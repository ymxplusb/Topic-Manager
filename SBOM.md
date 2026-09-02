# Jarvis Topic Manager — Software Bill of Materials (SBOM)

**Version:** 1.0.5
**Date:** 2026-09-02
**Format:** CycloneDX-compatible markdown
**Copyright:** (c) 2025–2026 James Rodman. All Rights Reserved.
**SBOM Serial:** urn:topic-manager:sbom:1.0.5

> The backend table below is generated from `requirements.txt`, which is the single source
> of truth for every Python pin: `install/upgrade-full.sh` installs exactly these versions on
> the target and `prepare-offline.sh` downloads exactly these wheels for an air-gapped host.
> `NOTICES.md` lists the same set, with licence text.

---

## Frontend Dependencies

| Component | Version  | License  | Source                     | Pinned by |
|-----------|----------|----------|----------------------------|-----------|
| Vue.js    | 3.5.42   | MIT      | vuejs.org                  | `install/upgrade-full.sh` — version **and SHA-256** (`aae6339a…ca2c`), verified before deploy and before bundling |

**Known divergence:** `install.sh` (fresh install only) still requests Vue **3.5.35** from
the CDN and serves whatever it receives, with no integrity check. A host that has been
upgraded runs the verified 3.5.42; a host freshly installed and never upgraded runs an
unverified 3.5.35. Tracked as an open defect against `install.sh`.

## Backend Dependencies

| Component        | Version | License         | Source                              |
|------------------|---------|-----------------|-------------------------------------|
| Flask            | 3.1.3   | BSD-3-Clause    | flask.palletsprojects.com           |
| Werkzeug         | 3.1.8   | BSD-3-Clause    | werkzeug.palletsprojects.com        |
| gunicorn         | 26.2.0  | MIT             | gunicorn.org                        |
| ldap3            | 2.9.1   | LGPL-3.0        | ldap3.readthedocs.io                |
| PyYAML           | 6.0.3   | MIT             | pyyaml.org                          |
| cryptography     | 50.0.1  | Apache-2.0/BSD  | cryptography.io                     |
| confluent-kafka  | 2.15.0  | Apache-2.0      | confluent.io / github.com/confluentinc/confluent-kafka-python |

`cryptography` became a **direct, first-party** dependency in v1.0.4: `tm/clusters.py`
imports `x509` and `serialization` to parse every PEM the Cluster Builder accepts before it
is written to disk. It was already pinned and already installed — this is a note about how
it is used, not a new pin. The pin remains 50.0.1 for the advisories listed under
*Vulnerability status*.

## Database

| Component | Version | License      | Source       |
|-----------|---------|--------------|--------------|
| SQLite    | 3.45.1  | Public Domain | sqlite.org  |

## Infrastructure

Installed on the host by `install.sh`. Every row here is something this product
adds to a machine, so every row can be checked against an advisory feed.

| Component | Version | License | Source |
|-----------|---------|---------|--------|
| nginx | 1.24.0 | BSD-2-Clause | nginx.org |
| polkit (`polkitd`) | 124 | LGPL-2.0+ and Expat | polkit.freedesktop.org |
| Python | 3.12.3 | PSF-2.0 | python.org |
| SQLite | 3.45.1 | Public Domain | sqlite.org |

**SQLite is not a separate package.** `sqlite3` is not installed on the target;
3.45.1 is the library compiled into Python 3.12.3's stdlib `_sqlite3`. It moves
when Python moves, and cannot be upgraded independently.

**polkit is an OS component we configure, not one we vendor.** It ships with
Ubuntu Server 24.04. `install.sh` adds `/etc/polkit-1/rules.d/50-topic-manager.rules`,
which authorises the `topic-manager` account for exactly three unit/verb pairs
(`restart topic-manager.service`, `reload`/`restart nginx.service`,
`start topic-manager-nginx-test.service`) and nothing else.

### Target platform

Ubuntu Server **24.04.4 LTS** — the platform this product is installed onto, not
a component it ships. Recorded here so the baseline is not lost; patch state is
the host owner's responsibility.

### External services — NOT components

These are connected to, never installed or shipped. Ports, protocols and
directions are in `PPSM.csv`.

| Service | Where | Measured |
|---------|-------|----------|
| Apache Kafka | broker1-3.int.crypticlight.com:9092 | 4.2.1 (`kafka_2.13-4.2.1`) |
| Active Directory | dc1.int.crypticlight.com:636 (LDAPS) | — |

Listing Kafka as a component overstated what this product ships: it is not
present on the application host at all.

## Tooling (not shipped to the target host)

| Tool | Purpose |
|------|---------|
| `tools/sca-check.sh` | Software Composition Analysis gate. Queries OSV.dev for every `==` pin in `requirements.txt` and for the Vue pin. Exits 1 on any advisory, 2 if a package could not be checked, 3 if OSV is unreachable — it does not report a pass it did not earn. Uses `curl` only; no third-party dependency of its own |
| `prepare-offline.sh` | Builds the offline bundle and verifies it against `requirements.txt` and the Vue hash |
| `install/upgrade-full.sh` | Audit, backup, upgrade, restore |

## Vulnerability status

Every pin above was checked against OSV.dev on **2026-09-01** and carries no known
advisory. Superseded pins and why they moved:

| Component | Was | Now | Reason |
|---|---|---|---|
| cryptography | 44.0.2 | 50.0.1 | CVE-2026-69247, CVE-2026-69248, CVE-2026-69249, CVE-2026-26007, CVE-2026-34073 |
| Flask | 3.1.0 | 3.1.3 | CVE-2025-47278, CVE-2026-27205 (moved in 1.0.2) |
| Werkzeug | 3.1.3 | 3.1.8 | CVE-2026-21860, CVE-2025-66221, CVE-2026-27199 (moved in 1.0.2) |
| gunicorn | 26.0.0 | 26.2.0 | maintenance |
| PyYAML | 6.0.2 | 6.0.3 | maintenance |
| confluent-kafka | 2.14.0 | 2.15.0 | maintenance |

## Notes

- This product ships no proprietary third-party commercial components.
- Offline install packages are governed by the licenses listed above.
- Full license texts are reproduced in NOTICES.md.
- Re-run `bash tools/sca-check.sh` against `requirements.txt` before every release. Checking
  what happens to be installed on one host is not the same check.
