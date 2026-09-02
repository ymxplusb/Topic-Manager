import logging
import os

import yaml

from . import clusters as cluster_store

log = logging.getLogger(__name__)

_DEFAULT_CONFIG_PATH = '/etc/topic-manager/config.yaml'

# THERE WERE TWO CACHES, and fixing one looked like success. This module used
# to return `_config_cache` forever after the first load, and tm/app.py froze a
# SECOND copy into app.config['TM_CONFIG'] that every route read. With four
# gunicorn workers a newly added cluster appeared on roughly one request in
# four — intermittent, and it reads as a Kafka fault, not a config fault.
#
# Both are gone. The file is re-read when its (inode, size, mtime_ns) changes,
# so every worker converges on its own with no IPC, and routes call load_config
# per request instead of holding a dict from process start.
_cache_key = None
_cache_path = None
_cache_cfg = None


def _stat_key(path):
    # Returns None when the file is absent rather than raising, so the caller
    # decides. The config is required, so load_config() turns that into a clear
    # message; it must not surface as an unhandled OSError inside a request.
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None
    return (st.st_ino, st.st_size, st.st_mtime_ns)


def config_path(path=None):
    return path or os.environ.get('TM_CONFIG', _DEFAULT_CONFIG_PATH)


def invalidate_cache():
    """Drop this process's parsed config. Used by tests and after a write."""
    global _cache_key, _cache_path, _cache_cfg
    _cache_key = None
    _cache_path = None
    _cache_cfg = None
    cluster_store.invalidate_cache()


def load_config(path=None):
    global _cache_key, _cache_path, _cache_cfg

    resolved = config_path(path)
    key = _stat_key(resolved)

    if key is None:
        raise FileNotFoundError(
            'Configuration file not found: %s. The service cannot run without '
            'it; it is not created automatically.' % resolved)

    if _cache_cfg is None or _cache_path != resolved or _cache_key != key:
        try:
            with open(resolved, 'r', encoding='utf-8') as f:
                cfg = yaml.safe_load(f)
        except FileNotFoundError:
            # Vanished between the stat and the open.
            raise FileNotFoundError(
                'Configuration file %s disappeared while being read.' % resolved)
        if not isinstance(cfg, dict):
            raise ValueError('%s did not parse to a mapping (found %s). An empty '
                             'config file parses to None.'
                             % (resolved, type(cfg).__name__))

        # Environment variable overrides for secrets
        if os.environ.get('TM_SECRET_KEY'):
            cfg.setdefault('server', {})['secret_key'] = os.environ['TM_SECRET_KEY']
        if os.environ.get('TM_LDAP_BIND_PASSWORD'):
            cfg.setdefault('auth', {})['ldap_bind_password'] = os.environ['TM_LDAP_BIND_PASSWORD']

        # Set aside the pre-v1.0.4 `clusters:` block under a private key at
        # PARSE time. Reading it back off cfg['clusters'] later would read the
        # cluster store's own list instead, and the fallback would never fire.
        legacy = cfg.pop('clusters', None)
        cfg['_legacy_clusters'] = legacy if isinstance(legacy, list) else None

        _cache_cfg = cfg
        _cache_key = key
        _cache_path = resolved

    cfg = _cache_cfg
    # Clusters live in their own app-writable file (tm/clusters.py) and are
    # re-read on their own (inode, size, mtime) independently of this one. The
    # block that may still be in config.yaml on an un-migrated host is the
    # fallback, nothing more — see clusters.load_clusters.
    cfg['clusters'] = cluster_store.load_clusters(fallback=cfg['_legacy_clusters'])
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
