#!/usr/bin/env bash
# =============================================================================
# t26 — THE OFFLINE BUNDLE CARRIES EVERY LOCKSTEP SIBLING (round 4).
#
# MEASURED 2026-09-26 on the real STIG (USG) + FIPS Ubuntu 24.04.4 host with
# the b3de193 bundle: the round-3 policy worked (29 FIPS packages held) and
# refused safely, but apt's only plan was
#   REMOVED: libpython3.12t64 ... ubuntu-server vim
#   UPGRADE: python3.12 python3.12-minimal libpython3.12-minimal libpython3.12-stdlib
# Binaries built from ONE Debian source carry exact-version dependencies on
# each other. The bundle held the closure of the REQUESTED packages only — it
# had python3.12 0ubuntu0.17 but not libpython3.12t64 0ubuntu0.17, which the
# target had installed at 0ubuntu0.13 — so upgrading one meant removing the
# other. prepare-offline.sh now adds every binary of the same source and
# source version as any closure package (this architecture and `all`; no
# -dbg/-dbgsym/-doc/Section debug; bounded per source).
#
#   * stub cases (run everywhere) drive the REAL apt_source_siblings with a
#     stub apt-cache (show / dumpavail) and check the selection rules;
#   * the REAL pipeline case (Debian/Ubuntu): real .debs built with dpkg-deb,
#     a fixture "mirror", the REAL bundle_apt_packages downloading from it,
#     then the REAL install.sh apt_install_from_bundle resolving against a
#     fixture target that has the OLD sibling installed: it must resolve with
#     NO removal. With the expansion held off (bound 0), the same target must
#     be refused with the sibling named. Nothing is installed on this host:
#     every dpkg/apt call reads a private status file and installs are -s.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "offline bundle: every binary of a closure package's source is bundled"

PREP_SH="$(tm_prepare_sh)"
INSTALL_SH="$(tm_install_sh)"

# ─── stub cases: the selection rules ─────────────────────────────────────────
_sib_driver() {
    mkdir -p "${TM_TMP}/bin"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        tm_extract_line "$PREP_SH" '^APT_SIBLING_MAX=[0-9]+$'
        tm_extract_func "$PREP_SH" apt_source_siblings
        echo 'apt_source_siblings "$@"'
    } > "${TM_TMP}/sib.sh"
    cat > "${TM_TMP}/bin/apt-cache" <<STUB
#!/usr/bin/env bash
case "\$1" in
    show)      cat "${TM_TMP}/show.out" ;;
    dumpavail) [ -f "${TM_TMP}/avail.fail" ] && exit 100; cat "${TM_TMP}/avail.out" ;;
    *)         exit 99 ;;
