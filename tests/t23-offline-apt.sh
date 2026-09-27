#!/usr/bin/env bash
# =============================================================================
# t23 — THE OFFLINE BUNDLE IS AN APT REPOSITORY, NOT A LIST OF .DEBS.
#
# ROUND 2. MEASURED 2026-09-26 on a real STIG (USG) + FIPS Ubuntu 24.04.4 host:
# the 9a794ff bundle's install.sh handed apt every bundled .deb that was not
# installed. The bundle is a dependency CLOSURE, so it holds every alternative
# provider, and apt answered "pkgProblemResolver::Resolve generated breaks".
#
# ROUND 3. MEASURED on the same host with the 95eb5ff bundle: the bundle was
# pinned to priority 1, BELOW every installed package, so apt could never
# upgrade anything, and
#   python3.12-venv : Depends: python3.12 (= 3.12.3-1ubuntu0.17)
#                     but 3.12.3-1ubuntu0.13 is to be installed
# An air-gapped host lags on patches, so this fails on almost every real one.
# The policy is now: never DOWNGRADE, never replace a FIPS package, but
# UPGRADE what a dependency requires. Pinned here by:
#   * stub cases (run everywhere) that drive the REAL apt_install_from_bundle
#     and apt_fips_packages with a stub apt-get / apt-cache / dpkg-query and
#     read what apt was told: names only, --no-download, --no-remove, a
#     private source AND private preferences, the bundle at 500 (never >= 1000),
#     a -1 pin for every installed FIPS package (by version string or by
#     origin), a plan summary printed before the install, a plan that would
#     downgrade / remove / touch a FIPS package refused, the temporary config
#     gone after a failure at every stage;
#   * REAL-APT cases (Debian/Ubuntu only) that run the actual resolver against
#     a fixture dpkg status and a private file: repository: a dependency that
#     needs an upgrade of an installed non-FIPS library RESOLVES; one that
#     needs a newer build of an installed +Fips1 library is refused BY APT
#     (the pin, not a later check); an older bundled copy is never a
#     downgrade. The real install step is forced to a simulation (-s), so
#     nothing is ever installed on the host running the tests.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "offline packages: apt resolves from the bundle; upgrades allowed, no downgrade, FIPS never replaced"

INSTALL_SH="$(tm_install_sh)"
PREP="${TM_REPO_ROOT}/prepare-offline.sh"

# The functions under test, extracted verbatim, plus a driver.
_driver() {
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'die() { echo "[DIE] $*" >&2; exit 1; }; info() { echo "[INFO] $*"; }'
        echo 'NON_INTERACTIVE="${T_NONINT:-true}"'
        tm_extract_func "$INSTALL_SH" apt_fips_packages
        tm_extract_func "$INSTALL_SH" apt_plan_names
        tm_extract_func "$INSTALL_SH" apt_removal_reason
        tm_extract_func "$INSTALL_SH" apt_install_from_bundle
        echo 'apt_install_from_bundle "$@"'
        echo 'echo RETURNED'
    } > "${TM_TMP}/aib.sh"
}

# ─── stub environment ────────────────────────────────────────────────────────
# Installed set (dpkg-query), host origins (apt-cache policy) and the simulated
# plan (apt-get -s) come from files in TM_TMP, so each case sets exactly the
# state it is about. The stub apt-get records every call, and a COPY of the
# private config as it was DURING the call, so a case reads what apt was told.
_stub() {   # _stub <update-rc> <sim-rc> <install-rc>
    mkdir -p "${TM_TMP}/bin" "${TM_TMP}/bundle" "${TM_TMP}/tmproot"
    : > "${TM_TMP}/bundle/nginx_1.24.0_amd64.deb"
    : > "${TM_TMP}/bundle/systemd-standalone-sysusers_255_amd64.deb"
    printf 'Package: nginx\n' > "${TM_TMP}/bundle/Packages"
    printf 'python3.12\t3.12.3-1ubuntu0.13\tinstall ok installed\n' > "${TM_TMP}/dpkg.out"
    printf 'python3.12:\n  Installed: 3.12.3-1ubuntu0.13\n  Candidate: 3.12.3-1ubuntu0.13\n  Version table:\n *** 3.12.3-1ubuntu0.13 100\n        100 /var/lib/dpkg/status\n' > "${TM_TMP}/policy.out"
    printf 'Inst nginx (1.24.0-2ubuntu7 localhost [amd64])\nConf nginx (1.24.0-2ubuntu7 localhost [amd64])\n' > "${TM_TMP}/sim.out"
    cat > "${TM_TMP}/bin/apt-get" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TM_TMP}/calls"
