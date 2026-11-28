#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the comms UI WRITE path (COMMS_UI_WRITE_ENABLED) and its wiring through
# /agent/comms-ui-start.sh. Fully OFFLINE: the whole write cycle runs against the
# communication engine's credential-free fake adapter - no real Slack/Telegram/email call
# is ever made, and no shipped live adapter has a send path at all.
#
# Properties proven:
#   1. all touched scripts parse (bash -n)
#   2. the write gate defaults ON in .env (COMMS_UI_WRITE_ENABLED=true - the dashboard
#      ships the engine's human-gated write surface; nothing auto-sends)
#   3. gate OFF (the one-line flip back, COMMS_UI_WRITE_ENABLED=false): the dashboard
#      renders NO write surface and the engine's send layer is never even imported into
#      the UI process (sys.modules stays clean)
#   4. gate ON at first start: comms-ui-start.sh generates settings.json with the fake
#      demo channels at reply_policy 'staged' (composable, click-gated); gate OFF
#      generation keeps them read-only 'never'
#   5. the running dashboard daemon receives COMMS_UI_WRITE_ENABLED in its environment
#      (the .env -> comms-ui-start.sh -> streamlit wiring), still loopback-only
#   6. compose through the REAL UI widgets stages a draft: outbox row STAGED, no
#      receipt, and NOTHING was sent (the fake adapter's ground truth is empty)
#   7. the explicit human click (the Send button on that exact draft) delivers it:
#      row COMMITTED with a read-back-proven receipt from the fake adapter
#   8. discard is terminal and kept: the row stays as DISCARDED and offers no Send
# Uses test-local state directories (/tmp/comms-write-smoke*); does not disturb /wd.

D=/tmp/comms-write-smoke
rm -rf "${D:?}"
mkdir -p ${D}

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"

export COMMS_HOME=${COMMS_HOME:-/opt/comms}
export COMMS_PYTHON=${COMMS_PYTHON:-/opt/comms-venv/bin/python}  # streamlit's own Python 3.12 environment (setup/install-comms.sh)
export COMMS_UI_PORT=8603
# This test exercises the comms UI itself, not the home-proxy routing (test9.sh does
# that): pin the base path empty so the dashboard answers at / regardless of the
# container's UI_HOME/COMMS_UI_BASE_PATH defaults.
export COMMS_UI_BASE_PATH=
export COMMS_UI_LISTEN_HOST=127.0.0.1
export COMMS_DEMO_SEED=true

fail()
{
	echo "Test7 FAILED: $1"
	COMMS_DIR=${D}/state-on "${AGENT_DIR}/comms-ui-stop.sh" > /dev/null 2>&1
	exit 1
}

# --- 1. syntax ---
for S in "${AGENT_DIR}/comms-ui-start.sh" "${AGENT_DIR}/comms-ui-stop.sh" \
         "${AGENT_DIR}/comms-ui-status.sh"; do
	bash -n "${S}" || fail "bash -n ${S}"
done
echo "ok 1 - syntax"

# --- preflight: engine + streamlit (installed by setup/install-comms.sh in the image) ---
if [ ! -f "${COMMS_HOME}/scripts/dashboard.py" ] || ! command -v python3 > /dev/null; then
	echo "Test7 skipped: communication engine not installed under ${COMMS_HOME} (run setup/install-comms.sh)"
	exit 0
fi
if [ ! -f "${COMMS_HOME}/scripts/dashboard_write.py" ]; then
	fail "engine at ${COMMS_HOME} has no scripts/dashboard_write.py - install-comms.sh pin predates the write path"
fi

# --- 2. the gate defaults ON in .env ---
# The repo .env is the shipped default; in-container it is baked at /. Look in both spots.
ENV_FILE=""
for C in "${BASE_DIR}/../.env" "/do-agent-aws/.env" "${BASE_DIR}/.env"; do
	[ -f "${C}" ] && ENV_FILE="${C}" && break
done
if [ -n "${ENV_FILE}" ]; then
	grep -qE '^export COMMS_UI_WRITE_ENABLED=true$' "${ENV_FILE}" \
		|| fail "COMMS_UI_WRITE_ENABLED does not default to true in ${ENV_FILE}"
	echo "ok 2 - .env defaults the write gate ON (human-gated; nothing auto-sends)"
else
	echo "ok 2 - (skipped: no .env found in this context)"
