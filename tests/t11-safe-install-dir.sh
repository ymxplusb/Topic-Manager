#!/usr/bin/env bash
# =============================================================================
# t11 — install -d MUST NOT WORK THROUGH A SYMLINK.
#
# `install -d` on a path that already exists is chmod() + chown(), and both
# follow symlinks. Two of the directories this product creates sit under a
# parent the APPLICATION owns and can write:
#
#   /opt/topic-manager/data/cluster-certs   (parent app-owned, and in the
#                                            unit's ReadWritePaths)
#
# so the application can replace that directory with a symlink to anything, and
# the next install or upgrade hands root an arbitrary chown+chmod on the target.
# safe_install_dir refuses BEFORE the call: detecting it afterwards is reporting
# a chown that has already happened.
#
# BOTH scripts carry the guard — install.sh and install/upgrade-full.sh — and
# both are driven here, because a guard in one of the two is a guard for one of
# the two paths onto a host.
#
# The mode/owner cases need Linux: Git Bash cannot hold either, so they SKIP
# loudly rather than passing on modes the filesystem never stored.
#   bash tests/run.sh --remote <user>@<linux-host> --strict
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "safe_install_dir refuses to apply ownership through a symlink"

UP="$(tm_upgrade_sh)"
INSTALL_SH="$(tm_install_sh)"

# _build <out> <source-script> — the REAL guard, extracted from the named
# script, with only the failure verb stubbed.
_build() {
    local h="$1" src="$2"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'die()  { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'fail() { die "$*"; }'
        echo
        tm_extract_func "$src" safe_install_dir
        echo
        echo 'safe_install_dir "$@"'
    } > "$h"
}

_do() {   # _do <script> <mode> <owner> <group> <path>
    RC=0
    bash "$1" "$2" "$3" "$4" "$5" > "$TM_TMP/out" 2>&1 || RC=$?
}

_prep() {
    rm -rf "$TM_TMP/w"; mkdir -p "$TM_TMP/w"
    TARGET="$TM_TMP/w/target"          # what a symlink would point AT
    mkdir -p "$TARGET"
    chmod 700 "$TARGET" 2>/dev/null || true
    LINK="$TM_TMP/w/link"              # the swapped-in symlink
    _build "$TM_TMP/up.sh"      "$UP"
    _build "$TM_TMP/install.sh" "$INSTALL_SH"
}

# Only used where install(1) is actually REACHED. The refusal cases never get
# that far, so they pass literals: a bogus group there would turn a proven
# refusal into an install(1) error and the case would pass for the wrong reason.
_owner_now() { id -un; }
_group_now() { id -gn 2>/dev/null || id -un; }

# ─── the refusal, in both scripts ────────────────────────────────────────────
s_upgrade_refuses_a_symlink() {
    _prep
    ln -s "$TARGET" "$LINK" 2>/dev/null || tm_die "this filesystem will not create symlinks"
    _do "$TM_TMP/up.sh" 755 root root "$LINK"
    tm_assert_ne 0 "$RC" \
        "install/upgrade-full.sh applied ownership through a symlink. The app
        owns the parent of the cert directory, so this is an arbitrary chown"
    tm_assert_grep "is a symlink" "$TM_TMP/out" "the refusal did not say why"
}
tm_case "upgrade-script-refuses-install--d-through-a-symlink" symlinks s_upgrade_refuses_a_symlink

s_install_refuses_a_symlink() {
    _prep
    ln -s "$TARGET" "$LINK" 2>/dev/null || tm_die "this filesystem will not create symlinks"
    _do "$TM_TMP/install.sh" 755 root root "$LINK"
    tm_assert_ne 0 "$RC" "install.sh applied ownership through a symlink"
    tm_assert_grep "is a symlink" "$TM_TMP/out" "the refusal did not say why"
}
tm_case "install-script-refuses-install--d-through-a-symlink" symlinks s_install_refuses_a_symlink

# The consequence, not just the exit code: the thing the symlink pointed at
# must be exactly as it was.
# Every behaviour case below runs BOTH scripts' copies (gatekeeper round 6,
# N1): an install.sh-only mutation used to be caught only by the
# scripts-carry-the-same-code comparison, never by what the code does.
_scripts() { echo "$TM_TMP/up.sh" "$TM_TMP/install.sh"; }

s_symlink_target_is_untouched() {
    local sc
    _prep
    ln -s "$TARGET" "$LINK" 2>/dev/null || tm_die "this filesystem will not create symlinks"
    for sc in $(_scripts); do
        _do "$sc" 777 root root "$LINK"
        tm_assert_mode 700 "$TARGET" \
            "$(basename "$sc"): the refusal came AFTER the chmod — the symlink target was modified,
            which is the whole thing the guard exists to prevent"
    done
}
tm_case "the-symlink-target-is-not-chmodded" symlinks,modes s_symlink_target_is_untouched

