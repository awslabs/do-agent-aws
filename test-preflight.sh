#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of build.sh's preflight and .env's conditional credential mounts (run by test.sh before the
# in-container suite, like test-exec.sh). Every branch is PLANTED with a docker stub on PATH - no real docker
# command runs, no image is built - and must refuse with its named message, exit 1 and no build attempted:
#   1. a docker without `buildx`               -> the buildx message (the fresh-host failure: Ubuntu's docker.io)
#   2. a docker that fails (`docker info`)      -> the "not usable by this user" message
#   3. a pass-through docker + BUILD_MIN_FREE_GB far above any disk, from the ENVIRONMENT -> the disk message
#      (so the environment overrides the .env default)
#   4. the pass-through docker with a threshold any disk meets -> rc 0 and exactly one build attempted for each
#      image build.sh builds: the agent's, then, with the kanban board on (UI_VIBE_KANBAN=true), the board server's
#      (the positive control: the preflight lets a sound host through). Only `docker image build` counts: the
#      Plane board's public images build.sh pulls first (UI_PLANE=true) are looked up with `docker image inspect`,
#      which the stub answers as present, so nothing is pulled. PLANTED CONTROL: a copy of build.sh that builds the
#      agent image twice fails the same count
#   5. .env with a HOME that has neither ~/.aws nor ~/.kube -> VOL_MAP and TEST_VOL_MAP mount neither; with both
#      present -> both maps mount both READ-ONLY (the host runs what they say: credential_process, exec plugins), VOL_MAP
#      adds the token caches ~/.aws/sso/cache and ~/.aws/cli/cache read-write when the host has them and TEST_VOL_MAP
#      never; the checkout is read-only in both maps, /wd writable in VOL_MAP
#   5b. the container's own kubeconfig: with no ~/.kube on the host, the agent-state mounts keep /home/agent/.kube under
#      wd/agent-state/.kube (it survives ./stop.sh && ./run.sh); with ~/.kube present they do not, so /home/agent/.kube has
#      exactly one mount, the host's (two at one path would stop docker run). The compose template binds every one of
#      those state folders at the same path, .kube included (compose mounts no host ~/.kube), the kubernetes template's
#      commented agent-state block lists the same, and .env makes wd/agent-state/.kube with a host ~/.kube too, since
#      a compose bind volume needs its folder (from a copy of .env and .fun, so its agent-state folder starts empty)
#   7. the Docker engine version (preflight.sh, shared with run.sh): on the docker target with the build
#      substrate on, an engine older than API 1.44 (Docker 25) warns (the sidecars' health check needs 25),
#      a current one is quiet, and the substrate off is quiet even on an old engine
#   6. Docker address pools (preflight.sh, shared with run.sh): a stub `docker network ls` listing 31 bridge networks on
#      the default 31 pools -> ./run.sh refuses before touching anything (exit 1) and names the count (31 of 31 in use,
#      0 free, 4 needed: the shipped defaults run the docker spoke's build substrate, whose two networks join the instance's
#      own and the board's internal one; the Plane board is off by default, docs/manual/boards.md "Plane board"), the stale network with no
#      container and `docker network prune`; with SPOKE_DOCKER=false 2 are needed; with the Plane board on (PLANE_RUN_OPTS set,
#      as .env does with UI_PLANE=true) its two join: 4 without the substrate, 6 with it; ./build.sh with the same stub
#      WARNS and still builds (a build creates no network); 20 networks -> the preflight passes and says 11 free; a
#      planted daemon.json with pools worth 256 subnets -> 31 used passes with 225 free; a malformed one falls back to 31
# Uses ./scratch/test-preflight (gitignored) for the stubs and outputs.

D=./scratch/test-preflight
rm -rf "${D:?}"
mkdir -p "${D}/bin" "${D}/emptyhome" "${D}/fullhome/.aws/sso/cache" "${D}/fullhome/.aws/cli/cache" "${D}/fullhome/.kube"
ATTEMPTED="$(pwd)/${D}/attempted.txt"
export ATTEMPTED

fail()
{
	echo "Test-preflight FAILED: $1"
	exit 1
}

