#!/usr/bin/env bash
# =============================================================================
# t15 — THE AURORA GLASS THEME (v1.1.0).
#
# Owner decisions, 2026-09-26, and what each case holds:
#   * Aurora colours, surfaces, glass and the aurora field; NO change to
#     content, flow or placement — body text stays 14px, only the panel
#     radius moves (to 20px). -> palette-*, metrics-unchanged
#   * --text-muted reaches 4.5:1 on the card surface in EVERY mode. The old
#     dark value was about 2.9:1. -> muted-text-contrast (computed, WCAG)
#   * Colour-blind mode is the full dark CB palette plus non-colour cues
#     (a glyph on every status, the status text kept). -> cb-*
#   * Hard-coded colour literals moved onto tokens; --bg-panel/--border
#     defined; banners EXEMPT. -> no-colour-literal-outside-the-tokens
#   * The saved tmTheme value is validated and a storage exception is caught,
#     and the class is still set before login, in setTheme and on mount.
#     -> saved-theme-*, storage-*, every-theme-writer-*
#
# The CSS facts come from tests/lib/theme_css_check.py reading the real
# stylesheet; the behaviour comes from tests/lib/theme-probe.js driving the
# real TopBar.js helpers in a vm. Neither re-implements what it checks.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "Aurora Glass theme: palettes, contrast, CB cues, validated preference"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python found"
CSSCHK="${TM_TESTS_DIR}/lib/theme_css_check.py"
PROBE="${TM_TESTS_DIR}/lib/theme-probe.js"
[ -f "$CSSCHK" ] || tm_die "tests/lib/theme_css_check.py is missing"
[ -f "$PROBE" ]  || tm_die "tests/lib/theme-probe.js is missing"

_css() { "$PY" "$CSSCHK" "$TM_REPO_ROOT" 2>&1 | tr -d '\r'; }
_probe() { node "$PROBE" "$TM_REPO_ROOT" "$1" 2>&1 | tr -d '\r'; }
_field() { grep -m1 "^${2}=" "$1" | cut -d= -f2- ; }

# ─── the stylesheet ──────────────────────────────────────────────────────────
c_palettes() {
    _css > "${TM_TMP}/css"
    local m
    for m in dark light cb; do
        tm_assert_eq "OK" "$(_field "${TM_TMP}/css" "palette.${m}")" \
            "the ${m} palette does not carry the owner's token values"
    done
}
tm_case "palette-dark-light-cb-match-the-owner-map" none c_palettes

c_muted_contrast() {
    _css > "${TM_TMP}/css"
    local m r
    for m in dark light cb; do
        r="$(_field "${TM_TMP}/css" "muted_contrast.${m}")"
        tm_assert_nonempty "$r" "no contrast figure for ${m}"
        "$PY" -c "import sys; sys.exit(0 if float(sys.argv[1]) >= 4.5 else 1)" "$r" \
            || _tm_afail "--text-muted is ${r}:1 on --bg-card in ${m} mode; the
        owner's floor is 4.5:1. Muted text carries hints, timestamps and table
        headers — it has to be readable, not merely present"
    done
}
tm_case "muted-text-contrast-is-at-least-4.5-in-every-mode" none c_muted_contrast

c_no_literals() {
    _css > "${TM_TMP}/css"
    tm_assert_eq "0" "$(_field "${TM_TMP}/css" literals_outside_tokens)" \
        "a colour literal is set outside the token blocks, so one theme will
        not reach it: $(grep '^literal=' "${TM_TMP}/css" | head -3)"
    tm_assert_eq "2" "$(_field "${TM_TMP}/css" banner_default_literals)" \
        "the classification-banner default is not where it was. The banners are
        EXEMPT from the theme — their colours come from Settings"
    tm_assert_eq "True"  "$(_field "${TM_TMP}/css" bg_panel_defined)" "--bg-panel is still undefined"
    tm_assert_eq "True"  "$(_field "${TM_TMP}/css" border_token_defined)" "--border is still undefined"
    tm_assert_eq "False" "$(_field "${TM_TMP}/css" idle_card_fallback_literal)" \
        "the idle-warning card still carries a literal fallback colour"
}
tm_case "no-colour-literal-outside-the-tokens" none c_no_literals

c_cb_cues() {
    _css > "${TM_TMP}/css"
    tm_assert_eq "OK" "$(_field "${TM_TMP}/css" cb_cues)" \
        "a status in colour-blind mode is carried by hue alone"
    tm_assert_eq "True" "$(_field "${TM_TMP}/css" cb_solid)" \
        "colour-blind mode still paints the glass gradient or the aurora field"
}
tm_case "cb-mode-has-glyph-cues-and-solid-surfaces" none c_cb_cues

