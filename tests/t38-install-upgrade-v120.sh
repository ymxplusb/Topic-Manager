#!/usr/bin/env bash
# =============================================================================
# t38 — THE INSTALLER, THE UPGRADE AND THE BUNDLE CARRY v1.2.0 WITHOUT EVER
# REVERTING AN OPERATOR'S CHOICE.
#
#   * the bundle and the installer list rsyslog, rsyslog-openssl (and the
#     bundle chrony);
#   * chrony is installed only where no time daemon runs or --install-chrony
#     asks, and the ONLY removal ever allowed is systemd-timesyncd — in the
#     simulated plan online, and in apt_install_from_bundle offline;
#   * a managed file (rate limits, syslog, the :80 link) is laid down only
#     where ABSENT, and the upgrade backs every one up and puts it back
#     byte-for-byte on a rollback — or removes it for a pre-v1.2.0 restore
#     point, whose own site file carries the :80 block;
#   * the upgrade re-applies what tm.db holds AFTER the service is verified;
#   * a bad host-setting flag stops install.sh before anything is changed.
# Every function is EXTRACTED from the real scripts (tests/lib/harness.sh).
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "install/upgrade/bundle: packages, chrony vs timesyncd, managed files kept and restored"

INSTALL_SH="$(tm_install_sh)"
UP="$(tm_upgrade_sh)"
PREP="$(tm_prepare_sh)"

a_packages() {
    local req pk
    req="$(tm_extract_between "$INSTALL_SH" '^REQUIRED_PKGS=\(' '^[[:space:]]+rsyslog rsyslog-openssl\)$' | tr '\n' ' ')"
    case "$req" in *" rsyslog "*"rsyslog-openssl"*) ;; *) _tm_afail "install.sh does not require rsyslog and rsyslog-openssl: ${req}" ;; esac
    pk="$(grep -E '^PKGS="' "$PREP")"
    for p in rsyslog rsyslog-openssl chrony; do
        case " ${pk#PKGS=\"} " in *" ${p} "*|*" ${p}\" "*) ;; *) _tm_afail "the offline bundle does not carry ${p}: ${pk}" ;; esac
    done
}
tm_case "installer-and-bundle-carry-rsyslog-openssl-and-chrony" none a_packages

a_shared_helpers_identical() {
    local f
    for f in install_apply_helper install_if_absent; do
        tm_extract_func "$INSTALL_SH" "$f" > "${TM_TMP}/a"
        tm_extract_func "$UP" "$f" > "${TM_TMP}/b"
        cmp -s "${TM_TMP}/a" "${TM_TMP}/b" || _tm_afail "${f} differs between install.sh and the upgrade"
    done
    tm_extract_func "$INSTALL_SH" run_as_app | sed 's/--by installer/--by X/' > "${TM_TMP}/a"
    tm_extract_func "$UP" run_as_app | sed 's/--by upgrade/--by X/' > "${TM_TMP}/b"
    cmp -s "${TM_TMP}/a" "${TM_TMP}/b" || _tm_afail "run_as_app differs between install.sh and the upgrade"
    local u
    for u in topic-manager-apply-syslog.service topic-manager-apply-time.service topic-manager-apply-nginx.service \
             topic-manager-apply-tls.service topic-manager-audit-prune.service topic-manager-audit-prune.timer; do
        grep -q "$u" "$INSTALL_SH" || _tm_afail "install.sh does not install ${u}"
        grep -q "$u" "$UP" || _tm_afail "the upgrade does not install ${u}"
    done
    grep -q 'systemctl enable --now topic-manager-audit-prune.timer' "$INSTALL_SH" || _tm_afail "install.sh never enables the prune timer"
    grep -q 'systemctl enable --now topic-manager-audit-prune.timer' "$UP" || _tm_afail "the upgrade never enables the prune timer"
}
tm_case "install-and-upgrade-share-the-helper-installers-and-units" none a_shared_helpers_identical

