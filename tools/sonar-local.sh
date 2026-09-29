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
# estate's SonarQube, whose quality gate ("Jarvis Standard") fails the
# release on ANY new issue (new_violations > 0, new code = since the previous
# version) and on duplication, hotspot review, bugs, vulnerabilities and
# reliability too. v1.1.0 found
# that out at its tag; v1.2.0's gatekeeper found 19 new issues the same way,
# after the fact. This runs the same scanner, with the same parameters, the
# same Sonar way profiles, the same new-code definition and a copy of the
# estate's quality gate, before there is a tag to fail:
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
#   5. the project is held to a copy of the estate's gate, "Jarvis Standard"
#      (JARVIS_GATE below, read from the estate server 2026-09-29), and EVERY
#      condition is evaluated: the three new-code ones (new_violations,
#      new_duplicated_lines_density, new_security_hotspots_reviewed) and
#      bugs, vulnerabilities and reliability_rating decide the exit code; the
#      two things a throwaway server cannot know are said, not hidden
#      (KNOWN DIFFERENCES, below);
#   6. every container, every volume and the network are removed on every
#      exit path; a server that dies while starting fails the run at once, and
#      a docker host whose disk is 90% full is refused before anything starts.
#
# NEVER UPLOADS ANYWHERE ELSE. sonar.host.url is always the throwaway
# container's name on the private network; SONAR_HOST_URL and SONAR_TOKEN
# from the environment are never passed in (docker run passes only what -e
# names).
#
# Exit: 0 = every gate condition passes; 1 = a condition fails (issues
# listed); 2 = could not run (no docker, a full docker disk, a ref that does
# not exist, the server died or never came up, a scan or a query failed, a
# gate condition that could not be read). 2 is NOT a pass.
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
UP_TIMEOUT_S="${TM_SONAR_UP_TIMEOUT_S:-600}"   # the suite shortens it (t46)
DISK_MAX_PCT=90                    # refuse a docker host at or above this use of its data disk

# THE ESTATE GATE, as the estate server defines it (api/qualitygates/show,
# name "Jarvis Standard", the gate project topic-manager is assigned; read
# 2026-09-29, SonarQube 26.9.0.129388). NOT "Sonar way": that is the server
# default, and this project is not on it. <metric> <op> <error>; new code =
# previous version (the project inherits PREVIOUS_VERSION).
JARVIS_GATE=(
  "new_violations GT 0"
  "new_duplicated_lines_density GT 3"
  "new_security_hotspots_reviewed LT 100"
  "bugs GT 0"
  "vulnerabilities GT 0"
  "reliability_rating GT 1"
  "security_hotspots_reviewed LT 100"
)
# KNOWN DIFFERENCES between this throwaway server and the estate's, each named
# in the output whenever it applies — never silently:
#   * vulnerabilities: python S4502 at tm/app.py ("disabling CSRF protection",
#     pre-existing since v1.0.x) is a VULNERABILITY here and a reviewed
#     security hotspot on the estate server, whose vulnerabilities is 0. Any
#     OTHER open vulnerability fails the run.
#   * security_hotspots_reviewed (overall): hotspot reviews are the estate
#     server's state; a throwaway server has none, so every pre-existing
#     hotspot is "unreviewed" here. Reported, not the verdict. A NEW hotspot
#     is held by new_security_hotspots_reviewed, which IS the verdict.
KNOWN_VULN_DIFFERENCES=("S4502 tm/app.py")

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

