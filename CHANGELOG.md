# Jarvis Topic Manager — Changelog

All notable changes to this project are documented here.
Copyright (c) 2025-2026 James Rodman. All Rights Reserved.

---

## [1.1.0] — 2026-09-26

**Aurora Glass theme, a Settings section rail, TLS 1.2/1.3 everywhere with a FIPS-approved
cipher list, a private audit database, one PPSM, and no environment-specific defaults — plus a
from-scratch install that reaches the finished state on a clean (STIG'd, FIPS-mode) Ubuntu
24.04 host, online or air-gapped.**

### Read this before upgrading

- **`config.yaml` must name its directory.** `auth.ldap_server`, `auth.ldap_base_dn` and
  `auth.ldap_domain` no longer have built-in defaults (they used to default to one particular
  site's domain controller). The upgrade audit BLOCKS on a config that lacks them and
  `--force` does **not** override it; `install.sh` refuses a reinstall over one. Add the keys
  with your values first. See TROUBLESHOOTING.md → *The directory settings are missing*.
- **Online upgrades need `--repo-url` AND `--repo-commit`.** `install/upgrade-full.sh` no
  longer names a source repository, and it runs what it clones as root, so it clones only the
  exact 40-hex commit you name (`--repo-commit`, or `TM_REPO_COMMIT`) and refuses the tree if
  `HEAD` is anything else. Take the commit id from the release notes or the tag's CI pipeline,
  out of band. Or use `--offline`, after checking the bundle's `.sha256` against a value you
  obtained out of band.
- **The frontend is root-owned.** Install and upgrade stop letting `www-data` own
  `/var/www/topic-manager`: root owns it and nobody else can write it (a group-scoped STIG tree
  keeps its group; no mode is widened).
- **Everyone is signed out once.** The session cookie is now signed with HMAC-SHA-256 instead of
  Flask's SHA-1 default, so cookies from before the upgrade stop validating.
- **A fresh install starts with no Kafka clusters.** Add them in Settings. The example profiles
  are no longer imported as live clusters.

### Added

- **Aurora Glass theme** for Dark, Light and Color Blind: Aurora colours, surfaces, glass
  gradients and the aurora background field, with **no change to content, flow or element
  placement** (14px body, heading and control sizes, control radii and the three-way theme
  menu all kept; panel/card/modal radius 20px). `--text-muted` measured at 6.1 / 5.8 / 7.9 : 1
  on the card surface. Colour-blind mode is the full dark CB palette with solid surfaces, a
  stronger focus ring, and a glyph on every status (✓ ok, ! warning, ✕ error) beside its text.
  The classification banners are exempt and still take their colours from Settings.
- **Settings section rail** (the CORTEX pattern): General (Cluster Profiles, Consent, Banner &
  Classification), System (Service Control), Support (PPSM, About), with search, persisted
  under `tmSettingsGroup`, and derived from the template so it cannot drift. Room left for the
  v1.2.0 Security, Logging and Time source groups. The custom consent/banner selection panel is
  kept as it was.
- **`SETTINGS_UPDATE` audit record** for `PUT /api/settings`, naming the keys that changed and
  never their values. README's Compliance list now has 16 actions.
- **nginx.conf management**: `install.sh` and the upgrade set `ssl_protocols TLSv1.2 TLSv1.3`
  at the http level of `/etc/nginx/nginx.conf` (stock Ubuntu enables TLS 1.0/1.1 there),
  backing the file up, running `nginx -t` and restoring it on failure. The upgrade's restore
  point now includes `nginx.conf`.
- **FIPS-approved site TLS policy**: TLS 1.2 ECDHE + AES-GCM + SHA-256/384 only, TLS 1.3
  AES-GCM suites only, curves P-384/P-256, `ssl_session_timeout 15m`, `ssl_session_tickets
  off`, `server_tokens off`.
- **From-scratch install** (`install.sh`): directory settings from `--ldap-*` flags or prompts
  (no defaults), `--server-name`, `--tls-cert/--tls-key` (verified as a pair) or a self-signed
  ECDSA P-256 placeholder, `umask 0022` for the run, runtime packages only (`polkitd`,
  `rsync`, `sudo` now included; no compiler or `-dev` headers), binary wheels only, no pip
  self-upgrade offline (it used to fail there), offline `.deb`s installed only where missing,
  and it now **starts the service and measures** health, `tm.db` 0600 and `data/` 0700.
- **Offline bundle from the committed tree**: `prepare-offline.sh --bundle` uses `git archive`
  (internal records export-ignored, untracked files left out), downloads the runtime `.deb`s
  with their dependency closure, writes a `.sha256`, and deletes the bundle if
  `tools/check-env-neutral.sh --bundle` finds anything internal or site-specific in it.
- **Gates**: `tools/check-ppsm-consistency.sh` (the two PPSMs agree, with coverage),
  `tools/check-env-neutral.sh` (no site ties in the tree or the bundle),
  `tools/check-version-surfaces.sh` (every version surface, including `tm/VERSION`, agrees
  with `VERSION`). All three run inside `tests/run.sh`, so CI enforces them on every tag.
- Tests t15–t22 (theme, settings audit, audit-DB modes, TLS/FIPS, PPSM, directory config,
  environment neutrality, version surfaces) and mutation controls M60–M87.

### Changed

- **Audit database private**: `tm.db` 0600 and `/opt/topic-manager/data` 0700, owned by the
  service account — created that way by `tm/models.py`, `UMask=0077` on the unit, and enforced
  by `install.sh` and by the upgrade **after** its baseline replay and after `cp -a` restores
  (a v1.0.x baseline records 0644), including `--restore` and the automatic rollback.
- **One PPSM**: `PPSM.csv` and *Settings → Download PPSM* are the same 34 rows — inbound 443,
  80 (redirect only), 22; outbound LDAPS 636, Kafka at operator-defined ports, DNS, NTP, syslog
  514/6514 (planned for v1.2.0), OCSP/CRL stated **not used**, and the online-install-only
  endpoints. LDAP 389 and the site's broker host names removed.
- The cert/key check in the upgrade compares raw public keys (`openssl x509 -pubkey` vs
  `openssl pkey -pubout`), so EC keys verify; it used `openssl rsa -modulus`.
- `tm/migrate_clusters.py`: a host with nothing to migrate gets an **empty** store; `--example`
  is gone.
- Dependencies: confluent-kafka 2.15.0 → **2.15.1**; Vue 3.5.42 → **3.5.43** (SHA-256 verified
  against the npm registry tarball). Every other pin re-measured as latest stable.
- Environment-neutral throughout: config examples use `<placeholders>` and `example.org`;
  docs, tests, SBOM and PPSM name no site hosts, addresses, accounts or paths.
  `docs/INSTALL.md` rewritten as a clean, neutral from-scratch procedure.
- `tm/VERSION` had been left at 1.0.6 by every release since v1.0.6, so `/api/health` could
  not tell 1.0.6–1.0.11 apart. It is now held to `VERSION` by a gate.

### Removed

- `.github/workflows/main.yml` (it mirrored GitHub → GitLab and declared GitHub authoritative;
  GitLab is authoritative).
- `docs/SonarQube-Report-2026-05-07.html` and `-05-29.html`: dated point-in-time artefacts
  carrying internal addresses. They remain in git history.

### Round 2 (assure lane, 2026-09-26)

Adversary and security-review findings, all fixed on this branch before release:

- **Settings change and its audit record are one transaction.** An action whose
  `SETTINGS_UPDATE` row cannot be written does not happen (500, nothing changed). Display and
  consent settings are recorded old -> new; any other key by name only; unknown client keys
  with `%r`. Login usernames and client key names are stripped of control characters before
  they reach a log line or the audit trail. The concurrent-session count and the new session
  are written under `BEGIN IMMEDIATE`.
- **ldaps:// is parsed, not substring-matched**, in the application and both installers
  (`LDAPS://` accepted, `ldap://` and a URL merely containing "ldaps" refused). An
  unauthenticated client sees only "Sign-in is unavailable. Contact the administrator."; the
  missing key is in the server log.
- **nginx.conf**: the rewrite never WIDENS an operator's stricter policy (a TLSv1.3-only line
  stays TLSv1.3-only) and refuses a line that holds another directive instead of deleting it.
- **install.sh** checks an existing `config.yaml` for its directory keys before it changes
  anything at all (it used to run after apt and pip); stops the service before re-moding the
  audit database; holds a kept TLS key to 0600 root:root.
- **Audit database and cluster store are re-moded through file descriptors** (`O_NOFOLLOW`,
  `fchown`/`fchmod`), so the app cannot swap a name for a symlink between check and change.
- **Rollback restores the cluster store.** `restore_from_backup` (used by `--restore` and the
  automatic rollback) never put back `clusters.d/` and `cluster-certs/`, although the backup
  took them. It does now, with their modes and owner.
- **A failed SQLite snapshot blocks the upgrade** instead of marking the restore point ready.
  The Vue backup fallback is held to the pinned SHA-256.
- **Hash-locked Python dependencies.** `requirements.lock` (generated by
  `tools/gen-requirements-lock.py`) pins all 15 packages, transitive ones included, with the
  SHA-256 of every published wheel. `install.sh`, the upgrade and `prepare-offline.sh` install
  from it with `--require-hashes --only-binary :all:`; pip is not self-upgraded; the
  unrestricted `pip download` fallback (which had been silently masking that cryptography 50
  has no manylinux2014 wheel) is gone. `tools/sca-check.sh` now queries the transitive packages
  too (16 clean).
- **The offline bundle is an apt repository.** Measured on a real STIG (USG) + FIPS Ubuntu
  24.04.4 host: handing apt every bundled `.deb` failed on mutually exclusive alternatives
  (`pkgProblemResolver::Resolve generated breaks`). `prepare-offline.sh` now indexes the debs;
  `install.sh` gives apt a private, bundle-only source (at first pinned below every installed
  package — replaced in round 3, below), asks only for the missing top-level packages with
  `--no-download`, and removes the temporary configuration on every exit. The bundle is built
  only from `git archive` (the non-git directory-copy fallback is gone).
- **Gates**: `check-env-neutral.sh` covers all RFC 1918 ranges, internal DNS suffixes,
  secret-store paths and the personal namespace (`.gitlab-ci.yml` is export-ignored and never
  ships); `check-ppsm-consistency.sh` pins the core rows including the protocol column;
  `check-version-surfaces.sh` refuses any version literal in `main.js`; new
  `check-requirements-lock.sh`. Colour-blind glyphs are placement-neutral.

### Round 3 (real-host install, 2026-09-26)

- **The offline apt step upgrades what a dependency needs; it never downgrades and never
  replaces a FIPS package.** Measured on the real STIG (USG) + FIPS Ubuntu 24.04.4 host with
  the round-2 bundle: pinning the bundle below every installed package meant apt could never
  upgrade anything, so `python3.12-venv : Depends: python3.12 (= 3.12.3-1ubuntu0.17) but
  3.12.3-1ubuntu0.13 is to be installed` failed the install — and an air-gapped host that lags
  on patches will hit this almost every time. Now:
  - the bundle is at apt priority **500**, so apt may upgrade an installed package to the
    bundled build when resolution needs it; below 1000 apt never selects an older version, so
    nothing is downgraded, and `--no-remove` means nothing is removed;
  - every installed package whose version contains `fips`, or whose installed version came from
    an Ubuntu Pro FIPS archive (`esm.ubuntu.com/fips`, `fips-updates`), gets a **-1 pin for the
    bundle's copy**, generated at install time from `dpkg-query -W` and `apt-cache policy`; if
    either cannot be read, the install stops;
  - the private apt configuration now also excludes the host's `preferences.d`, so no host pin
    can lift the bundle's priority;
  - apt **simulates** the request first and `install.sh` prints one line listing what is NEWLY
    INSTALLED and what is UPGRADED as `package=version`; a plan that would downgrade, remove or
    replace a FIPS package is refused; on a terminal the operator confirms it, and
    `--non-interactive` proceeds;
  - the failure messages say what is guaranteed: "never downgrades, never replaces FIPS
    packages", and "nothing was installed or changed" only where that is true (resolution
    failures); a failure during dpkg says part of the plan may have been applied.
  `install/upgrade-full.sh` installs no `.deb` offline (it skips OS patching with a warning), so
  it needed no change. t23 now runs the real apt resolver against a fixture package set.