for a in "\$@"; do
    case "\$a" in Dir::Etc::SourceList=*) cp "\${a#*=}" "${TM_TMP}/seen.sources" ;;
                  Dir::Etc::Preferences=*) cp "\${a#*=}" "${TM_TMP}/seen.prefs" ;;
                  Dir::Cache::Archives=*) ls "\${a#*=}" > "${TM_TMP}/seen.archives" ;; esac
done
case " \$* " in
    *" update "*)       exit ${1} ;;
    *" -s install "*)   cat "${TM_TMP}/sim.out"; exit ${2} ;;
    *" install "*)      echo APT-INSTALL-RAN; exit ${3} ;;
esac
exit 0
STUB
    cat > "${TM_TMP}/bin/apt-cache" <<STUB
#!/usr/bin/env bash
printf 'apt-cache %s\n' "\$*" >> "${TM_TMP}/calls"
[ -f "${TM_TMP}/policy.fail" ] && exit 100
cat "${TM_TMP}/policy.out"
STUB
    cat > "${TM_TMP}/bin/dpkg-query" <<STUB
#!/usr/bin/env bash
# "-W -f=<fmt> name..." answers for the NAMED packages only, as dpkg-query does.
case "\$*" in *source:Package*)
    shift 2; for n in "\$@"; do awk -F'\t' -v p="\$n" '\$1 == p' "${TM_TMP}/dpkg.src" 2>/dev/null; done; exit 0 ;; esac
# A failing dpkg-query can still print PART of the database first (a damaged
# status file) — the failure must stop the run, not the emptiness.
cat "${TM_TMP}/dpkg.out"
[ -f "${TM_TMP}/dpkg.fail" ] && exit 2
exit 0
STUB
    # dpkg --compare-versions, for the workstation (no dpkg there). The
    # fixture versions are ones sort -V orders exactly as dpkg does.
    cat > "${TM_TMP}/bin/dpkg" <<'STUB'
#!/usr/bin/env bash
[ "$1" = --compare-versions ] || exit 2
[ "$3" = gt ] || exit 2
[ "$2" != "$4" ] && [ "$(printf '%s\n%s\n' "$2" "$4" | sort -V | tail -1)" = "$2" ]
STUB
    chmod +x "${TM_TMP}/bin/"*
    _driver
}
_run() {    # _run <top-level package>...
    RC=0; TMPDIR="${TM_TMP}/tmproot" PATH="${TM_TMP}/bin:${PATH}" \
        bash "${TM_TMP}/aib.sh" "${TM_TMP}/bundle" "$@" > "${TM_TMP}/out" 2>&1 || RC=$?
}
_install_call() { grep -v -- ' -s install ' "${TM_TMP}/calls" | grep -- ' install ' || true; }

a_only_names_never_debs() {
    _stub 0 0 0; _run nginx polkitd
    tm_assert_rc 0 "$RC" "the install failed with a succeeding apt: $(cat "${TM_TMP}/out")"
    local inst; inst="$(_install_call)"
    tm_assert_nonempty "$inst" "apt-get install was never called"
    case "$inst" in *.deb*) _tm_afail "apt was handed .deb files — THE ROUND-2 DEFECT: ${inst}" ;; esac
    case "$inst" in *" nginx polkitd") ;; *) _tm_afail "apt was not asked for exactly the missing top-level packages: ${inst}" ;; esac
    case "$inst" in *--no-download*) ;; *) _tm_afail "install ran without --no-download: ${inst}" ;; esac
    case "$inst" in *--no-remove*) ;; *) _tm_afail "install ran without --no-remove, so apt could remove a package: ${inst}" ;; esac
    grep -q ' update' "${TM_TMP}/calls" || _tm_afail "the private package lists were never built (no update)"
}
tm_case "apt-is-given-package-names-never-a-deb-list" none a_only_names_never_debs

