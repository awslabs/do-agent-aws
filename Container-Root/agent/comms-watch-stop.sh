#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Comms real-channel watcher - stop the detached scheduler started by
# /agent/comms-watch-start.sh. Kills by the exact pid from the pidfile, only after the
# pid's command line proves it is the watcher (a recycled pid after container recreation
# must never be killed on a stale pidfile), then removes the pidfile. The engine commits
# its cursor only after the journal write (core/schedule.py), so stopping mid-cycle never
# loses a message - the next start re-polls anything uncommitted.

COMMS_DIR=${COMMS_DIR:-/wd/comms}
PID_FILE=${COMMS_DIR:?}/watch.pid

pid_is_watch()
{
	PID=$1
	[ -n "${PID}" ] && [ -d "/proc/${PID}" ] && tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null | grep -q "scripts/scheduler.py"
}

if [ ! -f "${PID_FILE}" ]; then
	echo "comms-watch: not running (no pidfile ${PID_FILE})"
	exit 0
fi

PID=$(cat "${PID_FILE}")
if pid_is_watch "${PID}"; then
	kill "${PID}"
	# Give it a moment to release the single-instance lock cleanly
	for _ in 1 2 3 4 5; do
		[ -d "/proc/${PID}" ] || break
		sleep 1
	done
	if [ -d "/proc/${PID}" ]; then
		kill -9 "${PID}"
	fi
	echo "comms-watch: stopped (pid ${PID})"
else
	echo "comms-watch: stale pidfile (pid ${PID} is not the watcher); removing it"
fi
rm -f "${PID_FILE:?}"
