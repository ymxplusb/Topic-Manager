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
    # REG-0007: an offline pass is a pass of STRUCTURE only, and must say so.
    tm_assert_grep "hashes NOT verified (offline; TM_LOCK_OFFLINE_OK=1)" "${TM_TMP}/out" "offline, the gate passed without saying the closure was not verified"
    # --require-online (the release-time requirement) refuses offline even
    # when TM_LOCK_OFFLINE_OK=1 asks to accept a structure-only result.
    local rc flag
    for flag in 0 1; do
        rc=0
        PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK="$flag" bash "$GATE" --require-online > "${TM_TMP}/out" 2>&1 || rc=$?
        tm_assert_rc 3 "$rc" "--require-online passed with no network (TM_LOCK_OFFLINE_OK=${flag}): $(cat "${TM_TMP}/out")"
    done
    # .gitlab-ci.yml is export-ignored: absent from an archive (--remote, CI tarball).
    [ ! -f "${TM_REPO_ROOT}/.gitlab-ci.yml" ] \
        || grep -q 'check-requirements-lock.sh --require-online' "${TM_REPO_ROOT}/.gitlab-ci.yml" \
        || _tm_afail "CI does not run the lock gate with --require-online"
    # WO-0006 af2: and the CI test lane installs what the installers install:
    # the LOCK, hash-checked, wheels only - never requirements.txt.
    if [ -f "${TM_REPO_ROOT}/.gitlab-ci.yml" ]; then
        local setup; setup="$(grep -E '^[[:space:]]*TEST_SETUP:' "${TM_REPO_ROOT}/.gitlab-ci.yml")"
        tm_assert_eq "1" "$(grep -c 'pip install --quiet --require-hashes --only-binary :all: -r requirements.lock"$' <<<"$setup")" \
            "CI TEST_SETUP does not install requirements.lock with --require-hashes --only-binary :all:: ${setup}"
        grep -q 'requirements[.]txt' <<<"$setup" && _tm_afail "CI TEST_SETUP still installs from requirements.txt: ${setup}"
        grep -q -- '--require-hashes --only-binary :all: -r "$LOCK_FILE"' "$(tm_install_sh)" \
            || _tm_afail "install.sh no longer installs the lock with the flags CI is held to"
    fi
    true
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

# ─── round 10 (gatekeeper B1): a trailing comment cannot hide an entry ───────
# pip strips `  # comment` and still honours the hash in front of it; so does
# the structure check. The hash check used a second parser that required the
# line to END in hashes and `continue`d otherwise: a bad hash with a comment
# after it passed as "PASS — 14 releases" on a 15-entry lock.
# _comment_lock <which> <mode> — which: blinker (one line) | cffi (its LAST
# --hash line); mode: bad (one hex digit changed) | good (hash unchanged).
_comment_lock() {
    tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk -v which="$1" -v mode="$2" '
        function alt(h) { return substr(h, 1, 63) (substr(h, 64, 1) == "0" ? "1" : "0") }
        which == "blinker" && /^blinker==/ { getline nx; s = nx; sub(/.*sha256:/, "", s); sub(/[^0-9a-f].*$/, "", s)
            print "blinker==1.9.0 --hash=sha256:" (mode == "bad" ? alt(s) : s) "  # pinned"; next }
        which == "cffi" && /^cffi==/ { c = 1; print; next }
        c && /--hash/ && !/\\$/ { s = $0; sub(/.*sha256:/, "", s); sub(/[^0-9a-f].*$/, "", s)
            print "    --hash=sha256:" (mode == "bad" ? alt(s) : s) "  # pinned"; c = 0; next }
        { print }' > "${TM_TMP}/c/requirements.lock"
    grep -q '  # pinned$' "${TM_TMP}/c/requirements.lock" || tm_die "the ${1} comment fixture changed nothing"
}
h_trailing_comment() {
    local which nv
    for which in blinker cffi; do
        case "$which" in blinker) nv="blinker==1.9.0" ;; cffi) nv="cffi==2.1.1" ;; esac
        _copy; _fake_pypi; _comment_lock "$which" bad
        _hash_gate
        tm_assert_rc 1 "$RC" "a bad ${which} hash followed by '# pinned' stayed GREEN — gatekeeper B1: $(cat "${TM_TMP}/out")"
        tm_assert_grep "FAIL: ${nv} — hash " "${TM_TMP}/out" "the commented bad ${which} hash was not named"
        _copy; _fake_pypi; _comment_lock "$which" good
        _hash_gate
        tm_assert_rc 0 "$RC" "a GOOD ${which} hash followed by '# pinned' went red: $(cat "${TM_TMP}/out")"
        tm_assert_grep "15 releases: every hash is one PyPI published" "${TM_TMP}/out" "a commented ${which} entry was not counted among the 15"
    done
}
tm_case "online-a-trailing-comment-cannot-hide-an-entry" none h_trailing_comment

# The same parse, on the other shapes pip reads (mutation survivors of round
# 10): a backslash on the LAST line still ends the entry (pip flushes it);
# a column-0 comment line ends a continuation and is itself a comment even
# with no space before the backslash; a "#" glued to a hash is NOT a comment
# to pip, so that hash is malformed and the gate must refuse it.
h_pip_shapes() {
    _copy; _fake_pypi
    tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk '{ l[NR] = $0 } END { for (i = 1; i < NR; i++) print l[i]; print l[NR] " \\" }' \
        > "${TM_TMP}/c/requirements.lock"
    _hash_gate
    tm_assert_rc 0 "$RC" "a backslash on the lock's last line went red: $(cat "${TM_TMP}/out")"
    tm_assert_grep "15 releases: every hash is one PyPI published" "${TM_TMP}/out" "a backslash on the last line lost the last entry"
    _copy; _fake_pypi
    tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk '
        /^blinker==/ { print; getline; print $0 "\\"; print "# a note, column 0"; next } { print }' > "${TM_TMP}/c/requirements.lock"
    grep -q '^# a note, column 0$' "${TM_TMP}/c/requirements.lock" || tm_die "the column-0 comment fixture changed nothing"
    _hash_gate
    tm_assert_rc 0 "$RC" "a column-0 comment ending blinker's continuation went red: $(cat "${TM_TMP}/out")"
    tm_assert_grep "15 releases: every hash is one PyPI published" "${TM_TMP}/out" "the column-0 comment lost an entry"
    _copy
    tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk '
        /^blinker==/ { print; getline; print $0 "#pinned"; next } { print }' > "${TM_TMP}/c/requirements.lock"
    grep -q '#pinned$' "${TM_TMP}/c/requirements.lock" || tm_die "the glued-# fixture changed nothing"
    PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=1 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a hash with a glued '#pinned' (not a comment to pip) passed"
    tm_assert_grep "blinker has a malformed hash" "${TM_TMP}/out" "the glued '#' was not reported as a malformed hash"
}
_pip_shapes_wrap() { _offline; h_pip_shapes; }
tm_case "online-the-lock-is-read-by-pips-rules" none _pip_shapes_wrap

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

