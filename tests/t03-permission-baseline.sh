#!/usr/bin/env bash
# =============================================================================
# t03 — THE PERMISSION BASELINE ROUND-TRIP.
#
# The script's promise is that a STIG-narrowed host gets its OWN ownership and
# modes back, not this script's defaults. That promise is only worth anything
# if the recording and the re-application are actually inverse operations.
#
# Record owner/mode -> clobber a file to 600 root:root -> re-apply -> it must
# come back to exactly what was recorded, AND www-data must be able to read it
# again. The second half is the one that matters: the contract's own principle
# is that effective access is asked of the kernel as the real principal, never
# inferred from mode bits (hazards[stig-umask-403]).
#
# EVERY CASE HERE NEEDS A LINUX HOST. Git Bash cannot hold modes or ownership,
# so all of them would pass vacuously; they are SKIPPED there and named.
#   bash tests/run.sh --remote claude_admin@<linux-host>
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "recorded ownership and modes survive a clobber"

UP="$(tm_upgrade_sh)"

_build() {
    local h="$1"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'FAKEROOT="$1"; ACTION="$2"; shift 2'
        echo 'RED=""; GREEN=""; YELLOW=""; BOLD=""; NC=""'
        echo 'info()    { echo "[INFO] $*"; }'
        echo 'warn()    { echo "[WARN] $*"; }'
        echo 'success() { echo "[OK] $*"; }'
        # fail() is reached for real now: apply_baseline and the re-application
        # loop refuse a record they cannot verify rather than swallowing the
        # chown error, and every refusal goes through it.
        echo 'fail()    { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'SERVICE="topic-manager"'
        echo 'APP_USER="root"'
        echo 'WEB_USER="'"$TM_WEB_USER"'"'
        echo 'APP_HOME="${FAKEROOT}/opt/topic-manager"'
        echo 'FRONTEND_DIR="${FAKEROOT}/var/www/topic-manager"'
        echo 'CONFIG_DIR="${FAKEROOT}/etc/topic-manager"'
        echo 'DROPIN_DIR="${FAKEROOT}/etc/systemd/system/${SERVICE}.service.d"'
        # New in v1.0.4. BASELINE_PATHS names these by VARIABLE, so they have
        # to be defined here or the extracted array is an unbound-variable
        # error under set -u — which is exactly how their absence was caught.
        echo 'CLUSTERS_DIR="${CONFIG_DIR}/clusters.d"'
        echo 'CLUSTERS_FILE="${CLUSTERS_DIR}/clusters.yaml"'
        echo 'CERT_DIR="${APP_HOME}/data/cluster-certs"'
        echo 'PERM_BASELINE=""'
        echo
        # BASELINE_PATHS holds absolute host paths, so it has to be relocated to
        # be runnable at all. This is the ONLY edit made to extracted text, it is
        # mechanical (a leading "/ becomes "${FAKEROOT}/), and the guard below
        # refuses to run if any element escaped the fake root — these tests must
        # never be able to touch the real /etc or /var/www.
        tm_extract_between "$UP" '^BASELINE_PATHS=\(' '^\)$' | sed 's#"/#"${FAKEROOT}/#g'
        echo 'for _p in "${BASELINE_PATHS[@]}"; do'
        echo '  case "$_p" in'
        echo '    "$FAKEROOT"/*) ;;'
        echo '    *) echo "REFUSING: BASELINE_PATHS entry escaped the fake root: $_p" >&2; exit 90 ;;'
        echo '  esac'
        echo 'done'
        echo
        tm_extract_func "$UP" record_baseline
        echo
        tm_extract_func "$UP" baseline_stream
        echo
        tm_extract_func "$UP" baseline_is_legacy
        echo
        tm_extract_func "$UP" baseline_assert_record
        echo
        tm_extract_func "$UP" baseline_lookup
        echo
        tm_extract_line "$UP" '^baseline_has\(\)'
        echo
        tm_extract_func "$UP" apply_baseline
        echo
        tm_extract_line "$UP" '^can_access\(\)'
        echo
        echo 'case "$ACTION" in'
        echo '  record)  PERM_BASELINE="$1"; record_baseline "$PERM_BASELINE" ;;'
        echo '  apply)   PERM_BASELINE="$1"; apply_baseline "$2" "${3:-}" "${4:-}" "${5:-}" ;;'
        echo '  reapply) PERM_BASELINE="$1"'
        # The real Phase 10 re-application block, extracted whole.
        tm_extract_between "$UP" '^info "Re-applying the recorded permission baseline' \
                                 '^success "Re-applied recorded ownership/mode' \
            | sed 's/^/    /'
        echo '    ;;'
        echo '  canaccess) can_access "$1" "$2" "$3" ;;'
        echo '  *) echo "unknown action" >&2; exit 99 ;;'
        echo 'esac'
    } > "$h"
}

