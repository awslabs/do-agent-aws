#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The supervisor: starts the enabled agent sessions of the registry and keeps them alive and unstuck (docs/AGENT-STACK.md
# "What the supervisor does on every pass"). A script that never calls a model: the harness's port of the fleet's
# session watchdog (an idempotent relaunch from a JSON registry of sessions, one instance at a time, a cooldown per
# session, the entry's env in the launch) and of its fleet check (/agent/fleet-check.sh: the pane's state, and the one
# safe repair).
#
#   /agent/supervisor.sh start    start the loop unless it runs (startup.sh does at every container start), and its tmux
#                                 session supervisor, which shows the last pass; one row per session
#   /agent/supervisor.sh status   one row per session; exit 1 when an enabled one is not live or the last pass is stale;
#                                 with SUPERVISOR=false every row reads OFF and the exit is 0 (nothing runs the
#                                 spokes, so none can be live: a setting, not a failure)
#   /agent/supervisor.sh ensure   start the loop again when its last pass is older than two intervals and a minute (the
#                                 container's main loop runs this every minute: someone watches the watcher); quiet
#                                 when all is well, and never after a stop
#   /agent/supervisor.sh stop     end the loop and leave its stop flag, so ensure does not start it again until start;
#                                 the sessions keep running
#   /agent/supervisor.sh run      the loop itself, in the foreground (what start detaches)
#   /agent/supervisor.sh view     the last pass, redrawn (what the supervisor session's pane runs)
#   /agent/supervisor.sh ledger [<session>]
#                                 the latest line of each session in the session ledger (or of one): what it runs, where,
#                                 its work, and the command that resumes it
#   /agent/supervisor.sh resume <session>
#                                 recreate a session that is not running from its latest ledger line: a registry session
#                                 through its registry start, a scratch one in its recorded directory with its recorded
#                                 command (claude --resume <id> when its Claude Code session id is known); refused while it
#                                 runs; a resume line records it
#   /agent/supervisor.sh record-stop
#                                 a stop line for every running session (the stack's stop path: ./stop.sh runs it in the
#                                 container before it removes it); nothing with SUPERVISOR=false
#
# Every SUPERVISOR_INTERVAL seconds (default 15, a whole number of at least 1), for each enabled entry of the registry
# (/agent/spokes/registry.json: the hub and the spokes; an entry's .env flag decides, its "enabled" is the default):
#  1. Alive? Its tmux session, with its agent process (the entry's agent_process, claude) in its agent's pane (the one
#     its start recorded, fleet-check.sh pane). A spoke without its session is started again
#     (/agent/tmux-session-start.sh <name>): the first start and the first restart at once, each further restart after
#     twice the wait of the one before, from the entry's cooldown_sec; after SUPERVISOR_RESTART_CAP restarts without
#     staying up SUPERVISOR_HEALTHY_SECS it is stuck and left alone until the loop starts again. The hub's session is
#     started again when it is gone, once per cooldown; a hub pane with a shell and no claude is reported, never
#     replaced (the pane is the person's). A session without its agent process SUPERVISOR_START_GRACE seconds after its
#     start is reported down.
#  2. Stuck? /agent/fleet-check.sh reads the pane: a menu open, "compaction failed", "API Error", "Prompt is too long", or
#     a status line at 80% context or more. Each is reported; the reading errs toward "working".
#  3. Safe repairs: /compact, once per high-context spell, into a spoke's pane idle at an empty prompt line at 80% or
#     more - never into the hub's pane, never at a menu, never while a turn runs. Nothing else: no menu is ever
#     answered, and no prompt that would send, spend or delete. /clear is not in this version: no rule for a backlog
#     that /clear would be safe on is defined.
#  4. Health: the memory API (/health) and the session-memory worker (it answers, and its queue depth stays under
#     SUPERVISOR_MEMORY_QUEUE_WARN), each only when its UI is on. And the Loop Deck's server, the one UI this loop starts
#     again (UI_START and UI_LOOP_DECK on): ui-start.sh starts it with /agent/loop-deck-start.sh, which records its pid in
#     ${UI_DIR}/loop-deck.pid. A pid there that is no longer the Deck's server is a server that died, and it is started
#     again with that script the way a spoke's session is: at once, then after SUPERVISOR_DECK_COOLDOWN seconds, doubling,
#     and after SUPERVISOR_RESTART_CAP restarts that did not stay up SUPERVISOR_HEALTHY_SECS it is stuck, left alone until
#     the loop starts again. Each restart and the stuck verdict is a line of ${SUPERVISOR_DIR}/loop-deck/restarts.log and
#     a notice to the hub. Without the pidfile (never started, or stopped with ui-stop.sh, which removes it) it is left
#     alone. Its state is status.json's health.loop_deck.
#  5. A spoke's cycle: the entry's cycle command every cadence_sec seconds in its workdir, with the entry's env, as
#     BUS_AGENT_ID=<name>; its output in ${SUPERVISOR_DIR}/<name>/cycle.out, last-cycle when it exits 0; what the cycle
#     leaves for the hub (the entry's notices: "stdout:<prefix>" lines, or "jsonl:<file>" records) becomes bus notices
#     from the spoke (/agent/bus.sh note).
#  6. Report: every change of a session's verdict, and every restart, repair or health change (health from
#     SUPERVISOR_START_GRACE seconds after the loop's start, when the container's services are up), is one bus notice
#     from the supervisor to the hub and a line of ${SUPERVISOR_DIR}/supervisor.log; each pass is one line of
#     ${SUPERVISOR_DIR}/passes.jsonl (the last 1000 kept) and ${SUPERVISOR_DIR}/status.json (the home tiles, at
#     /__spokes); the supervisor session's @agent_task on the tmux-agent dashboard says the last pass.
#  7. The session ledger (${SUPERVISOR_DIR}/sessions-ledger.jsonl, /agent/session-ledger.py; docs/AGENT-STACK.md "The
#     session ledger"), first in each pass: every session on the tmux server - the registry's, and the scratch ones a
#     person or the hub starts, not the views the harness's own scripts start and end - against its latest line; a session
#     that came gets a start line and one that went a stop line, with its pane's pid, directory, command, the commit of
#     its directory, its work and the command that resumes it. Every start and restart above writes its own start line
#     (tmux-session-start.sh). Lines are only ever appended. A read of the tmux server that fails is not an empty server:
#     that pass writes no line and closes nothing.
#  8. The bounded close, after the restarts in each pass: a session the registry does not list whose every pane's process
#     has exited (a pane tmux keeps after its process ends, with the output it printed) at two passes in a row, and still
#     when read again, has that output copied to ${SUPERVISOR_DIR}/closed/<session>.<created>.txt, then is closed with a
#     closed-exited line naming the file and one notice to the hub; a session whose output cannot be copied, or whose read
#     again fails, stays open. A pane whose process runs is never touched, nor is a session of the registry (step 1 owns
#     those); the copy refuses a pane started again since the census, and the session stays;
#     SUPERVISOR_CLOSE_EXITED=false turns the close off.
#
# Settings (environment; .env declares them): SUPERVISOR (true), SUPERVISOR_INTERVAL (15), SUPERVISOR_RESTART_CAP (5),
# SUPERVISOR_HEALTHY_SECS (300), SUPERVISOR_START_GRACE (120), SUPERVISOR_MEMORY_QUEUE_WARN (500), SUPERVISOR_CLOSE_EXITED
# (true), SUPERVISOR_DIR (/wd/supervisor), SPOKES_REGISTRY, AGENT_TMUX_SESSION_NAME (the hub, agent),
# SUPERVISOR_DECK_COOLDOWN (60, the Loop Deck server's first wait between two restarts; not in .env).

export HOME=${HOME:-/home/agent}
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

SUPERVISOR=${SUPERVISOR:-true}
SUPERVISOR_INTERVAL=${SUPERVISOR_INTERVAL:-15}
# a pass every 0 s or every "abc" s would spin: refused before anything runs
case "${SUPERVISOR_INTERVAL}" in
	''|*[!0-9]*) echo "supervisor: ERROR - SUPERVISOR_INTERVAL='${SUPERVISOR_INTERVAL}' is not a whole number of seconds" >&2; exit 2 ;;
