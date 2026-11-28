#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of the docker spoke's build substrate (docs/manual/agents.md "Docker agent"). Like test-kanban.sh it runs on the HOST:
# the BuildKit daemon and the registry are sidecar containers, which test.sh's throwaway container has no access to. It
# starts a substrate of its own with ./docker.sh, from a copy of .env whose .env.local names a test CONTAINER
# (<CONTAINER>-dtest), and a throwaway agent container from the image ./build.sh built, which mounts the daemon's socket
# volume and joins the registry's internal network after its start, as ./run.sh does. Nothing of a running harness is used
# or touched, and everything the test starts carries its label and is removed at the end. The planted Dockerfile builds
# FROM scratch: no base image is pulled, and the test needs no network.
# Each check FAILS if the property is removed:
#   1 [substrate-up]. ./docker.sh up starts the daemon and the registry, both healthy, the daemon as an unprivileged user;
#      neither publishes a host port; the daemon's network holds the daemon and the registry, the agent's internal one
#      the registry and the agent, and the agent is not on the daemon's; the daemon is not privileged and has no added
#      Linux capabilities; the agent container has no Docker socket and no docker CLI
#   2 [build-to-registry]. /agent/image-build.sh builds the planted Dockerfile through the daemon and prints the pushed
#      reference with its digest; the registry's catalog and tag list hold it, the manifest the registry serves for the tag
#      has that digest, and builds.jsonl records the build
#   3 [outside-push-refused]. the helper refuses a name on another registry (a host with a dot, one with a port, localhost,
#      Docker Hub by name) with exit 2, and buildctl never runs (a recording buildctl first on PATH). PLANTED CONTROL: the
#      same recorder sees the helper's build of the stack's own name, so a refusal that reached buildctl would be seen
#   4 [status-inventory]. one cycle of the spoke's loop writes STATUS.md with the daemon and the registry UP and each tag
#      with its digest in its images section (the registry's, not the build record's), and STATUS.html beside it; it
#      prints no notice for images already there, and the next cycle, after one more tag, prints that image as a notice
#      for agent (a "HUB: " line)
#   5 [tile-through-proxy]. the home page rendered with the docker spoke on has the spoke's tile linking /docker/, and
#      /docker/ on the home listener answers 200 with the rendered status naming the image, not cached
#   6 [rows-down-exit-1]. ui-status.sh's docker rows read UP with both sidecars running and it exits 0 (every other row
#      off); PLANTED: with the daemon stopped, docker-buildkit reads DOWN and the exit is 1; started again, UP
#   7 [doctor-registry-red]. /agent/doctor.sh --check docker passes with both running; PLANTED: with the registry stopped
#      it is a GAP naming the registry, with host lines, and exits 1; started again, it passes
#   8 [helper-registry-pin]. the helper's push target is the fixed registry:5000, not a BUILD_REGISTRY the caller
#      sets: a name on the host a hostile BUILD_REGISTRY names is refused and never reaches buildctl, a bare name
#      is pushed to registry:5000 regardless of BUILD_REGISTRY, and the helper's list reads registry:5000 too
#   9 [rows-substrate-failed]. a failed substrate (DOCKER_SUBSTRATE=failed, no BUILDKIT_HOST) reads both ui-status
#      rows DOWN and exits 1; CONTROL: without the marker a target that runs none reads NOT CONFIGURED and exits 0
#   10 [prev-carry-forward]. a cycle whose registry read failed carries the last inventory forward, so the recovery
#      cycle announces no image as new (only that the registry answers again)
# Usage: ./test-docker-spoke.sh (test.sh runs it while SPOKE_DOCKER=true). It needs the agent image (./build.sh) and the two
# sidecar images (./build.sh pulls them; ./docker.sh pull). Uses ./scratch/test-docker-spoke (gitignored).

source .env

