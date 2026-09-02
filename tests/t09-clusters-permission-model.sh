#!/usr/bin/env bash
# =============================================================================
# t09 — THE PERMISSION MODEL THE CLUSTER STORE DEPENDS ON.
#
# The Cluster Builder needs a directory the application can WRITE, because an
# atomic replace has to create a temp file beside its target. Making
# /etc/topic-manager itself app-writable was tried on prod and the app UNLINKED
# a root-owned 0600 file purely through directory write permission. Chained
# with the restart control that is a full auth-config takeover: delete
# config.yaml, write one with an attacker-chosen required_group, restart.
#
# So the layout is:
#     /etc/topic-manager/            root:<app>  0750   app reads, cannot write
#       config.yaml                  root:<app>  0640   secrets
#       clusters.d/                  <app>:<app> 0750   app owns this, only this
#
# These cases assert that boundary by ASKING THE KERNEL as the unprivileged
# principal — the contract's own principle, and the only check that survives an
# ACL or a parent directory saying otherwise. Mode bits are not evidence.
#
# The directory and config lines are EXTRACTED FROM install.sh, so weakening
# them there goes red here. t06 proves save_clusters is atomic; this file
# proves the filesystem permits exactly that operation and no more.
#
# EVERY CASE NEEDS A LINUX HOST with root and a spare unprivileged account.
# Git Bash cannot hold modes or ownership, so all of them would pass
# vacuously; they SKIP there and are named.
#     bash tests/run.sh --remote claude_admin@<linux-host>
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "clusters.d is writable; config.yaml is neither writable nor unlinkable"

INSTALL_SH="$(tm_install_sh)"
tm_assert_file "$INSTALL_SH" "install.sh is missing"
UP="$(tm_upgrade_sh)"

# TM_WEB_USER stands in for the topic-manager account: the property under test
# is "a non-root account that is the file's GROUP can read it and cannot unlink
# it", and www-data is the unprivileged account this harness already probes for.
APP="$TM_WEB_USER"

_build() {
    local h="$1"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'FAKEROOT="$1"'
        echo 'info()    { echo "[INFO] $*"; }'
        echo 'success() { echo "[OK] $*"; }'
        echo 'warn()    { echo "[WARN] $*"; }'
        echo 'die()     { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'fail()    { die "$*"; }'
        echo 'APP_USER="'"$APP"'"'
        echo 'SCRIPT_DIR="${FAKEROOT}/src"'
        echo 'APP_HOME="${FAKEROOT}/opt/topic-manager"'
        echo 'FRONTEND_DIR="${FAKEROOT}/var/www/topic-manager"'
        echo 'CONFIG_DIR="${FAKEROOT}/etc/topic-manager"'
        echo 'LOG_DIR="${APP_HOME}/logs"'
        echo 'DATA_DIR="${APP_HOME}/data"'
        echo 'CLUSTERS_DIR="${CONFIG_DIR}/clusters.d"'
        echo 'CERT_DIR="${DATA_DIR}/cluster-certs"'
        echo 'BACKUP_ROOT="${FAKEROOT}/var/backups/topic-manager"'
        echo
        echo '# Guard: these tests must never be able to touch the real /etc.'
        echo 'for _p in "$APP_HOME" "$CONFIG_DIR" "$CLUSTERS_DIR" "$CERT_DIR" "$FRONTEND_DIR" "$BACKUP_ROOT"; do'
        echo '  case "$_p" in'
        echo '    "$FAKEROOT"/*) ;;'
        echo '    *) echo "REFUSING: path escaped the fake root: $_p" >&2; exit 90 ;;'
        echo '  esac'
        echo 'done'
        echo
        # Every directory is now created through safe_install_dir, so the guard
        # itself is part of the code under test here — not a stub. t11 drives it
        # directly; this file needs it because the block below calls it.
        tm_extract_func "$INSTALL_SH" safe_install_dir
        echo
        # The real directory-creation block, extracted whole. Anchored on the
        # info/success lines around it so that DELETING an install -d line goes
        # RED here rather than breaking the extraction (a mutation that breaks
        # its own extraction proves nothing).
        tm_extract_between "$INSTALL_SH" \
            '^info "Creating application directories\.\.\."$' \
            '^success "Directories created"$'
        echo
        # The real config install: install(1) with owner and mode in one step,
        # not cp followed by chmod.
        #
        # BOTH anchors sit OUTSIDE the lines a mutation would change.
        # Anchoring ON the install line made mutation controls M34 and M37
        # ABORT rather than go red: they mutated the anchor itself, the
        # extraction matched nothing, and an aborted control proves nothing.
        tm_extract_between "$INSTALL_SH" \
            '^    # install\(1\), not cp\+chmod' \
            '^    # Generate a random secret key$'
        echo
        echo 'printf "clusters:\n  - id: seed\n" > "${CLUSTERS_DIR}/clusters.yaml"'
        echo 'chown "${APP_USER}:${APP_USER}" "${CLUSTERS_DIR}/clusters.yaml"'
        echo 'chmod 640 "${CLUSTERS_DIR}/clusters.yaml"'
        echo 'success "fake host built"'
    } > "$h"
}