# ─── round 11 (gatekeeper N1): ONE reader of the lock, pip's rules ───────────
# tools/lib/lockparse.py is the only parser of requirements.lock. The gate,
# gen-requirements-lock.py (--check-set, lock_set) and sca-check.sh all use it.
# Round 10 left --check-set and SCA on column-0 regexes:
#   X20  ' # regenerated \' on blinker's hash line: pip and the gate lose cffi,
#        --check-set still saw it -> gate "PASS — 14 releases", pip refuses.
#   X21  the real pyasn1==0.6.4 swallowed by a comment ending in '\', an
#        indented pyasn1==0.4.8 below it: gate PASS, SCA "pyasn1 0.6.4 CLEAN",
#        pip installs 0.4.8 (four CVEs).
PYASN1_048_HASH=39c7e2ec30515947ff4e87fb6f456dfc6e84857d34be479c9d4a4ba4bf46aa5d
# _xlock <x20|x21|tab> — writes the fixture to ${TM_TMP}/c/requirements.lock
_xlock() {
    tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk -v x="$1" -v h048="$PYASN1_048_HASH" '
        x == "x20" && prev ~ /^blinker==/ { print $0 " # regenerated \\"; prev = $0; next }
        x == "x21" && prev ~ /^MarkupSafe==/ && /--hash/ && !/\\$/ { print $0 " # regenerated \\"; m = 1; prev = $0; next }
        x == "x21" && m == 1 && /^pyasn1==/ { print; m = 2; prev = $0; next }
        x == "x21" && m == 2 { print; print "  pyasn1==0.4.8 --hash=sha256:" h048; m = 0; prev = $0; next }
        x == "tab" && /^blinker==/ { getline nx; s = nx; sub(/^ +/, "", s); print "blinker==1.9.0\t" s; prev = $0; next }
        /^[A-Za-z0-9._-]+==/ { prev = $0 }
        { print }' > "${TM_TMP}/c/requirements.lock"
    cmp -s "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/c/requirements.lock" && tm_die "the $1 fixture changed nothing"
    case "$1" in
        x20) grep -q '^    --hash=sha256:[0-9a-f]* # regenerated \\$' "${TM_TMP}/c/requirements.lock" || tm_die "x20 fixture: no commented continuation" ;;
        x21) grep -q '^  pyasn1==0\.4\.8 --hash' "${TM_TMP}/c/requirements.lock" && grep -q '^pyasn1==0\.6\.4 ' "${TM_TMP}/c/requirements.lock" \
                 || tm_die "x21 fixture: not both pyasn1 lines" ;;
        tab) grep -q "^blinker==1\.9\.0$(printf '\t')--hash" "${TM_TMP}/c/requirements.lock" || tm_die "tab fixture: no TAB" ;;
    esac
}
# _fake_resolver — a stand-in `pip` module (PYTHONPATH shadows the real one for
# `python -m pip`): --report writes the name==version set of the REAL lock, as
# a real resolution of requirements.txt returns it. The generator's own code,
# lock_set() included, runs unmodified.
_fake_resolver() {
    local F="${TM_TMP}/fakepip"
    mkdir -p "$F/pip"
    : > "$F/pip/__init__.py"
    "$(tm_python)" - "${TM_REPO_ROOT}/requirements.lock" "$F/resolved.json" <<'PY'
import json, re, sys
names = re.findall(r"^([A-Za-z0-9._-]+)==([^\s\\]+)", open(sys.argv[1], encoding="utf-8").read(), re.M)
json.dump({"install": [{"metadata": {"name": n, "version": v}} for n, v in names]}, open(sys.argv[2], "w"))
PY
    cat > "$F/pip/__main__.py" <<PY
import os, shutil, sys, time
time.sleep(float(os.environ.get("TM_FAKE_PIP_SLEEP") or 0))
shutil.copy("$F/resolved.json", sys.argv[sys.argv.index("--report") + 1])
PY
}
# _check_set <root> — the REAL generator's --check-set against the fake resolver
_check_set() {
    RC=0; PYTHONPATH="${TM_TMP}/fakepip" "$(tm_python)" "${TM_REPO_ROOT}/tools/gen-requirements-lock.py" --check-set --root "$1" \
        > "${TM_TMP}/cs-out" 2>&1 || RC=$?
}

x_check_set_reads_pips_set() {
    _fake_resolver; _copy
    _check_set "${TM_TMP}/c"
    tm_assert_rc 0 "$RC" "the real lock against its own resolved set: $(cat "${TM_TMP}/cs-out")"
    tm_assert_grep "covers the resolved set (15 packages)" "${TM_TMP}/cs-out" "the real lock's set was not 15"
    _copy; _xlock x20; _check_set "${TM_TMP}/c"
    tm_assert_rc 1 "$RC" "X20: --check-set passed a lock from which pip loses cffi: $(cat "${TM_TMP}/cs-out")"
    tm_assert_grep "MISSING from requirements.lock: cffi==2.1.1" "${TM_TMP}/cs-out" "X20: cffi was not reported missing"
    _copy; _xlock x21; _check_set "${TM_TMP}/c"
    tm_assert_rc 1 "$RC" "X21: --check-set passed a lock where pip installs pyasn1 0.4.8: $(cat "${TM_TMP}/cs-out")"
    tm_assert_grep "MISSING from requirements.lock: pyasn1==0.6.4" "${TM_TMP}/cs-out" "X21: the hidden 0.6.4 was counted as present"
    tm_assert_grep "NOT in the resolved set: pyasn1==0.4.8" "${TM_TMP}/cs-out" "X21: the indented 0.4.8 pip installs was not seen"
}
tm_case "x20-x21-check-set-sees-exactly-what-pip-installs" none x_check_set_reads_pips_set

