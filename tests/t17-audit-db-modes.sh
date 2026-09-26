#!/usr/bin/env bash
# =============================================================================
# t17 — THE AUDIT DATABASE IS PRIVATE: tm.db 0600, data/ 0700 (v1.1.0).
#
# tm.db holds the audit trail, the server-side sessions (live session ids) and
# the app settings. It used to be created under the process umask — 0644 on a
# stock host — and the upgrade's permission baseline then faithfully REPLAYED
# that 0644 on every upgrade, and cp -a put the backup's 0644 back on every
# restore. Four places now hold the line, and each is driven here:
#
#   tm/models.py            creates it 0600 / 0700 and narrows an old one
#   systemd unit            UMask=0077
#   install.sh              data/ 0700, then enforce_audit_db_modes
#   install/upgrade-full.sh enforce_audit_db_modes after the baseline replay
#                           in Phase 10 AND in restore_from_backup
#
# The mode/owner cases need Linux (Git Bash cannot hold modes) and SKIP loudly
# here:  bash tests/run.sh --remote <user>@<linux-host> --strict
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "tm.db 0600 and data/ 0700, from creation, through upgrade and restore"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
UP="$(tm_upgrade_sh)"
INSTALL_SH="$(tm_install_sh)"

_initdb() {   # _initdb <db-path>
    PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
import sys
from tm.models import init_db, get_db
cfg = {'audit': {'db_path': sys.argv[1]}}
init_db(cfg)
db = get_db(cfg); db.execute('INSERT INTO app_settings (key, value) VALUES (\"k\", \"v\")'); db.commit(); db.close()
" "$1" > "${TM_TMP}/py.out" 2>&1
}

# ─── tm/models.py ────────────────────────────────────────────────────────────
m_created_private() {
    umask 022
    _initdb "${TM_TMP}/data/tm.db" || _tm_afail "init_db failed: $(cat "${TM_TMP}/py.out")"
    tm_assert_mode 600 "${TM_TMP}/data/tm.db" \
        "tm.db was created world-readable under a stock umask — the audit trail
        and every live session id readable by every local account"
    tm_assert_mode 700 "${TM_TMP}/data" "the data directory was created wider than 0700"
}
tm_case "models-creates-tm.db-0600-and-data-0700" modes m_created_private

m_narrows_existing() {
    mkdir -p "${TM_TMP}/data"; chmod 755 "${TM_TMP}/data"
    : > "${TM_TMP}/data/tm.db"; chmod 644 "${TM_TMP}/data/tm.db"
    : > "${TM_TMP}/data/tm.db-wal"; chmod 644 "${TM_TMP}/data/tm.db-wal"
    _initdb "${TM_TMP}/data/tm.db" || _tm_afail "init_db failed: $(cat "${TM_TMP}/py.out")"
    tm_assert_mode 600 "${TM_TMP}/data/tm.db" "an existing 0644 tm.db from v1.0.x was left 0644"
    tm_assert_mode 600 "${TM_TMP}/data/tm.db-wal" "the -wal sibling (same rows) was left 0644"
    tm_assert_mode 700 "${TM_TMP}/data" "an existing 0755 data directory was left 0755"
}
tm_case "models-narrows-an-existing-database" modes m_narrows_existing

m_no_symlink_follow() {
    mkdir -p "${TM_TMP}/data" "${TM_TMP}/elsewhere"
    : > "${TM_TMP}/elsewhere/victim"; chmod 644 "${TM_TMP}/elsewhere/victim"
    ln -s "${TM_TMP}/elsewhere/victim" "${TM_TMP}/data/tm.db-shm"
    _initdb "${TM_TMP}/data/tm.db" || _tm_afail "init_db failed: $(cat "${TM_TMP}/py.out")"
    tm_assert_mode 644 "${TM_TMP}/elsewhere/victim" \
        "init_db chmodded THROUGH a symlink in the data directory"
}
tm_case "models-never-chmods-through-a-symlink" modes,symlinks m_no_symlink_follow

# ─── the unit ────────────────────────────────────────────────────────────────
u_umask() {
    grep -qx 'UMask=0077' "${TM_REPO_ROOT}/systemd/topic-manager.service" \
        || _tm_afail "topic-manager.service does not set UMask=0077"
}
tm_case "unit-sets-UMask-0077" none u_umask

# ─── enforce_audit_db_modes, in both scripts ─────────────────────────────────
e_identical() {
    tm_extract_func "$UP" enforce_audit_db_modes > "${TM_TMP}/up.fn"
    tm_extract_func "$INSTALL_SH" enforce_audit_db_modes > "${TM_TMP}/in.fn"
    cmp -s "${TM_TMP}/up.fn" "${TM_TMP}/in.fn" \
        || _tm_afail "install.sh and upgrade-full.sh carry DIFFERENT copies of
        enforce_audit_db_modes. One definition, two call sites — a fix to one copy
        is a fix to one of the two routes onto a host:
        $(diff "${TM_TMP}/up.fn" "${TM_TMP}/in.fn" | head -10)"
}
tm_case "both-scripts-carry-the-same-enforce-function" none e_identical

