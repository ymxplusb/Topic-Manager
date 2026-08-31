#!/usr/bin/env bash
# =============================================================================
# t00 — VERIFY THE VERIFIER.
#
# Every other file here rests on two claims: that an extraction which matches
# nothing FAILS rather than quietly evaluating an empty string, and that a host
# which cannot hold file modes is DETECTED rather than passing every permission
# assertion vacuously. Both claims are tested here, in both directions.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "the harness cannot go quiet"

# Deliberately the REPO file, not $(tm_upgrade_sh): this file verifies the
# harness itself, so it must read the same bytes whether or not tests/mutate.sh
# has pointed the rest of the suite at a mutated copy.
UP="${TM_REPO_ROOT}/install/upgrade-full.sh"

# ── extraction ───────────────────────────────────────────────────────────────
s_extract_real() {
    local out
    out="$(tm_extract_func "$UP" backup_dropin)"
    tm_assert_nonempty "$out" "extracting backup_dropin() produced nothing"
    printf '%s\n' "$out" > "$TM_TMP/f"
    tm_assert_grep 'backup_dropin() {' "$TM_TMP/f" "extraction lost the signature"
    tm_assert_grep 'cp -a'             "$TM_TMP/f" "extraction lost the body"
    # It must stop at the function, not swallow the rest of the file.
    tm_assert_nogrep 'restore_dropin() {' "$TM_TMP/f" "extraction ran past the closing brace"
}
tm_case "extract-real-function-verbatim" none s_extract_real

s_extract_nomatch() {
    # THE control that matters: an anchor matching nothing must be exit 2,
    # never an empty string that the caller happily tests.
    cat > "$TM_TMP/probe.sh" <<'EOS'
. "${TM_TESTS_DIR}/lib/harness.sh"
tm_extract_func "$1" no_such_function_anywhere
EOS
    local rc=0
    TM_TESTS_DIR="$TM_TESTS_DIR" bash "$TM_TMP/probe.sh" "$UP" >"$TM_TMP/o" 2>&1 || rc=$?
    tm_assert_rc 2 "$rc" "a non-matching anchor must be a HARNESS ERROR (2)"
    tm_assert_grep 'HARNESS ERROR' "$TM_TMP/o" "the refusal must say so out loud"
    tm_assert_grep 'matched 0 line' "$TM_TMP/o" "the refusal must name the match count"
}
tm_case "extract-refuses-on-zero-matches" none s_extract_nomatch

s_extract_twice() {
    # An anchor matching twice is equally unusable: which one was tested?
    printf 'dup_fn() {\n  :\n}\ndup_fn() {\n  :\n}\n' > "$TM_TMP/two.sh"
    cat > "$TM_TMP/probe2.sh" <<'EOS'
. "${TM_TESTS_DIR}/lib/harness.sh"
tm_extract_func "$1" dup_fn
EOS
    local rc=0
    TM_TESTS_DIR="$TM_TESTS_DIR" bash "$TM_TMP/probe2.sh" "$TM_TMP/two.sh" >"$TM_TMP/o2" 2>&1 || rc=$?
    tm_assert_rc 2 "$rc" "a doubly-matching anchor must be a HARNESS ERROR (2)"
    tm_assert_grep 'matched 2 line' "$TM_TMP/o2" ""
}
tm_case "extract-refuses-on-two-matches" none s_extract_twice

s_between_anchors() {
    local out
    out="$(tm_extract_between "$UP" '^DROPIN_BACKUP_NAME=' '^backup_dropin\(\)')"
    printf '%s\n' "$out" > "$TM_TMP/b"
    tm_assert_grep 'DROPIN_BACKUP_NAME=' "$TM_TMP/b" ""
    tm_assert_grep 'backup_dropin() {'   "$TM_TMP/b" "the end anchor line must be included"
}
tm_case "extract-between-includes-both-anchors" none s_between_anchors

# ── capability detection ─────────────────────────────────────────────────────
s_probe_can_say_no() {
    # Falsifiability of the detector itself. Neutralise chmod; the probe must
    # report that this filesystem cannot hold modes. If this case ever passes
    # with "yes", every permission assertion in the suite is decorative.
    chmod() { return 0; }
    local verdict
    verdict="$(TM_FORCE_NO_MODES= tm_probe_modes "$TM_TMP")"
    unset -f chmod
    tm_assert_eq "no" "$verdict" "the mode detector failed to notice a no-op chmod"
}
tm_case "mode-detector-says-no-when-chmod-lies" none s_probe_can_say_no

