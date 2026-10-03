#!/usr/bin/env bash
# =============================================================================
# t39 — THE v1.2.0 DOCUMENTS SAY WHAT THE CODE DOES.
#
#   * README's audit-action list names every action log_action writes, from
#     EVERY module (the AST over tm/*.py — a prune job in its own module was
#     exactly the kind of action a routes.py-only recipe would miss), plus the
#     syslog-only AUDIT_WRITE_FAILED;
#   * TROUBLESHOOTING.md is keyed to the EXACT refusal strings of the root
#     helper, the routes and the installer (the project's rule for this file);
#   * the install guide says out loud that installing chrony REMOVES
#     systemd-timesyncd;
#   * the contract's README recipe (.claude/project.yml) reads tm/*.py when
#     the contract is present (it is export-ignored, so a bundle has none).
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "docs: audit actions from all modules, TROUBLESHOOTING keyed to real strings"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"

a_readme_lists_every_action() {
    local acts a missing="" n
    acts="$(PYTHONDONTWRITEBYTECODE=1 "$PY" - "$(tm_py_root)" <<'PYEOF' | tr -d '\r'
import ast, glob, sys
acts = set()
for f in sorted(glob.glob(sys.argv[1] + "/tm/*.py")):
    for n in ast.walk(ast.parse(open(f, encoding="utf-8").read())):
        if isinstance(n, ast.Call) and getattr(n.func, "attr", getattr(n.func, "id", "")) == "log_action" \
           and len(n.args) > 2 and isinstance(n.args[2], ast.Constant):
            acts.add(n.args[2].value)
print(" ".join(sorted(acts)))
PYEOF
)"
    n="$(wc -w <<<"$acts" | tr -d ' ')"
    [ "$n" -ge 21 ] || _tm_afail "the AST found only ${n} actions: ${acts}"
    for a in $acts AUDIT_WRITE_FAILED; do
        grep -q "\`${a}\`" "${TM_REPO_ROOT}/README.md" || missing="${missing} ${a}"
    done
    [ -z "$missing" ] || _tm_afail "README's audit-action list is missing:${missing}"
    grep -q "\*\*${n} audited actions\*\*" "${TM_REPO_ROOT}/README.md" \
        || _tm_afail "README's count of audited actions is not ${n}"
    grep -q "glob.glob('tm/\*.py')" "${TM_REPO_ROOT}/README.md" \
        || _tm_afail "README's recipe does not read tm/*.py"
}
tm_case "readme-lists-every-audit-action-from-all-modules" none a_readme_lists_every_action

a_contract_recipe_reads_all_modules() {
    local y="${TM_REPO_ROOT}/.claude/project.yml"
    [ -f "$y" ] || { tm_note "no .claude/project.yml here (export-ignored: a bundle or CI archive)"; return 0; }
    grep -q "glob.glob('tm/\*.py')" "$y" || _tm_afail "the contract's README recipe still reads tm/routes.py only"
}
tm_case "contract-recipe-reads-all-modules" none a_contract_recipe_reads_all_modules

