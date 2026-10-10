#!/usr/bin/env bash
# =============================================================================
# t04 — THE SERVED TREE TAKES THE RELEASE'S MODES, AND THE HOST'S ACCESS MODEL.
#
# v1.3.1 (throwaway test, 2026-10-09, P1). A host installed online by v1.0.6
# carries lib/vue.global.prod.js at 0600: its install.sh fetched Vue with
# mktemp and `rsync -a` kept mktemp's mode. It served only because www-data
# OWNED the file. The 1.3.0 upgrade replayed that recorded 0600 (the
# permission baseline) and then made root the owner, so www-data could not
# read it, the Phase 12 effective-access re-audit failed and the upgrade
# rolled back. The workaround was TROUBLESHOOTING's chmod -R.
#
# THE FIX: every file in the served tree is the release's (Phase 9 empties it
# and lays it down), so its mode comes from the release, never from the old
# tree's per-file baseline. What the host decided is the tree's ACCESS MODEL,
# read from the directory itself, and that is kept:
#   * world-readable (o+r on the directory): root:root, 0755 / 0644;
#   * group-scoped (a STIG's 0750 root:www-data): 0750 / 0640, the group the
#     web account reads through; other gets nothing.
# Every OTHER recorded path keeps exactly the mode the baseline replays —
# a deliberately narrowed operator permission is never widened.
#
# The Phase 10 cases run the REAL Phase 10 permission block on a fake root
# and ask the KERNEL, as the web account, whether it can read the file. They
# need Linux as root with a www-data account and SKIP loudly elsewhere.
# (Until v1.3.1 this file tested the per-file derivation that replayed the
# baseline and only gave NEW files the directory's mode — the defect.)
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "the served tree takes the release's modes; narrowed operator paths are kept"

UP="$(tm_upgrade_sh)"

# ─── the function itself ─────────────────────────────────────────────────────
_fn() {   # _fn <dir> [web-user] — normalise_frontend_ownership as the script has it
    {
        echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }; info() { echo "[INFO] $*"; }'
        # T_GROUPS: the web account's group list as `id -nG` would print it,
        # for a membership the container cannot hold without editing /etc/group.
        echo 'if [ -n "${T_GROUPS:-}" ]; then id() { if [ "$1" = -nG ]; then echo "$T_GROUPS"; else command id "$@"; fi; }; fi'
        # T_FINDSPY: before each find that sets modes, record the modes of
        # every directory in the tree (who could still write while it runs).
        echo 'if [ -n "${T_FINDSPY:-}" ]; then find() { case " $* " in *" chmod "*) command find "$1" -type d -printf "%m %p\n" >> "$T_FINDSPY" ;; esac; command find "$@"; }; fi'
        tm_extract_func "$UP" normalise_frontend_ownership
        echo 'normalise_frontend_ownership "$1" "$2"'
    } > "${TM_TMP}/fn.sh"
    RC=0; bash "${TM_TMP}/fn.sh" "$1" "${2:-$TM_WEB_USER}" > "${TM_TMP}/out" 2>&1 || RC=$?
}
_tree() {   # _tree <dir> <owner:group> <dirmode> — index, app/, lib/vue at 0600
    mkdir -p "$1/app/components" "$1/lib"
    printf 'x\n' > "$1/index.html"; printf 'y\n' > "$1/app/components/a.js"
    printf 'vue\n' > "$1/lib/vue.global.prod.js"
    chown -R "$2" "$1"; find "$1" -type d -exec chmod "$3" {} +
    chmod 644 "$1/index.html" "$1/app/components/a.js"; chmod 600 "$1/lib/vue.global.prod.js"
}

