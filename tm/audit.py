import csv
import io
import json
import logging
import os
import re
import socket
from datetime import datetime, timezone
from .models import get_db

log = logging.getLogger(__name__)

_FORMULA_CHARS = ('=', '+', '-', '@', '\t', '\r')


def _csv_safe(value):
    """Neutralise formula-injection prefixes for spreadsheet consumers."""
    s = str(value)
    if s and s[0] in _FORMULA_CHARS:
        s = "'" + s
    return s


# ── syslog: every audit row also leaves the process (v1.2.0) ─────────────────
# SRG-APP-000515 / NGNX-APP-001400: the audit trail must be off-loadable to a
# central collector. Every row log_action writes is ALSO sent, one datagram per
# row, to the local syslog socket under the identifier below; the host's
# rsyslog forwards that identifier off the host when Settings > Logging >
# Remote syslog is applied (install/libexec/tm-apply renders the rule).
#
# INDEPENDENT of logging.syslog_enabled in config.yaml: that flag governs the
# application's own diagnostic log (facility daemon, tm/app.py). The audit
# stream is always emitted, facility authpriv, so on a stock host it lands in
# /var/log/auth.log (root:adm 0640) beside the other authentication records
# even when nothing forwards it.
#
# Sent over the socket directly rather than through logging.SysLogHandler so
# that a missing socket is a False return, measured by the caller, and never a
# traceback printed from inside a logging handler.
SYSLOG_IDENT = 'topic-manager-audit'
_LOG_AUTHPRIV = 10
SEV_CRIT, SEV_WARNING, SEV_INFO = 2, 4, 6
_MAX_DATAGRAM = 4096
_CONTROL = re.compile(r'[\x00-\x1f\x7f-\x9f  ]')


def _syslog_path():
    return os.environ.get('TM_SYSLOG_SOCKET', '/dev/log')


def _field(value, limit=1024):
    # JSON-quoted, control characters removed: one audit row is ONE syslog
    # line, and a CR/LF in an attacker-chosen username cannot start another.
    return json.dumps(_CONTROL.sub('?', str(value))[:limit])


def format_record(record):
    """The syslog text of one audit record. Stable key=value order, every
    value JSON-quoted, so a collector can parse it without guessing."""
    return 'action=%s user=%s target=%s cluster=%s detail=%s ts=%s' % (
        _field(record.get('action', ''), 64), _field(record.get('user', ''), 128),
        _field(record.get('target', ''), 256), _field(record.get('cluster_id', ''), 128),
        _field(record.get('detail', ''), 2048), _field(record.get('ts', ''), 32))


def syslog_send(message, severity=SEV_INFO):
    """Send one message to the local syslog socket. Returns True when the
    datagram was accepted, False otherwise (and says why in the app log)."""
    pri = _LOG_AUTHPRIV * 8 + severity
    data = ('<%d>%s[%d]: %s' % (pri, SYSLOG_IDENT, os.getpid(), message)).encode(
        'utf-8', 'replace')[:_MAX_DATAGRAM]
    af_unix = getattr(socket, 'AF_UNIX', None)
    if af_unix is None:
        log.warning('audit syslog: this platform has no Unix sockets; record not sent')
        return False
    try:
        s = socket.socket(af_unix, socket.SOCK_DGRAM)
        try:
            s.connect(_syslog_path())
            s.send(data)
        finally:
            s.close()
        return True
    except OSError as exc:
        log.warning('audit syslog: could not send to %s: %s', _syslog_path(), exc)
        return False


def emit(record, severity=SEV_INFO):
    """Send a COMMITTED audit record to syslog."""
    return syslog_send(format_record(record), severity)


class AuditUnavailable(RuntimeError):
    """The audit trail cannot be written. The owner's ruling (2026-09-26): an
    action whose audit record cannot be written does not happen — routes turn
    this into HTTP 503 {"error": "audit_unavailable"}."""


