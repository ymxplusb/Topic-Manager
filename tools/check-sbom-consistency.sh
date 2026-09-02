#!/usr/bin/env bash
# =============================================================================
# check-sbom-consistency.sh — dependency-table drift gate
#
# The same dependency facts are written down in FOUR places:
#     requirements.txt                          (the source of truth)
#     SBOM.md                                   (the bill of materials)
#     NOTICES.md                                (third-party licences)
#     app/components/modals/AboutModal.js       (the About dialog)
#
# Nothing forced them to agree, and on 2026-08-30 all three copies had drifted.
# AboutModal.js was the worst: it still advertised cryptography 44.0.2 — the
# five-advisory pin the release exists to remove — so the About dialog would
# have told an operator the app shipped the vulnerable version. SBOM.md and
# NOTICES.md disagreed with each other AND with the deployment.
#
# A bill of materials nobody checks is decoration. This gate makes drift fail.
#
# Usage:  bash tools/check-sbom-consistency.sh
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-sbom-consistency: no python found" >&2; exit 3; }

"$PY" - "$REPO_ROOT" <<'PYCHK'
import io, os, re, sys

root = sys.argv[1]

def read(rel):
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        return None
    return io.open(p, "rb").read().decode("utf-8")

# ── the source of truth ─────────────────────────────────────────────────────
req_src = read("requirements.txt")
if req_src is None:
    print("FAIL: requirements.txt not found"); sys.exit(1)

truth = {}
for line in req_src.splitlines():
    line = line.split("#")[0].strip()
    if "==" in line:
        name, ver = line.split("==", 1)
        truth[name.strip().lower()] = ver.strip()

if not truth:
    print("FAIL: no == pins parsed from requirements.txt — the gate examined nothing.")
    sys.exit(1)

failures = 0
checked_files = 0

def compare(label, rel, found):
    """found: {lowername: version} discovered in that file."""
    global failures, checked_files
    src_missing = found is None
    if src_missing:
        print("FAIL: %s not found" % rel); failures += 1; return
    checked_files += 1
    if not found:
        print("FAIL: %s — no dependency versions found. Either the file changed "
              "shape or this gate stopped reading it; either way it is not "
              "checking anything." % rel)
        failures += 1
        return

    # COVERAGE, not just agreement. Guarding only on "found nothing" catches a
    # total parse failure and is blind to PARTIAL loss — and partial loss is
    # what actually happens. Measured 2026-09-01: a blank line inserted
    # mid-table dropped SBOM.md from 12 components to 8, and a header renamed
    # Version -> Ver dropped it to 5; the gate printed "all 3 copies agree"
    # both times. A prose edit could therefore delete components from this
    # gate's view without failing anything.
    #
    # So: every == pin in requirements.txt must be VISIBLE in every copy. A
    # component this gate cannot see is a component it is not checking, and
    # that is a failure, not a pass.
    unseen = sorted(set(truth) - set(found))
    if unseen:
        print("FAIL: %s — %d of %d pinned components are NOT VISIBLE to this "
              "gate:" % (rel, len(unseen), len(truth)))
        for n in unseen:
            print("    %-18s expected %s" % (n, truth[n]))
        print("    The file may still be correct — but its shape changed and "
              "this gate can no longer see those rows,")
        print("    so it cannot vouch for them. Fix the table shape or the "
              "parser, not this message.")
        failures += len(unseen)
        return

    bad = []
    for name, ver in sorted(found.items()):
        want = truth.get(name)
        if want is None:
            continue          # extra components (nginx, Ubuntu, Python) are fine
        if ver != want:
            bad.append("    %-18s %s says %-10s requirements.txt says %s"
                       % (name, label, ver, want))
    if bad:
        print("FAIL: %s disagrees with requirements.txt:" % rel)
        print("\n".join(bad))
        failures += len(bad)
    else:
        print("  OK   %-42s (%d pinned components agree)" % (rel, len(found)))

# ── AboutModal.js: { name: 'X', version: 'Y', ... } ─────────────────────────
about = read("app/components/modals/AboutModal.js")
found = None
if about is not None:
    found = {}
    for m in re.finditer(r"name:\s*'([^']+)'\s*,\s*version:\s*'([^']+)'", about):
        found[m.group(1).strip().lower()] = m.group(2).strip()
compare("About dialog", "app/components/modals/AboutModal.js", found)

# ── SBOM.md: markdown table rows | Name | Version | ... ─────────────────────
# Only tables whose SECOND column header is literally "Version" carry current
# versions. SBOM.md also contains a change-history table headed
# "| Component | Was | Now | Reason |" whose second column is the OLD version —
# reading that as current produced six false "drift" reports on this gate's
# first run, and acting on them would have corrupted the CVE history.
sbom = read("SBOM.md")
found = None
if sbom is not None:
    found = {}
    in_version_table = False
    for line in sbom.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            in_version_table = False        # a blank line ends the table
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if len(cells) < 2:
            continue
        if set(cells[0]) <= set("-: ") and cells[0]:
            continue                        # the |---|---| separator row
        if cells[0].lower() == "component":
            in_version_table = (cells[1].lower() == "version")
            continue
        if not in_version_table:
            continue
        name, ver = cells[0], cells[1]
        if re.match(r"^[0-9]+\.[0-9]", ver):
            found[name.lower()] = ver
compare("SBOM.md", "SBOM.md", found)

# ── NOTICES.md: "## Name" followed by "Version: X" ─────────────────────────
notices = read("NOTICES.md")
found = None
if notices is not None:
    found = {}
    cur = None
    for line in notices.splitlines():
        h = re.match(r"^##+\s+(.+?)\s*$", line)
        if h:
            cur = h.group(1).strip()
            continue
        v = re.match(r"^\s*(?:\*\*)?Version(?:\*\*)?:\s*(.+?)\s*$", line)
        if v and cur:
            ver = v.group(1).strip().strip("*` ")
            if re.match(r"^[0-9]+\.[0-9]", ver):
                # NOTICES uses the upstream project name for the Kafka client
                key = cur.lower().replace("confluent-kafka-python", "confluent-kafka")
                found[key] = ver
compare("NOTICES.md", "NOTICES.md", found)

print()
if failures:
    print("check-sbom-consistency: %d disagreement(s) with requirements.txt." % failures)
    print("requirements.txt is the source of truth — update the copies, not the pin.")
    sys.exit(1)

if checked_files < 3:
    print("FAIL: only %d of 3 dependency copies were read." % checked_files)
    sys.exit(1)

print("check-sbom-consistency: all 3 copies agree with requirements.txt.")
PYCHK
