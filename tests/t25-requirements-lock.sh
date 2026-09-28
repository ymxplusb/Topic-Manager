#!/usr/bin/env bash
# =============================================================================
# t25 — EVERY PYTHON PACKAGE IS HASH-LOCKED (round 2, sec-review).
#
# requirements.lock pins every package, transitive ones included, with the
# SHA-256 of every published wheel; install.sh, install/upgrade-full.sh and
# prepare-offline.sh all install/download FROM IT with --require-hashes and
# --only-binary :all:, with no pip self-upgrade and no unrestricted fallback.
# tools/check-requirements-lock.sh holds the lock to requirements.txt; this
# file runs it and proves it can fail (on copies).
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "requirements.lock is complete, agrees, and is what every installer uses"

GATE="${TM_REPO_ROOT}/tools/check-requirements-lock.sh"
[ -f "$GATE" ] || tm_die "tools/check-requirements-lock.sh is missing"

l_agrees() {
    # Structure and agreement, deterministically: curl is stubbed to fail and
    # TM_LOCK_OFFLINE_OK=1 explicitly accepts a structure-only result (round 9:
    # offline is otherwise exit 3). The online completeness and HASH checks
    # are driven below against a fake PyPI (l_completeness, h_*).
    mkdir -p "${TM_TMP}/nobin"; printf '#!/bin/sh\nexit 7\n' > "${TM_TMP}/nobin/curl"; chmod +x "${TM_TMP}/nobin/curl"
    PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=1 bash "$GATE" > "${TM_TMP}/out" 2>&1 || _tm_afail "the lock is inconsistent: $(cat "${TM_TMP}/out")"
}
tm_case "the-lock-agrees-with-requirements-txt" none l_agrees

_copy() { mkdir -p "${TM_TMP}/c"; cp "${TM_REPO_ROOT}/requirements.txt" "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/c/"; }
l_red_on_drift() {
    _copy
    sed -i 's/^confluent-kafka==2\.15\.1\([[:space:]]\)/confluent-kafka==2.15.0\1/' "${TM_TMP}/c/requirements.lock"
    cmp -s "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/c/requirements.lock" && tm_die "the drift fixture changed nothing"
    bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a lock pinning a different version than requirements.txt passed"
    _copy
    awk '/^cffi==/{print "cffi==2.1.1"; skip=1; next} skip && /^    --hash/{next} {skip=0; print}' \
        "${TM_REPO_ROOT}/requirements.lock" > "${TM_TMP}/c/requirements.lock"
    bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a lock entry with NO hash passed"
    return 0
}
tm_case "the-gate-goes-red-on-drift-and-on-a-missing-hash" none l_red_on_drift

l_installers_use_it() {
    local f UP IN; UP="$(tm_upgrade_sh)"; IN="$(tm_install_sh)"
    for f in "$IN" "$UP" "${TM_REPO_ROOT}/prepare-offline.sh"; do
        grep -q -- '--require-hashes' "$f" || _tm_afail "${f} does not use --require-hashes"
        grep -q 'requirements.lock' "$f" || _tm_afail "${f} does not use requirements.lock"
        grep -nE '^[^#]*pip"? install --upgrade pip' "$f" > "${TM_TMP}/h" \
            && _tm_afail "${f} still self-upgrades pip outside the lock: $(cat "${TM_TMP}/h")"
    done
    # Continuation lines joined first: a pip call spans several lines.
    for f in "$IN" "${TM_REPO_ROOT}/prepare-offline.sh"; do
        awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' "$f" \
            | grep -E '^[[:space:]]*pip (install|download)' | grep -v -- '--only-binary' > "${TM_TMP}/h" \
            && _tm_afail "${f}: a pip call without --only-binary: $(cat "${TM_TMP}/h")"
    done
    grep -qx 'PIP_ARGS=(--require-hashes --only-binary :all:)' "$UP" \
        || _tm_afail "the upgrade's pip install no longer starts from --require-hashes --only-binary :all:"
    grep -q -- '--no-index --require-hashes --only-binary :all: --find-links' "$IN" \
        || _tm_afail "install.sh's offline pip install is not hash-locked"
    grep -q '^    -r "\$REQ_FILE"$' "${TM_REPO_ROOT}/prepare-offline.sh" \
        && _tm_afail "prepare-offline.sh still has the unrestricted pip download fallback" || true
    return 0
}
tm_case "every-installer-uses-the-lock-with-hashes-and-no-fallback" none l_installers_use_it

