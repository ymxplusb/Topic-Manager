#!/usr/bin/env bash
# =============================================================================
# t50 — v1.3.0 THE CONSENT NOTICE, ENFORCED BY THE SERVER (James 2026-10-02,
# DQ9; NGNX-APP-000180).
#
#   server     while the notice is on, POST /api/auth/login is refused (403
#              consent_required) without a fresh acceptance, BEFORE the
#              directory is asked; an acceptance serves one sign-in and is
#              recorded as CONSENT_ACCEPTED just before LOGIN
#   text       the operator's replacement text is validated, served on the
#              public route, recorded by digest, and named by the acceptance
#   page       the sign-in page shows the notice before the form, posts the
#              acceptance before the sign-in, and shows the custom text
#   install    a fresh install turns it ON, a reinstall keeps what is saved,
#              --no-consent-banner turns it off
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "v1.3.0 consent: refused without acceptance, one acceptance per sign-in, audited, custom text, fresh install ON"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_setup() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs" "${TM_TMP}/data"
    printf 'clusters: []\n' > "${TM_TMP}/clusters.d/clusters.yaml"
    cat > "${TM_TMP}/config.yaml" <<YAML
server:
  secret_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
auth:
  ldap_server: "ldaps://dc1.example.org:636"
  ldap_domain: "example.org"
  ldap_base_dn: "DC=example,DC=org"
  required_group: "CN=G,DC=example,DC=org"
session:
  timeout_minutes: 30
audit:
  db_path: "${TM_TMP}/data/tm.db"
logging:
  log_level: "CRITICAL"
YAML
}

_app() {
    cat > "${TM_TMP}/probe.py" <<PYEOF
import json, os, sqlite3, time, hashlib
from tm import auth, routes
tried = []
def fake(cfg, u, p):
    tried.append(u); return (True, {'username': u, 'display_name': u})
auth.validate_credentials = fake
from tm.app import create_app
app = create_app()
def db(): return sqlite3.connect(os.environ['TM_TEST_DB'])
def setting(k, v):
    d = db(); d.execute('INSERT OR REPLACE INTO app_settings VALUES (?,?)', (k, v)); d.commit(); d.close()
def rows(*actions):
    d = db(); r = d.execute('SELECT action, user, detail FROM audit_log WHERE action IN (%s) ORDER BY id' % ','.join('?' * len(actions)), actions).fetchall(); d.close(); return r
H = {'Content-Type': 'application/json', 'X-TM-Request': '1'}
cred = json.dumps({'username': 'alice', 'password': 'pw'})
$1
PYEOF
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 \
        TM_CONFIG="${TM_TMP}/config.yaml" TM_TEST_DB="${TM_TMP}/data/tm.db" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" \
        "$PY" "${TM_TMP}/probe.py" 2> "${TM_TMP}/probe.err" | tr -d '\r'
}

_line() { grep "^$1=" <<<"$2"; }