_build_enforce() {   # the REAL function, from the named script
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'APP_HOME="$1"; APP_USER="$(id -un)"'
        tm_extract_func "$2" safe_install_dir
        tm_extract_func "$2" enforce_audit_db_modes
        echo 'enforce_audit_db_modes'
    } > "$1.sh"
}

e_narrows() {
    local s
    for s in "$UP" "$INSTALL_SH"; do
        rm -rf "${TM_TMP}/h"; mkdir -p "${TM_TMP}/h/data"
        chmod 755 "${TM_TMP}/h/data"
        : > "${TM_TMP}/h/data/tm.db"; chmod 644 "${TM_TMP}/h/data/tm.db"
        : > "${TM_TMP}/h/data/tm.db-wal"; chmod 644 "${TM_TMP}/h/data/tm.db-wal"
        _build_enforce "${TM_TMP}/fn" "$s"
        bash "${TM_TMP}/fn.sh" "${TM_TMP}/h" > "${TM_TMP}/out" 2>&1 \
            || _tm_afail "$(basename "$s"): enforce_audit_db_modes failed: $(cat "${TM_TMP}/out")"
        tm_assert_mode 700 "${TM_TMP}/h/data"        "$(basename "$s"): data/ not 0700"
        tm_assert_mode 600 "${TM_TMP}/h/data/tm.db"  "$(basename "$s"): tm.db not 0600"
        tm_assert_mode 600 "${TM_TMP}/h/data/tm.db-wal" "$(basename "$s"): tm.db-wal not 0600"
    done
}
tm_case "enforce-narrows-db-wal-and-dir-in-both-scripts" modes e_narrows

e_refuses_symlink() {
    local s rc
    for s in "$UP" "$INSTALL_SH"; do
        rm -rf "${TM_TMP}/h" "${TM_TMP}/victim"; mkdir -p "${TM_TMP}/h/data"
        : > "${TM_TMP}/victim"; chmod 644 "${TM_TMP}/victim"
        ln -s "${TM_TMP}/victim" "${TM_TMP}/h/data/tm.db"
        _build_enforce "${TM_TMP}/fn" "$s"
        rc=0; bash "${TM_TMP}/fn.sh" "${TM_TMP}/h" > "${TM_TMP}/out" 2>&1 || rc=$?
        tm_assert_ne 0 "$rc" "$(basename "$s"): chmodded tm.db through a symlink the app could have planted"
        tm_assert_grep "is a symlink" "${TM_TMP}/out" "$(basename "$s"): the refusal did not say why"
        tm_assert_mode 644 "${TM_TMP}/victim" "$(basename "$s"): the symlink TARGET was re-moded"
    done
}
tm_case "enforce-refuses-a-symlink-in-both-scripts" modes,symlinks e_refuses_symlink

# Round 2 (sec-review TOCTOU): the DIRECTORY is opened O_NOFOLLOW too, so a
# data/ swapped for a link to somewhere else is refused, not re-moded.
e_refuses_symlinked_dir() {
    local s rc
    for s in "$UP" "$INSTALL_SH"; do
        rm -rf "${TM_TMP}/h" "${TM_TMP}/elsewhere"; mkdir -p "${TM_TMP}/h" "${TM_TMP}/elsewhere"
        chmod 755 "${TM_TMP}/elsewhere"
        ln -s "${TM_TMP}/elsewhere" "${TM_TMP}/h/data"
        _build_enforce "${TM_TMP}/fn" "$s"
        rc=0; bash "${TM_TMP}/fn.sh" "${TM_TMP}/h" > "${TM_TMP}/out" 2>&1 || rc=$?
        tm_assert_ne 0 "$rc" "$(basename "$s"): re-moded a data/ that is a symlink"
        tm_assert_mode 755 "${TM_TMP}/elsewhere" "$(basename "$s"): the symlinked directory's TARGET was re-moded"
    done
}
tm_case "enforce-refuses-a-symlinked-data-directory" modes,symlinks e_refuses_symlinked_dir

