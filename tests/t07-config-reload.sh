#!/usr/bin/env bash
# =============================================================================
# t07 — THE TWO CACHES, AND THE MIGRATION.
#
# There were TWO places a stale config could hide, and fixing either one alone
# looked like success:
#
#   tm/config.py   _config_cache returned forever after the first load.
#   tm/app.py      app.config['TM_CONFIG'] froze a SECOND copy at create_app,
#                  and tm/routes._cfg() handed that dict to every route.
#
# With four gunicorn workers, an in-process invalidation reaches one of them.
# A newly added cluster then appears on roughly one request in four —
# intermittent, and it reads as a Kafka fault rather than a config fault.
#
# These cases drive tm/config.py and the real Flask app. The one that matters
# is app-reads-a-cluster-written-by-another-process: it never touches this
# process's caches at all, which is the only way to be sure the fix is not
# just an invalidate() call in the writing path.
#
# The migration cases drive tm/migrate_clusters.py, which install.sh and
# install/upgrade-full.sh BOTH call — one migration, two callers.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "config staleness and the clusters migration"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
"$PY" -c "import yaml" >/dev/null 2>&1 || tm_die "PyYAML is not importable"

_py() {
    PYTHONPATH="$TM_REPO_ROOT" \
    PYTHONDONTWRITEBYTECODE=1 \
    TM_CONFIG="${TM_TMP}/config.yaml" \
    TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
    TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        "$PY" -c "$1" 2>&1 | tr -d '\r'
}

# A config.yaml carrying the legacy clusters: block, exactly as every host
# running v1.0.3 or earlier has it.
_mkconfig_legacy() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs"
    cat > "${TM_TMP}/config.yaml" <<'YAML'
server:
  host: 127.0.0.1
  port: 5001
  secret_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

auth:
  ldap_server: "ldaps://dc1.example.com:636"
  ldap_domain: "example.com"
  ldap_base_dn: "DC=example,DC=com"
  required_group: "CN=Kafka-Admins,DC=example,DC=com"

clusters:
  - id: "legacy"
    name: "Legacy"
    bootstrap_servers: "broker1.example.com:9092"
    security_protocol: "PLAINTEXT"
    active: true

session:
  timeout_minutes: 30
  # Maximum simultaneous sessions per user. 0 = unlimited.
  max_concurrent: 5

audit:
  db_path: "TMDBPATH"

logging:
  log_level: "INFO"
  syslog_enabled: false
YAML
    # A forward slash keeps the path YAML-safe on the Windows workstation too.
    DBP="$(printf '%s' "${TM_TMP}/tm.db" | tr '\\' '/')"
    sed -i "s|TMDBPATH|${DBP}|" "${TM_TMP}/config.yaml"
}

# ─── the fallback: an un-migrated host still works ───────────────────────────
c_legacy_block_is_the_fallback() {
    _mkconfig_legacy
    OUT="$(_py "
from tm import config
cfg = config.load_config()
print('%d:%s' % (len(cfg['clusters']), cfg['clusters'][0]['id']))
")"
    case "$OUT" in
        *"1:legacy"*) ;;
        *) _tm_afail "an un-migrated host lost its clusters entirely. The
        clusters: block still in config.yaml must be the fallback until the
        migration runs, or the upgrade is an outage. Got: ${OUT}" ;;
    esac
}
tm_case "un-migrated-config-yaml-still-provides-clusters" none c_legacy_block_is_the_fallback

c_clusters_file_wins_over_the_legacy_block() {
    _mkconfig_legacy
    cat > "${TM_TMP}/clusters.d/clusters.yaml" <<'YAML'
clusters:
  - id: "current"
    name: "Current"
    bootstrap_servers: "broker9.example.com:9092"
    security_protocol: "PLAINTEXT"
    active: true
YAML
    OUT="$(_py "
from tm import config
cfg = config.load_config()
print('%d:%s' % (len(cfg['clusters']), cfg['clusters'][0]['id']))
")"
    case "$OUT" in
        *"1:current"*) ;;
        *) _tm_afail "the stale clusters: block in config.yaml shadowed the
        cluster store. Two files claiming to hold the list is exactly what the
        split exists to prevent. Got: ${OUT}" ;;
    esac
}
tm_case "clusters-file-wins-over-a-stale-config-yaml-block" none c_clusters_file_wins_over_the_legacy_block