x_gate_refuses_x20_x21() {
    local x
    for x in x20 x21; do
        rm -f "${TM_TMP}/pypi/pyasn1==0.4.8.json"; _fake_resolver; _copy; _fake_pypi
        rm -f "${TM_TMP}/c/tools/gen-requirements-lock.py"      # the gate falls back to the REAL generator
        printf '{"urls": [{"filename": "pyasn1-0.4.8-py2.py3-none-any.whl", "packagetype": "bdist_wheel", "digests": {"sha256": "%s"}}]}\n' \
            "$PYASN1_048_HASH" > "${TM_TMP}/pypi/pyasn1==0.4.8.json"
        _xlock "$x"
        RC=0; PYTHONPATH="${TM_TMP}/fakepip" PATH="${TM_TMP}/on:${PATH}" TM_LOCK_OFFLINE_OK=0 bash "$GATE" --root "${TM_TMP}/c" \
            > "${TM_TMP}/out" 2>&1 || RC=$?
        tm_assert_rc 1 "$RC" "${x}: the gate did not refuse ($(cat "${TM_TMP}/out"))"
        case "$x" in
            x20) tm_assert_grep "looks like an entry but pip does not read it as one" "${TM_TMP}/out" "X20: the swallowed cffi line was not named" ;;
            x21) tm_assert_grep "pyasn1==0.4.8 is not at column 0" "${TM_TMP}/out" "X21: the indented pyasn1 entry was not named"
                 tm_assert_grep "looks like an entry but pip does not read it as one" "${TM_TMP}/out" "X21: the swallowed 0.6.4 line was not named" ;;
        esac
    done
    # The same harness on the real lock is GREEN, so the red above is the fixture's.
    rm -f "${TM_TMP}/pypi/pyasn1==0.4.8.json"; _fake_resolver; _copy; _fake_pypi; rm -f "${TM_TMP}/c/tools/gen-requirements-lock.py"
    RC=0; PYTHONPATH="${TM_TMP}/fakepip" PATH="${TM_TMP}/on:${PATH}" TM_LOCK_OFFLINE_OK=0 bash "$GATE" --root "${TM_TMP}/c" \
        > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "the real lock with the real generator went red: $(cat "${TM_TMP}/out")"
    tm_assert_grep "covers the resolved set (15 packages)" "${TM_TMP}/out" "the real generator's verdict was not relayed"
}
tm_case "x20-x21-the-gate-refuses-a-lock-pip-reads-differently" none x_gate_refuses_x20_x21

# TM-RL-004: pip splits a requirement line on SPACES; a TAB between the version
# and --hash makes one malformed requirement, which pip refuses. So does the gate.
x_tab() {
    _offline; _copy; _xlock tab
    RC=0; PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=1 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "a TAB between version and --hash (pip refuses it) passed the gate: $(cat "${TM_TMP}/out")"
    tm_assert_grep "not an exact pin with hashes: blinker==1.9.0" "${TM_TMP}/out" "the TAB line was not named"
}
tm_case "a-tab-before-hash-is-refused-as-pip-refuses-it" none x_tab

# The shared parser against PIP'S OWN parser (pip._internal.req.req_file), on
# every shape above plus the ones pip accepts: the name==version set must be
# identical, and where pip refuses a line the parser must report an error.
x_differential() {
    local x f
    mkdir -p "${TM_TMP}/diff"
    for x in real x20 x21 tab tabhash comment0 lastbs glued splithash; do
        _copy
        case "$x" in
            real) ;;
            x20|x21|tab) _xlock "$x" ;;
            tabhash) tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk '/^cffi==/{c=1;print;next} c==1&&/--hash/{sub(/ \\$/, "\t\\"); c=0} {print}' > "${TM_TMP}/c/requirements.lock"
                     grep -q "$(printf '\t')\\\\\$" "${TM_TMP}/c/requirements.lock" || tm_die "tabhash fixture changed nothing" ;;
            comment0) tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk '/^blinker==/ { print; getline; print $0 "\\"; print "# a note, column 0"; next } { print }' > "${TM_TMP}/c/requirements.lock" ;;
            lastbs) tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk '{ l[NR] = $0 } END { for (i = 1; i < NR; i++) print l[i]; print l[NR] " \\" }' > "${TM_TMP}/c/requirements.lock" ;;
            glued) tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk '/^blinker==/ { print; getline; print $0 "#pinned"; next } { print }' > "${TM_TMP}/c/requirements.lock" ;;
            # a hash broken across a continuation: pip joins the halves with NOTHING between
            splithash) tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk '/^blinker==/ { print; getline; print substr($0, 1, 40) "\\"; print substr($0, 41); next } { print }' > "${TM_TMP}/c/requirements.lock" ;;
        esac
        cp "${TM_TMP}/c/requirements.lock" "${TM_TMP}/diff/${x}.lock"
    done
    "$(tm_python)" - "${TM_REPO_ROOT}/tools/lib" "${TM_TMP}/diff" > "${TM_TMP}/out" 2>&1 <<'PY' || _tm_afail "the parser and pip disagree: $(cat "${TM_TMP}/out")"
import os, sys
sys.path.insert(0, sys.argv[1]); import lockparse
from pip._internal.req.req_file import parse_requirements
from pip._vendor.packaging.requirements import Requirement
bad = 0
for fn in sorted(os.listdir(sys.argv[2])):
    path = os.path.join(sys.argv[2], fn)
    pip_set, pip_refuses = set(), False
    try:
        for pr in parse_requirements(path, session=None):
            try:
                r = Requirement(pr.requirement)
                (spec,) = list(r.specifier)
                pip_set.add((lockparse.norm(r.name), spec.version))
            except Exception:
                pip_refuses = True
    except Exception:
        pip_refuses = True
    ents, errs = lockparse.parse(lockparse.read(path))
    ours = {(e["key"], e["version"]) for e in ents}
    ok = ours == pip_set and (errs or not pip_refuses)
    print("%-14s pip %2d entries%s  lockparse %2d entries, %d error(s)  %s"
          % (fn, len(pip_set), " (refuses a line)" if pip_refuses else "", len(ours), len(errs), "AGREE" if ok else "DISAGREE"))
    if not ok:
        bad += 1
        print("   pip only: %s  lockparse only: %s" % (sorted(pip_set - ours), sorted(ours - pip_set)))
sys.exit(1 if bad else 0)
PY
    tm_assert_grep "x21.lock       pip 15 entries  lockparse 15 entries" "${TM_TMP}/out" "X21 was not measured against pip"
    tm_assert_grep "x20.lock       pip 14 entries" "${TM_TMP}/out" "X20 was not measured against pip"
    tm_assert_grep "tab.lock       pip 14 entries (refuses a line)" "${TM_TMP}/out" "pip did not refuse the TAB line"
    tm_assert_grep "splithash.lock pip 15 entries  lockparse 15 entries, 0 error(s)  AGREE" "${TM_TMP}/out" "a hash split across a continuation was not rejoined as pip rejoins it"
}
tm_case "the-lock-parser-agrees-with-pips-own-parser" none x_differential

