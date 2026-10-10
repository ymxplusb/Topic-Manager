#!/usr/bin/env bash
# =============================================================================
# t55 — v1.3.3 (WO-0009, REG-0068): THE VENV'S OWN PIP IS A LOCKED PACKAGE,
# AND THE VENV HOLDS EXACTLY THE LOCK.
#
#   `python3 -m venv` seeds the venv with pip itself — 24.0 from Ubuntu
#   24.04's ensurepip, six advisories — and until v1.3.2 nothing pinned,
#   hashed, scanned or upgraded it. Now:
#
#   lock      requirements.txt pins pip (venv tooling) and requirements.lock
#             carries it with its hash; the generator refuses a resolution
#             that drops a direct pin (pip included)
#   block     lock_entry / venv_bootstrap_pip / venv_drift are one block,
#             byte-identical in install.sh and the upgrade
#   bootstrap the venv's pip is upgraded from the lock's pip entry ALONE,
#             --require-hashes --only-binary :all:, from the same source as
#             every other wheel, and must then report the locked version
#   order     both installers, driven through their REAL Phase-8 code with a
#             stand-in venv: venv created, pip upgraded, lock installed,
#             venv checked — in that order, online and offline
#   drift     the installed venv must hold EXACTLY the locked set: an extra
#             package, a missing one, another version or a duplicate is RED
#             (exit 1); no lock or no site-packages is "cannot say" (exit 3)
#   audit     --audit-only reports the INSTALLED venv against the release's
#             lock as WARN rows (pip 24.0 on a v1.3.2 host), never a pass
#   sca       tools/sca-check.sh queries pip: 24.0 in the lock is RED
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "v1.3.3 venv tooling: pip locked and upgraded first, the venv held to exactly the lock"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
REAL_PY="$(command -v python3 || true)"
[ -n "$REAL_PY" ] || tm_die "no python3 on PATH (the drift check runs the system python3)"
GEN="${TM_GEN_LOCK:-${TM_REPO_ROOT}/tools/gen-requirements-lock.py}"
SCA="${TM_SCA_CHECK:-${TM_REPO_ROOT}/tools/sca-check.sh}"

_BLK_START='^# >>> v1\.3\.3 venv tooling and drift'
_BLK_END='^# <<< v1\.3\.3 venv tooling and drift'
_block() { tm_extract_between "$1" "$_BLK_START" "$_BLK_END"; }

# Fixture venvs are laid out as `python3 -m venv` lays them out (bin/python3
# a link to THIS interpreter, pyvenv.cfg home = its directory) by
# tests/lib/fake_venv.py, and distributions as pip leaves them (import
# package, dist-info, RECORD with sha256) by tests/lib/fake_dist.py; pip in
# them is tests/lib/fake_pip_main.py, run by the REAL interpreter.
export STUB_FAKE_DIST="${TM_REPO_ROOT}/tests/lib/fake_dist.py"
FAKE_VENV="${TM_REPO_ROOT}/tests/lib/fake_venv.py"
PYMINOR="$("$REAL_PY" -c 'import sys; print(sys.version_info[1])')"
SPREL="lib/python3.${PYMINOR}/site-packages"
_dist() { "$REAL_PY" "$STUB_FAKE_DIST" "$1" "$2" "$3"; }
# _venv_from_lock <venv> <lock> — a venv holding exactly what the lock pins.
_venv_from_lock() {
    local sp="${1}/${SPREL}" nv
    "$REAL_PY" "$FAKE_VENV" "$1" --clear
    rm -rf "$sp"/pip "$sp"/pip-*.dist-info
    while IFS= read -r nv; do _dist "$sp" "${nv%%==*}" "${nv#*==}"; done \
        < <(sed -n 's/^\([A-Za-z0-9._-]*\)==\([^ \\]*\).*/\1==\2/p' "$2")
}
# The pass line for a venv holding the 16 locked packages as _dist writes
# them: two hashed files each, and pip four more (__main__.py, three bin/).
PYEXE="$("$REAL_PY" -c 'import os, sys; print(os.path.realpath(sys.executable))')"
PYHOME="$("$REAL_PY" -c 'import os, sys; print(os.path.dirname(sys.executable))')"
PASS16="16 packages, exactly the lock (36 files match their RECORD)"
# _drift <venv> <lock> — the REAL venv_drift from install.sh; RC + out.
_drift() {
    RC=0
    bash -c "$(_block "$(tm_install_sh)")"$'\n''venv_drift "$1" "$2"' _ "$1" "$2" > "${TM_TMP}/out" 2>&1 || RC=$?
}

# ─── the lock ────────────────────────────────────────────────────────────────
l_lock_carries_pip() {
    local req="${TM_REPO_ROOT}/requirements.txt" lock="${TM_REPO_ROOT}/requirements.lock" want
    want="$(sed -n 's/^pip==\([^[:space:]#]*\).*/\1/p' "$req")"
    tm_assert_eq "26.2.1" "$want" "requirements.txt does not pin pip 26.2.1 (venv tooling)"
    grep -q '^# venv tooling' "$req" || _tm_afail "requirements.txt has no venv tooling section"
    # In the lock, through the ONE lock parser (pip's rules), with its hash.
    "$PY" "${TM_REPO_ROOT}/tools/lib/lockparse.py" "$lock" > "${TM_TMP}/out" 2>&1 || _tm_afail "the lock does not parse: $(cat "${TM_TMP}/out")"
    grep -qx 'pip==26.2.1' "${TM_TMP}/out" || _tm_afail "the lock parser does not read pip==26.2.1"
    tm_assert_eq "#entries 16" "$(tail -n 1 "${TM_TMP}/out")" "the lock is not 15 app packages + pip"
    local ent; ent="$(grep -A1 '^pip==26\.2\.1 \\$' "$lock")"
    [[ "$ent" == *"--hash=sha256:71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e" ]] \
        || _tm_afail "the lock's pip entry does not carry the hash of pip-26.2.1-py3-none-any.whl: ${ent}"
    # The upgrade claims it: a pin no Phase 8 stage claims stops the run at
    # Phase 5. Its REAL load_pins + require_pins line, on the real file.
    {
        echo 'set -euo pipefail'; echo 'fail() { echo "[FAIL] $*"; exit 1; }'
        tm_extract_func "$(tm_upgrade_sh)" load_pins; tm_extract_func "$(tm_upgrade_sh)" require_pins
        echo 'declare -A PINS; load_pins "$1"'
        tm_extract_line "$(tm_upgrade_sh)" '^require_pins [a-z0-9 -]+$'
        echo 'echo "CLAIMED pip=${PINS[pip]}"'
    } > "${TM_TMP}/rp.sh"
    RC=0; bash "${TM_TMP}/rp.sh" "$req" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "the upgrade refuses the real requirements.txt: $(cat "${TM_TMP}/out")"
    tm_assert_eq "CLAIMED pip=26.2.1" "$(cat "${TM_TMP}/out")" "the upgrade does not claim and read the pip pin"
}
tm_case "requirements-and-the-lock-carry-pip-with-its-hash" none l_lock_carries_pip

