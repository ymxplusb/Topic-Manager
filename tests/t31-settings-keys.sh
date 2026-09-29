#!/usr/bin/env bash
# =============================================================================
# t31 — THE v1.2.0 ADMINISTRATOR SETTINGS: never public, always validated, and
# the session limit's precedence (Settings wins; config.yaml only seeds).
#
# THE ALIAS TRAP (scout consumer 1). v1.1.0 had `_ALL_KEYS = _PUBLIC_KEYS`,
# one set object under two names. The first `_ALL_KEYS.add('syslog_host')`
# would have published the syslog collector, the NTP servers and the rate
# limits on /api/settings/public, which answers WITHOUT authentication. These
# cases pin the public set at exactly the five display keys — by identity, by
# content and by what the unauthenticated route actually returns after every
# admin key has been saved.
#
# Every validator is driven with the injection shapes the root helper would
# otherwise have to survive: newline, semicolon, brace, quote, space, a leading
# dash, and the numeric edges.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "admin settings: never public, always validated, session limit precedence"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_py() { PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 "$PY" "$@" 2>&1 | tr -d '\r'; }

_setup() {   # _setup [extra yaml for the session block]
    local NT; NT="$(cygpath -m "$TM_TMP" 2>/dev/null || printf '%s' "$TM_TMP")"
    cat > "${TM_TMP}/config.yaml" <<YAML
server:
  host: 127.0.0.1
  port: 5001
  secret_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
auth:
  ldap_server: "ldaps://dc1.example.org:636"
  ldap_domain: "example.org"
  ldap_base_dn: "DC=example,DC=org"
  required_group: "CN=Kafka-Admins,DC=example,DC=org"
session:
  timeout_minutes: 30
${1:-}
audit:
  db_path: "${NT}/tm.db"
logging:
  log_level: "WARNING"
YAML
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs"
    printf 'clusters: []\n' > "${TM_TMP}/clusters.d/clusters.yaml"
}

_app() {   # _app <python body>; `app`, `c` (authenticated client), `db()` in scope
    cat > "${TM_TMP}/probe.py" <<PYEOF
import json, os, sqlite3, datetime, logging, io
logbuf = io.StringIO()
logging.getLogger().addHandler(logging.StreamHandler(logbuf))
from tm.app import create_app
app = create_app()
c = app.test_client()
def db():
    return sqlite3.connect(os.environ['TM_TEST_DB'])
def login_as(user):
    with c.session_transaction() as s:
        s['user'] = {'username': user}; s['sid'] = 'sid-' + user
    now = datetime.datetime.now(datetime.timezone.utc)
    d = db()
    d.execute('INSERT OR REPLACE INTO sessions VALUES (?,?,?,?,?,?)',
              ('sid-' + user, user, now.isoformat(), now.isoformat(),
               (now + datetime.timedelta(hours=1)).isoformat(), '192.0.2.1'))
    d.commit(); d.close()
H = {'Content-Type': 'application/json', 'Sec-Fetch-Site': 'same-origin'}
$1
PYEOF
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 TM_CONFIG="${TM_TMP}/config.yaml" \
        TM_TEST_DB="${TM_TMP}/tm.db" TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
        TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" TM_SYSLOG_SOCKET="${TM_TMP}/no-such.sock" \
        "$PY" "${TM_TMP}/probe.py" 2>&1 | tr -d '\r'
}

