# Jarvis Topic Manager — Changelog

All notable changes to this project are documented here.
Copyright (c) 2025-2026 James Rodman. All Rights Reserved.

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