# The parser's refusals, each on its own (mutation survivors of round 11): a
# duplicate package, an entry with no hash, a per-requirement option other
# than --hash (pip honours --config-settings and friends), and a line break
# pip honours that grep does not (a lone CR or a form feed can put an entry
# pip installs mid-line for every column-0 reader).
x_parser_refusals() {
    _offline
    local x msg
    for x in dup nohash option cr ff; do
        _copy
        tr -d '\r' < "${TM_REPO_ROOT}/requirements.lock" | awk -v x="$x" -v h048="$PYASN1_048_HASH" '
            x == "dup" && /^pycparser==/ { print; getline; print; print "pycparser==3.0 \\"; print; next }
            x == "nohash" && /^blinker==/ { print "blinker==1.9.0"; getline; next }
            x == "option" && /^blinker==/ { print "blinker==1.9.0 --config-settings=x=y \\"; next }
            x == "cr" && /^# whose hash/ { printf "%s\r  pyasn1==0.4.8 --hash=sha256:%s\n", $0, h048; next }
            x == "ff" && /^# whose hash/ { printf "%s\f  pyasn1==0.4.8 --hash=sha256:%s\n", $0, h048; next }
            { print }' > "${TM_TMP}/c/requirements.lock"
        cmp -s "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/c/requirements.lock" && tm_die "the ${x} fixture changed nothing"
        case "$x" in
            dup)    msg="pycparser appears twice in requirements.lock" ;;
            nohash) msg="blinker==1.9.0 has no --hash" ;;
            option) msg="blinker==1.9.0 has an option that is not --hash=sha256:...: --config-settings=x=y" ;;
            cr|ff)  msg="requirements.lock line 8: a line break pip honours and grep does not" ;;
        esac
        RC=0; PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=1 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || RC=$?
        tm_assert_rc 1 "$RC" "${x}: the gate passed it: $(cat "${TM_TMP}/out")"
        tm_assert_grep "$msg" "${TM_TMP}/out" "${x}: not named as '${msg}'"
    done
    # --check-set refuses a lock pip would refuse, rather than comparing a partial set.
    _fake_resolver; _copy; _xlock tab; _check_set "${TM_TMP}/c"
    tm_assert_rc 1 "$RC" "--check-set compared a lock pip refuses: $(cat "${TM_TMP}/cs-out")"
    tm_assert_grep "FAIL: requirements.lock: not an exact pin with hashes: blinker==1.9.0" "${TM_TMP}/cs-out" "--check-set did not name the refused line"
}
tm_case "the-lock-parser-refuses-what-a-consumer-could-misread" none x_parser_refusals

# lockparse.py's command line, which sca-check.sh reads: 0 with every entry and
# "#entries N"; 1 on a parse error; 2 when it cannot read the lock or is misused.
x_lockparse_cli() {
    local LP="${TM_REPO_ROOT}/tools/lib/lockparse.py"
    RC=0; "$(tm_python)" "$LP" "${TM_REPO_ROOT}/requirements.lock" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "the real lock: $(cat "${TM_TMP}/out")"
    tm_assert_eq "#entries 15" "$(tail -n 1 "${TM_TMP}/out")" "the count line"
    tm_assert_eq 15 "$(grep -c '==' "${TM_TMP}/out")" "the entry lines"
    _copy; _xlock tab
    RC=0; "$(tm_python)" "$LP" "${TM_TMP}/c/requirements.lock" > "${TM_TMP}/out" 2>"${TM_TMP}/err" || RC=$?
    tm_assert_rc 1 "$RC" "a lock pip refuses"
    [ -s "${TM_TMP}/out" ] && _tm_afail "a refused lock still printed entries: $(cat "${TM_TMP}/out")"
    tm_assert_grep "lockparse: requirements.lock: not an exact pin" "${TM_TMP}/err" "the parse error was not on stderr"
    printf 'blinker==1.9.0 \xff\n' > "${TM_TMP}/c/requirements.lock"
    RC=0; "$(tm_python)" "$LP" "${TM_TMP}/c/requirements.lock" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 2 "$RC" "a lock that is not UTF-8"
    tm_assert_grep "cannot read ${TM_TMP}/c/requirements.lock" "${TM_TMP}/out" "the unreadable file was not named"
    RC=0; "$(tm_python)" "$LP" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 2 "$RC" "no argument"
    tm_assert_grep "usage: lockparse.py" "${TM_TMP}/out" "no usage line"
}
tm_case "lockparse-cli-exit-codes" none x_lockparse_cli

# TM-RL-005: the gate reads the completeness verdict, not just exit 0; the
# resolver has a timeout.
x_check_set_output_is_read() {
    _copy; _fake_pypi
    printf '%s\n' 'print("something else")' > "${TM_TMP}/c/tools/gen-requirements-lock.py"
    _hash_gate
    tm_assert_rc 3 "$RC" "--check-set exited 0 with no verdict and the gate accepted it: $(cat "${TM_TMP}/out")"
    tm_assert_grep "exited 0 without its verdict" "${TM_TMP}/out" "the missing verdict was not named"
    printf '%s\n' 'print("requirements.lock covers the resolved set (14 packages)")' > "${TM_TMP}/c/tools/gen-requirements-lock.py"
    _hash_gate
    tm_assert_rc 1 "$RC" "a resolved count of 14 against a 15-entry lock passed: $(cat "${TM_TMP}/out")"
    tm_assert_grep "the resolved set has 14 packages but the lock has 15 entries" "${TM_TMP}/out" "the count mismatch was not named"
    _fake_resolver; _copy
    RC=0; TM_FAKE_PIP_SLEEP=30 TM_LOCK_RESOLVE_TIMEOUT=2 PYTHONPATH="${TM_TMP}/fakepip" \
        "$(tm_python)" "${TM_REPO_ROOT}/tools/gen-requirements-lock.py" --check-set --root "${TM_TMP}/c" > "${TM_TMP}/cs-out" 2>&1 || RC=$?
    tm_assert_rc 3 "$RC" "a resolver that hangs was not 'could not resolve' within the timeout: $(cat "${TM_TMP}/cs-out")"
    tm_assert_grep "timed out" "${TM_TMP}/cs-out" "the timeout was not reported"
}
tm_case "the-gate-reads-the-completeness-verdict-and-the-resolver-times-out" none x_check_set_output_is_read

# SCA queries the version PIP installs (X21), counts every lock entry
# (TM-RL-002), and refuses a lock pip would refuse. A stand-in curl plays OSV
# (pyasn1 0.4.8 carries an advisory, everything else is clean) and PyPI/npm
# (every release exists).
_sca_tree() {   # _sca_tree <lock-file> [fake-lockparse-body]
    local S="${TM_TMP}/sc"
    rm -rf "$S"; mkdir -p "$S/tools/lib" "$S/install" "${TM_TMP}/osv"
    cp "$SCA" "$S/tools/"; cp "${TM_REPO_ROOT}/tools/lib/lockparse.py" "$S/tools/lib/"
    cp "${TM_REPO_ROOT}/requirements.txt" "$S/"; cp "$1" "$S/requirements.lock"
    cp "$(tm_upgrade_sh)" "$S/install/upgrade-full.sh"
    [ -n "${2:-}" ] && printf '%s\n' "$2" > "$S/tools/lib/lockparse.py"
    cat > "${TM_TMP}/osv/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""; data=""; fmt=""
while [ $# -gt 0 ]; do case "$1" in -o) shift; out="$1" ;; -d) shift; data="$1" ;; -w) shift; fmt="$1" ;; -X|--max-time) shift ;; -*) ;; *) url="$1" ;; esac; shift; done
case "$url" in
    https://api.osv.dev/v1/query)
        case "$data" in
            *'"name":"pyasn1"},"version":"0.4.8"'*) body='{"vulns": [{"id": "CVE-2026-30922"}]}' ;;
            *'"name":"Flask"},"version":"3.1.2"'*) body='{"vulns": [{"id": "CVE-2026-00001"}]}' ;;
            *) body='{}' ;;
        esac ;;
    *) body="" ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