a_install_if_absent() {
    {
        echo 'set -uo pipefail'
        echo 'fail() { echo "FAIL: $*"; exit 1; }'
        tm_extract_func "$INSTALL_SH" install_if_absent | sed 's/-o root -g root //'
        echo 'install_if_absent "$@"'
    } > "${TM_TMP}/iia.sh"
    printf 'release\n' > "${TM_TMP}/src"
    printf 'operator\n' > "${TM_TMP}/kept"
    bash "${TM_TMP}/iia.sh" 644 "${TM_TMP}/src" "${TM_TMP}/kept" || _tm_afail "install_if_absent failed on an existing file"
    tm_assert_eq "operator" "$(cat "${TM_TMP}/kept")" "an existing managed file was REPLACED by the release default"
    bash "${TM_TMP}/iia.sh" 644 "${TM_TMP}/src" "${TM_TMP}/sub/new" || _tm_afail "install_if_absent failed on an absent file"
    tm_assert_eq "release" "$(cat "${TM_TMP}/sub/new")" "an absent managed file was not laid down"
}
tm_case "a-managed-file-is-installed-only-where-absent" none a_install_if_absent

a_install_if_absent_symlink() {
    {
        echo 'set -uo pipefail'
        echo 'fail() { echo "FAIL: $*"; exit 1; }'
        tm_extract_func "$INSTALL_SH" install_if_absent | sed 's/-o root -g root //'
        echo 'install_if_absent "$@"'
    } > "${TM_TMP}/iia.sh"
    printf 'release\n' > "${TM_TMP}/src"
    ln -s /nonexistent/target "${TM_TMP}/dangling"
    local rc=0 out
    out="$(bash "${TM_TMP}/iia.sh" 644 "${TM_TMP}/src" "${TM_TMP}/dangling" 2>&1)" || rc=$?
    tm_assert_rc 1 "$rc" "install_if_absent wrote THROUGH a dangling symlink: ${out}"
    [ -e /nonexistent/target ] && _tm_afail "a file was created at the symlink's target"
    true
}
tm_case "install-if-absent-refuses-a-symlink" symlinks a_install_if_absent_symlink

_time_daemon_harness() {   # <installed pkgs> <install-chrony> <online> <sim plan>
    mkdir -p "${TM_TMP}/bin"
    cat > "${TM_TMP}/bin/apt-get" <<STUB
#!/usr/bin/env bash
echo "apt-get \$*" >> "${TM_TMP}/calls"
case " \$* " in *" -s "*) printf '%b' "$4"; exit 0 ;; esac
exit 0
STUB
    chmod 755 "${TM_TMP}/bin/apt-get"
    {
        echo 'set -uo pipefail'
        echo 'info() { :; }; success() { echo "OK $*"; }; warn() { echo "WARN $*"; }; die() { echo "DIE $*"; exit 1; }'
        printf 'INSTALLED="%s"\n' "$1"
        echo 'pkg_installed() { [[ " $INSTALLED " == *" $1 "* ]] || [[ -f "'"${TM_TMP}"'/now.$1" ]]; }'
        echo 'apt_install_from_bundle() { echo "BUNDLE allow=[${APT_ALLOW_REMOVE:-}] $*" >> "'"${TM_TMP}"'/calls"; : > "'"${TM_TMP}"'/now.chrony"; }'
        echo 'mkdir() { echo "mkdir $*" >> "'"${TM_TMP}"'/calls"; }'
        printf 'OPT_INSTALL_CHRONY=%s ONLINE=%s SCRIPT_DIR=/src\n' "$2" "$3"
        tm_extract_func "$INSTALL_SH" install_time_daemon
        echo 'install_time_daemon'
    } > "${TM_TMP}/td.sh"
    : > "${TM_TMP}/calls"; rm -f "${TM_TMP}"/now.*
    TD_RC=0
    PATH="${TM_TMP}/bin:${PATH}" bash "${TM_TMP}/td.sh" > "${TM_TMP}/td.out" 2>&1 || TD_RC=$?
}

