#!/usr/bin/env bash
# =============================================================================
# sca-check.sh — Software Composition Analysis gate
#
# Queries OSV.dev for every pin in requirements.txt, every entry pip installs
# from requirements.lock (read by tools/lib/lockparse.py, pip's rules) and the
# frontend Vue pin, and exits non-zero if any carries a known advisory.
#
# Why this exists: the repo's other four gates are syntax-only. A mutation
# control on 2026-08-30 (builder M16) put cryptography==44.0.2 back into
# requirements.txt — five advisories — and ALL FOUR GATES STAYED GREEN. The
# gate set could not see the hazard class the release existed to fix. This is
# that missing gate.
#
# v1.3.3 (REG-0068): that includes the venv's own pip. It was ensurepip's
# unpinned 24.0 (six advisories) and in no requirements file, so this gate
# never saw it; it is now a direct pin ("venv tooling") and a lock entry, and
# the installers hold the installed venv to exactly the lock.
#
# Usage:  bash tools/sca-check.sh            # gate mode, exits 1 on any vuln
#         bash tools/sca-check.sh --report   # list findings, always exits 0
#
# Requires network access to api.osv.dev. In an air-gapped context run it on
# the bundle-building host, not the target.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQ="${REPO_ROOT}/requirements.txt"
UPGRADE="${REPO_ROOT}/install/upgrade-full.sh"

REPORT_ONLY=false
[[ "${1:-}" == "--report" ]] && REPORT_ONLY=true

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

command -v curl >/dev/null || { echo "sca-check: curl is required" >&2; exit 3; }
PY="${PYTHON:-python3}"
"$PY" -c 'import json' >/dev/null 2>&1 || PY=python
"$PY" -c 'import json' >/dev/null 2>&1 || { echo "sca-check: python is required to read OSV answers" >&2; exit 3; }
[[ -f "$REQ" ]] || { echo "sca-check: ${REQ} not found" >&2; exit 3; }
# Round 8 (gatekeeper): with requirements.lock missing the gate used to scan
# only the direct pins and pass. The lock is what the installers install.
LOCK="${REPO_ROOT}/requirements.lock"
[[ -f "$LOCK" && -r "$LOCK" ]] || { echo "${RED}sca-check: ${LOCK} is missing or unreadable — the transitive packages cannot be checked; REFUSING to pass.${NC}" >&2; exit 3; }

# REG-0005 (v1.2.0) + round 11 (gatekeeper N1, TM-RL-002): the lock is read
# BEFORE the network, by tools/lib/lockparse.py — pip's rules, the same parser
# as the lock gate — never by a column-0 regex here. That regex queried an
# entry a comment had hidden from pip (pyasn1 0.6.4, CLEAN), skipped the
# indented one pip installs (pyasn1 0.4.8, four CVEs), and skipped a direct
# package whose LOCKED version drifted. Every entry is queried at the version
# PIP installs; the count of entries handled must equal the parser's count,
# not merely be > 0. --list-pins prints that set and stops (offline).
LOCKPARSE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lockparse.py"
[[ -f "$LOCKPARSE" ]] || { echo "${RED}sca-check: ${LOCKPARSE} is missing — cannot read the lock; REFUSING to pass.${NC}" >&2; exit 3; }
LOCK_ENTRIES="$("$PY" "$(cygpath -m "$LOCKPARSE" 2>/dev/null || printf '%s' "$LOCKPARSE")" "$(cygpath -m "$LOCK" 2>/dev/null || printf '%s' "$LOCK")")" || {
    echo "${RED}sca-check: requirements.lock does not parse as pip reads it (see above) — REFUSING to pass.${NC}" >&2; exit 3; }