# The generator resolves pip like any package, but refuses a resolution that
# drops a direct pin rather than writing a lock without it.
l_generator_refuses_a_lost_pin() {
    printf 'Flask==3.1.3\npip==26.2.1\n' > "${TM_TMP}/requirements.txt"
    "$PY" - "$GEN" "${TM_REPO_ROOT}/tools/lib" "${TM_TMP}/requirements.txt" > "${TM_TMP}/out" 2>&1 <<'PY'
import importlib.util, sys
gen, lib, req = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, lib)
spec = importlib.util.spec_from_file_location("gen", gen)
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
g.REQ = req
item = lambda n, v: {"metadata": {"name": n, "version": v}}
g.resolve_report = lambda constraints=None: [item("Flask", "3.1.3"), item("pip", "26.2.1"), item("blinker", "1.9.0")]
print("WITH", g.resolve())
for label, rep in (("WITHOUT", [item("Flask", "3.1.3"), item("blinker", "1.9.0")]),
                   ("OTHER", [item("Flask", "3.1.3"), item("pip", "24.0")])):
    g.resolve_report = lambda constraints=None, rep=rep: rep
    try:
        print(label, "WROTE", g.resolve())
    except SystemExit as e:
        print(label, "REFUSED", e)
PY
    grep -q "^WITH \[('blinker', '1.9.0'), ('Flask', '3.1.3'), ('pip', '26.2.1')\]$" "${TM_TMP}/out" \
        || _tm_afail "a resolution carrying pip was not returned as it is: $(cat "${TM_TMP}/out")"
    grep -q '^WITHOUT REFUSED .*pip==26\.2\.1' "${TM_TMP}/out" \
        || _tm_afail "a resolution that dropped pip was not refused: $(cat "${TM_TMP}/out")"
    grep -q '^OTHER REFUSED .*pip==26\.2\.1' "${TM_TMP}/out" \
        || _tm_afail "a resolution that put another pip in was not refused: $(cat "${TM_TMP}/out")"
}
tm_case "the-generator-refuses-a-resolution-without-a-direct-pin" none l_generator_refuses_a_lost_pin

# ─── the shared block ────────────────────────────────────────────────────────
b_block_identical() {
    local a b
    a="$(_block "$(tm_install_sh)")"; b="$(_block "$(tm_upgrade_sh)")"
    [ "$a" = "$b" ] || _tm_afail "the venv block differs between install.sh and the upgrade: $(diff <(echo "$a") <(echo "$b") | head -5)"
}
tm_case "the-venv-block-is-byte-identical-in-both-scripts" none b_block_identical

b_lock_entry() {
    local blk; blk="$(_block "$(tm_install_sh)")"
    {
        printf 'alpha==1.0 \\\n    --hash=sha256:%064d\n' 1
        printf 'pipx==1.2.3 \\\n    --hash=sha256:%064d\n' 2
        printf 'Pip==26.2.1 \\\n    --hash=sha256:%064d \\\n    --hash=sha256:%064d\n' 3 4
        printf 'zeta==2.0 \\\n    --hash=sha256:%064d\n' 5
    } > "${TM_TMP}/l.lock"
    RC=0; bash -c "${blk}"$'\n''lock_entry "$1" pip' _ "${TM_TMP}/l.lock" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "lock_entry refused a lock with one pip entry: $(cat "${TM_TMP}/out")"
    printf 'Pip==26.2.1 \\\n    --hash=sha256:%064d \\\n    --hash=sha256:%064d\n' 3 4 > "${TM_TMP}/want"
    cmp -s "${TM_TMP}/want" "${TM_TMP}/out" || _tm_afail "lock_entry did not print exactly pip's entry: $(cat "${TM_TMP}/out")"
    # No pip, and pip twice: refused, never a guess.
    {
        printf 'alpha==1.0 \\\n    --hash=sha256:%064d\n' 1
        printf 'pipx==1.2.3 \\\n    --hash=sha256:%064d\n' 2
    } > "${TM_TMP}/none.lock"
    RC=0; bash -c "${blk}"$'\n''lock_entry "$1" pip' _ "${TM_TMP}/none.lock" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "lock_entry accepted a lock with no pip entry"
    cat "${TM_TMP}/l.lock" > "${TM_TMP}/two.lock"; printf 'pip==24.0 \\\n    --hash=sha256:%064d\n' 6 >> "${TM_TMP}/two.lock"
    RC=0; bash -c "${blk}"$'\n''lock_entry "$1" pip' _ "${TM_TMP}/two.lock" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "lock_entry accepted a lock with TWO pip entries"
}
tm_case "lock-entry-prints-one-packages-entry-or-refuses" linux b_lock_entry

# A stand-in `python3` for the installers: `-m venv [--clear] DIR` is
# tests/lib/fake_venv.py (seeded with the stand-in pip 24.0, as Ubuntu 24.04's
# ensurepip seeds 24.0); anything else is the real interpreter (venv_drift
# runs it). The venv's own bin/python3 IS the real interpreter, so every
# `<venv>/bin/python3 -m pip` and `<venv>/bin/pip` the installers run is the
# stand-in pip, and `-c "import flask, ..."` really imports.
_stub_system_python() {
    mkdir -p "${TM_TMP}/sysbin"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then\n'
        printf '    for d in "$@"; do :; done; echo "venv $*" >> "$STUB_LOG"\n'
        printf '    c=""; case " $* " in *" --clear "*) c=--clear ;; esac\n'
        printf '    exec "%s" "%s" "$d" $c\n' "$REAL_PY" "$FAKE_VENV"
        printf 'fi\nexec "%s" "$@"\n' "$REAL_PY"
    } > "${TM_TMP}/sysbin/python3"
    chmod +x "${TM_TMP}/sysbin/python3"
}

