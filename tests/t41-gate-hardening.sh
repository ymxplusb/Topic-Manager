#!/usr/bin/env bash
# =============================================================================
# t41 — THE GATES THEMSELVES (REG-0005..REG-0013, v1.2.0).
#
# An independent falsification of round 8 found each gate below passing on an
# input it exists to refuse, or refusing a valid one. Every case here is that
# REPRODUCTION, run against the real gate on a copy of the tree (the gate's
# own files are copied into a scratch root, so nothing tracked is edited), and
# each case also requires the real tree to stay green — a hardened gate that
# false-reds is not a fix.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "gate hardening: each register reproduction goes red, the real tree stays green"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
R="$TM_REPO_ROOT"

_tree() {   # _tree <paths...> — a scratch copy of the named repo paths under $FX
    FX="${TM_TMP}/tree"; mkdir -p "$FX"
    local p
    for p in "$@"; do mkdir -p "$FX/$(dirname "$p")"; cp -R "$R/$p" "$FX/$p"; done
}
_run() { RC=0; OUT="$("$@" 2>&1)" || RC=$?; OUT="${OUT//$'\r'/}"; }

# ── REG-0005: SCA reads the lock the way pip does, every package at its locked version
g_sca_lock_parse() {
    _tree tools/sca-check.sh tools/lib requirements.txt requirements.lock install/upgrade-full.sh
    _run bash "$FX/tools/sca-check.sh" --list-pins
    tm_assert_rc 0 "$RC" "the real lock does not parse: ${OUT}"
    tm_assert_eq 15 "$(grep -c . <<<"$OUT")" "the real lock is not 15 packages"
    # Indented, split over a continuation, no final newline, and a DIRECT
    # package drifted to a vulnerable version in the lock.
    local L="$FX/requirements.lock"
    sed -i 's/^MarkupSafe==/   MarkupSafe==/; s/^cryptography==50\.0\.1 /cryptography==44.0.2 /' "$L"
    printf 'zzsplit\\\n==1.2.3 \\\n    --hash=sha256:%064d' 0 >> "$L"
    _run bash "$FX/tools/sca-check.sh" --list-pins
    tm_assert_rc 0 "$RC" "the fixture lock was refused: ${OUT}"
    grep -qx 'MarkupSafe 3.0.3' <<<"$OUT" || _tm_afail "an INDENTED lock entry was dropped from the scan: ${OUT}"
    grep -qx 'zzsplit 1.2.3' <<<"$OUT" || _tm_afail "a continuation-split, unterminated last entry was dropped: ${OUT}"
    grep -qx 'cryptography 44.0.2' <<<"$OUT" || _tm_afail "the LOCKED version of a direct package is not what would be queried: ${OUT}"
    grep -q 'grep -qiE "^${n}==" "$REQ" && continue' "$FX/tools/sca-check.sh" \
        && _tm_afail "the lock loop still skips a package because requirements.txt names it"
    printf '\nwild==1.*\n' >> "$L"
    _run bash "$FX/tools/sca-check.sh" --list-pins
    tm_assert_rc 3 "$RC" "a wildcard pin in the lock was scanned as if it were a version: ${OUT}"
}
tm_case "reg0005-sca-reads-the-lock-like-pip-and-every-locked-version" none g_sca_lock_parse