LOCK_ENTRIES="$(tr -d '\r' <<<"$LOCK_ENTRIES")"
LOCK_PINS=(); LEXPECT=""
while IFS= read -r nv; do
    if [[ "$nv" =~ ^#entries\ ([0-9]+)$ ]]; then LEXPECT="${BASH_REMATCH[1]}"; continue; fi
    if [[ ! "$nv" =~ ^([A-Za-z0-9._-]+)==([^[:space:]]+)$ ]]; then
        echo "${RED}sca-check: unexpected line from the lock parser: ${nv:0:60} — REFUSING to pass.${NC}" >&2; exit 3
    fi
    LOCK_PINS+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}")
done <<<"$LOCK_ENTRIES"
LSEEN=${#LOCK_PINS[@]}
if [[ -z "$LEXPECT" || "$LSEEN" -ne "$LEXPECT" || "$LSEEN" -eq 0 ]]; then
    echo "${RED}sca-check: handled ${LSEEN} lock entries but the parser read ${LEXPECT:-none} — refusing to pass.${NC}" >&2
    exit 3
fi
if [[ "${1:-}" == "--list-pins" ]]; then
    printf '%s\n' "${LOCK_PINS[@]}"; exit 0
fi

# Fail loudly if OSV is unreachable. A gate that silently passes because the
# vulnerability database could not be reached is not a gate.
if ! curl -s --max-time 20 -o /dev/null -w '' \
     -X POST -d '{"package":{"ecosystem":"PyPI","name":"flask"},"version":"3.1.3"}' \
     https://api.osv.dev/v1/query; then
    echo "${RED}sca-check: cannot reach api.osv.dev — REFUSING to report a pass.${NC}" >&2
    echo "Run this on a networked host, or record an explicit waiver." >&2
    exit 3
fi

VULN=0; CLEAN=0; SKIPPED=0

# package_exists <ecosystem> <name> <version>
# OSV returns the byte-identical `{}` for "no known advisories" and for a
# package it has never heard of. So a TYPO defeats the whole gate: a pin of
# `cryptografy==44.0.2` reports CLEAN while the real cryptography 44.0.2 carries
# five advisories. Verified live against api.osv.dev on 2026-08-30.
# A clean OSV result is therefore only meaningful once we have independently
# confirmed that this exact name+version actually exists upstream.
package_exists() {
    local eco="$1" name="$2" ver="$3" url code
    case "$eco" in
        PyPI) url="https://pypi.org/pypi/${name}/${ver}/json" ;;
        npm)  url="https://registry.npmjs.org/${name}/${ver}" ;;
        *)    return 2 ;;   # unknown ecosystem: cannot confirm
    esac
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$url" 2>/dev/null)"
    [[ $? -ne 0 ]] && return 2
    case "$code" in
        200) return 0 ;;    # exists
        404) return 1 ;;    # does not exist — a typo, a yank, or a private name
        *)   return 2 ;;    # indeterminate
    esac
}