stub()
{
	# stub <nobuildx|failing|passthru> - the docker on PATH for the next build.sh run; a build attempt (docker image
	# build) is recorded, any other image command (the Plane pull's inspect) answers 0 and is not; the cat of /SBOM.txt at
	# the end of build.sh (docs/manual/supply-chain.md "Software bill of materials") answers the checkout's own THIRD-PARTY-LICENSES, so the
	# file build.sh writes here is the one that was there (test-build.sh proves that step)
	case "$1" in
		nobuildx) cat > "${D}/bin/docker" << 'EOF'
#!/bin/bash
case "$1" in
	info) [ "$2" == "--format" ] && echo /var/lib/docker; exit 0 ;;
	buildx) echo "docker: unknown command: docker buildx" >&2; exit 1 ;;
	image) [ "$2" == "build" ] && echo "BUILD-ATTEMPTED $*" >> "${ATTEMPTED}"; exit 0 ;;
esac
exit 0
EOF
		;;
		failing) printf '#!/bin/bash\nexit 1\n' > "${D}/bin/docker" ;;
		passthru) cat > "${D}/bin/docker" << 'EOF'
#!/bin/bash
case "$1" in
	info) [ "$2" == "--format" ] && echo /var/lib/docker; exit 0 ;;
	buildx) echo "github.com/docker/buildx (stub)"; exit 0 ;;
	image) [ "$2" == "build" ] && { echo "BUILD-ATTEMPTED $*" >> "${ATTEMPTED}"; echo "stub: image built"; }; exit 0 ;;
	container) case " $* " in *" /SBOM.txt "*) [ -s THIRD-PARTY-LICENSES ] && cat THIRD-PARTY-LICENSES || printf '## Software bill of materials (SBOM) of the container image stub, build 0\n\n# stub\n'; esac; exit 0 ;;
esac
exit 0
EOF
		;;
		pools) cat > "${D}/bin/docker" << 'EOF'
#!/bin/bash
# a sound docker whose bridge networks are the names in ${NETWORKS_FILE}; every network has no container
case "$1" in
	info) [ "$2" == "--format" ] && echo /var/lib/docker; exit 0 ;;
	buildx) echo "github.com/docker/buildx (stub)"; exit 0 ;;
	image) [ "$2" == "build" ] && { echo "BUILD-ATTEMPTED $*" >> "${ATTEMPTED}"; echo "stub: image built"; }; exit 0 ;;
	container) case " $* " in *" /SBOM.txt "*) [ -s THIRD-PARTY-LICENSES ] && cat THIRD-PARTY-LICENSES || printf '## Software bill of materials (SBOM) of the container image stub, build 0\n\n# stub\n'; esac; exit 0 ;;
	network) case "$2" in ls) cat "${NETWORKS_FILE}" ;; inspect) echo 0 ;; esac; exit 0 ;;
esac
exit 0
EOF
		;;
	esac
	chmod +x "${D}/bin/docker"
	: > "${ATTEMPTED}"
}

run_build()
{
	# run_build [BUILD_MIN_FREE_GB] -> build.sh's exit status, output in ${D}/out.txt; the stub shadows docker; CVE_SCAN=false:
	# the CVE scan at the end of build.sh is test-scan.sh's (docs/manual/supply-chain.md "CVE scan")
	( PATH="$(pwd)/${D}/bin:${PATH}" BUILD_MIN_FREE_GB="${1:-}" CVE_SCAN=false ENV_LOCAL_SETUP=false ./build.sh ) > "${D}/out.txt" 2>&1
	echo $?
}

# --- 1. no buildx ---
stub nobuildx
RC=$(run_build 1)
[ "${RC}" == "1" ] || fail "1: build.sh exited ${RC} with a docker that has no buildx (expected 1): $(cat "${D}/out.txt")"
grep -q "docker buildx (BuildKit) is not installed" "${D}/out.txt" || fail "1: the buildx message is missing: $(cat "${D}/out.txt")"
grep -q "docker-buildx" "${D}/out.txt" || fail "1: the message does not name the package to install: $(cat "${D}/out.txt")"
[ ! -s "${ATTEMPTED}" ] || fail "1: a build was attempted without buildx: $(cat "${ATTEMPTED}")"
echo "ok 1 - a docker without buildx: refused with the named install, exit 1, no build attempted"

