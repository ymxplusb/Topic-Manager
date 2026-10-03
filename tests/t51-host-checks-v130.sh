#!/usr/bin/env bash
# =============================================================================
# t51 — v1.3.0 HOST STIG CHECKS AND THE COMPLIANCE PAGE (James 2026-10-02:
# DQ1, DQ2, DQ3, DQ4, DQ10).
#
#   measure    the root helper's `compliance --report`, against a fixture host
#              and a canned `nginx -T`: host state the product does not own is
#              a WARN (never changed), the product's own files a FAIL, and a
#              FAIL is the report's exit code
#   staged     the same checks through the Settings path (staged request, the
#              fixed unit's command): verdict ok, checks in the result, the
#              staged request refused if it carries settings
#   site logs  ensure_site_logs creates the product's logs 0640 web:adm,
#              narrows an existing 0644 one and a rotated copy, and refuses a
#              symlink — byte-identical in install.sh and the upgrade
#   syslog     install.sh refuses to start without --syslog-host or
#              --no-remote-syslog; the upgrade's refusal is not --force-able
#   page       GET /api/compliance carries every rule, its status and the
#              application's own live checks
#   issuer     a self-signed server certificate is a warning (NGNX-APP-001900)
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "v1.3.0 host checks: warn on host state, fail on the product's own, site logs 0640, syslog required, the compliance page"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

# A fixture host root: a compliant stock Ubuntu web account and /etc/nginx,
# the product's files as install.sh lays them down, and a fake `nginx -T` that
# prints the dump in $R/dump (built from the SHIPPED site and log format).
_host() {
    R="${TM_TMP}/root"; RB="${TM_TMP}/bin"
    mkdir -p "$R"/etc/nginx/{conf.d,snippets,sites-available,sites-enabled,modules-enabled} \
        "$R"/var/log/nginx "$R"/etc/topic-manager/tls "$R"/etc/logrotate.d "$RB"
    # Ubuntu's own nginx stanza, as nginx-common ships it (measured, bookworm/noble).
    printf '/var/log/nginx/*.log {\n\tdaily\n\tmissingok\n\trotate 14\n\tcompress\n\tdelaycompress\n\tnotifempty\n\tcreate 0640 www-data adm\n\tsharedscripts\n\tpostrotate\n\t\tinvoke-rc.d nginx rotate >/dev/null 2>&1\n\tendscript\n}\n' \
        > "$R/etc/logrotate.d/nginx"
    printf 'root:x:0:0:root:/root:/bin/bash\nwww-data:x:33:33:www-data:/var/www:/usr/sbin/nologin\n' > "$R/etc/passwd"
    printf 'root:x:0:\nadm:x:4:syslog\nwww-data:x:33:\nsudo:x:27:admin\n' > "$R/etc/group"
    printf 'root:!:19000::::::\nwww-data:*:19000:0:99999:7:::\n' > "$R/etc/shadow"
    printf 'user www-data;\nworker_processes auto;\n' > "$R/etc/nginx/nginx.conf"
    cp "$(tm_nginx_site)" "$R/etc/nginx/sites-available/topic-manager"
    cp "${TM_LOG_FORMAT:-${TM_REPO_ROOT}/nginx/tm-log-format.conf}" "$R/etc/nginx/conf.d/topic-manager-log-format.conf"
    cp "${TM_REPO_ROOT}/nginx/tm-security-headers.conf" "$R/etc/nginx/snippets/tm-security-headers.conf"
    chmod -R go-w "$R/etc/nginx"
    : > "$R/var/log/nginx/topic-manager-access.log"; : > "$R/var/log/nginx/topic-manager-error.log"
    : > "$R/var/log/nginx/topic-manager-access.log.1"
    chown 33:4 "$R"/var/log/nginx/topic-manager-*.log*; chmod 640 "$R"/var/log/nginx/topic-manager-*.log*
    : > "$R/etc/topic-manager/tls/server.key"; chmod 600 "$R/etc/topic-manager/tls/server.key"
    {
        printf '# configuration file /etc/nginx/nginx.conf:\nuser www-data;\nevents {\n    worker_connections 768;\n}\nhttp {\n'
        printf '    ssl_protocols TLSv1.2 TLSv1.3; # managed by Topic Manager\n'
        printf '    access_log /var/log/nginx/access.log;\n    error_log /var/log/nginx/error.log;\n}\n'
        printf '# configuration file /etc/nginx/conf.d/topic-manager-log-format.conf:\n'
        cat "${TM_LOG_FORMAT:-${TM_REPO_ROOT}/nginx/tm-log-format.conf}"
        printf '# configuration file /etc/nginx/sites-enabled/topic-manager:\n'
        cat "$(tm_nginx_site)"
    } > "$R/dump"
    # A configuration that fails nginx -t still dumps: the exit code is the verdict.
    printf '#!/bin/sh\n[ "$1" = -T ] || exit 0\ncat "%s/dump"\n[ -f "%s/nginx.fail" ] && exit 1\nexit 0\n' "$R" "$R" > "$RB/nginx"
    chmod 755 "$RB/nginx"
}

