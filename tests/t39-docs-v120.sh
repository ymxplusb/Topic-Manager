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

tm_finish
