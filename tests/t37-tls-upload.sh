#!/usr/bin/env bash
# =============================================================================
# t37 — THE SERVER CERTIFICATE UPLOAD (v1.2.0; NGNX-APP-001900/001960).
#
# Every certificate here is made by the REAL openssl on this host, and the
# validation under test is tm/tls_check.py driving that same CLI — never
# python `cryptography`, whose wheel carries its own OpenSSL rather than the
# host's (FIPS) one.
#
# Accepted: EC P-256/P-384, RSA 2048/3072/4096. Refused, each for its own
# reason: RSA-1024, secp256k1, Ed25519, a SHA-1 signature, an expired or
# not-yet-valid certificate, a mismatched pair, an unverifiable chain and an
# encrypted key.
#
# Contract CC-1: a refusal NEVER echoes the upload. A PEM whose body is a
# canary string is submitted as certificate, key and chain; the canary must
# appear in no response, no log line, no audit row, no syslog record and no
# file the application wrote. And the private key never reaches /tmp.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "TLS upload: host-openssl validation, fixed reasons, key never in /tmp, helper install + rollback"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
PYROOT="$(tm_py_root)"

_mk() {   # _mk <name> <openssl req key args...> — a self-signed leaf
    local n="$1"; shift
    openssl req -x509 -nodes -days 30 -subj "/CN=${n}.example.org" "$@" \
        -addext "subjectAltName=DNS:${n}.example.org" \
        -keyout "${TM_TMP}/${n}.key" -out "${TM_TMP}/${n}.crt" >/dev/null 2>&1
}

_mk_chain() {   # CA -> intermediate -> leaf (EC P-256), and an unrelated CA
    local T="$TM_TMP"
    openssl req -x509 -nodes -days 60 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -subj /CN=Test-Root \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
        -keyout "$T/root.key" -out "$T/root.crt" >/dev/null 2>&1
    openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -subj /CN=Test-Int \
        -keyout "$T/int.key" -out "$T/int.csr" >/dev/null 2>&1
    printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$T/int.ext"
    openssl x509 -req -in "$T/int.csr" -CA "$T/root.crt" -CAkey "$T/root.key" -CAcreateserial \
        -days 40 -sha256 -extfile "$T/int.ext" -out "$T/int.crt" >/dev/null 2>&1
    openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -subj /CN=leaf.example.org \
        -keyout "$T/leaf.key" -out "$T/leaf.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:leaf.example.org\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' > "$T/leaf.ext"
    openssl x509 -req -in "$T/leaf.csr" -CA "$T/int.crt" -CAkey "$T/int.key" -CAcreateserial \
        -days 20 -sha256 -extfile "$T/leaf.ext" -out "$T/leaf.crt" >/dev/null 2>&1
    cat "$T/int.crt" "$T/root.crt" > "$T/chain.pem"
    openssl req -x509 -nodes -days 60 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -subj /CN=Other-Root \
        -keyout "$T/other.key" -out "$T/other.crt" >/dev/null 2>&1
}

_validate() {   # _validate <crt> <key> [chain] [now-iso] -> OK:<key_type> | REFUSED:<reason>
    PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 "$PY" - "$@" <<'PYEOF' 2>&1 | tr -d '\r'
import sys, datetime
from tm import tls_check
a = sys.argv[1:]
rd = lambda p: open(p, 'rb').read() if p else None
now = datetime.datetime.fromisoformat(a[3]) if len(a) > 3 and a[3] else None
try:
    info = tls_check.validate(rd(a[0]), rd(a[1]), rd(a[2]) if len(a) > 2 and a[2] else None, now=now)
    print('OK:%s' % info['key_type'])
except tls_check.CertInvalid as e:
    print('REFUSED:%s' % e)
PYEOF
}

