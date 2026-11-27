#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Add one goal, stated in Slack chat, to the autonomy loop's goals file; set a goal's priority; unpark a goal.
#
# Usage: /agent/goals-add.sh [--priority high|low] "<one-line goal>" ["<channel> <ts>"]
#        /agent/goals-add.sh --set-priority G<n>|L<line> high|low|normal
#        /agent/goals-add.sh --unpark G<n>|L<line>
#
# This is the one way a Slack conversation reaches the loop: the chat responder
# /agent/slack-chat.sh (its claude call is allowed to run exactly this script and
# /agent/slack-post.sh) records a goal the user stated, and the loop fires on the goals file from
# its next cycle. The add path only ever APPENDS to the goals file - the loop's fires may edit the
# same file (checking items off), and an append is the one write that cannot undo theirs:
#   - when ${AUTONOMY_LOOP_GOALS} is missing it is created (mkdir -p its directory) with the
#     structure of docs/loop/GOALS.md.example - a title, how the loop consumes the file and how an
#     item is marked done, then the heading "## Goals from Slack" as the LAST section;
#   - the goal is appended under that heading as "- [ ] <goal> (from Slack <channel> <ts>)" - the ts the responder
#     passes is the thread root of the message that stated the goal (its own ts when it was top-level), so a later
#     post about the goal can go in the topic's thread (SLACK_REPLY_IN_THREAD, the fire prompt's goal-thread rule);
#   - a user-written goals file without the heading gets it appended at the end first; only a
#     file where the heading exists but is not the last section is rewritten in place (awk, then
#     mv) to keep the list under its heading.
# On success the path of the goals file is printed; when the loop's stop flag exists a second
# line says so (the loop halts on it - /agent/loop-start.sh starts the loop again). This script
# never creates or removes the stop flag.
#
# Supervisor mode (G99, /wd/loop/supervisor/DESIGN.md sections 3 and 8). A goal's priority is a leading parenthesised
# note on its line, "- [ ] (priority: high) <goal> ..."; the board mirrors key a card by the text without its leading
# notes, so the marker changes no card. Order = priority (high, none, low), then file order.
#   --priority high|low      writes the marker into the NEW goal's line. The chat responder passes it when the person
#                            says "high priority", "first", "urgent", "ASAP", "top priority" (high) or "can wait",
#                            "low priority" (low). high also touches the loop's WAKE flag ${AUTONOMY_LOOP_DIR}/WAKE, so
#                            a sleeping loop starts its next cycle within seconds ("Run next fire"); a STOPPED loop is
#                            restarted by goal-watch.sh as before. normal is accepted and writes no marker.
#   --set-priority <id> <l>  changes the marker of ONE existing goal in place - the only in-place edit this script ever
#                            makes, done by supervisor-plan.py --set-priority under the goals lock
#                            ${AUTONOMY_LOOP_GOALS}.lock with a re-read before and a read-back after the write; normal
#                            removes the marker; high touches WAKE as above. G<n> is board.sh's numbering (the n-th
#                            goal item in file order, done ones included), L<line> is the file line.
#   --unpark <id>            the operator's "retry G<n>": removes the goal's hash from ${AUTONOMY_LOOP_DIR}/supervisor/
#                            parked and its strikes from .../supervisor/strikes.tsv under the strikes lock, so the
#                            supervisor loop dispatches it again. It never touches the goals file.
#
# Exit codes: the add path 0 ok / 1 usage or the goal did not land (as before); --set-priority and --unpark return the
# planner's codes - 0 ok (also "unchanged" / "nothing was parked"), 2 usage, 3 planner missing or goals unreadable,
# 4 no such goal or a `## Goal` heading, 5 lock busy (try again), 6 the line changed under us (nothing written).
#
# Settings (from .env / environment): AUTONOMY_LOOP_GOALS (default /wd/goals/GOALS.md),
# AUTONOMY_LOOP_DIR (default /wd/loop; names the notes file and the stop flag in the text, the WAKE flag and the
# supervisor directory), SUPERVISOR_PLAN (the planner, default supervisor-plan.py beside this script).

AUTONOMY_LOOP_GOALS=${AUTONOMY_LOOP_GOALS:-/wd/goals/GOALS.md}
AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}
AGENT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLANNER=${SUPERVISOR_PLAN:-${AGENT_DIR}/supervisor-plan.py}
WAKE_FLAG=${AUTONOMY_LOOP_DIR}/WAKE

