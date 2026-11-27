#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

source .env

if [ "${DEBUG}" == "true" ]; then
        set -x
fi

# Command line flags - parsed before the positional arguments below.
# -s|--shell is the per-shell escape hatch documented in .env and docs/manual/ui.md "tmux in the
# browser": it sets TMUX_AUTO_ATTACH=false for the exec'd shell only, so the shell stays
# plain instead of attaching to the shared agent tmux session.
## EXEC_SHELL_OPTS - docker exec switches injected by -s|--shell
EXEC_SHELL_OPTS=""
## EXEC_SHELL_PREFIX - shell prefix injected by -s|--shell on the kubernetes path,
## where kubectl exec has no environment switch; an exported variable in the pod's
## sh -c is inherited by the bash it starts, so the .bashrc attach guard sees it
EXEC_SHELL_PREFIX=""
while true; do
	case "$1" in
		"-h"|"--help")
			echo ""
			echo "Usage: ${0} [-h|--help] [-s|--shell] [index] [cmd ...]"
			echo ""
			echo "Open a shell or execute a specified command in the running container"
			echo ""
			echo "    -h, --help    display this usage information and exit"
			echo "    -s, --shell   start a plain bash shell instead of attaching to tmux;"
			echo "                  interactive shells attach to the shared '${AGENT_TMUX_SESSION_NAME}' tmux"
			echo "                  session by default (docs/manual/ui.md \"tmux in the browser\") -"
			echo "                  this flag sets TMUX_AUTO_ATTACH=false for this shell only"
			echo "    index         when TO=compose|swarm|kubernetes - index of the container,"
			echo "                  task, or pod to open the shell in, default 1"
			echo "    cmd ...       when TO=docker|sandbox - command to execute in the container"
			echo "                  (TO=docker) or the sandbox (TO=sandbox) instead of opening a shell"
			echo ""
			exit 0
			;;
		"-s"|"--shell")
			EXEC_SHELL_OPTS="-e TMUX_AUTO_ATTACH=false "
			EXEC_SHELL_PREFIX="export TMUX_AUTO_ATTACH=false; "
			shift
			;;
		-*)
			echo ""
			echo "${0}: unknown option $1"
			echo "Use ${0} --help to display usage"
			echo ""
			exit 1
			;;
		*)
			break
			;;
	esac
done

case "${TO}" in
        "compose")
		CONTAINER_INDEX=$1
		if [ "$CONTAINER_INDEX" == "" ]; then
			CONTAINER_INDEX=1
		fi
		CMD="docker exec -it ${EXEC_SHELL_OPTS}${COMPOSE_PROJECT_NAME}_${CONTAINER}_${CONTAINER_INDEX} sh -c 'if [ -e /bin/bash ]; then /bin/bash; else sh; fi'"
		;;
	"swarm")
		SERVICE_INDEX=$1
		if [ "$SERVICE_INDEX" == "" ]; then
			SERVICE_INDEX=1
		fi
		TASK_ID=${SWARM_STACK_NAME}_${SWARM_SERVICE_NAME}.${SERVICE_INDEX}
		CONTAINER_ID=$(docker ps | grep ${TASK_ID} | cut -d ' ' -f 1)
		if [ "${CONTAINER_ID}" == "" ]; then
			CONTAINER_HOST=$(docker service ps ${SWARM_STACK_NAME}_${SWARM_SERVICE_NAME} -f desired-state=running --format="{{.Node}} {{.Name }} {{.ID}}" | grep ${TASK_ID} | cut -d ' ' -f 1)
			echo ""
			if [ "${CONTAINER_HOST}" == "" ]; then
				echo "Could not find running task ${TASK_ID}"
			else
				echo "Cannot connect to service task ${TASK_ID}"
				echo "Only connections to tasks running on the local host are supported"
				echo "You may connect to the node running this task ($CONTAINER_HOST) and use docker exec locally"
				echo " or configure remote docker daemon access." 
			fi
			echo ""
			CMD=""
		else
			CMD="docker exec -it ${EXEC_SHELL_OPTS}${CONTAINER_ID} sh -c 'if [ -e /bin/bash ]; then /bin/bash; else sh; fi'"
		fi
		;;
	"kubernetes")
                CONTAINER_INDEX=$1
                if [ "$CONTAINER_INDEX" == "" ]; then
                        CONTAINER_INDEX=1
                fi
		CMD="unset DEBUG; ${KUBECTL} -n ${NAMESPACE} exec -it $( ${KUBECTL} -n ${NAMESPACE} get pod | grep ${APP_NAME} | head -n ${CONTAINER_INDEX} | cut -d ' ' -f 1 ) -- sh -c '${EXEC_SHELL_PREFIX}if [ -e /bin/bash ]; then /bin/bash; else sh; fi'"
		;;
	"sandbox")
		# the docker form against the sandbox (to/sandbox/README.md "TO=sandbox"): sbx exec takes -e NAME=value as docker
		# exec does, so -s|--shell works unchanged; a stopped sandbox is started first. The command's words are
		# re-quoted (printf %q, as run.sh does) so each reaches the sandbox as it was given
		if [ "$1" == "" ]; then
			CMD_ARGS=" sh -c 'if [ -e /bin/bash ]; then /bin/bash; else sh; fi'"
		else
			CMD_ARGS=$(printf ' %q' "$@")
		fi
		CMD="${SBX} exec -it ${EXEC_SHELL_OPTS}${SANDBOX_NAME}${CMD_ARGS}"
		;;
	*)
		checkTO "${TO}"
		# the command's words are re-quoted (printf %q, as run.sh does) so each reaches the container as it was given
		if [ "$1" == "" ]; then
			CMD_ARGS=" sh -c 'if [ -e /bin/bash ]; then /bin/bash; else sh; fi'"
		else
			CMD_ARGS=$(printf ' %q' "$@")
		fi
		CMD="docker container exec -it ${EXEC_SHELL_OPTS}${CONTAINER}${CMD_ARGS}"
		;;
esac

if [ "${VERBOSE}" == "true" ]; then
        echo "${CMD}"
fi

if [ "${DRY_RUN}" == "false" ]; then
        eval "${CMD}"
fi

if [ "${DEBUG}" == "true" ]; then
        set +x
fi

