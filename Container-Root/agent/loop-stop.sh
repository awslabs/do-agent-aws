#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Stop the autonomy loop.
#
# Default: create ${AUTONOMY_LOOP_DIR}/STOP so the loop halts cleanly before its next fire
# (an in-flight fire finishes first). With --now, additionally terminate the loop right away:
# the exact pid is resolved from loop.state - never from a process-name pattern - and its
# process group (set by loop-start.sh) is signaled so an in-flight fire ends with it.
# The flag stays in place until the next explicit /agent/loop-start.sh removes it.

AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}

LOOP_STATE=${AUTONOMY_LOOP_DIR}/loop.state
STOP_FLAG=${AUTONOMY_LOOP_DIR}/STOP
LOCK_FILE=${AUTONOMY_LOOP_DIR}/loop.lock

if [ ! -d "${AUTONOMY_LOOP_DIR}" ]; then
	echo "Autonomy loop: never started (no state directory ${AUTONOMY_LOOP_DIR})"
	exit 1
fi

touch "${STOP_FLAG}"
echo "Stop flag created: ${STOP_FLAG}"

running()
{
	[ -f "${LOCK_FILE}" ] || return 1
	exec 9< "${LOCK_FILE}"
	if flock -n 9; then
		exec 9<&-
		return 1
	fi
	exec 9<&-
	return 0
}

if ! running; then
	echo "Autonomy loop is not running; flag applies to the next start."
	exit 0
fi

PID=$(grep -o 'pid=[0-9]*' "${LOOP_STATE}" 2>/dev/null | cut -d= -f2)

if [ "$1" != "--now" ]; then
	echo "Autonomy loop${PID:+ (pid ${PID})} halts before its next fire; use '$0 --now' to terminate immediately."
	exit 0
fi

if [ -z "${PID}" ] || ! kill -0 "${PID}" 2>/dev/null; then
	echo "Cannot resolve a live loop pid from ${LOOP_STATE}; not sending signals."
	exit 1
fi

# Signal the loop's own process group when it has one (loop-start.sh launches with setsid),
# so an in-flight fire is terminated with the loop; otherwise signal the single pid.
PGID=$(ps -o pgid= -p "${PID}" 2>/dev/null | tr -d ' ')
if [ -n "${PGID}" ] && [ "${PGID}" = "${PID}" ]; then
	kill -TERM -- -"${PID}" 2>/dev/null
else
	kill -TERM "${PID}" 2>/dev/null
fi

WAITED=0
while kill -0 "${PID}" 2>/dev/null && [ ${WAITED} -lt 30 ]; do
	sleep 1
	WAITED=$((WAITED + 1))
done

if kill -0 "${PID}" 2>/dev/null; then
	echo "Loop pid ${PID} still alive ${WAITED}s after TERM; sending KILL."
	if [ -n "${PGID}" ] && [ "${PGID}" = "${PID}" ]; then
		kill -KILL -- -"${PID}" 2>/dev/null
	else
		kill -KILL "${PID}" 2>/dev/null
	fi
	sleep 1
fi

if kill -0 "${PID}" 2>/dev/null; then
	echo "Autonomy loop pid ${PID} did not terminate."
	exit 1
fi

echo "Autonomy loop stopped (pid ${PID} terminated); state: $(cat "${LOOP_STATE}" 2>/dev/null)"
