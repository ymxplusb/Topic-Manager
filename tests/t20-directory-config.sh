#!/usr/bin/env bash
# =============================================================================
# t20 — NO BUILT-IN DIRECTORY, AND NO SILENT LOCK-OUT (v1.1.0).
#
# tm/auth.py used to fill auth.ldap_server, ldap_base_dn and ldap_domain from
# defaults that named one particular site's domain controller. v1.1.0 removes
# them. Because a host may have been relying on them without knowing, three
# things now have to hold, and each is driven here:
#
#   1. the application refuses clearly (names the key) instead of binding to a
#      directory nobody configured;
#   2. install.sh and the upgrade REFUSE to proceed over a config.yaml that
#      lacks them — the upgrade even under --force — rather than lock every
#      user out;
#   3. the three places that decide "is it configured" (tm/auth.py and one
#      byte-identical shell function in each script) give the same answer.
#
# Plus the other environment tie in the upgrade: the online source. There is
# no default repository; an online upgrade without one is refused up front.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "directory settings are required, and nobody is locked out silently"

UP="$(tm_upgrade_sh)"
INSTALL_SH="$(tm_install_sh)"
PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python found"

# ─── fixtures ────────────────────────────────────────────────────────────────
_fixtures() {
    local d="${TM_TMP}/fx"; mkdir -p "$d"
    printf 'auth:\n  ldap_server: "ldaps://dc1.example.org:636"\n  ldap_base_dn: "DC=example,DC=org"\n  ldap_domain: "example.org"\n' > "$d/complete.yaml"
    printf 'auth:\n  ldap_base_dn: "DC=example,DC=org"\n  ldap_domain: "example.org"\n' > "$d/no_server.yaml"
    printf 'auth:\n  ldap_server: "ldaps://dc1.example.org:636"\n  ldap_base_dn: "DC=example,DC=org"\n  ldap_domain: ""\n' > "$d/blank_domain.yaml"
    printf 'auth:\n  ldap_server: "ldaps://dc1.example.org:636"\n  ldap_base_dn: "<base-dn>"\n  ldap_domain: "example.org"\n' > "$d/placeholder.yaml"
    printf 'server:\n  host: 127.0.0.1\n' > "$d/no_auth.yaml"
    printf 'auth: "not a mapping"\n' > "$d/auth_scalar.yaml"
    cp "${TM_REPO_ROOT}/config/config.yaml.example" "$d/example.yaml"
    # Round 2 (sec-review): the scheme is PARSED. Plain ldap:// is refused, an
    # upper-case LDAPS:// is accepted, and a URL that merely CONTAINS "ldaps"
    # is refused — the old substring test accepted it.
    printf 'auth:\n  ldap_server: "ldap://dc1.example.org:389"\n  ldap_base_dn: "DC=example,DC=org"\n  ldap_domain: "example.org"\n' > "$d/plain_ldap.yaml"
    printf 'auth:\n  ldap_server: "LDAPS://DC1.example.org:636"\n  ldap_base_dn: "DC=example,DC=org"\n  ldap_domain: "example.org"\n' > "$d/upper_ldaps.yaml"
    printf 'auth:\n  ldap_server: "ldap://dc1.example.org/?ldaps"\n  ldap_base_dn: "DC=example,DC=org"\n  ldap_domain: "example.org"\n' > "$d/ldaps_substring.yaml"
}
FIXTURES="complete no_server blank_domain placeholder no_auth auth_scalar example plain_ldap upper_ldaps ldaps_substring"

_shell_answer() {   # _shell_answer <script> <config> -> the function's output
    {
        echo '#!/usr/bin/env bash'
        tm_extract_func "$1" ldap_config_missing
        echo 'ldap_config_missing "$1" "$2"'
    } > "${TM_TMP}/lk.sh"
    bash "${TM_TMP}/lk.sh" "$PY" "$2" 2>&1 | tr -d '\r'
}

