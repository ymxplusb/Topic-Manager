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

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-config-example: no python found" >&2; exit 3; }

[[ -f "$CFG" ]] || { echo "check-config-example: ${CFG} not found" >&2; exit 1; }
[[ -s "$CFG" ]] || { echo "check-config-example: ${CFG} is EMPTY" >&2; exit 1; }

"$PY" - "$CFG" <<'PYCHK'
import sys, yaml

path = sys.argv[1]
try:
    cfg = yaml.safe_load(open(path, encoding="utf-8"))
except Exception as exc:
    print("FAIL: %s does not parse: %s" % (path, exc)); sys.exit(1)

if not isinstance(cfg, dict):
    print("FAIL: %s parsed to %r — expected a mapping. An empty file parses to "
          "None and would otherwise pass." % (path, type(cfg).__name__))
    sys.exit(1)

# Keys the application actually reads. Sources:
#   tm/app.py        server.secret_key, session.timeout_minutes
#   tm/auth.py       auth.ldap_server, ldap_domain, ldap_base_dn, required_group
#   tm/models.py     audit.db_path
#   tm/config.py     clusters[] (get_active_cluster / get_cluster_by_id)
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

clusters = cfg.get("clusters")
if not isinstance(clusters, list) or not clusters:
    missing.append("clusters (must be a non-empty list)")
else:
    for i, c in enumerate(clusters):
        if not isinstance(c, dict):
            missing.append("clusters[%d] (not a mapping)" % i); continue
        for k in ("id", "name", "bootstrap_servers"):
            if k not in c:
                missing.append("clusters[%d].%s" % (i, k))

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

print("OK: %s has all required sections and keys (%d clusters, placeholder secret)"
      % (path, len(clusters)))
PYCHK
