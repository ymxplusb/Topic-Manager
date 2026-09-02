#!/usr/bin/env bash
# =============================================================================
# t12 — THE RESTART CONTROL IS A PERSISTENT STOP PRIMITIVE, AND IS THROTTLED.
#
# MEASURED on prod 2026-09-01: both topic-manager.service and nginx.service
# carry systemd's defaults, StartLimitIntervalUSec=10s / StartLimitBurst=5.
# Five starts inside ten seconds trip the limiter, after which systemd REFUSES
# to start the unit until an operator runs `systemctl reset-failed` on the host.
# POST /api/service/restart is reachable by any authenticated user, so without a
# cooldown five requests are a persistent outage — of the application and, with
# the hard-nginx box ticked, of the web server serving the control used to fix it.
#
# THE POINT OF THIS FILE IS THE SECOND PROCESS. gunicorn runs FOUR workers, each
# with its own memory, so a module-level timestamp throttles one worker in four
# and the other three restart on demand. Every case below that matters therefore
# claims from a SEPARATE python process against the same database — a
# same-process test would pass on an implementation that cannot work in
# production.
#
# tm/service_control.py imports nothing outside the standard library, so these
# run on the workstation as well as on the host. The route-level case needs the
# whole app and is skipped where ldap3 is absent, loudly.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "the restart cooldown and single-flight"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"

# The interval is a DECISION recorded as a constant. Read it from the module
# rather than repeating the number here: a test that hardcodes 30 keeps passing
# when someone changes the constant to 0.
INTERVAL="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 \
    "$PY" -c "import tm.service_control as s; print(s.RESTART_MIN_INTERVAL_S)" 2>&1 | tr -d '\r')"
case "$INTERVAL" in
    ''|*[!0-9]*) tm_die "could not read RESTART_MIN_INTERVAL_S from tm/service_control.py: ${INTERVAL}" ;;
esac

# _claim <now> — ONE separate process, one claim. Prints "ALLOWED <remaining>"
# or "REFUSED <remaining>".
_claim() {
    PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 \
        "$PY" -c "
import sys
from tm.service_control import claim_restart_slot
cfg = {'audit': {'db_path': sys.argv[1]}}
ok, rem = claim_restart_slot(cfg, now=float(sys.argv[2]))
print('%s %.3f' % ('ALLOWED' if ok else 'REFUSED', rem))
" "$DB" "$1" 2>&1 | tr -d '\r'
}

DB=""
_mkdb() {
    DB="${TM_TMP}/tm.db"
    rm -f "$DB"
    PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 \
        "$PY" -c "
import sys
from tm.models import init_db
init_db({'audit': {'db_path': sys.argv[1]}})
" "$DB" > "${TM_TMP}/initdb.out" 2>&1 \
        || tm_die "could not create the test database: $(cat "${TM_TMP}/initdb.out")"
}

_verb() { set -- $1; echo "$1"; }
_rem()  { set -- $1; echo "$2"; }

# ─── the claim, across separate processes ────────────────────────────────────
r_second_process_is_refused() {
    _mkdb
    local a b
    a="$(_claim 1000)"
    b="$(_claim 1001)"      # a whole second later, and a DIFFERENT process
    tm_assert_eq "ALLOWED" "$(_verb "$a")" "the first claim was refused: ${a}"
    tm_assert_eq "REFUSED" "$(_verb "$b")" \
        "a second process claimed a restart one second after the first. A
        module-level timestamp gives exactly this result: four gunicorn workers,
        four independent caches, and the throttle stops nothing"
}
tm_case "a-second-process-is-refused-inside-the-interval" none r_second_process_is_refused

r_five_rapid_claims_yield_one() {
    # The shape of the actual attack: five requests inside the ten-second
    # window systemd counts. Exactly one may be allowed.
    _mkdb
    local i out allowed=0
    for i in 0 1 2 3 4; do
        out="$(_claim "$((1000 + i))")"
        [ "$(_verb "$out")" = "ALLOWED" ] && allowed=$((allowed + 1))
    done
    tm_assert_eq 1 "$allowed" \
        "${allowed} of five requests inside ten seconds were allowed. Five
        starts in ten seconds is exactly what trips StartLimitBurst, and the
        unit then refuses to start until systemctl reset-failed"
}
tm_case "five-requests-in-ten-seconds-yield-one-restart" none r_five_rapid_claims_yield_one

r_interval_expiry_allows_again() {
    # The throttle must not be a one-way door: after the interval it opens.
    # Driven off the constant, so changing the constant changes the test.
    _mkdb
    local a b
    a="$(_claim 1000)"
    b="$(_claim "$((1000 + INTERVAL))")"
    tm_assert_eq "ALLOWED" "$(_verb "$a")" "the first claim was refused: ${a}"
    tm_assert_eq "ALLOWED" "$(_verb "$b")" \
        "a claim ${INTERVAL}s later was still refused — the cooldown never
        expires and the restart control is permanently dead after one use"
}
tm_case "a-claim-after-the-full-interval-is-allowed" none r_interval_expiry_allows_again

r_just_inside_the_interval_is_refused() {
    # The boundary, from the other side: one second short must still refuse.
    _mkdb
    local b
    _claim 1000 > /dev/null
    b="$(_claim "$((1000 + INTERVAL - 1))")"
    tm_assert_eq "REFUSED" "$(_verb "$b")" \
        "a claim one second short of the interval was allowed — the comparison
        is off by one in the permissive direction"
}
tm_case "a-claim-one-second-short-is-refused" none r_just_inside_the_interval_is_refused