esac
STUB
    chmod +x "${TM_TMP}/bin/apt-cache"
}
_stz() {   # _stz <file> <pkg> <version> <arch> [source] [section]
    { printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$2" "$3" "$4"
      [ -z "${5:-}" ] || printf 'Source: %s\n' "$5"
      printf 'Section: %s\nDescription: fixture\n with a continuation line\n\n' "${6:-libs}"; } >> "$1"
}
_sib_fixture() {
    _sib_driver
    printf '%s\n' python3.12 python3 nginx libsys0 > "${TM_TMP}/closure"
    : > "${TM_TMP}/show.out"; : > "${TM_TMP}/avail.out"
    local V=3.12.3-1ubuntu0.17
    _stz "${TM_TMP}/show.out" python3.12 "$V" amd64
    _stz "${TM_TMP}/show.out" python3 3.12.3-0ubuntu2.1 amd64 python3-defaults
    _stz "${TM_TMP}/show.out" nginx 1.24.0-2ubuntu7.5 amd64
    _stz "${TM_TMP}/show.out" libsys0 255.4-1 amd64 sys
    local A="${TM_TMP}/avail.out"
    _stz "$A" python3.12 "$V" amd64
    _stz "$A" libpython3.12t64 "$V" amd64 python3.12                    # THE sibling
    _stz "$A" python3.12-venv "$V" amd64 python3.12
    _stz "$A" libpython3.12-testsuite "${V}+b1" all "python3.12 (${V})"   # binNMU: "name (version)"
    _stz "$A" python3.12-dbg "$V" amd64 python3.12                      # -dbg
    _stz "$A" libpython3.12t64-dbgsym "$V" amd64 python3.12             # -dbgsym
    _stz "$A" python3.12-doc "$V" all python3.12 doc                    # -doc
    _stz "$A" python3.12-symbols "$V" amd64 python3.12 universe/debug   # Section debug
    _stz "$A" python3.12-arm "$V" arm64 python3.12                      # another arch
    _stz "$A" python3.12-old 3.12.3-1ubuntu0.13 amd64 python3.12        # another SOURCE VERSION
    _stz "$A" libpython3-stdlib 3.12.3-0ubuntu2.1 amd64 python3-defaults
    _stz "$A" python3 3.12.3-0ubuntu2.1 amd64 python3-defaults
    _stz "$A" unrelated 1.0 amd64 other
    local i
    _stz "$A" nginx 1.24.0-2ubuntu7.5 amd64
    for i in $(seq 1 41); do _stz "$A" "libnginx-mod-x${i}" 1.24.0-2ubuntu7.5 amd64 nginx; done
    _stz "$A" libsys0 255.4-1 amd64 sys                                 # a source EXACTLY at the bound
    for i in $(seq 1 40); do _stz "$A" "sys-x${i}" 255.4-1 amd64 sys; done
}
_sib_run() {
    RC=0; PATH="${TM_TMP}/bin:${PATH}" bash "${TM_TMP}/sib.sh" amd64 "${TM_TMP}/closure" > "${TM_TMP}/out" 2>&1 || RC=$?
}

a_selects_siblings() {
    _sib_fixture; _sib_run
    tm_assert_rc 0 "$RC" "apt_source_siblings failed: $(cat "${TM_TMP}/out")"
    tm_assert_grep $'ADD\tlibpython3.12t64=3.12.3-1ubuntu0.17\tpython3.12' "${TM_TMP}/out" \
        "THE ROUND-4 DEFECT: the lockstep sibling libpython3.12t64 is not added at the closure's source version"
    tm_assert_grep $'ADD\tpython3.12-venv=3.12.3-1ubuntu0.17\tpython3.12' "${TM_TMP}/out" "a same-source sibling is missing"
    tm_assert_grep $'ADD\tlibpython3.12-testsuite=3.12.3-1ubuntu0.17+b1\tpython3.12' "${TM_TMP}/out" \
        "a sibling whose Source: carries a version (binNMU) is missing"
    tm_assert_grep $'ADD\tlibpython3-stdlib=3.12.3-0ubuntu2.1\tpython3-defaults' "${TM_TMP}/out" \
        "a sibling of a closure package whose source differs from its own name is missing"
    local bad
    for bad in python3.12-dbg libpython3.12t64-dbgsym python3.12-doc python3.12-symbols python3.12-arm python3.12-old unrelated; do
        tm_assert_nogrep $'\t'"${bad}=" "${TM_TMP}/out" "${bad} must not be added"
    done
    tm_assert_nogrep $'ADD\tpython3.12=' "${TM_TMP}/out" "a package already in the closure was added again"
}
tm_case "same-source-siblings-are-selected-and-nothing-else" none a_selects_siblings

a_bounded() {
    _sib_fixture; _sib_run
    tm_assert_grep $'BOUND\tnginx\t41' "${TM_TMP}/out" "a source over the bound was not reported"
    tm_assert_nogrep "libnginx-mod-x" "${TM_TMP}/out" "a source over the bound was expanded anyway"
    tm_assert_grep $'ADD\tsys-x40=255.4-1\tsys' "${TM_TMP}/out" "a source with EXACTLY the bound (40) siblings was not expanded"
    tm_assert_nogrep $'BOUND\tsys' "${TM_TMP}/out" "a source AT the bound was reported as over it"
    tm_assert_grep 'APT_SIBLING_MAX=40' "${TM_TMP}/sib.sh" "the per-source bound is not 40"
}
tm_case "a-source-over-the-bound-is-reported-not-expanded" none a_bounded

