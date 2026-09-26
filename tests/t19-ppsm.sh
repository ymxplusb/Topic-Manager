#!/usr/bin/env bash
# =============================================================================
# t19 — ONE PPSM (v1.1.0).
#
# PPSM.csv and the CSV Settings > Download PPSM builds must be the same
# document. tools/check-ppsm-consistency.sh proves it by running the real
# generator; this case puts that gate inside the suite so CI (which runs
# `tests/run.sh --strict` with node installed) enforces it on every tag, and a
# second case proves the gate itself can fail, against copies, never the repo.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "PPSM.csv and downloadPpsm() are one document"

GATE="${TM_REPO_ROOT}/tools/check-ppsm-consistency.sh"
[ -f "$GATE" ] || tm_die "tools/check-ppsm-consistency.sh is missing"

p_agree() {
    bash "$GATE" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "the two PPSM documents disagree or are incomplete:
        $(cat "${TM_TMP}/out")"
}
tm_case "ppsm-csv-and-the-download-agree" node p_agree

# The gate must be able to say no. A one-cell drift in a COPY of PPSM.csv.
p_gate_can_fail() {
    sed 's/Redirect to HTTPS only (301)/Redirect to HTTPS (302)/' "${TM_REPO_ROOT}/PPSM.csv" > "${TM_TMP}/PPSM.csv"
    cmp -s "${TM_REPO_ROOT}/PPSM.csv" "${TM_TMP}/PPSM.csv" && tm_die "the drift fixture did not change anything"
    PPSM_STATIC="${TM_TMP}/PPSM.csv" bash "$GATE" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "the gate passed a PPSM.csv that disagrees with the generator by one cell"
    tm_assert_grep "disagree" "${TM_TMP}/out" "the gate failed, but not for the drift"
}
tm_case "the-gate-goes-red-on-a-one-cell-drift" node p_gate_can_fail

tm_finish
