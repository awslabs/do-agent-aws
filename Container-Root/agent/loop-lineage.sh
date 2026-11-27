#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The autonomy loop's place in the tmux fleet: tmux sessions for the loop and its fires, for the tmux-agent dashboard.
#
# The loop runs detached in a session of its own (/agent/loop-start.sh: setsid, so /agent/loop-stop.sh --now ends the
# loop and a fire in flight as one process group), and a process outside tmux is invisible to the tmux-agent
# dashboard: its census lists tmux sessions and reads their lineage from the @agent_* user options. loop-start.sh runs
# `loop-lineage.sh start <loop pid>` after a start. That gives the loop a session on the default tmux server - the
# agent session's server, the one the dashboard watches - with @agent_parent operator, and the loop's own pane then
# opens one more session per fire while the fire runs (@agent_parent <the loop's session>). The dashboard's tree reads
# operator -> loop -> fire, and its history (its ledger) gets a session.spawned and a session.killed line per session,
# stamped with the times loop.log records, so ended fires stay in it.
#
# The sessions are a VIEW, never the work: a pane shows the loop's log, or a fire's elapsed time. The loop and its fires
# run exactly as before, outside tmux, so the exit code, the timeout, the claude options, the single-instance lock and
# loop-stop.sh --now's process-group kill are untouched (loop.sh is not changed at all). Nothing here holds the loop's
# lock: the panes are forked by the tmux server, never by the loop, and loop-start.sh runs `start` with the lock's fd
# closed. Each pane ends itself when what it shows has ended - a fire's session closes at the fire's END line, the
# loop's when the loop process exits (STOP flag, loop-stop.sh --now, a kill) - so nothing lingers; the loop's pane
# reads the log once more after the loop exits, so a last fire that set the STOP flag closes with its rc. The
# dashboard sees a pane's own process (a shell loop with no CPU), not claude: its activity readings for these sessions
# are the view's, and the Agent loop page (/agent/loop-view.py) has the fire's own.
#
# Never starts a tmux server: with none running (AGENT_TMUX_SESSION=false) there is no tree to join and `start` says
# so. A fire run by /agent/loop-once.sh has no loop session and gets none.
#
# Usage: loop-lineage.sh start <loop pid> | pane-loop <loop pid> | pane-fire <loop pid> <fire> <begin epoch>
# Settings (environment):
#   AUTONOMY_LOOP_TMUX_LINEAGE   true (default) | false - false: no tmux sessions and no ledger lines
#   AUTONOMY_LOOP_TMUX_SESSION   the loop's session (default ${AGENT_TMUX_SESSION_NAME:-agent}-loop); a fire's is
#                                <that>-fire-<n>
#   AGENT_TMUX_PARENT            the loop's parent (default operator, the agent session's - tmux-session-start.sh)
#   TMUX_AGENT_HOME              the dashboard's home, where its ledger is (default: the running dashboard's own, read
#                                from its process - ui-start.sh decides it; ~/.tmux-agent, the dashboard's default,
#                                when it has none or is not running)
#   UI_DIR                       where ui-start.sh records the dashboard's pid, tmux-agent.pid (default /wd/ui)
#   AUTONOMY_LOOP_DIR, AUTONOMY_LOOP_WORKDIR, AUTONOMY_LOOP_INTERVAL, AUTONOMY_LOOP_FIRE_TIMEOUT, AUTONOMY_LOOP_GOALS
#                                loop.sh's settings, for the panes' text and the sessions' task line

export HOME=${HOME:-/home/agent}
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

