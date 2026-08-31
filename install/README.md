# Offline Bundle Contract

Run `prepare-offline.sh` on an internet-connected machine **before** transferring anything
to an air-gapped host. It is the only supported way to build a bundle, because it is the
only thing that checks the bundle is complete while there is still a network to fix it with.

## What the bundle contains

| Path (relative to the repo) | Contents |
|---|---|
| `install/packages/python/` | One wheel (or sdist) for **every** `==` pin in `requirements.txt`. `prepare-offline.sh` refuses to declare the bundle good if any pin has no matching artefact |
| `install/packages/apt/` | Optional `.deb` files for the Ubuntu 24.04 build dependencies. Only downloaded when the bundling machine is Debian/Ubuntu |
| `lib/vue.global.prod.js` | Vue, at the version **and SHA-256** pinned in `install/upgrade-full.sh`, verified after download and written byte-for-byte — nothing is prepended to it |
| everything else | The repo itself: `tm/`, `app/`, `index.html`, `nginx/`, `systemd/`, `config/`, `requirements.txt` |

`bash prepare-offline.sh --bundle` additionally writes
`topic-manager-offline-<VERSION>.tar.gz` one directory **above** the repo. The tarball
extracts to a directory named after the repo checkout.

## The contract both sides must satisfy

`requirements.txt` is the single source of truth for every Python pin. The bundler downloads
exactly those versions; `install/upgrade-full.sh` reads the same file out of the transferred
tree and installs exactly those versions with `pip --no-index --find-links`. Neither script
keeps a second copy of a version number. If they ever disagree again, the failure appears on
the air-gapped host, which is the one place it cannot be fixed.

The Vue version and hash live in `install/upgrade-full.sh` — the script that verifies the
file on the target — and `prepare-offline.sh` reads them from there.

## Using the bundle

**Fresh install** on an air-gapped host: transfer the repo directory (or the tarball), then
run `install.sh` from it. It detects offline mode and installs from `install/packages/`.

**Upgrading an existing host**: do **not** run `install.sh` — it uses `rsync -a --delete`.
Use the upgrade script, which reads the bundle from one fixed path:

```bash
sudo install -d -m 700 -o root -g root /var/lib/topic-manager/offline-src
sudo tar xzf topic-manager-offline-<version>.tar.gz -C /tmp
sudo mv /tmp/topic-manager/* /var/lib/topic-manager/offline-src/

sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --offline
```

`/var/lib/topic-manager/offline-src` is not configurable, and it is deliberately NOT under `/tmp`.

> **Why not `/tmp`.** Root reads this tree and then rsyncs `tm/` into `/opt`, installs a
> systemd unit and an nginx site, and pip-installs wheels from it. A fixed name under a
> world-writable directory lets any local account that creates it first choose what root
> executes — and `mkdir -p` on an existing directory succeeds while leaving its ownership
> alone, so the documented steps would not notice. The upgrade script now asserts that the
> directory **and every ancestor** are root-owned and not group/other-writable before it
> reads a single byte, and refuses otherwise.

It is not configurable and is not searched for. The bundle is
left in place after a successful run — an air-gapped host cannot fetch another one, and a
re-upgrade after a `--restore` needs it.

Full procedure with the transfer steps: README.md → *Offline (air-gapped) upgrade*.

## Other contents of this directory

| | |
|---|---|
| `upgrade-full.sh` | The upgrade script. See README.md → *Upgrading* |
| `logrotate.d/topic-manager` | Deployed to `/etc/logrotate.d/` by both `install.sh` and the upgrade |
