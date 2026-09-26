#!/usr/bin/env bash
# =============================================================================
# check-env-neutral.sh — nothing that ships may name the site it was built at.
#
# Until v1.1.0 the product carried one site's host names, private addresses,
# directory DNs, service-account names, CA name, admin user names and
# workstation paths in its code defaults, config examples, docs, tests and
# PPSM — and the offline bundle was a tarball of the whole working directory,
# so it also carried the agent contract (.claude/), the work orders (.work/)
# with production addresses, and dated scan reports.
#
#   bash tools/check-env-neutral.sh                 the tracked tree (git ls-files),
#                                                   minus .claude/ and .work/,
#                                                   which are this repo's own
#                                                   process records and are
#                                                   export-ignored (never shipped)
#   bash tools/check-env-neutral.sh --dir DIR       every file under DIR
#   bash tools/check-env-neutral.sh --bundle F.tgz  an offline bundle: the same
#                                                   content rules, AND no .claude/,
#                                                   .work/, .git/, .github/ or
#                                                   scan report may be inside it
#
# Exit: 0 neutral · 1 a tie was found · 3 could not run. It says what it
# scanned, so "found nothing" cannot be confused with "read nothing".
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="repo"; TARGET=""
case "${1:-}" in
    "")       ;;
    --dir)    MODE="dir";    TARGET="${2:-}"; [[ -d "$TARGET" ]] || { echo "check-env-neutral: --dir needs a directory" >&2; exit 3; } ;;
    --bundle) MODE="bundle"; TARGET="${2:-}"; [[ -f "$TARGET" ]] || { echo "check-env-neutral: --bundle needs a file" >&2; exit 3; } ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)        echo "check-env-neutral: unknown option $1" >&2; exit 3 ;;
esac

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-env-neutral: no python found" >&2; exit 3; }

FILELIST=""
if [[ $MODE == repo ]]; then
    command -v git >/dev/null 2>&1 || { echo "check-env-neutral: git is required in repo mode" >&2; exit 3; }
    FILELIST="$(mktemp "${TMPDIR:-/tmp}/tm-envn.XXXXXX")" || exit 3
    trap 'rm -f "$FILELIST"' EXIT
    git -C "$REPO_ROOT" ls-files -z > "$FILELIST" || { echo "check-env-neutral: git ls-files failed" >&2; exit 3; }
    TARGET="$REPO_ROOT"
fi

_native() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

"$PY" - "$MODE" "$(_native "$TARGET")" "$( [[ -n "$FILELIST" ]] && _native "$FILELIST" )" <<'PYCHK'
import io, os, re, sys, tarfile

mode, target, filelist = sys.argv[1], sys.argv[2], sys.argv[3]
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# Built from pieces so this file does not match itself. Case-insensitive.
PATTERNS = [
    ("site domain",            "crypt" + "iclight"),
    ("private address",        r"192\.168\." + r"\d"),
    ("site service account",   "svc-" + "kafka-ui"),
    ("site CA name",           "int-" + "CL-CA"),
    ("site admin account",     "claude" + "_admin"),
    ("personal user name",     r"\bjrod" + r"m(an)?\b"),
    ("workstation path",       "/c/" + "Users/"),
    ("personal repository",    "ymx" + "plusb"),
]
RX = [(label, re.compile(p, re.I)) for label, p in PATTERNS]

# Paths that are this repository's own process records: tracked, but
# export-ignored and never shipped. In a BUNDLE they are forbidden outright.
INTERNAL = (".claude/", ".work/")
FORBIDDEN_IN_BUNDLE = re.compile(
    r"(^|/)(\.claude|\.work|\.git|\.github)(/|$)|(^|/)docs/SonarQube-Report-[^/]*$")

findings = []
scanned = 0

def scan(rel, data):
    global scanned
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return                      # images, icons, wheels, .debs
    scanned += 1
    for n, line in enumerate(text.splitlines(), 1):
        for label, rx in RX:
            if rx.search(line):
                findings.append("%s:%d: %s: %s" % (rel, n, label, line.strip()[:100]))

if mode == "repo":
    names = [p for p in open(filelist, "rb").read().decode("utf-8").split("\0") if p]
    for rel in names:
        if rel.startswith(INTERNAL):
            continue
        path = os.path.join(target, rel)
        if os.path.isfile(path):
            scan(rel, open(path, "rb").read())
elif mode == "dir":
    for dirpath, dirnames, filenames in os.walk(target):
        dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__")]
        for f in filenames:
            path = os.path.join(dirpath, f)
            rel = os.path.relpath(path, target).replace(os.sep, "/")
            scan(rel, open(path, "rb").read())
else:
    with tarfile.open(target, "r:*") as tf:
        for m in tf.getmembers():
            name = m.name.lstrip("./")
            inner = name.split("/", 1)[1] if "/" in name else name
            if FORBIDDEN_IN_BUNDLE.search(inner) or FORBIDDEN_IN_BUNDLE.search(name):
                findings.append("%s: internal or process file inside the bundle" % name)
                continue
            if m.isfile():
                data = tf.extractfile(m).read()
                if inner.endswith((".whl", ".deb", ".tar.gz", ".zip")):
                    continue        # third-party archives: not ours to scan
                scan(name, data)

if scanned == 0 and not findings:
    print("check-env-neutral: FAIL — scanned no text files in %s mode; it checked nothing." % mode)
    sys.exit(1)
if findings:
    print("check-env-neutral: FAIL — %d environment tie(s) in %s mode:" % (len(findings), mode))
    for f in findings[:40]:
        print("  " + f)
    if len(findings) > 40:
        print("  ... and %d more" % (len(findings) - 40))
    sys.exit(1)
print("check-env-neutral: %d text file(s) scanned in %s mode, no environment ties." % (scanned, mode))
PYCHK
