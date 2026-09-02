#!/usr/bin/env bash
# =============================================================================
# t13 — THE AUDIT TRAIL RECORDS THE REAL CLIENT ADDRESS.
#
# gunicorn binds 127.0.0.1:5001 and nginx is the only thing that talks to it,
# so request.remote_addr is 127.0.0.1 for every request ever made. Nothing read
# nginx's X-Real-IP / X-Forwarded-For, so every session row and every login line
# in the log said "127.0.0.1" — an audit trail that cannot say who did anything,
# which is the one thing it exists to say.
#
# EXACTLY ONE HOP. nginx sets X-Forwarded-For with $proxy_add_x_forwarded_for,
# which APPENDS the real peer to whatever the client sent, so the LAST entry is
# the one nginx itself added and every earlier entry is chosen by the client. A
# ProxyFix configured for more than one hop would let a caller write its own
# address into the audit log — the failure mode is worse than the one being
# fixed, because the record then looks precise and is false.
#
# Needs the full app (Flask + the backend's imports), so it SKIPS loudly where
# ldap3 and confluent-kafka are absent.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "the proxy's client address reaches the application"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"

_mkconfig() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs"
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
    printf 'clusters:\n  - id: c1\n    name: C1\n    bootstrap_servers: "h:9092"\n    security_protocol: PLAINTEXT\n    active: true\n' \
        > "${TM_TMP}/clusters.d/clusters.yaml"
    rm -f "${TM_TMP}/tm.db"
}

_probe() {
    cat > "${TM_TMP}/probe.py" <<'PYPROBE'
from flask import request
from tm.app import create_app

app = create_app()

@app.route('/__peer')
def peer():
    return request.remote_addr or 'none'

c = app.test_client()

# No proxy headers at all: whatever the peer really is.
bare = c.get('/__peer').get_data(as_text=True)

# One hop, the shape nginx produces on a direct client connection.
one = c.get('/__peer', headers={'X-Forwarded-For': '203.0.113.9'}).get_data(as_text=True)

# The client sent its own X-Forwarded-For and nginx APPENDED the real peer.
# Only the last entry may be believed.
spoof = c.get('/__peer', headers={
    'X-Forwarded-For': '10.9.9.9, 198.51.100.7, 203.0.113.9'}).get_data(as_text=True)

print('bare=%s one=%s spoof=%s' % (bare, one, spoof))
PYPROBE
    OUT="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 \
        TM_CONFIG="${TM_TMP}/config.yaml" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
        TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        "$PY" "${TM_TMP}/probe.py" 2>&1 | tr -d '\r')"
}

x_forwarded_for_is_used() {
    _mkconfig; _probe
    case "$OUT" in
        *"one=203.0.113.9"*) ;;
        *) _tm_afail "the forwarded client address was ignored: every session row
        and every login line records the loopback address, and the audit log
        cannot say who did anything. Got: ${OUT}" ;;
    esac
}
tm_case "the-forwarded-client-address-is-used" tmapp x_forwarded_for_is_used

only_one_hop_is_trusted() {
    _mkconfig; _probe
    case "$OUT" in
        *"spoof=203.0.113.9"*) ;;
        *"spoof=10.9.9.9"*) _tm_afail "the FIRST X-Forwarded-For entry was believed.
        nginx appends the real peer to whatever the client sent, so that entry
        is chosen by the caller: any user can write their own address into the
        audit log, and it looks precise. Got: ${OUT}" ;;
        *) _tm_afail "unexpected address from a multi-hop X-Forwarded-For: ${OUT}" ;;
    esac
}
tm_case "exactly-one-proxy-hop-is-trusted" tmapp only_one_hop_is_trusted

tm_finish
