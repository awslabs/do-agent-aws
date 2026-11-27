#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Start the Slack chat responder (/agent/slack-chat.sh) detached.
#
# Same contract as /agent/loop-start.sh for the loop: starting is the explicit signal to run, so a
# chat.STOP flag left by a previous halt is removed here (slack-chat.sh never removes it); when the
# responder is already running this reports so and exits 0 (its single-instance lock makes a
# duplicate start harmless); the process runs in its own session (setsid) so slack-chat-stop.sh
# --now can terminate it and an in-flight claude call as one process group. Detached stdout goes
# to ${SLACK_DIR}/chat.stdout; the responder's own log is ${SLACK_DIR}/chat.log.
#
# The chat gate decides whether to start at all: SLACK_CHAT_ENABLED=true, or auto/unset while
# SLACK_BOT_TOKEN and SLACK_CHANNELS are set (/agent/slack-gates.sh); false refuses here with a
# clear message and exit 1. startup.sh calls this script when the gate is on, independent of the
# UI_START switch and of whether the autonomy loop runs - the responder is how a person talks to
# the agent, the loop is how the agent works on goals (docs/manual/channels.md "Slack connectivity").

export HOME=${HOME:-/home/agent}

SLACK_DIR=${SLACK_DIR:-/wd/slack}
SLACK_CHAT_BIN=${SLACK_CHAT_BIN:-$(dirname "$0")/slack-chat.sh}

CHAT_STATE=${SLACK_DIR}/chat.state
STOP_FLAG=${SLACK_DIR:?}/chat.STOP
LOCK_FILE=${SLACK_DIR}/chat.lock

SLACK_GATES_BIN=${SLACK_GATES_BIN:-$(dirname "$0")/slack-gates.sh}
if [ ! -f "${SLACK_GATES_BIN}" ]; then
	echo "ERROR: ${SLACK_GATES_BIN} not found - slack-gates.sh ships beside slack-chat-start.sh; set SLACK_GATES_BIN if it lives elsewhere" >&2
	exit 1
fi
. "${SLACK_GATES_BIN}"
if [ "${SLACK_CHAT_EFFECTIVE}" != "on" ]; then
	echo "Slack chat responder not started: the chat gate is off (${SLACK_CHAT_REASON}). It is on when SLACK_CHAT_ENABLED=true, or when it is auto or unset (the .env default) and both SLACK_BOT_TOKEN and SLACK_CHANNELS are set; SLACK_CHAT_ENABLED=false turns it off. /agent/slack-gates.sh shows the effective gates."
	exit 1
fi

if [ ! -x "${SLACK_CHAT_BIN}" ]; then
	echo "ERROR: ${SLACK_CHAT_BIN} not found or not executable - slack-chat.sh ships beside this script; set SLACK_CHAT_BIN if it lives elsewhere" >&2
	exit 1
fi

mkdir -p "${SLACK_DIR}"

# Already running? A live responder holds an exclusive flock on chat.lock for its lifetime.
exec 9> "${LOCK_FILE}"
if ! flock -n 9; then
	PID=$(grep -o 'pid=[0-9]*' "${CHAT_STATE}" 2>/dev/null | cut -d= -f2)
	echo "Slack chat responder already running${PID:+ (pid ${PID})}; nothing to do."
	exit 0
fi
exec 9>&-

if [ -f "${STOP_FLAG}" ]; then
	echo "Removing stop flag ${STOP_FLAG} (explicit start)"
	rm -f "${STOP_FLAG:?}"
fi

setsid nohup "${SLACK_CHAT_BIN}" >> "${SLACK_DIR}/chat.stdout" 2>&1 &
PID=$!

sleep 2
if kill -0 "${PID}" 2>/dev/null; then
	echo "Slack chat responder started pid=${PID} log=${SLACK_DIR}/chat.log state=${CHAT_STATE}"
else
	echo "Slack chat responder exited immediately; last output:"
	tail -5 "${SLACK_DIR}/chat.stdout" 2>/dev/null
	exit 1
fi