### Round 4 (real-host install, 2026-09-26)

- **The offline bundle carries every lockstep sibling.** Measured on the real STIG + FIPS host
  with the round-3 bundle: the policy worked (29 FIPS packages held) and refused safely, but
  apt's only plan REMOVED `libpython3.12t64` (and with it `vim`, `ubuntu-server`,
  `linux-tools-*`) to upgrade `python3.12` from 0ubuntu0.13 to 0ubuntu0.17. Binaries built from
  one Debian source depend on each other's exact version, and the bundle carried only the
  closure of the requested packages. `prepare-offline.sh` now adds every binary built from the
  same source and source version as any closure package (this architecture and `all`; no
  `-dbg`, `-dbgsym`, `-doc` or debug-section packages; at most 40 per source, a larger source
  is reported and not expanded), prints what it added, and names any sibling it could not
  download. It needs no `deb-src` lines: the source comes from each package's `Source:` field
  and is mapped back through `apt-cache dumpavail`.
- **A forced removal is explained.** When apt could resolve only by removing packages (still
  refused), `install.sh` names the removals that are lockstep siblings missing from the bundle,
  lists what would go with them, and points at rebuilding the bundle on a fully patched build
  host.
- t26 builds real `.deb`s, bundles them with the real `bundle_apt_packages`, and resolves them
  with the real apt against a target that has the old sibling installed: no removal with the
  expansion, a named refusal without it.

