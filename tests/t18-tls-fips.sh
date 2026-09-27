#!/usr/bin/env bash
# =============================================================================
# t18 — TLS POLICY AND FIPS (v1.1.0).
#
# Owner decisions, 2026-09-26:
#   * nginx.conf's http-level ssl_protocols reads TLSv1.2 TLSv1.3 only, managed
#     by install.sh AND the upgrade: backed up, nginx -t'd, rolled back.
#   * the site gets a FIPS-approved cipher list, ssl_session_timeout 15m,
#     ssl_session_tickets off, server_tokens off; every location keeps the
#     security-header include (hazards[nginx-add-header-inheritance]).
#   * the cert/key pair check is key-type agnostic and compares RAW values
#     (the old `openssl rsa -modulus` broke on EC keys).
#   * the Flask session cookie is signed with SHA-256, not Flask's SHA-1.
#
# The nginx.conf cases drive the REAL manage_nginx_ssl_protocols extracted
# from BOTH scripts against a scratch nginx.conf, with a stub `nginx` first on
# PATH whose `-t` verdict each case chooses. No real nginx is touched.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "TLS 1.2/1.3 only, FIPS cipher list, raw key-pair check, SHA-256 cookies"

UP="$(tm_upgrade_sh)"
INSTALL_SH="$(tm_install_sh)"
SITE="${TM_REPO_ROOT}/nginx/topic-manager.conf"
PY="$(tm_python)"

# ─── the site config ─────────────────────────────────────────────────────────
s_policy() {
    grep -Eq '^[[:space:]]*ssl_protocols[[:space:]]+TLSv1\.2 TLSv1\.3;$' "$SITE" \
        || _tm_afail "the site does not set ssl_protocols TLSv1.2 TLSv1.3"
    local ciphers c bad=""
    ciphers="$(grep -E '^[[:space:]]*ssl_ciphers[[:space:]]' "$SITE" | sed -E 's/^[[:space:]]*ssl_ciphers[[:space:]]+//; s/;.*$//')"
    tm_assert_nonempty "$ciphers" "the site sets no ssl_ciphers"
    for c in ${ciphers//:/ }; do
        [[ "$c" =~ ^ECDHE-(ECDSA|RSA)-AES(128|256)-GCM-SHA(256|384)$ ]] || bad="${bad} ${c}"
    done
    [ -z "$bad" ] || _tm_afail "cipher(s) outside the FIPS policy (ECDHE + AES-GCM + SHA-256/384):${bad}"
    grep -Eq 'Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;' "$SITE" \
        || _tm_afail "the TLS 1.3 suites are not pinned to AES-GCM (ChaCha20 would be offered on a non-FIPS host)"
    grep -Eq '^[[:space:]]*ssl_ecdh_curve[[:space:]]+secp384r1:prime256v1;' "$SITE" \
        || _tm_afail "the ECDHE curves are not restricted to P-384/P-256"
    grep -Eq '^[[:space:]]*ssl_session_tickets[[:space:]]+off;' "$SITE" || _tm_afail "ssl_session_tickets is not off"
    grep -Eq '^[[:space:]]*ssl_session_timeout[[:space:]]+15m;' "$SITE" || _tm_afail "ssl_session_timeout is not 15m"
    # v1.2.0: the :80 server block is its own site (nginx/topic-manager-http.conf,
    # switched by Settings), so "both server blocks" are now one per file.
    grep -Eq '^[[:space:]]*server_tokens[[:space:]]+off;' "$SITE" \
        || _tm_afail "server_tokens off is not set in the HTTPS server block"
    grep -Eq '^[[:space:]]*server_tokens[[:space:]]+off;' "${TM_REPO_ROOT}/nginx/topic-manager-http.conf" \
        || _tm_afail "server_tokens off is not set in the :80 redirect server block"
}
tm_case "site-config-carries-the-fips-tls-policy" none s_policy

s_headers_everywhere() {
    # Every location block must include the header snippet: nginx drops ALL
    # inherited add_header lines the moment a location sets its own.
    local out
    out="$(awk '
        /^[[:space:]]*location[[:space:]]/ { inloc = 1; name = $0; has = 0; depth = 0 }
        inloc {
            n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); depth += n - m
            if ($0 ~ /include[[:space:]]+\/etc\/nginx\/snippets\/tm-security-headers\.conf;/) has = 1
            if (depth == 0 && m > 0) { if (!has) print "MISSING " name; inloc = 0 }
        }' "$SITE")"
    [ -z "$out" ] || _tm_afail "a location does not include the security headers: ${out}"
    [ "$(grep -Ec '^[[:space:]]*location[[:space:]]' "$SITE")" -ge 3 ] \
        || _tm_afail "expected at least three location blocks; the parser saw fewer"
}
tm_case "every-location-includes-the-security-headers" none s_headers_everywhere

