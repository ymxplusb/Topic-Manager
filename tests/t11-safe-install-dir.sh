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
#   bash tests/run.sh --remote claude_admin@<linux-host> --strict
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
s_symlink_target_is_untouched() {
    _prep
    ln -s "$TARGET" "$LINK" 2>/dev/null || tm_die "this filesystem will not create symlinks"
    _do "$TM_TMP/up.sh" 777 root root "$LINK"
    tm_assert_mode 700 "$TARGET" \
        "the refusal came AFTER the chmod — the symlink target was modified,
        which is the whole thing the guard exists to prevent"
}
tm_case "the-symlink-target-is-not-chmodded" symlinks,modes s_symlink_target_is_untouched

# ─── the guard must not be a blanket refusal ─────────────────────────────────
# A safe_install_dir that refused everything would pass every case above. These
# two prove it still does the job it replaced.
s_creates_a_new_directory() {
    _prep
    _do "$TM_TMP/up.sh" 750 "$(_owner_now)" "$(_group_now)" "$TM_TMP/w/fresh"
    tm_assert_rc 0 "$RC" "safe_install_dir refused an ordinary new directory: $(cat "$TM_TMP/out")"
    tm_assert_dir "$TM_TMP/w/fresh" "the directory was not created at all"
}
tm_case "an-ordinary-new-directory-is-still-created" chown s_creates_a_new_directory

s_applies_the_mode() {
    _prep
    _do "$TM_TMP/up.sh" 700 "$(_owner_now)" "$(_group_now)" "$TM_TMP/w/fresh"
    tm_assert_rc 0 "$RC" "safe_install_dir failed: $(cat "$TM_TMP/out")"
    tm_assert_mode 700 "$TM_TMP/w/fresh" "the requested mode was not applied"
    # and on an EXISTING directory, which is the reinstall case
    chmod 777 "$TM_TMP/w/fresh"
    _do "$TM_TMP/up.sh" 700 "$(_owner_now)" "$(_group_now)" "$TM_TMP/w/fresh"
    tm_assert_rc 0 "$RC" "safe_install_dir refused an existing real directory"
    tm_assert_mode 700 "$TM_TMP/w/fresh" \
        "a re-run did not re-apply the mode — the reinstall path would leave a
        widened directory widened"
}
tm_case "the-mode-is-applied-to-new-and-existing-directories" modes,chown s_applies_the_mode

s_refuses_a_plain_file() {
    _prep
    printf 'x\n' > "$TM_TMP/w/afile"
    _do "$TM_TMP/up.sh" 750 root root "$TM_TMP/w/afile"
    tm_assert_ne 0 "$RC" "a plain file was accepted where a directory was meant"
    tm_assert_grep "not a directory" "$TM_TMP/out" "the refusal did not say why"
}
tm_case "a-path-that-is-not-a-directory-is-refused" none s_refuses_a_plain_file

# ─── the guard is actually ON the paths that need it ─────────────────────────
# The cases above prove the guard works. This one proves it is REACHED. The two
# directories below are the ones the application itself can influence — it OWNS
# clusters.d, and it owns the PARENT of cluster-certs, which is what lets it
# swap either for a symlink between one run and the next. A bare `install -d`
# left on one of those paths is a guard that is simply not there, and no
# behavioural case in this file would notice.
s_app_writable_dirs_go_through_the_guard() {
    local f v base lit
    for f in "$INSTALL_SH" "$UP"; do
        base="$(basename "$f")"
        for v in CLUSTERS_DIR CERT_DIR; do
            # The literal text "$CLUSTERS_DIR", quotes and all.
            lit="\"\$${v}\""
            if ! grep -F -- "$lit" "$f" | grep -qE '^[[:space:]]*safe_install_dir [0-7]{3} '; then
                _tm_afail "${base} does not create \$${v} through safe_install_dir.
        That directory is app-owned, or has an app-owned parent, so install -d
        on it is an arbitrary chown+chmod the moment it is a symlink"
            fi
            if grep -F -- "$lit" "$f" | grep -qE '^[[:space:]]*install -d '; then
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
    if printf '%s\n' "$phase5" | grep -qE 'WORK_DIR="/tmp'; then
        _tm_afail "Phase 5 stages the source tree under /tmp again. A predictable
        name in a world-writable directory decides what root executes"
    fi
    printf '%s\n' "$phase5" | grep -q 'mktemp -d' || _tm_afail \
        "the online branch no longer creates its staging directory with mktemp -d.
        A fixed name can be pre-created by whoever gets there first, and
        mkdir -p on an existing directory leaves its ownership alone"
    :
}
tm_case "phase-5-stages-root-owned-source-on-both-branches" none s_staging_is_root_owned_on_both_branches

tm_finish
