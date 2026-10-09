# Offline Bundle Contract

Run `prepare-offline.sh` on an internet-connected machine **before** transferring anything
to an air-gapped host. It is the only supported way to build a bundle, because it is the
only thing that checks the bundle is complete while there is still a network to fix it with.

## What the bundle contains

| Path (relative to the repo) | Contents |
|---|---|
| `install/packages/python/` | One **binary wheel** for **every** `==` pin in `requirements.txt` (and their dependencies), for CPython 3.12 manylinux. `prepare-offline.sh` refuses to declare the bundle good if any pin has no matching artefact; `install.sh` installs with `--only-binary :all:`, so nothing is compiled on the target |
| `install/packages/apt/` | The runtime packages `install.sh` needs — `python3 python3-venv nginx polkitd rsync sudo curl ca-certificates openssl rsyslog rsyslog-openssl`, plus `chrony` (v1.2.0; installed only where no time daemon runs or `--install-chrony` asks, because it REMOVES `systemd-timesyncd`, the one removal the installer allows) — **with their dependency closure and every lockstep sibling** (each binary built from the same Debian source and source version as a closure package, e.g. `libpython3.12t64` beside `python3.12`). Only downloaded when the bundling machine is Ubuntu (it must be 24.04, same architecture as the target). `install.sh` asks apt only for those the host does not already have; apt may **upgrade** an installed dependency to the bundled build when one needs it, never downgrades, never removes, and never replaces a FIPS package (see docs/INSTALL.md §5b). Build it on a fully patched host. **What is carried is more than what is installed:** measured on the v1.2.0 build (2026-09-29) the directory held **520 packages, 187 MB**, 373 of them lockstep siblings — among them `libc6-dev`, `python3-dev`, `slapd` and `krb5-kdc` (binaries of the `glibc`, `python3-defaults`, `openldap` and `krb5` sources, which closure packages come from). They are there so an INSTALLED sibling can be upgraded in step (the v1.2.0 round-4 failure); apt installs only the missing top-level runtime packages and their dependencies, so a sibling that is not already installed is never installed, and no compiler reaches the host |
| `lib/vue.global.prod.js` | Vue, at the version **and SHA-256** pinned in `install/upgrade-full.sh`, verified after download and written byte-for-byte — nothing is prepended to it |
| everything else | The **committed** tree, from `git archive` of HEAD: `tm/` (including `tm/migrate_clusters.py`, which both the installer and the upgrade run), `app/`, `index.html`, `nginx/`, `systemd/` (every unit: `topic-manager.service` and its `topic-manager.socket`, `topic-manager-nginx-test.service`, the four apply units, the apply-result audit `.path`/`.service` and the audit prune `.service`/`.timer`), `install/polkit/50-topic-manager.rules`, `config/` (`config.yaml.example`, and `clusters.yaml.example` as a format reference only), `requirements.txt`, the docs and the tests |

**What is never in it (v1.1.0).** The bundle used to be a tarball of the whole working
directory, so it carried the repository's own process records — `.claude/` (the agent
contract) and `.work/` (work orders naming production hosts) — plus dated scan reports and any
untracked file. It is now built from `git archive`, `.gitattributes` export-ignores the
process records, and `tools/check-env-neutral.sh --bundle` scans the finished tarball: any
`.claude/`, `.work/`, `.git/`, `.github/` or scan report inside it, or any site-specific host
name, address, account or path in its text, and the bundle is **deleted**, not shipped.
Outside a git checkout an explicit allowlist of the shipped paths is used instead.

`bash prepare-offline.sh --bundle` additionally writes
`topic-manager-offline-<VERSION>.tar.gz` and `topic-manager-offline-<VERSION>.tar.gz.sha256`
one directory **above** the repo. The tarball extracts to `topic-manager-<VERSION>/`.

## The contract both sides must satisfy

`requirements.txt` is the single source of truth for every Python pin. The bundler downloads
exactly those versions; `install/upgrade-full.sh` reads the same file out of the transferred
tree and installs exactly those versions with `pip --no-index --find-links`. Neither script
keeps a second copy of a version number. If they ever disagree again, the failure appears on
the air-gapped host, which is the one place it cannot be fixed.

**v1.3.3 — pip is one of those pins.** `requirements.txt` pins the venv's own `pip`
("venv tooling") and `requirements.lock` carries its hash, so the bundle carries its wheel.
Both installers upgrade the new venv's pip to that wheel (`--require-hashes`, from the
bundle offline, PyPI online) **before** installing the application packages, and then require
the venv to hold **exactly** the locked set — no extra package, none missing, no other
version — or the run fails (the upgrade rolls back).

The Vue version and hash live in `install/upgrade-full.sh` — the script that verifies the
file on the target — and `prepare-offline.sh` reads them from there.

## Using the bundle