# --- 2. docker not usable ---
stub failing
RC=$(run_build 1)
[ "${RC}" == "1" ] || fail "2: build.sh exited ${RC} with a failing docker (expected 1): $(cat "${D}/out.txt")"
grep -q "docker is not usable by" "${D}/out.txt" || fail "2: the docker-group message is missing: $(cat "${D}/out.txt")"
grep -q "usermod -aG docker" "${D}/out.txt" || fail "2: the message does not name the fix: $(cat "${D}/out.txt")"
echo "ok 2 - a docker that fails: refused with the group/login fix, exit 1"

# --- 3. too little disk, threshold from the environment ---
stub passthru
RC=$(run_build 999999)
[ "${RC}" == "1" ] || fail "3: build.sh exited ${RC} with BUILD_MIN_FREE_GB=999999 (expected 1 - the environment must override the .env default): $(cat "${D}/out.txt")"
grep -q "GB free where Docker keeps its images" "${D}/out.txt" || fail "3: the disk message is missing: $(cat "${D}/out.txt")"
grep -q "need about 999999 GB" "${D}/out.txt" || fail "3: the message does not carry the threshold from the environment: $(cat "${D}/out.txt")"
[ ! -s "${ATTEMPTED}" ] || fail "3: a build was attempted with too little disk: $(cat "${ATTEMPTED}")"
echo "ok 3 - too little disk for the threshold given in the environment: refused, exit 1, no build attempted"

# --- 4. positive control: a sound host builds ---
stub passthru
RC=$(run_build 1)
[ "${RC}" == "0" ] || fail "4: build.sh exited ${RC} on a sound host (expected 0): $(cat "${D}/out.txt")"
# build.sh builds the agent image, then, with the kanban board on, the board server's image (docs/manual/boards.md "Kanban board")
WANT=1
[ "$(bash -c 'source .env > /dev/null 2>&1; echo "${UI_VIBE_KANBAN}"')" == "true" ] && WANT=2
[ "$(grep -c BUILD-ATTEMPTED "${ATTEMPTED}")" == "${WANT}" ] || fail "4: expected ${WANT} build attempt(s) on a sound host: $(cat "${ATTEMPTED}")"
head -1 "${ATTEMPTED}" | grep -q -- "-kanban" && fail "4: the first build attempted is not the agent image's: $(head -1 "${ATTEMPTED}")"
if [ "${WANT}" == "2" ]; then
	sed -n 2p "${ATTEMPTED}" | grep -q -- "-kanban" || fail "4: the second build attempted is not the board server's image: $(sed -n 2p "${ATTEMPTED}")"
fi
# PLANTED CONTROL: the same count refuses a build.sh that builds the agent image twice (the patterns are build.sh's
# literal text, $CMD and $? included)
# shellcheck disable=SC2016
sed 's/^eval "\$CMD" || exit \$?$/&\n&/' build.sh > "${D}/build-twice.sh"
# shellcheck disable=SC2016
[ "$(grep -c '^eval "\$CMD" || exit \$?$' "${D}/build-twice.sh")" == "2" ] || fail "4: PLANTED CONTROL BROKEN: the copy of build.sh does not build the agent image twice"
: > "${ATTEMPTED}"
( PATH="$(pwd)/${D}/bin:${PATH}" BUILD_MIN_FREE_GB=1 ENV_LOCAL_SETUP=false bash "${D}/build-twice.sh" ) > "${D}/out-twice.txt" 2>&1
[ "$(grep -c BUILD-ATTEMPTED "${ATTEMPTED}")" == "${WANT}" ] && fail "4: PLANTED CONTROL BROKEN: a build.sh that builds the agent image twice passed the count of ${WANT}: $(cat "${ATTEMPTED}")"
echo "ok 4 - a sound host: the preflight passes and one build is attempted per image (${WANT}; the Plane images' lookups are not builds); PLANTED CONTROL: a second build of the agent image is counted ($(grep -c BUILD-ATTEMPTED "${ATTEMPTED}"))"

