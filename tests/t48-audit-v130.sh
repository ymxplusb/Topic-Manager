#!/usr/bin/env bash
# =============================================================================
# t48 — v1.3.0 AUDIT RECORD CONTENT (James 2026-10-02: DQ6, DQ7; SRG-APP-000089,
# -000098, -000099, -000266, -000360, -000374).
#
#   migrate     the v1.2 table gains source and outcome, every stored ts is
#               rewritten to ISO 8601 Z, ALL IN ONE TRANSACTION with its
#               AUDIT_SCHEMA_MIGRATED row; a migration that cannot record itself
#               changes nothing; a second start changes nothing
#   retention   prunes the right rows AFTER the migration, on the cutoff's own
#               day, where a column holding both formats prunes the wrong ones
#   shape       a row says where it came from and whether it succeeded, in the
#               table, the syslog line and the CSV export
#   failures    a signed-in caller's refused write is recorded (a Kafka
#               refusal under its own action word, everything else as
#               REQUEST_REFUSED); an anonymous one never reaches tm.db
#   reads       every audit read and export is recorded first, or refused
#   errors      a Kafka failure tells the browser nothing about the cluster
#   banner      an audit write failure stays visible until a write succeeds
#
# Every case drives the real modules (or the real app through Flask's test
# client) against a real SQLite file. Kafka and LDAP are stubbed.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "v1.3.0 audit: source/outcome + ISO Z by one-transaction migration, failures, reads, generic errors, banner"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_setup() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs" "${TM_TMP}/data"
    printf 'clusters:\n  - id: c1\n    name: C1\n    bootstrap_servers: "broker-secret.internal:9092"\n    security_protocol: PLAINTEXT\n    active: true\n' \
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
  log_level: "WARNING"
YAML
}

# _py <body>: the modules only (no app). cfg, db(), rows() in scope.
_py() {
    cat > "${TM_TMP}/probe.py" <<PYEOF
import json, os, sqlite3, datetime, re
from tm.config import load_config
cfg = load_config()
def db(): return sqlite3.connect(os.environ['TM_TEST_DB'])
def rows(sql, *a):
    d = db(); r = d.execute(sql, a).fetchall(); d.close(); return r
$1
PYEOF
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 \
        TM_CONFIG="${TM_TMP}/config.yaml" TM_TEST_DB="${TM_TMP}/data/tm.db" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" \
        "$PY" "${TM_TMP}/probe.py" 2> "${TM_TMP}/probe.err" | tr -d '\r'
}

# _app <body>: the real app; c is signed in as admin, anon is not.
_app() {
    _py "
from tm import auth, kafka_client, audit
def refuse(*a, **k):
    raise RuntimeError('KafkaError{code=_TRANSPORT,str=broker-secret.internal:9092/1: Connect to ipv4#203.0.113.77:9092 failed}')
kafka_client.create_topic = refuse
kafka_client.list_topics = refuse
kafka_client.test_connection = lambda c: (False, 'broker-secret.internal:9092 refused')
auth.validate_credentials = lambda cfg, u, p: (True, {'username': u, 'display_name': u})
from tm.app import create_app
import logging
logbuf = []
class Grab(logging.Handler):
    def emit(self, r): logbuf.append(r.getMessage())
logging.getLogger('tm').addHandler(Grab())
logging.getLogger('tm').setLevel(logging.INFO)
app = create_app()
def signed_in(user='admin'):
    cl = app.test_client()
    with cl.session_transaction() as s:
        s['user'] = {'username': user}; s['sid'] = 'sid-' + user
    now = datetime.datetime.now(datetime.timezone.utc)
    d = db(); d.execute('INSERT OR REPLACE INTO sessions VALUES (?,?,?,?,?,?)', ('sid-' + user, user, now.isoformat(), now.isoformat(), (now + datetime.timedelta(hours=1)).isoformat(), 'x')); d.commit(); d.close()
    return cl
c = signed_in()
anon = app.test_client()
H = {'Content-Type': 'application/json', 'X-TM-Request': '1'}
$1"
}

_line() { grep "^$1=" <<<"$2"; }

# A v1.2 database: the old audit_log shape and old-format timestamps.
_OLD_DB='
d = db()
d.execute("CREATE TABLE audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, user TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL, detail TEXT, cluster_id TEXT)")
d.execute("CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)")
old = [("2026-01-02 03:04:05", "alice", "LOGIN", "192.0.2.10", "bind=direct-user", ""),
       ("2026-01-02 03:05:00", "mallory", "LOGIN_FAILED", "192.0.2.66", "reason=Invalid credentials", ""),
       ("2026-01-02 03:06:00", "alice", "CREATE", "orders", "partitions=3", "c1"),
       ("2026-01-02 03:07:00", "alice", "SYSTEM_APPLY_RESULT", "nginx", "job=a state=ok step=done: ok", ""),
       ("2026-01-02 03:08:00", "alice", "SYSTEM_APPLY_RESULT", "time", "job=b state=rolled_back step=test: no", ""),
       ("2026-01-02 03:09:00", "alice", "SERVICE_RESTART_THROTTLED", "topic-manager.service", "refused", ""),
       ("2026-01-02 03:10:00", "alice", "SERVICE_RESTART_STEP", "systemd", "nginx reload FAILED (exit 1): job failed", ""),
       ("2026-01-02 03:10:01", "alice", "SERVICE_RESTART_STEP", "systemd", "topic-manager restart queued", "")]