d_identical() {
    tm_extract_func "$UP" ldap_config_missing > "${TM_TMP}/a"
    tm_extract_func "$INSTALL_SH" ldap_config_missing > "${TM_TMP}/b"
    cmp -s "${TM_TMP}/a" "${TM_TMP}/b" \
        || _tm_afail "install.sh and upgrade-full.sh carry different copies of ldap_config_missing"
}
tm_case "both-scripts-carry-the-same-check" none d_identical

d_shell_answers() {
    _fixtures
    local f got want s
    for s in "$UP" "$INSTALL_SH"; do
        for f in $FIXTURES; do
            got="$(_shell_answer "$s" "${TM_TMP}/fx/${f}.yaml")"
            case "$f" in
                complete|upper_ldaps) want="" ;;
                plain_ldap|ldaps_substring) want="ldap_server" ;;
                no_server)    want="ldap_server" ;;
                blank_domain) want="ldap_domain" ;;
                placeholder)  want="ldap_base_dn" ;;
                no_auth|auth_scalar|example) want="ldap_server ldap_base_dn ldap_domain" ;;
            esac
            tm_assert_eq "$want" "$got" "$(basename "$s"): ldap_config_missing on ${f}"
        done
    done
}
tm_case "the-shell-check-names-exactly-the-missing-keys" none d_shell_answers

d_app_agrees() {
    # tm/auth.py imports ldap3, so this needs the app's environment.
    _fixtures
    local out
    out="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 "$PY" - "${TM_TMP}/fx" $FIXTURES <<'PYEOF' 2>&1 | tr -d '\r'
import sys, yaml
from tm.auth import missing_ldap_keys
d = sys.argv[1]
for name in sys.argv[2:]:
    cfg = yaml.safe_load(open("%s/%s.yaml" % (d, name), encoding="utf-8"))
    print("%s=%s" % (name, " ".join(missing_ldap_keys(cfg if isinstance(cfg, dict) else {}))))
PYEOF
)"
    local f s
    for f in $FIXTURES; do
        s="$(_shell_answer "$UP" "${TM_TMP}/fx/${f}.yaml")"
        tm_assert_eq "${f}=${s}" "$(grep "^${f}=" <<<"$out" | sed -n 1p)" \
            "tm/auth.py and the scripts disagree about ${f}"
    done
}
tm_case "the-application-and-the-scripts-agree" tmapp d_app_agrees

d_refusal_is_clear() {
    local out
    out="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
from tm import auth
import ldap3
called = []
auth.Server = lambda *a, **k: called.append('server') or (_ for _ in ()).throw(AssertionError('reached LDAP'))
import io, logging
buf = io.StringIO(); logging.getLogger('tm.auth').addHandler(logging.StreamHandler(buf))
ok, msg = auth.validate_credentials({'auth': {'ldap_base_dn': 'DC=example,DC=org'}}, 'u', 'p')
print('ok=%s called=%d msg=%s' % (ok, len(called), msg))
print('log=%s' % buf.getvalue().replace(chr(10), ' '))
" 2>&1 | tr -d '\r')"
    # Round 2: the unauthenticated client gets a generic sentence; which key is
    # missing is for the administrator, in the server log.
    case "$out" in
        *"ok=False called=0 msg=Sign-in is unavailable. Contact the administrator."*) ;;
        *) _tm_afail "sign-in did not refuse with the generic message before touching LDAP: ${out}" ;;
    esac
    case "$(printf '%s\n' "$out" | grep '^ok=')" in
        *ldap_*) _tm_afail "the response to an unauthenticated client names config keys: ${out}" ;;
    esac
    case "$(printf '%s\n' "$out" | grep '^log=')" in
        *"auth.ldap_server"*"auth.ldap_domain"*) ;;
        *) _tm_afail "the server log does not name the missing keys for the administrator: ${out}" ;;
    esac
}
tm_case "sign-in-refuses-generically-and-logs-the-keys" tmapp d_refusal_is_clear

