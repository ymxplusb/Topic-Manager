# Jarvis Topic Manager — Software Bill of Materials (SBOM)

**Version:** 1.0.2
**Date:** 2026-05-29
**Format:** CycloneDX-compatible markdown
**Copyright:** (c) 2025–2026 James Rodman. All Rights Reserved.
**SBOM Serial:** urn:topic-manager:sbom:1.0.2

---

## Frontend Dependencies

| Component | Version  | License  | Source                     |
|-----------|----------|----------|----------------------------|
| Vue.js    | 3.5.35   | MIT      | vuejs.org                  |

## Backend Dependencies

| Component        | Version | License         | Source                              |
|------------------|---------|-----------------|-------------------------------------|
| Flask            | 3.1.3   | BSD-3-Clause    | flask.palletsprojects.com           |
| gunicorn         | 26.0.0  | MIT             | gunicorn.org                        |
| ldap3            | 2.9.1   | LGPL-3.0        | ldap3.readthedocs.io                |
| confluent-kafka  | 2.14.0  | Apache-2.0      | confluent.io / github.com/confluentinc/confluent-kafka-python |
| PyYAML           | 6.0.2   | MIT             | pyyaml.org                          |
| cryptography     | 44.0.2  | Apache-2.0/BSD  | cryptography.io                     |
| Werkzeug         | 3.1.8   | BSD-3-Clause    | werkzeug.palletsprojects.com        |

## Database

| Component | Version | License      | Source       |
|-----------|---------|--------------|--------------|
| SQLite    | 3.x     | Public Domain | sqlite.org  |

## Infrastructure

| Component     | Version    | License    | Source            |
|---------------|------------|------------|-------------------|
| nginx         | 1.24.0     | BSD-2-Clause | nginx.org       |
| Ubuntu Server | 24.04 LTS  | Various    | ubuntu.com        |
| Python        | 3.12       | PSF-2.0    | python.org        |
| Apache Kafka  | 3.8.x      | Apache-2.0 | kafka.apache.org  |

## Notes

- This product ships no proprietary third-party commercial components.
- Offline install packages are governed by the licenses listed above.
- Full license texts are reproduced in NOTICES.md.
