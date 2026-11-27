#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Report Slack connectivity status honestly - configuration, the effective state of the four
# gates (loop autostart, watch, post, chat - the shared decision in slack-gates.sh, with its
# reason), cursors, inbox depth, and the last watch run. The token VALUE is never printed, only whether
# one is configured.
# No Slack API call is made; this reads only the environment and the state directory, so it
# is safe to run any time. Exit code: 0 when the connectivity is configured (token and
# channels present), 1 when it is not.
#
# Settings (from .env / environment): SLACK_BOT_TOKEN, SLACK_CHANNELS, AUTONOMY_LOOP,
# SLACK_WATCH_ENABLED, SLACK_POST_ENABLED, SLACK_CHAT_ENABLED, SLACK_DIR (default /wd/slack), SLACK_GATES_BIN
# (default: slack-gates.sh beside this script).

SLACK_DIR=${SLACK_DIR:-/wd/slack}

SLACK_GATES_BIN=${SLACK_GATES_BIN:-$(dirname "$0")/slack-gates.sh}
if [ ! -f "${SLACK_GATES_BIN}" ]; then
	echo "ERROR: ${SLACK_GATES_BIN} not found - slack-gates.sh ships beside slack-status.sh; set SLACK_GATES_BIN if it lives elsewhere" >&2
	exit 1
fi
. "${SLACK_GATES_BIN}"

count_lines()
{
	C=$(grep -c . "$1" 2>/dev/null)
	echo "${C:-0}"
}

CONFIGURED=true

echo "Slack connectivity status:"

if [ -n "${SLACK_BOT_TOKEN:+set}" ]; then
	echo "  token:      configured (value not shown)"
else
	echo "  token:      NOT configured (set SLACK_BOT_TOKEN in .env.local or the host environment)"
	CONFIGURED=false
fi

if [ -n "${SLACK_CHANNELS}" ]; then
	echo "  channels:   ${SLACK_CHANNELS}"
else
	echo "  channels:   NOT configured (set SLACK_CHANNELS in .env.local)"
	CONFIGURED=false
fi

# The four gates as decided by slack-gates.sh: auto/unset = on when token and channels are set
slack_gates_report | sed 's/^/  /'

if [ -f "${SLACK_DIR}/identity" ]; then
	echo "  identity:   $(cat "${SLACK_DIR}/identity") (the bot's own posts carry this user_id)"
else
	echo "  identity:   unknown (recorded by the first successful slack-watch.sh run)"
fi

echo "  state dir:  ${SLACK_DIR}"

for CURSOR_FILE in "${SLACK_DIR}"/cursor-*; do
	[ -f "${CURSOR_FILE}" ] || continue
	CHANNEL=${CURSOR_FILE##*/cursor-}
	CURSOR=$(cat "${CURSOR_FILE}")
	CURSOR_UTC=$(date -u -d "@${CURSOR%%.*}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
	echo "  channel ${CHANNEL}: cursor=${CURSOR} (${CURSOR_UTC}) threads=$(count_lines "${SLACK_DIR}/threads-${CHANNEL}")"
done

echo "  inbox:      $(count_lines "${SLACK_DIR}/inbox.jsonl") unprocessed, $(count_lines "${SLACK_DIR}/processed.jsonl") processed, $(count_lines "${SLACK_DIR}/posted.jsonl") posted"

if [ -f "${SLACK_DIR}/last-watch" ]; then
	echo "  last watch: $(cat "${SLACK_DIR}/last-watch")"
else
	echo "  last watch: never ran"
fi

[ "${CONFIGURED}" = "true" ]
