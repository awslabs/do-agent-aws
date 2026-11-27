#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Stop the Slack chat responder.
#
# Same contract as /agent/loop-stop.sh for the loop. Default: create ${SLACK_DIR}/chat.STOP so
# the responder halts cleanly at its next poll (a reply in flight is finished and posted first -
# at most one poll interval plus one claude call). With --now, additionally terminate it right
# away: the exact pid is resolved from chat.state - never from a process-name pattern - and its
# process group (set by slack-chat-start.sh) is signaled so an in-flight claude call ends with
# it; a message being answered at that moment stays in the inbox and is answered after the next
# start. The flag stays in place until the next explicit /agent/slack-chat-start.sh removes it.

SLACK_DIR=${SLACK_DIR:-/wd/slack}

CHAT_STATE=${SLACK_DIR}/chat.state
STOP_FLAG=${SLACK_DIR}/chat.STOP
LOCK_FILE=${SLACK_DIR}/chat.lock

if [ ! -d "${SLACK_DIR}" ]; then
	echo "Slack chat responder: never started (no state directory ${SLACK_DIR})"
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
	echo "Slack chat responder is not running; flag applies to the next start."
	exit 0
fi

PID=$(grep -o 'pid=[0-9]*' "${CHAT_STATE}" 2>/dev/null | cut -d= -f2)

if [ "$1" != "--now" ]; then
	echo "Slack chat responder${PID:+ (pid ${PID})} halts at its next poll; use '$0 --now' to terminate immediately."
	exit 0
fi

if [ -z "${PID}" ] || ! kill -0 "${PID}" 2>/dev/null; then
	echo "Cannot resolve a live responder pid from ${CHAT_STATE}; not sending signals."
	exit 1
fi

# Signal the responder's own process group when it has one (slack-chat-start.sh launches with
# setsid), so an in-flight claude call is terminated with it; otherwise signal the single pid.
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
	echo "Responder pid ${PID} still alive ${WAITED}s after TERM; sending KILL."
	if [ -n "${PGID}" ] && [ "${PGID}" = "${PID}" ]; then
		kill -KILL -- -"${PID}" 2>/dev/null
	else
		kill -KILL "${PID}" 2>/dev/null
	fi
	sleep 1
fi

if kill -0 "${PID}" 2>/dev/null; then
	echo "Slack chat responder pid ${PID} did not terminate."
	exit 1
fi

echo "Slack chat responder stopped (pid ${PID} terminated); state: $(cat "${CHAT_STATE}" 2>/dev/null)"
