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
| `Online upgrade, but no source repository was given.` | Since v1.1.0 the script has **no built-in source**. Pass the git URL your site publishes the release at — `--repo-url <url> [--repo-branch <tag>]`, or `TM_REPO_URL` / `TM_REPO_BRANCH` — or use `--offline` with a staged bundle. Printed in Phase 1, before any backup; `--audit-only`, `--dry-run` and `--backup-only` never fetch and are not refused |
| `--repo-url '...' is not an https://, ssh:// or git@ URL` / `--repo-branch '...' is not a branch or tag name` | The value is refused before it reaches `git clone`, including anything that starts with `-` |
| `Refusing to upgrade: config.yaml does not name its directory (...)` | See *The directory settings are missing* below. `--force` does **not** override this one |

### The directory settings are missing (`directory settings in config.yaml  missing: ...`)

Reported as a BLOCK by the audit, and a refusal by `install.sh` on a reinstall:
`/etc/topic-manager/config.yaml has no value for: ldap_server ldap_base_dn ldap_domain`.

Before v1.1.0, `tm/auth.py` filled `auth.ldap_server`, `ldap_base_dn` and `ldap_domain` in from
built-in defaults that belonged to one particular site, so a config that omitted them kept
working without anyone noticing. v1.1.0 has **no** directory defaults; upgrading such a host
unchanged would stop every sign-in. Add the keys with **your** directory's values, then re-run:

```yaml
auth:
  ldap_server:  "ldaps://dc1.example.org:636"
  ldap_base_dn: "DC=example,DC=org"
  ldap_domain:  "example.org"
```

A value still reading `<placeholder>` (as in `config/config.yaml.example`) counts as missing.
`--force` does not override this blocker: there is no host on which proceeding helps.

### `directory settings in config.yaml  could not be checked (...)`
The interpreter the audit uses (the service venv, else `python3`) could not read `config.yaml`
with PyYAML — a YAML error, or `python3` without `python3-yaml` on a host with no venv. Fix the
cause and re-run; it is not assumed to be fine.

### `tm.db mode  0644 — this upgrade sets tm.db 0600 and data/ 0700` (WARN)
Informational. Since v1.1.0 the audit database is private to the service account. The upgrade
narrows it in Phase 10 **after** replaying the recorded baseline (which, on a v1.0.x host,
records 0644), and Phase 12 measures the result.

### `nginx.conf ssl_protocols  TLSv1 TLSv1.1 TLSv1.2 TLSv1.3 — this upgrade removes TLSv1/TLSv1.1` (WARN)
Informational: stock Ubuntu enables TLS 1.0/1.1 at the http level. Phase 11 rewrites the line —
see *nginx.conf management* below.

---

## The run fails partway through

The script rolls back automatically: it stops the service, restores config, database, TLS
material, the unit drop-in, the frontend, the venv and the recorded ownership and modes from
the backup it verified in Phase 4, then reports the health of what it restored. Read the log
before doing anything by hand.

### `--repo-url needs --repo-commit <40-hex commit id>`
Online upgrades clone only the exact commit you name (round 2): a branch or tag can be moved on
the server, and root runs what is cloned. Take the full 40-character commit id of the release
from its release notes or the tag's CI pipeline — out of band, not from the same server you are
about to clone — and pass `--repo-commit <sha>` (or `TM_REPO_COMMIT`).

### `The cloned tree is commit '...', not the reviewed ...`
The branch or tag you named no longer points at the commit you named. Nothing from the clone
was read or run. Find out why before retrying — this is the check that stops a moved tag.

### `SQLite consistent snapshot failed — the restore point is NOT ready`
Round 2: a restore point without a consistent copy of the audit database is not a restore
point, so the upgrade stops before changing anything. Check free space under
`/var/backups/topic-manager` and that `tm.db` is readable, then re-run.

### `The backed-up Vue does not match the pinned SHA-256 ... — not used`
The CDN was unreachable and the previous install's Vue is a different version (or was changed).
Only the pinned file may serve. Stage the offline bundle (its `lib/` carries the pinned Vue) or
restore network access to the CDN.

