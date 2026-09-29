#!/usr/bin/env bash
# =============================================================================
# t32 — EVERY AUDIT RECORD ALSO GOES TO SYSLOG, AND AN ACTION WHOSE RECORD
# CANNOT BE WRITTEN DOES NOT HAPPEN (v1.2.0; SRG-APP-000515 / -000360).
#
# The syslog half is measured on a REAL Unix datagram socket bound in the
# scratch directory (TM_SYSLOG_SOCKET points tm/audit.py at it), so what is
# asserted is the bytes a syslog daemon would receive, not a mock's call log.
#
# The failure half uses a REAL database failure: a trigger that aborts every
# INSERT into audit_log. That fails the pre-check's probe row, the route's own
# row and the prune's row exactly as a corrupt or read-only store would, and
# it works as root, where a chmod would not.
#
# Owner ruling 2026-09-26: an audit write failure BLOCKS the action — the
# audit trail is proved writable BEFORE the Kafka change, the response is
# 503 {"error": "audit_unavailable"}, and AUDIT_WRITE_FAILED goes to syslog at
# CRIT carrying the whole record.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "audit: every record to syslog; no record, no action"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_setup() {
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
audit:
  db_path: "${TM_TMP}/tm.db"
logging:
  log_level: "WARNING"
  syslog_enabled: false
YAML
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs"
    printf 'clusters:\n  - id: c1\n    name: C1\n    bootstrap_servers: "h:9092"\n    security_protocol: PLAINTEXT\n    active: true\n' \
        > "${TM_TMP}/clusters.d/clusters.yaml"
}

# The prelude every probe shares: a bound syslog socket and a way to read it.
# Every probe is BOUNDED: a send that blocks (a full receiver queue) must be a
# FAIL of that case, never a stalled job. faulthandler's watchdog thread fires
# even while the main thread is stuck inside send(): it prints every thread's
# stack and exits. _run adds timeout(1) outside it where the host has one.
_PRELUDE='
import faulthandler, os
faulthandler.dump_traceback_later(int(os.environ.get("TM_PROBE_TIMEOUT") or 120), exit=True)
import json, socket, sqlite3, datetime, logging, io
SOCK = os.environ["TM_SYSLOG_SOCKET"]
try: os.unlink(SOCK)
except FileNotFoundError: pass
rx = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); rx.bind(SOCK); rx.setblocking(False)
def drain():
    out = []
    while True:
        try: out.append(rx.recv(65536).decode("utf-8", "replace"))
        except BlockingIOError: return out
def db():
    return sqlite3.connect(os.environ["TM_TEST_DB"])
def break_audit():
    d = db()
    d.execute("CREATE TRIGGER IF NOT EXISTS t_broken BEFORE INSERT ON audit_log "
              "BEGIN SELECT RAISE(ABORT, %r); END" % "audit store is broken")
    d.commit(); d.close()
'

_run() {   # _run <python body>   (TM_PROBE_TIMEOUT: seconds, default 120)
    printf '%s\n%s\n' "$_PRELUDE" "$1" > "${TM_TMP}/probe.py"
    local -a bound=()
    command -v timeout >/dev/null 2>&1 && bound=(timeout -k 5 "$(( ${TM_PROBE_TIMEOUT:-120} + 15 ))")
    ${bound[@]+"${bound[@]}"} env \
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 TM_CONFIG="${TM_TMP}/config.yaml" \
        TM_TEST_DB="${TM_TMP}/tm.db" TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
        TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" TM_SYSLOG_SOCKET="${TM_TMP}/log.sock" \
        "$PY" "${TM_TMP}/probe.py" 2>&1 | tr -d '\r'
}

_ACTIONS_AST='
import ast, glob, sys
acts = set()
for f in sorted(glob.glob(sys.argv[1] + "/tm/*.py")):
    t = ast.parse(open(f, encoding="utf-8").read())
    for n in ast.walk(t):
        if isinstance(n, ast.Call) and getattr(n.func, "attr", getattr(n.func, "id", "")) == "log_action" \
           and len(n.args) > 2 and isinstance(n.args[2], ast.Constant):
            acts.add(n.args[2].value)
print(" ".join(sorted(acts)))
'

