#!/usr/bin/env bash
# =============================================================================
# Jarvis Topic Manager — Security Patch Upgrade Script
# v1.0.0 / v1.0.1  →  v1.0.2
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
#
# Fixes applied:
#   HIGH  auth.py         LDAPS CERT_NONE → CERT_REQUIRED + two-phase service bind
#   HIGH  routes.py       Cross-site fetch blocked (Sec-Fetch-Site check)
#   HIGH  routes.py       Content-Type enforced — force=True removed on all mutations
#   HIGH  routes.py       Topic config allowlist + int bounds (partitions 1-1000, RF 1-9)
#   MED   app.py          Fail-closed on placeholder/empty secret_key at startup
#   MED   audit.py        CSV injection neutralised (csv.writer + formula prefix quoting)
#   LOW   nginx           CSP hardened: base-uri, form-action, frame-ancestors
#   BUG   nginx           Security headers now served on ALL routes (was silently absent
#                         due to add_header inheritance — pre-existing since v1.0.0)
#   BUG   index.html      Inline <script> moved to app/main.js (blocked by fixed CSP)
#   BUG   kafka_client    Consumer group state normalised to title case for confluent-kafka
#                         2.14.0 compat (state.name now returns STABLE not Stable)
#   DEP   AboutModal      Third-party versions updated; app version fetched live from API
#   DEP   packages        Flask 3.1.3, Werkzeug 3.1.8, gunicorn 26.0.0,
#                         confluent-kafka 2.14.0
#   DEP   frontend        Vue.js 3.5.35
#
# Online mode:  pip packages from PyPI, Vue from CDN.
# Offline mode: pip wheels from install/packages/python/, Vue from lib/vue.global.prod.js.
#               Run prepare-offline.sh on an internet host first, then transfer the bundle.
#
# Usage:
#   sudo bash install/upgrade-1.0.2.sh
#
# Safe to re-run. Backs up modified files to /opt/topic-manager/backup-pre-1.0.2/
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_HOME="/opt/topic-manager"
FRONTEND_DIR="/var/www/topic-manager"
CONFIG_DIR="/etc/topic-manager"
VENV="${APP_HOME}/venv"
SERVICE="topic-manager"
TM_DIR="${APP_HOME}/tm"
BACKUP_DIR="${APP_HOME}/backup-pre-1.0.2"
TARGET_VERSION="1.0.2"
FROM_VERSIONS=("1.0.0" "1.0.1")

PY_PKG_DIR="${REPO_DIR}/install/packages/python"
BUNDLED_VUE="${REPO_DIR}/lib/vue.global.prod.js"
VUE_VERSION="3.5.35"
VUE_URL="https://cdn.jsdelivr.net/npm/vue@${VUE_VERSION}/dist/vue.global.prod.js"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ─── root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash install/upgrade-1.0.2.sh"

# ─── version gate ────────────────────────────────────────────────────────────
INSTALLED_VER="$(cat "${TM_DIR}/VERSION" 2>/dev/null || echo 'unknown')"
VALID=false
for v in "${FROM_VERSIONS[@]}"; do [[ "$INSTALLED_VER" == "$v" ]] && VALID=true && break; done
$VALID || die "Upgrades v1.0.0 or v1.0.1 only. Installed: ${INSTALLED_VER}"
info "Upgrading Topic Manager ${INSTALLED_VER} → ${TARGET_VERSION}"

# ─── online detection ────────────────────────────────────────────────────────
ONLINE=false
curl -s --max-time 4 https://pypi.org > /dev/null 2>&1 && ONLINE=true
OFFLINE_PY_OK=false
[[ -d "$PY_PKG_DIR" && -n "$(ls -A "$PY_PKG_DIR" 2>/dev/null)" ]] && OFFLINE_PY_OK=true
OFFLINE_VUE_OK=false
[[ -f "$BUNDLED_VUE" ]] && grep -q "vue v${VUE_VERSION}" "$BUNDLED_VUE" 2>/dev/null && OFFLINE_VUE_OK=true

[[ $ONLINE == true ]] && info "Network mode: ONLINE" || {
    info "Network mode: OFFLINE"
    $OFFLINE_PY_OK || warn "No pip wheel cache at ${PY_PKG_DIR} — Python packages will be skipped."
    $OFFLINE_VUE_OK || warn "Bundled Vue is not ${VUE_VERSION} — Vue update will be skipped."
}

# ─── health check ────────────────────────────────────────────────────────────
PRE_HEALTH="$(curl -sk https://localhost/api/health 2>/dev/null || true)"
if echo "$PRE_HEALTH" | grep -q '"ok"'; then
    success "Pre-upgrade health check passed"
else
    warn "Pre-upgrade health check: ${PRE_HEALTH:-no response}"
    read -rp "Service may be down. Continue anyway? [y/N] " CONT
    [[ "$CONT" =~ ^[Yy]$ ]] || die "Aborted"
