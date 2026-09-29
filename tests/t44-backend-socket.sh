#!/usr/bin/env bash
# =============================================================================
# t44 — GUNICORN ON A UNIX SOCKET ONLY (v1.2.0, owner ruling 2026-09-29;
# adversary F-05, sec-review TM-SEC-003).
#
# On 127.0.0.1:5001 any local process could reach gunicorn directly: past
# nginx's rate limits, and with an X-Forwarded-For of its choosing that
# ProxyFix (x_for=1) records as the client in every session and audit row.
# The listener is now a Unix socket systemd creates 0660
# topic-manager:www-data (systemd/topic-manager.socket) and hands to gunicorn.
#
#   * the socket unit, the service, the nginx upstream and the installers
#     name ONE path, and nothing names 5001 any more;
#   * the REAL gunicorn, started with the unit's own arguments and a socket
#     passed the way systemd passes it (LISTEN_FDS), serves on THAT socket
#     and binds nothing of its own; started WITHOUT it, it fails closed
#     (a 0660 socket nginx cannot open, never a TCP port);
#   * the upgrade stops the socket with the service, installs and backs it
#     up, and a rollback to a release without it REMOVES it — left enabled it
#     would hand the restored gunicorn a socket in place of its own port.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "gunicorn listens on a 0660 Unix socket systemd owns; nothing listens on 5001"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"
SOCKU="${TM_REPO_ROOT}/systemd/topic-manager.socket"
SVCU="${TM_REPO_ROOT}/systemd/topic-manager.service"
SITE="$(tm_nginx_site)"
UP="$(tm_upgrade_sh)"
INSTALL_SH="$(tm_install_sh)"
SOCK=/run/topic-manager/gunicorn.sock

a_one_path_everywhere() {
    tm_assert_file "$SOCKU" "there is no socket unit"
    grep -qx "ListenStream=${SOCK}" "$SOCKU" || _tm_afail "the socket unit does not listen on ${SOCK}"
    grep -qx 'SocketUser=topic-manager' "$SOCKU" || _tm_afail "the socket is not owned by the service account"
    grep -qx 'SocketGroup=www-data' "$SOCKU" || _tm_afail "the socket's group is not nginx's (www-data)"
    grep -qx 'SocketMode=0660' "$SOCKU" || _tm_afail "the socket is not 0660"
    grep -qx 'Requires=topic-manager.socket' "$SVCU" || _tm_afail "the service does not require its socket"
    grep -qE '^After=.*topic-manager\.socket' "$SVCU" || _tm_afail "the service is not ordered after its socket"
    grep -qE "^[[:space:]]+--bind unix:${SOCK} \\\\$" "$SVCU" || _tm_afail "the service's --bind is not the socket path"
    grep -qE "^[[:space:]]+server unix:${SOCK};" "$SITE" || _tm_afail "nginx does not proxy to the socket"
    local hits
    # Comments may tell the history ("until v1.2.0 ... 127.0.0.1:5001"); no
    # directive, row or value may name it.
    hits="$(grep -rnE '127\.0\.0\.1:5001|:5001\b|--bind 127|,"5001",' "${TM_REPO_ROOT}/systemd" "${TM_REPO_ROOT}/nginx" \
        "${TM_REPO_ROOT}/PPSM.csv" "${TM_REPO_ROOT}/config" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
    [ -z "$hits" ] || _tm_afail "something still names the old TCP listener: ${hits}"
}
tm_case "one-socket-path-in-the-units-nginx-and-no-5001" none a_one_path_everywhere

a_installers_carry_the_socket() {
    grep -q '"${SCRIPT_DIR}/systemd/topic-manager.socket"' "$INSTALL_SH" || _tm_afail "install.sh does not install the socket unit"
    grep -q 'systemctl enable "${SERVICE_NAME}.socket" "${SERVICE_NAME}"' "$INSTALL_SH" || _tm_afail "install.sh does not enable the socket"
    grep -q '"${WORK_DIR}/systemd/topic-manager.socket"' "$UP" || _tm_afail "the upgrade does not install the socket unit"
    grep -q 'systemctl enable "${SERVICE}.socket" "$SERVICE"' "$UP" || _tm_afail "the upgrade does not enable the socket"
    grep -q 'cp -a /etc/systemd/system/topic-manager.socket "${BACKUP_DIR}/system/"' "$UP" \
        || _tm_afail "the restore point does not keep the socket unit"
    # Phase 7 stops the socket right after the service, or a request would
    # start the half-replaced service again.
    local p7; p7="$(tm_extract_between "$UP" '^phase "Phase 7 — Stop service and replace application"$' '^success "Previous application removed"$')"
    grep -q 'systemctl stop "${SERVICE}.socket"' <<<"$p7" || _tm_afail "Phase 7 leaves the socket listening"
    local p12; p12="$(tm_extract_between "$UP" '^phase "Phase 12 — Start and verify"$' '^success "Service active"$')"
    grep -q 'systemctl start "${SERVICE}.socket"' <<<"$p12" || _tm_afail "Phase 12 does not start the socket"
    grep -q '^    restore_socket_unit "\$BD"$' <<<"$(tm_extract_func "$UP" restore_from_backup)" \
        || _tm_afail "a rollback does not put the socket unit right"
    grep -q 'systemctl stop "${SERVICE}.socket"' <<<"$(tm_extract_func "$UP" restore_from_backup)" \
        || _tm_afail "a rollback leaves the socket listening while it restores"
}
tm_case "install-and-upgrade-install-stop-back-up-and-restore-the-socket" none a_installers_carry_the_socket

