#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Comms real-channel watcher - start the communication engine's own reference scheduler
# (scripts/scheduler.py) detached, so the channels configured in ${COMMS_SETTINGS} are
# actually POLLED into the journal the dashboard renders.
#
# Why this exists: the comms UI is a viewer by construction (docs/comms/README.md) - the
# only scheduler invocation in this container was the one-time demo seed at first start.
# Without a running scheduler a perfectly configured real channel is never polled and the
# dashboard stays empty forever. This script is that missing poller.
#
# On by default: COMMS_WATCH_ENABLED=true in .env (docs/comms/README.md "Connect a real
# channel"), and startup.sh then calls this script at container start; set it false to run
# no watcher. With the generated demo settings the only instance is the credential-free fake
# adapter, so the watcher makes no network call. It keys off
# COMMS_WATCH_ENABLED alone, independent of the UI_START master switch, because a watcher
# is not a UI: it polls channels into the journal whether or not anyone is viewing, serves
# no port, and renders nothing - the UI gates control what is SERVED, this gate controls
# what is COLLECTED. It can also be run manually inside the container at any time.
#
# Read-only stays read-only: scheduler.py never imports the engine's send layer - by
# construction, enforced by the engine's own AST test (tests/test_schedule.py) - so no bug
# in the watcher can post as anyone. The engine's single-instance lock (state/scheduler.lock)
# is authoritative: a second scheduler on the same state directory refuses with exit 3
# instead of racing, so a second start here is a no-op reported honestly.
#
# State: pidfile ${COMMS_DIR}/watch.pid, log ${COMMS_DIR}/watch.log - on the /wd volume,
# same as the UI's ui.pid/ui.log, so they survive container replacement.

export HOME=${HOME:-/home/agent}
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

COMMS_HOME=${COMMS_HOME:-/opt/comms}
COMMS_DIR=${COMMS_DIR:-/wd/comms}
COMMS_SETTINGS=${COMMS_SETTINGS:-${COMMS_DIR}/settings.json}

if [ ! -f "${COMMS_HOME}/scripts/scheduler.py" ]; then
	echo "comms-watch: engine not installed under ${COMMS_HOME} (run setup/install-comms.sh)"
	exit 1
fi

if [ ! -f "${COMMS_SETTINGS}" ]; then
	echo "comms-watch: no ${COMMS_SETTINGS} yet - the comms UI generates it on first start"
	echo "(demo mode), and real channels are added per docs/comms/README.md \"Connect a real"
	echo "channel\"; start the UI once or write settings.json first, then start the watcher"
	exit 1
fi

mkdir -p "${COMMS_DIR}"

# A pid is trusted only when its command line matches the watcher it claims to be
# (same reasoning as comms-ui-start.sh: pidfiles survive container recreation, pids do not)
pid_is_watch()
{
	PID=$1
	[ -n "${PID}" ] && [ -d "/proc/${PID}" ] && tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null | grep -q "scripts/scheduler.py"
}

PID_FILE=${COMMS_DIR:?}/watch.pid
if [ -f "${PID_FILE}" ]; then
	if pid_is_watch "$(cat ${PID_FILE})"; then
		echo "comms-watch: already running (pid $(cat ${PID_FILE}))"
		exit 0
	fi
	rm -f "${PID_FILE:?}"
fi

# The & must apply to the setsid command alone so $! is the daemon itself (the
# comms-ui-start.sh pattern); setsid detaches it for comms-watch-stop.sh
(
	cd "${COMMS_HOME}" || exit 1
	setsid nohup python3 "${COMMS_HOME}/scripts/scheduler.py" \
		--config "${COMMS_SETTINGS}" >> "${COMMS_DIR}/watch.log" 2>&1 &
	echo $! > "${PID_FILE}"
)

# The scheduler validates the config and takes its single-instance lock immediately; an
# exit inside ~1s is one of its two loud refusals (exit 2 config refused, exit 3 lock held
# by another scheduler on this state directory) - report that honestly instead of "started"
sleep 1
PID=$(cat "${PID_FILE}")
if pid_is_watch "${PID}"; then
	echo "comms-watch: started (pid ${PID}, log ${COMMS_DIR}/watch.log)"
	echo "comms-watch: see polling with /agent/comms-watch-status.sh; rows appear in the dashboard as channels are polled"
else
	rm -f "${PID_FILE:?}"
	echo "comms-watch: did not start - last log lines:"
	tail -5 "${COMMS_DIR}/watch.log"
	exit 1
fi