a_timesyncd_kept() {
    _time_daemon_harness "systemd-timesyncd" false true ""
    tm_assert_rc 0 "$TD_RC" "$(cat "${TM_TMP}/td.out")"
    grep -q '^apt-get' "${TM_TMP}/calls" && _tm_afail "chrony was installed over systemd-timesyncd WITHOUT --install-chrony"
    grep -q 'mkdir -p /etc/systemd/timesyncd.conf.d' "${TM_TMP}/calls" || _tm_afail "the timesyncd drop-in directory is not prepared"
    tm_assert_grep "systemd-timesyncd (kept" "${TM_TMP}/td.out"
}
tm_case "timesyncd-is-kept-unless-install-chrony" none a_timesyncd_kept

a_install_chrony_online() {
    _time_daemon_harness "systemd-timesyncd" true true 'Remv systemd-timesyncd [255.4]\nInst chrony (4.5-1 Ubuntu:24.04)\n'
    grep -q '^apt-get install -y --no-install-recommends chrony' "${TM_TMP}/calls" \
        || _tm_afail "--install-chrony did not install chrony: $(cat "${TM_TMP}/calls") $(cat "${TM_TMP}/td.out")"
    tm_assert_grep "REMOVES systemd-timesyncd" "${TM_TMP}/td.out" "the removal was not announced"
    _time_daemon_harness "systemd-timesyncd" true true 'Remv systemd-timesyncd [255.4]\nRemv ntpsec [1.2]\nInst chrony (4.5-1 Ubuntu:24.04)\n'
    tm_assert_rc 1 "$TD_RC" "a plan that also removes ANOTHER package was carried out"
    grep -q '^apt-get install -y' "${TM_TMP}/calls" && _tm_afail "chrony was installed although the plan removed ntpsec"
    tm_assert_grep "would also remove: ntpsec" "${TM_TMP}/td.out"
}
tm_case "install-chrony-online-removes-only-systemd-timesyncd" none a_install_chrony_online

a_install_chrony_offline() {
    _time_daemon_harness "systemd-timesyncd" true false ""
    grep -qx 'BUNDLE allow=\[systemd-timesyncd\] /src/install/packages/apt chrony' "${TM_TMP}/calls" \
        || _tm_afail "offline, chrony did not come from the bundle with ONLY systemd-timesyncd allowed out: $(cat "${TM_TMP}/calls")"
    _time_daemon_harness "" false false ""
    grep -qx 'BUNDLE allow=\[systemd-timesyncd\] /src/install/packages/apt chrony' "${TM_TMP}/calls" \
        || _tm_afail "a host with NO time daemon did not get chrony"
    _time_daemon_harness "chrony" true true ""
    grep -q 'apt-get\|BUNDLE' "${TM_TMP}/calls" && _tm_afail "chrony was reinstalled where it already runs"
    true
}
tm_case "install-chrony-offline-and-no-daemon-and-already-chrony" none a_install_chrony_offline

_bundle_plan() {   # <plan text> <allow-remove> — the REAL apt_install_from_bundle, stub apt
    mkdir -p "${TM_TMP}/bin" "${TM_TMP}/apt"
    : > "${TM_TMP}/apt/Packages"; : > "${TM_TMP}/apt/chrony.deb"
    cat > "${TM_TMP}/bin/apt-get" <<STUB
#!/usr/bin/env bash
echo "apt-get \$*" >> "${TM_TMP}/calls"
case " \$* " in *" -s "*) printf '%b' "$1"; exit 0 ;; esac
exit 0
STUB
    chmod 755 "${TM_TMP}/bin/apt-get"
    {
        echo 'set -uo pipefail'
        echo 'info() { echo "INFO $*"; }; die() { echo "DIE $*"; exit 1; }'
        echo 'apt_fips_packages() { :; }'
        echo 'apt_removal_reason() { :; }'
        tm_extract_func "$INSTALL_SH" apt_install_from_bundle
        printf 'NON_INTERACTIVE=true APT_ALLOW_REMOVE="%s" apt_install_from_bundle "%s" chrony\n' "$2" "${TM_TMP}/apt"
        echo 'echo RETURNED'
    } > "${TM_TMP}/bp.sh"
    : > "${TM_TMP}/calls"
    BP_RC=0
    PATH="${TM_TMP}/bin:${PATH}" bash "${TM_TMP}/bp.sh" > "${TM_TMP}/bp.out" 2>&1 || BP_RC=$?
}

