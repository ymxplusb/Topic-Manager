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
#
# install.sh's WSGI heredoc used to be invisible TWICE over: this map named only
# upgrade-full.sh, and WSGI sat in a hardcoded skip list beside NGINXEOF and SH
# as "obviously not Python". It is the gunicorn entry point — the most
# load-bearing Python in the repo. Measured 2026-09-01: `def broken(:::`
# injected into it passed ALL EIGHT GATES, shipping a wsgi.py that cannot start.
# NGINXEOF and SH were stale; those heredocs no longer exist in the tree.
EXPECTED = {
    os.path.join("install", "upgrade-full.sh"): ["PYRESOLVE", "PYLDAP", "PYBACKUP"],
    "install.sh": ["WSGI"],
}

# Tags that are deliberately NOT Python. Keep this EMPTY unless a real one
# appears; every entry is a hole in the gate and must be justified in place.
NON_PYTHON = set()

failures = 0
checked = 0

for rel, tags in EXPECTED.items():
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        print("FAIL: %s not found" % rel); failures += 1; continue

    # bytes -> explicit utf-8, never a lossy decode
    # bytes -> explicit utf-8, then normalise CRLF. git autocrlf rewrites these
    # files on every Windows checkout and the heredoc regex anchors on a bare
    # \n, so without this the gate reports "expected heredoc not present" for
    # heredocs that are plainly there — a false red that teaches people to
    # ignore it. Measured 2026-09-02: a merge checkout turned all four
    # "missing". Normalising is safe; the heredoc BODY is compiled either way.
    src = open(path, "rb").read().decode("utf-8").replace("\r\n", "\n")

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
        if tag in NON_PYTHON:
            continue
        if tag not in tags:
            # An unclassified heredoc. Silently skipping is exactly how WSGI
            # stayed invisible — make the maintainer classify it instead.
            print("FAIL: %s: heredoc %s is not classified. Add it to EXPECTED "
                  "if it is Python, or to NON_PYTHON with a reason." % (rel, tag))
            failures += 1
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