a_dumpavail_fails() {
    _sib_fixture; : > "${TM_TMP}/avail.fail"; _sib_run
    tm_assert_ne 0 "$RC" "a failed apt-cache dumpavail was reported as 'no siblings'"
}
tm_case "an-unreadable-package-list-is-an-error-not-no-siblings" none a_dumpavail_fails

# ─── the real pipeline ───────────────────────────────────────────────────────
_deb() {   # _deb <outdir> <pkg> <version> <arch> [depends] [source]
    local d="${TM_TMP}/debsrc/$2_$3"
    mkdir -p "$d/DEBIAN"
    { printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@example.org>\n' "$2" "$3" "$4"
      [ -z "${6:-}" ] || printf 'Source: %s\n' "$6"
      [ -z "${5:-}" ] || printf 'Depends: %s\n' "$5"
      printf 'Section: misc\nPriority: optional\nDescription: fixture\n'; } > "$d/DEBIAN/control"
    dpkg-deb --root-owner-group -Zgzip --build "$d" "$1/$2_$3_$4.deb" >/dev/null || tm_die "dpkg-deb failed for $2"
}
_index() { ( cd "$1" && if command -v apt-ftparchive >/dev/null 2>&1; then apt-ftparchive packages . > Packages
                         else dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null; fi ) || tm_die "could not index $1"; }
_st() {    # _st <pkg> <version> <arch> [depends] [source]
    { printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nArchitecture: %s\nVersion: %s\nMaintainer: t <t@example.org>\n' "$1" "$3" "$2"
      [ -z "${5:-}" ] || printf 'Source: %s\n' "$5"
      [ -z "${4:-}" ] || printf 'Depends: %s\n' "$4"
      printf 'Description: fixture\n\n'; } >> "${TM_TMP}/target/status"
}
_aptwrap() {   # _aptwrap <bin-dir> <status-file> <extra-opts...>: apt-get + apt-cache on a private config
    local bin="$1" st="$2"; shift 2
    local real_get real_cache o=""
    real_get="$(command -v apt-get)"; real_cache="$(command -v apt-cache)"
    for a in "$@"; do o="${o} $(printf '%q' "$a")"; done
    mkdir -p "$bin"
    cat > "${bin}/apt-get" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TM_TMP}/calls"
extra=(-o "Dir::State::status=${st}" -o Debug::NoLocking=1 ${o})
case " \$* " in
    *" -s "*|*" update "*|*" download "*) exec "${real_get}" "\${extra[@]}" "\$@" ;;
    *" install "*) args=(); for a in "\$@"; do [ "\$a" = -y ] || args+=("\$a"); done
                   exec "${real_get}" "\${extra[@]}" -s "\${args[@]}" ;;
esac
exit 99
STUB
    cat > "${bin}/apt-cache" <<STUB
#!/usr/bin/env bash
[ "\$1" = policy ] && exit 0     # the target's FIPS origins: none in this fixture
exec "${real_cache}" -o "Dir::State::status=${st}" ${o} "\$@"
STUB
    cat > "${bin}/dpkg-query" <<STUB
#!/usr/bin/env bash
exec "$(command -v dpkg-query)" --admindir="$(dirname "$st")" "\$@"
STUB
    chmod +x "${bin}/"*
}