a_troubleshooting_is_keyed_to_real_strings() {
    local T="${TM_REPO_ROOT}/TROUBLESHOOTING.md" H frag missing=""
    H="$(tm_apply_helper)"
    local -a PAIRS=(
        "$H|syslog over TLS needs the rsyslog-openssl package"
        "$H|neither chrony nor systemd-timesyncd is running on this"
        "$H|is not installed, so the HTTP redirect cannot be enabled"
        "$H|may be in a mixed state"
        "$H|ufw rule 80/tcp removed, but port 80 is STILL OPEN through:"
        "$H|The firewall state is unknown, so nothing was changed"
        "$H|ufw is not installed: no firewall rule was changed"
        "$H|is not root-owned and private to root; refusing to import it as root"
        "$H|the syslog user cannot read"
        "$H|has no \"sourcedir /etc/chrony/sources.d\" line"
        "$(tm_py_root)/tm/apply.py|no result was written for this request"
        "$(tm_py_root)/tm/apply.py|the apply unit could not be started"
        "$(tm_py_root)/tm/routes.py|The audit trail cannot be written, so nothing was changed."
        "$(tm_py_root)/tm/routes.py|WAS made, but its audit record could not be written"
        "$(tm_py_root)/tm/tls_check.py|the certificate does not verify against the supplied chain for TLS server use"
        "$(tm_py_root)/tm/settings_schema.py|Settings wins"
        "$(tm_py_root)/tm/audit.py|AUDIT_SYSLOG_FAILED: a committed audit record did NOT reach syslog"
        "$(tm_py_root)/tm/audit.py|did not accept the record within"
        "$(tm_py_root)/tm/audit.py|queue is full: the syslog daemon is stalled or not reading)"
        "$(tm_py_root)/tm/audit.py|audit syslog: could not send to"
        "$(tm_py_root)/tm/audit.py|audit syslog: this platform has no Unix sockets; record not sent"
        "$(tm_install_sh)|Installing chrony would also remove"
        "$(tm_install_sh)|The service is installed and running, but applying"
        "$(tm_upgrade_sh)|did NOT succeed"
        "$H|a compliance measurement carries no settings"
        "$(tm_py_root)/tm/routes.py|Read and accept the notice before signing in."
        "$(tm_py_root)/tm/routes.py|The directory could not be reached to re-check your group membership, so changes are refused"
        "$(tm_py_root)/tm/routes.py|The Kafka cluster refused the request or did not answer."
        "$(tm_install_sh)|No remote syslog collector was named."
        "$(tm_install_sh)|A host STIG check FAILED on Topic Manager's own files or configuration"
        "$(tm_install_sh)|The Topic Manager nginx logs could not be made private"
        "$(tm_upgrade_sh)|Refusing to upgrade: the audit trail would stay on this host without anyone saying so."
    )
    local pair src text
    for pair in "${PAIRS[@]}"; do
        src="${pair%%|*}"; frag="${pair#*|}"
        # Python sources: the string CONSTANTS, with implicit concatenation
        # applied by the parser, so a message split over two source lines is
        # still one string. Shell sources: the file as it is.
        case "$src" in
            *.py|*/tm-apply)
                text="$(PYTHONDONTWRITEBYTECODE=1 "$PY" - "$src" <<'PYEOF' | tr -d '\r'
import ast, sys
for n in ast.walk(ast.parse(open(sys.argv[1], encoding="utf-8").read())):
    if isinstance(n, ast.Constant) and isinstance(n.value, str):
        print(" ".join(n.value.split()))
PYEOF
)" ;;
            *) text="$(cat "$src")" ;;
        esac
        grep -qF -- "$frag" <<<"$text" || _tm_afail "the code no longer says [${frag}] (${src}); re-key TROUBLESHOOTING.md"
        grep -qF -- "$frag" "$T" || missing="${missing} [${frag}]"
    done
    [ -z "$missing" ] || _tm_afail "TROUBLESHOOTING.md has no entry for:${missing}"
}
tm_case "troubleshooting-is-keyed-to-the-real-strings" none a_troubleshooting_is_keyed_to_real_strings

a_chrony_removal_is_documented() {
    grep -qi "removes systemd-timesyncd" "${TM_REPO_ROOT}/docs/INSTALL.md"         || _tm_afail "docs/INSTALL.md does not say that installing chrony removes systemd-timesyncd"
    grep -qi "removes systemd-timesyncd" "${TM_REPO_ROOT}/README.md" || _tm_afail "README does not say it"
    grep -qi "REMOVES systemd-timesyncd" "$(tm_install_sh)" || _tm_afail "install.sh --help does not say it"
}
tm_case "installing-chrony-removes-timesyncd-is-said-out-loud" none a_chrony_removal_is_documented

