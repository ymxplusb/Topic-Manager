#!/usr/bin/env bash
# =============================================================================
# t46 — v1.2.0 ROUND 5: the pre-tag Sonar gate is the ESTATE's gate and cleans
# up after itself; the clean-room documentation defects stay fixed.
#
#   * tools/sonar-local.sh holds the project to a copy of "Jarvis Standard"
#     (the gate project topic-manager is on, read from the estate server
#     2026-09-29) and evaluates EVERY condition: the real evaluate_gate on
#     fixture answers, one condition failing at a time, and the two named
#     known differences (S4502 at tm/app.py; overall hotspot review);
#   * run against a fake docker: a server that dies while starting fails the
#     run at once (exit 2, not a 600 s wait), every volume it created is
#     removed and so is its network; a docker disk at 90% is refused before
#     anything is created;
#   * the eight clean-room documentation defects (WO-0004 clean_room).
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "sonar-local is the estate gate and leaves nothing; the clean-room docs hold"

R="$TM_REPO_ROOT"
S="${TM_SONAR_LOCAL:-${R}/tools/sonar-local.sh}"

# ─── the gate definition ─────────────────────────────────────────────────────
g_gate_is_jarvis_standard() {
    local got want
    got="$(sed -n '/^JARVIS_GATE=($/,/^)$/p' "$S" | grep -oE '"[a-z_]+ (GT|LT) [0-9]+"' | tr -d '"' | sort)"
    want="$(printf '%s\n' "bugs GT 0" "new_duplicated_lines_density GT 3" "new_security_hotspots_reviewed LT 100" \
        "new_violations GT 0" "reliability_rating GT 1" "security_hotspots_reviewed LT 100" "vulnerabilities GT 0" | sort)"
    tm_assert_eq "$want" "$got" "sonar-local's copy of the estate gate is not Jarvis Standard's seven conditions"
    grep -qx 'KNOWN_VULN_DIFFERENCES=("S4502 tm/app.py")' "$S" \
        || _tm_afail "the known S4502 difference is not the one declared, or not declared"
    grep -q 'api POST "qualitygates/set_as_default?name=${qname}"' "$S" \
        || _tm_afail "the gate copy is not made the project's gate before the scans"
    local setdef scan1
    setdef="$(grep -n 'qualitygates/set_as_default' "$S" | cut -d: -f1)"; setdef="$(sed -n 1p <<<"$setdef")"
    scan1="$(grep -n '^scan "\$base_sha"' "$S" | cut -d: -f1)"
    [ "$setdef" -lt "$scan1" ] || _tm_afail "the gate is set after the scans: they would be judged by Sonar way"
    grep -qx 'evaluate_gate "$WORK" "$GATE_NAME" "${head_sha:0:12} vs ${BASE_REF}"' "$S" \
        || _tm_afail "the verdict is not evaluate_gate"
}
tm_case "sonar-local-holds-the-project-to-jarvis-standard" none g_gate_is_jarvis_standard

# _eval <status-conditions-json> <measures-json> <vulns-json> [gate-name]
_eval() {
    local d="${TM_TMP}/g"; mkdir -p "$d"
    printf '{"qualityGate":{"name":"%s"}}' "${4:-G}" > "$d/v-gate.json"
    printf '{"projectStatus":{"status":"X","conditions":%s}}' "$1" > "$d/v-status.json"
    printf '{"component":{"measures":%s}}' "$2" > "$d/v-measures.json"
    printf '{"issues":%s}' "$3" > "$d/v-vulns.json"
    {
        echo 'set -uo pipefail'
        sed -n '/^JARVIS_GATE=($/,/^)$/p' "$S"
        grep -E '^KNOWN_VULN_DIFFERENCES=' "$S"
        tm_extract_func "$S" evaluate_gate
        echo 'evaluate_gate "$1" G "fixture"'
    } > "${TM_TMP}/ev.sh"
    RC=0; OUT="$(bash "${TM_TMP}/ev.sh" "$d" 2>&1)" || RC=$?
}
_c() { printf '{"metricKey":"%s","status":"%s","actualValue":"%s"}' "$1" "$2" "$3"; }
# Six conditions evaluated OK; new_security_hotspots_reviewed has no value
# (no new hotspot), exactly as the estate server answered for v1.1.1.
_ok_except() {   # _ok_except <metric> <actual> -> the conditions JSON with that one ERROR
    local out="" m st a
    for m in new_violations:0 new_duplicated_lines_density:0.0 bugs:0 vulnerabilities:0 reliability_rating:1 security_hotspots_reviewed:100.0; do
        st=OK; a="${m#*:}"; m="${m%%:*}"
        [ "$m" = "$1" ] && { st=ERROR; a="$2"; }
        out="${out}${out:+,}$(_c "$m" "$st" "$a")"
    done
    [ "$1" = new_security_hotspots_reviewed ] && out="${out},$(_c new_security_hotspots_reviewed ERROR "$2")"
    echo "[${out}]"
}
M_OK='[{"metric":"new_violations","period":{"value":"0"}},{"metric":"bugs","value":"0"}]'
V_S4502='{"rule":"python:S4502","component":"topic-manager:tm/app.py","line":46,"message":"csrf"}'
V_OTHER='{"rule":"python:S2076","component":"topic-manager:tm/routes.py","line":9,"message":"cmd"}'

