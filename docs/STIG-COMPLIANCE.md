# STIG compliance - Jarvis Topic Manager

**This document is the source of truth** for how Topic Manager answers every rule
of the STIG decision board: the F5 NGINX STIG V1R1 (32 rules) and the Database SRG V4R5 narrowed
to the SQLite audit database (43 rules), 75 in all - 64 decided Yes, 8 Other and 3 No by the owner.

Settings > Support > STIG compliance serves the same list, live, as a CSV download: each rule
with its status from this document and, where a rule has a live check, what the host and the
application measure now (the root apply helper measures the host, read-only; "Measure host now"
re-runs it). Since v1.3.2 the page itself shows only a one-line summary - when the host was last
measured and the open items - and not the rules. `tools/check-stig-compliance.sh` holds the
page's rule list (tm/compliance.py RULES) to
this document - every id, title, severity, decision, status and live check - the way the PPSM gate
holds the two PPSM copies together; tests/t53 proves it goes red on a one-sided edit.

## Status vocabulary

| Status | Meaning |
|---|---|
| MET | The product does what the rule asks, as described under "How met". |
| PARTLY | Part of the rule is met; the rest is named, with why it is not. |
| INHERITED | The control belongs to the host, its baseline or the site PKI. The product does not change it; where it can, it CHECKS and REPORTS it (James 2026-10-02, DQ1/DQ2). |
| N-A | The rule does not apply to this product; why is stated. |
| NOT-MET | Decided No by the owner (deferred); only rules decided No carry it. |

A rule decided Other, or answered INHERITED or N-A, names its **AO decision point**: the
decision that is the Authorizing Official's, not the product's.

## Live checks

A live check is measured on the host: `host` checks by the root apply helper
(`/usr/libexec/topic-manager/tm-apply compliance`, also run with `--report` by install.sh and
install/upgrade-full.sh), `app` checks by the service. A check reports pass, warn (host state the
product does not own, or an open item such as remote syslog OFF), fail (the product's OWN files
or settings have drifted), info, or unknown (could not be measured, never guessed).

| Check | Where | What it measures |
|---|---|---|
| `web_account_shell` | host | the shell of the account nginx runs as (/etc/passwd) |
| `web_account_groups` | host | that account's membership of sudo, adm, wheel, admin, root (/etc/group) |
| `web_account_password` | host | that the account's password is locked (/etc/shadow) |
| `nginx_config_modes` | host | owner and group/other write under /etc/nginx; product files FAIL |
| `site_log_modes` | host | /var/log/nginx/topic-manager-*.log modes and owners; drift FAILS |
| `nginx_modules` | host | dynamic modules loaded (`nginx -T` load_module) |
| `tls_protocols` | host | every ssl_protocols line in `nginx -T` is TLS 1.2+ |
| `nginx_log_format` | host | log_format tm_dod has every DoD field and the site uses it |
| `server_tokens` | host | server_tokens off in the Topic Manager site |
| `error_pages` | host | the site's own pages for 403, 404, 500, 502, 503, 504 |
| `worker_connections` | host | nginx worker_connections (information) |
| `nginx_http_logs` | host | file-only log directives in nginx.conf (information) |
| `tls_key_mode` | host | server.key 0600 root |
| `session_cap` | app | the concurrent-session limit (0 = unlimited is a warning) |
| `absolute_lifetime` | app | the absolute session lifetime in hours |
| `group_recheck` | app | whether the 15-minute group re-check can run (a service account is configured) |
| `consent_notice` | app | the consent notice is on, and which text |
| `remote_syslog` | app | remote syslog APPLIED on the host (off is an open item) |
| `db_modes` | app | tm.db 0600 and its directory 0700 |
| `sqlite_extensions` | app | load_extension() is refused |
| `tls_issuer` | app | the server certificate's issuer; self-signed is a warning |
| `fips_mode` | app | /proc/sys/crypto/fips_enabled |
| `time_sync` | app | the host clock is synchronised |
| `audit_write_state` | app | no audit write failure is current |

## F5 NGINX STIG V1R1

### NGNX-APP-000010 - NGINX must limit the number of concurrent sessions to an organization-defined number for all accounts and/or account types.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `session_cap`, `worker_connections`
- **How met:** The application caps concurrent sessions per user: Settings > Security > Sessions > Concurrent sessions (session_max_concurrent, default 3, 0 = unlimited), enforced at sign-in under one write lock. The STIG discussion allows the control to be the application's. nginx worker_connections is the OS package setting and is reported, not changed (DQ5: nginx.conf is not edited further).
- **How verified:** Sign in four times as one user with the limit at 3: the fourth is HTTP 429 and LOGIN_REFUSED is recorded. The compliance page measures the saved limit and reports the effective worker_connections from `nginx -T`.
- **Evidence:** tm/settings_schema.py ADMIN_DEFAULTS session_max_concurrent; tm/routes.py login() and _refuse_session_limit(); tests/t42-route-characterisation.sh sign-in-at-the-session-limit-is-unchanged; install/libexec/tm-apply check_nginx_effective (worker_connections).

### NGNX-APP-000040 - NGINX must use TLS 1.2, at a minimum, to protect data confidentiality using remote access.

- **Severity:** CAT I
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `tls_protocols`
- **How met:** The site allows TLSv1.2 and TLSv1.3 only, and the http-level ssl_protocols line in /etc/nginx/nginx.conf is rewritten to the same by install.sh and the upgrade (manage_nginx_ssl_protocols), backed up and tested with nginx -t first.
- **How verified:** The compliance check reads every ssl_protocols line in `nginx -T` and fails on SSLv3, TLSv1 or TLSv1.1. `openssl s_client -tls1_1` is refused.
- **Evidence:** nginx/topic-manager.conf ssl_protocols; install.sh and install/upgrade-full.sh manage_nginx_ssl_protocols; install/libexec/tm-apply check_nginx_effective (tls_protocols).

