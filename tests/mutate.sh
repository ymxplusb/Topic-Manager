#!/usr/bin/env bash
# =============================================================================
# tests/mutate.sh — mechanical mutation controls for install/upgrade-full.sh.
#
#   bash tests/mutate.sh                 run every control in mutations.txt
#   bash tests/mutate.sh M06 M23         run named controls only
#   bash tests/mutate.sh --list          list them
#   bash tests/mutate.sh --remote U@H    run them on a Linux host (the mode
#                                        controls cannot be proven anywhere else)
#
# READ THE SURVIVORS. A killed mutant tells you nothing you did not already
# believe. A survivor is a mechanical change to the code that the suite did not
# notice, and it is a finding about the TEST.
#
# THE SCRIPT UNDER TEST IS NEVER MODIFIED. Each control writes a mutated COPY
# into a scratch directory outside the repo and points the suite at it with
# TM_UPGRADE_SH. There is no cp/restore dance to get wrong, no `git checkout`
# anywhere near this, and a run killed halfway leaves the tree untouched. The
# target's sha256 is compared before and after the whole run anyway.
#
# Exit codes:
#   0  every control killed (documented equivalents aside)
#   1  at least one control SURVIVED               <- a finding
#   2  the harness could not run: the baseline was already red, an anchor did
#      not match exactly once, or a control's covering cases were all SKIPPED
#      on this host. An unproven control is NOT a pass.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

TM_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TM_REPO_ROOT="$(cd "${TM_TESTS_DIR}/.." && pwd)"
MUTFILE="${TM_TESTS_DIR}/mutations.txt"

# Two scripts are under test as of v1.0.4. A control names one with
# TARGET|<key>; the default is the upgrade script, so every existing record is
# unchanged. The KEY, not a path, so mutations.txt cannot point the harness at
# an arbitrary file.
declare -A TARGET_PATH=(
  [upgrade]="${TM_UPGRADE_SH:-${TM_REPO_ROOT}/install/upgrade-full.sh}"
  [install]="${TM_INSTALL_SH:-${TM_REPO_ROOT}/install.sh}"
)
declare -A TARGET_ENV=(
  [upgrade]="TM_UPGRADE_SH"
  [install]="TM_INSTALL_SH"
)
TARGET="${TARGET_PATH[upgrade]}"

if [ -t 1 ] && [ -z "${TM_NO_COLOUR:-}" ]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
    C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_OFF=''
fi

LIST=false; REMOTE=""; WANT=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list)   LIST=true ;;
        --remote) shift; REMOTE="${1:-}" ;;
        -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *)  WANT+=("$1") ;;
    esac
    shift
done

if [ -n "$REMOTE" ]; then
    RKEY="${TM_SSH_KEY:-$HOME/.ssh/claude_admin}"
    RDIR="/tmp/tm-mutate-$(date +%Y%m%d-%H%M%S)"
    TAR="$(mktemp "${TMPDIR:-/tmp}/tm-mut.XXXXXX.tar")"
    # Both scripts under test, plus the tree the covering cases import.
    ( cd "$TM_REPO_ROOT" && tar -cf "$TAR" tests tm app index.html config systemd install.sh         install/upgrade-full.sh install/polkit ) || exit 2
    ssh -i "$RKEY" -o BatchMode=yes "$REMOTE" "mkdir -p '$RDIR'" || exit 2
    scp -q -i "$RKEY" -o BatchMode=yes "$TAR" "${REMOTE}:${RDIR}/t.tar" || exit 2
    rm -f "$TAR"
    ssh -i "$RKEY" -o BatchMode=yes "$REMOTE" \
        "cd '$RDIR' && tar -xf t.tar && find tests install tm app config systemd install.sh index.html -type f -exec sed -i 's/\r\$//' {} + && sudo -n TM_NO_COLOUR=1 bash tests/mutate.sh ${WANT[*]:-}"
    rc=$?
    echo "── remote mutation run exit ${rc}; tree left at ${REMOTE}:${RDIR}"
    exit $rc
fi

