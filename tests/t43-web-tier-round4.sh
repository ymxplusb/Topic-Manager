#!/usr/bin/env bash
# =============================================================================
# t43 — v1.2.0 ROUND 4: the web tier's answers to sec-review and the adversary.
#
#   csrf        every state-changing /api/ request must be marked as this
#               origin's own (Sec-Fetch-Site: same-origin, or X-TM-Request: 1
#               which the SPA adds); the multipart certificate upload, which
#               a plain HTML form on another site can send, included (CWE-352)
#   login       one answer for every failed sign-in; the audit row keeps the
#               specific reason (CWE-203)
#   per_page    the audit list is bounded; SQLite reads LIMIT -1 as "all"
#               (CWE-770)
#   case        "Alice", "alice" and "ALICE" are ONE session identity, and
#               rows written before that are migrated (CWE-178)
#   truthful    a failed audit write says where the record went, measured
#               (CWE-778)
#   unattended  a finished apply is audited with nobody polling (adversary F-03)
#
# Each case drives the REAL app through Flask's test client (or the real
# module), and each was run against the code before the fix and went red.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "round 4 web tier: CSRF, one login answer, bounded audit pages, one session identity, truthful audit failures"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_setup() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs" "${TM_TMP}/run" "${TM_TMP}/data" "${TM_TMP}/bin"
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
session:
  timeout_minutes: 30
audit:
  db_path: "${TM_TMP}/data/tm.db"
logging:
  log_level: "CRITICAL"
YAML
    printf '#!/usr/bin/env bash\nexit 0\n' > "${TM_TMP}/bin/systemctl"
    chmod 755 "${TM_TMP}/bin/systemctl"
}

# _run <python body>: `app`, `c` (signed in as admin), `anon`, `db()`, `rows()`
# in scope. Nothing reaches Kafka or LDAP: both are stubbed.
_run() {
    cat > "${TM_TMP}/probe.py" <<PYEOF
import json, os, sqlite3, datetime, io
from tm import auth, kafka_client, audit
kafka_client.delete_topic = lambda c, n: None
auth.validate_credentials = lambda cfg, u, p: (True, {'username': u, 'display_name': u})
from tm.app import create_app
app = create_app()
def db(): return sqlite3.connect(os.environ['TM_TEST_DB'])
def rows(action):
    d = db(); r = d.execute('SELECT user, detail FROM audit_log WHERE action=? ORDER BY id', (action,)).fetchall(); d.close(); return r
def signed_in(user='admin'):
    cl = app.test_client()
    with cl.session_transaction() as s:
        s['user'] = {'username': user}; s['sid'] = 'sid-' + user
    now = datetime.datetime.now(datetime.timezone.utc)
    d = db(); d.execute('INSERT OR REPLACE INTO sessions VALUES (?,?,?,?,?,?)', ('sid-' + user, user, now.isoformat(), now.isoformat(), (now + datetime.timedelta(hours=1)).isoformat(), 'x')); d.commit(); d.close()
    return cl
c = signed_in()
anon = app.test_client()
J = {'Content-Type': 'application/json'}
$1
PYEOF
    PATH="${TM_TMP}/bin:${PATH}" PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 \
        TM_CONFIG="${TM_TMP}/config.yaml" TM_TEST_DB="${TM_TMP}/data/tm.db" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        TM_APPLY_RESULT_DIR="${TM_TMP}/run" TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" \
        "$PY" "${TM_TMP}/probe.py" 2> "${TM_TMP}/probe.err" | tr -d '\r'
}

_line() { grep "^$1=" <<<"$2"; }