b_bootstrap_pip() {
    local blk V L; blk="$(_block "$(tm_install_sh)")"; V="${TM_TMP}/v"; L="${TM_REPO_ROOT}/requirements.lock"
    "$REAL_PY" "$FAKE_VENV" "$V" --clear
    export STUB_LOG="${TM_TMP}/log"
    RC=0; bash -c "${blk}"$'\n''venv_bootstrap_pip "$@"' _ "$V" "$L" --no-index --find-links=/bundle > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "the pip bootstrap failed: $(cat "${TM_TMP}/out")"
    tm_assert_eq "26.2.1" "$(cat "${TM_TMP}/out")" "the bootstrap did not report the locked pip"
    tm_assert_eq 1 "$(grep -c . "$STUB_LOG")" "the bootstrap ran pip more than once"
    grep -q -- '^pip install --disable-pip-version-check --quiet --require-hashes --only-binary :all: --no-index --find-links=/bundle -r ' "$STUB_LOG" \
        || _tm_afail "the bootstrap is not hash-locked, binary-only, from the given source: $(cat "$STUB_LOG")"
    # pip's entry ALONE (with its hash), not the whole lock and not unhashed.
    _block "$(tm_install_sh)" > "${TM_TMP}/blk.sh"
    bash -c '. "$1"; lock_entry "$2" pip' _ "${TM_TMP}/blk.sh" "$L" > "${TM_TMP}/want"
    cmp -s "${TM_TMP}/want" "${STUB_LOG}.req.1" || _tm_afail "the bootstrap installed from something other than the lock's pip entry: $(cat "${STUB_LOG}.req.1")"
    grep -q -- '--hash=sha256:' "${STUB_LOG}.req.1" || _tm_afail "the bootstrap's requirement carries no hash"
    # A failed install, and a pip that does not report the locked version: refused.
    rm -f "${STUB_LOG}"*; "$REAL_PY" "$FAKE_VENV" "$V" --clear
    RC=0; STUB_PIP_RC=1 bash -c "${blk}"$'\n''venv_bootstrap_pip "$@"' _ "$V" "$L" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "the bootstrap passed a failed pip install"
    grep -q 'failed' "${TM_TMP}/out" || _tm_afail "the failed install was not said: $(cat "${TM_TMP}/out")"
    rm -f "${STUB_LOG}"*
    RC=0; STUB_PIP_REPORT=24.0 bash -c "${blk}"$'\n''venv_bootstrap_pip "$@"' _ "$V" "$L" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "the bootstrap passed a venv whose pip still reports 24.0"
    grep -q "reports '24.0', not the locked 26.2.1" "${TM_TMP}/out" || _tm_afail "the version mismatch was not named: $(cat "${TM_TMP}/out")"
    # A lock with no pip entry (a pre-1.3.3 lock): refused before pip runs.
    grep -v -e '^pip==' -e '71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e' "$L" > "${TM_TMP}/old.lock"
    rm -f "${STUB_LOG}"*
    RC=0; bash -c "${blk}"$'\n''venv_bootstrap_pip "$@"' _ "$V" "${TM_TMP}/old.lock" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "the bootstrap passed a lock with no pip entry"
    [ ! -s "$STUB_LOG" ] || _tm_afail "pip ran although the lock has no pip entry"
}
tm_case "the-pip-bootstrap-installs-the-locked-entry-alone-and-checks-it" linux b_bootstrap_pip

# ─── stage order, driven through each installer's REAL Phase-8 code ──────────
_phase8_upgrade() {   # _phase8_upgrade <online true|false>
    local W="${TM_TMP}/work"
    mkdir -p "$W/install/packages/python"
    cp "${TM_REPO_ROOT}/requirements.txt" "${TM_REPO_ROOT}/requirements.lock" "$W/"
    _stub_system_python
    {
        echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*"; exit 1; }; info() { echo "[INFO] $*"; }; success() { echo "[OK] $*"; }; warn() { echo "[WARN] $*"; }'
        _block "$(tm_upgrade_sh)"
        tm_extract_func "$(tm_upgrade_sh)" load_pins
        echo "declare -A PINS; WORK_DIR='${W}'; VENV='${TM_TMP}/venv'; ONLINE=$1"
        echo 'load_pins "${WORK_DIR}/requirements.txt"'
        echo 'PIN_PIP="${PINS[pip]}"; PIN_FLASK=x PIN_WERKZEUG=x PIN_GUNICORN=x PIN_LDAP3=x PIN_PYYAML=x PIN_CRYPTOGRAPHY=x PIN_CONFLUENT_KAFKA=x'
        tm_extract_between "$(tm_upgrade_sh)" '^info "Creating virtual environment \.\.\."$' '^success "Dependency imports verified"$'
        echo 'echo PHASE8-DONE'
    } > "${TM_TMP}/p8.sh"
    export STUB_LOG="${TM_TMP}/log"; rm -f "${STUB_LOG}"*
    RC=0; PATH="${TM_TMP}/sysbin:${PATH}" bash "${TM_TMP}/p8.sh" > "${TM_TMP}/out" 2>&1 || RC=$?
}
_phase8_install() {   # _phase8_install <online true|false>
    local S="${TM_TMP}/src"
    mkdir -p "$S/install/packages/python"
    cp "${TM_REPO_ROOT}/requirements.txt" "${TM_REPO_ROOT}/requirements.lock" "$S/"
    _stub_system_python
    {
        echo 'set -euo pipefail'
        echo 'die() { echo "[FAIL] $*"; exit 1; }; info() { echo "[INFO] $*"; }; success() { echo "[OK] $*"; }; warn() { echo "[WARN] $*"; }'
        _block "$(tm_install_sh)"
        echo "SCRIPT_DIR='${S}'; VENV='${TM_TMP}/venv'; PYTHON=python3; ONLINE=$1"
        tm_extract_between "$(tm_install_sh)" '^# ─── Python venv \+ packages' '^success "Python environment ready'
        echo 'echo PHASE8-DONE'
    } > "${TM_TMP}/p8.sh"
    export STUB_LOG="${TM_TMP}/log"; rm -f "${STUB_LOG}"*
    RC=0; PATH="${TM_TMP}/sysbin:${PATH}" bash "${TM_TMP}/p8.sh" > "${TM_TMP}/out" 2>&1 || RC=$?
}
# _assert_order <online> — venv, then the pip entry alone, then the lock.
_assert_order() {
    local src=""; [ "$1" = true ] || src=" --no-index --find-links=${2}/install/packages/python"
    tm_assert_rc 0 "$RC" "Phase 8 failed: $(cat "${TM_TMP}/out")"
    tm_assert_grep "PHASE8-DONE" "${TM_TMP}/out" "Phase 8 did not run to its end"
    tm_assert_eq 3 "$(grep -c . "$STUB_LOG")" "Phase 8 did not run exactly: venv, pip, lock: $(cat "$STUB_LOG")"
    local l1 l2 l3
    l1="$(sed -n 1p "$STUB_LOG")"; l2="$(sed -n 2p "$STUB_LOG")"; l3="$(sed -n 3p "$STUB_LOG")"
    [[ "$l1" == "venv "* ]] || _tm_afail "the venv was not created first: $(cat "$STUB_LOG")"
    [[ "$l2" == *"--require-hashes --only-binary :all:${src} -r "* ]] \
        || _tm_afail "step 2 is not the hash-locked pip upgrade from the install's source: ${l2}"
    tm_assert_eq 1 "$(grep -c '^pip==' "${STUB_LOG}.req.1")" "step 2 did not install the pip entry"
    tm_assert_eq 1 "$(grep -c '==' "${STUB_LOG}.req.1")" "step 2 installed more than the pip entry"
    [[ "$l3" == *"-r ${2}/requirements.lock"* ]] || _tm_afail "step 3 is not the lock install: ${l3}"
    [[ "$l3" == *"--require-hashes --only-binary :all:${src}"* ]] \
        || _tm_afail "the lock install is not from the same source: ${l3}"
    grep -q 'venv tooling: pip 26.2.1' "${TM_TMP}/out" || _tm_afail "the pip stage did not report 26.2.1: $(cat "${TM_TMP}/out")"
    grep -qF "$PASS16" "${TM_TMP}/out" || _tm_afail "the drift check did not pass the installed venv: $(cat "${TM_TMP}/out")"
}
o_upgrade_order() {
    _phase8_upgrade true;  _assert_order true "${TM_TMP}/work"
    _phase8_upgrade false; _assert_order false "${TM_TMP}/work"
    # An extra package after the install: the upgrade FAILS here (the EXIT
    # trap then rolls back), naming it.
    export STUB_EXTRA=six; _phase8_upgrade true; unset STUB_EXTRA
    tm_assert_rc 1 "$RC" "the upgrade passed a venv holding a package the lock does not pin"
    grep -q 'EXTRA six: 1.0 installed, not in the lock' "${TM_TMP}/out" || _tm_afail "the extra package was not named: $(cat "${TM_TMP}/out")"
    grep -q PHASE8-DONE "${TM_TMP}/out" && _tm_afail "Phase 8 carried on past the drift"
    return 0
}
tm_case "upgrade-phase-8-venv-then-pip-then-lock-then-drift" linux o_upgrade_order