FR=""
_mkhost() {
    FR="$TM_TMP/root"
    rm -rf "$FR"
    mkdir -p "$FR/src/config"
    printf 'server:\n  secret_key: "SUPERSECRET"\n' > "$FR/src/config/config.yaml.example"
    _build "$TM_TMP/ph.sh"
    bash "$TM_TMP/ph.sh" "$FR" > "$TM_TMP/build.out" 2>&1 \
        || tm_die "building the fake host failed: $(cat "$TM_TMP/build.out")"
    # mktemp -d makes 0700 directories, so the unprivileged account cannot
    # traverse down to the fake root at all unless the ancestors are opened.
    tm_open_traversal "$FR"
}

CFG=""; CLUD=""; CLUF=""
_paths() {
    CFG="$FR/etc/topic-manager/config.yaml"
    CLUD="$FR/etc/topic-manager/clusters.d"
    CLUF="$CLUD/clusters.yaml"
}

# as_app <command...> — run as the unprivileged principal, return its status.
as_app() { RC=0; sudo -u "$APP" "$@" > "$TM_TMP/asapp.out" 2>&1 || RC=$?; }

# ─── the layout install.sh actually creates ──────────────────────────────────
p_layout() {
    _mkhost; _paths
    tm_assert_owner "root:${APP}" "$FR/etc/topic-manager" \
        "the config directory is not root-owned with the app as its group. Group
        root would stop the service reading its own config; app-owned would let
        it unlink config.yaml"
    tm_assert_mode  750 "$FR/etc/topic-manager" "the config directory is not 0750"
    tm_assert_owner "root:${APP}" "$CFG" "config.yaml is not root:${APP}"
    tm_assert_mode  640 "$CFG" "config.yaml is not 0640"
    tm_assert_owner "${APP}:${APP}" "$CLUD" "clusters.d is not owned by the app"
    tm_assert_mode  750 "$CLUD" "clusters.d is not 0750"
    tm_assert_mode  700 "$FR/opt/topic-manager/data/cluster-certs" \
        "the cert directory is not 0700 — uploaded Kafka key material would be
        readable by the app's group"
}
tm_case "install-creates-the-split-layout" modes,chown,sudo p_layout

# ─── THE assertion: config.yaml cannot be removed ────────────────────────────
p_config_cannot_be_unlinked() {
    _mkhost; _paths
    as_app rm -f "$CFG"
    tm_assert_ne 0 "$RC" \
        "the app user DELETED config.yaml. Directory write is unlink: chained
        with the restart control this is a full auth-config takeover — remove
        config.yaml, write one with an attacker-chosen required_group, restart"
    tm_assert_file "$CFG" "config.yaml is gone"
}
tm_case "app-user-cannot-unlink-config-yaml" modes,chown,sudo p_config_cannot_be_unlinked

p_config_cannot_be_modified() {
    _mkhost; _paths
    as_app sh -c "echo 'required_group: CN=Everyone' >> '$CFG'"
    tm_assert_ne 0 "$RC" "the app user APPENDED to config.yaml"
    as_app sh -c "> '$CFG'"
    tm_assert_ne 0 "$RC" "the app user TRUNCATED config.yaml"
    tm_assert_grep "SUPERSECRET" "$CFG" "config.yaml lost its contents"
}
tm_case "app-user-cannot-modify-config-yaml" modes,chown,sudo p_config_cannot_be_modified

