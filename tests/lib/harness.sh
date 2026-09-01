#!/usr/bin/env bash
# =============================================================================
# tests/lib/harness.sh — the whole test framework for this repo.
#
# There is no pytest, no npm and no CI here (contract: ci.status, and
# unavailable_gates[unit-tests]). So this is plain bash and nothing else.
#
# Three rules it exists to enforce:
#
#   1. Every test drives code EXTRACTED FROM THE REAL SCRIPT, never a copy of
#      the logic written out again. A reimplementation tests the test.
#   2. Every extraction asserts its anchor matched EXACTLY ONCE. An anchor that
#      matches nothing is a HARNESS ERROR (exit 2), never a pass — the whole
#      point of these tests is that they cannot go quiet.
#   3. A test whose assertions cannot be made here is SKIPPED loudly and named,
#      never silently passed. Git Bash on the Windows workstation cannot hold
#      file modes (chmod 600 reads back 644), so every permission assertion
#      would pass vacuously. See tm_probe_modes.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================

# ─── locations ───────────────────────────────────────────────────────────────
TM_TESTS_DIR="${TM_TESTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TM_REPO_ROOT="${TM_REPO_ROOT:-$(cd "${TM_TESTS_DIR}/.." && pwd)}"

# The script under test. tests/mutate.sh points this at a MUTATED COPY held
# outside the repo, so a mutation control never edits a tracked file — there is
# no cp/restore dance to get wrong, and nothing to destroy if a run is killed.
tm_upgrade_sh() { echo "${TM_UPGRADE_SH:-${TM_REPO_ROOT}/install/upgrade-full.sh}"; }

# ─── output ──────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${TM_NO_COLOUR:-}" ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
    C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_OFF=''
fi

TM_FILE_NAME="$(basename "${0}")"

# tm_die — a HARNESS failure, not a test failure. Exit 2, distinct from 1, so a
# caller can tell "the code under test is wrong" from "the test could not run".
tm_die() {
    printf '%s\n' "${C_RED}${C_BLD}[HARNESS ERROR]${C_OFF} ${TM_FILE_NAME}: $*" >&2
    exit 2
}

tm_note() { printf '        %s\n' "$*"; }

# ─── extraction ──────────────────────────────────────────────────────────────
# Every extractor below counts its anchor and refuses on anything but exactly
# one match. A silent no-match is the failure mode these tests exist to prevent:
# it would leave the harness evaluating an empty string and reporting green.

_tm_count() {   # _tm_count <file> <ere>
    local n
    n="$(grep -cE -- "$2" "$1" 2>/dev/null || true)"
    [ -n "$n" ] || n=0
    echo "$n"
}

tm_require_anchor() {   # tm_require_anchor <file> <ere> <what>
    local f="$1" re="$2" what="$3" n
    [ -f "$f" ] || tm_die "no such file to extract from: $f"
    n="$(_tm_count "$f" "$re")"
    if [ "$n" -ne 1 ]; then
        tm_die "anchor for ${what} matched ${n} line(s) in $(basename "$f") (need exactly 1).
        Anchor: ${re}
        Either the construct was renamed/moved — update the anchor in this test —
        or it was DELETED, which is the regression this test exists to catch.
        Refusing to run: an extraction that matches nothing must never report a pass."
    fi
}

# tm_extract_func <file> <name> — a multi-line function whose closing brace is
# at column 0. Emits the whole definition, verbatim.
tm_extract_func() {
    local f="$1" name="$2"
    tm_require_anchor "$f" "^${name}\(\)[[:space:]]*\{" "function ${name}()"
    awk -v fn="$name" '
        !inside && $0 ~ "^" fn "\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^\}[[:space:]]*$/ { exit }
    ' "$f"
}

# tm_extract_line <file> <ere> — exactly one whole line.
tm_extract_line() {
    local f="$1" re="$2"
    tm_require_anchor "$f" "$re" "line /${re}/"
    grep -E -- "$re" "$f"
}

# tm_extract_between <file> <start-ere> <end-ere> — inclusive block. Both
# anchors are counted; the end anchor is deliberately placed BELOW the last
# line that matters, so deleting that line goes RED instead of failing
# extraction (a mutation that breaks its own extraction proves nothing).
tm_extract_between() {
    local f="$1" s="$2" e="$3" out
    tm_require_anchor "$f" "$s" "block start /${s}/"
    tm_require_anchor "$f" "$e" "block end /${e}/"
    # Anchors go through ENVIRON, NOT `awk -v`. `-v` performs escape-sequence
    # processing on the value, so an ERE like '^FE_DIR_MODE="\$\(stat ' arrives
    # at awk as '^FE_DIR_MODE="$(stat ' — an unescaped '(' and therefore an
    # invalid regexp. gawk made that fatal mid-extraction while
    # tm_require_anchor (which uses grep -E, no escape processing) had already
    # said the anchor was fine. The case then ran against EMPTY extracted code
    # and reported a plausible-looking assertion failure instead of a harness
    # error. Found 2026-08-30 on the first Linux run.
    out="$(TM_S="$s" TM_E="$e" awk '
        BEGIN { s = ENVIRON["TM_S"]; e = ENVIRON["TM_E"] }
        !on && $0 ~ s { on = 1; print; next }
        on && $0 ~ e  { print; exit }
        on            { print }
    ' "$f" 2>&1)" || {
        printf '%s\n' "$out" >&2
        tm_die "extraction failed for block /${s}/ .. /${e}/ in ${f}"
        return 2
    }
    # A regexp error can still leave awk exit 0 on some builds; empty output
    # from a block whose anchors both matched is impossible, so treat it as a
    # harness error rather than letting an assertion invent a verdict.
    if [[ -z "${out//[[:space:]]/}" ]]; then
        tm_die "extraction produced NOTHING for block /${s}/ .. /${e}/ in ${f} — anchors matched but the block is empty"
        return 2
    fi
    printf '%s\n' "$out"
}

