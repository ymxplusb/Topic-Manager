#!/usr/bin/env bash
# =============================================================================
# sca-check.sh — Software Composition Analysis gate
#
# Queries OSV.dev for every pin in requirements.txt and for the frontend Vue
# pin, and exits non-zero if any pinned version carries a known advisory.
#
# Why this exists: the repo's other four gates are syntax-only. A mutation
# control on 2026-08-30 (builder M16) put cryptography==44.0.2 back into
# requirements.txt — five advisories — and ALL FOUR GATES STAYED GREEN. The
# gate set could not see the hazard class the release existed to fix. This is
# that missing gate.
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
[[ -f "$REQ" ]] || { echo "sca-check: ${REQ} not found" >&2; exit 3; }

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

query_osv() {  # query_osv <ecosystem> <name> <version>
    local eco="$1" name="$2" ver="$3" resp rc ids
    resp="$(curl -sS --max-time 25 -X POST \
        -d "{\"package\":{\"ecosystem\":\"${eco}\",\"name\":\"${name}\"},\"version\":\"${ver}\"}" \
        https://api.osv.dev/v1/query 2>/dev/null)"
    rc=$?
    # Check curl's OWN exit status, not just whether bytes came back. A
    # truncated or aborted transfer can leave a non-empty body that is neither
    # a clean result nor an advisory list, and grepping it silently reads CLEAN.
    if [[ $rc -ne 0 ]]; then
        printf '  %-22s %-12s %bSKIPPED%b  (curl exit %d)\n' "$name" "$ver" "$YELLOW" "$NC" "$rc"
        SKIPPED=$((SKIPPED+1)); return 0
    fi
    if [[ -z "$resp" ]]; then
        printf '  %-22s %-12s %bSKIPPED%b  (empty response from OSV)\n' "$name" "$ver" "$YELLOW" "$NC"
        SKIPPED=$((SKIPPED+1)); return 0
    fi
    # Shape check. A well-formed OSV answer is either `{}` (nothing known) or an
    # object carrying "vulns". Anything else — an error object, an HTML error
    # page, a half-received body — must not be read as clean.
    local trimmed; trimmed="$(tr -d '[:space:]' <<<"$resp")"
    if [[ "$trimmed" != "{}" ]] && ! grep -q '"vulns"' <<<"$resp"; then
        printf '  %-22s %-12s %bSKIPPED%b  (unrecognised OSV response shape)\n' "$name" "$ver" "$YELLOW" "$NC"
        SKIPPED=$((SKIPPED+1)); return 0
    fi

    ids="$(grep -o '"\(CVE\|GHSA\|PYSEC\|GO\|OSV\|RUSTSEC\|MAL\)-[A-Za-z0-9._-]*"' <<<"$resp" \
           | tr -d '"' | sort -u | tr '\n' ' ')"
    if [[ -n "$ids" ]]; then
        printf '  %-22s %-12s %bVULNERABLE%b  %s\n' "$name" "$ver" "$RED" "$NC" "$ids"
        VULN=$((VULN+1)); return 0
    fi

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

echo "── Python pins (requirements.txt) ───────────────────────────────"
PINS=0
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(tr -d '[:space:]' <<<"$line")"
    [[ -z "$line" ]] && continue
    if [[ "$line" != *"=="* ]]; then
        printf '  %-22s %-12s %bNOT PINNED%b  (== required for SCA)\n' "$line" "-" "$RED" "$NC"
        VULN=$((VULN+1)); continue
    fi
    query_osv PyPI "${line%%==*}" "${line##*==}"
    PINS=$((PINS+1))
done < "$REQ"

if [[ $PINS -eq 0 ]]; then
    echo "${RED}sca-check: no pins parsed from requirements.txt — refusing to pass.${NC}" >&2
    exit 3
fi

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