_report() {   # _report -> REPORT (the report's text) and REPORT_RC, in the CALLER's shell
    REPORT_RC=0
    python3 -I "$(tm_apply_helper)" compliance --report --root "$R" --bin "$RB" > "${TM_TMP}/report" 2>&1 || REPORT_RC=$?
    REPORT="$(tr -d '\r' < "${TM_TMP}/report")"
}

_st() { awk -F'\t' -v k="$1" '$2 == k { print $1 }' <<<"$2"; }

a_compliant_host_passes() {
    _host
    local out k
    _report; out="$REPORT"
    tm_assert_eq "0" "$REPORT_RC" "a compliant host fails the report: ${out}"
    for k in web_account_shell web_account_groups web_account_password nginx_config_modes site_log_modes \
             nginx_modules tls_protocols nginx_log_format server_tokens error_pages nginx_http_logs tls_key_mode; do
        case "$(_st "$k" "$out")" in
            PASS) ;;
            INFO) [ "$k" = nginx_http_logs ] || _tm_afail "${k} is INFO on a compliant host: ${out}" ;;
            *) _tm_afail "${k} is not PASS on a compliant host: ${out}" ;;
        esac
    done
    tm_assert_eq "INFO" "$(_st worker_connections "$out")" "worker_connections is not reported as information"
    grep -q 'worker_connections 768' <<<"$out" || _tm_afail "the measured worker_connections is not named: ${out}"
    grep -q 'both site logs and 1 rotated copy are 0640 www-data adm' <<<"$out" || _tm_afail "the site-log check does not say what it measured: ${out}"
}
tm_case "a-compliant-host-passes-every-check" chown a_compliant_host_passes

a_host_state_warns() {
    _host
    sed -i 's#www-data:/var/www:/usr/sbin/nologin#www-data:/var/www:/bin/bash#' "$R/etc/passwd"
    sed -i 's#^adm:x:4:syslog#adm:x:4:syslog,www-data#' "$R/etc/group"
    sed -i 's#^www-data:\*:#www-data:$6$abc$def:#' "$R/etc/shadow"
    chmod g+w "$R/etc/nginx/nginx.conf"
    sed -i 's/create 0640 www-data adm/create 0644 root root/' "$R/etc/logrotate.d/nginx"
    printf 'load_module modules/ngx_http_geoip_module.so;\n' >> "$R/dump"
    printf '# configuration file /etc/nginx/sites-enabled/other:\nserver {\n    ssl_protocols TLSv1 TLSv1.2;\n}\n' >> "$R/dump"
    local before out k
    before="$(cd "$R" && find etc -type f -exec sha256sum {} + | sort)"
    _report; out="$REPORT"
    tm_assert_eq "0" "$REPORT_RC" "host state the product does not own FAILED the report (it must only warn): ${out}"
    for k in web_account_shell web_account_groups web_account_password nginx_config_modes nginx_modules tls_protocols site_log_modes; do
        tm_assert_eq "WARN" "$(_st "$k" "$out")" "${k} on host-owned state is not a WARN: ${out}"
    done
    grep -q 'logrotate.d/nginx does not recreate the logs it rotates as "create 0640 www-data adm" (create 0644 root root)' <<<"$out" \
        || _tm_afail "the OS logrotate stanza's create is not named: ${out}"
    grep -q 'administrative group(s) adm' <<<"$out" || _tm_afail "the admin group is not named: ${out}"
    grep -q 'ngx_http_geoip_module' <<<"$out" || _tm_afail "the loaded module is not named"
    tm_assert_eq "$before" "$(cd "$R" && find etc -type f -exec sha256sum {} + | sort)" \
        "the check CHANGED the host (DQ2: verify and report only)"
}
tm_case "host-state-the-product-does-not-own-is-a-warning-and-untouched" chown a_host_state_warns

a_product_drift_fails() {
    local k mut out
    for mut in site_log rotated rotated_owner live_owner site_mode format uses errors tokens key tls; do
        _host
        case "$mut" in
            site_log) chmod 644 "$R/var/log/nginx/topic-manager-error.log"; k=site_log_modes ;;
            rotated)  : > "$R/var/log/nginx/topic-manager-access.log.1"; chmod 644 "$R/var/log/nginx/topic-manager-access.log.1"; k=site_log_modes ;;
            # WO-0006 D6: the tm-qc shape - a rotated copy root:root 0640 - and a
            # live log root-owned; both used to pass (root was accepted).
            rotated_owner) : > "$R/var/log/nginx/topic-manager-error.log.2.gz"; chown 0:0 "$R/var/log/nginx/topic-manager-error.log.2.gz"; chmod 640 "$R/var/log/nginx/topic-manager-error.log.2.gz"; k=site_log_modes ;;
            live_owner) chown 0:4 "$R/var/log/nginx/topic-manager-access.log"; k=site_log_modes ;;
            site_mode) chmod g+w "$R/etc/nginx/sites-available/topic-manager"; k=nginx_config_modes ;;
            format)   sed -i 's/ \$request_id//' "$R/dump"; k=nginx_log_format ;;
            uses)     sed -i 's#topic-manager-access.log tm_dod;#topic-manager-access.log;#' "$R/dump"; k=nginx_log_format ;;
            errors)   sed -i '/error_page 500 502 503 504 @tm_unavailable;/d' "$R/dump"; k=error_pages ;;
            tokens)   sed -i 's/server_tokens       off;/server_tokens on;/' "$R/dump"; k=server_tokens ;;
            key)      chmod 640 "$R/etc/topic-manager/tls/server.key"; k=tls_key_mode ;;
            tls)      sed -i 's/ssl_protocols       TLSv1.2 TLSv1.3;/ssl_protocols TLSv1.1 TLSv1.2;/' "$R/dump"; k=tls_protocols ;;
        esac
        _report; out="$REPORT"
        tm_assert_eq "FAIL" "$(_st "$k" "$out")" "drift of the product's own (${mut}) is not a FAIL of ${k}: ${out}"
        tm_assert_eq "1" "$REPORT_RC" "a FAIL (${mut}) did not make the report exit 1"
    done
    _host; printf 'x' > "$R/nginx.fail"
    _report; out="$REPORT"
    tm_assert_eq "UNKNOWN" "$(_st nginx_log_format "$out")" "a check nginx could not answer was guessed: ${out}"
}
tm_case "drift-of-the-products-own-files-fails-the-report" chown a_product_drift_fails