# ── REG-0006: completeness = a self-consistent closure, not "newest today"
g_lock_closure() {
    _tree tools/gen-requirements-lock.py tools/lib
    printf 'Alpha==1.0\n' > "$FX/requirements.txt"
    local h; h="$(printf '%064d' 1)"
    _lock() { printf '%s\n' "$@" | sed "s/\$/ --hash=sha256:${h}/" > "$FX/requirements.lock"; }
    cat > "$FX/meta.json" <<'JSON'
{"Alpha==1.0": ["beta>=2.0", "winonly; sys_platform == 'win32'", "extra-dep; extra == 'fancy'"],
 "beta==2.1": [], "beta==1.5": [], "beta==9.0": []}
JSON
    local M; M="$(cygpath -m "$FX/meta.json" 2>/dev/null || echo "$FX/meta.json")"
    _gen() { _run env TM_LOCK_METADATA="$M" "$PY" "$FX/tools/gen-requirements-lock.py" --check-set --root "$(cygpath -m "$FX" 2>/dev/null || echo "$FX")"; }
    _lock 'Alpha==1.0' 'beta==2.1'; _gen
    tm_assert_rc 0 "$RC" "a valid, OLDER, compatible closure (beta 2.1, not the newest 9.0) was refused: ${OUT}"
    _lock 'Alpha==1.0'; _gen
    tm_assert_rc 1 "$RC" "a closure MISSING a dependency passed: ${OUT}"
    grep -q 'MISSING from requirements.lock: beta' <<<"$OUT" || _tm_afail "the missing dependency is not named: ${OUT}"
    _lock 'Alpha==1.0' 'beta==1.5'; _gen
    tm_assert_rc 1 "$RC" "a dependency locked at an INCOMPATIBLE version passed: ${OUT}"
    grep -q 'INCOMPATIBLE: beta==1.5' <<<"$OUT" || _tm_afail "the incompatible version is not named: ${OUT}"
    # An extra requirements.txt asks for brings its own dependencies into the
    # closure (Alpha[fancy] needs extra-dep); without the extra it does not.
    printf 'Alpha[fancy]==1.0\n' > "$FX/requirements.txt"; _lock 'Alpha==1.0' 'beta==2.1'; _gen
    tm_assert_rc 1 "$RC" "the dependency of an extra requirements.txt asks for was not required of the lock: ${OUT}"
    grep -q 'MISSING from requirements.lock: extra-dep' <<<"$OUT" || _tm_afail "the extra's dependency is not named: ${OUT}"
    printf 'Alpha==1.0\n' > "$FX/requirements.txt"
    printf '{}' > "$FX/meta.json"; _lock 'Alpha==1.0' 'beta==2.1'; _gen
    tm_assert_rc 3 "$RC" "a closure whose metadata could not be read was reported as verified: ${OUT}"
}
tm_case "reg0006-an-older-compatible-closure-passes-a-broken-one-fails" none g_lock_closure

# ── REG-0006 on the REAL path (no TM_LOCK_METADATA): v1.1.0's --check-set
# compares the lock with pip's resolution; at the merge that resolution became
# CONSTRAINED to the lock's own pins, so an older compatible lock resolves to
# itself. A stand-in pip (its __path__ extended to the real pip, so
# pip._vendor.packaging still imports) resolves to the constraints when given
# them and to the NEWEST beta when not, records its argv, and reports the
# declared dependencies the closure check then judges.
g_lock_constrained_resolution() {
    _tree tools/gen-requirements-lock.py tools/lib
    printf 'Alpha==1.0\n' > "$FX/requirements.txt"
    local h; h="$(printf '%064d' 1)"
    _lock() { printf '%s\n' "$@" | sed "s/\$/ --hash=sha256:${h}/" > "$FX/requirements.lock"; }
    local F="${TM_TMP}/fakepip" realpip
    realpip="$(PYTHONDONTWRITEBYTECODE=1 "$PY" -c 'import os, pip; print(os.path.dirname(pip.__file__))' | tr -d '\r')"
    [ -d "$realpip" ] || tm_die "no real pip to extend"
    mkdir -p "$F/pip"
    printf '__path__.append(%s)\n' "$("$PY" -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$realpip")" > "$F/pip/__init__.py"
    cat > "$F/pip/__main__.py" <<'PY'
import json, os, re, sys
a = sys.argv
open(os.environ["FAKE_ARGV"], "w").write(" ".join(a))
if os.environ.get("FAKE_CONFLICT"):
    sys.stderr.write("ERROR: Cannot install because these package versions have conflicting dependencies.\n"
                     "ERROR: ResolutionImpossible: for help visit https://pip.pypa.io\n")
    sys.exit(1)
pins = {}
if "-c" in a:
    for line in open(a[a.index("-c") + 1]):
        n, v = line.strip().split("==")
        pins[n.lower()] = v
pins.setdefault("alpha", "1.0")
pins.setdefault("beta", "9.0")                 # unconstrained: the newest
deps = {"alpha": ["beta>=2.0"]}
json.dump({"install": [{"metadata": {"name": n, "version": v, "requires_dist": deps.get(n, [])}}
                       for n, v in pins.items()]}, open(a[a.index("--report") + 1], "w"))
