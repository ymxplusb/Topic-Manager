#!/usr/bin/env bash
# =============================================================================
# t47 — v1.2.0 ROUND 6: the package lock is waited for, not failed on; and the
# clean-room round-5 documentation defects stay fixed.
#
#   * the REAL dpkg_lock_holder / wait_for_dpkg_lock against a real POSIX
#     lock held by another process: it waits, names the holder, returns when
#     the lock is released, and gives up — saying so — at its bound;
#   * the helpers are byte-identical in install.sh and the upgrade, every apt
#     call that takes a lock also carries apt's own bound, and a held lock
#     stops install.sh (bundle and online paths) before apt runs;
#   * the docs: every count of the polkit rule's unit/verb pairs is DERIVED
#     from the rule; README's ufw line matches INSTALL; the upgrade is run
#     detached; the PPSM names both resolved stubs; the lock and the restore
#     verdict are in TROUBLESHOOTING.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "the package lock is waited for; the round-5 documentation defects stay fixed"

INSTALL_SH="$(tm_install_sh)"
UP="$(tm_upgrade_sh)"
R="$TM_REPO_ROOT"

# ─── the lock wait, for real ────────────────────────────────────────────────
_lock_prog() {   # the real helpers from install.sh, waiting on "$@"
    {
        echo 'set -uo pipefail'
        echo 'info() { echo "[INFO] $*"; }; warn() { echo "[WARN] $*"; }'
        tm_extract_line "$INSTALL_SH" '^DPKG_LOCKS=\('
        tm_extract_line "$INSTALL_SH" '^APT_LOCKS=\('
        tm_extract_line "$INSTALL_SH" '^DPKG_LOCK_WAIT_S='
        tm_extract_func "$INSTALL_SH" dpkg_lock_holder
        tm_extract_func "$INSTALL_SH" wait_for_dpkg_lock
        echo 'wait_for_dpkg_lock "$@"'
    } > "${TM_TMP}/lw.sh"
}
# A lock file on tmpfs (/dev/shm): on an overlay filesystem the kernel may
# list a lock under the upper layer's device rather than the path's.
_hold() {   # _hold <seconds> — a python process holding a POSIX lock on $LK
    rm -f "${LD}/ready"
    "$(tm_python)" -c '
import fcntl, sys, time
f = open(sys.argv[1], "w")
fcntl.lockf(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(float(sys.argv[3]))' "$LK" "${LD}/ready" "$1" &
    HOLDER=$!
    local i
    for i in $(seq 1 50); do [ -e "${LD}/ready" ] && return 0; sleep 0.1; done
    kill "$HOLDER" 2>/dev/null; rm -rf "$LD"; tm_die "the lock holder never took the lock"
}

l_waits_names_and_bounds() {
    [ -d /dev/shm ] && [ -w /dev/shm ] || tm_die "/dev/shm is not writable here"
    LD="$(mktemp -d /dev/shm/tm-lock.XXXXXX)"; LK="${LD}/lock-frontend"; : > "$LK"
    _lock_prog
    local rc t0 out
    # Free: returns at once and says nothing about waiting.
    rc=0; out="$(TM_DPKG_LOCK_WAIT_S=5 bash "${TM_TMP}/lw.sh" "$LK" 2>&1)" || rc=$?
    tm_assert_rc 0 "$rc" "a free lock was not free: ${out}"
    grep -q 'Waiting' <<<"$out" && { rm -rf "$LD"; _tm_afail "waited on a free lock: ${out}"; }
    # Held for 3 s, bound 30 s: waits, names the holder, returns 0 once released.
    _hold 3
    t0=$SECONDS
    rc=0; out="$(TM_DPKG_LOCK_WAIT_S=30 bash "${TM_TMP}/lw.sh" "$LK" 2>&1)" || rc=$?
    wait "$HOLDER" 2>/dev/null
    tm_assert_rc 0 "$rc" "CLEAN-ROOM N1: a lock released within the bound failed the step: ${out}"
    [ $((SECONDS - t0)) -ge 2 ] || { rm -rf "$LD"; _tm_afail "it did not wait for the lock (returned in $((SECONDS - t0))s): ${out}"; }
    grep -q "Waiting for the package lock (${LK}, held by PID ${HOLDER} (python" <<<"$out" \
        || { rm -rf "$LD"; _tm_afail "the wait does not name the process holding the lock: ${out}"; }
    grep -q 'The package lock was released after' <<<"$out" || { rm -rf "$LD"; _tm_afail "the release is not reported: ${out}"; }
    # Held for 60 s, bound 2 s: gives up, non-zero, with the holder named.
    _hold 60
    rc=0; out="$(TM_DPKG_LOCK_WAIT_S=2 bash "${TM_TMP}/lw.sh" "$LK" 2>&1)" || rc=$?
    kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
    rm -rf "$LD"
    tm_assert_rc 1 "$rc" "a lock held past the bound was not a failure: ${out}"
    grep -q "STILL held after 2s: ${LK}, held by PID ${HOLDER} (python" <<<"$out" \
        || _tm_afail "the give-up does not name the lock and its holder: ${out}"
    grep -q 'unattended-upgrades' <<<"$out" || _tm_afail "the give-up does not say what usually holds it: ${out}"
}
tm_case "package-lock-is-waited-for-named-and-bounded" linux l_waits_names_and_bounds

l_helpers_identical() {
    local f
    for f in dpkg_lock_holder wait_for_dpkg_lock; do
        tm_extract_func "$INSTALL_SH" "$f" > "${TM_TMP}/a"
        tm_extract_func "$UP" "$f" > "${TM_TMP}/b"
        cmp -s "${TM_TMP}/a" "${TM_TMP}/b" || _tm_afail "${f} differs between install.sh and the upgrade"
    done
    for f in '^DPKG_LOCKS=\(' '^APT_LOCKS=\(' '^DPKG_LOCK_WAIT_S='; do
        tm_assert_eq "$(tm_extract_line "$INSTALL_SH" "$f")" "$(tm_extract_line "$UP" "$f")" "the lock settings differ"
    done
    tm_assert_eq 'DPKG_LOCK_WAIT_S="${TM_DPKG_LOCK_WAIT_S:-600}"' "$(tm_extract_line "$INSTALL_SH" '^DPKG_LOCK_WAIT_S=')" \
        "the default wait is not 600 s"
}
tm_case "lock-helpers-are-byte-identical-in-both-scripts" none l_helpers_identical

# Every apt-get that takes a lock (anything but a simulation) carries apt's
# own bound too, for the moment between the wait and apt's lock.
l_every_apt_call_bounded() {
    "$(tm_python)" - "$INSTALL_SH" "$UP" > "${TM_TMP}/apt.calls" <<'PYEOF' || tm_die "could not read the apt calls"
import re, sys
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read().replace("\\\n", " ")
    for n, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if s.startswith("#"):
            continue
        m = re.search(r'(^|[;&|(]\s*|(?:DEBIAN_FRONTEND|LC_ALL)=\S+\s+)apt-get\s', s)
        if not m:
            continue
        sim = re.search(r'\s-s\s', s) is not None
        print("%s|%s|%s" % (path.rsplit("/", 1)[-1], "SIM" if sim else "LOCK", s))
PYEOF
    local n
    n="$(grep -c '|LOCK|' "${TM_TMP}/apt.calls")"
    [ "$n" -ge 8 ] || tm_die "only ${n} locking apt-get calls found: $(cat "${TM_TMP}/apt.calls")"
    grep '|LOCK|' "${TM_TMP}/apt.calls" | grep -v 'DPkg::Lock::Timeout=${DPKG_LOCK_WAIT_S}' > "${TM_TMP}/unbounded" || true
    [ -s "${TM_TMP}/unbounded" ] && _tm_afail "apt-get call(s) without DPkg::Lock::Timeout: $(cat "${TM_TMP}/unbounded")"
    true
}
tm_case "every-locking-apt-call-carries-a-lock-timeout" none l_every_apt_call_bounded

# A lock still held at the bound stops the step BEFORE apt runs, on every path.
_apt_stub() {
    mkdir -p "${TM_TMP}/bin" "${TM_TMP}/apt"
    : > "${TM_TMP}/apt/Packages"; : > "${TM_TMP}/apt/nginx.deb"
    printf '#!/usr/bin/env bash\necho "apt-get $*" >> "%s/calls"\ncase " $* " in *" -s "*) echo "Inst nginx (1 b [all])" ;; esac\nexit 0\n' \
        "$TM_TMP" > "${TM_TMP}/bin/apt-get"
    chmod 755 "${TM_TMP}/bin/apt-get"; : > "${TM_TMP}/calls"
}
l_held_lock_stops_the_bundle_install() {
    _apt_stub
    {
        echo 'set -uo pipefail'
        echo 'info() { echo "INFO $*"; }; die() { echo "DIE $*"; exit 1; }'
        echo 'apt_fips_packages() { :; }; apt_removal_reason() { :; }'
        echo 'wait_for_dpkg_lock() { echo "WAITED $*" >> "'"${TM_TMP}"'/calls"; return 1; }; DPKG_LOCK_WAIT_S=7'
        tm_extract_func "$INSTALL_SH" apt_install_from_bundle
        printf 'NON_INTERACTIVE=true apt_install_from_bundle "%s" nginx\n' "${TM_TMP}/apt"
    } > "${TM_TMP}/b.sh"
    local rc=0 out
    out="$(PATH="${TM_TMP}/bin:${PATH}" bash "${TM_TMP}/b.sh" 2>&1)" || rc=$?
    tm_assert_rc 1 "$rc" "the offline install went on with the package lock held: ${out}"
    grep -q '^WAITED' "${TM_TMP}/calls" || _tm_afail "CLEAN-ROOM N1: the offline install never waits for the package lock"
    local inst
    inst="$(grep -E '^apt-get .* install -y' "${TM_TMP}/calls" | grep -v -- ' -s ' || true)"
    [ -z "$inst" ] || _tm_afail "apt install ran although the lock was held: ${inst}"
    grep -q 'package lock is held by another process' <<<"$out" || _tm_afail "the failure does not say it is the lock: ${out}"
    grep -q 'nothing was installed or changed' <<<"$out" || _tm_afail "the failure does not say nothing changed: ${out}"
    tm_assert_grep "Could not get lock /var/lib/dpkg/lock-frontend" "$INSTALL_SH" "the apt-failure text never mentions the lock"
}
tm_case "a-held-lock-stops-the-offline-install-before-apt" none l_held_lock_stops_the_bundle_install

l_held_lock_stops_the_online_installs() {
    _apt_stub
    {
        echo 'set -uo pipefail'
        echo 'info() { :; }; success() { :; }; warn() { :; }; die() { echo "DIE $*"; exit 1; }'
        echo 'wait_for_dpkg_lock() { echo "WAITED $*" >> "'"${TM_TMP}"'/calls"; return 1; }'
        echo 'DPKG_LOCKS=(/d1 /d2); APT_LOCKS=(/a1 /a2); DPKG_LOCK_WAIT_S=7'
        echo 'pkg_installed() { [ "$1" = systemd-timesyncd ]; }'
        echo 'REQUIRED_PKGS=(nginx); ONLINE=true; OPT_INSTALL_CHRONY=true; SCRIPT_DIR=/src'
        tm_extract_func "$INSTALL_SH" install_required_packages
        tm_extract_func "$INSTALL_SH" install_time_daemon
        echo '"$1"'
    } > "${TM_TMP}/o.sh"
    local f rc out ran
    for f in install_required_packages install_time_daemon; do
        : > "${TM_TMP}/calls"; rc=0
        out="$(PATH="${TM_TMP}/bin:${PATH}" bash "${TM_TMP}/o.sh" "$f" 2>&1)" || rc=$?
        tm_assert_rc 1 "$rc" "${f} went on with the package lock held: ${out}"
        grep -qx 'WAITED /d1 /d2 /a1 /a2' "${TM_TMP}/calls" || _tm_afail "${f} does not wait for dpkg's AND apt's locks: $(cat "${TM_TMP}/calls")"
        ran="$(grep -E '^apt-get' "${TM_TMP}/calls" | grep -v -- ' -s ' || true)"
        [ -z "$ran" ] || _tm_afail "${f} ran apt although the lock was held: ${ran}"
        grep -q 'package lock is held' <<<"$out" || _tm_afail "${f}: the failure does not say it is the lock: ${out}"
    done
    true
}
tm_case "a-held-lock-stops-the-online-installs-before-apt" none l_held_lock_stops_the_online_installs

l_upgrade_waits_before_destruction() {
    local p6 w d
    p6="$(tm_extract_between "$UP" '^phase "Phase 6 ' '^phase "Phase 7 ')"
    w="$(grep -n 'wait_for_dpkg_lock "\${DPKG_LOCKS\[@\]}" "\${APT_LOCKS\[@\]}"' <<<"$p6" | cut -d: -f1)"
    d="$(grep -n '^    DESTRUCTIVE_STARTED=true$' <<<"$p6" | cut -d: -f1)"
    tm_assert_nonempty "$w" "Phase 6 does not wait for the package lock"
    tm_assert_nonempty "$d" "Phase 6 lost its DESTRUCTIVE_STARTED anchor"
    [ "$w" -lt "$d" ] || _tm_afail "Phase 6 waits for the lock AFTER it has started changing the host"
    local after
    after="$(sed -n "$((w + 1))p" <<<"$p6")"
    [[ "$after" == *'|| fail '* ]] || _tm_afail "a lock still held does not stop Phase 6: ${after}"
    local p5
    p5="$(tm_extract_between "$UP" '^phase "Phase 5 ' '^phase "Phase 6 ')"
    grep -q 'wait_for_dpkg_lock' <<<"$p5" || _tm_afail "Phase 5 installs git without waiting for the lock"
}
tm_case "the-upgrade-waits-for-the-lock-before-it-changes-anything" none l_upgrade_waits_before_destruction

# ─── the documentation (WO-0004 clean_room 2026-09-29, N2-N6) ───────────────
D_README="${R}/README.md"; D_INSTALL="${R}/docs/INSTALL.md"; D_T="${R}/TROUBLESHOOTING.md"
D_IREADME="${R}/install/README.md"; RULE="${R}/install/polkit/50-topic-manager.rules"

d_polkit_counts_derived() {
    "$(tm_python)" - "$RULE" "$D_README" "$D_INSTALL" "$D_IREADME" "$D_T" > "${TM_TMP}/pk" 2>&1 <<'PYEOF'
import re, sys
words = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve".split())}
rule = open(sys.argv[1], encoding="utf-8").read()
body = rule[rule.index("polkit.addRule"):]
pairs, units = 0, set()
for cond in re.findall(r'if \(([^{]*?)\) \{\s*return polkit\.Result\.YES;', body):
    us = re.findall(r'unit === "([^"]+)"', cond)
    vs = re.findall(r'verb === "([^"]+)"', cond)
    pairs += len(us) * len(vs); units.update(us)
print("DERIVED %d pairs over %d units" % (pairs, len(units)))
if pairs == 0:
    print("FAIL: no YES clause parsed from the rule"); sys.exit(1)
bad, seen = [], 0
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r'(\w+)\s+(?:systemd\s+)?unit/verb pairs', text):
        seen += 1
        n = words.get(m.group(1).lower())
        if n != pairs:
            bad.append("%s: '%s' (the rule has %d)" % (path.rsplit("/", 1)[-1], m.group(0), pairs))
        win = text[max(0, m.start() - 80):m.end() + 80]
        for u in re.finditer(r'(\w+)\s+units\b', win):
            k = words.get(u.group(1).lower())
            if k is not None and k != len(units):
                bad.append("%s: '%s' (the rule has %d units)" % (path.rsplit("/", 1)[-1], u.group(0), len(units)))
print("SEEN %d" % seen)
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PYEOF
    local rc=$?
    [ "$rc" -eq 0 ] || _tm_afail "CLEAN-ROOM N3: a count of the polkit rule's pairs is not the rule's: $(cat "${TM_TMP}/pk")"
    tm_assert_grep "DERIVED 8 pairs over 7 units" "${TM_TMP}/pk" "the rule is not the eight pairs over seven units this release reviewed"
    local seen; seen="$(sed -n 's/^SEEN //p' "${TM_TMP}/pk")"
    [ "${seen:-0}" -ge 5 ] || _tm_afail "only ${seen:-0} unit/verb-pair counts found (README x2, INSTALL, install/README, TROUBLESHOOTING, the rule)"
}
tm_case "every-polkit-pair-count-is-the-rules-own" none d_polkit_counts_derived

