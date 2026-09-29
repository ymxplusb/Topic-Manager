import logging
import sqlite3
import os
import stat
import uuid
from datetime import datetime, timezone, timedelta

log = logging.getLogger(__name__)


#: tm.db holds the audit trail, the server-side sessions and the app
#: settings. It is read and written by the service account and nobody else, so
#: the file is 0600 and its directory 0700 (v1.1.0). Before that the file was
#: created under whatever umask the process had — 0644 on a stock host, i.e.
#: every local account could read who did what, and copy live session ids.
DB_FILE_MODE = 0o600
DB_DIR_MODE = 0o700


def _ensure_db_file(db_path):
    """
    Create the directory 0700 and the database file 0600 if they are absent,
    BEFORE sqlite opens it. sqlite3.connect would otherwise create the file
    with the process umask; creating it here with os.open(..., 0o600) means it
    never exists at a wider mode, not even for the first request. SQLite gives
    its -wal/-journal/-shm siblings the database file's own permissions, so
    they follow.
    """
    directory = os.path.dirname(db_path)
    if directory:
        os.makedirs(directory, mode=DB_DIR_MODE, exist_ok=True)
    if not os.path.exists(db_path):
        try:
            fd = os.open(db_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, DB_FILE_MODE)
            os.close(fd)
        except FileExistsError:
            pass            # another worker created it first; that is fine


def _tighten(path, mode):
    """Narrow an existing path to `mode` if it is any wider. Never widens, and
    never follows a symlink: the app owns this directory, and a mode applied
    through a link would land on whatever it points at."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(st.st_mode):
        return
    if st.st_mode & 0o777 & ~mode:
        try:
            os.chmod(path, st.st_mode & mode & 0o777)
        except OSError as exc:
            # Not ours to fix (e.g. a root-owned directory). The installer and
            # the upgrade enforce the mode as root; refusing to start the
            # service over it would turn a hardening step into an outage.
            log.warning('could not narrow %s to %o: %s', path, mode, exc)


def get_db(cfg):
    db_path = cfg.get('audit', {}).get('db_path', '/opt/topic-manager/data/tm.db')
    _ensure_db_file(db_path)
    return sqlite3.connect(db_path)


def init_db(cfg):
    db_path = cfg.get('audit', {}).get('db_path', '/opt/topic-manager/data/tm.db')
    _ensure_db_file(db_path)
    # Once per process start: bring an EXISTING database and directory created
    # by an older release (0644 / 0755) down to 0600 / 0700. The installer and
    # the upgrade enforce the same thing as root; this is the belt to their
    # braces for a host where someone restored a file by hand.
    for suffix in ('', '-wal', '-shm', '-journal'):
        _tighten(db_path + suffix, DB_FILE_MODE)
    if os.path.dirname(db_path):
        _tighten(os.path.dirname(db_path), DB_DIR_MODE)
    db = get_db(cfg)
    cur = db.cursor()
    cur.execute('''
        CREATE TABLE IF NOT EXISTS audit_log (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         TEXT    NOT NULL,
            user       TEXT    NOT NULL,
            action     TEXT    NOT NULL,
            target     TEXT    NOT NULL,
            detail     TEXT,
            cluster_id TEXT
        )
    ''')
    cur.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
            key   TEXT PRIMARY KEY,
            value TEXT
        )
    ''')
    cur.execute('''
        CREATE TABLE IF NOT EXISTS sessions (
            id         TEXT PRIMARY KEY,
            user       TEXT NOT NULL,
            created_at TEXT NOT NULL,
            last_seen  TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            ip_addr    TEXT
        )
    ''')
    cur.execute('CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user)')
    _fold_session_users(cur)
    # v1.2.0: retention prunes by age (tm/audit_retention.py). Without an index
    # on ts every prune and every capacity read is a full scan of a table that
    # is allowed to hold five million rows by default.
    cur.execute('CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts)')
    db.commit()
    db.close()


def session_user_key(username):
    """The ONE form a user name takes in the sessions table: lower-case
    (tm/auth._normalise_sam). Every writer and every lookup goes through it,
    so "Alice" and "alice" share one concurrent-session count."""
    return str(username).lower()


def _fold_session_users(cur):
    """v1.2.0 migration: session rows written before user names were
    lower-cased. Done in Python because SQLite's lower() folds ASCII only."""
    rows = cur.execute('SELECT DISTINCT user FROM sessions').fetchall()
    for (user,) in rows:
        if user != session_user_key(user):
            cur.execute('UPDATE sessions SET user = ? WHERE user = ?',
                        (session_user_key(user), user))


# ── session helpers ───────────────────────────────────────────────

def _now():
    return datetime.now(timezone.utc)

def _iso(dt):
    return dt.isoformat()


def create_session(db, username, timeout_minutes, ip_addr=''):
    sid = str(uuid.uuid4())
    now = _now()
    expires = now + timedelta(minutes=timeout_minutes)
    db.execute(
        'INSERT INTO sessions (id, user, created_at, last_seen, expires_at, ip_addr) VALUES (?,?,?,?,?,?)',
        (sid, session_user_key(username), _iso(now), _iso(now), _iso(expires), ip_addr or '')
    )
    db.commit()
    return sid


def validate_session(db, sid):
    """Return username if session exists and is not expired, else None."""
    row = db.execute(
        'SELECT user FROM sessions WHERE id=? AND expires_at > ?',
        (sid, _iso(_now()))
    ).fetchone()
    return row[0] if row else None


def touch_session(db, sid, timeout_minutes):
    """Reset the expiry window from now."""
    now = _now()
    expires = now + timedelta(minutes=timeout_minutes)
    db.execute(
        'UPDATE sessions SET last_seen=?, expires_at=? WHERE id=?',
        (_iso(now), _iso(expires), sid)
    )
    db.commit()


def delete_session(db, sid):
    db.execute('DELETE FROM sessions WHERE id=?', (sid,))
    db.commit()


def count_active_sessions(db, username):
    row = db.execute(
        'SELECT COUNT(*) FROM sessions WHERE user=? AND expires_at > ?',
        (session_user_key(username), _iso(_now()))
    ).fetchone()
    return row[0] if row else 0


def list_active_sessions(db, username):
    rows = db.execute(
        'SELECT id, created_at, last_seen, ip_addr FROM sessions WHERE user=? AND expires_at > ? ORDER BY last_seen DESC',
        (session_user_key(username), _iso(_now()))
    ).fetchall()
    return [{'id': r[0], 'created_at': r[1], 'last_seen': r[2], 'ip_addr': r[3]} for r in rows]


def cleanup_expired_sessions(db):
    db.execute('DELETE FROM sessions WHERE expires_at <= ?', (_iso(_now()),))
    db.commit()
