#!/usr/bin/env bash
# =============================================================================
# t45 — A ROLLBACK RETIRES WHAT THE NEWER RELEASE ADDED TO THE HOST, AND
# NOTHING THAT IS NOT THE PRODUCT'S (clean-room 2026-09-29 R1; gatekeeper
# round 6 B1, N2, N3).
#
# `upgrade-full.sh --restore` to a 1.1.x restore point left
# topic-manager-audit-prune.timer and topic-manager-apply-audit.path ENABLED
# (R1). Round 6 fixed that by judging a file the product's when its TEXT named
# topic-manager — and a rollback then stopped, disabled and deleted another
# tool's site-backup.service (its ExecStart backs up /opt/topic-manager) and
# silently deleted an operator's nginx.service.d/50-limits.conf that named the
# product in a comment (B1).
#
# Ownership is now a POSITIVE RECORD: install.sh and the upgrade write
# /var/lib/topic-manager/installed-files.manifest (sha256 per file) of every
# host artefact they lay down, from the same lists and source tree they
# install from. A restore retires only what the host's manifest names and the
# restore point's does not, puts back only what the restore point's names, and
# leaves everything else exactly as it is, listing what changed.
#
#   * the round trip through the REAL functions on a fake root: a 1.1.1 host
#     (no manifest: its shipped list, derived), the 1.2.0 upgrade and its
#     manifest, another tool's units and an operator's drop-ins, the rollback;
#   * the exporter pair (N2): the product's by record goes, timer too; the
#     same names NOT in the record stay, running and enabled;
#   * a product file edited since it was installed is kept aside, not lost;
#   * an interrupted upgrade (.pending only) is still retired by record;
#   * a restore point with no manifest: v1.1.x by its shipped list; any other
#     version retires NOTHING and is RESTORE INCOMPLETE with the list (N3);
#   * the manifest is written from host_artefacts, which reads the tree the
#     release installs from; both scripts carry one identical copy;
#   * the v1.1.x list is re-derived from the v1.1.0 and v1.1.1 TAGS, and this
#     tree's install/cp/ln destinations are held to the manifest lists.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "a rollback retires what the newer release installed, by record, and nothing else"

UP="$(tm_upgrade_sh)"
INSTALL_SH="$(tm_install_sh)"

# The shared block and the v1.1.x list, as the script has them.
_block() {   # _block <file>
    tm_extract_between "$1" "^# >>> the product's host artefacts" "^# <<< the product's host artefacts$"
}

# _prog <fakeroot> <verb> <args...> — the real functions, every literal host
# path relocated under <fakeroot>.
_prog() {
    local R="$1"; shift
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        # T_FAIL_UNIT: the one unit whose `systemctl disable` fails, as it
        # would where systemd refuses (gatekeeper round 5, d).
        echo 'systemctl() { echo "systemctl $*" >> "'"${TM_TMP}"'/calls"'
        echo '    if [[ "$1" == disable && " $* " == *" ${T_FAIL_UNIT:-none} "* ]]; then echo "Failed to disable unit: Access denied" >&2; return 1; fi; }'
        echo 'info() { echo "[INFO] $*"; }; warn() { echo "[WARN] $*"; }; fail() { echo "[FAIL] $*"; exit 1; }'
        echo 'safe_install_dir() { mkdir -p -- "$4"; chmod "$1" -- "$4"; }'
        echo 'SERVICE=topic-manager'
        {
            _block "${BLOCK_SRC:-$UP}"
            tm_extract_between "$UP" '^LEGACY_V11X_VERSIONS=' '^[[:space:]]+"file /etc/logrotate.d/topic-manager"\)$'
        } | sed -e "s#/etc/#${R}/etc/#g" -e "s#/usr/libexec/#${R}/usr/libexec/#g" -e "s#/var/lib/topic-manager/#${R}/var/lib/topic-manager/#g"
        echo 'DROPIN_DIR="'"${R}"'/etc/systemd/system/topic-manager.service.d"'
        echo 'OWNED_RUNTIME_DIR="'"${R}"'/run"'
        echo 'TIMER_STAMP_DIR="'"${R}"'/var/lib/systemd/timers"'
        echo 'SET_ASIDE_DIR="'"${R}"'/var/backups/topic-manager/set-aside-T"'
        echo 'RETIRED_UNITS=(); RETIRED_RUNTIME=(); RESTORE_PROBLEMS=(); SET_ASIDE=()'
        local f
        for f in socket_unit_paths unit_runtime_dirs retire_unit remove_retired_runtime location_inventory \
                 legacy_artefacts same_artefact backup_owned_artefacts restore_point_copy set_aside_if_changed \
                 restore_owned_artefacts restore_socket_unit; do
            tm_extract_func "$UP" "$f" | sed -e "s#/etc/#${R}/etc/#g"
        done
        # install_apply_helper as the script under test has it (install(1)
        # without -o/-g, which only root may pass).
        echo 'install() { local a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done; command install "${a[@]}"; }'
        tm_extract_func "${BLOCK_SRC:-$UP}" install_apply_helper
        # As restore_from_backup orders them: the socket unit first.
        echo 'rollback() { restore_socket_unit "$1"; restore_owned_artefacts "$1"; }'
        echo '"$@"'
        echo 'for _p in "${RESTORE_PROBLEMS[@]}"; do echo "PROBLEM|${_p}"; done'
    } > "${TM_TMP}/prog.sh"
    local esc
    esc="$(grep -v "${R}" "${TM_TMP}/prog.sh" | grep -v '^[[:space:]]*#' | grep -E '(^|[^/A-Za-z0-9_.-])/(etc|usr/libexec|var/lib)/' || true)"
    [ -z "$esc" ] || tm_die "a host path escaped the fake root: $(sed -n 1,3p <<<"$esc")"
    RC=0; bash "${TM_TMP}/prog.sh" "$@" >> "${TM_TMP}/out" 2>&1 || RC=$?
}

_unit() { printf '%s\n' "$2" > "$1"; }

# The host as v1.1.1 left it — and other tools that were there before the upgrade.
_host_111() {
    local R="$1" U="$1/etc/systemd/system"
    mkdir -p "$U/multi-user.target.wants" "$R/etc/polkit-1/rules.d" "$R/etc/nginx/sites-available" \
             "$R/etc/nginx/sites-enabled" "$R/etc/nginx/snippets" "$R/etc/logrotate.d"
    printf '[Service]\nExecStart=gunicorn --bind 127.0.0.1:5001\n[Install]\nWantedBy=multi-user.target\n' > "$U/topic-manager.service"
    printf '[Service]\n# nginx-test v1.1\n' > "$U/topic-manager-nginx-test.service"
    ln -s "$U/topic-manager.service" "$U/multi-user.target.wants/topic-manager.service"
    printf '// polkit v1.1: restart only\n' > "$R/etc/polkit-1/rules.d/50-topic-manager.rules"
    printf 'server { # v1.1 site }\n' > "$R/etc/nginx/sites-available/topic-manager"
    ln -s "$R/etc/nginx/sites-available/topic-manager" "$R/etc/nginx/sites-enabled/topic-manager"
    printf '# headers v1.1\n' > "$R/etc/nginx/snippets/tm-security-headers.conf"
    printf '/opt/topic-manager/logs/*.log { daily }\n' > "$R/etc/logrotate.d/topic-manager"
    printf '[Service]\n# someone else\n' > "$U/other.service"
    # Another tool's alias, re-pointed later at a unit with the SAME bytes:
    # only the link target says it changed.
    printf '[Service]\n# a or b\n' > "$U/other-a.service"; cp "$U/other-a.service" "$U/other-b.service"
    ln -s "$U/other-a.service" "$U/alias.service"
    # An operator's override of a package unit, there before the upgrade.
    mkdir -p "$U/nginx.service.d"
    printf '[Service]\nLimitNOFILE=65536\n' > "$U/nginx.service.d/override.conf"
    printf '// another package\n' > "$R/etc/polkit-1/rules.d/49-other.rules"
    # Another timer's persistent stamp.
    mkdir -p "$R/var/lib/systemd/timers"; : > "$R/var/lib/systemd/timers/stamp-apt-daily.timer"
}

