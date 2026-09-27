#!/usr/bin/env bash
# =============================================================================
# t34 — THE ROOT APPLY HELPER (install/libexec/tm-apply), run for real as root.
#
# This is the one place in the product where something the service account
# wrote is acted on by root, so it is tested the way an attacker would use it:
#   * values that would be SYNTAX in rsyslog, chrony or nginx (newline,
#     semicolon, brace, quote) and out-of-range numbers, staged DIRECTLY —
#     bypassing every check the application makes — are refused by the
#     helper's own validation, and nothing on the host changes;
#   * a staging file that is a symlink, owned by someone else, readable by
#     others, or hard-linked is refused unread;
#   * the helper never runs code from the service account's tree: a poisoned
#     PYTHONPATH and a poisoned staging directory are ignored;
#   * a change that fails its test AFTER it was installed is rolled back to a
#     BYTE-IDENTICAL host (every managed file, every link, the ufw rule);
#   * the verdict lands in the run directory, never the staging directory, and
#     the staging files are gone afterwards.
# nginx -t and rsyslogd -N1 are the REAL binaries where this host has them
# (see tests/lib/apply_fixture.sh); each case says which ran.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/apply_fixture.sh"

tm_header "root apply helper: re-validates, refuses unsafe staging, rolls back byte-identically"

REQ="linux,chown"
NGX='{"ratelimit_login_per_min":"20","ratelimit_login_burst":"7","ratelimit_api_per_min":"500","ratelimit_api_burst":"50","ratelimit_conn_per_ip":"30","http_redirect_enabled":"true"}'

a_nginx_applies() {
    fx_setup
    local job; job="$(fx_stage nginx "$NGX")"
    fx_helper nginx
    tm_assert_rc 0 "$FX_RC" "the nginx apply failed: $(cat "${TM_TMP}/helper.out")"
    tm_assert_eq "ok" "$(fx_field "d['state']")" "state: $(cat "$FX_RES")"
    tm_assert_eq "$job" "$(fx_field "d['job']")" "the result does not name the job it answers"
    tm_assert_grep "zone=tm_login:10m rate=20r/m;" "$FX/etc/nginx/conf.d/topic-manager-limits.conf"
    tm_assert_grep "zone=tm_api:10m   rate=500r/m;" "$FX/etc/nginx/conf.d/topic-manager-limits.conf"
    tm_assert_grep "limit_req zone=tm_login burst=7 nodelay;" "$FX/etc/nginx/snippets/tm-limits-login.conf"
    tm_assert_grep "limit_req zone=tm_api burst=50 nodelay;" "$FX/etc/nginx/snippets/tm-limits-api.conf"
    tm_assert_grep "limit_conn tm_conn 30;" "$FX/etc/nginx/snippets/tm-limits-server.conf"
    tm_assert_mode 644 "$FX/etc/nginx/snippets/tm-limits-api.conf" "a rendered file is not 0644 (www-data must read it)"
    tm_assert_owner "root:root" "$FX/etc/nginx/snippets/tm-limits-api.conf"
    grep -qx 'ufw allow 80/tcp' "${TM_TMP}/calls" || _tm_afail "redirect ON did not open ufw 80/tcp: $(cat "${TM_TMP}/calls")"
    grep -qx 'nginx -t' "${TM_TMP}/calls" || _tm_afail "nginx -t was not run"
    grep -qx 'systemctl try-reload-or-restart nginx.service' "${TM_TMP}/calls" || _tm_afail "nginx was not reloaded"
    tm_assert_eq "500" "$(fx_field "d['applied']['ratelimit_api_per_min']")" "the result does not carry what was applied (CC-1)"
    tm_assert_nofile "$FX/opt/topic-manager/data/apply/nginx.json" "the staging file was left behind"
    tm_assert_mode 644 "$FX_RES" "the result file is not 0644"
    [ -z "$(fx_staged_left)" ] \
        || _tm_afail "something other than the app's own .last record is in the staging dir: $(ls "$FX/opt/topic-manager/data/apply")"
    tm_note "nginx -t: ${FX_NGINX}"
}
tm_case "nginx-apply-renders-tests-reloads-and-opens-80" "$REQ" a_nginx_applies

