# Jarvis Topic Manager — Installation Guide

**Version:** 1.0.6
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

# 5. Do you WANT a service account for LDAP bind? (OPTIONAL)
#   The default is a direct user bind, which needs no account at all.
#   If you prefer a service account: svc-kafka-ui@int.crypticlight.com
#   (read-only, Domain Users). Create it in ADUC first. See Section 5.
#   Leave ldap_bind_dn / ldap_bind_password EMPTY to skip it entirely.

# 6. Is polkit installed? (it is, on a stock Ubuntu Server 24.04)
ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90 \
  "systemctl is-active polkit; pkaction --version"
#   Expected: active / pkaction version 124
#   Without it, only the Settings restart control is affected.
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
# Root runs install.sh out of this tree, so it is moved to a root-owned parent
# and given to root before anything reads it.
sudo install -d -m 700 -o root -g root /opt/topic-manager-src
sudo cp -a /tmp/topic-manager-src/. /opt/topic-manager-src/
sudo chown -R root:root /opt/topic-manager-src
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
4. Creates the two directories the application is allowed to write inside the configuration
   and data trees: `/etc/topic-manager/clusters.d/` (`topic-manager:topic-manager 0750`) and
   `/opt/topic-manager/data/cluster-certs/` (`topic-manager:topic-manager 0700`).
   `/etc/topic-manager` itself stays `root:topic-manager 0750` — see 5b below for why
5. Creates Python virtual environment at `/opt/topic-manager/venv`
6. Installs Python packages (Flask, gunicorn, ldap3, confluent-kafka, PyYAML, cryptography)
7. Copies backend to `/opt/topic-manager/tm/`
8. Copies frontend to `/var/www/topic-manager/`
9. Installs the default config to `/etc/topic-manager/config.yaml` (with auto-generated secret key)
10. Runs the cluster-profile migration (`tm/migrate_clusters.py`): installs the example
    profiles at `/etc/topic-manager/clusters.d/clusters.yaml`, or — on a reinstall over an
    older host — moves the existing `clusters:` block out of `config.yaml`. Idempotent
11. Installs the systemd units: `topic-manager.service` and the on-demand
    `topic-manager-nginx-test.service`
12. Installs `/etc/polkit-1/rules.d/50-topic-manager.rules` for the Settings restart control.
    If `/etc/polkit-1/rules.d` is absent the installer warns and carries on
13. Installs the nginx site config
14. **Does NOT start services yet** — you must configure first

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
  ldap_ca_cert: ""         # blank = system trust store; set to CA PEM path if cert not trusted
  ldap_domain: "int.crypticlight.com"
  ldap_base_dn: "DC=int,DC=crypticlight,DC=com"
  # OPTIONAL. Leave BOTH empty for the default direct user bind, which needs no
  # AD service account. If you set them they must WORK — from v1.0.2 onward every
  # login is gated on this bind succeeding.
  ldap_bind_dn: "CN=svc-kafka-ui,OU=ICLServiceAccounts,DC=int,DC=crypticlight,DC=com"
  ldap_bind_password: "THE_ACTUAL_PASSWORD_FOR_svc-kafka-ui"
  required_group: "CN=Kafka-Admins,CN=Users,DC=int,DC=crypticlight,DC=com"
```

> **There is no `clusters:` block in this file any more.** Since v1.0.4 cluster profiles
> live in `/etc/topic-manager/clusters.d/clusters.yaml`. A `clusters:` block added back here
> is ignored. See 5a below.

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

### 5a. Cluster profiles

The installer has already written a starter file:

```bash
sudo cat /etc/topic-manager/clusters.d/clusters.yaml
```

Edit the brokers to match your environment. The normal route is the **Cluster Builder** in
the UI (Settings → Cluster Profiles → **+ Add Cluster** / **Edit** / **Delete**), which
validates the profile, writes the file atomically, and records the change in the audit log.
Changes take effect immediately — every gunicorn worker re-reads the file when it changes,
so no restart is required.

Editing by hand is supported. Put the ownership back afterwards, because an editor that
replaces the file leaves it root-owned and the next save from the UI would then fail:

```bash
sudo nano /etc/topic-manager/clusters.d/clusters.yaml
sudo chown topic-manager:topic-manager /etc/topic-manager/clusters.d/clusters.yaml
sudo chmod 640 /etc/topic-manager/clusters.d/clusters.yaml
python3 -c "import yaml; yaml.safe_load(open('/etc/topic-manager/clusters.d/clusters.yaml'))" \
  && echo "YAML valid"