# ─── round 4: the clean-room's eleven documentation defects (tm-qc, 2026-09-29)
# Someone with only the documents could not get from a stock build host to an
# upgraded air-gapped host. Each case pins one defect to what the docs, and
# where the defect was the CODE's message, what the code now says.

_pre_copy() {   # a copy of prepare-offline.sh that can be run without touching the repo
    local d="${TM_TMP}/po"
    rm -rf "$d"; mkdir -p "$d/tools" "$d/bin"
    cp "$(tm_prepare_sh)" "$d/prepare-offline.sh"
    cp "${TM_REPO_ROOT}/VERSION" "${TM_REPO_ROOT}/requirements.txt" "${TM_REPO_ROOT}/requirements.lock" "$d/"
    printf '#!/usr/bin/env bash\necho "check-requirements-lock: STUB"\nexit "${STUB_LOCK_RC:-0}"\n' > "$d/tools/check-requirements-lock.sh"
    # A PATH holding ONLY the named tools (symlinks to the real ones).
    local t
    for t in bash env cat tr cut mkdir dirname rm ls sed grep "$@"; do
        [ -e "$d/bin/$t" ] && continue
        ln -s "$(command -v "$t")" "$d/bin/$t" 2>/dev/null || true
    done
}

a_build_host_tools_are_named() {
    _pre_copy python3 tar gzip sha256sum git        # NO pip, NO curl
    local out rc=0
    out="$(cd "${TM_TMP}/po" && PATH="${TM_TMP}/po/bin" bash ./prepare-offline.sh 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || _tm_afail "prepare-offline.sh went on without pip and curl"
    case "$out" in *"This build host is missing: pip curl"*) ;; *) _tm_afail "the missing tools were not named: ${out}" ;; esac
    case "$out" in *PyPI*|*unreachable*|*"lock disagrees"*|*STUB*) _tm_afail "a missing TOOL was still reported as a network or lock failure: ${out}" ;; esac
    [ -d "${TM_TMP}/po/install/packages" ] && _tm_afail "prepare-offline.sh created its download directories before naming the missing tools"
    true
}
tm_case "prepare-offline-names-missing-build-tools-before-anything" none a_build_host_tools_are_named

a_lock_gate_verdict_is_reported_as_itself() {
    local out rc
    _pre_copy python3 tar gzip sha256sum git pip curl
    # Stubs so the run stops at the lock gate whatever this host has.
    printf '#!/usr/bin/env bash\nexit 0\n' > "${TM_TMP}/po/bin/pip"; chmod 755 "${TM_TMP}/po/bin/pip"
    rm -f "${TM_TMP}/po/bin/curl"; printf '#!/usr/bin/env bash\nexit 0\n' > "${TM_TMP}/po/bin/curl"; chmod 755 "${TM_TMP}/po/bin/curl"
    rc=0; out="$(cd "${TM_TMP}/po" && STUB_LOCK_RC=3 PATH="${TM_TMP}/po/bin" bash ./prepare-offline.sh 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || _tm_afail "an unverifiable lock let the build go on"
    case "$out" in *"could NOT BE VERIFIED"*) ;; *) _tm_afail "exit 3 (could not verify) was not reported as such: ${out}" ;; esac
    case "$out" in *"FAILED its gate"*) _tm_afail "exit 3 was reported as a WRONG lock: ${out}" ;; esac
    rc=0; out="$(cd "${TM_TMP}/po" && STUB_LOCK_RC=1 PATH="${TM_TMP}/po/bin" bash ./prepare-offline.sh 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || _tm_afail "a failed lock gate let the build go on"
    case "$out" in *"FAILED its gate (exit 1"*) ;; *) _tm_afail "exit 1 (the lock is wrong) was not reported as such: ${out}" ;; esac
    case "$out" in *"NOT BE VERIFIED"*|*unreachable*) _tm_afail "a WRONG lock was reported as a network problem: ${out}" ;; esac
    true
}
tm_case "the-lock-gate-verdict-is-reported-as-itself" none a_lock_gate_verdict_is_reported_as_itself

