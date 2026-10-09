#!/usr/bin/env python3
"""
gen-requirements-lock.py — regenerate requirements.lock from requirements.txt.

requirements.txt names the DIRECT pins (the ones this project decides).
requirements.lock is what install.sh, install/upgrade-full.sh and
prepare-offline.sh actually install, with `pip --require-hashes`: every
package INCLUDING every transitive dependency, pinned exactly, with the
SHA-256 of every wheel PyPI publishes for that version. pip then refuses any
file whose hash is not listed, whatever index, mirror or bundle it came from.

How it is built (run on a developer machine with network access):
  1. resolve the full dependency set as the TARGET would — Linux x86_64,
     CPython 3.12, manylinux, binary wheels only — with
     `pip install --dry-run --report`;
  2. for each resolved (name, version), take the sha256 of EVERY wheel PyPI
     lists for that release from https://pypi.org/pypi/<name>/<version>/json.
     Listing all wheels (not just the x86_64 one) is what lets the same lock
     install on aarch64 too; sdists are never listed, so nothing is compiled.

    python tools/gen-requirements-lock.py            # rewrite requirements.lock
    python tools/gen-requirements-lock.py --check    # same verdict as the lock gate

VENV TOOLING (v1.3.3, REG-0068): `python3 -m venv` seeds the venv with pip
itself (24.0 from Ubuntu 24.04's ensurepip, six advisories), and nothing
locked it, scanned it or upgraded it. pip is now a direct pin in
requirements.txt ("venv tooling") and so an ordinary lock entry. It is
resolved the usual way: --target with --ignore-installed makes pip treat
`pip==X` as a package to install, not as itself (measured 2026-10-09 with
pip 25.0.1 and 26.2.1: the report lists it). That is pip's behaviour, not a
promise, so resolve() REFUSES a resolution that drops ANY direct pin (pip
included) instead of writing a lock without it; --check-set would then say
"NOT in the resolved set". setuptools and wheel are not locked because a
3.12 venv does not contain them (measured in ubuntu:24.04 and python:3.12).
Every installer upgrades pip from its lock entry FIRST, then installs the
whole lock, then holds the venv to exactly this set (venv_drift).

Needs pip >= 23 in the running interpreter and network access to PyPI.
tools/check-requirements-lock.sh verifies the result: published hashes and all target
wheel hashes, not byte equality with regeneration. Offline is exit 3 unless
TM_LOCK_OFFLINE_OK=1 explicitly accepts structure-only verification.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
# The ONE reader of requirements.lock, pip's rules; importable only after the
# sys.path insert above, hence the E402 waiver.
import lockparse  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if '--root' in sys.argv:          # the tree to read (tools/check-requirements-lock.sh --root)
    ROOT = sys.argv[sys.argv.index('--root') + 1]
REQ = os.path.join(ROOT, 'requirements.txt')
LOCK = os.path.join(ROOT, 'requirements.lock')
# A resolution that hangs (a stalled index, a proxy that never answers) is a
# "could not verify", not a gate that never returns (round 11, TM-RL-005).
RESOLVE_TIMEOUT = int(os.environ.get('TM_LOCK_RESOLVE_TIMEOUT') or 600)
PLATFORMS = ['manylinux_2_34_x86_64', 'manylinux_2_28_x86_64',
             'manylinux_2_17_x86_64', 'manylinux2014_x86_64']


def resolve_report(constraints=None):
    """pip's resolution of requirements.txt for the target, as the list of
    --report "install" items (each carries metadata: name, version and
    requires_dist). With constraints (a list of name==version), the resolver
    is held to them: a lock that is a valid closure resolves to itself."""
    with tempfile.TemporaryDirectory() as tmp:
        report = os.path.join(tmp, 'report.json')
        cmd = [sys.executable, '-m', 'pip', 'install', '--dry-run', '--ignore-installed',
               '--quiet', '--report', report, '--only-binary', ':all:',
               '--python-version', '3.12', '--implementation', 'cp', '--abi', 'cp312',
               '--target', os.path.join(tmp, 't'), '-r', REQ]
        if constraints is not None:
            cfile = os.path.join(tmp, 'constraints.txt')
            with open(cfile, 'w', encoding='ascii', newline='\n') as f:
                f.write(''.join('%s==%s\n' % nv for nv in constraints))
            cmd += ['-c', cfile]
        for p in PLATFORMS:
            cmd += ['--platform', p]
        subprocess.run(cmd, check=True, timeout=RESOLVE_TIMEOUT,
                       stderr=subprocess.PIPE if constraints is not None else None,
                       universal_newlines=True)
        data = json.load(open(report, encoding='utf-8'))
    return data['install']


def direct_pins():
    """{normalised name: version} of the == pins in requirements.txt."""
    pins = {}
    for line in open(REQ, encoding='utf-8'):
        m = re.match(r'^\s*([A-Za-z0-9._-]+)\s*==\s*(\S+)', line.split('#', 1)[0])
        if m:
            pins[lockparse.norm(m.group(1))] = m.group(2)
    return pins


def resolve():
    pins = sorted(((i['metadata']['name'], i['metadata']['version']) for i in resolve_report()),
                  key=lambda nv: nv[0].lower())
    # v1.3.3: a direct pin the resolution left out (pip special-casing
    # itself, say) is refused here, never written as a lock without it.
    got = {lockparse.norm(n): v for n, v in pins}
    lost = ['%s==%s' % nv for nv in sorted(direct_pins().items()) if got.get(nv[0]) != nv[1]]
    if lost:
        raise SystemExit('the resolution does not carry the direct pin(s) %s; refusing to write '
                         'a lock without them' % ', '.join(lost))
    return pins


def wheel_hashes(name, version):
    url = 'https://pypi.org/pypi/%s/%s/json' % (name, version)
    with urllib.request.urlopen(url, timeout=30) as r:
        meta = json.load(r)
    # Exact == pins can select yanked files too; include them so regeneration
    # satisfies the gate's all-published-target-files policy.
    hashes = sorted({f['digests']['sha256'] for f in meta['urls']
                     if f.get('packagetype') == 'bdist_wheel'})
    if not hashes:
        raise SystemExit('%s==%s has no wheels on PyPI; refusing to lock an sdist' % (name, version))
    return hashes


def render(pins):
    out = ['# requirements.lock - GENERATED by tools/gen-requirements-lock.py from',
           '# requirements.txt. Do not edit by hand; edit requirements.txt and regenerate.',
           '#',
           '# Every package the application needs, INCLUDING transitive dependencies,',
           '# pinned exactly, with the SHA-256 of every wheel PyPI publishes for that',
           '# version. Installed with `pip install --require-hashes --only-binary :all:`',
           '# by install.sh, install/upgrade-full.sh and prepare-offline.sh, so a file',
           '# whose hash is not listed here is refused, wherever it came from.',
           '# pip itself is an entry too (venv tooling, v1.3.3): the installers upgrade',
           '# the venv to it first, and the installed venv must hold exactly this set.',
           '']
    for name, version in pins:
        hashes = wheel_hashes(name, version)
        out.append('%s==%s \\' % (name, version))
        out.extend('    --hash=sha256:%s%s' % (h, ' \\' if i < len(hashes) - 1 else '')
                   for i, h in enumerate(hashes))
    return '\n'.join(out) + '\n'


def lock_bytes(text):
    """-> (bytes to write, problems). Round 12 (gatekeeper B1): the lock must
    be one every reader decodes and splits the same way - plain ASCII, no BOM,
    no coding line, LF only - with every entry whole at column 0. The bytes
    about to be written are checked by the readers' own rules; a lock they
    would refuse is never written."""
    data = text.encode('utf-8')
    probs = lockparse.byte_problems(data)
    if not probs:
        probs = lockparse.parse(text)[1] + lockparse.layout_problems(text)
    return data, probs


def lock_set():
    """The name==version set pip would install from requirements.lock (names
    normalised), read by tools/lib/lockparse.py — the same parser as the gate
    and sca-check.sh. Round 11 (gatekeeper N1): this used to match raw
    column-0 lines, so it counted an entry a comment had hidden from pip and
    missed an indented entry pip installs. A lock pip would refuse is an
    error here too (SystemExit 1), never a partial set."""
    try:
        entries, errors = lockparse.parse(lockparse.read(LOCK))
    except lockparse.LockEncodingError as e:
        errors = e.problems
    if errors:
        for e in errors:
            print('FAIL: %s' % e)
        sys.exit(1)
    return {(e['key'], e['version']) for e in entries}


#: The environment the lock is FOR (the target host), so a dependency behind a
#: marker ("; sys_platform == 'win32'", "; python_version < '3.8'") is judged
#: as the target would judge it, not as this workstation would.
TARGET_ENV = {'python_version': '3.12', 'python_full_version': '3.12.3', 'os_name': 'posix',
              'sys_platform': 'linux', 'platform_system': 'Linux', 'platform_machine': 'x86_64',
              'platform_python_implementation': 'CPython', 'implementation_name': 'cpython',
              'implementation_version': '3.12.3', 'platform_release': '', 'platform_version': ''}


def metadata_file(src):
    """Test hook (TM_LOCK_METADATA): the declared dependencies of each
    name==version from a JSON file ({"name==version": [requirement strings]})
    instead of a resolution. LookupError for a release it does not name."""
    meta = {lockparse.norm(k.split('==')[0]) + '==' + k.split('==', 1)[1]: v
            for k, v in json.load(open(src, encoding='utf-8')).items()}

    def deps(name, version):
        key = '%s==%s' % (name, version)
        if key not in meta:
            raise LookupError('no metadata for %s' % key)
        return meta[key] or []
    return deps


def _packaging():
    """packaging's Requirement and Version, imported only when a requirement
    string has to be judged (pip vendors it; a stand-alone copy is preferred)."""
    try:
        from packaging.requirements import Requirement
        from packaging.version import Version
    except ImportError:
        from pip._vendor.packaging.requirements import Requirement
        from pip._vendor.packaging.version import Version
    return Requirement, Version


def check_closure(locked, deps):
    """REG-0006 (v1.2.0): the lock is SELF-CONSISTENT and COMPLETE — every
    dependency of every locked package (markers evaluated for the TARGET, not
    this workstation) is itself locked, at a version its specifier accepts.
    The completeness check used to compare the lock with a FRESH newest
    resolution, so a valid, older, compatible lock (the usual state of a
    release branch) was reported as incomplete. deps(name, version) returns
    the declared requirement strings, or None when there is nothing to judge.
    Returns the list of problems."""
    wanted_extras = _requested_extras()
    problems = []
    for name, version in sorted(locked.items()):
        specs = deps(name, version)
        if not specs:
            continue
        requirement_cls, version_cls = _packaging()
        extras = wanted_extras.get(name, set()) | {''}
        for spec in specs:
            r = requirement_cls(spec)
            if not _applies_to_target(r, extras):
                continue
            dep = lockparse.norm(r.name)
            problem = _closure_problem(r, dep, locked, version_cls, '%s==%s' % (name, version), spec)
            if problem:
                problems.append(problem)
            wanted_extras.setdefault(dep, set()).update(r.extras)
    return problems


def _requested_extras():
    """{normalised name: extras} as requirements.txt asks for them; the
    closure walk adds the extras each dependency is required with."""
    wanted_extras = {}
    for line in open(REQ, encoding='utf-8'):
        m = re.match(r'^\s*([A-Za-z0-9._-]+)\s*(?:\[([^\]]*)\])?', line.split('#', 1)[0])
        if m:
            wanted_extras.setdefault(lockparse.norm(m.group(1)), set()).update(
                x.strip() for x in (m.group(2) or '').split(',') if x.strip())
    return wanted_extras


def _applies_to_target(r, extras):
    """A requirement with no marker always applies; one with a marker applies
    when it holds on the TARGET for any extra the package is installed with."""
    return r.marker is None or any(
        r.marker.evaluate(dict(TARGET_ENV, extra=e)) for e in extras)


def _closure_problem(r, dep, locked, version_cls, requirer, spec):
    """The problem one applicable requirement makes of the lock, or None."""
    if dep not in locked:
        return ('MISSING from requirements.lock: %s (%s requires %s)'
                % (dep, requirer, spec))
    if r.specifier and not r.specifier.contains(version_cls(locked[dep]), prereleases=True):
        return ('INCOMPATIBLE: %s==%s is locked, but %s requires %s'
                % (dep, locked[dep], requirer, spec))
    return None


def check_set():
    """--check-set: does the lock cover EXACTLY what pip installs from
    requirements.txt, and is it a self-consistent closure? -> (problems,
    verdict or None). SystemExit 3 when it cannot say.

    Round 8/11 (v1.1.0): the lock's set (lock_set, pip's parser) is compared
    with pip's resolution of requirements.txt: MISSING / NOT in the resolved
    set. REG-0006 (v1.2.0): that resolution is CONSTRAINED to the lock's own
    pins, so a valid older compatible closure resolves to itself and passes;
    a lock missing a dependency still resolves it fresh (MISSING), a package
    nothing needs is still NOT in the resolved set, and pins that cannot be
    installed together are ResolutionImpossible, reported as INCONSISTENT
    (exit 1), not as "could not verify". The resolution's own metadata
    (requires_dist) then feeds check_closure, which judges markers for the
    target. TM_LOCK_METADATA (tests) replaces the resolution with a metadata
    file: closure only."""
    have = lock_set()
    locked = dict(have)
    src = os.environ.get('TM_LOCK_METADATA')
    if src:
        try:
            problems = check_closure(locked, metadata_file(src))
        except Exception as e:  # no metadata: cannot say
            print('could not read the dependency metadata: %s: %s' % (type(e).__name__, e))
            sys.exit(3)
        print('closure judged from TM_LOCK_METADATA (no resolution)')
        return problems, len(have)
    try:
        items = resolve_report(constraints=sorted(have))
    except subprocess.CalledProcessError as e:
        err = (e.stderr or '') if isinstance(e.stderr, str) else ''
        sys.stdout.write(err)
        if 'ResolutionImpossible' in err:
            return ['INCONSISTENT: the locked versions cannot be installed together '
                    '(pip: ResolutionImpossible, above)'], None
        print('could not resolve requirements.txt: %s' % e)
        sys.exit(3)
    except Exception as e:  # no network, a timeout, a pip failure: cannot say
        print('could not resolve requirements.txt: %s' % e)
        sys.exit(3)
    want = {(lockparse.norm(i['metadata']['name']), i['metadata']['version']) for i in items}
    meta = {(lockparse.norm(i['metadata']['name']), i['metadata']['version']):
            i['metadata'].get('requires_dist') or [] for i in items}
    problems = ['MISSING from requirements.lock: %s==%s (resolved from requirements.txt)' % nv
                for nv in sorted(want - have)]
    problems += ['NOT in the resolved set: %s==%s' % nv for nv in sorted(have - want)]
    try:
        problems += check_closure(locked, lambda n, v: meta.get((n, v)))
    except Exception as e:  # a requirement string packaging cannot read
        print('could not judge the dependency metadata: %s: %s' % (type(e).__name__, e))
        sys.exit(3)
    return problems, len(have)


def main():
    if '--check' in sys.argv:
        # One policy for both entry points; the gate calls --check-set below,
        # never --check, so this cannot recurse. Optional non-target wheels
        # must not make --check stricter than the gate.
        gate = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            'check-requirements-lock.sh')
        env = dict(os.environ, PYTHON=sys.executable)
        sys.exit(subprocess.run(['bash', gate, '--root', ROOT], env=env).returncode)
    if '--check-set' in sys.argv:
        problems, n = check_set()
        for p in problems:
            print(p)
        if problems:
            sys.exit(1)
        # The gate reads THIS line, and the count in it (round 11, TM-RL-005).
        print('requirements.lock covers the resolved set (%d packages)' % n)
        return
    data, probs = lock_bytes(render(resolve()))
    if probs:
        for e in probs:
            print('REFUSED: %s' % e)
        sys.exit(1)
    open(LOCK, 'wb').write(data)
    print('wrote %s' % LOCK)


if __name__ == '__main__':
    main()