a_every_action_emits_once() {
    _setup
    local acts out
    acts="$(PYTHONDONTWRITEBYTECODE=1 "$PY" -c "$_ACTIONS_AST" "$PYROOT" | tr -d '\r')"
    [ "$(wc -w <<<"$acts")" -ge 20 ] || _tm_afail "the AST found only $(wc -w <<<"$acts") audit actions: ${acts}"
    out="$(_run "
from tm.config import load_config
from tm.models import init_db
from tm import audit
cfg = load_config(); init_db(cfg)
acts = '''${acts}'''.split()
got = []
for a in acts:
    audit.log_action(cfg, 'user\nFORGED', a, 'target-' + a, 'detail\r\nline2', 'c1')
    got += drain()      # as a daemon reads: the queue holds 10 datagrams in a container
print('sent=%d got=%d' % (len(acts), len(got)))
missing = [a for a in acts if not any(('action=\"%s\"' % a) in g for g in got)]
print('missing=%s' % missing)
print('newlines=%d' % sum(('\n' in g) for g in got))
print('pri=%s' % sorted(set(g.split('>')[0] for g in got)))
print('tag=%s' % all('topic-manager-audit[' in g for g in got))
print('sample=%s' % got[0])
")"
    tm_assert_eq "sent=$(wc -w <<<"$acts") got=$(wc -w <<<"$acts")" "$(grep '^sent=' <<<"$out")" \
        "log_action did not emit exactly one syslog record per call: ${out}"
    tm_assert_eq "missing=[]" "$(grep '^missing=' <<<"$out")" "an audit action never reached syslog: ${out}"
    tm_assert_eq "newlines=0" "$(grep '^newlines=' <<<"$out")" \
        "a CR/LF in an audit field reached syslog: one record could forge another line"
    tm_assert_eq "pri=['<86']" "$(grep '^pri=' <<<"$out")" "audit records are not authpriv.info (<86>)"
    tm_assert_eq "tag=True" "$(grep '^tag=' <<<"$out")" "a record lacks the topic-manager-audit identifier"
}
tm_case "every-audit-action-reaches-syslog-exactly-once" linux a_every_action_emits_once

a_full_queue_is_bounded() {
    # A syslog daemon that stops reading: its receive queue fills (to
    # net.unix.max_dgram_qlen, 10 in a container, 512 on a host) and a
    # BLOCKING datagram send then waits forever — every gunicorn worker that
    # writes an audit record hangs. The send must fail within its bound, the
    # committed record stay in the database, and the failure be LOUD.
    _setup
    local out
    out="$(TM_PROBE_TIMEOUT=30 _run "
import sys, time
from tm.config import load_config
from tm.models import init_db
from tm import audit
cfg = load_config(); init_db(cfg)
buf = io.StringIO(); h = logging.StreamHandler(buf)
logging.getLogger('tm').addHandler(h); logging.getLogger('tm').setLevel(logging.INFO)
# Fill the queue with a NON-blocking sender until the kernel refuses: the
# host's own limit, whatever it is set to.
tx = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); tx.connect(SOCK); tx.setblocking(False)
n = 0
while n < 200000:
    try:
        tx.send(b'<86>filler'); n += 1
    except BlockingIOError:
        break