e_all_ok() {
    _eval "$(_ok_except none 0)" "$M_OK" '[]'
    tm_assert_rc 0 "$RC" "a clean project did not pass: ${OUT}"
    grep -q 'new_security_hotspots_reviewed.*no value' <<<"$OUT" || _tm_afail "the no-value condition is not accounted for: ${OUT}"
}
tm_case "gate-every-condition-ok-passes" none e_all_ok

e_each_condition_fails_alone() {
    local m
    for m in new_violations:2 new_duplicated_lines_density:7.5 new_security_hotspots_reviewed:0.0 bugs:1 reliability_rating:3; do
        _eval "$(_ok_except "${m%%:*}" "${m#*:}")" "$M_OK" '[]'
        tm_assert_rc 1 "$RC" "${m%%:*} failing on the estate gate passed here: ${OUT}"
        grep -q "FAIL: ${m%%:*}" <<<"$OUT" || _tm_afail "the failure does not name ${m%%:*}: ${OUT}"
    done
}
tm_case "gate-each-condition-failing-alone-fails-the-run" none e_each_condition_fails_alone

e_known_vuln() {
    _eval "$(_ok_except vulnerabilities 1)" "$M_OK" "[${V_S4502}]"
    tm_assert_rc 0 "$RC" "the known S4502 difference failed the run: ${OUT}"
    grep -q 'KNOWN DIFFERENCE' <<<"$OUT" || _tm_afail "the S4502 exception is applied silently: ${OUT}"
    _eval "$(_ok_except vulnerabilities 2)" "$M_OK" "[${V_S4502},${V_OTHER}]"
    tm_assert_rc 1 "$RC" "a vulnerability beside S4502 passed: ${OUT}"
    _eval "$(_ok_except vulnerabilities 1)" "$M_OK" "[${V_OTHER}]"
    tm_assert_rc 1 "$RC" "a vulnerability that is not the known one passed: ${OUT}"
    _eval "$(_ok_except vulnerabilities 3)" "$M_OK" "[${V_S4502}]"
    tm_assert_rc 2 "$RC" "a vulnerability count the list does not account for was treated as known: ${OUT}"
}
tm_case "gate-only-the-named-s4502-difference-is-excused" none e_known_vuln

e_overall_hotspots_reported() {
    _eval "$(_ok_except security_hotspots_reviewed 0.0)" "$M_OK" '[]'
    tm_assert_rc 0 "$RC" "overall hotspot review (estate state) decided the run: ${OUT}"
    grep -q 'security_hotspots_reviewed.*KNOWN DIFFERENCE' <<<"$OUT" || _tm_afail "the overall hotspot result is not reported: ${OUT}"
}
tm_case "gate-overall-hotspot-review-is-reported-not-hidden" none e_overall_hotspots_reported

e_unevaluated_is_not_a_pass() {
    _eval "$(_ok_except none 0)" '[{"metric":"new_security_hotspots_reviewed","period":{"value":"50.0"}}]' '[]'
    tm_assert_rc 2 "$RC" "a condition the server did not evaluate, with a value, passed: ${OUT}"
    _eval "$(_ok_except none 0)" "$M_OK" '[]' "Sonar way"
    tm_assert_rc 2 "$RC" "a run judged by another gate passed: ${OUT}"
}
tm_case "gate-an-unevaluated-condition-or-another-gate-is-exit-2" none e_unevaluated_is_not_a_pass

# The verdict block itself, from "the verdict" to the end of the script, with
# api() answering from fixtures: its exit code IS the gate's.
e_verdict_block_exits_with_the_gate() {
    local d="${TM_TMP}/vb"; mkdir -p "$d/fx"
    printf '{"issues":[]}' > "$d/fx/issues"
    printf '{"qualityGate":{"name":"Jarvis Standard (sonar-local copy)"}}' > "$d/fx/gate"
    printf '{"projectStatus":{"conditions":%s}}' "$(_ok_except bugs 2)" > "$d/fx/status"
    printf '{"component":{"measures":%s}}' "$M_OK" > "$d/fx/measures"
    printf '{"issues":[]}' > "$d/fx/vulns"
    {
        echo 'set -uo pipefail'
        echo 'die2() { echo "DIE2 $*"; exit 2; }'
        echo 'WORK="'"$d"'"; PROJECT_KEY=topic-manager; head_sha=0123456789abcdef; BASE_REF=base'
        echo 'GATE_NAME="Jarvis Standard (sonar-local copy)"'
        echo 'api() { case "$2" in issues/search*VULNERABILITY*) cat "$WORK/fx/vulns" ;; issues/search*) cat "$WORK/fx/issues" ;;'
        echo '  qualitygates/get_by_project*) cat "$WORK/fx/gate" ;; qualitygates/project_status*) cat "$WORK/fx/status" ;;'
        echo '  measures/component*) cat "$WORK/fx/measures" ;; *) return 1 ;; esac; }'
        sed -n '/^JARVIS_GATE=($/,/^)$/p' "$S"
        grep -E '^KNOWN_VULN_DIFFERENCES=' "$S"
        tm_extract_func "$S" evaluate_gate
        sed -n '/^# ─── the verdict ─/,$p' "$S"
    } > "${TM_TMP}/vb.sh"
    grep -q 'evaluate_gate "\$WORK"' "${TM_TMP}/vb.sh" || tm_die "the verdict block was not extracted"
    RC=0; OUT="$(bash "${TM_TMP}/vb.sh" 2>&1)" || RC=$?
    tm_assert_rc 1 "$RC" "the script's exit code is not the gate's (bugs failing): ${OUT}"
    printf '{"projectStatus":{"conditions":%s}}' "$(_ok_except none 0)" > "$d/fx/status"
    RC=0; OUT="$(bash "${TM_TMP}/vb.sh" 2>&1)" || RC=$?
    tm_assert_rc 0 "$RC" "a clean gate did not exit 0 through the verdict block: ${OUT}"
}
tm_case "sonar-local-exits-with-the-gate-verdict" none e_verdict_block_exits_with_the_gate

# ─── a fake docker: the dead server, the volumes, the full disk ──────────────
_fake_env() {
    local F="${TM_TMP}/fake"; mkdir -p "$F/bin" "$F/root"
    : > "$F/calls"; : > "$F/vols"
    cat > "$F/bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
F="$FAKE_DIR"; echo "docker $*" >> "$F/calls"
case "$1" in
  info) [ "${2:-}" = -f ] && echo "$F/root"; exit 0 ;;
  network) echo net; exit 0 ;;
  image)
    if [ "${3:-}" = -f ]; then echo "/opt/sonarqube/data /opt/sonarqube/extensions /opt/sonarqube/logs /opt/sonarqube/temp "; fi
    exit 0 ;;
  volume)
    case "$2" in
      create) printf '%s\t%s\n' "$4" "$5" >> "$F/vols"; echo "$5" ;;
      ls) lbl="${5#label=}"; awk -F'\t' -v l="$lbl" '$1 == l { print $2 }' "$F/vols" ;;
      rm) awk -F'\t' -v n="$4" '$2 != n' "$F/vols" > "$F/vols.n"; mv "$F/vols.n" "$F/vols" ;;
    esac
    exit 0 ;;
  run) echo cid; exit 0 ;;
  inspect) case "$3" in *Running*) echo false ;; *ExitCode*) echo 137 ;; esac; exit 0 ;;
  logs) echo "fake: elasticsearch bootstrap checks failed"; exit 0 ;;
  exec) exit 1 ;;
  rm) exit 0 ;;
