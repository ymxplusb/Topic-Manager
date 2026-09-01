# Troubleshooting — Topic Manager

Diagnosis procedures for installation, upgrade and runtime failures.

Upgrades are run by `install/upgrade-full.sh`. It is **version-agnostic** — there is no
"expected installed version" gate — and it audits the host, takes a verified backup, and
rolls back by itself if a phase fails. Every message quoted below is a string that script
actually prints; the transcript of any run is kept at
`/var/log/topic-manager-upgrade-<TIMESTAMP>.log`.

---

## First: establish what is actually installed

```bash
cat /opt/topic-manager/tm/VERSION
curl -sk https://localhost/api/health
sudo bash install/upgrade-full.sh --list-backups
```

The deployed version is whatever `/api/health` reports, not whatever the repo says. A host
that was reverted to a VM snapshot can be several releases behind while the repo, the
CHANGELOG and everyone's memory say otherwise.

---

## The audit refuses to pass

`--audit-only` exits **0** clear, **1** warnings only, **2** blockers present. Each finding
below is printed as a `BLOCK` row and must be cleared before the upgrade will run
(`--force` overrides, and says so in the log — the verified backup is still taken first).

### `server.secret_key  unset in the unit environment and in config.yaml`
The application refuses to start without one. Older versions silently generated a random
key **per gunicorn worker**, so sessions were valid on one worker and rejected by the next;
that fail-open is gone.

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
sudo nano /etc/topic-manager/config.yaml     # server.secret_key: "<the value>"
```

Changing the key invalidates every existing session cookie. That is expected.

### `server.secret_key  placeholder value (from config)`
The config still contains `CHANGE_ME`. Same remediation.

### `server.secret_key  could not be resolved: ...`
The resolver itself failed, so the check has proven **nothing** — it is reported as a
blocker rather than a pass for that reason. Fix the error it printed and re-run.

Note that the value may not be in `config.yaml` at all. `TM_SECRET_KEY` and
`TM_LDAP_BIND_PASSWORD` override the file at runtime, and the script resolves them the way
the service will: the unit's `Environment=` and `EnvironmentFile=` (drop-ins included)
first, then the shell, then `config.yaml`. To see what the unit contributes:

```bash
systemctl show topic-manager --property=DropInPaths --property=Environment --property=EnvironmentFiles
sudo systemctl cat topic-manager
```

### `LDAP service bind  bind rejected (bad DN, bad password, or both)`
**This is the classic upgrade trap and the most likely cause of a post-upgrade outage.**

v1.0.0's `auth.py` has no service-bind logic — it binds directly as the user, so a wrong
`ldap_bind_dn` sits in the config being ignored and every login works. Later versions treat
a configured bind DN plus a non-placeholder password as "use the service bind" and gate
**every** login on it succeeding. A stale DN that has been harmless for months becomes a
total authentication outage the moment the new code starts.

Confirm by hand:
```bash
ldapwhoami -H ldaps://YOUR-DC:636 \
  -D "$(sudo grep ldap_bind_dn /etc/topic-manager/config.yaml | awk -F'"' '{print $2}')" \
  -w "YOUR-SERVICE-ACCOUNT-PASSWORD" -x 2>&1
