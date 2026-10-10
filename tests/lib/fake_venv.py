#!/usr/bin/env python3
"""
tests/lib/fake_venv.py <dir> [--clear]

A venv laid out the way `python3 -m venv` lays it out, by THIS interpreter
(t55 runs it as the stand-in for `python3 -m venv`): bin/python3 a link to
sys.executable, bin/python and bin/python3.N links to python3, pyvenv.cfg
with home = the interpreter's directory and include-system-site-packages =
false, lib/python3.N/site-packages, a bin/activate, and - in a NEW venv
only, as ensurepip does - pip 24.0 (tests/lib/fake_dist.py, so `bin/python3
-m pip` is the stand-in pip). Without --clear an existing venv keeps what is
installed in it; with it, the directory is emptied first.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import os
import platform
import pwd
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fake_dist  # noqa: E402

ACTIVATE = '''_OLD_PATH="$PATH"; PATH="%s/bin:$PATH"; export PATH
deactivate() { PATH="$_OLD_PATH"; export PATH; unset -f deactivate; }
'''


def main(d, clear):
    d = os.path.abspath(d)
    if clear:
        shutil.rmtree(d, ignore_errors=True)
    minor = sys.version_info[1]
    site = os.path.join(d, "lib", "python3.%d" % minor, "site-packages")
    fresh = not os.path.isdir(site)
    os.makedirs(os.path.join(d, "bin"), exist_ok=True)
    os.makedirs(site, exist_ok=True)
    for name, target in (("python3", sys.executable), ("python", "python3"), ("python3.%d" % minor, "python3")):
        p = os.path.join(d, "bin", name)
        if os.path.lexists(p):
            os.remove(p)
        os.symlink(target, p)
    with open(os.path.join(d, "pyvenv.cfg"), "w") as f:
        f.write("home = %s\ninclude-system-site-packages = false\nversion = %s\n"
                % (os.path.dirname(sys.executable), platform.python_version()))
    with open(os.path.join(d, "bin", "activate"), "w") as f:
        f.write(ACTIVATE % d)
    if fresh:
        fake_dist.make(site, "pip", "24.0")
    # STUB_VENV_OWNER: hand the whole venv to that account and make it group-
    # and world-writable, as a v1.0.3..v1.3.2 upgrade (and a loose umask) left
    # it, so a test can see the installer take it back (REG-0078).
    owner = os.environ.get("STUB_VENV_OWNER")
    if owner:
        uid, gid = pwd.getpwnam(owner)[2:4]
        for root, dirs, files in os.walk(d):
            for n in [root] + [os.path.join(root, x) for x in dirs + files]:
                os.lchown(n, uid, gid)
                if not os.path.islink(n):
                    os.chmod(n, os.stat(n).st_mode & 0o7777 | (0o777 if os.path.isdir(n) else 0o666))


if __name__ == "__main__":
    main(sys.argv[1], "--clear" in sys.argv[2:])
