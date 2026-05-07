import sqlite3
import os
import uuid
from datetime import datetime, timezone, timedelta


def get_db(cfg):
    db_path = cfg.get('audit', {}).get('db_path', '/opt/topic-manager/data/tm.db')
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    return sqlite3.connect(db_path)


def init_db(cfg):
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
    db.commit()
    db.close()


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
        (sid, username, _iso(now), _iso(now), _iso(expires), ip_addr or '')
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
        (username, _iso(_now()))
    ).fetchone()
    return row[0] if row else 0


def list_active_sessions(db, username):
    rows = db.execute(
        'SELECT id, created_at, last_seen, ip_addr FROM sessions WHERE user=? AND expires_at > ? ORDER BY last_seen DESC',
        (username, _iso(_now()))
    ).fetchall()
    return [{'id': r[0], 'created_at': r[1], 'last_seen': r[2], 'ip_addr': r[3]} for r in rows]


def cleanup_expired_sessions(db):
    db.execute('DELETE FROM sessions WHERE expires_at <= ?', (_iso(_now()),))
    db.commit()
