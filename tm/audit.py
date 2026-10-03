import csv
import io
import json
import logging
import os
import re
import socket
from datetime import datetime, timezone
from .models import get_db

try:                                    # the service and every CLI run in the venv
    from flask import g, has_request_context, request
except ImportError:                     # pragma: no cover - a bare interpreter
    g = request = None

    def has_request_context():
        return False

log = logging.getLogger(__name__)

# ── the shape of one audit row (v1.3.0, DQ6) ─────────────────────────────────
# SRG-APP-000374: the stored time is ISO 8601 UTC with its "Z", so a row read
# on its own (an export, a syslog line, the Audit tab) says which clock it is.
# Before v1.3.0 it was "YYYY-MM-DD HH:MM:SS" with no zone; migrate_schema()
# rewrites every such row in one transaction. The format is fixed-width and
# zero-padded, so string order is still time order: tm/audit_retention.py
# compares ts as strings and relies on it.
TS_FORMAT = '%Y-%m-%dT%H:%M:%SZ'
#: SRG-APP-000099: every row says whether the event succeeded.
OUTCOMES = ('success', 'failure')
#: SRG-APP-000098: the origin of a row written by no client (the prune timer,
#: the apply-result recorder, the installer).
SYSTEM_SOURCE = 'system'


def utc_ts(dt=None):
    """An audit timestamp: `dt` (default now) in TS_FORMAT, UTC."""
    return (dt or datetime.now(timezone.utc)).astimezone(timezone.utc).strftime(TS_FORMAT)


def request_source():
    """The client address of the request being served (ProxyFix makes it
    the real one, tm/app.py), or SYSTEM_SOURCE outside a request."""
    if has_request_context():
        return request.remote_addr or 'unknown'
    return SYSTEM_SOURCE


def _mark_audited():
    # tm/routes.py's after_request records a signed-in caller's refused write
    # (DQ7) only when the route did not record anything itself.
    if has_request_context():
        g.tm_audited = True


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
#: The longest one datagram may wait for room in the syslog daemon's receive
#: queue. A Unix datagram send BLOCKS while the receiver's queue is full
#: (net.unix.max_dgram_qlen: 512 on a host, 10 in a container's netns), so a
#: stalled journald/rsyslog used to hang every gunicorn worker that wrote an
#: audit record, forever. Past this bound the send is a failure (False), the
#: record stays in the audit database, and the failure is logged at CRITICAL.
SYSLOG_SEND_TIMEOUT = 0.5
_CONTROL = re.compile(r'[\x00-\x1f\x7f-\x9f  ]')


def _syslog_path():
    return os.environ.get('TM_SYSLOG_SOCKET', '/dev/log')


def _field(value, limit=1024):
    # JSON-quoted, control characters removed: one audit row is ONE syslog
    # line, and a CR/LF in an attacker-chosen username cannot start another.
    return json.dumps(_CONTROL.sub('?', str(value))[:limit])


def format_record(record):
    """The syslog text of one audit record. Stable key=value order, every
    value JSON-quoted, so a collector can parse it without guessing. v1.3.0
    APPENDS source= and outcome= after ts=, so a collector that matched the
    v1.2 line by position still finds every earlier key where it was."""
    return 'action=%s user=%s target=%s cluster=%s detail=%s ts=%s source=%s outcome=%s' % (
        _field(record.get('action', ''), 64), _field(record.get('user', ''), 128),
        _field(record.get('target', ''), 256), _field(record.get('cluster_id', ''), 128),
        _field(record.get('detail', ''), 2048), _field(record.get('ts', ''), 32),
        _field(record.get('source', ''), 64), _field(record.get('outcome', ''), 16))


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
            s.settimeout(SYSLOG_SEND_TIMEOUT)     # never an unbounded wait
            s.connect(_syslog_path())
            s.send(data)
        finally:
            s.close()
        return True
    except socket.timeout:
        log.error('audit syslog: %s did not accept the record within %.1f s (its receive '
                  'queue is full: the syslog daemon is stalled or not reading)',
                  _syslog_path(), SYSLOG_SEND_TIMEOUT)
        return False
    except OSError as exc:
        # With the traceback (Sonar S8572): the socket's own error is the diagnosis.
        log.exception('audit syslog: could not send to %s: %s', _syslog_path(), exc)
        return False


def emit(record, severity=SEV_INFO):
    """Send a COMMITTED audit record to syslog. Returns syslog_send's verdict.

    Every caller emits AFTER its commit, so the action has happened and its
    record IS in the audit database; the owner's ruling (an action whose
    record cannot be written does not happen) is already satisfied, and a
    syslog failure here cannot undo either. It is not silent: the whole
    record goes to the application log at CRITICAL as AUDIT_SYSLOG_FAILED, so
    the gap in the off-host copy is visible and can be reconciled from the
    database export."""
    ok = syslog_send(format_record(record), severity)
    if not ok:
        log.critical('AUDIT_SYSLOG_FAILED: a committed audit record did NOT reach syslog, so it '
                     'was not forwarded off the host; it is in the audit database: %s',
                     format_record(record))
    return ok


