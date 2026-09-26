#!/usr/bin/env bash
# =============================================================================
# check-version-surfaces.sh — every version surface says what VERSION says.
#
# The release pipeline (ci-templates) checks VERSION against the tag and
# nothing else. tm/VERSION — the one /api/health and /api/version serve, and
# the one the upgrade verifies the running service against — sat at 1.0.6
# through v1.0.7 … v1.0.11, so production answered "1.0.6" for six different
# releases and no check could notice. This gate holds every declared surface
# (.claude/project.yml surfaces:) to VERSION, and runs inside tests/run.sh, so
# the CI test lane enforces it on every tag.
#
#   bash tools/check-version-surfaces.sh             this repository
#   bash tools/check-version-surfaces.sh --root DIR  a copy (used by t22)
#
# Exit: 0 all agree · 1 a surface disagrees or cannot be read · 3 could not run.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${1:-}" == "--root" ]] && { ROOT="${2:-}"; [[ -d "$ROOT" ]] || { echo "check-version-surfaces: --root needs a directory" >&2; exit 3; }; }

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-version-surfaces: no python found" >&2; exit 3; }

"$PY" - "$(cygpath -m "$ROOT" 2>/dev/null || printf '%s' "$ROOT")" <<'PYCHK'
import io, os, re, sys

root = sys.argv[1]
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

def read(rel):
    p = os.path.join(root, rel)
    return io.open(p, encoding="utf-8").read() if os.path.isfile(p) else None

want = (read("VERSION") or "").strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", want):
    print("FAIL: VERSION does not hold an N.N.N version: %r" % want)
    sys.exit(1)
maj, mnr, pat = (int(x) for x in want.split("."))
token = "%d" % (maj * 1000 + mnr * 100 + pat)     # 1.1.0 -> 1100, 1.0.6 -> 1006

# (file, regex with ONE group that must equal VERSION, what it is)
SURFACES = [
    ("tm/VERSION",                    r"\A\s*(\S+)\s*\Z",                        "served by /api/health and /api/version"),
    ("app/components/SettingsTab.js", r"\['Version', '([^']+)'",                 "downloadPpsm() Version row"),
    ("PPSM.csv",                      r'^"Version","([^"]+)"',                   "static PPSM Version row"),
    ("app/styles/main.css",           r"^ \* Version: (\S+)",                    "stylesheet header"),
    ("install.sh",                    r"^# Version: (\S+)",                      "installer header"),
    ("prepare-offline.sh",            r"^# Version: (\S+)",                      "bundler header"),
    ("SBOM.md",                       r"^\*\*Version:\*\* (\S+)",                "SBOM version"),
    ("SBOM.md",                       r"urn:topic-manager:sbom:(\S+)",            "SBOM serial"),
    ("docs/INSTALL.md",               r"^\*\*Version:\*\* (\S+)",                "install guide version"),
    ("README.md",                     r"\A# Jarvis Topic Manager v(\S+)",         "README title"),
    ("README.md",                     r'should return `\{"status":"ok","version":"([^"]+)"\}`', "README health example"),
    ("CHANGELOG.md",                  r"^## \[([^\]]+)\]",                        "newest CHANGELOG section"),
]

fail = 0
for rel, rx, what in SURFACES:
    src = read(rel)
    if src is None:
        print("FAIL: %-32s missing (%s)" % (rel, what)); fail += 1; continue
    m = re.search(rx, src, re.M)
    if not m:
        print("FAIL: %-32s no %s found — the surface moved or was deleted" % (rel, what)); fail += 1; continue
    got = m.group(1).strip()
    if got != want:
        print("FAIL: %-32s %s says %s, VERSION says %s" % (rel, what, got, want)); fail += 1
    else:
        print("  OK   %-32s %s" % (rel, what))

# Cache-bust tokens: every ?v= in the shipped frontend is ONE value, derived
# from VERSION, so a browser can never mix two releases' files.
tokens = {}
for rel in ["index.html"] + ["app/components/" + f for f in sorted(os.listdir(os.path.join(root, "app/components"))) if f.endswith(".js")] \
                          + ["app/components/modals/" + f for f in sorted(os.listdir(os.path.join(root, "app/components/modals"))) if f.endswith(".js")]:
    src = read(rel) or ""
    for t in re.findall(r"\?v=(\d+)", src):
        tokens.setdefault(t, []).append(rel)
count = sum(len(v) for v in tokens.values())
if count == 0:
    print("FAIL: no ?v= cache tokens found at all"); fail += 1
elif set(tokens) != {token}:
    fail += 1
    print("FAIL: ?v= cache tokens %s; VERSION %s needs every one to be %s"
          % (", ".join("%s x%d" % (k, len(v)) for k, v in sorted(tokens.items())), want, token))
else:
    print("  OK   %-32s %d cache tokens, all ?v=%s" % ("index.html + components", count, token))

# The sentinel rule (hazards[hardcoded-version-fallback]): these two must not
# assert a version they were not told.
for rel, rx in (("app/main.js", r"ref\('unknown'\)"),
                ("app/components/modals/AboutModal.js", r"version:\s*'unknown'")):
    if not re.search(rx, read(rel) or ""):
        print("FAIL: %s no longer seeds the version as 'unknown'" % rel); fail += 1

if fail:
    print("check-version-surfaces: %d surface(s) disagree with VERSION %s." % (fail, want))
    sys.exit(1)
print("check-version-surfaces: every surface says %s." % want)
PYCHK