PY
    _gen() { _run env PYTHONPATH="$F" FAKE_ARGV="${TM_TMP}/argv" "$PY" "$FX/tools/gen-requirements-lock.py" --check-set --root "$(cygpath -m "$FX" 2>/dev/null || echo "$FX")"; }
    _lock 'Alpha==1.0' 'beta==2.1'; _gen
    tm_assert_rc 0 "$RC" "a valid OLDER closure was compared with an unconstrained (newest) resolution: ${OUT}"
    grep -q 'covers the resolved set (2 packages)' <<<"$OUT" || _tm_afail "no verdict line the gate can read: ${OUT}"
    grep -q ' -c ' "${TM_TMP}/argv" || _tm_afail "pip was not given the lock as constraints: $(cat "${TM_TMP}/argv")"
    _lock 'Alpha==1.0'; _gen
    tm_assert_rc 1 "$RC" "a lock missing beta passed the constrained resolution: ${OUT}"
    grep -q 'MISSING from requirements.lock: beta==9.0 (resolved' <<<"$OUT" || _tm_afail "the resolver's missing package is not named: ${OUT}"
    _lock 'Alpha==1.0' 'beta==1.5'; _gen
    tm_assert_rc 1 "$RC" "a locked beta the resolution's own metadata refuses passed: ${OUT}"
    grep -q 'INCOMPATIBLE: beta==1.5' <<<"$OUT" || _tm_afail "the closure did not judge the resolution's requires_dist: ${OUT}"
    _lock 'Alpha==1.0' 'beta==2.1'; FAKE_CONFLICT=1 _gen
    tm_assert_rc 1 "$RC" "pins pip cannot install together were not a FAILURE (exit 1): ${OUT}"
    grep -q 'INCONSISTENT' <<<"$OUT" || _tm_afail "ResolutionImpossible was not reported as an inconsistent lock: ${OUT}"
}
tm_case "reg0006-the-resolution-is-held-to-the-locks-own-pins" none g_lock_constrained_resolution

# ── REG-0007: exact ==<version> only
g_lock_exact() {
    mkdir -p "${TM_TMP}/nobin"; printf '#!/bin/sh\nexit 7\n' > "${TM_TMP}/nobin/curl"; chmod +x "${TM_TMP}/nobin/curl"
    local bad
    # 'latest' and 'v1.9.0': the PEP 440 shape (REG-0007), carried into the one
    # parser (tools/lib/lockparse.py) at the v1.1.0 merge; its PIN_RE took both.
    for bad in 'blinker==1.*' 'blinker==1.9.0,<2' 'blinker===1.9.0' 'blinker==latest' 'blinker==v1.9.0'; do
        rm -rf "${TM_TMP}/tree"; _tree tools/check-requirements-lock.sh tools/gen-requirements-lock.py tools/lib requirements.txt requirements.lock
        sed -i "s/^blinker==1\.9\.0 /${bad} /" "$FX/requirements.lock"
        grep -qF "${bad} " "$FX/requirements.lock" || tm_die "fixture did not apply ${bad}"
        _run env PATH="${TM_TMP}/nobin:${PATH}" bash "$FX/tools/check-requirements-lock.sh" --root "$FX"
        # Exit 1 = refused by the STRUCTURE check. Offline is exit 3 on its own
        # since round 9, so "non-zero" would stay green with the check deleted.
        tm_assert_rc 1 "$RC" "the lock gate accepted '${bad}' as a lock: ${OUT}"
    done
    rm -rf "${TM_TMP}/tree"; _tree tools/check-requirements-lock.sh tools/gen-requirements-lock.py tools/lib requirements.txt requirements.lock
    sed -i 's/^Flask==3\.1\.3$/Flask>=3.1.3/' "$FX/requirements.txt"
    _run env PATH="${TM_TMP}/nobin:${PATH}" bash "$FX/tools/check-requirements-lock.sh" --root "$FX"
    tm_assert_rc 1 "$RC" "a RANGE in requirements.txt was accepted as a pin: ${OUT}"
    # ...and the real tree stays green on the same (structure-only) path.
    rm -rf "${TM_TMP}/tree"; _tree tools/check-requirements-lock.sh tools/gen-requirements-lock.py tools/lib requirements.txt requirements.lock
    _run env PATH="${TM_TMP}/nobin:${PATH}" TM_LOCK_OFFLINE_OK=1 bash "$FX/tools/check-requirements-lock.sh" --root "$FX"
    tm_assert_rc 0 "$RC" "the real lock was refused on the structure-only path: ${OUT}"
}
tm_case "reg0007-only-exact-pins-are-a-lock" none g_lock_exact