```

For `SSL` and `SASL_SSL` clusters, supply the CA bundle, client certificate and client key
through the Cluster Builder as **PEM content** — the form's file picker reads the file in
your browser and posts its text. The API does not accept a path, and will not store one you
choose: the server parses the PEM, writes it under `/opt/topic-manager/data/cluster-certs/`
with a name it generates, and refuses on load any profile whose TLS paths resolve outside
that directory. The reason is in README.md → *Cluster profiles*: the cluster test returns
the Kafka driver's error verbatim, and any authenticated user can export the audit log, so a
user-supplied path would be a file-read oracle over files the service can read — including
`config.yaml`.

The annotated reference for this file is `config/clusters.yaml.example` in the source tree.

### 5b. Why the configuration is split across two files

`config.yaml` holds `secret_key`, `ldap_bind_password` and `required_group`. The service
must read it and must never write it, so it is `root:topic-manager 0640` in a directory that
is `root:topic-manager 0750`.

The Cluster Builder needs a file it *can* rewrite, and rewriting a file safely means creating
a temporary file beside it and renaming over the target — which needs write permission on the
**directory**. And a directory the application can write is a directory in which it can
**unlink** files it cannot write: unlink is a directory operation, and the target file's own
mode and owner do not enter into it. Had `/etc/topic-manager` been made writable, the
application could
delete `config.yaml`, write its own with its own `required_group`, and restart the service
with the Settings control to load it — a full takeover of the authentication configuration,
using nothing but supported features. This was measured on the host.

So the writable directory is `clusters.d/`, one level below a parent that stays root-owned.
The systemd unit's `ReadWritePaths` names `/etc/topic-manager/clusters.d` and deliberately
not its parent. Confirm the boundary at any time:

```bash
sudo -u topic-manager test -w /etc/topic-manager             && echo "WRITABLE — WRONG" || echo "not writable (correct)"
sudo -u topic-manager test -w /etc/topic-manager/config.yaml && echo "WRITABLE — WRONG" || echo "not writable (correct)"
sudo -u topic-manager test -r /etc/topic-manager/config.yaml && echo "readable (correct)"
sudo -u topic-manager test -w /etc/topic-manager/clusters.d  && echo "writable (correct)"
systemctl show topic-manager --property=ReadWritePaths
```

### 5c. What the install grants the service account

Three systemd unit/verb pairs, through polkit, and nothing else:

| Unit | Verbs |
|---|---|
| `topic-manager.service` | `restart` |
| `nginx.service` | `reload`, `restart` |
| `topic-manager-nginx-test.service` | `start` |

No `stop`, no `kill`. The rule
(`/etc/polkit-1/rules.d/50-topic-manager.rules`) only ever returns `YES` for those
combinations and leaves every other subject and action untouched. Who used the control is
recorded in the application audit log (`SERVICE_RESTART`); that the rule is in force at all
is confirmed from the polkit journal, which reports every load and every rule that fails to
compile:

```bash
ls -l /etc/polkit-1/rules.d/50-topic-manager.rules
sudo journalctl -u polkit -n 5 --no-pager
# "Finished loading, compiling and executing N rules" — N includes this file
```

`topic-manager-nginx-test.service` is a root-side `Type=oneshot` running `nginx -t`. It
exists because the check could not otherwise fail: `nginx -t` run as the `topic-manager`
account dies on `open() "/run/nginx.pid" failed (13: Permission denied)` and exits 1 whether
the configuration is good or bad, and `systemctl reload nginx` runs `nginx -s reload`, which
exits 0 whether or not the master accepts the config. Both measured on the live host. The
unit reads configuration, writes nothing, is never enabled, and only runs when the restart
control starts it.

Why polkit rather than sudoers: the unit sets `NoNewPrivileges=true`, under which `sudo`
refuses to run at all. `systemctl` over D-Bus works because the caller never escalates — it
asks PID 1 to act — so polkit, not sudo, is the mechanism that fits the hardening as it
stands.

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

### 7c. Verify the service account `svc-kafka-ui` exists (OPTIONAL)

Skip this entirely if you left `ldap_bind_dn` / `ldap_bind_password` empty — the direct user
bind authenticates and enforces `required_group` without any service account.

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
# Expected: {"status":"ok","version":"1.0.6"}

# Health check through nginx (HTTPS)
curl -sk https://localhost/api/health
# Expected: {"status":"ok","version":"1.0.6"}
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
| Settings → Restart Services reports *Interactive authentication required* | Is the polkit rule installed? `ls -l /etc/polkit-1/rules.d/50-topic-manager.rules` | Install it from the source tree and check `sudo journalctl -u polkit -n 5` shows a reload |
| Cluster Builder save fails | `sudo -u topic-manager test -w /etc/topic-manager/clusters.d` | `sudo chown -R topic-manager:topic-manager /etc/topic-manager/clusters.d`; confirm `ReadWritePaths` includes it |
| A cluster is shown as disabled | Its TLS paths resolve outside `/opt/topic-manager/data/cluster-certs/` | Re-upload the certificates through the Cluster Builder |
| Certificate rejected on save | Is the file really PEM? `openssl x509 -in ca.pem -noout -subject` | Convert DER to PEM, or export the correct file. Private keys must be unencrypted PEM |
| No clusters listed at all | `sudo cat /etc/topic-manager/clusters.d/clusters.yaml` | Re-run the migration (Section 15) |

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
cd /path/to/topic-manager                 # wherever the repo is checked out
bash prepare-offline.sh --bundle
# Creates: topic-manager-offline-1.0.6.tar.gz  (named from VERSION)
```

