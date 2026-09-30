#!/usr/bin/env bash
# =============================================================================
# Jarvis Topic Manager — Full-Stack Upgrade with Permission Audit,
#                        Backup, Upgrade and Restore
#
#   AUDITS permissions and platform hardening BEFORE anything is touched
#   -> checks the upgrade blockers that only bite on the way out of v1.0.0
#   -> backs up ALL configuration and secret material, and verifies it
#   -> patches the OS and every third-party component
#   -> reinstalls the application from source
#   -> restores configuration, audit data, TLS certs and private keys to the
#      EXACT ownership and modes they had, not to hardcoded defaults
#   -> re-audits effective access, so a scoped-down host cannot silently
#      produce an nginx 403 or a service that cannot read its own venv
#   -> rolls back automatically on any failure
#
# Designed for STIG-hardened Ubuntu, where permissions are deliberately
# narrowed after install. This script treats the host's permissions as the
# authority and its own defaults as a fallback — it never widens anything
# without saying so.
#
# Version-agnostic: upgrades from ANY installed version (including 1.0.0) to
# whatever the fetched source tree declares in tm/VERSION.
#
# Usage:
#   sudo bash upgrade-full.sh                    # full upgrade
#   sudo bash upgrade-full.sh --audit-only       # audit + blocker checks only
#                                                (exit 0 clear / 1 warnings / 2 blockers)
#   sudo bash upgrade-full.sh --dry-run          # audit + plan, no changes
#   sudo bash upgrade-full.sh --backup-only      # verified backup, no changes
#   sudo bash upgrade-full.sh --skip-os          # app + deps only, no apt
#   sudo bash upgrade-full.sh --offline          # air-gapped install
#   sudo bash upgrade-full.sh --list-backups     # show restore points
#   sudo bash upgrade-full.sh --restore TS       # roll back to a restore point
#   sudo bash upgrade-full.sh --force            # proceed past BLOCK findings
#   sudo bash upgrade-full.sh --no-bind-probe    # skip the live LDAP bind entirely
#   sudo bash upgrade-full.sh --repo-url URL --repo-commit SHA [--repo-branch REF]
#                                                # online source (or TM_REPO_URL /
#                                                # TM_REPO_COMMIT / TM_REPO_BRANCH);
#                                                # there is NO default URL, and the
#                                                # 40-hex commit is REQUIRED
#
# ONLINE vs OFFLINE: online mode clones the release source from the git URL
# the operator supplies — this script names no repository of its own, because
# which server is authoritative is a property of the site, not of the product.
# Without --repo-url (or TM_REPO_URL) an online run stops before Phase 4 and
# says so; the offline bundle (--offline) needs no network at all.
#
# The clone is PINNED (round 2, sec-review HIGH): a branch or tag is movable,
# and root executes what it fetches. --repo-commit names the exact 40-hex
# commit the operator reviewed; after the clone `git rev-parse HEAD` must equal
# it before a single byte of the tree is read, or the run stops. Get the value
# from the release notes or the CI pipeline of the tag, out of band.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -euo pipefail
# This script's own ABSOLUTE path, for every "roll back with ..." line it
# prints. A bare "upgrade-full.sh" only works from the directory it was run
# from, which an operator following the instructions later is rarely in
# (clean-room, 2026-09-29).
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

# ─── tunables ────────────────────────────────────────────────────────────────
# v1.1.0: no built-in source. This used to clone a public mirror that the
# owning site no longer treats as authoritative; an upgrade must fetch from
# where the operator says the release lives, or not fetch at all.
REPO_URL="${TM_REPO_URL:-}"
REPO_BRANCH="${TM_REPO_BRANCH:-main}"
REPO_COMMIT="${TM_REPO_COMMIT:-}"

APP_USER="topic-manager"
WEB_USER="www-data"
APP_HOME="/opt/topic-manager"
FRONTEND_DIR="/var/www/topic-manager"
CONFIG_DIR="/etc/topic-manager"
# Defined here, not in Phase 3 where it used to be: restore_from_backup is
# called from the EXIT trap and from --restore, both of which run before Phase 3
# ever assigns anything, and `set -u` turns a forward reference into an abort.
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
# New in v1.0.4. The cluster list moved out of config.yaml into a
# subdirectory the application OWNS, because atomic replace needs to create
# a temp file beside the target and making /etc/topic-manager itself
# app-writable was measured to let the app UNLINK the root-owned secrets
# file. The parent stays root:topic-manager 0750.
CLUSTERS_DIR="${CONFIG_DIR}/clusters.d"
CLUSTERS_FILE="${CLUSTERS_DIR}/clusters.yaml"
CERT_DIR="${APP_HOME}/data/cluster-certs"
VENV="${APP_HOME}/venv"
SERVICE="topic-manager"
# Where TM_SECRET_KEY and TM_LDAP_BIND_PASSWORD live on a host configured by
# environment rather than by config.yaml. Phase 3 reads them from here (via
# `systemctl show`, which reports the merged unit), so this directory is
# configuration and secret material, not a system file that install re-creates.
DROPIN_DIR="/etc/systemd/system/${SERVICE}.service.d"
# >>> the product's host artefacts — byte-identical in install.sh and install/upgrade-full.sh (t45)
# What this release lays down OUTSIDE its own trees, recorded POSITIVELY
# (gatekeeper round 6, B1). The installer and the upgrade write
# INSTALL_MANIFEST (root 0600) from these lists and from the source tree they
# install from: every unit in systemd/ and the enablement link its [Install]
# section asks for, every rule in install/polkit/, the helper tree
# APPLY_HELPER_FILES describes, HOST_FILES, HOST_LINKS, and the operator state
# in V120_MANAGED. A rollback retires or puts back ONLY what a manifest names
# (restore_owned_artefacts); anything else is another tool's or the
# operator's, and is never stopped, disabled, deleted or changed. Round 6
# judged a file the product's when its TEXT mentioned topic-manager, and a
# rollback stopped, disabled and deleted another tool's backup unit (its
# ExecStart backed up /opt/topic-manager) and silently deleted an operator's
# nginx drop-in that named the product in a comment.
# One line per artefact, "<field> <absolute path>": the sha256 of a file as
# installed, "dir", "link", "state" (operator state the Settings apply
# rewrites: recorded, never hash-checked) or, in INSTALL_MANIFEST.pending
# only, "pending" (a file an upgrade is about to install). "#" starts a comment.
INSTALL_MANIFEST="/var/lib/topic-manager/installed-files.manifest"
OWNED_UNIT_DIR="/etc/systemd/system"
OWNED_POLKIT_DIR="/etc/polkit-1/rules.d"
OWNED_LIBEXEC_DIR="/usr/libexec/topic-manager"
# The root apply helper: "<mode> <source in the tree> <path under OWNED_LIBEXEC_DIR>".
APPLY_HELPER_FILES=("755 install/libexec/tm-apply tm-apply"
                    "644 tm/settings_schema.py lib/settings_schema.py"
                    "644 tm/tls_check.py lib/tls_check.py")
# Release files and links at fixed paths elsewhere. t45 parses every install,
# cp and ln both scripts run and holds them to these lists.
HOST_FILES=(/etc/nginx/snippets/tm-security-headers.conf
            /etc/nginx/sites-available/topic-manager /etc/logrotate.d/topic-manager)
HOST_LINKS=(/etc/nginx/sites-enabled/topic-manager)
# v1.2.0: the files Settings > "Apply to host" manages (rendered by the root
# helper /usr/libexec/topic-manager/tm-apply). They are OPERATOR STATE, like
# config.yaml: an upgrade keeps them (the release's copies are laid down only
# where absent), backs them up in Phase 4, puts them back on a rollback, and
# re-applies what tm.db holds at the end (Phase 12) — it never reverts an
# operator's choice to the release default.
V120_MANAGED=(
  /etc/nginx/conf.d/topic-manager-limits.conf
  /etc/nginx/snippets/tm-limits-server.conf /etc/nginx/snippets/tm-limits-login.conf
  /etc/nginx/snippets/tm-limits-api.conf /etc/nginx/snippets/tm-syslog.conf
  /etc/nginx/sites-available/topic-manager-http /etc/nginx/sites-enabled/topic-manager-http
  /etc/rsyslog.d/30-topic-manager.conf /etc/rsyslog.d/topic-manager
  /etc/chrony/sources.d/topic-manager.sources
  /etc/systemd/timesyncd.conf.d/topic-manager.conf)
# (closed on its last entry: tests extract the upgrade's BASELINE_PATHS up to
# the only line in that file that is a bare ")", and a second would break them)

