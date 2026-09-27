#!/usr/bin/env bash
# =============================================================================
# t35 — "APPLY TO HOST", THE UNPRIVILEGED HALF: the routes, the status, the
# applied values (contract CC-1) and the polkit rule that lets the service
# account start the four apply units and nothing else.
#
# systemctl is a recording stub on PATH (tm/service_control finds it with
# shutil.which), and the helper's result directory is a scratch directory, so
# every case drives the REAL routes end to end without touching a host unit.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "apply routes: stage 0600, start the fixed unit, status + applied, once-only audit"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_setup() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs" "${TM_TMP}/bin" "${TM_TMP}/run" "${TM_TMP}/data"
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
  log_level: "ERROR"
YAML
    cat > "${TM_TMP}/bin/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TM_TMP}/calls"
[ "\$1" = is-active ] && { cat "${TM_TMP}/unit.state" 2>/dev/null || echo inactive; exit 3; }
[ -f "${TM_TMP}/start.fail" ] && { echo "Failed to start: Access denied"; exit 4; }
exit 0
STUB
    chmod 755 "${TM_TMP}/bin/systemctl"
    : > "${TM_TMP}/calls"
}

_run() {
    cat > "${TM_TMP}/probe.py" <<PYEOF
import json, os, sqlite3, datetime, time
from tm.app import create_app
from tm import apply as A
app = create_app()
c = app.test_client()
with c.session_transaction() as s:
    s['user'] = {'username': 'admin'}; s['sid'] = 'sid1'
now = datetime.datetime.now(datetime.timezone.utc)
def db(): return sqlite3.connect(os.environ['TM_TEST_DB'])
d = db(); d.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('sid1','admin',now.isoformat(),now.isoformat(),(now+datetime.timedelta(hours=1)).isoformat(),'x')); d.commit(); d.close()
H = {'Content-Type': 'application/json'}
RUN = os.environ['TM_APPLY_RESULT_DIR']
STAGE = os.path.join(os.path.dirname(os.environ['TM_TEST_DB']), 'apply')
def result(domain, **kw):
    with open(os.path.join(RUN, domain + '.result'), 'w') as f: json.dump(kw, f)
def audits(action):
    d = db(); n = d.execute('SELECT COUNT(*) FROM audit_log WHERE action=?', (action,)).fetchone()[0]; d.close(); return n
def unthrottle():
    d = db(); d.execute("DELETE FROM app_settings WHERE key LIKE 'apply_last_epoch_%'"); d.commit(); d.close()
$1
PYEOF
    PATH="${TM_TMP}/bin:${PATH}" PYTHONPATH="$PYROOT" PYTHONDONTWRITEBYTECODE=1 \
        TM_CONFIG="${TM_TMP}/config.yaml" TM_TEST_DB="${TM_TMP}/data/tm.db" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        TM_APPLY_RESULT_DIR="${TM_TMP}/run" TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" \
        UNIT_STATE="${TM_TMP}/unit.state" "$PY" "${TM_TMP}/probe.py" 2>&1 | tr -d '\r'
}

a_post_stages_and_starts() {
    _setup
    local out
    out="$(_run "
c.put('/api/settings', data=json.dumps({'ratelimit_api_per_min': '450'}), headers=H)
r = c.post('/api/system/apply/nginx', data='{}', headers=H)
j = r.get_json()
print('code=%d state=%s dom=%s job=%s' % (r.status_code, j.get('state'), j.get('domain'), len(j.get('job', ''))))
doc = json.load(open(os.path.join(STAGE, 'nginx.json')))
print('staged=%s' % doc['settings']['ratelimit_api_per_min'])
print('keys=%s' % ','.join(sorted(doc['settings'])))
print('mode=%o dirmode=%o' % (os.stat(os.path.join(STAGE, 'nginx.json')).st_mode & 0o777, os.stat(STAGE).st_mode & 0o777))
print('audited=%d' % audits('SYSTEM_APPLY_REQUESTED'))
s = c.get('/api/system/apply/nginx').get_json()
print('status=%s applied=%s' % (s['state'], s['applied']))
print('fields=%s' % ','.join(sorted(s)))
")"
    tm_assert_eq "code=202 state=queued dom=nginx job=16" "$(grep '^code=' <<<"$out")" "POST apply did not answer 202 queued: ${out}"
    tm_assert_eq "staged=450" "$(grep '^staged=' <<<"$out")" "the SAVED value was not staged: ${out}"
    tm_assert_eq "keys=http_redirect_enabled,ratelimit_api_burst,ratelimit_api_per_min,ratelimit_conn_per_ip,ratelimit_login_burst,ratelimit_login_per_min" \
        "$(grep '^keys=' <<<"$out")" "the nginx staging carries keys that are not the nginx domain's"
    grep -qx 'start --no-block topic-manager-apply-nginx.service' "${TM_TMP}/calls" \
        || _tm_afail "the fixed apply unit was not started: $(cat "${TM_TMP}/calls")"
    tm_assert_eq "audited=1" "$(grep '^audited=' <<<"$out")" "SYSTEM_APPLY_REQUESTED was not audited once"
    tm_assert_eq "status=queued applied=None" "$(grep '^status=' <<<"$out")" "status before any result: ${out}"
    tm_assert_eq "fields=applied,applied_at,details,domain,finished_at,job,message,state" \
        "$(grep '^fields=' <<<"$out")" "the status document is not the contract's shape (+ CC-1 applied/applied_at)"
}
tm_case "post-apply-stages-the-saved-values-and-starts-the-fixed-unit" tmapp a_post_stages_and_starts

