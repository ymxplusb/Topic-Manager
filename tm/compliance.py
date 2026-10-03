"""
STIG compliance (v1.3.0, James 2026-10-02, DQ3): the operator page's rule
list and the application's own live checks.

docs/STIG-COMPLIANCE.md is the SOURCE OF TRUTH: every rule of the STIG
decision board with its decision, status, how it is met, how it is verified
and the evidence. RULES below is the page's copy of the parts the page shows
(id, severity, decision, status, live checks, title), and
tools/check-stig-compliance.sh holds the two to each other field for field,
as the PPSM gate holds the two PPSM copies — edit both or the gate stops the
release.

LIVE CHECKS. Each rule may name checks measured on THIS host:
  * HOST_CHECKS — measured by the root apply helper
    (install/libexec/tm-apply, domain "compliance": `nginx -T`, /etc/shadow,
    modes under /etc/nginx and /var/log/nginx), started from Settings like an
    apply and changing nothing; its last verdict is kept in tm.db;
  * APP_CHECKS — measured here, now, by the service.
A check is pass, warn (host state the product does not own, or an open item),
fail (the product's own files or settings drifted), info, or unknown — never
a guess (hazards[misleading-failure-message]).

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import collections
import os
import sqlite3
import stat

from . import apply as apply_mod
from . import audit, auth, hoststatus, settings_schema
from .models import get_db, DB_FILE_MODE, DB_DIR_MODE

Rule = collections.namedtuple('Rule', 'id sev decision status checks title')

STATUSES = ('MET', 'PARTLY', 'INHERITED', 'N-A', 'NOT-MET')
DECISIONS = ('Yes', 'Other', 'No')

#: Measured by the root helper (install/libexec/tm-apply compliance_checks).
HOST_CHECKS = ('web_account_shell', 'web_account_groups', 'web_account_password',
               'nginx_config_modes', 'site_log_modes', 'nginx_modules', 'tls_protocols',
               'nginx_log_format', 'server_tokens', 'error_pages', 'worker_connections',
               'nginx_http_logs', 'tls_key_mode')
#: Measured here (app_checks).
APP_CHECKS = ('session_cap', 'absolute_lifetime', 'group_recheck', 'consent_notice',
              'remote_syslog', 'db_modes', 'sqlite_extensions', 'tls_issuer', 'fips_mode',
              'time_sync', 'audit_write_state')

RULES = (
    Rule('NGNX-APP-000010', 'CAT II', 'Yes', 'MET', ('session_cap', 'worker_connections'),
         'NGINX must limit the number of concurrent sessions to an organization-defined number for all accounts and/or account types.'),
    Rule('NGNX-APP-000040', 'CAT I', 'Yes', 'MET', ('tls_protocols',),
         'NGINX must use TLS 1.2, at a minimum, to protect data confidentiality using remote access.'),
    Rule('NGNX-APP-000140', 'CAT II', 'Yes', 'INHERITED', ('web_account_shell',),
         'The NGINX service account must be configured to not have shell access.'),
    Rule('NGNX-APP-000150', 'CAT II', 'Yes', 'INHERITED', ('web_account_groups',),
         'The NGINX service account must be configured to not have admin group access.'),
    Rule('NGNX-APP-000180', 'CAT II', 'Yes', 'MET', ('consent_notice',),
         'NGINX must display the Standard Mandatory DOD Notice and Consent Banner before granting access to the application.'),
    Rule('NGNX-APP-000240', 'CAT II', 'Yes', 'MET', ('nginx_log_format',),
         'NGINX must provide audit records for DOD-defined auditable events.'),
    Rule('NGNX-APP-000250', 'CAT II', 'Other', 'INHERITED', ('nginx_config_modes',),
         'NGINX must allow only the information system security manager (ISSM) (or individuals or roles appointed by the ISSM) to select which auditable events are to be audited.'),
    Rule('NGNX-APP-000370', 'CAT II', 'Yes', 'INHERITED', ('nginx_modules',),
         'NGINX must prevent the execution of unapproved modules.'),
    Rule('NGNX-APP-000400', 'CAT II', 'Yes', 'MET', ('site_log_modes',),
         'NGINX must protect audit information from unauthorized access.'),
    Rule('NGNX-APP-000510', 'CAT II', 'Yes', 'MET', (),
         'NGINX must be configured to prohibit or restrict using ports, protocols, and/or services.'),
    Rule('NGNX-APP-000590', 'CAT II', 'Yes', 'MET', (),
         'NGINX must implement replay-resistant authentication mechanisms for network access.'),
    Rule('NGNX-APP-000720', 'CAT II', 'No', 'NOT-MET', (),
         'NGINX must be configured to use a Certificate Revocation List (CRL) for certificate path validation and revocation. (Online Certificate Status Protocol [OCSP] is the preferred configuration.)'),
    Rule('NGNX-APP-000730', 'CAT II', 'Yes', 'MET', ('tls_key_mode',),
         'NGINX, when using PKI-based authentication, must enforce authorized access to the corresponding private key.'),
    Rule('NGNX-APP-000850', 'CAT II', 'Yes', 'PARTLY', (),
         'NGINX must identify prohibited mobile code.'),
    Rule('NGNX-APP-001030', 'CAT II', 'Yes', 'MET', (),
         'NGINX must restrict the ability of individuals to launch denial-of-service (DoS) attacks against other information systems.'),
    Rule('NGNX-APP-001070', 'CAT II', 'Yes', 'MET', ('server_tokens', 'error_pages'),
         'NGINX must generate error messages that provide information necessary for corrective actions without revealing information that could be exploited by adversaries.'),
    Rule('NGNX-APP-001400', 'CAT I', 'Yes', 'PARTLY', ('remote_syslog', 'nginx_http_logs'),
         'NGINX must off-load audit records to a central log server.'),
    Rule('NGNX-APP-001590', 'CAT II', 'Yes', 'INHERITED', ('nginx_config_modes',),
         'NGINX must restrict access to configuration files.'),
    Rule('NGNX-APP-001630', 'CAT II', 'Other', 'N-A', (),
         'NGINX must be configured with a deny-all, permit-by-exception policy to allow the execution of authorized software programs.'),
    Rule('NGNX-APP-001640', 'CAT II', 'Yes', 'MET', (),
         'NGINX must be configured to require SSL sessions to reauthenticate no longer than 15 minutes.'),
    Rule('NGNX-APP-001650', 'CAT II', 'No', 'NOT-MET', (),
         'NGINX must accept Personal Identity Verification (PIV) credentials.'),
    Rule('NGNX-APP-001690', 'CAT II', 'Yes', 'MET', (),
         'NGINX must be configured to expire cached authenticators after an organization-defined time period.'),
    Rule('NGNX-APP-001840', 'CAT II', 'Yes', 'MET', (),
         'NGINX must be configured to pass security attributes to proxies.'),
    Rule('NGNX-APP-001900', 'CAT II', 'Other', 'INHERITED', ('tls_issuer',),
         'NGINX must only allow using DOD approved certificate authorities for PKI.'),
    Rule('NGNX-APP-001940', 'CAT II', 'Yes', 'MET', (),
         'NGINX must protect against denial-of-service (DoS) attacks.'),
    Rule('NGNX-APP-001960', 'CAT II', 'Yes', 'MET', (),
         'NGINX must be configured to use FIPS-approved algorithms to protect the confidentiality and integrity of transmitted information.'),
    Rule('NGNX-APP-002620', 'CAT II', 'No', 'NOT-MET', (),
         'NGINX must be configured to use Online Certificate Status Protocol (OCSP) for certificate path validation and revocation. (OCSP is the preferred configuration.)'),
    Rule('NGNX-APP-002660', 'CAT II', 'Yes', 'INHERITED', ('fips_mode',),
         'NGINX must be configured to use a FIPS-validated cryptographic module for confidentiality and integrity.'),
    Rule('NGNX-APP-003040', 'CAT II', 'Yes', 'INHERITED', ('web_account_password',),
         'The NGINX service account must be configured to lock changes to the password.'),
    Rule('NGNX-APP-003060', 'CAT II', 'Other', 'N-A', (),
         'NGINX must separate API maintenance sessions from other network sessions within the system by logically separated communications paths.'),
    Rule('NGNX-APP-003220', 'CAT II', 'Other', 'MET', (),
         'NGINX must generate, manage, and protect from disclosure and misuse the cryptographic keys that protect access tokens.'),
    Rule('NGNX-APP-003330', 'CAT II', 'Yes', 'MET', ('group_recheck', 'absolute_lifetime'),
         'NGINX must revoke access tokens in accordance with organization-defined identification and authentication policy.'),
    Rule('SRG-APP-000001-DB-000031', 'CAT II', 'Yes', 'MET', ('session_cap',),
         'The DBMS must limit the number of concurrent sessions to an organization-defined number per user for all accounts and/or account types.'),
    Rule('SRG-APP-000089-DB-000064', 'CAT II', 'Yes', 'MET', ('audit_write_state',),
         'The DBMS must provide audit record generation capability for DoD-defined auditable events within all DBMS/database components.'),
    Rule('SRG-APP-000095-DB-000039', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must produce audit records containing sufficient information to establish what type of events occurred.'),
    Rule('SRG-APP-000096-DB-000040', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must produce audit records containing time stamps to establish when the events occurred.'),
    Rule('SRG-APP-000097-DB-000041', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must produce audit records containing sufficient information to establish where the events occurred.'),
    Rule('SRG-APP-000098-DB-000042', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must produce audit records containing sufficient information to establish the sources (origins) of the events.'),
    Rule('SRG-APP-000099-DB-000043', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must produce audit records containing sufficient information to establish the outcome (success or failure) of the events.'),
    Rule('SRG-APP-000100-DB-000201', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must produce audit records containing sufficient information to establish the identity of any user/subject or process associated with the event.'),
    Rule('SRG-APP-000116-DB-000057', 'CAT II', 'Yes', 'MET', ('time_sync',),
         'The DBMS must use system clocks to generate time stamps for use in audit records and application data.'),
    Rule('SRG-APP-000118-DB-000059', 'CAT II', 'Yes', 'MET', ('db_modes',),
         'The audit information produced by the DBMS must be protected from unauthorized read access.'),
    Rule('SRG-APP-000119-DB-000060', 'CAT II', 'Yes', 'MET', ('db_modes',),
         'The audit information produced by the DBMS must be protected from unauthorized modification.'),
    Rule('SRG-APP-000120-DB-000061', 'CAT II', 'Yes', 'MET', ('db_modes',),
         'The audit information produced by the DBMS must be protected from unauthorized deletion.'),
    Rule('SRG-APP-000121-DB-000202', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must protect its audit features from unauthorized access.'),
    Rule('SRG-APP-000122-DB-000203', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must protect its audit configuration from unauthorized modification.'),
    Rule('SRG-APP-000123-DB-000204', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must protect its audit features from unauthorized removal.'),
    Rule('SRG-APP-000133-DB-000198', 'CAT I', 'Yes', 'MET', (),
         'The DBMS software installation account must be restricted to authorized users.'),
    Rule('SRG-APP-000133-DB-000199', 'CAT II', 'Yes', 'MET', (),
         'Database software, including DBMS configuration files, must be stored in dedicated directories, or DASD pools, separate from the host OS and other applications.'),
    Rule('SRG-APP-000133-DB-000200', 'CAT II', 'Yes', 'MET', ('db_modes',),
         'Database objects (including but not limited to tables, indexes, storage, stored procedures, functions, triggers, links to software external to the DBMS, etc.) must be owned by database/DBMS principals authorized for ownership.'),
    Rule('SRG-APP-000141-DB-000091', 'CAT II', 'Yes', 'MET', (),
         'Unused database components, DBMS software, and database objects must be removed.'),
    Rule('SRG-APP-000141-DB-000093', 'CAT II', 'Yes', 'MET', ('sqlite_extensions',),
         'Access to external executables must be disabled or restricted.'),
    Rule('SRG-APP-000179-DB-000114', 'CAT I', 'Other', 'N-A', (),
         'The DBMS must use NIST FIPS 140-2 or 140-3 validated cryptographic modules for cryptographic operations.'),
    Rule('SRG-APP-000220-DB-000149', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must invalidate session identifiers upon user logout or other session termination.'),
    Rule('SRG-APP-000223-DB-000168', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must recognize only system-generated session identifiers.'),
    Rule('SRG-APP-000225-DB-000153', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must fail to a secure state if system initialization fails, shutdown fails, or aborts fail.'),
    Rule('SRG-APP-000226-DB-000147', 'CAT II', 'Yes', 'MET', (),
         'In the event of a system failure, the DBMS must preserve any information necessary to determine cause of failure and any information necessary to return to operations with least disruption to mission processes.'),
    Rule('SRG-APP-000231-DB-000154', 'CAT I', 'Other', 'INHERITED', (),
         'The DBMS must protect the confidentiality and integrity of all information at rest.'),
    Rule('SRG-APP-000243-DB-000374', 'CAT II', 'Yes', 'MET', ('db_modes',),
         'Access to database files must be limited to relevant processes and to authorized, administrative users.'),
    Rule('SRG-APP-000251-DB-000160', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must check the validity of all data inputs except those specifically identified by the organization.'),
    Rule('SRG-APP-000251-DB-000391', 'CAT II', 'Yes', 'MET', (),
         'The DBMS and associated applications must reserve the use of dynamic code execution for situations that require it.'),
    Rule('SRG-APP-000266-DB-000162', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must provide non-privileged users with error messages that provide information necessary for corrective actions without revealing information that could be exploited by adversaries.'),
    Rule('SRG-APP-000295-DB-000305', 'CAT II', 'Yes', 'MET', ('absolute_lifetime',),
         'The DBMS must automatically terminate a user session after organization-defined conditions or trigger events requiring session disconnect.'),
    Rule('SRG-APP-000296-DB-000306', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must provide logout functionality to allow the user to manually terminate a session initiated by that user.'),
    Rule('SRG-APP-000357-DB-000316', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must allocate audit record storage capacity in accordance with organization-defined audit record storage requirements.'),
    Rule('SRG-APP-000359-DB-000319', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must provide a warning to appropriate support staff when allocated audit record storage volume reaches 75% of maximum audit record storage capacity.'),
    Rule('SRG-APP-000360-DB-000320', 'CAT II', 'Yes', 'MET', ('audit_write_state', 'remote_syslog'),
         'The DBMS must provide an immediate real-time alert to appropriate support staff of all audit log failures.'),
    Rule('SRG-APP-000374-DB-000322', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must record time stamps, in audit records and application data, that can be mapped to Coordinated Universal Time (UTC, formerly GMT).'),
    Rule('SRG-APP-000375-DB-000323', 'CAT II', 'Yes', 'MET', (),
         'The DBMS must generate time stamps, for audit records and application data, with a minimum granularity of one second.'),
    Rule('SRG-APP-000456-DB-000390', 'CAT II', 'Yes', 'INHERITED', (),
         'Security-relevant software updates to the DBMS must be installed within 30 days unless the time period is directed by an authoritative source (e.g., IAVM, CTOs, DTMs, and STIGs).'),
    Rule('SRG-APP-000515-DB-000318', 'CAT II', 'Yes', 'MET', ('remote_syslog',),
         'The DBMS must off-load audit data to a separate log management facility; this shall be continuous and in near real time for systems with a network connection to the storage facility and weekly or more often for stand-alone systems.'),
    Rule('SRG-APP-000795-DB-000130', 'CAT II', 'Other', 'INHERITED', (),
         'The DBMS must alert organization-defined personnel or roles upon detection of unauthorized access, modification, or deletion of audit information.'),
    Rule('SRG-APP-000920-DB-000320', 'CAT II', 'Yes', 'MET', ('time_sync',),
         'The DBMS must synchronize system clocks within and between systems or system components.'),
    Rule('SRG-APP-000925-DB-000330', 'CAT II', 'Yes', 'MET', ('time_sync',),
         'The DBMS must compare the internal system clocks on an organization-defined frequency with organization-defined authoritative time source.'),
    Rule('SRG-APP-001035-DB-000323', 'CAT I', 'Yes', 'MET', (),
         'The DBMS must be a version supported by the vendor.'),
)


def _check(key, status, detail):
    return {'key': key, 'status': status, 'detail': str(detail)[:500], 'where': 'app'}


def _session_checks(cfg, db):
    vals = settings_schema.read_admin(db, ['session_max_concurrent', 'session_absolute_hours'])
    cap = settings_schema.int_setting(vals, 'session_max_concurrent')
    hours = settings_schema.int_setting(vals, 'session_absolute_hours')
    out = [_check('session_cap', 'pass' if cap > 0 else 'warn',
                  '%d concurrent session(s) per user' % cap if cap > 0 else
                  'unlimited (0): set a limit in Settings > Security > Sessions'),
           _check('absolute_lifetime', 'pass', 'a session ends %d hour(s) after sign-in, however '
                  'active' % hours)]
    if auth.recheck_supported(cfg):
        out.append(_check('group_recheck', 'pass', 'required_group is re-checked every %d minutes '
                          'with the service account' % auth.GROUP_RECHECK_MINUTES))
    else:
        out.append(_check('group_recheck', 'warn', 'no LDAP service account (auth.ldap_bind_dn) is '
                          'configured, so group membership cannot be re-checked during a session: '
                          'a removed user keeps access until sign-out, the idle timeout or the '
                          'absolute lifetime'))
    return out


def _consent_check(db):
    rows = dict(db.execute("SELECT key, value FROM app_settings WHERE key IN ('dow_enabled', "
                           "'dow_text')").fetchall())
    if rows.get('dow_enabled') != 'true':
        return _check('consent_notice', 'warn', 'the consent notice is OFF (open item): turn it on '
                      'in Settings > General > DoW Consent Banner')
    return _check('consent_notice', 'pass', 'on, with the %s' % (
        'operator-supplied text' if rows.get('dow_text') else 'standard DoD wording'))


def _syslog_check(cfg):
    values, at = apply_mod.applied(cfg, 'syslog')
    if values is None:
        return _check('remote_syslog', 'warn', 'remote syslog has never been applied on this host: '
                      'the audit trail and the nginx logs stay on it (open item)')
    if values.get('syslog_enabled') != 'true':
        return _check('remote_syslog', 'warn', 'remote syslog is OFF (applied %s): the audit trail '
                      'and the nginx logs stay on this host (open item)' % (at or '?'))
    return _check('remote_syslog', 'pass', 'forwarding to %s:%s over %s (applied %s)' % (
        values.get('syslog_host', '?'), values.get('syslog_port', '?'),
        str(values.get('syslog_protocol', '?')).upper(), at or '?'))


def _db_checks(cfg):
    path = cfg.get('audit', {}).get('db_path', '/opt/topic-manager/data/tm.db')
    out = []
    try:
        f, d = os.stat(path), os.stat(os.path.dirname(path) or '.')
        wide = [n for n, st, want in ((path, f, DB_FILE_MODE), (os.path.dirname(path), d, DB_DIR_MODE))
                if stat.S_IMODE(st.st_mode) & ~want]
        out.append(_check('db_modes', 'fail' if wide else 'pass',
                          ('wider than 0600/0700: %s' % ', '.join(wide)) if wide else
                          'tm.db %o, its directory %o' % (stat.S_IMODE(f.st_mode),
                                                         stat.S_IMODE(d.st_mode))))
    except OSError as exc:
        out.append(_check('db_modes', 'unknown', 'could not stat the database: %s' % exc))
    conn = get_db(cfg)
    try:
        conn.execute("SELECT load_extension('tm-compliance-probe')")
        out.append(_check('sqlite_extensions', 'fail', 'load_extension() was NOT refused'))
    except sqlite3.OperationalError as exc:
        refused = 'not authorized' in str(exc)
        out.append(_check('sqlite_extensions', 'pass' if refused else 'fail',
                          'load_extension() is refused' if refused else
                          'load_extension() was attempted: %s' % exc))
    finally:
        conn.close()
    return out


def _host_view_checks(cfg):
    tls = hoststatus.tls_status()
    if tls.get('self_signed') is None:
        issuer = _check('tls_issuer', 'unknown', 'the server certificate could not be read')
    elif tls['self_signed']:
        issuer = _check('tls_issuer', 'warn', 'self-signed (%s): replace it with a certificate '
                        'from a DoD-approved CA' % (tls['cert'].get('subject') or '?'))
    else:
        issuer = _check('tls_issuer', 'info', 'issued by %s: confirm it is a DoD-approved CA'
                        % (tls['cert'].get('issuer') or '?'))
    fips = hoststatus.fips_mode()
    synced = hoststatus.time_status().get('synced')
    failure = audit.write_failure_state(cfg)
    return [issuer,
            _check('fips_mode', 'pass' if fips else 'warn',
                   'the host runs in FIPS mode' if fips else 'the host is NOT in FIPS mode'),
            _check('time_sync', 'pass' if synced else 'warn',
                   'the host clock is synchronised' if synced else
                   'the host clock is NOT synchronised'),
            _check('audit_write_state', 'fail' if failure and failure['current'] else 'pass',
                   ('an audit write FAILED at %s and none has succeeded since' % failure['failed_at'])
                   if failure and failure['current'] else
                   ('no current audit write failure (last: %s, recovered %s)'
                    % (failure['failed_at'], failure['recovered_at']) if failure else
                    'no audit write has failed'))]


def app_checks(cfg):
    """Every APP_CHECKS key, measured now. One probe that raises does not
    hide the others: it reports unknown."""
    out = []
    db = get_db(cfg)
    try:
        for fn in (lambda: _session_checks(cfg, db), lambda: [_consent_check(db)]):
            try:
                out.extend(fn())
            except Exception as exc:
                out.append(_check('internal', 'unknown', '%s: %s' % (type(exc).__name__, exc)))
    finally:
        db.close()
    for fn in (lambda: [_syslog_check(cfg)], lambda: _db_checks(cfg),
               lambda: _host_view_checks(cfg)):
        try:
            out.extend(fn())
        except Exception as exc:
            out.append(_check('internal', 'unknown', '%s: %s' % (type(exc).__name__, exc)))
    return out


def report(cfg):
    """The GET /api/compliance document: every rule, its documented status,
    and its live checks with what was measured."""
    host = apply_mod.status(cfg, 'compliance')
    measured = {c['key']: dict(c, where='host') for c in host.get('checks') or []}
    measured.update({c['key']: c for c in app_checks(cfg)})
    rules = []
    for r in RULES:
        live = [measured.get(k) or {'key': k, 'status': 'unknown', 'where':
                                    'host' if k in HOST_CHECKS else 'app',
                                    'detail': 'not measured yet: press Measure host now'}
                for k in r.checks]
        rules.append({'id': r.id, 'sev': r.sev, 'decision': r.decision, 'status': r.status,
                      'title': r.title, 'checks': live})
    open_items = sorted({c['key'] for r in rules for c in r['checks']
                         if c['status'] in ('warn', 'fail')})
    counts = collections.Counter(r.status for r in RULES)
    return {'rules': rules, 'counts': dict(counts), 'open_items': open_items,
            'host': {'state': host.get('state'), 'measured_at': host.get('finished_at'),
                     'message': host.get('message', '')},
            'document': 'docs/STIG-COMPLIANCE.md'}
