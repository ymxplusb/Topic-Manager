import logging
import re
import ssl
from urllib.parse import urlsplit
from ldap3 import Server, Connection, ALL, SIMPLE, Tls
from ldap3.core.exceptions import LDAPException, LDAPBindError

log = logging.getLogger(__name__)

_BIND_PW_PLACEHOLDER = 'CHANGE_ME'

#: The keys sign-in cannot work without. required_group is deliberately NOT
#: here: an empty value is a documented choice (any directory account), where
#: an empty server or base DN can only be a mistake.
REQUIRED_LDAP_KEYS = ('ldap_server', 'ldap_base_dn', 'ldap_domain')


#: What sign-in says to an UNAUTHENTICATED client when the server is not
#: configured. The detail (which key) goes to the server log only.
SIGN_IN_UNAVAILABLE = 'Sign-in is unavailable. Contact the administrator.'


def is_ldaps_url(url):
    """True only for an ldaps:// URL with a host. The scheme is PARSED and
    compared exactly (case-insensitively, as URL schemes are); it used to be a
    substring test, so 'ldap://x/?ldaps' or 'xldaps://' counted as TLS."""
    try:
        parts = urlsplit(str(url).strip())
        return parts.scheme.lower() == 'ldaps' and bool(parts.hostname)
    except ValueError:
        return False


def missing_ldap_keys(cfg):
    """The REQUIRED_LDAP_KEYS that are absent, blank, still an unfilled
    <placeholder>, or — for ldap_server — not an ldaps:// URL. Empty list when
    sign-in is configured. install.sh and upgrade-full.sh carry the same rule
    (ldap_config_missing) and t20 holds all three to the same answers."""
    auth_cfg = (cfg or {}).get('auth') or {}
    if not isinstance(auth_cfg, dict):
        auth_cfg = {}
    return [k for k in REQUIRED_LDAP_KEYS
            if not _ldap_key_is_set(k, str(auth_cfg.get(k) or '').strip())]


def _ldap_key_is_set(key, value):
    """One required key's verdict: a value, not a <placeholder>, and for
    ldap_server an ldaps:// URL."""
    if not value or ('<' in value and '>' in value):
        return False
    return key != 'ldap_server' or is_ldaps_url(value)


def _build_tls(cfg):
    # Only ldaps:// reaches here (missing_ldap_keys refuses anything else), so
    # certificate validation is always on.
    ca_file = (cfg.get('auth', {}) or {}).get('ldap_ca_cert') or None
    return Tls(validate=ssl.CERT_REQUIRED, ca_certs_file=ca_file)


def validate_credentials(cfg, username, password):
    """
    Bind to AD with user credentials, verify group membership.
    Returns (True, user_dict) or (False, error_string).

    Uses two-phase bind when ldap_bind_dn/ldap_bind_password are configured:
      1. Service-account bind for directory search.
      2. Re-bind with the user's UPN to verify the supplied password.
    Falls back to direct user-bind when service credentials are absent.
    """
    auth_cfg = _auth_section(cfg)
    # v1.1.0: NO built-in directory. These three used to default to one
    # particular site's domain controller, base DN and domain, so a config that
    # omitted them authenticated against a directory nobody configured. A
    # missing key is now a refusal that names the key; install.sh and the
    # upgrade refuse to proceed without them, so this is the last line.
    missing = missing_ldap_keys(cfg)
    if missing:
        # The detail is for the administrator, in the server log. The client
        # is unauthenticated and learns only that sign-in is unavailable.
        log.error('Sign-in refused: config.yaml auth.%s missing, a <placeholder>, '
                  'or (ldap_server) not an ldaps:// URL', ', auth.'.join(missing))
        return False, SIGN_IN_UNAVAILABLE
    ldap_url = auth_cfg['ldap_server']
    base_dn = auth_cfg['ldap_base_dn']
    required_group_dn = auth_cfg.get('required_group', '')
    domain = auth_cfg['ldap_domain']

    sam = _normalise_sam(username)
    upn = f'{sam}@{domain}'
    use_service_bind = _uses_service_bind(auth_cfg)

    tls = _build_tls(cfg)
    server = Server(ldap_url, get_info=ALL, tls=tls, use_ssl=True)

    if use_service_bind:
        ok, err, conn = _ldap_bind(server, auth_cfg['ldap_bind_dn'],
                                   auth_cfg['ldap_bind_password'])
    else:
        ok, err, conn = _ldap_bind(server, upn, password)
    if not ok:
        return False, err

    entry, err = _ldap_search_user(conn, base_dn, sam)
    if entry is None:
        return False, err

    member_of = _member_of(entry)

    if use_service_bind:
        # Phase 2: the service account found the user; only a bind AS the
        # user proves the password.
        ok, err = _verify_user_password(server, upn, password)
        if not ok:
            return False, err

    if required_group_dn and required_group_dn.lower() not in member_of:
        return False, f'Not a member of required group: {required_group_dn}'

    return True, _user_record(entry, sam, upn)