f_stock_tree_is_755_644() {
    local d="${TM_TMP}/fe"
    _tree "$d" "${TM_WEB_USER}:${TM_WEB_USER}" 755
    chmod 777 "$d/app/components/a.js"; chmod 775 "$d/app"
    _fn "$d"; tm_assert_rc 0 "$RC" "$(cat "${TM_TMP}/out")"
    tm_assert_mode 644 "$d/lib/vue.global.prod.js" "THROWAWAY P1: a 0600 Vue in a world-readable tree kept the old tree's 0600"
    tm_assert_owner "root:root" "$d/lib/vue.global.prod.js" "the served tree is not root-owned"
    tm_assert_mode 644 "$d/app/components/a.js" "a served file kept execute or group/other write"
    tm_assert_mode 755 "$d/app" "a directory kept group write"
    tm_assert_mode 755 "$d/lib" "a directory is not 0755"
}
tm_case "a-world-readable-tree-is-root-root-755-644-whatever-its-files-were" modes,chown f_stock_tree_is_755_644

f_write_is_closed_before_the_modes_are_set() {
    # The exact modes are set by find ... -exec chmod, which acts on a NAME
    # found a moment earlier. On a tree whose directories were group- or
    # world-writable (an old www-data 0775 tree), anyone with that write
    # could swap a name for a symlink in between and have root chmod the
    # target. So group/other write is closed on the whole tree FIRST.
    local d="${TM_TMP}/fe"
    _tree "$d" "${TM_WEB_USER}:${TM_WEB_USER}" 777
    export T_FINDSPY="${TM_TMP}/spy"; : > "$T_FINDSPY"
    _fn "$d"; unset T_FINDSPY
    tm_assert_rc 0 "$RC" "$(cat "${TM_TMP}/out")"
    [ -s "${TM_TMP}/spy" ] || tm_die "the find spy recorded nothing: the mode-setting finds were not seen"
    awk '{ m = $1; if (m ~ /[2367]$/ || m ~ /[2367].$/) { print; bad = 1 } } END { exit bad }' "${TM_TMP}/spy" > "${TM_TMP}/open" \
        || _tm_afail "group/other could still write the served tree while root set its modes by name: $(cat "${TM_TMP}/open")"
}
tm_case "write-is-closed-before-modes-are-set-by-name" modes,chown f_write_is_closed_before_the_modes_are_set

f_group_scoped_tree_is_kept_group_scoped() {
    local d="${TM_TMP}/fe"
    _tree "$d" "root:${TM_WEB_USER}" 750
    chmod 640 "$d/index.html"; chmod 660 "$d/app/components/a.js"
    _fn "$d"; tm_assert_rc 0 "$RC" "$(cat "${TM_TMP}/out")"
    tm_assert_owner "root:${TM_WEB_USER}" "$d/index.html" "a group-scoped (STIG) tree lost the group nginx reads it through"
    tm_assert_mode 640 "$d/index.html" "a group-scoped tree was WIDENED to other"
    tm_assert_mode 640 "$d/lib/vue.global.prod.js" "THROWAWAY P1: the 0600 Vue in a group-scoped tree is unreadable by its group"
    tm_assert_mode 640 "$d/app/components/a.js" "group write survived"
    tm_assert_mode 750 "$d/app" "a 0750 directory was widened"
}
tm_case "a-group-scoped-tree-stays-group-scoped-and-readable" modes,chown f_group_scoped_tree_is_kept_group_scoped

f_umask077_tree_reads_through_the_web_group() {
    # A tree laid down under umask 077 and chowned to the web account: 0700
    # www-data. No other access was the host's model; the web account still
    # has to read it once root owns it.
    local d="${TM_TMP}/fe"
    _tree "$d" "${TM_WEB_USER}:${TM_WEB_USER}" 700
    _fn "$d"; tm_assert_rc 0 "$RC" "$(cat "${TM_TMP}/out")"
    tm_assert_owner "root:${TM_WEB_USER}" "$d/lib/vue.global.prod.js" "a 0700 web-owned tree did not get the web group"
    tm_assert_mode 640 "$d/lib/vue.global.prod.js" "a file of a no-other tree is not 0640"
    tm_assert_mode 750 "$d" "the top of a no-other tree is not 0750"
}
tm_case "a-no-other-tree-owned-by-the-web-account-reads-through-its-group" modes,chown f_umask077_tree_reads_through_the_web_group