d_no_defaults_in_source() {
    "$PY" - "${TM_REPO_ROOT}/tm/auth.py" <<'PYEOF' > "${TM_TMP}/ast" 2>&1
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
bad = []
for n in ast.walk(tree):
    if (isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "get" and len(n.args) >= 2
            and isinstance(n.args[0], ast.Constant)
            and n.args[0].value in ("ldap_server", "ldap_base_dn", "ldap_domain")
            # A blank default is a guard, not a directory. Any other constant is one.
            and not (isinstance(n.args[1], ast.Constant) and n.args[1].value in ("", None))):
        bad.append("%s default at line %d" % (n.args[0].value, n.lineno))
print("BAD " + "; ".join(bad) if bad else "OK")
PYEOF
    grep -q '^OK$' "${TM_TMP}/ast" \
        || _tm_afail "tm/auth.py supplies a default for a directory key again: $(cat "${TM_TMP}/ast")"
}
tm_case "auth-py-has-no-directory-defaults" none d_no_defaults_in_source

# ─── the scripts refuse ──────────────────────────────────────────────────────
# _block_from <file> <start-ere> — from the (unique) start line to the first
# column-0 `fi` after it. `fi` occurs dozens of times in the file, so it cannot
# be a tm_extract_between end anchor; the start anchor is still counted.
_block_from() {
    tm_require_anchor "$1" "$2" "block start /$2/"
    TM_S="$2" awk 'BEGIN { s = ENVIRON["TM_S"] } !on && $0 ~ s { on = 1 } on { print } on && /^fi$/ { exit }' "$1"
}
# Round 2 (adversary F3): BEFORE ANY MUTATION, not merely before the code
# copy — it used to run after apt, the venv and pip while claiming "nothing
# was changed". Every mutating step's first line must come after the check.
d_install_checks_before_any_change() {
    local check first=999999 n pat
    check="$(grep -n 'LDAP_MISSING="$(ldap_config_missing' "$INSTALL_SH" | sed -n 1p | cut -d: -f1)"
    tm_assert_nonempty "$check" "install.sh no longer checks an existing config.yaml for the directory keys"
    for pat in '^    DEBIAN_FRONTEND=noninteractive apt-get update' '^    apt_install_from_bundle ' \
               '^    useradd ' '^safe_install_dir ' '^"\$PYTHON" -m venv' '^rsync -a --delete' \
               '^    systemctl stop '; do
        n="$(grep -nE "$pat" "$INSTALL_SH" | sed -n 1p | cut -d: -f1)"
        tm_assert_nonempty "$n" "anchor for a mutating step not found: ${pat}"
        [ "$n" -lt "$first" ] && first="$n"
    done
    [ "$check" -lt "$first" ] || _tm_afail "install.sh checks the directory keys at line ${check}, AFTER
        the first change to the host at line ${first} — its 'Nothing has been changed' would be false"
}
tm_case "install-checks-the-config-before-any-change" none d_install_checks_before_any_change

# Behavioural: the REAL install.sh block that guards a reinstall, run against
# a config that relied on the old defaults and against one that did not.
d_install_refuses_behaviourally() {
    _fixtures
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'die() { echo "[FAIL] $*" >&2; exit 1; }; success() { echo "[OK] $*"; }'
        echo 'NEW_CONFIG=false; CONFIG_FILE="$1"; VENV="$2"'
        tm_extract_func "$INSTALL_SH" ldap_config_missing
        _block_from "$INSTALL_SH" '^# ─── an existing config.yaml must name its directory'
        echo 'echo CONTINUED'
    } > "${TM_TMP}/ir.sh"
    # A fake venv whose bin/python3 is the test interpreter.
    mkdir -p "${TM_TMP}/venv/bin"
    printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$PY" > "${TM_TMP}/venv/bin/python3"
    chmod +x "${TM_TMP}/venv/bin/python3"
    local rc=0
    bash "${TM_TMP}/ir.sh" "${TM_TMP}/fx/no_server.yaml" "${TM_TMP}/venv" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "install.sh carried on over a config.yaml with no ldap_server"
    tm_assert_nogrep "CONTINUED" "${TM_TMP}/out" "install.sh went past the check"
    tm_assert_grep "ldap_server" "${TM_TMP}/out" "the refusal does not name the missing key"
    rc=0
    bash "${TM_TMP}/ir.sh" "${TM_TMP}/fx/complete.yaml" "${TM_TMP}/venv" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_eq 0 "$rc" "install.sh refused a complete config: $(cat "${TM_TMP}/out")"
}
tm_case "install-refuses-a-config-without-the-keys" none d_install_refuses_behaviourally

