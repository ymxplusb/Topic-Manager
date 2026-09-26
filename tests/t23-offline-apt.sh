#!/usr/bin/env bash
# =============================================================================
# t23 — THE OFFLINE BUNDLE IS AN APT REPOSITORY, NOT A LIST OF .DEBS (round 2).
#
# MEASURED 2026-09-26 on a real STIG (USG) + FIPS Ubuntu 24.04.4 host: the
# 9a794ff bundle's install.sh handed apt every bundled .deb that was not
# installed. The bundle is a dependency CLOSURE, so it holds every alternative
# provider (systemd-sysv, dbus-broker, systemd-standalone-sysusers, ...), and
# apt answered "pkgProblemResolver::Resolve generated breaks". The same was
# reproduced (simulated, /tmp only) on a stock host: 6 not-installed debs,
# "systemd-standalone-sysusers : Conflicts: systemd-sysusers".
#
# The fix, driven here through the REAL apt_install_from_bundle with a stub
# apt-get that records what it was asked and then fails:
#   * apt is given ONLY the missing top-level package names — never a .deb;
#   * the source list is private, names only the bundle, [trusted=yes] for
#     that one file: path; the bundle is pinned to priority 1 so nothing
#     installed (a FIPS libssl, say) can be upgraded or replaced;
#   * --no-download;
#   * the temporary configuration is gone after a FAILED install too.
# prepare-offline.sh must index the .debs (Packages / Packages.gz).
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "offline packages: apt resolves from the bundle; nothing installed is replaced"

INSTALL_SH="$(tm_install_sh)"
PREP="${TM_REPO_ROOT}/prepare-offline.sh"

_build() {   # _build <stub-exit-for-install>
    mkdir -p "${TM_TMP}/bin" "${TM_TMP}/bundle" "${TM_TMP}/tmproot"
    : > "${TM_TMP}/bundle/nginx_1.24.0_amd64.deb"
    : > "${TM_TMP}/bundle/systemd-standalone-sysusers_255_amd64.deb"
    printf 'Package: nginx\n' > "${TM_TMP}/bundle/Packages"
    # The stub records every call, and a COPY of the private config as it was
    # during the call, so the case can read what apt was actually told.
    cat > "${TM_TMP}/bin/apt-get" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TM_TMP}/calls"
for a in "\$@"; do
    case "\$a" in Dir::Etc::SourceList=*) cp "\${a#*=}" "${TM_TMP}/seen.sources" ;;
                  Dir::Etc::Preferences=*) cp "\${a#*=}" "${TM_TMP}/seen.prefs" ;;
                  Dir::Cache::Archives=*) ls "\${a#*=}" > "${TM_TMP}/seen.archives" ;; esac
done
case " \$* " in *" install "*) exit ${1} ;; esac
exit 0
STUB
    chmod +x "${TM_TMP}/bin/apt-get"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'die() { echo "[DIE] $*" >&2; exit 1; }; info() { echo "[INFO] $*"; }'
        tm_extract_func "$INSTALL_SH" apt_install_from_bundle
        echo 'apt_install_from_bundle "$@"'
        echo 'echo RETURNED'
    } > "${TM_TMP}/aib.sh"
}
_run() { RC=0; TMPDIR="${TM_TMP}/tmproot" PATH="${TM_TMP}/bin:${PATH}" \
         bash "${TM_TMP}/aib.sh" "${TM_TMP}/bundle" nginx polkitd > "${TM_TMP}/out" 2>&1 || RC=$?; }

a_only_names_never_debs() {
    _build 0; _run
    tm_assert_rc 0 "$RC" "the install failed with a succeeding apt: $(cat "${TM_TMP}/out")"
    local inst; inst="$(grep ' install ' "${TM_TMP}/calls")"
    tm_assert_nonempty "$inst" "apt-get install was never called"
    case "$inst" in *.deb*) _tm_afail "apt was handed .deb files — THE DEFECT: ${inst}" ;; esac
    case "$inst" in *" nginx polkitd") ;; *) _tm_afail "apt was not asked for exactly the missing top-level packages: ${inst}" ;; esac
    case "$inst" in *--no-download*) ;; *) _tm_afail "install ran without --no-download: ${inst}" ;; esac
    grep -q ' update' "${TM_TMP}/calls" || _tm_afail "the private package lists were never built (no update)"
}
tm_case "apt-is-given-package-names-never-a-deb-list" none a_only_names_never_debs

a_private_pinned_source() {
    _build 0; _run
    tm_assert_eq "deb [trusted=yes] file:${TM_TMP}/bundle ./" "$(cat "${TM_TMP}/seen.sources" 2>/dev/null)" \
        "the private source list is not exactly the bundle, trusted for that path only"
    grep -q '^Pin: origin ""$' "${TM_TMP}/seen.prefs" 2>/dev/null \
        && grep -q '^Pin-Priority: 1$' "${TM_TMP}/seen.prefs" \
        || _tm_afail "the bundle is not pinned to priority 1 — it could upgrade or replace an
        installed package, such as a FIPS library: $(cat "${TM_TMP}/seen.prefs" 2>/dev/null)"
    grep -q 'nginx_1.24.0_amd64.deb' "${TM_TMP}/seen.archives" 2>/dev/null \
        || _tm_afail "the bundle .debs were not in the private archive cache, so --no-download could not use them"
    grep -q 'Dir::Etc::SourceParts=' "${TM_TMP}/calls" \
        || _tm_afail "the host's sources.list.d was not excluded; apt could reach a network source"
}
tm_case "the-source-is-private-trusted-for-one-path-and-pinned" none a_private_pinned_source

a_cleanup_on_failure() {
    _build 100; _run
    tm_assert_ne 0 "$RC" "a failed apt install was reported as success"
    tm_assert_nogrep "RETURNED" "${TM_TMP}/out" "the run carried on past a failed package install"
    tm_assert_grep "Nothing installed on the" "${TM_TMP}/out" "the failure message does not say nothing installed was replaced"
    [ -z "$(ls -A "${TM_TMP}/tmproot")" ] \
        || _tm_afail "the temporary apt configuration was left behind after the failure: $(ls "${TM_TMP}/tmproot")"
}
tm_case "the-temporary-apt-config-is-removed-on-failure" none a_cleanup_on_failure

a_needs_an_index() {
    _build 0; rm -f "${TM_TMP}/bundle/Packages"; _run
    tm_assert_ne 0 "$RC" "a bundle with no Packages index was used anyway"
    [ ! -s "${TM_TMP}/calls" ] || _tm_afail "apt was called without an index: $(cat "${TM_TMP}/calls")"
}
tm_case "an-unindexed-bundle-is-refused" none a_needs_an_index

a_no_raw_deb_install_anywhere() {
    grep -nE 'apt-get[^#]*install[^#]*(\.deb|DEBS|\$\{PKG_DIR\})' "$INSTALL_SH" > "${TM_TMP}/hits" \
        && _tm_afail "install.sh still hands apt a list of .deb files: $(cat "${TM_TMP}/hits")" || true
    grep -q 'apt_install_from_bundle "${SCRIPT_DIR}/install/packages/apt" "${MISSING_PKGS\[@\]}"' "$INSTALL_SH" \
        || _tm_afail "the offline branch no longer installs only the missing top-level packages"
    grep -qE 'apt-ftparchive packages|dpkg-scanpackages' "$PREP" && grep -q 'Packages.gz' "$PREP" \
        || _tm_afail "prepare-offline.sh no longer indexes the bundled .debs"
}
tm_case "no-raw-deb-list-and-the-bundle-is-indexed" none a_no_raw_deb_install_anywhere

tm_finish