# ─── THE case: another process writes, this one must see it ──────────────────
c_another_process_write_is_visible() {
    _mkconfig_legacy
    OUT="$(_py "
import os, subprocess, sys
from tm import config
first = [c['id'] for c in config.load_config()['clusters']]
# A SEPARATE interpreter does the save — this process's caches are never
# invalidated, exactly as worker 2 never learns that worker 1 wrote.
subprocess.run([sys.executable, '-c',
    'from tm import clusters; clusters.save_clusters(['
    \"{'id':'added','name':'Added','bootstrap_servers':'h:9092',\"
    \"'security_protocol':'PLAINTEXT','active':True}])\"],
    check=True, env=dict(os.environ))
second = [c['id'] for c in config.load_config()['clusters']]
print('%s -> %s' % (first, second))
")"
    case "$OUT" in
        *"['legacy'] -> ['added']"*) ;;
        *) _tm_afail "a cluster written by ANOTHER process was not visible to
        this one. That is the four-worker defect: the edit lands on one worker
        and the other three keep serving the old list, so the new cluster
        appears on about one request in four. Got: ${OUT}" ;;
    esac
}
tm_case "a-cluster-written-by-another-process-is-visible-here" none c_another_process_write_is_visible

# Closing mutation control P8, which SURVIVED on 2026-09-01: tm/config.py was
# reverted to "return the first parse forever" and every case stayed green.
# The cluster cases could not catch it, because clusters come from the cluster
# store's own cache — so config.yaml's own staleness was untested. It is the
# file holding session.timeout_minutes, required_group and ldap_bind_dn.
c_config_yaml_itself_is_reread() {
    _mkconfig_legacy
    OUT="$(_py "
import os, subprocess, sys
from tm import config
first = config.load_config()['session']['timeout_minutes']
# ANOTHER process rewrites config.yaml, exactly as an operator editing it
# does. This process is never told.
subprocess.run([sys.executable, '-c',
    'import io, os, re; p = os.environ[\"TM_CONFIG\"]; '
    's = io.open(p, encoding=\"utf-8\").read(); '
    's = s.replace(\"timeout_minutes: 30\", \"timeout_minutes: 4500\"); '
    'io.open(p, \"w\", encoding=\"utf-8\").write(s)'],
    check=True, env=dict(os.environ))
second = config.load_config()['session']['timeout_minutes']
print('%s -> %s' % (first, second))
")"
    case "$OUT" in
        *"30 -> 4500"*) ;;
        *) _tm_afail "config.yaml was not re-read after it changed on disk. The
        v1.0.3 loader returned its first parse forever, which is half of the
        two-cache defect. Got: ${OUT}" ;;
    esac
}
tm_case "config-yaml-is-re-read-when-it-changes-on-disk" none c_config_yaml_itself_is_reread