d_binary_wheels_only() {
    [ "$(grep -c -- '--only-binary :all:' "$INSTALL_SH")" -ge 2 ] \
        || _tm_afail "install.sh no longer installs binary wheels only (online AND offline)"
    grep -nE 'build-essential|python3-dev|libssl-dev|libffi-dev' "$INSTALL_SH" "$PREP_SH" \
        | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' > "${TM_TMP}/tc" \
        && _tm_afail "a compiler toolchain is back in the install path: $(cat "${TM_TMP}/tc")" || true
}
PREP_SH="${TM_REPO_ROOT}/prepare-offline.sh"
tm_case "install-uses-binary-wheels-and-no-toolchain" none d_binary_wheels_only

d_upgrade_gate_ignores_force() {
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'FORCE=true; AUDIT_BLOCK=1; CONFIG_FILE=/x; BACKUP_DIR=/y'
        echo 'LDAP_KEYS_HARD_BLOCK="$1"; LDAP_KEYS_MISSING="ldap_server"'
        # Anchored on the comment ABOVE the if, so a mutation of the if line is
        # tested rather than breaking its own extraction.
        _block_from "$UP" '^# First the one blocker --force cannot override'
        echo 'echo PROCEEDED'
    } > "${TM_TMP}/g.sh"
    local rc=0
    bash "${TM_TMP}/g.sh" true > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "the upgrade proceeded over missing directory keys because --force was given"
    tm_assert_nogrep "PROCEEDED" "${TM_TMP}/out" "the upgrade went past the gate"
    tm_assert_grep "does not override" "${TM_TMP}/out" "the refusal does not say --force cannot override it"
    rc=0; bash "${TM_TMP}/g.sh" false > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_eq 0 "$rc" "the gate refused a host whose directory keys are fine"
}
tm_case "upgrade-refuses-missing-keys-even-with-force" none d_upgrade_gate_ignores_force

d_upgrade_phase3_blocks() {
    grep -qE '^LDAP_KEYS_MISSING="\$\(ldap_config_missing "\$CFG_PY_BIN" "\$CONFIG_FILE"' "$UP" \
        || _tm_afail "Phase 3 no longer checks config.yaml for the directory keys"
}
tm_case "upgrade-audit-reports-missing-keys" none d_upgrade_phase3_blocks

# ─── the online source ───────────────────────────────────────────────────────
_src_block() {
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }; info() { echo "[INFO] $*"; }'
        echo 'ONLINE=true; REPO_URL="$1"; REPO_BRANCH="${2:-main}"'
        echo 'AUDIT_ONLY="${3:-false}"; DRY_RUN=false; BACKUP_ONLY=false'
        echo 'REPO_COMMIT="${4-0123456789abcdef0123456789abcdef01234567}"'
        _block_from "$UP" '^# An online run needs to be told where the release source lives'
        echo 'echo CONTINUED'
    } > "${TM_TMP}/src.sh"
}
r_no_default_source() {
    grep -qx 'REPO_URL="${TM_REPO_URL:-}"' "$UP" \
        || _tm_afail "REPO_URL is not operator-supplied-only (TM_REPO_URL, no default)"
    grep -nE '^[^#]*(github\.com|gitlab\.[a-z]|git\.int\.)' "$UP" > "${TM_TMP}/hits" \
        && _tm_afail "upgrade-full.sh names a repository host: $(cat "${TM_TMP}/hits")" || true
}
tm_case "the-upgrade-names-no-source-repository" none r_no_default_source

