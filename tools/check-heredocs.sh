#!/usr/bin/env bash
# =============================================================================
# check-heredocs.sh — embedded-Python gate
#
# `bash -n` does NOT parse heredoc bodies. Gatekeeper proved it on 2026-08-30
# by injecting `def broken(:::` into the PYLDAP heredoc inside
# install/upgrade-full.sh: bash -n still exited 0. A Python syntax error inside
# an upgrade heredoc therefore ships completely untested by the shell gate —
# and these heredocs implement the config resolver, the LDAP pre-flight probe
# and the SQLite consistent snapshot, i.e. the upgrade's blocker checks.
#
# This extracts every `<<'NAME' ... NAME` Python heredoc from the shell scripts
# and compiles each one.
#
# NOTE ON ENCODING: the scripts are UTF-8 and contain em-dashes. Read as BYTES
# and decode UTF-8 explicitly — a lossy read corrupts them and produces a false
# failure. That already happened once during development.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-heredocs: no python found" >&2; exit 3; }

"$PY" - "$REPO_ROOT" <<'PYCHK'
import os, re, sys, py_compile, tempfile

root = sys.argv[1]

# Shell files that may carry embedded Python, and the heredoc tags to expect.
# Listing the expected tags means a heredoc that is RENAMED or DELETED fails
# the gate rather than silently reducing coverage to zero.
EXPECTED = {
    os.path.join("install", "upgrade-full.sh"): ["PYRESOLVE", "PYLDAP", "PYBACKUP"],
}

failures = 0
checked = 0

for rel, tags in EXPECTED.items():
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        print("FAIL: %s not found" % rel); failures += 1; continue

    # bytes -> explicit utf-8, never a lossy decode
    src = open(path, "rb").read().decode("utf-8")

    found = re.findall(r"<<'([A-Z][A-Z0-9_]*)'\n", src)
    for tag in tags:
        if tag not in found:
            print("FAIL: %s: expected heredoc %s not present "
                  "(renamed or removed? coverage would silently drop)" % (rel, tag))
            failures += 1

    for tag in sorted(set(found)):
        m = re.search(r"<<'" + re.escape(tag) + r"'\n(.*?)\n" + re.escape(tag) + r"\n",
                      src, re.S)
        if not m:
            print("FAIL: %s: heredoc %s opened but never terminated" % (rel, tag))
            failures += 1
            continue
        body = m.group(1)
        # Only Python heredocs are compilable; skip obvious non-Python ones.
        if tag in ("NGINXEOF", "WSGI", "SH"):
            continue
        tmp = os.path.join(tempfile.gettempdir(), "hd_%s.py" % tag)
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(body)
        try:
            py_compile.compile(tmp, doraise=True)
            print("  OK   %-12s %s (%d lines)" % (tag, rel, body.count("\n") + 1))
            checked += 1
        except py_compile.PyCompileError as exc:
            print("FAIL: %s: heredoc %s does not compile:\n    %s" % (rel, tag, exc))
            failures += 1
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass

if checked == 0 and failures == 0:
    print("FAIL: no heredocs were checked — the gate examined nothing.")
    sys.exit(1)

if failures:
    print("\ncheck-heredocs: %d failure(s)." % failures)
    sys.exit(1)

print("\ncheck-heredocs: %d embedded Python heredoc(s) compile." % checked)
PYCHK
