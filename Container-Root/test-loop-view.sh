#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the Agent loop page (/agent/loop-view.py; its route, tile and dot probe in /agent/home-render.sh; the
# loop-view rows of ui-start.sh, ui-status.sh and ui-stop.sh) and of the loop's place in the tmux fleet
# (/agent/loop-lineage.sh, run by /agent/loop-start.sh). Fully OFFLINE: no model call - a stub claude stands in for a
# fire, the loop's files are written by the real loop.sh or planted in its exact formats, a private tmux server
# (TMUX_TMPDIR) keeps any real agent session out of it, everything binds 127.0.0.1 on test-local ports, and the state
# lives under /tmp/loop-view-smoke.
#
# Properties proven (each check FAILS when its property is removed; the control that shows it is run here):
#   1. every script involved parses, loop-view.py compiles, app.js parses (node --check)
#   2. a stopped loop reads "stopped" and never GREEN; CONTROL: the real loop.sh, started, reads "running" and GREEN
#   3. needs attention lists a failed fire (rc != 0) and a fire that hit its timeout, the STOP flag, the loop not
#      running while goals are open, and a lock no loop process holds; CONTROL: with only good fires, a stopped loop and
#      no open goal the list is empty. A goal longer than the page shows ends in an ellipsis; CONTROL: a renderer copy
#      that cuts without one fails
#   4. after one fire of the real loop the page's fleet reads operator -> loop -> fire, with the sub-agent the fire's
#      own session shows; CONTROL: a renderer copy that writes no lineage (no fire under the loop) fails the check
#   5. the tmux-agent dashboard's own CLI (`tmux-agent lineage`) shows the loop under operator and the live fire under
#      the loop, and its API keeps the ended fire in the history with the loop as parent; CONTROL: the same check fails
#      with AUTONOMY_LOOP_TMUX_LINEAGE=false. With the lineage on, the fire still behaves as loop.sh makes it: a fire's
#      rc is logged as it exits, a fire past AUTONOMY_LOOP_FIRE_TIMEOUT ends with rc 124, loop-stop.sh --now ends the
#      loop and the fire in flight, the loop's sessions end, no process holds the lock, and the tmux server survives.
#      A last fire that sets the STOP flag itself (loop.sh then logs its END and LOOP STOPPED and exits in the same
#      second) closes in the dashboard's ledger with its rc; CONTROL: a loop-lineage.sh copy without the pane's final
#      read of the log closes it as cut off by the loop's exit. A loop started WITHOUT TMUX_AGENT_HOME (as the
#      container starts it: ui-start.sh decides the dashboard's home) writes its ledger lines where the running
#      dashboard reads them, found from the dashboard's process; CONTROL: a loop-lineage.sh copy without that read
#      writes them to its own default instead
#   6. /__probe/loop through the rendered proxy is 204 (status only, GET only) while the data is fresh; CONTROL 1: the
#      renderer stopped - not 2xx; CONTROL 2: the data stale (a render interval beyond the stale bound) - not 2xx
#   7. a transcript holding <script> is served as text/plain, nosniff and sandboxed, bytes intact, with no badge in it,
#      and the page's script has no HTML sink; CONTROLS: a renderer copy serving it as text/html, and an app.js copy
#      writing innerHTML, each fail
#   8. through the proxy the page carries the home badge exactly once, returning to //localhost:<port>/; its three
#      inline parts (the style attribute, the phone-width rule, the keeper script) are the page's only inline parts,
#      and the route's Content-Security-Policy allows each by its hash; CONTROLS: a home-render.sh copy without the
#      route's badge include fails, and one whose policy lacks the keeper's hash fails (the viewport at 1920x1080 and
#      390x844 needs a browser: the Playwright walk of the real check). The route serves the harness stylesheet
#      (/__harness/harness.css: its bytes, text/css) and the page links it exactly once - its own link; the badge
#      include adds none; CONTROL: a home-render.sh copy without the route's stylesheet location does not serve it
#   9. ui-start.sh starts the renderer on 127.0.0.1 only and ui-status.sh reports it UP, the home page lists the tile
#      live, ui-stop.sh stops it; UI_LOOP=false renders no route and no probe, and greys the tile with its flag
#  10. the Control section: Run next fire on a stopped loop answers done with the loop read back running, and the loop
#      fires; Pause loop answers done with STOP a file, and the loop halts (Run next fire before it has halted answers
#      failed: running, the STOP flag still set). With planted states the scripts call fine - a
#      lock no loop process holds (loop-start.sh: "already running", exit 0) and a STOP that is a directory (touch
#      succeeds) - both answer failed. A POST without the page's X-Loop-Control header, from another origin, and a GET are
#      refused, and UI_LOOP_CONTROL=false refuses both actions. CONTROLS: a renderer answering from the scripts' exit
#      codes calls the planted states done; one without the header check runs an action sent without the header
#  11. one page per loop at /loop/<loop-id>/, and the README saying that a loop row of Loop Deck opens the Deck's own
#      view of the loop, as the Deck's app.js does (a missing README or app.js fails): /loop/autonomy-loop/ through the
#      proxy is the page / serves and /loop/autonomy-loop redirects to it; its data and its transcripts (sandboxed text/plain)
#      are under it; /loop/nope/ is a 404 that says so and names the loops shown; an id with markup is escaped; a POST to
#      /loop/autonomy-loop/control/pause reaches the renderer's checks. The Loop Deck link (the 404 page and data.json):
#      none with the Deck neither named nor reachable; the Deck this harness serves, on the sibling host route
#      (//loop-deck.<home host>/#/loops), while a stub on its port answers the proxy's /__probe/loop-deck; the Loops view
#      of the Deck LOOP_DECK_URL names. CONTROLS: a renderer without the route, one without the escape, one without Loop
#      Deck's address, one that does not ask whether the Deck is reachable, one that ignores LOOP_DECK_URL, and a proxy
#      without the prefixed transcripts location (a transcript gets the page's policy) each fail
#  12. the harness's other loops by their Loop Deck slugs (slack-chat, slack-watch, comms-watch, kanban-sync, plane-sync,
#      hindsight-seed): through the proxy each /loop/<slug>/ is its status page, and its data reads that loop's own files -
#      slack-chat's answered messages as fires (MSG, MODEL, REPLY: answering, failed, ok with rc and duration) with its
#      lock holder, slack-watch's last-watch line, comms-watch's process and log tail, the state files of kanban-sync,
#      plane-sync (none yet: said so) and hindsight-seed; once the comms watch exits its pid reads not running. CONTROLS:
#      a renderer without the chat's REPLY lines, and one that trusts the pid file, each fail

D=/tmp/loop-view-smoke
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
VIEW="${AGENT_DIR}/loop-view.py"
PIDS=()

# a private tmux server and test-local state for everything that would otherwise share the agent's
unset TMUX TMUX_PANE
export TMUX_TMPDIR=${D}/tmux
export TMUX_AGENT_HOME=${D}/tmux-agent-home
export CLAUDE_CONFIG_DIR=${D}/claude
export UI_DIR=${D}/ui
export UI_LISTEN_HOST=127.0.0.1
export UI_HOME_GATEWAY=127.0.0.2
export UI_PORT_LOOP=18790 UI_PORT_HOME=18791
# the Loop Deck: its adapter runs after every fire (loop.sh) and at UI start, so its inputs go under this directory,
# and the Deck's port (its route and probe in the rendered proxy) is a test-local one nothing else listens on
export LOOP_DECK_DATA_DIR=${D}/loop-deck UI_PORT_LOOP_DECK=18793
export SLACK_DIR=${D}/slack SLACK_BOT_TOKEN= SLACK_CHANNELS= SLACK_CHAT_ENABLED=false SLACK_WATCH_ENABLED=false
export AGENT_TMUX_SESSION_NAME=agent AGENT_TMUX_CLAUDE=false
unset AUTONOMY_LOOP_TMUX_SESSION AUTONOMY_LOOP_TMUX_LINEAGE

cleanup()
{
	for P in "${PIDS[@]}"; do kill "${P}" 2> /dev/null; done
	for N in ui probe-ui mutant-ui; do kill "$(cat "${D}/${N}/home/nginx.pid" 2> /dev/null)" 2> /dev/null; done
	UI_DIR=${D}/ui "${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
	for L in "${D}"/*/loop; do [ -d "${L}" ] && AUTONOMY_LOOP_DIR=${L} "${AGENT_DIR}/loop-stop.sh" --now > /dev/null 2>&1; done
	tmux kill-server 2> /dev/null
}
trap cleanup EXIT

fail()
{
	echo "Test-loop-view FAILED: $1"
	exit 1
}

rm -rf "${D:?}"
mkdir -p "${D}/tmux" "${TMUX_AGENT_HOME}" "${CLAUDE_CONFIG_DIR}"
chmod 700 "${D}/tmux"

# render <loop dir> [<env>...] - one render of the page for <loop dir> into ${D}/ui-<name>, prints the data.json path
render()
{
	local L=$1 OUT=${D}/ui-$(basename "$(dirname "$1")")
	shift
	env AUTONOMY_LOOP_DIR="${L}" AUTONOMY_LOOP_GOALS="$(dirname "${L}")/goals/GOALS.md" UI_DIR="${OUT}" "$@" \
		python3 "${VIEW_BIN:-${VIEW}}" --once > "${OUT}.log" 2>&1 || { cat "${OUT}.log"; return 1; }
	echo "${OUT}/loop/data.json"
}
# q <data.json> <python expression over d> - one value from a rendered data.json
q()
{
	python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}
stamp() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

# The stub claude: the prompt on stdin, then the fire's own Claude Code session (its first user entry is the prompt,
# then an Agent tool use and its result) under CLAUDE_CONFIG_DIR/projects, the way claude -p writes one, then the
# planted outcome from ${STUB_CONF}: STUB_SLEEP seconds, STUB_OUT on stdout, exit STUB_RC - or, with STUB_PLAN
# ("<sleep>:<rc> ..."), the entry of the fire number loop.state names, so a run of fires is planned up front.
export STUB_CONF=${D}/stub.conf
echo 'STUB_SLEEP=0; STUB_RC=0; STUB_OUT="fire done"; STUB_AGENT="Survey the goals file"; STUB_PLAN=' > "${STUB_CONF}"
cat > "${D}/stub-claude" << 'EOF'
#!/bin/bash
. "${STUB_CONF}"
if [ -n "${STUB_PLAN}" ]; then
	N=$(sed -nE 's/^FIRING fire=([0-9]+).*/\1/p' "${AUTONOMY_LOOP_DIR}/loop.state" 2> /dev/null)
	E=$(echo ${STUB_PLAN} | cut -d' ' -f"${N:-1}")
	[ -n "${E}" ] && STUB_SLEEP=${E%%:*} && STUB_RC=${E##*:}
fi
PROMPT=$(cat)
P=${CLAUDE_CONFIG_DIR}/projects/$(pwd | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "${P}"
python3 - "${P}/$(cat /proc/sys/kernel/random/uuid).jsonl" "${PROMPT}" "${STUB_AGENT}" << 'PY'
import json, sys, time
path, prompt, agent = sys.argv[1:4]
ts = lambda: time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
rows = [{"type": "user", "message": {"role": "user", "content": prompt}, "timestamp": ts()}]
if agent:
    rows.append({"type": "assistant", "timestamp": ts(), "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_stub1", "name": "Agent",
         "input": {"description": agent, "subagent_type": "general-purpose", "prompt": "survey"}}]}})
    rows.append({"type": "user", "timestamp": ts(), "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_stub1", "content": "surveyed"}]}})
with open(path, "w") as f:
    f.write("".join(json.dumps(r) + "\n" for r in rows))