a_bundle_allow_remove() {
    _bundle_plan 'Remv systemd-timesyncd [255.4]\nInst chrony (4.5-1 bundle [amd64])\n' "systemd-timesyncd"
    tm_assert_rc 0 "$BP_RC" "the ALLOWED removal was refused: $(cat "${TM_TMP}/bp.out")"
    grep -E '^apt-get .* install -y ' "${TM_TMP}/calls" | grep -q -- '--no-remove' \
        && _tm_afail "the real install still passed --no-remove, so apt would abort the allowed removal"
    grep -qE '^apt-get .* install -y ' "${TM_TMP}/calls" || _tm_afail "the plan was never carried out"
    _bundle_plan 'Remv systemd-timesyncd [255.4]\nRemv vim [9]\nInst chrony (4.5-1 bundle [amd64])\n' "systemd-timesyncd"
    tm_assert_rc 1 "$BP_RC" "a plan removing a package that was NOT allowed was carried out"
    tm_assert_grep "vim [9]: would be REMOVED" "${TM_TMP}/bp.out" "the unallowed removal is not named"
    _bundle_plan 'Remv systemd-timesyncd [255.4]\nInst chrony (4.5-1 bundle [amd64])\n' ""
    tm_assert_rc 1 "$BP_RC" "with nothing allowed, a removal was carried out (the round-3 policy is never remove)"
    grep -E '^apt-get .* -s install ' "${TM_TMP}/calls" | grep -q -- '--no-remove' \
        || _tm_afail "without an allowance the plan is no longer simulated with --no-remove"
}
tm_case "bundle-install-allows-exactly-the-named-removal" none a_bundle_allow_remove

_v120_relocated() {   # the upgrade's V120_MANAGED + backup/restore, relocated under $FR
    FR="${TM_TMP}/fr"
    mkdir -p "$FR"
    {
        echo 'set -uo pipefail'
        echo 'fail() { echo "FAIL: $*"; exit 1; }'
        echo "FAKEROOT='${FR}'"
        tm_extract_between "$UP" '^V120_MANAGED=\(' '^  /etc/systemd/timesyncd\.conf\.d/topic-manager\.conf\)$'             | sed 's# /# ${FAKEROOT}/#g; s#^  /#  ${FAKEROOT}/#'
        tm_extract_func "$UP" backup_v120_managed
        tm_extract_func "$UP" restore_v120_managed
        echo 'systemctl() { echo "systemctl $*" >> "'"${TM_TMP}"'/calls"; }'
        echo '"$@"'
    } > "${TM_TMP}/v120.sh"
    : > "${TM_TMP}/calls"
    grep -qF '${FAKEROOT}/etc/nginx/conf.d/topic-manager-limits.conf' "${TM_TMP}/v120.sh" \
        || tm_die "could not relocate V120_MANAGED into the fake root"
    grep -Eq '"/etc|[[:space:]]/etc' <(tm_extract_between "${TM_TMP}/v120.sh" '^V120_MANAGED=\(' 'topic-manager\.conf\)$') \
        && tm_die "a V120_MANAGED entry escaped the fake root"
}

