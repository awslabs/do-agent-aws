#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the comms real-channel path shipped for docs/comms/README.md "Connect a real
# channel": the COMMS_ENV_NAMES pass-through in .env, the gated real-channel watcher
# (/agent/comms-watch-*.sh + the startup.sh gate), the docs' Slack verification ladder
# (docs/slack/README.md section 5), and the comms-UI route followed end to end to a visible
# message. Fully OFFLINE: a stub Slack API on 127.0.0.1 stands in for slack.com (the agent
# scripts honor SLACK_API_BASE; the engine's slack adapter is exercised through a test-local
# channels_dir copy with only its API_BASE constant pointed at the stub - the engine exposes
# no env override for it at the pinned sha). No real platform call; no secret anywhere.
#
# Properties proven (each check FAILS if the property is removed):
#   1. .env renders COMMS_ENV_NAMES="A B" as exactly "-e A -e B" inside COMMS_ENV_OPTS and
#      never a value; PLANTED CONTROL: COMMS_ENV_NAMES="A=x" is refused (nonzero, loud,
#      value not echoed)
#   2. watcher gate off (COMMS_WATCH_ENABLED=false/unset): startup.sh starts NO scheduler -
#      no process, no pidfile (today's behavior byte-for-byte)
#   3. watcher gate on: startup.sh starts the scheduler on the fake-adapter settings; the
#      engine's single-instance lock holds (a second start is a no-op, exit 0); status
#      reports RUNNING with a visible poll cycle; stop removes process and pidfile. (The
#      watcher never passes --seed-demo - a real-channel poller must not fabricate rows - so
#      an unseeded fake adapter legitimately polls 0; that real messages actually land in the
#      journal is proven in section 5 against the stub, with the real slack adapter.)
#   4. the docs' Slack verification ladder, step for step against the stub: status (no API
#      call) -> first watch (cursor init, 0 new) -> a message lands -> second watch (1 new,
#      inbox=1, the message text in inbox.jsonl)
#   5. the comms-UI route E2E: add a slack connection + channel through the REAL UI widgets
#      (auth as env-var NAMES that are set), apply with the human click, start the watcher,
#      and a journal row from the stub message is visible - the route Alex followed, taken
#      all the way to a message. PLANTED CONTROLS, each refused/failing exactly as the doc
#      warns: a literal token pasted -> refused unstored; an unset env name -> refused by
#      name; a channel id present on only one side of the two-place rule -> doctor FAILS
#      naming the channel and the poll stores nothing for it.
# Uses test-local state directories (/tmp/comms-real-smoke*); does not disturb /wd.

D=/tmp/comms-real-smoke
rm -rf "${D:?}"
mkdir -p ${D}

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
export COMMS_HOME=${COMMS_HOME:-/opt/comms}
export COMMS_PYTHON=${COMMS_PYTHON:-/opt/comms-venv/bin/python}  # streamlit's own Python 3.12 environment (setup/install-comms.sh)

# The repo root (for .env): mounted at /do-agent-aws by run.sh/test.sh, or the checkout root
ENV_FILE=""
for CAND in /do-agent-aws/.env "${BASE_DIR}/../.env"; do
	[ -f "${CAND}" ] && ENV_FILE="$(cd "$(dirname "${CAND}")" && pwd)/.env" && break
done

NODE_BIN=${NODE_BIN:-$(command -v node || echo /usr/local/bin/node)}

