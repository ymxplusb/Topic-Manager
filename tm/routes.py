import hashlib
import io
import math
import os
import re
import logging
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from functools import wraps
from flask import Blueprint, request, jsonify, session, current_app, make_response, g
from werkzeug.formparser import parse_form_data

from . import auth, kafka_client, audit, service_control, settings_schema
from . import apply as apply_mod
from . import audit_retention, compliance, hoststatus, tls_check
from . import clusters as cluster_store
from .models import (get_db, create_session, touch_session,
                     delete_session, count_active_sessions, cleanup_expired_sessions,
                     session_state, session_absolute_end, session_verification,
                     mark_verified, end_sessions, list_all_active_sessions,
                     session_handle, END_REASONS)
from .config import (load_config, get_active_cluster, get_cluster_by_id,
                     DEFAULT_SESSION_TIMEOUT_MINUTES)

bp = Blueprint('api', __name__, url_prefix='/api')

TM_VERSION = open(os.path.join(os.path.dirname(__file__), 'VERSION')).read().strip()

log = logging.getLogger(__name__)

# Kafka topic config keys that may be written by users. Read-only and
# internal keys (e.g. leader.epoch, segment.jitter.ms internals) are omitted.
_ALLOWED_TOPIC_CONFIGS = {
    'cleanup.policy', 'compression.type', 'delete.retention.ms',
    'file.delete.delay.ms', 'flush.messages', 'flush.ms',
    'follower.replication.throttled.replicas', 'index.interval.bytes',
    'leader.replication.throttled.replicas', 'local.retention.bytes',
    'local.retention.ms', 'max.compaction.lag.ms', 'max.message.bytes',
    'message.downconversion.enable', 'message.timestamp.difference.max.ms',
    'message.timestamp.type', 'min.cleanable.dirty.ratio',
    'min.compaction.lag.ms', 'min.insync.replicas', 'preallocate',
    'retention.bytes', 'retention.ms', 'segment.bytes', 'segment.index.bytes',
    'segment.jitter.ms', 'segment.ms', 'unclean.leader.election.enable',
}

_MAX_PARTITIONS = 1000
_MAX_RF = 9


# ── helpers ───────────────────────────────────────────────────────
def _cfg():
    # Re-reads on change rather than returning a dict frozen at create_app.
    # app.config['TM_CONFIG'] used to hold that frozen dict, so a cluster edit
    # stayed invisible to all four gunicorn workers until a restart — and
    # invalidating tm/config.py's module cache alone fixed exactly one of them.
    return load_config(current_app.config['TM_CONFIG_PATH'])

def _timeout():
    return _cfg().get('session', {}).get('timeout_minutes',
                                        DEFAULT_SESSION_TIMEOUT_MINUTES)

#: The reasons a session may END, and the sentence each one writes into the
#: audit trail. A closed vocabulary because the value arrives from the browser;
#: see the logout route. '' (no reason sent) is the pre-v1.0.6 client and the
#: Sign out button, both of which are genuinely explicit.
_LOGOUT_REASONS = {
    '':         'explicit sign-out',
    'explicit': 'explicit sign-out',
    'idle':     'automatic sign-out after the idle timeout',
    'absolute': 'automatic sign-out at the absolute session lifetime',
}


def _absolute_hours(db):
    # v1.3.0 (SRG-APP-000295, DQ8): Settings > Security > Sessions, default 12.
    return settings_schema.int_setting(
        settings_schema.read_admin(db, ['session_absolute_hours']), 'session_absolute_hours')


def _max_sessions(db):
    # v1.2.0: Settings > Security > Sessions, not config.yaml. config.yaml
    # seeds the setting once (tm/settings_schema.seed_session_limit); after
    # that the stored value wins. Owner ruling 2026-09-26.
    return settings_schema.int_setting(
        settings_schema.read_admin(db, [settings_schema.SESSION_KEY]),
        settings_schema.SESSION_KEY)


# ── audit fail-closed (v1.2.0, owner ruling 2026-09-26) ───────────────────
# An action whose audit record cannot be written does not happen. Routes that
# change something that cannot be taken back (Kafka, the cluster store, the
# host) PROVE the audit trail is writable before they act (audit_gate), and
# refuse with 503 when it is not. If the record still fails AFTER the change —
# the database broke in between — the response says the change WAS made, and
# where its AUDIT_WRITE_FAILED record went: the host syslog at CRIT when that
# accepted it, otherwise only the service log (_where_the_record_went).

def _where_the_record_went(exc):
    """Where the failed record actually went — never a guess (round 4,
    sec-review TM-SEC-006): audit.write_failed says whether syslog took it."""
    if getattr(exc, 'syslog_delivered', False):
        return ('The record was sent to the host syslog as AUDIT_WRITE_FAILED (CRIT).')
    return ('The host syslog did NOT accept the record either: its only copy is the '
            'AUDIT_WRITE_FAILED line in the service log (journalctl -u topic-manager).')


def _audit_unavailable(exc=None):
    return jsonify({
        'error': 'audit_unavailable',
        'message': ('The audit trail cannot be written, so nothing was changed. '
                    'An administrator must check the audit database. '
                    + _where_the_record_went(exc)),
    }), 503


def _audit_failed_after(what, exc=None):
    return jsonify({
        'error': 'audit_write_failed',
        'message': ('%s WAS made, but its audit record could not be written to '
                    'the audit database. %s Check the audit database before '
                    'making any further change.' % (what, _where_the_record_went(exc))),
    }), 500