# --- 5. the credential mounts follow the host ---
MAPS=$(HOME="$(pwd)/${D}/emptyhome" bash -c 'source .env > /dev/null 2>&1; echo "${VOL_MAP} ${TEST_VOL_MAP}"')
echo "${MAPS}" | grep -q "/home/agent/.aws" && fail "5: ~/.aws is mounted although HOME has no .aws: ${MAPS}"
echo "${MAPS}" | grep -q "/home/agent/.kube" && fail "5: ~/.kube is mounted although HOME has no .kube: ${MAPS}"
VM=$(HOME="$(pwd)/${D}/fullhome" bash -c 'source .env > /dev/null 2>&1; echo "${VOL_MAP}"')
TM=$(HOME="$(pwd)/${D}/fullhome" bash -c 'source .env > /dev/null 2>&1; echo "${TEST_VOL_MAP}"')
# Literal matches (-F): the checkout path is part of the expected text, and a "(" or "+" in it must not become
# regex syntax. The trailing space on the echoed map is the anchor - the mount ends at the kube path, no ":ro".
echo "${VM} " | grep -qF -- "-v $(pwd)/${D}/fullhome/.aws:/home/agent/.aws:ro " || fail "5: VOL_MAP does not mount ~/.aws read-only when present: ${VM}"
echo "${VM} " | grep -qF -- "-v $(pwd)/${D}/fullhome/.kube:/home/agent/.kube:ro " || fail "5: VOL_MAP does not mount ~/.kube read-only when present: ${VM}"
for C in sso/cache cli/cache; do
	echo "${VM} " | grep -qF -- "-v $(pwd)/${D}/fullhome/.aws/${C}:/home/agent/.aws/${C} " || fail "5: VOL_MAP does not mount ~/.aws/${C} read-write when present: ${VM}"
	echo "${TM}" | grep -qF -- "/.aws/${C}" && fail "5: TEST_VOL_MAP mounts the token cache ~/.aws/${C}: ${TM}"
done
echo "${TM} " | grep -qF -- "/fullhome/.aws:/home/agent/.aws:ro " || fail "5: TEST_VOL_MAP does not mount ~/.aws read-only when present: ${TM}"
echo "${TM} " | grep -qF -- "/fullhome/.kube:/home/agent/.kube:ro " || fail "5: TEST_VOL_MAP does not mount ~/.kube read-only when present: ${TM}"
# every mount of VOL_MAP is read-only but /wd and the two token caches: the checkout above all (every host script sources
# its .env and .env.local)
python3 -I - "${VM}" << 'PY2' || fail "5: VOL_MAP mounts something writable beyond /wd and the token caches: ${VM}"
import sys
words, rw = sys.argv[1].split(), []
for i, w in enumerate(words):
    if w == "-v" and i + 1 < len(words):
        parts = words[i + 1].split(":")
        dst, opts = parts[1], parts[2:] if len(parts) > 2 else []
        if "ro" not in opts and dst not in ("/wd", "/home/agent/.aws/sso/cache", "/home/agent/.aws/cli/cache"):
            rw.append(words[i + 1])
sys.exit(1 if rw or "/do-agent-aws:ro" not in sys.argv[1] else 0)
PY2
echo "ok 5 - ~/.aws and ~/.kube: mounted only when present, read-only in both maps; the token caches writable for the harness only; the checkout read-only, /wd writable"

# --- 5b. the container's own kubeconfig is agent state when the host has none ---
SM=$(HOME="$(pwd)/${D}/emptyhome" bash -c 'source .env > /dev/null 2>&1; echo "${AGENT_STATE_VOL_MAP}"')
echo "${SM} " | grep -qF -- "device=${AGENT_STATE_PATH_EXTERNAL:-$(pwd)/wd/agent-state}/.kube,dst=/home/agent/.kube " \
	|| fail "5b: with no ~/.kube on the host, the agent-state mounts do not keep /home/agent/.kube: ${SM}"