_digest() { ( cd "$FR" && find . \( -type f -o -type l \) | sort | while read -r f; do
    if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; else sha256sum "$f"; fi; done ) | sha256sum | cut -d' ' -f1; }

a_upgrade_backup_restore_roundtrip() {
    _v120_relocated
    mkdir -p "$FR"/etc/nginx/{conf.d,snippets,sites-available,sites-enabled} "$FR"/etc/rsyslog.d/topic-manager "$FR"/etc/chrony/sources.d
    printf 'rate=17\n' > "$FR/etc/nginx/conf.d/topic-manager-limits.conf"
    printf 'burst 9\n' > "$FR/etc/nginx/snippets/tm-limits-login.conf"
    printf 'syslog on\n' > "$FR/etc/nginx/snippets/tm-syslog.conf"
    printf 'fwd\n' > "$FR/etc/rsyslog.d/30-topic-manager.conf"
    printf 'CA\n' > "$FR/etc/rsyslog.d/topic-manager/syslog-ca.pem"
    printf 'server ntp1\n' > "$FR/etc/chrony/sources.d/topic-manager.sources"
    printf 'server {}\n' > "$FR/etc/nginx/sites-available/topic-manager-http"
    # The operator turned the redirect OFF: no link.
    local before; before="$(_digest)"
    mkdir -p "${TM_TMP}/bd"
    bash "${TM_TMP}/v120.sh" backup_v120_managed "${TM_TMP}/bd" || _tm_afail "backup failed: $(cat "${TM_TMP}/calls")"
    tm_assert_file "${TM_TMP}/bd/system/v120/.present" "the backup carries no v1.2.0 marker"
    # The upgrade then changes all of it...
    printf 'DEFAULT\n' > "$FR/etc/nginx/conf.d/topic-manager-limits.conf"
    ln -s "$FR/etc/nginx/sites-available/topic-manager-http" "$FR/etc/nginx/sites-enabled/topic-manager-http"
    rm -f "$FR/etc/chrony/sources.d/topic-manager.sources"
    printf 'extra\n' > "$FR/etc/systemd-timesyncd-should-not-matter" 2>/dev/null || true
    rm -f "$FR/etc/systemd-timesyncd-should-not-matter"
    # ...and rolls back.
    bash "${TM_TMP}/v120.sh" restore_v120_managed "${TM_TMP}/bd" || _tm_afail "restore failed"
    tm_assert_eq "$before" "$(_digest)" \
        "the rollback did not put the managed files (and the absent :80 link) back byte-for-byte"
}
tm_case "upgrade-backs-up-and-restores-managed-files-byte-for-byte" symlinks a_upgrade_backup_restore_roundtrip

a_restore_pre_v120_removes_them() {
    _v120_relocated
    mkdir -p "$FR"/etc/nginx/{conf.d,sites-available,sites-enabled} "${TM_TMP}/old/system"
    printf 'x\n' > "$FR/etc/nginx/conf.d/topic-manager-limits.conf"
    printf 'x\n' > "$FR/etc/nginx/sites-available/topic-manager-http"
    ln -s "$FR/etc/nginx/sites-available/topic-manager-http" "$FR/etc/nginx/sites-enabled/topic-manager-http"
    bash "${TM_TMP}/v120.sh" restore_v120_managed "${TM_TMP}/old" || _tm_afail "restore from a pre-v1.2.0 point failed"
    [ -e "$FR/etc/nginx/sites-enabled/topic-manager-http" ] || [ -L "$FR/etc/nginx/sites-enabled/topic-manager-http" ] \
        && _tm_afail "a pre-v1.2.0 rollback left the :80 site enabled beside the old site's own :80 block"
    tm_assert_nofile "$FR/etc/nginx/conf.d/topic-manager-limits.conf" "a v1.2.0-only file survived a rollback to before v1.2.0"
    grep -q 'systemctl disable --now topic-manager-audit-prune.timer' "${TM_TMP}/calls" \
        || _tm_afail "the prune timer stays enabled for a release that has no tm.audit_retention"
}
tm_case "restore-to-pre-v120-removes-the-v120-files" symlinks a_restore_pre_v120_removes_them