def audit_gate(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        try:
            audit.require_writable(_cfg())
        except audit.AuditUnavailable as exc:
            return _audit_unavailable(exc)
        return f(*args, **kwargs)
    return decorated


_CONTROL_CHARS = re.compile(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]')


def _log_safe(value, limit=64):
    '''A client-supplied string made safe for ONE log line or audit field:
    control characters (CR/LF included, so no forged log lines) become "?",
    and the length is bounded. Round 2, sec-review.'''
    return _CONTROL_CHARS.sub('?', str(value))[:limit]


class NoClusterError(ValueError):
    """No usable cluster profile. Its message is the product's own sentence
    and safe to show; a Kafka library error is not (SRG-APP-000266)."""


def _cluster(cluster_id=None):
    cfg = _cfg()
    if cluster_id:
        c = get_cluster_by_id(cfg, cluster_id)
    else:
        cid = request.args.get('cluster') or session.get('active_cluster')
        c = get_cluster_by_id(cfg, cid) if cid else get_active_cluster(cfg)
    if not c:
        # v1.1.0: a fresh install starts with NO cluster profiles (the example
        # file is documentation, not an install input), so "none configured"
        # is now the first thing a new operator sees. Say what to do.
        if not cfg.get('clusters'):
            raise NoClusterError('No cluster profile is configured yet. Add one in '
                                 'Settings > General > Cluster Profiles.')
        raise NoClusterError('No cluster configured or cluster not found')
    if c.get('disabled'):
        raise NoClusterError('Cluster %s is disabled: %s' % (c.get('id'), c['disabled']))
    return c


# ── error hygiene (v1.3.0, SRG-APP-000266) ──────────────────────────────────
# Every Kafka route used to answer `{"error": str(exc)}`: broker host names and
# addresses, the client library's own text, whatever the cluster said. The
# browser now gets one sentence and a short reference; the exception goes to
# the service log under that reference, where an administrator reads it.
KAFKA_FAILED_MESSAGE = ('The Kafka cluster refused the request or did not answer. The details '
                        'are in the service log (journalctl -u topic-manager) under reference %s.')


def _kafka_failure(what, exc):
    """Log `exc` server-side under a fresh reference; returns the reference."""
    ref = secrets.token_hex(4)
    log.warning('%s failed [ref %s]: %s: %s', what, ref, type(exc).__name__,
                _log_safe(str(exc), 1000))
    return ref


def _kafka_error_response(what, exc):
    if isinstance(exc, NoClusterError):
        return jsonify({'error': str(exc), 'code': 'no_cluster'}), 502
    ref = _kafka_failure(what, exc)
    return jsonify({'error': KAFKA_FAILED_MESSAGE % ref, 'code': 'kafka_error',
                    'reference': ref}), 502


def _write_cluster():
    """(cluster, None) for a write route, or (None, a 409 refusal) when there
    is no usable profile. Before v1.3.0 the lookup sat outside the routes'
    try blocks, so a missing profile was an unhandled 500."""
    try:
        return _cluster(), None
    except NoClusterError as exc:
        return None, (jsonify({'error': str(exc), 'code': 'no_cluster'}), 409)


# ── helpers ───────────────────────────────────────────────────────
def _parse_json_body():
    """Return parsed JSON body, or abort 415/400 if Content-Type or body is wrong."""
    if not request.is_json:
        return None, (jsonify({'error': 'Content-Type must be application/json'}), 415)
    data = request.get_json(silent=True)
    if data is None:
        return None, (jsonify({'error': 'Invalid or empty JSON body'}), 400)
    return data, None


# ── cross-site request forgery (v1.2.0 round 4, sec-review CWE-352) ──────
# A state-changing request is accepted only when the browser says it came from
# this origin (Sec-Fetch-Site: same-origin) or it carries X-TM-Request: 1,
# which app/main.js adds to every non-GET request the SPA makes. A custom
# header cannot be sent cross-origin without a CORS preflight, and this API
# answers no preflight, so another site can send neither.
#
# The old rule refused only Sec-Fetch-Site: cross-site and only in
# require_auth. That let through a SAME-SITE sibling (another host under the
# same registrable domain), a browser that sends no Fetch Metadata, and, on the
# multipart certificate upload, a plain HTML form: the JSON Content-Type rule
# that protects the other routes cannot apply to multipart/form-data, and a
# form post can be multipart. Tooling (curl) sends the header too.
_SAFE_METHODS = frozenset({'GET', 'HEAD', 'OPTIONS'})
CSRF_HEADER = 'X-TM-Request'


@bp.before_request
def _refuse_cross_site():
    if request.method in _SAFE_METHODS:
        return None
    fetch_site = request.headers.get('Sec-Fetch-Site')
    if fetch_site == 'same-origin':
        return None
    if fetch_site is None and request.headers.get(CSRF_HEADER) == '1':
        return None
    return jsonify({'error': 'Cross-site requests are not permitted', 'code': 'cross_site',
                    'message': 'A request that changes something must come from this site '
                               '(Sec-Fetch-Site: same-origin) or carry %s: 1.' % CSRF_HEADER}), 403


# ── unsuccessful events (v1.3.0, SRG-APP-000089/000099, DQ7) ───────────────
# A SIGNED-IN caller's refused write is an audit event: a Kafka 502, a 400
# validation refusal, a 409, a CSRF 403 — whatever the route. Routes that
# record their own failure (the Kafka writes, the restart refusals) set
# g.tm_audited through audit.log_action and are not recorded twice; every
# other refused write is recorded here as REQUEST_REFUSED, outcome failure.
#
# An ANONYMOUS caller's refusal never reaches tm.db (James 2026-10-02): it is
# attacker-generatable, and the table is the audit trail, not a request log.
# It goes to the service log through a per-worker limiter, and to nginx's
# access log as every request does. Failed SIGN-INS are the exception they
# always were (LOGIN_FAILED, AU-2), and nginx holds those to the login rate.
_UNAUDITABLE = frozenset({'audit_unavailable', 'audit_write_failed'})


class _AnonymousRefusals:
    """At most BURST log lines per WINDOW seconds per worker, then one
    summary line for the rest when the window closes."""
    WINDOW = 60.0
    BURST = 10

    def __init__(self):
        self._lock = threading.Lock()
        self._start = 0.0
        self._count = 0
        self._suppressed = 0

    def note(self, status, method, path, source):
        now = time.monotonic()
        with self._lock:
            summary = None
            if now - self._start >= self.WINDOW:
                summary, self._suppressed = self._suppressed, 0
                self._start, self._count = now, 0
            self._count += 1
            logged = self._count <= self.BURST
            if not logged:
                self._suppressed += 1
        if summary:
            log.warning('ANON_REQUEST_REFUSED: %d more refused anonymous request(s) in the '
                        'last %d s were not logged one by one', summary, int(self.WINDOW))
        if logged:
            log.warning('ANON_REQUEST_REFUSED status=%d method=%s path=%s source=%s', status,
                        _log_safe(method, 8), _log_safe(path, 120), _log_safe(source, 64))
        return logged


_ANON_REFUSALS = _AnonymousRefusals()


def _signed_in_user():
    """The user of a VALID session on this request, or None. require_auth
    sets request.current_user; a request refused before it ran (a CSRF 403)
    is judged by its session row here."""
    user = getattr(request, 'current_user', None)
    if user:
        return user.get('username')
    sid = session.get('sid')
    if not sid:
        return None
    db = get_db(_cfg())
    try:
        username, reason = session_state(db, sid, _absolute_hours(db))
    finally:
        db.close()
    return username if reason is None else None


def _refusal_detail(response):
    data = response.get_json(silent=True) if response.is_json else None
    data = data if isinstance(data, dict) else {}
    what = data.get('code') or data.get('error') or data.get('reason') or ''
    return _log_safe(str(what), 160), data.get('error')


@bp.after_request
def _record_refusals(response):
    if response.status_code < 400 or not request.path.startswith('/api/'):
        return response
    try:
        detail, error = _refusal_detail(response)
        unsafe = request.method not in _SAFE_METHODS
        # A refused READ by a signed-in user is neither (require_auth set
        # current_user): not a write, and not anonymous.
        user = _signed_in_user() if unsafe or getattr(request, 'current_user', None) else None
        if user:
            if unsafe and not getattr(g, 'tm_audited', False) and error not in _UNAUDITABLE:
                audit.log_action(_cfg(), user, 'REQUEST_REFUSED', _log_safe(request.path, 200),
                                 '%s %s -> HTTP %d: %s' % (request.method, request.endpoint or '?',
                                                          response.status_code, detail),
                                 '', best_effort=True, outcome='failure')
        else:
            _ANON_REFUSALS.note(response.status_code, request.method, request.path,
                                request.remote_addr or 'unknown')
    except Exception:           # recording a refusal must never change the answer
        log.exception('could not record the refusal of %s %s', request.method, request.path)
    return response


# ── auth decorator ────────────────────────────────────────────────
# All authenticated users are members of the Kafka-Admins AD group —
# group membership is enforced at login time by auth.validate_credentials.
# Every session therefore carries implicit admin rights; require_auth is the
# single gate for all protected routes.
def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        # Cross-site request refusal is bp.before_request (_refuse_cross_site),
        # which runs before this for EVERY route, the public ones included.
        sid = session.get('sid')
        if not sid:
            return jsonify({'error': 'Authentication required'}), 401

        cfg = _cfg()
        db = get_db(cfg)
        try:
            username, reason = session_state(db, sid, _absolute_hours(db))
            refusal = None
            if reason is None:
                refusal = _recheck_group(cfg, db, sid, username)
        finally:
            db.close()
        if reason is not None:
            return _session_ended(cfg, username, reason)
        request.current_user = session.get('user', {})
        if refusal is not None:
            return refusal
        db = get_db(cfg)

        # AN IDLE TIMEOUT THAT BACKGROUND POLLING CANNOT DEFEAT.
        #
        # TopicsTab and ConsumerGroupsTab each auto-refresh every 30
        # seconds. Every one of those refreshes is an authenticated request
        # and every one landed here, so `expires_at` was pushed a further
        # full timeout into the future twice a minute FOR AS LONG AS THE TAB
        # WAS OPEN. The server-side session timeout could therefore only
        # ever fire on a tab that was CLOSED - an unattended browser left on
        # the Topics view held a valid session indefinitely, and changing the
        # timeout from 30 minutes to 15 would not have altered that by one
        # second.
        #
        # A request that says it is a background refresh does not count as
        # activity. Trusting the client here is safe IN THIS DIRECTION and
        # only in this direction: the header can only SHORTEN a session.
        # Omitting it gives exactly the old behaviour, so a caller that
        # forgets it loses nothing an attacker could want, and a caller that
        # forges it expires itself sooner.
        if request.headers.get('X-TM-Background') != '1':
            touch_session(db, sid, _timeout())
        db.close()
        return f(*args, **kwargs)
    return decorated


def _session_ended(cfg, username, reason):
    """The 401 for a session that is no longer valid, recorded with WHY
    (SRG-APP-000295): idle, the absolute lifetime, or what ended it."""
    who = username or session.get('user', {}).get('username', '?')
    audit.log_action(cfg, who, 'SESSION_EXPIRED', request.remote_addr or 'unknown',
                     END_REASONS.get(reason, reason), '', best_effort=True)
    session.clear()
    code = reason if reason in END_REASONS else 'ended'
    return jsonify({'error': 'Session expired', 'reason': code}), 401


# ── the group re-check (v1.3.0, NGNX-APP-003330, DQ8, James 2026-10-02) ──────
# Every GROUP_RECHECK_MINUTES a session's user is looked up again with the
# service account. Removed from required_group, or gone from the directory:
# every session of that user is ended, SESSION_REVOKED is recorded and this
# request is refused. The directory unreachable: the session may still READ,
# and every WRITE is refused (503 directory_unavailable) until a re-check
# succeeds — a removed administrator must not keep write access for the
# length of an outage. The directory is asked at most once a minute per
# session while it is down. Sign-out is never refused.
RECHECK_RETRY = timedelta(seconds=60)
DIRECTORY_UNAVAILABLE_MESSAGE = (
    'The directory could not be reached to re-check your group membership, so changes '
    'are refused until it answers. You can still view everything. Try again in a minute.')
_NEVER_REFUSED = frozenset({'api.logout'})


def _write_refused_for_directory():
    if request.method in _SAFE_METHODS or request.endpoint in _NEVER_REFUSED:
        return None
    return jsonify({'error': DIRECTORY_UNAVAILABLE_MESSAGE, 'code': 'directory_unavailable'}), 503


def _recheck_group(cfg, db, sid, username):
    verified, attempted = session_verification(db, sid)
    now = datetime.now(timezone.utc)
    if verified is not None and now - verified < timedelta(minutes=auth.GROUP_RECHECK_MINUTES):
        return None
    if attempted is not None and now - attempted < RECHECK_RETRY \
            and (verified is None or attempted > verified):
        return _write_refused_for_directory()      # a recent attempt failed
    verdict, detail = auth.check_membership(cfg, username)
    if verdict == 'member':
        mark_verified(db, sid, True)
        return None
    if verdict == 'unsupported':
        return None                                 # reported on the compliance page
    if verdict == 'unavailable':
        mark_verified(db, sid, False)
        log.warning('group re-check for user=%s: directory unavailable (%s); writes are '
                    'refused until it answers', _log_safe(username), _log_safe(detail, 300))
        return _write_refused_for_directory()
    ended = end_sessions(db, 'revoked: %s' % detail, user=username)
    audit.log_action(cfg, username, 'SESSION_REVOKED', request.remote_addr or 'unknown',
                     '%s; %d session(s) ended' % (detail, ended), '', best_effort=True,
                     outcome='success')
    session.clear()
    return jsonify({'error': 'Your access was withdrawn: %s.' % detail, 'reason': 'revoked'}), 401


# ── health ────────────────────────────────────────────────────────
@bp.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok', 'version': TM_VERSION})


# ── auth ──────────────────────────────────────────────────────────
LOGIN_FAILED_MESSAGE = 'Sign-in failed: the user name or password is wrong, or this account may not use Topic Manager.'

# ── the consent notice, enforced by the server (v1.3.0, NGNX-APP-000180, DQ9) ─
# The sign-in page shows the notice (the standard DoD wording, or the
# operator's own text from Settings) and the browser posts the acceptance
# here. It is held in the signed session cookie, and POST /api/auth/login
# refuses a sign-in without a fresh one while the notice is on: nothing but
# the public pages answers before the notice has been accepted. The
# acceptance is recorded as CONSENT_ACCEPTED, for the user it then signs in,
# immediately before their LOGIN row — an anonymous acceptance writes nothing
# to the audit database (DQ7).
CONSENT_VALID_S = 600
CONSENT_REQUIRED_MESSAGE = ('Read and accept the notice before signing in. Reload the page '
                            'if it is not shown.')


def _consent_settings(db):
    vals = _read_settings(db, ('dow_enabled', 'dow_text'))
    return vals['dow_enabled'] == 'true', vals['dow_text'] or ''


def _notice_label(text):
    """Which notice was accepted: the standard wording, or the operator's
    text by digest (never the text itself: it can be long)."""
    if not text:
        return 'standard DoD notice'
    return 'custom notice sha256=%s' % hashlib.sha256(text.encode('utf-8')).hexdigest()[:16]


@bp.route('/auth/consent', methods=['POST'])
def accept_consent():
    data, err = _parse_json_body()
    if err:
        return err
    if data.get('accepted') is not True:
        return jsonify({'error': 'The notice was not accepted.', 'code': 'consent_declined'}), 400
    db = get_db(_cfg())
    try:
        _enabled, text = _consent_settings(db)
    finally:
        db.close()
    session['consent'] = {'at': time.time(), 'notice': _notice_label(text)}
    return jsonify({'ok': True, 'valid_seconds': CONSENT_VALID_S})


def _fresh_consent():
    """The consent this browser gave, if it was given in the last
    CONSENT_VALID_S seconds; else None."""
    c = session.get('consent')
    if not isinstance(c, dict):
        return None
    try:
        age = time.time() - float(c.get('at'))
    except (TypeError, ValueError):
        return None
    return c if 0 <= age <= CONSENT_VALID_S else None


def _consent_gate():
    """(consent, refusal) for a sign-in: the acceptance to record (None
    while the notice is off), or the 403 when the notice is on and this
    browser holds no fresh acceptance."""
    db = get_db(_cfg())
    try:
        consent_on, _text = _consent_settings(db)
    finally:
        db.close()
    consent = _fresh_consent()
    if consent_on and consent is None:
        # Before the directory is asked anything: no credential is tried
        # until the notice has been accepted.
        return None, (jsonify({'error': CONSENT_REQUIRED_MESSAGE, 'code': 'consent_required'}), 403)
    return (consent if consent_on else None), None


@bp.route('/auth/login', methods=['POST'])
def login():
    data, err = _parse_json_body()
    if err:
        return err
    username = (data.get('username') or '').strip()
    password = data.get('password') or ''
    if not username or not password:
        return jsonify({'error': 'Username and password required'}), 400
    consent, refused = _consent_gate()
    if refused:
        return refused

    ok, result = auth.validate_credentials(_cfg(), username, password)
    if not ok:
        log.warning('Login failed for user %r from %s: %s', _log_safe(username),
                    request.remote_addr, result)
        # The username here is ATTACKER-CONTROLLED and this row is downloadable
        # by any authenticated user via /api/audit/export. audit.py neutralises
        # spreadsheet formula prefixes and quotes with csv.writer, so it is safe
        # to record — but it is bounded anyway, because an unbounded attacker
        # string in a shared export is not something to rely on one control for.
        audit.log_action(_cfg(), _log_safe(username) or '(empty)', 'LOGIN_FAILED',
                         request.remote_addr or 'unknown',
                         'reason=%s' % str(result)[:120], '', best_effort=True,
                         outcome='failure')
        # ONE answer for every failure (round 4, sec-review TM-SEC-009): "User
        # not found", "Invalid credentials", "Not a member of ..." and a raw LDAP
        # error told an unauthenticated caller which accounts exist and what the
        # directory said. The specific reason stays in the audit row and the log
        # above, where an administrator reads it.
        return jsonify({'error': LOGIN_FAILED_MESSAGE}), 401

    cfg = _cfg()
    # A sign-in is an audited action like any other: no session is created
    # that the audit trail cannot record.
    try:
        audit.require_writable(cfg)
    except audit.AuditUnavailable as exc:
        return _audit_unavailable(exc)
    db  = get_db(cfg)

    # Clean up expired sessions before checking the count
    cleanup_expired_sessions(db)

    max_s = _max_sessions(db)
    # Count and insert under ONE write lock (round 2, sec-review): with four
    # workers, two logins at the limit could both count N-1 and both insert.
    # BEGIN IMMEDIATE takes the lock before the count; create_session's
    # commit releases it.
    db.execute('BEGIN IMMEDIATE')
    active = count_active_sessions(db, result['username'])
    if 0 < max_s <= active:          # a limit of zero means unlimited
        return _refuse_session_limit(cfg, db, result['username'], active, max_s)

    sid = create_session(db, result['username'], _timeout(), request.remote_addr)
    ends_at = session_absolute_end(db, sid, _absolute_hours(db))
    db.close()
    # Authentication events belong in the audit trail, not only the app log:
    # the app log is not exported, not shown in the Audit tab, and rotates out
    # after 14 days. NIST AU-2 treats logon/logoff as auditable events.
    # request.remote_addr is meaningful as of v1.0.4 (ProxyFix, one hop) —
    # before that every row would have recorded 127.0.0.1.
    try:
        if consent:
            audit.log_action(cfg, result['username'], 'CONSENT_ACCEPTED', 'consent notice',
                             '%s accepted %s before this sign-in' % (
                                 consent.get('notice', '?'),
                                 audit.utc_ts(datetime.fromtimestamp(float(consent['at']),
                                                                     timezone.utc))), '')
        audit.log_action(cfg, result['username'], 'LOGIN',
                         request.remote_addr or 'unknown',
                         'bind=%s' % ('service' if _cfg().get('auth', {}).get('ldap_bind_dn')
                                      else 'direct-user'), '')
    except audit.AuditUnavailable as exc:
        # The session row exists but has not been handed out: remove it, and
        # the sign-in did not happen.
        db = get_db(cfg)
        delete_session(db, sid)
        db.close()
        return _audit_unavailable(exc)

    session.permanent = True
    session.pop('consent', None)        # one acceptance, one sign-in
    session['sid']  = sid
    session['user'] = result

    log.info('Login success: user=%s ip=%s', result['username'], request.remote_addr)
    # The browser arms its own idle timer from THIS value. It is not sent so
    # the client can decide policy - the server still enforces `expires_at` -
    # but so that the countdown a person watches is the same number the
    # session actually dies on. A hardcoded 15 in the frontend would be a
    # second definition that drifts the first time config.yaml is edited.
    # v1.3.0: and the absolute end, which no activity moves.
    return jsonify({'user': result, 'timeout_minutes': _timeout(), 'session_ends_at': ends_at})


def _refuse_session_limit(cfg, db, username, active, max_s):
    """The 429 for a user already at the concurrent-session limit: the write
    lock released and LOGIN_REFUSED recorded."""
    db.rollback()
    db.close()
    log.warning('Concurrent session limit (%d) reached for user %s', max_s, username)
    audit.log_action(cfg, username, 'LOGIN_REFUSED',
                     request.remote_addr or 'unknown',
                     'concurrent session limit reached (%d/%d)' % (active, max_s), '',
                     best_effort=True, outcome='failure')
    return jsonify({
        'error': f'Concurrent session limit reached ({active}/{max_s}). '
                 f'Sign out from another session first.'
    }), 429


@bp.route('/auth/logout', methods=['POST'])
@require_auth
def logout():
    sid = session.get('sid')
    user = session.get('user', {}).get('username', '?')
    if sid:
        db = get_db(_cfg())
        delete_session(db, sid)
        db.close()
    # WHY THE SESSION ENDED, IN THE ROW ITSELF. A session the browser closed
    # after 15 idle minutes is not the same event as a person pressing Sign out,
    # and recording both as 'explicit sign-out' would have made the audit trail
    # say something untrue about the first. The DETAIL carries the distinction
    # rather than a sixteenth action word: an auditor filtering the export on
    # LOGOUT still sees every session end, which is the question usually asked.
    #
    # The reason is CLIENT-SUPPLIED and therefore constrained to a known set.
    # Anything else is recorded as 'unspecified' rather than echoed - this
    # string reaches the audit export, and an attacker-chosen sentence in an
    # audit row is a forged record even when it is correctly escaped.
    reason = str(((request.get_json(silent=True) or {}).get('reason') or '')).strip()
    detail = _LOGOUT_REASONS.get(reason, 'sign-out (unspecified reason)')
    log.info('Logout: user=%s reason=%s', user, reason or 'explicit')
    # Audited BEFORE session.clear(), because the username is read from the
    # session and clearing it first would record '?' for every logout.
    # best_effort: a sign-out is never refused. A failed record is reported
    # at CRIT (AUDIT_WRITE_FAILED) with the whole row.
    audit.log_action(_cfg(), user, 'LOGOUT',
                     request.remote_addr or 'unknown', detail, '', best_effort=True)
    session.clear()
    return jsonify({'ok': True})


@bp.route('/auth/whoami', methods=['GET'])
@require_auth
def whoami():
    # `timeout_minutes` here as well as on login: this is the call the app
    # makes on a page RELOAD, and a reloaded tab that re-armed its idle timer
    # from a frontend default would run a different clock from the session it
    # just restored.
    db = get_db(_cfg())
    try:
        ends_at = session_absolute_end(db, session.get('sid'), _absolute_hours(db))
    finally:
        db.close()
    return jsonify({'user': session['user'], 'timeout_minutes': _timeout(),
                    'session_ends_at': ends_at})


# ── ending other sessions (v1.3.0, NGNX-APP-003330, DQ8) ─────────────────────
# Every signed-in user is an administrator (contract principle), so any of them
# may end a user's sessions or everyone's. The caller's own session is never
# ended here (Sign out does that), so the action cannot lock its own author
# out mid-request. Sessions are listed by a one-way handle, NEVER by id: an id
# is a bearer secret and this list is readable by every signed-in user.
@bp.route('/sessions', methods=['GET'])
@require_auth
def list_sessions():
    db = get_db(_cfg())
    try:
        rows = list_all_active_sessions(db)
    finally:
        db.close()
    mine = session_handle(session.get('sid'))
    for r in rows:
        r['current'] = r['handle'] == mine
    return jsonify({'sessions': rows})


@bp.route('/sessions/end', methods=['POST'])
@require_auth
@audit_gate
def end_user_sessions():
    data, err = _parse_json_body()
    if err:
        return err
    everyone = data.get('all') is True
    target = data.get('user')
    if everyone == (target is not None) or (target is not None and (
            not isinstance(target, str) or not target.strip() or len(target) > 128)):
        return jsonify({'error': 'Send {"user": "<name>"} or {"all": true}, not both.',
                        'code': 'invalid'}), 400
    cfg = _cfg()
    me = session['user']['username']
    who = 'every user' if everyone else _log_safe(target.strip(), 128)
    db = get_db(cfg)
    try:
        db.execute('BEGIN IMMEDIATE')
        ended = end_sessions(db, 'ended by %s' % _log_safe(me, 128),
                             user=None if everyone else target.strip(),
                             keep_sid=session.get('sid'), commit=False)
        record = audit.log_action(cfg, me, 'SESSIONS_ENDED', who,
                                  'ended %d session(s) of %s; the caller kept their own'
                                  % (ended, who), '', db=db)
        db.commit()
    except audit.AuditUnavailable as exc:
        db.rollback()
        return _audit_unavailable(exc)
    finally:
        db.close()
    audit.emit(record)
    log.info('SESSIONS_ENDED by=%s target=%s count=%d', _log_safe(me), who, ended)
    return jsonify({'ok': True, 'ended': ended})


# ── clusters ──────────────────────────────────────────────────────
@bp.route('/clusters', methods=['GET'])
@require_auth
def list_clusters():
    # cluster_store.public_view is the single definition of what leaves this
    # process: everything the Cluster Builder needs to EDIT a profile, cert
    # paths reduced to basenames, and sasl_password never — it is write-only.
    return jsonify({
        'clusters': [cluster_store.public_view(c) for c in _cfg().get('clusters', [])],
        'protocols': list(cluster_store.PROTOCOLS),
        'sasl_mechanisms': list(cluster_store.SASL_MECHANISMS),
    })


@bp.route('/clusters/<cluster_id>/test', methods=['GET'])
@require_auth
def test_cluster(cluster_id):
    cfg = _cfg()
    c = get_cluster_by_id(cfg, cluster_id)
    if not c:
        return jsonify({'error': 'Cluster not found'}), 404
    if c.get('disabled'):
        return jsonify({'ok': False, 'detail': {'error': c['disabled']}})
    ok, result = kafka_client.test_connection(c)
    if not ok:
        ref = _kafka_failure('cluster test %s' % _log_safe(cluster_id), RuntimeError(result))
        return jsonify({'ok': False, 'detail': {'error': KAFKA_FAILED_MESSAGE % ref,
                                                'reference': ref}})
    return jsonify({'ok': ok, 'detail': result})


# ── cluster builder (create / modify / delete) ────────────────────
# Every authenticated user is a Kafka admin by design (contract principle), so
# these routes carry no extra role check — require_auth IS the gate. What they
# do carry is an audit entry per change, with the before and after state.
def _persist(clusters):
    """Write the list atomically. The next _cfg() re-reads it from disk."""
    cluster_store.save_clusters(clusters)


def _only_one_active(clusters, active_id):
    """Exactly one profile may be active — two would make _cluster() arbitrary."""
    for c in clusters:
        c['active'] = (c.get('id') == active_id)
    return clusters


@bp.route('/clusters', methods=['POST'])
@require_auth
@audit_gate
def create_cluster():
    data, err = _parse_json_body()
    if err:
        return err
    existing = _cfg().get('clusters', [])
    try:
        cluster = cluster_store.validate(data, existing, cluster_id=None)
        cluster = cluster_store.apply_material(cluster, data, previous=None)
    except cluster_store.ClusterError as exc:
        return jsonify({'error': str(exc)}), 400

    updated = [dict(c) for c in existing] + [cluster]
    if cluster['active'] or len(updated) == 1:
        _only_one_active(updated, cluster['id'])
    _persist(updated)

    user = session['user']['username']
    try:
        audit.log_action(_cfg(), user, 'CLUSTER_CREATE', cluster['id'],
                         'after: %s' % cluster_store.audit_detail(cluster),
                         cluster['id'])
    except audit.AuditUnavailable as exc:
        return _audit_failed_after('The cluster profile %s' % cluster['id'], exc)
    log.info('CLUSTER_CREATE id=%s user=%s', cluster['id'], user)
    return jsonify({'ok': True, 'cluster': cluster_store.public_view(cluster)}), 201


@bp.route('/clusters/<cluster_id>', methods=['PUT'])
@require_auth
@audit_gate
def update_cluster(cluster_id):
    data, err = _parse_json_body()
    if err:
        return err
    existing = _cfg().get('clusters', [])
    previous = get_cluster_by_id({'clusters': existing}, cluster_id)
    if not previous:
        return jsonify({'error': 'Cluster not found'}), 404

    # The id is the routing key: session['active_cluster'] holds it and every
    # generated cert filename is derived from it. Renaming through this route
    # would orphan both, so it is refused rather than silently accepted.
    if str(data.get('id') or cluster_id) != cluster_id:
        return jsonify({'error': 'A cluster id cannot be changed. Create a new '
                                 'profile and delete this one.'}), 400

    try:
        cluster = cluster_store.validate(data, existing, cluster_id=cluster_id)
        cluster = cluster_store.apply_material(cluster, data, previous=previous)
    except cluster_store.ClusterError as exc:
        return jsonify({'error': str(exc)}), 400

    updated = [cluster if c.get('id') == cluster_id else dict(c) for c in existing]
    if cluster['active']:
        _only_one_active(updated, cluster['id'])
    elif not any(c.get('active') for c in updated):
        _only_one_active(updated, updated[0]['id'])
    _persist(updated)

    user = session['user']['username']
    try:
        audit.log_action(_cfg(), user, 'CLUSTER_UPDATE', cluster_id,
                         'before: %s | after: %s'
                         % (cluster_store.audit_detail(previous),
                            cluster_store.audit_detail(cluster)),
                         cluster_id)
    except audit.AuditUnavailable as exc:
        return _audit_failed_after('The change to cluster profile %s' % cluster_id, exc)
    log.info('CLUSTER_UPDATE id=%s user=%s', cluster_id, user)
    return jsonify({'ok': True, 'cluster': cluster_store.public_view(cluster)})


@bp.route('/clusters/<cluster_id>', methods=['DELETE'])
@require_auth
@audit_gate
def delete_cluster(cluster_id):
    existing = _cfg().get('clusters', [])
    previous = get_cluster_by_id({'clusters': existing}, cluster_id)
    if not previous:
        return jsonify({'error': 'Cluster not found'}), 404
    if len(existing) == 1:
        return jsonify({'error': 'The last cluster profile cannot be deleted — '
                                 'every topic and consumer-group view resolves '
                                 'through one.'}), 409

    updated = [dict(c) for c in existing if c.get('id') != cluster_id]
    if not any(c.get('active') for c in updated):
        _only_one_active(updated, updated[0]['id'])
    _persist(updated)
    for field in cluster_store.CERT_FIELDS:
        cluster_store.discard_cert(previous.get(field))

    user = session['user']['username']
    try:
        audit.log_action(_cfg(), user, 'CLUSTER_DELETE', cluster_id,
                         'before: %s' % cluster_store.audit_detail(previous),
                         cluster_id)
    except audit.AuditUnavailable as exc:
        return _audit_failed_after('The deletion of cluster profile %s' % cluster_id, exc)
    log.info('CLUSTER_DELETE id=%s user=%s', cluster_id, user)
    return jsonify({'ok': True})


@bp.route('/clusters/active', methods=['PUT'])
@require_auth
def set_active_cluster():
    data, err = _parse_json_body()
    if err:
        return err
    cluster_id = data.get('cluster_id')
    if not get_cluster_by_id(_cfg(), cluster_id):
        return jsonify({'error': 'Cluster not found'}), 404
    session['active_cluster'] = cluster_id
    return jsonify({'ok': True, 'active_cluster': cluster_id})


# ── service control ───────────────────────────────────────────────
# Restart topic-manager and RELOAD nginx. A hard nginx restart is available
# behind an explicit flag only: nothing in this release changes nginx's
# configuration, so a restart buys nothing a reload does not and it drops
# every other user's in-flight request.
#
# `nginx -t` is run FIRST and synchronously — its failure refuses the whole
# operation and nothing is touched. Only then is the 202 returned and the
# sequence detached, because restarting topic-manager kills the worker running
# this handler and no response would ever reach the browser.
@bp.route('/service/restart', methods=['POST'])
@require_auth
@audit_gate
def restart_service():
    data, err = _parse_json_body()
    if err:
        return err
    hard_nginx = bool(data.get('restart_nginx', False))
    nginx_action = 'restart' if hard_nginx else 'reload'
    cfg  = _cfg()
    user = session['user']['username']

    # Claimed BEFORE the nginx test, because starting the test unit is itself a
    # systemd start and carries its own start limit. Every authenticated user
    # can reach this route, and five starts in ten seconds leave systemd
    # refusing to start the unit until an operator runs `systemctl reset-failed`
    # on the host — a persistent outage from an ordinary session.
    allowed, remaining = service_control.claim_restart_slot(cfg)
    if not allowed:
        wait = max(1, int(math.ceil(remaining)))
        detail = ('refused: a restart was requested less than %ds ago; %ds remaining'
                  % (service_control.RESTART_MIN_INTERVAL_S, wait))
        audit.log_action(cfg, user, 'SERVICE_RESTART_THROTTLED',
                         service_control.SERVICE_UNIT, detail, best_effort=True,
                         outcome='failure')
        log.warning('SERVICE_RESTART throttled for user=%s: %s', user, detail)
        resp = jsonify({
            'error': ('Another restart was requested less than %ds ago. Wait %ds and try '
                      'again — restarting faster than that trips systemd start limiting, '
                      'which leaves the service refusing to start until an operator runs '
                      '`systemctl reset-failed` on the host.'
                      % (service_control.RESTART_MIN_INTERVAL_S, wait)),
            'retry_after': wait,
        })
        resp.headers['Retry-After'] = str(wait)
        return resp, 429

    ok, detail = service_control.nginx_config_test()
    if not ok:
        audit.log_action(cfg, user, 'SERVICE_RESTART_REFUSED',
                         service_control.NGINX_UNIT, detail, best_effort=True,
                         outcome='failure')
        log.warning('SERVICE_RESTART refused for user=%s: %s', user, detail)
        return jsonify({'error': detail}), 409

    # Logged BEFORE anything is touched. The worker is about to be killed, so
    # an entry written afterwards is an entry that may never be written.
    try:
        audit.log_action(cfg, user, 'SERVICE_RESTART',
                         '%s + %s' % (service_control.NGINX_UNIT,
                                      service_control.SERVICE_UNIT),
                         'nginx=%s, topic-manager=restart; %s' % (nginx_action, detail))
    except audit.AuditUnavailable as exc:
        return _audit_unavailable(exc)
    log.warning('SERVICE_RESTART user=%s nginx=%s', user, nginx_action)

    source = audit.request_source()     # the steps run on a thread, outside this request

    def _record(message):
        audit.log_action(cfg, user, 'SERVICE_RESTART_STEP', 'systemd', message,
                         best_effort=True, source=source)

    service_control.restart_detached(hard_nginx, _record)
    return jsonify({
        'ok': True,
        'nginx_action': nginx_action,
        'nginx_config_test': detail,
        'poll': '/api/health',
    }), 202


# ── broker metadata ───────────────────────────────────────────────
@bp.route('/broker/metadata', methods=['GET'])
@require_auth
def broker_metadata():
    try:
        meta = kafka_client.get_cluster_metadata(_cluster())
        return jsonify(meta)
    except Exception as exc:
        return _kafka_error_response('broker metadata', exc)


# ── topics ────────────────────────────────────────────────────────
@bp.route('/topics', methods=['GET'])
@require_auth
def list_topics():
    include_internal = request.args.get('internal', 'false').lower() == 'true'
    try:
        topics = kafka_client.list_topics(_cluster(), include_internal)
        return jsonify({'topics': topics})
    except Exception as exc:
        return _kafka_error_response('list topics', exc)


#: The create form's own top-level fields and the topic config key each one
#: sets. They win over the same key in `config`, in this order.
_TOPIC_BODY_CONFIGS = (
    ('retention_ms',        'retention.ms'),
    ('retention_bytes',     'retention.bytes'),
    ('cleanup_policy',      'cleanup.policy'),
    ('compression_type',    'compression.type'),
    ('min_insync_replicas', 'min.insync.replicas'),
    ('max_message_bytes',   'max.message.bytes'),
)


@bp.route('/topics', methods=['POST'])
@require_auth
@audit_gate
def create_topic():
    data, err = _parse_json_body()
    if err:
        return err
    name = (data.get('name') or '').strip()
    if not name or not re.match(r'^[a-zA-Z0-9._-]+$', name):
        return jsonify({'error': 'Invalid topic name'}), 400

    try:
        partitions = int(data.get('partitions', 3))
        rf         = int(data.get('replication_factor', 3))
    except (TypeError, ValueError):
        return jsonify({'error': 'partitions and replication_factor must be integers'}), 400
    if not (1 <= partitions <= _MAX_PARTITIONS):
        return jsonify({'error': f'partitions must be between 1 and {_MAX_PARTITIONS}'}), 400
    if not (1 <= rf <= _MAX_RF):
        return jsonify({'error': f'replication_factor must be between 1 and {_MAX_RF}'}), 400

    # Only permit known writable config keys; reject arbitrary/read-only entries
    raw_config = data.get('config', {})
    if not isinstance(raw_config, dict):
        return jsonify({'error': 'config must be an object'}), 400
    config = {k: str(v) for k, v in raw_config.items() if k in _ALLOWED_TOPIC_CONFIGS}

    for field, key in _TOPIC_BODY_CONFIGS:
        if data.get(field):
            config[key] = str(data[field])

    cluster, refused = _write_cluster()
    if refused:
        return refused
    user = session['user']['username']
    try:
        kafka_client.create_topic(cluster, name, partitions, rf, config)
    except Exception as exc:
        return _kafka_write_failed('CREATE', user, name, cluster, exc)

    try:
        audit.log_action(_cfg(), user, 'CREATE', name,
                         f'partitions={partitions}, rf={rf}, config={config}',
                         cluster.get('id', ''))
    except audit.AuditUnavailable as exc:
        return _audit_failed_after('The creation of topic %s' % name, exc)
    log.info('CREATE topic=%s user=%s', name, user)
    return jsonify({'ok': True, 'name': name}), 201


@bp.route('/topics/<path:name>/config', methods=['GET'])
@require_auth
def get_topic_config(name):
    try:
        config = kafka_client.get_topic_config(_cluster(), name)
        return jsonify({'name': name, 'config': config})
    except Exception as exc:
        return _kafka_error_response('topic config read', exc)


@bp.route('/topics/<path:name>/config', methods=['PUT'])
@require_auth
@audit_gate
def update_topic_config(name):
    data, err = _parse_json_body()
    if err:
        return err
    raw_updates = data.get('updates', {})
    if not isinstance(raw_updates, dict) or not raw_updates:
        return jsonify({'error': 'No updates provided'}), 400
    updates = {k: str(v) for k, v in raw_updates.items() if k in _ALLOWED_TOPIC_CONFIGS}
    if not updates:
        return jsonify({'error': 'No valid config keys provided'}), 400

    cluster, refused = _write_cluster()
    if refused:
        return refused
    user = session['user']['username']
    try:
        kafka_client.update_topic_config(cluster, name, updates)
    except Exception as exc:
        return _kafka_write_failed('UPDATE_CONFIG', user, name, cluster, exc)

    try:
        audit.log_action(_cfg(), user, 'UPDATE_CONFIG', name, str(updates), cluster.get('id', ''))
    except audit.AuditUnavailable as exc:
        return _audit_failed_after('The configuration change to topic %s' % name, exc)
    log.info('UPDATE_CONFIG topic=%s user=%s', name, user)
    return jsonify({'ok': True})


@bp.route('/topics/<path:name>', methods=['DELETE'])
@require_auth
@audit_gate
def delete_topic(name):
    cluster, refused = _write_cluster()
    if refused:
        return refused
    user = session['user']['username']
    try:
        kafka_client.delete_topic(cluster, name)
    except Exception as exc:
        return _kafka_write_failed('DELETE', user, name, cluster, exc)

    try:
        audit.log_action(_cfg(), user, 'DELETE', name, 'confirmed by user', cluster.get('id', ''))
    except audit.AuditUnavailable as exc:
        return _audit_failed_after('The deletion of topic %s' % name, exc)
    log.info('DELETE topic=%s user=%s', name, user)
    return jsonify({'ok': True})


# ── consumer groups ───────────────────────────────────────────────
@bp.route('/consumer-groups', methods=['GET'])
@require_auth
def list_consumer_groups():
    try:
        groups = kafka_client.list_consumer_groups(_cluster())
        return jsonify({'groups': groups})
    except Exception as exc:
        return _kafka_error_response('list consumer groups', exc)


def _kafka_write_failed(action, user, name, cluster, exc):
    """A topic write the cluster refused: recorded under its own action word
    with outcome failure (SRG-APP-000099), answered with the generic sentence
    (SRG-APP-000266). Best effort: the change did not happen, so there is
    nothing a missing record could hide."""
    ref = _kafka_failure('%s topic %s' % (action, _log_safe(name, 200)), exc)
    audit.log_action(_cfg(), user, action, name,
                     'failed: the cluster refused the request or did not answer (reference %s)'
                     % ref, cluster.get('id', ''), best_effort=True, outcome='failure')
    return jsonify({'error': KAFKA_FAILED_MESSAGE % ref, 'code': 'kafka_error',
                    'reference': ref}), 502


# ── audit log ─────────────────────────────────────────────────────
#: The largest page of audit rows one request may ask for (round 4,
#: sec-review TM-SEC-007). SQLite reads LIMIT -1 as "no limit", so an
#: unchecked per_page of -1, 0 or 10**9 returned the whole table in one
#: response. The Audit tab asks for 50.
AUDIT_PAGE_MAX = 500


@bp.route('/audit', methods=['GET'])
@require_auth
def get_audit():
    page     = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 50, type=int)
    if page < 1:
        return jsonify({'error': 'page must be a whole number from 1'}), 400
    if not 1 <= per_page <= AUDIT_PAGE_MAX:
        return jsonify({'error': 'per_page must be a whole number from 1 to %d'
                                 % AUDIT_PAGE_MAX}), 400
    # v1.3.0 (SRG-APP-000089, DQ7): reading the audit trail is itself audited,
    # and the read is refused when that record cannot be written.
    cfg = _cfg()
    try:
        audit.log_action(cfg, session['user']['username'], 'AUDIT_READ', 'audit_log',
                         'page=%d per_page=%d' % (page, per_page), '')
    except audit.AuditUnavailable as exc:
        return _audit_unavailable(exc)
    return jsonify(audit.get_audit_log(cfg, page, per_page))


