# Jarvis Topic Manager v1.0.2

**Standalone Kafka topic administration frontend for the Jarvis ecosystem.**

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.

---

## Overview

Jarvis Topic Manager is a lightweight web application that provides a secure, AD-authenticated interface for managing Apache Kafka topics. It integrates with the Jarvis/CORTEX ecosystem via a hyperlink from CORTEX's Jarvis tab.

**Design principles:** Simple. Offline-capable. STIG-aware. No unnecessary dependencies.

## Features

- **Topic Management** — List, create, delete, and view/edit topic configuration
- **Retrieve / Update** — Pull live topic config from Kafka; push changes back via `alter_configs`
- **Download Config** — Export any topic's live config as JSON; re-import to pre-fill Create Topic
- **Consumer Groups** — View group state and membership (30s auto-refresh with countdown)
- **Auto-refresh** — Topics and Consumer Groups tabs refresh every 30 seconds with live countdown
- **Audit Log** — Every create/delete/config-change is recorded with user, timestamp, and detail; CSV export
- **AD Authentication** — LDAPS bind + required AD group (`Kafka-Admins`) enforcement
- **DoW Consent Modal** — Duty of Warning popup on login (no bypass); enable/disable from Settings
- **Multi-cluster** — Supports bare-metal and K8s Kafka clusters; switch at runtime
- **3 Themes** — Dark (default), Light, Color Blind — stored per browser
- **Classification Banner** — Fixed at top and bottom of viewport; server-side persistence (consistent across all browsers and users)
- **Broker Hover Popup** — Hover the broker count to see all broker FQDNs and IDs
- **Concurrent Session Limit** — Configurable max simultaneous sessions per user (default 5)
- **Offline Install** — All dependencies bundlable; no internet required on target host
- **SonarQube** — Quality Gate OK on CE 26.5 (`192.168.202.76:9000`, project `topic-manager`)

## Stack

| Layer    | Technology                              |
|----------|-----------------------------------------|
| Frontend | Vue.js 3 (Options API, no build tools)  |
| Backend  | Python 3.12 / Flask 3 / gunicorn        |
| Auth     | AD/LDAPS via ldap3                      |
| Kafka    | confluent-kafka AdminClient             |
| Web      | nginx (TLS termination, reverse proxy)  |
| DB       | SQLite (audit log)                      |
| OS       | Ubuntu Server 24.04 LTS                 |

## Quick Start

### Build Artifacts

**Frontend tar** (for deployment without git on the target server):
```bash
# Run on any machine with the repo checked out + lib/vue.global.prod.js present
# Download Vue first if needed:
curl -fsSL https://cdn.jsdelivr.net/npm/vue@3.5.35/dist/vue.global.prod.js \
  -o lib/vue.global.prod.js
# Build the tar:
tar czf topic-manager-frontend-1.0.2.tar.gz \
  app index.html lib jarvis-favicon.ico jarvis-glyph-32.png jarvis-logo.png
# Deploy on server:
sudo tar xzf topic-manager-frontend-1.0.2.tar.gz -C /var/www/topic-manager/
sudo chown -R www-data:www-data /var/www/topic-manager/
```

**Offline bundle** (air-gapped installs — requires Linux/WSL with pip3):
```bash
bash prepare-offline.sh --bundle
# → creates topic-manager-offline-1.0.2.tar.gz
# Contains: all source + Python wheels + Vue.js lib
```

### Online Install
```bash
git clone https://github.com/ymxplusb/Topic-Manager.git
cd Topic-Manager
sudo bash install.sh
sudo nano /etc/topic-manager/config.yaml   # edit LDAP + cluster settings
# place TLS cert at /etc/topic-manager/tls/server.crt + server.key
sudo systemctl start topic-manager nginx
curl -sk https://localhost/api/health
```

### Offline Install
On internet-connected machine:
```bash
bash prepare-offline.sh --bundle
# → creates topic-manager-offline-1.0.2.tar.gz
```
Transfer bundle to air-gapped host, extract, then:
```bash
sudo bash install.sh
```

## Configuration

Main config: `/etc/topic-manager/config.yaml`

Key settings:
- `auth.ldap_server` — LDAPS endpoint (e.g., `ldaps://dc1.int.crypticlight.com:636`)
- `auth.required_group` — Full DN of AD group that grants access
- `clusters[].bootstrap_servers` — Kafka broker addresses
- `server.secret_key` — Flask session secret (auto-generated on first install)

See `config/config.yaml.example` for full annotated reference.

## File Layout (Server)

```
/opt/topic-manager/          Backend root
  venv/                      Python virtual environment
  tm/                        Flask application package
  data/tm.db                 SQLite audit database
  logs/                      gunicorn access + error logs
/var/www/topic-manager/      Frontend static files
/etc/topic-manager/          Configuration
  config.yaml                Main config (edit this)
  tls/server.crt             TLS certificate
  tls/server.key             TLS private key
/etc/nginx/sites-available/topic-manager   nginx site config
/etc/systemd/system/topic-manager.service  systemd unit
```

## Compliance

- HTTPS enforced (HTTP → 301 redirect)
- TLS 1.2 / 1.3 only
- HTTPOnly + Secure + SameSite=Lax session cookies
- Security headers: HSTS, CSP (with `frame-ancestors 'none'`, `form-action 'none'`, `base-uri 'self'`), X-Content-Type-Options, Referrer-Policy
- Audit log for all destructive and config-change operations
- Destructive actions require name-match confirmation
- Session timeout: 30 minutes (configurable)

See `PPSM.csv` for port/protocol inventory and `SBOM.md` for dependency inventory.

## Integrate with CORTEX

In CORTEX's `JarvisTab.js`, a "⚡ Topic Manager ↗" button links to this application.
The URL is `https://kafka-topics.int.crypticlight.com` — update to match your deployment hostname.

## Support

Logs:
```bash
journalctl -u topic-manager -f
tail -f /opt/topic-manager/logs/error.log
nginx -t && sudo systemctl status nginx
```

See `docs/INSTALL.md` for the complete installation guide.
