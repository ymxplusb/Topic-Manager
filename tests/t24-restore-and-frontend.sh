#!/usr/bin/env bash
# =============================================================================
# t24 — ROUND 2: WHAT A ROLLBACK PUTS BACK, AND WHO OWNS THE SERVED TREE.
#
#   * restore_cluster_store (adversary F5, treated as HIGH): the backup took
#     clusters.d/ and cluster-certs/ and restore_from_backup never put them
#     back. Driven through the REAL function against a fake root.
#   * the frontend is ROOT-owned: install.sh makes it root:root 0755/0644; the
#     upgrade re-owns it to root and strips group/other write WITHOUT widening
#     a group-scoped (STIG) tree.
#   * a failed SQLite snapshot blocks the upgrade; the Vue backup fallback is
#     held to the pinned SHA-256.
#
# Mode/owner cases need Linux as root and SKIP loudly elsewhere.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "restore puts the cluster store back; the frontend is root-owned"

UP="$(tm_upgrade_sh)"
INSTALL_SH="$(tm_install_sh)"

# ─── restore_cluster_store ───────────────────────────────────────────────────
_rcs() {   # _rcs <fakeroot> <backup-dir>
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }; info() { echo "[INFO] $*"; }'
        echo 'FR="$1"; APP_USER="'"$TM_WEB_USER"'"'
        echo 'CLUSTERS_DIR="${FR}/etc/topic-manager/clusters.d"; CLUSTERS_FILE="${CLUSTERS_DIR}/clusters.yaml"'
        echo 'CERT_DIR="${FR}/opt/topic-manager/data/cluster-certs"'
        tm_extract_func "$UP" safe_install_dir
        tm_extract_func "$UP" restore_cluster_store
        echo 'restore_cluster_store "$2"'
    } > "${TM_TMP}/rcs.sh"
    RC=0; bash "${TM_TMP}/rcs.sh" "$1" "$2" > "${TM_TMP}/out" 2>&1 || RC=$?
}
r_store_comes_back() {
    local FR="${TM_TMP}/root" BD="${TM_TMP}/backup"
    mkdir -p "$FR/etc/topic-manager/clusters.d" "$FR/opt/topic-manager/data/cluster-certs" \
             "$BD/etc/clusters.d" "$BD/data/cluster-certs"
    printf 'clusters:\n  - id: from-backup\n' > "$BD/etc/clusters.d/clusters.yaml"
    printf 'CA\n' > "$BD/data/cluster-certs/c1-ca-1.pem"; chmod 644 "$BD/data/cluster-certs/c1-ca-1.pem"
    # What the FAILED upgrade left behind.
    printf 'clusters:\n  - id: from-the-failed-run\n' > "$FR/etc/topic-manager/clusters.d/clusters.yaml"
    printf 'X\n' > "$FR/opt/topic-manager/data/cluster-certs/added-later.pem"
    _rcs "$FR" "$BD"
    tm_assert_rc 0 "$RC" "restore_cluster_store failed: $(cat "${TM_TMP}/out")"
    tm_assert_grep "from-backup" "$FR/etc/topic-manager/clusters.d/clusters.yaml" \
        "THE ROLLBACK DEFECT: the cluster list is still what the failed upgrade left"
    tm_assert_file "$FR/opt/topic-manager/data/cluster-certs/c1-ca-1.pem" "the backed-up cert did not come back"
    tm_assert_nofile "$FR/opt/topic-manager/data/cluster-certs/added-later.pem" \
        "a cert that is not in the backup survived the restore"
    tm_assert_mode 750 "$FR/etc/topic-manager/clusters.d" "clusters.d not 0750"
    tm_assert_mode 640 "$FR/etc/topic-manager/clusters.d/clusters.yaml" "clusters.yaml not 0640"
    tm_assert_mode 700 "$FR/opt/topic-manager/data/cluster-certs" "cluster-certs not 0700"
    tm_assert_mode 600 "$FR/opt/topic-manager/data/cluster-certs/c1-ca-1.pem" \
        "a restored cert file is readable beyond the service account"
    tm_assert_owner "${TM_WEB_USER}:${TM_WEB_USER}" "$FR/etc/topic-manager/clusters.d/clusters.yaml" \
        "clusters.yaml not owned by the service account after restore"
}
tm_case "restore-puts-the-cluster-store-and-certs-back" modes,chown r_store_comes_back

