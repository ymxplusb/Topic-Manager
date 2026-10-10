"""
tests/lib/fake_pip_main.py — installed by tests/lib/fake_dist.py as the
venv's pip/__main__.py, so `<venv>/bin/python3 -m pip` and `<venv>/bin/pip`
run THIS under the real interpreter (t55). It never touches a network:

  pip --version             "pip <installed version> from ..." (or
                            STUB_PIP_REPORT, to play a pip that did not move)
  pip install ... -r FILE   appends "pip install <args>" to STUB_LOG, keeps a
                            copy of FILE as STUB_LOG.req.<n>, exits
                            STUB_PIP_RC if set, else "installs" every
                            column-0 name==version of FILE with fake_dist
                            (replacing an installed version), plus one
                            STUB_EXTRA package per name (version 1.0)

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import glob
import os
import re
import shutil
import sys

SITE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _fake_dist():
    sys.path.insert(0, os.path.dirname(os.environ["STUB_FAKE_DIST"]))
    import fake_dist
    return fake_dist


def _remove(fd, name):
    norm = re.sub(r"[-_.]+", "-", name).lower()
    for d in glob.glob(os.path.join(SITE, "*.dist-info")):
        if re.sub(r"[-_.]+", "-", os.path.basename(d)[:-len(".dist-info")].rsplit("-", 1)[0]).lower() == norm:
            shutil.rmtree(d)
    shutil.rmtree(os.path.join(SITE, fd.import_name(name)), ignore_errors=True)


def main(argv):
    if argv[:1] == ["--version"]:
        v = os.environ.get("STUB_PIP_REPORT", "")
        for d in glob.glob(os.path.join(SITE, "pip-*.dist-info")):
            v = v or os.path.basename(d)[len("pip-"):-len(".dist-info")]
        if v:
            print("pip %s from %s/pip (python 3)" % (v, SITE))
        return 0
    if argv[:1] != ["install"]:
        sys.stderr.write("fake pip: unexpected %s\n" % " ".join(argv))
        return 9
    log = os.environ["STUB_LOG"]
    with open(log, "a") as f:
        f.write("pip install %s\n" % " ".join(argv[1:]))
    req = argv[argv.index("-r") + 1]
    n = len(glob.glob(log + ".req.*")) + 1
    shutil.copy(req, "%s.req.%d" % (log, n))
    rc = int(os.environ.get("STUB_PIP_RC") or 0)
    if rc:
        return rc
    fd = _fake_dist()
    for line in open(req):
        m = re.match(r"^([A-Za-z0-9._-]+)==([^\s\\]+)", line)
        if m:
            _remove(fd, m.group(1))
            fd.make(SITE, m.group(1), m.group(2))
    for x in os.environ.get("STUB_EXTRA", "").split():
        fd.make(SITE, x, "1.0")
    return 0


sys.exit(main(sys.argv[1:]))
