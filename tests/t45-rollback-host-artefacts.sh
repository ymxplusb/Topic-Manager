#!/usr/bin/env bash
# =============================================================================
# t45 — A ROLLBACK RETIRES WHAT THE NEWER RELEASE ADDED TO THE HOST
# (clean-room 2026-09-29, R1).
#
# `upgrade-full.sh --restore` to a 1.1.x restore point left
# topic-manager-audit-prune.timer and topic-manager-apply-audit.path ENABLED.
# They run tm.audit_retention and tm.apply, which 1.1.x does not have, so the
# restored host failed a unit every day. The only guard was a name list gated
# on a marker the NEW script writes into every restore point it takes — so it
# never fired on the one rollback that mattered.
#
# The restore point now carries an inventory of every product host artefact
# (units and enablement links, polkit rules, the root-helper tree) with a
# byte-exact copy of each. A restore retires what is present now and absent
# then — ANY name, not a list — and puts back what was there.
#
#   * a round trip through the REAL functions on a fake root: a 1.1.x host,
#     its restore point, the 1.2.0 upgrade (plus a unit name no list could
#     know), the restore;
#   * a restore point without the inventory changes nothing and names what
#     it could not judge;
#   * Phase 4 takes the inventory before the checksums, and restore_from_backup
#     uses it.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "a rollback retires the units, rules and helpers the newer release added"

UP="$(tm_upgrade_sh)"

# _prog <fakeroot> <verb> <backup-dir> — the real functions, relocated.
_prog() {
    local R="$1"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        # T_FAIL_UNIT: the one unit whose `systemctl disable` fails, as it
        # would where systemd refuses (gatekeeper round 5, d).
        echo 'systemctl() { echo "systemctl $*" >> "'"${TM_TMP}"'/calls"'
        echo '    if [[ "$1" == disable && " $* " == *" ${T_FAIL_UNIT:-none} "* ]]; then echo "Failed to disable unit: Access denied" >&2; return 1; fi; }'
        echo 'info() { echo "[INFO] $*"; }; warn() { echo "[WARN] $*"; }'
        echo 'SERVICE=topic-manager'
        echo 'OWNED_UNIT_DIR="'"${R}"'/etc/systemd/system"'
        echo 'DROPIN_DIR="'"${R}"'/etc/systemd/system/topic-manager.service.d"'
        echo 'OWNED_POLKIT_DIR="'"${R}"'/etc/polkit-1/rules.d"'
        echo 'OWNED_LIBEXEC_DIR="'"${R}"'/usr/libexec/topic-manager"'
        echo 'OWNED_RUNTIME_DIR="'"${R}"'/run"'
        echo 'RETIRED_UNITS=(); RETIRED_RUNTIME=(); RESTORE_PROBLEMS=()'
        tm_extract_func "$UP" socket_unit_paths
        tm_extract_func "$UP" unit_runtime_dirs
        tm_extract_func "$UP" retire_unit
        tm_extract_func "$UP" remove_retired_runtime
        tm_extract_func "$UP" owned_inventory
        tm_extract_func "$UP" owned_artefact
        tm_extract_func "$UP" owned_unit_file
        tm_extract_func "$UP" same_artefact
        tm_extract_func "$UP" backup_owned_artefacts
        tm_extract_func "$UP" restore_owned_artefacts
        tm_extract_func "$UP" restore_socket_unit
        # As restore_from_backup orders them: the socket unit first.
        echo 'rollback() { restore_socket_unit "$1"; restore_owned_artefacts "$1"; }'
        echo '"$1" "$2"'
        echo 'for _p in "${RESTORE_PROBLEMS[@]}"; do echo "PROBLEM|${_p}"; done'
    } > "${TM_TMP}/prog.sh"
    RC=0; bash "${TM_TMP}/prog.sh" "$2" "$3" >> "${TM_TMP}/out" 2>&1 || RC=$?
}

