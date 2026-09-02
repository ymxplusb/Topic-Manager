#!/usr/bin/env bash
# =============================================================================
# t10 — THE PERMISSION BASELINE IS NUL-DELIMITED, AND EVERY RECORD IS CHECKED.
#
# The baseline is written by root and replayed by root as chown + chmod. Until
# v1.0.4 it was written as
#     %p|%u|%g|%m\n
# and a filename may contain BOTH '|' and a newline. www-data owns
# /var/www/topic-manager, which record_baseline walks, so a file created there
# and named
#     x<newline>/some/other/path|root|root|777
# put a whole EXTRA RECORD into the baseline that root then replayed against a
# path of the attacker's choosing. That is the case
# forged-record-does-not-reach-the-replay below, and it is the reason this file
# exists — it fails on the old producer and on any consumer that splits on '|'.
#
# The other half is the consumer. A record is four attacker-influenced fields
# handed to chown and chmod as root, so baseline_assert_record refuses a mode
# that is not octal, an owner that is not a name, and — the one that matters —
# any path that does not RESOLVE inside the recorded roots. realpath resolves
# symlinks on purpose: chmod(1) has no --no-dereference, so a recorded file
# swapped for a symlink is otherwise an arbitrary chmod.
#
# Legacy backups are still read: every restore point on a host running 1.0.3
# holds the pipe format, and --restore is exactly where a new script meets an
# old backup. Silently restoring NOTHING from one would be worse than the bug.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "the baseline record format and its replay"

UP="$(tm_upgrade_sh)"

# The harness script: the REAL functions, extracted, with the host paths
# relocated under a fake root.
_build() {
    local h="$1"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'FAKEROOT="$1"; ACTION="$2"; shift 2'
        echo 'RED=""; GREEN=""; YELLOW=""; BOLD=""; NC=""'
        echo 'info()    { echo "[INFO] $*"; }'
        echo 'warn()    { echo "[WARN] $*"; }'
        echo 'success() { echo "[OK] $*"; }'
        # fail() is not decoration here: baseline_assert_record calls it, and
        # its exit status is the verdict every refusal case asserts on.
        echo 'fail()    { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'SERVICE="topic-manager"'
        echo 'APP_USER="root"'
        echo 'WEB_USER="'"$TM_WEB_USER"'"'
        echo 'APP_HOME="${FAKEROOT}/opt/topic-manager"'
        echo 'FRONTEND_DIR="${FAKEROOT}/var/www/topic-manager"'
        echo 'CONFIG_DIR="${FAKEROOT}/etc/topic-manager"'
        echo 'DROPIN_DIR="${FAKEROOT}/etc/systemd/system/${SERVICE}.service.d"'
        echo 'CLUSTERS_DIR="${CONFIG_DIR}/clusters.d"'
        echo 'CLUSTERS_FILE="${CLUSTERS_DIR}/clusters.yaml"'
        echo 'CERT_DIR="${APP_HOME}/data/cluster-certs"'
        echo 'PERM_BASELINE=""'
        echo
        # Same mechanical relocation t03 uses, with the same refusal: these
        # tests must never be able to touch the real /etc or /var/www.
        tm_extract_between "$UP" '^BASELINE_PATHS=\(' '^\)$' | sed 's#"/#"${FAKEROOT}/#g'
        echo 'for _p in "${BASELINE_PATHS[@]}"; do'
        echo '  case "$_p" in'
        echo '    "$FAKEROOT"/*) ;;'
        echo '    *) echo "REFUSING: BASELINE_PATHS entry escaped the fake root: $_p" >&2; exit 90 ;;'
        echo '  esac'
        echo 'done'
        echo
        tm_extract_func "$UP" record_baseline
        echo
        tm_extract_func "$UP" baseline_stream
        echo
        tm_extract_func "$UP" baseline_is_legacy
        echo
        tm_extract_func "$UP" baseline_assert_record
        echo
        tm_extract_func "$UP" baseline_lookup
        echo
        tm_extract_line "$UP" '^baseline_has\(\)'
        echo
        tm_extract_func "$UP" apply_baseline
        echo
        echo 'case "$ACTION" in'
        echo '  record)  PERM_BASELINE="$1"; record_baseline "$PERM_BASELINE" ;;'
        echo '  apply)   PERM_BASELINE="$1"; apply_baseline "$2" "${3:-}" "${4:-}" "${5:-}" ;;'
        echo '  has)     PERM_BASELINE="$1"; baseline_has "$PERM_BASELINE" "$2" ;;'
        echo '  reapply) PERM_BASELINE="$1"'
        # The real Phase 10 re-application block, extracted whole.
        tm_extract_between "$UP" '^info "Re-applying the recorded permission baseline' \
                                 '^success "Re-applied recorded ownership/mode' \
            | sed 's/^/    /'
        echo '    ;;'
        echo '  *) echo "unknown action" >&2; exit 99 ;;'
        echo 'esac'
    } > "$h"
}