esac
[ "$((10#${SUPERVISOR_INTERVAL}))" -ge 1 ] || { echo "supervisor: ERROR - SUPERVISOR_INTERVAL=${SUPERVISOR_INTERVAL} is under 1 s" >&2; exit 2; }
SUPERVISOR_RESTART_CAP=${SUPERVISOR_RESTART_CAP:-5}
SUPERVISOR_HEALTHY_SECS=${SUPERVISOR_HEALTHY_SECS:-300}
SUPERVISOR_START_GRACE=${SUPERVISOR_START_GRACE:-120}
SUPERVISOR_MEMORY_QUEUE_WARN=${SUPERVISOR_MEMORY_QUEUE_WARN:-500}
SUPERVISOR_CLOSE_EXITED=${SUPERVISOR_CLOSE_EXITED:-true}
SUPERVISOR_DIR=${SUPERVISOR_DIR:-/wd/supervisor}
AGENT_TMUX_SESSION_NAME=${AGENT_TMUX_SESSION_NAME:-agent}
export SUPERVISOR_DIR AGENT_TMUX_SESSION_NAME

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPOKE="${AGENT_DIR}/spoke.sh"
FLEET_CHECK="${AGENT_DIR}/fleet-check.sh"
BUS="${AGENT_DIR}/bus.sh"
LEDGER_TOOL="${AGENT_DIR}/session-ledger.py"
LOCK_FILE=${SUPERVISOR_DIR}/supervisor.lock
PID_FILE=${SUPERVISOR_DIR}/supervisor.pid
STOP_FLAG=${SUPERVISOR_DIR}/STOP
STATUS=${SUPERVISOR_DIR}/status.json
PASSES=${SUPERVISOR_DIR}/passes.jsonl
LOG=${SUPERVISOR_DIR}/supervisor.log
# the supervisor's own session name, from its registry entry
SELF=$("${SPOKE}" sessions 2>/dev/null | awk '$2 == "supervisor" { print $1; exit }')
[ -n "${SELF}" ] || SELF=supervisor

now() { date +%s; }
utc() { date -u +%FT%TZ; }

# loop_running - the loop holds its lock for its whole life (the kernel releases it when the loop dies)
loop_running()
{
	[ -f "${LOCK_FILE}" ] || return 1
	exec 7< "${LOCK_FILE}"
	if flock -n 7; then
		exec 7<&-
		return 1
	fi
	exec 7<&-
	return 0
}

# pass_age - seconds since the last pass (status.json is rewritten after each), or nothing without one
pass_age()
{
	[ -f "${STATUS}" ] || return 1
	echo $(( $(now) - $(stat -c %Y "${STATUS}") ))
}
STALE_AFTER=$(( 2 * SUPERVISOR_INTERVAL + 60 ))

# the entries the loop supervises: "<name> <role> <requires> <what> <agent process>" for every hub and spoke that is
# switched on, from ${TABLE} (spoke.sh table: the registry, read once a pass)
supervised()
{
	while read -r N R E _ REQ WHAT HOOK; do
		[ "${R}" == "hub" ] || [ "${R}" == "spoke" ] || continue
		[ "${E}" == "true" ] && echo "${N} ${R} ${REQ} ${WHAT} ${HOOK}"
	done <<< "${TABLE}"
}

# rows - one line for the supervisor and one per session, from the last pass; returns 1 when an enabled spoke is not live,
# or the supervisor is down or stale while a spoke is enabled. The hub's row never counts: its pane is the person's, and
# a menu or a shell there is the person's business (the row says so, and the supervisor tells the hub). With
# SUPERVISOR=false nothing starts or watches a spoke, so a spoke's row reads OFF with that reason and counts no more than
# the supervisor's own OFF row: the status fails on a spoke the supervisor lost, never on the setting that runs none
rows()
{
	RC=0
	AGE=$(pass_age)
	FAIL=0
	# the registry and the last pass, read once each
	TABLE=$("${SPOKE}" table)
	[ -n "$(awk '$2 == "spoke" && $3 == "true"' <<< "${TABLE}")" ] && FAIL=1
	declare -A ROWS=()
	while IFS=$'\x1f' read -r N ROW; do
		ROWS[${N}]=${ROW}
	done < <(python3 -I - "${STATUS}" << 'PY' 2>/dev/null
import json, sys
for n, s in json.load(open(sys.argv[1]))["sessions"].items():
    print(n, s.get("state") or "", str(s.get("why") or "").replace("\n", " "), s.get("last_cycle") or "", s.get("restarts") or 0,
          s.get("how") or "", sep="\x1f")
PY
)
	if [ "${SUPERVISOR}" != "true" ]; then
		echo "supervisor: OFF (SUPERVISOR=${SUPERVISOR} in .env.local; nothing starts or watches the spokes)"
	elif ! loop_running && [ -f "${STOP_FLAG}" ]; then
		echo "supervisor: STOPPED - supervisor.sh stop left its stop flag; ${AGENT_DIR}/supervisor.sh start runs it again (the keepalive leaves it stopped)"
	elif ! loop_running; then
		echo "supervisor: DOWN - SUPERVISOR=true and the loop does not run (${AGENT_DIR}/supervisor.sh start; the container's keepalive starts it within a minute)"
		RC=${FAIL}
	elif [ -z "${AGE}" ]; then
		echo "supervisor: STARTING pid=$(cat "${PID_FILE}" 2>/dev/null) - no pass yet"
	elif [ "${AGE}" -gt "${STALE_AFTER}" ]; then
		echo "supervisor: STALE pid=$(cat "${PID_FILE}" 2>/dev/null) - its last pass was ${AGE} s ago (interval ${SUPERVISOR_INTERVAL} s)"
		RC=${FAIL}
	else
		echo "supervisor: UP pid=$(cat "${PID_FILE}" 2>/dev/null) interval=${SUPERVISOR_INTERVAL}s last pass ${AGE} s ago (${STATUS})"
	fi
	while read -r N R E FLAG _; do
		[ "${R}" == "hub" ] || [ "${R}" == "spoke" ] || continue
		if [ "${E}" != "true" ]; then
			[ "${R}" == "spoke" ] && echo "spoke ${N}: OFF (set ${FLAG}=true in .env.local to run it)"
			continue
		fi
		IFS=$'\x1f' read -r S WHY LAST RESTARTS HOW <<< "${ROWS[${N}]}"
		L="spoke ${N}"
		if [ "${R}" == "hub" ]; then
			# the hub's row, when a pass saw it; never in the exit status
			case "${S}" in
				live)        echo "hub ${N}: LIVE${WHY:+ (${WHY})}" ;;
				stuck|down)  echo "hub ${N}: ${S^^} - ${WHY} (the person's pane: reported, never typed into)" ;;
				starting)    echo "hub ${N}: STARTING - ${WHY}" ;;
			esac
			continue
		fi
		if [ "${SUPERVISOR}" != "true" ]; then
			echo "${L}: OFF (SUPERVISOR=${SUPERVISOR} in .env.local: nothing starts or watches it; ${FLAG}=true)"
			continue
		fi
		case "${S}" in
			live)     echo "${L}: LIVE session=${N}${LAST:+ last_cycle=${LAST}} restarts=${RESTARTS}/${SUPERVISOR_RESTART_CAP}${WHY:+ (${WHY})}" ;;
			starting) echo "${L}: STARTING session=${N} - ${WHY}"; RC=1 ;;
			waiting)  echo "${L}: WAITING session=${N} - ${WHY}${HOW:+; ${HOW}}" ;;
			stuck)    echo "${L}: STUCK - ${WHY} (${SUPERVISOR_DIR}/${N}/restarts.log)"; RC=1 ;;
			down)     echo "${L}: DOWN - ${WHY} (${SUPERVISOR_DIR}/${N}/restarts.log)"; RC=1 ;;
			*)        echo "${L}: UNKNOWN - ${FLAG}=true and the supervisor has not reported on it"; RC=1 ;;
		esac
	done <<< "${TABLE}"
	return ${RC}
}

