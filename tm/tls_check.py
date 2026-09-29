"""
Server certificate validation for Settings > Security > TLS & certificate
(v1.2.0; NGNX-APP-001900/001960).

STANDARD LIBRARY ONLY, and the openssl COMMAND LINE for every cryptographic
question. Two reasons:
  * on a FIPS host the host's openssl binary runs through the host's FIPS
    provider, while the `cryptography` wheel bundles its OWN OpenSSL, which is
    not the validated module;
  * this file is ALSO installed, root-owned, beside the root apply helper
    (/usr/libexec/topic-manager/lib/tm_tls_check.py), which re-runs exactly
    these checks before it installs anything. The helper never imports code
    from /opt/topic-manager — that tree belongs to the service account — so
    the shared copy has to be importable with nothing but the stdlib.

THE PRIVATE KEY NEVER TOUCHES A FILESYSTEM HERE. PEM material is handed to
openssl through anonymous memory files (memfd_create) passed as /dev/fd/N, so
no key byte is written to /tmp, the data directory or anywhere else by these
checks. memfd_create is Linux-only; elsewhere validate() refuses rather than
fall back to a temp file.

Accepted: EC P-256 / P-384 and RSA 2048 / 3072 / 4096, signed with SHA-2,
currently valid, the key matching the certificate, the key unencrypted, and —
when a chain is supplied — the leaf verifying against it for TLS server use.
Refused, each with its own reason: anything else, including RSA-1024,
secp256k1, Ed25519 (no matching TLS 1.2 suite in the policy), SHA-1 or MD5
signatures, expired or not-yet-valid certificates, a mismatched pair, an
unverifiable chain and an encrypted key.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import datetime
import ipaddress
import os
import re
import subprocess

MAX_PEM_BYTES = 64 * 1024
ACCEPTED_KEY_TYPES = ('EC P-256', 'EC P-384', 'RSA 2048', 'RSA 3072', 'RSA 4096')
_OPENSSL_TIMEOUT = 20

_CERT_BLOCK = re.compile(
    rb'-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+?-----END CERTIFICATE-----')
_KEY_HEADERS = (b'-----BEGIN PRIVATE KEY-----', b'-----BEGIN EC PRIVATE KEY-----',
                b'-----BEGIN RSA PRIVATE KEY-----')
_CURVES = {'prime256v1': 'P-256', 'secp384r1': 'P-384', 'P-256': 'P-256',
           'P-384': 'P-384'}
_WEAK_SIG = re.compile(r'(sha1|md5|md2|md4)', re.I)


class CertInvalid(ValueError):
    """The upload is refused. str(exc) is the reason shown to the operator."""


def openssl_bin():
    return os.environ.get('TM_OPENSSL', '/usr/bin/openssl')


class _Mem:
    """PEM bytes in an anonymous memory file, readable by a child process as
    /dev/fd/N. Closed (and so gone) on exit."""
    def __init__(self, data, name='pem'):
        if not hasattr(os, 'memfd_create'):
            raise CertInvalid('certificate checks need Linux (memfd_create); '
                              'refusing to write key material to a temporary file')
        self.fd = os.memfd_create('tm-' + name, getattr(os, 'MFD_CLOEXEC', 0))
        os.write(self.fd, data)
        os.lseek(self.fd, 0, os.SEEK_SET)
        self.path = '/dev/fd/%d' % self.fd

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        os.close(self.fd)


def _openssl(args, fds=()):
    """Run openssl. Returns (rc, stdout, stderr) as text; never raises."""
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}
    if os.environ.get('OPENSSL_CONF'):
        env['OPENSSL_CONF'] = os.environ['OPENSSL_CONF']
    try:
        p = subprocess.run([openssl_bin()] + list(args), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           pass_fds=tuple(fds), env=env, timeout=_OPENSSL_TIMEOUT,
                           check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, '', str(exc)
    return p.returncode, p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')


def split_certs(pem):
    """Every CERTIFICATE block in `pem`, in order, as bytes."""
    return [m.group(0) + b'\n' for m in _CERT_BLOCK.finditer(pem or b'')]


def _field(text, label):
    m = re.search(r'^\s*' + re.escape(label) + r'\s*(.+)$', text, re.M)
    return m.group(1).strip() if m else ''


def _safe_word(value):
    """An algorithm or curve NAME as openssl printed it, reduced to the
    characters such names use and bounded, so a reason string can carry the
    name and never anything else from the upload (contract CC-1)."""
    return re.sub(r'[^A-Za-z0-9 ._()-]', '', str(value))[:40]


def key_type_of(cert_text):
    """'EC P-256', 'RSA 2048', ... from `openssl x509 -text`, or a description
    of what it is instead."""
    alg = _field(cert_text, 'Public Key Algorithm:')
    if alg == 'rsaEncryption':
        m = re.search(r'Public-Key:\s*\((\d+) bit\)', cert_text)
        return 'RSA %s' % (m.group(1) if m else '?')
    if alg == 'id-ecPublicKey':
        curve = _field(cert_text, 'NIST CURVE:') or _field(cert_text, 'ASN1 OID:')
        return 'EC %s' % _CURVES.get(curve, curve or '?')
    return alg or 'unknown'


def _parse_date(value):
    # openssl prints e.g. "Sep 26 12:00:00 2026 GMT"
    try:
        return datetime.datetime.strptime(' '.join(value.split()),
                                          '%b %d %H:%M:%S %Y GMT').replace(
            tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


def _cert_info(pem, what):
    with _Mem(pem, 'crt') as m:
        rc, text, _ = _openssl(['x509', '-noout', '-text', '-in', m.path], [m.fd])
        if rc != 0:
            raise CertInvalid('%s does not parse as an X.509 certificate' % what)
        _, dates, _ = _openssl(['x509', '-noout', '-startdate', '-enddate',
                                  '-subject', '-issuer', '-nameopt', 'RFC2253',
                                  '-in', m.path], [m.fd])
        rc3, pub, _ = _openssl(['x509', '-noout', '-pubkey', '-in', m.path], [m.fd])
        rc4, ext, _ = _openssl(['x509', '-noout', '-ext', 'subjectAltName',
                                '-in', m.path], [m.fd])
    info = {'text': text, 'pubkey': pub if rc3 == 0 else ''}
    for line in dates.splitlines():
        k, _, v = line.partition('=')
        info[k.strip()] = v.strip()
    info['sig'] = _field(text, 'Signature Algorithm:')
    info['key_type'] = key_type_of(text)
    info['sans'] = re.findall(r'(?:DNS|IP Address):([^,\s]+)', ext if rc4 == 0 else '')
    return info


def validate(cert_pem, key_pem, chain_pem=None, now=None, server_name=None):
    """Validate an upload. Returns a dict describing the certificate:
    {subject, issuer, not_after, key_type, sans, chain_count, warnings};
    raises CertInvalid with the reason otherwise. The checks run in a fixed
    order, so one upload always gets the same (first) reason.

    `server_name` is the name this server is configured to answer to (the
    root helper reads it from the nginx site). A certificate that does not
    name it is WARNED about, not refused (decision, round 4, sec-review
    TM-SEC-011): an operator may install the certificate for a new name
    before moving DNS and server_name to it, or reach the host by address;
    clients that use the configured name will refuse it, and the warning
    in the apply result says exactly that."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    certs = _checked_upload(cert_pem, key_pem, chain_pem)
    leaf = _cert_info(certs[0], 'the certificate')
    not_after = _checked_leaf(leaf, now)
    _check_key_matches(key_pem, leaf)
    chain, warnings = _checked_chain(chain_pem, certs[0], leaf)
    if server_name and not names_host(leaf['sans'], server_name):
        warnings.append('the certificate does not name this server (%s) in its subject '
                        'alternative names: browsers and clients that reach it by that '
                        'name will refuse it' % _safe_host(server_name))
    return {'subject': leaf.get('subject', ''), 'issuer': leaf.get('issuer', ''),
            'not_after': not_after.isoformat(), 'key_type': leaf['key_type'],
            'sans': leaf['sans'], 'chain_count': len(chain), 'warnings': warnings}


