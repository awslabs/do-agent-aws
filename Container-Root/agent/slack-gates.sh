#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# credentials loaded from AWS Secrets Manager at the start, for a run through `docker exec` (/agent/secrets-env.sh)
if [ -r "${AGENT_DIR:-/agent}/secrets-env.sh" ]; then . "${AGENT_DIR:-/agent}/secrets-env.sh"; fi

# Slack gates - the one place that decides whether the autonomy loop autostarts, whether a loop
# cycle watches Slack, whether /agent/slack-post.sh may post, and whether the Slack chat responder
# /agent/slack-chat.sh runs.
#
# A bot token and a channel list are enough: with SLACK_BOT_TOKEN and SLACK_CHANNELS set and the
# four gate variables at their .env default (auto) or unset, the container starts the loop and the
# chat responder, the responder watches the channels and answers, and a fire may reply. An explicit
# false on a gate turns that part off; an explicit true forces it on (today's meaning - e.g. a loop
# with no Slack at all).
#
# Per gate variable - AUTONOMY_LOOP, SLACK_WATCH_ENABLED, SLACK_POST_ENABLED, SLACK_CHAT_ENABLED:
#   true           on
#   false          off
#   auto or unset  on exactly when Slack is configured: SLACK_BOT_TOKEN and SLACK_CHANNELS both
#                  non-empty
#   anything else  off, with a one-line WARNING on stderr naming the variable and the value
#
# Sourced (`. /agent/slack-gates.sh`) by loop.sh, loop-once.sh, slack-post.sh, slack-status.sh,
# slack-chat.sh, slack-chat-start.sh and slack-chat-status.sh. It sets SLACK_CONFIGURED
# (true|false); LOOP_AUTOSTART_EFFECTIVE, SLACK_WATCH_EFFECTIVE, SLACK_POST_EFFECTIVE and
# SLACK_CHAT_EFFECTIVE (on|off) with LOOP_AUTOSTART_REASON, SLACK_WATCH_REASON, SLACK_POST_REASON
# and SLACK_CHAT_REASON (one phrase each); and defines slack_gates_report, which prints the four
# lines below. Run as a command - startup.sh (plain sh) and /test4.sh query it this way:
#   /agent/slack-gates.sh                  the four effective values with their reasons, e.g.
#     loop autostart: AUTONOMY_LOOP=auto (effective: on - token and channels set)
#     watch gate: SLACK_WATCH_ENABLED=auto (effective: on - token and channels set)
#     post gate: SLACK_POST_ENABLED=auto (effective: on - token and channels set)
#     chat gate: SLACK_CHAT_ENABLED=auto (effective: on - token and channels set)
#   /agent/slack-gates.sh loop|watch|post|chat  prints on or off for that gate; exit 0 when on, 1 when off
# While the chat gate is on, the chat responder owns the Slack inbox and the loop does not run the
# watch itself (see loop.sh); the watch gate then governs only a loop that runs with chat off.
# No Slack API call is made and the token value is never printed. The posting rules that remain
# (only channels in SLACK_CHANNELS, read-back verification) are slack-post.sh's and unchanged.

if [ -n "${SLACK_BOT_TOKEN:+set}" ] && [ -n "${SLACK_CHANNELS}" ]; then
	SLACK_CONFIGURED=true
	SLACK_MISSING=""
elif [ -z "${SLACK_BOT_TOKEN:+set}" ] && [ -z "${SLACK_CHANNELS}" ]; then
	SLACK_CONFIGURED=false
	SLACK_MISSING="SLACK_BOT_TOKEN and SLACK_CHANNELS"
elif [ -z "${SLACK_BOT_TOKEN:+set}" ]; then
	SLACK_CONFIGURED=false
	SLACK_MISSING="SLACK_BOT_TOKEN"
else
	SLACK_CONFIGURED=false
	SLACK_MISSING="SLACK_CHANNELS"
fi

slack_gate()
{
	# slack_gate <variable name> <value> - sets GATE_EFFECTIVE (on|off) and GATE_REASON
	case "$2" in
	true)
		GATE_EFFECTIVE=on
		GATE_REASON="$1=true"
		;;
	false)
		GATE_EFFECTIVE=off
		GATE_REASON="$1=false"
		;;
	auto|"")
		if [ "${SLACK_CONFIGURED}" = "true" ]; then
			GATE_EFFECTIVE=on
			GATE_REASON="token and channels set"
		else
			GATE_EFFECTIVE=off
			GATE_REASON="${SLACK_MISSING} not set"
		fi
		;;
	*)
		echo "WARNING: $1='$2' is not true, false or auto - treated as false (see /agent/slack-gates.sh)" >&2
		GATE_EFFECTIVE=off
		GATE_REASON="$1='$2' is not true, false or auto"
		;;
	esac
}

slack_gate AUTONOMY_LOOP "${AUTONOMY_LOOP}"
LOOP_AUTOSTART_EFFECTIVE=${GATE_EFFECTIVE}
LOOP_AUTOSTART_REASON=${GATE_REASON}

slack_gate SLACK_WATCH_ENABLED "${SLACK_WATCH_ENABLED}"
SLACK_WATCH_EFFECTIVE=${GATE_EFFECTIVE}
SLACK_WATCH_REASON=${GATE_REASON}

slack_gate SLACK_POST_ENABLED "${SLACK_POST_ENABLED}"
SLACK_POST_EFFECTIVE=${GATE_EFFECTIVE}
SLACK_POST_REASON=${GATE_REASON}

slack_gate SLACK_CHAT_ENABLED "${SLACK_CHAT_ENABLED}"
SLACK_CHAT_EFFECTIVE=${GATE_EFFECTIVE}
SLACK_CHAT_REASON=${GATE_REASON}

slack_gates_report()
{
	echo "loop autostart: AUTONOMY_LOOP=${AUTONOMY_LOOP:-unset} (effective: ${LOOP_AUTOSTART_EFFECTIVE} - ${LOOP_AUTOSTART_REASON})"
	echo "watch gate: SLACK_WATCH_ENABLED=${SLACK_WATCH_ENABLED:-unset} (effective: ${SLACK_WATCH_EFFECTIVE} - ${SLACK_WATCH_REASON})"
	echo "post gate: SLACK_POST_ENABLED=${SLACK_POST_ENABLED:-unset} (effective: ${SLACK_POST_EFFECTIVE} - ${SLACK_POST_REASON})"
	echo "chat gate: SLACK_CHAT_ENABLED=${SLACK_CHAT_ENABLED:-unset} (effective: ${SLACK_CHAT_EFFECTIVE} - ${SLACK_CHAT_REASON})"
}

# Run as a command (not sourced): report, or answer for one gate
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "$1" in
	"")
		slack_gates_report
		;;
	loop)
		echo "${LOOP_AUTOSTART_EFFECTIVE}"
		[ "${LOOP_AUTOSTART_EFFECTIVE}" = "on" ]
		exit $?
		;;
	watch)
		echo "${SLACK_WATCH_EFFECTIVE}"
		[ "${SLACK_WATCH_EFFECTIVE}" = "on" ]
		exit $?
		;;
	post)
		echo "${SLACK_POST_EFFECTIVE}"
		[ "${SLACK_POST_EFFECTIVE}" = "on" ]
		exit $?
		;;
	chat)
		echo "${SLACK_CHAT_EFFECTIVE}"
		[ "${SLACK_CHAT_EFFECTIVE}" = "on" ]
		exit $?
		;;
	*)
		echo "usage: $0 [loop|watch|post|chat]" >&2
		exit 2
		;;
	esac
fi
