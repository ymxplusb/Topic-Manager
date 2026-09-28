#!/usr/bin/env bash
# =============================================================================
# Jarvis Topic Manager — Install Script
# Version: 1.1.1
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
#
# FRESH INSTALL on a clean Ubuntu 24.04 host (including a STIG'd one with FIPS
# mode enabled), online or offline. To move an EXISTING host to a new release,
# use install/upgrade-full.sh instead — it backs up, audits and rolls back.
#
# Usage:
#   sudo bash install.sh [options]
#
#   --ldap-url URL          LDAPS URL of the directory, e.g. ldaps://dc1.example.org:636
#   --ldap-base-dn DN       user search base, e.g. DC=example,DC=org
#   --ldap-domain DOMAIN    UPN suffix users sign in with (default: from the base DN)
#   --ldap-group DN         group whose members may sign in
#   --ldap-bind-dn DN       optional service account for directory searches; its
#                           password is read from TM_LDAP_BIND_PASSWORD or prompted
#                           for, never taken on the command line
#   --ldap-ca-cert PATH     optional CA bundle for the directory's certificate
#   --server-name FQDN      name the site answers to (default: hostname -f)
#   --tls-cert PATH --tls-key PATH
#                           install this certificate and key (verified as a pair);
#                           without them an existing pair is kept, or a
#                           self-signed ECDSA P-256 placeholder is generated
#   --non-interactive       never prompt; fail if a required value is missing
#
# There are NO environment defaults for the directory. On a fresh host the
# LDAP values come from the flags above or from prompts; an existing
# config.yaml is kept, and refused if it lacks auth.ldap_server,
# auth.ldap_base_dn or auth.ldap_domain.
#
# Online vs offline is detected (pypi.org reachable or not).
#   Online:  apt, PyPI and the Vue CDN (hash-verified).
#   Offline: the bundle built by prepare-offline.sh — install/packages/apt,
#            install/packages/python and lib/vue.global.prod.js.
# =============================================================================
set -euo pipefail

# Deterministic file creation. A STIG'd host runs root with umask 077, and a
# venv or frontend created under it is unreadable by the service account and
# by nginx (hazards[stig-umask-403]). Everything sensitive below is given its
# mode explicitly (install -m, chmod), so 0022 here widens nothing that matters.
umask 0022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_USER="topic-manager"
APP_HOME="/opt/topic-manager"
FRONTEND_DIR="/var/www/topic-manager"
CONFIG_DIR="/etc/topic-manager"
LOG_DIR="${APP_HOME}/logs"
DATA_DIR="${APP_HOME}/data"
# The one directory the application may write inside /etc. Its parent stays
# root-owned so config.yaml can be neither modified nor unlinked by the app:
# a directory the app can write is a directory in which it can UNLINK a
# root-owned 0600 file, which chained with the restart control would be a
# full auth-config takeover.
CLUSTERS_DIR="${CONFIG_DIR}/clusters.d"
CLUSTERS_FILE="${CLUSTERS_DIR}/clusters.yaml"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
CERT_DIR="${DATA_DIR}/cluster-certs"
# The upgrade script writes its restore points here and creates the directory
# itself. A fresh install did not, so the first upgrade of a new host was the
# thing that decided the mode of the directory holding config.yaml, the LDAP
# bind password and the audit database. Created here, root-only, from the start.
BACKUP_ROOT="/var/backups/topic-manager"
VENV="${APP_HOME}/venv"
SERVICE_NAME="topic-manager"
PYTHON="python3"
REQUIRED_PYTHON_VERSION="3.10"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }
# The same verb install/upgrade-full.sh uses, so the checks the two scripts
# share can be one identical copy rather than two that drift apart.
fail()    { die "$*"; }