a_accepts_the_fips_set() {
    local spec got
    for spec in "p256|EC P-256|-newkey ec -pkeyopt ec_paramgen_curve:P-256" \
                "p384|EC P-384|-newkey ec -pkeyopt ec_paramgen_curve:P-384" \
                "r2048|RSA 2048|-newkey rsa:2048" "r3072|RSA 3072|-newkey rsa:3072" \
                "r4096|RSA 4096|-newkey rsa:4096"; do
        IFS='|' read -r n want args <<<"$spec"
        # shellcheck disable=SC2086
        _mk "$n" $args
        got="$(_validate "${TM_TMP}/${n}.crt" "${TM_TMP}/${n}.key")"
        tm_assert_eq "OK:${want}" "$got" "a ${want} certificate was refused"
    done
}
tm_case "accepts-ec-p256-p384-and-rsa-2048-3072-4096" "linux,openssl" a_accepts_the_fips_set

a_refuses_the_rest() {
    local got n
    if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ]; then
        # MEASURED on the STIG+FIPS QC host (2026-09-26): FIPS openssl refuses
        # to MAKE an RSA-1024, secp256k1, Ed25519 or SHA-1-signed certificate,
        # so the validator's refusal of each can only be exercised on a
        # non-FIPS host (the --remote test host). Here the host's refusal is
        # what is asserted — an openssl that made one would be the finding.
        for n in "r1024 -newkey rsa:1024" "k1 -newkey ec -pkeyopt ec_paramgen_curve:secp256k1" \
                 "ed -newkey ed25519" "s1 -newkey rsa:2048 -sha1"; do
            # shellcheck disable=SC2086
            _mk $n
            [ -s "${TM_TMP}/${n%% *}.crt" ] && _tm_afail "FIPS openssl MADE a ${n%% *} certificate"
        done
        tm_note "FIPS host: the four weak shapes were refused by openssl itself"
    else
    _mk r1024 -newkey rsa:1024
    got="$(_validate "${TM_TMP}/r1024.crt" "${TM_TMP}/r1024.key")"
    tm_assert_eq "REFUSED:unsupported key type: RSA 1024 (accepted: EC P-256, EC P-384, RSA 2048, RSA 3072, RSA 4096)" "$got" "RSA-1024"
    _mk k1 -newkey ec -pkeyopt ec_paramgen_curve:secp256k1
    got="$(_validate "${TM_TMP}/k1.crt" "${TM_TMP}/k1.key")"
    case "$got" in "REFUSED:unsupported key type: EC secp256k1"*) ;; *) _tm_afail "secp256k1: ${got}" ;; esac
    _mk ed -newkey ed25519
    got="$(_validate "${TM_TMP}/ed.crt" "${TM_TMP}/ed.key")"
    case "$got" in "REFUSED:unsupported key type: ED25519"*) ;; *) _tm_afail "Ed25519: ${got}" ;; esac
    _mk s1 -newkey rsa:2048 -sha1
    got="$(_validate "${TM_TMP}/s1.crt" "${TM_TMP}/s1.key")"
    tm_assert_eq "REFUSED:the certificate is signed with sha1WithRSAEncryption; SHA-1 and MD5 signatures are refused" "$got" "SHA-1"
    fi
    _mk ok -newkey ec -pkeyopt ec_paramgen_curve:P-256
    got="$(_validate "${TM_TMP}/ok.crt" "${TM_TMP}/ok.key" "" "2031-01-01T00:00:00+00:00")"
    case "$got" in "REFUSED:the certificate expired on "*) ;; *) _tm_afail "an expired certificate: ${got}" ;; esac
    got="$(_validate "${TM_TMP}/ok.crt" "${TM_TMP}/ok.key" "" "2001-01-01T00:00:00+00:00")"
    case "$got" in "REFUSED:the certificate is not valid until "*) ;; *) _tm_afail "a not-yet-valid certificate: ${got}" ;; esac
    _mk other -newkey ec -pkeyopt ec_paramgen_curve:P-256
    got="$(_validate "${TM_TMP}/ok.crt" "${TM_TMP}/other.key")"
    tm_assert_eq "REFUSED:the private key does not match the certificate" "$got" "a mismatched pair"
    openssl pkey -in "${TM_TMP}/ok.key" -aes256 -passout pass:secret -out "${TM_TMP}/enc.key" 2>/dev/null
    got="$(_validate "${TM_TMP}/ok.crt" "${TM_TMP}/enc.key")"
    case "$got" in "REFUSED:the private key is encrypted"*) ;; *) _tm_afail "an encrypted key: ${got}" ;; esac
}
tm_case "refuses-weak-keys-sha1-dates-mismatch-and-encrypted-keys" "linux,openssl" a_refuses_the_rest