FM=$(HOME="$(pwd)/${D}/fullhome" bash -c 'source .env > /dev/null 2>&1; echo "${VOL_MAP} ${AGENT_STATE_VOL_MAP}"')
[ "$(echo "${FM}" | grep -o -- '/home/agent/.kube' | wc -l)" == "1" ] || fail "5b: with ~/.kube on the host, /home/agent/.kube is not mounted exactly once: ${FM}"
# and the container is told which: with the host's own ~/.kube mounted, the setup doctor gives update-kubeconfig as
# the person's host line instead of writing their kubeconfig
SF=$(HOME="$(pwd)/${D}/emptyhome" bash -c 'source .env > /dev/null 2>&1; echo "${AGENT_ENV_OPTS}"')
FF=$(HOME="$(pwd)/${D}/fullhome" bash -c 'source .env > /dev/null 2>&1; echo "${AGENT_ENV_OPTS}"')
echo " ${SF} " | grep -qF -- " -e KUBE_HOST_MOUNT=false " && echo " ${FF} " | grep -qF -- " -e KUBE_HOST_MOUNT=true " \
	|| fail "5b: the container is not told whether its ~/.kube is the host's (KUBE_HOST_MOUNT=false without one, true with one)"
# compose and kubernetes keep the same state folders as the docker mounts: the full list (no host ~/.kube), each at
# its path, bound to its folder under AGENT_STATE_PATH_EXTERNAL (compose) or as its subPath (kubernetes, commented)
SD=$(HOME="$(pwd)/${D}/emptyhome" bash -c 'source .env > /dev/null 2>&1; echo "${AGENT_STATE_DIRS}"')
WHY=$(python3 -I - to/compose/template/docker-compose.yaml to/kubernetes/template/020-deployment.yaml ${SD} 2>&1 << 'PY'
import re, sys
compose, k8s = open(sys.argv[1]).read(), open(sys.argv[2]).read()
dirs = [m.split(":", 1) for m in sys.argv[3:]]
if len(dirs) < 6 or [".kube", "/home/agent/.kube"] not in dirs:
    sys.exit(f"5b: .env's agent-state list without a host ~/.kube is not the full one: {dirs}")
top = compose.split("\nvolumes:\n", 1)[1]
device = dict(re.findall(r"^  (agent-state-[a-z0-9-]+):\n(?:    .*\n)*?      device: (\S+)$", top, re.M))
mounts = dict((dst, name) for name, dst in re.findall(r"^      - (agent-state-[a-z0-9-]+):(/\S+)$", compose, re.M))
for d, dst in dirs:
    name = mounts.get(dst)
    if name is None or device.get(name) != "${AGENT_STATE_PATH_EXTERNAL}/" + d:
        sys.exit(f"5b: the compose template does not bind {dst} to its agent-state folder {d} (mount {name}, device {device.get(name)})")
    if not re.search(r"#- name: agent-state\n\s*#  mountPath: %s\n\s*#  subPath: %s\n" % (re.escape(dst), re.escape(d)), k8s):
        sys.exit(f"5b: the kubernetes template's commented agent-state block does not list {dst} (subPath {d})")
PY
) || fail "${WHY}"
FH="$(pwd)/${D}/fullhome"
EC="${D}/envcopy"
mkdir -p "${EC}"
cp .env .fun "${EC}/"
CK=$(cd "${EC}" && HOME="${FH}" bash -c 'source .env > /dev/null 2>&1; echo "${AGENT_STATE_PATH_EXTERNAL}"')
case "${CK}" in */scratch/test-preflight/envcopy/wd/agent-state) ;; *) fail "5b: the copy of .env keeps its state elsewhere: ${CK}" ;; esac
[ -d "${CK}/.kube" ] || fail "5b: with ~/.kube on the host, .env does not make wd/agent-state/.kube, which the compose template binds"
echo "ok 5b - the container's kubeconfig: kept under wd/agent-state/.kube without a host ~/.kube, the host's ~/.kube alone with one, and KUBE_HOST_MOUNT says which; compose binds the same state folders (.kube included, its folder made either way) and the kubernetes template lists them"

