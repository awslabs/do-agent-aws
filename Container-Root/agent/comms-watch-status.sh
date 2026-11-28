#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Comms real-channel watcher - honest status. Reports RUNNING only when the pidfile's pid
# is alive AND its command line is the scheduler (the comms-ui-status.sh reasoning: a
# pidfile survives container recreation, a pid does not), then shows the evidence an
# operator needs to SEE polling happen: the last cycle line from the log, and the
# journal/message row counts read from the engine's own databases (sqlite mode=ro, the
# same read-only discipline as the dashboard). Exit 0 when running, 1 when not.

COMMS_HOME=${COMMS_HOME:-/opt/comms}
COMMS_DIR=${COMMS_DIR:-/wd/comms}
COMMS_SETTINGS=${COMMS_SETTINGS:-${COMMS_DIR}/settings.json}
PID_FILE=${COMMS_DIR}/watch.pid

pid_is_watch()
{
	PID=$1
	[ -n "${PID}" ] && [ -d "/proc/${PID}" ] && tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null | grep -q "scripts/scheduler.py"
}

echo "Comms watcher status:"

RUNNING=false
if [ -f "${PID_FILE}" ] && pid_is_watch "$(cat ${PID_FILE})"; then
	RUNNING=true
	echo "  watcher:    RUNNING (pid $(cat ${PID_FILE}))"
else
	echo "  watcher:    not running (start with /agent/comms-watch-start.sh; gate COMMS_WATCH_ENABLED in .env)"
fi

echo "  gate:       COMMS_WATCH_ENABLED=${COMMS_WATCH_ENABLED:-unset} (startup.sh starts the watcher when true)"
echo "  settings:   ${COMMS_SETTINGS}$([ -f "${COMMS_SETTINGS}" ] || echo ' (MISSING)')"

if [ -f "${COMMS_DIR}/watch.log" ]; then
	LAST_CYCLE=$(grep "^cycle:" "${COMMS_DIR}/watch.log" | tail -1)
	echo "  last cycle: ${LAST_CYCLE:-none logged yet} (log ${COMMS_DIR}/watch.log)"
else
	echo "  last cycle: never ran (no ${COMMS_DIR}/watch.log)"
fi

# Row counts from the engine's own config resolution - a user-supplied settings.json with
# different db paths is honored, and both databases are opened read-only
if [ -f "${COMMS_SETTINGS}" ]; then
	COMMS_HOME="${COMMS_HOME}" COMMS_SETTINGS="${COMMS_SETTINGS}" python3 - << 'EOF' 2>/dev/null || echo "  journal:    unreadable (engine refused the settings, or dbs not created yet)"
import os, sqlite3, sys
sys.path.insert(0, os.environ["COMMS_HOME"])
from core.config import load
cfg = load(os.environ["COMMS_SETTINGS"])
for label, path in (("messages", cfg.store_path), ("journal", cfg.journal_path)):
    if not os.path.exists(path):
        print(f"  {label + ':':<11} no database yet ({path})")
        continue
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")]
        total = sum(conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
                    for t in tables)
        print(f"  {label + ':':<11} {total} row(s) in {len(tables)} table(s) ({path})")
    finally:
        conn.close()
EOF
fi

[ "${RUNNING}" = "true" ]