esac
exit 0
FAKEDOCKER
    printf '#!/usr/bin/env bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 100 %s %s %s%% /"\n' \
        "$1" "$((100 - $1))" "$1" > "$F/bin/df"
    chmod +x "$F/bin/docker" "$F/bin/df"
    # Two commits with a VERSION each, named where sonar-local reads them.
    local G="${TM_TMP}/repo"
    git init -q "$G" && git -C "$G" config user.email t@t && git -C "$G" config user.name t
    echo 1.0.0 > "$G/VERSION"; git -C "$G" add VERSION; git -C "$G" commit -qm a
    BSHA="$(git -C "$G" rev-parse HEAD)"
    echo 1.1.0 > "$G/VERSION"; git -C "$G" commit -qam b
    HSHA="$(git -C "$G" rev-parse HEAD)"
    git -C "$G" update-ref refs/sonar-local/base "$BSHA"; git -C "$G" update-ref refs/sonar-local/head "$HSHA"
    git -C "$G" bundle create "${TM_TMP}/src.bundle" refs/sonar-local/base refs/sonar-local/head >/dev/null 2>&1 \
        || tm_die "could not build the fixture bundle"
}
_run_fake() {
    local t0=$SECONDS
    RC=0; OUT="$(TM_SONAR_UP_TIMEOUT_S=20 FAKE_DIR="${TM_TMP}/fake" PATH="${TM_TMP}/fake/bin:${PATH}" \
        bash "$S" --bundle "${TM_TMP}/src.bundle" --base "$BSHA" --head "$HSHA" 2>&1)" || RC=$?
    ELAPSED=$((SECONDS - t0))
}