r_store_refuses_symlink() {
    local FR="${TM_TMP}/root" BD="${TM_TMP}/backup"
    mkdir -p "$FR/etc/topic-manager" "$FR/opt/topic-manager/data" "$BD/etc/clusters.d" "${TM_TMP}/elsewhere"
    printf 'clusters: []\n' > "$BD/etc/clusters.d/clusters.yaml"
    ln -s "${TM_TMP}/elsewhere" "$FR/etc/topic-manager/clusters.d"
    _rcs "$FR" "$BD"
    tm_assert_ne 0 "$RC" "the store was restored through a symlink the app could have planted"
}
tm_case "restore-refuses-a-symlinked-store" symlinks r_store_refuses_symlink

r_restore_calls_it() {
    grep -q '^    restore_cluster_store "\$BD"$' <<<"$(tm_extract_func "$UP" restore_from_backup)" \
        || _tm_afail "restore_from_backup (--restore and the automatic rollback) does not restore the cluster store"
}
tm_case "restore-from-backup-calls-restore-cluster-store" none r_restore_calls_it

# ─── the frontend ────────────────────────────────────────────────────────────
_fe_tree() {   # _fe_tree <dir> <owner:group> <dirmode> <filemode>
    mkdir -p "$1/app/components"; printf 'x\n' > "$1/index.html"; printf 'y\n' > "$1/app/components/a.js"
    chown -R "$2" "$1"; find "$1" -type d -exec chmod "$3" {} +; find "$1" -type f -exec chmod "$4" {} +
}
f_install_root_owned() {
    local d="${TM_TMP}/fe"
    _fe_tree "$d" "${TM_WEB_USER}:${TM_WEB_USER}" 775 664
    {
        echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'
        echo 'die() { echo "[DIE] $*" >&2; exit 1; }'
        tm_extract_func "$INSTALL_SH" normalise_frontend_install
        echo 'normalise_frontend_install "$1"'
    } > "${TM_TMP}/fi.sh"
    bash "${TM_TMP}/fi.sh" "$d" > "${TM_TMP}/out" 2>&1 || _tm_afail "failed: $(cat "${TM_TMP}/out")"
    tm_assert_owner "root:root" "$d/app/components/a.js" "install.sh left the frontend owned by the web user"
    tm_assert_mode 644 "$d/app/components/a.js" "a frontend file is not 0644"
    tm_assert_mode 755 "$d/app" "a frontend directory is not 0755"
}
tm_case "install-makes-the-frontend-root-root-0755-0644" modes,chown f_install_root_owned

_fu() {
    {
        echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }; info() { echo "[INFO] $*"; }'
        tm_extract_func "$UP" normalise_frontend_ownership
        echo 'normalise_frontend_ownership "$1"'
    } > "${TM_TMP}/fu.sh"
    bash "${TM_TMP}/fu.sh" "$1" > "${TM_TMP}/out" 2>&1 || _tm_afail "failed: $(cat "${TM_TMP}/out")"
}
f_upgrade_reowns_stock() {
    local d="${TM_TMP}/fe"
    _fe_tree "$d" "${TM_WEB_USER}:${TM_WEB_USER}" 775 664
    _fu "$d"
    tm_assert_owner "root:root" "$d/index.html" "the upgrade left a world-readable frontend owned by the web user"
    tm_assert_mode 644 "$d/index.html" "group/other write was not removed"
    tm_assert_mode 755 "$d/app" "group/other write was not removed from a directory"
}
tm_case "upgrade-re-owns-a-stock-frontend-to-root" modes,chown f_upgrade_reowns_stock