start_loop()
{
	mkdir -p "${SUPERVISOR_DIR}" || { echo "supervisor: ERROR - cannot create ${SUPERVISOR_DIR}"; return 1; }
	# without the caller's tmux pane: bus.sh takes the sender from the pane, so a loop started from the agent pane would
	# send every notice as agent to agent
	env -u TMUX -u TMUX_PANE setsid nohup "${AGENT_DIR}/supervisor.sh" run >> "${LOG}" 2>&1 < /dev/null &
	for I in 1 2 3 4 5 6 7 8 9 10; do
		loop_running && break
		sleep 0.5
	done
	loop_running || { echo "supervisor: ERROR - the loop did not start: $(tail -3 "${LOG}")"; return 1; }
	# its tmux session, the view of its log the dashboard lists with its lineage (left alone when it exists)
	command -v tmux > /dev/null && "${AGENT_DIR}/tmux-session-start.sh" "${SELF}" > /dev/null 2>&1
	return 0
}

# census_list - the sessions the session ledger keeps, from one tmux call, "<name> <agent pane pid> <created> <exited>
# <status>" a line: the agent pane as fleet-check.sh picks it (the one @agent_pane names, else the active pane of the active
# window), the session's creation time (epoch seconds; with the pid, which a new container can hand out again, it tells
# one session of a name from the next), exited 1 when the process of every pane of the session has exited (panes tmux
# keeps after their process ends) and status the agent pane's exit status. Every session of the registry (${TABLE}), and
# every other one but the views the harness's own scripts start and end (owner do-agent-aws and not in the registry: the
# autonomy loop's); plain names only. Returns 2, printing nothing, when tmux cannot be read and the reason is not that no
# server runs (none started yet, or its last session went): a failed read is not an empty server. The failed read's
# words go to ${SUPERVISOR_DIR}/census.err
census_list()
{
	local OUT WHY ERRF=/dev/null
	[ -d "${SUPERVISOR_DIR}" ] && ERRF="${SUPERVISOR_DIR%/}/census.err"
	OUT=$(timeout 10 tmux list-panes -a -F $'#{session_name}\t#{pane_id}\t#{pane_pid}\t#{window_active}#{pane_active}\t#{@agent_pane}\t#{pane_dead}\t#{pane_dead_status}\t#{@agent_owner}\t#{session_created}' 2> "${ERRF}") || {
		WHY=$(timeout 10 tmux list-sessions 2>&1 > /dev/null)
		case "${WHY}" in
			*"no server running"*|*"error connecting to"*"(No such file or directory)"*|*"error connecting to"*"(Connection refused)"*) return 0 ;;
		esac
		return 2
	}
	awk -F '\t' -v reg=" $(awk '{ printf "%s ", $1 }' <<< "${TABLE}")" '
			$1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || length($1) > 64 { next }
			!($1 in X) { X[$1] = 1; N[++k] = $1 }
			$6 != "1" { LIVE[$1] = 1 }
			$8 == "do-agent-aws" { OWN[$1] = 1 }
			($5 != "" && $2 == $5) || ($5 == "" && $4 == "11") { P[$1] = $3; S[$1] = ($7 == "" ? "-" : $7); C[$1] = $9 }
			END {
				for (i = 1; i <= k; i++) {
					s = N[i]
					if (P[s] == "" || (index(reg, " " s " ") == 0 && (s in OWN))) continue
					print s, P[s], (C[s] == "" ? "-" : C[s]), ((s in LIVE) ? 0 : 1), S[s]
				}
			}' <<< "${OUT}"
}

# keep_output <session> <file> - the output tmux keeps for every pane of the session, its history included, copied into
# <file> (its directory made first), a header line per pane naming the pane, its exit status, the lines its history held
# with the pane's history-limit, and its command. tmux keeps no more history than that limit (2000 lines unless set) and
# drops the earliest lines a tenth of it at a time, so a history within a tenth of the limit says its earliest lines may
# be gone. The status is "-" when tmux gives none: tmux 3.2a gives none for a process a signal ended, nor at times for
# one that exited while tmux was busy (another pane's exit, or reads such as this loop's). Returns 3, writing nothing,
# when the process of a pane runs (a pane started again since the census read it); fails when the panes cannot be read
# or the file cannot be written. Either way the bounded close leaves the session open
keep_output()
{
	local L ID EXITED ST HS HL CMD CAP T N=0
	L=$(timeout 10 tmux list-panes -s -t "=$1:" -F $'#{pane_id}\t#{pane_dead}\t#{?#{!=:#{pane_dead_status},},#{pane_dead_status},-}\t#{history_size}\t#{history_limit}\t#{pane_start_command}' 2> /dev/null) || return 1
	[ -n "${L}" ] || return 1
	awk -F '\t' '$2 != "1" { r = 1 } END { exit r }' <<< "${L}" || return 3
	mkdir -p "${2%/*}" 2> /dev/null && : > "$2" 2> /dev/null || return 1
	# no field before the command is ever empty, so a read split at tabs keeps each in its place
	while IFS=$'\t' read -r ID EXITED ST HS HL CMD; do
		N=$((N + 1))
		# tmux shows a start command in double quotes
		CMD=${CMD#\"} CMD=${CMD%\"}
		CAP=""
		[[ "${HS}" =~ ^[0-9]+$ && "${HL}" =~ ^[0-9]+$ ]] && [ "${HS}" -ge $(( HL - (HL / 10 > 1 ? HL / 10 : 1) )) ] \
			&& CAP=": its earliest lines may be gone"
		# the pane's history and screen (tmux keeps an exited pane's output in its history), each line's trailing blanks and
		# the blank lines at the end left out; the read's own status decides
		T=$(timeout 10 tmux capture-pane -p -J -S - -E - -t "${ID}" 2> /dev/null | sed -e 's/[[:space:]]*$//'; exit "${PIPESTATUS[0]}") || return 1
		printf '=== %s: its process exited with status %s; its history held %s lines (history-limit %s%s); its command: %s\n%s\n' \
			"${ID}" "${ST}" "${HS}" "${HL}" "${CAP}" "${CMD}" "${T}" >> "$2" || return 1
	done <<< "${L}"
	[ "${N}" -gt 0 ]
}

case "$1" in
	status)
		rows
		exit $?
		;;
	start)
		if [ "${SUPERVISOR}" == "true" ] && ! loop_running; then
			# starting is the explicit signal to run: a stop flag left by an earlier stop goes, here and nowhere else
			rm -f "${SUPERVISOR_DIR:?}/STOP"
			start_loop || exit 1
		fi
		rows
		exit 0
		;;
	ensure)
		[ "${SUPERVISOR}" == "true" ] || exit 0
		# stopped on purpose (supervisor.sh stop): the keepalive leaves it stopped until supervisor.sh start
		[ -f "${STOP_FLAG}" ] && exit 0
		AGE=$(pass_age)
		if loop_running && { [ -z "${AGE}" ] || [ "${AGE}" -le "${STALE_AFTER}" ]; }; then
			command -v tmux > /dev/null && ! tmux has-session -t "=${SELF}" 2>/dev/null && "${AGENT_DIR}/tmux-session-start.sh" "${SELF}" > /dev/null 2>&1
			exit 0
		fi
		WHY="the loop was not running"
		if loop_running; then
			# a loop that holds its lock and no longer passes: ended by its pid, once that pid is shown to be this loop
			P=$(cat "${PID_FILE}" 2>/dev/null)
			if [ -n "${P}" ] && tr '\0' ' ' < "/proc/${P}/cmdline" 2>/dev/null | grep -q "supervisor.sh run"; then
				kill "${P}" 2>/dev/null
				for I in $(seq 1 20); do loop_running || break; sleep 0.5; done
			fi
			WHY="its last pass was ${AGE} s old"
		fi
		loop_running && { echo "$(utc) supervisor: ensure - ${WHY}, and the loop could not be ended"; exit 1; }
		start_loop || exit 1
		echo "$(utc) supervisor: started again - ${WHY}"
		echo "the supervisor was started again: ${WHY}" | env -u TMUX -u TMUX_PANE BUS_AGENT_ID=${SELF} "${BUS}" note "${AGENT_TMUX_SESSION_NAME}" > /dev/null 2>&1
		exit 0
		;;
	stop)
		# the flag first, even when the loop is not running: the keepalive's ensure must not start it again
		mkdir -p "${SUPERVISOR_DIR}" && touch "${STOP_FLAG}"
		loop_running || { echo "supervisor: stopped (it was not running; supervisor.sh start runs it again)"; exit 0; }
		for I in $(seq 1 $((SUPERVISOR_INTERVAL * 2 + 10))); do
			loop_running || { echo "supervisor: stopped (the sessions keep running)"; exit 0; }
			sleep 1
		done
		echo "supervisor: still running $((SUPERVISOR_INTERVAL * 2 + 10)) s after the stop flag"
		exit 1
		;;
	view)
		# the pass, as names and states, redrawn every few seconds - never the reasons: they quote panes ("API Error",
		# a menu's "1."), and the tmux-agent dashboard reads this pane's words as the supervisor's own state. The
		# reasons are in supervisor.log, status.json, the notices to the hub and supervisor.sh status
		while :; do
			OUT=$(python3 -I - "${STATUS}" << 'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
on = {n: s for n, s in d["sessions"].items() if s["enabled"]}
live = [n for n, s in on.items() if s["state"] == "live"]
print(f"supervisor, pass {d['pass']} at {d['updated_at']}: {len(live)} of {len(on)} sessions live")
for n, s in sorted(on.items()):
    print(f"  {n:<24} {s['state']}")
print("")
print("the reasons: supervisor.sh status, and the log beside status.json")
PY
)
			printf '\033[H\033[2J%s\n' "${OUT:-supervisor: no pass yet}"
			sleep 5
		done
		;;
	ledger)
		# the latest line of each session in the session ledger, or of one: what it ran, where, its work, how to resume it
		python3 -I "${LEDGER_TOOL}" latest ${2:+"$2"}
		exit $?
		;;
	resume)
		[ -n "$2" ] || { echo "usage: $0 resume <session>" >&2; exit 64; }
		python3 -I "${LEDGER_TOOL}" resume "$2"
		exit $?
		;;
	record-stop)
		# the stack's stop path (./stop.sh runs it in the container before it removes it): a stop line for each session the
		# census sees, each read from its running pane, with its Claude Code session when known; with the supervisor off, none
		[ "${SUPERVISOR}" == "true" ] || { echo "supervisor: OFF - no stop recorded (SUPERVISOR=${SUPERVISOR})"; exit 0; }
		command -v tmux > /dev/null || { echo "supervisor: no tmux - no session to record"; exit 0; }
		TABLE=$("${SPOKE}" table)
		CEN=$(census_list) || { echo "supervisor: the tmux server could not be read ($(tail -1 "${SUPERVISOR_DIR%/}/census.err" 2> /dev/null)): no stop recorded" >&2; exit 1; }
		awk '{ print $1, $2, $3 }' <<< "${CEN}" | python3 -I "${LEDGER_TOOL}" stop-all "the stack is stopping (supervisor.sh record-stop)" || exit 1
		echo "supervisor: a stop line for each running session in ${SUPERVISOR_DIR}/sessions-ledger.jsonl"
		exit 0
		;;
	run)
		;;
	*)
		echo "usage: $0 start | status | ensure | stop | run | view | ledger [<session>] | resume <session> | record-stop" >&2
		exit 64
		;;
