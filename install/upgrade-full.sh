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
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -euo pipefail

# ─── tunables ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/ymxplusb/Topic-Manager.git"
REPO_BRANCH="main"

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

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="/var/backups/topic-manager"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
BACKUP_TAR="${BACKUP_ROOT}/topic-manager-backup-${TIMESTAMP}.tar.gz"
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
VUE_VERSION="3.5.42"
VUE_SHA256="aae6339a0e744cc3503f2a3ae63f5ee0d99ce39f45517e7a51fcb9ecc290ca2c"
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
  "/etc/nginx/sites-available/topic-manager"
  "/etc/nginx/snippets/tm-security-headers.conf"
  "/etc/systemd/system/topic-manager.service"
  "$DROPIN_DIR"
  "/etc/logrotate.d/topic-manager"
)

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
        --restore)       shift; RESTORE_TS="${1:-}"
                         [[ -n "$RESTORE_TS" ]] || { echo "--restore needs a timestamp (see --list-backups)" >&2; exit 2; } ;;
        -h|--help)       sed -n '2,42p' "$0"; exit 0 ;;
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
# the next upgrade or reinstall. Refuse BEFORE the call, so the mutation cannot
# happen — detecting it afterwards is reporting a chown that already ran.
safe_install_dir() {   # safe_install_dir <mode> <owner> <group> <path>
    local m="$1" o="$2" g="$3" p="$4"
    [[ -L "$p" ]] && fail "${p} is a symlink; refusing to apply ownership through it.
     install -d would chmod and chown whatever it points at. Remove it, or put
     the real directory back, and run again."
    [[ -e "$p" && ! -d "$p" ]] && fail "${p} exists and is not a directory."
    install -d -m "$m" -o "$o" -g "$g" "$p"
}

# can_access <user> <test-flag> <path> — the honest check. Mode bits can look
# right while an ACL, a parent directory or a MAC policy still says no, so ask
# the kernel as the actual principal.
can_access() { sudo -u "$1" test "$2" "$3" 2>/dev/null; }

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
    systemctl stop "$SERVICE" 2>/dev/null || true

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
    [[ -f "${BD}/system/topic-manager.service" ]] && \
        cp -a "${BD}/system/topic-manager.service" /etc/systemd/system/
    restore_dropin "$BD"
    [[ -f "${BD}/system/logrotate-topic-manager" ]] && \
        cp -a "${BD}/system/logrotate-topic-manager" /etc/logrotate.d/topic-manager
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
    local h v
    h="$(curl -sk --max-time 10 https://localhost/api/health 2>/dev/null || true)"
    v="$(grep -oP 'topic_manager_version=\K.*' "${BD}/manifest/state.env" 2>/dev/null || echo '?')"
    if grep -q '"ok"' <<<"$h"; then
        success "Restore complete — back on v${v}, healthy: ${h}"
        return 0
    fi
    warn "Restore ran but health is not OK: ${h:-no response}"
    warn "Restore the vCSA snapshot. Backup retained at ${BD}"
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
    echo; echo "  Restore with:  sudo bash upgrade-full.sh --restore <timestamp>"
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
    if lsattr -d "$p" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
        row BLOCK "immutable attribute set" "$p — chattr -i required before upgrade"
        IMMUT=$((IMMUT+1))
    fi
done
[[ $IMMUT -eq 0 ]] && row PASS "no immutable attributes" "on any path this upgrade writes"

ACL_FOUND=0
for p in "$FRONTEND_DIR" "$CONFIG_DIR" "$APP_HOME"; do
    [[ -d "$p" ]] || continue
    if getfacl -p "$p" 2>/dev/null | grep -qE '^(user|group|mask):[^:]+:'; then
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

echo
echo "  ── recorded permission baseline"
info "Current ownership and modes on the paths this upgrade touches:"
for p in "${BASELINE_PATHS[@]}"; do
    [[ -e "$p" ]] && printf '      %-10s %-28s %s\n' \
        "$(stat -c '%a' "$p")" "$(stat -c '%U:%G' "$p")" "$p"