@bp.route('/audit/export', methods=['GET'])
@require_auth
def export_audit():
    cfg = _cfg()
    try:
        audit.log_action(cfg, session['user']['username'], 'AUDIT_EXPORT', 'audit_log',
                         'CSV export of %d row(s)' % audit.count_rows(cfg), '')
    except audit.AuditUnavailable as exc:
        return _audit_unavailable(exc)
    csv_data = audit.export_audit_csv(cfg)
    resp = make_response(csv_data)
    resp.headers['Content-Type'] = 'text/csv'
    resp.headers['Content-Disposition'] = 'attachment; filename="topic-manager-audit.csv"'
    return resp


# ── version ───────────────────────────────────────────────────────
@bp.route('/version', methods=['GET'])
def get_version():
    return jsonify({'version': TM_VERSION, 'product': 'Jarvis Topic Manager'})


# ── app settings ──────────────────────────────────────────────────
# Public subset (banner + DoW) readable without auth so the login page
# and app shell can apply them before the user is authenticated.
#
# FROZEN, and _ALL_KEYS is a NEW set built from it (v1.2.0). Until then
# `_ALL_KEYS = _PUBLIC_KEYS` bound the SAME object, so the first
# `_ALL_KEYS.add(...)` or `|=` for an admin setting would have published it on
# the unauthenticated route below — the syslog collector, the NTP servers, the
# rate limits. A frozenset cannot be extended in place at all.
_PUBLIC_KEYS = frozenset({'banner_enabled', 'banner_text', 'banner_bg', 'banner_fg',
                          'dow_enabled', 'dow_text'})