# ─── CSRF ────────────────────────────────────────────────────────────────────
a_csrf() {
    _setup
    local out
    out="$(_run "
put = lambda tag, h: c.put('/api/settings', data=json.dumps({'banner_text': tag}), headers={**J, **h}).status_code
print('none=%d' % put('none', {}))
print('samesite=%d' % put('samesite', {'Sec-Fetch-Site': 'same-site'}))
print('crosssite=%d' % put('crosssite', {'Sec-Fetch-Site': 'cross-site'}))
print('navigate=%d' % put('navigate', {'Sec-Fetch-Site': 'none'}))
print('header_but_crosssite=%d' % put('hbc', {'Sec-Fetch-Site': 'cross-site', 'X-TM-Request': '1'}))
print('wrongvalue=%d' % put('wrongvalue', {'X-TM-Request': 'yes'}))
print('sameorigin=%d' % put('sameorigin', {'Sec-Fetch-Site': 'same-origin'}))
print('header=%d' % put('header', {'X-TM-Request': '1'}))
print('changes=%s' % [d.split(' -> ')[-1] for _, d in rows('SETTINGS_UPDATE')])
# A plain HTML form on another site: multipart, no Fetch Metadata, no header.
form = {'cert': (io.BytesIO(b'x'), 'c.pem'), 'key': (io.BytesIO(b'y'), 'k.pem')}
r = c.post('/api/system/tls/cert', data=form, content_type='multipart/form-data')
print('form=%d' % r.status_code)
print('staged=%s' % os.path.exists(os.path.join(os.path.dirname(os.environ['TM_TEST_DB']), 'apply', 'tls.json')))
print('delete=%d' % c.delete('/api/topics/orders').status_code)
print('deleted_audited=%d' % len(rows('DELETE')))
print('login=%d' % anon.post('/api/auth/login', data=json.dumps({'username': 'u', 'password': 'p'}), headers=J).status_code)
print('logout=%d' % c.post('/api/auth/logout', data='{}', headers=J).status_code)
print('get=%d' % c.get('/api/settings').status_code)
")"
    local k
    for k in none samesite crosssite navigate header_but_crosssite wrongvalue form delete login logout; do
        tm_assert_eq "${k}=403" "$(_line "$k" "$out")" "a state-changing request without this origin's mark was accepted (${k}): ${out}"
    done
    tm_assert_eq "staged=False" "$(_line staged "$out")" "a cross-site form staged a certificate"
    tm_assert_eq "deleted_audited=0" "$(_line deleted_audited "$out")" "a cross-site DELETE reached Kafka"
    tm_assert_eq "sameorigin=200" "$(_line sameorigin "$out")" "a same-origin request was refused"
    tm_assert_eq "header=200" "$(_line header "$out")" "a request carrying X-TM-Request: 1 was refused"
    tm_assert_eq "changes=[\"'sameorigin'\", \"'header'\"]" "$(_line changes "$out")" \
        "the settings changed by something other than the two marked requests"
    tm_assert_eq "get=200" "$(_line get "$out")" "a GET was refused by the CSRF rule"
}
tm_case "state-changing-requests-need-this-origins-mark" tmapp a_csrf

# The SPA side: app/main.js wraps fetch so EVERY non-GET /api/ request carries
# X-TM-Request: 1. The real file, evaluated under node with a recording fetch.
a_spa_marks_its_requests() {
    local out
    out="$(node - "${TM_REPO_ROOT}/app/main.js" <<'JSEOF' 2>&1 | tr -d '\r'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const seen = [];
const win = { fetch: (input, init) => { seen.push([input, init]); return Promise.resolve({ ok: true, json: async () => ({}) }); } };
const Vue = { createApp: () => ({ mount() {} }), ref: v => ({ value: v }), computed: f => ({ value: undefined }), onMounted() {}, onUnmounted() {} };
const stubs = ['LoginView', 'TopBar', 'TopicsTab', 'ConsumerGroupsTab', 'AuditTab', 'SettingsTab', 'AboutModal'];
new Function('Vue', 'window', 'document', ...stubs, src)(Vue, win, {}, ...stubs.map(() => ({})));
const mark = i => { const h = seen[i][1] && seen[i][1].headers; return h && typeof h.get === 'function' ? String(h.get('X-TM-Request')) : 'none'; };
(async () => {
  await win.fetch('/api/settings', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: '{}' });
  await win.fetch('/api/topics/x', { method: 'DELETE' });
  await win.fetch('/api/system/tls/cert', { method: 'POST', body: 'form' });
  await win.fetch('/api/settings');
  await win.fetch('https://elsewhere.example/api/x', { method: 'POST' });
  console.log('put=' + mark(0) + ' ctype=' + seen[0][1].headers.get('Content-Type'));
  console.log('delete=' + mark(1));
  console.log('upload=' + mark(2) + ' body=' + seen[2][1].body);
  console.log('get=' + mark(3));
  console.log('foreign=' + mark(4));
})();
JSEOF
)"
    tm_assert_eq "put=1 ctype=application/json" "$(_line put "$out")" "the SPA's PUT does not carry X-TM-Request (or lost its Content-Type): ${out}"
    tm_assert_eq "delete=1" "$(_line delete "$out")" "the SPA's DELETE does not carry X-TM-Request: ${out}"
    tm_assert_eq "upload=1 body=form" "$(_line upload "$out")" "the certificate upload does not carry X-TM-Request: ${out}"
    tm_assert_eq "get=none" "$(_line get "$out")" "a GET was marked (it needs no mark): ${out}"
    tm_assert_eq "foreign=none" "$(_line foreign "$out")" "a request to another origin was marked: ${out}"
}
tm_case "the-spa-marks-every-state-changing-request" node a_spa_marks_its_requests

