# Topic Manager v1.2.0 — frontend/backend interface contract (binding for both workers)

Owner rulings (James, 2026-09-26) — see WO-0004 `decisions`:
- Audit write failure BLOCKS the action (nothing changes; HTTP 503 `{"error":"audit_unavailable"}`), CRIT to syslog.
- Retention prunes by age/capacity only; every prune writes `AUDIT_PRUNE`.
- Rate-limit defaults: login 10 r/m per IP burst 5; API 300 r/m per IP burst 100; limit_conn 20 per IP.
- Session limit: the Settings value wins; config.yaml seeds it on first start only; mismatch → log warning; fresh default 3.
- Turning the HTTP redirect OFF also removes the ufw 80 rule; the PPSM follows the live state.
- PIV/CAC is out of scope. Everything environment-neutral (example.org placeholders only).

## Settings keys (admin-only; NEVER added to `_PUBLIC_KEYS`)

`_ALL_KEYS = _PUBLIC_KEYS | ADMIN_KEYS` (a NEW set — never alias or mutate `_PUBLIC_KEYS`). Values are strings in `app_settings`.

| key | type / validation | default |
|---|---|---|
| `syslog_enabled` | "true"/"false" | "false" |
| `syslog_host` | hostname or IP, 1–253 chars, `^[A-Za-z0-9.-]+$` or IPv4/IPv6 literal | "" |
| `syslog_port` | int 1–65535 | "6514" |
| `syslog_protocol` | "udp" / "tcp" / "tls" | "tls" |
| `syslog_app_id` | `^[A-Za-z0-9._-]{1,48}$` | "topic-manager" |
| `ntp_servers` | comma-separated, 1–5 entries, each hostname/IP as above | "" (host default untouched) |
| `session_max_concurrent` | int 0–50 (0 = unlimited) | "3" |
| `ratelimit_login_per_min` | int 1–600 | "10" |
| `ratelimit_login_burst` | int 0–100 | "5" |
| `ratelimit_api_per_min` | int 10–6000 | "300" |
| `ratelimit_api_burst` | int 0–1000 | "100" |
| `ratelimit_conn_per_ip` | int 1–500 | "20" |
| `audit_retention_days` | int 30–3650 | "365" |
| `audit_max_rows` | int 10000–50000000 | "5000000" |
| `audit_warn_pct` | int 50–95 | "75" |
| `http_redirect_enabled` | "true"/"false" | "true" |

`PUT /api/settings` (existing) validates each key by the table (400 `{"error":"invalid","field":k,"reason":"..."}`), and
writes rows + a `SETTINGS_UPDATE` audit row in ONE transaction (already true in v1.1.0). It does NOT apply OS changes by itself.

## New authenticated routes (all under require_auth; JSON; CSRF rules as today)

| method + path | request | response |
|---|---|---|
| `POST /api/system/apply/<domain>` domain ∈ {`syslog`,`time`,`nginx`} | `{}` (applies the SAVED settings for that domain) | 202 `{"domain":d,"job":"<id>","state":"queued"}`; audit `SYSTEM_APPLY_REQUESTED` |
| `GET /api/system/apply/<domain>` | — | 200 `{"domain":d,"state":"idle|queued|running|ok|failed|rolled_back","finished_at":iso|null,"message":str,"details":[str],"applied":{<key>:<value>,...}|null,"applied_at":iso|null}` — `applied` = the settings values LAST SUCCESSFULLY applied to the host for this domain (null if never applied; installer defaults count as applied at install). Server `message`/`details` MUST NEVER echo submitted cert/key material. |
| `GET /api/system/time` | — | 200 `{"source":"chrony|timesyncd|none","servers":[str],"synced":bool,"offset_ms":num|null,"stratum":int|null,"last_sync":iso|null}` |
| `GET /api/audit/capacity` | — | 200 `{"rows":int,"max_rows":int,"oldest":iso|null,"retention_days":int,"pct":num,"warn_pct":int,"warning":bool,"last_prune":iso|null}` |
| `GET /api/system/tls` | — | 200 `{"protocols":["TLSv1.2","TLSv1.3"],"ciphers":[str],"fips_mode":bool,"cert":{"subject":str,"issuer":str,"not_after":iso,"key_type":"EC P-256|EC P-384|RSA 2048|...","sans":[str]},"chain_present":bool}` |
| `POST /api/system/tls/cert` | multipart: `cert` (PEM), `key` (PEM, unencrypted), `chain` (PEM, optional) | 202 like apply, domain `tls`; validation errors 400 `{"error":"invalid_cert","reason":str}`; key NEVER logged/stored in DB/audit/tmp |
| `GET /api/system/apply/tls` | — | same shape as other apply status |