# evaluate_gate <dir> <gate-name> <label> — the exit code, from the four API
# answers saved in <dir> (v-gate, v-status, v-measures, v-vulns .json). Every
# condition in JARVIS_GATE must be ACCOUNTED FOR: evaluated by the server, or
# absent from both the gate status and the measures (nothing new to measure).
# A condition the server did not evaluate although its metric has a value
# means the gate here is not the gate declared: exit 2, never a pass.
evaluate_gate() {   # evaluate_gate <dir> <gate-name> <label>
    python3 - "$1" "$2" "$3" "${JARVIS_GATE[@]}" -- "${KNOWN_VULN_DIFFERENCES[@]}" <<'PYGATE'
import json, sys
d, gate_name, label = sys.argv[1:4]
rest = sys.argv[4:]
sep = rest.index("--")
conds = [c.split() for c in rest[:sep]]
known = [k.split(None, 1) for k in rest[sep + 1:]]
load = lambda n: json.load(open("%s/v-%s.json" % (d, n)))
say = lambda m: print("sonar-local: " + m)
try:
    got_gate = load("gate")["qualityGate"]["name"]
    status = load("status")["projectStatus"]
    measures = {m["metric"]: m.get("period", {}).get("value", m.get("value"))
                for m in load("measures")["component"]["measures"]}
    vulns = load("vulns").get("issues", [])
except Exception as e:
    say("COULD NOT RUN: unreadable gate answer (%s)" % e); sys.exit(2)
if got_gate != gate_name:
    say("COULD NOT RUN: the project is on gate %r, not %r" % (got_gate, gate_name)); sys.exit(2)
by_metric = {c.get("metricKey"): c for c in status.get("conditions", [])}
fail, unknown = [], []
for metric, op, err in conds:
    c = by_metric.get(metric)
    if c is None:
        if measures.get(metric) not in (None, ""):
            unknown.append(metric)
            say("  %-32s %s %s  NOT EVALUATED although it has a value (%s)" % (metric, op, err, measures[metric]))
        else:
            say("  %-32s %s %s  no value (nothing new to measure): OK" % (metric, op, err))
        continue
    actual, st = c.get("actualValue", "?"), c.get("status", "?")
    if st == "OK":
        say("  %-32s %s %s  actual %s: OK" % (metric, op, err, actual)); continue
    if metric == "vulnerabilities":
        def is_known(i):
            rule = i["rule"].split(":")[-1]; path = i["component"].split(":", 1)[-1]
            return any(rule == k[0] and path == k[1] for k in known)
        other = [i for i in vulns if not is_known(i)]
        for i in vulns:
            say("    VULN %s %s:%s  %s%s" % (i["rule"].split(":")[-1], i["component"].split(":", 1)[-1],
                i.get("line", "-"), i["message"], "  [KNOWN DIFFERENCE: a reviewed hotspot on the estate server]" if is_known(i) else ""))
        if len(vulns) != int(float(actual)):
            unknown.append(metric)
            say("  %-32s %s %s  actual %s but %d listed: cannot attribute" % (metric, op, err, actual, len(vulns)))
        elif other:
            fail.append(metric); say("  %-32s %s %s  actual %s: FAIL" % (metric, op, err, actual))
        else:
            say("  %-32s %s %s  actual %s: OK on the estate (every one is a KNOWN DIFFERENCE, listed above)" % (metric, op, err, actual))
        continue
    if metric == "security_hotspots_reviewed":
        say("  %-32s %s %s  actual %s here: KNOWN DIFFERENCE, not the verdict (reviews are the estate server's state; new hotspots are held by new_security_hotspots_reviewed)" % (metric, op, err, actual))
        continue
    fail.append(metric); say("  %-32s %s %s  actual %s: FAIL" % (metric, op, err, actual))
say("HEAD %s: new_violations=%s (all issues %s); gate %s" % (label, measures.get("new_violations", "?"),
    measures.get("violations", "?"), gate_name))
if unknown:
    say("COULD NOT RUN: condition(s) not evaluable: %s" % ", ".join(unknown)); sys.exit(2)
if fail:
    say("FAIL: %s - the tag's Sonar gate would fail on these" % ", ".join(fail)); sys.exit(1)
say("PASS: every condition of the estate gate holds (%d conditions)" % len(conds))
sys.exit(0)
PYGATE
}

# ─── local run (a Linux host with docker) ────────────────────────────────────
command -v git >/dev/null 2>&1 || die2 "git is not installed"
if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo -n docker)
else die2 "docker is not usable here (tried docker and sudo -n docker)"; fi

