"""
"Apply to host" — the unprivileged half (v1.2.0).

The application runs as `topic-manager` under NoNewPrivileges and cannot
change /etc. OS changes therefore cross ONE privilege boundary, the same way
the restart control does (tm/service_control.py):

  1. this module writes the SAVED settings for one domain to a staging file,
       /opt/topic-manager/data/apply/<domain>.json   (0600, the service's own)
     plus, for tls, the certificate, key and chain beside it;
  2. it asks systemd (over D-Bus, authorised by the polkit rule) to START the
     fixed one-shot unit topic-manager-apply-<domain>.service;
  3. that unit runs the root helper /usr/libexec/topic-manager/tm-apply, which
     re-validates every value against its own root-owned copy of the rules,
     renders, tests, backs up, installs, reloads, verifies and rolls back, and
     writes its verdict to
       /run/topic-manager-apply/<domain>.result      (root 0644)
     — a directory the service account cannot write, so a result can never be
     forged by the side that asked for it.

Nothing here runs as root and nothing here decides whether a change is safe:
the helper decides. This module only stages, starts and reads.

The same module is the installer's and the upgrade's way to re-apply what is
saved in tm.db (run as the service account):
    python -m tm.apply stage all --by installer
    python -m tm.apply seed syslog_host=logs.example.org ...
    python -m tm.apply get http_redirect_enabled

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import argparse
import hashlib
import json
import logging
import os
import secrets
import sys
import time
from datetime import datetime, timezone

from . import audit, settings_schema, service_control
from .models import get_db, init_db

log = logging.getLogger(__name__)

APPLY_DOMAINS = ('syslog', 'time', 'nginx')          # POST /api/system/apply/<d>
STATUS_DOMAINS = APPLY_DOMAINS + ('tls',)            # GET  /api/system/apply/<d>
STATES = ('idle', 'queued', 'running', 'ok', 'failed', 'rolled_back')
FINAL_STATES = ('ok', 'failed', 'rolled_back')

#: How long a requested job may stay without a result before the status says
#: so. The UI polls for 90 s (contract); the helper's own steps are bounded
#: well inside that.
STALE_AFTER_S = 120

RESULT_DIR_DEFAULT = '/run/topic-manager-apply'
STAGE_MAX_BYTES = 16 * 1024

#: The two app_settings statements this module repeats, defined once.
_SELECT_SETTING = 'SELECT value FROM app_settings WHERE key = ?'
_UPSERT_SETTING = 'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)'


def stage_dir(cfg):
    db_path = cfg.get('audit', {}).get('db_path', '/opt/topic-manager/data/tm.db')
    return os.path.join(os.path.dirname(db_path) or '.', 'apply')


def result_dir():
    return os.environ.get('TM_APPLY_RESULT_DIR', RESULT_DIR_DEFAULT)


def _now():
    return datetime.now(timezone.utc)


def _stage_name(domain, suffix):
    """<domain>.<suffix>: the one naming rule for every staging file."""
    return '%s.%s' % (domain, suffix)


def _ensure_stage_dir(cfg):
    d = stage_dir(cfg)
    os.makedirs(d, mode=0o700, exist_ok=True)
    st = os.lstat(d)
    if not os.path.isdir(d) or os.path.islink(d):
        raise OSError('%s is not a directory' % d)
    if st.st_mode & 0o077:
        os.chmod(d, 0o700)
    return d


def _write_private(directory, name, data):
    """Write `data` to directory/name, 0600 from creation, never through a
    symlink: the old file is unlinked and the new one created O_EXCL."""
    path = os.path.join(directory, name)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0),
                 0o600)
    try:
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            view = view[n:]
    finally:
        os.close(fd)
    return path


def _read_json(path, limit=STAGE_MAX_BYTES):
    try:
        with open(path, 'rb') as fh:
            data = fh.read(limit + 1)
    except OSError:
        return None
    if len(data) > limit:
        return None
    try:
        doc = json.loads(data.decode('utf-8'))
    except (ValueError, UnicodeDecodeError):
        return None
    return doc if isinstance(doc, dict) else None


def new_job():
    return secrets.token_hex(8)


def domain_settings(db, domain):
    keys = settings_schema.DOMAIN_KEYS[domain]
    return settings_schema.read_admin(db, keys)


def write_stage(cfg, domain, settings, user, files=None):
    """Stage one domain for the helper. `files` (tls only) maps a staging
    suffix ('crt', 'key', 'chain') to bytes; their SHA-256 go into the job
    document so the helper can tell a complete set from a mixed one. The job
    document is written LAST: its presence means the set is complete.
    Returns the job id."""
    if domain not in STATUS_DOMAINS:
        raise ValueError('unknown domain %r' % domain)
    d = _ensure_stage_dir(cfg)
    job = new_job()
    doc = {'domain': domain, 'job': job, 'requested_by': str(user)[:128],
           'requested_at': _now().isoformat(), 'settings': dict(settings or {}),
           'files': {}}
    for suffix, blob in sorted((files or {}).items()):
        _write_private(d, _stage_name(domain, suffix), blob)
        doc['files'][suffix] = hashlib.sha256(blob).hexdigest()
    _write_private(d, _stage_name(domain, 'json'), json.dumps(doc, sort_keys=True).encode('utf-8'))
    # The app's own record of the latest request: the helper deletes the
    # staging files once it has read them, and the status needs to know which
    # job to wait for.
    _write_private(d, _stage_name(domain, 'last'), json.dumps(
        {'job': job, 'requested_at': doc['requested_at'],
         'requested_by': doc['requested_by']}).encode('utf-8'))
    return job


def discard_stage(cfg, domain):
    """Remove every staging file for `domain` (a request that was refused
    after staging — e.g. its audit record could not be written)."""
    d = stage_dir(cfg)
    for suffix in ('json', 'crt', 'key', 'chain', 'last'):
        try:
            os.unlink(os.path.join(d, _stage_name(domain, suffix)))
        except FileNotFoundError:
            pass


def read_result(domain):
    return _read_json(os.path.join(result_dir(), '%s.result' % domain), 64 * 1024)


def _parse_iso(value):
    try:
        return datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None


APPLY_MIN_INTERVAL_S = 5
_APPLIED_KEY = 'apply_applied_%s'
_FINAL_KEY = 'apply_final_%s'


def _final(cfg, domain):
    db = get_db(cfg)
    try:
        row = db.execute(_SELECT_SETTING,
                         (_FINAL_KEY % domain,)).fetchone()
    finally:
        db.close()
    try:
        doc = json.loads(row[0]) if row else None
    except (TypeError, ValueError):
        doc = None
    return doc if isinstance(doc, dict) else None


def claim_slot(cfg, domain, now=None):
    """One apply request per domain per APPLY_MIN_INTERVAL_S, across all
    workers — the same single-UPSERT claim as the restart control
    (tm/service_control.claim_restart_slot), and for the same reason: each
    request is a `systemctl start`, and systemd's start limiter (5 in 10 s)
    refuses a unit outright once tripped. Returns (allowed, seconds_left)."""
    now = time.time() if now is None else now
    key = 'apply_last_epoch_%s' % domain
    db = get_db(cfg)
    try:
        cur = db.execute(
            'INSERT INTO app_settings (key, value) VALUES (?, ?) '
            'ON CONFLICT(key) DO UPDATE SET value = excluded.value '
            '  WHERE CAST(excluded.value AS REAL) - CAST(app_settings.value AS REAL) >= ?',
            (key, '%.6f' % now, APPLY_MIN_INTERVAL_S))
        claimed = cur.rowcount == 1
        db.commit()
        if claimed:
            return True, 0.0
        row = db.execute(_SELECT_SETTING, (key,)).fetchone()
    finally:
        db.close()
    try:
        last = float(row[0]) if row and row[0] is not None else now
    except ValueError:
        last = now
    remaining = APPLY_MIN_INTERVAL_S - (now - last)
    return False, remaining if remaining > 0 else float(APPLY_MIN_INTERVAL_S)


def record_start_failure(cfg, domain, job, detail):
    """The unit could not be started, so no result will ever arrive for this
    job: say so in the app's own request record, and the status reports it
    at once instead of after STALE_AFTER_S."""
    d = stage_dir(cfg)
    try:
        os.unlink(os.path.join(d, _stage_name(domain, 'json')))
    except FileNotFoundError:
        pass
    for suffix in ('crt', 'key', 'chain'):
        try:
            os.unlink(os.path.join(d, _stage_name(domain, suffix)))
        except FileNotFoundError:
            pass
    last = _read_json(os.path.join(d, _stage_name(domain, 'last'))) or {'job': job}
    last['start_error'] = str(detail)[:500]
    _write_private(d, _stage_name(domain, 'last'), json.dumps(last).encode('utf-8'))


def applied(cfg, domain):
    """(values, applied_at) last applied SUCCESSFULLY to the host for `domain`,
    or (None, None). Contract CC-1: the PPSM export shows these LIVE values,
    never the merely saved settings. They come from the root helper's own
    result (what it rendered and verified) and are kept in tm.db, because the
    result file lives on /run and does not survive a reboot."""
    db = get_db(cfg)
    try:
        row = db.execute(_SELECT_SETTING,
                         (_APPLIED_KEY % domain,)).fetchone()
    finally:
        db.close()
    if not row:
        return None, None
    try:
        doc = json.loads(row[0])
        return (doc.get('values') if isinstance(doc.get('values'), dict) else None,
                doc.get('at'))
    except (TypeError, ValueError):
        return None, None


def status(cfg, domain):
    """The GET /api/system/apply/<domain> document."""
    last = _read_json(os.path.join(stage_dir(cfg), _stage_name(domain, 'last')))
    res = read_result(domain)
    values, at = applied(cfg, domain)
    doc = {'domain': domain, 'state': 'idle', 'finished_at': None,
           'message': '', 'details': [], 'applied': values, 'applied_at': at}
    if res and (not last or res.get('job') == last.get('job') or _refused_after(res, last)):
        return _from_result(doc, res)
    if not last:
        return doc
    return _pending(cfg, domain, last, doc)


def _refused_after(res, last):
    """A result with NO job is the helper refusing a staging file it would not
    read (a symlink, a wrong owner, bad JSON): it could not learn the job id,
    so it is matched by time — a refusal written after this request was made
    is this request's answer."""
    return (res.get('job') is None and last and res.get('finished_at')
            and _parse_iso(res.get('finished_at')) and _parse_iso(last.get('requested_at'))
            and _parse_iso(res['finished_at']) >= _parse_iso(last['requested_at']))


