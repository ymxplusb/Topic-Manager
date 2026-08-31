#!/usr/bin/env bash
# =============================================================================
# t02 — THE SYSTEMD DROP-IN BACKUP/RESTORE.
#
# THE DEFECT (found 2026-08-30, WO-0001 pass 2):
#   /etc/systemd/system/topic-manager.service.d/ is where an operator puts
#   TM_SECRET_KEY and TM_LDAP_BIND_PASSWORD when configuration lives in the
#   environment. Phase 3 READ it. The backup set did not include it. So a
#   --restore handed back a service with no secret_key — and the current code
#   raises RuntimeError rather than start without one (contract
#   hazards[secret-key-fail-open]). The backup looked complete until the day
#   somebody restored from it.
#
# Every case here drives the REAL backup_dropin / verify_dropin_backed_up /
# restore_dropin extracted from the script, against a throwaway root.
#
# NOTE ON A DELIBERATE OMISSION: this harness defines no variable called BD or
# SRC. restore_dropin uses both as locals, and an earlier version of it read an
# unset one; a harness that leaves a global BD lying around makes that defect
# invisible. See t05, which is the dedicated control for it.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "the unit drop-in is backed up, verified and restored"

UP="$(tm_upgrade_sh)"
SECRET='CANARY-SECRET-9f3a'
BINDPW='CANARY-BINDPW-7b21'

_build() {   # _build <path>
    local h="$1"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'FAKEROOT="$1"; ACTION="$2"; ARG="${3:-}"'
        echo 'RED=""; GREEN=""; YELLOW=""; BOLD=""; NC=""'
        echo 'info() { echo "[INFO] $*"; }'
        echo 'warn() { echo "[WARN] $*"; }'
        echo 'SERVICE="topic-manager"'
        # The ONE relocation: the constant is an absolute host path, so it has
        # to move for the code to be runnable at all. Guarded below so a broken
        # relocation can never let these tests touch the real /etc.
        echo 'DROPIN_DIR="${FAKEROOT}/etc/systemd/system/${SERVICE}.service.d"'
        echo 'case "$DROPIN_DIR" in'
        echo '  "$FAKEROOT"/*) ;;'
        echo '  *) echo "REFUSING: DROPIN_DIR escaped the fake root" >&2; exit 90 ;;'
        echo 'esac'
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
        echo '  backup)  backup_dropin "$ARG" ;;'
        echo '  verify)  verify_dropin_backed_up "$ARG" ;;'
        echo '  restore) restore_dropin "$ARG" ;;'
        echo '  *) echo "unknown action" >&2; exit 99 ;;'
        echo 'esac'
    } > "$h"
}

FR=""; DD=""; BK=""
_mkhost() {   # a host that keeps its secrets in the unit drop-in
    FR="$TM_TMP/root"; DD="$FR/etc/systemd/system/topic-manager.service.d"
    BK="$TM_TMP/backup"
    rm -rf "$FR" "$BK"
    mkdir -p "$DD" "$BK/system"
    printf '[Service]\nEnvironment=TM_SECRET_KEY=%s\n' "$SECRET" > "$DD/override.conf"
    printf '[Service]\nEnvironment=TM_LDAP_BIND_PASSWORD=%s\n' "$BINDPW" > "$DD/20-ldap.conf"
    chmod 600 "$DD/override.conf" "$DD/20-ldap.conf" 2>/dev/null || true
    _build "$TM_TMP/dh.sh"
}

_do() {   # _do <action> [backup-dir]
    RC=0
    bash "$TM_TMP/dh.sh" "$FR" "$1" "${2:-$BK}" > "$TM_TMP/out" 2>&1 || RC=$?
}

# ─── the consequence the whole change exists to produce ──────────────────────
c_roundtrip() {
    _mkhost
    _do backup;  tm_assert_rc 0 "$RC" "backup_dropin failed: $(cat "$TM_TMP/out")"
    rm -rf "$DD"                      # the upgrade wipes and re-creates the unit
    _do restore; tm_assert_rc 0 "$RC" "restore_dropin failed: $(cat "$TM_TMP/out")"

    tm_assert_file "$DD/override.conf" "the drop-in was NOT restored"
    tm_assert_grep "$SECRET" "$DD/override.conf" \
        "the restored service has NO TM_SECRET_KEY — it would refuse to start"
    tm_assert_file "$DD/20-ldap.conf" "only one drop-in file came back"
    tm_assert_grep "$BINDPW" "$DD/20-ldap.conf" \
        "the restored service has no LDAP bind password — every login fails"
}
tm_case "restore-returns-the-secret-key" none c_roundtrip

