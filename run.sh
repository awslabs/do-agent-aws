#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# ./run.sh [-s|--single] [<command>] - start this harness instance (docs/manual/install.md "What runs"):
#   no argument    a detached run of the agent container, after the sidecars it uses: the Plane board (./plane.sh up;
#                  only with UI_PLANE=true, it is off by default), the docker spoke's build substrate (./docker.sh up)
#                  and the kanban board (./kanban.sh up) - the docker target's six containers, eighteen with the Plane
#                  board on. Compose: docker-compose up -d of every service; swarm, kubernetes and
#                  the sandbox: their one command
#   <command>      an interactive run (-it) of the agent container with that command, its words passed as given
#   -s, --single   the agent container alone: no sidecar is started; the agent joins the boards' networks when they
#                  exist, and mounts and joins the build substrate when it runs, and starts without what is not there
#                  (one WARNING each, docker target). After ./stop.sh -s, or a rebuild: ./build.sh && ./stop.sh -s &&
#                  ./run.sh -s, the boards and the
#                  substrate untouched (docs/manual/install.md "Restart only the agent container"). The docker and compose targets;
#                  refused by name on swarm, kubernetes and the sandbox. Only a leading -s or --single is an option: any
#                  other first word is the command (./run.sh -x runs -x), and ./run.sh -s bash -s runs bash -s
# your settings file .env.local: created on the first run, an edited tracked .env moved into it once
# (docs/manual/install.md "Settings"); a copy of this script without it skips the step
[ -x ./env-local.sh ] && ./env-local.sh

source .env

if [ "${DEBUG}" == "true" ]; then
	set -x
fi

# -s/--single, removed from the arguments before anything reads them, so the words that remain are what they always
# were: none, a detached run; else the container command of an interactive run
SINGLE=false
SINGLE_HINT=""
while [ $# -gt 0 ]; do
	case "$1" in
		-s|--single) SINGLE=true; shift ;;
		*) break ;;
	esac
done
if [ "${SINGLE}" == "true" ]; then
	case "${TO}" in
		"swarm"|"kubernetes"|"sandbox")
			echo "run.sh: -s/--single applies to the docker and compose targets, not TO=${TO} (the instance is one unit there) - ./run.sh without it starts it" >&2
			exit 2
			;;
	esac
	if [ "${VERBOSE}" == "true" ]; then
		if [ "${TO}" == "compose" ]; then
			echo "run.sh: -s - starting the agent service alone: no other service is started (./run.sh without -s starts every service)"
		else
			echo "run.sh: -s - starting the agent container alone: no board and no build substrate is started, the agent joins the ones that run (./stop.sh -s && ./run.sh starts them)"
		fi
	fi
	# the preflight (preflight.sh): a single start on the docker target creates no network, so it needs no address pool
	# (compose creates the project's network again after a full down, so its count stays)
	if [ "${TO}" != "compose" ]; then
		PREFLIGHT_POOLS_NEEDED=0
		PREFLIGHT_POOLS_WHICH="none with -s: the agent container alone joins the networks that run"
	fi
	# the sidecar WARNINGs below name the way to start what is not there: a full start after the single stop (each up
	# leaves a running sidecar alone)
	SINGLE_HINT=" (./stop.sh -s && ./run.sh starts it)"
fi

if [ -z "$1" ]; then
	MODE=-d
else
	MODE=-it
fi 

function generate_docker_compose
{
	CMD="mkdir -p $(dirname "${COMPOSE_FILE}"); ${ENVSUBST} < ${COMPOSE_TEMPLATE} > ${COMPOSE_FILE}"
	if [ "${VERBOSE}" == "true" ]; then
		echo "${CMD}"
	fi
	if [ "${DRY_RUN}" == "false" ]; then
		eval "${CMD}"
	fi
}

function generate_kubernetes_manifests
{
	# The Ingress (plain HTTP to the home proxy, no authentication in front of it) and the HorizontalPodAutoscaler are
	# opt-in (.env KUBERNETES_INGRESS, KUBERNETES_HPA): off, their manifest is not rendered and a copy an earlier render
	# left in KUBERNETES_APP_PATH is removed, so `kubectl apply -f` of that folder never creates them
	SKIP_MANIFESTS=""
	[ "${KUBERNETES_HPA}" == "true" ] || SKIP_MANIFESTS="${SKIP_MANIFESTS} 040-hpa.yaml"
	[ "${KUBERNETES_INGRESS}" == "true" ] || SKIP_MANIFESTS="${SKIP_MANIFESTS} 050-ingress.yaml"
	CMD="BASE_PATH=$(pwd); mkdir -p ${KUBERNETES_APP_PATH}; cd ${KUBERNETES_TEMPLATE_PATH}; for f in *.yaml; do case ' ${SKIP_MANIFESTS} ' in *\" \$f \"*) rm -f \${BASE_PATH}/\${KUBERNETES_APP_PATH}/\$f; continue ;; esac; cat \$f | envsubst > \${BASE_PATH}/\${KUBERNETES_APP_PATH}/\$f; done; cd \${BASE_PATH}"
        if [ "${VERBOSE}" == "true" ]; then
                echo "${CMD}"
        fi
        if [ "${DRY_RUN}" == "false" ]; then
                eval "${CMD}"
        fi 
	
}