### Transfer to air-gapped host:

```bash
scp -i ~/.ssh/claude_admin \
  topic-manager-offline-1.0.6.tar.gz \
  claude_admin@192.168.202.90:/tmp/
```

### On the air-gapped host:

```bash
# root runs install.sh, so the tree it runs from is created root-owned first and
# the bundle is unpacked straight into it — never staged in /tmp, where the
# directory would be created by whichever account got there first.
sudo install -d -m 700 -o root -g root /var/lib/topic-manager/install-src
sudo tar xzf /tmp/topic-manager-offline-1.0.6.tar.gz   -C /var/lib/topic-manager/install-src --strip-components=1
sudo bash /var/lib/topic-manager/install-src/install.sh
# Script detects offline mode and uses install/packages/
```

Continue from Section 5 (Configure the Application).

---

## 15. Upgrading

There is **one** upgrade path: `install/upgrade-full.sh`. It applies to every version — it
upgrades whatever is installed (including 1.0.0) to whatever the source tree it fetches
declares in `tm/VERSION`, so there is no per-release upgrade script to find.

> **Do not run `install.sh` on a host that already has Topic Manager.**
> `install.sh` uses `rsync -a --delete` on the backend and frontend directories: it removes
> anything there that is not in the source tree. Earlier editions of this guide gave exactly
> that as the "general procedure for future versions" — that instruction was wrong, and it
> is why this section now describes the upgrade script instead.

### Online (target has internet)

```bash
ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90

# 1. The script is obtained by cloning the repo. The upgrade fetches its own copy
#    of the target source later, in Phase 5 — this clone only supplies the script.
sudo apt-get install -y git
# NOT /tmp: root executes this script. A local account that pre-creates the
# directory owns what root then runs out of it, and `git clone` into an
# existing empty directory succeeds without noticing who made it.
sudo install -d -m 700 -o root -g root /var/lib/topic-manager/upgrade-src
sudo git clone https://github.com/ymxplusb/Topic-Manager.git   /var/lib/topic-manager/upgrade-src
cd /var/lib/topic-manager/upgrade-src

# 2. Audit. Changes nothing. Exit 0 = clear, 1 = warnings, 2 = blockers.
sudo bash install/upgrade-full.sh --audit-only

# 3. Take the vCSA snapshot NOW, then a verified restore point.
sudo bash install/upgrade-full.sh --backup-only
sudo bash install/upgrade-full.sh --list-backups

# 4. Upgrade. Rolls back automatically on any failure.
sudo bash install/upgrade-full.sh
```

**Upgrading to v1.0.4 or later** additionally moves cluster profiles out of `config.yaml`
into `/etc/topic-manager/clusters.d/clusters.yaml` (Phase 11), and installs the polkit rule
and the `topic-manager-nginx-test` unit (Phase 9). The upgrade then **measures** the
permission boundary as the `topic-manager` principal and fails if the application can write
`config.yaml` or its directory. Verify afterwards:

```bash
# Profiles moved, old block gone (the grep should print nothing)
sudo cat /etc/topic-manager/clusters.d/clusters.yaml
sudo grep -n '^clusters:' /etc/topic-manager/config.yaml

# Ownership the application needs
sudo ls -ld /etc/topic-manager /etc/topic-manager/clusters.d \
            /etc/topic-manager/clusters.d/clusters.yaml \
            /opt/topic-manager/data/cluster-certs

# The restart control
ls -l /etc/polkit-1/rules.d/50-topic-manager.rules
systemctl cat topic-manager-nginx-test.service >/dev/null && echo "test unit installed"
```

