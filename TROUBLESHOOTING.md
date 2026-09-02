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

# Which configuration layout is on the host
sudo ls -l /etc/topic-manager/clusters.d/clusters.yaml 2>/dev/null \
  || echo "pre-v1.0.4 layout: cluster profiles are still inside config.yaml"
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
# config.yaml is root-owned ON PURPOSE. The app reads it and must not be able to
# write or unlink it — do not "fix" a permission problem by giving it away.
sudo chown root:topic-manager /etc/topic-manager && sudo chmod 750 /etc/topic-manager
# The cluster store is the one thing the app does own:
sudo chown -R topic-manager:topic-manager /etc/topic-manager/clusters.d
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
sudo /opt/topic-manager/venv/bin/pip install -r /var/lib/topic-manager/upgrade-src/requirements.txt
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

## The restart control (Settings → Service Control)

### The button reports *Interactive authentication required*, or nothing happens

The polkit rule is not loaded. Without it, `systemctl` over D-Bus is refused by polkit — not
by the sandbox — and that message is polkit's.

```bash
# 1. Is the rule file even there?
ls -l /etc/polkit-1/rules.d/50-topic-manager.rules

# 2. Did polkitd load it? The count includes this file.
sudo journalctl -u polkit -n 20 --no-pager
# Sep 01 22:45:32 host polkitd[...]: Finished loading, compiling and executing 7 rules

# 3. Does the action exist at all (it does, on any systemd host)?
pkaction --action-id org.freedesktop.systemd1.manage-units --verbose
# implicit any: auth_admin  ← this is WHY a rule is needed: without one, an
#                             unattended service account can never be authorised
```

If the file is missing, install it from the source tree and confirm polkitd reloads:

```bash
cd /var/lib/topic-manager/upgrade-src        # a root-owned checkout of the source tree
sudo install -m 644 -o root -g root \
  install/polkit/50-topic-manager.rules /etc/polkit-1/rules.d/50-topic-manager.rules
sudo journalctl -u polkit -n 5 --no-pager     # a fresh "Finished loading ... N rules"
```

`polkitd` picks up a new rules file on its own. If the journal shows no reload,
`sudo systemctl restart polkit` — restarting it does not interrupt the application.

If the file is present but has no effect, look in that same journal — polkitd reports errors
in a rules file there. Nothing in the rule can *deny* anything: it returns `YES` for its
three unit/verb pairs and `NOT_HANDLED` for everything else, so a rule that is not in force
takes nothing else with it.

To ask whether the account is authorised **without restarting anything**, check against a
live process owned by that account:

```bash
sudo -u topic-manager sleep 20 &
sleep 1; PID=$(pgrep -u topic-manager -x sleep | head -1)
sudo pkcheck --action-id org.freedesktop.systemd1.manage-units \
  --detail unit topic-manager.service --detail verb restart --process "$PID"; echo "rc=$?"
```

`rc=0` is authorised. On a host without the rule this prints
`Authorization requires authentication and -u wasn't passed.` and `rc=2` — measured. Note
that `pkcheck --detail` must be run as **root**: run as `topic-manager` it fails with
*Only trusted callers ... can use CheckAuthorization() and pass details*, which is about the
caller, not about the rule.

### The restart is refused with "nginx -t did not pass"

Working as intended: the configuration test runs **first**, and a failing test refuses the
whole operation. Nothing was touched — nginx was not reloaded and the service was not
restarted. The refusal is in the audit log as `SERVICE_RESTART_REFUSED`.

```bash
sudo nginx -t                                   # the full diagnostic
sudo journalctl -u topic-manager-nginx-test -n 20 --no-pager
```

Fix the nginx configuration and try again.

### The restart is refused, but `sudo nginx -t` passes

The application does not run `nginx -t` itself — it starts
`topic-manager-nginx-test.service`, a root-side `Type=oneshot` unit, because `nginx -t` as
the `topic-manager` account always fails on `/run/nginx.pid` regardless of the
configuration. So check the unit, not the binary:

```bash
systemctl cat topic-manager-nginx-test.service          # is it installed at all?
sudo systemctl start topic-manager-nginx-test.service; echo "rc=$?"
sudo systemctl status topic-manager-nginx-test --no-pager
```

If the unit is missing, install it and reload systemd:

```bash
cd /var/lib/topic-manager/upgrade-src        # a root-owned checkout of the source tree
sudo install -m 644 -o root -g root \
  systemd/topic-manager-nginx-test.service /etc/systemd/system/
sudo systemctl daemon-reload
```

