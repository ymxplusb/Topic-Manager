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
from tm import audit, auth

MODE = os.environ.get('TM_PROBE_MODE', '')
if MODE == 'audit-raises':
    # The audit write fails. The standing rule: then the action does not happen.
    real = audit.log_action
    def failing(cfg, user, action, *a, **k):
        if action == 'SETTINGS_UPDATE':
            raise RuntimeError('audit store unavailable')
        return real(cfg, user, action, *a, **k)
    audit.log_action = failing
if MODE == 'login-inject':
    auth.validate_credentials = lambda cfg, u, p: (False, 'Invalid credentials')

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
            (now + datetime.timedelta(hours=1)).isoformat(), '192.0.2.10'))
db.commit(); db.close()

hdrs = {'Content-Type': 'application/json', 'Sec-Fetch-Site': 'same-origin'}
payloads = json.loads(sys.argv[1])
codes = []
for p in payloads:
    if MODE == 'login-inject':
        r = c.post('/api/auth/login', data=json.dumps(p), headers=hdrs)
    else:
        r = c.put('/api/settings', data=json.dumps(p), headers=hdrs)
    codes.append(r.status_code)
db = sqlite3.connect(os.environ['TM_TEST_DB'])
rows = db.execute("SELECT user, action, target, detail FROM audit_log "
                  "WHERE action IN ('SETTINGS_UPDATE','LOGIN_FAILED') ORDER BY id").fetchall()
settings = dict(db.execute("SELECT key, value FROM app_settings").fetchall())
print('codes=%s' % ','.join(str(x) for x in codes))
print('count=%d' % len(rows))
print('banner_text=%r' % settings.get('banner_text'))
for i, r in enumerate(rows):
    print('row%d=%s' % (i, json.dumps('|'.join(str(x) for x in r))))
PYPROBE
}

_run() {   # _run '<json array of payloads>' [mode]
    PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 TM_PROBE_MODE="${2:-}" \
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
    # Display settings are recorded old -> new (round 2): an auditor needs to
    # see WHAT the banner was changed to, not only that it was.
    case "$(_field "$out" row0)" in
        "\"auditor|SETTINGS_UPDATE|app_settings|changed: banner_bg: 'green' -> 'red'; banner_text: 'UNCLASSIFIED' -> 'SECRET//CANARY-VALUE'\"") ;;
        *) _tm_afail "the record does not carry the user and each display key old -> new: ${out}" ;;
    esac
}
tm_case "a-settings-change-writes-SETTINGS_UPDATE-old-to-new" tmapp a_update_is_audited

a_audit_failure_blocks_the_change() {
    # ADVERSARY F1: the change and its audit record are ONE transaction. If the
    # audit write fails, the banner must be exactly as it was and the caller
    # told so.
    _setup
    local out
    out="$(_run '[{"banner_text": "SHOULD-NOT-LAND"}]' audit-raises)"
    tm_assert_eq "500" "$(_field "$out" codes)" \
        "the settings PUT reported success although its audit record could not be written: ${out}"
    tm_assert_eq "None" "$(_field "$out" banner_text)" \
        "THE UNAUDITED CHANGE LANDED: app_settings holds the new banner text with no
        audit record of who set it: ${out}"
    tm_assert_eq "0" "$(_field "$out" count)" "a SETTINGS_UPDATE row exists for a refused change: ${out}"
}
tm_case "a-failed-audit-write-blocks-the-settings-change" tmapp a_audit_failure_blocks_the_change

a_unknown_keys_by_name_only() {
    _setup
    local out
    out="$(_run '[{"banner_bg": "red", "not_a_setting": "CANARY-2", "evil\nkey": "x"}]')"
    case "$out" in *CANARY-2*) _tm_afail "the VALUE of an unknown key reached the audit record: ${out}" ;; esac
    case "$(_field "$out" row0)" in
        *"ignored unknown key(s): 'evil\\\\nkey', 'not_a_setting'"*) ;;
        *) _tm_afail "unknown keys were not recorded by name with %r: ${out}" ;;
    esac
}
tm_case "unknown-keys-are-named-with-repr-never-valued" tmapp a_unknown_keys_by_name_only

