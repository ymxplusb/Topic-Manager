#!/usr/bin/env bash
# =============================================================================
# check-frontend-syntax.sh — every script and stylesheet index.html loads
# exists, and every script parses.
#
# There is no build step: a syntax error in any component ships straight to
# the browser as a blank pane, and a file index.html names but the tree does
# not hold is a 404 that takes every component after it down with it. The
# gate used to be a fixed glob (app/main.js app/components/*.js
# app/components/modals/*.js) run with `node --check`: a file index.html
# loads going MISSING left the glob one shorter and still green (REG-0017).
# The list is now DERIVED from index.html — every <script src> and <link
# rel="stylesheet" href> outside a comment — and a missing one fails. The old
# glob is kept as well, so a component that is present but no longer loaded
# is still syntax-checked.
#
# /lib/vue.global.prod.js is the one load that is not in the tree: install.sh,
# prepare-offline.sh and the upgrade fetch it and verify it against
# VUE_SHA256, so it is named here, not skipped silently.
#
#   bash tools/check-frontend-syntax.sh             this repository
#   bash tools/check-frontend-syntax.sh --root DIR  a copy (used by t41)
#
# Exit: 0 all present and parsing · 1 a file is missing or does not parse ·
#       3 could not run (no node, no python, no index.html).
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${1:-}" == "--root" ]] && { ROOT="${2:-}"; [[ -d "$ROOT" ]] || { echo "check-frontend-syntax: --root needs a directory" >&2; exit 3; }; }

command -v node >/dev/null 2>&1 || { echo "check-frontend-syntax: node is not installed; nothing was checked" >&2; exit 3; }
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-frontend-syntax: no python found" >&2; exit 3; }
[[ -f "$ROOT/index.html" ]] || { echo "check-frontend-syntax: no index.html under $ROOT" >&2; exit 3; }

# The loads index.html makes, one repo-relative path per line, prefixed
# "js " or "css ". Read by Python's HTML PARSER, not a regex (round 4): the
# regex took only QUOTED attribute values, so <script src=/app/x.js> — valid
# HTML, and a load the browser makes — was invisible, and a missing or broken
# file loaded that way stayed green. The parser reads quoted, unquoted and
# upper-case attributes alike, and never reports a commented-out tag.
LOADS="$("$PY" - "$ROOT/index.html" <<'PYLOADS'
import sys
from html.parser import HTMLParser


class Loads(HTMLParser):
    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "").strip() for k, v in attrs}
        if tag == "script" and a.get("src"):
            print("js " + a["src"])
        elif tag == "link" and "stylesheet" in a.get("rel", "").lower().split() and a.get("href"):
            print("css " + a["href"])

    handle_startendtag = handle_starttag


Loads(convert_charrefs=True).feed(open(sys.argv[1], encoding="utf-8").read())
PYLOADS
)" || { echo "check-frontend-syntax: could not read index.html" >&2; exit 3; }

INSTALL_FETCHED="/lib/vue.global.prod.js"
fail=0; n_js=0
declare -A SEEN=()
while read -r kind url; do
    [[ -n "$kind" ]] || continue
    path="${url%%[?#]*}"
    case "$path" in
        /*) ;;
        *) echo "FAIL: index.html loads ${url}, which is not a root-relative path"; fail=$((fail + 1)); continue ;;
    esac
    if [[ "$path" == "$INSTALL_FETCHED" ]]; then
        echo "  --   ${path} (fetched and SHA-256-verified at install time; not in the tree)"
        continue
    fi
    rel="${path#/}"
    if [[ ! -f "$ROOT/$rel" ]]; then
        echo "FAIL: index.html loads ${path}, and ${rel} does not exist"; fail=$((fail + 1)); continue
    fi
    if [[ "$kind" == "js" ]]; then
        SEEN["$rel"]=1
        if out="$(node --check "$ROOT/$rel" 2>&1)"; then
            n_js=$((n_js + 1)); echo "  OK   ${rel}"
        else
            echo "FAIL: ${rel} does not parse:"; printf '%s\n' "$out" | sed 's/^/        /'; fail=$((fail + 1))
        fi
    else
        echo "  OK   ${rel} (present)"
    fi
done <<< "$LOADS"

[[ "$n_js" -gt 0 || "$fail" -gt 0 ]] || { echo "FAIL: index.html loads no script at all"; fail=$((fail + 1)); }

# Components in the tree that index.html does not load: still parsed.
shopt -s nullglob
for f in "$ROOT"/app/main.js "$ROOT"/app/components/*.js "$ROOT"/app/components/modals/*.js; do
    rel="${f#"$ROOT"/}"
    [[ -n "${SEEN[$rel]:-}" ]] && continue
    if out="$(node --check "$f" 2>&1)"; then
        echo "  OK   ${rel} (in the tree, not loaded by index.html)"
    else
        echo "FAIL: ${rel} does not parse:"; printf '%s\n' "$out" | sed 's/^/        /'; fail=$((fail + 1))
    fi
done

if [[ "$fail" -gt 0 ]]; then
    echo "check-frontend-syntax: ${fail} problem(s)."
    exit 1
fi
echo "check-frontend-syntax: ${n_js} script(s) index.html loads are present and parse."