fi

# ─── backup ──────────────────────────────────────────────────────────────────
info "Backing up to ${BACKUP_DIR}..."
mkdir -p "$BACKUP_DIR"
for f in auth.py app.py routes.py audit.py kafka_client.py; do
    cp "${TM_DIR}/${f}" "${BACKUP_DIR}/${f}.bak" 2>/dev/null || true
done
cp "${FRONTEND_DIR}/index.html"                                     "${BACKUP_DIR}/index.html.bak"          2>/dev/null || true
cp "${FRONTEND_DIR}/app/components/modals/AboutModal.js"            "${BACKUP_DIR}/AboutModal.js.bak"       2>/dev/null || true
cp "${FRONTEND_DIR}/app/components/ConsumerGroupsTab.js"            "${BACKUP_DIR}/ConsumerGroupsTab.js.bak" 2>/dev/null || true
cp /etc/nginx/sites-available/topic-manager                         "${BACKUP_DIR}/topic-manager.nginx.bak" 2>/dev/null || true
success "Backup written to ${BACKUP_DIR}"

# ─── stop service ────────────────────────────────────────────────────────────
info "Stopping ${SERVICE}..."
systemctl stop "$SERVICE" || true
sleep 1

# ─── patch: auth.py ──────────────────────────────────────────────────────────
info "Patching tm/auth.py..."
cat > "${TM_DIR}/auth.py" <<'PYEOF'
import re
import ssl
from ldap3 import Server, Connection, ALL, SIMPLE, Tls
from ldap3.core.exceptions import LDAPException, LDAPBindError

_BIND_PW_PLACEHOLDER = 'CHANGE_ME'


def _build_tls(cfg):
    auth_cfg = cfg.get('auth', {})
    if 'ldaps' not in auth_cfg.get('ldap_server', '').lower():
        return None
    ca_file = auth_cfg.get('ldap_ca_cert') or None
    return Tls(validate=ssl.CERT_REQUIRED, ca_certs_file=ca_file)


def validate_credentials(cfg, username, password):
    """
    Bind to AD with user credentials, verify group membership.
    Returns (True, user_dict) or (False, error_string).

    Uses two-phase bind when ldap_bind_dn/ldap_bind_password are configured:
      1. Service-account bind for directory search.
      2. Re-bind with the found user DN to verify the supplied password.
    Falls back to direct user-bind when service credentials are absent.
    """
    auth_cfg = cfg.get('auth', {})
    ldap_url = auth_cfg.get('ldap_server', 'ldaps://dc1.int.crypticlight.com:636')
    base_dn = auth_cfg.get('ldap_base_dn', 'DC=int,DC=crypticlight,DC=com')
    required_group_dn = auth_cfg.get('required_group', '')
    domain = auth_cfg.get('ldap_domain', 'int.crypticlight.com')
    bind_dn = auth_cfg.get('ldap_bind_dn', '')
    bind_pw = auth_cfg.get('ldap_bind_password', '')

    sam = _normalise_sam(username)
    upn = f'{sam}@{domain}'
    use_service_bind = bool(bind_dn and bind_pw and _BIND_PW_PLACEHOLDER not in bind_pw)

    tls = _build_tls(cfg)
    server = Server(ldap_url, get_info=ALL, tls=tls, use_ssl='ldaps' in ldap_url.lower())

    bind_user = bind_dn if use_service_bind else upn
    bind_pass = bind_pw if use_service_bind else password
    ok, err, conn = _ldap_bind(server, bind_user, bind_pass)
    if not ok:
        return False, err

    entry, err = _ldap_search_user(conn, base_dn, sam)
    if entry is None:
        return False, err

    user_dn = str(entry.distinguishedName) if entry.distinguishedName else ''
    member_of = [str(g).lower() for g in (entry.memberOf.values if entry.memberOf else [])]

    if use_service_bind and user_dn:
        ok, err, user_conn = _ldap_bind(server, user_dn, password)
        if not ok:
            return False, err
        user_conn.unbind()

    if required_group_dn and required_group_dn.lower() not in member_of:
        return False, f'Not a member of required group: {required_group_dn}'

    return True, {
        'username': sam,
        'display_name': str(entry.displayName) if entry.displayName else sam,
        'email': str(entry.mail) if entry.mail else '',
        'upn': upn,
    }


def _normalise_sam(username):
    if '\\' in username:
        return username.split('\\', 1)[1]
    if '@' in username:
        return username.split('@', 1)[0]
    return username


def _ldap_bind(server, user, password):
    try:
        conn = Connection(server, user=user, password=password,
                          authentication=SIMPLE, auto_bind=True)
        return True, None, conn
    except LDAPBindError:
        return False, 'Invalid credentials', None
    except LDAPException as exc:
        return False, f'LDAP error: {exc}', None


