#!/usr/bin/env bash
# =============================================================================
# t16 — PUT /api/settings WRITES AN AUDIT RECORD (v1.1.0).
#
# The route changes what EVERY user sees — the classification banner and the
# consent notice — and until v1.1.0 it wrote nothing to the audit log. These
# cases drive the real route through Flask's test client against a scratch
# database and read the audit_log table back.
#
# What the record must say: SETTINGS_UPDATE, who, and the NAMES of the keys
# that changed. What it must never say: the values. Every key is display-only
# today; the rule is enforced now so it already holds on the day a secret-
# bearing setting is added.
#
# Needs the whole app importable (Flask, ldap3, confluent-kafka): it SKIPS
# loudly where they are absent and runs on CI and on a host.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "PUT /api/settings is audited, by key name, never by value"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"

_setup() {
    # The path as the INTERPRETER will see it. On Git Bash, MSYS rewrites a
    # path in an environment variable for a native program but not one written
    # into a file, so the YAML must carry the native form or the app and this
    # probe open two different databases.
    local NT; NT="$(cygpath -m "$TM_TMP" 2>/dev/null || printf '%s' "$TM_TMP")"
    cat > "${TM_TMP}/config.yaml" <<YAML
server:
  host: 127.0.0.1
  port: 5001
  secret_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
auth:
  ldap_server: "ldaps://dc1.example.org:636"
  ldap_domain: "example.org"
  ldap_base_dn: "DC=example,DC=org"
  required_group: "CN=Kafka-Admins,DC=example,DC=org"
session:
  timeout_minutes: 30
audit:
  db_path: "${NT}/tm.db"
logging:
  log_level: "ERROR"
YAML
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs"
    printf 'clusters: []\n' > "${TM_TMP}/clusters.d/clusters.yaml"
    rm -f "${TM_TMP}/tm.db"
    cat > "${TM_TMP}/probe.py" <<'PYPROBE'
import json, os, sqlite3, datetime, sys
from tm.app import create_app

app = create_app()
c = app.test_client()
with c.session_transaction() as s:
    s['user'] = {'username': 'auditor', 'display_name': 'Auditor'}
    s['sid'] = 'test-session'
db = sqlite3.connect(os.environ['TM_TEST_DB'])
now = datetime.datetime.now(datetime.timezone.utc)
db.execute('INSERT OR REPLACE INTO sessions (id, user, created_at, last_seen, expires_at, ip_addr)'
           ' VALUES (?,?,?,?,?,?)',
           ('test-session', 'auditor', now.isoformat(), now.isoformat(),
            (now + datetime.timedelta(hours=1)).isoformat(), '10.0.0.1'))
db.commit(); db.close()

hdrs = {'Content-Type': 'application/json', 'Sec-Fetch-Site': 'same-origin'}
payloads = json.loads(sys.argv[1])
codes = []
for p in payloads:
    r = c.put('/api/settings', data=json.dumps(p), headers=hdrs)
    codes.append(r.status_code)
db = sqlite3.connect(os.environ['TM_TEST_DB'])
rows = db.execute("SELECT user, action, target, detail FROM audit_log "
                  "WHERE action='SETTINGS_UPDATE' ORDER BY id").fetchall()
print('codes=%s' % ','.join(str(x) for x in codes))
print('count=%d' % len(rows))
for i, r in enumerate(rows):
    print('row%d=%s' % (i, '|'.join(str(x) for x in r)))
PYPROBE
}

_run() {   # _run '<json array of payloads>'
    PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 \
        TM_CONFIG="${TM_TMP}/config.yaml" TM_TEST_DB="${TM_TMP}/tm.db" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        "$PY" "${TM_TMP}/probe.py" "$1" 2>&1 | tr -d '\r'
}
_field() { printf '%s\n' "$1" | grep -m1 "^${2}=" | cut -d= -f2- ; }

a_update_is_audited() {
    _setup
    local out
    out="$(_run '[{"banner_text": "SECRET//CANARY-VALUE", "banner_bg": "red"}]')"
    tm_assert_eq "200" "$(_field "$out" codes)" "the settings PUT did not succeed: ${out}"
    tm_assert_eq "1" "$(_field "$out" count)" \
        "a settings change wrote no SETTINGS_UPDATE record. It changes the banner
        for every user, and the audit log could not say who did it: ${out}"
    case "$(_field "$out" row0)" in
        "auditor|SETTINGS_UPDATE|app_settings|changed: banner_bg, banner_text"*) ;;
        *) _tm_afail "the record does not name the user and the changed keys: ${out}" ;;
    esac
}
tm_case "a-settings-change-writes-SETTINGS_UPDATE" tmapp a_update_is_audited

a_values_never_logged() {
    _setup
    local out
    out="$(_run '[{"banner_text": "SECRET//CANARY-VALUE", "banner_bg": "red", "not_a_setting": "CANARY-2"}]')"
    case "$out" in
        *CANARY*) _tm_afail "a setting VALUE reached the audit record. Key names only —
        the first secret-bearing setting would otherwise be logged in clear: ${out}" ;;
    esac
    case "$(_field "$out" row0)" in
        *"ignored unknown key(s): not_a_setting"*) ;;
        *) _tm_afail "a key the route refused was not recorded as ignored: ${out}" ;;
    esac
}
tm_case "setting-values-never-reach-the-audit-log" tmapp a_values_never_logged

a_only_changed_keys_are_named() {
    _setup
    local out
    # Same value twice: the second PUT changes nothing and must say so, rather
    # than naming a key that did not move.
    out="$(_run '[{"banner_bg": "red", "dow_enabled": "true"}, {"banner_bg": "red", "dow_enabled": "false"}]')"
    tm_assert_eq "2" "$(_field "$out" count)" "expected one record per PUT: ${out}"
    case "$(_field "$out" row1)" in
        *"|changed: dow_enabled") ;;
        *) _tm_afail "the second record named a key whose value did not change: ${out}" ;;
    esac
}
tm_case "only-keys-that-changed-are-named" tmapp a_only_changed_keys_are_named

a_readme_lists_it() {
    grep -q 'SETTINGS_UPDATE' "${TM_REPO_ROOT}/README.md" \
        || _tm_afail "README.md's Compliance audit-action list does not name SETTINGS_UPDATE"
}
tm_case "readme-compliance-list-names-SETTINGS_UPDATE" none a_readme_lists_it

tm_finish