HEADING="## Goals from Slack"

err()
{
	echo "ERROR: $*" >&2
}

usage()
{
	cat << EOT
usage: $0 [--priority high|low] "<one-line goal>" ["<channel> <ts>"]
   or: $0 [--priority high|low] -- "<a goal that starts with ->" ["<channel> <ts>"]
   or: $0 --set-priority G<n>|L<line> high|low|normal
   or: $0 --unpark G<n>|L<line>
Adds the goal as one checkbox item, "- [ ] <goal>", under "${HEADING}" in ${AUTONOMY_LOOP_GOALS} - the form the
autonomy loop fires on and the Goals board mirrors - and prints the file's path. The second argument records where
the goal was stated (the Slack responder passes the channel and the ts of the message's thread root - the message's own
ts when it was top-level - so a later post about the goal lands in the topic's thread).
--priority high|low writes the marker "(priority: high)" before the goal text (high also touches the loop's WAKE flag,
so the next cycle starts at once). --set-priority changes the marker of one existing goal in place (G<n> = board.sh's
numbering, L<line> = the file line; normal removes it). --unpark clears a parked goal's strikes so the supervisor loop
retries it ("retry G<n>"). -h, --help: this text.
EOT
}

wake()
{
	if touch "${WAKE_FLAG}" 2> /dev/null; then
		echo "note: priority high - ${WAKE_FLAG} touched, a sleeping loop starts its next cycle now"
	else
		echo "note: priority high, but ${WAKE_FLAG} could not be touched (is ${AUTONOMY_LOOP_DIR} there?)" >&2
	fi
}

valid_level()
{
	case "$1" in
		high|low|normal) return 0 ;;
		*) return 1 ;;
	esac
}

valid_target()
{
	case "$1" in
		G[0-9]*|L[0-9]*) return 0 ;;
		*) return 1 ;;
	esac
}

PRIORITY=""
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--priority)
			[ $# -ge 2 ] || { err "--priority needs a level: high or low"; exit 1; }
			valid_level "$2" || { err "not a priority level: $2 (high, low or normal)"; exit 1; }
			PRIORITY=$2; shift 2 ;;
		--priority=*)
			PRIORITY=${1#--priority=}
			valid_level "${PRIORITY}" || { err "not a priority level: ${PRIORITY} (high, low or normal)"; exit 1; }
			shift ;;
		--set-priority)
			[ $# -eq 3 ] || { err "usage: $0 --set-priority G<n>|L<line> high|low|normal"; exit 2; }
			valid_target "$2" || { err "not a goal id: $2 (G<n> = board.sh numbering, or L<line>)"; exit 2; }
			valid_level "$3" || { err "not a priority level: $3 (high, low or normal)"; exit 2; }
			[ -f "${PLANNER}" ] || { err "planner not found: ${PLANNER}"; exit 3; }
			python3 -I "${PLANNER}" --goals "${AUTONOMY_LOOP_GOALS}" --set-priority "$2" "$3"
			RC=$?
			if [ "${RC}" -eq 0 ] && [ "$3" = high ]; then
				wake
			fi
			exit "${RC}" ;;
		--unpark)
			[ $# -eq 2 ] || { err "usage: $0 --unpark G<n>|L<line>"; exit 2; }
			valid_target "$2" || { err "not a goal id: $2 (G<n> = board.sh numbering, or L<line>)"; exit 2; }
			[ -f "${PLANNER}" ] || { err "planner not found: ${PLANNER}"; exit 3; }
			exec python3 -I "${PLANNER}" --goals "${AUTONOMY_LOOP_GOALS}" --unpark "$2" --supervisor-dir "${AUTONOMY_LOOP_DIR}/supervisor" ;;
		--) shift; break ;;
		# an option-shaped first argument is never a goal: --help once became the goal "--help", a card on two boards
		-*) err "a goal does not start with '-' ($1): for a goal that does, write $0 -- \"$1\"; $0 --help prints the usage"; exit 1 ;;
		*) break ;;
	esac
done