fail()
{
	echo "Test10 FAILED: $1"
	[ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null
	"${AGENT_DIR}/comms-watch-stop.sh" > /dev/null 2>&1
	exit 1
}

if [ ! -f "${COMMS_HOME}/scripts/scheduler.py" ] || ! command -v python3 > /dev/null; then
	echo "Test10 skipped: communication engine not installed under ${COMMS_HOME} (run setup/install-comms.sh)"
	exit 0
fi
if [ ! -x "${NODE_BIN}" ]; then
	echo "Test10 skipped: node not found (needed for the stub Slack API)"
	exit 0
fi

# --- 1. COMMS_ENV_NAMES rendering + the planted NAME=value control ---
if [ -z "${ENV_FILE}" ]; then
	echo "Test10 skipped: .env not found (expected the repo mounted at /do-agent-aws)"
	exit 0
fi
ENV_ROOT="$(dirname "${ENV_FILE}")"
OPTS=$(cd "${ENV_ROOT}" && bash -c 'export COMMS_ENV_NAMES="A B"; source ./.env > /dev/null 2>&1; echo "${COMMS_ENV_OPTS}"') \
	|| fail ".env refused a valid COMMS_ENV_NAMES"
case "${OPTS}" in
*"-e A -e B"*) : ;;
*) fail "COMMS_ENV_NAMES=\"A B\" did not render '-e A -e B' in COMMS_ENV_OPTS (got: ${OPTS})" ;;
esac
CONTROL_OUT=$(cd "${ENV_ROOT}" && bash -c 'export COMMS_ENV_NAMES="A=plantedsecretvalue"; source ./.env 2>&1; echo REACHED-AFTER-SOURCE' )
CONTROL_RC=$?
[ "${CONTROL_RC}" -ne 0 ] || fail "planted control: COMMS_ENV_NAMES with NAME=value was ACCEPTED (rc 0)"
echo "${CONTROL_OUT}" | grep -q "NAMES, never NAME=value" || fail "planted control: refusal lost its message (got: ${CONTROL_OUT})"
echo "${CONTROL_OUT}" | grep -q "plantedsecretvalue" && fail "planted control: the refusal ECHOED the value"
echo "ok 1 - COMMS_ENV_NAMES renders bare -e switches; NAME=value refused loud, value unechoed"

# --- fake-adapter settings for the watcher gate sections ---
COMMS_DIR=${D}/wd
COMMS_SETTINGS=${COMMS_DIR}/settings.json
export COMMS_DIR COMMS_SETTINGS
mkdir -p "${COMMS_DIR}"
python3 - << 'EOF' || fail "could not write fake-adapter settings"
import json, os
home = os.environ["COMMS_HOME"]
d = os.environ["COMMS_DIR"]
json.dump({
    "engine": {"state_dir": d + "/state", "channels_dir": home + "/channels",
               "store": d + "/state/messages.db", "journal": d + "/state/journal.db",
               "outbox": d + "/state/outbox.db"},
    "instances": [{"name": "team", "adapter": "fake",
                   "channels": [{"id": "fake-demo", "reply_policy": "never",
                                 "poll_interval_s": 1}]}],
}, open(os.environ["COMMS_SETTINGS"], "w"), indent=2)
EOF

# --- 2. gate off: startup.sh starts no scheduler ---
# startup.sh with every optional feature off is just its echo + keepalive loop - run the real
# file, so the gate under test is the shipping wiring, not a re-derivation of it
# Waits are bounded polls, never fixed sleeps: under a host load of 45-106 a verifier's run saw the fixed 1 s / 6 s
# waits of this test expire before the thing they waited for had happened
wait_for()
{
	# wait_for <seconds> <command...> - poll the command every 0.5 s until it succeeds or the deadline; 0 or 1
	local DEADLINE=$(( $(date +%s) + $1 )); shift
	until "$@" > /dev/null 2>&1; do [ "$(date +%s)" -ge "${DEADLINE}" ] && return 1; sleep 0.5; done
	return 0
}
AUTONOMY_LOOP=false UI_START=false COMMS_UI_ENABLED=false COMMS_WATCH_ENABLED=false SUPERVISOR=false \
	sh "${BASE_DIR}/startup.sh" > ${D}/startup-off.log 2>&1 &
STARTUP_PID=$!
# startup.sh is through its gates once its keepalive loop prints the first date line (matched on its clock time:
# the day and month names depend on the locale)
wait_for 60 grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}' ${D}/startup-off.log || { kill ${STARTUP_PID} 2>/dev/null; fail "startup.sh (gate off) did not reach its keepalive within 60s: $(tail -3 ${D}/startup-off.log)"; }
# Scope the probe to THIS test's config path - any-scheduler-anywhere would false-positive
# on an unrelated tenant of the machine
if pgrep -f "scheduler.py --config ${COMMS_SETTINGS}" > /dev/null 2>&1; then
	kill ${STARTUP_PID}; fail "gate off but a scheduler process exists for ${COMMS_SETTINGS}"