def _checked_upload(cert_pem, key_pem, chain_pem):
    """Size and shape, before openssl sees a byte: returns the one leaf
    certificate's PEM in a list."""
    for label, blob in (('certificate', cert_pem), ('private key', key_pem),
                        ('chain', chain_pem or b'')):
        if len(blob) > MAX_PEM_BYTES:
            raise CertInvalid('the %s is larger than %d bytes' % (label, MAX_PEM_BYTES))
    if not cert_pem or not key_pem:
        raise CertInvalid('both a certificate and a private key are required')

    certs = split_certs(cert_pem)
    if len(certs) != 1:
        raise CertInvalid('the certificate field must hold exactly one PEM certificate '
                          '(found %d); put intermediates in the chain field' % len(certs))
    if b'ENCRYPTED' in key_pem:
        raise CertInvalid('the private key is encrypted; upload it unencrypted '
                          '(it is stored root-only, 0600)')
    if sum(key_pem.count(h) for h in _KEY_HEADERS) != 1:
        raise CertInvalid('the key field must hold exactly one unencrypted PEM private key')
    return certs


def _checked_leaf(leaf, now):
    """Key type, signature and validity of the leaf; returns its notAfter."""
    if leaf['key_type'] not in ACCEPTED_KEY_TYPES:
        raise CertInvalid('unsupported key type: %s (accepted: %s)'
                          % (_safe_word(leaf['key_type']), ', '.join(ACCEPTED_KEY_TYPES)))
    if not leaf['sig'] or _WEAK_SIG.search(leaf['sig']):
        raise CertInvalid('the certificate is signed with %s; SHA-1 and MD5 signatures '
                          'are refused' % (_safe_word(leaf['sig']) or 'an unknown algorithm'))
    not_before = _parse_date(leaf.get('notBefore', ''))
    not_after = _parse_date(leaf.get('notAfter', ''))
    if not_after is None or not_before is None:
        raise CertInvalid('the certificate validity dates could not be read')
    if not_after <= now:
        raise CertInvalid('the certificate expired on %s' % not_after.isoformat())
    if not_before > now:
        raise CertInvalid('the certificate is not valid until %s' % not_before.isoformat())
    return not_after


