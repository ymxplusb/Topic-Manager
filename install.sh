#!/usr/bin/env bash
# =============================================================================
# Jarvis Topic Manager — Install Script
# Version: 1.0.3
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
#
# Usage:
#   sudo bash install.sh
#
# The script auto-detects online vs offline mode.
# Online:  downloads packages from apt/PyPI.
# Offline: uses pre-downloaded packages in install/packages/ (run
#          prepare-offline.sh on an internet host first).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_USER="topic-manager"
APP_HOME="/opt/topic-manager"
FRONTEND_DIR="/var/www/topic-manager"
CONFIG_DIR="/etc/topic-manager"
LOG_DIR="${APP_HOME}/logs"
DATA_DIR="${APP_HOME}/data"
VENV="${APP_HOME}/venv"
SERVICE_NAME="topic-manager"
PYTHON="python3"
REQUIRED_PYTHON_VERSION="3.10"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ─── root check ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash install.sh"

# ─── online detection ────────────────────────────────────────────────────────
ONLINE=false
if curl -s --max-time 4 https://pypi.org > /dev/null 2>&1; then
    ONLINE=true
fi
info "Install mode: $( [[ $ONLINE == true ]] && echo 'ONLINE' || echo 'OFFLINE' )"

# ─── system dependencies ─────────────────────────────────────────────────────
info "Installing system dependencies..."
if [[ $ONLINE == true ]]; then
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        python3 python3-venv python3-dev \
        nginx \
        build-essential libssl-dev libffi-dev \
        libsasl2-dev libldap2-dev \
        curl git ca-certificates