# ── the periodic group re-check (v1.3.0, NGNX-APP-003330, DQ8) ────────────────
# A session used to survive its user's removal from required_group (or the
# account's deletion) until its idle timeout: the group was read at sign-in
# and never again. tm/routes.require_auth now asks this every
# GROUP_RECHECK_MINUTES per session. The verdicts:
#   member       still in required_group (or no group is required)
#   not_member   no longer in it                -> the session is ended
#   not_found    the account is gone            -> the session is ended
#   unavailable  the directory could not answer -> reads continue, every
#                write is refused until it does (James 2026-10-02)
#   unsupported  no service account is configured, so there is nothing to
#                search with (the user's password is not kept). Reported on
#                the compliance page; sessions still end at the absolute
#                lifetime.
GROUP_RECHECK_MINUTES = 15
RECHECK_TIMEOUT_S = 5
RECHECK_VERDICTS = ('member', 'not_member', 'not_found', 'unavailable', 'unsupported')


def recheck_supported(cfg):
    return _uses_service_bind(_auth_section(cfg)) and not missing_ldap_keys(cfg)


def check_membership(cfg, username):
    """(verdict, detail) for `username` now, by the service account. Never
    raises: anything unexpected is 'unavailable', which refuses writes."""
    if not recheck_supported(cfg):
        return 'unsupported', 'no LDAP service account (auth.ldap_bind_dn) is configured'
    auth_cfg = _auth_section(cfg)
    try:
        server = Server(auth_cfg['ldap_server'], get_info=None, tls=_build_tls(cfg), use_ssl=True,
                        connect_timeout=RECHECK_TIMEOUT_S)
        ok, err, conn = _ldap_bind(server, auth_cfg['ldap_bind_dn'],
                                   auth_cfg['ldap_bind_password'], RECHECK_TIMEOUT_S)
        if not ok:
            return 'unavailable', 'service bind failed: %s' % err
        entry, err = _ldap_search_user(conn, auth_cfg['ldap_base_dn'], _normalise_sam(username))
    except Exception as exc:          # a socket error mid-search, a TLS failure
        return 'unavailable', '%s: %s' % (type(exc).__name__, str(exc)[:200])
    if entry is None:
        return 'not_found', 'the account is no longer in the directory'
    group = auth_cfg.get('required_group', '')
    if group and group.lower() not in _member_of(entry):
        return 'not_member', 'no longer a member of the required group'
    return 'member', ''


def _auth_section(cfg):
    auth_cfg = cfg.get('auth', {}) or {}
    return auth_cfg if isinstance(auth_cfg, dict) else {}


def _uses_service_bind(auth_cfg):
    """A configured bind DN AND a bind password that is not the placeholder.
    Anything less falls back to binding directly as the user."""
    bind_dn = auth_cfg.get('ldap_bind_dn', '')
    bind_pw = auth_cfg.get('ldap_bind_password', '')
    return bool(bind_dn and bind_pw and _BIND_PW_PLACEHOLDER not in bind_pw)


def _verify_user_password(server, upn, password):
    ok, err, user_conn = _ldap_bind(server, upn, password)
    if ok:
        user_conn.unbind()
    return ok, err


def _member_of(entry):
    """The entry's group DNs, lower-cased for a case-insensitive match."""
    return [str(g).lower() for g in (entry.memberOf.values if entry.memberOf else [])]


def _user_record(entry, sam, upn):
    return {
        'username': sam,
        'display_name': str(entry.displayName) if entry.displayName else sam,
        'email': str(entry.mail) if entry.mail else '',
        'upn': upn,
    }


def _normalise_sam(username):
    """The sAMAccountName part of what was typed (DOMAIN\\user, user@domain or
    user), LOWER-CASED. Active Directory matches sAMAccountName and the UPN
    bind case-insensitively, so "Alice", "alice" and "ALICE" are one account;
    they must be one session identity too, or each spelling gets its own
    concurrent-session quota (adversary F-04, sec-review TM-SEC-004).
    str.lower(), not casefold(): casefold() maps "ß" to "ss", which would
    bind as a DIFFERENT account."""
    if '\\' in username:
        username = username.split('\\', 1)[1]
    elif '@' in username:
        username = username.split('@', 1)[0]
    return username.lower()


def _ldap_bind(server, user, password, receive_timeout=None):
    # A bounded read only where one is asked for (the re-check, which runs
    # inside a request); sign-in keeps ldap3's own defaults.
    extra = {'receive_timeout': receive_timeout} if receive_timeout else {}
    try:
        conn = Connection(server, user=user, password=password,
                          authentication=SIMPLE, auto_bind=True, **extra)
        return True, None, conn
    except LDAPBindError:
        return False, 'Invalid credentials', None
    except LDAPException as exc:
        return False, f'LDAP error: {exc}', None


def _ldap_search_user(conn, base_dn, sam):
    conn.search(
        search_base=base_dn,
        search_filter=f'(sAMAccountName={_ldap_escape(sam)})',
        attributes=['memberOf', 'displayName', 'sAMAccountName', 'mail', 'distinguishedName'],
    )
    if not conn.entries:
        conn.unbind()
        return None, 'User not found in directory'
    entry = conn.entries[0]
    conn.unbind()
    return entry, None


def _ldap_escape(value):
    """Escape special characters in LDAP filter values."""
    return re.sub(r'([\\*\(\)\x00])', lambda m: f'\\{ord(m.group(1)):02x}', value)