_ALL_KEYS    = _PUBLIC_KEYS | settings_schema.ADMIN_KEYS

_DEFAULTS = {
    'banner_enabled': 'false',
    'banner_text':    'UNCLASSIFIED',
    'banner_bg':      'green',
    'banner_fg':      'white',
    # OFF unless set: an UPGRADED host keeps what it had. A fresh install sets
    # it ON (install.sh seeds dow_enabled=true unless --no-consent-banner).
    'dow_enabled':    'false',
    'dow_text':       '',
    **settings_schema.ADMIN_DEFAULTS,
}


def _read_settings(db, keys):
    rows = db.execute(
        f'SELECT key, value FROM app_settings WHERE key IN ({",".join("?"*len(keys))})',
        list(keys)
    ).fetchall()
    result = dict(_DEFAULTS)
    result.update({r[0]: r[1] for r in rows})
    return {k: result[k] for k in keys}


@bp.route('/settings/public', methods=['GET'])
def public_settings():
    """No auth required — returns only display/consent settings."""
    db = get_db(_cfg())
    data = _read_settings(db, _PUBLIC_KEYS)
    db.close()
    return jsonify(data)


@bp.route('/settings', methods=['GET'])
@require_auth
def get_settings():
    db = get_db(_cfg())
    data = _read_settings(db, _ALL_KEYS)
    db.close()
    return jsonify(data)


