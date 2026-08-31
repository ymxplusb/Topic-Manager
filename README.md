# Jarvis Topic Manager v1.0.3

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
- **AD Authentication** — LDAPS bind + required AD group enforcement
- **DoW Consent Modal** — Duty of Warning popup on login (no bypass); enable/disable from Settings
- **Multi-cluster** — Supports bare-metal and K8s Kafka clusters; switch at runtime
- **3 Themes** — Dark (default), Light, Color Blind — stored per browser
- **Classification Banner** — Fixed at top and bottom of viewport; server-side persistence
- **Broker Hover Popup** — Hover the broker count to see all broker FQDNs and IDs
- **Concurrent Session Limit** — Configurable max simultaneous sessions per user (default 5)
- **Offline Install** — All dependencies bundlable; no internet required on target host

## Stack

| Layer    | Technology                              |
|----------|-----------------------------------------|
| Frontend | Vue.js 3.5.42 (Options API, no build tools) |
| Backend  | Python 3.12 / Flask 3.1.3 / gunicorn 26.2.0 |
| Auth     | AD/LDAPS via ldap3 2.9.1                |
| Kafka    | confluent-kafka 2.15.0 AdminClient      |
| Web      | nginx (TLS termination, reverse proxy)  |
| DB       | SQLite (audit log + server-side sessions) |
| OS       | Ubuntu Server 24.04 LTS                 |

Every Python version above is pinned in `requirements.txt`, which is the single source of truth — the upgrade script and the offline bundler both read their pins from it. The Vue version and its SHA-256 are pinned in `install/upgrade-full.sh`. See `SBOM.md` for the full inventory, including the two places a *fresh* `install.sh` still differs.

---

## Installing