fi

# --- 4a. gate OFF generation: read-only channels ---
COMMS_DIR=${D}/state-off COMMS_UI_WRITE_ENABLED=false "${AGENT_DIR}/comms-ui-start.sh" \
	|| fail "comms-ui-start.sh (gate off)"
COMMS_DIR=${D}/state-off "${AGENT_DIR}/comms-ui-stop.sh" > /dev/null 2>&1
python3 - << 'EOF' || fail "gate-off generated settings are not read-only"
import json, os
cfg = json.load(open("/tmp/comms-write-smoke/state-off/settings.json"))
pols = [ch.get("reply_policy") for i in cfg["instances"] for ch in i.get("channels", [])]
assert pols and set(pols) == {"never"}, pols
EOF
echo "ok 4a - gate-off settings keep every channel at reply_policy never"

# --- 3. gate OFF: no write surface, send layer never imported ---
COMMS_DIR=${D}/state-off COMMS_SETTINGS=${D}/state-off/settings.json \
COMMS_UI_WRITE_ENABLED=false "${COMMS_PYTHON}" - << 'EOF' || fail "gate-off dashboard grew a write surface"
import os, sys
sys.path.insert(0, os.environ["COMMS_HOME"])
from streamlit.testing.v1 import AppTest
at = AppTest.from_file(os.environ["COMMS_HOME"] + "/scripts/dashboard.py",
                       default_timeout=60).run()
assert not at.exception, at.exception
assert not [b for b in at.button if b.key and b.key.startswith("FormSubmitter:compose")], \
    "compose form rendered with the gate off"
assert "dashboard_write" not in sys.modules, \
    "the send-layer module was imported with the gate off"
caps = "\n".join(str(c.value) for c in at.caption)
assert "cannot send or edit" in caps, "the read-only promise left the sidebar"
EOF
echo "ok 3 - gate off: no write widgets, send layer not imported"

# --- 4b. gate ON generation: staged (composable, click-gated) channels ---
# drain the port from the gate-off daemon before reusing it
for i in $(seq 1 15); do
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${COMMS_UI_PORT}/" 2>/dev/null)
	[ "${HTTP}" == "200" ] || break
	sleep 1
done
COMMS_DIR=${D}/state-on COMMS_UI_WRITE_ENABLED=true "${AGENT_DIR}/comms-ui-start.sh" \
	|| fail "comms-ui-start.sh (gate on)"
python3 - << 'EOF' || fail "gate-on generated settings are not staged"
import json
cfg = json.load(open("/tmp/comms-write-smoke/state-on/settings.json"))
pols = [ch.get("reply_policy") for i in cfg["instances"] for ch in i.get("channels", [])]
assert pols and set(pols) == {"staged"}, pols
adapters = [i.get("adapter") for i in cfg["instances"]]
assert set(adapters) == {"fake"}, adapters
EOF
echo "ok 4b - gate-on settings stage the fake demo channels (fake adapter only)"

# --- 5. the daemon got the gate variable, loopback only ---
UIPID=$(cat ${D}/state-on/ui.pid 2>/dev/null)
[ -n "${UIPID}" ] && [ -d "/proc/${UIPID}" ] || fail "no running dashboard pid"
tr '\0' '\n' < /proc/${UIPID}/environ | grep -q '^COMMS_UI_WRITE_ENABLED=true$' \
	|| fail "the dashboard daemon did not receive COMMS_UI_WRITE_ENABLED=true"
HTTP=000
for i in $(seq 1 45); do
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${COMMS_UI_PORT}/" 2>/dev/null)
	[ "${HTTP}" == "200" ] && break
	sleep 2
done
[ "${HTTP}" == "200" ] || { tail -20 ${D}/state-on/ui.log 2>/dev/null; fail "gate-on dashboard not answering on 127.0.0.1:${COMMS_UI_PORT}"; }
python3 - << 'EOF' || fail "a non-loopback listener exists on the comms UI port"
import os
port = format(int(os.environ["COMMS_UI_PORT"]), '04X')
bad = [f[1] for ln in open('/proc/net/tcp') if len(f := ln.split()) > 3
       and f[3] == '0A' and f[1].endswith(':' + port) and f[1].split(':')[0] != '0100007F']