The migration is idempotent and can be re-run by hand if it was skipped — for example on a
host that was restored from a backup taken before the upgrade:

```bash
sudo install -d -m 750 -o topic-manager -g topic-manager /etc/topic-manager/clusters.d
sudo env PYTHONPATH=/opt/topic-manager /opt/topic-manager/venv/bin/python3 \
  -m tm.migrate_clusters \
  --config /etc/topic-manager/config.yaml \
  --clusters-dir /etc/topic-manager/clusters.d
sudo chown topic-manager:topic-manager /etc/topic-manager/clusters.d/clusters.yaml
sudo chmod 640 /etc/topic-manager/clusters.d/clusters.yaml
```

It prints what it did (`moved N cluster profile(s) ...`), or `already migrated` and changes
nothing. It preserves the comments in `config.yaml`, and refuses to report success if the
`clusters:` key survives the rewrite.

If **neither** file carries a profile it stops with `neither ... carries any cluster
profile, and no example was given` and writes nothing — an empty cluster list would leave
every topic and consumer-group view unresolvable. Add
`--example /var/lib/topic-manager/upgrade-src/config/clusters.yaml.example` (a path in the *source*
tree; the example is not deployed to the host) to install the starter profiles instead.

Do not skip step 2. The blockers it reports are the failures that otherwise appear an hour
after an apparently successful upgrade — an unset `server.secret_key`, an LDAP service bind
that the previous version ignored and the new one gates every login on, a DC certificate
that is not trusted, or assets the web user cannot read.

Useful flags: `--dry-run` (audit and plan only), `--skip-os` (application and dependencies
only, no `apt`), `--force` (proceed past blockers; the backup is still taken first),
`--list-backups`, `--restore <TIMESTAMP>`.

### Offline (air-gapped target)

The bundle is built where there **is** a network, then carried across. The target path is
fixed — the script reads the bundle from `/var/lib/topic-manager/offline-src` and nowhere else.

```bash
# On the internet-connected machine, in the repo:
cd /path/to/topic-manager
bash prepare-offline.sh --bundle
# Downloads a wheel for every pin in requirements.txt and verifies each one is present,
# fetches Vue and checks it against the SHA-256 the target will check, then writes
# topic-manager-offline-<version>.tar.gz one directory above the repo.

scp -i ~/.ssh/claude_admin ../topic-manager-offline-<version>.tar.gz \
  claude_admin@192.168.202.90:/tmp/

ssh -i ~/.ssh/claude_admin claude_admin@192.168.202.90 "
  sudo install -d -m 700 -o root -g root /var/lib/topic-manager/offline-src
  sudo tar xzf /tmp/topic-manager-offline-<version>.tar.gz     -C /var/lib/topic-manager/offline-src --strip-components=1
  sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --offline
"
```

- The tarball wraps everything in a directory named after the repo checkout, which is what
  `--strip-components=1` removes. `Offline source not found at /var/lib/topic-manager/offline-src`
  is what a skipped extraction looks like; a tree with a `topic-manager/` directory inside it
  is what a *forgotten* `--strip-components=1` looks like, and the run stops on the missing
  `tm/VERSION`.
- The bundle is **not** deleted on success. An air-gapped host cannot fetch another one, and
  a re-upgrade after a `--restore` needs it.
- `--offline` implies no OS patching — `apt` has no repository to reach. Patch the OS from
  your own mirror separately.

### Rolling back

```bash
sudo bash install/upgrade-full.sh --list-backups
sudo bash install/upgrade-full.sh --restore <TIMESTAMP>
```

Restore points live in `/var/backups/topic-manager/<TIMESTAMP>/`, with a `.tar.gz` of the
same tree beside them. Each one carries the config, the cluster store (`etc/clusters.d/` and
`data/cluster-certs/`), the TLS key and certificate, a consistent database snapshot, the
venv, the nginx config, the systemd unit **and its drop-in directory**, and a recorded
permission baseline, all covered by a `SHA256SUMS` that `--restore` verifies before it
restores anything.

Neither configuration file is overwritten by an upgrade. `/etc/topic-manager/config.yaml`
and `/etc/topic-manager/clusters.d/` are backed up in Phase 4 and put back in Phase 10 —
the cluster store deliberately *before* the migration runs in Phase 11, so an existing set
of profiles is never replaced by the example — along with the ownership and modes they had.

---

*End of Installation Guide*
*Jarvis Topic Manager v1.0.6 — Copyright (c) 2025-2026 James Rodman*