a_offline_procedure_is_complete() {
    local I="${TM_REPO_ROOT}/docs/INSTALL.md" R="${TM_REPO_ROOT}/README.md" B="${TM_REPO_ROOT}/install/README.md" f s
    # 1. build-host prerequisites; 3. a checkout path before the tag exists
    grep -q 'apt-get install -y git python3 python3-pip curl' "$I" || _tm_afail "INSTALL 5a does not list the build-host prerequisites"
    grep -q 'git checkout --detach <40-hex commit id under review>' "$I" || _tm_afail "INSTALL 5a has no checkout path before the release is tagged"
    # 4. offline --audit-only / --backup-only by absolute path, in both
    for f in "$I" "$R"; do
        for s in --audit-only --backup-only; do
            grep -qF "sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh ${s} --offline" "$f" \
                || _tm_afail "$(basename "$f") has no offline ${s} command by absolute path"
        done
    done
    # 5. the README's offline section checks the bundle, both ways
    local sect
    sect="$(tm_extract_between "$R" '^### Offline \(air-gapped\) upgrade$' '^## Offline Install$')"
    grep -q 'sha256sum -c topic-manager-offline-<version>.tar.gz.sha256' <<<"$sect" || _tm_afail "the README offline upgrade does not check the .sha256"
    grep -q 'out of band' <<<"$sect" || _tm_afail "the README offline upgrade does not require an out-of-band checksum"
    # 6. how rsyslog-openssl reaches an air-gapped upgraded host
    for f in "$I" "$R" "$B"; do
        grep -qF 'offline-src/install.sh --packages-only' "$f" || _tm_afail "$(basename "$f") does not say how to install a runtime package offline"
    done
    grep -q 'install.sh --packages-only' "$(tm_upgrade_sh)" || _tm_afail "the upgrade's rsyslog-openssl warning does not name the fix"
    # 7. the TLS 1.1 probe proves the SERVER refused
    grep -q 'alert protocol version' "$I" || _tm_afail "INSTALL 7 does not say what a SERVER refusal looks like"
    grep -q 'no protocols available' "$I" || _tm_afail "INSTALL 7 does not warn that a FIPS client refuses on its own"
    grep -qF "grep -c 'Cipher is (NONE)" "$I" && _tm_afail "INSTALL 7 still counts a client-side refusal as a pass"
    # 8. the bundle's contents are stated as measured, not as "no -dev headers"
    grep -qF 'No compiler and no `-dev` headers |' "$B" && _tm_afail "install/README.md still claims the bundle has no -dev packages"
    grep -q '520 packages, 187 MB' "$B" || _tm_afail "install/README.md does not state what the bundle measured"
    # 11. FIPS TLS 1.2 needs the extended master secret
    grep -q 'extended master secret' "$I" || _tm_afail "INSTALL 10 does not say FIPS TLS 1.2 needs the extended master secret"
    true
}
tm_case "the-offline-procedure-is-complete-as-written" none a_offline_procedure_is_complete

a_packages_only_changes_nothing_else() {
    local I; I="$(tm_install_sh)"
    local branch n_branch n_dirs n_rsync n_cfg
    branch="$(tm_extract_between "$I" '^if \[\[ \$PACKAGES_ONLY == true \]\]; then$' '^    exit 0$')"
    tm_assert_eq "if [[ \$PACKAGES_ONLY == true ]]; then
    install_required_packages
    success \"--packages-only: runtime packages present; nothing else was changed.\"
    exit 0" "$branch" "the --packages-only branch does something besides installing packages"
    n_branch="$(grep -n -m1 '^if \[\[ \$PACKAGES_ONLY == true \]\]; then$' "$I" | cut -d: -f1)"
    n_dirs="$(grep -n -m1 '^safe_install_dir [0-7]' "$I" | cut -d: -f1)"
    n_rsync="$(grep -n -m1 '^rsync ' "$I" | cut -d: -f1)"
    n_cfg="$(grep -n -m1 '^# ─── directory settings (fresh host only)' "$I" | cut -d: -f1)"
    [ "$n_branch" -lt "$n_cfg" ] && [ "$n_branch" -lt "$n_dirs" ] && [ "$n_branch" -lt "$n_rsync" ] \
        || _tm_afail "--packages-only exits only AFTER config, directory or file work (${n_branch} vs ${n_cfg}/${n_dirs}/${n_rsync})"
    grep -q '^install_required_packages$' "$I" || _tm_afail "the normal install no longer installs the runtime packages"
}
tm_case "install-packages-only-changes-nothing-else" none a_packages_only_changes_nothing_else