case "$fmt" in *http_code*) printf '200' ;; esac
exit 0
STUB
    chmod +x "${TM_TMP}/osv/curl"
}
_sca_run() { RC=0; PATH="${TM_TMP}/osv:${PATH}" bash "${TM_TMP}/sc/tools/sca-check.sh" > "${TM_TMP}/out" 2>&1 || RC=$?; }

s_sca_queries_what_pip_installs() {
    _sca_tree "${TM_REPO_ROOT}/requirements.lock"; _sca_run
    tm_assert_rc 0 "$RC" "SCA on the real lock with a clean OSV went red: $(cat "${TM_TMP}/out")"
    tm_assert_grep "15 of 15 requirements.lock entries checked at the version pip installs" "${TM_TMP}/out" "SCA did not account for every lock entry"
    grep -Eq '^  pyasn1 +0\.6\.4 +.*CLEAN' "${TM_TMP}/out" || _tm_afail "SCA did not query pyasn1 0.6.4 from the real lock"
    # A direct pin at the SAME version in requirements.txt and the lock is
    # queried once, whatever its spelling (Flask / flask, PyYAML / pyyaml).
    local p n
    for p in flask werkzeug gunicorn ldap3 pyyaml cryptography confluent-kafka; do
        n="$(grep -Eic "^  ${p} " "${TM_TMP}/out")"
        tm_assert_eq 1 "$n" "${p} was not queried exactly once"
    done
    # ... and when requirements.txt spells it differently from the lock.
    _sca_tree "${TM_REPO_ROOT}/requirements.lock"
    sed -i 's/^Flask==/flask==/; s/^PyYAML==/pyyaml==/' "${TM_TMP}/sc/requirements.txt"
    grep -q '^flask==3\.1\.3' "${TM_TMP}/sc/requirements.txt" || tm_die "the lower-case fixture changed nothing"
    _sca_run
    for p in flask pyyaml; do
        n="$(grep -Eic "^  ${p} " "${TM_TMP}/out")"
        tm_assert_eq 1 "$n" "${p} (spelt differently in requirements.txt) was not queried exactly once"
    done
    # A direct pin whose LOCK version differs from requirements.txt: pip
    # installs the lock's, so SCA must query the lock's too.
    sed 's/^Flask==3\.1\.3 /Flask==3.1.2 /' "${TM_REPO_ROOT}/requirements.lock" > "${TM_TMP}/flask.lock"
    cmp -s "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/flask.lock" && tm_die "the Flask drift fixture changed nothing"
    _sca_tree "${TM_TMP}/flask.lock"; _sca_run
    tm_assert_rc 1 "$RC" "SCA passed a lock that installs Flask 3.1.2 (vulnerable) under a requirements.txt pin of 3.1.3: $(cat "${TM_TMP}/out")"
    grep -Eq '^  Flask +3\.1\.2 +.*VULNERABLE' "${TM_TMP}/out" || _tm_afail "SCA did not query the Flask version pip installs"
    _copy; _xlock x21
    _sca_tree "${TM_TMP}/c/requirements.lock"; _sca_run
    tm_assert_rc 1 "$RC" "X21: SCA passed a lock from which pip installs pyasn1 0.4.8: $(cat "${TM_TMP}/out")"
    grep -Eq '^  pyasn1 +0\.4\.8 +.*VULNERABLE.*CVE-2026-30922' "${TM_TMP}/out" \
        || _tm_afail "X21: SCA did not query the pyasn1 0.4.8 pip installs: $(cat "${TM_TMP}/out")"
    grep -Eq '^  pyasn1 +0\.6\.4 ' "${TM_TMP}/out" && _tm_afail "X21: SCA queried the 0.6.4 a comment hides from pip"
    tm_assert_grep "15 of 15 requirements.lock entries checked" "${TM_TMP}/out" "X21: the indented entry was not counted"
    _copy; _xlock x20
    _sca_tree "${TM_TMP}/c/requirements.lock"; _sca_run
    grep -Eq '^  cffi ' "${TM_TMP}/out" && _tm_afail "X20: SCA queried the cffi pip never reads: $(cat "${TM_TMP}/out")"
    tm_assert_grep "14 of 14 requirements.lock entries checked" "${TM_TMP}/out" "X20: SCA's count is not pip's"
    return 0
}
tm_case "sca-queries-the-version-pip-installs" none s_sca_queries_what_pip_installs

s_sca_refuses_a_short_or_bad_read() {
    _copy; _xlock tab
    _sca_tree "${TM_TMP}/c/requirements.lock"; _sca_run
    tm_assert_rc 3 "$RC" "SCA passed a lock pip refuses (TAB before --hash): $(cat "${TM_TMP}/out")"
    tm_assert_grep "does not parse as pip reads it" "${TM_TMP}/out" "the refusal does not say why"
    # The count guard: a reader that hands over fewer entries than it counted,
    # or a line that is not name==version, is a refusal — never "> 0 is enough".
    _sca_tree "${TM_REPO_ROOT}/requirements.lock" 'print("flask==3.1.3"); print("#entries 15")'; _sca_run
    tm_assert_rc 3 "$RC" "SCA accepted 1 entry handled of 15 counted: $(cat "${TM_TMP}/out")"
    tm_assert_grep "handled 1 lock entries but the parser read 15" "${TM_TMP}/out" "the short read was not named"
    _sca_tree "${TM_REPO_ROOT}/requirements.lock" 'print("flask==3.1.3 --hash=x"); print("#entries 1")'; _sca_run
    tm_assert_rc 3 "$RC" "SCA accepted a parser line that is not name==version: $(cat "${TM_TMP}/out")"
    tm_assert_grep "unexpected line from the lock parser" "${TM_TMP}/out" "the malformed parser line was not named"
    _sca_tree "${TM_REPO_ROOT}/requirements.lock" 'print("#entries 0")'; _sca_run
    tm_assert_rc 3 "$RC" "SCA accepted a lock with no entries: $(cat "${TM_TMP}/out")"
    _sca_tree "${TM_REPO_ROOT}/requirements.lock" 'import sys; print("flask==3.1.3"); print("#entries 1"); sys.exit(1)'; _sca_run
    tm_assert_rc 3 "$RC" "SCA used the output of a parser that exited 1: $(cat "${TM_TMP}/out")"
    tm_assert_grep "does not parse as pip reads it" "${TM_TMP}/out" "the parser's failure was not the stated reason"
    _sca_tree "${TM_REPO_ROOT}/requirements.lock"; rm -f "${TM_TMP}/sc/tools/lib/lockparse.py"; _sca_run
    tm_assert_rc 3 "$RC" "SCA ran without the lock parser: $(cat "${TM_TMP}/out")"
    tm_assert_grep "lockparse.py is missing" "${TM_TMP}/out" "the missing parser was not named"
}
tm_case "sca-refuses-a-lock-it-cannot-read-in-full" none s_sca_refuses_a_short_or_bad_read

