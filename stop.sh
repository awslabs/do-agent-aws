#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# ./stop.sh [-s|--single] - stop this harness instance (docs/manual/install.md "What runs"):
#   no argument    remove every container and service of the instance: the agent container, then the kanban board's
#                  sidecars (./kanban.sh down), the docker spoke's build substrate (./docker.sh down) and the Plane
#                  board's (./plane.sh down) - the docker target's six containers, eighteen with the Plane board on
#                  (UI_PLANE=true); every volume and everything under wd/ stays, so the next ./run.sh starts with the
#                  same data. Compose: docker-compose down; swarm,
#                  kubernetes and the sandbox: their one command
#   -s, --single   remove the agent container alone - the boards and the build substrate keep running, and ./run.sh -s
#                  starts a new agent container that joins them (docs/manual/install.md "Restart only the agent container"): the
#                  rebuild idiom is ./build.sh && ./stop.sh -s && ./run.sh -s. The docker and compose targets; refused
#                  by name on swarm, kubernetes and the sandbox, where the instance is one unit
# Any other argument is refused with the usage line, exit 2, before anything runs; -h or --help prints the usage.

SINGLE=false
usage()
{
	echo "Usage: $0 [-s|--single] - no argument removes every container and service of this harness instance; -s or --single removes the agent container alone, so the boards and the build substrate keep running (docs/manual/install.md \"Restart only the agent container\"); -h prints this"
}
while [ $# -gt 0 ]; do
	case "$1" in
		-s|--single) SINGLE=true ;;
		-h|--help) usage; exit 0 ;;
		*) echo "stop.sh: unknown argument '$1' - stop.sh takes -s or --single, or no argument" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

source .env

if [ "${DEBUG}" == "true" ]; then
        set -x
fi

# -s/--single: the docker and compose targets, where the agent container (compose: its service) can go alone; on swarm,
# kubernetes and the sandbox the instance is one stack, one set of manifests or one microVM, so the flag is refused
# before anything runs
if [ "${SINGLE}" == "true" ]; then
	case "${TO}" in
		"swarm"|"kubernetes"|"sandbox")
			echo "stop.sh: -s/--single applies to the docker and compose targets, not TO=${TO} (the instance is one unit there) - ./stop.sh without it removes it" >&2
			exit 2
			;;
	esac
	if [ "${VERBOSE}" == "true" ]; then
		if [ "${TO}" == "compose" ]; then
			echo "stop.sh: -s - removing the agent service alone; the board's services keep running (./stop.sh without -s removes every service)"
		else
			echo "stop.sh: -s - removing the agent container alone; the kanban board, the docker spoke's build substrate and the Plane board, whichever run, keep running (./stop.sh without -s removes them)"
		fi
	fi
fi

LEDGER_CMD=""
case "${TO}" in
        "compose")
		# with the kanban board's services when run.sh rendered their overlay file (docs/manual/boards.md "Kanban board")
		COMPOSE_KANBAN_OPTS=""
		[ -f "${COMPOSE_KANBAN_FILE}" ] && COMPOSE_KANBAN_OPTS="-f ${COMPOSE_KANBAN_FILE}"
		# and the board's relay, when run.sh rendered its overlay too
		[ -f "${COMPOSE_KANBAN_FILE}" ] && [ -f "${COMPOSE_KANBAN_RELAY_FILE}" ] && COMPOSE_KANBAN_OPTS="${COMPOSE_KANBAN_OPTS} -f ${COMPOSE_KANBAN_RELAY_FILE}"
		if [ "${SINGLE}" == "true" ]; then
			# -s: the agent service alone, stopped and removed with its anonymous volumes (its named agent-state volumes
			# stay, as after a down); the same -f files, so compose resolves the project run.sh started, and no down
			CMD="${DOCKER_COMPOSE} -f ${COMPOSE_FILE} ${COMPOSE_KANBAN_OPTS} rm -s -f -v ${CONTAINER}"
		else
			CMD="${DOCKER_COMPOSE} -f ${COMPOSE_FILE} ${COMPOSE_KANBAN_OPTS} down"
		fi
		;;
	"swarm")
		CMD="docker stack rm ${SWARM_STACK_NAME}"
		;;
	"kubernetes")
		CMD="${KUBECTL} delete -f ${KUBERNETES_APP_PATH}"
		;;
	"sandbox")
		# the sandbox goes with its containers and its sandbox-scoped secrets, as the docker target's stop removes the
		# container; `sbx stop ${SANDBOX_NAME}` is the keep-state alternative (to/sandbox/README.md "TO=sandbox")
		CMD="${SBX} rm --force ${SANDBOX_NAME}"
		;;
	*)
                checkTO "${TO}"
		# -v: the anonymous bind-backed volumes of the agent-state mounts go with the container (each ./run.sh
		# creates a fresh set; without -v they pile up as dangling volumes). The local bind driver never deletes
		# the host folders, so wd/agent-state keeps the state.
		CMD="docker container rm -f -v ${CONTAINER}"
		# first, in the container: a stop line per running session in the session ledger (wd/supervisor/
		# sessions-ledger.jsonl, docs/manual/agents.md "Spoke agents"), so /agent/supervisor.sh resume can bring one back after
		# ./run.sh; a container that is not running records nothing and the stop goes on
		LEDGER_CMD="docker container exec ${CONTAINER} /agent/supervisor.sh record-stop"
		;;
esac

if [ "${VERBOSE}" == "true" ]; then
        [ -n "${LEDGER_CMD}" ] && echo "${LEDGER_CMD}"
        echo "${CMD}"
fi

if [ "${DRY_RUN}" == "false" ]; then
        [ -n "${LEDGER_CMD}" ] && { timeout 60 ${LEDGER_CMD} > /dev/null 2>&1 || true; }
        eval "${CMD}"
fi

# docker target: the kanban board's sidecars too, by the names run.sh gave them and only when they carry this
# harness's label, after the agent container that shares the board server's network; the board's data stays in its
# volumes (docs/manual/boards.md "Kanban board"). Not gated on the UI flags, so a flag changed since ./run.sh leaves nothing
# behind. Not with -s: the board keeps running (docs/manual/install.md "Restart only the agent container").
case "${TO}" in
	"compose"|"swarm"|"kubernetes"|"sandbox")
		;;
	*)
		if [ "${SINGLE}" != "true" ]; then
			./kanban.sh down
			# and the docker spoke's build substrate, the same way: the daemon and the registry by the names run.sh gave
			# them and only with this harness's label, after the agent container that mounts the daemon's socket volume;
			# the build cache and the registry's images stay in their volumes (docs/manual/agents.md "Docker agent")
			./docker.sh down
		fi
		;;
esac

if [ "${DEBUG}" == "true" ]; then
        set +x
fi

# docker target: the Plane board's sidecars too - every container and the network carrying this harness's label,
# after the agent container that shares the network; the board's data stays in its volumes (docs/manual/boards.md "Plane
# board"). Not gated on the UI flags, so a flag changed since ./run.sh leaves nothing behind. Not with -s.
case "${TO}" in
	"compose"|"swarm"|"kubernetes"|"sandbox")
		;;
	*)
		[ "${SINGLE}" == "true" ] || ./plane.sh down
		;;
esac