# The host as v1.1.x left it.
_host_110() {
    local R="$1" U="$1/etc/systemd/system"
    mkdir -p "$U/multi-user.target.wants" "$R/etc/polkit-1/rules.d"
    printf '[Service]\nExecStart=gunicorn --bind 127.0.0.1:5001\n' > "$U/topic-manager.service"
    printf '[Service]\n# nginx-test v1.1\n' > "$U/topic-manager-nginx-test.service"
    ln -s ../topic-manager.service "$U/multi-user.target.wants/topic-manager.service"
    printf '// polkit v1.1: restart only\n' > "$R/etc/polkit-1/rules.d/50-topic-manager.rules"
    printf '[Service]\n# someone else\n' > "$U/other.service"
    # An operator's override of a package unit: recorded, never the product's.
    mkdir -p "$U/nginx.service.d"
    printf '[Service]\nLimitNOFILE=65536\n' > "$U/nginx.service.d/override.conf"
}

# What the 1.2.0 upgrade lays over it — and one name no list in the script has.
_upgrade_120() {
    local R="$1" U="$1/etc/systemd/system" u
    mkdir -p "$U/timers.target.wants" "$U/paths.target.wants" "$U/sockets.target.wants" \
             "$R/usr/libexec/topic-manager/lib"
    printf '[Service]\nExecStart=gunicorn --bind unix:/run/x\n' > "$U/topic-manager.service"
    printf '[Service]\n# nginx-test v1.2\n' > "$U/topic-manager-nginx-test.service"
    for u in topic-manager-audit-prune.service topic-manager-apply-audit.service \
             topic-manager-future-thing.service; do
        printf '[Service]\nExecStart=python3 -m tm.x\n' > "$U/$u"
    done
    # An apply unit keeps its runtime directory after it stops
    # (RuntimeDirectoryPreserve=yes) and leaves its verdict there (clean-room N5).
    printf '[Service]\nRuntimeDirectory=topic-manager-apply\nRuntimeDirectoryPreserve=yes\nExecStart=/usr/libexec/topic-manager/tm-apply tls\n' \
        > "$U/topic-manager-apply-tls.service"
    mkdir -p "$R/run/topic-manager-apply"; printf '{"state":"applied"}\n' > "$R/run/topic-manager-apply/tls.result"
    # A product unit NOT named topic-manager* (gatekeeper round 5, b), with a
    # drop-in directory and an enablement link; and a drop-in directory of a
    # topic-manager* unit that is retired.
    printf '[Service]\nUser=topic-manager\nExecStart=/usr/libexec/topic-manager/tm-future\n' > "$U/tm-future.service"
    mkdir -p "$U/tm-future.service.d" "$U/topic-manager-future-thing.service.d"
    printf '[Service]\nMemoryMax=1G\n' > "$U/tm-future.service.d/10-limits.conf"
    printf '[Service]\nNice=5\n' > "$U/topic-manager-future-thing.service.d/override.conf"
    ln -s ../tm-future.service "$U/multi-user.target.wants/tm-future.service"
    # NOT the product's, added after the restore point: a snap refresh writes
    # a mount unit and its enablement link. A rollback must never stop it.
    printf '[Mount]\nWhat=/var/lib/snapd/snaps/core22_1234.snap\n' > "$U/snap-core22-1234.mount"
    ln -s ../snap-core22-1234.mount "$U/multi-user.target.wants/snap-core22-1234.mount"
    # A drop-in the newer release added to a unit the older one ALSO ships:
    # the unit stays, the drop-in goes.
    mkdir -p "$U/topic-manager-nginx-test.service.d"
    printf '[Service]\nTimeoutSec=30\n' > "$U/topic-manager-nginx-test.service.d/10-v120.conf"
    # ... and another tool changed its own unit after the restore point.
    printf '[Service]\n# someone else, changed later\n' > "$U/other.service"
    printf '[Timer]\nOnCalendar=daily\n' > "$U/topic-manager-audit-prune.timer"
    printf '[Path]\nPathChanged=/run/x\n' > "$U/topic-manager-apply-audit.path"
    printf '[Timer]\nOnCalendar=hourly\n' > "$U/topic-manager-future-thing.timer"
    printf '[Socket]\nListenStream=%s\n' "$SOCK" > "$U/topic-manager.socket"
    ln -s ../topic-manager-audit-prune.timer "$U/timers.target.wants/topic-manager-audit-prune.timer"
    ln -s ../topic-manager-future-thing.timer "$U/timers.target.wants/topic-manager-future-thing.timer"
    ln -s ../topic-manager-apply-audit.path "$U/paths.target.wants/topic-manager-apply-audit.path"
    ln -s ../topic-manager.socket "$U/sockets.target.wants/topic-manager.socket"
    # A NEW enablement link to a unit the restore point also holds: the link
    # goes, the unit is not disabled.
    mkdir -p "$U/graphical.target.wants"
    ln -s ../topic-manager.service "$U/graphical.target.wants/topic-manager.service"
    printf '#!/usr/bin/python3\n' > "$R/usr/libexec/topic-manager/tm-apply"
    printf 'RULES = 1\n' > "$R/usr/libexec/topic-manager/lib/settings_schema.py"
    printf '// polkit v1.2: restart + four apply units\n' > "$R/etc/polkit-1/rules.d/50-topic-manager.rules"
    printf '// polkit v1.2: a second rule file\n' > "$R/etc/polkit-1/rules.d/51-topic-manager-apply.rules"
    # A rule of the product's under another name (it names the account), and
    # one that is not the product's at all.
    printf 'if (subject.user === "topic-manager") {}\n' > "$R/etc/polkit-1/rules.d/60-tm-apply.rules"
    printf '// another package\n' > "$R/etc/polkit-1/rules.d/49-other.rules"
    # The operator's drop-in (secrets), created after the restore point was
    # taken: restore_dropin owns it, so the inventory must never judge it.
    mkdir -p "$U/topic-manager.service.d"
    printf '[Service]\n# changed by the upgrade\n' > "$U/topic-manager.service.d/override.conf"
}