# The source tree of the NEWER release: what it installs, and so what its
# manifest records. <with-exporter: yes|no> — a product exporter pair (N2).
_src_120() {
    local S="$1" u
    rm -rf "$S"; mkdir -p "$S/systemd" "$S/install/polkit" "$S/install/libexec" "$S/tm"
    echo 1.2.0 > "$S/VERSION"
    printf '[Service]\nExecStart=gunicorn --bind unix:/run/x\n[Install]\nWantedBy=multi-user.target\n' > "$S/systemd/topic-manager.service"
    printf '[Socket]\nListenStream=%s\n[Install]\nWantedBy=sockets.target\n' "$SOCK" > "$S/systemd/topic-manager.socket"
    printf '[Service]\n# nginx-test v1.2\n' > "$S/systemd/topic-manager-nginx-test.service"
    for u in topic-manager-audit-prune.service topic-manager-apply-audit.service; do
        printf '[Service]\nExecStart=python3 -m tm.x\n' > "$S/systemd/$u"
    done
    printf '[Service]\nExecStart=python3 -m tm.x\n[Install]\nRequiredBy=multi-user.target\n' > "$S/systemd/topic-manager-future-thing.service"
    # An apply unit keeps its runtime directory after it stops
    # (RuntimeDirectoryPreserve=yes) and leaves its verdict there (clean-room N5).
    printf '[Service]\nRuntimeDirectory=topic-manager-apply\nRuntimeDirectoryPreserve=yes\nExecStart=/usr/libexec/topic-manager/tm-apply tls\n' \
        > "$S/systemd/topic-manager-apply-tls.service"
    printf '[Timer]\nOnCalendar=daily\n[Install]\nWantedBy=timers.target\n' > "$S/systemd/topic-manager-audit-prune.timer"
    printf '[Path]\nPathChanged=/run/x\n[Install]\nWantedBy=paths.target\n' > "$S/systemd/topic-manager-apply-audit.path"
    printf '[Timer]\nOnCalendar=hourly\n[Install]\nWantedBy=timers.target\n' > "$S/systemd/topic-manager-future-thing.timer"
    # A product unit NOT named topic-manager*: the record makes it the product's.
    printf '[Service]\nExecStart=/usr/libexec/topic-manager/tm-future\n[Install]\nWantedBy=multi-user.target\n' > "$S/systemd/tm-future.service"
    if [ "$2" = yes ]; then
        printf '[Service]\nExecStart=/usr/libexec/topic-manager/tm-export\n' > "$S/systemd/tm-exporter.service"
        printf '[Timer]\nUnit=tm-exporter.service\nOnCalendar=minutely\n[Install]\nWantedBy=timers.target\n' > "$S/systemd/tm-exporter.timer"
    fi
    printf '// polkit v1.2: restart + four apply units\n' > "$S/install/polkit/50-topic-manager.rules"
    printf '// polkit v1.2: a second rule file\n' > "$S/install/polkit/51-topic-manager-apply.rules"
    printf 'if (subject.user === "tm") {}\n' > "$S/install/polkit/60-tm-apply.rules"
    printf '#!/usr/bin/python3\n' > "$S/install/libexec/tm-apply"
    printf 'RULES = 1\n' > "$S/tm/settings_schema.py"
    printf 'TLS = 1\n' > "$S/tm/tls_check.py"
}