FR=""; BL=""; CANARY=""
_mkhost() {
    FR="$TM_TMP/root"; BL="$TM_TMP/permissions.baseline"
    rm -rf "$FR"; rm -f "$BL"
    mkdir -p "$FR/etc/topic-manager/tls" \
             "$FR/etc/topic-manager/clusters.d" \
             "$FR/opt/topic-manager/data/cluster-certs" \
             "$FR/var/www/topic-manager/app" \
             "$FR/etc/systemd/system/topic-manager.service.d"
    printf 'kafka:\n  brokers: broker1:9092\n' > "$FR/etc/topic-manager/config.yaml"
    printf 'clusters:\n  - id: bare-metal\n' > "$FR/etc/topic-manager/clusters.d/clusters.yaml"
    printf 'x\n' > "$FR/var/www/topic-manager/index.html"
    printf '[Service]\nEnvironment=TM_SECRET_KEY=CANARY\n' \
        > "$FR/etc/systemd/system/topic-manager.service.d/override.conf"
    # OUTSIDE the fake root's recorded trees, and outside BASELINE_PATHS: the
    # path a forged record would name. It is what "did the replay reach
    # something it was never recorded for" is asked of.
    CANARY="$TM_TMP/canary"
    printf 'do not touch\n' > "$CANARY"
    chmod 600 "$CANARY"
    _build "$TM_TMP/ph.sh"
}
_do() { RC=0; bash "$TM_TMP/ph.sh" "$FR" "$@" > "$TM_TMP/out" 2>&1 || RC=$?; }

FE=""; CFG=""
_paths() {
    FE="$FR/var/www/topic-manager"
    CFG="$FR/etc/topic-manager/config.yaml"
}

# ─── the format itself ───────────────────────────────────────────────────────
b_format_is_nul_delimited() {
    _mkhost; _paths
    _do record "$BL"; tm_assert_rc 0 "$RC" "record_baseline failed: $(cat "$TM_TMP/out")"
    tm_baseline_is_nul "$BL" || _tm_afail \
        "the baseline has no NUL bytes in it — it is still a line format, and a
        filename containing a newline can forge a record in it"
    tm_assert_recorded "$BL" "$CFG" "" "" "" "config.yaml is not in the baseline"
    tm_assert_recorded "$BL" "${FE}/index.html" "" "" "" "a served file is not in the baseline"
}
tm_case "baseline-is-written-nul-delimited" none b_format_is_nul_delimited

# ─── THE ONE THIS FILE EXISTS FOR ────────────────────────────────────────────
# A filename carrying a newline AND a pipe, shaped exactly like a second record
# for a path outside the recorded roots. Under the old producer this became a
# real record and root replayed it.
DECOY=""
_plant_forgery() {
    # THE EXPLOIT, built the way www-data can actually build it.
    #
    # A filename cannot contain '/', so the injected record cannot name an
    # absolute path by itself. It does not have to: create a DIRECTORY whose
    # name ends in a newline and rebuild the target path underneath it. find
    # then prints
    #     <frontend>/ev\n/tmp/.../canary
    # and a consumer that splits on newlines reads a SECOND record whose path
    # field is /tmp/.../canary — absolute, because every slash after the newline
    # came from find's own path separator rather than from a filename.
    #
    # The mode it forges is the decoy's own, so 0777 here is what root would
    # apply to the canary.
    local dir="${FE}/$(printf 'ev\n')"
    DECOY="${dir}${CANARY}"
    mkdir -p "$(dirname "$DECOY")" 2>/dev/null || return 1
    printf 'decoy\n' > "$DECOY" 2>/dev/null || return 1
    chmod 777 "$DECOY" 2>/dev/null || true
    return 0
}