# WO-0006 LOW: a probe that raises is reported by its exception TYPE only; the
# text (paths, host details) goes to the journal, not to the result the page shows.
a_broken_probe_reports_type_only() {
    _host
    local out
    out="$(python3 -I - "$(tm_apply_helper)" "$R" "$RB" <<'PYEOF' 2>"${TM_TMP}/stderr" | tr -d '\r'
import argparse, importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader('tm_apply_probe', sys.argv[1])
spec = importlib.util.spec_from_loader('tm_apply_probe', loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
def broken(ctx):
    raise RuntimeError('SECRET-DETAIL /etc/topic-manager/tls/server.key')
m.check_tls_key = broken
ctx = m.Ctx(argparse.Namespace(domain='compliance', report=True, root=sys.argv[2], bin=sys.argv[3], lib=None, svc_user=None))
internal = [c for c in m.compliance_checks(ctx) if c['key'] == 'internal']
print('n=%d' % len(internal))
print('detail=%s' % internal[0]['detail'])
PYEOF
)"
    tm_assert_eq "n=1" "$(grep '^n=' <<<"$out")" "the broken probe was not reported once: ${out} $(cat "${TM_TMP}/stderr")"
    tm_assert_eq "detail=a check failed with RuntimeError; the detail is in journalctl -u topic-manager-apply-compliance" \
        "$(grep '^detail=' <<<"$out")" "the result carries the exception's text, not just its type: ${out}"
    grep -q 'SECRET-DETAIL' "${TM_TMP}/stderr" || _tm_afail "the exception's text did not reach the journal (stderr)"
}
tm_case "a-broken-probe-is-reported-by-type-its-text-goes-to-the-journal" "linux,chown" a_broken_probe_reports_type_only

# WO-0006 LOW: the read-only measurement unit may write its result directory,
# nginx's pid file, the nginx logs nginx -T opens and the staging - not all of /run.
a_compliance_unit_writes_little() {
    local u="${TM_REPO_ROOT}/systemd/topic-manager-apply-compliance.service"
    tm_assert_eq "ReadWritePaths=-/opt/topic-manager/data/apply /run/topic-manager-apply -/run/nginx.pid /var/log/nginx" \
        "$(grep '^ReadWritePaths=' "$u")" "the compliance unit's writable set changed (all of /run is too much for a measurement)"
    tm_assert_eq "ProtectSystem=strict" "$(grep '^ProtectSystem=' "$u")" "the compliance unit is not read-only everywhere else"
    tm_assert_eq "RuntimeDirectory=topic-manager-apply" "$(grep '^RuntimeDirectory=' "$u")" "the result directory is not the unit's runtime directory"
    grep -q "^RESULT_DIR = '/run/topic-manager-apply'$" "$(tm_apply_helper)" || _tm_afail "the helper writes its result somewhere the unit does not allow"
}
tm_case "the-compliance-unit-writes-only-what-a-measurement-needs" none a_compliance_unit_writes_little

a_staged_measurement() {
    . "${TM_TESTS_DIR}/lib/apply_fixture.sh"
    fx_setup
    local job before
    before="$(fx_hash_managed)"
    job="$(fx_stage compliance '{}')"
    fx_helper compliance
    tm_assert_eq "0" "$FX_RC" "the compliance measurement failed: $(cat "${TM_TMP}/helper.out")"
    tm_assert_eq "ok ${job}" "$(fx_field "d['state'] + ' ' + d['job']")" "the measurement's verdict is not ok for its job"
    tm_assert_eq "True" "$(fx_field "len(d['checks']) >= 13 and all(set(c) == {'key','status','detail'} for c in d['checks'])")" \
        "the verdict does not carry the checks"
    case "$(fx_field "d['message']")" in "compliance measured: "*"Nothing on the host was changed.") ;;
        *) _tm_afail "the verdict does not say it measured and changed nothing: $(fx_field "d['message']")" ;; esac
    tm_assert_eq "$before" "$(fx_hash_managed)" "the measurement changed the host"
    fx_stage_raw compliance "{\"domain\":\"compliance\",\"job\":\"00000000000000c1\",\"requested_by\":\"t\",\"files\":{},\"settings\":{\"x\":\"y\"}}"
    fx_helper compliance
    case "$(fx_field "d['state'] + ' ' + d['message']")" in
        "failed "*"a compliance measurement carries no settings"*) ;;
        *) _tm_afail "a measurement request carrying settings was not refused: $(fx_field "d['message']")" ;;
    esac
}
tm_case "the-settings-path-measures-and-changes-nothing" "linux,chown" a_staged_measurement