# _assert_root_venv <venv> — every entry root:root, directories 0755, files
# 0755/0644 by their execute bit, symlinks left as links.
_assert_root_venv() {
    local bad
    bad="$(find "$1" \( ! -user root -o ! -group root \) -print)"
    [ -z "$bad" ] || _tm_afail "not root:root after the install: $(head -n 3 <<<"$bad")"
    bad="$(find "$1" \( \( -type d ! -perm 0755 \) -o \( -type f ! -perm 0755 ! -perm 0644 \) \) -print)"
    [ -z "$bad" ] || _tm_afail "modes not 0755/0644: $(head -n 3 <<<"$bad")"
    [ -L "$1/bin/python3" ] || _tm_afail "bin/python3 is no longer a link"
    tm_assert_eq 755 "$(stat -c '%a' "$1/bin/pip")" "an entry point lost its execute bit"
    tm_assert_eq 644 "$(stat -c '%a' "$1/pyvenv.cfg")" "pyvenv.cfg is not 0644"
}
o_install_order() {
    # REG-0078: the venv is handed over app-owned and world-writable (as an
    # older upgrade left it); install.sh must leave it root's.
    export STUB_VENV_OWNER="$TM_WEB_USER"; _phase8_install true; unset STUB_VENV_OWNER
    _assert_order true "${TM_TMP}/src"
    _assert_root_venv "${TM_TMP}/venv"
    # A reinstall over a venv an older release left a package in: the
    # install starts from an empty venv, so the leftover is gone and the
    # drift check passes.
    _dist "${TM_TMP}/venv/${SPREL}" leftover 0.9
    _phase8_install true
    tm_assert_rc 0 "$RC" "a reinstall over a venv holding a leftover package failed: $(cat "${TM_TMP}/out")"
    [ ! -e "${TM_TMP}/venv/${SPREL}/leftover-0.9.dist-info" ] \
        || _tm_afail "the reinstall kept a package the old venv held (no --clear)"
    _phase8_install false; _assert_order false "${TM_TMP}/src"
    export STUB_EXTRA=six; _phase8_install true; unset STUB_EXTRA
    tm_assert_rc 1 "$RC" "install.sh passed a venv holding a package the lock does not pin"
    grep -q 'EXTRA six: 1.0 installed, not in the lock' "${TM_TMP}/out" || _tm_afail "the extra package was not named: $(cat "${TM_TMP}/out")"
    return 0
}
tm_case "install-sh-venv-then-pip-then-lock-then-drift" linux,chown o_install_order

# REG-0078: lock_down_venv itself, and the upgrade's Phase 10 calling it.
r_lock_down() {
    local blk V="${TM_TMP}/v"; blk="$(_block "$(tm_install_sh)")"
    STUB_VENV_OWNER="$TM_WEB_USER" "$REAL_PY" "$FAKE_VENV" "$V" --clear
    chmod 4755 "$V/bin/pip"; chmod 0700 "$V/${SPREL}"
    : > "${TM_TMP}/victim"; chown "$TM_WEB_USER" "${TM_TMP}/victim"; chmod 666 "${TM_TMP}/victim"
    ln -s "${TM_TMP}/victim" "$V/${SPREL}/link-out"
    RC=0; bash -c "${blk}"$'\n''lock_down_venv "$1"' _ "$V" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "lock_down_venv failed: $(cat "${TM_TMP}/out")"
    _assert_root_venv "$V"
    tm_assert_eq 755 "$(stat -c '%a' "$V/bin/pip")" "a setuid bit survived"
    tm_assert_eq "666 ${TM_WEB_USER}" "$(stat -c '%a %U' "${TM_TMP}/victim")" "lock_down_venv followed a symlink out of the venv"
    tm_assert_eq root "$(stat -c '%U' "$V/${SPREL}/link-out")" "the symlink itself was not taken"
    # Not a directory, or a symlink to one: refused.
    ln -s "$V" "${TM_TMP}/vlink"
    RC=0; bash -c "${blk}"$'\n''lock_down_venv "$1"' _ "${TM_TMP}/vlink" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "a symlinked venv path was locked down through the link"
    RC=0; bash -c "${blk}"$'\n''lock_down_venv "$1"' _ "${TM_TMP}/none" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "a missing venv was 'locked down'"
}
tm_case "lock-down-venv-makes-it-roots-without-following-links" linux,chown r_lock_down

