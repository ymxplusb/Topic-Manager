#!/usr/bin/env bash
# =============================================================================
# check-shell-parse.sh — every shell script parses under the OLDEST bash too
#
#   bash tools/check-shell-parse.sh [file ...]     default: every *.sh in the
#                                                  tree, plus install/libexec/*
#
# WO-0006 assure-fix-2: bash 3.2 (macOS /bin/bash, where these tests are also
# run) does not understand a heredoc inside $( ... ). It scans the heredoc's
# BODY for quotes as if it were shell, so one apostrophe in it ("a BROWSER's
# status poll", "a stranger's number" - both in Python comments) leaves an
# unclosed quote and the WHOLE FILE fails to parse: `bash -n` -> unexpected
# EOF. Linux bash 5 parses the same file, so nothing on CI noticed; t14 and t51
# did not run at all on the Mac.
#
# Two checks:
#   1. STATIC, everywhere: every heredoc opened inside an unclosed $( must have
#      a body whose quotes balance when scanned as shell. That is the pattern;
#      it needs no old bash to find.
#   2. If an old bash is available (TM_OLD_BASH, or /bin/bash when it is 3.x),
#      `bash -n` with it on every file. Reported as run or not run, never
#      silently skipped.
#
# Exit 0 clean, 1 a finding, 3 could not run.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-shell-parse: no python found" >&2; exit 3; }

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(
        cd "$REPO_ROOT" && find . -path ./.git -prune -o -type f \( -name '*.sh' -o -path './install/libexec/*' \) -print \
            | while IFS= read -r p; do head -c 64 "$p" | grep -q 'bash' && echo "${REPO_ROOT}/${p#./}"; done | sort)
fi
[ ${#FILES[@]} -gt 0 ] || { echo "check-shell-parse: no shell files found" >&2; exit 3; }

rc=0
"$PY" - "${FILES[@]}" <<'PYCHK' || rc=1
import re, sys

HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")

def line_quote(text):
    """The quote a shell-style scan of one line ends inside, or None."""
    q, i = None, 0
    while i < len(text):
        ch = text[i]
        if q == "'":
            if ch == "'": q = None
        elif ch == '\\':
            i += 1
        elif q == '"':
            if ch == '"': q = None
        elif ch in "'\"":
            q = ch
        i += 1
    return q

def scan(path):
    """Yield (opener line, tag, body start, body end) for every heredoc whose
    opener sits inside an open $( ... ), tracking quotes and command
    substitutions across lines (a $( often opens lines above its <<)."""
    lines = open(path, 'rb').read().decode('utf-8', 'replace').replace('\r\n', '\n').split('\n')
    stack, n = [], 0          # stack of '(' (a $( ) and '"' (a double quote)
    while n < len(lines):
        line, i, sq, pending = lines[n], 0, False, []
        while i < len(line):
            ch, top = line[i], (stack[-1] if stack else None)
            if sq:
                if ch == "'": sq = False
            elif ch == '\\':
                i += 1
            elif top == '"':
                if ch == '"': stack.pop()
                elif line.startswith('$(', i): stack.append('('); i += 1
            elif ch == '#' and (i == 0 or line[i - 1] in ' \t;(|&'):
                break
            elif ch == "'":
                sq = True
            elif ch == '"':
                stack.append('"')
            elif line.startswith('<<<', i):
                i += 2
            elif line.startswith('<<', i):
                m = HEREDOC.match(line, i)
                if m:
                    pending.append((m.group(3), m.group(1) == '-', '(' in stack))
                    i = m.end() - 1
            elif line.startswith('$(', i):
                stack.append('('); i += 1
            elif ch == '(' and '(' in stack:
                stack.append('(')
            elif ch == ')' and top == '(':
                stack.pop()
            i += 1
        for tag, dash, inside in pending:
            end = n + 1
            while end < len(lines) and (lines[end].lstrip('\t') if dash else lines[end]) != tag:
                end += 1
            if inside:
                yield n + 1, tag, n + 1, end
            n = end
        n += 1

bad = 0
for path in sys.argv[1:]:
    lines = open(path, 'rb').read().decode('utf-8', 'replace').replace('\r\n', '\n').split('\n')
    for opener, tag, start, end in scan(path):
        for k in range(start, end):
            q = line_quote(lines[k])
            if q:
                print("FAIL: %s:%d: heredoc %s (opened line %d inside $( )) has an unpaired %s "
                      "on this line; bash 3.2 reads the body as shell and cannot parse the "
                      "file - reword it" % (path, k + 1, tag, opener, q))
                bad += 1
sys.exit(1 if bad else 0)
PYCHK

OLD="${TM_OLD_BASH:-}"
if [ -z "$OLD" ] && [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]' 2>/dev/null; then
    OLD=/bin/bash
fi
if [ -n "$OLD" ]; then
    ver="$("$OLD" -c 'echo "$BASH_VERSION"' 2>/dev/null)" || { echo "check-shell-parse: ${OLD} does not run" >&2; exit 3; }
    for f in "${FILES[@]}"; do
        "$OLD" -n "$f" 2>"${TMPDIR:-/tmp}/csp.$$" || { echo "FAIL: ${f}: bash ${ver} -n: $(head -1 "${TMPDIR:-/tmp}/csp.$$")"; rc=1; }
    done
    rm -f "${TMPDIR:-/tmp}/csp.$$"
    echo "check-shell-parse: bash ${ver} -n on ${#FILES[@]} file(s): $([ $rc -eq 0 ] && echo clean || echo FAILED)"
else
    echo "check-shell-parse: no bash 3.x here (set TM_OLD_BASH to one); static check only"
fi
[ $rc -eq 0 ] && echo "check-shell-parse: PASS (${#FILES[@]} file(s))"
exit $rc