# ─── the SECOND cache: the Flask app must not freeze a copy ──────────────────
c_flask_app_does_not_freeze_the_config() {
    _mkconfig_legacy
    # The probe is written to a FILE rather than passed with python -c: it
    # needs quotes nested three deep otherwise, and the previous version of
    # that was unreadable enough to hide a weak assertion.
    cat > "${TM_TMP}/probe.py" <<'PYPROBE'
import os, subprocess, sys
from tm.app import create_app
from tm import routes

app = create_app()
with app.test_request_context('/api/health'):
    cfg = routes._cfg()
    first = ([c['id'] for c in cfg['clusters']], cfg['session']['timeout_minutes'])

# ANOTHER process changes BOTH files. Clusters alone is NOT enough:
# tm/config.py caches and hands back the SAME dict object, so a route that
# froze a REFERENCE to it still sees cluster updates. Mutation control P9
# SURVIVED on exactly that, on Linux, where this case actually runs
# (2026-09-01). Only a config.yaml change replaces the cached dict and
# shows a frozen reference for what it is.
WRITER = """
import io, os
from tm import clusters
clusters.save_clusters([{'id': 'added', 'name': 'Added',
                         'bootstrap_servers': 'h:9092',
                         'security_protocol': 'PLAINTEXT', 'active': True}])
p = os.environ['TM_CONFIG']
s = io.open(p, encoding='utf-8').read()
io.open(p, 'w', encoding='utf-8').write(
    s.replace('timeout_minutes: 30', 'timeout_minutes: 4500'))
"""
subprocess.run([sys.executable, '-c', WRITER], check=True, env=dict(os.environ))

with app.test_request_context('/api/health'):
    cfg = routes._cfg()
    second = ([c['id'] for c in cfg['clusters']], cfg['session']['timeout_minutes'])
print('%s -> %s' % (first, second))
PYPROBE
    OUT="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 \
        TM_CONFIG="${TM_TMP}/config.yaml" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
        TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        "$PY" "${TM_TMP}/probe.py" 2>&1 | tr -d '\r')"
    case "$OUT" in
        *"(['legacy'], 30) -> (['added'], 4500)"*) ;;
        *) _tm_afail "routes._cfg() handed back a config frozen at create_app.
        app.config['TM_CONFIG'] was the SECOND cache; fixing tm/config.py
        alone looks like it worked and still failed for three of the four
        workers. Got: ${OUT}" ;;
    esac
}
tm_case "flask-routes-do-not-serve-a-config-frozen-at-create_app" tmapp c_flask_app_does_not_freeze_the_config

# ─── the migration ───────────────────────────────────────────────────────────
c_migration_moves_the_block() {
    _mkconfig_legacy
    OUT="$(_py "
import yaml
from tm.migrate_clusters import migrate
import os
migrate(os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR'])
cfg = yaml.safe_load(open(os.environ['TM_CONFIG'], encoding='utf-8'))
clu = yaml.safe_load(open(os.path.join(os.environ['TM_CLUSTERS_DIR'],'clusters.yaml'), encoding='utf-8'))
print('cfg_has_clusters=%s clu_ids=%s secret_kept=%s' % (
    'clusters' in cfg,
    [c['id'] for c in clu['clusters']],
    cfg['server']['secret_key'].startswith('0123')))
")"
    case "$OUT" in
        *"cfg_has_clusters=False clu_ids=['legacy'] secret_kept=True"*) ;;
        *) _tm_afail "the migration did not move the block, or damaged the rest
        of config.yaml. Got: ${OUT}" ;;
    esac
}
tm_case "migration-moves-the-clusters-block-out-of-config-yaml" none c_migration_moves_the_block

