# Jarvis Topic Manager v1.1.0

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
- **Cluster Builder** — Add, modify and delete cluster profiles from Settings: PLAINTEXT, SSL and SASL_SSL, with TLS material supplied as PEM *content*. Every change is written to the audit log and takes effect immediately, with no restart
- **Service Control** — Restart `topic-manager` and reload nginx from Settings (hard nginx restart is opt-in), gated on a root-side `nginx -t` that must pass before anything is touched
- **3 Themes** — Dark (default), Light, Color Blind — stored per browser
- **Classification Banner** — Fixed at top and bottom of viewport; server-side persistence
- **Broker Hover Popup** — Hover the broker count to see all broker FQDNs and IDs
- **Concurrent Session Limit** — Configurable max simultaneous sessions per user (default 5)
- **Idle session timeout** — 15 minutes by default. The browser warns at 60
  seconds remaining and then signs the user out; the server refuses the
  session regardless. A tab's own background refresh does not count as
  activity, so an unattended browser cannot hold a session open
- **Offline Install** — All dependencies bundlable; no internet required on target host

## Stack

| Layer    | Technology                              |
|----------|-----------------------------------------|
| Frontend | Vue.js 3.5.43 (Options API, no build tools) |
| Backend  | Python 3.12 / Flask 3.1.3 / gunicorn 26.2.0 |
| Auth     | AD/LDAPS via ldap3 2.9.1                |
| Kafka    | confluent-kafka 2.15.1 AdminClient      |
| Web      | nginx (TLS termination, reverse proxy)  |
| DB       | SQLite (audit log + server-side sessions) |
| OS       | Ubuntu Server 24.04 LTS                 |

Every Python version above is pinned in `requirements.txt`, which is the single source of truth — the upgrade script and the offline bundler both read their pins from it. The Vue version and its SHA-256 are pinned in `install/upgrade-full.sh`. See `SBOM.md` for the full inventory, including the two places a *fresh* `install.sh` still differs.

---

## Installing

