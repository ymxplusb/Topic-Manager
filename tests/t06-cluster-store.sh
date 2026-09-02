#!/usr/bin/env bash
# =============================================================================
# t06 — THE CLUSTER STORE: atomic save, cert containment, validation.
#
# These drive tm/clusters.py itself, imported from the repo. There is no
# pytest here and adding one would move requirements.txt, so the cases are
# bash + python3 -c against the real module — the same rule the rest of this
# suite follows: never re-implement the logic in the test.
#
# What each case exists to catch:
#   atomic-save     a truncate-then-write save. Four gunicorn workers can save
#                   concurrently, and an interrupted truncate loses every
#                   profile. The assertion is on the INODE: os.replace makes a
#                   new one, an in-place rewrite does not.
#   no-temp-left    a save that leaves its temp file behind, which the next
#                   load would not see but an operator would.
#   cert-escape     a hand-edited clusters.yaml pointing ssl_cafile at
#                   config.yaml. That is the file-read oracle this whole
#                   design exists to close, because test_cluster returns
#                   librdkafka's error verbatim and any authenticated user can
#                   download the audit CSV.
#   duplicate-*     two profiles that shadow each other.
#   cert-content    a path where PEM content is expected must be REFUSED, not
#                   stored. Accepting a path is the oracle.
#   audit-redaction sasl_password must never reach the audit detail.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "cluster store: atomic save, path containment, validation"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python interpreter found"
"$PY" -c "import yaml, cryptography" >/dev/null 2>&1 \
    || tm_die "python is present but PyYAML/cryptography are not importable — this
        case set drives tm/clusters.py directly and cannot run without them."

# Every case runs a snippet with tm/ importable and the store pointed at a
# scratch directory. TM_CLUSTERS_DIR / TM_CLUSTER_CERT_DIR are the same
# environment variables the systemd unit sets, so the test configures the
# module exactly the way production does.
_py() {
    PYTHONPATH="$TM_REPO_ROOT" \
    PYTHONDONTWRITEBYTECODE=1 \
    TM_CLUSTERS_DIR="${TM_TMP}/clusters.d" \
    TM_CLUSTER_CERT_DIR="${TM_TMP}/cluster-certs" \
        "$PY" -c "$1" 2>&1 | tr -d '\r'
    # CR stripped: python on the Windows workstation writes CRLF, and a
    # comparison against an LF-only expectation then fails for a reason
    # that has nothing to do with the code — contract
    # hazards[windows-clone-crlf].
}

_mkdirs() { mkdir -p "${TM_TMP}/clusters.d" "${TM_TMP}/cluster-certs"; }

# A real, parseable self-signed certificate and its key, generated once per
# case. Hand-written PEM-shaped strings would test the regex, not the parser.
_mkpem() {
    _py "
import os
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
import datetime
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, u'tm-test')])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now).not_valid_after(now + datetime.timedelta(days=1))
        .sign(key, hashes.SHA256()))
open(os.environ['TM_TMP'] + '/test.crt','wb').write(
    cert.public_bytes(serialization.Encoding.PEM))
open(os.environ['TM_TMP'] + '/test.key','wb').write(
    key.private_bytes(serialization.Encoding.PEM,
                      serialization.PrivateFormat.TraditionalOpenSSL,
                      serialization.NoEncryption()))
print('PEMOK')
"
}