a_chains() {
    _mk_chain
    local got
    got="$(_validate "${TM_TMP}/leaf.crt" "${TM_TMP}/leaf.key" "${TM_TMP}/chain.pem")"
    tm_assert_eq "OK:EC P-256" "$got" "a leaf with its real chain was refused"
    got="$(_validate "${TM_TMP}/leaf.crt" "${TM_TMP}/leaf.key" "${TM_TMP}/int.crt")"
    tm_assert_eq "OK:EC P-256" "$got" "a leaf with its intermediate only (partial chain) was refused"
    got="$(_validate "${TM_TMP}/leaf.crt" "${TM_TMP}/leaf.key" "${TM_TMP}/other.crt")"
    tm_assert_eq "REFUSED:the certificate does not verify against the supplied chain for TLS server use" "$got" \
        "an unverifiable chain was accepted"
    cat "${TM_TMP}/leaf.crt" "${TM_TMP}/int.crt" > "${TM_TMP}/two.crt"
    got="$(_validate "${TM_TMP}/two.crt" "${TM_TMP}/leaf.key")"
    case "$got" in "REFUSED:the certificate field must hold exactly one"*) ;; *) _tm_afail "two certs in the cert field: ${got}" ;; esac
}
tm_case "a-chain-must-verify-the-leaf" "linux,openssl" a_chains

_route_setup() {
    mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs" "${TM_TMP}/bin" "${TM_TMP}/run" "${TM_TMP}/data" "${TM_TMP}/tmp"
    printf 'clusters: []\n' > "${TM_TMP}/clusters.d/clusters.yaml"
    cat > "${TM_TMP}/config.yaml" <<YAML
server:
  secret_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
auth:
  ldap_server: "ldaps://dc1.example.org:636"
  ldap_domain: "example.org"
  ldap_base_dn: "DC=example,DC=org"
  required_group: "CN=G,DC=example,DC=org"
session:
  timeout_minutes: 30
audit:
  db_path: "${TM_TMP}/data/tm.db"
logging:
  log_level: "DEBUG"
YAML
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %s/calls\nexit 0\n' "$TM_TMP" > "${TM_TMP}/bin/systemctl"
    chmod 755 "${TM_TMP}/bin/systemctl"
}

_route() {   # _route <python body>
    cat > "${TM_TMP}/probe.py" <<PYEOF
import json, os, sqlite3, datetime, io, logging, socket
logbuf = io.StringIO()
h = logging.StreamHandler(logbuf); h.setLevel(logging.DEBUG)
logging.getLogger().addHandler(h); logging.getLogger().setLevel(logging.DEBUG)
rx = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); rx.bind(os.environ['TM_SYSLOG_SOCKET']); rx.setblocking(False)
def syslog_text():
    out = []
    while True:
        try: out.append(rx.recv(65536).decode('utf-8', 'replace'))
        except BlockingIOError: return '\n'.join(out)
from tm.app import create_app
app = create_app()
c = app.test_client()
with c.session_transaction() as s:
    s['user'] = {'username': 'admin'}; s['sid'] = 'sid1'
now = datetime.datetime.now(datetime.timezone.utc)
def db(): return sqlite3.connect(os.environ['TM_TEST_DB'])
d = db(); d.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)', ('sid1','admin',now.isoformat(),now.isoformat(),(now+datetime.timedelta(hours=1)).isoformat(),'x')); d.commit(); d.close()
T = os.environ['T']
def upload(crt, key, chain=None):
    data = {'cert': (io.BytesIO(crt), 'server.crt'), 'key': (io.BytesIO(key), 'server.key')}
    if chain is not None: data['chain'] = (io.BytesIO(chain), 'chain.pem')
    return c.post('/api/system/tls/cert', data=data, content_type='multipart/form-data')