@bp.route('/settings', methods=['PUT'])
@require_auth
def update_settings():
    data, err = _parse_json_body()
    if err:
        return err
    if not isinstance(data, dict):
        return jsonify({'error': 'Expected a JSON object of setting: value pairs'}), 400
    cfg = _cfg()
    user = session['user']['username']
    # v1.2.0: every administrator setting passes its validator BEFORE anything
    # is written, and one bad value refuses the whole request — a half-applied
    # PUT would leave Settings showing a mix the operator never chose.
    try:
        accepted = _accepted_settings(data)
    except settings_schema.InvalidSetting as exc:
        return jsonify({'error': 'invalid', 'field': exc.field, 'reason': exc.reason}), 400
    ignored = sorted(str(k) for k in data if k not in _ALL_KEYS)
    # v1.1.0: this route changes what EVERY user sees (the classification
    # banner, the consent notice) and wrote no audit record at all.
    #
    # ONE TRANSACTION, ONE CONNECTION (round 2, adversary F1). The settings
    # rows and the SETTINGS_UPDATE row commit together or not at all: the
    # standing rule is that an action whose audit record cannot be written
    # does not happen. They used to commit separately, so a failed audit write
    # left a changed banner with no record of who changed it.
    db = get_db(cfg)
    try:
        before = _read_settings(db, accepted.keys()) if accepted else {}
        for key, value in accepted.items():
            db.execute('INSERT OR REPLACE INTO app_settings (key, value) VALUES (?,?)',
                       (key, value))
        changed = sorted(k for k, v in accepted.items() if before.get(k) != v)
        detail = _settings_audit_detail(before, accepted, changed, ignored)
        record = audit.log_action(cfg, user, 'SETTINGS_UPDATE', 'app_settings', detail, '',
                                  db=db)
        db.commit()
    except audit.AuditUnavailable as exc:
        db.rollback()
        return _audit_unavailable(exc)
    except Exception:
        db.rollback()
        log.exception('SETTINGS_UPDATE by user=%s was NOT applied: the change and '
                      'its audit record are one transaction and it failed', _log_safe(user))
        return jsonify({'error': 'The settings could not be saved together with their '
                                 'audit record, so nothing was changed.'}), 500
    finally:
        db.close()
    audit.emit(record)
    log.info('SETTINGS_UPDATE user=%s %s', _log_safe(user), _log_safe(detail, 200))
    return jsonify({'ok': True, 'changed': changed})