f_upgrade_never_widens_stig() {
    local d="${TM_TMP}/fe"
    _fe_tree "$d" "root:${TM_WEB_USER}" 750 640
    _fu "$d"
    tm_assert_owner "root:${TM_WEB_USER}" "$d/index.html" \
        "a group-scoped (STIG) tree lost the group nginx reads it through"
    tm_assert_mode 640 "$d/index.html" "a 0640 file was WIDENED"
    tm_assert_mode 750 "$d/app" "a 0750 directory was WIDENED"
}
tm_case "upgrade-never-widens-a-group-scoped-frontend" modes,chown f_upgrade_never_widens_stig

f_upgrade_calls_it() {
    local fe call
    fe="$(grep -n '^\[\[ \$DEVIATED -gt 0 \]\]' "$UP" | cut -d: -f1)"
    call="$(grep -n '^normalise_frontend_ownership "\$FRONTEND_DIR"$' "$UP" | cut -d: -f1)"
    tm_assert_nonempty "$call" "Phase 10 no longer re-owns the frontend"
    [ "$call" -gt "$fe" ] || _tm_afail "the re-own runs before the per-file frontend pass that sets owners"
}
tm_case "upgrade-phase10-re-owns-after-the-frontend-pass" none f_upgrade_calls_it

# ─── snapshot and Vue fallback ───────────────────────────────────────────────
s_snapshot_blocks() {
    local blk
    blk="$(awk '/^    if python3 - "\$APP_HOME" "\$BACKUP_DIR" <<.PYBACKUP./{on=1} on{print} on && /^    fi$/{exit}' "$UP" | sed -n '/^PYBACKUP$/,$p')"
    case "$blk" in
        *"else"*"fail \"SQLite consistent snapshot failed"*) ;;
        *) _tm_afail "a failed SQLite snapshot no longer blocks the upgrade: ${blk}" ;;
    esac
}
tm_case "a-failed-sqlite-snapshot-blocks-the-upgrade" none s_snapshot_blocks

v_backup_vue_is_hash_checked() {
    local B="${TM_TMP}/b"
    mkdir -p "$B/frontend/lib" "${TM_TMP}/fe/lib"
    printf 'old vue\n' > "$B/frontend/lib/vue.global.prod.js"
    {
        echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'
        echo 'warn() { echo "[WARN] $*"; }; success() { echo "[OK] $*"; }'
        echo 'BACKUP_DIR="$1"; VUE_DEST="$2"; VUE_SHA256="$3"; VUE_VERSION=x; VUE_OK=false'
        TM_S='^if \[\[ \$VUE_OK != true \]\] && \[\[ -f "\$\{BACKUP_DIR\}/frontend/lib/vue.global.prod.js" \]\]; then$' \
            awk 'BEGIN{s=ENVIRON["TM_S"]} !on && $0 ~ s {on=1} on{print} on && /^fi$/{exit}' "$UP"
        echo 'echo "VUE_OK=$VUE_OK"'
    } > "${TM_TMP}/vf.sh"
    grep -q 'sha256sum' "${TM_TMP}/vf.sh" || tm_die "could not extract the Vue backup fallback"
    local good; good="$(sha256sum "$B/frontend/lib/vue.global.prod.js" | cut -d' ' -f1)"
    bash "${TM_TMP}/vf.sh" "$B" "${TM_TMP}/fe/lib/vue.js" "$(printf '0%.0s' $(seq 64))" > "${TM_TMP}/out" 2>&1
    tm_assert_grep "VUE_OK=false" "${TM_TMP}/out" "a backed-up Vue that does NOT match the pin was served"
    tm_assert_nofile "${TM_TMP}/fe/lib/vue.js" "the unverified Vue was copied into place"
    bash "${TM_TMP}/vf.sh" "$B" "${TM_TMP}/fe/lib/vue.js" "$good" > "${TM_TMP}/out" 2>&1
    tm_assert_grep "VUE_OK=true" "${TM_TMP}/out" "a backed-up Vue that DOES match the pin was refused"
}
tm_case "the-vue-backup-fallback-is-held-to-the-pin" none v_backup_vue_is_hash_checked

tm_finish
