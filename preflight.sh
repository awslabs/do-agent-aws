#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side preflight shared by build.sh and run.sh: what THIS host needs before a build or a start, each gap named
# with its exact numbers and the one command that fixes it. Sourced, then `preflight build`, `preflight run` or, on the
# sandbox target (TO=sandbox), `preflight sandbox`; messages are prefixed with the calling script's name. Nothing here
# changes the host: it reads docker's state and the disk and prints; pruning stays the person's command.
#
#   docker usable      `docker info` answers (the user is in the docker group)                 build + run: refuse
#   buildx             the BuildKit builder the build options use                             build: refuse
#   disk               GB free where Docker keeps its images vs BUILD_MIN_FREE_GB (30)        build: refuse; run: warn
#   address pools      Docker gives every bridge network a subnet from its default address pools - 31 by default
#                      (/etc/docker/daemon.json "default-address-pools" when present, each pool base/prefix split
#                      into "size" subnets; PREFLIGHT_DAEMON_JSON names another file, for tests) - and a start that
#                      needs more subnets than are free fails with "could not find an available, non-overlapping
#                      IPv4 address pool". A harness instance takes PREFLIGHT_POOLS_NEEDED (2: its own network and the
#                      board's internal one; plus Plane's two with the Plane board on - UI_PLANE=true sets
#                      PLANE_RUN_OPTS; it is off by default; docker target only, where its sidecars run - and plus
#                      the docker spoke's build substrate's two on the
#                      docker target, whose daemon and registry have two: 4 with the shipped defaults; 0 for
#                      ./run.sh -s, which starts the agent container alone and creates no network - run.sh sets
#                      PREFLIGHT_POOLS_NEEDED and PREFLIGHT_POOLS_WHICH, the words after the number). Printed every
#                      time; when fewer are free than an instance
#                      needs: run refuses (the start would certainly fail), build warns (a build creates no network).
#                      The fix is the person's: the stale networks of past instances with no container left
#                      (listed when there are any) and `docker network prune`, which removes every network no
#                      container uses - this script never runs it.
#   CVE scan           build only, CVE_SCAN=true with TRIVY=docker (docs/manual/supply-chain.md "CVE scan"): the scan at the end of the build runs
#                      trivy as a container that reads the image through the Docker socket; warn when the current Docker
#                      endpoint is not a unix socket this user can write (a tcp or ssh DOCKER_HOST, a socket of another user)
#                      - the build would run and its last step fail. preflight_docker_socket, the endpoint's socket path,
#                      is what scan.sh mounts.
#   sandbox            TO=sandbox only (to/sandbox/README.md "Local sandboxes"), in place of the checks above: the sbx
#                      cli on PATH; /dev/kvm (a host without a hypervisor runs no local sandbox, and sbx cannot build
#                      the kit there - PREFLIGHT_KVM names another path, for tests); the local sandbox daemon
#                      answering (`sbx ls -q`); the kit descriptor's resources@1 readable (python3 with PyYAML), which
#                      is where build.sh and run.sh take the sandbox's --cpus and --memory from (preflight_sandbox_sizes,
#                      the one source of the sizes, read as e2e.sh reads it)

preflight_docker_socket()
{
	# the unix socket of the current Docker endpoint: DOCKER_HOST when set, else the active context's docker endpoint, else the
	# daemon's default; nothing for an endpoint that is not a unix socket (tcp://, ssh://)
	local host=${DOCKER_HOST:-}
	[ -n "${host}" ] || host=$(docker context inspect --format '{{(index .Endpoints "docker").Host}}' 2> /dev/null)
	case "${host}" in
		unix://*) echo "${host#unix://}" ;;
		"") echo /var/run/docker.sock ;;
	esac
}

