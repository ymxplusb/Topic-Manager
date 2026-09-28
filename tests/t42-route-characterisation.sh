#!/usr/bin/env bash
# =============================================================================
# t42 — CHARACTERISATION of the two routes v1.2.0 refactored for Sonar's
# cognitive-complexity limit (S3776, 15): sign-in at the concurrent-session
# limit, and topic creation's config assembly.
#
# Neither behaviour had a test that could tell the refactor from the original:
# t31 counts the 429s but never read the refusal body or its LOGIN_REFUSED
# audit row, never exercised a limit of 0 (unlimited), and nothing at all
# drove create_topic's six top-level config fields. Every expected line below
# was RECORDED on the pre-refactor code (release/v1.2.0 83af254, the v1.1.1
# merge) and then held against the refactor, byte for byte.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "route characterisation: session-limit refusal and topic config assembly"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_setup() {
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
  log_level: "WARNING"
YAML
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs"
    printf 'clusters:\n  - id: c1\n    name: C1\n    bootstrap_servers: "h:9092"\n    security_protocol: PLAINTEXT\n    active: true\n' \
        > "${TM_TMP}/clusters.d/clusters.yaml"
}

_app() {   # _app <python body>; `app`, `db()`, `H`, `calls` in scope. The app's
           # own log lines (no syslog socket here) go to probe.err, not the transcript.
    cat > "${TM_TMP}/probe.py" <<PYEOF
import json, os, sqlite3, datetime
from tm import auth, kafka_client
calls = []
kafka_client.create_topic = lambda c, n, p, r, cf: calls.append((c.get('id'), n, p, r, sorted(cf.items())))
auth.validate_credentials = lambda cfg, u, p: (True, {'username': u, 'display_name': u})
from tm.app import create_app
app = create_app()
def db():
    return sqlite3.connect(os.environ['TM_TEST_DB'])
H = {'Content-Type': 'application/json', 'Sec-Fetch-Site': 'same-origin'}
$1
PYEOF
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 TM_CONFIG="${TM_TMP}/config.yaml" \
        TM_TEST_DB="${TM_TMP}/tm.db" TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
        TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" TM_SYSLOG_SOCKET="${TM_TMP}/no-such.sock" \
        "$PY" "${TM_TMP}/probe.py" > "${TM_TMP}/probe.out" 2> "${TM_TMP}/probe.err" \
        || _tm_afail "the probe exited non-zero: $(tail -5 "${TM_TMP}/probe.err")"
    tr -d '\r' < "${TM_TMP}/probe.out"
}

_LOGIN='
def logins(limit, n):
    d = db()
    d.execute("INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)", ("session_max_concurrent", str(limit)))
    d.execute("DELETE FROM sessions"); d.commit(); d.close()
    out = []
    for i in range(n):
        r = app.test_client().post("/api/auth/login", data=json.dumps({"username": "alice", "password": "x"}), headers=H)
        out.append((r.status_code, r.get_json().get("error")))
    return out
app.test_client()   # the app is built; the audit and session tables exist
for code, err in logins(1, 3):
    print("limit1 %d %s" % (code, err))
print("limit0 %s" % [c for c, _ in logins(0, 4)])
print("sessions=%d" % db().execute("SELECT COUNT(*) FROM sessions WHERE user = ?", ("alice",)).fetchone()[0])
for row in db().execute("SELECT user, action, target, detail FROM audit_log WHERE action = ? ORDER BY id", ("LOGIN_REFUSED",)):
    print("audit %s|%s|%s|%s" % row)
'

a_session_limit_refusal() {
    _setup
    local out; out="$(_app "$_LOGIN")" || _tm_afail "${out}"
    local want
    want="limit1 200 None
limit1 429 Concurrent session limit reached (1/1). Sign out from another session first.
limit1 429 Concurrent session limit reached (1/1). Sign out from another session first.
limit0 [200, 200, 200, 200]
sessions=4
audit alice|LOGIN_REFUSED|127.0.0.1|concurrent session limit reached (1/1)
audit alice|LOGIN_REFUSED|127.0.0.1|concurrent session limit reached (1/1)"
    tm_assert_eq "$want" "$out" "sign-in at the session limit no longer behaves as recorded on 83af254"
}
tm_case "sign-in-at-the-session-limit-is-unchanged" tmapp a_session_limit_refusal

_CREATE='
c = app.test_client()
with c.session_transaction() as s:
    s["user"] = {"username": "admin"}; s["sid"] = "sid1"
now = datetime.datetime.now(datetime.timezone.utc)
d = db(); d.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?)", ("sid1", "admin", now.isoformat(), now.isoformat(), (now + datetime.timedelta(hours=1)).isoformat(), "x")); d.commit(); d.close()
bodies = [
    {"name": "t.all", "partitions": 2, "replication_factor": 1,
     "config": {"retention.ms": "1", "cleanup.policy": "delete", "not.a.key": "x", "segment.ms": 9},
     "retention_ms": 5, "retention_bytes": 7, "cleanup_policy": "compact", "compression_type": "lz4",
     "min_insync_replicas": 2, "max_message_bytes": 100},
    {"name": "t.falsy", "retention_ms": 0, "retention_bytes": "", "cleanup_policy": None,
     "compression_type": False, "min_insync_replicas": [], "max_message_bytes": {}},
    {"name": "t.one", "config": {"max.message.bytes": "1"}, "max_message_bytes": "2"},
    {"name": "t.bad", "config": ["retention.ms"]},
]
for b in bodies:
    r = c.post("/api/topics", data=json.dumps(b), headers=H)
    print("%s %d %s" % (b["name"], r.status_code, r.get_json()))
for call in calls:
    print("kafka %s" % (call,))
for row in db().execute("SELECT target, detail FROM audit_log WHERE action = ? ORDER BY id", ("CREATE",)):
    print("audit %s|%s" % row)
'

a_topic_config_assembly() {
    _setup
    local out; out="$(_app "$_CREATE")" || _tm_afail "${out}"
    local want
    want="t.all 201 {'name': 't.all', 'ok': True}
t.falsy 201 {'name': 't.falsy', 'ok': True}
t.one 201 {'name': 't.one', 'ok': True}
t.bad 400 {'error': 'config must be an object'}
kafka ('c1', 't.all', 2, 1, [('cleanup.policy', 'compact'), ('compression.type', 'lz4'), ('max.message.bytes', '100'), ('min.insync.replicas', '2'), ('retention.bytes', '7'), ('retention.ms', '5'), ('segment.ms', '9')])
kafka ('c1', 't.falsy', 3, 3, [])
kafka ('c1', 't.one', 3, 3, [('max.message.bytes', '2')])
audit t.all|partitions=2, rf=1, config={'retention.ms': '5', 'cleanup.policy': 'compact', 'segment.ms': '9', 'retention.bytes': '7', 'compression.type': 'lz4', 'min.insync.replicas': '2', 'max.message.bytes': '100'}
audit t.falsy|partitions=3, rf=3, config={}
audit t.one|partitions=3, rf=3, config={'max.message.bytes': '2'}"
    tm_assert_eq "$want" "$out" "create_topic no longer assembles the topic config as recorded on 83af254"
}
tm_case "topic-creation-config-assembly-is-unchanged" tmapp a_topic_config_assembly

tm_finish