# host_artefacts <source-tree> — "<kind> <path>" for every artefact above,
# kind file, dir, link or state. The units and rules are read from the tree
# the release installs them FROM, so a unit added to systemd/ is recorded
# without anyone remembering to list it.
host_artefacts() {   # host_artefacts <source-tree>
    local src="$1" f u t e m s d
    local -a ts
    for f in "${src}"/systemd/*; do
        u="${f##*/}"
        printf 'file %s\n' "${OWNED_UNIT_DIR}/${u}"
        read -r -a ts <<<"$(sed -n -E 's/^[[:space:]]*WantedBy[[:space:]]*=//p' "$f" | tr '\n' ' ')"
        for t in "${ts[@]}"; do printf 'link %s\n' "${OWNED_UNIT_DIR}/${t}.wants/${u}"; done
        read -r -a ts <<<"$(sed -n -E 's/^[[:space:]]*RequiredBy[[:space:]]*=//p' "$f" | tr '\n' ' ')"
        for t in "${ts[@]}"; do printf 'link %s\n' "${OWNED_UNIT_DIR}/${t}.requires/${u}"; done
    done
    for f in "${src}"/install/polkit/*; do printf 'file %s\n' "${OWNED_POLKIT_DIR}/${f##*/}"; done
    printf 'dir %s\n' "$OWNED_LIBEXEC_DIR"
    for e in "${APPLY_HELPER_FILES[@]}"; do
        read -r m s d <<<"$e"
        if [[ "$d" == */* ]]; then printf 'dir %s\n' "${OWNED_LIBEXEC_DIR}/${d%/*}"; fi
        printf 'file %s\n' "${OWNED_LIBEXEC_DIR}/${d}"
    done
    for f in "${HOST_FILES[@]}"; do printf 'file %s\n' "$f"; done
    for f in "${HOST_LINKS[@]}"; do printf 'link %s\n' "$f"; done
    for f in "${V120_MANAGED[@]}"; do printf 'state %s\n' "$f"; done
}

# write_install_manifest <source-tree> [pending] — INSTALL_MANIFEST from
# host_artefacts: every artefact PRESENT, a file with its sha256 as it is now
# (after the installer's own edits, e.g. the site's server_name). With
# "pending": INSTALL_MANIFEST.pending, every artefact the release is ABOUT to
# install, present or not — so a rollback of an upgrade interrupted before its
# manifest was written still knows what that upgrade installed.
write_install_manifest() {   # write_install_manifest <source-tree> [pending]
    local src="$1" mode="${2:-}" out="$INSTALL_MANIFEST" kind p h tmp
    local -A seen=()
    [[ "$mode" == pending ]] && out="${INSTALL_MANIFEST}.pending"
    safe_install_dir 700 root root "${INSTALL_MANIFEST%/*}"
    tmp="$(mktemp "${out}.XXXXXX")"
    {
        printf '# topic-manager install manifest, release %s: <sha256|dir|link|state|pending> <absolute path>\n' \
            "$(cat "${src}/VERSION" 2>/dev/null || echo unknown)"
        while read -r kind p; do
            [[ -z "${seen[$p]+x}" ]] || continue
            seen["$p"]=1
            if [[ "$mode" == pending ]]; then
                h="$kind"; [[ "$kind" == file ]] && h=pending
            elif [[ "$kind" == state ]]; then
                [[ -e "$p" || -L "$p" ]] || continue
                h=state
            elif [[ "$kind" == link ]]; then
                [[ -L "$p" ]] || continue
                h=link
            elif [[ "$kind" == dir ]]; then
                [[ -d "$p" && ! -L "$p" ]] || continue
                h=dir
            else
                [[ -f "$p" && ! -L "$p" ]] || continue
                h="$(sha256sum < "$p")"; h="${h%% *}"
            fi
            printf '%s %s\n' "$h" "$p"
        done < <(host_artefacts "$src")
    } > "$tmp"
    chmod 600 -- "$tmp"
    mv -f -- "$tmp" "$out"
}
# <<< the product's host artefacts
# Where a retired unit's RuntimeDirectory= lives (remove_retired_runtime).
OWNED_RUNTIME_DIR="/run"
# Where systemd keeps a persistent timer's last-trigger stamp. It outlives the
# timer unit, so retire_unit removes a retired timer's (clean-room round 6, M2).
TIMER_STAMP_DIR="/var/lib/systemd/timers"
# One restore's record, reset by restore_from_backup: the units it retired,
# their runtime directories, and every PROBLEM it met — a unit systemctl could
# not stop and disable, a recorded artefact with no saved copy, the wrong
# version answering. Any problem makes the restore's verdict non-zero
# (restore_verdict), with each one listed.
RETIRED_UNITS=(); RETIRED_RUNTIME=(); RESTORE_PROBLEMS=()
SET_ASIDE=()   # product files a restore retired that were not as installed

# What v1.1.0 and v1.1.1 laid down outside their own trees: the releases that
# wrote no install manifest. DATA, read from those tags' install.sh and
# install/upgrade-full.sh Phase 9 (t45 re-derives it from both tags and fails
# on any difference) — never inferred from what a file on the host says. A
# host with no manifest is judged by it ONLY when it runs one of these
# versions; any other version with no manifest has no record, and a rollback
# to it retires nothing and says so (restore_owned_artefacts).
LEGACY_V11X_VERSIONS=(1.1.0 1.1.1)
LEGACY_V11X_ARTEFACTS=("file /etc/systemd/system/topic-manager.service"
                       "file /etc/systemd/system/topic-manager-nginx-test.service"
                       "link /etc/systemd/system/multi-user.target.wants/topic-manager.service"
                       "file /etc/polkit-1/rules.d/50-topic-manager.rules"
                       "file /etc/nginx/snippets/tm-security-headers.conf"
                       "file /etc/nginx/sites-available/topic-manager"
                       "link /etc/nginx/sites-enabled/topic-manager"
                       "file /etc/logrotate.d/topic-manager")

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="/var/backups/topic-manager"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
BACKUP_TAR="${BACKUP_ROOT}/topic-manager-backup-${TIMESTAMP}.tar.gz"
# Where a rollback copies a product file it retires that is NOT byte-for-byte
# what the manifest recorded (an operator edited it since): kept, never just
# deleted (restore_owned_artefacts).
SET_ASIDE_DIR="${BACKUP_ROOT}/set-aside-${TIMESTAMP}"
# Where root stages the source tree it is about to EXECUTE. BOTH branches of
# Phase 5 land under this root-owned 0700 parent and BOTH assert it before a
# byte is read. The online branch used to clone into
# /tmp/topic-manager-src-<timestamp>: a predictable name under a world-writable
# directory, and the timestamp is printed in the log and derivable from the run,
# so any local account that created it first chose what root then rsyncs into
# /opt, installs as a systemd unit and pip-installs wheels from. The offline
# branch has always been root-owned; the assertion was only ever called there.
STAGE_ROOT="/var/lib/topic-manager"
WORK_DIR=""                            # set in Phase 5, one value per branch
OFFLINE_SRC_DIR="${STAGE_ROOT}/offline-src"
WORK_DIR_OWNED=false      # true only when THIS run created WORK_DIR (see Phase 5)
LOG_FILE="/var/log/topic-manager-upgrade-${TIMESTAMP}.log"
PERM_BASELINE=""          # set once BACKUP_DIR exists
AUDIT_REPORT=""

# Third-party dependency pins are NOT declared here. requirements.txt in the
# target source tree is the single source of truth, and Phase 5 reads it into
# PINS[] before anything destructive happens. Pinning them a second time in this
# script is precisely what broke --offline: prepare-offline.sh downloaded the
# wheels requirements.txt resolved to (gunicorn 26.0.0, cryptography 44.0.2,
# PyYAML 6.0.2, confluent-kafka 2.14.0) while this script asked pip for four
# different versions that were never in the bundle. Two lists, one truth.
declare -A PINS=()
PIN_FLASK=""; PIN_WERKZEUG=""; PIN_GUNICORN=""; PIN_LDAP3=""
PIN_PYYAML=""; PIN_CRYPTOGRAPHY=""; PIN_CONFLUENT_KAFKA=""

# Frontend third-party lib, pinned BY CONTENT — a version in a URL is not
# an integrity control.
VUE_VERSION="3.5.43"
VUE_SHA256="b72394052eef1eeda1752db3758ce1be6f88016903f22e5241cc732ea307478e"
VUE_URL="https://cdn.jsdelivr.net/npm/vue@${VUE_VERSION}/dist/vue.global.prod.js"

# Paths whose ownership and mode are captured before the upgrade and put back
# exactly afterwards.
BASELINE_PATHS=(
  "$APP_HOME" "${APP_HOME}/tm" "${APP_HOME}/data" "${APP_HOME}/logs"
  "${APP_HOME}/venv" "${APP_HOME}/wsgi.py" "${APP_HOME}/data/tm.db"
  "$FRONTEND_DIR" "${FRONTEND_DIR}/index.html" "${FRONTEND_DIR}/app"
  "${FRONTEND_DIR}/lib" "${FRONTEND_DIR}/lib/vue.global.prod.js"
  "$CONFIG_DIR" "${CONFIG_DIR}/config.yaml" "${CONFIG_DIR}/tls"
  "$CLUSTERS_DIR" "$CLUSTERS_FILE" "$CERT_DIR"
  "${CONFIG_DIR}/tls/server.crt" "${CONFIG_DIR}/tls/server.key"
  "${CONFIG_DIR}/tls/chain.pem"
  "/etc/nginx/sites-available/topic-manager"
  "/etc/nginx/snippets/tm-security-headers.conf"
  "/etc/systemd/system/topic-manager.service"
  "$DROPIN_DIR"
  "/etc/logrotate.d/topic-manager"
)

V120_UNITS=(topic-manager-apply-syslog.service topic-manager-apply-time.service
            topic-manager-apply-nginx.service topic-manager-apply-tls.service
            topic-manager-audit-prune.service topic-manager-audit-prune.timer
            topic-manager-apply-audit.service topic-manager-apply-audit.path)

# ─── the run's verdict, as its last line (clean-room round 6, M1) ───────────
# The docs tell the operator to run this detached (sudo setsid nohup … &) and
# to judge the run by its exit code — which a detached run throws away. So
# every exit from here on ends the output, and the script's own log, with
# "RESULT: exit <N>"; _on_exit (armed for the destructive phases) prints it
# after its rollback. README and docs/INSTALL.md say how to read it (t47).
result_line() { echo "RESULT: exit $1"; }
trap 'result_line "$?"' EXIT

# ─── flags ───────────────────────────────────────────────────────────────────
SKIP_OS=false; OFFLINE_FORCED=false; BACKUP_ONLY=false; DRY_RUN=false
AUDIT_ONLY=false; LIST_BACKUPS=false; FORCE=false; RESTORE_TS=""
NO_BIND_PROBE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-os)       SKIP_OS=true ;;
        --offline)       OFFLINE_FORCED=true ;;
        --backup-only)   BACKUP_ONLY=true ;;
        --dry-run)       DRY_RUN=true ;;
        --audit-only)    AUDIT_ONLY=true ;;
        --list-backups)  LIST_BACKUPS=true ;;
        --force)         FORCE=true ;;
        --no-bind-probe) NO_BIND_PROBE=true ;;
        --repo-url)      shift; REPO_URL="${1:-}"
                         [[ -n "$REPO_URL" ]] || { echo "--repo-url needs a git URL" >&2; exit 2; } ;;
        --repo-branch)   shift; REPO_BRANCH="${1:-}"
                         [[ -n "$REPO_BRANCH" ]] || { echo "--repo-branch needs a branch or tag" >&2; exit 2; } ;;
        --repo-commit)   shift; REPO_COMMIT="${1:-}"
                         [[ -n "$REPO_COMMIT" ]] || { echo "--repo-commit needs a 40-hex commit id" >&2; exit 2; } ;;
        --restore)       shift; RESTORE_TS="${1:-}"
                         [[ -n "$RESTORE_TS" ]] || { echo "--restore needs a timestamp (see --list-backups)" >&2; exit 2; } ;;
        -h|--help)       sed -n '2,62p' "$0"; exit 0 ;;
        *)               echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# ─── output helpers ──────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info()    { echo "${CYAN}[INFO]${NC}    $*"; }
success() { echo "${GREEN}[OK]${NC}      $*"; }
warn()    { echo "${YELLOW}[WARN]${NC}    $*"; }
phase()   { echo; echo "${BOLD}── $* ─────────────────────────────────────────${NC}"; }
fail()    { echo "${RED}[FAIL]${NC}    $*" >&2; exit 1; }

# ─── the package lock ────────────────────────────────────────────────────────
# MEASURED on the air-gapped STIG + FIPS clean-room host (2026-09-29):
# unattended-upgrades held dpkg's lock for ~4.5 minutes while it tried to
# reach an archive it never will, and `install.sh --packages-only` failed at
# once with a message that sent the operator to `dpkg --audit` (which was
# clean). Every apt/dpkg step now WAITS for the lock first, bounded
# (TM_DPKG_LOCK_WAIT_S, default 600 s), naming the process that holds it, and
# apt is given the same bound (-o DPkg::Lock::Timeout) for the moment between
# the wait and its own lock. Byte-identical in install.sh and
# install/upgrade-full.sh (t47).
DPKG_LOCKS=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock)
APT_LOCKS=(/var/lib/apt/lists/lock /var/cache/apt/archives/lock)
DPKG_LOCK_WAIT_S="${TM_DPKG_LOCK_WAIT_S:-600}"

# dpkg_lock_holder <lock-file>... — "<lock-file>, held by PID <pid> (<name>)"
# for the first of them some process holds, or nothing. dpkg and apt take
# POSIX (fcntl) locks, and the kernel lists every one in /proc/locks by
# device and inode, so this reads that and needs no tool (fuser and lslocks
# are not on every STIG host).
dpkg_lock_holder() {   # dpkg_lock_holder <lock-file>...
    local f dev ino key line pid comm
    local -a w
    [[ -r /proc/locks ]] || return 0
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        dev="$(stat -c %d -- "$f" 2>/dev/null)" && ino="$(stat -c %i -- "$f" 2>/dev/null)" || continue
        key="$(printf '%02x:%02x:%s' $(( (dev >> 8) & 0xfff )) $(( (dev & 0xff) | ((dev >> 12) & 0xfff00) )) "$ino")"
        while IFS= read -r line; do
            read -r -a w <<<"$line"
            [[ "${w[1]:-}" == "->" ]] && continue          # a waiter, not the holder
            [[ "${w[5]:-}" == "$key" ]] || continue
            pid="${w[4]}"
            comm="$(cat "/proc/${pid}/comm" 2>/dev/null || echo unknown)"
            echo "${f}, held by PID ${pid} (${comm})"
            return 0
        done < /proc/locks
    done
    return 0
}

# wait_for_dpkg_lock [<lock-file>...] — 0 once none of them is held (default:
# dpkg's two); 1, having named the holder, if one still is after
# DPKG_LOCK_WAIT_S seconds.
wait_for_dpkg_lock() {   # wait_for_dpkg_lock [<lock-file>...]
    local waited=0 holder said="" locks=("$@")
    [[ ${#locks[@]} -gt 0 ]] || locks=("${DPKG_LOCKS[@]}")
    while holder="$(dpkg_lock_holder "${locks[@]}")"; [[ -n "$holder" ]]; do
        if (( waited >= DPKG_LOCK_WAIT_S )); then
            warn "The package lock is STILL held after ${DPKG_LOCK_WAIT_S}s: ${holder}."
            warn "  Usually unattended-upgrades (on an air-gapped host it retries an archive it cannot"
            warn "  reach). Let it finish, or stop it: sudo systemctl stop unattended-upgrades apt-daily.service"
            warn "  apt-daily-upgrade.service; then run this again. A longer wait: TM_DPKG_LOCK_WAIT_S=<seconds>."
            return 1
        fi
        if [[ "$holder" != "$said" ]] || (( waited % 60 == 0 && waited > 0 )); then
            info "Waiting for the package lock (${holder}); ${waited}s of up to ${DPKG_LOCK_WAIT_S}s ..."
            said="$holder"
        fi
        sleep 1; waited=$((waited + 1))
    done
    [[ -z "$said" ]] || info "The package lock was released after ${waited}s"
    return 0
}

[[ $EUID -eq 0 ]] || fail "Run with sudo: sudo bash upgrade-full.sh"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Log: ${LOG_FILE}"

# ─── permission baseline helpers ─────────────────────────────────────────────
# The host's current ownership and modes are the authority. On a STIG'd system
# they have been deliberately narrowed; re-imposing this script's defaults
# would quietly undo that hardening. So: record, then put back exactly.

# THE RECORD FORMAT IS NUL-DELIMITED: path\0owner\0group\0mode\0, four fields
# per record and no line structure at all.
#
# It used to be '%p|%u|%g|%m\n'. A filename may contain BOTH '|' and a newline,
# and www-data owns /var/www/topic-manager — so a file created there and named
#     evil<newline>/etc/shadow|root|root|777
# put a whole extra RECORD into the baseline, which root later replayed as a
# chown and a chmod on a path of the attacker's choosing. NUL is the one byte a
# filename cannot contain, which is why find(1) offers it and why every consumer
# below reads with `read -d ''`.
record_baseline() {
    local out="$1"; : > "$out"; chmod 600 "$out"
    local p
    for p in "${BASELINE_PATHS[@]}"; do
        [[ -e "$p" ]] || continue
        printf '%s\0%s\0%s\0%s\0' "$p" \
            "$(stat -c '%U' "$p")" "$(stat -c '%G' "$p")" "$(stat -c '%a' "$p")" >> "$out"
    done
    # Every file actually served to browsers, so the restore can reproduce
    # exactly what nginx was able to read before.
    if [[ -d "$FRONTEND_DIR" ]]; then
        find "$FRONTEND_DIR" -mindepth 1 \( -type f -o -type d \) -printf '%p\0%u\0%g\0%m\0' >> "$out"
    fi
    # Every drop-in file individually, not just the directory. These carry the
    # secret_key and the LDAP bind password, so a restore that widened one from
    # 0600 to the directory's default would expose them to every local account.
    if [[ -d "$DROPIN_DIR" ]]; then
        find "$DROPIN_DIR" -mindepth 1 \( -type f -o -type d \) -printf '%p\0%u\0%g\0%m\0' >> "$out"
    fi
}

# baseline_count <file> — how many records the baseline holds. It is
# NUL-delimited quadruples (path, owner, group, mode), so a record is four
# NULs; `wc -l` counted newlines, which the format never writes, and the
# upgrade reported "Baseline recorded (0 paths)" on every run (REG-0018).
baseline_count() {
    local nul
    nul="$(tr -cd '\000' < "$1" | wc -c)"
    echo $(( nul / 4 ))
}

# baseline_stream <file> — emit the baseline as NUL-delimited quadruples,
# whichever format the file on disk is in.
#
# A backup taken before v1.0.4 holds the old pipe format, and `--restore` is
# exactly the path where a NEW script reads an OLD backup. Reading one of those
# with the NUL reader would find no record at all and report "restored 0 paths"
# — a silent no-op on the one operation whose entire purpose is putting
# permissions back. So the legacy shape is converted here instead.
#
# It never calls fail(), and it never prints a diagnostic: it runs inside a
# process substitution, where an exit would only kill the subshell and leave the
# caller reading a truncated stream, and where anything on stdout would be read
# back AS A RECORD. Malformed legacy records are passed through verbatim and
# refused by baseline_assert_record in the caller, which runs in the shell that
# can actually stop. A legacy record for a path containing '|' therefore arrives
# with a mode field like "www-data|644", fails the octal test, and stops the run
# — the honest outcome, because that format cannot represent such a path at all.
baseline_stream() {
    local bl="$1" line f1 f2 f3 f4
    [[ -n "$bl" && -s "$bl" ]] || return 0
    if ! baseline_is_legacy "$bl"; then
        cat -- "$bl"
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        IFS='|' read -r f1 f2 f3 f4 <<<"$line"
        printf '%s\0%s\0%s\0%s\0' "$f1" "$f2" "$f3" "$f4"
    done < "$bl"
}

# baseline_is_legacy <file> — true for a pre-v1.0.4 pipe-delimited baseline.
# NUL cannot be held in a shell variable, so the format is measured by length:
# a file that shortens when NULs are deleted contained NULs.
baseline_is_legacy() {
    local bl="$1" total stripped
    [[ -n "$bl" && -s "$bl" ]] || return 1
    total="$(wc -c < "$bl")"
    stripped="$(LC_ALL=C tr -d '\000' < "$bl" | wc -c)"
    [[ "$total" -eq "$stripped" ]]
}

# baseline_assert_record <path> <owner> <group> <mode>
# Every field of a record is attacker-influenced until this says otherwise, and
# the caller is about to run chown and chmod AS ROOT with all four. Sets
# BASELINE_REAL_PATH on success.
#
# It returns the resolved path in a GLOBAL rather than on stdout on purpose:
# real="$(baseline_assert_record ...)" would run fail() inside a command
# substitution, where exit only leaves the subshell and the run carries on.
BASELINE_REAL_PATH=""
_BASELINE_REAL=()
_BASELINE_REAL_INIT=""
baseline_assert_record() {
    local fp="$1" fo="$2" fg="$3" fm="$4" real fe di p
    [[ "$fm" =~ ^[0-7]{3,4}$ ]] \
        || fail "Permission baseline: the mode field for ${fp} is not octal: '${fm}'.
     Nothing was chowned or chmodded. This is what a record the format cannot
     represent — or a forged one — looks like."
    [[ "$fo" =~ ^[A-Za-z0-9._@-]+$ && "$fg" =~ ^[A-Za-z0-9._@-]+$ ]] \
        || fail "Permission baseline: the owner/group fields for ${fp} are not names: '${fo}:${fg}'."
    # A recorded path that is NOW a symlink is a swap, full stop.
    # record_baseline only records files and directories (find -type f -o
    # -type d), so a symlink at a recorded path was put there afterwards —
    # and chmod(1) has no --no-dereference, so replaying the record would
    # follow it. Refuse on the LINK, not on where it points: that is a
    # question with one answer, and it does not depend on resolving anything.
    [[ -L "$fp" ]] \
        && fail "Permission baseline: ${fp} is a symlink now and was not when it
     was recorded. Nothing was chowned or chmodded. chmod would follow it to
     $(readlink -f -- "$fp" 2>/dev/null || echo 'wherever it points')."
    # LEXICAL normalisation (-s), NOT resolution. MEASURED 2026-09-01: with a
    # resolved allowlist this check validated the attack against itself — the
    # allowlist is built from the SAME recorded paths, so resolving it followed
    # the attacker's symlink and the record then matched its own target. The
    # comparison has to be about the path that was RECORDED, not about where
    # the filesystem points today.
    real="$(realpath -m -s -- "$fp")"
    fe="$(realpath -m -s -- "$FRONTEND_DIR")"
    di="$(realpath -m -s -- "$DROPIN_DIR")"
    case "$real" in
        "$fe"/*|"$di"/*) BASELINE_REAL_PATH="$real"; return 0 ;;
    esac
    # The recorded set is not only those two trees: BASELINE_PATHS also names
    # config.yaml, the nginx site, the unit and more. The allowlist is derived
    # from that array rather than written out a second time, so it cannot drift
    # from what record_baseline actually writes.
    # Built once, and built HERE rather than depending on a declaration
    # somewhere above: under `set -u` a function that reads an array it did not
    # create is one refactor away from aborting the run it is meant to guard.
    if [[ -z "${_BASELINE_REAL_INIT:-}" ]]; then
        _BASELINE_REAL=()
        for p in "${BASELINE_PATHS[@]}"; do _BASELINE_REAL+=("$(realpath -m -s -- "$p")"); done
        _BASELINE_REAL_INIT=1
    fi
    for p in "${_BASELINE_REAL[@]}"; do
        if [[ "$real" == "$p" ]]; then BASELINE_REAL_PATH="$real"; return 0; fi
    done
    fail "Permission baseline record points outside the recorded roots:
     recorded as ${fp}
     resolves to ${real}
     Nothing was chowned or chmodded. record_baseline can only produce paths
     under ${FRONTEND_DIR}, under ${DROPIN_DIR}, or exactly one of the
     BASELINE_PATHS entries, so this record is corrupt or forged."
}

# baseline_lookup <file> <path> — the recorded owner, group and mode for ONE
# path as owner<TAB>group<TAB>mode, or exit 1 when the path is not recorded.
# An EXACT path comparison: the previous lookup was a grep for "<path>|", which
# is anchored on the separator but is still a substring match against the whole
# file.
baseline_lookup() {
    local bl="$1" want="$2" fp fo fg fm
    [[ -n "$bl" && -f "$bl" ]] || return 1
    while IFS= read -r -d '' fp && IFS= read -r -d '' fo \
       && IFS= read -r -d '' fg && IFS= read -r -d '' fm; do
        if [[ "$fp" == "$want" ]]; then
            printf '%s\t%s\t%s\n' "$fo" "$fg" "$fm"
            return 0
        fi
    done < <(baseline_stream "$bl")
    return 1
}

# baseline_has <file> <path> — is this path in the recorded set at all?
baseline_has() { baseline_lookup "$1" "$2" >/dev/null; }

# apply_baseline <path> [fallback_owner] [fallback_group] [fallback_mode]
# Restores the recorded owner/mode. Falls back only when the path is new.
apply_baseline() {
    local p="$1" fo="${2:-}" fg="${3:-}" fm="${4:-}" rec o g mo
    [[ -e "$p" ]] || return 0
    if rec="$(baseline_lookup "$PERM_BASELINE" "$p")"; then
        IFS=$'\t' read -r o g mo <<<"$rec"
        baseline_assert_record "$p" "$o" "$g" "$mo"
        chown -h "${o}:${g}" -- "$p" || fail "chown failed on ${p}"
        chmod "$mo" -- "$p" || fail "chmod failed on ${p}"
        return 0
    fi
    [[ -n "$fo" && -n "$fg" ]] && chown "${fo}:${fg}" "$p" 2>/dev/null || true
    [[ -n "$fm" ]] && chmod "$fm" "$p" 2>/dev/null || true
}

# assert_root_owned_path <dir> — refuse to read code from anywhere an
# unprivileged account could have influenced. Walks the directory AND every
# ancestor: a root-owned leaf under a user-writable parent is still swappable.
assert_root_owned_path() {
    local d; d="$(cd "$1" 2>/dev/null && pwd -P)" || fail "Cannot resolve $1"
    local cur="$d"
    while : ; do
        local owner mode
        owner="$(stat -c '%U' "$cur" 2>/dev/null)" || fail "Cannot stat ${cur}"
        mode="$(stat -c '%a' "$cur" 2>/dev/null)"
        [[ "$owner" == "root" ]] \
            || fail "${cur} is owned by '${owner}', not root.
     Root would execute code from a path an unprivileged account controls.
     Fix: sudo chown root:root ${cur}"
        # group- or other-writable without the sticky bit lets another account
        # replace entries even when the directory itself is root-owned.
        if [[ "${mode: -1}" =~ [2367] || "${mode: -2:1}" =~ [2367] ]]; then
            [[ "${#mode}" -eq 4 && "${mode:0:1}" =~ [1357] ]] \
                || fail "${cur} is group/other-writable (mode ${mode}) and not sticky.
     Fix: sudo chmod go-w ${cur}"
        fi
        [[ "$cur" == "/" ]] && break
        cur="$(dirname "$cur")"
    done
    info "Verified root-owned, non-writable path: ${d}"
}

# safe_install_dir <mode> <owner> <group> <path> — install -d that refuses to
# work through a symlink.
#
# install -d on an existing path is chmod() + chown(), and both FOLLOW symlinks.
# $CERT_DIR's parent (/opt/topic-manager/data) is app-owned and inside the
# unit's ReadWritePaths, so the application can replace cluster-certs with a
# symlink to anything and have root apply an owner and a mode to the target on
# the next upgrade or reinstall. It is REFUSED, never
# detected afterwards (that would be reporting a chown that already ran), and
# never by a path check followed by install -d (round 4: see below).
safe_install_dir() {   # safe_install_dir <mode> <owner> <group> <path>
    # THROUGH FILE DESCRIPTORS (round 4, sec-review TM-SEC-002, CWE-367). The
    # old guard checked [[ -L ]] and then ran install -d, which resolves the
    # path AGAIN and chmods/chowns whatever is there by then: a window in
    # which the service account (it owns ${APP_HOME}) could swap the
    # directory, or any directory ABOVE it, for a symlink. Here every
    # component from / is opened relative to its parent's descriptor with
    # O_NOFOLLOW, and fchown/fchmod act on the descriptor that was opened, so
    # nothing is resolved twice. A symlink is followed ONLY where root alone
    # could have put it (a parent owned by root and writable by nobody else);
    # anywhere else, and as the last component always, it is refused.
    if ! python3 - "$@" <<'PYSID'
import errno, grp, os, pwd, stat, sys
mode, owner, group, path = int(sys.argv[1], 8), sys.argv[2], sys.argv[3], sys.argv[4]
parts = [c for c in path.split("/") if c]
if not path.startswith("/") or not parts or ".." in parts:
    sys.exit("%s is not an absolute path free of '..'; refusing." % path)
D = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
fd = os.open("/", D)
for i, name in enumerate(parts):
    here, last = "/" + "/".join(parts[:i + 1]), i == len(parts) - 1
    try:
        st = os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        os.mkdir(name, 0o700 if last else 0o755, dir_fd=fd)
        st = os.stat(name, dir_fd=fd, follow_symlinks=False)
    flags = D | os.O_NOFOLLOW
    if stat.S_ISLNK(st.st_mode):
        parent = os.fstat(fd)
        if last or parent.st_uid != 0 or parent.st_mode & 0o022:
            sys.exit("%s is a symlink; refusing to apply ownership through it. install -d "
                     "would chmod and chown whatever it points at. Remove it, or put the real "
                     "directory back, and run again." % here)
        flags = D
    elif not stat.S_ISDIR(st.st_mode):
        sys.exit("%s exists and is not a directory." % here)
    try:
        nfd = os.open(name, flags, dir_fd=fd)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR):
            sys.exit("%s is a symlink or not a directory now (it changed while it was being "
                     "opened); refusing to apply ownership through it." % here)
        raise
    os.close(fd)
    fd = nfd
os.fchown(fd, pwd.getpwnam(owner).pw_uid, grp.getgrnam(group).gr_gid)
os.fchmod(fd, mode)
os.close(fd)
PYSID
    then
        fail "Could not create ${4} safely (the line above says why). Nothing was chowned or chmodded through a link."
    fi
}

# enforce_audit_db_modes — the audit database is private to the service
# account (v1.1.0): ${APP_HOME}/data 0700 and tm.db 0600, both owned by
# ${APP_USER}, and the same for SQLite's -wal/-shm/-journal siblings, which
# hold the same rows. Called AFTER anything that copies the database back
# (cp -a keeps the backup's old 0644) or replays a recorded mode (a baseline
# taken on a v1.0.x host records 0644), so it is always the last word.
#
# THROUGH FILE DESCRIPTORS (round 2, sec-review TOCTOU). The application owns
# data/, so a path check followed by chown/chmod BY NAME leaves a window in
# which it can swap a file for a symlink and have root re-own the target. The
# directory is opened O_DIRECTORY|O_NOFOLLOW, each file O_NOFOLLOW relative to
# that descriptor, and fchown/fchmod act on what was opened — a symlink cannot
# be followed at any step, it is refused.
enforce_audit_db_modes() {
    if ! python3 - "${APP_HOME}/data" "$APP_USER" <<'PYFD'
import errno, os, pwd, stat, sys
d, user = sys.argv[1], sys.argv[2]
pw = pwd.getpwnam(user)
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
try:
    dfd = os.open(d, flags)
except FileNotFoundError:
    os.mkdir(d, 0o700)
    dfd = os.open(d, flags)
except OSError as exc:
    if exc.errno in (errno.ELOOP, errno.ENOTDIR):
        sys.exit("%s is a symlink or not a directory; refusing to chown or chmod through it." % d)
    raise
try:
    os.fchown(dfd, pw.pw_uid, pw.pw_gid)
    os.fchmod(dfd, 0o700)
    for name in ("tm.db", "tm.db-wal", "tm.db-shm", "tm.db-journal"):
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
        except FileNotFoundError:
            continue
        except OSError as exc:
            if exc.errno == errno.ELOOP:
                sys.exit("%s/%s is a symlink; refusing to chown or chmod through it. The application "
                         "owns %s, so a link here lets it choose what root changes." % (d, name, d))
            raise
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                sys.exit("%s/%s exists and is not a regular file." % (d, name))
            os.fchown(fd, pw.pw_uid, pw.pw_gid)
            os.fchmod(fd, 0o600)
        finally:
            os.close(fd)
finally:
    os.close(dfd)
PYFD
    then
        fail "Could not make the audit database private (see the line above). Nothing was chowned or chmodded through a link."
    fi
}

# manage_nginx_ssl_protocols <nginx.conf> <backup-path> — v1.1.0.
# The site config sets TLS 1.2/1.3, but the http-level ssl_protocols line in
# nginx.conf is what a scanner (and any other server block) sees, and stock
# Ubuntu ships "TLSv1 TLSv1.1 TLSv1.2 TLSv1.3" there. Every ACTIVE
# ssl_protocols line in nginx.conf is rewritten to TLSv1.2 TLSv1.3; if there
# is none, one is added at the top of the http block.
#   1. back up nginx.conf (cp -a, so owner and mode go with it);
#   2. write the edit to a temp file beside it and move it into place with
#      the original's owner and mode;
#   3. nginx -t; on failure put the backup back, test again, and stop,
#      saying whether the failure was this edit or was already there.
# Never through a symlink, and never on a line it cannot parse: an
# ssl_protocols directive that does not end on its own line is refused.
manage_nginx_ssl_protocols() {
    local conf="$1" bak="$2" tmp want n out
    want='ssl_protocols TLSv1.2 TLSv1.3;'
    [[ -L "$conf" ]] && fail "${conf} is a symlink; refusing to edit through it."
    [[ -f "$conf" ]] || fail "${conf} not found — is nginx installed?"
    if grep -Eq '^[[:space:]]*ssl_protocols[[:space:]]+[^;]*$' "$conf"; then
        fail "${conf} has an ssl_protocols directive that does not end on its own
     line. Refusing to rewrite what cannot be parsed safely. Put it on one line
     (ssl_protocols TLSv1.2 TLSv1.3;) and run again."
    fi
    # ONE DIRECTIVE PER LINE, or refuse (round 2, adversary F2). The rewrite
    # replaces a whole line, so another directive sharing it — before or after
    # the ssl_protocols one — would be silently deleted.
    if grep -Eq '^[[:space:]]*ssl_protocols[[:space:]][^;]*;[[:space:]]*[^[:space:]#]' "$conf" \
       || grep -Eq '^[[:space:]]*[^#[:space:]][^#]*[;{}][[:space:]]*ssl_protocols[[:space:]]' "$conf"; then
        fail "${conf} has an ssl_protocols directive sharing its line with another
     directive. Refusing to rewrite it, because the rewrite would delete the
     other one. Put ssl_protocols on a line of its own and run again."
    fi
    cp -a -- "$conf" "$bak" || fail "could not back up ${conf} to ${bak}"
    tmp="$(mktemp "${conf}.tm-XXXXXX")" || fail "could not create a temp file beside ${conf}"
    n="$(grep -Ec '^[[:space:]]*ssl_protocols[[:space:]]' "$conf" || true)"
    if [[ "${n:-0}" -gt 0 ]]; then
        # NEVER WIDEN (round 2, sec-review #17): what is kept is the
        # operator's own list MINUS anything below TLS 1.2. A TLSv1.3-only
        # line stays TLSv1.3-only; only a line left with nothing approved
        # becomes TLSv1.2 TLSv1.3.
        awk '
            /^[[:space:]]*ssl_protocols[[:space:]][^;]*;/ {
                match($0, /^[[:space:]]*/)
                ind = substr($0, 1, RLENGTH)
                body = substr($0, RLENGTH + 1)
                body = substr(body, 1, index(body, ";") - 1)
                n = split(body, tok, /[[:space:]]+/)
                keep = ""
                for (i = 2; i <= n; i++)
                    if (tok[i] == "TLSv1.2" || tok[i] == "TLSv1.3")
                        keep = keep (keep == "" ? "" : " ") tok[i]
                if (keep == "") keep = "TLSv1.2 TLSv1.3"
                print ind "ssl_protocols " keep "; # managed by Topic Manager: TLS 1.2/1.3 only"
                next
            }
            { print }' "$conf" > "$tmp"
    else
        grep -Eq '^[[:space:]]*http[[:space:]]*[{]' "$conf" \
            || { rm -f "$tmp"; fail "${conf} has no ssl_protocols line and no http { block to add one to."; }
        awk -v want="$want" '
            { print }
            !done && /^[[:space:]]*http[[:space:]]*[{]/ {
                print "\t" want " # managed by Topic Manager: TLS 1.2/1.3 only"
                done = 1
            }' "$conf" > "$tmp"
    fi
    chown --reference="$conf" -- "$tmp" && chmod --reference="$conf" -- "$tmp" \
        || { rm -f "$tmp"; fail "could not give the edited nginx.conf its original owner and mode"; }
    mv -f -- "$tmp" "$conf" || { rm -f "$tmp"; fail "could not move the edited nginx.conf into place"; }
    if out="$(nginx -t 2>&1)"; then
        info "nginx.conf: ssl_protocols holds TLS 1.2/1.3 only (backup: ${bak}); nginx -t passed"
        return 0
    fi
    cp -a -- "$bak" "$conf" || fail "nginx -t FAILED after the TLS edit AND the backup
     could not be put back. Restore it by hand: sudo cp -a ${bak} ${conf}
     nginx -t said: ${out}"
    if nginx -t >/dev/null 2>&1; then
        fail "nginx -t failed after setting ssl_protocols in ${conf}, so the original
     was put back (nginx -t passes with it). Nothing else was changed.
     nginx -t said: ${out}"
    fi
    fail "nginx -t fails with OR without the TLS edit, so the problem is elsewhere
     in the nginx configuration (often a missing certificate). ${conf} was put
     back as it was. nginx -t said: ${out}"
}