_restore_socket() {   # _restore_socket <backup-has-socket: yes|no>
    local R="${TM_TMP}/rs"
    rm -rf "$R" "${TM_TMP}/bd"; mkdir -p "$R/etc/systemd/system/sockets.target.wants" "${TM_TMP}/bd/system"
    printf '[Socket]\nListenStream=%s\n' "$SOCK" > "$R/etc/systemd/system/topic-manager.socket"
    ln -s ../topic-manager.socket "$R/etc/systemd/system/sockets.target.wants/topic-manager.socket"
    [ "$1" = yes ] && printf '[Socket]\n# the restore point copy\n' > "${TM_TMP}/bd/system/topic-manager.socket"
    : > "${TM_TMP}/calls"
    {
        echo 'set -uo pipefail'
        echo 'systemctl() { echo "systemctl $*" >> "'"${TM_TMP}"'/calls"; }'
        tm_extract_func "$UP" restore_socket_unit | sed "s#/etc/systemd/#${R}/etc/systemd/#g"
        echo 'restore_socket_unit "$1"'
    } > "${TM_TMP}/rs.sh"
    grep -qE '(^|[^/])/etc/systemd' <(grep -v "${R}" "${TM_TMP}/rs.sh") && tm_die "a path escaped the fake root"
    bash "${TM_TMP}/rs.sh" "${TM_TMP}/bd" || _tm_afail "restore_socket_unit failed"
}

a_rollback_socket() {
    local R="${TM_TMP}/rs"
    _restore_socket no
    grep -qx 'systemctl disable --now topic-manager.socket' "${TM_TMP}/calls" \
        || _tm_afail "a rollback to a TCP release did not disable the socket: $(cat "${TM_TMP}/calls")"
    tm_assert_nofile "$R/etc/systemd/system/topic-manager.socket" "the socket unit survived a rollback to a release without one"
    [ -L "$R/etc/systemd/system/sockets.target.wants/topic-manager.socket" ] \
        && _tm_afail "the socket stays wanted by sockets.target after the rollback"
    _restore_socket yes
    grep -q 'the restore point copy' "$R/etc/systemd/system/topic-manager.socket" \
        || _tm_afail "a rollback to a socket release did not restore its socket unit"
    grep -q 'disable' "${TM_TMP}/calls" && _tm_afail "a rollback to a socket release disabled the socket"
    true
}
tm_case "a-rollback-to-a-tcp-release-removes-the-socket" none a_rollback_socket

# ── the REAL gunicorn, with the unit's own arguments ─────────────────────────
_unit_args() {   # the service's ExecStart arguments, one per line, paths relocated
    "$PY" - "$SVCU" "$1" "$TM_TMP" <<'PYEOF' | tr -d '\r'
import shlex, sys
joined = open(sys.argv[1], encoding='utf-8').read().replace('\\\n', ' ')
line = next(l for l in joined.splitlines() if l.startswith('ExecStart='))
args = shlex.split(line[len('ExecStart='):])
assert args[0].endswith('/gunicorn'), args[0]
out = []
for a in args[1:]:
    a = a.replace('/run/topic-manager/gunicorn.sock', sys.argv[2])
    a = a.replace('/opt/topic-manager/logs/', sys.argv[3] + '/')
    out.append(a)
print('\n'.join(out))
PYEOF
}

_setup_app() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs" "${TM_TMP}/data" "${TM_TMP}/sock"
    printf 'clusters: []\n' > "${TM_TMP}/clusters.d/clusters.yaml"
    cat > "${TM_TMP}/config.yaml" <<YAML
server:
  secret_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
auth:
  ldap_server: "ldaps://dc1.example.org:636"
  ldap_domain: "example.org"
  ldap_base_dn: "DC=example,DC=org"
  required_group: "CN=G,DC=example,DC=org"
audit:
  db_path: "${TM_TMP}/data/tm.db"
logging:
  log_level: "ERROR"
YAML
    # systemd's half of socket activation, done by hand: bind, set the mode,
    # put the socket on fd 3, and exec (the PID survives exec, so LISTEN_PID
    # names the gunicorn arbiter, exactly as systemd sets it).
    cat > "${TM_TMP}/activate.py" <<'PYEOF'