# safe_install_dir <mode> <owner> <group> <path> — install -d that refuses to
# work through a symlink.
#
# install -d on an existing path is chmod() + chown(), and both FOLLOW symlinks.
# $CERT_DIR's parent (/opt/topic-manager/data) is app-owned and inside the
# unit's ReadWritePaths, so the application can replace cluster-certs with a
# symlink to anything and have root apply an owner and a mode to the target on
# the next reinstall. Refuse BEFORE the call, so the mutation cannot happen —
# detecting it afterwards is reporting a chown that already ran.
safe_install_dir() {   # safe_install_dir <mode> <owner> <group> <path>
    local m="$1" o="$2" g="$3" p="$4"
    [[ -L "$p" ]] && fail "${p} is a symlink; refusing to apply ownership through it.
     install -d would chmod and chown whatever it points at. Remove it, or put
     the real directory back, and run again."
    [[ -e "$p" && ! -d "$p" ]] && fail "${p} exists and is not a directory."
    install -d -m "$m" -o "$o" -g "$g" "$p"
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

# apt_fips_packages — print, one per line, every INSTALLED package that the
# offline bundle must never replace because it is a FIPS module (round 3):
#   * its installed version string contains "fips" in any case (Ubuntu Pro
#     FIPS builds: libssl3t64, openssl, openssh-*, libgcrypt20, gnutls,
#     strongswan, the kernel, ... carry "+Fips1" or "fips" in the version);
#   * or `apt-cache policy` (the HOST's own apt configuration, not the bundle's)
#     shows the installed version coming from a FIPS archive
#     (esm.ubuntu.com/fips, /fips-updates, /fips-preview).
# Fails closed: if either query cannot run, the caller stops rather than
# install without knowing which packages are FIPS modules.
apt_fips_packages() {
    local installed names=() by_version by_origin
    installed="$(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 2>/dev/null)" || return 1
    installed="$(printf '%s\n' "$installed" | awk -F'\t' '$3 ~ / installed$/')"
    [[ -n "$installed" ]] || return 1
    by_version="$(printf '%s\n' "$installed" | awk -F'\t' 'tolower($2) ~ /fips/ { print $1 }')"
    mapfile -t names < <(printf '%s\n' "$installed" | cut -f1 | sort -u)
    # The installed version is the "***" line; the origin lines under it are
    # indented deeper than a version line. A package header starts in column 1.
    by_origin="$(LC_ALL=C apt-cache policy "${names[@]}" 2>/dev/null)" || return 1
    by_origin="$(printf '%s\n' "$by_origin" | awk '
        /^[^ ]/            { pkg = $0; sub(/:$/, "", pkg); sub(/:.*/, "", pkg); inst = 0; next }
        /^ \*\*\* /        { inst = 1; next }
        /^     [^ ]/       { inst = 0; next }
        inst && /esm\.ubuntu\.com\/fips/ { print pkg }')"
    printf '%s\n%s\n' "$by_version" "$by_origin" | awk 'NF' | sort -u
}

# apt_plan_names <apt output> <word> — the package names apt lists under its
# "The following packages will be <word>:" header (REMOVED, upgraded), one per
# line. The list is the indented block under the header.
apt_plan_names() {
    printf '%s\n' "$1" | awk -v hdr="The following packages will be $2:" '
        $0 == hdr     { on = 1; next }
        on && /^  /   { for (i = 1; i <= NF; i++) { n = $i; sub(/\*$/, "", n); print n }; next }
        on            { exit }'
}

# apt_removal_reason <apt output> — when apt could only satisfy the request by
# REMOVING installed packages (refused: --no-remove), say which removals are
# forced by LOCKSTEP SIBLINGS the bundle lacks. Binaries built from one Debian
# source (python3.12, libpython3.12t64, libpython3.12-stdlib, ...) carry
# exact-version dependencies on each other; a bundle that upgrades part of a
# source without the rest leaves apt one way out — remove the rest, and
# everything that depends on it. Round 4, measured on the real STIG + FIPS
# host. Prints nothing when apt proposed no removal.
apt_removal_reason() {
    local plan="$1" removed upgraded srcs name src
    local -a sib=() dep=()
    local -A upsrc=()
    removed="$(apt_plan_names "$plan" REMOVED)"
    [[ -n "$removed" ]] || return 0
    upgraded="$(apt_plan_names "$plan" upgraded)"
    if [[ -n "$upgraded" ]]; then
        # shellcheck disable=SC2046  # one word per package name, by design
        while IFS=$'\t' read -r name src; do
            [[ -n "$src" ]] && upsrc["$src"]=1
        done < <(dpkg-query -W -f='${Package}\t${source:Package}\n' $(printf '%s\n' "$upgraded" | sed 's/:.*//') 2>/dev/null || true)
    fi
    # shellcheck disable=SC2046
    srcs="$(dpkg-query -W -f='${Package}\t${source:Package}\n' $(printf '%s\n' "$removed" | sed 's/:.*//') 2>/dev/null || true)"
    while IFS= read -r name; do
        src="$(printf '%s\n' "$srcs" | awk -F'\t' -v p="${name%%:*}" '$1 == p { print $2; exit }')"
        if [[ -n "$src" && -n "${upsrc[$src]:-}" ]]; then
            sib+=("${name} (source ${src})")
        else
            dep+=("$name")
        fi
    done <<<"$removed"
    printf 'apt could satisfy this only by REMOVING installed packages, and the\n'
    printf '     offline install never removes one.\n'
    if [[ ${#sib[@]} -gt 0 ]]; then
        printf '     Lockstep siblings missing from the bundle: %s\n' "${sib[*]}"
        printf '     — each is built from the same source as a package the plan upgrades, and\n'
        printf '     binaries of one source must be upgraded together.\n'
        [[ ${#dep[@]} -eq 0 ]] || printf '     Would be removed with them (they depend on them): %s\n' "${dep[*]}"
    else
        printf '     Would be removed: %s\n' "${dep[*]}"
    fi
    printf '     Rebuild the bundle with the prepare-offline.sh of this release (it adds\n'
    printf '     every binary of the same source) on a FULLY PATCHED Ubuntu 24.04 build\n'
    printf '     host of the same architecture, then run this again.\n'
}

# apt_install_from_bundle <bundle-apt-dir> <top-level package>... — offline.
#
# MEASURED 2026-09-26 on a STIG (USG stig) + FIPS Ubuntu 24.04.4 host: handing
# apt every bundled .deb that was not installed failed with "pkgProblemResolver
# ::Resolve generated breaks". The bundle holds a dependency CLOSURE, which
# includes every ALTERNATIVE provider (systemd-sysv, dbus-broker,
# systemd-standalone-sysusers, ...), and a host whose package set differs from
# the build host — a FIPS host always does — cannot take them all.
#
# MEASURED AGAIN on the same host (round 3): pinning the bundle to priority 1
# so it could never upgrade anything made apt refuse
#   python3.12-venv : Depends: python3.12 (= 3.12.3-1ubuntu0.17)
#                     but 3.12.3-1ubuntu0.13 is to be installed
# An air-gapped host lags on patches, so a newly installed package routinely
# needs a newer build of a library that is already installed. The policy is
# now: NEVER DOWNGRADE, NEVER REPLACE A FIPS PACKAGE, but UPGRADE what a
# dependency requires.
#
# So the bundle is used as a REPOSITORY, and apt's own resolver chooses:
#   * a temporary, ISOLATED apt configuration under mktemp -d: its source list
#     names ONLY the bundle ([trusted=yes] for that one file: path — the
#     .debs were verified when the bundle's sha256 was checked out of band),
#     its own preferences (the host's preferences.d is NOT read, so no host
#     pin can lift the bundle's priority), lists and archive cache; nothing is
#     written under /etc/apt;
#   * ONLY the missing TOP-LEVEL packages are named; never a .deb path;
#   * the bundle is at priority 500, so apt may UPGRADE an installed package to
#     the bundled build when resolution needs it. Below 1000 apt never selects
#     a version older than the installed one, so a DOWNGRADE is impossible —
#     never give the bundle a priority of 1000 or more;
#   * every installed FIPS package (apt_fips_packages) gets a pin of -1 for the
#     bundle's copy, so a FIPS module can never be swapped for a non-FIPS build.
#     If a bundled package needs a newer FIPS library, resolution FAILS;
#   * --no-remove: apt aborts rather than remove anything;
#   * the plan is simulated first (apt-get -s) and printed — what is NEWLY
#     INSTALLED and what is UPGRADED, as package=version — and refused if it
#     would downgrade or touch a FIPS package. On a terminal the operator
#     confirms it; --non-interactive (or no terminal) proceeds;
#   * --no-download: the .debs are placed in the private archive cache, so
#     apt uses them and fetches nothing;
#   * the temporary configuration is removed on every exit path (trap).
apt_install_from_bundle() {
    local dir="$1"; shift
    local tmp rc=0 fips_list="" p ans=""
    local plan="" line name old ver re_upg re_new why=""
    local -a fips=() plan_new=() plan_upg=() plan_bad=()
    local -A is_fips=()
    [[ -f "${dir}/Packages" || -f "${dir}/Packages.gz" ]] || die "Offline, and ${dir} has no Packages index.
     Rebuild the bundle with this release's prepare-offline.sh (it indexes the
     .debs), or install $* from the host's own package mirror."
    fips_list="$(apt_fips_packages)" || die "Could not read the installed package set and its origins
     (dpkg-query / apt-cache policy failed), so it cannot be established which
     installed packages are FIPS modules. Nothing has been changed."
    [[ -z "$fips_list" ]] || mapfile -t fips <<<"$fips_list"
    for p in "${fips[@]}"; do is_fips["$p"]=1; done
    tmp="$(mktemp -d)" || die "could not create a temporary apt configuration"
    # Removed on EVERY exit path: explicitly below, and by the EXIT trap if
    # die() (or set -e) ends the run anywhere in between.
    APT_BUNDLE_TMP="$tmp"
    trap 'rm -rf -- "${APT_BUNDLE_TMP:-/nonexistent}"' EXIT
    mkdir -p "${tmp}/lists/partial" "${tmp}/archives/partial" "${tmp}/parts" "${tmp}/prefparts"
    printf 'deb [trusted=yes] file:%s ./\n' "$dir" > "${tmp}/sources.list"
    # Specific (per-package) pins take precedence over the Package: * entry.
    {
        for p in "${fips[@]}"; do
            printf 'Package: %s\nPin: origin ""\nPin-Priority: -1\n\n' "$p"
        done
        printf 'Package: *\nPin: origin ""\nPin-Priority: 500\n'
    } > "${tmp}/preferences"
    cp -- "$dir"/*.deb "${tmp}/archives/" 2>/dev/null \
        || { rm -rf "$tmp"; die "${dir} holds no .deb files."; }
    local opts=(-o "Dir::Etc::SourceList=${tmp}/sources.list" -o "Dir::Etc::SourceParts=${tmp}/parts"
                -o "Dir::State::Lists=${tmp}/lists" -o "Dir::Cache=${tmp}" -o "Dir::Cache::Archives=${tmp}/archives"
                -o "Dir::Etc::Preferences=${tmp}/preferences" -o "Dir::Etc::PreferencesParts=${tmp}/prefparts"
                -o "Acquire::Languages=none" -o "APT::Get::List-Cleanup=false" -o "APT::Sandbox::User=root")
    local inst_opts=(--no-install-recommends --no-download --no-remove)
    info "Resolving from the offline bundle (never downgrades, never replaces FIPS packages; ${#fips[@]} FIPS package(s) held): $*"
    DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" update -qq || rc=$?
    if [[ $rc -eq 0 ]]; then
        plan="$(LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" -s install "${inst_opts[@]}" "$@" 2>&1)" || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        rm -rf -- "$tmp"; APT_BUNDLE_TMP=""; trap - EXIT
        [[ -z "$plan" ]] || printf '%s\n' "$plan" >&2
        why="$(apt_removal_reason "$plan")"
        [[ -z "$why" ]] || die "The offline bundle could not supply $* (apt exit ${rc}); nothing was
     installed or changed. The bundle never downgrades a package and never
     replaces a FIPS package, and ${why}
     See TROUBLESHOOTING.md -> Fresh install."
        die "The offline bundle could not supply $* (apt exit ${rc}); nothing was
     installed or changed. The bundle never downgrades a package and never
     replaces a FIPS package${fips_list:+ (held here: ${fips[*]})}. If apt says a
     package needs a NEWER version of a FIPS library, or of something the bundle
     does not carry, install $* from the host's own mirror (for a FIPS library,
     the Ubuntu Pro FIPS archive) instead. See TROUBLESHOOTING.md -> Fresh install."
    fi
    # "Inst pkg [installed] (candidate origin [arch])" is an upgrade (or a
    # downgrade); "Inst pkg (candidate ...)" is a new install.
    re_upg='^Inst ([^ ]+) \[([^]]+)\] \(([^ ]+)'
    re_new='^Inst ([^ ]+) \(([^ ]+)'
    while IFS= read -r line; do
        if [[ "$line" =~ $re_upg ]]; then
            name="${BASH_REMATCH[1]}"; old="${BASH_REMATCH[2]}"; ver="${BASH_REMATCH[3]}"
            if [[ -n "${is_fips[${name%%:*}]:-}" ]]; then
                plan_bad+=("${name}: FIPS package ${old} would be replaced by ${ver}")
            elif ! dpkg --compare-versions "$ver" gt "$old"; then
                plan_bad+=("${name}: ${old} would be DOWNGRADED to ${ver}")
            fi
            plan_upg+=("${name}=${ver} (from ${old})")
        elif [[ "$line" =~ $re_new ]]; then
            name="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}"
            [[ -z "${is_fips[${name%%:*}]:-}" ]] || plan_bad+=("${name}: FIPS package would be replaced by ${ver}")
            plan_new+=("${name}=${ver}")
        elif [[ "$line" == Remv\ * ]]; then
            plan_bad+=("${line#Remv }: would be REMOVED")
        fi
    done <<<"$plan"
    info "Offline package plan — NEW (${#plan_new[@]}): ${plan_new[*]:-none}; UPGRADE (${#plan_upg[@]}): ${plan_upg[*]:-none}"
    if [[ ${#plan_bad[@]} -gt 0 ]]; then
        rm -rf -- "$tmp"; APT_BUNDLE_TMP=""; trap - EXIT
        die "Refusing the offline package plan; nothing was installed or changed:
     $(printf '%s; ' "${plan_bad[@]}")
     The bundle never downgrades a package, never removes one and never
     replaces a FIPS package. See TROUBLESHOOTING.md -> Fresh install."
    fi
    if [[ ${NON_INTERACTIVE:-false} != true && -t 0 ]]; then
        read -r -p "  Apply this package plan? [y/N]: " ans || true
        if [[ "${ans,,}" != y && "${ans,,}" != yes ]]; then
            rm -rf -- "$tmp"; APT_BUNDLE_TMP=""; trap - EXIT
            die "Package plan declined. Nothing has been changed."
        fi
    fi
    DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" install -y "${inst_opts[@]}" "$@" || rc=$?
    rm -rf -- "$tmp"; APT_BUNDLE_TMP=""; trap - EXIT
    [[ $rc -eq 0 ]] || die "Offline package install failed (apt exit ${rc}) while applying the plan
     printed above. The bundle never downgrades a package and never replaces a
     FIPS package, but dpkg may have applied PART of that plan: check
     'dpkg --audit' before running this script again.
     See TROUBLESHOOTING.md -> Fresh install."
}

# normalise_frontend_install <dir> — a FRESH or re-installed frontend is
# root:root, directories 0755 and files 0644 (round 2, sec-review). It used to
# be chowned to www-data, so the web server could rewrite the JavaScript every
# administrator runs. The tree is public static content, so world-read is
# correct; nobody but root may write it. Symlinks are refused: nothing in the
# shipped tree is one, and a link here would be served.
normalise_frontend_install() {
    local d="$1" l
    [[ -L "$d" ]] && die "${d} is a symlink; refusing to install the frontend through it."
    l="$(find "$d" -type l -print -quit)"
    [[ -z "$l" ]] || die "${l} is a symlink inside the frontend tree; refusing. Remove it and run again."
    chown -R -h root:root "$d"
    find "$d" -type d -exec chmod 0755 {} +
    find "$d" -type f -exec chmod 0644 {} +
}

# can_access <user> <test-flag> <path> — the honest check. Mode bits can look
# right while an ACL, a parent directory or a MAC policy still says no, so ask
# the kernel as the actual principal.
can_access() { sudo -u "$1" test "$2" "$3" 2>/dev/null; }

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

# ─── options ─────────────────────────────────────────────────────────────────
OPT_TLS_CERT=""; OPT_TLS_KEY=""; OPT_SERVER_NAME=""
OPT_LDAP_URL=""; OPT_LDAP_BASE_DN=""; OPT_LDAP_DOMAIN=""; OPT_LDAP_GROUP=""
OPT_LDAP_BIND_DN=""; OPT_LDAP_CA_CERT=""; NON_INTERACTIVE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tls-cert)        shift; OPT_TLS_CERT="${1:-}" ;;
        --tls-key)         shift; OPT_TLS_KEY="${1:-}" ;;
        --server-name)     shift; OPT_SERVER_NAME="${1:-}" ;;
        --ldap-url)        shift; OPT_LDAP_URL="${1:-}" ;;
        --ldap-base-dn)    shift; OPT_LDAP_BASE_DN="${1:-}" ;;
        --ldap-domain)     shift; OPT_LDAP_DOMAIN="${1:-}" ;;
        --ldap-group)      shift; OPT_LDAP_GROUP="${1:-}" ;;
        --ldap-bind-dn)    shift; OPT_LDAP_BIND_DN="${1:-}" ;;
        --ldap-ca-cert)    shift; OPT_LDAP_CA_CERT="${1:-}" ;;
        --non-interactive) NON_INTERACTIVE=true ;;
        -h|--help)         sed -n '2,42p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)                 die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

# The name the site answers to and the self-signed placeholder is issued for.
# Validated because it is written into the nginx site with sed.
SERVER_NAME="${OPT_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}"
[[ "$SERVER_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?$ ]] \
    || die "Server name '${SERVER_NAME}' is not a valid host name. Pass --server-name <fqdn>."

# ─── root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash install.sh"

# ─── online detection ────────────────────────────────────────────────────────
ONLINE=false
# curl first; python3's own TLS stack when a minimal host has no curl yet.
if curl -s --max-time 4 https://pypi.org > /dev/null 2>&1; then
    ONLINE=true
elif python3 -c "import urllib.request; urllib.request.urlopen('https://pypi.org', timeout=4)" >/dev/null 2>&1; then
    ONLINE=true
fi
info "Install mode: $( [[ $ONLINE == true ]] && echo 'ONLINE' || echo 'OFFLINE' )"

# ─── directory settings (fresh host only) ────────────────────────────────────
# Asked for BEFORE anything is installed, so a missing answer stops the run on
# an untouched host. Flags win; otherwise prompt on a terminal; with
# --non-interactive (or no terminal) a missing required value is a refusal.
ask() {   # ask <variable> <prompt> [default]
    local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
    [[ -n "${!__var}" ]] && return 0
    if [[ $NON_INTERACTIVE == true || ! -t 0 ]]; then
        printf -v "$__var" '%s' "$__def"
        return 0
    fi
    read -r -p "  ${__prompt}${__def:+ [${__def}]}: " __ans || true
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

NEW_CONFIG=false
[[ -f "$CONFIG_FILE" ]] || NEW_CONFIG=true
LDAP_BIND_PW=""
if [[ $NEW_CONFIG == true ]]; then
    info "No ${CONFIG_FILE} yet — collecting the directory settings for it."
    ask OPT_LDAP_URL     "Directory LDAPS URL, e.g. ldaps://dc1.example.org:636"
    ask OPT_LDAP_BASE_DN "User search base DN, e.g. DC=example,DC=org"
    # DC=example,DC=org -> example.org, offered as the default sign-in domain.
    DERIVED_DOMAIN="$(printf '%s' "$OPT_LDAP_BASE_DN" | tr ',' '\n' \
        | sed -n 's/^[[:space:]]*[Dd][Cc]=//p' | paste -sd. - || true)"
    ask OPT_LDAP_DOMAIN  "Sign-in domain (the UPN suffix)" "$DERIVED_DOMAIN"
    ask OPT_LDAP_GROUP   "DN of the group allowed to sign in, e.g. CN=Kafka-Admins,OU=Groups,DC=example,DC=org"
    ask OPT_LDAP_BIND_DN "Service-account DN for searches (blank: bind as each user)"
    MISSING_OPTS=""
    [[ -n "$OPT_LDAP_URL" ]]     || MISSING_OPTS="${MISSING_OPTS} --ldap-url"
    [[ -n "$OPT_LDAP_BASE_DN" ]] || MISSING_OPTS="${MISSING_OPTS} --ldap-base-dn"
    [[ -n "$OPT_LDAP_DOMAIN" ]]  || MISSING_OPTS="${MISSING_OPTS} --ldap-domain"
    [[ -n "$OPT_LDAP_GROUP" ]]   || MISSING_OPTS="${MISSING_OPTS} --ldap-group"
    [[ -z "$MISSING_OPTS" ]] || die "Cannot write ${CONFIG_FILE}: no value for${MISSING_OPTS}.
     There is no built-in directory. Pass them as flags (see --help) or run
     on a terminal to be asked. Nothing has been installed."
    [[ "${OPT_LDAP_URL,,}" =~ ^ldaps://[A-Za-z0-9._-]+(:[0-9]{1,5})?/?$ ]] \
        || die "--ldap-url must be ldaps://<host>[:<port>] (plain ldap:// is not supported): '${OPT_LDAP_URL}'"
    [[ -z "$OPT_LDAP_CA_CERT" || -f "$OPT_LDAP_CA_CERT" ]] \
        || die "--ldap-ca-cert ${OPT_LDAP_CA_CERT}: no such file."
    # The service-account password: environment or a silent prompt, never argv.
    LDAP_BIND_PW="${TM_LDAP_BIND_PASSWORD:-}"
    if [[ -n "$OPT_LDAP_BIND_DN" && -z "$LDAP_BIND_PW" && $NON_INTERACTIVE != true && -t 0 ]]; then
        read -r -s -p "  Password for ${OPT_LDAP_BIND_DN} (not echoed): " LDAP_BIND_PW || true
        echo
    fi
    if [[ -n "$OPT_LDAP_BIND_DN" && -z "$LDAP_BIND_PW" ]]; then
        warn "No password for the service account: config.yaml keeps the CHANGE_ME"
        warn "  placeholder, so sign-in binds as each user until auth.ldap_bind_password is set."
    fi
    success "Directory: ${OPT_LDAP_URL} (base ${OPT_LDAP_BASE_DN}, domain ${OPT_LDAP_DOMAIN})"
fi

# ─── an existing config.yaml must name its directory ─────────────────────────
# Checked BEFORE ANYTHING IS CHANGED (round 2, adversary F3: it used to run
# after apt, the venv and pip had already touched the host, while saying
# "nothing was changed"). v1.1.0 has no built-in directory defaults, and a
# reinstall over a host whose config.yaml relied on them would otherwise lock
# every user out the moment a worker restarted. The interpreter is whichever
# of the existing venv and the system python3 can import PyYAML; if neither
# can, the run stops here rather than guess.
if [[ $NEW_CONFIG != true ]]; then
    CHECK_PY=""
    for cand in "${VENV}/bin/python3" python3; do
        if "$cand" -c "import yaml" >/dev/null 2>&1; then CHECK_PY="$cand"; break; fi
    done
    [[ -n "$CHECK_PY" ]] || die "Cannot check ${CONFIG_FILE} before changing anything: neither
     ${VENV}/bin/python3 nor python3 can import yaml. Install python3-yaml and
     run again. Nothing has been changed."
    LDAP_MISSING="$(ldap_config_missing "$CHECK_PY" "$CONFIG_FILE")"
    case "$LDAP_MISSING" in
        "") success "config.yaml names its directory (ldap_server, ldap_base_dn, ldap_domain)" ;;
        ERROR:*) die "Could not read ${CONFIG_FILE} to check its directory settings (${LDAP_MISSING#ERROR:}).
     Fix the file and run again. Nothing has been changed." ;;
        *) die "${CONFIG_FILE} has no usable value for: ${LDAP_MISSING}
     Releases before 1.1.0 filled these in from built-in defaults that belonged
     to one particular site; 1.1.0 has none (and ldap_server must be ldaps://),
     so this install would lock every user out. Add the keys under auth: with
     YOUR directory's values, e.g.
       ldap_server:  \"ldaps://dc1.example.org:636\"
       ldap_base_dn: \"DC=example,DC=org\"
       ldap_domain:  \"example.org\"
     then run again. Nothing has been changed." ;;
    esac
fi

# ─── system dependencies ─────────────────────────────────────────────────────
# Runtime packages only. No compiler and no -dev headers: every Python
# dependency is installed from a binary wheel (pip --only-binary :all:), which
# is also what the offline bundle carries, so a STIG'd host never needs a
# toolchain. polkitd is what lets the Settings restart control act.
REQUIRED_PKGS=(python3 python3-venv nginx polkitd rsync sudo curl ca-certificates openssl)
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
MISSING_PKGS=()
for p in "${REQUIRED_PKGS[@]}"; do pkg_installed "$p" || MISSING_PKGS+=("$p"); done
info "Installing system dependencies..."
if [[ ${#MISSING_PKGS[@]} -eq 0 ]]; then
    success "All required packages already installed"
elif [[ $ONLINE == true ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING_PKGS[@]}"
else
    apt_install_from_bundle "${SCRIPT_DIR}/install/packages/apt" "${MISSING_PKGS[@]}"
fi
for p in "${REQUIRED_PKGS[@]}"; do
    pkg_installed "$p" || die "Required package ${p} is still not installed."
done
success "System dependencies ready"

# ─── Python version check ────────────────────────────────────────────────────
PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" \
    || die "Python ${REQUIRED_PYTHON_VERSION}+ required (found ${PY_VER})"
success "Python ${PY_VER} OK"

# ─── system user ─────────────────────────────────────────────────────────────
if ! id "$APP_USER" &>/dev/null; then
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$APP_USER"
    success "Created system user: ${APP_USER}"
fi

# ─── directories ─────────────────────────────────────────────────────────────
info "Creating application directories..."
safe_install_dir 750 "$APP_USER" "$APP_USER" "$APP_HOME"
safe_install_dir 750 "$APP_USER" "$APP_USER" "$LOG_DIR"
# 0700, not 0750 (v1.1.0): it holds the audit database. enforce_audit_db_modes
# below is the authority for it and for tm.db.
safe_install_dir 700 "$APP_USER" "$APP_USER" "$DATA_DIR"
safe_install_dir 755 root root "$FRONTEND_DIR"
# root:${APP_USER} 0750 — the app can traverse and READ config.yaml, and
# can create nothing here. Not root:root, which would stop it reading its
# own configuration; not group-writable, which is what would let it unlink
# config.yaml.
safe_install_dir 750 root "$APP_USER" "$CONFIG_DIR"
safe_install_dir 750 root "$APP_USER" "${CONFIG_DIR}/tls"
# The app owns this subdirectory and ONLY this. Atomic replace needs to
# create a temp file beside the target, which needs directory write.
safe_install_dir 750 "$APP_USER" "$APP_USER" "$CLUSTERS_DIR"
# Uploaded Kafka TLS material. 0700: nothing but the service reads it, and
# it is already inside the unit ReadWritePaths.
safe_install_dir 700 "$APP_USER" "$APP_USER" "$CERT_DIR"
# Restore points. root-only: they hold config.yaml verbatim.
safe_install_dir 700 root root "$BACKUP_ROOT"
success "Directories created"

# ─── Python venv + packages ──────────────────────────────────────────────────
info "Setting up Python virtual environment..."
"$PYTHON" -m venv "$VENV"
source "${VENV}/bin/activate"

# HASH-LOCKED, BINARY WHEELS ONLY (round 2): requirements.lock pins every
# package including transitive ones, with the SHA-256 of every wheel PyPI
# publishes for it, and pip refuses any file not on that list — from PyPI, a
# mirror or the bundle alike. Nothing is compiled on the host. pip itself is
# NOT self-upgraded (online or off): an unhashed download of the installer
# would sit outside the lock, and offline it was a hard failure.
LOCK_FILE="${SCRIPT_DIR}/requirements.lock"
[[ -f "$LOCK_FILE" ]] || die "${LOCK_FILE} not found — it is what the Python packages are verified against."
if [[ $ONLINE == true ]]; then
    info "Installing Python packages from PyPI (hash-locked)..."
    pip install --require-hashes --only-binary :all: -r "$LOCK_FILE" --quiet \
        || die "pip install from requirements.lock failed (a hash mismatch is refused, not retried)."
else
    PY_PKG_DIR="${SCRIPT_DIR}/install/packages/python"
    if [[ -d "$PY_PKG_DIR" ]]; then
        info "Installing Python packages from offline cache (hash-locked)..."
        pip install --no-index --require-hashes --only-binary :all: --find-links="$PY_PKG_DIR" \
            -r "$LOCK_FILE" --quiet \
            || die "pip install from the bundle failed (a hash mismatch is refused, not retried)."
    else
        die "Offline Python packages not found at ${PY_PKG_DIR}. Run prepare-offline.sh first."
    fi
fi
deactivate
success "Python environment ready"

# ─── backend ─────────────────────────────────────────────────────────────────
# A reinstall stops the running service first (round 2, sec-review): the
# audit database is re-moded below, and a live service could create or swap a
# -wal file between the check and the change.
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    info "Stopping ${SERVICE_NAME} for the reinstall (it is started again at the end) ..."
    systemctl stop "${SERVICE_NAME}"
fi
info "Installing backend (tm/)..."
rsync -a --delete "${SCRIPT_DIR}/tm/" "${APP_HOME}/tm/"
chown -R "$APP_USER:$APP_USER" "${APP_HOME}/tm"
chown -R "$APP_USER:$APP_USER" "$LOG_DIR" "$DATA_DIR"
# A reinstall over a v1.0.x host finds tm.db at 0644 and data/ at 0750.
enforce_audit_db_modes
# WSGI entry point
cat > "${APP_HOME}/wsgi.py" <<'WSGI'
from tm.app import create_app
application = create_app()
WSGI
chown "$APP_USER:$APP_USER" "${APP_HOME}/wsgi.py"
success "Backend installed"

# ─── frontend lib: Vue.js ────────────────────────────────────────────────────
# Version AND hash come from install/upgrade-full.sh — the single pin, same as
# prepare-offline.sh reads. A version in a URL is not an integrity control:
# until 2026-08-30 this fetched whatever the CDN returned and served it as the
# framework rendering every authenticated page, with no SRI, checksum or
# signature. The fresh-install path is now held to the same standard as upgrade.
UPGRADE_SH="${SCRIPT_DIR}/install/upgrade-full.sh"
[[ -f "$UPGRADE_SH" ]] || die "${UPGRADE_SH} not found — it holds the Vue version and hash pin."
VUE_VERSION="$(sed -n 's/^VUE_VERSION="\([^"]*\)".*/\1/p' "$UPGRADE_SH" | head -1)"
VUE_SHA256="$(sed -n 's/^VUE_SHA256="\([^"]*\)".*/\1/p' "$UPGRADE_SH" | head -1)"
[[ -n "$VUE_VERSION" && -n "$VUE_SHA256" ]] \
    || die "Could not read VUE_VERSION/VUE_SHA256 from ${UPGRADE_SH}."
VUE_URL="https://cdn.jsdelivr.net/npm/vue@${VUE_VERSION}/dist/vue.global.prod.js"
VUE_DEST="${SCRIPT_DIR}/lib/vue.global.prod.js"

vue_sha256() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

if [[ -f "$VUE_DEST" ]]; then
    # A pre-existing file (offline bundle, or a previous run) is NOT trusted
    # just because it is present — verify it or refuse.
    GOT="$(vue_sha256 "$VUE_DEST")"
    [[ "$GOT" == "$VUE_SHA256" ]] \
        || die "Existing ${VUE_DEST} FAILED its integrity check.
     Expected ${VUE_SHA256}
     Got      ${GOT}
     Delete it and re-run, or rebuild the bundle with prepare-offline.sh."
    success "Vue.js ${VUE_VERSION} already present (sha256 verified)"
elif [[ $ONLINE == true ]]; then
    info "Downloading Vue.js ${VUE_VERSION}..."
    mkdir -p "${SCRIPT_DIR}/lib"
    TMP_VUE="$(mktemp)"
    curl -fsSL --max-time 30 "$VUE_URL" -o "$TMP_VUE" \
        || { rm -f "$TMP_VUE"; die "Failed to download Vue.js from CDN. For offline install, run prepare-offline.sh first."; }
    GOT="$(vue_sha256 "$TMP_VUE")"
    if [[ "$GOT" != "$VUE_SHA256" ]]; then
        rm -f "$TMP_VUE"
        die "Vue integrity check FAILED. Expected ${VUE_SHA256}, got ${GOT}.
     Refusing to install an unverified script as the application's framework."
    fi
    mv "$TMP_VUE" "$VUE_DEST"
    success "Vue.js ${VUE_VERSION} downloaded (sha256 verified)"
else
    die "lib/vue.global.prod.js is missing. Run prepare-offline.sh on an internet host first, then transfer the bundle."
fi

# ─── frontend ────────────────────────────────────────────────────────────────
info "Installing frontend..."
rsync -a --delete \
    "${SCRIPT_DIR}/index.html" \
    "${SCRIPT_DIR}/app" \
    "${SCRIPT_DIR}/lib" \
    "$FRONTEND_DIR/"

# Image assets. These were NOT copied before 2026-09-01, so a FRESH install had
# no favicon, no login wordmark and no header mark — index.html and LoginView
# reference them by absolute path, so they 404'd. Upgraded hosts looked fine
# because upgrade-full.sh copies them, which is exactly why the gap survived.
for asset in jarvis-favicon.ico jarvis-glyph-32.png jarvis-logo.png jarvis-mark.png; do
    if [[ -f "${SCRIPT_DIR}/${asset}" ]]; then
        install -m 644 "${SCRIPT_DIR}/${asset}" "${FRONTEND_DIR}/${asset}"
    else
        warn "asset missing from the source tree: ${asset}"
    fi
done
normalise_frontend_install "$FRONTEND_DIR"
success "Frontend installed at ${FRONTEND_DIR} (root:root, 0755/0644)"

# ─── config ──────────────────────────────────────────────────────────────────
if [[ $NEW_CONFIG == true ]]; then
    info "Writing ${CONFIG_DIR}/config.yaml ..."
    # install(1), not cp+chmod: cp under umask 077 lands the file 0600 and
    # the following chmod races the window in between. install(1) creates it
    # with the final owner and mode in one step.
    install -m 640 -o root -g "$APP_USER" \
        "${SCRIPT_DIR}/config/config.yaml.example" "${CONFIG_DIR}/config.yaml"

    # Generate a random secret key
    # ...and fill in the directory settings. Rewritten IN PLACE (same inode), so the owner and mode install(1) set
    # hold throughout. Values arrive through the environment, never argv, and
    # are written as JSON strings, which are valid YAML double-quoted scalars
    # whatever characters a DN contains. secrets.token_hex draws on the kernel
    # CSPRNG (os.urandom), which is the approved DRBG on a FIPS host.
    if ! TM_I_LDAP_SERVER="$OPT_LDAP_URL" TM_I_LDAP_BASE_DN="$OPT_LDAP_BASE_DN" \
         TM_I_LDAP_DOMAIN="$OPT_LDAP_DOMAIN" TM_I_REQUIRED_GROUP="$OPT_LDAP_GROUP" \
         TM_I_LDAP_BIND_DN="$OPT_LDAP_BIND_DN" TM_I_LDAP_CA_CERT="$OPT_LDAP_CA_CERT" \
         TM_I_LDAP_BIND_PW="$LDAP_BIND_PW" \
         "${VENV}/bin/python3" - "${CONFIG_DIR}/config.yaml" <<'PYCFG'
import json, os, re, secrets, sys
import yaml

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
values = {
    "ldap_server":    os.environ["TM_I_LDAP_SERVER"],
    "ldap_base_dn":   os.environ["TM_I_LDAP_BASE_DN"],
    "ldap_domain":    os.environ["TM_I_LDAP_DOMAIN"],
    "required_group": os.environ["TM_I_REQUIRED_GROUP"],
    "ldap_bind_dn":   os.environ.get("TM_I_LDAP_BIND_DN", ""),
    "ldap_ca_cert":   os.environ.get("TM_I_LDAP_CA_CERT", ""),
}
if os.environ.get("TM_I_LDAP_BIND_PW"):
    values["ldap_bind_password"] = os.environ["TM_I_LDAP_BIND_PW"]
for key, value in values.items():
    pattern = re.compile(r'^(  ' + re.escape(key) + r':[ \t]*)"[^"\n]*"', re.M)
    text, n = pattern.subn(lambda m: m.group(1) + json.dumps(value), text)
    if n != 1:
        sys.exit("config template: auth.%s matched %d lines, expected 1" % (key, n))
text, n = re.subn(r"CHANGE_ME_GENERATE_A_RANDOM_SECRET", secrets.token_hex(32), text)
if n != 1:
    sys.exit("config template: the secret_key placeholder matched %d times" % n)
parsed = yaml.safe_load(text)
for key, value in values.items():
    if parsed["auth"].get(key) != value:
        sys.exit("config template: auth.%s did not round-trip" % key)
with open(path, "r+", encoding="utf-8") as fh:
    fh.seek(0)
    fh.write(text)
    fh.truncate()
PYCFG
    then
        rm -f "${CONFIG_DIR}/config.yaml"
        die "Could not write config.yaml (see above); it was removed so a re-run starts clean."
    fi

    success "Config written to ${CONFIG_DIR}/config.yaml (0640 root:${APP_USER}, new secret key)"
else
    info "Config already exists — not overwritten (its directory settings were checked above)."
fi

# ─── cluster profiles ───────────────────────────────────────────────────────
# A REINSTALL over an existing host finds a config.yaml that still carries
# the clusters: block, so this runs on install as well as on upgrade. It is
# the same module the upgrade calls, and it is idempotent. On a FRESH host it
# creates an EMPTY store (v1.1.0): config/clusters.yaml.example is a format
# reference, never imported as live clusters. Add them in Settings.
info "Preparing the cluster profile store in ${CLUSTERS_DIR} ..."
PYTHONPATH="$SCRIPT_DIR" "${VENV}/bin/python3" -m tm.migrate_clusters \
    --config "${CONFIG_DIR}/config.yaml" \
    --clusters-dir "$CLUSTERS_DIR" \
    || die "Cluster profile migration failed."
# The migration owns the DATA; permissions are set here, with install(1).
safe_install_dir 750 "$APP_USER" "$APP_USER" "$CLUSTERS_DIR"
chown "$APP_USER":"$APP_USER" "$CLUSTERS_FILE"
chmod 640 "$CLUSTERS_FILE"
success "Cluster profiles at ${CLUSTERS_FILE}"

# ─── systemd service ─────────────────────────────────────────────────────────
info "Installing systemd service..."
install -m 644 -o root -g root \
    "${SCRIPT_DIR}/systemd/topic-manager.service" \
    /etc/systemd/system/topic-manager.service
# The root-side `nginx -t` gate for the Settings restart control. Never
# enabled, only started on demand; the unit says why it has to be root.
install -m 644 -o root -g root \
    "${SCRIPT_DIR}/systemd/topic-manager-nginx-test.service" \
    /etc/systemd/system/topic-manager-nginx-test.service
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" --quiet
success "Service installed: ${SERVICE_NAME}"

# ─── polkit ─────────────────────────────────────────────────────────────────
# sudo cannot work under NoNewPrivileges=true (measured on prod), so the
# restart control authorises through polkit instead.
if [[ -d /etc/polkit-1/rules.d ]]; then
    info "Installing polkit rule for the service restart control..."
    install -m 644 -o root -g root \
        "${SCRIPT_DIR}/install/polkit/50-topic-manager.rules" \
        /etc/polkit-1/rules.d/50-topic-manager.rules
    success "polkit rule installed (restart self, reload nginx)"
else
    warn "/etc/polkit-1/rules.d does not exist — polkit is not installed."
    warn "  The Settings restart control would report 'Interactive authentication required'."
    warn "  Install polkitd, then re-run this script."
fi

# ─── nginx ───────────────────────────────────────────────────────────────────
info "Installing nginx site..."
mkdir -p /etc/nginx/snippets
cp "${SCRIPT_DIR}/nginx/tm-security-headers.conf" /etc/nginx/snippets/tm-security-headers.conf
install -m 644 -o root -g root "${SCRIPT_DIR}/nginx/topic-manager.conf" /etc/nginx/sites-available/topic-manager
# The shipped site carries a placeholder name, and only the placeholder is
# replaced.
sed -i "s|server_name YOUR-HOSTNAME.YOUR-DOMAIN.com _;|server_name ${SERVER_NAME} _;|" \
    /etc/nginx/sites-available/topic-manager
ln -sf /etc/nginx/sites-available/topic-manager /etc/nginx/sites-enabled/topic-manager
rm -f /etc/nginx/sites-enabled/default
success "nginx site configured for ${SERVER_NAME}"

# ─── TLS certificate ─────────────────────────────────────────────────────────
# v1.1.0: nginx cannot start without a certificate, so a fresh install used to
# end with a failing `nginx -t` and a warning. Now, in order of preference:
#   1. --tls-cert/--tls-key given: installed, and verified to be a pair;
#   2. a certificate already present: kept;
#   3. otherwise a SELF-SIGNED placeholder, ECDSA P-256 / SHA-256 (FIPS-approved),
#      loudly reported. Replace it with one your CA issued before production use.
# The private key is 0600 root:root: nginx's master process (root) reads it,
# and nothing else needs to.
TLS_CRT="${CONFIG_DIR}/tls/server.crt"
TLS_KEY="${CONFIG_DIR}/tls/server.key"
if [[ -n "$OPT_TLS_CERT" || -n "$OPT_TLS_KEY" ]]; then
    [[ -f "$OPT_TLS_CERT" && -f "$OPT_TLS_KEY" ]] \
        || die "--tls-cert and --tls-key must both name existing files."
    tls_keypair_matches "$OPT_TLS_CERT" "$OPT_TLS_KEY" \
        || die "--tls-cert and --tls-key are not a matching certificate/key pair
     (or one of them could not be read). Nothing was installed."
    install -m 644 -o root -g root "$OPT_TLS_CERT" "$TLS_CRT"
    install -m 600 -o root -g root "$OPT_TLS_KEY"  "$TLS_KEY"
    success "TLS certificate installed from ${OPT_TLS_CERT} (key pair verified)"
elif [[ -f "$TLS_CRT" && -f "$TLS_KEY" ]]; then
    # A KEPT key is held to the same rule as a new one (round 2): 0600
    # root:root. Never through a symlink.
    [[ -L "$TLS_KEY" ]] && die "${TLS_KEY} is a symlink; refusing to chown or chmod through it."
    chown root:root "$TLS_KEY"; chmod 600 "$TLS_KEY"
    tls_keypair_matches "$TLS_CRT" "$TLS_KEY" \
        && success "Existing TLS certificate kept (key pair verified)" \
        || warn "Existing ${TLS_CRT} and ${TLS_KEY} do NOT verify as a pair — nginx -t below will say more."
else
    info "No TLS certificate supplied — generating a self-signed placeholder for ${SERVER_NAME} ..."
    TLS_TMP_KEY="$(mktemp "${CONFIG_DIR}/tls/.key.XXXXXX")"
    openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -nodes \
        -days 397 -subj "/CN=${SERVER_NAME}" \
        -addext "subjectAltName=DNS:${SERVER_NAME}" \
        -keyout "$TLS_TMP_KEY" -out "$TLS_CRT" >/dev/null 2>&1 \
        || { rm -f "$TLS_TMP_KEY"; die "openssl could not generate a self-signed certificate."; }
    chown root:root "$TLS_TMP_KEY" "$TLS_CRT"
    chmod 600 "$TLS_TMP_KEY"; chmod 644 "$TLS_CRT"
    mv -f "$TLS_TMP_KEY" "$TLS_KEY"
    warn "SELF-SIGNED certificate generated for ${SERVER_NAME} (ECDSA P-256, 397 days)."
    warn "  Browsers will warn. Replace ${TLS_CRT} and ${TLS_KEY} with a CA-issued"
    warn "  pair, then: sudo systemctl reload nginx"
fi

# ─── nginx.conf: TLS 1.2/1.3 only at the http level ──────────────────────────
# Stock Ubuntu's nginx.conf enables TLSv1 and TLSv1.1 for every server. Backed
# up to ${BACKUP_ROOT}, edited, nginx -t'd, and put back if the test fails.
manage_nginx_ssl_protocols /etc/nginx/nginx.conf \
    "${BACKUP_ROOT}/nginx.conf.before-install-$(date +%Y%m%d-%H%M%S)"

# ─── firewall ────────────────────────────────────────────────────────────────
# open_firewall_ports — open 80/tcp and 443/tcp when ufw is ACTIVE.
# Round 5, MEASURED on the real STIG + FIPS host (every STIG host has ufw
# active): the old `ufw --quiet allow 80/tcp` failed with "ERROR: Invalid
# syntax" — ufw has NO --quiet option — and killed the install at its last
# step. Output is discarded by redirection instead, and each rule's exit code
# is checked: a rule that fails is a loud warning naming the command to run,
# never a "ports open" claim. Not fatal: everything else is installed by now.
# The status is read whole and matched in-shell, not piped to grep -q, which
# under pipefail can SIGPIPE ufw and read an active firewall as inactive.
open_firewall_ports() {
    local port out failed="" st
    command -v ufw >/dev/null 2>&1 || return 0
    st="$(ufw status 2>/dev/null || true)"
    [[ "$st" == *"Status: active"* ]] || return 0
    info "Opening firewall ports 80 and 443..."
    for port in 80/tcp 443/tcp; do
        out="$(ufw allow "$port" 2>&1)" || failed="${failed} ${port} (${out%%$'\n'*})"
    done
    if [[ -z "$failed" ]]; then
        success "Firewall ports 80/443 open"
    else
        warn "ufw is active but could NOT open:${failed}"
        warn "  The site is unreachable until you run: sudo ufw allow 80/tcp; sudo ufw allow 443/tcp"
    fi
}
open_firewall_ports

# ─── logrotate ───────────────────────────────────────────────────────────────
info "Installing logrotate config..."
cp "${SCRIPT_DIR}/install/logrotate.d/topic-manager" /etc/logrotate.d/topic-manager
success "Log rotation configured (daily, 14-day retention)"

# ─── nginx test ──────────────────────────────────────────────────────────────
# A fresh install now always has a certificate, so a failing test is a real
# fault, not an expected gap — stop, and show nginx's own words.
NGINX_T="$(nginx -t 2>&1)" || die "nginx -t failed:
${NGINX_T}"
success "nginx config valid"

# ─── permission boundary ────────────────────────────────────────────────────
# ASKED OF THE KERNEL as the real principal. Mode bits can look right while an
# ACL or a parent directory still says otherwise, and this is the boundary the
# whole clusters.d design exists to hold: the app writes its own directory and
# cannot touch the file that holds secret_key, ldap_bind_password and
# required_group.
#
# The upgrade script has asked these five questions since v1.0.4. install.sh
# asked none of them, so the REINSTALL path — the one that runs over an
# existing host and re-applies every mode — could put the boundary back wrong
# and report a successful install.
command -v sudo >/dev/null 2>&1 \
    || die "sudo is not installed, so the permission boundary cannot be verified as
     ${APP_USER}. Install sudo and re-run: an unverified boundary is not a
     verified one, and this script will not claim it."
can_access "$APP_USER" -r "$CLUSTERS_FILE" \
    || die "${APP_USER} cannot READ ${CLUSTERS_FILE} — every cluster view would fail."
can_access "$APP_USER" -w "$CLUSTERS_DIR" \
    || die "${APP_USER} cannot WRITE ${CLUSTERS_DIR} — the Cluster Builder could not save."
can_access "$APP_USER" -r "$CONFIG_FILE" \
    || die "${APP_USER} cannot read config.yaml — the service would not start."
if can_access "$APP_USER" -w "$CONFIG_FILE"; then
    die "${APP_USER} can WRITE ${CONFIG_FILE}. The application must never be able
     to modify the file holding secret_key and ldap_bind_password.
     Fix: sudo chown root:${APP_USER} ${CONFIG_FILE}; sudo chmod 640 ${CONFIG_FILE}"
fi
if can_access "$APP_USER" -w "$CONFIG_DIR"; then
    die "${APP_USER} can WRITE ${CONFIG_DIR}. Directory write is UNLINK: the
     application could delete config.yaml and write its own, choosing its
     own required_group, then restart the service.
     Fix: sudo chown root:${APP_USER} ${CONFIG_DIR}; sudo chmod 750 ${CONFIG_DIR}"
fi
success "Permission boundary verified: the app owns clusters.d and cannot write config.yaml"

# ─── start and verify ───────────────────────────────────────────────────────
# The end state is a RUNNING service, measured — not a list of next steps. The
# config is complete (the directory settings were supplied or checked above)
# and nginx has a certificate, so there is nothing left for an operator to
# fill in before it can start.
info "Starting ${SERVICE_NAME} and nginx ..."
systemctl restart "${SERVICE_NAME}"
systemctl enable nginx --quiet
systemctl reload-or-restart nginx
HEALTH=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 2
    HEALTH="$(curl -sk --max-time 5 https://localhost/api/health 2>/dev/null || true)"
    grep -q '"ok"' <<<"$HEALTH" && break
done
grep -q '"ok"' <<<"$HEALTH" \
    || die "${SERVICE_NAME} did not answer /api/health: ${HEALTH:-no response}
     See: sudo journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
success "Health: ${HEALTH}"
# The service has started, so tm.db now exists — created by tm/models.py under
# UMask=0077. Measured, not assumed.
DB_STATE="$(stat -c '%a %U' "${DATA_DIR}/tm.db" 2>/dev/null || echo missing)"
[[ "$DB_STATE" == "600 ${APP_USER}" ]] \
    || die "${DATA_DIR}/tm.db is '${DB_STATE}', expected '600 ${APP_USER}'."
DIR_STATE="$(stat -c '%a %U' "$DATA_DIR" 2>/dev/null || echo missing)"
[[ "$DIR_STATE" == "700 ${APP_USER}" ]] \
    || die "${DATA_DIR} is '${DIR_STATE}', expected '700 ${APP_USER}'."
success "Audit database private: tm.db 0600, data/ 0700, owned by ${APP_USER}"

# ─── summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Jarvis Topic Manager install complete — running.${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo "  URL:      https://${SERVER_NAME}/"
echo "  Config:   ${CONFIG_DIR}/config.yaml"
echo "  Next steps:"
echo "  1. Sign in with a member of the required group, then add the Kafka"
echo "     clusters in Settings > General > Cluster Profiles (a new install"
echo "     starts with none)."
if [[ -z "$OPT_TLS_CERT" ]] && openssl x509 -in "$TLS_CRT" -noout -issuer -subject 2>/dev/null \
        | awk -F'= ' '/^issuer/{i=$2} /^subject/{s=$2} END{exit !(i==s)}'; then
echo "  2. The TLS certificate is SELF-SIGNED. Replace ${TLS_CRT} and"
echo "     ${TLS_KEY} with a CA-issued pair, then: sudo systemctl reload nginx"
fi
echo ""
echo "  Logs:  journalctl -u ${SERVICE_NAME} -f"
echo "         tail -f ${LOG_DIR}/error.log"
echo ""