# tls_keypair_matches <cert.pem> <key.pem> — exit 0 only when the certificate's
# public key and the private key's public half are the SAME, compared raw.
# Key-type agnostic (RSA, EC, Ed25519): `openssl rsa -modulus` is RSA-only and
# reported every EC pair as a mismatch. Never hashes first: two failed commands
# produce two empty strings, and sha256 of nothing equals sha256 of nothing.
tls_keypair_matches() {
    local c k
    c="$(openssl x509 -noout -pubkey -in "$1" 2>/dev/null || true)"
    k="$(openssl pkey -pubout -in "$2" 2>/dev/null || true)"
    [[ "$c" == *"-----BEGIN PUBLIC KEY-----"*"-----END PUBLIC KEY-----"* ]] || return 1
    [[ "$k" == *"-----BEGIN PUBLIC KEY-----"*"-----END PUBLIC KEY-----"* ]] || return 1
    [[ "$c" == "$k" ]]
}

# ldap_config_missing <python> <config.yaml> — prints the REQUIRED directory
# keys that are absent, blank or still an unfilled <placeholder>, space
# separated; prints nothing when sign-in is configured, and ERROR:... when the
# file cannot be read. The same rule as tm/auth.py missing_ldap_keys, and a
# byte-identical copy lives in install/upgrade-full.sh (t20 holds all three to
# the same answers). v1.1.0 removed the application's built-in directory
# defaults, so a config that relied on them would lock every user out.
ldap_config_missing() {
    "$1" - "$2" <<'PYKEYS'
import sys
from urllib.parse import urlsplit
try:
    import yaml
    with open(sys.argv[1], encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}
except Exception as exc:
    print("ERROR:%s" % type(exc).__name__)
    sys.exit(0)
auth = cfg.get("auth") if isinstance(cfg, dict) else None
auth = auth if isinstance(auth, dict) else {}
missing = []
for key in ("ldap_server", "ldap_base_dn", "ldap_domain"):
    value = str(auth.get(key) or "").strip()
    if not value or ("<" in value and ">" in value):
        missing.append(key)
    elif key == "ldap_server":
        # PARSED, exact scheme (tm/auth.py is_ldaps_url): only ldaps:// with a host.
        try:
            parts = urlsplit(value)
            ok = parts.scheme.lower() == "ldaps" and bool(parts.hostname)
        except ValueError:
            ok = False
        if not ok:
            missing.append(key)
print(" ".join(missing))
PYKEYS
}

# can_access <user> <test-flag> <path> — the honest check. Mode bits can look
# right while an ACL, a parent directory or a MAC policy still says no, so ask
# the kernel as the actual principal.
can_access() { sudo -u "$1" test "$2" "$3" 2>/dev/null; }

# normalise_frontend_ownership <dir> — round 2 (sec-review): the served tree
# is OWNED BY ROOT and writable by nobody else. Older installs chowned it to
# www-data, so the web server could rewrite the JavaScript every administrator
# runs. Modes are otherwise KEPT, never widened (the rule of this script):
#   * owner -> root; group/other write bits removed;
#   * group -> root when the tree is world-readable (the stock layout, which
#     then becomes root:root 0755/0644); a group-scoped tree (no other-access
#     on the directory, e.g. a STIG's 0750 root:www-data) keeps its group,
#     because that group is how nginx reads it.
# Symlinks are refused. The Phase 12 re-audit then asks the kernel, as
# www-data, whether the files are still readable.
normalise_frontend_ownership() {
    local d="$1" l grp
    [[ -L "$d" ]] && fail "${d} is a symlink; refusing to re-own the frontend through it."
    l="$(find "$d" -type l -print -quit)"
    [[ -z "$l" ]] || fail "${l} is a symlink inside the served tree; refusing. Remove it and re-run."
    if (( 8#$(stat -c '%a' "$d") & 8#005 )); then grp=root; else grp="$(stat -c '%G' "$d")"; fi
    chown -R -h "root:${grp}" -- "$d"
    chmod -R go-w -- "$d"
    info "Frontend owned by root:${grp}, no group/other write (modes otherwise kept)"
}

# verify_clone_commit <dir> <40-hex> — the cloned HEAD must be exactly the
# commit the operator named. Raw comparison of two well-formed 40-hex values;
# an empty or failed rev-parse can never compare equal.
verify_clone_commit() {
    local d="$1" want="$2" got
    got="$(git -C "$d" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
    [[ "$want" =~ ^[0-9a-f]{40}$ && "$got" =~ ^[0-9a-f]{40}$ && "$got" == "$want" ]] \
        || fail "The cloned tree is commit '${got:-<none>}', not the reviewed ${want}.
     The branch or tag moved, or the wrong one was named. Nothing from it was
     read or run; nothing on this host has been changed by the fetch."
    info "Cloned tree verified: HEAD is ${got}"
}

# install_apply_helper <source-tree> — the ROOT apply helper and its two rule
# modules (APPLY_HELPER_FILES, which the install manifest is written from),
# root:root. Byte-identical in install.sh (t38).
install_apply_helper() {   # install_apply_helper <source-tree>
    local src="$1" lx="$OWNED_LIBEXEC_DIR" e m s d
    [[ -L "$lx" || -L "${lx}/lib" ]] && fail "${lx} (or its lib/) is a symlink; refusing to install root code through it."
    install -d -m 755 -o root -g root "$lx" "${lx}/lib"
    for e in "${APPLY_HELPER_FILES[@]}"; do
        read -r m s d <<<"$e"
        install -m "$m" -o root -g root "${src}/${s}" "${lx}/${d}"
    done
}

# install_if_absent <mode> <src> <dest> — the release's default for a managed
# file, ONLY where there is none. Byte-identical in install.sh (t38).
install_if_absent() {   # install_if_absent <mode> <src> <dest>
    [[ -L "$3" ]] && fail "$3 is a symlink; refusing to install through it."
    [[ -e "$3" ]] && return 0
    install -D -m "$1" -o root -g root "$2" "$3"
}

# run_as_app <tm.apply args> — the application's own CLI as the service account.
run_as_app() {
    ( cd / && sudo -u "$APP_USER" env TM_CONFIG="$CONFIG_FILE" TM_CLUSTERS_DIR="$CLUSTERS_DIR" \
        TM_CLUSTER_CERT_DIR="$CERT_DIR" PYTHONPATH="$APP_HOME" PYTHONDONTWRITEBYTECODE=1 \
        "${VENV}/bin/python3" -m tm.apply --by upgrade "$@" )
}

# backup_v120_managed <backup-dir> — every managed file (and the :80 link) as
# it is, plus a marker: a restore point WITH the marker knows which of these
# were absent; one WITHOUT it predates v1.2.0, when none of them existed.
backup_v120_managed() {   # backup_v120_managed <backup-dir>
    local BD="$1" f
    install -d -m 700 "${BD}/system/v120"
    for f in "${V120_MANAGED[@]}"; do
        [[ -e "$f" || -L "$f" ]] || continue
        mkdir -p "${BD}/system/v120$(dirname "$f")"
        cp -a -- "$f" "${BD}/system/v120${f}"
    done
    : > "${BD}/system/v120/.present"
}

# restore_socket_unit <backup-dir> — the gunicorn socket unit, v1.2.0+.
# A restore point that has one gets it back, enabled. One that has NONE is a
# release whose gunicorn bound 127.0.0.1:5001 itself (v1.1.x and earlier), and
# the v1.2.0 unit must GO — restore_owned_artefacts retires it, because the
# host's install manifest records it and the restore point's does not (by
# record, gatekeeper round 6; a restore point of an unknown release with no
# manifest retires nothing and says so): left enabled it would hold /run/topic-manager/gunicorn.sock
# and, on the first connection, start the restored service with LISTEN_FDS
# set — and gunicorn serves a socket systemd hands it INSTEAD of its own
# --bind, so the restored release would stop listening on the port its restored
# nginx site proxies to. Measured in gunicorn 26.2.0 sock.create_sockets: with
# inherited descriptors it returns before binding any configured address.
restore_socket_unit() {   # restore_socket_unit <backup-dir>
    local BD="$1"
    if [[ -f "${BD}/system/topic-manager.socket" ]]; then
        cp -a "${BD}/system/topic-manager.socket" "${OWNED_UNIT_DIR}/topic-manager.socket"
        systemctl enable topic-manager.socket >/dev/null 2>&1 || true
    fi
}

# socket_unit_paths <unit-file> — the filesystem sockets a .socket unit
# listens on (ListenStream/ListenDatagram/ListenSequentialPacket values that
# are absolute paths), one per line. Read from the unit itself, not assumed.
socket_unit_paths() {   # socket_unit_paths <unit-file>
    sed -n -E 's/^[[:space:]]*Listen(Stream|Datagram|SequentialPacket)[[:space:]]*=[[:space:]]*(\/[^[:space:]]+)[[:space:]]*$/\2/p' "$1" 2>/dev/null
}

# unit_runtime_dirs <unit-file> — the RuntimeDirectory= names a unit declares
# (relative to /run; one line may name several), one per line.
unit_runtime_dirs() {   # unit_runtime_dirs <unit-file>
    local line d
    local -a ds
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*RuntimeDirectory[[:space:]]*=(.*)$ ]] || continue
        read -r -a ds <<<"${BASH_REMATCH[1]}"
        for d in "${ds[@]}"; do printf '%s\n' "$d"; done
    done < "$1"
}

# retire_unit <unit-file> — stop and disable a product unit, remove its file
# and, for a socket unit, the socket file it left behind: systemd does not
# delete a Unix socket on stop (RemoveOnStop= defaults to no), so a rollback to
# a TCP release used to leave a dead /run/topic-manager/gunicorn.sock that
# nothing listens on (clean-room R2). The RuntimeDirectory= it declares is
# noted for remove_retired_runtime: with RuntimeDirectoryPreserve=yes it
# outlives the unit, and a rollback left /run/topic-manager-apply and the newer
# release's result files behind (clean-room N5). A retired timer's stamp in
# TIMER_STAMP_DIR goes with it (clean-room round 6, M2). Its enablement links go with
# `systemctl disable`, and those a manifest records are removed by
# restore_owned_artefacts; a drop-in directory or a link no manifest records
# is not the product's and is left (and listed) — gatekeeper round 6, B1.
# A systemctl that could not stop and disable the unit is a RESTORE PROBLEM,
# never ignored (gatekeeper round 5, d): the unit may still be running, or
# still enabled, and the restore's verdict says so (restore_verdict).
retire_unit() {   # retire_unit <unit-file>
    local f="$1" u s rd out
    u="$(basename "$f")"
    local socks=()
    [[ "$u" == *.socket && -f "$f" ]] && mapfile -t socks < <(socket_unit_paths "$f")
    if [[ -f "$f" ]]; then
        while IFS= read -r rd; do RETIRED_RUNTIME+=("$rd"); done < <(unit_runtime_dirs "$f")
    fi
    if ! out="$(systemctl disable --now "$u" 2>&1)"; then
        RESTORE_PROBLEMS+=("systemctl disable --now ${u} failed (${out//$'\n'/ }): it may still be running or enabled")
    fi
    # reset-failed only clears a failed state; it errs on a unit that has none.
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    rm -f -- "$f"
    if [[ "$u" == *.timer ]]; then rm -f -- "${TIMER_STAMP_DIR}/stamp-${u}"; fi
    for s in "${socks[@]}"; do
        [[ -S "$s" ]] && rm -f -- "$s"
        rmdir -- "$(dirname "$s")" 2>/dev/null || true
    done
    RETIRED_UNITS+=("$u")
    info "Retired ${u} (the restore point does not hold it)"
}

