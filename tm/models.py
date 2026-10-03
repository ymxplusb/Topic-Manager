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
    conn = sqlite3.connect(db_path)
    _refuse_extensions(conn)
    return conn


def _refuse_extensions(conn):
    """SRG-APP-000141-DB-000093: no external executable may be loaded into
    the database engine. Python builds sqlite3 with extension loading OFF, but
    that is a default, not a decision; this states it on every connection the
    application opens. An interpreter built without extension support has no
    enable_load_extension at all, which is the same outcome (t17 asserts that
    load_extension() is refused either way)."""
    disable = getattr(conn, 'enable_load_extension', None)
    if disable is not None:
        disable(False)


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
            cluster_id TEXT,
            source     TEXT    NOT NULL DEFAULT '',
            outcome    TEXT    NOT NULL DEFAULT ''
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
    # v1.3.0 (DQ8): what a session row does not hold, beside it rather than in
    # it, so the sessions table keeps the shape every earlier release (and every
    # restore point) has. verified_at: when the directory last confirmed the
    # user is in required_group (missing = the sign-in itself, created_at).
    # verify_attempt_at: the last attempt, so an unreachable directory is asked
    # at most once a minute per session. end_reason: why an administrator or a
    # failed re-check ended it; the session row stays, expired, so its next
    # request is told WHY.
    cur.execute('''
        CREATE TABLE IF NOT EXISTS session_meta (
            id                TEXT PRIMARY KEY,
            verified_at       TEXT,
            verify_attempt_at TEXT,
            end_reason        TEXT
        )
    ''')
    cur.execute('CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user)')
    _fold_session_users(cur)
    # v1.2.0: retention prunes by age (tm/audit_retention.py). Without an index
    # on ts every prune and every capacity read is a full scan of a table that
    # is allowed to hold five million rows by default.
    cur.execute('CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts)')
    db.commit()
    # v1.3.0: source/outcome columns and ISO 8601 Z timestamps, in ONE
    # transaction with its own audit row (tm/audit.migrate_schema). Imported
    # here because tm.audit imports this module.
    from . import audit
    try:
        record = audit.migrate_schema(cfg, db)
    finally:
        db.close()
    if record:
        audit.emit(record)



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


def validate_session(db, sid, absolute_hours=None):
    """Return username if session exists and is not expired, else None."""
    user, _reason = session_state(db, sid, absolute_hours)
    return user


#: The reasons session_state gives for a session that is no longer valid.
#: tm/routes.py writes the sentence into the SESSION_EXPIRED audit row
#: (SRG-APP-000295: the condition that ended it).
END_REASONS = {
    'unknown':  'session no longer valid',
    'idle':     'idle timeout',
    'absolute': 'absolute session lifetime reached',
}


def session_state(db, sid, absolute_hours=None):
    """(username, None) for a valid session, else (username or None, reason):
    'unknown' (no such row), 'idle' (expires_at passed), 'absolute' (older
    than `absolute_hours` since sign-in, however active), or the end_reason an
    administrator or a failed group re-check recorded. The absolute limit is
    measured from created_at, which no request ever moves."""
    row = db.execute(
        'SELECT s.user, s.created_at, s.expires_at, m.end_reason FROM sessions s '
        'LEFT JOIN session_meta m ON m.id = s.id WHERE s.id=?', (sid,)).fetchone()
    if not row:
        return None, 'unknown'
    user, created, expires, ended = row
    now = _now()
    if ended:
        return user, ended
    if absolute_hours and _parse(created) is not None \
            and now - _parse(created) >= timedelta(hours=absolute_hours):
        return user, 'absolute'
    if expires <= _iso(now):
        return user, 'idle'
    return user, None


def _parse(value):
    try:
        dt = datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def session_absolute_end(db, sid, absolute_hours):
    """When the session reaches its absolute lifetime (ISO 8601), or None."""
    row = db.execute('SELECT created_at FROM sessions WHERE id=?', (sid,)).fetchone()
    created = _parse(row[0]) if row else None
    if created is None or not absolute_hours:
        return None
    return _iso(created + timedelta(hours=absolute_hours))


