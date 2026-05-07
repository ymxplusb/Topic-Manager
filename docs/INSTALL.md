# Jarvis Topic Manager — Installation Guide

**Version:** 1.0.0
**Platform:** Ubuntu Server 24.04 LTS
**Completed by:** Human administrator
**Copyright (c) 2025-2026 James Rodman. All Rights Reserved.**

---

> **Environment-Specific Values**
> This guide was written for the CrypticLight / BlueRootX deployment.
> The following values appear throughout and must be substituted for your environment:
>
> | Placeholder used in this guide | Replace with |
> |---|---|
> | `192.168.202.90` | IP of your TopicManager VM |
> | `kafka-topics.int.crypticlight.com` | Your chosen FQDN for this server |
> | `dc1.int.crypticlight.com` | Your AD domain controller |
> | `int.crypticlight.com` | Your AD domain |
> | `int-CL-CA` on `192.168.202.6` | Your internal Certificate Authority |
> | `claude.admin` | Your AD admin account for domain join |
> | `192.168.202.5` | Your DNS server |
> | `broker1-3.int.crypticlight.com` | Your Kafka broker FQDNs |
>
> Everything else in the guide (paths, service names, package names) is generic and applies to any Ubuntu 24.04 installation.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Pre-Install Checklist](#2-pre-install-checklist)
3. [Get the Application](#3-get-the-application)
4. [Run the Install Script](#4-run-the-install-script)
5. [Configure the Application](#5-configure-the-application)
6. [TLS Certificate](#6-tls-certificate)
7. [Active Directory Setup](#7-active-directory-setup)
8. [Start and Verify Services](#8-start-and-verify-services)
9. [First Login Test](#9-first-login-test)
10. [Post-Install: CORTEX Button](#10-post-install-cortex-button)
11. [Firewall](#11-firewall)
12. [Prometheus Monitoring (Optional)](#12-prometheus-monitoring-optional)
13. [Troubleshooting](#13-troubleshooting)
14. [Offline Install Procedure](#14-offline-install-procedure)
15. [Upgrading](#15-upgrading)

---

## 1. Prerequisites

### Server
- Ubuntu Server 24.04 LTS (freshly deployed from `Ubuntu_24.04_Server` template)
- Minimum: 2 vCPU, 4 GB RAM, 20 GB disk
- Static IP assigned (e.g., `192.168.202.90`)
- Joined to AD domain `int.crypticlight.com` (see `ubuntu-desktop-xrdp-gdm-wayland.md` pattern)
- SSH access as `claude_admin` with key `~/.ssh/claude_admin`

### Network access the server must have
| Destination | Port | Protocol | Purpose |
|---|---|---|---|
| dc1.int.crypticlight.com | 636 | TCP | LDAPS authentication |
| broker1-3.int.crypticlight.com | 9092 | TCP | Kafka AdminClient |
| (Optional) 192.168.202.131-133 | 9094 | TCP | K8s Kafka (SSL) |

### DNS record
Add an A record in your internal DNS:
```
kafka-topics.int.crypticlight.com  →  192.168.202.90
```

### Required on admin workstation
- `git` or the ability to SCP the repo to the server
- Access to internal CA (`int-CL-CA` on 192.168.202.6) to sign a cert

---

## 2. Pre-Install Checklist

Run these from your workstation **before** touching the server:

```bash
# 1. Can you reach the server?
ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90 "hostname; ip -4 a | grep 192"

# 2. Can the server reach the Kafka brokers?
ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90 \
  "nc -zv broker1.int.crypticlight.com 9092; echo exit: $?"

# 3. Can the server reach AD?
ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90 \
  "nc -zv dc1.int.crypticlight.com 636; echo exit: $?"

# 4. Does the Kafka-Admins AD group exist?
# (run from a domain-joined Windows machine or use ADUC)
#   Active Directory Users and Computers → find or create "Kafka-Admins" group
#   Add your admin user account to it

# 5. Do you have a service account for LDAP bind?
#   You need: svc-kafka-ui@int.crypticlight.com (read-only, Domain Users)
#   If it doesn't exist, create it in ADUC first
```

---

## 3. Get the Application

### Option A — Clone from GitHub (online)

SSH into the server, then:

```bash
ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90

# On the server:
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/ymxplusb/Topic-Manager.git /opt/topic-manager-src
```

### Option B — SCP from your workstation

```bash
# From your Windows workstation (Git Bash):
scp -i ~/.ssh/claude_admin -r \
  /c/Users/jrodm/Scripts/topic-manager \
  claude_admin@192.168.202.90:/tmp/topic-manager-src

ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90
sudo mv /tmp/topic-manager-src /opt/topic-manager-src
```

### Option C — Offline bundle

See [Section 14 — Offline Install](#14-offline-install-procedure).

---

## 4. Run the Install Script

```bash
# On the server (as claude_admin, then sudo):
cd /opt/topic-manager-src
sudo bash install.sh
```

**What the script does:**
1. Installs system packages (python3, python3-venv, nginx, libldap, libssl)
2. Creates the `topic-manager` system user (no login shell, no home)
3. Creates directories: `/opt/topic-manager/`, `/var/www/topic-manager/`, `/etc/topic-manager/`
4. Creates Python virtual environment at `/opt/topic-manager/venv`
5. Installs Python packages (Flask, gunicorn, ldap3, confluent-kafka, PyYAML)
6. Copies backend to `/opt/topic-manager/tm/`
7. Copies frontend to `/var/www/topic-manager/`
8. Installs the default config to `/etc/topic-manager/config.yaml` (with auto-generated secret key)
9. Installs the systemd service: `topic-manager.service`
10. Installs the nginx site config
11. **Does NOT start services yet** — you must configure first

Expected output ends with:
```
══════════════════════════════════════════════════════
  Jarvis Topic Manager install complete.
══════════════════════════════════════════════════════
  Next steps:
  1. Edit config:  sudo nano /etc/topic-manager/config.yaml
  ...
```

---

## 5. Configure the Application

```bash
sudo nano /etc/topic-manager/config.yaml
```

### Required fields to edit:

```yaml
auth:
  ldap_server: "ldaps://dc1.int.crypticlight.com:636"
  ldap_domain: "int.crypticlight.com"
  ldap_base_dn: "DC=int,DC=crypticlight,DC=com"
  ldap_bind_dn: "CN=svc-kafka-ui,OU=Service Accounts,DC=int,DC=crypticlight,DC=com"
  ldap_bind_password: "THE_ACTUAL_PASSWORD_FOR_svc-kafka-ui"
  required_group: "CN=Kafka-Admins,CN=Users,DC=int,DC=crypticlight,DC=com"

clusters:
  - id: "bare-metal"
    name: "Bare Metal — Legacy Jarvis"
    bootstrap_servers: "broker1.int.crypticlight.com:9092,broker2.int.crypticlight.com:9092,broker3.int.crypticlight.com:9092"
    security_protocol: "PLAINTEXT"
    active: true
```

### Find the correct DN for `required_group`:

On a domain-joined machine or from PowerShell:
```powershell
# Run from any domain-joined Windows machine:
Get-ADGroup -Identity "Kafka-Admins" | Select-Object DistinguishedName
```

Example output: `CN=Kafka-Admins,CN=Users,DC=int,DC=crypticlight,DC=com`

### Verify config syntax:

```bash
python3 -c "import yaml; yaml.safe_load(open('/etc/topic-manager/config.yaml'))" && echo "YAML valid"
```

---

## 6. TLS Certificate

The nginx config requires a TLS certificate at `/etc/topic-manager/tls/`.

### Option A — Internal CA (Recommended for production)

1. Generate a CSR on the server:
```bash
sudo openssl req -new -newkey rsa:2048 -nodes \
  -keyout /etc/topic-manager/tls/server.key \
  -out /tmp/topic-manager.csr \
  -subj "/CN=kafka-topics.int.crypticlight.com/O=CrypticLight/C=US" \
  -addext "subjectAltName=DNS:kafka-topics.int.crypticlight.com,DNS:topic-manager.int.crypticlight.com,IP:192.168.202.90"
```

2. Copy the CSR to your Windows workstation:
```bash
# From workstation:
scp -i ~/.ssh/claude_admin claude_admin@192.168.202.90:/tmp/topic-manager.csr C:\Temp\
```

3. Submit to internal CA (on `192.168.202.6`, domain-joined machine):
```powershell
# In PowerShell on a domain-joined machine:
certreq -submit -config "int-CL-CA\int-CL-CA" -attrib "SAN:dns=kafka-topics.int.crypticlight.com" C:\Temp\topic-manager.csr C:\Temp\topic-manager.crt
```
   Or use the web interface at `http://192.168.202.6/certsrv`.

4. Copy the signed cert back:
```bash
scp -i ~/.ssh/claude_admin C:\Temp\topic-manager.crt claude_admin@192.168.202.90:/tmp/
sudo cp /tmp/topic-manager.crt /etc/topic-manager/tls/server.crt
sudo chmod 640 /etc/topic-manager/tls/server.crt /etc/topic-manager/tls/server.key
sudo chown root:topic-manager /etc/topic-manager/tls/server.crt /etc/topic-manager/tls/server.key
```

### Option B — Self-signed (testing only)

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/topic-manager/tls/server.key \
  -out    /etc/topic-manager/tls/server.crt \
  -subj   "/CN=kafka-topics.int.crypticlight.com"
sudo chmod 640 /etc/topic-manager/tls/server.*
sudo chown root:topic-manager /etc/topic-manager/tls/server.*
```

### Verify nginx accepts the cert:
```bash
sudo nginx -t
```
Expected: `syntax is ok` and `test is successful`

---

## 7. Active Directory Setup

### 7a. Create the Kafka-Admins group (if it doesn't exist)

In Active Directory Users and Computers (ADUC) on a domain-joined machine:
1. Right-click the `Users` container → New → Group
2. Group name: `Kafka-Admins`
3. Group scope: Global
4. Group type: Security
5. Click OK

Or via PowerShell:
```powershell
New-ADGroup -Name "Kafka-Admins" -GroupScope Global -GroupCategory Security `
  -Description "Members can access Jarvis Topic Manager"
```

### 7b. Add users to the group
```powershell
Add-ADGroupMember -Identity "Kafka-Admins" -Members "jrodman"
```

### 7c. Verify the service account `svc-kafka-ui` exists

The account needs:
- Read access to AD (Domain Users is sufficient)
- Password set to never expire recommended (service account)

```powershell
# Check:
Get-ADUser -Identity "svc-kafka-ui"

# Create if missing:
New-ADUser -Name "svc-kafka-ui" -SamAccountName "svc-kafka-ui" `
  -UserPrincipalName "svc-kafka-ui@int.crypticlight.com" `
  -AccountPassword (ConvertTo-SecureString "YourPassword" -AsPlainText -Force) `
  -PasswordNeverExpires $true -Enabled $true `
  -Description "Topic Manager LDAP bind account (read-only)"
```

### 7d. Join the TopicManager VM to the AD domain

SSH into the VM and run the following. You will be prompted for the AD admin password once.

```bash
ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90

# Confirm the domain is reachable before joining
sudo realm discover int.crypticlight.com
# Expected output includes: configured: no  (means not yet joined)

# Join the domain — prompts for AD admin password
sudo realm join -U claude.admin int.crypticlight.com
```

**After joining, patch sssd.conf** so AD usernames work without the `@domain` suffix and home directories are created automatically:

```bash
# Remove any existing duplicate keys first, then append correct values
sudo sed -i '/use_fully_qualified_names/d' /etc/sssd/sssd.conf
sudo sed -i '/fallback_homedir/d'          /etc/sssd/sssd.conf
echo "use_fully_qualified_names = False"   | sudo tee -a /etc/sssd/sssd.conf
echo "fallback_homedir = /home/%u"         | sudo tee -a /etc/sssd/sssd.conf

# Restart sssd and enable automatic homedir creation
sudo systemctl restart sssd
sudo pam-auth-update --enable mkhomedir

# Verify — should return UID/GID info for your AD account
id jrodman
```

Expected `id` output looks like:
```
uid=xxxxxx(jrodman) gid=xxxxxx(domain users) groups=xxxxxx(domain users),xxxxxx(kafka-admins),...
```

**Common failure causes for `realm join`:**
| Error | Fix |
|---|---|
| `realm: Couldn't join realm: Insufficient permissions` | Wrong password, or account doesn't have join rights |
| `realm: Couldn't join realm: Failed to enroll machine` | Clock skew >5 min vs DC — run `sudo chronyc makestep` |
| `realm: Couldn't join realm: No such realm found` | DNS can't resolve DC — check `/etc/resolv.conf` points to `192.168.202.5` |

---

## 8. Start and Verify Services

```bash
# Start the application backend
sudo systemctl start topic-manager
sudo systemctl status topic-manager
# Expected: Active: active (running)

# Restart nginx (picks up new site config)
sudo systemctl restart nginx
sudo systemctl status nginx
# Expected: Active: active (running)

# Quick health check (backend directly)
curl http://127.0.0.1:5001/api/health
# Expected: {"status":"ok","version":"1.0.0"}

# Health check through nginx (HTTPS)
curl -sk https://localhost/api/health
# Expected: {"status":"ok","version":"1.0.0"}
```

If `topic-manager` fails to start:
```bash
journalctl -u topic-manager -n 50 --no-pager
```

Common failures:
- **YAML parse error** — check `/etc/topic-manager/config.yaml` syntax
- **ImportError** — venv packages missing, re-run `install.sh`
- **Permission denied on /opt/topic-manager/data/** — `sudo chown topic-manager:topic-manager /opt/topic-manager/data`

---

## 9. First Login Test

From any browser on the `int.crypticlight.com` network:

1. Navigate to `https://kafka-topics.int.crypticlight.com`
2. Accept the TLS warning if using self-signed cert (or trust the internal CA)
3. Sign in with your AD credentials (user must be in `Kafka-Admins`)
4. Verify the Topics tab loads and shows your Kafka topics

If login fails with "Invalid credentials or insufficient permissions":
```bash
# Test LDAP bind manually on the server:
ldapwhoami -H ldaps://dc1.int.crypticlight.com:636 \
  -D "svc-kafka-ui@int.crypticlight.com" \
  -W -x
```
- `-W` prompts for the bind password
- Success output: `dn:CN=svc-kafka-ui,...`
- Failure: `ldap_bind: Invalid credentials (49)` → wrong password in config

---

## 10. Post-Install: CORTEX Button

The CORTEX Jarvis tab already has a "⚡ Topic Manager ↗" button added to its view bar. The URL is currently set to `https://kafka-topics.int.crypticlight.com`.

If the hostname differs, update it in CORTEX:
```bash
# On honey (CORTEX dev host):
grep -n "kafka-topics" /var/www/cortex/app/components/JarvisTab.js
# Edit the href to match your actual FQDN
sudo nano /var/www/cortex/app/components/JarvisTab.js
```
No backend restart needed — it's a frontend-only change.

---

## 11. Firewall

```bash
# Allow SSH (already open), HTTP (for redirect), and HTTPS
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

The gunicorn port (5001) is bound to `127.0.0.1` only — no firewall rule needed.

---

## 12. Prometheus Monitoring (Optional)

The Topic Manager does not ship its own exporter. Monitor it via:

```bash
# Add to prometheus.yml on your monitoring stack (.202.80):
  - job_name: 'topic-manager'
    metrics_path: '/api/health'
    scheme: https
    tls_config:
      insecure_skip_verify: true
    static_configs:
      - targets: ['192.168.202.90']
```

For process-level metrics, consider deploying `node_exporter` on the VM (standard pattern).

---

## 13. Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| 502 Bad Gateway | `journalctl -u topic-manager -n 30` | gunicorn crashed — check traceback |
| Login fails (valid creds) | `ldapwhoami` test (Section 9) | Wrong bind DN/password in config |
| Topics tab empty | Kafka broker connectivity | `nc -zv broker1.int.crypticlight.com 9092` |
| "Not a member of required group" | Check AD group DN | Run `Get-ADGroup Kafka-Admins \| Select DistinguishedName` |
| TLS cert error in browser | Check cert SANs | Reissue cert with correct SANs |
| nginx 404 on /api/ | Proxy config | `sudo nginx -t` and check error log |
| DB permission error | `/opt/topic-manager/data/` ownership | `sudo chown -R topic-manager:topic-manager /opt/topic-manager/data` |

**Useful log commands:**
```bash
# Application
journalctl -u topic-manager -f
tail -f /opt/topic-manager/logs/error.log

# nginx
tail -f /var/log/nginx/topic-manager-error.log

# Test connectivity
curl -sk https://localhost/api/health | python3 -m json.tool
curl -sk https://localhost/api/version | python3 -m json.tool
```

---

## 14. Offline Install Procedure

### On internet-connected machine (Linux/WSL/Mac):

```bash
cd /c/Users/jrodm/Scripts/topic-manager   # or wherever the repo lives
bash prepare-offline.sh --bundle
# Creates: topic-manager-offline-1.0.0.tar.gz
```

### Transfer to air-gapped host:

```bash
scp -i ~/.ssh/claude_admin \
  topic-manager-offline-1.0.0.tar.gz \
  claude_admin@192.168.202.90:/tmp/
```

### On the air-gapped host:

```bash
cd /tmp
tar xzf topic-manager-offline-1.0.0.tar.gz
cd topic-manager
sudo bash install.sh
# Script detects offline mode and uses install/packages/
```

Continue from Section 5 (Configure the Application).

---

## 15. Upgrading

When a new version of Topic Manager is released:

```bash
# 1. On workstation — pull new version:
cd /c/Users/jrodm/Scripts/topic-manager
git pull origin main

# 2. SCP to server:
scp -i ~/.ssh/claude_admin -r \
  /c/Users/jrodm/Scripts/topic-manager \
  claude_admin@192.168.202.90:/tmp/topic-manager-new

# 3. On server — run install (non-destructive — does not overwrite config):
ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90
cd /tmp/topic-manager-new
sudo bash install.sh

# 4. Restart services:
sudo systemctl restart topic-manager
sudo systemctl reload nginx

# 5. Verify:
curl -sk https://localhost/api/health
```

The config at `/etc/topic-manager/config.yaml` is **never overwritten** by the install script.

---

*End of Installation Guide*
*Jarvis Topic Manager v1.0.0 — Copyright (c) 2025-2026 James Rodman*