# ─── one answer for every failed sign-in ────────────────────────────────────
a_login_one_answer() {
    _setup
    local out
    out="$(_run "
H = {**J, 'X-TM-Request': '1'}
answers = set()
for reason in ('User not found in directory', 'Invalid credentials',
               'Not a member of required group: CN=G,DC=example,DC=org', 'LDAP error: socket unreachable'):
    auth.validate_credentials = lambda cfg, u, p, reason=reason: (False, reason)
    r = anon.post('/api/auth/login', data=json.dumps({'username': 'ghost', 'password': 'p'}), headers=H)
    answers.add('%d %s' % (r.status_code, json.dumps(r.get_json(), sort_keys=True)))
print('answers=%d' % len(answers))
print('answer=%s' % sorted(answers)[0])
print('audit=%s' % ' | '.join(d for _, d in rows('LOGIN_FAILED')))
")"
    tm_assert_eq "answers=1" "$(_line answers "$out")" "different sign-in failures got different answers: ${out}"
    tm_assert_eq 'answer=401 {"error": "Sign-in failed: the user name or password is wrong, or this account may not use Topic Manager."}' \
        "$(_line answer "$out")" "the sign-in failure answer is not the generic one"
    tm_assert_eq "audit=reason=User not found in directory | reason=Invalid credentials | reason=Not a member of required group: CN=G,DC=example,DC=org | reason=LDAP error: socket unreachable" \
        "$(_line audit "$out")" "the audit rows lost the specific reason"
}
tm_case "every-failed-sign-in-gets-one-answer-and-the-audit-keeps-the-reason" tmapp a_login_one_answer

# ─── the audit list is bounded ──────────────────────────────────────────────
a_audit_page_bounded() {
    _setup
    local out
    out="$(_run "
for i in range(3):
    audit.log_action({'audit': {'db_path': os.environ['TM_TEST_DB']}}, 'u', 'CREATE', 't%d' % i)
g = lambda q: c.get('/api/audit?' + q)
for q in ('per_page=-1', 'per_page=0', 'per_page=501', 'per_page=100000000', 'page=0', 'page=-3'):
    r = g(q); print('%s=%d %d' % (q, r.status_code, len((r.get_json() or {}).get('entries', []))))
r = g('per_page=500'); print('max=%d %d' % (r.status_code, len(r.get_json()['entries'])))
# v1.3.0: each read writes its AUDIT_READ AFTER it has read (WO-0006 af2), so
# newest first the table this read sees is READ(max), t2, t1, t0: page 4 of
# one row is t0.
r = g('per_page=1&page=4'); print('paged=%d %d %s' % (r.status_code, len(r.get_json()['entries']), r.get_json()['entries'][0]['target']))
r = g(''); print('default=%d %d' % (r.status_code, r.get_json()['per_page']))
")"
    local q
    for q in per_page=-1 per_page=0 per_page=501 per_page=100000000 page=0 page=-3; do
        tm_assert_eq "${q}=400 0" "$(_line "$q" "$out")" "an unbounded or invalid audit page was served (${q}): ${out}"
    done
    # 3 rows: the max read's own AUDIT_READ is written after it has read, and
    # the refused reads before it are not audit reads and record nothing.
    tm_assert_eq "max=200 3" "$(_line max "$out")" "the largest allowed page was refused, or recorded itself before reading"
    tm_assert_eq "paged=200 1 t0" "$(_line paged "$out")" "paging no longer works"
    tm_assert_eq "default=200 50" "$(_line default "$out")" "the default page size changed"
}
tm_case "the-audit-list-page-is-bounded" tmapp a_audit_page_bounded

