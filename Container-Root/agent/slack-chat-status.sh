#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Report Slack chat responder status: running (polling|answering) or stopped, the chat gate with
# its reason, the stop flag, how many messages it has handled, and its last reply and log line.
#
# Same contract as /agent/loop-status.sh for the loop: liveness comes from chat.lock - a live
# responder holds an exclusive flock on it for its lifetime, released by the kernel even if the
# process dies - cross-checked against the pid recorded in chat.state. A stale state line with no
# live process is reported as stopped/stale, never as running. No Slack API call is made. Exit
# code: 0 when the responder is running, 1 when it is not.
#
# This is the first command to run when Slack is configured but nothing answers (docs/slack/README.md).

SLACK_DIR=${SLACK_DIR:-/wd/slack}

CHAT_LOG=${SLACK_DIR}/chat.log
CHAT_STATE=${SLACK_DIR}/chat.state
STOP_FLAG=${SLACK_DIR}/chat.STOP
LOCK_FILE=${SLACK_DIR}/chat.lock

SLACK_GATES_BIN=${SLACK_GATES_BIN:-$(dirname "$0")/slack-gates.sh}
if [ ! -f "${SLACK_GATES_BIN}" ]; then
	echo "ERROR: ${SLACK_GATES_BIN} not found - slack-gates.sh ships beside slack-chat-status.sh; set SLACK_GATES_BIN if it lives elsewhere" >&2
	exit 1
fi
. "${SLACK_GATES_BIN}"

echo "Chat gate: SLACK_CHAT_ENABLED=${SLACK_CHAT_ENABLED:-unset} (effective: ${SLACK_CHAT_EFFECTIVE} - ${SLACK_CHAT_REASON}); startup.sh starts the responder when on"

if [ ! -d "${SLACK_DIR}" ]; then
	echo "Slack chat responder: never started (no state directory ${SLACK_DIR})"
	exit 1
fi

STATE_LINE=$(cat "${CHAT_STATE}" 2>/dev/null)
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
		echo "Slack chat responder: running (lock held) but state pid ${PID} is not alive - state line may be mid-update"
	fi
	echo "Slack chat responder: running${PID:+ (pid ${PID})} - ${STATE_LINE:-no state line yet}"
else
	case "${STATE_LINE}" in
	"")
		echo "Slack chat responder: not running (no state recorded; start with /agent/slack-chat-start.sh)"
		;;
	STOPPED*)
		echo "Slack chat responder: stopped - ${STATE_LINE}"
		;;
	*)
		echo "Slack chat responder: stopped (stale state, no live process) - ${STATE_LINE}"
		;;
	esac
fi

if [ -f "${STOP_FLAG}" ]; then
	if [ "${RUNNING}" = "true" ]; then
		echo "Stop flag: present (${STOP_FLAG}) - responder halts at its next poll"
	else
		echo "Stop flag: present (${STOP_FLAG}) - /agent/slack-chat-start.sh removes it on the next start"
	fi
else
	echo "Stop flag: absent"
fi

HANDLED=$(grep -c " CHAT MSG " "${CHAT_LOG}" 2>/dev/null)
echo "Messages handled: ${HANDLED:-0} (log ${CHAT_LOG}; transcripts under ${SLACK_DIR}/chat/)"
LAST_REPLY=$(grep " CHAT REPLY " "${CHAT_LOG}" 2>/dev/null | tail -1)
echo "Last reply: ${LAST_REPLY:-none}"
LAST_LOG=$(tail -1 "${CHAT_LOG}" 2>/dev/null)
echo "Last log line: ${LAST_LOG:-none}"

[ "${RUNNING}" = "true" ]