D=./scratch/test-docker-spoke
rm -rf "${D:?}"
mkdir -p "${D}/env" || exit 1
IMG=${REGISTRY}${IMAGE}${TAG}
TC=${CONTAINER}-dtest
AG=${TC}-agent
LABEL_KEY=do-agent-aws.docker
STARTED=""

fail()
{
	echo "Test-docker-spoke FAILED: $1"
	exit 1
}

# the substrate's names for the test CONTAINER, from a copy of .env (and the person's .env.local) beside a copy of docker.sh
cp .env .fun docker.sh "${D}/env/" || fail "cannot copy .env, .fun and docker.sh into ${D}/env"
[ -f .env.local ] && cp .env.local "${D}/env/.env.local"
echo "export CONTAINER=${TC}" >> "${D}/env/.env.local"
( cd "${D}/env" && bash -c 'source .env > /dev/null 2>&1; for V in DOCKER_BUILDKIT_NAME DOCKER_REGISTRY_NAME DOCKER_NETWORK DOCKER_BUILD_NETWORK DOCKER_SOCKET_VOLUME DOCKER_CACHE_VOLUME DOCKER_REGISTRY_VOLUME DOCKER_RUN_OPTS; do printf "%s=%q\n" "${V}" "${!V}"; done' ) > "${D}/names.sh"
source "${D}/names.sh"
[ "${DOCKER_BUILDKIT_NAME}" == "${TC}-buildkit" ] && [ -n "${DOCKER_RUN_OPTS}" ] || fail "the copy of .env does not derive the substrate's names from CONTAINER=${TC}: $(tr '\n' ' ' < "${D}/names.sh")"

ours()
{
	# ours <container|volume> <name> - 0 when it carries the test's label (docker.sh labels the sidecars and volumes the
	# same way, with the test CONTAINER as the value)
	local F="{{index .Labels \"${LABEL_KEY}\"}}"
	[ "$1" == "container" ] && F="{{index .Config.Labels \"${LABEL_KEY}\"}}"
	[ "$(timeout 60 docker "$1" inspect -f "${F}" "$2" 2> /dev/null)" == "${TC}" ]
}