# ─── ensure_site_logs, from install.sh, identical in the upgrade ─────────────
_SHARED_START='^# >>> v1.3.0 host STIG checks'
_SHARED_END='^# <<< v1.3.0 host STIG checks$'

a_shared_block_identical() {
    local a b
    a="$(tm_extract_between "$(tm_install_sh)" "$_SHARED_START" "$_SHARED_END")"
    b="$(tm_extract_between "$(tm_upgrade_sh)" "$_SHARED_START" "$_SHARED_END")"
    [ "$a" = "$b" ] || _tm_afail "the host STIG block differs between install.sh and the upgrade: $(diff <(echo "$a") <(echo "$b") | head -5)"
}
tm_case "the-host-stig-block-is-byte-identical-in-both-scripts" none a_shared_block_identical

a_ensure_site_logs() {
    local blk d out rc
    blk="$(tm_extract_between "$(tm_install_sh)" "$_SHARED_START" "$_SHARED_END")"
    d="${TM_TMP}/log"; mkdir -p "$d"
    : > "$d/topic-manager-error.log"; chmod 644 "$d/topic-manager-error.log"; chown root:root "$d/topic-manager-error.log"
    : > "$d/topic-manager-access.log.1"; chmod 644 "$d/topic-manager-access.log.1"; chown root:root "$d/topic-manager-access.log.1"
    : > "$d/other.log"; chmod 644 "$d/other.log"
    out="$(bash -c "${blk}"$'\n'"ensure_site_logs '$d' www-data")"; rc=$?
    tm_assert_eq "0" "$rc" "ensure_site_logs failed on a fixable directory: ${out}"
    tm_assert_eq "640 www-data adm" "$(stat -c '%a %U %G' "$d/topic-manager-access.log")" "a missing site log was not created 0640 www-data:adm"
    tm_assert_eq "640 www-data adm" "$(stat -c '%a %U %G' "$d/topic-manager-error.log")" "an existing 0644 site log was not narrowed"
    tm_assert_eq "640 www-data adm" "$(stat -c '%a %U %G' "$d/topic-manager-access.log.1")" "a rotated copy kept its other-read bit or its root owner (WO-0006 D6)"
    tm_assert_eq "644" "$(stat -c '%a' "$d/other.log")" "a log that is not the product's was changed"
    # The symlink points at a SCRATCH file: a mutant that follows it must not
    # damage the host it runs on (it once chmod'ed a container's /etc/passwd).
    : > "${TM_TMP}/victim"; chmod 644 "${TM_TMP}/victim"
    rm -f "$d/topic-manager-error.log"; ln -s "${TM_TMP}/victim" "$d/topic-manager-error.log"
    out="$(bash -c "${blk}"$'\n'"ensure_site_logs '$d' www-data")"; rc=$?
    tm_assert_eq "1" "$rc" "a symlinked site log was accepted"
    case "$out" in *"(a symlink)"*) ;; *) _tm_afail "the refusal does not name the symlink: ${out}" ;; esac
    tm_assert_eq "644 root" "$(stat -c '%a %U' "${TM_TMP}/victim")" "ensure_site_logs followed the symlink"
    # A directory someone other than root can write: a checked name could be
    # swapped for a link before root chowns it. Refused, nothing touched.
    rm -f "$d/topic-manager-error.log"
    local d2="${TM_TMP}/log2"; mkdir -p "$d2"; chmod 775 "$d2"
    : > "$d2/topic-manager-access.log.1"; chmod 644 "$d2/topic-manager-access.log.1"
    out="$(bash -c "${blk}"$'\n'"ensure_site_logs '$d2' www-data")"; rc=$?
    tm_assert_eq "1" "$rc" "a group-writable log directory was accepted"
    case "$out" in *"is not root-owned and closed to group/other writes"*) ;; *) _tm_afail "the refusal does not say why: ${out}" ;; esac
    tm_assert_eq "644 root" "$(stat -c '%a %U' "$d2/topic-manager-access.log.1")" "a log in a writable directory was touched"
    chmod 755 "$d2"; chown 33 "$d2"
    out="$(bash -c "${blk}"$'\n'"ensure_site_logs '$d2' www-data")"; rc=$?
    tm_assert_eq "1" "$rc" "a log directory owned by the web account was accepted"
    # The verify, not the chown, is the guarantee: a chown that reports success
    # and changes nothing (a filesystem that ignores ownership) is caught.
    local d3="${TM_TMP}/log3"; mkdir -p "$d3"
    : > "$d3/topic-manager-access.log"; : > "$d3/topic-manager-error.log"; : > "$d3/topic-manager-error.log.1"
    chown root:root "$d3"/topic-manager-*; chmod 640 "$d3"/topic-manager-*
    out="$(bash -c 'chown() { :; }'$'\n'"${blk}"$'\n'"ensure_site_logs '$d3' www-data")"; rc=$?
    tm_assert_eq "1" "$rc" "logs left root:root by a chown that did nothing were accepted: ${out}"
    case "$out" in *"topic-manager-error.log.1 (640 root root)"*) ;; *) _tm_afail "the rotated copy left root:root is not named: ${out}" ;; esac
    out="$(bash -c "${blk}"$'\n'"host_stig_report '${TM_TMP}/no-such-helper'")"; rc=$?
    tm_assert_eq "0" "$rc" "a missing helper made the report fail rather than say so"
    case "$out" in UNKNOWN$'\t'host_checks$'\t'*"is missing, so the host STIG checks were not run") ;;
        *) _tm_afail "a missing helper is not SAID: ${out}" ;; esac
}
tm_case "the-site-logs-are-created-and-narrowed-never-through-a-symlink" chown a_ensure_site_logs