> **Upgrading an existing installation?** See [Upgrading](#upgrading) — do not re-run `install.sh` on a server that already has Topic Manager deployed.

The complete, environment-neutral procedure — online and air-gapped, including STIG'd and
FIPS-mode hosts — is **[docs/INSTALL.md](docs/INSTALL.md)**. In brief:

### Prerequisites

- A clean Ubuntu Server 24.04 LTS host (2 vCPU · 4 GB RAM · 20 GB disk minimum) with a DNS name
- Your directory's LDAPS URL, user search base DN and the DN of the group allowed to sign in (optionally a service account for searches — not required; see [LDAP authentication](#ldap-authentication))
- Network: LDAPS 636 to the directory, the Kafka brokers at the ports your cluster profiles name, DNS, NTP. An online install also needs HTTPS to the Ubuntu mirror, PyPI and `cdn.jsdelivr.net`; an offline install needs none of them. `PPSM.csv` has the full list
- Optionally, a TLS certificate and key for the host name from your CA. Without one a self-signed ECDSA P-256 placeholder is generated

### Step 1 — Get the release

The release tarball from your site's package registry (check its `.sha256`), or a clone of your
site's copy of the repository at the release tag:

```bash
git clone --branch v<version> --depth 1 <your-git-url> topic-manager && cd topic-manager
```

On an **air-gapped host**, see [Offline Install](#offline-install) below.

### Step 2 — Run the installer

```bash
sudo bash install.sh \
    --ldap-url     ldaps://dc1.example.org:636 \
    --ldap-base-dn "DC=example,DC=org" \
    --ldap-group   "CN=Kafka-Admins,OU=Groups,DC=example,DC=org" \
    --server-name  topics.example.org \
    [--tls-cert server.crt --tls-key server.key]
```

Run it without the `--ldap-*` flags on a terminal to be asked for each value instead;
`--non-interactive` makes a missing value a refusal. There are **no built-in directory
defaults**: before v1.1.0 the application silently filled in one particular site's domain
controller, base DN and domain when `config.yaml` omitted them.

The script, in order:
- Sets `umask 0022` for its own run (a STIG host's 077 would leave the venv and the frontend unreadable) and gives every sensitive file its mode explicitly
- Installs any missing runtime package — `python3 python3-venv nginx polkitd rsync sudo curl ca-certificates openssl` — from apt online, or from the bundle's `.deb`s offline (only for packages the host does not already have). No compiler and no `-dev` headers: every Python dependency is a binary wheel (`pip --only-binary :all:`)
- Installs Vue.js **3.5.43**, verified by SHA-256 before it is served (online: fetched from the CDN; offline: taken from the bundle's `lib/`). The version and hash are read from `install/upgrade-full.sh`, the same pin the upgrade and `prepare-offline.sh` use, and a file that does not match is refused — so a fresh install and an upgraded host serve byte-identical Vue
- Creates the `topic-manager` system user and `/opt/topic-manager/` (`data/` **0700**), `/var/www/topic-manager/`, `/etc/topic-manager/`
- Creates `/etc/topic-manager/clusters.d/` (owned by `topic-manager`) and `/opt/topic-manager/data/cluster-certs/` (mode 0700) — the only two directories the application may write outside its own data and log directories. `/etc/topic-manager` itself stays `root:topic-manager 0750`; see [Cluster profiles](#cluster-profiles) for why that split is not arbitrary
- Writes `/etc/topic-manager/config.yaml` (0640 `root:topic-manager`) with your directory settings and a random secret key — or, on a reinstall, keeps the existing one and **refuses to continue** if it lacks `auth.ldap_server`, `ldap_base_dn` or `ldap_domain`
- Creates an **empty** cluster store at `/etc/topic-manager/clusters.d/clusters.yaml` (or, on a reinstall over an older host, moves the existing `clusters:` block out of `config.yaml`). `config/clusters.yaml.example` is a format reference; it is never installed as live clusters
- Installs the systemd service (`topic-manager.service`, `UMask=0077`), the on-demand `topic-manager-nginx-test.service`, and `/etc/polkit-1/rules.d/50-topic-manager.rules`, which is what lets the Settings restart control act
- Installs the nginx site, the certificate (yours, an existing one, or the self-signed placeholder) and sets `ssl_protocols TLSv1.2 TLSv1.3` in `/etc/nginx/nginx.conf` — backed up, `nginx -t`'d, and put back if the test fails
- Opens ufw ports 80 and 443 if ufw is active
- Verifies, as the service account, that the app can write `clusters.d` and cannot write `config.yaml`
- **Starts the service**, waits for `/api/health`, and measures `tm.db` 0600 / `data/` 0700

### Step 3 — Verify, sign in, add clusters

```bash
curl -sk https://localhost/api/health
```

should return `{"status":"ok","version":"1.1.0"}`. Open `https://<server-name>/`, sign in as a
member of the required group, and add your Kafka clusters in **Settings → General → Cluster
Profiles** — a new install starts with none.

> **Login credential format:** use your directory `sAMAccountName` (e.g. `firstname.lastname`), your full UPN (`firstname.lastname@example.org`), or `DOMAIN\firstname.lastname`. Display names and email aliases are not supported.

---

## LDAP authentication

Topic Manager supports **two** bind modes. Both authenticate the user against
Active Directory and both enforce `required_group`; they differ only in which
identity performs the directory *search*.

| Mode | `ldap_bind_dn` / `ldap_bind_password` | Directory search runs as | Setup |
|---|---|---|---|
| **Direct user bind** (default) | both empty | the user logging in | none |
| **Service-account bind** | both set | a dedicated read-only account | AD account required |

The service account is **optional hardening, not a requirement**. If you have no
particular reason to prefer it, leave both fields empty and skip the rest of
this section.

### ⚠ Upgrading from v1.0.0 — read this first

This is the most likely way to break an upgrade out of v1.0.0, and it fails
*silently*: the health check, `/api/version` and the UI all stay green while
**nobody can log in**.

- **v1.0.0 has no service-bind logic at all.** It binds directly as the user, so
  whatever sits in `ldap_bind_dn` is simply ignored. A wrong or stale value can
  sit in the config for months causing no symptom whatsoever.
- **v1.0.2 and later** treat a populated `ldap_bind_dn` plus a non-placeholder
  password as "use the service bind", and gate **every** login on it succeeding.

A setting that was inert becomes load-bearing the moment the new code starts.

Check it before upgrading — this is exactly what the upgrade script's Phase 3
blocker does, and it refuses to proceed if the bind fails:

```bash
sudo bash install/upgrade-full.sh --audit-only
# "LDAP service bind" must report PASS, or "no service bind configured"
```

To test the bind by hand:

```bash
ldapwhoami -H ldaps://<dc-host>:636 -x -W \
  -D "$(sudo grep ldap_bind_dn /etc/topic-manager/config.yaml | cut -d'"' -f2)"
# Expected: dn:CN=svc-...
```

If it fails, take Fix A or Fix B below.

### Fix A — disable the service account (fastest, needs no secret)

This leaves you on the direct user bind, which is what v1.0.0 was doing anyway,
so there is **no change in behaviour**:

```bash
sudo sed -i 's/^\(\s*ldap_bind_dn:\).*/\1 ""/'       /etc/topic-manager/config.yaml
sudo sed -i 's/^\(\s*ldap_bind_password:\).*/\1 ""/' /etc/topic-manager/config.yaml
python3 -c "import yaml; yaml.safe_load(open('/etc/topic-manager/config.yaml'))" && echo "YAML OK"
sudo systemctl restart topic-manager
```

Re-run `--audit-only`; the LDAP row should now read *no service bind configured*.

### Fix B — repair the service account

1. Confirm the account's **real** DN. The `CN` and the `sAMAccountName` are
   frequently different, and inferring the DN from the login name is a common
   cause of this exact failure:

   ```powershell
   Get-ADUser -Identity "svc-topic-mgr" -Properties DistinguishedName |
     Select-Object Name, SamAccountName, DistinguishedName
   ```

2. Reset the password if it is unknown or stale, and record it wherever your
   secrets live.

3. Set both fields, validate the YAML, restart:

   ```bash
   sudo nano /etc/topic-manager/config.yaml     # ldap_bind_dn + ldap_bind_password
   python3 -c "import yaml; yaml.safe_load(open('/etc/topic-manager/config.yaml'))" && echo "YAML OK"
   sudo systemctl restart topic-manager
   ```

4. Prove it before trusting it:

   ```bash
   sudo bash install/upgrade-full.sh --audit-only   # LDAP service bind -> PASS
   ```

> **Do not brute-force the bind to discover the right password.** Every attempt
> is a real AD authentication, and enough failures lock the account. Because
> every login is gated on that same bind, a locked service account is a total
> outage for the application. The upgrade script caches a *failing* verdict for
> a given (server, DN, password) and will not re-bind the same tuple;
> `--no-bind-probe` skips the check entirely.

### Certificate trust

From v1.0.2 the LDAPS connection uses `CERT_REQUIRED`, so the domain
controller's certificate must validate against the system trust store:

```bash
openssl s_client -connect <dc-host>:636 \
  -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>&1 | grep 'Verify return code'
# Expected: Verify return code: 0 (ok)
```

If it does not verify, add your CA and re-run:

```bash
sudo cp your-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

Alternatively point `ldap_ca_cert` at a CA PEM file; leaving it blank uses the
system trust store.

---

## Cluster profiles

Cluster profiles used to be a `clusters:` block inside `config.yaml`. Since **v1.0.4** they
live in their own file, which the application owns and writes:

```
/etc/topic-manager/          root:topic-manager  0750   the app reads, and can create nothing
  config.yaml                root:topic-manager  0640   secrets; the app can neither write nor unlink it
  tls/                       root:topic-manager  0750
  clusters.d/                topic-manager:topic-manager  0750   the app owns this, and ONLY this
    clusters.yaml            topic-manager:topic-manager  0640
/opt/topic-manager/data/cluster-certs/   topic-manager:topic-manager  0700   uploaded TLS material
```

### Why the split exists

It looks like two files where one would do. It is not, and simplifying it back would
reintroduce a privilege escalation.

`config.yaml` holds `server.secret_key`, `auth.ldap_bind_password` and
`auth.required_group`. The service must **read** it and must never **write** it. An
interactive Cluster Builder, on the other hand, needs a file it can rewrite — and rewriting
a file safely means writing a temporary file beside it and renaming over the target, which
requires write permission on the *directory*, not on the file.

**A directory the application can write is a directory in which it can unlink files it
cannot write.** POSIX unlink is a directory operation; the target file's own mode and owner
do not enter into it — `config.yaml` being `root:topic-manager 0640` would not save it. So
had `/etc/topic-manager` been made app-writable, the application could delete `config.yaml`,
write its own in its place — choosing its own `required_group`, i.e. which AD group is
allowed in — and then use the Settings restart control to load it. That is a complete
authentication-configuration takeover, reached entirely through supported features. This was
measured on the host, not reasoned about in the abstract.

The split is what removes it: the writable directory is `clusters.d/`, one level *below* a
parent that stays `root:topic-manager 0750`, so an atomic replace of `clusters.yaml` works
and `config.yaml` remains untouchable. The systemd unit's `ReadWritePaths` names
`/etc/topic-manager/clusters.d` and deliberately **not** its parent, and the upgrade script
asks the kernel — as the `topic-manager` principal — to prove both halves before it declares
the upgrade good.

Verify it yourself at any time:

```bash
sudo -u topic-manager test -w /etc/topic-manager         && echo "WRITABLE — WRONG" || echo "not writable (correct)"
sudo -u topic-manager test -w /etc/topic-manager/config.yaml && echo "WRITABLE — WRONG" || echo "not writable (correct)"
sudo -u topic-manager test -r /etc/topic-manager/config.yaml && echo "readable (correct)"
sudo -u topic-manager test -w /etc/topic-manager/clusters.d  && echo "writable (correct)"
```

### The Cluster Builder

**Settings → Cluster Profiles → + Add Cluster**, or **Edit** / **Delete** on any profile.

- **Protocols:** `PLAINTEXT`, `SSL`, `SASL_SSL`. The list the form offers comes from the
  backend (`/api/clusters`), so it cannot drift from what the backend will accept.
- **SASL:** `PLAIN`, `SCRAM-SHA-256`, `SCRAM-SHA-512`. The password is **write-only** — it
  is accepted and stored for the Kafka client, and no route ever returns it. Re-saving a
  profile without re-typing it keeps the stored one.
- **Certificates are supplied as PEM content, never as a path.** The file picker reads the
  file in your browser and posts its text; the server parses it, writes it under
  `/opt/topic-manager/data/cluster-certs/` with a **server-generated** filename, and stores
  that path. The UI only ever shows the basename.
- **Changes take effect immediately.** Every gunicorn worker re-reads `clusters.yaml` when
  its inode/size/mtime changes, so no restart is needed after an edit.
- **Every change is audit-logged** (`CLUSTER_CREATE` / `CLUSTER_UPDATE` / `CLUSTER_DELETE`)
  with the before and after state. The SASL password is redacted and certificate paths are
  reduced to basenames before anything reaches the log.
- The **last** profile cannot be deleted, and a cluster **id** cannot be changed by editing —
  the id is the routing key that sessions and generated certificate filenames are tied to.
  Create a new profile and delete the old one.

#### Why content and not a path

Accepting `ssl_cafile: /some/path` from a user would be an arbitrary-file-read oracle, not a
convenience:

- `GET /api/clusters/<id>/test` returns the Kafka driver's error string **verbatim**, and the
  driver reports what it found when it tried to parse the file;
- `/api/audit/export` hands the full audit CSV to **any authenticated user**;
- the service can read `config.yaml`, which holds `secret_key` and `ldap_bind_password`.

Point a cluster's CA file at `config.yaml`, press *Test*, and read the parse error. Every
authenticated user is a Kafka admin by design in this product, so "authenticated" is the only
barrier there is. Taking paths out of the API closes that at the source: the only paths the
store will ever hold are ones it generated itself, and any profile whose TLS paths resolve
outside the certificate directory is **disabled on load** — it stays visible and named in the
UI, but it can never be handed to the Kafka client.

### Editing the file by hand

Supported, and picked up without a restart:

```bash
sudo nano /etc/topic-manager/clusters.d/clusters.yaml

# Put the ownership and mode back: an editor that REPLACES the file leaves it
# root-owned, and the next save from the Cluster Builder would then fail.
sudo chown topic-manager:topic-manager /etc/topic-manager/clusters.d/clusters.yaml
sudo chmod 640 /etc/topic-manager/clusters.d/clusters.yaml

sudo /opt/topic-manager/venv/bin/python3 \
  -c "import yaml; yaml.safe_load(open('/etc/topic-manager/clusters.d/clusters.yaml'))" && echo "YAML valid"
```

The annotated reference for the file's shape is `config/clusters.yaml.example`.

### Migration from an earlier release

`tm/migrate_clusters.py` is run by **both** `install.sh` and `install/upgrade-full.sh`, so a
reinstall and an upgrade take the same path. It:

- moves the `clusters:` block out of `config.yaml` into `clusters.d/clusters.yaml`, leaving
  a comment where the block was;
- **preserves your comments** in the rest of `config.yaml` — it edits the file line by line
  rather than re-serialising it, because a YAML round-trip would silently delete every
  comment from a file operators are expected to hand-edit;
- is **idempotent**: on an already-migrated host it prints `already migrated` and changes
  nothing;
- on a host with neither a store nor a `clusters:` block (a fresh install) creates an
  **empty** store — `clusters: []` — since v1.1.0. It used to install the example profiles,
  which made a brand-new host's first cluster list somebody else's brokers;
- refuses to report success if `config.yaml` still has a `clusters:` key afterwards, or if
  the new file does not hold a cluster list.

After an upgrade, confirm the three things it is responsible for:

```bash
# 1. the profiles are in the new file
sudo cat /etc/topic-manager/clusters.d/clusters.yaml

# 2. the old block is gone from config.yaml (expect no output)
sudo grep -n '^clusters:' /etc/topic-manager/config.yaml

# 3. ownership and modes are what the app needs
sudo ls -ld /etc/topic-manager /etc/topic-manager/clusters.d \
            /etc/topic-manager/clusters.d/clusters.yaml \
            /opt/topic-manager/data/cluster-certs
# drwxr-x--- root          topic-manager  /etc/topic-manager
# drwxr-x--- topic-manager topic-manager  /etc/topic-manager/clusters.d
# -rw-r----- topic-manager topic-manager  clusters.yaml
# drwx------ topic-manager topic-manager  cluster-certs
```

Then sign in and check Settings → Cluster Profiles lists what it listed before, and that the
Topics tab still loads.

If a host somehow reaches the new code without the migration having run, it keeps working:
the `clusters:` block still in `config.yaml` is used as a fallback, with a warning in the
log, and the first save from the Cluster Builder writes the whole list out to the new file.
That fallback is a safety net, not a supported state — run the migration by hand
(`TROUBLESHOOTING.md` → *The cluster-profile migration*) and leave one file holding the
list. If both files end up holding one, `clusters.yaml` wins and the block in `config.yaml`
is ignored — with a warning naming it, because two files claiming the same truth is the
shadowing this split exists to prevent.

---

## Service control

**Settings → Service Control → ↻ Restart Services** restarts `topic-manager.service` and
**reloads** `nginx.service`. A **Hard-restart nginx** checkbox is available and is off by
default: nothing in a Topic Manager release changes nginx's configuration, so a full restart
buys nothing a reload does not, and it drops every other user's in-flight request.

What happens, in order:

1. **`nginx -t` runs first, as root, and synchronously.** If it fails, the request is
   refused with HTTP 409, the refusal is audit-logged as `SERVICE_RESTART_REFUSED`, and
   **nothing is touched**.
2. The intent is audit-logged (`SERVICE_RESTART`, with the user and which nginx verb) *before*
   anything is restarted — the worker handling the request is about to be killed, so an entry
   written afterwards is an entry that might never be written.
3. The API answers **202 Accepted** and detaches. nginx is reloaded or restarted first,
   `topic-manager` last, because restarting `topic-manager` kills the worker doing the work.
4. The browser then polls `/api/health` for up to 60 seconds and reports either the version
   that came back or `The service DID NOT come back within 60 seconds`. The 202 only means
   the work was accepted; whether the service returned is a separate question and the UI
   answers it separately.

Every authenticated user can use this control. There is no role separation anywhere in this
product — see [Compliance](#compliance) — so treat the audit log as the record of *who*, not
as a control on *whether*.

---

## Privileges the install grants

The installer grants the `topic-manager` service account three narrowly scoped systemd
actions, and nothing else. If you are reviewing the box, these are what changed in v1.0.4:

**`/etc/polkit-1/rules.d/50-topic-manager.rules`** — for the user `topic-manager` only, on
the action `org.freedesktop.systemd1.manage-units`:

| Unit | Verbs allowed |
|---|---|
| `topic-manager.service` | `restart` |
| `nginx.service` | `reload`, `restart` |
| `topic-manager-nginx-test.service` | `start` |

There is no `stop` and no `kill` — leaving the site down is not one of the outcomes this
feature offers. The rule returns `YES` for those combinations and `NOT_HANDLED` for
everything else, so it can never widen anything for any other subject or action.

The record of *who* restarted the service is the application's own audit log
(`SERVICE_RESTART`, with the username). `polkitd` journals the loading and compilation of
the rules files, which is how you confirm this one is in force at all — an error in a rules
file is reported there too:

```bash
sudo journalctl -u polkit --since "-1h" --no-pager
# ... polkitd[...]: Finished loading, compiling and executing N rules
```

**`/etc/systemd/system/topic-manager-nginx-test.service`** — a root-side `Type=oneshot`
running `/usr/sbin/nginx -t`, and nothing else. It has no `[Install]` section, is never
enabled, and only ever runs when the restart control starts it. It exists because the
pre-check could not otherwise fail:

- `nginx -t` **cannot** be run by the `topic-manager` account. Measured on the live host, it
  reports `[emerg] open() "/run/nginx.pid" failed (13: Permission denied)` and exits 1 — so
  as the app user the test fails whether the configuration is good or bad. Redirecting the
  pid file with `-g 'pid /tmp/...;'` is refused as a duplicate of the directive `nginx.conf`
  already sets.
- `systemctl reload nginx` is **not** a substitute. Its `ExecReload` is `nginx -s reload`,
  which exits 0 whether or not the master process accepts the new configuration. Without
  this unit, a "config test" would report success on a configuration nginx had rejected.

Being `Type=oneshot`, `systemctl start` blocks until the test finishes and returns its exit
status, so the verdict is conclusive rather than inferred. The unit reads configuration and
writes nothing.

**Why polkit and not sudoers.** `topic-manager.service` sets `NoNewPrivileges=true`, under
which `sudo` refuses to run at all (`sudo: The "no new privileges" flag is set...`). A
sudoers entry would be dead code as the unit stands, and the hardening is not being removed
to revive it. `systemctl` over D-Bus survives `NoNewPrivileges` because the caller never
escalates — it asks PID 1 to act on its behalf — and the denial you get without a rule is
polkit's *Interactive authentication required*, not the sandbox refusing.

**`ReadWritePaths`.** The unit adds `/etc/topic-manager/clusters.d` and deliberately not
`/etc/topic-manager`, for the unlink reason in [Cluster profiles](#cluster-profiles):

```bash
systemctl show topic-manager --property=ReadWritePaths
# ReadWritePaths=/opt/topic-manager/data /opt/topic-manager/logs /tmp /etc/topic-manager/clusters.d
```

`ReadWritePaths` alone is not what protects `config.yaml`; ordinary file permissions inside
the mount namespace are. Both are in place, and both are checked by the upgrade.

---

## Upgrading

> **Do not run `install.sh` on an existing deployment.** It uses `rsync -a --delete` on the backend and frontend directories and will remove files it did not put there.

Upgrades are run by **`install/upgrade-full.sh`**, which is the only supported upgrade path in this repo. It is version-agnostic: it upgrades whatever is installed — including v1.0.0 — to whatever the source tree it fetches declares in `tm/VERSION`. It audits the host first, takes a verified backup before touching anything, and rolls back automatically if a phase fails.

What it does, in order:

| Phase | |
|-------|--|
| 1–2  | Preflight and permission audit — disk, ownership and modes, immutable attributes, POSIX ACLs, AppArmor/SELinux, auditd/AIDE/fapolicyd, and effective access asked of the kernel as the real `www-data` and `topic-manager` principals |
| 3    | Upgrade blockers — `server.secret_key` must be set; `config.yaml` must name its directory (`auth.ldap_server`, `ldap_base_dn`, `ldap_domain` — v1.1.0 has no built-in defaults, and this blocker is **not** overridable with `--force`); and if a service bind is configured the LDAP bind must actually succeed. They are resolved the way the *service* sees them: the unit's `Environment=` / `EnvironmentFile=` (drop-ins included) first, then the shell, then `config.yaml`. The audit also reports the current `tm.db` mode and `nginx.conf`'s `ssl_protocols` |
| 4    | Backup to `/var/backups/topic-manager/<TIMESTAMP>` plus a `.tar.gz` alongside it — config, TLS key and certificate, extra CA material, a consistent SQLite snapshot, the venv, the nginx site **and `/etc/nginx/nginx.conf`**, the systemd unit **and its drop-in directory**, and a recorded permission baseline. Checksummed and verified before the upgrade is allowed to continue |
| 5    | Fetch the target source — online from the git URL you give with `--repo-url` (there is no default), or offline from the staged bundle — and read every Python pin from its `requirements.txt`; the script keeps no pins of its own |
| 6    | OS packages (`apt full-upgrade`), unless `--skip-os` |
| 7–9  | Replace venv, backend, frontend, nginx config and unit, and install the polkit rule and the `topic-manager-nginx-test` unit. Vue is verified by SHA-256 before it is allowed to serve |
| 10   | Restore `config.yaml`, the audit database, TLS material, the systemd drop-in, the cluster store (`clusters.d/` and `cluster-certs/`) and the recorded ownership and modes verbatim — a deliberately narrowed permission is never widened back to a script default. The store is restored *before* the migration runs. The one deliberate exception to "verbatim": `data/` and `tm.db` are set to **0700 / 0600** after the replay, because a v1.0.x baseline records 0644 for the audit database |
| 11–12| Config migration — the `clusters:` block moves out of `config.yaml` — and `nginx.conf`'s `ssl_protocols` set to `TLSv1.2 TLSv1.3` (backed up, `nginx -t`, put back on failure); then the permission boundary is **measured** as the `topic-manager` principal (it must be able to write `clusters.d`, and must not be able to write `config.yaml` or its directory; either failure fails the upgrade), then start and verify: health, reported version, effective access, and the security headers on every route class |

### What the upgrade needs, and what it will ask you

**It asks you nothing.** `upgrade-full.sh` is fully non-interactive from start to
finish — there are no prompts, no confirmations and no `[y/N]`, and `apt` runs
under `DEBIAN_FRONTEND=noninteractive`. It either completes or it fails and rolls
back. What it needs is *access*, not answers:

| Needs | Why | If you cannot grant it |
|-------|-----|------------------------|
| **root** (`sudo bash`) | writes `/opt`, `/etc`, `/var`, the unit and the nginx site | it refuses immediately: `Run with sudo` |
| **A source URL and outbound access to it** | online mode clones the target source (`--depth 1`) from the git URL you give with `--repo-url` (or `TM_REPO_URL`). There is no default: without one, an online run stops before anything changes and says so | use `--offline` with a prepared bundle |
| **Outbound HTTPS to `pypi.org`** | installs the pins from `requirements.txt` | use `--offline`; it also auto-detects and degrades |
| **`apt`** | `apt full-upgrade` for nginx, OpenSSL, python3, krb5, kernel | use `--skip-os` to upgrade the app only |
| **systemd** | stop/start `topic-manager`, reload nginx | none — this is required |

On a STIG'd host the permission audit (phase 2) asks the **kernel**, not the file
modes, whether `www-data` and `topic-manager` can actually reach what they need,
so scoped-down ACLs, immutable attributes and AppArmor denials are reported
before anything is touched rather than discovered at restart.

### Your configuration is restored verbatim — including values a new release changed

Phase 10 restores your `config.yaml` **exactly as it was**. That is deliberate:
your configuration is yours, and an upgrade that silently rewrote it would be
worse than one that leaves a setting behind.

The consequence is worth stating plainly, because it is easy to miss:

> **A change to a DEFAULT does not reach a host that sets the key.**

v1.0.6 lowered the idle session timeout default from 30 minutes to 15. A host
whose `config.yaml` says `timeout_minutes: 30` upgrades to v1.0.6 and **stays on
30**, while this README, `SBOM.md` and the in-app documentation all describe 15.
This was measured on the production host on 2026-09-02: the upgrade reported
success and the value had to be changed by hand afterwards.

`--audit-only` now reports it, as a warning rather than a blocker — a longer
timeout can be a deliberate decision:

```
[WARN ] session idle timeout is 30 min, above the 15 min default
        config.yaml is restored verbatim, so THIS UPGRADE WILL NOT CHANGE IT
```

To adopt the new default after upgrading:

```bash
sudo sed -i 's/^\(  timeout_minutes:\).*/\1 15/' /etc/topic-manager/config.yaml
sudo systemctl restart topic-manager
```

Apply the same reasoning to any future release that changes a default: read the
`--audit-only` warnings, not just its exit code.

**Step 1 — Take a vCSA snapshot** of the VM before doing anything else.

**Step 2 — Check what is actually installed:**
```bash
curl -sk https://localhost/api/health
# {"status":"ok","version":"1.0.0"}
```

**Step 3 — Get the script and audit the host.** The clone below only supplies the script; the upgrade fetches its own copy of the target source in Phase 5.
```bash
sudo apt-get install -y git
# NOT /tmp: root executes this script. A local account that pre-creates the
# directory owns what root then runs out of it, and `git clone` into an
# existing empty directory succeeds without noticing who made it.
sudo install -d -m 700 -o root -g root /var/lib/topic-manager/upgrade-src
sudo git clone --branch v<version> --depth 1 <your-git-url>   /var/lib/topic-manager/upgrade-src
cd /var/lib/topic-manager/upgrade-src
sudo bash install/upgrade-full.sh --audit-only --repo-url <your-git-url> --repo-branch v<version>
```
`--audit-only` changes nothing and exits **0** clear, **1** warnings only, **2** blockers present. Resolve every blocker before going further — they are the failures that otherwise appear an hour later as "nobody can log in".

**Step 4 — Take the verified restore point:**
```bash
sudo bash install/upgrade-full.sh --backup-only
sudo bash install/upgrade-full.sh --list-backups
```

**Step 5 — Run the upgrade:**
```bash
sudo bash install/upgrade-full.sh --repo-url <your-git-url> --repo-branch v<version>
```
Useful flags: `--dry-run` (audit + plan, no changes), `--skip-os` (application and dependencies only), `--offline` (see below), `--force` (proceed past blockers — the backup is still taken first).

**Step 6 — Follow the post-upgrade checklist** printed at the end of the run:

1. Verify LDAPS cert is trusted:
```bash
openssl s_client -connect <dc-host>:636 \
  -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null 2>&1 | grep "Verify return code"
# Expected: Verify return code: 0 (ok)
```
If not 0: `sudo cp your-internal-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`

2. If `ldap_bind_password` in your config is a real value (not `CHANGE_ME`), verify the service account works:
```bash
ldapwhoami -H ldaps://<dc-host>:636 \
  -D "<service-account-dn>" -W -x
# Expected: dn:CN=svc-account,...
```
If `ldap_bind_password` is `CHANGE_ME`, auth falls back to direct user bind — login works without any changes.

3. Sign in with your AD `sAMAccountName` (`firstname.lastname`) or full UPN.

4. Hard-refresh all browsers — `Ctrl+Shift+R`.

5. **Upgrading to v1.0.4 or later:** confirm the cluster-profile migration landed, and that
   the restart control has what it needs.

```bash
# Profiles moved out of config.yaml, and the old block is gone (expect no output)
sudo cat /etc/topic-manager/clusters.d/clusters.yaml
sudo grep -n '^clusters:' /etc/topic-manager/config.yaml

# The boundary the split exists to hold
sudo -u topic-manager test -w /etc/topic-manager && echo "WRITABLE — WRONG" || echo "not writable (correct)"
sudo -u topic-manager test -w /etc/topic-manager/clusters.d && echo "writable (correct)"

# The restart control's authorisation and its config-test unit
ls -l /etc/polkit-1/rules.d/50-topic-manager.rules
sudo journalctl -u polkit -n 5 --no-pager      # "Finished loading, compiling and executing N rules"
systemctl cat topic-manager-nginx-test.service >/dev/null && echo "test unit installed"
```

Then open Settings and check that Cluster Profiles lists what it listed before.

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
# Straight into the root-owned destination. --strip-components=1 drops the
# repo-checkout directory the tarball wraps everything in, so nothing is ever
# staged in /tmp, where the directory root reads from would be created by
# whoever got there first.
sudo tar xzf topic-manager-offline-<version>.tar.gz   -C /var/lib/topic-manager/offline-src --strip-components=1

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
# Creates: ../topic-manager-offline-<version>.tar.gz and its .sha256
# Contains: the COMMITTED tree (git archive) + Python wheels + Vue.js + runtime .debs
```

Run it on an Ubuntu 24.04 machine of the target's architecture. The bundle is built from
`git archive` of HEAD — never the working directory — so the repository's own records
(`.claude/`, `.work/`) and untracked files cannot ship, and `tools/check-env-neutral.sh
--bundle` deletes it if anything internal or site-specific got in.

On the air-gapped host — root runs `install.sh`, so the tree it runs from is
created root-owned first and the bundle is unpacked straight into it:
```bash
sha256sum -c topic-manager-offline-<version>.tar.gz.sha256
sudo install -d -m 700 -o root -g root /var/lib/topic-manager/install-src
sudo tar xzf topic-manager-offline-<version>.tar.gz   -C /var/lib/topic-manager/install-src --strip-components=1
sudo bash /var/lib/topic-manager/install-src/install.sh --ldap-url ... --ldap-base-dn ... --ldap-group ...
```

It auto-detects offline mode. See [docs/INSTALL.md](docs/INSTALL.md) section 5.

---

## Configuration Reference

There are **two** configuration files, and the difference between them is a security
boundary, not a filing decision — see [Cluster profiles](#cluster-profiles).

| File | Owner / mode | Holds | Written by |
|---|---|---|---|
| `/etc/topic-manager/config.yaml` | `root:topic-manager 0640` | server, auth, session, audit, logging | the operator (and the installer, once) |
| `/etc/topic-manager/clusters.d/clusters.yaml` | `topic-manager:topic-manager 0640` | cluster profiles only | the Cluster Builder, or the operator |

Full annotated examples: `config/config.yaml.example` and `config/clusters.yaml.example`.

**When a restart is needed.** Both files are re-read when their inode, size or mtime
changes, so cluster profiles and the `auth:` settings take effect on the next request with
no restart. `server.secret_key`, the session cookie lifetime (`session.timeout_minutes`) and
the `logging:` settings are applied when the process starts, so changing those does need
`sudo systemctl restart topic-manager` — or the restart control in Settings.

Key settings:

| Setting | Description |
|---------|-------------|
| `server.secret_key` | Flask session secret — auto-generated on install, do not change |
| `auth.ldap_server` | LDAPS endpoint, e.g. `ldaps://dc1.example.org:636` |
| `auth.ldap_ca_cert` | Path to CA bundle; leave blank to use system trust store |
| `auth.ldap_bind_dn` | **Optional.** Full DN of a service account used for directory searches. Leave empty for the direct user bind |
| `auth.ldap_bind_password` | **Optional.** Service account password. If both fields are set they must work — every login is gated on that bind |
| `auth.required_group` | Full DN of the AD group required for access |
| `session.timeout_minutes` | Session idle timeout in minutes (default: **15**) |
| `session.max_concurrent` | Maximum simultaneous sessions per user; 0 = unlimited |

#### Session timeout

`session.timeout_minutes` (default **15**) is minutes of **inactivity**, and it
is enforced in two places that agree with each other:

- **The server** stores `expires_at` on the session row and refuses an expired
  session with `401`, writing a `SESSION_EXPIRED` audit row. This is the
  enforcement, and it holds whether or not the browser cooperates.
- **The browser** arms an idle timer from the same value — served on login and
  on `/api/auth/whoami`, never hardcoded in the frontend — warns at 60 seconds
  remaining, and then signs out. The sign-out is deliberately a few seconds
  before the server's own expiry, so the `LOGOUT` audit row is written while
  the session is still valid rather than lost to a `401`.

**Background refreshes do not count as activity.** The Topics and Consumer
Groups tabs refresh every 30 seconds; those requests carry `X-TM-Background: 1`
and do not extend the session.

> Before v1.0.6 they did, and the consequence is worth stating plainly: every
> authenticated request renewed the session for another full timeout, so an open
> tab renewed itself twice a minute and the idle timeout could only ever expire
> a browser that was already closed. Setting `timeout_minutes` to a smaller
> number would not have changed that.

Raising `timeout_minutes` is an operator decision; the value flows to the
browser automatically and no frontend change is needed.

| `audit.db_path` | SQLite audit + session database |
| `logging.log_level` / `logging.syslog_enabled` | Log verbosity, and syslog forwarding |

In `clusters.d/clusters.yaml` (normally maintained from the Cluster Builder):

| Setting | Description |
|---------|-------------|
| `clusters[].id` | Routing key. Lowercase letters, digits, `.`, `_`, `-`. Cannot be changed by editing a profile |
| `clusters[].bootstrap_servers` | Comma-separated `host:port` Kafka broker addresses — no scheme, no spaces |
| `clusters[].security_protocol` | `PLAINTEXT`, `SSL` or `SASL_SSL` |
| `clusters[].sasl_mechanism` / `sasl_username` / `sasl_password` | SASL only. The password is write-only over the API |
| `clusters[].ssl_cafile` / `ssl_certfile` / `ssl_keyfile` | Absolute paths **under `/opt/topic-manager/data/cluster-certs/`**, generated by the Cluster Builder from uploaded PEM. A path anywhere else disables the profile on load |
| `clusters[].active` | Exactly one profile is the default; the UI switches at runtime |

---

## File Layout (Server)

```
/opt/topic-manager/          Backend root
  venv/                      Python virtual environment
  tm/                        Flask application package
  data/tm.db                 SQLite audit + session database
  data/cluster-certs/        topic-manager:topic-manager 0700 — TLS material uploaded
                             through the Cluster Builder. Filenames are generated
                             server-side; files are written 0600
  logs/                      gunicorn access + error logs
/var/www/topic-manager/      Frontend static files (nginx root)
/etc/topic-manager/          root:topic-manager 0750 — the app reads this directory and
                             can create nothing in it
  config.yaml                root:topic-manager 0640 — server, auth, session, audit and
                             logging. Holds secret_key and ldap_bind_password, so the
                             application can neither write nor unlink it
  tls/                       root:topic-manager 0750
  tls/server.crt             TLS certificate for nginx
  tls/server.key             TLS private key
  clusters.d/                topic-manager:topic-manager 0750 — the ONE directory the app
                             owns inside /etc. Directory write is what an atomic replace
                             needs, and it is why this is a subdirectory rather than
                             /etc/topic-manager itself
  clusters.d/clusters.yaml   topic-manager:topic-manager 0640 — cluster profiles, written
                             by the Cluster Builder
/etc/nginx/sites-available/topic-manager   nginx site config
/etc/nginx/snippets/tm-security-headers.conf   Security header snippet
/etc/systemd/system/topic-manager.service    systemd unit
/etc/systemd/system/topic-manager-nginx-test.service   Root-side `nginx -t`, Type=oneshot.
                             Never enabled; started on demand by the restart control
/etc/polkit-1/rules.d/50-topic-manager.rules   Authorises the topic-manager account to
                             restart topic-manager, reload/restart nginx, and start the
                             nginx-test unit. Nothing else — no stop, no kill
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
- TLS 1.2 / 1.3 only — in the site AND at the http level of `/etc/nginx/nginx.conf`, which install and upgrade manage (stock Ubuntu enables TLS 1.0/1.1 there). FIPS-approved ciphers only: TLS 1.2 ECDHE with AES-GCM and SHA-256/384; TLS 1.3 AES-GCM suites; curves P-384/P-256; session tickets off; `server_tokens off`
- Runs on a STIG'd, FIPS-mode Ubuntu 24.04 host. Known limitation: the `cryptography` and `confluent-kafka` wheels bundle their own OpenSSL, outside the host's validated module — see `SBOM.md` and docs/INSTALL.md section 10
- Audit database `tm.db` 0600 in a 0700 directory, owned by the service account; `UMask=0077` on the unit
- HTTPOnly + Secure + SameSite=Lax session cookies, signed with HMAC-SHA-256
- Security headers on all routes: HSTS, CSP (`frame-ancestors 'none'`, `form-action 'none'`, `base-uri 'self'`), X-Content-Type-Options, Referrer-Policy
- Server-side session store (SQLite); session tokens never leave the server in a readable form
- Audit log with user, IP, timestamp and detail. **16 audited actions** (derived from `tm/routes.py` with the AST method in `.claude/project.yml`, not by grep): topics (`CREATE`, `DELETE`, `UPDATE_CONFIG`); cluster profiles (`CLUSTER_CREATE`, `CLUSTER_UPDATE`, `CLUSTER_DELETE`, before and after); application settings (`SETTINGS_UPDATE` — the banner and consent settings, naming the keys that changed and never their values; new in v1.1.0); service restarts (`SERVICE_RESTART`, `SERVICE_RESTART_STEP`, `SERVICE_RESTART_REFUSED`, `SERVICE_RESTART_THROTTLED`); and authentication (`LOGIN`, `LOGIN_FAILED`, `LOGIN_REFUSED`, `LOGOUT`, `SESSION_EXPIRED`). A `LOGOUT` row says in its detail whether the person signed out or the idle timeout did it, so the two are distinguishable in the export. SASL passwords are redacted and certificate paths reduced to basenames before anything is logged, because any authenticated user can export the log
- Destructive actions require name-match confirmation
- Idle session timeout: 15 minutes (configurable as `session.timeout_minutes`); background refreshes do not count as activity
- Fail-closed: application refuses to start if `secret_key` is absent or still the placeholder
- The service account holds no general privilege escalation: `NoNewPrivileges=true` (so `sudo` cannot run under the unit at all), and exactly three systemd unit/verb pairs are authorised through polkit — see [Privileges the install grants](#privileges-the-install-grants)
- The application cannot write or unlink its own `config.yaml`, and the upgrade asks the kernel to prove it as the real principal rather than reading mode bits
- **No role separation.** Every member of `required_group` can delete any topic, rewrite the cluster list and restart the service. "Authenticated" and "fully privileged in this app" are the same thing here; the audit log records who acted, it does not constrain who may

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
