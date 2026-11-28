#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The docker spoke's build substrate - a rootless BuildKit daemon and a registry as sidecar containers of the agent
# container (docs/manual/agents.md "Docker agent"). A host-side helper of build.sh, run.sh and stop.sh, also usable by hand:
#   ./docker.sh pull    - pull the two pinned public images that are not present yet (build.sh calls it)
#   ./docker.sh up      - TO=docker: create the two networks and the three volumes, start the registry and the daemon,
#                         and wait until each answers (run.sh calls it before it starts the agent container); on a
#                         host that restricts unprivileged user namespaces it starts nothing and says why
#   ./docker.sh down    - remove both containers and both networks carrying this harness's label; the volumes stay
#                         (stop.sh calls it)
#   ./docker.sh status  - show the containers, the volumes and whether each container answers
# No container publishes a host port, and no host Docker socket is mounted into any container. The daemon is
# moby/buildkit's rootless image: it runs as an unprivileged user and listens on a unix socket on a small tmpfs volume
# (DOCKER_SOCKET_VOLUME), which the agent container mounts at /run/buildkit (DOCKER_RUN_OPTS in .env); buildctl in the
# agent reaches the daemon there and nowhere else. The daemon and the registry share DOCKER_BUILD_NETWORK, which has
# egress for base images and the push; the agent and the registry share DOCKER_NETWORK, an internal network with no
# route out, so no build step can reach the agent container. The registry answers as registry:5000 on both networks.
# The build cache (DOCKER_CACHE_VOLUME) and the pushed images (DOCKER_REGISTRY_VOLUME) stay in their volumes.
# A container, network or volume is only used or removed when it carries this harness's label
# (do-agent-aws.docker=<CONTAINER>), so a same-named one of someone else is never touched.

source .env

if [ "${DEBUG}" == "true" ]; then
	set -x
fi

LABEL_KEY=do-agent-aws.docker
LABEL="${LABEL_KEY}=${CONTAINER}"

fail()
{
	echo "docker: ERROR - $*" >&2
	exit 1
}

# userns_restricted - 0 when the host restricts unprivileged user namespaces for unconfined programs
# (kernel.apparmor_restrict_unprivileged_userns=1, the default from Ubuntu 24.04 on). The rootless daemon runs
# AppArmor-unconfined (below) and needs one, so there it exits at once ("fork/exec /proc/self/exe: permission
# denied") and its restart policy starts it again without end. The value is read with sysctl, else from /proc/sys; a
# host without the setting (another kernel or distribution) or a read that fails counts as not restricted
USERNS_SYSCTL=kernel.apparmor_restrict_unprivileged_userns
USERNS_NOTE="the host restricts unprivileged user namespaces (${USERNS_SYSCTL}=1), which the rootless BuildKit daemon needs; the host owner's options (docs/manual/agents.md \"Docker agent\"): persist ${USERNS_SYSCTL}=0 in a file under /etc/sysctl.d and load it (sudo sysctl --system), or set SPOKE_DOCKER=false in .env.local"
userns_restricted()
{
	local V
	V=$(sysctl -n "${USERNS_SYSCTL}" 2> /dev/null) || V=$(cat "/proc/sys/${USERNS_SYSCTL//.//}" 2> /dev/null) || V=""
	[ "${V}" == "1" ]
}

# run <command> - echo it when VERBOSE=true, execute it unless DRY_RUN=true (the repo scripts' convention). The names
# (networks, volumes, the sidecars, the label), the images and the proxy values go into these commands through shq
# (.env), so each reaches docker as one word and nothing in it runs
run()
{
	if [ "${VERBOSE}" == "true" ]; then
		echo "$*"
	fi
	if [ "${DRY_RUN}" == "false" ]; then
		eval "$*"
	fi
}