def _accepted_settings(data):
    """The stored form of every known key in `data`; raises InvalidSetting
    on the first value that fails its validator (v1.3.0: the consent keys
    have validators too). Unknown keys are left out, and named in the audit."""
    accepted = {}
    for k, v in data.items():
        if k in settings_schema.ADMIN_KEYS:
            accepted[k] = settings_schema.normalise(k, v)
        elif k in settings_schema.PUBLIC_VALIDATORS:
            accepted[k] = settings_schema.normalise_public(k, v)
        elif k in _PUBLIC_KEYS:
            accepted[k] = str(v)
    return accepted


#: Settings whose VALUES the audit record may show, old -> new. Display and
#: consent settings: what the banner says and what colour it is are exactly
#: what an auditor needs to see. v1.2.0 adds the administrator settings ON
#: PURPOSE: none is a secret (host names, ports, numbers, true/false), every
#: one has passed a charset validator, and "who pointed the audit trail at
#: which collector" is the question an auditor asks. Any key added later is
#: recorded by NAME only unless it is added here deliberately.
_AUDIT_VALUE_KEYS = frozenset({'banner_enabled', 'banner_text', 'banner_bg',
                               'banner_fg', 'dow_enabled'}) | settings_schema.ADMIN_KEYS
#: Recorded by digest, old -> new: the custom consent text can be 4000
#: characters, and its digest is what CONSENT_ACCEPTED names.
_AUDIT_DIGEST_KEYS = frozenset({'dow_text'})


