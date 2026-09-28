#!/usr/bin/env bash
# Frontend-only v1.2.0 contract checks against the real Settings component.
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"
tm_header "Settings v1.2.0 bindings, validation, host jobs, panels and certificate handling"
PROBE="${TM_TESTS_DIR}/lib/settings-v120-probe.js"
probe_case() {
    node "$PROBE" "$TM_REPO_ROOT" "$SCENARIO" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "$(cat "${TM_TMP}/out")"
    tm_assert_eq "ALL ${EXPECTED} ASSERTIONS PASSED" "$(cat "${TM_TMP}/out")" \
        "probe did not complete exactly ${EXPECTED} assertions for ${SCENARIO}"
}
# Independent fixed counts: neither a zero exit nor a partial PASS is enough.
# One case per scenario below; tests/run.sh cannot count a tm_case in a loop.
# tm-expect-cases: 9
for SPEC in bindings:93 validation:269 errors:14 apply:45 timeout:13 panels:27 tls:103 ppsm:28 integration:83; do
    SCENARIO="${SPEC%:*}"
    EXPECTED="${SPEC#*:}"
    tm_case "settings-v120-${SCENARIO}" node probe_case
done
tm_finish