def write_failed(record, exc):
    """The DB write of `record` failed. The record is not lost: it goes to
    syslog at CRIT as AUDIT_WRITE_FAILED, carrying the whole original row, and
    to the application log at CRITICAL."""
    msg = 'action=%s reason=%s original: %s' % (
        _field('AUDIT_WRITE_FAILED'), _field('%s: %s' % (type(exc).__name__, exc), 300),
        format_record(record))
    log.critical('AUDIT_WRITE_FAILED: the audit database refused a record '
                 '(%s: %s). The record was sent to syslog instead: %s',
                 type(exc).__name__, exc, format_record(record))
    syslog_send(msg, SEV_CRIT)


def _new_record(user, action, target, detail, cluster_id):
    return {'ts': datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S'),
            'user': user, 'action': action, 'target': target,
            'detail': detail, 'cluster_id': cluster_id}


#: The smallest free space on the database's filesystem an audited action may
#: start with. SQLite can open a write transaction on a full disk and only fail
#: at COMMIT, so the pre-check measures the space as well.
AUDIT_MIN_FREE_BYTES = 1024 * 1024


def _db_path(cfg):
    return cfg.get('audit', {}).get('db_path', '/opt/topic-manager/data/tm.db')


def require_writable(cfg):
    """Prove, BEFORE an action that cannot be undone, that its audit record can
    be written: a real write transaction with a real (rolled-back) audit row,
    and enough free space for it to commit. Raises AuditUnavailable, after
    reporting AUDIT_WRITE_FAILED at CRIT, when it cannot."""
    probe = _new_record('(pre-check)', 'AUDIT_PRECHECK', 'audit_log', '', '')
    db = None
    try:
        st = os.statvfs(os.path.dirname(_db_path(cfg)) or '.') if hasattr(os, 'statvfs') else None
        if st is not None and st.f_bavail * st.f_frsize < AUDIT_MIN_FREE_BYTES:
            raise OSError('less than %d bytes free for the audit database'
                          % AUDIT_MIN_FREE_BYTES)
        db = get_db(cfg)
        db.execute('BEGIN IMMEDIATE')
        db.execute('INSERT INTO audit_log (ts, user, action, target, detail, cluster_id) '
                   'VALUES (?,?,?,?,?,?)',
                   (probe['ts'], probe['user'], probe['action'], probe['target'],
                    probe['detail'], probe['cluster_id']))
        db.rollback()
    except Exception as exc:
        write_failed(probe, exc)
        raise AuditUnavailable(str(exc)) from exc
    finally:
        if db is not None:
            db.close()


def log_action(cfg, user, action, target, detail='', cluster_id='', db=None,
               best_effort=False):
    """Write one audit row, and send it to syslog once it is committed.

    With `db`, the row is written on THAT connection inside the caller's open
    transaction and is NOT committed here: the caller commits the change and
    its audit record together, or rolls both back (v1.1.0, settings), and calls
    emit(record) after its commit — a row that is rolled back is never sent.
    Without it, the row gets its own connection and commit, and is emitted.

    A failed write is AUDIT_WRITE_FAILED at CRIT in syslog (with the whole
    record), then AuditUnavailable is raised — unless `best_effort`, for the
    few records whose action cannot be refused (a failed login is already a
    refusal; a sign-out must never be blocked), which return None instead.
    Returns the record on success.
    """
    record = _new_record(user, action, target, detail, cluster_id)
    own = db is None
    try:
        if own:
            db = get_db(cfg)
        db.execute(
            'INSERT INTO audit_log (ts, user, action, target, detail, cluster_id) VALUES (?,?,?,?,?,?)',
            (record['ts'], user, action, target, detail, cluster_id)
        )
        if own:
            db.commit()
    except Exception as exc:
        write_failed(record, exc)
        if best_effort:
            return None
        raise AuditUnavailable(str(exc)) from exc
    finally:
        if own and db is not None:
            db.close()
    if own:
        emit(record)
    return record


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