`nginx` apply covers rate limits AND the HTTP redirect (+ ufw 80). `syslog` apply covers rsyslog forwarding of app audit
+ nginx logs. `time` apply writes chrony `sources.d` (or timesyncd drop-in) — empty `ntp_servers` = leave host config alone.

Audit actions to add: `SYSTEM_APPLY_REQUESTED`, `SYSTEM_APPLY_RESULT`, `TLS_CERT_REPLACED`, `AUDIT_PRUNE`, `AUDIT_CAPACITY_WARNING`,
`AUDIT_WRITE_FAILED` (syslog-only, since the DB write failed).

## Frontend (SettingsTab.js) — new rail groups/panes

Add groups after General: **Security** (Sessions, Rate limiting, TLS & certificate), **Logging** (Remote syslog, Audit retention),
**System** gains **Time source** (existing Service Control stays), plus **Network** pane "HTTP redirect" inside Security.
Each pane: fields bound to the keys above, a Save button (existing `saveSettings` pattern), and — for syslog/time/nginx/tls — an
"Apply to host" button that POSTs apply then polls GET apply status every 2s up to 90s, showing state + message + details.
Capacity pane shows `/api/audit/capacity` (bar + warning when `warning:true`); TLS pane shows `/api/system/tls` read-only + cert
upload form; Time pane shows `/api/system/time`. A global banner in Settings when audit `warning` is true.
Must keep: `loadSettings`, `saveSettings`, `saveBanner`, `applyBanner` on SettingsTab (tests/lib/settings-probe.js), the rail
derivation from panes, Aurora tokens (no hard-coded colours), no placement change to existing panes, no v-html.

PPSM (PPSM.csv + downloadPpsm()): syslog rows move from PLANNED to active with the configured port/protocol; NTP 123/udp;
port 80 row reflects `http_redirect_enabled`; keep `tools/check-ppsm-consistency.sh` green (update its pins as needed).

## Privileged side (backend worker only)
One root helper `/usr/libexec/topic-manager/tm-apply <domain>` started by fixed one-shot units
`topic-manager-apply-{syslog,time,nginx,tls}.service` via polkit (extend `install/polkit/50-topic-manager.rules` +
`service_control.py ALLOWED_UNITS`). Staging `/opt/topic-manager/data/apply/<domain>.json` (0600, owner topic-manager, no symlinks,
size-capped); results `/run/topic-manager-apply/<domain>.result`. Helper never executes code from /opt/topic-manager or its venv
(it is service-account-owned): system python3 + stdlib only. Validate → render → test (`rsyslogd -N1`, `chronyd -p`/`chronyc`,
`nginx -t`, `openssl` via host binary) → backup → install → reload → verify → rollback on failure. rsyslog TLS via
`rsyslog-openssl` (added to the offline bundle and install packages); CA for syslog TLS stored where the `syslog` user can read it.
Retention: `topic-manager-audit-prune.{service,timer}` (service user, UMask=0077). Installer + offline bundle + upgrade set all
defaults on a fresh STIG/FIPS host; upgrade re-applies saved settings (never reverts operator choices).


## Contract change log
- 2026-09-26 CC-1: apply status gains `applied` + `applied_at` (PPSM must reflect LIVE applied state, not saved settings — Codex review finding 4). Error text must never echo submitted PEM material (finding 2).
