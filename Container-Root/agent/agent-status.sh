#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Agent status on one screen - what the autonomy loop and the Slack chat responder are doing, read
# from their state files only: the loop.state line, the last loop.log lines, completed fires, the
# last progress notes, whether a goals file exists and how many of its items are open, the chat
# responder's state, and the Slack inbox counters. No claude call and no Slack API call, so it is
# safe to run any time: docker exec do-agent-aws /agent/agent-status.sh
#
# The chat responder /agent/slack-chat.sh posts this output as the answer to "status" (no model
# call) and includes it in the prompt of every free-form question. Always exits 0 - a report, not
# a check (/agent/loop-status.sh and /agent/slack-chat-status.sh carry exit codes).
#
# Settings (from .env / environment): AUTONOMY_LOOP_DIR (default /wd/loop), AUTONOMY_LOOP_GOALS
# (default /wd/goals/GOALS.md), SLACK_DIR (default /wd/slack).

AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}
AUTONOMY_LOOP_GOALS=${AUTONOMY_LOOP_GOALS:-/wd/goals/GOALS.md}
SLACK_DIR=${SLACK_DIR:-/wd/slack}

LOOP_LOG=${AUTONOMY_LOOP_DIR}/loop.log
LOOP_STATE=${AUTONOMY_LOOP_DIR}/loop.state
STOP_FLAG=${AUTONOMY_LOOP_DIR}/STOP
NOTES=${AUTONOMY_LOOP_DIR}/notes.md
CHAT_STATE=${SLACK_DIR}/chat.state

count_lines()
{
	C=$(grep -c . "$1" 2>/dev/null)
	echo "${C:-0}"
}

count_matches()
{
	# count_matches <regex> <file>
	C=$(grep -c -E -- "$1" "$2" 2>/dev/null)
	echo "${C:-0}"
}

echo "Agent status at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

STATE_LINE=$(cat "${LOOP_STATE}" 2>/dev/null)
echo "loop: ${STATE_LINE:-no state recorded (the loop has not run yet; /agent/loop-status.sh has the details)}"
if [ -f "${STOP_FLAG}" ]; then
	echo "loop stop flag: present (${STOP_FLAG}) - the loop halts before its next fire; /agent/loop-start.sh removes it"
fi

FIRES=$(count_matches " END rc=" "${LOOP_LOG}")
LAST_OUTCOME=$(grep " END rc=" "${LOOP_LOG}" 2>/dev/null | tail -1)
echo "fires: ${FIRES} completed; last outcome: ${LAST_OUTCOME:-none}"
case "${LAST_OUTCOME}" in
	*"outcome=no-credentials"*|*"outcome=invalid-credentials"*|*"outcome=no-access"*)
		echo "  the last fire did NO work: claude could not use AWS credentials or the Bedrock model - docs/manual/aws.md 'AWS credentials', 'Bedrock connectivity'" ;;
	*"outcome=api-error"*)
		echo "  the last fire did NO work: claude reported an API error (the END line above carries it) - docs/manual/aws.md 'Bedrock connectivity'" ;;
	*"outcome=timeout"*)
		echo "  the last fire timed out with no output: credentials that never answer look like this (an IMDS endpoint that does not respond, static keys that fail silently) - docs/manual/aws.md 'AWS credentials'" ;;
	*"outcome=config"*)
		echo "  the last fire did NO work: AUTONOMY_LOOP_CLAUDE_OPTS holds a word that cannot be a rule (the END line names it; the fire's transcript explains) - fix the value in .env.local and recreate the container, docs/manual/autonomy.md 'Autonomy loop'" ;;
esac
case "${LAST_OUTCOME}" in
	*" ignored-rule \""*)
		echo "  claude ignored an allow rule of the last fire's options (the END line names the word): the fire ran without it and denied every call it would have allowed - docs/manual/autonomy.md 'Autonomy loop'" ;;
esac

echo "loop log (last 3 lines of ${LOOP_LOG}):"
if [ -s "${LOOP_LOG}" ]; then
	tail -3 "${LOOP_LOG}" | sed 's/^/  /'
else
	echo "  none"
fi

echo "notes (last 5 lines of ${NOTES}):"
if [ -s "${NOTES}" ]; then
	tail -5 "${NOTES}" | sed 's/^/  /'
else
	echo "  none yet"
fi

if [ -f "${AUTONOMY_LOOP_GOALS}" ]; then
	HEADINGS=$(count_matches "^## " "${AUTONOMY_LOOP_GOALS}")
	OPEN=$(count_matches "^[[:space:]]*[-*] \[ \]" "${AUTONOMY_LOOP_GOALS}")
	DONE=$(count_matches "^[[:space:]]*[-*] \[[xX]\]" "${AUTONOMY_LOOP_GOALS}")
	echo "goals: ${AUTONOMY_LOOP_GOALS} present - ${HEADINGS} heading(s), ${OPEN} unchecked item(s), ${DONE} checked"
else
	echo "goals: no goals file yet at ${AUTONOMY_LOOP_GOALS} - a goal stated in chat creates it (/agent/goals-add.sh)"
fi

CHAT_LINE=$(cat "${CHAT_STATE}" 2>/dev/null)
echo "chat: ${CHAT_LINE:-not started (no ${CHAT_STATE}; /agent/slack-chat-status.sh has the details)}"

echo "slack inbox: $(count_lines "${SLACK_DIR}/inbox.jsonl") unprocessed, $(count_lines "${SLACK_DIR}/processed.jsonl") processed, $(count_lines "${SLACK_DIR}/posted.jsonl") posted"

exit 0