# ─── the guard must not be a blanket refusal ─────────────────────────────────
# A safe_install_dir that refused everything would pass every case above. These
# two prove it still does the job it replaced.
s_creates_a_new_directory() {
    local sc
    _prep
    for sc in $(_scripts); do
        rm -rf "$TM_TMP/w/fresh"
        _do "$sc" 750 "$(_owner_now)" "$(_group_now)" "$TM_TMP/w/fresh"
        tm_assert_rc 0 "$RC" "$(basename "$sc"): safe_install_dir refused an ordinary new directory: $(cat "$TM_TMP/out")"
        tm_assert_dir "$TM_TMP/w/fresh" "$(basename "$sc"): the directory was not created at all"
    done
}
tm_case "an-ordinary-new-directory-is-still-created" chown s_creates_a_new_directory

s_applies_the_mode() {
    local sc
    _prep
    for sc in $(_scripts); do
        rm -rf "$TM_TMP/w/fresh"
        _do "$sc" 700 "$(_owner_now)" "$(_group_now)" "$TM_TMP/w/fresh"
        tm_assert_rc 0 "$RC" "$(basename "$sc"): safe_install_dir failed: $(cat "$TM_TMP/out")"
        tm_assert_mode 700 "$TM_TMP/w/fresh" "$(basename "$sc"): the requested mode was not applied"
        # and on an EXISTING directory, which is the reinstall case
        chmod 777 "$TM_TMP/w/fresh"
        _do "$sc" 700 "$(_owner_now)" "$(_group_now)" "$TM_TMP/w/fresh"
        tm_assert_rc 0 "$RC" "$(basename "$sc"): safe_install_dir refused an existing real directory"
        tm_assert_mode 700 "$TM_TMP/w/fresh" \
            "$(basename "$sc"): a re-run did not re-apply the mode — the reinstall path would leave a
            widened directory widened"
    done
}
tm_case "the-mode-is-applied-to-new-and-existing-directories" modes,chown s_applies_the_mode

s_refuses_a_plain_file() {
    local sc
    _prep
    printf 'x\n' > "$TM_TMP/w/afile"
    for sc in $(_scripts); do
        _do "$sc" 750 root root "$TM_TMP/w/afile"
        tm_assert_ne 0 "$RC" "$(basename "$sc"): a plain file was accepted where a directory was meant"
        tm_assert_grep "exists and is not a directory" "$TM_TMP/out" "$(basename "$sc"): the refusal did not say why"
    done
}
tm_case "a-path-that-is-not-a-directory-is-refused" none s_refuses_a_plain_file

# ─── round 4 (sec-review TM-SEC-002, CWE-367): no path is resolved twice ─────
# The old guard was `[[ -L "$p" ]]` and then `install -d "$p"`: two separate
# resolutions of the same name, and only the LAST component was ever checked.
# A symlink one level up — the service account owns ${APP_HOME}, so it can
# replace data/ itself — was followed by install -d without a word.
s_intermediate_symlink_refused() {
    local f script
    for f in "$UP" "$INSTALL_SH"; do
        _prep
        script="$TM_TMP/up.sh"; [ "$f" = "$INSTALL_SH" ] && script="$TM_TMP/install.sh"
        # A parent anyone may write (as the service account may write its
        # own tree): a link placed in it is exactly the kind root must not
        # follow — whoever runs the suite, root included.
        chmod 777 "$TM_TMP/w"
        ln -s "$TARGET" "$TM_TMP/w/parentlink" 2>/dev/null || tm_die "this filesystem will not create symlinks"
        _do "$script" 777 "$(_owner_now)" "$(_group_now)" "$TM_TMP/w/parentlink/child"
        tm_assert_ne 0 "$RC" "$(basename "$f") created a directory THROUGH a symlinked parent"
        tm_assert_grep "is a symlink" "$TM_TMP/out" "$(basename "$f"): the refusal did not say why"
        tm_assert_nofile "$TARGET/child" "$(basename "$f") created the child inside the symlink's target"
        tm_assert_mode 700 "$TARGET" "$(basename "$f") changed the mode of the symlink's target"
    done
}
tm_case "a-symlinked-parent-is-refused-and-nothing-is-created-through-it" symlinks,modes s_intermediate_symlink_refused

s_no_path_is_resolved_twice() {
    local f body base
    for f in "$INSTALL_SH" "$UP"; do
        base="$(basename "$f")"
        body="$(tm_extract_func "$f" safe_install_dir)"
        grep -qE '^[[:space:]]*install -d' <<<"$body" \
            && _tm_afail "${base}: safe_install_dir still ends in install -d, which resolves the path a second time"
        grep -q 'O_NOFOLLOW' <<<"$body" || _tm_afail "${base}: safe_install_dir does not open with O_NOFOLLOW"
        grep -q 'dir_fd=fd' <<<"$body" || _tm_afail "${base}: safe_install_dir does not walk relative to the parent's descriptor"
        grep -q 'os.fchown(fd' <<<"$body" || _tm_afail "${base}: ownership is not applied to the opened descriptor"
        grep -q 'os.fchmod(fd' <<<"$body" || _tm_afail "${base}: the mode is not applied to the opened descriptor"
    done
    # The two copies are one rule.
    cmp -s <(tm_extract_func "$INSTALL_SH" safe_install_dir) <(tm_extract_func "$UP" safe_install_dir) \
        || _tm_afail "safe_install_dir differs between install.sh and the upgrade"
}
tm_case "safe-install-dir-acts-on-descriptors-in-both-scripts" none s_no_path_is_resolved_twice