f_foreign_group_is_replaced_by_the_web_group() {
    # A group-scoped tree whose group the web account is NOT in could never be
    # served by a root owner: the web account's own group replaces it.
    local d="${TM_TMP}/fe"
    _tree "$d" "root:root" 750
    id -nG "$TM_WEB_USER" > "${TM_TMP}/groups"
    tm_assert_nogrep "root" "${TM_TMP}/groups" "precondition: ${TM_WEB_USER} is in group root"
    _fn "$d"; tm_assert_rc 0 "$RC" "$(cat "${TM_TMP}/out")"
    tm_assert_owner "root:$(id -gn "$TM_WEB_USER")" "$d/index.html" "the tree kept a group the web account cannot read through"
    tm_assert_mode 640 "$d/index.html" "other was given access"
}
tm_case "a-group-the-web-account-is-not-in-is-replaced" modes,chown f_foreign_group_is_replaced_by_the_web_group

f_symlink_is_refused() {
    local d="${TM_TMP}/fe"
    _tree "$d" "root:root" 755
    printf 'secret\n' > "${TM_TMP}/elsewhere"; chmod 600 "${TM_TMP}/elsewhere"
    ln -s "${TM_TMP}/elsewhere" "$d/lib/evil.js"
    _fn "$d"
    tm_assert_ne 0 "$RC" "a symlink inside the served tree was accepted"
    tm_assert_mode 600 "${TM_TMP}/elsewhere" "a mode was changed THROUGH a symlink"
    # The tree itself a symlink: refused before anything is changed.
    mkdir -p "${TM_TMP}/real"; printf 'z\n' > "${TM_TMP}/real/f"; chmod 600 "${TM_TMP}/real/f"
    ln -s "${TM_TMP}/real" "${TM_TMP}/fe-link"
    _fn "${TM_TMP}/fe-link"
    tm_assert_ne 0 "$RC" "a served tree that is itself a symlink was accepted"
    # ... and said as what it is: the find below would also stop on it, but
    # calling the tree's own link "a symlink inside the served tree" sends
    # the operator looking in the wrong place (M877 survived without this).
    tm_assert_grep "fe-link is a symlink; refusing to re-own the frontend through it" "${TM_TMP}/out" \
        "a symlinked served tree is not named as such"
    tm_assert_mode 600 "${TM_TMP}/real/f" "a mode was changed through the symlinked tree"
}
tm_case "a-symlink-in-the-served-tree-is-refused" modes,symlinks f_symlink_is_refused

f_traverse_only_tree_is_group_scoped() {
    # Other may TRAVERSE but not read (0711): no read for other was the
    # host's model, so the tree is group-scoped, never made world-readable.
    local d="${TM_TMP}/fe"
    _tree "$d" "root:${TM_WEB_USER}" 711
    _fn "$d"; tm_assert_rc 0 "$RC" "$(cat "${TM_TMP}/out")"
    tm_assert_mode 640 "$d/index.html" "a tree other could not read was made world-readable"
    tm_assert_mode 750 "$d/app" "a traverse-only tree's directory gave other access"
}
tm_case "a-traverse-only-tree-is-not-made-world-readable" modes,chown f_traverse_only_tree_is_group_scoped

f_secondary_group_is_kept() {
    # A group-scoped tree whose group the web account reads through as a
    # SECONDARY group (an operator's reader group): kept, not swapped for the
    # web account's own group.
    local d="${TM_TMP}/fe" g
    g="$(getent group | cut -d: -f1 | grep -vx -e root -e "$(id -gn "$TM_WEB_USER")" | sed -n 1p)"
    tm_assert_nonempty "$g" "no second group to test with"
    _tree "$d" "root:${g}" 750
    export T_GROUPS="$(id -gn "$TM_WEB_USER") ${g}"
    _fn "$d"; unset T_GROUPS
    tm_assert_rc 0 "$RC" "$(cat "${TM_TMP}/out")"
    tm_assert_owner "root:${g}" "$d/index.html" "the operator's reader group was replaced though the web account is in it"
}
tm_case "a-reader-group-the-web-account-is-in-is-kept" modes,chown f_secondary_group_is_kept