a_private_source_and_priority() {
    _stub 0 0 0; _run nginx
    tm_assert_eq "deb [trusted=yes] file:${TM_TMP}/bundle ./" "$(cat "${TM_TMP}/seen.sources" 2>/dev/null)" \
        "the private source list is not exactly the bundle, trusted for that path only"
    # The Package: * stanza is the bundle's priority. 500 lets apt UPGRADE an
    # installed package when a dependency needs it (priority 1 was the round-3
    # defect); 1000 or more would let it DOWNGRADE one.
    local prio
    prio="$(awk '/^Package: \*$/ { s = 1; next } s && /^Pin-Priority:/ { print $2; exit }' "${TM_TMP}/seen.prefs" 2>/dev/null)"
    tm_assert_eq 500 "$prio" "the bundle is not at priority 500 (1 blocks every upgrade a dependency needs; >= 1000 permits a downgrade)"
    grep -q '^Pin: origin ""$' "${TM_TMP}/seen.prefs" || _tm_afail "the bundle pin does not select the bundle (origin \"\")"
    awk '/^Pin-Priority:/ && $2 >= 1000 { bad = 1 } END { exit !bad }' "${TM_TMP}/seen.prefs" \
        && _tm_afail "a priority >= 1000 is in the bundle preferences — apt may DOWNGRADE: $(cat "${TM_TMP}/seen.prefs")"
    grep -q 'nginx_1.24.0_amd64.deb' "${TM_TMP}/seen.archives" 2>/dev/null \
        || _tm_afail "the bundle .debs were not in the private archive cache, so --no-download could not use them"
    grep -q 'Dir::Etc::SourceParts=' "${TM_TMP}/calls" \
        || _tm_afail "the host's sources.list.d was not excluded; apt could reach a network source"
    grep -q "Dir::Etc::PreferencesParts=${TM_TMP}/tmproot/" "${TM_TMP}/calls" \
        || _tm_afail "the host's preferences.d was not excluded; a host pin could lift the bundle to >= 1000"
    return 0
}
tm_case "the-bundle-is-private-and-at-priority-500" none a_private_source_and_priority

# (b) An installed +Fips1 package gets a -1 pin for the BUNDLE's copy.
_fips_stanza() {   # _fips_stanza <pkg> -> the Pin-Priority of its own stanza
    awk -v p="Package: $1" '$0 == p { s = 1; next } s && /^Package:/ { exit } s && /^Pin-Priority:/ { print $2; exit }' \
        "${TM_TMP}/seen.prefs" 2>/dev/null
}
a_fips_by_version() {
    _stub 0 0 0
    printf '%s\n' \
        $'libssl3t64\t3.0.13-0ubuntu3.4+Fips1\tinstall ok installed' \
        $'openssh-server\t1:9.6p1-3ubuntu13.5+fips\tinstall ok installed' \
        $'python3.12\t3.12.3-1ubuntu0.13\tinstall ok installed' \
        $'libgnutls30t64\t3.8.3-1.1ubuntu3.2+Fips1\tdeinstall ok config-files' > "${TM_TMP}/dpkg.out"
    _run nginx
    tm_assert_rc 0 "$RC" "the install failed: $(cat "${TM_TMP}/out")"
    tm_assert_eq -1 "$(_fips_stanza libssl3t64)" "the installed +Fips1 libssl3t64 has no -1 pin for the bundle copy — THE FIPS MUTATION"
    tm_assert_eq -1 "$(_fips_stanza openssh-server)" "a lower-case 'fips' version was not recognised as FIPS"
    tm_assert_eq "" "$(_fips_stanza python3.12)" "a non-FIPS package was pinned away from the bundle, so it could never be upgraded"
    tm_assert_eq "" "$(_fips_stanza libgnutls30t64)" "a package that is NOT installed (config-files only) was treated as installed"
    grep -qx 'Pin: origin ""' <<<"$(awk '/^Package: libssl3t64$/ { getline; print; exit }' "${TM_TMP}/seen.prefs")" \
        || _tm_afail "the FIPS pin does not target the bundle's copy (origin \"\"): $(cat "${TM_TMP}/seen.prefs")"
}
tm_case "an-installed-fips-version-pins-the-bundle-copy-at-minus-1" none a_fips_by_version

