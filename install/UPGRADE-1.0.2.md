# Topic Manager — Upgrade Guide: v1.0.0 / v1.0.1 → v1.0.2

## Overview

v1.0.2 is a security patch release. It fixes 5 security findings (3 HIGH, 2 MED, 1 LOW) from a third-party review, corrects 2 pre-existing bugs exposed when the security fixes were applied, and upgrades all third-party dependencies with available patches.

**No schema changes. No config migration required beyond the additions documented below.**

---

## What Changed

### Security Fixes

| Severity | Component | Finding | Fix |
|---|---|---|---|
| HIGH | `auth.py` | LDAPS used `CERT_NONE` — no certificate validation | Changed to `CERT_REQUIRED`. System CA trust store used by default; configurable via `ldap_ca_cert`. |
| HIGH | `auth.py` | Single-phase user bind — service account not used for search | Two-phase bind: service account searches directory, user DN re-bound to verify password. Falls back to direct bind if service credentials are absent/placeholder. |
| HIGH | `routes.py` | `force=True` on `get_json()` bypassed Content-Type enforcement | Removed on all routes. Added `_parse_json_body()` helper returning 415 on wrong Content-Type. |
| HIGH | `routes.py` | No cross-site request guard on mutation routes | `Sec-Fetch-Site: cross-site` blocked in `require_auth` for all non-GET methods. |
| HIGH | `routes.py` | Topic config accepted arbitrary keys and unvalidated integer inputs | `_ALLOWED_TOPIC_CONFIGS` allowlist; partitions bounded 1–1,000; RF bounded 1–9; `int()` wrapped with error handling. |
| MED | `app.py` | Random per-process secret key if config missing — gunicorn workers diverge | Startup raises `RuntimeError` if `secret_key` is absent or still the placeholder. |
| MED | `audit.py` | Hand-built CSV vulnerable to formula injection and quote escaping bugs | Replaced with `csv.writer`; formula-leading chars (`=`, `+`, `-`, `@`) prefixed with `'`. |
| LOW | nginx | CSP lacked `base-uri`, `form-action`, `frame-ancestors` | All three added; `X-Frame-Options` removed (superseded by `frame-ancestors 'none'`). |

### Bugs Fixed (discovered during security fix rollout)

| Component | Bug | Fix |
|---|---|---|
| nginx | Security headers silently absent on all routes — `location /` and `location ~*.js\|css` each had `add_header Cache-Control` which cancels all server-block `add_header` directives in nginx. Pre-existing since v1.0.0. | Created `/etc/nginx/snippets/tm-security-headers.conf`; included in all three location blocks. |
| `index.html` | Inline `<script>` block blocked by the now-enforced CSP (`script-src 'self'` — no `unsafe-inline`). Was invisible before because headers were never actually served. | Moved app bootstrap to `app/main.js`; cache-bust token bumped to `?v=1001`. |
| `kafka_client.py` | Consumer group STABLE/EMPTY stat cards showed 0 after confluent-kafka upgrade — `ConsumerGroupState.STABLE.name` returns `'STABLE'` in 2.14.0 vs `'Stable'` in 2.6.1. | Normalised with `.title()` at API layer. |
| `AboutModal.js` | Third-party version table hardcoded v1.0.0 package versions. App version also hardcoded. | Package versions updated; app version now fetched live from `/api/version` on mount. |

### Dependency Updates

| Package | From | To |
|---|---|---|
| Flask | 3.1.0 | 3.1.3 |
| gunicorn | 23.0.0 | 26.0.0 |
| Werkzeug | 3.1.3 | 3.1.8 |
| confluent-kafka | 2.6.1 | 2.14.0 |
| Vue.js | 3.5.13 | 3.5.35 |
| ldap3 | 2.9.1 | 2.9.1 (latest) |
| PyYAML | 6.0.2 | 6.0.2 (latest) |
| cryptography | 44.0.2 | 44.0.2 (latest) |

---

## Prerequisites

- Running Topic Manager v1.0.0 or v1.0.1
- Root / sudo access on the target host
- Internet access **or** an offline bundle prepared with `prepare-offline.sh`

---

## Running the Upgrade

> **IMPORTANT — do not run `install.sh` on an existing deployment.**  
> `install.sh` is for **fresh installs only**. Running it on a server that already has Topic Manager will rsync over your backend files and (due to the `--delete` flag) may delete `lib/vue.global.prod.js` from the server. Always use `install/upgrade-1.0.2.sh` to upgrade.

### Online (internet-connected host)

```bash
# 1. Clone the repo onto the target server (or pull latest if already cloned)
git clone https://github.com/ymxplusb/Topic-Manager.git
cd Topic-Manager

# 2. Run the upgrade script
sudo bash install/upgrade-1.0.2.sh
```