f_missing_web_account_fails() {
    local d="${TM_TMP}/fe"
    _tree "$d" "root:root" 750
    _fn "$d" tm-no-such-account
    tm_assert_ne 0 "$RC" "a group-scoped tree was re-owned with no web account to read through"
    tm_assert_grep "does not exist" "${TM_TMP}/out" "the missing web account is not named"
}
tm_case "a-group-scoped-tree-with-no-web-account-stops" modes,chown f_missing_web_account_fails

# ─── the real Phase 10 block on a 1.0.x layout ───────────────────────────────
_build_phase10() {
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'FAKEROOT="$1"; ACTION="$2"; PERM_BASELINE="$3"'
        echo 'info() { echo "[INFO] $*"; }; warn() { echo "[WARN] $*"; }; success() { echo "[OK] $*"; }'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'SERVICE="topic-manager"; APP_USER="root"; WEB_USER="'"$TM_WEB_USER"'"'
        echo 'APP_HOME="${FAKEROOT}/opt/topic-manager"; VENV="${APP_HOME}/venv"'
        echo 'FRONTEND_DIR="${FAKEROOT}/var/www/topic-manager"'
        echo 'CONFIG_DIR="${FAKEROOT}/etc/topic-manager"'
        echo 'DROPIN_DIR="${FAKEROOT}/etc/systemd/system/${SERVICE}.service.d"'
        echo 'CLUSTERS_DIR="${CONFIG_DIR}/clusters.d"; CLUSTERS_FILE="${CLUSTERS_DIR}/clusters.yaml"'
        echo 'CERT_DIR="${APP_HOME}/data/cluster-certs"'
        tm_extract_between "$UP" '^BASELINE_PATHS=\(' '^\)$' | sed 's#"/#"${FAKEROOT}/#g'
        echo 'for _p in "${BASELINE_PATHS[@]}"; do case "$_p" in "$FAKEROOT"/*) ;; *) echo "REFUSING: $_p" >&2; exit 90 ;; esac; done'
        local f
        for f in record_baseline baseline_stream baseline_is_legacy baseline_assert_record \
                 baseline_lookup apply_baseline safe_install_dir enforce_audit_db_modes normalise_frontend_ownership lock_down_venv; do
            tm_extract_func "$UP" "$f"
        done
        tm_extract_line "$UP" '^baseline_has\(\)'
        tm_extract_line "$UP" '^can_access\(\)'
        echo 'if [ "$ACTION" = record ]; then record_baseline "$PERM_BASELINE"; exit 0; fi'
        tm_extract_between "$UP" '^info "Re-applying the recorded permission baseline' \
                                 '^success "Ownership and modes restored"'
    } > "${TM_TMP}/p10.sh"
}

