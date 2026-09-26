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
    bash "$GATE" > "${TM_TMP}/out" 2>&1 || _tm_afail "the lock is inconsistent: $(cat "${TM_TMP}/out")"
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

tm_finish