s_reinstall_stops_before_directories() {
    # The service (and its socket, which would start it again) is stopped
    # BEFORE root touches a directory the service account can write.
    local stop first
    stop="$(grep -n -m1 '^stop_for_reinstall$' "$INSTALL_SH" | cut -d: -f1)"
    first="$(grep -n -m1 '^safe_install_dir [0-7]' "$INSTALL_SH" | cut -d: -f1)"
    [ -n "$stop" ] || _tm_afail "install.sh never calls stop_for_reinstall"
    [ -n "$first" ] || _tm_afail "install.sh creates no directory through safe_install_dir"
    [ "$stop" -lt "$first" ] || _tm_afail "install.sh stops the service only AFTER creating the app-writable directories (line ${stop} vs ${first})"
    local fn; fn="$(tm_extract_func "$INSTALL_SH" stop_for_reinstall)"
    grep -q '"${SERVICE_NAME}.service"' <<<"$fn" || _tm_afail "stop_for_reinstall does not stop the service"
    grep -q '"${SERVICE_NAME}.socket"' <<<"$fn" || _tm_afail "stop_for_reinstall leaves the socket up (a connection would restart the service)"
}
tm_case "a-reinstall-stops-the-service-before-any-directory-work" none s_reinstall_stops_before_directories

# ─── the guard is actually ON the paths that need it ─────────────────────────
# The cases above prove the guard works. This one proves it is REACHED. The two
# directories below are the ones the application itself can influence — it OWNS
# clusters.d, and it owns the PARENT of cluster-certs, which is what lets it
# swap either for a symlink between one run and the next. A bare `install -d`
# left on one of those paths is a guard that is simply not there, and no
# behavioural case in this file would notice.
s_app_writable_dirs_go_through_the_guard() {
    local f v base lit hits
    for f in "$INSTALL_SH" "$UP"; do
        base="$(basename "$f")"
        for v in CLUSTERS_DIR CERT_DIR; do
            # The literal text "$CLUSTERS_DIR", quotes and all.
            lit="\"\$${v}\""
            hits="$(grep -F -- "$lit" "$f")"
            if ! grep -qE '^[[:space:]]*safe_install_dir [0-7]{3} ' <<<"$hits"; then
                _tm_afail "${base} does not create \$${v} through safe_install_dir.
        That directory is app-owned, or has an app-owned parent, so install -d
        on it is an arbitrary chown+chmod the moment it is a symlink"
            fi
            if grep -qE '^[[:space:]]*install -d ' <<<"$hits"; then
                _tm_afail "${base} still has a BARE install -d creating \$${v}.
        The guard exists and this call site bypasses it"
            fi
        done
    done
    :
}
tm_case "app-writable-directories-are-created-through-the-guard" none s_app_writable_dirs_go_through_the_guard

# ─── the tree root EXECUTES is staged where only root can write ──────────────
# Phase 5 has two branches and the ancestor assertion was only ever on one of
# them. The online branch cloned into /tmp/topic-manager-src-<timestamp> — a
# predictable name in a world-writable directory, and the timestamp is printed
# in the log — so any local account that created it first chose what root then
# rsynced into /opt, installed as a systemd unit and pip-installed from.
#
# This is read from the source rather than driven: Phase 5 clones a repo and
# there is no way to run it here without network and root. What it CAN prove is
# that neither branch has lost its guard.
s_staging_is_root_owned_on_both_branches() {
    local phase5 n
    phase5="$(tm_extract_between "$UP" \
        '^phase "Phase 5 — Fetch target source"$' \
        '^TARGET_VERSION="\$\(cat ')"
    n="$(printf '%s\n' "$phase5" | grep -c 'assert_root_owned_path "\$WORK_DIR"' || true)"
    [ -n "$n" ] || n=0
    [ "$n" -eq 2 ] || _tm_afail \
        "assert_root_owned_path is called ${n} time(s) in Phase 5, not twice.
        BOTH branches stage a tree that root then executes; the offline branch
        has always been checked and the online one was not"
    if grep -qE 'WORK_DIR="/tmp' <<<"$phase5"; then
        _tm_afail "Phase 5 stages the source tree under /tmp again. A predictable
        name in a world-writable directory decides what root executes"
    fi
    grep -q 'mktemp -d' <<<"$phase5" || _tm_afail \
        "the online branch no longer creates its staging directory with mktemp -d.
        A fixed name can be pre-created by whoever gets there first, and
        mkdir -p on an existing directory leaves its ownership alone"
    :
}
tm_case "phase-5-stages-root-owned-source-on-both-branches" none s_staging_is_root_owned_on_both_branches

tm_finish
