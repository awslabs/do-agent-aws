#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The Loop Deck's server: the vendored release (/opt/loop-deck, VENDORED.md) in harness mode over the data directory
# /agent/loop-deck-adapter.py writes (/wd/loop-deck), bound to 127.0.0.1 and routed as loop-deck.localhost by the home
# proxy (docs/manual/ui.md "Harness UIs"). Actions stay off: LOOP_DECK_ACT_TOKEN is never passed (every POST /act answers 403,
# audited). ui-start.sh runs this at every UI start, after the adapter; the supervisor runs it again when the server's
# process is gone (/agent/supervisor.sh, "the Loop Deck's server"). A server whose pid is alive is left untouched, so it is
# safe to re-run. Starts run one at a time (the lock ${UI_DIR}/loop-deck.start.lock). Its output goes to
# ${UI_DIR}/loop-deck.log and its pid to ${UI_DIR}/loop-deck.pid, which ui-status.sh and ui-stop.sh read.
#
# Settings (environment): UI_DIR (/wd/ui), UI_PORT_LOOP_DECK (8091), LOOP_DECK_DIR (/opt/loop-deck), LOOP_DECK_DATA_DIR
# (/wd/loop-deck). Exit status: 0 when the server runs, or was started and listens on its port (or still runs after
# 5 s, which the line says); 1 when there is no vendored Deck to start, another start held the lock for 30 s, or the
# server exited at once (the line says so, with the last line of its log).

UI_DIR=${UI_DIR:-/wd/ui}
UI_PORT_LOOP_DECK=${UI_PORT_LOOP_DECK:-8091}
LOOP_DECK_DIR=${LOOP_DECK_DIR:-/opt/loop-deck}
LOOP_DECK_DATA_DIR=${LOOP_DECK_DATA_DIR:-/wd/loop-deck}
PID_FILE=${UI_DIR:?}/loop-deck.pid

if [ ! -f "${LOOP_DECK_DIR}/deck-server.py" ]; then
	echo "loop-deck: not started - no vendored Deck at ${LOOP_DECK_DIR}/deck-server.py (the image ships it; tools/vendor-loop-deck.sh)"
	exit 1
fi
mkdir -p "${UI_DIR}" "${LOOP_DECK_DATA_DIR}/out" || exit 1
# one start at a time: ui-start.sh and the supervisor's restart can run this together, and two that both found no live
# server started two, the pidfile naming either. The lock is held across the check, the start and the wait below (the
# server does not inherit it)
exec 7> "${UI_DIR}/loop-deck.start.lock"
flock -w 30 7 || { echo "loop-deck: not started - another start held ${UI_DIR}/loop-deck.start.lock for 30 s"; exit 1; }
# a pid counts only while its command line is the Deck's server: the pidfile outlives the container on /wd, where a
# recycled pid can be any process
if [ -f "${PID_FILE}" ]; then
	PID=$(cat "${PID_FILE}")
	# 2>/dev/null before the < : a pid that is gone fails the redirection itself, which reports before a later 2>
	if [ -n "${PID}" ] && tr '\0' ' ' 2>/dev/null < "/proc/${PID}/cmdline" | grep -q deck-server.py; then
		echo "loop-deck: already running (pid ${PID})"
		exit 0
	fi
	rm -f "${PID_FILE:?}"
fi
# the & applies to the setsid command alone, so $! is the server itself; setsid detaches it into its own session and
# process group for ui-stop.sh
(
	cd "${LOOP_DECK_DATA_DIR}" || exit 1
	setsid nohup env -u LOOP_DECK_ACT_TOKEN PYTHONDONTWRITEBYTECODE=1 LOOP_DECK_MODE=harness LOOP_DECK_DATA_DIR="${LOOP_DECK_DATA_DIR}" \
		python3 -I "${LOOP_DECK_DIR}/deck-server.py" --port "${UI_PORT_LOOP_DECK}" --root "${LOOP_DECK_DATA_DIR}/out" >> "${UI_DIR}/loop-deck.log" 2>&1 7>&- &
	# whole or not at all: a reader never sees a pidfile cut short
	echo $! > "${PID_FILE:?}.tmp" && mv -f "${PID_FILE:?}.tmp" "${PID_FILE:?}"
)
PID=$(cat "${PID_FILE}")
# a server that cannot run (its port taken, a broken out/) dies within seconds of its start: wait until this pid
# listens on its port or is gone (at most 5 s), and say which - a dead one with its log's last line. The pidfile stays
# either way, so the supervisor starts a dead one again on its backoff. Gone is a pid with no /proc entry, or one that
# has exited and is not reaped yet (state Z or X in /proc/<pid>/stat). Not an empty command line: a live process reads
# an empty one while it is inside execve, and the fork passes through four on its way to the server (setsid, nohup,
# env, python3). Until its exec the fork still has this script's command line, which does not name the server: that
# is a start still under way, not a server that is gone
gone() { local S; read -r S 2>/dev/null < "/proc/${PID}/stat" || return 0; S=${S##*) }; [ "${S%% *}" == "Z" ] || [ "${S%% *}" == "X" ]; }
listening() { ss -ltnpH "sport = :${UI_PORT_LOOP_DECK}" 2>/dev/null | grep -q "pid=${PID},"; }
for _ in $(seq 1 50); do
	gone && break
	listening && break
	sleep 0.1
done
if gone; then
	echo "loop-deck: exited at once (pid ${PID}): $(tail -1 "${UI_DIR}/loop-deck.log" 2>/dev/null) - log ${UI_DIR}/loop-deck.log"
	exit 1
fi
listening || { echo "loop-deck: started (pid ${PID}, log ${UI_DIR}/loop-deck.log) - not listening on ${UI_PORT_LOOP_DECK} after 5 s"; exit 0; }
echo "loop-deck: started (pid ${PID}, log ${UI_DIR}/loop-deck.log)"