> **Upgrading an existing installation?** See [Upgrading](#upgrading) — do not re-run `install.sh` on a server that already has Topic Manager deployed.

### Prerequisites

- Ubuntu Server 24.04 LTS
- 2 vCPU · 4 GB RAM · 20 GB disk (minimum)
- Static IP, DNS A record pointing to the host
- Network access: DC on port 636 (LDAPS), Kafka brokers on port 9092 (or 9094 for SSL)
- An AD service account for LDAP directory searches (Domain Users rights are sufficient)
- A TLS certificate for the hostname (internal CA or self-signed)

### Step 1 — Get the code

```bash
git clone https://github.com/ymxplusb/Topic-Manager.git
cd Topic-Manager
```

On an **air-gapped host**, see [Offline Install](#offline-install) below.

### Step 2 — Run the installer

```bash
sudo bash install.sh
```

The script:
- Installs system packages (python3, python3-venv, nginx, libldap, libssl, build-essential)
- Downloads Vue.js from the CDN automatically (online mode). Note that `install.sh` still asks for **3.5.35** and takes whatever the CDN returns, with no integrity check; the upgrade path pins **3.5.42** by SHA-256 and refuses anything else. A host that has been upgraded is therefore on a *verified* newer Vue than a host freshly installed — see `SBOM.md`
- Creates the `topic-manager` system user
- Creates `/opt/topic-manager/`, `/var/www/topic-manager/`, `/etc/topic-manager/`
- Sets up the Python virtual environment and installs all packages
- Deploys backend and frontend files
- Writes a default config to `/etc/topic-manager/config.yaml` with an auto-generated secret key
- Installs the systemd service (`topic-manager.service`) and nginx site config
- Opens ufw ports 80 and 443 if ufw is active

The installer **does not start services** — complete the configuration steps below first.

### Step 3 — Edit the config

```bash
sudo nano /etc/topic-manager/config.yaml
```

Required fields:

```yaml
auth:
  ldap_server:       "ldaps://your-dc.yourdomain.com:636"
  ldap_domain:       "yourdomain.com"
  ldap_base_dn:      "DC=yourdomain,DC=com"
  ldap_bind_dn:      "CN=svc-topic-mgr,OU=ServiceAccounts,DC=yourdomain,DC=com"
  ldap_bind_password: "the-service-account-password"
  required_group:    "CN=Kafka-Admins,CN=Users,DC=yourdomain,DC=com"

clusters:
  - id:   "production"
    name: "Production"
    bootstrap_servers: "broker1.yourdomain.com:9092,broker2.yourdomain.com:9092"
    security_protocol: "PLAINTEXT"
    active: true
```

The `ldap_bind_dn` must be the full Distinguished Name of your service account.  
The `required_group` must be the full DN of the AD group whose members are allowed to log in.

To find these values from any domain-joined Windows machine:
```powershell
Get-ADUser    -Identity "svc-topic-mgr"    | Select-Object DistinguishedName
Get-ADGroup   -Identity "Kafka-Admins"     | Select-Object DistinguishedName
```

Validate the YAML syntax before proceeding:
```bash
python3 -c "import yaml; yaml.safe_load(open('/etc/topic-manager/config.yaml'))" && echo "OK"
```

### Step 4 — Place the TLS certificate

nginx requires a certificate and private key at:

```
/etc/topic-manager/tls/server.crt
/etc/topic-manager/tls/server.key
```

**From an internal CA** — generate a CSR and sign it:
```bash
sudo openssl req -new -newkey rsa:2048 -nodes \
  -keyout /etc/topic-manager/tls/server.key \
  -out    /tmp/topic-manager.csr \
  -subj   "/CN=your-hostname.yourdomain.com" \
  -addext "subjectAltName=DNS:your-hostname.yourdomain.com"
# Submit /tmp/topic-manager.csr to your CA, then place the signed cert:
sudo cp /path/to/signed.crt /etc/topic-manager/tls/server.crt
```

**Self-signed** (testing only):
```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/topic-manager/tls/server.key \
  -out    /etc/topic-manager/tls/server.crt \
  -subj   "/CN=your-hostname.yourdomain.com"
```

Set permissions:
```bash
sudo chmod 640 /etc/topic-manager/tls/server.crt /etc/topic-manager/tls/server.key
sudo chown root:topic-manager /etc/topic-manager/tls/server.crt /etc/topic-manager/tls/server.key
```

Verify nginx accepts the cert:
```bash
sudo nginx -t
```

### Step 5 — Start services

```bash
sudo systemctl start topic-manager
sudo systemctl restart nginx
```

### Step 6 — Verify

```bash
# Backend direct
curl http://127.0.0.1:5001/api/health
# Through nginx (HTTPS)
curl -sk https://localhost/api/health
```

Both should return: `{"status":"ok","version":"1.0.3"}`

Then open `https://your-hostname.yourdomain.com` in a browser and sign in with an AD account that is a member of `Kafka-Admins`.

> **Login credential format:** use your AD `sAMAccountName` (e.g. `firstname.lastname`), your full UPN (`firstname.lastname@yourdomain.com`), or `DOMAIN\firstname.lastname`. Display names and email aliases are not supported.

---

## Upgrading

> **Do not run `install.sh` on an existing deployment.** It uses `rsync -a --delete` on the backend and frontend directories and will remove files it did not put there.

Upgrades are run by **`install/upgrade-full.sh`**, which is the only supported upgrade path in this repo. It is version-agnostic: it upgrades whatever is installed — including v1.0.0 — to whatever the source tree it fetches declares in `tm/VERSION`. It audits the host first, takes a verified backup before touching anything, and rolls back automatically if a phase fails.

What it does, in order:

| Phase | |
|-------|--|
| 1–2  | Preflight and permission audit — disk, ownership and modes, immutable attributes, POSIX ACLs, AppArmor/SELinux, auditd/AIDE/fapolicyd, and effective access asked of the kernel as the real `www-data` and `topic-manager` principals |
| 3    | Upgrade blockers — `server.secret_key` must be set, and if a service bind is configured the LDAP bind must actually succeed. Both are resolved the way the *service* sees them: the unit's `Environment=` / `EnvironmentFile=` (drop-ins included) first, then the shell, then `config.yaml` |
| 4    | Backup to `/var/backups/topic-manager/<TIMESTAMP>` plus a `.tar.gz` alongside it — config, TLS key and certificate, extra CA material, a consistent SQLite snapshot, the venv, the nginx config, the systemd unit **and its drop-in directory**, and a recorded permission baseline. Checksummed and verified before the upgrade is allowed to continue |
| 5    | Fetch the target source and read every Python pin from its `requirements.txt` — the script keeps no pins of its own |
| 6    | OS packages (`apt full-upgrade`), unless `--skip-os` |
| 7–9  | Replace venv, backend, frontend, nginx config and unit. Vue is verified by SHA-256 before it is allowed to serve |
| 10   | Restore `config.yaml`, the audit database, TLS material, the systemd drop-in, and the recorded ownership and modes verbatim — a deliberately narrowed permission is never widened back to a script default |
| 11–12| Config migration, then start and verify: health, reported version, effective access, and the security headers on every route class |

**Step 1 — Take a vCSA snapshot** of the VM before doing anything else.

**Step 2 — Check what is actually installed:**
```bash
curl -sk https://localhost/api/health
# {"status":"ok","version":"1.0.0"}
```

**Step 3 — Get the script and audit the host.** The clone below only supplies the script; the upgrade fetches its own copy of the target source in Phase 5.
```bash
sudo apt-get install -y git
git clone https://github.com/ymxplusb/Topic-Manager.git /tmp/topic-manager-upgrade
cd /tmp/topic-manager-upgrade
sudo bash install/upgrade-full.sh --audit-only
```
`--audit-only` changes nothing and exits **0** clear, **1** warnings only, **2** blockers present. Resolve every blocker before going further — they are the failures that otherwise appear an hour later as "nobody can log in".

**Step 4 — Take the verified restore point:**
```bash
sudo bash install/upgrade-full.sh --backup-only
sudo bash install/upgrade-full.sh --list-backups
```

**Step 5 — Run the upgrade:**
```bash
sudo bash install/upgrade-full.sh
```
Useful flags: `--dry-run` (audit + plan, no changes), `--skip-os` (application and dependencies only), `--offline` (see below), `--force` (proceed past blockers — the backup is still taken first).

**Step 6 — Follow the post-upgrade checklist** printed at the end of the run:

1. Verify LDAPS cert is trusted:
```bash
openssl s_client -connect your-dc.yourdomain.com:636 \
  -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>&1 | grep "Verify return code"
# Expected: Verify return code: 0 (ok)
```
If not 0: `sudo cp your-internal-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`

2. If `ldap_bind_password` in your config is a real value (not `CHANGE_ME`), verify the service account works:
```bash
ldapwhoami -H ldaps://your-dc.yourdomain.com:636 \
  -D "CN=svc-account,OU=ServiceAccounts,DC=yourdomain,DC=com" -w "PASSWORD" -x
# Expected: dn:CN=svc-account,...
```
If `ldap_bind_password` is `CHANGE_ME`, auth falls back to direct user bind — login works without any changes.

3. Sign in with your AD `sAMAccountName` (`firstname.lastname`) or full UPN.

4. Hard-refresh all browsers — `Ctrl+Shift+R`.

### Rolling back

Every run leaves a verified restore point. Nothing is deleted by a rollback that is not put back from it.

```bash
sudo bash install/upgrade-full.sh --list-backups
# 20260830-141205  v1.0.0  412M  verified OK  perms recorded

sudo bash install/upgrade-full.sh --restore 20260830-141205
```
`--restore` verifies the backup's `SHA256SUMS` before it restores from it, puts back the recorded ownership and modes, and reports the health of what it restored. A vCSA snapshot revert remains the fastest option if the host itself is in doubt.

### Offline (air-gapped) upgrade

The bundle is built on a machine that **has** a network, then carried to the target. The path below is not optional — the upgrade script reads the bundle from exactly one location.

On the internet-connected machine, with this repo checked out:
```bash
bash prepare-offline.sh --bundle
# Downloads the wheels for every pin in requirements.txt, verifies each one is
# present, downloads Vue and checks it against the SHA-256 that
# install/upgrade-full.sh will check on the target, then writes
# topic-manager-offline-<version>.tar.gz one directory above the repo.
```

Transfer it, then on the air-gapped host:
```bash
sudo install -d -m 700 -o root -g root /var/lib/topic-manager/offline-src
sudo tar xzf topic-manager-offline-<version>.tar.gz -C /tmp
# The tarball extracts to a directory named after the repo checkout:
sudo mv /tmp/topic-manager/* /var/lib/topic-manager/offline-src/

sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --offline
```

- **`/var/lib/topic-manager/offline-src` is fixed.** The script does not search for the bundle and will stop with `Offline source not found` if it is anywhere else.
- `--offline` forces offline mode; the script also selects it on its own when `pypi.org` is unreachable, so a genuinely air-gapped host takes this path with or without the flag.
- The bundle is **not** deleted on success — an air-gapped host cannot fetch another one, and a re-upgrade after a `--restore` needs it.
- `--offline` implies no OS patching: `apt` has no repository to reach.
- The Python versions installed offline are the ones in the bundle's `requirements.txt`, which is the same file the online path installs from. If `prepare-offline.sh` reported a missing pin, fix it on the networked machine — the target cannot.

See `TROUBLESHOOTING.md` for diagnosis procedures for every known failure mode.

---

## Offline Install

On an **internet-connected** machine with the repo checked out:

```bash
bash prepare-offline.sh --bundle
# Creates: topic-manager-offline-1.0.3.tar.gz
# Contains: all source files + Python wheels + Vue.js lib
```

Transfer the bundle to the air-gapped host:
```bash
scp topic-manager-offline-1.0.3.tar.gz user@target:/tmp/
```

On the air-gapped host:
```bash
cd /tmp
tar xzf topic-manager-offline-1.0.3.tar.gz
cd topic-manager
sudo bash install.sh    # auto-detects offline mode, uses bundled packages
```

Continue from [Step 3 — Edit the config](#step-3--edit-the-config) above.

---

## Configuration Reference

Main config: `/etc/topic-manager/config.yaml`  
Full annotated example: `config/config.yaml.example`

Key settings:

| Setting | Description |
|---------|-------------|
| `server.secret_key` | Flask session secret — auto-generated on install, do not change |
| `auth.ldap_server` | LDAPS endpoint, e.g. `ldaps://dc1.yourdomain.com:636` |
| `auth.ldap_ca_cert` | Path to CA bundle; leave blank to use system trust store |
| `auth.ldap_bind_dn` | Full DN of service account used for directory searches |
| `auth.ldap_bind_password` | Service account password |
| `auth.required_group` | Full DN of the AD group required for access |
| `clusters[].bootstrap_servers` | Comma-separated Kafka broker addresses |
| `session.timeout_minutes` | Session idle timeout (default: 30) |

---

## File Layout (Server)

```
/opt/topic-manager/          Backend root
  venv/                      Python virtual environment
  tm/                        Flask application package
  data/tm.db                 SQLite audit + session database
  logs/                      gunicorn access + error logs
/var/www/topic-manager/      Frontend static files (nginx root)
/etc/topic-manager/          Configuration
  config.yaml                Main config — edit this
  tls/server.crt             TLS certificate
  tls/server.key             TLS private key
/etc/nginx/sites-available/topic-manager   nginx site config
/etc/nginx/snippets/tm-security-headers.conf   Security header snippet
/etc/systemd/system/topic-manager.service    systemd unit
/etc/systemd/system/topic-manager.service.d/ unit drop-ins, if used — this is
                             where TM_SECRET_KEY and TM_LDAP_BIND_PASSWORD live
                             when the configuration is held in the environment
                             rather than in config.yaml. Backed up and restored
                             with everything else
/var/backups/topic-manager/  Upgrade restore points
  <TIMESTAMP>/               One per run: etc/ data/ app/ frontend/ system/
                             manifest/ + SHA256SUMS
  topic-manager-backup-<TIMESTAMP>.tar.gz   The same tree, archived (mode 600)
/var/log/topic-manager-upgrade-<TIMESTAMP>.log   Full transcript of an upgrade
```

---

## Compliance

- HTTPS enforced (HTTP → 301 redirect)
- TLS 1.2 / 1.3 only; strong cipher suite
- HTTPOnly + Secure + SameSite=Lax session cookies
- Security headers on all routes: HSTS, CSP (`frame-ancestors 'none'`, `form-action 'none'`, `base-uri 'self'`), X-Content-Type-Options, Referrer-Policy
- Server-side session store (SQLite); session tokens never leave the server in a readable form
- Audit log for all create/delete/config-change operations with user, IP, timestamp, and detail
- Destructive actions require name-match confirmation
- Session timeout: 30 minutes (configurable)
- Fail-closed: application refuses to start if `secret_key` is absent or still the placeholder

See `PPSM.csv` for port/protocol inventory and `SBOM.md` for dependency inventory.

---

## Integrate with CORTEX

In CORTEX's `JarvisTab.js`, a "⚡ Topic Manager ↗" button links to this application.
Update the URL to match your deployment hostname if it differs from the default.

---

## Support

```bash
# Application logs
journalctl -u topic-manager -f
tail -f /opt/topic-manager/logs/error.log

# nginx logs
tail -f /var/log/nginx/topic-manager-error.log

# Quick diagnostics
curl -sk https://localhost/api/health | python3 -m json.tool
sudo nginx -t
sudo systemctl status topic-manager nginx
```

See `docs/INSTALL.md` for the complete step-by-step installation guide including AD setup, domain join, TLS from an internal CA, and Prometheus monitoring integration.
