#!/usr/bin/env bash
# =============================================================================
# Jarvis Topic Manager — Prepare Offline Bundle
# Version: 1.0.0
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

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }

mkdir -p "$PY_PKG_DIR" "$APT_PKG_DIR" "$LIB_DIR"

# ─── Python wheels ───────────────────────────────────────────────────────────
info "Downloading Python wheels to ${PY_PKG_DIR}..."
pip download \
    --dest "$PY_PKG_DIR" \
    --platform manylinux2014_x86_64 \
    --python-version 3.12 \
    --implementation cp \
    --abi cp312 \
    --only-binary :all: \
    -r "${SCRIPT_DIR}/requirements.txt" 2>/dev/null || \
pip download \
    --dest "$PY_PKG_DIR" \
    -r "${SCRIPT_DIR}/requirements.txt"
ok "Python wheels saved"

# ─── Vue.js 3 (CDN file for offline frontend) ────────────────────────────────
info "Downloading Vue.js 3..."
VUE_VER="3.5.13"
VUE_URL="https://cdn.jsdelivr.net/npm/vue@${VUE_VER}/dist/vue.global.prod.js"
curl -fsSL "$VUE_URL" -o "${LIB_DIR}/vue.global.prod.js"
# Prepend version comment
echo "/* Vue.js ${VUE_VER} — MIT License — vuejs.org */" | \
    cat - "${LIB_DIR}/vue.global.prod.js" > /tmp/vue.tmp && \
    mv /tmp/vue.tmp "${LIB_DIR}/vue.global.prod.js"
ok "Vue.js ${VUE_VER} saved to lib/"

# ─── apt packages (Ubuntu 24.04) ─────────────────────────────────────────────
info "Downloading apt packages (requires Ubuntu host or docker)..."
PKGS="python3 python3-venv python3-dev nginx build-essential libssl-dev libffi-dev libsasl2-dev"
if command -v apt-get &>/dev/null; then
    apt-get download $PKGS 2>/dev/null && mv ./*.deb "$APT_PKG_DIR/" 2>/dev/null || true
    ok "apt packages downloaded (where available)"
else
    echo "  Skipping apt download — not running on Debian/Ubuntu."
    echo "  On Ubuntu: cd ${APT_PKG_DIR} && apt-get download ${PKGS}"
fi

# ─── optional bundle ─────────────────────────────────────────────────────────
if [[ $CREATE_BUNDLE == true ]]; then
    BUNDLE_NAME="topic-manager-offline-${VERSION}.tar.gz"
    info "Creating bundle: ${BUNDLE_NAME}..."
    cd "${SCRIPT_DIR}/.."
    tar czf "${BUNDLE_NAME}" \
        --exclude='*.pyc' --exclude='__pycache__' \
        --exclude='.git' --exclude='.gitignore' \
        "$(basename "$SCRIPT_DIR")"
    ok "Bundle created: ${BUNDLE_NAME}"
fi

echo ""
echo -e "${GREEN}Offline preparation complete.${NC}"
echo "Transfer the repo (or bundle) to the target host and run:"
echo "  sudo bash install.sh"
echo ""