# --- 6. Docker address pools ---
stub pools
export NETWORKS_FILE="$(pwd)/${D}/networks.txt"
{ echo bridge; for i in $(seq 1 29); do echo "net-${i}"; done; echo adav-old-test; } > "${NETWORKS_FILE}"   # 31 bridge networks, one a stale test network
[ "$(wc -l < "${NETWORKS_FILE}")" == "31" ] || fail "6: the planted network list is not 31 long"
# ENV_LOCAL_FILE=/dev/null: .env then reads no .env.local, so this checkout's own settings (a host that opted into the Plane board,
# or turned the substrate off) do not change the counts asserted here
( PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_DAEMON_JSON="$(pwd)/${D}/no-daemon.json" ENV_LOCAL_SETUP=false ENV_LOCAL_FILE=/dev/null ./run.sh ) > "${D}/run-full.txt" 2>&1; RC=$?
[ "${RC}" == "1" ] || fail "6: run.sh exited ${RC} with all 31 address pools in use (expected 1): $(cat "${D}/run-full.txt")"
grep -q "docker address pools: 31 of 31 in use, 0 free; a harness instance needs 4 (its own network, the board's internal one, the build substrate's two)" "${D}/run-full.txt" || fail "6: the refusal does not name the count: $(cat "${D}/run-full.txt")"
grep -q "too few free Docker address pools for a start (0 free, 4 needed)" "${D}/run-full.txt" || fail "6: run.sh did not refuse for the pools: $(cat "${D}/run-full.txt")"
# the docker spoke off (SPOKE_DOCKER=false in .env.local leaves DOCKER_RUN_OPTS empty): its substrate's two networks are not counted
( PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_DAEMON_JSON="$(pwd)/${D}/no-daemon.json" ENV_LOCAL_FILE=/dev/null bash -c 'source .env > /dev/null 2>&1; DOCKER_RUN_OPTS=; source ./preflight.sh; preflight_pools run' ) > "${D}/run-nodocker.txt" 2>&1
grep -q "a harness instance needs 2 (its own network, the board's internal one)$" "${D}/run-nodocker.txt" || fail "6: with SPOKE_DOCKER=false the count is not 2: $(cat "${D}/run-nodocker.txt")"
# the Plane board on (UI_PLANE=true in .env.local sets PLANE_RUN_OPTS; test-env-local.sh check 3): its two networks join the count
( PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_DAEMON_JSON="$(pwd)/${D}/no-daemon.json" ENV_LOCAL_FILE=/dev/null bash -c 'source .env > /dev/null 2>&1; DOCKER_RUN_OPTS=; PLANE_RUN_OPTS="--network planted-plane"; source ./preflight.sh; preflight_pools run' ) > "${D}/run-plane.txt" 2>&1
grep -q "a harness instance needs 4 (its own network, the board's internal one, Plane's two)$" "${D}/run-plane.txt" || fail "6: with the Plane board on and SPOKE_DOCKER=false the count is not 4: $(cat "${D}/run-plane.txt")"
( PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_DAEMON_JSON="$(pwd)/${D}/no-daemon.json" ENV_LOCAL_FILE=/dev/null bash -c 'source .env > /dev/null 2>&1; PLANE_RUN_OPTS="--network planted-plane"; source ./preflight.sh; preflight_pools run' ) > "${D}/run-plane-docker.txt" 2>&1
# the Plane board's two are counted on the docker target only, where its sidecars run (compose, swarm, kubernetes start none)
( PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_DAEMON_JSON="$(pwd)/${D}/no-daemon.json" ENV_LOCAL_FILE=/dev/null bash -c 'source .env > /dev/null 2>&1; TO=compose; DOCKER_RUN_OPTS=; PLANE_RUN_OPTS="--network planted-plane"; source ./preflight.sh; preflight_pools run' ) > "${D}/run-plane-compose.txt" 2>&1
grep -q "a harness instance needs 2 (its own network, the board's internal one)$" "${D}/run-plane-compose.txt" || fail "6: on the compose target the Plane board's two were counted: $(cat "${D}/run-plane-compose.txt")"
grep -q "a harness instance needs 6 (its own network, the board's internal one, Plane's two, the build substrate's two)$" "${D}/run-plane-docker.txt" || fail "6: with the Plane board and the substrate on the count is not 6: $(cat "${D}/run-plane-docker.txt")"
grep -q "docker network prune" "${D}/run-full.txt" || fail "6: the refusal does not name the command that frees pools: $(cat "${D}/run-full.txt")"
grep -q "adav-old-test" "${D}/run-full.txt" || fail "6: the refusal does not list the stale network with no container: $(cat "${D}/run-full.txt")"
grep -q "docker container run" "${D}/run-full.txt" && fail "6: run.sh went on to its start command after refusing"
: > "${ATTEMPTED}"
( PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_DAEMON_JSON="$(pwd)/${D}/no-daemon.json" BUILD_MIN_FREE_GB=1 CVE_SCAN=false ENV_LOCAL_SETUP=false ENV_LOCAL_FILE=/dev/null ./build.sh ) > "${D}/build-full.txt" 2>&1; RC=$?
[ "${RC}" == "0" ] || fail "6: build.sh exited ${RC} with all pools in use (expected 0: a build creates no network): $(cat "${D}/build-full.txt")"
grep -q "WARNING - too few free Docker address pools for a start" "${D}/build-full.txt" || fail "6: build.sh did not warn about the pools: $(cat "${D}/build-full.txt")"
[ -s "${ATTEMPTED}" ] || fail "6: build.sh attempted no build although only the pools were short"
{ echo bridge; for i in $(seq 1 19); do echo "net-${i}"; done; } > "${NETWORKS_FILE}"   # 20 in use, 11 free
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_DAEMON_JSON="$(pwd)/${D}/no-daemon.json" PREFLIGHT_WHO=run.sh bash -c 'source ./preflight.sh; preflight run' 2>&1); RC=$?
[ "${RC}" == "0" ] || fail "6: the preflight refused a host with 11 free pools: ${OUT}"
echo "${OUT}" | grep -q "docker address pools: 20 of 31 in use, 11 free" || fail "6: the passing preflight does not print the count: ${OUT}"
echo "${OUT}" | grep -q "docker network prune" && fail "6: a passing preflight still tells the person to prune"
printf '{"default-address-pools": [{"base": "10.10.0.0/16", "size": 24}]}\n' > "${D}/daemon-256.json"
{ echo bridge; for i in $(seq 1 30); do echo "net-${i}"; done; } > "${NETWORKS_FILE}"   # 31 in use
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_DAEMON_JSON="$(pwd)/${D}/daemon-256.json" PREFLIGHT_WHO=run.sh bash -c 'source ./preflight.sh; preflight run' 2>&1); RC=$?
[ "${RC}" == "0" ] && echo "${OUT}" | grep -q "31 of 256 in use, 225 free" || fail "6: a daemon.json pool of 256 subnets was not counted (rc ${RC}): ${OUT}"
printf '{not json' > "${D}/daemon-bad.json"
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_DAEMON_JSON="$(pwd)/${D}/daemon-bad.json" PREFLIGHT_WHO=run.sh bash -c 'source ./preflight.sh; preflight run' 2>&1); RC=$?
[ "${RC}" == "1" ] && echo "${OUT}" | grep -q "31 of 31 in use, 0 free" || fail "6: a malformed daemon.json did not fall back to the default 31 pools (rc ${RC}): ${OUT}"
echo "ok 6 - Docker address pools: 31 of 31 in use refuses ./run.sh with the count (4 by default, 2 without the substrate, 6 with the Plane board on and 4 with it alone, 2 with the board on another target), the stale network and the prune command before any start, ./build.sh warns and builds; 20 in use passes with 11 free; a daemon.json pool of 256 is counted; a malformed one falls back to 31"