a_upgrade_checklist_numbers_and_paths() {
    local UP; UP="$(tm_upgrade_sh)"
    local block out
    block="$(tm_extract_between "$UP" '^echo "\$\{BOLD\}Post-upgrade checklist:\$\{NC\}"$' '^echo "  Rollback:  sudo bash \$\{SELF\} --restore \$\{TIMESTAMP\}"$')" \
        || _tm_afail "the checklist block moved"
    # Run the REAL block with no AIDE and no reboot pending: numbering must not skip.
    out="$( { echo 'BOLD=; NC=; YELLOW=; TIMESTAMP=20260929-000000; SELF=/abs/upgrade-full.sh'
              echo 'systemctl() { return 3; }; hostname() { echo tm.example.org; }'
              printf '%s\n' "$block"; } | bash 2>&1 | grep -E '^  [0-9]+\.' | sed -E 's/^  ([0-9]+)\..*/\1/' | tr '\n' ' ')"
    local want="1 2 3 "; [ -f /var/run/reboot-required ] && want="1 2 3 4 "
    tm_assert_eq "$want" "$out" "the printed checklist skips numbers"
    grep -qE '^SELF="\$\(readlink -f "\$\{BASH_SOURCE\[0\]\}"' "$UP" || _tm_afail "the upgrade does not know its own absolute path"
    grep -nE 'sudo bash upgrade-full\.sh --restore' "$UP" | grep -v ':#' \
        && _tm_afail "a printed rollback line still uses a relative upgrade-full.sh"
    true
}
tm_case "the-upgrade-checklist-counts-and-names-an-absolute-rollback" none a_upgrade_checklist_numbers_and_paths