def _ldap_search_user(conn, base_dn, sam):
    conn.search(
        search_base=base_dn,
        search_filter=f'(sAMAccountName={_ldap_escape(sam)})',
        attributes=['memberOf', 'displayName', 'sAMAccountName', 'mail', 'distinguishedName'],
    )
    if not conn.entries:
        conn.unbind()
        return None, 'User not found in directory'
    entry = conn.entries[0]
    conn.unbind()
    return entry, None


def _ldap_escape(value):
    """Escape special characters in LDAP filter values."""
    return re.sub(r'([\\*\(\)\x00])', lambda m: f'\\{ord(m.group(1)):02x}', value)

PYEOF
success "auth.py patched"

# ─── patch: app.py ───────────────────────────────────────────────────────────
info "Patching tm/app.py..."
cat > "${TM_DIR}/app.py" <<'PYEOF'
import os
import secrets
import logging
import logging.handlers
from flask import Flask
from .config import load_config
from .models import init_db


def create_app(config_path=None):
    app = Flask(__name__, static_folder=None)
    cfg = load_config(config_path)

    _secret = cfg.get('server', {}).get('secret_key', '')
    if not _secret or 'CHANGE_ME' in _secret:
        raise RuntimeError(
            'server.secret_key is not set or still contains the placeholder. '
            'Generate one with: python3 -c "import secrets; print(secrets.token_hex(32))"'
        )
    app.secret_key = _secret
    app.config['SESSION_COOKIE_HTTPONLY'] = True
    app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
    app.config['SESSION_COOKIE_SECURE']   = True
    app.config['PERMANENT_SESSION_LIFETIME'] = (
        cfg.get('session', {}).get('timeout_minutes', 30) * 60
    )
    app.config['TM_CONFIG'] = cfg

    _setup_logging(cfg, app)
    init_db(cfg)

    from .routes import bp
    app.register_blueprint(bp)
    return app


def _setup_logging(cfg, app):
    log_cfg = cfg.get('logging', {})
    level   = getattr(logging, log_cfg.get('log_level', 'INFO').upper(), logging.INFO)
    app.logger.setLevel(level)
    logging.getLogger('tm').setLevel(level)

    if log_cfg.get('syslog_enabled', False):
        try:
            handler = logging.handlers.SysLogHandler(
                address='/dev/log',
                facility=logging.handlers.SysLogHandler.LOG_DAEMON,
            )
            handler.setFormatter(
                logging.Formatter('topic-manager[%(process)d]: %(levelname)s %(message)s')
            )
            handler.setLevel(level)
            app.logger.addHandler(handler)
            logging.getLogger('tm').addHandler(handler)
        except Exception as exc:
            app.logger.warning('Could not attach syslog handler: %s', exc)
PYEOF
success "app.py patched"

# ─── patch: routes.py ────────────────────────────────────────────────────────
info "Patching tm/routes.py..."
cat > "${TM_DIR}/routes.py" <<'PYEOF'
import os
import re
import logging
from functools import wraps
from flask import Blueprint, request, jsonify, session, current_app, make_response

from . import auth, kafka_client, audit
from .models import (get_db, create_session, validate_session, touch_session,
                     delete_session, count_active_sessions, cleanup_expired_sessions)
from .config import get_active_cluster, get_cluster_by_id

bp = Blueprint('api', __name__, url_prefix='/api')
TM_VERSION = open(os.path.join(os.path.dirname(__file__), 'VERSION')).read().strip()
log = logging.getLogger(__name__)

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


def _cfg():
    return current_app.config['TM_CONFIG']

def _timeout():
    return _cfg().get('session', {}).get('timeout_minutes', 30)

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
    return c

def _parse_json_body():
    if not request.is_json:
        return None, (jsonify({'error': 'Content-Type must be application/json'}), 415)
    data = request.get_json(silent=True)
    if data is None:
        return None, (jsonify({'error': 'Invalid or empty JSON body'}), 400)
    return data, None

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if request.method not in ('GET', 'HEAD', 'OPTIONS'):
            if request.headers.get('Sec-Fetch-Site') == 'cross-site':
                return jsonify({'error': 'Cross-site requests are not permitted'}), 403
        sid = session.get('sid')
        if not sid:
            return jsonify({'error': 'Authentication required'}), 401
        db = get_db(_cfg())
        username = validate_session(db, sid)
        if not username:
            db.close(); session.clear()
            return jsonify({'error': 'Session expired'}), 401
        touch_session(db, sid, _timeout())
        db.close()
        request.current_user = session.get('user', {})
        return f(*args, **kwargs)
    return decorated


@bp.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok', 'version': TM_VERSION})

