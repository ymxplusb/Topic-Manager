#!/usr/bin/env bash
# =============================================================================
# tools/sonar-local.sh — the release's SonarQube gate, run BEFORE the tag, on
# a throwaway SonarQube that never talks to the estate's server.
#
#   bash tools/sonar-local.sh --remote <user>@<linux-docker-host> [--key <ssh key>]
#   bash tools/sonar-local.sh                  # on a Linux host with docker
#   options: --base <ref> (default v1.1.1)  --head <ref> (default HEAD)
#
# WHY. The tag pipeline's scan job (ci-templates v1.5.3, build-test-publish.yml)
# runs sonar-scanner over the WHOLE tree (-Dsonar.sources=.) against the
# estate's SonarQube, whose quality gate fails the release on ANY new issue
# (new_violations > 0, new code = since the previous version). v1.1.0 found
# that out at its tag; v1.2.0's gatekeeper found 19 new issues the same way,
# after the fact. This runs the same scanner, with the same parameters, the
# same Sonar way profiles and the same new-code definition, before there is a
# tag to fail:
#
#   1. a private docker network, and sonarqube:26.9.0.129388-community on it
#      with NO published port (nothing outside the network can reach it, and
#      it reaches nothing it is not told to);
#   2. the admin password replaced by a random one and a token generated,
#      both held in this process only;
#   3. the BASE ref scanned as projectVersion <its VERSION>, then HEAD as
#      <its VERSION>: SonarQube's default new-code period is "previous
#      version", so HEAD's new code is exactly what changed since the base —
#      the same comparison the estate's server makes at the tag;
#   4. the scanner is CI's own image, pinned by digest, run as its own user
#      with CI's exact -D parameters (projectKey, projectVersion, sources=.,
#      sourceEncoding, host.url, token, qualitygate.wait) over a git
#      checkout of each ref; the repository's own sonar-project.properties
#      (its exclusions) is read from that ref's tree, as in CI;
#   5. new_violations and the new issues themselves are read back, printed
#      rule by rule, and decide the exit code;
#   6. every container and the network are removed on every exit path.
#
# NEVER UPLOADS ANYWHERE ELSE. sonar.host.url is always the throwaway
# container's name on the private network; SONAR_HOST_URL and SONAR_TOKEN
# from the environment are never passed in (docker run passes only what -e
# names).
#
# Exit: 0 = no new issue; 1 = new issues (listed); 2 = could not run (no
# docker, a ref that does not exist, the server never came up, a scan or a
# query failed). 2 is NOT a pass.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

# Pinned by digest as well as tag (measured on the docker host 2026-09-29).
SQ_IMAGE="sonarqube:26.9.0.129388-community@sha256:4905574ab8584dcac1a06c01cdc43a4ce9e369723ac4a7ab1d029c1bf71e6fe9"
# The CI scan job's image, digest-pinned exactly as ci-templates v1.5.3 pins it.
SCANNER_IMAGE="sonarsource/sonar-scanner-cli:11@sha256:46341f2c2dc560381414e90347885f5cddc716db080adcbafc1cac13e1473094"
PROJECT_KEY="topic-manager"        # .gitlab-ci.yml SONAR_PROJECT_KEY
SONAR_SOURCES="."                  # ci-templates SONAR_SOURCES default; this project sets no override
BASE_REF="v1.1.1"
HEAD_REF="HEAD"
REMOTE=""
SSH_KEY=""
BUNDLE=""
AUTH=""
UP_TIMEOUT_S=600

die2() { echo "sonar-local: COULD NOT RUN: $*" >&2; exit 2; }
say()  { echo "sonar-local: $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)   BASE_REF="${2:?--base needs a ref}"; shift ;;
        --head)   HEAD_REF="${2:?--head needs a ref}"; shift ;;
        --remote) REMOTE="${2:?--remote needs user@host}"; shift ;;
        --key)    SSH_KEY="${2:?--key needs a path}"; shift ;;
        --bundle) BUNDLE="${2:?--bundle needs a file}"; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die2 "unknown option $1" ;;
    esac
    shift
done

