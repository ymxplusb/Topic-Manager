#!/usr/bin/env bash
# =============================================================================
# t49 — v1.3.0 SESSIONS (James 2026-10-02, DQ8; SRG-APP-000295, NGNX-APP-003330).
#
#   absolute   a session ends at Settings' absolute lifetime (default 12 h)
#              however active it is, and SESSION_EXPIRED says so
#   recheck    every 15 minutes the user is looked up again: removed from the
#              group (or gone) ends every session of that user and records
#              SESSION_REVOKED; the directory unreachable leaves reads working
#              and refuses every write (503) until it answers, asked at most
#              once a minute; sign-out is never refused
#   end        an administrator ends a user's sessions, or everyone's but their
#              own, recorded as SESSIONS_ENDED; the list names sessions by a
#              one-way handle, never by their (bearer) id
#   directory  auth.check_membership maps the directory's answers to verdicts
#
# The real app through Flask's test client; the directory is stubbed at
# auth.check_membership (and, for the last case, at ldap3's Server/Connection).
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "v1.3.0 sessions: absolute lifetime, 15-minute group re-check, admin end, directory outage = reads only"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_setup() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs" "${TM_TMP}/data"
    printf 'clusters:\n  - id: c1\n    name: C1\n    bootstrap_servers: "h:9092"\n    security_protocol: PLAINTEXT\n    active: true\n' \
        > "${TM_TMP}/clusters.d/clusters.yaml"
    cat > "${TM_TMP}/config.yaml" <<YAML
server:
  secret_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
auth:
  ldap_server: "ldaps://dc1.example.org:636"
  ldap_domain: "example.org"
  ldap_base_dn: "DC=example,DC=org"
  required_group: "CN=G,DC=example,DC=org"
  ldap_bind_dn: "CN=svc,DC=example,DC=org"
  ldap_bind_password: "not-a-placeholder"
session:
  timeout_minutes: 30
audit:
  db_path: "${TM_TMP}/data/tm.db"
logging:
  log_level: "CRITICAL"
YAML
}

# _app <body>: `client(user, sid, created_ago_h, verified_ago_min)` makes a
# signed-in test client; `verdicts` drives the stubbed directory, `asked`
# counts its calls; rows(action) reads the audit trail.
_app() {
    cat > "${TM_TMP}/probe.py" <<PYEOF
import json, os, sqlite3, datetime
from tm import auth, kafka_client
kafka_client.delete_topic = lambda c, n: None
auth.validate_credentials = lambda cfg, u, p: (True, {'username': u, 'display_name': u})
verdicts = {}
asked = []
def fake_check(cfg, username):
    asked.append(username)
    return verdicts.get(username, ('member', ''))
auth.check_membership = fake_check
from tm.app import create_app
app = create_app()
now = datetime.datetime.now(datetime.timezone.utc)
def db(): return sqlite3.connect(os.environ['TM_TEST_DB'])
def rows(action):
    d = db(); r = d.execute('SELECT user, target, detail, outcome FROM audit_log WHERE action=? ORDER BY id', (action,)).fetchall(); d.close(); return r
def client(user, sid, created_ago_h=0.0, verified_ago_min=None):
    cl = app.test_client()
    with cl.session_transaction() as s:
        s['user'] = {'username': user}; s['sid'] = sid
    created = now - datetime.timedelta(hours=created_ago_h)
    d = db()
    d.execute('INSERT OR REPLACE INTO sessions VALUES (?,?,?,?,?,?)', (sid, user, created.isoformat(), created.isoformat(), (now + datetime.timedelta(hours=1)).isoformat(), '192.0.2.5'))
    if verified_ago_min is not None:
        d.execute('INSERT OR REPLACE INTO session_meta (id, verified_at) VALUES (?, ?)', (sid, (now - datetime.timedelta(minutes=verified_ago_min)).isoformat()))
    d.commit(); d.close()
    return cl
def cookie(user, sid):            # a browser holding that session's cookie, the row untouched
    cl = app.test_client()
    with cl.session_transaction() as s:
        s['user'] = {'username': user}; s['sid'] = sid
    return cl
H = {'Content-Type': 'application/json', 'X-TM-Request': '1'}
$1
PYEOF
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 \
        TM_CONFIG="${TM_TMP}/config.yaml" TM_TEST_DB="${TM_TMP}/data/tm.db" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" \
        "$PY" "${TM_TMP}/probe.py" 2> "${TM_TMP}/probe.err" | tr -d '\r'
}

