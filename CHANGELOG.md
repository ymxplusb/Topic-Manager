# Jarvis Topic Manager — Changelog

All notable changes to this project are documented here.
Copyright (c) 2025-2026 James Rodman. All Rights Reserved.

---

## [1.0.5] — 2026-09-02

Security release. Authentication events are now written to the audit database, not only to
the application log.

### Added
- **Five audit actions for authentication**, bringing the total to **15**
  (`tm/routes.py`): `LOGIN` (successful sign-in, recording whether the service bind or the
  direct user bind was used), `LOGIN_FAILED` (rejected credentials, with the reason),
  `LOGIN_REFUSED` (credentials were good but the concurrent-session limit was already
  reached), `LOGOUT` (explicit sign-out) and `SESSION_EXPIRED` (the session was no longer
  valid when a request arrived).

  **Why the app log was not enough.** `log.info('Login success: ...')` and its `log.warning`
  counterpart already existed, but the application log is not exported by
  `/api/audit/export`, is not shown in the Audit tab, and `install/logrotate.d/topic-manager`
  rotates it daily with `rotate 14` — so who signed in three weeks ago was simply gone. NIST
  SP 800-53 **AU-2** treats logon, logoff and logon failure as auditable events; every other
  privileged action in this product was already audited and authentication was the gap.

  `LOGOUT` is recorded **before** `session.clear()`, because the username is read out of the
  session and clearing it first would have written `?` on every row.

- The client address on these rows is the **real** client IP. That is the v1.0.4 ProxyFix
  (one hop) working: a login through nginx now records `10.250.0.2` rather than the
  `127.0.0.1` every row would have carried before it.

### Security
- **`LOGIN_FAILED` records an attacker-controlled value.** The attempted username is
  whatever was posted to `/api/auth/login`, by definition unauthenticated input, and the row
  it lands in is downloadable as CSV by **any** authenticated user through
  `/api/audit/export`. Two controls apply: the username is **bounded to 64 characters**
  before it is stored, and `tm/audit.py` already neutralises spreadsheet formula prefixes
  (`_csv_safe`) and quotes every field (`csv.writer(..., quoting=csv.QUOTE_ALL)`) on export.
  The bound is deliberately belt-and-braces — an unbounded attacker-controlled string in a
  shared export is not something to rest on a single control.

### Known limitations
- **`/api/auth/login` still has no rate limiting.** Nothing in the application or in the
  nginx configuration throttles authentication attempts. A brute-force run now writes **one
  audit row per attempt** into a table that has **no retention or pruning of any kind** —
  there is no `DELETE FROM audit` anywhere in the codebase. This is a real improvement for
  detection and a real growth risk: the audit database is bounded only by how many times an
  unauthenticated client is willing to guess. Rate limiting on the login route, and a
  retention policy for the audit table, are both outstanding.

---

## [1.0.4] — 2026-09-01

Feature release. Cluster profiles become editable from the UI, the service can be restarted
from Settings, the installer and permission model are rebuilt around both, and a banner
defect that was silently destroying operator settings is fixed.

### Added
- **Interactive Cluster Builder** (Settings → Cluster Profiles,
  `app/components/modals/ClusterModal.js`). Add, modify and delete cluster profiles over
  `PLAINTEXT`, `SSL` and `SASL_SSL`, with `ssl_cafile` / `ssl_certfile` / `ssl_keyfile`
  supplied by the operator. Certificates are chosen as **files and posted as content** — the
  API never accepts a path, so it cannot be aimed at an arbitrary file on the server, and
  cert filenames are generated server-side. Every add, modify and delete is written to the
  audit log with before/after values. Changes take effect on the next request; no restart
  is needed.
- **Service restart control** (Settings → Service Control). Restarts `topic-manager.service`
  and reloads `nginx.service`, with a full nginx restart available behind an explicit
  checkbox because it drops every in-flight request for all users. The nginx configuration
  is tested **before** anything is touched, and the UI then polls `/api/health` for 60
  seconds and reports that the service did not come back, rather than reading the API's 202
  as success — a 202 says only that the work was accepted.