a_server_enforces() {
    _setup
    local out
    out="$(_app "
c = app.test_client()
print('off=%d' % c.post('/api/auth/login', data=cred, headers=H).status_code)
setting('dow_enabled', 'true')
c = app.test_client()
r = c.post('/api/auth/login', data=cred, headers=H)
print('refused=%d %s tried=%d' % (r.status_code, r.get_json().get('code'), len(tried)))
print('declined=%d' % c.post('/api/auth/consent', data=json.dumps({'accepted': 'yes'}), headers=H).status_code)
print('csrf=%d' % c.post('/api/auth/consent', data=json.dumps({'accepted': True}), headers={'Content-Type': 'application/json'}).status_code)
print('accept=%d' % c.post('/api/auth/consent', data=json.dumps({'accepted': True}), headers=H).status_code)
r = c.post('/api/auth/login', data=cred, headers=H)
print('signin=%d' % r.status_code)
import datetime
end = datetime.datetime.fromisoformat(r.get_json()['session_ends_at'])
print('ends_h=%.0f' % ((end - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 3600))
print('rows=%s' % [(a, u) for a, u, _ in rows('CONSENT_ACCEPTED', 'LOGIN')])
print('detail=%s' % rows('CONSENT_ACCEPTED')[0][2].split(' accepted ')[0])
c.post('/api/auth/logout', data='{}', headers=H)
print('reuse=%d' % c.post('/api/auth/login', data=cred, headers=H).status_code)
c2 = app.test_client()
c2.post('/api/auth/consent', data=json.dumps({'accepted': True}), headers=H)
with c2.session_transaction() as s:
    s['consent'] = dict(s['consent'], at=time.time() - 601)
print('stale=%d' % c2.post('/api/auth/login', data=cred, headers=H).status_code)
print('consent_rows=%d' % len(rows('CONSENT_ACCEPTED')))
")"
    tm_assert_eq "off=200" "$(_line off "$out")" "with the notice off a sign-in was refused: ${out}"
    tm_assert_eq "refused=403 consent_required tried=1" "$(_line refused "$out")" \
        "a sign-in without the acceptance was let through, or the directory was asked first: ${out}"
    tm_assert_eq "declined=400" "$(_line declined "$out")" "an acceptance that is not literally true was taken"
    tm_assert_eq "csrf=403" "$(_line csrf "$out")" "a cross-site acceptance was taken"
    tm_assert_eq "accept=200" "$(_line accept "$out")" "an acceptance was refused"
    tm_assert_eq "signin=200" "$(_line signin "$out")" "a sign-in after the acceptance was refused: ${out}"
    tm_assert_eq "ends_h=12" "$(_line ends_h "$out")" "the sign-in does not tell the browser when the session ends"
    tm_assert_eq "rows=[('LOGIN', 'alice'), ('CONSENT_ACCEPTED', 'alice'), ('LOGIN', 'alice')]" "$(_line rows "$out")" \
        "CONSENT_ACCEPTED is not recorded for the user, just before LOGIN: ${out}"
    tm_assert_eq "detail=standard DoD notice" "$(_line detail "$out")" "the acceptance does not name the notice"
    tm_assert_eq "reuse=403" "$(_line reuse "$out")" "one acceptance served a second sign-in"
    tm_assert_eq "stale=403" "$(_line stale "$out")" "an acceptance older than its window was taken"
    tm_assert_eq "consent_rows=1" "$(_line consent_rows "$out")" "a refused sign-in recorded a consent"
}
tm_case "the-server-refuses-a-sign-in-without-a-fresh-acceptance" tmapp a_server_enforces

a_custom_text() {
    _setup
    local out
    out="$(_app "
c = app.test_client()
with c.session_transaction() as s:
    s['user'] = {'username': 'admin'}; s['sid'] = 'sa'
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
d = db(); d.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('sa', 'admin', now.isoformat(), now.isoformat(), (now + datetime.timedelta(hours=1)).isoformat(), 'x')); d.commit(); d.close()
put = lambda body: c.put('/api/settings', data=json.dumps(body), headers=H)
print('ctrl=%d' % put({'dow_text': 'a\tb'}).status_code)
print('long=%d' % put({'dow_text': 'x' * 4001}).status_code)
print('bool=%d' % put({'dow_enabled': 'maybe'}).status_code)
text = 'NOTICE ONE\r\n\r\nParagraph two.'
print('ok=%d' % put({'dow_text': text, 'dow_enabled': True}).status_code)
pub = app.test_client().get('/api/settings/public').get_json()
print('public=%r %s' % (pub['dow_text'], pub['dow_enabled']))
det = rows('SETTINGS_UPDATE')[-1][2]
digest = hashlib.sha256('NOTICE ONE\n\nParagraph two.'.encode()).hexdigest()[:16]
print('digest=%s plain=%s' % (digest in det, 'NOTICE ONE' in det))
a = app.test_client()
a.post('/api/auth/consent', data=json.dumps({'accepted': True}), headers=H)
a.post('/api/auth/login', data=cred, headers=H)
print('named=%s' % (('custom notice sha256=' + digest) in rows('CONSENT_ACCEPTED')[-1][2]))
")"
    tm_assert_eq "ctrl=400" "$(_line ctrl "$out")" "a control character in the notice text was stored"
    tm_assert_eq "long=400" "$(_line long "$out")" "a notice text over 4000 characters was stored"
    tm_assert_eq "bool=400" "$(_line bool "$out")" "dow_enabled took a value that is not true/false"
    tm_assert_eq "ok=200" "$(_line ok "$out")" "a valid notice text was refused: ${out}"
    tm_assert_eq "public='NOTICE ONE\n\nParagraph two.' true" "$(_line public "$out")" \
        "the public route does not serve the normalised notice text (the sign-in page needs it)"
    tm_assert_eq "digest=True plain=False" "$(_line digest "$out")" "SETTINGS_UPDATE records the notice text instead of its digest"
    tm_assert_eq "named=True" "$(_line named "$out")" "the acceptance does not name the custom notice it accepted"
}
tm_case "the-notice-text-is-validated-public-and-recorded-by-digest" tmapp a_custom_text

