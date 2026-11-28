#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Comms UI - stop the communication-engine operator dashboard.
#
# Stops the dashboard that comms-ui-start.sh started, by pidfile. The pid is only signaled
# when its command line matches the dashboard it claims to be (pidfiles survive container
# recreation on the /wd volume while pids are namespace-local, so a stale pidfile can point
# at an unrelated recycled pid - that process must never be killed). The dashboard was
# started as its own session leader, so the whole tree is stopped by signaling the process
# group. TERM first, then KILL after a grace period. Safe to run when nothing is up.

COMMS_DIR=${COMMS_DIR:-/wd/comms}
PID_FILE=${COMMS_DIR:?}/ui.pid

pid_is_comms()
{
	PID=$1
	[ -n "${PID}" ] && [ -d "/proc/${PID}" ] && tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null | grep -q "scripts/dashboard.py"
}

if [ ! -f "${PID_FILE}" ]; then
	echo "comms-ui: not running (no pidfile)"
	exit 0
fi
PID=$(cat "${PID_FILE}")
if ! pid_is_comms "${PID}"; then
	echo "comms-ui: not running (stale pidfile removed)"
	rm -f "${PID_FILE:?}"
	exit 0
fi
kill -TERM -- "-${PID}" 2>/dev/null || kill -TERM "${PID}" 2>/dev/null
for i in $(seq 1 10); do
	kill -0 "${PID}" 2>/dev/null || break
	sleep 1
done
if pid_is_comms "${PID}"; then
	kill -KILL -- "-${PID}" 2>/dev/null || kill -KILL "${PID}" 2>/dev/null
fi
rm -f "${PID_FILE:?}"
echo "comms-ui: stopped (pid ${PID})"