- `systemd/topic-manager-nginx-test.service` — a **third unit**: `Type=oneshot`, root, with a
  fixed absolute `ExecStart` of `nginx -t` in a root-owned file. It reads configuration and
  writes nothing. It exists because the requirement *nginx must be tested before any nginx
  action* is otherwise unimplementable. Measured on prod 2026-09-01:
  `sudo -u topic-manager /usr/sbin/nginx -t` exits 1 with
  `[emerg] open() "/run/nginx.pid" failed (13: Permission denied)`, and overriding the pid
  path is refused as a duplicate of `nginx.conf`. A successful `systemctl reload nginx` is
  **not** a substitute: `ExecReload` is `nginx -s reload`, which exits 0 whether or not the
  master accepted the new configuration.
- `install/polkit/50-topic-manager.rules` — authorisation for the restart control via
  **polkit, not sudoers**. `topic-manager.service` sets `NoNewPrivileges=true`, under which
  sudo refuses to run at all, so a sudoers entry is dead code — and the hardening is not
  being removed to revive it. The D-Bus path survives `NoNewPrivileges` because the caller
  never escalates. The rule matches `subject.user == "topic-manager"`, checks
  `action.lookup("unit")` against a unit and verb allowlist, and returns `YES` only;
  everything else falls through as `NOT_HANDLED`.
- `tm/migrate_clusters.py` — one migration module with two callers (`install.sh` and
  `install/upgrade-full.sh`) rather than two copies of it. Line-based removal, so operator
  comments in `config.yaml` survive; it verifies both files afterwards and refuses to report
  success while `config.yaml` still carries the key.
- `config/clusters.yaml.example`, and `tests/t06`–`t09`: new cases over the cluster store,
  the config reload, the banner load gate and the permission boundary.

### Changed
- **The cluster list moved out of `config.yaml`** into
  `/etc/topic-manager/clusters.d/clusters.yaml`. An editable cluster list needs a file the
  application can write, and `config.yaml` is root-owned `0640 root:topic-manager` precisely
  so the application can read `secret_key` and the LDAP bind password and never write them.
  Widening that file — or its directory — was not an option: **a directory the application
  can write is a directory in which it can UNLINK a root-owned secrets file**, because
  directory write *is* unlink. So the store is a new file in a new directory. `clusters.d/`
  is app-writable, since an atomic replace has to create a temp file beside its target;
  `/etc/topic-manager` itself is pinned `root:topic-manager 0750` and stays unwritable by
  the application. `t09` measures that boundary by asking the kernel as the unprivileged
  principal rather than by reading mode bits.
- Configuration staleness was **two caches, not one**. `tm/config.py` returned its first
  parse forever, and `tm/app.py` froze a second copy into `app.config['TM_CONFIG']` that was
  handed to every route. With four gunicorn workers, fixing either one alone leaves a newly
  saved cluster visible on roughly one request in four, which presents as an intermittent
  Kafka fault. The loader now keys its cache on `(inode, size, mtime_ns)`, and the second
  copy is gone: `app.config` holds the path and routes re-read per request.
- `systemd/topic-manager.service` declares `TM_CLUSTERS_DIR` and `TM_CLUSTER_CERT_DIR`, and
  `ReadWritePaths` gains `/etc/topic-manager/clusters.d` — and deliberately **not** its
  parent.
- `install.sh` creates the store and cert directories with `install(1)`, installs
  `config.yaml` with `install(1)` rather than `cp` plus `chmod`, runs the migration, and
  installs the polkit rule and the nginx-test unit.
- `install/upgrade-full.sh`: the three new paths join `BASELINE_PATHS`; Phase 4 backs them
  up and asserts the copy; Phase 9 installs the polkit rule and the test unit; Phase 10
  restores the store before the migration; Phase 11 runs the migration and then **measures**
  the permission boundary as the application user, failing the upgrade if the application
  can write `config.yaml` or its directory.
- `tools/check-config-example.sh` follows the split: a `config.yaml.example` that still
  carries `clusters:` is now itself a gate failure.

### Fixed
- **The Branding & Classification banner silently overwrote the operator's real banner.**
  This was reported as a cosmetic flash of the green `UNCLASSIFIED` default before saved
  values loaded. It was not cosmetic. `SettingsTab` seeded `UNCLASSIFIED` / `green` /
  `white` into the same `data()` fields that `saveBanner()` reads, and `loadSettings()`
  returned early on a non-ok response without telling anyone. An expired session on load
  followed by one toggle therefore **PUT those defaults over the operator's configured
  banner** — and the banner is a global setting, so the loss applied to every user. The
  flash and the data loss are one root cause: defaults seeded into the fields the save path
  reads. Fixed at that root — the fields start empty, the controls are not rendered until
  `/api/settings` has actually answered, a load failure is surfaced with a Retry action, and
  both save paths refuse while settings have not loaded. Two independent barriers.