def _from_result(doc, res):
    """The status document for a result the helper wrote for this request."""
    state = res.get('state') if res.get('state') in STATES else 'failed'
    doc.update(state=state, finished_at=res.get('finished_at'),
               message=str(res.get('message', ''))[:2000],
               details=[str(x)[:500] for x in (res.get('details') or [])][:50])
    if 'job' in res:
        doc['job'] = res['job']
    return doc


def _pending(cfg, domain, last, doc):
    """The status document for a request with no result file of its own: the
    verdict kept in tm.db, a start failure, a running unit, a stale request,
    or still queued."""
    doc['job'] = last.get('job')
    final = _final(cfg, domain)
    if final and final.get('job') == last.get('job') and final.get('state') in FINAL_STATES:
        doc.update(state=final['state'], finished_at=final.get('finished_at'),
                   message=str(final.get('message', '')), details=list(final.get('details') or []))
        return doc
    if last.get('start_error'):
        doc.update(state='failed', message='the apply unit could not be started: %s'
                   % str(last['start_error'])[:500])
        return doc
    active = service_control.apply_unit_state(domain)
    if active in ('activating', 'active', 'reloading'):
        doc.update(state='running', message='the apply helper is running')
        return doc
    requested = _parse_iso(last.get('requested_at'))
    age = (_now() - requested).total_seconds() if requested else None
    if age is not None and age > STALE_AFTER_S:
        doc.update(state='failed', message=(
            'no result was written for this request %d s after it was made. The '
            'unit may not have started; see: journalctl -u %s'
            % (int(age), service_control.apply_unit(domain))))
        return doc
    doc.update(state='queued', message='waiting for the apply unit to start')
    return doc