def _check_key_matches(key_pem, leaf):
    """The private key reads, and its public half is the certificate's."""
    with _Mem(key_pem, 'key') as k:
        rc, keypub, _ = _openssl(['pkey', '-pubout', '-passin', 'pass:', '-in', k.path], [k.fd])
    if rc != 0 or '-----BEGIN PUBLIC KEY-----' not in keypub:
        raise CertInvalid('the private key could not be read (not a PEM key, encrypted, '
                          'or a type this host\'s OpenSSL refuses)')
    if '-----BEGIN PUBLIC KEY-----' not in leaf['pubkey'] or keypub.strip() != leaf['pubkey'].strip():
        raise CertInvalid('the private key does not match the certificate')


def _checked_chain(chain_pem, leaf_pem, leaf):
    """(chain certificates, warnings): every chain signature strong enough and
    the leaf verified against the chain for TLS server use, or a warning that
    there is no chain."""
    warnings = []
    chain = split_certs(chain_pem) if chain_pem else []
    if chain_pem and chain_pem.strip() and not chain:
        raise CertInvalid('the chain field holds no PEM certificate')
    for i, c in enumerate(chain, 1):
        ci = _cert_info(c, 'chain certificate %d' % i)
        self_signed = ci.get('subject') == ci.get('issuer')
        if not self_signed and (not ci['sig'] or _WEAK_SIG.search(ci['sig'])):
            raise CertInvalid('chain certificate %d is signed with %s; SHA-1 and MD5 '
                              'signatures are refused' % (i, _safe_word(ci['sig']) or
                                                          'an unknown algorithm'))
    if chain:
        bundle = b''.join(chain)
        with _Mem(bundle, 'chain') as ch, _Mem(leaf_pem, 'leaf') as lf:
            rc, _, _ = _openssl(['verify', '-partial_chain', '-purpose', 'sslserver',
                                     '-CAfile', ch.path, '-untrusted', ch.path, lf.path],
                                    [ch.fd, lf.fd])
        if rc != 0:
            # A FIXED reason (contract CC-1). openssl's own text names the
            # subject of the certificate that failed, and nothing taken from
            # the upload is ever echoed back.
            raise CertInvalid('the certificate does not verify against the supplied chain '
                              'for TLS server use')
    elif leaf.get('subject') != leaf.get('issuer'):
        warnings.append('no chain was supplied; clients must already trust the issuer')
    else:
        warnings.append('the certificate is self-signed')
    return chain, warnings


def _safe_host(value):
    return re.sub(r'[^A-Za-z0-9.:*-]', '', str(value))[:253]


def _same_name(san, host):
    """RFC 6125: an exact (case-insensitive) match, or ONE wildcard that is
    the whole leftmost label and stands for exactly one label. IP addresses
    compare as addresses (openssl prints IPv6 SANs uncompressed)."""
    try:
        return ipaddress.ip_address(san) == ipaddress.ip_address(host)
    except ValueError:
        pass
    san, host = san.lower().rstrip('.'), host.lower().rstrip('.')
    if san == host:
        return True
    if not san.startswith('*.') or '*' in san[2:]:
        return False
    head, _, tail = host.partition('.')
    return bool(head) and tail == san[2:] and '.' in tail


def names_host(sans, host):
    """True when one of the certificate's subject alternative names covers
    `host`. The subject CN is not consulted: current browsers ignore it."""
    return any(_same_name(s, host) for s in sans or ())


def describe_installed(fullchain_pem):
    """Read-only description of an INSTALLED certificate file (leaf first,
    then any chain) for GET /api/system/tls. Never raises for a bad file; the
    fields say what could be read."""
    certs = split_certs(fullchain_pem)
    if not certs:
        return None, 0
    try:
        info = _cert_info(certs[0], 'the installed certificate')
    except CertInvalid:
        return None, len(certs)
    na = _parse_date(info.get('notAfter', ''))
    return ({'subject': info.get('subject', ''), 'issuer': info.get('issuer', ''),
             'not_after': na.isoformat() if na else None,
             'key_type': info['key_type'], 'sans': info['sans']}, len(certs))