r_remaining_is_reported() {
    # The UI shows this number and the route puts it in Retry-After. A refusal
    # that says "wait 0 seconds" is a refusal the operator cannot act on.
    _mkdb
    local b rem
    _claim 1000 > /dev/null
    b="$(_claim 1010)"
    rem="$(_rem "$b")"
    tm_assert_eq "REFUSED" "$(_verb "$b")" "expected a refusal: ${b}"
    case "$rem" in
        0.000|'') _tm_afail "the refusal reported ${rem}s remaining — the client is
        told to retry immediately, which is the loop the cooldown exists to stop" ;;
    esac
    # 30s interval, 10s elapsed -> 20s remaining.
    tm_assert_eq "$((INTERVAL - 10)).000" "$rem" "the remaining time is wrong: ${b}"
}
tm_case "the-refusal-reports-the-time-remaining" none r_remaining_is_reported

r_state_is_shared_not_in_memory() {
    # Belt and braces on the thing that actually breaks in production: the
    # claim must leave a mark OUTSIDE the process. If it does not, no other
    # worker can see it.
    _mkdb
    _claim 1000 > /dev/null
    local rows
    rows="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
print(len(db.execute(\"SELECT 1 FROM app_settings WHERE key='service_restart_last_epoch'\").fetchall()))
" "$DB" 2>&1 | tr -d '\r')"
    tm_assert_eq 1 "$rows" \
        "the claim left nothing in the shared database, so the other three
        gunicorn workers cannot see it: got [${rows}]"
}
tm_case "the-claim-is-recorded-where-every-worker-can-see-it" none r_state_is_shared_not_in_memory

# ─── the route ───────────────────────────────────────────────────────────────
# 429, with Retry-After, and NOTHING touched: the nginx test unit must not even
# be started, because starting it is itself a systemd start with its own limit.
r_route_returns_429() {
    cat > "${TM_TMP}/config.yaml" <<YAML
server:
  host: 127.0.0.1
  port: 5001
  secret_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

auth:
  ldap_server: "ldaps://dc1.example.com:636"
  ldap_domain: "example.com"
  ldap_base_dn: "DC=example,DC=com"
  required_group: "CN=Kafka-Admins,DC=example,DC=com"

session:
  timeout_minutes: 30

audit:
  db_path: "${TM_TMP}/tm.db"

logging:
  log_level: "ERROR"
YAML
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs"
    printf 'clusters:\n  - id: c1\n    name: C1\n    bootstrap_servers: "h:9092"\n    security_protocol: PLAINTEXT\n    active: true\n' \
        > "${TM_TMP}/clusters.d/clusters.yaml"
    rm -f "${TM_TMP}/tm.db"

    cat > "${TM_TMP}/probe.py" <<'PYPROBE'
import os
from tm.app import create_app
from tm import service_control

# The nginx test unit must NOT be started on a throttled request: starting it
# is a systemd start of its own. If it is reached, this records it.
STARTED = []
service_control.nginx_config_test = lambda: (STARTED.append(1), (True, 'stubbed'))[1]
service_control.restart_detached = lambda hard, cb: STARTED.append('restart')

app = create_app()
c = app.test_client()
with c.session_transaction() as s:
    s['user'] = {'username': 'tester', 'display_name': 'Tester'}
    s['sid'] = 'test-session'

# The session is validated against the sessions table; insert one that matches.
import sqlite3, datetime
db = sqlite3.connect(os.environ['TM_TEST_DB'])
now = datetime.datetime.now(datetime.timezone.utc)
db.execute('INSERT OR REPLACE INTO sessions (id, user, created_at, last_seen, expires_at, ip_addr)'
           ' VALUES (?,?,?,?,?,?)',
           ('test-session', 'tester', now.isoformat(), now.isoformat(),
            (now + datetime.timedelta(hours=1)).isoformat(), '10.0.0.1'))
db.commit(); db.close()

hdrs = {'Content-Type': 'application/json', 'Sec-Fetch-Site': 'same-origin'}
first  = c.post('/api/service/restart', json={'restart_nginx': False}, headers=hdrs)
second = c.post('/api/service/restart', json={'restart_nginx': False}, headers=hdrs)
print('first=%d second=%d retry_after=%s reached=%d'
      % (first.status_code, second.status_code,
         second.headers.get('Retry-After'), len(STARTED)))
PYPROBE
    OUT="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 \
        TM_CONFIG="${TM_TMP}/config.yaml" \
        TM_TEST_DB="${TM_TMP}/tm.db" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
        TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        "$PY" "${TM_TMP}/probe.py" 2>&1 | tr -d '\r')"
    case "$OUT" in
        *"first=202 second=429"*) ;;
        *) _tm_afail "the second restart request inside the cooldown did not get a
        429. Any authenticated user can send five of these, and five starts in
        ten seconds leave systemd refusing to start the unit at all.
        Got: ${OUT}" ;;
    esac
    case "$OUT" in
        *"retry_after=None"*) _tm_afail "the 429 carried no Retry-After header: ${OUT}" ;;
    esac
    case "$OUT" in
        # one nginx test + one restart from the FIRST request, and nothing from
        # the second: the throttled request must not reach systemd at all.
        *"reached=2"*) ;;
        *) _tm_afail "the throttled request still reached systemd — the claim is
        being made after the nginx test rather than before it. Got: ${OUT}" ;;
    esac
}
tm_case "the-route-answers-429-and-touches-nothing" tmapp r_route_returns_429

tm_finish