class AuditUnavailable(RuntimeError):
    """The audit trail cannot be written. The owner's ruling (2026-09-26): an
    action whose audit record cannot be written does not happen — routes turn
    this into HTTP 503 {"error": "audit_unavailable"}.

    `syslog_delivered` says whether the AUDIT_WRITE_FAILED copy of the record
    reached the host syslog, so nothing that reports this failure has to
    GUESS where the record went (round 4, sec-review TM-SEC-006)."""

    def __init__(self, message, syslog_delivered=False):
        super().__init__(message)
        self.syslog_delivered = syslog_delivered


def write_failed(record, exc, cfg=None):
    """The DB write of `record` failed. Its whole row goes to syslog at CRIT
    as AUDIT_WRITE_FAILED. Returns True only when syslog ACCEPTED it; the
    application log says which happened, because until round 4 it said "sent to
    syslog instead" before the send was even tried, and said it again when the
    send then failed. With `cfg`, the failure is also noted beside the database
    for the Settings banner (write_failure_state)."""
    if cfg is not None:
        _note_write_failure(cfg, record, exc)
    msg = 'action=%s reason=%s original: %s' % (
        _field('AUDIT_WRITE_FAILED'), _field('%s: %s' % (type(exc).__name__, exc), 300),
        format_record(record))
    delivered = syslog_send(msg, SEV_CRIT)
    if delivered:
        log.critical('AUDIT_WRITE_FAILED: the audit database refused a record (%s: %s). '
                     'The record was sent to the host syslog instead: %s',
                     type(exc).__name__, exc, format_record(record))
    else:
        log.critical('AUDIT_WRITE_FAILED: the audit database refused a record (%s: %s) AND '
                     'the host syslog did not accept it either; this log line is the only '
                     'copy: %s', type(exc).__name__, exc, format_record(record))
    return delivered


def _new_record(user, action, target, detail, cluster_id, source=None, outcome='success'):
    if outcome not in OUTCOMES:
        raise ValueError('audit outcome must be one of %s, not %r' % (OUTCOMES, outcome))
    return {'ts': utc_ts(),
            'user': user, 'action': action, 'target': target,
            'detail': detail, 'cluster_id': cluster_id,
            'source': request_source() if source is None else str(source)[:64],
            'outcome': outcome}


_INSERT = ('INSERT INTO audit_log (ts, user, action, target, detail, cluster_id, source, outcome) '
           'VALUES (?,?,?,?,?,?,?,?)')


def _row(record):
    return (record['ts'], record['user'], record['action'], record['target'],
            record['detail'], record['cluster_id'], record['source'], record['outcome'])


# ── the audit-failure banner (v1.3.0, SRG-APP-000360) ────────────────────────
# AUDIT_WRITE_FAILED goes to syslog at CRIT as it happens. What an operator in
# the browser did not get was any LASTING sign of it: the actor saw one 503 and
# every other user saw nothing. The failure is therefore also written to a
# small file BESIDE the database (not in it: the database is what failed), and
# the next successful write marks it recovered. /api/audit/capacity carries it
# and Settings and the Audit tab show a banner while it is current.
WRITE_FAILURE_FILE = 'audit-write-failure.json'


def _failure_path(cfg):
    return os.path.join(os.path.dirname(_db_path(cfg)) or '.', WRITE_FAILURE_FILE)


def _write_failure_doc(cfg, doc):
    path = _failure_path(cfg)
    tmp = path + '.tmp'
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        try:
            os.write(fd, json.dumps(doc, sort_keys=True).encode('utf-8'))
        finally:
            os.close(fd)
        os.replace(tmp, path)
    except OSError as exc:
        # A full or read-only disk is often WHY the database failed. The CRIT
        # line in syslog is the alert; this file is only the banner.
        log.warning('could not record the audit write failure state in %s: %s', path, exc)


def _note_write_failure(cfg, record, exc):
    _write_failure_doc(cfg, {'failed_at': utc_ts(), 'action': str(record.get('action', ''))[:64],
                             'reason': type(exc).__name__, 'recovered_at': None})


def _note_success(cfg):
    """A write succeeded: a current failure is marked recovered. One stat
    per audit write when there is nothing to do."""
    if not os.path.exists(_failure_path(cfg)):
        return
    doc = write_failure_state(cfg)
    if doc and not doc.get('recovered_at'):
        doc['recovered_at'] = utc_ts()
        _write_failure_doc(cfg, doc)