print('filled=%s' % (0 < n < 200000))
t0 = time.monotonic(); ok = audit.syslog_send('probe'); dt = time.monotonic() - t0
print('send=%s bounded=%s' % (ok, dt < 2.0))
t0 = time.monotonic(); rec = audit.log_action(cfg, 'alice', 'DELETE', 'orders', 'x', 'c1'); dt = time.monotonic() - t0
print('log_action=%s bounded=%s' % (rec and rec['action'], dt < 2.0))
d = db(); print('row=%d' % d.execute(\"SELECT COUNT(*) FROM audit_log WHERE action='DELETE' AND target='orders'\").fetchone()[0]); d.close()
txt = buf.getvalue()
print('loud=%s' % any(('AUDIT_SYSLOG_FAILED' in l and 'orders' in l) for l in txt.splitlines()))
print('why=%s' % ('receive queue is full' in txt))
# The diagnostic handler (logging.syslog_enabled) writes to the same kind of
# socket; the CRITICAL above goes through it on a host that enables it.
from tm.app import _BoundedSysLogHandler
lg = logging.getLogger('probe.diag'); lg.propagate = False
lg.addHandler(_BoundedSysLogHandler(address=SOCK))
err, sys.stderr = sys.stderr, io.StringIO()
t0 = time.monotonic(); lg.error('diagnostic line'); dt = time.monotonic() - t0
sys.stderr = err
print('diag_bounded=%s' % (dt < 2.0))
drain()
print('recovered=%s' % audit.syslog_send('after'))
")"
    tm_assert_eq "filled=True" "$(grep '^filled=' <<<"$out")" "the fixture could not fill the receive queue: ${out}"
    tm_assert_eq "send=False bounded=True" "$(grep '^send=' <<<"$out")" \
        "a send to a FULL syslog queue did not fail within 2 s (it blocks: every worker would hang): ${out}"
    tm_assert_eq "log_action=DELETE bounded=True" "$(grep '^log_action=' <<<"$out")" \
        "a committed audit record with syslog stalled did not return within 2 s: ${out}"
    tm_assert_eq "row=1" "$(grep '^row=' <<<"$out")" "the committed record is not in the audit database"
    tm_assert_eq "loud=True" "$(grep '^loud=' <<<"$out")" \
        "a committed record that did not reach syslog was not logged CRITICAL with the record: ${out}"
    tm_assert_eq "why=True" "$(grep '^why=' <<<"$out")" "the log does not say the syslog queue is full"
    tm_assert_eq "diag_bounded=True" "$(grep '^diag_bounded=' <<<"$out")" \
        "the diagnostic SysLogHandler blocked on a full queue: ${out}"
    tm_assert_eq "recovered=True" "$(grep '^recovered=' <<<"$out")" "sending did not recover once the queue drained"
}
tm_case "a-full-syslog-queue-fails-the-send-within-its-bound" linux a_full_queue_is_bounded

a_independent_of_syslog_enabled() {
    _setup
    local out
    out="$(_run "
from tm.app import create_app
app = create_app()
c = app.test_client()
with c.session_transaction() as s:
    s['user'] = {'username': 'admin'}; s['sid'] = 'sid1'
now = datetime.datetime.now(datetime.timezone.utc)
d = db(); d.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('sid1','admin',now.isoformat(),now.isoformat(),(now+datetime.timedelta(hours=1)).isoformat(),'x')); d.commit()
drain()
r = c.put('/api/settings', data=json.dumps({'banner_text': 'X'}), headers={'Content-Type':'application/json', 'X-TM-Request': '1'})
got = drain()
print('code=%d n=%d' % (r.status_code, len(got)))
print('settings=%s' % any('action=\"SETTINGS_UPDATE\"' in g for g in got))
")"
    tm_assert_eq "code=200 n=1" "$(grep '^code=' <<<"$out")" \
        "a settings change with logging.syslog_enabled=false sent no audit record to syslog: ${out}"
    tm_assert_eq "settings=True" "$(grep '^settings=' <<<"$out")" "the record sent was not the SETTINGS_UPDATE"
}
tm_case "audit-syslog-does-not-depend-on-syslog_enabled" "tmapp,linux" a_independent_of_syslog_enabled

a_failure_is_crit_and_raises() {
    _setup
    local out
    out="$(_run "
from tm.config import load_config
from tm.models import init_db
from tm import audit
cfg = load_config(); init_db(cfg); break_audit(); drain()
try:
    audit.log_action(cfg, 'alice', 'DELETE', 'orders', 'confirmed', 'c1')
    print('raised=no')
except audit.AuditUnavailable:
    print('raised=yes')
got = drain()
print('crit=%s' % [g.split('>')[0] for g in got])
print('carries=%s' % all(('AUDIT_WRITE_FAILED' in g and 'orders' in g and 'DELETE' in g) for g in got))
r = audit.log_action(cfg, 'alice', 'LOGOUT', 'x', '', '', best_effort=True)
print('best_effort=%s crit2=%d' % (r, len(drain())))
try:
    audit.require_writable(cfg); print('pre=passed')
except audit.AuditUnavailable:
    print('pre=refused')
")"
    tm_assert_eq "raised=yes" "$(grep '^raised=' <<<"$out")" \
        "a failed audit write passed SILENTLY (SRG-APP-000360): ${out}"
    tm_assert_eq "crit=['<82']" "$(grep '^crit=' <<<"$out")" \
        "the failure was not ONE authpriv.crit (<82>) syslog record: ${out}"
    tm_assert_eq "carries=True" "$(grep '^carries=' <<<"$out")" \
        "AUDIT_WRITE_FAILED does not carry the record that was lost: ${out}"
    tm_assert_eq "best_effort=None crit2=1" "$(grep '^best_effort=' <<<"$out")" \
        "a best-effort record (sign-out) either raised or went unreported: ${out}"
    tm_assert_eq "pre=refused" "$(grep '^pre=' <<<"$out")" \
        "the pre-check called a broken audit store writable: ${out}"
}
tm_case "audit-write-failure-is-crit-and-never-silent" linux a_failure_is_crit_and_raises

