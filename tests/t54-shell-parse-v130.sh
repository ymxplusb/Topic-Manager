#!/usr/bin/env bash
# =============================================================================
# t54 — v1.3.0 (WO-0006 assure-fix-2): every shell script parses under the
# OLDEST bash these tests run on, not only Linux bash 5.
#
#   bash 3.2 (macOS /bin/bash) reads a heredoc inside $( ... ) as shell, so an
#   apostrophe in its body ("a BROWSER" + "'s status poll" in t51, a Python
#   comment in t14) left the whole file unparseable there: `bash -n` ->
#   unexpected EOF. Linux bash parsed it, so nothing on CI noticed.
#   tools/check-shell-parse.sh finds the pattern statically (no old bash
#   needed) and runs `bash -n` with a 3.x bash when one is present.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "every shell script parses under bash 3.2: no unpaired quote in a heredoc inside \$( )"

CHK="${TM_SHELL_PARSE:-${TM_REPO_ROOT}/tools/check-shell-parse.sh}"

a_tree_parses() {
    bash "$CHK" > "${TM_TMP}/out" 2>&1 || _tm_afail "a shell script in the tree does not parse under bash 3.2: $(cat "${TM_TMP}/out")"
    grep -q 'PASS ([0-9][0-9]* file(s))' "${TM_TMP}/out" || _tm_afail "the check did not say what it read: $(cat "${TM_TMP}/out")"
    # Every test file is in what it read (a scan of nothing is not a pass).
    local n; n="$(ls "${TM_REPO_ROOT}"/tests/t[0-9]*.sh | wc -l | tr -d ' ')"
    local read_n; read_n="$(sed -n 's/.*PASS (\([0-9]*\) file(s)).*/\1/p' "${TM_TMP}/out")"
    [ "${read_n:-0}" -gt "$n" ] || _tm_afail "the check read ${read_n:-0} file(s); there are ${n} test files alone"
}
tm_case "every-shell-script-in-the-tree-parses-under-bash-3-2" none a_tree_parses

# The defect exactly as it shipped in t51: the $( opens two lines above the <<.
a_the_pattern_is_found() {
    local q="'"
    {
        printf 'out="$(PATH=/x \\\n    A=1 \\\n    python3 - <<%sPYEOF%s 2>/dev/null | tr -d x\n' "$q" "$q"
        printf '# recorded by a BROWSER%ss status poll\nprint(1)\nPYEOF\n)"\n' "$q"
    } > "${TM_TMP}/bad.sh"
    {
        printf 'python3 - <<%sPYEOF%s\n# a BROWSER%ss status poll: not in a $( ), so fine\nPYEOF\n' "$q" "$q" "$q"
        printf 'out="$(python3 - <<%sPYEOF%s\nprint(%sit is paired%s)\nPYEOF\n)"\n' "$q" "$q" "$q" "$q"
    } > "${TM_TMP}/good.sh"
    TM_OLD_BASH= bash "$CHK" "${TM_TMP}/bad.sh" > "${TM_TMP}/out" 2>&1
    tm_assert_eq "1" "$?" "the unpaired apostrophe in a heredoc inside \$( ) was not found: $(cat "${TM_TMP}/out")"
    grep -q 'bad.sh:4: heredoc PYEOF (opened line 3 inside \$( ))' "${TM_TMP}/out" \
        || _tm_afail "the finding does not name the line: $(cat "${TM_TMP}/out")"
    TM_OLD_BASH= bash "$CHK" "${TM_TMP}/good.sh" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "a heredoc outside \$( ), or one whose quotes pair, was refused: $(cat "${TM_TMP}/out")"
    # With an old bash present it is used, and its verdict counts.
    if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]'; then
        TM_OLD_BASH=/bin/bash bash "$CHK" "${TM_TMP}/good.sh" > "${TM_TMP}/out" 2>&1
        grep -q 'bash 3[.].* -n on 1 file(s): clean' "${TM_TMP}/out" || _tm_afail "the old bash was not run: $(cat "${TM_TMP}/out")"
    fi
    true
}
tm_case "an-unpaired-quote-in-a-heredoc-inside-a-command-substitution-is-found" none a_the_pattern_is_found

tm_finish