a_fips_by_origin() {
    _stub 0 0 0
    printf '%s\n' $'libgcrypt20\t1.10.3-2build1\tinstall ok installed' \
                  $'libfoo1\t2.0-1\tinstall ok installed' \
                  $'libbaz1\t3.0-1\tinstall ok installed' > "${TM_TMP}/dpkg.out"
    # libgcrypt20's INSTALLED version comes from the FIPS archive; libfoo1's
    # and libbaz1's do not (a FIPS build is merely AVAILABLE — listed above the
    # installed version for one, below it for the other).
    cat > "${TM_TMP}/policy.out" <<'EOF'
libgcrypt20:amd64:
  Installed: 1.10.3-2build1
  Candidate: 1.10.3-2build1
  Version table:
 *** 1.10.3-2build1 1001
       1001 https://esm.ubuntu.com/fips-updates/ubuntu noble-updates/main amd64 Packages
        100 /var/lib/dpkg/status
libfoo1:
  Installed: 2.0-1
  Candidate: 2.0-1
  Version table:
     2.0-1fips 1001
       1001 https://esm.ubuntu.com/fips/ubuntu noble/main amd64 Packages
 *** 2.0-1 500
        500 http://archive.ubuntu.com/ubuntu noble/main amd64 Packages
        100 /var/lib/dpkg/status
libbaz1:amd64:
  Installed: 3.0-1
  Candidate: 3.0-1
  Version table:
 *** 3.0-1 500
        500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages
        100 /var/lib/dpkg/status
     2.9-1 1001
       1001 https://esm.ubuntu.com/fips/ubuntu noble/main amd64 Packages
EOF
    _run nginx
    tm_assert_rc 0 "$RC" "the install failed: $(cat "${TM_TMP}/out")"
    tm_assert_eq -1 "$(_fips_stanza libgcrypt20)" "a package installed FROM the FIPS archive was not pinned at -1"
    tm_assert_eq "" "$(_fips_stanza libfoo1)" "a package was pinned because a FIPS build is AVAILABLE, not because it is installed"
    tm_assert_eq "" "$(_fips_stanza libbaz1)" "an origin line of a version BELOW the installed one was read as the installed origin"
    # The policy header is "libgcrypt20:amd64:" — the pin must name the package.
    grep -q '^Package: [^ ]*:' "${TM_TMP}/seen.prefs" && _tm_afail "an architecture-qualified name reached the preferences: $(cat "${TM_TMP}/seen.prefs")" || true
    grep -q '^apt-cache policy .*libgcrypt20' "${TM_TMP}/calls" || _tm_afail "the host's apt-cache policy was never asked for the installed origins"
}
tm_case "a-package-installed-from-a-fips-archive-is-pinned" none a_fips_by_origin

a_fips_unknown_fails_closed() {
    _stub 0 0 0; : > "${TM_TMP}/dpkg.fail"; _run nginx
    tm_assert_ne 0 "$RC" "the install went ahead without knowing which packages are FIPS modules"
    [ ! -s "${TM_TMP}/calls" ] || _tm_afail "apt was run although the FIPS set could not be read: $(cat "${TM_TMP}/calls")"
    tm_assert_grep "FIPS modules" "${TM_TMP}/out" "the refusal does not say why"
}
tm_case "an-unreadable-package-set-stops-before-apt" none a_fips_unknown_fails_closed

a_fips_empty_fails_closed() {
    _stub 0 0 0; : > "${TM_TMP}/dpkg.out"; _run nginx
    tm_assert_ne 0 "$RC" "an EMPTY installed set was taken as 'no FIPS packages'"
    grep -q -- ' install ' "${TM_TMP}/calls" 2>/dev/null && _tm_afail "apt was run on an empty installed set: $(cat "${TM_TMP}/calls")" || true
}
tm_case "an-empty-package-set-stops-before-apt" none a_fips_empty_fails_closed

a_origins_unknown_fails_closed() {
    _stub 0 0 0; : > "${TM_TMP}/policy.fail"; _run nginx
    tm_assert_ne 0 "$RC" "the install went ahead without knowing where the installed packages came from"
    grep -qv '^apt-cache ' "${TM_TMP}/calls" && _tm_afail "apt-get was run although the origins could not be read: $(cat "${TM_TMP}/calls")" || true
}
tm_case "unreadable-origins-stop-before-apt" none a_origins_unknown_fails_closed

