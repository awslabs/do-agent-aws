#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the comms UI (/agent/comms-ui-*.sh) and its startup.sh gate.
# Fully OFFLINE: everything runs against the communication engine's credential-free fake
# adapter and its --seed-demo dry-run hook. No real Slack/Telegram/email call is made.
#
# Properties proven:
#   1.  all new/changed scripts parse (bash -n)
#   2.  the engine is installed at the EXACT pinned sha (setup/install-comms.sh contract)
#   3.  first start generates settings.json from the engine's example with ONLY the fake
#       adapter kept (an unresolved env: reference would make the engine refuse to start)
#   4.  the demo seed ran: journal and store exist with at least one journaled message
#   5.  the dashboard answers HTTP 200 on 127.0.0.1:${COMMS_UI_PORT}
#   6.  the listener is loopback-only - nothing on this port listens on 0.0.0.0
#   7.  a second start is a no-op (already running, no duplicate process)
#   8.  the engine's own unit-test suite is green
#   9.  stop by pidfile works: process gone, pidfile removed
#   10. stop -> rerun: journal rows and cursors SURVIVE and the seed does not re-run
#       (counts unchanged), and the dashboard answers again
#   11. gate off: with COMMS_UI_ENABLED=false startup.sh starts nothing - no listener,
#       no pidfile
# Uses test-local state directories (/tmp/comms-smoke*); does not disturb live state under /wd.

D=/tmp/comms-smoke
rm -rf "${D:?}" /tmp/comms-smoke-gateoff
mkdir -p ${D}

# Locate the scripts both in-container (/agent, /setup) and in a repo checkout (Container-Root/...)
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
SETUP_DIR="${BASE_DIR%/}/setup"

export COMMS_HOME=${COMMS_HOME:-/opt/comms}
export COMMS_DIR=${D}/state-dir
export COMMS_UI_PORT=8602
# This test exercises the comms UI itself, not the home-proxy routing (test9.sh does
# that): pin the base path empty so the dashboard answers at / regardless of the
# container's UI_HOME/COMMS_UI_BASE_PATH defaults.
export COMMS_UI_BASE_PATH=
export COMMS_UI_LISTEN_HOST=127.0.0.1
export COMMS_DEMO_SEED=true

fail()
{
	echo "Test6 FAILED: $1"
	COMMS_DIR=${COMMS_DIR} "${AGENT_DIR}/comms-ui-stop.sh" > /dev/null 2>&1
	exit 1
}

# --- 1. syntax ---
for S in "${AGENT_DIR}/comms-ui-start.sh" "${AGENT_DIR}/comms-ui-stop.sh" \
         "${AGENT_DIR}/comms-ui-status.sh" "${SETUP_DIR}/install-comms.sh" \
         "${BASE_DIR}/startup.sh"; do
	bash -n "${S}" || fail "bash -n ${S}"
done
echo "ok 1 - syntax"

# --- preflight: engine + python3 (installed by setup/install-comms.sh in the image) ---
if [ ! -f "${COMMS_HOME}/scripts/dashboard.py" ] || ! command -v python3 > /dev/null; then
	echo "Test6 skipped: communication engine not installed under ${COMMS_HOME} (run setup/install-comms.sh)"
	exit 0
fi

# --- 2. pinned sha ---
PINNED=$(grep -oE 'COMMS_ENGINE_SHA=[0-9a-f]{40}' "${SETUP_DIR}/install-comms.sh" | cut -d= -f2)
[ -n "${PINNED}" ] || fail "no 40-hex COMMS_ENGINE_SHA pin in install-comms.sh"
HEAD_SHA=$(git -C "${COMMS_HOME}" rev-parse HEAD 2>/dev/null)
[ "${HEAD_SHA}" == "${PINNED}" ] || fail "engine HEAD ${HEAD_SHA} != pinned ${PINNED}"
echo "ok 2 - engine pinned at ${PINNED}"

# --- 3. first start generates fake-only settings ---
"${AGENT_DIR}/comms-ui-start.sh" || fail "comms-ui-start.sh (first run)"
[ -f "${COMMS_DIR}/settings.json" ] || fail "settings.json not generated"
python3 - << 'EOF' || fail "generated settings.json is not fake-adapter-only"
import json, os
cfg = json.load(open(os.environ["COMMS_DIR"] + "/settings.json"))
adapters = [i.get("adapter") for i in cfg["instances"]]
assert adapters and set(adapters) == {"fake"}, adapters
EOF
echo "ok 3 - settings generated (fake adapter only)"