d_one_firewall_truth() {
    local line
    line="$(grep -E '^- Opens .*ufw' "$D_README")"
    tm_assert_nonempty "$line" "README's install list has no firewall line"
    grep -q '80 and 443' <<<"$line" && _tm_afail "CLEAN-ROOM N4: README still says ufw opens 80 and 443: ${line}"
    grep -q '80/tcp only while the HTTP redirect is on' <<<"$line" || _tm_afail "README does not say 80 opens only with the redirect: ${line}"
    grep -q '80 only while the HTTP redirect is on' "$D_INSTALL" || _tm_afail "INSTALL no longer says 80 opens only with the redirect"
    grep -q 'ports=(443/tcp)' "$INSTALL_SH" || _tm_afail "install.sh no longer opens 443 alone by default"
}
tm_case "readme-and-install-agree-on-the-firewall" none d_one_firewall_truth

d_detached() {
    local f
    for f in "$D_README" "$D_INSTALL"; do
        grep -qF 'sudo setsid nohup bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --offline' "$f" \
            || _tm_afail "CLEAN-ROOM N2: $(basename "$f") does not say to run the upgrade detached"
        grep -q '> ~/tm-upgrade.out 2>&1 < /dev/null &' "$f" || _tm_afail "$(basename "$f"): the detached run has no log file"
        grep -q 'tmux new -s tm-upgrade' "$f" || _tm_afail "$(basename "$f") does not give the tmux form"
    done
    true
}
tm_case "docs-say-to-run-the-upgrade-detached-with-a-log" none d_detached