# The operator sees NEW and UPGRADE, as package=version, BEFORE the install.
a_plan_summary() {
    _stub 0 0 0
    printf '%s\n' 'Inst python3.12 [3.12.3-1ubuntu0.13] (3.12.3-1ubuntu0.17 localhost [amd64])' \
                  'Inst python3.12-venv (3.12.3-1ubuntu0.17 localhost [amd64])' \
                  'Conf python3.12 (3.12.3-1ubuntu0.17 localhost [amd64])' > "${TM_TMP}/sim.out"
    _run python3-venv
    tm_assert_rc 0 "$RC" "an upgrade a dependency needs was refused: $(cat "${TM_TMP}/out")"
    tm_assert_grep "NEW (1): python3.12-venv=3.12.3-1ubuntu0.17;" "${TM_TMP}/out" "the plan does not name what is NEWLY installed"
    tm_assert_grep "UPGRADE (1): python3.12=3.12.3-1ubuntu0.17 (from 3.12.3-1ubuntu0.13)" "${TM_TMP}/out" "the plan does not name what is UPGRADED"
    local ln_plan ln_inst
    ln_plan="$(grep -n 'Offline package plan' "${TM_TMP}/out" | sed -n 1p | cut -d: -f1)"
    ln_inst="$(grep -n 'APT-INSTALL-RAN' "${TM_TMP}/out" | sed -n 1p | cut -d: -f1)"
    [ -n "$ln_plan" ] && [ -n "$ln_inst" ] && [ "$ln_plan" -lt "$ln_inst" ] \
        || _tm_afail "the plan was not printed BEFORE the install ran: $(cat "${TM_TMP}/out")"
    grep -q -- ' -s install .*python3-venv' "${TM_TMP}/calls" || _tm_afail "the plan was not simulated with the same request"
}
tm_case "the-plan-names-new-and-upgraded-before-installing" none a_plan_summary

_refused() {   # _refused <sim line> <expected text> <why>
    _stub 0 0 0; printf '%s\n' "$1" > "${TM_TMP}/sim.out"
    printf '%s\n' $'libssl3t64\t3.0.13-0ubuntu3.4+Fips1\tinstall ok installed' > "${TM_TMP}/dpkg.out"
    _run nginx
    tm_assert_ne 0 "$RC" "$3"
    tm_assert_grep "$2" "${TM_TMP}/out" "$3"
    [ -z "$(_install_call)" ] || _tm_afail "the refused plan was installed anyway: $(_install_call)"
    [ -z "$(ls -A "${TM_TMP}/tmproot")" ] || _tm_afail "the temporary apt configuration was left behind after the refusal"
}
a_plan_downgrade() { _refused 'Inst nginx [1.26.0-1] (1.24.0-2ubuntu7 localhost [amd64])' "would be DOWNGRADED" "a downgrade in the plan was not refused"; }
tm_case "a-plan-that-downgrades-is-refused" none a_plan_downgrade
a_plan_fips() { _refused 'Inst libssl3t64 [3.0.13-0ubuntu3.4+Fips1] (3.0.13-0ubuntu3.5 localhost [amd64])' "FIPS package" "a plan replacing a FIPS package was not refused"; }
tm_case "a-plan-that-replaces-a-fips-package-is-refused" none a_plan_fips
a_plan_fips_arch() { _refused 'Inst libssl3t64:i386 (3.0.13-0ubuntu3.5 localhost [i386])' "FIPS package" "a new foreign-architecture copy of a FIPS package was not refused"; }
tm_case "a-plan-adding-another-arch-of-a-fips-package-is-refused" none a_plan_fips_arch
a_plan_remove() { _refused 'Remv dbus-broker [33-1]' "would be REMOVED" "a removal in the plan was not refused"; }
tm_case "a-plan-that-removes-a-package-is-refused" none a_plan_remove

