#!/usr/bin/env bash
# =============================================================================
# tests/run.sh — the entire test suite for Topic Manager.
#
#   bash tests/run.sh                  run everything runnable here
#   bash tests/run.sh --strict         a SKIP is a failure (use on Linux/CI)
#   bash tests/run.sh --list           list cases and what each one needs
#   bash tests/run.sh --remote U@H     ship the tree to a Linux host and run
#                                      there under sudo, --strict
#   bash tests/run.sh tests/t02-*.sh   run named files only
#
# WHERE THESE CAN RUN
#   Git Bash on Windows CANNOT hold POSIX file modes — `chmod 600` reads back
#   644 — so every permission assertion would pass no matter what the code did.
#   Those cases are therefore SKIPPED here and named individually, with the
#   command to run them for real. They are not silently green. A test that
#   cannot fail is worse than no test.
#
# Exit codes:  0 = all runnable cases passed   1 = a test failed
#              2 = the harness could not run (a missing extraction anchor is
#                  a harness error, never a pass)
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

TM_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TM_REPO_ROOT="$(cd "${TM_TESTS_DIR}/.." && pwd)"
export TM_TESTS_DIR TM_REPO_ROOT

STRICT=false; LIST=false; REMOTE=""
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --strict)  STRICT=true ;;
        --list)    LIST=true ;;
        --remote)  shift; REMOTE="${1:-}" ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)        echo "unknown option: $1" >&2; exit 2 ;;
        *)         FILES+=("$1") ;;
    esac
    shift
done

if [ "${#FILES[@]}" -eq 0 ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(ls "${TM_TESTS_DIR}"/t[0-9]*.sh | sort)
fi

if [ -t 1 ] && [ -z "${TM_NO_COLOUR:-}" ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
    C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_OFF=''
fi

# ─── --remote: get the skipped cases actually run ────────────────────────────
if [ -n "$REMOTE" ]; then
    command -v ssh  >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 2; }
    command -v scp  >/dev/null 2>&1 || { echo "scp not found" >&2; exit 2; }
    RKEY="${TM_SSH_KEY:-$HOME/.ssh/claude_admin}"
    RDIR="/tmp/tm-tests-$(date +%Y%m%d-%H%M%S)"
    echo "${C_BLD}── shipping tests + install/upgrade-full.sh to ${REMOTE}:${RDIR}${C_OFF}"
    TAR="$(mktemp "${TMPDIR:-/tmp}/tm-tests.XXXXXX.tar")"
    ( cd "$TM_REPO_ROOT" && tar -cf "$TAR" tests install/upgrade-full.sh ) \
        || { echo "could not build the transfer tarball" >&2; exit 2; }
    ssh -i "$RKEY" -o BatchMode=yes "$REMOTE" "mkdir -p '$RDIR'" || exit 2
    scp -q -i "$RKEY" -o BatchMode=yes "$TAR" "${REMOTE}:${RDIR}/t.tar" || exit 2
    rm -f "$TAR"
    # CRLF: this repo is cloned on Windows (contract hazards[windows-clone-crlf]).
    # A \r on a shebang line makes every script "not found" on Linux.
    ssh -i "$RKEY" -o BatchMode=yes "$REMOTE" \
        "cd '$RDIR' && tar -xf t.tar && find tests install -type f -exec sed -i 's/\r\$//' {} + && sudo -n TM_NO_COLOUR=1 bash tests/run.sh --strict"
    rc=$?
    echo "${C_BLD}── remote run exit ${rc}; tree left at ${REMOTE}:${RDIR}${C_OFF}"
    exit $rc
fi

# ─── list mode ───────────────────────────────────────────────────────────────
if [ "$LIST" = true ]; then
    for f in "${FILES[@]}"; do
        printf '%s%s%s\n' "$C_BLD" "$(basename "$f")" "$C_OFF"
        grep -E '^[[:space:]]*tm_case ' "$f" | sed -E 's/^[[:space:]]*tm_case[[:space:]]+/  /' \
            | awk '{ printf "  %-34s requires: %s\n", $1, $2 }' | tr -d '"'
    done
    exit 0
fi

# ─── run ─────────────────────────────────────────────────────────────────────
# TM_RESULTS_OUT lets tests/mutate.sh read the per-case verdicts, so a mutation
# can be told apart from a mutation whose covering cases were all SKIPPED.
TM_RESULTS="${TM_RESULTS_OUT:-$(mktemp "${TMPDIR:-/tmp}/tm-results.XXXXXX")}"
: > "$TM_RESULTS"
export TM_RESULTS
[ -n "${TM_RESULTS_OUT:-}" ] || trap 'rm -f "$TM_RESULTS"' EXIT

echo "${C_BLD}Topic Manager test suite${C_OFF}"
echo "  script under test: $(basename "${TM_UPGRADE_SH:-${TM_REPO_ROOT}/install/upgrade-full.sh}")"
echo "  files:             ${#FILES[@]}"

ANY_FAIL=0; ANY_ERROR=0
for f in "${FILES[@]}"; do
    bash "$f"
    rc=$?
    case "$rc" in
        0) ;;
        1) ANY_FAIL=1 ;;
        *) ANY_ERROR=1
           printf '  %sHARNESS ERROR%s in %s (exit %d) — no result can be trusted from this file\n' \
               "$C_RED" "$C_OFF" "$(basename "$f")" "$rc" ;;
    esac