### Round 5 (real-host install, 2026-09-26)

- **The firewall step no longer kills the install on a host with ufw active.** Measured on the
  real STIG + FIPS host with the round-4 bundle: packages (357 lockstep siblings added, `gcc-14`
  over the bound and not expanded), venv, backend, frontend, config, cluster store, systemd,
  polkit, the nginx site, the self-signed ECDSA certificate and the nginx.conf TLS edit all
  succeeded, then `ufw --quiet allow 80/tcp` answered `ERROR: Invalid syntax` and the install
  exited 1. ufw has no `--quiet` option; the line had been there since v1.0.6, so every host with
  ufw active (every STIG host) failed at that step. `install.sh` now runs `ufw allow 80/tcp` and
  `ufw allow 443/tcp` with their output captured, checks each exit code, and on a failure warns
  with ufw's reason and the command to run instead of claiming the ports are open. The ufw
  status is read whole rather than piped to `grep -q`. With the flag removed on the host, a
  reinstall ran to `install complete — running`, `/api/health` answered
  `{"status":"ok","version":"1.1.0"}`, tm.db was 0600 and the boundary check passed. No other
  invalid ufw option exists in the scripts or docs. t27 runs the firewall step against a stub
  that rejects unknown options exactly as real ufw does (checked against real ufw with
  `--dry-run`).