import os, socket, sys
path, argv = sys.argv[1], sys.argv[2:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
os.chmod(path, 0o660)
s.listen(16)
if s.fileno() != 3:
    os.dup2(s.fileno(), 3)
os.set_inheritable(3, True)
os.environ['LISTEN_FDS'] = '1'
os.environ['LISTEN_PID'] = str(os.getpid())
os.execv(argv[0], argv)
PYEOF
}

_gunicorn() {   # _gunicorn <activated: yes|no> <socket path> — starts it in the background, PID in GPID
    local -a args
    mapfile -t args < <(_unit_args "$2")
    local -a pre=()
    [ "$1" = yes ] && pre=("$PY" "${TM_TMP}/activate.py" "$2")
    ( cd "$PYROOT" && exec env PYTHONPATH="$PYROOT" PYTHONDONTWRITEBYTECODE=1 TM_CONFIG="${TM_TMP}/config.yaml" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        TM_SYSLOG_SOCKET="${TM_TMP}/none.sock" TM_APPLY_RESULT_DIR="${TM_TMP}/run" \
        "${pre[@]}" "$(command -v "$PY")" -m gunicorn "${args[@]}" "tm.app:create_app()" ) \
        > "${TM_TMP}/g.out" 2>&1 &
    GPID=$!
}

_health() {   # _health <socket> -> the body, or empty
    local i body=""
    for i in $(seq 1 40); do
        body="$(curl -s --max-time 2 --unix-socket "$1" http://localhost/api/health 2>/dev/null || true)"
        [ -n "$body" ] && break
        sleep 0.5
    done
    printf '%s' "$body"
}

_stop() { kill -TERM "$GPID" 2>/dev/null; wait "$GPID" 2>/dev/null; true; }

a_real_gunicorn_serves_the_inherited_socket() {
    command -v curl >/dev/null 2>&1 || _tm_afail "no curl here"
    "$PY" -c 'import gunicorn' 2>/dev/null || _tm_afail "no gunicorn in ${PY}"
    _setup_app
    local s="${TM_TMP}/sock/gunicorn.sock" ino_before ino_after body mode
    _gunicorn yes "$s"
    for _ in $(seq 1 20); do [ -S "$s" ] && break; sleep 0.25; done
    ino_before="$(stat -c %i "$s" 2>/dev/null)"
    body="$(_health "$s")"
    ino_after="$(stat -c %i "$s" 2>/dev/null)"; mode="$(stat -c %a "$s" 2>/dev/null)"
    _stop
    case "$body" in *'"status":"ok"'*) ;; *) _tm_afail "gunicorn did not answer on the activated socket: ${body} $(tail -5 "${TM_TMP}/g.out" "${TM_TMP}/error.log" 2>/dev/null)" ;; esac
    [ -n "$ino_before" ] && [ "$ino_before" = "$ino_after" ] \
        || _tm_afail "gunicorn replaced the socket systemd handed it (inode ${ino_before} -> ${ino_after}): it bound its own"
    tm_assert_eq "660" "$mode" "the activated socket's mode changed under gunicorn"
    grep -q "Listening at: unix:${s}" "${TM_TMP}/error.log" || _tm_afail "gunicorn does not report the socket as its listener: $(grep -i listening "${TM_TMP}/error.log")"
    grep -qE 'Listening at: http://' "${TM_TMP}/error.log" && _tm_afail "gunicorn ALSO listens on TCP"
    true
}
tm_case "the-real-gunicorn-serves-the-socket-systemd-hands-it" "linux,tmapp" a_real_gunicorn_serves_the_inherited_socket

a_unactivated_gunicorn_fails_closed() {
    command -v curl >/dev/null 2>&1 || _tm_afail "no curl here"
    "$PY" -c 'import gunicorn' 2>/dev/null || _tm_afail "no gunicorn in ${PY}"
    _setup_app
    local s="${TM_TMP}/sock/fallback.sock" mode body
    _gunicorn no "$s"
    body="$(_health "$s")"
    mode="$(stat -c %a "$s" 2>/dev/null)"
    _stop
    case "$body" in *'"status":"ok"'*) ;; *) _tm_afail "the fallback bind did not come up at all: $(tail -5 "${TM_TMP}/g.out" "${TM_TMP}/error.log" 2>/dev/null)" ;; esac
    tm_assert_eq "660" "$mode" "without systemd, gunicorn's own socket is NOT 0660 (the --umask is gone): anyone who can reach the directory could open it"
    grep -qE 'Listening at: http://' "${TM_TMP}/error.log" && _tm_afail "the fallback listens on TCP"
    true
}
tm_case "a-gunicorn-started-without-its-socket-fails-closed" "linux,tmapp" a_unactivated_gunicorn_fails_closed

tm_finish
