#!/usr/bin/env bash
# =============================================================================
# t33 — AUDIT RETENTION AND CAPACITY (v1.2.0; SRG-APP-000120/000357/000359).
#
# Owner ruling 2026-09-26: prune by AGE and by ROW COUNT only, and every prune
# that deletes writes AUDIT_PRUNE — in the SAME transaction as the delete, so
# a prune that cannot record itself deletes nothing. The capacity warning is
# raised once per upward crossing of audit_warn_pct and re-armed below it.
#
# Driven through the real tm/audit_retention.py against a real SQLite file.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "audit retention: age and rows, audited in one transaction; capacity warning once per crossing"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_setup() {
    local NT; NT="$(cygpath -m "$TM_TMP" 2>/dev/null || printf '%s' "$TM_TMP")"
    printf 'audit:\n  db_path: "%s/tm.db"\n' "$NT" > "${TM_TMP}/config.yaml"
    mkdir -p "${TM_TMP}/clusters.d"
    printf 'clusters: []\n' > "${TM_TMP}/clusters.d/clusters.yaml"
}

_run() {
    cat > "${TM_TMP}/probe.py" <<PYEOF
import os, sqlite3, datetime
from tm.config import load_config
from tm.models import init_db, get_db
from tm import audit_retention as R, audit
cfg = load_config(); init_db(cfg)
def db(): return get_db(cfg)
def setting(k, v):
    d = db(); d.execute('INSERT OR REPLACE INTO app_settings VALUES (?,?)', (k, v)); d.commit(); d.close()
def add_rows(n, days_ago, action='CREATE'):
    # v1.3.0: rows are written in the stored format, ISO 8601 Z (tm/audit.TS_FORMAT).
    ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days_ago)).strftime(audit.TS_FORMAT)
    d = db(); d.executemany('INSERT INTO audit_log (ts,user,action,target,detail,cluster_id) VALUES (?,?,?,?,?,?)',
                            [(ts, 'u', action, 't%d' % i, '', '') for i in range(n)]); d.commit(); d.close()
def count(where='1=1'):
    d = db(); n = d.execute('SELECT COUNT(*) FROM audit_log WHERE ' + where).fetchone()[0]; d.close(); return n
$1
PYEOF
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 TM_CONFIG="${TM_TMP}/config.yaml" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" \
        "$PY" "${TM_TMP}/probe.py" 2>&1 | tr -d '\r'
}