# remove_retired_runtime — after the retirements: the runtime directory each
# retired unit declared, under OWNED_RUNTIME_DIR, unless a unit still
# installed declares the same one. A name that is not a plain relative path is
# a restore problem and is left alone.
remove_retired_runtime() {
    local d f keep
    local -A seen=()
    for d in "${RETIRED_RUNTIME[@]}"; do
        [[ -z "${seen[$d]+x}" ]] || continue
        seen["$d"]=1
        if [[ ! "$d" =~ ^[A-Za-z0-9_.@-]+(/[A-Za-z0-9_.@-]+)*$ || "/${d}/" == */../* || "/${d}/" == */./* ]]; then
            RESTORE_PROBLEMS+=("a retired unit declared RuntimeDirectory=${d}, which is not a plain name under ${OWNED_RUNTIME_DIR}: left as it is")
            continue
        fi
        keep=""
        shopt -s nullglob
        for f in "${OWNED_UNIT_DIR}"/*; do
            [[ -f "$f" ]] || continue
            [[ $'\n'"$(unit_runtime_dirs "$f")"$'\n' == *$'\n'"${d}"$'\n'* ]] && keep="${f##*/}"
        done
        shopt -u nullglob
        if [[ -n "$keep" ]]; then
            info "Kept ${OWNED_RUNTIME_DIR}/${d}: ${keep} still declares it"
        elif [[ -e "${OWNED_RUNTIME_DIR}/${d}" || -L "${OWNED_RUNTIME_DIR}/${d}" ]]; then
            rm -rf -- "${OWNED_RUNTIME_DIR:?}/${d}"
            info "Removed ${OWNED_RUNTIME_DIR}/${d} (the runtime directory of a retired unit)"
        fi
    done
}

# location_inventory — "<field> <path>" for everything in the places a release
# lays artefacts down (the unit directory, its drop-in directories and the
# links in and one level below it, the polkit rules, the helper tree), whoever
# put it there: field is the sha256 of a file, "dir", or "link:<target>". It
# decides NOTHING. It is how a restore can say which files another tool or an
# operator added, changed or removed since the restore point, all of which it
# leaves exactly as they are. The service's own drop-in (DROPIN_DIR) is not
# in it: backup_dropin/restore_dropin own it, because it holds secrets.
location_inventory() {
    local p f
    {
        shopt -s nullglob
        for p in "${OWNED_UNIT_DIR}"/* "${OWNED_UNIT_DIR}"/*/* "${OWNED_POLKIT_DIR}"/*; do
            [[ "$p" == "$DROPIN_DIR" || "$p" == "$DROPIN_DIR"/* || "$p" == *$'\n'* ]] && continue
            if [[ -L "$p" ]]; then
                printf 'link:%s %s\n' "$(readlink -- "$p")" "$p"
            elif [[ -f "$p" ]]; then
                f="$(sha256sum < "$p")"; printf '%s %s\n' "${f%% *}" "$p"
            elif [[ -d "$p" && "$p" == *.d ]]; then
                printf 'dir %s\n' "$p"
            fi
        done
        shopt -u nullglob
        # An if, not `test && find`: on a host without the helper (every
        # 1.1.x host) that would end the group non-zero, and under pipefail
        # abort Phase 4.
        if [[ -d "$OWNED_LIBEXEC_DIR" && ! -L "$OWNED_LIBEXEC_DIR" ]]; then
            while IFS= read -r -d '' p; do
                if [[ -f "$p" && ! -L "$p" ]]; then
                    f="$(sha256sum < "$p")"; printf '%s %s\n' "${f%% *}" "$p"
                elif [[ -d "$p" && ! -L "$p" ]]; then
                    printf 'dir %s\n' "$p"
                elif [[ -L "$p" ]]; then
                    printf 'link:%s %s\n' "$(readlink -- "$p")" "$p"
                fi
            done < <(find "$OWNED_LIBEXEC_DIR" -print0)
        fi
    } | sort -k2 -u
}

# legacy_artefacts <version> — "<kind> <path>" for a release that wrote no
# install manifest, from LEGACY_V11X_ARTEFACTS; non-zero for any version that
# list does not cover.
legacy_artefacts() {   # legacy_artefacts <version>
    local v
    for v in "${LEGACY_V11X_VERSIONS[@]}"; do
        if [[ "$1" == "$v" ]]; then
            printf '%s\n' "${LEGACY_V11X_ARTEFACTS[@]}"
            return 0
        fi
    done
    return 1
}

# same_artefact <a> <b> — the same link target, both directories, or the same bytes.
same_artefact() {   # same_artefact <a> <b>
    if [[ -L "$1" || -L "$2" ]]; then
        [[ -L "$1" && -L "$2" && "$(readlink -- "$1")" == "$(readlink -- "$2")" ]]
    elif [[ -d "$1" || -d "$2" ]]; then
        [[ -d "$1" && -d "$2" ]]
    else
        cmp -s -- "$1" "$2"
    fi
}

# backup_owned_artefacts <backup-dir> <installed-version> — Phase 4. The
# restore point's record of what is the product's: the host's install manifest
# as it is; on a host with none, a manifest DERIVED from the shipped list of
# the installed release (legacy_artefacts: v1.1.x), marked "# derived"; for
# any other version none at all, and a rollback to this point will retire
# nothing (it says so now, and again then). Then a byte-exact copy of every
# recorded artefact, and the location inventory.
backup_owned_artefacts() {   # backup_owned_artefacts <backup-dir> <installed-version>
    local BD="$1" v="${2:-unknown}" rec="${1}/manifest/installed-files.manifest" kind p h d
    location_inventory > "${BD}/manifest/host-locations.list"
    if [[ -f "$INSTALL_MANIFEST" ]]; then
        cp -- "$INSTALL_MANIFEST" "$rec"
    elif legacy_artefacts "$v" >/dev/null; then
        {
            printf '# derived: v%s wrote no install manifest; its shipped list (LEGACY_V11X_ARTEFACTS) as found on this host\n' "$v"
            while read -r kind p; do
                if [[ "$kind" == link && -L "$p" ]]; then
                    printf 'link %s\n' "$p"
                elif [[ "$kind" == file && -f "$p" && ! -L "$p" ]]; then
                    h="$(sha256sum < "$p")"; printf '%s %s\n' "${h%% *}" "$p"
                fi
            done < <(legacy_artefacts "$v")
        } > "$rec"
    else
        warn "v${v} wrote no install manifest, and this script carries no shipped list for it:"
        warn "  a rollback to this restore point cannot tell its units from any other tool's,"
        warn "  so it will retire none of them and report RESTORE INCOMPLETE with the list."
        return 0
    fi
    while read -r h p; do
        [[ -n "$h" && "$h" != \#* && "$h" != state && "$h" != pending ]] || continue
        [[ -e "$p" || -L "$p" ]] || continue
        d="${BD}/system/owned${p}"
        if [[ -d "$p" && ! -L "$p" ]]; then
            mkdir -p -- "$d"; chmod --reference="$p" -- "$d"; chown --reference="$p" -- "$d"
        else
            mkdir -p -- "$(dirname "$d")"; cp -a -- "$p" "$d"
        fi
    done < "$rec"
}

# restore_point_copy <backup-dir> <path> — the restore point's copy of a
# recorded artefact: the copy Phase 4 made, or (a restore point older than the
# manifest) the one it has always kept of the service unit, the nginx site
# and snippet and the logrotate file. Prints nothing if none.
restore_point_copy() {   # restore_point_copy <backup-dir> <path>
    local BD="$1" p="$2" c
    c="${BD}/system/owned${p}"
    if [[ ! -e "$c" && ! -L "$c" ]]; then
        case "$p" in
            "${OWNED_UNIT_DIR}/topic-manager.service") c="${BD}/system/topic-manager.service" ;;
            /etc/nginx/sites-available/topic-manager) c="${BD}/system/topic-manager.nginx" ;;
            /etc/nginx/snippets/tm-security-headers.conf) c="${BD}/system/tm-security-headers.conf" ;;
            /etc/logrotate.d/topic-manager) c="${BD}/system/logrotate-topic-manager" ;;
            *) return 0 ;;
        esac
    fi
    if [[ -e "$c" || -L "$c" ]]; then printf '%s' "$c"; fi
}

# set_aside_if_changed <path> <recorded-field> — before a product file is
# retired: if it is not byte-for-byte what the manifest recorded (an operator
# edited it, or an interrupted upgrade installed it and recorded no hash), a
# copy goes to SET_ASIDE_DIR and the restore names it. Never deleted unseen.
set_aside_if_changed() {   # set_aside_if_changed <path> <recorded-field>
    local p="$1" want="$2" got why
    got="$(sha256sum < "$p")"; got="${got%% *}"
    [[ "$want" =~ ^[0-9a-f]{64}$ && "$got" == "$want" ]] && return 0
    why="changed since it was installed"
    [[ "$want" == pending ]] && why="installed by an upgrade that did not finish; no hash was recorded"
    mkdir -p -- "${SET_ASIDE_DIR}${p%/*}"; chmod 700 -- "$SET_ASIDE_DIR"
    cp -a -- "$p" "${SET_ASIDE_DIR}${p}"
    SET_ASIDE+=("${p} (${why}) -> ${SET_ASIDE_DIR}${p}")
}

# restore_owned_artefacts <backup-dir> — make the product's host artefacts
# what the restore point recorded, judged ONLY by the two install manifests
# (gatekeeper round 6, B1): the host's (INSTALL_MANIFEST, plus the .pending
# record of an upgrade that did not finish) says what is the product's NOW,
# the restore point's says what was then. Now and not then = added by the
# release being rolled back: a unit is stopped, disabled and removed
# (retire_unit), a file or link removed, a directory removed once empty — a
# file that is not what its manifest recorded is set aside first. Then = put
# back from the restore point's copy; no copy (and not unchanged) = a restore
# problem. Everything else in these locations is not the product's: never
# stopped, disabled, deleted or changed; what changed since the restore point
# is listed. A restore point with no manifest of a version legacy_artefacts
# does not cover retires NOTHING, and every artefact it could not judge is a
# restore problem (RESTORE INCOMPLETE, exit 1). Operator state (V120_MANAGED)
# is restore_v120_managed's.
restore_owned_artefacts() {   # restore_owned_artefacts <backup-dir>
    local BD="$1" rec="${1}/manifest/installed-files.manifest" f h p v c i
    local -A now=() had=() then_loc=() now_loc=()
    local keys=() units=() files=() dirs=() foreign=()
    SET_ASIDE=()
    # The .pending record first, so a hash the finished manifest recorded wins.
    for f in "${INSTALL_MANIFEST}.pending" "$INSTALL_MANIFEST"; do
        [[ -f "$f" ]] || continue
        while read -r h p; do
            if [[ -n "$h" && "$h" != \#* ]]; then now["$p"]="$h"; fi
        done < "$f"
    done
    if [[ -f "$rec" ]]; then
        while read -r h p; do
            if [[ -n "$h" && "$h" != \#* ]]; then had["$p"]="$h"; fi
        done < "$rec"
    else
        v="$(grep -oP '^topic_manager_version=\K.*' "${BD}/manifest/state.env" 2>/dev/null || true)"
        if legacy_artefacts "$v" >/dev/null; then
            while read -r h p; do had["$p"]="$h"; done < <(legacy_artefacts "$v")
        else
            mapfile -t keys < <(printf '%s\n' "${!now[@]}" | sort)
            for p in "${keys[@]}"; do
                [[ -n "$p" && "${now[$p]}" != state ]] || continue
                [[ -e "$p" || -L "$p" ]] || continue
                RESTORE_PROBLEMS+=("not retired: ${p} — the restore point (v${v:-unknown}) has no install manifest and this script carries no shipped list for that version, so nothing says its release did not ship it")
            done
            warn "The restore point (v${v:-unknown}) has no install manifest: no unit, rule or helper was retired or put back."
            return 0
        fi
    fi

    # Retire: the product's now, not then. Judged before anything is removed.
    mapfile -t keys < <(printf '%s\n' "${!now[@]}" | sort)
    for p in "${keys[@]}"; do
        [[ -n "$p" && -z "${had[$p]+x}" ]] || continue
        h="${now[$p]}"
        [[ "$h" != state ]] || continue
        [[ -e "$p" || -L "$p" ]] || continue
        if [[ "$h" == dir ]]; then
            if [[ -d "$p" && ! -L "$p" ]]; then dirs+=("$p"); fi
            continue
        fi
        if [[ -d "$p" && ! -L "$p" ]]; then
            RESTORE_PROBLEMS+=("${p} is a directory, but the install manifest does not record a directory there: left as it is")
            continue
        fi
        if [[ "$h" != link && ! -L "$p" ]]; then set_aside_if_changed "$p" "$h"; fi
        if [[ "$h" != link && "${p%/*}" == "$OWNED_UNIT_DIR" && ! -L "$p" ]]; then
            units+=("$p")
        else
            files+=("$p")
        fi
    done
    for p in "${units[@]}"; do retire_unit "$p"; done
    for p in "${files[@]}"; do
        rm -f -- "$p"
        # The bytecode Python wrote beside a retired module of the helper's.
        if [[ "$p" == *.py ]]; then
            f="${p##*/}"
            shopt -s nullglob
            for c in "${p%/*}/__pycache__/${f%.py}".*.pyc; do rm -f -- "$c"; done
            shopt -u nullglob
            rmdir -- "${p%/*}/__pycache__" 2>/dev/null || true
        fi
        info "Removed ${p} (the restore point's release does not ship it)"
    done
    # Deepest first, so a directory is empty when its turn comes.
    for (( i=${#dirs[@]}-1; i>=0; i-- )); do
        p="${dirs[$i]}"
        if rmdir -- "$p" 2>/dev/null; then
            info "Removed ${p} (the restore point's release does not ship it)"
        else
            foreign+=("${p}/ (the newer release's directory, left: it holds files no manifest records)")
        fi
    done

    # Put back: the product's then.
    mapfile -t keys < <(printf '%s\n' "${!had[@]}" | sort)
    for p in "${keys[@]}"; do
        [[ -n "$p" ]] || continue
        h="${had[$p]}"
        [[ "$h" != state && "$h" != pending ]] || continue
        c="$(restore_point_copy "$BD" "$p")"
        if [[ "$h" == dir ]]; then
            [[ -L "$p" ]] && rm -f -- "$p"
            mkdir -p -- "$p"
            if [[ -n "$c" && -d "$c" ]]; then chmod --reference="$c" -- "$p"; chown --reference="$c" -- "$p"; fi
        elif [[ -n "$c" ]]; then
            if ! same_artefact "$c" "$p"; then
                mkdir -p -- "$(dirname "$p")"
                rm -rf -- "$p"; cp -a -- "$c" "$p"
            fi
        elif [[ "$h" == link && -L "$p" ]]; then
            :
        elif [[ "$h" == link && "$p" == "${OWNED_UNIT_DIR}"/*.wants/* ]]; then
            mkdir -p -- "${p%/*}"; ln -s -- "${OWNED_UNIT_DIR}/${p##*/}" "$p"
        elif [[ "$h" =~ ^[0-9a-f]{64}$ && -f "$p" && ! -L "$p" ]] && [[ "$(sha256sum < "$p")" == "$h "* ]]; then
            :   # as the restore point recorded it
        else
            RESTORE_PROBLEMS+=("the restore point lists ${p} but holds no copy of it: left as it is")
            warn "The restore point lists ${p} but holds no copy of it — left as it is."
        fi
    done

    # Not the product's by either record: listed, never touched.
    if [[ -f "${BD}/manifest/host-locations.list" ]]; then
        while read -r h p; do then_loc["$p"]="$h"; done < "${BD}/manifest/host-locations.list"
        while read -r h p; do now_loc["$p"]="$h"; done < <(location_inventory)
        mapfile -t keys < <(printf '%s\n' "${!then_loc[@]}" "${!now_loc[@]}" | sort -u)
        for p in "${keys[@]}"; do
            [[ -n "$p" && -z "${now[$p]+x}" && -z "${had[$p]+x}" ]] || continue
            if [[ -z "${then_loc[$p]+x}" ]]; then
                foreign+=("${p} (added since the restore point)")
            elif [[ -z "${now_loc[$p]+x}" ]]; then
                foreign+=("${p} (removed since the restore point)")
            elif [[ "${then_loc[$p]}" != "${now_loc[$p]}" ]]; then
                foreign+=("${p} (changed since the restore point)")
            fi
        done
    fi
    if [[ ${#foreign[@]} -gt 0 ]]; then
        info "Not the product's (no install manifest records them), so this rollback left them exactly as they are:"
        for p in "${foreign[@]}"; do info "    ${p}"; done
    fi
    if [[ ${#SET_ASIDE[@]} -gt 0 ]]; then
        warn "Retired product files that were not as installed — a copy of each was kept:"
        for p in "${SET_ASIDE[@]}"; do warn "    ${p}"; done
    fi
    remove_retired_runtime
    systemctl daemon-reload >/dev/null 2>&1 || true
    # The host's record is now the restore point's (none, for a release that kept none).
    if [[ -f "$rec" ]] && ! grep -q '^# derived:' "$rec"; then
        safe_install_dir 700 root root "${INSTALL_MANIFEST%/*}"
        cp -- "$rec" "$INSTALL_MANIFEST"; chmod 600 -- "$INSTALL_MANIFEST"
    else
        rm -f -- "$INSTALL_MANIFEST"
    fi
    rm -f -- "${INSTALL_MANIFEST}.pending"
    info "Host units, rules and helpers restored to the restore point's manifest (${#RETIRED_UNITS[@]} unit(s) retired${RETIRED_UNITS[*]:+: ${RETIRED_UNITS[*]}})"
}

# restore_v120_managed <backup-dir> — put them back exactly; from a restore
# point older than v1.2.0 remove them (the old site file has its own :80
# block, and an enabled topic-manager-http beside it would be a duplicate).
restore_v120_managed() {   # restore_v120_managed <backup-dir>
    local BD="$1" f
    for f in "${V120_MANAGED[@]}"; do
        rm -rf -- "$f"
        if [[ -f "${BD}/system/v120/.present" ]] && [[ -e "${BD}/system/v120${f}" || -L "${BD}/system/v120${f}" ]]; then
            mkdir -p "$(dirname "$f")"
            cp -a -- "${BD}/system/v120${f}" "$f"
        fi
    done
    systemctl try-restart rsyslog.service >/dev/null 2>&1 || true
}

# ─── systemd unit drop-in ────────────────────────────────────────────────────
# ${DROPIN_DIR} is not a system file this script re-creates from the source
# tree — it is where an operator puts TM_SECRET_KEY and TM_LDAP_BIND_PASSWORD
# when the configuration is held in the environment instead of config.yaml.
# Phase 3 reads those values from it. Backing up the unit but not its drop-ins
# meant --restore handed back a service with no secret_key, and the current
# version raises RuntimeError rather than start without one, so the restore
# "succeeded" into a host that would not boot the service.
DROPIN_BACKUP_NAME="topic-manager.service.d"

backup_dropin() {   # backup_dropin <backup-dir>
    local BD="$1"
    [[ -d "$DROPIN_DIR" ]] || return 0
    cp -a "$DROPIN_DIR" "${BD}/system/${DROPIN_BACKUP_NAME}"
    info "Backed up unit drop-in: $(find "$DROPIN_DIR" -mindepth 1 -type f | wc -l) file(s) from ${DROPIN_DIR}"
}

# Asked while nothing has been touched yet: every drop-in file on the host must
# be in the backup by name. A secret that did not reach the restore point is
# indistinguishable from a good backup until the day someone restores.
verify_dropin_backed_up() {   # verify_dropin_backed_up <backup-dir>
    local BD="$1" f rel
    [[ -d "$DROPIN_DIR" ]] || return 0
    while IFS= read -r f; do
        rel="${f#"${DROPIN_DIR}/"}"
        [[ -f "${BD}/system/${DROPIN_BACKUP_NAME}/${rel}" ]] \
            || fail "Unit drop-in ${f} did not reach the backup.
It may carry TM_SECRET_KEY or TM_LDAP_BIND_PASSWORD, and a restore without it
returns a service that refuses to start. Refusing to proceed."
    done < <(find "$DROPIN_DIR" -mindepth 1 -type f)
}

# restore_cluster_store <backup-dir> — round 2 (adversary F5, treated as HIGH).
# The backup has always taken clusters.d/ and data/cluster-certs/, and
# restore_from_backup never put them back: --restore and the automatic
# rollback returned a host whose cluster list and uploaded Kafka TLS material
# were whatever the FAILED upgrade left. Both are now replaced by the backup's
# copy (files added after the backup are removed, as a restore means), then
# given the store's invariants: clusters.d 0750 and cluster-certs 0700, both
# topic-manager-owned; clusters.yaml 0640 and every cert file 0600, owned by
# topic-manager. Never through a symlink: both directories are app-writable.
restore_cluster_store() {   # restore_cluster_store <backup-dir>
    local BD="$1" src l
    for src in "${BD}/etc/clusters.d" "${BD}/data/cluster-certs"; do
        [[ -d "$src" ]] || continue
        l="$(find "$src" -type l -print -quit)"
        [[ -z "$l" ]] || fail "Backup contains a symlink (${l}); refusing to restore through it."
    done
    if [[ -d "${BD}/etc/clusters.d" ]]; then
        safe_install_dir 750 "$APP_USER" "$APP_USER" "$CLUSTERS_DIR"
        find "$CLUSTERS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        cp -a "${BD}/etc/clusters.d/." "${CLUSTERS_DIR}/"
        # cp -a of "dir/." also copies the backup directory's OWN mode onto the
        # target, so the store directory is re-moded after, not only before.
        safe_install_dir 750 "$APP_USER" "$APP_USER" "$CLUSTERS_DIR"
        find "$CLUSTERS_DIR" -mindepth 1 \( -type f -o -type d \) -exec chown -h "${APP_USER}:${APP_USER}" -- {} +
        [[ -f "$CLUSTERS_FILE" ]] && chmod 640 -- "$CLUSTERS_FILE"
        info "Restored cluster profiles to ${CLUSTERS_DIR}"
    fi
    if [[ -d "${BD}/data/cluster-certs" ]]; then
        safe_install_dir 700 "$APP_USER" "$APP_USER" "$CERT_DIR"
        find "$CERT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        cp -a "${BD}/data/cluster-certs/." "${CERT_DIR}/"
        safe_install_dir 700 "$APP_USER" "$APP_USER" "$CERT_DIR"
        find "$CERT_DIR" -mindepth 1 -type f -exec chown -h "${APP_USER}:${APP_USER}" -- {} + -exec chmod 600 -- {} +
        info "Restored Kafka TLS material to ${CERT_DIR} ($(find "$CERT_DIR" -type f | wc -l) file(s))"
    fi
    return 0
}

restore_dropin() {   # restore_dropin <backup-dir>
    # Two statements, deliberately: `local a="$1" b="${a}/x"` expands every
    # argument BEFORE the builtin assigns any of them, so b would read an
    # unset a and `set -u` would abort the whole run here.
    local BD="$1"
    local SRC="${BD}/system/${DROPIN_BACKUP_NAME}"
    if [[ -d "$SRC" ]]; then
        rm -rf "${DROPIN_DIR:?}"
        mkdir -p "$(dirname "$DROPIN_DIR")"
        cp -a "$SRC" "$DROPIN_DIR"
        info "Restored unit drop-in ($(find "$DROPIN_DIR" -mindepth 1 -type f | wc -l) file(s)) to ${DROPIN_DIR}"
        return 0
    fi
    # Deliberately NOT symmetrical with the nginx snippet above, which is
    # removed when the backup lacks it. A snippet the restored nginx config does
    # not reference breaks nginx; a drop-in the restored unit does not need
    # breaks nothing — but deleting it can take away the only copy of the
    # secret_key. Say what was not restored and leave it alone.
    if [[ -d "$DROPIN_DIR" ]] && [[ -n "$(ls -A "$DROPIN_DIR" 2>/dev/null)" ]]; then
        warn "Backup ${BD} contains no unit drop-in — ${DROPIN_DIR} was LEFT AS IT IS."
        warn "  Either it was added after that backup was taken, or the backup predates"
        warn "  drop-in capture. Check TM_SECRET_KEY / TM_LDAP_BIND_PASSWORD before starting."
    fi
    return 0
}

# ─── dependency pins ─────────────────────────────────────────────────────────
# requirements.txt in the TARGET source tree is the only place a Python version
# is decided. load_pins reads it into PINS[<normalised name>]=<version>; the
# stages in Phase 8 then install exactly what it says, and nothing it does not.

load_pins() {
    local req="$1" line name ver
    [[ -f "$req" ]] || fail "No requirements.txt at ${req} — it is the source of every Python pin."
    PINS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] || continue
        [[ "$line" == *'=='* ]] || fail "requirements.txt: '${line}' is not an exact == pin."
        name="${line%%==*}"; ver="${line##*==}"
        [[ -n "$name" && -n "$ver" ]] || fail "requirements.txt: malformed pin '${line}'."
        name="${name,,}"; name="${name//_/-}"; name="${name//./-}"
        PINS["$name"]="$ver"
    done < "$req"
    [[ ${#PINS[@]} -gt 0 ]] || fail "requirements.txt at ${req} pins nothing."
}

# require_pins <normalised name>... — every name given must be pinned, AND every
# pin in the file must be claimed by one of the names. The second half is the
# one that keeps this honest: a dependency added to requirements.txt but not to
# an install stage below would otherwise be downloaded into the offline bundle
# and then never installed, which is the same silent drift in a new costume.
require_pins() {
    local n m claimed missing="" unclaimed=""
    for n in "$@"; do
        [[ -n "${PINS[$n]:-}" ]] || missing="${missing} ${n}"
    done
    [[ -z "${missing// /}" ]] || fail "requirements.txt has no pin for:${missing}"
    # Matched in-shell rather than through `printf | grep -q`: with pipefail set,
    # grep exiting early on a match can SIGPIPE the printf and make a claimed pin
    # look unclaimed. A guard that misfires on timing is not a guard.
    for n in "${!PINS[@]}"; do
        claimed=false
        for m in "$@"; do
            if [[ "$m" == "$n" ]]; then claimed=true; break; fi
        done
        [[ $claimed == true ]] || unclaimed="${unclaimed} ${n}"
    done
    [[ -z "${unclaimed// /}" ]] \
        || fail "requirements.txt pins${unclaimed}, which no Phase 8 install stage handles.
Add it to a stage, or take it out of requirements.txt — an unbundled or
uninstalled dependency is how the offline path broke in the first place."
}

# ─── audit result accounting ─────────────────────────────────────────────────
AUDIT_BLOCK=0; AUDIT_WARN=0
row() {  # row <status> <label> <detail>
    local st="$1" lbl="$2" det="${3:-}" tag
    case "$st" in
        PASS)  tag="${GREEN}PASS ${NC}" ;;
        WARN)  tag="${YELLOW}WARN ${NC}"; AUDIT_WARN=$((AUDIT_WARN+1)) ;;
        BLOCK) tag="${RED}BLOCK${NC}";    AUDIT_BLOCK=$((AUDIT_BLOCK+1)) ;;
        *)     tag="     " ;;
    esac
    printf '  [%b] %-44s %s\n' "$tag" "$lbl" "$det"
    [[ -n "$AUDIT_REPORT" ]] && printf '%s|%s|%s\n' "$st" "$lbl" "$det" >> "$AUDIT_REPORT"
    return 0
}

# ─── restore ─────────────────────────────────────────────────────────────────
restore_from_backup() {
    local BD="$1"
    [[ -d "$BD" ]] || { warn "Backup directory not found: ${BD}"; return 1; }
    if [[ -f "${BD}/SHA256SUMS" ]]; then
        ( cd "$BD" && sha256sum -c --quiet SHA256SUMS ) \
            || { warn "Backup at ${BD} FAILED checksum verification — not restoring from it."; return 1; }
        info "Backup checksums verified"
    else
        warn "Backup at ${BD} has no SHA256SUMS — restoring unverified."
    fi

    local SAVED_BASELINE="$PERM_BASELINE"
    [[ -f "${BD}/manifest/permissions.baseline" ]] && PERM_BASELINE="${BD}/manifest/permissions.baseline"
    # Said once, here, rather than by the converter: baseline_stream is called
    # for every recorded path and cannot print anything at all (its stdout IS
    # the record stream). Every restore point taken before v1.0.4 is in the old
    # format, so this is the normal shape of a rollback, not an error.
    if baseline_is_legacy "$PERM_BASELINE"; then
        warn "${PERM_BASELINE} is a pre-v1.0.4 pipe-delimited baseline."
        warn "  It is converted on the fly. A record that format cannot represent"
        warn "  unambiguously — a path containing '|' or a newline — is refused, not replayed."
    fi

    warn "Restoring from ${BD} ..."
    RETIRED_UNITS=(); RETIRED_RUNTIME=(); RESTORE_PROBLEMS=()
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl stop "${SERVICE}.socket" 2>/dev/null || true

    [[ -f "${BD}/etc/config.yaml" ]] && cp -a "${BD}/etc/config.yaml" "${CONFIG_DIR}/config.yaml"
    if [[ -d "${BD}/etc/tls" ]]; then
        mkdir -p "${CONFIG_DIR}/tls"; cp -a "${BD}/etc/tls/." "${CONFIG_DIR}/tls/"
    fi
    shopt -s nullglob
    for extra in "${BD}"/etc/extra-certs/*; do cp -a "$extra" "${CONFIG_DIR}/"; done
    shopt -u nullglob
    if [[ -f "${BD}/data/tm.consistent.db" ]]; then
        cp -a "${BD}/data/tm.consistent.db" "${APP_HOME}/data/tm.db"
    elif [[ -f "${BD}/data/tm.db" ]]; then
        cp -a "${BD}/data/tm.db" "${APP_HOME}/data/tm.db"
    fi
    [[ -d "${BD}/app/tm" ]] && { rm -rf "${APP_HOME}/tm"; cp -a "${BD}/app/tm" "${APP_HOME}/tm"; }
    [[ -f "${BD}/app/wsgi.py" ]] && cp -a "${BD}/app/wsgi.py" "${APP_HOME}/wsgi.py"
    [[ -d "${BD}/frontend" ]] && { rm -rf "${FRONTEND_DIR:?}"/*; cp -a "${BD}/frontend/." "${FRONTEND_DIR}/"; }
    [[ -f "${BD}/system/topic-manager.nginx" ]] && \
        cp -a "${BD}/system/topic-manager.nginx" /etc/nginx/sites-available/topic-manager
    if [[ -f "${BD}/system/tm-security-headers.conf" ]]; then
        mkdir -p /etc/nginx/snippets
        cp -a "${BD}/system/tm-security-headers.conf" /etc/nginx/snippets/
    else
        # The restored install predates the snippet; drop a newer one so the
        # restored nginx config cannot reference a file it never used.
        rm -f /etc/nginx/snippets/tm-security-headers.conf
    fi
    ln -sf /etc/nginx/sites-available/topic-manager /etc/nginx/sites-enabled/topic-manager
    # Present only in restore points taken by v1.1.0+, which edits it.
    [[ -f "${BD}/system/nginx.conf" ]] && cp -a "${BD}/system/nginx.conf" /etc/nginx/nginx.conf
    [[ -f "${BD}/system/topic-manager.service" ]] && \
        cp -a "${BD}/system/topic-manager.service" /etc/systemd/system/
    restore_socket_unit "$BD"
    restore_owned_artefacts "$BD"
    restore_dropin "$BD"
    restore_cluster_store "$BD"
    [[ -f "${BD}/system/logrotate-topic-manager" ]] && \
        cp -a "${BD}/system/logrotate-topic-manager" /etc/logrotate.d/topic-manager
    restore_v120_managed "$BD"
    [[ -f "${BD}/venv.tar.gz" ]] && { rm -rf "$VENV"; tar -xzf "${BD}/venv.tar.gz" -C "$APP_HOME"; }

    local p
    for p in "${BASELINE_PATHS[@]}"; do apply_baseline "$p"; done
    if [[ -f "$PERM_BASELINE" ]]; then
        local fp fo fg fm
        while IFS= read -r -d '' fp && IFS= read -r -d '' fo \
           && IFS= read -r -d '' fg && IFS= read -r -d '' fm; do
            baseline_assert_record "$fp" "$fo" "$fg" "$fm"
            [[ -e "$fp" ]] || continue
            chown -h "${fo}:${fg}" -- "$fp" || fail "chown failed on ${fp} during restore"
            chmod "$fm" -- "$fp" || fail "chmod failed on ${fp} during restore"
        done < <(baseline_stream "$PERM_BASELINE")
        info "Restored recorded ownership and modes"
    fi
    PERM_BASELINE="$SAVED_BASELINE"
    # The database came back by cp -a and its recorded mode was just replayed,
    # and a backup from a v1.0.x host records 0644 for both. Narrow it again:
    # a rollback must not re-expose the audit trail and the live session ids.
    enforce_audit_db_modes
    info "Audit database re-moded: ${APP_HOME}/data 0700, tm.db 0600"

    # --- The permission boundary, ASKED OF THE KERNEL as the real principal.
    # Same five questions Phase 11 asks, because --restore replays recorded
    # ownership with none of Phase 11's checks: a backup taken while the
    # boundary was wrong puts the host straight back into the state the
    # boundary exists to prevent, and the restore would report success.
    # The cluster-store half is conditional — a pre-v1.0.4 restore point has
    # no clusters.d at all, and that is not a fault to abort a rollback on.
    if [[ -e "$CLUSTERS_FILE" ]]; then
        can_access "$APP_USER" -r "$CLUSTERS_FILE" \
            || fail "${APP_USER} cannot READ ${CLUSTERS_FILE} after the restore — every cluster view would fail."
    fi
    if [[ -d "$CLUSTERS_DIR" ]]; then
        can_access "$APP_USER" -w "$CLUSTERS_DIR" \
            || fail "${APP_USER} cannot WRITE ${CLUSTERS_DIR} after the restore — the Cluster Builder could not save."
    fi
    can_access "$APP_USER" -r "$CONFIG_FILE" \
        || fail "${APP_USER} cannot read config.yaml after the restore — the service would not start."
    if can_access "$APP_USER" -w "$CONFIG_FILE"; then
        fail "${APP_USER} can WRITE ${CONFIG_FILE} after the restore. The application must
     never be able to modify the file holding secret_key and ldap_bind_password.
     Fix: sudo chown root:${APP_USER} ${CONFIG_FILE}; sudo chmod 640 ${CONFIG_FILE}"
    fi
    if can_access "$APP_USER" -w "$CONFIG_DIR"; then
        fail "${APP_USER} can WRITE ${CONFIG_DIR} after the restore. Directory write is
     UNLINK: the application could delete config.yaml and write its own,
     choosing its own required_group, then restart the service.
     Fix: sudo chown root:${APP_USER} ${CONFIG_DIR}; sudo chmod 750 ${CONFIG_DIR}"
    fi
    success "Permission boundary verified after restore"

    systemctl daemon-reload
    systemctl start "$SERVICE" 2>/dev/null || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true

    sleep 5
    restore_verdict "$BD"
}

# restore_verdict <backup-dir> — the restore's exit code. 0 only when the
# service answers healthy AS THE RESTORED VERSION (manifest/state.env) and the
# restore met no problem. Health alone was the verdict until round 6
# (gatekeeper round 5, c): ANY process answering "ok" — the newer release's
# included — passed as "back on v<restored>". Every problem —
# the wrong or an unknown version, a unit systemctl could not retire, a
# recorded artefact with no saved copy — is listed under RESTORE INCOMPLETE
# and the verdict is 1, so `--restore` exits non-zero (gatekeeper round 5, d).
restore_verdict() {   # restore_verdict <backup-dir>
    local BD="$1" h v hv p
    h="$(curl -sk --max-time 10 https://localhost/api/health 2>/dev/null || true)"
    v="$(grep -oP '^topic_manager_version=\K.*' "${BD}/manifest/state.env" 2>/dev/null || true)"
    hv="$(grep -oP '"version":\s*"\K[^"]+' <<<"$h" || true)"
    if ! grep -q '"ok"' <<<"$h"; then
        RESTORE_PROBLEMS+=("health is not OK: ${h:-no response}")
    elif [[ -z "$v" || "$v" == unknown ]]; then
        RESTORE_PROBLEMS+=("the restore point does not record its version (manifest/state.env), so the service answering ${hv:-no version} cannot be confirmed as the restored release")
    elif [[ "$hv" != "$v" ]]; then
        RESTORE_PROBLEMS+=("the service answers version ${hv:-none}, not the restored ${v}: what is running is not what was restored")
    fi
    if [[ ${#RESTORE_PROBLEMS[@]} -eq 0 ]]; then
        success "Restore complete — back on v${v}, healthy: ${h}"
        return 0
    fi
    warn "RESTORE INCOMPLETE — ${#RESTORE_PROBLEMS[@]} problem(s):"
    for p in "${RESTORE_PROBLEMS[@]}"; do warn "  - ${p}"; done
    warn "Fix each one, or restore the vCSA snapshot. Backup retained at ${BD}"
    return 1
}

RESTORE_POINT_READY=false
DESTRUCTIVE_STARTED=false
rollback() {
    # Silent when nothing destructive ran. The trap is now on EXIT, so this is
    # reached by every non-zero exit — including --audit-only returning 2 for
    # blockers, which is a reported verdict, not a failed upgrade. Announcing
    # "UPGRADE FAILED — ROLLING BACK" there would be false.
    if [[ $DESTRUCTIVE_STARTED != true ]]; then
        return 0
    fi
    echo
    echo "${RED}${BOLD}══ UPGRADE FAILED — ROLLING BACK ══${NC}"
    if [[ $RESTORE_POINT_READY != true ]]; then
        warn "No verified backup exists. Manual recovery required."
        warn "Restore the vCSA snapshot taken before this run."
        return 1
    fi
    restore_from_backup "$BACKUP_DIR" || true
    return 1
}

# ─── standalone backup management modes ──────────────────────────────────────
if [[ $LIST_BACKUPS == true ]]; then
    phase "Restorable backups in ${BACKUP_ROOT}"
    shopt -s nullglob; found=false
    for d in "${BACKUP_ROOT}"/*/; do
        ts="$(basename "$d")"; found=true
        ver="$(grep -oP 'topic_manager_version=\K.*' "${d}manifest/state.env" 2>/dev/null || echo '?')"
        sz="$(du -sh "$d" 2>/dev/null | cut -f1)"
        ck="unverified"
        [[ -f "${d}SHA256SUMS" ]] && { ( cd "$d" && sha256sum -c --quiet SHA256SUMS ) >/dev/null 2>&1 && ck="verified OK" || ck="CHECKSUM MISMATCH"; }
        pb="no perms"; [[ -f "${d}manifest/permissions.baseline" ]] && pb="perms recorded"
        printf '  %-18s  v%-8s  %-6s  %-16s  %s\n' "$ts" "$ver" "$sz" "$ck" "$pb"
    done
    shopt -u nullglob
    [[ $found == true ]] || echo "  (none)"
    echo; echo "  Restore with:  sudo bash ${SELF} --restore <timestamp>"
    exit 0
fi

if [[ -n "$RESTORE_TS" ]]; then
    phase "Restore requested — ${RESTORE_TS}"
    RB="${BACKUP_ROOT}/${RESTORE_TS}"
    [[ -d "$RB" ]] || fail "No backup at ${RB}. Run --list-backups."
    warn "This REPLACES the current install with the backed-up one."
    restore_from_backup "$RB" || fail "Restore did not complete cleanly — see above."
    exit 0
fi

# EXIT, not ERR. bash does NOT fire an ERR trap on `exit`, and fail() ends in
# `exit 1` — so an ERR trap left the rollback dead on all 16 fail() call sites
# that sit AFTER the destructive phase, which is precisely where it was needed.
# Verified 2026-08-30: with an ERR trap, fail() after Phase 7 printed its message
# and exited 1 with rollback never invoked. An EXIT trap fires on both routes.
# rollback() itself is a no-op unless DESTRUCTIVE_STARTED, so the early exits
# (--audit-only / --dry-run / --backup-only / --list-backups / --restore) and
# the success path are unaffected.
_on_exit() {
    local rc=$?
    trap - EXIT
    [[ $rc -ne 0 ]] && rollback || true
    result_line "$rc"
    exit $rc
}
trap _on_exit EXIT

# =============================================================================
phase "Phase 1 — Preflight"
# =============================================================================

INSTALLED_VER="$(cat "${APP_HOME}/tm/VERSION" 2>/dev/null || echo 'unknown')"
info "Installed version:  ${INSTALLED_VER}"
[[ -f "${CONFIG_DIR}/config.yaml" ]] || fail "Config not found at ${CONFIG_DIR}/config.yaml"
id "$APP_USER" &>/dev/null || fail "Service account ${APP_USER} does not exist — this is not a Topic Manager host."

PRE_HEALTH="$(curl -sk --max-time 10 https://localhost/api/health 2>/dev/null || true)"
if grep -q '"ok"' <<<"$PRE_HEALTH"; then
    success "Pre-upgrade health: ${PRE_HEALTH}"
else
    warn "Pre-upgrade health did not return ok: ${PRE_HEALTH:-no response}"
fi

for mount in /tmp /opt /var; do
    FREE_KB=$(df --output=avail "$mount" 2>/dev/null | tail -1 | tr -d ' ')
    [[ "${FREE_KB:-0}" -gt 1048576 ]] || fail "Less than 1 GB free on ${mount} (${FREE_KB} KB)."
done
success "Disk space OK (>1 GB on /tmp, /opt, /var)"

ONLINE=false
if [[ $OFFLINE_FORCED == false ]] && curl -s --max-time 6 https://pypi.org >/dev/null 2>&1; then ONLINE=true; fi
info "Network mode: $([[ $ONLINE == true ]] && echo ONLINE || echo OFFLINE)"

# An online run needs to be told where the release source lives. Refused here,
# before any backup is taken or anything changes, when the run would reach
# Phase 5; the audit, dry-run and backup-only modes never fetch, so they go on.
if [[ $ONLINE == true ]]; then
    if [[ -n "$REPO_URL" ]]; then
        [[ "$REPO_URL" =~ ^(https://|ssh://|git@)[^[:space:]]+$ && "$REPO_URL" != -* ]] \
            || fail "--repo-url '${REPO_URL}' is not an https://, ssh:// or git@ URL."
        [[ "$REPO_BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$REPO_BRANCH" != -* ]] \
            || fail "--repo-branch '${REPO_BRANCH}' is not a branch or tag name."
        # A movable ref is not an identity. Root runs what this fetches.
        [[ "$REPO_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
            || fail "--repo-url needs --repo-commit <40-hex commit id> (or TM_REPO_COMMIT).
     A branch or tag can be moved on the server after you reviewed it, and this
     script runs what it clones as root. Take the full commit id of the release
     from its release notes or CI pipeline, out of band. Nothing has been changed."
        info "Online source: ${REPO_URL} (${REPO_BRANCH} @ ${REPO_COMMIT})"
    elif [[ $AUDIT_ONLY != true && $DRY_RUN != true && $BACKUP_ONLY != true ]]; then
        fail "Online upgrade, but no source repository was given.
     This script has no built-in source. Either:
       * pass the git URL your site publishes the release from:
           sudo bash upgrade-full.sh --repo-url <https-or-ssh-git-url> [--repo-branch <ref>]
         (or set TM_REPO_URL / TM_REPO_BRANCH), or
       * use the offline bundle, which needs no network:
           sudo bash upgrade-full.sh --offline      (see install/README.md)
     Nothing has been changed."
    fi
fi

for tool in curl tar sha256sum rsync systemctl nginx python3 stat find openssl; do
    command -v "$tool" >/dev/null || fail "Required tool missing: ${tool}"
done
success "Required tooling present"

# =============================================================================
phase "Phase 2 — Permission and platform audit"
# =============================================================================
# Runs BEFORE any change. On a STIG-hardened host the install-time assumptions
# no longer hold: umask is 077, /tmp may be noexec, sudo is narrowed, and file
# integrity tooling watches every path this script writes. Find that out now,
# not halfway through a destructive phase.

AUDIT_REPORT="$(mktemp)"; chmod 600 "$AUDIT_REPORT"

echo "  ── identity and privilege"
row PASS "running as root" "uid=0"
APP_UID="$(id -u "$APP_USER" 2>/dev/null || echo '?')"
APP_SHELL="$(getent passwd "$APP_USER" | cut -d: -f7)"
row PASS "service account ${APP_USER}" "uid=${APP_UID} shell=${APP_SHELL}"
if id "$WEB_USER" &>/dev/null; then
    row PASS "web account ${WEB_USER}" "uid=$(id -u "$WEB_USER")"
else
    row BLOCK "web account ${WEB_USER}" "missing — nginx cannot serve the frontend"
fi

echo
echo "  ── file creation semantics"
ORIG_UMASK="$(umask)"
if [[ "$ORIG_UMASK" == "0077" || "$ORIG_UMASK" == "077" ]]; then
    row WARN "umask" "${ORIG_UMASK} (STIG) — forcing 0022 for this run so served assets stay readable"
else
    row PASS "umask" "${ORIG_UMASK}"
fi
# Deterministic regardless of the host default. Restored at the end.
umask 0022

echo
echo "  ── mount options"
for m in /tmp /var/tmp /opt /var/www /var/backups; do
    [[ -d "$m" ]] || continue
    OPTS="$(findmnt -no OPTIONS --target "$m" 2>/dev/null || echo '?')"
    SRC="$(findmnt -no TARGET --target "$m" 2>/dev/null || echo '/')"
    if grep -q 'noexec' <<<"$OPTS"; then
        row WARN "mount ${m} (on ${SRC})" "noexec"
    else
        row PASS "mount ${m} (on ${SRC})" "$(cut -c1-46 <<<"$OPTS")"
    fi
done

# pip and venv need to execute from the build temp dir. Test it, don't assume.
TMP_EXEC_DIR=""
probe_exec() {
    local d="$1" f
    f="$(mktemp "${d}/.tmxq.XXXXXX" 2>/dev/null)" || return 1
    printf '#!/bin/sh\nexit 7\n' > "$f"; chmod 0700 "$f"
    "$f" >/dev/null 2>&1; local rc=$?; rm -f "$f"
    [[ $rc -eq 7 ]]
}
if probe_exec /tmp; then
    row PASS "/tmp is executable" "pip and venv builds will work"
else
    # Not fatal: give pip an exec-capable private build dir instead.
    TMP_EXEC_DIR="${APP_HOME}/.upgrade-tmp"
    mkdir -p "$TMP_EXEC_DIR"; chmod 700 "$TMP_EXEC_DIR"
    if probe_exec "$TMP_EXEC_DIR"; then
        export TMPDIR="$TMP_EXEC_DIR"
        row WARN "/tmp is noexec" "using TMPDIR=${TMP_EXEC_DIR} for pip and venv"
    else
        row BLOCK "no executable temp directory" "pip cannot build; mount an exec-capable path or set TMPDIR"
    fi
fi

echo
echo "  ── immutable and extended attributes"
IMMUT=0
for p in "${BASELINE_PATHS[@]}"; do
    [[ -e "$p" ]] || continue
    # Captured, then tested (REG-0004): `| grep -q` under pipefail could
    # SIGPIPE the producer and MISS an immutable file — a blocker read as a pass.
    _attrs="$(lsattr -d "$p" 2>/dev/null || true)"
    if [[ "${_attrs%% *}" == *i* ]]; then
        row BLOCK "immutable attribute set" "$p — chattr -i required before upgrade"
        IMMUT=$((IMMUT+1))
    fi
done
[[ $IMMUT -eq 0 ]] && row PASS "no immutable attributes" "on any path this upgrade writes"

ACL_FOUND=0
for p in "$FRONTEND_DIR" "$CONFIG_DIR" "$APP_HOME"; do
    [[ -d "$p" ]] || continue
    _acl="$(getfacl -p "$p" 2>/dev/null || true)"
    if grep -qE '^(user|group|mask):[^:]+:' <<<"$_acl"; then
        row WARN "POSIX ACL present" "$p — ACLs are preserved by cp -a but not by mode restore"
        ACL_FOUND=$((ACL_FOUND+1))
    fi
done
[[ $ACL_FOUND -eq 0 ]] && row PASS "no extended POSIX ACLs" "mode + owner restore is sufficient"

echo
echo "  ── mandatory access control"
if command -v aa-status >/dev/null 2>&1 && aa-status --enabled 2>/dev/null; then
    NGX_PROF="$(aa-status 2>/dev/null | grep -ci nginx || true)"
    if [[ "${NGX_PROF:-0}" -gt 0 ]]; then
        row WARN "AppArmor nginx profile loaded" "confirm it permits ${FRONTEND_DIR} and ${CONFIG_DIR}/tls"
    else
        row PASS "AppArmor enabled, no nginx profile" "no new path restrictions expected"
    fi
else
    row PASS "AppArmor" "not enforcing on this host"
fi
if command -v getenforce >/dev/null 2>&1; then
    row WARN "SELinux present" "$(getenforce 2>/dev/null) — relabel served paths after upgrade"
fi

echo
echo "  ── integrity and audit tooling (needs re-baselining after upgrade)"
for svc in auditd aide fapolicyd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        case "$svc" in
            aide)      row WARN "AIDE active" "re-run 'aide --init' after the upgrade or every changed file alarms" ;;
            auditd)    row WARN "auditd active" "file-watch rules on ${APP_HOME} / ${CONFIG_DIR} will fire during the upgrade" ;;
            fapolicyd) row BLOCK "fapolicyd active" "execution allowlisting will block new venv binaries — add a rule or stop it for the run" ;;
        esac
    else
        row PASS "${svc}" "not active"
    fi
done

echo
echo "  ── effective access (asked of the kernel, as the real principal)"
# Mode bits can look correct while a parent directory, an ACL or a MAC policy
# still denies. This is the check that actually predicts an nginx 403.
if [[ -f "${FRONTEND_DIR}/index.html" ]]; then
    can_access "$WEB_USER" -r "${FRONTEND_DIR}/index.html" \
        && row PASS "${WEB_USER} can read index.html" "" \
        || row BLOCK "${WEB_USER} cannot read index.html" "nginx would return 403 — fix before upgrading"
fi
if [[ -f "${FRONTEND_DIR}/lib/vue.global.prod.js" ]]; then
    can_access "$WEB_USER" -r "${FRONTEND_DIR}/lib/vue.global.prod.js" \
        && row PASS "${WEB_USER} can read the Vue bundle" "" \
        || row BLOCK "${WEB_USER} cannot read the Vue bundle" "the UI would not load"
fi
can_access "$APP_USER" -r "${CONFIG_DIR}/config.yaml" \
    && row PASS "${APP_USER} can read config.yaml" "" \
    || row BLOCK "${APP_USER} cannot read config.yaml" "the service would not start"
if [[ -x "${VENV}/bin/python3" ]]; then
    can_access "$APP_USER" -x "${VENV}/bin/python3" \
        && row PASS "${APP_USER} can execute the venv" "" \
        || row BLOCK "${APP_USER} cannot execute the venv" "umask 077 at install time is the usual cause"
fi
for d in "${APP_HOME}/data" "${APP_HOME}/logs"; do
    [[ -d "$d" ]] || continue
    can_access "$APP_USER" -w "$d" \
        && row PASS "${APP_USER} can write $(basename "$d")/" "" \
        || row BLOCK "${APP_USER} cannot write ${d}" "audit log and gunicorn logs would fail"
done
# v1.1.0 narrows the audit database. Said at audit time so an operator is not
# surprised by it; a WARN, because the upgrade itself is the fix.
if [[ -f "${APP_HOME}/data/tm.db" ]]; then
    DB_MODE_NOW="$(stat -c '%a' "${APP_HOME}/data/tm.db" 2>/dev/null || echo '?')"
    if [[ "$DB_MODE_NOW" == "600" ]]; then
        row PASS "tm.db mode" "0600"
    else
        row WARN "tm.db mode" "0${DB_MODE_NOW} — this upgrade sets tm.db 0600 and data/ 0700"
    fi
fi

echo
echo "  ── recorded permission baseline"
info "Current ownership and modes on the paths this upgrade touches:"
for p in "${BASELINE_PATHS[@]}"; do
    [[ -e "$p" ]] && printf '      %-10s %-28s %s\n' \
        "$(stat -c '%a' "$p")" "$(stat -c '%U:%G' "$p")" "$p"
done
info "These exact values are captured in Phase 4 and re-applied in Phase 10."

# v1.2.0 host settings. Reported, not blocked: the upgrade installs no OS
# packages offline, and each feature fails its own apply with the package
# named. The warning says how to install it from the SAME source tree — the
# offline bundle's packages, through install.sh's own policy (--packages-only
# changes nothing else).
for _pkg in rsyslog rsyslog-openssl; do
    if [[ "$(dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null || true)" == *"install ok installed"* ]]; then
        row PASS "package ${_pkg}" "installed"
    else
        row WARN "package ${_pkg}" "absent — Settings > Remote syslog$([[ $_pkg == rsyslog-openssl ]] && echo ' over TLS') will fail to apply until it is installed. Install it: sudo bash ${OFFLINE_SRC_DIR}/install.sh --packages-only (offline bundle) or sudo apt-get install ${_pkg}"
    fi
done
if systemctl is-active --quiet chrony 2>/dev/null; then
    row PASS "time daemon" "chrony"
elif systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    row PASS "time daemon" "systemd-timesyncd"
else
    row WARN "time daemon" "neither chrony nor systemd-timesyncd is active — Settings > Time source cannot apply"
fi

# =============================================================================
phase "Phase 3 — Upgrade blockers (v${INSTALLED_VER} → target)"
# =============================================================================
# Checks for things that are harmless on the installed version but fail closed
# on the new one. These are the failures that would otherwise surface as
# "nobody can log in" an hour after a apparently successful upgrade.

# --- 0. Resolve configuration the way the SERVICE will see it, not the way
# config.yaml alone reads. tm/config.py:18-21 lets TM_SECRET_KEY and
# TM_LDAP_BIND_PASSWORD override the file at runtime, and on a host configured
# that way both checks below answered the wrong question: secret_key BLOCKED on
# a key that is really set, and — the one that matters — the LDAP probe decided
# "no service bind configured" and SKIPped, reporting PASS for the single check
# this phase exists to perform. The overrides live in the unit's Environment= /
# EnvironmentFile= (drop-ins included), not in the operator's shell, so read
# there too.
CFG_PY_BIN="python3"
[[ -x "${VENV}/bin/python3" ]] && CFG_PY_BIN="${VENV}/bin/python3"

RESOLVE_PY="$(mktemp)"; chmod 600 "$RESOLVE_PY"
cat > "$RESOLVE_PY" <<'PYRESOLVE'
"""Resolve one setting exactly as tm/config.py will at runtime.

Precedence, highest first:
  1. the systemd unit's environment: Environment=, then EnvironmentFile=, which
     systemd applies afterwards and lets override Environment=. `systemctl show`
     reports the merged unit, so drop-ins are included.
  2. this process's own environment
  3. config.yaml
Prints exactly one line, <source>|<value>, source being one of
unit-env | shell-env | config | none | error. The value itself is never logged
by the caller; only its length and its source are.
"""
import os
import shlex
import subprocess
import sys


def _show(service, prop):
    out = subprocess.run(
        ['systemctl', 'show', service, '--property=' + prop, '--no-pager'],
        capture_output=True, text=True, timeout=20).stdout
    return [ln[len(prop) + 1:] for ln in out.splitlines()
            if ln.startswith(prop + '=')]


def unit_env(service):
    env = {}
    for line in _show(service, 'Environment'):
        for tok in shlex.split(line):
            if '=' in tok:
                k, _, v = tok.partition('=')
                env[k] = v
    for line in _show(service, 'EnvironmentFiles'):
        path = line.rsplit(' (', 1)[0].strip()   # "/etc/x (ignore_errors=no)"
        if not path or not os.path.isfile(path):
            continue
        with open(path, 'r') as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw or raw.startswith('#') or '=' not in raw:
                    continue
                k, _, v = raw.partition('=')
                v = v.strip()
                if len(v) > 1 and v[0] == v[-1] and v[0] in ('"', "'"):
                    v = v[1:-1]
                env[k.strip()] = v
    return env


def from_yaml(path, dotted):
    import yaml
    cur = yaml.safe_load(open(path)) or {}
    for part in dotted.split('.'):
        if not isinstance(cur, dict):
            return ''
        cur = cur.get(part, '')
    return '' if cur is None else str(cur)


def resolve(cfg_path, service, dotted, envvar):
    val = unit_env(service).get(envvar, '')
    if val:
        return 'unit-env', val
    val = os.environ.get(envvar, '')
    if val:
        return 'shell-env', val
    val = from_yaml(cfg_path, dotted)
    return ('config', val) if val else ('none', '')


try:
    src, value = resolve(*sys.argv[1:5])
except Exception as exc:          # never let a broken resolver read as "unset"
    print('error|%s: %s' % (type(exc).__name__, exc))
else:
    print('%s|%s' % (src, value))
PYRESOLVE

# resolve_cfg <dotted.key> <ENV_VAR>  ->  "<source>|<value>" on stdout.
# A resolver that cannot run returns error|..., never an empty value — an empty
# value here would be read as "not configured", which is the fail-open this
# whole section exists to remove.
resolve_cfg() {
    local out
    out="$("$CFG_PY_BIN" "$RESOLVE_PY" "$CONFIG_FILE" "${SERVICE}.service" "$1" "$2" 2>/dev/null || true)"
    out="${out%%$'\n'*}"
    case "$out" in
        unit-env\|*|shell-env\|*|config\|*|none\|*|error\|*) printf '%s' "$out" ;;
        *) printf 'error|%s produced no usable output resolving %s' "$CFG_PY_BIN" "$1" ;;
    esac
}

# --- 1. secret_key. v1.0.0 silently generated a random key per worker when
# this was blank; the new version raises RuntimeError and refuses to start.
SECRET_RES="$(resolve_cfg server.secret_key TM_SECRET_KEY)"
SECRET_SRC="${SECRET_RES%%|*}"; SECRET="${SECRET_RES#*|}"
case "$SECRET_SRC" in
    error)
        row BLOCK "server.secret_key" "could not be resolved: ${SECRET}"
        warn "  The effective configuration could not be read, so this check cannot say the key is set."
        warn "  Fix the resolver error above and re-run — do not assume it is fine." ;;
    none)
        row BLOCK "server.secret_key" "unset in the unit environment and in config.yaml — the new version refuses to start"
        warn "  Remediation: set a real key, then re-run."
        warn "    python3 -c \"import secrets; print(secrets.token_hex(32))\""
        warn "  NOTE: changing it invalidates every existing session cookie (expected)." ;;
    *)
        if [[ "$SECRET" == *CHANGE_ME* ]]; then
            row BLOCK "server.secret_key" "placeholder value (from ${SECRET_SRC}) — the new version refuses to start"
            warn "  Remediation: set a real key, then re-run."
            warn "    python3 -c \"import secrets; print(secrets.token_hex(32))\""
            warn "  NOTE: changing it invalidates every existing session cookie (expected)."
        else
            row PASS "server.secret_key" "set (${#SECRET} chars, from ${SECRET_SRC})"
        fi ;;
esac

# --- 2. LDAP service bind. THIS IS THE v1.0.0 TRAP.
# v1.0.0's auth.py has no service-bind logic at all — it binds directly as the
# user, so a wrong ldap_bind_dn in the config is simply ignored and every login
# works. The new version treats a configured bind_dn + non-placeholder password
# as "use the service bind", and gates EVERY login on it succeeding. A stale or
# wrong DN that has been sitting in the config harmlessly since v1.0.0 becomes
# a total authentication outage the moment the new code starts.
LDAP_PW_RES="$(resolve_cfg auth.ldap_bind_password TM_LDAP_BIND_PASSWORD)"
LDAP_PW_SRC="${LDAP_PW_RES%%|*}"; LDAP_PW="${LDAP_PW_RES#*|}"
[[ "$LDAP_PW_SRC" == "none" || "$LDAP_PW_SRC" == "error" ]] && LDAP_PW=""
# The other two thirds of the bind identity, for the attempt-budget cache key.
# grep -m1 on the FILE, not `| head -1` on a pipe (REG-0004).
LDAP_DN="$(grep -m1 -oP 'ldap_bind_dn:\s*"\K[^"]+' "$CONFIG_FILE" 2>/dev/null || true)"
LDAP_SRV_RAW="$(grep -m1 -oP 'ldap_server:\s*"?\K[^"]+' "$CONFIG_FILE" 2>/dev/null || true)"

LDAP_PY="$(mktemp)"; chmod 600 "$LDAP_PY"
cat > "$LDAP_PY" <<'PYLDAP'
import os, ssl, sys, yaml
try:
    from ldap3 import Server, Connection, ALL, SIMPLE, Tls
    from ldap3.core.exceptions import LDAPException, LDAPBindError
except Exception:
    # NOT a SKIP: the probe did not run, so nothing about the bind is known.
    print("ERROR|ldap3 not importable in this interpreter"); sys.exit(0)

cfg = yaml.safe_load(open(sys.argv[1])) or {}
a   = cfg.get('auth', {}) or {}
url = a.get('ldap_server', '') or ''
dn  = a.get('ldap_bind_dn', '') or ''
# Same precedence as tm/config.py:20-21 — the env var wins over the file. The
# caller puts the value resolved from the unit's environment here, so this
# probe sees the password the service will actually bind with.
pw  = os.environ.get('TM_LDAP_BIND_PASSWORD') or str(a.get('ldap_bind_password', '') or '')

if not (dn and pw and 'CHANGE_ME' not in pw):
    print("SKIP|no service bind configured; the new version will use direct user bind")
    sys.exit(0)
if not url.lower().startswith('ldaps'):
    print("WARN|ldap_server is not ldaps:// — the new version enforces CERT_REQUIRED only for ldaps")
    sys.exit(0)

ca = a.get('ldap_ca_cert') or None
try:
    tls = Tls(validate=ssl.CERT_REQUIRED, ca_certs_file=ca)
    srv = Server(url, get_info=ALL, tls=tls, use_ssl=True)
    c = Connection(srv, user=dn, password=pw, authentication=SIMPLE, auto_bind=True)
    who = c.extend.standard.who_am_i()
    c.unbind()
    print("OK|service bind succeeds as %s" % who)
except LDAPBindError as e:
    print("FAIL|bind rejected (bad DN, bad password, or both): %s" % e)
except LDAPException as e:
    print("FAIL|LDAP/TLS error: %s" % e)
PYLDAP

# ---- attempt budget -------------------------------------------------------
# Every invocation of this script performs ONE live bind. The documented
# procedure runs it three times (--audit-only, --backup-only, full), and an
# operator fixing a wrong DN re-runs the audit each time. Against a stale
# password that walks the service account toward AD lockout — and because
# v1.0.2+ gates EVERY user login on this same service bind, a locked service
# account is a total authentication outage for the whole application. The
# check meant to prevent an outage would have caused one.
#
# So: cache the verdict against a salted hash of (server, DN, password). The
# same failing tuple is reported from cache and NOT re-bound. Change any of
# the three and it is a genuinely new attempt, which is retried once.
LDAP_CACHE_DIR="${BACKUP_ROOT}/.bind-probe"
LDAP_CACHE=""
if [[ -n "$LDAP_DN" && -n "$LDAP_PW" ]]; then
    install -d -m 700 -o root -g root "$LDAP_CACHE_DIR" 2>/dev/null || true
    _salt_f="${LDAP_CACHE_DIR}/.salt"
    if [[ ! -s "$_salt_f" ]]; then
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$_salt_f" 2>/dev/null || true
        chmod 600 "$_salt_f" 2>/dev/null || true
    fi
    _salt="$(cat "$_salt_f" 2>/dev/null || echo fallback)"
    # The password never lands on disk — only a salted digest of the tuple.
    LDAP_TUPLE_ID="$(printf '%s' "${_salt}|${LDAP_SRV_RAW}|${LDAP_DN}|${LDAP_PW}" \
                     | sha256sum | cut -d' ' -f1)"
    LDAP_CACHE="${LDAP_CACHE_DIR}/${LDAP_TUPLE_ID}"
    unset _salt
fi

if [[ $NO_BIND_PROBE == true ]]; then
    # NOT "SKIP" — that status means "no service bind is configured", which is a
    # legitimate pass. Suppressing the probe is different: the check did not run,
    # and a check that did not execute has proven nothing.
    LDAP_RES="ERROR|--no-bind-probe given; the service bind was deliberately NOT tested"
elif [[ -n "$LDAP_CACHE" && -f "$LDAP_CACHE" ]]; then
    _cached="$(cat "$LDAP_CACHE" 2>/dev/null || true)"
    _cnt="${_cached%%|*}"
    LDAP_RES="${_cached#*|}"
    warn "Re-using the cached bind verdict for this exact (server, DN, password)."
    warn "  ${_cnt} live attempt(s) already spent on this tuple. NOT re-binding —"
    warn "  repeated failures would walk the service account toward AD lockout,"
    warn "  which under v1.0.2+ is itself a total authentication outage."
    warn "  Change the DN or password to force a fresh attempt, or delete ${LDAP_CACHE}."
else
    LDAP_RES="$(TM_LDAP_BIND_PASSWORD="$LDAP_PW" "$CFG_PY_BIN" "$LDAP_PY" "$CONFIG_FILE" 2>/dev/null \
                || echo 'ERROR|the bind probe exited non-zero')"
    # Cache only a FAILING verdict. A success is cheap to repeat and must not
    # be allowed to go stale after a password rotation.
    if [[ -n "$LDAP_CACHE" && "${LDAP_RES%%|*}" == "FAIL" ]]; then
        printf '1|%s' "$LDAP_RES" > "$LDAP_CACHE" 2>/dev/null || true
        chmod 600 "$LDAP_CACHE" 2>/dev/null || true
    fi
fi
rm -f "$LDAP_PY" "$RESOLVE_PY"
LDAP_ST="${LDAP_RES%%|*}"; LDAP_MSG="${LDAP_RES#*|}"
[[ "$LDAP_PW_SRC" == "unit-env" || "$LDAP_PW_SRC" == "shell-env" ]] \
    && LDAP_MSG="${LDAP_MSG} (bind password from ${LDAP_PW_SRC})"
case "$LDAP_ST" in
    OK)   row PASS "LDAP service bind" "$LDAP_MSG" ;;
    SKIP) row PASS "LDAP service bind" "$LDAP_MSG" ;;
    WARN) row WARN "LDAP service bind" "$LDAP_MSG" ;;
    # The probe could not run. Reporting PASS here is what let the v1.0.0 trap
    # through: a check that did not execute has proven nothing.
    ERROR) row WARN "LDAP service bind" "NOT CHECKED — ${LDAP_MSG}"
          warn "  The service-bind probe did not run, so the v1.0.0 auth trap is UNTESTED on this host."
          warn "  Verify the bind by hand before upgrading, or accept the risk with --force." ;;
    *)    row BLOCK "LDAP service bind" "$LDAP_MSG"
          warn "  This is the classic v1.0.0 upgrade trap:"
          warn "    v1.0.0 IGNORES ldap_bind_dn entirely and binds as the user, so logins work today."
          warn "    The new version gates EVERY login on this bind succeeding."
          warn "  Upgrading without fixing this locks out every user."
          warn "  Remediation — either correct the DN and password in ${CONFIG_FILE},"
          warn "  or blank ldap_bind_dn/ldap_bind_password to keep direct user bind." ;;
esac

# --- 2b. The directory must be NAMED in config.yaml (v1.1.0).
# Before 1.1.0, tm/auth.py filled ldap_server, ldap_base_dn and ldap_domain
# from built-in defaults that belonged to one particular site. They are gone,
# so a config.yaml that omitted them — and worked, silently, for months —
# would stop every sign-in the moment the new code starts. This is a BLOCK
# that --force does NOT override: there is no configuration of this host on
# which proceeding helps anyone.
LDAP_KEYS_HARD_BLOCK=false
LDAP_KEYS_MISSING="$(ldap_config_missing "$CFG_PY_BIN" "$CONFIG_FILE" 2>/dev/null || echo 'ERROR:resolver')"
case "$LDAP_KEYS_MISSING" in
    "") row PASS "directory settings in config.yaml" "ldap_server, ldap_base_dn, ldap_domain all set" ;;
    ERROR:*)
        row BLOCK "directory settings in config.yaml" "could not be checked (${LDAP_KEYS_MISSING#ERROR:})"
        LDAP_KEYS_HARD_BLOCK=true
        warn "  ${CFG_PY_BIN} could not read ${CONFIG_FILE} with PyYAML, so this check cannot say"
        warn "  the directory is configured. Fix that and re-run." ;;
    *)
        row BLOCK "directory settings in config.yaml" "missing: ${LDAP_KEYS_MISSING}"
        LDAP_KEYS_HARD_BLOCK=true
        warn "  v1.1.0 has NO built-in directory defaults. This config.yaml relied on them for:"
        warn "      ${LDAP_KEYS_MISSING}"
        warn "  Upgrading as it stands would lock EVERY user out. Add them under auth: in"
        warn "  ${CONFIG_FILE} with your directory's values, e.g."
        warn "      ldap_server:  \"ldaps://dc1.example.org:636\""
        warn "      ldap_base_dn: \"DC=example,DC=org\""
        warn "      ldap_domain:  \"example.org\""
        warn "  then re-run. --force does not override this one." ;;
esac

# --- 3. LDAPS trust. The new version enforces CERT_REQUIRED; an untrusted DC
# certificate turns into a login outage rather than a warning.
LDAP_SRV="$(grep -m1 -oP 'ldap_server:\s*"?\Kldaps://[^"]+' "$CONFIG_FILE" 2>/dev/null || true)"
if [[ -n "$LDAP_SRV" ]]; then
    HP="${LDAP_SRV#ldaps://}"
    RC="$(timeout 15 openssl s_client -connect "$HP" -CAfile /etc/ssl/certs/ca-certificates.crt \
            </dev/null 2>&1 || true)"
    RC="$(grep -m1 'Verify return code' <<<"$RC" || true)"
    if grep -q 'Verify return code: 0' <<<"$RC"; then
        row PASS "LDAPS certificate trust" "${HP} verifies against the system store"
    else
        row BLOCK "LDAPS certificate trust" "${HP}: ${RC:-no result}"
        warn "  The new version enforces CERT_REQUIRED. Trust the DC's CA first:"
        warn "    sudo cp your-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates"
    fi
fi

# --- 4. Config paths that are referenced but absent.
while read -r ref; do
    [[ -z "$ref" ]] && continue
    [[ -f "$ref" ]] && row PASS "config reference exists" "$ref" \
                    || row WARN "config references a missing file" "$ref"
done < <(grep -oP '(ssl_cafile|ssl_certfile|ssl_keyfile|ldap_ca_cert):\s*"\K[^"]+' "$CONFIG_FILE" 2>/dev/null || true)

# --- 5. v1.0.0 frontend carries an inline <script> that the new enforced CSP
# blocks. Informational: the frontend is replaced wholesale, which fixes it.
if [[ -f "${FRONTEND_DIR}/index.html" ]] && grep -q '<script>' "${FRONTEND_DIR}/index.html"; then
    row PASS "v1.0.0 inline script in index.html" "replaced by app/main.js during deploy"
fi

# --- 5b. nginx.conf offers TLS 1.0/1.1 at the http level (stock Ubuntu does).
# Reported, not blocked: Phase 11 rewrites it, backs it up and tests it.
if [[ -f /etc/nginx/nginx.conf ]]; then
    NGX_PROTO="$(grep -m1 -E '^[[:space:]]*ssl_protocols[[:space:]]' /etc/nginx/nginx.conf 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]*#.*$//' || true)"
    if [[ -z "$NGX_PROTO" ]]; then
        row WARN "nginx.conf ssl_protocols" "not set at http level — this upgrade adds TLSv1.2 TLSv1.3"
    elif grep -Eq 'TLSv1([^.]|$)|TLSv1\.1' <<<"$NGX_PROTO"; then
        row WARN "nginx.conf ssl_protocols" "${NGX_PROTO} — this upgrade removes TLSv1/TLSv1.1"
    else
        row PASS "nginx.conf ssl_protocols" "$NGX_PROTO"
    fi
fi

# --- 6. A NEW DEFAULT DOES NOT REACH AN INSTALL THAT SETS THE VALUE.
#
# Phase 10 restores config.yaml verbatim, which is correct: the operator's
# configuration belongs to the operator and an upgrade must not silently rewrite
# it. The consequence is that changing a DEFAULT in the code changes nothing on
# any host that has the key set — and v1.0.6 lowered the idle session timeout
# from 30 minutes to 15.
#
# MEASURED 2026-09-02 on the production host: the upgrade completed, reported
# success, and left `timeout_minutes: 30` in place while README.md, SBOM.md and
# the in-app documentation all described a 15-minute default. The value had to
# be edited by hand afterwards.
#
# WARN, never BLOCK. A longer timeout can be a deliberate decision, and refusing
# to upgrade over an operator's own setting would be presumptuous. What the
# operator is owed is to be TOLD, at audit time, that the file disagrees with
# the version they are moving to.
TM_DEFAULT_TIMEOUT=15
CFG_TIMEOUT="$(awk '
    /^session:/        { in_s = 1; next }
    /^[^[:space:]#]/   { in_s = 0 }
    in_s && $1 == "timeout_minutes:" { print $2; exit }
' "${CONFIG_FILE}" 2>/dev/null || true)"

if [[ -z "$CFG_TIMEOUT" ]]; then
    row PASS "session idle timeout" \
        "not set in config.yaml — the new default of ${TM_DEFAULT_TIMEOUT} min will apply"
elif [[ "$CFG_TIMEOUT" =~ ^[0-9]+$ ]] && (( CFG_TIMEOUT > TM_DEFAULT_TIMEOUT )); then
    row WARN "session idle timeout is ${CFG_TIMEOUT} min, above the ${TM_DEFAULT_TIMEOUT} min default" \
        "config.yaml is restored verbatim, so THIS UPGRADE WILL NOT CHANGE IT"
    warn "  session.timeout_minutes = ${CFG_TIMEOUT} in ${CONFIG_FILE}."
    warn "  v1.0.6 onward defaults to ${TM_DEFAULT_TIMEOUT} minutes and the documentation says so,"
    warn "  but an upgrade restores your config file unchanged — by design."
    warn "  To adopt the new default, edit it yourself after the upgrade:"
    warn "      sudo sed -i 's/^\(  timeout_minutes:\).*/\1 ${TM_DEFAULT_TIMEOUT}/' ${CONFIG_FILE}"
    warn "      sudo systemctl restart topic-manager"
else
    row PASS "session idle timeout" "${CFG_TIMEOUT} min (at or below the ${TM_DEFAULT_TIMEOUT} min default)"
fi

# ─── audit verdict ───────────────────────────────────────────────────────────
# Reported here; ENFORCED after the backup. A blocker must never stand between
# an operator and a restore point — a broken system is exactly when you most
# want one. The gate sits immediately before the first destructive phase.
echo
if [[ $AUDIT_BLOCK -gt 0 ]]; then
    echo "${RED}${BOLD}  AUDIT: ${AUDIT_BLOCK} blocker(s), ${AUDIT_WARN} warning(s)${NC}"
elif [[ $AUDIT_WARN -gt 0 ]]; then
    echo "${YELLOW}${BOLD}  AUDIT: clear, with ${AUDIT_WARN} warning(s)${NC}"
else
    echo "${GREEN}${BOLD}  AUDIT: clear${NC}"
fi

if [[ $AUDIT_ONLY == true ]]; then
    phase "Audit-only run complete — nothing changed"
    umask "$ORIG_UMASK"
    # Exit status is the result, so this can gate a pipeline:
    #   0 = clear, 1 = warnings only, 2 = blockers present
    if   [[ $AUDIT_BLOCK -gt 0 ]]; then exit 2
    elif [[ $AUDIT_WARN  -gt 0 ]]; then exit 1
    else exit 0; fi
fi

if [[ $DRY_RUN == true ]]; then
    phase "Dry run — planned actions"
    echo "  backup      -> ${BACKUP_DIR} (+ ${BACKUP_TAR})"
    echo "  perms       -> recorded now, re-applied verbatim after deploy"
    echo "  os patch    -> $([[ $SKIP_OS == true ]] && echo 'SKIPPED' || echo 'apt full-upgrade')"
    echo "  python deps -> exactly the pins in the target tree's requirements.txt."
    echo "                 Not listed here: --dry-run stops before Phase 5 fetches"
    echo "                 the source, and this script no longer keeps a second copy"
    echo "                 of the versions to recite from."
    echo "  frontend    -> Vue ${VUE_VERSION} (sha256 pinned)"
    echo "  nginx.conf  -> ssl_protocols TLSv1.2 TLSv1.3 (backed up, nginx -t, put back on failure)"
    echo "  restore     -> config.yaml, tm.db, tls/{server.crt,server.key}, extra CA certs,"
    echo "                 and ${DROPIN_DIR} if this host has one"
    umask "$ORIG_UMASK"; exit 0
fi

# =============================================================================
phase "Phase 4 — Backup (everything, verified)"
# =============================================================================

# 0700 from creation: this tree holds the TLS private key and the LDAP bind
# password. Never group- or world-traversable, not even briefly.
install -d -m 700 -o root -g root "$BACKUP_ROOT"
install -d -m 700 -o root -g root "$BACKUP_DIR"
install -d -m 700 "${BACKUP_DIR}"/{etc,data,app,frontend,system,manifest}
install -d -m 700 "${BACKUP_DIR}/etc/extra-certs"
PERM_BASELINE="${BACKUP_DIR}/manifest/permissions.baseline"

info "Recording permission baseline ..."
record_baseline "$PERM_BASELINE"
success "Baseline recorded ($(baseline_count "$PERM_BASELINE") paths)"
cp -a "$AUDIT_REPORT" "${BACKUP_DIR}/manifest/permission-audit.txt" 2>/dev/null || true

info "Backing up to ${BACKUP_DIR} ..."
cp -a "${CONFIG_DIR}/config.yaml" "${BACKUP_DIR}/etc/config.yaml"
[[ -d "${CONFIG_DIR}/tls" ]] && cp -a "${CONFIG_DIR}/tls" "${BACKUP_DIR}/etc/tls"
# The cluster profiles and the uploaded Kafka TLS material. Without these
# a --restore hands back a host whose every topic view resolves through a
# cluster that no longer exists.
[[ -d "$CLUSTERS_DIR" ]] && cp -a "$CLUSTERS_DIR" "${BACKUP_DIR}/etc/clusters.d"
[[ -d "$CERT_DIR" ]]     && cp -a "$CERT_DIR" "${BACKUP_DIR}/data/cluster-certs"
# Additional CA/cert material dropped into the config dir. The shipped
# upgrade.sh copied only tls/ and silently lost these.
shopt -s nullglob
for f in "${CONFIG_DIR}"/*.crt "${CONFIG_DIR}"/*.pem "${CONFIG_DIR}"/*.key "${CONFIG_DIR}"/*.p12; do
    cp -a "$f" "${BACKUP_DIR}/etc/extra-certs/"
done
shopt -u nullglob

[[ -f "${APP_HOME}/data/tm.db" ]] && cp -a "${APP_HOME}/data/tm.db" "${BACKUP_DIR}/data/tm.db"
# Consistent SQLite snapshot via python3's stdlib — the sqlite3 CLI is NOT
# installed on stock Ubuntu Server 24.04, and relying on it made this skip.
if [[ -f "${APP_HOME}/data/tm.db" ]]; then
    if python3 - "$APP_HOME" "$BACKUP_DIR" <<'PYBACKUP'
import sqlite3, sys
src, dst = sys.argv[1] + "/data/tm.db", sys.argv[2] + "/data/tm.consistent.db"
s = sqlite3.connect("file:%s?mode=ro" % src, uri=True)
d = sqlite3.connect(dst)
with d:
    s.backup(d)
d.close(); s.close()
PYBACKUP
    then success "SQLite consistent snapshot taken"
    else
        # Round 2: a restore point without a consistent copy of the audit
        # database is not a restore point. The raw copy of a live WAL database
        # can be torn, and the audit trail is what a rollback must not lose.
        fail "SQLite consistent snapshot failed — the restore point is NOT ready and
     nothing has been changed. Check the database and the free space under
     ${BACKUP_ROOT}, then re-run."
    fi
fi

[[ -d "${APP_HOME}/tm" ]]      && cp -a "${APP_HOME}/tm"   "${BACKUP_DIR}/app/tm"
[[ -f "${APP_HOME}/wsgi.py" ]] && cp -a "${APP_HOME}/wsgi.py" "${BACKUP_DIR}/app/wsgi.py"
[[ -d "$FRONTEND_DIR" ]]       && cp -a "${FRONTEND_DIR}/." "${BACKUP_DIR}/frontend/"
if [[ -d "$VENV" ]]; then
    info "Archiving current venv for offline rollback ..."
    tar -czf "${BACKUP_DIR}/venv.tar.gz" -C "$APP_HOME" venv
fi

[[ -f /etc/nginx/sites-available/topic-manager ]] && \
    cp -a /etc/nginx/sites-available/topic-manager "${BACKUP_DIR}/system/topic-manager.nginx"
[[ -f /etc/nginx/snippets/tm-security-headers.conf ]] && \
    cp -a /etc/nginx/snippets/tm-security-headers.conf "${BACKUP_DIR}/system/"
# v1.1.0 edits nginx.conf (ssl_protocols), so the restore point must hold it.
[[ -f /etc/nginx/nginx.conf ]] && cp -a /etc/nginx/nginx.conf "${BACKUP_DIR}/system/nginx.conf"
[[ -f /etc/systemd/system/topic-manager.service ]] && \
    cp -a /etc/systemd/system/topic-manager.service "${BACKUP_DIR}/system/"
# v1.2.0+: the gunicorn socket unit. Its ABSENCE in a restore point is what
# tells a rollback the restored release listened on TCP (restore_socket_unit).
[[ -f /etc/systemd/system/topic-manager.socket ]] && \
    cp -a /etc/systemd/system/topic-manager.socket "${BACKUP_DIR}/system/"
backup_dropin "$BACKUP_DIR"
[[ -f /etc/logrotate.d/topic-manager ]] && \
    cp -a /etc/logrotate.d/topic-manager "${BACKUP_DIR}/system/logrotate-topic-manager"
backup_v120_managed "$BACKUP_DIR"
backup_owned_artefacts "$BACKUP_DIR" "$INSTALLED_VER"

{
    echo "topic_manager_version=${INSTALLED_VER}"
    echo "backup_timestamp=${TIMESTAMP}"
    echo "hostname=$(hostname -f 2>/dev/null || hostname)"
    echo "os=$(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "kernel=$(uname -r)"
    echo "nginx=$(nginx -v 2>&1 | sed 's|.*/||')"
    echo "openssl=$(openssl version)"
    echo "python=$(python3 --version 2>&1)"
    echo "host_umask=${ORIG_UMASK}"
    echo "audit_blockers=${AUDIT_BLOCK}"
    echo "audit_warnings=${AUDIT_WARN}"
} > "${BACKUP_DIR}/manifest/state.env"
[[ -x "${VENV}/bin/pip" ]] && "${VENV}/bin/pip" freeze > "${BACKUP_DIR}/manifest/pip-freeze.txt" 2>/dev/null || true
dpkg -l > "${BACKUP_DIR}/manifest/dpkg-list.txt" 2>/dev/null || true
[[ -f "${FRONTEND_DIR}/lib/vue.global.prod.js" ]] && \
    sha256sum "${FRONTEND_DIR}/lib/vue.global.prod.js" > "${BACKUP_DIR}/manifest/vue.sha256" || true

( cd "$BACKUP_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z \
    | xargs -0 sha256sum > SHA256SUMS )
( cd "$BACKUP_DIR" && sha256sum -c --quiet SHA256SUMS ) \
    || fail "Backup checksum verification failed — refusing to proceed."
tar -czf "$BACKUP_TAR" -C "$BACKUP_ROOT" "$TIMESTAMP"
chmod 600 "$BACKUP_TAR"
tar -tzf "$BACKUP_TAR" >/dev/null || fail "Backup archive is unreadable — refusing to proceed."

[[ -s "${BACKUP_DIR}/etc/config.yaml" ]] || fail "config.yaml missing from backup."
# Assert the copy happened, rather than trusting that it did. A cluster
# store that exists on the host and not in the backup is a restore that
# silently loses every profile.
if [[ -s "$CLUSTERS_FILE" ]]; then
    [[ -s "${BACKUP_DIR}/etc/clusters.d/clusters.yaml" ]] \
        || fail "clusters.yaml exists on the host but is missing from the backup."
    success "Cluster profiles backed up ($(wc -c < "$CLUSTERS_FILE") bytes)"
fi
verify_dropin_backed_up "$BACKUP_DIR"
if [[ -d "${CONFIG_DIR}/tls" ]]; then
    [[ -s "${BACKUP_DIR}/etc/tls/server.key" ]] || fail "TLS private key missing from backup."
    openssl x509 -in "${BACKUP_DIR}/etc/tls/server.crt" -noout >/dev/null \
        || fail "Backed-up certificate does not parse."
    success "Backed-up cert/key verified parseable"
fi

RESTORE_POINT_READY=true
success "Verified backup: ${BACKUP_DIR}"
success "Archive:         ${BACKUP_TAR}"

if [[ $BACKUP_ONLY == true ]]; then
    phase "Backup-only run complete — no changes made"
    [[ $AUDIT_BLOCK -gt 0 ]] && warn "Note: ${AUDIT_BLOCK} audit blocker(s) still stand — resolve before upgrading."
    umask "$ORIG_UMASK"; exit 0
fi

# ─── the gate ────────────────────────────────────────────────────────────────
# A verified restore point now exists. This is the last point before anything
# destructive happens, so the blockers are enforced here.
# First the one blocker --force cannot override (v1.1.0: directory keys).
if [[ $LDAP_KEYS_HARD_BLOCK == true ]]; then
    fail "Refusing to upgrade: config.yaml does not name its directory (${LDAP_KEYS_MISSING}).
The new version has no built-in LDAP defaults and would lock every user out.
--force does not override this. Fix ${CONFIG_FILE} and re-run.
Nothing has been changed — and a verified backup was still taken:
  ${BACKUP_DIR}"
fi
if [[ $AUDIT_BLOCK -gt 0 ]]; then
    if [[ $FORCE == true ]]; then
        warn "--force given: proceeding despite ${AUDIT_BLOCK} blocker(s). This is on you."
        warn "A verified restore point exists at ${BACKUP_DIR}"
    else
        echo
        fail "Refusing to upgrade with ${AUDIT_BLOCK} unresolved blocker(s).
Fix them and re-run, or override with --force if you have decided they do not apply.
Nothing has been changed — and a verified backup was still taken:
  ${BACKUP_DIR}"
    fi
fi

# =============================================================================
phase "Phase 5 — Fetch target source"
# =============================================================================

if [[ $ONLINE == true ]]; then
    if ! command -v git >/dev/null; then
        wait_for_dpkg_lock "${DPKG_LOCKS[@]}" "${APT_LOCKS[@]}" \
            || fail "The package lock is held by another process (named above); git could not be installed. Nothing has been changed."
        apt-get -o "DPkg::Lock::Timeout=${DPKG_LOCK_WAIT_S}" install -y --no-install-recommends git -qq
    fi
    # Root-owned, 0700 and unpredictable. mktemp -d creates the directory
    # itself and fails rather than reusing one, so there is no race to lose;
    # assert_root_owned_path then walks every ancestor, because a root-owned
    # leaf under a parent someone else can write is still swappable.
    safe_install_dir 700 root root "$STAGE_ROOT"
    WORK_DIR="$(mktemp -d "${STAGE_ROOT}/src-${TIMESTAMP}-XXXXXX")" \
        || fail "Could not create a staging directory under ${STAGE_ROOT}."
    WORK_DIR_OWNED=true          # this run created it, so this run may delete it
    assert_root_owned_path "$WORK_DIR"
    info "Cloning ${REPO_URL} (${REPO_BRANCH}) into ${WORK_DIR} ..."
    # Hardened (round 2): TLS verification forced on whatever the host's git
    # config says; no file:// or other local transport; never prompt; SSH only
    # to an ALREADY-KNOWN host key; `--` so the URL can never be an option.
    GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o BatchMode=yes" \
        git -c http.sslVerify=true -c protocol.file.allow=never -c protocol.ext.allow=never \
            clone --depth 1 --branch "$REPO_BRANCH" --quiet -- "$REPO_URL" "$WORK_DIR" \
        || fail "git clone failed."
    # BEFORE ANY CONTENT IS READ: the tree must be exactly the reviewed commit.
    verify_clone_commit "$WORK_DIR" "$REPO_COMMIT"
else
    # The operator transferred this by hand onto an air-gapped host. It is not
    # ours to delete — see the cleanup at the end of the script.
    #
    # NOT under /tmp. Root reads this tree and then rsyncs tm/ into /opt,
    # installs a systemd unit and an nginx site, and pip-installs wheels from
    # it. A FIXED name under a world-writable directory means any local account
    # that can win the race to create it chooses what root executes — and the
    # documented procedure told the operator to mkdir exactly that path, which
    # succeeds and leaves an existing directory's ownership alone. Root-owned
    # location, and the ownership of every ancestor is asserted before reading.
    WORK_DIR="${OFFLINE_SRC_DIR}"
    WORK_DIR_OWNED=false
    [[ -d "$WORK_DIR" ]] || fail "Offline source not found at ${WORK_DIR}.
     Stage the bundle there first:
       sudo install -d -m 700 -o root -g root ${WORK_DIR}
       sudo tar xzf topic-manager-offline-<version>.tar.gz -C ${WORK_DIR} --strip-components=1
     See install/README.md."
    assert_root_owned_path "$WORK_DIR"
fi
TARGET_VERSION="$(cat "${WORK_DIR}/tm/VERSION" 2>/dev/null || echo 'unknown')"
[[ "$TARGET_VERSION" != "unknown" ]] || fail "Source tree has no tm/VERSION."
info "Upgrade path: ${INSTALLED_VER} → ${TARGET_VERSION}"

# Read the Python pins from the source tree NOW — before Phase 7 removes the
# running install. A malformed or incomplete requirements.txt must stop the run
# while the host is still untouched.
load_pins "${WORK_DIR}/requirements.txt"
require_pins flask werkzeug gunicorn ldap3 pyyaml cryptography confluent-kafka
PIN_FLASK="${PINS[flask]}"
PIN_WERKZEUG="${PINS[werkzeug]}"
PIN_GUNICORN="${PINS[gunicorn]}"
PIN_LDAP3="${PINS[ldap3]}"
PIN_PYYAML="${PINS[pyyaml]}"
PIN_CRYPTOGRAPHY="${PINS[cryptography]}"
PIN_CONFLUENT_KAFKA="${PINS[confluent-kafka]}"
info "Python pins from requirements.txt: Flask ${PIN_FLASK}, Werkzeug ${PIN_WERKZEUG}, gunicorn ${PIN_GUNICORN},"
info "  ldap3 ${PIN_LDAP3}, PyYAML ${PIN_PYYAML}, cryptography ${PIN_CRYPTOGRAPHY}, confluent-kafka ${PIN_CONFLUENT_KAFKA}"
success "Source fetched"

# =============================================================================
phase "Phase 6 — Patch system elements (OS + platform)"
# =============================================================================

if [[ $SKIP_OS == true ]]; then
    warn "--skip-os given: OS packages NOT patched this run."
elif [[ $ONLINE != true ]]; then
    warn "Offline: OS packages NOT patched this run."
else
    # Waited for BEFORE anything destructive: a held lock stops the run here,
    # with the holder named, and nothing has changed yet.
    wait_for_dpkg_lock "${DPKG_LOCKS[@]}" "${APT_LOCKS[@]}" \
        || fail "The package lock is held by another process (named above). Nothing has been changed; run again once it is released, or use --skip-os."
    DESTRUCTIVE_STARTED=true
    info "apt-get update ..."
    DEBIAN_FRONTEND=noninteractive apt-get -o "DPkg::Lock::Timeout=${DPKG_LOCK_WAIT_S}" update -qq
    info "apt-get full-upgrade (nginx, openssl, python3, krb5, open-vm-tools, kernel) ..."
    DEBIAN_FRONTEND=noninteractive apt-get -o "DPkg::Lock::Timeout=${DPKG_LOCK_WAIT_S}" \
        -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        full-upgrade -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get -o "DPkg::Lock::Timeout=${DPKG_LOCK_WAIT_S}" autoremove -y -qq
    success "OS packages patched"
    info "nginx:   $(nginx -v 2>&1 | sed 's|.*/||')"
    info "openssl: $(openssl version)"
    [[ -f /var/run/reboot-required ]] && warn "A REBOOT is required to activate the patched kernel/libraries."
fi

# =============================================================================
phase "Phase 7 — Stop service and replace application"
# =============================================================================

DESTRUCTIVE_STARTED=true
systemctl stop "$SERVICE" 2>/dev/null || true
# v1.2.0: and its socket, or the next request through nginx would start the
# service again in the middle of the replacement (socket activation).
systemctl stop "${SERVICE}.socket" 2>/dev/null || true
info "Removing previous application files (config, data and certs are NOT touched) ..."
rm -rf "$VENV" "${APP_HOME}/tm" "${APP_HOME}/wsgi.py"
rm -rf "${FRONTEND_DIR:?}"/*
rm -f /etc/nginx/sites-enabled/topic-manager
success "Previous application removed"

# =============================================================================
phase "Phase 8 — Install third-party components (hash-locked by requirements.lock)"
# =============================================================================

info "Creating virtual environment ..."
python3 -m venv "$VENV"
ls "${VENV}/lib/python"*"/site-packages/" >/dev/null 2>&1 || fail "venv creation failed."

# ROUND 2: ONE hash-locked install of requirements.lock — every package,
# transitive ones included, verified by SHA-256; binary wheels only; no pip
# self-upgrade (an unhashed download of the installer itself, and a hard
# failure offline). The three separately-staged installs, with the Kafka
# client allowed to soft-fail, are gone: with --require-hashes a stage must
# carry its own dependencies, and a hash failure is never something to carry
# on past. require_pins (Phase 5) still holds requirements.txt to its
# consumers, and the lock is held to requirements.txt here.
LOCK_FILE="${WORK_DIR}/requirements.lock"
[[ -f "$LOCK_FILE" ]] || fail "${LOCK_FILE} not found — the source tree has no hash lock."
for _pin in flask werkzeug gunicorn ldap3 pyyaml cryptography confluent-kafka; do
    grep -qiE "^${_pin//-/[-_.]}==${PINS[$_pin]//./[.]}[[:space:]]" "$LOCK_FILE" \
        || fail "requirements.lock does not pin ${_pin}==${PINS[$_pin]} as requirements.txt does."
done
PIP_ARGS=(--require-hashes --only-binary :all:)
if [[ $ONLINE != true ]]; then
    PY_PKG_DIR="${WORK_DIR}/install/packages/python"
    [[ -d "$PY_PKG_DIR" ]] || fail "Offline install needs ${PY_PKG_DIR} (run prepare-offline.sh)."
    PIP_ARGS+=(--no-index --find-links="$PY_PKG_DIR")
fi
info "Installing the hash-locked dependency set ..."
"${VENV}/bin/pip" install "${PIP_ARGS[@]}" --quiet -r "$LOCK_FILE" \
    || fail "pip install from requirements.lock failed (a hash mismatch is refused, not retried)."
success "Flask ${PIN_FLASK} / Werkzeug ${PIN_WERKZEUG} / gunicorn ${PIN_GUNICORN} / ldap3 ${PIN_LDAP3}"
success "PyYAML ${PIN_PYYAML} / cryptography ${PIN_CRYPTOGRAPHY} / confluent-kafka ${PIN_CONFLUENT_KAFKA} (all hash-verified)"

"${VENV}/bin/python3" -c "import flask, werkzeug, gunicorn, ldap3, yaml, cryptography, confluent_kafka" \
    || fail "Package import check failed."
success "Dependency imports verified"

# =============================================================================
phase "Phase 9 — Deploy application"
# =============================================================================
# Before the first host artefact is written: what this release is about to
# install, so a rollback from anywhere below retires it by record even though
# the manifest proper is written only once it is all in place.
write_install_manifest "$WORK_DIR" pending

info "Deploying backend ..."
rsync -a "${WORK_DIR}/tm/" "${APP_HOME}/tm/"
printf 'from tm.app import create_app\napplication = create_app()\n' > "${APP_HOME}/wsgi.py"

info "Deploying frontend ..."
rsync -a "${WORK_DIR}/index.html" "${WORK_DIR}/app" "${FRONTEND_DIR}/"
mkdir -p "${FRONTEND_DIR}/lib"

# Vue: fetch, then verify BY CONTENT HASH before it is allowed to serve.
VUE_DEST="${FRONTEND_DIR}/lib/vue.global.prod.js"
VUE_TMP="$(mktemp)"; VUE_OK=false
if [[ $ONLINE == true ]]; then
    if curl -fsSL --max-time 60 "$VUE_URL" -o "$VUE_TMP"; then
        GOT="$(sha256sum "$VUE_TMP" | cut -d' ' -f1)"
        if [[ "$GOT" == "$VUE_SHA256" ]]; then
            mv "$VUE_TMP" "$VUE_DEST"; VUE_OK=true
            success "Vue ${VUE_VERSION} verified (sha256 ${VUE_SHA256:0:16}...)"
        else
            rm -f "$VUE_TMP"
            fail "Vue integrity check FAILED. Expected ${VUE_SHA256}, got ${GOT}. Refusing to deploy an unverified script."
        fi
    else
        warn "Vue CDN download failed — falling back to bundled/backup copy."
    fi
fi
if [[ $VUE_OK != true ]] && [[ -f "${WORK_DIR}/lib/vue.global.prod.js" ]]; then
    GOT="$(sha256sum "${WORK_DIR}/lib/vue.global.prod.js" | cut -d' ' -f1)"
    [[ "$GOT" == "$VUE_SHA256" ]] || fail "Bundled Vue hash mismatch (${GOT}). Refusing to deploy."
    cp "${WORK_DIR}/lib/vue.global.prod.js" "$VUE_DEST"; VUE_OK=true
    success "Vue ${VUE_VERSION} installed from offline bundle (hash verified)"
fi
if [[ $VUE_OK != true ]] && [[ -f "${BACKUP_DIR}/frontend/lib/vue.global.prod.js" ]]; then
    # Round 2: held to the SAME pin. Only a backed-up copy that is
    # byte-identical to the pinned release may serve; a previous version, or a
    # file changed since, is refused like any other unverified script.
    GOT="$(sha256sum "${BACKUP_DIR}/frontend/lib/vue.global.prod.js" | cut -d' ' -f1)"
    if [[ "$GOT" == "$VUE_SHA256" ]]; then
        cp "${BACKUP_DIR}/frontend/lib/vue.global.prod.js" "$VUE_DEST"; VUE_OK=true
        success "Vue ${VUE_VERSION} taken from the backup (hash verified)"
    else
        warn "The backed-up Vue does not match the pinned SHA-256 (${GOT:0:16}...) — not used."
    fi
fi
rm -f "$VUE_TMP" 2>/dev/null || true
[[ $VUE_OK == true ]] || fail "No verified Vue bundle available — the UI would not load."

for asset in jarvis-favicon.ico jarvis-glyph-32.png jarvis-logo.png jarvis-mark.png; do
    [[ -f "${WORK_DIR}/${asset}" ]] && cp "${WORK_DIR}/${asset}" "${FRONTEND_DIR}/${asset}"
done

info "Installing nginx configuration ..."
mkdir -p /etc/nginx/snippets
# nginx discards ALL inherited add_header directives as soon as a child
# location declares its own — every location must include this snippet.
cp "${WORK_DIR}/nginx/tm-security-headers.conf" /etc/nginx/snippets/tm-security-headers.conf
cp "${WORK_DIR}/nginx/topic-manager.conf" /etc/nginx/sites-available/topic-manager
PREV_SN="$(grep -m1 -oP 'server_name\s+\K[^;]+' "${BACKUP_DIR}/system/topic-manager.nginx" 2>/dev/null || true)"
if [[ -n "$PREV_SN" ]] && ! grep -q "YOUR-HOSTNAME" <<<"$PREV_SN"; then
    sed -i "s|server_name .*;|server_name ${PREV_SN};|" /etc/nginx/sites-available/topic-manager
    info "Preserved server_name: ${PREV_SN}"
fi
ln -sf /etc/nginx/sites-available/topic-manager /etc/nginx/sites-enabled/topic-manager
rm -f /etc/nginx/sites-enabled/default

# v1.2.0: the managed files are kept (release defaults only where absent), the
# :80 redirect becomes its own site. From a release BEFORE v1.2.0 the old site
# file carried the :80 block, so the redirect site is enabled to match; from
# v1.2.0 on, the link is left exactly as the operator's last apply left it.
install_if_absent 644 "${WORK_DIR}/nginx/tm-limits.conf" /etc/nginx/conf.d/topic-manager-limits.conf
for f in tm-limits-server tm-limits-login tm-limits-api tm-syslog; do
    install_if_absent 644 "${WORK_DIR}/nginx/${f}.conf" "/etc/nginx/snippets/${f}.conf"
done
install -m 644 -o root -g root "${WORK_DIR}/nginx/topic-manager-http.conf" /etc/nginx/sites-available/topic-manager-http
if [[ -n "$PREV_SN" ]] && ! grep -q "YOUR-HOSTNAME" <<<"$PREV_SN"; then
    sed -i "s|server_name .*;|server_name ${PREV_SN};|" /etc/nginx/sites-available/topic-manager-http
fi
if [[ ! -f "${BACKUP_DIR}/system/v120/.present" ]]; then
    ln -sf /etc/nginx/sites-available/topic-manager-http /etc/nginx/sites-enabled/topic-manager-http
    info "HTTP redirect: now its own site (enabled, as the previous release's :80 block was)"
fi
install -d -m 755 -o root -g root /etc/rsyslog.d/topic-manager
install_if_absent 644 "${WORK_DIR}/install/rsyslog/30-topic-manager.conf" /etc/rsyslog.d/30-topic-manager.conf
safe_install_dir 700 "$APP_USER" "$APP_USER" "${APP_HOME}/data/apply"
install_apply_helper "$WORK_DIR"
for u in "${V120_UNITS[@]}"; do
    install -m 644 -o root -g root "${WORK_DIR}/systemd/${u}" "/etc/systemd/system/${u}"
done
success "Apply helper, apply units and the audit prune timer installed; managed files kept"

info "Installing systemd unit and logrotate ..."
cp "${WORK_DIR}/systemd/topic-manager.service" /etc/systemd/system/
# v1.2.0: gunicorn's only listener is the Unix socket this unit creates, 0660
# topic-manager:www-data; the TCP port 127.0.0.1:5001 of v1.1.x is gone. The
# nginx site installed above proxies to the socket.
install -m 644 -o root -g root "${WORK_DIR}/systemd/topic-manager.socket" \
    /etc/systemd/system/topic-manager.socket
# New in v1.0.4: the root-side `nginx -t` gate the Settings restart control
# calls before it touches nginx. Measured on prod 2026-09-01 — `nginx -t`
# as the topic-manager account dies on /run/nginx.pid (13: Permission
# denied), and -g 'pid ...;' collides with nginx.conf line 3. It has to be
# root, so it is a Type=oneshot unit with a fixed ExecStart.
install -m 644 -o root -g root \
    "${WORK_DIR}/systemd/topic-manager-nginx-test.service" \
    /etc/systemd/system/topic-manager-nginx-test.service
# polkit, not sudoers: sudo cannot run at all under NoNewPrivileges=true.
if [[ -d /etc/polkit-1/rules.d ]]; then
    install -m 644 -o root -g root \
        "${WORK_DIR}/install/polkit/50-topic-manager.rules" \
        /etc/polkit-1/rules.d/50-topic-manager.rules
    success "polkit rule installed for the service restart control"
else
    warn "polkit is not installed — the Settings restart control will report"
    warn "  'Interactive authentication required' until polkitd is present."
fi
[[ -f "${WORK_DIR}/install/logrotate.d/topic-manager" ]] && \
    cp "${WORK_DIR}/install/logrotate.d/topic-manager" /etc/logrotate.d/topic-manager
systemctl daemon-reload
systemctl enable "${SERVICE}.socket" "$SERVICE" --quiet
write_install_manifest "$WORK_DIR"
success "Application deployed (install manifest: ${INSTALL_MANIFEST})"

# =============================================================================
phase "Phase 10 — Restore configuration, data, certs and permissions"
# =============================================================================
# Outcome flags. The closing summary must report what ACTUALLY happened, not a
# fixed list — an unconditional "key-pair match verified" is the same
# misleading-claim defect this release exists to remove from die().
TLS_RESULT="no TLS material in the backup"
DB_RESULT="no audit database in the backup"
EXTRA_N=0
# =============================================================================

info "Restoring config.yaml ..."
cp -a "${BACKUP_DIR}/etc/config.yaml" "${CONFIG_DIR}/config.yaml"

# The cluster store, before Phase 11 migrates. Restoring first is what
# makes the migration idempotent across repeated upgrades: it sees the
# profiles that already exist and leaves them alone.
if [[ -d "${BACKUP_DIR}/etc/clusters.d" ]]; then
    safe_install_dir 750 "$APP_USER" "$APP_USER" "$CLUSTERS_DIR"
    cp -a "${BACKUP_DIR}/etc/clusters.d/." "${CLUSTERS_DIR}/"
    success "Cluster profiles restored"
fi
if [[ -d "${BACKUP_DIR}/data/cluster-certs" ]]; then
    safe_install_dir 700 "$APP_USER" "$APP_USER" "$CERT_DIR"
    cp -a "${BACKUP_DIR}/data/cluster-certs/." "${CERT_DIR}/"
    success "Kafka TLS material restored"
fi

# The unit drop-in is configuration in the same class as config.yaml: Phase 9
# replaced the unit file, and on a host that keeps TM_SECRET_KEY there this is
# the other half of what the service needs to start. Phase 9's daemon-reload
# ran before this, so reload again once the drop-in is back.
restore_dropin "$BACKUP_DIR"
systemctl daemon-reload

if [[ -f "${BACKUP_DIR}/data/tm.consistent.db" ]]; then
    cp -a "${BACKUP_DIR}/data/tm.consistent.db" "${APP_HOME}/data/tm.db"
    success "Audit database restored (consistent snapshot)"
    DB_RESULT="restored from the consistent snapshot"
elif [[ -f "${BACKUP_DIR}/data/tm.db" ]]; then
    cp -a "${BACKUP_DIR}/data/tm.db" "${APP_HOME}/data/tm.db"
    success "Audit database restored"
    DB_RESULT="restored from the raw file copy"
fi

if [[ -d "${BACKUP_DIR}/etc/tls" ]]; then
    mkdir -p "${CONFIG_DIR}/tls"
    cp -a "${BACKUP_DIR}/etc/tls/." "${CONFIG_DIR}/tls/"
    openssl x509 -in "${CONFIG_DIR}/tls/server.crt" -noout >/dev/null || fail "Restored certificate does not parse."
    # Compare the RAW public keys, never their hashes — see tls_keypair_matches.
    # v1.1.0: this used `openssl rsa -modulus`, which is RSA-only, so every EC
    # certificate (the FIPS-friendly choice, and what install.sh now generates)
    # was reported as "match NOT confirmed". The public-key comparison works for
    # RSA, EC and Ed25519 alike, and under FIPS mode.
    if tls_keypair_matches "${CONFIG_DIR}/tls/server.crt" "${CONFIG_DIR}/tls/server.key"; then
        success "TLS cert/key restored and key-pair match verified"
        TLS_RESULT="restored, key-pair match verified"
    else
        warn "The restored certificate and private key do NOT verify as a pair (or one"
        warn "  could not be read). nginx -t in Phase 11 is the backstop."
        TLS_RESULT="restored, key-pair match NOT confirmed"
    fi
    info "Certificate expires: $(openssl x509 -in "${CONFIG_DIR}/tls/server.crt" -noout -enddate | cut -d= -f2)"
fi

shopt -s nullglob
for f in "${BACKUP_DIR}"/etc/extra-certs/*; do
    cp -a "$f" "${CONFIG_DIR}/$(basename "$f")"
    info "Restored additional cert material: $(basename "$f")"
    EXTRA_N=$((EXTRA_N+1))
done
shopt -u nullglob

# --- Put permissions back exactly as they were.
# This is the STIG-safe half: the host's recorded ownership and modes are
# re-applied verbatim, so a deliberately narrowed permission is never widened
# back to this script's default.
info "Re-applying the recorded permission baseline ..."
for p in "${BASELINE_PATHS[@]}"; do apply_baseline "$p"; done
RESTORED_N=0
while IFS= read -r -d '' fp && IFS= read -r -d '' fo \
   && IFS= read -r -d '' fg && IFS= read -r -d '' fm; do
    # Validated BEFORE the existence test, deliberately: a check a record can
    # skip by naming a path that is not there is a check the record turns off.
    baseline_assert_record "$fp" "$fo" "$fg" "$fm"
    [[ -e "$fp" ]] || continue
    # -h and --, both load-bearing: a recorded file that has been replaced by a
    # symlink must not have its TARGET chowned, and a path is not an option.
    # The failures are no longer swallowed: `2>/dev/null || true` on a chown
    # that root cannot perform is a permission model that reports success.
    chown -h "${fo}:${fg}" -- "$fp" || fail "chown failed on ${fp}"
    chmod "$fm" -- "$fp" || fail "chmod failed on ${fp}"
    RESTORED_N=$((RESTORED_N+1))
done < <(baseline_stream "$PERM_BASELINE")
success "Re-applied recorded ownership/mode on ${RESTORED_N} paths"

# --- New files have no baseline entry. Give them the same treatment their
# directory got, then assert the functional minimum: nginx must be able to
# read what it serves, and the service account must own its own runtime.
FE_DIR_MODE="$(stat -c '%a' "$FRONTEND_DIR" 2>/dev/null || echo 755)"
FE_OWNER="$(stat -c '%U:%G' "$FRONTEND_DIR" 2>/dev/null || echo "${WEB_USER}:${WEB_USER}")"
# Derive the file mode from the DIRECTORY's own mode rather than a fixed go+r.
# An unconditional `chmod u+rw,go+r` grants group AND other read on every new
# file regardless of what the host intended — on a tree deliberately kept
# 0640 root:www-data that silently widens a STIG's access model. Masking the
# directory's mode with 0666 keeps the host's own model and drops execute.
FE_FILE_MODE="$(printf '%o' $(( 8#${FE_DIR_MODE} & 8#666 )))"
WIDENED=0; DEVIATED=0
while IFS= read -r f; do
    # Anchor the baseline lookup: an unanchored substring can match a longer
    # path that merely contains this one.
    if baseline_has "$PERM_BASELINE" "$f"; then
        continue    # recorded path — apply_baseline already restored it verbatim
    fi
    # New this release: it has no recorded owner/mode, so it takes the
    # directory's. Note this is the ONLY chown here — a recursive chown would
    # overwrite the per-file ownership the baseline loop just restored.
    chown "$FE_OWNER" "$f" 2>/dev/null || true
    if [[ -d "$f" ]]; then
        chmod "$FE_DIR_MODE" "$f"
    else
        chmod "$FE_FILE_MODE" "$f"
        # Then MEASURE, don't assume. The script's own principle is that
        # effective access is asked of the kernel, never inferred from mode
        # bits; a mode that looks right can still fail behind an ACL or a
        # parent directory. Only widen further if the kernel actually says no,
        # and report each widening as an explicit deviation.
        if ! can_access "$WEB_USER" -r "$f"; then
            chmod go+r "$f"
            if can_access "$WEB_USER" -r "$f"; then
                DEVIATED=$((DEVIATED+1))
                warn "  widened beyond the host's model to make ${f} servable"
            else
                # Widening did not achieve access — the blocker is elsewhere
                # (usually a parent directory the web user cannot traverse).
                # Leaving the file widened would loosen the host's model for
                # no benefit, so put it back and let the Phase 12 effective-
                # access re-audit fail the upgrade with the real reason.
                chmod "$FE_FILE_MODE" "$f"
                warn "  ${f} is unreadable by ${WEB_USER} and widening it does not help"
                warn "  — check traversal on the parent directories, not the file mode"
            fi
        fi
        WIDENED=$((WIDENED+1))
    fi
done < <(find "$FRONTEND_DIR" -mindepth 1)
[[ $WIDENED  -gt 0 ]] && info "Applied the frontend directory's own mode (${FE_FILE_MODE}) to ${WIDENED} newly deployed file(s)"
[[ $DEVIATED -gt 0 ]] && warn "${DEVIATED} file(s) needed read access beyond the host's model — review the lines above"
normalise_frontend_ownership "$FRONTEND_DIR"

chown -R "${APP_USER}:${APP_USER}" "${APP_HOME}/tm" "${APP_HOME}/wsgi.py" "$VENV"
apply_baseline "${APP_HOME}/tm"     "$APP_USER" "$APP_USER" 755
apply_baseline "${APP_HOME}/wsgi.py" "$APP_USER" "$APP_USER" 644
apply_baseline "${APP_HOME}/venv"   root root 755
safe_install_dir 755 "$APP_USER" "$APP_USER" "${APP_HOME}/logs"
apply_baseline "${APP_HOME}/logs" "$APP_USER" "$APP_USER" 750
# NOT the recorded mode (v1.1.0). data/ and tm.db are the one place the
# baseline is deliberately overridden: a v1.0.x host recorded 0755/0750 and
# 0644, and replaying that would put the audit trail and every live session
# id back in reach of every local account. This runs AFTER the replay loop
# above and after the cp -a restore of tm.db, so it is the last word.
enforce_audit_db_modes
success "Ownership and modes restored"

# =============================================================================
phase "Phase 11 — Configuration migration"
# =============================================================================

# --- The cluster store. Runs on EVERY upgrade, and does nothing on a host
# that is already migrated.
info "Ensuring the cluster profile store ..."
# install(1), never cp+chmod: under umask 077 the mode between the two is
# wrong, and on a STIG host that window is the whole exposure.
safe_install_dir 750 root "$APP_USER" "$CONFIG_DIR"
safe_install_dir 750 "$APP_USER" "$APP_USER" "$CLUSTERS_DIR"
safe_install_dir 700 "$APP_USER" "$APP_USER" "$CERT_DIR"
# No --example (v1.1.0): the example is a format reference, never live
# clusters. A host with no store and no legacy block gets an empty store.
PYTHONPATH="$APP_HOME" "${VENV}/bin/python3" -m tm.migrate_clusters \
    --config "$CONFIG_FILE" \
    --clusters-dir "$CLUSTERS_DIR" \
    || fail "Cluster profile migration failed. It writes clusters.yaml before it
     rewrites config.yaml, so DO NOT assume either file is untouched — read the
     error above. A verified restore point exists:
       ${BACKUP_DIR}
     Restore with: sudo bash ${SELF} --restore ${TIMESTAMP}"
chown "${APP_USER}:${APP_USER}" "$CLUSTERS_FILE"
chmod 640 "$CLUSTERS_FILE"
# Then hand the host its own recorded values back, if it had any.
apply_baseline "$CLUSTERS_DIR"  "$APP_USER" "$APP_USER" 750
apply_baseline "$CLUSTERS_FILE" "$APP_USER" "$APP_USER" 640
apply_baseline "$CERT_DIR"      "$APP_USER" "$APP_USER" 700
"${VENV}/bin/python3" -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if isinstance(d,dict) and isinstance(d.get('clusters'), list) else 1)" "$CLUSTERS_FILE" \
    || fail "${CLUSTERS_FILE} does not hold a cluster list after migration."
success "Cluster profiles at ${CLUSTERS_FILE}"

# --- The permission boundary, ASKED OF THE KERNEL as the real principal.
# Mode bits can look right while an ACL or a parent directory still says
# otherwise, and this is the boundary the whole clusters.d design exists
# to hold: the app writes its own directory and cannot touch the file that
# holds secret_key, ldap_bind_password and required_group.
can_access "$APP_USER" -r "$CLUSTERS_FILE" \
    || fail "${APP_USER} cannot READ ${CLUSTERS_FILE} — every cluster view would fail."
can_access "$APP_USER" -w "$CLUSTERS_DIR" \
    || fail "${APP_USER} cannot WRITE ${CLUSTERS_DIR} — the Cluster Builder could not save."
can_access "$APP_USER" -r "$CONFIG_FILE" \
    || fail "${APP_USER} cannot read config.yaml — the service would not start."
if can_access "$APP_USER" -w "$CONFIG_FILE"; then
    fail "${APP_USER} can WRITE ${CONFIG_FILE}. The application must never be able
     to modify the file holding secret_key and ldap_bind_password.
     Fix: sudo chown root:${APP_USER} ${CONFIG_FILE}; sudo chmod 640 ${CONFIG_FILE}"
fi
if can_access "$APP_USER" -w "$CONFIG_DIR"; then
    fail "${APP_USER} can WRITE ${CONFIG_DIR}. Directory write is UNLINK: the
     application could delete config.yaml and write its own, choosing its
     own required_group, then restart the service.
     Fix: sudo chown root:${APP_USER} ${CONFIG_DIR}; sudo chmod 750 ${CONFIG_DIR}"
fi
success "Permission boundary verified: the app owns clusters.d and cannot write config.yaml"

if ! grep -q 'ldap_ca_cert' "$CONFIG_FILE"; then
    sed -i '/ldap_server:/a\  ldap_ca_cert: ""         # blank = system trust store; set to CA PEM path if the DC cert is not trusted' "$CONFIG_FILE"
    apply_baseline "$CONFIG_FILE" root "$APP_USER" 640
    success "ldap_ca_cert added to config"
fi
"${VENV}/bin/python3" -c "import yaml; yaml.safe_load(open('${CONFIG_FILE}'))" \
    || fail "config.yaml failed YAML validation after migration."
success "config.yaml valid"
# v1.1.0: the http-level ssl_protocols line. Backed up, edited, nginx -t'd and
# put back on failure inside the function; the whole-file copy taken in Phase 4
# is what restore_from_backup puts back if a LATER phase fails.
manage_nginx_ssl_protocols /etc/nginx/nginx.conf "${BACKUP_DIR}/system/nginx.conf.before-tls-edit"
nginx -t >/dev/null 2>&1 || fail "nginx config test failed."
success "nginx config test passed"

# =============================================================================
phase "Phase 12 — Start and verify"
# =============================================================================

systemctl start "${SERVICE}.socket"
systemctl start "$SERVICE"
systemctl reload nginx
sleep 6

systemctl is-active --quiet "$SERVICE" || fail "${SERVICE} is not active after start."
success "Service active"

POST_HEALTH="$(curl -sk --max-time 15 https://localhost/api/health 2>/dev/null || true)"
grep -q '"ok"' <<<"$POST_HEALTH" || fail "Health check failed: ${POST_HEALTH:-no response}"
success "Health: ${POST_HEALTH}"

RUNNING_VER="$(curl -sk --max-time 10 https://localhost/api/version 2>/dev/null | grep -oP '"version":\s*"\K[^"]+' || echo unknown)"
[[ "$RUNNING_VER" == "$TARGET_VERSION" ]] \
    || fail "Version mismatch: API reports ${RUNNING_VER}, expected ${TARGET_VERSION}."
success "Version verified: ${RUNNING_VER}"

# --- Post-install permission re-audit. A scoped-down host can produce a
# perfectly healthy service that still 403s every page, so ask the kernel again.
info "Re-auditing effective access after deployment ..."
PERM_FAIL=0
recheck() {
    if can_access "$1" "$2" "$3"; then
        printf '      %-14s %-3s %s  OK\n' "$1" "$2" "$3"
    else
        warn "      ${1} ${2} ${3}  DENIED"
        PERM_FAIL=$((PERM_FAIL+1))
    fi
}
recheck "$WEB_USER" -r "${FRONTEND_DIR}/index.html"
recheck "$WEB_USER" -r "${FRONTEND_DIR}/lib/vue.global.prod.js"
recheck "$WEB_USER" -r "${FRONTEND_DIR}/app/main.js"
recheck "$APP_USER" -r "${CONFIG_DIR}/config.yaml"
recheck "$APP_USER" -x "${VENV}/bin/python3"
recheck "$APP_USER" -w "${APP_HOME}/data"
recheck "$APP_USER" -w "${APP_HOME}/logs"
# Measured, not assumed: the service has been running for a few seconds, so
# tm.db exists and any -wal file it made is there too.
for _dbp in "${APP_HOME}/data:700" "${APP_HOME}/data/tm.db:600"; do
    _got="$(stat -c '%a %U' "${_dbp%:*}" 2>/dev/null || echo 'missing')"
    if [[ "$_got" == "${_dbp##*:} ${APP_USER}" ]]; then
        printf '      %-14s %-3s %s  OK\n' "mode" "${_dbp##*:}" "${_dbp%:*}"
    else
        warn "      ${_dbp%:*} is ${_got}, expected ${_dbp##*:} ${APP_USER}"
        PERM_FAIL=$((PERM_FAIL+1))
    fi
done
[[ $PERM_FAIL -eq 0 ]] || fail "${PERM_FAIL} effective-access check(s) failed after deployment.
The service is running but cannot serve or write correctly. Rolling back."
success "Effective access verified for ${WEB_USER} and ${APP_USER}"

# --- Security headers must be SERVED, not merely configured. This class has
# regressed twice via nginx's add_header inheritance rule.
info "Verifying security headers on every route class ..."
HDR_FAIL=0
check_headers() {
    local path="$1" label="$2" hdrs
    hdrs="$(curl -skI --max-time 10 "https://localhost${path}" 2>/dev/null | tr 'A-Z' 'a-z')"
    for h in strict-transport-security x-content-type-options content-security-policy referrer-policy; do
        grep -q "^${h}:" <<<"$hdrs" || { warn "  MISSING ${h} on ${label} (${path})"; HDR_FAIL=$((HDR_FAIL+1)); }
    done
    grep -q 'frame-ancestors' <<<"$hdrs" || { warn "  MISSING frame-ancestors on ${label} (${path})"; HDR_FAIL=$((HDR_FAIL+1)); }
}
check_headers "/"                       "root document"
check_headers "/index.html"             "static html"
check_headers "/lib/vue.global.prod.js" "javascript"
check_headers "/app/styles/main.css"    "stylesheet"
check_headers "/api/health"             "api"
[[ $HDR_FAIL -eq 0 ]] && success "Security headers served on all route classes" \
    || fail "${HDR_FAIL} security header(s) not served. The add_header inheritance bug has regressed."

# --- The bind that gates every login on the new version.
if [[ "$LDAP_ST" == "OK" ]]; then
    success "LDAP service bind verified pre-upgrade — logins should work"
elif [[ "$LDAP_ST" == "SKIP" ]]; then
    info "Direct user bind in use (no service account configured)"
else
    warn "LDAP service bind was NOT healthy pre-upgrade (--force was used)."
    warn "Test an interactive login immediately; if it fails, roll back:"
    warn "  sudo bash ${SELF} --restore ${TIMESTAMP}"
fi

# --- v1.2.0: re-apply the saved host settings. The managed files were kept
# (Phase 9) and are now brought in line with tm.db through the same path as
# Settings > "Apply to host". NOT a rollback trigger: each domain's helper
# rolls itself back, the application is verified healthy above, and a
# failure here names the domain and the fix.
# The apply results are audited the moment they land (the .path unit), so it
# is enabled BEFORE the re-apply below starts any.
systemctl enable --now topic-manager-apply-audit.path >/dev/null 2>&1 \
    && success "Apply results are audited as they finish: topic-manager-apply-audit.path" \
    || warn "topic-manager-apply-audit.path could not be enabled: apply results are audited only when polled, at service start and by the daily prune. Run: systemctl enable --now topic-manager-apply-audit.path"
info "Re-applying the saved host settings (syslog, time, nginx) ..."
REAPPLY_FAILED=""
if run_as_app stage all >/dev/null; then
    for d in syslog time nginx; do
        systemctl start "topic-manager-apply-${d}.service" >/dev/null 2>&1 || true
        st="$(run_as_app result "$d" 2>/dev/null)" || st=""
        msg="$(printf '%s' "$st" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state","?") + ": " + d.get("message",""))' 2>/dev/null || echo "?: no result")"
        if [[ "$msg" == ok:* ]]; then
            success "Re-applied ${d}: ${msg#ok: }"
        else
            warn "Re-apply ${d} did NOT succeed — ${msg}"
            REAPPLY_FAILED="${REAPPLY_FAILED} ${d}"
        fi
    done
else
    warn "Could not stage the saved host settings; nothing was re-applied."
    REAPPLY_FAILED=" syslog time nginx"
fi
systemctl enable --now topic-manager-audit-prune.timer >/dev/null 2>&1 \
    && success "Audit retention: topic-manager-audit-prune.timer (daily)" \
    || warn "The audit prune timer could not be enabled: systemctl enable --now topic-manager-audit-prune.timer"
# Again now every unit is enabled: the enablement links are recorded as they are.
write_install_manifest "$WORK_DIR"
rm -f -- "${INSTALL_MANIFEST}.pending"

info "Installed third-party components:"
"${VENV}/bin/pip" freeze | sed 's/^/    /'
"${VENV}/bin/pip" freeze > "${BACKUP_DIR}/manifest/pip-freeze-after.txt"
sha256sum "$VUE_DEST" > "${BACKUP_DIR}/manifest/vue-after.sha256"
record_baseline "${BACKUP_DIR}/manifest/permissions.after"

# =============================================================================
phase "Upgrade complete"
# =============================================================================
trap - EXIT
umask "$ORIG_UMASK"
[[ -n "$TMP_EXEC_DIR" ]] && rm -rf "$TMP_EXEC_DIR"
rm -f "$AUDIT_REPORT"

echo
echo "${GREEN}══════════════════════════════════════════════════════${NC}"
echo "${GREEN}  Topic Manager  ${INSTALLED_VER}  →  ${TARGET_VERSION}${NC}"
echo "${GREEN}══════════════════════════════════════════════════════${NC}"
echo
echo "  Backup dir : ${BACKUP_DIR}"
echo "  Backup tar : ${BACKUP_TAR}"
echo "  Log        : ${LOG_FILE}"
echo "  Perms      : ${BACKUP_DIR}/manifest/permissions.baseline (before)"
echo "               ${BACKUP_DIR}/manifest/permissions.after    (after)"
echo "               diff these two to see exactly what moved"
echo
echo "${BOLD}Restored from the pre-upgrade system:${NC}"
echo "    config.yaml (incl. LDAP bind password and secret_key)"
echo "    TLS server certificate + private key   (${TLS_RESULT})"
if [[ $EXTRA_N -gt 0 ]]; then
echo "    ${EXTRA_N} additional CA/cert file(s) in ${CONFIG_DIR}"
fi
echo "    audit database + sessions + app settings   (${DB_RESULT})"
echo "    nginx server_name"
if [[ -d "${BACKUP_DIR}/system/${DROPIN_BACKUP_NAME}" ]]; then
echo "    systemd unit drop-in (TM_SECRET_KEY / TM_LDAP_BIND_PASSWORD)"
fi
echo "    ownership and modes on ${RESTORED_N} paths, verbatim"
echo "    Settings-managed host files (rate limits, HTTP redirect, syslog, time) kept and re-applied"
if [[ -n "$REAPPLY_FAILED" ]]; then
echo "    ${YELLOW}NOT re-applied:${REAPPLY_FAILED}${NC} — see the warnings above and"
echo "      TROUBLESHOOTING.md -> Apply to host; re-apply from Settings once fixed"
fi
echo
echo "${BOLD}Post-upgrade checklist:${NC}"
# Numbered as printed, so a step that does not apply leaves no gap (the fixed
# numbers read 1, 2, 5 on a host with no AIDE and no reboot pending).
STEP=0
step() { STEP=$((STEP + 1)); echo "  ${STEP}. $*"; }
step "Test an interactive AD login at https://$(hostname -f 2>/dev/null || hostname)"
step "Hard-refresh browsers (Ctrl+Shift+R) — JS cache tokens changed"
if systemctl is-active --quiet aide 2>/dev/null; then
step "Re-baseline AIDE:  sudo aide --init && sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
fi
if [[ -f /var/run/reboot-required ]]; then
step "${YELLOW}REBOOT REQUIRED${NC}:  sudo shutdown -r +5 'Topic Manager post-upgrade reboot'"
fi
step "Take a fresh vCSA snapshot once the above is confirmed good"
echo
echo "  Rollback:  sudo bash ${SELF} --restore ${TIMESTAMP}"
echo

# Only remove a working tree THIS run created. In --offline mode WORK_DIR is the
# bundle the operator carried onto an air-gapped host by hand; deleting it on
# success left them with no source for a second run and none for a re-upgrade
# after --restore, on a machine that cannot fetch one.
if [[ $WORK_DIR_OWNED == true ]]; then
    rm -rf "$WORK_DIR" 2>/dev/null || true
else
    echo "  Offline source left in place (not created by this run): ${WORK_DIR}"
    echo
fi
exit 0
