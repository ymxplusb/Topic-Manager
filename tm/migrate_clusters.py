"""
Move the `clusters:` block out of config.yaml and into clusters.d/clusters.yaml.

Run by BOTH install.sh and install/upgrade-full.sh — one migration with two
callers, because two copies of it is the same "two lists, one truth" drift that
already broke --offline in the upgrade script.

    python3 -m tm.migrate_clusters --config /etc/topic-manager/config.yaml \
        --clusters-dir /etc/topic-manager/clusters.d \
        [--example config/clusters.yaml.example]

It is IDEMPOTENT. Running it on an already-migrated host does nothing and
exits 0, which matters because install.sh, a reinstall and every upgrade all
call it.

DIVISION OF LABOUR: this script owns the DATA and the calling shell owns the
DIRECTORY, which it creates with install(1) before calling — see
hazards[cortex-cert-deploy-stig-sudoers-broken].

Two exceptions, both because os.replace necessarily creates a NEW INODE and a
new inode has whatever the umask says, not what the file it replaced had:

  * the rewritten config.yaml gets its original owner and mode copied on;
  * clusters.yaml is CREATED 0640 owned by --owner (the service account).
    It used to land 0600 root:root from mkstemp, or 0644 from a copy of the
    example under umask 022, and was corrected afterwards by chown/chmod lines
    in install.sh and upgrade-full.sh. The documented invariant is
    "0640 topic-manager:topic-manager"; a file that only becomes that a moment
    later has a window where it is not, and on the example path that window is
    world-readable. It now holds at creation, from the one place that creates it.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import argparse
import os
import re
import sys
import tempfile

import yaml

try:                      # POSIX only; absent on the Windows workstation
    import pwd
except ImportError:       # pragma: no cover - platform guard, not a fallback
    pwd = None

CLUSTERS_FILENAME = 'clusters.yaml'

# The service account, and the mode the layout documents for the cluster store.
# clusters.yaml carries no secret, but it decides which brokers the application
# talks to and it names the certificate files, so it is not world-readable.
APP_USER = 'topic-manager'
CLUSTERS_MODE = 0o640

_MARKER = (
    '# clusters: moved to {path} in v1.0.4.\n'
    '# The application owns that file and writes it through the Cluster\n'
    '# Builder in Settings. This file stays root-owned and read-only to the\n'
    '# service, so a cluster edit can never reach secret_key or\n'
    '# ldap_bind_password. Do not add a clusters: block back here — it would\n'
    '# be ignored, and two files claiming to hold the cluster list is exactly\n'
    '# the shadowing the split exists to prevent.\n'
)

_HEADER = (
    '# Jarvis Topic Manager — cluster profiles\n'
    '# Moved out of config.yaml by the v1.0.4 migration.\n'
    '# Written by the Cluster Builder; hand edits are picked up without a\n'
    '# restart, because every worker re-reads on inode/size/mtime change.\n'
)

# A top-level key starts at column 0. Anything indented belongs to the block
# being removed.
_TOP_LEVEL = re.compile(r'^[A-Za-z_][A-Za-z0-9_-]*\s*:')


def _read_yaml(path):
    if not os.path.exists(path):
        return None
    with open(path, 'r', encoding='utf-8') as fh:
        return yaml.safe_load(fh)


def _owner_ids(owner):
    """
    (uid, gid) for `owner`, or None when this process cannot set ownership.

    None only when we are NOT root: chown would fail for a reason that is not a
    fault, and the file already belongs to whoever ran us. When we ARE root and
    the account does not exist, that IS a fault — the installer creates the
    account before calling this — and it stops the migration rather than
    leaving the cluster store owned by root, where the service cannot write it.
    """
    if owner is None or pwd is None or not hasattr(os, 'geteuid'):
        return None
    if os.geteuid() != 0:
        return None
    try:
        ent = pwd.getpwnam(owner)
    except KeyError:
        raise SystemExit('migrate-clusters: no such account %r. The installer '
                         'creates it before calling this; the cluster store '
                         'must belong to the service account or the Cluster '
                         'Builder cannot save.' % owner)
    return ent.pw_uid, ent.pw_gid


def _atomic_write(path, text, template=None, owner=None, mode=None):
    """
    Replace `path` atomically.

    `template` — an existing file whose owner and mode are copied onto the
    replacement. os.replace makes a new inode, and a config.yaml that came back
    0644 root:root would be both a disclosure and a service that cannot read
    its own secret.

    `owner` / `mode` — used when there is no template, i.e. when this call is
    CREATING the file. They are applied to the temp file before the rename, so
    the file never exists at the wrong mode, not even briefly. mkstemp makes
    0600, so the window without them is restrictive rather than exposed — but
    it is also root-owned, which is the direction that breaks the service.
    """
    directory = os.path.dirname(path) or '.'
    fd, tmp = tempfile.mkstemp(prefix='.tm-migrate-', suffix='.tmp', dir=directory)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        if template and os.path.exists(template):
            st = os.stat(template)
            os.chmod(tmp, st.st_mode & 0o7777)
            if hasattr(os, 'chown'):
                os.chown(tmp, st.st_uid, st.st_gid)
        else:
            if mode is not None:
                os.chmod(tmp, mode)
            ids = _owner_ids(owner)
            if ids is not None:
                os.chown(tmp, ids[0], ids[1])
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def strip_clusters_block(text, clusters_path):
    """
    Remove the top-level `clusters:` block from config.yaml TEXT, leaving every
    other comment intact. A yaml.safe_dump round-trip would silently delete the
    operator's comments from a file they are expected to hand-edit.

    Returns (new_text, removed) — `removed` is False when there was no block.
    """
    lines = text.splitlines(keepends=True)
    out = []
    i = 0
    removed = False
    while i < len(lines):
        if not removed and re.match(r'^clusters\s*:', lines[i]):
            removed = True
            i += 1
            while i < len(lines):
                line = lines[i]
                if line.strip() and not line.startswith((' ', '\t', '-')) \
                        and _TOP_LEVEL.match(line):
                    break
                if line.strip().startswith('#') and not line.startswith((' ', '\t')):
                    break
                i += 1
            out.append(_MARKER.format(path=clusters_path))
            out.append('\n')
            continue
        out.append(lines[i])
        i += 1
    return ''.join(out), removed


def migrate(config_path, clusters_dir, example=None, owner=None):
    clusters_path = os.path.join(clusters_dir, CLUSTERS_FILENAME)
    if not os.path.isdir(clusters_dir):
        raise SystemExit('migrate-clusters: %s does not exist. The installer '
                         'creates it with install(1) before calling this.'
                         % clusters_dir)

    existing = _read_yaml(clusters_path) or {}
    already = existing.get('clusters') if isinstance(existing, dict) else None

    with open(config_path, 'r', encoding='utf-8') as fh:
        config_text = fh.read()
    parsed = yaml.safe_load(config_text)
    if not isinstance(parsed, dict):
        raise SystemExit('migrate-clusters: %s did not parse to a mapping'
                         % config_path)
    legacy = parsed.get('clusters')

    actions = []

    if already:
        if legacy:
            actions.append('clusters.yaml already holds %d profile(s); the stale '
                           'block in config.yaml is being removed' % len(already))
        else:
            print('migrate-clusters: already migrated (%d profile(s) in %s)'
                  % (len(already), clusters_path))
            return 0
    elif legacy:
        _atomic_write(clusters_path, _HEADER + yaml.safe_dump(
            {'clusters': legacy}, sort_keys=False, default_flow_style=False,
            allow_unicode=True), owner=owner, mode=CLUSTERS_MODE)
        actions.append('moved %d cluster profile(s) out of config.yaml into %s'
                       % (len(legacy), clusters_path))
    elif example and os.path.exists(example):
        # Through _atomic_write, not shutil.copyfile: copyfile creates the
        # destination with the process umask, which on a stock host is 0644 —
        # world-readable, and the mode was only corrected by a later shell line.
        with open(example, 'r', encoding='utf-8') as fh:
            _atomic_write(clusters_path, fh.read(), owner=owner, mode=CLUSTERS_MODE)
        actions.append('installed the example cluster profiles at %s' % clusters_path)
    else:
        raise SystemExit(
            'migrate-clusters: neither %s nor %s carries any cluster profile, '
            'and no example was given. Refusing to write an empty cluster list '
            '— the application resolves every topic and consumer-group view '
            'through a cluster.' % (config_path, clusters_path))

    if legacy is not None:
        new_text, removed = strip_clusters_block(config_text, clusters_path)
        if removed:
            _atomic_write(config_path, new_text, template=config_path)
            actions.append('removed the clusters: block from %s' % config_path)

    # Verify, do not assume. A migration that reported success while leaving
    # both files holding a cluster list is the shadowing failure this split
    # exists to prevent.
    after_cfg = _read_yaml(config_path)
    if isinstance(after_cfg, dict) and 'clusters' in after_cfg:
        raise SystemExit('migrate-clusters: %s STILL has a clusters: key after '
                         'migration — refusing to report success' % config_path)
    after_clu = _read_yaml(clusters_path)
    if not isinstance(after_clu, dict) or not after_clu.get('clusters'):
        raise SystemExit('migrate-clusters: %s does not hold a non-empty cluster '
                         'list after migration' % clusters_path)

    for action in actions:
        print('migrate-clusters: %s' % action)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--config', required=True)
    ap.add_argument('--clusters-dir', required=True)
    ap.add_argument('--example', default=None)
    ap.add_argument('--owner', default=APP_USER,
                    help='account that must own a newly created %s '
                         '(default: %s). Applied only when running as root.'
                         % (CLUSTERS_FILENAME, APP_USER))
    args = ap.parse_args(argv)
    return migrate(args.config, args.clusters_dir, args.example, args.owner)


if __name__ == '__main__':
    sys.exit(main())
