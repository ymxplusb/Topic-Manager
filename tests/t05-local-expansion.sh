#!/usr/bin/env bash
# =============================================================================
# t05 — `local a="$1" b="${a}/x"` READS AN UNSET a.
#
# THE DEFECT (found 2026-08-30 by the harness, not by review): bash expands
# EVERY word of a `local` statement before the builtin assigns any of them. So
#
#     local BD="$1" SRC="${BD}/system/${DROPIN_BACKUP_NAME}"
#
# expands ${BD} while BD is still whatever the enclosing scope had — nothing —
# and under the script's own `set -u` that aborts the entire upgrade at the
# first restore. bash -n accepts it. shellcheck accepts it. The four syntax
# gates accept it. It only appears when the function is RUN with nothing else
# in scope.
#
# The earlier harness missed it exactly once, because a call-site block had
# left a global BD lying around and the function silently read that instead.
# So this file runs the real functions with BD and SRC scrubbed from the
# environment and refuses to start if either is defined.
#
# No modes involved: runs anywhere.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "drop-in functions run with only their argument in scope"

UP="$(tm_upgrade_sh)"
SECRET='CANARY-SECRET-5c1d'

_build() {
    local h="$1"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'FAKEROOT="$1"; ACTION="$2"; _A="${3:-}"'
        # The guard that makes this control mean anything. Any variable the
        # functions declare `local` must NOT already exist here, or an unset
        # read would silently find a value and the defect would hide again.
        echo 'for _v in BD SRC f rel; do'
        echo '  if declare -p "$_v" >/dev/null 2>&1; then'
        echo '    echo "HARNESS LEAK: a global named $_v exists — this control proves nothing" >&2'
        echo '    exit 91'
        echo '  fi'
        echo 'done'
        echo 'RED=""; GREEN=""; YELLOW=""; BOLD=""; NC=""'
        echo 'info() { echo "[INFO] $*"; }'
        echo 'warn() { echo "[WARN] $*"; }'
        echo 'SERVICE="topic-manager"'
        echo 'DROPIN_DIR="${FAKEROOT}/etc/systemd/system/${SERVICE}.service.d"'
        echo
        tm_extract_line "$UP" '^fail\(\)'
        tm_extract_line "$UP" '^DROPIN_BACKUP_NAME='
        echo
        tm_extract_func "$UP" backup_dropin
        echo
        tm_extract_func "$UP" verify_dropin_backed_up
        echo
        tm_extract_func "$UP" restore_dropin
        echo
        echo 'case "$ACTION" in'
        echo '  backup)  backup_dropin "$_A" ;;'
        echo '  verify)  verify_dropin_backed_up "$_A" ;;'
        echo '  restore) restore_dropin "$_A" ;;'
        echo '  *) echo "unknown action" >&2; exit 99 ;;'
        echo 'esac'
        echo 'echo "COMPLETED $ACTION"'
    } > "$h"
}

FR=""; DD=""; BK=""
_mkhost() {
    FR="$TM_TMP/root"; DD="$FR/etc/systemd/system/topic-manager.service.d"; BK="$TM_TMP/backup"
    rm -rf "$FR" "$BK"; mkdir -p "$DD" "$BK/system"
    printf '[Service]\nEnvironment=TM_SECRET_KEY=%s\n' "$SECRET" > "$DD/override.conf"
    _build "$TM_TMP/lh.sh"
}

# env -u is the belt; the in-harness `declare -p` guard is the braces.
_do() {
    RC=0
    env -u BD -u SRC -u f -u rel bash "$TM_TMP/lh.sh" "$FR" "$1" "$BK" > "$TM_TMP/out" 2>&1 || RC=$?
}

l_restore_runs_with_nothing_in_scope() {
    _mkhost
    _do backup;  tm_assert_rc 0 "$RC" "$(cat "$TM_TMP/out")"
    rm -rf "$DD"
    _do restore
    tm_assert_ne 91 "$RC" "the harness leaked a global — see the note at the top of this file"
    tm_assert_rc 0 "$RC" \
        "restore_dropin aborted with only its argument in scope. Under set -u this kills the whole upgrade at the first restore: $(cat "$TM_TMP/out")"
    tm_assert_grep "COMPLETED restore" "$TM_TMP/out" "restore_dropin did not return"
    tm_assert_grep "$SECRET" "$DD/override.conf" "the restore returned without the secret"
}
tm_case "restore_dropin-runs-with-only-its-argument" none l_restore_runs_with_nothing_in_scope

l_backup_runs_with_nothing_in_scope() {
    _mkhost
    _do backup
    tm_assert_ne 91 "$RC" "the harness leaked a global"
    tm_assert_rc 0 "$RC" "backup_dropin aborted with only its argument in scope: $(cat "$TM_TMP/out")"
    tm_assert_grep "COMPLETED backup" "$TM_TMP/out" ""
}
tm_case "backup_dropin-runs-with-only-its-argument" none l_backup_runs_with_nothing_in_scope

l_verify_runs_with_nothing_in_scope() {
    _mkhost
    _do backup
    _do verify
    tm_assert_ne 91 "$RC" "the harness leaked a global"
    tm_assert_rc 0 "$RC" "verify_dropin_backed_up aborted with only its argument in scope: $(cat "$TM_TMP/out")"
    tm_assert_grep "COMPLETED verify" "$TM_TMP/out" ""
}
tm_case "verify_dropin_backed_up-runs-with-only-its-argument" none l_verify_runs_with_nothing_in_scope

l_static_scan() {
    # A STATIC scan, labelled as such — the three cases above are the real
    # controls. This one catches the same class being reintroduced anywhere
    # else in the script, where no behaviour test happens to reach.
    # Full-line comments are stripped first: the fix's own explanatory comment
    # quotes the broken form.
    sed -E 's/^[[:space:]]*#.*//' "$UP" \
        | grep -nE 'local[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=.*[[:space:]][A-Za-z_][A-Za-z0-9_]*=.*\$\{?\1' \
        > "$TM_TMP/hits" 2>/dev/null || true
    if [ -s "$TM_TMP/hits" ]; then
        _tm_afail "a 'local' statement references one of its own names, which expands BEFORE assignment:
$(sed 's/^/          /' "$TM_TMP/hits")
        Split it into separate 'local' statements."
    fi
}
tm_case "static-no-local-references-its-own-name" none l_static_scan

tm_finish