def audit_result(cfg, domain):
    """Record SYSTEM_APPLY_RESULT (and TLS_CERT_REPLACED for a successful tls
    apply) ONCE per finished job, and on success store what the helper says
    it applied (CC-1). The claim, the audit rows and the applied values are
    ONE transaction, so a failed audit write leaves the job unclaimed and the
    next status read tries again; four workers polling cannot record it twice."""
    res = read_result(domain)
    if not res or res.get('state') not in FINAL_STATES or not res.get('job'):
        return False
    job = str(res['job'])[:32]
    key = 'apply_audited_%s' % domain
    by = str(res.get('requested_by') or 'system')[:128]
    records = []
    db = get_db(cfg)
    try:
        db.execute('BEGIN IMMEDIATE')
        cur = db.execute(
            'INSERT INTO app_settings (key, value) VALUES (?, ?) '
            'ON CONFLICT(key) DO UPDATE SET value = excluded.value '
            '  WHERE app_settings.value != excluded.value', (key, job))
        if cur.rowcount != 1:
            db.rollback()
            return False
        detail = 'job=%s state=%s step=%s: %s' % (
            job, res.get('state'), str(res.get('step', ''))[:40],
            str(res.get('message', ''))[:300])
        records.append(audit.log_action(cfg, by, 'SYSTEM_APPLY_RESULT', domain, detail,
                                        '', db=db))
        # The verdict itself, kept: the result file is on /run and a reboot
        # would otherwise turn a finished job back into "queued".
        db.execute(_UPSERT_SETTING,
                   (_FINAL_KEY % domain, json.dumps({
                       'job': job, 'state': res.get('state'),
                       'finished_at': res.get('finished_at'),
                       'message': str(res.get('message', ''))[:2000],
                       'details': [str(x)[:500] for x in (res.get('details') or [])][:50]},
                       sort_keys=True)))
        done = res.get('applied')
        if res.get('state') == 'ok' and isinstance(done, dict):
            db.execute(_UPSERT_SETTING,
                       (_APPLIED_KEY % domain, json.dumps(
                           {'values': {str(k)[:64]: str(v)[:512] for k, v in done.items()},
                            'at': res.get('finished_at'), 'job': job}, sort_keys=True)))
        if domain == 'tls' and res.get('state') == 'ok':
            cert = done if isinstance(done, dict) else {}
            records.append(audit.log_action(
                cfg, by, 'TLS_CERT_REPLACED', 'nginx server certificate',
                ('job=%s key_type=%s not_after=%s chain=%s'
                 % (job, cert.get('key_type', '?'), cert.get('not_after', '?'),
                    cert.get('chain_count', '?')))[:400], '', db=db))
        db.commit()
    except Exception:
        db.rollback()
        log.exception('could not record the %s apply result; it will be retried', domain)
        return False
    finally:
        db.close()
    for r in records:
        audit.emit(r)
    return True


