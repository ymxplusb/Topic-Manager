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
    # Structure and agreement, deterministically: curl is stubbed to fail, so
    # the gate's network-dependent completeness step reports itself NOT
    # verified instead of depending on this host's PyPI access and pip
    # (l_completeness below drives that step with a stub resolver).
    mkdir -p "${TM_TMP}/nobin"; printf '#!/bin/sh\nexit 7\n' > "${TM_TMP}/nobin/curl"; chmod +x "${TM_TMP}/nobin/curl"
    PATH="${TM_TMP}/nobin:${PATH}" bash "$GATE" > "${TM_TMP}/out" 2>&1 || _tm_afail "the lock is inconsistent: $(cat "${TM_TMP}/out")"
    # REG-0007: an offline pass is a pass of STRUCTURE only, and must say so.
    tm_assert_grep "lock completeness NOT verified (offline)" "${TM_TMP}/out"         "offline, the gate passed without saying the closure was not verified"
    local rc=0
    PATH="${TM_TMP}/nobin:${PATH}" bash "$GATE" --require-online > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_rc 3 "$rc" "--require-online passed with no network (the release-time requirement): $(cat "${TM_TMP}/out")"
    # .gitlab-ci.yml is export-ignored: absent from an archive (--remote, CI tarball).
    [ ! -f "${TM_REPO_ROOT}/.gitlab-ci.yml" ]         || grep -q 'check-requirements-lock.sh --require-online' "${TM_REPO_ROOT}/.gitlab-ci.yml"         || _tm_afail "CI does not run the lock gate with --require-online"
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
        PATH="${TM_TMP}/nobin:${PATH}" bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
            && _tm_afail "a TRANSITIVE entry with a ${bad} sha256 passed"
        tm_assert_grep "markupsafe has a malformed hash" "${TM_TMP}/out" "the ${bad} hash on a transitive entry was not named"
    done
}
_offline_wrap() { _offline; l_transitive_hash_format; }
tm_case "a-malformed-hash-on-a-transitive-entry-is-caught" none _offline_wrap

l_completeness() {
    _offline; _copy
    # Offline: say so, never pass silently.
    PATH="${TM_TMP}/nobin:${PATH}" bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "the offline gate failed on a good lock: $(cat "${TM_TMP}/out")"
    tm_assert_grep "lock completeness NOT verified (offline)" "${TM_TMP}/out" "offline, the gate passed without saying completeness was not verified"
    # Online: the resolved set is compared. A stub resolver stands in for PyPI
    # and reports a package the lock lacks — the gate must go red.
    mkdir -p "${TM_TMP}/on" "${TM_TMP}/c/tools"
    printf '#!/bin/sh\nexit 0\n' > "${TM_TMP}/on/curl"; chmod +x "${TM_TMP}/on/curl"
    printf '%s\n' 'import sys' 'print("MISSING from requirements.lock: newdep==1.0 (resolved from requirements.txt)")' 'sys.exit(1)' \
        > "${TM_TMP}/c/tools/gen-requirements-lock.py"
    PATH="${TM_TMP}/on:${PATH}" bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a lock missing a resolved package passed"
    tm_assert_grep "does not cover the resolved set" "${TM_TMP}/out" "the gate failed, but not on completeness"
    printf '%s\n' 'import sys' 'print("could not resolve")' 'sys.exit(3)' > "${TM_TMP}/c/tools/gen-requirements-lock.py"
    PATH="${TM_TMP}/on:${PATH}" bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a resolution that failed was reported as a pass"
    printf '%s\n' 'print("requirements.lock covers the resolved set (15 packages)")' > "${TM_TMP}/c/tools/gen-requirements-lock.py"
    PATH="${TM_TMP}/on:${PATH}" bash "$GATE" --root "${TM_TMP}/c" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "a complete lock failed online: $(cat "${TM_TMP}/out")"
    tm_assert_grep "covers the resolved set" "${TM_TMP}/out" "the completeness result was not printed"
}
tm_case "lock-completeness-is-checked-or-said-to-be-unchecked" none l_completeness

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