# (c) The private sources AND preferences are gone after a failure — at the
# update, at the simulation and at the install — and the message says what the
# policy is: never downgrades, never replaces FIPS packages.
_cleanup_case() {   # _cleanup_case <update-rc> <sim-rc> <install-rc> <expected text>
    _stub "$1" "$2" "$3"; _run nginx polkitd
    tm_assert_ne 0 "$RC" "a failed apt step was reported as success"
    tm_assert_nogrep "RETURNED" "${TM_TMP}/out" "the run carried on past a failed package step"
    tm_assert_file "${TM_TMP}/seen.prefs" "the preferences file was never created (nothing to prove removed)"
    tm_assert_file "${TM_TMP}/seen.sources" "the sources file was never created (nothing to prove removed)"
    [ -z "$(ls -A "${TM_TMP}/tmproot")" ] \
        || _tm_afail "the temporary sources/preferences were left behind after the failure: $(find "${TM_TMP}/tmproot")"
    tm_assert_grep "never downgrades a package and never" "${TM_TMP}/out" "the failure message does not state the policy"
    tm_assert_grep "$4" "${TM_TMP}/out" "the failure message claims the wrong state"
    tm_assert_nogrep "pinned below every installed package" "${TM_TMP}/out" "the failure message still makes the round-2 claim"
}
a_cleanup_update()  { _cleanup_case 100 0 0 "nothing was"; }
tm_case "config-removed-when-the-update-fails" none a_cleanup_update
a_cleanup_sim()     { _cleanup_case 0 100 0 "nothing was"; }
tm_case "config-removed-when-resolution-fails" none a_cleanup_sim
a_cleanup_install() { _cleanup_case 0 0 100 "may have applied PART"; }
tm_case "config-removed-when-the-install-fails" none a_cleanup_install

# Round 4, the real STIG + FIPS host: apt could only upgrade python3.12 by
# REMOVING its lockstep sibling libpython3.12t64 (and what depends on it).
# --no-remove refuses; the message must NAME the missing siblings, tell them
# apart from the collateral, and point at rebuilding the bundle.
_removal_sim() {
    cat > "${TM_TMP}/sim.out" <<'EOF'
The following packages will be REMOVED:
  libpython3.12t64 linux-tools-6.8.0-142-fips ubuntu-server
  vim*
The following NEW packages will be installed:
  nginx python3.12-venv
The following packages will be upgraded:
  libpython3.12-stdlib python3.12
  python3.12-minimal
E: Packages need to be removed but remove is disabled.
EOF
}
a_removal_names_siblings() {
    _stub 0 100 0; _removal_sim
    printf '%s\n' $'python3.12\tpython3.12' $'python3.12-minimal\tpython3.12' $'libpython3.12-stdlib\tpython3.12' \
        $'libpython3.12t64\tpython3.12' $'vim\tvim' $'ubuntu-server\tubuntu-meta' \
        $'linux-tools-6.8.0-142-fips\tlinux-fips' > "${TM_TMP}/dpkg.src"
    _run python3-venv nginx
    tm_assert_ne 0 "$RC" "a plan that needs removals was not refused"
    tm_assert_grep "Lockstep siblings missing from the bundle: libpython3.12t64 (source python3.12)" "${TM_TMP}/out" \
        "the refusal does not name the lockstep sibling the bundle lacks"
    tm_assert_grep "Would be removed with them (they depend on them): linux-tools-6.8.0-142-fips ubuntu-server vim" "${TM_TMP}/out" \
        "the collateral removals are not told apart from the missing sibling"
    # (apt's own listing, echoed above the message, legitimately carries "vim*")
    grep -q 'depend on them): .*vim\*' "${TM_TMP}/out" && _tm_afail "apt's purge marker (*) was kept on a package name"
    tm_assert_grep "FULLY PATCHED" "${TM_TMP}/out" "the refusal does not point at rebuilding the bundle on a fully patched host"
    tm_assert_grep "nothing was" "${TM_TMP}/out" "the refusal does not say nothing changed"
    [ -z "$(_install_call)" ] || _tm_afail "the install ran after a refused resolution"
    [ -z "$(ls -A "${TM_TMP}/tmproot")" ] || _tm_afail "the temporary apt configuration was left behind"
}
tm_case "a-forced-removal-names-the-missing-lockstep-siblings" none a_removal_names_siblings

a_removal_without_sibling() {
    _stub 0 100 0
    printf '%s\n' 'The following packages will be REMOVED:' '  dbus-broker' \
        'The following NEW packages will be installed:' '  nginx' \
        'E: Packages need to be removed but remove is disabled.' > "${TM_TMP}/sim.out"
    printf '%s\n' $'dbus-broker\tdbus-broker' > "${TM_TMP}/dpkg.src"
    _run nginx
    tm_assert_ne 0 "$RC" "a plan that needs a removal was not refused"
    tm_assert_grep "Would be removed: dbus-broker" "${TM_TMP}/out" "a removal with no upgraded sibling source is not named"
    tm_assert_nogrep "Lockstep siblings missing" "${TM_TMP}/out" "a removal that shares no source with an upgrade was blamed on a missing sibling"
}
tm_case "a-removal-with-no-upgraded-source-is-not-called-a-sibling" none a_removal_without_sibling