# ─── DQ10: no silent on-host-only audit trail ───────────────────────────────
a_install_requires_a_collector() {
    local blk host noflag saved got
    blk="$(tm_extract_between "$(tm_install_sh)" '^saved_remote_syslog\(\) \{' '^    \|\| warn "--no-remote-syslog: ')"
    for c in "::no:refused" "logs.example.org::no:ok" ":true:no:ok" ":true:yes:ok" "logs.example.org:true:no:refused" "::yes:ok"; do
        IFS=: read -r host noflag saved want <<<"$c"
        mkdir -p "${TM_TMP}/d"; rm -f "${TM_TMP}/d/tm.db"
        if [ "$saved" = yes ]; then
            "$PY" -c "import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute('CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)'); d.execute(\"INSERT INTO app_settings VALUES ('syslog_enabled','true')\"); d.commit()" "${TM_TMP}/d/tm.db"
        fi
        got="$(DATA_DIR="${TM_TMP}/d" OPT_SYSLOG_HOST="$host" OPT_NO_REMOTE_SYSLOG="${noflag:-false}" bash -c '
            die() { echo refused; exit 1; }; warn() { :; }
            '"${blk}"'
            echo ok')"
        tm_assert_eq "$want" "$got" "install.sh with --syslog-host='${host}' --no-remote-syslog=${noflag:-false} saved=${saved}"
    done
}
tm_case "an-install-refuses-without-a-collector-or-an-explicit-no" none a_install_requires_a_collector

a_upgrade_block_is_not_forceable() {
    local up blk out
    up="$(tm_upgrade_sh)"
    blk="$(tm_extract_between "$up" '^if \[\[ \$SYSLOG_HARD_BLOCK == true \]\]; then$' '^fi   # the remote-syslog hard block \(t51\)$')"
    out="$(SYSLOG_HARD_BLOCK=true FORCE=true AUDIT_BLOCK=1 BACKUP_DIR=/b bash -c 'fail() { echo "FAILED: $1"; exit 1; }
'"${blk}"'
echo proceeded')"
    case "$out" in "FAILED: Refusing to upgrade: the audit trail would stay on this host"*"--force does not override this"*) ;;
        *) _tm_afail "--force got past the remote-syslog block: ${out}" ;; esac
    grep -q '^        --no-remote-syslog) NO_REMOTE_SYSLOG=true ;;$' "$up" || _tm_afail "the upgrade has no --no-remote-syslog"
    grep -q 'row BLOCK "remote syslog" "OFF: re-run with --syslog-host <collector> or --no-remote-syslog' "$up" \
        || _tm_afail "the upgrade does not block an unacknowledged on-host-only audit trail"
}
tm_case "the-upgrade-refuses-without-a-collector-and-force-does-not-override" none a_upgrade_block_is_not_forceable

# ─── the page ────────────────────────────────────────────────────────────────
a_compliance_page() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/data" "${TM_TMP}/run"
    printf 'clusters: []\n' > "${TM_TMP}/clusters.d/clusters.yaml"
    printf 'server:\n  secret_key: "%s"\nauth:\n  ldap_server: "ldaps://dc.example.org:636"\n  ldap_domain: example.org\n  ldap_base_dn: "DC=example,DC=org"\naudit:\n  db_path: "%s/data/tm.db"\nlogging:\n  log_level: CRITICAL\n' \
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "$TM_TMP" > "${TM_TMP}/config.yaml"
    mkdir -p "${TM_TMP}/bin"; printf '#!/bin/sh\nexit 0\n' > "${TM_TMP}/bin/systemctl"; chmod 755 "${TM_TMP}/bin/systemctl"
    printf '1\n' > "${TM_TMP}/fips"
    printf '{"domain":"compliance","job":"00000000000000d1","state":"ok","finished_at":"2026-10-02T10:00:00+00:00","message":"m","details":[],"checks":[{"key":"site_log_modes","status":"fail","detail":"0644"},{"key":"web_account_shell","status":"pass","detail":"nologin","extra":"dropped"},{"key":"BAD KEY","status":"pass","detail":"x"}]}' \
        > "${TM_TMP}/run/compliance.result"
    local out
    out="$(PATH="${TM_TMP}/bin:${PATH}" PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 TM_CONFIG="${TM_TMP}/config.yaml" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" TM_APPLY_RESULT_DIR="${TM_TMP}/run" \
        TM_TLS_CERT="${TM_TMP}/no.crt" TM_FIPS_FLAG="${TM_TMP}/fips" "$PY" - <<'PYEOF' 2>"${TM_TMP}/err" | tr -d '\r'
