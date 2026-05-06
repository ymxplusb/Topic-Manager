import os
import re
from functools import wraps
from flask import Blueprint, request, jsonify, session, current_app, make_response

from . import auth, kafka_client, audit
from .config import get_active_cluster, get_cluster_by_id

bp = Blueprint('api', __name__, url_prefix='/api')

TM_VERSION = open(os.path.join(os.path.dirname(__file__), 'VERSION')).read().strip()


# ── auth decorator ────────────────────────────────────────────────
def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'user' not in session:
            return jsonify({'error': 'Authentication required'}), 401
        return f(*args, **kwargs)
    return decorated


def _cfg():
    return current_app.config['TM_CONFIG']


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


# ── health ────────────────────────────────────────────────────────
@bp.route('/health')
def health():
    return jsonify({'status': 'ok', 'version': TM_VERSION})


# ── auth ──────────────────────────────────────────────────────────
@bp.route('/auth/login', methods=['POST'])
def login():
    data = request.get_json(force=True)
    username = (data.get('username') or '').strip()
    password = data.get('password') or ''
    if not username or not password:
        return jsonify({'error': 'Username and password required'}), 400

    ok, result = auth.validate_credentials(_cfg(), username, password)
    if not ok:
        return jsonify({'error': result}), 401

    session.permanent = True
    session['user'] = result
    return jsonify({'user': result})


@bp.route('/auth/logout', methods=['POST'])
@require_auth
def logout():
    session.clear()
    return jsonify({'ok': True})


@bp.route('/auth/whoami')
@require_auth
def whoami():
    return jsonify({'user': session['user']})


# ── clusters ──────────────────────────────────────────────────────
@bp.route('/clusters')
@require_auth
def list_clusters():
    cfg = _cfg()
    safe = []
    for c in cfg.get('clusters', []):
        safe.append({
            'id': c.get('id'),
            'name': c.get('name'),
            'bootstrap_servers': c.get('bootstrap_servers'),
            'security_protocol': c.get('security_protocol', 'PLAINTEXT'),
            'active': c.get('active', False),
        })
    return jsonify({'clusters': safe})


@bp.route('/clusters/<cluster_id>/test')
@require_auth
def test_cluster(cluster_id):
    cfg = _cfg()
    c = get_cluster_by_id(cfg, cluster_id)
    if not c:
        return jsonify({'error': 'Cluster not found'}), 404
    ok, result = kafka_client.test_connection(c)
    return jsonify({'ok': ok, 'detail': result})


@bp.route('/clusters/active', methods=['PUT'])
@require_auth
def set_active_cluster():
    data = request.get_json(force=True)
    cluster_id = data.get('cluster_id')
    if not get_cluster_by_id(_cfg(), cluster_id):
        return jsonify({'error': 'Cluster not found'}), 404
    session['active_cluster'] = cluster_id
    return jsonify({'ok': True, 'active_cluster': cluster_id})


# ── broker metadata ───────────────────────────────────────────────
@bp.route('/broker/metadata')
@require_auth
def broker_metadata():
    try:
        meta = kafka_client.get_cluster_metadata(_cluster())
        return jsonify(meta)
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502


# ── topics ────────────────────────────────────────────────────────
@bp.route('/topics')
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
    data = request.get_json(force=True)
    name = (data.get('name') or '').strip()
    if not name or not re.match(r'^[a-zA-Z0-9._-]+$', name):
        return jsonify({'error': 'Invalid topic name'}), 400

    partitions = int(data.get('partitions', 3))
    rf = int(data.get('replication_factor', 3))
    config = data.get('config', {})

    # Build config dict from convenience fields
    if data.get('retention_ms'):
        config['retention.ms'] = str(data['retention_ms'])
    if data.get('retention_bytes'):
        config['retention.bytes'] = str(data['retention_bytes'])
    if data.get('cleanup_policy'):
        config['cleanup.policy'] = data['cleanup_policy']
    if data.get('compression_type'):
        config['compression.type'] = data['compression_type']
    if data.get('min_insync_replicas'):
        config['min.insync.replicas'] = str(data['min_insync_replicas'])
    if data.get('max_message_bytes'):
        config['max.message.bytes'] = str(data['max_message_bytes'])

    cluster = _cluster()
    try:
        kafka_client.create_topic(cluster, name, partitions, rf, config)
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

    audit.log_action(
        _cfg(), session['user']['username'], 'CREATE', name,
        f'partitions={partitions}, rf={rf}, config={config}',
        cluster.get('id', '')
    )
    return jsonify({'ok': True, 'name': name}), 201


@bp.route('/topics/<path:name>/config')
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
    data = request.get_json(force=True)
    updates = data.get('updates', {})
    if not updates:
        return jsonify({'error': 'No updates provided'}), 400

    cluster = _cluster()
    try:
        kafka_client.update_topic_config(cluster, name, updates)
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

    audit.log_action(
        _cfg(), session['user']['username'], 'UPDATE_CONFIG', name,
        str(updates), cluster.get('id', '')
    )
    return jsonify({'ok': True})


@bp.route('/topics/<path:name>', methods=['DELETE'])
@require_auth
def delete_topic(name):
    cluster = _cluster()
    try:
        kafka_client.delete_topic(cluster, name)
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502

    audit.log_action(
        _cfg(), session['user']['username'], 'DELETE', name,
        'confirmed by user', cluster.get('id', '')
    )
    return jsonify({'ok': True})


# ── consumer groups ───────────────────────────────────────────────
@bp.route('/consumer-groups')
@require_auth
def list_consumer_groups():
    try:
        groups = kafka_client.list_consumer_groups(_cluster())
        return jsonify({'groups': groups})
    except Exception as exc:
        return jsonify({'error': str(exc)}), 502


# ── audit log ─────────────────────────────────────────────────────
@bp.route('/audit')
@require_auth
def get_audit():
    page = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 50, type=int)
    return jsonify(audit.get_audit_log(_cfg(), page, per_page))


@bp.route('/audit/export')
@require_auth
def export_audit():
    csv_data = audit.export_audit_csv(_cfg())
    resp = make_response(csv_data)
    resp.headers['Content-Type'] = 'text/csv'
    resp.headers['Content-Disposition'] = 'attachment; filename="topic-manager-audit.csv"'
    return resp


# ── version ───────────────────────────────────────────────────────
@bp.route('/version')
def get_version():
    return jsonify({'version': TM_VERSION, 'product': 'Jarvis Topic Manager'})
