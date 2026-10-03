#!/usr/bin/env bash
# =============================================================================
# t52 — v1.3.0 THE WEB TIER, SERVED (NGNX-APP-000240, -001070; DQ5).
#
# The SHIPPED site, with the SHIPPED log format and snippets, run by the REAL
# nginx on a loopback port (its /etc paths pointed at the tree, a throwaway
# certificate, a backend socket that does not exist):
#
#   * nginx's own errors are the product's pages: a missing file is a 404
#     page and a dead backend a 502 JSON answer, neither naming nginx, both
#     with the security headers (nginx drops add_header on error pages
#     without "always", and a location that sets one inherits none);
#   * the access log is written in tm_dod, every DoD field present, the
#     request id a fresh 32-hex value;
#   * the :80 site logs in the same format, to the product's log;
#   * the syslog copy the helper renders names the format and passes nginx -t.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "v1.3.0 nginx: the product's own error pages, the DoD log format, served by the real nginx"

_nginx() {
    local n; n="$(command -v nginx 2>/dev/null || true)"
    [ -x /usr/sbin/nginx ] && n=/usr/sbin/nginx
    echo "$n"
}

# _serve: start the shipped site on 127.0.0.1:${PORT}; D is its directory.
_serve() {
    NGX="$(_nginx)"; [ -n "$NGX" ] || _tm_afail "no real nginx here"
    D="${TM_TMP}/srv"; PORT=18443; HPORT=18081   # not 18080: t36 uses it
    mkdir -p "$D/www" "$D/log"
    printf '<!DOCTYPE html><title>tm</title>' > "$D/www/index.html"
    # nginx's workers are not root: the docroot must be reachable through the
    # 0700 scratch directories (as /var/www is on a host).
    chmod 755 "$D" "$D/www"; chmod 644 "$D/www/index.html"; tm_open_traversal "$D"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=tm.example.org \
        -keyout "$D/k.pem" -out "$D/c.pem" >/dev/null 2>&1 || _tm_afail "openssl could not make a certificate"
    sed -e "s#listen 443 ssl http2;#listen 127.0.0.1:${PORT} ssl;#" \
        -e "s#/etc/nginx/snippets/#${TM_REPO_ROOT}/nginx/#g" \
        -e "s#/etc/topic-manager/tls/server.crt#${D}/c.pem#" -e "s#/etc/topic-manager/tls/server.key#${D}/k.pem#" \
        -e "s#/var/log/nginx/#${D}/log/#g" -e "s#root /var/www/topic-manager;#root ${D}/www;#" \
        -e "s#unix:/run/topic-manager/gunicorn.sock#unix:${D}/no-backend.sock#" \
        -e 's/YOUR-HOSTNAME.YOUR-DOMAIN.com/tm.example.org/' \
        "$(tm_nginx_site)" > "$D/site.conf"
    grep -q "listen 127.0.0.1:${PORT} ssl;" "$D/site.conf" || _tm_afail "the site's listen line moved; this case cannot relocate it"
    sed -e "s/^\([[:space:]]*\)listen 80;/\1listen 127.0.0.1:${HPORT};/" -e "s#/var/log/nginx/#${D}/log/#g" \
        -e 's/YOUR-HOSTNAME.YOUR-DOMAIN.com/tm.example.org/' "${TM_HTTP_SITE:-${TM_REPO_ROOT}/nginx/topic-manager-http.conf}" > "$D/http.conf"
    # The snippets' own names are tm-*.conf; the site includes them by those names.
    for f in tm-limits-server tm-limits-login tm-limits-api tm-syslog tm-security-headers; do
        [ -f "${TM_REPO_ROOT}/nginx/${f}.conf" ] || _tm_afail "missing shipped snippet ${f}.conf"
    done
    cat > "$D/nginx.conf" <<NGX
pid ${D}/nginx.pid;
error_log ${D}/log/main-error.log;
events {}
http {
    access_log ${D}/log/main-access.log;
    client_body_temp_path ${D}/body; proxy_temp_path ${D}/proxy; fastcgi_temp_path ${D}/fcgi;
    uwsgi_temp_path ${D}/uwsgi; scgi_temp_path ${D}/scgi;
    include ${TM_REPO_ROOT}/nginx/tm-limits.conf;
    include ${TM_LOG_FORMAT:-${TM_REPO_ROOT}/nginx/tm-log-format.conf};
    include ${D}/site.conf;
    include ${D}/http.conf;
}
NGX
    "$NGX" -c "$D/nginx.conf" -p "$D" > "$D/start.out" 2>&1 \
        || _tm_afail "nginx would not start: $(cat "$D/start.out" "$D/log/main-error.log" 2>/dev/null)"
}
_stop() { "$NGX" -c "$D/nginx.conf" -p "$D" -s stop >/dev/null 2>&1 || kill "$(cat "$D/nginx.pid" 2>/dev/null)" 2>/dev/null; }