# WO-0006 D1/D2: every documented upgrade command that would hit the v1.3.0
# remote-syslog gate (--audit-only, or the upgrade itself, online or offline,
# detached or not) carries the answer: --syslog-host or --no-remote-syslog.
# Read from README, INSTALL §12, install/README AND the text prepare-offline.sh
# prints (its echo lines, unescaped). A command block that loses the flag sends
# the operator into a refused upgrade. --backup-only/--list-backups/--restore
# need none, and each source says so for --backup-only; the refusal's exit
# code is stated where the flags are explained.
a_upgrade_commands_carry_the_syslog_answer() {
    local out
    out="$(PYTHONDONTWRITEBYTECODE=1 "$PY" - "$TM_REPO_ROOT" "$(tm_prepare_sh)" <<'PYEOF' | tr -d '\r'
import re, sys
root, prep = sys.argv[1], sys.argv[2]
def logical(text):
    out, cur = [], ''
    for line in text.splitlines():
        if line.rstrip().endswith('\\'):
            cur += line.rstrip()[:-1] + ' '
            continue
        out.append(cur + line); cur = ''
    return out
def printed(path):
    src = open(path, encoding='utf-8').read()
    tail = src[src.index('Offline preparation complete'):]
    return '\n'.join(m.group(1).replace('\\\\', '\\') for m in re.finditer(r'^echo "(.*)"$', tail, re.M))
srcs = {'README.md': open(root + '/README.md', encoding='utf-8').read(),
        'INSTALL.md': open(root + '/docs/INSTALL.md', encoding='utf-8').read(),
        'install/README.md': open(root + '/install/README.md', encoding='utf-8').read(),
        'prepare-offline.sh': printed(prep)}
for name, text in srcs.items():
    n, bad = 0, []
    for line in logical(text):
        cmd = line.strip()
        if 'upgrade-full.sh' not in cmd or not cmd.startswith('sudo ') \
                or not ('--offline' in cmd or '--repo-url' in cmd):
            continue
        if re.search(r'--(backup-only|list-backups|restore)\b', cmd):
            continue
        n += 1
        if '--syslog-host' not in cmd and '--no-remote-syslog' not in cmd:
            bad.append(cmd)
    print('%s n=%d bad=%s' % (name, n, bad))
    norm = re.sub(r'\s+', ' ', text)
    print('%s backup_only_said=%s' % (name, any(p in norm for p in ('--backup-only` needs neither', '--backup-only needs neither', 'no syslog flag'))))
PYEOF
)"
    local f want
    for f in README.md:5 INSTALL.md:5 install/README.md:1 prepare-offline.sh:2; do
        want="${f%:*}"
        local line; line="$(grep "^${want} n=" <<<"$out")"
        local n; n="$(sed -E 's/.* n=([0-9]+) .*/\1/' <<<"$line")"
        [ "${n:-0}" -ge "${f##*:}" ] || _tm_afail "${want}: found ${n:-0} gated upgrade command(s), expected at least ${f##*:} - the check would be vacuous: ${out}"
        case "$line" in *" bad=[]") ;; *) _tm_afail "${want}: an upgrade command without --syslog-host/--no-remote-syslog: ${line}" ;; esac
        tm_assert_eq "${want} backup_only_said=True" "$(grep "^${want} backup_only_said=" <<<"$out")" \
            "${want} does not say that --backup-only needs no syslog flag"
    done
    local R="${TM_REPO_ROOT}/README.md" I="${TM_REPO_ROOT}/docs/INSTALL.md"
    for f in "$R" "$I"; do
        local flat; flat="$(tr '\n' ' ' < "$f" | tr -s ' ')"
        grep -qF '`BLOCK remote syslog` and exits 2' <<<"$flat" || _tm_afail "$(basename "$f") does not give --audit-only's exit code for the syslog block"
        grep -qE 'refuses at its gate with (\*\*)?exit 1' <<<"$flat" || _tm_afail "$(basename "$f") does not give the refused upgrade's exit code"
    done
    grep -qF 'needs neither' <<<"$(tr '\n' ' ' < "${TM_REPO_ROOT}/install/README.md" | tr -s ' ')" || _tm_afail "install/README.md does not say --backup-only needs neither flag"
    # The exit codes the docs state are the script's.
    local UP; UP="$(tm_upgrade_sh)"
    grep -q '^fail()    { echo "${RED}\[FAIL\]${NC}    \$\*" >&2; exit 1; }$' "$UP" || _tm_afail "fail() no longer exits 1; the documented refusal code is wrong"
    grep -qF 'Refusing to upgrade: the audit trail would stay on this host' "$UP" || _tm_afail "the syslog refusal moved"
}
tm_case "every-documented-upgrade-command-says-where-the-audit-trail-goes" none a_upgrade_commands_carry_the_syslog_answer