_ROUTES='
from tm.app import create_app
from tm import kafka_client, auth, service_control
calls = []
kafka_client.delete_topic = lambda c, n: calls.append("delete:" + n)
kafka_client.create_topic = lambda c, n, p, r, cf: calls.append("create:" + n)
kafka_client.update_topic_config = lambda c, n, u: calls.append("config:" + n)
service_control.restart_detached = lambda h, cb: calls.append("restart")
service_control.nginx_config_test = lambda: (True, "ok")
auth.validate_credentials = lambda cfg, u, p: (True, {"username": u, "display_name": u})
app = create_app()
c = app.test_client()
with c.session_transaction() as s:
    s["user"] = {"username": "admin"}; s["sid"] = "sid1"
now = datetime.datetime.now(datetime.timezone.utc)
d = db(); d.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?)", ("sid1","admin",now.isoformat(),now.isoformat(),(now+datetime.timedelta(hours=1)).isoformat(),"x")); d.commit(); d.close()
H = {"Content-Type": "application/json", "X-TM-Request": "1"}
'

a_routes_fail_closed() {
    _setup
    local out
    out="$(_run "${_ROUTES}
break_audit(); drain()
res = {}
res['delete'] = c.delete('/api/topics/orders', headers=H)
res['create'] = c.post('/api/topics', data=json.dumps({'name': 'n1'}), headers=H)
res['config'] = c.put('/api/topics/orders/config', data=json.dumps({'updates': {'retention.ms': '1'}}), headers=H)
res['cluster'] = c.post('/api/clusters', data=json.dumps({'id': 'c2', 'name': 'C2', 'bootstrap_servers': 'h:9092', 'security_protocol': 'PLAINTEXT'}), headers=H)
res['restart'] = c.post('/api/service/restart', data='{}', headers=H)
res['settings'] = c.put('/api/settings', data=json.dumps({'banner_text': 'NEW'}), headers=H)
res['apply'] = c.post('/api/system/apply/nginx', data='{}', headers=H)
anon = app.test_client()
# An EXPIRED session of someone else: a sign-in normally sweeps it. A refused
# sign-in must change nothing at all, the sweep included.
d = db(); d.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('old', 'zed', '2000-01-01', '2000-01-01', '2000-01-01T00:00:00+00:00', 'x')); d.commit(); d.close()
before_sessions = sorted(db().execute('SELECT id FROM sessions').fetchall())
res['login'] = anon.post('/api/auth/login', data=json.dumps({'username': 'bob', 'password': 'x'}), headers=H)
print('sessions_untouched=%s' % (sorted(db().execute('SELECT id FROM sessions').fetchall()) == before_sessions))
for k, r in sorted(res.items()):
    print('%s=%d %s' % (k, r.status_code, (r.get_json() or {}).get('error')))