r_online_needs_a_url() {
    _src_block
    local rc=0
    bash "${TM_TMP}/src.sh" "" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "an online upgrade with no source URL carried on"
    tm_assert_grep "--repo-url" "${TM_TMP}/out" "the refusal does not tell the operator how to supply a URL"
    tm_assert_grep "--offline" "${TM_TMP}/out" "the refusal does not offer the offline bundle"
    rc=0; bash "${TM_TMP}/src.sh" "" main true > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_eq 0 "$rc" "--audit-only was refused for lacking a URL it never uses"
    rc=0; bash "${TM_TMP}/src.sh" "https://git.example.org/team/topic-manager.git" v1.1.0 > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_eq 0 "$rc" "a well-formed https URL was refused: $(cat "${TM_TMP}/out")"
    rc=0; bash "${TM_TMP}/src.sh" "--upload-pack=touch /tmp/x" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "an option-shaped URL was accepted and would reach git clone"
    rc=0; bash "${TM_TMP}/src.sh" "https://git.example.org/x.git" "--help" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "an option-shaped branch was accepted"
}
tm_case "an-online-upgrade-without-a-source-is-refused" none r_online_needs_a_url

# Round 2 (sec-review HIGH): a URL alone is a movable ref run as root.
r_url_needs_a_commit() {
    _src_block
    local rc=0 u="https://git.example.org/team/topic-manager.git"
    bash "${TM_TMP}/src.sh" "$u" v1.1.0 false "" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "--repo-url without --repo-commit was accepted"
    tm_assert_grep "--repo-commit" "${TM_TMP}/out" "the refusal does not name --repo-commit"
    rc=0; bash "${TM_TMP}/src.sh" "$u" v1.1.0 false "0123abc" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "a short commit id was accepted"
    rc=0; bash "${TM_TMP}/src.sh" "$u" v1.1.0 false "0123456789ABCDEF0123456789abcdef01234567" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "a non-lower-case-hex commit id was accepted"
}
tm_case "a-repo-url-requires-a-40-hex-commit" none r_url_needs_a_commit

r_clone_is_verified_and_hardened() {
    command -v git >/dev/null 2>&1 || tm_die "git is required"
    local r="${TM_TMP}/repo" rc head
    mkdir -p "$r" && git -C "$r" init -q && printf 'x\n' > "$r/f" \
        && git -C "$r" add f && git -C "$r" -c user.name=t -c user.email=t@example.org commit -qm one \
        || tm_die "could not build a scratch repository"
    head="$(git -C "$r" rev-parse HEAD)"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }; info() { echo "[INFO] $*"; }'
        tm_extract_func "$UP" verify_clone_commit
        echo 'verify_clone_commit "$1" "$2"; echo VERIFIED'
    } > "${TM_TMP}/v.sh"
    rc=0; bash "${TM_TMP}/v.sh" "$r" "$head" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_eq 0 "$rc" "the exact commit was not accepted: $(cat "${TM_TMP}/out")"
    rc=0; bash "${TM_TMP}/v.sh" "$r" "0123456789abcdef0123456789abcdef01234567" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "a clone whose HEAD is NOT the named commit was accepted"
    rc=0; bash "${TM_TMP}/v.sh" "${TM_TMP}/not-a-repo" "0123456789abcdef0123456789abcdef01234567" > "${TM_TMP}/out" 2>&1 || rc=$?
    tm_assert_ne 0 "$rc" "a failed rev-parse compared equal"
    # The clone line itself, and its order against the first read of the tree.
    local clone verify readv
    clone="$(grep -n 'clone --depth 1 --branch "$REPO_BRANCH" --quiet -- "$REPO_URL" "$WORK_DIR"' "$UP" | cut -d: -f1)"
    verify="$(grep -n '^    verify_clone_commit "$WORK_DIR" "$REPO_COMMIT"' "$UP" | cut -d: -f1)"
    readv="$(grep -n '^TARGET_VERSION="$(cat "${WORK_DIR}/tm/VERSION"' "$UP" | cut -d: -f1)"
    tm_assert_nonempty "$clone" "the hardened clone line is gone"
    tm_assert_nonempty "$verify" "the clone is no longer verified against --repo-commit"
    [ "$clone" -lt "$verify" ] && [ "$verify" -lt "$readv" ] \
        || _tm_afail "the commit check does not sit between the clone and the first read of the tree"
    local opt
    for opt in 'http.sslVerify=true' 'protocol.file.allow=never' 'GIT_TERMINAL_PROMPT=0' 'StrictHostKeyChecking=yes'; do
        grep -q -- "$opt" "$UP" || _tm_afail "the clone is no longer hardened with ${opt}"
    done
}
tm_case "the-clone-is-hardened-and-pinned-before-any-read" none r_clone_is_verified_and_hardened