AUTONOMY_LOOP_TMUX_LINEAGE=${AUTONOMY_LOOP_TMUX_LINEAGE:-true}
AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}
AUTONOMY_LOOP_WORKDIR=${AUTONOMY_LOOP_WORKDIR:-/wd}
AUTONOMY_LOOP_INTERVAL=${AUTONOMY_LOOP_INTERVAL:-300}
AUTONOMY_LOOP_FIRE_TIMEOUT=${AUTONOMY_LOOP_FIRE_TIMEOUT:-1500}
AUTONOMY_LOOP_GOALS=${AUTONOMY_LOOP_GOALS:-/wd/goals/GOALS.md}
LOOP_SESSION=${AUTONOMY_LOOP_TMUX_SESSION:-${AGENT_TMUX_SESSION_NAME:-agent}-loop}
PARENT=${AGENT_TMUX_PARENT:-operator}
# The ledger lines go where the dashboard reads its ledger: its own TMUX_AGENT_HOME, which ui-start.sh sets (or not)
# when it starts it. Unless given here, it is read from the running dashboard itself - the pid ui-start.sh recorded,
# when that process is the dashboard - and a dashboard without one uses its default, ~/.tmux-agent.
dashboard_home()
{
	local P
	P=$(cat "${UI_DIR:-/wd/ui}/tmux-agent.pid" 2> /dev/null)
	case "${P}" in "" | *[!0-9]*) return 0 ;; esac
	tr '\0' '\n' < "/proc/${P}/cmdline" 2> /dev/null | grep -q 'tmux-agent.js' || return 0
	tr '\0' '\n' < "/proc/${P}/environ" 2> /dev/null | sed -n 's/^TMUX_AGENT_HOME=//p' | head -1
}
TMUX_AGENT_HOME=${TMUX_AGENT_HOME:-$(dashboard_home)}
TMUX_AGENT_HOME=${TMUX_AGENT_HOME:-${HOME}/.tmux-agent}
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
LOOP_LOG=${AUTONOMY_LOOP_DIR}/loop.log
LOOP_STATE=${AUTONOMY_LOOP_DIR}/loop.state
# the dashboard's own rule for a session name (it refuses any other); a fire's name carries the -fire-<n> suffix
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

json_str()
{
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}

iso_ms()
{
	# 2026-10-13T12:00:05Z (a loop.log stamp) -> 2026-10-13T12:00:05.000Z (the dashboard's form)
	echo "${1%Z}.000Z"
}

ledger()
{
	# ledger <type> <session> <parent or ""> <ISO ts> <data object>: one line in the tmux-agent dashboard's ledger, the
	# shape its own spawn and kill write (v, ts, type, session, parent, actor, data), in the day file of <ts>, the
	# directory 0700 and the file 0600 like the dashboard's own
	local P=""
	[ -n "$3" ] && P=",\"parent\":\"$(json_str "$3")\""
	( umask 077; mkdir -p "${TMUX_AGENT_HOME}/ledger" \
		&& printf '{"v":1,"ts":"%s","type":"%s","session":"%s"%s,"actor":"do-agent-aws","data":%s}\n' \
			"$4" "$1" "$(json_str "$2")" "${P}" "$5" >> "${TMUX_AGENT_HOME}/ledger/events-${4:0:10}.ndjson" ) 2> /dev/null
}

loop_alive()
{
	[ -d "/proc/$1" ] && tr '\0' ' ' < "/proc/$1/cmdline" 2> /dev/null | grep -qE '(^|[/ ])loop\.sh( |$)'
}

# the settings a pane needs, handed over with -e: a pane inherits the tmux SERVER's environment, not this caller's
PANE_ENV=(-e "AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR}" -e "AUTONOMY_LOOP_WORKDIR=${AUTONOMY_LOOP_WORKDIR}"
	-e "AUTONOMY_LOOP_INTERVAL=${AUTONOMY_LOOP_INTERVAL}" -e "AUTONOMY_LOOP_FIRE_TIMEOUT=${AUTONOMY_LOOP_FIRE_TIMEOUT}"
	-e "AUTONOMY_LOOP_GOALS=${AUTONOMY_LOOP_GOALS}" -e "AUTONOMY_LOOP_TMUX_SESSION=${LOOP_SESSION}"
	-e "AGENT_TMUX_PARENT=${PARENT}" -e "TMUX_AGENT_HOME=${TMUX_AGENT_HOME}")

lineage_options()
{
	# lineage_options <session> <parent> <task> <role> - the user options the dashboard's census reads
	tmux set-option -t "=$1:" @agent_parent "$2"
	tmux set-option -t "=$1:" @agent_owner do-agent-aws
	tmux set-option -t "=$1:" @agent_task "$3"
	tmux set-option -t "=$1:" @agent_role "$4"
}

