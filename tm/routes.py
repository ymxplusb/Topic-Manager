import math
import os
import re
import logging
from functools import wraps
from flask import Blueprint, request, jsonify, session, current_app, make_response

from . import auth, kafka_client, audit, service_control
from . import clusters as cluster_store
from .models import (get_db, create_session, validate_session, touch_session,
                     delete_session, count_active_sessions, cleanup_expired_sessions)
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
}


def _max_sessions():
    return _cfg().get('session', {}).get('max_concurrent', 0)


def _cluster(cluster_id=None):
    cfg = _cfg()
    if cluster_id:
        c = get_cluster_by_id(cfg, cluster_id)
    else:
        cid = request.args.get('cluster') or session.get('active_cluster')
        c = get_cluster_by_id(cfg, cid) if cid else get_active_cluster(cfg)
    if not c:
        raise ValueError('No cluster configured or cluster not found')
    if c.get('disabled'):
        raise ValueError('Cluster %s is disabled: %s' % (c.get('id'), c['disabled']))
    return c


# ── helpers ───────────────────────────────────────────────────────
def _parse_json_body():
    """Return parsed JSON body, or abort 415/400 if Content-Type or body is wrong."""
    if not request.is_json:
        return None, (jsonify({'error': 'Content-Type must be application/json'}), 415)
    data = request.get_json(silent=True)
    if data is None:
        return None, (jsonify({'error': 'Invalid or empty JSON body'}), 400)
    return data, None


# ── auth decorator ────────────────────────────────────────────────
# All authenticated users are members of the Kafka-Admins AD group —
# group membership is enforced at login time by auth.validate_credentials.
# Every session therefore carries implicit admin rights; require_auth is the
# single gate for all protected routes.
def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        # Block cross-site fetch requests on state-mutation methods.
        # Sec-Fetch-Site is set by all modern browsers; absence (curl/Postman)
        # is allowed so the API remains usable by authorized tooling.
        if request.method not in ('GET', 'HEAD', 'OPTIONS'):
            if request.headers.get('Sec-Fetch-Site') == 'cross-site':
                return jsonify({'error': 'Cross-site requests are not permitted'}), 403

        sid = session.get('sid')
        if not sid:
            return jsonify({'error': 'Authentication required'}), 401

        db = get_db(_cfg())
        username = validate_session(db, sid)
        if not username:
            db.close()
            # The other way a session ends. Recorded so the trail shows why a
            # user stopped appearing, rather than leaving a silent gap.
            audit.log_action(_cfg(), session.get('user', {}).get('username', '?'),
                             'SESSION_EXPIRED', request.remote_addr or 'unknown',
                             'session no longer valid', '')
            session.clear()
            return jsonify({'error': 'Session expired'}), 401

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

        request.current_user = session.get('user', {})
        return f(*args, **kwargs)
    return decorated


# ── health ────────────────────────────────────────────────────────
@bp.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok', 'version': TM_VERSION})