# ─── install.sh writes a complete, neutral config ────────────────────────────
c_config_written() {
    # The body starts after the command line that opens it, and that line is
    # continued with backslashes, so skip to the end of the continuation.
    awk '/<<.PYCFG./ { p = 1; if ($0 !~ /\\$/) on = 1; next }
         p && !on    { if ($0 !~ /\\$/) on = 1; next }
         on && /^PYCFG$/ { exit }
         on { print }' "$INSTALL_SH" > "${TM_TMP}/pycfg.py"
    [ -s "${TM_TMP}/pycfg.py" ] || tm_die "could not extract the PYCFG heredoc from install.sh"
    cp "${TM_REPO_ROOT}/config/config.yaml.example" "${TM_TMP}/config.yaml"
    local n; n="$(cygpath -m "${TM_TMP}/config.yaml" 2>/dev/null || printf '%s' "${TM_TMP}/config.yaml")"
    TM_I_LDAP_SERVER="ldaps://dc1.example.org:636" TM_I_LDAP_BASE_DN="OU=People,DC=example,DC=org" \
    TM_I_LDAP_DOMAIN="example.org" TM_I_REQUIRED_GROUP='CN=Kafka "Ops" Admins,OU=Groups,DC=example,DC=org' \
    TM_I_LDAP_BIND_DN="" TM_I_LDAP_CA_CERT="" TM_I_LDAP_BIND_PW="" \
        "$PY" "${TM_TMP}/pycfg.py" "$n" > "${TM_TMP}/out" 2>&1 \
        || _tm_afail "the config writer failed: $(cat "${TM_TMP}/out")"
    local got
    got="$(_shell_answer "$INSTALL_SH" "${TM_TMP}/config.yaml")"
    tm_assert_eq "" "$got" "the written config.yaml still lacks directory keys: ${got}"
    "$PY" - "$n" <<'PYEOF' > "${TM_TMP}/chk" 2>&1
import re, sys, yaml
text = open(sys.argv[1], encoding="utf-8").read()
c = yaml.safe_load(text)
a = c["auth"]
print("group=%s" % a["required_group"])
print("secret_ok=%s" % bool(re.fullmatch(r"[0-9a-f]{64}", c["server"]["secret_key"])))
print("placeholders=%d" % len(re.findall(r'"<[^">]*>"', text)))
print("comments_kept=%s" % ("There are NO built-in" in text))
PYEOF
    tm_assert_grep 'group=CN=Kafka "Ops" Admins,OU=Groups,DC=example,DC=org' "${TM_TMP}/chk" \
        "a DN with quotes did not survive into config.yaml intact"
    tm_assert_grep "secret_ok=True" "${TM_TMP}/chk" "no fresh 64-hex secret key was written"
    tm_assert_grep "placeholders=0" "${TM_TMP}/chk" "a <placeholder> survived into the written config"
    tm_assert_grep "comments_kept=True" "${TM_TMP}/chk" "the operator-facing comments were lost"
}
tm_case "install-writes-a-complete-neutral-config" none c_config_written

tm_finish