esac

# ---------------------------------------------------------------- the loop
unset TMUX TMUX_PANE
mkdir -p "${SUPERVISOR_DIR}" || exit 1
exec 9> "${LOCK_FILE}"
flock -n 9 || { echo "$(utc) supervisor: already running"; exit 0; }
echo $$ > "${PID_FILE}"
echo "$(utc) supervisor: started pid=$$ interval=${SUPERVISOR_INTERVAL}s cap=${SUPERVISOR_RESTART_CAP} registry=${SPOKES_REGISTRY:-/agent/spokes/registry.json}"

declare -A STARTED RESTARTS NEXT_AT UP_SINCE NEXT_CYCLE CYCLE_PID CAPPED LAST_START VERDICT VQUIET WHYS ACTION COMPACTED HEALTH_SEEN EXITED_AT KEEP_ERR

say() { echo "$(utc) $*"; }
restart_log() { mkdir -p "${SUPERVISOR_DIR}/$1" && echo "$(utc) $2" >> "${SUPERVISOR_DIR}/$1/restarts.log"; }
# notify <text> - one bus notice from the supervisor to the hub, and the log line
notify()
{
	say "notice: $1"
	echo "$1" | env -u TMUX -u TMUX_PANE BUS_AGENT_ID=${SELF} "${BUS}" note "${AGENT_TMUX_SESSION_NAME}" > /dev/null 2>> "${SUPERVISOR_DIR}/bus.err" 9>&-
}

start_session()
{
	# start_session <name> <why> - the entry's session; the start's output goes to the restart log, and <why> is the reason
	# of the start's line in the session ledger
	OUT=$(SESSION_LEDGER_REASON="supervisor: $2" "${AGENT_DIR}/tmux-session-start.sh" "$1" 2>&1 9>&-)
	RC=$?
	LAST_START[$1]=$(echo "${OUT}" | tail -1)
	restart_log "$1" "$2: ${LAST_START[$1]}"
	return ${RC}
}

# agent_alive <name> <process> - the agent pane's live process tree (children and grandchildren: tmux may wrap the
# command in a shell) holds a process whose argv has a token ending in /<process> or equal to it; the pane's own command,
# its wrapper scripts, never match (test12's check, for any session). The agent's pane is the one fleet-check.sh pane
# names, the one the session's start recorded: a window a person opens in the session is not it
agent_alive()
{
	read -r _ PANE_PID <<< "$("${FLEET_CHECK}" pane "$1" 9>&-)"
	[ -n "${PANE_PID}" ] || return 1
	python3 -I - "${PANE_PID}" "$2" << 'PY'
import os, sys
root, want = sys.argv[1], sys.argv[2]
kids = {}
for p in os.listdir("/proc"):
    if p.isdigit():
        try:
            ppid = open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()[1]
        except (OSError, IndexError):
            continue
        kids.setdefault(ppid, []).append(p)
todo, seen = [root], []
while todo:
    p = todo.pop()
    for k in kids.get(p, []):
        seen.append(k)
        todo.append(k)
for p in seen:
    try:
        argv = open(f"/proc/{p}/cmdline", "rb").read().split(b"\0")
    except OSError:
        continue
    if any(a.decode(errors="replace").rsplit("/", 1)[-1] == want for a in argv if a):
        sys.exit(0)
sys.exit(1)
PY
}

run_cycle()
{
	# run_cycle <name> - one cycle of the entry's loop, in the background, in the spoke's workdir, with the entry's env;
	# then the notices it left for the hub
	N=$1
	CMD=$("${SPOKE}" entry "${N}" cycle)
	CADENCE=$("${SPOKE}" entry "${N}" cadence_sec)
	WORKDIR=$("${SPOKE}" entry "${N}" workdir)
	NOTICES=$("${SPOKE}" entry "${N}" notices 2>/dev/null)
	REC=${SUPERVISOR_DIR}/${N}
	mapfile -t ENVS < <("${SPOKE}" entry "${N}" env | python3 -I -c 'import json, sys; [print(f"{k}={v}") for k, v in json.load(sys.stdin).items()]')
	(
		exec 9>&-
		mkdir -p "${WORKDIR}" "${REC}" && cd "${WORKDIR}" || exit 1
		OUT=${REC}/cycle.this
		# no tmux identity: bus.sh takes BUS_AGENT_ID, never the session of a pane this loop was started from
		env -u TMUX -u TMUX_PANE "${ENVS[@]}" BUS_AGENT_ID="${N}" AGENT_DIR="${AGENT_DIR}" SPOKE_DIR="${WORKDIR}" \
			timeout --kill-after=10 "${CADENCE}" bash -c "${CMD}" > "${OUT}" 2>&1
		RC=$?
		{ echo "=== $(utc) cycle rc=${RC}"; cat "${OUT}"; } >> "${REC}/cycle.out"
		if [ ${RC} -eq 0 ]; then
			T=$(utc)
			echo "${T}" > "${REC}/last-cycle.tmp" && mv "${REC:?}/last-cycle.tmp" "${REC:?}/last-cycle"
			"${SPOKE}" state "${N}" "last_cycle=${T}" last_cycle_rc=0
		else
			"${SPOKE}" state "${N}" "last_cycle_rc=${RC}" "last_cycle_failed_at=$(utc)"
		fi
		# the cycle's messages for the hub: each one a notice from the spoke
		case "${NOTICES}" in
			stdout:*)
				P=${NOTICES#stdout:}
				grep -F -- "${P}" "${OUT}" | while IFS= read -r LINE; do
					[ "${LINE#"${P}"}" != "${LINE}" ] || continue
					echo "${LINE#"${P}"}" | env -u TMUX -u TMUX_PANE BUS_AGENT_ID="${N}" "${BUS}" note "${AGENT_TMUX_SESSION_NAME}" > /dev/null 2>> "${REC}/bus.err"
				done
				;;
			jsonl:*)
				F=${WORKDIR%/}/${NOTICES#jsonl:}
				OFF=$(cat "${REC}/notices.offset" 2>/dev/null)
				python3 -I - "${F}" "${OFF:-0}" "${REC}/notices.offset" << 'PY' | while IFS= read -r LINE; do
import json, os, sys
path, off, store = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3]
try:
    data = open(path, "rb").read()
except OSError:
    sys.exit(0)
end = data.rfind(b"\n") + 1
if off > end:
    off = 0
for raw in data[off:end].splitlines():
    try:
        r = json.loads(raw)
    except ValueError:
        continue
    t = r.get("text") if isinstance(r, dict) else None
    if isinstance(t, str) and t.strip():
        print(" ".join(t.split()))
open(store + ".tmp", "w").write(str(end))
os.replace(store + ".tmp", store)
PY
					echo "${LINE}" | env -u TMUX -u TMUX_PANE BUS_AGENT_ID="${N}" "${BUS}" note "${AGENT_TMUX_SESSION_NAME}" > /dev/null 2>> "${REC}/bus.err"
				done
				;;
		esac
		rm -f "${REC:?}/cycle.this"
	) &
	CYCLE_PID[${N}]=$!
	NEXT_CYCLE[${N}]=$(( $(now) + CADENCE ))
}