@bp.route('/auth/login', methods=['POST'])
def login():
    data, err = _parse_json_body()
    if err: return err
    username = (data.get('username') or '').strip()
    password = data.get('password') or ''
    if not username or not password:
        return jsonify({'error': 'Username and password required'}), 400
    ok, result = auth.validate_credentials(_cfg(), username, password)
    if not ok:
        log.warning('Login failed for user %s from %s: %s', username, request.remote_addr, result)
        return jsonify({'error': result}), 401
    cfg = _cfg(); db = get_db(cfg)
    cleanup_expired_sessions(db)
    max_s = _max_sessions()
    if max_s > 0:
        active = count_active_sessions(db, result['username'])
        if active >= max_s:
            db.close()
            log.warning('Session limit (%d) reached for %s', max_s, result['username'])
            return jsonify({'error': f'Concurrent session limit reached ({active}/{max_s}). Sign out from another session first.'}), 429
    sid = create_session(db, result['username'], _timeout(), request.remote_addr)
    db.close()
    session.permanent = True
    session['sid']  = sid
    session['user'] = result
    log.info('Login success: user=%s ip=%s', result['username'], request.remote_addr)
    return jsonify({'user': result})

@bp.route('/auth/logout', methods=['POST'])
@require_auth
def logout():
    sid = session.get('sid')
    if sid:
        db = get_db(_cfg()); delete_session(db, sid); db.close()
    log.info('Logout: user=%s', session.get('user', {}).get('username', '?'))
    session.clear()
    return jsonify({'ok': True})

@bp.route('/auth/whoami', methods=['GET'])
@require_auth
def whoami():
    return jsonify({'user': session['user']})

@bp.route('/clusters', methods=['GET'])
@require_auth
def list_clusters():
    cfg = _cfg()
    safe = [{'id': c.get('id'), 'name': c.get('name'),
             'bootstrap_servers': c.get('bootstrap_servers'),
             'security_protocol': c.get('security_protocol', 'PLAINTEXT'),
             'active': c.get('active', False)} for c in cfg.get('clusters', [])]
    return jsonify({'clusters': safe})

@bp.route('/clusters/<cluster_id>/test', methods=['GET'])
@require_auth
def test_cluster(cluster_id):
    cfg = _cfg(); c = get_cluster_by_id(cfg, cluster_id)
    if not c: return jsonify({'error': 'Cluster not found'}), 404
    ok, result = kafka_client.test_connection(c)
    return jsonify({'ok': ok, 'detail': result})

@bp.route('/clusters/active', methods=['PUT'])
@require_auth
def set_active_cluster():
    data, err = _parse_json_body()
    if err: return err
    cluster_id = data.get('cluster_id')
    if not get_cluster_by_id(_cfg(), cluster_id):
        return jsonify({'error': 'Cluster not found'}), 404
    session['active_cluster'] = cluster_id
    return jsonify({'ok': True, 'active_cluster': cluster_id})

@bp.route('/broker/metadata', methods=['GET'])
@require_auth
def broker_metadata():
    try:
        return jsonify(kafka_client.get_cluster_metadata(_cluster()))
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

@bp.route('/topics', methods=['GET'])
@require_auth
def list_topics():
    include_internal = request.args.get('internal', 'false').lower() == 'true'
    try:
        return jsonify({'topics': kafka_client.list_topics(_cluster(), include_internal)})
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

@bp.route('/topics', methods=['POST'])
@require_auth
def create_topic():
    data, err = _parse_json_body()
    if err: return err
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
    raw_config = data.get('config', {})
    if not isinstance(raw_config, dict):
        return jsonify({'error': 'config must be an object'}), 400
    config = {k: str(v) for k, v in raw_config.items() if k in _ALLOWED_TOPIC_CONFIGS}
    if data.get('retention_ms'):        config['retention.ms']        = str(data['retention_ms'])
    if data.get('retention_bytes'):     config['retention.bytes']     = str(data['retention_bytes'])
    if data.get('cleanup_policy'):      config['cleanup.policy']      = str(data['cleanup_policy'])
    if data.get('compression_type'):    config['compression.type']    = str(data['compression_type'])
    if data.get('min_insync_replicas'): config['min.insync.replicas'] = str(data['min_insync_replicas'])
    if data.get('max_message_bytes'):   config['max.message.bytes']   = str(data['max_message_bytes'])
    cluster = _cluster()
    try:
        kafka_client.create_topic(cluster, name, partitions, rf, config)
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502
    user = session['user']['username']
    audit.log_action(_cfg(), user, 'CREATE', name,
                     f'partitions={partitions}, rf={rf}, config={config}', cluster.get('id', ''))
    log.info('CREATE topic=%s user=%s', name, user)
    return jsonify({'ok': True, 'name': name}), 201

@bp.route('/topics/<path:name>/config', methods=['GET'])
@require_auth
def get_topic_config(name):
    try:
        return jsonify({'name': name, 'config': kafka_client.get_topic_config(_cluster(), name)})
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