start()
{
	LOOP_PID=$1
	if [ "${AUTONOMY_LOOP_TMUX_LINEAGE}" != "true" ]; then
		echo "tmux lineage: off (AUTONOMY_LOOP_TMUX_LINEAGE=${AUTONOMY_LOOP_TMUX_LINEAGE})"
		return 0
	fi
	if ! echo "${LOOP_SESSION}-fire-999999" | grep -qE "${NAME_RE}"; then
		echo "tmux lineage: '${LOOP_SESSION}' is not a session name the dashboard accepts with a -fire-<n> suffix (a letter or digit first, then letters, digits, . _ -; at most 64) - no loop session"
		return 0
	fi
	command -v tmux > /dev/null || { echo "tmux lineage: tmux is not installed - no loop session"; return 0; }
	loop_alive "${LOOP_PID}" || { echo "tmux lineage: pid ${LOOP_PID} is not a running loop.sh - no loop session"; return 0; }
	if ! tmux list-sessions > /dev/null 2>&1; then
		echo "tmux lineage: no tmux server is running (the agent session starts one) - the loop has no session in the tmux-agent dashboard's tree"
		return 0
	fi
	if tmux has-session -t "=${LOOP_SESSION}" 2> /dev/null; then
		if [ "$(tmux show-options -qv -t "=${LOOP_SESSION}:" @agent_loop_pid 2> /dev/null)" == "${LOOP_PID}" ]; then
			echo "tmux lineage: session '${LOOP_SESSION}' already shows the loop (pid ${LOOP_PID})"
			return 0
		fi
		# an earlier loop's session whose pane has not seen that loop exit yet
		tmux kill-session -t "=${LOOP_SESSION}" 2> /dev/null
	fi
	if ! tmux new-session -d -s "${LOOP_SESSION}" -n loop -c "${AUTONOMY_LOOP_WORKDIR}" "${PANE_ENV[@]}" \
		"'${SELF}' pane-loop ${LOOP_PID}"; then
		echo "tmux lineage: could not create the session '${LOOP_SESSION}'"
		return 0
	fi
	lineage_options "${LOOP_SESSION}" "${PARENT}" "the autonomy loop - a fire every ${AUTONOMY_LOOP_INTERVAL}s against ${AUTONOMY_LOOP_GOALS}; it runs detached as pid ${LOOP_PID}, this session is its view" loop
	tmux set-option -t "=${LOOP_SESSION}:" @agent_loop_pid "${LOOP_PID}"
	echo "tmux lineage: session '${LOOP_SESSION}' (parent ${PARENT}) shows the loop (pid ${LOOP_PID}); a session per fire follows while it runs"
}

fire_open()
{
	# fire_open <n> <loop.log stamp of its BEGIN>
	[ -n "${OPEN}" ] && fire_close "${OPEN}" "$2" "" "" "another fire began before this one logged its END"
	FS="${LOOP_SESSION}-fire-$1"
	BEGIN=$(date -u -d "$2" +%s 2> /dev/null || date +%s)
	# a fire's number repeats after an interrupted fire: the older session, if it is still there, is that fire's
	tmux kill-session -t "=${FS}" 2> /dev/null
	tmux new-session -d -s "${FS}" -n fire -c "${AUTONOMY_LOOP_WORKDIR}" "${PANE_ENV[@]}" \
		"'${SELF}' pane-fire ${LOOP_PID} $1 ${BEGIN}" || return 0
	lineage_options "${FS}" "${LOOP_SESSION}" "fire $1 of the autonomy loop, began $2 - it runs detached under the loop (pid ${LOOP_PID}), this session is its view" fire
	ledger session.spawned "${FS}" "${LOOP_SESSION}" "$(iso_ms "$2")" \
		"{\"cwd\":\"$(json_str "${AUTONOMY_LOOP_WORKDIR}")\",\"command\":null,\"task\":\"fire $1 of the autonomy loop\"}"
	OPEN=$1
}

fire_close()
{
	# fire_close <n> <loop.log stamp> <rc or ""> <duration or ""> [<reason>]
	local DATA="{\"force\":false"
	[ -n "$3" ] && DATA="${DATA},\"rc\":$3"
	[ -n "$4" ] && DATA="${DATA},\"duration_s\":$4"
	[ -n "$5" ] && DATA="${DATA},\"reason\":\"$(json_str "$5")\""
	ledger session.killed "${LOOP_SESSION}-fire-$1" "" "$(iso_ms "$2")" "${DATA}}"
	tmux kill-session -t "=${LOOP_SESSION}-fire-$1" 2> /dev/null
	[ "${OPEN}" == "$1" ] && OPEN=""
}

read_new_lines()
{
	# the loop.log lines after line DONE: shown in the pane, a fire's BEGIN opening its session and its END closing it
	TOTAL=$(wc -l < "${LOOP_LOG}" 2> /dev/null || echo 0)
	[ "${TOTAL}" -lt "${DONE}" ] && DONE=0
	[ "${TOTAL}" -gt "${DONE}" ] || return 0
	while IFS= read -r LINE; do
		echo "${LINE}"
		TS=${LINE%% *}
		case "${LINE#* }" in
		"FIRE "*" BEGIN"*)
			fire_open "$(echo "${LINE}" | cut -d' ' -f3)" "${TS}"
			;;
		"FIRE "*" END rc="*)
			RC=$(echo "${LINE}" | sed -nE 's/.* END rc=(-?[0-9]+).*/\1/p')
			DUR=$(echo "${LINE}" | sed -nE 's/.* duration=([0-9]+)s.*/\1/p')
			fire_close "$(echo "${LINE}" | cut -d' ' -f3)" "${TS}" "${RC}" "${DUR}"
			;;
		esac
	done < <(sed -n "$((DONE + 1)),${TOTAL}p" "${LOOP_LOG}")
	DONE=${TOTAL}
}