# ── auth ──────────────────────────────────────────────────────────
@bp.route('/auth/login', methods=['POST'])
def login():
    data, err = _parse_json_body()
    if err:
        return err
    username = (data.get('username') or '').strip()
    password = data.get('password') or ''
    if not username or not password:
        return jsonify({'error': 'Username and password required'}), 400

    ok, result = auth.validate_credentials(_cfg(), username, password)
    if not ok:
        log.warning('Login failed for user %s from %s: %s', username, request.remote_addr, result)
        # The username here is ATTACKER-CONTROLLED and this row is downloadable
        # by any authenticated user via /api/audit/export. audit.py neutralises
        # spreadsheet formula prefixes and quotes with csv.writer, so it is safe
        # to record — but it is bounded anyway, because an unbounded attacker
        # string in a shared export is not something to rely on one control for.
        audit.log_action(_cfg(), username[:64] or '(empty)', 'LOGIN_FAILED',
                         request.remote_addr or 'unknown',
                         'reason=%s' % str(result)[:120], '')
        return jsonify({'error': result}), 401

    cfg = _cfg()
    db  = get_db(cfg)

    # Clean up expired sessions before checking the count
    cleanup_expired_sessions(db)

    max_s = _max_sessions()
    if max_s > 0:
        active = count_active_sessions(db, result['username'])
        if active >= max_s:
            db.close()
            log.warning('Concurrent session limit (%d) reached for user %s', max_s, result['username'])
            audit.log_action(cfg, result['username'], 'LOGIN_REFUSED',
                             request.remote_addr or 'unknown',
                             'concurrent session limit reached (%d/%d)' % (active, max_s), '')
            return jsonify({
                'error': f'Concurrent session limit reached ({active}/{max_s}). '
                         f'Sign out from another session first.'
            }), 429

    sid = create_session(db, result['username'], _timeout(), request.remote_addr)
    db.close()

    session.permanent = True
    session['sid']  = sid
    session['user'] = result

    log.info('Login success: user=%s ip=%s', result['username'], request.remote_addr)
    # Authentication events belong in the audit trail, not only the app log:
    # the app log is not exported, not shown in the Audit tab, and rotates out
    # after 14 days. NIST AU-2 treats logon/logoff as auditable events.
    # request.remote_addr is meaningful as of v1.0.4 (ProxyFix, one hop) —
    # before that every row would have recorded 127.0.0.1.
    audit.log_action(cfg, result['username'], 'LOGIN',
                     request.remote_addr or 'unknown',
                     'bind=%s' % ('service' if _cfg().get('auth', {}).get('ldap_bind_dn')
                                  else 'direct-user'), '')
    # The browser arms its own idle timer from THIS value. It is not sent so
    # the client can decide policy - the server still enforces `expires_at` -
    # but so that the countdown a person watches is the same number the
    # session actually dies on. A hardcoded 15 in the frontend would be a
    # second definition that drifts the first time config.yaml is edited.
    return jsonify({'user': result, 'timeout_minutes': _timeout()})


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
    audit.log_action(_cfg(), user, 'LOGOUT',
                     request.remote_addr or 'unknown', detail, '')
    session.clear()
    return jsonify({'ok': True})


@bp.route('/auth/whoami', methods=['GET'])
@require_auth
def whoami():
    # `timeout_minutes` here as well as on login: this is the call the app
    # makes on a page RELOAD, and a reloaded tab that re-armed its idle timer
    # from a frontend default would run a different clock from the session it
    # just restored.
    return jsonify({'user': session['user'], 'timeout_minutes': _timeout()})


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
    audit.log_action(_cfg(), user, 'CLUSTER_CREATE', cluster['id'],
                     'after: %s' % cluster_store.audit_detail(cluster),
                     cluster['id'])
    log.info('CLUSTER_CREATE id=%s user=%s', cluster['id'], user)
    return jsonify({'ok': True, 'cluster': cluster_store.public_view(cluster)}), 201


@bp.route('/clusters/<cluster_id>', methods=['PUT'])
@require_auth
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
    audit.log_action(_cfg(), user, 'CLUSTER_UPDATE', cluster_id,
                     'before: %s | after: %s'
                     % (cluster_store.audit_detail(previous),
                        cluster_store.audit_detail(cluster)),
                     cluster_id)
    log.info('CLUSTER_UPDATE id=%s user=%s', cluster_id, user)
    return jsonify({'ok': True, 'cluster': cluster_store.public_view(cluster)})


@bp.route('/clusters/<cluster_id>', methods=['DELETE'])
@require_auth
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
    audit.log_action(_cfg(), user, 'CLUSTER_DELETE', cluster_id,
                     'before: %s' % cluster_store.audit_detail(previous),
                     cluster_id)
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
                         service_control.SERVICE_UNIT, detail)
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
                         service_control.NGINX_UNIT, detail)
        log.warning('SERVICE_RESTART refused for user=%s: %s', user, detail)
        return jsonify({'error': detail}), 409

    # Logged BEFORE anything is touched. The worker is about to be killed, so
    # an entry written afterwards is an entry that may never be written.
    audit.log_action(cfg, user, 'SERVICE_RESTART',
                     '%s + %s' % (service_control.NGINX_UNIT,
                                  service_control.SERVICE_UNIT),
                     'nginx=%s, topic-manager=restart; %s' % (nginx_action, detail))
    log.warning('SERVICE_RESTART user=%s nginx=%s', user, nginx_action)

    def _record(message):
        audit.log_action(cfg, user, 'SERVICE_RESTART_STEP', 'systemd', message)

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
        return jsonify({'error': str(exc)}), 502