c_migration_preserves_comments() {
    _mkconfig_legacy
    _py "
import os
from tm.migrate_clusters import migrate
migrate(os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR'])
" > /dev/null
    tm_assert_grep "# Maximum simultaneous sessions per user" "${TM_TMP}/config.yaml" \
        "the migration round-tripped config.yaml through yaml.safe_dump and
        deleted every comment from a file operators are expected to hand-edit"
    tm_assert_grep "moved to" "${TM_TMP}/config.yaml" \
        "nothing was left in config.yaml to say where the clusters went"
}
tm_case "migration-preserves-the-operator-comments" none c_migration_preserves_comments

# The documented layout is "clusters.yaml 0640, owned by the service account".
# It used to become that a moment AFTER creation, through chown/chmod lines in
# install.sh and upgrade-full.sh — and on the example path the file was created
# by shutil.copyfile, which lands 0644 under a stock umask. The invariant has to
# hold at creation, from the one place that creates the file.
c_migration_creates_the_file_0640() {
    _mkconfig_legacy
    umask 022
    _py "
import os
from tm.migrate_clusters import migrate
migrate(os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR'])
" > /dev/null
    tm_assert_mode 640 "${TM_TMP}/clusters.d/clusters.yaml" \
        "the migrated cluster store was not created 0640"
}
tm_case "migration-creates-clusters-yaml-0640" modes c_migration_creates_the_file_0640

c_fresh_store_is_0640_too() {
    # The other creation path: no legacy block and no store — a fresh host.
    # v1.1.0 creates an EMPTY store there; it must still be born 0640.
    _mkconfig_legacy
    umask 022
    _py "
import io, os, re
p = os.environ['TM_CONFIG']
s = io.open(p, encoding='utf-8').read()
io.open(p, 'w', encoding='utf-8').write(re.sub(r'(?ms)^clusters:.*?(?=^\w|\Z)', '', s))
from tm.migrate_clusters import migrate
migrate(p, os.environ['TM_CLUSTERS_DIR'])
" > /dev/null
    tm_assert_file "${TM_TMP}/clusters.d/clusters.yaml" "no cluster store was created on a fresh host"
    tm_assert_mode 640 "${TM_TMP}/clusters.d/clusters.yaml" \
        "the fresh cluster store was created world-readable — once the operator
        adds clusters it names every broker and every certificate file"
}
tm_case "fresh-cluster-store-is-created-0640" modes c_fresh_store_is_0640_too

# MUTATION FINDING, 2026-09-01: removing the chown from _atomic_write SURVIVED.
# Both mode cases above call migrate() with no owner, so the ownership half was
# never exercised at all — a cluster store created root-owned means the Cluster
# Builder cannot save anything, and nothing here would have noticed. The state
# the guard exists to produce has to be populated, or the guard is untested.
c_migration_gives_the_store_to_the_service_account() {
    _mkconfig_legacy
    _py "
import os
from tm.migrate_clusters import migrate
migrate(os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR'], owner='${TM_WEB_USER}')
" > /dev/null
    tm_assert_owner "${TM_WEB_USER}:${TM_WEB_USER}" "${TM_TMP}/clusters.d/clusters.yaml" \
        "the cluster store was not given to the service account at creation. It
        is root-owned inside a directory the app owns, so every save from the
        Cluster Builder fails — and the installer's later chown is a separate
        line that a reinstall or a hand-run migration does not repeat"
}
tm_case "migration-gives-the-store-to-the-service-account" chown c_migration_gives_the_store_to_the_service_account

# Round 2: the rewritten config.yaml takes its original owner and mode from
# the OPEN descriptor (fchmod/fchown). Hand-run control G2 (the template mode
# replaced by 0644) showed nothing checked this path at all.
c_config_rewrite_keeps_owner_and_mode() {
    _mkconfig_legacy
    chown "root:${TM_WEB_USER}" "${TM_TMP}/config.yaml"; chmod 640 "${TM_TMP}/config.yaml"
    umask 022
    _py "
import os
from tm.migrate_clusters import migrate
migrate(os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR'])
" > /dev/null
    tm_assert_grep "moved to" "${TM_TMP}/config.yaml" "precondition: config.yaml was not rewritten"
    tm_assert_mode 640 "${TM_TMP}/config.yaml" \
        "the rewritten config.yaml lost its 0640 — it holds secret_key and the bind password"
    tm_assert_owner "root:${TM_WEB_USER}" "${TM_TMP}/config.yaml" \
        "the rewritten config.yaml lost its owner/group"
}
tm_case "migration-rewrite-keeps-config-yaml-owner-and-mode" modes,chown c_config_rewrite_keeps_owner_and_mode

c_migration_is_idempotent() {
    _mkconfig_legacy
    OUT="$(_py "
import os, hashlib
from tm.migrate_clusters import migrate
cp, cd = os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR']
migrate(cp, cd)
h1 = (hashlib.sha256(open(cp,'rb').read()).hexdigest(),
      hashlib.sha256(open(os.path.join(cd,'clusters.yaml'),'rb').read()).hexdigest())
migrate(cp, cd)
migrate(cp, cd)
h2 = (hashlib.sha256(open(cp,'rb').read()).hexdigest(),
      hashlib.sha256(open(os.path.join(cd,'clusters.yaml'),'rb').read()).hexdigest())
print('STABLE' if h1 == h2 else 'CHANGED')
")"
    case "$OUT" in
        *STABLE*) ;;
        *) _tm_afail "running the migration again changed the files. It runs on
        every install, reinstall and upgrade, so a second run must be a no-op.
        Got: ${OUT}" ;;
    esac
}
tm_case "migration-is-idempotent-across-repeated-runs" none c_migration_is_idempotent

# v1.1.0 REVERSES the old rule here, on the owner's direction. A fresh host
# used to be given config/clusters.yaml.example, so its first cluster list was
# somebody else's brokers. Now a host with nothing to migrate gets an EMPTY
# store, and nothing — no example, no default — is ever imported into it.
c_fresh_host_gets_an_empty_store() {
    _mkconfig_legacy
    # A decoy example beside the config: the old code would have imported it.
    printf 'clusters:\n  - id: decoy\n    name: Decoy\n    bootstrap_servers: "decoy.example.org:9092"\n    security_protocol: PLAINTEXT\n    active: true\n' \
        > "${TM_TMP}/clusters.yaml.example"
    _py "
import io, os, re
p = os.environ['TM_CONFIG']
s = io.open(p, encoding='utf-8').read()
s = re.sub(r'clusters:.*?\nsession:', 'session:', s, flags=re.S)
io.open(p, 'w', encoding='utf-8').write(s)
" > /dev/null
    OUT="$(_py "
import os, yaml
from tm.migrate_clusters import migrate
migrate(os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR'])
migrate(os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR'])   # and again: still empty
d = yaml.safe_load(open(os.path.join(os.environ['TM_CLUSTERS_DIR'], 'clusters.yaml'), encoding='utf-8'))
print('clusters=%r' % (d.get('clusters'),))
")"
    case "$OUT" in
        *"clusters=[]"*) ;;
        *) _tm_afail "a fresh host did not get an EMPTY cluster store (or a second run
        filled it). Got: ${OUT}" ;;
    esac
    case "$OUT" in *decoy*) _tm_afail "an example profile was imported as a live cluster: ${OUT}" ;; esac
}
tm_case "a-fresh-host-gets-an-empty-store-never-the-example" none c_fresh_host_gets_an_empty_store

