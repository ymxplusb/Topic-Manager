#!/usr/bin/env bash
# =============================================================================
# Jarvis Topic Manager — Prepare Offline Bundle
# Version: 1.0.6
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
#
# Run this on an INTERNET-CONNECTED machine (Linux/Mac/WSL) to download
# all required packages for an air-gapped install.
#
# Usage:
#   bash prepare-offline.sh [--bundle]
#   --bundle  Also creates topic-manager-offline-<version>.tar.gz
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(cat "${SCRIPT_DIR}/VERSION" | tr -d '[:space:]')
PY_PKG_DIR="${SCRIPT_DIR}/install/packages/python"
APT_PKG_DIR="${SCRIPT_DIR}/install/packages/apt"
LIB_DIR="${SCRIPT_DIR}/lib"
CREATE_BUNDLE=false
[[ "${1:-}" == "--bundle" ]] && CREATE_BUNDLE=true

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# This script is documented as running on Linux/Mac/WSL, and macOS has no
# sha256sum — ask for the digest by name, not by assuming coreutils.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        die "Neither sha256sum nor shasum is available — cannot verify the Vue bundle."
    fi
}

mkdir -p "$PY_PKG_DIR" "$APT_PKG_DIR" "$LIB_DIR"

# ─── Python wheels ───────────────────────────────────────────────────────────
# requirements.txt is the single source of truth for the Python pins, and
# install/upgrade-full.sh installs from that same file on the target host. Do
# not pin a version anywhere in this script.
REQ_FILE="${SCRIPT_DIR}/requirements.txt"
[[ -f "$REQ_FILE" ]] || die "${REQ_FILE} not found — it is the source of every Python pin."

info "Downloading Python wheels to ${PY_PKG_DIR}..."
pip download \
    --dest "$PY_PKG_DIR" \
    --platform manylinux2014_x86_64 \
    --python-version 3.12 \
    --implementation cp \
    --abi cp312 \
    --only-binary :all: \
    -r "$REQ_FILE" 2>/dev/null || \
pip download \
    --dest "$PY_PKG_DIR" \
    -r "$REQ_FILE"
ok "Python wheels saved"