# --- 4. demo seed journaled ---
counts()
{
	python3 - << 'EOF'
import os, sqlite3, sys
sys.path.insert(0, os.environ["COMMS_HOME"])
from core.config import load
cfg = load(os.environ["COMMS_DIR"] + "/settings.json")
j = sqlite3.connect(f"file:{cfg.journal_path}?mode=ro", uri=True)
s = sqlite3.connect(f"file:{cfg.store_path}?mode=ro", uri=True)
print(j.execute("SELECT count(*) FROM journal").fetchone()[0],
      s.execute("SELECT count(*) FROM cursors").fetchone()[0])
EOF
}
COUNTS1=$(counts) || fail "journal/store unreadable after seed"
JOURNAL1=${COUNTS1% *}
[ "${JOURNAL1}" -ge 1 ] 2>/dev/null || fail "journal empty after demo seed (rows=${JOURNAL1})"
echo "ok 4 - demo seeded (journal=${JOURNAL1} cursors=${COUNTS1#* })"

# --- 5. dashboard answers on loopback ---
HTTP=000
for i in $(seq 1 45); do
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${COMMS_UI_PORT}/" 2>/dev/null)
	[ "${HTTP}" == "200" ] && break
	sleep 2
done
[ "${HTTP}" == "200" ] || { cat "${COMMS_DIR}/ui.log" 2>/dev/null | tail -20; fail "dashboard not answering 200 on 127.0.0.1:${COMMS_UI_PORT} (last=${HTTP})"; }
"${AGENT_DIR}/comms-ui-status.sh" | grep -q "comms-ui: UP" || fail "comms-ui-status.sh does not report UP"
echo "ok 5 - dashboard HTTP 200 on 127.0.0.1:${COMMS_UI_PORT}"

# --- 6. loopback only ---
python3 - << 'EOF' || fail "a non-loopback listener exists on the comms UI port"
import os
port = format(int(os.environ["COMMS_UI_PORT"]), '04X')
bad = [f[1] for ln in open('/proc/net/tcp') if len(f := ln.split()) > 3
       and f[3] == '0A' and f[1].endswith(':' + port) and f[1].split(':')[0] != '0100007F']
assert not bad, bad
EOF
echo "ok 6 - loopback-only listener"

# --- 7. idempotent start ---
"${AGENT_DIR}/comms-ui-start.sh" | grep -q "already running" || fail "second start did not report already running"
# count dashboard processes on OUR test port via /proc (pgrep/procps is not in the base
# image, and an unrelated live dashboard on another port must not be counted)
NPROC=$(python3 - << 'EOF'
import glob, os
port = os.environ["COMMS_UI_PORT"].encode()
n = 0
for p in glob.glob('/proc/[0-9]*/cmdline'):
    try:
        cmd = open(p, 'rb').read().split(b'\0')
    except OSError:
        continue
    if any(b'scripts/dashboard.py' in a for a in cmd) and port in cmd:
        n += 1
print(n)
EOF
)
[ "${NPROC}" -eq 1 ] 2>/dev/null || fail "expected exactly 1 dashboard process, found ${NPROC}"
echo "ok 7 - second start is a no-op"

# --- 8. engine unit-test suite ---
# The suite (750 tests) runs in ~50 s on an idle host and took 751 s under a load of 65 (a verifier's run on a
# shared host): the cap is a knob, TEST6_UNITTEST_TIMEOUT (seconds, default 1200; .env's TEST_RUN_OPTS passes it
# into the test container, so `TEST6_UNITTEST_TIMEOUT=<s> ./test.sh` sets it), and a timeout names itself
UNITTEST_TIMEOUT=${TEST6_UNITTEST_TIMEOUT:-1200}
UT_START=$(date +%s)
(cd "${COMMS_HOME}" && timeout "${UNITTEST_TIMEOUT}" python3 -m unittest discover -s tests -q > ${D}/unittest.log 2>&1)
UT_RC=$?
if [ "${UT_RC}" -eq 124 ]; then
	fail "engine unit-test suite did not finish within TEST6_UNITTEST_TIMEOUT=${UNITTEST_TIMEOUT}s (load $(cut -d' ' -f1 /proc/loadavg)); on a loaded host raise it: TEST6_UNITTEST_TIMEOUT=<seconds> ./test.sh - last lines: $(tail -3 ${D}/unittest.log | tr '\n' ' ')"