# What the 1.2.0 upgrade lays over the host (from _src_120), and its manifest
# written by the REAL write_install_manifest.
_upgrade_120() {
    local R="$1" S="$2" U="$1/etc/systemd/system" f u t
    mkdir -p "$R/usr/libexec/topic-manager/lib/__pycache__"
    for f in "$S"/systemd/*; do
        u="${f##*/}"; cp "$f" "$U/$u"
        for t in $(sed -n 's/^WantedBy=//p' "$f"); do
            mkdir -p "$U/${t}.wants"; ln -sfn "$U/$u" "$U/${t}.wants/$u"
        done
        for t in $(sed -n 's/^RequiredBy=//p' "$f"); do
            mkdir -p "$U/${t}.requires"; ln -sfn "$U/$u" "$U/${t}.requires/$u"
        done
    done
    # Operator state the Settings apply renders (restore_v120_managed's).
    mkdir -p "$R/etc/nginx/conf.d"; printf 'limit_req_zone x;\n' > "$R/etc/nginx/conf.d/topic-manager-limits.conf"
    for f in "$S"/install/polkit/*; do cp "$f" "$R/etc/polkit-1/rules.d/"; done
    cp "$S/install/libexec/tm-apply" "$R/usr/libexec/topic-manager/tm-apply"
    cp "$S/tm/settings_schema.py" "$S/tm/tls_check.py" "$R/usr/libexec/topic-manager/lib/"
    printf 'server { # v1.2 site }\n' > "$R/etc/nginx/sites-available/topic-manager"
    printf '# headers v1.2\n' > "$R/etc/nginx/snippets/tm-security-headers.conf"
    mkdir -p "$R/run/topic-manager-apply"; printf '{"state":"applied"}\n' > "$R/run/topic-manager-apply/tls.result"
    # The timers ran: systemd keeps a persistent timer's stamp after the unit
    # is gone (clean-room round 6, M2). The service's has no stamp; the
    # check below proves a stamp is looked for only for a TIMER.
    mkdir -p "$R/var/lib/systemd/timers"
    : > "$R/var/lib/systemd/timers/stamp-topic-manager-audit-prune.timer"
    : > "$R/var/lib/systemd/timers/stamp-topic-manager-future-thing.timer"
    _prog "$R" write_install_manifest "$S"
    tm_assert_rc 0 "$RC" "write_install_manifest failed: $(cat "${TM_TMP}/out")"
    # The helper ran once as root: Python wrote bytecode beside its module.
    printf 'pyc' > "$R/usr/libexec/topic-manager/lib/__pycache__/settings_schema.cpython-312.pyc"
}

# Other tools and the operator, AFTER the upgrade (none of it in any manifest).
_others_after() {
    local R="$1" U="$1/etc/systemd/system"
    # THE GATEKEEPER'S FIXTURES (round 6, B1). Another tool's backup unit that
    # backs up the product's tree, enabled; and an operator's nginx drop-in
    # that names the product only in a comment.
    printf '[Service]\nExecStart=/usr/local/bin/backup /opt/topic-manager /var/backups/site\n[Install]\nWantedBy=multi-user.target\n' > "$U/site-backup.service"
    ln -s "$U/site-backup.service" "$U/multi-user.target.wants/site-backup.service"
    printf '[Service]\n# raised for topic-manager uploads\nLimitNOFILE=131072\n' > "$U/nginx.service.d/50-limits.conf"
    # A snap refresh writes a mount unit and its enablement link.
    printf '[Mount]\nWhat=/var/lib/snapd/snaps/core22_1234.snap\n' > "$U/snap-core22-1234.mount"
    ln -s "$U/snap-core22-1234.mount" "$U/multi-user.target.wants/snap-core22-1234.mount"
    # An operator's drop-in for a unit the rollback retires, and a link of
    # the operator's to a product unit: not the product's by any record.
    mkdir -p "$U/tm-future.service.d" "$U/graphical.target.wants"
    printf '[Service]\nMemoryMax=1G\n' > "$U/tm-future.service.d/10-limits.conf"
    ln -s "$U/topic-manager.service" "$U/graphical.target.wants/topic-manager.service"
    # Another tool changed its own unit, re-pointed its alias, and the
    # operator removed an override.
    printf '[Service]\n# someone else, changed later\n' > "$U/other.service"
    ln -sfn "$U/other-b.service" "$U/alias.service"
    rm -f "$U/nginx.service.d/override.conf"
    # The operator's drop-in (secrets): restore_dropin owns it.
    mkdir -p "$U/topic-manager.service.d"
    printf '[Service]\n# changed by the upgrade\n' > "$U/topic-manager.service.d/override.conf"
}

# A foreign exporter pair: the same names as the product one, NOT in the record.
_foreign_exporter() {
    local U="$1/etc/systemd/system"
    printf '[Service]\nExecStart=/usr/local/bin/node-exporter-textfile /opt/topic-manager\n' > "$U/tm-exporter.service"
    printf '[Timer]\nUnit=tm-exporter.service\nOnCalendar=minutely\n[Install]\nWantedBy=timers.target\n' > "$U/tm-exporter.timer"
    mkdir -p "$U/timers.target.wants"; ln -s "$U/tm-exporter.timer" "$U/timers.target.wants/tm-exporter.timer"
    : > "$1/var/lib/systemd/timers/stamp-tm-exporter.timer"
}

_foreign_paths() {   # the gatekeeper's foreign artefacts, relative to the root
    echo etc/systemd/system/site-backup.service etc/systemd/system/multi-user.target.wants/site-backup.service \
         etc/systemd/system/nginx.service.d etc/systemd/system/snap-core22-1234.mount \
         etc/systemd/system/multi-user.target.wants/snap-core22-1234.mount etc/systemd/system/other.service \
         etc/systemd/system/tm-future.service.d etc/systemd/system/graphical.target.wants \
         etc/polkit-1/rules.d/49-other.rules etc/systemd/system/topic-manager.service.d \
         etc/systemd/system/alias.service etc/systemd/system/other-a.service etc/systemd/system/other-b.service "$@"
}
_snapshot() {   # _snapshot <root> <paths...> — every byte, link target and mode
    local R="$1"; shift
    ( cd "$R" && find "$@" \( -type l -printf 'L %p -> %l\n' \) -o \( -type f -printf 'F %p %m ' -exec sha256sum {} \; \) -o \( -type d -printf 'D %p %m\n' \) | sort )
}

_mksock() {
    SOCKD="$(mktemp -d /tmp/tms.XXXXXX)"; SOCK="${SOCKD}/gunicorn.sock"
    "$(tm_python)" -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCK" \
        || tm_die "could not create a Unix socket at ${SOCK}"
}

# _setup [exporter: product|foreign|none] — 1.1.1 host, its restore point,
# the 1.2.0 upgrade with its manifest, other tools after.
_setup() {
    R="${TM_TMP}/root"; BD="${TM_TMP}/bd"; U="${R}/etc/systemd/system"; S="${TM_TMP}/src120"
    mkdir -p "$BD/manifest" "$BD/system"; : > "${TM_TMP}/calls"; : > "${TM_TMP}/out"
    printf 'topic_manager_version=1.1.1\n' > "$BD/manifest/state.env"
    _mksock
    _host_111 "$R"
    _prog "$R" backup_owned_artefacts "$BD" 1.1.1
    tm_assert_rc 0 "$RC" "backup_owned_artefacts failed: $(cat "${TM_TMP}/out")"
    _src_120 "$S" "$([ "${1:-none}" = product ] && echo yes || echo no)"
    _upgrade_120 "$R" "$S"
    _others_after "$R"
    [ "${1:-none}" = foreign ] && _foreign_exporter "$R"
    : > "${TM_TMP}/calls"
}

r_round_trip() {
    local u
    _setup none
    tm_assert_grep "# derived: v1.1.1" "$BD/manifest/installed-files.manifest" "a 1.1.1 host's restore point carries no record of what 1.1.1 shipped"
    local dup; dup="$(grep -v '^#' "$R/var/lib/topic-manager/installed-files.manifest" | cut -d' ' -f2- | sort | uniq -d)"
    [ -z "$dup" ] || _tm_afail "the manifest records a path twice: ${dup}"
    # A recorded file already gone before the rollback: nothing to retire.
    rm -f "$R/usr/libexec/topic-manager/lib/tls_check.py"
    local before after
    before="$(_snapshot "$R" $(_foreign_paths))"
    _prog "$R" rollback "$BD"
    tm_assert_rc 0 "$RC" "the rollback failed: $(cat "${TM_TMP}/out")"
    grep -q '^PROBLEM|' "${TM_TMP}/out" && { rm -rf "$SOCKD"; _tm_afail "a clean rollback reported problems: $(grep '^PROBLEM|' "${TM_TMP}/out")"; }

    # GATEKEEPER ROUND 6 B1: nothing that is not the product's by record was
    # stopped, disabled, deleted or changed — byte-identical, links and modes.
    after="$(_snapshot "$R" $(_foreign_paths))"
    [ "$before" = "$after" ] || { rm -rf "$SOCKD"; _tm_afail "GATEKEEPER R6 B1: a rollback changed what is not the product's: $(diff <(echo "$before") <(echo "$after") | head -8)"; }
    grep -Eq 'site-backup|snap-core22|nginx\.service|other\.service' "${TM_TMP}/calls" \
        && { rm -rf "$SOCKD"; _tm_afail "GATEKEEPER R6 B1: a rollback ran systemctl on a unit that is not the product's: $(tr '\n' ';' < "${TM_TMP}/calls")"; }
    # ... and each is NAMED (the 50-limits.conf deletion was not even listed).
    for u in "nginx.service.d/50-limits.conf (added since the restore point)" \
             "site-backup.service (added since the restore point)" \
             "snap-core22-1234.mount (added since the restore point)" \
             "other.service (changed since the restore point)" \
             "tm-future.service.d/10-limits.conf (added since the restore point)" \
             "tm-future.service.d (added since the restore point)" \
             "alias.service (changed since the restore point)" \
             "nginx.service.d/override.conf (removed since the restore point)" \
             "graphical.target.wants/topic-manager.service (added since the restore point)"; do
        tm_assert_grep "$u" "${TM_TMP}/out" "a change that is not the product's is not listed"
    done
    tm_assert_nogrep "topic-manager.service.d" "${TM_TMP}/out" "the service's drop-in (restore_dropin's) was judged here"
    tm_assert_nogrep "topic-manager-nginx-test.service (" "${TM_TMP}/out" "a product unit was listed as not the product's"
    # Operator state is restore_v120_managed's, never this function's.
    tm_assert_grep "limit_req_zone x;" "$R/etc/nginx/conf.d/topic-manager-limits.conf" "operator state was removed by the unit rollback"

    # Every unit the newer release's manifest records, and the restore point's
    # does not, is disabled and stopped, and GONE — tm-future.service too.
    for u in topic-manager-audit-prune.timer topic-manager-apply-audit.path topic-manager-audit-prune.service \
             topic-manager-apply-audit.service topic-manager-apply-tls.service topic-manager.socket \
             topic-manager-future-thing.timer topic-manager-future-thing.service tm-future.service; do
        grep -qx "systemctl disable --now ${u}" "${TM_TMP}/calls" \
            || { rm -rf "$SOCKD"; _tm_afail "CLEAN-ROOM R1: ${u} was not disabled --now on the rollback: $(tr '\n' ';' < "${TM_TMP}/calls")"; }
        [ -e "$U/$u" ] && { rm -rf "$SOCKD"; _tm_afail "CLEAN-ROOM R1: ${u} survived a rollback to a release without it"; }
    done
    for u in timers.target.wants/topic-manager-audit-prune.timer paths.target.wants/topic-manager-apply-audit.path \
             sockets.target.wants/topic-manager.socket timers.target.wants/topic-manager-future-thing.timer \
             multi-user.target.wants/tm-future.service multi-user.target.requires/topic-manager-future-thing.service; do
        [ -L "$U/$u" ] && { rm -rf "$SOCKD"; _tm_afail "a recorded enablement link of a retired unit survived: ${u}"; }
    done
    [ -e "$SOCK" ] && { rm -rf "$SOCKD"; _tm_afail "CLEAN-ROOM R2: the retired socket unit left its socket file"; }
    [ -d "$SOCKD" ] && { rm -rf "$SOCKD"; _tm_afail "the emptied socket directory was left behind"; }
    rm -rf "$SOCKD"
    tm_assert_nofile "$R/run/topic-manager-apply" "CLEAN-ROOM N5: the retired units' runtime directory (1.2.0 result files) survived"
    tm_assert_nofile "$R/var/lib/systemd/timers/stamp-topic-manager-audit-prune.timer" "CLEAN-ROOM M2: a retired timer's stamp survived the rollback"
    tm_assert_nofile "$R/var/lib/systemd/timers/stamp-topic-manager-future-thing.timer" "CLEAN-ROOM M2: a retired timer's stamp survived the rollback"
    tm_assert_file "$R/var/lib/systemd/timers/stamp-apt-daily.timer" "another timer's stamp was removed"
    local listed counted
    listed="$(grep -c '^\[INFO\] Retired ' "${TM_TMP}/out")"
    counted="$(sed -n "s/.*restore point's manifest (\([0-9]*\) unit(s) retired.*/\1/p" "${TM_TMP}/out")"
    tm_assert_eq 9 "$listed" "not every recorded unit was retired"
    tm_assert_eq "$listed" "$counted" "CLEAN-ROOM N5: the summary counts ${counted} unit(s) retired after listing ${listed}"
    tm_assert_nofile "$R/usr/libexec/topic-manager" "the root helper tree (and its bytecode) the newer release added survived"
    tm_assert_nofile "$R/etc/polkit-1/rules.d/51-topic-manager-apply.rules" "a polkit rule the newer release added survived"
    tm_assert_nofile "$R/etc/polkit-1/rules.d/60-tm-apply.rules" "a recorded polkit rule under another name survived"

    # What 1.1.1 shipped comes back byte-exact, enablement included.
    tm_assert_grep "polkit v1.1: restart only" "$R/etc/polkit-1/rules.d/50-topic-manager.rules" "the polkit rule still grants the newer release's units"
    tm_assert_grep "nginx-test v1.1" "$U/topic-manager-nginx-test.service" "a unit the old release shipped was not put back"
    tm_assert_grep "127.0.0.1:5001" "$U/topic-manager.service" "the service unit was not put back"
    tm_assert_grep "v1.1 site" "$R/etc/nginx/sites-available/topic-manager" "the nginx site was not put back"
    tm_assert_grep "headers v1.1" "$R/etc/nginx/snippets/tm-security-headers.conf" "the header snippet was not put back"
    [ -L "$U/multi-user.target.wants/topic-manager.service" ] || _tm_afail "the service lost its enablement link"
    grep -qx 'systemctl disable --now topic-manager.service' "${TM_TMP}/calls" && _tm_afail "a unit the restored release ships was disabled"
    grep -q 'topic-manager-nginx-test' "${TM_TMP}/calls" && _tm_afail "a unit the restored release ships was retired"
    # The host's record is the restore point's: 1.1.1 kept none.
    tm_assert_nofile "$R/var/lib/topic-manager/installed-files.manifest" "the newer release's manifest outlived the rollback"
    # systemd reloads AFTER the last removal.
    local last_disable reload
    last_disable="$(grep -n 'disable --now' "${TM_TMP}/calls" | tail -1 | cut -d: -f1)"
    reload="$(grep -nx 'systemctl daemon-reload' "${TM_TMP}/calls" | tail -1 | cut -d: -f1)"
    tm_assert_nonempty "$reload" "no daemon-reload after the units were removed"
    [ "$reload" -gt "$last_disable" ] || _tm_afail "daemon-reload ran before the units were retired"
}
tm_case "rollback-retires-by-record-and-leaves-every-foreign-artefact-byte-identical" linux,symlinks r_round_trip