### NGNX-APP-000140 - The NGINX service account must be configured to not have shell access.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** INHERITED
- **Live checks:** `web_account_shell`
- **How met:** The account nginx runs as (www-data on Ubuntu) has /usr/sbin/nologin on a stock host. The account belongs to the OS baseline: the product never changes it (James 2026-10-02, DQ2) and reports it instead.
- **How verified:** install.sh at the end of an install, install/upgrade-full.sh --audit-only, and the compliance page read the shell from /etc/passwd for the user named by nginx's `user` directive; a login shell is a WARN.
- **Evidence:** install/libexec/tm-apply check_web_account (web_account_shell); install.sh host_stig_report; install/upgrade-full.sh host_stig_report.
- **AO decision point:** Whether a non-nologin shell is acceptable is the host owner's decision; the product only reports it.

### NGNX-APP-000150 - The NGINX service account must be configured to not have admin group access.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** INHERITED
- **Live checks:** `web_account_groups`
- **How met:** The web account is in no administrative group on a stock host (its own group only). The product adds it to none (the gunicorn socket is group www-data, not a group membership) and never changes its groups (DQ2).
- **How verified:** The check reads /etc/group and warns when the account is in sudo, adm, wheel, admin or root.
- **Evidence:** install/libexec/tm-apply check_web_account (web_account_groups, ADMIN_GROUPS); systemd/topic-manager.socket SocketGroup.
- **AO decision point:** Membership of an administrative group is the host owner's decision; the product only reports it.

### NGNX-APP-000180 - NGINX must display the Standard Mandatory DOD Notice and Consent Banner before granting access to the application.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `consent_notice`
- **How met:** The sign-in page shows the Standard Mandatory DoD Notice and Consent Banner, or an operator-supplied replacement text (Settings > General > DoW Consent Banner), BEFORE the sign-in form, and the server refuses POST /api/auth/login without a fresh acceptance (HTTP 403 consent_required). An acceptance is a one-use token the server issues (POST /api/auth/consent, which must name the notice text the page displayed, else 409 notice_changed) and holds by digest in tm.db; the sign-in it enables uses it up in the transaction that creates the session, so a copied cookie cannot be replayed for a second sign-in. The acceptance is recorded as CONSENT_ACCEPTED immediately before the user's LOGIN row. A fresh install turns it ON (install.sh --no-consent-banner turns it off); an upgraded host keeps its setting and the compliance page shows OFF as an open item.
- **How verified:** Sign in without accepting: refused 403 and nothing reaches the directory. Accept, then sign in: CONSENT_ACCEPTED then LOGIN in the audit trail. Replay the consent cookie from that sign-in in another browser: refused 403 consent_required. The compliance page reads dow_enabled.
- **Evidence:** tm/routes.py accept_consent(), login() (_fresh_consent, CONSENT_ACCEPTED); app/components/LoginView.js; tm/settings_schema.py CONSENT_KEY/CONSENT_TEXT_KEY; install.sh --no-consent-banner; tests/t50-consent-v130.sh.

### NGNX-APP-000240 - NGINX must provide audit records for DOD-defined auditable events.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `nginx_log_format`
- **How met:** The product's access records use log_format tm_dod, which carries $server_name, $server_addr, $remote_addr, $remote_user, $time_local, $status, $request, $request_id, $http_user_agent and $http_x_forwarded_for. It is defined in the product's own http-level file /etc/nginx/conf.d/topic-manager-log-format.conf and used by both Topic Manager sites and by the syslog copy (DQ5). $remote_user is always "-": sign-in is the application's, and its audit trail names the user.
- **How verified:** The compliance check reads `nginx -T` and fails when tm_dod is missing, lacks a field, or the site access log does not use it. A real nginx in the test suite writes a line in the format.
- **Evidence:** nginx/tm-log-format.conf; nginx/topic-manager.conf and nginx/topic-manager-http.conf access_log ... tm_dod; install/libexec/tm-apply render_nginx_syslog; tests/t52-nginx-v130.sh.

### NGNX-APP-000250 - NGINX must allow only the information system security manager (ISSM) (or individuals or roles appointed by the ISSM) to select which auditable events are to be audited.