f_dead_server_fails_fast_and_cleans_up() {
    _fake_env 50
    _run_fake
    tm_assert_rc 2 "$RC" "a server that died while starting was not exit 2: ${OUT}"
    [ "$ELAPSED" -lt 60 ] || _tm_afail "a dead server was polled for ${ELAPSED}s instead of failing at once"
    grep -q 'stopped while starting' <<<"$OUT" || _tm_afail "the failure does not say the server died: ${OUT}"
    grep -q 'elasticsearch bootstrap checks failed' <<<"$OUT" || _tm_afail "the server's last log lines are not shown"
    local created
    created="$(grep -c '^docker volume create ' "${TM_TMP}/fake/calls")"
    tm_assert_eq 4 "$created" "not one named volume per image VOLUME"
    [ -s "${TM_TMP}/fake/vols" ] && _tm_afail "volumes left behind: $(cat "${TM_TMP}/fake/vols")"
    grep -qE '^docker rm -f -v ' "${TM_TMP}/fake/calls" || _tm_afail "containers are removed without their volumes (rm -f without -v)"
    grep -qE '^docker network rm ' "${TM_TMP}/fake/calls" || _tm_afail "the network is not removed"
    grep -qE '^docker run -d --rm ' "${TM_TMP}/fake/calls" && _tm_afail "the server runs with --rm: a dead one leaves no logs to read"
    true
}
tm_case "sonar-local-dead-server-fails-fast-and-leaves-no-volume" none f_dead_server_fails_fast_and_cleans_up

f_full_disk_refused() {
    _fake_env 90
    _run_fake
    tm_assert_rc 2 "$RC" "a 90%-full docker disk was not refused: ${OUT}"
    grep -q '90% full' <<<"$OUT" || _tm_afail "the refusal does not give the measurement: ${OUT}"
    grep -qE '^docker (network create|volume create|run) ' "${TM_TMP}/fake/calls" \
        && _tm_afail "something was created on a full disk: $(cat "${TM_TMP}/fake/calls")"
    _fake_env 89
    _run_fake
    grep -q '% full' <<<"$OUT" && _tm_afail "an 89% disk was refused: ${OUT}"
    true
}
tm_case "sonar-local-refuses-a-docker-disk-at-90-percent" none f_full_disk_refused

# ─── the clean-room documentation (WO-0004 clean_room, 2026-09-29) ──────────
I="${R}/docs/INSTALL.md"; RD="${R}/README.md"; T="${R}/TROUBLESHOOTING.md"; P="${R}/prepare-offline.sh"

