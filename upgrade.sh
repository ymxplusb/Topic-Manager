#!/usr/bin/env bash
# =============================================================================
# Jarvis Topic Manager — Clean Reinstall Upgrade
# v1.0.0  →  v1.0.2
#
# Strategy: backup everything → uninstall v1.0.0 → fresh install v1.0.2
#           → restore config/data → verify → report
#
# Nothing is patched in place. All application files are replaced wholesale.
# Configuration, audit data, and TLS certificates are preserved exactly.
#
# Usage:   sudo bash upgrade.sh
# =============================================================================
set -euo pipefail

# ─── constants ────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/ymxplusb/Topic-Manager.git"
REPO_BRANCH="main"
FROM_VERSION="1.0.0"
TARGET_VERSION="1.0.2"

APP_USER="topic-manager"
APP_HOME="/opt/topic-manager"
FRONTEND_DIR="/var/www/topic-manager"
CONFIG_DIR="/etc/topic-manager"
VENV="${APP_HOME}/venv"
SERVICE="topic-manager"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/opt/topic-manager-backup-${TIMESTAMP}"
WORK_DIR="/tmp/topic-manager-src-${TIMESTAMP}"

VUE_VERSION="3.5.35"
VUE_URL="https://cdn.jsdelivr.net/npm/vue@${VUE_VERSION}/dist/vue.global.prod.js"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
die()     { echo -e "${RED}[FAIL]${NC}    $*" >&2; echo -e "${RED}Upgrade aborted. System is unchanged — your v1.0.0 install is still running.${NC}" >&2; exit 1; }
phase()   { echo -e "\n${BOLD}── $* ──────────────────────────────────────────────────${NC}"; }

# ─── root check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash upgrade.sh"

# =============================================================================
phase "Phase 1: Pre-flight checks"
# =============================================================================

# Version gate
INSTALLED_VER="$(cat "${APP_HOME}/tm/VERSION" 2>/dev/null || echo 'unknown')"
[[ "$INSTALLED_VER" == "$FROM_VERSION" ]] \
    || die "Expected v${FROM_VERSION} installed, found: ${INSTALLED_VER}. This script only upgrades v1.0.0."
info "Installed version: ${INSTALLED_VER} ✓"

# Service health
PRE_HEALTH="$(curl -sk https://localhost/api/health 2>/dev/null || true)"
echo "$PRE_HEALTH" | grep -q '"ok"' \
    || die "v1.0.0 health check failed: ${PRE_HEALTH:-no response}. Resolve the existing issue before upgrading."
success "v1.0.0 is healthy"

# Config readable
[[ -f "${CONFIG_DIR}/config.yaml" ]] \
    || die "Config not found at ${CONFIG_DIR}/config.yaml"
info "Config found ✓"

# Disk space: need ~500 MB free in /tmp and /opt
for mount in /tmp /opt; do
    FREE_KB=$(df --output=avail "$mount" 2>/dev/null | tail -1 | tr -d ' ')
    [[ "${FREE_KB:-0}" -gt 512000 ]] \
        || die "Less than 500 MB free on ${mount} (${FREE_KB} KB available). Free space before upgrading."
done
success "Disk space OK"

# Internet check
ONLINE=false
curl -s --max-time 5 https://pypi.org > /dev/null 2>&1 && ONLINE=true
[[ $ONLINE == true ]] && info "Network mode: ONLINE" || warn "Network mode: OFFLINE — packages must be pre-installed in the venv"

# =============================================================================
phase "Phase 2: Backup"
# =============================================================================

mkdir -p "${BACKUP_DIR}"
info "Backing up to ${BACKUP_DIR} ..."

cp "${CONFIG_DIR}/config.yaml"                             "${BACKUP_DIR}/config.yaml"
cp "${APP_HOME}/tm/VERSION"                               "${BACKUP_DIR}/VERSION"
[[ -f "${APP_HOME}/data/tm.db" ]]       && cp "${APP_HOME}/data/tm.db"      "${BACKUP_DIR}/tm.db"
[[ -d "${CONFIG_DIR}/tls" ]]            && cp -r "${CONFIG_DIR}/tls"        "${BACKUP_DIR}/tls"
[[ -f /etc/nginx/sites-available/topic-manager ]] \
    && cp /etc/nginx/sites-available/topic-manager       "${BACKUP_DIR}/nginx-topic-manager.conf"