# --- 7. the Docker engine version (preflight.sh preflight_docker_engine, shared with run.sh) ---
cat > "${D}/bin/docker" << 'EOF'
#!/bin/bash
case "$1" in
	version) [ "$2" == "--format" ] && echo "${STUB_API}"; exit 0 ;;
esac
exit 0
EOF
chmod +x "${D}/bin/docker"
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" STUB_API=1.43 PREFLIGHT_WHO=run.sh bash -c 'source ./preflight.sh; DOCKER_RUN_OPTS=x TO=docker preflight_docker_engine' 2>&1)
echo "${OUT}" | grep -q "Docker Engine API 1.43 is older than 1.44 (Engine 25)" || fail "7: an engine older than 25 did not warn: ${OUT}"
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" STUB_API=1.44 PREFLIGHT_WHO=run.sh bash -c 'source ./preflight.sh; DOCKER_RUN_OPTS=x TO=docker preflight_docker_engine' 2>&1)
[ -z "${OUT}" ] || fail "7: a current engine (API 1.44) warned: ${OUT}"
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" STUB_API=1.43 PREFLIGHT_WHO=run.sh bash -c 'source ./preflight.sh; DOCKER_RUN_OPTS= TO=docker preflight_docker_engine' 2>&1)
[ -z "${OUT}" ] || fail "7: the engine warn fired with the build substrate off: ${OUT}"
echo "ok 7 - the Docker engine version: an engine older than API 1.44 (Engine 25) warns on the docker target with the substrate on, a current one is quiet, and the substrate off is quiet even on an old engine"

