#!/usr/bin/env python3
"""
tests/lib/fake_dist.py <site-packages> <name> <version>

Writes one installed distribution the way pip leaves it, small: a package
directory <k>/__init__.py, <k>-<version>.dist-info/METADATA and a RECORD that
lists both with their sha256 (urlsafe base64, no padding) and itself with no
hash. <k> is the name with "-" and "." as "_". An existing <k>/__init__.py is
overwritten (as installing another version over it would). Used by t55 to
build venvs for venv_drift without a network or a real pip.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import base64
import hashlib
import os
import sys


def main():
    site, name, ver = sys.argv[1], sys.argv[2], sys.argv[3]
    k = name.replace("-", "_").replace(".", "_")
    info = "%s-%s.dist-info" % (k, ver)
    files = {
        "%s/__init__.py" % k: ("# %s %s\n" % (name, ver)).encode(),
        "%s/METADATA" % info: ("Metadata-Version: 2.1\nName: %s\nVersion: %s\n" % (name, ver)).encode(),
    }
    rows = []
    for rel, data in files.items():
        path = os.path.join(site, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        rows.append("%s,sha256=%s,%d" % (rel, digest, len(data)))
    rows.append("%s/RECORD,," % info)
    with open(os.path.join(site, info, "RECORD"), "w") as f:
        f.write("\n".join(rows) + "\n")


if __name__ == "__main__":
    main()