# dn:CN=...                                     the bind works
# ldap_bind: Invalid credentials (49) ... 52e    wrong password
```

Either correct the DN and password in `/etc/topic-manager/config.yaml`, or blank
`ldap_bind_dn` / `ldap_bind_password` to keep direct user bind.

### `LDAP service bind  NOT CHECKED — ...` (reported as WARN)
The probe did not run — `ldap3` was not importable in the interpreter used, or the probe
exited non-zero. This is deliberately **not** reported as a pass: nothing about the bind is
known. Verify it by hand with `ldapwhoami` as above before upgrading.

### `LDAPS certificate trust`
The new version enforces `CERT_REQUIRED` on the LDAPS connection. See
[LDAPS certificate errors](#ldaps-certificate-errors) below.

### `www-data cannot read index.html` / `cannot read the Vue bundle`
nginx would return 403 on every page while the service itself looks perfectly healthy. This
is the umask-077 class: assets deployed under a hardened umask land 0700 and the web user
cannot read them. Mode bits can also look correct while a parent directory or an ACL still
denies, so ask the kernel as the real principal:

```bash
sudo -u www-data test -r /var/www/topic-manager/index.html && echo OK || echo DENIED
sudo chmod -R u+rwX,go+rX /var/www/topic-manager
```

### `topic-manager cannot read config.yaml` / `cannot execute the venv` / `cannot write data`
Same class, service account side. The service would not start, or would fail to write the
audit log.

```bash
sudo chown -R topic-manager:topic-manager /opt/topic-manager/{data,logs}
sudo chmod 640 /etc/topic-manager/config.yaml
sudo chown root:topic-manager /etc/topic-manager/config.yaml
```

### `no executable temp directory`
`/tmp` is mounted `noexec` **and** the fallback build directory could not execute either.
pip cannot build. Mount an exec-capable path or set `TMPDIR` to one for the run.

### `immutable attribute set`
`chattr -i` the path named in the row. The upgrade writes there and cannot.

### `fapolicyd active`
Execution allowlisting will block the new venv's binaries. Add a rule for
`/opt/topic-manager/venv` or stop the daemon for the duration of the run.

---

## The run stops before anything is changed

These all happen in Phases 1–4, before a single file is replaced. The install is untouched.

| Message | What to do |
|---|---|
| `Refusing to upgrade with N unresolved blocker(s)` | Clear the blockers above. A verified backup was still taken and its path is printed |
| `Config not found at /etc/topic-manager/config.yaml` | This is not a Topic Manager host, or the config was moved |
| `Service account topic-manager does not exist` | Same — the upgrade will not create an install where there was none. Use `install.sh` for a fresh host |
| `Less than 1 GB free on /opt` (or `/tmp`, `/var`) | Free space. The venv, the backup and the venv archive all need room |
| `Required tool missing: <tool>` | Install it; the script will not improvise around a missing dependency |
| `Backup checksum verification failed — refusing to proceed` | The backup tree does not match its own `SHA256SUMS`. Investigate the disk before upgrading anything |
| `Backup archive is unreadable — refusing to proceed` | Same, for the `.tar.gz` |
| `config.yaml missing from backup` / `TLS private key missing from backup` | The backup is incomplete. Do not proceed — there would be nothing to restore from |
| `Unit drop-in ... did not reach the backup` | A file in `/etc/systemd/system/topic-manager.service.d/` was not captured. It may hold `TM_SECRET_KEY`; a restore without it returns a service that refuses to start |
| `requirements.txt has no pin for: X` / `pins X, which no Phase 8 install stage handles` | `requirements.txt` in the source tree and the install stages disagree. Fix the file — do not pin by hand on the host |
| `requirements.txt: 'X' is not an exact == pin` | Every dependency must be pinned exactly, or the offline bundle and the online install cannot be the same thing |

---

## The run fails partway through

The script rolls back automatically: it stops the service, restores config, database, TLS
material, the unit drop-in, the frontend, the venv and the recorded ownership and modes from
the backup it verified in Phase 4, then reports the health of what it restored. Read the log
before doing anything by hand.

### `git clone failed`
```bash
curl -s https://github.com >/dev/null && echo OK
```
If the host is air-gapped, use the offline procedure in README.md → *Offline (air-gapped)
upgrade*. The bundle must be at `/var/lib/topic-manager/offline-src`.

### `Offline source not found at /var/lib/topic-manager/offline-src`
The bundle is somewhere else. That path is fixed; the script does not search for it. The
tarball extracts to a directory named after the repo checkout, so it has to be moved:

```bash
sudo install -d -m 700 -o root -g root /var/lib/topic-manager/offline-src
sudo tar xzf topic-manager-offline-<version>.tar.gz -C /tmp
sudo mv /tmp/topic-manager/* /var/lib/topic-manager/offline-src/
```

### `Offline install needs /var/lib/topic-manager/offline-src/install/packages/python`
The bundle was transferred without its wheels. Re-run `prepare-offline.sh` on the networked
machine — it verifies that every pin in `requirements.txt` has a matching wheel before it
declares the bundle good, so a bundle that passes there cannot fail here for this reason.

### `venv creation failed — lib/pythonX.Y/site-packages/ not present`
Disk filled during venv creation.
```bash
df -h /opt
sudo rm -rf /opt/topic-manager/venv
```
Then re-run the upgrade — do not hand-build the venv; the script installs into it from the
source tree's `requirements.txt`.

### `pip install of the web stack failed` / `of ldap3/PyYAML/cryptography failed`
```bash
df -h /opt /tmp
curl -s https://pypi.org >/dev/null && echo OK
```
To reproduce it by hand, install exactly what the source tree pins — never a version you
remember:
```bash
sudo /opt/topic-manager/venv/bin/pip install -r /tmp/topic-manager-upgrade/requirements.txt
```

### `confluent-kafka install failed` (WARN, not fatal)
The application starts without it; Kafka operations return errors until it is resolved. It
is installed last for exactly this reason.

### `Vue integrity check FAILED` / `Bundled Vue hash mismatch`
The bytes fetched from the CDN, or carried in the bundle, are not the ones pinned in
`install/upgrade-full.sh`. **Do not work around this by deploying the file anyway** — the
pin is a content hash and it is the only integrity control on that script. Re-run
`prepare-offline.sh`, which fetches and verifies against the same pin.

### `N effective-access check(s) failed after deployment`
The service is running but nginx cannot read what it serves, or the service account cannot
write its own runtime. See the `www-data cannot read` remediation above; the failing
principal, flag and path are all named in the log.

### `N security header(s) not served`
nginx discards **all** inherited `add_header` directives the moment a child `location`
declares its own, which silently drops every security header on the HTML/JS/CSS surface
while `/api/*` keeps them. Every location must include the snippet:

```bash
grep -n "tm-security-headers" /etc/nginx/sites-available/topic-manager
curl -skI https://localhost/ | grep -i -E "strict-transport|content-security|x-content-type|referrer"
curl -skI https://localhost/lib/vue.global.prod.js | grep -i content-security
```
Reading the config proves nothing here — the headers must be proven *served*, per route
class.

### `Version mismatch: API reports X, expected Y`
The deployment succeeded but the running code is not the code that was deployed. Almost
always a stale gunicorn process:
```bash
sudo systemctl restart topic-manager
curl -sk https://localhost/api/version
```

### `Health check failed: ...`
```bash
sudo journalctl -u topic-manager -n 50 --no-pager
```
Common causes are in the next section. The backup is intact at the path printed by the
script, and `--restore <TIMESTAMP>` will put it back.

---

## Service starts but login fails

### "Network error — is the server reachable?"
The browser got no response or a non-JSON response from `/api/auth/login`. The backend is
down.
```bash
sudo systemctl status topic-manager
sudo journalctl -u topic-manager -n 30 --no-pager
curl -sk https://localhost/api/health
```

**Most common cause: `secret_key` is absent or still the placeholder.** The app refuses to
start rather than sign sessions with a per-worker random key:
```bash
sudo grep secret_key /etc/topic-manager/config.yaml
# and the environment, which overrides the file:
systemctl show topic-manager --property=Environment --property=DropInPaths

SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sudo sed -i "s/CHANGE_ME_GENERATE_A_RANDOM_SECRET/$SECRET/" /etc/topic-manager/config.yaml
sudo systemctl restart topic-manager
```

### "User not found in directory"
The service account bound successfully but the LDAP search returned no results.

1. The login name must be the AD `sAMAccountName` — not display name, not email.
2. List them from the host, using the service account in the config:
```bash
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
Two possible sources.

**Service account bind failing** — the password for `ldap_bind_dn` is wrong:
```bash
ldapwhoami -H ldaps://YOUR-DC:636 \
  -D "$(sudo grep ldap_bind_dn /etc/topic-manager/config.yaml | awk -F'"' '{print $2}')" \
  -w "YOUR-SERVICE-ACCOUNT-PASSWORD" -x 2>&1
```
Fix it in the config and restart, or bypass the service account entirely and fall back to
direct user bind:
```bash
sudo sed -i 's/ldap_bind_password:.*/ldap_bind_password: "CHANGE_ME"/' /etc/topic-manager/config.yaml
sudo systemctl restart topic-manager
```

**User password wrong** — confirm the service account works with `ldapwhoami` first, then
have the user confirm their AD password.

### "Not a member of required group"
The account authenticated but is not in the group named by `required_group`.
```bash
sudo grep required_group /etc/topic-manager/config.yaml
```
Add the user to that group in AD. Membership changes take a few minutes to propagate.

---

## LDAPS certificate errors

### "LDAP error: ... certificate verify failed"
The DC's certificate is not trusted by the system CA store, and certificate validation is
enforced.

```bash
openssl s_client -connect YOUR-DC:636 \
  -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>&1 | grep "Verify return code"