# ours_container / ours_network / ours_volume <name> - 0 when it carries this harness's label (type-specific inspects:
# a container and a volume may share a name)
ours_container()
{
	[ "$(docker container inspect -f "{{index .Config.Labels \"${LABEL_KEY}\"}}" "$1" 2> /dev/null)" == "${CONTAINER}" ]
}

ours_network()
{
	[ "$(docker network inspect -f "{{index .Labels \"${LABEL_KEY}\"}}" "$1" 2> /dev/null)" == "${CONTAINER}" ]
}

ours_volume()
{
	[ "$(docker volume inspect -f "{{index .Labels \"${LABEL_KEY}\"}}" "$1" 2> /dev/null)" == "${CONTAINER}" ]
}

exists()
{
	docker container inspect "$1" > /dev/null 2>&1
}

# wait_ready <name> <seconds> - until the container is running and its health check reports healthy
wait_ready()
{
	[ "${DRY_RUN}" == "false" ] || return 0
	for i in $(seq 1 "$2"); do
		STATE=$(docker container inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2> /dev/null)
		case "${STATE}" in
		"running healthy")
			echo "docker: $1 ready after ${i}s"
			return 0
			;;
		dead*|exited*|"")
			echo "docker: $1 is not running (${STATE:-gone}); its last log lines:" >&2
			docker container logs --tail 15 "$1" >&2 2>&1
			return 1
			;;
		esac
		sleep 1
	done
	echo "docker: $1 not ready after $2s (state: ${STATE}); its last log lines:" >&2
	docker container logs --tail 15 "$1" >&2 2>&1
	return 1
}

# start_sidecar <name> <image> <options> [<command>] - (re)create one sidecar. A running one of ours on the current image
# and settings (a hash of the image id, the options and the command, kept in a label) is left alone, so ./run.sh can be
# re-run; a stopped one, or one whose image or settings changed, is replaced (the data stays in its volume).
start_sidecar()
{
	NAME=$1
	IMG=$2
	OPTS=$3
	ARGS=$4
	CONFIG=$( { echo "${IMG} ${OPTS} ${ARGS}"; docker image inspect -f '{{.Id}}' "${IMG}" 2> /dev/null; } | sha256sum | cut -c1-16)
	if [ "${DRY_RUN}" == "false" ] && exists "${NAME}"; then
		ours_container "${NAME}" || fail "a container named ${NAME} exists and is not this harness's (no ${LABEL} label) - refusing to touch it; set CONTAINER in .env.local to another name"
		RUNNING=$(docker container inspect -f '{{.State.Running}}' "${NAME}" 2> /dev/null)
		HAS=$(docker container inspect -f "{{index .Config.Labels \"${LABEL_KEY}.config\"}}" "${NAME}" 2> /dev/null)
		if [ "${RUNNING}" == "true" ] && [ "${HAS}" == "${CONFIG}" ]; then
			echo "docker: ${NAME} already running"
			return 0
		fi
		run "docker container rm -f -v $(shq "${NAME}") > /dev/null" || fail "could not remove the old ${NAME}"
	fi
	run "docker container run -d --name $(shq "${NAME}") --label $(shq "${LABEL}") --label ${LABEL_KEY}.config=${CONFIG} --restart unless-stopped ${OPTS} $(shq "${IMG}") ${ARGS} > /dev/null" \
		|| fail "could not start ${NAME}"
}

docker_pull()
{
	for I in ${DOCKER_BUILDKIT_IMAGE} ${DOCKER_REGISTRY_IMAGE}; do
		if docker image inspect "${I}" > /dev/null 2>&1; then
			echo "docker: ${I} present"
		else
			run "docker image pull -q $(shq "${I}")" || fail "cannot pull ${I} (anonymous pull from Docker Hub)"
		fi
	done
}

docker_up()
{
	# On a host that restricts unprivileged user namespaces nothing is created or started: the daemon could not run, and
	# a daemon left from an earlier start would go on restarting, so that one is removed (the registry, which needs no
	# user namespace, and the volumes stay)
	if [ "${DRY_RUN}" == "false" ] && userns_restricted; then
		echo "docker: not starting the build substrate - ${USERNS_NOTE}" >&2
		if exists "${DOCKER_BUILDKIT_NAME}" && ours_container "${DOCKER_BUILDKIT_NAME}"; then
			run "docker container rm -f -v $(shq "${DOCKER_BUILDKIT_NAME}") > /dev/null" \
				&& echo "docker: removed ${DOCKER_BUILDKIT_NAME}, left from an earlier start, which cannot run on this host" >&2
		fi
		exit 1
	fi
	for I in ${DOCKER_BUILDKIT_IMAGE} ${DOCKER_REGISTRY_IMAGE}; do
		[ "${DRY_RUN}" == "false" ] || break
		docker image inspect "${I}" > /dev/null 2>&1 || fail "the image ${I} is missing - run ./build.sh (or ./docker.sh pull) first"
	done
	# The daemon's network keeps egress (base images, the push); the agent's is internal, so it adds no route to the
	# agent container and nothing on it can reach a third party
	for N in "${DOCKER_BUILD_NETWORK}" "${DOCKER_NETWORK}"; do
		INTERNAL=""
		[ "${N}" == "${DOCKER_NETWORK}" ] && INTERNAL="--internal "
		if [ "${DRY_RUN}" == "false" ] && docker network inspect "${N}" > /dev/null 2>&1; then
			ours_network "${N}" || fail "a network named ${N} exists and is not this harness's (no ${LABEL} label) - refusing to use it"
			[ -z "${INTERNAL}" ] || [ "$(docker network inspect -f '{{.Internal}}' "${N}")" == "true" ] \
				|| fail "the network ${N} is not internal - remove it (./docker.sh down) and run again"
		else
			run "docker network create --label $(shq "${LABEL}") ${INTERNAL}$(shq "${N}") > /dev/null" || fail "could not create the network ${N}"
		fi
	done
	# The socket's volume is a tmpfs owned by the daemon's user (uid 1000 in the rootless image), so the daemon can create
	# its socket there; Docker mounts it once on the host and both containers see the same socket
	for V in "${DOCKER_SOCKET_VOLUME}" "${DOCKER_CACHE_VOLUME}" "${DOCKER_REGISTRY_VOLUME}"; do
		if [ "${DRY_RUN}" == "false" ] && docker volume inspect "${V}" > /dev/null 2>&1; then
			ours_volume "${V}" || fail "a volume named ${V} exists and is not this harness's (no ${LABEL} label) - refusing to use it"
		elif [ "${V}" == "${DOCKER_SOCKET_VOLUME}" ]; then
			run "docker volume create --label $(shq "${LABEL}") --driver local --opt type=tmpfs --opt device=tmpfs --opt o=uid=1000,gid=1000,mode=0700,size=1m $(shq "${V}") > /dev/null" \
				|| fail "could not create the volume ${V}"
		else
			run "docker volume create --label $(shq "${LABEL}") $(shq "${V}") > /dev/null" || fail "could not create the volume ${V}"
		fi
	done
	# Health checks every second while a sidecar starts (Docker 25+ --health-start-interval), then every 60 s
	H="--health-start-period 60s --health-start-interval 1s --health-interval 60s --health-timeout 10s --health-retries 3"
	# The registry first (the daemon pushes to it), on both networks as registry; its default log level is debug
	start_sidecar "${DOCKER_REGISTRY_NAME}" "${DOCKER_REGISTRY_IMAGE}" \
		"--network name=$(shq "${DOCKER_BUILD_NETWORK}"),alias=registry --network name=$(shq "${DOCKER_NETWORK}"),alias=registry -e REGISTRY_LOG_LEVEL=info -v $(shq "${DOCKER_REGISTRY_VOLUME}"):/var/lib/registry --health-cmd 'wget -q --spider http://127.0.0.1:5000/v2/' ${H}"
	wait_ready "${DOCKER_REGISTRY_NAME}" 60 || fail "the registry did not become ready"
	# The daemon: upstream's flags for the rootless image under Docker (docs/rootless.md at the pinned release) - seccomp
	# and AppArmor unconfined for the unshare and mount calls of each build step's sandbox, systempaths unconfined for
	# its own /proc; the daemon itself runs as the image's unprivileged user. A proxy from .env reaches its pulls, and
	# the registry is never behind it
	start_sidecar "${DOCKER_BUILDKIT_NAME}" "${DOCKER_BUILDKIT_IMAGE}" \
		"--network $(shq "${DOCKER_BUILD_NETWORK}") --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt systempaths=unconfined -e http_proxy=$(shq "${http_proxy}") -e https_proxy=$(shq "${https_proxy}") -e no_proxy=$(shq "registry,${no_proxy}") -v $(shq "${DOCKER_CACHE_VOLUME}"):/home/user/.local/share/buildkit -v $(shq "${DOCKER_SOCKET_VOLUME}"):/run/user/1000/buildkit --health-cmd 'buildctl debug workers' ${H}"
	wait_ready "${DOCKER_BUILDKIT_NAME}" 90 || fail "the BuildKit daemon did not become ready (on a host that restricts unprivileged user namespaces, e.g. kernel.apparmor_restrict_unprivileged_userns=1, the rootless daemon cannot start: docs/manual/agents.md \"Docker agent\")"
	echo "docker: build substrate up - the daemon ${DOCKER_BUILDKIT_NAME} (socket volume ${DOCKER_SOCKET_VOLUME}) and the registry ${DOCKER_REGISTRY_NAME} (registry:5000); no host port, no host Docker socket"
}

docker_down()
{
	for NAME in "${DOCKER_BUILDKIT_NAME}" "${DOCKER_REGISTRY_NAME}"; do
		exists "${NAME}" || continue
		if ours_container "${NAME}"; then
			run "docker container rm -f -v $(shq "${NAME}") > /dev/null" && echo "docker: removed ${NAME}"
		else
			echo "docker: WARNING - ${NAME} is not this harness's (no ${LABEL} label); left untouched" >&2
		fi
	done
	for N in "${DOCKER_NETWORK}" "${DOCKER_BUILD_NETWORK}"; do
		docker network inspect "${N}" > /dev/null 2>&1 || continue
		if ours_network "${N}"; then
			run "docker network rm $(shq "${N}") > /dev/null" && echo "docker: removed the network ${N}" \
				|| echo "docker: the network ${N} is still in use (is the agent container still running?); left in place" >&2
		else
			echo "docker: WARNING - the network ${N} is not this harness's; left untouched" >&2
		fi
	done
	if docker volume inspect "${DOCKER_REGISTRY_VOLUME}" > /dev/null 2>&1; then
		echo "docker: the build cache and the registry's images stay in the volumes ${DOCKER_CACHE_VOLUME} and ${DOCKER_REGISTRY_VOLUME} (docker volume rm deletes them)"
	fi
}

docker_status()
{
	docker ps -a --filter "label=${LABEL}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}'
	for V in "${DOCKER_SOCKET_VOLUME}" "${DOCKER_CACHE_VOLUME}" "${DOCKER_REGISTRY_VOLUME}"; do
		docker volume inspect "${V}" > /dev/null 2>&1 && echo "volume ${V}: present" || echo "volume ${V}: absent"
	done
	RC=0
	if docker container exec "${DOCKER_BUILDKIT_NAME}" buildctl debug workers > /dev/null 2>&1; then
		echo "daemon ${DOCKER_BUILDKIT_NAME}: answers"
	elif userns_restricted; then
		echo "daemon ${DOCKER_BUILDKIT_NAME}: not running - ${USERNS_NOTE}"
		RC=1
	else
		echo "daemon ${DOCKER_BUILDKIT_NAME}: does not answer"
		RC=1
	fi
	if CAT=$(docker container exec "${DOCKER_REGISTRY_NAME}" wget -q -O- http://127.0.0.1:5000/v2/_catalog 2> /dev/null); then
		echo "registry ${DOCKER_REGISTRY_NAME}: answers - ${CAT}"
	else
		echo "registry ${DOCKER_REGISTRY_NAME}: does not answer"
		RC=1
	fi
	return ${RC}
}

case "$1" in
	"pull")
		docker_pull
		;;
	"up")
		docker_up
		;;
	"down")
		docker_down
		;;
	"status")
		docker_status
		;;
	*)
		echo "Usage: $0 pull|up|down|status (see docs/manual/agents.md \"Docker agent\")"
		exit 1
		;;
esac
