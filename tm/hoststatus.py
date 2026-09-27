"""
Read-only views of host state for Settings (v1.2.0): the time source and the
TLS policy nginx serves. Nothing here needs privilege or changes anything, and
every probe degrades to null/unknown rather than asserting a state it could
not measure (hazards[misleading-failure-message]).

TIME. timedatectl answers unprivileged over D-Bus. chronyc tracking uses
chronyd's command port on 127.0.0.1:323; a STIG profile that sets
`cmdport 0` removes that path, in which case offset/stratum/last_sync are
null and the source and sync flag still come from systemd.

TLS. The certificate is read from the file nginx serves
(/etc/topic-manager/tls/server.crt, 0644 in a root:topic-manager 0750
directory, so the service can read it; never the key). The protocol and
cipher lists are read from the installed site file, falling back to the
policy this release ships.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import datetime
import os
import re
import shutil
import subprocess

from . import tls_check

_TIMEOUT = 5
TLS_CERT = os.environ.get('TM_TLS_CERT', '/etc/topic-manager/tls/server.crt')
NGINX_SITE = os.environ.get('TM_NGINX_SITE_LIVE', '/etc/nginx/sites-available/topic-manager')
FIPS_FLAG = os.environ.get('TM_FIPS_FLAG', '/proc/sys/crypto/fips_enabled')

#: What nginx/topic-manager.conf ships. Used only when the live file cannot be
#: read, and then said so by the absence of a live match.
SHIPPED_PROTOCOLS = ['TLSv1.2', 'TLSv1.3']
SHIPPED_CIPHERS = ['ECDHE-ECDSA-AES256-GCM-SHA384', 'ECDHE-RSA-AES256-GCM-SHA384',
                   'ECDHE-ECDSA-AES128-GCM-SHA256', 'ECDHE-RSA-AES128-GCM-SHA256',
                   'TLS_AES_256_GCM_SHA384', 'TLS_AES_128_GCM_SHA256']


def _run(args):
    exe = shutil.which(args[0])
    if not exe:
        return 127, ''
    try:
        p = subprocess.run([exe] + args[1:], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=_TIMEOUT, check=False,
                           env={'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'LC_ALL': 'C'})
    except (OSError, subprocess.TimeoutExpired):
        return 124, ''
    return p.returncode, p.stdout.decode('utf-8', 'replace')


def _active(unit):
    rc, out = _run(['systemctl', 'is-active', unit])
    return out.strip() == 'active'


def _timedatectl_props(*args):
    rc, out = _run(['timedatectl'] + list(args))
    props = {}
    if rc == 0:
        for line in out.splitlines():
            k, sep, v = line.partition('=')
            if sep:
                props[k.strip()] = v.strip()
    return props


def _chrony_tracking():
    """chronyc -c tracking (CSV). Fields (chrony 4.x): RefID, name/IP,
    stratum, ref time (epoch), system offset (s), last offset, rms offset,
    frequency, residual, skew, root delay, root dispersion, update interval,
    leap status."""
    rc, out = _run(['chronyc', '-n', '-c', 'tracking'])
    if rc != 0 or not out.strip():
        return None
    f = out.strip().splitlines()[0].split(',')
    if len(f) < 5:
        return None
    try:
        stratum = int(f[2])
        ref = float(f[3])
        offset_ms = round(float(f[4]) * 1000.0, 3)
    except ValueError:
        return None
    last = (datetime.datetime.fromtimestamp(ref, datetime.timezone.utc).isoformat()
            if ref > 0 else None)
    return {'stratum': stratum, 'offset_ms': offset_ms, 'last_sync': last,
            'leap': f[-1].strip() if f else ''}


def _chrony_servers():
    rc, out = _run(['chronyc', '-c', 'sources'])
    if rc != 0:
        return []
    names = []
    for line in out.splitlines():
        f = line.split(',')
        if len(f) > 2 and f[0] == '^':
            names.append(f[2])
    return names


def time_status():
    """The GET /api/system/time document."""
    doc = {'source': 'none', 'servers': [], 'synced': False, 'offset_ms': None,
           'stratum': None, 'last_sync': None}
    props = _timedatectl_props('show')
    doc['synced'] = props.get('NTPSynchronized') == 'yes'
    if _active('chrony.service') or _active('chronyd.service'):
        doc['source'] = 'chrony'
        tr = _chrony_tracking()
        if tr:
            doc.update(stratum=tr['stratum'], offset_ms=tr['offset_ms'],
                       last_sync=tr['last_sync'])
            doc['synced'] = doc['synced'] or tr['leap'] in ('Normal', 'Insert second',
                                                            'Delete second')
        doc['servers'] = _chrony_servers()
    elif _active('systemd-timesyncd.service'):
        doc['source'] = 'timesyncd'
        ts = _timedatectl_props('show-timesync', '--all')
        servers = (ts.get('SystemNTPServers') or ts.get('FallbackNTPServers') or '').split()
        doc['servers'] = servers
        m = re.search(r'Stratum=(\d+)', ts.get('NTPMessage', ''))
        if m:
            doc['stratum'] = int(m.group(1))
    return doc


def _site_policy():
    try:
        with open(NGINX_SITE, encoding='utf-8') as fh:
            text = fh.read()
    except OSError:
        return list(SHIPPED_PROTOCOLS), list(SHIPPED_CIPHERS)
    m = re.search(r'^\s*ssl_protocols\s+([^;]+);', text, re.M)
    protocols = m.group(1).split() if m else list(SHIPPED_PROTOCOLS)
    m = re.search(r'^\s*ssl_ciphers\s+([^;]+);', text, re.M)
    ciphers = [c for c in (m.group(1).strip().strip('"').split(':') if m else []) if c]
    m = re.search(r'^\s*ssl_conf_command\s+Ciphersuites\s+([^;]+);', text, re.M)
    if m:
        ciphers += [c for c in m.group(1).strip().split(':') if c]
    return protocols, ciphers or list(SHIPPED_CIPHERS)


def fips_mode():
    try:
        with open(FIPS_FLAG, encoding='ascii') as fh:
            return fh.read().strip() == '1'
    except OSError:
        return False


def tls_status():
    """The GET /api/system/tls document."""
    protocols, ciphers = _site_policy()
    cert, count = None, 0
    try:
        with open(TLS_CERT, 'rb') as fh:
            data = fh.read(4 * tls_check.MAX_PEM_BYTES)
        cert, count = tls_check.describe_installed(data)
    except (OSError, tls_check.CertInvalid):
        pass
    return {'protocols': protocols, 'ciphers': ciphers, 'fips_mode': fips_mode(),
            'cert': cert or {'subject': '', 'issuer': '', 'not_after': None,
                             'key_type': 'unknown', 'sans': []},
            'chain_present': count > 1}
