#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Goal watcher - starts the stopped autonomy loop when a new unchecked goal appears.
#
# The loop (/agent/loop.sh) exits when it finds ${AUTONOMY_LOOP_DIR}/STOP, which a fire creates when every goal is
# complete. A goal added afterwards - through chat (goals-add.sh), /agent/board.sh create --goal, or a manual edit of
# the goals file - would otherwise wait until someone runs /agent/loop-start.sh by hand. This watcher checks the goals
# file every GOAL_WATCH_INTERVAL seconds (default 120) and, when an unchecked goal appears that it has not seen
# before and the loop is stopped (STOP present, or no loop holds loop.lock), runs /agent/loop-start.sh, which removes
# STOP and starts the loop.
#
# - An unchecked goal is a line "- [ ] ..." (leading spaces allowed) or a heading "## ... [ ] ..."; the instruction
#   text that merely mentions `- [ ]` inside a sentence does not count.
# - The first check only records the goals already open: a loop someone stopped on purpose with goals still open is
#   not restarted for those; only a goal that was not there before starts it.
# - A goal counts as seen once a start succeeded (or the loop was already running without STOP); if the start fails
#   or the loop is still winding down, the goal stays new and the next check tries again.
# - Single instance: flock on ${AUTONOMY_LOOP_DIR}/goal-watch.lock. Log: ${AUTONOMY_LOOP_DIR}/goal-watch.log.
# - GOAL_WATCH_ONCE=true runs one check and exits (tests, cron).

AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}
AUTONOMY_LOOP_GOALS=${AUTONOMY_LOOP_GOALS:-/wd/goals/GOALS.md}
GOAL_WATCH_INTERVAL=${GOAL_WATCH_INTERVAL:-120}
GOAL_WATCH_ONCE=${GOAL_WATCH_ONCE:-false}
LOOP_START_BIN=${LOOP_START_BIN:-$(dirname "$0")/loop-start.sh}

STOP_FLAG=${AUTONOMY_LOOP_DIR}/STOP
LOOP_LOCK=${AUTONOMY_LOOP_DIR}/loop.lock
SEEN_FILE=${AUTONOMY_LOOP_DIR}/goal-watch.seen
LOG_FILE=${AUTONOMY_LOOP_DIR}/goal-watch.log
WATCH_LOCK=${AUTONOMY_LOOP_DIR}/goal-watch.lock

mkdir -p "${AUTONOMY_LOOP_DIR}"

log()
{
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "${LOG_FILE}"
}

# One sha256 per open goal line, sorted and unique.
open_goals()
{
	[ -f "${AUTONOMY_LOOP_GOALS}" ] || return 0
	command grep -E -- '^[[:space:]]*- \[ \]|^#+ .*\[ \]' "${AUTONOMY_LOOP_GOALS}" | while IFS= read -r line; do
		printf '%s' "${line}" | sha256sum | cut -d' ' -f1
	done | sort -u
}

loop_stopped()
{
	[ -f "${STOP_FLAG}" ] && return 0
	# No running loop holds the lock: probe it on a private fd and release at once.
	( flock -n 8 ) 8> "${LOOP_LOCK}" 2>/dev/null
}

check()
{
	local current new
	current=$(open_goals)
	if [ ! -f "${SEEN_FILE}" ]; then
		printf '%s\n' "${current}" | sed '/^$/d' > "${SEEN_FILE}"
		log "SEED $(printf '%s\n' "${current}" | sed '/^$/d' | wc -l) open goal(s) recorded; none trigger a start"
		return 0
	fi
	new=$(comm -23 <(printf '%s\n' "${current}" | sed '/^$/d') <(sort -u "${SEEN_FILE}"))
	if [ -z "${new}" ]; then
		# Keep the seen set to what is open now, so a goal re-opened later counts as new.
		printf '%s\n' "${current}" | sed '/^$/d' > "${SEEN_FILE}"
		return 0
	fi
	local n
	n=$(printf '%s\n' "${new}" | wc -l)
	if ! loop_stopped; then
		log "NEW ${n} goal(s); loop running, nothing to start"
		printf '%s\n' "${current}" | sed '/^$/d' > "${SEEN_FILE}"
		return 0
	fi
	log "NEW ${n} goal(s) while the loop is stopped: running ${LOOP_START_BIN}"
	local out rc
	out=$("${LOOP_START_BIN}" 2>&1)
	rc=$?
	log "START rc=${rc}: $(printf '%s' "${out}" | tr '\n' ' ')"
	if [ "${rc}" -eq 0 ] && [ ! -f "${STOP_FLAG}" ]; then
		printf '%s\n' "${current}" | sed '/^$/d' > "${SEEN_FILE}"
	else
		log "START not confirmed (rc=${rc}, STOP $([ -f "${STOP_FLAG}" ] && echo present || echo absent)); retry next check"
	fi
}

exec 9> "${WATCH_LOCK}"
if ! flock -n 9; then
	echo "Goal watcher already running (lock ${WATCH_LOCK})"
	exit 0
fi

log "WATCH start goals=${AUTONOMY_LOOP_GOALS} interval=${GOAL_WATCH_INTERVAL}s once=${GOAL_WATCH_ONCE}"
while true; do
	check
	[ "${GOAL_WATCH_ONCE}" = "true" ] && exit 0
	sleep "${GOAL_WATCH_INTERVAL}"
done
