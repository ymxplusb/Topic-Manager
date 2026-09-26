#!/usr/bin/env bash
# =============================================================================
# t27 — THE FIREWALL STEP WORKS AGAINST A REAL-BEHAVING ufw (round 5).
#
# MEASURED 2026-09-26 on the real STIG + FIPS host: install.sh got through
# packages, venv, backend, frontend, config, systemd, polkit, nginx, the cert
# and the nginx.conf TLS edit, then died at
#   ufw --quiet allow 80/tcp  ->  "ERROR: Invalid syntax" + usage, exit 1
# ufw has no --quiet option. The line dates from v1.0.6 (commit 119ec47) and
# every host with ufw ACTIVE — every STIG host — failed there.
#
# The stub below is STRICT the way real ufw is: any argument starting with --
# other than --dry-run, --version or --force is "Invalid syntax", exit 1. The
# REAL open_firewall_ports is extracted and run against it.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "firewall: install opens 80/443 with ufw's real syntax"

INSTALL_SH="$(tm_install_sh)"

_stub() {   # _stub <status: active|inactive> [port whose allow fails]
    mkdir -p "${TM_TMP}/bin"
    cat > "${TM_TMP}/bin/ufw" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TM_TMP}/calls"
for a in "\$@"; do
    case "\$a" in
        --dry-run|--version|--force) ;;
        --*) echo "ERROR: Invalid syntax"; echo; echo "Usage: ufw COMMAND"; exit 1 ;;
    esac
done
case "\$1" in
    status) echo "Status: ${1}"; echo; echo "To                         Action      From" ;;
    allow)  [ "\$2" = "${2:-none}" ] && { echo "ERROR: Could not update running firewall"; exit 1; }
            echo "Rule added"; echo "Rule added (v6)" ;;
    *)      echo "ERROR: Invalid syntax"; exit 1 ;;
esac
STUB
    chmod +x "${TM_TMP}/bin/ufw"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'info() { echo "[INFO] $*"; }; success() { echo "[OK] $*"; }; warn() { echo "[WARN] $*"; }; die() { echo "[DIE] $*" >&2; exit 1; }'
        tm_extract_func "$INSTALL_SH" open_firewall_ports
        echo 'open_firewall_ports'
        echo 'echo RETURNED'
    } > "${TM_TMP}/fw.sh"
}
_run() { RC=0; PATH="${TM_TMP}/bin:${PATH}" bash "${TM_TMP}/fw.sh" > "${TM_TMP}/out" 2>&1 || RC=$?; }

a_active_opens_both() {
    _stub active; _run
    tm_assert_rc 0 "$RC" "the firewall step failed against a strict ufw — THE ROUND-5 DEFECT: $(cat "${TM_TMP}/out")"
    tm_assert_nogrep "Invalid syntax" "${TM_TMP}/out" "install passed ufw an option it does not have"
    grep -qx 'allow 80/tcp' "${TM_TMP}/calls" || _tm_afail "80/tcp was not allowed: $(cat "${TM_TMP}/calls")"
    grep -qx 'allow 443/tcp' "${TM_TMP}/calls" || _tm_afail "443/tcp was not allowed: $(cat "${TM_TMP}/calls")"
    tm_assert_grep "[OK] Firewall ports 80/443 open" "${TM_TMP}/out" "success was not reported"
    tm_assert_nogrep "Rule added" "${TM_TMP}/out" "ufw's own output was not kept quiet"
    tm_assert_grep "RETURNED" "${TM_TMP}/out" "the install did not carry on after the firewall step"
}
tm_case "an-active-ufw-gets-80-and-443-with-valid-syntax" none a_active_opens_both

a_inactive_untouched() {
    _stub inactive; _run
    tm_assert_rc 0 "$RC" "an inactive ufw failed the step"
    grep -q '^allow' "${TM_TMP}/calls" && _tm_afail "rules were added to an INACTIVE firewall: $(cat "${TM_TMP}/calls")"
    tm_assert_nogrep "Firewall ports 80/443 open" "${TM_TMP}/out" "ports were claimed open on an inactive firewall"
}
tm_case "an-inactive-ufw-is-left-alone" none a_inactive_untouched

a_failure_is_loud() {
    _stub active 443/tcp; _run
    tm_assert_rc 0 "$RC" "a failed rule ended the whole install (everything else is in place by now)"
    tm_assert_grep "could NOT open: 443/tcp (ERROR: Could not update running firewall)" "${TM_TMP}/out" \
        "a failed ufw rule was not named with ufw's reason"
    tm_assert_grep "sudo ufw allow 80/tcp; sudo ufw allow 443/tcp" "${TM_TMP}/out" "the fix-it command was not given"
    tm_assert_nogrep "Firewall ports 80/443 open" "${TM_TMP}/out" "ports were claimed open although a rule FAILED"
}
tm_case "a-failed-rule-is-a-loud-warning-never-a-claim" none a_failure_is_loud

a_no_invalid_ufw_flags_anywhere() {
    grep -rnE 'ufw[[:space:]]+(-[^ ]*[[:space:]]+)*--(quiet|silent|yes|assume-yes)' \
        "$INSTALL_SH" "${TM_REPO_ROOT}/install" "${TM_REPO_ROOT}/docs" "${TM_REPO_ROOT}/README.md" \
        "${TM_REPO_ROOT}/TROUBLESHOOTING.md" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' > "${TM_TMP}/hits"   # a shell comment describing the defect is not a use
    [ -s "${TM_TMP}/hits" ] && _tm_afail "an option ufw does not have is used: $(cat "${TM_TMP}/hits")" || true
}
tm_case "no-invalid-ufw-option-in-scripts-or-docs" none a_no_invalid_ufw_flags_anywhere

tm_finish