import datetime, json, os, sqlite3
from tm.app import create_app
app = create_app()
c = app.test_client()
with c.session_transaction() as s:
    s['user'] = {'username': 'admin'}; s['sid'] = 'sa'
now = datetime.datetime.now(datetime.timezone.utc)
d = sqlite3.connect(os.environ['TM_CONFIG'].replace('config.yaml', 'data/tm.db'))
d.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('sa', 'admin', now.isoformat(), now.isoformat(), (now + datetime.timedelta(hours=1)).isoformat(), 'x'))
d.execute("INSERT OR REPLACE INTO app_settings VALUES ('session_max_concurrent', '0')")
d.commit(); d.close()
print('anon=%d' % app.test_client().get('/api/compliance').status_code)
doc = c.get('/api/compliance').get_json()
print('rules=%d' % len(doc['rules']))
by = {r['id']: r for r in doc['rules']}
chk = lambda rid, k: [x for x in by[rid]['checks'] if x['key'] == k][0]
print('site=%s %s' % (chk('NGNX-APP-000400', 'site_log_modes')['status'], chk('NGNX-APP-000400', 'site_log_modes')['where']))
print('shell=%s' % sorted(chk('NGNX-APP-000140', 'web_account_shell')))
print('groups=%s' % chk('NGNX-APP-000150', 'web_account_groups')['status'])
print('cap=%s' % chk('NGNX-APP-000010', 'session_cap')['status'])
print('consent=%s' % chk('NGNX-APP-000180', 'consent_notice')['status'])
print('syslog=%s' % chk('SRG-APP-000515-DB-000318', 'remote_syslog')['status'])
print('ext=%s' % chk('SRG-APP-000141-DB-000093', 'sqlite_extensions')['status'])
print('db=%s' % chk('SRG-APP-000118-DB-000059', 'db_modes')['status'])
print('recheck=%s' % chk('NGNX-APP-003330', 'group_recheck')['status'])
print('open=%s' % ','.join(doc['open_items']))
print('measured=%s' % doc['host']['measured_at'])
print('nomet=%s' % by['NGNX-APP-000720']['status'])
for k in ('fips_mode', 'time_sync', 'tls_issuer', 'audit_write_state'):
    rid = {'fips_mode': 'NGNX-APP-002660', 'time_sync': 'SRG-APP-000920-DB-000320', 'tls_issuer': 'NGNX-APP-001900',
           'audit_write_state': 'SRG-APP-000089-DB-000064'}[k]
    print('%s=%s' % (k, chk(rid, k)['status']))