a_prune_by_age() {
    _setup
    local out
    out="$(_run "
setting('audit_retention_days', '30')
add_rows(7, 45); add_rows(5, 29); add_rows(3, 0)
r = R.prune(cfg)
print('deleted_age=%d deleted_rows=%d' % (r['deleted_age'], r['deleted_rows']))
print('left_create=%d' % count(\"action='CREATE'\"))
print('prune_rows=%d' % count(\"action='AUDIT_PRUNE'\"))
d = db(); det = d.execute(\"SELECT user, target, detail FROM audit_log WHERE action='AUDIT_PRUNE'\").fetchone(); d.close()
print('prune=%s|%s|%s' % det)
print('last=%s' % (R.capacity(cfg, record_crossing=False)['last_prune'] is not None))
r2 = R.prune(cfg)
print('second=%d prune_rows2=%d' % (r2['deleted_age'] + r2['deleted_rows'], count(\"action='AUDIT_PRUNE'\")))
")"
    tm_assert_eq "deleted_age=7 deleted_rows=0" "$(grep '^deleted_age=' <<<"$out")" \
        "prune did not delete exactly the rows older than 30 days: ${out}"
    tm_assert_eq "left_create=8" "$(grep '^left_create=' <<<"$out")" "rows inside the retention window were deleted: ${out}"
    tm_assert_eq "prune_rows=1" "$(grep '^prune_rows=' <<<"$out")" "the deletion wrote no AUDIT_PRUNE record: ${out}"
    grep -q '^prune=system|audit_log|deleted 7: 7 older than 30 days' <<<"$out" \
        || _tm_afail "AUDIT_PRUNE does not say what was deleted and why: ${out}"
    tm_assert_eq "last=True" "$(grep '^last=' <<<"$out")" "the last prune time was not recorded"
    tm_assert_eq "second=0 prune_rows2=1" "$(grep '^second=' <<<"$out")" \
        "a prune that deleted nothing still wrote an AUDIT_PRUNE row (or deleted something): ${out}"
}
tm_case "prune-deletes-by-age-and-records-it" none a_prune_by_age

# WO-0006 D4: a prune that deletes nothing writes no AUDIT_PRUNE row (above),
# and the docs now say so; --dry-run says beforehand what a prune would do,
# exactly as prune() then does it, and writes nothing at all.
a_prune_dry_run() {
    _setup
    local out
    out="$(_run "
import hashlib, subprocess, sys
setting('audit_retention_days', '30'); setting('audit_max_rows', '10000')
add_rows(4, 45); add_rows(10000, 5); add_rows(3, 1)
def dump():
    d = db(); h = hashlib.sha256(repr(d.execute('SELECT * FROM audit_log ORDER BY id').fetchall()).encode() + repr(d.execute('SELECT * FROM app_settings ORDER BY key').fetchall()).encode()).hexdigest(); d.close(); return h
before = dump()
now = datetime.datetime.now(datetime.timezone.utc)
p = R.preview(cfg, now=now)
cli = subprocess.run([sys.executable, '-m', 'tm.audit_retention', '--dry-run'], capture_output=True, text=True)
print('cli_rc=%d' % cli.returncode)
print('cli=%s' % cli.stdout.strip())
print('unchanged=%s' % (dump() == before))
r = R.prune(cfg, now=now)
print('same=%s' % ({k: p[k] for k in ('deleted_age', 'deleted_rows', 'oldest')} == {k: r[k] for k in ('deleted_age', 'deleted_rows', 'oldest')}))
print('remaining=%s' % (p['remaining'] + 1 == r['remaining']))
print('counts=%d %d' % (p['deleted_age'], p['deleted_rows']))
setting('audit_max_rows', '20000')       # nothing old, nothing over the limit now
cli = subprocess.run([sys.executable, '-m', 'tm.audit_retention', '--dry-run'], capture_output=True, text=True)
print('noop=%s' % cli.stdout.strip().endswith('Nothing to delete: a prune now would write no AUDIT_PRUNE row.'))
")"
    tm_assert_eq "cli_rc=0" "$(grep '^cli_rc=' <<<"$out")" "--dry-run failed: ${out}"
    case "$(grep '^cli=' <<<"$out")" in
        "cli=audit prune --dry-run: would delete 4 older than 30 days"*" and 4 beyond the 10000-row limit; 9999 rows would remain"*"A prune would write AUDIT_PRUNE.") ;;
        *) _tm_afail "--dry-run does not say what a prune would delete: ${out}" ;;
    esac
    tm_assert_eq "unchanged=True" "$(grep '^unchanged=' <<<"$out")" "--dry-run changed the database"
    tm_assert_eq "same=True" "$(grep '^same=' <<<"$out")" "the preview disagrees with the prune that followed: ${out}"
    tm_assert_eq "remaining=True" "$(grep '^remaining=' <<<"$out")" "the preview's remaining count is not the prune's (less its own row): ${out}"
    tm_assert_eq "counts=4 4" "$(grep '^counts=' <<<"$out")" "the preview counted the wrong rows: ${out}"
    tm_assert_eq "noop=True" "$(grep '^noop=' <<<"$out")" "--dry-run on a pruned table does not say a prune would write nothing: ${out}"
}
tm_case "a-dry-run-says-what-a-prune-would-do-and-writes-nothing" none a_prune_dry_run

a_prune_by_rows() {
    _setup
    local out
    out="$(_run "
setting('audit_max_rows', '10000')
add_rows(10050, 1)
d = db(); first_kept = d.execute('SELECT id FROM audit_log ORDER BY id LIMIT 1 OFFSET 51').fetchone()[0]; d.close()
r = R.prune(cfg)
print('deleted_rows=%d' % r['deleted_rows'])
print('total=%d' % count())
d = db(); oldest = d.execute(\"SELECT MIN(id) FROM audit_log WHERE action='CREATE'\").fetchone()[0]; d.close()
print('oldest_is_expected=%s' % (oldest == first_kept))
")"
    tm_assert_eq "deleted_rows=51" "$(grep '^deleted_rows=' <<<"$out")" \
        "prune by rows did not delete down to max_rows - 1 (then + AUDIT_PRUNE): ${out}"
    tm_assert_eq "total=10000" "$(grep '^total=' <<<"$out")" "the table does not hold exactly audit_max_rows after a prune"
    tm_assert_eq "oldest_is_expected=True" "$(grep '^oldest_is_expected=' <<<"$out")" \
        "prune by rows did not delete the OLDEST rows first: ${out}"
}
tm_case "prune-by-row-limit-deletes-the-oldest" none a_prune_by_rows

a_prune_is_atomic() {
    _setup
    local out
    out="$(_run "
setting('audit_retention_days', '30')
add_rows(4, 90)
d = db(); d.execute(\"CREATE TRIGGER t BEFORE INSERT ON audit_log WHEN NEW.action='AUDIT_PRUNE' BEGIN SELECT RAISE(ABORT,'x'); END\"); d.commit(); d.close()
try:
    R.prune(cfg); print('raised=no')
except Exception:
    print('raised=yes')
print('still=%d' % count())
print('main=%d' % R.main(['--config', os.environ['TM_CONFIG']]))
")"
    tm_assert_eq "raised=yes" "$(grep '^raised=' <<<"$out")" "a prune whose AUDIT_PRUNE failed reported success: ${out}"
    tm_assert_eq "still=4" "$(grep '^still=' <<<"$out")" \
        "rows were DELETED although the prune could not record itself: ${out}"
    tm_assert_eq "main=1" "$(grep '^main=' <<<"$out")" "the timer entry point exits 0 on a failed prune"
}
tm_case "a-prune-that-cannot-record-itself-deletes-nothing" none a_prune_is_atomic

a_capacity_crossing() {
    _setup
    local out
    out="$(_run "
setting('audit_max_rows', '10000'); setting('audit_warn_pct', '75')
add_rows(7400, 1)
c1 = R.capacity(cfg)
print('below=%s pct=%s' % (c1['warning'], c1['pct']))
add_rows(200, 1)
c2 = R.capacity(cfg); c3 = R.capacity(cfg); c4 = R.capacity(cfg)
print('above=%s warns=%d' % (c2['warning'], count(\"action='AUDIT_CAPACITY_WARNING'\")))
d = db(); d.execute(\"DELETE FROM audit_log WHERE action='CREATE' AND id % 2 = 0\"); d.commit(); d.close()
c5 = R.capacity(cfg)
add_rows(4000, 1)
c6 = R.capacity(cfg)
print('rearmed=%s %s warns=%d' % (c5['warning'], c6['warning'], count(\"action='AUDIT_CAPACITY_WARNING'\")))
print('keys=%s' % ','.join(sorted(c6)))
")"
    grep -q '^below=False pct=74' <<<"$out" || _tm_afail "74% was reported as a warning (or wrong pct): ${out}"
    tm_assert_eq "above=True warns=1" "$(grep '^above=' <<<"$out")" \
        "crossing 75% did not warn EXACTLY once over three capacity reads: ${out}"
    tm_assert_eq "rearmed=False True warns=2" "$(grep '^rearmed=' <<<"$out")" \
        "falling below and crossing again did not warn a second time: ${out}"
    tm_assert_eq "keys=last_prune,max_rows,oldest,pct,retention_days,rows,warn_pct,warning,write_failure" \
        "$(grep '^keys=' <<<"$out")" "the capacity document is not the contract's shape"
}
tm_case "capacity-warns-once-per-crossing" none a_capacity_crossing

a_prune_unit_and_db_mode() {
    local u="${TM_REPO_ROOT}/systemd/topic-manager-audit-prune.service"
    tm_assert_file "$u"
    grep -qx 'UMask=0077' "$u" || _tm_afail "the prune unit does not set UMask=0077 (it does not inherit the service's)"
    grep -qx 'User=topic-manager' "$u" || _tm_afail "the prune unit does not run as the service account"
    grep -q '^ExecStart=/opt/topic-manager/venv/bin/python3 -m tm.audit_retention$' "$u" \
        || _tm_afail "the prune unit does not run tm.audit_retention"
    grep -qx 'OnCalendar=daily' "${TM_REPO_ROOT}/systemd/topic-manager-audit-prune.timer" \
        || _tm_afail "the prune timer is not daily"
    _setup
    ( umask 022; _run "print('ok')" >/dev/null )
    tm_assert_mode 600 "${TM_TMP}/tm.db" "the prune entry point created tm.db wider than 0600"
}
tm_case "prune-runs-as-the-service-umask-0077-and-db-stays-0600" modes a_prune_unit_and_db_mode

tm_finish