# ─── the atomic save ─────────────────────────────────────────────────────────
c_atomic_save_replaces_the_inode() {
    _mkdirs
    OUT="$(_py "
import os
from tm import clusters
p = clusters.clusters_path()
clusters.save_clusters([{'id':'a','name':'A','bootstrap_servers':'h:9092',
                         'security_protocol':'PLAINTEXT','active':True}])
first = os.stat(p).st_ino
clusters.save_clusters([{'id':'a','name':'A','bootstrap_servers':'h:9092',
                         'security_protocol':'PLAINTEXT','active':True},
                        {'id':'b','name':'B','bootstrap_servers':'h:9093',
                         'security_protocol':'PLAINTEXT','active':False}])
second = os.stat(p).st_ino
print('SAME' if first == second else 'REPLACED')
")"
    tm_assert_eq "REPLACED" "$OUT" \
        "the second save did not replace the file. An in-place rewrite keeps the
        inode, which means truncate-then-write: an interrupted save loses every
        cluster profile and two of the four workers can interleave"
}
tm_case "atomic-save-replaces-rather-than-truncates" none c_atomic_save_replaces_the_inode

c_atomic_save_leaves_no_temp_file() {
    _mkdirs
    _py "
from tm import clusters
clusters.save_clusters([{'id':'a','name':'A','bootstrap_servers':'h:9092',
                         'security_protocol':'PLAINTEXT','active':True}])
" >/dev/null
    LEFT="$(find "${TM_TMP}/clusters.d" -name '.clusters-*' | wc -l | tr -d ' ')"
    tm_assert_eq "0" "$LEFT" "a temp file was left behind in clusters.d"
    tm_assert_file "${TM_TMP}/clusters.d/clusters.yaml" "clusters.yaml was not written"
}
tm_case "atomic-save-leaves-no-temp-file" none c_atomic_save_leaves_no_temp_file

c_save_is_readable_back() {
    _mkdirs
    OUT="$(_py "
from tm import clusters
clusters.save_clusters([{'id':'x','name':'X','bootstrap_servers':'h:9092',
                         'security_protocol':'PLAINTEXT','active':True}])
clusters.invalidate_cache()
got = clusters.load_clusters()
print('%d:%s' % (len(got), got[0]['id']))
")"
    tm_assert_eq "1:x" "$OUT" "what was saved did not come back"
}
tm_case "saved-profiles-load-back" none c_save_is_readable_back

# ─── the cache that must converge across four workers ────────────────────────
c_cache_reloads_on_change() {
    _mkdirs
    OUT="$(_py "
from tm import clusters
clusters.save_clusters([{'id':'a','name':'A','bootstrap_servers':'h:9092',
                         'security_protocol':'PLAINTEXT','active':True}])
before = len(clusters.load_clusters())
# Simulate ANOTHER worker saving: write through a fresh path, then read again
# WITHOUT invalidating this process's cache. A cache that returns forever
# after the first load reports 1 here, which is the defect that made a new
# cluster appear on roughly one request in four.
import yaml, os, tempfile
d = clusters.clusters_dir()
fd, tmp = tempfile.mkstemp(dir=d)
os.write(fd, yaml.safe_dump({'clusters':[
    {'id':'a','name':'A','bootstrap_servers':'h:9092','security_protocol':'PLAINTEXT','active':True},
    {'id':'b','name':'B','bootstrap_servers':'h:9093','security_protocol':'PLAINTEXT','active':False},
]}).encode())
os.close(fd)
os.replace(tmp, clusters.clusters_path())
print('%d->%d' % (before, len(clusters.load_clusters())))
")"
    tm_assert_eq "1->2" "$OUT" \
        "the store did not notice a write made by another process. With four
        gunicorn workers that means a newly added cluster shows up on about one
        request in four, which presents as an intermittent Kafka fault"
}
tm_case "store-reloads-when-another-worker-writes" none c_cache_reloads_on_change

