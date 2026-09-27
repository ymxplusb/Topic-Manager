#!/usr/bin/env bash
# =============================================================================
# t36 — THE v1.2.0 NGINX SITE: rate limits, the sign-in location, the :80
# redirect as its own site, and the sign-in page's reading of a 429.
#
# hazards[nginx-add-header-inheritance]: a location that declares its own
# add_header loses every inherited security header, and a location that is
# NEW loses every proxy_set_header of its sibling. The sign-in location is
# both, and the backend TRUSTS X-Forwarded-Host (ProxyFix x_host=1), so a
# missing line there hands request.host to the client. These cases read the
# shipped site structurally, then run the REAL nginx -t over it with the
# rendered snippets where this host has nginx.
#
# The LoginView case runs the real component's doLogin under node against a
# fetch that returns what nginx returns: the old failure was "Network error —
# is the server reachable?" for a response the server sent on purpose.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "nginx: limits, the sign-in location, the :80 site; a 429 is never a 'network error'"

SITE="$(tm_nginx_site)"
PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"

# locations <site> -> one line per location: "<selector>\t<body on one line>"
_locations() {
    "$PY" - "$1" <<'PYEOF' | tr -d '\r'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
text = re.sub(r'#[^\n]*', '', text)
i = 0
while True:
    m = re.search(r'location\s+([^{]+?)\s*\{', text[i:])
    if not m:
        break
    start = i + m.end(); depth = 1; j = start
    while depth:
        if text[j] == '{': depth += 1
        elif text[j] == '}': depth -= 1
        j += 1
    body = ' '.join(text[start:j-1].split())
    print('%s\t%s' % (m.group(1).strip(), body))
    i = j
PYEOF
}

a_every_location_has_headers() {
    local n=0 sel body
    while IFS=$'\t' read -r sel body; do
        n=$((n+1))
        case "$body" in
            *"include /etc/nginx/snippets/tm-security-headers.conf;"*) ;;
            *) _tm_afail "location ${sel} does not include the security-header snippet" ;;
        esac
    done < <(_locations "$SITE")
    [ "$n" -ge 5 ] || _tm_afail "only ${n} locations found — the parser or the site moved"
}
tm_case "every-location-includes-the-security-headers" none a_every_location_has_headers

a_login_repeats_proxy_headers() {
    local api login h missing=""
    api="$(_locations "$SITE" | awk -F'\t' '$1 == "/api/" { print $2 }')"
    login="$(_locations "$SITE" | awk -F'\t' '$1 == "= /api/auth/login" { print $2 }')"
    [ -n "$login" ] || _tm_afail "there is no exact-match sign-in location"
    [ -n "$api" ] || _tm_afail "there is no /api/ location"
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        case "$login" in *"$h"*) ;; *) missing="${missing} [${h}]" ;; esac
    done < <(grep -oE 'proxy_(set_header|pass|http_version|read_timeout|connect_timeout|send_timeout|buffering|buffer_size|buffers)[^;]*;' <<<"$api")
    [ -z "$missing" ] || _tm_afail "the sign-in location drops what /api/ sets:${missing}"
    case "$login" in *"proxy_set_header X-Forwarded-Host \$host;"*) ;; *)
        _tm_afail "the sign-in location does not set X-Forwarded-Host (the backend trusts it)" ;; esac
    case "$login" in *"include /etc/nginx/snippets/tm-limits-login.conf;"*) ;; *)
        _tm_afail "the sign-in location is not rate-limited by the login snippet" ;; esac
    case "$api" in *"include /etc/nginx/snippets/tm-limits-api.conf;"*) ;; *)
        _tm_afail "/api/ is not rate-limited by the API snippet" ;; esac
    case "$login$api" in *"error_page 429 = @tm_rate_limited;"*"error_page 429 = @tm_rate_limited;"*) ;; *)
        _tm_afail "a limited request would get nginx's HTML page, not the JSON 429" ;; esac
}
tm_case "sign-in-location-repeats-every-proxy-directive-and-is-limited" none a_login_repeats_proxy_headers

a_server_level_limits() {
    grep -qE '^\s*limit_req_status\s+429;' "$SITE" || _tm_afail "limit_req_status is not 429 (nginx's default is 503)"
    grep -qE '^\s*limit_conn_status\s+429;' "$SITE" || _tm_afail "limit_conn_status is not 429"
    grep -qE '^\s*include /etc/nginx/snippets/tm-limits-server.conf;' "$SITE" || _tm_afail "no per-address connection limit"
    grep -qE '^\s*include /etc/nginx/snippets/tm-syslog.conf;' "$SITE" || _tm_afail "the syslog snippet is not included"
    local k
    for k in client_header_timeout client_body_timeout send_timeout client_max_body_size; do
        grep -qE "^\s*${k}\s+[0-9]+[sm];" "$SITE" || _tm_afail "${k} is not set (NGNX-APP-001030/001940)"
    done
    grep -qE '^\s*listen\s+80\b' "$SITE" && _tm_afail "the main site still listens on :80 — the redirect toggle cannot remove it"
    grep -qE '^\s*listen\s+80;' "${TM_REPO_ROOT}/nginx/topic-manager-http.conf" || _tm_afail "the :80 site has no listener"
    grep -q 'return 301 https://\$host\$request_uri;' "${TM_REPO_ROOT}/nginx/topic-manager-http.conf" \
        || _tm_afail "the :80 site does not redirect to HTTPS"
    grep -q '"code":"rate_limited"' "$SITE" || _tm_afail "the JSON 429 has no code to tell it from the app's own 429"
    grep -qE 'client_body_buffer_size\s+1m;' "$SITE" || _tm_afail "an API body can spill to nginx's temp dir (a TLS key would)"
}
tm_case "server-limits-timeouts-and-no-80-in-the-main-site" none a_server_level_limits