# A FULL DOCKER DISK. The server needs ~800 MB of volumes per run, and the
# usual docker host here is the GitLab server: at 90% it is refused before
# anything is pulled or started, with the numbers, not after a 600 s wait.
droot="$("${DOCKER[@]}" info -f '{{.DockerRootDir}}' 2>/dev/null)"
[[ -n "$droot" ]] || die2 "docker did not report its data directory"
dpct="$(df -P "$droot" 2>/dev/null | awk 'NR == 2 { sub("%", "", $5); print $5 }')"
[[ "$dpct" =~ ^[0-9]+$ ]] || die2 "could not measure the disk holding ${droot}"
if (( dpct >= DISK_MAX_PCT )); then
    die2 "the docker disk (${droot}) is ${dpct}% full (limit ${DISK_MAX_PCT}%). Free space first: sudo docker volume ls; sudo docker system df"
fi

WORK="$(mktemp -d /tmp/tm-sonar-work.XXXXXX)" || die2 "mktemp failed"
TAG="tm-sonar-$$-$RANDOM"
NET="${TAG}-net"; SRV="${TAG}-srv"
VOL_LABEL="tm-sonar-local=${TAG}"
cleanup() {
    # -v: the containers' anonymous volumes too. Without it every run left
    # the server's ~800 MB behind (four VOLUMEs in the image).
    "${DOCKER[@]}" rm -f -v "$SRV" "${TAG}-scan" >/dev/null 2>&1
    local v left
    for v in $("${DOCKER[@]}" volume ls -q --filter "label=${VOL_LABEL}" 2>/dev/null); do
        "${DOCKER[@]}" volume rm -f "$v" >/dev/null 2>&1
    done
    "${DOCKER[@]}" network rm "$NET" >/dev/null 2>&1
    left="$("${DOCKER[@]}" volume ls -q --filter "label=${VOL_LABEL}" 2>/dev/null)"
    [[ -z "$left" ]] || echo "sonar-local: WARNING: volumes left behind: ${left//$'\n'/ } (sudo docker volume rm them)" >&2
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
# Every VOLUME the image declares becomes a NAMED volume carrying this run's
# label, so cleanup can find and remove each one by label, whatever the image
# declares and however the run ends.
"${DOCKER[@]}" image inspect "$SQ_IMAGE" >/dev/null 2>&1 || "${DOCKER[@]}" pull -q "$SQ_IMAGE" >/dev/null \
    || die2 "could not pull ${SQ_IMAGE}"
vol_args=(); n=0
for vpath in $("${DOCKER[@]}" image inspect -f '{{range $k, $v := .Config.Volumes}}{{$k}} {{end}}' "$SQ_IMAGE"); do
    n=$((n + 1))
    "${DOCKER[@]}" volume create --label "$VOL_LABEL" "${TAG}-vol${n}" >/dev/null || die2 "docker volume create failed"
    vol_args+=(-v "${TAG}-vol${n}:${vpath}")
done
# No -p: the server is reachable ONLY on the private network. No --rm: a
# server that dies while starting must still be there to read its logs from.
"${DOCKER[@]}" run -d --name "$SRV" --network "$NET" "${vol_args[@]}" \
    -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true -e SONAR_TELEMETRY_ENABLE=false \
    "$SQ_IMAGE" >/dev/null || die2 "could not start ${SQ_IMAGE}"

api() {   # api <method> <path?query> [user:pass] — through the server container itself
    local auth="${3:-$AUTH}"
    "${DOCKER[@]}" exec "$SRV" curl -s -f -X "$1" -u "$auth" "http://localhost:9000/api/$2"
}

say "waiting for SonarQube (up to ${UP_TIMEOUT_S}s) ..."
up=""
for ((i = 0; i < UP_TIMEOUT_S; i += 5)); do
    # A server that has DIED will never answer: say so now, with its last
    # words, instead of polling a corpse for the whole timeout.
    running="$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$SRV" 2>/dev/null || true)"
    if [[ "$running" != true ]]; then
        "${DOCKER[@]}" logs --tail 25 "$SRV" 2>&1 | sed 's/^/    /' >&2
        die2 "the SonarQube container stopped while starting (state: ${running:-gone}; exit $("${DOCKER[@]}" inspect -f '{{.State.ExitCode}}' "$SRV" 2>/dev/null || echo '?'))"
    fi
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

