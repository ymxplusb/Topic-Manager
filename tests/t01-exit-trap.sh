#!/usr/bin/env bash
# =============================================================================
# t01 — THE ERR-vs-EXIT TRAP.
#
# THE DEFECT (found 2026-08-30, WO-0001): the automatic rollback was armed with
#   trap rollback ERR
# and bash does NOT fire an ERR trap on `exit`. fail() ends in `exit 1`, so on
# all 16 fail() call sites that sit AFTER the destructive phase the advertised
# "rolls back automatically on any failure" did nothing at all. The script
# printed its message and left a half-upgraded host.
#
# These cases drive the REAL trap construct, extracted from the script, through
# every exit route it has to survive: a fail() after the destructive phase, a
# set -e abort, the --audit-only exit 2, and the success path.
#
# No file modes are involved, so this file runs anywhere bash runs.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "automatic rollback fires on exit(), not just on ERR"

UP="$(tm_upgrade_sh)"

# ─── build a harness around the real trap construct ──────────────────────────
_build() {   # _build <path>
    local h="$1"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'MARKER="$1"; SCENARIO="$2"'
        echo 'RED=""; GREEN=""; YELLOW=""; BOLD=""; NC=""'
        echo 'info()    { echo "[INFO] $*"; }'
        echo 'warn()    { echo "[WARN] $*"; }'
        echo 'success() { echo "[OK] $*"; }'
        echo 'phase()   { echo "== $* =="; }'
        echo 'BACKUP_DIR="/nonexistent/backup-dir"'
        # The one stub: restoring a real host is not what is under test here.
        # Whether it is REACHED is exactly what is under test.
        echo 'restore_from_backup() { echo "ROLLBACK-RAN $1" >> "$MARKER"; return 0; }'
        echo
        tm_extract_line "$UP" '^fail\(\)'
        tm_extract_line "$UP" '^RESTORE_POINT_READY=false$'
        tm_extract_line "$UP" '^DESTRUCTIVE_STARTED=false$'
        echo
        tm_extract_func "$UP" rollback
        echo
        tm_extract_func "$UP" _on_exit
        # Deliberately loose on the SIGNAL: anchoring on "EXIT" would make the
        # ERR-vs-EXIT mutation break its own extraction, and a control that
        # cannot be applied proves nothing. Whatever signal the script
        # registers is what these scenarios are driven through.
        tm_extract_line "$UP" '^trap _on_exit [A-Z]+$'
        echo
        cat <<'EOS'
case "$SCENARIO" in
  fail_after_destructive)
        DESTRUCTIVE_STARTED=true; RESTORE_POINT_READY=true
        fail "simulated Phase 8 failure"
        ;;
  seterr_after_destructive)
        DESTRUCTIVE_STARTED=true; RESTORE_POINT_READY=true
        false
        ;;
  exit3_after_destructive)
        DESTRUCTIVE_STARTED=true; RESTORE_POINT_READY=true
        exit 3
        ;;
  destructive_no_restore_point)
        DESTRUCTIVE_STARTED=true; RESTORE_POINT_READY=false
        fail "simulated failure with no verified backup"
        ;;
  audit_blockers)
        # --audit-only reporting BLOCK findings: a verdict, not a failed upgrade
        exit 2
        ;;
  zero_exit_destructive)
        DESTRUCTIVE_STARTED=true; RESTORE_POINT_READY=true
        exit 0
        ;;
  success_trap_cleared)
        DESTRUCTIVE_STARTED=true; RESTORE_POINT_READY=true
        trap - EXIT
        exit 0
        ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 99 ;;
esac
EOS
    } > "$h"
}

# _drive <scenario> — runs the harness, leaves rc in RC, output in $TM_TMP/out,
# rollback evidence in $TM_TMP/marker (absent when rollback did not run).
_drive() {
    local scenario="$1"
    rm -f "$TM_TMP/marker"
    _build "$TM_TMP/h.sh"
    RC=0
    bash "$TM_TMP/h.sh" "$TM_TMP/marker" "$scenario" > "$TM_TMP/out" 2>&1 || RC=$?
}