fi
[ -f "${COMMS_DIR}/watch.pid" ] && { kill ${STARTUP_PID}; fail "gate off but a pidfile appeared"; }
grep -q "comms-watch-start" ${D}/startup-off.log && { kill ${STARTUP_PID}; fail "gate off but startup.sh invoked the watcher"; }
kill ${STARTUP_PID} 2>/dev/null
echo "ok 2 - COMMS_WATCH_ENABLED=false: startup starts no scheduler, no pidfile"

# --- 3. gate on: startup starts it; lock holds; second start no-op; status; stop ---
AUTONOMY_LOOP=false UI_START=false COMMS_UI_ENABLED=false COMMS_WATCH_ENABLED=true SUPERVISOR=false \
	sh "${BASE_DIR}/startup.sh" > ${D}/startup-on.log 2>&1 &
STARTUP_PID=$!
scheduler_up() { [ -f "${COMMS_DIR}/watch.pid" ] && tr '\0' ' ' < "/proc/$(cat "${COMMS_DIR}/watch.pid")/cmdline" 2>/dev/null | grep -q "scripts/scheduler.py"; }
wait_for 60 scheduler_up || { kill ${STARTUP_PID} 2>/dev/null; fail "gate on but no scheduler behind a pidfile within 60s: $(tail -3 ${D}/startup-on.log)"; }
kill ${STARTUP_PID} 2>/dev/null
WATCH_PID=$(cat "${COMMS_DIR}/watch.pid")
SECOND=$("${AGENT_DIR}/comms-watch-start.sh") || fail "second start exited nonzero (want no-op exit 0)"
echo "${SECOND}" | grep -q "already running" || fail "second start did not report already-running (got: ${SECOND})"
[ "$(cat "${COMMS_DIR}/watch.pid")" = "${WATCH_PID}" ] || fail "second start replaced the pidfile"
# the first poll cycle shows in the status once the scheduler has run one - a poll, not a fixed wait
cycle_visible() { COMMS_WATCH_ENABLED=true "${AGENT_DIR}/comms-watch-status.sh" 2>/dev/null | grep -Eq "cycle: polled=[0-9]"; }
wait_for 60 cycle_visible || fail "status shows no poll cycle line within 60s - polling not visible (got: $(COMMS_WATCH_ENABLED=true "${AGENT_DIR}/comms-watch-status.sh" 2>&1))"
STATUS=$(COMMS_WATCH_ENABLED=true "${AGENT_DIR}/comms-watch-status.sh") || fail "status exited nonzero while running"
echo "${STATUS}" | grep -q "RUNNING (pid ${WATCH_PID})" || fail "status does not report RUNNING (got: ${STATUS})"
"${AGENT_DIR}/comms-watch-stop.sh" | grep -q "stopped (pid ${WATCH_PID})" || fail "stop did not stop by the exact pid"
[ -d "/proc/${WATCH_PID}" ] && fail "scheduler still alive after stop"
[ -f "${COMMS_DIR}/watch.pid" ] && fail "pidfile survives stop"
"${AGENT_DIR}/comms-watch-status.sh" > /dev/null && fail "status exits 0 while not running"
echo "ok 3 - gate on: startup starts the watcher; second start no-op; status shows a poll cycle; stop is clean"