@bp.route('/topics/<path:name>/config', methods=['PUT'])
@require_auth
def update_topic_config(name):
    data, err = _parse_json_body()
    if err: return err
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

@bp.route('/consumer-groups', methods=['GET'])
@require_auth
def list_consumer_groups():
    try:
        return jsonify({'groups': kafka_client.list_consumer_groups(_cluster())})
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

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

@bp.route('/version', methods=['GET'])
def get_version():
    return jsonify({'version': TM_VERSION, 'product': 'Jarvis Topic Manager'})

_PUBLIC_KEYS = {'banner_enabled', 'banner_text', 'banner_bg', 'banner_fg', 'dow_enabled'}
_ALL_KEYS    = _PUBLIC_KEYS
_DEFAULTS    = {'banner_enabled':'false','banner_text':'UNCLASSIFIED',
                'banner_bg':'green','banner_fg':'white','dow_enabled':'false'}

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
    db = get_db(_cfg()); data = _read_settings(db, _PUBLIC_KEYS); db.close()
    return jsonify(data)

@bp.route('/settings', methods=['GET'])
@require_auth
def get_settings():
    db = get_db(_cfg()); data = _read_settings(db, _ALL_KEYS); db.close()
    return jsonify(data)

@bp.route('/settings', methods=['PUT'])
@require_auth
def update_settings():
    data, err = _parse_json_body()
    if err: return err
    db = get_db(_cfg())
    for key, value in data.items():
        if key in _ALL_KEYS:
            db.execute('INSERT OR REPLACE INTO app_settings (key, value) VALUES (?,?)',
                       (key, str(value)))
    db.commit(); db.close()
    return jsonify({'ok': True})
PYEOF
success "routes.py patched"

# ─── patch: audit.py ─────────────────────────────────────────────────────────
info "Patching tm/audit.py..."
cat > "${TM_DIR}/audit.py" <<'PYEOF'
import csv
import io
from datetime import datetime, timezone
from .models import get_db

_FORMULA_CHARS = ('=', '+', '-', '@', '\t', '\r')

def _csv_safe(value):
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
    db.commit(); db.close()

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
        'entries': [{'id':r[0],'ts':r[1],'user':r[2],'action':r[3],
                     'target':r[4],'detail':r[5],'cluster_id':r[6]} for r in rows],
        'total': total, 'page': page, 'per_page': per_page,
        'pages': max(1, (total + per_page - 1) // per_page),
    }

def export_audit_csv(cfg):
    db = get_db(cfg)
    rows = db.execute(
        'SELECT ts, user, action, target, detail, cluster_id FROM audit_log ORDER BY id DESC'
    ).fetchall()
    db.close()
    buf = io.StringIO()
    writer = csv.writer(buf, quoting=csv.QUOTE_ALL, lineterminator='\n')
    writer.writerow(['timestamp', 'user', 'action', 'target', 'detail', 'cluster_id'])
    for r in rows:
        writer.writerow([_csv_safe(c) for c in r])
    return buf.getvalue()
PYEOF
success "audit.py patched"

# ─── patch: kafka_client.py ──────────────────────────────────────────────────
info "Patching tm/kafka_client.py (state normalisation for confluent-kafka 2.14+)..."
sed -i "s/g\.state\.name if hasattr(g\.state, 'name') else str(g\.state)/g.state.name.title() if hasattr(g.state, 'name') else str(g.state).title()/" \
    "${TM_DIR}/kafka_client.py"
success "kafka_client.py patched"

# ─── patch: VERSION ──────────────────────────────────────────────────────────
echo "1.0.2" > "${TM_DIR}/VERSION"
chown -R topic-manager:topic-manager "${TM_DIR}"
success "VERSION → 1.0.2"

# ─── patch: config.yaml — add ldap_ca_cert if missing ───────────────────────
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
if ! grep -q 'ldap_ca_cert' "$CONFIG_FILE"; then
    sed -i '/ldap_server:/a\  ldap_ca_cert: ""         # PEM CA bundle; blank = system trust store' "$CONFIG_FILE"
    success "ldap_ca_cert added to config.yaml"
fi

# ─── nginx: security headers snippet ─────────────────────────────────────────
# IMPORTANT: nginx cancels ALL parent add_header directives when a location
# block defines its own add_header. Security headers must be in a snippet
# included explicitly in every location that sets Cache-Control.
info "Installing nginx security headers snippet..."
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/tm-security-headers.conf <<'NGINXEOF'
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options nosniff always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'; form-action 'none'; base-uri 'self';" always;
NGINXEOF
success "Snippet written to /etc/nginx/snippets/tm-security-headers.conf"