# osv_judge <n> — judge one OSV /v1/querybatch answer (stdin) for <n> queries.
# REG-0070 (v1.3.3, gatekeeper + Daybreak Blue F-03): the gate used to send one
# /v1/query per package and read `{}` — which is ALSO what an empty proxy page,
# a truncated reply or `{"next_page_token": ...}` with no vulns looks like — as
# CLEAN. One batch now carries every query, and only a WELL-FORMED answer for
# EVERY one of them is a verdict: a JSON object whose only key is "results",
# holding exactly <n> entries, each an object with no key but "vulns" (a list)
# and "next_page_token". Anything else prints one line, "BAD <why>", and every
# package is SKIPPED (exit 2). Otherwise <n> lines, in query order:
#   CLEAN              no vulns and no page token
#   VULN <id> <id>...  ANY entry in "vulns", whatever its ID prefix (round 8:
#                      a prefix allowlist read unknown databases as clean); an
#                      entry with no id still counts, as "(no-id)"
#   PAGE <token>       no vulns on this page, but OSV says there are more:
#                      followed by the caller, never read as clean
#   BAD <why>          this entry is malformed: that package is SKIPPED
osv_judge() {   # osv_judge <n>  (answer on stdin)
    "$PY" -c '
import json, sys
n = int(sys.argv[1])
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("BAD the answer is not JSON"); sys.exit(0)
if not isinstance(d, dict) or set(d) != {"results"}:
    print("BAD the answer is not {\"results\": [...]} (keys: %s)" % (",".join(sorted(d)) if isinstance(d, dict) else type(d).__name__)); sys.exit(0)
r = d["results"]
if not isinstance(r, list) or len(r) != n:
    print("BAD %s results for %d queries" % (len(r) if isinstance(r, list) else "no list of", n)); sys.exit(0)
for e in r:
    if not isinstance(e, dict) or any(k not in ("vulns", "next_page_token") for k in e):
        print("BAD a result is not {vulns, next_page_token}"); continue
    v, t = e.get("vulns", []), e.get("next_page_token")
    if not isinstance(v, list) or (t is not None and not (isinstance(t, str) and t)):
        print("BAD a result has a malformed vulns list or page token"); continue
    if v:
        print("VULN " + " ".join(sorted({(x.get("id") if isinstance(x, dict) else None) or "(no-id)" for x in v})))
    elif t:
        print("PAGE " + t)
    else:
        print("CLEAN")
' "$1" 2>/dev/null || echo "BAD the answer could not be judged"
}

# osv_batch <file of "eco<TAB>name<TAB>version<TAB>page-token" lines> — POST
# them as ONE /v1/querybatch; print osv_judge's lines. The transfer must
# succeed (curl's own exit status) and answer HTTP 200, or it is one BAD line.
osv_batch() {   # osv_batch <query-file>
    local n req resp rc code
    n="$(grep -c . "$1")"
    req="$("$PY" -c '
import json, sys
q = []
for line in open(sys.argv[1], encoding="utf-8"):
    eco, name, ver, tok = line.rstrip("\n").split("\t")
    e = {"package": {"ecosystem": eco, "name": name}, "version": ver}
    if tok:
        e["page_token"] = tok
    q.append(e)
print(json.dumps({"queries": q}))
' "$1")" || { echo "BAD the query could not be built"; return 0; }
    resp="$(curl -sS --max-time 60 -w '\n%{http_code}' -X POST -d "$req" https://api.osv.dev/v1/querybatch 2>/dev/null)"
    rc=$?
    [[ $rc -eq 0 ]] || { echo "BAD curl exit ${rc}"; return 0; }
    code="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
    [[ "$code" == 200 ]] || { echo "BAD HTTP ${code:-none}"; return 0; }
    osv_judge "$n" <<<"$resp"
}