# A bundle that is missing a pinned version fails on the air-gapped host, where
# there is no way to fetch the missing wheel. Find that out here, with a network.
info "Verifying every pin in requirements.txt is present in the bundle..."
# Accumulated as a string, not an array: macOS still ships bash 3.2, where
# ${#arr[@]} on an empty array is an unbound-variable error under set -u.
MISSING=""
shopt -s nullglob
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    [[ "$line" == *'=='* ]] || die "requirements.txt: '${line}' is not an exact == pin."
    PKG="${line%%==*}"; VER="${line##*==}"
    PAT="$(printf '%s' "$PKG" | tr '[:upper:]' '[:lower:]')"; PAT="${PAT//_/-}"
    FOUND=false
    for f in "$PY_PKG_DIR"/*; do
        NORM="$(printf '%s' "$(basename "$f")" | tr '[:upper:]' '[:lower:]')"; NORM="${NORM//_/-}"
        if [[ "$NORM" == "${PAT}-${VER}-"* || "$NORM" == "${PAT}-${VER}.tar.gz" ]]; then
            FOUND=true; break
        fi
    done
    [[ $FOUND == true ]] || MISSING="${MISSING} ${PKG}==${VER}"
done < "$REQ_FILE"
shopt -u nullglob
[[ -z "${MISSING// /}" ]] \
    || die "The bundle does not contain:${MISSING}
     pip resolved something else for these, so an air-gapped install would fail
     at pip install --no-index. Fix the pin or the download platform and re-run."
ok "Bundle matches requirements.txt"

# ─── Vue.js 3 (CDN file for offline frontend) ────────────────────────────────
# The version AND the content hash are read from install/upgrade-full.sh, which
# is the script that verifies this file on the target host. Keeping a second
# copy of the pin here is exactly how the offline path broke: this script
# fetched 3.5.35 and prepended a comment line, so the bundled bytes could never
# match the hash upgrade-full.sh checks and every --offline run aborted at
# "Bundled Vue hash mismatch". Fetch what the installer verifies, byte for byte,
# and prepend nothing.
info "Downloading Vue.js 3..."
UPGRADE_SH="${SCRIPT_DIR}/install/upgrade-full.sh"
[[ -f "$UPGRADE_SH" ]] || die "${UPGRADE_SH} not found — it holds the Vue version and hash pin."
VUE_VER="$(sed -n 's/^VUE_VERSION="\([^"]*\)".*/\1/p' "$UPGRADE_SH" | head -1)"
VUE_SHA256="$(sed -n 's/^VUE_SHA256="\([^"]*\)".*/\1/p' "$UPGRADE_SH" | head -1)"
[[ -n "$VUE_VER" && -n "$VUE_SHA256" ]] \
    || die "Could not read VUE_VERSION/VUE_SHA256 from ${UPGRADE_SH}."
VUE_URL="https://cdn.jsdelivr.net/npm/vue@${VUE_VER}/dist/vue.global.prod.js"
curl -fsSL "$VUE_URL" -o "${LIB_DIR}/vue.global.prod.js"
GOT="$(sha256_of "${LIB_DIR}/vue.global.prod.js")"
if [[ "$GOT" != "$VUE_SHA256" ]]; then
    rm -f "${LIB_DIR}/vue.global.prod.js"
    die "Vue integrity check FAILED. Expected ${VUE_SHA256}, got ${GOT}.
     The bundle is not being written — upgrade-full.sh would refuse this file anyway."
fi
ok "Vue.js ${VUE_VER} saved to lib/ (sha256 verified against upgrade-full.sh)"

# ─── apt packages (Ubuntu 24.04) ─────────────────────────────────────────────
# The runtime packages install.sh requires, WITH their dependency closure, so
# an air-gapped host that lacks one of them can install it from the bundle.
# install.sh installs only the .debs for packages the host does not already
# have, so nothing here can downgrade it. Must run on Ubuntu 24.04 of the
# target's architecture. No compiler or -dev headers: every Python dependency
# is a binary wheel.
info "Downloading apt packages and their dependencies (requires an Ubuntu 24.04 host)..."
PKGS="python3 python3-venv nginx polkitd rsync sudo curl ca-certificates openssl"
if command -v apt-get &>/dev/null && command -v apt-cache &>/dev/null; then
    CLOSURE="$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
                 --no-breaks --no-replaces --no-enhances $PKGS 2>/dev/null \
               | grep -E '^[a-z0-9]' | sort -u || true)"
    GOT=0; MISSED=0
    for p in $CLOSURE; do
        if ( cd "$APT_PKG_DIR" && apt-get download "$p" >/dev/null 2>&1 ); then
            GOT=$((GOT+1))
        else
            MISSED=$((MISSED+1))      # virtual packages have no .deb of their own
        fi
    done
    ok "apt packages: ${GOT} downloaded to ${APT_PKG_DIR} (${MISSED} virtual/unavailable skipped)"
else
    echo "  Skipping apt download — not running on Debian/Ubuntu."
    echo "  The target must then already have: ${PKGS}"
fi

# ─── optional bundle ─────────────────────────────────────────────────────────
# v1.1.0: built from the COMMITTED tree (git archive of HEAD), not a tarball of
# the working directory. The old tarball shipped whatever sat in the checkout:
# the agent contract (.claude/), the work orders (.work/) with production
# addresses, dated scan reports and any untracked file. .gitattributes
# export-ignores the internal records, and the finished bundle is scanned by
# tools/check-env-neutral.sh --bundle, which refuses it if anything internal
# or environment-specific got in. Outside a git checkout an explicit allowlist
# of the shipped paths is used instead.
if [[ $CREATE_BUNDLE == true ]]; then
    BUNDLE_NAME="topic-manager-offline-${VERSION}.tar.gz"
    OUT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
    TOP="topic-manager-${VERSION}"
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tm-bundle.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    mkdir -p "${STAGE}/${TOP}"
    info "Creating bundle: ${BUNDLE_NAME}..."
    if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
            echo "  NOTE: uncommitted changes to tracked files are NOT in the bundle —"
            echo "        it is built from HEAD ($(git -C "$SCRIPT_DIR" rev-parse --short HEAD))."
        fi
        git -C "$SCRIPT_DIR" archive --format=tar HEAD | tar -x -C "${STAGE}/${TOP}" \
            || die "git archive of HEAD failed."
    else
        for p in VERSION requirements.txt install.sh prepare-offline.sh index.html \
                 README.md CHANGELOG.md SBOM.md NOTICES.md PPSM.csv TROUBLESHOOTING.md \
                 jarvis-favicon.ico jarvis-glyph-32.png jarvis-logo.png jarvis-mark.png \
                 app tm config systemd nginx tools tests docs \
                 install/upgrade-full.sh install/README.md install/polkit install/logrotate.d; do
            [[ -e "${SCRIPT_DIR}/${p}" ]] || continue
            mkdir -p "${STAGE}/${TOP}/$(dirname "$p")"
            cp -a "${SCRIPT_DIR}/${p}" "${STAGE}/${TOP}/${p}"
        done
        find "${STAGE}/${TOP}" -name __pycache__ -type d -prune -exec rm -rf {} +
    fi
    # The generated, untracked payload an air-gapped host needs.
    mkdir -p "${STAGE}/${TOP}/lib" "${STAGE}/${TOP}/install/packages"
    cp -a "${LIB_DIR}/vue.global.prod.js" "${STAGE}/${TOP}/lib/"
    cp -a "$PY_PKG_DIR" "$APT_PKG_DIR" "${STAGE}/${TOP}/install/packages/"
    tar -czf "${OUT_DIR}/${BUNDLE_NAME}" -C "$STAGE" "$TOP" || die "could not write ${OUT_DIR}/${BUNDLE_NAME}"
    if ! bash "${SCRIPT_DIR}/tools/check-env-neutral.sh" --bundle "${OUT_DIR}/${BUNDLE_NAME}"; then
        rm -f "${OUT_DIR}/${BUNDLE_NAME}"
        die "The bundle failed the leak check above and was deleted. Nothing internal ships."
    fi
    ( cd "$OUT_DIR" && sha256_of "$BUNDLE_NAME" > "${BUNDLE_NAME}.sha256.tmp" \
        && printf '%s  %s\n' "$(cat "${BUNDLE_NAME}.sha256.tmp")" "$BUNDLE_NAME" > "${BUNDLE_NAME}.sha256" \
        && rm -f "${BUNDLE_NAME}.sha256.tmp" )
    ok "Bundle created: ${OUT_DIR}/${BUNDLE_NAME} (+ .sha256)"
fi

echo ""
echo -e "${GREEN}Offline preparation complete.${NC}"
echo "Transfer the bundle (and its .sha256) to the target host, then:"
echo ""
echo "  FRESH INSTALL:"
echo "    sha256sum -c topic-manager-offline-${VERSION}.tar.gz.sha256"
echo "    tar xzf topic-manager-offline-${VERSION}.tar.gz && cd topic-manager-${VERSION}"
echo "    sudo bash install.sh --ldap-url ldaps://<dc>:636 --ldap-base-dn <base-dn> \\"
echo "         --ldap-group <group-dn> [--server-name <fqdn>] [--tls-cert <crt> --tls-key <key>]"
echo "    (or run it on a terminal and answer the prompts)"
echo ""
echo "  UPGRADE an existing host — NOT install.sh, which rsync --deletes the"
echo "  deployed tree. The upgrade reads the bundle from one fixed path:"
echo "    sudo install -d -m 700 -o root -g root /var/lib/topic-manager/offline-src"
echo "    sudo tar xzf topic-manager-offline-${VERSION}.tar.gz \\"
echo "      -C /var/lib/topic-manager/offline-src --strip-components=1"
echo "    sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --offline"
echo ""
echo "  Full procedures: docs/INSTALL.md (fresh install) and README.md -> 'Offline (air-gapped) upgrade'"
echo ""