a_stage_modes() {
    _setup
    ( umask 022; _run "c.post('/api/system/apply/time', data='{}', headers=H)" >/dev/null )
    tm_assert_mode 600 "${TM_TMP}/data/apply/time.json" "a staging file is readable by others under umask 022"
    tm_assert_mode 700 "${TM_TMP}/data/apply" "the staging directory is not 0700"
}
tm_case "staging-is-0600-in-a-0700-directory-whatever-the-umask" "tmapp,modes" a_stage_modes

a_result_audited_once_and_applied_kept() {
    _setup
    local out
    out="$(_run "
r = c.post('/api/system/apply/nginx', data='{}', headers=H); job = r.get_json()['job']
result('nginx', job=job, state='ok', step='done', message='nginx applied and verified.', details=['x'],
       finished_at='2026-09-26T10:00:00+00:00', requested_by='admin',
       applied={'http_redirect_enabled': 'false', 'ratelimit_api_per_min': '300'})
for i in range(4):
    s = c.get('/api/system/apply/nginx').get_json()
print('state=%s applied=%s at=%s' % (s['state'], s['applied'].get('http_redirect_enabled'), s['applied_at']))
print('audits=%d' % audits('SYSTEM_APPLY_RESULT'))
os.unlink(os.path.join(RUN, 'nginx.result'))            # /run does not survive a reboot
s = c.get('/api/system/apply/nginx').get_json()
print('after_reboot=%s %s %s' % (s['state'], s['applied'] and s['applied'].get('http_redirect_enabled'), s['applied_at']))
# A later FAILED apply must not replace what is applied.
unthrottle()
r = c.post('/api/system/apply/nginx', data='{}', headers=H); job2 = r.get_json()['job']
result('nginx', job=job2, state='rolled_back', step='test', message='nginx -t failed', details=[],
       finished_at='2026-09-26T11:00:00+00:00', requested_by='admin', applied={'http_redirect_enabled': 'true'})
s = c.get('/api/system/apply/nginx').get_json()
print('after_fail=%s %s %s' % (s['state'], s['applied'].get('http_redirect_enabled'), audits('SYSTEM_APPLY_RESULT')))
")"
    tm_assert_eq "state=ok applied=false at=2026-09-26T10:00:00+00:00" "$(grep '^state=' <<<"$out")" \
        "a successful result did not report what was applied (CC-1): ${out}"
    tm_assert_eq "audits=1" "$(grep '^audits=' <<<"$out")" "four status polls recorded the result more than once: ${out}"
    tm_assert_eq "after_reboot=ok false 2026-09-26T10:00:00+00:00" "$(grep '^after_reboot=' <<<"$out")" \
        "the verdict or the applied values were lost with the /run result file (a reboot): ${out}"
    tm_assert_eq "after_fail=rolled_back false 2" "$(grep '^after_fail=' <<<"$out")" \
        "a rolled-back apply replaced the LIVE applied values: ${out}"
}
tm_case "result-audited-once-applied-values-persist-and-survive-failure" tmapp a_result_audited_once_and_applied_kept