- Deleting the active cluster no longer leaves the active-cluster reference pointing at
  nothing.
- `/api/clusters` refuses a disabled cluster, and refuses a cluster id rename.

### Known issues
- The polkit rule and `topic-manager-nginx-test.service` have **never been loaded** by
  polkitd or systemd. Nothing in this repo can load them — no agent holds a deploy verb — so
  the end-to-end restart path is unproven on a live host. The unit needs operator sign-off.
- The installer claim that it survives install, upgrade **and** reinstall is not proven end
  to end; there is no QC host for this project. Proven on Linux: the permission layout, the
  boundary itself, the migration's idempotency across three runs, and the backup path. Not
  proven: a real fresh install and a real upgrade.
- **Role separation is unchanged, and now wider.** Every `Kafka-Admins` member can now also
  restart the service and rewrite the cluster list. Audit logging records that; it does not
  control it. This needs a policy decision.
- Documentation prose still describes the pre-split file layout in places (README.md file
  layout, docs/INSTALL.md, TROUBLESHOOTING.md, install/README.md). A documentation pass is
  queued; this release moved version strings and this section only.
- `install.sh` still fetches Vue from the CDN without an integrity check (carried from
  1.0.3).

---

## [1.0.3] — 2026-08-30

Tooling and dependency release. No application code changed; the frontend and the Flask
backend are byte-identical to 1.0.2.

### Security
- **HIGH** `requirements.txt`: `cryptography` `44.0.2 → 50.0.1`. The 44.0.2 pin carried five
  advisories (CVE-2026-69247, CVE-2026-69248, CVE-2026-69249, CVE-2026-26007,
  CVE-2026-34073). Deploying 1.0.2 exactly as released did **not** clear them, because the
  released pin was the vulnerable one.
- **MED** `requirements.txt`: `gunicorn 26.0.0 → 26.2.0`, `PyYAML 6.0.2 → 6.0.3`,
  `confluent-kafka 2.14.0 → 2.15.0`. Every pin is now CVE-clean as of 2026-08-30, verified
  against OSV.dev.
- **MED** The Vue bundle is pinned **by content hash**, not by a version in a URL:
  `install/upgrade-full.sh` refuses to deploy `vue.global.prod.js` unless its SHA-256
  matches, and `prepare-offline.sh` verifies the same hash before it puts the file in an
  offline bundle. (`install.sh` still fetches Vue 3.5.35 from the CDN with no integrity
  check — open defect, tracked for the next release.)
- **MED** The systemd unit **drop-in directory** is now backed up, permission-baselined and
  restored. It is where `TM_SECRET_KEY` and `TM_LDAP_BIND_PASSWORD` live on a host
  configured by environment; backing up the unit but not its drop-ins meant a `--restore`
  handed back a service with no secret key, which the application refuses to start with.
  The upgrade also refuses to proceed if a drop-in file on the host did not reach the backup.
- **LOW** New SCA gate `tools/sca-check.sh` queries OSV.dev for every `==` pin in
  `requirements.txt` and for the Vue pin, and exits non-zero on any advisory — or if OSV
  cannot be reached, rather than reporting a pass it did not earn.

### Added
- `install/upgrade-full.sh` — the single, version-agnostic upgrade path: permission and
  platform audit, upgrade-blocker checks, verified backup, automatic rollback on any
  failure, `--restore`/`--list-backups`, `--audit-only`, `--dry-run`, `--backup-only`,
  `--skip-os`, `--offline`, `--force`.
- A documented **offline upgrade** procedure. It has never existed in this repo: the script
  reads the bundle from `/var/lib/topic-manager/offline-src` and the tarball extracts under a
  different name, so an operator following the old documentation could not succeed. See
  README.md → *Offline (air-gapped) upgrade*.

### Changed
- `requirements.txt` is the **single source of truth** for every Python pin.
  `install/upgrade-full.sh` reads it at run time and refuses to run if a pin has no install
  stage or a stage has no pin; `prepare-offline.sh` downloads exactly those versions and
  fails on the networked machine if any wheel is missing, rather than on the air-gapped host
  that cannot fix it.