# Expected: Verify return code: 0 (ok)
```
If it is not `0 (ok)`, import the internal CA:
```bash
sudo cp your-internal-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
sudo systemctl restart topic-manager
```
Or point at the CA file directly in `/etc/topic-manager/config.yaml`:
```yaml
auth:
  ldap_ca_cert: "/etc/topic-manager/tls/internal-ca.crt"
```

---

## After an upgrade

### Hard-refresh browsers
The JS cache-bust tokens change with every release. `Ctrl+Shift+R`.

### Check what is installed against what was pinned
The upgrade installs exactly the pins in the source tree's `requirements.txt` and prints the
full `pip freeze` at the end of the run. To compare a live host:

```bash
sudo /opt/topic-manager/venv/bin/pip freeze > /tmp/live.txt
diff <(sort /tmp/topic-manager-upgrade/requirements.txt | grep '==') <(sort /tmp/live.txt)
```

> **Do not pin a package by hand on the host.** Installing a version you remember —
> `pip install "confluent-kafka==2.14.0"`, for example — silently *downgrades* a correctly
> upgraded host, and the next upgrade will quietly put it back, so the symptom appears to
> come and go. If a pin is wrong, change `requirements.txt` and re-run the upgrade; that
> file is the single source of truth for both the online install and the offline bundle.

### Compare permissions before and after
Every run records both, in the backup it took:
```bash
diff /var/backups/topic-manager/<TIMESTAMP>/manifest/permissions.baseline \
     /var/backups/topic-manager/<TIMESTAMP>/manifest/permissions.after