c_roundtrip_modes() {
    _mkhost
    _do backup
    rm -rf "$DD"
    _do restore
    tm_assert_mode 600 "$DD/override.conf" \
        "the restored secret file was widened — every local account can read TM_SECRET_KEY"
    tm_assert_mode 600 "$DD/20-ldap.conf" "the restored bind-password file was widened"
}
tm_case "restore-keeps-0600-on-secret-files" modes c_roundtrip_modes

c_restore_clears_stale() {
    _mkhost
    _do backup
    # The upgrade left something behind that the restore point does not contain.
    printf '[Service]\nEnvironment=TM_SECRET_KEY=WRONG-KEY\n' > "$DD/override.conf"
    printf 'stale\n' > "$DD/99-stale.conf"
    _do restore; tm_assert_rc 0 "$RC" ""
    tm_assert_grep   "$SECRET" "$DD/override.conf" "the stale key was not replaced"
    tm_assert_nofile "$DD/99-stale.conf" "a file absent from the restore point survived it"
}
tm_case "restore-replaces-the-live-dropin-exactly" none c_restore_clears_stale

# ─── the asymmetry, and why it is deliberate ─────────────────────────────────
c_no_backup_leaves_host_alone() {
    _mkhost
    # A backup taken before drop-in capture existed: it has no drop-in at all.
    _do restore; tm_assert_rc 0 "$RC" ""
    tm_assert_grep "$SECRET" "$DD/override.conf" \
        "restoring from an older backup DELETED the only copy of the secret key"
    tm_assert_grep "LEFT AS IT IS" "$TM_TMP/out" \
        "the operator was not told the drop-in was not restored"
}
tm_case "old-backup-does-not-delete-the-live-dropin" none c_no_backup_leaves_host_alone

# ─── the completeness gate, asked before anything is touched ─────────────────
c_verify_complete() {
    _mkhost
    _do backup
    _do verify; tm_assert_rc 0 "$RC" "a complete backup was refused: $(cat "$TM_TMP/out")"
}
tm_case "verify-accepts-a-complete-backup" none c_verify_complete

c_verify_incomplete() {
    _mkhost
    _do backup
    printf '[Service]\nEnvironment=TM_SECRET_KEY=%s\n' "$SECRET" > "$DD/30-added-later.conf"
    _do verify
    tm_assert_rc 1 "$RC" \
        "a drop-in file that never reached the backup was accepted — the run would proceed"
    tm_assert_grep "did not reach the backup" "$TM_TMP/out" "the refusal must name the reason"
}
tm_case "verify-refuses-an-incomplete-backup" none c_verify_incomplete

# ─── the host we actually have ───────────────────────────────────────────────
c_host_without_dropin() {
    # PROD (192.168.202.90) has NO drop-in directory at all. Every one of these
    # paths must be a clean no-op there, not an abort under `set -e`.
    _mkhost
    rm -rf "$DD"
    _do backup;  tm_assert_rc 0 "$RC" "backup_dropin aborted on a host with no drop-in"
    _do verify;  tm_assert_rc 0 "$RC" "verify aborted on a host with no drop-in"
    _do restore; tm_assert_rc 0 "$RC" "restore aborted on a host with no drop-in"
    tm_assert_nofile "$DD" "restore invented a drop-in directory from nothing"
}
tm_case "no-dropin-on-the-host-is-a-clean-no-op" none c_host_without_dropin

# ─── wiring (labelled as such: consequence is proven above) ──────────────────
c_wiring() {
    local n
    n="$(grep -cE '^[[:space:]]*backup_dropin "' "$UP" || true)"
    [ "${n:-0}" -ge 1 ] || _tm_afail "backup_dropin is defined but never CALLED"
    n="$(grep -cE '^[[:space:]]*verify_dropin_backed_up "' "$UP" || true)"
    [ "${n:-0}" -ge 1 ] || _tm_afail "verify_dropin_backed_up is defined but never CALLED"
    n="$(grep -cE '^[[:space:]]*restore_dropin "' "$UP" || true)"
    [ "${n:-0}" -ge 2 ] || _tm_afail \
        "restore_dropin has ${n:-0} call site(s); it needs at least two — restore_from_backup (used by --restore AND the automatic rollback) and Phase 10"
}
tm_case "wiring-all-three-functions-are-called" none c_wiring

tm_finish