Do not "fix" this by making the application call `systemctl reload nginx` without the test.
`ExecReload` is `nginx -s reload`, which exits 0 whether or not the master accepts the new
configuration — a pre-check that cannot fail is not a pre-check.

### The restart is refused with "Another restart was requested less than 30 seconds ago"

Working as intended, and it is a **429** with a `Retry-After` header. Wait the number of
seconds the message gives and click again. The refusal is in the audit log as
`SERVICE_RESTART_THROTTLED`, with the user who asked.

The cooldown is not politeness. Both units carry systemd's defaults —
`StartLimitIntervalUSec=10s` and `StartLimitBurst=5` — so **five starts inside ten seconds
trips start limiting**, after which systemd refuses to start the unit at all until an
operator runs `systemctl reset-failed` **on the host**. Every authenticated user can reach
the restart control, so without a cooldown five clicks are a persistent outage of the
application and, with *Hard-restart nginx* ticked, of the web server that serves the control
you would use to fix it.

```bash
# what the limiter looks like on the units
systemctl show topic-manager -p StartLimitIntervalUSec -p StartLimitBurst
systemctl show nginx         -p StartLimitIntervalUSec -p StartLimitBurst

# the cooldown is enforced per HOST, not per worker: it is a row in the
# audit database, so all four gunicorn workers see the same claim
sudo /opt/topic-manager/venv/bin/python3 -c "import sqlite3;
print(sqlite3.connect('/opt/topic-manager/data/tm.db').execute(
  \"SELECT key, value FROM app_settings WHERE key='service_restart_last_epoch'\").fetchall())"
```

Do not "fix" this by setting `StartLimitBurst=0`. It only helps our own unit — `nginx.service`
is a shared system unit and this product has no business dropping overrides into it — and it
trades a wedged unit for an unbounded restart loop.

### `Failed to start topic-manager.service: Start request repeated too quickly`

Start limiting has already been tripped: usually by repeated restarts from outside the
application (a shell loop, a config edit cycle), because the control itself now refuses
faster than one restart per 30 seconds. systemd will not start the unit again until the
counter is cleared, and nothing in the application can clear it — the API is unreachable
precisely because the service is down.

```bash
systemctl status topic-manager --no-pager      # "start request repeated too quickly"
sudo systemctl reset-failed topic-manager.service
sudo systemctl start topic-manager.service
curl -sk https://localhost/api/health
```

If nginx is the unit that was wedged, the site returns *502 Bad Gateway* or refuses the
connection outright:

```bash
sudo systemctl reset-failed nginx.service
sudo nginx -t && sudo systemctl start nginx.service
```

`reset-failed` clears the counter only. It fixes nothing that made the unit fail, so if the
unit stops again immediately, read the journal before repeating it:

```bash
sudo journalctl -u topic-manager -n 50 --no-pager
```

### "The service DID NOT come back within 60 seconds"

The restart was accepted and the browser polled `/api/health` for 60 seconds without getting
an answer. The API answers 202 *before* the restart happens, so this message is about the
service, not about the request.

```bash
sudo systemctl status topic-manager nginx --no-pager
sudo journalctl -u topic-manager -n 50 --no-pager
curl -sk https://localhost/api/health
```

The usual causes are the ordinary start-up failures in *Service starts but login fails* and
*Health check failed* above — a config edit made just before the restart is the first thing
to check.

---

## The Cluster Builder (Settings → Cluster Profiles)

### Saving a cluster fails

The application writes `/etc/topic-manager/clusters.d/clusters.yaml` by creating a temporary
file in that directory and renaming over the target, so it needs **write on the directory**,
not just on the file. Two things can withdraw that: ownership, and the unit's
`ReadWritePaths`.

```bash
# Asked of the kernel as the real principal — mode bits can look right while an
# ACL or a parent directory still denies
sudo -u topic-manager test -w /etc/topic-manager/clusters.d && echo "writable (correct)" || echo DENIED
sudo ls -ld /etc/topic-manager /etc/topic-manager/clusters.d \
            /etc/topic-manager/clusters.d/clusters.yaml

systemctl show topic-manager --property=ReadWritePaths
# must include /etc/topic-manager/clusters.d
```

Expected:

```
drwxr-x--- root          topic-manager  /etc/topic-manager
drwxr-x--- topic-manager topic-manager  /etc/topic-manager/clusters.d
-rw-r----- topic-manager topic-manager  /etc/topic-manager/clusters.d/clusters.yaml
```

Repair:

```bash
sudo chown -R topic-manager:topic-manager /etc/topic-manager/clusters.d
sudo chmod 750 /etc/topic-manager/clusters.d
sudo chmod 640 /etc/topic-manager/clusters.d/clusters.yaml
```

The usual cause is a hand edit made as `root` with an editor that replaced the file.

> **Do not fix this by widening `/etc/topic-manager` or by adding it to `ReadWritePaths`.**
> A directory the application can write is a directory in which it can **unlink**
> `config.yaml` — unlink is a directory operation and the file's own 0640 does not prevent
> it — and `config.yaml` holds `secret_key`, `ldap_bind_password` and `required_group`.
> Chained with the restart control, that is a takeover of the authentication configuration.
> The parent staying `root:topic-manager 0750` is the control; `clusters.d` is the only
> exception, and it is a subdirectory precisely so it can be one. The upgrade script fails
> the upgrade if the application can write `config.yaml` or its directory.

### A certificate is rejected

The Cluster Builder posts certificate **content** and the server parses it before storing
anything. A rejection means the bytes are not what they claim to be — usually DER rather
than PEM, a certificate pasted into the key field, or an encrypted private key (only
unencrypted PEM keys are accepted, because the Kafka client is given the file, not a
passphrase).

Check the file before uploading it:

```bash
openssl x509 -in ca.pem     -noout -subject -issuer -dates   # CA / certificate
openssl pkey -in client.key -noout                           # private key, must be unencrypted
```

A non-PEM file fails as `Unable to load certificate`. Convert DER to PEM with
`openssl x509 -inform der -in cert.der -out cert.pem`. A CA *bundle* may hold a chain —
every block in it must parse, and one stray block fails the whole upload.

### A cluster is listed but marked disabled

Its `ssl_cafile` / `ssl_certfile` / `ssl_keyfile` resolve outside
`/opt/topic-manager/data/cluster-certs/`, so the profile was loaded with those paths
discarded and marked disabled. It stays visible and named — it is not deleted — but it is
never handed to the Kafka client, and every topic or consumer-group view through it refuses
with `Cluster <id> is disabled`.

This is what a hand-edited `clusters.yaml` looks like when someone pointed a certificate
field at an arbitrary file. The API cannot produce it: paths there are always generated by
the server inside the certificate directory.

```bash
sudo grep -n 'ssl_' /etc/topic-manager/clusters.d/clusters.yaml
sudo journalctl -u topic-manager | grep 'resolves outside'
```

Fix it by re-uploading the certificates through the Cluster Builder, which stores them where
they belong. Do not point the profile back at the original path.

### Cluster changes do not appear, or appear intermittently

They should be visible immediately: there are four gunicorn workers and each re-reads
`clusters.yaml` when its inode, size or mtime changes, with no restart and no IPC. A change
that shows up on *some* requests and not others is the signature of a worker that is not
re-reading — check the file really changed, then look for a stale process:

```bash
sudo stat -c '%n ino=%i size=%s mtime=%y' /etc/topic-manager/clusters.d/clusters.yaml
curl -sk https://localhost/api/version
sudo systemctl status topic-manager --no-pager | head -5
```

### The cluster list is empty, or "No cluster configured"

```bash
sudo cat /etc/topic-manager/clusters.d/clusters.yaml
sudo grep -n '^clusters:' /etc/topic-manager/config.yaml
```

- **New file missing, old block still in `config.yaml`** — the migration has not run. The
  application still works: it falls back to the `clusters:` block, read-only, and logs
  `does not exist; using the clusters: block still in config.yaml`. Run the migration (see
  *The cluster-profile migration* below).
- **Both present** — `clusters.yaml` wins and the block in `config.yaml` is **ignored**,
  with `config.yaml still carries a clusters: block; it is IGNORED` in the log. Two files
  claiming to hold the cluster list is the shadowing the split exists to prevent: delete the
  block from `config.yaml`, or re-run the migration, which removes it.
- **Neither present** — nothing resolves. Restore `clusters.yaml` from the most recent
  backup (`/var/backups/topic-manager/<TIMESTAMP>/etc/clusters.d/clusters.yaml`), or run the
  migration with `--example` as below.

---

## The cluster-profile migration