a_redirect_off() {
    fx_setup
    echo 80/tcp >> "${TM_TMP}/ufw.state"
    fx_stage nginx "${NGX/\"http_redirect_enabled\":\"true\"/\"http_redirect_enabled\":\"false\"}" >/dev/null
    fx_helper nginx
    tm_assert_eq "ok" "$(fx_field "d['state']")" "state: $(cat "$FX_RES") $(cat "${TM_TMP}/helper.out")"
    [ -L "$FX/etc/nginx/sites-enabled/topic-manager-http" ] && _tm_afail "redirect OFF left the :80 site enabled"
    grep -qx 'ufw delete allow 80/tcp' "${TM_TMP}/calls" || _tm_afail "redirect OFF did not remove ufw 80/tcp: $(cat "${TM_TMP}/calls")"
    grep -q '^80/tcp' "${TM_TMP}/ufw.state" && _tm_afail "ufw still allows 80/tcp"
    # And back on.
    : > "${TM_TMP}/calls"
    fx_stage nginx "$NGX" >/dev/null
    fx_helper nginx
    tm_assert_eq "ok" "$(fx_field "d['state']")" "re-enabling failed: $(cat "$FX_RES")"
    [ "$(readlink "$FX/etc/nginx/sites-enabled/topic-manager-http")" = "$FX/etc/nginx/sites-available/topic-manager-http" ] \
        || _tm_afail "redirect ON did not restore the :80 site link"
    grep -q '^80/tcp' "${TM_TMP}/ufw.state" || _tm_afail "redirect ON did not re-open 80/tcp"
}
tm_case "redirect-off-removes-the-listener-and-ufw-80" "$REQ" a_redirect_off

a_ufw_inactive() {
    fx_setup
    printf 'Status: inactive\n' > "${TM_TMP}/ufw.state"
    fx_stage nginx "${NGX/\"http_redirect_enabled\":\"true\"/\"http_redirect_enabled\":\"false\"}" >/dev/null
    fx_helper nginx
    tm_assert_eq "ok" "$(fx_field "d['state']")" "state: $(cat "$FX_RES")"
    grep -E '^ufw (allow|delete)' "${TM_TMP}/calls" && _tm_afail "rules were changed on an INACTIVE firewall"
    grep -q "ufw is not active" "$FX_RES" || _tm_afail "the result does not say the firewall was left alone"
}
tm_case "an-inactive-ufw-is-never-changed" "$REQ" a_ufw_inactive

a_injection_refused() {
    fx_setup
    local before job payload bad n=0
    before="$(fx_hash_managed)"
    local -a BAD=(
        '"syslog_host":"logs.example.org\nforward.evil.example"'
        '"syslog_host":"a;b"'
        '"syslog_host":"a{b}"'
        '"syslog_host":"a\"b"'
        '"syslog_port":"0"'
        '"syslog_port":"65536"'
        '"syslog_protocol":"sctp"'
        '"syslog_app_id":"a b"'
        '"syslog_app_id":"x\") action(type=\"omprog\" binary=\"/bin/sh"'
        '"extra_key":"1"'
    )
    for bad in "${BAD[@]}"; do
        n=$((n+1))
        job="$(printf '%016x' "$n")"
        payload="{\"domain\":\"syslog\",\"job\":\"${job}\",\"requested_by\":\"t\",\"files\":{},\"settings\":{\"syslog_enabled\":\"true\",\"syslog_host\":\"logs.example.org\",\"syslog_port\":\"514\",\"syslog_protocol\":\"udp\",\"syslog_app_id\":\"tm\",${bad}}}"
        fx_stage_raw syslog "$payload"
        fx_helper syslog
        [ "$FX_RC" -ne 0 ] || _tm_afail "the helper ACCEPTED ${bad}"
        tm_assert_eq "failed validate" "$(fx_field "d['state'] + ' ' + d['step']")" \
            "${bad} was not refused at validation: $(cat "$FX_RES")"
        grep -q "Nothing on the host was changed" "$FX_RES" || _tm_afail "the refusal does not say nothing changed"
    done
    tm_assert_eq "$before" "$(fx_hash_managed)" "a refused request CHANGED the host"
    grep -E '^(systemctl (restart|try-reload)|rsyslogd|nginx|ufw (allow|delete))' "${TM_TMP}/calls" \
        && _tm_afail "a refused request still ran a test, a reload or the firewall"
    true
}
tm_case "hostile-values-staged-directly-are-refused-by-root" "$REQ" a_injection_refused

