# Jarvis Topic Manager — Changelog

All notable changes to this project are documented here.
Copyright (c) 2025-2026 James Rodman. All Rights Reserved.

---

## [1.3.0] — 2026-10-02

The STIG decision board's remaining rules (WO-0006; James's rulings of 2026-10-02). Every
rule of the board now has its answer in **[docs/STIG-COMPLIANCE.md](docs/STIG-COMPLIANCE.md)**
— the source of truth — and on a live **Settings → Support → STIG compliance** page.

**Before you upgrade:** a host whose saved settings do not already forward the audit trail
must say where it goes (`--syslog-host <collector>`) or that it stays (`--no-remote-syslog`);
the upgrade refuses otherwise and `--force` does not override it. The audit table is migrated
on the first start (see *Changed*); a collector that parses the syslog line, or a script that
reads the CSV, sees two new fields at the END.

### Added

- **STIG compliance page and document.** Every board rule (75) with its decision, status,
  how it is met, how it is verified, evidence and, where the decision is the Authorizing
  Official's, the AO decision point. The page shows what the host and the application measure
  now (**Measure host now** runs the root helper read-only, through a fifth one-shot unit,
  `topic-manager-apply-compliance.service`) and downloads as CSV.
  `tools/check-stig-compliance.sh` holds the page's rule list and the document together.
- **Host STIG checks** at the end of `install.sh`, in `upgrade-full.sh --audit-only`, after an
  upgrade deploys, and on the page: the web server account's shell, groups and password lock,
  files under `/etc/nginx`, loaded nginx modules, the effective TLS protocols, the access-log
  format, `server_tokens`, the error pages, `worker_connections`, the site logs and the TLS
  key. Host state the product does not own is **reported, never changed**; a failure of the
  product's own files stops an install and rolls an upgrade back.
- **Consent notice enforced by the server** (NGNX-APP-000180). Shown before the sign-in form;
  the server refuses a sign-in without a fresh acceptance — a one-use token it issues and holds
  by digest, used up by the sign-in, so a replayed cookie is refused; the acceptance must name
  the notice text the page showed (409 `notice_changed` otherwise) — and records `CONSENT_ACCEPTED` just
  before the user's `LOGIN`. Its text can be replaced (Settings → General → DoW Consent
  Banner; empty = the standard DoD wording). **ON after a fresh install**
  (`--no-consent-banner` to install without it); an upgraded host keeps its setting.
- **Absolute session lifetime** (Settings → Security → Sessions, default 12 hours) that no
  activity extends; `SESSION_EXPIRED` says which limit ended a session.
- **Group membership re-checked every 15 minutes** with the LDAP service account: a user
  removed from `required_group`, or gone, loses every session (`SESSION_REVOKED`). While the
  directory cannot be reached — or answers a search with anything but success (busy, a limit,
  a base DN it does not hold) — sessions may read and **every change is refused** (503); only a
  search that completed and found no such account counts as removal.