[ -f "$MUTFILE" ] || { echo "no mutations.txt at $MUTFILE" >&2; exit 2; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/tm-mutate.XXXXXX")" || exit 2
trap '[ -n "${TM_KEEP:-}" ] || rm -rf "$SCRATCH"' EXIT

_sha() { sha256sum "$1" 2>/dev/null | cut -d" " -f1; }
declare -A SHA_BEFORE=()
for k in "${!TARGET_PATH[@]}"; do
    [ -f "${TARGET_PATH[$k]}" ] || { echo "no target at ${TARGET_PATH[$k]}" >&2; exit 2; }
    SHA_BEFORE[$k]="$(_sha "${TARGET_PATH[$k]}")"
done

# ─── parse mutations.txt ─────────────────────────────────────────────────────
# Records are written out as three files per id: .meta, .anchor, .replace
IDS=()
_parse() {
    local id="" line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            '--- '*)
                id="${line#--- }"
                IDS+=("$id")
                : > "${SCRATCH}/${id}.anchor"
                : > "${SCRATCH}/${id}.replace"
                : > "${SCRATCH}/${id}.meta"
                continue ;;
            '#'*|'') continue ;;
        esac
        [ -n "$id" ] || continue
        key="${line%%|*}"; val="${line#*|}"
        case "$key" in
            ANCHOR)  printf '%s\n' "$val" >> "${SCRATCH}/${id}.anchor" ;;
            REPLACE) printf '%s\n' "$val" >> "${SCRATCH}/${id}.replace" ;;
            DESC|TESTS|EQUIV|TARGET) printf '%s=%s\n' "$key" "$val" >> "${SCRATCH}/${id}.meta" ;;
            *) echo "mutations.txt: unknown key '${key}' in ${id}" >&2; exit 2 ;;
        esac
    done < "$MUTFILE"
}
_parse

_meta() { grep -m1 "^$2=" "${SCRATCH}/${1}.meta" 2>/dev/null | cut -d= -f2- ; }

if [ "$LIST" = true ]; then
    for id in "${IDS[@]}"; do printf '%-5s %s\n' "$id" "$(_meta "$id" DESC)"; done
    exit 0
fi

if [ "${#WANT[@]}" -gt 0 ]; then
    SEL=()
    for w in "${WANT[@]}"; do
        found=false
        for id in "${IDS[@]}"; do [ "$id" = "$w" ] && { SEL+=("$id"); found=true; }; done
        [ "$found" = true ] || { echo "no such control: $w" >&2; exit 2; }
    done
    IDS=("${SEL[@]}")
fi

# ─── apply one mutation to a COPY, exactly once ──────────────────────────────
# Emits the match count on stdout. Anything but 1 is an ABORTED control: a
# mutation that did not apply would run the tests against unmodified code and
# report a pass it did not earn.
_mutate_copy() {   # _mutate_copy <target> <anchor-file> <replace-file> <out>
    local cnt="${SCRATCH}/.count"
    awk -v af="$2" -v rf="$3" -v cf="$cnt" '
        BEGIN {
            an = 0; while ((getline l < af) > 0) { sub(/\r$/, "", l); A[++an] = l }
            rn = 0; while ((getline l < rf) > 0) { sub(/\r$/, "", l); R[++rn] = l }
        }
        { sub(/\r$/, ""); L[NR] = $0 }
        END {
            n = NR; count = 0; pos = 0
            for (i = 1; i <= n - an + 1; i++) {
                ok = 1
                for (j = 1; j <= an; j++) if (L[i + j - 1] != A[j]) { ok = 0; break }
                if (ok) { count++; pos = i }
            }
            if (count == 1) {
                for (i = 1; i <= n; i++) {
                    if (i == pos) { for (j = 1; j <= rn; j++) print R[j]; i += an - 1 }
                    else print L[i]
                }
            }
            printf "%d\n", count > cf
        }
    ' "$1" > "$4"
    cat "$cnt"
}