a_root_renders_the_normalised_value() {
    # Staged directly (no app-side normalising): "UDP" and a padded host are
    # VALID, and root must render what they normalise to — never the raw text
    # ("UDP" is not "udp", and would fall through to TCP).
    fx_setup
    fx_stage_raw syslog '{"domain":"syslog","job":"00000000000000aa","requested_by":"t","files":{},"settings":{"syslog_enabled":"TRUE","syslog_host":" logs.example.org ","syslog_port":"514","syslog_protocol":"UDP","syslog_app_id":"tm"}}'
    fx_helper syslog
    tm_assert_eq "ok" "$(fx_field "d['state']")" "a valid, un-normalised request failed: $(cat "$FX_RES")"
    tm_assert_grep 'target="logs.example.org" port="514" protocol="udp"' "$FX/etc/rsyslog.d/30-topic-manager.conf" \
        "root rendered the RAW staged value instead of the normalised one"
    tm_assert_eq "udp logs.example.org true" "$(fx_field "d['applied']['syslog_protocol'] + ' ' + d['applied']['syslog_host'] + ' ' + d['applied']['syslog_enabled']")" \
        "the applied values reported are not the normalised ones"
}
tm_case "root-renders-the-normalised-value-not-the-staged-text" "$REQ" a_root_renders_the_normalised_value

a_domain_mismatch() {
    fx_setup
    fx_stage_raw nginx '{"domain":"syslog","job":"0000000000000001","settings":{}}'
    fx_helper nginx
    tm_assert_eq "failed validate" "$(fx_field "d['state'] + ' ' + d['step']")" "a request for another domain was acted on"
    fx_stage_raw nginx '{"domain":"nginx","job":"../../x","settings":{}}'
    fx_helper nginx
    tm_assert_eq "failed validate" "$(fx_field "d['state'] + ' ' + d['step']")" "a malformed job id was accepted"
}
tm_case "a-request-for-another-domain-or-a-bad-job-id-is-refused" "$REQ" a_domain_mismatch

a_unsafe_staging_refused() {
    fx_setup
    local st="$FX/opt/topic-manager/data/apply" before
    before="$(fx_hash_managed)"
    printf '{"domain":"nginx","job":"0000000000000001","settings":%s}' "$NGX" > "${TM_TMP}/real.json"
    # 1. a symlink
    ln -s "${TM_TMP}/real.json" "$st/nginx.json"
    fx_helper nginx
    grep -q "symlink; refused" "$FX_RES" || _tm_afail "a SYMLINKED staging file was followed: $(cat "$FX_RES")"
    # 2. owned by root, not the service account
    rm -f "$st/nginx.json"; cp "${TM_TMP}/real.json" "$st/nginx.json"; chmod 600 "$st/nginx.json"
    fx_helper nginx
    grep -q "is not owned by ${FX_SVC_USER}; refused" "$FX_RES" || _tm_afail "a root-owned staging file was read: $(cat "$FX_RES")"
    # 3. readable by others
    rm -f "$st/nginx.json"; cp "${TM_TMP}/real.json" "$st/nginx.json"; chown "$FX_SVC_USER" "$st/nginx.json"; chmod 644 "$st/nginx.json"
    fx_helper nginx
    grep -q "readable or writable by others" "$FX_RES" || _tm_afail "a 0644 staging file was read: $(cat "$FX_RES")"
    # 4. hard-linked (the helper deletes whatever it refused, so re-stage)
    cp "${TM_TMP}/real.json" "$st/nginx.json"; chown "$FX_SVC_USER" "$st/nginx.json"
    chmod 600 "$st/nginx.json"; ln "$st/nginx.json" "$st/other"
    fx_helper nginx
    grep -q "has 2 links; refused" "$FX_RES" || _tm_afail "a hard-linked staging file was read: $(cat "$FX_RES")"
    rm -f "$st/other" "$st/nginx.json"
    # 5. the staging DIRECTORY replaced by a symlink
    mv "$st" "${st}.real"; ln -s "${st}.real" "$st"
    fx_stage_raw nginx "$(cat "${TM_TMP}/real.json")" 2>/dev/null || true
    fx_helper nginx
    grep -q "has a symlink or a non-directory" "$FX_RES" || _tm_afail "a symlinked staging DIRECTORY was followed: $(cat "$FX_RES")"
    tm_assert_eq "$before" "$(fx_hash_managed)" "an unsafe staging file changed the host"
    [ -f "$FX/opt/topic-manager/data/apply/nginx.result" ] && _tm_afail "a result was written into the STAGING directory"
    true
}
tm_case "unsafe-staging-files-are-refused-unread" "$REQ" a_unsafe_staging_refused