a_tls_result_audits_replacement() {
    _setup
    local out
    out="$(_run "
A.write_stage({'audit': {'db_path': os.environ['TM_TEST_DB']}}, 'tls', {}, 'admin', files={'crt': b'x', 'key': b'y'})
job = json.load(open(os.path.join(STAGE, 'tls.last')))['job']
result('tls', job=job, state='ok', step='done', message='tls applied and verified.', details=[],
       finished_at='2026-09-26T10:00:00+00:00', requested_by='admin',
       applied={'subject': 'CN=x', 'key_type': 'EC P-256', 'not_after': '2027-01-01T00:00:00+00:00', 'chain_count': '1'})
s = c.get('/api/system/apply/tls').get_json()
d = db(); row = d.execute(\"SELECT user, detail FROM audit_log WHERE action='TLS_CERT_REPLACED'\").fetchone(); d.close()
print('state=%s row=%s' % (s['state'], row))
")"
    grep -q "^state=ok row=('admin', 'job=.* key_type=EC P-256 not_after=2027-01-01T00:00:00+00:00 chain=1')" <<<"$out" \
        || _tm_afail "a successful certificate replacement was not audited as TLS_CERT_REPLACED: ${out}"
}
tm_case "a-successful-tls-apply-is-audited-as-tls-cert-replaced" tmapp a_tls_result_audits_replacement

a_refusals() {
    _setup
    local out
    out="$(_run "
r = c.post('/api/system/apply/tls', data='{}', headers=H); print('tls=%d' % r.status_code)
r = c.post('/api/system/apply/etc', data='{}', headers=H); print('etc=%d' % r.status_code)
r = c.get('/api/system/apply/etc'); print('getetc=%d' % r.status_code)
r = c.post('/api/system/apply/nginx', data='{}', headers={}); print('nojson=%d' % r.status_code)
c.put('/api/settings', data=json.dumps({'syslog_enabled': 'true'}), headers=H)
r = c.post('/api/system/apply/syslog', data='{}', headers=H)
print('cross=%d %s' % (r.status_code, json.dumps(r.get_json(), sort_keys=True)))
r = c.post('/api/system/apply/time', data='{}', headers=H); print('first=%d' % r.status_code)
r = c.post('/api/system/apply/time', data='{}', headers=H); print('second=%d %s' % (r.status_code, r.headers.get('Retry-After')))
unthrottle()
open(os.environ['UNIT_STATE'], 'w').write('activating\n')
r = c.post('/api/system/apply/time', data='{}', headers=H); print('busy=%d %s' % (r.status_code, r.get_json().get('error')))
anon = app.test_client()
print('anon=%d %d %d %d' % (anon.get('/api/system/apply/nginx').status_code, anon.post('/api/system/apply/nginx', data='{}', headers=H).status_code,
      anon.get('/api/system/time').status_code, anon.get('/api/audit/capacity').status_code))
r = c.post('/api/system/apply/nginx', data='{}', headers={'Content-Type': 'application/json', 'Sec-Fetch-Site': 'cross-site'})
print('xsite=%d' % r.status_code)
")"
    tm_assert_eq "tls=404" "$(grep '^tls=' <<<"$out")" "tls was applicable without an uploaded certificate"
    tm_assert_eq "etc=404" "$(grep '^etc=' <<<"$out")" "an unknown domain was accepted"
    tm_assert_eq "getetc=404" "$(grep '^getetc=' <<<"$out")" "status for an unknown domain was served"
    tm_assert_eq "nojson=415" "$(grep '^nojson=' <<<"$out")" "a non-JSON POST (a form) could start an apply"
    tm_assert_eq 'cross=400 {"error": "invalid", "field": "syslog_host", "reason": "required when remote syslog is enabled"}' \
        "$(grep '^cross=' <<<"$out")" "syslog ON with no host was staged: ${out}"
    tm_assert_eq "first=202" "$(grep '^first=' <<<"$out")" "the first time apply failed: ${out}"
    tm_assert_eq "second=429 5" "$(grep '^second=' <<<"$out")" \
        "a second apply inside 5 s was not throttled (systemd's start limiter would be next): ${out}"
    tm_assert_eq "busy=409 apply_in_progress" "$(grep '^busy=' <<<"$out")" "an apply was started over a running one"
    tm_assert_eq "anon=401 401 401 401" "$(grep '^anon=' <<<"$out")" "an apply/status route answered WITHOUT authentication"
    tm_assert_eq "xsite=403" "$(grep '^xsite=' <<<"$out")" "a cross-site POST reached the apply route"
}
tm_case "apply-refuses-unknown-domains-bad-input-bursts-and-anonymous" tmapp a_refusals

a_start_failure() {
    _setup
    : > "${TM_TMP}/start.fail"
    local out
    out="$(_run "
r = c.post('/api/system/apply/nginx', data='{}', headers=H)
print('code=%d %s' % (r.status_code, r.get_json().get('error')))
s = c.get('/api/system/apply/nginx').get_json()
print('status=%s' % s['state'])
print('says=%s' % ('could not be started' in s['message']))
print('keyfiles=%s' % sorted(f for f in os.listdir(STAGE) if not f.endswith('.last')))
")"
    tm_assert_eq "code=502 apply_unit_failed" "$(grep '^code=' <<<"$out")" "a unit that could not start was reported as queued"
    tm_assert_eq "status=failed" "$(grep '^status=' <<<"$out")" "the status kept saying queued for a job that can never run"
    tm_assert_eq "says=True" "$(grep '^says=' <<<"$out")" "the status does not say the unit could not be started"
    tm_assert_eq "keyfiles=[]" "$(grep '^keyfiles=' <<<"$out")" "staging was left behind for a job that will never run"
}
tm_case "a-unit-that-cannot-start-is-failed-at-once" tmapp a_start_failure

a_polkit_rule() {
    local rules="${TM_REPO_ROOT}/install/polkit/50-topic-manager.rules"
    node - "$rules" <<'JSEOF' > "${TM_TMP}/pk.out" 2>&1 || _tm_afail "the polkit rule did not evaluate: $(cat "${TM_TMP}/pk.out")"
const fs = require('fs');
let rule = null;
const polkit = { Result: { YES: 'yes', NO: 'no', NOT_HANDLED: 'nh' }, addRule: (f) => { rule = f; } };
new Function('polkit', fs.readFileSync(process.argv[2], 'utf8'))(polkit);
const ask = (user, unit, verb) => rule({ id: 'org.freedesktop.systemd1.manage-units',
    lookup: (k) => ({ unit, verb })[k] }, { user });
const out = [];
for (const d of ['syslog', 'time', 'nginx', 'tls']) {
  const u = `topic-manager-apply-${d}.service`;
  out.push(`${d}:start=${ask('topic-manager', u, 'start')}`);
  for (const v of ['stop', 'restart', 'reload', 'kill', 'enable']) out.push(`${d}:${v}=${ask('topic-manager', u, v)}`);
  out.push(`${d}:other-user=${ask('alice', u, 'start')}`);
}
out.push(`unknown=${ask('topic-manager', 'topic-manager-apply-evil.service', 'start')}`);
out.push(`sshd=${ask('topic-manager', 'ssh.service', 'start')}`);
console.log(out.join('\n'));
JSEOF
    local d v
    for d in syslog time nginx tls; do
        grep -qx "${d}:start=yes" "${TM_TMP}/pk.out" || _tm_afail "polkit does not let the app START the ${d} apply unit"
        for v in stop restart reload kill enable other-user; do
            grep -qx "${d}:${v}=nh" "${TM_TMP}/pk.out" || _tm_afail "polkit grants ${v} on the ${d} apply unit: $(grep "^${d}:${v}" "${TM_TMP}/pk.out")"
        done
    done
    grep -qx 'unknown=nh' "${TM_TMP}/pk.out" || _tm_afail "polkit matches apply units by PREFIX"
    grep -qx 'sshd=nh' "${TM_TMP}/pk.out" || _tm_afail "polkit grants an unrelated unit"
}
tm_case "polkit-grants-start-of-the-four-apply-units-and-nothing-else" node a_polkit_rule

a_allowed_units_match_polkit() {
    local out
    out="$(PYTHONPATH="$PYROOT" PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
from tm import service_control as s
print(' '.join(sorted(s.APPLY_UNITS.values())))
print(all(u in s.ALLOWED_UNITS for u in s.APPLY_UNITS.values()))
" | tr -d '\r')"
    tm_assert_eq "topic-manager-apply-nginx.service topic-manager-apply-syslog.service topic-manager-apply-time.service topic-manager-apply-tls.service" \
        "$(sed -n 1p <<<"$out")" "service_control.APPLY_UNITS is not the four units"
    tm_assert_eq "True" "$(sed -n 2p <<<"$out")" "ALLOWED_UNITS does not carry the apply units"
    local u
    for u in syslog time nginx tls; do
        grep -q "topic-manager-apply-${u}.service" "${TM_REPO_ROOT}/install/polkit/50-topic-manager.rules" \
            || _tm_afail "the polkit rule does not name topic-manager-apply-${u}.service"
        tm_assert_file "${TM_REPO_ROOT}/systemd/topic-manager-apply-${u}.service"
        grep -q '^\[Install\]' "${TM_REPO_ROOT}/systemd/topic-manager-apply-${u}.service" \
            && _tm_afail "topic-manager-apply-${u}.service can be enabled (it must only be started on demand)"
        grep -qx 'Type=oneshot' "${TM_REPO_ROOT}/systemd/topic-manager-apply-${u}.service" \
            || _tm_afail "topic-manager-apply-${u}.service is not a oneshot (systemctl start would not wait for a verdict)"
    done
    true
}
tm_case "service-control-and-units-agree-with-the-polkit-rule" none a_allowed_units_match_polkit

tm_finish