done
info "These exact values are captured in Phase 4 and re-applied in Phase 10."

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
LDAP_DN="$(grep -oP 'ldap_bind_dn:\s*"\K[^"]+' "$CONFIG_FILE" 2>/dev/null | head -1 || true)"
LDAP_SRV_RAW="$(grep -oP 'ldap_server:\s*"?\K[^"]+' "$CONFIG_FILE" 2>/dev/null | head -1 || true)"

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

# --- 3. LDAPS trust. The new version enforces CERT_REQUIRED; an untrusted DC
# certificate turns into a login outage rather than a warning.
LDAP_SRV="$(grep -oP 'ldap_server:\s*"?\Kldaps://[^"]+' "$CONFIG_FILE" 2>/dev/null | head -1 || true)"
if [[ -n "$LDAP_SRV" ]]; then
    HP="${LDAP_SRV#ldaps://}"
    RC="$(timeout 15 openssl s_client -connect "$HP" -CAfile /etc/ssl/certs/ca-certificates.crt \
            </dev/null 2>&1 | grep -m1 'Verify return code' || true)"
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
success "Baseline recorded ($(wc -l < "$PERM_BASELINE") paths)"
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
    else warn "SQLite consistent snapshot failed — raw file copy retained"; fi
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
[[ -f /etc/systemd/system/topic-manager.service ]] && \
    cp -a /etc/systemd/system/topic-manager.service "${BACKUP_DIR}/system/"
backup_dropin "$BACKUP_DIR"
[[ -f /etc/logrotate.d/topic-manager ]] && \
    cp -a /etc/logrotate.d/topic-manager "${BACKUP_DIR}/system/logrotate-topic-manager"

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
    command -v git >/dev/null || apt-get install -y --no-install-recommends git -qq
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
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$WORK_DIR" --quiet || fail "git clone failed."
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
    DESTRUCTIVE_STARTED=true
    info "apt-get update ..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    info "apt-get full-upgrade (nginx, openssl, python3, krb5, open-vm-tools, kernel) ..."
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        full-upgrade -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq
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
info "Removing previous application files (config, data and certs are NOT touched) ..."
rm -rf "$VENV" "${APP_HOME}/tm" "${APP_HOME}/wsgi.py"
rm -rf "${FRONTEND_DIR:?}"/*
rm -f /etc/nginx/sites-enabled/topic-manager
success "Previous application removed"

# =============================================================================
phase "Phase 8 — Install third-party components (pinned by requirements.txt)"
# =============================================================================

info "Creating virtual environment ..."
python3 -m venv "$VENV"
ls "${VENV}/lib/python"*"/site-packages/" >/dev/null 2>&1 || fail "venv creation failed."
"${VENV}/bin/pip" install --upgrade pip --quiet

PIP_ARGS=()
if [[ $ONLINE != true ]]; then
    PY_PKG_DIR="${WORK_DIR}/install/packages/python"
    [[ -d "$PY_PKG_DIR" ]] || fail "Offline install needs ${PY_PKG_DIR} (run prepare-offline.sh)."
    PIP_ARGS=(--no-index --find-links="$PY_PKG_DIR")
fi

# Staged deliberately — web stack, then auth/crypto, then the Kafka client which
# soft-fails because the app runs without it. Every version below came out of
# requirements.txt in Phase 5; there is no second list to drift from it, and
# require_pins has already refused any pin no stage here installs.
info "Installing web stack ..."
"${VENV}/bin/pip" install "${PIP_ARGS[@]}" --quiet \
    "Flask==${PIN_FLASK}" "Werkzeug==${PIN_WERKZEUG}" "gunicorn==${PIN_GUNICORN}" \
    || fail "pip install of the web stack failed."
success "Flask ${PIN_FLASK} / Werkzeug ${PIN_WERKZEUG} / gunicorn ${PIN_GUNICORN}"

info "Installing auth and crypto stack ..."
"${VENV}/bin/pip" install "${PIP_ARGS[@]}" --quiet \
    "ldap3==${PIN_LDAP3}" "PyYAML==${PIN_PYYAML}" "cryptography==${PIN_CRYPTOGRAPHY}" \
    || fail "pip install of ldap3/PyYAML/cryptography failed."
success "ldap3 ${PIN_LDAP3} / PyYAML ${PIN_PYYAML} / cryptography ${PIN_CRYPTOGRAPHY}"

info "Installing Kafka client ..."
"${VENV}/bin/pip" install "${PIP_ARGS[@]}" --quiet "confluent-kafka==${PIN_CONFLUENT_KAFKA}" \
    || warn "confluent-kafka install failed — Kafka operations will not work until resolved."

"${VENV}/bin/python3" -c "import flask, werkzeug, gunicorn, ldap3, yaml, cryptography" \
    || fail "Package import check failed."
"${VENV}/bin/python3" -c "import confluent_kafka" 2>/dev/null \
    && success "confluent-kafka importable" || warn "confluent_kafka NOT importable."
success "Dependency imports verified"

# =============================================================================
phase "Phase 9 — Deploy application"
# =============================================================================

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
    cp "${BACKUP_DIR}/frontend/lib/vue.global.prod.js" "$VUE_DEST"; VUE_OK=true
    warn "Vue restored from BACKUP (previous version) — frontend lib NOT upgraded."
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

info "Installing systemd unit and logrotate ..."
cp "${WORK_DIR}/systemd/topic-manager.service" /etc/systemd/system/
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
systemctl enable "$SERVICE" --quiet
success "Application deployed"

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
    # Compare the RAW moduli, never their hashes. sha256sum emits a digest even
    # for empty input, so hashing first makes the check unfalsifiable: if both
    # openssl calls fail and produce nothing, both digests are the sha256 of
    # nothing (e3b0c442...), they compare EQUAL, and the script reports a
    # key-pair match it never verified. Require a real modulus from each side.
    C_MOD="$(openssl x509 -noout -modulus -in "${CONFIG_DIR}/tls/server.crt" 2>/dev/null || true)"
    K_MOD="$(openssl rsa  -noout -modulus -in "${CONFIG_DIR}/tls/server.key" 2>/dev/null || true)"
    if [[ "$C_MOD" != Modulus=* ]] || [[ "$K_MOD" != Modulus=* ]]; then
        C_MOD=""; K_MOD="x"   # force the mismatch branch; never silently agree
    fi
    if [[ -n "$C_MOD" && "$C_MOD" == "$K_MOD" ]]; then
        success "TLS cert/key restored and key-pair match verified"
        TLS_RESULT="restored, key-pair match verified"
    else
        warn "Could not confirm cert/key modulus match (non-RSA key?). nginx -t is the backstop."
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

chown -R "${APP_USER}:${APP_USER}" "${APP_HOME}/tm" "${APP_HOME}/wsgi.py" "$VENV"
apply_baseline "${APP_HOME}/tm"     "$APP_USER" "$APP_USER" 755
apply_baseline "${APP_HOME}/wsgi.py" "$APP_USER" "$APP_USER" 644
apply_baseline "${APP_HOME}/venv"   root root 755
safe_install_dir 755 "$APP_USER" "$APP_USER" "${APP_HOME}/data"
safe_install_dir 755 "$APP_USER" "$APP_USER" "${APP_HOME}/logs"
apply_baseline "${APP_HOME}/data" "$APP_USER" "$APP_USER" 750
apply_baseline "${APP_HOME}/logs" "$APP_USER" "$APP_USER" 750
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
PYTHONPATH="$APP_HOME" "${VENV}/bin/python3" -m tm.migrate_clusters \
    --config "$CONFIG_FILE" \
    --clusters-dir "$CLUSTERS_DIR" \
    --example "${WORK_DIR}/config/clusters.yaml.example" \
    || fail "Cluster profile migration failed. It writes clusters.yaml before it
     rewrites config.yaml, so DO NOT assume either file is untouched — read the
     error above. A verified restore point exists:
       ${BACKUP_DIR}
     Restore with: sudo bash upgrade-full.sh --restore ${TIMESTAMP}"
chown "${APP_USER}:${APP_USER}" "$CLUSTERS_FILE"
chmod 640 "$CLUSTERS_FILE"
# Then hand the host its own recorded values back, if it had any.
apply_baseline "$CLUSTERS_DIR"  "$APP_USER" "$APP_USER" 750
apply_baseline "$CLUSTERS_FILE" "$APP_USER" "$APP_USER" 640
apply_baseline "$CERT_DIR"      "$APP_USER" "$APP_USER" 700
"${VENV}/bin/python3" -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if isinstance(d,dict) and d.get('clusters') else 1)" "$CLUSTERS_FILE" \
    || fail "${CLUSTERS_FILE} does not hold a non-empty cluster list after migration."
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
nginx -t >/dev/null 2>&1 || fail "nginx config test failed."
success "nginx config test passed"

# =============================================================================
phase "Phase 12 — Start and verify"
# =============================================================================

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
    warn "  sudo bash upgrade-full.sh --restore ${TIMESTAMP}"
fi

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
echo
echo "${BOLD}Post-upgrade checklist:${NC}"
echo "  1. Test an interactive AD login at https://$(hostname -f 2>/dev/null || hostname)"
echo "  2. Hard-refresh browsers (Ctrl+Shift+R) — JS cache tokens changed"
if systemctl is-active --quiet aide 2>/dev/null; then
echo "  3. Re-baseline AIDE:  sudo aide --init && sudo mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
fi
if [[ -f /var/run/reboot-required ]]; then
echo "  4. ${YELLOW}REBOOT REQUIRED${NC}:  sudo shutdown -r +5 'Topic Manager post-upgrade reboot'"
fi
echo "  5. Take a fresh vCSA snapshot once the above is confirmed good"
echo
echo "  Rollback:  sudo bash upgrade-full.sh --restore ${TIMESTAMP}"
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
