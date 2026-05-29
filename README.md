# Topic Manager — Upgrade v1.0.0 → v1.0.2

**Clean reinstall upgrade package.**

This branch contains only the upgrade script and supporting documentation. It does not contain application source code — that is fetched from the main repository at runtime.

---

## What this upgrade does

Rather than patching files in-place, `upgrade.sh` takes a backup-uninstall-reinstall-restore approach:

1. Verifies v1.0.0 is installed and healthy
2. Backs up your config, audit database, and TLS certificates to a timestamped directory
3. Stops and completely removes v1.0.0 (venv, code, nginx config, systemd unit)
4. Clones v1.0.2 from GitHub and performs a clean install
5. Restores your config, audit data, and certificates exactly as they were
6. Applies the one config migration v1.0.2 requires (`ldap_ca_cert` field)
7. Starts services and verifies health
8. Prints a post-upgrade checklist of what to verify manually

If anything fails the script stops immediately. Your v1.0.0 installation is preserved in the backup directory, and a vCSA snapshot (if taken beforehand) provides a full rollback path.

---

## Prerequisites

| Requirement | Detail |
|------------|--------|
| Installed version | Topic Manager v1.0.0 — verified by `/api/health` returning `"version":"1.0.0"` |
| vCSA snapshot | **Take one before running.** If the upgrade fails mid-run the snapshot is the fastest rollback. |
| Root / sudo | Required — `sudo bash upgrade.sh` |
| Internet access | Required for online mode. For air-gapped hosts see [Offline Install](#offline-install) below. |
| Disk space | 500 MB free in `/tmp` and `/opt` |

---

## Quick Start

**Step 1 — Take a vCSA snapshot** of the Topic Manager VM before doing anything else.

**Step 2 — On the Topic Manager host:**

```bash
# Install git if not present
sudo apt-get install -y git

# Clone this upgrade branch
git clone --branch upgrade/v1.0.0-to-v1.0.2 \
  https://github.com/ymxplusb/Topic-Manager.git \
  /tmp/topic-manager-upgrade
cd /tmp/topic-manager-upgrade

# Run the upgrade
sudo bash upgrade.sh
```

The script prints phase-by-phase progress. A successful run ends with:
```
══════════════════════════════════════════════════════
  Topic Manager upgraded to v1.0.2
══════════════════════════════════════════════════════
```

**Step 3 — Follow the post-upgrade checklist** printed at the end of the run.

---

## After the Upgrade

### Verify health
```bash
curl -sk https://localhost/api/health
# Expected: {"status":"ok","version":"1.0.2"}
```

### Verify LDAPS certificate (new in v1.0.2)
v1.0.2 enforces TLS certificate validation on the LDAPS connection. Run:
```bash
openssl s_client -connect YOUR-DC:636 \
  -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>&1 | grep "Verify return code"
# Expected: Verify return code: 0 (ok)
```
If the code is not 0, import your internal CA into the system store:
```bash
sudo cp your-internal-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
sudo systemctl restart topic-manager
```

### Verify login
Open the application in a browser and log in with your AD `sAMAccountName` (e.g. `firstname.lastname`). If you used UPN format (`user@domain.com`) in v1.0.0 that still works — the `@domain` suffix is stripped automatically.

### Hard-refresh browsers
JavaScript cache tokens changed in v1.0.2. All users should press `Ctrl+Shift+R` once.

---

## What changed

See [CHANGELOG.md](CHANGELOG.md) for the full list of security fixes, bug fixes, and dependency updates.

---

## Rollback

**Fast rollback — vCSA snapshot** (recommended):
Revert the VM to the snapshot taken before the upgrade. This is instantaneous and requires no manual steps.

**Manual rollback — from backup**:
```bash
# The backup directory is printed at the end of a run, e.g.:
BACKUP=/opt/topic-manager-backup-20260529-152300

sudo systemctl stop topic-manager

# Restore config and database
sudo cp ${BACKUP}/config.yaml /etc/topic-manager/config.yaml
sudo cp ${BACKUP}/tm.db       /opt/topic-manager/data/tm.db

# Restore original nginx config
sudo cp ${BACKUP}/nginx-topic-manager.conf /etc/nginx/sites-available/topic-manager

# Reinstall v1.0.0 from your original source and restart
```

---

## Offline Install

On an internet-connected machine with the v1.0.2 application repo:

```bash
# 1. Clone the application repo
git clone https://github.com/ymxplusb/Topic-Manager.git
cd Topic-Manager

# 2. Build the offline bundle (packages + Vue.js)
bash prepare-offline.sh --bundle
# → creates topic-manager-offline-1.0.2.tar.gz

# 3. Transfer to the air-gapped host
scp topic-manager-offline-1.0.2.tar.gz user@target:/tmp/

# 4. Also transfer the upgrade scripts
git clone --branch upgrade/v1.0.0-to-v1.0.2 \
  https://github.com/ymxplusb/Topic-Manager.git \
  topic-manager-upgrade
tar czf topic-manager-upgrade.tar.gz topic-manager-upgrade/
scp topic-manager-upgrade.tar.gz user@target:/tmp/
```

On the air-gapped host:
```bash
cd /tmp
tar xzf topic-manager-offline-1.0.2.tar.gz   # → /tmp/topic-manager-offline-src/
tar xzf topic-manager-upgrade.tar.gz
cd topic-manager-upgrade
sudo bash upgrade.sh    # auto-detects offline source at /tmp/topic-manager-offline-src
```

---

## Files in this branch

| File | Purpose |
|------|---------|
| `upgrade.sh` | Main upgrade script |
| `README.md` | This file |
| `CHANGELOG.md` | What changed from v1.0.0 to v1.0.2 |
| `TROUBLESHOOTING.md` | Diagnosis and fix procedures |
| `SBOM.md` | Software Bill of Materials |