FR=""; BL=""
_mkhost() {
    FR="$TM_TMP/root"; BL="$TM_TMP/permissions.baseline"
    rm -rf "$FR"; rm -f "$BL"
    mkdir -p "$FR/etc/topic-manager/tls" \
             "$FR/etc/topic-manager/clusters.d" \
             "$FR/opt/topic-manager/data/cluster-certs" \
             "$FR/var/www/topic-manager/app" \
             "$FR/etc/systemd/system/topic-manager.service.d"
    printf 'kafka:\n  brokers: broker1:9092\n' > "$FR/etc/topic-manager/config.yaml"
    printf 'clusters:\n  - id: bare-metal\n' > "$FR/etc/topic-manager/clusters.d/clusters.yaml"
    printf 'x\n' > "$FR/var/www/topic-manager/index.html"
    printf '[Service]\nEnvironment=TM_SECRET_KEY=CANARY\n' \
        > "$FR/etc/systemd/system/topic-manager.service.d/override.conf"
    _build "$TM_TMP/ph.sh"
}
_do() { RC=0; bash "$TM_TMP/ph.sh" "$FR" "$@" > "$TM_TMP/out" 2>&1 || RC=$?; }

CFG=""; DDIR=""; DFILE=""; CLUD=""; CLUF=""; CERTD=""
_paths() {
    CFG="$FR/etc/topic-manager/config.yaml"
    DDIR="$FR/etc/systemd/system/topic-manager.service.d"
    DFILE="$DDIR/override.conf"
    CLUD="$FR/etc/topic-manager/clusters.d"
    CLUF="$CLUD/clusters.yaml"
    CERTD="$FR/opt/topic-manager/data/cluster-certs"
}

# ─── the round trip that was asked for ───────────────────────────────────────
p_roundtrip() {
    _mkhost; _paths
    chown "root:${TM_WEB_USER}" "$CFG"; chmod 640 "$CFG"
    chmod 755 "$FR" "$FR/etc" "$FR/etc/topic-manager"
    tm_open_traversal "$FR"

    _do record "$BL"; tm_assert_rc 0 "$RC" "record_baseline failed: $(cat "$TM_TMP/out")"
    tm_assert_recorded "$BL" "$CFG" root "$TM_WEB_USER" 640 "config.yaml was not recorded"

    _do canaccess "$TM_WEB_USER" -r "$CFG"
    tm_assert_rc 0 "$RC" "precondition: ${TM_WEB_USER} should be able to read a 640 root:${TM_WEB_USER} file"

    # Clobber it the way a careless reinstall would.
    chown root:root "$CFG"; chmod 600 "$CFG"
    _do canaccess "$TM_WEB_USER" -r "$CFG"
    tm_assert_ne 0 "$RC" \
        "can_access said ${TM_WEB_USER} can read a 600 root:root file — the access check is not asking the kernel"

    _do reapply "$BL"; tm_assert_rc 0 "$RC" "re-application failed: $(cat "$TM_TMP/out")"
    tm_assert_mode  640 "$CFG" "the recorded mode did not come back"
    tm_assert_owner "root:${TM_WEB_USER}" "$CFG" "the recorded ownership did not come back"

    _do canaccess "$TM_WEB_USER" -r "$CFG"
    tm_assert_rc 0 "$RC" \
        "the mode bits look right but ${TM_WEB_USER} still cannot read it — nginx would serve 403"
}
tm_case "baseline-roundtrip-restores-owner-mode-and-access" modes,chown,sudo p_roundtrip

