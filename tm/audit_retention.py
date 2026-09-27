"""
Audit retention and capacity (v1.2.0; SRG-APP-000120/000357/000359).

PRUNE — by age and by row count ONLY (owner ruling 2026-09-26). Rows older
than audit_retention_days go, then the oldest rows beyond audit_max_rows. The
deletion and its AUDIT_PRUNE record are ONE transaction: a prune that cannot
record itself does not delete anything. Rows are not held back until a
collector has confirmed them — UDP cannot confirm anything — so the docs
recommend TCP or TLS forwarding for a guaranteed off-load.

Run daily by topic-manager-audit-prune.timer as the service account with
UMask=0077 (it does not inherit topic-manager.service's), so a database it
happens to create is 0600 like the one the service creates:

    python -m tm.audit_retention [--config /etc/topic-manager/config.yaml]

CAPACITY — the larger of two ratios, as a percentage:
    rows used / audit_max_rows, and
    database bytes / (database bytes + free bytes on its filesystem).
At audit_warn_pct and above the Settings banner shows, and ONE
AUDIT_CAPACITY_WARNING row + syslog WARNING is written per crossing: the
"already warned" flag is claimed with a single conditional UPSERT, so four
gunicorn workers and the timer cannot all report the same crossing. Falling
back below the threshold re-arms it.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import argparse
import logging
import os
import sys
from datetime import datetime, timedelta, timezone

from . import audit, settings_schema
from .models import get_db, init_db

log = logging.getLogger(__name__)

LAST_PRUNE_KEY = 'audit_last_prune'
WARNED_KEY = 'audit_capacity_warned'
SYSTEM_USER = 'system'


def _now():
    return datetime.now(timezone.utc)


def _ts(dt):
    # The audit_log ts format (tm/audit.py), so string comparison is ordering.
    return dt.strftime('%Y-%m-%d %H:%M:%S')


def _settings(db):
    vals = settings_schema.read_admin(
        db, ['audit_retention_days', 'audit_max_rows', 'audit_warn_pct'])
    return {k: settings_schema.int_setting(vals, k) for k in vals}


def _last_prune(db):
    row = db.execute('SELECT value FROM app_settings WHERE key=?',
                     (LAST_PRUNE_KEY,)).fetchone()
    return row[0] if row else None


def prune(cfg, now=None):
    """Delete what retention says must go, and record it. Returns a dict:
    {deleted_age, deleted_rows, remaining, oldest}. Raises on any failure, in
    which case nothing was deleted."""
    now = now or _now()
    db = get_db(cfg)
    try:
        s = _settings(db)
        cutoff = _ts(now - timedelta(days=s['audit_retention_days']))
        db.execute('BEGIN IMMEDIATE')
        by_age = db.execute('DELETE FROM audit_log WHERE ts < ?', (cutoff,)).rowcount
        # Keep max_rows - 1, so that WITH the AUDIT_PRUNE row the table holds
        # exactly max_rows. Oldest first by id, which is insertion order. The
        # row at OFFSET k is the (k+1)-th newest and is itself kept, so
        # k = max_rows - 2 keeps max_rows - 1 (t33 measured the off-by-one).
        by_rows = db.execute(
            'DELETE FROM audit_log WHERE id < (SELECT id FROM audit_log '
            'ORDER BY id DESC LIMIT 1 OFFSET ?)',
            (s['audit_max_rows'] - 2,)).rowcount
        record = None
        if by_age or by_rows:
            oldest = db.execute('SELECT MIN(ts) FROM audit_log').fetchone()[0]
            reasons = []
            if by_age:
                reasons.append('%d older than %d days (before %s UTC)'
                               % (by_age, s['audit_retention_days'], cutoff))
            if by_rows:
                reasons.append('%d beyond the %d-row limit'
                               % (by_rows, s['audit_max_rows']))
            detail = 'deleted %d: %s; oldest kept %s' % (
                by_age + by_rows, '; '.join(reasons), oldest or '(none)')
            record = audit.log_action(cfg, SYSTEM_USER, 'AUDIT_PRUNE', 'audit_log',
                                      detail, '', db=db)
        db.execute('INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)',
                   (LAST_PRUNE_KEY, now.isoformat()))
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        remaining = None
        try:
            remaining = db.execute('SELECT COUNT(*) FROM audit_log').fetchone()[0]
            oldest = db.execute('SELECT MIN(ts) FROM audit_log').fetchone()[0]
        except Exception:
            oldest = None
        db.close()
    if record:
        audit.emit(record)
    return {'deleted_age': by_age, 'deleted_rows': by_rows,
            'remaining': remaining, 'oldest': oldest}


def _db_bytes(path):
    total = 0
    for suffix in ('', '-wal', '-shm', '-journal'):
        try:
            total += os.stat(path + suffix).st_size
        except OSError:
            pass
    return total


def _free_bytes(path):
    if not hasattr(os, 'statvfs'):
        return None
    st = os.statvfs(os.path.dirname(path) or '.')
    return st.f_bavail * st.f_frsize


def _iso(ts):
    """An audit ts ('YYYY-MM-DD HH:MM:SS', UTC) as ISO 8601, or None."""
    if not ts:
        return None
    try:
        return datetime.strptime(ts, '%Y-%m-%d %H:%M:%S').replace(
            tzinfo=timezone.utc).isoformat()
    except ValueError:
        return None


def capacity(cfg, record_crossing=True):
    """The /api/audit/capacity document. With record_crossing, an upward
    crossing of the threshold is audited exactly once (see module doc)."""
    db_path = cfg.get('audit', {}).get('db_path', '/opt/topic-manager/data/tm.db')
    db = get_db(cfg)
    try:
        s = _settings(db)
        rows = db.execute('SELECT COUNT(*) FROM audit_log').fetchone()[0]
        oldest = db.execute('SELECT MIN(ts) FROM audit_log').fetchone()[0]
        last_prune = _last_prune(db)
    finally:
        db.close()
    pct_rows = 100.0 * rows / s['audit_max_rows']
    used = _db_bytes(db_path)
    free = _free_bytes(db_path)
    pct_disk = (100.0 * used / (used + free)) if free is not None and used + free > 0 else 0.0
    pct = round(max(pct_rows, pct_disk), 1)
    warning = pct >= s['audit_warn_pct']
    doc = {'rows': rows, 'max_rows': s['audit_max_rows'], 'oldest': _iso(oldest),
           'retention_days': s['audit_retention_days'], 'pct': pct,
           'warn_pct': s['audit_warn_pct'], 'warning': warning,
           'last_prune': last_prune}
    if record_crossing:
        _record_crossing(cfg, warning, doc, pct_rows, pct_disk)
    return doc


def _record_crossing(cfg, warning, doc, pct_rows, pct_disk):
    want = '1' if warning else '0'
    db = get_db(cfg)
    record = None
    try:
        db.execute('BEGIN IMMEDIATE')
        # The claim: exactly one caller moves the flag, and only that caller
        # writes the record. A missing flag counts as '0' (not warned).
        cur = db.execute(
            'INSERT INTO app_settings (key, value) VALUES (?, ?) '
            'ON CONFLICT(key) DO UPDATE SET value = excluded.value '
            '  WHERE app_settings.value != excluded.value',
            (WARNED_KEY, want))
        claimed = cur.rowcount == 1
        if claimed and warning:
            detail = ('audit storage at %.1f%% (rows %.1f%% of %d, disk %.1f%%); '
                      'warning threshold %d%%' % (doc['pct'], pct_rows, doc['max_rows'],
                                                    pct_disk, doc['warn_pct']))
            record = audit.log_action(cfg, SYSTEM_USER, 'AUDIT_CAPACITY_WARNING',
                                      'audit_log', detail, '', db=db)
        db.commit()
    except Exception:
        db.rollback()
        log.exception('could not record the audit capacity state')
        return
    finally:
        db.close()
    if record:
        audit.emit(record, audit.SEV_WARNING)


def main(argv=None):
    ap = argparse.ArgumentParser(prog='python -m tm.audit_retention',
                                 description='Prune the audit trail by age and row count.')
    ap.add_argument('--config', default=None,
                    help='config.yaml (default: $TM_CONFIG or /etc/topic-manager/config.yaml)')
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    from .config import load_config
    cfg = load_config(args.config)
    init_db(cfg)
    try:
        res = prune(cfg)
    except Exception as exc:
        log.error('audit prune FAILED; nothing was deleted: %s: %s', type(exc).__name__, exc)
        return 1
    cap = capacity(cfg)
    log.info('audit prune: %d deleted by age, %d by row limit; %s rows remain; '
             'capacity %.1f%% (warning at %d%%)', res['deleted_age'], res['deleted_rows'],
             res['remaining'], cap['pct'], cap['warn_pct'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