# Two passes over the SAME section code (scan_sections): COLLECT=true records
# every query in order; the batch runs; the second pass prints each query's
# verdict in that order. A query the first pass did not record is a harness
# fault, never a verdict.
COLLECT=true; QI=0; Q_FILE="$(mktemp "${TMPDIR:-/tmp}/tm-sca.XXXXXX")" || exit 3
trap 'rm -f -- "$Q_FILE" "${Q_FILE}".*' EXIT
V_FILE="${Q_FILE}.v"
query_osv() {  # query_osv <ecosystem> <name> <version>
    local eco="$1" name="$2" ver="$3" verdict
    if [[ $COLLECT == true ]]; then
        printf '%s\t%s\t%s\t\n' "$eco" "$name" "$ver" >> "$Q_FILE"; return 0
    fi
    QI=$((QI+1))
    verdict="$(sed -n "${QI}p" "$V_FILE")"
    case "$verdict" in
        CLEAN) ;;
        VULN*)
            printf '  %-22s %-12s %bVULNERABLE%b  %s\n' "$name" "$ver" "$RED" "$NC" "${verdict#VULN }"
            VULN=$((VULN+1)); return 0 ;;
        PAGE*)
            printf '  %-22s %-12s %bSKIPPED%b  (OSV kept paginating with no advisory on any page)\n' "$name" "$ver" "$YELLOW" "$NC"
            SKIPPED=$((SKIPPED+1)); return 0 ;;
        *)  # an error object, an HTML page, a half-received body, no verdict at all: never clean
            printf '  %-22s %-12s %bSKIPPED%b  (OSV: %s)\n' "$name" "$ver" "$YELLOW" "$NC" "${verdict#BAD }"
            SKIPPED=$((SKIPPED+1)); return 0 ;;
    esac

    # Clean per OSV — but only trust that if the package genuinely exists.
    package_exists "$eco" "$name" "$ver"
    case $? in
        0) printf '  %-22s %-12s %bCLEAN%b\n' "$name" "$ver" "$GREEN" "$NC"
           CLEAN=$((CLEAN+1)) ;;
        1) printf '  %-22s %-12s %bNOT FOUND%b  (no such %s package/version — typo or yanked;\n' \
               "$name" "$ver" "$RED" "$NC" "$eco"
           printf '  %-22s %-12s             OSV reports "clean" for names it does not know)\n' "" ""
           VULN=$((VULN+1)) ;;
        *) printf '  %-22s %-12s %bSKIPPED%b  (could not confirm the package exists)\n' \
               "$name" "$ver" "$YELLOW" "$NC"
           SKIPPED=$((SKIPPED+1)) ;;
    esac
}

