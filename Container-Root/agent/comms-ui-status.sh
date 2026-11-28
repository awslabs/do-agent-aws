#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Comms UI - show the honest state of the communication-engine dashboard.
#
# Prints whether the dashboard process is alive AND whether it actually answers HTTP on its
# port - a pid without an answering port is reported as such, never as up. A pid only counts
# when its command line matches the dashboard it claims to be (pidfiles survive container
# recreation on the /wd volume while pids are namespace-local, so a stale pidfile can point
# at an unrelated recycled pid). Also reports the on-disk engine state: settings present,
# journal present, and message/journal/cursor counts read from the sqlite files in read-only
# mode - the databases are the truth, not the process. Never prints a token (it never reads
# auth values at all; a generated settings.json holds env: references only). Exit code is 0
# when the dashboard answers or is deliberately off, 1 when it is enabled or started but not
# answering, so the script doubles as a probe.

COMMS_HOME=${COMMS_HOME:-/opt/comms}
COMMS_DIR=${COMMS_DIR:-/wd/comms}
COMMS_UI_PORT=${COMMS_UI_PORT:-8502}
COMMS_UI_ENABLED=${COMMS_UI_ENABLED:-false}
# With a base path set (the home proxy carries the dashboard at /comms/) the app answers
# under that path, not at / - probe where it actually serves
COMMS_UI_BASE_PATH=${COMMS_UI_BASE_PATH:-}
COMMS_UI_PROBE_PATH=/
[ -n "${COMMS_UI_BASE_PATH}" ] && COMMS_UI_PROBE_PATH="/${COMMS_UI_BASE_PATH}/"
COMMS_SETTINGS=${COMMS_SETTINGS:-${COMMS_DIR}/settings.json}
PID_FILE=${COMMS_DIR}/ui.pid

pid_is_comms()
{
	PID=$1
	[ -n "${PID}" ] && [ -d "/proc/${PID}" ] && tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null | grep -q "scripts/dashboard.py"
}

echo "comms-ui: COMMS_UI_ENABLED=${COMMS_UI_ENABLED} port=${COMMS_UI_PORT} settings=${COMMS_SETTINGS}"

PID=""
[ -f "${PID_FILE}" ] && PID=$(cat "${PID_FILE}")
ALIVE=false
pid_is_comms "${PID}" && ALIVE=true
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${COMMS_UI_PORT}${COMMS_UI_PROBE_PATH}" 2>/dev/null)

RC=0
if [ "${ALIVE}" == "true" ] && [ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null; then
	echo "comms-ui: UP pid=${PID} http=${HTTP} port=${COMMS_UI_PORT}"
elif [ "${ALIVE}" == "true" ]; then
	echo "comms-ui: STARTING-OR-UNHEALTHY pid=${PID} http=${HTTP:-000} port=${COMMS_UI_PORT} (process alive, port not answering)"
	RC=1
elif [ "${COMMS_UI_ENABLED}" == "true" ]; then
	echo "comms-ui: DOWN port=${COMMS_UI_PORT}"
	RC=1
else
	echo "comms-ui: DISABLED (not running; set COMMS_UI_ENABLED=true in .env or run /agent/comms-ui-start.sh)"
fi

if [ ! -f "${COMMS_SETTINGS}" ]; then
	echo "comms-ui: settings absent (generated on first start)"
	exit ${RC}
fi

# On-disk engine state, resolved by the engine's own config loader and read mode=ro
COMMS_HOME="${COMMS_HOME}" COMMS_SETTINGS="${COMMS_SETTINGS}" python3 - << 'EOF' 2>/dev/null || echo "comms-ui: engine state unreadable (engine missing or settings refused)"
import os, sqlite3, sys
sys.path.insert(0, os.environ["COMMS_HOME"])
from core.config import load
cfg = load(os.environ["COMMS_SETTINGS"])

def count(path, table):
    if not path.is_file():
        return None
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
    finally:
        conn.close()

journal = count(cfg.journal_path, "journal")
if journal is None:
    print(f"comms-ui: journal absent ({cfg.journal_path})")
else:
    print(f"comms-ui: journal present ({cfg.journal_path}) entries={journal}")
messages = count(cfg.store_path, "messages")
cursors = count(cfg.store_path, "cursors")
if messages is None:
    print(f"comms-ui: store absent ({cfg.store_path})")
else:
    print(f"comms-ui: store present ({cfg.store_path}) messages={messages} cursors={cursors}")
EOF

exit ${RC}