success "Backup written to ${BACKUP_DIR}"

# =============================================================================
phase "Phase 3: Fetch v${TARGET_VERSION}"
# =============================================================================

if [[ $ONLINE == true ]]; then
    if ! command -v git &>/dev/null; then
        info "Installing git..."
        apt-get install -y --no-install-recommends git -qq
    fi
    info "Cloning ${REPO_URL} (${REPO_BRANCH})..."
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$WORK_DIR" --quiet \
        || die "git clone failed. Check internet access or run prepare-offline.sh on another machine."
    REPO_VER="$(cat "${WORK_DIR}/tm/VERSION" 2>/dev/null || echo 'unknown')"
    [[ "$REPO_VER" == "$TARGET_VERSION" ]] \
        || die "Cloned repo reports version ${REPO_VER}, expected ${TARGET_VERSION}. Check the repo branch."
    success "v${TARGET_VERSION} source fetched"
else
    # Offline: expect source at /tmp/topic-manager-offline-src
    WORK_DIR="/tmp/topic-manager-offline-src"
    [[ -d "$WORK_DIR" ]] \
        || die "Offline source not found at ${WORK_DIR}. See TROUBLESHOOTING.md for offline procedure."
    success "Using offline source at ${WORK_DIR}"
fi

# =============================================================================
phase "Phase 4: Stop and uninstall v${FROM_VERSION}"
# =============================================================================

info "Stopping ${SERVICE}..."
systemctl stop "$SERVICE" 2>/dev/null || true
systemctl disable "$SERVICE" 2>/dev/null || true

