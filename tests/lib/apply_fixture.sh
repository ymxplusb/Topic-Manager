# shellcheck shell=bash
# =============================================================================
# tests/lib/apply_fixture.sh — a fake host root for the root apply helper
# (install/libexec/tm-apply), shared by t34, t35 and t37.
#
# The helper is run FOR REAL, as root, with --root pointing at a directory tree
# that looks like the host (/etc/nginx, /etc/rsyslog.d, /etc/chrony, the
# staging directory owned by an unprivileged account, ...) and --bin at a
# directory of tools:
#   * openssl, setpriv, test  -> the REAL binaries;
#   * nginx, rsyslogd         -> the REAL binaries where the host has them
#                                (rsyslogd as an unconfined COPY: its AppArmor
#                                profile cannot read a fixture tree), run
#                                against the fixture, else a stub that says so;
#   * systemctl, ufw, chronyd, chronyc, timedatectl -> recording stubs whose
#                                answers are set per case (files in $FX).
# Every stub appends "<tool> <args>" to $FX/calls.
# =============================================================================

FX_SVC_USER="${TM_TEST_SVC_USER:-nobody}"

fx_setup() {   # fx_setup — builds $FX (root), $FXBIN (tools)
    FX="${TM_TMP}/root"; FXBIN="${TM_TMP}/bin"
    export FX FXBIN
    mkdir -p "$FX"/opt/topic-manager/data/apply "$FX"/var/backups/topic-manager \
        "$FX"/etc/nginx/{conf.d,snippets,sites-available,sites-enabled} "$FX"/etc/rsyslog.d \
        "$FX"/etc/chrony/sources.d "$FX"/etc/systemd/timesyncd.conf.d "$FX"/etc/topic-manager/tls \
        "$FX"/etc/ssl/certs "$FXBIN"
    chown "$FX_SVC_USER" "$FX"/opt/topic-manager/data/apply
    chmod 700 "$FX"/opt/topic-manager/data/apply
    printf 'pool ntp.ubuntu.com iburst\nsourcedir /etc/chrony/sources.d\n' > "$FX"/etc/chrony/chrony.conf
    printf -- '-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n' > "$FX"/etc/ssl/certs/ca-certificates.crt
    # The shipped files, installed the way install.sh installs them.
    cp "${TM_REPO_ROOT}/nginx/tm-limits.conf" "$FX"/etc/nginx/conf.d/topic-manager-limits.conf
    for f in tm-limits-server tm-limits-login tm-limits-api tm-syslog tm-security-headers; do
        cp "${TM_REPO_ROOT}/nginx/${f}.conf" "$FX/etc/nginx/snippets/${f}.conf"
    done
    cp "${TM_REPO_ROOT}/nginx/topic-manager-http.conf" "$FX"/etc/nginx/sites-available/topic-manager-http
    ln -s "$FX"/etc/nginx/sites-available/topic-manager-http "$FX"/etc/nginx/sites-enabled/topic-manager-http
    cp "${TM_REPO_ROOT}/install/rsyslog/30-topic-manager.conf" "$FX"/etc/rsyslog.d/30-topic-manager.conf
    : > "${TM_TMP}/calls"
    printf 'nginx.service\nrsyslog.service\n' > "${TM_TMP}/active"
    printf 'Status: active\n' > "${TM_TMP}/ufw.state"
    _fx_tools
}