# ─── baseline: the suite must be GREEN before any mutation means anything ────
COVERING=""
for id in "${IDS[@]}"; do COVERING="${COVERING} $(_meta "$id" TESTS)"; done
BASE_FILES=()
for t in $(printf '%s\n' $COVERING | sort -u); do
    [ -f "${TM_TESTS_DIR}/${t}" ] || { echo "mutations.txt names a test file that does not exist: ${t}" >&2; exit 2; }
    BASE_FILES+=("${TM_TESTS_DIR}/${t}")
done

echo "${C_BLD}Mutation controls — ${#IDS[@]} control(s) over $(basename "$TARGET")${C_OFF}"
echo "  the repo file is NEVER modified; each control runs against a copy in ${SCRATCH}"
echo
echo "${C_BLD}── baseline (unmutated)${C_OFF}"
BASE_RES="${SCRATCH}/baseline.results"
TM_RESULTS_OUT="$BASE_RES" TM_NO_COLOUR=1 bash "${TM_TESTS_DIR}/run.sh" "${BASE_FILES[@]}" \
    > "${SCRATCH}/baseline.log" 2>&1
brc=$?
BASE_PASS=$(grep -c '^PASS' "$BASE_RES" 2>/dev/null || true); BASE_PASS=${BASE_PASS:-0}
BASE_SKIP=$(grep -c '^SKIP' "$BASE_RES" 2>/dev/null || true); BASE_SKIP=${BASE_SKIP:-0}
printf '  %d passed, %d skipped (exit %d)\n' "$BASE_PASS" "$BASE_SKIP" "$brc"
if [ "$brc" -ne 0 ]; then
    echo "${C_RED}  The suite is already RED. A mutation control means nothing against a red baseline.${C_OFF}"
    sed 's/^/    /' "${SCRATCH}/baseline.log"
    exit 2
fi

# Which cases could actually run here — used to tell a survivor apart from a
# control this host was never able to prove.
_ran_cases() { grep -E '^(PASS|FAIL)' "$1" | awk -F'\t' '{print $2"\t"$3}'; }

# ─── run the controls ────────────────────────────────────────────────────────
echo
KILLED=0; SURVIVED=0; UNPROVEN=0; ABORTED=0; EQUIV_OK=0
REPORT="${SCRATCH}/report"; : > "$REPORT"