### `git clone failed`
The clone is from the URL given with `--repo-url` (there is no default). Test it by hand, as
root, the same way:
```bash
sudo git ls-remote --heads <your-git-url>
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
- **`clusters: []` on a new install** — expected since v1.1.0. A fresh install starts with
  **no** cluster profiles (the example file is a format reference, never live clusters), and
  the Topics tab says `No cluster profile is configured yet. Add one in Settings > General >
  Cluster Profiles.` Add one there.
- **Neither present** — nothing resolves. Restore `clusters.yaml` from the most recent
  backup (`/var/backups/topic-manager/<TIMESTAMP>/etc/clusters.d/clusters.yaml`), or run the
  migration as below, which creates an empty store you then fill in Settings.

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
| `created an empty cluster store at ... — add clusters in Settings > General > Cluster Profiles` | A host with neither a store nor a `clusters:` block. Expected on a fresh install since v1.1.0; `--example` no longer exists |
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

## nginx.conf management (v1.1.0)

`install.sh` and the upgrade set every active `ssl_protocols` line in `/etc/nginx/nginx.conf`
to `ssl_protocols TLSv1.2 TLSv1.3; # managed by Topic Manager: TLS 1.2/1.3 only` (or add one
at the top of `http {`). The file is backed up first — `install.sh` to
`/var/backups/topic-manager/nginx.conf.before-install-<TS>`, the upgrade to
`<backup>/system/nginx.conf.before-tls-edit` (and the whole file is in the Phase 4 restore
point, which `--restore` and the automatic rollback put back).

| Message | Meaning |
|---|---|
| `nginx -t failed after setting ssl_protocols in /etc/nginx/nginx.conf, so the original was put back` | The edit itself broke the configuration (very unusual). The original is in place and nginx -t passes with it. The message includes nginx's own output |
| `nginx -t fails with OR without the TLS edit, so the problem is elsewhere` | Not this edit — often a missing certificate or another site. nginx.conf was put back as it was; fix the other fault and re-run |
| `... has an ssl_protocols directive that does not end on its own line` | Refused rather than rewritten blind. Put it on one line and re-run |
| `/etc/nginx/nginx.conf is a symlink; refusing to edit through it` | Replace the link with the real file, or edit it yourself to `ssl_protocols TLSv1.2 TLSv1.3;` |
| `... has an ssl_protocols directive sharing its line with another directive` | The rewrite replaces the line, so it would delete the other directive. Put `ssl_protocols` on a line of its own and re-run |

**Never widened (round 2).** The rewrite keeps the operator's own list minus anything below
TLS 1.2: `TLSv1.3` alone stays `TLSv1.3`; `TLSv1 TLSv1.3` becomes `TLSv1.3`; only a line left
with nothing approved becomes `TLSv1.2 TLSv1.3`.

**`--restore` brings back the PRE-EDIT nginx.conf.** A rollback restores the whole file from the
Phase 4 restore point, i.e. with whatever `ssl_protocols` it had before the upgrade (on a stock
host, TLSv1 and TLSv1.1 enabled again). Re-run the upgrade, or set the line by hand, after
a rollback.

Check it: `grep -E '^\s*ssl_protocols' /etc/nginx/nginx.conf`, and
`openssl s_client -connect localhost:443 -tls1_1 </dev/null` must fail the handshake.

---

## FIPS-mode hosts

- **`Error 2308: No smart card found` on every `sudo`** on a STIG'd host is `pam_pkcs11`
  looking for a CAC/PIV card, not this product. It is harmless for install and upgrade; the
  command continues with the next PAM method.

- **Supported.** nginx TLS uses the host's OpenSSL (the validated FIPS provider when FIPS mode
  is on) and the cipher list is FIPS-approved only; the session cookie is HMAC-SHA-256; LDAPS
  uses Python's `ssl` (host OpenSSL), SIMPLE bind only; secrets come from the kernel CSPRNG.
- **Known limitation, not a failure: the module boundary.** The `cryptography` and
  `confluent-kafka` wheels bundle their **own** OpenSSL, which is not the host's validated
  module. `cryptography` parses PEM certificates uploaded in the Cluster Builder;
  `confluent-kafka` (librdkafka) makes the TLS connection to SSL/SASL_SSL Kafka brokers. Both
  run on a FIPS host; their cryptography is outside the validated boundary. Record it as an
  accepted limitation, or keep the Kafka path inside a boundary your accreditation already
  covers.
