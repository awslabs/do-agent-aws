#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Report autonomy loop status: running (firing|sleeping|idle) or stopped, plus the stop flag
# and the last outcome line from the log.
#
# Liveness comes from loop.lock - a live loop holds an exclusive flock on it for its lifetime,
# released by the kernel even if the process dies - cross-checked against the pid recorded in
# loop.state. A stale state line with no live process is reported as stopped/stale, never as
# running. Exit code: 0 when the loop is running, 1 when it is not.

AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}

LOOP_LOG=${AUTONOMY_LOOP_DIR}/loop.log
LOOP_STATE=${AUTONOMY_LOOP_DIR}/loop.state
STOP_FLAG=${AUTONOMY_LOOP_DIR}/STOP
LOCK_FILE=${AUTONOMY_LOOP_DIR}/loop.lock

if [ ! -d "${AUTONOMY_LOOP_DIR}" ]; then
	echo "Autonomy loop: never started (no state directory ${AUTONOMY_LOOP_DIR})"
	exit 1
fi

STATE_LINE=$(cat "${LOOP_STATE}" 2>/dev/null)
PID=$(echo "${STATE_LINE}" | grep -o 'pid=[0-9]*' | cut -d= -f2)

RUNNING=false
if [ -f "${LOCK_FILE}" ]; then
	exec 9< "${LOCK_FILE}"
	if ! flock -n 9; then
		RUNNING=true
	fi
	exec 9<&-
fi

if [ "${RUNNING}" = "true" ]; then
	if [ -n "${PID}" ] && ! kill -0 "${PID}" 2>/dev/null; then
		echo "Autonomy loop: running (lock held) but state pid ${PID} is not alive - state line may be mid-update"
	fi
	echo "Autonomy loop: running${PID:+ (pid ${PID})} - ${STATE_LINE:-no state line yet}"
else
	case "${STATE_LINE}" in
	"")
		echo "Autonomy loop: not running (no state recorded)"
		;;
	STOPPED*)
		echo "Autonomy loop: stopped - ${STATE_LINE}"
		;;
	*)
		echo "Autonomy loop: stopped (stale state, no live process) - ${STATE_LINE}"
		;;
	esac
fi

if [ -f "${STOP_FLAG}" ]; then
	if [ "${RUNNING}" = "true" ]; then
		echo "Stop flag: present (${STOP_FLAG}) - loop halts before its next fire"
	else
		echo "Stop flag: present (${STOP_FLAG}) - /agent/loop-start.sh removes it on the next start"
	fi
else
	echo "Stop flag: absent"
fi

LAST_OUTCOME=$(grep " END rc=" "${LOOP_LOG}" 2>/dev/null | tail -1)
echo "Last outcome: ${LAST_OUTCOME:-none (no completed fire in ${LOOP_LOG})}"
LAST_LOG=$(tail -1 "${LOOP_LOG}" 2>/dev/null)
echo "Last log line: ${LAST_LOG:-none}"

[ "${RUNNING}" = "true" ]