# MUTATION FINDING 2026-09-26 (S7): log_action committing the CALLER's
# connection survived every route case, because the patched failure is raised
# before any commit. It would split the one transaction in two the moment
# anything after the audit write failed. Driven directly: stdlib only.
a_log_action_leaves_the_transaction_open() {
    local out db
    db="$(cygpath -m "${TM_TMP}/tx.db" 2>/dev/null || printf '%s' "${TM_TMP}/tx.db")"
    out="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
import sys
from tm.models import init_db, get_db
from tm import audit
cfg = {'audit': {'db_path': sys.argv[1]}}
init_db(cfg)
db = get_db(cfg)
db.execute(\"INSERT INTO app_settings (key, value) VALUES ('banner_text', 'X')\")
audit.log_action(cfg, 'u', 'SETTINGS_UPDATE', 'app_settings', 'd', '', db=db)
db.rollback(); db.close()
db = get_db(cfg)
print('settings=%d audit=%d' % (db.execute('SELECT COUNT(*) FROM app_settings').fetchone()[0],
                                db.execute('SELECT COUNT(*) FROM audit_log').fetchone()[0]))
" "$db" 2>&1 | tr -d '\r')"
    tm_assert_eq "settings=0 audit=0" "$out" \
        "log_action(db=...) committed the caller's transaction, so the change and its
        audit record are no longer one unit"
}
tm_case "log-action-on-a-caller-connection-does-not-commit" none a_log_action_leaves_the_transaction_open

a_non_display_keys_are_names_only() {
    # Every key in _ALL_KEYS today is a display key, so the allowlist boundary
    # is driven through the real helper with a key outside it.
    local out
    out="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
from tm.routes import _settings_audit_detail
print(_settings_audit_detail({'smtp_password': 'OLD-SECRET', 'banner_bg': 'green'},
                             {'smtp_password': 'NEW-SECRET', 'banner_bg': 'red'},
                             ['banner_bg', 'smtp_password'], []))
" 2>&1 | tr -d '\r')"
    case "$out" in *SECRET*) _tm_afail "a key outside the display allowlist was recorded with its value: ${out}" ;; esac
    tm_assert_eq "changed: banner_bg: 'green' -> 'red'; smtp_password" "$out" \
        "the detail is not old->new for display keys and name-only for the rest"
}
tm_case "keys-outside-the-display-allowlist-are-names-only" tmapp a_non_display_keys_are_names_only

a_only_changed_keys_are_named() {
    _setup
    local out
    # Same value twice: the second PUT changes nothing and must say so, rather
    # than naming a key that did not move.
    out="$(_run '[{"banner_bg": "red", "dow_enabled": "true"}, {"banner_bg": "red", "dow_enabled": "false"}]')"
    tm_assert_eq "2" "$(_field "$out" count)" "expected one record per PUT: ${out}"
    case "$(_field "$out" row1)" in
        *"|changed: dow_enabled: 'true' -> 'false'\"") ;;
        *) _tm_afail "the second record named a key whose value did not change: ${out}" ;;
    esac
}
tm_case "only-keys-that-changed-are-named" tmapp a_only_changed_keys_are_named

a_login_username_cannot_forge_a_line() {
    _setup
    local out
    out="$(_run '[{"username": "mallory\nINFO fake line\r", "password": "x"}]' login-inject)"
    tm_assert_eq "401" "$(_field "$out" codes)" "the stubbed failed login did not answer 401: ${out}"
    case "$(_field "$out" row0)" in
        "\"mallory?INFO fake line|LOGIN_FAILED|"*) ;;
        *) _tm_afail "control characters from the username reached the audit record: ${out}" ;;
    esac
}
tm_case "a-username-cannot-inject-control-characters" tmapp a_login_username_cannot_forge_a_line

a_session_count_is_locked() {
    "$PY" - "${TM_REPO_ROOT}/tm/routes.py" <<'PYEOF' > "${TM_TMP}/ast" 2>&1
import ast, sys
src = open(sys.argv[1], encoding="utf-8").read()
fn = [n for n in ast.walk(ast.parse(src)) if isinstance(n, ast.FunctionDef) and n.name == "login"][0]
seg = ast.get_source_segment(src, fn)
b = seg.find("db.execute('BEGIN IMMEDIATE')")
c = seg.find("count_active_sessions(")
i = seg.find("create_session(")
print("OK" if 0 <= b < c < i else "BAD begin=%d count=%d insert=%d" % (b, c, i))
PYEOF
    grep -q '^OK$' "${TM_TMP}/ast" \
        || _tm_afail "login no longer counts and inserts under BEGIN IMMEDIATE: $(cat "${TM_TMP}/ast")"
}
tm_case "login-counts-and-inserts-under-one-write-lock" none a_session_count_is_locked

a_readme_lists_it() {
    grep -q 'SETTINGS_UPDATE' "${TM_REPO_ROOT}/README.md" \
        || _tm_afail "README.md's Compliance audit-action list does not name SETTINGS_UPDATE"
}
tm_case "readme-compliance-list-names-SETTINGS_UPDATE" none a_readme_lists_it

tm_finish