def _settings_audit_detail(before, accepted, changed, ignored):
    parts = []
    for k in changed:
        if k in _AUDIT_DIGEST_KEYS:
            parts.append('%s: %s -> %s' % (k, _notice_label(before.get(k) or ''),
                                           _notice_label(accepted[k])))
        elif k in _AUDIT_VALUE_KEYS:
            parts.append('%s: %s -> %s' % (k, _log_safe(repr(before.get(k)), 80),
                                           _log_safe(repr(accepted[k]), 80)))
        else:
            parts.append(k)
    detail = ('changed: %s' % '; '.join(parts)) if parts else 'no change'
    if ignored:
        # %r and a control-character strip: the key names come from the client.
        detail += '; ignored unknown key(s): %s' % ', '.join(
            _log_safe(repr(k), 40) for k in ignored[:10])
    return detail[:500]


# ── v1.2.0: apply to host, host status, audit capacity, TLS ───────────────
# Every route below is behind require_auth; none is public. The privileged
# half is install/libexec/tm-apply (root), reached ONLY through the fixed
# one-shot units tm/service_control.APPLY_UNITS — see tm/apply.py.

def _start_staged(cfg, domain, job, user):
    """Audit the request and start the unit. The request is audited BEFORE the
    helper can run: if that record cannot be written the staging is withdrawn
    and nothing changes."""
    try:
        audit.log_action(cfg, user, 'SYSTEM_APPLY_REQUESTED', domain, 'job=%s' % job)
    except audit.AuditUnavailable as exc:
        apply_mod.discard_stage(cfg, domain)
        return _audit_unavailable(exc)
    ok, detail = service_control.start_apply_unit(domain)
    if not ok:
        apply_mod.record_start_failure(cfg, domain, job, detail)
        log.warning('SYSTEM_APPLY %s job=%s could not start: %s', domain, job, detail)
        return jsonify({'error': 'apply_unit_failed', 'domain': domain, 'job': job,
                        'message': detail}), 502
    log.info('SYSTEM_APPLY_REQUESTED domain=%s job=%s user=%s', domain, job, _log_safe(user))
    return jsonify({'domain': domain, 'job': job, 'state': 'queued'}), 202