$1
PYEOF
    PATH="${TM_TMP}/bin:${PATH}" PYTHONPATH="$PYROOT" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 T="$TM_TMP" \
        TMPDIR="${TM_TMP}/tmp" TM_CONFIG="${TM_TMP}/config.yaml" TM_TEST_DB="${TM_TMP}/data/tm.db" \
        TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        TM_APPLY_RESULT_DIR="${TM_TMP}/run" TM_SYSLOG_SOCKET="${TM_TMP}/log.sock" \
        "$PY" "${TM_TMP}/probe.py" 2>&1 | tr -d '\r'
}

a_canary_never_echoed() {
    _route_setup
    local out
    out="$(_route "
CAN = 'CANARY7f3e9d2c1b0a'
pem = lambda kind: ('-----BEGIN %s-----\n%s%s\n-----END %s-----\n' % (kind, CAN, 'A' * 40, kind)).encode()
results = []
for crt, key, chain in ((pem('CERTIFICATE'), pem('PRIVATE KEY'), pem('CERTIFICATE')),
                        (open(T + '/good.crt','rb').read(), pem('PRIVATE KEY'), None),
                        (open(T + '/good.crt','rb').read(), open(T + '/good.key','rb').read(), pem('CERTIFICATE')),
                        (pem('CERTIFICATE'), open(T + '/good.key','rb').read(), None)):
    r = upload(crt, key, chain)
    results.append((r.status_code, r.get_data(as_text=True)))
print('codes=%s' % [x[0] for x in results])
print('errors=%s' % sorted(set(json.loads(x[1]).get('error') for x in results)))
print('in_response=%s' % any(CAN in x[1] for x in results))
print('in_log=%s' % (CAN in logbuf.getvalue()))
d = db(); rows = ' '.join(str(r) for r in d.execute('SELECT * FROM audit_log').fetchall()); d.close()
print('in_audit=%s' % (CAN in rows))
print('in_syslog=%s' % (CAN in syslog_text()))
hits = []
for root in (T + '/data', T + '/run', T + '/tmp'):
    for dp, dn, fn in os.walk(root):
        for f in fn:
            try:
                if CAN.encode() in open(os.path.join(dp, f), 'rb').read(): hits.append(f)
            except OSError: pass
print('in_files=%s' % hits)
")"
    tm_assert_eq "codes=[400, 400, 400, 400]" "$(grep '^codes=' <<<"$out")" "a canary upload was not refused: ${out}"
    tm_assert_eq "errors=['invalid_cert']" "$(grep '^errors=' <<<"$out")" "the refusal is not invalid_cert"
    local w
    for w in in_response in_log in_audit in_syslog; do
        tm_assert_eq "${w}=False" "$(grep "^${w}=" <<<"$out")" "submitted PEM material was ECHOED (${w}) — contract CC-1: ${out}"
    done
    tm_assert_eq "in_files=[]" "$(grep '^in_files=' <<<"$out")" "submitted PEM material was written to a file"
}

a_canary_setup() {
    openssl req -x509 -nodes -days 30 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -subj /CN=good.example.org \
        -keyout "${TM_TMP}/good.key" -out "${TM_TMP}/good.crt" >/dev/null 2>&1
    a_canary_never_echoed
}
tm_case "no-refusal-ever-echoes-the-upload-canary" "tmapp,linux,openssl" a_canary_setup