# ─── the public set ─────────────────────────────────────────────────────────
a_public_set_is_five() {
    _setup
    local out
    out="$(_app "
from tm import routes
print('public=%s' % ','.join(sorted(routes._PUBLIC_KEYS)))
print('frozen=%s' % isinstance(routes._PUBLIC_KEYS, frozenset))
print('alias=%s' % (routes._ALL_KEYS is routes._PUBLIC_KEYS))
print('leak=%s' % ','.join(sorted(routes._PUBLIC_KEYS & routes.settings_schema.ADMIN_KEYS)))
print('all_has_admin=%s' % routes.settings_schema.ADMIN_KEYS.issubset(routes._ALL_KEYS))
")"
    tm_assert_eq "public=banner_bg,banner_enabled,banner_fg,banner_text,dow_enabled" \
        "$(grep '^public=' <<<"$out")" "the PUBLIC settings set is not exactly the five display keys: ${out}"
    tm_assert_eq "frozen=True" "$(grep '^frozen=' <<<"$out")" \
        "_PUBLIC_KEYS can be extended in place — one .add() publishes an admin setting"
    tm_assert_eq "alias=False" "$(grep '^alias=' <<<"$out")" \
        "_ALL_KEYS IS _PUBLIC_KEYS (the v1.1.0 alias): extending one extends the other"
    tm_assert_eq "leak=" "$(grep '^leak=' <<<"$out")" "an admin key is in the public set"
    tm_assert_eq "all_has_admin=True" "$(grep '^all_has_admin=' <<<"$out")" \
        "the authenticated settings set does not carry every admin key"
}
tm_case "public-settings-set-is-exactly-five-keys" tmapp a_public_set_is_five

a_public_route_serves_five() {
    _setup
    local out
    out="$(_app "
login_as('admin')
r = c.put('/api/settings', data=json.dumps({'syslog_enabled': 'true', 'syslog_host': 'logs.example.org',
    'ntp_servers': 'ntp1.example.org', 'ratelimit_api_per_min': '400', 'banner_text': 'HELLO'}), headers=H)
print('put=%d' % r.status_code)
anon = app.test_client()
p = anon.get('/api/settings/public').get_json()
print('keys=%s' % ','.join(sorted(p)))
print('text=%s' % p.get('banner_text'))
full = c.get('/api/settings').get_json()
print('full_host=%s' % full.get('syslog_host'))
print('full_n=%d' % len(full))
")"
    tm_assert_eq "put=200" "$(grep '^put=' <<<"$out")" "saving admin settings failed: ${out}"
    tm_assert_eq "keys=banner_bg,banner_enabled,banner_fg,banner_text,dow_enabled" \
        "$(grep '^keys=' <<<"$out")" \
        "the UNAUTHENTICATED /api/settings/public returned more than the display keys: ${out}"
    tm_assert_eq "text=HELLO" "$(grep '^text=' <<<"$out")" "the public route stopped serving the banner"
    tm_assert_eq "full_host=logs.example.org" "$(grep '^full_host=' <<<"$out")" \
        "the authenticated route does not return the saved admin setting"
    tm_assert_eq "full_n=21" "$(grep '^full_n=' <<<"$out")" "GET /api/settings is not 5 display + 16 admin keys"
}
tm_case "public-route-never-serves-an-admin-key" tmapp a_public_route_serves_five

# ─── the contract table ──────────────────────────────────────────────────────
a_defaults_are_the_contract() {
    local out
    out="$(_py -c "
from tm import settings_schema as s
want = {'syslog_enabled':'false','syslog_host':'','syslog_port':'6514','syslog_protocol':'tls',
 'syslog_app_id':'topic-manager','ntp_servers':'','session_max_concurrent':'3',
 'ratelimit_login_per_min':'10','ratelimit_login_burst':'5','ratelimit_api_per_min':'300',
 'ratelimit_api_burst':'100','ratelimit_conn_per_ip':'20','audit_retention_days':'365',
 'audit_max_rows':'5000000','audit_warn_pct':'75','http_redirect_enabled':'true'}
print('same=%s' % (s.ADMIN_DEFAULTS == want))
bad = [k for k,v in want.items() if s.normalise(k, v) != v and v != '']
print('selfvalid=%s' % bad)
")"
    tm_assert_eq "same=True" "$(grep '^same=' <<<"$out")" "the defaults are not the contract's table: ${out}"
    tm_assert_eq "selfvalid=[]" "$(grep '^selfvalid=' <<<"$out")" "a default fails its own validator: ${out}"
}
tm_case "defaults-equal-the-contract-table" none a_defaults_are_the_contract