# _host_10x <vue-owner> — the served tree and the files around it as an online
# v1.0.6 install leaves them: www-data-owned 0755/0644 with Vue 0600; plus two
# paths an operator deliberately narrowed (the TLS key 0400, the drop-in 0600).
FR=""; FE=""; KEY=""; DROP=""
_host_10x() {
    FR="${TM_TMP}/root"; FE="${FR}/var/www/topic-manager"
    local A="${FR}/opt/topic-manager"
    mkdir -p "${A}/data" "${A}/tm" "${A}/venv/bin" "${A}/logs" "${FE}/app/components" "${FE}/lib" \
             "${FR}/etc/topic-manager/tls" "${FR}/etc/systemd/system/topic-manager.service.d"
    : > "${A}/wsgi.py"; : > "${A}/data/tm.db"
    printf 'old index\n' > "${FE}/index.html"; printf 'old\n' > "${FE}/app/main.js"
    printf 'old vue\n' > "${FE}/lib/vue.global.prod.js"
    chown -R "${TM_WEB_USER}:${TM_WEB_USER}" "$FE"
    find "$FE" -type d -exec chmod 755 {} +; find "$FE" -type f -exec chmod 644 {} +
    chmod 600 "${FE}/lib/vue.global.prod.js"
    chown "$1" "${FE}/lib/vue.global.prod.js"
    KEY="${FR}/etc/topic-manager/tls/server.key"; printf 'k\n' > "$KEY"; chmod 400 "$KEY"
    DROP="${FR}/etc/systemd/system/topic-manager.service.d/override.conf"
    printf '[Service]\n' > "$DROP"; chmod 600 "$DROP"
    printf 'cfg\n' > "${FR}/etc/topic-manager/config.yaml"; chmod 600 "${FR}/etc/topic-manager/config.yaml"
    chmod 755 "$FR" "$FR/var" "$FR/var/www"
    tm_open_traversal "$FR"
}
# _deploy — what Phase 9 does to the tree: empty it, lay the release down as
# root under a umask that keeps the files private, Vue through mktemp (0600).
_deploy() {
    rm -rf "${FE:?}"/*
    ( umask 077; mkdir -p "${FE}/app/components" "${FE}/lib"
      printf 'new index\n' > "${FE}/index.html"; printf 'new\n' > "${FE}/app/main.js"
      printf 'a\n' > "${FE}/app/components/a.js"; t="$(mktemp)"; printf 'new vue\n' > "$t"
      mv "$t" "${FE}/lib/vue.global.prod.js" )
}
_p10() {   # _p10 <vue-owner>
    _host_10x "$1"
    _build_phase10
    RC=0; bash "${TM_TMP}/p10.sh" "$FR" record "${TM_TMP}/bl" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "record failed: $(cat "${TM_TMP}/out")"
    tm_assert_recorded "${TM_TMP}/bl" "${FE}/lib/vue.global.prod.js" "" "" 600 "precondition: the baseline did not record the v1.0.x 0600 Vue"
    _deploy
    RC=0; bash "${TM_TMP}/p10.sh" "$FR" phase10 "${TM_TMP}/bl" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "the Phase 10 block failed: $(cat "${TM_TMP}/out")"
}
_assert_served() {
    local f
    for f in index.html app/main.js app/components/a.js lib/vue.global.prod.js; do
        sudo -u "$TM_WEB_USER" test -r "${FE}/${f}" \
            || _tm_afail "THROWAWAY P1: after Phase 10 the KERNEL says ${TM_WEB_USER} cannot read ${f} ($(tm_owner "${FE}/${f}") $(tm_mode "${FE}/${f}")) — Phase 12 fails and the upgrade rolls back"
    done
    tm_assert_owner "root:root" "${FE}/lib/vue.global.prod.js" "the served tree is not root-owned"
    tm_assert_mode 644 "${FE}/lib/vue.global.prod.js" "Vue did not take the release's 0644"
    tm_assert_mode 755 "${FE}/app/components" "a directory the release added did not take 0755"
    # The operator's deliberately narrowed paths elsewhere: exactly as recorded.
    tm_assert_mode 400 "$KEY" "a deliberately narrowed TLS key was widened"
    tm_assert_mode 600 "$DROP" "a deliberately narrowed drop-in was widened"
    tm_assert_mode 600 "${FR}/etc/topic-manager/config.yaml" "a narrowed config.yaml was widened"
}
p_web_owned_0600_vue() { _p10 "${TM_WEB_USER}:${TM_WEB_USER}"; _assert_served; }
tm_case "phase10-a-1.0.x-tree-with-a-web-owned-0600-vue-ends-servable" modes,chown p_web_owned_0600_vue
p_root_owned_0600_vue() { _p10 "root:root"; _assert_served; }
tm_case "phase10-a-1.0.x-tree-with-a-root-owned-0600-vue-ends-servable" modes,chown p_root_owned_0600_vue

p_wired() {
    local blk
    blk="$(tm_extract_between "$UP" '^info "Re-applying the recorded permission baseline' '^success "Ownership and modes restored"')"
    grep -qx 'normalise_frontend_ownership "$FRONTEND_DIR" "$WEB_USER"' <<<"$blk" \
        || _tm_afail "Phase 10 does not give the served tree the release's modes"
    grep -q 'FE_FILE_MODE\|baseline_has "\$PERM_BASELINE" "\$f"' <<<"$blk" \
        && _tm_afail "Phase 10 still derives per-file frontend modes from the old tree's baseline"
    true
}
tm_case "phase10-calls-it-and-no-per-file-replay-remains" none p_wired

tm_finish