_mksock() {
    SOCKD="$(mktemp -d /tmp/tms.XXXXXX)"; SOCK="${SOCKD}/gunicorn.sock"
    "$(tm_python)" -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCK" \
        || tm_die "could not create a Unix socket at ${SOCK}"
}

r_round_trip() {
    local R="${TM_TMP}/root" BD="${TM_TMP}/bd" U="${TM_TMP}/root/etc/systemd/system" u
    mkdir -p "$BD/manifest" "$BD/system"; : > "${TM_TMP}/calls"; : > "${TM_TMP}/out"
    _mksock
    _host_110 "$R"
    _prog "$R" backup_owned_artefacts "$BD"
    tm_assert_rc 0 "$RC" "backup_owned_artefacts failed: $(cat "${TM_TMP}/out")"
    tm_assert_file "$BD/manifest/owned-artefacts.list" "the restore point holds no inventory"
    _upgrade_120 "$R"
    : > "${TM_TMP}/calls"
    _prog "$R" rollback "$BD"
    tm_assert_rc 0 "$RC" "the rollback failed: $(cat "${TM_TMP}/out")"
    grep -q '^PROBLEM|' "${TM_TMP}/out" && _tm_afail "a clean rollback reported problems: $(grep '^PROBLEM|' "${TM_TMP}/out")"

    # Every unit the newer release added is disabled and stopped, and GONE —
    # tm-future.service too, which no name prefix covers (gatekeeper round 5, b).
    for u in topic-manager-audit-prune.timer topic-manager-apply-audit.path topic-manager-audit-prune.service \
             topic-manager-apply-audit.service topic-manager-apply-tls.service topic-manager.socket \
             topic-manager-future-thing.timer topic-manager-future-thing.service tm-future.service; do
        grep -qx "systemctl disable --now ${u}" "${TM_TMP}/calls" \
            || { rm -rf "$SOCKD"; _tm_afail "CLEAN-ROOM R1: ${u} was not disabled --now on the rollback: $(tr '\n' ';' < "${TM_TMP}/calls")"; }
        [ -e "$U/$u" ] && { rm -rf "$SOCKD"; _tm_afail "CLEAN-ROOM R1: ${u} survived a rollback to a release without it"; }
    done
    local left
    left="$(find "$U" -path '*.wants/*' -name 'topic-manager*' ! -name topic-manager.service)"
    [ -z "$left" ] || { rm -rf "$SOCKD"; _tm_afail "an enablement link of a retired unit survived: ${left}"; }
    [ -e "$SOCK" ] && { rm -rf "$SOCKD"; _tm_afail "CLEAN-ROOM R2: the retired socket unit left its socket file"; }
    rm -rf "$SOCKD"
    tm_assert_nofile "$U/tm-future.service.d" "GATEKEEPER R5 b: the drop-in directory of a retired unit survived a rollback"
    tm_assert_nofile "$U/topic-manager-future-thing.service.d" "the drop-in directory of a retired topic-manager unit survived"
    tm_assert_nofile "$U/topic-manager-nginx-test.service.d" "a drop-in the newer release added to a KEPT unit survived the rollback"
    [ -L "$U/multi-user.target.wants/tm-future.service" ] && _tm_afail "the enablement link of a retired tm-* unit survived"
    # Clean-room N5: the retired apply unit's runtime directory and its result.
    tm_assert_nofile "$R/run/topic-manager-apply" "CLEAN-ROOM N5: the retired units' runtime directory (1.2.0 result files) survived"
    # ... and the count is every unit retired, the socket unit included.
    local listed counted
    listed="$(grep -c '^\[INFO\] Retired ' "${TM_TMP}/out")"
    counted="$(sed -n 's/.*inventory (\([0-9]*\) unit(s) retired.*/\1/p' "${TM_TMP}/out")"
    tm_assert_eq 9 "$listed" "not every added unit was retired"
    tm_assert_eq "$listed" "$counted" "CLEAN-ROOM N5: the summary counts ${counted} unit(s) retired after listing ${listed}"
    tm_assert_nofile "$R/usr/libexec/topic-manager" "the root helper tree the newer release added survived"
    tm_assert_nofile "$R/etc/polkit-1/rules.d/51-topic-manager-apply.rules" "a polkit rule the newer release added survived"
    tm_assert_nofile "$R/etc/polkit-1/rules.d/60-tm-apply.rules" "a polkit rule of the product's under another name survived"
    tm_assert_file "$R/etc/polkit-1/rules.d/49-other.rules" "a polkit rule that is not the product's was removed"

    # What was there comes back byte-exact, enablement included.
    tm_assert_grep "polkit v1.1: restart only" "$R/etc/polkit-1/rules.d/50-topic-manager.rules" \
        "the polkit rule still grants the newer release's units"
    tm_assert_grep "nginx-test v1.1" "$U/topic-manager-nginx-test.service" "a unit the old release shipped was not put back"
    tm_assert_grep "127.0.0.1:5001" "$U/topic-manager.service" "the service unit was not put back"
    [ -L "$U/multi-user.target.wants/topic-manager.service" ] || _tm_afail "the service lost its enablement link"
    [ -L "$U/graphical.target.wants/topic-manager.service" ] && _tm_afail "an enablement link the newer release added survived"
    grep -qx 'systemctl disable --now topic-manager.service' "${TM_TMP}/calls" \
        && _tm_afail "a unit the restored release ships was disabled"
    grep -q 'topic-manager-nginx-test' "${TM_TMP}/calls" && _tm_afail "a unit the restored release ships was retired"

    # Not the product's: another tool's unit, ADDED (a snap mount) or CHANGED
    # since the restore point, is left as it is and named; an operator's
    # override of a package unit is left alone.
    grep -q 'snap-core22-1234.mount' "${TM_TMP}/calls" && _tm_afail "a rollback stopped a unit that is not the product's (a snap mount)"
    tm_assert_file "$U/snap-core22-1234.mount" "a unit that is not the product's was removed"
    [ -L "$U/multi-user.target.wants/snap-core22-1234.mount" ] || _tm_afail "the enablement of a unit that is not the product's was removed"
    tm_assert_grep "changed later" "$U/other.service" "a unit that is not the product's was reverted to the restore point"
    tm_assert_grep "snap-core22-1234.mount (added since the restore point)" "${TM_TMP}/out" "an added unit that is not the product's is not named"
    tm_assert_grep "other.service (changed or removed since the restore point)" "${TM_TMP}/out" "a changed unit that is not the product's is not named"
    tm_assert_grep "LimitNOFILE=65536" "$U/nginx.service.d/override.conf" "an operator's drop-in for a package unit was touched"
    # Out of scope for this function: the service's drop-in (restore_dropin owns it).
    tm_assert_file "$U/other.service" "a unit that is not the product's was touched"
    tm_assert_grep "changed by the upgrade" "$U/topic-manager.service.d/override.conf" \
        "the inventory reached into the drop-in directory, which backup_dropin owns"

    # systemd reloads AFTER the last removal.
    local last_disable reload
    last_disable="$(grep -n 'disable --now' "${TM_TMP}/calls" | tail -1 | cut -d: -f1)"
    reload="$(grep -nx 'systemctl daemon-reload' "${TM_TMP}/calls" | tail -1 | cut -d: -f1)"
    tm_assert_nonempty "$reload" "no daemon-reload after the units were removed"
    [ "$reload" -gt "$last_disable" ] || _tm_afail "daemon-reload ran before the units were retired"
}
tm_case "rollback-retires-every-unit-rule-and-helper-the-newer-release-added" linux,symlinks r_round_trip