# The upgrade holds the lock to requirements.txt before it installs: driven
# through the REAL loop against a lock that has drifted.
l_upgrade_refuses_a_drifted_lock() {
    local UP; UP="$(tm_upgrade_sh)"
    {
        echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'declare -A PINS=([flask]=3.1.3 [werkzeug]=3.1.8 [gunicorn]=26.2.0 [ldap3]=2.9.1 [pyyaml]=6.0.3 [cryptography]=50.0.1 [confluent-kafka]=2.15.1)'
        echo 'LOCK_FILE="$1"'
        TM_S='^for _pin in flask werkzeug gunicorn ldap3 pyyaml cryptography confluent-kafka; do$' \
            awk 'BEGIN{s=ENVIRON["TM_S"]} !on && $0 ~ s {on=1} on{print} on && /^done$/{exit}' "$UP"
        echo 'echo AGREED'
    } > "${TM_TMP}/lk.sh"
    grep -q '^for _pin in ' "${TM_TMP}/lk.sh" || tm_die "could not extract the lock check"
    bash "${TM_TMP}/lk.sh" "${TM_REPO_ROOT}/requirements.lock" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "the real lock was refused: $(cat "${TM_TMP}/out")"
    sed 's/^cryptography==50\.0\.1 /cryptography==44.0.2 /' "${TM_REPO_ROOT}/requirements.lock" > "${TM_TMP}/drift.lock"
    bash "${TM_TMP}/lk.sh" "${TM_TMP}/drift.lock" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "the upgrade accepted a lock pinning cryptography 44.0.2 against requirements.txt 50.0.1"
    return 0
}
tm_case "the-upgrade-refuses-a-lock-that-disagrees-with-the-pins" none l_upgrade_refuses_a_drifted_lock


# ─── round 8 (gatekeeper): lock hashes, lock completeness, SCA, SBOM ─────────
_offline() { mkdir -p "${TM_TMP}/nobin"; printf '#!/bin/sh\nexit 7\n' > "${TM_TMP}/nobin/curl"; chmod +x "${TM_TMP}/nobin/curl"; }

l_transitive_hash_format() {
    local bad
    for bad in upper short; do
        _copy
        case "$bad" in
            upper) awk '/^MarkupSafe==/{m=1} m && /--hash=sha256:/{sub(/sha256:[0-9a-f]/, "sha256:A"); m=0} {print}' \
                       "${TM_REPO_ROOT}/requirements.lock" > "${TM_TMP}/c/requirements.lock" ;;
            short) awk '/^MarkupSafe==/{m=1} m && /--hash=sha256:/{sub(/sha256:[0-9a-f]/, "sha256:"); m=0} {print}' \
                       "${TM_REPO_ROOT}/requirements.lock" > "${TM_TMP}/c/requirements.lock" ;;
        esac
        cmp -s "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/c/requirements.lock" && tm_die "the ${bad} fixture changed nothing"
        PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=0 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
            && _tm_afail "a TRANSITIVE entry with a ${bad} sha256 passed"
        tm_assert_grep "markupsafe has a malformed hash" "${TM_TMP}/out" "the ${bad} hash on a transitive entry was not named"
    done
}
_offline_wrap() { _offline; l_transitive_hash_format; }
tm_case "a-malformed-hash-on-a-transitive-entry-is-caught" none _offline_wrap

