#!/usr/bin/env bash
# =============================================================================
# t22 — EVERY VERSION SURFACE SAYS WHAT VERSION SAYS (v1.1.0).
#
# CI compares VERSION with the tag and nothing else, and tm/VERSION — what
# /api/health serves and what the upgrade verifies the running service
# against — stayed at 1.0.6 through six releases. This file runs
# tools/check-version-surfaces.sh inside the suite, so the CI test lane (which
# runs `tests/run.sh --strict` on every tag) now holds tm/VERSION, the PPSM
# pair, the headers, the docs and the ?v= cache tokens to VERSION as well.
# The second and third cases prove the gate can fail, against copies.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "tm/VERSION and every other surface agree with VERSION"

GATE="${TM_REPO_ROOT}/tools/check-version-surfaces.sh"
[ -f "$GATE" ] || tm_die "tools/check-version-surfaces.sh is missing"

v_agree() {
    bash "$GATE" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "a version surface disagrees with VERSION:
        $(grep FAIL "${TM_TMP}/out")"
}
tm_case "every-surface-agrees-with-VERSION" none v_agree

_copy() {
    local r="${TM_TMP}/copy" f
    rm -rf "$r"; mkdir -p "$r/tm" "$r/app/styles" "$r/app/components/modals" "$r/docs"
    for f in VERSION tm/VERSION PPSM.csv install.sh prepare-offline.sh SBOM.md README.md \
             CHANGELOG.md index.html app/main.js app/styles/main.css docs/INSTALL.md; do
        cp "${TM_REPO_ROOT}/${f}" "$r/${f}"
    done
    cp "${TM_REPO_ROOT}"/app/components/*.js "$r/app/components/"
    cp "${TM_REPO_ROOT}"/app/components/modals/*.js "$r/app/components/modals/"
}

v_tm_version_drift() {
    _copy
    bash "$GATE" --root "${TM_TMP}/copy" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "the unmodified copy already fails: $(grep FAIL "${TM_TMP}/out")"
    printf '1.0.6\n' > "${TM_TMP}/copy/tm/VERSION"
    bash "$GATE" --root "${TM_TMP}/copy" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "tm/VERSION at 1.0.6 passed — the exact drift that went unnoticed for six releases"
    tm_assert_grep "tm/VERSION" "${TM_TMP}/out" "the gate failed but did not name tm/VERSION"
}
tm_case "a-stale-tm-VERSION-is-caught" none v_tm_version_drift

v_token_drift() {
    _copy
    sed -i 's/?v=\([0-9]*\)"/?v=1\1"/' "${TM_TMP}/copy/app/components/TopBar.js"
    bash "$GATE" --root "${TM_TMP}/copy" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "one component with a different ?v= token passed — browsers would mix releases"
    tm_assert_grep "cache tokens" "${TM_TMP}/out" "the gate failed, but not on the tokens"
}
tm_case "a-mixed-cache-token-is-caught" none v_token_drift

# Round 2 (adversary F8): the FALLBACK, not only the seed.
v_fallback_literal() {
    _copy
    sed -i "s/version.value = d.version || 'unknown';/version.value = d.version || '1.0.9';/" "${TM_TMP}/copy/app/main.js"
    cmp -s "${TM_REPO_ROOT}/app/main.js" "${TM_TMP}/copy/app/main.js" && tm_die "the fixture changed nothing"
    bash "$GATE" --root "${TM_TMP}/copy" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "main.js falling back to a hard-coded '1.0.9' passed — the app would assert a version it was never told"
    tm_assert_grep "version literal" "${TM_TMP}/out" "the gate failed, but not on the literal"
}
tm_case "a-version-literal-in-the-main-js-fallback-is-caught" none v_fallback_literal

tm_finish