pane_loop()
{
	LOOP_PID=$1
	OPEN=""
	echo "Agent loop (pid ${LOOP_PID}) - this tmux session is the loop's place in the fleet; the loop itself runs detached"
	echo "(state in ${AUTONOMY_LOOP_DIR}: /agent/loop-status.sh, or the Agent loop page). Its log follows; a session per fire opens while the fire runs."
	echo
	ledger session.spawned "${LOOP_SESSION}" "${PARENT}" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
		"{\"cwd\":\"$(json_str "${AUTONOMY_LOOP_WORKDIR}")\",\"command\":\"/agent/loop.sh\",\"task\":\"the autonomy loop (pid ${LOOP_PID})\"}"
	DONE=0
	if [ -f "${LOOP_LOG}" ]; then
		DONE=$(wc -l < "${LOOP_LOG}")
		tail -n 12 "${LOOP_LOG}"
	fi
	# A loop that started under a minute ago (loop-start.sh runs this right after the start): its lines from its own
	# LOOP START on are read below as new, so a first fire that already ended - one that failed at once - is in the
	# history too. An older loop (a session made again on an "already running" start) is never replayed; only the
	# fire in flight, if any, is taken over.
	START_LINE=$(grep -n ' LOOP START ' "${LOOP_LOG}" 2> /dev/null | tail -1)
	START_AT=$(date -u -d "$(echo "${START_LINE}" | cut -d: -f2- | cut -d' ' -f1)" +%s 2> /dev/null || echo 0)
	if [ -n "${START_LINE}" ] && [ $(( $(date +%s) - START_AT )) -le 60 ]; then
		DONE=$(( ${START_LINE%%:*} - 1 ))
	else
		N=$(sed -nE 's/^FIRING fire=([0-9]+).*/\1/p' "${LOOP_STATE}" 2> /dev/null)
		if [ -n "${N}" ]; then
			B=$(grep -E "^[^ ]+ FIRE ${N} BEGIN" "${LOOP_LOG}" 2> /dev/null | tail -1 | cut -d' ' -f1)
			[ -n "${B}" ] && fire_open "${N}" "${B}"
		fi
	fi
	while loop_alive "${LOOP_PID}"; do
		read_new_lines
		sleep 2
	done
	# The loop's last lines land after the last read above when the loop exits right after a fire: a fire that set the
	# STOP flag itself (its goals all done) ends, and loop.sh logs its END and LOOP STOPPED and exits in the same
	# second. Read them before closing anything, so that fire closes with its rc, not as one the loop's exit cut off.
	read_new_lines
	echo
	echo "the loop (pid ${LOOP_PID}) has exited: $(cat "${LOOP_STATE}" 2> /dev/null)"
	[ -n "${OPEN}" ] && fire_close "${OPEN}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "" "" "the loop exited during this fire"
	ledger session.killed "${LOOP_SESSION}" "" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "{\"force\":false,\"reason\":\"the loop exited\"}"
}

pane_fire()
{
	LOOP_PID=$1
	echo "Fire $2 of the autonomy loop - began $(date -u -d "@$3" +%Y-%m-%dT%H:%M:%SZ)"
	echo "It runs detached, inside the loop's process group (loop pid ${LOOP_PID}); this tmux session is its place in the fleet."
	echo "Transcript: ${AUTONOMY_LOOP_DIR}/fires/fire-$2.out (written when the fire ends; also on the Agent loop page)"
	while loop_alive "${LOOP_PID}"; do
		printf '\r  working for %ss (timeout %ss) ' "$(( $(date +%s) - $3 ))" "${AUTONOMY_LOOP_FIRE_TIMEOUT}"
		sleep 2
	done
	echo
	echo "the loop has exited"
}

case "$1" in
start)
	[ -n "$2" ] || { echo "usage: $0 start <loop pid>" >&2; exit 64; }
	start "$2"
	;;
pane-loop)
	pane_loop "$2"
	;;
pane-fire)
	pane_fire "$2" "$3" "$4"
	;;
*)
	echo "usage: $0 start <loop pid> | pane-loop <loop pid> | pane-fire <loop pid> <fire> <begin epoch>" >&2
	exit 64
	;;
esac