c_existing_empty_store_is_left_alone() {
    # "Already migrated" means changes NOTHING, and an empty store is migrated.
    # MUTATION FINDING 2026-09-26 (MC5): with the empty-store branch removed the
    # store was silently REWRITTEN on every run — same list, so the other
    # cases stayed green, but an operator's comments in it were destroyed.
    _mkconfig_legacy
    _py "
import io, os, re
p = os.environ['TM_CONFIG']
s = io.open(p, encoding='utf-8').read()
io.open(p, 'w', encoding='utf-8').write(re.sub(r'(?ms)^clusters:.*?(?=^\w|\Z)', '', s))
" > /dev/null
    printf '# operator note: clusters come later\nclusters: []\n' > "${TM_TMP}/clusters.d/clusters.yaml"
    cp "${TM_TMP}/clusters.d/clusters.yaml" "${TM_TMP}/before.yaml"
    _py "
import os
from tm.migrate_clusters import migrate
migrate(os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR'])
" > /dev/null
    cmp -s "${TM_TMP}/before.yaml" "${TM_TMP}/clusters.d/clusters.yaml" \
        || _tm_afail "an existing EMPTY store was rewritten; the operator's comment is gone:
        $(cat "${TM_TMP}/clusters.d/clusters.yaml")"
}
tm_case "an-existing-empty-store-is-left-untouched" none c_existing_empty_store_is_left_alone

c_legacy_block_still_migrates_into_an_empty_store() {
    # An existing EMPTY store must not swallow a legacy block that still has
    # real profiles in it.
    _mkconfig_legacy
    printf 'clusters: []\n' > "${TM_TMP}/clusters.d/clusters.yaml"
    OUT="$(_py "
import os, yaml
from tm.migrate_clusters import migrate
migrate(os.environ['TM_CONFIG'], os.environ['TM_CLUSTERS_DIR'])
d = yaml.safe_load(open(os.path.join(os.environ['TM_CLUSTERS_DIR'], 'clusters.yaml'), encoding='utf-8'))
print('ids=%s' % [c['id'] for c in d['clusters']])
")"
    case "$OUT" in
        *"ids=['legacy']"*) ;;
        *) _tm_afail "a legacy clusters: block was dropped because an empty store existed: ${OUT}" ;;
    esac
}
tm_case "legacy-profiles-still-migrate-into-an-empty-store" none c_legacy_block_still_migrates_into_an_empty_store

tm_finish