`tm/migrate_clusters.py` runs from **both** `install.sh` and `install/upgrade-full.sh`, and
is idempotent — a reinstall, an upgrade and a manual run all take the same path.

Run it by hand when a host reached the new code without it (typically after a restore from a
pre-v1.0.4 backup):

```bash
sudo install -d -m 750 -o topic-manager -g topic-manager /etc/topic-manager/clusters.d
sudo env PYTHONPATH=/opt/topic-manager /opt/topic-manager/venv/bin/python3 \
  -m tm.migrate_clusters \
  --config /etc/topic-manager/config.yaml \
  --clusters-dir /etc/topic-manager/clusters.d
sudo chown topic-manager:topic-manager /etc/topic-manager/clusters.d/clusters.yaml
sudo chmod 640 /etc/topic-manager/clusters.d/clusters.yaml
```

What it prints:

| Message | Meaning |
|---|---|
| `moved N cluster profile(s) out of config.yaml into ...` | It did the work |
| `removed the clusters: block from ...` | `config.yaml` was rewritten, comments preserved |
| `already migrated (N profile(s) in ...)` | Nothing to do. **This is a success**, not a warning |
| `clusters.yaml already holds N profile(s); the stale block in config.yaml is being removed` | Both files had a list. The new file wins; the dead block goes |
| `neither ... carries any cluster profile, and no example was given` | It refuses to write an empty list. Add `--example <source tree>/config/clusters.yaml.example` |
| `... STILL has a clusters: key after migration — refusing to report success` | The rewrite did not take. Do not carry on; check the file and the disk |
| `%s does not exist. The installer creates it with install(1)` | Create `clusters.d` first, with the `install -d` line above |

It edits `config.yaml` line by line rather than re-serialising it, so **your comments
survive**. It writes `clusters.yaml` before it rewrites `config.yaml`, and it copies the
original owner and mode onto the replacement — `os.replace` necessarily creates a new inode,
and a `config.yaml` that came back `0644 root:root` would be both a disclosure and a service
that cannot read its own secret. Confirm afterwards:

```bash
sudo ls -l /etc/topic-manager/config.yaml    # -rw-r----- root topic-manager
sudo grep -n '^clusters:' /etc/topic-manager/config.yaml   # no output
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
diff <(sort /var/lib/topic-manager/upgrade-src/requirements.txt | grep '==') <(sort /tmp/live.txt)
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
  etc/clusters.d/clusters.yaml       data/cluster-certs/
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
# The cluster store, if the backup was taken on v1.0.4 or later. cp -a keeps the
# topic-manager ownership; without it the Cluster Builder could not save.
if [ -d "$BACKUP/etc/clusters.d" ]; then
  sudo install -d -m 750 -o topic-manager -g topic-manager /etc/topic-manager/clusters.d
  sudo cp -a "$BACKUP/etc/clusters.d/." /etc/topic-manager/clusters.d/
fi
if [ -d "$BACKUP/data/cluster-certs" ]; then
  sudo install -d -m 700 -o topic-manager -g topic-manager /opt/topic-manager/data/cluster-certs
  sudo cp -a "$BACKUP/data/cluster-certs/." /opt/topic-manager/data/cluster-certs/
fi
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

# The permission boundary the cluster store depends on
sudo -u topic-manager test -w /etc/topic-manager/clusters.d  && echo "writable (correct)"      || echo DENIED
sudo -u topic-manager test -w /etc/topic-manager             && echo "WRITABLE — WRONG"        || echo "not writable (correct)"
sudo -u topic-manager test -w /etc/topic-manager/config.yaml && echo "WRITABLE — WRONG"        || echo "not writable (correct)"
systemctl show topic-manager --property=ReadWritePaths

# The restart control's authorisation
ls -l /etc/polkit-1/rules.d/50-topic-manager.rules
sudo journalctl -u polkit -n 5 --no-pager
pkaction --action-id org.freedesktop.systemd1.manage-units --verbose
systemctl cat topic-manager-nginx-test.service >/dev/null && echo "test unit installed"

# Cluster profiles
sudo cat /etc/topic-manager/clusters.d/clusters.yaml
sudo grep -n '^clusters:' /etc/topic-manager/config.yaml   # no output once migrated
sudo /opt/topic-manager/venv/bin/python3 \
  -c "import yaml; yaml.safe_load(open('/etc/topic-manager/clusters.d/clusters.yaml'))" && echo OK

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