r_restore_point_had_them() {
    # A 1.2.0 -> 1.2.x rollback: the restore point HAD the helper and a unit;
    # they come back, and nothing is retired.
    local R="${TM_TMP}/root" BD="${TM_TMP}/bd" U="${TM_TMP}/root/etc/systemd/system"
    mkdir -p "$BD/manifest" "$BD/system"; : > "${TM_TMP}/calls"; : > "${TM_TMP}/out"
    _mksock
    _host_110 "$R"; _upgrade_120 "$R"
    _prog "$R" backup_owned_artefacts "$BD"
    printf '#!/usr/bin/python3\n# a later build\n' > "$R/usr/libexec/topic-manager/tm-apply"
    rm -f "$U/topic-manager-audit-prune.timer"
    : > "${TM_TMP}/calls"
    _prog "$R" restore_owned_artefacts "$BD"
    rm -rf "$SOCKD"
    tm_assert_rc 0 "$RC" "restore failed: $(cat "${TM_TMP}/out")"
    grep -q 'disable' "${TM_TMP}/calls" && _tm_afail "a unit the restore point held was retired: $(cat "${TM_TMP}/calls")"
    tm_assert_file "$U/topic-manager-audit-prune.timer" "a unit the restore point held did not come back"
    tm_assert_nogrep "a later build" "$R/usr/libexec/topic-manager/tm-apply" "the helper was not put back byte-exact"
}
tm_case "rollback-puts-back-what-the-restore-point-held" linux,symlinks r_restore_point_had_them