print('calls=%s' % calls)
d = db()
print('banner=%s' % d.execute(\"SELECT value FROM app_settings WHERE key='banner_text'\").fetchone())
print('bob_sessions=%d' % d.execute(\"SELECT COUNT(*) FROM sessions WHERE user='bob'\").fetchone()[0])
print('clusters_c2=%s' % ('c2' in open(os.environ['TM_CLUSTERS_DIR'] + '/clusters.yaml').read()))
print('staged=%s' % os.path.exists(os.path.join(os.path.dirname(os.environ['TM_TEST_DB']), 'apply', 'nginx.json')))
print('crit=%d' % sum(g.startswith('<82>') for g in drain()))
r = c.post('/api/auth/logout', data='{}', headers=H)
print('logout=%d' % r.status_code)
")"
    local k
    for k in apply cluster config create delete login restart settings; do
        grep -q "^${k}=503 audit_unavailable$" <<<"$out" \
            || _tm_afail "${k}: not refused with 503 audit_unavailable while the audit store is broken: ${out}"
    done
    tm_assert_eq "calls=[]" "$(grep '^calls=' <<<"$out")" \
        "an action REACHED Kafka / systemd although its audit record could not be written: ${out}"
    tm_assert_eq "banner=None" "$(grep '^banner=' <<<"$out")" "the settings change was written without its audit record"
    tm_assert_eq "bob_sessions=0" "$(grep '^bob_sessions=' <<<"$out")" "a session was created that the audit trail cannot record"
    tm_assert_eq "sessions_untouched=True" "$(grep '^sessions_untouched=' <<<"$out")" \
        "a sign-in refused for a broken audit trail still CHANGED the session table (it must be refused before it acts)"
    tm_assert_eq "clusters_c2=False" "$(grep '^clusters_c2=' <<<"$out")" "a cluster profile was saved without its audit record"
    tm_assert_eq "staged=False" "$(grep '^staged=' <<<"$out")" "an apply was staged without its audit record"
    grep -q '^crit=[1-9]' <<<"$out" || _tm_afail "no CRIT syslog record for the refusals: ${out}"
    tm_assert_eq "logout=200" "$(grep '^logout=' <<<"$out")" "a sign-out was BLOCKED by the audit failure — it must never be"
}
tm_case "every-mutating-route-refuses-when-the-audit-trail-is-broken" "tmapp,linux" a_routes_fail_closed

a_after_change_is_honest() {
    _setup
    local out
    out="$(_run "${_ROUTES}
from tm import audit
real = audit.require_writable
audit.require_writable = lambda cfg: None     # the store breaks AFTER the pre-check
kafka_client.delete_topic = lambda c, n: (calls.append('delete:' + n), break_audit())
r = c.delete('/api/topics/orders', headers=H)
j = r.get_json()
print('code=%d err=%s' % (r.status_code, j.get('error')))
print('says_made=%s' % ('WAS made' in j.get('message', '')))
print('calls=%s' % calls)
")"
    tm_assert_eq "code=500 err=audit_write_failed" "$(grep '^code=' <<<"$out")" \
        "a change made before the audit store broke was not reported as such: ${out}"
    tm_assert_eq "says_made=True" "$(grep '^says_made=' <<<"$out")" \
        "the response did not say the change WAS made (hazards[misleading-failure-message])"
}
tm_case "a-failure-after-the-change-says-the-change-was-made" "tmapp,linux" a_after_change_is_honest

a_record_fails_after_precheck() {
    # The store passes the pre-check and then refuses the record itself: a
    # sign-in must leave NO session behind, and an apply must be withdrawn
    # (nothing staged, no unit started).
    _setup
    mkdir -p "${TM_TMP}/bin"
    printf '#!/usr/bin/env bash\necho "$*" >> %s/calls\nexit 0\n' "$TM_TMP" > "${TM_TMP}/bin/systemctl"
    chmod 755 "${TM_TMP}/bin/systemctl"; : > "${TM_TMP}/calls"
    local out
    out="$(PATH="${TM_TMP}/bin:${PATH}" _run "${_ROUTES}
from tm import audit
audit.require_writable = lambda cfg: None
break_audit()
anon = app.test_client()
r = anon.post('/api/auth/login', data=json.dumps({'username': 'bob', 'password': 'x'}), headers=H)
print('login=%d %s' % (r.status_code, (r.get_json() or {}).get('error')))
d = db(); print('bob_sessions=%d' % d.execute(\"SELECT COUNT(*) FROM sessions WHERE user='bob'\").fetchone()[0]); d.close()
r = c.post('/api/system/apply/nginx', data='{}', headers=H)
print('apply=%d %s' % (r.status_code, (r.get_json() or {}).get('error')))
st = os.path.join(os.path.dirname(os.environ['TM_TEST_DB']), 'apply')
print('staged=%s' % sorted(os.listdir(st)) if os.path.isdir(st) else 'staged=[]')
")"
    tm_assert_eq "login=503 audit_unavailable" "$(grep '^login=' <<<"$out")" "a sign-in whose LOGIN record failed was let in: ${out}"
    tm_assert_eq "bob_sessions=0" "$(grep '^bob_sessions=' <<<"$out")" \
        "the session created before the LOGIN record failed was left in the database"
    tm_assert_eq "apply=503 audit_unavailable" "$(grep '^apply=' <<<"$out")" "an apply whose request record failed went ahead: ${out}"
    tm_assert_eq "staged=[]" "$(grep '^staged=' <<<"$out")" "an apply whose request record failed was left staged"
    grep -q 'start' "${TM_TMP}/calls" && _tm_afail "the apply unit was started although its request was never recorded"
    true
}
tm_case "a-record-that-fails-after-the-precheck-undoes-sign-in-and-apply" "tmapp,linux" a_record_fails_after_precheck

a_precheck_measures_free_space() {
    _setup
    local out
    out="$(_run "
from tm.config import load_config
from tm.models import init_db
from tm import audit
cfg = load_config(); init_db(cfg); drain()
audit.AUDIT_MIN_FREE_BYTES = 1 << 62      # more than any disk has free
try:
    audit.require_writable(cfg); print('pre=passed')
except audit.AuditUnavailable as e:
    print('pre=refused')
print('crit=%s' % any(g.startswith('<82>') and 'bytes free' in g for g in drain()))
")"
    tm_assert_eq "pre=refused" "$(grep '^pre=' <<<"$out")" \
        "the pre-check passed a filesystem with less free space than it requires (SQLite fails at COMMIT on a full disk)"
    tm_assert_eq "crit=True" "$(grep '^crit=' <<<"$out")" "the full-disk refusal was not reported at CRIT"
}
tm_case "the-precheck-refuses-a-full-disk" linux a_precheck_measures_free_space


tm_finish
