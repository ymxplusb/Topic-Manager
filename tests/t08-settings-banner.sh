#!/usr/bin/env bash
# =============================================================================
# t08 — THE BANNER DEFAULT-OVERWRITE PATH (F4).
#
# This was reported as a cosmetic flash. It is not.
#
# SettingsTab.loadSettings used to `return` on a non-ok response, leaving the
# SEEDED defaults — bannerText 'UNCLASSIFIED', bannerBg 'green' — sitting in
# the very fields saveBanner() reads. So: session expires, the operator opens
# Settings, the load 401s silently, the operator flips one toggle, and
# saveBanner PUTs green/UNCLASSIFIED over the real banner. Globally. For every
# user. The cosmetic flash and the data loss are the same root cause: defaults
# seeded into the fields the save path reads.
#
# The cases drive the REAL app/components/SettingsTab.js through
# tests/lib/settings-probe.js — a vm context with a stubbed fetch. The claim
# is "it did not save"; the evidence is the recorded call log.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "settings load failure must not overwrite the operator banner"

# node is DECLARED as a requirement on every case below rather than checked
# here. It is present on the Windows workstation and absent on the Linux host,
# and a tm_die at file level turned the whole file into a harness error on the
# first remote run — exit 2, "no result can be trusted", for a host that was
# never expected to run these.
PROBE="${TM_TESTS_DIR}/lib/settings-probe.js"
[ -f "$PROBE" ] || tm_die "tests/lib/settings-probe.js is missing"

_probe() { node "$PROBE" "$TM_REPO_ROOT" "$1" 2>&1 | tr -d '\r'; }

_field() { grep -m1 "^${2}=" "$1" | cut -d= -f2- ; }

# The probe is JavaScript living outside the frontend gate's glob
# (app/components/**). Check it here, as a case, so it cannot rot into a
# harness error that looks like a code failure.
c_probe_parses() {
    node --check "$PROBE" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "tests/lib/settings-probe.js does not parse: $(cat "${TM_TMP}/out")"
}
tm_case "the-probe-itself-parses" node c_probe_parses

# ─── the data-loss path ──────────────────────────────────────────────────────
c_expired_session_does_not_overwrite() {
    _probe load-401 > "${TM_TMP}/out"
    tm_assert_eq "false" "$(_field "${TM_TMP}/out" settingsLoaded)" \
        "a 401 on load left the component believing settings were loaded"
    tm_assert_eq "set" "$(_field "${TM_TMP}/out" settingsError)" \
        "the load failed and said nothing. Silence is what let the operator
        carry on and trigger the overwrite"
    tm_assert_eq "0" "$(_field "${TM_TMP}/out" putCount)" \
        "THE DATA LOSS: after a failed load, toggling the banner PUT settings
        to the server. Those settings are the seeded defaults, and this route
        is global — it replaces the banner for every user"
}
tm_case "expired-session-on-load-does-not-overwrite-the-banner" node c_expired_session_does_not_overwrite

c_no_seeded_classification_default() {
    _probe load-401 > "${TM_TMP}/out"
    tm_assert_ne '"UNCLASSIFIED"' "$(_field "${TM_TMP}/out" bannerText)" \
        "bannerText still holds the seeded 'UNCLASSIFIED' after a failed load.
        Seeding a real classification marking into a field the save path reads
        is the root cause, not the symptom"
    tm_assert_ne '"green"' "$(_field "${TM_TMP}/out" bannerBg)" \
        "bannerBg still holds the seeded 'green' after a failed load"
}
tm_case "no-seeded-classification-value-survives-a-failed-load" node c_no_seeded_classification_default

c_network_failure_is_the_same() {
    _probe load-network > "${TM_TMP}/out"
    tm_assert_eq "false" "$(_field "${TM_TMP}/out" settingsLoaded)" \
        "a network failure on load was treated as a successful load"
    tm_assert_eq "set" "$(_field "${TM_TMP}/out" settingsError)" \
        "a network failure on load was swallowed silently"
    tm_assert_eq "0" "$(_field "${TM_TMP}/out" putCount)" \
        "a network failure on load still allowed a save"
}
tm_case "network-failure-on-load-is-surfaced-and-blocks-saving" node c_network_failure_is_the_same

c_save_refuses_without_a_load() {
    _probe save-before-load > "${TM_TMP}/out"
    tm_assert_eq "0" "$(_field "${TM_TMP}/out" putCount)" \
        "saveBanner/saveDow issued a PUT without any load having succeeded.
        The template guard alone is not enough — this is the second, independent
        barrier and it must hold on its own"
}
tm_case "save-refuses-when-no-load-has-succeeded" node c_save_refuses_without_a_load

# ─── the happy path still works ──────────────────────────────────────────────
c_successful_load_then_save_sends_the_operator_values() {
    _probe load-ok > "${TM_TMP}/out"
    tm_assert_eq "true" "$(_field "${TM_TMP}/out" settingsLoaded)" \
        "a successful load did not mark the settings loaded"
    tm_assert_eq "1" "$(_field "${TM_TMP}/out" putCount)" \
        "after a successful load, saving did not reach the server. The fix must
        not turn the feature off"
    grep -q 'SECRET//NOFORN' "${TM_TMP}/out" \
        || _tm_afail "the PUT did not carry the operator's loaded values.
        A save that sends something other than what was loaded is the same
        defect wearing different clothes:
        $(cat "${TM_TMP}/out")"
    grep -q 'UNCLASSIFIED' "${TM_TMP}/out" \
        && _tm_afail "the PUT carried the seeded default instead of the
        operator's value" || true
}
tm_case "successful-load-then-save-sends-the-loaded-values" node c_successful_load_then_save_sends_the_operator_values

# ─── the template must not render the form before the load ───────────────────
# Structural, and deliberately secondary: the behavioural cases above are what
# prove the data is safe. This one catches a template edit that puts the
# controls back on screen before there is anything real in them.
c_template_gates_the_form() {
    local f="${TM_REPO_ROOT}/app/components/SettingsTab.js"
    local n
    n="$(grep -c 'v-if="settingsLoaded"' "$f" || true)"
    [ "${n:-0}" -ge 2 ] || _tm_afail "the DoW and Branding sections are not both
        gated on settingsLoaded (found ${n:-0} of 2). The form would render
        seeded values the operator can change and save"
    grep -q 'v-if="!settingsLoaded"' "$f" \
        || _tm_afail "there is no loading/error state — the operator would see
        the sections simply vanish with no explanation"
}
tm_case "template-does-not-render-the-form-before-the-load" none c_template_gates_the_form

tm_finish