cycle_running()
{
	[ -n "${CYCLE_PID[$1]}" ] && jobs -pr | grep -qx "${CYCLE_PID[$1]}"
}

# verdict <name> <state> <why> [<action>] - this pass's verdict on a session; a change is one notice to the hub (the
# class of the reason decides a change - its text up to the first colon, without its numbers: a context reading that
# moves from 81% to 82%, or the seconds since a start, make the same verdict)
verdict()
{
	N=$1; S=$2; W=$3; A=$4
	K=${W%%:*}
	KEY="${S}:${K//[0-9]/}"
	# the agent session's own menus and high context are its person's, seen in the pane: they stay in status.json and
	# send no notice, nor does the return from one (a permission prompt each turn would otherwise flap the inbox)
	QUIET=""
	[ "${N}" == "${AGENT_TMUX_SESSION_NAME}" ] && [ "${S}" == "stuck" ] && case "${W}" in "a menu is open"*|"context at"*) QUIET=1 ;; esac
	if [ "${VERDICT[${N}]}" != "${KEY}" ]; then
		case "${S}" in
			stuck|down) [ -n "${QUIET}" ] || notify "${N} is ${S}: ${W}" ;;
			live) [ -n "${VERDICT[${N}]}" ] && [ "${VERDICT[${N}]%%:*}" != "live" ] && [ "${VERDICT[${N}]%%:*}" != "starting" ] \
				&& [ "${VERDICT[${N}]%%:*}" != "waiting" ] && [ -z "${VQUIET[${N}]}" ] && notify "${N} is live again" ;;
		esac
		VQUIET[${N}]=${QUIET}
		VERDICT[${N}]=${KEY}
	fi
	WHYS[${N}]=${W}
	ACTION[${N}]=${A}
}

# check_pane <name> <role> - the fleet check on a live session: the stuck verdicts, and /compact once per high-context
# spell for a spoke at an idle prompt; sets CP_STATE, CP_WHY and CP_ACTION (run in this shell, so COMPACTED keeps)
check_pane()
{
	N=$1; R=$2
	CP_ACTION=""
	IFS=$'\x1f' read -r FV FWHY FCTX FIDLE <<< "$("${FLEET_CHECK}" "${N}" 9>&- | python3 -I -c 'import json, sys
v = json.load(sys.stdin)
print(v["verdict"], v["why"] or "", v["ctx"] if v["ctx"] is not None else "", "true" if v["idle_prompt"] else "false", sep="\x1f")' 2>/dev/null)"
	# a reading under 80% ends the high-context spell: the next one may get its /compact
	[ -n "${FCTX}" ] && [ "${FCTX}" -lt 80 ] && COMPACTED[${N}]=""
	case "${FV}" in
		menu)
			CP_STATE=stuck; CP_WHY="a menu is open: ${FWHY}" ;;
		error)
			CP_STATE=stuck; CP_WHY="${FWHY}" ;;
		context)
			CP_STATE=stuck
			if [ "${R}" == "spoke" ] && [ -z "${COMPACTED[${N}]}" ]; then
				# recorded only when fleet-check.sh sent it: a refused send is tried again at the next pass
				if OUT=$("${FLEET_CHECK}" compact "${N}" 9>&-); then
					COMPACTED[${N}]=$(utc)
					"${SPOKE}" state "${N}" "compact_sent_at=${COMPACTED[${N}]}" > /dev/null
					CP_WHY="context at ${FCTX}%; /compact sent"
					CP_ACTION="/compact"
				else
					CP_WHY="context at ${FCTX}%; /compact not sent"
				fi
				say "${N}: ${OUT}"
			elif [ -n "${COMPACTED[${N}]}" ]; then
				CP_WHY="context at ${FCTX}% after the /compact at ${COMPACTED[${N}]}; left for a person"
			else
				CP_WHY="context at ${FCTX}% (the hub's pane is the person's: reported, never typed into)"
			fi
			;;
		gone|"")
			CP_STATE=down; CP_WHY="its session ended during the check" ;;
		*)
			CP_STATE=live; CP_WHY="${FV}${FCTX:+, ctx ${FCTX}%}" ;;
	esac
}

health()
{
	# the memory API and the session-memory worker, each only when its UI is on: "<name> <state> <detail>" lines
	if [ "${UI_HINDSIGHT:-true}" == "true" ]; then
		C=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${UI_PORT_HINDSIGHT_API:-8888}/health" 2>/dev/null)
		if [ "${C}" == "200" ]; then echo "memory_api up -"; else echo "memory_api down the memory API does not answer /health (HTTP ${C:-none})"; fi
	fi
	if [ "${UI_CLAUDE_MEM:-true}" == "true" ]; then
		Q=$(curl -s --noproxy '*' --max-time 3 "http://127.0.0.1:${UI_PORT_CLAUDE_MEM:-37700}/api/processing-status" 2>/dev/null \
			| python3 -I -c 'import json, sys; q = json.load(sys.stdin).get("queueDepth"); print(int(q))' 2>/dev/null)
		if [ -z "${Q}" ]; then echo "memory_worker down the session-memory worker does not answer /api/processing-status"
		elif [ "${Q}" -ge "${SUPERVISOR_MEMORY_QUEUE_WARN}" ]; then echo "memory_worker deep the session-memory queue is ${Q} deep (warning at ${SUPERVISOR_MEMORY_QUEUE_WARN})"
		else echo "memory_worker up queue ${Q}"; fi
	fi
}