def _refuse_if_busy(cfg, domain):
    allowed, remaining = apply_mod.claim_slot(cfg, domain)
    if not allowed:
        wait = max(1, int(math.ceil(remaining)))
        resp = jsonify({'error': 'apply_throttled', 'retry_after': wait,
                        'message': 'An apply for %s was requested less than %ds ago.'
                                   % (domain, apply_mod.APPLY_MIN_INTERVAL_S)})
        resp.headers['Retry-After'] = str(wait)
        return resp, 429
    if apply_mod.status(cfg, domain)['state'] in ('queued', 'running'):
        return jsonify({'error': 'apply_in_progress', 'domain': domain,
                        'message': 'An apply for %s is already queued or running.' % domain}), 409
    return None


@bp.route('/system/apply/<domain>', methods=['POST'])
@require_auth
@audit_gate
def system_apply(domain):
    if domain not in apply_mod.REQUEST_DOMAINS:
        return jsonify({'error': 'unknown_domain', 'domain': _log_safe(domain, 32)}), 404
    # The body carries nothing (the SAVED settings are applied); requiring
    # JSON is what refuses a form post.
    _, err = _parse_json_body()
    if err:
        return err
    cfg = _cfg()
    user = session['user']['username']
    busy = _refuse_if_busy(cfg, domain)
    if busy:
        return busy
    db = get_db(cfg)
    try:
        values = apply_mod.domain_settings(db, domain)
    finally:
        db.close()
    problems = settings_schema.check_domain(domain, values)
    if problems:
        field, _, reason = problems[0].partition(': ')
        return jsonify({'error': 'invalid', 'field': field, 'reason': reason or problems[0]}), 400
    job = apply_mod.write_stage(cfg, domain, values, user)
    return _start_staged(cfg, domain, job, user)


@bp.route('/system/apply/<domain>', methods=['GET'])
@require_auth
def system_apply_status(domain):
    if domain not in apply_mod.STATUS_DOMAINS:
        return jsonify({'error': 'unknown_domain', 'domain': _log_safe(domain, 32)}), 404
    cfg = _cfg()
    apply_mod.audit_result(cfg, domain)
    return jsonify(apply_mod.status(cfg, domain))


@bp.route('/system/time', methods=['GET'])
@require_auth
def system_time():
    return jsonify(hoststatus.time_status())


@bp.route('/audit/capacity', methods=['GET'])
@require_auth
def audit_capacity():
    return jsonify(audit_retention.capacity(_cfg()))


@bp.route('/system/tls', methods=['GET'])
@require_auth
def system_tls():
    return jsonify(hoststatus.tls_status())


@bp.route('/compliance', methods=['GET'])
@require_auth
def compliance_report():
    """v1.3.0 (DQ3): every board rule with its documented status
    (docs/STIG-COMPLIANCE.md, held to tm/compliance.py by
    tools/check-stig-compliance.sh) and what was MEASURED: the application's
    own checks now, the host's from the last `compliance` run of the root
    helper. Read-only."""
    return jsonify(compliance.report(_cfg()))


#: The largest multipart body the certificate upload accepts: three PEM fields
#: of at most tls_check.MAX_PEM_BYTES each, plus the multipart framing.
_TLS_UPLOAD_MAX = 3 * tls_check.MAX_PEM_BYTES + 8 * 1024


def _memory_stream(*_args, **_kwargs):
    # THE PRIVATE KEY NEVER TOUCHES /tmp. Werkzeug's default spools a large
    # upload part to a temporary file; this parser keeps every part in memory,
    # and the body is capped above so memory is bounded too.
    return io.BytesIO()


@bp.route('/system/tls/cert', methods=['POST'])
@require_auth
@audit_gate
def system_tls_cert():
    length = request.content_length
    if length is None:
        return jsonify({'error': 'invalid_cert',
                        'reason': 'the upload must carry a Content-Length'}), 411
    if length > _TLS_UPLOAD_MAX:
        return jsonify({'error': 'invalid_cert',
                        'reason': 'the upload is larger than %d bytes' % _TLS_UPLOAD_MAX}), 413
    if request.mimetype != 'multipart/form-data':
        return jsonify({'error': 'invalid_cert',
                        'reason': 'send multipart/form-data with cert, key and optional chain'}), 415
    _stream, _form, files = parse_form_data(request.environ, stream_factory=_memory_stream,
                                            max_content_length=_TLS_UPLOAD_MAX)

    def _part(name):
        f = files.get(name)
        return f.read(tls_check.MAX_PEM_BYTES + 1) if f else b''

    cert, key, chain = _part('cert'), _part('key'), _part('chain')
    try:
        info = tls_check.validate(cert, key, chain or None)
    except tls_check.CertInvalid as exc:
        # The reason names what is wrong with the upload and never quotes it.
        return jsonify({'error': 'invalid_cert', 'reason': str(exc)}), 400
    cfg = _cfg()
    user = session['user']['username']
    busy = _refuse_if_busy(cfg, 'tls')
    if busy:
        return busy
    staged = {'crt': cert, 'key': key}
    if chain.strip():
        staged['chain'] = chain
    summary = {'subject': info['subject'], 'issuer': info['issuer'],
               'not_after': info['not_after'], 'key_type': info['key_type'],
               'chain_count': info['chain_count']}
    job = apply_mod.write_stage(cfg, 'tls', {'certificate': summary}, user, files=staged)
    del key, staged
    return _start_staged(cfg, 'tls', job, user)