a_validators() {
    local out
    out="$(_py - <<'PYEOF'
from tm import settings_schema as s
ok = [('syslog_host','logs.example.org'),('syslog_host','192.0.2.7'),('syslog_host','2001:db8::7'),
      ('syslog_host',''),('syslog_port','1'),('syslog_port','65535'),('syslog_port',6514),
      ('syslog_protocol','UDP'),('syslog_protocol','tls'),('syslog_app_id','tm.prod_1-a'),
      ('syslog_app_id','a'*48),('syslog_enabled',True),('syslog_enabled','FALSE'),
      ('ntp_servers','ntp1.example.org, 192.0.2.1'),('ntp_servers',','.join('n%d.example.org' % i for i in range(5))),
      ('session_max_concurrent','0'),('session_max_concurrent','50'),('ratelimit_login_per_min','1'),
      ('ratelimit_login_per_min','600'),('ratelimit_login_burst','0'),('ratelimit_api_per_min','10'),
      ('ratelimit_api_per_min','6000'),('ratelimit_api_burst','1000'),('ratelimit_conn_per_ip','500'),
      ('audit_retention_days','30'),('audit_retention_days','3650'),('audit_max_rows','10000'),
      ('audit_max_rows','50000000'),('audit_warn_pct','50'),('audit_warn_pct','95'),
      ('http_redirect_enabled','true'),
      ('syslog_host','fe80::1'),('syslog_host','::ffff:192.0.2.1'),('syslog_host','x'*63 + '.example.org'),
      ('ntp_servers','2001:db8::1,ntp.example.org')]
bad = [('syslog_host','fe80::1%a\nb'),('syslog_host','fe80::1%eth0'),('ntp_servers','fe80::1%a\nb'),
       ('ntp_servers','ntp.example.org,fe80::1%lo'),('syslog_host','logs.example.org.'),
       ('syslog_host','a..b'),('syslog_host','a-.b'),('syslog_host','x'*64 + '.org'),
       ('syslog_host','1.2.3'),('syslog_host','256.1.1.1'),('syslog_port','\u0661\u0662'),
       ('syslog_app_id','tm\nx'),('syslog_host','a\nb'),('syslog_host','a;b'),('syslog_host','a{b}'),('syslog_host','a"b'),
       ('syslog_host','a b'),('syslog_host','-oProxy'),('syslog_host','.lead'),('syslog_host','a'*254),
       ('syslog_host','x/y'),('syslog_port','0'),('syslog_port','65536'),('syslog_port','-1'),
       ('syslog_port','65 14'),('syslog_port','1e3'),('syslog_port',''),('syslog_protocol','sctp'),
       ('syslog_protocol',''),('syslog_app_id','a b'),('syslog_app_id',''),('syslog_app_id','a'*49),
       ('syslog_app_id','x;y'),('syslog_app_id','x"y'),('syslog_enabled','yes'),('syslog_enabled','1'),
       ('ntp_servers','a,b,c,d,e,f'),('ntp_servers','a,,b'),('ntp_servers','a;b'),('ntp_servers','a,A'),
       ('ntp_servers','ntp1 ntp2'),('session_max_concurrent','51'),('session_max_concurrent','-1'),
       ('ratelimit_login_per_min','0'),('ratelimit_login_per_min','601'),('ratelimit_login_burst','101'),
       ('ratelimit_api_per_min','9'),('ratelimit_api_per_min','6001'),('ratelimit_api_burst','1001'),
       ('ratelimit_conn_per_ip','0'),('ratelimit_conn_per_ip','501'),('audit_retention_days','29'),
       ('audit_retention_days','3651'),('audit_max_rows','9999'),('audit_max_rows','50000001'),
       ('audit_warn_pct','49'),('audit_warn_pct','96'),('http_redirect_enabled','on'),
       ('syslog_port',['1']),('syslog_host',None),('banner_text','x')]
fails = []
for k, v in ok:
    try: s.normalise(k, v)
    except s.InvalidSetting as e: fails.append('REFUSED %s=%r: %s' % (k, v, e))
for k, v in bad:
    try:
        got = s.normalise(k, v); fails.append('ACCEPTED %s=%r -> %r' % (k, v, got))
    except s.InvalidSetting: pass
print('norm_proto=%s' % s.normalise('syslog_protocol', 'UDP'))
print('norm_bool=%s' % s.normalise('syslog_enabled', True))
print('norm_ntp=%s' % s.normalise('ntp_servers', ' a.example.org , b.example.org '))
print('FAILS=%d' % len(fails))
for f in fails: print(f)
PYEOF
)"
    tm_assert_eq "FAILS=0" "$(grep '^FAILS=' <<<"$out")" "a validator is wrong: ${out}"
    tm_assert_eq "norm_proto=udp" "$(grep '^norm_proto=' <<<"$out")" "protocol is not stored lower-case"
    tm_assert_eq "norm_bool=true" "$(grep '^norm_bool=' <<<"$out")" "a JSON boolean is not stored as \"true\""
    tm_assert_eq "norm_ntp=a.example.org,b.example.org" "$(grep '^norm_ntp=' <<<"$out")" "NTP list is not normalised"
}
tm_case "every-validator-accepts-its-range-and-refuses-injection" none a_validators