from tm import apply as A
from tm.config import load_config
cfg = load_config()
st = A.status(cfg, 'compliance')
print('clean=%s' % sorted(c['key'] for c in st['checks']))
d = sqlite3.connect(os.environ['TM_CONFIG'].replace('config.yaml', 'data/tm.db'))
print('result_row=%s' % d.execute("SELECT source, outcome FROM audit_log WHERE action='SYSTEM_APPLY_RESULT' AND target='compliance'").fetchall())
d.close()
# A result that lands while the service runs, recorded by a status poll from a browser:
# still the system's row, with the helper's own (failed) outcome.
open(os.path.join(os.environ['TM_APPLY_RESULT_DIR'], 'nginx.result'), 'w').write(json.dumps({'domain': 'nginx', 'job': '00000000000000e1', 'state': 'rolled_back', 'requested_by': 'admin', 'finished_at': '2026-10-02T11:00:00+00:00', 'message': 'nginx failed', 'details': []}))
c.get('/api/system/apply/nginx')
d = sqlite3.connect(os.environ['TM_CONFIG'].replace('config.yaml', 'data/tm.db'))
print('polled_row=%s' % d.execute("SELECT source, outcome FROM audit_log WHERE action='SYSTEM_APPLY_RESULT' AND target='nginx'").fetchall())
d.close()
os.unlink(os.path.join(os.environ['TM_APPLY_RESULT_DIR'], 'compliance.result'))
os.makedirs(os.path.join(os.path.dirname(os.environ['TM_CONFIG']), 'data', 'apply'), exist_ok=True)
open(os.path.join(os.path.dirname(os.environ['TM_CONFIG']), 'data', 'apply', 'compliance.last'), 'w').write(json.dumps({'job': '00000000000000d1', 'requested_at': '2026-10-02T09:59:00+00:00'}))
print('after_reboot=%s' % [c['key'] for c in A.status(cfg, 'compliance').get('checks', [])])
# The failing cases: a database wider than 0600/0700, and FIPS off.
dbp = os.environ['TM_CONFIG'].replace('config.yaml', 'data/tm.db')
os.chmod(dbp, 0o644)
open(os.environ['TM_FIPS_FLAG'], 'w').write('0\n')
doc = c.get('/api/compliance').get_json()
by = {r['id']: r for r in doc['rules']}
print('wide_db=%s' % chk('SRG-APP-000118-DB-000059', 'db_modes')['status'])
print('fips_off=%s' % chk('NGNX-APP-002660', 'fips_mode')['status'])
os.chmod(dbp, 0o600)
r = c.post('/api/system/apply/compliance', data='{}', headers={'Content-Type': 'application/json', 'X-TM-Request': '1'})
print('post=%d' % r.status_code)
staged = json.load(open(os.path.join(os.path.dirname(os.environ['TM_CONFIG']), 'data', 'apply', 'compliance.json')))
print('staged=%s %s' % (staged['settings'], staged['files']))
PYEOF
)"
    tm_assert_eq "anon=401" "$(grep '^anon=' <<<"$out")" "the compliance page answers without sign-in: ${out} $(cat "${TM_TMP}/err")"
    tm_assert_eq "rules=75" "$(grep '^rules=' <<<"$out")" "the page does not carry every board rule"
    tm_assert_eq "site=fail host" "$(grep '^site=' <<<"$out")" "the host's measured FAIL is not on the page"
    tm_assert_eq "shell=['detail', 'key', 'status', 'where']" "$(grep '^shell=' <<<"$out")" "a result field outside the contract reached the page"
    tm_assert_eq "groups=unknown" "$(grep '^groups=' <<<"$out")" "an unmeasured host check is not 'unknown'"
    tm_assert_eq "cap=warn" "$(grep '^cap=' <<<"$out")" "an unlimited session cap is not a warning"
    tm_assert_eq "consent=warn" "$(grep '^consent=' <<<"$out")" "the consent notice OFF is not an open item"
    tm_assert_eq "syslog=warn" "$(grep '^syslog=' <<<"$out")" "remote syslog never applied is not an open item"
    tm_assert_eq "ext=pass" "$(grep '^ext=' <<<"$out")" "load_extension is not measured as refused"
    tm_assert_eq "db=pass" "$(grep '^db=' <<<"$out")" "the database modes are not measured"
    tm_assert_eq "recheck=warn" "$(grep '^recheck=' <<<"$out")" "a host with no service account does not say the re-check cannot run"
    case "$(grep '^open=' <<<"$out")" in *consent_notice*remote_syslog*session_cap*site_log_modes*) ;;
        *) _tm_afail "the open items do not list the warnings and the failure: ${out}" ;; esac
    tm_assert_eq "measured=2026-10-02T10:00:00+00:00" "$(grep '^measured=' <<<"$out")" "the host measurement time is not shown"
    tm_assert_eq "nomet=NOT-MET" "$(grep '^nomet=' <<<"$out")" "a deferred rule is not shown NOT-MET"
    tm_assert_eq "fips_mode=pass" "$(grep '^fips_mode=' <<<"$out")" "FIPS mode on is not a pass"
    tm_assert_eq "time_sync=warn" "$(grep '^time_sync=' <<<"$out")" "an unsynchronised (unmeasurable) clock is not a warning"
    tm_assert_eq "tls_issuer=unknown" "$(grep '^tls_issuer=' <<<"$out")" "an unreadable certificate is guessed about"
    tm_assert_eq "audit_write_state=pass" "$(grep '^audit_write_state=' <<<"$out")" "a healthy audit store is not a pass"
    tm_assert_eq "clean=['site_log_modes', 'web_account_shell']" "$(grep '^clean=' <<<"$out")" \
        "a malformed check key from the result file reached the status: ${out}"
    tm_assert_eq "polled_row=[('system', 'failure')]" "$(grep '^polled_row=' <<<"$out")" \
        "an apply result recorded by a poll is the poller's, or is not the helper's outcome: ${out}"
    tm_assert_eq "result_row=[('system', 'success')]" "$(grep '^result_row=' <<<"$out")" \
        "the measurement's SYSTEM_APPLY_RESULT is not the system's, with the helper's outcome"
    tm_assert_eq "after_reboot=['site_log_modes', 'web_account_shell']" "$(grep '^after_reboot=' <<<"$out")" \
        "the measured checks are lost when /run is (a reboot)"
    tm_assert_eq "wide_db=fail" "$(grep '^wide_db=' <<<"$out")" "a database wider than 0600 is not a failure"
    tm_assert_eq "fips_off=warn" "$(grep '^fips_off=' <<<"$out")" "FIPS mode off is not a warning"
    tm_assert_eq "post=202" "$(grep '^post=' <<<"$out")" "Measure host now is refused: ${out} $(cat "${TM_TMP}/err")"
    tm_assert_eq "staged=() {}" "$(grep '^staged=' <<<"$out" | sed 's/{} {}/() {}/')" "the measurement request carries settings or files: ${out}"
}
tm_case "the-compliance-page-carries-every-rule-and-its-measurements" tmapp a_compliance_page