# ── topics ────────────────────────────────────────────────────────
@bp.route('/topics', methods=['GET'])
@require_auth
def list_topics():
    include_internal = request.args.get('internal', 'false').lower() == 'true'
    try:
        topics = kafka_client.list_topics(_cluster(), include_internal)
        return jsonify({'topics': topics})
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502


@bp.route('/topics', methods=['POST'])
@require_auth
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

    if data.get('retention_ms'):
        config['retention.ms'] = str(data['retention_ms'])
    if data.get('retention_bytes'):
        config['retention.bytes'] = str(data['retention_bytes'])
    if data.get('cleanup_policy'):
        config['cleanup.policy'] = str(data['cleanup_policy'])
    if data.get('compression_type'):
        config['compression.type'] = str(data['compression_type'])
    if data.get('min_insync_replicas'):
        config['min.insync.replicas'] = str(data['min_insync_replicas'])
    if data.get('max_message_bytes'):
        config['max.message.bytes'] = str(data['max_message_bytes'])

    cluster = _cluster()
    try:
        kafka_client.create_topic(cluster, name, partitions, rf, config)
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

    user = session['user']['username']
    audit.log_action(_cfg(), user, 'CREATE', name,
                     f'partitions={partitions}, rf={rf}, config={config}',
                     cluster.get('id', ''))
    log.info('CREATE topic=%s user=%s', name, user)
    return jsonify({'ok': True, 'name': name}), 201


@bp.route('/topics/<path:name>/config', methods=['GET'])
@require_auth
def get_topic_config(name):
    try:
        config = kafka_client.get_topic_config(_cluster(), name)
        return jsonify({'name': name, 'config': config})
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502


@bp.route('/topics/<path:name>/config', methods=['PUT'])
@require_auth
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

    cluster = _cluster()
    try:
        kafka_client.update_topic_config(cluster, name, updates)
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

    user = session['user']['username']
    audit.log_action(_cfg(), user, 'UPDATE_CONFIG', name, str(updates), cluster.get('id', ''))
    log.info('UPDATE_CONFIG topic=%s user=%s', name, user)
    return jsonify({'ok': True})


@bp.route('/topics/<path:name>', methods=['DELETE'])
@require_auth
def delete_topic(name):
    cluster = _cluster()
    try:
        kafka_client.delete_topic(cluster, name)
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

    user = session['user']['username']
    audit.log_action(_cfg(), user, 'DELETE', name, 'confirmed by user', cluster.get('id', ''))
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
        return jsonify({'error': str(exc)}), 502


# ── audit log ─────────────────────────────────────────────────────
@bp.route('/audit', methods=['GET'])
@require_auth
def get_audit():
    page     = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 50, type=int)
    return jsonify(audit.get_audit_log(_cfg(), page, per_page))


@bp.route('/audit/export', methods=['GET'])
@require_auth
def export_audit():
    csv_data = audit.export_audit_csv(_cfg())
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
_PUBLIC_KEYS = {'banner_enabled', 'banner_text', 'banner_bg', 'banner_fg', 'dow_enabled'}
_ALL_KEYS    = _PUBLIC_KEYS  # extend here if admin-only settings are added later

_DEFAULTS = {
    'banner_enabled': 'false',
    'banner_text':    'UNCLASSIFIED',
    'banner_bg':      'green',
    'banner_fg':      'white',
    'dow_enabled':    'false',
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
    db = get_db(_cfg())
    for key, value in data.items():
        if key in _ALL_KEYS:
            db.execute('INSERT OR REPLACE INTO app_settings (key, value) VALUES (?,?)',
                       (key, str(value)))
    db.commit()
    db.close()
    return jsonify({'ok': True})
