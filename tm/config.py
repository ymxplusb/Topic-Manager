import os
import yaml

_DEFAULT_CONFIG_PATH = '/etc/topic-manager/config.yaml'
_config_cache = None


def load_config(path=None):
    global _config_cache
    if _config_cache is not None:
        return _config_cache

    config_path = path or os.environ.get('TM_CONFIG', _DEFAULT_CONFIG_PATH)
    with open(config_path, 'r') as f:
        cfg = yaml.safe_load(f)

    # Environment variable overrides for secrets
    if os.environ.get('TM_SECRET_KEY'):
        cfg.setdefault('server', {})['secret_key'] = os.environ['TM_SECRET_KEY']
    if os.environ.get('TM_LDAP_BIND_PASSWORD'):
        cfg.setdefault('auth', {})['ldap_bind_password'] = os.environ['TM_LDAP_BIND_PASSWORD']

    _config_cache = cfg
    return cfg


def get_active_cluster(cfg):
    for cluster in cfg.get('clusters', []):
        if cluster.get('active', False):
            return cluster
    clusters = cfg.get('clusters', [])
    return clusters[0] if clusters else None


def get_cluster_by_id(cfg, cluster_id):
    for cluster in cfg.get('clusters', []):
        if cluster.get('id') == cluster_id:
            return cluster
    return None
