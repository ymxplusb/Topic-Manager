import sqlite3
import os


def get_db(cfg):
    db_path = cfg.get('audit', {}).get('db_path', '/opt/topic-manager/data/tm.db')
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    return sqlite3.connect(db_path)


def init_db(cfg):
    db = get_db(cfg)
    cur = db.cursor()
    cur.execute('''
        CREATE TABLE IF NOT EXISTS audit_log (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            ts        TEXT    NOT NULL,
            user      TEXT    NOT NULL,
            action    TEXT    NOT NULL,
            target    TEXT    NOT NULL,
            detail    TEXT,
            cluster_id TEXT
        )
    ''')
    cur.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
            key   TEXT PRIMARY KEY,
            value TEXT
        )
    ''')
    db.commit()
    db.close()