p_config_cannot_be_replaced_by_rename() {
    _mkhost; _paths
    # The subtle one: a writable DIRECTORY lets an attacker rename a file it
    # cannot write over the top of the target. Directory permission is the
    # control, not the file mode.
    as_app sh -c "cp '$CFG' /tmp/tm-t09-$$ 2>/dev/null; mv /tmp/tm-t09-$$ '$CFG'"
    tm_assert_ne 0 "$RC" \
        "the app user replaced config.yaml by renaming another file over it"
    tm_assert_grep "SUPERSECRET" "$CFG" "config.yaml was replaced"
    rm -f "/tmp/tm-t09-$$"
}
tm_case "app-user-cannot-replace-config-yaml-by-rename" modes,chown,sudo p_config_cannot_be_replaced_by_rename

# ─── and yet it must still WORK ──────────────────────────────────────────────
p_config_is_readable() {
    _mkhost; _paths
    as_app test -r "$CFG"
    tm_assert_rc 0 "$RC" \
        "the app user cannot READ config.yaml. It holds secret_key, so the
        service would raise RuntimeError and refuse to start — a boundary that
        is too tight is an outage, not a hardening"
}
tm_case "app-user-can-still-read-config-yaml" modes,chown,sudo p_config_is_readable

p_atomic_save_is_possible_in_clusters_d() {
    _mkhost; _paths
    # Exactly what tm/clusters.save_clusters does: a temp file created INSIDE
    # the directory, then renamed over the target. Both halves need directory
    # write, which is the whole reason clusters.d exists.
    as_app sh -c "t=\$(mktemp '${CLUD}/.clusters-XXXXXX') && printf 'clusters:\n  - id: new\n' > \"\$t\" && mv -f \"\$t\" '${CLUF}'"
    tm_assert_rc 0 "$RC" \
        "the app user could not perform an atomic replace inside clusters.d, so
        the Cluster Builder could not save: $(cat "$TM_TMP/asapp.out")"
    tm_assert_grep "id: new" "$CLUF" "the replacement did not land"
}
tm_case "app-user-can-atomically-replace-clusters-yaml" modes,chown,sudo p_atomic_save_is_possible_in_clusters_d

p_cert_dir_is_writable_and_private() {
    _mkhost; _paths
    local certs="$FR/opt/topic-manager/data/cluster-certs"
    as_app sh -c "printf x > '${certs}/probe.pem'"
    tm_assert_rc 0 "$RC" "the app user cannot write the cert directory, so a
        certificate upload would fail: $(cat "$TM_TMP/asapp.out")"
    tm_assert_mode 700 "$certs" "the cert directory is not 0700"
}
tm_case "app-user-can-write-the-cert-directory" modes,chown,sudo p_cert_dir_is_writable_and_private

# ─── the unit must open clusters.d and nothing wider ─────────────────────────
p_unit_readwritepaths() {
    local unit="${TM_REPO_ROOT}/systemd/topic-manager.service"
    tm_assert_file "$unit" "the unit file is missing"
    tm_assert_grep "/etc/topic-manager/clusters.d" "$unit" \
        "ReadWritePaths does not name clusters.d, so ProtectSystem=strict makes
        it read-only and every save fails with EROFS"
    grep -E '^ReadWritePaths=.*[= ]/etc/topic-manager( |$)' "$unit" \
        && _tm_afail "ReadWritePaths names /etc/topic-manager ITSELF. That is the
        mount-namespace half of the unlink hole — narrow it to clusters.d" || true
}
tm_case "unit-opens-clusters-d-and-not-the-whole-config-dir" none p_unit_readwritepaths

# ─── the boundary is ASSERTED, not just created ──────────────────────────────
# Creating the layout correctly and CHECKING it are different claims. Until
# v1.0.4 only the upgrade asked these five questions; install.sh created the
# layout and asserted nothing, so the REINSTALL path — the one that runs over an
# existing host — could put the boundary back wrong and report success. --restore
# replayed recorded ownership with no checks at all.
#
# Both copies are driven here, from the real scripts, against a host that is
# right and then against one that is wrong.