- `prepare-offline.sh` no longer keeps its own copy of the Vue version and hash, and no
  longer prepends a licence comment to the downloaded file — that prepend made the bundled
  bytes unhashable, so **every** `--offline` upgrade aborted at "Bundled Vue hash mismatch".
- A successful offline run no longer deletes the bundle the operator transferred.
- Phase 3's blocker checks resolve configuration the way the service sees it — unit
  `Environment=` / `EnvironmentFile=` (drop-ins included), then the shell, then
  `config.yaml`. On a host configured by environment the LDAP bind probe previously read a
  blank password, concluded "no service bind configured", and reported PASS for the one
  check it exists to make.
- Documentation rewritten against the current tooling: README.md (Upgrading, Offline
  upgrade, File Layout, Stack), TROUBLESHOOTING.md (rewritten), docs/INSTALL.md §15,
  install/README.md, SBOM.md and NOTICES.md.

### Removed
- **`upgrade.sh`** (repo root). It only upgraded 1.0.0 → 1.0.2, had no rollback, no
  permission handling, fetched Vue with no integrity check, and its failure message always
  claimed "System is unchanged — your v1.0.0 install is still running" — including after the
  phase that had already deleted the venv, application, frontend, nginx config and systemd
  unit. `install/upgrade-full.sh` replaces it for every version.

### Known issues
- `install.sh` fetches Vue 3.5.35 from the CDN without verifying it, and its
  `rsync -a --delete` makes it unsafe on an existing deployment. Use the upgrade script on
  any host that already has Topic Manager.
- `SBOM.md` and `NOTICES.md` had drifted apart (1.0.2 set vs 1.0.0 set) and neither matched
  `requirements.txt`. Both now match it; the drift itself is what the SCA gate exists to
  catch next time.

---

## [1.0.2] — 2026-05-28

### Security
- **HIGH** `auth.py`: LDAPS certificate validation changed from `CERT_NONE` to `CERT_REQUIRED`; supports configurable CA bundle via `ldap_ca_cert` in config. DC certificate chain is now validated on every LDAP connection.
- **HIGH** `auth.py`: Two-phase LDAP bind — service account searches the directory, user DN is then re-bound to verify credentials. Prevents `memberOf` read failures in tighter AD environments and correctly separates search from authentication.
- **HIGH** `routes.py`: Cross-site fetch requests blocked via `Sec-Fetch-Site: cross-site` check in `require_auth` decorator for all non-GET methods.
- **HIGH** `routes.py`: `force=True` removed from all `request.get_json()` calls; replaced with `_parse_json_body()` helper that enforces `Content-Type: application/json` (415 on mismatch). Login, cluster switch, topic create/update, settings PUT all affected.
- **HIGH** `routes.py`: Topic create and config update now validate against an explicit allowlist of writable Kafka config keys (`_ALLOWED_TOPIC_CONFIGS`). Arbitrary or read-only config keys are silently filtered. Partition count bounded 1–1000; replication factor bounded 1–9; both `int()` conversions wrapped with exception handling (400 on non-integer input).
- **MED** `app.py`: Application refuses to start if `server.secret_key` is absent or contains the `CHANGE_ME` placeholder — gunicorn workers were previously able to diverge on session signing with a per-process random key.
- **MED** `audit.py`: CSV export replaced hand-built quoted strings with `csv.writer` (`QUOTE_ALL`). Formula-injection characters (`=`, `+`, `-`, `@`, tab, CR) at the start of field values are prefixed with `'` to neutralise spreadsheet execution.
- **LOW** `nginx`: Content Security Policy hardened — added `frame-ancestors 'none'` (replaces `X-Frame-Options SAMEORIGIN`), `form-action 'none'`, and `base-uri 'self'`.

### Changed
- `config/config.yaml.example`: added `ldap_ca_cert` field with documentation.
- `requirements.txt`: Flask `3.1.0 → 3.1.3`, Werkzeug `3.1.3 → 3.1.8`.

### Upgrade
- Run `sudo bash install/upgrade-1.0.2.sh` on any host not connected to the repo.
  *(Historical: that script was never committed to this repo. Use
  `sudo bash install/upgrade-full.sh` — see 1.0.3 above.)*
- After upgrade, verify LDAPS: `openssl s_client -connect dc1.int.crypticlight.com:636 -CAfile /etc/ssl/certs/ca-certificates.crt`
- If DC cert not in system store, set `ldap_ca_cert:` in `/etc/topic-manager/config.yaml` to the CA PEM path.