def session_verification(db, sid):
    """(verified_at, verify_attempt_at) as datetimes. A session never
    re-checked was verified by its sign-in: verified_at is its created_at."""
    row = db.execute(
        'SELECT s.created_at, m.verified_at, m.verify_attempt_at FROM sessions s '
        'LEFT JOIN session_meta m ON m.id = s.id WHERE s.id=?', (sid,)).fetchone()
    if not row:
        return None, None
    return _parse(row[1] or row[0]), _parse(row[2])


def mark_verified(db, sid, ok):
    """Record a group re-check: ok moves verified_at and the attempt time,
    a failed attempt (directory unreachable) moves the attempt time only."""
    now = _iso(_now())
    db.execute('INSERT OR IGNORE INTO session_meta (id) VALUES (?)', (sid,))
    if ok:
        db.execute('UPDATE session_meta SET verified_at=?, verify_attempt_at=? WHERE id=?',
                   (now, now, sid))
    else:
        db.execute('UPDATE session_meta SET verify_attempt_at=? WHERE id=?', (now, sid))
    db.commit()


def end_sessions(db, reason, user=None, keep_sid=None, commit=True):
    """End every active session (of `user`, when given), except `keep_sid`:
    each is expired NOW with `reason` recorded, so its next request is refused
    and audited with that reason. Returns how many were ended. commit=False
    leaves the change in the caller's transaction (with its audit row)."""
    now = _iso(_now())
    where = ('expires_at > ? AND id != ? AND id NOT IN '
             '(SELECT id FROM session_meta WHERE end_reason IS NOT NULL)')
    args = [now, keep_sid or '']
    if user is not None:
        where += ' AND user = ?'
        args.append(session_user_key(user))
    ids = [r[0] for r in db.execute('SELECT id FROM sessions WHERE ' + where, args).fetchall()]
    for sid in ids:
        db.execute('INSERT OR IGNORE INTO session_meta (id) VALUES (?)', (sid,))
        db.execute('UPDATE session_meta SET end_reason=? WHERE id=?', (str(reason)[:200], sid))
        db.execute('UPDATE sessions SET expires_at=? WHERE id=?', (now, sid))
    if commit:
        db.commit()
    return len(ids)


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
    db.execute('DELETE FROM session_meta WHERE id=?', (sid,))
    db.commit()


def count_active_sessions(db, username):
    row = db.execute(
        'SELECT COUNT(*) FROM sessions WHERE user=? AND expires_at > ?',
        (session_user_key(username), _iso(_now()))
    ).fetchone()
    return row[0] if row else 0


def session_handle(sid):
    """What a session is called OUTSIDE its own cookie. The id is a bearer
    secret: the administrator's session list must never show one, or any
    signed-in user could read another's id and replay it. A one-way digest
    names it well enough to end it."""
    import hashlib
    return hashlib.sha256(str(sid).encode('utf-8')).hexdigest()[:16]


def list_all_active_sessions(db):
    """Every active session, newest activity first, by handle (never id)."""
    rows = db.execute(
        'SELECT id, user, created_at, last_seen, ip_addr FROM sessions '
        'WHERE expires_at > ? ORDER BY last_seen DESC', (_iso(_now()),)).fetchall()
    return [{'handle': session_handle(r[0]), 'user': r[1], 'created_at': r[2],
             'last_seen': r[3], 'ip_addr': r[4] or ''} for r in rows]


#: How long an expired session row is kept (v1.3.0). Long enough that the
#: next request of a session ended by an administrator, a group re-check or the
#: idle clock is told WHY (session_state) rather than "unknown"; the rows are
#: never counted as active (every count filters on expires_at).
EXPIRED_KEEP = timedelta(hours=24)


def cleanup_expired_sessions(db):
    db.execute('DELETE FROM sessions WHERE expires_at <= ?', (_iso(_now() - EXPIRED_KEEP),))
    db.execute('DELETE FROM session_meta WHERE id NOT IN (SELECT id FROM sessions)')
    db.commit()
