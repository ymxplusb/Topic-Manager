# Jarvis Topic Manager — Installation Guide

**Version:** 1.1.0
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
| Service | `topic-manager.service` running (gunicorn on 127.0.0.1:5001), `UMask=0077`, `NoNewPrivileges=true`, `ProtectSystem=strict`; `/api/health` answers `{"status":"ok",...}` through nginx |
| Web | nginx site for `--server-name` (default `hostname -f`); HTTP 80 → 301 to HTTPS only; security headers on every location |
| TLS | `/etc/nginx/nginx.conf` → `ssl_protocols TLSv1.2 TLSv1.3;` (backed up first, `nginx -t`, rolled back on failure). Site: TLS 1.2 ECDHE + AES-GCM + SHA-256/384 only, TLS 1.3 AES-GCM suites only, curves P-384/P-256, `ssl_session_timeout 15m`, `ssl_session_tickets off`, `server_tokens off` |
| Certificate | yours (`--tls-cert/--tls-key`, verified as a pair), or an existing one kept, or a **self-signed ECDSA P-256** placeholder; key `0600 root:root` |
| Config | `/etc/topic-manager/config.yaml` `0640 root:topic-manager`, written from your directory settings with a fresh random `secret_key`; no environment defaults |
| Audit DB | `/opt/topic-manager/data` `0700`, `tm.db` `0600`, both owned by `topic-manager` |
| Clusters | `/etc/topic-manager/clusters.d/clusters.yaml` `0640 topic-manager:topic-manager`, **empty** — you add clusters in Settings |
| Restart control | polkit rule `/etc/polkit-1/rules.d/50-topic-manager.rules` (three unit/verb pairs) and the root-side `topic-manager-nginx-test.service` |
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

The script ends with the URL and a running service. If it stops, it says why, and nothing
half-configured is left claiming success; see TROUBLESHOOTING.md.

---

## 5. Install — offline (air-gapped)

### 5a. On a connected machine — build the bundle

Use an **Ubuntu 24.04** machine of the **same architecture** as the target (the `.deb`
closure and the wheels are architecture-specific), with a clone of the release:

```bash
git checkout v<version>
bash prepare-offline.sh --bundle
```

This downloads the pinned wheels (binary only, verified against `requirements.txt`), Vue
(verified against its SHA-256 pin), and the runtime `.deb`s with their dependency closure, then
builds `../topic-manager-offline-<version>.tar.gz` and its `.sha256`.

The bundle is built from the **committed tree** (`git archive`), never from the working
directory: the repository's own process records (`.claude/`, `.work/`) are export-ignored,
untracked files are left out, and `tools/check-env-neutral.sh --bundle` deletes the bundle if
anything internal or site-specific got in.

### 5b. On the air-gapped host — install

Carry the bundle and its `.sha256` across. **Check the checksum against a value you obtained
out of band** — from the release record, or read off the build host by a second person — not
only against the `.sha256` that travelled with the bundle, which proves integrity in transit
but not origin. Then:

```bash
sha256sum -c topic-manager-offline-<version>.tar.gz.sha256
tar xzf topic-manager-offline-<version>.tar.gz && cd topic-manager-<version>
sudo bash install.sh \
    --ldap-url ldaps://dc1.example.org:636 --ldap-base-dn "DC=example,DC=org" \
    --ldap-group "CN=Kafka-Admins,OU=Groups,DC=example,DC=org" --server-name topics.example.org
```

With no network, `install.sh` uses the bundle's `.deb`s as a private apt **repository**: apt's
own resolver installs only the missing top-level packages, the bundle is pinned below every
installed package (a FIPS `libssl` or `openssh` is never replaced), nothing is downloaded, and
the temporary apt configuration is removed afterwards. Python comes from the bundled wheels,
each checked against its SHA-256 in `requirements.lock`; Vue from the bundle, hash-verified.

---

## 6. What install.sh does, step by step

1. Sets `umask 0022` for its own run (a STIG host's 077 would leave the venv and frontend
   unreadable to the service and nginx); every sensitive file is then given its mode explicitly.
2. Detects online/offline.
3. On a host with no `config.yaml`, collects the directory settings (flags, else prompts) —
   **before** anything is installed, so a missing value stops an untouched host.
4. Installs any missing runtime package: `python3 python3-venv nginx polkitd rsync sudo curl
   ca-certificates openssl`. No compiler, no `-dev` headers.
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
12. Installs the systemd units and the polkit rule.
13. Installs the nginx site and security-header snippet, the certificate (yours, existing, or a
    self-signed ECDSA P-256 placeholder), and sets `ssl_protocols TLSv1.2 TLSv1.3` in
    `nginx.conf` (backup in `/var/backups/topic-manager/`, `nginx -t`, rolled back on failure).
14. Opens 80/443 in ufw if ufw is active; installs log rotation.
15. `nginx -t` (fatal on failure), then asks the kernel — as the service account — that the app
    can write `clusters.d` and can **not** write `config.yaml` or its directory.
16. Starts the service and nginx, waits for `/api/health`, and measures `tm.db` 0600 and
    `data/` 0700.

---

## 7. Verify the install

```bash
curl -sk https://localhost/api/health
#   {"status":"ok","version":"<version>"}

curl -skI https://localhost/ | grep -iE 'strict-transport|content-security|x-content-type|referrer'
curl -skI https://localhost/app/main.js | grep -ic 'content-security-policy'    # 1

grep -E '^\s*ssl_protocols' /etc/nginx/nginx.conf
#   ssl_protocols TLSv1.2 TLSv1.3; # managed by Topic Manager: TLS 1.2/1.3 only

openssl s_client -connect localhost:443 -tls1_1 </dev/null 2>&1 | grep -c 'Cipher is (NONE)\|alert'
#   TLS 1.1 must be refused

sudo stat -c '%a %U %n' /opt/topic-manager/data /opt/topic-manager/data/tm.db
#   700 topic-manager /opt/topic-manager/data
#   600 topic-manager /opt/topic-manager/data/tm.db
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
- The self-signed placeholder is generated with `openssl req ... ec P-256 -sha256`, which works
  under FIPS mode.

---

## 11. Firewall

If `ufw` is active, `install.sh` opens 80/tcp and 443/tcp. Otherwise open them yourself, and
nothing else is needed inbound except SSH for administration. The complete inventory is
`PPSM.csv`.

---

## 12. Upgrading later

```bash
# online: from the git URL your site publishes the release at — there is no default —
# pinned to the release's full commit id, taken out of band (release notes / tag pipeline)
sudo bash install/upgrade-full.sh --audit-only --repo-url <your-git-url> --repo-branch v<next> --repo-commit <40-hex-sha>
sudo bash install/upgrade-full.sh --repo-url <your-git-url> --repo-branch v<next> --repo-commit <40-hex-sha>

# offline: from a bundle staged at /var/lib/topic-manager/offline-src
sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --offline
```

See README.md → *Upgrading* and `install/README.md`.