a_error_pages() {
    _serve
    local h404 b404 h502 b502 c403
    h404="$(curl -sk -D - -o "$D/b404" "https://127.0.0.1:${PORT}/no-such-file.js")"
    b404="$(cat "$D/b404")"
    h502="$(curl -sk -D - -o "$D/b502" "https://127.0.0.1:${PORT}/api/health")"
    b502="$(cat "$D/b502")"
    _stop
    case "$h404" in "HTTP/1.1 404"*) ;; *) _tm_afail "a missing file is not a 404: ${h404}" ;; esac
    case "$h502" in "HTTP/1.1 502"*) ;; *) _tm_afail "a dead backend is not a 502: ${h502}" ;; esac
    case "${b404}${b502}" in *[Nn]ginx*) _tm_afail "an error page names nginx: ${b404} ${b502}" ;; esac
    case "$b404" in *"There is nothing to show at this address."*) ;; *) _tm_afail "the 404 is not the product's page: ${b404}" ;; esac
    case "$b502" in *'"code":"unavailable"'*) ;; *) _tm_afail "the 502 is not the product's JSON answer: ${b502}" ;; esac
    local h
    for h in "$h404" "$h502"; do
        grep -qi '^content-security-policy:' <<<"$h" || _tm_afail "an error page lacks the security headers: ${h}"
        grep -qi '^strict-transport-security:' <<<"$h" || _tm_afail "an error page lacks HSTS: ${h}"
    done
    grep -qi '^content-type: application/json' <<<"$h502" || _tm_afail "the API's error is not JSON"
}
tm_case "nginx-errors-are-the-products-pages-with-their-headers" "linux,openssl" a_error_pages

a_dod_log_format() {
    _serve
    curl -sk -o /dev/null -H 'User-Agent: tm-probe/1' -H 'X-Forwarded-For: 198.51.100.7' "https://127.0.0.1:${PORT}/index.html?q=1"
    curl -s -o /dev/null "http://127.0.0.1:${HPORT}/x"
    sleep 1
    _stop
    local line hline
    line="$(grep 'GET /index.html?q=1' "$D/log/topic-manager-access.log" || true)"
    [ -n "$line" ] || _tm_afail "the request is not in the product's access log: $(cat "$D"/log/*.log)"
    # $time_local $server_name $server_addr $remote_addr $remote_user "$request" $status $body_bytes_sent "$http_user_agent" "$http_x_forwarded_for" $request_id
    [[ "$line" =~ ^[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9:]{8}\ [-+][0-9]{4}\ tm\.example\.org\ 127\.0\.0\.1\ 127\.0\.0\.1\ -\ \"GET\ /index\.html\?q=1\ HTTP/1\.1\"\ 200\ [0-9]+\ \"tm-probe/1\"\ \"198\.51\.100\.7\"\ [0-9a-f]{32}$ ]] \
        || _tm_afail "the access line is not the DoD format (time, server name and address, client, user, request, status, bytes, agent, forwarded-for, request id): ${line}"
    hline="$(grep 'GET /x' "$D/log/topic-manager-access.log" || true)"
    [[ "$hline" =~ \ 301\ .*\ [0-9a-f]{32}$ ]] || _tm_afail "the :80 site does not log in the DoD format to the product's log: ${hline}"
    grep -q 'GET /index.html' "$D/log/main-access.log" 2>/dev/null && _tm_afail "the product's traffic went to the OS package's access log"
    true
}
tm_case "the-access-log-carries-every-dod-field" "linux,openssl" a_dod_log_format

a_syslog_render_uses_the_format() {
    . "${TM_TESTS_DIR}/lib/apply_fixture.sh"
    fx_setup
    [ "$FX_NGINX" = real ] || _tm_afail "no real nginx here"
    fx_stage syslog '{"syslog_enabled":"true","syslog_host":"logs.example.org","syslog_port":"514","syslog_protocol":"tcp","syslog_app_id":"tm"}' >/dev/null
    fx_helper syslog
    tm_assert_eq "ok" "$(fx_field "d['state']")" "the syslog apply (nginx -t on the rendered snippet) failed: $(fx_field "d['message']")"
    grep -qE '^access_log syslog:server=unix:/dev/log,facility=local5,tag=tm_nginx_access,severity=info tm_dod;$' \
        "$FX/etc/nginx/snippets/tm-syslog.conf" || _tm_afail "the syslog copy of the access log is not in tm_dod: $(cat "$FX/etc/nginx/snippets/tm-syslog.conf")"
}
tm_case "the-syslog-copy-is-in-the-dod-format-and-passes-nginx-t" "linux,chown" a_syslog_render_uses_the_format

a_format_fields() {
    local f="${TM_LOG_FORMAT:-${TM_REPO_ROOT}/nginx/tm-log-format.conf}" k missing="" body
    body="$(grep -v '^#' "$f")"
    for k in '$server_name' '$server_addr' '$remote_addr' '$remote_user' '$time_local' '$status' '$request' '$request_id' '$http_user_agent' '$http_x_forwarded_for'; do
        grep -qF -- "$k" <<<"$body" || missing="${missing} ${k}"
    done
    [ -z "$missing" ] || _tm_afail "log_format tm_dod lacks:${missing}"
    grep -qE '^[[:space:]]*access_log /var/log/nginx/topic-manager-access.log tm_dod;' "$(tm_nginx_site)" \
        || _tm_afail "the site's access log is not in tm_dod"
    grep -qE '^log_format' "$(tm_nginx_site)" && _tm_afail "the format is defined in the site (it must be http-level, in conf.d, for both sites)"
    true
}
tm_case "the-format-names-every-field-and-lives-at-http-level" none a_format_fields

tm_finish
