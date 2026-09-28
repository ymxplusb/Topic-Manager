"""Characterisation probe for tm/auth.py (v1.1.1).

Drives the REAL validate_credentials() and missing_ldap_keys() through every
branch of the sign-in path against a scripted stand-in directory, and prints
one transcript: the return value of each scenario plus every bind, search and
unbind the code performed, in order. t20 holds the transcript to
tests/lib/auth_probe.expected byte for byte.

It exists because v1.1.1 refactors validate_credentials() and
missing_ldap_keys() (Sonar S3776/S1871) and nothing else drove the bind
sequence: the service bind, the second bind as the user, the group check and
the returned user record were untested. The transcript was recorded on the
v1.1.0 code BEFORE the refactor, so a refactor that changes any observable
step (a bind as the wrong principal, a skipped unbind, a different message)
fails here.

Only ldap3's Server, Connection and Tls are replaced; the exception classes
are ldap3's own, so the except clauses are exercised for real.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import logging
import sys

from ldap3.core.exceptions import LDAPBindError, LDAPSocketOpenError

from tm import auth

logging.disable(logging.CRITICAL)

CALLS = []


class Attr:
    """An ldap3 entry attribute: str() is the value, falsy when empty."""
    def __init__(self, values):
        self.values = list(values)

    def __bool__(self):
        return bool(self.values)

    def __str__(self):
        return str(self.values[0]) if self.values else ''


class Entry:
    def __init__(self, dn=None, member_of=(), display=None, mail=None):
        self.distinguishedName = Attr([dn] if dn else [])
        self.memberOf = Attr(member_of)
        self.displayName = Attr([display] if display else [])
        self.mail = Attr([mail] if mail else [])


# The stand-in directory: principal -> password, and sAMAccountName -> entry.
PASSWORDS = {
    'CN=svc,DC=example,DC=org': 'svc-pw',
    'alice@example.org': 'alice-pw',
    'bob@example.org': 'bob-pw',
    'carol@example.org': 'carol-pw',
    'dave@example.org': 'dave-pw',     # binds, but has no directory entry
    'a*(b)@example.org': 'odd-pw',
}
ENTRIES = {
    'alice': Entry(dn='CN=Alice,DC=example,DC=org',
                   member_of=['CN=Kafka-Admins,CN=Users,DC=example,DC=org',
                              'CN=Staff,DC=example,DC=org'],
                   display='Alice A', mail='alice@example.org'),
    'bob': Entry(dn='CN=Bob,DC=example,DC=org', member_of=['CN=Staff,DC=example,DC=org'],
                 display='Bob B', mail='bob@example.org'),
    'carol': Entry(),     # no dn, no groups, no display name, no mail
    'a\\2a\\28b\\29': Entry(dn='CN=Odd,DC=example,DC=org', display='Odd'),
}
# A principal whose bind fails with a transport error, not a bad password.
BROKEN = {'down@example.org'}


class FakeTls:
    def __init__(self, validate=None, ca_certs_file=None):
        CALLS.append('tls validate=%s ca=%s' % (validate, ca_certs_file))


class FakeServer:
    def __init__(self, url, get_info=None, tls=None, use_ssl=None):
        CALLS.append('server %s use_ssl=%s tls=%s' % (url, use_ssl, type(tls).__name__))


class FakeConnection:
    def __init__(self, server, user=None, password=None, authentication=None, auto_bind=None):
        CALLS.append('bind %s auth=%s auto_bind=%s' % (user, authentication, auto_bind))
        if user in BROKEN:
            raise LDAPSocketOpenError('socket unreachable')
        if PASSWORDS.get(user) != password:
            raise LDAPBindError('invalidCredentials')
        self.user = user
        self.entries = []

    def search(self, search_base=None, search_filter=None, attributes=None):
        CALLS.append('search %s %s %s' % (search_base, search_filter, ','.join(attributes)))
        sam = search_filter[len('(sAMAccountName='):-1]
        self.entries = [ENTRIES[sam]] if sam in ENTRIES else []

    def unbind(self):
        CALLS.append('unbind %s' % self.user)


auth.Tls = FakeTls
auth.Server = FakeServer
auth.Connection = FakeConnection

GROUP = 'CN=Kafka-Admins,CN=Users,DC=example,DC=org'


def cfg(**over):
    a = {'ldap_server': 'ldaps://dc.example.org:636',
         'ldap_base_dn': 'DC=example,DC=org',
         'ldap_domain': 'example.org'}
    a.update(over)
    return {'auth': {k: v for k, v in a.items() if v is not None}}


SERVICE = {'ldap_bind_dn': 'CN=svc,DC=example,DC=org', 'ldap_bind_password': 'svc-pw'}

SCENARIOS = [
    ('direct-ok-no-group', cfg(), 'alice', 'alice-pw'),
    ('direct-ok-group-member', cfg(required_group=GROUP), 'alice', 'alice-pw'),
    ('direct-group-case-insensitive', cfg(required_group=GROUP.upper()), 'alice', 'alice-pw'),
    ('direct-not-a-member', cfg(required_group=GROUP), 'bob', 'bob-pw'),
    ('direct-wrong-password', cfg(), 'alice', 'nope'),
    ('direct-transport-error', cfg(), 'down', 'x'),
    ('direct-user-not-found', cfg(), 'ghost', 'x'),
    ('direct-bound-but-not-found', cfg(), 'dave', 'dave-pw'),
    ('direct-empty-attributes', cfg(), 'carol', 'carol-pw'),
    ('direct-empty-attributes-group', cfg(required_group=GROUP), 'carol', 'carol-pw'),
    ('netbios-form', cfg(), 'EXAMPLE\\alice', 'alice-pw'),
    ('upn-form', cfg(), 'alice@elsewhere.org', 'alice-pw'),
    ('filter-escaped', cfg(), 'a*(b)', 'odd-pw'),
    ('ca-cert-configured', cfg(ldap_ca_cert='/etc/ssl/ad-ca.pem'), 'alice', 'alice-pw'),
    ('service-ok-group-member', cfg(required_group=GROUP, **SERVICE), 'alice', 'alice-pw'),
    ('service-user-wrong-password', cfg(**SERVICE), 'alice', 'nope'),
    ('service-user-wrong-password-not-member', cfg(required_group=GROUP, **SERVICE), 'bob', 'nope'),
    ('service-not-a-member', cfg(required_group=GROUP, **SERVICE), 'bob', 'bob-pw'),
    ('service-bind-fails', cfg(ldap_bind_dn='CN=svc,DC=example,DC=org',
                               ldap_bind_password='stale'), 'alice', 'alice-pw'),
    ('service-user-not-found', cfg(**SERVICE), 'ghost', 'x'),
    ('service-placeholder-password', cfg(ldap_bind_dn='CN=svc,DC=example,DC=org',
                                         ldap_bind_password='CHANGE_ME_PLEASE'), 'alice', 'alice-pw'),
    ('service-dn-without-password', cfg(ldap_bind_dn='CN=svc,DC=example,DC=org'), 'alice', 'alice-pw'),
    ('service-password-without-dn', cfg(ldap_bind_password='svc-pw'), 'alice', 'alice-pw'),
    ('group-empty-string', cfg(required_group='', **SERVICE), 'bob', 'bob-pw'),
    ('not-configured', cfg(ldap_server=None), 'alice', 'alice-pw'),
    ('plain-ldap-refused', cfg(ldap_server='ldap://dc.example.org:389'), 'alice', 'alice-pw'),
    ('auth-not-a-mapping', {'auth': 'text'}, 'alice', 'alice-pw'),
    ('auth-none', {'auth': None}, 'alice', 'alice-pw'),
]

MISSING = [
    ('complete', cfg()),
    ('server-placeholder', cfg(ldap_server='<ldaps-url>')),
    ('server-plain-ldap', cfg(ldap_server='ldap://dc.example.org')),
    ('server-padded', cfg(ldap_server='  ldaps://dc.example.org  ')),
    ('server-no-host', cfg(ldap_server='ldaps://')),
    ('server-not-a-string', cfg(ldap_server=636)),
    ('base-dn-placeholder', cfg(ldap_base_dn='<base-dn>')),
    ('base-dn-half-bracket', cfg(ldap_base_dn='DC=<example,DC=org')),
    ('domain-blank', cfg(ldap_domain='   ')),
    ('domain-not-ldaps-is-fine', cfg(ldap_domain='ldap://x')),
    ('all-absent', {'auth': {}}),
    ('no-auth', {}),
    ('cfg-none', None),
    ('auth-list', {'auth': ['x']}),
]


def main():
    for name, c, user, pw in SCENARIOS:
        del CALLS[:]
        result = auth.validate_credentials(c, user, pw)
        print('== %s' % name)
        for call in CALLS:
            print('   %s' % call)
        print('   -> %r' % (result,))
    for name, c in MISSING:
        print('missing %s -> %r' % (name, auth.missing_ldap_keys(c)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
