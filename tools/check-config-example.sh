#!/usr/bin/env bash
# =============================================================================
# check-config-example.sh — config example gate
#
# The previous gate was `yaml.safe_load(open(...))`, which proves the file
# PARSES and nothing more. Gatekeeper demonstrated on 2026-08-30 that a
# ZERO-BYTE config/config.yaml.example passes it: yaml.safe_load("") returns
# None and exits 0. A truncated example config would ship green to operators.
# Silence was being treated as evidence.
#
# This gate asserts the example actually carries the keys the application
# reads, so an empty or gutted file fails.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${REPO_ROOT}/config/config.yaml.example"
CLU="${REPO_ROOT}/config/clusters.yaml.example"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-config-example: no python found" >&2; exit 3; }

[[ -f "$CFG" ]] || { echo "check-config-example: ${CFG} not found" >&2; exit 1; }
[[ -s "$CFG" ]] || { echo "check-config-example: ${CFG} is EMPTY" >&2; exit 1; }
[[ -f "$CLU" ]] || { echo "check-config-example: ${CLU} not found" >&2; exit 1; }
[[ -s "$CLU" ]] || { echo "check-config-example: ${CLU} is EMPTY" >&2; exit 1; }

"$PY" - "$CFG" "$CLU" <<'PYCHK'
import sys, yaml

path, clu_path = sys.argv[1], sys.argv[2]


def load_mapping(p):
    try:
        doc = yaml.safe_load(open(p, encoding="utf-8"))
    except Exception as exc:
        print("FAIL: %s does not parse: %s" % (p, exc)); sys.exit(1)
    if not isinstance(doc, dict):
        print("FAIL: %s parsed to %r — expected a mapping. An empty file parses "
              "to None and would otherwise pass." % (p, type(doc).__name__))
        sys.exit(1)
    return doc


cfg = load_mapping(path)
clu = load_mapping(clu_path)

# Keys the application actually reads. Sources:
#   tm/app.py        server.secret_key, session.timeout_minutes
#   tm/auth.py       auth.ldap_server, ldap_domain, ldap_base_dn, required_group
#   tm/models.py     audit.db_path
#
# clusters[] is NOT here any more: as of v1.0.4 the cluster list lives in
# config/clusters.yaml.example -> /etc/topic-manager/clusters.d/clusters.yaml,
# because the application has to be able to WRITE it and must never be able to
# write config.yaml. It is checked separately below, and config.yaml.example
# carrying a clusters: block is now itself a failure — two files claiming to
# hold the cluster list is exactly the shadowing this split exists to prevent.
REQUIRED = {
    "server":   ["host", "port", "secret_key"],
    "auth":     ["ldap_server", "ldap_domain", "ldap_base_dn", "required_group"],
    "session":  ["timeout_minutes"],
    "audit":    ["db_path"],
}

missing = []
for section, keys in REQUIRED.items():
    if section not in cfg:
        missing.append(section); continue
    if not isinstance(cfg[section], dict):
        missing.append("%s (not a mapping)" % section); continue
    for k in keys:
        if k not in cfg[section]:
            missing.append("%s.%s" % (section, k))

if "clusters" in cfg:
    missing.append("clusters MUST NOT be in config.yaml.example any more "
                   "(it moved to clusters.yaml.example in v1.0.4)")

clusters = clu.get("clusters")
if not isinstance(clusters, list) or not clusters:
    missing.append("%s: clusters (must be a non-empty list)" % clu_path)
    clusters = []
else:
    seen_ids, seen_names = set(), set()
    for i, c in enumerate(clusters):
        if not isinstance(c, dict):
            missing.append("clusters[%d] (not a mapping)" % i); continue
        for k in ("id", "name", "bootstrap_servers", "security_protocol"):
            if k not in c:
                missing.append("clusters[%d].%s" % (i, k))
        # A duplicate id makes get_cluster_by_id arbitrary and a duplicate name
        # makes the two indistinguishable to the operator choosing one.
        if c.get("id") in seen_ids:
            missing.append("clusters[%d].id %r is a duplicate" % (i, c.get("id")))
        seen_ids.add(c.get("id"))
        if str(c.get("name", "")).lower() in seen_names:
            missing.append("clusters[%d].name %r is a duplicate" % (i, c.get("name")))
        seen_names.add(str(c.get("name", "")).lower())
        # Cert material is stored under the cert directory and nowhere else.
        # An example pointing into /etc would teach operators the exact shape
        # the loader refuses.
        for k in ("ssl_cafile", "ssl_certfile", "ssl_keyfile"):
            v = c.get(k)
            if v and not str(v).startswith("/opt/topic-manager/data/cluster-certs/"):
                missing.append("clusters[%d].%s must be under "
                               "/opt/topic-manager/data/cluster-certs/ (found %r)"
                               % (i, k, v))

if len([c for c in clusters if isinstance(c, dict) and c.get("active")]) != 1:
    missing.append("%s: exactly one cluster must have active: true" % clu_path)

if missing:
    print("FAIL: %s is missing required keys:" % path)
    for m in missing:
        print("  - %s" % m)
    sys.exit(1)

# The example must ship a placeholder, never a real secret.
sk = str(cfg["server"].get("secret_key", ""))
if sk and "CHANGE_ME" not in sk and len(sk) >= 32:
    print("FAIL: server.secret_key in the EXAMPLE looks like a real key "
          "(%d chars, no CHANGE_ME placeholder). Never commit a real secret." % len(sk))
    sys.exit(1)

print("OK: %s has all required sections and keys (placeholder secret), and "
      "%s carries %d valid cluster profile(s)"
      % (path, clu_path, len(clusters)))
PYCHK