l_completeness() {
    _offline; _copy
    # Offline (round 9, B2): the printed verdict and the exit code agree — it
    # is exit 3 "could not verify", even for a lock MISSING a package, unless
    # TM_LOCK_OFFLINE_OK=1 explicitly accepts a structure-only result.
    local rc=0
    PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=0 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_rc 3 "$rc" "offline, the gate did not exit 3 ($(cat "${TM_TMP}/out"))"
    tm_assert_grep "COULD NOT VERIFY" "${TM_TMP}/out" "offline, the verdict does not say it could not verify"
    rc=0; PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=1 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_rc 0 "$rc" "TM_LOCK_OFFLINE_OK=1 did not accept a structure-only result"
    tm_assert_grep "hashes NOT verified (offline; TM_LOCK_OFFLINE_OK=1)" "${TM_TMP}/out" "the accepted offline result does not print the warning"
    for flag in 0 1; do
        rc=0
        PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK="$flag" "$(tm_python)" "${TM_REPO_ROOT}/tools/gen-requirements-lock.py" --check --root "${TM_TMP}/c" > "${TM_TMP}/gen-out" 2>&1 || rc=$?
        tm_assert_rc "$((3 * (1 - flag)))" "$rc" "generator --check disagrees with the offline policy"
    done
    awk '/^blinker==/{s=1;next} s&&/^    --hash/{next} {s=0;print}' "${TM_REPO_ROOT}/requirements.lock" > "${TM_TMP}/c/requirements.lock"
    rc=0; PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=0 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_rc 3 "$rc" "offline, a lock missing blinker exited ${rc} (the gatekeeper measured 0)"
    # Online: the resolved set is compared. A stub resolver stands in for pip
    # and reports a package the lock lacks — the gate must go red.
    _copy; _fake_pypi
    printf '%s\n' 'import sys' 'print("MISSING from requirements.lock: newdep==1.0 (resolved from requirements.txt)")' 'sys.exit(1)' \
        > "${TM_TMP}/c/tools/gen-requirements-lock.py"
    PATH="${TM_TMP}/on:${PATH}" bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a lock missing a resolved package passed"
    tm_assert_grep "does not cover the resolved set" "${TM_TMP}/out" "the gate failed, but not on completeness"
    printf '%s\n' 'import sys' 'print("could not resolve")' 'sys.exit(3)' > "${TM_TMP}/c/tools/gen-requirements-lock.py"
    rc=0; PATH="${TM_TMP}/on:${PATH}" bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_rc 3 "$rc" "a resolution that failed was not 'could not verify'"
}

# ─── round 9 (gatekeeper B2): the HASHES, against PyPI ───────────────────────
# A fake PyPI: `curl` answers the reachability probe and serves, for every
# name==version in the REAL lock, a JSON release whose files carry exactly the
# lock's hashes. The FIRST TWO hashes are target wheels (cp312 and abi3
# manylinux x86_64); the rest and an extra newly published wheel are macOS
# wheels. Dropping one target hash must fail even with another remaining.
# A stub resolver says the set is complete, so only the hash check decides.
_fake_pypi() {
    local J="${TM_TMP}/pypi"
    mkdir -p "$J" "${TM_TMP}/on" "${TM_TMP}/c/tools"
    tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk -v J="$J" '
        function flush() {
            if (nv == "") return
            f = J "/" nv ".json"
            printf "{\"urls\": [" > f
            for (i = 1; i <= n; i++)
                printf "%s{\"filename\": \"%s-%s-%s-%s.whl\", \"packagetype\": \"bdist_wheel\", \"digests\": {\"sha256\": \"%s\"}}", \
                    (i > 1 ? ", " : ""), name, ver, (i == 2 ? "cp38-abi3" : "cp312-cp312"), (i <= 2 ? "manylinux_2_17_x86_64" : "macosx_11_0_arm64"), h[i] > f
            printf ", {\"filename\": \"%s-%s-cp312-cp312-macosx_11_0_arm64.whl\", \"packagetype\": \"bdist_wheel\", \"digests\": {\"sha256\": \"%s\"}}]}\n", \
                name, ver, "0000000000000000000000000000000000000000000000000000000000000000" > f
            close(f); nv = ""; n = 0
        }
        /^[A-Za-z0-9._-]+==/ { flush(); split($1, p, "=="); name = p[1]; ver = p[2]; nv = name "==" ver; next }
        /--hash=sha256:/ { s = $0; sub(/.*--hash=sha256:/, "", s); sub(/[^0-9a-f].*$/, "", s); h[++n] = s }
        END { flush() }'
    [ "$(find "$J" -name '*.json' | wc -l | tr -d ' ')" -eq 15 ] || tm_die "the fake PyPI was not built for all 15 releases"
    cat > "${TM_TMP}/on/curl" <<STUB
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) shift; out="\$1" ;; -*) ;; *) url="\$1" ;; esac; shift; done
case "\$url" in
    */simple/*) exit 0 ;;
    https://pypi.org/pypi/*/json)
        nv="\${url#https://pypi.org/pypi/}"; nv="\${nv%/json}"; nv="\${nv%%/*}==\${nv#*/}"
        [ -f "${TM_TMP}/pypi/\${nv}.json" ] || exit 22
        cp "${TM_TMP}/pypi/\${nv}.json" "\$out" ;;
    *) exit 7 ;;