_line() { grep "^$1=" <<<"$2"; }

a_absolute_lifetime() {
    _setup
    local out
    out="$(_app "
young = client('alice', 's-young', created_ago_h=11.5, verified_ago_min=1)
old = client('bob', 's-old', created_ago_h=12.5, verified_ago_min=1)
print('young=%d' % young.get('/api/settings').status_code)
r = old.get('/api/settings')
print('old=%d %s' % (r.status_code, r.get_json().get('reason')))
print('expired=%s' % rows('SESSION_EXPIRED'))
w = young.get('/api/auth/whoami').get_json()
end = datetime.datetime.fromisoformat(w['session_ends_at'])
print('ends_in_h=%.1f' % ((end - now).total_seconds() / 3600))
d = db(); d.execute(\"INSERT OR REPLACE INTO app_settings VALUES ('session_absolute_hours', '2')\"); d.commit(); d.close()
r = client('carol', 's-3h', created_ago_h=3, verified_ago_min=1).get('/api/settings')
print('setting=%d %s' % (r.status_code, r.get_json().get('reason')))
print('bg=%d' % young.get('/api/settings', headers={'X-TM-Background': '1'}).status_code)
")"
    tm_assert_eq "young=200" "$(_line young "$out")" "a session inside its lifetime was refused: ${out}"
    tm_assert_eq "old=401 absolute" "$(_line old "$out")" "a 12.5-hour session was not ended by the 12-hour lifetime: ${out}"
    tm_assert_eq "expired=[('bob', '127.0.0.1', 'absolute session lifetime reached', 'success')]" \
        "$(_line expired "$out")" "SESSION_EXPIRED does not say the absolute lifetime ended it"
    tm_assert_eq "ends_in_h=0.5" "$(_line ends_in_h "$out")" "whoami does not say when the session ends"
    tm_assert_eq "setting=401 absolute" "$(_line setting "$out")" "the lifetime is not Settings' value"
    tm_assert_eq "bg=401" "$(_line bg "$out")" "a session past the setting's lifetime still answered"
}
tm_case "a-session-ends-at-its-absolute-lifetime-however-active" tmapp a_absolute_lifetime

a_group_recheck() {
    _setup
    local out
    out="$(_app "
fresh = client('alice', 's-fresh', verified_ago_min=5)
print('fresh=%d asked=%s' % (fresh.get('/api/settings').status_code, asked))
new = client('alice', 's-new')                     # no re-check yet: the sign-in verified it
print('new=%d asked=%s' % (new.get('/api/settings').status_code, asked))
stale = client('alice', 's-stale', verified_ago_min=20)
print('member=%d asked=%s' % (stale.get('/api/settings').status_code, asked))
d = db(); v = d.execute(\"SELECT verified_at FROM session_meta WHERE id='s-stale'\").fetchone()[0]; d.close()
print('moved=%s' % (datetime.datetime.fromisoformat(v) > now - datetime.timedelta(minutes=1)))
asked.clear()
removed = client('mallory', 's-m1', verified_ago_min=20)
other = client('mallory', 's-m2', verified_ago_min=1)
verdicts['mallory'] = ('not_member', 'no longer a member of the required group')
r = removed.get('/api/settings')
print('revoked=%d %s' % (r.status_code, r.get_json().get('reason')))
print('revoked_row=%s' % rows('SESSION_REVOKED'))
r = other.get('/api/settings')
print('other=%d %s' % (r.status_code, r.get_json().get('reason')))
print('expired_reason=%s' % rows('SESSION_EXPIRED')[-1][2])
verdicts['gone'] = ('not_found', 'the account is no longer in the directory')
print('gone=%d' % client('gone', 's-g', verified_ago_min=20).get('/api/settings').status_code)
")"
    tm_assert_eq "fresh=200 asked=[]" "$(_line fresh "$out")" "a session verified 5 minutes ago was re-checked (or refused): ${out}"
    tm_assert_eq "new=200 asked=[]" "$(_line new "$out")" "a session signed in just now was re-checked at once (its sign-in verified it)"
    tm_assert_eq "member=200 asked=['alice']" "$(_line member "$out")" "a session verified 20 minutes ago was not re-checked"
    tm_assert_eq "moved=True" "$(_line moved "$out")" "a successful re-check did not move verified_at"
    tm_assert_eq "revoked=401 revoked" "$(_line revoked "$out")" "a user removed from the group kept the session: ${out}"
    tm_assert_eq "revoked_row=[('mallory', '127.0.0.1', 'no longer a member of the required group; 2 session(s) ended', 'success')]" \
        "$(_line revoked_row "$out")" "SESSION_REVOKED does not record the reason and the sessions ended"
    tm_assert_eq "other=401 ended" "$(_line other "$out")" "the removed user's OTHER session (re-checked recently) survived"
    tm_assert_eq "expired_reason=revoked: no longer a member of the required group" "$(_line expired_reason "$out")" \
        "the other session's end does not say why"
    tm_assert_eq "gone=401" "$(_line gone "$out")" "a deleted account kept its session"
}
tm_case "removal-from-the-group-ends-every-session-of-the-user" tmapp a_group_recheck

a_directory_outage() {
    _setup
    local out
    out="$(_app "
verdicts['alice'] = ('unavailable', 'LDAPSocketOpenError: unreachable')
c = client('alice', 's-a', verified_ago_min=20)
print('read=%d asked=%d' % (c.get('/api/settings').status_code, len(asked)))
r = c.put('/api/settings', data=json.dumps({'banner_text': 'x'}), headers=H)
print('write=%d %s asked=%d' % (r.status_code, r.get_json().get('code'), len(asked)))
print('refused=%s' % [d for _, _, d, _ in rows('REQUEST_REFUSED')])
print('changed=%d' % len(rows('SETTINGS_UPDATE')))
print('delete=%d' % c.delete('/api/topics/orders', headers=H).status_code)
d = db(); d.execute(\"UPDATE session_meta SET verify_attempt_at=? WHERE id='s-a'\", ((now - datetime.timedelta(minutes=2)).isoformat(),)); d.commit(); d.close()
verdicts['alice'] = ('member', '')
r = c.put('/api/settings', data=json.dumps({'banner_text': 'y'}), headers=H)
print('recovered=%d asked=%d' % (r.status_code, len(asked)))
verdicts['alice'] = ('unavailable', 'down')
d = db(); d.execute(\"UPDATE session_meta SET verified_at=?, verify_attempt_at=? WHERE id='s-a'\", ((now - datetime.timedelta(minutes=30)).isoformat(), (now - datetime.timedelta(minutes=30)).isoformat())); d.commit(); d.close()
c.get('/api/settings')
print('logout=%d' % c.post('/api/auth/logout', data='{}', headers=H).status_code)
")"
    tm_assert_eq "read=200 asked=1" "$(_line read "$out")" "a read was refused while the directory was down: ${out}"
    tm_assert_eq "write=503 directory_unavailable asked=1" "$(_line write "$out")" \
        "a write was allowed while the directory was down, or the directory was asked again within the minute: ${out}"
    tm_assert_eq "refused=['PUT api.update_settings -> HTTP 503: directory_unavailable']" "$(_line refused "$out")" \
        "the refused write is not recorded as a signed-in failure"
    tm_assert_eq "changed=0" "$(_line changed "$out")" "the settings changed while writes were refused"
    tm_assert_eq "delete=503" "$(_line delete "$out")" "a topic delete was allowed while the directory was down"
    tm_assert_eq "recovered=200 asked=2" "$(_line recovered "$out")" "writes did not resume once the directory answered"
    tm_assert_eq "logout=200" "$(_line logout "$out")" "sign-out was refused during a directory outage"
}
tm_case "a-directory-outage-allows-reads-and-refuses-every-write" tmapp a_directory_outage

a_end_sessions() {
    _setup
    local out
    out="$(_app "
admin = client('admin', 'sid-admin-secret', verified_ago_min=1)
admin2 = client('admin', 'sid-admin-other', verified_ago_min=1)
bob = client('bob', 'sid-bob-secret', verified_ago_min=1)
carol = client('carol', 'sid-carol-secret', verified_ago_min=1)
r = admin.get('/api/sessions')
lst = r.get_json()['sessions']
print('listed=%d %s' % (len(lst), sorted(s['user'] for s in lst)))
print('noid=%s' % ('sid-' not in r.get_data(as_text=True)))
print('current=%s' % [s['user'] for s in lst if s['current']])
print('bad=%d' % admin.post('/api/sessions/end', data=json.dumps({'user': 'bob', 'all': True}), headers=H).status_code)
print('bad2=%d' % admin.post('/api/sessions/end', data=json.dumps({}), headers=H).status_code)
r = admin.post('/api/sessions/end', data=json.dumps({'user': 'BOB'}), headers=H)
print('user=%d %s' % (r.status_code, r.get_json().get('ended')))
r = bob.get('/api/settings')
print('bob=%d %s' % (r.status_code, r.get_json().get('reason')))
print('bob_reason=%s' % rows('SESSION_EXPIRED')[-1][2])
# A sign-in in between cleans expired rows: bob's ended row must survive it
# long enough for its next request to be told WHY.
app.test_client().post('/api/auth/login', data=json.dumps({'username': 'dave', 'password': 'p'}), headers=H)
print('kept_reason=%s' % cookie('bob', 'sid-bob-secret').get('/api/settings').get_json().get('reason'))
print('carol_before=%d' % carol.get('/api/settings').status_code)
r = admin.post('/api/sessions/end', data=json.dumps({'all': True}), headers=H)
print('all=%d %s' % (r.status_code, r.get_json().get('ended')))
print('carol=%d admin2=%d admin=%d' % (carol.get('/api/settings').status_code, admin2.get('/api/settings').status_code, admin.get('/api/settings').status_code))
print('ended_rows=%s' % [(u, t, d) for u, t, d, _ in rows('SESSIONS_ENDED')])
")"
    tm_assert_eq "listed=4 ['admin', 'admin', 'bob', 'carol']" "$(_line listed "$out")" "the session list is wrong: ${out}"
    tm_assert_eq "noid=True" "$(_line noid "$out")" "the session list exposes a session id (a bearer secret)"
    tm_assert_eq "current=['admin']" "$(_line current "$out")" "the caller's own session is not marked"
    tm_assert_eq "bad=400" "$(_line bad "$out")" "a body naming a user AND all was accepted"
    tm_assert_eq "bad2=400" "$(_line bad2 "$out")" "an empty body was accepted"
    tm_assert_eq "user=200 1" "$(_line user "$out")" "ending bob's sessions (named in another case) did not end exactly one"
    tm_assert_eq "bob=401 ended" "$(_line bob "$out")" "bob's ended session still answered"
    tm_assert_eq "bob_reason=ended by admin" "$(_line bob_reason "$out")" "the ended session's next request does not say who ended it"
    tm_assert_eq "kept_reason=ended" "$(_line kept_reason "$out")" "an ended session's row was cleaned before it could say why"
    tm_assert_eq "carol_before=200" "$(_line carol_before "$out")" "ending bob's sessions ended carol's"
    tm_assert_eq "all=200 3" "$(_line all "$out")" "ending everyone's did not end exactly the three others (carol, admin's other, dave)"
    tm_assert_eq "carol=401 admin2=401 admin=200" "$(_line carol "$out")" "ending all sessions ended the caller's own or missed one"
    tm_assert_eq "ended_rows=[('admin', 'BOB', 'ended 1 session(s) of BOB; the caller kept their own'), ('admin', 'every user', 'ended 3 session(s) of every user; the caller kept their own')]" \
        "$(_line ended_rows "$out")" "SESSIONS_ENDED does not record who ended what"
}
tm_case "an-administrator-ends-a-users-or-everyones-sessions" tmapp a_end_sessions

a_check_membership() {
    _setup
    local out
    out="$(PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 "$PY" - <<'PYEOF' 2>&1 | tr -d '\r'
from tm import auth
from ldap3.core.exceptions import LDAPSocketOpenError
class Entry:
    def __init__(self, groups):
        class V: pass
        self.memberOf = V(); self.memberOf.values = groups
state = {}
class FakeServer:
    def __init__(self, *a, **k): state['server_kw'] = k
class FakeConn:
    def __init__(self, server, user=None, password=None, authentication=None, auto_bind=None, **k):
        state['conn_kw'] = k
        if state.get('down'): raise LDAPSocketOpenError('unreachable')
        self.entries = state.get('entries', [])
    def search(self, **k): pass
    def unbind(self): pass
auth.Server, auth.Connection = FakeServer, FakeConn
cfg = {'auth': {'ldap_server': 'ldaps://dc.example.org:636', 'ldap_base_dn': 'DC=example,DC=org',
                'ldap_domain': 'example.org', 'required_group': 'CN=G,DC=example,DC=org',
                'ldap_bind_dn': 'CN=svc,DC=example,DC=org', 'ldap_bind_password': 'pw'}}
state['entries'] = [Entry(['CN=G,DC=example,DC=org'])]
print('member=%s' % auth.check_membership(cfg, 'alice')[0])
print('bounded=%s %s' % (state['server_kw'].get('connect_timeout'), state['conn_kw'].get('receive_timeout')))
state['entries'] = [Entry(['CN=Other,DC=example,DC=org'])]
print('not_member=%s' % auth.check_membership(cfg, 'alice')[0])
state['entries'] = []
print('not_found=%s' % auth.check_membership(cfg, 'alice')[0])
state['down'] = True
print('unavailable=%s' % auth.check_membership(cfg, 'alice')[0])
del cfg['auth']['ldap_bind_dn']
print('unsupported=%s' % auth.check_membership(cfg, 'alice')[0])
PYEOF
)"
    tm_assert_eq "member=member" "$(_line member "$out")" "a member is not 'member': ${out}"
    tm_assert_eq "bounded=5 5" "$(_line bounded "$out")" "the re-check's directory calls are not time-bounded (it runs inside a request)"
    tm_assert_eq "not_member=not_member" "$(_line not_member "$out")" "a removed member is not 'not_member'"
    tm_assert_eq "not_found=not_found" "$(_line not_found "$out")" "a deleted account is not 'not_found'"
    tm_assert_eq "unavailable=unavailable" "$(_line unavailable "$out")" "an unreachable directory is not 'unavailable'"
    tm_assert_eq "unsupported=unsupported" "$(_line unsupported "$out")" "a host with no service account is not 'unsupported'"
}
tm_case "the-directory-answers-map-to-the-four-verdicts" tmapp a_check_membership

# The browser's half: app/main.js arms a sign-out at the absolute end the
# server sent, a few seconds early, and says why. The real file under node.
a_browser_signs_out_at_the_absolute_end() {
    local out
    out="$(node - "${TM_MAIN_JS:-${TM_REPO_ROOT}/app/main.js}" <<'JSEOF' 2>&1 | tr -d '\r'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
let App = null, now = 1_000_000;
const timers = [], posts = [];
const win = { fetch: async (url, init) => { if (init && init.method === 'POST') posts.push([url, init.body]); return { ok: false, json: async () => ({}) }; } };
const Vue = { createApp: a => { App = a; return { mount() {} }; }, ref: v => ({ value: v }), computed: f => ({ get value() { return f(); } }), onMounted() {}, onUnmounted() {} };
const stubs = ['LoginView', 'TopBar', 'TopicsTab', 'ConsumerGroupsTab', 'AuditTab', 'SettingsTab', 'AboutModal'];
const g = { setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; }, clearTimeout: id => { if (timers[id - 1]) timers[id - 1].cleared = true; },
            setInterval: () => 0, clearInterval() {}, Date: { now: () => now, parse: Date.parse } };
// In a browser the components' bare fetch IS window.fetch (which main.js wraps).
new Function('Vue', 'window', 'document', 'fetch', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Date', ...stubs, src)(
    Vue, win, { addEventListener() {}, removeEventListener() {} }, (...a) => win.fetch(...a), g.setTimeout, g.clearTimeout, g.setInterval, g.clearInterval, g.Date, ...stubs.map(() => ({})));
const vm = App.setup();
const ends = new Date(now + 2 * 3600 * 1000).toISOString();
vm.onLoggedIn({ username: 'u' }, 15, ends);
const abs = timers.filter(t => !t.cleared && t.ms > 15 * 60 * 1000);
console.log('armed=' + abs.length + ' ms=' + (abs[0] && abs[0].ms));
(async () => {
  await abs[0].fn(); await new Promise(r => setImmediate(r));
  console.log('posted=' + JSON.stringify(posts));
  console.log('notice=' + vm.loginNotice.value);
  console.log('user=' + vm.user.value);
  timers.length = 0;
  vm.onLoggedIn({ username: 'u' }, 15, '');
  console.log('none=' + timers.filter(t => t.ms > 15 * 60 * 1000).length);
})();
JSEOF
)"
    tm_assert_eq "armed=1 ms=7195000" "$(grep '^armed=' <<<"$out")" "no sign-out is armed at the absolute end (minus the 5 s lead): ${out}"
    tm_assert_eq 'posted=[["/api/auth/logout","{\"reason\":\"absolute\"}"]]' "$(grep '^posted=' <<<"$out")" \
        "the absolute sign-out is not posted with its reason (the audit row would say 'explicit'): ${out}"
    case "$(grep '^notice=' <<<"$out")" in "notice=You were signed out because the session reached its maximum lifetime."*) ;;
        *) _tm_afail "the sign-in page is not told why: ${out}" ;; esac
    tm_assert_eq "user=null" "$(grep '^user=' <<<"$out")" "the browser stayed signed in"
    tm_assert_eq "none=0" "$(grep '^none=' <<<"$out")" "a timer was armed with no end from the server"
}
tm_case "the-browser-signs-out-at-the-absolute-end-and-says-why" node a_browser_signs_out_at_the_absolute_end

a_absolute_logout_reason() {
    _setup
    local out
    out="$(_app "
c = client('alice', 's-a', verified_ago_min=1)
c.post('/api/auth/logout', data=json.dumps({'reason': 'absolute'}), headers=H)
print('detail=%s' % rows('LOGOUT')[-1][2])
")"
    tm_assert_eq "detail=automatic sign-out at the absolute session lifetime" "$(_line detail "$out")" \
        "a sign-out at the absolute lifetime is recorded as something else: ${out}"
}
tm_case "an-absolute-sign-out-is-recorded-as-one" tmapp a_absolute_logout_reason

tm_finish
