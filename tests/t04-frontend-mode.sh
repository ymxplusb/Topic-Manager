#!/usr/bin/env bash
# =============================================================================
# t04 — THE FRONTEND MODE DERIVATION.
#
# THE DEFECT: newly deployed frontend files were given `chmod u+rw,go+r`
# unconditionally. On a tree deliberately kept 0750 root:www-data that silently
# grants world read on every new file — the upgrade quietly widens a hardening
# decision the operator made on purpose. The fix derives the file mode from the
# DIRECTORY's own mode (dir & 0666), so a 750 tree yields 640, not 644.
#
# The second half matters as much: the script then MEASURES access rather than
# assuming it, and if widening a file still does not make it readable (the
# blocker is usually traversal on a parent), it must REVERT the widening rather
# than leave the host loosened for no benefit.
#
# can_access is stubbed here on purpose: this file tests what the block DECIDES
# given a kernel answer. That can_access tells the truth about the kernel is
# tested in t03, against the real kernel, as the real principal.
#
# Needs a filesystem that holds modes. Skipped, loudly, on Git Bash.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "new frontend files take the directory's mode, not a fixed go+r"

UP="$(tm_upgrade_sh)"

_build() {
    local h="$1"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'FAKEROOT="$1"; CA_MODE="$2"; PERM_BASELINE="$3"'
        echo 'RED=""; GREEN=""; YELLOW=""; BOLD=""; NC=""'
        echo 'info() { echo "[INFO] $*"; }'
        echo 'warn() { echo "[WARN] $*"; }'
        echo 'FRONTEND_DIR="${FAKEROOT}/var/www/topic-manager"'
        echo 'WEB_USER="'"$TM_WEB_USER"'"'
        echo 'case "$FRONTEND_DIR" in'
        echo '  "$FAKEROOT"/*) ;;'
        echo '  *) echo "REFUSING: FRONTEND_DIR escaped the fake root" >&2; exit 90 ;;'
        echo 'esac'
        echo '_CA_STATE="${FAKEROOT}/.can-access-was-called"'
        echo 'can_access() {'
        echo '  case "$CA_MODE" in'
        echo '    yes) return 0 ;;'
        echo '    no)  return 1 ;;'
        echo '    no-then-yes) if [ -e "$_CA_STATE" ]; then return 0; fi; : > "$_CA_STATE"; return 1 ;;'
        echo '    *) echo "bad CA_MODE" >&2; exit 99 ;;'
        echo '  esac'
        echo '}'
        echo
        tm_extract_between "$UP" '^FE_DIR_MODE="\$\(stat ' '^\[\[ \$DEVIATED -gt 0 \]\]'
        echo
        # The extracted block ends on `[[ $DEVIATED -gt 0 ]] && warn ...`, which
        # returns 1 when nothing deviated. Harmless mid-script; as the last
        # command of this harness it would be read as a failure.
        echo 'exit 0'
    } > "$h"
}

FR=""; FE=""; BL=""
_mkhost() {   # _mkhost <frontend-dir-mode>
    FR="$TM_TMP/root"; FE="$FR/var/www/topic-manager"; BL="$TM_TMP/permissions.baseline"
    rm -rf "$FR"; : > "$BL"
    mkdir -p "$FE/app"
    printf 'console.log(1)\n' > "$FE/app/main.js"
    chmod "$1" "$FE" "$FE/app"
    _build "$TM_TMP/fh.sh"
}
_do() { RC=0; bash "$TM_TMP/fh.sh" "$FR" "$1" "$BL" > "$TM_TMP/out" 2>&1 || RC=$?; }

# ─── the derivation itself ───────────────────────────────────────────────────
f_750_tree_yields_640() {
    _mkhost 750
    chmod 666 "$FE/app/main.js"          # whatever it arrived as
    _do yes; tm_assert_rc 0 "$RC" "$(cat "$TM_TMP/out")"
    tm_assert_ne  644 "$(tm_mode "$FE/app/main.js")" \
        "a new file in a 0750 tree was given 644 — the upgrade widened the host's own access model"
    tm_assert_mode 640 "$FE/app/main.js" "the file mode was not derived from the directory mode"
}
tm_case "new-file-in-a-750-tree-lands-640-not-644" modes f_750_tree_yields_640

f_755_tree_yields_644() {
    _mkhost 755
    chmod 600 "$FE/app/main.js"
    _do yes; tm_assert_rc 0 "$RC" ""
    tm_assert_mode 644 "$FE/app/main.js" "an ordinary 0755 tree must still yield 0644"
}
tm_case "new-file-in-a-755-tree-lands-644" modes f_755_tree_yields_644

f_execute_bit_is_dropped() {
    # The mask is 0666, not 0777: a data file must never inherit the
    # directory's execute bit.
    _mkhost 750
    chmod 777 "$FE/app/main.js"
    _do yes
    tm_assert_mode 640 "$FE/app/main.js" "the directory's execute bit was inherited by a served file"
}
tm_case "derived-mode-drops-the-execute-bit" modes f_execute_bit_is_dropped

f_new_directory_takes_the_directory_mode() {
    _mkhost 750
    mkdir -p "$FE/lib"; chmod 777 "$FE/lib"
    _do yes
    tm_assert_mode 750 "$FE/lib" "a new directory did not take the frontend directory's mode"
}
tm_case "new-directory-takes-the-tree-mode" modes f_new_directory_takes_the_directory_mode

f_recorded_file_is_left_alone() {
    # A path with a recorded baseline entry has already been restored verbatim.
    # Touching it here would undo the STIG-safe half of the restore.
    _mkhost 750
    printf '%s|root|root|600\n' "$FE/app/main.js" > "$BL"
    chmod 600 "$FE/app/main.js"
    _do yes
    tm_assert_mode 600 "$FE/app/main.js" \
        "a file with a recorded baseline was re-chmodded, overwriting the mode the restore had just put back"
}
tm_case "recorded-files-are-skipped-by-the-new-file-pass" modes f_recorded_file_is_left_alone

# ─── measure, do not assume ──────────────────────────────────────────────────
f_widening_that_helps_is_reported() {
    _mkhost 750
    _do no-then-yes; tm_assert_rc 0 "$RC" ""
    tm_assert_mode 644 "$FE/app/main.js" \
        "the file was not widened even though the kernel said the web user could not read it"
    tm_assert_grep "widened beyond the host's model" "$TM_TMP/out" \
        "a deviation from the host's own model must be reported, not silent"
}
tm_case "widening-that-achieves-access-is-declared" modes f_widening_that_helps_is_reported

f_widening_that_fails_is_reverted() {
    # The case that was asked for: if go+r does not achieve access, the host is
    # left loosened for nothing. It must go back.
    _mkhost 750
    _do no; tm_assert_rc 0 "$RC" ""
    tm_assert_mode 640 "$FE/app/main.js" \
        "widening did not achieve access and was NOT reverted — the host is now looser with no benefit"
    tm_assert_grep "does not help" "$TM_TMP/out" "the real cause must be named"
    tm_assert_grep "traversal"     "$TM_TMP/out" "the operator must be pointed at the parent directories"
    tm_assert_nogrep "widened beyond the host's model" "$TM_TMP/out" \
        "a reverted widening must not be counted as an accepted deviation"
}
tm_case "widening-that-does-not-help-is-reverted" modes f_widening_that_fails_is_reverted

tm_finish
