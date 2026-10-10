# Jarvis Topic Manager — Software Bill of Materials (SBOM)

**Version:** 1.3.3
**Date:** 2026-10-09
**Format:** CycloneDX-compatible markdown
**Copyright:** (c) 2025–2026 James Rodman. All Rights Reserved.
**SBOM Serial:** urn:topic-manager:sbom:1.3.3

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
| Werkzeug         | 3.1.9   | BSD-3-Clause    | werkzeug.palletsprojects.com        |
| gunicorn         | 26.2.0  | MIT             | gunicorn.org                        |
| ldap3            | 2.9.1   | LGPL-3.0        | ldap3.readthedocs.io                |
| PyYAML           | 6.0.3   | MIT             | pyyaml.org                          |
| cryptography     | 50.0.1  | Apache-2.0/BSD  | cryptography.io                     |
| confluent-kafka  | 2.15.1  | Apache-2.0      | confluent.io / github.com/confluentinc/confluent-kafka-python |
| pip              | 26.2.1  | MIT             | pip.pypa.io (venv tooling, v1.3.3)  |

**pip is a component (v1.3.3).** `python3 -m venv` puts pip itself into the application's
venv; on Ubuntu 24.04 that was ensurepip's 24.0, carrying six advisories, and because it was
in no requirements file nothing pinned, hashed, scanned or upgraded it. It is now a direct pin
under *venv tooling* in `requirements.txt`, hash-locked in `requirements.lock`, scanned by
`tools/sca-check.sh`, upgraded first by every installer, and the installed venv is held to
exactly the locked set (`venv_drift`). A 3.12 venv carries no setuptools and no wheel
(measured in ubuntu:24.04 and python:3.12), so neither is a component.

`cryptography` became a **direct, first-party** dependency in v1.0.4: `tm/clusters.py`
imports `x509` and `serialization` to parse every PEM the Cluster Builder accepts before it
is written to disk. It was already pinned and already installed — this is a note about how
it is used, not a new pin. The pin remains 50.0.1 for the advisories listed under
*Vulnerability status*.

## Transitive Python dependencies (requirements.lock)

Installed alongside the pins above and verified the same way: `requirements.lock` carries the
SHA-256 of every published wheel of each, and every installer uses `--require-hashes`.
`tools/sca-check.sh` queries OSV for these too.

| Component | Version | License | Pulled in by |
|-----------|---------|---------|--------------|
| blinker | 1.9.0 | MIT | Flask |
| click | 8.5.0 | BSD-3-Clause | Flask |
| itsdangerous | 2.2.0 | BSD-3-Clause | Flask |
| Jinja2 | 3.1.6 | BSD-3-Clause | Flask |
| MarkupSafe | 3.0.4 | BSD-3-Clause | Jinja2, Werkzeug |
| cffi | 2.1.1 | MIT | cryptography |
| pycparser | 3.11 | BSD-3-Clause | cffi |
| pyasn1 | 0.6.4 | BSD-2-Clause | ldap3 |

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
| rsyslog (v1.2.0: remote syslog forwarding) | 8.2312.0 | GPL-3.0+ / LGPL-3.0+ / Apache-2.0 | rsyslog.com |
| rsyslog-openssl (v1.2.0: syslog over TLS) | same source as rsyslog, 8.2312.0 (binaries of one Debian source move in lockstep) — NOT measured: absent on both measured hosts | as rsyslog | rsyslog.com |
| chrony (v1.2.0: time source; only where no time daemon runs or `--install-chrony`) | 4.5 | GPL-2.0 | chrony-project.org |

MEASURED 2026-09-26: rsyslog `8.2312.0-3ubuntu9.2` and chrony `4.5-1ubuntu4.2` on the STIG+FIPS
QC host (Ubuntu 24.04.4); rsyslog 8.2312.0 on the test host, which runs systemd-timesyncd, not
chrony. rsyslog is part of Ubuntu Server; chrony REPLACES systemd-timesyncd when installed (they
conflict). The About dialog carries the same infrastructure rows, and
tools/check-sbom-consistency.sh holds the two copies to each other.

**SQLite is not a separate package.** The `sqlite3` CLI is not installed on the
target; 3.45.1 is the OS library (`libsqlite3-0`) that Python 3.12.3's stdlib
`_sqlite3` module links. It is patched by the host's own update process
(SRG-APP-000456, docs/STIG-COMPLIANCE.md: the product neither holds it back nor
carries a copy of its own); an air-gapped host is patched only through its
operator's update media.

**polkit is an OS component we configure, not one we vendor.** It ships with
Ubuntu Server 24.04. `install.sh` adds `/etc/polkit-1/rules.d/50-topic-manager.rules`,
which authorises the `topic-manager` account for exactly nine unit/verb pairs over
eight units (`restart topic-manager.service`, `reload`/`restart nginx.service`,
`start topic-manager-nginx-test.service`, since v1.2.0 `start` on the four
`topic-manager-apply-*.service` units and since v1.3.0 on the read-only
`topic-manager-apply-compliance.service`) and nothing else.

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
| v1.2.0 certificate upload checks (`tm/tls_check.py`, app and root helper) | the host `openssl` CLI, never `cryptography` | **Yes** — measured on the FIPS QC host: openssl itself refuses to make RSA-1024, secp256k1, Ed25519 and SHA-1 certificates there |
| v1.2.0 syslog over TLS (`rsyslog-openssl`, the `ossl` netstream driver) | host OpenSSL | **Yes** |