# The sign-in page, executed: the real component under node, fetch stubbed.
a_login_page() {
    local js; js="$(tm_loginview_js)"
    node - "$js" <<'JSEOF' > "${TM_TMP}/out" 2>&1 || _tm_afail "$(cat "${TM_TMP}/out")"
const fs = require('fs'), assert = require('assert');
const src = fs.readFileSync(process.argv[2], 'utf8');
const def = new Function('Vue', 'window', src + String.fromCharCode(10) + 'return LoginView;')({}, { location: { hostname: 'h' } });
const settle = () => new Promise(r => setTimeout(r, 20));   // submit() does not await the sign-in
const run = async (pub, loginAnswers) => {
    const calls = [];
    global.fetch = async (url, opts = {}) => {
        calls.push(url + ' ' + (opts.method || 'GET'));
        if (url === '/api/settings/public') return { ok: true, status: 200, json: async () => pub };
        if (url === '/api/auth/consent') return { ok: true, status: 200, json: async () => ({ ok: true }) };
        const a = loginAnswers.shift();
        return { ok: a[0] < 400, status: a[0], json: async () => a[1] };
    };
    const vm = Object.assign({}, def.data(), { username: 'u', password: 'p', emitted: [] });
    vm.$emit = (...a) => vm.emitted.push(a);
    for (const [k, f] of Object.entries(def.methods)) vm[k] = f.bind(vm);
    Object.defineProperty(vm, 'consentParagraphs', { get: () => def.computed.consentParagraphs.call(vm) });
    await def.mounted.call(vm);
    return { vm, calls };
};
(async () => {
    let { vm, calls } = await run({ dow_enabled: 'true', dow_text: '' }, [[200, { user: { username: 'u' }, timeout_minutes: 15, session_ends_at: 'E' }]]);
    assert.equal(vm.showConsent, true, 'the notice is not shown before the form');
    await vm.submit();
    assert.ok(!calls.some(c => c.startsWith('/api/auth/login')), 'a sign-in was posted before the acceptance');
    vm.cancelConsent();
    assert.match(vm.error, /accept the notice/, 'declining says why there is no sign-in');
    await vm.agreeConsent();
    assert.equal(vm.consentAccepted, true);
    await vm.submit(); await settle();
    assert.deepEqual(calls.filter(c => c.startsWith('/api/auth/')), ['/api/auth/consent POST', '/api/auth/login POST'], 'the acceptance is not posted before the sign-in');
    assert.deepEqual(JSON.parse(JSON.stringify(vm.emitted)), [['logged-in', { username: 'u' }, 15, 'E']], 'the session end is not handed to the app: ' + JSON.stringify(vm.emitted));
    ({ vm, calls } = await run({ dow_enabled: 'true' }, [[403, { error: 'Read and accept', code: 'consent_required' }]]));
    await vm.agreeConsent();
    await vm.submit(); await settle();
    assert.equal(vm.showConsent, true, 'a 403 consent_required does not show the notice again');
    assert.equal(vm.consentAccepted, false);
    ({ vm } = await run({ dow_enabled: 'true', dow_text: 'ONE\n\n  TWO  \n\n\n' }, []));
    assert.deepEqual(vm.consentParagraphs, ['ONE', 'TWO'], 'the custom text is not split into paragraphs');
    ({ vm, calls } = await run({ dow_enabled: 'false' }, [[200, { user: {}, timeout_minutes: 15 }]]));
    assert.equal(vm.showConsent, false, 'the notice shows while it is off');
    await vm.submit(); await settle();
    assert.ok(calls.includes('/api/auth/login POST') && !calls.includes('/api/auth/consent POST'), 'with the notice off the sign-in is not direct');
    console.log('LOGIN PAGE OK');
})().catch(e => { console.error(e.message); process.exit(1); });
JSEOF
    tm_assert_eq "LOGIN PAGE OK" "$(tr -d '\r' < "${TM_TMP}/out")" "the sign-in page does not handle the notice as the server requires"
    grep -q '<p v-for="(para, i) in consentParagraphs"' "$js" || _tm_afail "the template does not render the custom paragraphs"
    grep -q 'You are accessing a U.S. Government (USG) Information System' "$js" || _tm_afail "the standard DoD wording is gone"
}
tm_case "the-sign-in-page-shows-the-notice-first-and-posts-the-acceptance" node a_login_page