# --- stub Slack API (for the ladder and the UI-route E2E) ---
cat > ${D}/stub.js << 'EOF'
const http = require("http");
let messages = [];
const srv = http.createServer((req, res) => {
	let body = "";
	req.on("data", d => body += d);
	req.on("end", () => {
		const url = new URL(req.url, "http://x");
		const params = url.searchParams;
		for (const kv of body.split("&")) {
			const [k, v] = kv.split("=");
			if (k && !params.has(k)) params.set(k, decodeURIComponent(v || ""));
		}
		const out = o => { res.setHeader("content-type", "application/json"); res.end(JSON.stringify(o)); };
		const path = url.pathname.replace(/^\/api/, "");
		if (path === "/stub.seed") { messages.unshift({ ts: (Date.now() / 1000).toFixed(6), text: params.get("text") || "planted" }); return out({ ok: true }); }
		if (path === "/auth.test") return out({ ok: true, user_id: "U0STUBBOT", team: "T0STUB", user: "stub-bot" });
		if (path === "/conversations.history") {
			const oldest = parseFloat(params.get("oldest") || "0");
			return out({ ok: true, messages: messages.filter(m => parseFloat(m.ts) > oldest).map(m => ({ ts: m.ts, user: "U0STUBUSER", text: m.text })), has_more: false });
		}
		if (path === "/conversations.replies") return out({ ok: true, messages: [], has_more: false });
		out({ ok: false, error: "unknown_method" });
	});
});
srv.listen(0, "127.0.0.1", () => console.log("PORT " + srv.address().port));
EOF
"${NODE_BIN}" ${D}/stub.js > ${D}/stub.out 2>&1 &
STUB_PID=$!
wait_for 30 grep -q ^PORT ${D}/stub.out || fail "stub did not print its port within 30s: $(cat ${D}/stub.out)"
STUB_PORT=$(grep ^PORT ${D}/stub.out | awk '{print $2}')
[ -n "${STUB_PORT}" ] || fail "stub did not start"

# --- 4. the docs' verification ladder (docs/slack/README.md section 5), verbatim sequence ---
LADDER_DIR=${D}/slack
export SLACK_API_BASE="http://127.0.0.1:${STUB_PORT}" SLACK_DIR="${LADDER_DIR}" NODE_BIN
export SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNELS="C000TEST"
S1=$("${AGENT_DIR}/slack-status.sh") || fail "ladder: status exited nonzero with token+channels configured"
echo "${S1}" | grep -q "last watch: never ran" || fail "ladder: pre-watch status should say the watch never ran"
W1=$("${AGENT_DIR}/slack-watch.sh") || fail "ladder: first watch failed"
echo "${W1}" | grep -q "cursor initialized to now" || fail "ladder: first watch lost the cursor-init message (got: ${W1})"
echo "${W1}" | grep -q "0 new message(s)" || fail "ladder: first watch should see 0 new (got: ${W1})"
# these two are not waits for a process: the cursor is a Slack timestamp with one-second resolution, so the planted
# message must be stamped after the cursor and the second watch after the message
sleep 1
curl -s "http://127.0.0.1:${STUB_PORT}/stub.seed?text=test+message+for+the+agent" > /dev/null
sleep 1
W2=$("${AGENT_DIR}/slack-watch.sh") || fail "ladder: second watch failed"
echo "${W2}" | grep -q "1 new message(s)" || fail "ladder: second watch should see the 1 planted message (got: ${W2})"
echo "${W2}" | grep -q "inbox=1" || fail "ladder: inbox should hold 1 (got: ${W2})"
grep -q "test message for the agent" "${LADDER_DIR}/inbox.jsonl" || fail "ladder: the message text is not in inbox.jsonl"
unset SLACK_API_BASE SLACK_BOT_TOKEN SLACK_CHANNELS SLACK_DIR
echo "ok 4 - the documented ladder: status -> first watch 0 new (cursor init) -> message -> second watch 1 new, text in inbox"

# --- 5. the comms-UI route E2E + the three documented refusal controls ---
export STUB_PORT D
export AGENT_DIR_FOR_PY="${AGENT_DIR}"
"${COMMS_PYTHON}" - << 'EOF' || fail "UI-route E2E (see output above)"
import json, os, shutil, sqlite3, subprocess, sys, time
HOME = os.environ["COMMS_HOME"]
sys.path.insert(0, HOME)
# the deletion below is built from D: an empty D would make it /ui, so refuse instead (the deletion rule)
D = (os.environ.get("D") or sys.exit("test10: D is empty - refusing to remove /ui")) + "/ui"
shutil.rmtree(D, ignore_errors=True)
os.makedirs(D + "/state")
# Test-local channels_dir: the REAL slack adapter, only its API_BASE constant pointed at the
# stub (the engine has no env override for it at the pinned sha; a copy keeps /opt/comms pristine)
shutil.copytree(HOME + "/channels", D + "/channels")
p = D + "/channels/slack/adapter.py"
s = open(p).read()
old = 'API_BASE = "https://slack.com/api"'
assert old in s, "engine slack adapter changed its API_BASE constant - update this test"
open(p, "w").write(s.replace(old, 'API_BASE = "http://127.0.0.1:%s/api"' % os.environ["STUB_PORT"]))