a_needs_an_index() {
    _stub 0 0 0; rm -f "${TM_TMP}/bundle/Packages"; _run nginx
    tm_assert_ne 0 "$RC" "a bundle with no Packages index was used anyway"
    [ ! -s "${TM_TMP}/calls" ] || _tm_afail "apt was called without an index: $(cat "${TM_TMP}/calls")"
}
tm_case "an-unindexed-bundle-is-refused" none a_needs_an_index

# On a terminal without --non-interactive the operator confirms the plan.
a_prompt_declined() {
    _stub 0 0 0
    RC=0; printf 'n\n' | T_NONINT=false TMPDIR="${TM_TMP}/tmproot" PATH="${TM_TMP}/bin:${PATH}" \
        script -qec "bash '${TM_TMP}/aib.sh' '${TM_TMP}/bundle' nginx" /dev/null > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_grep "Apply this package plan?" "${TM_TMP}/out" "no confirmation was asked for on a terminal"
    tm_assert_grep "declined" "${TM_TMP}/out" "a declined plan was not reported as declined"
    [ -z "$(_install_call)" ] || _tm_afail "the plan was installed although the operator said no"
    [ -z "$(ls -A "${TM_TMP}/tmproot")" ] || _tm_afail "the temporary apt configuration was left behind after the decline"
}
tm_case "a-terminal-operator-can-decline-the-plan" pty a_prompt_declined

a_noninteractive_no_prompt() {
    _stub 0 0 0
    RC=0; printf 'n\n' | T_NONINT=true TMPDIR="${TM_TMP}/tmproot" PATH="${TM_TMP}/bin:${PATH}" \
        script -qec "bash '${TM_TMP}/aib.sh' '${TM_TMP}/bundle' nginx" /dev/null > "${TM_TMP}/out" 2>&1 || RC=$?
    tm_assert_nogrep "Apply this package plan?" "${TM_TMP}/out" "--non-interactive still prompted"
    tm_assert_nonempty "$(_install_call)" "--non-interactive did not proceed to the install"
}
tm_case "non-interactive-proceeds-without-a-prompt" pty a_noninteractive_no_prompt

# ─── the REAL resolver ───────────────────────────────────────────────────────
# A fixture "installed" set (a private dpkg status file) and a fixture bundle
# (a private file: repository with hashed .debs). apt-get is wrapped so that
# every call also reads the fixture status, takes no lock, and — for the
# install step — only SIMULATES: nothing is ever installed on this host.
_real() {
    local real_apt; real_apt="$(command -v apt-get)"
    mkdir -p "${TM_TMP}/bin" "${TM_TMP}/bundle" "${TM_TMP}/tmproot"
    : > "${TM_TMP}/status"
    _st() { printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nArchitecture: all\nVersion: %s\nMaintainer: t <t@example.org>\nDescription: fixture\n\n' "$1" "$2" >> "${TM_TMP}/status"
            printf '%s\t%s\tinstall ok installed\n' "$1" "$2" >> "${TM_TMP}/dpkg.out"; }
    _pk() { local f="${TM_TMP}/bundle/${1}_${2}_all.deb"
            printf 'fixture %s %s' "$1" "$2" > "$f"
            printf 'Package: %s\nVersion: %s\nArchitecture: all\n' "$1" "$2" >> "${TM_TMP}/bundle/Packages"
            [ -z "${3:-}" ] || printf 'Depends: %s\n' "$3" >> "${TM_TMP}/bundle/Packages"
            printf 'Filename: ./%s\nSize: %s\nSHA256: %s\nDescription: fixture\n\n' "$(basename "$f")" \
                "$(wc -c < "$f" | tr -d ' ')" "$(sha256sum "$f" | cut -d' ' -f1)" >> "${TM_TMP}/bundle/Packages"; }
    : > "${TM_TMP}/dpkg.out"
    _st libfoo 1.0; _st libssl-t 3.0-1+Fips1; _st libbar 2.0
    _pk app-a 1.0 'libfoo (>= 1.1)'; _pk libfoo 1.1          # (a) needs an upgrade of a non-FIPS lib
    _pk app-b 1.0 'libssl-t (>= 3.0-2)'; _pk libssl-t 3.0-2  # (b) needs a newer build of a FIPS lib
    _pk libbar 1.0                                          # older than the installed 2.0
    _pk app-c 1.0 'libbar'
    printf 'libfoo:\n  Installed: 1.0\n' > "${TM_TMP}/policy.out"
    cat > "${TM_TMP}/bin/apt-get" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TM_TMP}/calls"