a_rollback_byte_identical() {
    fx_setup
    echo 80/tcp >> "${TM_TMP}/ufw.state"
    local before
    before="$(fx_hash_managed)"
    : > "${TM_TMP}/fail.nginx"          # nginx -t fails AFTER the install
    fx_stage nginx "${NGX/\"http_redirect_enabled\":\"true\"/\"http_redirect_enabled\":\"false\"}" >/dev/null
    fx_helper nginx
    [ "$FX_RC" -ne 0 ] || _tm_afail "a failed nginx -t was reported as success"
    tm_assert_eq "rolled_back test" "$(fx_field "d['state'] + ' ' + d['step']")" "state: $(cat "$FX_RES")"
    tm_assert_eq "$before" "$(fx_hash_managed)" \
        "the host is NOT byte-identical after the rollback (files, the :80 link or the ufw rule)"
    grep -q "checked byte for byte" "$FX_RES" || _tm_afail "rolled_back was reported without the restore being checked"
    grep -q '"applied"' "$FX_RES" && _tm_afail "a rolled-back apply claims values were applied"
    [ "$(grep -c 'systemctl try-reload-or-restart nginx.service' "${TM_TMP}/calls")" -ge 1 ] \
        || _tm_afail "nginx was not reloaded onto the restored files"
    ls "$FX"/var/backups/topic-manager/apply/nginx-* >/dev/null 2>&1 || _tm_afail "no backup was kept"
    true
}
tm_case "a-failed-test-rolls-back-to-a-byte-identical-host" "$REQ" a_rollback_byte_identical

a_firewall_restored_on_late_failure() {
    # nginx reloads, ufw 80/tcp is opened, and THEN verification fails (nginx
    # died on the reload). The rollback must close 80/tcp again, not only put
    # the files back.
    fx_setup
    local before; before="$(fx_hash_managed)"
    rm -f "$FX/etc/nginx/sites-enabled/topic-manager-http"; before="$(fx_hash_managed)"
    : > "${TM_TMP}/die.try-reload-or-restart"
    fx_stage nginx "$NGX" >/dev/null
    fx_helper nginx
    tm_assert_eq "rolled_back verify" "$(fx_field "d['state'] + ' ' + d['step']")" "state: $(cat "$FX_RES")"
    grep -qx 'ufw allow 80/tcp' "${TM_TMP}/calls" || _tm_afail "the case never reached the firewall step: $(cat "${TM_TMP}/calls")"
    grep -q '^80/tcp' "${TM_TMP}/ufw.state" && _tm_afail "the rollback left ufw 80/tcp OPEN"
    tm_assert_eq "$before" "$(fx_hash_managed)" "the host is not byte-identical after a failure past the firewall step"
}
tm_case "a-failure-after-the-firewall-step-closes-80-again" "$REQ" a_firewall_restored_on_late_failure

a_reload_failure_rolls_back() {
    fx_setup
    local before; before="$(fx_hash_managed)"
    : > "${TM_TMP}/fail.restart"         # rsyslog will not restart
    fx_stage syslog '{"syslog_enabled":"true","syslog_host":"logs.example.org","syslog_port":"514","syslog_protocol":"tcp","syslog_app_id":"tm"}' >/dev/null
    fx_helper syslog
    tm_assert_eq "failed" "$(fx_field "d['state']")" "state: $(cat "$FX_RES")"
    grep -q "may be in a mixed state" "$FX_RES" || _tm_afail "a restore whose reload failed was not reported as a possible mixed state"
    rm -f "${TM_TMP}/fail.restart"
    tm_assert_eq "$before" "$(fx_hash_managed)" "the files were not put back"
}
tm_case "a-failed-reload-is-rolled-back-and-reported-honestly" "$REQ" a_reload_failure_rolls_back