# Ownership is put back by TWO independent paths — apply_baseline for the
# enumerated BASELINE_PATHS, and the Phase 10 loop for everything the recording
# found underneath them. The round-trip above runs both, so neutralising EITHER
# one alone left it green: mutation controls M19 and M21 both SURVIVED on
# 2026-08-30. The next two cases exercise one path each.
p_apply_baseline_restores_ownership_alone() {
    _mkhost; _paths
    chown "root:${TM_WEB_USER}" "$CFG"; chmod 640 "$CFG"
    _do record "$BL"; tm_assert_rc 0 "$RC" ""
    chown root:root "$CFG"
    _do apply "$BL" "$CFG"           # apply_baseline on its own, no Phase 10 loop
    tm_assert_owner "root:${TM_WEB_USER}" "$CFG" \
        "apply_baseline did not put the recorded ownership back"
    tm_assert_mode 640 "$CFG" "apply_baseline did not put the recorded mode back"
}
tm_case "apply_baseline-alone-restores-ownership" modes,chown p_apply_baseline_restores_ownership_alone

p_reapply_loop_restores_ownership_alone() {
    # The drop-in FILES are not in BASELINE_PATHS — they are only ever found by
    # record_baseline's find and put back by the Phase 10 loop. So this case
    # can only be satisfied by that loop.
    _mkhost; _paths
    chown "root:${TM_WEB_USER}" "$DFILE"; chmod 640 "$DFILE"
    _do record "$BL"; tm_assert_rc 0 "$RC" ""
    chown root:root "$DFILE"
    _do reapply "$BL"
    tm_assert_owner "root:${TM_WEB_USER}" "$DFILE" \
        "the re-application loop did not put the recorded ownership back on a drop-in file"
}
tm_case "reapply-loop-alone-restores-ownership" modes,chown p_reapply_loop_restores_ownership_alone

# ─── the v1.0.4 cluster store ────────────────────────────────────────────────
# scout's note: a path ABSENT from BASELINE_PATHS is restored to a script
# fallback rather than to what the operator set, so an upgrade silently
# re-widens or re-narrows it. These are the paths added this release.
p_clusters_paths_are_recorded() {
    _mkhost; _paths
    chown "${TM_WEB_USER}:${TM_WEB_USER}" "$CLUD" "$CLUF"
    chmod 750 "$CLUD"; chmod 640 "$CLUF"
    chmod 700 "$CERTD"
    _do record "$BL"; tm_assert_rc 0 "$RC" "record_baseline failed: $(cat "$TM_TMP/out")"
    tm_assert_recorded "$BL" "$CLUD" "" "" "" \
        "clusters.d is not in BASELINE_PATHS. An upgrade would hand it back a
        script default instead of what the operator set, and this is the one
        directory the application is allowed to write"
    tm_assert_recorded "$BL" "$CLUF" "" "" "" \
        "clusters.yaml is not in BASELINE_PATHS — the cluster list itself"
    tm_assert_recorded "$BL" "$CERTD" "" "" "" \
        "the Kafka TLS material directory is not in BASELINE_PATHS"
}
tm_case "cluster-store-paths-are-in-the-baseline-set" modes,chown p_clusters_paths_are_recorded

