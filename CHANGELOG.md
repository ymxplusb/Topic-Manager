# Changelog — Topic Manager v1.0.0 → v1.0.2

## v1.0.2 (2026-05-29)

### Security Fixes

| Severity | Component | Finding | Fix |
|---|---|---|---|
| HIGH | `auth.py` | LDAPS connection used `CERT_NONE` — DC certificate was never validated | Changed to `CERT_REQUIRED`. System CA trust store used by default; configurable via `ldap_ca_cert` in config.yaml. |
| HIGH | `auth.py` | Single-phase user bind — no directory search before credential verification | Two-phase bind: service account searches directory first, then user UPN is re-bound to verify the supplied password. Falls back to direct bind when service credentials are absent or set to `CHANGE_ME`. |
| HIGH | `routes.py` | `force=True` on `request.get_json()` bypassed Content-Type enforcement | Removed on all mutation routes. Requests with wrong Content-Type now return 415. |
| HIGH | `routes.py` | No cross-site request guard on mutation routes | `Sec-Fetch-Site: cross-site` blocked for all non-GET methods. |
| HIGH | `routes.py` | Topic config accepted arbitrary keys and unvalidated integer inputs | `_ALLOWED_TOPIC_CONFIGS` allowlist enforced; `partitions` bounded 1–1,000; `replication_factor` bounded 1–9. |
| MED | `app.py` | Random per-process secret key if config was missing — gunicorn workers diverged, breaking sessions | Application now refuses to start if `server.secret_key` is absent or still the `CHANGE_ME` placeholder. |
| MED | `audit.py` | Hand-built CSV vulnerable to formula injection | Replaced with `csv.writer`; formula-leading chars (`=`, `+`, `-`, `@`) prefixed with `'`. |
| LOW | nginx | CSP lacked `base-uri`, `form-action`, `frame-ancestors` directives | All three added. `X-Frame-Options` removed (superseded by `frame-ancestors 'none'`). |

### Bug Fixes

| Component | Bug | Fix |
|---|---|---|
| nginx | Security headers silently absent on all routes — `add_header Cache-Control` in location blocks cancelled all parent `add_header` directives. Pre-existing since v1.0.0. | Created `/etc/nginx/snippets/tm-security-headers.conf`; included explicitly in all three location blocks. |
| `index.html` | Inline `<script>` block blocked by the now-enforced CSP (`script-src 'self'`). Was invisible before because headers were never served. | App bootstrap moved to `app/main.js`. |
| `kafka_client.py` | Consumer group STABLE/EMPTY stat cards showed 0 — `ConsumerGroupState.STABLE.name` returns `'STABLE'` in confluent-kafka 2.14.0 vs `'Stable'` in 2.6.1. | Normalised with `.title()` at the API layer. |
| `AboutModal.js` | Third-party versions hardcoded to v1.0.0 packages; app version also hardcoded. | Package versions updated; app version now fetched live from `/api/version` on mount. |

### Auth Behaviour Change (v1.0.2)

v1.0.2 introduces a two-phase LDAP bind when `ldap_bind_dn` and `ldap_bind_password` are configured in `config.yaml`:

1. Service account binds to the directory and searches for the user by `sAMAccountName`
2. The user's UPN (`sAMAccountName@domain`) is used to verify the supplied password

If `ldap_bind_password` is `CHANGE_ME` (the default), auth falls back to the v1.0.0 behaviour: direct bind with the user's UPN and password. Login continues to work without any config change.

### Dependency Updates

| Package | From | To |
|---|---|---|
| Flask | 3.1.0 | 3.1.3 |
| gunicorn | 23.0.0 | 26.0.0 |
| Werkzeug | 3.1.3 | 3.1.8 |
| confluent-kafka | 2.6.1 | 2.14.0 |
| Vue.js | 3.5.13 | 3.5.35 |
| ldap3 | 2.9.1 | 2.9.1 (unchanged) |
| PyYAML | 6.0.2 | 6.0.2 (unchanged) |
| cryptography | 44.0.2 | 44.0.2 (unchanged) |

### Config Migration Required

One new field is added to `config.yaml` by the upgrade script automatically:

```yaml
auth:
  ldap_ca_cert: ""    # new — blank = system trust store
```

No other config changes are required. Existing values are preserved.

---

## v1.0.1 (2026-05-07)

- Replaced `window.fetch` with `fetch` across all frontend components (SonarQube MAJOR finding)
- Added explicit HTTP methods to all fetch calls
- Various SonarQube code quality fixes

---

## v1.0.0 (initial release)

- Initial release: topic management, consumer groups, audit log, AD authentication, multi-cluster support