for a in "\$@"; do case "\$a" in Dir::Etc::Preferences=*) cp "\${a#*=}" "${TM_TMP}/seen.prefs" ;; esac; done
extra=(-o "Dir::State::status=${TM_TMP}/status" -o Debug::NoLocking=1)
case " \$* " in
    *" -s "*|*" update "*) exec "${real_apt}" "\${extra[@]}" "\$@" ;;
    *" install "*) args=(); for a in "\$@"; do [ "\$a" = -y ] || args+=("\$a"); done
                   exec "${real_apt}" "\${extra[@]}" -s "\${args[@]}" ;;
esac
exit 99
STUB
    cat > "${TM_TMP}/bin/apt-cache" <<STUB
#!/usr/bin/env bash
cat "${TM_TMP}/policy.out"
STUB
    cat > "${TM_TMP}/bin/dpkg-query" <<STUB
#!/usr/bin/env bash
cat "${TM_TMP}/dpkg.out"
STUB
    chmod +x "${TM_TMP}/bin/"*
    _driver
}

a_real_upgrade_resolves() {
    _real; _run app-a
    tm_assert_rc 0 "$RC" "(a) a package needing a NEWER build of an installed non-FIPS library did not resolve —
        THE ROUND-3 DEFECT (python3.12-venv needing python3.12 0ubuntu0.17): $(cat "${TM_TMP}/out")"
    tm_assert_grep "UPGRADE (1): libfoo=1.1 (from 1.0)" "${TM_TMP}/out" "the real plan does not show the upgrade"
    tm_assert_grep "NEW (1): app-a=1.0;" "${TM_TMP}/out" "the real plan does not show the new package"
    tm_assert_grep "RETURNED" "${TM_TMP}/out" "the run did not carry on after a successful resolution"
}
tm_case "real-apt-a-needed-upgrade-of-an-installed-lib-resolves" apt a_real_upgrade_resolves

a_real_fips_held() {
    _real; _run app-b
    tm_assert_ne 0 "$RC" "(b) the bundle's non-FIPS libssl-t replaced the installed 3.0-1+Fips1: $(cat "${TM_TMP}/out")"
    tm_assert_eq -1 "$(_fips_stanza libssl-t)" "the installed +Fips1 package has no -1 pin for the bundle copy"
    # Refused by the RESOLVER because of the pin — not caught later by the
    # plan check, which would mean the pin itself did nothing.
    tm_assert_grep "but 3.0-1+Fips1 is to be installed" "${TM_TMP}/out" \
        "apt itself did not hold the FIPS package; the -1 pin is not doing the work"
    tm_assert_nogrep "Refusing the offline package plan" "${TM_TMP}/out" "the FIPS package reached the plan; the -1 pin is not doing the work"
    [ -z "$(ls -A "${TM_TMP}/tmproot")" ] || _tm_afail "the temporary apt configuration was left behind"
}
tm_case "real-apt-b-an-installed-fips-lib-is-never-replaced" apt a_real_fips_held

a_real_never_downgrades() {
    _real; _run app-c libbar
    tm_assert_rc 0 "$RC" "installing next to an installed libbar 2.0 failed (the bundle holds 1.0): $(cat "${TM_TMP}/out")"
    tm_assert_nogrep "libbar=" "${TM_TMP}/out" "the bundle's OLDER libbar entered the plan — a DOWNGRADE"
    tm_assert_grep "NEW (1): app-c=1.0;" "${TM_TMP}/out" "the real plan does not show the new package"
}
tm_case "real-apt-an-older-bundled-copy-is-never-a-downgrade" apt a_real_never_downgrades

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