a_valid_upload_stages_privately() {
    _route_setup
    _mk_chain
    local out
    out="$(_route "
before = set(os.listdir(os.environ['TMPDIR']))
key = open(T + '/leaf.key','rb').read()
r = upload(open(T + '/leaf.crt','rb').read(), key, open(T + '/chain.pem','rb').read())
j = r.get_json()
print('code=%d state=%s dom=%s' % (r.status_code, j.get('state'), j.get('domain')))
st = os.path.join(T, 'data', 'apply')
print('staged=%s' % sorted(os.listdir(st)))
print('keymode=%o' % (os.stat(os.path.join(st, 'tls.key')).st_mode & 0o777))
print('keysame=%s' % (open(os.path.join(st, 'tls.key'),'rb').read() == key))
print('newtmp=%s' % sorted(set(os.listdir(os.environ['TMPDIR'])) - before))
d = db(); rows = ' '.join(str(r) for r in d.execute('SELECT * FROM audit_log').fetchall()); d.close()
body = key.split(b'\n')[1].decode()
print('key_in_audit=%s key_in_log=%s' % (body in rows, body in logbuf.getvalue()))
print('settings_key=%s' % any(b'PRIVATE KEY' in (v or '').encode() for (v,) in db().execute('SELECT value FROM app_settings').fetchall()))
big = c.post('/api/system/tls/cert', data=b'x' * 300000, content_type='multipart/form-data; boundary=x')
print('big=%d %s' % (big.status_code, (big.get_json(silent=True) or {}).get('error')))
")"
    tm_assert_eq "code=202 state=queued dom=tls" "$(grep '^code=' <<<"$out")" "a valid upload was not staged: ${out}"
    tm_assert_eq "staged=['tls.chain', 'tls.crt', 'tls.json', 'tls.key', 'tls.last']" "$(grep '^staged=' <<<"$out")" \
        "the staging set is not cert + key + chain + job"
    tm_assert_eq "keymode=600" "$(grep '^keymode=' <<<"$out")" "the staged key is readable beyond the service account"
    tm_assert_eq "keysame=True" "$(grep '^keysame=' <<<"$out")" "the staged key is not the uploaded key"
    tm_assert_eq "newtmp=[]" "$(grep '^newtmp=' <<<"$out")" "the upload wrote a file under TMPDIR (the key must never reach /tmp)"
    tm_assert_eq "key_in_audit=False key_in_log=False" "$(grep '^key_in_audit=' <<<"$out")" "key material reached the audit trail or the log"
    tm_assert_eq "settings_key=False" "$(grep '^settings_key=' <<<"$out")" "key material reached app_settings (the DB)"
    tm_assert_eq "big=413 invalid_cert" "$(grep '^big=' <<<"$out")"         "an oversized upload was not refused BEFORE parsing with the contract's JSON error"
    grep -qx 'start --no-block topic-manager-apply-tls.service' "${TM_TMP}/calls" || _tm_afail "the tls apply unit was not started"
}
tm_case "a-valid-upload-stages-0600-in-the-data-dir-never-tmp" "tmapp,linux,openssl" a_valid_upload_stages_privately

a_helper_installs_and_rolls_back() {
    . "${TM_TESTS_DIR}/lib/apply_fixture.sh"
    fx_setup
    _mk_chain
    local tls="$FX/etc/topic-manager/tls" old_crt old_key
    [ -f "$tls/server.crt" ] || { printf 'old-cert\n' > "$tls/server.crt"; printf 'old-key\n' > "$tls/server.key"; chmod 600 "$tls/server.key"; }
    old_crt="$(sha256sum < "$tls/server.crt")"; old_key="$(sha256sum < "$tls/server.key")"
    _stage_tls() {
        PYTHONPATH="$(tm_py_root)" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 python3 - "$FX" "$TM_TMP" <<'PYEOF'
import sys
from tm import apply
fx, t = sys.argv[1], sys.argv[2]
rd = lambda n: open('%s/%s' % (t, n), 'rb').read()
apply.write_stage({'audit': {'db_path': fx + '/opt/topic-manager/data/tm.db'}}, 'tls', {}, 'admin',
                  files={'crt': rd('leaf.crt'), 'key': rd('leaf.key'), 'chain': rd('chain.pem')})
PYEOF
        chown -R "$FX_SVC_USER" "$FX/opt/topic-manager/data/apply"
    }
    # A failing nginx -t first: everything must come back exactly.
    : > "${TM_TMP}/fail.nginx"
    _stage_tls
    fx_helper tls
    tm_assert_eq "rolled_back test" "$(fx_field "d['state'] + ' ' + d['step']")" "state: $(cat "$FX_RES")"
    tm_assert_eq "$old_crt" "$(sha256sum < "$tls/server.crt")" "the old certificate was not restored byte for byte"
    tm_assert_eq "$old_key" "$(sha256sum < "$tls/server.key")" "the old KEY was not restored byte for byte"
    tm_assert_nofile "$tls/chain.pem" "a chain file was left from the rolled-back upload"
    tm_assert_nofile "$FX/opt/topic-manager/data/apply/tls.key" "the staged key survived a failed apply"
    rm -f "${TM_TMP}/fail.nginx"
    _stage_tls
    fx_helper tls
    tm_assert_eq "ok" "$(fx_field "d['state']")" "the certificate install failed: $(cat "$FX_RES") $(cat "${TM_TMP}/helper.out")"
    cat "${TM_TMP}/leaf.crt" "${TM_TMP}/int.crt" "${TM_TMP}/root.crt" > "${TM_TMP}/want.fullchain"
    cmp -s "${TM_TMP}/want.fullchain" "$tls/server.crt" || _tm_afail "server.crt is not leaf + chain (nginx serves one file)"
    cmp -s "${TM_TMP}/leaf.key" "$tls/server.key" || _tm_afail "server.key is not the uploaded key"
    tm_assert_mode 600 "$tls/server.key" "the installed key is not 0600"
    tm_assert_owner "root:root" "$tls/server.key" "the installed key is not root-owned"
    tm_assert_mode 644 "$tls/server.crt"
    tm_assert_file "$tls/chain.pem"
    tm_assert_eq "EC P-256" "$(fx_field "d['applied']['key_type']")" "the result does not describe what was applied"
    grep -q 'PRIVATE KEY\|BEGIN CERTIFICATE' "$FX_RES" && _tm_afail "the result file carries PEM material"
    [ -z "$(fx_staged_left)" ] || _tm_afail "staged TLS files were left behind"
    ls "$FX"/var/backups/topic-manager/apply/tls-*/ >/dev/null 2>&1 || _tm_afail "the previous pair was not backed up"
    tm_assert_mode 700 "$FX/var/backups/topic-manager/apply" "the backup directory (it holds the old key) is not 0700"
    tm_note "nginx -t: ${FX_NGINX} (real = it loaded the installed pair)"
}
tm_case "helper-installs-fullchain-and-key-0600-or-restores-exactly" "linux,chown,openssl" a_helper_installs_and_rolls_back