a_upgrade_order() {
    local up="$UP" n_health n_reapply n_phase9_keep n_restore
    n_health="$(grep -n 'success "Version verified: ' "$up" | head -1 | cut -d: -f1)"
    n_reapply="$(grep -n 'run_as_app stage all' "$up" | head -1 | cut -d: -f1)"
    [ -n "$n_health" ] && [ -n "$n_reapply" ] || _tm_afail "cannot find the version check or the re-apply"
    [ "$n_reapply" -gt "$n_health" ] || _tm_afail "the upgrade re-applies host settings BEFORE the new service is verified"
    grep -q '^install_if_absent 644 "${WORK_DIR}/nginx/tm-limits.conf" /etc/nginx/conf.d/topic-manager-limits.conf$' "$up" \
        || _tm_afail "Phase 9 does not keep an existing rate-limit file"
    grep -Eq '^(cp|install)[[:space:]][^#]*nginx/(tm-limits|tm-syslog)[^#]*(conf.d|snippets)' "$up" \
        && _tm_afail "the upgrade OVERWRITES a managed file (reverting an operator's choice)"
    n_restore="$(grep -n '^    restore_v120_managed "\$BD"$' <<<"$(tm_extract_func "$up" restore_from_backup)" | cut -d: -f1)"
    [ -n "$n_restore" ] || _tm_afail "restore_from_backup does not put the managed files back"
    grep -q '^backup_v120_managed "\$BACKUP_DIR"$' "$up" || _tm_afail "Phase 4 does not back up the managed files"
    grep -q '"${CONFIG_DIR}/tls/chain.pem"' <<<"$(tm_extract_between "$up" '^BASELINE_PATHS=\(' '^\)$')" \
        || _tm_afail "the uploaded CA chain is not in BASELINE_PATHS (its mode would not be replayed)"
}
tm_case "upgrade-re-applies-after-verification-and-never-overwrites" none a_upgrade_order

a_bad_flag_changes_nothing() {
    local rc=0 out
    out="$(bash "$INSTALL_SH" --server-name tm.example.org --non-interactive --syslog-host 'logs.example.org;x' 2>&1)" || rc=$?
    tm_assert_rc 1 "$rc" "a hostile --syslog-host was accepted: ${out}"
    case "$out" in *"Invalid host setting: --syslog-host:"*"Nothing has been changed."*) ;; *)
        _tm_afail "the refusal does not name the flag or say nothing changed: ${out}" ;; esac
    out="$(bash "$INSTALL_SH" --server-name tm.example.org --non-interactive --syslog-port 70000 --syslog-host logs.example.org 2>&1)" || rc=$?
    case "$out" in *"--syslog-port: must be from 1 to 65535"*) ;; *) _tm_afail "port 70000: ${out}" ;; esac
    out="$(bash "$INSTALL_SH" --server-name tm.example.org --non-interactive --ntp-server 'a,b,c,d,e,f' 2>&1)" || rc=$?
    case "$out" in *"--ntp-server: at most 5 servers"*) ;; *) _tm_afail "six NTP servers: ${out}" ;; esac
    out="$(bash "$INSTALL_SH" --server-name tm.example.org --non-interactive --syslog-ca /nonexistent/ca.pem 2>&1)" || rc=$?
    case "$out" in *"--syslog-ca /nonexistent/ca.pem: no such file"*) ;; *) _tm_afail "missing CA: ${out}" ;; esac
    case "$out" in *"Install mode:"*) _tm_afail "install.sh probed the network before refusing a bad flag" ;; esac
    true
}
tm_case "a-bad-host-setting-flag-stops-install-before-any-change" none a_bad_flag_changes_nothing

tm_finish