r_legacy_point() {
    local R="${TM_TMP}/root" BD="${TM_TMP}/bd" U="${TM_TMP}/root/etc/systemd/system"
    mkdir -p "$BD/manifest" "$BD/system"; : > "${TM_TMP}/calls"; : > "${TM_TMP}/out"
    _mksock
    _host_110 "$R"; _upgrade_120 "$R"
    _prog "$R" restore_owned_artefacts "$BD"
    rm -rf "$SOCKD"
    tm_assert_rc 0 "$RC" "a restore point without the inventory failed the restore: $(cat "${TM_TMP}/out")"
    [ -s "${TM_TMP}/calls" ] && _tm_afail "a restore point without the inventory guessed: $(cat "${TM_TMP}/calls")"
    tm_assert_file "$U/topic-manager-audit-prune.timer" "a restore point without the inventory removed something"
    tm_assert_grep "predates the host-artefact inventory" "${TM_TMP}/out" "the operator is not told"
    tm_assert_grep "topic-manager-audit-prune.timer" "${TM_TMP}/out" "the artefacts it could not judge are not named"
}
tm_case "a-restore-point-without-the-inventory-names-and-never-guesses" linux,symlinks r_legacy_point

r_socket_dropin_goes_with_the_socket() {
    # restore_socket_unit retires the socket unit on its own (a restore point
    # older than the inventory too): its drop-in directory goes with it.
    local R="${TM_TMP}/root" BD="${TM_TMP}/bd" U="${TM_TMP}/root/etc/systemd/system"
    mkdir -p "$BD/manifest" "$BD/system" "$U/topic-manager.socket.d"; : > "${TM_TMP}/calls"; : > "${TM_TMP}/out"
    printf '[Socket]\nListenStream=/nonexistent/x.sock\n' > "$U/topic-manager.socket"
    printf '[Socket]\nBacklog=64\n' > "$U/topic-manager.socket.d/override.conf"
    _prog "$R" restore_socket_unit "$BD"
    tm_assert_rc 0 "$RC" "restore_socket_unit failed: $(cat "${TM_TMP}/out")"
    tm_assert_nofile "$U/topic-manager.socket" "the socket unit was not retired"
    tm_assert_nofile "$U/topic-manager.socket.d" "a retired unit's drop-in directory outlived it"
}
tm_case "a-retired-units-drop-in-directory-goes-with-it" linux,symlinks r_socket_dropin_goes_with_the_socket