- **Severity:** CAT II
- **Decision:** Other
- **Status:** INHERITED
- **Live checks:** `nginx_config_modes`
- **How met:** Which events nginx logs is set by files under /etc/nginx, which are root-owned and writable by root only; only root (the ISSM's administrators) can change them. The product writes its own files there 0644 root:root and never widens anything.
- **How verified:** The compliance check walks /etc/nginx and reports anything not root-owned or writable by group or other: a product file is a FAIL, anything else a WARN.
- **Evidence:** install/libexec/tm-apply check_nginx_config_modes; write_atomic (0644, chown root); install.sh install_if_absent.
- **AO decision point:** Who is appointed to change the audited events (root on this host) is an ISSM decision.

### NGNX-APP-000370 - NGINX must prevent the execution of unapproved modules.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** INHERITED
- **Live checks:** `nginx_modules`
- **How met:** Topic Manager needs no dynamic nginx module and loads none. A stock Ubuntu 24.04 nginx host has none enabled. Any module the host loads is listed for approval.
- **How verified:** The compliance check lists every load_module in `nginx -T`; any is a WARN naming it.
- **Evidence:** install/libexec/tm-apply check_modules.
- **AO decision point:** Approval of any dynamic module the host loads is the ISSM's.

### NGNX-APP-000400 - NGINX must protect audit information from unauthorized access.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `site_log_modes`
- **How met:** The product's own logs (/var/log/nginx/topic-manager-access.log and -error.log) are CREATED 0640 www-data:adm by install.sh and the upgrade before nginx can create them world-readable; every rotated copy (topic-manager-*.log.*, compressed or not) is set to the same owner and 0640 or tighter, and Ubuntu's /etc/logrotate.d/nginx recreates the live files with `create 0640 www-data adm` (a rotated copy keeps the live file's owner and mode, so live and rotated logs are 0640 www-data:adm alike; root stands in only where that account or group does not exist). The installer and the upgrade touch the logs only when /var/log/nginx is root-owned and not group- or other-writable, and never through a symlink. Drift is enforced back by the next install or upgrade and BLOCKS it if it cannot be (DQ1).
- **How verified:** The compliance check stats both live files and every rotated copy: each must be a regular file, 0640 or tighter, owned www-data:adm — drift is a FAIL. It also reads /etc/logrotate.d/nginx (the OS package's file): a `create` other than `0640 www-data adm` for /var/log/nginx/*.log is a WARN.
- **Evidence:** install.sh and install/upgrade-full.sh ensure_site_logs; install/libexec/tm-apply check_site_logs; tests/t51-host-checks-v130.sh.

### NGNX-APP-000510 - NGINX must be configured to prohibit or restrict using ports, protocols, and/or services.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** nginx listens on 443 and, only while Settings > Security > HTTP redirect is on, on 80 for a redirect to HTTPS (its own site, enabled by one symlink, with ufw 80/tcp opened or closed to match). PPSM.csv lists both.
- **How verified:** nginx -T | grep listen; ss -ltnp; the PPSM export.
- **Evidence:** nginx/topic-manager.conf listen 443; nginx/topic-manager-http.conf; install/libexec/tm-apply plan_nginx; PPSM.csv.

### NGNX-APP-000590 - NGINX must implement replay-resistant authentication mechanisms for network access.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Authentication is the application's: a server-side session (random id, row in tm.db) carried in a Secure, HttpOnly, SameSite=Lax cookie signed with HMAC-SHA-256, over TLS 1.2+ only, and every state-changing request must be marked same-origin. nginx performs no authentication of its own.
- **How verified:** curl -skI the sign-in response: Set-Cookie Secure; HttpOnly; SameSite=Lax. A replayed cookie after sign-out is refused.
- **Evidence:** tm/app.py Sha256SessionInterface and SESSION_COOKIE_*; tm/models.py create_session; tm/routes.py _refuse_cross_site.

### NGNX-APP-000720 - NGINX must be configured to use a Certificate Revocation List (CRL) for certificate path validation and revocation. (Online Certificate Status Protocol [OCSP] is the preferred configuration.)

- **Severity:** CAT II
- **Decision:** No
- **Status:** NOT-MET
- **Live checks:** none
- **How met:** Not built. Certificate revocation (CRL) applies to client-certificate (PIV/CAC) authentication, which this release does not offer; the owner deferred it on 2026-09-26.
- **How verified:** Not applicable to verify until PIV/CAC sign-in exists.
- **Evidence:** Board decision No (2026-09-26); PPSM.csv row OCSP / CRL: not used.

### NGNX-APP-000730 - NGINX, when using PKI-based authentication, must enforce authorized access to the corresponding private key.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `tls_key_mode`
- **How met:** The TLS private key is /etc/topic-manager/tls/server.key, 0600 root:root, written so by install.sh and by the root apply helper for an uploaded key.
- **How verified:** The compliance check stats the key: 0600 or tighter and root-owned, else FAIL.
- **Evidence:** install.sh (server.key chmod 600); install/libexec/tm-apply plan_tls (0600) and check_tls_key.

### NGNX-APP-000850 - NGINX must identify prohibited mobile code.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** PARTLY
- **Live checks:** none
- **How met:** No dynamic module is loaded (see NGNX-APP-000370). The Content-Security-Policy allows script only from the site itself, but still carries 'unsafe-eval': the Vue runtime compiles the component templates in the browser. ACCEPTED RISK until the templates are precompiled, which needs a build step this product does not have; the plan is to remove it in a later release.
- **How verified:** curl -skI https://<host>/ shows the policy; the compliance check lists loaded modules.
- **Evidence:** nginx/tm-security-headers.conf (script-src 'self' 'unsafe-eval'); index.html (Vue global build).
- **AO decision point:** Acceptance of 'unsafe-eval' until it can be removed is the AO's decision.

### NGNX-APP-001030 - NGINX must restrict the ability of individuals to launch denial-of-service (DoS) attacks against other information systems.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Per-address request rates for sign-in and the API (limit_req), a per-address connection limit (limit_conn), bounded client header and body timeouts and a 1 MB body limit. The rates are Settings > Security > Rate limiting.
- **How verified:** nginx -T | grep -E "limit_req|limit_conn|client_(header|body)_timeout"; a burst of sign-ins gets 429 rate_limited.
- **Evidence:** nginx/topic-manager.conf; nginx/tm-limits.conf, nginx/tm-limits-login.conf, nginx/tm-limits-api.conf; install/libexec/tm-apply plan_nginx.

### NGNX-APP-001070 - NGINX must generate error messages that provide information necessary for corrective actions without revealing information that could be exploited by adversaries.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `server_tokens`, `error_pages`
- **How met:** server_tokens off in both sites, and the site serves its own pages for 403, 404, 500, 502, 503 and 504 (a JSON answer for the API), which name neither nginx nor a version. An answer the application gives is passed through as it is, and the application answers Kafka failures with a generic sentence and a reference (SRG-APP-000266).
- **How verified:** The compliance check reads `nginx -T` for server_tokens off and the six error_page codes. A real nginx in the test suite serves a 404 and a 502 that do not mention nginx.
- **Evidence:** nginx/topic-manager.conf error_page, @tm_not_found, @tm_unavailable; install/libexec/tm-apply check_nginx_effective; tests/t52-nginx-v130.sh.

### NGNX-APP-001400 - NGINX must off-load audit records to a central log server.

- **Severity:** CAT I
- **Decision:** Yes
- **Status:** PARTLY
- **Live checks:** `remote_syslog`, `nginx_http_logs`
- **How met:** With Settings > Logging > Remote syslog applied, the Topic Manager sites send their access and error logs to the local syslog socket and rsyslog forwards them (with the audit trail) to the collector over TLS, TCP or UDP. A fresh install or upgrade refuses to finish without --syslog-host or an explicit --no-remote-syslog (DQ10), and the compliance page shows remote syslog OFF as an open item. PARTLY because the http-level access_log/error_log lines in /etc/nginx/nginx.conf (the OS package's, for other sites) are not changed (DQ5); the product's own sites replace both for their traffic.
- **How verified:** The compliance page reads the APPLIED syslog settings and reports the http-level log lines of nginx.conf from `nginx -T`. The collector receives tm_nginx_access lines.
- **Evidence:** install/libexec/tm-apply render_nginx_syslog and render_rsyslog; tm/compliance.py remote_syslog; install.sh and install/upgrade-full.sh --syslog-host/--no-remote-syslog.
- **AO decision point:** Whether the OS package's own nginx logs must also leave the host is the ISSM's decision; changing nginx.conf for it was declined (DQ5).

### NGNX-APP-001590 - NGINX must restrict access to configuration files.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** INHERITED
- **Live checks:** `nginx_config_modes`
- **How met:** /etc/nginx is root-owned and not writable by group or other on a stock host. The product's own files there are 0644 root:root, written atomically by root, and a FAIL when they drift.
- **How verified:** The compliance check walks /etc/nginx (see NGNX-APP-000250).
- **Evidence:** install/libexec/tm-apply check_nginx_config_modes and write_atomic.
- **AO decision point:** Modes of files the product does not own are the host baseline's.

### NGNX-APP-001630 - NGINX must be configured with a deny-all, permit-by-exception policy to allow the execution of authorized software programs.

- **Severity:** CAT II
- **Decision:** Other
- **Status:** N-A
- **Live checks:** none
- **How met:** nginx here executes no software: it serves static files from /var/www/topic-manager and proxies one Unix socket. There is no CGI, FastCGI or script handler to permit or deny.
- **How verified:** nginx -T shows no fastcgi_pass, uwsgi_pass, scgi_pass or perl directive.
- **Evidence:** nginx/topic-manager.conf (root, try_files, proxy_pass http://tm_backend only).
- **AO decision point:** The AO may decide that a client address allow-list is wanted; it was considered and not built (James 2026-10-02, DQ4).

### NGNX-APP-001640 - NGINX must be configured to require SSL sessions to reauthenticate no longer than 15 minutes.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** ssl_session_timeout 15m and ssl_session_tickets off: a TLS session is re-established at least every 15 minutes.
- **How verified:** nginx -T | grep -E "ssl_session_(timeout|tickets)".
- **Evidence:** nginx/topic-manager.conf.

### NGNX-APP-001650 - NGINX must accept Personal Identity Verification (PIV) credentials.

- **Severity:** CAT II
- **Decision:** No
- **Status:** NOT-MET
- **Live checks:** none
- **How met:** Not built. PIV/CAC sign-in was deferred by the owner on 2026-09-26; users sign in with directory credentials over LDAPS.
- **How verified:** Not applicable to verify until PIV/CAC sign-in exists.
- **Evidence:** Board decision No (2026-09-26).

### NGNX-APP-001690 - NGINX must be configured to expire cached authenticators after an organization-defined time period.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** nginx caches no authenticator (no keyval or auth cache). The cached authenticator is the application session: a 15-minute idle timeout that background polling cannot extend, and an absolute lifetime (SRG-APP-000295).
- **How verified:** nginx -T | grep keyval returns nothing; an idle tab is signed out at 15 minutes.
- **Evidence:** tm/config.py DEFAULT_SESSION_TIMEOUT_MINUTES; tm/routes.py require_auth (X-TM-Background); tests/t14-idle-session.sh.

### NGNX-APP-001840 - NGINX must be configured to pass security attributes to proxies.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Both proxied locations set Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto and X-Forwarded-Host; the application trusts exactly one hop.
- **How verified:** nginx -T | grep proxy_set_header; the audit trail records the client address, not 127.0.0.1.
- **Evidence:** nginx/topic-manager.conf; tm/app.py _TRUSTED_PROXY_HOPS; tests/t13-proxy-headers.sh.

### NGNX-APP-001900 - NGINX must only allow using DOD approved certificate authorities for PKI.

- **Severity:** CAT II
- **Decision:** Other
- **Status:** INHERITED
- **Live checks:** `tls_issuer`
- **How met:** Which certificate authority issues the server certificate is the site's PKI. The product accepts an upload of any certificate whose chain verifies, shows its issuer, and WARNS on the TLS pane and the compliance page when the certificate is self-signed - which a fresh install serves until one is uploaded (James 2026-10-02, DQ4).
- **How verified:** Settings > Security > TLS shows the issuer and the self-signed warning; the compliance page reports it.
- **Evidence:** tm/hoststatus.py issuer_status and tls_status; app/components/SettingsTab.js TLS pane; tm/tls_check.py validate.
- **AO decision point:** That the issuing CA is DoD-approved is for the AO to confirm; the product cannot judge it.

### NGNX-APP-001940 - NGINX must protect against denial-of-service (DoS) attacks.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** The same request, connection, timeout and body limits as NGNX-APP-001030, applied before a request reaches the application.
- **How verified:** As NGNX-APP-001030.
- **Evidence:** nginx/topic-manager.conf; nginx/tm-limits.conf, nginx/tm-limits-login.conf, nginx/tm-limits-api.conf.

### NGNX-APP-001960 - NGINX must be configured to use FIPS-approved algorithms to protect the confidentiality and integrity of transmitted information.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** TLS 1.2 with ECDHE and AES-GCM (SHA-256/384) only; TLS 1.3 with the two AES-GCM suites; curves P-384 and P-256. No CBC, ChaCha20, RSA key exchange or SHA-1.
- **How verified:** nginx -T | grep -E "ssl_(ciphers|conf_command|ecdh_curve)"; Settings > Security > TLS lists them.
- **Evidence:** nginx/topic-manager.conf; tests/t18-tls-fips.sh.

### NGNX-APP-002620 - NGINX must be configured to use Online Certificate Status Protocol (OCSP) for certificate path validation and revocation. (OCSP is the preferred configuration.)

- **Severity:** CAT II
- **Decision:** No
- **Status:** NOT-MET
- **Live checks:** none
- **How met:** Not built. OCSP applies to client-certificate (PIV/CAC) authentication, deferred by the owner on 2026-09-26.
- **How verified:** Not applicable to verify until PIV/CAC sign-in exists.
- **Evidence:** Board decision No (2026-09-26); PPSM.csv row OCSP / CRL: not used.

### NGNX-APP-002660 - NGINX must be configured to use a FIPS-validated cryptographic module for confidentiality and integrity.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** INHERITED
- **Live checks:** `fips_mode`
- **How met:** nginx links the host OpenSSL, which runs its FIPS provider on a FIPS-enabled Ubuntu 24.04 host. The product's policy uses FIPS-approved algorithms only and runs in that mode.
- **How verified:** cat /proc/sys/crypto/fips_enabled; openssl list -providers. Settings > Security > TLS and the compliance page show FIPS mode.
- **Evidence:** tm/hoststatus.py fips_mode; nginx/topic-manager.conf (FIPS-approved suites).
- **AO decision point:** Enabling FIPS mode on the host is the host owner's.

### NGNX-APP-003040 - The NGINX service account must be configured to lock changes to the password.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** INHERITED
- **Live checks:** `web_account_password`
- **How met:** The web account's password is locked on a stock Ubuntu host ("*" in /etc/shadow). The product never changes it (DQ2) and reports it.
- **How verified:** The check reads /etc/shadow as root (the helper) and warns unless the hash field starts with "!" or "*".
- **Evidence:** install/libexec/tm-apply check_web_account (web_account_password).
- **AO decision point:** Unlocking the account is the host owner's decision; the product only reports it.

### NGNX-APP-003060 - NGINX must separate API maintenance sessions from other network sessions within the system by logically separated communications paths.

- **Severity:** CAT II
- **Decision:** Other
- **Status:** N-A
- **Live checks:** none
- **How met:** The rule concerns the NGINX Plus API (the api directive), which this nginx does not have and the product does not configure. The host is administered over SSH (PPSM row 22/tcp), not through nginx.
- **How verified:** nginx -T | grep -E "^\s*api\b" returns nothing.
- **Evidence:** nginx/topic-manager.conf; PPSM.csv (SSH).
- **AO decision point:** Separation of the SSH management path is the host owner's and the network's.

### NGNX-APP-003220 - NGINX must generate, manage, and protect from disclosure and misuse the cryptographic keys that protect access tokens.

- **Severity:** CAT II
- **Decision:** Other
- **Status:** MET
- **Live checks:** none
- **How met:** The key that protects the session token is server.secret_key in /etc/topic-manager/config.yaml (0640 root:topic-manager), generated from the OS random source at install, refused when unset or still the placeholder. ROTATION: replace secret_key, restart the service; every user signs in again.
- **How verified:** ls -l /etc/topic-manager/config.yaml; the service refuses to start with the placeholder.
- **Evidence:** tm/app.py create_app (secret_key check); install.sh (config.yaml 0640, generated key).
- **AO decision point:** How often the key is rotated is an organisational decision.

### NGNX-APP-003330 - NGINX must revoke access tokens in accordance with organization-defined identification and authentication policy.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `group_recheck`, `absolute_lifetime`
- **How met:** Sign-out deletes the server-side session; idle and absolute expiry invalidate it; every 15 minutes the user is looked up again with the service account and every session of a user removed from required_group (or gone from the directory: a search that completed and found no such account) is ended and SESSION_REVOKED recorded — a search the directory did not complete (any result code but success) is an outage, reads only, never a removal; an administrator can end a user's sessions or everyone's (Settings > Security > Sessions, SESSIONS_ENDED). While the directory cannot be reached, sessions may read and every write is refused (DQ8). Without a service account (auth.ldap_bind_dn) the re-check cannot run, and the compliance page says so.
- **How verified:** Remove a signed-in user from the group: within 15 minutes their next request is 401 and SESSION_REVOKED is recorded. End sessions from Settings: the user's next request is 401 with the reason.
- **Evidence:** tm/routes.py _recheck_group, end_user_sessions; tm/auth.py check_membership; tm/models.py end_sessions; tests/t49-sessions-v130.sh.

## Database SRG V4R5 (SQLite audit database)

### SRG-APP-000001-DB-000031 - The DBMS must limit the number of concurrent sessions to an organization-defined number per user for all accounts and/or account types.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `session_cap`
- **How met:** The same per-user concurrent session cap as NGNX-APP-000010 (default 3). Every signed-in user is an administrator by design.
- **How verified:** As NGNX-APP-000010.
- **Evidence:** tm/settings_schema.py session_max_concurrent; tm/routes.py login().

### SRG-APP-000089-DB-000064 - The DBMS must provide audit record generation capability for DoD-defined auditable events within all DBMS/database components.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `audit_write_state`
- **How met:** Every change, every sign-in event, every refused write by a signed-in user (REQUEST_REFUSED, or the action word with outcome failure for a Kafka refusal), and every read and export of the audit trail itself (AUDIT_READ, AUDIT_EXPORT) is recorded. An anonymous caller's refused request goes to the service log through a limiter and to the nginx access log, never to tm.db (DQ7); a cross-site write refused with 403 is handled the same way even when the browser sent a valid session cookie, because it is another site acting with that cookie, not the user; failed sign-ins are recorded as LOGIN_FAILED as before.
- **How verified:** Force a Kafka create failure: CREATE with outcome failure. Export the CSV: AUDIT_EXPORT. A refused write from the signed-in browser (an invalid topic name): REQUEST_REFUSED. A same-site POST with a valid session: 403, ANON_REQUEST_REFUSED in the service log, no audit row.
- **Evidence:** tm/routes.py _record_refusals, _kafka_write_failed, get_audit, export_audit; README Compliance (audited actions); tests/t48-audit-v130.sh.

### SRG-APP-000095-DB-000039 - The DBMS must produce audit records containing sufficient information to establish what type of events occurred.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Every audit row carries its action word (NOT NULL).
- **How verified:** Inspect any exported row.
- **Evidence:** tm/models.py audit_log.action; tm/audit.py log_action.

### SRG-APP-000096-DB-000040 - The DBMS must produce audit records containing time stamps to establish when the events occurred.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Every audit row carries a timestamp (NOT NULL), ISO 8601 UTC with Z.
- **How verified:** Inspect any exported row.
- **Evidence:** tm/audit.py TS_FORMAT, utc_ts.

### SRG-APP-000097-DB-000041 - The DBMS must produce audit records containing sufficient information to establish where the events occurred.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Every row names its target (topic, cluster, setting, unit) and, for Kafka actions, the cluster profile.
- **How verified:** Inspect CREATE and DELETE rows.
- **Evidence:** tm/models.py audit_log target, cluster_id.

### SRG-APP-000098-DB-000042 - The DBMS must produce audit records containing sufficient information to establish the sources (origins) of the events.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Every row has a source column: the client address of the request (one trusted proxy hop), or "system" for the prune timer, the apply-result recorder and the installer. Rows written before v1.3.0 were migrated: the sign-in events copy the address they kept in target, the rest say "unrecorded".
- **How verified:** Delete a topic: its row names the client address in source.
- **Evidence:** tm/audit.py request_source, migrate_schema; tm/app.py ProxyFix; tests/t48-audit-v130.sh.

### SRG-APP-000099-DB-000043 - The DBMS must produce audit records containing sufficient information to establish the outcome (success or failure) of the events.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Every row has an outcome column. A row written by v1.3.0 or later is success or failure; a failed step of a detached operation (a service restart) is recorded as failure. Rows written before v1.3.0 recorded no outcome: the migration marks failure only where the old record itself states it (LOGIN_FAILED, LOGIN_REFUSED, SERVICE_RESTART_REFUSED, SERVICE_RESTART_THROTTLED, a SYSTEM_APPLY_RESULT whose state is not ok, a SERVICE_RESTART_STEP that says FAILED), success only for an old SYSTEM_APPLY_RESULT with state=ok, and unknown for every other old row rather than claiming a success the record never made.
- **How verified:** Every exported row has outcome success or failure, or unknown for a row written before v1.3.0; a restart whose nginx reload fails records that SERVICE_RESTART_STEP with outcome failure.
- **Evidence:** tm/audit.py OUTCOMES, OUTCOME_UNRECORDED, migrate_schema; tm/service_control.py _restart_sequence; tests/t48-audit-v130.sh.

### SRG-APP-000100-DB-000201 - The DBMS must produce audit records containing sufficient information to establish the identity of any user/subject or process associated with the event.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Every row names the user (NOT NULL); rows written by no user say "system".
- **How verified:** Inspect rows.
- **Evidence:** tm/models.py audit_log.user; tm/audit_retention.py SYSTEM_USER.

### SRG-APP-000116-DB-000057 - The DBMS must use system clocks to generate time stamps for use in audit records and application data.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `time_sync`
- **How met:** Timestamps come from the operating system clock in UTC; the clock is synchronised by the host time service (Settings > System > Time source).
- **How verified:** Compare a fresh row with date -u; the compliance page reports synchronisation.
- **Evidence:** tm/audit.py utc_ts; tm/hoststatus.py time_status.

### SRG-APP-000118-DB-000059 - The audit information produced by the DBMS must be protected from unauthorized read access.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `db_modes`
- **How met:** tm.db is 0600 and its directory 0700, owned by the service account, created so before SQLite opens it and narrowed at every start; backups are 0700 root.
- **How verified:** The compliance page stats both; sudo -u nobody test -r tm.db fails.
- **Evidence:** tm/models.py _ensure_db_file, _tighten; install.sh enforce_audit_db_modes; tests/t17-audit-db-modes.sh.

### SRG-APP-000119-DB-000060 - The audit information produced by the DBMS must be protected from unauthorized modification.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `db_modes`
- **How met:** The same modes; the application has no route that edits or deletes an audit row.
- **How verified:** As SRG-APP-000118; the API has GET /api/audit and /api/audit/export only.
- **Evidence:** tm/routes.py (audit routes).

### SRG-APP-000120-DB-000061 - The audit information produced by the DBMS must be protected from unauthorized deletion.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `db_modes`
- **How met:** The same modes; rows leave only by retention (days, rows), in the same transaction as the AUDIT_PRUNE row that records it.
- **How verified:** Settings refuses retention below 30 days; a prune that deletes rows writes AUDIT_PRUNE (deleted counts and reasons) in the same transaction; a prune that deletes nothing writes no row (its run is in the journal of topic-manager-audit-prune and in the capacity document's last_prune). `python -m tm.audit_retention --dry-run` says what a prune would delete now and writes nothing.
- **Evidence:** tm/audit_retention.py prune, preview; tests/t33-audit-retention.sh.

### SRG-APP-000121-DB-000202 - The DBMS must protect its audit features from unauthorized access.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** The audit features are reachable only by signed-in members of required_group.
- **How verified:** An unauthenticated GET /api/audit is 401.
- **Evidence:** tm/routes.py require_auth.

### SRG-APP-000122-DB-000203 - The DBMS must protect its audit configuration from unauthorized modification.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Audit configuration (retention) changes only through Settings, recorded by SETTINGS_UPDATE in the same transaction; config.yaml is 0640 root:topic-manager.
- **How verified:** Change retention: a SETTINGS_UPDATE row names old and new values.
- **Evidence:** tm/routes.py update_settings.

### SRG-APP-000123-DB-000204 - The DBMS must protect its audit features from unauthorized removal.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Auditing cannot be switched off; an action whose record cannot be written is refused (HTTP 503 audit_unavailable).
- **How verified:** Make tm.db unwritable: writes are refused 503.
- **Evidence:** tm/audit.py require_writable; tm/routes.py audit_gate; tests/t32-audit-syslog.sh.

### SRG-APP-000133-DB-000198 - The DBMS software installation account must be restricted to authorized users.

- **Severity:** CAT I
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Only root can install or upgrade (both scripts refuse otherwise). SQLite is the operating system library.
- **How verified:** Run install.sh as a non-root user: refused.
- **Evidence:** install.sh and install/upgrade-full.sh root checks.

### SRG-APP-000133-DB-000199 - Database software, including DBMS configuration files, must be stored in dedicated directories, or DASD pools, separate from the host OS and other applications.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** tm.db lives in its own directory, /opt/topic-manager/data.
- **How verified:** ls -ld /opt/topic-manager/data.
- **Evidence:** install.sh DATA_DIR.

### SRG-APP-000133-DB-000200 - Database objects (including but not limited to tables, indexes, storage, stored procedures, functions, triggers, links to software external to the DBMS, etc.) must be owned by database/DBMS principals authorized for ownership.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `db_modes`
- **How met:** The database directory and file are owned by the service account.
- **How verified:** stat -c %U /opt/topic-manager/data/tm.db.
- **Evidence:** install.sh safe_install_dir; tm/models.py.

### SRG-APP-000141-DB-000091 - Unused database components, DBMS software, and database objects must be removed.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Four tables (audit_log, app_settings, sessions, session_meta) and two indexes; no sample database or unused object ships.
- **How verified:** List sqlite_master.
- **Evidence:** tm/models.py init_db.

### SRG-APP-000141-DB-000093 - Access to external executables must be disabled or restricted.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `sqlite_extensions`
- **How met:** Extension loading is disabled explicitly on every connection the application opens; load_extension() is refused.
- **How verified:** The compliance page calls load_extension() on a fresh connection and requires "not authorized".
- **Evidence:** tm/models.py get_db, _refuse_extensions; tests/t17-audit-db-modes.sh.

### SRG-APP-000179-DB-000114 - The DBMS must use NIST FIPS 140-2 or 140-3 validated cryptographic modules for cryptographic operations.

- **Severity:** CAT I
- **Decision:** Other
- **Status:** N-A
- **Live checks:** none
- **How met:** SQLite performs no cryptography. The cryptography in the product is TLS (nginx, the host OpenSSL) and the session cookie signature (HMAC-SHA-256). Note for the AO: the cryptography and confluent-kafka wheels carry their own OpenSSL builds, outside the host's validated module; removing them is not in this release.
- **How verified:** N/A for SQLite.
- **Evidence:** README (FIPS note on the bundled wheels); SBOM.md.
- **AO decision point:** Acceptance of the bundled OpenSSL in the Python wheels is the AO's decision.

### SRG-APP-000220-DB-000149 - The DBMS must invalidate session identifiers upon user logout or other session termination.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Sign-out deletes the server-side session row; an expired or ended session is refused.
- **How verified:** Reuse a cookie after sign-out: 401.
- **Evidence:** tm/routes.py logout; tm/models.py delete_session.

### SRG-APP-000223-DB-000168 - The DBMS must recognize only system-generated session identifiers.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Session ids are generated by the server (uuid4, from the OS random source) and only ids present in tm.db are accepted.
- **How verified:** A forged session id: 401.
- **Evidence:** tm/models.py create_session, session_state.

### SRG-APP-000225-DB-000153 - The DBMS must fail to a secure state if system initialization fails, shutdown fails, or aborts fail.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** The service refuses to start without a valid secret key or an initialisable database; an unwritable audit trail refuses every change.
- **How verified:** Make tm.db unwritable: writes 503.
- **Evidence:** tm/app.py create_app; tm/routes.py audit_gate.

### SRG-APP-000226-DB-000147 - In the event of a system failure, the DBMS must preserve any information necessary to determine cause of failure and any information necessary to return to operations with least disruption to mission processes.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** SQLite's rollback journal keeps the database consistent across a failure; failures go to the journal and syslog at CRIT.
- **How verified:** journalctl -u topic-manager.
- **Evidence:** tm/audit.py write_failed.

### SRG-APP-000231-DB-000154 - The DBMS must protect the confidentiality and integrity of all information at rest.

- **Severity:** CAT I
- **Decision:** Other
- **Status:** INHERITED
- **Live checks:** none
- **How met:** Confidentiality and integrity at rest are file permissions (tm.db 0600, directory 0700, backups 0700 root). Encryption at rest is the platform's (LUKS, or the hypervisor's datastore encryption).
- **How verified:** As SRG-APP-000118; the platform owner shows the encryption.
- **Evidence:** tm/models.py DB_FILE_MODE; install.sh BACKUP_ROOT.
- **AO decision point:** Whether encryption at rest is required for this data, and by which layer, is the AO's decision.

### SRG-APP-000243-DB-000374 - Access to database files must be limited to relevant processes and to authorized, administrative users.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `db_modes`
- **How met:** Only the service account (and root) can open the database and its backups.
- **How verified:** find /opt/topic-manager/data /var/backups/topic-manager -perm /o+r returns nothing.
- **Evidence:** tm/models.py; install.sh.

### SRG-APP-000251-DB-000160 - The DBMS must check the validity of all data inputs except those specifically identified by the organization.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Every input is validated: topic names, bounded integers, an allow-list of topic config keys, every setting by its validator, cluster profiles.
- **How verified:** Create topic "a b": 400.
- **Evidence:** tm/routes.py create_topic; tm/settings_schema.py normalise; tm/clusters.py validate.

### SRG-APP-000251-DB-000391 - The DBMS and associated applications must reserve the use of dynamic code execution for situations that require it.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** No dynamic SQL from input: every value is a bound parameter; the only built SQL is a list of "?" placeholders or a module constant. No eval or exec.
- **How verified:** AST scan of every execute() call.
- **Evidence:** tm/*.py.

### SRG-APP-000266-DB-000162 - The DBMS must provide non-privileged users with error messages that provide information necessary for corrective actions without revealing information that could be exploited by adversaries.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Errors shown to a user say what to do and reveal nothing exploitable: a Kafka failure is one sentence with a reference, the exception goes to the service log under it; sign-in failures have one answer.
- **How verified:** Point a cluster at a dead broker: the browser gets the generic sentence; journalctl shows the reference and the detail.
- **Evidence:** tm/routes.py KAFKA_FAILED_MESSAGE, _kafka_failure, LOGIN_FAILED_MESSAGE; tests/t48-audit-v130.sh.

### SRG-APP-000295-DB-000305 - The DBMS must automatically terminate a user session after organization-defined conditions or trigger events requiring session disconnect.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `absolute_lifetime`
- **How met:** A session ends after 15 idle minutes (background polling does not count as activity) and, however active, at the absolute lifetime set in Settings > Security > Sessions (session_absolute_hours, default 12). SESSION_EXPIRED records which condition ended it.
- **How verified:** Keep a session active past the absolute lifetime: 401 with reason absolute, and SESSION_EXPIRED "absolute session lifetime reached".
- **Evidence:** tm/models.py session_state; tm/routes.py require_auth, _session_ended; tests/t49-sessions-v130.sh.

### SRG-APP-000296-DB-000306 - The DBMS must provide logout functionality to allow the user to manually terminate a session initiated by that user.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** A Sign out button ends the session.
- **How verified:** Press Sign out: LOGOUT is recorded and the cookie no longer works.
- **Evidence:** app/components/TopBar.js; tm/routes.py logout.

### SRG-APP-000357-DB-000316 - The DBMS must allocate audit record storage capacity in accordance with organization-defined audit record storage requirements.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Audit storage is bounded by retention days and a row limit (Settings > Logging > Audit retention); capacity is the larger of rows used and disk used.
- **How verified:** GET /api/audit/capacity.
- **Evidence:** tm/audit_retention.py capacity.

### SRG-APP-000359-DB-000319 - The DBMS must provide a warning to appropriate support staff when allocated audit record storage volume reaches 75% of maximum audit record storage capacity.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** At 75% (configurable) of capacity: a Settings banner, one AUDIT_CAPACITY_WARNING row and a syslog WARNING per crossing.
- **How verified:** Lower the row limit below 75% of the rows held.
- **Evidence:** tm/audit_retention.py _record_crossing; tests/t33-audit-retention.sh.

### SRG-APP-000360-DB-000320 - The DBMS must provide an immediate real-time alert to appropriate support staff of all audit log failures.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `audit_write_state`, `remote_syslog`
- **How met:** An audit write failure is sent to syslog at CRIT with the whole record (forwarded off the host when Remote syslog is applied), the action is refused, and a banner shows in Settings and the Audit tab until a later write succeeds, saying whether the syslog accepted the record or the service log holds the only copy.
- **How verified:** Make tm.db read-only: CRIT line at the collector; the banner appears; it clears after the store recovers.
- **Evidence:** tm/audit.py write_failed, write_failure_state; app/components/SettingsTab.js and AuditTab.js banner; tests/t48-audit-v130.sh.

### SRG-APP-000374-DB-000322 - The DBMS must record time stamps, in audit records and application data, that can be mapped to Coordinated Universal Time (UTC, formerly GMT).

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** Timestamps are stored and exported as ISO 8601 UTC with Z (e.g. 2026-10-02T12:00:00Z). Rows written before v1.3.0 were rewritten in one transaction, recorded as AUDIT_SCHEMA_MIGRATED.
- **How verified:** Export: the timestamp column ends in Z.
- **Evidence:** tm/audit.py TS_FORMAT, migrate_schema; tests/t48-audit-v130.sh.

### SRG-APP-000375-DB-000323 - The DBMS must generate time stamps, for audit records and application data, with a minimum granularity of one second.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** One-second granularity.
- **How verified:** Inspect rows.
- **Evidence:** tm/audit.py TS_FORMAT.

### SRG-APP-000456-DB-000390 - Security-relevant software updates to the DBMS must be installed within 30 days unless the time period is directed by an authoritative source (e.g., IAVM, CTOs, DTMs, and STIGs).

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** INHERITED
- **Live checks:** none
- **How met:** SQLite is the operating system's libsqlite3, patched by the host's update process (unattended-upgrades online, the operator's media offline). The product neither holds it back nor carries its own copy.
- **How verified:** apt list --upgradable | grep libsqlite3.
- **Evidence:** SBOM.md (SQLite row).
- **AO decision point:** The patch window (30 days) is met by the host's update process, which the host owner runs.

### SRG-APP-000515-DB-000318 - The DBMS must off-load audit data to a separate log management facility; this shall be continuous and in near real time for systems with a network connection to the storage facility and weekly or more often for stand-alone systems.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `remote_syslog`
- **How met:** Every committed audit row is sent to the local syslog socket as it is written, as one datagram that always carries ts, source and outcome (an over-long detail is shortened and marked [truncated] in the syslog copy only), and rsyslog forwards it to the collector with a disk-assisted queue once Remote syslog is applied. Install and upgrade refuse to finish without --syslog-host or --no-remote-syslog (DQ10); while it is off the compliance page shows an open item.
- **How verified:** The collector receives topic-manager-audit lines in near real time.
- **Evidence:** tm/audit.py emit; install/libexec/tm-apply render_rsyslog; install.sh and install/upgrade-full.sh (--syslog-host, --no-remote-syslog).

### SRG-APP-000795-DB-000130 - The DBMS must alert organization-defined personnel or roles upon detection of unauthorized access, modification, or deletion of audit information.

- **Severity:** CAT II
- **Decision:** Other
- **Status:** INHERITED
- **Live checks:** none
- **How met:** Detecting access to tm.db from outside the application is the host's file-integrity monitoring (auditd, AIDE). The product ships no rule for it (DQ4). Reference rule for the host owner: -w /opt/topic-manager/data/tm.db -p wa -k tm-audit.
- **How verified:** auditctl -l | grep tm.db on a host that adopted the rule.
- **Evidence:** docs/STIG-COMPLIANCE.md (this rule); install/upgrade-full.sh audit rows (auditd active).
- **AO decision point:** Which personnel are alerted, and by which host tool, is the ISSM's decision.

### SRG-APP-000920-DB-000320 - The DBMS must synchronize system clocks within and between systems or system components.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `time_sync`
- **How met:** The host clock is synchronised by chrony or systemd-timesyncd; Settings > System > Time source sets the servers.
- **How verified:** chronyc tracking; the compliance page reports synchronisation.
- **Evidence:** install/libexec/tm-apply plan_time; tm/hoststatus.py time_status.

### SRG-APP-000925-DB-000330 - The DBMS must compare the internal system clocks on an organization-defined frequency with organization-defined authoritative time source.

- **Severity:** CAT II
- **Decision:** Yes
- **Status:** MET
- **Live checks:** `time_sync`
- **How met:** chrony compares with the configured sources (maxpoll 16); Settings shows offset, stratum and last synchronisation.
- **How verified:** Settings > System > Time source status.
- **Evidence:** tm/hoststatus.py time_status.

### SRG-APP-001035-DB-000323 - The DBMS must be a version supported by the vendor.

- **Severity:** CAT I
- **Decision:** Yes
- **Status:** MET
- **Live checks:** none
- **How met:** SQLite 3.45.1 from Ubuntu 24.04 LTS, supported by the vendor.
- **How verified:** python3 -c "import sqlite3; print(sqlite3.sqlite_version)".
- **Evidence:** SBOM.md.

## Totals

| Status | Rules |
|---|---|
| MET | 56 |
| PARTLY | 2 |
| INHERITED | 11 |
| N-A | 3 |
| NOT-MET | 3 |
| **All** | **75** |