done

# ─── summary ─────────────────────────────────────────────────────────────────
P=$(grep -c '^PASS' "$TM_RESULTS" 2>/dev/null || true); P=${P:-0}
F=$(grep -c '^FAIL' "$TM_RESULTS" 2>/dev/null || true); F=${F:-0}
S=$(grep -c '^SKIP' "$TM_RESULTS" 2>/dev/null || true); S=${S:-0}

echo
echo "${C_BLD}══════════════════════════════════════════════════════════════${C_OFF}"
printf '  %d passed   %d failed   %d skipped\n' "$P" "$F" "$S"

if [ "$F" -gt 0 ]; then
    echo "  ${C_RED}${C_BLD}FAILED CASES${C_OFF}"
    grep '^FAIL' "$TM_RESULTS" | awk -F'\t' '{ printf "    %-22s %-30s %s\n", $2, $3, $5 }'
fi

if [ "$S" -gt 0 ]; then
    echo
    echo "  ${C_YEL}${C_BLD}╔══════════════════════════════════════════════════════════╗${C_OFF}"
    echo "  ${C_YEL}${C_BLD}║  ${S} CASE(S) DID NOT RUN. THEY ARE NOT PASSES.               ${C_OFF}"
    echo "  ${C_YEL}${C_BLD}╚══════════════════════════════════════════════════════════╝${C_OFF}"
    grep '^SKIP' "$TM_RESULTS" | awk -F'\t' '{ printf "    %-22s %-30s %s\n", $2, $3, $5 }'
    echo
    echo "  This host cannot hold POSIX modes/ownership, so those assertions"
    echo "  would pass VACUOUSLY. Run them for real on a Linux host:"
    echo "      bash tests/run.sh --remote claude_admin@<linux-host>"
    echo "  (--strict there; a skip on that host is a failure.)"
fi
echo "${C_BLD}══════════════════════════════════════════════════════════════${C_OFF}"

if [ "$ANY_ERROR" -eq 1 ]; then exit 2; fi
if [ "$F" -gt 0 ] || [ "$ANY_FAIL" -eq 1 ]; then exit 1; fi
if [ "$STRICT" = true ] && [ "$S" -gt 0 ]; then
    echo "  ${C_RED}--strict: ${S} skipped case(s) count as failures.${C_OFF}"
    exit 1
fi
exit 0