r_upgrade_phase10() {
    local H="${TM_TMP}/app"
    mkdir -p "$H/tm"; : > "$H/wsgi.py"
    STUB_VENV_OWNER="$TM_WEB_USER" "$REAL_PY" "$FAKE_VENV" "$H/venv" --clear
    {
        echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*"; exit 1; }; apply_baseline() { :; }; safe_install_dir() { :; }'
        _block "$(tm_upgrade_sh)"
        echo "APP_HOME='$H'; VENV='$H/venv'; APP_USER='$TM_WEB_USER'"
        tm_extract_between "$(tm_upgrade_sh)" '^chown -R "\$\{APP_USER\}:\$\{APP_USER\}" "\$\{APP_HOME\}/tm"' '^apply_baseline "\$\{APP_HOME\}/logs"'
        echo 'echo PHASE10-DONE'
    } > "${TM_TMP}/p10.sh"
    RC=0; bash "${TM_TMP}/p10.sh" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "the upgrade ownership step failed: $(cat "${TM_TMP}/out")"
    tm_assert_grep PHASE10-DONE "${TM_TMP}/out" "the step did not run to its end"
    _assert_root_venv "$H/venv"
    tm_assert_eq "$TM_WEB_USER" "$(stat -c '%U' "$H/tm")" "tm/ is no longer the service account's"
}
tm_case "upgrade-phase-10-leaves-the-venv-roots" linux,chown r_upgrade_phase10

# ─── the drift check ─────────────────────────────────────────────────────────
d_drift() {
    local L="${TM_REPO_ROOT}/requirements.lock" V="${TM_TMP}/v" SP
    SP="${V}/${SPREL}"
    _venv_from_lock "$V" "$L"; _drift "$V" "$L"
    tm_assert_rc 0 "$RC" "a venv holding exactly the lock failed: $(cat "${TM_TMP}/out")"
    tm_assert_eq "$PASS16" "$(cat "${TM_TMP}/out")" "the pass line"
    # An extra package.
    _dist "$SP" six 1.17.0; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "an extra package (six) passed"
    tm_assert_eq "EXTRA six: 1.17.0 installed, not in the lock" "$(cat "${TM_TMP}/out")" "the extra package line"
    rm -rf "$SP"/six-* "$SP"/six
    # The wrong pip: ensurepip's, as a v1.3.2 host has it.
    rm -rf "$SP"/pip-*; _dist "$SP" pip 24.0; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "pip 24.0 against a lock pinning 26.2.1 passed"
    tm_assert_eq "DIFFERENT pip: 24.0 installed, the lock pins 26.2.1" "$(cat "${TM_TMP}/out")" "the wrong-pip line"
    # Two pips at once (a half-finished upgrade), and a missing package.
    _dist "$SP" pip 26.2.1; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "two pip installs passed"
    grep -q '^DUPLICATE pip: installed twice (24.0, 26.2.1)$' "${TM_TMP}/out" || _tm_afail "the duplicate was not named: $(cat "${TM_TMP}/out")"
    rm -rf "$SP"/pip-24.0.dist-info "$SP"/cffi-* "$SP"/cffi; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "a venv missing cffi passed"
    tm_assert_eq "MISSING cffi: not installed, the lock pins 2.1.1" "$(cat "${TM_TMP}/out")" "the missing line"
    # Names compare as pip compares them (PyYAML / pyyaml, confluent_kafka).
    _dist "$SP" cffi 2.1.1; rm -rf "$SP"/PyYAML-* "$SP"/yaml; _dist "$SP" pyyaml 6.0.3; _drift "$V" "$L"
    tm_assert_rc 0 "$RC" "a differently-spelt name was read as drift: $(cat "${TM_TMP}/out")"
    # A distribution whose metadata names nothing: a finding, never skipped.
    mkdir -p "$SP/ghost-1.0.dist-info"; printf 'Metadata-Version: 2.1\n' > "$SP/ghost-1.0.dist-info/METADATA"
    _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "a distribution with no name passed"
    tm_assert_eq "UNREADABLE ?: a distribution with no name or version" "$(cat "${TM_TMP}/out")" "the unreadable line"
    rm -rf "$SP/ghost-1.0.dist-info"
    # Cannot say: no lock, a lock that pins nothing, no site-packages. Exit 3.
    _drift "$V" "${TM_TMP}/nope.lock"; tm_assert_rc 3 "$RC" "a missing lock was not 'cannot say'"
    printf '# nothing\n' > "${TM_TMP}/empty.lock"; _drift "$V" "${TM_TMP}/empty.lock"; tm_assert_rc 3 "$RC" "an empty lock was not 'cannot say'"
    _drift "${TM_TMP}/novenv" "$L"; tm_assert_rc 3 "$RC" "a missing venv was not 'cannot say'"
}
tm_case "the-drift-check-is-red-on-extra-missing-different-duplicate" linux d_drift

