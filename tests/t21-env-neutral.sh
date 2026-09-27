#!/usr/bin/env bash
# =============================================================================
# t21 — NOTHING THAT SHIPS NAMES THE SITE IT WAS BUILT AT (v1.1.0).
#
#   * the tracked tree carries no environment tie (tools/check-env-neutral.sh);
#   * that gate can fail, in all three of its modes;
#   * the offline bundle is built from the COMMITTED tree, with the internal
#     records (.claude/, .work/) export-ignored and untracked files left out,
#     and a bundle that picks up a tie is deleted, not shipped. The real
#     bundle block of prepare-offline.sh is driven against a scratch git
#     repository — no network, no pip, no apt.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "environment-neutral tree and a leak-free offline bundle"

GATE="${TM_REPO_ROOT}/tools/check-env-neutral.sh"
PREP="${TM_REPO_ROOT}/prepare-offline.sh"
[ -f "$GATE" ] || tm_die "tools/check-env-neutral.sh is missing"

# A tie, assembled so this file does not itself contain one.
TIE="dc1.int.crypt""iclight.com"

n_repo_is_neutral() {
    bash "$GATE" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "the tracked tree carries an environment tie:
        $(head -15 "${TM_TMP}/out")"
    tm_assert_grep "no environment ties" "${TM_TMP}/out" "the gate did not say what it scanned"
}
tm_case "the-tracked-tree-is-environment-neutral" none n_repo_is_neutral

n_gate_can_fail() {
    mkdir -p "${TM_TMP}/d/docs"
    printf 'nothing to see\n' > "${TM_TMP}/d/ok.md"
    bash "$GATE" --dir "${TM_TMP}/d" > "${TM_TMP}/out" 2>&1 || _tm_afail "a clean directory failed: $(cat "${TM_TMP}/out")"
    printf 'connect to %s\n' "$TIE" > "${TM_TMP}/d/docs/guide.md"
    bash "$GATE" --dir "${TM_TMP}/d" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "the gate passed a directory whose docs name the site's domain controller"
    tm_assert_grep "docs/guide.md:1" "${TM_TMP}/out" "the gate failed but did not say where"
    printf 'ssh 192.168''.1.5\n' > "${TM_TMP}/d/docs/guide.md"
    bash "$GATE" --dir "${TM_TMP}/d" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "the gate passed a private address"
    # Round 2 (adversary F6): every RFC 1918 range, internal DNS suffixes,
    # secret-store paths and the personal namespace — each alone must go red.
    local t
    for t in 'ssh 10.''20.30.40' 'gw 172.''16.5.1' 'gw 172.''31.255.1' 'host broker1.int''.example.org' \
             'host kafka.ops.int''ernal' 'path cre''ds/apps/kafka' 'see james''.rodman/topic-manager'; do
        printf '%s\n' "$t" > "${TM_TMP}/d/docs/guide.md"
        bash "$GATE" --dir "${TM_TMP}/d" > "${TM_TMP}/out" 2>&1 \
            && _tm_afail "the gate passed: ${t}"
    done
    # And nothing that merely LOOKS similar: a public range, a code property.
    printf 'gw 172.''32.0.1; return t.internal; 10.0 GB\n' > "${TM_TMP}/d/docs/guide.md"
    bash "$GATE" --dir "${TM_TMP}/d" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "a false positive: $(cat "${TM_TMP}/out")"
    return 0
}
tm_case "the-gate-goes-red-on-a-tie" none n_gate_can_fail

_tarball() {   # _tarball <out.tar.gz> <dir-to-pack> <top-name>
    tar -czf "$1" -C "$2" "$3"
}
n_bundle_mode() {
    mkdir -p "${TM_TMP}/b/topic-manager-9.9.9/tm"
    printf 'print(1)\n' > "${TM_TMP}/b/topic-manager-9.9.9/tm/x.py"
    _tarball "${TM_TMP}/clean.tgz" "${TM_TMP}/b" topic-manager-9.9.9
    bash "$GATE" --bundle "${TM_TMP}/clean.tgz" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "a clean bundle failed: $(cat "${TM_TMP}/out")"
    mkdir -p "${TM_TMP}/b/topic-manager-9.9.9/.work"
    printf '{"note": "harmless text"}\n' > "${TM_TMP}/b/topic-manager-9.9.9/.work/WO-0001.json"
    _tarball "${TM_TMP}/work.tgz" "${TM_TMP}/b" topic-manager-9.9.9
    bash "$GATE" --bundle "${TM_TMP}/work.tgz" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a bundle carrying .work/ passed — process records must never ship, whatever they say"
    rm -rf "${TM_TMP}/b/topic-manager-9.9.9/.work"
    printf 'host = "%s"\n' "$TIE" > "${TM_TMP}/b/topic-manager-9.9.9/tm/x.py"
    _tarball "${TM_TMP}/tie.tgz" "${TM_TMP}/b" topic-manager-9.9.9
    bash "$GATE" --bundle "${TM_TMP}/tie.tgz" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a bundle whose code names the site passed"
    return 0
}
tm_case "bundle-mode-refuses-internal-files-and-ties" none n_bundle_mode