# deck_keep - the Loop Deck's server, the one UI this loop starts again (header, 4). Sets DECK_HEALTH, the pass's health
# line for it - "loop_deck <state> <detail>": up, restarted, backoff while its backoff runs, stuck, or off without its
# pidfile - or nothing while UI_START or UI_LOOP_DECK is off
DECK_KEY="ui:loop-deck"
DECK_COOLDOWN=${SUPERVISOR_DECK_COOLDOWN:-60}
case "${DECK_COOLDOWN}" in ''|*[!0-9]*) DECK_COOLDOWN=60 ;; esac
deck_keep()
{
	DECK_HEALTH=""
	{ [ "${UI_START:-true}" == "true" ] && [ "${UI_LOOP_DECK:-true}" == "true" ]; } || return 0
	local F K=${DECK_KEY} P OUT
	F=${UI_DIR:-/wd/ui}/loop-deck.pid
	if [ ! -f "${F}" ]; then
		UP_SINCE[${K}]=""
		DECK_HEALTH="loop_deck off its server is not started (no ${F}: never started, or stopped with ui-stop.sh)"
		return 0
	fi
	P=$(cat "${F}" 2>/dev/null)
	# 2>/dev/null before the < : a pid that is gone fails the redirection itself, which reports before a later 2>
	if [ -n "${P}" ] && tr '\0' ' ' 2>/dev/null < "/proc/${P}/cmdline" | grep -q deck-server.py; then
		[ -n "${UP_SINCE[${K}]}" ] || UP_SINCE[${K}]=$(now)
		if [ "${RESTARTS[${K}]:-0}" -gt 0 ] && [ $(( $(now) - UP_SINCE[${K}] )) -ge "${SUPERVISOR_HEALTHY_SECS}" ]; then
			RESTARTS[${K}]=0
			restart_log loop-deck "up ${SUPERVISOR_HEALTHY_SECS}s: the restart count is back to 0"
		fi
		DECK_HEALTH="loop_deck up pid ${P}"
		return 0
	fi
	UP_SINCE[${K}]=""
	[ -n "${CAPPED[${K}]}" ] && { DECK_HEALTH="loop_deck stuck ${CAPPED[${K}]}"; return 0; }
	if [ "$(now)" -lt "${NEXT_AT[${K}]:-0}" ]; then
		# backoff, not down: the pass's health notices tell the hub about a service that is down, and this one told it
		# already, with its restart notice
		DECK_HEALTH="loop_deck backoff the Loop Deck's server is gone; the next start after its backoff"
		return 0
	fi
	# a stop that began since the pidfile was read (ui-stop.sh removes the pidfile first) is a stop, not a death
	[ -f "${F}" ] || { DECK_HEALTH="loop_deck off its server was stopped (no ${F})"; return 0; }
	RESTARTS[${K}]=$(( ${RESTARTS[${K}]:-0} + 1 ))
	if [ "${RESTARTS[${K}]}" -gt "${SUPERVISOR_RESTART_CAP}" ]; then
		CAPPED[${K}]="it did not stay up ${SUPERVISOR_HEALTHY_SECS}s through ${SUPERVISOR_RESTART_CAP} restarts; the last start said: ${LAST_START[${K}]}"
		RESTARTS[${K}]=${SUPERVISOR_RESTART_CAP}
		restart_log loop-deck "stuck: ${CAPPED[${K}]}; left alone until the supervisor starts again"
		notify "the Loop Deck's server is stuck: ${CAPPED[${K}]}"
		DECK_HEALTH="loop_deck stuck ${CAPPED[${K}]}"
		return 0
	fi
	# fd 9 closed: the server must never hold this loop's lock
	OUT=$("${AGENT_DIR}/loop-deck-start.sh" 2>&1 9>&-)
	SRC=$?
	LAST_START[${K}]=$(echo "${OUT}" | tail -1)
	restart_log loop-deck "restart ${RESTARTS[${K}]}/${SUPERVISOR_RESTART_CAP} (its server was gone): ${LAST_START[${K}]}"
	if [ "${SRC}" == "0" ]; then
		notify "the Loop Deck's server was gone and was started again (restart ${RESTARTS[${K}]}/${SUPERVISOR_RESTART_CAP})"
	else
		notify "the Loop Deck's server was gone, and restart ${RESTARTS[${K}]}/${SUPERVISOR_RESTART_CAP} did not start it: ${LAST_START[${K}]}"
	fi
	NEXT_AT[${K}]=$(( $(now) + DECK_COOLDOWN * (1 << (RESTARTS[${K}] - 1)) ))
	DECK_HEALTH="loop_deck restarted restart ${RESTARTS[${K}]}/${SUPERVISOR_RESTART_CAP}: ${LAST_START[${K}]}"
	[ "${SRC}" == "0" ] || DECK_HEALTH="loop_deck backoff restart ${RESTARTS[${K}]}/${SUPERVISOR_RESTART_CAP} did not start it: ${LAST_START[${K}]}"
}

write_status()
{
	# ${STATUS} - every session's state for the home tiles (served at /__spokes); ${PASSES} - one line per pass
	LIST=""
	while read -r N R E _; do
		[ "${R}" == "hub" ] || [ "${R}" == "spoke" ] || continue
		LIST+="${N}"$'\t'"${R}"$'\t'"${E}"$'\t'"${VERDICT[${N}]%%:*}"$'\t'"${WHYS[${N}]}"$'\t'"${ACTION[${N}]}"$'\n'
	done <<< "${TABLE}"
	SUP_LIST="${LIST}" SUP_HEALTH="$1" SUP_PASS=${PASS} SUP_PID=$$ SUPERVISOR_INTERVAL=${SUPERVISOR_INTERVAL} SUPERVISOR_RESTART_CAP=${SUPERVISOR_RESTART_CAP} \
		SUP_SELF=${SELF} python3 -I - "${STATUS}" "${PASSES}" << 'PY'
import fcntl, json, os, sys
from datetime import datetime, timezone
status, passes = sys.argv[1], sys.argv[2]


def own_state(path, word):
    # a session's own state.json carries this pass's state word, the one status.json gives it: a read-modify-write
    # under the lock spoke.sh state takes, so a start or a cycle recorded beside this pass is never lost
    try:
        with open(path + ".lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            cur = json.load(open(path))
            if not isinstance(cur, dict) or cur.get("state") == word:
                return
            cur["state"] = word
            with open(path + ".tmp", "w") as f:
                json.dump(cur, f, indent=1, sort_keys=True)
                f.write("\n")
            os.replace(path + ".tmp", path)
    except (OSError, ValueError):
        pass
sup_dir, proj_root = os.environ["SUPERVISOR_DIR"], os.environ.get("MAILBOX_PROJECTION_ROOT", "/wd/mailbox")
registry = os.environ.get("SPOKES_REGISTRY", "/agent/spokes/registry.json")
entries = {e.get("session_name"): e for e in json.load(open(registry)).get("sessions", []) if isinstance(e, dict)}
# the last message to or from each session: the mailbox log is read from where the last pass stopped, kept in
# last-messages.json with the log's inode and first bytes; a log that is new, shorter or rewritten is read from its start,
# and a line still being written waits for the next pass
log_path, idx_path = os.path.join(proj_root, "log.jsonl"), os.path.join(sup_dir, "last-messages.json")
last = {}
try:
    st = os.stat(log_path)
    with open(log_path, "rb") as f:
        head = f.read(256).hex()
        try:
            idx = json.load(open(idx_path))
        except (OSError, ValueError):
            idx = {}
        off = idx.get("offset") if isinstance(idx, dict) else None
        if isinstance(off, int) and 0 <= off <= st.st_size and idx.get("inode") == st.st_ino and isinstance(idx.get("last"), dict) \
                and head.startswith(idx.get("head") or "-") and len(idx.get("head") or "") == min(512, 2 * off):
            last = idx["last"]
        else:
            off = 0
        f.seek(off)
        data = f.read()
    end = data.rfind(b"\n") + 1
    for line in data[:end].splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("event") != "message.accepted":
            continue
        env = (e.get("details") or {}).get("env") or {}
        for who in (env.get("from"), env.get("to")):
            if isinstance(who, str):
                last[who] = {k: env.get(k) for k in ("id", "ts", "from", "to", "kind", "reply_to")}
                last[who]["text"] = " ".join(str(env.get("text", "")).split())[:160]
    off += end
    tmp = idx_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"inode": st.st_ino, "offset": off, "head": head[:min(512, 2 * off)], "last": last}, f, sort_keys=True)
    os.replace(tmp, idx_path)
except OSError:
    pass
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
sessions, brief = {}, {}
for row in os.environ["SUP_LIST"].splitlines():
    name, role, enabled, state, why, action = (row.split("\t") + [""] * 6)[:6]
    e = entries.get(name, {})
    try:
        st = json.load(open(os.path.join(sup_dir, name, "state.json")))
    except (OSError, ValueError):
        st = {}
    if enabled != "true":
        state, why = "off", f"set {e.get('flag')}=true in .env.local to run it"
    charter = e.get("charter") or ""
    sessions[name] = {"role": role, "flag": e.get("flag"), "enabled": enabled == "true", "state": state or "starting",
                      "why": why or ("the supervisor has not looked yet" if enabled == "true" else ""), "action": action or None,
                      "title": e.get("title"), "cost": e.get("cost"), "writes": e.get("writes") or [], "cadence": e.get("cadence_sec"),
                      "charter": charter if os.path.isfile(charter) else None,
                      **{k: st.get(k) for k in ("started_at", "last_cycle", "last_cycle_rc", "restarts", "generation", "compact_sent_at")},
                      "last_message": last.get(name)}
    if sessions[name]["state"] == "waiting":
        # what it waits for and how to give it: the entry's requires that this environment does not set
        req = [x for x in (e.get("requires") or []) if isinstance(x, str)]
        miss = [x for x in req if not os.environ.get(x)] or req
        sessions[name]["waiting_for"] = e.get("requires_what") or "/".join(miss)
        sessions[name]["how"] = "set " + " and ".join(miss) + " in .env.local, then ./stop.sh && ./run.sh"
    if enabled == "true":
        brief[name] = {"state": sessions[name]["state"], "why": why or None, "action": action or None}
        # a started session's own state.json (its start wrote one) reads the same word as its row here
        if state and st and st.get("state") != state:
            own_state(os.path.join(sup_dir, name, "state.json"), state)