# REG-0069 (gatekeeper P1-P4 + Daybreak Blue F-01): venvs whose metadata
# matches the lock but which can still import code outside it.
d_drift_escapes() {
    local L="${TM_REPO_ROOT}/requirements.lock" V="${TM_TMP}/v" SP
    SP="${V}/${SPREL}"
    _venv_from_lock "$V" "$L"; _drift "$V" "$L"
    tm_assert_rc 0 "$RC" "the clean venv failed: $(cat "${TM_TMP}/out")"
    cp "$V/pyvenv.cfg" "${TM_TMP}/cfg.ok"
    # A runtime byte-code cache of a RECORDed source is not an escape.
    mkdir -p "$SP/flask/__pycache__"; : > "$SP/flask/__pycache__/__init__.cpython-3${PYMINOR}.pyc"; _drift "$V" "$L"
    tm_assert_rc 0 "$RC" "a run-time .pyc of a RECORDed source was a finding: $(cat "${TM_TMP}/out")"
    # P1: a package installed, then its dist-info deleted: six.py importable.
    _dist "$SP" six 1.17.0; rm -rf "$SP"/six-1.17.0.dist-info; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "P1: a package with its dist-info removed passed"
    tm_assert_eq "UNOWNED six/__init__.py: in site-packages, in no distribution's RECORD" "$(cat "${TM_TMP}/out")" "P1 line"
    rm -rf "$SP/six"
    # ... and a top-level orphan .pyc, a sitecustomize.py, a symlink out.
    mkdir -p "$SP/__pycache__"; : > "$SP/__pycache__/evil.cpython-3${PYMINOR}.pyc"
    : > "$SP/sitecustomize.py"; ln -s "${TM_TMP}" "$SP/outside"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "an orphan .pyc / sitecustomize.py / symlink passed"
    grep -qx "UNOWNED __pycache__/evil.cpython-3${PYMINOR}.pyc: in site-packages, in no distribution's RECORD" "${TM_TMP}/out" || _tm_afail "orphan .pyc not named: $(cat "${TM_TMP}/out")"
    grep -qx "UNOWNED sitecustomize.py: in site-packages, in no distribution's RECORD" "${TM_TMP}/out" || _tm_afail "sitecustomize.py not named: $(cat "${TM_TMP}/out")"
    grep -qx "UNOWNED outside (a symlink): in site-packages, in no distribution's RECORD" "${TM_TMP}/out" || _tm_afail "the symlink not named: $(cat "${TM_TMP}/out")"
    rm -rf "$SP/__pycache__" "$SP/sitecustomize.py" "$SP/outside"
    # Many unowned files: ten named, the rest (here exactly one) counted.
    mkdir -p "$SP/junk"; for i in 01 02 03 04 05 06 07 08 09 10 11; do : > "$SP/junk/m${i}.py"; done; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "eleven unowned files passed"
    tm_assert_eq 11 "$(grep -c '^UNOWNED ' "${TM_TMP}/out")" "ten named + one count line"
    tm_assert_eq "UNOWNED ...: and 1 more files in no distribution's RECORD" "$(tail -n 1 "${TM_TMP}/out")" "the count line"
    rm -rf "$SP/junk"
    # P2: a .pth pointing outside the venv.
    printf '/w/extra\n' > "$SP/evil.pth"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "P2: a .pth passed"
    tm_assert_eq "PTH evil.pth: a .pth file no installed distribution put there (it adds import paths or runs code at start-up)" "$(cat "${TM_TMP}/out")" "P2 line"
    rm -f "$SP/evil.pth"
    # P3: the system site-packages switched on.
    sed -i 's/^include-system-site-packages = false$/include-system-site-packages = true/' "$V/pyvenv.cfg"
    grep -q '= true$' "$V/pyvenv.cfg" || tm_die "the P3 fixture changed nothing"
    _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "P3: include-system-site-packages = true passed"
    tm_assert_eq "SYSTEM-SITE pyvenv.cfg: include-system-site-packages = true, so the system site-packages are importable too" "$(cat "${TM_TMP}/out")" "P3 line"
    cp "${TM_TMP}/cfg.ok" "$V/pyvenv.cfg"
    rm -f "$V/pyvenv.cfg"; _drift "$V" "$L"; tm_assert_rc 3 "$RC" "no pyvenv.cfg was not 'cannot say'"
    cp "${TM_TMP}/cfg.ok" "$V/pyvenv.cfg"
    # REG-0076 (a): the key DELETED - Python reads a missing one as true.
    grep -v '^include-system-site-packages' "${TM_TMP}/cfg.ok" > "$V/pyvenv.cfg"
    _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "REG-0076a: a pyvenv.cfg with no include-system-site-packages line passed"
    tm_assert_eq "SYSTEM-SITE pyvenv.cfg: no include-system-site-packages line, which Python reads as true, so the system site-packages are importable too" "$(cat "${TM_TMP}/out")" "REG-0076a line"
    # ... and a later line saying true overrides an earlier false (last wins).
    { cat "${TM_TMP}/cfg.ok"; echo 'include-system-site-packages = true'; } > "$V/pyvenv.cfg"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "REG-0076a: a second, true, line passed"
    # REG-0076 (b): home moved to another prefix; and home missing.
    sed "s|^home = .*|home = ${TM_TMP}/evilprefix/bin|" "${TM_TMP}/cfg.ok" > "$V/pyvenv.cfg"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "REG-0076b: home elsewhere passed"
    tm_assert_eq "HOME pyvenv.cfg: home = ${TM_TMP}/evilprefix/bin, not ${PYHOME}, the directory of the python3 that made the venv" "$(cat "${TM_TMP}/out")" "REG-0076b line"
    grep -v '^home' "${TM_TMP}/cfg.ok" > "$V/pyvenv.cfg"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "REG-0076b: no home line passed"
    grep -q '^HOME pyvenv.cfg: home = (none), ' "${TM_TMP}/out" || _tm_afail "no home not named: $(cat "${TM_TMP}/out")"
    cp "${TM_TMP}/cfg.ok" "$V/pyvenv.cfg"
    # REG-0076 (c): bin/. A wrapper in place of python3; a python3.N that is
    # not a link at all; a missing link; bin/gunicorn.py; a directory.
    rm "$V/bin/python3"; printf '#!/bin/sh\nexec %s "$@"\n' "$REAL_PY" > "$V/bin/python3"; chmod +x "$V/bin/python3"
    _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "REG-0076c: a python3 wrapper passed"
    grep -qx "BIN python3: not a link to the system interpreter ${PYEXE}" "${TM_TMP}/out" || _tm_afail "the wrapper not named: $(cat "${TM_TMP}/out")"
    rm "$V/bin/python3"; ln -s "${TM_TMP}/elsewhere/python3" "$V/bin/python3"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "REG-0076c: python3 linked elsewhere passed"
    rm "$V/bin/python3"; ln -s "$REAL_PY" "$V/bin/python3"
    rm "$V/bin/python"; _drift "$V" "$L"
    tm_assert_eq "BIN python: not a link to the system interpreter ${PYEXE}" "$(cat "${TM_TMP}/out")" "a missing python link"
    ln -s python3 "$V/bin/python"
    printf 'import os\n' > "$V/bin/gunicorn.py"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "REG-0076c: bin/gunicorn.py passed"
    tm_assert_eq "BIN gunicorn.py: in the venv bin/, in no distribution's RECORD and not one of the venv's own files" "$(cat "${TM_TMP}/out")" "REG-0076c line"
    rm -f "$V/bin/gunicorn.py"; mkdir "$V/bin/sub"; _drift "$V" "$L"
    tm_assert_eq "BIN sub: not a regular file a distribution installed" "$(cat "${TM_TMP}/out")" "a directory in bin/"
    rmdir "$V/bin/sub"
    # A pip-written entry point (in pip's RECORD) and activate are fine; an
    # edited entry point is MODIFIED (its RECORD hash).
    _drift "$V" "$L"; tm_assert_rc 0 "$RC" "bin/ restored still fails: $(cat "${TM_TMP}/out")"
    printf '# x\n' >> "$V/bin/pip"; _drift "$V" "$L"
    grep -qx "MODIFIED pip: ../../../bin/pip does not match its RECORD hash" "${TM_TMP}/out" || _tm_afail "an edited bin/pip not named: $(cat "${TM_TMP}/out")"
    _dist "$SP" pip 26.2.1
    # P4: Flask 3.1.2 installed, its METADATA edited to say 3.1.3.
    rm -rf "$SP"/flask "$SP"/Flask-*.dist-info; _dist "$SP" Flask 3.1.2
    sed -i 's/^Version: 3\.1\.2$/Version: 3.1.3/' "$SP/Flask-3.1.2.dist-info/METADATA"
    grep -q '^Version: 3.1.3$' "$SP/Flask-3.1.2.dist-info/METADATA" || tm_die "the P4 fixture changed nothing"
    _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "P4: flask 3.1.2 relabelled 3.1.3 passed"
    grep -qx "MODIFIED flask: Flask-3.1.2.dist-info/METADATA does not match its RECORD hash" "${TM_TMP}/out" || _tm_afail "P4: the edited METADATA was not named: $(cat "${TM_TMP}/out")"
    grep -qx "MISLABELLED flask: Flask-3.1.2.dist-info says 3.1.2, its METADATA says 3.1.3" "${TM_TMP}/out" || _tm_afail "P4: the label was not named: $(cat "${TM_TMP}/out")"
    # ... and, with the dist-info renamed to match, the RECORD hash alone.
    mv "$SP/Flask-3.1.2.dist-info" "$SP/Flask-3.1.3.dist-info"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "P4: a renamed relabelled dist-info passed"
    tm_assert_eq 1 "$(grep -c '^MODIFIED flask: ' "${TM_TMP}/out")" "P4: the RECORD check alone must catch it"
    rm -rf "$SP"/flask "$SP"/Flask-*.dist-info; _dist "$SP" Flask 3.1.3
    # A locked file edited, and one deleted.
    printf 'import os\n' >> "$SP/flask/__init__.py"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "an edited locked file passed"
    tm_assert_eq "MODIFIED flask: flask/__init__.py does not match its RECORD hash" "$(cat "${TM_TMP}/out")" "edited file line"
    rm -f "$SP/flask/__init__.py"; _drift "$V" "$L"
    tm_assert_eq "MODIFIED flask: flask/__init__.py is missing" "$(cat "${TM_TMP}/out")" "missing file line"
    _dist "$SP" Flask 3.1.3
    # No RECORD: its files cannot be verified.
    rm -f "$SP/Flask-3.1.3.dist-info/RECORD"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "a distribution with no RECORD passed"
    grep -qx "NORECORD flask: no RECORD, so its files cannot be verified" "${TM_TMP}/out" || _tm_afail "NORECORD not named: $(cat "${TM_TMP}/out")"
    _dist "$SP" Flask 3.1.3
    # A RECORD row that points outside the venv.
    printf '../../../../../etc/passwd,sha256=AAAA,1\n' >> "$SP/Flask-3.1.3.dist-info/RECORD"; _drift "$V" "$L"
    tm_assert_rc 1 "$RC" "a RECORD pointing outside the venv passed"
    grep -q "^MODIFIED flask: its RECORD lists .*etc/passwd, outside the venv$" "${TM_TMP}/out" || _tm_afail "outside path not named: $(cat "${TM_TMP}/out")"
    _dist "$SP" Flask 3.1.3; _drift "$V" "$L"
    tm_assert_rc 0 "$RC" "the restored venv failed: $(cat "${TM_TMP}/out")"
}
tm_case "the-drift-check-is-red-on-code-outside-the-lock-reg-0069" linux d_drift_escapes

