#!/usr/bin/env python3
"""
tests/lib/fake_dist.py <site-packages> <name> <version>

Writes one installed distribution the way pip leaves it, small: the import
package <m>/__init__.py, <k>-<version>.dist-info/METADATA and a RECORD that
lists them with their sha256 (urlsafe base64, no padding) and itself with no
hash. <k> is the name with "-" and "." as "_" (case kept, as in the dist-info
directory); <m> is the IMPORT name - <k> lower-cased, PyYAML's "yaml" - so a
real interpreter can `import flask, yaml, confluent_kafka` from it.

pip itself gets what the venv needs to RUN it: pip/__main__.py (the stand-in
pip, tests/lib/fake_pip_main.py) and the bin/pip, bin/pip3, bin/pip3.N entry
points, RECORDed as ../../../bin/<name> exactly as pip records its own.
An existing file is overwritten (as installing another version over it).
Used by t55 to build venvs for the installers and venv_drift without a
network or a real pip.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import base64
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
IMPORT_NAMES = {"pyyaml": "yaml"}


def import_name(name):
    k = name.replace("-", "_").replace(".", "_").lower()
    return IMPORT_NAMES.get(k, k)


def make(site, name, ver):
    site = os.path.abspath(site)
    k = name.replace("-", "_").replace(".", "_")
    m = import_name(name)
    info = "%s-%s.dist-info" % (k, ver)
    files = {
        "%s/__init__.py" % m: ("# %s %s\n" % (name, ver)).encode(),
        "%s/METADATA" % info: ("Metadata-Version: 2.1\nName: %s\nVersion: %s\n" % (name, ver)).encode(),
    }
    if m == "pip":
        venv = os.path.dirname(os.path.dirname(os.path.dirname(site)))
        with open(os.path.join(HERE, "fake_pip_main.py"), "rb") as f:
            files["pip/__main__.py"] = f.read()
        script = ("#!%s/bin/python3\nimport runpy, sys\nsys.argv[0] = 'pip'\n"
                  "runpy.run_module('pip', run_name='__main__', alter_sys=True)\n" % venv).encode()
        for b in ("pip", "pip3", "pip3.%d" % sys.version_info[1]):
            files["../../../bin/%s" % b] = script
    rows = []
    for rel, data in files.items():
        path = os.path.normpath(os.path.join(site, rel))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.lexists(path):
            os.remove(path)
        with open(path, "wb") as f:
            f.write(data)
        if rel.startswith("../"):
            os.chmod(path, 0o755)
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        rows.append("%s,sha256=%s,%d" % (rel, digest, len(data)))
    rows.append("%s/RECORD,," % info)
    with open(os.path.join(site, info, "RECORD"), "w") as f:
        f.write("\n".join(rows) + "\n")


if __name__ == "__main__":
    make(sys.argv[1], sys.argv[2], sys.argv[3])