r_runtime_dir_kept_while_declared() {
    # A 1.2.0 -> 1.2.x rollback: the restore point HAS an apply unit that
    # declares the runtime directory; the one retired declares it too. It stays.
    # A RuntimeDirectory= that is not a plain name is a problem, never an rm.
    local R="${TM_TMP}/root" BD="${TM_TMP}/bd" U="${TM_TMP}/root/etc/systemd/system"
    mkdir -p "$BD/manifest" "$BD/system" "$U" "$R/run/topic-manager-apply" "$R/etc/keep"; : > "${TM_TMP}/calls"; : > "${TM_TMP}/out"
    printf '[Service]\nRuntimeDirectory=topic-manager-apply\n' > "$U/topic-manager-apply-syslog.service"
    _prog "$R" backup_owned_artefacts "$BD"
    printf '[Service]\nRuntimeDirectory=topic-manager-apply\n' > "$U/topic-manager-apply-tls.service"
    printf '[Service]\nRuntimeDirectory=../etc/keep\n' > "$U/topic-manager-escape.service"
    printf 'x\n' > "$R/run/topic-manager-apply/syslog.result"
    _prog "$R" restore_owned_artefacts "$BD"
    tm_assert_rc 0 "$RC" "restore failed: $(cat "${TM_TMP}/out")"
    tm_assert_file "$R/run/topic-manager-apply/syslog.result" "a runtime directory a KEPT unit declares was removed"
    tm_assert_dir "$R/etc/keep" "a RuntimeDirectory= with .. reached outside the runtime root"
    tm_assert_grep "PROBLEM|a retired unit declared RuntimeDirectory=../etc/keep" "${TM_TMP}/out" "an unsafe RuntimeDirectory= is not a restore problem"
}
tm_case "rollback-keeps-a-runtime-directory-a-kept-unit-declares" linux,symlinks r_runtime_dir_kept_while_declared