# ─── --audit-only: the INSTALLED venv against the release's lock ─────────────
_audit() {   # _audit <venv> <script-dir> -> rows in ${TM_TMP}/rows
    {
        echo 'set -euo pipefail'
        echo 'row() { printf "%s|%s|%s\n" "$1" "$2" "${3:-}"; }'
        _block "$(tm_upgrade_sh)"
        echo "VENV='$1'; SELF='$2/upgrade-full.sh'"
        tm_extract_between "$(tm_upgrade_sh)" '^echo "  ── venv packages \(v1\.3\.3' '^echo "  ── recorded permission baseline"$'
    } > "${TM_TMP}/audit.sh"
    RC=0; bash "${TM_TMP}/audit.sh" > "${TM_TMP}/rows" 2>&1 || RC=$?
}
a_audit_warns() {
    local L="${TM_REPO_ROOT}/requirements.lock" V="${TM_TMP}/v" D="${TM_TMP}/rel/install"
    mkdir -p "$D"; cp "$L" "${TM_TMP}/rel/requirements.lock"
    _venv_from_lock "$V" "$L"
    _audit "$V" "$D"
    tm_assert_rc 0 "$RC" "the audit section failed: $(cat "${TM_TMP}/rows")"
    grep -qxF "PASS|venv packages|${PASS16}" "${TM_TMP}/rows" || _tm_afail "a venv holding the lock was not a PASS: $(cat "${TM_TMP}/rows")"
    # A v1.3.2 host: ensurepip's pip.
    rm -rf "$V"/${SPREL}/pip-*; _dist "$V/${SPREL}" pip 24.0
    _audit "$V" "$D"
    grep -q '^WARN|venv pip|24.0 installed, the lock pins 26.2.1 (DIFFERENT) — this upgrade rebuilds the venv from the lock and re-checks it$' "${TM_TMP}/rows" \
        || _tm_afail "pip 24.0 was not a WARN naming both versions: $(cat "${TM_TMP}/rows")"
    grep -q '^PASS|' "${TM_TMP}/rows" && _tm_afail "a drifted venv was also reported as a PASS"
    grep -q '^BLOCK|' "${TM_TMP}/rows" && _tm_afail "venv drift blocked the upgrade that fixes it"
    # A lock that pins nothing: the drift check cannot say (exit 3) — a WARN.
    printf '# nothing\n' > "${TM_TMP}/rel/requirements.lock"
    _audit "$V" "$D"
    grep -q '^WARN|venv packages|NOT compared: .*pins nothing$' "${TM_TMP}/rows" \
        || _tm_afail "a drift check that could not say was not a WARN: $(cat "${TM_TMP}/rows")"
    # No lock beside the script: said, never a silent pass.
    _audit "$V" "${TM_TMP}/nolock/install"
    grep -q '^WARN|venv packages|NOT compared: no requirements.lock beside this script' "${TM_TMP}/rows" \
        || _tm_afail "a missing lock was not reported: $(cat "${TM_TMP}/rows")"
    return 0
}
tm_case "audit-only-warns-on-the-installed-venv-pip-24-0" linux a_audit_warns