def audit_all_results(cfg):
    for d in STATUS_DOMAINS:
        try:
            audit_result(cfg, d)
        except Exception:
            log.exception('apply result audit for %s failed', d)


# ── CLI: the installer and the upgrade, running as the service account ───────

def _cli_seed(cfg, pairs, by):
    values = {}
    for p in pairs:
        k, sep, v = p.partition('=')
        if not sep:
            raise SystemExit('seed: expected key=value, got %r' % p)
        try:
            values[k] = settings_schema.normalise(k, v)
        except settings_schema.InvalidSetting as exc:
            raise SystemExit('seed: %s' % exc)
    if not values:
        return 0
    db = get_db(cfg)
    try:
        db.execute('BEGIN IMMEDIATE')
        for k, v in values.items():
            db.execute(_UPSERT_SETTING, (k, v))
        detail = 'changed: %s' % '; '.join('%s -> %r' % (k, v) for k, v in sorted(values.items()))
        rec = audit.log_action(cfg, by, 'SETTINGS_UPDATE', 'app_settings', detail[:500], '', db=db)
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
    audit.emit(rec)
    print('seeded: %s' % ', '.join(sorted(values)))
    return 0


def _cli_stage(cfg, domains, by):
    for domain in domains:
        db = get_db(cfg)
        try:
            vals = domain_settings(db, domain)
        finally:
            db.close()
        problems = settings_schema.check_domain(domain, vals)
        if problems:
            raise SystemExit('stage %s: %s' % (domain, '; '.join(problems)))
        job = write_stage(cfg, domain, vals, by)
        try:
            audit.log_action(cfg, by, 'SYSTEM_APPLY_REQUESTED', domain, 'job=%s' % job)
        except audit.AuditUnavailable as exc:
            # The request is withdrawn: a change whose audit record cannot be
            # written does not happen, whoever asks for it.
            discard_stage(cfg, domain)
            raise SystemExit('stage %s: the audit record could not be written (%s); '
                             'nothing was staged' % (domain, exc))
        print('%s %s' % (domain, job))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog='python -m tm.apply')
    ap.add_argument('--config', default=None)
    ap.add_argument('--by', default='installer', help='the name recorded in the audit trail')
    sub = ap.add_subparsers(dest='cmd', required=True)
    s1 = sub.add_parser('stage')
    s1.add_argument('domain', choices=APPLY_DOMAINS + ('all',))
    s2 = sub.add_parser('seed')
    s2.add_argument('pairs', nargs='*')
    s3 = sub.add_parser('get')
    s3.add_argument('key')
    s4 = sub.add_parser('result')
    s4.add_argument('domain', choices=STATUS_DOMAINS)
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.WARNING, format='%(levelname)s %(message)s')
    from .config import load_config
    cfg = load_config(args.config)
    init_db(cfg)
    if args.cmd == 'seed':
        return _cli_seed(cfg, args.pairs, args.by)
    if args.cmd == 'stage':
        return _cli_stage(cfg, APPLY_DOMAINS if args.domain == 'all' else (args.domain,), args.by)
    if args.cmd == 'get':
        if args.key not in settings_schema.ADMIN_KEYS:
            raise SystemExit('get: %r is not an administrator setting' % args.key)
        db = get_db(cfg)
        try:
            print(settings_schema.read_admin(db, [args.key])[args.key])
        finally:
            db.close()
        return 0
    if args.cmd == 'result':
        audit_result(cfg, args.domain)
        print(json.dumps(status(cfg, args.domain)))
        return 0
    return 2


if __name__ == '__main__':
    sys.exit(main())
