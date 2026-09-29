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

# Round 2 (adversary F7): the SAME wrong edit in both copies agrees perfectly,
# so the core rows are pinned, protocol column included.
p_identical_protocol_edit() {
    sed 's/"Web","HTTPS","443","TCP"/"Web","HTTPS","443","UDP"/' "${TM_REPO_ROOT}/PPSM.csv" > "${TM_TMP}/PPSM.csv"
    sed "s/\['Web', 'HTTPS', '443', 'TCP'/['Web', 'HTTPS', '443', 'UDP'/" \
        "${TM_REPO_ROOT}/app/components/SettingsTab.js" > "${TM_TMP}/SettingsTab.js"
    cmp -s "${TM_REPO_ROOT}/PPSM.csv" "${TM_TMP}/PPSM.csv" && tm_die "the CSV fixture changed nothing"
    cmp -s "${TM_REPO_ROOT}/app/components/SettingsTab.js" "${TM_TMP}/SettingsTab.js" && tm_die "the JS fixture changed nothing"
    PPSM_STATIC="${TM_TMP}/PPSM.csv" PPSM_SETTINGS="${TM_TMP}/SettingsTab.js" bash "$GATE" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "443/TCP changed to UDP in BOTH copies passed — agreement is not correctness"
    tm_assert_grep "pinned protocol is TCP" "${TM_TMP}/out" "the gate failed, but not on the pinned protocol"
}
tm_case "an-identical-protocol-edit-in-both-copies-goes-red" node p_identical_protocol_edit

# v1.2.0 round 4: gunicorn has no TCP port. A 5001 row put back in BOTH copies
# agrees perfectly, and would tell an auditor a port is open that is not.
p_5001_row_goes_red() {
    sed 's#^"App","systemd-resolved"#"App","gunicorn (Flask)","5001","TCP","Loopback","x"\n"App","systemd-resolved"#' \
        "${TM_REPO_ROOT}/PPSM.csv" > "${TM_TMP}/PPSM.csv"
    sed "s#^\(                \)\['App', 'systemd-resolved'#\1['App', 'gunicorn (Flask)', '5001', 'TCP', 'Loopback', 'x'],\n\1['App', 'systemd-resolved'#" \
        "${TM_REPO_ROOT}/app/components/SettingsTab.js" > "${TM_TMP}/SettingsTab.js"
    cmp -s "${TM_REPO_ROOT}/PPSM.csv" "${TM_TMP}/PPSM.csv" && tm_die "the CSV fixture changed nothing"
    cmp -s "${TM_REPO_ROOT}/app/components/SettingsTab.js" "${TM_TMP}/SettingsTab.js" && tm_die "the JS fixture changed nothing"
    PPSM_STATIC="${TM_TMP}/PPSM.csv" PPSM_SETTINGS="${TM_TMP}/SettingsTab.js" bash "$GATE" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a 5001 row added identically to both copies passed"
    tm_assert_grep "a 5001 row is listed" "${TM_TMP}/out" "the gate failed, but not on the 5001 row"
    grep -q "disagree" "${TM_TMP}/out" && _tm_afail "the fixture made the copies disagree, so the case proves nothing about the 5001 rule"
    true
}
tm_case "a-5001-row-in-both-copies-goes-red" node p_5001_row_goes_red

tm_finish