r_problems_are_reported() {
    # Gatekeeper round 5, d: a unit systemctl could not disable, and a recorded
    # file with no saved copy, are restore PROBLEMS, not warnings in passing.
    local R="${TM_TMP}/root" BD="${TM_TMP}/bd" U="${TM_TMP}/root/etc/systemd/system"
    mkdir -p "$BD/manifest" "$BD/system"; : > "${TM_TMP}/calls"; : > "${TM_TMP}/out"
    _mksock
    _host_110 "$R"
    _prog "$R" backup_owned_artefacts "$BD"
    rm -f "$BD/system/owned$U/topic-manager-nginx-test.service"
    _upgrade_120 "$R"
    export T_FAIL_UNIT=topic-manager-audit-prune.timer
    _prog "$R" rollback "$BD"
    unset T_FAIL_UNIT
    rm -rf "$SOCKD"
    tm_assert_grep "PROBLEM|systemctl disable --now topic-manager-audit-prune.timer failed (Failed to disable unit: Access denied)" \
        "${TM_TMP}/out" "a unit systemctl could not retire is not a restore problem"
    tm_assert_grep "PROBLEM|the restore point lists $U/topic-manager-nginx-test.service but holds no copy of it" \
        "${TM_TMP}/out" "a recorded file with no saved copy is not a restore problem"
    [ "$(grep -c '^PROBLEM|' "${TM_TMP}/out")" -eq 2 ] || _tm_afail "expected exactly two problems: $(grep '^PROBLEM|' "${TM_TMP}/out")"
}
tm_case "a-unit-that-cannot-be-retired-or-a-missing-copy-is-a-restore-problem" linux,symlinks r_problems_are_reported

