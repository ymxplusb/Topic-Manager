import csv
import io
from datetime import datetime, timezone
from .models import get_db

_FORMULA_CHARS = ('=', '+', '-', '@', '\t', '\r')


def _csv_safe(value):
    """Neutralise formula-injection prefixes for spreadsheet consumers."""
    s = str(value)
    if s and s[0] in _FORMULA_CHARS:
        s = "'" + s
    return s


def log_action(cfg, user, action, target, detail='', cluster_id=''):
    db = get_db(cfg)
    ts = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
    db.execute(
        'INSERT INTO audit_log (ts, user, action, target, detail, cluster_id) VALUES (?,?,?,?,?,?)',
        (ts, user, action, target, detail, cluster_id)
    )
    db.commit()
    db.close()


def get_audit_log(cfg, page=1, per_page=50):
    db = get_db(cfg)
    offset = (page - 1) * per_page
    rows = db.execute(
        'SELECT id, ts, user, action, target, detail, cluster_id '
        'FROM audit_log ORDER BY id DESC LIMIT ? OFFSET ?',
        (per_page, offset)
    ).fetchall()
    total = db.execute('SELECT COUNT(*) FROM audit_log').fetchone()[0]
    db.close()
    return {
        'entries': [
            {'id': r[0], 'ts': r[1], 'user': r[2], 'action': r[3],
             'target': r[4], 'detail': r[5], 'cluster_id': r[6]}
            for r in rows
        ],
        'total': total,
        'page': page,
        'per_page': per_page,
        'pages': max(1, (total + per_page - 1) // per_page),
    }


def export_audit_csv(cfg):
    db = get_db(cfg)
    rows = db.execute(
        'SELECT ts, user, action, target, detail, cluster_id '
        'FROM audit_log ORDER BY id DESC'
    ).fetchall()
    db.close()
    buf = io.StringIO()
    writer = csv.writer(buf, quoting=csv.QUOTE_ALL, lineterminator='\n')
    writer.writerow(['timestamp', 'user', 'action', 'target', 'detail', 'cluster_id'])
    for r in rows:
        writer.writerow([_csv_safe(c) for c in r])
    return buf.getvalue()
