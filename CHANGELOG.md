# Jarvis Topic Manager — Changelog

All notable changes to this project are documented here.
Copyright (c) 2025-2026 James Rodman. All Rights Reserved.

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
- Offline-capable install script (online/offline auto-detect)
- prepare-offline.sh for air-gapped bundle preparation
- Multi-cluster support (bare-metal + K8s profiles)

### Files Changed
- Initial commit: all files

---