a_real_nginx_t() {
    . "${TM_TESTS_DIR}/lib/apply_fixture.sh"
    fx_setup
    [ "$FX_NGINX" = real ] || _tm_afail "no real nginx here"
    # Nothing staged: the shipped files, as install.sh lays them down.
    "${FXBIN}/nginx" > "${TM_TMP}/t.out" 2>&1 || _tm_afail "the shipped site + snippets fail the REAL nginx -t: $(cat "${TM_TMP}/t.out")"
    # And with the syslog snippet ON (as tm-apply renders it).
    printf 'access_log syslog:server=unix:/dev/log,facility=local5,tag=tm_nginx_access,severity=info;\nerror_log  syslog:server=unix:/dev/log,facility=local5,tag=tm_nginx_error warn;\n' \
        > "$FX/etc/nginx/snippets/tm-syslog.conf"
    "${FXBIN}/nginx" > "${TM_TMP}/t.out" 2>&1 || _tm_afail "the syslog-on rendering fails nginx -t: $(cat "${TM_TMP}/t.out")"
    # A broken snippet must make it fail — the test can go red.
    printf 'limit_req zone=tm_nosuch burst=5;\n' > "$FX/etc/nginx/snippets/tm-limits-login.conf"
    "${FXBIN}/nginx" > "${TM_TMP}/t.out" 2>&1 && _tm_afail "nginx -t PASSED a reference to an undefined zone — this check proves nothing"
    true
}
tm_case "the-shipped-site-passes-the-real-nginx-t" "linux,chown" a_real_nginx_t

_loginview() {   # _loginview <status> <content-type> <body> -> the error the page shows
    local js
    js="$(tm_loginview_js)"
    node - "$js" "$1" "$2" "$3" <<'JSEOF' 2>&1 | tr -d '\r'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
// The REAL component: the file declares `const LoginView = {...}` for the
// global build, so it is evaluated and that binding returned.
const def = new Function('Vue', 'window', src + String.fromCharCode(10) + 'return LoginView;')({}, { location: { hostname: 'tm.example.org' }, sessionStorage: { getItem: () => null, setItem: () => {} }, localStorage: { getItem: () => null, setItem: () => {} } });
const status = +process.argv[3], ctype = process.argv[4], body = process.argv[5];
global.fetch = async () => ({ ok: status < 400, status,
  headers: { get: () => ctype },
  json: async () => JSON.parse(body) });
const vm = Object.assign({}, def.data ? def.data() : {}, { username: 'u', password: 'p', $emit: () => {} });
for (const [k, f] of Object.entries(def.methods || {})) vm[k] = f.bind(vm);
vm.doLogin().then(() => console.log('ERROR=' + vm.error));
JSEOF
}

a_loginview_429() {
    local js; js="$(tm_loginview_js)"
    grep -q "^const LoginView = {" "$js" || _tm_afail "LoginView.js no longer declares const LoginView (the probe needs updating)"
    local e
    e="$(_loginview 429 text/html '<html><body><h1>429 Too Many Requests</h1></body></html>')"
    case "$e" in
        *"Network error"*) _tm_afail "an nginx HTML 429 is still shown as a network error: ${e}" ;;
        "ERROR=Too many sign-in attempts from this address. Wait a minute and try again.") ;;
        *) _tm_afail "an HTML 429 did not show the rate-limit message: ${e}" ;;
    esac
    e="$(_loginview 429 application/json '{"error":"Too many requests from this address. Wait a minute and try again.","code":"rate_limited"}')"
    tm_assert_eq "ERROR=Too many sign-in attempts from this address. Wait a minute and try again." "$e" "the JSON rate-limit 429"
    e="$(_loginview 429 application/json '{"error":"Concurrent session limit reached (3/3). Sign out from another session first."}')"
    tm_assert_eq "ERROR=Concurrent session limit reached (3/3). Sign out from another session first." "$e" \
        "the APPLICATION's 429 (session limit) was replaced by the rate-limit text — the two must stay distinguishable"
    e="$(_loginview 502 text/html '<html>Bad Gateway</html>')"
    tm_assert_eq "ERROR=Login failed (HTTP 502)" "$e" "a non-JSON 502 was not reported with its status"
    e="$(_loginview 401 application/json '{"error":"Invalid credentials"}')"
    tm_assert_eq "ERROR=Invalid credentials" "$e" "a normal refusal is no longer shown verbatim"
}
tm_case "sign-in-page-reads-a-429-as-a-rate-limit-not-a-network-error" node a_loginview_429

tm_finish