# WO-0006 D3/D5: the operator docs name the compliance API and INSTALL §7
# verifies the v1.3.0 host state, each by a name the code actually uses.
a_compliance_api_and_v130_verify_documented() {
    local R="${TM_REPO_ROOT}/README.md" I="${TM_REPO_ROOT}/docs/INSTALL.md" sect
    grep -qF '`GET /api/compliance`' "$R" || _tm_afail "README does not document GET /api/compliance"
    grep -qF '`POST /api/system/apply/compliance`' "$R" || _tm_afail "README does not document POST /api/system/apply/compliance"
    grep -qF '`GET /api/system/apply/compliance`' "$R" || _tm_afail "README does not say how to read the measurement's state"
    grep -q "^@bp.route('/compliance', methods=\['GET'\])$" "${TM_REPO_ROOT}/tm/routes.py" || _tm_afail "the documented GET /api/compliance route is not in routes.py"
    grep -q "^@bp.route('/system/apply/<domain>', methods=\['POST'\])$" "${TM_REPO_ROOT}/tm/routes.py" || _tm_afail "the documented apply route is not in routes.py"
    grep -q "^CHECK_DOMAINS = ('compliance',)" "${TM_REPO_ROOT}/tm/apply.py" || _tm_afail "compliance is no longer a request domain"
    sect="$(tm_extract_between "$I" '^## 7\. Verify the install$' '^## 8\. ')"
    grep -qF 'log_format tm_dod' <<<"$sect" || _tm_afail "INSTALL 7 does not check the DoD log format"
    grep -q '^log_format tm_dod ' "${TM_REPO_ROOT}/nginx/tm-log-format.conf" || _tm_afail "the log format INSTALL 7 checks for is not the shipped one"
    grep -qF 'access_log /var/log/nginx/topic-manager-access.log tm_dod;' <<<"$sect" || _tm_afail "INSTALL 7 does not check the site logs in it"
    grep -qF 'access_log /var/log/nginx/topic-manager-access.log tm_dod;' "$(tm_nginx_site)" || _tm_afail "the site no longer logs as INSTALL 7 says"
    grep -qF "stat -c '%a %U %G %n' /var/log/nginx /var/log/nginx/topic-manager-*" <<<"$sect" || _tm_afail "INSTALL 7 does not check the site log modes"
    grep -qF 'tm-apply compliance --report' <<<"$sect" || _tm_afail "INSTALL 7 does not run the host STIG checks"
    grep -qF 'topic-manager-apply-compliance.service' <<<"$sect" || _tm_afail "INSTALL 7 does not check the compliance unit"
    [ -f "${TM_REPO_ROOT}/systemd/topic-manager-apply-compliance.service" ] || _tm_afail "the unit INSTALL 7 checks is not shipped"
}
tm_case "the-compliance-api-and-the-v130-verify-steps-are-documented" none a_compliance_api_and_v130_verify_documented

# WO-0006 af2 (LOW, docs): how a SCRIPT signs in to use the compliance API,
# and that a newer offline bundle goes into an emptied directory.
a_script_sign_in_and_empty_staging() {
    local readme="${TM_README:-${TM_REPO_ROOT}/README.md}" ir="${TM_INSTALL_README:-${TM_REPO_ROOT}/install/README.md}" f
    grep -qF -- '-d @/root/tm-login.json "$U/api/auth/login"' "$readme" || _tm_afail "README does not show a script signing in with POST /api/auth/login"
    grep -qF 'Then `POST /api/auth/login` with JSON `{"username", "password"}`' "$readme" || _tm_afail "README does not name the sign-in body"
    grep -qF -- '"$U/api/auth/consent"' "$readme" || _tm_afail "README does not show the consent acceptance a script needs while the notice is on"
    grep -qF 'send `X-TM-Request: 1` on every POST' "$readme" || _tm_afail "README does not say a script must send X-TM-Request: 1"
    grep -qF 'curl -sS -c "$J" -b "$J" -H "$H" -H "$T"' "$readme" || _tm_afail "README does not keep the session in a cookie jar"
    # The emptying comes BEFORE the extraction, in each place the extraction is shown.
    for f in "$readme" "$ir"; do
        awk '/find \/var\/lib\/topic-manager\/offline-src -mindepth 1 -delete/ { e = NR }
             /tar xzf topic-manager-offline-<version>.tar.gz +-C \/var\/lib\/topic-manager\/offline-src/ { if (!e || e > NR) bad = 1; t = NR }
             END { exit (bad || !t || !e) }' "$f" \
            || _tm_afail "${f}: offline-src is not emptied before the newer bundle is extracted into it"
    done
}
tm_case "a-script-sign-in-and-an-emptied-offline-staging-are-documented" none a_script_sign_in_and_empty_staging

tm_finish