# ── REG-0008: the pipefail lint parses shell, it does not grep it
g_pipelint() {
    local P='|' shape rc
    local -a RED=(
        "x ${P} sed -n 1q" "x ${P} sed 5q" "x ${P} command grep -q y" "x ${P} \\grep -q y"
        "x ${P} grep 'a${P}b' -q" "x ${P} grep -l y" "x ${P} head -n 1"
        "out=\"\$(x ${P} awk '{exit}')\""
        # v1.2.0 Sonar refactor of pipelint: each shape below is one of its
        # branches the mechanical pass found unobserved (sed -e, a nested $(
        # inside quotes, an escaped quote inside a quoted $(, a backtick body).
        "x ${P} sed -e 1q"
        "v=\"\$(echo \$(date) ${P} head -1)\""
        "v=\"\$(echo \"a\\\"b\" ${P} head -1)\""
        "v=\"\`x ${P} head -1\`\""
    )
    for shape in "${RED[@]}"; do
        printf '%s\n' "$shape" > "${TM_TMP}/l.sh"
        rc=0; bash "$R/tools/check-pipefail-consumers.sh" "${TM_TMP}/l.sh" >/dev/null 2>&1 || rc=$?
        tm_assert_rc 1 "$rc" "the lint missed: ${shape}"
    done
    printf 'x \\\n    %s grep -q y\n' "$P" > "${TM_TMP}/l.sh"
    rc=0; bash "$R/tools/check-pipefail-consumers.sh" "${TM_TMP}/l.sh" >/dev/null 2>&1 || rc=$?
    tm_assert_rc 1 "$rc" "the lint missed a pipe continued onto the next line"
    printf '%s\n' "echo 'x ${P} head -1'" "echo \"x ${P} grep -q y\"" "x ${P} sed 's/q/Q/'" "x ${P} grep -- -q" \
        "cat <<'EOF'" "x ${P} head -1" "EOF" "x ${P} grep -c y # ${P} head" > "${TM_TMP}/l.sh"
    rc=0; bash "$R/tools/check-pipefail-consumers.sh" "${TM_TMP}/l.sh" > "${TM_TMP}/o" 2>&1 || rc=$?
    tm_assert_rc 0 "$rc" "the lint flagged pipe TEXT (a string, a heredoc body, a comment): $(cat "${TM_TMP}/o")"
}
tm_case "reg0008-pipefail-lint-tokenises-quotes-comments-continuations" none g_pipelint

# ── REG-0009: env-neutral sees through encodings and never reads pixels
g_env_neutral() {
    local d="${TM_TMP}/scan"; mkdir -p "$d"
    local oct="10.2" ; oct="${oct}0.30.40"                     # a 10/8 address, built at run time
    local ula="fc"; ula="${ula}12:3456:789a::1"                # a unique-local address, fc prefix
    printf 'x\xe9%s y\n' "$oct" > "$d/latin1.txt"
    _run bash "$R/tools/check-env-neutral.sh" --dir "$d"
    [ "$RC" -ne 0 ] || _tm_afail "a 10/8 address after a latin-1 byte was not seen: ${OUT}"
    rm -f "$d"/*
    "$PY" -c "import sys; open(sys.argv[1],'wb').write(('host ' + sys.argv[2] + '\n').encode('utf-16'))" "$d/u16.txt" "$oct"
    _run bash "$R/tools/check-env-neutral.sh" --dir "$d"
    [ "$RC" -ne 0 ] || _tm_afail "an address in a UTF-16 file was not seen: ${OUT}"
    rm -f "$d"/*
    printf 'addr %s\n' "$ula" > "$d/v6.txt"
    _run bash "$R/tools/check-env-neutral.sh" --dir "$d"
    [ "$RC" -ne 0 ] || _tm_afail "an fc-prefix unique-local IPv6 address was not seen: ${OUT}"
    local fe="fe"; fe="${fe}80::1ff:fe23:4567:890a"
    printf 'addr %s\n' "$fe" > "$d/v6.txt"
    _run bash "$R/tools/check-env-neutral.sh" --dir "$d"
    [ "$RC" -ne 0 ] || _tm_afail "a link-local IPv6 address was not seen: ${OUT}"
    printf 'the unique-local range is %s and link-local %s\n' "fc00::/7" "fe80::/10" > "$d/v6.txt"
    _run bash "$R/tools/check-env-neutral.sh" --dir "$d"
    tm_assert_rc 0 "$RC" "a range written in prefix notation (documentation) was read as an address: ${OUT}"
    rm -f "$d"/*
    printf '\x89PNG\r\n\x1a\n pixels %s pixels\n' "$oct" > "$d/image.bin"
    printf 'plain text, nothing site-specific\n' > "$d/readme.txt"
    _run bash "$R/tools/check-env-neutral.sh" --dir "$d"
    tm_assert_rc 0 "$RC" "pixel data in a PNG was read as text: ${OUT}"
}
tm_case "reg0009-env-neutral-bytes-utf16-fc00-and-no-pixels" none g_env_neutral

# ── REG-0010: live tokens only, in every frontend file
g_version_tokens() {
    _tree VERSION tm/VERSION app index.html PPSM.csv install.sh prepare-offline.sh SBOM.md docs/INSTALL.md README.md CHANGELOG.md
    local G="$R/tools/check-version-surfaces.sh"
    _run bash "$G" --root "$FX"; tm_assert_rc 0 "$RC" "the copy is not green to start with: ${OUT}"
    # A real token turned into a COMMENTED one: 15 live tokens.
    sed -i 's#^<script src="/app/main.js?v=\([0-9]*\)"></script>$#<!-- <script src="/app/main.js?v=\1"></script> -->#' "$FX/index.html"
    grep -q '<!-- <script src="/app/main.js' "$FX/index.html" || tm_die "fixture did not comment the token out"
    _run bash "$G" --root "$FX"
    [ "$RC" -ne 0 ] || _tm_afail "a token inside an HTML COMMENT was counted as live: ${OUT}"
    rm -rf "${TM_TMP}/tree"; _tree VERSION tm/VERSION app index.html PPSM.csv install.sh prepare-offline.sh SBOM.md docs/INSTALL.md README.md CHANGELOG.md
    printf '\n// legacy: /old.png%s9999\n/* /x.css%s0 */\n' '?v=' '?v=' >> "$FX/app/main.js"
    _run bash "$G" --root "$FX"
    tm_assert_rc 0 "$RC" "a ?v= inside a JS COMMENT was counted: ${OUT}"
    # REG-0014: a live token is an ATTRIBUTE value (here a src= in HTML a
    # component builds), so that is the shape a live one takes.
    printf "\nconst u = '<img src=\"/live.png%s9999\">';\n" '?v=' >> "$FX/app/main.js"
    _run bash "$G" --root "$FX"
    [ "$RC" -ne 0 ] || _tm_afail "a live token in app/main.js was not scanned: ${OUT}"
    rm -rf "${TM_TMP}/tree"; _tree VERSION tm/VERSION app index.html PPSM.csv install.sh prepare-offline.sh SBOM.md docs/INSTALL.md README.md CHANGELOG.md
    sed -i 's#<img src="/jarvis-mark.png\(?v=[0-9]*\)"#<img :src="`/jarvis-mark.png\1`"#' "$FX/app/components/TopBar.js"
    grep -q 'jarvis-mark.png?v=[0-9]*`' "$FX/app/components/TopBar.js" || tm_die "fixture did not make a template literal"
    _run bash "$G" --root "$FX"
    tm_assert_rc 0 "$RC" "a token closing a TEMPLATE LITERAL was read as non-numeric: ${OUT}"
}
tm_case "reg0010-version-tokens-live-only-every-js-template-literals" none g_version_tokens