```
An empty diff means the upgrade widened nothing.

---

## Rollback

**Fastest — vCSA snapshot**: revert the VM to the snapshot taken before the upgrade. Use
this if the host itself is in doubt.

**From a restore point** — this is the supported path:
```bash
sudo bash install/upgrade-full.sh --list-backups
# 20260830-141205  v1.0.0  412M  verified OK  perms recorded

sudo bash install/upgrade-full.sh --restore 20260830-141205
```
It verifies the backup's `SHA256SUMS` before restoring from it, refuses to restore a backup
that fails that check, puts back the recorded ownership and modes, and then reports the
health of what it restored.

**By hand**, if the script cannot run at all. A restore point is laid out as:
```
/var/backups/topic-manager/<TIMESTAMP>/
  etc/config.yaml                    etc/tls/{server.crt,server.key}
  etc/extra-certs/                   data/tm.db  data/tm.consistent.db
  app/tm/  app/wsgi.py               frontend/
  system/topic-manager.service       system/topic-manager.service.d/
  system/topic-manager.nginx         system/tm-security-headers.conf
  system/logrotate-topic-manager     venv.tar.gz
  manifest/state.env                 manifest/permissions.baseline
  SHA256SUMS
```
```bash
BACKUP=/var/backups/topic-manager/20260830-141205
( cd "$BACKUP" && sha256sum -c --quiet SHA256SUMS ) || echo "BACKUP IS NOT INTACT"

sudo systemctl stop topic-manager
sudo cp -a "$BACKUP/etc/config.yaml"  /etc/topic-manager/config.yaml
sudo cp -a "$BACKUP/data/tm.consistent.db" /opt/topic-manager/data/tm.db
sudo cp -a "$BACKUP/system/topic-manager.service" /etc/systemd/system/
sudo cp -a "$BACKUP/system/topic-manager.service.d" /etc/systemd/system/   # if present
sudo cp -a "$BACKUP/system/topic-manager.nginx" /etc/nginx/sites-available/topic-manager
sudo tar -xzf "$BACKUP/venv.tar.gz" -C /opt/topic-manager
sudo systemctl daemon-reload && sudo systemctl start topic-manager
```
Then re-apply the recorded ownership and modes from
`manifest/permissions.baseline` (`path|owner|group|mode`, one per line) before declaring it
done.

---

## Diagnostic command reference

```bash
# Service status
sudo systemctl status topic-manager --no-pager
sudo journalctl -u topic-manager -n 50 --no-pager

# What the unit really contributes to the environment (drop-ins included)
sudo systemctl cat topic-manager
systemctl show topic-manager --property=DropInPaths --property=Environment

# Health and version
curl -sk https://localhost/api/health | python3 -m json.tool
curl -sk https://localhost/api/version

# Security headers, per route class — not by reading the config
for p in / /index.html /lib/vue.global.prod.js /api/health; do
  echo "== $p"; curl -skI "https://localhost$p" | grep -i -E "strict-transport|content-security|x-content-type|referrer"
done

# Effective access, asked of the kernel as the real principal
sudo -u www-data      test -r /var/www/topic-manager/index.html && echo OK || echo DENIED
sudo -u topic-manager test -r /etc/topic-manager/config.yaml    && echo OK || echo DENIED

# nginx config test and YAML syntax
sudo nginx -t
sudo /opt/topic-manager/venv/bin/python3 \
  -c "import yaml; yaml.safe_load(open('/etc/topic-manager/config.yaml'))" && echo OK

# Installed packages and imports
sudo /opt/topic-manager/venv/bin/pip freeze
sudo /opt/topic-manager/venv/bin/python3 -c "import flask, werkzeug, gunicorn, ldap3, yaml, cryptography; print('OK')"

# Upgrade transcripts and restore points
ls -t /var/log/topic-manager-upgrade-*.log | head
sudo bash install/upgrade-full.sh --list-backups

# Disk
df -h /opt /tmp /var
```