for id in "${IDS[@]}"; do
    desc="$(_meta "$id" DESC)"
    tests="$(_meta "$id" TESTS)"
    equiv="$(_meta "$id" EQUIV)"
    [ -n "$tests" ] || { echo "${id}: no TESTS declared" >&2; exit 2; }

    tkey="$(_meta "$id" TARGET)"; tkey="${tkey:-upgrade}"
    tpath="${TARGET_PATH[$tkey]:-}"
    tenv="${TARGET_ENV[$tkey]:-}"
    if [ -z "$tpath" ]; then
        echo "${id}: unknown TARGET '${tkey}' (known: ${!TARGET_PATH[*]})" >&2; exit 2
    fi
    mutant="${SCRATCH}/${id}-$(basename "$tpath")"
    n="$(_mutate_copy "$tpath" "${SCRATCH}/${id}.anchor" "${SCRATCH}/${id}.replace" "$mutant")"
    if [ "$n" != "1" ]; then
        ABORTED=$((ABORTED+1))
        printf '  %-5s %s%-10s%s %s\n' "$id" "$C_RED" "ABORTED" "$C_OFF" "$desc" | tee -a "$REPORT"
        printf '        anchor matched %s time(s), need exactly 1 — nothing was mutated, so this\n' "$n" | tee -a "$REPORT"
        printf '        control proves NOTHING. The source moved; update the anchor.\n' | tee -a "$REPORT"
        continue
    fi

    files=()
    for t in $tests; do files+=("${TM_TESTS_DIR}/${t}"); done
    res="${SCRATCH}/${id}.results"
    env "${tenv}=${mutant}" TM_RESULTS_OUT="$res" TM_NO_COLOUR=1 \
        bash "${TM_TESTS_DIR}/run.sh" "${files[@]}" > "${SCRATCH}/${id}.log" 2>&1
    rc=$?
    nf=$(grep -c '^FAIL' "$res" 2>/dev/null || true); nf=${nf:-0}
    ns=$(grep -c '^SKIP' "$res" 2>/dev/null || true); ns=${ns:-0}

    if [ "$rc" -eq 2 ]; then
        ABORTED=$((ABORTED+1))
        printf '  %-5s %s%-10s%s %s\n' "$id" "$C_RED" "ABORTED" "$C_OFF" "$desc" | tee -a "$REPORT"
        printf '        the mutated copy broke an extraction anchor — no verdict is available\n' | tee -a "$REPORT"
        sed 's/^/        /' "${SCRATCH}/${id}.log" | grep -i 'harness error' | head -3 | tee -a "$REPORT"
    elif [ "$nf" -gt 0 ]; then
        KILLED=$((KILLED+1))
        printf '  %-5s %s%-10s%s %s  (%d case%s)\n' "$id" "$C_GRN" "RED" "$C_OFF" "$desc" "$nf" "$([ "$nf" -eq 1 ] || echo s)" | tee -a "$REPORT"
        grep '^FAIL' "$res" | awk -F'\t' '{printf "          - %s\n", $3}' | tee -a "$REPORT"
    elif [ "$equiv" = "yes" ]; then
        EQUIV_OK=$((EQUIV_OK+1))
        printf '  %-5s %s%-10s%s %s\n' "$id" "$C_YEL" "SURVIVED" "$C_OFF" "$desc" | tee -a "$REPORT"
        printf '        DOCUMENTED EQUIVALENT — the change is self-consistent and has no\n' | tee -a "$REPORT"
        printf '        observable consequence. Recorded, not a finding.\n' | tee -a "$REPORT"
    elif [ "$ns" -gt 0 ]; then
        UNPROVEN=$((UNPROVEN+1))
        printf '  %-5s %s%-10s%s %s\n' "$id" "$C_YEL" "UNPROVEN" "$C_OFF" "$desc" | tee -a "$REPORT"
        printf '        every covering case was SKIPPED on this host (%d of them). This control\n' "$ns" | tee -a "$REPORT"
        printf '        was NOT run. Re-run on Linux:  bash tests/mutate.sh --remote U@H\n' | tee -a "$REPORT"
    else
        SURVIVED=$((SURVIVED+1))
        printf '  %-5s %s%-10s%s %s\n' "$id" "$C_RED$C_BLD" "SURVIVED" "$C_OFF" "$desc" | tee -a "$REPORT"
        printf '        ** FINDING ** the suite did not notice this change. That is a gap in the\n' | tee -a "$REPORT"
        printf '        TEST, not in the mutation. Close it, then re-run this control.\n' | tee -a "$REPORT"
    fi
done

# ─── the target must be byte-identical to what we started with ───────────────
echo
for k in "${!TARGET_PATH[@]}"; do
    after="$(_sha "${TARGET_PATH[$k]}")"
    if [ "${SHA_BEFORE[$k]}" != "$after" ]; then
        echo "${C_RED}${C_BLD}A TARGET FILE CHANGED DURING THIS RUN: ${TARGET_PATH[$k]}${C_OFF}"
        echo "  before: ${SHA_BEFORE[$k]}"
        echo "  after:  ${after}"
        echo "  This harness never writes to it. Either something else edited it, or"
        echo "  a control leaked. Do not trust the results above."
        exit 2
    fi
    echo "  ${k} target sha256 unchanged: ${SHA_BEFORE[$k]}"
done

echo
printf '%sMUTATION CONTROLS: %d run — %d killed, %d SURVIVED, %d unproven here, %d aborted, %d documented-equivalent%s\n' \
    "$C_BLD" "${#IDS[@]}" "$KILLED" "$SURVIVED" "$UNPROVEN" "$ABORTED" "$EQUIV_OK" "$C_OFF"

if [ "$ABORTED" -gt 0 ]; then exit 2; fi
if [ "$SURVIVED" -gt 0 ]; then exit 1; fi
if [ "$UNPROVEN" -gt 0 ]; then
    echo "  ${C_YEL}${UNPROVEN} control(s) could not be proven on this host — that is not a pass.${C_OFF}"
    exit 2
fi
exit 0