_fx_stub() {   # _fx_stub <name> <body>
    { printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/calls"\n' "$1" "$TM_TMP"; printf '%s\n' "$2"; } \
        > "${FXBIN}/$1"
    chmod 755 "${FXBIN}/$1"
}

_fx_tools() {
    local T="$TM_TMP"
    ln -sf "$(command -v openssl)" "${FXBIN}/openssl"
    ln -sf "$(command -v setpriv 2>/dev/null || echo /usr/bin/setpriv)" "${FXBIN}/setpriv"
    ln -sf "$(command -v test 2>/dev/null || echo /usr/bin/test)" "${FXBIN}/test"
    _fx_stub systemctl "
case \"\$1\" in
  is-active) grep -qx \"\$2\" '${T}/active' && { echo active; exit 0; }; echo inactive; exit 3 ;;
  restart|reload|try-reload-or-restart|start)
     [ -f \"${T}/fail.\$1\" ] && { echo \"stub: \$1 failed\"; exit 1; }; exit 0 ;;
esac
exit 0"
    _fx_stub ufw "
st=\$(cat '${T}/ufw.state')
case \"\$1\" in
  status) printf '%s\n\nTo                         Action      From\n--                         ------      ----\n' \"\$(head -1 '${T}/ufw.state')\"
          grep -q '^80/tcp' '${T}/ufw.state' && printf '80/tcp                     ALLOW       Anywhere\n'
          grep -q '^443/tcp' '${T}/ufw.state' && printf '443/tcp                    ALLOW       Anywhere\n'
          exit 0 ;;
  allow) [ \"\$2\" = 80/tcp ] && { grep -q '^80/tcp' '${T}/ufw.state' || echo 80/tcp >> '${T}/ufw.state'; echo 'Rule added'; exit 0; } ;;
  delete) [ \"\$2 \$3\" = 'allow 80/tcp' ] && { sed -i '/^80\/tcp/d' '${T}/ufw.state'; echo 'Rule deleted'; exit 0; } ;;
esac
echo 'ERROR: Invalid syntax'; exit 1"
    _fx_stub chronyd "[ -f '${T}/fail.chronyd' ] && { echo 'chronyd: bad directive'; exit 1; }; cat \"\${@: -1}\" > '${T}/chronyd.saw'; exit 0"
    _fx_stub chronyc "[ \"\$1 \$2\" = 'reload sources' ] && exit 0; printf '^,+,192.0.2.1,2,6,377,1,0.0001,0.0002,0.001\n'; exit 0"
    _fx_stub timedatectl "cat '${T}/timesync.servers' 2>/dev/null; exit 0"
    # nginx: the real binary against the fixture tree when this host has one.
    local real_nginx; real_nginx="$(command -v nginx 2>/dev/null || true)"
    [ -x /usr/sbin/nginx ] && real_nginx=/usr/sbin/nginx
    if [ -n "$real_nginx" ] && [ -z "${TM_FX_STUB_NGINX:-}" ]; then
        FX_NGINX=real
        _fx_nginx_conf
        _fx_stub nginx "[ -f '${T}/fail.nginx' ] && { echo 'nginx: [emerg] stub-injected failure'; exit 1; }
exec ${real_nginx} -t -q -c '${T}/nginx-test.conf'"
    else
        FX_NGINX=stub
        _fx_stub nginx "[ -f '${T}/fail.nginx' ] && { echo 'nginx: [emerg] stub-injected failure'; exit 1; }; exit 0"
    fi
    local real_rs=""; [ -x /usr/sbin/rsyslogd ] && real_rs=/usr/sbin/rsyslogd
    if [ -n "$real_rs" ]; then
        FX_RSYSLOG=real
        cp "$real_rs" "${TM_TMP}/rsyslogd-unconfined"
        _fx_stub rsyslogd "[ -f '${T}/fail.rsyslogd' ] && { echo 'rsyslogd: stub-injected failure'; exit 1; }
if [ \"\$2\" = -f ]; then cp \"\$3\" '${T}/rsyslog.pretest'; exec '${T}/rsyslogd-unconfined' -N1 -f \"\$3\"; fi
exit 0"
    else
        FX_RSYSLOG=stub
        _fx_stub rsyslogd "[ -f '${T}/fail.rsyslogd' ] && { echo 'rsyslogd: stub-injected failure'; exit 1; }
[ \"\$2\" = -f ] && cp \"\$3\" '${T}/rsyslog.pretest'; exit 0"
    fi
    export FX_NGINX FX_RSYSLOG
}

# A minimal nginx.conf that loads the FIXTURE's managed files and the real
# site file (with its /etc paths pointed into the fixture) — so `nginx -t`
# checks exactly what the helper rendered, with the real parser.
_fx_nginx_conf() {
    local T="$TM_TMP" site="${TM_TMP}/site.conf"
    sed -e "s#/etc/nginx/snippets/#${FX}/etc/nginx/snippets/#g" \
        -e "s#/etc/topic-manager/tls/#${FX}/etc/topic-manager/tls/#g" \
        -e "s#/var/log/nginx/#${T}/#g" "$(tm_nginx_site)" > "$site"
    # The certificate nginx -t loads is the FIXTURE's installed pair, so a TLS
    # apply is tested with the pair it just installed.
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=fx \
        -keyout "${FX}/etc/topic-manager/tls/server.key" \
        -out "${FX}/etc/topic-manager/tls/server.crt" >/dev/null 2>&1
    chmod 600 "${FX}/etc/topic-manager/tls/server.key"
    cat > "${T}/nginx-test.conf" <<NGX
pid ${T}/nginx.pid;
error_log ${T}/nginx-error.log;
events {}
http {
    access_log off;
    client_body_temp_path ${T}/body;
    proxy_temp_path ${T}/proxy;
    fastcgi_temp_path ${T}/fcgi;
    uwsgi_temp_path ${T}/uwsgi;
    scgi_temp_path ${T}/scgi;
    include ${FX}/etc/nginx/conf.d/*.conf;
    include ${site};
    include ${FX}/etc/nginx/sites-enabled/*;
}
NGX
}

fx_helper() {   # fx_helper <domain> — run the helper; RC and the result in $FX_RES
    FX_RC=0
    python3 -I "$(tm_apply_helper)" "$1" --root "$FX" --bin "$FXBIN" \
        --lib "$(tm_py_root)/tm" --svc-user "$FX_SVC_USER" > "${TM_TMP}/helper.out" 2>&1 || FX_RC=$?
    FX_RES="${FX}/run/topic-manager-apply/$1.result"
}

fx_field() {   # fx_field <jsonpath-ish python expr on d>
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$FX_RES" 2>/dev/null | tr -d '\r'
}

fx_stage() {   # fx_stage <domain> <json settings> — through the REAL tm/apply.py writer
    local NT="$FX/opt/topic-manager/data"
    PYTHONPATH="$(tm_py_root)" PYTHONDONTWRITEBYTECODE=1 python3 - "$1" "$2" "$NT" <<'PYEOF'
import json, sys
from tm import apply
cfg = {'audit': {'db_path': sys.argv[3] + '/tm.db'}}
print(apply.write_stage(cfg, sys.argv[1], json.loads(sys.argv[2]), 'tester'))
PYEOF
    chown -R "$FX_SVC_USER" "$FX/opt/topic-manager/data/apply"
}

fx_stage_raw() {   # fx_stage_raw <domain> <raw json document> — bypasses every app-side check
    printf '%s' "$2" > "$FX/opt/topic-manager/data/apply/$1.json"
    chown "$FX_SVC_USER" "$FX/opt/topic-manager/data/apply/$1.json"
    chmod 600 "$FX/opt/topic-manager/data/apply/$1.json"
}

fx_hash_managed() {   # a digest of every file and link the helper may touch
    ( cd "$FX" && find etc -type f -o -type l | sort | while read -r f; do
        if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; else sha256sum "$f"; fi
    done; cat "${TM_TMP}/ufw.state" ) | sha256sum | cut -d' ' -f1
}