# ─── SCA reads pip: 24.0 in the lock is RED (stand-in OSV) ───────────────────
_sca_tree55() {   # the real sca-check over the real tree, OSV played by tests/lib/osv-curl-stub.sh
    local S="${TM_TMP}/sc"
    mkdir -p "$S/tools/lib" "$S/install" "${TM_TMP}/osv"
    cp "$SCA" "$S/tools/sca-check.sh"; cp "${TM_REPO_ROOT}/tools/lib/lockparse.py" "$S/tools/lib/"
    cp "${TM_REPO_ROOT}/requirements.txt" "${TM_REPO_ROOT}/requirements.lock" "$S/"
    cp "$(tm_upgrade_sh)" "$S/install/upgrade-full.sh"
    cp "${TM_REPO_ROOT}/tests/lib/osv-curl-stub.sh" "${TM_TMP}/osv/curl"
    chmod +x "${TM_TMP}/osv/curl"
    export STUB_VULNS="pip==24.0=GHSA-4xh5-x5gv-qwph GHSA-wf93-45jw-7689"
}
s_sca_reads_pip() {
    local S="${TM_TMP}/sc"
    _sca_tree55
    RC=0; PATH="${TM_TMP}/osv:${PATH}" bash "$S/tools/sca-check.sh" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 0 "$RC" "SCA on the real tree went red: $(cat "${TM_TMP}/out")"
    grep -Eq '^  pip +26\.2\.1 +.*CLEAN' "${TM_TMP}/out" || _tm_afail "SCA did not query pip 26.2.1: $(cat "${TM_TMP}/out")"
    # pip 24.0 in the lock alone (requirements.txt still says 26.2.1): pip
    # would install 24.0, so SCA must query 24.0 and go RED.
    sed -i 's/^pip==26\.2\.1 /pip==24.0 /' "$S/requirements.lock"
    grep -q '^pip==24\.0 ' "$S/requirements.lock" || tm_die "the pip 24.0 fixture changed nothing"
    RC=0; PATH="${TM_TMP}/osv:${PATH}" bash "$S/tools/sca-check.sh" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "SCA passed a lock that installs pip 24.0: $(cat "${TM_TMP}/out")"
    grep -Eq '^  pip +24\.0 +.*VULNERABLE.*GHSA-4xh5-x5gv-qwph' "${TM_TMP}/out" || _tm_afail "SCA did not name pip 24.0's advisories: $(cat "${TM_TMP}/out")"
}
tm_case "sca-queries-pip-and-24-0-is-red" none s_sca_reads_pip

# REG-0070: only a well-formed answer for EVERY query is a verdict. With pip
# 24.0 in the lock, each broken answer must be exit 2 (could not check) and
# never print pip CLEAN; a paginated answer is followed to its advisory.
s_sca_needs_a_whole_answer() {
    local S="${TM_TMP}/sc" mode
    _sca_tree55
    sed -i 's/^pip==26\.2\.1 /pip==24.0 /' "$S/requirements.lock"
    grep -q '^pip==24\.0 ' "$S/requirements.lock" || tm_die "the pip 24.0 fixture changed nothing"
    for mode in empty token short endless http500 curlfail; do
        RC=0
        if [ "$mode" = http500 ]; then
            STUB_OSV_HTTP=500 PATH="${TM_TMP}/osv:${PATH}" bash "$S/tools/sca-check.sh" > "${TM_TMP}/out" 2>&1 || RC=$?
        elif [ "$mode" = curlfail ]; then
            STUB_OSV_CURL_RC=28 PATH="${TM_TMP}/osv:${PATH}" bash "$S/tools/sca-check.sh" > "${TM_TMP}/out" 2>&1 || RC=$?
        else
            STUB_OSV_MODE="$mode" PATH="${TM_TMP}/osv:${PATH}" bash "$S/tools/sca-check.sh" > "${TM_TMP}/out" 2>&1 || RC=$?
        fi
        tm_assert_rc 2 "$RC" "OSV answer '${mode}' was not 'could not check': $(cat "${TM_TMP}/out")"
        grep -Eq '^  pip +24\.0 +.*SKIPPED' "${TM_TMP}/out" || _tm_afail "'${mode}': pip 24.0 was not SKIPPED: $(cat "${TM_TMP}/out")"
        grep -Eq 'CLEAN' "${TM_TMP}/out" && _tm_afail "'${mode}': a package was CLEAN on an answer that is no verdict: $(cat "${TM_TMP}/out")"
    done
    RC=0; STUB_OSV_MODE=page PATH="${TM_TMP}/osv:${PATH}" bash "$S/tools/sca-check.sh" > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_rc 1 "$RC" "a paginated answer was not followed to pip 24.0's advisories: $(cat "${TM_TMP}/out")"
    grep -Eq '^  pip +24\.0 +.*VULNERABLE.*GHSA-4xh5-x5gv-qwph' "${TM_TMP}/out" || _tm_afail "page: pip 24.0 not VULNERABLE: $(cat "${TM_TMP}/out")"
    grep -Eq '^  pip +26\.2\.1 +.*CLEAN' "${TM_TMP}/out" || _tm_afail "page: the followed clean page was not CLEAN: $(cat "${TM_TMP}/out")"
}
tm_case "sca-an-answer-that-is-no-verdict-is-exit-2" none s_sca_needs_a_whole_answer

tm_finish
