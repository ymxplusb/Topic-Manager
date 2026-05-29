# Software Bill of Materials — Topic Manager v1.0.2

Generated: 2026-05-29

---

## Application

| Field | Value |
|-------|-------|
| Product | Jarvis Topic Manager |
| Version | 1.0.2 |
| License | Proprietary — Copyright (c) 2025-2026 James Rodman. All Rights Reserved. |
| Repository | https://github.com/ymxplusb/Topic-Manager |

---

## Python Runtime

| Component | Version | License |
|-----------|---------|---------|
| Python | 3.10+ (3.12 recommended) | PSF |

---

## Python Dependencies

| Package | Version | License | Purpose |
|---------|---------|---------|---------|
| Flask | 3.1.3 | BSD-3 | Web framework |
| Werkzeug | 3.1.8 | BSD-3 | WSGI utilities (Flask dependency) |
| gunicorn | 26.0.0 | MIT | WSGI application server |
| ldap3 | 2.9.1 | LGPL-3.0 | LDAP/LDAPS client for AD authentication |
| confluent-kafka | 2.14.0 | Apache-2.0 | Kafka AdminClient |
| PyYAML | 6.0.2 | MIT | Config file parsing |
| cryptography | 44.0.2 | Apache-2.0 / BSD | TLS support (ldap3 dependency) |

---

## Frontend Dependencies

| Component | Version | License | Delivery |
|-----------|---------|---------|---------|
| Vue.js | 3.5.35 | MIT | Bundled at `/var/www/topic-manager/lib/vue.global.prod.js` |

---

## System Dependencies (installed via apt)

| Package | Purpose |
|---------|---------|
| python3 / python3-venv | Runtime and virtual environment |
| nginx | TLS termination and reverse proxy |
| build-essential | Native extension compilation (confluent-kafka) |
| libssl-dev | TLS library headers |
| libsasl2-dev | SASL library headers (confluent-kafka) |
| libldap2-dev | LDAP library headers (ldap3) |
| libffi-dev | Foreign function interface (cryptography) |
| ca-certificates | System CA trust store |
| git | Source code retrieval during upgrade |
| curl | CDN downloads and health checks |

---

## Infrastructure

| Component | Version | Role |
|-----------|---------|------|
| Ubuntu Server | 24.04 LTS | Operating system |
| systemd | System-managed | Process supervision |
| SQLite | 3.x (system) | Audit log and server-side session store |
| Active Directory / LDAPS | Customer environment | Authentication |

---

## Security Notes

- All Python packages pinned to exact versions
- No packages with known high/critical CVEs as of 2026-05-29 (SonarQube gate PASSED)
- TLS 1.2 / 1.3 enforced; LDAP connection uses CERT_REQUIRED (certificate validation enforced in v1.0.2)
- Vue.js served from local bundle — no CDN dependency at runtime
- confluent-kafka ships native binaries; source-build fallback requires `librdkafka-dev`
