#!/usr/bin/env bash
# =============================================================================
# check-ppsm-consistency.sh — the two PPSM documents must be ONE document.
#
# The PPSM exists twice: PPSM.csv in the repository and the CSV that
# Settings > Support > Download PPSM builds in the browser
# (app/components/SettingsTab.js downloadPpsm). They drifted apart for months:
# the generator listed LDAP 389 and a MetalLB Kafka port the static file did
# not, the static file listed DNS, NTP and the install-time endpoints the
# generator did not, and neither carried syslog or said that OCSP/CRL is not
# used. An operator got two different answers from one release.
#
# This gate RUNS the real downloadPpsm() under node with a stubbed Blob,
# parses both CSVs with Python's csv module, and requires them to agree cell
# for cell. The one row allowed to differ is "Generated" (the browser stamps
# today's date). It also asserts COVERAGE, not just agreement: two copies that
# both lost the LDAPS row would agree perfectly.
#
# Exit: 0 agree and complete · 1 disagree or incomplete · 3 could not run.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC="${PPSM_STATIC:-${REPO_ROOT}/PPSM.csv}"
SETTINGS="${PPSM_SETTINGS:-${REPO_ROOT}/app/components/SettingsTab.js}"

command -v node >/dev/null 2>&1 || { echo "check-ppsm-consistency: node is required (it runs the real generator)" >&2; exit 3; }
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-ppsm-consistency: no python found" >&2; exit 3; }
[[ -s "$STATIC" ]]   || { echo "FAIL: ${STATIC} is missing or empty"; exit 1; }
[[ -s "$SETTINGS" ]] || { echo "FAIL: ${SETTINGS} is missing or empty"; exit 1; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/tm-ppsm.XXXXXX")" || exit 3
trap 'rm -rf "$TMPD"' EXIT
GEN="${TMPD}/generated.csv"

# Paths handed to node in the form node itself will open.
_native() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

PPSM_SRC="$(_native "$SETTINGS")" PPSM_OUT="$(_native "$GEN")" node -e '
const fs = require("fs"), vm = require("vm");
const src = fs.readFileSync(process.env.PPSM_SRC, "utf8");
let captured = null;
const sandbox = {
    ClusterModal: {}, console: console, Date: Date,
    Blob: function (parts) { captured = parts.join(""); },
    URL: { createObjectURL: function () { return "blob:stub"; } },
    document: { createElement: function () { return { click: function () {} }; },
                getElementById: function () { return null; }, body: { style: {} } },
};
vm.createContext(sandbox);
vm.runInContext(src + "\n;globalThis.__S = SettingsTab;", sandbox);
sandbox.__S.methods.downloadPpsm.call({});
if (captured === null) { console.error("downloadPpsm produced no CSV"); process.exit(4); }
fs.writeFileSync(process.env.PPSM_OUT, captured);
' || { echo "FAIL: could not run SettingsTab.downloadPpsm() under node — a parse error here is a blank Settings tab in the browser"; exit 1; }

"$PY" - "$STATIC" "$GEN" <<'PYCHK'
import csv, io, re, sys

def rows(path):
    text = io.open(path, encoding="utf-8").read()
    out = []
    for r in csv.reader(io.StringIO(text)):
        r = [c.strip() for c in r]
        while len(r) < 6:
            r.append("")
        out.append(r[:6] if not any(r[6:]) else r)
    return out

static, gen = rows(sys.argv[1]), rows(sys.argv[2])
s_cmp = [r for r in static if r[0] != "Generated"]
g_cmp = [r for r in gen if r[0] != "Generated"]

fail = 0
if s_cmp != g_cmp:
    fail += 1
    print("FAIL: PPSM.csv and downloadPpsm() disagree:")
    n = max(len(s_cmp), len(g_cmp))
    shown = 0
    for i in range(n):
        a = s_cmp[i] if i < len(s_cmp) else None
        b = g_cmp[i] if i < len(g_cmp) else None
        if a != b:
            print("  row %d\n    PPSM.csv      : %s\n    downloadPpsm(): %s" % (i + 1, a, b))
            shown += 1
            if shown >= 5:
                print("  ..."); break

if not any(r[0] == "Generated" for r in gen):
    fail += 1
    print("FAIL: the downloaded PPSM carries no Generated date row")

# Coverage: the rows the owner's PPSM must carry, checked on the static copy
# (the generated one is proven equal to it above).
def has(section, port, direction, text=""):
    return any(r[0] == section and r[2] == port and r[4] == direction and text in r[5]
               for r in s_cmp)
required = [
    ("Web", "443", "Inbound", ""), ("Web", "80", "Inbound", "Redirect"),
    ("Admin", "22", "Inbound", ""), ("Auth", "636", "Outbound", ""),
    ("Infra", "53", "Outbound", ""), ("Infra", "123", "Outbound", ""),
    ("Logging", "514", "Outbound", "PLANNED"), ("Logging", "6514", "Outbound", "PLANNED"),
    ("PKI", "N/A", "Outbound", "NOT USED"),
]
for sec, port, d, t in required:
    if not has(sec, port, d, t):
        fail += 1
        print("FAIL: no %s %s %s row%s" % (sec, port, d, (" mentioning '%s'" % t) if t else ""))
if not any(r[0] == "Kafka" and r[4] == "Outbound" and "operator-defined" in r[2] for r in s_cmp):
    fail += 1
    print("FAIL: the Kafka broker row does not say its ports are operator-defined")
if any(r[2] == "389" for r in s_cmp):
    fail += 1
    print("FAIL: an LDAP 389 row is listed; the product does not use plain LDAP")
if not any(r[0] == "Version" and re.match(r"^\d+\.\d+\.\d+$", r[1]) for r in s_cmp):
    fail += 1
    print("FAIL: no Version row with an N.N.N version")
leak = [c for r in s_cmp for c in r if re.search(r"192\.168\.|crypticlight", c, re.I)]
if leak:
    fail += 1
    print("FAIL: environment-specific value in the PPSM: %s" % leak[0][:80])

if fail:
    print("check-ppsm-consistency: %d problem(s)." % fail)
    sys.exit(1)
print("check-ppsm-consistency: PPSM.csv and downloadPpsm() agree on %d rows, coverage complete." % len(s_cmp))
PYCHK