r_exporter_by_record() {
    # N2: the product's exporter pair is retired, the TIMER too (it names only
    # its service); the same names installed by another tool are not touched.
    _setup product
    _prog "$R" rollback "$BD"
    rm -rf "$SOCKD"
    tm_assert_rc 0 "$RC" "the rollback failed: $(cat "${TM_TMP}/out")"
    local u
    for u in tm-exporter.service tm-exporter.timer; do
        grep -qx "systemctl disable --now ${u}" "${TM_TMP}/calls" || _tm_afail "GATEKEEPER R6 N2: the product's ${u} was not retired"
        tm_assert_nofile "$U/$u" "GATEKEEPER R6 N2: the product's ${u} survived a rollback"
    done
    [ -L "$U/timers.target.wants/tm-exporter.timer" ] && _tm_afail "the product exporter timer's recorded link survived"

    rm -rf "${TM_TMP:?}"/root "${TM_TMP:?}"/bd; : > "${TM_TMP}/out"
    _setup foreign
    local before after
    before="$(_snapshot "$R" etc/systemd/system/tm-exporter.service etc/systemd/system/tm-exporter.timer etc/systemd/system/timers.target.wants/tm-exporter.timer)"
    _prog "$R" rollback "$BD"
    rm -rf "$SOCKD"
    after="$(_snapshot "$R" etc/systemd/system/tm-exporter.service etc/systemd/system/tm-exporter.timer etc/systemd/system/timers.target.wants/tm-exporter.timer)"
    tm_assert_eq "$before" "$after" "GATEKEEPER R6 B1: an exporter pair NOT in the manifest was changed"
    tm_assert_file "$R/var/lib/systemd/timers/stamp-tm-exporter.timer" "the stamp of a timer that is not the product's was removed"
    grep -q 'tm-exporter' "${TM_TMP}/calls" && _tm_afail "GATEKEEPER R6 B1: systemctl was run on an exporter that is not the product's"
    tm_assert_grep "tm-exporter.timer (added since the restore point)" "${TM_TMP}/out" "the foreign exporter is not listed"
    true
}
tm_case "an-exporter-pair-goes-only-when-the-manifest-records-it" linux,symlinks r_exporter_by_record

r_modified_is_set_aside() {
    # A recorded product file changed since it was installed: retired, but a
    # byte-exact copy is kept and named — never deleted unseen.
    _setup none
    # A stale pending record beside the finished manifest: the recorded hash wins.
    _prog "$R" write_install_manifest "$S" pending
    # Someone else's files inside the product's helper directory.
    mkdir -p "$R/usr/libexec/topic-manager/local"; printf 'mine\n' > "$R/usr/libexec/topic-manager/local/notes.txt"
    printf '[Service]\nExecStart=python3 -m tm.x\n# operator: tuned\n[Install]\nRequiredBy=multi-user.target\n' > "$U/topic-manager-future-thing.service"
    printf '# edited helper\n' >> "$R/usr/libexec/topic-manager/tm-apply"
    local want1 want2
    want1="$(sha256sum < "$U/topic-manager-future-thing.service")"
    want2="$(sha256sum < "$R/usr/libexec/topic-manager/tm-apply")"
    _prog "$R" rollback "$BD"
    rm -rf "$SOCKD"
    tm_assert_rc 0 "$RC" "the rollback failed: $(cat "${TM_TMP}/out")"
    local A="$R/var/backups/topic-manager/set-aside-T"
    tm_assert_file "$A$U/topic-manager-future-thing.service" "GATEKEEPER R6: an edited product unit was deleted without a copy"
    tm_assert_eq "$want1" "$(sha256sum < "$A$U/topic-manager-future-thing.service")" "the kept copy is not the edited file"
    tm_assert_eq "$want2" "$(sha256sum < "$A$R/usr/libexec/topic-manager/tm-apply")" "the edited helper was not kept"
    tm_assert_grep "topic-manager-future-thing.service (changed since it was installed)" "${TM_TMP}/out" "the kept copy is not named"
    tm_assert_mode 700 "$A" "the set-aside directory is not private"
    # Unedited ones are not set aside.
    tm_assert_nofile "$A$U/topic-manager-audit-prune.timer" "an unedited product file was set aside"
    # A product directory holding someone else's files is left, and said so once.
    tm_assert_file "$R/usr/libexec/topic-manager/local/notes.txt" "a file no manifest records was deleted with the product's directory"
    tm_assert_grep "$R/usr/libexec/topic-manager/ (the newer release's directory, left" "${TM_TMP}/out" "a product directory left behind is not named"
    tm_assert_grep "$R/usr/libexec/topic-manager/local (added since the restore point)" "${TM_TMP}/out" "a foreign directory in the helper tree is not listed"
    tm_assert_grep "$R/usr/libexec/topic-manager/local/notes.txt (added since the restore point)" "${TM_TMP}/out" "a foreign file in the helper tree is not listed"
    tm_assert_nogrep "$R/usr/libexec/topic-manager (added since" "${TM_TMP}/out" "the product's own directory is listed as another tool's"
}
tm_case "an-edited-product-file-is-kept-aside-not-deleted" linux,symlinks,modes r_modified_is_set_aside