fi
[ "${UT_RC}" -eq 0 ] || { tail -20 ${D}/unittest.log; fail "engine unit-test suite not green (rc ${UT_RC} after $(( $(date +%s) - UT_START ))s)"; }
grep -E "^OK" ${D}/unittest.log > /dev/null || { tail -5 ${D}/unittest.log; fail "engine unit-test suite did not end OK"; }
echo "ok 8 - engine suite green ($(grep -oE 'Ran [0-9]+ tests' ${D}/unittest.log) in $(( $(date +%s) - UT_START ))s, cap ${UNITTEST_TIMEOUT}s)"

# --- 9. stop ---
"${AGENT_DIR}/comms-ui-stop.sh" | grep -q "stopped" || fail "comms-ui-stop.sh did not stop"
[ ! -f "${COMMS_DIR}/ui.pid" ] || fail "pidfile survived stop"
sleep 1
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${COMMS_UI_PORT}/" 2>/dev/null)
[ "${HTTP}" == "200" ] && fail "port still answering after stop"
echo "ok 9 - stopped by pidfile"

# --- 10. rerun: state survives, seed does not re-run ---
"${AGENT_DIR}/comms-ui-start.sh" || fail "comms-ui-start.sh (rerun)"
COUNTS2=$(counts) || fail "journal/store unreadable after rerun"
[ "${COUNTS2}" == "${COUNTS1}" ] || fail "state changed across stop/rerun (was '${COUNTS1}', now '${COUNTS2}' - re-seed?)"
HTTP=000
for i in $(seq 1 45); do
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${COMMS_UI_PORT}/" 2>/dev/null)
	[ "${HTTP}" == "200" ] && break
	sleep 2
done
[ "${HTTP}" == "200" ] || fail "dashboard not answering after rerun"
"${AGENT_DIR}/comms-ui-stop.sh" > /dev/null || fail "final stop"
echo "ok 10 - journal + cursors survive stop/rerun (${COUNTS2})"

# --- 11. gate off: startup.sh starts nothing ---
GATEOFF_DIR=/tmp/comms-smoke-gateoff
mkdir -p ${GATEOFF_DIR}/wd
# startup.sh also makes the starter repository (starter-repo.sh) under its workspace root: here that root is the test's
# own ${GATEOFF_DIR}/wd, so the step runs for real and nothing lands under /wd - the suite's container has a throwaway
# /wd that test.sh requires untouched (anything written there would be the user's wd/ once the real volume is mounted).
# The same for the other state a start writes with every gate off: the LogLearner bank the pack loader fills
# (loglearner-packs.sh, LOGLEARNER_STATE), the default knowledge copy (claude-settings-sync.sh, KNOWLEDGE_DIR) and the agent
# session's capture log (tmux-session-start.sh, TMUX_AGENT_HOME) - ./test.sh passes test-local paths for all three
# (TEST_RUN_OPTS); without them, in a plain docker run of the image, this start wrote /wd/loglearner and /wd/tmux-agent-home
W0=$(find /wd -mindepth 1 2>/dev/null | wc -l)
COMMS_UI_ENABLED=false COMMS_DIR=${GATEOFF_DIR} UI_START=false AUTONOMY_LOOP=false SUPERVISOR=false STARTER_REPO_ROOT=${GATEOFF_DIR}/wd \
	LOGLEARNER_STATE=${GATEOFF_DIR}/loglearner KNOWLEDGE_DIR=${GATEOFF_DIR}/knowledge TMUX_AGENT_HOME=${GATEOFF_DIR}/tmux-agent-home \
	timeout 3 "${BASE_DIR}/startup.sh" > ${D}/startup-gateoff.log 2>&1
[ -d "${GATEOFF_DIR}/wd/projects/scratch/.git" ] || fail "gate-off startup.sh did not make the starter repository under its test-local root ${GATEOFF_DIR}/wd: $(grep -i 'starter' ${D}/startup-gateoff.log | head -2)"
[ "$(find /wd -mindepth 1 2>/dev/null | wc -l)" -eq "${W0}" ] || fail "gate-off startup.sh wrote under /wd: $(find /wd -mindepth 1 2>/dev/null | head -5 | tr '\n' ' ')"
grep -q "comms-ui" ${D}/startup-gateoff.log && fail "gate-off startup.sh touched the comms UI"
[ -f "${GATEOFF_DIR}/ui.pid" ] && fail "gate-off startup.sh created a pidfile"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${COMMS_UI_PORT}/" 2>/dev/null)
[ "${HTTP}" == "200" ] && fail "gate-off left a listener on ${COMMS_UI_PORT}"
echo "ok 11 - COMMS_UI_ENABLED=false starts nothing; the starter repository lands under the test-local root, /wd untouched"

echo "Test6 succeeded"
