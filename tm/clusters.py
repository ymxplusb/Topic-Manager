"""
Cluster profile store.

The cluster list used to live in the `clusters:` block of config.yaml, which is
root-owned 0640 root:topic-manager so the application can READ its secrets and
never write them. An interactive Cluster Builder needs a file the application
can write, and widening config.yaml — or its directory — is not an option: a
directory the app can write is a directory in which it can UNLINK a root-owned
0600 file, which chained with the restart control is a full auth-config
takeover.

So the cluster list lives in its OWN directory:

    /etc/topic-manager/            root:topic-manager  0750   app reads only
      config.yaml                  root:topic-manager  0640   secrets
      clusters.d/                  topic-manager:...   0750   app owns this
        clusters.yaml              topic-manager:...   0640

Atomic replace works inside clusters.d/ (same filesystem, writable directory),
and /etc/topic-manager stays non-writable by the app, so config.yaml can be
neither modified nor unlinked. There are FOUR gunicorn workers: every save is
write-temp-then-os.replace, never truncate-then-write.

Certificate material is accepted as CONTENT, never as a path. A user-supplied
path would be an arbitrary-file-read oracle, because routes.test_cluster hands
librdkafka's error string back verbatim and /api/audit/export hands the audit
detail to any authenticated user — and config.yaml is a file this process can
read. Uploaded PEM is parsed before it is stored, the filename is generated
here, and every stored path is re-checked against the cert directory on load.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import binascii
import logging
import os
import re
import tempfile

import yaml
from cryptography import x509
from cryptography.hazmat.primitives import serialization

log = logging.getLogger(__name__)

CLUSTERS_FILENAME = 'clusters.yaml'
_DEFAULT_CLUSTERS_DIR = '/etc/topic-manager/clusters.d'
_DEFAULT_CERT_DIR = '/opt/topic-manager/data/cluster-certs'

# Protocols the Cluster Builder offers. kafka_client._make_admin keys off
# 'SSL' in the protocol and 'SASL' in the protocol, so SASL_SSL already gets
# both halves — no new key is needed there.
PROTOCOLS = ('PLAINTEXT', 'SSL', 'SASL_SSL')
SASL_MECHANISMS = ('PLAIN', 'SCRAM-SHA-256', 'SCRAM-SHA-512')

# The three cert fields, mapped to the kind used in the generated filename.
CERT_FIELDS = {
    'ssl_cafile':   'ca',
    'ssl_certfile': 'cert',
    'ssl_keyfile':  'key',
}
# The matching upload fields on the API: PEM text, never a path.
CERT_PEM_FIELDS = {
    'ssl_cafile_pem':   'ssl_cafile',
    'ssl_certfile_pem': 'ssl_certfile',
    'ssl_keyfile_pem':  'ssl_keyfile',
}

_ID_RE   = re.compile(r'^[a-z0-9][a-z0-9._-]{0,63}$')
_NAME_RE = re.compile(r'^[\w .,()\[\]/&+:-]{1,80}$', re.UNICODE)
# host:port[,host:port...] — no scheme, no whitespace, no shell metacharacters.
_BOOTSTRAP_RE = re.compile(r'^[A-Za-z0-9._-]+:\d{1,5}(,[A-Za-z0-9._-]+:\d{1,5})*$')

_MAX_PEM_BYTES = 64 * 1024


class ClusterError(ValueError):
    """A rejected cluster definition. Carries a message meant for the user."""


# ── locations ─────────────────────────────────────────────────────
def clusters_dir():
    return os.environ.get('TM_CLUSTERS_DIR', _DEFAULT_CLUSTERS_DIR)


def clusters_path():
    return os.path.join(clusters_dir(), CLUSTERS_FILENAME)


def cert_dir():
    return os.environ.get('TM_CLUSTER_CERT_DIR', _DEFAULT_CERT_DIR)


# ── the load cache ────────────────────────────────────────────────
# Keyed on (inode, size, mtime_ns) of the clusters file. Every save creates a
# NEW inode via os.replace, so the key changes even when two saves land inside
# one mtime tick — which is what makes this converge across all four workers
# with no IPC. A cache that returns forever after the first load (what
# config.py used to do) makes a cluster edit visible to roughly one request in
# four, and that presents as an intermittent Kafka fault.
_cache_key = None
_cache_value = []


def _stat_key(path):
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None
    return (st.st_ino, st.st_size, st.st_mtime_ns)


def invalidate_cache():
    """Drop the in-process cache. Only needed after this worker writes."""
    global _cache_key, _cache_value
    _cache_key = None
    _cache_value = []


def load_clusters(fallback=None):
    """
    Return the cluster list.

    `fallback` is the `clusters:` list still sitting in config.yaml on a host
    where the v1.0.4 migration has not run yet. It is used ONLY when the
    clusters file does not exist, so an un-migrated host keeps working; the
    first save writes the whole list out and completes the migration.
    """
    global _cache_key, _cache_value
    path = clusters_path()
    key = _stat_key(path)

    if key is None:
        if fallback:
            log.warning('%s does not exist; using the clusters: block still in '
                        'config.yaml. The first cluster edit will write it out.', path)
            return _sanitise_all([dict(c) for c in fallback if isinstance(c, dict)])
        return []

    if key != _cache_key:
        try:
            with open(path, 'r', encoding='utf-8') as fh:
                doc = yaml.safe_load(fh)
        except FileNotFoundError:
            # Removed between _stat_key() and open(). save_clusters() only ever
            # replaces via os.replace(), which never leaves the path absent, so
            # this means an out-of-band delete. Serve the last good value rather
            # than letting FileNotFoundError escape into a route as a bare 500.
            log.warning('%s disappeared while being read; serving the last known '
                        'cluster list. An out-of-band delete is the usual cause.', path)
            _cache_key = None
            return [dict(c) for c in _cache_value]
        raw = (doc or {}).get('clusters') or []
        if not isinstance(raw, list):
            raise ClusterError('%s: clusters must be a list, found %s'
                               % (path, type(raw).__name__))
        _cache_value = _sanitise_all([dict(c) for c in raw if isinstance(c, dict)])
        _cache_key = key
        if fallback:
            log.warning('config.yaml still carries a clusters: block; it is IGNORED '
                        'because %s exists. Remove it to stop the two files disagreeing.',
                        path)
    # A copy: a caller that mutates its cluster dict must not poison the cache.
    return [dict(c) for c in _cache_value]


def _sanitise_all(clusters):
    return [_sanitise_loaded(c) for c in clusters]


def _sanitise_loaded(cluster):
    """
    Belt and braces for a HAND-EDITED clusters file. The API can only ever
    store a generated path under the cert directory, but nothing stops root
    editing the file, and an ssl_cafile pointing at config.yaml would turn
    test_cluster's verbatim librdkafka error into a file-read oracle.

    A cluster whose cert paths escape the cert directory keeps its identity —
    it stays visible and named in the UI — but loses the offending paths and
    is marked disabled, so it can never be handed to librdkafka.
    """
    root = os.path.realpath(cert_dir())
    for field in CERT_FIELDS:
        value = cluster.get(field)
        if not value:
            continue
        resolved = os.path.realpath(value)
        if resolved != root and not resolved.startswith(root + os.sep):
            log.error('cluster %r: %s=%r resolves outside %s — the cluster is '
                      'disabled and the path discarded.',
                      cluster.get('id'), field, value, root)
            for f in CERT_FIELDS:
                cluster.pop(f, None)
            cluster['disabled'] = ('TLS material path is outside %s. Re-upload the '
                                   'certificates through the Cluster Builder.' % root)
            return cluster
    return cluster


# ── saving ────────────────────────────────────────────────────────
def save_clusters(clusters):
    """
    Replace the clusters file atomically.

    Never truncate-then-write: four workers can save concurrently, and a
    truncated file that is never re-written loses every cluster profile. The
    temp file is created INSIDE clusters.d so os.replace is a same-filesystem
    rename, which is what makes it atomic.
    """
    directory = clusters_dir()
    path = clusters_path()
    # `disabled` is DERIVED at load time by _sanitise_loaded. Writing it back
    # would persist a computed diagnostic into the source of truth, and a later
    # read would then be unable to tell a real refusal from a stale note.
    clusters = [{k: v for k, v in c.items() if k != 'disabled'} for c in clusters]
    payload = yaml.safe_dump({'clusters': clusters},
                             sort_keys=False, default_flow_style=False,
                             allow_unicode=True)
    header = ('# Jarvis Topic Manager — cluster profiles\n'
              '# Written by the Cluster Builder. Edits made here are picked up\n'
              '# without a restart; every worker re-reads on change.\n')

    fd, tmp = tempfile.mkstemp(prefix='.clusters-', suffix='.tmp', dir=directory)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            fh.write(header)
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o640)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

    # Make the rename itself durable. O_DIRECTORY is a POSIX capability, not an
    # error to swallow: Windows has no such open, and the tests run on both.
    if hasattr(os, 'O_DIRECTORY'):
        dfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    invalidate_cache()


# ── validation ────────────────────────────────────────────────────
def validate(data, existing, cluster_id=None):
    """
    Validate one submitted cluster against the clusters that already exist.

    `cluster_id` is the id being edited (None on create), so a profile can keep
    its own id and name without colliding with itself.

    Returns a normalised cluster dict WITHOUT cert material — the caller stores
    the PEM uploads separately and merges the generated paths in.
    """
    if not isinstance(data, dict):
        raise ClusterError('Cluster definition must be an object')

    cid = str(data.get('id') or '').strip().lower()
    if not _ID_RE.match(cid):
        raise ClusterError('Cluster id must be 1-64 characters of lowercase '
                           'letters, digits, dot, underscore or hyphen, and must '
                           'start with a letter or digit')

    name = str(data.get('name') or '').strip()
    if not _NAME_RE.match(name):
        raise ClusterError('Cluster name must be 1-80 characters and may not '
                           'contain control characters')

    servers = str(data.get('bootstrap_servers') or '').strip()
    if not _BOOTSTRAP_RE.match(servers):
        raise ClusterError('bootstrap_servers must be host:port, comma-separated, '
                           'with no scheme and no spaces '
                           '(e.g. broker1.example.com:9092,broker2.example.com:9092)')

    protocol = str(data.get('security_protocol') or 'PLAINTEXT').strip().upper()
    if protocol not in PROTOCOLS:
        raise ClusterError('security_protocol must be one of: %s' % ', '.join(PROTOCOLS))

    # A second profile must not shadow this one. Ids are the routing key, and
    # two identical names are indistinguishable to the operator picking one.
    for other in existing:
        if other.get('id') == cluster_id:
            continue
        if other.get('id') == cid:
            raise ClusterError('A cluster with id %r already exists' % cid)
        if str(other.get('name') or '').strip().lower() == name.lower():
            raise ClusterError('A cluster named %r already exists' % name)

    cluster = {
        'id': cid,
        'name': name,
        'bootstrap_servers': servers,
        'security_protocol': protocol,
        'active': bool(data.get('active', False)),
    }

    if 'SASL' in protocol:
        mechanism = str(data.get('sasl_mechanism') or 'PLAIN').strip().upper()
        if mechanism not in SASL_MECHANISMS:
            raise ClusterError('sasl_mechanism must be one of: %s'
                               % ', '.join(SASL_MECHANISMS))
        username = str(data.get('sasl_username') or '')
        if not username:
            raise ClusterError('sasl_username is required for %s' % protocol)
        if '\n' in username or '\r' in username:
            raise ClusterError('sasl_username may not contain line breaks')
        cluster['sasl_mechanism'] = mechanism
        cluster['sasl_username'] = username

    return cluster


# ── certificate material ──────────────────────────────────────────
def _parse_pem(kind, text):
    """Parse the PEM as what it claims to be. Raises ClusterError if it is not."""
    if not isinstance(text, str) or not text.strip():
        raise ClusterError('%s: no PEM content supplied' % kind)
    blob = text.encode('utf-8')
    if len(blob) > _MAX_PEM_BYTES:
        raise ClusterError('%s: PEM is larger than %d bytes'
                           % (kind, _MAX_PEM_BYTES))

    if kind == 'key':
        try:
            serialization.load_pem_private_key(blob, password=None)
        except (ValueError, TypeError) as exc:
            raise ClusterError('Private key is not a valid unencrypted PEM key: %s'
                               % exc)
        return blob

    # A CA bundle is legitimately a chain, so every block must parse.
    blocks = re.findall(rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                        blob, re.S)
    if not blocks:
        raise ClusterError('%s: no PEM certificate block found' % kind)
    for block in blocks:
        try:
            x509.load_pem_x509_certificate(block)
        except (ValueError, TypeError) as exc:
            raise ClusterError('%s: PEM certificate does not parse: %s' % (kind, exc))
    return blob


def store_cert(cluster_id, field, pem_text):
    """
    Parse the supplied PEM and write it under the cert directory with a
    SERVER-GENERATED name. Returns the absolute path that goes into the
    cluster profile. The caller never sees a path it chose.
    """
    kind = CERT_FIELDS[field]
    blob = _parse_pem(kind, pem_text)

    directory = cert_dir()
    os.makedirs(directory, mode=0o700, exist_ok=True)
    suffix = binascii.hexlify(os.urandom(4)).decode('ascii')
    path = os.path.join(directory, '%s-%s-%s.pem' % (cluster_id, kind, suffix))

    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as fh:
        fh.write(blob)
    return path


def discard_cert(path):
    """Remove a cert file this store generated. Anything else is left alone."""
    if not path:
        return
    root = os.path.realpath(cert_dir())
    resolved = os.path.realpath(path)
    if not resolved.startswith(root + os.sep):
        log.error('refusing to delete %r: it is not under %s', path, root)
        return
    if os.path.exists(resolved):
        os.unlink(resolved)


def apply_material(cluster, data, previous=None):
    """
    Merge cert material and the SASL password into a validated cluster.

    Precedence per cert field: a new PEM upload replaces it, an explicit
    <field>_clear removes it, otherwise the previous profile's path is carried
    forward. The replaced file is deleted only AFTER the new one is written, so
    a failed parse never leaves a profile pointing at a file that is gone.

    sasl_password is write-only: it is accepted, stored (librdkafka needs the
    literal value) and never returned by any route. An edit that omits it keeps
    the one already stored, so re-saving a profile does not silently blank the
    credential.
    """
    previous = previous or {}
    replaced = []

    for pem_field, path_field in CERT_PEM_FIELDS.items():
        pem = data.get(pem_field)
        if pem:
            cluster[path_field] = store_cert(cluster['id'], path_field, pem)
            if previous.get(path_field):
                replaced.append(previous[path_field])
        elif data.get(path_field + '_clear'):
            if previous.get(path_field):
                replaced.append(previous[path_field])
        elif previous.get(path_field):
            cluster[path_field] = previous[path_field]

    if 'SSL' not in cluster['security_protocol']:
        # Switching a profile back to PLAINTEXT must not leave TLS material
        # attached to it, or a later switch back silently reuses stale certs.
        for path_field in CERT_FIELDS:
            cluster.pop(path_field, None)
            if previous.get(path_field):
                replaced.append(previous[path_field])

    if 'SASL' in cluster['security_protocol']:
        password = data.get('sasl_password')
        if password:
            cluster['sasl_password'] = str(password)
        elif previous.get('sasl_password'):
            cluster['sasl_password'] = previous['sasl_password']
        else:
            raise ClusterError('sasl_password is required for %s'
                               % cluster['security_protocol'])

    for path in replaced:
        discard_cert(path)
    return cluster


# ── audit detail ──────────────────────────────────────────────────
_SECRET_KEYS = ('sasl_password',)


def audit_detail(cluster):
    """
    A one-line description of a cluster for the audit log.

    /api/audit/export hands `detail` to any authenticated user as a CSV, and
    AuditTab renders it on screen, so nothing secret may reach it. Cert paths
    are reduced to basenames: the directory is not the operator's business and
    a full path in a downloadable CSV is free reconnaissance.
    """
    if not cluster:
        return '(none)'
    parts = []
    for key in ('id', 'name', 'bootstrap_servers', 'security_protocol',
                'sasl_mechanism', 'sasl_username', 'active'):
        if key in cluster and cluster[key] not in (None, ''):
            parts.append('%s=%s' % (key, cluster[key]))
    for field in CERT_FIELDS:
        if cluster.get(field):
            parts.append('%s=%s' % (field, os.path.basename(cluster[field])))
    for key in _SECRET_KEYS:
        if cluster.get(key):
            parts.append('%s=<redacted>' % key)
    return ', '.join(parts)


def public_view(cluster):
    """
    The shape the API returns. Everything the Cluster Builder needs to EDIT a
    profile, and nothing that would disclose secret material: cert paths are
    reduced to their basenames so the UI can say "a CA is loaded" without
    handing out a filesystem path, and sasl_password is write-only — it is
    never stored by this release and never returned.
    """
    view = {
        'id': cluster.get('id'),
        'name': cluster.get('name'),
        'bootstrap_servers': cluster.get('bootstrap_servers'),
        'security_protocol': cluster.get('security_protocol', 'PLAINTEXT'),
        'active': cluster.get('active', False),
        'sasl_mechanism': cluster.get('sasl_mechanism', ''),
        'sasl_username': cluster.get('sasl_username', ''),
        'has_sasl_password': bool(cluster.get('sasl_password')),
    }
    for field in CERT_FIELDS:
        view[field] = os.path.basename(cluster[field]) if cluster.get(field) else ''
    if cluster.get('disabled'):
        view['disabled'] = cluster['disabled']
    return view