r_pending_only() {
    # An upgrade that failed before its manifest was written: the .pending
    # record still names what it was installing, so the rollback retires it —
    # and, no hash having been recorded, keeps a copy of each.
    _setup none
    mv "$R/var/lib/topic-manager/installed-files.manifest" "${TM_TMP}/final.manifest"
    _prog "$R" write_install_manifest "$S" pending
    tm_assert_file "$R/var/lib/topic-manager/installed-files.manifest.pending" "no pending record written"
    tm_assert_grep "pending $U/tm-future.service" "$R/var/lib/topic-manager/installed-files.manifest.pending" "pending does not record a file the release installs"
    : > "${TM_TMP}/calls"
    _prog "$R" rollback "$BD"
    rm -rf "$SOCKD"
    tm_assert_rc 0 "$RC" "the rollback failed: $(cat "${TM_TMP}/out")"
    grep -qx "systemctl disable --now topic-manager-audit-prune.timer" "${TM_TMP}/calls" \
        || _tm_afail "an interrupted upgrade's units were not retired by its pending record"
    tm_assert_file "$R/var/backups/topic-manager/set-aside-T$U/tm-future.service" "an unrecorded-hash file was deleted without a copy"
    tm_assert_grep "did not finish" "${TM_TMP}/out" "the reason for the kept copy is not given"
    tm_assert_nofile "$R/var/lib/topic-manager/installed-files.manifest.pending" "the pending record outlived the rollback"
    tm_assert_file "$U/site-backup.service" "a foreign unit was removed"
}
tm_case "an-interrupted-upgrade-is-retired-by-its-pending-record" linux,symlinks r_pending_only

r_unknown_version_retires_nothing() {
    # N3: a restore point with no manifest, of a release this script carries
    # no shipped list for, retires NOTHING and fails the verdict with the list.
    _setup none
    rm -f "$BD/manifest/installed-files.manifest"
    printf 'topic_manager_version=1.0.11\n' > "$BD/manifest/state.env"
    rm -f "$U/topic-manager-apply-tls.service"      # recorded, already gone
    _prog "$R" rollback "$BD"
    rm -rf "$SOCKD"
    tm_assert_rc 0 "$RC" "the restore step itself failed: $(cat "${TM_TMP}/out")"
    grep -q 'disable' "${TM_TMP}/calls" && _tm_afail "GATEKEEPER R6 N3: an unknown restore point retired units: $(cat "${TM_TMP}/calls")"
    tm_assert_file "$U/topic-manager-audit-prune.timer" "GATEKEEPER R6 N3: an unknown restore point removed something"
    tm_assert_file "$U/topic-manager.socket" "the socket unit was retired without a record"
    tm_assert_grep "PROBLEM|not retired: $U/topic-manager-audit-prune.timer — the restore point (v1.0.11) has no install manifest" \
        "${TM_TMP}/out" "GATEKEEPER R6 N3: what was not retired is not a restore problem"
    tm_assert_grep "PROBLEM|not retired: $R/usr/libexec/topic-manager/tm-apply" "${TM_TMP}/out" "the helper is not listed"
    grep -q "^PROBLEM|not retired: .*site-backup" "${TM_TMP}/out" && _tm_afail "a foreign unit is listed as the product's"
    grep -q "^PROBLEM|not retired: .*topic-manager-apply-tls.service" "${TM_TMP}/out" && _tm_afail "an artefact already gone is listed as not retired"
    grep -q "^PROBLEM|not retired: .*topic-manager-limits.conf" "${TM_TMP}/out" && _tm_afail "operator state is listed as a unit, rule or helper"
    tm_assert_file "$R/var/lib/topic-manager/installed-files.manifest" "the host's record was dropped though nothing was retired"
    # Phase 4 on such a host: no record, a warning, and Phase 4 goes on.
    rm -f "$R/var/lib/topic-manager/installed-files.manifest"; mkdir -p "${TM_TMP}/bd2/manifest" "${TM_TMP}/bd2/system"; : > "${TM_TMP}/out"
    _prog "$R" backup_owned_artefacts "${TM_TMP}/bd2" 1.0.11
    tm_assert_rc 0 "$RC" "Phase 4 failed on a host of a release with no manifest and no shipped list: $(cat "${TM_TMP}/out")"
    tm_assert_nofile "${TM_TMP}/bd2/manifest/installed-files.manifest" "a record was invented for a release with none"
    tm_assert_grep "will retire none of them" "${TM_TMP}/out" "the operator is not told at backup time"
    true
}
tm_case "a-restore-point-of-an-unknown-release-retires-nothing-and-fails" linux,symlinks r_unknown_version_retires_nothing

r_legacy_point_uses_shipped_list() {
    # A restore point taken before the manifest existed (a 1.1.1 script's
    # --backup-only): judged by the v1.1.x shipped list, put back from the
    # copies it has always kept; one it never kept is a restore problem.
    _setup none
    rm -rf "$BD/manifest/installed-files.manifest" "$BD/manifest/host-locations.list" "$BD/system/owned"
    printf '[Service]\nExecStart=gunicorn --bind 127.0.0.1:5001\n' > "$BD/system/topic-manager.service"
    printf 'server { # v1.1 site }\n' > "$BD/system/topic-manager.nginx"
    printf '# headers v1.1\n' > "$BD/system/tm-security-headers.conf"
    rm -f "$U/multi-user.target.wants/topic-manager.service"     # the operator had disabled it
    _prog "$R" rollback "$BD"
    rm -rf "$SOCKD"
    tm_assert_rc 0 "$RC" "the rollback failed: $(cat "${TM_TMP}/out")"
    grep -qx "systemctl disable --now topic-manager-audit-prune.timer" "${TM_TMP}/calls" || _tm_afail "a v1.1.1 restore point without a manifest retired nothing"
    grep -q 'site-backup' "${TM_TMP}/calls" && _tm_afail "a foreign unit was touched"
    tm_assert_grep "127.0.0.1:5001" "$U/topic-manager.service" "the service unit was not put back from the legacy copy"
    tm_assert_grep "PROBLEM|the restore point lists $U/topic-manager-nginx-test.service but holds no copy of it" "${TM_TMP}/out" \
        "a shipped artefact the legacy point never kept is not a restore problem"
    tm_assert_grep "PROBLEM|the restore point lists $R/etc/logrotate.d/topic-manager but holds no copy of it" "${TM_TMP}/out" \
        "a legacy copy the restore point does not have is not a restore problem"
    tm_assert_grep "headers v1.1" "$R/etc/nginx/snippets/tm-security-headers.conf" "the header snippet was not put back from the legacy copy"
    [ -L "$U/multi-user.target.wants/topic-manager.service" ] || _tm_afail "a shipped enablement link was not re-created"
    # Exactly the three it never kept a copy of; a shipped link that is there
    # (sites-enabled) is fine as it is.
    [ "$(grep -c '^PROBLEM|' "${TM_TMP}/out")" -eq 3 ] || _tm_afail "expected exactly three problems: $(grep '^PROBLEM|' "${TM_TMP}/out")"
    tm_assert_grep "PROBLEM|the restore point lists $R/etc/polkit-1/rules.d/50-topic-manager.rules but holds no copy" "${TM_TMP}/out" "the polkit rule with no copy is not a problem"
    tm_assert_file "$U/site-backup.service" "a foreign unit was removed"
}
tm_case "a-v111-restore-point-without-a-manifest-uses-the-shipped-list" linux,symlinks r_legacy_point_uses_shipped_list

