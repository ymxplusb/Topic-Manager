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
        echo 'systemctl() { echo "systemctl $*" >> "'"${TM_TMP}"'/calls"; }'
        echo 'info() { echo "[INFO] $*"; }; warn() { echo "[WARN] $*"; }'
        echo 'SERVICE=topic-manager'
        echo 'OWNED_UNIT_DIR="'"${R}"'/etc/systemd/system"'
        echo 'OWNED_POLKIT_DIR="'"${R}"'/etc/polkit-1/rules.d"'
        echo 'OWNED_LIBEXEC_DIR="'"${R}"'/usr/libexec/topic-manager"'
        tm_extract_func "$UP" socket_unit_paths
        tm_extract_func "$UP" retire_unit
        tm_extract_func "$UP" owned_inventory
        tm_extract_func "$UP" backup_owned_artefacts
        tm_extract_func "$UP" restore_owned_artefacts
        echo '"$1" "$2"'
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
}

# What the 1.2.0 upgrade lays over it — and one name no list in the script has.
_upgrade_120() {
    local R="$1" U="$1/etc/systemd/system" u
    mkdir -p "$U/timers.target.wants" "$U/paths.target.wants" "$U/sockets.target.wants" \
             "$R/usr/libexec/topic-manager/lib"
    printf '[Service]\nExecStart=gunicorn --bind unix:/run/x\n' > "$U/topic-manager.service"
    printf '[Service]\n# nginx-test v1.2\n' > "$U/topic-manager-nginx-test.service"
    for u in topic-manager-audit-prune.service topic-manager-apply-audit.service \
             topic-manager-apply-tls.service topic-manager-future-thing.service; do
        printf '[Service]\nExecStart=python3 -m tm.x\n' > "$U/$u"
    done
    printf '[Timer]\nOnCalendar=daily\n' > "$U/topic-manager-audit-prune.timer"
    printf '[Path]\nPathChanged=/run/x\n' > "$U/topic-manager-apply-audit.path"
    printf '[Timer]\nOnCalendar=hourly\n' > "$U/topic-manager-future-thing.timer"
    printf '[Socket]\nListenStream=%s\n' "$SOCK" > "$U/topic-manager.socket"
    ln -s ../topic-manager-audit-prune.timer "$U/timers.target.wants/topic-manager-audit-prune.timer"
    ln -s ../topic-manager-future-thing.timer "$U/timers.target.wants/topic-manager-future-thing.timer"
    ln -s ../topic-manager-apply-audit.path "$U/paths.target.wants/topic-manager-apply-audit.path"
    ln -s ../topic-manager.socket "$U/sockets.target.wants/topic-manager.socket"
    printf '#!/usr/bin/python3\n' > "$R/usr/libexec/topic-manager/tm-apply"
    printf 'RULES = 1\n' > "$R/usr/libexec/topic-manager/lib/settings_schema.py"
    printf '// polkit v1.2: restart + four apply units\n' > "$R/etc/polkit-1/rules.d/50-topic-manager.rules"
    printf '// polkit v1.2: a second rule file\n' > "$R/etc/polkit-1/rules.d/51-topic-manager-apply.rules"
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
    _prog "$R" restore_owned_artefacts "$BD"
    tm_assert_rc 0 "$RC" "restore_owned_artefacts failed: $(cat "${TM_TMP}/out")"

    # Every unit the newer release added is disabled and stopped, and GONE.
    for u in topic-manager-audit-prune.timer topic-manager-apply-audit.path topic-manager-audit-prune.service \
             topic-manager-apply-audit.service topic-manager-apply-tls.service topic-manager.socket \
             topic-manager-future-thing.timer topic-manager-future-thing.service; do
        grep -qx "systemctl disable --now ${u}" "${TM_TMP}/calls" \
            || { rm -rf "$SOCKD"; _tm_afail "CLEAN-ROOM R1: ${u} was not disabled --now on the rollback: $(tr '\n' ';' < "${TM_TMP}/calls")"; }
        [ -e "$U/$u" ] && { rm -rf "$SOCKD"; _tm_afail "CLEAN-ROOM R1: ${u} survived a rollback to a release without it"; }
    done
    local left
    left="$(find "$U" -path '*.wants/*' -name 'topic-manager*' ! -name topic-manager.service)"
    [ -z "$left" ] || { rm -rf "$SOCKD"; _tm_afail "an enablement link of a retired unit survived: ${left}"; }
    [ -e "$SOCK" ] && { rm -rf "$SOCKD"; _tm_afail "CLEAN-ROOM R2: the retired socket unit left its socket file"; }
    rm -rf "$SOCKD"
    tm_assert_nofile "$R/usr/libexec/topic-manager" "the root helper tree the newer release added survived"
    tm_assert_nofile "$R/etc/polkit-1/rules.d/51-topic-manager-apply.rules" "a polkit rule the newer release added survived"

    # What was there comes back byte-exact, enablement included.
    tm_assert_grep "polkit v1.1: restart only" "$R/etc/polkit-1/rules.d/50-topic-manager.rules" \
        "the polkit rule still grants the newer release's units"
    tm_assert_grep "nginx-test v1.1" "$U/topic-manager-nginx-test.service" "a unit the old release shipped was not put back"
    tm_assert_grep "127.0.0.1:5001" "$U/topic-manager.service" "the service unit was not put back"
    [ -L "$U/multi-user.target.wants/topic-manager.service" ] || _tm_afail "the service lost its enablement link"
    grep -qx 'systemctl disable --now topic-manager.service' "${TM_TMP}/calls" \
        && _tm_afail "a unit the restored release ships was disabled"
    grep -q 'topic-manager-nginx-test' "${TM_TMP}/calls" && _tm_afail "a unit the restored release ships was retired"

    # Out of scope for this function: another product's unit, and the drop-in
    # (restore_dropin owns it).
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
