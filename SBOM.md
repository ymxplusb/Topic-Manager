# Jarvis Topic Manager — Software Bill of Materials (SBOM)

**Version:** 1.0.6
**Date:** 2026-09-02
**Format:** CycloneDX-compatible markdown
**Copyright:** (c) 2025–2026 James Rodman. All Rights Reserved.
**SBOM Serial:** urn:topic-manager:sbom:1.0.6

> The backend table below is generated from `requirements.txt`, which is the single source
> of truth for every Python pin: `install/upgrade-full.sh` installs exactly these versions on
> the target and `prepare-offline.sh` downloads exactly these wheels for an air-gapped host.
> `NOTICES.md` lists the same set, with licence text.

---

## Frontend Dependencies

| Component | Version  | License  | Source                     | Pinned by |
|-----------|----------|----------|----------------------------|-----------|
| Vue.js    | 3.5.43   | MIT      | vuejs.org                  | `install/upgrade-full.sh` — version **and SHA-256** (`b7239405…478e`), verified before deploy and before bundling |

**One verified Vue on every route.** `install.sh`, `prepare-offline.sh` and
`install/upgrade-full.sh` all read the version and the SHA-256 from the same two lines in
`install/upgrade-full.sh` and refuse a file that does not match. A fresh install, an
offline install and an upgrade therefore serve byte-identical Vue. (The "known divergence"
recorded here until v1.0.x — fresh installs fetching an unverified 3.5.35 — was closed when
`install.sh` began verifying the pin, and no longer applies.)

The 3.5.43 hash was verified against the **npm registry tarball**
(`registry.npmjs.org/vue/-/vue-3.5.43.tgz`, whose sha512 matches the registry's own
`dist.integrity`), by extracting `package/dist/vue.global.prod.js` and hashing it; the
jsDelivr file the installers fetch is byte-identical to it. The CDN was not trusted to
vouch for itself.

## Backend Dependencies

| Component        | Version | License         | Source                              |
|------------------|---------|-----------------|-------------------------------------|
| Flask            | 3.1.3   | BSD-3-Clause    | flask.palletsprojects.com           |
| Werkzeug         | 3.1.8   | BSD-3-Clause    | werkzeug.palletsprojects.com        |
| gunicorn         | 26.2.0  | MIT             | gunicorn.org                        |
| ldap3            | 2.9.1   | LGPL-3.0        | ldap3.readthedocs.io                |
| PyYAML           | 6.0.3   | MIT             | pyyaml.org                          |
| cryptography     | 50.0.1  | Apache-2.0/BSD  | cryptography.io                     |
| confluent-kafka  | 2.15.1  | Apache-2.0      | confluent.io / github.com/confluentinc/confluent-kafka-python |

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

| Service | Where | Notes |
|---------|-------|-------|
| Apache Kafka | the brokers named in each cluster profile (operator-defined ports, commonly 9092/9093/9094) | AdminClient protocol; any broker version the confluent-kafka client supports |
| Directory (Active Directory or other LDAPS) | `auth.ldap_server` in `config.yaml` (LDAPS 636) | no built-in default since v1.1.0 |

Listing Kafka as a component overstated what this product ships: it is not
present on the application host at all.

## Cryptographic module boundary (FIPS) — known limitation

The product runs on a STIG-hardened Ubuntu 24.04 host with FIPS mode enabled. Which
cryptography runs inside the host's FIPS-validated OpenSSL, and which does not:

| Component | Crypto provider | Inside the host's validated module? |
|---|---|---|
| nginx (TLS termination, 443) | host OpenSSL 3.0 (Ubuntu) | **Yes** when FIPS mode is on. Cipher list is FIPS-approved only |
| Python `ssl` (LDAPS to the directory) and `hashlib` (session-cookie HMAC-SHA-256) | host OpenSSL via the system `python3` | **Yes** |
| `cryptography` 50.0.1 (PEM parsing of uploaded cluster certificates) | OpenSSL **bundled in the wheel** | **No** |
| `confluent-kafka` 2.15.1 / librdkafka (TLS to SSL/SASL_SSL Kafka brokers) | OpenSSL **bundled in the wheel** | **No** |

Both bundled copies **run** on a FIPS host — nothing fails — but their cryptography is outside
the host's validated boundary. This is recorded as a **known limitation**, not a defect: PyPI
wheels are statically linked by their publishers, and there is no FIPS-validated wheel of
either package. Operators who must keep every TLS session inside the validated module should
keep the Kafka path inside a boundary their accreditation already covers, or accept and record
the limitation. Measured facts behind this table come from how the wheels are built; a run on a
FIPS-enabled host has not yet been made (see CHANGELOG 1.1.0 → *Not verified*).

## Tooling (not shipped to the target host)

| Tool | Purpose |
|------|---------|
| `tools/check-env-neutral.sh` | Refuses a tracked tree or an offline bundle that names the site it was built at (host names, private addresses, account names, paths), or a bundle carrying the repository's process records |
| `tools/check-ppsm-consistency.sh` | Runs the real Settings → Download PPSM generator and requires it to equal `PPSM.csv` |
| `tools/sca-check.sh` | Software Composition Analysis gate. Queries OSV.dev for every `==` pin in `requirements.txt` and for the Vue pin. Exits 1 on any advisory, 2 if a package could not be checked, 3 if OSV is unreachable — it does not report a pass it did not earn. Uses `curl` only; no third-party dependency of its own |
| `prepare-offline.sh` | Builds the offline bundle from `git archive` of the committed tree, verifies it against `requirements.txt` and the Vue hash, and runs the leak check on it |
| `install/upgrade-full.sh` | Audit, backup, upgrade, restore |

## Vulnerability status

Every pin above was checked against OSV.dev on **2026-09-26** (`tools/sca-check.sh`: 8 clean,
0 vulnerable) and carries no known advisory. Every Python pin was also re-measured on PyPI
that day and is the latest stable release; Vue 3.5.43 is the latest on npm. Superseded pins and why they moved:

| Component | Was | Now | Reason |
|---|---|---|---|
| cryptography | 44.0.2 | 50.0.1 | CVE-2026-69247, CVE-2026-69248, CVE-2026-69249, CVE-2026-26007, CVE-2026-34073 |
| Flask | 3.1.0 | 3.1.3 | CVE-2025-47278, CVE-2026-27205 (moved in 1.0.2) |
| Werkzeug | 3.1.3 | 3.1.8 | CVE-2026-21860, CVE-2025-66221, CVE-2026-27199 (moved in 1.0.2) |
| gunicorn | 26.0.0 | 26.2.0 | maintenance |
| PyYAML | 6.0.2 | 6.0.3 | maintenance |
| confluent-kafka | 2.14.0 | 2.15.0 | maintenance (moved in 1.0.2) |
| confluent-kafka | 2.15.0 | 2.15.1 | maintenance (moved in 1.1.0) |
| Vue.js | 3.5.42 | 3.5.43 | maintenance (moved in 1.1.0) |

## Notes

- This product ships no proprietary third-party commercial components.
- Offline install packages are governed by the licenses listed above.
- Full license texts are reproduced in NOTICES.md.
- Re-run `bash tools/sca-check.sh` against `requirements.txt` before every release. Checking
  what happens to be installed on one host is not the same check.