a_syslog_renders_and_tests() {
    fx_setup
    fx_stage syslog '{"syslog_enabled":"true","syslog_host":"logs.example.org","syslog_port":"10514","syslog_protocol":"tcp","syslog_app_id":"tm-prod"}' >/dev/null
    fx_helper syslog
    tm_assert_eq "ok" "$(fx_field "d['state']")" "state: $(cat "$FX_RES") $(cat "${TM_TMP}/helper.out")"
    local c="$FX/etc/rsyslog.d/30-topic-manager.conf"
    tm_assert_grep 'target="logs.example.org" port="10514" protocol="tcp"' "$c"
    tm_assert_grep '%HOSTNAME% tm-prod %PROCID%' "$c" "the app id is not the forwarded APP-NAME"
    tm_assert_grep 'if ($programname == "topic-manager-audit"' "$c" "the audit trail is not forwarded"
    tm_assert_grep 'tag=tm_nginx_access' "$FX/etc/nginx/snippets/tm-syslog.conf" "nginx access log is not sent to syslog"
    tm_assert_file "${TM_TMP}/rsyslog.pretest" "rsyslogd -N1 was never run on the rendered file"
    grep -q "workDirectory=\"/var/spool/rsyslog\"" "${TM_TMP}/rsyslog.pretest" || _tm_afail "the pre-test lacks the work directory"
    ls "$FX"/etc/rsyslog.d/.tm-pretest-* >/dev/null 2>&1 && _tm_afail "the pre-test file was left in /etc/rsyslog.d"
    grep -qx 'systemctl restart rsyslog.service' "${TM_TMP}/calls" || _tm_afail "rsyslog was not restarted"
    tm_note "rsyslogd -N1: ${FX_RSYSLOG}; nginx -t: ${FX_NGINX}"
    # Off again: the forwarding rule and the nginx syslog lines go.
    fx_stage syslog '{"syslog_enabled":"false","syslog_host":"","syslog_port":"6514","syslog_protocol":"tls","syslog_app_id":"topic-manager"}' >/dev/null
    fx_helper syslog
    tm_assert_eq "ok" "$(fx_field "d['state']")" "turning syslog off failed: $(cat "$FX_RES")"
    tm_assert_nogrep "omfwd" "$c" "forwarding is still configured after turning it off"
    tm_assert_nogrep "access_log" "$FX/etc/nginx/snippets/tm-syslog.conf" "nginx still logs to syslog after turning it off"
    cmp -s "$c" "${TM_REPO_ROOT}/install/rsyslog/30-topic-manager.conf" \
        || _tm_afail "the OFF rendering differs from the shipped default (install/rsyslog/30-topic-manager.conf)"
}
tm_case "syslog-renders-pretests-with-rsyslogd-and-turns-off-cleanly" "$REQ" a_syslog_renders_and_tests

a_syslog_tls_needs_module_and_ca() {
    fx_setup
    local before; before="$(fx_hash_managed)"
    fx_stage syslog '{"syslog_enabled":"true","syslog_host":"logs.example.org","syslog_port":"6514","syslog_protocol":"tls","syslog_app_id":"tm"}' >/dev/null
    fx_helper syslog
    tm_assert_eq "failed validate" "$(fx_field "d['state'] + ' ' + d['step']")" "TLS without rsyslog-openssl was not refused"
    grep -q "rsyslog-openssl" "$FX_RES" || _tm_afail "the refusal does not name rsyslog-openssl"
    tm_assert_eq "$before" "$(fx_hash_managed)" "the refused TLS request changed the host"
    mkdir -p "$FX/usr/lib/x86_64-linux-gnu/rsyslog"; : > "$FX/usr/lib/x86_64-linux-gnu/rsyslog/lmnsd_ossl.so"
    fx_stage syslog '{"syslog_enabled":"true","syslog_host":"logs.example.org","syslog_port":"6514","syslog_protocol":"tls","syslog_app_id":"tm"}' >/dev/null
    fx_helper syslog
    tm_assert_eq "ok" "$(fx_field "d['state']")" "TLS with the module present failed: $(cat "$FX_RES")"
    cmp -s "$FX/etc/ssl/certs/ca-certificates.crt" "$FX/etc/rsyslog.d/topic-manager/system-ca.pem" \
        || _tm_afail "the system trust store was not copied where the CONFINED rsyslogd can read it"
    tm_assert_grep 'StreamDriver.CAFile="/etc/rsyslog.d/topic-manager/system-ca.pem"' "$FX/etc/rsyslog.d/30-topic-manager.conf"
    tm_assert_grep 'StreamDriverPermittedPeers="logs.example.org"' "$FX/etc/rsyslog.d/30-topic-manager.conf" \
        "the collector's certificate name is not checked"
    tm_assert_mode 644 "$FX/etc/rsyslog.d/topic-manager/system-ca.pem" "the CA copy is not readable by the syslog user"
    # An operator CA wins over the trust store.
    printf -- '-----BEGIN CERTIFICATE-----\nb3A=\n-----END CERTIFICATE-----\n' > "$FX/etc/rsyslog.d/topic-manager/syslog-ca.pem"
    fx_stage syslog '{"syslog_enabled":"true","syslog_host":"logs.example.org","syslog_port":"6514","syslog_protocol":"tls","syslog_app_id":"tm"}' >/dev/null
    fx_helper syslog
    tm_assert_grep 'StreamDriver.CAFile="/etc/rsyslog.d/topic-manager/syslog-ca.pem"' "$FX/etc/rsyslog.d/30-topic-manager.conf" \
        "a dedicated syslog CA was ignored"
}
tm_case "syslog-tls-needs-rsyslog-openssl-and-a-readable-ca" "$REQ" a_syslog_tls_needs_module_and_ca