# ─── nginx: replace site config with snippet-based version ───────────────────
info "Replacing nginx site config..."
cat > /etc/nginx/sites-available/topic-manager <<'NGINXEOF'
upstream tm_backend {
    server 127.0.0.1:5001;
    keepalive 16;
}
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl http2;
    server_name _;

    ssl_certificate     /etc/topic-manager/tls/server.crt;
    ssl_certificate_key /etc/topic-manager/tls/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:TM:10m;
    ssl_session_timeout 10m;

    keepalive_timeout 65s;
    keepalive_requests 200;

    root /var/www/topic-manager;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
        expires -1;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        include /etc/nginx/snippets/tm-security-headers.conf;
    }

    location ~* \.(js|css)$ {
        expires 1d;
        add_header Cache-Control "public, max-age=86400";
        include /etc/nginx/snippets/tm-security-headers.conf;
    }

    location /api/ {
        proxy_pass         http://tm_backend;
        proxy_http_version 1.1;
        proxy_set_header   Connection "";
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout    90s;
        proxy_connect_timeout 15s;
        proxy_send_timeout    30s;
        proxy_buffering    on;
        proxy_buffer_size  8k;
        proxy_buffers      8 8k;
        include /etc/nginx/snippets/tm-security-headers.conf;
    }

    access_log /var/log/nginx/topic-manager-access.log;
    error_log  /var/log/nginx/topic-manager-error.log;
}
NGINXEOF
nginx -t 2>/dev/null && success "nginx config valid" || die "nginx config test failed"

# ─── frontend: app/main.js (move inline script out of index.html) ─────────────
# The inline <script> in index.html is blocked by the enforced CSP (script-src
# 'self' — no 'unsafe-inline'). It was previously invisible because security
# headers were never actually served due to the nginx add_header bug above.
info "Installing app/main.js and updating index.html..."
mkdir -p "${FRONTEND_DIR}/app"
cat > "${FRONTEND_DIR}/app/main.js" <<'JSEOF'
const { createApp, ref, computed, onMounted } = Vue;

const App = {
    components: { LoginView, TopBar, TopicsTab, ConsumerGroupsTab, AuditTab, SettingsTab, AboutModal },
    setup() {
        const user          = ref(null);
        const currentTab    = ref('topics');
        const clusters      = ref([]);
        const activeCluster = ref('');
        const brokerMeta    = ref(null);
        const topicCount    = ref(0);
        const showAbout     = ref(false);
        const version       = ref('1.0.2');

        async function fetchVersion() {
            try {
                const r = await fetch('/api/version');
                if (r.ok) { const d = await r.json(); version.value = d.version || '1.0.2'; }
            } catch (_) {}
        }

        async function fetchClusters() {
            try {
                const r = await fetch('/api/clusters');
                if (r.ok) {
                    const d = await r.json();
                    clusters.value = d.clusters || [];
                    const active = clusters.value.find(c => c.active);
                    if (active && !activeCluster.value) activeCluster.value = active.id;
                }
            } catch (_) {}
        }

        async function checkSession() {
            try {
                const r = await fetch('/api/auth/whoami');
                if (r.ok) { const d = await r.json(); user.value = d.user; }
            } catch (_) {}
        }

        async function logout() {
            await fetch('/api/auth/logout', { method: 'POST' });
            user.value = null; currentTab.value = 'topics';
        }

        function onLoggedIn(u) { user.value = u; fetchClusters(); fetchVersion(); }

        function onClusterChanged(id) {
            activeCluster.value = id;
            fetch('/api/clusters/active', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ cluster_id: id }),
            });
        }

        const colorMap = { green:'#16a34a', blue:'#2563eb', purple:'#7c3aed',
                           red:'#dc2626', orange:'#ea580c', yellow:'#ca8a04' };
        const fgMap    = { white:'#ffffff', black:'#000000', grey:'#d1d5db' };

        function applyBannerFromSettings(s) {
            const enabled = s.banner_enabled === 'true';
            const bg  = colorMap[s.banner_bg]  || '#16a34a';
            const fg  = fgMap[s.banner_fg]     || '#ffffff';
            const txt = s.banner_text          || 'UNCLASSIFIED';
            ['banner-top', 'banner-bot'].forEach(id => {
                const el = document.getElementById(id);
                if (!el) return;
                el.style.display    = enabled ? 'block' : 'none';
                el.style.background = bg;
                el.style.color      = fg;
                el.textContent      = txt;
            });
            const pad = enabled ? '26px' : '0px';
            document.body.style.paddingTop    = pad;
            document.body.style.paddingBottom = pad;
        }

        onMounted(async () => {
            const t = localStorage.getItem('tmTheme') || 'dark';
            document.body.classList.remove('light-mode', 'cb-mode');
            if (t === 'light') document.body.classList.add('light-mode');
            if (t === 'cb')    document.body.classList.add('cb-mode');
            try {
                const r = await fetch('/api/settings/public');
                if (r.ok) applyBannerFromSettings(await r.json());
            } catch (_) {}
            checkSession().then(() => { if (user.value) { fetchClusters(); fetchVersion(); } });
        });

        return { user, currentTab, clusters, activeCluster, brokerMeta, topicCount,
                 showAbout, version, onLoggedIn, logout, onClusterChanged };
    },
    template: `
<div id="app-shell" v-if="user">
  <TopBar :user="user" :clusters="clusters" :active-cluster-id="activeCluster"
    :broker-meta="brokerMeta" @logout="logout" @cluster-changed="onClusterChanged"
    @open-about="showAbout = true" />
  <nav class="app-nav">
    <button class="ntab" :class="{ act: currentTab === 'topics' }"   @click="currentTab = 'topics'">Topics</button>
    <button class="ntab" :class="{ act: currentTab === 'cgroups' }"  @click="currentTab = 'cgroups'">Consumer Groups</button>
    <button class="ntab" :class="{ act: currentTab === 'audit' }"    @click="currentTab = 'audit'">Audit Log</button>
    <button class="ntab" :class="{ act: currentTab === 'settings' }" @click="currentTab = 'settings'">Settings</button>
  </nav>
  <div class="app-content">
    <TopicsTab         v-if="currentTab === 'topics'"   :cluster-id="activeCluster" @topic-count="topicCount = $event" />
    <ConsumerGroupsTab v-if="currentTab === 'cgroups'"  :cluster-id="activeCluster" />
    <AuditTab          v-if="currentTab === 'audit'" />
    <SettingsTab       v-if="currentTab === 'settings'" :clusters="clusters"
      :active-cluster-id="activeCluster" :version="version"
      @open-about="showAbout = true" @cluster-changed="onClusterChanged" />
  </div>
  <AboutModal v-if="showAbout" @close="showAbout = false" />
</div>
<LoginView v-else @logged-in="onLoggedIn" />
`,
};

