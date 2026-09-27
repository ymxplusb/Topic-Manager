#!/usr/bin/env bash
# Frontend-only v1.2.0 contract checks against the real Settings component.
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"
tm_header "Settings v1.2.0 bindings, validation, host jobs, panels and certificate handling"
PROBE="${TM_TESTS_DIR}/lib/settings-v120-probe.js"
probe_case() {
    node "$PROBE" "$TM_REPO_ROOT" "$SCENARIO" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "$(cat "${TM_TMP}/out")"
}
for SCENARIO in bindings validation errors apply timeout panels tls ppsm; do
    tm_case "settings-v120-${SCENARIO}" node probe_case
done
tm_finish