a_time_chrony() {
    fx_setup
    printf 'chrony.service\n' >> "${TM_TMP}/active"
    fx_stage time '{"ntp_servers":"ntp1.example.org,192.0.2.10"}' >/dev/null
    fx_helper time
    tm_assert_eq "ok" "$(fx_field "d['state']")" "state: $(cat "$FX_RES") $(cat "${TM_TMP}/helper.out")"
    local f="$FX/etc/chrony/sources.d/topic-manager.sources"
    tm_assert_grep "server ntp1.example.org iburst maxpoll 16" "$f"
    tm_assert_grep "server 192.0.2.10 iburst maxpoll 16" "$f"
    grep -q '^chronyd -p -f ' "${TM_TMP}/calls" || _tm_afail "chronyd -p was not run on the rendered sources"
    cmp -s "${TM_TMP}/chronyd.saw" "$f" || _tm_afail "chronyd -p tested something other than what was installed"
    grep -qx 'chronyc reload sources' "${TM_TMP}/calls" || _tm_afail "chrony was not told to reload its sources"
    ls "$FX"/etc/chrony/sources.d/.tm-pretest-* >/dev/null 2>&1 && _tm_afail "the chrony pre-test file was left behind"
    fx_stage time '{"ntp_servers":""}' >/dev/null
    fx_helper time
    tm_assert_eq "ok" "$(fx_field "d['state']")" "clearing the servers failed"
    tm_assert_nofile "$f" "empty ntp_servers did not remove the Topic Manager source file"
    tm_assert_grep "pool ntp.ubuntu.com" "$FX/etc/chrony/chrony.conf" "the host's own chrony.conf was touched"
}
tm_case "time-chrony-sources-tested-reloaded-and-removable" "$REQ" a_time_chrony

a_time_chrony_without_sourcedir() {
    fx_setup
    printf 'chrony.service\n' >> "${TM_TMP}/active"
    printf 'pool ntp.ubuntu.com iburst\n' > "$FX/etc/chrony/chrony.conf"
    fx_stage time '{"ntp_servers":"ntp1.example.org"}' >/dev/null
    fx_helper time
    tm_assert_eq "failed validate" "$(fx_field "d['state'] + ' ' + d['step']")" \
        "servers were written where chrony would never read them: $(cat "$FX_RES")"
}
tm_case "time-chrony-refuses-when-sources-d-is-not-read" "$REQ" a_time_chrony_without_sourcedir

a_time_timesyncd() {
    fx_setup
    printf 'systemd-timesyncd.service\n' >> "${TM_TMP}/active"
    printf 'ntp1.example.org ntp2.example.org\n' > "${TM_TMP}/timesync.servers"
    fx_stage time '{"ntp_servers":"ntp1.example.org,ntp2.example.org"}' >/dev/null
    fx_helper time
    tm_assert_eq "ok" "$(fx_field "d['state']")" "state: $(cat "$FX_RES")"
    tm_assert_grep "NTP=ntp1.example.org ntp2.example.org" "$FX/etc/systemd/timesyncd.conf.d/topic-manager.conf"
    grep -qx 'systemctl restart systemd-timesyncd.service' "${TM_TMP}/calls" || _tm_afail "timesyncd was not restarted"
    # timesyncd reports different servers: verification must fail and roll back.
    printf 'pool.example.org\n' > "${TM_TMP}/timesync.servers"
    fx_stage time '{"ntp_servers":"ntp3.example.org"}' >/dev/null
    fx_helper time
    tm_assert_eq "rolled_back verify" "$(fx_field "d['state'] + ' ' + d['step']")" \
        "a timesyncd that did not take the servers was reported as applied: $(cat "$FX_RES")"
    tm_assert_grep "NTP=ntp1.example.org ntp2.example.org" "$FX/etc/systemd/timesyncd.conf.d/topic-manager.conf" \
        "the previous drop-in was not restored"
}
tm_case "time-timesyncd-drop-in-verified-or-rolled-back" "$REQ" a_time_timesyncd