health = {}
for l in os.environ["SUP_HEALTH"].splitlines():
    k, s, d = (l.split(" ", 2) + ["", ""])[:3]
    health[k] = {"state": s, "detail": None if d == "-" else d}
doc = {"updated_at": now, "pass": int(os.environ["SUP_PASS"]), "pid": int(os.environ["SUP_PID"]),
       "interval": int(os.environ["SUPERVISOR_INTERVAL"]), "cap": int(os.environ["SUPERVISOR_RESTART_CAP"]),
       "supervisor": {"session": os.environ["SUP_SELF"], "last_message": last.get(os.environ["SUP_SELF"])},
       "sessions": sessions, "health": health}
tmp = status + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=1, sort_keys=True)
    f.write("\n")
os.replace(tmp, status)
rec = json.dumps({"ts": now, "pass": doc["pass"], "sessions": brief, "health": {k: v["state"] for k, v in health.items()}}, sort_keys=True)
with open(passes, "a") as f:
    f.write(rec + "\n")
# the pass on the tmux-agent dashboard: the supervisor session's task line, printed for the loop
on = {n: s for n, s in sessions.items() if s["enabled"]}
bad = [n + (" waiting for " + s["waiting_for"] if s["state"] == "waiting" else " " + s["state"]) for n, s in on.items() if s["state"] != "live"]
print("last pass " + now + ": " + str(len(on) - len(bad)) + " of " + str(len(on)) + " live" + (" - " + ", ".join(bad) if bad else ""))
# the last 1000 passes are kept
try:
    lines = open(passes).read().splitlines()
    if len(lines) > 2000:
        with open(passes + ".tmp", "w") as f:
            f.write("\n".join(lines[-1000:]) + "\n")
        os.replace(passes + ".tmp", passes)
except OSError:
    pass
PY
}

trap 'echo "$(utc) supervisor: terminated"; exit 0' TERM INT