# ─── the two commits, as a git bundle ───────────────────────────────────────
# Resolved HERE, in the checkout the script lives in (a worktree's HEAD is its
# own, not the main checkout's), then carried as a bundle so the scan host
# needs no access to the repository. Temporary refs under refs/sonar-local/
# name them for `git bundle` and are deleted at once; no branch is touched.
make_bundle() {   # make_bundle <out-file>  -> sets base_sha head_sha
    local repo rc
    repo="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel 2>/dev/null)" || die2 "not inside a git checkout"
    base_sha="$(git -C "$repo" rev-parse --verify "${BASE_REF}^{commit}" 2>/dev/null)" || die2 "no such base ref: ${BASE_REF}"
    head_sha="$(git -C "$(dirname "$0")/.." rev-parse --verify "${HEAD_REF}^{commit}" 2>/dev/null)" || die2 "no such head ref: ${HEAD_REF}"
    git -C "$repo" update-ref refs/sonar-local/base "$base_sha" \
        && git -C "$repo" update-ref refs/sonar-local/head "$head_sha" || die2 "could not name the two commits"
    git -C "$repo" bundle create "$1" refs/sonar-local/base refs/sonar-local/head >/dev/null 2>&1
    rc=$?
    git -C "$repo" update-ref -d refs/sonar-local/base >/dev/null 2>&1
    git -C "$repo" update-ref -d refs/sonar-local/head >/dev/null 2>&1
    [[ $rc -eq 0 ]] || die2 "git bundle failed"
}

if [[ -z "$BUNDLE" ]]; then
    tmpb="$(mktemp -d)" || die2 "mktemp failed"
    trap 'rm -rf "$tmpb"' EXIT
    make_bundle "$tmpb/src.bundle"
    BUNDLE="$tmpb/src.bundle"; BASE_REF="$base_sha"; HEAD_REF="$head_sha"
fi

if [[ -n "$REMOTE" ]]; then
    ssh_opts=(-o BatchMode=yes)
    [[ -n "$SSH_KEY" ]] && ssh_opts+=(-i "$SSH_KEY")
    rdir="$(ssh "${ssh_opts[@]}" "$REMOTE" 'mktemp -d /tmp/tm-sonar-local.XXXXXX')" || die2 "cannot reach ${REMOTE}"
    scp -q "${ssh_opts[@]}" "$0" "$BUNDLE" "${REMOTE}:${rdir}/" || die2 "copy to ${REMOTE} failed"
    say "running on ${REMOTE} (${BASE_REF:0:12} -> ${HEAD_REF:0:12})"
    ssh "${ssh_opts[@]}" "$REMOTE" "bash ${rdir}/sonar-local.sh --bundle ${rdir}/src.bundle --base ${BASE_REF} --head ${HEAD_REF}"
    rc=$?
    ssh "${ssh_opts[@]}" "$REMOTE" "rm -rf ${rdir}" || say "WARNING: could not remove ${rdir} on ${REMOTE}"
    exit "$rc"
fi

# ─── local run (a Linux host with docker) ────────────────────────────────────
command -v git >/dev/null 2>&1 || die2 "git is not installed"
if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo -n docker)
else die2 "docker is not usable here (tried docker and sudo -n docker)"; fi

WORK="$(mktemp -d /tmp/tm-sonar-work.XXXXXX)" || die2 "mktemp failed"
TAG="tm-sonar-$$-$RANDOM"
NET="${TAG}-net"; SRV="${TAG}-srv"
cleanup() {
    "${DOCKER[@]}" rm -f "$SRV" "${TAG}-scan" >/dev/null 2>&1
    "${DOCKER[@]}" network rm "$NET" >/dev/null 2>&1
    # The scanner wrote as this user; nothing here is root's.
    rm -rf "$WORK" "${tmpb:-}"
}
trap cleanup EXIT
trap 'exit 2' INT TERM

# The source: a repository holding exactly the two commits (CI scans a git
# clone too, so the scanner sees SCM data as it does there).
git init -q "$WORK/src" && git -C "$WORK/src" fetch -q "$BUNDLE" '+refs/sonar-local/*:refs/sonar-local/*' 2>/dev/null \
    || die2 "cannot read the bundle ${BUNDLE}"
base_sha="$(git -C "$WORK/src" rev-parse --verify "${BASE_REF}^{commit}" 2>/dev/null)" || die2 "no such base ref: ${BASE_REF}"
head_sha="$(git -C "$WORK/src" rev-parse --verify "${HEAD_REF}^{commit}" 2>/dev/null)" || die2 "no such head ref: ${HEAD_REF}"
base_ver="$(git -C "$WORK/src" show "${base_sha}:VERSION" 2>/dev/null | tr -d '[:space:]')"
head_ver="$(git -C "$WORK/src" show "${head_sha}:VERSION" 2>/dev/null | tr -d '[:space:]')"
[[ -n "$base_ver" && -n "$head_ver" ]] || die2 "VERSION is missing at one of the refs"
# A new-code period of "previous version" needs two different versions.
[[ "$head_ver" != "$base_ver" ]] || head_ver="${head_ver}+${head_sha:0:12}"