# ─── manage_nginx_ssl_protocols, from both scripts ───────────────────────────
m_identical() {
    local f
    for f in manage_nginx_ssl_protocols tls_keypair_matches; do
        tm_extract_func "$UP" "$f" > "${TM_TMP}/a"
        tm_extract_func "$INSTALL_SH" "$f" > "${TM_TMP}/b"
        cmp -s "${TM_TMP}/a" "${TM_TMP}/b" \
            || _tm_afail "install.sh and upgrade-full.sh carry different copies of ${f}"
    done
}
tm_case "both-scripts-carry-the-same-tls-functions" none m_identical

# _harness <script> — the real function plus a stub nginx whose verdict is set
# by NGINX_STUB: pass | fail | fail-if-edited.
_harness() {
    mkdir -p "${TM_TMP}/bin"
    cat > "${TM_TMP}/bin/nginx" <<'STUB'
#!/usr/bin/env bash
case "${NGINX_STUB:-pass}" in
    pass) echo "nginx: configuration file test is successful"; exit 0 ;;
    fail) echo "nginx: [emerg] stubbed failure"; exit 1 ;;
    fail-if-edited)
        grep -q 'managed by Topic Manager' "$NGINX_STUB_CONF" \
            && { echo "nginx: [emerg] stubbed failure on the edit"; exit 1; }
        exit 0 ;;
esac
STUB
    chmod +x "${TM_TMP}/bin/nginx"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo 'fail() { echo "[FAIL] $*" >&2; exit 1; }'
        echo 'info() { echo "[INFO] $*"; }'
        tm_extract_func "$1" manage_nginx_ssl_protocols
        echo 'manage_nginx_ssl_protocols "$1" "$2"'
    } > "${TM_TMP}/m.sh"
}
_run() {   # _run <script> <verdict> ; conf at ${TM_TMP}/nginx.conf
    _harness "$1"
    RC=0
    PATH="${TM_TMP}/bin:${PATH}" NGINX_STUB="$2" NGINX_STUB_CONF="${TM_TMP}/nginx.conf" \
        bash "${TM_TMP}/m.sh" "${TM_TMP}/nginx.conf" "${TM_TMP}/nginx.conf.bak" \
        > "${TM_TMP}/out" 2>&1 || RC=$?
}
_stock() {   # the shape of stock Ubuntu 24.04 nginx.conf, reduced
    cat > "${TM_TMP}/nginx.conf" <<'CONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
	worker_connections 768;
}