PASS=0
LOOP_START=$(now)
CENSUS_FIRST=--first
CENSUS_SIG=""
CENSUS_ERR=""
LEDGER_ERR=""
while [ ! -f "${STOP_FLAG}" ]; do
	PASS=$((PASS + 1))
	# the entries on fd 3: nothing the pass runs can read them from its stdin
	TABLE=$("${SPOKE}" table)
	# the session ledger's census (step 7): the sessions on the server against their latest lines; its tool runs only when a
	# session came, went or changed its pane since the last census it recorded (and at the loop's first pass, which also
	# records the stops nobody saw while no supervisor ran)
	# A read of the server that fails is not an empty server: that pass writes no line and closes nothing, and the close's
	# count of passes starts again
	if ! CENSUS=$(census_list); then
		[ -n "${CENSUS_ERR}" ] || say "ledger: the tmux server could not be read ($(tail -1 "${SUPERVISOR_DIR%/}/census.err" 2> /dev/null | cut -c1-200)); no census and no close until it can"
		CENSUS_ERR=1 CENSUS=""
		unset EXITED_AT
		declare -A EXITED_AT=()
	else
		[ -n "${CENSUS_ERR}" ] && say "ledger: the tmux server can be read again"
		CENSUS_ERR=""
		SIG=$(awk '{ print $1, $2, $3 }' <<< "${CENSUS}" | sort)
		if [ -n "${CENSUS_FIRST}" ] || [ "${SIG}" != "${CENSUS_SIG}" ]; then
			if OUT=$(python3 -I "${LEDGER_TOOL}" census ${CENSUS_FIRST} <<< "${SIG}" 2>&1 9>&-); then
				CENSUS_SIG=${SIG} CENSUS_FIRST="" LEDGER_ERR=""
			elif [ -z "${LEDGER_ERR}" ]; then
				LEDGER_ERR=1
				say "ledger: the census was not recorded (tried again every pass): ${OUT}"
			fi
		fi
	fi
	exec 3< <(supervised)
	while read -r N R REQ WHAT HOOK <&3; do
		[ -n "${HOOK}" ] || HOOK=claude
		if [ "${R}" == "hub" ]; then
			if ! tmux has-session -t "=${N}" 2>/dev/null; then
				COOL=$("${SPOKE}" entry "${N}" cooldown_sec 2>/dev/null)
				if [ "$(now)" -ge "${NEXT_AT[${N}]:-0}" ]; then
					NEXT_AT[${N}]=$(( $(now) + ${COOL:-60} ))
					OUT=$("${AGENT_DIR}/tmux-session-start.sh" 2>&1 9>&-)
					restart_log "${N}" "the hub's session was gone: ${OUT}"
					# its start's line in the session ledger (the hub's start writes none; its pane keeps a shell, so it is read)
					python3 -I "${LEDGER_TOOL}" record start "${N}" --reason "supervisor: the hub's session was gone; started again" > /dev/null 2>&1 9>&-
					notify "${N} was gone and was started again"
					VERDICT[${N}]=starting
					verdict "${N}" starting "its session was gone; started again" "start"
				else
					verdict "${N}" down "its session is gone; the next start after its cooldown"
				fi
			elif ! agent_alive "${N}" "${HOOK}"; then
				CREATED=$(tmux list-sessions -F '#{session_name} #{session_created}' 2>/dev/null | awk -v s="${N}" '$1 == s { print $2 }')
				if [ -n "${CREATED}" ] && [ $(( $(now) - CREATED )) -lt "${SUPERVISOR_START_GRACE}" ]; then
					verdict "${N}" starting "its pane runs no ${HOOK} yet ($(( $(now) - CREATED )) s after its start)"
				else
					verdict "${N}" down "no ${HOOK} process in its pane (a shell); left for the person"
				fi
			else
				check_pane "${N}" hub
				verdict "${N}" "${CP_STATE}" "${CP_WHY}" "${CP_ACTION}"
			fi
			continue
		fi
		# a spoke
		[ -n "${CAPPED[${N}]}" ] && { verdict "${N}" stuck "${CAPPED[${N}]}"; continue; }
		if tmux has-session -t "=${N}" 2>/dev/null; then
			[ -n "${UP_SINCE[${N}]}" ] || UP_SINCE[${N}]=$(now)
			if [ -z "${STARTED[${N}]}" ]; then
				# a session this loop did not start (the loop itself was started again): adopted, any old verdict cleared
				STARTED[${N}]=$(now)
				RESTARTS[${N}]=0
				"${SPOKE}" state "${N}" restarts=0 stuck_reason= state=starting
			fi
			UP=$(( $(now) - UP_SINCE[${N}] ))
			if [ "${RESTARTS[${N}]:-0}" -gt 0 ] && [ "${UP}" -ge "${SUPERVISOR_HEALTHY_SECS}" ]; then
				RESTARTS[${N}]=0
				"${SPOKE}" state "${N}" restarts=0
				restart_log "${N}" "up ${SUPERVISOR_HEALTHY_SECS}s: the restart count is back to 0"
			fi
			if ! agent_alive "${N}" "${HOOK}"; then
				if [ "${UP}" -lt "${SUPERVISOR_START_GRACE}" ]; then
					verdict "${N}" starting "its pane runs no ${HOOK} yet (${UP} s after its start)"
				else
					verdict "${N}" down "no ${HOOK} process in its pane ${UP} s after its start"
				fi
				continue
			fi
			# settings its cycle needs and this environment does not set (the entry's requires): its session runs and
			# waits, no cycle runs and nothing restarts; with them set (the next start), it goes on as below
			MISS=""
			if [ "${REQ}" != "-" ]; then
				for V in ${REQ//,/ }; do [ -n "${!V}" ] || MISS+="${MISS:+/}${V}"; done
			fi
			if [ -n "${MISS}" ]; then
				check_pane "${N}" spoke
				if [ "${CP_STATE}" == "live" ]; then
					CP_STATE=waiting
					CP_WHY="waiting for ${MISS}"
					[ "${WHAT}" != "-" ] && CP_WHY="waiting for ${WHAT} (${MISS})"
				fi
				verdict "${N}" "${CP_STATE}" "${CP_WHY}" "${CP_ACTION}"
				continue
			fi
			CYC=$("${SPOKE}" entry "${N}" cycle 2>/dev/null)
			if [ -n "${CYC}" ] && ! cycle_running "${N}" && [ "$(now)" -ge "${NEXT_CYCLE[${N}]:-0}" ]; then
				run_cycle "${N}"
			fi
			check_pane "${N}" spoke
			if [ "${CP_STATE}" == "live" ] && [ -n "${CYC}" ]; then
				LAST=$("${SPOKE}" state "${N}" 2>/dev/null | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print("yes" if d.get("last_cycle") and d.get("last_cycle") >= (d.get("started_at") or "") else "")' 2>/dev/null)
				[ -n "${LAST}" ] || { CP_STATE=starting; CP_WHY="no cycle has completed since its start"; }
			fi
			verdict "${N}" "${CP_STATE}" "${CP_WHY}" "${CP_ACTION}"
			continue
		fi
		UP_SINCE[${N}]=""
		COMPACTED[${N}]=""
		if [ -z "${STARTED[${N}]}" ]; then
			# the loop's first start of this spoke (a container start): not a restart
			STARTED[${N}]=$(now)
			RESTARTS[${N}]=0
			"${SPOKE}" state "${N}" restarts=0 stuck_reason= state=starting
			start_session "${N}" "start"
			verdict "${N}" starting "started: ${LAST_START[${N}]}" "start"
			continue
		fi
		[ "$(now)" -lt "${NEXT_AT[${N}]:-0}" ] && { verdict "${N}" down "its session is gone; the next restart after its backoff"; continue; }
		R0=${RESTARTS[${N}]:-0}
		RESTARTS[${N}]=$((R0 + 1))
		if [ "${RESTARTS[${N}]}" -gt "${SUPERVISOR_RESTART_CAP}" ]; then
			REASON="it did not stay up ${SUPERVISOR_HEALTHY_SECS}s through ${SUPERVISOR_RESTART_CAP} restarts; the last start said: ${LAST_START[${N}]}"
			CAPPED[${N}]=${REASON}
			"${SPOKE}" state "${N}" state=stuck "stuck_reason=${REASON}" "restarts=${SUPERVISOR_RESTART_CAP}" "stuck_at=$(utc)"
			restart_log "${N}" "stuck: ${REASON}; left alone until the supervisor starts again"
			RESTARTS[${N}]=${SUPERVISOR_RESTART_CAP}
			verdict "${N}" stuck "${REASON}"
			continue
		fi
		start_session "${N}" "restart ${RESTARTS[${N}]}/${SUPERVISOR_RESTART_CAP} (the session was gone)"
		notify "${N} was gone and was started again (restart ${RESTARTS[${N}]}/${SUPERVISOR_RESTART_CAP})"
		"${SPOKE}" state "${N}" "restarts=${RESTARTS[${N}]}"
		COOL=$("${SPOKE}" entry "${N}" cooldown_sec 2>/dev/null)
		NEXT_AT[${N}]=$(( $(now) + ${COOL:-60} * (1 << (RESTARTS[${N}] - 1)) ))
		verdict "${N}" starting "restarted ${RESTARTS[${N}]}/${SUPERVISOR_RESTART_CAP}: ${LAST_START[${N}]}" "restart"
	done
	exec 3<&-
	# the bounded close (step 8): a session the registry does not list whose every pane's process had exited at this
	# pass's census and at the last one, the same session and pane, and still when read again now, has its panes' output
	# copied to a file, then is closed with a closed-exited ledger line naming the file and one notice to the hub; a pane
	# whose process runs is never touched, and a session whose read again fails, whose copy finds a pane running again or
	# whose output cannot be copied stays open
	if [ "${SUPERVISOR_CLOSE_EXITED}" == "true" ] && [ -z "${CENSUS_ERR}" ]; then
		REG=" $(awk '{ printf "%s ", $1 }' <<< "${TABLE}")"
		unset EXITED_NOW
		declare -A EXITED_NOW=()
		while read -r S P C X ST; do
			[ "${X}" == "1" ] && [ "${REG/ ${S} /}" == "${REG}" ] || continue
			EXITED_NOW[${S}]=1
			if [ "${EXITED_AT[${S}]%% *}" != "${P}:${C}" ]; then
				EXITED_AT[${S}]="${P}:${C} ${PASS}"
				continue
			fi
			FIRST_PASS=${EXITED_AT[${S}]#* }
			unset "EXITED_AT[${S}]"
			# read again now: a read that fails closes nothing, nor does a pane whose process runs
			PANES=$(timeout 10 tmux list-panes -s -t "=${S}:" -F '#{pane_dead}' 2>/dev/null) || continue
			grep -qvx 1 <<< "${PANES}" && continue
			OUTF="${SUPERVISOR_DIR%/}/closed/${S}.${C}.txt"
			keep_output "${S}" "${OUTF}"
			KEPT=$?
			# 3: a pane's process runs again, started since that read: no copy, no close
			[ "${KEPT}" -eq 3 ] && continue
			if [ "${KEPT}" -ne 0 ]; then
				[ -n "${KEEP_ERR[${S}]}" ] || say "close: the output of ${S} could not be kept in ${OUTF}; the session stays open"
				KEEP_ERR[${S}]=1
				continue
			fi
			unset "KEEP_ERR[${S}]"
			tmux kill-session -t "=${S}" 2>/dev/null 9>&- || continue
			python3 -I "${LEDGER_TOOL}" record closed-exited "${S}" --output "${OUTF}" --reason "every pane's process had exited (exit status ${ST}) at passes ${FIRST_PASS} and ${PASS}; the supervisor kept its panes' output in ${OUTF} and closed the session" > /dev/null 2>&1 9>&- \
				|| say "ledger: the close of ${S} was not recorded"
			notify "closed the scratch session ${S}: every pane's process had exited (exit status ${ST}) at two passes in a row; its panes' output is kept in ${OUTF}; supervisor.sh resume ${S} recreates it"
		done <<< "${CENSUS}"
		for S in "${!EXITED_AT[@]}"; do [ -n "${EXITED_NOW[${S}]}" ] || unset "EXITED_AT[${S}]"; done
	fi
	deck_keep
	H=$(health)
	[ -n "${DECK_HEALTH}" ] && { [ -n "${H}" ] && H+=$'\n'; H+=${DECK_HEALTH}; }
	# the memory services start with the container, beside this loop: their state is recorded from the first pass, and
	# reported only after SUPERVISOR_START_GRACE seconds, so a container start is not a pair of "down" and "back" notices
	if [ $(( $(now) - LOOP_START )) -ge "${SUPERVISOR_START_GRACE}" ]; then
		while read -r K S DETAIL; do
			[ -n "${K}" ] || continue
			if [ "${HEALTH_SEEN[${K}]}" != "${S}" ]; then
				case "${S}" in
					down|deep) notify "${DETAIL}" ;;
					up)
						case "${K}:${HEALTH_SEEN[${K}]}" in
							memory_api:?*) notify "the memory API answers /health again" ;;
							memory_worker:deep) notify "the session-memory queue is under the warning again (${DETAIL})" ;;
							memory_worker:?*) notify "the session-memory worker answers again (${DETAIL})" ;;
						esac
						;;
				esac
				HEALTH_SEEN[${K}]=${S}
			fi
		done <<< "${H}"
	fi
	# the pass on the tmux-agent dashboard: the supervisor session's task line, from the status write
	SUMMARY=$(write_status "${H}")
	if [ -n "${SUMMARY}" ] && tmux has-session -t "=${SELF}" 2>/dev/null; then
		tmux set-option -t "=${SELF}:" @agent_task "${SUMMARY}" 2>/dev/null 9>&-
	fi
	sleep "${SUPERVISOR_INTERVAL}" 9>&- &
	wait $!
done
echo "$(utc) supervisor: stop flag ${STOP_FLAG} - stopping (the sessions keep running)"