n_export_ignore() {
    command -v git >/dev/null 2>&1 || tm_die "git is required"
    local a
    for a in .claude/project.yml .work/WO-0001.json; do
        grep -q ': set$' <<<"$(git -C "$TM_REPO_ROOT" check-attr export-ignore "$a")" \
            || _tm_afail "${a} is not export-ignored — git archive (the bundle, the CI release tarball) would ship it"
    done
}
tm_case "internal-records-are-export-ignored" none n_export_ignore

# ─── the REAL bundle block, against a scratch repository ─────────────────────
_prep_block() {
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'die() { echo "[FAIL] $*" >&2; exit 1; }; info() { echo "[INFO] $*"; }; ok() { echo "[OK] $*"; }'
        echo 'sha256_of() { sha256sum "$1" | cut -d" " -f1; }'
        echo 'SCRIPT_DIR="$1"; VERSION="9.9.9"; CREATE_BUNDLE=true'
        echo 'LIB_DIR="${SCRIPT_DIR}/lib"; PY_PKG_DIR="${SCRIPT_DIR}/install/packages/python"; APT_PKG_DIR="${SCRIPT_DIR}/install/packages/apt"'
        TM_S='^if \[\[ \$CREATE_BUNDLE == true \]\]; then$' awk '
            BEGIN { s = ENVIRON["TM_S"] } !on && $0 ~ s { on = 1 } on { print } on && /^fi$/ { exit }' "$PREP"
    } > "${TM_TMP}/prep.sh"
    # Sanity-check the extraction on a line no mutation of the build method
    # touches, so a mutated build is TESTED rather than refused as unextractable.
    grep -q 'BUNDLE_NAME="topic-manager-offline-${VERSION}.tar.gz"' "${TM_TMP}/prep.sh"         || tm_die "could not extract the bundle block from prepare-offline.sh"
}
_scratch_repo() {   # a repo shaped like this one, in ${TM_TMP}/p/src
    local r="${TM_TMP}/p/src"
    rm -rf "${TM_TMP}/p"; mkdir -p "$r/tm" "$r/tools" "$r/.work" "$r/.claude" "$r/lib" \
        "$r/install/packages/python" "$r/install/packages/apt"
    cp "$GATE" "$r/tools/check-env-neutral.sh"
    cp "${TM_REPO_ROOT}/.gitattributes" "$r/.gitattributes"
    printf 'print(1)\n' > "$r/tm/app.py"
    printf '{"prod": "%s"}\n' "$TIE" > "$r/.work/WO-0001.json"
    printf 'contract naming %s\n' "$TIE" > "$r/.claude/project.yml"
    printf 'vue\n' > "$r/lib/vue.global.prod.js"
    printf 'wheel\n' > "$r/install/packages/python/pkg-1.0-py3-none-any.whl"
    printf 'deb\n' > "$r/install/packages/apt/pkg_1.0_amd64.deb"
    printf 'lib/\ninstall/packages/\n' > "$r/.gitignore"
    git -C "$r" init -q && git -C "$r" -c user.email=t@example.org -c user.name=t add -A \
        && git -C "$r" -c user.email=t@example.org -c user.name=t commit -qm init \
        || tm_die "could not build the scratch repository"
    printf 'untracked %s\n' "$TIE" > "$r/UNTRACKED-NOTES.txt"
}
p_bundle_is_the_committed_tree() {
    command -v git >/dev/null 2>&1 || tm_die "git is required"
    _prep_block; _scratch_repo
    TMPDIR="${TM_TMP}" bash "${TM_TMP}/prep.sh" "${TM_TMP}/p/src" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "the bundle block failed on a clean committed tree: $(cat "${TM_TMP}/out")"
    local b="${TM_TMP}/p/topic-manager-offline-9.9.9.tar.gz"
    tm_assert_file "$b" "no bundle was written"
    tm_assert_file "${b}.sha256" "no checksum was written beside the bundle"
    tar -tzf "$b" > "${TM_TMP}/list"
    tm_assert_grep "topic-manager-9.9.9/tm/app.py" "${TM_TMP}/list" "the committed code is missing from the bundle"
    tm_assert_grep "topic-manager-9.9.9/lib/vue.global.prod.js" "${TM_TMP}/list" "the Vue file is missing"
    tm_assert_grep "topic-manager-9.9.9/install/packages/python/pkg-1.0-py3-none-any.whl" "${TM_TMP}/list" "the wheels are missing"
    grep -E '/\.work/|/\.claude/' "${TM_TMP}/list" > /dev/null \
        && _tm_afail "the bundle carries .work/ or .claude/: $(grep -E '/\.work/|/\.claude/' "${TM_TMP}/list")"
    grep -q 'UNTRACKED-NOTES' "${TM_TMP}/list" && _tm_afail "an UNTRACKED file got into the bundle"
    return 0
}
tm_case "the-bundle-is-the-committed-tree-without-internal-files" none p_bundle_is_the_committed_tree