r_restore_point_had_them() {
    # A 1.2.0 -> 1.2.x rollback: the restore point's manifest HAS the helper
    # and a unit; they come back, nothing is retired, and the host's record
    # becomes the restore point's.
    _setup none
    rm -rf "$BD"; mkdir -p "$BD/manifest" "$BD/system"; printf 'topic_manager_version=1.2.0\n' > "$BD/manifest/state.env"
    chmod 750 "$R/usr/libexec/topic-manager/lib"
    rm -f "$U/topic-manager-future-thing.timer"     # recorded, gone before the backup
    _prog "$R" backup_owned_artefacts "$BD" 1.2.0
    tm_assert_rc 0 "$RC" "Phase 4 failed on a recorded artefact that is gone: $(cat "${TM_TMP}/out")"
    cmp -s "$BD/manifest/installed-files.manifest" "$R/var/lib/topic-manager/installed-files.manifest" \
        || _tm_afail "the restore point does not carry the host's manifest as it is"
    tm_assert_nofile "$BD/system/owned$R/etc/nginx/conf.d/topic-manager-limits.conf" "operator state was copied as a release file"
    # An unchanged file with no copy is fine; a symlink where the product's
    # directory was is replaced, and nothing is changed through it.
    rm -f "$BD/system/owned$U/topic-manager-apply-audit.service"
    mkdir -p "${TM_TMP}/elsewhere"; chmod 700 "${TM_TMP}/elsewhere"
    rm -rf "$R/usr/libexec/topic-manager/lib"; ln -s "${TM_TMP}/elsewhere" "$R/usr/libexec/topic-manager/lib"
    printf '#!/usr/bin/python3\n# a later build\n' > "$R/usr/libexec/topic-manager/tm-apply"
    rm -f "$U/topic-manager-audit-prune.timer"
    echo "# later" >> "$R/var/lib/topic-manager/installed-files.manifest"
    : > "${TM_TMP}/calls"
    _prog "$R" restore_owned_artefacts "$BD"
    rm -rf "$SOCKD"
    tm_assert_rc 0 "$RC" "restore failed: $(cat "${TM_TMP}/out")"
    grep -q 'disable' "${TM_TMP}/calls" && _tm_afail "a unit the restore point held was retired: $(cat "${TM_TMP}/calls")"
    tm_assert_file "$U/topic-manager-audit-prune.timer" "a unit the restore point held did not come back"
    tm_assert_nogrep "a later build" "$R/usr/libexec/topic-manager/tm-apply" "the helper was not put back byte-exact"
    [ -d "$R/usr/libexec/topic-manager/lib" ] && [ ! -L "$R/usr/libexec/topic-manager/lib" ] || _tm_afail "a symlink stands where the product's directory was"
    tm_assert_mode 700 "${TM_TMP}/elsewhere" "the restore changed a mode THROUGH a symlink"
    tm_assert_mode 750 "$R/usr/libexec/topic-manager/lib" "a recorded directory did not get its recorded mode back"
    tm_assert_file "$R/usr/libexec/topic-manager/lib/tls_check.py" "a file inside the directory was not put back"
    grep -q "^PROBLEM|.*topic-manager-apply-audit.service" "${TM_TMP}/out" && _tm_afail "an UNCHANGED recorded file with no copy was called a problem"
    tm_assert_grep "PROBLEM|the restore point lists $U/topic-manager-future-thing.timer but holds no copy of it" "${TM_TMP}/out" \
        "a recorded artefact gone before the backup is not a restore problem"
    # ... and nothing else: operator state the record names is restore_v120_managed's.
    [ "$(grep -c '^PROBLEM|' "${TM_TMP}/out")" -eq 1 ] || _tm_afail "expected exactly one problem: $(grep '^PROBLEM|' "${TM_TMP}/out")"
    tm_assert_grep "limit_req_zone x;" "$R/etc/nginx/conf.d/topic-manager-limits.conf" "operator state was touched by the unit restore"
    cmp -s "$BD/manifest/installed-files.manifest" "$R/var/lib/topic-manager/installed-files.manifest" \
        || _tm_afail "the host's manifest is not the restore point's after the restore"
    tm_assert_mode 600 "$R/var/lib/topic-manager/installed-files.manifest" "the restored manifest is not 0600"
}
tm_case "rollback-puts-back-what-the-restore-point-recorded" linux,symlinks,modes r_restore_point_had_them

r_runtime_dir_kept_while_declared() {
    # A RuntimeDirectory= a KEPT unit declares stays; one that is not a plain
    # name is a problem, never an rm.
    local R="${TM_TMP}/root" BD="${TM_TMP}/bd" U="${TM_TMP}/root/etc/systemd/system" M="${TM_TMP}/root/var/lib/topic-manager/installed-files.manifest" h
    mkdir -p "$BD/manifest" "$BD/system" "$U" "$R/run/topic-manager-apply" "$R/etc/keep" "${M%/*}"; : > "${TM_TMP}/calls"; : > "${TM_TMP}/out"
    printf '[Service]\nRuntimeDirectory=topic-manager-apply\n' > "$U/topic-manager-apply-syslog.service"
    printf '[Service]\nRuntimeDirectory=topic-manager-apply\n' > "$U/topic-manager-apply-tls.service"
    printf '[Service]\nRuntimeDirectory=../etc/keep\n' > "$U/topic-manager-escape.service"
    : > "$M"
    for h in topic-manager-apply-syslog.service topic-manager-apply-tls.service topic-manager-escape.service; do
        printf '%s %s\n' "$(sha256sum < "$U/$h" | cut -d' ' -f1)" "$U/$h" >> "$M"
    done
    grep 'apply-syslog' "$M" > "$BD/manifest/installed-files.manifest"
    mkdir -p "$BD/system/owned$U"; cp -a "$U/topic-manager-apply-syslog.service" "$BD/system/owned$U/"
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
    _setup none
    rm -f "$BD/system/owned$U/topic-manager-nginx-test.service"
    rm -f "$U/topic-manager-future-thing.timer"; mkdir "$U/topic-manager-future-thing.timer"
    export T_FAIL_UNIT=topic-manager-audit-prune.timer
    _prog "$R" rollback "$BD"
    unset T_FAIL_UNIT
    rm -rf "$SOCKD"
    tm_assert_grep "PROBLEM|systemctl disable --now topic-manager-audit-prune.timer failed (Failed to disable unit: Access denied)" \
        "${TM_TMP}/out" "a unit systemctl could not retire is not a restore problem"
    tm_assert_grep "PROBLEM|the restore point lists $U/topic-manager-nginx-test.service but holds no copy of it" \
        "${TM_TMP}/out" "a recorded file with no saved copy is not a restore problem"
    tm_assert_grep "PROBLEM|$U/topic-manager-future-thing.timer is a directory, but the install manifest does not record a directory there" \
        "${TM_TMP}/out" "a directory where a recorded file was is not a restore problem"
    tm_assert_dir "$U/topic-manager-future-thing.timer" "a directory the manifest does not record was removed"
    [ "$(grep -c '^PROBLEM|' "${TM_TMP}/out")" -eq 3 ] || _tm_afail "expected exactly three problems: $(grep '^PROBLEM|' "${TM_TMP}/out")"
    tm_assert_nogrep "topic-manager-nginx-test.service (changed since" "${TM_TMP}/out" "a product unit with no copy is listed as not the product's"
}
tm_case "a-unit-that-cannot-be-retired-or-a-missing-copy-is-a-restore-problem" linux,symlinks r_problems_are_reported