a_never_runs_service_code() {
    fx_setup
    local evil="${TM_TMP}/evil"
    mkdir -p "$evil"
    printf 'import os\nopen(%r, "w").write("PWNED")\n' "${TM_TMP}/pwned" > "$evil/sitecustomize.py"
    cp "$evil/sitecustomize.py" "$evil/json.py"
    cp "$evil/sitecustomize.py" "$FX/opt/topic-manager/data/apply/settings_schema.py"
    chown "$FX_SVC_USER" "$FX/opt/topic-manager/data/apply/settings_schema.py"
    fx_stage nginx "$NGX" >/dev/null
    PYTHONPATH="$evil" PYTHONSTARTUP="$evil/json.py" PYTHONHOME="" fx_helper nginx
    tm_assert_eq "ok" "$(fx_field "d['state']")" "the apply failed: $(cat "$FX_RES") $(cat "${TM_TMP}/helper.out")"
    tm_assert_nofile "${TM_TMP}/pwned" "the ROOT helper executed code from PYTHONPATH or the staging directory"
    local h; h="$(tm_apply_helper)"
    [ "$(sed -n 1p "$h")" = '#!/usr/bin/python3 -I' ] || _tm_afail "the helper is not /usr/bin/python3 -I"
    # By the AST, not by grep: the docstring EXPLAINS the rule and must not
    # trip it. No import of the tm package, and no string that names the venv
    # or the tm/ tree (the staging data directory is the only path it reads).
    python3 - "$h" <<'PYEOF' || _tm_afail "the helper references the service account's code tree"
import ast, sys
t = ast.parse(open(sys.argv[1], encoding='utf-8').read())
bad = []
for n in ast.walk(t):
    if isinstance(n, ast.Import):
        bad += [a.name for a in n.names if a.name == 'tm' or a.name.startswith('tm.')]
    if isinstance(n, ast.ImportFrom) and (n.module or '').split('.')[0] == 'tm':
        bad.append(n.module)
    if isinstance(n, ast.Constant) and isinstance(n.value, str) and not n.value.startswith('\ntm-apply'):
        if 'venv' in n.value or '/opt/topic-manager/tm' in n.value:
            bad.append(n.value[:60])
print(bad)
sys.exit(1 if bad else 0)
PYEOF
    local u
    for u in syslog time nginx tls; do
        grep -qx "ExecStart=/usr/bin/python3 -I /usr/libexec/topic-manager/tm-apply ${u}" \
            "${TM_REPO_ROOT}/systemd/topic-manager-apply-${u}.service" \
            || _tm_afail "topic-manager-apply-${u}.service does not run the root-owned helper with -I and a fixed argument"
    done
    true
}
tm_case "the-helper-never-runs-code-the-service-account-owns" "$REQ" a_never_runs_service_code

a_shipped_defaults_are_the_render() {
    fx_setup
    echo 80/tcp >> "${TM_TMP}/ufw.state"     # as install.sh leaves it with the redirect on
    fx_stage nginx '{"ratelimit_login_per_min":"10","ratelimit_login_burst":"5","ratelimit_api_per_min":"300","ratelimit_api_burst":"100","ratelimit_conn_per_ip":"20","http_redirect_enabled":"true"}' >/dev/null
    local before; before="$(fx_hash_managed)"
    fx_helper nginx
    tm_assert_eq "ok" "$(fx_field "d['state']")" "state: $(cat "$FX_RES")"
    tm_assert_eq "$before" "$(fx_hash_managed)" \
        "the files the release ships (nginx/tm-limits*.conf) are not what the helper renders for the default settings"
}
tm_case "shipped-nginx-defaults-equal-the-helpers-render" "$REQ" a_shipped_defaults_are_the_render

tm_finish