**Fresh install** on an air-gapped host: check the `.sha256`, extract the tarball, and run
`install.sh` from it with the directory flags (`--ldap-url`, `--ldap-base-dn`, `--ldap-group`;
see `docs/INSTALL.md` section 5). It detects offline mode and installs from
`install/packages/` and the bundled, hash-verified `lib/vue.global.prod.js`.

**Upgrading an existing host**: do **not** run `install.sh` — it uses `rsync -a --delete`.
Use the upgrade script, which reads the bundle from one fixed path:

```bash
sudo install -d -m 700 -o root -g root /var/lib/topic-manager/offline-src
# A newer bundle goes into an EMPTY directory: tar does not remove what the last
# bundle left, and a leftover would be read as part of this one.
sudo find /var/lib/topic-manager/offline-src -mindepth 1 -delete
sudo tar xzf topic-manager-offline-<version>.tar.gz   -C /var/lib/topic-manager/offline-src --strip-components=1

sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --offline --syslog-host <collector>
```

**v1.3.0:** the upgrade (and `--audit-only`) needs ONE of `--syslog-host <collector>` (the audit
trail is forwarded there; `--syslog-port`/`--syslog-protocol` as needed) or `--no-remote-syslog`
(there is no collector: the trail stays on this host, an open item on the compliance page) —
unless the saved settings already forward it. Without either the upgrade refuses with exit 1
(after the backup, before any change) and `--force` does not override it; `--backup-only` needs
neither.

Check the tarball before extracting it (its `.sha256`, and the value recorded out of band),
and run `--audit-only --offline --syslog-host <collector>` (or `--no-remote-syslog`) and
`--backup-only --offline` first — README.md → *Offline
(air-gapped) upgrade* has the full sequence. A runtime package the release added and the host
lacks (v1.2.0: `rsyslog-openssl`) is installed from the bundle with
`sudo bash /var/lib/topic-manager/offline-src/install.sh --packages-only`, which changes nothing
else; the upgrade itself patches no OS package offline.

`/var/lib/topic-manager/offline-src` is not configurable, and it is deliberately NOT under `/tmp`.

> **Why not `/tmp`.** Root reads this tree and then rsyncs `tm/` into `/opt`, installs a
> systemd unit and an nginx site, and pip-installs wheels from it. A fixed name under a
> world-writable directory lets any local account that creates it first choose what root
> executes — and `mkdir -p` on an existing directory succeeds while leaving its ownership
> alone, so the documented steps would not notice. The upgrade script now asserts that the
> directory **and every ancestor** are root-owned and not group/other-writable before it
> reads a single byte, and refuses otherwise.
>
> The same reasoning applies to the *staging* step. The extraction above writes straight into
> the root-owned destination with `--strip-components=1`; it never lands in `/tmp` first. An
> unpack into `/tmp` followed by `mv` hands the same problem back — the directory `tar`
> extracts into is created by whoever gets there first, and root then reads every byte of it.

It is not configurable and is not searched for. The bundle is
left in place after a successful run — an air-gapped host cannot fetch another one, and a
re-upgrade after a `--restore` needs it.

Full procedure with the transfer steps: README.md → *Offline (air-gapped) upgrade*.

## Other contents of this directory

| | |
|---|---|
| `upgrade-full.sh` | The upgrade script. See README.md → *Upgrading* |
| `logrotate.d/topic-manager` | Deployed to `/etc/logrotate.d/` by both `install.sh` and the upgrade |
| `polkit/50-topic-manager.rules` | Installed to `/etc/polkit-1/rules.d/` by both `install.sh` and the upgrade, `root:root 0644`. It authorises the `topic-manager` account for exactly nine systemd unit/verb pairs, over eight units — `restart topic-manager.service`, `reload`/`restart nginx.service`, `start topic-manager-nginx-test.service`, and (v1.2.0) `start` on `topic-manager-apply-{syslog,time,nginx,tls}.service`, (v1.3.0) on the read-only `topic-manager-apply-compliance.service` — and returns `NOT_HANDLED` for everything else. No `stop`, no `kill`. Both scripts warn and continue if `/etc/polkit-1/rules.d` does not exist: only the Settings restart control depends on it. See README.md → *Privileges the install grants* |

| `libexec/tm-apply` | v1.2.0: the ROOT apply helper, installed `root:root 0755` to `/usr/libexec/topic-manager/` with root-owned copies of `tm/settings_schema.py` and `tm/tls_check.py` in `lib/`. It runs `/usr/bin/python3 -I` with the standard library only and never executes anything under `/opt/topic-manager`. See README.md → *Host settings* |
| `rsyslog/30-topic-manager.conf` | v1.2.0: the release default (forwarding OFF) for `/etc/rsyslog.d/30-topic-manager.conf`, laid down only where absent; `tm-apply syslog` renders it from Settings |

A bundled host therefore gets the same privilege model as an online one — the polkit rule
and both systemd units travel inside the bundle, because the bundle is the repo.