### Known limitations

- **FIPS module boundary**: the `cryptography` and `confluent-kafka` wheels bundle their own
  OpenSSL, outside the host's validated module. Both run on a FIPS host. See SBOM.md.
- **Tag signatures are not verified.** The online upgrade pins the commit id; verifying a signed
  tag against an operator keyring (`--verify-tag`) is a follow-up.
- History entries below this one describe past releases as they were; for example the notes
  that `install.sh` fetched an unverified Vue 3.5.35 were true of v1.0.2 and were fixed in
  v1.0.4.

### Not verified

- No FIPS-enabled host was available: behaviour under FIPS mode is argued from how each
  component is built and configured, not measured.
- The round-1 bundle (9a794ff) WAS installed on a real STIG + FIPS host by the owner and failed
  at the offline apt step — the defect fixed above. The round-2 bundle has not yet been
  re-installed there; the new apt path was proven by simulation (`apt-get -s`, /tmp only) on
  a stock host and by the test suite.

---

## [1.0.6] — 2026-09-02

**Idle sessions now end, and the browser signs the user out when they do.**

James: *"When session expires, it should automatically log the user out. this
should be after 15 minutes."*

### The part that was not the number

Nothing in the browser watched the clock. An expired session was discovered only
when some later request happened to return `401`, and until then the application
sat on screen looking signed in.