PY
sleep "${STUB_SLEEP:-0}"
printf '%s\n' "${STUB_OUT}"
# STUB_STOP: the fire ends the loop the way an agent whose goals are all done does - it creates the STOP flag
[ -n "${STUB_STOP}" ] && touch "${AUTONOMY_LOOP_DIR}/STOP"
exit "${STUB_RC:-0}"
EOF
chmod +x "${D}/stub-claude"
export CLAUDE_BIN=${D}/stub-claude

# --- 1. syntax ---
for S in loop-lineage.sh loop-start.sh loop-stop.sh loop.sh home-render.sh ui-start.sh ui-status.sh ui-stop.sh; do
	bash -n "${AGENT_DIR}/${S}" || fail "bash -n ${S}"
done
bash -n "$0" || fail "bash -n $0"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${VIEW}" || fail "loop-view.py does not parse"
if command -v node > /dev/null; then
	node --check "${AGENT_DIR}/loop-view/app.js" || fail "app.js does not parse"
fi
echo "ok 1 - syntax (scripts, loop-view.py, app.js)"

# --- 2. a stopped loop reads stopped, never GREEN; control: the real loop, running, reads running and GREEN ---
F=${D}/stopped
mkdir -p "${F}/loop/fires" "${F}/work"
printf '%s LOOP START interval=300s goals=%s fire_timeout=600s workdir=%s\n%s FIRE 1 BEGIN goals=%s\n%s FIRE 1 END rc=0 duration=40s\n%s LOOP STOPPED stop flag %s present\n' \
	"$(stamp 900)" "${F}/goals/GOALS.md" "${F}/work" "$(stamp 800)" "${F}/goals/GOALS.md" "$(stamp 760)" "$(stamp 700)" "${F}/loop/STOP" > "${F}/loop/loop.log"
echo "STOPPED reason=stop-flag pid=2147480000 utc=$(stamp 700)" > "${F}/loop/loop.state"
J=$(render "${F}/loop") || fail "render (stopped)"
[ "$(q "${J}" 'd["hub"]["state"]')" == "stopped" ] || fail "a stopped loop does not read stopped: $(q "${J}" 'd["hub"]')"
[ "$(q "${J}" 'd["hub"]["health"]')" != "GREEN" ] || fail "a stopped loop reads GREEN"
R=${D}/run
mkdir -p "${R}/loop" "${R}/goals" "${R}/work"
printf -- '- [ ] write the smoke file\n- [x] read the goals\n' > "${R}/goals/GOALS.md"
RUN_ENV=(AUTONOMY_LOOP_DIR="${R}/loop" AUTONOMY_LOOP_GOALS="${R}/goals/GOALS.md" AUTONOMY_LOOP_WORKDIR="${R}/work"
	AUTONOMY_LOOP_INTERVAL=2 AUTONOMY_LOOP_FIRE_TIMEOUT=60)
env "${RUN_ENV[@]}" bash "${AGENT_DIR}/loop.sh" > "${R}/loop.stdout" 2>&1 &
LOOP_PID=$!
PIDS+=("${LOOP_PID}")
for i in $(seq 1 30); do grep -q " END rc=" "${R}/loop/loop.log" 2> /dev/null && break; sleep 0.5; done
grep -q "FIRE 1 END rc=0" "${R}/loop/loop.log" || fail "the real loop did not complete a stub fire: $(cat "${R}/loop.stdout")"
J=$(render "${R}/loop") || fail "render (running)"
[ "$(q "${J}" 'd["hub"]["state"]')" == "running" ] || fail "CONTROL: the running loop does not read running: $(q "${J}" 'd["hub"]')"
[ "$(q "${J}" 'd["hub"]["health"]')" == "GREEN" ] || fail "CONTROL: the running loop is not GREEN: $(q "${J}" 'd["hub"]["health_reason"]')"
echo "ok 2 - a stopped loop reads stopped and $(q "$(render "${F}/loop")" 'd["hub"]["health"]'); control: the running loop.sh reads running, GREEN ($(q "${J}" 'd["hub"]["health_reason"]'))"

# --- 4. (needs the fire above) the fleet: operator -> loop -> fire, the fire's sub-agent under it ---
tree_ok()
{
	python3 - "$1" << 'PY'
import json, sys
root = json.load(open(sys.argv[1]))["fleet"]["root"]
loop = [c for c in root["children"] if c["kind"] == "loop"]
fires = [f for f in (loop[0]["children"] if loop else []) if f["kind"] == "fire"]
subs = [s for f in fires for s in f["children"] if s["kind"] == "subagent"]
ok = root["kind"] == "operator" and loop and fires and subs
print("operator -> %s -> %s -> %s" % (loop[0]["label"] if loop else "NO LOOP", ", ".join(f["label"] for f in fires) or "NO FIRE",
                                     ", ".join("%s (%s)" % (s["label"], s["state"]) for s in subs) or "NO SUB-AGENT"))
sys.exit(0 if ok else 1)
PY
}
TREE=$(tree_ok "${J}") || fail "after one fire the fleet is not operator -> loop -> fire -> sub-agent: ${TREE}"
mkdir -p "${D}/mutant-view"
cp -r "${AGENT_DIR}/loop-view" "${D}/mutant-view/"
python3 - "${VIEW}" "${D}/mutant-view/loop-view.py" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = '"tmux": LOOP_SESSION if LOOP_SESSION in live_tmux else None, "children": kids})'
assert anchor in s, "the loop node is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, anchor.replace('"children": kids', '"children": []')))
PY
MJ=$(VIEW_BIN=${D}/mutant-view/loop-view.py render "${R}/loop") || fail "render (mutant without lineage)"
MTREE=$(tree_ok "${MJ}") && fail "CONTROL: a renderer that writes no lineage passed the hierarchy check: ${MTREE}"
echo "ok 4 - after one fire: ${TREE}; control: a renderer writing no lineage fails (${MTREE})"

# stop the loop: the STOP flag halts it before its next fire
touch "${R}/loop/STOP"
for i in $(seq 1 30); do kill -0 "${LOOP_PID}" 2> /dev/null || break; sleep 0.5; done
kill -0 "${LOOP_PID}" 2> /dev/null && fail "the loop did not halt on its STOP flag"
J=$(render "${R}/loop") || fail "render (stopped again)"
[ "$(q "${J}" 'd["hub"]["state"]')" == "stopped" ] || fail "the loop halted by its STOP flag does not read stopped"

# --- 3. needs attention ---
A=${D}/attn
mkdir -p "${A}/loop/fires" "${A}/goals"
printf '%s LOOP START interval=300s goals=%s fire_timeout=600s workdir=/wd\n' "$(stamp 5000)" "${A}/goals/GOALS.md" > "${A}/loop/loop.log"
printf '%s FIRE 1 BEGIN goals=%s\n%s FIRE 1 END rc=0 duration=50s\n' "$(stamp 4800)" "${A}/goals/GOALS.md" "$(stamp 4750)" >> "${A}/loop/loop.log"
printf '%s FIRE 2 BEGIN goals=%s\n%s FIRE 2 END rc=0 duration=50s\n' "$(stamp 4400)" "${A}/goals/GOALS.md" "$(stamp 4350)" >> "${A}/loop/loop.log"
printf '%s LOOP STOPPED stop flag present\n' "$(stamp 4000)" >> "${A}/loop/loop.log"
echo "STOPPED reason=stop-flag pid=2147480001 utc=$(stamp 4000)" > "${A}/loop/loop.state"
J=$(render "${A}/loop") || fail "render (attention control)"
[ "$(q "${J}" 'len(d["attention"])')" == "0" ] || fail "CONTROL: good fires, a stopped loop and no goals file put something under needs attention: $(q "${J}" 'd["attention"]')"
# the failed fire and the timed-out fire, and the goals left open
sed -i '$d' "${A}/loop/loop.log"
printf '%s FIRE 3 BEGIN goals=%s\n%s FIRE 3 END rc=1 duration=12s\n' "$(stamp 3900)" "${A}/goals/GOALS.md" "$(stamp 3888)" >> "${A}/loop/loop.log"
printf '%s FIRE 4 BEGIN goals=%s\n%s FIRE 4 END rc=124 duration=600s\n' "$(stamp 3500)" "${A}/goals/GOALS.md" "$(stamp 2900)" >> "${A}/loop/loop.log"
printf '%s LOOP STOPPED stop flag present\n' "$(stamp 2800)" >> "${A}/loop/loop.log"
J=$(render "${A}/loop") || fail "render (failed + timed out)"
KINDS=$(q "${J}" '" ".join(sorted("%s:%s" % (a["kind"], a.get("fire", "")) for a in d["attention"]))')
[ "${KINDS}" == "failed:3 timeout:4" ] || fail "needs attention does not list exactly the failed fire 3 and the timed-out fire 4: ${KINDS}"
printf -- '- [ ] an open goal\n' > "${A}/goals/GOALS.md"
touch "${A}/loop/STOP"
J=$(render "${A}/loop") || fail "render (STOP flag + open goal)"
KINDS2=$(q "${J}" '" ".join(sorted(a["kind"] for a in d["attention"]))')
[ "${KINDS2}" == "failed not-running stop-flag timeout" ] || fail "with the STOP flag and an open goal, needs attention reads: ${KINDS2}"
# a lock that no loop process holds (here: a sleep that inherited the locked fd)
( exec 9> "${A}/loop/loop.lock"; flock -n 9 && exec sleep 30 ) &
PIDS+=($!)
sleep 0.5
J=$(render "${A}/loop") || fail "render (stale lock)"
[ "$(q "${J}" '"stale-lock" in [a["kind"] for a in d["attention"]] and d["hub"]["state"] == "stale"')" == "True" ] \
	|| fail "a lock held by a non-loop process is not a stale lock: $(q "${J}" 'd["hub"]["state"], d["hub"]["lock_holders"]')"
# a goal longer than the page shows (300 characters) is cut with an ellipsis, never silently; control: a renderer copy
# that cuts without one fails
LONG="a goal with a long DONE condition:$(printf ' word%.0s' $(seq 1 70)) and these last words"
printf -- '- [ ] %s\n' "${LONG}" > "${A}/goals/GOALS.md"
long_ok() { [ "$(q "$1" 'len(d["goals"]["items"][0]["text"]) == 300 and d["goals"]["items"][0]["text"].endswith("\u2026")')" == "True" ]; }
J=$(render "${A}/loop") || fail "render (long goal)"
long_ok "${J}" || fail "a goal longer than 300 characters is not cut with an ellipsis: $(q "${J}" 'd["goals"]["items"][0]["text"][-40:]')"
mkdir -p "${D}/mutant-clip"
cp -r "${AGENT_DIR}/loop-view" "${D}/mutant-clip/"
python3 - "${VIEW}" "${D}/mutant-clip/loop-view.py" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = 'return text if len(text) <= width else text[:width - 1] + "\\u2026"'
assert anchor in s, "clip() is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, "return text[:width]"))
PY
MJ=$(VIEW_BIN=${D}/mutant-clip/loop-view.py render "${A}/loop") || fail "render (mutant without the ellipsis)"
long_ok "${MJ}" && fail "CONTROL: a renderer cutting the goal without an ellipsis passed the check"
echo "ok 3 - needs attention: ${KINDS} (then ${KINDS2}, and stale-lock for a lock no loop holds); control: good fires, no open goal -> empty; a ${#LONG}-character goal shows 300 ending in an ellipsis (control: a renderer cutting without one fails)"

# --- 5. the tmux-agent dashboard's tree: operator -> loop -> fire, live and in its history ---
TA_JS=/opt/tmux-agent/dist/bin/tmux-agent.js
if [ ! -x /agent/loop.sh ] || ! command -v tmux > /dev/null || ! command -v node > /dev/null || [ ! -f "${TA_JS}" ]; then
	echo "Test-loop-view skipped check 5: it needs the image's /agent/loop.sh (loop-start.sh starts that one), tmux, node and the vendored tmux-agent at ${TA_JS}"
