# Troubleshooting — Topic Manager Upgrade v1.0.0 → v1.0.2

---

## Upgrade script fails

### "Expected v1.0.0 installed, found: X"
The script only upgrades from v1.0.0. Check what is currently installed:
```bash
cat /opt/topic-manager/tm/VERSION
curl -sk https://localhost/api/health
```
If the version is already `1.0.2`, the upgrade completed on a previous run. If it is `unknown`, the application may not be installed at all.

### "v1.0.0 health check failed"
The existing service is not responding before the upgrade starts. Investigate the current state first — the upgrade will not proceed until v1.0.0 is healthy.
```bash
sudo systemctl status topic-manager
sudo journalctl -u topic-manager -n 30 --no-pager
curl -sk https://localhost/api/health
```
Restore from the vCSA snapshot if the service cannot be recovered.

### "git clone failed"
- Check internet access from the host: `curl -s https://github.com > /dev/null && echo OK`
- If air-gapped, use the offline procedure in README.md

### "pip install of Flask/Werkzeug/gunicorn failed"
1. Check disk space: `df -h /opt /tmp`
2. Check internet: `curl -s https://pypi.org > /dev/null && echo OK`
3. Try manually: `sudo /opt/topic-manager/venv/bin/pip install gunicorn==26.0.0`

### "venv creation failed — lib/pythonX.Y/site-packages/ not present"
Disk full during venv creation. Free space and re-run:
```bash
df -h /opt
# Free space, then:
sudo rm -rf /opt/topic-manager/venv
sudo python3 -m venv /opt/topic-manager/venv
ls /opt/topic-manager/venv/lib/
```

### "Health check failed after start"
The upgrade script's final health check failed. Get the error:
```bash
sudo journalctl -u topic-manager -n 50 --no-pager
```
Common causes — see sections below. The backup is still intact at the path printed by the script.

---

## Service starts but login fails

### "Network error — is the server reachable?"
The browser got no response or a non-JSON response from `/api/auth/login`. The backend is down.
```bash
sudo systemctl status topic-manager
sudo journalctl -u topic-manager -n 30 --no-pager
curl -sk https://localhost/api/health
```

**Most common cause: `secret_key` is still the placeholder.**
The v1.0.2 `app.py` refuses to start if `server.secret_key` is `CHANGE_ME`:
```bash
sudo grep "secret_key" /etc/topic-manager/config.yaml
# If it shows CHANGE_ME:
SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sudo sed -i "s/CHANGE_ME_GENERATE_A_RANDOM_SECRET/$SECRET/" /etc/topic-manager/config.yaml
sudo systemctl restart topic-manager
```

### "User not found in directory"
The service account bound successfully but the LDAP search returned no results.

1. The user's login name must be their AD `sAMAccountName` — not display name, not email.
2. Find the correct `sAMAccountName`:
```bash
# Run from the Topic Manager host using the service account from config
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
conn.search('DC=yourdomain,DC=com', '(objectClass=user)',
            attributes=['sAMAccountName', 'displayName'])
for e in conn.entries:
    print(str(e.sAMAccountName).ljust(30), str(e.displayName))
conn.unbind()
EOF
```

### "Invalid credentials"
The username/password combination was rejected. Two possible sources:

**Service account bind failing** — the password for `ldap_bind_dn` in config is wrong:
```bash
ldapwhoami -H ldaps://YOUR-DC:636 \
  -D "$(sudo grep ldap_bind_dn /etc/topic-manager/config.yaml | awk -F'"' '{print $2}')" \
  -w "YOUR-SERVICE-ACCOUNT-PASSWORD" -x 2>&1
```
- `dn:CN=...` = bind works, wrong password is not here
- `ldap_bind: Invalid credentials (49) ... data 52e` = wrong password in config

If the service account password is wrong, update it:
```bash
sudo nano /etc/topic-manager/config.yaml   # fix ldap_bind_password
sudo systemctl restart topic-manager
```

Or bypass the service account entirely (falls back to direct user bind, same as v1.0.0):
```bash
sudo sed -i 's/ldap_bind_password:.*/ldap_bind_password: "CHANGE_ME"/' /etc/topic-manager/config.yaml
sudo systemctl restart topic-manager
```

**User password wrong** — the user is typing the wrong password. Confirm the service account works with `ldapwhoami`, then have the user confirm their AD password.

### "Not a member of required group"
The user's account exists and authenticated, but they are not a member of the AD group specified in `required_group`.
```bash
sudo grep required_group /etc/topic-manager/config.yaml
```
Add the user to that group in Active Directory, then try logging in again. AD group membership changes may take a few minutes to propagate.

---

## LDAPS certificate errors

### "LDAP error: ... certificate verify failed"
The DC's TLS certificate is not trusted by the system CA store.

1. Verify:
```bash
openssl s_client -connect YOUR-DC:636 \
  -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>&1 | grep "Verify return code"
```
2. If not `0 (ok)`, import your internal CA:
```bash
sudo cp your-internal-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
sudo systemctl restart topic-manager
```
3. Or point directly to the CA file in config:
```bash
# In /etc/topic-manager/config.yaml:
auth:
  ldap_ca_cert: "/etc/topic-manager/tls/internal-ca.crt"
```

---

## After the upgrade

### Hard-refresh browsers
JS cache tokens changed in v1.0.2. Press `Ctrl+Shift+R` in the browser after upgrading.

### Consumer Groups tab shows 0 for STABLE/EMPTY
This is fixed in v1.0.2. If still seeing 0, verify confluent-kafka 2.14.0 is installed:
```bash
sudo /opt/topic-manager/venv/bin/pip show confluent-kafka
# Should show: Version: 2.14.0
```
If it shows an older version:
```bash
sudo /opt/topic-manager/venv/bin/pip install "confluent-kafka==2.14.0"
sudo systemctl restart topic-manager
```

---

## Rollback

**Fastest — vCSA snapshot** (recommended): revert the VM to the snapshot taken before the upgrade.

**Manual — from backup**:
```bash
BACKUP=/opt/topic-manager-backup-YYYYMMDD-HHMMSS  # printed by upgrade.sh

sudo systemctl stop topic-manager

sudo cp ${BACKUP}/config.yaml /etc/topic-manager/config.yaml
[[ -f ${BACKUP}/tm.db ]] && sudo cp ${BACKUP}/tm.db /opt/topic-manager/data/tm.db

# Restore original nginx config (v1.0.0 did not have the snippets)
sudo cp ${BACKUP}/nginx-topic-manager.conf /etc/nginx/sites-available/topic-manager
sudo rm -f /etc/nginx/snippets/tm-security-headers.conf
```
Then reinstall v1.0.0 from your original source and start the service.

---

## Diagnostic command reference

```bash
# Service status
sudo systemctl status topic-manager --no-pager
sudo journalctl -u topic-manager -n 50 --no-pager

# Health endpoint
curl -sk https://localhost/api/health | python3 -m json.tool

# nginx config test
sudo nginx -t

# Config YAML syntax
sudo /opt/topic-manager/venv/bin/python3 \
  -c "import yaml; yaml.safe_load(open('/etc/topic-manager/config.yaml'))" && echo OK

# Package check
sudo /opt/topic-manager/venv/bin/pip list | grep -E "gunicorn|flask|confluent|ldap"

# Import sanity
sudo /opt/topic-manager/venv/bin/python3 -c "import gunicorn, flask, ldap3; print('OK')"

# Disk space
df -h /opt /tmp /var
```