c_metrics() {
    _css > "${TM_TMP}/css"
    tm_assert_eq "14px" "$(_field "${TM_TMP}/css" body_font_size)" \
        "the body font size moved. Aurora's 16px body was deliberately NOT
        adopted: it would re-flow every page"
    tm_assert_eq "20px" "$(_field "${TM_TMP}/css" radius)" "the panel radius is not 20px"
}
tm_case "metrics-unchanged-except-the-panel-radius" none c_metrics

# ─── the saved preference ────────────────────────────────────────────────────
c_saved_valid() {
    _probe saved-light > "${TM_TMP}/out"
    tm_assert_eq "light" "$(_field "${TM_TMP}/out" read)" "a saved 'light' was not read back"
    tm_assert_eq "light-mode" "$(_field "${TM_TMP}/out" classes)" "light did not set exactly light-mode"
    _probe saved-cb > "${TM_TMP}/out"
    tm_assert_eq "cb-mode" "$(_field "${TM_TMP}/out" classes)" \
        "colour-blind did not set exactly cb-mode (it is its own dark palette,
        never layered on light)"
}
tm_case "saved-theme-is-restored" node c_saved_valid

c_saved_garbage() {
    _probe saved-garbage > "${TM_TMP}/out"
    tm_assert_eq "dark" "$(_field "${TM_TMP}/out" read)" \
        "a malformed saved theme was accepted instead of falling back to dark"
    tm_assert_eq "(none)" "$(_field "${TM_TMP}/out" classes)" \
        "a malformed saved theme put classes on <body>"
    tm_assert_eq "dark" "$(_field "${TM_TMP}/out" mountedTheme)" \
        "TopBar mounted() trusted the malformed value"
}
tm_case "saved-theme-garbage-falls-back-to-dark" node c_saved_garbage

c_storage_throws() {
    _probe storage-throws > "${TM_TMP}/out"
    grep -q '^EXCEPTION=' "${TM_TMP}/out" \
        && _tm_afail "localStorage throwing escaped the theme helpers — inside
        main.js onMounted that stops the whole shell rendering: $(cat "${TM_TMP}/out")"
    tm_assert_eq "dark" "$(_field "${TM_TMP}/out" read)" "unavailable storage did not fall back to dark"
    tm_assert_eq "light|light-mode" "$(_field "${TM_TMP}/out" afterSet)" \
        "with storage unavailable, choosing a theme no longer applied it"
}
tm_case "storage-exceptions-are-caught" node c_storage_throws

c_apply_each() {
    _probe apply-each > "${TM_TMP}/out"
    tm_assert_eq "dark|(none)"       "$(_field "${TM_TMP}/out" apply.dark)"  "dark left a class behind"
    tm_assert_eq "light|light-mode"  "$(_field "${TM_TMP}/out" apply.light)" "light is not exclusive"
    tm_assert_eq "cb|cb-mode"        "$(_field "${TM_TMP}/out" apply.cb)"    "cb is not exclusive"
    tm_assert_eq "dark|(none)"       "$(_field "${TM_TMP}/out" apply.bogus)" "an unknown theme was applied"
}
tm_case "apply-is-exclusive-and-rejects-unknown" node c_apply_each

# The three writers of the body class. Structural on purpose: the behaviour of
# the helper is proven above; this proves each of the three places still CALLS
# it, and that nobody reads tmTheme around it.
c_writers() {
    local main="${TM_REPO_ROOT}/app/main.js" top="${TM_REPO_ROOT}/app/components/TopBar.js"
    grep -q 'tmApplyTheme(tmReadTheme())' "$main" \
        || _tm_afail "main.js onMounted no longer applies the saved theme — the login page
        would always render dark"
    [ "$(grep -c 'tmApplyTheme(' "$top")" -ge 3 ] \
        || _tm_afail "TopBar.js setTheme/mounted no longer route through tmApplyTheme"
    grep -rn "localStorage.getItem('tmTheme')" "${TM_REPO_ROOT}/app" > "${TM_TMP}/raw" 2>/dev/null \
        && _tm_afail "something reads tmTheme directly, bypassing the validation:
        $(cat "${TM_TMP}/raw")" || true
}
tm_case "every-theme-writer-uses-the-validated-helper" none c_writers

tm_finish