createApp(App).mount('#app-mount');
JSEOF

# Replace index.html inline script with external reference, bump cache tokens
python3 - <<'PYEOF'
import re, sys

path = '/var/www/topic-manager/index.html'
with open(path) as f:
    html = f.read()

# Remove inline <script>...</script> block (the Vue app bootstrap)
html = re.sub(r'\n<script>\nconst \{ createApp.*?createApp\(App\)\.mount\(\'#app-mount\'\);\n</script>',
              '', html, flags=re.DOTALL)

# Add main.js reference after the last component script tag
html = html.replace(
    '<script src="/app/components/SettingsTab.js?v=1000"></script>',
    '<script src="/app/components/SettingsTab.js?v=1001"></script>\n<script src="/app/main.js?v=1001"></script>'
)

# Bump all other component cache tokens
html = re.sub(r'\?v=1000', '?v=1001', html)

with open(path, 'w') as f:
    f.write(html)
print('index.html updated')
PYEOF
success "app/main.js installed, index.html updated (cache token → 1001)"

# ─── frontend: AboutModal versions ───────────────────────────────────────────
info "Updating AboutModal.js versions..."
sed -i \
    -e "s/version: '1\.0\.0'/version: '1.0.2'/" \
    -e "s/'3\.5\.13'/'3.5.35'/" \
    -e "s/'3\.1\.0'/'3.1.3'/" \
    -e "s/'23\.0\.0'/'26.0.0'/" \
    -e "s/'2\.6\.1'/'2.14.0'/" \
    -e "s/'3\.1\.3',    license: 'BSD-3'/'3.1.8',    license: 'BSD-3'/" \
    "${FRONTEND_DIR}/app/components/modals/AboutModal.js"

# Add mounted() hook to fetch version dynamically if not already present
if ! grep -q "fetch('/api/version')" "${FRONTEND_DIR}/app/components/modals/AboutModal.js"; then
    sed -i "/emits: \['close'\],/a\\    mounted() { fetch('/api/version').then(r => r.ok ? r.json() : null).then(d => { if (d \&\& d.version) this.version = d.version; }).catch(() => {}); }," \
        "${FRONTEND_DIR}/app/components/modals/AboutModal.js"
fi
chown www-data:www-data "${FRONTEND_DIR}/app/components/modals/AboutModal.js"
success "AboutModal.js versions updated"

# ─── frontend: fix ownership ─────────────────────────────────────────────────
chown www-data:www-data "${FRONTEND_DIR}/app/main.js" "${FRONTEND_DIR}/index.html"

# ─── LDAPS warning ───────────────────────────────────────────────────────────
warn "LDAPS now uses CERT_REQUIRED. Verify DC cert is trusted:"
warn "  openssl s_client -connect dc1.int.crypticlight.com:636 \\"
warn "    -CAfile /etc/ssl/certs/ca-certificates.crt 2>&1 | grep -E 'Verify|subject'"
warn "If validation fails → set ldap_ca_cert in ${CONFIG_FILE}"
echo ""
warn "Service account bind: if ldap_bind_password is not CHANGE_ME, ensure"
warn "  ldap_bind_dn in ${CONFIG_FILE} matches the account's actual AD DN."
warn "  Verify with: ldapsearch -H ldaps://dc1... -D '<bind_dn>' -w '<pw>' '(sAMAccountName=*)'"

