import re
from ldap3 import Server, Connection, ALL, SIMPLE, Tls
from ldap3.core.exceptions import LDAPException, LDAPBindError
import ssl


def _build_tls(cfg):
    if 'ldaps' in cfg.get('auth', {}).get('ldap_server', '').lower():
        tls = Tls(validate=ssl.CERT_NONE, version=ssl.PROTOCOL_TLS_CLIENT)
        tls.validate = ssl.CERT_NONE
        return tls
    return None


def validate_credentials(cfg, username, password):
    """
    Bind to AD with user credentials, verify group membership.
    Returns (True, user_dict) or (False, error_string).
    """
    auth_cfg = cfg.get('auth', {})
    ldap_url = auth_cfg.get('ldap_server', 'ldaps://dc1.int.crypticlight.com:636')
    base_dn = auth_cfg.get('ldap_base_dn', 'DC=int,DC=crypticlight,DC=com')
    required_group_dn = auth_cfg.get('required_group', '')
    domain = auth_cfg.get('ldap_domain', 'int.crypticlight.com')

    # Normalise username — strip domain prefix if present
    sam = username
    if '\\' in username:
        sam = username.split('\\', 1)[1]
    elif '@' in username:
        sam = username.split('@', 1)[0]

    upn = f'{sam}@{domain}'

    try:
        tls = _build_tls(cfg)
        server = Server(ldap_url, get_info=ALL, tls=tls, use_ssl='ldaps' in ldap_url.lower())
        conn = Connection(server, user=upn, password=password,
                          authentication=SIMPLE, auto_bind=True)
    except LDAPBindError:
        return False, 'Invalid credentials'
    except LDAPException as exc:
        return False, f'LDAP error: {exc}'

    # Search for the user
    search_filter = f'(sAMAccountName={_ldap_escape(sam)})'
    conn.search(
        search_base=base_dn,
        search_filter=search_filter,
        attributes=['memberOf', 'displayName', 'sAMAccountName', 'mail'],
    )

    if not conn.entries:
        conn.unbind()
        return False, 'User not found in directory'

    entry = conn.entries[0]
    member_of = [str(g).lower() for g in (entry.memberOf.values if entry.memberOf else [])]
    conn.unbind()

    if required_group_dn and required_group_dn.lower() not in member_of:
        return False, f'Not a member of required group: {required_group_dn}'

    display = str(entry.displayName) if entry.displayName else sam
    mail = str(entry.mail) if entry.mail else ''

    return True, {
        'username': sam,
        'display_name': display,
        'email': mail,
        'upn': upn,
    }


def _ldap_escape(value):
    """Escape special characters in LDAP filter values."""
    return re.sub(r'([\\*\(\)\x00])', lambda m: f'\\{ord(m.group(1)):02x}', value)