http {
	sendfile on;
	##
	# SSL Settings
	##

	ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3; # Dropping SSLv3, ref: POODLE
	ssl_prefer_server_ciphers on;
	# ssl_protocols TLSv1;
	include /etc/nginx/conf.d/*.conf;
	include /etc/nginx/sites-enabled/*;
}
CONF
    cp "${TM_TMP}/nginx.conf" "${TM_TMP}/orig.conf"
}

m_rewrites_stock() {
    local s
    for s in "$UP" "$INSTALL_SH"; do
        _stock; rm -f "${TM_TMP}/nginx.conf.bak"
        _run "$s" pass
        tm_assert_rc 0 "$RC" "$(basename "$s"): the edit failed: $(cat "${TM_TMP}/out")"
        grep -Eq '^[[:space:]]*ssl_protocols TLSv1\.2 TLSv1\.3; # managed by Topic Manager' "${TM_TMP}/nginx.conf" \
            || _tm_afail "$(basename "$s"): ssl_protocols was not rewritten: $(grep ssl_protocols "${TM_TMP}/nginx.conf")"
        grep -Eq 'TLSv1([^.]|$)|TLSv1\.1' <<<"$(grep -E '^[[:space:]]*ssl_protocols' "${TM_TMP}/nginx.conf")" \
            && _tm_afail "$(basename "$s"): TLSv1/TLSv1.1 is still enabled at the http level"
        tm_assert_grep "# ssl_protocols TLSv1;" "${TM_TMP}/nginx.conf" "$(basename "$s"): a COMMENTED line was rewritten"
        cmp -s "${TM_TMP}/orig.conf" "${TM_TMP}/nginx.conf.bak" \
            || _tm_afail "$(basename "$s"): the backup is not the original nginx.conf"
    done
}
tm_case "stock-nginx-conf-loses-tls1.0-and-1.1-and-is-backed-up" none m_rewrites_stock

# Round 2 (sec-review #17): NEVER WIDEN an operator's stricter policy.
m_never_widens() {
    local s
    for s in "$UP" "$INSTALL_SH"; do
        printf 'http {\n\tssl_protocols TLSv1.3;\n}\n' > "${TM_TMP}/nginx.conf"
        _run "$s" pass
        tm_assert_rc 0 "$RC" "$(basename "$s"): $(cat "${TM_TMP}/out")"
        grep -Eq '^[[:space:]]*ssl_protocols TLSv1\.3; # managed' "${TM_TMP}/nginx.conf" \
            || _tm_afail "$(basename "$s"): a TLSv1.3-only policy was WIDENED: $(grep ssl_protocols "${TM_TMP}/nginx.conf")"
        printf 'http {\n\tssl_protocols TLSv1 TLSv1.3;\n}\n' > "${TM_TMP}/nginx.conf"
        _run "$s" pass
        grep -Eq '^[[:space:]]*ssl_protocols TLSv1\.3; # managed' "${TM_TMP}/nginx.conf" \
            || _tm_afail "$(basename "$s"): 'TLSv1 TLSv1.3' should become 'TLSv1.3', got: $(grep ssl_protocols "${TM_TMP}/nginx.conf")"
        printf 'http {\n\tssl_protocols TLSv1 TLSv1.1;\n}\n' > "${TM_TMP}/nginx.conf"
        _run "$s" pass
        grep -Eq '^[[:space:]]*ssl_protocols TLSv1\.2 TLSv1\.3; # managed' "${TM_TMP}/nginx.conf" \
            || _tm_afail "$(basename "$s"): a line with nothing approved did not become TLSv1.2 TLSv1.3"
    done
}
tm_case "a-stricter-operator-policy-is-never-widened" none m_never_widens

# Round 2 (adversary F2): a directive sharing the ssl_protocols line would be
# deleted by a whole-line rewrite, so such a line is refused, untouched.
m_refuses_shared_line() {
    local s c
    for s in "$UP" "$INSTALL_SH"; do
        for c in 'ssl_protocols TLSv1 TLSv1.2; ssl_prefer_server_ciphers on;' \
                 'ssl_session_timeout 5m; ssl_protocols TLSv1 TLSv1.2;'; do
            printf 'http {\n\t%s\n}\n' "$c" > "${TM_TMP}/nginx.conf"
            cp "${TM_TMP}/nginx.conf" "${TM_TMP}/orig.conf"
            _run "$s" pass
            tm_assert_ne 0 "$RC" "$(basename "$s"): rewrote a line holding two directives: ${c}"
            cmp -s "${TM_TMP}/orig.conf" "${TM_TMP}/nginx.conf" \
                || _tm_afail "$(basename "$s"): the shared line was changed; the other directive may be gone"
            tm_assert_grep "sharing its line" "${TM_TMP}/out" "$(basename "$s"): the refusal did not say why"
        done
        # A trailing COMMENT is not a directive and is still accepted.
        printf 'http {\n\tssl_protocols TLSv1 TLSv1.2; # old note\n}\n' > "${TM_TMP}/nginx.conf"
        _run "$s" pass
        tm_assert_rc 0 "$RC" "$(basename "$s"): a trailing comment was treated as a second directive"
    done
}
tm_case "a-line-with-two-directives-is-refused-untouched" none m_refuses_shared_line

m_inserts_when_absent() {
    local s
    for s in "$UP" "$INSTALL_SH"; do
        printf 'events {}\nhttp {\n\tinclude /etc/nginx/sites-enabled/*;\n}\n' > "${TM_TMP}/nginx.conf"
        _run "$s" pass
        tm_assert_rc 0 "$RC" "$(basename "$s"): $(cat "${TM_TMP}/out")"
        [ "$(grep -A1 '^http {' "${TM_TMP}/nginx.conf" | tail -1 | grep -c 'ssl_protocols TLSv1.2 TLSv1.3;')" = 1 ] \
            || _tm_afail "$(basename "$s"): no ssl_protocols line was added at the top of http {: $(cat "${TM_TMP}/nginx.conf")"
    done
}
tm_case "missing-ssl-protocols-is-added-inside-http" none m_inserts_when_absent

m_rolls_back_its_own_failure() {
    local s
    for s in "$UP" "$INSTALL_SH"; do
        _stock
        _run "$s" fail-if-edited
        tm_assert_ne 0 "$RC" "$(basename "$s"): nginx -t failed on the edit and the function reported success"
        cmp -s "${TM_TMP}/orig.conf" "${TM_TMP}/nginx.conf" \
            || _tm_afail "$(basename "$s"): nginx -t failed and nginx.conf was NOT put back — a
        config nginx cannot load is left in place for the next reload"
        tm_assert_grep "was put back" "${TM_TMP}/out" "$(basename "$s"): the failure did not say the original was restored"
    done
}
tm_case "a-failed-nginx-test-puts-the-original-back" none m_rolls_back_its_own_failure

m_says_when_failure_is_elsewhere() {
    local s
    for s in "$UP" "$INSTALL_SH"; do
        _stock
        _run "$s" fail
        tm_assert_ne 0 "$RC" "$(basename "$s"): reported success over a failing nginx -t"
        cmp -s "${TM_TMP}/orig.conf" "${TM_TMP}/nginx.conf" || _tm_afail "$(basename "$s"): original not restored"
        tm_assert_grep "with OR without" "${TM_TMP}/out" \
            "$(basename "$s"): did not tell the operator the failure was not this edit"
    done
}
tm_case "a-pre-existing-nginx-failure-is-named-as-such" none m_says_when_failure_is_elsewhere

m_refuses_multiline() {
    local s
    for s in "$UP" "$INSTALL_SH"; do
        printf 'http {\n\tssl_protocols TLSv1\n\t\tTLSv1.2;\n}\n' > "${TM_TMP}/nginx.conf"
        cp "${TM_TMP}/nginx.conf" "${TM_TMP}/orig.conf"
        _run "$s" pass
        tm_assert_ne 0 "$RC" "$(basename "$s"): rewrote a directive it cannot parse"
        cmp -s "${TM_TMP}/orig.conf" "${TM_TMP}/nginx.conf" || _tm_afail "$(basename "$s"): touched the file anyway"
    done
}
tm_case "an-unparseable-directive-is-refused-untouched" none m_refuses_multiline

m_refuses_symlink() {
    local s
    for s in "$UP" "$INSTALL_SH"; do
        _stock; mv "${TM_TMP}/nginx.conf" "${TM_TMP}/real.conf"
        ln -s "${TM_TMP}/real.conf" "${TM_TMP}/nginx.conf"
        _run "$s" pass
        tm_assert_ne 0 "$RC" "$(basename "$s"): edited nginx.conf through a symlink"
        cmp -s "${TM_TMP}/orig.conf" "${TM_TMP}/real.conf" || _tm_afail "$(basename "$s"): the link target was changed"
        rm -f "${TM_TMP}/nginx.conf"
    done
}
tm_case "nginx-conf-is-never-edited-through-a-symlink" symlinks m_refuses_symlink

m_wired_in() {
    grep -qE '^manage_nginx_ssl_protocols /etc/nginx/nginx.conf ' "$UP" \
        || _tm_afail "the upgrade no longer manages nginx.conf's ssl_protocols"
    grep -qF 'cp -a /etc/nginx/nginx.conf "${BACKUP_DIR}/system/nginx.conf"' "$UP" \
        || _tm_afail "the upgrade's restore point does not hold nginx.conf, which it now edits"
    grep -qF '"${BD}/system/nginx.conf" /etc/nginx/nginx.conf' <<<"$(tm_extract_func "$UP" restore_from_backup)" \
        || _tm_afail "restore_from_backup does not put nginx.conf back"
    grep -qE '^manage_nginx_ssl_protocols /etc/nginx/nginx.conf ' "$INSTALL_SH" \
        || _tm_afail "install.sh does not manage nginx.conf's ssl_protocols"
}
tm_case "both-scripts-call-it-and-the-upgrade-can-undo-it" none m_wired_in

# ─── the key-pair check ──────────────────────────────────────────────────────
_kp() {   # _kp <script> <crt> <key> -> exit status of the REAL function
    {
        echo '#!/usr/bin/env bash'
        tm_extract_func "$1" tls_keypair_matches
        echo 'tls_keypair_matches "$1" "$2"'
    } > "${TM_TMP}/kp.sh"
    bash "${TM_TMP}/kp.sh" "$2" "$3" >/dev/null 2>&1
}
_mkpair() {   # _mkpair <name> <ec|rsa>
    local alg
    [ "$2" = ec ] && alg="-newkey ec -pkeyopt ec_paramgen_curve:P-256" || alg="-newkey rsa:2048"
    # Git Bash: -subj must not be path-converted, so conversion is off and the
    # file paths are handed over in native form instead.
    local d; d="$(cygpath -m "$TM_TMP" 2>/dev/null || printf '%s' "$TM_TMP")"
    MSYS_NO_PATHCONV=1 openssl req -x509 $alg -sha256 -nodes -days 2 -subj "/CN=t18" \
        -keyout "${d}/$1.key" -out "${d}/$1.crt" >/dev/null 2>&1 \
        || tm_die "openssl could not make a test key pair"
}
k_pairs() {
    command -v openssl >/dev/null 2>&1 || tm_die "openssl is required for the key-pair cases"
    _mkpair ec1 ec; _mkpair ec2 ec; _mkpair rsa1 rsa
    : > "${TM_TMP}/empty.key"; printf 'garbage\n' > "${TM_TMP}/garbage.crt"
    local s
    for s in "$UP" "$INSTALL_SH"; do
        _kp "$s" "${TM_TMP}/ec1.crt" "${TM_TMP}/ec1.key" \
            || _tm_afail "$(basename "$s"): an EC certificate and its own key were not recognised as a pair (the old -modulus defect)"
        _kp "$s" "${TM_TMP}/rsa1.crt" "${TM_TMP}/rsa1.key" \
            || _tm_afail "$(basename "$s"): an RSA pair was not recognised"
        _kp "$s" "${TM_TMP}/ec1.crt" "${TM_TMP}/ec2.key" \
            && _tm_afail "$(basename "$s"): two DIFFERENT EC keys were reported as a pair"
        _kp "$s" "${TM_TMP}/rsa1.crt" "${TM_TMP}/ec1.key" \
            && _tm_afail "$(basename "$s"): an RSA cert and an EC key were reported as a pair"
        _kp "$s" "${TM_TMP}/garbage.crt" "${TM_TMP}/empty.key" \
            && _tm_afail "$(basename "$s"): two unreadable inputs compared EQUAL — the empty-output trap"
    done
    return 0
}
tm_case "key-pair-check-is-key-type-agnostic-and-raw" none k_pairs

k_no_modulus() {
    grep -nE '^[^#]*openssl rsa ' "$UP" "$INSTALL_SH" > "${TM_TMP}/rsa" 2>/dev/null \
        && _tm_afail "an RSA-only openssl call is still in the install path: $(cat "${TM_TMP}/rsa")" || true
    grep -qE 'tls_keypair_matches "\$\{CONFIG_DIR\}/tls/server.crt" "\$\{CONFIG_DIR\}/tls/server.key"' "$UP" \
        || _tm_afail "the upgrade's restored-cert check no longer uses tls_keypair_matches"
    grep -q 'ec_paramgen_curve:P-256' "$INSTALL_SH" \
        || _tm_afail "install.sh's self-signed placeholder is not ECDSA P-256"
}
tm_case "no-rsa-only-checks-remain-and-install-generates-ec" none k_no_modulus

# ─── the session cookie digest ───────────────────────────────────────────────
f_cookie() {
    local out
    out="$(PYTHONPATH="$TM_REPO_ROOT" PYTHONDONTWRITEBYTECODE=1 "$PY" -c "
import hashlib
from flask import Flask, session
from flask.sessions import SecureCookieSessionInterface
import tm.app as a
def sig_len(iface):
    app = Flask('t'); app.secret_key = 'k' * 64; app.session_interface = iface
    @app.route('/')
    def r():
        session['sid'] = 'x'; return 'ok'
    c = app.test_client(); resp = c.get('/')
    cookie = resp.headers['Set-Cookie'].split(';')[0].split('=', 1)[1]
    return len(cookie.rsplit('.', 1)[1])
print('digest=%s' % (a.Sha256SessionInterface.digest_method is hashlib.sha256))
print('ours=%d default=%d' % (sig_len(a.Sha256SessionInterface()), sig_len(SecureCookieSessionInterface())))
src = open(a.__file__, encoding='utf-8').read()
print('wired=%s' % ('app.session_interface = Sha256SessionInterface()' in src))
" 2>&1 | tr -d '\r')"
    case "$out" in *"digest=True"*) ;; *) _tm_afail "the session interface does not use hashlib.sha256: ${out}" ;; esac
    # HMAC-SHA-256 is 32 bytes -> 43 base64url chars; SHA-1 is 20 -> 27.
    case "$out" in *"ours=43 default=27"*) ;; *) _tm_afail "the cookie signature is not SHA-256 sized: ${out}" ;; esac
    case "$out" in *"wired=True"*) ;; *) _tm_afail "create_app does not install the SHA-256 interface: ${out}" ;; esac
}
tm_case "session-cookie-is-signed-with-hmac-sha256" tmapp f_cookie

tm_finish