# ─── capability detection ────────────────────────────────────────────────────
# THE point of this block. On Git Bash for Windows the filesystem cannot hold
# POSIX modes: chmod 600 reads back 644. Every mode assertion therefore passes
# no matter what the code does. A test that cannot fail is worse than no test,
# so anything that asserts a mode or an owner is SKIPPED here and said out loud.

tm_mode() {   # tm_mode <path> -> octal, or empty
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}
tm_owner() { stat -c '%U:%G' "$1" 2>/dev/null || true; }

# tm_probe_modes <dir> -> yes|no
# Measured, not assumed: set two different modes and read both back. Proven
# falsifiable by t00, which puts a no-op `chmod` on PATH and requires "no".
tm_probe_modes() {
    local d="$1" f m1 m2
    [ -n "${TM_FORCE_NO_MODES:-}" ] && { echo no; return 0; }
    f="${d}/.tm-modeprobe.$$"
    : > "$f" 2>/dev/null || { echo no; return 0; }
    chmod 600 "$f" 2>/dev/null || { rm -f "$f"; echo no; return 0; }
    m1="$(tm_mode "$f")"
    chmod 640 "$f" 2>/dev/null || { rm -f "$f"; echo no; return 0; }
    m2="$(tm_mode "$f")"
    rm -f "$f"
    if [ "$m1" = "600" ] && [ "$m2" = "640" ]; then echo yes; else echo no; fi
}

TM_WEB_USER="${TM_TEST_WEB_USER:-www-data}"

# tm_open_traversal <path> — mktemp -d makes 0700 directories, so a fake root
# under it is unreachable by www-data no matter what the file mode says, and an
# effective-access assertion would fail for a reason that has nothing to do
# with the code. Open o+x on the ancestors, stopping at the scratch parent.
tm_open_traversal() {
    local p="$1" top
    top="$(dirname "$(_tm_scratch)")"
    while [ -n "$p" ] && [ "$p" != "/" ] && [ "$p" != "$top" ]; do
        chmod o+x "$p" 2>/dev/null || true
        p="$(dirname "$p")"
    done
}

# tm_probe_chown <dir> -> yes|no  (root, and the web principal really exists,
# and the chown really sticks)
tm_probe_chown() {
    local d="$1" f o
    [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || { echo no; return 0; }
    id "$TM_WEB_USER" >/dev/null 2>&1 || { echo no; return 0; }
    f="${d}/.tm-chownprobe.$$"
    : > "$f" 2>/dev/null || { echo no; return 0; }
    chown "root:${TM_WEB_USER}" "$f" 2>/dev/null || { rm -f "$f"; echo no; return 0; }
    o="$(tm_owner "$f")"; rm -f "$f"
    [ "$o" = "root:${TM_WEB_USER}" ] && echo yes || echo no
}

# Created EAGERLY, at source time. Creating it lazily inside a command
# substitution put it in a subshell: the assignment was lost and the subshell's
# own EXIT trap deleted the directory the caller was about to use.
TM_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tm-tests.XXXXXX")" \
    || { echo "cannot create a scratch directory" >&2; exit 2; }
trap '[ -n "${TM_KEEP:-}" ] || rm -rf "$TM_SCRATCH"' EXIT
_tm_scratch() { echo "$TM_SCRATCH"; }

TM_CAP_MODES=""
TM_CAP_CHOWN=""
tm_caps() {
    [ -n "$TM_CAP_MODES" ] && return 0
    local s; s="$(_tm_scratch)"
    TM_CAP_MODES="$(tm_probe_modes "$s")"
    TM_CAP_CHOWN="$(tm_probe_chown "$s")"
}

# tm_unmet <csv-of-requirements> -> human list of what is missing (empty = ok)
tm_unmet() {
    tm_caps
    local reqs="$1" r out=""
    IFS=',' read -r -a _rr <<<"$reqs"
    for r in "${_rr[@]}"; do
        case "$r" in
            ''|none) ;;
            modes) [ "$TM_CAP_MODES" = yes ] || out="${out}${out:+, }a filesystem that holds POSIX modes" ;;
            chown) [ "$TM_CAP_CHOWN" = yes ] || out="${out}${out:+, }root on Linux with a '${TM_WEB_USER}' account" ;;
            sudo)  command -v sudo >/dev/null 2>&1 || out="${out}${out:+, }sudo" ;;
            *)     tm_die "unknown requirement '${r}'" ;;
        esac
    done
    echo "$out"
}