# ─── Python package upgrades ─────────────────────────────────────────────────
# Install in two separate calls: service-critical stack first (Flask / Werkzeug /
# gunicorn), then confluent-kafka. If confluent-kafka fails the web service is
# still intact and can start. Installing all four in one call lets pip uninstall
# gunicorn before the download of conflent-kafka completes, leaving the service
# unbootable if the combined install is then aborted.
info "Upgrading Python packages (Flask / Werkzeug / gunicorn)..."
if [[ $ONLINE == true ]]; then
    "${VENV}/bin/pip" install "Flask==3.1.3" "Werkzeug==3.1.8" "gunicorn==26.0.0" \
        || die "pip install of Flask/Werkzeug/gunicorn failed — service stack not upgraded"
    success "Flask / Werkzeug / gunicorn upgraded from PyPI"
elif $OFFLINE_PY_OK; then
    "${VENV}/bin/pip" install --no-index --find-links="$PY_PKG_DIR" \
        "Flask==3.1.3" "Werkzeug==3.1.8" "gunicorn==26.0.0" \
        || die "pip install of Flask/Werkzeug/gunicorn failed (offline) — service stack not upgraded"
    success "Flask / Werkzeug / gunicorn upgraded from offline cache"
else
    warn "Python package upgrade skipped — no internet and no offline cache at ${PY_PKG_DIR}"
fi

info "Upgrading confluent-kafka..."
if [[ $ONLINE == true ]]; then
    "${VENV}/bin/pip" install "confluent-kafka==2.14.0" \
        || warn "confluent-kafka upgrade failed — Kafka operations may use old version; re-run manually: ${VENV}/bin/pip install confluent-kafka==2.14.0"
    success "confluent-kafka upgraded from PyPI"
elif $OFFLINE_PY_OK; then
    "${VENV}/bin/pip" install --no-index --find-links="$PY_PKG_DIR" "confluent-kafka==2.14.0" \
        || warn "confluent-kafka upgrade failed (offline) — Kafka operations may use old version"
    success "confluent-kafka upgraded from offline cache"
fi

# ─── Vue.js update ───────────────────────────────────────────────────────────
VUE_DEST="${FRONTEND_DIR}/lib/vue.global.prod.js"
info "Updating Vue.js to ${VUE_VERSION}..."
if [[ $ONLINE == true ]]; then
    cp "${VUE_DEST}" "${BACKUP_DIR}/vue.global.prod.js.bak" 2>/dev/null || true
    if curl -fsSL --max-time 20 "$VUE_URL" -o "${VUE_DEST}.tmp" 2>/dev/null && \
       grep -q "vue v${VUE_VERSION}" "${VUE_DEST}.tmp" 2>/dev/null; then
        mv "${VUE_DEST}.tmp" "$VUE_DEST"
        chown www-data:www-data "$VUE_DEST"
        success "Vue.js → ${VUE_VERSION} (CDN)"
    else
        rm -f "${VUE_DEST}.tmp"
        warn "Vue CDN download failed — keeping current version"
    fi
elif $OFFLINE_VUE_OK; then
    cp "${VUE_DEST}" "${BACKUP_DIR}/vue.global.prod.js.bak" 2>/dev/null || true
    cp "$BUNDLED_VUE" "$VUE_DEST"
    chown www-data:www-data "$VUE_DEST"
    success "Vue.js → ${VUE_VERSION} (offline bundle)"
else
    warn "Vue.js not updated — no internet and bundled lib/ is not ${VUE_VERSION}"
fi

# ─── restart and verify ──────────────────────────────────────────────────────
info "Restarting services..."
systemctl start "$SERVICE"
systemctl reload nginx
sleep 3

POST_HEALTH="$(curl -sk https://localhost/api/health 2>/dev/null || true)"
if echo "$POST_HEALTH" | grep -q '"1.0.2"'; then
    success "Post-upgrade health: ${POST_HEALTH}"
elif echo "$POST_HEALTH" | grep -q '"ok"'; then
    warn "Service up but unexpected version: ${POST_HEALTH}"
else
    die "Health check FAILED: ${POST_HEALTH:-no response}. Check: journalctl -u ${SERVICE} -n 50"
fi

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Topic Manager upgrade to v1.0.2 complete.${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Backup:  ${BACKUP_DIR}/"
echo "  Logs:    journalctl -u ${SERVICE} -f"
echo "  Config:  ${CONFIG_FILE}  ← verify ldap_bind_dn / ldap_bind_password"
echo ""