d_docs() {
    # 1. the build-host prerequisites in both forms
    grep -qxF 'sudo apt-get update && sudo apt-get install -y git python3 python3-pip curl apt-utils' "$I" || _tm_afail "INSTALL 5a lost the server form"
    grep -qxF 'apt-get update && apt-get install -y git python3 python3-pip curl apt-utils' "$I" || _tm_afail "INSTALL 5a has no sudo-less container form"
    # 2. no localhost TLS 1.1 probe anywhere
    grep -nE 's_client -connect (localhost|127\.0\.0\.1)[^ ]* -tls1(_1)?' "$I" "$T" "$RD" && _tm_afail "a TLS 1.1 probe from localhost is still documented"
    grep -qF "s_client -connect <server-name>:443 -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0'" "$T" || _tm_afail "TROUBLESHOOTING has no server-side probe"
    # 3. OpenSSL 3, not LibreSSL
    for f in "$I" "$T"; do grep -q 'LibreSSL' "$f" || _tm_afail "$(basename "$f") does not say the probe needs OpenSSL 3"; done
    # 4. a refused handshake prints Cipher is (NONE) too
    grep -qF 'New, (NONE), Cipher is (NONE)' "$I" || _tm_afail "INSTALL 7 does not show what a refusal's Cipher line looks like"
    grep -qF 'Cipher is <a cipher name>' "$I" || _tm_afail "INSTALL 7 does not define acceptance as a real cipher name"
    grep -qF 'New, TLSv1.1, Cipher is ...' "$I" && _tm_afail "INSTALL 7 still reads any 'Cipher is' as acceptance"
    # 6. --restore by absolute path
    grep -nE 'bash install/upgrade-full\.sh --restore' "$RD" "$T" && _tm_afail "a relative --restore is still documented"
    grep -qF 'sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --restore' "$RD" || _tm_afail "README Rolling back has no absolute --restore"
    grep -qF 'sudo bash /var/lib/topic-manager/offline-src/install/upgrade-full.sh --restore' "$T" || _tm_afail "TROUBLESHOOTING Rollback has no absolute --restore"
    # 7. ONE fresh offline install procedure: README, INSTALL 5b, prepare-offline
    local f
    for f in "$I" "$RD" "$P"; do
        grep -qF 'sudo install -d -m 700 -o root -g root /var/lib/topic-manager/install-src' "$f" || _tm_afail "$(basename "$f") does not stage the install tree root-owned"
        grep -qF -- '-C /var/lib/topic-manager/install-src --strip-components=1' "$f" || _tm_afail "$(basename "$f") does not unpack into install-src"
        grep -qF 'sudo bash /var/lib/topic-manager/install-src/install.sh' "$f" || _tm_afail "$(basename "$f") does not run install.sh by its staged path"
        grep -qE 'offline-.*\.tar\.gz && cd topic-manager-' "$f" && _tm_afail "$(basename "$f") still has the unpack-and-cd procedure"
    done
    # 8. the README unit list names the socket and the apply-audit path unit
    local units
    units="$(grep -E '^- (Installs the systemd service|v1\.2\.0: installs the root apply helper)' "$RD")"
    grep -q 'topic-manager.socket' <<<"$units" || _tm_afail "README's install list misses topic-manager.socket"
    grep -q 'topic-manager-apply-audit.path' <<<"$units" || _tm_afail "README's install list misses topic-manager-apply-audit.path"
    true
}
tm_case "clean-room-documentation-defects-stay-fixed" none d_docs

d_ppsm_postfix() {
    # 5. Postfix as found (all interfaces), with the hardening option; the
    #    installer leaves it alone.
    local row
    row="$(grep -E '^"Host","Postfix \(MTA\)","25","TCP",' "${R}/PPSM.csv")"
    tm_assert_nonempty "$row" "PPSM has no Postfix row"
    grep -q '"Inbound"' <<<"$row" || _tm_afail "PPSM still calls Postfix loopback-only: ${row}"
    grep -q 'inet_interfaces = all' <<<"$row" || _tm_afail "the Postfix row does not describe what the host does"
    grep -q 'inet_interfaces = loopback-only' <<<"$row" || _tm_afail "the Postfix row does not name the hardening option"
    grep -q 'postconf -e inet_interfaces=loopback-only' "$I" || _tm_afail "INSTALL does not document the hardening"
    grep -nE 'postconf|inet_interfaces' "${R}/install.sh" "${R}/install/upgrade-full.sh" \
        && _tm_afail "the installer now changes the host MTA, which the docs say it leaves alone"
    true
}
tm_case "ppsm-postfix-row-is-the-host-as-found" none d_ppsm_postfix

tm_finish