# ── REG-0014: only src=/href= attribute values are cache tokens
_VS_TREE="VERSION tm/VERSION app index.html PPSM.csv install.sh prepare-offline.sh SBOM.md docs/INSTALL.md README.md CHANGELOG.md"
_vs_drop_main_token() {   # a real asset loses its token: 15 live ones
    sed -i 's#^<script src="/app/main.js?v=[0-9]*"></script>$#<script src="/app/main.js"></script>#' "$FX/index.html"
    grep -qx '<script src="/app/main.js"></script>' "$FX/index.html" || tm_die "fixture did not drop the main.js token"
}
g_version_tokens_attributes_only() {
    local G="$R/tools/check-version-surfaces.sh" v shape
    # shellcheck disable=SC2086
    _tree $_VS_TREE
    v="$(sed -n 's#^<script src="/app/main.js?v=\([0-9]*\)"></script>$#\1#p' "$FX/index.html")"
    [ -n "$v" ] || tm_die "index.html has no main.js token to read"
    _run bash "$G" --root "$FX"; tm_assert_rc 0 "$RC" "the copy is not green to start with: ${OUT}"
    # Each shape below is NOT a request a browser makes. Beside a dropped real
    # token it used to make the count 16 again, and the gate passed.
    for shape in html-text inline-script-comment js-string; do
        rm -rf "${TM_TMP}/tree"
        # shellcheck disable=SC2086
        _tree $_VS_TREE
        _vs_drop_main_token
        case "$shape" in
            html-text)             sed -i "s#</body>#<p>cache token ?v=${v}</p></body>#" "$FX/index.html" ;;
            inline-script-comment) sed -i "s#</body>#<script>/* <script src=\"/app/main.js?v=${v}\"> */</script></body>#" "$FX/index.html" ;;
            js-string)             printf "\nconst note = '/app/main.js?v=%s';\n" "$v" >> "$FX/app/main.js" ;;
        esac
        grep -q "?v=${v}" "$FX/index.html" "$FX/app/main.js" || tm_die "fixture ${shape} was not written"
        _run bash "$G" --root "$FX"
        [ "$RC" -ne 0 ] || _tm_afail "a ?v= that is not a src/href attribute (${shape}) was counted as a cache token: ${OUT}"
        grep -q "15 ?v= cache tokens" <<<"$OUT" || _tm_afail "${shape}: the gate failed, but not on the token count: ${OUT}"
    done
    # A Vue-bound :src with a template literal is an attribute: still green.
    rm -rf "${TM_TMP}/tree"
    # shellcheck disable=SC2086
    _tree $_VS_TREE
    sed -i 's#<img src="/jarvis-mark.png\(?v=[0-9]*\)"#<img :src="`/jarvis-mark.png\1`"#' "$FX/app/components/TopBar.js"
    _run bash "$G" --root "$FX"
    tm_assert_rc 0 "$RC" "a :src binding was not read as an attribute: ${OUT}"
}
tm_case "reg0014-only-src-and-href-attribute-values-are-cache-tokens" none g_version_tokens_attributes_only