preflight_cve_scan()
{
	# WARN (never refuse) before a build whose last step is the CVE scan (CVE_SCAN=true, TRIVY=docker) when the scanner container
	# cannot reach the image: the Docker endpoint is not a unix socket, or the socket is not writable by this user
	local who=${PREFLIGHT_WHO:-$(basename "$0")} sock
	[ "${CVE_SCAN:-true}" == "true" ] && [ "${TRIVY:-docker}" == "docker" ] || return 0
	sock=$(preflight_docker_socket)
	if [ -z "${sock}" ]; then
		echo "${who}: WARNING - the CVE scan at the end of the build (CVE_SCAN=true) runs trivy as a container that reads the image through the Docker socket, and the Docker endpoint is not a unix socket (DOCKER_HOST=${DOCKER_HOST:-$(docker context inspect --format '{{(index .Endpoints "docker").Host}}' 2> /dev/null)}): ./scan.sh will fail there - in .env.local, TRIVY=<trivy command> for a host install, or CVE_SCAN=false (docs/manual/supply-chain.md \"CVE scan\")"
	elif [ ! -S "${sock}" ] || [ ! -w "${sock}" ]; then
		echo "${who}: WARNING - the CVE scan at the end of the build (CVE_SCAN=true) runs trivy as a container that reads the image through the Docker socket, and ${sock} is not there or not writable by $(id -un): ./scan.sh will fail there - in .env.local, TRIVY=<trivy command> for a host install, or CVE_SCAN=false (docs/manual/supply-chain.md \"CVE scan\")"
	fi
}

preflight_pools_total()
{
	# the number of subnets Docker's default address pools hold: from daemon.json's default-address-pools when set, else 31
	local f=${PREFLIGHT_DAEMON_JSON:-/etc/docker/daemon.json}
	if [ -r "${f}" ]; then
		python3 - "${f}" << 'PY' 2>/dev/null && return 0
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
pools = d.get("default-address-pools")
if not isinstance(pools, list) or not pools:
    sys.exit(1)
n = 0
for p in pools:
    base = str(p.get("base", "")); size = int(p.get("size", 0))
    prefix = int(base.split("/")[1]) if "/" in base else 0
    if not prefix or size < prefix:
        sys.exit(1)
    n += 2 ** (size - prefix)
print(n)
PY
	fi
	echo 31
}

preflight_pools()
{
	# preflight_pools <build|run>: 0 when a start fits, 1 when run must refuse; prints the numbers either way
	local mode=$1 who=${PREFLIGHT_WHO:-$(basename "$0")} total used free need stale which
	# the instance's own network and the kanban board's internal one; the Plane board (docs/manual/boards.md "Plane board", off by
	# default) adds its two when it is on (.env sets PLANE_RUN_OPTS with UI_START and UI_PLANE) on the docker target, the
	# only one that runs its sidecars; the docker spoke's build substrate (docs/manual/agents.md "Docker agent") its two on the docker
	# target too; PREFLIGHT_POOLS_NEEDED and _WHICH, when set, win
	need=2
	which="its own network, the board's internal one"
	if [ -n "${PLANE_RUN_OPTS}" ] && [ "${TO}" == "docker" ]; then
		need=$(( need + 2 ))
		which="${which}, Plane's two"
	fi
	if [ -n "${DOCKER_RUN_OPTS}" ] && [ "${TO}" == "docker" ]; then
		need=$(( need + 2 ))
		which="${which}, the build substrate's two"
	fi
	need=${PREFLIGHT_POOLS_NEEDED:-${need}}
	which=${PREFLIGHT_POOLS_WHICH:-${which}}
	total=$(preflight_pools_total)
	used=$(docker network ls --filter driver=bridge --format '{{.Name}}' 2>/dev/null | grep -c .)
	free=$(( total - used ))
	[ "${free}" -lt 0 ] && free=0
	echo "${who}: docker address pools: ${used} of ${total} in use, ${free} free; a harness instance needs ${need} (${which})"
	[ "${free}" -ge "${need}" ] && return 0
	# the candidates a person may remove: networks of past instances and test runs with no container left on them
	stale=$(docker network ls --filter driver=bridge --format '{{.Name}}' 2>/dev/null | grep -E '^(adav-|ado-|test-)|-test$|-smoke$' | while read -r n; do
		[ "$(docker network inspect -f '{{len .Containers}}' "${n}" 2>/dev/null)" == "0" ] && echo "${n}"
	done | tr '\n' ' ')
	if [ "${mode}" == "run" ]; then
		echo "${who}: too few free Docker address pools for a start (${free} free, ${need} needed) - a start would fail with 'could not find an available, non-overlapping IPv4 address pool'. Free them: ${stale:+stale networks with no container: ${stale}- }docker network prune (removes every network no container uses; asks first) - nothing is pruned by this script" >&2
		return 1
	fi
	echo "${who}: WARNING - too few free Docker address pools for a start (${free} free, ${need} needed): ./run.sh will refuse until networks are freed (${stale:+stale networks with no container: ${stale}- }docker network prune)"
	return 0
}