### Offline (air-gapped)

**Step 1 — on an internet-connected machine:**
```bash
bash prepare-offline.sh --bundle
# Creates: topic-manager-offline-1.0.2.tar.gz
```

**Step 2 — transfer the bundle to the target host:**
```bash
scp topic-manager-offline-1.0.2.tar.gz user@target:/tmp/
```

**Step 3 — on the target host:**
```bash
cd /tmp && tar xzf topic-manager-offline-1.0.2.tar.gz
sudo bash topic-manager/install/upgrade-1.0.2.sh
```

The script auto-detects online vs offline mode. In offline mode it uses:
- `install/packages/python/` — pip wheels (Flask, Werkzeug, gunicorn, confluent-kafka)
- `lib/vue.global.prod.js` — bundled Vue 3.5.35

---

## Post-Upgrade Steps

### 1. Verify LDAPS certificate validation

LDAPS now enforces `CERT_REQUIRED`. The DC certificate must be trusted by the system CA store:

```bash
openssl s_client -connect dc1.int.crypticlight.com:636 \
  -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>&1 | grep -E 'Verify|subject'
# Expected: Verify return code: 0 (ok)
```

If this fails, add the CA certificate to the system trust store:
```bash
sudo cp your-internal-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

Or point directly to it in `/etc/topic-manager/config.yaml`:
```yaml
auth:
  ldap_ca_cert: "/etc/topic-manager/tls/internal-ca.crt"
```

### 2. Verify LDAP service account bind

The new two-phase bind uses a read-only service account. Check `/etc/topic-manager/config.yaml`:

```yaml
auth:
  ldap_bind_dn: "CN=svc-kafka-bind,OU=ICLServiceAccounts,DC=int,DC=crypticlight,DC=com"
  ldap_bind_password: "<service-account-password>"
```

- If `ldap_bind_password` is `CHANGE_ME`, the app falls back to direct user bind (same as v1.0.0 behaviour).
- If a real password is set, verify the account's actual AD Distinguished Name — the DN must match exactly.
- Test the bind:
  ```bash
  ldapsearch -H ldaps://dc1.int.crypticlight.com:636 \
    -D "CN=svc-kafka-bind,OU=ICLServiceAccounts,DC=int,DC=crypticlight,DC=com" \
    -w "<password>" -b "DC=int,DC=crypticlight,DC=com" "(sAMAccountName=*)" sAMAccountName
  ```

### 3. Verify security headers on all routes

```bash
curl -skI https://localhost/ | grep -i content-security-policy
curl -skI https://localhost/api/health | grep -i content-security-policy
# Both should return the CSP header
```

### 4. Hard-refresh browsers

The cache-bust token changed from `?v=1000` to `?v=1001`. All users should `Ctrl+Shift+R` once after the upgrade to clear cached JS components.

---

## Rollback

The script backs up all modified files to `/opt/topic-manager/backup-pre-1.0.2/` before making changes.

**Manual rollback:**
```bash
sudo systemctl stop topic-manager
sudo cp /opt/topic-manager/backup-pre-1.0.2/auth.py         /opt/topic-manager/tm/auth.py
sudo cp /opt/topic-manager/backup-pre-1.0.2/app.py          /opt/topic-manager/tm/app.py
sudo cp /opt/topic-manager/backup-pre-1.0.2/routes.py       /opt/topic-manager/tm/routes.py
sudo cp /opt/topic-manager/backup-pre-1.0.2/audit.py        /opt/topic-manager/tm/audit.py
sudo cp /opt/topic-manager/backup-pre-1.0.2/kafka_client.py /opt/topic-manager/tm/kafka_client.py
sudo cp /opt/topic-manager/backup-pre-1.0.2/topic-manager.nginx.bak /etc/nginx/sites-available/topic-manager
sudo cp /opt/topic-manager/backup-pre-1.0.2/index.html.bak  /var/www/topic-manager/index.html
echo "<original-version>" | sudo tee /opt/topic-manager/tm/VERSION
sudo systemctl start topic-manager
sudo nginx -t && sudo systemctl reload nginx
```

**vCSA rollback** (if snapshot was taken before upgrade):
```bash
# Via govc on the management workstation:
govc snapshot.revert -vm=TopicManager "pre-v1.0.2-security-patch"
```

---

## Verification Checklist

After upgrade, confirm all of the following:

- [ ] `curl -sk https://<host>/api/health` returns `{"status":"ok","version":"1.0.2"}`
- [ ] Login with AD credentials succeeds
- [ ] Consumer Groups tab shows correct STABLE/EMPTY counts (not 0)
- [ ] About modal shows v1.0.2 and updated package versions
- [ ] `curl -skI https://<host>/` includes `content-security-policy` header
- [ ] `curl -skI https://<host>/api/health` includes `content-security-policy` header
- [ ] No browser console errors on page load
- [ ] `openssl s_client` LDAPS verify returns code 0