# A source "pysrc" at versions 1 (installed on the target) and 2 (the mirror's
# candidate). pyx-venv is requested; its closure is pyx + libpyx. libpyx-t64
# is the lockstep sibling: installed on the target at 1, with Depends
# libpyx (= 1), and NOT in the request closure. app-x depends on libpyx-t64.
_pipeline() {   # _pipeline <sibling-bound or "">
    local arch; arch="$(dpkg --print-architecture)"
    mkdir -p "${TM_TMP}/mirror" "${TM_TMP}/bundle" "${TM_TMP}/build/lists/partial" "${TM_TMP}/build/cache/archives/partial" \
             "${TM_TMP}/build/parts" "${TM_TMP}/build/prefparts" "${TM_TMP}/target/updates" "${TM_TMP}/target/info" "${TM_TMP}/tmproot"
    local v
    for v in 1 2; do
        _deb "${TM_TMP}/mirror" pyx-venv "$v" all "pyx (= ${v})" pysrc
        _deb "${TM_TMP}/mirror" pyx "$v" "$arch" "libpyx (= ${v})" pysrc
        _deb "${TM_TMP}/mirror" libpyx "$v" "$arch" "" pysrc
        _deb "${TM_TMP}/mirror" libpyx-t64 "$v" "$arch" "libpyx (= ${v})" pysrc
        _deb "${TM_TMP}/mirror" pyx-doc "$v" all "" pysrc
    done
    _deb "${TM_TMP}/mirror" app-x 1 all "libpyx-t64" ""
    # A sibling the mirror INDEXES but cannot deliver: it must be logged and
    # left out, never fail the build or be claimed.
    _deb "${TM_TMP}/mirror" libpyx-gone 2 "$arch" "" pysrc
    _index "${TM_TMP}/mirror"
    rm -f "${TM_TMP}/mirror"/libpyx-gone_*.deb
    printf 'deb [trusted=yes] file:%s ./\n' "${TM_TMP}/mirror" > "${TM_TMP}/build/sources.list"
    : > "${TM_TMP}/build/status"; : > "${TM_TMP}/build/prefs"
    _aptwrap "${TM_TMP}/bin-build" "${TM_TMP}/build/status" \
        -o "Dir::Etc::SourceList=${TM_TMP}/build/sources.list" -o "Dir::Etc::SourceParts=${TM_TMP}/build/parts" \
        -o "Dir::State::Lists=${TM_TMP}/build/lists" -o "Dir::Cache=${TM_TMP}/build/cache" \
        -o "Dir::Etc::Preferences=${TM_TMP}/build/prefs" -o "Dir::Etc::PreferencesParts=${TM_TMP}/build/prefparts" \
        -o APT::Sandbox::User=root -o Acquire::Languages=none
    PATH="${TM_TMP}/bin-build:${PATH}" apt-get update -qq >/dev/null 2>&1 || tm_die "fixture mirror: apt-get update failed"
    # The build step: the REAL bundle_apt_packages.
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'ok() { echo "[OK] $*"; }; info() { echo "[INFO] $*"; }; die() { echo "[DIE] $*" >&2; exit 1; }'
        tm_extract_line "$PREP_SH" '^APT_SIBLING_MAX=[0-9]+$'
        [ -z "${1:-}" ] || echo "APT_SIBLING_MAX=$1"
        tm_extract_func "$PREP_SH" apt_source_siblings
        tm_extract_func "$PREP_SH" bundle_apt_packages
        echo 'bundle_apt_packages "$@"'
    } > "${TM_TMP}/build.sh"
    BRC=0; PATH="${TM_TMP}/bin-build:${PATH}" bash "${TM_TMP}/build.sh" "${TM_TMP}/bundle" pyx-venv > "${TM_TMP}/build.out" 2>&1 || BRC=$?
    # The target: the old source installed, sibling and dependant included.
    : > "${TM_TMP}/target/status"
    _st pyx 1 "$arch" "libpyx (= 1)" pysrc
    _st libpyx 1 "$arch" "" pysrc
    _st libpyx-t64 1 "$arch" "libpyx (= 1)" pysrc
    _st app-x 1 all "libpyx-t64"
    _aptwrap "${TM_TMP}/bin-target" "${TM_TMP}/target/status"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'die() { echo "[DIE] $*" >&2; exit 1; }; info() { echo "[INFO] $*"; }'
        echo 'NON_INTERACTIVE=true'
        tm_extract_func "$INSTALL_SH" apt_fips_packages
        tm_extract_func "$INSTALL_SH" apt_plan_names
        tm_extract_func "$INSTALL_SH" apt_removal_reason
        tm_extract_func "$INSTALL_SH" apt_install_from_bundle
        echo 'apt_install_from_bundle "$@"'
        echo 'echo RETURNED'
    } > "${TM_TMP}/aib.sh"
    RC=0; TMPDIR="${TM_TMP}/tmproot" PATH="${TM_TMP}/bin-target:${PATH}" \
        bash "${TM_TMP}/aib.sh" "${TM_TMP}/bundle" pyx-venv > "${TM_TMP}/out" 2>&1 || RC=$?
}