say "server ${SQ_IMAGE%%@*} (pinned), scanner ${SCANNER_IMAGE%%@*} (pinned), base ${BASE_REF} ${base_sha:0:12} as ${base_ver}, head ${head_sha:0:12} as ${head_ver}"
"${DOCKER[@]}" network create --internal=false "$NET" >/dev/null || die2 "docker network create failed"
# No -p: the server is reachable ONLY on the private network.
"${DOCKER[@]}" run -d --rm --name "$SRV" --network "$NET" \
    -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true -e SONAR_TELEMETRY_ENABLE=false \
    "$SQ_IMAGE" >/dev/null || die2 "could not start ${SQ_IMAGE}"

api() {   # api <method> <path?query> [user:pass] — through the server container itself
    local auth="${3:-$AUTH}"
    "${DOCKER[@]}" exec "$SRV" curl -s -f -X "$1" -u "$auth" "http://localhost:9000/api/$2"
}

say "waiting for SonarQube (up to ${UP_TIMEOUT_S}s) ..."
up=""
for ((i = 0; i < UP_TIMEOUT_S; i += 5)); do
    st="$("${DOCKER[@]}" exec "$SRV" curl -s http://localhost:9000/api/system/status 2>/dev/null || true)"
    case "$st" in *'"status":"UP"'*) up=1; break ;; esac
    sleep 5
done
[[ -n "$up" ]] || die2 "SonarQube did not come up within ${UP_TIMEOUT_S}s"

PW="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')Aa1!"
api POST "users/change_password?login=admin&previousPassword=admin&password=${PW}" admin:admin >/dev/null \
    || die2 "could not replace the default admin password"
AUTH="admin:${PW}"
TOKEN="$(api POST "user_tokens/generate?name=sonar-local-$$" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2>/dev/null)"
[[ -n "$TOKEN" ]] || die2 "could not generate a scanner token"
AUTH="${TOKEN}:"

# WHAT "NEW" MEANS, AND WHY THE SCANNED REPOSITORY IS REWRITTEN. SonarQube
# decides new code LINE BY LINE from `git blame`: a line is new when its commit
# is dated after the new-code period began (the base analysis). Scanning the
# real history would therefore call nothing new — every commit being checked
# was made BEFORE this throwaway server's base analysis — and report a false 0
# (measured 2026-09-29: new_violations=0 on the tree the estate's gate found 19
# in). So each ref's TRACKED tree (all of it, as CI's clone has it) is
# committed afresh into a scratch repository just before it is scanned: every
# line the head changed is blamed to a commit made after the base analysis,
# every line it did not change keeps the base's commit. "New" is then exactly
# "changed since the base", whatever the commits' dates — never less than the
# tag's scan counts.
git init -q "$WORK/scan" && git -C "$WORK/scan" config user.name sonar-local \
    && git -C "$WORK/scan" config user.email sonar-local@localhost || die2 "cannot create the scan repository"
stage_tree() {   # stage_tree <sha> — the scan repository's next commit is exactly that tree
    find "$WORK/scan" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + || die2 "cannot clear the scan tree"
    git -C "$WORK/src" --work-tree="$WORK/scan" checkout -q --force "$1" -- . 2>/dev/null || die2 "checkout of ${1} failed"
    git -C "$WORK/scan" add -A && git -C "$WORK/scan" commit -q --allow-empty -m "sonar-local ${1}" \
        || die2 "cannot commit ${1} into the scan repository"
    sleep 2       # blame dates are whole seconds; keep them after the last analysis
}

scan() {   # scan <sha> <projectVersion>
    stage_tree "$1"
    say "scanning ${1:0:12} as ${2} ..."
    # As CI runs it: the image's own user and working directory
    # (SCANNER_WORKDIR_PATH=/tmp/.scannerwork, inside the container). The
    # source is mounted READ-ONLY, so the scan cannot change what it reads and
    # leaves nothing on this host. SONAR_USER_HOME stays the image's: CI points
    # it into the project directory only to cache plugin jars between jobs,
    # which no analyser reads.
    chmod -R a+rX "$WORK/scan"
    "${DOCKER[@]}" run --rm --name "${TAG}-scan" --network "$NET" \
        -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/usr/src \
        -v "$WORK/scan:/usr/src:ro" -w /usr/src "$SCANNER_IMAGE" \
        sonar-scanner \
        -Dsonar.projectKey="$PROJECT_KEY" \
        -Dsonar.projectVersion="$2" \
        -Dsonar.sources="$SONAR_SOURCES" \
        -Dsonar.sourceEncoding=UTF-8 \
        -Dsonar.host.url="http://${SRV}:9000" \
        -Dsonar.token="$TOKEN" \
        -Dsonar.qualitygate.wait=true \
        > "$WORK/scan-$2.log" 2>&1
    local rc=$?
    grep -q 'EXECUTION SUCCESS\|QUALITY GATE STATUS' "$WORK/scan-$2.log" || {
        tail -30 "$WORK/scan-$2.log" >&2
        die2 "the scan of ${1:0:12} did not complete (scanner exit ${rc})"
    }
    grep -E 'files indexed|QUALITY GATE STATUS' "$WORK/scan-$2.log" | sed 's/^/    /'
}