# ── REG-0011: SBOM gate reads indented lock lines, refuses duplicate rows
g_sbom() {
    _tree tools/check-sbom-consistency.sh tools/lib requirements.txt requirements.lock SBOM.md NOTICES.md app/components/modals/AboutModal.js install/upgrade-full.sh
    _run bash "$FX/tools/check-sbom-consistency.sh"; tm_assert_rc 0 "$RC" "the copy is not green: ${OUT}"
    sed -i 's/^MarkupSafe==3\.0\.3 /    MarkupSafe==3.0.2 /' "$FX/requirements.lock"
    grep -q '^    MarkupSafe==3.0.2 ' "$FX/requirements.lock" || tm_die "fixture did not indent the entry"
    _run bash "$FX/tools/check-sbom-consistency.sh"
    [ "$RC" -ne 0 ] || _tm_afail "an INDENTED lock entry that disagrees with SBOM.md was not read: ${OUT}"
    rm -rf "${TM_TMP}/tree"; _tree tools/check-sbom-consistency.sh tools/lib requirements.txt requirements.lock SBOM.md NOTICES.md app/components/modals/AboutModal.js install/upgrade-full.sh
    awk '{print} /^\| Flask +\| 3\.1\.3/ && !d {print "| Flask | 2.0.0 | BSD-3-Clause | x |"; d=1}' "$R/SBOM.md" > "$FX/SBOM.md"
    grep -q '^| Flask | 2.0.0' "$FX/SBOM.md" || tm_die "fixture did not add a duplicate row"
    _run bash "$FX/tools/check-sbom-consistency.sh"
    [ "$RC" -ne 0 ] || _tm_afail "a DUPLICATE component row with a different version passed: ${OUT}"
    grep -q 'lists flask twice' <<<"$OUT" || _tm_afail "the duplicate is not named: ${OUT}"
}
tm_case "reg0011-sbom-indented-lock-lines-and-duplicate-rows" none g_sbom

g_sbom_infra() {
    # v1.2.0: the About dialog's infrastructure rows and SBOM.md's are held to
    # each other (rsyslog, rsyslog-openssl and chrony joined both).
    _tree tools/check-sbom-consistency.sh tools/lib requirements.txt requirements.lock SBOM.md NOTICES.md app/components/modals/AboutModal.js install/upgrade-full.sh
    sed -i "s/{ name: 'chrony',          version: '4.5',/{ name: 'chrony',          version: '4.4',/" "$FX/app/components/modals/AboutModal.js"
    grep -q "'chrony',          version: '4.4'" "$FX/app/components/modals/AboutModal.js" || tm_die "fixture did not apply"
    _run bash "$FX/tools/check-sbom-consistency.sh"
    [ "$RC" -ne 0 ] || _tm_afail "the About dialog's chrony drifted from SBOM.md and passed: ${OUT}"
    grep -q 'chrony  *About dialog 4.4, SBOM.md 4.5' <<<"$OUT" || _tm_afail "the drift is not named: ${OUT}"
}
tm_case "sbom-infrastructure-rows-agree-with-the-about-dialog" none g_sbom_infra