preflight_docker_engine()
{
	# WARN (never refuse) on the docker target with the build substrate on when the engine API is older than 1.44
	# (Docker Engine 25): the sidecars' health check uses --health-start-interval, Docker 25+, so ./docker.sh up fails
	# and the agent starts without the substrate. Quiet when the version is unreadable or the substrate is off.
	local who=${PREFLIGHT_WHO:-$(basename "$0")} api lowest
	[ -n "${DOCKER_RUN_OPTS}" ] && [ "${TO}" == "docker" ] || return 0
	api=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null)
	echo "${api}" | grep -qE '^[0-9]+\.[0-9]+$' || return 0
	lowest=$(printf '%s\n%s\n' "${api}" 1.44 | sort -V | head -1)
	if [ "${api}" != "1.44" ] && [ "${lowest}" == "${api}" ]; then
		echo "${who}: WARNING - Docker Engine API ${api} is older than 1.44 (Engine 25): the build substrate's health check needs Docker 25+, so ./docker.sh up fails and the agent starts without it (docs/manual/agents.md \"Docker agent\")"
	fi
}

preflight_sandbox_sizes()
{
	# prints the descriptor's cpu and memory (resources@1, e.g. "4 8g"), the fields to/sandbox/test/e2e.sh reads; 1 with
	# the reason on stderr when they cannot be read: no such file, YAML that does not parse, no resources@1 capability, no
	# cpu or memory in it
	local who=${PREFLIGHT_WHO:-$(basename "$0")} f=${SANDBOX_DESCRIPTOR:-./to/sandbox/template/do-agent-aws-sandbox.yaml} sizes rc
	if ! python3 -c 'import yaml' 2> /dev/null; then
		echo "${who}: python3 with PyYAML is needed to read the sandbox's sizes from ${f} - python3 -m pip install pyyaml (or the distribution's python3-yaml package)" >&2
		return 1
	fi
	# one line on stdout: the sizes (exit 0), or why they could not be read (exit 1); a Python error is that line, not a
	# traceback
	sizes=$(python3 - "${f}" 2> /dev/null << 'EOF'
import sys, yaml
try:
    with open(sys.argv[1]) as fh:
        d = yaml.safe_load(fh)
    caps = [c for c in ((d or {}).get("capabilities") or []) if isinstance(c, dict) and c.get("type") == "com.docker.sandbox/resources@1"]
    if not caps:
        raise ValueError("no com.docker.sandbox/resources@1 capability")
    r = caps[0].get("config") or {}
    if "cpu" not in r or "memory" not in r:
        raise ValueError("resources@1 has no cpu or no memory")
    print(r["cpu"], r["memory"])
except Exception as e:
    print(" ".join(str(e).split()) or type(e).__name__)
    sys.exit(1)
EOF
	)
	rc=$?
	case "${rc}:${sizes}" in
		0:[0-9]*" "[0-9]*) echo "${sizes}"; return 0 ;;
	esac
	echo "${who}: could not read cpu and memory from the kit descriptor's resources@1 (${f}): ${sizes:-nothing was read} - the sandbox's sizes have that one source (to/sandbox/README.md)" >&2
	return 1
}

preflight_sandbox()
{
	# preflight sandbox -> 0 to go on, 1 to stop: what a local sandbox needs on THIS host (to/sandbox/README.md "Local
	# sandboxes"), each gap named with its fix; nothing is changed
	local who=${PREFLIGHT_WHO:-$(basename "$0")} rc=0 sbx=${SBX:-sbx} kvm=${PREFLIGHT_KVM:-/dev/kvm}
	if ! command -v "${sbx}" > /dev/null 2>&1; then
		echo "${who}: ${sbx} is not on PATH - install sbx 0.47.0, the Docker Sandboxes cli (https://docs.docker.com/ai/sandboxes/), as to/sandbox/README.md 'Local sandboxes' says, then sbx login" >&2
		return 1
	fi
	if [ ! -e "${kvm}" ]; then
		echo "${who}: no ${kvm} - this host has no hypervisor, so it runs no local sandbox and sbx cannot build the kit here (the build stops with 'OCI exporter is not supported for the docker driver'); use a host with KVM, or a cloud sandbox from a pushed kit (to/sandbox/push-kit.sh; to/sandbox/README.md 'Local sandboxes' and 'Cloud sandboxes')" >&2
		rc=1
	fi
	if ! "${sbx}" ls -q > /dev/null 2>&1; then
		echo "${who}: the local sandbox daemon does not answer (${sbx} ls -q fails) - sign in once with '${sbx} login', or start it with '${sbx} daemon start -d' (to/sandbox/README.md 'Local sandboxes')" >&2
		rc=1
	fi
	preflight_sandbox_sizes > /dev/null || rc=1
	return ${rc}
}

