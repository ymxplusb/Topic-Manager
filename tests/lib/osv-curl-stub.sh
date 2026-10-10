#!/usr/bin/env bash
# =============================================================================
# tests/lib/osv-curl-stub.sh — a stand-in `curl` for tools/sca-check.sh (t25,
# t55). Copied onto PATH as `curl`. It plays:
#   OSV /v1/querybatch  {"results": [...]}, one entry per query, in order;
#                       STUB_VULNS="name==version=ID ID,name==version=ID"
#                       names the vulnerable releases (case as queried)
#   OSV /v1/query       {} (sca-check uses it only as a reachability probe)
#   PyPI / npm          every release exists (HTTP 200)
# and these broken OSV answers (STUB_OSV_MODE), each of which must be "could
# not check" (exit 2), never clean (REG-0070):
#   empty    {}                               no results at all
#   token    {"next_page_token": "abc"}       a page token and nothing else
#   short    one result fewer than the queries
#   page     every first answer is {"next_page_token": "p1"}; the follow-up
#            with page_token is the real answer (pagination is followed)
#   endless  every answer, follow-ups included, is a page token
# STUB_OSV_HTTP sets the querybatch HTTP status (default 200).
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
out=""; url=""; data=""; fmt=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift; out="$1" ;; -d) shift; data="$1" ;; -w) shift; fmt="$1" ;;
        -X|--max-time) shift ;; -*) ;; *) url="$1" ;;
    esac
    shift
done
code=200; body=""
case "$url" in
    https://api.osv.dev/v1/querybatch)
        code="${STUB_OSV_HTTP:-200}"
        body="$(python3 -c '
import json, os, sys
q = json.loads(sys.argv[1])["queries"]
mode = os.environ.get("STUB_OSV_MODE", "")
vul = dict(x.rsplit("=", 1) for x in os.environ.get("STUB_VULNS", "").split(",") if x)
if mode == "empty":
    print("{}"); sys.exit()
if mode == "token":
    print(json.dumps({"next_page_token": "abc"})); sys.exit()
res = []
for e in q:
    if mode == "endless" or (mode == "page" and "page_token" not in e):
        res.append({"next_page_token": "p1"}); continue
    ids = vul.get("%s==%s" % (e["package"]["name"], e["version"]))
    res.append({"vulns": [{"id": i} for i in ids.split()]} if ids else {})
if mode == "short":
    res = res[:-1]
print(json.dumps({"results": res}))
' "$data")" ;;
    https://api.osv.dev/v1/query) body='{}' ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
[ -z "$fmt" ] || printf '%b' "${fmt//%\{http_code\}/$code}"
exit 0