_sbom_copy() {
    local r="${TM_TMP}/sb"
    mkdir -p "$r/tools/lib" "$r/install" "$r/app/components/modals"
    cp "${TM_REPO_ROOT}/tools/check-sbom-consistency.sh" "$r/tools/"
    cp "${TM_REPO_ROOT}/tools/lib/lockparse.py" "$r/tools/lib/"
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

# ─── round 12 (gatekeeper B1/B2): the lock's ENCODING, and the SBOM reader ───
# B1: pip decodes the lock by a byte-order mark, else by a PEP 263 coding line
# in its first two lines, else by the locale — never simply as UTF-8.
#   N01  "# -*- coding: latin-1 -*-" and a comment holding U+0145 (C5 85): 0x85
#        is NEL, a line break, to a latin-1 reader, so pip read
#        "pyasn1==0.4.8 --hash=<real> \" as an entry and it swallowed the real
#        0.6.4 line. Gate PASS 15, SBOM 0, SCA "0.6.4 CLEAN"; pip installed 0.4.8.
#   N02  the same with "coding: utf-7" and the pure-ASCII "+AAo-" (a newline).
# The rule is now: pure ASCII, no BOM, no coding line, LF (CRLF) only.
# B2: check-sbom-consistency.sh read the lock with a column-0 regex of its own:
#   N03  a BOM glued to the first entry (blinker) hid it, so its SBOM row could
#        say 1.8.0 with every gate green (pip installs 1.9.0).
#   N04  "pyasn1==0.6\" + ".4 \": pip reads 0.6.4, the regex read 0.6, and an
#        SBOM row of 0.6 was green.
# _nlock <case> <out> — the fixture, built from the real lock's BYTES.
_nlock() {
    "$(tm_python)" - "$1" "${TM_REPO_ROOT}/requirements.lock" "$2" "$PYASN1_048_HASH" <<'PY' || tm_die "could not build the $1 fixture"
import sys
case, src, dst, h = sys.argv[1:5]
raw = open(src, "rb").read().replace(b"\r\n", b"\n")
lines = raw.split(b"\n")
def at(prefix):
    (i,) = [k for k, l in enumerate(lines) if l.startswith(prefix)]
    return i
pa = at(b"pyasn1==")
hidden = b"pyasn1==0.4.8 --hash=sha256:" + h.encode() + b" \\"
def comment_before_pyasn1(mid):
    return lines[:pa] + [b"# note " + mid + hidden] + lines[pa:]
if case == "n01":
    out = comment_before_pyasn1(u"\u0145".encode("utf-8")); out[0] = b"# -*- coding: latin-1 -*-"
elif case == "n02":
    out = comment_before_pyasn1(b"+AAo-"); out[0] = b"# -*- coding: utf-7 -*-"
elif case == "n03":
    out = lines[at(b"blinker=="):]; out[0] = b"\xef\xbb\xbf" + out[0]
elif case == "n04":
    out = lines[:pa] + [b"pyasn1==0.6\\", b".4 \\"] + lines[pa + 1:]
elif case == "bom":
    out = list(lines); out[0] = b"\xef\xbb\xbf" + out[0]
elif case == "coding2":
    out = list(lines); out[1] = b"# -*- coding: utf-8 -*-"
elif case in ("nel", "vt", "ff", "u2028", "nul", "b80", "del"):
    mid = {"nel": b"\x85", "vt": b"\x0b", "ff": b"\x0c", "u2028": u"\u2028".encode("utf-8"), "nul": b"\x00",
           "b80": b"\x80", "del": b"\x7f"}[case]
    out = comment_before_pyasn1(mid)
elif case == "coding3":     # a coding line on line 3: pip ignores it, so may the parser
    out = list(lines); out[2] = b"# -*- coding: utf-7 -*-"
elif case == "crlfnel":     # CRLF is stripped, and ONLY the CR: the byte before it is still checked
    out = lines[:pa] + [b"# note x\x85"] + lines[pa:]
    open(dst, "wb").write(b"\r\n".join(out)); sys.exit(0)
elif case == "crlf":
    open(dst, "wb").write(raw.replace(b"\n", b"\r\n")); sys.exit(0)
elif case == "utf16":
    open(dst, "wb").write(raw.decode("ascii").encode("utf-16")); sys.exit(0)
else:
    sys.exit("unknown case " + case)
data = b"\n".join(out)
assert data != raw, case
open(dst, "wb").write(data)
PY
    cmp -s "${TM_REPO_ROOT}/requirements.lock" "$2" && tm_die "the $1 fixture changed nothing"
    return 0
}
PA="$(awk '/^pyasn1==/ { print NR; exit }' "${TM_REPO_ROOT}/requirements.lock")"    # the real pyasn1 line
[ -n "$PA" ] || tm_die "the real lock has no pyasn1 line"
# The message each fixture must be refused with — by the gate AND by the SBOM check.
_nwhy() {
    case "$1" in
        n01)     echo "requirements.lock line 1: a coding declaration (PEP 263)" ;;
        n02)     echo "requirements.lock line 1: a coding declaration (PEP 263)" ;;
        n03)     echo "requirements.lock starts with a byte-order mark" ;;
        n04)     echo "requirements.lock line ${PA}: pyasn1==0.6.4 is not written whole on its first line" ;;
        bom)     echo "requirements.lock starts with a byte-order mark" ;;
        utf16)   echo "requirements.lock starts with a byte-order mark" ;;
        coding2) echo "requirements.lock line 2: a coding declaration (PEP 263)" ;;
        nel)     echo "requirements.lock line ${PA} col 8: byte 0x85 is not ASCII" ;;
        u2028)   echo "requirements.lock line ${PA} col 8: byte 0xe2 is not ASCII" ;;
        vt)      echo "requirements.lock line ${PA}: a line break pip honours and grep does not (byte 0x0b)" ;;
        ff)      echo "requirements.lock line ${PA}: a line break pip honours and grep does not (byte 0x0c)" ;;
        nul)     echo "requirements.lock line ${PA} col 8: control character 0x00" ;;
        del)     echo "requirements.lock line ${PA} col 8: control character 0x7f" ;;
        b80)     echo "requirements.lock line ${PA} col 8: byte 0x80 is not ASCII" ;;
        crlfnel) echo "requirements.lock line ${PA} col 9: byte 0x85 is not ASCII" ;;
    esac
}
N_CASES="n01 n02 n03 n04 bom utf16 coding2 nel u2028 vt ff nul del b80 crlfnel"