---

## [1.0.1] — 2026-05-07

### Added
- Jarvis favicon (browser tab icon from CORTEX icon set)
- Broker list shown as hover popup on the broker count — displays all broker FQDNs and IDs
- Bulk topic delete uses in-app confirmation modal (replaced browser `confirm()`)
- DoW (Duty of Warning) consent modal on login — blocks login until user accepts; no backdrop-click bypass
- DoW consent enable/disable control in Settings tab
- Jarvis logo on login page (replaces lightning bolt glyph)
- Download Config action in Topics tab — saves live topic configuration as JSON
- Import JSON in Create Topic modal — pre-fills form fields from a previously downloaded config file
- 30-second auto-refresh with live countdown ticker on Topics tab (Retrieve All button)
- 30-second auto-refresh with live countdown ticker on Consumer Groups tab (Refresh button)

### Changed
- Classification banner is now fixed at both the top and bottom of the viewport during scroll
- Classification banner text, colors, and DoW enabled state stored server-side in SQLite (`app_settings` table) — consistent across all browsers and users; no longer uses localStorage for system policy settings
- `/api/settings/public` endpoint (no auth required) serves banner and DoW state on page load — banner renders before login

### Fixed
- Banner only appeared after visiting Settings tab — moved initialization to root app `onMounted()`
- minISR validation in Create Topic: submit is blocked and an inline red warning shown when Min In-Sync Replicas exceeds the Replication Factor

### Code Quality (SonarQube CE 26.4 — Quality Gate: OK)
- All 13 GET-only Flask route decorators now declare `methods=['GET']` explicitly
- Nested ternary in topic sort comparator refactored to sequential `if` statements
- Nested template literal in `TopicsTab.fetch()` extracted to `brokerQs` variable
- `window.fetch` replaced with `fetch` across all four component files
- CSRF hotspot documented in `app.py` (intentional: pure JSON REST API + SameSite=Lax)
- SonarQube project `topic-manager` created on `192.168.202.76:9000` with `Jarvis Standard` quality gate

### Files Changed
- `app/components/TopicsTab.js` — auto-refresh countdown, broker hover popup, fetch refactor
- `app/components/ConsumerGroupsTab.js` — auto-refresh countdown, fetch refactor
- `app/components/AuditTab.js` — fetch refactor
- `app/components/modals/CreateTopicModal.js` — minISR validation, Import JSON
- `app/components/LoginView.js` — Jarvis logo, DoW consent modal
- `app/components/SettingsTab.js` — DoW enable/disable, server-side settings load, fetch refactor
- `index.html` — root banner init from `/api/settings/public`
- `tm/app.py` — CSRF intent comment
- `tm/routes.py` — `/api/settings/public`, PUT `/api/settings`, DoW fields, explicit GET methods
- `tm/models.py` — `app_settings` table schema + helpers
- `nginx/topic-manager.conf` — hostname placeholder comment
- `docs/INSTALL.md` — environment-specific values table

---

## [1.0.0] — 2026-05-06

**Initial Release**

### Added
- Topic list view with live retrieval from Kafka AdminClient
- Create topic modal (name, partitions, RF, retention, cleanup policy, compression, min ISR, max message bytes)
- View / Edit topic configuration — Retrieve pulls live config from Kafka; Update applies changes via alter_configs
- Delete topic with name-match confirmation guard
- Consumer Groups tab — lists groups with state
- Audit Log tab — paginated, exportable as CSV
- Settings tab:
  - Cluster profile management (test connection, set active)
  - Classification banner (text, background color, text color, enable/disable)
  - Three theme modes: Dark, Light, Color Blind (matches CORTEX)
  - STIG compliance status display
  - PPSM CSV export
  - About / Third-Party Licenses modal
- AD/LDAP authentication with required-group enforcement
- Flask backend with gunicorn, nginx reverse proxy
- HTTPS enforced (TLS 1.2/1.3), HTTPOnly cookies, security headers
- SQLite audit log (all create/delete/update_config actions)
- Server-side session table with concurrent session limit (default 5)
- Offline-capable install script (online/offline auto-detect)
- prepare-offline.sh for air-gapped bundle preparation
- Multi-cluster support (bare-metal + K8s profiles)

### Files Changed
- Initial commit: all files

---