a_issuer_warning() {
    local out
    out="$(PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
from tm import hoststatus as h
s = h.issuer_status({'subject': 'CN=tm.example.org', 'issuer': 'CN=tm.example.org'})
print('self=%s %s' % (s['self_signed'], 'DoD-approved' in s['warning']))
s = h.issuer_status({'subject': 'CN=tm.example.org', 'issuer': 'CN=Example CA,O=Example'})
print('ca=%s %s' % (s['self_signed'], 'Confirm' in s['warning']))
print('none=%s' % h.issuer_status({'subject': '', 'issuer': ''}))
" 2>&1 | tr -d '\r')"
    tm_assert_eq "self=True True" "$(grep '^self=' <<<"$out")" "a self-signed certificate is not a warning naming the rule: ${out}"
    tm_assert_eq "ca=False True" "$(grep '^ca=' <<<"$out")" "a CA-issued certificate does not ask the operator to confirm the CA"
    tm_assert_eq "none={'self_signed': None, 'warning': ''}" "$(grep '^none=' <<<"$out")" "an unreadable certificate is guessed about"
    grep -q '<dd v-if="hostPanels.tls.issuer_warning"' "${TM_SETTINGS_SOURCE:-${TM_REPO_ROOT}/app/components/SettingsTab.js}" || _tm_afail "the TLS pane does not show the issuer warning"
}
tm_case "a-self-signed-certificate-is-a-warning-on-the-tls-pane" none a_issuer_warning

# The Settings side of v1.3.0, executed: the compliance CSV, End sessions and
# the consent text, from the real SettingsTab under node.
a_settings_v130() {
    local js="${TM_SETTINGS_SOURCE:-${TM_REPO_ROOT}/app/components/SettingsTab.js}"
    node - "$js" <<'JSEOF' > "${TM_TMP}/out" 2>&1 || _tm_afail "$(cat "${TM_TMP}/out")"
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const calls = [];
let csv = null, answer = { ok: true, status: 200, json: async () => ({ ok: true, ended: 2, sessions: [] }) };
const sandbox = { ClusterModal: {}, console, AbortController, setTimeout, clearTimeout, Date,
    fetch: async (url, opts = {}) => { calls.push([url, opts.method || 'GET', opts.body]); return answer; },
    Blob: function (parts) { csv = parts.join(''); }, URL: { createObjectURL: () => 'blob:x' },
    document: { createElement: () => ({ click() {} }), getElementById: () => null, body: { style: {} } } };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8') + '\n;globalThis.__S = SettingsTab; globalThis.__csv = settingsComplianceCsv;', sandbox);
(async () => {
    const doc = { rules: [{ id: 'R-1', sev: 'CAT I', decision: 'Yes', status: 'MET', title: 'T q', checks: [{ key: 'k1', where: 'host', status: 'fail', detail: 'd"1' }, { key: 'k2', where: 'app', status: 'pass', detail: 'd2' }] },
                          { id: 'R-2', sev: 'CAT II', decision: 'No', status: 'NOT-MET', title: 'U', checks: [] }],
                  host: { measured_at: '2026-10-02T10:00:00+00:00' } };
    const lines = sandbox.__csv(doc).split('\n');
    assert.equal(lines[0], '"Rule","Severity","Decision","Status","Live check","Where","Result","Detail","Title"');
    assert.equal(lines[1], '"R-1","CAT I","Yes","MET","k1","host","fail","d""1","T q"');
    assert.equal(lines[2], '"R-1","CAT I","Yes","MET","k2","app","pass","d2","T q"');
    assert.equal(lines[3], '"R-2","CAT II","No","NOT-MET","","","","","U"');
    assert.ok(lines[4].startsWith('"Host measured","2026-10-02T10:00:00+00:00"'));
    const S = sandbox.__S;
    const inst = Object.assign({}, S.data());
    for (const [k, f] of Object.entries(S.methods)) inst[k] = f.bind(inst);
    inst.compliance = doc; inst.downloadCompliance(); assert.ok(csv && csv.startsWith('"Rule"'), 'the download is not the CSV');
    await inst.endSessions('bob');
    await inst.endSessions(null);
    const ends = calls.filter(c => c[0] === '/api/sessions/end');
    assert.deepEqual(ends.map(c => [c[1], JSON.parse(c[2])]), [['POST', { user: 'bob' }], ['POST', { all: true }]]);
    assert.equal(inst.sessionsMessage, '✓ Ended 2 session(s).');
    answer = { ok: false, status: 503, json: async () => ({ error: 'audit_unavailable' }) };
    await inst.endSessions('bob');
    assert.match(inst.sessionsMessage, /^✕ Audit logging is unavailable/);
    // GET /api/settings answers what was saved, as the server would.
    answer = { ok: true, status: 200, json: async () => ({ dow_text: 'MY NOTICE', dow_enabled: 'true' }) };
    inst.settingsLoaded = true; inst.savedHostSettings = {}; inst.dowText = 'MY NOTICE';
    calls.length = 0;
    await inst.saveConsentText(false);
    assert.deepEqual(JSON.parse(calls.find(c => c[1] === 'PUT')[2]), { dow_text: 'MY NOTICE' });
    calls.length = 0;
    await inst.saveConsentText(true);
    assert.deepEqual(JSON.parse(calls.find(c => c[1] === 'PUT')[2]), { dow_text: '' }, 'the standard wording is not restored by saving empty text');
    console.log('SETTINGS V130 OK');
})().catch(e => { console.error(e.message); process.exit(1); });
JSEOF
    tm_assert_eq "SETTINGS V130 OK" "$(tr -d '\r' < "${TM_TMP}/out")" "the Settings v1.3.0 controls do not behave"
}
tm_case "settings-builds-the-compliance-csv-and-ends-sessions-as-asked" node a_settings_v130

tm_finish