n_gate_refuses_encodings() {
    _offline
    local x
    for x in $N_CASES; do
        _copy; _nlock "$x" "${TM_TMP}/c/requirements.lock"
        RC=0; PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=1 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || RC=$?
        tm_assert_rc 1 "$RC" "${x}: the gate passed it: $(cat "${TM_TMP}/out")"
        tm_assert_grep "FAIL: $(_nwhy "$x")" "${TM_TMP}/out" "${x}: not refused for the right reason"
    done
    # N01/N02 carry a second, independent problem each: the non-ASCII byte
    # (N01) — so a coding line alone and a stray byte alone are both refusals.
    _copy; _nlock n01 "${TM_TMP}/c/requirements.lock"
    RC=0; PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=1 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_grep "FAIL: requirements.lock line ${PA} col 8: byte 0xc5 is not ASCII" "${TM_TMP}/out" "N01: the C5 85 bytes were not named"
    # CRLF is tolerated (as before): same bytes pip, grep and the parser split
    # alike. A coding line on line 3 is not one pip reads (it looks at two).
    for x in crlf coding3; do
        _copy; _nlock "$x" "${TM_TMP}/c/requirements.lock"
        RC=0; PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=1 bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 || RC=$?
        tm_assert_rc 0 "$RC" "${x}: an otherwise real lock went red: $(cat "${TM_TMP}/out")"
        tm_assert_grep "15 packages locked" "${TM_TMP}/out" "${x}: the lock lost entries"
    done
}
tm_case "n01-n04-the-gate-refuses-a-lock-pip-could-decode-differently" none n_gate_refuses_encodings

_sbom_run() { RC=0; bash "${TM_TMP}/sb/tools/check-sbom-consistency.sh" > "${TM_TMP}/out" 2>&1 || RC=$?; }
n_sbom_reads_the_lock_as_pip_does() {
    local x
    # N03 / N04 exactly as measured: the SBOM row edited to what the old
    # column-0 regex saw. Both must now be RED.
    _sbom_copy; _nlock n03 "${TM_TMP}/sb/requirements.lock"
    sed -i 's/^| blinker | 1\.9\.0 |/| blinker | 1.8.0 |/' "${TM_TMP}/sb/SBOM.md"
    grep -q '^| blinker | 1\.8\.0 |' "${TM_TMP}/sb/SBOM.md" || tm_die "the N03 SBOM edit changed nothing"
    _sbom_run
    tm_assert_rc 1 "$RC" "N03: a BOM-hidden blinker with its SBOM row at 1.8.0 passed: $(cat "${TM_TMP}/out")"
    tm_assert_grep "requirements.lock does not parse as pip reads it" "${TM_TMP}/out" "N03: not refused as unparseable"
    tm_assert_grep "requirements.lock starts with a byte-order mark" "${TM_TMP}/out" "N03: the BOM was not named"
    _sbom_copy; _nlock n04 "${TM_TMP}/sb/requirements.lock"
    sed -i 's/^| pyasn1 | 0\.6\.4 |/| pyasn1 | 0.6 |/' "${TM_TMP}/sb/SBOM.md"
    grep -q '^| pyasn1 | 0\.6 |' "${TM_TMP}/sb/SBOM.md" || tm_die "the N04 SBOM edit changed nothing"
    _sbom_run
    tm_assert_rc 1 "$RC" "N04: an SBOM row of 0.6 for the 0.6.4 pip installs passed: $(cat "${TM_TMP}/out")"
    tm_assert_grep "pyasn1             SBOM.md says 0.6        requirements.lock says 0.6.4" "${TM_TMP}/out" "N04: the version pip reads (0.6.4) was not the one compared"
    # N04 with the SBOM row left TRUE (0.6.4) is green here — the SBOM is
    # right; the split entry is the lock gate's refusal (above).
    _sbom_copy; _nlock n04 "${TM_TMP}/sb/requirements.lock"; _sbom_run
    tm_assert_rc 0 "$RC" "N04 with a true SBOM row went red: $(cat "${TM_TMP}/out")"
    # N03 with blinker's row left TRUE: still RED, the lock itself is refused.
    for x in $N_CASES; do
        [ "$x" = n04 ] && continue
        _sbom_copy; _nlock "$x" "${TM_TMP}/sb/requirements.lock"; _sbom_run
        tm_assert_rc 1 "$RC" "${x}: the SBOM check passed it: $(cat "${TM_TMP}/out")"
        tm_assert_grep "    $(_nwhy "$x")" "${TM_TMP}/out" "${x}: not refused for the right reason"
    done
    # A CRLF lock is read, entry for entry, as the LF one.
    _sbom_copy; _nlock crlf "${TM_TMP}/sb/requirements.lock"; _sbom_run
    tm_assert_rc 0 "$RC" "a CRLF copy of the real lock went red: $(cat "${TM_TMP}/out")"
    tm_assert_grep "(8 transitive packages agree with requirements.lock)" "${TM_TMP}/out" "the CRLF lock lost transitive entries"
    _sbom_copy; rm -f "${TM_TMP}/sb/tools/lib/lockparse.py"; _sbom_run
    tm_assert_rc 3 "$RC" "the SBOM check ran without the lock parser: $(cat "${TM_TMP}/out")"
    tm_assert_grep "lockparse.py is missing" "${TM_TMP}/out" "the missing parser was not named"
}
tm_case "n03-n04-the-sbom-check-reads-the-lock-as-pip-does" none n_sbom_reads_the_lock_as_pip_does

# The other consumers of the parser refuse the same bytes: --check-set, SCA and
# the command line (exit 2, "cannot read").
n_consumers_refuse() {
    _fake_resolver; _copy; _nlock n01 "${TM_TMP}/c/requirements.lock"; _check_set "${TM_TMP}/c"
    tm_assert_rc 1 "$RC" "N01: --check-set compared a lock pip decodes differently: $(cat "${TM_TMP}/cs-out")"
    tm_assert_grep "FAIL: requirements.lock line 1: a coding declaration (PEP 263)" "${TM_TMP}/cs-out" "N01: --check-set did not say why"
    _copy; _nlock n01 "${TM_TMP}/c/requirements.lock"
    _sca_tree "${TM_TMP}/c/requirements.lock"; _sca_run
    tm_assert_rc 3 "$RC" "N01: SCA passed a lock from which pip installs pyasn1 0.4.8: $(cat "${TM_TMP}/out")"
    tm_assert_grep "does not parse as pip reads it" "${TM_TMP}/out" "N01: SCA did not say why"
    grep -Eq '^  pyasn1 +0\.6\.4 ' "${TM_TMP}/out" && _tm_afail "N01: SCA still queried the 0.6.4 pip does not install"
    _copy; _nlock n02 "${TM_TMP}/c/requirements.lock"
    RC=0; "$(tm_python)" "${TM_REPO_ROOT}/tools/lib/lockparse.py" "${TM_TMP}/c/requirements.lock" > "${TM_TMP}/out" 2>"${TM_TMP}/err" || RC=$?
    tm_assert_rc 2 "$RC" "N02 through the command line"
    [ -s "${TM_TMP}/out" ] && _tm_afail "N02: entries were printed for a refused lock: $(cat "${TM_TMP}/out")"
    tm_assert_grep "a coding declaration (PEP 263)" "${TM_TMP}/err" "N02: the refusal was not on stderr"
}
tm_case "n01-n02-every-consumer-refuses-a-coding-line" none n_consumers_refuse