else
    PKG_DIR="${SCRIPT_DIR}/install/packages/apt"
    if [[ -d "$PKG_DIR" ]]; then
        info "Installing from offline .deb cache..."
        dpkg -i "${PKG_DIR}"/*.deb 2>/dev/null || apt-get install -f -y
    else
        warn "No offline apt packages found at ${PKG_DIR}. System packages must already be installed."
    fi
fi
success "System dependencies ready"

# ─── Python version check ────────────────────────────────────────────────────
PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" \
    || die "Python ${REQUIRED_PYTHON_VERSION}+ required (found ${PY_VER})"
success "Python ${PY_VER} OK"

# ─── system user ─────────────────────────────────────────────────────────────
if ! id "$APP_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
    success "Created system user: ${APP_USER}"
fi

# ─── directories ─────────────────────────────────────────────────────────────
info "Creating application directories..."
install -d -m 750 -o "$APP_USER" -g "$APP_USER" \
    "$APP_HOME" "$LOG_DIR" "$DATA_DIR"
install -d -m 755 "$FRONTEND_DIR"
install -d -m 750 "$CONFIG_DIR"
install -d -m 750 "${CONFIG_DIR}/tls"
success "Directories created"

# ─── Python venv + packages ──────────────────────────────────────────────────
info "Setting up Python virtual environment..."
"$PYTHON" -m venv "$VENV"
source "${VENV}/bin/activate"

pip install --upgrade pip --quiet

if [[ $ONLINE == true ]]; then
    info "Installing Python packages from PyPI..."
    pip install -r "${SCRIPT_DIR}/requirements.txt" --quiet
else
    PY_PKG_DIR="${SCRIPT_DIR}/install/packages/python"
    if [[ -d "$PY_PKG_DIR" ]]; then
        info "Installing Python packages from offline cache..."
        pip install --no-index --find-links="$PY_PKG_DIR" \
            -r "${SCRIPT_DIR}/requirements.txt" --quiet
    else
        die "Offline Python packages not found at ${PY_PKG_DIR}. Run prepare-offline.sh first."
    fi
fi
deactivate
success "Python environment ready"

# ─── backend ─────────────────────────────────────────────────────────────────
info "Installing backend (tm/)..."
rsync -a --delete "${SCRIPT_DIR}/tm/" "${APP_HOME}/tm/"
chown -R "$APP_USER:$APP_USER" "${APP_HOME}/tm"
chown -R "$APP_USER:$APP_USER" "$LOG_DIR" "$DATA_DIR"
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
chown -R www-data:www-data "$FRONTEND_DIR"
success "Frontend installed at ${FRONTEND_DIR}"

# ─── config ──────────────────────────────────────────────────────────────────
if [[ ! -f "${CONFIG_DIR}/config.yaml" ]]; then
    info "Installing default config..."
    cp "${SCRIPT_DIR}/config/config.yaml.example" "${CONFIG_DIR}/config.yaml"
    chmod 640 "${CONFIG_DIR}/config.yaml"
    chown root:"$APP_USER" "${CONFIG_DIR}/config.yaml"

    # Generate a random secret key
    SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    sed -i "s/CHANGE_ME_GENERATE_A_RANDOM_SECRET/${SECRET}/" "${CONFIG_DIR}/config.yaml"

    warn "Config installed at ${CONFIG_DIR}/config.yaml"
    warn "  → Edit LDAP bind DN/password and cluster bootstrap_servers before starting."
else
    info "Config already exists — not overwritten."
fi

# ─── systemd service ─────────────────────────────────────────────────────────
info "Installing systemd service..."
cp "${SCRIPT_DIR}/systemd/topic-manager.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" --quiet
success "Service installed: ${SERVICE_NAME}"

# ─── nginx ───────────────────────────────────────────────────────────────────
info "Installing nginx site..."
mkdir -p /etc/nginx/snippets
cp "${SCRIPT_DIR}/nginx/tm-security-headers.conf" /etc/nginx/snippets/tm-security-headers.conf
cp "${SCRIPT_DIR}/nginx/topic-manager.conf" /etc/nginx/sites-available/topic-manager
ln -sf /etc/nginx/sites-available/topic-manager /etc/nginx/sites-enabled/topic-manager
rm -f /etc/nginx/sites-enabled/default
success "nginx site configured"

# ─── TLS cert placeholder ────────────────────────────────────────────────────
if [[ ! -f "${CONFIG_DIR}/tls/server.crt" ]]; then
    warn "TLS certificate not found at ${CONFIG_DIR}/tls/server.crt"
    warn "  Generate a self-signed cert for testing, or place your signed cert:"
    warn "    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \\"
    warn "      -keyout ${CONFIG_DIR}/tls/server.key \\"
    warn "      -out    ${CONFIG_DIR}/tls/server.crt \\"
    warn "      -subj '/CN=topic-manager.int.crypticlight.com'"
    warn "  Then: sudo systemctl restart nginx topic-manager"
fi

# ─── firewall ────────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    info "Opening firewall ports 80 and 443..."
    ufw --quiet allow 80/tcp
    ufw --quiet allow 443/tcp
    success "Firewall ports 80/443 open"
fi

# ─── logrotate ───────────────────────────────────────────────────────────────
info "Installing logrotate config..."
cp "${SCRIPT_DIR}/install/logrotate.d/topic-manager" /etc/logrotate.d/topic-manager
success "Log rotation configured (daily, 14-day retention)"

# ─── nginx test ──────────────────────────────────────────────────────────────
nginx -t 2>/dev/null && success "nginx config valid" || warn "nginx config test failed — check cert paths"

# ─── summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Jarvis Topic Manager install complete.${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Next steps:"
echo "  1. Edit config:  sudo nano ${CONFIG_DIR}/config.yaml"
echo "  2. Place TLS cert at ${CONFIG_DIR}/tls/server.crt (.key)"
echo "  3. Start services:"
echo "       sudo systemctl start ${SERVICE_NAME}"
echo "       sudo systemctl restart nginx"
echo "  4. Verify:  curl -sk https://localhost/api/health"
echo ""
echo "  Logs:  journalctl -u ${SERVICE_NAME} -f"
echo "         tail -f ${LOG_DIR}/error.log"
echo ""
