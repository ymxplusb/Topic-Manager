#!/usr/bin/env bash
# =============================================================================
# Jarvis Topic Manager — Install Script
# Version: 1.0.6
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

# can_access <user> <test-flag> <path> — the honest check. Mode bits can look
# right while an ACL, a parent directory or a MAC policy still says no, so ask
# the kernel as the actual principal.
can_access() { sudo -u "$1" test "$2" "$3" 2>/dev/null; }

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
safe_install_dir 750 "$APP_USER" "$APP_USER" "$APP_HOME"
safe_install_dir 750 "$APP_USER" "$APP_USER" "$LOG_DIR"
safe_install_dir 750 "$APP_USER" "$APP_USER" "$DATA_DIR"
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
chown -R www-data:www-data "$FRONTEND_DIR"
success "Frontend installed at ${FRONTEND_DIR}"

# ─── config ──────────────────────────────────────────────────────────────────
if [[ ! -f "${CONFIG_DIR}/config.yaml" ]]; then
    info "Installing default config..."
    # install(1), not cp+chmod: cp under umask 077 lands the file 0600 and
    # the following chmod races the window in between. install(1) creates it
    # with the final owner and mode in one step.
    install -m 640 -o root -g "$APP_USER" \
        "${SCRIPT_DIR}/config/config.yaml.example" "${CONFIG_DIR}/config.yaml"

    # Generate a random secret key
    SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    sed -i "s/CHANGE_ME_GENERATE_A_RANDOM_SECRET/${SECRET}/" "${CONFIG_DIR}/config.yaml"

    warn "Config installed at ${CONFIG_DIR}/config.yaml"
    warn "  → Edit the LDAP bind DN and password before starting."
else
    info "Config already exists — not overwritten."
fi

# ─── cluster profiles ───────────────────────────────────────────────────────
# A REINSTALL over an existing host finds a config.yaml that still carries
# the clusters: block, so this runs on install as well as on upgrade. It is
# the same module the upgrade calls, and it is idempotent.
info "Migrating cluster profiles into ${CLUSTERS_DIR} ..."
PYTHONPATH="$SCRIPT_DIR" "${VENV}/bin/python3" -m tm.migrate_clusters \
    --config "${CONFIG_DIR}/config.yaml" \
    --clusters-dir "$CLUSTERS_DIR" \
    --example "${SCRIPT_DIR}/config/clusters.yaml.example" \
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