# The generator never writes a lock that breaks the rule, and refuses to: its
# real render() (hashes stubbed, no network) is plain ASCII the parser accepts,
# and lock_bytes() refuses the round-11 header's em dash.
n_generator_writes_ascii() {
    TMPDIR="${TM_TMP}" "$(tm_python)" - "${TM_REPO_ROOT}/tools/gen-requirements-lock.py" > "${TM_TMP}/out" 2>&1 <<'PY' || _tm_afail "the generator: $(cat "${TM_TMP}/out")"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gen", sys.argv[1]); g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
g.wheel_hashes = lambda n, v: ["%064x" % 1, "%064x" % 2]
text = g.render([("blinker", "1.9.0"), ("cffi", "2.1.1")])
data, probs = g.lock_bytes(text)
assert probs == [], probs
assert max(data) < 0x80 and data == text.encode("ascii"), "not plain ASCII"
bad = text.replace(" - GENERATED", " — GENERATED", 1)
assert bad != text, "the em-dash fixture changed nothing"
data, probs = g.lock_bytes(bad)
assert probs and "byte 0xe2 is not ASCII" in probs[0], probs
split = text.replace("cffi==2.1.1 \\", "cffi==2.1\\\n.1 \\", 1)
assert split != text, "the split fixture changed nothing"
probs = g.lock_bytes(split)[1]
assert any("cffi==2.1.1 is not written whole" in p for p in probs), probs
# main() itself: refuses to write a lock lock_bytes() refuses, writes the bytes otherwise.
import os, tempfile
g.LOCK = os.path.join(tempfile.mkdtemp(), "requirements.lock")
g.resolve = lambda: [("blinker", "1.9.0"), ("cffi", "2.1.1")]
sys.argv = ["gen-requirements-lock.py"]
real_render = g.render
g.render = lambda pins: real_render(pins).replace(" - GENERATED", " \u2014 GENERATED", 1)
try:
    g.main(); rc = 0
except SystemExit as e:
    rc = e.code
assert rc == 1 and not os.path.exists(g.LOCK), "main() wrote a lock with a non-ASCII byte (rc %r)" % rc
g.render = real_render
g.main()
assert open(g.LOCK, "rb").read() == text.encode("ascii"), "main() did not write the rendered lock"
print("generator OK")
PY
    tm_assert_grep "generator OK" "${TM_TMP}/out" "the generator check did not finish"
}
tm_case "the-generator-writes-only-plain-ascii" none n_generator_writes_ascii

# pip's OWN reader on the fixtures' raw BYTES (pip._internal.req.req_file reads
# the file and decodes it with auto_decode — BOM, coding line, locale): what pip
# would install from each, against lockparse. The hazard is real (pip reads
# pyasn1 0.4.8 from N01 and N02, blinker from N03, 0.6.4 from N04) and the
# parser refuses N01-N03 outright; on N04 it reads pip's 0.6.4.
n_pip_oracle_raw_bytes() {
    local x
    mkdir -p "${TM_TMP}/nraw"
    for x in n01 n02 n03 n04 bom utf16 coding2 coding3 crlf; do _nlock "$x" "${TM_TMP}/nraw/${x}.lock"; done
    cp "${TM_REPO_ROOT}/requirements.lock" "${TM_TMP}/nraw/real.lock"
    "$(tm_python)" - "${TM_REPO_ROOT}/tools/lib" "${TM_TMP}/nraw" > "${TM_TMP}/out" 2>&1 <<'PY' || _tm_afail "pip and the parser: $(cat "${TM_TMP}/out")"
import os, sys
sys.path.insert(0, sys.argv[1]); import lockparse
from pip._internal.req.req_file import parse_requirements
from pip._vendor.packaging.requirements import Requirement
want = {  # what pip reads from the raw bytes, for the packages the fixture is about
    "n01": {"pyasn1": "0.4.8"}, "n02": {"pyasn1": "0.4.8"}, "n03": {"blinker": "1.9.0"},
    "n04": {"pyasn1": "0.6.4"}, "bom": {"blinker": "1.9.0"}, "utf16": {"pyasn1": "0.6.4"},
    "coding2": {"pyasn1": "0.6.4"}, "coding3": {"pyasn1": "0.6.4"}, "crlf": {"pyasn1": "0.6.4"}, "real": {"pyasn1": "0.6.4"},
}
accepted = {"n04", "crlf", "coding3", "real"}           # the bytes the parser reads (n04 is refused by layout)
bad = 0
for fn in sorted(os.listdir(sys.argv[2])):
    x = fn[:-5]; path = os.path.join(sys.argv[2], fn)
    pip = {}
    for pr in parse_requirements(path, session=None):
        r = Requirement(pr.requirement); (spec,) = list(r.specifier)
        pip[lockparse.norm(r.name)] = spec.version
    try:
        ents, errs = lockparse.parse(lockparse.read(path))
        ours = {e["key"]: e["version"] for e in ents}; verdict = "read"
    except lockparse.LockEncodingError as e:
        ours, errs, verdict = None, e.problems, "REFUSED"
    ok = all(pip.get(k) == v for k, v in want[x].items())
    if x in accepted:
        ok = ok and ours == pip and not errs
    else:
        ok = ok and verdict == "REFUSED"
    print("%-8s pip reads %s  lockparse %s  %s" % (x, " ".join("%s==%s" % (k, pip.get(k)) for k in want[x]), verdict, "OK" if ok else "WRONG"))
    bad += not ok
sys.exit(1 if bad else 0)
PY
    tm_assert_grep "n01      pip reads pyasn1==0.4.8  lockparse REFUSED  OK" "${TM_TMP}/out" "N01 was not measured against pip"
    tm_assert_grep "n02      pip reads pyasn1==0.4.8  lockparse REFUSED  OK" "${TM_TMP}/out" "N02 was not measured against pip"
    tm_assert_grep "n04      pip reads pyasn1==0.6.4  lockparse read  OK" "${TM_TMP}/out" "N04 was not measured against pip"
}
tm_case "n01-n04-pip-reads-the-raw-bytes-the-parser-refuses" none n_pip_oracle_raw_bytes

tm_finish