# Round 2 (adversary F4): there is no non-git fallback. A directory that is
# not a git work tree — with an untracked secret sitting in it — is refused,
# and no bundle is written.
p_non_git_tree_is_refused() {
    _prep_block
    local r="${TM_TMP}/p/src"
    rm -rf "${TM_TMP}/p"; mkdir -p "$r/tm" "$r/tools" "$r/lib" "$r/install/packages/python" "$r/install/packages/apt"
    cp "$GATE" "$r/tools/check-env-neutral.sh"
    printf 'print(1)\n' > "$r/tm/app.py"; printf 'vue\n' > "$r/lib/vue.global.prod.js"
    printf 'untracked secret\n' > "$r/NOTES.txt"
    local rc=0
    TMPDIR="${TM_TMP}" GIT_CEILING_DIRECTORIES="${TM_TMP}" bash "${TM_TMP}/prep.sh" "$r" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "a bundle was built from a directory that is not a git work tree"
    tm_assert_grep "git work tree" "${TM_TMP}/out" "the refusal does not say a git work tree is required"
    tm_assert_nofile "${TM_TMP}/p/topic-manager-offline-9.9.9.tar.gz" "a bundle file was written anyway"
    grep -q 'for p in VERSION requirements.txt' "$PREP" \
        && _tm_afail "the directory-copy fallback is still in prepare-offline.sh" || true
}
tm_case "a-non-git-tree-is-refused-no-fallback" none p_non_git_tree_is_refused

p_leaky_bundle_is_deleted() {
    command -v git >/dev/null 2>&1 || tm_die "git is required"
    _prep_block; _scratch_repo
    local r="${TM_TMP}/p/src"
    printf 'SERVER = "%s"\n' "$TIE" > "$r/tm/app.py"
    git -C "$r" -c user.email=t@example.org -c user.name=t commit -qam leak
    local rc=0
    TMPDIR="${TM_TMP}" bash "${TM_TMP}/prep.sh" "$r" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "a bundle whose committed code names the site was reported as built"
    tm_assert_nofile "${TM_TMP}/p/topic-manager-offline-9.9.9.tar.gz" "the leaking bundle was left on disk"
}
tm_case "a-bundle-that-leaks-is-deleted-not-shipped" none p_leaky_bundle_is_deleted


# Round 8 (gatekeeper): IPv6 private/link-local addresses, a file that is not
# valid UTF-8 (it used to be skipped), and a FLAT bundle carrying .work/.
n_round8_blind_spots() {
    local d="${TM_TMP}/r8" P
    mkdir -p "$d/clean" "$d/ula" "$d/ll" "$d/bin"
    printf 'nothing to see\n' > "$d/clean/a.txt"
    bash "$GATE" --dir "$d/clean" > "${TM_TMP}/out" 2>&1 || _tm_afail "a clean directory failed: $(cat "${TM_TMP}/out")"
    P='fd12:3456'; printf 'broker at %s:789a::1\n' "$P" > "$d/ula/a.txt"
    bash "$GATE" --dir "$d/ula" > "${TM_TMP}/out" 2>&1 && _tm_afail "an IPv6 unique-local address passed"
    tm_assert_grep "IPv6 unique-local" "${TM_TMP}/out" "the ULA address was not named"
    P='fe80:'; printf 'gateway %s:1ff:fe23:4567:890a\n' "$P" > "$d/ll/a.txt"
    bash "$GATE" --dir "$d/ll" > "${TM_TMP}/out" 2>&1 && _tm_afail "an IPv6 link-local address passed"
    tm_assert_grep "link-local address" "${TM_TMP}/out" "the link-local address was not named"
    P='192.168'; printf 'ok \377\376 then %s.7.9\n' "$P" > "$d/bin/a.dat"
    bash "$GATE" --dir "$d/bin" > "${TM_TMP}/out" 2>&1 && _tm_afail "a tie inside a file that is not valid UTF-8 passed (it was skipped)"
    tm_assert_grep "a.dat:1: private address" "${TM_TMP}/out" "the non-UTF-8 file was not scanned"
}
tm_case "ipv6-private-and-non-utf8-ties-are-caught" none n_round8_blind_spots

n_flat_bundle() {
    local d="${TM_TMP}/flat"
    mkdir -p "$d/.work"
    printf '{}\n' > "$d/.work/WO-0001.json"; printf 'readme\n' > "$d/README.md"
    ( cd "$d" && tar czf "${TM_TMP}/flat.tgz" .work README.md ) || tm_die "could not build the flat bundle"
    bash "$GATE" --bundle "${TM_TMP}/flat.tgz" > "${TM_TMP}/out" 2>&1 \
        && _tm_afail "a FLAT bundle (no top-level directory) carrying .work/ passed"
    tm_assert_grep ".work/WO-0001.json: internal or process file" "${TM_TMP}/out" "the flat .work/ was not named"
}
tm_case "a-flat-bundle-carrying-work-is-refused" none n_flat_bundle

tm_finish
