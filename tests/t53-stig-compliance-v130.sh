#!/usr/bin/env bash
# =============================================================================
# t53 — THE STIG COMPLIANCE DOCUMENT AND PAGE ARE ONE ANSWER (v1.3.0, DQ3).
#
# tools/check-stig-compliance.sh holds docs/STIG-COMPLIANCE.md (the source of
# truth) and tm/compliance.py RULES (the page) together, field for field, and
# the document to its own coverage and shape. It passes on the tree, and it
# goes RED on each one-sided or shape-breaking edit below — made to COPIES,
# never to the tracked files.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "STIG compliance: the document and the page agree, and the gate can fail"

GATE="${TM_STIG_GATE:-${TM_REPO_ROOT}/tools/check-stig-compliance.sh}"
DOC="${TM_REPO_ROOT}/docs/STIG-COMPLIANCE.md"
RULES="$(tm_py_root)/tm/compliance.py"
HELPER="$(tm_apply_helper)"

_gate() {   # _gate [doc] [rules] [helper] -> output; GATE_RC
    GATE_RC=0
    STIG_DOC="${1:-$DOC}" STIG_RULES="${2:-$RULES}" STIG_HELPER="${3:-$HELPER}" bash "$GATE" > "${TM_TMP}/gate.out" 2>&1 || GATE_RC=$?
    GATE_OUT="$(tr -d '\r' < "${TM_TMP}/gate.out")"
}

a_gate_passes() {
    _gate
    tm_assert_eq "0" "$GATE_RC" "the gate fails on the tree: ${GATE_OUT}"
    case "$GATE_OUT" in "PASS: 75 rules (32 NGNX-APP, 43 SRG-APP), document and page agree field for field"*) ;;
        *) _tm_afail "the gate does not say what it held: ${GATE_OUT}" ;; esac
}
tm_case "the-document-and-the-page-agree" none a_gate_passes

# _red <name> <file: doc|rules|helper> <python edit of `t`> <expected text in the failure>
_red() {
    local name="$1" which="$2" edit="$3" want="$4" src dst d r h
    case "$which" in doc) src="$DOC" ;; rules) src="$RULES" ;; helper) src="$HELPER" ;; esac
    dst="${TM_TMP}/${name}.${which}"
    python3 - "$src" "$dst" <<PYEOF || _tm_afail "the edit for ${name} did not apply"
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
o = t
$edit
if t == o:
    sys.exit(1)
open(sys.argv[2], 'w', encoding='utf-8').write(t)
PYEOF
    d="$DOC"; r="$RULES"; h="$HELPER"
    case "$which" in doc) d="$dst" ;; rules) r="$dst" ;; helper) h="$dst" ;; esac
    _gate "$d" "$r" "$h"
    tm_assert_eq "1" "$GATE_RC" "the gate PASSED ${name}: ${GATE_OUT}"
    case "$GATE_OUT" in *"$want"*) ;; *) _tm_afail "the gate failed ${name} for another reason: ${GATE_OUT}" ;; esac
}

a_gate_goes_red() {
    _red doc_status doc "t = t.replace('- **Status:** PARTLY', '- **Status:** MET', 1)" "status differs"
    _red rules_status rules "t = t.replace('YES, PARTLY', 'YES, MET', 1)" "status differs"
    _red rules_constant rules "t = t.replace(\"CAT_I, CAT_II = 'CAT I', 'CAT II'\", \"CAT_I, CAT_II = 'CAT I', 'CAT 2'\", 1)" "sev differs"
    _red rules_title rules "t = t.replace('NGINX must use TLS 1.2', 'NGINX must use TLS 1.3', 1)" "title differs"
    _red doc_check doc "t = t.replace('- **Live checks:** \`tls_protocols\`', '- **Live checks:** none', 1)" "checks differs"
    _red doc_drop doc "i = t.index('### NGNX-APP-000590'); j = t.index('### NGNX-APP-000720'); t = t[:i] + t[j:]" "the document has 74 rules"
    _red doc_decision doc "t = t.replace('- **Decision:** No', '- **Decision:** Yes', 1)" "NOT-MET is for, and only for"
    _red doc_ao doc "t = re.sub(r'- \*\*AO decision point:\*\* [^\n]*\n', '', t, count=1)" "no \"AO decision point\""
    _red doc_evidence doc "t = t.replace('tm/compliance.py remote_syslog', 'tm/no-such-module.py remote_syslog', 1)" "which does not exist"
    _red doc_unknown_check doc "t = t.replace('- **Live checks:** \`fips_mode\`', '- **Live checks:** \`fips_moode\`', 1)" "does not declare"
    _red doc_totals doc "t = re.sub(r'^\| MET \| (\d+) \|$', lambda m: '| MET | %d |' % (int(m.group(1)) + 1), t, count=1, flags=re.M)" "the Totals table says MET"
    _red doc_field doc "t = t.replace('- **How verified:**', '- **Verified:**', 1)" "no \"How verified\""
    _red helper_check helper "t = t.replace(\"_check('server_tokens', 'pass'\", \"_check('server_token', 'pass'\").replace(\"_check('server_tokens', 'fail'\", \"_check('server_token', 'fail'\")" "host check server_tokens is never produced"
    _red rules_unused rules "t = t.replace(\"'time_sync', 'audit_write_state')\", \"'time_sync', 'audit_write_state', 'spare_check')\", 1)" "declares the check spare_check and no rule uses it"
}
tm_case "the-gate-goes-red-on-every-one-sided-or-shape-breaking-edit" none a_gate_goes_red

tm_finish
