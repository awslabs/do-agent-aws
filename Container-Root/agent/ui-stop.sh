#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Harness UIs - stop the running web UIs.
#
# Stops every UI that ui-start.sh started, by pidfile. A pid is only signaled when its
# command line matches the UI it claims to be (pidfiles survive container recreation on
# the /wd volume while pids are namespace-local, so a stale pidfile can point at an
# unrelated recycled pid - that process must never be killed). Each UI was started as its
# own session leader, so the whole tree is stopped by signaling the process group
# (vibe-kanban's npm wrapper spawns the actual server as a child). TERM first, then KILL
# after a grace period. Safe to run when nothing is up.

UI_DIR=${UI_DIR:-/wd/ui}

pid_is_ui()
{
	PID=$1
	MATCH=$2
	[ -n "${PID}" ] && [ -d "/proc/${PID}" ] && tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null | grep -q "${MATCH}"
}

stop_ui()
{
	NAME=$1
	MATCH=$2
	PID_FILE=${UI_DIR:?}/${NAME:?}.pid
	if [ ! -f "${PID_FILE}" ]; then
		echo "${NAME}: not running (no pidfile)"
		return 0
	fi
	PID=$(cat "${PID_FILE}")
	if ! pid_is_ui "${PID}" "${MATCH}"; then
		echo "${NAME}: not running (stale pidfile removed)"
		rm -f "${PID_FILE:?}"
		return 0
	fi
	# the pidfile goes first: it says the UI should run, and the supervisor starts the Loop Deck's server again while its
	# pidfile names a pid that is gone, which a stop in progress would otherwise look like
	rm -f "${PID_FILE:?}"
	kill -TERM -- "-${PID}" 2>/dev/null || kill -TERM "${PID}" 2>/dev/null
	for i in $(seq 1 10); do
		kill -0 "${PID}" 2>/dev/null || break
		sleep 1
	done
	if pid_is_ui "${PID}" "${MATCH}"; then
		kill -KILL -- "-${PID}" 2>/dev/null || kill -KILL "${PID}" 2>/dev/null
	fi
	echo "${NAME}: stopped (pid ${PID})"
}

# home (nginx) first so no half-proxied window while the UIs behind it go down
stop_ui home-watch    home-route-watch.sh
stop_ui home          nginx
stop_ui plane-signin  plane-signin.py
stop_ui board         board-server.py
stop_ui files         files-server.py
stop_ui tmux-agent    tmux-agent.js
stop_ui agent-chat    agent-chat.py
stop_ui tmux          ttyd
stop_ui claude-mem    worker-service.cjs
stop_ui loglearner    "loglearner/dashboard/app.py\|loglearner-serve.sh"
stop_ui loop-view     loop-view.py
stop_ui loop-deck     deck-server.py
stop_ui knowledge     knowledge-transfer.py
stop_ui headlamp      headlamp-server
stop_ui hindsight-api hindsight-api
stop_ui hindsight-ui  next-server
stop_ui vibe-kanban   vibe-kanban
stop_ui kanban-signin kanban-signin.py