Both bundled copies **run** on a FIPS host — nothing fails — but their cryptography is outside
the host's validated boundary. This is recorded as a **known limitation**, not a defect: PyPI
wheels are statically linked by their publishers, and there is no FIPS-validated wheel of
either package. Operators who must keep every TLS session inside the validated module should
keep the Kafka path inside a boundary their accreditation already covers, or accept and record
the limitation. The "Yes" rows were measured on a STIG + FIPS Ubuntu 24.04 host (see CHANGELOG
1.1.0 → *Verified*); the "No" rows follow from how the wheels are built.

### Risk acceptance — Kafka client TLS outside the validated module

| | |
|---|---|
| **Finding** | The `confluent-kafka` 2.15.1 wheel bundles librdkafka and its **own** OpenSSL. Kafka client TLS therefore runs **outside** the host's FIPS 140-3 validated cryptographic module, even with `fips_enabled=1`. |
| **Mapping** | NIST SP 800-53 SC-13; SRG-APP-000014, SRG-APP-000514; CWE-327 |
| **Decision** | **Accepted by the system owner, 2026-09-26.** |
| **Compensating notes** | Kafka cluster profiles should use `SSL` or `SASL_SSL`, never `PLAINTEXT`. Every other TLS path on the host does use the validated module: nginx, LDAPS and Python `ssl` — measured on a STIG + FIPS Ubuntu 24.04 host (`fips_enabled=1`, provider "Ubuntu 24.04 OpenSSL Cryptographic Module 3.0.13+Fips2"). |
| **Path to remove the risk** | Run the Kafka client against the system OpenSSL: the distribution's `python3-confluent-kafka` package (linked to the system libssl), or a site-built wheel compiled against the system libssl. |

The `cryptography` wheel's bundled OpenSSL is used only to parse uploaded PEM certificates (no
TLS session, no key agreement) and remains a known limitation as described above.

## Tooling (not shipped to the target host)

| Tool | Purpose |
|------|---------|
| `tools/check-env-neutral.sh` | Refuses a tracked tree or an offline bundle that names the site it was built at (host names, private addresses, account names, paths), or a bundle carrying the repository's process records |
| `tools/check-ppsm-consistency.sh` | Runs the real Settings → Download PPSM generator and requires it to equal `PPSM.csv` |
| `tools/sca-check.sh` | Software Composition Analysis gate. Queries OSV.dev for every `==` pin in `requirements.txt` and for the Vue pin. Since v1.3.3 one OSV `/v1/querybatch` carries every query and only a well-formed answer for every one of them is a verdict (a bare `{}`, a page token alone, a short result list or a non-200 status is "could not check"; a page token is followed). Exits 1 on any advisory, 2 if a package could not be checked, 3 if OSV is unreachable — it does not report a pass it did not earn. Uses `curl` only; no third-party dependency of its own |
| `prepare-offline.sh` | Builds the offline bundle from `git archive` of the committed tree, verifies it against `requirements.txt` and the Vue hash, and runs the leak check on it |
| `install/upgrade-full.sh` | Audit, backup, upgrade, restore |

## Vulnerability status

Every pin above was checked against OSV.dev on **2026-10-09** (`tools/sca-check.sh`: 17 clean,
0 vulnerable — the 8 direct pins including pip, the 8 transitive lock entries, Vue; 16 of 16
lock entries checked) and carries no known advisory. The same run with pip 24.0 put back in the
lock is RED (`pip 24.0 VULNERABLE`, six GHSA / six PYSEC ids, exit 1). pip 26.2.1 was the latest release on
PyPI that day; the other Python pins were last re-measured as the latest stable releases on
2026-09-26, and Vue 3.5.43 as the latest on npm (not re-measured for 1.3.3). Superseded pins and why they moved:

| Component | Was | Now | Reason |
|---|---|---|---|
| cryptography | 44.0.2 | 50.0.1 | CVE-2026-69247, CVE-2026-69248, CVE-2026-69249, CVE-2026-26007, CVE-2026-34073 |
| Flask | 3.1.0 | 3.1.3 | CVE-2025-47278, CVE-2026-27205 (moved in 1.0.2) |
| Werkzeug | 3.1.3 | 3.1.8 | CVE-2026-21860, CVE-2025-66221, CVE-2026-27199 (moved in 1.0.2) |
| Werkzeug | 3.1.8 | 3.1.9 | CVE-2026-102598 (moved in 1.3.1) |
| pip (venv tooling) | 24.0 | 26.2.1 | CVE-2025-8869, CVE-2026-1703, CVE-2026-3219, CVE-2026-6357, CVE-2026-8643, CVE-2026-13346 — 24.0 was ensurepip's, unpinned and unscanned (moved in 1.3.3) |
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