d_ppsm_resolved() {
    local row
    row="$(grep -E '^"App","systemd-resolved","53",' "${R}/PPSM.csv")"
    grep -q '127.0.0.53:53' <<<"$row" || _tm_afail "the resolved row lost 127.0.0.53:53: ${row}"
    grep -q '127.0.0.54:53' <<<"$row" || _tm_afail "CLEAN-ROOM N6: the resolved row does not name 127.0.0.54:53: ${row}"
    grep -q '127.0.0.54:53' "${R}/app/components/SettingsTab.js" || _tm_afail "the downloaded PPSM does not name 127.0.0.54:53"
    grep -q '"127.0.0.54:53"' "${R}/tools/check-ppsm-consistency.sh" || _tm_afail "the PPSM gate does not pin 127.0.0.54:53"
}
tm_case "ppsm-names-both-resolved-stubs" none d_ppsm_resolved

d_troubleshooting() {
    tm_assert_grep 'The package lock is STILL held after 600s' "$D_T" "TROUBLESHOOTING has no row for a held package lock"
    tm_assert_grep 'The package lock is STILL held after' "$INSTALL_SH" "install.sh no longer prints the text TROUBLESHOOTING documents"
    tm_assert_grep 'RESTORE INCOMPLETE' "$D_T" "TROUBLESHOOTING does not describe the restore verdict"
    tm_assert_grep 'RESTORE INCOMPLETE' "$D_README" "README does not describe the restore verdict"
    tm_assert_grep 'RESTORE INCOMPLETE' "$UP" "the upgrade no longer prints the verdict the docs describe"
    tm_assert_grep '/run/topic-manager-apply' "$D_README" "README does not say the retired units' runtime directory is removed"
}
tm_case "troubleshooting-covers-the-lock-and-the-restore-verdict" none d_troubleshooting