Worse, the timeout could not fire at all on an open tab. The Topics and Consumer
Groups tabs each refresh every 30 seconds; every refresh was an authenticated
request, and every authenticated request called `touch_session()`, which pushes
`expires_at` a further **full timeout** into the future. An open tab therefore
renewed its own session twice a minute for as long as the browser was open, and
`timeout_minutes` could only ever expire a tab that was already closed.

**Changing 30 to 15 alone would not have altered that by one second.**

### What changed

- **Default idle timeout is now 15 minutes**, defined once in `tm/config.py`.
  `tm/app.py` (cookie lifetime) and `tm/routes.py` (session row) both read it;
  each previously carried its own literal `30`, so they could be given different
  values with nothing to report it.
- **A background refresh is not activity.** The two auto-refresh timers send
  `X-TM-Background: 1`, and `require_auth` does not extend the session for a
  request that carries it. Trusting the client is safe in this direction only:
  the header can shorten a session and never lengthen one, so omitting it gives
  the old behaviour and forging it expires you sooner.
- **The browser arms an idle timer** from the server's value (served on login
  and `whoami`, not hardcoded), resets it on real interaction, warns at 60
  seconds with a **Stay signed in** button, and then signs out. The sign-out
  fires a few seconds before the server's expiry so the `LOGOUT` audit row is
  written under a session that is still valid, instead of being lost to a `401`.
- **The audit trail says which kind of sign-out it was.** A `LOGOUT` row records
  *explicit sign-out* or *automatic sign-out after the idle timeout*. The reason
  comes from the browser, so it is looked up in a closed vocabulary and never
  echoed — this string reaches the CSV export, and an attacker-chosen sentence
  in an audit row is a forged record even when it is correctly escaped.
- **The login screen says why you are looking at it** after an idle sign-out,
  styled as information rather than as an error.

### Verification

`tests/t14-idle-session.sh` — 7 cases. The one that matters is the mutation
control: it removes the header guard from a copy of the tree and requires the
real check to go **red**. It invokes the actual case function against the
mutant rather than a copy of its logic, because a control that re-implements
the rule it is testing can drift from it and go on passing.

### Files

`tm/config.py`, `tm/app.py`, `tm/routes.py`, `app/main.js`,
`app/components/LoginView.js`, `app/components/TopicsTab.js`,
`app/components/ConsumerGroupsTab.js`, `app/styles/main.css`,
`config/config.yaml.example`, `tests/t14-idle-session.sh` (new).

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
  (one hop) working: a login through nginx now records the real client address rather than the
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
- After upgrade, verify LDAPS: `openssl s_client -connect <dc-host>:636 -CAfile /etc/ssl/certs/ca-certificates.crt`
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
- SonarQube project `topic-manager` created on the site SonarQube server with `Jarvis Standard` quality gate

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