a_helper_refuses_a_mixed_set() {
    # The request names the SHA-256 of each staged file. A key swapped in
    # after the request was written (a second upload racing the first, or
    # anything else writing the staging directory) is refused — even though
    # the swapped key is itself a perfectly valid key for another certificate.
    . "${TM_TESTS_DIR}/lib/apply_fixture.sh"
    fx_setup
    _mk_chain
    _mk other2 -newkey ec -pkeyopt ec_paramgen_curve:P-256
    local tls="$FX/etc/topic-manager/tls" before
    before="$(fx_hash_managed)"
    PYTHONPATH="$(tm_py_root)" PYTHONSAFEPATH=1 PYTHONDONTWRITEBYTECODE=1 python3 - "$FX" "$TM_TMP" <<'PYEOF'
import sys
from tm import apply
fx, t = sys.argv[1], sys.argv[2]
rd = lambda n: open('%s/%s' % (t, n), 'rb').read()
apply.write_stage({'audit': {'db_path': fx + '/opt/topic-manager/data/tm.db'}}, 'tls', {}, 'admin',
                  files={'crt': rd('leaf.crt'), 'key': rd('leaf.key')})
PYEOF
    cp "${TM_TMP}/other2.key" "$FX/opt/topic-manager/data/apply/tls.key"
    chown -R "$FX_SVC_USER" "$FX/opt/topic-manager/data/apply"; chmod 600 "$FX/opt/topic-manager/data/apply/tls.key"
    fx_helper tls
    tm_assert_eq "failed validate" "$(fx_field "d['state'] + ' ' + d['step']")" "a mixed staged set was acted on: $(cat "$FX_RES")"
    grep -q "does not match the request" "$FX_RES" || _tm_afail "the refusal does not name the mismatch: $(cat "$FX_RES")"
    tm_assert_eq "$before" "$(fx_hash_managed)" "a refused mixed set changed the host"
    tm_assert_nofile "$FX/opt/topic-manager/data/apply/tls.key" "the refused key was left in the staging directory"
}
tm_case "helper-refuses-a-mixed-staged-set" "linux,chown,openssl" a_helper_refuses_a_mixed_set

tm_finish