else
	ta() { TMUX_AGENT_DEFAULT_SERVER=1 node "${TA_JS}" "$@"; }
	ta_api() { curl -s --max-time 5 "http://127.0.0.1:18792$1"; }
	# lineage_ok <tmux-agent lineage output> <fire n>: the loop's row has parent operator, the fire's has parent the loop
	lineage_ok()
	{
		echo "$1" | grep -qP "^agent-loop\tparent=operator\t" && echo "$1" | grep -qP "^agent-loop-fire-$2\tparent=agent-loop\t"
	}
	wait_line() { for i in $(seq 1 "${3:-60}"); do grep -q "$2" "$1" 2> /dev/null && return 0; sleep 0.5; done; return 1; }
	wait_session() { for i in $(seq 1 40); do tmux has-session -t "=$1" 2> /dev/null && return 0; sleep 0.5; done; return 1; }
	gone_session() { for i in $(seq 1 20); do tmux has-session -t "=$1" 2> /dev/null || return 0; sleep 0.5; done; return 1; }
	# the agent session on the private tmux server, as the container makes it (tmux-session-start.sh: parent operator)
	"${AGENT_DIR}/tmux-session-start.sh" > "${D}/tmux-session.log" 2>&1 || fail "tmux-session-start.sh: $(cat "${D}/tmux-session.log")"
	TMUX_AGENT_DEFAULT_SERVER=1 node "${TA_JS}" web --port 18792 --host 127.0.0.1 --no-token --strict-port > "${D}/ta-web.log" 2>&1 &
	TAPID=$!
	PIDS+=("${TAPID}")
	L5=${D}/lin
	mkdir -p "${L5}/loop" "${L5}/goals" "${L5}/work"
	printf -- '- [ ] a goal\n' > "${L5}/goals/GOALS.md"
	LIN_ENV=(AUTONOMY_LOOP_DIR="${L5}/loop" AUTONOMY_LOOP_GOALS="${L5}/goals/GOALS.md" AUTONOMY_LOOP_WORKDIR="${L5}/work"
		AUTONOMY_LOOP_INTERVAL=2 AUTONOMY_LOOP_FIRE_TIMEOUT=10)
	# fire 1 runs 8 s (rc 0), fire 2 exits 3 at once, fire 3 sleeps past the 10 s timeout, fire 4 is ended by --now
	echo 'STUB_RC=0; STUB_OUT="fire output"; STUB_AGENT=; STUB_PLAN="8:0 0:3 30:0 60:0"' > "${STUB_CONF}"
	env "${LIN_ENV[@]}" "${AGENT_DIR}/loop-start.sh" > "${D}/lin-start.log" 2>&1 || fail "loop-start.sh: $(cat "${D}/lin-start.log")"
	grep -q "tmux lineage: session 'agent-loop' (parent operator)" "${D}/lin-start.log" || fail "loop-start.sh gave the loop no session: $(cat "${D}/lin-start.log")"
	LPID=$(grep -o 'started pid=[0-9]*' "${D}/lin-start.log" | cut -d= -f2)
	wait_session agent-loop-fire-1 || fail "no session for the live fire 1: $(tmux ls 2>&1)"
	LIN=$(ta lineage 2>&1)
	lineage_ok "${LIN}" 1 || fail "tmux-agent lineage does not show operator -> agent-loop -> agent-loop-fire-1: ${LIN}"
	FLEET=""
	for i in $(seq 1 10); do
		FLEET=$(ta_api /api/fleet | python3 -c 'import json, sys; print(" ".join(sorted("%s<-%s" % (s["session"], s.get("parent")) for s in json.load(sys.stdin)["sessions"])))' 2> /dev/null)
		echo "${FLEET}" | grep -q "agent-loop-fire-1<-agent-loop" && break
		sleep 1
	done
	echo "${FLEET}" | grep -q "agent-loop<-operator" && echo "${FLEET}" | grep -q "agent-loop-fire-1<-agent-loop" \
		|| fail "the dashboard's /api/fleet does not have the loop under operator and the fire under the loop: ${FLEET}"
	# the fire ends: its session closes, the history keeps it with the loop as its parent
	wait_line "${L5}/loop/loop.log" "FIRE 1 END rc=0" || fail "fire 1 did not end"
	gone_session agent-loop-fire-1 || fail "fire 1's session outlived the fire"
	HIST=""
	for i in $(seq 1 10); do
		HIST=$(ta_api /api/history | python3 -c 'import json, sys
for r in json.load(sys.stdin)["sessions"]:
    if r["session"].startswith("agent-loop"):
        print("%s parent=%s live=%s spawned=%s ended=%s" % (r["session"], r["parent"], r["live"], bool(r["spawnedAt"]), bool(r["killedAt"])))' 2> /dev/null)
		echo "${HIST}" | grep -q "^agent-loop-fire-1 parent=agent-loop live=False spawned=True ended=True" && break
		sleep 1
	done
	echo "${HIST}" | grep -q "^agent-loop-fire-1 parent=agent-loop live=False spawned=True ended=True" \
		&& echo "${HIST}" | grep -q "^agent-loop parent=operator live=True spawned=True" \
		|| fail "the dashboard's history does not keep the ended fire under the loop and the live loop under operator: ${HIST}"
	echo "ok 5 - tmux-agent lineage: $(echo "${LIN}" | grep -P '^agent-loop' | cut -f1,2 | tr '\t\n' ' '); /api/fleet: ${FLEET}; history: $(echo "${HIST}" | tr '\n' ';')"
	# the fire semantics with the lineage on: rc as the fire exits, the timeout's 124, then --now
	wait_line "${L5}/loop/loop.log" "FIRE 2 END rc=3" || fail "fire 2's rc 3 was not logged as it exited: $(tail -3 "${L5}/loop/loop.log")"
	wait_line "${L5}/loop/loop.log" "FIRE 3 END rc=124" 60 || fail "fire 3 did not end with the timeout's rc 124: $(tail -3 "${L5}/loop/loop.log")"
	DUR3=$(sed -nE 's/.*FIRE 3 END rc=124 duration=([0-9]+)s.*/\1/p' "${L5}/loop/loop.log")
	[ "${DUR3}" -ge 10 ] && [ "${DUR3}" -le 14 ] || fail "fire 3 ran ${DUR3}s, not its 10 s timeout"
	wait_session agent-loop-fire-4 || fail "no session for the live fire 4"
	STUB4=$(pgrep -f "${D}/stub-claude" | head -1)
	[ -n "${STUB4}" ] || fail "fire 4's stub claude is not running"
	env "${LIN_ENV[@]}" "${AGENT_DIR}/loop-stop.sh" --now > "${D}/lin-stop.log" 2>&1 || fail "loop-stop.sh --now: $(cat "${D}/lin-stop.log")"
	kill -0 "${LPID}" 2> /dev/null && fail "loop-stop.sh --now left the loop (pid ${LPID}) running"
	for i in $(seq 1 10); do kill -0 "${STUB4}" 2> /dev/null || break; sleep 0.5; done
	kill -0 "${STUB4}" 2> /dev/null && fail "loop-stop.sh --now left fire 4 (stub pid ${STUB4}) running"
	gone_session agent-loop-fire-4 && gone_session agent-loop || fail "the loop's sessions outlived the loop: $(tmux ls 2>&1)"
	env "${LIN_ENV[@]}" "${AGENT_DIR}/loop-status.sh" > "${D}/lin-status.log" 2>&1 && fail "loop-status.sh still reports the loop running: $(cat "${D}/lin-status.log")"
	HOLD=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import importlib.util as u; s = u.spec_from_file_location("lv", sys.argv[2]); m = u.module_from_spec(s); s.loader.exec_module(m); print(m.lock_holders(sys.argv[3]))' \
		"${AGENT_DIR}" "${VIEW}" "${L5}/loop/loop.lock")
	[ "${HOLD}" == "[]" ] || fail "a process still holds the loop's lock after --now: ${HOLD}"
	tmux has-session -t "=agent" 2> /dev/null || fail "--now took the tmux server (and the agent session) down with the loop"
	echo "ok 5 - with the lineage on: fire 2 logged rc 3, fire 3 ended rc 124 after ${DUR3}s (timeout 10), --now ended the loop and fire 4, its sessions closed, no lock holder, the agent session lives"
	# CONTROL: the same lineage check with AUTONOMY_LOOP_TMUX_LINEAGE=false fails
	L6=${D}/nolin
	mkdir -p "${L6}/loop" "${L6}/goals" "${L6}/work"
	printf -- '- [ ] a goal\n' > "${L6}/goals/GOALS.md"
	echo 'STUB_RC=0; STUB_OUT="fire output"; STUB_AGENT=; STUB_PLAN="30:0"' > "${STUB_CONF}"
	env AUTONOMY_LOOP_DIR="${L6}/loop" AUTONOMY_LOOP_GOALS="${L6}/goals/GOALS.md" AUTONOMY_LOOP_WORKDIR="${L6}/work" AUTONOMY_LOOP_INTERVAL=2 \
		AUTONOMY_LOOP_TMUX_LINEAGE=false "${AGENT_DIR}/loop-start.sh" > "${D}/nolin-start.log" 2>&1 || fail "loop-start.sh (control)"
	grep -q "tmux lineage: off" "${D}/nolin-start.log" || fail "CONTROL: loop-start.sh did not report the lineage off: $(cat "${D}/nolin-start.log")"
	wait_line "${L6}/loop/loop.log" "FIRE 1 BEGIN" || fail "the control loop did not fire"
	sleep 3
	CLIN=$(ta lineage 2>&1)
	lineage_ok "${CLIN}" 1 && fail "CONTROL: with AUTONOMY_LOOP_TMUX_LINEAGE=false the lineage check still passed: ${CLIN}"
	AUTONOMY_LOOP_DIR="${L6}/loop" "${AGENT_DIR}/loop-stop.sh" --now > /dev/null 2>&1
	echo "ok 5 - control: with AUTONOMY_LOOP_TMUX_LINEAGE=false tmux-agent lineage has no loop and no fire ($(echo "${CLIN}" | cut -f1 | tr '\n' ' '))"
	# A last fire that sets the STOP flag itself, as an agent whose goals are all done does: loop.sh logs its END and
	# LOOP STOPPED and exits in the same second, between two reads of the loop's pane. The fire must still close in the
	# dashboard's ledger with its rc, not as a fire the loop's exit cut off.
	# stop_fire <loop-lineage.sh> <dir>: one such loop, with a ledger of its own; prints the data of the fire's
	# session.killed lines (a JSON list) once the loop has stopped and its session has closed
	stop_fire()
	{
		mkdir -p "$2/loop" "$2/goals" "$2/work" "$2/tah"
		printf -- '- [ ] the last goal\n' > "$2/goals/GOALS.md"
		echo 'STUB_RC=0; STUB_OUT="all goals done"; STUB_AGENT=; STUB_PLAN="3:0"; STUB_STOP=1' > "${STUB_CONF}"
		env AUTONOMY_LOOP_DIR="$2/loop" AUTONOMY_LOOP_GOALS="$2/goals/GOALS.md" AUTONOMY_LOOP_WORKDIR="$2/work" \
			AUTONOMY_LOOP_INTERVAL=2 TMUX_AGENT_HOME="$2/tah" LOOP_LINEAGE_BIN="$1" "${AGENT_DIR}/loop-start.sh" > "$2/start.log" 2>&1 \
			|| { echo "loop-start.sh: $(cat "$2/start.log")"; return 1; }
		wait_line "$2/loop/loop.log" "LOOP STOPPED" 60 || { echo "the loop did not stop on its fire's flag: $(tail -3 "$2/loop/loop.log")"; return 1; }
		gone_session agent-loop || { echo "the loop's session outlived the loop: $(tmux ls 2>&1)"; return 1; }
		python3 -c 'import json, os, sys
d = sys.argv[1]
rows = [json.loads(l) for f in sorted(os.listdir(d)) for l in open(os.path.join(d, f))]
print(json.dumps([r["data"] for r in rows if r["type"] == "session.killed" and r["session"] == "agent-loop-fire-1"], sort_keys=True))' "$2/tah/ledger"
	}
	SF=$(stop_fire "${AGENT_DIR}/loop-lineage.sh" "${D}/stopfire") || fail "the fire that set the STOP flag: ${SF}"
	echo "${SF}" | python3 -c 'import json, sys; k = json.load(sys.stdin); sys.exit(0 if len(k) == 1 and k[0].get("rc") == 0 and "reason" not in k[0] else 1)' \
		|| fail "a last fire that set the STOP flag did not close with its rc 0 in the dashboard's ledger: ${SF}"
	# CONTROL: the pane without its final read of the log. Whether that copy sees the END depends on timing (a 2 s read
	# landing in the milliseconds between the END line and the loop's exit), so it runs up to twice and must fail once
	python3 - "${AGENT_DIR}/loop-lineage.sh" "${D}/mutant-lineage.sh" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = '\tread_new_lines\n\techo\n\techo "the loop (pid'
assert anchor in s, "the pane's final read is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, '\techo\n\techo "the loop (pid'))
PY
	chmod +x "${D}/mutant-lineage.sh"
	MSF=""
	for T in 1 2; do
		MSF=$(stop_fire "${D}/mutant-lineage.sh" "${D}/stopfire-mutant-${T}") || fail "the fire that set the STOP flag (control run ${T}): ${MSF}"
		echo "${MSF}" | grep -qF '"reason": "the loop exited during this fire"' && ! echo "${MSF}" | grep -qF '"rc"' && break
		MSF=""
	done
	[ -n "${MSF}" ] || fail "CONTROL: a pane without its final read closed the STOP-flag fire with its rc in both runs"
	echo "ok 5 - a last fire that set the STOP flag closes with its rc: ${SF}; control: a pane without its final read closes it as ${MSF}"
	# The ledger lines go where the RUNNING dashboard reads its ledger. ui-start.sh decides the dashboard's TMUX_AGENT_HOME
	# (it may set none), and the container starts the loop without one, so the lineage finds it from the dashboard's
	# process: the pid ui-start.sh records in ${UI_DIR}/tmux-agent.pid. The dashboard above runs with this test's.
	# home_fire <loop-lineage.sh> <dir> <session>: one loop (tmux session <session>, a name of its own per run) whose only
	# fire sets the STOP flag, started with no TMUX_AGENT_HOME, HOME <dir>/home and the dashboard's pid in <dir>/ui; prints
	# the ledger files that got its fire's session.killed line
	home_fire()
	{
		mkdir -p "$2/loop" "$2/goals" "$2/work" "$2/ui" "$2/home"
		printf -- '- [ ] the last goal\n' > "$2/goals/GOALS.md"
		echo "${TAPID}" > "$2/ui/tmux-agent.pid"
		echo 'STUB_RC=0; STUB_OUT="all goals done"; STUB_AGENT=; STUB_PLAN="3:0"; STUB_STOP=1' > "${STUB_CONF}"
		env -u TMUX_AGENT_HOME HOME="$2/home" UI_DIR="$2/ui" AUTONOMY_LOOP_TMUX_SESSION="$3" AUTONOMY_LOOP_DIR="$2/loop" \
			AUTONOMY_LOOP_GOALS="$2/goals/GOALS.md" AUTONOMY_LOOP_WORKDIR="$2/work" AUTONOMY_LOOP_INTERVAL=2 LOOP_LINEAGE_BIN="$1" \
			"${AGENT_DIR}/loop-start.sh" > "$2/start.log" 2>&1 || { echo "loop-start.sh: $(cat "$2/start.log")"; return 1; }
		wait_line "$2/loop/loop.log" "LOOP STOPPED" 60 || { echo "the loop did not stop: $(tail -3 "$2/loop/loop.log")"; return 1; }
		gone_session "$3" || { echo "the loop's session outlived the loop: $(tmux ls 2>&1)"; return 1; }
		grep -l "\"type\":\"session.killed\",\"session\":\"$3-fire-1\"" "${TMUX_AGENT_HOME}"/ledger/*.ndjson \
			"$2"/home/.tmux-agent/ledger/*.ndjson 2> /dev/null
		return 0
	}
	HF=$(home_fire "${AGENT_DIR}/loop-lineage.sh" "${D}/homefire" home-loop) || fail "the loop started without TMUX_AGENT_HOME: ${HF}"
	echo "${HF}" | grep -q "^${TMUX_AGENT_HOME}/ledger/" && ! echo "${HF}" | grep -q '/home/.tmux-agent/' \
		|| fail "a loop started without TMUX_AGENT_HOME did not write its ledger lines where the running dashboard reads them: [${HF}]"
	# CONTROL: a loop-lineage.sh copy that does not read the dashboard's process writes them to its own default
	python3 - "${AGENT_DIR}/loop-lineage.sh" "${D}/mutant-lineage-home.sh" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = "TMUX_AGENT_HOME=${TMUX_AGENT_HOME:-$(dashboard_home)}\n"
assert anchor in s, "the dashboard's home lookup is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, ""))
PY
	chmod +x "${D}/mutant-lineage-home.sh"
	MHF=$(home_fire "${D}/mutant-lineage-home.sh" "${D}/homefire-mutant" home-mutant) || fail "the control loop: ${MHF}"
	echo "${MHF}" | grep -q "^${TMUX_AGENT_HOME}/ledger/" \
		&& fail "CONTROL: a loop-lineage.sh copy that does not read the dashboard's process still wrote where it reads: [${MHF}]"
	echo "${MHF}" | grep -q '/home/.tmux-agent/ledger/' \
		|| fail "CONTROL: the copy without the read wrote its fire's line nowhere: [${MHF}]"
	echo "ok 5 - started without TMUX_AGENT_HOME, the loop's ledger lines land where the running dashboard reads them (${HF#${D}/}, found from its process); control: a copy without that read writes them to ${MHF#${D}/}"
fi

if ! command -v nginx > /dev/null; then
	echo "Test-loop-view skipped checks 6-9: nginx is not installed (setup/install-nginx.sh)"
	echo "Test-loop-view succeeded"
	exit 0
fi
H=http://127.0.0.1:${UI_PORT_HOME}
LH="loop.localhost:${UI_PORT_HOME}"
# serve <log> [<env>...] - the renderer over the stopped fixture on UI_PORT_LOOP, in the background; prints its pid
serve()
{
	local LOG=$1
	shift
	env AUTONOMY_LOOP_DIR="${F}/loop" AUTONOMY_LOOP_GOALS="${F}/goals/GOALS.md" UI_DIR="${D}/ui-serve" "$@" \
		python3 "${VIEW_BIN:-${VIEW}}" --port "${PORT:-${UI_PORT_LOOP}}" > "${LOG}" 2>&1 &
	echo $!
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
upto() { for i in $(seq 1 40); do [ "$(code "$2")" == "$1" ] && return 0; sleep 0.25; done; return 1; }

# --- 6. /__probe/loop: 204 while fresh; not 2xx with the renderer stopped, or with its data stale ---
env UI_DIR="${D}/probe-ui" "${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh"
nginx -t -c "${D}/probe-ui/home/nginx.conf" > "${D}/nginx-t.log" 2>&1 || fail "the rendered config does not pass nginx -t: $(cat "${D}/nginx-t.log")"
nginx -c "${D}/probe-ui/home/nginx.conf" -g "daemon off;" > "${D}/nginx-probe.log" 2>&1 &
PIDS+=($!)
printf '<script>window.__pwned=1</script><img src=x onerror="alert(1)"> and the rest of the fire output\n' > "${F}/loop/fires/fire-1.out"
V=$(serve "${D}/serve-1.log")
PIDS+=("${V}")
upto 204 "${H}/__probe/loop" || fail "the dot probe never answered 204 with the renderer up: $(code "${H}/__probe/loop"); $(cat "${D}/serve-1.log")"
[ "$(curl -s -o /dev/null -w '%{http_code} %{size_download}' --max-time 5 -H 'Cookie: planted=1' "${H}/__probe/loop")" == "204 0" ] \
	|| fail "the dot probe is not status-only"
[ "$(code -X POST "${H}/__probe/loop")" == "403" ] || fail "a POST to the dot probe was not refused"
kill "${V}"
for i in $(seq 1 20); do kill -0 "${V}" 2> /dev/null || break; sleep 0.25; done
P1=$(code "${H}/__probe/loop")
[ "${P1}" -ge 200 ] 2> /dev/null && [ "${P1}" -lt 300 ] && fail "CONTROL 1: with the renderer stopped the dot probe still answers ${P1}"
V=$(serve "${D}/serve-stale.log" LOOP_VIEW_INTERVAL=600 LOOP_VIEW_STALE_SECS=2)
PIDS+=("${V}")
upto 204 "${H}/__probe/loop" || fail "the stale-control renderer never answered fresh at first"
sleep 3
P2=$(code "${H}/__probe/loop")
[ "${P2}" -ge 200 ] 2> /dev/null && [ "${P2}" -lt 300 ] && fail "CONTROL 2: with its data stale the dot probe still answers ${P2}"
[ "$(code "http://127.0.0.1:${UI_PORT_LOOP}/health")" == "503" ] || fail "the stale renderer's /health is not 503"
kill "${V}"
for i in $(seq 1 20); do kill -0 "${V}" 2> /dev/null || break; sleep 0.25; done
echo "ok 6 - /__probe/loop 204 (status only, POST 403) while fresh; control 1: renderer stopped -> ${P1}; control 2: data stale -> ${P2} (/health 503)"

# --- 7. a transcript with <script> is text, never HTML ---
V=$(serve "${D}/serve-2.log")
PIDS+=("${V}")
upto 204 "${H}/__probe/loop" || fail "the renderer did not come back"
# tx_text_ok <headers+body file>: text/plain, nosniff, a sandboxing policy, the payload bytes intact, no badge injected
tx_text_ok()
{
	grep -qi '^content-type: text/plain' "$1" && grep -qi '^x-content-type-options: nosniff' "$1" \
		&& grep -qi "^content-security-policy: default-src 'none'; sandbox" "$1" \
		&& grep -qF '<script>window.__pwned=1</script><img src=x onerror="alert(1)">' "$1" && ! grep -q 'data-harness-home' "$1"
}
curl -s -D - --max-time 5 -H "Host: ${LH}" "${H}/transcripts/fire-1.out" > "${D}/tx.out"
tx_text_ok "${D}/tx.out" || fail "the transcript is not served as sandboxed plain text through the proxy: $(head -12 "${D}/tx.out")"
curl -s --max-time 5 -H "Host: ${LH}" "${H}/data.json" | grep -qF '<script>window.__pwned=1</script>' || fail "the page's data does not carry the transcript's first line as it is"
SINKS='innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|Function\(|srcdoc'
grep -nE "${SINKS}" "${AGENT_DIR}/loop-view/app.js" && fail "the page's script writes markup"
kill "${V}"
mkdir -p "${D}/mutant-html"
cp -r "${AGENT_DIR}/loop-view" "${D}/mutant-html/"
python3 - "${VIEW}" "${D}/mutant-html/loop-view.py" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = "self.send(200, body, \"text/plain; charset=utf-8\", {\"Content-Security-Policy\": \"default-src 'none'; sandbox\","
assert anchor in s, "the transcript response is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, "self.send(200, body, \"text/html; charset=utf-8\", {"))
PY
V=$(VIEW_BIN=${D}/mutant-html/loop-view.py serve "${D}/serve-mutant.log")
PIDS+=("${V}")
upto 204 "${H}/__probe/loop" || fail "the mutant renderer did not answer"
curl -s -D - --max-time 5 -H "Host: ${LH}" "${H}/transcripts/fire-1.out" > "${D}/tx-mutant.out"
tx_text_ok "${D}/tx-mutant.out" && fail "CONTROL: a renderer serving the transcript as text/html passed the plain-text check"
kill "${V}"
sed 's/n\.textContent = String(v);/n.innerHTML = String(v);/' "${AGENT_DIR}/loop-view/app.js" > "${D}/app-mutant.js"
cmp -s "${AGENT_DIR}/loop-view/app.js" "${D}/app-mutant.js" && fail "could not plant the innerHTML control (the text setter moved)"
grep -qE "${SINKS}" "${D}/app-mutant.js" || fail "CONTROL: an app.js writing innerHTML passed the sink check"
echo "ok 7 - the <script> transcript is sandboxed text/plain (nosniff, bytes intact, no badge); app.js has no HTML sink; controls: text/html served and an innerHTML app.js both fail"

# --- 8. the badge through the proxy, and the policy that admits exactly its inline parts ---
V=$(serve "${D}/serve-3.log")
PIDS+=("${V}")
upto 204 "${H}/__probe/loop" || fail "the renderer did not come back"
# badge_ok <url> <host>: the page carries the badge once, returning to //localhost:<port>/; the badge's style
# attribute, its phone-width <style> rule and its keeper <script> are the page's only inline parts, and the route's
# policy allows each by its sha256
badge_ok()
{
	curl -s -D "${D}/badge.h" -o "${D}/badge.html" --max-time 5 -H "Host: $2" "$1/"
	python3 - "${D}/badge.h" "${D}/badge.html" "${2#*:}" << 'PY'
import base64, hashlib, re, sys
head, page, port = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
csp = next((l.split(":", 1)[1].strip() for l in head.splitlines() if l.lower().startswith("content-security-policy:")), "")
h = lambda s: "'sha256-%s'" % base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()
m = re.search(r'<a class="hs-badge" data-harness-home href="([^"]*)" title="do-agent-aws harness home" '
              r'id="do-agent-aws-home" target="do-agent-aws-home" style="([^"]*)">&#8962; home</a>'
              r'<style id="do-agent-aws-home-style">([^<]*)</style><script>([^<]*)</script>', page)
if page.count("data-harness-home") != 1 or not m:
    sys.exit("the badge is not in the page exactly once (%d)" % page.count("data-harness-home"))
inline = len(re.findall(r"<script(?![^>]*\bsrc=)[^>]*>", page)) + page.count("<style") + page.count("style=")
if inline != 3:
    sys.exit("the page carries %d inline parts (want the badge's three: its style attribute, rule and script)" % inline)
if m.group(1) != "//localhost:%s/" % port:
    sys.exit("the badge returns to %s" % m.group(1))
style = re.search(r"style-src ([^;]*)", csp)
if not (style and "'unsafe-hashes'" in style.group(1) and h(m.group(2)) in style.group(1)):
    sys.exit("the route's policy does not allow the badge's style attribute by hash: %s" % csp)
if h(m.group(3)) not in style.group(1):
    sys.exit("the route's policy does not allow the badge's phone-width rule by hash: %s" % csp)
script = re.search(r"script-src ([^;]*)", csp)
if not (script and h(m.group(4)) in script.group(1)):
    sys.exit("the route's policy does not allow the badge's keeper script by hash: %s" % csp)
if "'unsafe-inline'" in csp or "http" in csp:
    sys.exit("the route's policy is wider than its own origin: %s" % csp)
print("badge once, back to //localhost:%s/, its three inline parts (the page's only ones) each allowed by its hash" % port)
PY
}
B=$(badge_ok "${H}" "${LH}" 2>&1) || fail "${B}"
mkdir -p "${D}/mutant-home"
python3 - "${AGENT_DIR}/home-render.sh" "${D}/mutant-home/home-render.sh" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = "\t\t\tproxy_pass http://127.0.0.1:${UI_PORT_LOOP};\n\t\t\tinclude ${HOME_DIR}/proxy-common.conf;\n$(host_redirect_rules \"${UI_PORT_LOOP}\")\n\t\t\tinclude ${HOME_DIR}/badge-host-nolink.conf;\n\t\t\tproxy_hide_header"
assert anchor in s, "the loop route's badge include is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, anchor.replace("\t\t\tinclude ${HOME_DIR}/badge-host-nolink.conf;\n", "")))
PY
env UI_DIR="${D}/mutant-ui" UI_PORT_HOME=18794 bash "${D}/mutant-home/home-render.sh" > /dev/null || fail "the mutant home-render.sh did not render"
nginx -c "${D}/mutant-ui/home/nginx.conf" -g "daemon off;" > "${D}/nginx-mutant.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 20); do [ "$(code "http://127.0.0.1:18794/")" == "200" ] && break; sleep 0.25; done
MB=$(badge_ok "http://127.0.0.1:18794" "loop.localhost:18794" 2>&1) && fail "CONTROL: without the route's badge include the badge check passed: ${MB}"
# CONTROL: a policy without the keeper script's hash - the badge would lose its keeper here and the browser would log
# the refusal - must fail the check
mkdir -p "${D}/mutant-csp"
python3 - "${AGENT_DIR}/home-render.sh" "${D}/mutant-csp/home-render.sh" << 'PY' || fail "CONTROL: the policy mutant could not be planted"
import sys
s = open(sys.argv[1]).read()
anchor = "BADGE_SCRIPT_SRC=\"'${BADGE_KEEPER_SHA}'\"\n"
assert s.count(anchor) == 1, "the badge's script source is not defined where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, "BADGE_SCRIPT_SRC=\"\"\n"))
PY
env UI_DIR="${D}/mutant-csp-ui" UI_PORT_HOME=18789 bash "${D}/mutant-csp/home-render.sh" > /dev/null || fail "the policy mutant did not render"
nginx -c "${D}/mutant-csp-ui/home/nginx.conf" -g "daemon off;" > "${D}/nginx-mutant-csp.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 20); do [ "$(code "http://127.0.0.1:18789/")" == "200" ] && break; sleep 0.25; done
MK=$(badge_ok "http://127.0.0.1:18789" "loop.localhost:18789" 2>&1) && fail "CONTROL: a policy without the keeper's hash passed the badge check: ${MK}"
case "${MK}" in *"keeper script by hash"*) ;; *) fail "CONTROL: the policy mutant failed for another reason: ${MK}" ;; esac
# the harness stylesheet on the route: its bytes as text/css, linked once by the page itself (the badge include adds none)
SHEET="${AGENT_DIR}/ui/harness.css"
[ -f "${SHEET}" ] || fail "no ${SHEET}: the page draws its look from the harness design system, which must be beneath it"
LINK='<link rel="stylesheet" href="/__harness/harness.css">'
# sheet_ok <base url> <host>: exit 0 when the route answers the stylesheet with its bytes as text/css; prints what it got
sheet_ok()
{
	curl -s --max-time 5 -D "${D}/sheet.h" -o "${D}/sheet.css" -H "Host: $2" "$1/__harness/harness.css"
	if grep -qi '^content-type: text/css' "${D}/sheet.h" && [ "$(sha256sum < "${D}/sheet.css")" == "$(sha256sum < "${SHEET}")" ]; then
		echo "the stylesheet served with its bytes as text/css"
		return 0
	fi
	echo "not the stylesheet: $(head -1 "${D}/sheet.h" | tr -d '\r')"
	return 1
}
SO=$(sheet_ok "${H}" "${LH}") || fail "the loop route does not serve the harness stylesheet: ${SO}"
NL=$(curl -s --max-time 5 -H "Host: ${LH}" "${H}/" | grep -oF "${LINK}" | wc -l)
[ "${NL}" == "1" ] || fail "through the proxy the page carries the stylesheet link ${NL} times (want exactly 1)"
mkdir -p "${D}/mutant-css"
python3 - "${AGENT_DIR}/home-render.sh" "${D}/mutant-css/home-render.sh" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = "\t\tserver_name loop.localhost;\n\t\tif (\\$foreign_origin) { return 403; }\n\t\tset \\$proxy_upstream_host \\$http_host;\n$(harness_css_location)\n"
assert anchor in s, "the loop route's stylesheet location is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, anchor.replace("$(harness_css_location)\n", "")))
PY
env UI_DIR="${D}/mutant-css-ui" UI_PORT_HOME=18797 bash "${D}/mutant-css/home-render.sh" > /dev/null || fail "the stylesheet mutant did not render"
nginx -c "${D}/mutant-css-ui/home/nginx.conf" -g "daemon off;" > "${D}/nginx-mutant-css.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 20); do [ "$(code "http://127.0.0.1:18797/")" == "200" ] && break; sleep 0.25; done
MS=$(sheet_ok "http://127.0.0.1:18797" "loop.localhost:18797") && fail "CONTROL: without the route's stylesheet location the stylesheet was still served: ${MS}"
kill "${V}"
echo "ok 8 - ${B}; control: without its include -> ${MB}; control: without the keeper's hash -> ${MK}; ${SO}, the page links it once; control: without the route's stylesheet location -> ${MS}"

# --- 9. ui-start.sh / ui-status.sh / ui-stop.sh, and UI_LOOP=false ---
(
	export UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false \
		UI_LOGLEARNER=false UI_LOOP_DECK=false UI_FILES=false COMMS_UI_ENABLED=false UI_HOME=true UI_LOOP=true UI_PORT_LOOP=18795 \
		UI_PORT_HOME=18796 \
		AUTONOMY_LOOP_DIR="${F}/loop" UI_DIR="${D}/ui"
	"${AGENT_DIR}/ui-start.sh" > "${D}/ui-start.log" 2>&1 || { cat "${D}/ui-start.log"; exit 11; }
	for i in $(seq 1 40); do "${AGENT_DIR}/ui-status.sh" > "${D}/ui-status.log" 2>&1 && break; sleep 0.25; done
	grep -q "^loop-view: UP pid=[0-9]* http=200 port=18795" "${D}/ui-status.log" || { cat "${D}/ui-status.log"; exit 12; }
	ADDRS=$(ss -ltnH "sport = :18795" | awk '{print $4}')
	[ "${ADDRS}" == "127.0.0.1:18795" ] || { echo "the renderer listens on: ${ADDRS}"; exit 13; }
	grep -qE '<li class="tile" data-host="loop" data-probe="/__probe/loop" data-path="/"><span class="dot"></span><a [^>]*>Agent loop</a>' \
		"${D}/ui/home/site/index.html" || exit 14
	[ "$(code -H "Host: loop.localhost:18796" "http://127.0.0.1:18796/")" == "200" ] || exit 15
	"${AGENT_DIR}/ui-stop.sh" > "${D}/ui-stop.log" 2>&1
	grep -q "^loop-view: stopped" "${D}/ui-stop.log" || { cat "${D}/ui-stop.log"; exit 16; }
	[ -f "${D}/ui/loop-view.pid" ] && exit 17
	[ "$(code "http://127.0.0.1:18795/health")" == "000" ] || exit 18
	export UI_LOOP=false
	"${AGENT_DIR}/home-render.sh" > /dev/null || exit 19
	grep -q "server_name loop.localhost" "${D}/ui/home/nginx.conf" && exit 20
	grep -q "/__probe/loop" "${D}/ui/home/nginx.conf" && exit 21
	grep -q "off - set UI_LOOP=true in .env" "${D}/ui/home/site/index.html" || exit 22
	exit 0
)
RC=$?
[ "${RC}" == "0" ] || fail "ui-start/status/stop with UI_LOOP (step ${RC}): $(tail -5 "${D}/ui-start.log" "${D}/ui-status.log" 2> /dev/null)"
echo "ok 9 - ui-start.sh serves the renderer on 127.0.0.1 only, ui-status.sh: $(grep '^loop-view:' "${D}/ui-status.log"), the tile is live and its host route answers 200, ui-stop.sh stops it; UI_LOOP=false: no route, no probe, a greyed tile"

# --- 10. the Control section: Run next fire and Pause loop answer with the loop's state read back ---
if [ ! -x /agent/loop.sh ]; then
	echo "Test-loop-view skipped check 10: it needs the image's /agent/loop.sh (loop-start.sh starts that one)"
else
	C10=${D:?}/ctl
	mkdir -p "${C10}/loop" "${C10}/goals" "${C10}/work"
	printf -- '- [ ] a goal\n' > "${C10}/goals/GOALS.md"
	echo 'STUB_RC=0; STUB_OUT="fire output"; STUB_AGENT=; STUB_PLAN="8:0 8:0 8:0 8:0"' > "${STUB_CONF}"
	CTL_ENV=(AUTONOMY_LOOP_DIR="${C10}/loop" AUTONOMY_LOOP_GOALS="${C10}/goals/GOALS.md" AUTONOMY_LOOP_WORKDIR="${C10}/work"
		AUTONOMY_LOOP_INTERVAL=2 AUTONOMY_LOOP_TMUX_LINEAGE=false UI_DIR="${D}/ui-ctl")
	# ctl_serve <log> <renderer> [<env>...]: a renderer over C10 on UI_PORT_LOOP, behind the probe proxy of check 6
	ctl_serve()
	{
		local LOG=$1 BIN=$2
		shift 2
		env "${CTL_ENV[@]}" "$@" python3 "${BIN}" --port "${UI_PORT_LOOP}" > "${LOG}" 2>&1 &
		echo $!
	}
	ctl_stop() { kill "$1" 2> /dev/null; for i in $(seq 1 20); do kill -0 "$1" 2> /dev/null || return 0; sleep 0.25; done; }
	# act <action> [<curl args>...]: a POST through the proxy as the page sends it; prints "<http code> <json answer>"
	act()
	{
		local A=$1
		shift
		local CODE
		CODE=$(curl -s --max-time 90 -o "${D}/act.json" -w '%{http_code}' -X POST -H "Host: ${LH}" "$@" "${H}/control/${A}")
		echo "${CODE} $(cat "${D}/act.json" 2> /dev/null)"
	}
	PAGE_HDRS=(-H "Origin: http://${LH}" -H 'X-Loop-Control: 1')
	field() { python3 -c 'import json, sys; d = json.loads(sys.argv[1].split(" ", 1)[1]); print(eval(sys.argv[2]))' "$1" "$2" 2> /dev/null; }
	waitfor() { for i in $(seq 1 "${3:-60}"); do grep -q "$2" "$1" 2> /dev/null && return 0; sleep 0.5; done; return 1; }
	# the renderer copies the controls use: one answering from the scripts' exit codes instead of the state it reads
	# back, one without the page-header check; each beside copies of the loop scripts its actions run
	for M in readback header; do
		mkdir -p "${D}/mutant-${M}"
		cp -r "${AGENT_DIR}/loop-view" "${AGENT_DIR}/loop-start.sh" "${AGENT_DIR}/loop-stop.sh" "${AGENT_DIR}/loop-lineage.sh" "${D}/mutant-${M}/"
	done
	python3 - "${VIEW}" "${D}/mutant-readback/loop-view.py" "${D}/mutant-header/loop-view.py" << 'PY'
import sys
s = open(sys.argv[1]).read()
r = s
for anchor in ('ok = after["state"] == "running" and not after["stop_flag"]  # done only when the loop runs, read back',
               'ok = after["stop_flag"]  # done only when STOP is a file the loop sees, read back'):
    assert anchor in r, "the read-back decision is not where the control expects it"
    r = r.replace(anchor, "ok = rc == 0")
open(sys.argv[2], "w").write(r)
anchor = 'if self.headers.get("X-Loop-Control") != "1":'
assert anchor in s, "the header check is not where the control expects it"
open(sys.argv[3], "w").write(s.replace(anchor, "if False:"))
PY
	V=$(ctl_serve "${D}/serve-ctl.log" "${VIEW}")
	PIDS+=("${V}")
	upto 204 "${H}/__probe/loop" || fail "the control renderer did not answer: $(cat "${D}/serve-ctl.log")"
	# a. Run on a loop that never started: done, read back running - and the loop really fires
	R1=$(act run "${PAGE_HDRS[@]}")
	[ "$(field "${R1}" 'd["result"]')" == "done" ] && [ "$(field "${R1}" 'd["after"]["state"]')" == "running" ] \
		|| fail "Run next fire on a loop that never started did not answer done, running: ${R1}"
	waitfor "${C10}/loop/loop.log" "FIRE 1 BEGIN" || fail "after Run next fire the loop did not fire"
	# b. Pause while it runs: done, STOP a file - and the loop halts on it
	P1=$(act pause "${PAGE_HDRS[@]}")
	[ "$(field "${P1}" 'd["result"]')" == "done" ] && [ "$(field "${P1}" 'd["after"]["stop_flag"]')" == "True" ] && [ -f "${C10}/loop/STOP" ] \
		|| fail "Pause loop while it runs did not answer done with the STOP flag set: ${P1}"
	# b2. Run next fire again while that fire is still in flight: loop-start.sh leaves the running loop and its flag alone
	# (exit 0), so the answer is failed, read back running with the STOP flag set - not done
	R3=$(act run "${PAGE_HDRS[@]}")
	[ "$(field "${R3}" 'd["result"]')" == "failed" ] && [ "$(field "${R3}" 'd["after"]["state"]')" == "running" ] \
		&& [ "$(field "${R3}" 'd["after"]["stop_flag"]')" == "True" ] && [ "$(field "${R3}" 'd["rc"]')" == "0" ] \
		&& [ "$(field "${R3}" '"STOP flag still set" in d["message"]')" == "True" ] \
		|| fail "Run next fire while a paused loop finishes its fire did not answer failed with the STOP flag still set: ${R3}"
	waitfor "${C10}/loop/loop.state" "^STOPPED reason=stop-flag" 40 || fail "after Pause loop the loop did not halt: $(cat "${C10}/loop/loop.state")"
	# c./d. planted states the scripts report as fine: a lock held by a process that is not the loop (loop-start.sh says
	# "already running" and exits 0) and a STOP that is a directory (loop-stop.sh's touch succeeds on it)
	# (the loop writes its STOPPED line before it exits: the lock is planted once the loop has let it go, and checked)
	for i in $(seq 1 40); do flock -n "${C10}/loop/loop.lock" true 2> /dev/null && break; sleep 0.25; done
	( exec 9> "${C10}/loop/loop.lock"; flock -n 9 && exec sleep 120 ) &
	HOLDER=$!
	PIDS+=("${HOLDER}")
	rm -f "${C10:?}/loop/STOP"
	mkdir "${C10}/loop/STOP"
	sleep 0.5
	flock -n "${C10}/loop/loop.lock" true 2> /dev/null && fail "could not plant the lock no loop holds: it is free"
	R2=$(act run "${PAGE_HDRS[@]}")
	[ "$(field "${R2}" 'd["result"]')" == "failed" ] && [ "$(field "${R2}" 'd["after"]["state"]')" == "stale" ] && [ "$(field "${R2}" 'd["rc"]')" == "0" ] \
		|| fail "Run next fire with a lock no loop holds did not answer failed although loop-start.sh exited 0: ${R2}"
	P2=$(act pause "${PAGE_HDRS[@]}")
	[ "$(field "${P2}" 'd["result"]')" == "failed" ] && [ "$(field "${P2}" 'd["after"]["stop_kind"]')" == "directory" ] && [ "$(field "${P2}" 'd["rc"]')" == "0" ] \
		|| fail "Pause loop with STOP a directory did not answer failed although loop-stop.sh exited 0: ${P2}"
	# the requests the page never sends: no X-Loop-Control header, another origin, a GET
	N1=$(act pause -H "Origin: http://${LH}")
	N2=$(act pause -H "Origin: http://elsewhere.example" -H 'X-Loop-Control: 1')
	N3=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${LH}" "${H}/control/pause")
	[ "${N1%% *}" == "403" ] && [ "${N2%% *}" == "403" ] && [ "${N3}" -ge 400 ] 2> /dev/null \
		|| fail "a request the page never sends was not refused: no header ${N1%% *}, another origin ${N2%% *}, GET ${N3}"
	ctl_stop "${V}"
	# CONTROL 1: a renderer answering from the exit codes calls both planted states done
	V=$(ctl_serve "${D}/serve-ctl-m1.log" "${D}/mutant-readback/loop-view.py")
	PIDS+=("${V}")
	upto 204 "${H}/__probe/loop" || fail "the read-back mutant did not answer"
	MR=$(act run "${PAGE_HDRS[@]}")
	MP=$(act pause "${PAGE_HDRS[@]}")
	[ "$(field "${MR}" 'd["result"]')" != "failed" ] && [ "$(field "${MP}" 'd["result"]')" != "failed" ] \
		|| fail "CONTROL: a renderer trusting the scripts' exit codes still answered failed: run ${MR}; pause ${MP}"
	ctl_stop "${V}"
	# CONTROL 2: without the header check a request with no X-Loop-Control header runs the action
	V=$(ctl_serve "${D}/serve-ctl-m2.log" "${D}/mutant-header/loop-view.py")
	PIDS+=("${V}")
	upto 204 "${H}/__probe/loop" || fail "the header mutant did not answer"
	MH=$(act pause -H "Origin: http://${LH}")
	[ "${MH%% *}" == "200" ] || fail "CONTROL: a renderer without the header check still refused a request without the header: ${MH}"
	ctl_stop "${V}"
	kill "${HOLDER}" 2> /dev/null
	rmdir "${C10:?}/loop/STOP"
	# UI_LOOP_CONTROL=false: the proxy writes no control route (CONTROL: the default render of check 6 has it), the
	# renderer refuses both actions, and the page's data says the controls are off
	CTL_ROUTE='location ~ ^(/loop/autonomy-loop)?/control/(run|pause)$ {'
	env UI_DIR="${D}/ctl-off-ui" UI_LOOP_CONTROL=false "${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh with UI_LOOP_CONTROL=false"
	ROUTES="$(grep -cF -- "${CTL_ROUTE}" "${D}/probe-ui/home/nginx.conf") $(grep -cF -- "${CTL_ROUTE}" "${D}/ctl-off-ui/home/nginx.conf")"
	[ "${ROUTES}" == "1 0" ] || fail "the control route is not written exactly when UI_LOOP_CONTROL is on (on, off): ${ROUTES}"
	V=$(ctl_serve "${D}/serve-ctl-off.log" "${VIEW}" UI_LOOP_CONTROL=false)
	PIDS+=("${V}")
	upto 204 "${H}/__probe/loop" || fail "the control-off renderer did not answer"
	OFF=$(act run "${PAGE_HDRS[@]}")
	[ "${OFF%% *}" == "403" ] && [ "$(curl -s --max-time 5 -H "Host: ${LH}" "${H}/data.json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["control"]["enabled"])')" == "False" ] \
		|| fail "with UI_LOOP_CONTROL=false Run next fire was not refused or the data does not say the controls are off: ${OFF}"
	ctl_stop "${V}"
	echo "ok 10 - Run next fire: $(field "${R1}" 'd["result"]') (read back $(field "${R1}" 'd["after"]["state"]')); Pause loop: $(field "${P1}" 'd["result"]') (STOP a file, the loop halted); Run next fire before it halted: $(field "${R3}" 'd["result"]') (running, STOP still set); planted: a lock no loop holds -> run $(field "${R2}" 'd["result"]') although loop-start.sh exited 0, STOP a directory -> pause $(field "${P2}" 'd["result"]') although loop-stop.sh exited 0; no header ${N1%% *}, another origin ${N2%% *}, GET ${N3}; UI_LOOP_CONTROL=false: no proxy route, renderer ${OFF%% *}; controls: exit codes trusted -> run $(field "${MR}" 'd["result"]'), pause $(field "${MP}" 'd["result"]'); no header check -> ${MH%% *}"
fi

# --- 11. one page per loop: /loop/<loop-id>/; what a loop row of Loop Deck opens, in the README ---
V=$(serve "${D}/serve-11.log")
PIDS+=("${V}")
upto 204 "${H}/__probe/loop" || fail "the renderer did not come back for check 11"
# route_ok <base url> <host>: prints what the per-loop addresses answered; exit 1 at the first that does not hold
route_ok()
{
	local B=$1 HH=$2 C R
	curl -s --max-time 5 -o "${D}/r11-root.html" -H "Host: ${HH}" "${B}/"
	C=$(curl -s --max-time 5 -o "${D}/r11-loop.html" -w '%{http_code}' -H "Host: ${HH}" "${B}/loop/autonomy-loop/")
	[ "${C}" == "200" ] && cmp -s "${D}/r11-root.html" "${D}/r11-loop.html" || { echo "/loop/autonomy-loop/ answered ${C}, not the page / serves"; return 1; }
	R=$(curl -s --max-time 5 -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: ${HH}" "${B}/loop/autonomy-loop")
	[ "${R%% *}" == "301" ] && [ "${R%/loop/autonomy-loop/}" != "${R}" ] || { echo "/loop/autonomy-loop answered ${R}, not a redirect to /loop/autonomy-loop/"; return 1; }
	[ "$(curl -s --max-time 5 -H "Host: ${HH}" "${B}/loop/autonomy-loop/data.json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["hub"]["loop_dir"])' 2> /dev/null)" == "${F}/loop" ] \
		|| { echo "/loop/autonomy-loop/data.json is not the autonomy loop's data"; return 1; }
	curl -s -D - --max-time 5 -H "Host: ${HH}" "${B}/loop/autonomy-loop/transcripts/fire-1.out" > "${D}/r11-tx.out"
	tx_text_ok "${D}/r11-tx.out" || { echo "a transcript under /loop/autonomy-loop/ is not sandboxed plain text: $(grep -i '^content-security-policy' "${D}/r11-tx.out" | tr -d '\r')"; return 1; }
	C=$(curl -s --max-time 5 -o "${D}/r11-nope.html" -w '%{http_code}' -H "Host: ${HH}" "${B}/loop/nope/")
	[ "${C}" == "404" ] && grep -qF '<h1>No such loop</h1>' "${D}/r11-nope.html" && grep -qF '<code>nope</code>' "${D}/r11-nope.html" \
		&& grep -qF '<a href="/loop/autonomy-loop/">autonomy-loop</a>' "${D}/r11-nope.html" || { echo "/loop/nope/ answered ${C} without the page that says so"; return 1; }
	# the Loop Deck link, as EXPECT_DECK says: the href it carries, or empty for no link at all
	DK=$(curl -s --max-time 5 -H "Host: ${HH}" "${B}/loop/autonomy-loop/data.json" | python3 -c 'import json, sys
k = json.load(sys.stdin).get("loop_deck")
print("none" if k is None else k.get("href") or ("route" if k.get("route") else "?"))' 2> /dev/null)
	if [ -n "${EXPECT_DECK}" ]; then
		grep -qF "<a href=\"${EXPECT_DECK}\">Loop Deck</a>" "${D}/r11-nope.html" \
			|| { echo "the no-such-loop page does not link Loop Deck at ${EXPECT_DECK} (data.json: ${DK})"; return 1; }
		case "${EXPECT_DECK}" in //loop-deck.*) [ "${DK}" == "route" ] ;; *) [ "${DK}" == "${EXPECT_DECK}" ] ;; esac \
			|| { echo "data.json's loop_deck is ${DK}, not the link to ${EXPECT_DECK}"; return 1; }
	else
		grep -qF '>Loop Deck</a>' "${D}/r11-nope.html" && { echo "the no-such-loop page links a Loop Deck that is neither named nor reachable (data.json: ${DK})"; return 1; }
		[ "${DK}" == "none" ] || { echo "data.json's loop_deck is ${DK} with no Deck named or reachable"; return 1; }
	fi
	C=$(curl -s --max-time 5 -o "${D}/r11-markup.html" -w '%{http_code}' -H "Host: ${HH}" "${B}/loop/%3Cscript%3Ealert(1)%3C%2Fscript%3E/")
	[ "${C}" == "404" ] && grep -qF '<code>&lt;script&gt;alert(1)&lt;/script&gt;</code>' "${D}/r11-markup.html" && ! grep -qF '<script>alert(1)' "${D}/r11-markup.html" \
		|| { echo "an id with markup (${C}) is not escaped on the no-such-loop page"; return 1; }
	C=$(curl -s --max-time 5 -o "${D}/r11-ctl.json" -w '%{http_code}' -X POST -H "Host: ${HH}" -H "Origin: http://${HH}" "${B}/loop/autonomy-loop/control/pause")
	[ "${C}" == "403" ] && grep -qF 'X-Loop-Control' "${D}/r11-ctl.json" || { echo "a POST to /loop/autonomy-loop/control/pause did not reach the renderer's header check (${C})"; return 1; }
	echo "/loop/autonomy-loop/ is the page / serves and /loop/autonomy-loop redirects to it; its data and its transcripts (sandboxed text/plain) are under it; /loop/nope/ is a 404 that says so, naming the loops it shows; an id with markup is escaped; /loop/autonomy-loop/control/ reaches the renderer's checks; the Loop Deck link: ${EXPECT_DECK:-none}"
}
# Loop Deck neither named (no LOOP_DECK_URL) nor reachable (nothing on its port): no link
RO=$(EXPECT_DECK="" route_ok "${H}" "${LH}") || fail "${RO}"
kill "${V}"
for i in $(seq 1 20); do kill -0 "${V}" 2> /dev/null || break; sleep 0.25; done
# the Deck this harness serves, reachable: a stub on its port answers the proxy's /__probe/loop-deck (its /status.json)
mkdir -p "${D}/deck-stub" && echo '{}' > "${D}/deck-stub/status.json"
python3 -m http.server "${UI_PORT_LOOP_DECK}" --bind 127.0.0.1 --directory "${D}/deck-stub" > "${D}/deck-stub.log" 2>&1 &
DS=$!
PIDS+=("${DS}")
upto 204 "${H}/__probe/loop-deck" || fail "the stub Deck does not answer the proxy's /__probe/loop-deck"
DECK_LINK="//loop-deck.${LH#*.}/#/loops"
DECK_URL="http://deck.localhost:18799/"
V=$(serve "${D}/serve-11-served.log")
PIDS+=("${V}")
upto 204 "${H}/__probe/loop" || fail "the renderer did not come back with the Deck reachable"
RS=$(EXPECT_DECK="${DECK_LINK}" route_ok "${H}" "${LH}") || fail "with the served Deck reachable: ${RS}"
kill "${V}"
for i in $(seq 1 20); do kill -0 "${V}" 2> /dev/null || break; sleep 0.25; done
# a fleet's Deck named by LOOP_DECK_URL: the link is its Loops view
V=$(serve "${D}/serve-11-named.log" LOOP_DECK_URL="${DECK_URL}")
PIDS+=("${V}")
upto 204 "${H}/__probe/loop" || fail "the renderer did not come back with LOOP_DECK_URL"
RN=$(EXPECT_DECK="${DECK_URL}#/loops" route_ok "${H}" "${LH}") || fail "with LOOP_DECK_URL: ${RN}"
kill "${V}"
for i in $(seq 1 20); do kill -0 "${V}" 2> /dev/null || break; sleep 0.25; done
# CONTROLS 1, 2, 4, 5 and 6: renderer copies without the route, without the escape on the no-such-loop page, without
# Loop Deck's address (the served Deck reachable), one that links the served Deck without asking whether it is
# reachable (the stub stopped), and one that ignores LOOP_DECK_URL
for M in route escape deck probe url; do
	mkdir -p "${D}/mutant-${M}11"
	cp -r "${AGENT_DIR}/loop-view" "${D}/mutant-${M}11/"
done
python3 - "${VIEW}" "${D}/mutant-route11/loop-view.py" "${D}/mutant-escape11/loop-view.py" "${D}/mutant-deck11/loop-view.py" \
	"${D}/mutant-probe11/loop-view.py" "${D}/mutant-url11/loop-view.py" << 'PY'
import sys
s = open(sys.argv[1]).read()
a = "    m = LOOP_ROUTE_RE.match(path)\n    return (m.group(1), m.group(2)) if m else (None, path)\n"
assert a in s, "the route is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(a, "    return (None, path)\n"))
b = 'name = html.escape(unquote(raw)[:80], quote=True) or "(none)"'
assert b in s, "the escape is not where the control expects it"
open(sys.argv[3], "w").write(s.replace(b, 'name = unquote(raw)[:80] or "(none)"'))
c = '    return "//loop-deck.%s/#/loops" % m.group(1) if m else None\n'
assert c in s, "Loop Deck's address is not where the control expects it"
open(sys.argv[4], "w").write(s.replace(c, "    return None\n"))
d = '    return {"route": True, "via": "loop-deck.localhost"} if DECK.reachable(now) else None\n'
assert d in s, "the reachability check is not where the control expects it"
open(sys.argv[5], "w").write(s.replace(d, '    return {"route": True, "via": "loop-deck.localhost"}\n'))
e = "    if DECK_URL and DECK_URL_RE.fullmatch(DECK_URL):\n"
assert e in s, "the LOOP_DECK_URL check is not where the control expects it"
open(sys.argv[6], "w").write(s.replace(e, "    if False:\n"))
PY
CO=""
for M in route escape deck probe url; do
	EXP=${DECK_LINK} XENV=()
	case "${M}" in
	probe) kill "${DS}"; for i in $(seq 1 20); do kill -0 "${DS}" 2> /dev/null || break; sleep 0.25; done; EXP="" ;;
	url) EXP="${DECK_URL}#/loops" XENV=(LOOP_DECK_URL="${DECK_URL}") ;;
	esac
	V=$(VIEW_BIN=${D}/mutant-${M}11/loop-view.py serve "${D}/serve-11-${M}.log" "${XENV[@]}")
	PIDS+=("${V}")
	upto 204 "${H}/__probe/loop" || fail "the ${M} mutant did not answer"
	MO=$(EXPECT_DECK="${EXP}" route_ok "${H}" "${LH}") && fail "CONTROL: a renderer without the ${M} passed the per-loop check: ${MO}"
	CO="${CO}; without the ${M} -> ${MO}"
	kill "${V}"
	for i in $(seq 1 20); do kill -0 "${V}" 2> /dev/null || break; sleep 0.25; done
done
# CONTROL 3: a proxy without the prefixed transcripts location serves a transcript under /loop/autonomy-loop/ with the page's
# policy instead of the sandbox
mkdir -p "${D}/mutant-tx11"
python3 - "${AGENT_DIR}/home-render.sh" "${D}/mutant-tx11/home-render.sh" << 'PY'
import sys
s = open(sys.argv[1]).read()
a = "\t\tlocation ~ ^/loop/[^/]+/transcripts/ {\n"
i = s.index(a)
j = s.index("\t\t}\n", i) + len("\t\t}\n")
open(sys.argv[2], "w").write(s[:i] + s[j:])
PY
env UI_DIR="${D}/mutant-tx11-ui" UI_PORT_HOME=18798 bash "${D}/mutant-tx11/home-render.sh" > /dev/null || fail "the transcripts mutant did not render"
nginx -c "${D}/mutant-tx11-ui/home/nginx.conf" -g "daemon off;" > "${D}/nginx-mutant-tx11.log" 2>&1 &
PIDS+=($!)
V=$(serve "${D}/serve-11-tx.log")
PIDS+=("${V}")
for i in $(seq 1 20); do [ "$(code "http://127.0.0.1:18798/")" == "200" ] && break; sleep 0.25; done
upto 204 "${H}/__probe/loop" || fail "the renderer did not come back for the transcripts control"
MT=$(route_ok "http://127.0.0.1:18798" "loop.localhost:18798") && fail "CONTROL: a proxy without the prefixed transcripts location passed: ${MT}"
kill "${V}"
# what a loop row of Loop Deck opens, in the manual and in the Deck: the vendored Deck's loop row goes to its own view of
# the loop (#/loop/<slug>), so the manual's UI page says that, and it never calls this page the row's drill-down
# both are needed, so a missing one fails the check, never skips it: ./test.sh mounts the checkout read-only at
# VOLUME_PATH_INTERNAL (.env: /do-agent-aws), the image ships the Deck at /opt/loop-deck and, for a run of the image with
# no checkout mounted (a plain docker run), the manual it serves at /guide/manual/ (/docs/manual, the Dockerfile's copy
# of the commit the image was built from - the one that goes with its Deck)
README_MD=""
for F in "${BASE_DIR}/../docs/manual/ui.md" "${VOLUME_PATH_INTERNAL:-/do-agent-aws}/docs/manual/ui.md" /docs/manual/ui.md; do [ -f "${F}" ] && README_MD=${F} && break; done
[ -n "${README_MD}" ] || fail "check 11 cannot read the manual's UI page: no ui.md at ${BASE_DIR}/../docs/manual, ${VOLUME_PATH_INTERNAL:-/do-agent-aws}/docs/manual (where ./test.sh mounts the checkout) or /docs/manual (the image's served copy)"
DECK_JS=""
for F in /opt/loop-deck/app/app.js "${BASE_DIR}/opt/loop-deck/app/app.js"; do [ -f "${F}" ] && DECK_JS=${F} && break; done
[ -n "${DECK_JS}" ] || fail "check 11 cannot read the Deck's app.js: it is at neither /opt/loop-deck/app/app.js nor ${BASE_DIR}/opt/loop-deck/app/app.js"
python3 - "${README_MD}" "${DECK_JS}" << 'EOF' || fail "the manual's Agent loop page section does not say what a loop row of Loop Deck opens (${README_MD}, ${DECK_JS})"
import sys
readme, app = open(sys.argv[1]).read(), open(sys.argv[2]).read()
assert "location.hash = '#/loop/' + l.slug" in app, "the Deck's loop row no longer opens its own view (#/loop/<slug>): say in the manual what it opens now"
sec = " ".join(readme.split("\n### Agent loop page\n", 1)[1].split("\n## ", 1)[0].split("\n### ", 1)[0].split())
assert "A loop row of Loop Deck opens the Deck's own view of that loop (`#/loop/<slug>` on the Deck), not this page" in sec, \
    "the section does not say that a loop row of Loop Deck opens the Deck's own view of the loop"
assert "drill-down a loop row" not in sec, "the section still calls this page the drill-down a loop row of Loop Deck opens"
EOF
echo "ok 11 - ${RO}; controls${CO}; without the prefixed transcripts location -> ${MT}; the README says a loop row of Loop Deck opens the Deck's own view, as the Deck's app.js does"

# --- 12. the harness's other loops, by their Loop Deck slugs: each one's status page and data, from its own files ---
O12=${D:?}/others
mkdir -p "${O12}/slack" "${O12}/comms" "${O12}/loop" "${O12}/ui" "${O12}/tmux"
chmod 700 "${O12}/tmux"
printf '%s CHAT MSG ts=1.000100 channel=C1 user=U1 kind=model text="what does the loop do"\n%s CHAT MODEL ts=1.000100 rc=0 duration=14s posted=yes transcript=/wd/slack/t1\n%s CHAT REPLY ts=1.000100 kind=model ok posted=2.000200\n%s CHAT MSG ts=3.000300 channel=C1 user=U2 kind=status text="status"\n%s CHAT REPLY ts=3.000300 kind=status FAILED: rate limited\n%s CHAT MSG ts=4.000400 channel=C1 user=U1 kind=model text="<script>window.__pwned=1</script>"\n' \
	"$(stamp 300)" "$(stamp 286)" "$(stamp 285)" "$(stamp 200)" "$(stamp 199)" "$(stamp 30)" > "${O12}/slack/chat.log"
echo "POLLING interval=5s handled=2 pid=2147480002 utc=$(stamp 10)" > "${O12}/slack/chat.state"
echo "$(stamp 20) new=1 replies=0 deferred=0 inbox=1" > "${O12}/slack/last-watch"
# a process named slack-chat.sh holds the responder's lock, as the running responder does
( exec 9> "${O12}/slack/chat.lock"; flock -n 9 && exec -a slack-chat.sh sleep 120 ) &
PIDS+=($!)
sleep 120 &
CW=$!
PIDS+=("${CW}")
echo "${CW}" > "${O12}/comms/watch.pid"
printf 'engine started\npolled 3 channels\n' > "${O12}/comms/watch.log"
echo '{"last_sync": "2026-10-13T22:04:00Z", "cards": 7, "board": "agent"}' > "${O12}/loop/kanban-sync.state"
echo "state=accepted documents=12" > "${O12}/ui/hindsight-seed.state"
OT_ENV=(SLACK_DIR="${O12}/slack" COMMS_DIR="${O12}/comms" AUTONOMY_LOOP_DIR="${O12}/loop" UI_DIR="${O12}/ui" TMUX_TMPDIR="${O12}/tmux")
# ot_serve <log> <renderer>: a renderer over the other loops' fixture on UI_PORT_LOOP, behind the probe proxy of check 6
ot_serve() { env "${OT_ENV[@]}" python3 "$2" --port "${UI_PORT_LOOP}" > "$1" 2>&1 & echo $!; }
# others_ok <base url> <host> <comms watch alive: True|False>: what each slug's page and data say through the proxy
others_ok()
{
	python3 - "$1" "$2" "$3" "${CW}" << 'PY'
import json, sys, urllib.request
base, host, alive_want, cw = sys.argv[1:5]
def get(path):
    with urllib.request.urlopen(urllib.request.Request(base + path, headers={"Host": host}), timeout=10) as r:
        return r.status, r.read()
out = []
def need(cond, what):
    if not cond:
        print("; ".join(out + ["FAILED: " + what]))
        sys.exit(1)
    out.append(what)
for slug in ("slack-chat", "slack-watch", "comms-watch", "kanban-sync", "plane-sync", "hindsight-seed"):
    c, b = get("/loop/%s/" % slug)
    need(c == 200 and b'data-view="status"' in b, "/loop/%s/ is its status page" % slug)
d = lambda slug: json.loads(get("/loop/%s/data.json" % slug)[1])
ch = d("slack-chat")
st = [(f["n"], f["status"]) for f in ch["fires"]]
need(st == [(3, "answering"), (2, "failed"), (1, "ok")] and ch["fires"][2]["rc"] == 0 and ch["fires"][2]["duration_s"] == 14
     and ch["fires"][2]["posted"] == "yes", "slack-chat: 3 fires, newest first: answering, failed, ok (rc 0, 14 s, posted) %s" % st)
need(ch["process"]["alive"] is True and ch["record"]["lines"][0].startswith("POLLING"), "slack-chat: its lock held by slack-chat.sh, state POLLING")
need(d("slack-watch")["record"]["lines"][0].endswith("new=1 replies=0 deferred=0 inbox=1"), "slack-watch: its last-watch line")
cwd = d("comms-watch")
need(cwd["process"].get("pid") == int(cw) and str(cwd["process"]["alive"]) == alive_want
     and cwd["log_tail"] == ["engine started", "polled 3 channels"],
     "comms-watch: pid %s alive=%s (want %s), its log tail" % (cwd["process"].get("pid"), cwd["process"]["alive"], alive_want))
need(["cards", "7"] in d("kanban-sync")["record"]["fields"], "kanban-sync: its state file's fields")
need(d("plane-sync")["record"].get("missing") is True, "plane-sync: no state file yet, said so")
need(d("hindsight-seed")["record"]["lines"] == ["state=accepted documents=12"], "hindsight-seed: its state")
print("; ".join(out))
PY
}
V=$(ot_serve "${D}/serve-12.log" "${VIEW}")
PIDS+=("${V}")
upto 204 "${H}/__probe/loop" || fail "the renderer for check 12 did not answer: $(cat "${D}/serve-12.log")"
OK12=$(others_ok "${H}" "${LH}" True) || fail "${OK12}"
# the comms watch exits: its pid file stays, and its pid reads not running
kill "${CW}" 2> /dev/null
for i in $(seq 1 20); do [ -n "$(tr -d '\0' < /proc/${CW}/cmdline 2> /dev/null)" ] || break; sleep 0.25; done
GONE=$(others_ok "${H}" "${LH}" False) || fail "after the comms watch exited: ${GONE}"
ctl_stop12() { kill "$1" 2> /dev/null; for i in $(seq 1 20); do kill -0 "$1" 2> /dev/null || return 0; sleep 0.25; done; }
ctl_stop12 "${V}"
# CONTROLS: a renderer without the chat's REPLY lines (every fire stays answering), and one that trusts the pid file
for M in reply pidfile; do
	mkdir -p "${D}/mutant-${M}12"
	cp -r "${AGENT_DIR}/loop-view" "${D}/mutant-${M}12/"
done
python3 - "${VIEW}" "${D}/mutant-reply12/loop-view.py" "${D}/mutant-pidfile12/loop-view.py" << 'PY'
import sys
s = open(sys.argv[1]).read()
a = '            f.update(end=at, outcome=word.lower(), status={"ok": "ok", "FAILED": "failed"}.get(word, "unknown"))\n'
assert a in s, "the chat's REPLY handling is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(a, "            pass\n"))
b = '    return {"file": path, "pid": int(text), "alive": bool(cmd), "cmd": clip(cmd or "", 160)}\n'
assert b in s, "the pid check is not where the control expects it"
open(sys.argv[3], "w").write(s.replace(b, '    return {"file": path, "pid": int(text), "alive": True, "cmd": clip(cmd or "", 160)}\n'))
PY
C12=""
for M in reply pidfile; do
	V=$(ot_serve "${D}/serve-12-${M}.log" "${D}/mutant-${M}12/loop-view.py")
	PIDS+=("${V}")
	upto 204 "${H}/__probe/loop" || fail "the ${M} mutant did not answer"
	MO=$(others_ok "${H}" "${LH}" False) && fail "CONTROL: a renderer without the ${M} check passed: ${MO}"
	C12="${C12}; without the ${M} check -> ${MO##*FAILED: }"
	ctl_stop12 "${V}"
done
echo "ok 12 - ${OK12}; after the comms watch exited its pid reads not running; controls${C12}"

echo "Test-loop-view succeeded"