# ─── one session identity per account ───────────────────────────────────────
a_session_identity_is_case_folded() {
    _setup
    local out
    out="$(_run "
H = {**J, 'X-TM-Request': '1'}
from tm import auth as A
import importlib; importlib.reload(A)
print('sam=%s' % ','.join(A._normalise_sam(u) for u in ('Alice', 'EXAMPLE\\\\ALICE', 'Alice@Example.org', 'alice')))
A.validate_credentials = lambda cfg, u, p: (True, {'username': A._normalise_sam(u), 'display_name': u})
auth.validate_credentials = A.validate_credentials
d = db(); d.execute(\"INSERT OR REPLACE INTO app_settings (key, value) VALUES ('session_max_concurrent', '2')\"); d.execute('DELETE FROM sessions'); d.commit(); d.close()
codes = [app.test_client().post('/api/auth/login', data=json.dumps({'username': u, 'password': 'p'}), headers=H).status_code for u in ('Alice', 'ALICE', 'alice')]
print('codes=%s' % codes)
d = db(); print('users=%s' % sorted(set(r[0] for r in d.execute('SELECT user FROM sessions')))); d.close()
# A row written before the fold (a v1.2.0 pre-release or a hand edit) is migrated at start.
from tm import models
now = datetime.datetime.now(datetime.timezone.utc)
d = db(); d.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('old', 'Bob', now.isoformat(), now.isoformat(), (now + datetime.timedelta(hours=1)).isoformat(), 'x')); d.commit(); d.close()
models.init_db({'audit': {'db_path': os.environ['TM_TEST_DB']}})
d = db(); print('migrated=%s' % d.execute(\"SELECT user FROM sessions WHERE id='old'\").fetchone()[0]); d.close()
print('counted=%d' % models.count_active_sessions(db(), 'BOB'))
")"
    tm_assert_eq "sam=alice,alice,alice,alice" "$(_line sam "$out")" "the sign-in name is not lower-cased: ${out}"
    tm_assert_eq "codes=[200, 200, 429]" "$(_line codes "$out")" \
        "case variants of one account got separate session quotas: ${out} $(tail -3 "${TM_TMP}/probe.err")"
    tm_assert_eq "users=['alice']" "$(_line users "$out")" "sessions were stored under more than one spelling"
    tm_assert_eq "migrated=bob" "$(_line migrated "$out")" "an existing mixed-case session row was not migrated"
    tm_assert_eq "counted=1" "$(_line counted "$out")" "the session count is not case-insensitive"
}
tm_case "one-account-is-one-session-identity-whatever-its-case" tmapp a_session_identity_is_case_folded

# ─── a failed audit write says where the record went ────────────────────────
a_audit_failure_is_truthful() {
    _setup
    local out
    out="$(_run "
H = {'X-TM-Request': '1'}
audit.require_writable = lambda cfg: None          # the pre-check passed; the DB broke after
def broken(cfg):
    raise sqlite3.OperationalError('disk I/O error')
audit.get_db = broken
for ok in (True, False):
    audit.syslog_send = lambda msg, sev=6, ok=ok: ok
    r = c.delete('/api/topics/orders', headers=H)
    print('%s=%d %s' % ('sent' if ok else 'lost', r.status_code, r.get_json()['message']))
    print('ret_%s=%s' % ('sent' if ok else 'lost', audit.write_failed({'action': 'X'}, OSError('e'))))
")"
    case "$(_line sent "$out")" in
        "sent=500 "*"WAS made"*"The record was sent to the host syslog as AUDIT_WRITE_FAILED (CRIT)."*) ;;
        *) _tm_afail "with syslog accepting, the answer does not say the record went there: ${out}" ;;
    esac
    case "$(_line lost "$out")" in
        *"sent to the host syslog"*) _tm_afail "the answer CLAIMS syslog has a record syslog refused: ${out}" ;;
        "lost=500 "*"WAS made"*"The host syslog did NOT accept the record either"*) ;;
        *) _tm_afail "with syslog refusing, the answer does not say so: ${out}" ;;
    esac
    tm_assert_eq "ret_sent=True" "$(_line ret_sent "$out")" "write_failed does not report a delivered record"
    tm_assert_eq "ret_lost=False" "$(_line ret_lost "$out")" "write_failed reports a refused record as delivered"
}
tm_case "a-failed-audit-write-says-where-the-record-actually-went" tmapp a_audit_failure_is_truthful