a_real_bundle_resolves() {
    _pipeline ""
    tm_assert_rc 0 "$BRC" "bundle_apt_packages failed: $(cat "${TM_TMP}/build.out")"
    ls "${TM_TMP}/bundle"/libpyx-t64_2_*.deb >/dev/null 2>&1 \
        || _tm_afail "THE ROUND-4 DEFECT: the bundle lacks the lockstep sibling libpyx-t64 2: $(ls "${TM_TMP}/bundle")"
    ls "${TM_TMP}/bundle"/pyx-venv_2_*.deb "${TM_TMP}/bundle"/pyx_2_*.deb "${TM_TMP}/bundle"/libpyx_2_*.deb >/dev/null 2>&1 \
        || _tm_afail "the request closure is not in the bundle: $(ls "${TM_TMP}/bundle")"
    ls "${TM_TMP}/bundle"/pyx-doc_* >/dev/null 2>&1 && _tm_afail "a -doc sibling was bundled"
    ls "${TM_TMP}/bundle"/*_1_*.deb >/dev/null 2>&1 && _tm_afail "an OLD source version was bundled: $(ls "${TM_TMP}/bundle")"
    grep -q '^Package: libpyx-t64$' "${TM_TMP}/bundle/Packages" || _tm_afail "the sibling is not in the bundle index"
    tm_assert_grep "lockstep siblings (same source): 1 added: libpyx-t64=2" "${TM_TMP}/build.out" "the build does not print what it added"
    tm_assert_grep "NOT downloadable here, so NOT in the bundle: libpyx-gone=2 (pysrc)" "${TM_TMP}/build.out" \
        "a sibling the build host could not download was not logged"
    ls "${TM_TMP}/bundle"/libpyx-gone_* >/dev/null 2>&1 && _tm_afail "an undownloadable sibling is in the bundle"
    tm_assert_rc 0 "$RC" "the target could not install from the expanded bundle: $(cat "${TM_TMP}/out")"
    tm_assert_nogrep "REMOVED" "${TM_TMP}/out" "resolution needed a removal"
    tm_assert_grep "libpyx-t64=2 (from 1)" "${TM_TMP}/out" "the installed sibling was not upgraded in lockstep"
    tm_assert_grep "RETURNED" "${TM_TMP}/out" "the install did not complete"
}
tm_case "real-apt-the-expanded-bundle-resolves-with-no-removal" apt a_real_bundle_resolves

a_real_unexpanded_is_named() {
    _pipeline 0     # bound 0: the expansion is held off, as a round-3 bundle
    tm_assert_rc 0 "$BRC" "bundle_apt_packages failed: $(cat "${TM_TMP}/build.out")"
    ls "${TM_TMP}/bundle"/libpyx-t64_* >/dev/null 2>&1 && _tm_afail "harness: the sibling was bundled although the bound is 0"
    tm_assert_grep "NOT expanded: pysrc: 2 binaries" "${TM_TMP}/build.out" "a source held off by the bound was not reported"
    tm_assert_ne 0 "$RC" "the target resolved WITHOUT the sibling — the fixture no longer reproduces the defect"
    tm_assert_grep "Lockstep siblings missing from the bundle: libpyx-t64 (source pysrc)" "${TM_TMP}/out" \
        "the refusal does not name the missing sibling"
    tm_assert_grep "Would be removed with them (they depend on them): app-x" "${TM_TMP}/out" "the collateral removal is not named"
}
tm_case "real-apt-without-the-sibling-the-refusal-names-it" apt a_real_unexpanded_is_named

tm_finish