# The estate's gate, condition for condition, made this project's gate here.
GATE_NAME="Jarvis Standard (sonar-local copy)"
qname="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$GATE_NAME")"
api POST "qualitygates/create?name=${qname}" >/dev/null || die2 "could not create the gate copy"
# A new gate is NOT empty: SonarQube seeds it with its own Clean-as-You-Code
# conditions (measured 2026-09-29: adding new_violations then failed as a
# duplicate). Remove every seeded condition, add exactly the declared ones,
# and read the gate back: it must hold those and nothing else.
gate_conditions() {   # gate_conditions -> "id metric op error" per line
    api GET "qualitygates/show?name=${qname}" | python3 -c '
import json, sys
for c in json.load(sys.stdin).get("conditions", []):
    print(c["id"], c["metric"], c["op"], c.get("error", ""))'
}
seeded="$(gate_conditions)" || die2 "could not read the new gate"
while read -r cid _; do
    [[ -n "$cid" ]] || continue
    api POST "qualitygates/delete_condition?id=${cid}" >/dev/null || die2 "could not remove a seeded condition from the gate copy"
done <<<"$seeded"
for c in "${JARVIS_GATE[@]}"; do
    read -r cm cop cerr <<<"$c"
    api POST "qualitygates/create_condition?gateName=${qname}&metric=${cm}&op=${cop}&error=${cerr}" >/dev/null \
        || die2 "could not add the gate condition ${c}"
done
api POST "qualitygates/set_as_default?name=${qname}" >/dev/null || die2 "could not make the gate copy the default"
have="$(gate_conditions | cut -d' ' -f2- | sort)" || die2 "could not read the gate copy back"
want="$(printf '%s\n' "${JARVIS_GATE[@]}" | sort)"
[[ "$have" == "$want" ]] || die2 "the gate copy is not the declared gate: has [${have//$'\n'/; }]"
say "gate: ${GATE_NAME}, ${#JARVIS_GATE[@]} conditions, read back identical"

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

# ─── the verdict ─────────────────────────────────────────────────────────────
issues="$(api GET "issues/search?componentKeys=${PROJECT_KEY}&inNewCodePeriod=true&resolved=false&ps=500")" \
    || die2 "could not read the new issues"
python3 -c '
import json, sys
d = json.load(sys.stdin)
for i in sorted(d.get("issues", []), key=lambda i: (i["component"], i.get("line", 0))):
    print("  NEW  %-12s %s:%s  %s" % (i["rule"].split(":")[-1], i["component"].split(":", 1)[-1],
                                      i.get("line", "-"), i["message"]))' <<<"$issues"

metrics="$(for c in "${JARVIS_GATE[@]}"; do printf '%s,' "${c%% *}"; done)violations"
{
    api GET "qualitygates/get_by_project?project=${PROJECT_KEY}" > "$WORK/v-gate.json" \
    && api GET "qualitygates/project_status?projectKey=${PROJECT_KEY}" > "$WORK/v-status.json" \
    && api GET "measures/component?component=${PROJECT_KEY}&metricKeys=${metrics}" > "$WORK/v-measures.json" \
    && api GET "issues/search?componentKeys=${PROJECT_KEY}&types=VULNERABILITY&resolved=false&ps=100" > "$WORK/v-vulns.json"
} || die2 "could not read the gate status, measures or vulnerabilities"
evaluate_gate "$WORK" "$GATE_NAME" "${head_sha:0:12} vs ${BASE_REF}"
exit $?