- **End sessions**: Settings → Security → Sessions lists active sessions (by a one-way
  handle, never the session id) and ends a user's, or everyone else's (`SESSIONS_ENDED`).
  A browser whose session the server ended returns to the sign-in page on its next request
  and says why ("Your session was ended", or the re-check's reason).
- **`python -m tm.audit_retention --dry-run`**: what a prune would delete now, writing nothing.
  A prune that deletes nothing writes no `AUDIT_PRUNE` row (as before; now documented).
- **The compliance API** documented for operators: `GET /api/compliance`,
  `POST`/`GET /api/system/apply/compliance` (README → *Compliance*).
- **DoD access-log format** `tm_dod` (`/etc/nginx/conf.d/topic-manager-log-format.conf`),
  used by both sites and the syslog copy; `nginx.conf` is edited no further than before.
- **The product's own nginx error pages** for 403/404 and a JSON answer for 500/502/503/504,
  with the security headers, naming no server software.
- **TLS issuer check** (NGNX-APP-001900): a self-signed server certificate is a warning on the
  TLS pane and the compliance page; any other issuer is shown for the operator to confirm.
- **Audit-failure banner** in Settings and the Audit tab while an audit write failure is
  current (SRG-APP-000360); it says whether the host syslog accepted the `AUDIT_WRITE_FAILED`
  copy or the service log holds the only one.
- install.sh `--no-remote-syslog`, `--no-consent-banner`; upgrade-full.sh `--syslog-host`,
  `--syslog-port`, `--syslog-protocol`, `--no-remote-syslog`.

### Changed

- **Audit rows carry `source` and `outcome`** (SRG-APP-000098/099), and **timestamps are ISO
  8601 UTC with `Z`** (SRG-APP-000374). On the first start the table gains the two columns and
  every stored timestamp is rewritten, **in one transaction** with the `AUDIT_SCHEMA_MIGRATED`
  row that records it; sign-in rows take their address from the target they kept it in,
  other older rows say `unrecorded`; an older row's outcome is `failure` where its record says so
  (a failure action word, an apply result's state, a restart step that says FAILED), `success`
  only for an apply result with state ok, and `unknown` otherwise — never a claimed success. The
  syslog line and the CSV **append** `source` and `outcome` after the v1.2 fields; the Audit
  tab shows them. A syslog line longer than one datagram has its `detail` shortened (marked
  ` [truncated]`, never mid-character) so `ts`, `source` and `outcome` always arrive; the
  database row keeps the whole detail. A service-restart step that fails is recorded with
  outcome `failure`.
- **Unsuccessful events are audited** (SRG-APP-000089, DQ7): a signed-in user's refused change
  (`REQUEST_REFUSED`; a refused topic write under its own action word with outcome
  `failure`), and every read and export of the audit trail (`AUDIT_READ`, `AUDIT_EXPORT`),
  written before the data is served. An anonymous caller's refusals are logged by the
  service (rate-limited) and by nginx, never written to the audit database; so is a
  cross-site write refused with 403 even when it carried a valid session cookie (it is another
  site acting with the cookie, and recording it under the user let that site write and prune
  their audit rows).
- **Kafka errors are generic** (SRG-APP-000266): one sentence and a reference; the detail is
  in the service log under that reference. A write with no usable cluster profile is a 409.
- **Install and upgrade require a decision about remote syslog** (DQ10).
- The site's logs are created 0640 `www-data:adm` before nginx can create them
  world-readable; the upgrade narrows existing ones — rotated copies included, owner too —
  and the TLS key. It touches them only in a root-owned `/var/log/nginx` closed to group and
  other writes, and never through a symlink. The compliance check holds live and rotated logs
  to `www-data:adm` 0640 and warns when `/etc/logrotate.d/nginx` would recreate them otherwise.
- The polkit rule authorises nine unit/verb pairs over eight units (adds `start` on the
  read-only compliance unit).
- Every database connection switches SQLite extension loading off explicitly
  (SRG-APP-000141).

### Not built (decided)

- No change to `www-data` (DQ2), no auditd rule, no client allow-list, no further edit of
  `/etc/nginx/nginx.conf` (`worker_connections` and its http-level logs are reported). CRL,
  OCSP and PIV remain deferred. See docs/STIG-COMPLIANCE.md for each rule's AO decision point.

---

## [1.2.1] — 2026-10-02

A patch release: quieter Settings panes, and a successful full upgrade now ends with its
verdict line. No dependency, schema, configuration or host-file change; upgrade as usual.

### Changed

- **Settings → Apply to host no longer repeats the last success.** Every apply pane (Rate
  limiting, HTTP redirect, TLS & certificate, Remote syslog, Time source) used to show the
  last job's state, message, job id and every detail (time daemon, backup path…) in green on
  each visit. Now a pane whose last apply succeeded shows nothing; right after **your** Apply
  succeeds it shows one line, **✓ Applied.**, cleared when you change Settings group or reload.
  A failed, rolled-back, unknown or still-running apply is shown as before — state and
  message, and for a failure its job id and details — and is never cleared by moving around.
  **✓ Saved.** follows the same rule; a failed save keeps its message. The TLS pane no longer
  repeats the certificate summary under the apply result: **Current TLS configuration**, just
  above it, shows the certificate the host is serving.

### Fixed

- **REG-0031: a successful full upgrade printed no `RESULT: exit 0`.** The success path
  disarmed the exit handler that prints the final line (`trap - EXIT`), so an online or
  `--offline` upgrade that finished never printed the line README and INSTALL tell you to
  read with `tail -n 1`; the last line was the `Rollback:` hint. Every exit path now ends with
  `RESULT: exit <N>`; a failure after the upgrade has completed still does not roll it back.
  `--audit-only`, `--backup-only`, `--restore` and failed runs were already correct.

---

## [1.2.0] — 2026-09-29


**Seven STIG host settings, each set in Settings and applied to the host through one root
helper that trusts nothing it is handed — plus an audit trail that goes to syslog, blocks
any action it cannot record, and prunes itself on a schedule.** (F5 NGINX STIG V1R1,
Database SRG V4R5 applied to SQLite.)

### Read this before upgrading

- **An audit write failure now BLOCKS the action** (owner ruling). If the audit database
  cannot be written, topic/cluster changes, restarts, applies and sign-ins answer
  `503 {"error": "audit_unavailable"}` and nothing happens; `AUDIT_WRITE_FAILED` goes to
  syslog at CRIT with the whole record. Sign-out is never blocked.
- **`session.max_concurrent` moved into Settings** (Security > Sessions, default **3**). The
  value in `config.yaml` seeds it once, on the first start of the new release against an
  existing database; after that Settings wins and a different `config.yaml` value is logged
  as a warning at every start. `config/config.yaml.example` now says 3 (it said 5).
- **The `:80` redirect is its own nginx site** (`/etc/nginx/sites-available/topic-manager-http`),
  enabled by a link only while Settings has it on. The upgrade enables it (the previous
  site file had the `:80` block) and never touches it again.
- **gunicorn has no TCP port any more.** It listens only on
  `/run/topic-manager/gunicorn.sock`, created `0660 topic-manager:www-data` by the new
  `topic-manager.socket`; nginx proxies to it. `127.0.0.1:5001` is gone (PPSM, config example).
  The upgrade installs, backs up and rolls back the socket unit; a rollback to 1.1.x removes it
  and puts the TCP unit and site back.
- **Scripts calling the API must send `X-TM-Request: 1`** on POST/PUT/DELETE (or come from a
  browser on this origin). Anything else is refused with 403 — cross-site request forgery,
  the multipart certificate upload included.
- **A failed sign-in shows one message** whatever the reason; the reason is in the
  `LOGIN_FAILED` audit row. Session identity is lower-case, so `Alice` and `alice` share one
  concurrent-session count (existing rows are migrated).
- **New packages:** `rsyslog` and `rsyslog-openssl` (install.sh requires them; the upgrade
  installs no packages and reports `rsyslog-openssl` as a WARN when absent — only syslog over
  TLS needs it). On an air-gapped upgraded host install it from the bundle with
  `install.sh --packages-only`, which changes nothing else. `chrony` is in the offline bundle; it is installed only on a host with no
  time daemon or with `--install-chrony`, because **installing chrony removes
  systemd-timesyncd** (they conflict). That is the one removal the installer ever allows.

### Added

- **Remote syslog** (NGNX-APP-001400, SRG-APP-000515/000360): host, port, UDP/TCP/TLS and an
  application id; forwards the audit trail, the apply helper and nginx's access/error logs
  (RFC 5424, disk-assisted queue for TCP/TLS). TLS through `rsyslog-openssl` (the host's
  OpenSSL), collector name verified, CA = system trust store or `install.sh --syslog-ca`.
  Every audit record is always sent to local syslog (authpriv) regardless of
  `logging.syslog_enabled`.
- **Time source** (SRG-APP-000116/000920/000925): up to five NTP servers, written as chrony
  sources or a systemd-timesyncd drop-in, tested (`chronyd -p`) and verified; read-only
  status (`GET /api/system/time`: source, servers, sync, offset, stratum, last sync).
- **Rate limiting** (NGNX-APP-001030/001940): nginx `limit_req` for sign-in (10/min burst 5)
  and the API (300/min burst 100), `limit_conn` 20 per address, 10 s client timeouts, 1 MB
  body cap. A limited request is a JSON 429 (`"code": "rate_limited"`).
- **Audit retention** (SRG-APP-000120/000357/000359): prune by days and by row limit, daily
  (`topic-manager-audit-prune.timer`, the service account, `UMask=0077`); every prune that
  deletes writes `AUDIT_PRUNE` in the same transaction. Capacity (`GET /api/audit/capacity`)
  is the larger of rows/limit and database/(database + free disk); crossing the warning
  percentage writes one `AUDIT_CAPACITY_WARNING` (and a syslog WARNING) per crossing.
- **TLS certificate upload** (NGNX-APP-001900/001960): `POST /api/system/tls/cert` (cert, key,
  optional chain). EC P-256/P-384 and RSA 2048/3072/4096 only, SHA-2, in date, matching,
  unencrypted, chain verified — by the host `openssl` CLI. Refusals are fixed sentences that
  never quote the upload (contract CC-1). The key is parsed in memory (never `/tmp`), staged
  0600 for the helper and deleted once read; nginx serves leaf + chain; `TLS_CERT_REPLACED`.
  `GET /api/system/tls` shows the protocols, ciphers, FIPS mode and the certificate.
- **HTTP redirect on/off** (NGNX-APP-000510): off removes the `:80` listener and ufw `80/tcp`.
  The redirect goes to the configured `server_name`, never the client's `Host`.

### Security review, round 4 (sec-review, adversary, clean-room; WO-0004)

- Host values rendered by the root helper: IP literals only from `[0-9A-Fa-f:.]` with no IPv6
  scope id (`2001:db8::1%a\nb` reached rsyslog, chrony and timesyncd), strict RFC 1123 names, and
  the helper's own independent character rule at the sinks.
- CSRF: `Sec-Fetch-Site: same-origin` or `X-TM-Request: 1` on every state-changing request.
- `install.sh` stops the service, its socket and the timers before touching a directory, and
  `safe_install_dir` (install and upgrade) works through `O_NOFOLLOW` descriptors.
- A failed audit write says where the record actually went (syslog, or only the service log).
- An unreadable `ufw status` fails the nginx apply closed; the firewall detail says when
  another rule still admits port 80.
- Finished applies are audited with nobody polling: `topic-manager-apply-audit.path` runs
  `python -m tm.apply audit` on each final verdict; also at service start and by the prune.
- `GET /api/audit` `per_page` is 1..500 and `page` ≥ 1 (400 otherwise).
- A certificate that does not name the configured server is installed with a WARNING in the
  apply result (decision: warn, not refuse).
- `tools/sonar-local.sh`: the release's SonarQube scan, run before the tag on a throwaway
  server (a declared gate). `sonar-project.properties` now states the scope CI actually scans.
- Docs: build-host prerequisites, a checkout path before the tag, offline `--audit-only` /
  `--backup-only` by absolute path, out-of-band checksum, a TLS 1.1 probe that proves the
  SERVER refused, FIPS TLS 1.2 needs the extended master secret, the bundle's real contents,
  PPSM host services (postfix 25, chrony 323, rsyslog UDP sender sockets).
- **Apply to host**: `POST/GET /api/system/apply/<syslog|time|nginx>` and `GET
  /api/system/apply/tls`. The root helper `/usr/libexec/topic-manager/tm-apply` (system
  `python3 -I`, stdlib only, never code from `/opt/topic-manager`) re-validates, renders,
  tests, backs up, installs, reloads, verifies and rolls back byte-for-byte; its verdict and
  the values it applied are recorded (`SYSTEM_APPLY_REQUESTED`, `SYSTEM_APPLY_RESULT`; the
  applied values feed the PPSM, contract CC-1). Four fixed one-shot units, `start` only
  through polkit; one apply per domain per 5 s; 409 while one runs.
- `install.sh` flags: `--syslog-host`, `--syslog-port`, `--syslog-protocol`,
  `--syslog-app-id`, `--syslog-ca`, `--ntp-server`, `--no-http-redirect`, `--install-chrony`.

### Clean-room round 5 (WO-0004): rollback and documentation
- **`--restore` to 1.1.x retires what 1.2.0 added.** The restore point now records every
  product host artefact (units and their enablement links, polkit rules,
  `/usr/libexec/topic-manager`) with a byte-exact copy (`manifest/owned-artefacts.list`,
  `system/owned/`). A restore stops, disables and removes every unit the newer release added
  (the audit-prune timer and apply-audit path unit kept firing into modules 1.1.x does not
  have), deletes its helper and rules, puts the older copies back and reloads systemd. A
  retired socket unit's socket file (`/run/topic-manager/gunicorn.sock`) goes with it.
- Docs: INSTALL 5a gives the build-host prerequisites with and without `sudo` (the
  `ubuntu:24.04` container has none); the TLS 1.1 probe is server-side only, needs OpenSSL 3,
  and reads `Cipher is (NONE)` as a refusal; `--restore` is documented by absolute path; ONE
  fresh offline install procedure (root-owned `/var/lib/topic-manager/install-src`) in README,
  INSTALL 5b and `prepare-offline.sh`; README names `topic-manager.socket` and
  `topic-manager-apply-audit.path`; the PPSM Postfix row describes Postfix as installed (all
  interfaces) and names the loopback-only hardening, which the installer does not apply.
- Tools: `tools/sonar-local.sh` holds the project to a copy of the estate gate (Jarvis
  Standard, all seven conditions), removes its volumes and network, fails at once on a dead
  server and refuses a docker disk at 90%; `check-version-surfaces.sh` no longer prints OK
  after a changelog-date FAIL.

### Round 7 (WO-0004): the gatekeeper's round-6 verdict and clean-room round 6
- **A rollback touches only what the product recorded installing.** Round 6 judged a file the
  product's when its text mentioned `topic-manager`: a rollback stopped, disabled and deleted
  another tool's `site-backup.service` (it backs up `/opt/topic-manager`) and silently deleted an
  operator's `nginx.service.d/50-limits.conf` that named the product in a comment. `install.sh`
  and the upgrade now write `/var/lib/topic-manager/installed-files.manifest` (root `0600`, one
  path per line with its sha256) from the same lists and source tree they install from; a
  restore retires only what the host's manifest names and the restore point's does not, puts
  back only what the restore point's names, and leaves everything else — listing what changed.
  A retired file that was edited since it was installed is kept in
  `/var/backups/topic-manager/set-aside-<TIMESTAMP>/`. A v1.1.x host (no manifest) is judged by
  v1.1.x's shipped list, which the tests re-derive from the v1.1.0 and v1.1.1 tags; a restore
  point of any other release with no manifest retires nothing and ends `RESTORE INCOMPLETE`.
  Drop-in directories of retired units are no longer removed (no manifest records them).
- A retired timer's stamp (`/var/lib/systemd/timers/stamp-<timer>`) goes with it.
- **A detached run reports its exit code.** Every run of `upgrade-full.sh` ends with
  `RESULT: exit <N>` in its output and its log; README and INSTALL say to read it with
  `tail -n 1 ~/tm-upgrade.out`.

### Round 6 (WO-0004): clean-room round 5 and the gatekeeper's round-5 notes
- **`install.sh` and the upgrade wait for the package lock.** On the air-gapped QC host
  unattended-upgrades held dpkg's lock for ~4.5 minutes and `install.sh --packages-only`
  failed at once, pointing at `dpkg --audit`. Every apt/dpkg step now waits (up to 600 s,
  `TM_DPKG_LOCK_WAIT_S`) and names the process holding the lock; a lock still held stops the
  run before anything changes, and the error text and TROUBLESHOOTING say so.
- **`--restore` is judged by the version and by what it could not do.** It exits 0 only
  when the service answers healthy as the version the restore point holds; the wrong
  version, a unit `systemctl` could not stop and disable, or a recorded file with no saved
  copy is listed under `RESTORE INCOMPLETE` and the exit is 1. The retired count now counts
  every unit retired (it said 8 after listing 9), and a retired unit's runtime directory
  (`/run/topic-manager-apply`) and drop-in directory go with it.
- **The rollback inventory is by location.** The restore point records every unit file,
  drop-in directory and link in `/etc/systemd/system` and every polkit rule, whatever its
  name; a restore changes only the product's (what the file names, not only its name), and
  lists anything else that changed as not the product's. (Replaced in round 7: ownership by
  what a file names was wrong; it is now the install manifest.)
- `tools/sonar-local.sh` fails a head whose scan indexed fewer than 80% of the base's files
  (an exclusion of the whole tree printed PASS on 0 files), and its PASS line names the
  conditions actually judged.
- Docs: run the upgrade detached (`setsid nohup … &` or `tmux`) with a log file; the polkit
  rule is eight unit/verb pairs over seven units everywhere; README's ufw line matches
  INSTALL (80/tcp only while the HTTP redirect is on); the PPSM systemd-resolved row names
  127.0.0.54:53 as well as 127.0.0.53:53.

### Changed

- `_ALL_KEYS` is a NEW set (`_PUBLIC_KEYS | ADMIN_KEYS`, `_PUBLIC_KEYS` frozen). It used to
  BE `_PUBLIC_KEYS`, so adding an admin key would have published it on the unauthenticated
  `/api/settings/public`.
- `PUT /api/settings` validates every admin key and refuses the whole request on one bad
  value (`400 {"error": "invalid", "field", "reason"}`); host settings show old → new values
  in `SETTINGS_UPDATE`.
- The sign-in page reads a 429 it cannot parse as JSON as a rate limit, not "Network error".
- The upgrade keeps every Settings-managed file (backed up in Phase 4, restored on a
  rollback, removed when rolling back to a release before 1.2.0) and re-applies what `tm.db`
  holds after the new service is verified.

### Fixed during the build (found by the new tests)

- The row-limit prune kept `max_rows` rows and then added `AUDIT_PRUNE` — one over.
- After a reboot (the verdict file is on `/run`), a finished apply read as "queued" and then
  "failed: no result"; the verdict is now kept in `tm.db` with the claim that audits it.

### Frontend

- Settings gains **Security** (Sessions, Rate limiting, TLS & certificate, HTTP redirect),
  **Logging** (Remote syslog, Audit retention) and **System › Time source**, each with Save and,
  where the host changes, **Apply to host** with live status; the audit-capacity banner; the
  PPSM export built from the values last APPLIED, not merely saved (contract CC-1); every
  backend error code handled explicitly (t30, t40).

### Scripts and gates (REG-0004 … REG-0013)

- **The product scripts are held to the pipefail rule too.** `dpkg-query | grep -q` in
  install.sh could read an installed package as missing, and `lsattr | … | grep -q` in the
  upgrade audit could MISS an immutable file; every early-exit consumer at a pipe in install.sh,
  install/upgrade-full.sh, prepare-offline.sh and install/libexec/ now captures, then tests.
  `tools/check-pipefail-consumers.sh` checks them by default, with a real shell tokenizer.
- The gates were hardened against an independent falsification: SCA reads the lock the way pip
  does and queries every package at its locked version; lock completeness is a self-consistent
  closure (an older compatible lock passes) and CI requires it online; exact `==` pins only;
  env-neutral sees through latin-1 bytes and UTF-16 and covers fc00::/7; version tokens in
  comments no longer count; duplicate SBOM rows and empty-container config values fail; the
  About dialog's infrastructure rows are held to SBOM.md; the test runner rejects unrecognised
  result records. Each is proven by its reproduction in t41.
- REG-0014 … REG-0019: a `?v=` cache token counts only as a `src=`/`href=` attribute value
  (not in HTML text, a plain JS string, or an inline script's comment); `tests/run.sh` holds
  every file to the number of cases it declares, so a file that stops early fails
  (`case-count-shortfall`) instead of passing with fewer; the settings and theme probes'
  exit code is asserted before their output is read; the frontend syntax gate
  (`tools/check-frontend-syntax.sh`) takes its list from `index.html` and fails on a file it
  loads going missing; the upgrade's "Baseline recorded (N paths)" counts records (it always
  said 0); `AUDIT_SYSLOG_FAILED` and the syslog send failures are in TROUBLESHOOTING.md.

### Carried from 1.1.1, and held to its code-quality gate

- 1.1.1's fixes are merged: the sign-in and cluster-migration refactors, `Object.hasOwn`, the
  theme list as a `Set`, and its characterisation tests (t07, t08, t20), which pass unchanged
  against this release.
- The new code in this release was measured the way the release gate measures it (cognitive
  complexity limit 15, duplicated literals, nested ternaries, ignored exceptions, `Set`
  membership, `Object.hasOwn`) before tagging. Refactored with behaviour held by tests: the
  apply status, the settings validator, the certificate validator, the sign-in session limit,
  topic creation's config assembly, the lock-closure check, and the Settings tab's
  host-error text, input checks and apply monitor. A reason that names an
  `Object.prototype` member is not a known certificate refusal (t30); sign-in at the
  session limit and topic config assembly are held to transcripts recorded before the
  refactor (t42).

---

## [1.1.1] — 2026-09-28

**v1.1.0 with the six code-quality findings that stopped its release fixed. Nothing else
changed.**

The v1.1.0 tag was pushed, but its release pipeline failed at the SonarQube quality gate: the
scan found six new code smells in the release's new code (no bugs, no vulnerabilities, every
security hotspot reviewed). The gate fails on any new violation, so the pipeline stopped there
and **nothing was published** — no v1.1.0 package, checksum or release exists. 1.1.1 is 1.1.0
plus the fixes below. There is no v1.1.0 to install or upgrade from; everything in the 1.1.0
section still applies, including *Read this before upgrading*.