esac
STUB
    chmod +x "${TM_TMP}/on/curl"
    printf '%s\n' 'print("requirements.lock covers the resolved set (15 packages)")' > "${TM_TMP}/c/tools/gen-requirements-lock.py"
}
_hash_gate() {
    RC=0; PATH="${TM_TMP}/on:${PATH}" TM_LOCK_OFFLINE_OK=0 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || RC=$?
    local grc=0
    PATH="${TM_TMP}/on:${PATH}" TM_LOCK_OFFLINE_OK=0 "$(tm_python)" "${TM_REPO_ROOT}/tools/gen-requirements-lock.py" --check --root "${TM_TMP}/c" > "${TM_TMP}/gen-out" 2>&1 || grc=$?
    tm_assert_rc "$RC" "$grc" "generator --check disagrees with the gate: $(cat "${TM_TMP}/gen-out")"
}
# _cffi_hash <n> — the n-th hash of cffi in the real lock (1 and 2 = fake target wheels)
_cffi_hash() { tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk -v k="$1" '/^cffi==/{c=1;next} c&&/--hash/{i++; if(i==k){s=$0; sub(/.*sha256:/,"",s); sub(/[^0-9a-f].*$/,"",s); print s}} c&&!/--hash/{c=0}'; }
# _drop_hash <hash> — remove that hash line, keeping the continuation backslashes valid
_drop_hash() {
    tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk -v h="$1" '
        { l[NR] = $0 } END {
            for (i = 1; i <= NR; i++) if (index(l[i], "sha256:" h)) d = i
            if (d && l[d] !~ / \\$/) sub(/ \\$/, "", l[d-1])
            for (i = 1; i <= NR; i++) if (i != d) print l[i] }' > "${TM_TMP}/c/requirements.lock"
}

tm_case "lock-completeness-is-checked-or-exits-3" none l_completeness

h_online_good_lock() {
    _copy; _fake_pypi; _hash_gate
    tm_assert_rc 0 "$RC" "the real lock failed against a PyPI that publishes its hashes: $(cat "${TM_TMP}/out")"
    tm_assert_grep "15 releases: every hash is one PyPI published" "${TM_TMP}/out" "the hash verdict was not printed"
}
tm_case "online-the-real-lock-matches-published-hashes" none h_online_good_lock

h_dropped_target_hash() {
    _copy; _fake_pypi; _drop_hash "$(_cffi_hash 1)"
    cmp -s "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/c/requirements.lock" && tm_die "the drop fixture changed nothing"
    _hash_gate
    tm_assert_rc 1 "$RC" "dropping one of cffi's two target-wheel hashes stayed GREEN — gatekeeper B2"
    tm_assert_grep "cffi==2.1.1 — missing target wheel hash" "${TM_TMP}/out" "the dropped target hash was not named"
}
tm_case "online-a-dropped-target-hash-is-caught" none h_dropped_target_hash