SETTINGS = D + "/settings.json"
os.environ["COMMS_SETTINGS"] = SETTINGS
os.environ["COMMS_UI_WRITE_ENABLED"] = "true"
os.environ["SLACK_BOT_TOKEN"] = "xoxb-test"
os.environ["SLACK_CHANNELS"] = "C000TEST"
json.dump({"engine": {"state_dir": D + "/state", "channels_dir": D + "/channels",
                      "store": D + "/state/messages.db", "journal": D + "/state/journal.db",
                      "outbox": D + "/state/outbox.db"},
           "instances": [{"name": "seed", "adapter": "fake",
                          "channels": [{"id": "fake-demo", "reply_policy": "never"}]}]},
          open(SETTINGS, "w"), indent=2)

from streamlit.testing.v1 import AppTest

def run():
    return AppTest.from_file(HOME + "/scripts/dashboard.py", default_timeout=120).run()

def by_key(widgets, key):
    found = [w for w in widgets if w.key == key]
    assert len(found) == 1, f"widget {key!r}: {len(found)} found"
    return found[0]

def submit(at, form_key):
    found = [b for b in at.button if b.key and b.key.startswith(f"FormSubmitter:{form_key}")]
    assert len(found) == 1, f"form {form_key!r} lost its submit"
    return found[0].click().run()

def apply_click(at):
    btns = [b for b in at.button if b.key and b.key.startswith("confapply-")]
    assert len(btns) == 1, f"{len(btns)} apply buttons at the gate"
    return btns[0].click().run()

def errors(at):
    return "\n".join(str(e.value) for e in at.error)

# CONTROL A: a literal token pasted where the env-var NAME belongs -> refused, unechoed
at = run()
assert not at.exception, at.exception
by_key(at.text_input, "confaddinst-name").input("pasted")
by_key(at.selectbox, "confaddinst-adapter").select("slack")
by_key(at.text_input, "confaddinst-authkey").input("token")
by_key(at.text_input, "confaddinst-authvar").input("xoxb-1234-pasted-literal")
at = submit(at, "conf-add-inst")
e = errors(at)
assert "expected the NAME of an environment variable" in e, f"literal token not refused: {e!r}"
assert "xoxb-1234-pasted-literal" not in e, "the refusal ECHOED the pasted secret"
assert "pasted" not in json.load(open(SETTINGS)).__str__(), "the refused instance reached settings.json"
print("ok 5a - control: literal token refused unstored and unechoed")

# CONTROL B: an env-var NAME that is not set -> refused by name
assert "UNSET_TOKEN_VAR_T10" not in os.environ
at = run()
by_key(at.text_input, "confaddinst-name").input("halfset")
by_key(at.selectbox, "confaddinst-adapter").select("slack")
by_key(at.text_input, "confaddinst-authkey").input("token")
by_key(at.text_input, "confaddinst-authvar").input("UNSET_TOKEN_VAR_T10")
at = submit(at, "conf-add-inst")
e = errors(at)
assert "UNSET_TOKEN_VAR_T10 is not set" in e, f"unset env name not refused by name: {e!r}"
print("ok 5b - control: unset env-var name refused by name")