# Preflight (preflight.sh, shared with build.sh): a start on this host creates networks from Docker's address pools and
# needs disk; the numbers are printed, and a start that would certainly fail (fewer free pools than an instance needs)
# is refused with the command that frees them. Kubernetes targets do not use this host's Docker; the sandbox target
# (TO=sandbox) has a preflight of its own: what a local sandbox needs on this host (to/sandbox/README.md "TO=sandbox")
case "${TO}" in
	"docker"|"compose")
		source ./preflight.sh
		preflight run || exit 1
		;;
	"sandbox")
		source ./preflight.sh
		preflight sandbox || exit 1
		;;
esac

# the networks the agent container joins once it runs (the kanban board's, on the docker target with NETWORK set; the
# docker spoke's build substrate's internal one, on the docker target while the substrate is up): run.sh's own, never a
# value from the caller's environment. Each join is a direct docker call: nothing in it is eval'd
KANBAN_JOIN_NETWORK=""
DOCKER_JOIN_NETWORK=""
case "${TO}" in
	"compose")
		# The kanban board (docs/manual/boards.md "Kanban board"): its login and env files, and its services in an overlay file
		# added with -f only while the board is on (the base file stays a valid swarm stack); after the start the
		# database password is applied in the board's database container
		COMPOSE_KANBAN_OPTS=""
		if [ "${SINGLE}" == "true" ]; then
			# -s: the agent service alone - its file rendered again, so a changed setting or image takes effect; the
			# board's overlays added as an earlier ./run.sh rendered them, not rendered again and their services not
			# touched (--no-deps), so compose resolves the same project; no ./kanban.sh init or db-password
			[ -f "${COMPOSE_KANBAN_FILE}" ] && COMPOSE_KANBAN_OPTS="-f ${COMPOSE_KANBAN_FILE}"
			[ -f "${COMPOSE_KANBAN_FILE}" ] && [ -f "${COMPOSE_KANBAN_RELAY_FILE}" ] && COMPOSE_KANBAN_OPTS="${COMPOSE_KANBAN_OPTS} -f ${COMPOSE_KANBAN_RELAY_FILE}"
			generate_docker_compose
			CMD="${DOCKER_COMPOSE} -f ${COMPOSE_FILE} ${COMPOSE_KANBAN_OPTS} up -d --no-deps ${CONTAINER}"
		else
			if [ -n "${KANBAN_RUN_OPTS}" ]; then
				./kanban.sh init || exit 1
				KANBAN_CMD="mkdir -p $(dirname "${COMPOSE_KANBAN_FILE}"); ${ENVSUBST} < ${COMPOSE_KANBAN_TEMPLATE} > ${COMPOSE_KANBAN_FILE}"
				if [ "${VERBOSE}" == "true" ]; then
					echo "${KANBAN_CMD}"
				fi
				if [ "${DRY_RUN}" == "false" ]; then
					eval "${KANBAN_CMD}"
				fi
				COMPOSE_KANBAN_OPTS="-f ${COMPOSE_KANBAN_FILE}"
				# the board's relay (UI_KANBAN_RELAY=true): its service in a second overlay
				if [ -n "${KANBAN_RELAY_URL}" ]; then
					RELAY_CMD="${ENVSUBST} < ${COMPOSE_KANBAN_RELAY_TEMPLATE} > ${COMPOSE_KANBAN_RELAY_FILE}"
					if [ "${VERBOSE}" == "true" ]; then
						echo "${RELAY_CMD}"
					fi
					if [ "${DRY_RUN}" == "false" ]; then
						eval "${RELAY_CMD}"
					fi
					COMPOSE_KANBAN_OPTS="${COMPOSE_KANBAN_OPTS} -f ${COMPOSE_KANBAN_RELAY_FILE}"
				fi
			fi
			generate_docker_compose
			CMD="${DOCKER_COMPOSE} -f ${COMPOSE_FILE} ${COMPOSE_KANBAN_OPTS} up -d"
			if [ -n "${COMPOSE_KANBAN_OPTS}" ]; then
				CMD="${CMD} && ./kanban.sh db-password \$(${DOCKER_COMPOSE} -f ${COMPOSE_FILE} ${COMPOSE_KANBAN_OPTS} ps -q kanban-db)"
			fi
		fi
		;;
	"swarm")
		generate_docker_compose
		CMD="docker stack deploy -c ${COMPOSE_FILE} ${SWARM_STACK_NAME}"
		;;
	"kubernetes")
		generate_kubernetes_manifests
		CMD="${KUBECTL} -n ${NAMESPACE} apply -f ${KUBERNETES_APP_PATH}"
		;;
	"sandbox")
		# TO=sandbox (to/sandbox/README.md "TO=sandbox"): the microVM is created from the kit ./build.sh built (sbx reuses
		# that build) with the descriptor's sizes; no board sidecar, no published port, no mount - the kit image carries
		# the sandbox's environment. An interactive run (./run.sh <command>) creates it and runs the command in it, the
		# words quoted as for the docker target
		read -r SANDBOX_CPUS SANDBOX_MEMORY < <(preflight_sandbox_sizes) || exit 1
		CMD_ARGS=""
		if [ $# -gt 0 ]; then
			CMD_ARGS=$(printf ' %q' "$@")
		fi
		CMD="${SBX} create --name ${SANDBOX_NAME} --cpus ${SANDBOX_CPUS} --memory ${SANDBOX_MEMORY} ${SANDBOX_CREATE_OPTS} ${SANDBOX_KIT}"
		if [ -n "${CMD_ARGS}" ]; then
			CMD="${CMD} && ${SBX} exec -it ${SANDBOX_NAME}${CMD_ARGS}"
		fi
		;;
	*)
		# The self-hosted Plane board (docs/manual/boards.md "Plane board"; only with the board on - PLANE_RUN_OPTS is empty with
		# UI_PLANE=false, the default, and nothing of Plane starts): its sidecars start and are seeded first, and the agent
		# container joins their network (a second --network, Docker 25+) so its home proxy serves the board at
		# plane.localhost. A board that does not come up does not stop the agent; without the network, or on host or
		# none networking (NETWORK), the agent starts without the board
		if [ -n "${PLANE_RUN_OPTS}" ]; then
			if echo " ${NETWORK} " | grep -qE '[ =](host|none) '; then
				echo "WARNING: NETWORK=${NETWORK} - the agent cannot also join ${PLANE_NETWORK}; it starts without the Plane board"
				PLANE_RUN_OPTS=""
			else
				# not with -s: the board is not started, and the agent joins its network when it is there (the check below)
				if [ "${SINGLE}" != "true" ]; then
					./plane.sh up || echo "WARNING: the Plane board did not come up (see the plane: lines above); starting the agent anyway - ./plane.sh status shows the sidecars"
				fi
				if [ "${DRY_RUN}" == "false" ] && ! docker network inspect "${PLANE_NETWORK}" > /dev/null 2>&1; then
					echo "WARNING: no ${PLANE_NETWORK} network - the agent starts without the Plane board${SINGLE_HINT}"
					PLANE_RUN_OPTS=""
				fi
			fi
			RUN_OPTS="${RUN_OPTS} ${PLANE_RUN_OPTS}"
		fi
		checkTO "${TO}"
		# The docker spoke's build substrate (docs/manual/agents.md "Docker agent"): the BuildKit daemon and the registry start
		# first; the agent container mounts the daemon's socket volume and, once it runs, joins the registry's internal
		# network with a direct docker call (DOCKER_JOIN_NETWORK, below; a network with no route out leaves the agent's own
		# routes as they are). A substrate that does not come up does not stop the agent: it starts without it. An
		# interactive run (./run.sh <command>), host or none networking, or no container name start without it too, with a
		# warning
		if [ -n "${DOCKER_RUN_OPTS}" ]; then
			if [ "${MODE}" != "-d" ] || [ -z "${CONTAINER_NAME}" ] || echo " ${NETWORK} " | grep -qE '[ =](host|none) '; then
				echo "WARNING: the build substrate needs a detached run of a named container on bridge networking; the agent starts without it"
			elif [ "${SINGLE}" == "true" ]; then
				# -s: the substrate is not started; the agent mounts the daemon's socket volume and joins the registry's
				# network when the substrate runs - its network, its socket volume and its two containers running, what
				# ./docker.sh up leaves - else it starts without, marked for its rows as a substrate that was not running at
				# a single start (DOCKER_SUBSTRATE=not-running: nothing was tried, so not failed)
				if [ "${DRY_RUN}" != "false" ] || { docker network inspect "${DOCKER_NETWORK}" > /dev/null 2>&1 && docker volume inspect "${DOCKER_SOCKET_VOLUME}" > /dev/null 2>&1 \
					&& [ "$(docker container inspect -f '{{.State.Running}}' "${DOCKER_BUILDKIT_NAME}" 2> /dev/null)" == "true" ] \
					&& [ "$(docker container inspect -f '{{.State.Running}}' "${DOCKER_REGISTRY_NAME}" 2> /dev/null)" == "true" ]; }; then
					RUN_OPTS="${RUN_OPTS} ${DOCKER_RUN_OPTS}"
					DOCKER_JOIN_NETWORK=${DOCKER_NETWORK}
				else
					echo "WARNING: the build substrate is not running - the agent starts without it (./docker.sh status shows the sidecars; ./stop.sh -s && ./run.sh starts them)"
					RUN_OPTS="${RUN_OPTS} -e DOCKER_SUBSTRATE=not-running"
				fi
			elif ./docker.sh up; then
				RUN_OPTS="${RUN_OPTS} ${DOCKER_RUN_OPTS}"
				DOCKER_JOIN_NETWORK=${DOCKER_NETWORK}
			else
				echo "WARNING: the build substrate did not come up (see the docker: lines above); starting the agent without it - ./docker.sh status shows the sidecars"
				# tell the agent's rows this was a failure, not a target that runs no substrate (ui-status.sh reads it)
				RUN_OPTS="${RUN_OPTS} -e DOCKER_SUBSTRATE=failed"
			fi
		fi
		# The self-hosted kanban board (docs/manual/boards.md "Kanban board"): its three sidecars start first, and the agent
		# container joins the board server's network so its home proxy serves the board at kanban.localhost (the
		# database and Electric are on an internal network of their own). A board that does not come up does not
		# stop the agent; without the network the agent starts as before (kanban.localhost then serves the agent
		# runner)
		# With NETWORK set the agent starts on that network and is connected to the board's afterwards - a bridge
		# network only: on host or none networking (or the default bridge, which has no name resolution) the board is
		# skipped with a warning
		if [ -n "${KANBAN_RUN_OPTS}" ]; then
			# not with -s: the board is not started, and the agent joins its network when it is there (the checks below)
			if [ "${SINGLE}" != "true" ]; then
				./kanban.sh up || echo "WARNING: the kanban board did not come up (see the kanban: lines above); starting the agent anyway - ./kanban.sh status shows the sidecars"
			fi
			NET_NAME=$(echo "${NETWORK}" | sed -E 's/^[[:space:]]*--net(work)?[[:space:]=]+//; s/[[:space:]].*$//')
			if [ "${DRY_RUN}" == "false" ] && ! docker network inspect "${KANBAN_NETWORK}" > /dev/null 2>&1; then
				echo "WARNING: no ${KANBAN_NETWORK} network - the agent starts without the board${SINGLE_HINT}"
				KANBAN_RUN_OPTS=""
				KANBAN_RUN_NETWORK=""
			elif [ -n "${NET_NAME}" ]; then
				KANBAN_RUN_NETWORK=""
				if [ "${NET_NAME}" == "host" ] || [ "${NET_NAME}" == "none" ] || [ "${NET_NAME}" == "bridge" ] \
					|| [ "$(docker network inspect -f '{{.Driver}}' "${NET_NAME}" 2> /dev/null)" != "bridge" ] \
					|| [ "${MODE}" != "-d" ] || [ -z "${CONTAINER_NAME}" ]; then
					echo "WARNING: NETWORK=${NETWORK} - the agent cannot also join ${KANBAN_NETWORK} (it needs a user-defined bridge network, a container name and a detached run); the agent starts without the board"
					KANBAN_RUN_OPTS=""
				else
					KANBAN_JOIN_NETWORK=${KANBAN_NETWORK}
				fi
			fi
		fi
		# an interactive run's command (./run.sh <command>) reaches docker as its words were given: each is quoted for
		# the eval below, so nothing in it is expanded or run on the host
		CMD_ARGS=""
		if [ $# -gt 0 ]; then
			CMD_ARGS=$(printf ' %q' "$@")
		fi
		CMD="docker container run ${RUN_OPTS} ${CONTAINER_NAME} ${MODE} ${NETWORK} ${KANBAN_RUN_NETWORK} ${KANBAN_RUN_OPTS} ${PORT_MAP} ${VOL_MAP} ${REGISTRY}${IMAGE}${TAG}${CMD_ARGS}"
		# the agent container joins KANBAN_JOIN_NETWORK and DOCKER_JOIN_NETWORK once it runs (below)
		;;
esac

if [ "${VERBOSE}" == "true" ]; then
	echo "${CMD}"
	if [ -n "${KANBAN_JOIN_NETWORK}" ]; then
		# as the shell would read it, the words of the direct call below
		printf 'docker network connect %q %q\n' "${KANBAN_JOIN_NETWORK}" "${CONTAINER_NAME#--name }"
	fi
	if [ -n "${DOCKER_JOIN_NETWORK}" ]; then
		printf 'docker network connect %q %q\n' "${DOCKER_JOIN_NETWORK}" "${CONTAINER_NAME#--name }"
	fi
fi

# A start that fails says so: run.sh exits with the start command's status and one ERROR line (the line above it,
# docker's or the shell's for a command that does not parse, names the cause), and on the docker target a detached
# agent container that is not running two seconds after its start is an ERROR too, with its state and last log lines.
# So a ./run.sh that exits 0 left an agent container that was running two seconds after its start; that does not prove
# the agent in it answers. An interactive run (./run.sh <command>) exits with its command's status. With NETWORK set,
# the agent container joins the kanban board's network once it runs; a join that fails is a WARNING, as for the
# board's other troubles: the agent runs without the board and run.sh still exits 0. On the sandbox target a create
# that fails is the same ERROR line with its status (sbx create refuses a name that exists: ./stop.sh removes it), and a
# detached create that succeeds prints the two commands that come next
if [ "${DRY_RUN}" == "false" ]; then
	eval "${CMD}"
	RC=$?
	echo ""
	if [ "${RC}" != "0" ]; then
		[ "${MODE}" == "-d" ] && echo "run.sh: ERROR - the start command exited ${RC} (the lines above name the cause); fix it, then ./stop.sh && ./run.sh" >&2
		exit ${RC}
	fi
	case "${TO}" in
		"compose"|"swarm"|"kubernetes")
			;;
		"sandbox")
			if [ "${MODE}" == "-d" ]; then
				echo "run.sh: sandbox ${SANDBOX_NAME} created. A shell in it: ./exec.sh - the agent (Claude Code with the harness configuration): ${SBX} run --name ${SANDBOX_NAME} - remove it: ./stop.sh"
			fi
			;;
		*)
			AGENT_NAME=${CONTAINER_NAME#--name }
			if [ "${MODE}" == "-d" ] && [ -n "${AGENT_NAME}" ] && [ "${AGENT_NAME}" != "${CONTAINER_NAME}" ]; then
				# a container that exits at once has done so within two seconds
				sleep 2
				STATE=$(docker container inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${AGENT_NAME}" 2> /dev/null)
				if [ "${STATE%% *}" != "running" ]; then
					WHY="no such container"
					[ -n "${STATE}" ] && WHY="${STATE%% *}, exit code ${STATE#* }"
					echo "run.sh: ERROR - the agent container ${AGENT_NAME} is not running right after its start (${WHY}); its last log lines:" >&2
					docker container logs --tail 20 "${AGENT_NAME}" 2>&1 | sed 's/^/  /' >&2
					echo "run.sh: fix the cause, then ./stop.sh && ./run.sh" >&2
					exit 1
				fi
			fi
			;;
	esac
	if [ -n "${KANBAN_JOIN_NETWORK}" ]; then
		docker network connect "${KANBAN_JOIN_NETWORK}" "${CONTAINER_NAME#--name }" \
			|| echo "WARNING: the agent container ${CONTAINER_NAME#--name } runs, but it could not join ${KANBAN_JOIN_NETWORK} (the line above names the cause) - it runs without the kanban board; ./stop.sh && ./run.sh tries again"
	fi
	if [ -n "${DOCKER_JOIN_NETWORK}" ]; then
		docker network connect "${DOCKER_JOIN_NETWORK}" "${CONTAINER_NAME#--name }" \
			|| echo "WARNING: the agent container ${CONTAINER_NAME#--name } runs, but it could not join ${DOCKER_JOIN_NETWORK} (the line above names the cause) - the stack's registry is out of its reach and image builds fail; ./docker.sh status shows the sidecars"
	fi
fi

if [ "${DEBUG}" == "true" ]; then
	set +x
fi
