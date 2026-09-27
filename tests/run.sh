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

DEFAULT_SET=false
if [ "${#FILES[@]}" -eq 0 ]; then
    DEFAULT_SET=true
    while IFS= read -r f; do FILES+=("$f"); done < <(ls "${TM_TESTS_DIR}"/t[0-9]*.sh 2>/dev/null | sort)
fi
# Round 8 (gatekeeper): a run of NOTHING passed. The default set must be every
# tests/t*.sh in the tree and at least one file; the tally below then requires
# every file to have reported at least one case.
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "run.sh: no test files to run — refusing to report a pass for nothing" >&2; exit 2
fi
if [ "$DEFAULT_SET" = true ]; then
    TREE_N="$(find "$TM_TESTS_DIR" -maxdepth 1 -type f -name 't*.sh' | wc -l | tr -d ' ')"
    if [ "$TREE_N" -ne "${#FILES[@]}" ]; then
        echo "run.sh: the tree has ${TREE_N} tests/t*.sh file(s) but ${#FILES[@]} were selected to run" >&2; exit 2
    fi
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
    # The key is the operator's choice (TM_SSH_KEY); without it ssh uses its
    # own defaults and agent. No environment-specific key name is assumed.
    SSH_OPTS=(-o BatchMode=yes)
    [ -n "${TM_SSH_KEY:-}" ] && SSH_OPTS+=(-i "$TM_SSH_KEY")
    RDIR="/tmp/tm-tests-$(date +%Y%m%d-%H%M%S)"
    echo "${C_BLD}── shipping tests + install/upgrade-full.sh to ${REMOTE}:${RDIR}${C_OFF}"
    TAR="$(mktemp "${TMPDIR:-/tmp}/tm-tests.XXXXXX.tar")"
    # WHAT IS SHIPPED IS HEAD, the way CI sees it (v1.1.0). `git archive`
    # gives every tracked file — the cases read the docs, the gates, the
    # PPSM, the SBOM and the CHANGELOG as well as the code — with LF endings
    # already applied by .gitattributes (hazards[windows-clone-crlf]) and
    # without the export-ignored process records. A hand-picked subset of
    # paths went stale as soon as a new case read a new file (measured: five
    # false failures on the first v1.1.0 remote run). Commit before --remote;
    # uncommitted changes are NOT in the run, and it says so.
    DIRTY="$(git -C "$TM_REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null | wc -l)"
    [ "${DIRTY:-0}" -eq 0 ] || echo "${C_YEL}  NOTE: ${DIRTY} uncommitted change(s) to tracked files are NOT in this run — it tests HEAD $(git -C "$TM_REPO_ROOT" rev-parse --short HEAD).${C_OFF}"
    git -C "$TM_REPO_ROOT" archive --format=tar -o "$TAR" HEAD \
        || { echo "could not build the transfer tarball (git archive HEAD)" >&2; exit 2; }
    ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$RDIR'" || exit 2
    scp -q "${SSH_OPTS[@]}" "$TAR" "${REMOTE}:${RDIR}/t.tar" || exit 2
    rm -f "$TAR"
    # The extracted tree is made a git work tree again, as a CI clone is, for
    # the cases that ask git about it (t21). PYTHONDONTWRITEBYTECODE:
    # tm_python prefers the service's own venv on a host, and a root python
    # importing from it must not write .pyc files into it — this run is
    # read-only toward the installed product.
    ssh "${SSH_OPTS[@]}" "$REMOTE" \
        "cd '$RDIR' && tar -xf t.tar && rm -f t.tar && git init -q && git add -A && git -c user.name=tm-tests -c user.email=tm-tests@localhost commit -qm snapshot && sudo -n PYTHONDONTWRITEBYTECODE=1 TM_NO_COLOUR=1 bash tests/run.sh --strict"
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
# Round 8 (gatekeeper): the verdict used to be counted FROM that file, so
# TM_RESULTS_OUT=/dev/null counted 0 failures and 0 skips and bypassed
# --strict. The runner now always tallies into its OWN file and only COPIES it
# to TM_RESULTS_OUT at the end.
TM_RESULTS="$(mktemp "${TMPDIR:-/tmp}/tm-results.XXXXXX")" || { echo "run.sh: mktemp failed" >&2; exit 2; }
export TM_RESULTS
trap 'rm -f "$TM_RESULTS"' EXIT

