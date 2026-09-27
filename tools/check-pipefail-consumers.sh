#!/usr/bin/env bash
# =============================================================================
# tools/check-pipefail-consumers.sh — no early-exit consumer at the end of a
# pipe in the test suite OR in the product scripts.
#
#   bash tools/check-pipefail-consumers.sh [file-or-dir ...]
#   default: tests/ AND the product scripts — install.sh, install/*.sh,
#   install/libexec/*, prepare-offline.sh (REG-0004, v1.2.0). Round 8 fixed
#   the class in tests only; in install.sh's pkg_installed the same race could
#   read an installed package as missing, and in the upgrade audit it could
#   MISS an immutable file — a blocker read as a pass.
#
# Every test runs under `set -o pipefail`. A consumer that stops reading as soon
# as it has its answer — `grep -q`, `grep -m N`, `head` — can leave the PRODUCER
# writing into a closed pipe; it dies of SIGPIPE (141) and pipefail reports the
# whole pipeline as failed. Whether that happens depends on how much the
# producer still had to write when the consumer exited: pipe timing.
# MEASURED 2026-09-26 (gatekeeper): t24's `tm_extract_func ... | grep -q`
# false-failed in 2 of 3 fresh --remote --strict runs, 3 in 400 on the host.
# In an `if`/`&&` position the same race is a false PASS.
#
# Capture the producer, then test the text: grep -q PAT <<<"$out", or
# `sed -n 1p` instead of `head -1` (sed reads all of its input).
#
# Flags, outside comments: `| grep` with -q/-m (or --quiet/--silent/
# --max-count) among its words, `| head`,
# and `| awk` whose program calls exit. Exit 1 on any hit, 2 on no input.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -eq 0 ]; then
    set -- "${ROOT}/tests" "${ROOT}/install.sh" "${ROOT}/prepare-offline.sh"
    for f in "${ROOT}"/install/*.sh "${ROOT}"/install/libexec/*; do
        [ -f "$f" ] && set -- "$@" "$f"
    done
fi

files=()
for a in "$@"; do
    if [ -d "$a" ]; then
        while IFS= read -r f; do files+=("$f"); done < <(find "$a" -type f -name '*.sh' | sort)
    elif [ -f "$a" ]; then
        files+=("$a")
    else
        echo "check-pipefail-consumers: no such file or directory: $a" >&2; exit 2
    fi
done
[ ${#files[@]} -gt 0 ] || { echo "check-pipefail-consumers: no .sh files to check" >&2; exit 2; }

hits="$(awk '
    { line = $0 }
    line ~ /^[[:space:]]*#/ { next }
    # A PIPE is a "|" that is not half of "||" (a || b is not a pipeline).
    line ~ /(^|[^|])\|[[:space:]]*grep[^|]*[[:space:]](-[A-Za-z]*[qm]|--quiet|--silent|--max-count)/ \
      || line ~ /(^|[^|])\|[[:space:]]*head([[:space:]]|$)/ \
      || line ~ /(^|[^|])\|[[:space:]]*awk[^|]*[^A-Za-z_]exit([^A-Za-z_]|$)/ { printf "%s:%d: %s\n", FILENAME, FNR, line }
' "${files[@]}")"

if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    echo "check-pipefail-consumers: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') early-exit consumer(s) under pipefail. Capture the producer and test the text (grep -q PAT <<<\"\$out\"; sed -n 1p)."
    exit 1
fi
echo "check-pipefail-consumers: ${#files[@]} file(s), no early-exit consumer at the end of a pipe."