# ─── THE CONSEQUENCE: Phase 10 on a v1.0.x host ends with 0600/0700 ─────────
# Drives the REAL Phase 10 re-application block — the baseline replay, the
# frontend pass, the runtime chowns and the enforcement that follows them —
# against a fake root whose recorded baseline says tm.db 0644 and data/ 0755,
# exactly what a v1.0.x host records. Only BASELINE_PATHS is relocated, as in
# t03, and the harness refuses to run if any entry escapes the fake root.
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
                 baseline_lookup apply_baseline safe_install_dir enforce_audit_db_modes; do
            tm_extract_func "$UP" "$f"
        done
        tm_extract_line "$UP" '^baseline_has\(\)'
        tm_extract_line "$UP" '^can_access\(\)'
        echo 'if [ "$ACTION" = record ]; then record_baseline "$PERM_BASELINE"; exit 0; fi'
        tm_extract_between "$UP" '^info "Re-applying the recorded permission baseline' \
                                 '^success "Ownership and modes restored"'
    } > "${TM_TMP}/p10.sh"
}
p_phase10_ends_private() {
    local FR="${TM_TMP}/root" A
    A="${FR}/opt/topic-manager"
    mkdir -p "${A}/data" "${A}/tm" "${A}/venv/bin" "${A}/logs" "${FR}/var/www/topic-manager/app"
    : > "${A}/wsgi.py"; printf 'x\n' > "${FR}/var/www/topic-manager/index.html"
    chmod 755 "${A}/data"
    : > "${A}/data/tm.db"; chmod 644 "${A}/data/tm.db"
    _build_phase10
    bash "${TM_TMP}/p10.sh" "$FR" record "${TM_TMP}/bl" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "record failed: $(cat "${TM_TMP}/out")"
    tm_assert_recorded "${TM_TMP}/bl" "${A}/data/tm.db" "" "" 644 \
        "precondition: the baseline did not record the v1.0.x 0644"
    bash "${TM_TMP}/p10.sh" "$FR" phase10 "${TM_TMP}/bl" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "the Phase 10 block failed: $(cat "${TM_TMP}/out")"
    tm_assert_mode 600 "${A}/data/tm.db" \
        "Phase 10 left tm.db at the RECORDED 0644 — the upgrade replays a v1.0.x
        host's world-readable audit database straight back"
    tm_assert_mode 700 "${A}/data" "Phase 10 left data/ at the recorded 0755"
}
tm_case "phase10-on-a-v1.0.x-baseline-ends-0600-0700" modes,chown p_phase10_ends_private

# ─── where it is called, and in what order ───────────────────────────────────
# The behaviour is proven above; these prove the scripts still CALL it, and
# call it AFTER the thing that would otherwise undo it.
_line() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
o_upgrade_order() {
    local replay cpdb enforce
    replay="$(_line "$UP" 'success "Re-applied recorded ownership/mode')"
    cpdb="$(_line "$UP" 'cp -a "${BACKUP_DIR}/data/tm.consistent.db" "${APP_HOME}/data/tm.db"')"
    enforce="$(grep -n '^enforce_audit_db_modes$' "$UP" | head -1 | cut -d: -f1)"
    tm_assert_nonempty "$replay"  "anchor: the Phase 10 replay loop was not found"
    tm_assert_nonempty "$cpdb"    "anchor: the Phase 10 tm.db restore was not found"
    tm_assert_nonempty "$enforce" "Phase 10 no longer calls enforce_audit_db_modes — the
        baseline replay puts a v1.0.x host's 0644 straight back on tm.db"
    [ "$enforce" -gt "$replay" ] && [ "$enforce" -gt "$cpdb" ] \
        || _tm_afail "enforce_audit_db_modes (line ${enforce}) runs BEFORE the replay
        (${replay}) or the cp -a restore (${cpdb}) that it exists to override"
}
tm_case "upgrade-enforces-after-the-replay-and-the-restore" none o_upgrade_order

o_restore_calls_it() {
    tm_extract_func "$UP" restore_from_backup > "${TM_TMP}/rfb"
    local loop call
    loop="$(grep -n 'done < <(baseline_stream "$PERM_BASELINE")' "${TM_TMP}/rfb" | head -1 | cut -d: -f1)"
    call="$(grep -n '^    enforce_audit_db_modes$' "${TM_TMP}/rfb" | head -1 | cut -d: -f1)"
    tm_assert_nonempty "$call" "restore_from_backup does not re-mode the audit
        database, so --restore and the automatic rollback put 0644 back"
    [ -n "$loop" ] && [ "$call" -gt "$loop" ] \
        || _tm_afail "restore_from_backup re-modes tm.db before the replay that undoes it"
}
tm_case "restore-from-backup-re-modes-the-database" none o_restore_calls_it

o_install() {
    grep -qF 'safe_install_dir 700 "$APP_USER" "$APP_USER" "$DATA_DIR"' "$INSTALL_SH" \
        || _tm_afail "install.sh no longer creates data/ 0700"
    local chownl call
    chownl="$(_line "$INSTALL_SH" 'chown -R "$APP_USER:$APP_USER" "$LOG_DIR" "$DATA_DIR"')"
    call="$(grep -n '^enforce_audit_db_modes$' "$INSTALL_SH" | head -1 | cut -d: -f1)"
    tm_assert_nonempty "$call" "install.sh does not call enforce_audit_db_modes — a
        reinstall over a v1.0.x host leaves tm.db 0644"
    [ "$call" -gt "$chownl" ] || _tm_afail "install.sh enforces before its own recursive chown"
}
tm_case "install-creates-data-0700-and-enforces" none o_install

tm_finish