# ─── cases ───────────────────────────────────────────────────────────────────
c_fail_after_destructive() {
    _drive fail_after_destructive
    tm_assert_rc 1 "$RC" "fail() must still exit 1 through the trap"
    tm_assert_file "$TM_TMP/marker" \
        "ROLLBACK DID NOT RUN after fail() past the destructive phase — this is the ERR-vs-EXIT defect"
    tm_assert_grep "ROLLBACK-RAN /nonexistent/backup-dir" "$TM_TMP/marker" \
        "rollback must restore from BACKUP_DIR"
    tm_assert_grep "UPGRADE FAILED" "$TM_TMP/out" "the operator must be told a rollback happened"
}
tm_case "rollback-runs-on-fail-after-destructive" none c_fail_after_destructive

c_seterr_after_destructive() {
    _drive seterr_after_destructive
    tm_assert_rc 1 "$RC" ""
    tm_assert_file "$TM_TMP/marker" "rollback must also run on a set -e abort"
}
tm_case "rollback-runs-on-set-e-abort" none c_seterr_after_destructive

c_exit_code_preserved() {
    _drive exit3_after_destructive
    tm_assert_rc 3 "$RC" "the trap must re-raise the ORIGINAL exit code, not flatten it"
    tm_assert_file "$TM_TMP/marker" "any non-zero exit after the destructive phase rolls back"
}
tm_case "exit-code-survives-the-trap" none c_exit_code_preserved

c_no_rollback_on_audit() {
    _drive audit_blockers
    tm_assert_rc 2 "$RC" "--audit-only must keep its exit 2 verdict"
    tm_assert_nofile "$TM_TMP/marker" \
        "rollback ran on the --audit-only path, which has changed NOTHING to roll back"
    tm_assert_nogrep "UPGRADE FAILED" "$TM_TMP/out" \
        "an audit verdict must not be announced as a failed upgrade"
}
tm_case "no-rollback-on-audit-only-exit-2" none c_no_rollback_on_audit

c_no_rollback_on_success() {
    _drive success_trap_cleared
    tm_assert_rc 0 "$RC" ""
    tm_assert_nofile "$TM_TMP/marker" "rollback ran on the SUCCESS path"
}
tm_case "no-rollback-on-success" none c_no_rollback_on_success

c_no_rollback_on_zero_exit() {
    # The trap is still armed here. rc is 0, so nothing may be rolled back —
    # this is what makes the `[[ $rc -ne 0 ]]` test in _on_exit load-bearing.
    _drive zero_exit_destructive
    tm_assert_rc 0 "$RC" ""
    tm_assert_nofile "$TM_TMP/marker" \
        "a zero exit rolled back — the trap is not testing the exit code"
}
tm_case "no-rollback-on-zero-exit-with-trap-armed" none c_no_rollback_on_zero_exit

c_no_restore_point() {
    _drive destructive_no_restore_point
    tm_assert_rc 1 "$RC" ""
    tm_assert_nofile "$TM_TMP/marker" \
        "rollback restored from a backup that was never verified ready"
    tm_assert_grep "No verified backup exists" "$TM_TMP/out" \
        "the operator must be told manual recovery is needed"
}
tm_case "rollback-refuses-without-a-verified-restore-point" none c_no_restore_point

c_wiring() {
    # A WIRING assertion, deliberately labelled as one: the cases above prove
    # the consequence, this only proves nobody re-armed the rollback on ERR.
    grep -nE '^[[:space:]]*trap .*ERR' "$UP" > "$TM_TMP/errtraps" 2>/dev/null || true
    if [ -s "$TM_TMP/errtraps" ]; then
        _tm_afail "an ERR trap is registered in $(basename "$UP") — it will not fire on exit: $(cat "$TM_TMP/errtraps")"
    fi
}
tm_case "wiring-no-ERR-trap-reintroduced" none c_wiring

tm_finish