# ─── the manifest itself ─────────────────────────────────────────────────────
_m_tree_one() {
    # host_artefacts reads the REAL tree: every unit in systemd/ with the link
    # its [Install] asks for, every polkit rule, the helper files, HOST_FILES,
    # HOST_LINKS and the operator state — and nothing is judged by content.
    local R="${TM_TMP}/root" out f u t
    _prog "$R" host_artefacts "$TM_REPO_ROOT"
    tm_assert_rc 0 "$RC" "host_artefacts failed: $(cat "${TM_TMP}/out")"
    out="${TM_TMP}/out"
    for f in "${TM_REPO_ROOT}"/systemd/*; do
        u="${f##*/}"
        grep -qx "file $R/etc/systemd/system/$u" "$out" || _tm_afail "the manifest does not record the shipped unit $u"
        for t in $(sed -n 's/^WantedBy=//p' "$f"); do
            grep -qx "link $R/etc/systemd/system/$t.wants/$u" "$out" || _tm_afail "the manifest does not record ${u}'s enablement link"
        done
    done
    for f in "${TM_REPO_ROOT}"/install/polkit/*; do
        grep -qx "file $R/etc/polkit-1/rules.d/${f##*/}" "$out" || _tm_afail "the manifest does not record the rule ${f##*/}"
    done
    for f in "dir $R/usr/libexec/topic-manager" "dir $R/usr/libexec/topic-manager/lib" "file $R/usr/libexec/topic-manager/tm-apply" \
             "file $R/usr/libexec/topic-manager/lib/settings_schema.py" "file $R/usr/libexec/topic-manager/lib/tls_check.py" \
             "file $R/etc/nginx/sites-available/topic-manager" "link $R/etc/nginx/sites-enabled/topic-manager" \
             "file $R/etc/logrotate.d/topic-manager" "file $R/etc/nginx/snippets/tm-security-headers.conf" \
             "state $R/etc/nginx/conf.d/topic-manager-limits.conf" "state $R/etc/rsyslog.d/topic-manager"; do
        grep -qxF "$f" "$out" || _tm_afail "the manifest does not record: $f"
    done
    [ "$(grep -c "^file $R/etc/systemd/system/" "$out")" -eq "$(find "${TM_REPO_ROOT}/systemd" -type f | wc -l)" ] \
        || _tm_afail "the manifest records a unit the tree does not ship"
    true
}
# Both scripts' copies, by BEHAVIOUR: an install.sh-only mutation must go red
# here, not only in the scripts-carry-the-same-block check.
_both() {   # _both <fn>
    local f
    for f in "$UP" "$INSTALL_SH"; do
        BLOCK_SRC="$f"; rm -rf "${TM_TMP:?}/root"; : > "${TM_TMP}/out"
        ( "$1" ) || _tm_afail "$(basename "$f"): the case above failed on this script's copy"
    done
}
m_manifest_from_the_tree() { _both _m_tree_one; }
tm_case "the-manifest-is-read-from-the-tree-the-release-installs-from" none m_manifest_from_the_tree

_m_file_one() {
    # Only what is PRESENT, a file with its sha256 as it is on disk; 0600.
    # The pending record lists everything, present or not.
    local R="${TM_TMP}/root" U="${TM_TMP}/root/etc/systemd/system" M="${TM_TMP}/root/var/lib/topic-manager/installed-files.manifest"
    mkdir -p "$U/sockets.target.wants" "$R/etc/nginx/conf.d"; : > "${TM_TMP}/out"
    cp "${TM_REPO_ROOT}/systemd/topic-manager.socket" "$U/"
    printf '# edited by the installer\n' >> "$U/topic-manager.socket"
    ln -s "$U/topic-manager.socket" "$U/sockets.target.wants/topic-manager.socket"
    printf 'x\n' > "$R/etc/nginx/conf.d/topic-manager-limits.conf"
    _prog "$R" write_install_manifest "$TM_REPO_ROOT"
    tm_assert_rc 0 "$RC" "write_install_manifest failed: $(cat "${TM_TMP}/out")"
    tm_assert_mode 600 "$M" "the manifest is not 0600"
    tm_assert_mode 700 "${M%/*}" "the manifest's directory is not 0700"
    grep -qx "$(sha256sum < "$U/topic-manager.socket" | cut -d' ' -f1) $U/topic-manager.socket" "$M" \
        || _tm_afail "the manifest does not record the file's hash as it is on disk: $(cat "$M")"
    grep -qx "link $U/sockets.target.wants/topic-manager.socket" "$M" || _tm_afail "a present enablement link is not recorded"
    grep -qx "state $R/etc/nginx/conf.d/topic-manager-limits.conf" "$M" || _tm_afail "present operator state is not recorded as state"
    grep -q "topic-manager.service$" "$M" && _tm_afail "an artefact that is NOT present was recorded"
    [ "$(grep -vc '^#' "$M")" -eq 3 ] || _tm_afail "expected exactly three records: $(cat "$M")"
    _prog "$R" write_install_manifest "$TM_REPO_ROOT" pending
    grep -qx "pending $U/topic-manager.service" "$M.pending" || _tm_afail "the pending record omits a file the release is about to install"
    grep -qx "link $U/multi-user.target.wants/topic-manager.service" "$M.pending" || _tm_afail "the pending record omits a link"
    true
}
m_manifest_file() { _both _m_file_one; }
tm_case "the-manifest-records-what-is-present-with-its-hash-0600" linux,symlinks,modes m_manifest_file

_m_helper_one() {
    # install_apply_helper lays down EXACTLY the helper tree the manifest
    # records (APPLY_HELPER_FILES is the one list), with its modes.
    local R="${TM_TMP}/root" L="${TM_TMP}/root/usr/libexec/topic-manager" p
    _prog "$R" install_apply_helper "$TM_REPO_ROOT"
    tm_assert_rc 0 "$RC" "install_apply_helper failed: $(cat "${TM_TMP}/out")"
    tm_assert_mode 755 "$L/tm-apply" "the helper is not 0755"
    tm_assert_mode 644 "$L/lib/settings_schema.py" "a rule module is not 0644"
    cmp -s "$L/tm-apply" "${TM_REPO_ROOT}/install/libexec/tm-apply" || _tm_afail "the helper installed is not the tree's"
    cmp -s "$L/lib/tls_check.py" "${TM_REPO_ROOT}/tm/tls_check.py" || _tm_afail "tls_check.py installed is not the tree's"
    : > "${TM_TMP}/out"
    _prog "$R" host_artefacts "$TM_REPO_ROOT"
    diff <(cd "$R" && find usr/libexec/topic-manager | sed 's#^#/#' | sort) \
         <(grep -E "^(file|dir) $R/usr/libexec/" "${TM_TMP}/out" | cut -d' ' -f2- | sed "s#^$R##" | sort -u) >/dev/null \
        || _tm_afail "the helper tree installed is not the tree the manifest records"
}
m_helper_tree() { _both _m_helper_one; }
tm_case "the-helper-tree-installed-is-the-one-the-manifest-records" linux,modes m_helper_tree

m_block_identical() {
    _block "$INSTALL_SH" > "${TM_TMP}/a"
    _block "$UP" > "${TM_TMP}/b"
    [ -s "${TM_TMP}/a" ] || tm_die "empty block"
    cmp -s "${TM_TMP}/a" "${TM_TMP}/b" || _tm_afail "the host-artefact block differs between install.sh and the upgrade: $(diff "${TM_TMP}/a" "${TM_TMP}/b" > "${TM_TMP}/d"; sed -n 1,5p "${TM_TMP}/d")"
}
tm_case "install-and-upgrade-share-one-host-artefact-record" none m_block_identical

m_wired() {
    local p4 rfb p9 end first_host
    p4="$(tm_extract_between "$UP" '^backup_v120_managed "\$BACKUP_DIR"$' '^tar -czf "\$BACKUP_TAR"')"
    grep -q '^backup_owned_artefacts "\$BACKUP_DIR" "\$INSTALLED_VER"$' <<<"$p4" || _tm_afail "Phase 4 does not record the host artefacts with the installed version"
    local inv sums
    inv="$(grep -n '^backup_owned_artefacts "\$BACKUP_DIR" "\$INSTALLED_VER"$' "$UP" | cut -d: -f1)"
    sums="$(grep -n '^( cd "\$BACKUP_DIR" && find . -type f ! -name SHA256SUMS' "$UP" | cut -d: -f1)"
    tm_assert_nonempty "$inv" "no inventory call"; tm_assert_nonempty "$sums" "no checksum anchor"
    [ "$inv" -lt "$sums" ] || _tm_afail "the record is taken after the restore point is checksummed"
    rfb="$(tm_extract_func "$UP" restore_from_backup)"
    grep -q '^    restore_owned_artefacts "\$BD"$' <<<"$rfb" || _tm_afail "restore_from_backup does not retire by record"
    # The pending record before Phase 9's first host write; the manifest when
    # the deploy is done and again once every unit is enabled.
    p9="$(tm_extract_between "$UP" '^phase "Phase 9 — Deploy application"$' '^phase "Phase 10 — ')"
    first_host="$(grep -n '/etc/nginx/snippets/tm-security-headers.conf$' <<<"$p9" | cut -d: -f1)"; first_host="${first_host%%$'\n'*}"
    local pend; pend="$(grep -n '^write_install_manifest "\$WORK_DIR" pending$' <<<"$p9" | cut -d: -f1)"
    tm_assert_nonempty "$pend" "Phase 9 writes no pending record"
    [ "$pend" -lt "$first_host" ] || _tm_afail "the pending record is written after Phase 9 starts installing"
    grep -q '^write_install_manifest "\$WORK_DIR"$' <<<"$p9" || _tm_afail "Phase 9 does not write the manifest once deployed"
    end="$(tm_extract_between "$UP" '^systemctl enable --now topic-manager-audit-prune.timer' '^info "Installed third-party components:"$')"
    grep -q '^write_install_manifest "\$WORK_DIR"$' <<<"$end" || _tm_afail "the upgrade does not record the enablement links at the end"
    grep -qF 'rm -f -- "${INSTALL_MANIFEST}.pending"' <<<"$end" || _tm_afail "the upgrade leaves its pending record"
    end="$(tm_extract_between "$INSTALL_SH" '^systemctl enable --now topic-manager-audit-prune.timer' '^success "Install manifest: ')"
    grep -q '^write_install_manifest "\$SCRIPT_DIR"$' <<<"$end" || _tm_afail "install.sh writes no manifest after the last enable"
}
tm_case "every-install-and-upgrade-writes-and-every-restore-reads-the-record" none m_wired

