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
      1. Service-account bind for directory search (searches by sAMAccountName,
         fetches memberOf, avoids tighter AD read-restriction failures).
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

    # Normalise username — strip domain prefix if present
    sam = username
    if '\\' in username:
        sam = username.split('\\', 1)[1]
    elif '@' in username:
        sam = username.split('@', 1)[0]

    upn = f'{sam}@{domain}'
    use_service_bind = bool(bind_dn and bind_pw and _BIND_PW_PLACEHOLDER not in bind_pw)

    try:
        tls = _build_tls(cfg)
        server = Server(ldap_url, get_info=ALL, tls=tls, use_ssl='ldaps' in ldap_url.lower())

        if use_service_bind:
            svc_conn = Connection(server, user=bind_dn, password=bind_pw,
                                  authentication=SIMPLE, auto_bind=True)
        else:
            # Direct user bind — credential verification happens here
            svc_conn = Connection(server, user=upn, password=password,
                                  authentication=SIMPLE, auto_bind=True)
    except LDAPBindError:
        return False, 'Invalid credentials'
    except LDAPException as exc:
        return False, f'LDAP error: {exc}'

    # Fetch user attributes and group membership via the bound connection
    search_filter = f'(sAMAccountName={_ldap_escape(sam)})'
    svc_conn.search(
        search_base=base_dn,
        search_filter=search_filter,
        attributes=['memberOf', 'displayName', 'sAMAccountName', 'mail', 'distinguishedName'],
    )

    if not svc_conn.entries:
        svc_conn.unbind()
        return False, 'User not found in directory'

    entry = svc_conn.entries[0]
    user_dn = str(entry.distinguishedName) if entry.distinguishedName else ''
    member_of = [str(g).lower() for g in (entry.memberOf.values if entry.memberOf else [])]
    svc_conn.unbind()

    # Phase 2: verify the user's password via a separate bind (only when service bind was used)
    if use_service_bind and user_dn:
        try:
            user_conn = Connection(server, user=user_dn, password=password,
                                   authentication=SIMPLE, auto_bind=True)
            user_conn.unbind()
        except LDAPBindError:
            return False, 'Invalid credentials'
        except LDAPException as exc:
            return False, f'LDAP error: {exc}'

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