# ─── the file-read oracle ────────────────────────────────────────────────────
c_cert_path_outside_certdir_is_refused() {
    _mkdirs
    printf 'server:\n  secret_key: "SUPERSECRET"\n' > "${TM_TMP}/config.yaml"
    cat > "${TM_TMP}/clusters.d/clusters.yaml" <<YAML
clusters:
  - id: evil
    name: Evil
    bootstrap_servers: "h:9092"
    security_protocol: SSL
    ssl_cafile: "${TM_TMP}/config.yaml"
    active: true
YAML
    # Asserted with grep, not string equality: the module logs the refusal at
    # ERROR, and that log line is part of what this case wants to see. An
    # equality assertion would fail on the evidence.
    _py "
from tm import clusters
c = clusters.load_clusters()[0]
print('cafile=%r disabled=%s' % (c.get('ssl_cafile'), bool(c.get('disabled'))))
" > "${TM_TMP}/out"
    tm_assert_grep "cafile=None disabled=True" "${TM_TMP}/out" \
        "a hand-edited clusters.yaml pointing ssl_cafile at config.yaml was
        loaded as-is. librdkafka would then open the file holding secret_key and
        ldap_bind_password and test_cluster would hand the parse error back
        verbatim to any authenticated user"
    tm_assert_grep "resolves outside" "${TM_TMP}/out" \
        "the refusal happened silently. A cluster that stops working without
        saying why is a cluster an operator will spend an afternoon on"
    tm_assert_nogrep "SUPERSECRET" "${TM_TMP}/out" \
        "the contents of the targeted file were echoed back"
}
tm_case "cert-path-outside-the-cert-dir-is-refused-on-load" none c_cert_path_outside_certdir_is_refused

c_cert_upload_rejects_a_path() {
    _mkdirs
    OUT="$(_py "
from tm import clusters
try:
    clusters.store_cert('c1', 'ssl_cafile', '/etc/topic-manager/config.yaml')
    print('ACCEPTED')
except clusters.ClusterError:
    print('REFUSED')
")"
    tm_assert_eq "REFUSED" "$OUT" \
        "a filesystem PATH was accepted where PEM CONTENT is required. Accepting
        a path IS the arbitrary-file-read primitive"
}
tm_case "a-path-is-refused-where-pem-content-is-required" none c_cert_upload_rejects_a_path

c_cert_upload_stores_under_the_cert_dir() {
    _mkdirs
    tm_assert_eq "PEMOK" "$(_mkpem)" "could not build a test certificate"
    OUT="$(_py "
import os
from tm import clusters
pem = open(os.environ['TM_TMP'] + '/test.crt').read()
path = clusters.store_cert('c1', 'ssl_cafile', pem)
root = os.path.realpath(clusters.cert_dir())
print('%s|%s' % (os.path.realpath(path).startswith(root + os.sep),
                 os.path.basename(path).startswith('c1-ca-')))
")"
    tm_assert_eq "True|True" "$OUT" \
        "uploaded PEM was not stored under the cert directory with a
        server-generated name"
}
tm_case "uploaded-pem-lands-in-the-cert-dir-with-a-generated-name" none c_cert_upload_stores_under_the_cert_dir

c_garbage_pem_is_refused() {
    _mkdirs
    OUT="$(_py "
from tm import clusters
for body in ('-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydA==\n-----END CERTIFICATE-----\n',
             'just some text'):
    try:
        clusters.store_cert('c1', 'ssl_cafile', body)
        print('ACCEPTED')
    except clusters.ClusterError:
        print('REFUSED')
")"
    tm_assert_eq "REFUSED
REFUSED" "$OUT" "PEM that does not parse as a certificate was stored anyway"
}
tm_case "unparseable-pem-is-refused" none c_garbage_pem_is_refused

# ─── validation: shadowing and shape ─────────────────────────────────────────
c_duplicate_id_is_refused() {
    _mkdirs
    OUT="$(_py "
from tm import clusters
existing = [{'id':'a','name':'A','bootstrap_servers':'h:9092','security_protocol':'PLAINTEXT'}]
for data in ({'id':'a','name':'Other','bootstrap_servers':'h:9092'},
             {'id':'b','name':'B','bootstrap_servers':'h:9092'},
             {'id':'b','name':'A','bootstrap_servers':'h:9092'}):
    try:
        clusters.validate(data, existing, cluster_id=None)
        print('ACCEPTED')
    except clusters.ClusterError:
        print('REFUSED')
")"
    tm_assert_eq "REFUSED
ACCEPTED
REFUSED" "$OUT" \
        "a profile that collides on id or name with an existing one was
        accepted — two profiles the operator cannot tell apart, and a
        get_cluster_by_id that returns whichever comes first"
}
tm_case "duplicate-id-or-name-is-refused" none c_duplicate_id_is_refused