# ─── round 7 (clean-room round 6, M1): a detached run's exit code ────────────
# The docs judge the run by its exit code and run it detached, which throws
# the code away. The script prints it as its last line; the docs say to read
# that line. Both sides, and they must agree.
d_result_line() {
    local out rc f
    # The REAL script, early exits (nothing on the host is touched: both stop
    # at option parsing): the last line is the exit code, whatever it is.
    rc=0; out="$(bash "$UP" --no-such-option 2>&1)" || rc=$?
    tm_assert_rc 2 "$rc" "an unknown option did not exit 2"
    tm_assert_eq "RESULT: exit 2" "$(tail -n 1 <<<"$out")" "CLEAN-ROOM M1: the last line of an early exit is not its exit code"
    rc=0; out="$(bash "$UP" --restore 2>&1)" || rc=$?
    tm_assert_eq "RESULT: exit ${rc}" "$(tail -n 1 <<<"$out")" "CLEAN-ROOM M1: --restore without a timestamp does not end with its exit code"
    # _on_exit — the trap of the destructive phases — after its rollback.
    {
        echo 'rollback() { echo "ROLLED BACK"; }'
        tm_extract_line "$UP" '^result_line\(\) \{'
        tm_extract_func "$UP" _on_exit
        echo 'trap _on_exit EXIT'
        echo 'exit "$1"'
    } > "${TM_TMP}/exit.sh"
    rc=0; out="$(bash "${TM_TMP}/exit.sh" 3 2>&1)" || rc=$?
    tm_assert_rc 3 "$rc" "_on_exit changed the exit code"
    tm_assert_eq "ROLLED BACK|RESULT: exit 3" "$(tr '\n' '|' <<<"$out" | sed 's/|$//')" \
        "CLEAN-ROOM M1: a failed upgrade does not end with RESULT after its rollback"
    rc=0; out="$(bash "${TM_TMP}/exit.sh" 0 2>&1)" || rc=$?
    tm_assert_eq "RESULT: exit 0" "$out" "a finished upgrade does not end with RESULT: exit 0"
    # The docs give the same line and say how to read it.
    for f in "$D_README" "$D_INSTALL"; do
        grep -qF 'tail -n 1 ~/tm-upgrade.out' "$f" || _tm_afail "$(basename "$f") does not say how to read a detached run's result"
        grep -qF 'RESULT: exit 0' "$f" || _tm_afail "$(basename "$f") does not give the success line the script prints"
        grep -qF 'RESULT: exit <N>' "$f" || _tm_afail "$(basename "$f") does not give the failure line"
        grep -qF 'RESTORE INCOMPLETE' "$f" || _tm_afail "$(basename "$f") does not say what 1 means for --restore"
    done
    grep -qF "result_line() { echo \"RESULT: exit \$1\"; }" "$UP" || _tm_afail "the script's line is not the one the docs give"
}
tm_case "a-detached-run-ends-with-its-exit-code-and-the-docs-say-so" none d_result_line

tm_finish