h_altered_hash() {
    local h k new
    for k in 1 3; do
        _copy; _fake_pypi; h="$(_cffi_hash "$k")"
        case "${h: -1}" in 0) new="${h%?}1" ;; *) new="${h%?}0" ;; esac
        sed -i "s/${h}/${new}/" "${TM_TMP}/c/requirements.lock"
        cmp -s "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/c/requirements.lock" && tm_die "the hex fixture changed nothing"
        _hash_gate
        tm_assert_rc 1 "$RC" "one changed hex digit in cffi hash #${k} stayed GREEN — gatekeeper B2"
        tm_assert_grep "is not one PyPI published for this release" "${TM_TMP}/out" "the altered hash #${k} was not named"
    done
}
tm_case "online-one-changed-hex-digit-is-caught" none h_altered_hash

h_no_false_red() {
    # A NON-target hash dropped (pip never picks that file on the target), and
    # a new non-target wheel PyPI published: both GREEN.
    _copy; _fake_pypi; _drop_hash "$(_cffi_hash 3)"
    cmp -s "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/c/requirements.lock" && tm_die "the drop fixture changed nothing"
    _hash_gate
    tm_assert_rc 0 "$RC" "a lock without a non-target hash, beside a newly published non-target wheel, went red: $(cat "${TM_TMP}/out")"
}
tm_case "online-optional-non-target-hashes-are-not-a-false-red" none h_no_false_red

h_target_tags() {
    local tag expected
    for tag in cp312-cp312-manylinux_2_17_x86_64 cp38-abi3-manylinux2014_x86_64 py2.py3-none-any \
               cp313-abi3-manylinux_2_17_x86_64 cp312-cp312-manylinux_2_17_aarch64 \
               cp312-cp312-musllinux_1_2_x86_64 cp312-cp312-manylinux_2_40_x86_64; do
        _copy; _fake_pypi
        "$(tm_python)" - "${TM_TMP}/pypi/cffi==2.1.1.json" "$tag" <<'PY'
import json, sys
path, tag = sys.argv[1:]
data = json.load(open(path))
for i, f in enumerate(data['urls'][:2]):
    f['filename'] = 'cffi-2.1.1-%d-%s.whl' % (i + 1, tag)
with open(path, 'w') as out:
    json.dump(data, out)
PY
        case "$tag" in
            cp312-cp312-manylinux_2_17_x86_64|cp38-abi3-manylinux2014_x86_64|py2.py3-none-any) expected=0 ;;
            *) expected=1 ;;
        esac
        _hash_gate
        tm_assert_rc "$expected" "$RC" "wrong target classification for $tag: $(cat "${TM_TMP}/out")"
    done
}
tm_case "online-target-tags-match-python-312-on-ubuntu-2404" none h_target_tags

h_new_target() {
    _copy; _fake_pypi
    # Turn the extra, unlisted macOS wheel into a target wheel: the documented
    # all-target policy deliberately requires regeneration in this case.
    "$(tm_python)" - "${TM_TMP}/pypi/cffi==2.1.1.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data['urls'][-1]['filename'] = 'cffi-2.1.1-cp312-cp312-manylinux_2_28_x86_64.whl'
with open(path, 'w') as out:
    json.dump(data, out)
PY
    _hash_gate
    tm_assert_rc 1 "$RC" "a newly published target wheel must require regeneration"
    tm_assert_grep "missing target wheel hash" "${TM_TMP}/out" "the new target wheel was not named"
}
tm_case "online-new-target-wheel-requires-regeneration" none h_new_target

h_pypi_silent() {
    _copy; _fake_pypi; rm -f "${TM_TMP}/pypi/cffi==2.1.1.json"; _hash_gate
    tm_assert_rc 3 "$RC" "a release PyPI did not answer for was not 'could not verify'"
    printf '%s\n' '<html>502</html>' > "${TM_TMP}/pypi/cffi==2.1.1.json"
    _hash_gate
    tm_assert_rc 3 "$RC" "an unreadable release answer was not 'could not verify'"
}
tm_case "online-an-unanswered-release-is-exit-3" none h_pypi_silent