echo "${C_BLD}Topic Manager test suite${C_OFF}"
echo "  script under test: $(basename "${TM_UPGRADE_SH:-${TM_REPO_ROOT}/install/upgrade-full.sh}")"
echo "  files:             ${#FILES[@]}"

ANY_FAIL=0; ANY_ERROR=0; RAN=0
for f in "${FILES[@]}"; do
    before="$(wc -l < "$TM_RESULTS" | tr -d ' ')"
    bash "$f"
    rc=$?
    RAN=$((RAN+1))
    after="$(wc -l < "$TM_RESULTS" | tr -d ' ')"
    if [ "$rc" -eq 0 ] && [ "$after" -le "$before" ]; then
        ANY_ERROR=1
        printf '  %sHARNESS ERROR%s in %s — it exited 0 and reported NO case\n' "$C_RED" "$C_OFF" "$(basename "$f")"
    fi
    # REG-0013 (v1.2.0): every record this file added must be a RECOGNISED
    # one — PASS/FAIL/SKIP, this file's own name, an id, five tab-separated
    # fields — and there must be at least one. A garbage line used to be
    # counted as "the file reported something" and then ignored by the tally,
    # so one real record beside it masked it.
    if [ "$after" -gt "$before" ]; then
        bad_recs="$(sed -n "$((before + 1)),${after}p" "$TM_RESULTS" | awk -F'\t' -v me="$(basename "$f")" '
            !(NF == 5 && ($1 == "PASS" || $1 == "FAIL" || $1 == "SKIP") && $2 == me && $3 ~ /^[A-Za-z0-9._-]+$/) { n++ }
            END { print n + 0 }')"
        good_recs=$(( after - before - bad_recs ))
        if [ "$bad_recs" -gt 0 ] || [ "$good_recs" -lt 1 ]; then
            ANY_ERROR=1
            printf '  %sHARNESS ERROR%s in %s — %d unrecognised result record(s), %d recognised\n' \
                "$C_RED" "$C_OFF" "$(basename "$f")" "$bad_recs" "$good_recs"
        fi
    fi
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
    echo "  Each line above names what it needed. The two usual reasons:"
    echo "    modes/chown  this host cannot hold POSIX modes, so the assertion"
    echo "                 would pass VACUOUSLY. Prove it on Linux:"
    echo "                     bash tests/run.sh --remote <user>@<linux-host>"
    echo "    node         the frontend cases. node is on the Windows"
    echo "                 workstation and NOT on the Linux host, so those run"
    echo "                 here and skip there. The two runs are complementary;"
    echo "                 neither alone covers the suite."
fi
echo "${C_BLD}══════════════════════════════════════════════════════════════${C_OFF}"

[ -z "${TM_RESULTS_OUT:-}" ] || cp -- "$TM_RESULTS" "$TM_RESULTS_OUT" 2>/dev/null || true
if [ "$RAN" -ne "${#FILES[@]}" ] || [ $((P + F + S)) -lt "$RAN" ]; then
    echo "  ${C_RED}run.sh: ${RAN} of ${#FILES[@]} file(s) ran and $((P + F + S)) case(s) were counted — no verdict${C_OFF}"
    exit 2
fi
if [ "$ANY_ERROR" -eq 1 ]; then exit 2; fi
if [ "$F" -gt 0 ] || [ "$ANY_FAIL" -eq 1 ]; then exit 1; fi
if [ "$STRICT" = true ] && [ "$S" -gt 0 ]; then
    echo "  ${C_RED}--strict: ${S} skipped case(s) count as failures.${C_OFF}"
    exit 1
fi
exit 0