# ─── results ─────────────────────────────────────────────────────────────────
TM_PASS=0; TM_FAIL=0; TM_SKIP=0
TM_RESULTS="${TM_RESULTS:-}"

_tm_record() {   # _tm_record <status> <id> <reqs> <msg>
    [ -n "$TM_RESULTS" ] || return 0
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$TM_FILE_NAME" "$2" "$3" "$4" >> "$TM_RESULTS"
}

# ─── assertions (each one aborts its case) ───────────────────────────────────
_tm_afail() { printf '%s\n' "${C_RED}ASSERT${C_OFF} $*" >&2; exit 1; }

tm_assert_eq()   { [ "$1" = "$2" ] || _tm_afail "${3:-values differ}: expected [$1], got [$2]"; }
tm_assert_ne()   { [ "$1" != "$2" ] || _tm_afail "${3:-values equal}: both [$1]"; }
tm_assert_file() { [ -f "$1" ] || _tm_afail "${2:-expected a file}: $1"; }
tm_assert_nofile(){ [ ! -e "$1" ] || _tm_afail "${2:-expected NO such path}: $1"; }
tm_assert_dir()  { [ -d "$1" ] || _tm_afail "${2:-expected a directory}: $1"; }
tm_assert_grep() {   # tm_assert_grep <fixed-string> <file> [msg]
    grep -qF -- "$1" "$2" 2>/dev/null || _tm_afail "${3:-missing text}: [$1] not in $2"
}
tm_assert_nogrep() {
    grep -qF -- "$1" "$2" 2>/dev/null && _tm_afail "${3:-text should be absent}: [$1] found in $2" || true
}
tm_assert_mode() {   # tm_assert_mode <expected-octal> <path> [msg]
    local got; got="$(tm_mode "$2")"
    [ "$1" = "$got" ] || _tm_afail "${3:-wrong mode} on $2: expected ${1}, got ${got:-<unreadable>}"
}
tm_assert_owner() {
    local got; got="$(tm_owner "$2")"
    [ "$1" = "$got" ] || _tm_afail "${3:-wrong owner} on $2: expected ${1}, got ${got:-<unreadable>}"
}
tm_assert_rc() {   # tm_assert_rc <expected> <actual> [msg]
    [ "$1" = "$2" ] || _tm_afail "${3:-wrong exit code}: expected ${1}, got ${2}"
}
tm_assert_nonempty() { [ -n "$1" ] || _tm_afail "${2:-expected non-empty}"; }

# ─── case runner ─────────────────────────────────────────────────────────────
# tm_case <id> <requires-csv> <function>
tm_case() {
    local id="$1" reqs="$2" fn="$3" missing out rc
    missing="$(tm_unmet "$reqs")"
    if [ -n "$missing" ]; then
        TM_SKIP=$((TM_SKIP+1))
        _tm_record SKIP "$id" "$reqs" "needs $missing"
        printf '  %s  %-34s %s\n' "${C_YEL}SKIP${C_OFF}" "$id" "needs ${missing}"
        return 0
    fi
    TM_TMP="$(mktemp -d "$(_tm_scratch)/case.XXXXXX")"; export TM_TMP
    out="$(mktemp "$(_tm_scratch)/out.XXXXXX")"
    rc=0
    ( set +e; "$fn" ) >"$out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        TM_PASS=$((TM_PASS+1))
        _tm_record PASS "$id" "$reqs" ""
        printf '  %s  %s\n' "${C_GRN}PASS${C_OFF}" "$id"
    elif [ "$rc" -eq 2 ]; then
        # harness error inside the case — propagate, do not count as a test
        printf '  %s  %s\n' "${C_RED}ERROR${C_OFF}" "$id"
        sed 's/^/        /' "$out" >&2
        exit 2
    else
        TM_FAIL=$((TM_FAIL+1))
        _tm_record FAIL "$id" "$reqs" "$(head -1 "$out" | tr -d '\r')"
        printf '  %s  %s\n' "${C_RED}FAIL${C_OFF}" "$id"
        sed 's/^/        /' "$out"
    fi
    [ -n "${TM_KEEP:-}" ] || rm -rf "$TM_TMP"
}

tm_header() { printf '\n%s%s%s  %s\n' "$C_BLD" "$TM_FILE_NAME" "$C_OFF" "$*"; }

tm_finish() {
    printf '  ── %s: %d passed, %d failed, %d skipped\n' \
        "$TM_FILE_NAME" "$TM_PASS" "$TM_FAIL" "$TM_SKIP"
    [ "$TM_FAIL" -eq 0 ] || exit 1
    exit 0
}