b_forged_record_is_not_in_the_baseline() {
    _mkhost; _paths
    _plant_forgery || tm_die "could not plant the forgery (newline in a directory name)"

    _do record "$BL"; tm_assert_rc 0 "$RC" "record_baseline failed: $(cat "$TM_TMP/out")"

    # The decoy is ONE record, whole. The canary is not a record at all.
    tm_assert_recorded "$BL" "$DECOY" "" "" "" \
        "the planted file was not recorded at all — the producer is dropping it
        rather than writing it as one field, which is a different bug"
    tm_assert_not_recorded "$BL" "$CANARY" \
        "a FILENAME forged a second record naming an absolute path outside the
        recorded roots. This is the defect: the baseline is being written in a
        format that a filename can inject into"
}
tm_case "forged-record-in-a-filename-is-not-in-the-baseline" weirdnames b_forged_record_is_not_in_the_baseline

b_forged_record_does_not_reach_the_replay() {
    # The consequence, not the shape: what the replay actually DOES.
    _mkhost; _paths
    _plant_forgery || tm_die "could not plant the forgery (newline in a directory name)"
    chmod 600 "$CANARY"

    _do record "$BL"; tm_assert_rc 0 "$RC" "record_baseline failed: $(cat "$TM_TMP/out")"
    _do reapply "$BL"
    tm_assert_rc 0 "$RC" "the re-application failed on a legitimate baseline: $(cat "$TM_TMP/out")"
    tm_assert_mode 600 "$CANARY" \
        "root replayed a forged record: a file outside the recorded roots was
        chmodded to the mode a FILENAME asked for"
    tm_assert_mode 777 "$DECOY" \
        "the planted file did not get its own recorded mode back — the record
        for it was lost, so this case would have passed for the wrong reason"
}
tm_case "forged-record-in-a-filename-does-not-reach-the-replay" weirdnames,modes b_forged_record_does_not_reach_the_replay

# ─── the consumer's own guards ───────────────────────────────────────────────
b_record_outside_the_roots_is_refused() {
    _mkhost; _paths
    printf '%s\0%s\0%s\0%s\0' "$CANARY" root root 777 > "$BL"
    _do reapply "$BL"
    tm_assert_ne 0 "$RC" \
        "a record naming a path outside the recorded roots was replayed instead
        of refused. record_baseline cannot produce one, so it is corrupt or forged"
    tm_assert_grep "outside the recorded roots" "$TM_TMP/out" \
        "the refusal did not say why"
}
tm_case "record-outside-the-recorded-roots-is-refused" none b_record_outside_the_roots_is_refused

b_record_outside_the_roots_changes_nothing() {
    _mkhost; _paths
    printf '%s\0%s\0%s\0%s\0' "$CANARY" root root 777 > "$BL"
    _do reapply "$BL"
    tm_assert_mode 600 "$CANARY" \
        "the refusal happened AFTER the chmod — the guard has to run before the
        mutation, not report it afterwards"
}
tm_case "a-refused-record-changes-nothing" modes b_record_outside_the_roots_changes_nothing

b_non_octal_mode_is_refused() {
    _mkhost; _paths
    printf '%s\0%s\0%s\0%s\0' "${FE}/index.html" root root 'nonsense' > "$BL"
    _do reapply "$BL"
    tm_assert_ne 0 "$RC" "a record whose mode is not octal was handed to chmod"
    tm_assert_grep "is not octal" "$TM_TMP/out" "the refusal did not say why"
}
tm_case "record-with-a-non-octal-mode-is-refused" none b_non_octal_mode_is_refused

b_symlinked_record_is_refused() {
    # A recorded file replaced by a symlink between the record and the replay.
    # chmod(1) follows symlinks and has no -h, so without the resolve-then-check
    # this is an arbitrary chmod as root.
    _mkhost; _paths
    _do record "$BL"; tm_assert_rc 0 "$RC" ""
    rm -f "${FE}/index.html"
    ln -s "$CANARY" "${FE}/index.html" 2>/dev/null \
        || tm_die "this filesystem will not create symlinks"
    _do reapply "$BL"
    tm_assert_ne 0 "$RC" \
        "a recorded path that now resolves OUTSIDE the recorded roots was
        replayed — realpath is not being consulted, so chmod followed the symlink"
    tm_assert_mode 600 "$CANARY" "the symlink target was chmodded through the link"
}
tm_case "a-recorded-path-swapped-for-a-symlink-is-refused" symlinks,modes b_symlinked_record_is_refused