# ── REG-0012: required values are non-empty scalars; required_group "" is valid
g_config_example() {
    local mut
    for mut in 's/^  port: .*/  port: []/' 's/^  secret_key: .*/  secret_key: {}/' 's/^  ldap_server: .*/  ldap_server: []/'; do
        rm -rf "${TM_TMP}/tree"; _tree tools/check-config-example.sh config
        sed -i "$mut" "$FX/config/config.yaml.example"
        cmp -s "$R/config/config.yaml.example" "$FX/config/config.yaml.example" && tm_die "fixture '${mut}' changed nothing"
        _run bash "$FX/tools/check-config-example.sh"
        [ "$RC" -ne 0 ] || _tm_afail "an EMPTY CONTAINER passed as a required value (${mut}): ${OUT}"
    done
    rm -rf "${TM_TMP}/tree"; _tree tools/check-config-example.sh config
    sed -i '0,/bootstrap_servers:.*/s//bootstrap_servers:/' "$FX/config/clusters.yaml.example"
    _run bash "$FX/tools/check-config-example.sh"
    [ "$RC" -ne 0 ] || _tm_afail "a cluster with a NULL bootstrap_servers passed: ${OUT}"
    rm -rf "${TM_TMP}/tree"; _tree tools/check-config-example.sh config
    sed -i 's/^  required_group: .*/  required_group: ""/' "$FX/config/config.yaml.example"
    grep -q '^  required_group: ""$' "$FX/config/config.yaml.example" || tm_die "fixture did not blank required_group"
    _run bash "$FX/tools/check-config-example.sh"
    tm_assert_rc 0 "$RC" "the DOCUMENTED empty required_group (any directory account) was refused: ${OUT}"
}
tm_case "reg0012-config-example-scalars-and-the-empty-group" none g_config_example

# ── REG-0013: the runner trusts only recognised records; plain requirements
g_runner() {
    local t="${TM_TMP}/tfake" f
    mkdir -p "$t"
    f="$t/t98-fake.sh"
    printf '%s\n' '#!/usr/bin/env bash' ". \"${TM_TESTS_DIR}/lib/harness.sh\"" \
        'ok() { true; }' 'tm_case "a-real-case" none ok' \
        'printf "GARBAGE-RECORD\n" >> "$TM_RESULTS"' 'tm_finish' > "$f"
    _run env TM_NO_COLOUR=1 bash "${TM_TESTS_DIR}/run.sh" "$f"
    tm_assert_rc 2 "$RC" "an unrecognised record beside a real PASS was masked: ${OUT}"
    grep -q 'unrecognised result record' <<<"$OUT" || _tm_afail "the runner did not say why: ${OUT}"
    printf '%s\n' '#!/usr/bin/env bash' ". \"${TM_TESTS_DIR}/lib/harness.sh\"" \
        'ok() { true; }' 'tm_case "multi" "$(printf "none\nnode")" ok' 'tm_finish' > "$f"
    _run env TM_NO_COLOUR=1 bash "${TM_TESTS_DIR}/run.sh" "$f"
    tm_assert_rc 2 "$RC" "a requirement list with an embedded NEWLINE ran (its second line was never checked): ${OUT}"
}
tm_case "reg0013-runner-recognised-records-and-plain-requirements" none g_runner

# ── REG-0015: a file that stops early is a failure, not a smaller pass
g_runner_case_count() {
    local t="${TM_TMP}/tcount" f
    mkdir -p "$t"
    f="$t/t97-count.sh"
    _fake() { printf '%s\n' '#!/usr/bin/env bash' ". \"${TM_TESTS_DIR}/lib/harness.sh\"" 'ok() { true; }' "$@" 'tm_finish' > "$f"; }
    _fake 'tm_case "first" none ok' 'exit 0' 'tm_case "second" none ok'
    _run env TM_NO_COLOUR=1 bash "${TM_TESTS_DIR}/run.sh" "$f"
    tm_assert_rc 1 "$RC" "a file that exited 0 after its first of two cases passed: ${OUT}"
    grep -q 'declares 2 case(s) and reported 1' <<<"$OUT" || _tm_afail "the shortfall was not named: ${OUT}"
    grep -q 'case-count-shortfall' <<<"$OUT" || _tm_afail "the shortfall is not in the failed-case list: ${OUT}"
    _fake 'tm_case "first" none ok' 'tm_case "second" none ok'
    _run env TM_NO_COLOUR=1 bash "${TM_TESTS_DIR}/run.sh" "$f"
    tm_assert_rc 0 "$RC" "a complete file was refused: ${OUT}"
    _fake 'for i in 1 2 3; do' '    tm_case "loop-$i" none ok' 'done'
    _run env TM_NO_COLOUR=1 bash "${TM_TESTS_DIR}/run.sh" "$f"
    tm_assert_rc 2 "$RC" "a tm_case in a loop with no declared total was counted by guesswork: ${OUT}"
    _fake '# tm-expect-cases: 3' 'for i in 1 2 3; do' '    tm_case "loop-$i" none ok' 'done'
    _run env TM_NO_COLOUR=1 bash "${TM_TESTS_DIR}/run.sh" "$f"
    tm_assert_rc 0 "$RC" "a loop file with its declared total was refused: ${OUT}"
    _fake '# tm-expect-cases: 3' 'for i in 1 2; do' '    tm_case "loop-$i" none ok' 'done'
    _run env TM_NO_COLOUR=1 bash "${TM_TESTS_DIR}/run.sh" "$f"
    tm_assert_rc 1 "$RC" "a loop file that ran 2 of its declared 3 passed: ${OUT}"
}
tm_case "reg0015-runner-holds-each-file-to-its-declared-case-count" none g_runner_case_count