p_clusters_file_survives_a_clobber() {
    _mkhost; _paths
    chown "${TM_WEB_USER}:${TM_WEB_USER}" "$CLUF"; chmod 640 "$CLUF"
    chmod 700 "$CERTD"
    _do record "$BL"; tm_assert_rc 0 "$RC" ""
    # A careless reinstall widens both.
    chown root:root "$CLUF"; chmod 644 "$CLUF"
    chmod 755 "$CERTD"
    _do reapply "$BL"; tm_assert_rc 0 "$RC" "re-application failed: $(cat "$TM_TMP/out")"
    tm_assert_owner "${TM_WEB_USER}:${TM_WEB_USER}" "$CLUF" \
        "clusters.yaml came back root-owned — the application could no longer
        save a cluster profile"
    tm_assert_mode 640 "$CLUF" "clusters.yaml came back world-readable"
    tm_assert_mode 700 "$CERTD" \
        "the cert directory came back 0755, so uploaded Kafka private keys are
        readable by every local account"
}
tm_case "cluster-store-ownership-and-modes-survive-a-clobber" modes,chown p_clusters_file_survives_a_clobber

# ─── the drop-in files, individually ─────────────────────────────────────────
p_dropin_files_recorded() {
    _mkhost; _paths
    chmod 700 "$DDIR"; chmod 600 "$DFILE"
    _do record "$BL"; tm_assert_rc 0 "$RC" ""
    tm_assert_recorded "$BL" "$DFILE" "" "" "" \
        "the drop-in FILE was not recorded — only the directory. A restore would widen TM_SECRET_KEY to the directory default"
    chmod 644 "$DFILE"
    _do reapply "$BL"
    tm_assert_mode 600 "$DFILE" "the secret-bearing drop-in file came back world-readable"
}
tm_case "dropin-files-are-recorded-and-restored-individually" modes p_dropin_files_recorded

p_dropin_dir_recorded() {
    # The directory itself comes only from BASELINE_PATHS — record_baseline's
    # find uses -mindepth 1 — so this case fails if the entry is dropped.
    _mkhost; _paths
    chmod 700 "$DDIR"
    _do record "$BL"; tm_assert_rc 0 "$RC" ""
    tm_assert_recorded "$BL" "$DDIR" "" "" "" "DROPIN_DIR is not in BASELINE_PATHS"
    chmod 777 "$DDIR"
    _do reapply "$BL"
    tm_assert_mode 700 "$DDIR" "the drop-in directory was left world-writable after a restore"
}
tm_case "dropin-directory-is-in-the-baseline-path-set" modes p_dropin_dir_recorded

# ─── the lookup itself ───────────────────────────────────────────────────────
p_anchored_lookup() {
    # An unanchored substring match finds a LONGER path that merely contains
    # this one, and applies the wrong file's mode. The .bak line is written
    # first so an unanchored grep -m1 would hit it.
    #
    # Written in the PRE-v1.0.4 pipe format on purpose: it is also the case
    # that proves an old backup is still readable. The NUL-format twin of this
    # is t10's the-lookup-matches-the-whole-path.
    _mkhost; _paths
    local u g; u="$(id -un)"; g="$(id -gn)"
    printf '%s.bak|%s|%s|700\n' "$CFG" "$u" "$g" >  "$BL"
    printf '%s|%s|%s|640\n'     "$CFG" "$u" "$g" >> "$BL"
    printf 'backup\n' > "${CFG}.bak"
    chmod 600 "$CFG"
    _do apply "$BL" "$CFG"
    tm_assert_mode 640 "$CFG" \
        "apply_baseline used a DIFFERENT path's recorded mode — the lookup is not anchored on the field separator"
}
tm_case "baseline-lookup-is-anchored-on-the-separator" modes p_anchored_lookup

p_fallback_for_new_paths() {
    _mkhost; _paths
    : > "$BL"                       # a path with no recorded entry at all
    chmod 777 "$CFG"
    _do apply "$BL" "$CFG" "$(id -un)" "$(id -gn)" 750
    tm_assert_mode 750 "$CFG" "the fallback mode was not applied to an unrecorded path"
}
tm_case "unrecorded-paths-take-the-fallback" modes p_fallback_for_new_paths

p_absent_path_is_a_noop() {
    _mkhost; _paths
    : > "$BL"
    _do apply "$BL" "$FR/does/not/exist" root root 750
    tm_assert_rc 0 "$RC" "apply_baseline aborted on a path that does not exist"
}
tm_case "absent-paths-are-a-clean-no-op" none p_absent_path_is_a_noop

tm_finish
