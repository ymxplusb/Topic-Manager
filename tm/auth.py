import re
import ssl
from ldap3 import Server, Connection, ALL, SIMPLE, Tls
from ldap3.core.exceptions import LDAPException, LDAPBindError

_BIND_PW_PLACEHOLDER = 'CHANGE_ME'


def _build_tls(cfg):
    auth_cfg = cfg.get('auth', {})
    if 'ldaps' not in auth_cfg.get('ldap_server', '').lower():
        return None
    ca_file = auth_cfg.get('ldap_ca_cert') or None
    return Tls(validate=ssl.CERT_REQUIRED, ca_certs_file=ca_file)


def validate_credentials(cfg, username, password):
    """
    Bind to AD with user credentials, verify group membership.
    Returns (True, user_dict) or (False, error_string).

    Uses two-phase bind when ldap_bind_dn/ldap_bind_password are configured:
      1. Service-account bind for directory search.
      2. Re-bind with the found user DN to verify the supplied password.
    Falls back to direct user-bind when service credentials are absent.
    """
    auth_cfg = cfg.get('auth', {})
    ldap_url = auth_cfg.get('ldap_server', 'ldaps://dc1.int.crypticlight.com:636')
    base_dn = auth_cfg.get('ldap_base_dn', 'DC=int,DC=crypticlight,DC=com')
    required_group_dn = auth_cfg.get('required_group', '')
    domain = auth_cfg.get('ldap_domain', 'int.crypticlight.com')
    bind_dn = auth_cfg.get('ldap_bind_dn', '')
    bind_pw = auth_cfg.get('ldap_bind_password', '')

    sam = _normalise_sam(username)
    upn = f'{sam}@{domain}'
    use_service_bind = bool(bind_dn and bind_pw and _BIND_PW_PLACEHOLDER not in bind_pw)

    tls = _build_tls(cfg)
    server = Server(ldap_url, get_info=ALL, tls=tls, use_ssl='ldaps' in ldap_url.lower())

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

    if use_service_bind and user_dn:
        ok, err, user_conn = _ldap_bind(server, user_dn, password)
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