c_a_profile_may_keep_its_own_id_and_name() {
    _mkdirs
    OUT="$(_py "
from tm import clusters
existing = [{'id':'a','name':'A','bootstrap_servers':'h:9092','security_protocol':'PLAINTEXT'}]
c = clusters.validate({'id':'a','name':'A','bootstrap_servers':'h:9099'},
                      existing, cluster_id='a')
print(c['bootstrap_servers'])
")"
    tm_assert_eq "h:9099" "$OUT" "editing a profile collided with itself"
}
tm_case "editing-a-profile-does-not-collide-with-itself" none c_a_profile_may_keep_its_own_id_and_name

c_bad_shapes_are_refused() {
    _mkdirs
    OUT="$(_py "
from tm import clusters
bad = [
    {'id':'../escape','name':'X','bootstrap_servers':'h:9092'},
    {'id':'a b','name':'X','bootstrap_servers':'h:9092'},
    {'id':'a','name':'X','bootstrap_servers':'http://h:9092'},
    {'id':'a','name':'X','bootstrap_servers':'h:9092 ; rm -rf /'},
    {'id':'a','name':'X','bootstrap_servers':'h:9092','security_protocol':'SASL_PLAINTEXT'},
    {'id':'a','name':'X','bootstrap_servers':'h:9092','security_protocol':'SASL_SSL'},
]
for data in bad:
    try:
        clusters.validate(data, [], cluster_id=None)
        print('ACCEPTED %s' % data)
    except clusters.ClusterError:
        print('REFUSED')
")"
    tm_assert_eq "REFUSED
REFUSED
REFUSED
REFUSED
REFUSED
REFUSED" "$OUT" "a malformed cluster definition was accepted"
}
tm_case "malformed-cluster-definitions-are-refused" none c_bad_shapes_are_refused

# ─── what leaves the process ─────────────────────────────────────────────────
c_secrets_never_leave() {
    _mkdirs
    OUT="$(_py "
from tm import clusters
c = {'id':'s','name':'S','bootstrap_servers':'h:9093','security_protocol':'SASL_SSL',
     'sasl_mechanism':'PLAIN','sasl_username':'svc','sasl_password':'hunter2',
     'ssl_cafile':'/opt/topic-manager/data/cluster-certs/s-ca-deadbeef.pem','active':True}
view = clusters.public_view(c)
detail = clusters.audit_detail(c)
print('view_pw=%s view_has=%s' % ('sasl_password' in view, view['has_sasl_password']))
print('view_ca=%s' % view['ssl_cafile'])
print('detail_pw=%s detail_path=%s' % ('hunter2' in detail, '/opt/' in detail))
print('detail_basename=%s' % ('s-ca-deadbeef.pem' in detail))
")"
    # view_ca is the BASENAME. Closing mutation control P6, which SURVIVED on
    # 2026-09-01: public_view was changed to return the full filesystem path
    # and nothing noticed. The UI only ever needs to say "a CA is loaded", and
    # a full path handed to every authenticated user is free reconnaissance.
    tm_assert_eq "view_pw=False view_has=True
view_ca=s-ca-deadbeef.pem
detail_pw=False detail_path=False
detail_basename=True" "$OUT" \
        "sasl_password or a full cert path reached the API response or the audit
        detail. /api/audit/export hands detail to any authenticated user as a
        CSV and AuditTab renders it on screen"
}
tm_case "sasl-password-and-cert-paths-never-leave-the-process" none c_secrets_never_leave

tm_finish