# install.sh: ON on a fresh install, kept on a reinstall, OFF on request.
a_install_seeds_consent() {
    local blk; blk="$(tm_extract_between "$(tm_install_sh)" '^if \[\[ "\$OPT_CONSENT" == false \]\]; then$' '^fi   # the consent seed \(t50\)$')"
    local case_ db_exists flag got
    for case_ in "fresh::dow_enabled=true" "fresh:false:dow_enabled=false" "existing::" "existing:false:dow_enabled=false"; do
        IFS=: read -r db_exists flag want <<<"$case_"
        got="$(DATA_DIR="${TM_TMP}/d-${db_exists}" OPT_CONSENT="$flag" bash -c "
            mkdir -p \"\$DATA_DIR\"; [ ${db_exists} = existing ] && : > \"\$DATA_DIR/tm.db\"
            SEED_PAIRS=()
            ${blk}
            echo \"\${SEED_PAIRS[*]}\"")"
        tm_assert_eq "$want" "$got" "install.sh seeds the consent switch wrongly (${db_exists}, flag '${flag}')"
    done
    grep -q -- '--no-consent-banner) OPT_CONSENT=false ;;' "$(tm_install_sh)" || _tm_afail "install.sh has no --no-consent-banner flag"
}
tm_case "a-fresh-install-turns-the-notice-on-and-a-reinstall-keeps-it" none a_install_seeds_consent

# What install.sh runs for the seed: the application's own CLI.
a_seed_cli() {
    _setup
    local out
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
        TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" "$PY" -m tm.apply --config "${TM_TMP}/config.yaml" --by installer \
        seed dow_enabled=true session_absolute_hours=8 > "${TM_TMP}/seed.out" 2>&1 || _tm_afail "seed failed: $(cat "${TM_TMP}/seed.out")"
    out="$("$PY" -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); print(sorted(d.execute(\"SELECT key, value FROM app_settings WHERE key IN ('dow_enabled','session_absolute_hours')\").fetchall()))" "${TM_TMP}/data/tm.db" | tr -d '\r')"
    tm_assert_eq "[('dow_enabled', 'true'), ('session_absolute_hours', '8')]" "$out" "the installer's seed did not store the consent switch"
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
        TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" "$PY" -m tm.apply --config "${TM_TMP}/config.yaml" seed dow_enabled=maybe > "${TM_TMP}/seed.out" 2>&1 \
        && _tm_afail "the seed stored dow_enabled=maybe"
    true
}
tm_case "the-installers-seed-takes-the-consent-switch-and-validates-it" tmapp a_seed_cli

tm_finish