# _boundary <out> <script> <start-ere> <end-ere> — the real assertions, with
# the paths pointed at the fake host.
_boundary() {
    local h="$1" src="$2" s="$3" e="$4"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -uo pipefail'
        echo 'FAKEROOT="$1"'
        echo 'success() { echo "[OK] $*"; }'
        echo 'warn()    { echo "[WARN] $*"; }'
        echo 'die()     { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'fail()    { die "$*"; }'
        echo 'APP_USER="'"$APP"'"'
        echo 'CONFIG_DIR="${FAKEROOT}/etc/topic-manager"'
        echo 'CONFIG_FILE="${CONFIG_DIR}/config.yaml"'
        echo 'CLUSTERS_DIR="${CONFIG_DIR}/clusters.d"'
        echo 'CLUSTERS_FILE="${CLUSTERS_DIR}/clusters.yaml"'
        echo
        tm_extract_line "$UP" '^can_access\(\)'
        echo
        tm_extract_between "$src" "$s" "$e" | sed 's/^    //'
    } > "$h"
}

_boundary_scripts() {
    _boundary "$TM_TMP/b-install.sh" "$INSTALL_SH" \
        '^# ─── permission boundary ─' \
        '^success "Permission boundary verified: the app owns clusters\.d'
    _boundary "$TM_TMP/b-restore.sh" "$UP" \
        '^    # --- The permission boundary, ASKED OF THE KERNEL as the real principal\.' \
        '^    success "Permission boundary verified after restore"'
}

_run_boundary() { RC=0; bash "$1" "$FR" > "$TM_TMP/b.out" 2>&1 || RC=$?; }

p_boundary_passes_on_a_correct_host() {
    _mkhost; _paths; _boundary_scripts
    _run_boundary "$TM_TMP/b-install.sh"
    tm_assert_rc 0 "$RC" "install.sh's boundary check failed on the layout
        install.sh itself creates: $(cat "$TM_TMP/b.out")"
    _run_boundary "$TM_TMP/b-restore.sh"
    tm_assert_rc 0 "$RC" "the restore boundary check failed on a correct layout:
        $(cat "$TM_TMP/b.out")"
}
tm_case "the-boundary-check-passes-on-a-correct-layout" modes,chown,sudo p_boundary_passes_on_a_correct_host

p_boundary_catches_a_writable_config() {
    # The failure the check exists for: config.yaml group-writable, so the app
    # can rewrite required_group and then restart the service.
    _mkhost; _paths; _boundary_scripts
    chmod 660 "$CFG"
    _run_boundary "$TM_TMP/b-install.sh"
    tm_assert_ne 0 "$RC" \
        "install.sh accepted a config.yaml the application can WRITE. Nothing on
        the install or reinstall path notices, and the app can then choose its
        own required_group"
    _run_boundary "$TM_TMP/b-restore.sh"
    tm_assert_ne 0 "$RC" \
        "the restore accepted a config.yaml the application can WRITE — a backup
        taken while the boundary was wrong puts the host straight back into it"
}
tm_case "the-boundary-check-catches-a-writable-config-yaml" modes,chown,sudo p_boundary_catches_a_writable_config

p_boundary_catches_a_writable_config_dir() {
    # Directory write is UNLINK: the app deletes config.yaml and writes its own.
    _mkhost; _paths; _boundary_scripts
    chmod 770 "$FR/etc/topic-manager"
    _run_boundary "$TM_TMP/b-install.sh"
    tm_assert_ne 0 "$RC" \
        "install.sh accepted a config DIRECTORY the application can write"
    _run_boundary "$TM_TMP/b-restore.sh"
    tm_assert_ne 0 "$RC" \
        "the restore accepted a config DIRECTORY the application can write"
}
tm_case "the-boundary-check-catches-a-writable-config-directory" modes,chown,sudo p_boundary_catches_a_writable_config_dir

p_boundary_catches_an_unwritable_cluster_store() {
    # The other direction: a boundary so tight the Cluster Builder cannot save.
    #
    # clusters.yaml stays READABLE on purpose. MEASURED 2026-09-01: with the
    # directory at 700 root:root the file was unreadable too, so this case went
    # red on the -r CLUSTERS_FILE check and mutation control M55 — deleting the
    # -w CLUSTERS_DIR check — SURVIVED. Only the directory is closed here, so
    # the only assertion that can fire is the one under test.
    _mkhost; _paths; _boundary_scripts
    chown "root:${APP}" "$CLUD"; chmod 750 "$CLUD"
    _run_boundary "$TM_TMP/b-install.sh"
    tm_assert_ne 0 "$RC" \
        "install.sh accepted a clusters.d the application cannot write — every
        save from the Cluster Builder would fail, and the install said OK"
}
tm_case "the-boundary-check-catches-an-unwritable-cluster-store" modes,chown,sudo p_boundary_catches_an_unwritable_cluster_store

tm_finish