r_shipped_artefacts_name_the_service() {
    # owned_artefact judges a unit by what it SAYS as well as its name: every
    # unit and polkit rule this release ships must name the service, or a
    # future one shipped under another name would outlive a rollback.
    local f n=0
    for f in "${TM_REPO_ROOT}"/systemd/* "${TM_REPO_ROOT}"/install/polkit/*; do
        n=$((n + 1))
        grep -qF topic-manager "$f" || _tm_afail "$(basename "$f") does not name topic-manager: a rollback could not tell it is the product's"
    done
    [ "$n" -ge 12 ] || tm_die "only ${n} shipped unit/rule files found"
}
tm_case "every-shipped-unit-and-rule-names-the-service" none r_shipped_artefacts_name_the_service

# ─── the restore's verdict (gatekeeper round 5, c and d) ─────────────────────
_verdict() {   # _verdict <health-json> <state.env line or ''> [problem]
    local BD="${TM_TMP}/vbd"; rm -rf "$BD"; mkdir -p "$BD/manifest"
    [ -z "$2" ] || printf 'installed_at=x\n%s\n' "$2" > "$BD/manifest/state.env"
    printf '%s' "$1" > "${TM_TMP}/health"
    {
        echo 'set -uo pipefail'
        echo 'curl() { cat "'"${TM_TMP}"'/health"; }'
        echo 'success() { echo "[OK] $*"; }; warn() { echo "[WARN] $*"; }'
        echo 'RESTORE_PROBLEMS=()'
        [ -z "${3:-}" ] || printf 'RESTORE_PROBLEMS+=(%q)\n' "$3"
        tm_extract_func "$UP" restore_verdict
        echo 'restore_verdict "$1"'
    } > "${TM_TMP}/verdict.sh"
    RC=0; OUT="$(bash "${TM_TMP}/verdict.sh" "$BD" 2>&1)" || RC=$?
}
v_version_is_required() {
    _verdict '{"status":"ok","version":"1.1.0"}' 'topic_manager_version=1.1.0'
    tm_assert_rc 0 "$RC" "a healthy restore of the right version failed: ${OUT}"
    grep -q 'Restore complete — back on v1.1.0' <<<"$OUT" || _tm_afail "the success line does not name the version: ${OUT}"
    _verdict '{"status":"ok","version":"1.2.0"}' 'topic_manager_version=1.1.0'
    tm_assert_rc 1 "$RC" "GATEKEEPER R5 c: health said ok as 1.2.0 after a restore to 1.1.0, and the restore passed: ${OUT}"
    grep -q 'answers version 1.2.0, not the restored 1.1.0' <<<"$OUT" || _tm_afail "the wrong version is not named: ${OUT}"
    _verdict '{"status":"ok"}' 'topic_manager_version=1.1.0'
    tm_assert_rc 1 "$RC" "a health answer with no version passed as the restored release: ${OUT}"
    _verdict '{"status":"ok","version":"1.1.0"}' ''
    tm_assert_rc 1 "$RC" "a restore point that records no version passed unverified: ${OUT}"
    # Neither side knows the version: "" == "" must not read as a match.
    _verdict '{"status":"ok"}' ''
    tm_assert_rc 1 "$RC" "no recorded version and no reported version passed as a match: ${OUT}"
    _verdict '{"status":"ok","version":"unknown"}' 'topic_manager_version=unknown'
    tm_assert_rc 1 "$RC" "an UNKNOWN recorded version passed as a match: ${OUT}"
    grep -q 'does not record its version' <<<"$OUT" || _tm_afail "an unknown recorded version is not named: ${OUT}"
    _verdict '' 'topic_manager_version=1.1.0'
    tm_assert_rc 1 "$RC" "no health answer passed: ${OUT}"
    grep -q 'RESTORE INCOMPLETE' <<<"$OUT" || _tm_afail "a failed restore does not say RESTORE INCOMPLETE: ${OUT}"
}
tm_case "restore-verdict-requires-the-restored-version" linux v_version_is_required

v_problems_fail_the_verdict() {
    _verdict '{"status":"ok","version":"1.1.0"}' 'topic_manager_version=1.1.0' 'systemctl disable --now x.timer failed'
    tm_assert_rc 1 "$RC" "GATEKEEPER R5 d: a restore problem did not fail the verdict: ${OUT}"
    grep -q '  - systemctl disable --now x.timer failed' <<<"$OUT" || _tm_afail "the problem is not listed: ${OUT}"
    grep -q 'Restore complete' <<<"$OUT" && _tm_afail "a restore with a problem said complete: ${OUT}"
    true
}
tm_case "restore-verdict-fails-on-any-restore-problem" linux v_problems_fail_the_verdict

v_verdict_wired() {
    local rfb
    local -a L
    rfb="$(tm_extract_func "$UP" restore_from_backup)"
    mapfile -t L <<<"$rfb"
    grep -q '^    RETIRED_UNITS=(); RETIRED_RUNTIME=(); RESTORE_PROBLEMS=()$' <<<"$rfb" || _tm_afail "restore_from_backup does not start a fresh restore record"
    [ "${L[${#L[@]}-2]}" = '    restore_verdict "$BD"' ] || _tm_afail "restore_from_backup does not END with restore_verdict (its exit code)"
    grep -qF 'restore_from_backup "$RB" || fail "Restore did not complete cleanly' "$UP" || _tm_afail "--restore does not exit non-zero on a failed verdict"
}
tm_case "restore-from-backup-returns-the-verdict" none v_verdict_wired

r_wired() {
    local p4 rfb
    p4="$(tm_extract_between "$UP" '^backup_v120_managed "\$BACKUP_DIR"$' '^tar -czf "\$BACKUP_TAR"')"
    grep -q '^backup_owned_artefacts "\$BACKUP_DIR"$' <<<"$p4" || _tm_afail "Phase 4 does not record the host artefacts"
    local inv sums
    inv="$(grep -n '^backup_owned_artefacts "\$BACKUP_DIR"$' "$UP" | cut -d: -f1)"
    sums="$(grep -n '^( cd "\$BACKUP_DIR" && find . -type f ! -name SHA256SUMS' "$UP" | cut -d: -f1)"
    tm_assert_nonempty "$inv" "no inventory call"; tm_assert_nonempty "$sums" "no checksum anchor"
    [ "$inv" -lt "$sums" ] || _tm_afail "the inventory is taken after the restore point is checksummed"
    rfb="$(tm_extract_func "$UP" restore_from_backup)"
    grep -q '^    restore_owned_artefacts "\$BD"$' <<<"$rfb" \
        || _tm_afail "restore_from_backup (--restore and the automatic rollback) does not retire the newer release's units"
}
tm_case "phase4-records-and-every-restore-uses-the-inventory" none r_wired

tm_finish
