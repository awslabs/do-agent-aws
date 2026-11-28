#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

source .env

if [ "${DEBUG}" == "true" ]; then
        set -x
fi

case "${TO}" in
	"compose")
		# with the kanban board's services when run.sh rendered their overlay file (docs/manual/boards.md "Kanban board")
		COMPOSE_KANBAN_OPTS=""
		[ -f "${COMPOSE_KANBAN_FILE}" ] && COMPOSE_KANBAN_OPTS="-f ${COMPOSE_KANBAN_FILE}"
		# and the board's relay, when run.sh rendered its overlay too
		[ -f "${COMPOSE_KANBAN_FILE}" ] && [ -f "${COMPOSE_KANBAN_RELAY_FILE}" ] && COMPOSE_KANBAN_OPTS="${COMPOSE_KANBAN_OPTS} -f ${COMPOSE_KANBAN_RELAY_FILE}"
		CMD="${DOCKER_COMPOSE} -f ${COMPOSE_FILE} ${COMPOSE_KANBAN_OPTS} ps -a"
		;;
	"swarm")
		CMD="docker stack ps ${SWARM_STACK_NAME}"
		;;
	"kubernetes")
		CMD="${KUBECTL} -n ${NAMESPACE} get all"
		;;
	"sandbox")
		# the sandbox's line of sbx ls under its header (to/sandbox/README.md "TO=sandbox")
		CMD="${SBX} ls | grep -E '^(SANDBOX|${SANDBOX_NAME})[[:space:]]'"
		;;
	*)
		checkTO "${TO}"
		CMD="docker ps -a | grep ${CONTAINER}"
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