def write_failure_state(cfg):
    """The last audit write failure {failed_at, action, reason, recovered_at,
    current}, or None when there has never been one."""
    try:
        with open(_failure_path(cfg), 'rb') as fh:
            doc = json.loads(fh.read(4096).decode('utf-8'))
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or not doc.get('failed_at'):
        return None
    out = {k: (str(doc[k])[:64] if doc.get(k) else None)
           for k in ('failed_at', 'action', 'reason', 'recovered_at')}
    out['current'] = out['recovered_at'] is None
    return out


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
    probe = _new_record('(pre-check)', 'AUDIT_PRECHECK', 'audit_log', '', '', source=SYSTEM_SOURCE)
    db = None
    try:
        st = os.statvfs(os.path.dirname(_db_path(cfg)) or '.') if hasattr(os, 'statvfs') else None
        if st is not None and st.f_bavail * st.f_frsize < AUDIT_MIN_FREE_BYTES:
            raise OSError('less than %d bytes free for the audit database'
                          % AUDIT_MIN_FREE_BYTES)
        db = get_db(cfg)
        db.execute('BEGIN IMMEDIATE')
        db.execute(_INSERT, _row(probe))
        db.rollback()
    except Exception as exc:
        delivered = write_failed(probe, exc, cfg)
        raise AuditUnavailable(str(exc), delivered) from exc
    finally:
        if db is not None:
            db.close()


def log_action(cfg, user, action, target, detail='', cluster_id='', db=None,
               best_effort=False, source=None, outcome='success'):
    """Write one audit row, and send it to syslog once it is committed.

    With `db`, the row is written on THAT connection inside the caller's open
    transaction and is NOT committed here: the caller commits the change and
    its audit record together, or rolls both back (v1.1.0, settings), and calls
    emit(record) after its commit — a row that is rolled back is never sent.
    Without it, the row gets its own connection and commit, and is emitted.

    A failed write is sent as AUDIT_WRITE_FAILED at CRIT to syslog (with the
    whole record; write_failed reports whether syslog took it, and the
    AuditUnavailable carries that as syslog_delivered), then AuditUnavailable
    is raised — unless `best_effort`, for the
    few records whose action cannot be refused (a failed login is already a
    refusal; a sign-out must never be blocked), which return None instead.
    Returns the record on success.

    v1.3.0: `source` is the client address (default: the request being
    served, or "system" outside one) and `outcome` "success" or "failure".
    """
    record = _new_record(user, action, target, detail, cluster_id, source, outcome)
    _mark_audited()
    own = db is None
    try:
        if own:
            db = get_db(cfg)
        db.execute(_INSERT, _row(record))
        if own:
            db.commit()
    except Exception as exc:
        delivered = write_failed(record, exc, cfg)
        if best_effort:
            return None
        raise AuditUnavailable(str(exc), delivered) from exc
    finally:
        if own and db is not None:
            db.close()
    _note_success(cfg)
    if own:
        emit(record)
    return record