# ─── a finished apply is audited with nobody polling ────────────────────────
a_apply_audited_unattended() {
    _setup
    local out
    printf '{"domain":"nginx","job":"00000000000000a1","state":"ok","requested_by":"admin","finished_at":"2026-09-29T10:00:00+00:00","message":"nginx applied and verified.","details":[],"applied":{"ratelimit_api_per_min":"400"}}' \
        > "${TM_TMP}/run/nginx.result"
    # 1. Service start: create_app alone records it — no GET /api/system/apply.
    out="$(_run "
print('at_start=%s' % [d for _, d in rows('SYSTEM_APPLY_RESULT')])
")"
    tm_assert_eq "at_start=['job=00000000000000a1 state=ok step=: nginx applied and verified.']" "$(_line at_start "$out")" \
        "a finished apply was not audited at service start: ${out}"
    # 2. The .path unit's command, for a result that lands while the service runs.
    printf '{"domain":"time","job":"00000000000000b2","state":"rolled_back","requested_by":"admin","finished_at":"2026-09-29T10:05:00+00:00","message":"time failed","details":[]}' \
        > "${TM_TMP}/run/time.result"
    PATH="${TM_TMP}/bin:${PATH}" PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 \
        TM_APPLY_RESULT_DIR="${TM_TMP}/run" TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        "$PY" -m tm.apply --config "${TM_TMP}/config.yaml" audit > "${TM_TMP}/cli.out" 2> "${TM_TMP}/cli.err" \
        || _tm_afail "python -m tm.apply audit failed: $(cat "${TM_TMP}/cli.out" "${TM_TMP}/cli.err")"
    tm_assert_eq "audited: time" "$(tr -d '\r' < "${TM_TMP}/cli.out")" "the unattended audit command did not record the new result"
    # 3. Once only, however many times it runs.
    out="$(_run "
from tm import apply as A
print('again=%s' % A.audit_all_results({'audit': {'db_path': os.environ['TM_TEST_DB']}}))
print('count=%d' % len(rows('SYSTEM_APPLY_RESULT')))
")"
    tm_assert_eq "again=[]" "$(_line again "$out")" "a result was recorded twice"
    tm_assert_eq "count=2" "$(_line count "$out")" "the results were not each recorded exactly once"
}
tm_case "a-finished-apply-is-audited-with-nobody-polling" tmapp a_apply_audited_unattended

a_apply_audit_units() {
    local p="${TM_REPO_ROOT}/systemd/topic-manager-apply-audit.path" s="${TM_REPO_ROOT}/systemd/topic-manager-apply-audit.service"
    tm_assert_file "$p" "there is no path unit watching for finished applies"
    grep -qx 'PathChanged=/run/topic-manager-apply/finished' "$p" || _tm_afail "the path unit does not watch the helper's final-verdict marker"
    grep -qx 'Unit=topic-manager-apply-audit.service' "$p" || _tm_afail "the path unit starts something else"
    grep -qx 'ExecStart=/opt/topic-manager/venv/bin/python3 -m tm.apply audit' "$s" || _tm_afail "the audit unit does not run tm.apply audit"
    grep -qx 'User=topic-manager' "$s" || _tm_afail "the audit unit does not run as the service account"
    grep -qx 'UMask=0077' "$s" || _tm_afail "the audit unit could create tm.db wider than 0600"
    local h; h="$(tm_apply_helper)"
    grep -q "^DONE_MARKER = 'finished'$" "$h" || _tm_afail "the helper's final-verdict marker is not the file the path unit watches"
    grep -q "name=DONE_MARKER)" "$h" || _tm_afail "the helper never writes the final-verdict marker"
}
tm_case "the-apply-audit-path-unit-watches-the-helpers-final-marker" none a_apply_audit_units

tm_finish