# ─── the lists are the code's, not a hand-kept copy ─────────────────────────
# _dests <text-file> <tree-reader> — every host path the script text installs
# ("file|link <path>"): install/cp/ln destinations and the enablement links of
# `systemctl enable`, with for-loop and array variables expanded.
_dests() {   # _dests <script-text> <cmd that prints a tree file: CMD <relpath>>
    "$(tm_python)" - "$1" "$2" <<'PY'
import re, shlex, subprocess, sys
text = open(sys.argv[1]).read().replace('\\\n', ' ')
reader = sys.argv[2]
def tree(rel):
    # the reader's last word is a prefix: "cat <root>/" or "git ... show <tag>:"
    argv = reader.split()
    argv[-1] += rel
    r = subprocess.run(argv, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None
arrays = {}
for m in re.finditer(r'^([A-Z0-9_]+)=\(([^)]*)\)', text, re.M):
    arrays[m.group(1)] = shlex.split(m.group(2), comments=True)
scal = {}
for m in re.finditer(r'^(SERVICE|SERVICE_NAME)="([^"$]*)"', text, re.M):
    scal[m.group(1)] = m.group(2)
out, loops = set(), []
def expand(tok, env):
    for k, v in env.items():
        tok = tok.replace('${%s}' % k, v).replace('$%s' % k, v)
    return tok
for raw in text.split('\n'):
    line = raw.strip()
    if not line or line.startswith('#'):
        continue
    m = re.match(r'for (\w+) in (.*?); do', line)
    if m:
        words = []
        for w in shlex.split(m.group(2)):
            a = re.fullmatch(r'\$\{(\w+)\[@\]\}', w)
            words += arrays.get(a.group(1), []) if a else [w]
        loops.append((m.group(1), words))
        continue
    if line.startswith('done'):
        if loops: loops.pop()
        continue
    for seg in re.split(r'&&|\|\||;', line):
        seg = seg.strip()
        try:
            w = shlex.split(seg)
        except ValueError:
            continue
        if not w: continue
        envs = [dict(scal)]
        for var, words in loops:
            envs = [dict(e, **{var: x}) for e in envs for x in words]
        for env in envs:
            ww = [expand(x, env) for x in w]
            if ww[0] in ('install', 'cp', 'ln', 'install_if_absent') and '-d' not in ww[1:3] and len(ww) >= 3:
                dest, src = ww[-1], ww[-2]
                if not re.match(r'^/(etc|usr)/', dest) or '$' in dest:
                    continue
                if dest.endswith('/'):
                    dest += src.rsplit('/', 1)[-1]
                out.add(('link' if ww[0] == 'ln' else 'file', dest))
            elif ww[:2] == ['systemctl', 'enable']:
                for u in ww[2:]:
                    if u.startswith('-') or '$' in u: continue
                    if '.' not in u: u += '.service'
                    body = tree('systemd/' + u)
                    if body is None: continue
                    for t in re.findall(r'^\s*WantedBy\s*=\s*(.+)$', body, re.M):
                        for tt in t.split():
                            out.add(('link', '/etc/systemd/system/%s.wants/%s' % (tt, u)))
for k, p in sorted(out):
    print(k, p)
PY
}

l_legacy_list_is_the_tags() {
    # LEGACY_V11X_ARTEFACTS is DATA taken from the v1.1.0 and v1.1.1 tags:
    # re-derived here from each tag's install.sh and upgrade Phase 9.
    local tag want got
    want="$(tm_extract_between "$UP" '^LEGACY_V11X_ARTEFACTS=' '^[[:space:]]+"file /etc/logrotate.d/topic-manager"\)$' \
            | grep -oE '"(file|link) /[^"]+"' | tr -d '"' | sort)"
    tm_assert_nonempty "$want" "no legacy list extracted"
    for tag in v1.1.0 v1.1.1; do
        { git -C "$TM_REPO_ROOT" show "${tag}:install.sh"
          git -C "$TM_REPO_ROOT" show "${tag}:install/upgrade-full.sh" \
            | awk '/^phase "Phase 9 /{p=1} /^phase "Phase 10 /{p=0} p'
        } > "${TM_TMP}/${tag}.sh" || tm_die "cannot read ${tag}"
        [ "$(git -C "$TM_REPO_ROOT" show "${tag}:VERSION" | tr -d '[:space:]')" = "${tag#v}" ] || tm_die "${tag} is not release ${tag#v}"
        got="$(_dests "${TM_TMP}/${tag}.sh" "git -C ${TM_REPO_ROOT} show ${tag}:" | sort)"
        tm_assert_eq "$want" "$got" "LEGACY_V11X_ARTEFACTS is not what ${tag} installs"
    done
    grep -q '^LEGACY_V11X_VERSIONS=(1.1.0 1.1.1)$' "$UP" || _tm_afail "the legacy list is applied to versions it was not derived from"
}
tm_case "the-v11x-shipped-list-is-re-derived-from-the-tags" gittags l_legacy_list_is_the_tags

l_this_tree_is_recorded() {
    # Every host path install.sh or the upgrade's Phase 9 installs is in the
    # manifest this release writes, and every release file and link the
    # manifest records outside the helper tree is installed by both.
    local R="${TM_TMP}/root" m p
    { cat "$INSTALL_SH"; awk '/^phase "Phase 9 /{p=1} /^phase "Phase 10 /{p=0} p' "$UP"; grep -E '^V120_UNITS=|^[[:space:]]+topic-manager-(apply|audit)' "$UP"; } > "${TM_TMP}/both.sh"
    _dests "${TM_TMP}/both.sh" "cat ${TM_REPO_ROOT}/" | sort > "${TM_TMP}/installed"
    _prog "/" host_artefacts "$TM_REPO_ROOT"
    sed -e 's#//*#/#g' "${TM_TMP}/out" | sort > "${TM_TMP}/recorded"
    [ -s "${TM_TMP}/installed" ] || tm_die "no destinations parsed"
    while read -r _ p; do
        case "$p" in /etc/topic-manager/*) continue ;; esac   # the product's own configuration tree
        m="$(awk -v p="$p" '{ q=$2 } q==p || index(p, q "/")==1 { print; exit }' "${TM_TMP}/recorded")"
        [ -n "$m" ] || _tm_afail "installed but not in the manifest: ${p}"
    done < "${TM_TMP}/installed"
    while read -r k p; do
        [ "$k" = file ] || [ "$k" = link ] || continue
        case "$p" in /usr/libexec/topic-manager/*) continue ;; esac   # install_apply_helper, from APPLY_HELPER_FILES
        grep -qx "$k $p" "${TM_TMP}/installed" || _tm_afail "the manifest records ${k} ${p}, which neither script installs"
    done < "${TM_TMP}/recorded"
    true
}
tm_case "every-host-path-this-tree-installs-is-recorded" none l_this_tree_is_recorded

tm_finish