scan "$base_sha" "$base_ver"
scan "$head_sha" "$head_ver"

m="$(api GET "measures/component?component=${PROJECT_KEY}&metricKeys=new_violations,violations")" \
    || die2 "could not read the measures"
read -r new_v total_v < <(python3 -c '
import json, sys
d = json.load(sys.stdin)["component"]["measures"]
get = lambda k: next((x.get("period", {}).get("value", x.get("value")) for x in d if x["metric"] == k), None)
print(get("new_violations"), get("violations"))' <<<"$m")
[[ "$new_v" =~ ^[0-9]+$ ]] || die2 "new_violations was not reported (${m:0:200})"

issues="$(api GET "issues/search?componentKeys=${PROJECT_KEY}&inNewCodePeriod=true&resolved=false&ps=500")" \
    || die2 "could not read the new issues"
python3 -c '
import json, sys
d = json.load(sys.stdin)
for i in sorted(d.get("issues", []), key=lambda i: (i["component"], i.get("line", 0))):
    print("  NEW  %-12s %s:%s  %s" % (i["rule"].split(":")[-1], i["component"].split(":", 1)[-1],
                                      i.get("line", "-"), i["message"]))' <<<"$issues"

# The verdict is new_violations (the condition that stopped v1.1.0). The rest
# is REPORTED so nothing is hidden: this server's own Sonar way gate fails on
# coverage (no report is ever sent, here or in CI), and the estate's gate
# (measured 2026-09-28) also holds bugs, vulnerabilities, reliability, new
# duplication and hotspot review — a NEW security hotspot needs a human review
# on the estate's server before the tag, so it is named here as a WARN.
extra="$(api GET "measures/component?component=${PROJECT_KEY}&metricKeys=bugs,vulnerabilities,reliability_rating,new_duplicated_lines_density,new_security_hotspots")" || extra='{}'
python3 -c '
import json, sys
try:
    d = {x["metric"]: x.get("period", {}).get("value", x.get("value")) for x in json.load(sys.stdin)["component"]["measures"]}
except Exception:
    d = {}
warn = []
if d.get("bugs") not in (None, "0"): warn.append("bugs=%s" % d["bugs"])
if d.get("vulnerabilities") not in (None, "0"): warn.append("vulnerabilities=%s" % d["vulnerabilities"])
if d.get("reliability_rating") not in (None, "1.0", "1"): warn.append("reliability_rating=%s" % d["reliability_rating"])
if d.get("new_duplicated_lines_density") and float(d["new_duplicated_lines_density"]) > 3: warn.append("new_duplicated_lines_density=%s%%" % d["new_duplicated_lines_density"])
if d.get("new_security_hotspots") not in (None, "0"): warn.append("new_security_hotspots=%s (each needs a review on the estate server before the tag)" % d["new_security_hotspots"])
print("sonar-local: also: " + ", ".join("%s=%s" % kv for kv in sorted(d.items())))
for w in warn: print("sonar-local: WARN (the estate gate holds this too): " + w)' <<<"$extra"
gate="$(api GET "qualitygates/project_status?projectKey=${PROJECT_KEY}" | python3 -c '
import json, sys
p = json.load(sys.stdin)["projectStatus"]
bad = [c["metricKey"] for c in p.get("conditions", []) if c.get("status") == "ERROR"]
print(p["status"] + (" (conditions failing on this throwaway Sonar way gate: " + ", ".join(bad) + ")" if bad else ""))' 2>/dev/null || echo '?')"
say "HEAD ${head_sha:0:12} vs ${BASE_REF}: new_violations=${new_v} (all issues ${total_v}); quality gate ${gate}"
if [[ "$new_v" -gt 0 ]]; then
    say "FAIL: ${new_v} new issue(s) - the tag's Sonar gate would fail on these"
    exit 1
fi
say "PASS: 0 new issues"
exit 0
