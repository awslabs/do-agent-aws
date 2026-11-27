#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# goals-mark.sh - a supervisor worker marks ONE of its own goals done (G99, DESIGN.md sections 7 and 11).
#
# Usage: /agent/goals-mark.sh G<n>|L<line> [--note "<text>"]
#
# Flips that goal's `- [ ]` to `- [x]` in ${AUTONOMY_LOOP_GOALS} (default /wd/goals/GOALS.md), writing the optional
# note before the goal text as a leading parenthesised note - the completion form the fires write by hand today, so
# the board mirrors' goal_key (strip_note) does not change and the goal keeps its cards. G<n> is board.sh's numbering
# (the n-th goal item in file order, done ones included); L<line> is the file line.
#
# The write is supervisor-plan.py --mark: under the goals lock ${AUTONOMY_LOOP_GOALS}.lock (non-blocking flock), a
# re-read that refuses when the line changed since it was read, an atomic replace of the whole file, and a read-back
# of the written line before success is reported. A worker may only mark a goal the loop handed it: the goal's hash
# (sha256 of its key, 12 hex, printed by the planner) must be one of the space-separated hashes in WORKER_GOAL_HASHES.
# With that variable empty or unset EVERY mark is refused, so a fire that is not a supervisor worker cannot use this
# script by accident (today's serial fire edits the goals file itself, as its prompt says).
#
# Exit codes: 0 marked (prints the old and the new line); 2 usage; 3 not yours (the hash is not in WORKER_GOAL_HASHES,
# or the variable is empty); 4 no such goal, a `## Goal` heading, or already done; 5 goals lock busy (try again);
# 6 the line changed under us, did not read back, or the note would change the goal key (nothing written);
# 7 goals file unreadable or planner missing.
# Nothing else is written: never the stop flag, never notes.md (notes-append.sh), never another goal's line.
#
# Settings (from .env / environment): AUTONOMY_LOOP_GOALS (default /wd/goals/GOALS.md); WORKER_GOAL_HASHES (set by
# the loop for each worker); SUPERVISOR_PLAN (the planner, default supervisor-plan.py beside this script).

AUTONOMY_LOOP_GOALS=${AUTONOMY_LOOP_GOALS:-/wd/goals/GOALS.md}
AGENT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLANNER=${SUPERVISOR_PLAN:-${AGENT_DIR}/supervisor-plan.py}

err()
{
	echo "ERROR: $*" >&2
}

usage()
{
	cat << EOT
usage: $0 G<n>|L<line> [--note "<text>"]
Marks that open goal done in ${AUTONOMY_LOOP_GOALS} (- [ ] -> - [x], the note as a leading parenthesised note), under
the goals lock, only when the goal's hash is in WORKER_GOAL_HASHES (the goals the loop handed this worker).
Exit: 0 marked, 2 usage, 3 not yours, 4 no such open goal, 5 lock busy, 6 changed under us / bad note, 7 unreadable.
EOT
}

TARGET=""
NOTE=""
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--note)
			[ $# -ge 2 ] || { err "--note needs a text"; usage >&2; exit 2; }
			NOTE=$2; shift 2 ;;
		--note=*) NOTE=${1#--note=}; shift ;;
		-*) err "unknown option $1"; usage >&2; exit 2 ;;
		*)
			[ -z "${TARGET}" ] || { err "one goal per call ($TARGET and $1 given)"; usage >&2; exit 2; }
			TARGET=$1; shift ;;
	esac
done

case "${TARGET}" in
	G[0-9]*|L[0-9]*) ;;
	"") err "which goal? G<n> (board.sh numbering) or L<line>"; usage >&2; exit 2 ;;
	*) err "not a goal id: ${TARGET} (G<n> or L<line>)"; usage >&2; exit 2 ;;
esac

[ -f "${PLANNER}" ] || { err "planner not found: ${PLANNER}"; exit 7; }
[ -r "${AUTONOMY_LOOP_GOALS}" ] || { err "goals file unreadable: ${AUTONOMY_LOOP_GOALS}"; exit 7; }

# WORKER_GOAL_HASHES is passed even when empty: an empty value makes the planner refuse every goal (rc 3).
if [ -n "${NOTE}" ]; then
	exec python3 -I "${PLANNER}" --goals "${AUTONOMY_LOOP_GOALS}" --mark "${TARGET}" --allowed-hashes "${WORKER_GOAL_HASHES:-}" --note "${NOTE}"
else
	exec python3 -I "${PLANNER}" --goals "${AUTONOMY_LOOP_GOALS}" --mark "${TARGET}" --allowed-hashes "${WORKER_GOAL_HASHES:-}"
fi