---

## Troubleshooting

### "Network error — is the server reachable?" on login

This error means the browser got no response or a non-JSON response from `/api/auth/login`. The backend is down or restarting.

```bash
# Check service status
sudo systemctl status topic-manager

# Check last 50 lines of gunicorn output
sudo journalctl -u topic-manager -n 50 --no-pager

# Confirm backend responds (returns JSON)
curl -sk https://localhost/api/health
```

**Most common causes:**

1. **`secret_key` is still the placeholder** — The v1.0.2 `app.py` fails-closed if `server.secret_key` in `/etc/topic-manager/config.yaml` is absent or contains `CHANGE_ME`. Generate and set a real key:
   ```bash
   python3 -c "import secrets; print(secrets.token_hex(32))"
   # Paste the output into /etc/topic-manager/config.yaml → server.secret_key
   sudo systemctl restart topic-manager
   ```

2. **Service was stopped mid-test** — The upgrade script stops the service for ~10 seconds. If you tested login during that window, nginx returned a 502 HTML page which the browser treated as a network error. Try again after confirming the service is `active (running)`.

3. **Import error at startup** — Check `journalctl -u topic-manager -n 50` for a Python traceback. If present, the patched files may be corrupt; restore from the backup:
   ```bash
   sudo cp /opt/topic-manager/backup-pre-1.0.2/auth.py    /opt/topic-manager/tm/auth.py
   sudo cp /opt/topic-manager/backup-pre-1.0.2/app.py     /opt/topic-manager/tm/app.py
   sudo cp /opt/topic-manager/backup-pre-1.0.2/routes.py  /opt/topic-manager/tm/routes.py
   sudo systemctl restart topic-manager
   ```

---

### "User not found in directory" on login

The service account bound successfully, but the directory search returned no matching user. This is **not** an LDAPS certificate issue.

**Most common cause: wrong username format.** The login field expects your AD `sAMAccountName` (e.g. `james.rodman`), not a display name (`james`), email prefix, or UPN (`james.rodman@int.crypticlight.com` also works — the `@domain` suffix is stripped automatically).

To find your SAMAccountName:
```bash
# Run on the Topic Manager host (uses the configured service account)
sudo /opt/topic-manager/venv/bin/python3 - << 'EOF'
import ssl, yaml
from ldap3 import Server, Connection, ALL, SIMPLE, Tls
with open('/etc/topic-manager/config.yaml') as f:
    cfg = yaml.safe_load(f)
auth = cfg['auth']
tls  = Tls(validate=ssl.CERT_REQUIRED)
srv  = Server(auth['ldap_server'], get_info=ALL, tls=tls, use_ssl=True)
conn = Connection(srv, user=auth['ldap_bind_dn'], password=auth['ldap_bind_password'],
                  authentication=SIMPLE, auto_bind=True)
conn.search('DC=int,DC=crypticlight,DC=com', '(objectClass=user)',
            attributes=['sAMAccountName', 'displayName'])
for e in conn.entries:
    if e.memberOf or True:
        print(str(e.sAMAccountName).ljust(30), str(e.displayName))
conn.unbind()
EOF
```

**Service account bind failure** — If the bind itself fails (LDAP error rather than "User not found"), the `ldap_bind_password` in `/etc/topic-manager/config.yaml` may be wrong or still set to `CHANGE_ME`. In that case auth falls back to direct user bind — verify the fallback works with:
```bash
ldapsearch -H ldaps://dc1.int.crypticlight.com:636 \
  -D "james.rodman@int.crypticlight.com" -W \
  -b "DC=int,DC=crypticlight,DC=com" "(sAMAccountName=james.rodman)"
```

---

### Upgrade script dies at firewall step

Symptom: script exits with `ufw: invalid option` or similar after the pip install step.

The `ufw --quiet allow <port>` syntax requires `--quiet` **before** the subcommand. This was a bug in install.sh prior to this patch; upgrade-1.0.2.sh was never affected. If running a fresh install from a clone taken before 2026-05-29, update install.sh or open the ports manually:
```bash
sudo ufw --quiet allow 80/tcp
sudo ufw --quiet allow 443/tcp
```

---

### lib/vue.global.prod.js missing (fresh install only)

`lib/vue.global.prod.js` is excluded from the git repository (binary vendor file). On a fresh `git clone`, the `lib/` directory will not exist.

- **Online install:** install.sh now automatically downloads Vue.js from the CDN before the rsync step. No action needed.
- **Offline install:** run `prepare-offline.sh --bundle` on an internet-connected machine first; the bundle includes the lib file.