a_cross_field() {
    local out
    out="$(_py -c "
from tm import settings_schema as s
print('p1=%s' % s.check_domain('syslog', {'syslog_enabled':'true','syslog_host':'','syslog_port':'514','syslog_protocol':'udp','syslog_app_id':'x'}))
print('p2=%s' % s.check_domain('syslog', {'syslog_enabled':'false','syslog_host':'','syslog_port':'514','syslog_protocol':'udp','syslog_app_id':'x'}))
")"
    grep -q "^p1=.*syslog_host: required" <<<"$out" || _tm_afail "remote syslog ON with no host was not refused: ${out}"
    tm_assert_eq "p2=[]" "$(grep '^p2=' <<<"$out")" "remote syslog OFF with no host was refused"
}
tm_case "syslog-enabled-needs-a-host" none a_cross_field

# normalise() refuses a key it has no validator for, rather than storing it
# unchecked. Unreachable for the shipped table (every admin key has one), so
# the case adds a key WITHOUT one: the guard is what a future key that forgot
# its validator would meet.
a_no_validator_is_refused() {
    local out
    out="$(_py -c "
from tm import settings_schema as s
s.ADMIN_KEYS = s.ADMIN_KEYS | {'future_key'}
try:
    print('stored=%r' % s.normalise('future_key', 'x;rm -rf /'))
except s.InvalidSetting as e:
    print('refused=%s:%s' % (e.field, e.reason))
")"
    tm_assert_eq "refused=future_key:no validator" "$out" "a key with no validator was stored unchecked: ${out}"
}
tm_case "a-key-without-a-validator-is-refused" none a_no_validator_is_refused