cleanup()
{
	[ -n "${STARTED}" ] || return
	ours container "${AG}" && timeout 120 docker container rm -f "${AG}" > /dev/null 2>&1
	( cd "${D}/env" && timeout 300 ./docker.sh down ) > "${D}/down.log" 2>&1
	for V in "${DOCKER_SOCKET_VOLUME}" "${DOCKER_CACHE_VOLUME}" "${DOCKER_REGISTRY_VOLUME}"; do
		ours volume "${V}" && timeout 120 docker volume rm "${V:?}" > /dev/null 2>&1
	done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

for I in "${IMG}" "${DOCKER_BUILDKIT_IMAGE}" "${DOCKER_REGISTRY_IMAGE}"; do
	timeout 60 docker image inspect "${I}" > /dev/null 2>&1 || fail "the image ${I} is missing - run ./build.sh first (it builds the agent image and pulls the sidecars')"
done
for C in "${AG}" "${DOCKER_BUILDKIT_NAME}" "${DOCKER_REGISTRY_NAME}"; do
	timeout 60 docker container inspect "${C}" > /dev/null 2>&1 && ! ours container "${C}" && fail "a container named ${C} exists and is not this test's - refusing to touch it"
done
STARTED=1
# a container an earlier run of this test left behind goes first (its own label only)
ours container "${AG}" && timeout 120 docker container rm -f "${AG}" > /dev/null 2>&1

ax()
{
	# ax <command...> - run in the throwaway agent container; axi passes this script's stdin to it
	timeout 600 docker container exec "${AG}" "$@"
}

axi()
{
	timeout 600 docker container exec -i "${AG}" "$@"
}

# --- 1. the substrate comes up, isolated, without a host port or a Docker socket ---
( cd "${D}/env" && timeout 900 ./docker.sh up ) > "${D}/up.log" 2>&1 || fail "./docker.sh up: $(tail -5 "${D}/up.log")"
for C in "${DOCKER_BUILDKIT_NAME}" "${DOCKER_REGISTRY_NAME}"; do
	[ "$(timeout 60 docker container inspect -f '{{.State.Health.Status}}' "${C}")" == "healthy" ] || fail "${C} is not healthy after ./docker.sh up"
	[ -z "$(timeout 60 docker container port "${C}")" ] || fail "${C} publishes a host port: $(timeout 60 docker container port "${C}")"
done
[ "$(timeout 60 docker container exec "${DOCKER_BUILDKIT_NAME}" id -u)" == "1000" ] || fail "the BuildKit daemon does not run as the image's unprivileged user"
[ "$(timeout 60 docker container inspect -f '{{.HostConfig.Privileged}}' "${DOCKER_BUILDKIT_NAME}")" == "false" ] || fail "the BuildKit daemon runs privileged"
[ -z "$(timeout 60 docker container inspect -f '{{range .HostConfig.CapAdd}}{{.}} {{end}}' "${DOCKER_BUILDKIT_NAME}")" ] || fail "the BuildKit daemon has added Linux capabilities: $(timeout 60 docker container inspect -f '{{range .HostConfig.CapAdd}}{{.}} {{end}}' "${DOCKER_BUILDKIT_NAME}")"
timeout 300 docker container run -d --name "${AG}" --label "${LABEL_KEY}=${TC}" ${DOCKER_RUN_OPTS} -e DOCKER_MIN_FREE_GB=1 "${IMG}" sleep 3600 > /dev/null \
	|| fail "could not start the throwaway agent container from ${IMG}"
timeout 120 docker network connect "${DOCKER_NETWORK}" "${AG}" || fail "the agent container could not join ${DOCKER_NETWORK}"
members()
{
	timeout 60 docker network inspect -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' "$1" | grep . | sort | tr '\n' ' '
}
[ "$(members "${DOCKER_BUILD_NETWORK}")" == "$(printf '%s\n' "${DOCKER_BUILDKIT_NAME}" "${DOCKER_REGISTRY_NAME}" | sort | tr '\n' ' ')" ] \
	|| fail "the daemon's network ${DOCKER_BUILD_NETWORK} holds $(members "${DOCKER_BUILD_NETWORK}"), not the daemon and the registry alone"
[ "$(members "${DOCKER_NETWORK}")" == "$(printf '%s\n' "${AG}" "${DOCKER_REGISTRY_NAME}" | sort | tr '\n' ' ')" ] \
	|| fail "the agent's network ${DOCKER_NETWORK} holds $(members "${DOCKER_NETWORK}"), not the registry and the agent alone"
[ "$(timeout 60 docker network inspect -f '{{.Internal}}' "${DOCKER_NETWORK}")" == "true" ] || fail "the agent's network ${DOCKER_NETWORK} is not internal"
ax sh -c '[ ! -e /var/run/docker.sock ] && [ ! -e /run/docker.sock ] && ! command -v docker' > /dev/null || fail "the agent container has a Docker socket or a docker CLI"
echo "ok 1 [substrate-up] - ./docker.sh up: the daemon (uid 1000, not privileged, no added caps) and the registry healthy, no host port; the daemon's network holds the daemon and the registry, the agent's internal one the registry and the agent; no Docker socket or docker CLI in the agent"

# --- 2. a build through the helper lands in the stack's registry with its digest ---
ax sh -c 'mkdir -p /tmp/dtest-ctx && echo hello-from-the-docker-spoke-test > /tmp/dtest-ctx/hello.txt && printf "FROM scratch\nCOPY hello.txt /hello.txt\n" > /tmp/dtest-ctx/Dockerfile' \
	|| fail "could not write the planted Dockerfile in the agent container"
build()
{
	# build <name> [<PATH>] - the helper's build of the planted Dockerfile as <name>; its stdout in ${D}/build-<n>.out
	local P=${2:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
	ax env PATH="${P}" DOCKER_SPOKE_WD=/tmp/dtest-wd /agent/image-build.sh /tmp/dtest-ctx /tmp/dtest-ctx/Dockerfile "$1"
}
OUT=$(build dtest/hello:1 2> "${D}/build-1.err") || fail "the helper's build of dtest/hello:1 failed: $(tail -5 "${D}/build-1.err")"
REF=$(echo "${OUT}" | sed -n 's/^image: //p')
echo "${REF}" | grep -qE '^registry:5000/dtest/hello:1@sha256:[0-9a-f]{64}$' || fail "the helper did not print the pushed reference with its digest: ${OUT}"
DIGEST=${REF#*@}
reg_get()
{
	ax curl -s --noproxy '*' --max-time 10 "$@"
}
reg_get http://registry:5000/v2/_catalog | grep -q '"dtest/hello"' || fail "the registry's catalog does not list dtest/hello: $(reg_get http://registry:5000/v2/_catalog)"
reg_get http://registry:5000/v2/dtest/hello/tags/list | grep -q '"1"' || fail "the registry's tag list of dtest/hello has no tag 1"
SERVED=$(reg_get -I -H 'Accept: application/vnd.oci.image.manifest.v1+json' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
	http://registry:5000/v2/dtest/hello/manifests/1 | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p')
[ "${SERVED}" == "${DIGEST}" ] || fail "the registry serves dtest/hello:1 as '${SERVED}', not the helper's ${DIGEST}"
ax cat /tmp/dtest-wd/builds.jsonl | grep -F "\"digest\": \"${DIGEST}\"" | grep -qF '"rc": 0' || fail "builds.jsonl does not record the build with its digest"
echo "ok 2 [build-to-registry] - the helper built the planted Dockerfile through the daemon and pushed ${REF}; the catalog, the tag list and the served manifest agree, and builds.jsonl records it"

# --- 3. a push outside the stack is refused before buildctl runs ---
ax sh -c 'mkdir -p /tmp/dtest-shim && printf "#!/bin/sh\necho \"\$*\" >> /tmp/dtest-shim/calls.log\nexec /usr/local/bin/buildctl \"\$@\"\n" > /tmp/dtest-shim/buildctl && chmod +x /tmp/dtest-shim/buildctl' \
	|| fail "could not write the recording buildctl"
SHIM=/tmp/dtest-shim:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
for N in example.com/team/tool:1 registry.example:5000/tool:1 localhost:5000/tool:1 127.0.0.1:5000/tool:1 docker.io/library/tool:1; do
	build "${N}" "${SHIM}" > /dev/null 2> "${D}/refused.err"
	RC=$?
	[ "${RC}" == "2" ] && grep -q 'REFUSED' "${D}/refused.err" || fail "the helper did not refuse ${N} with exit 2 (rc ${RC}): $(cat "${D}/refused.err")"
done
[ -z "$(ax cat /tmp/dtest-shim/calls.log 2> /dev/null)" ] || fail "a refused name reached buildctl: $(ax cat /tmp/dtest-shim/calls.log)"
OUT=$(build registry:5000/dtest/hello:2 "${SHIM}" 2> "${D}/build-2.err") || fail "PLANTED CONTROL: the stack's own name was not built: $(tail -3 "${D}/build-2.err")"
[ "$(ax cat /tmp/dtest-shim/calls.log 2> /dev/null | grep -c '^build ')" == "1" ] || fail "PLANTED CONTROL: the recording buildctl did not see the build of the stack's own name"
echo "ok 3 [outside-push-refused] - five names on other registries refused with exit 2, none reached buildctl; control: the recorder saw the build of registry:5000/dtest/hello:2"

# --- 4. the spoke's cycle writes the inventory, and tells agent about a new image ---
ax env DOCKER_SPOKE_WD=/tmp/dtest-wd /agent/charters/docker/loop.sh > "${D}/cycle-1.out" 2>&1 || fail "the docker loop's first cycle: $(tail -5 "${D}/cycle-1.out")"
ax cat /tmp/dtest-wd/STATUS.md > "${D}/STATUS.md" || fail "the cycle wrote no STATUS.md"
grep -q '^| BuildKit daemon | UP | BuildKit v' "${D}/STATUS.md" && grep -q '^| registry | UP | registry:5000' "${D}/STATUS.md" \
	|| fail "STATUS.md does not read the daemon and the registry UP: $(grep '^| ' "${D}/STATUS.md" | head -4)"
# the images section alone: the last-builds table below it names the same references, from builds.jsonl
sed -n '/^## Images in the registry$/,/^## Last builds$/p' "${D}/STATUS.md" > "${D}/STATUS-images.md"
grep -qF "| registry:5000/dtest/hello:1 | ${DIGEST} |" "${D}/STATUS-images.md" || fail "STATUS.md's images section does not list dtest/hello:1 with its digest"
grep -qF '| registry:5000/dtest/hello:2 | sha256:' "${D}/STATUS-images.md" || fail "STATUS.md's images section does not list dtest/hello:2"
ax grep -q 'dtest/hello' /tmp/dtest-wd/STATUS.html || fail "the cycle wrote no STATUS.html naming the image"
grep -q '^HUB: ' "${D}/cycle-1.out" && fail "the first cycle sent notices for what was already there: $(grep '^HUB: ' "${D}/cycle-1.out")"
build dtest/hello:3 > /dev/null 2> "${D}/build-3.err" || fail "the build of dtest/hello:3: $(tail -3 "${D}/build-3.err")"
ax env DOCKER_SPOKE_WD=/tmp/dtest-wd /agent/charters/docker/loop.sh > "${D}/cycle-2.out" 2>&1 || fail "the docker loop's second cycle: $(tail -5 "${D}/cycle-2.out")"
grep -q '^HUB: new image in the registry: registry:5000/dtest/hello:3@sha256:' "${D}/cycle-2.out" || fail "the second cycle did not tell agent about dtest/hello:3: $(cat "${D}/cycle-2.out")"
[ "$(grep -c '^HUB: ' "${D}/cycle-2.out")" == "1" ] || fail "the second cycle sent other notices too: $(grep '^HUB: ' "${D}/cycle-2.out")"
echo "ok 4 [status-inventory] - the cycle's STATUS.md reads the daemon and the registry UP and lists each tag with its digest, STATUS.html beside it; no notice for what was there, one for the new dtest/hello:3"

# --- 5. the tile and the page through the home listener ---
axi python3 -I - << 'PY' || fail "could not write the test's registry copies in the agent container"
import json
doc = json.load(open("/agent/spokes/registry.json"))
for e in doc["sessions"]:
    if e["session_name"] == "docker":
        e["workdir"] = "/tmp/dtest-wd"
json.dump(doc, open("/tmp/dtest-registry.json", "w"))
doc["sessions"] = [e for e in doc["sessions"] if e["role"] != "spoke"]
json.dump(doc, open("/tmp/dtest-registry-hub.json", "w"))
PY
ax test -s /tmp/dtest-registry-hub.json || fail "the test's registry copies are not in the agent container"
OFF="UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false UI_PLANE=false UI_BOARD=false UI_FILES=false UI_CHAT=false COMMS_UI_ENABLED=false LOOP_DECK_DATA_DIR=/tmp/dtest-deck AGENT_TMUX_SESSION=false"
SPOKES_OFF="SPOKE_CONVERSATIONS=false SPOKE_INSIGHTS=false SPOKE_CLUSTERS=false SPOKE_SESSIONS=false SPOKE_LOOPS=false SPOKE_ISSUES=false SPOKE_EXAMPLE=false SPOKE_DOCKER=true"
ax env ${OFF} ${SPOKES_OFF} UI_DIR=/tmp/dtest-ui UI_LISTEN_HOST=127.0.0.1 UI_HOME=true UI_PORT_HOME=18877 SUPERVISOR=false \
	SPOKES_REGISTRY=/tmp/dtest-registry.json /agent/ui-start.sh > "${D}/ui-start.log" 2>&1 || fail "ui-start.sh with the docker spoke on: $(tail -5 "${D}/ui-start.log")"
for I in $(seq 1 30); do [ "$(ax curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18877/)" == "200" ] && break; sleep 1; done
ax curl -s --max-time 10 http://127.0.0.1:18877/ > "${D}/home.html"
grep -qF '<li class="tile spoke" data-spoke="docker"><span class="dot"></span><a href="/docker/" target="_blank" rel="opener">Docker spoke</a>' "${D}/home.html" \
	|| fail "the home page has no live docker spoke tile linking /docker/: $(grep -o '<li class="tile spoke[^>]*data-spoke="docker".\{0,200\}' "${D}/home.html")"
ax curl -s -D /tmp/dtest-page.hdr -o /tmp/dtest-page.html -w '%{http_code}' --max-time 10 http://127.0.0.1:18877/docker/ > "${D}/page.code"
[ "$(cat "${D}/page.code")" == "200" ] || fail "/docker/ answers $(cat "${D}/page.code") through the home listener"
ax grep -q 'registry:5000/dtest/hello:3' /tmp/dtest-page.html || fail "/docker/ does not serve the rendered status naming the image"
ax grep -qi '^cache-control: no-store' /tmp/dtest-page.hdr || fail "/docker/ is served without Cache-Control no-store"
echo "ok 5 [tile-through-proxy] - the home page's docker spoke tile links /docker/, and /docker/ answers 200 with the rendered status naming the image, never cached"

# --- 6. ui-status.sh's rows: UP with both sidecars, DOWN and exit 1 with the daemon stopped ---
rows()
{
	ax env ${OFF} ${SPOKES_OFF} UI_HOME=false UI_DIR=/tmp/dtest-ui-status SUPERVISOR=false SPOKES_REGISTRY=/tmp/dtest-registry-hub.json /agent/ui-status.sh > "${D}/$1.out" 2>&1
	echo $?
}
[ "$(rows status-up)" == "0" ] && grep -q '^docker-buildkit: UP ' "${D}/status-up.out" && grep -q '^docker-registry: UP ' "${D}/status-up.out" \
	|| fail "ui-status.sh with both sidecars running: $(cat "${D}/status-up.out")"
timeout 120 docker container stop "${DOCKER_BUILDKIT_NAME}" > /dev/null || fail "could not stop ${DOCKER_BUILDKIT_NAME}"
[ "$(rows status-down)" == "1" ] && grep -q '^docker-buildkit: DOWN ' "${D}/status-down.out" \
	|| fail "PLANTED: ui-status.sh with the daemon stopped does not read DOWN and exit 1: $(grep docker "${D}/status-down.out")"
timeout 120 docker container start "${DOCKER_BUILDKIT_NAME}" > /dev/null || fail "could not start ${DOCKER_BUILDKIT_NAME} again"
for I in $(seq 1 60); do [ "$(rows status-back)" == "0" ] && break; sleep 2; done
grep -q '^docker-buildkit: UP ' "${D}/status-back.out" || fail "the daemon started again does not read UP: $(grep docker "${D}/status-back.out")"
echo "ok 6 [rows-down-exit-1] - ui-status.sh: both rows UP and exit 0; planted: the daemon stopped reads DOWN with exit 1; started again, UP"

# --- 7. the setup doctor's docker check: a pass, a gap with the registry stopped ---
doctor()
{
	ax env SETUP_DIR=/tmp/dtest-setup /agent/doctor.sh --check docker > "${D}/$1.out" 2>&1
	echo $?
}
[ "$(doctor doctor-up)" == "0" ] && grep -q '^  docker  *PASS ' "${D}/doctor-up.out" || fail "the doctor's docker check with both running: $(head -5 "${D}/doctor-up.out")"
timeout 120 docker container stop "${DOCKER_REGISTRY_NAME}" > /dev/null || fail "could not stop ${DOCKER_REGISTRY_NAME}"
[ "$(doctor doctor-down)" == "1" ] && grep -q '^  docker  *GAP .*the registry does not answer' "${D}/doctor-down.out" && grep -q '\./docker.sh up' "${D}/doctor-down.out" \
	|| fail "PLANTED: the doctor with the registry stopped is not a gap naming the registry with its host line: $(head -8 "${D}/doctor-down.out")"
timeout 120 docker container start "${DOCKER_REGISTRY_NAME}" > /dev/null || fail "could not start ${DOCKER_REGISTRY_NAME} again"
for I in $(seq 1 60); do [ "$(doctor doctor-back)" == "0" ] && break; sleep 2; done
grep -q '^  docker  *PASS ' "${D}/doctor-back.out" || fail "the doctor does not pass with the registry started again: $(head -5 "${D}/doctor-back.out")"
echo "ok 7 [doctor-registry-red] - the doctor's docker check passes; planted: with the registry stopped it is a GAP naming the registry with ./docker.sh up, exit 1; started again, it passes"

# --- 8. the helper's push target is the fixed registry:5000, not a BUILD_REGISTRY the caller sets ---
ax sh -c ': > /tmp/dtest-shim/calls.log' || fail "8: could not reset the recording buildctl log"
build_as()
{
	# build_as <BUILD_REGISTRY> <name> - the helper with BUILD_REGISTRY set in the environment, through the recorder
	ax env PATH="${SHIM}" BUILD_REGISTRY="$1" DOCKER_SPOKE_WD=/tmp/dtest-wd /agent/image-build.sh /tmp/dtest-ctx /tmp/dtest-ctx/Dockerfile "$2"
}
build_as evil.example:5000 evil.example:5000/x:1 > /dev/null 2> "${D}/pin.err"
RC=$?
[ "${RC}" == "2" ] && grep -q 'REFUSED' "${D}/pin.err" || fail "8: the helper did not refuse evil.example:5000/x:1 with BUILD_REGISTRY set to that host (rc ${RC}): $(cat "${D}/pin.err")"
[ -z "$(ax cat /tmp/dtest-shim/calls.log 2> /dev/null)" ] || fail "8: a redirected push reached buildctl: $(ax cat /tmp/dtest-shim/calls.log)"
OUT=$(build_as evil.example:5000 dtest/pinned:1 2> "${D}/pin2.err") || fail "8: CONTROL: a bare name did not build with BUILD_REGISTRY set elsewhere: $(tail -3 "${D}/pin2.err")"
echo "${OUT}" | grep -q '^image: registry:5000/dtest/pinned:1@sha256:' || fail "8: CONTROL: the helper did not push to registry:5000 regardless of BUILD_REGISTRY: ${OUT}"
LIST=$(ax env BUILD_REGISTRY=evil.example:5000 /agent/image-build.sh list 2> "${D}/pin3.err") \
	|| fail "8: the helper's list failed with BUILD_REGISTRY set to another host: $(tail -2 "${D}/pin3.err")"
echo "${LIST}" | grep -qx 'registry:5000/dtest/pinned:1' || fail "8: the helper's list did not read registry:5000 with BUILD_REGISTRY set to another host: ${LIST}"
echo "ok 8 [helper-registry-pin] - the helper refuses the host a hostile BUILD_REGISTRY names (none reached buildctl), pushes a bare name to registry:5000 regardless of BUILD_REGISTRY, and lists registry:5000's images under it too"

# --- 9. a failed substrate reads DOWN and exits 1, a target that runs none reads NOT CONFIGURED and exits 0 ---
failrows()
{
	# failrows <name> <extra env> - ui-status.sh in the agent with no BUILDKIT_HOST/BUILD_REGISTRY and the given marker
	ax env ${OFF} ${SPOKES_OFF} UI_HOME=false UI_DIR=/tmp/dtest-ui-$1 SUPERVISOR=false SPOKES_REGISTRY=/tmp/dtest-registry-hub.json BUILDKIT_HOST= BUILD_REGISTRY= $2 /agent/ui-status.sh > "${D}/$1.out" 2>&1
	echo $?
}
[ "$(failrows status-failed DOCKER_SUBSTRATE=failed)" == "1" ] && grep -q '^docker-buildkit: DOWN ' "${D}/status-failed.out" && grep -q '^docker-registry: DOWN ' "${D}/status-failed.out" \
	|| fail "9: a failed substrate (DOCKER_SUBSTRATE=failed, no BUILDKIT_HOST) does not read DOWN and exit 1: $(grep docker "${D}/status-failed.out")"
# a substrate that was not running when ./run.sh -s started the agent container alone (docs/manual/install.md "Restart only the agent
# container"): DOWN with that reason, not the failed start's, and exit 1
[ "$(failrows status-nr DOCKER_SUBSTRATE=not-running)" == "1" ] && grep -q '^docker-buildkit: DOWN - the build substrate was not running at ./run.sh -s' "${D}/status-nr.out" && grep -q '^docker-registry: DOWN - the build substrate was not running at ./run.sh -s' "${D}/status-nr.out" \
	|| fail "9: a substrate that was not running at a single start (DOCKER_SUBSTRATE=not-running, no BUILDKIT_HOST) does not read both rows DOWN with that reason and exit 1: $(grep docker "${D}/status-nr.out")"
[ "$(failrows status-nc DOCKER_SUBSTRATE=)" == "0" ] && grep -q '^docker-buildkit: NOT CONFIGURED' "${D}/status-nc.out" \
	|| fail "9: CONTROL: no marker and no BUILDKIT_HOST does not read NOT CONFIGURED and exit 0: $(grep docker "${D}/status-nc.out")"
echo "ok 9 [rows-substrate-failed] - DOCKER_SUBSTRATE=failed with no BUILDKIT_HOST reads both rows DOWN and exits 1, DOCKER_SUBSTRATE=not-running (a single start found no substrate) reads them DOWN with that reason; control: without the marker it reads NOT CONFIGURED and exits 0"

# --- 10. a down cycle does not make the next good cycle announce every image as new ---
ax env DOCKER_SPOKE_WD=/tmp/dtest-wd /agent/charters/docker/loop.sh > "${D}/cycle-base.out" 2>&1 || fail "10: the baseline cycle: $(tail -3 "${D}/cycle-base.out")"
timeout 120 docker container stop "${DOCKER_REGISTRY_NAME}" > /dev/null || fail "10: could not stop ${DOCKER_REGISTRY_NAME}"
ax env DOCKER_SPOKE_WD=/tmp/dtest-wd /agent/charters/docker/loop.sh > "${D}/cycle-down.out" 2>&1 || fail "10: the down cycle: $(tail -3 "${D}/cycle-down.out")"
timeout 120 docker container start "${DOCKER_REGISTRY_NAME}" > /dev/null || fail "10: could not start ${DOCKER_REGISTRY_NAME} again"
for I in $(seq 1 60); do [ "$(ax curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 3 http://registry:5000/v2/ 2> /dev/null)" == "200" ] && break; sleep 2; done
ax env DOCKER_SPOKE_WD=/tmp/dtest-wd /agent/charters/docker/loop.sh > "${D}/cycle-good.out" 2>&1 || fail "10: the recovery cycle: $(tail -3 "${D}/cycle-good.out")"
grep -q '^HUB: new image' "${D}/cycle-good.out" && fail "10: the cycle after a down read announced images as new: $(grep '^HUB: ' "${D}/cycle-good.out")"
grep -q '^HUB: the registry answers again' "${D}/cycle-good.out" || fail "10: the recovery cycle did not report the registry answering again: $(grep '^HUB: ' "${D}/cycle-good.out")"
echo "ok 10 [prev-carry-forward] - a cycle whose registry read failed carries the last inventory forward, so the recovery cycle announces no image as new (only that the registry answers again)"

echo "Test-docker-spoke succeeded"