# One line: newlines and tabs become spaces, surrounding whitespace is dropped
GOAL=$(printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
SOURCE=$(printf '%s' "$2" | tr '\n\r\t' '   ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [ -z "${GOAL}" ]; then
	err "usage: $0 [--priority high|low] \"<one-line goal>\" [\"<channel> <ts>\"]"
	exit 1
fi

MARK=""
case "${PRIORITY}" in
	high|low) MARK="(priority: ${PRIORITY}) " ;;
esac
if [ -n "${SOURCE}" ]; then
	ENTRY="- [ ] ${MARK}${GOAL} (from Slack ${SOURCE})"
else
	ENTRY="- [ ] ${MARK}${GOAL}"
fi

mkdir -p "$(dirname "${AUTONOMY_LOOP_GOALS}")" || { err "cannot create $(dirname "${AUTONOMY_LOOP_GOALS}")"; exit 1; }

if [ ! -f "${AUTONOMY_LOOP_GOALS}" ]; then
	cat > "${AUTONOMY_LOOP_GOALS}" << EOT
# Goals for the autonomy loop

Goals stated in Slack chat are collected here by /agent/goals-add.sh, and the autonomy loop fires
on this file (docs/manual/autonomy.md "Autonomy loop"). Each fire reads the goals plus the progress notes
${AUTONOMY_LOOP_DIR}/notes.md, completes the single smallest unfinished increment, appends a
one-line progress note, and stops. Mark an item done by changing its \`- [ ]\` to \`- [x]\` and
leave the line in place. A goal is an outcome with a DONE condition that can be checked - a file
or command result that is missing if the work was not done - not an activity.

When every item below is checked, create the stop flag ${AUTONOMY_LOOP_DIR}/STOP and end; the
loop halts, and /agent/loop-start.sh starts it again when new goals arrive through chat.

${HEADING}

EOT
	[ -f "${AUTONOMY_LOOP_GOALS}" ] || { err "cannot create ${AUTONOMY_LOOP_GOALS}"; exit 1; }
fi

if ! grep -qxF -- "${HEADING}" "${AUTONOMY_LOOP_GOALS}"; then
	# A user-written file without the heading: the section is appended at the end
	[ -n "$(tail -c1 "${AUTONOMY_LOOP_GOALS}")" ] && echo >> "${AUTONOMY_LOOP_GOALS}"
	printf '\n%s\n\n' "${HEADING}" >> "${AUTONOMY_LOOP_GOALS}"
fi

HEADING_LINE=$(grep -nxF -- "${HEADING}" "${AUTONOMY_LOOP_GOALS}" | head -1 | cut -d: -f1)
NEXT_HEADING=$(awk -v h="${HEADING_LINE}" 'NR > h && /^## / { print NR; exit }' "${AUTONOMY_LOOP_GOALS}")

if [ -z "${NEXT_HEADING}" ]; then
	# The heading is the last section: a plain append keeps the list under it
	[ -n "$(tail -c1 "${AUTONOMY_LOOP_GOALS}")" ] && echo >> "${AUTONOMY_LOOP_GOALS}"
	printf '%s\n' "${ENTRY}" >> "${AUTONOMY_LOOP_GOALS}"
else
	# Another section follows: insert after the last non-blank line of the Slack section
	INSERT_AFTER=$(awk -v h="${HEADING_LINE}" -v n="${NEXT_HEADING}" 'NR > h && NR < n && NF { last = NR } END { print (last ? last : h) }' "${AUTONOMY_LOOP_GOALS}")
	TMP=$(mktemp "${AUTONOMY_LOOP_GOALS}.XXXXXX") || { err "cannot create a temp file beside ${AUTONOMY_LOOP_GOALS}"; exit 1; }
	ENTRY="${ENTRY}" awk -v l="${INSERT_AFTER}" '{ print } NR == l { print ENVIRON["ENTRY"] }' "${AUTONOMY_LOOP_GOALS}" > "${TMP}" \
		&& mv "${TMP:?}" "${AUTONOMY_LOOP_GOALS:?}" || { rm -f "${TMP:?}"; err "could not insert the goal into ${AUTONOMY_LOOP_GOALS}"; exit 1; }
fi

grep -qxF -- "${ENTRY}" "${AUTONOMY_LOOP_GOALS}" || { err "the goal line did not land in ${AUTONOMY_LOOP_GOALS}"; exit 1; }

echo "${AUTONOMY_LOOP_GOALS}"
if [ "${PRIORITY}" = high ]; then
	wake
fi
if [ -f "${AUTONOMY_LOOP_DIR}/STOP" ]; then
	echo "note: the loop stop flag ${AUTONOMY_LOOP_DIR}/STOP is present - the loop halts on it; /agent/loop-start.sh removes the flag and starts the loop"
fi