- **Risk acceptance (2026-09-26, system owner): Kafka client TLS.** `confluent-kafka` 2.15.1
  bundles librdkafka and its own OpenSSL, so Kafka client TLS runs outside the host's FIPS
  140-3 validated module even with `fips_enabled=1` (SC-13; SRG-APP-000014 / SRG-APP-000514;
  CWE-327). Accepted. Use `SSL` or `SASL_SSL` in every Kafka profile. nginx, LDAPS and Python
  `ssl` do use the validated module (measured: `fips_enabled=1`, "Ubuntu 24.04 OpenSSL
  Cryptographic Module 3.0.13+Fips2"). To remove the risk, use the distribution's
  `python3-confluent-kafka` (system OpenSSL) or a site-built wheel against the system libssl.
  Full record: SBOM.md → *Risk acceptance*.
- **A browser cannot connect after FIPS mode is enabled.** The client offered only suites
  outside the list (ChaCha20, CBC, X25519-only). Any current browser offers AES-GCM with
  P-256; check with `openssl s_client -connect <host>:443 -tls1_2`.
- **Offline packages on a FIPS host.** The offline install never replaces a FIPS package: every
  installed package whose version contains `fips`, or that came from an Ubuntu Pro FIPS archive
  (`esm.ubuntu.com/fips`, `fips-updates`), has the bundle's copy pinned at -1 for that run.
  Other installed packages **may be upgraded** to the bundled build when a new package needs
  it — that is expected on an air-gapped host that lags on patches, and the plan line lists
  each one before it happens. If apt says a bundled package needs a newer FIPS library
  (`... but 3.0.13-0ubuntu3.4+Fips1 is to be installed`), update that library from the FIPS
  archive first; see *Fresh install* below. If apt could only proceed by **removing**
  packages (`libpython3.12t64`, and `vim` / `ubuntu-server` with it), the bundle lacks a
  lockstep sibling: rebuild it on a fully patched build host (see *Fresh install*).
- **`openssl could not generate a self-signed certificate`** on install — confirm
  `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 ...` works by hand;
  it is FIPS-approved. Or supply your own pair with `--tls-cert/--tls-key`.

---

## The audit database mode (tm.db 0600, data/ 0700)

- **`/opt/topic-manager/data/tm.db is '644 topic-manager', expected '600 topic-manager'`**
  (install) or **`/opt/topic-manager/data/tm.db is ..., expected 600 topic-manager`** (upgrade
  Phase 12, which then rolls back). Something re-widened it after the enforcement ran — a
  restore by hand, or an ACL/MAC policy. Check `getfacl` on the directory; fix with
  `sudo chown topic-manager:topic-manager /opt/topic-manager/data/tm.db && sudo chmod 600
  /opt/topic-manager/data/tm.db && sudo chmod 700 /opt/topic-manager/data`.
- **`/opt/topic-manager/data/tm.db is a symlink; refusing to chown or chmod through it`** — the
  application owns `data/`, so a link there would let it choose what root re-modes. The real
  database is a regular file; find out how the link got there before removing it.
- The service itself creates the file 0600 (and narrows an older one at start-up) and runs
  with `UMask=0077`, so SQLite's `-wal`/`-journal` siblings are 0600 too.

---

## Sign-in says "Sign-in is unavailable. Contact the administrator."

The application found no usable value for a required directory key — missing, a
`<placeholder>`, or an `ldap_server` that is not `ldaps://`. It never falls back to a built-in
directory, and (round 2) it does not tell an unauthenticated client which key: that is in the
service log — `sudo journalctl -u topic-manager | grep 'Sign-in refused'` — as
`config.yaml auth.<key> missing, a <placeholder>, or (ldap_server) not an ldaps:// URL`. Fix
the key (see *The directory settings are missing* above) and
`sudo systemctl restart topic-manager`.

## Saving a setting fails with "could not be saved together with their audit record"

The change and its `SETTINGS_UPDATE` row are one transaction; the audit row could not be
written, so nothing changed. The traceback is in the service log. Usually the database is
full, read-only or not owned by `topic-manager` — see *The audit database mode* above.

## Everyone was signed out by the upgrade

Expected once, after upgrading to v1.1.0: the session cookie is now signed with HMAC-SHA-256
instead of Flask's SHA-1 default, so cookies signed before the upgrade no longer validate.
Sign in again.

---

## Fresh install (install.sh)

| Message | What to do |
|---|---|
| `Cannot write /etc/topic-manager/config.yaml: no value for --ldap-url ...` | Pass the directory flags (see `sudo bash install.sh --help`) or run on a terminal to be prompted. Nothing was installed |
| `--ldap-url must be ldaps://<host>[:<port>]` | Plain `ldap://` is not supported; certificate validation is enforced |
| `Offline, and .../install/packages/apt has no Packages index` | The bundle predates round 2 (it handed apt a raw list of .debs, which fails on a STIG/FIPS host). Rebuild it with this release's `prepare-offline.sh` |
| `Offline package plan — NEW (n): ...; UPGRADE (n): ...` (INFO) | Not an error: what the offline apt step is about to do, as `package=version`. An UPGRADE is an installed package moved to the bundled build because a new package needs it (an air-gapped host lags on patches). The bundle never downgrades, never removes and never replaces a FIPS package. On a terminal you are asked to confirm; `--non-interactive` proceeds |
| `The offline bundle could not supply <packages> (apt exit N); nothing was installed or changed` | apt's own reason is printed just above. `but <version>+Fips1 is to be installed` (or any version containing `fips`) means a bundled package needs a **newer FIPS library** than the host has: the bundle's non-FIPS copy is pinned at -1 and is never used. Patch that library from the Ubuntu Pro FIPS archive (or the host's own mirror), then re-run. Any other unmet dependency: the bundle was built on a host too unlike this one — rebuild it with `prepare-offline.sh` on a host at the same patch level |
| `... could only satisfy this by REMOVING installed packages ... Lockstep siblings missing from the bundle: <pkg> (source <src>)` | Binaries built from one Debian source (e.g. `python3.12`, `libpython3.12t64`, `libpython3.12-stdlib`) depend on each other's exact version. The plan upgrades part of a source, and the bundle lacks the named sibling at the new version, so apt's only way out was to remove it — and everything that depends on it (the "Would be removed with them" list, e.g. `vim`, `ubuntu-server`). Nothing was changed. Rebuild the bundle with this release's `prepare-offline.sh` (it bundles every sibling; check its `lockstep siblings ... added` and `NOT downloadable` lines) on a **fully patched** Ubuntu 24.04 build host of the same architecture. If a sibling's source was reported over the 40-binary bound, install that package from the host's own mirror instead |
| `Refusing the offline package plan; nothing was installed or changed: <pkg>: ... would be DOWNGRADED / REMOVED / FIPS package ...` | The simulated plan broke the policy, so nothing was run. It should not happen (apt is configured so it cannot); report it with the line printed |
| `Package plan declined. Nothing has been changed.` | You answered no at `Apply this package plan?`. Nothing was installed |
| `Could not read the installed package set and its origins` | `dpkg-query -W` or `apt-cache policy` failed, so it could not be established which installed packages are FIPS modules; the install stops rather than guess. Run both by hand to see why (for example a damaged `/var/lib/dpkg/status`, or no package lists under `/var/lib/apt/lists`) |
| `Offline package install failed (apt exit N) while applying the plan printed above` | Resolution succeeded but dpkg failed while installing, so **part of the plan may be applied**. Run `sudo dpkg --audit` and read dpkg's output above; fix the cause and re-run `install.sh` |
| `pip install from requirements.lock failed (a hash mismatch is refused, not retried)` | A wheel did not match its SHA-256 in `requirements.lock` — a tampered mirror, a corrupted bundle, or a bundle built from a different release. Rebuild the bundle; never edit the lock by hand |
| `Cannot check /etc/topic-manager/config.yaml before changing anything` | Neither the existing venv nor `python3` can import PyYAML. `sudo apt install python3-yaml` and re-run; nothing was changed |
| `--tls-cert and --tls-key are not a matching certificate/key pair` | The two files are not a pair, or one could not be read. Compare `openssl x509 -noout -pubkey -in <crt>` with `openssl pkey -pubout -in <key>` |
| `nginx -t failed:` | nginx's own output follows. A fresh install always has a certificate now, so this is a real fault |
| `ufw is active but could NOT open: 443/tcp (<ufw's reason>)` (WARN) | Everything else was installed, but the site is unreachable through the firewall until the rule exists. Read ufw's reason, then `sudo ufw allow 80/tcp; sudo ufw allow 443/tcp` and `sudo ufw status`. (Before v1.1.0 round 5 the install instead died here with ufw's `ERROR: Invalid syntax` on every host with ufw active — it passed ufw an option ufw does not have. Re-run the fixed `install.sh`; it is safe over a finished install) |
| `topic-manager did not answer /api/health` | `sudo journalctl -u topic-manager -n 50 --no-pager` |

### prepare-offline.sh: `--bundle needs a git work tree` / `Not a git work tree`
The bundle is built only from `git archive` of the committed tree (round 2 removed the
directory-copy fallback, which also copied untracked files). Run it from a clone.

### prepare-offline.sh: `pip download from requirements.lock failed. There is no fallback`
Every wheel must be the locked, hash-verified one for Linux x86_64 / CPython 3.12. If a pin in
`requirements.txt` changed, regenerate the lock (`python tools/gen-requirements-lock.py`) and
commit it; `tools/check-requirements-lock.sh` says whether the two agree.

### prepare-offline.sh: `Neither apt-ftparchive (apt-utils) nor dpkg-scanpackages (dpkg-dev)`
The bundled `.deb`s must be indexed so the target's apt can resolve from them. Install
`apt-utils` on the build host.

### prepare-offline.sh: `The bundle failed the leak check above and was deleted`
`tools/check-env-neutral.sh --bundle` found process records (`.claude/`, `.work/`), a scan
report, or a site-specific name or address inside the bundle. It is built from `git archive`
of HEAD, so the cause is in a **committed** file: fix it, commit, rebuild.

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