preflight_wd_owner()
{
	# a start on Linux: files under wd/ (or the agent-state path) that another uid owns - typically root, from an image that
	# ran as root - are files the agent (AGENT_UID) cannot update; one WARNING names the hand-over (docs/manual/install.md "Container user")
	[ "$(uname -s)" == "Linux" ] || return 0
	local d other
	for d in "${VOLUME_PATH_EXTERNAL:-$(pwd)}/wd" "${AGENT_STATE_PATH_EXTERNAL}"; do
		[ -n "${d}" ] && [ -d "${d}" ] || continue
		other=$(find "${d}" -maxdepth 4 ! -uid "${AGENT_UID:-1000}" -print -quit 2> /dev/null)
		if [ -n "${other}" ]; then
			echo "${who}: WARNING - ${other} belongs to uid $(stat -c '%u' "${other}"), not the agent's ${AGENT_UID:-1000}: the agent cannot update what another uid owns under ${d} - hand it over once: sudo chown -R ${AGENT_UID:-1000}:${AGENT_GID:-1000} ${d} (docs/manual/install.md \"Container user\")"
			return 0
		fi
	done
}

preflight()
{
	# preflight <build|run|sandbox> -> 0 to go on, 1 to stop (every stop prints why and the fix)
	local mode=$1 who=${PREFLIGHT_WHO:-$(basename "$0")} rc=0
	if [ "${mode}" == "sandbox" ]; then
		preflight_sandbox
		return $?
	fi
	if ! docker info > /dev/null 2>&1; then
		echo "${who}: docker is not usable by $(id -un) - install Docker Engine and add the user to the docker group (sudo usermod -aG docker $(id -un), then log in again); README 'Prerequisites'" >&2
		return 1
	fi
	if [ "${mode}" == "build" ] && ! docker buildx version > /dev/null 2>&1; then
		echo "${who}: docker buildx (BuildKit) is not installed and the build uses it - Ubuntu 22.04+/Debian 13+: sudo apt install docker-buildx; elsewhere Docker's own packages (docker-buildx-plugin); README 'Prerequisites'" >&2
		rc=1
	fi
	DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
	FREE_GB=$(df -BG --output=avail "${DOCKER_ROOT:-/var/lib/docker}" 2>/dev/null | tail -1 | tr -dc '0-9')
	[ -n "${FREE_GB}" ] || FREE_GB=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
	if [ -n "${FREE_GB}" ]; then
		echo "${who}: disk: ${FREE_GB} GB free where Docker keeps its images (${DOCKER_ROOT:-/var/lib/docker}); the image and its build cache need about ${BUILD_MIN_FREE_GB:-30} GB"
		if [ "${FREE_GB}" -lt "${BUILD_MIN_FREE_GB:-30}" ]; then
			if [ "${mode}" == "build" ]; then
				echo "${who}: ${FREE_GB} GB free where Docker keeps its images (${DOCKER_ROOT:-/var/lib/docker}); the image and its build cache need about ${BUILD_MIN_FREE_GB:-30} GB - grow the volume, or set BUILD_MIN_FREE_GB in .env if you know better; 'docker system df' shows what Docker holds" >&2
				rc=1
			else
				echo "${who}: WARNING - ${FREE_GB} GB free where Docker keeps its images; a rebuild needs about ${BUILD_MIN_FREE_GB:-30} GB ('docker system df' shows what Docker holds; the start itself needs far less)"
			fi
		fi
	fi
	preflight_docker_engine
	[ "${mode}" == "build" ] && preflight_cve_scan
	[ "${mode}" == "run" ] && preflight_wd_owner
	preflight_pools "${mode}" || rc=1
	return ${rc}
}
