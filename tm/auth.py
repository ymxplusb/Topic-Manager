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
    out = []
    for k in REQUIRED_LDAP_KEYS:
        v = str(auth_cfg.get(k) or '').strip()
        if not v or ('<' in v and '>' in v):
            out.append(k)
        elif k == 'ldap_server' and not is_ldaps_url(v):
            out.append(k)
    return out


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
    auth_cfg = cfg.get('auth', {}) or {}
    if not isinstance(auth_cfg, dict):
        auth_cfg = {}
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
    bind_dn = auth_cfg.get('ldap_bind_dn', '')
    bind_pw = auth_cfg.get('ldap_bind_password', '')

    sam = _normalise_sam(username)
    upn = f'{sam}@{domain}'
    use_service_bind = bool(bind_dn and bind_pw and _BIND_PW_PLACEHOLDER not in bind_pw)

    tls = _build_tls(cfg)
    server = Server(ldap_url, get_info=ALL, tls=tls, use_ssl=True)

    bind_user = bind_dn if use_service_bind else upn
    bind_pass = bind_pw if use_service_bind else password
    ok, err, conn = _ldap_bind(server, bind_user, bind_pass)
    if not ok:
        return False, err

    entry, err = _ldap_search_user(conn, base_dn, sam)
    if entry is None:
        return False, err

    user_dn = str(entry.distinguishedName) if entry.distinguishedName else ''
    member_of = [str(g).lower() for g in (entry.memberOf.values if entry.memberOf else [])]

    if use_service_bind:
        ok, err, user_conn = _ldap_bind(server, upn, password)
        if not ok:
            return False, err
        user_conn.unbind()

    if required_group_dn and required_group_dn.lower() not in member_of:
        return False, f'Not a member of required group: {required_group_dn}'

    return True, {
        'username': sam,
        'display_name': str(entry.displayName) if entry.displayName else sam,
        'email': str(entry.mail) if entry.mail else '',
        'upn': upn,
    }


def _normalise_sam(username):
    if '\\' in username:
        return username.split('\\', 1)[1]
    if '@' in username:
        return username.split('@', 1)[0]
    return username


def _ldap_bind(server, user, password):
    try:
        conn = Connection(server, user=user, password=password,
                          authentication=SIMPLE, auto_bind=True)
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