b_chown_failure_is_not_swallowed() {
    # The replay used to end every chown and chmod with `2>/dev/null || true`.
    # A permission model that cannot report a failed chown is a permission model
    # that reports success either way. The owner here is name-shaped, so it gets
    # past validation and fails where it should: at chown(1).
    _mkhost; _paths
    # NOT index.html: that path is enumerated in BASELINE_PATHS, so
    # apply_baseline reaches it first and the case would go red on a different
    # chown from the one it names. MEASURED 2026-09-01: mutation control M46
    # (the Phase 10 loop swallowing chown failures again) SURVIVED for exactly
    # that reason. app/main.js is found only by record_baseline's find, so only
    # the replay loop touches it.
    printf 'x\n' > "${FE}/app/main.js"
    printf '%s\0%s\0%s\0%s\0' "${FE}/app/main.js" 'tm-no-such-user' 'tm-no-such-user' 644 > "$BL"
    _do reapply "$BL"
    tm_assert_ne 0 "$RC" \
        "chown failed and the run carried on. Every remaining path in the
        baseline is then applied on a host whose ownership is already wrong,
        and the upgrade reports 'Re-applied recorded ownership/mode' regardless"
    tm_assert_grep "chown failed" "$TM_TMP/out" "the failure was not named"
}
tm_case "a-chown-that-fails-stops-the-run" chown b_chown_failure_is_not_swallowed

# ─── the legacy format ───────────────────────────────────────────────────────
# Every restore point taken by v1.0.3 is in the old format, and --restore is
# where a new script reads an old backup. Reading one as NUL would find no
# records and report "restored 0 paths" — a silent no-op.
b_legacy_baseline_is_still_applied() {
    _mkhost; _paths
    local u g; u="$(id -un)"; g="$(id -gn)"
    printf '%s|%s|%s|640\n' "$CFG" "$u" "$g" > "$BL"
    chmod 600 "$CFG"
    _do reapply "$BL"
    tm_assert_rc 0 "$RC" "a pre-v1.0.4 baseline was not applied at all: $(cat "$TM_TMP/out")"
    tm_assert_mode 640 "$CFG" \
        "a legacy pipe-delimited baseline restored NOTHING. Every backup taken
        before v1.0.4 is in that format, so --restore would report success and
        put no permissions back"
}
tm_case "a-pre-v1.0.4-pipe-baseline-is-still-applied" modes b_legacy_baseline_is_still_applied

b_legacy_ambiguous_record_is_refused() {
    # The legacy format cannot represent a path containing '|'. Such a line
    # parses with the mode field holding the tail, and is refused rather than
    # guessed at.
    _mkhost; _paths
    printf '%s|%s|%s|%s\n' "${FE}/a|b" root root 644 > "$BL"
    _do reapply "$BL"
    tm_assert_ne 0 "$RC" \
        "a legacy record the format cannot represent unambiguously was replayed
        anyway — that is the injection, arriving through an old backup"
}
tm_case "an-ambiguous-legacy-record-is-refused" none b_legacy_ambiguous_record_is_refused

# ─── the lookup, on the new format ───────────────────────────────────────────
b_lookup_is_exact() {
    _mkhost; _paths
    local u g; u="$(id -un)"; g="$(id -gn)"
    # Every field through %s. `printf '\0700'` is the OCTAL ESCAPE \070 ('8')
    # followed by '0', not a NUL and a mode — it silently produced a baseline
    # with no separator and the case failed for that reason instead of the one
    # it names. Found on the first Linux run, 2026-09-01.
    {
        printf '%s\0%s\0%s\0%s\0' "${CFG}.bak" "$u" "$g" 700
        printf '%s\0%s\0%s\0%s\0' "$CFG"       "$u" "$g" 640
    } > "$BL"
    printf 'backup\n' > "${CFG}.bak"
    chmod 600 "$CFG"
    _do apply "$BL" "$CFG"
    tm_assert_rc 0 "$RC" "apply_baseline failed: $(cat "$TM_TMP/out")"
    tm_assert_mode 640 "$CFG" \
        "apply_baseline used a DIFFERENT path's record — the lookup is matching
        on a prefix rather than on the whole path"
}
tm_case "the-lookup-matches-the-whole-path" modes b_lookup_is_exact

b_has_answers_on_the_new_format() {
    # The Phase 10 new-file pass asks this question about every file it finds;
    # if it answers "no" for a recorded path, that file is re-chowned to the
    # directory's owner and the restored per-file ownership is lost.
    _mkhost; _paths
    _do record "$BL"; tm_assert_rc 0 "$RC" ""
    _do has "$BL" "${FE}/index.html"
    tm_assert_rc 0 "$RC" "baseline_has said a recorded path is not recorded"
    _do has "$BL" "${FE}/never-existed.js"
    tm_assert_ne 0 "$RC" "baseline_has said an unrecorded path IS recorded"
}
tm_case "baseline_has-answers-for-recorded-and-unrecorded-paths" none b_has_answers_on_the_new_format

tm_finish
