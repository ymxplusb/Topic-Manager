"""
The administrator-only settings added in v1.2.0: their defaults and the ONE
validator each value must pass before it is stored.

Every value lives in app_settings as a string. The table here is the contract
(.work/V120-API-CONTRACT.md) made executable: PUT /api/settings refuses a value
that fails its validator, and the root apply helper
(install/libexec/tm-apply) re-validates the same values against its OWN copy of
these rules, because it runs as root and must not trust anything the service
account wrote.

None of these keys is public. They are joined to the display keys in
tm/routes.py as a NEW set (`_ALL_KEYS = _PUBLIC_KEYS | ADMIN_KEYS`), never by
adding to `_PUBLIC_KEYS`: that set is what the UNAUTHENTICATED
/api/settings/public serves, and one `.add()` on an alias of it would publish
the syslog collector and the NTP servers to anyone who can reach the login
page.

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import ipaddress
import logging
import re

log = logging.getLogger(__name__)

#: Contract defaults. A fresh install behaves exactly as this table says
#: without a single row in app_settings.
ADMIN_DEFAULTS = {
    'syslog_enabled':          'false',
    'syslog_host':             '',
    'syslog_port':             '6514',
    'syslog_protocol':         'tls',
    'syslog_app_id':           'topic-manager',
    'ntp_servers':             '',
    'session_max_concurrent':  '3',
    'ratelimit_login_per_min': '10',
    'ratelimit_login_burst':   '5',
    'ratelimit_api_per_min':   '300',
    'ratelimit_api_burst':     '100',
    'ratelimit_conn_per_ip':   '20',
    'audit_retention_days':    '365',
    'audit_max_rows':          '5000000',
    'audit_warn_pct':          '75',
    'http_redirect_enabled':   'true',
}

ADMIN_KEYS = frozenset(ADMIN_DEFAULTS)

#: Which keys each "Apply to host" domain carries to the root helper. The
#: helper is given these and nothing else.
DOMAIN_KEYS = {
    'syslog': ('syslog_enabled', 'syslog_host', 'syslog_port',
               'syslog_protocol', 'syslog_app_id'),
    'time':   ('ntp_servers',),
    'nginx':  ('ratelimit_login_per_min', 'ratelimit_login_burst',
               'ratelimit_api_per_min', 'ratelimit_api_burst',
               'ratelimit_conn_per_ip', 'http_redirect_enabled'),
}

_INT_RANGES = {
    'syslog_port':             (1, 65535),
    'session_max_concurrent':  (0, 50),
    'ratelimit_login_per_min': (1, 600),
    'ratelimit_login_burst':   (0, 100),
    'ratelimit_api_per_min':   (10, 6000),
    'ratelimit_api_burst':     (0, 1000),
    'ratelimit_conn_per_ip':   (1, 500),
    'audit_retention_days':    (30, 3650),
    'audit_max_rows':          (10000, 50000000),
    'audit_warn_pct':          (50, 95),
}

_BOOL_KEYS = ('syslog_enabled', 'http_redirect_enabled')
SYSLOG_PROTOCOLS = ('udp', 'tcp', 'tls')

_HOSTNAME_RE = re.compile(r'^[A-Za-z0-9.-]{1,253}$')
_APP_ID_RE = re.compile(r'^[A-Za-z0-9._-]{1,48}$')
_INT_RE = re.compile(r'^[0-9]{1,9}$')
MAX_NTP_SERVERS = 5


class InvalidSetting(ValueError):
    """A value that failed its validator. `field` names the key."""
    def __init__(self, field, reason):
        super().__init__('%s: %s' % (field, reason))
        self.field = field
        self.reason = reason


def valid_host(value):
    """A host name or an IP literal, and nothing a config file could read as
    syntax. The contract's charset (letters, digits, '.', '-') for a name; an
    IPv4/IPv6 literal through ipaddress. A leading '-' or '.' is refused on
    top of the contract: no host name starts with either, and '-x' reads as an
    option to more than one tool the root helper runs."""
    if not isinstance(value, str) or not value:
        return False
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        pass
    return bool(_HOSTNAME_RE.match(value)) and value[0] not in '-.'


def _as_text(key, value):
    # JSON true/false and numbers are accepted and stored in the table's
    # string form; anything else that is not a string is refused.
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return value.strip()
    raise InvalidSetting(key, 'must be a string')


def normalise(key, value):
    """Return the stored form of `value` for `key`, or raise InvalidSetting.

    This is the only gate between a PUT body and app_settings for the admin
    keys, and the reason strings are shown to the operator as-is.
    """
    if key not in ADMIN_KEYS:
        raise InvalidSetting(key, 'not an administrator setting')
    text = _as_text(key, value)
    validator = _validator(key)
    if validator is None:
        raise InvalidSetting(key, 'no validator')      # unreachable: every key has one
    return validator(key, text)


def _validator(key):
    """The one validator for an admin key, or None (refused, never stored
    unchecked)."""
    if key in _BOOL_KEYS:
        return _norm_bool
    if key in _INT_RANGES:
        return _norm_int
    return _KEY_VALIDATORS.get(key)


def _norm_bool(key, text):
    if text.lower() not in ('true', 'false'):
        raise InvalidSetting(key, 'must be "true" or "false"')
    return text.lower()


def _norm_int(key, text):
    lo, hi = _INT_RANGES[key]
    if not _INT_RE.match(text):
        raise InvalidSetting(key, 'must be a whole number from %d to %d' % (lo, hi))
    n = int(text)
    if not lo <= n <= hi:
        raise InvalidSetting(key, 'must be from %d to %d' % (lo, hi))
    return str(n)


def _norm_protocol(key, text):
    if text.lower() not in SYSLOG_PROTOCOLS:
        raise InvalidSetting(key, 'must be one of udp, tcp, tls')
    return text.lower()


def _norm_app_id(key, text):
    if not _APP_ID_RE.match(text):
        raise InvalidSetting(key, '1-48 characters from A-Z a-z 0-9 . _ -')
    return text


def _norm_host(key, text):
    if text == '':
        return ''
    if not valid_host(text):
        raise InvalidSetting(key, 'must be a host name (A-Z a-z 0-9 . -, '
                                  'up to 253 characters) or an IP address')
    return text


def _norm_ntp(key, text):
    if text == '':
        return ''
    servers = [s.strip() for s in text.split(',')]
    if len(servers) > MAX_NTP_SERVERS:
        raise InvalidSetting(key, 'at most %d servers' % MAX_NTP_SERVERS)
    for s in servers:
        if not valid_host(s):
            raise InvalidSetting(key, '%r is not a host name or IP address'
                                 % s[:64])
    if len(set(s.lower() for s in servers)) != len(servers):
        raise InvalidSetting(key, 'a server is listed twice')
    return ','.join(servers)


_KEY_VALIDATORS = {
    'syslog_protocol': _norm_protocol,
    'syslog_app_id':   _norm_app_id,
    'syslog_host':     _norm_host,
    'ntp_servers':     _norm_ntp,
}


def int_setting(values, key):
    """An integer admin setting from a dict of stored strings, falling back to
    the contract default when the stored value is missing or unreadable."""
    raw = values.get(key, ADMIN_DEFAULTS[key])
    try:
        return int(normalise(key, raw))
    except InvalidSetting:
        log.warning('app_settings %s=%r is not valid; using the default %s',
                    key, raw, ADMIN_DEFAULTS[key])
        return int(ADMIN_DEFAULTS[key])


def read_admin(db, keys=None):
    """Stored values for `keys` (default: every admin key), defaults filled in."""
    keys = list(keys or ADMIN_KEYS)
    rows = db.execute(
        'SELECT key, value FROM app_settings WHERE key IN (%s)' % ','.join('?' * len(keys)),
        keys).fetchall()
    out = {k: ADMIN_DEFAULTS[k] for k in keys}
    out.update({r[0]: r[1] for r in rows})
    return out


def check_domain(domain, values):
    """Cross-field rules an apply must satisfy. Returns a list of problems
    (empty = ok). The per-key rules already held when the values were saved;
    these are the ones that need two keys at once."""
    problems = []
    for k in DOMAIN_KEYS.get(domain, ()):
        try:
            normalise(k, values.get(k, ADMIN_DEFAULTS[k]))
        except InvalidSetting as exc:
            problems.append(str(exc))
    if domain == 'syslog' and values.get('syslog_enabled') == 'true' \
            and not values.get('syslog_host'):
        problems.append('syslog_host: required when remote syslog is enabled')
    return problems


# ── session limit precedence (owner ruling 2026-09-26) ────────────────────
# Settings wins. config.yaml session.max_concurrent SEEDS the setting the
# first time the service starts on a database that has no value for it, and is
# ignored after that; a disagreement is logged at every start so an operator
# who edits config.yaml is told why nothing changed. With neither, 3.

SESSION_KEY = 'session_max_concurrent'


def seed_session_limit(cfg, db):
    """Seed session_max_concurrent from config.yaml if it has never been set.
    Idempotent and race-free across workers (INSERT OR IGNORE). Returns the
    value in force."""
    raw = (cfg.get('session') or {}).get('max_concurrent', None)
    seed = ADMIN_DEFAULTS[SESSION_KEY]
    if raw is not None:
        try:
            seed = normalise(SESSION_KEY, raw)
        except InvalidSetting:
            log.warning('config.yaml session.max_concurrent=%r is not 0-50; '
                        'seeding the default %s instead', raw, seed)
    db.execute('INSERT OR IGNORE INTO app_settings (key, value) VALUES (?, ?)',
               (SESSION_KEY, seed))
    db.commit()
    current = read_admin(db, [SESSION_KEY])[SESSION_KEY]
    if raw is not None and str(raw).strip() != current:
        log.warning('config.yaml session.max_concurrent is %r but Settings holds %s. '
                    'Settings wins: config.yaml only seeds this value on first start. '
                    'Change it in Settings > Security > Sessions.', raw, current)
    return current
