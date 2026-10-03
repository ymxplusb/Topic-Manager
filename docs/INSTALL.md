# Jarvis Topic Manager — Installation Guide

**Version:** 1.2.1
**Applies to:** a FRESH install on a clean Ubuntu Server 24.04 LTS host — including a
STIG-hardened host with FIPS mode enabled — online or air-gapped.

To move an **existing** host to a new release, do not use this guide: use
`install/upgrade-full.sh`, which audits, backs up, upgrades and rolls back on failure. See
README.md → *Upgrading*.

Every name in this guide is a placeholder. `example.org`, `<dc-host>`, `<base-dn>` and the like
stand for **your** values; nothing in the product defaults to any particular site.

---

## Contents

1. [What you end up with](#1-what-you-end-up-with)
2. [Prerequisites](#2-prerequisites)
3. [Get the release](#3-get-the-release)
4. [Install — online](#4-install--online)
5. [Install — offline (air-gapped)](#5-install--offline-air-gapped)
6. [What install.sh does, step by step](#6-what-installsh-does-step-by-step)
7. [Verify the install](#7-verify-the-install)
8. [First sign-in and cluster profiles](#8-first-sign-in-and-cluster-profiles)
9. [Replace the self-signed certificate](#9-replace-the-self-signed-certificate)
10. [FIPS-mode hosts](#10-fips-mode-hosts)
11. [Firewall](#11-firewall)
12. [Upgrading later](#12-upgrading-later)

---

## 1. What you end up with

`install.sh` does not stop at "files copied". When it exits 0 the host is in this state, and
the script has **measured** each point rather than assumed it:

| Area | End state |
|---|---|
| Service | `topic-manager.service` running, `UMask=0077`, `NoNewPrivileges=true`, `ProtectSystem=strict`; gunicorn has **no TCP port** — it listens only on `/run/topic-manager/gunicorn.sock`, which `topic-manager.socket` creates `0660 topic-manager:www-data`, so nothing but nginx can reach it; `/api/health` answers `{"status":"ok",...}` through nginx |
| Web | nginx site for `--server-name` (default `hostname -f`); HTTP 80 → 301 to HTTPS only; security headers on every location |
| TLS | `/etc/nginx/nginx.conf` → `ssl_protocols TLSv1.2 TLSv1.3;` (backed up first, `nginx -t`, rolled back on failure). Site: TLS 1.2 ECDHE + AES-GCM + SHA-256/384 only, TLS 1.3 AES-GCM suites only, curves P-384/P-256, `ssl_session_timeout 15m`, `ssl_session_tickets off`, `server_tokens off` |
| Certificate | yours (`--tls-cert/--tls-key`, verified as a pair), or an existing one kept, or a **self-signed ECDSA P-256** placeholder; key `0600 root:root` |
| Config | `/etc/topic-manager/config.yaml` `0640 root:topic-manager`, written from your directory settings with a fresh random `secret_key`; no environment defaults |
| Audit DB | `/opt/topic-manager/data` `0700`, `tm.db` `0600`, both owned by `topic-manager` |
| Clusters | `/etc/topic-manager/clusters.d/clusters.yaml` `0640 topic-manager:topic-manager`, **empty** — you add clusters in Settings |
| Restart control | polkit rule `/etc/polkit-1/rules.d/50-topic-manager.rules` (eight unit/verb pairs over seven units: restart `topic-manager.service`, reload/restart `nginx.service`, start `topic-manager-nginx-test.service` and the four `topic-manager-apply-*.service`) and the root-side `topic-manager-nginx-test.service` |
| Frontend | `/var/www/topic-manager` **root:root**, dirs 0755 / files 0644 (the web server reads it and cannot rewrite it); Vue 3.5.43, **SHA-256 verified** against the pin in `install/upgrade-full.sh` before it is served |
| Python | a venv of **binary wheels only**, every package (transitive ones included) **hash-verified** against `requirements.lock`; no compiler on the host |

---

## 2. Prerequisites

### The host

- Ubuntu Server **24.04 LTS**, clean. STIG hardening (umask 077, noexec `/tmp`) and FIPS mode
  are supported; see [section 10](#10-fips-mode-hosts).
- An administrator account with `sudo`.
- A DNS name for the server, e.g. `topics.example.org`, resolving to it.

### The directory (Active Directory or another LDAPS directory)

Have these ready — `install.sh` asks for them, or takes them as flags:

| Value | Flag | Example |
|---|---|---|
| LDAPS URL of a directory server | `--ldap-url` | `ldaps://dc1.example.org:636` |
| User search base DN | `--ldap-base-dn` | `DC=example,DC=org` |
| Sign-in domain (UPN suffix) | `--ldap-domain` | `example.org` (derived from the base DN if omitted) |
| DN of the group whose members may sign in | `--ldap-group` | `CN=Kafka-Admins,OU=Groups,DC=example,DC=org` |
| *(optional)* service account for searches | `--ldap-bind-dn` | `CN=svc-topic-manager,OU=Service Accounts,DC=example,DC=org` |
| *(optional)* CA bundle for the directory's certificate | `--ldap-ca-cert` | `/usr/local/share/ca-certificates/example-root.crt` |

- Plain `ldap://` is not supported: certificate validation is enforced. The directory's CA must
  be trusted by the host (system store) or given with `--ldap-ca-cert`.
- With no service account, each user's own credentials are used for the directory search
  (direct bind). With one, its password is read from `TM_LDAP_BIND_PASSWORD` or a silent
  prompt — never from the command line.
- To find a group's DN, from a host that can reach the directory:

  ```bash
  ldapsearch -H ldaps://<dc-host>:636 -D "<you>@<domain>" -W \
    -b "<base-dn>" "(&(objectClass=group)(cn=<group-name>))" distinguishedName
  ```

### Network

What the host must reach is in `PPSM.csv` (the same document as *Settings → Support → Download
PPSM*). In short: inbound 443 (and 80 for the redirect, 22 for administration); outbound LDAPS
636 to the directory, the Kafka brokers at the ports your cluster profiles name, DNS and NTP. An
**online** install additionally needs HTTPS to the Ubuntu mirror, PyPI and `cdn.jsdelivr.net`;
an **offline** install needs none of them.

### Optional: your certificate

A certificate and key for the server name, issued by your CA (PEM). Without one, a self-signed
placeholder is generated and you replace it later ([section 9](#9-replace-the-self-signed-certificate)).

---

## 3. Get the release

Use whichever your site publishes:

- **The release tarball** from your site's package registry, with its `.sha256`:

  ```bash
  sha256sum -c topic-manager-<version>.tar.gz.sha256
  tar xzf topic-manager-<version>.tar.gz && cd topic-manager-<version>
  ```

- **A git clone** of your site's copy of the repository, at the release tag:

  ```bash
  git clone --branch v<version> --depth 1 <your-git-url> topic-manager && cd topic-manager
  ```

- **The offline bundle** for an air-gapped host — see [section 5](#5-install--offline-air-gapped).

Root executes this tree, so keep it somewhere only root can write (not a world-writable
directory such as `/tmp`).

---

## 4. Install — online

On the server, from the release directory:

```bash
sudo bash install.sh \
    --ldap-url      ldaps://dc1.example.org:636 \
    --ldap-base-dn  "DC=example,DC=org" \
    --ldap-group    "CN=Kafka-Admins,OU=Groups,DC=example,DC=org" \
    --server-name   topics.example.org
```

Add `--tls-cert /path/server.crt --tls-key /path/server.key` to install your certificate, and
`--ldap-bind-dn ...` for a service account (the password is prompted for, or taken from
`TM_LDAP_BIND_PASSWORD`). Run `sudo bash install.sh` with no directory flags on a terminal to be
asked for each value instead. `--non-interactive` turns any missing required value into a
refusal instead of a prompt — use it from automation.

**Host settings (v1.2.0), all optional** — each is a Settings pane afterwards; a flag only
seeds it, and the install then applies it through the same root helper the pane uses:

```bash
    --syslog-host logs.example.org --syslog-protocol tls --syslog-port 6514 \
    --syslog-app-id topic-manager --syslog-ca /path/collector-ca.pem \
    --ntp-server ntp1.example.org,ntp2.example.org \
    --no-http-redirect          # no :80 listener, ufw 80/tcp stays closed
    --install-chrony            # see below
```

A bad value stops the install before anything changes. **Time daemon:** the install keeps
whichever of chrony and systemd-timesyncd runs. It installs chrony only on a host with
neither, or with `--install-chrony` — and chrony **conflicts with systemd-timesyncd: installing
it removes systemd-timesyncd**. That is the only package removal the installer ever allows
(checked in apt's simulated plan; anything else it would remove is refused). A STIG'd Ubuntu
24.04 host already runs chrony.

The script ends with the URL and a running service. If it stops, it says why, and nothing
half-configured is left claiming success; see TROUBLESHOOTING.md.

---

## 5. Install — offline (air-gapped)

### 5a. On a connected machine — build the bundle

Use a **fully patched** (`apt update && apt full-upgrade`) **Ubuntu 24.04** machine of the
**same architecture** as the target (the `.deb` closure and the wheels are
architecture-specific), with a clone of the release. It must be at least as patched as the
target: the bundle can only upgrade the target to versions the build host could download.

**Build-host prerequisites.** A stock Ubuntu 24.04 (a server, or the `ubuntu:24.04`
container) has none of these; install them first. On a server, as an administrator:

```bash
sudo apt-get update && sudo apt-get install -y git python3 python3-pip curl apt-utils
```

In the `ubuntu:24.04` container you are already root and the image has **no `sudo`**
(`sudo: command not found`), so drop it:

```bash
apt-get update && apt-get install -y git python3 python3-pip curl apt-utils
```

`git` (the bundle is `git archive` of the checkout), `python3` and `python3-pip` (the lock
gate and `pip download`), `curl` (Vue and the PyPI hash check), and `apt-utils` or `dpkg-dev`
(the bundle's apt index). `prepare-offline.sh` names any that is missing before it downloads
anything, rather than failing later with a network error.

**Check out the release.** Once it is tagged, the tag:

```bash
git fetch --tags origin && git checkout v<version>
```

**Before it is tagged** (a release candidate, or a QC build) there is no tag to check out.
Build from the release branch at the exact commit under review, and record that commit id
with the bundle — it is what the bundle's `.sha256` then vouches for:

```bash
git fetch origin release/v<version>
git checkout --detach <40-hex commit id under review>
git rev-parse HEAD            # write this down beside the bundle's checksum
```

Then build:

```bash
bash prepare-offline.sh --bundle
```

This downloads the pinned wheels (binary only, verified against `requirements.txt`), Vue
(verified against its SHA-256 pin), and the runtime `.deb`s with their dependency closure, then
builds `../topic-manager-offline-<version>.tar.gz` and its `.sha256`.

The `.deb` set also carries every **lockstep sibling**: each binary built from the same Debian
source, at the same source version, as a package in the closure (for example
`libpython3.12t64` beside `python3.12`). Binaries of one source depend on each other's exact
version, so a target that has an older `libpython3.12t64` installed can only take the newer
`python3.12` if the newer `libpython3.12t64` comes with it — otherwise apt's only way out is to
remove it. Siblings are for this architecture and `all`; `-dbg`, `-dbgsym`, `-doc` and
debug-section packages are skipped; a source with more than 40 siblings (a compiler suite) is
reported and not expanded. The build prints what it added
(`lockstep siblings (same source): N added: ...`) and names any sibling it could not download.

The bundle is built from the **committed tree** (`git archive`), never from the working
directory: the repository's own process records (`.claude/`, `.work/`) are export-ignored,
untracked files are left out, and `tools/check-env-neutral.sh --bundle` deletes the bundle if
anything internal or site-specific got in.

### 5b. On the air-gapped host — install

Carry the bundle and its `.sha256` across. **Check the checksum against a value you obtained
out of band** — from the release record, or read off the build host by a second person — not
only against the `.sha256` that travelled with the bundle, which proves integrity in transit
but not origin. Then:

Root runs `install.sh`, so the tree it runs from is created **root-owned** first and the
bundle is unpacked straight into it (`--strip-components=1` drops the `topic-manager-<version>/`
directory the tarball wraps everything in); nothing is staged where another account could
change it before root reads it. This is the same procedure `prepare-offline.sh` prints and
README.md -> *Offline Install* gives:

```bash
sha256sum -c topic-manager-offline-<version>.tar.gz.sha256
sha256sum topic-manager-offline-<version>.tar.gz      # must equal the out-of-band value
sudo install -d -m 700 -o root -g root /var/lib/topic-manager/install-src
sudo tar xzf topic-manager-offline-<version>.tar.gz -C /var/lib/topic-manager/install-src --strip-components=1
sudo bash /var/lib/topic-manager/install-src/install.sh \
    --ldap-url ldaps://dc1.example.org:636 --ldap-base-dn "DC=example,DC=org" \
    --ldap-group "CN=Kafka-Admins,OU=Groups,DC=example,DC=org" --server-name topics.example.org
```

With no network, `install.sh` uses the bundle's `.deb`s as a private apt **repository**: apt's
own resolver installs only the missing top-level packages, nothing is downloaded, and the
temporary apt configuration (its own sources **and** preferences; the host's
`sources.list.d` and `preferences.d` are not read) is removed afterwards, on success or failure.
The package policy is **never downgrade, never replace a FIPS package, but upgrade what a
dependency needs**:

- An air-gapped host lags on patches, so a new package often needs a newer build of a library
  that is already installed (for example `python3.12-venv` needs the matching `python3.12`).
  The bundle sits at apt priority 500, so apt may **upgrade** that library to the bundled build.
  Below priority 1000 apt never picks a version older than the installed one, so nothing is
  **downgraded**, and `--no-remove` means nothing is removed.
- Every installed package whose version contains `fips` (Ubuntu Pro FIPS builds such as
  `libssl3t64`, `openssl`, `openssh-*`, `libgcrypt20`, GnuTLS, strongSwan, the kernel), or whose
  installed version came from an Ubuntu Pro FIPS archive (`esm.ubuntu.com/fips`, `fips-updates`),
  gets a pin of **-1 for the bundle's copy**, generated at install time from `dpkg-query` and
  `apt-cache policy`. A FIPS module is never swapped for a non-FIPS build; if a bundled package
  needs a newer one, the install stops and names it.
- Before anything is installed, apt **simulates** the request and `install.sh` prints one line:

  ```
  [INFO] Offline package plan — NEW (2): nginx=1.24.0-2ubuntu7.5 python3.12-venv=3.12.3-1ubuntu0.17; UPGRADE (1): python3.12=3.12.3-1ubuntu0.17 (from 3.12.3-1ubuntu0.13)
  ```

  On a terminal you are asked `Apply this package plan? [y/N]`; with `--non-interactive` (or no
  terminal) it proceeds. A plan that would downgrade, remove, or replace a FIPS package is
  refused outright. If apt could only proceed by **removing** packages, the refusal names the
  ones that are lockstep siblings missing from the bundle and the ones that would go with them;
  rebuild the bundle (5a) on a fully patched build host.

Python comes from the bundled wheels, each checked against its SHA-256 in `requirements.lock`;
Vue from the bundle, hash-verified.

---

## 6. What install.sh does, step by step

1. Sets `umask 0022` for its own run (a STIG host's 077 would leave the venv and frontend
   unreadable to the service and nginx); every sensitive file is then given its mode explicitly.
2. Detects online/offline.
3. On a host with no `config.yaml`, collects the directory settings (flags, else prompts) —
   **before** anything is installed, so a missing value stops an untouched host.
4. Installs any missing runtime package: `python3 python3-venv nginx polkitd rsync sudo curl
   ca-certificates openssl rsyslog rsyslog-openssl`. It asks for no compiler and no `-dev`
   headers (the offline bundle CARRIES some as lockstep siblings; apt never installs one that
   is not already installed — `install/README.md`). Then the
   time daemon: chrony is kept, systemd-timesyncd is kept unless `--install-chrony`, and a host
   with neither gets chrony (v1.2.0).
5. Creates the `topic-manager` system account and the directories:
   `/opt/topic-manager` (0750), `logs` (0750), `data` (**0700**), `/etc/topic-manager` (0750
   `root:topic-manager`), `tls` (0750), `clusters.d` (0750, app-owned), `data/cluster-certs`
   (0700), `/var/backups/topic-manager` (0700 root).
6. Builds the venv from binary wheels (`--only-binary :all:`).
7. On a host that **already** has `config.yaml`: refuses to continue if it lacks
   `auth.ldap_server`, `auth.ldap_base_dn` or `auth.ldap_domain` — checked **before** new code is
   copied in, because v1.1.0 has no built-in directory defaults and would lock everyone out.
8. Deploys the backend, then narrows the audit database (`enforce_audit_db_modes`).
9. Installs Vue 3.5.43 after verifying its SHA-256, and the frontend.
10. Writes `config.yaml` (0640 `root:topic-manager`, in one `install(1)` step) with your
    directory settings and a new random `secret_key`, or keeps the existing one.
11. Creates an **empty** cluster store (or migrates a legacy `clusters:` block on a reinstall).
    `config/clusters.yaml.example` is a format reference and is never imported.
12. Installs the systemd units and the polkit rule; v1.2.0 adds `topic-manager.socket` (the
    only way to reach gunicorn: `/run/topic-manager/gunicorn.sock`, 0660
    `topic-manager:www-data`), the root apply helper (`/usr/libexec/topic-manager/tm-apply`,
    `root:root`), its four one-shot units, the apply-result audit (`topic-manager-apply-audit.path`)
    and the audit prune timer. A reinstall stops the service, its socket and the timers FIRST,
    before any directory is touched. The host-setting flags are saved to `tm.db` here, as the service account.
13. Installs the nginx site and security-header snippet, the Settings-managed nginx and
    rsyslog files where absent (rate limits, syslog: the release defaults), the `:80` redirect
    site (enabled only if the redirect setting is on), the certificate (yours, existing, or a
    self-signed ECDSA P-256 placeholder), and sets `ssl_protocols TLSv1.2 TLSv1.3` in
    `nginx.conf` (backup in `/var/backups/topic-manager/`, `nginx -t`, rolled back on failure).
14. Opens 443 in ufw if ufw is active — and 80 only while the HTTP redirect is on; installs log
    rotation.
15. `nginx -t` (fatal on failure), then asks the kernel — as the service account — that the app
    can write `clusters.d` and can **not** write `config.yaml` or its directory.
16. Starts the service and nginx, waits for `/api/health`, and measures `tm.db` 0600 and
    `data/` 0700.
17. Applies the saved host settings (syslog, time, nginx) through the apply units and reads
    each verdict back; a failed domain was rolled back by the helper and stops the install with
    its reason. Enables the daily audit prune timer.

---

## 7. Verify the install

```bash
curl -sk https://localhost/api/health
#   {"status":"ok","version":"<version>"}

curl -skI https://localhost/ | grep -iE 'strict-transport|content-security|x-content-type|referrer'
curl -skI https://localhost/app/main.js | grep -ic 'content-security-policy'    # 1

grep -E '^\s*ssl_protocols' /etc/nginx/nginx.conf
#   ssl_protocols TLSv1.2 TLSv1.3; # managed by Topic Manager: TLS 1.2/1.3 only

# TLS 1.0 / 1.1 must be refused BY THE SERVER. Probe from a machine that is NOT in FIPS
# mode: a FIPS client (this host, if FIPS is on) refuses TLS 1.1 ITSELF and prints
# "no protocols available" without sending a byte — that proves nothing about the server.
# The probe needs OpenSSL 3 (`openssl version` -> "OpenSSL 3.x"): @SECLEVEL=0 is what lets
# a modern client OFFER TLS 1.1 at all, and LibreSSL (the macOS /usr/bin/openssl, e.g.
# 3.3.6) does not understand it and errors before connecting — no result either way.
openssl s_client -connect <server-name>:443 -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0' </dev/null 2>&1 \
    | grep -E 'alert protocol version|handshake failure|no protocols available|Cipher is'
# Read the "Cipher is" line by its VALUE — a refused handshake prints one too:
#   ...tlsv1 alert protocol version...  or  ...handshake failure...
#   New, (NONE), Cipher is (NONE)                <- the SERVER refused: pass
#   ...no protocols available...                 <- YOUR client refused: no result; use another client
#   New, TLSv1.1, Cipher is <a cipher name>      <- the server ACCEPTED TLS 1.1: fail
# Only a real cipher name (not "(NONE)") after "Cipher is" means TLS 1.1 was accepted.
# The configuration half, on the host: every ssl_protocols nginx will use is TLSv1.2 TLSv1.3
sudo nginx -T 2>/dev/null | grep -E '^[[:space:]]*ssl_protocols'

sudo stat -c '%a %U %n' /opt/topic-manager/data /opt/topic-manager/data/tm.db
#   700 topic-manager /opt/topic-manager/data
#   600 topic-manager /opt/topic-manager/data/tm.db

# v1.2.0: every apply the install made, and the prune timer
sudo cat /run/topic-manager-apply/nginx.result | python3 -m json.tool | grep '"state"'
#   "state": "ok",
systemctl list-timers topic-manager-audit-prune.timer --no-pager | tail -n +2 | head -1
```

---

## 8. First sign-in and cluster profiles

Browse to `https://<server-name>/` and sign in as a member of the group you gave with
`--ldap-group`. A new install has **no Kafka clusters**: open **Settings → General → Cluster
Profiles → + Add Cluster**, enter the bootstrap servers and security protocol, upload CA /
client certificates if the cluster uses TLS, **Test**, then **Set Active**. Every change is
written to the audit log.

---

## 9. Replace the self-signed certificate

```bash
sudo install -m 644 -o root -g root server.crt /etc/topic-manager/tls/server.crt
sudo install -m 600 -o root -g root server.key /etc/topic-manager/tls/server.key
sudo nginx -t && sudo systemctl reload nginx
```

Use an ECDSA P-256/P-384 or RSA ≥ 2048 key signed with SHA-256 or stronger, with the server
name in the subjectAltName. `openssl x509 -noout -pubkey -in server.crt` and `openssl pkey
-pubout -in server.key` must print the same key.

---

## 10. FIPS-mode hosts

The product runs on a FIPS-enabled Ubuntu 24.04 host. What is FIPS-relevant, and what is not
covered by the host's validated module:

- **nginx TLS** uses the host's OpenSSL, i.e. the validated FIPS provider when FIPS mode is on.
  The cipher list is FIPS-approved only (section 1), so nothing it offers is refused by the
  provider.
- **The session cookie** is signed with HMAC-SHA-256 (not Flask's default SHA-1).
- **LDAPS** runs over Python's `ssl` module, which uses the host's OpenSSL. SIMPLE bind only;
  no NTLM or DIGEST-MD5.
- **Random values** (`secret_key`, session ids, file names) come from the kernel CSPRNG.
- **Known limitation — module boundary.** The `cryptography` and `confluent-kafka` wheels
  **bundle their own OpenSSL**, which is **not** the host's FIPS-validated module.
  `cryptography` is used to parse the PEM certificates you upload for a cluster profile;
  `confluent-kafka` (librdkafka) makes the TLS connection to SSL/SASL_SSL Kafka brokers. Both
  **run** on a FIPS host; their cryptography is simply outside the host's validated boundary. If
  your accreditation requires every TLS connection to use the validated module, keep Kafka on a
  network path your boundary already covers, or record this as an accepted limitation.
- **Risk acceptance — Kafka client TLS (accepted by the system owner, 2026-09-26).** Because
  the `confluent-kafka` 2.15.1 wheel bundles librdkafka and its own OpenSSL, Kafka client TLS
  runs outside the host's FIPS 140-3 validated module even with `fips_enabled=1` (SC-13;
  SRG-APP-000014 / SRG-APP-000514; CWE-327). Compensating: configure every Kafka profile with
  `SSL` or `SASL_SSL`; nginx, LDAPS and Python `ssl` use the validated module (measured on a
  STIG + FIPS Ubuntu 24.04 host: `fips_enabled=1`, "Ubuntu 24.04 OpenSSL Cryptographic Module
  3.0.13+Fips2"). To remove the risk, install the distribution's `python3-confluent-kafka`
  (linked to the system OpenSSL) or a wheel built on site against the system libssl. See
  SBOM.md → *Risk acceptance*.
- The self-signed placeholder is generated with `openssl req ... ec P-256 -sha256`, which works
  under FIPS mode.
- **TLS 1.2 clients must offer the extended master secret (RFC 7627).** The FIPS provider
  refuses a TLS 1.2 handshake without it: the cipher is agreed and the server then aborts
  (alert 80, `internal_error`). Current browsers, OpenSSL 1.1.0 and later, and Java 8u161 and
  later all send it; **LibreSSL 3.3 (macOS's `/usr/bin/openssl`) does not** — measured against
  a FIPS host on 2026-09-29. Use TLS 1.3, or a client that sends the extension; nothing on the
  server side can or should relax this.

---

## 11. Firewall

If `ufw` is active, `install.sh` opens 443/tcp, and 80/tcp while the HTTP redirect is on
(`ufw allow 80/tcp`, `ufw allow 443/tcp`); turning the redirect off in Settings removes the
80/tcp rule, and a reinstall does not add it back (v1.2.0). If ufw refuses a rule, the install finishes with a warning naming the port and ufw's
reason, and does not claim the ports are open. Otherwise open them yourself, and
nothing else is needed inbound except SSH for administration. The complete inventory is
`PPSM.csv`.

**Postfix (25/tcp), a host service this product does not use.** A STIG baseline installs
Postfix for audit alerts, and as installed it listens on **every** interface (`ss -ltn` shows
`0.0.0.0:25` and `[::]:25`; `postconf inet_interfaces` answers `all`). `install.sh` leaves
it alone: the MTA belongs to the host baseline, not to this product, and the product relies
on no mail at all. If the host only ever sends mail by local submission (the audit-alert case),
narrow it:

```bash
sudo postconf -e inet_interfaces=loopback-only && sudo systemctl restart postfix
ss -ltn | grep ':25 '      # 127.0.0.1:25 and [::1]:25 only
```

or leave it and block 25/tcp at the host firewall. `PPSM.csv` lists it as found (Inbound).

---

## 12. Upgrading later

```bash
# online: from the git URL your site publishes the release at — there is no default —
# pinned to the release's full commit id, taken out of band (release notes / tag pipeline)
sudo bash install/upgrade-full.sh --audit-only --repo-url <your-git-url> --repo-branch v<next> --repo-commit <40-hex-sha>
sudo bash install/upgrade-full.sh --repo-url <your-git-url> --repo-branch v<next> --repo-commit <40-hex-sha>

# offline: from a bundle staged at /var/lib/topic-manager/offline-src (README.md ->
# *Offline (air-gapped) upgrade* for the checksum and staging steps). Every step takes
# --offline and is run from the staged tree, by its absolute path:
sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --audit-only --offline
#   exit 0 clear / 1 warnings only (proceed if each is a change this release makes) / 2 blockers
sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --backup-only --offline
sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --offline
# a runtime package the new release needs and the air-gapped host lacks (v1.2.0:
# rsyslog-openssl, for Remote syslog over TLS) — from the same bundle, nothing else changed:
sudo bash /var/lib/topic-manager/offline-src/install.sh --packages-only
```

**Run the upgrade (and a `--restore`) detached, with a log file**, so a dropped SSH session
cannot kill it mid-phase:
```bash
sudo -v                       # enter the password now: a backgrounded sudo cannot ask for it
sudo setsid nohup bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --offline \
    > ~/tm-upgrade.out 2>&1 < /dev/null &
tail -f ~/tm-upgrade.out      # Ctrl-C ends only the tail
```
or inside `tmux new -s tm-upgrade`. The script's own log is `/var/log/topic-manager-upgrade-<TIMESTAMP>.log`.
The exit code of a detached run is its LAST line, in both: `tail -n 1 ~/tm-upgrade.out` shows
`RESULT: exit 0` when it finished and verified, `RESULT: exit <N>` when it stopped (the lines
above say why; a failed upgrade has already rolled back; for `--restore`, 1 is
`RESTORE INCOMPLETE`). No `RESULT:` line yet: still running (`pgrep -af upgrade-full.sh`), or
killed outright — read the log.
`install.sh` and the upgrade WAIT for the package lock (up to 600 s, `TM_DPKG_LOCK_WAIT_S`),
naming the process that holds it — on an air-gapped host usually unattended-upgrades.

See README.md → *Upgrading* and `install/README.md`.