def get_audit_log(cfg, page=1, per_page=50):
    db = get_db(cfg)
    offset = (page - 1) * per_page
    rows = db.execute(
        'SELECT id, ts, user, action, target, detail, cluster_id, source, outcome '
        'FROM audit_log ORDER BY id DESC LIMIT ? OFFSET ?',
        (per_page, offset)
    ).fetchall()
    total = db.execute(_COUNT_SQL).fetchone()[0]
    db.close()
    return {
        'entries': [
            {'id': r[0], 'ts': r[1], 'user': r[2], 'action': r[3],
             'target': r[4], 'detail': r[5], 'cluster_id': r[6],
             'source': r[7], 'outcome': r[8]}
            for r in rows
        ],
        'total': total,
        'page': page,
        'per_page': per_page,
        'pages': max(1, (total + per_page - 1) // per_page),
    }


_COUNT_SQL = 'SELECT COUNT(*) FROM audit_log'

#: The export's columns. v1.3.0 APPENDS source and outcome, so a consumer that
#: reads the v1.2 columns by position still finds them where they were; the
#: timestamp column is ISO 8601 UTC with "Z" (TS_FORMAT).
CSV_HEADER = ('timestamp', 'user', 'action', 'target', 'detail', 'cluster_id', 'source', 'outcome')


def count_rows(cfg):
    db = get_db(cfg)
    try:
        return db.execute(_COUNT_SQL).fetchone()[0]
    finally:
        db.close()


def export_audit_csv(cfg):
    db = get_db(cfg)
    rows = db.execute(
        'SELECT ts, user, action, target, detail, cluster_id, source, outcome '
        'FROM audit_log ORDER BY id DESC'
    ).fetchall()
    db.close()
    buf = io.StringIO()
    writer = csv.writer(buf, quoting=csv.QUOTE_ALL, lineterminator='\n')
    writer.writerow(list(CSV_HEADER))
    for r in rows:
        writer.writerow([_csv_safe(c) for c in r])
    return buf.getvalue()


# ── v1.3.0 schema migration (DQ6, James 2026-10-02) ──────────────────────────
# Two new columns, source and outcome, and every stored ts rewritten from
# "YYYY-MM-DD HH:MM:SS" (UTC, unmarked) to TS_FORMAT — ALL IN ONE TRANSACTION
# with the AUDIT_SCHEMA_MIGRATED row that records it. A half-done rewrite is
# the hazard the scout named: tm/audit_retention.py prunes with `ts < cutoff`
# as STRINGS, and " " sorts before "T", so a column holding both formats
# prunes the wrong rows on the cutoff's own day. Either every row is rewritten
# or none is. Idempotent: init_db runs it at every start, in every worker, and
# BEGIN IMMEDIATE makes them take turns; the second finds nothing to do.
OLD_TS_GLOB = ('[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] '
               '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
#: Before v1.3.0 these five recorded the client address in TARGET; it is
#: copied into source for them. Every other old row's origin was never
#: recorded, and says so ("unrecorded") rather than guessing.
ADDRESS_IN_TARGET = ('LOGIN', 'LOGIN_FAILED', 'LOGIN_REFUSED', 'LOGOUT', 'SESSION_EXPIRED')
#: Old rows whose action word meant a failure. SYSTEM_APPLY_RESULT carried its
#: state in the detail ("state=ok"); every other old action was a success.
FAILURE_ACTIONS = ('LOGIN_FAILED', 'LOGIN_REFUSED', 'SERVICE_RESTART_THROTTLED',
                   'SERVICE_RESTART_REFUSED')
UNRECORDED_SOURCE = 'unrecorded'


def migrate_schema(cfg, db):
    """Bring audit_log to the v1.3.0 shape on `db` (an open connection with
    no transaction in progress). Returns the AUDIT_SCHEMA_MIGRATED record,
    COMMITTED, for the caller to emit() — or None when there was nothing to do.
    On any failure nothing is changed and the exception propagates: the
    service does not start on an audit table it could not migrate."""
    db.execute('BEGIN IMMEDIATE')
    try:
        cols = {r[1] for r in db.execute('PRAGMA table_info(audit_log)').fetchall()}
        added = [c for c in ('source', 'outcome') if c not in cols]
        for c in added:
            db.execute("ALTER TABLE audit_log ADD COLUMN %s TEXT NOT NULL DEFAULT ''" % c)
        rewritten = db.execute(
            "UPDATE audit_log SET ts = substr(ts, 1, 10) || 'T' || substr(ts, 12, 8) || 'Z' "
            'WHERE ts GLOB ?', (OLD_TS_GLOB,)).rowcount
        marks = ','.join('?' * len(ADDRESS_IN_TARGET))
        backfilled = 0
        if 'source' in added:
            db.execute("UPDATE audit_log SET source = target WHERE source = '' AND action IN (%s)"
                       % marks, ADDRESS_IN_TARGET)
            backfilled = db.execute("UPDATE audit_log SET source = ? WHERE source = ''",
                                    (UNRECORDED_SOURCE,)).rowcount
        if 'outcome' in added:
            db.execute("UPDATE audit_log SET outcome = 'failure' WHERE outcome = '' AND action IN (%s)"
                       % ','.join('?' * len(FAILURE_ACTIONS)), FAILURE_ACTIONS)
            db.execute("UPDATE audit_log SET outcome = CASE WHEN detail LIKE '% state=ok %' "
                       "THEN 'success' ELSE 'failure' END "
                       "WHERE outcome = '' AND action = 'SYSTEM_APPLY_RESULT'")
            db.execute("UPDATE audit_log SET outcome = 'success' WHERE outcome = ''")
        record = None
        if added or rewritten:
            total = db.execute(_COUNT_SQL).fetchone()[0]
            detail = ('audit_log v1.3.0: columns added: %s; %d timestamp(s) rewritten to ISO 8601 '
                      'UTC (Z); %d older row(s) have no recorded source (%s); outcome of older '
                      'rows inferred from the action; %d row(s) in the table'
                      % (', '.join(added) or 'none', rewritten, backfilled, UNRECORDED_SOURCE,
                         total))
            record = log_action(cfg, SYSTEM_SOURCE, 'AUDIT_SCHEMA_MIGRATED', 'audit_log',
                                detail, '', db=db, source=SYSTEM_SOURCE)
        db.commit()
    except Exception:
        db.rollback()
        raise
    return record
