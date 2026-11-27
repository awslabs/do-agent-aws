#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# credentials loaded from AWS Secrets Manager at the start, for a run through `docker exec` (/agent/secrets-env.sh)
if [ -r "${AGENT_DIR:-/agent}/secrets-env.sh" ]; then . "${AGENT_DIR:-/agent}/secrets-env.sh"; fi

# Start the autonomy loop (/agent/loop.sh) detached.
#
# Starting the loop is the explicit signal to run: a STOP flag left by a previous halt is
# removed here (loop.sh itself never removes the flag; if every goal is already complete the
# next fire simply re-creates it). If the loop is already running this script reports that
# honestly and exits 0 - loop.sh's single-instance lock makes a duplicate start harmless.
# A running loop that is not firing (sleeping between fires) is woken instead: the WAKE flag
# ends its sleep within ~5 s and it starts the next cycle ("Run next fire"). A fire in flight
# is left alone - loop.sh removes WAKE when a fire begins, so a click never queues a second fire.
# The detached process runs in its own session (setsid) so loop-stop.sh --now can terminate
# the loop and any in-flight fire as one exact process group. Detached stdout goes to
# ${AUTONOMY_LOOP_DIR}/loop.stdout; the loop's own log remains ${AUTONOMY_LOOP_DIR}/loop.log.
# A running loop gets its place in the tmux fleet - a tmux session for the loop and one per fire while it runs, the
# tree the tmux-agent dashboard draws - from /agent/loop-lineage.sh (a view of the loop: the loop itself still runs
# here, detached and unchanged; AUTONOMY_LOOP_TMUX_LINEAGE=false leaves it out). It runs with the lock's fd closed,
# never fails the start, and is called again on an "already running" start, so a session lost with a tmux server
# comes back.

export HOME=${HOME:-/home/agent}

AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}

LOOP_STATE=${AUTONOMY_LOOP_DIR}/loop.state
STOP_FLAG=${AUTONOMY_LOOP_DIR:?}/STOP
WAKE_FLAG=${AUTONOMY_LOOP_DIR}/WAKE
LOCK_FILE=${AUTONOMY_LOOP_DIR}/loop.lock
LOOP_LINEAGE_BIN=${LOOP_LINEAGE_BIN:-$(dirname "$0")/loop-lineage.sh}

lineage()
{
	[ -x "${LOOP_LINEAGE_BIN}" ] && timeout 20 "${LOOP_LINEAGE_BIN}" start "$1" 9>&-
	return 0
}

mkdir -p "${AUTONOMY_LOOP_DIR}"

# Already running? A live loop holds an exclusive flock on loop.lock for its lifetime.
exec 9> "${LOCK_FILE}"
if ! flock -n 9; then
	PID=$(grep -o 'pid=[0-9]*' "${LOOP_STATE}" 2>/dev/null | cut -d= -f2)
	PHASE=$(awk '{print $1; exit}' "${LOOP_STATE}" 2>/dev/null)
	if [ "${PHASE}" = "FIRING" ]; then
		FIRE=$(grep -o 'fire=[0-9]*' "${LOOP_STATE}" 2>/dev/null | cut -d= -f2)
		echo "Autonomy loop already running${PID:+ (pid ${PID})} and a fire is running${FIRE:+ (fire ${FIRE})}; the next fire starts when it ends."
	else
		touch "${WAKE_FLAG}"
		echo "Autonomy loop already running${PID:+ (pid ${PID})}, ${PHASE:-state unknown}; woke it: the next fire starts within ~5 s."
	fi
	[ -n "${PID}" ] && lineage "${PID}"
	exit 0
fi
exec 9>&-

if [ -f "${STOP_FLAG}" ]; then
	echo "Removing stop flag ${STOP_FLAG} (explicit start)"
	rm -f "${STOP_FLAG:?}"
fi

setsid nohup /agent/loop.sh >> "${AUTONOMY_LOOP_DIR}/loop.stdout" 2>&1 &
PID=$!

sleep 2
if kill -0 "${PID}" 2>/dev/null; then
	echo "Autonomy loop started pid=${PID} log=${AUTONOMY_LOOP_DIR}/loop.log state=${LOOP_STATE}"
	lineage "${PID}"
else
	echo "Autonomy loop exited immediately; last output:"
	tail -5 "${AUTONOMY_LOOP_DIR}/loop.stdout" 2>/dev/null
	exit 1
fi