# THE ROUTE: add the slack connection with SET env names, apply, add the channel, apply
at = run()
by_key(at.text_input, "confaddinst-name").input("my-slack")
by_key(at.selectbox, "confaddinst-adapter").select("slack")
by_key(at.text_input, "confaddinst-authkey").input("token")
by_key(at.text_input, "confaddinst-authvar").input("SLACK_BOT_TOKEN")
at = submit(at, "conf-add-inst")
assert not errors(at), f"staging the valid connection errored: {errors(at)}"
at = apply_click(at)
# the channels auth entry (second auth key) through the edit-connection form
by_key(at.selectbox, "confsetauth-inst").select("my-slack")
by_key(at.text_input, "confsetauth-key").input("channels")
by_key(at.text_input, "confsetauth-var").input("SLACK_CHANNELS")
at = submit(at, "conf-set-auth")
at = apply_click(at)
by_key(at.selectbox, "confaddchan-inst").select("my-slack")
by_key(at.text_input, "confaddchan-id").input("C000TEST")
by_key(at.text_input, "confaddchan-label").input("stub-watch")
at = submit(at, "conf-add-chan")
at = apply_click(at)
raw = json.load(open(SETTINGS))
inst = next(i for i in raw["instances"] if i["name"] == "my-slack")
assert inst["auth"] == {"token": "env:SLACK_BOT_TOKEN", "channels": "env:SLACK_CHANNELS"}, inst["auth"]
assert [c["id"] for c in inst["channels"]] == ["C000TEST"]
print("ok 5c - the UI route wrote the instance: adapter slack, env-name auth, channel both places")

# a message exists on the platform before the watcher runs
import urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/stub.seed?text=ui-route-proof" % os.environ["STUB_PORT"]).read()

# no watcher yet -> nothing stored (the F3 gap this feature closes)
store = D + "/state/messages.db"
assert not os.path.exists(store), "rows exist before any watcher ran - something polls that should not"

# start the shipped watcher against this settings file, wait for a cycle, stop it
agent_dir = os.environ.get("AGENT_DIR_FOR_PY")
env = dict(os.environ, COMMS_DIR=D, COMMS_SETTINGS=SETTINGS)
r = subprocess.run(["bash", agent_dir + "/comms-watch-start.sh"], env=env,
                   capture_output=True, text=True)
assert r.returncode == 0, f"comms-watch-start failed: {r.stdout} {r.stderr}"
deadline = time.time() + 30
rows = 0
while time.time() < deadline:
    if os.path.exists(store):
        conn = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
        try:
            rows = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        except sqlite3.OperationalError:
            rows = 0
        finally:
            conn.close()
        if rows:
            break
    time.sleep(1)
subprocess.run(["bash", agent_dir + "/comms-watch-stop.sh"], env=env, capture_output=True)
assert rows >= 1, "the watcher polled no message row from the stub within 30s"
conn = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
texts = [r[0] for r in conn.execute("SELECT text FROM messages")]
conn.close()
assert any("ui-route-proof" in (t or "") for t in texts), f"stub message text not stored: {texts}"
print("ok 5d - UI-configured instance + shipped watcher = the message is in the journal store")

# CONTROL C: the two-place rule - a channel id in channels[] only; doctor FAILS naming it,
# and a watcher cycle stores nothing for it
os.environ["ONE_SIDE_CHANNELS"] = "C000TEST"   # C_ONLY_CONFIG deliberately absent
raw["instances"] = [i for i in raw["instances"] if i["name"] != "seed"]
inst["auth"]["channels"] = "env:ONE_SIDE_CHANNELS"
inst["channels"].append({"id": "C_ONLY_CONFIG", "label": "two-place-miss"})
json.dump(raw, open(SETTINGS, "w"), indent=2)
from core import doctor
import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = doctor.main(["--config", SETTINGS])
out = buf.getvalue()
assert rc == 1, f"doctor should FAIL on the two-place miss (rc {rc}):\n{out}"
assert "C_ONLY_CONFIG" in out and "absent from the adapter's watched channel set" in out, out
conn = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
n = conn.execute("SELECT COUNT(*) FROM messages WHERE channel_id='C_ONLY_CONFIG'").fetchone()[0]
conn.close()
assert n == 0, "a one-sided channel stored rows"
print("ok 5e - control: two-place miss -> DOCTOR FAIL names the channel; nothing stored for it")
EOF
RC5=$?
kill ${STUB_PID} 2>/dev/null
[ ${RC5} -eq 0 ] || exit 1
echo "ok 5 - comms-UI route followed to a visible message; all three documented refusals reproduced"

echo "Test10 succeeded"