d.executemany("INSERT INTO audit_log (ts,user,action,target,detail,cluster_id) VALUES (?,?,?,?,?,?)", old)
d.commit(); d.close()
'

a_migration() {
    _setup
    local out
    out="$(_py "${_OLD_DB}
from tm.models import init_db
init_db(cfg)
cols = [r[1] for r in rows('PRAGMA table_info(audit_log)')]
print('cols=%s' % ','.join(cols[-2:]))
print('ts=%s' % sorted({bool(re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', t)) for (t,) in rows('SELECT ts FROM audit_log')}))
print('first=%s' % rows('SELECT ts FROM audit_log WHERE id=1')[0][0])
for a in ('LOGIN', 'LOGIN_FAILED', 'CREATE', 'SERVICE_RESTART_THROTTLED'):
    print('row_%s=%s' % (a, '|'.join(rows('SELECT source, outcome FROM audit_log WHERE action=?', a)[0])))
print('steps=%s' % [o for (o,) in rows(\"SELECT outcome FROM audit_log WHERE action='SERVICE_RESTART_STEP' ORDER BY id\")])
print('outcomes=%s' % sorted({o for (o,) in rows('SELECT outcome FROM audit_log')}))
print('apply=%s' % rows(\"SELECT target, outcome FROM audit_log WHERE action='SYSTEM_APPLY_RESULT' ORDER BY id\"))
m = rows(\"SELECT user, source, outcome, detail FROM audit_log WHERE action='AUDIT_SCHEMA_MIGRATED'\")
print('migrated_rows=%d' % len(m))
print('migrated=%s|%s|%s' % m[0][:3])
print('migrated_detail=%s' % m[0][3])
before = rows('SELECT * FROM audit_log')
init_db(cfg)
print('second_same=%s' % (rows('SELECT * FROM audit_log') == before))
")"
    tm_assert_eq "cols=source,outcome" "$(_line cols "$out")" "the migration did not add source and outcome: ${out}"
    tm_assert_eq "ts=[True]" "$(_line ts "$out")" "a stored timestamp is not ISO 8601 with Z after the migration: ${out}"
    tm_assert_eq "first=2026-01-02T03:04:05Z" "$(_line first "$out")" "the rewrite changed the instant, not just the form"
    # WO-0006 F1: an old row whose record does not state its outcome is
    # 'unknown', never a claimed 'success' - v1.2 wrote a FAILED restart step
    # exactly like a successful one.
    tm_assert_eq "row_LOGIN=192.0.2.10|unknown" "$(_line row_LOGIN "$out")" "a LOGIN row did not get its address as source, or was given an outcome it never recorded"
    tm_assert_eq "row_LOGIN_FAILED=192.0.2.66|failure" "$(_line row_LOGIN_FAILED "$out")" "LOGIN_FAILED is not a failure from its address"
    tm_assert_eq "row_CREATE=unrecorded|unknown" "$(_line row_CREATE "$out")" "a row whose origin or outcome was never recorded claims one"
    tm_assert_eq "steps=['failure', 'unknown']" "$(_line steps "$out")" "an old FAILED restart step is not a failure, or an old step claims a success it never recorded: ${out}"
    tm_assert_eq "outcomes=['failure', 'success', 'unknown']" "$(_line outcomes "$out")" "the migrated table holds an outcome outside success/failure/unknown: ${out}"
    tm_assert_eq "row_SERVICE_RESTART_THROTTLED=unrecorded|failure" "$(_line row_SERVICE_RESTART_THROTTLED "$out")" "a refusal is not a failure"
    tm_assert_eq "apply=[('nginx', 'success'), ('time', 'failure')]" "$(_line apply "$out")" "an old apply result's outcome is not its state"
    tm_assert_eq "migrated_rows=1" "$(_line migrated_rows "$out")" "the migration was not recorded exactly once: ${out}"
    tm_assert_eq "migrated=system|system|success" "$(_line migrated "$out")" "the migration row is not the system's"
    case "$(_line migrated_detail "$out")" in
        *"columns added: source, outcome; 8 timestamp(s) rewritten"*"6 older row(s) have no recorded source"*"3 older row(s) have no recorded outcome (unknown), the rest carry the outcome their record states"*) ;;
        *) _tm_afail "the migration row does not say what it did: ${out}" ;;
    esac
    tm_assert_eq "second_same=True" "$(_line second_same "$out")" "a second start changed the migrated table"
}
tm_case "the-v12-table-is-migrated-in-one-recorded-transaction" none a_migration

a_migration_is_atomic() {
    _setup
    local out
    out="$(_py "${_OLD_DB}
d = db()
d.execute(\"CREATE TRIGGER no_record BEFORE INSERT ON audit_log WHEN NEW.action = 'AUDIT_SCHEMA_MIGRATED' BEGIN SELECT RAISE(ABORT, 'audit store is broken'); END\")
d.commit(); d.close()
from tm.models import init_db
try:
    init_db(cfg); print('raised=no')
except Exception as exc:
    print('raised=%s' % type(exc).__name__)
print('cols=%s' % ','.join(r[1] for r in rows('PRAGMA table_info(audit_log)')))
print('old_ts=%d' % rows(\"SELECT COUNT(*) FROM audit_log WHERE ts LIKE '% %'\")[0][0])
")"
    tm_assert_eq "raised=AuditUnavailable" "$(_line raised "$out")" "a migration that could not record itself did not stop the start: ${out}"
    tm_assert_eq "cols=id,ts,user,action,target,detail,cluster_id" "$(_line cols "$out")" \
        "a failed migration left columns behind: it was not one transaction"
    tm_assert_eq "old_ts=8" "$(_line old_ts "$out")" "a failed migration rewrote timestamps: it was not one transaction"
}
tm_case "a-migration-that-cannot-record-itself-changes-nothing" none a_migration_is_atomic

# A v1.2 table with no rows still gains the columns, and says so; a stray
# old-format row written later (an old worker during an upgrade) is rewritten
# at the next start, and that is recorded too.
a_migration_variants() {
    _setup
    local out
    out="$(_py "
d = db()
d.execute('CREATE TABLE audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, user TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL, detail TEXT, cluster_id TEXT)')
d.commit(); d.close()
from tm.models import init_db
init_db(cfg)
print('empty=%d %s' % (rows(\"SELECT COUNT(*) FROM audit_log WHERE action='AUDIT_SCHEMA_MIGRATED'\")[0][0], rows(\"SELECT detail FROM audit_log\")[0][0].split(';')[0]))
d = db(); d.execute(\"INSERT INTO audit_log (ts,user,action,target,detail,cluster_id,source,outcome) VALUES ('2026-03-04 05:06:07','u','CREATE','late','','','x','success')\"); d.commit(); d.close()
init_db(cfg)
print('late=%s' % rows(\"SELECT ts FROM audit_log WHERE target='late'\")[0][0])
print('late_rows=%d' % rows(\"SELECT COUNT(*) FROM audit_log WHERE action='AUDIT_SCHEMA_MIGRATED'\")[0][0])
print('late_detail=%s' % rows(\"SELECT detail FROM audit_log WHERE action='AUDIT_SCHEMA_MIGRATED' ORDER BY id DESC\")[0][0].split(';')[:2])
")"
    tm_assert_eq "empty=1 audit_log v1.3.0: columns added: source, outcome" "$(_line empty "$out")" \
        "an empty v1.2 table's migration was not recorded: ${out}"
    tm_assert_eq "late=2026-03-04T05:06:07Z" "$(_line late "$out")" "a late old-format row was not rewritten at the next start"
    tm_assert_eq "late_rows=2" "$(_line late_rows "$out")" "a rewrite-only migration was not recorded"
    tm_assert_eq "late_detail=['audit_log v1.3.0: columns added: none', ' 1 timestamp(s) rewritten to ISO 8601 UTC (Z)']" \
        "$(_line late_detail "$out")" "a rewrite-only migration does not say what it did: ${out}"
}
tm_case "an-empty-table-and-a-late-old-row-are-each-migrated-and-recorded" none a_migration_variants

# DQ6: retention compares ts AS STRINGS. Rows on the cutoff's own day, one an
# hour older than the cutoff and one an hour younger, written in the OLD
# format: left unmigrated, " " sorts before "T" and BOTH would be pruned.
a_retention_after_migration() {
    _setup
    local out
    out="$(_py "${_OLD_DB}
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
if now.hour in (0, 23):
    now = now.replace(hour=12)            # keep both test rows on the cutoff's own day
cut = now - datetime.timedelta(days=30)
d = db()
for tag, at in (('older', cut - datetime.timedelta(hours=1)), ('younger', cut + datetime.timedelta(hours=1)),
                ('old', now - datetime.timedelta(days=45)), ('new', now)):
    d.execute('INSERT INTO audit_log (ts,user,action,target,detail,cluster_id) VALUES (?,?,?,?,?,?)',
              (at.strftime('%Y-%m-%d %H:%M:%S'), 'u', 'CREATE', tag, '', ''))
d.execute('DELETE FROM audit_log WHERE target NOT IN (?,?,?,?)', ('older', 'younger', 'old', 'new'))
d.execute(\"INSERT INTO app_settings VALUES ('audit_retention_days', '30')\")
d.commit(); d.close()
from tm.models import init_db
init_db(cfg)
from tm import audit_retention as R
r = R.prune(cfg, now=now)
print('deleted=%d' % r['deleted_age'])
print('left=%s' % sorted(t for (t,) in rows(\"SELECT target FROM audit_log WHERE action='CREATE'\")))
print('oldest=%s' % (R.capacity(cfg, record_crossing=False)['oldest'] == (cut + datetime.timedelta(hours=1)).isoformat()))
")"
    tm_assert_eq "deleted=2" "$(_line deleted "$out")" "retention after the migration did not delete exactly the two older rows: ${out}"
    tm_assert_eq "left=['new', 'younger']" "$(_line left "$out")" \
        "retention after the migration pruned by the wrong order (a mixed-format column): ${out}"
    tm_assert_eq "oldest=True" "$(_line oldest "$out")" "the capacity's oldest entry is not read from the migrated format: ${out}"
}
tm_case "retention-prunes-correctly-after-the-migration" none a_retention_after_migration

a_row_shape() {
    _setup
    local out
    out="$(_py "
from tm.models import init_db
from tm import audit
init_db(cfg)
r = audit.log_action(cfg, 'sys', 'AUDIT_PRUNE', 'audit_log', 'x')
print('outside=%s|%s' % (r['source'], r['outcome']))
print('ts=%s' % bool(re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', r['ts'])))
r = audit.log_action(cfg, 'u', 'CREATE', 't', 'd', 'c1', source='198.51.100.4', outcome='failure')
print('line=%s' % audit.format_record(r))
try:
    audit.log_action(cfg, 'u', 'CREATE', 't', outcome='maybe'); print('bad_outcome=accepted')
except ValueError:
    print('bad_outcome=refused')
try:
    audit.log_action(cfg, 'u', 'CREATE', 't', outcome='unknown'); print('new_unknown=accepted')
except ValueError:
    print('new_unknown=refused')
from flask import Flask
with Flask('x').test_request_context('/', environ_base={'REMOTE_ADDR': '203.0.113.9'}):
    print('inside=%s' % audit.log_action(cfg, 'u', 'DELETE', 't')['source'])
csv = audit.export_audit_csv(cfg).splitlines()
print('header=%s' % csv[0])
print('csvrow=%s' % [l for l in csv if '198.51.100.4' in l][0])
print('page=%s' % sorted(audit.get_audit_log(cfg)['entries'][0]))
")"
    tm_assert_eq "outside=system|success" "$(_line outside "$out")" "a row written outside a request does not say system/success"
    tm_assert_eq "ts=True" "$(_line ts "$out")" "a new row's ts is not ISO 8601 Z"
    case "$(_line line "$out")" in
        'line=action="CREATE" user="u" target="t" cluster="c1" detail="d" ts="'*'Z" source="198.51.100.4" outcome="failure"') ;;
        *) _tm_afail "the syslog line does not append source= and outcome= after the v1.2 keys: ${out}" ;;
    esac
    tm_assert_eq "bad_outcome=refused" "$(_line bad_outcome "$out")" "an outcome outside success|failure was stored"
    tm_assert_eq "new_unknown=refused" "$(_line new_unknown "$out")" "a NEW row was allowed the migration-only outcome 'unknown'"
    tm_assert_eq "inside=203.0.113.9" "$(_line inside "$out")" "a row written in a request does not carry the client address"
    tm_assert_eq 'header="timestamp","user","action","target","detail","cluster_id","source","outcome"' \
        "$(_line header "$out")" "the CSV header does not APPEND source and outcome"
    case "$(_line csvrow "$out")" in
        *'Z","u","CREATE","t","d","c1","198.51.100.4","failure"') ;;
        *) _tm_afail "the CSV row does not carry source and outcome last: ${out}" ;;
    esac
    tm_assert_eq "page=['action', 'cluster_id', 'detail', 'id', 'outcome', 'source', 'target', 'ts', 'user']" \
        "$(_line page "$out")" "the Audit tab's entries lack source or outcome"
}
tm_case "a-row-says-its-source-and-outcome-everywhere-it-goes" none a_row_shape

a_failures_are_audited() {
    _setup
    local out
    out="$(_app "
r = c.post('/api/topics', data=json.dumps({'name': 'orders'}), headers=H)
body = r.get_json()
print('kafka=%d %s' % (r.status_code, body.get('code')))
print('leak=%s' % any(s in json.dumps(body) for s in ('broker-secret', '203.0.113.77', 'KafkaError')))
ref = body.get('reference', '')
print('logged=%s' % any(ref in m and 'broker-secret' in m for m in logbuf))
print('create=%s' % rows(\"SELECT outcome, target, source FROM audit_log WHERE action='CREATE'\"))
print('createdetail=%s' % (ref in rows(\"SELECT detail FROM audit_log WHERE action='CREATE'\")[0][0]))
r = c.post('/api/topics', data=json.dumps({'name': 'bad name'}), headers=H)
print('invalid=%d' % r.status_code)
n = rows('SELECT COUNT(*) FROM audit_log')[0][0]
r = c.put('/api/settings', data=json.dumps({'banner_text': 'x'}), headers={'Content-Type': 'application/json', 'Sec-Fetch-Site': 'cross-site'})
print('csrf=%d' % r.status_code)
# WO-0006 F4: a SAME-SITE sibling host's page posting with the victim's valid
# session cookie is refused, and is NOT written under the victim's name: that
# would let it flood their rows and push real ones out by the row limit.
before = len(logbuf)
for i in range(3):
    r = c.post('/api/topics', data=json.dumps({'name': 'sib%d' % i}), headers={'Content-Type': 'application/json', 'Sec-Fetch-Site': 'same-site'})
print('sibling=%d rows=%d' % (r.status_code, rows('SELECT COUNT(*) FROM audit_log')[0][0] - n))
print('sibling_logged=%d' % sum('ANON_REQUEST_REFUSED status=403' in m and '/api/topics' in m for m in logbuf[before:]))
print('refused=%s' % [(o, d) for o, d in rows(\"SELECT outcome, detail FROM audit_log WHERE action='REQUEST_REFUSED' ORDER BY id\")])
n = rows('SELECT COUNT(*) FROM audit_log')[0][0]
anon.put('/api/settings', data=json.dumps({'banner_text': 'x'}), headers={'Content-Type': 'application/json', 'Sec-Fetch-Site': 'cross-site'})
anon.post('/api/topics', data='{}', headers=H)
anon.get('/api/topics')
print('anon_rows=%d' % (rows('SELECT COUNT(*) FROM audit_log')[0][0] - n))
print('anon_logged=%s' % any('ANON_REQUEST_REFUSED status=403' in m for m in logbuf))
r = c.get('/api/topics')
print('listleak=%d %s' % (r.status_code, 'broker-secret' in r.get_data(as_text=True)))
r = c.get('/api/clusters/c1/test')
print('testleak=%s' % ('broker-secret' in r.get_data(as_text=True)))
# An EXPIRED session's cross-site write is anonymous: not in tm.db.
x = signed_in('ghost')
d = db(); d.execute(\"UPDATE sessions SET expires_at='2000-01-01T00:00:00+00:00' WHERE id='sid-ghost'\"); d.commit(); d.close()
n = rows('SELECT COUNT(*) FROM audit_log')[0][0]
x.put('/api/settings', data=json.dumps({'banner_text': 'x'}), headers={'Content-Type': 'application/json', 'Sec-Fetch-Site': 'cross-site'})
print('ghost_rows=%d' % (rows('SELECT COUNT(*) FROM audit_log')[0][0] - n))
# ...and so is its refused write on a route that answers before require_auth
# (a declined consent, 400): the expired session is nobody's (M656).
n = rows('SELECT COUNT(*) FROM audit_log')[0][0]
r = x.post('/api/auth/consent', data=json.dumps({'accepted': 'no'}), headers=H)
print('ghost_pre_auth=%d rows=%d' % (r.status_code, rows('SELECT COUNT(*) FROM audit_log')[0][0] - n))
# No cluster profile: our own sentence passes through; a write is a 409.
open(os.environ['TM_CLUSTERS_DIR'] + '/clusters.yaml', 'w').write('clusters: []\\n')
r = c.get('/api/topics')
print('nocluster=%d %s' % (r.status_code, r.get_json().get('code')))
print('nocluster_text=%s' % r.get_json()['error'].startswith('No cluster profile is configured yet'))
r = c.post('/api/topics', data=json.dumps({'name': 'x1'}), headers=H)
print('nocluster_write=%d' % r.status_code)
")"
    tm_assert_eq "kafka=502 kafka_error" "$(_line kafka "$out")" "a Kafka refusal is not a 502 with the generic code: ${out}"
    tm_assert_eq "leak=False" "$(_line leak "$out")" "the browser was told the broker's name, address or the library's text"
    tm_assert_eq "logged=True" "$(_line logged "$out")" "the service log does not hold the detail under the reference"
    tm_assert_eq "create=[('failure', 'orders', '127.0.0.1')]" "$(_line create "$out")" \
        "a refused topic write was not recorded under CREATE with outcome failure: ${out}"
    tm_assert_eq "createdetail=True" "$(_line createdetail "$out")" "the failure row does not name the reference"
    tm_assert_eq "invalid=400" "$(_line invalid "$out")" "an invalid name was not refused"
    tm_assert_eq "csrf=403" "$(_line csrf "$out")" "a cross-site write was not refused"
    tm_assert_eq "refused=[('failure', 'POST api.create_topic -> HTTP 400: Invalid topic name')]" \
        "$(_line refused "$out")" "a signed-in caller's 400 is not a REQUEST_REFUSED row, or a cross-site 403 was written under the session user: ${out}"
    tm_assert_eq "sibling=403 rows=0" "$(_line sibling "$out")" \
        "a same-site sibling's write with a valid session was not refused, or was written to the audit trail under the session user: ${out}"
    tm_assert_eq "sibling_logged=3" "$(_line sibling_logged "$out")" "a refused cross-site write went to neither the trail nor the anonymous log"
    tm_assert_eq "anon_rows=0" "$(_line anon_rows "$out")" "an anonymous refusal reached the audit database"
    tm_assert_eq "anon_logged=True" "$(_line anon_logged "$out")" "an anonymous refusal went nowhere at all"
    tm_assert_eq "listleak=502 False" "$(_line listleak "$out")" "a Kafka read error leaks the broker"
    tm_assert_eq "testleak=False" "$(_line testleak "$out")" "the cluster test leaks the broker"
    tm_assert_eq "ghost_rows=0" "$(_line ghost_rows "$out")" "an expired session's refused write reached the audit database"
    tm_assert_eq "ghost_pre_auth=400 rows=0" "$(_line ghost_pre_auth "$out")" \
        "an expired session's refused write (before require_auth) was recorded under its user: ${out}"
    tm_assert_eq "nocluster=502 no_cluster" "$(_line nocluster "$out")" "a missing cluster profile is reported as a Kafka failure: ${out}"
    tm_assert_eq "nocluster_text=True" "$(_line nocluster_text "$out")" "the product's own no-cluster sentence was replaced"
    tm_assert_eq "nocluster_write=409" "$(_line nocluster_write "$out")" "a write with no cluster profile is not a 409"
}
tm_case "signed-in-failures-are-audited-anonymous-ones-are-not-and-nothing-leaks" tmapp a_failures_are_audited

a_audit_reads_are_audited() {
    _setup
    local out
    out="$(_app "
r = c.get('/api/audit?page=1&per_page=10')
print('read=%d %s' % (r.status_code, [e['action'] for e in r.get_json()['entries']]))
r = c.get('/api/audit/export')
print('export=%d %s' % (r.status_code, r.get_data(as_text=True).splitlines()[1].split(',')[2]))
print('rows=%s' % rows(\"SELECT action, detail, outcome FROM audit_log WHERE action IN ('AUDIT_READ','AUDIT_EXPORT') ORDER BY id\"))
# WO-0006 af2: the row is written AFTER the read, and a read that FAILS is a
# failure row, not the success row it used to be (written first, then the read
# raised). The read itself is broken here; the audit store is not.
real_get, real_csv = audit.get_audit_log, audit.export_audit_csv
def boom(*a, **k): raise OSError('disk I/O error')
audit.get_audit_log = boom; audit.export_audit_csv = boom
r = c.get('/api/audit?page=2&per_page=5')
print('readfail=%d %s %s' % (r.status_code, r.get_json().get('code'), 'disk' in r.get_data(as_text=True)))
r = c.get('/api/audit/export')
print('exportfail=%d %s' % (r.status_code, r.get_json().get('code')))
audit.get_audit_log, audit.export_audit_csv = real_get, real_csv
print('failrows=%s' % rows(\"SELECT action, detail, outcome FROM audit_log WHERE outcome = 'failure' AND action IN ('AUDIT_READ','AUDIT_EXPORT') ORDER BY id\"))
d = db(); d.execute(\"CREATE TRIGGER t_broken BEFORE INSERT ON audit_log BEGIN SELECT RAISE(ABORT, 'broken'); END\"); d.commit(); d.close()
r = c.get('/api/audit/export')
print('broken=%d %s %s' % (r.status_code, r.get_json().get('error'), 'timestamp' in r.get_data(as_text=True)))
print('broken_read=%d' % c.get('/api/audit').status_code)
# A change refused because the audit store is broken (the pre-check of an
# audit_gate route, which writes no row of its own) is NOT recorded again by
# the refusal recorder: one AUDIT_WRITE_FAILED per refused change, not two.
crit = []
audit.syslog_send = lambda msg, sev=6: crit.append(msg) or True
r = c.delete('/api/topics/orders', headers=H)
print('refused_broken=%d %s crit=%d' % (r.status_code, r.get_json().get('error'), sum('AUDIT_WRITE_FAILED' in m for m in crit)))
")"
    # The read does not contain its own row: it was written after the read.
    tm_assert_eq "read=200 []" "$(_line read "$out")" "an audit read recorded itself BEFORE it read (or not at all): ${out}"
    tm_assert_eq 'export=200 "AUDIT_READ"' "$(_line export "$out")" "an export recorded itself BEFORE it was built: ${out}"
    case "$(_line rows "$out")" in
        "rows=[('AUDIT_READ', 'page=1 per_page=10', 'success'), ('AUDIT_EXPORT', 'CSV export of 1 row(s)', 'success')]") ;;
        *) _tm_afail "the read and export rows do not say what was read: ${out}" ;;
    esac
    tm_assert_eq "readfail=500 audit_read_failed False" "$(_line readfail "$out")" "a failed audit read was not a 500 (or leaked the database's words): ${out}"
    tm_assert_eq "exportfail=500 audit_read_failed" "$(_line exportfail "$out")" "a failed export was not a 500: ${out}"
    tm_assert_eq "failrows=[('AUDIT_READ', 'page=2 per_page=5 failed: OSError', 'failure'), ('AUDIT_EXPORT', 'CSV export failed: OSError', 'failure')]" \
        "$(_line failrows "$out")" "a failed audit read or export was not recorded as a failure: ${out}"
    tm_assert_eq "broken=503 audit_unavailable False" "$(_line broken "$out")" "an export was served with its record unwritable"
    tm_assert_eq "broken_read=503" "$(_line broken_read "$out")" "a read was served with its record unwritable"
    tm_assert_eq "refused_broken=503 audit_unavailable crit=1" "$(_line refused_broken "$out")" \
        "a change refused for a broken audit store was recorded twice (or not refused): ${out}"
}
tm_case "every-audit-read-and-export-is-recorded-after-with-its-outcome" tmapp a_audit_reads_are_audited

a_write_failure_banner() {
    _setup
    local out
    out="$(_py "
from tm.models import init_db
from tm import audit, audit_retention as R
init_db(cfg)
print('never=%s' % R.capacity(cfg, record_crossing=False)['write_failure'])
d = db(); d.execute(\"CREATE TRIGGER t_broken BEFORE INSERT ON audit_log BEGIN SELECT RAISE(ABORT, 'broken'); END\"); d.commit(); d.close()
try:
    audit.log_action(cfg, 'u', 'CREATE', 't')
except audit.AuditUnavailable:
    pass
w = R.capacity(cfg, record_crossing=False)['write_failure']
print('failed=%s %s %s' % (w['current'], w['action'], w['reason']))
print('delivered=%s' % w['syslog_delivered'])      # no syslog socket here: refused
real_send = audit.syslog_send
audit.syslog_send = lambda msg, sev=6: True
try:
    audit.log_action(cfg, 'u', 'CREATE', 't')
except audit.AuditUnavailable:
    pass
audit.syslog_send = real_send
print('delivered_ok=%s' % R.capacity(cfg, record_crossing=False)['write_failure']['syslog_delivered'])
print('mode=%o' % (os.stat(os.path.join(os.path.dirname(os.environ['TM_TEST_DB']), 'audit-write-failure.json')).st_mode & 0o777))
d = db(); d.execute('DROP TRIGGER t_broken'); d.commit(); d.close()
audit.log_action(cfg, 'u', 'CREATE', 't')
w = R.capacity(cfg, record_crossing=False)['write_failure']
print('recovered=%s %s' % (w['current'], bool(w['recovered_at'])))
")"
    tm_assert_eq "never=None" "$(_line never "$out")" "a store that never failed reports a failure"
    tm_assert_eq "failed=True CREATE IntegrityError" "$(_line failed "$out")" "a failed audit write left no lasting sign: ${out}"
    # WO-0006: the state says whether the syslog took the record, so the banner
    # does not claim it did.
    tm_assert_eq "delivered=False" "$(_line delivered "$out")" "a record the syslog refused is reported as delivered (or not at all): ${out}"
    tm_assert_eq "delivered_ok=True" "$(_line delivered_ok "$out")" "a record the syslog accepted is not reported as delivered: ${out}"
    tm_assert_eq "mode=600" "$(_line mode "$out")" "the failure state file is readable beyond the service account"
    tm_assert_eq "recovered=False True" "$(_line recovered "$out")" "a successful write did not mark the failure recovered: ${out}"
}
tm_case "an-audit-write-failure-stays-visible-until-a-write-succeeds" none a_write_failure_banner

a_banner_is_rendered() {
    local js="${TM_SETTINGS_SOURCE:-${TM_REPO_ROOT}/app/components/SettingsTab.js}" at="${TM_AUDITTAB_JS:-${TM_REPO_ROOT}/app/components/AuditTab.js}"
    grep -q 'v-if="hostPanels.capacity?.write_failure?.current"' "$js" || _tm_afail "Settings has no audit-failure banner bound to write_failure.current"
    grep -q 'v-if="writeFailure && writeFailure.current"' "$at" || _tm_afail "the Audit tab has no audit-failure banner"
    # WO-0006: each banner says what happened to the record, not always "the syslog".
    local f x
    for f in "$js:hostPanels.capacity.write_failure" "$at:writeFailure"; do
        x="${f##*:}"
        grep -qF "<template v-if=\"${x}.syslog_delivered === true\">the record went to the host syslog" "${f%:*}" \
            || _tm_afail "$(basename "${f%:*}") does not say the syslog took it only when it did"
        grep -qF "<template v-else-if=\"${x}.syslog_delivered === false\">the host syslog did NOT accept the record either" "${f%:*}" \
            || _tm_afail "$(basename "${f%:*}") does not say when the syslog refused it"
        [ "$(grep -c 'the record went to the host syslog as AUDIT_WRITE_FAILED' "${f%:*}")" = 1 ] || _tm_afail "$(basename "${f%:*}") still claims syslog delivery unconditionally"
    done
    grep -q "fetch('/api/audit/capacity'" "$at" || _tm_afail "the Audit tab does not read the failure state"
    grep -q '<th>Source</th>' "$at" || _tm_afail "the Audit tab has no Source column"
    grep -q '<th>Outcome</th>' "$at" || _tm_afail "the Audit tab has no Outcome column"
}
tm_case "the-banner-and-the-new-columns-are-in-the-ui" none a_banner_is_rendered

# The anonymous-refusal limiter: BURST lines per WINDOW, then one summary.
# WO-0006 F1: a restart step that FAILED is audited with outcome failure. The
# steps run detached, after the 202; the callback used to pass no outcome, so
# log_action's default recorded "nginx reload FAILED" as a success.
a_restart_step_outcome() {
    _setup
    local out
    out="$(_app "
from tm import service_control
service_control._FLUSH_DELAY = 0
service_control.claim_restart_slot = lambda cfg: (True, 0)     # three restarts in one test
service_control.nginx_config_test = lambda: (True, 'syntax is ok')
service_control.restart_detached = lambda h, cb: service_control._restart_sequence(h, cb)
RC = {}
service_control._unit_action = lambda verb, unit, extra=(): (RC.get(unit, 0), 'stubbed %s' % verb)
def steps():
    return rows(\"SELECT detail, outcome FROM audit_log WHERE action='SERVICE_RESTART_STEP' ORDER BY id\")
RC = {service_control.NGINX_UNIT: 1}
r = c.post('/api/service/restart', data='{}', headers=H)
print('status=%d' % r.status_code)
print('nginx_failed=%s' % [(d.split(' (')[0], o) for d, o in steps()])
d = db(); d.execute('DELETE FROM audit_log'); d.commit(); d.close()
RC = {service_control.SERVICE_UNIT: 1}
c.post('/api/service/restart', data='{}', headers=H)
print('tm_failed=%s' % [(d.split(' (')[0], o) for d, o in steps()])
d = db(); d.execute('DELETE FROM audit_log'); d.commit(); d.close()
RC = {service_control.SERVICE_UNIT: -15}
c.post('/api/service/restart', data='{}', headers=H)
print('self_kill=%s' % [o for d, o in steps()])
")"
    tm_assert_eq "status=202" "$(_line status "$out")" "the restart was not accepted: ${out} $(cat "${TM_TMP}/probe.err")"
    tm_assert_eq "nginx_failed=[('nginx reload FAILED', 'failure'), ('topic-manager restart queued', 'success')]" \
        "$(_line nginx_failed "$out")" "a FAILED nginx step is not audited as a failure (false success): ${out}"
    tm_assert_eq "tm_failed=[('nginx reloaded', 'success'), ('topic-manager restart FAILED', 'failure')]" \
        "$(_line tm_failed "$out")" "a FAILED topic-manager restart step is not audited as a failure: ${out}"
    tm_assert_eq "self_kill=['success', 'success']" "$(_line self_kill "$out")" \
        "the expected self-kill (SIGTERM) of the worker is recorded as a failure"
}
tm_case "a-failed-restart-step-is-audited-as-a-failure" tmapp a_restart_step_outcome

# WO-0006 LOW: a cluster profile whose PEM the parser refuses answers one
# sentence and a reference (the library's text goes to the service log); our
# own validation sentences still name the field that is wrong.
a_parser_text_is_not_returned() {
    _setup
    local out
    out="$(_app "
base = {'id': 'c9', 'name': 'C9', 'bootstrap_servers': 'h:9093', 'security_protocol': 'SSL'}
bad_key = '-----BEGIN PRIVATE KEY-----\\nTUlJQ2RnSUJBREFOQmdrcWhraUc5dzBCQVFFRkFBU0NBbUF3Z2dKY0FnRUFBb0dCQUxPRw==\\n-----END PRIVATE KEY-----\\n'
r = c.post('/api/clusters', data=json.dumps(dict(base, ssl_keyfile_pem=bad_key)), headers=H)
b = r.get_json()
print('key=%d %s' % (r.status_code, b.get('code')))
print('key_generic=%s' % (b['error'].startswith('The certificate or key material could not be parsed.') and b.get('reference', '') in b['error']))
print('key_logged=%s' % any(b.get('reference', '?') in m and 'cluster profile material' in m for m in logbuf))
bad_cert = '-----BEGIN CERTIFICATE-----\\nAAAA\\n-----END CERTIFICATE-----\\n'
r = c.post('/api/clusters', data=json.dumps(dict(base, ssl_cafile_pem=bad_cert)), headers=H)
print('cert=%d %s' % (r.status_code, r.get_json().get('code')))
r = c.post('/api/clusters', data=json.dumps(dict(base, security_protocol='BOGUS')), headers=H)
print('own=%d %s' % (r.status_code, r.get_json()['error'].startswith('security_protocol must be one of')))
")"
    tm_assert_eq "key=400 material_unparsed" "$(_line key "$out")" "an unparsable key did not answer the generic refusal: ${out} $(cat "${TM_TMP}/probe.err")"
    tm_assert_eq "key_generic=True" "$(_line key_generic "$out")" "the refusal carries the parser's text, or no reference: ${out}"
    tm_assert_eq "key_logged=True" "$(_line key_logged "$out")" "the parser's text is not in the service log under the reference"
    tm_assert_eq "cert=400 material_unparsed" "$(_line cert "$out")" "an unparsable certificate did not answer the generic refusal: ${out}"
    tm_assert_eq "own=400 True" "$(_line own "$out")" "the product's own validation sentence was replaced: ${out}"
}
tm_case "a-parser-refusal-answers-a-sentence-and-a-reference" tmapp a_parser_text_is_not_returned

a_anonymous_limiter() {
    local out
    out="$(PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 "$PY" - <<'PYEOF' 2>&1 | tr -d '\r'
import logging
from tm import routes
lines = []
class Grab(logging.Handler):
    def emit(self, r): lines.append(r.getMessage())
routes.log.addHandler(Grab()); routes.log.setLevel(logging.INFO)
now = [1000.0]
routes.time.monotonic = lambda: now[0]
lim = routes._AnonymousRefusals()
got = [lim.note(403, 'PUT', '/api/x', '192.0.2.1') for _ in range(12)]
print('first=%d logged=%d' % (got.count(True), len(lines)))
now[0] += lim.WINDOW + 1
lim.note(401, 'GET', '/api/y', '192.0.2.2')
print('summary=%s' % [l for l in lines if 'more refused' in l])
print('after=%d' % len(lines))
PYEOF
)"
    tm_assert_eq "first=10 logged=10" "$(grep '^first=' <<<"$out")" "the limiter does not log exactly the first 10 in a window: ${out}"
    tm_assert_eq "summary=['ANON_REQUEST_REFUSED: 2 more refused anonymous request(s) in the last 60 s were not logged one by one']" \
        "$(grep '^summary=' <<<"$out")" "the suppressed refusals are not summarised when the window closes: ${out}"
    tm_assert_eq "after=12" "$(grep '^after=' <<<"$out")" "a new window does not log again"
}
tm_case "anonymous-refusals-are-logged-ten-a-minute-then-summarised" tmapp a_anonymous_limiter

tm_finish
