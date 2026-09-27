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
    # Round 2 (adversary F6): every RFC 1918 range, not only 192.168/16 ...
    ("private address (10/8)",       r"\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"),
    ("private address (172.16/12)",  r"\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b"),
    # ... internal DNS suffixes (a dotted host name, so a code property such
    # as `t.internal` does not count) ...
    ("internal host name",     r"\b[a-z0-9-]+\.int\.[a-z0-9-]+\.[a-z]{2,}\b"),
    ("internal DNS suffix",    r"\b[a-z0-9-]+\.[a-z0-9-]+\.(internal|intranet|corp|lan|home\.arpa)\b"),
    # ... secret-store paths and the personal code namespace.
    ("secret-store path",      r"\b(creds|secret|kv)/(apps|data|hooks|metadata|infra)/"),
    ("personal namespace",     "james" + r"\.rodman/"),
    # Round 8 (gatekeeper): IPv6 unique-local (the fd prefix, /8) and
    # link-local (fe8 to feb, /10) addresses: an address shape, >= 3 groups.
    # The labels and this comment do not spell an address, so this file
    # does not match itself.
    # REG-0009 (v1.2.0): the WHOLE unique-local range, the /7 (fc AND fd prefixes).
    ("private address (IPv6 unique-local)",   r"\bf[cd][0-9a-f]{2}(:[0-9a-f]{0,4}){2,7}"),
    ("link-local address (IPv6)",             r"\bfe[89ab][0-9a-f](:[0-9a-f]{0,4}){2,7}"),
]
# REG-0009: re.ASCII, so word boundaries are ASCII-only. Decoded as latin-1,
# a byte such as 0xE9 became a letter that \b counts as a WORD character, so
# one stray byte before a 10/8 address removed the boundary and hid it.
RX = [(label, re.compile(p, re.I | re.A)) for label, p in PATTERNS]

# Known binary media, recognised by CONTENT (magic number), not by name: pixel
# data read as text produces address-shaped noise. Everything else is scanned.
MEDIA_MAGIC = (b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a", b"BM",
               b"\x00\x00\x01\x00", b"wOFF", b"wOF2")

# Paths that are this repository's own process records: tracked, but
# export-ignored and never shipped. In a BUNDLE they are forbidden outright.
INTERNAL = (".claude/", ".work/", ".gitlab-ci.yml")
FORBIDDEN_IN_BUNDLE = re.compile(
    r"(^|/)(\.claude|\.work|\.git|\.github)(/|$)|(^|/)docs/SonarQube-Report-[^/]*$|(^|/)\.gitlab-ci\.yml$")

# Third-party archives (wheels, .debs, compressed indexes): not ours to scan,
# and their compressed bytes are noise when read as text.
ARCHIVES = (".whl", ".deb", ".tar.gz", ".tgz", ".zip", ".gz")
findings = []
scanned = 0

def scan(rel, data):
    global scanned
    # Round 8 (gatekeeper): a file that is not valid UTF-8 used to be SKIPPED,
    # so one stray byte hid every tie in it. It is now read byte-for-byte
    # (latin-1 maps every byte), and still matched. Third-party archives are
    # left out by the callers, never by decoding.
    if data.startswith(MEDIA_MAGIC):
        return
    text = None
    # REG-0009: UTF-16 (a BOM, or the NUL-every-other-byte shape of ASCII
    # text in UTF-16) is decoded as such; read as latin-1 its NULs split
    # every token and nothing ever matched.
    head = data[:256]
    half = len(head) // 2
    if head.startswith((b"\xff\xfe", b"\xfe\xff")):
        text = data.decode("utf-16", "replace")
    elif half >= 4 and head[1::2].count(0) >= half * 0.9 and head[0::2].count(0) == 0:
        text = data.decode("utf-16-le", "replace")
    elif half >= 4 and head[0::2].count(0) >= half * 0.9 and head[1::2].count(0) == 0:
        text = data.decode("utf-16-be", "replace")
    if text is None:
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            text = data.decode("latin-1")
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
        if os.path.isfile(path) and not rel.endswith(ARCHIVES):
            scan(rel, open(path, "rb").read())
elif mode == "dir":
    for dirpath, dirnames, filenames in os.walk(target):
        dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__")]
        for f in filenames:
            path = os.path.join(dirpath, f)
            rel = os.path.relpath(path, target).replace(os.sep, "/")
            if not rel.endswith(ARCHIVES):
                scan(rel, open(path, "rb").read())
else:
    with tarfile.open(target, "r:*") as tf:
        for m in tf.getmembers():
            # Round 8 (gatekeeper): lstrip("./") stripped the DOT of a leading
            # ".work/" too, so a FLAT bundle (no top-level directory) carrying
            # .work/ passed. Only a literal "./" prefix is removed now, and the
            # rule matches the component at any depth.
            name = m.name
            while name.startswith("./"):
                name = name[2:]
            name = name.lstrip("/")
            inner = name.split("/", 1)[1] if "/" in name else name
            if FORBIDDEN_IN_BUNDLE.search(name):
                findings.append("%s: internal or process file inside the bundle" % name)
                continue
            if m.isfile():
                data = tf.extractfile(m).read()
                if inner.endswith(ARCHIVES):
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
