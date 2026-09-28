"""Characterisation probe for tm/migrate_clusters.py migrate() (v1.1.1).

Runs the REAL migrate() over every starting state it distinguishes and prints
one transcript per state: the return value or the SystemExit message, what it
printed, and the exact text of config.yaml and clusters.yaml afterwards. t07
holds the transcript to tests/lib/migrate_probe.expected byte for byte.

It exists because v1.1.1 splits migrate() into helpers (Sonar S3776) and its
printed lines are what TROUBLESHOOTING.md is keyed to, which no test pinned.
The transcript was recorded on the v1.1.0 code BEFORE the refactor.

The scratch directory is printed as <D>, so the transcript does not depend on
where it ran.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import contextlib
import io
import os
import shutil
import sys
import tempfile

from tm import migrate_clusters as mc

CONFIG_HEAD = '# operator comment kept\nserver:\n  port: 8443\n'
CONFIG_TAIL = '# tail comment kept\nsession:\n  timeout_minutes: 15\n'
LEGACY = ('clusters:\n  - id: "legacy"\n    bootstrap_servers: "b1.example.com:9092"\n'
          '# indented-free comment ends the block\n')
# A profile name outside ASCII: the moved store must keep it readable.
LEGACY_UNICODE = ('clusters:\n  - id: "eu"\n    name: "Z\u00fcrich \u2014 Nord"\n'
                  '    bootstrap_servers: "b2.example.com:9092"\n')
STORE_ONE = 'clusters:\n  - id: current\n    bootstrap_servers: b9.example.com:9092\n'

# name, config.yaml text (None = no file), clusters.yaml text (None = none),
# make the clusters dir
STATES = [
    ('no-clusters-dir', CONFIG_HEAD, None, False),
    ('config-not-a-mapping', '- just\n- a list\n', None, True),
    ('config-empty', '', None, True),
    ('fresh-host', CONFIG_HEAD + CONFIG_TAIL, None, True),
    ('legacy-only', CONFIG_HEAD + LEGACY + CONFIG_TAIL, None, True),
    ('legacy-non-ascii-name', CONFIG_HEAD + LEGACY_UNICODE + CONFIG_TAIL, None, True),
    ('legacy-at-end-of-file', CONFIG_HEAD + LEGACY, None, True),
    ('store-and-stale-legacy', CONFIG_HEAD + LEGACY + CONFIG_TAIL, STORE_ONE, True),
    ('store-only', CONFIG_HEAD + CONFIG_TAIL, STORE_ONE, True),
    ('empty-store-only', CONFIG_HEAD + CONFIG_TAIL, 'clusters: []\n', True),
    ('empty-store-and-legacy', CONFIG_HEAD + LEGACY + CONFIG_TAIL, 'clusters: []\n', True),
    ('store-not-a-list-and-legacy', CONFIG_HEAD + LEGACY + CONFIG_TAIL, 'clusters: {}\n', True),
    ('store-is-a-scalar', CONFIG_HEAD + CONFIG_TAIL, 'hello\n', True),
    ('legacy-empty-list', CONFIG_HEAD + 'clusters: []\n' + CONFIG_TAIL, None, True),
    ('legacy-null', CONFIG_HEAD + 'clusters:\n' + CONFIG_TAIL, None, True),
    ('store-and-legacy-empty-list', CONFIG_HEAD + 'clusters: []\n' + CONFIG_TAIL, STORE_ONE, True),
    ('empty-store-and-legacy-null', CONFIG_HEAD + 'clusters:\n' + CONFIG_TAIL, 'clusters: []\n', True),
    ('store-and-legacy-null', CONFIG_HEAD + 'clusters:\n' + CONFIG_TAIL, STORE_ONE, True),
    ('legacy-indented-key-not-stripped', CONFIG_HEAD + '  clusters: [1]\n', None, True),
]


def _read(path):
    if not os.path.exists(path):
        return '<absent>'
    with open(path, encoding='utf-8') as fh:
        return fh.read()


def run_state(name, config_text, store_text, make_dir, write_fails=False):
    top = tempfile.mkdtemp(prefix='tm-mig-')
    try:
        cfg = os.path.join(top, 'config.yaml')
        cdir = os.path.join(top, 'clusters.d')
        with open(cfg, 'w', encoding='utf-8') as fh:
            fh.write(config_text)
        if make_dir:
            os.mkdir(cdir)
            if store_text is not None:
                with open(os.path.join(cdir, 'clusters.yaml'), 'w', encoding='utf-8') as fh:
                    fh.write(store_text)
        out = io.StringIO()
        real_write = mc._atomic_write
        if write_fails:
            # A write that silently does nothing: the post-migration
            # verification must refuse to report success.
            mc._atomic_write = lambda *a, **k: None
        try:
            with contextlib.redirect_stdout(out):
                result = 'return %r' % (mc.migrate(cfg, cdir),)
        except SystemExit as exc:
            result = 'SystemExit %s' % exc
        finally:
            mc._atomic_write = real_write
        print('== %s' % name)
        print('   %s' % result.replace(top, '<D>'))
        for line in out.getvalue().splitlines():
            print('   out: %s' % line.replace(top, '<D>'))
        for label, path in (('config', cfg), ('store', os.path.join(cdir, 'clusters.yaml'))):
            for line in _read(path).replace(top, '<D>').splitlines():
                print('   %s| %s' % (label, line))
    finally:
        shutil.rmtree(top)


def main():
    for state in STATES:
        run_state(*state)
    run_state('verify-refuses-a-store-that-was-not-written',
              CONFIG_HEAD + CONFIG_TAIL, None, True, write_fails=True)
    run_state('verify-refuses-a-legacy-move-that-was-not-written',
              CONFIG_HEAD + LEGACY + CONFIG_TAIL, None, True, write_fails=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