SCA="${TM_REPO_ROOT}/tools/sca-check.sh"
s_osv_any_vuln_is_a_finding() {
    {
        echo 'PY="${PYTHON:-python3}"; "$PY" -c "import json" >/dev/null 2>&1 || PY=python'
        tm_extract_func "$SCA" osv_verdict
        echo 'osv_verdict "$1"'
    } > "${TM_TMP}/v.sh"
    local got
    got="$(bash "${TM_TMP}/v.sh" '{}')";  tm_assert_eq "CLEAN" "$got" "an empty OSV answer"
    got="$(bash "${TM_TMP}/v.sh" '{"vulns": []}')"; tm_assert_eq "CLEAN" "$got" "an empty vulns list"
    got="$(bash "${TM_TMP}/v.sh" '{"vulns": [{"id": "BIT-flask-2026-1"}]}')"
    tm_assert_eq "VULN BIT-flask-2026-1" "$got" "an advisory with an unlisted ID prefix was not a finding"
    got="$(bash "${TM_TMP}/v.sh" '{"vulns": [{"summary": "no id"}]}')"
    tm_assert_eq "VULN (no-id)" "$got" "an advisory with no id was not a finding"
    got="$(bash "${TM_TMP}/v.sh" '<html>502</html>')"; tm_assert_eq "BAD" "$got" "an HTML error page"
    got="$(bash "${TM_TMP}/v.sh" '{"message": "rate limited"}')"; tm_assert_eq "BAD" "$got" "an error object"
}
tm_case "sca-any-osv-advisory-is-a-finding-whatever-its-prefix" none s_osv_any_vuln_is_a_finding

s_sca_needs_the_lock() {
    mkdir -p "${TM_TMP}/s/tools"
    cp "$SCA" "${TM_TMP}/s/tools/"; cp "${TM_REPO_ROOT}/requirements.txt" "${TM_TMP}/s/"
    local rc=0
    bash "${TM_TMP}/s/tools/sca-check.sh" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_rc 3 "$rc" "with requirements.lock missing SCA did not refuse: $(cat "${TM_TMP}/out")"
    tm_assert_grep "requirements.lock is missing or unreadable" "${TM_TMP}/out" "the refusal does not say why"
}
tm_case "sca-refuses-without-requirements-lock" none s_sca_needs_the_lock

_sbom_copy() {
    local r="${TM_TMP}/sb"
    mkdir -p "$r/tools" "$r/install" "$r/app/components/modals"
    cp "${TM_REPO_ROOT}/tools/check-sbom-consistency.sh" "$r/tools/"
    cp "${TM_REPO_ROOT}"/requirements.txt "${TM_REPO_ROOT}"/requirements.lock "${TM_REPO_ROOT}"/SBOM.md "${TM_REPO_ROOT}"/NOTICES.md "$r/"
    cp "${TM_REPO_ROOT}/install/upgrade-full.sh" "$r/install/"
    cp "${TM_REPO_ROOT}/app/components/modals/AboutModal.js" "$r/app/components/modals/"
}
b_sbom_transitive() {
    _sbom_copy
    bash "${TM_TMP}/sb/tools/check-sbom-consistency.sh" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "the unmodified copy fails: $(cat "${TM_TMP}/out")"
    tm_assert_grep "transitive packages agree with requirements.lock" "${TM_TMP}/out" "the transitive rows were not checked"
    sed -i 's/^| MarkupSafe | 3\.0\.3 |/| MarkupSafe | 2.1.5 |/' "${TM_TMP}/sb/SBOM.md"
    cmp -s "${TM_REPO_ROOT}/SBOM.md" "${TM_TMP}/sb/SBOM.md" && tm_die "the drift fixture changed nothing"
    bash "${TM_TMP}/sb/tools/check-sbom-consistency.sh" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a transitive SBOM row at the wrong version passed"
    tm_assert_grep "markupsafe" "${TM_TMP}/out" "the wrong transitive row was not named"
    _sbom_copy
    sed -i '/^| pyasn1 | /d' "${TM_TMP}/sb/SBOM.md"
    bash "${TM_TMP}/sb/tools/check-sbom-consistency.sh" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a locked transitive package MISSING from SBOM.md passed"
    tm_assert_grep "pyasn1             NOT in SBOM.md" "${TM_TMP}/out" "the missing transitive row was not named"
}
tm_case "sbom-transitive-rows-are-held-to-the-lock" none b_sbom_transitive

tm_finish