info "Removing v${FROM_VERSION} application files..."
rm -rf "${VENV}"
rm -rf "${APP_HOME}/tm"
rm -f  "${APP_HOME}/wsgi.py"
rm -rf "${FRONTEND_DIR:?}"/*
rm -f  /etc/nginx/sites-available/topic-manager
rm -f  /etc/nginx/sites-enabled/topic-manager
rm -f  /etc/nginx/snippets/tm-security-headers.conf
rm -f  /etc/systemd/system/topic-manager.service
systemctl daemon-reload

success "v${FROM_VERSION} removed"

# =============================================================================
phase "Phase 5: Install v${TARGET_VERSION}"
# =============================================================================

# Python venv
info "Creating Python virtual environment..."
python3 -m venv "$VENV"
ls "${VENV}/lib/python"*"/site-packages/" > /dev/null 2>&1 \
    || die "venv creation failed — lib/pythonX.Y/site-packages/ not present. Check disk space and Python installation."
success "venv created"

# pip: service-critical stack first
info "Installing Flask / Werkzeug / gunicorn..."
"${VENV}/bin/pip" install --upgrade pip --quiet
"${VENV}/bin/pip" install "Flask==3.1.3" "Werkzeug==3.1.8" "gunicorn==26.0.0" \
    || die "pip install of Flask/Werkzeug/gunicorn failed. Check internet access or disk space."
success "Flask / Werkzeug / gunicorn installed"

# pip: remaining packages
info "Installing ldap3 / PyYAML / cryptography..."
"${VENV}/bin/pip" install "ldap3==2.9.1" "PyYAML==6.0.2" "cryptography==44.0.2" \
    || die "pip install of ldap3/PyYAML/cryptography failed."
success "ldap3 / PyYAML / cryptography installed"

# pip: confluent-kafka (soft fail — service starts without it)
info "Installing confluent-kafka..."
"${VENV}/bin/pip" install "confluent-kafka==2.14.0" \
    || warn "confluent-kafka install failed — Kafka operations will not work until resolved. See TROUBLESHOOTING.md."

# Import sanity check before touching anything else
"${VENV}/bin/python3" -c "import gunicorn, flask, ldap3" \
    || die "Package import check failed. Installed packages are not importable — check for disk/permission issues."
success "Package imports verified"

# Backend
info "Deploying backend..."
rsync -a "${WORK_DIR}/tm/"   "${APP_HOME}/tm/"
cat > "${APP_HOME}/wsgi.py" <<'WSGI'
from tm.app import create_app
application = create_app()
WSGI
chown -R "${APP_USER}:${APP_USER}" "${APP_HOME}/tm" "${APP_HOME}/wsgi.py"
success "Backend deployed"

# Frontend
info "Deploying frontend..."
rsync -a \
    "${WORK_DIR}/index.html" \
    "${WORK_DIR}/app" \
    "${FRONTEND_DIR}/"

# Vue.js — download fresh copy or keep existing
mkdir -p "${FRONTEND_DIR}/lib"
if [[ $ONLINE == true ]]; then
    curl -fsSL --max-time 30 "$VUE_URL" -o "${FRONTEND_DIR}/lib/vue.global.prod.js" 2>/dev/null \
        && success "Vue.js ${VUE_VERSION} downloaded" \
        || warn "Vue.js CDN download failed — copying from source bundle if available"
fi
if [[ ! -f "${FRONTEND_DIR}/lib/vue.global.prod.js" ]] && [[ -f "${WORK_DIR}/lib/vue.global.prod.js" ]]; then
    cp "${WORK_DIR}/lib/vue.global.prod.js" "${FRONTEND_DIR}/lib/vue.global.prod.js"
    success "Vue.js copied from source"
fi
[[ -f "${FRONTEND_DIR}/lib/vue.global.prod.js" ]] \
    || warn "Vue.js not installed — the web UI will not load until lib/vue.global.prod.js is placed manually."

# Copy any image/icon assets
for asset in jarvis-favicon.ico jarvis-glyph-32.png jarvis-logo.png; do
    [[ -f "${WORK_DIR}/${asset}" ]] && cp "${WORK_DIR}/${asset}" "${FRONTEND_DIR}/${asset}" || true
done

chown -R www-data:www-data "$FRONTEND_DIR"
success "Frontend deployed"

# nginx
info "Installing nginx config..."
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/tm-security-headers.conf <<'NGINXEOF'
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options nosniff always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'; form-action 'none'; base-uri 'self';" always;
NGINXEOF

cp "${WORK_DIR}/nginx/topic-manager.conf" /etc/nginx/sites-available/topic-manager
ln -sf /etc/nginx/sites-available/topic-manager /etc/nginx/sites-enabled/topic-manager
rm -f /etc/nginx/sites-enabled/default
nginx -t 2>/dev/null || die "nginx config test failed. Check TLS cert paths in ${CONFIG_DIR}/tls/"
success "nginx configured"

# systemd
info "Installing systemd service..."
cp "${WORK_DIR}/systemd/topic-manager.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable "$SERVICE" --quiet
success "systemd service installed"

# =============================================================================
phase "Phase 6: Restore configuration and data"
# =============================================================================

info "Restoring config.yaml..."
cp "${BACKUP_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml"
chmod 640 "${CONFIG_DIR}/config.yaml"
chown root:"${APP_USER}" "${CONFIG_DIR}/config.yaml"

if [[ -f "${BACKUP_DIR}/tm.db" ]]; then
    cp "${BACKUP_DIR}/tm.db" "${APP_HOME}/data/tm.db"
    chown "${APP_USER}:${APP_USER}" "${APP_HOME}/data/tm.db"
    success "Audit database restored"
fi

if [[ -d "${BACKUP_DIR}/tls" ]]; then
    cp -r "${BACKUP_DIR}/tls/." "${CONFIG_DIR}/tls/"
    chmod 640 "${CONFIG_DIR}/tls/"*.{crt,key} 2>/dev/null || true
    chown root:"${APP_USER}" "${CONFIG_DIR}/tls/"* 2>/dev/null || true
    success "TLS certificates restored"
fi

echo "${TARGET_VERSION}" > "${APP_HOME}/tm/VERSION"
chown "${APP_USER}:${APP_USER}" "${APP_HOME}/tm/VERSION"
success "Config and data restored"

# =============================================================================
phase "Phase 7: Config migration (v1.0.0 → v1.0.2 new fields)"
# =============================================================================

CONFIG_FILE="${CONFIG_DIR}/config.yaml"

# Add ldap_ca_cert if missing (new in v1.0.2 — blank means use system trust store)
if ! grep -q 'ldap_ca_cert' "$CONFIG_FILE"; then
    sed -i '/ldap_server:/a\  ldap_ca_cert: ""         # blank = system trust store; set to CA PEM path if cert not trusted' "$CONFIG_FILE"
    success "ldap_ca_cert added to config"
fi

# Validate YAML syntax
"${VENV}/bin/python3" -c "import yaml; yaml.safe_load(open('${CONFIG_FILE}'))" \
    || die "config.yaml failed YAML validation after migration. Check the file manually: sudo nano ${CONFIG_FILE}"
success "config.yaml valid"

# =============================================================================
phase "Phase 8: Start and verify"
# =============================================================================

info "Starting ${SERVICE}..."
systemctl start "$SERVICE"
systemctl reload nginx
sleep 5

POST_HEALTH="$(curl -sk https://localhost/api/health 2>/dev/null || true)"
if echo "$POST_HEALTH" | grep -q "\"${TARGET_VERSION}\""; then
    success "Health check: ${POST_HEALTH}"
else
    die "Health check failed after start: ${POST_HEALTH:-no response}
Run: sudo journalctl -u ${SERVICE} -n 50 --no-pager
See: TROUBLESHOOTING.md"
fi

# =============================================================================
phase "Upgrade complete"
# =============================================================================

BIND_PW="$(grep 'ldap_bind_password' "$CONFIG_FILE" | head -1 | sed "s/.*: //" | tr -d '"' | tr -d "'")"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Topic Manager upgraded to v${TARGET_VERSION}${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Backup:  ${BACKUP_DIR}/"
echo ""
echo -e "${BOLD}Post-upgrade checklist:${NC}"
echo ""

# LDAPS cert
echo "  1. Verify DC cert is trusted (v1.0.2 enforces CERT_REQUIRED):"
echo "       openssl s_client -connect YOUR-DC:636 \\"
echo "         -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>&1 | grep 'Verify return code'"
echo "     Expected: Verify return code: 0 (ok)"
echo "     If not: sudo cp your-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates"
echo ""

# Service account
if [[ "$BIND_PW" == "CHANGE_ME" ]] || [[ -z "$BIND_PW" ]]; then
    echo "  2. LDAP service account: ldap_bind_password is CHANGE_ME"
    echo "     Auth falls back to direct user bind (same as v1.0.0 — login works as-is)."
    echo "     Optional: set a real service account password for stronger security:"
    echo "       sudo nano ${CONFIG_FILE}"
    echo "       sudo systemctl restart ${SERVICE}"
else
    echo "  2. LDAP service account password is set. Verify with:"
    echo "       ldapwhoami -H ldaps://YOUR-DC:636 \\"
    echo "         -D \"\$(sudo grep ldap_bind_dn ${CONFIG_FILE} | awk -F'\"' '{print \$2}')\" \\"
    echo "         -w YOUR-SERVICE-ACCOUNT-PASSWORD -x"
    echo "     Expected: dn:CN=svc-..."
fi
echo ""

echo "  3. Test login at https://$(hostname -f 2>/dev/null || hostname)"
echo "     Username format: your AD sAMAccountName (e.g. firstname.lastname)"
echo ""
echo "  4. Hard-refresh browsers (Ctrl+Shift+R) — JS cache tokens changed"
echo ""
echo "  Full troubleshooting: TROUBLESHOOTING.md"
echo "  Rollback: restore vCSA snapshot taken before this run"
echo "  Backup files: ${BACKUP_DIR}/"
echo ""

# Clean up work dir
rm -rf "$WORK_DIR" 2>/dev/null || true