lk_norm() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[-_.]+/-/g'; }
scan_sections() {
    echo "── Python pins (requirements.txt) ───────────────────────────────"
    PINS=0
    QUERIED=""      # "normalised-name==version" per line, already queried (bash 3 has no assoc arrays)
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(tr -d '[:space:]' <<<"$line")"
        [[ -z "$line" ]] && continue
        if [[ "$line" != *"=="* ]]; then
            printf '  %-22s %-12s %bNOT PINNED%b  (== required for SCA)\n' "$line" "-" "$RED" "$NC"
            VULN=$((VULN+1)); continue
        fi
        query_osv PyPI "${line%%==*}" "${line##*==}"
        QUERIED+="$(lk_norm "${line%%==*}")==${line##*==}"$'\n'
        PINS=$((PINS+1))
    done < "$REQ"

    if [[ $PINS -eq 0 ]]; then
        echo "${RED}sca-check: no pins parsed from requirements.txt — refusing to pass.${NC}" >&2
        exit 3
    fi

    # Round 2: the TRANSITIVE dependencies too. requirements.lock carries every
    # package the installers actually install (Jinja2, MarkupSafe, cffi, ...),
    # as read above by lockparse.py. A direct pin is skipped only when
    # requirements.txt already queried that SAME version.
    echo
    echo "── Locked packages (requirements.lock — what pip installs) ──────"
    for pair in "${LOCK_PINS[@]}"; do
        n="${pair%% *}"; v="${pair#* }"
        grep -Fqx -- "$(lk_norm "$n")==${v}" <<<"$QUERIED" && continue     # same version queried above
        query_osv PyPI "$n" "$v"
    done
    echo "  ${LSEEN} of ${LEXPECT} requirements.lock entries checked at the version pip installs"

    echo
    echo "── Frontend pin (install/upgrade-full.sh) ───────────────────────"
    if [[ -f "$UPGRADE" ]]; then
        VUE_VER="$(grep -m1 -oP '^VUE_VERSION="\K[^"]+' "$UPGRADE" || true)"
        if [[ -n "$VUE_VER" ]]; then
            query_osv npm vue "$VUE_VER"
        else
            echo "  ${YELLOW}could not read VUE_VERSION from ${UPGRADE}${NC}"; SKIPPED=$((SKIPPED+1))
        fi
    else
        echo "  ${YELLOW}${UPGRADE} not found${NC}"; SKIPPED=$((SKIPPED+1))
    fi
}

# Pass 1: record every query, in order (nothing printed, nothing counted).
scan_sections > /dev/null
NQ="$(grep -c . "$Q_FILE")"
[[ "$NQ" -gt 0 ]] || { echo "${RED}sca-check: no query was recorded — refusing to pass.${NC}" >&2; exit 3; }
osv_batch "$Q_FILE" > "$V_FILE"
# One BAD line for the whole batch (transfer, HTTP status or envelope): every
# package gets it, so every package is SKIPPED.
if [[ "$(grep -c '' "$V_FILE")" -ne "$NQ" ]]; then
    _why="$(sed -n 1p "$V_FILE")"; : > "$V_FILE"
    for ((_i = 0; _i < NQ; _i++)); do printf '%s\n' "${_why:-BAD no answer}" >> "$V_FILE"; done
fi
# PAGINATION, explicitly: a result with an advisory is already a finding. A
# result with NO advisory but a next_page_token is followed, that package
# alone, with its page_token, up to OSV_MAX_PAGES more pages; one still
# paginating after that is SKIPPED (exit 2), never clean.
OSV_MAX_PAGES=5
for ((_round = 1; _round <= OSV_MAX_PAGES; _round++)); do
    grep -q '^PAGE ' "$V_FILE" || break
    : > "${Q_FILE}.p"; _idx=""
    _n=0
    while IFS= read -r _v; do
        _n=$((_n+1))
        [[ "$_v" == "PAGE "* ]] || continue
        _q="$(sed -n "${_n}p" "$Q_FILE")"
        printf '%s%s\n' "${_q%$'\t'*}"$'\t' "${_v#PAGE }" >> "${Q_FILE}.p"
        _idx="${_idx} ${_n}"
    done < "$V_FILE"
    osv_batch "${Q_FILE}.p" > "${Q_FILE}.pv"
    _np="$(grep -c . "${Q_FILE}.p")"
    if [[ "$(grep -c '' "${Q_FILE}.pv")" -ne "$_np" ]]; then
        _why="$(sed -n 1p "${Q_FILE}.pv")"; : > "${Q_FILE}.pv"
        for ((_i = 0; _i < _np; _i++)); do printf '%s\n' "${_why:-BAD no answer}" >> "${Q_FILE}.pv"; done
    fi
    # Put each follow-up verdict back at its query's line.
    "$PY" -c '
import sys
v = open(sys.argv[1]).read().split("\n")[:-1]
pv = open(sys.argv[2]).read().split("\n")[:-1]
for i, line in zip(sys.argv[3].split(), pv):
    v[int(i) - 1] = line
open(sys.argv[1], "w").write("".join(x + "\n" for x in v))
' "$V_FILE" "${Q_FILE}.pv" "$_idx" || { echo "${RED}sca-check: could not merge OSV pages — refusing to pass.${NC}" >&2; exit 3; }
done

# Pass 2: the same sections, each query printed with its verdict.
VULN=0; CLEAN=0; SKIPPED=0; COLLECT=false; QI=0
scan_sections
if [[ $QI -ne $NQ ]]; then
    echo "${RED}sca-check: ${QI} verdicts printed for ${NQ} queries — refusing to pass.${NC}" >&2; exit 3
fi
echo
echo "─────────────────────────────────────────────────────────────────"
printf 'clean %d · vulnerable %d · skipped %d\n' "$CLEAN" "$VULN" "$SKIPPED"

if [[ $REPORT_ONLY == true ]]; then
    exit 0
fi
if [[ $SKIPPED -gt 0 ]]; then
    echo "${RED}sca-check: ${SKIPPED} package(s) could not be checked — treating as FAIL.${NC}" >&2
    exit 2
fi
if [[ $VULN -gt 0 ]]; then
    echo "${RED}sca-check: ${VULN} pinned package(s) carry known advisories.${NC}" >&2
    exit 1
fi
echo "${GREEN}sca-check: all pins clean.${NC}"
exit 0