# --- 8. the CVE scan's preflight (docs/manual/supply-chain.md "CVE scan"): the scanner container needs a writable unix socket ---
# the passthru stub's `docker context inspect` prints nothing, so the endpoint is /var/run/docker.sock unless DOCKER_HOST says otherwise;
# a build with CVE_SCAN=true and a tcp endpoint warns, a run never does, a writable planted socket is quiet, an unwritable path warns
stub passthru
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${D}/cve-sock" || fail "8: could not plant a socket"
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_WHO=build.sh DOCKER_HOST=tcp://planted:2375 bash -c 'source .env > /dev/null 2>&1; source ./preflight.sh; CVE_SCAN=true TRIVY=docker preflight_cve_scan' 2>&1)
echo "${OUT}" | grep -q '^build.sh: WARNING - the CVE scan at the end of the build (CVE_SCAN=true) runs trivy as a container that reads the image through the Docker socket, and the Docker endpoint is not a unix socket (DOCKER_HOST=tcp://planted:2375): ./scan.sh will fail there - in .env.local, TRIVY=<trivy command>' \
	|| fail "8: no WARNING for a tcp Docker endpoint with CVE_SCAN=true: ${OUT}"
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_WHO=build.sh DOCKER_HOST="unix://${D}/cve-sock" bash -c 'source .env > /dev/null 2>&1; source ./preflight.sh; CVE_SCAN=true TRIVY=docker preflight_cve_scan' 2>&1)
[ -z "${OUT}" ] || fail "8: a writable unix socket produced output: ${OUT}"
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_WHO=build.sh DOCKER_HOST="unix://${D}/no-such-sock" bash -c 'source .env > /dev/null 2>&1; source ./preflight.sh; CVE_SCAN=true TRIVY=docker preflight_cve_scan' 2>&1)
echo "${OUT}" | grep -q "^build.sh: WARNING - .*${D}/no-such-sock is not there or not writable by $(id -un): ./scan.sh will fail there" || fail "8: no WARNING for a socket that is not there: ${OUT}"
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_WHO=build.sh DOCKER_HOST=tcp://planted:2375 bash -c 'source .env > /dev/null 2>&1; source ./preflight.sh; CVE_SCAN=false TRIVY=docker preflight_cve_scan; CVE_SCAN=true TRIVY=trivy preflight_cve_scan' 2>&1)
[ -z "${OUT}" ] || fail "8: CVE_SCAN=false or a host trivy produced a warning: ${OUT}"
# the build preflight carries it, the run preflight does not (the stub's docker is sound, so the whole preflight runs)
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_WHO=build.sh DOCKER_HOST=tcp://planted:2375 BUILD_MIN_FREE_GB=1 bash -c 'source .env > /dev/null 2>&1; source ./preflight.sh; CVE_SCAN=true TRIVY=docker preflight build' 2>&1)
echo "${OUT}" | grep -q 'WARNING - the CVE scan at the end of the build' || fail "8: preflight build does not carry the CVE scan warning: ${OUT}"
OUT=$(PATH="$(pwd)/${D}/bin:${PATH}" PREFLIGHT_WHO=run.sh DOCKER_HOST=tcp://planted:2375 BUILD_MIN_FREE_GB=1 bash -c 'source .env > /dev/null 2>&1; source ./preflight.sh; CVE_SCAN=true TRIVY=docker preflight run' 2>&1)
echo "${OUT}" | grep -q 'WARNING - the CVE scan' && fail "8: preflight run carries the CVE scan warning: ${OUT}"
echo "ok 8 - the CVE scan's preflight: a tcp Docker endpoint or a socket that is not there warns before a build with CVE_SCAN=true (the remedy names .env.local), a writable socket, CVE_SCAN=false, a host trivy and the run preflight are quiet"

echo "Test-preflight succeeded"