a_put_refuses_and_writes_nothing() {
    _setup
    local out
    out="$(_app "
login_as('admin')
before = dict(db().execute('SELECT key, value FROM app_settings').fetchall())
r = c.put('/api/settings', data=json.dumps({'banner_text': 'CHANGED', 'syslog_port': '65536'}), headers=H)
print('code=%d' % r.status_code)
print('body=%s' % json.dumps(r.get_json(), sort_keys=True))
after = dict(db().execute('SELECT key, value FROM app_settings').fetchall())
print('unchanged=%s' % (before == after))
n = db().execute(\"SELECT COUNT(*) FROM audit_log WHERE action='SETTINGS_UPDATE'\").fetchone()[0]
print('audits=%d' % n)
r = c.put('/api/settings', data=json.dumps({'syslog_protocol': 'TCP', 'syslog_enabled': True,
    'syslog_host': 'logs.example.org', 'syslog_port': 514}), headers=H)
print('code2=%d' % r.status_code)
st = dict(db().execute('SELECT key, value FROM app_settings').fetchall())
print('stored=%s,%s,%s' % (st.get('syslog_protocol'), st.get('syslog_enabled'), st.get('syslog_port')))
d = db().execute(\"SELECT detail FROM audit_log WHERE action='SETTINGS_UPDATE' ORDER BY id DESC\").fetchone()[0]
print('detail=%s' % d)
")"
    tm_assert_eq "code=400" "$(grep '^code=' <<<"$out")" "an out-of-range port was accepted: ${out}"
    tm_assert_eq 'body={"error": "invalid", "field": "syslog_port", "reason": "must be from 1 to 65535"}' \
        "$(grep '^body=' <<<"$out")" "the 400 body is not the contract's {error, field, reason}"
    tm_assert_eq "unchanged=True" "$(grep '^unchanged=' <<<"$out")" \
        "a refused PUT still wrote the VALID key beside the invalid one (a half-applied change)"
    tm_assert_eq "audits=0" "$(grep '^audits=' <<<"$out")" "a refused PUT was audited as a change"
    tm_assert_eq "code2=200" "$(grep '^code2=' <<<"$out")" "a valid admin PUT failed: ${out}"
    tm_assert_eq "stored=tcp,true,514" "$(grep '^stored=' <<<"$out")" "values are not stored in normalised form"
    grep -q "^detail=.*syslog_host: '' -> 'logs.example.org'" <<<"$out" \
        || _tm_afail "the audit record does not show the collector the audit trail was pointed at: ${out}"
}
tm_case "put-validates-every-admin-key-and-writes-nothing-on-refusal" tmapp a_put_refuses_and_writes_nothing

# ─── session limit precedence ────────────────────────────────────────────────
_sessions_probe='
from tm import routes
from tm.models import create_session
d = db()
print("stored=%s" % d.execute("SELECT value FROM app_settings WHERE key=%r" % "session_max_concurrent").fetchone())
from unittest import mock
import tm.auth
tm.auth.validate_credentials = lambda cfg, u, p: (True, {"username": "alice", "display_name": "A"})
codes = []
for i in range(4):
    cl = app.test_client()
    r = cl.post("/api/auth/login", data=json.dumps({"username": "alice", "password": "x"}), headers=H)
    codes.append(r.status_code)
print("codes=%s" % ",".join(map(str, codes)))
print("warned=%s" % ("Settings wins" in logbuf.getvalue()))
'

a_fresh_default_is_three() {
    _setup ""
    local out; out="$(_app "$_sessions_probe")"
    tm_assert_eq "stored=3" "$(grep '^stored=' <<<"$out")" "a fresh install does not default the session limit to 3: ${out}"
    tm_assert_eq "codes=200,200,200,429" "$(grep '^codes=' <<<"$out")" \
        "the fourth concurrent sign-in was not refused at the default limit of 3: ${out}"
}
tm_case "session-limit-fresh-default-is-3-and-enforced" tmapp a_fresh_default_is_three

a_config_seeds_once_then_settings_win() {
    _setup "  max_concurrent: 2"
    local out
    out="$(_app "$_sessions_probe")"
    tm_assert_eq "stored=2" "$(grep '^stored=' <<<"$out")" "config.yaml did not SEED the limit on first start: ${out}"
    tm_assert_eq "codes=200,200,429,429" "$(grep '^codes=' <<<"$out")" "the seeded limit of 2 was not enforced: ${out}"
    # The operator changes it in Settings; config.yaml still says 2.
    "$PY" -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute(\"UPDATE app_settings SET value='4' WHERE key='session_max_concurrent'\"); d.execute('DELETE FROM sessions'); d.commit()" "${TM_TMP}/tm.db"
    out="$(_app "$_sessions_probe")"
    tm_assert_eq "stored=4" "$(grep '^stored=' <<<"$out")" \
        "a restart re-seeded from config.yaml and REVERTED the operator's Settings value: ${out}"
    tm_assert_eq "codes=200,200,200,200" "$(grep '^codes=' <<<"$out")" \
        "the Settings value (4) did not win over config.yaml (2): ${out}"
    tm_assert_eq "warned=True" "$(grep '^warned=' <<<"$out")" \
        "the config.yaml/Settings disagreement was not logged at start"
}
tm_case "session-limit-config-seeds-once-then-settings-win" tmapp a_config_seeds_once_then_settings_win

tm_finish