s_probe_matches_platform() {
    local verdict expect
    verdict="$(TM_FORCE_NO_MODES= tm_probe_modes "$TM_TMP")"
    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW*|MSYS*|CYGWIN*) expect=no ;;   # Git Bash: chmod 600 reads back 644
        Linux|Darwin)         expect=yes ;;
        *)                    expect="$verdict" ;;   # unknown platform: no claim
    esac
    tm_assert_eq "$expect" "$verdict" \
        "the mode detector disagrees with the platform — investigate before trusting any permission case"
}
tm_case "mode-detector-agrees-with-platform" none s_probe_matches_platform

s_force_flag() {
    tm_assert_eq "no" "$(TM_FORCE_NO_MODES=1 tm_probe_modes "$TM_TMP")" \
        "TM_FORCE_NO_MODES must force the pessimistic verdict"
}
tm_case "mode-detector-honours-force-flag" none s_force_flag

# ── the runner's own verdicts ────────────────────────────────────────────────
_mk_fixture() {   # _mk_fixture <file> <requires> <body-line>
    {
        echo 'set -uo pipefail'
        echo '. "${TM_TESTS_DIR}/lib/harness.sh"'
        echo 'tm_header "fixture"'
        echo 'fx() {'
        echo "  $3"
        echo '}'
        echo "tm_case \"fixture-case\" $2 fx"
        echo 'tm_finish'
    } > "$1"
}

_runner() {   # _runner <extra-env-assignments...> -- <args...>
    local envs=() args=() seen=false a
    for a in "$@"; do
        if [ "$a" = "--" ]; then seen=true; continue; fi
        if [ "$seen" = true ]; then args+=("$a"); else envs+=("$a"); fi
    done
    env -u TM_RESULTS -u TM_TMP TM_NO_COLOUR=1 "${envs[@]}" \
        bash "${TM_TESTS_DIR}/run.sh" "${args[@]}"
}

s_skip_is_not_pass() {
    _mk_fixture "$TM_TMP/t99-fake.sh" modes 'tm_assert_eq a b "this must never be reached"'
    local rc=0
    _runner TM_FORCE_NO_MODES=1 -- "$TM_TMP/t99-fake.sh" >"$TM_TMP/r" 2>&1 || rc=$?
    tm_assert_rc 0 "$rc" "a skip alone must not fail the default run"
    tm_assert_grep '1 skipped'   "$TM_TMP/r" "the skip must be counted"
    tm_assert_grep 'DID NOT RUN' "$TM_TMP/r" "the skip banner must be loud"
    tm_assert_grep '0 passed'    "$TM_TMP/r" "a skipped case must NOT be reported as a pass"
}
tm_case "runner-skips-loudly-never-silently-passes" none s_skip_is_not_pass

s_strict_fails_on_skip() {
    _mk_fixture "$TM_TMP/t99-fake2.sh" modes 'tm_assert_eq a b "unreachable"'
    local rc=0
    _runner TM_FORCE_NO_MODES=1 -- --strict "$TM_TMP/t99-fake2.sh" >"$TM_TMP/r2" 2>&1 || rc=$?
    tm_assert_rc 1 "$rc" "--strict must turn a skip into a failure"
}
tm_case "runner-strict-turns-skip-into-failure" none s_strict_fails_on_skip

s_failing_case_goes_red() {
    # Proof the gate can go RED. Without this, "the suite passed" means nothing.
    _mk_fixture "$TM_TMP/t99-fake3.sh" none 'tm_assert_eq 1 2 "deliberate"'
    local rc=0
    _runner -- "$TM_TMP/t99-fake3.sh" >"$TM_TMP/r3" 2>&1 || rc=$?
    tm_assert_rc 1 "$rc" "a failing case must fail the runner"
    tm_assert_grep 'FAILED CASES' "$TM_TMP/r3" ""
}
tm_case "runner-goes-red-on-a-failing-case" none s_failing_case_goes_red

s_harness_error_propagates() {
    _mk_fixture "$TM_TMP/t99-fake4.sh" none 'tm_extract_func "$(tm_upgrade_sh)" definitely_not_here'
    local rc=0
    _runner -- "$TM_TMP/t99-fake4.sh" >"$TM_TMP/r4" 2>&1 || rc=$?
    tm_assert_rc 2 "$rc" "a broken extraction must exit 2 from the runner, not 0"
    tm_assert_grep 'HARNESS ERROR' "$TM_TMP/r4" ""
}
tm_case "runner-exits-2-on-a-broken-extraction" none s_harness_error_propagates

tm_finish