### Fixed (the six new-code findings)

- `tm/auth.py` — `validate_credentials()` was over the cognitive-complexity limit (17 > 15), and
  `missing_ldap_keys()` had two branches with the same body. The sign-in path is split into
  small helpers (the service-bind decision, the second bind as the user, the group list, the
  user record) and the two branches are one check. The bind sequence is unchanged.
- `tm/migrate_clusters.py` — `migrate()` was over the limit (20 > 15). Reading `config.yaml`,
  choosing what to do with the cluster store and verifying the result are now separate helpers.
  Every message it prints is unchanged, so TROUBLESHOOTING.md still matches.
- `tools/gen-requirements-lock.py` — a `# noqa` comment carried trailing prose that made it
  malformed; the explanation moved to its own line.
- `app/components/SettingsTab.js` — the entity lookup uses `Object.hasOwn()`.
- `app/components/TopBar.js` — the list of themes is a `Set`, checked with `.has()`.

### Browser support

`Object.hasOwn()` is ES2022: Chrome and Edge 93, Firefox 92, Safari 15.4 and later (all released
by March 2022). The frontend already used ES2020 syntax (`?.`, `??`), so this raises the oldest
browser that can load the Settings tab from those releases to these.

### Tests

- t20 now drives the whole sign-in sequence (service bind, second bind as the user, unbinds,
  group check, returned user record, the administrator's log line) against a scripted
  directory, and t07 drives `migrate()` through 21 starting states. Both are held to
  transcripts recorded on the v1.1.0 code before the refactor, so the refactor is proven not to
  change behaviour.
- t08 checks entity decoding directly, including names that exist only on `Object.prototype`.

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

### Round 6 (render proof, 2026-09-26)

- **Colour-blind badges no longer move by a fraction of a pixel.** The render proof on the real
  host matched v1.0.6 to 0.0px in Dark and Light, but in Color Blind mode `bdg-ok` sat 0.6px and
  `bdg-warn` 1.3px higher and a badge-only row lost 1.3px: the glyph was drawn INSIDE the 5x5
  marker (`inline-flex`, `line-height:0`), which gave the badge a text baseline. The marker box
  is now left exactly as in every other mode (only its fill is dropped) and the glyph is an
  absolutely positioned `::after` over it, as the stat-card, lag, STIG and login-error glyphs
  already were. Measured with a same-page harness against v1.0.6's `main.css` in dark, light
  and colour-blind at 1920 and 1366 (33 elements, including every glyph-bearing class): 0.0px
  everywhere, and colour-blind equal to dark; every glyph still renders (computed `content`
  checked). The same harness on the previous CSS reproduced the 0.66 / 1.31px deltas.

### Round 9 (gatekeeper, 2026-09-27)

- **`tools/check-requirements-lock.sh` verifies the hashes, and offline is not a pass.** It
  checked structure and the resolved `name==version` set only: dropping a hash, or changing one
  hex digit of one, stayed green, and offline it printed "NOT verified" while exiting 0. With
  PyPI reachable it now fetches each locked release's JSON: every hash in the lock must be one
  PyPI published for that exact release, and all published target wheel hashes must be present
  (at least one per release; CPython 3.12 x86_64, manylinux glibc <= 2.39 or py3-none-any).
  Dropping one target hash fails even if another remains. Non-target hashes are optional;
  adding a non-target wheel on PyPI cannot turn it red. Adding a target wheel deliberately
  requires regeneration. `gen-requirements-lock.py --check` uses the same gate. Offline it
  exits 3 ("could not verify") unless `TM_LOCK_OFFLINE_OK=1` explicitly
  accepts a structure-only result. t25 covers the online branch against a fake PyPI.

### Round 10 (gatekeeper, 2026-09-28)

- **A trailing comment can no longer hide a lock entry from the hash check.** The structure
  check stripped `# comments`; the hash check re-parsed the lock with a pattern that required
  the line to end in hashes and silently skipped any other line. So
  `blinker==1.9.0 --hash=sha256:<anything>  # pinned` passed as "PASS — 14 releases" on a
  15-entry lock, while pip still honours that hash. The lock is now parsed once, by pip's rules
  (continuations, comments), and the PyPI fetch and the hash check both use that entry list; the
  hash check must judge every entry or the gate fails. t25 proves a commented bad hash goes red
  (a one-line entry, and the last `--hash` line of a multi-hash entry) and a commented good one
  stays green.
- **Where the real lock meets live PyPI (corrected claim).** In v1.1.0, CI runs
  `tests/run.sh --strict` only: t25 checks the real lock's structure offline and exercises the
  online logic against a fake PyPI built from the lock's own hashes. CI does **not** verify the
  real lock against live PyPI. That happens when `prepare-offline.sh` runs (it runs the gate
  and stops on any failure) and when the gate is run by hand (2026-09-28: PASS, 15 releases).
  v1.2.0 adds a `--require-online` CI step.

### Round 11 (gatekeeper, 2026-09-28)

- **One reader of `requirements.lock`, and it is pip's.** Round 10 made the lock gate read the
  lock as pip does, but the completeness check (`gen-requirements-lock.py --check-set`) and
  SCA (`tools/sca-check.sh`) still matched raw column-0 lines. Two locks exploited the gap:
  a `# regenerated \` comment on blinker's hash line made pip and the gate lose `cffi` while
  `--check-set` still counted it (gate "PASS — 14 releases", pip then refuses to install); and
  an entry hidden behind such a comment with an indented `pyasn1==0.4.8` below it passed the
  gate with 15 releases while SCA reported "pyasn1 0.6.4 CLEAN" and pip installed 0.4.8 (four
  CVEs). All three now use `tools/lib/lockparse.py`, which follows pip's own rules
  (continuations, comments, splitting on spaces only), and a t25 case compares it with pip's own
  parser. SCA queries every lock entry at the version pip installs and its count must match
  the parser's. The gate also refuses a lock laid out so that a reader looking only at
  column 0 would see different entries from pip (a hidden entry, an indented entry, a
  line break that pip honours and grep does not); the generator never writes one.
- A TAB between a version and `--hash` is refused, as pip refuses it.
- The lock gate reads the completeness verdict and its count instead of relying on exit 0.
  The resolver now times out after 600 s and reports "could not verify".

### Round 12 (gatekeeper, 2026-09-28)

- **`requirements.lock` must be plain ASCII.** pip does not read the lock as UTF-8: it
  honours a byte-order mark and a `# -*- coding: ... -*-` line in the first two lines. A
  lock declaring `coding: latin-1` (or `utf-7`) could make pip read an entry that every gate
  saw inside a comment: all gates passed and SCA reported pyasn1 0.6.4 clean while pip
  installed 0.4.8. The shared parser now refuses any byte of 0x80 or above, a byte-order
  mark, a coding line, a line break other than LF (CRLF is still accepted) and any control
  character other than TAB. So the lock gate, the completeness check, SCA and the SBOM
  check all refuse such a lock. The generator writes only ASCII (its header no longer has
  an em dash) and will not write a lock these rules refuse.
- **The SBOM check reads the lock through the same parser.** It had its own column-0
  pattern, which missed an entry behind a byte-order mark and read a version split across a
  continuation line (`pyasn1==0.6\` then `.4`) as `0.6`. In both cases a wrong SBOM row
  passed. The lock gate also refuses an entry whose `name==version` is split across lines.

### Known limitations

- **FIPS module boundary**: the `cryptography` and `confluent-kafka` wheels bundle their own
  OpenSSL, outside the host's validated module. Both run on a FIPS host. See SBOM.md.
- **Risk acceptance (system owner, 2026-09-26): Kafka client TLS runs outside the host's FIPS
  140-3 validated module** — the `confluent-kafka` 2.15.1 wheel bundles librdkafka and its own
  OpenSSL (SC-13; SRG-APP-000014 / SRG-APP-000514; CWE-327). Compensating: SSL/SASL_SSL Kafka
  profiles; nginx, LDAPS and Python `ssl` use the validated module. Removal path: the
  distribution's `python3-confluent-kafka` or a site-built wheel against the system libssl.
  Recorded in SBOM.md, TROUBLESHOOTING.md and docs/INSTALL.md §10.
- **Tag signatures are not verified.** The online upgrade pins the commit id; verifying a signed
  tag against an operator keyring (`--verify-tag`) is a follow-up.
- History entries below this one describe past releases as they were; for example the notes
  that `install.sh` fetched an unverified Vue 3.5.35 were true of v1.0.2 and were fixed in
  v1.0.4.

### Verified

- **DAST:** ZAP 2.17.0 active scan of the release candidate on a STIG (USG stig-v1r1) + FIPS
  Ubuntu 24.04 host: 0 High, 0 Low, 2 distinct Medium (CSP script-src 'unsafe-eval' and
  style-src 'unsafe-inline', both deferred to the CSP/precompiled-templates release).
- **Air-gapped install:** the install from the offline bundle completed on that host; the host
  STIG audit was unchanged after install (209 pass / 8 site-specific fail).
- **FIPS paths:** on that host (`fips_enabled=1`) nginx, LDAPS and Python `ssl` use the
  validated module, "Ubuntu 24.04 OpenSSL Cryptographic Module 3.0.13+Fips2".

### Not verified

- The Kafka client's TLS under FIPS mode is not inside the validated module by construction
  (see the risk acceptance above); it was not measured separately.

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