assert not bad, bad
EOF
# Streamlit's own toolbar is off (its Deploy menu offered Streamlit Community Cloud - a public-publishing path
# inside the tool holding the Slack credentials): the running daemon was started with --client.toolbarMode viewer and carries
# STREAMLIT_CLIENT_TOOLBAR_MODE=viewer; Streamlit reports the effective value from the same environment
tr '\0' '\n' < /proc/${UIPID}/cmdline | grep -qx -- '--client.toolbarMode' && tr '\0' '\n' < /proc/${UIPID}/cmdline | grep -qx viewer \
	|| fail "the dashboard daemon was not started with --client.toolbarMode viewer: $(tr '\0' ' ' < /proc/${UIPID}/cmdline | cut -c1-300)"
tr '\0' '\n' < /proc/${UIPID}/environ | grep -qx 'STREAMLIT_CLIENT_TOOLBAR_MODE=viewer' || fail "the dashboard daemon does not carry STREAMLIT_CLIENT_TOOLBAR_MODE=viewer"
TB=$(cd "${COMMS_HOME}" && STREAMLIT_CLIENT_TOOLBAR_MODE=viewer "${COMMS_PYTHON}" -m streamlit config show 2>/dev/null | grep -E '^toolbarMode' | head -1)
echo "${TB}" | grep -q '"viewer"' || fail "Streamlit does not report toolbarMode viewer from the daemon's environment: ${TB}"
echo "ok 5 - daemon carries the gate env and Streamlit's toolbar off (toolbarMode viewer: no Deploy menu); listener loopback-only"
COMMS_DIR=${D}/state-on "${AGENT_DIR}/comms-ui-stop.sh" > /dev/null 2>&1

# --- 6/7/8. the full write cycle through the REAL UI widgets, offline ---
COMMS_SETTINGS=${D}/state-on/settings.json COMMS_UI_WRITE_ENABLED=true \
"${COMMS_PYTHON}" - << 'EOF' || fail "write cycle (stage -> click -> deliver -> discard) failed"
import os, sqlite3, sys
sys.path.insert(0, os.environ["COMMS_HOME"])
from streamlit.testing.v1 import AppTest
from core.config import load

cfg = load(os.environ["COMMS_SETTINGS"])
inst = cfg.instances[0].name
db = str(cfg.outbox_path_for(inst))

def rows():
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        return conn.execute("SELECT state, receipt, text FROM outbox "
                            "ORDER BY created_at").fetchall()
    finally:
        conn.close()

def run():
    return AppTest.from_file(os.environ["COMMS_HOME"] + "/scripts/dashboard.py",
                             default_timeout=60).run()

def compose(at, text):
    at.selectbox[0].select(at.selectbox[0].options[0])
    at.text_area[0].input(text)
    sub = [b for b in at.button if b.key and b.key.startswith("FormSubmitter:compose")]
    assert len(sub) == 1, "compose form missing under the gate"
    return sub[0].click().run()

# 6: compose stages, sends nothing
at = compose(run(), "[TEST7] offline draft - must not send without a click")
assert not at.exception, at.exception
r = rows()
assert [x[0] for x in r] == ["STAGED"], r
assert r[0][1] is None, "a receipt exists for a draft nobody sent"
print("ok 6 - compose staged (no receipt, nothing sent)")

# 7: the human click delivers to the FAKE adapter, read-back proven
send = [b for b in at.button if b.key and b.key.startswith("send-")]
assert len(send) == 1, "staged draft is not at the gate with a Send button"
at = send[0].click().run()
assert not at.exception, at.exception
r = rows()
assert r[0][0] == "COMMITTED", r
assert r[0][1] is not None, "COMMITTED without a fake-adapter receipt"
print("ok 7 - human click delivered: COMMITTED with read-back-proven receipt")

# 8: discard is terminal and kept
at = compose(at, "[TEST7] second draft - to be rejected")
disc = [b for b in at.button if b.key and b.key.startswith("discard-")]
assert len(disc) == 1, "second staged draft has no Discard"
at = disc[0].click().run()
assert not at.exception, at.exception
r = rows()
assert [x[0] for x in r] == ["COMMITTED", "DISCARDED"], r
assert not [b for b in at.button if b.key and b.key.startswith("send-")], \
    "a discarded draft still offers Send"
print("ok 8 - discard terminal, row kept as the audit record")
EOF

echo "Test7 succeeded"