# ── REG-0017: the frontend gate reads its list from index.html
g_frontend_syntax() {
    local G="$R/tools/check-frontend-syntax.sh"
    _tree index.html app
    _run bash "$G" --root "$FX"; tm_assert_rc 0 "$RC" "the copy is not green to start with: ${OUT}"
    # A file index.html loads goes missing. The old fixed glob stayed green on
    # exactly this tree (it can only check what is there).
    rm "$FX/app/components/AuditTab.js"
    _run bash -c 'cd "$1" && for f in app/main.js app/components/*.js app/components/modals/*.js; do node --check "$f" || exit 1; done' _ "$FX"
    tm_assert_rc 0 "$RC" "fixture: the old glob gate was expected to MISS the deleted file: ${OUT}"
    _run bash "$G" --root "$FX"
    tm_assert_rc 1 "$RC" "a script index.html loads was deleted and the gate passed: ${OUT}"
    grep -q 'loads /app/components/AuditTab.js, and app/components/AuditTab.js does not exist' <<<"$OUT" \
        || _tm_afail "the missing file was not named: ${OUT}"
    rm -rf "${TM_TMP}/tree"; _tree index.html app
    rm "$FX/app/styles/main.css"
    _run bash "$G" --root "$FX"
    tm_assert_rc 1 "$RC" "the stylesheet index.html loads was deleted and the gate passed: ${OUT}"
    # A syntax error in a loaded component, and one in a component index.html
    # no longer loads: both fail.
    rm -rf "${TM_TMP}/tree"; _tree index.html app
    printf '\nconst broken = {;\n' >> "$FX/app/components/TopBar.js"
    _run bash "$G" --root "$FX"
    tm_assert_rc 1 "$RC" "a loaded component that does not parse passed: ${OUT}"
    rm -rf "${TM_TMP}/tree"; _tree index.html app
    printf 'const orphan = {;\n' > "$FX/app/components/Orphan.js"
    _run bash "$G" --root "$FX"
    tm_assert_rc 1 "$RC" "an unloaded component that does not parse passed: ${OUT}"
    # A COMMENTED-OUT load of a file that does not exist is not a load.
    rm -rf "${TM_TMP}/tree"; _tree index.html app
    sed -i 's#</body>#<!-- <script src="/app/components/Gone.js?v=1"></script> --></body>#' "$FX/index.html"
    _run bash "$G" --root "$FX"
    tm_assert_rc 0 "$RC" "a commented-out <script> was read as a load: ${OUT}"
    _run bash "$G"; tm_assert_rc 0 "$RC" "frontend-syntax on the real tree: ${OUT}"
}
tm_case "reg0017-frontend-gate-derives-its-list-from-index-html" node g_frontend_syntax

g_real_tree_green() {
    _run bash "$R/tools/check-pipefail-consumers.sh"; tm_assert_rc 0 "$RC" "pipefail lint: ${OUT}"
    _run bash "$R/tools/check-env-neutral.sh"; tm_assert_rc 0 "$RC" "env-neutral: ${OUT}"
    _run bash "$R/tools/check-version-surfaces.sh"; tm_assert_rc 0 "$RC" "version-surfaces: ${OUT}"
    _run bash "$R/tools/check-sbom-consistency.sh"; tm_assert_rc 0 "$RC" "sbom: ${OUT}"
    _run bash "$R/tools/check-config-example.sh"; tm_assert_rc 0 "$RC" "config-example: ${OUT}"
    _run bash "$R/tools/sca-check.sh" --list-pins; tm_assert_rc 0 "$RC" "sca lock parse: ${OUT}"
}
tm_case "the-hardened-gates-are-green-on-the-real-tree" none g_real_tree_green

tm_finish
