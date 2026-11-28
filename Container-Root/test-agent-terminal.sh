#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the agent's terminal: Claude Code's first-run answers (/agent/claude-onboarding.py, synced by
# /agent/claude-settings-sync.sh at build and at every start) so the shared tmux pane - the browser terminal
# /tmux/ - opens at claude's prompt on a fresh agent state. Fully OFFLINE: test-local tmux sessions and config
# directories under /tmp/agent-terminal-smoke; no prompt is ever submitted to claude; the image's own config and
# the shared "agent" session are only read.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the scripts parse (bash -n; python3 ast)
#   2. the image's Claude Code config carries the first-run answers (claude-onboarding.py --check exits 0)
#   3. merge-safe seeding on a planted .claude.json: a user's own theme and a project's other keys are kept, the
#      missing answers are added, the file keeps its mode, a re-run changes nothing, --check tells missing from
#      present; a file that is not JSON is left byte-identical; a file whose onboarding is complete but has no theme
#      (what Claude Code leaves after it starts) passes --check and is not rewritten, while a first run gets the theme;
#      a .claude.json that is a link (PLANTED CONTROL: it is one) stays a link, and the file it points to gets the
#      answers with its own mode; a link to nothing is left alone - nothing is created where it points
#   4. the live pane, A/B with ONE variable: claude started in a test-local tmux session the way the agent session
#      starts it, on two otherwise identical bare config dirs - with the seeded answers the pane reaches claude's
#      prompt and shows none of the first-run screens; PLANTED CONTROL: without them it shows the theme picker
#      (the first of the screens whose Enter-Enter-Enter exits claude to the bare shell); and with onboarding complete
#      but no theme the pane reaches the prompt too
#   5. claude is the agent pane's FOREGROUND process: in a session tmux-session-start.sh creates (on a test-local
#      tmux server), tmux reports pane_current_command "claude"; PLANTED CONTROL: the previous wrapper (no job
#      control) reports "bash" for the same claude
#   6. the session carries its lineage (@agent_parent operator, @agent_owner, @agent_task, @agent_role) and its pane
#      is piped into <TMUX_AGENT_HOME>/logs/<session>.log (pipe on, the file 0600 in a 0700 directory, growing)
#   6b. the folder the hub's pane starts in is trusted in the pane's config before the pane starts (the start runs
#      claude-onboarding.py --dir on it): /wd when it exists, else HOME - the image's config trusts /wd alone, so a
#      container without /wd (a plain docker run of the image, a sandbox) opened the pane at the trust question, where
#      check 7's dashboard read a menu, not the agent; PLANTED CONTROL: a copy of the start without the trust step
#      leaves a throwaway config as it was
#   7. the tmux-agent dashboard's own API (the vendored dashboard on a test port with the harness lexicon and the
#      session's home): the agent row is classified by claude-code-harness, has a context %, log bytes and an
#      engagement other than ORPHANED, and its process is claude; PLANTED CONTROLS: the previous wrapper and
#      session start give process bash, ORPHANED and no log; the same dashboard without the lexicon leaves the
#      idle agent unclassified
#   8. the pane survives claude: when claude exits the pane falls back to a shell and the session stays
#   9. the GitHub plugin follows the token (without one its MCP server only logs failures), both states: on a planted
#      settings file the sync disables it with no GH_TOKEN/GITHUB_TOKEN/GITHUB_PERSONAL_ACCESS_TOKEN and enables it
#      with any one of them, keeping every
#      other key (a settings file without the plugin is left alone, a re-run changes nothing); startup.sh hands
#      GH_TOKEN or GITHUB_TOKEN to the plugin as GITHUB_PERSONAL_ACCESS_TOKEN (never over an explicit one); and
#      `claude mcp list` on a copy of the image's config lists no GitHub MCP server without a token, and lists it
#      (tried with the token) with one - the server whose failure every session logged. The context7 plugin the
#      same way on CONTEXT7_PLUGIN=true (its MCP server needs an OAuth sign-in): off by default, on when asked,
#      and `claude mcp list` lists its server only then - with neither, the first screen has no "needs
#      authentication"
#  10. the test leaves the user's /wd/knowledge alone: its settings syncs (claude-settings-sync.sh runs the knowledge
#      step) and every claude it starts (the image's SessionStart hook, knowledge-files.py verify, makes the copy where
#      KNOWLEDGE_DIR points) write the default knowledge copy under its own directory, and /wd/knowledge is the same at
#      the end as at the start (with the copy's default KNOWLEDGE_DIR the syncs wrote /wd/knowledge/defaults - the
#      user's persisted volume in a container started by ./test.sh; and the agent session of checks 5-8, whose claude
#      runs with the image's hooks, wrote it wherever /wd existed without ./test.sh's KNOWLEDGE_DIR, as in a sandbox)

D=/tmp/agent-terminal-smoke
rm -rf "${D:?}"
mkdir -p "${D}"
# what /wd/knowledge holds before this test (the user's volume under ./test.sh): check 10 compares the end with it
wd_knowledge_state() { find /wd/knowledge -printf '%P %s %T@\n' 2>/dev/null | sort | sha256sum; }
KNOWLEDGE_BEFORE=$(wd_knowledge_state)
# where every claude this test starts and every settings sync it runs writes the default knowledge copy: the image's
# SessionStart hook (knowledge-files.py verify) makes the copy under KNOWLEDGE_DIR, /wd/knowledge by default, and the
# agent session of checks 5-8 runs claude with the image's own hooks. ./test.sh passes a KNOWLEDGE_DIR under /tmp
# (TEST_RUN_OPTS); without it - a plain docker run, a sandbox - that session wrote the user's /wd/knowledge (check 10)
export KNOWLEDGE_DIR=${D}/knowledge

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
CLAUDE_BIN=${CLAUDE_BIN:-/usr/local/bin/claude}
SESSIONS=()

cleanup()
{
	for S in "${SESSIONS[@]}"; do tmux kill-session -t "=${S}" 2>/dev/null; done
}
trap cleanup EXIT

fail()
{
	echo "Test-agent-terminal FAILED: $1"
	exit 1
}

# --- 1. syntax ---
bash -n "$0" || fail "bash -n $0"
bash -n "${AGENT_DIR}/claude-settings-sync.sh" || fail "bash -n claude-settings-sync.sh"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${AGENT_DIR}/claude-onboarding.py" || fail "python3 cannot parse claude-onboarding.py"
echo "ok 1 - syntax"

# --- 2. the image's config ---
IMG_CFG=${CLAUDE_CONFIG_DIR:-/home/agent/.claude}/.claude.json
if [ -f "${IMG_CFG}" ]; then
	python3 "${AGENT_DIR}/claude-onboarding.py" --config "${IMG_CFG}" --check > ${D}/img-check.log || fail "the image's ${IMG_CFG} lacks first-run answers: $(cat ${D}/img-check.log)"
	echo "ok 2 - ${IMG_CFG} carries the first-run answers"
else
	echo "ok 2 - (skipped: no ${IMG_CFG} in this context)"
fi

# --- 3. merge-safe seeding ---
mkdir -p ${D}/planted
echo '{"userID": "planted", "theme": "light", "projects": {"/wd": {"allowedTools": ["Bash"]}, "/other": {"x": 1}}}' > ${D}/planted/.claude.json
chmod 640 ${D}/planted/.claude.json
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/.claude.json --check > /dev/null && fail "--check passed on a file missing the answers"
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/.claude.json --dir /wd > ${D}/seed1.log || fail "seeding failed: $(cat ${D}/seed1.log)"
python3 - ${D}/planted/.claude.json << 'PYEOF' || fail "seeding changed or lost a planted value"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["theme"] == "light", d["theme"]
assert d["userID"] == "planted" and d["projects"]["/other"] == {"x": 1}
assert d["projects"]["/wd"] == {"allowedTools": ["Bash"], "hasTrustDialogAccepted": True}, d["projects"]["/wd"]
assert d["hasCompletedOnboarding"] is True
PYEOF
[ "$(stat -c %a ${D}/planted/.claude.json)" == "640" ] || fail "seeding changed the file mode to $(stat -c %a ${D}/planted/.claude.json)"
SHA=$(sha256sum ${D}/planted/.claude.json)
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/.claude.json --dir /wd > /dev/null
[ "$(sha256sum ${D}/planted/.claude.json)" == "${SHA}" ] || fail "a re-run rewrote the file"
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/.claude.json --check > /dev/null || fail "--check failed after seeding"
echo 'not { json' > ${D}/planted/broken.json
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/broken.json > /dev/null || fail "a broken file made the helper fail"
[ "$(cat ${D}/planted/broken.json)" == 'not { json' ] || fail "a file that is not JSON was rewritten"
# onboarding complete, no theme (Claude Code removes the key after it starts): healthy, left alone; a first run gets one
printf '{"hasCompletedOnboarding": true, "projects": {"/wd": {"hasTrustDialogAccepted": true}}}\n' > ${D}/planted/started.json
SHA=$(sha256sum ${D}/planted/started.json)
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/started.json --check > ${D}/started-check.log || fail "--check failed on a started state (onboarding complete, no theme): $(cat ${D}/started-check.log)"
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/started.json --dir /wd > /dev/null
[ "$(sha256sum ${D}/planted/started.json)" == "${SHA}" ] || fail "seeding rewrote a started state: $(cat ${D}/planted/started.json)"
# a .claude.json that is a link: the answers land in the file it points to, the link stays a link, the mode stays
echo '{"userID": "planted-link"}' > ${D}/planted/real.json
chmod 600 ${D}/planted/real.json
ln -s real.json ${D}/planted/link.json
[ -L ${D}/planted/link.json ] || fail "PLANTED CONTROL BROKEN: link.json is not a link"
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/link.json --dir /wd > ${D}/link.log || fail "seeding through a link failed: $(cat ${D}/link.log)"
[ -L ${D}/planted/link.json ] || fail "seeding replaced the linked .claude.json with a file of its own (the file it pointed to keeps no answers)"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if d.get("userID") == "planted-link" and d.get("hasCompletedOnboarding") is True else 1)' ${D}/planted/real.json \
	|| fail "the answers did not land in the file the link points to: $(cat ${D}/planted/real.json)"
[ "$(stat -c %a ${D}/planted/real.json)" == "600" ] || fail "seeding through a link changed the mode of the file it points to to $(stat -c %a ${D}/planted/real.json)"
# a link to nothing is left alone: no directory or file is created where it points
ln -s missing-dir/real.json ${D}/planted/dangling.json
{ [ -L ${D}/planted/dangling.json ] && [ ! -e ${D}/planted/dangling.json ]; } || fail "PLANTED CONTROL BROKEN: dangling.json is not a link to nothing"
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/dangling.json --dir /wd > ${D}/dangling.log || fail "a link to nothing made the helper fail"
[ -e ${D}/planted/missing-dir ] && fail "seeding through a link to nothing created the directory it points to"
grep -q "left alone" ${D}/dangling.log || fail "a link to nothing was not reported as left alone: $(cat ${D}/dangling.log)"
echo '{}' > ${D}/planted/fresh.json
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/planted/fresh.json --dir /wd > /dev/null
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if d.get("theme") == "dark" and d.get("hasCompletedOnboarding") is True else 1)' ${D}/planted/fresh.json \
	|| fail "a first run did not get the theme with the onboarding answer: $(cat ${D}/planted/fresh.json)"
echo "ok 3 - merge-safe: a user's theme and project keys kept, missing answers added, mode kept, re-run byte-identical, --check exact, a broken file untouched; a started state without a theme passes --check and is left alone, a first run gets the theme; a linked .claude.json stays a link, its target gets the answers with its mode; a link to nothing is left alone"

# --- 4. the live pane, with and without the answers ---
if ! command -v tmux > /dev/null || [ ! -x "${CLAUDE_BIN}" ]; then
	echo "Test-agent-terminal skipped check 4: tmux or ${CLAUDE_BIN} not installed"
	echo "Test-agent-terminal succeeded"
	exit 0
fi
ONBOARDING='Choose the text style|Security notes|trust this folder|Quick safety check'
mkdir -p ${D}/workdir ${D}/cfg-seeded ${D}/cfg-control ${D}/cfg-started
echo '{}' > ${D}/cfg-seeded/.claude.json
echo '{}' > ${D}/cfg-control/.claude.json
# what Claude Code leaves after a start: onboarding complete, the folder trusted, no theme
printf '{"hasCompletedOnboarding": true, "projects": {"%s": {"hasTrustDialogAccepted": true}}}\n' ${D}/workdir > ${D}/cfg-started/.claude.json
python3 "${AGENT_DIR}/claude-onboarding.py" --config ${D}/cfg-seeded/.claude.json --dir ${D}/workdir > /dev/null || fail "could not seed the A side"
# pane <session> <config dir> - claude in a test-local session, the agent session's way (a tmux pane in the work
# folder, no options), with its own config dir and the image's Bedrock settings from the environment
pane()
{
	SESSIONS+=("$1")
	tmux new-session -d -s "$1" -x 200 -y 50 -c ${D}/workdir -e CLAUDE_CONFIG_DIR="$2" "${CLAUDE_BIN}" \
		|| fail "could not start the test session $1"
}
# screen <session> <wanted regex> - polls the pane (up to 60 s) until it matches; prints the last screen
screen()
{
	for _ in $(seq 1 60); do
		OUT=$(tmux capture-pane -p -t "=$1:" 2>/dev/null)
		echo "${OUT}" | grep -qE "$2" && { echo "${OUT}"; return 0; }
		sleep 1
	done
	echo "${OUT}"
	return 1
}
pane t01-seeded ${D}/cfg-seeded
pane t01-control ${D}/cfg-control
pane t01-started ${D}/cfg-started
screen t01-seeded '^❯' > ${D}/pane-seeded.txt || fail "with the seeded answers the pane never reached claude's prompt: $(tail -15 ${D}/pane-seeded.txt)"
grep -qE "${ONBOARDING}" ${D}/pane-seeded.txt && fail "with the seeded answers the pane still shows a first-run screen: $(grep -E "${ONBOARDING}" ${D}/pane-seeded.txt)"
screen t01-control 'Choose the text style' > ${D}/pane-control.txt || fail "PLANTED CONTROL BROKEN: without the answers no theme picker appeared: $(tail -15 ${D}/pane-control.txt)"
screen t01-started '^❯' > ${D}/pane-started.txt || fail "with onboarding complete and no theme the pane never reached claude's prompt: $(tail -15 ${D}/pane-started.txt)"
grep -qE "${ONBOARDING}" ${D}/pane-started.txt && fail "with onboarding complete and no theme the pane shows a first-run screen: $(grep -E "${ONBOARDING}" ${D}/pane-started.txt)"
echo "ok 4 - the live pane: seeded -> claude's prompt, no first-run screen; control without the answers -> the theme picker; onboarding complete without a theme -> the prompt"
# the check-4 sessions live on the default tmux server and the rest of the test moves to a server of its own (TMUX_TMPDIR
# below), where the exit cleanup cannot reach them: ended here, or their three claude processes outlive the test (seen in
# a sequential run of the suite)
for S in "${SESSIONS[@]}"; do tmux kill-session -t "=${S}" 2>/dev/null; done
SESSIONS=()

# --- 5-8. the agent session as the tmux-agent dashboard sees it ---
# a test-local tmux server (its own socket dir), so the session's environment is this test's and the shared
# "agent" session is never touched; the session start, the dashboard and this test all use it
export TMUX_TMPDIR=${D}/tmux
mkdir -p "${TMUX_TMPDIR}"
export TMUX_AGENT_HOME=${D}/ta-home
export HINDSIGHT_WAIT_SECS=0
unset UI_START TMUX
# the previous wrapper and session start, for the controls: this image's scripts minus job control, lineage and
# capture (each removal asserted, so the controls cannot silently stop being the old behaviour)
mkdir -p ${D}/old-agent
python3 - "${AGENT_DIR}" ${D}/old-agent << 'PYEOF' || fail "could not derive the previous wrapper for the controls"
import re, sys
src, dst = sys.argv[1], sys.argv[2]
w = open(src + "/tmux-claude.sh").read()
n = len(w)
w = re.sub(r"\n\t\t# Job control for this one command:.*?\n\t\tset -m\n", "\n", w, flags=re.S)
w = w.replace('\t\twhile [ -n "$(jobs -ps)" ]; do fg > /dev/null; done\n\t\tset +m\n', "")
assert len(w) < n and "set -m" not in w and "jobs -ps" not in w, "job control still in the control wrapper"
open(dst + "/tmux-claude.sh", "w").write(w)
t = open(src + "/tmux-session-start.sh").read()
i = t.index("\n# Lineage for the tmux-agent dashboard")
open(dst + "/tmux-session-start.sh", "w").write(t[:i] + "\n")
PYEOF
chmod +x ${D}/old-agent/*.sh
SESSIONS+=(t03-agent t03-old)
AGENT_TMUX_SESSION_NAME=t03-agent "${AGENT_DIR}/tmux-session-start.sh" > ${D}/start-agent.log 2>&1 || fail "tmux-session-start.sh failed: $(cat ${D}/start-agent.log)"
AGENT_TMUX_SESSION_NAME=t03-old ${D}/old-agent/tmux-session-start.sh > ${D}/start-old.log 2>&1 || fail "the control session start failed: $(cat ${D}/start-old.log)"
# cmd_of <session> - what tmux reports as the pane's foreground program
cmd_of() { tmux display -p -t "=$1:" '#{pane_current_command}' 2>/dev/null; }
claude_under() { pgrep -P "$(tmux display -p -t "=$1:" '#{pane_pid}' 2>/dev/null)" -x claude > /dev/null 2>&1; }
for _ in $(seq 1 60); do [ "$(cmd_of t03-agent)" == "claude" ] && claude_under t03-old && break; sleep 1; done
[ "$(cmd_of t03-agent)" == "claude" ] || fail "the agent pane's foreground process is '$(cmd_of t03-agent)', not claude: $(cat ${D}/start-agent.log)"
claude_under t03-old || fail "the control pane never started claude"
[ "$(cmd_of t03-old)" == "bash" ] || fail "PLANTED CONTROL BROKEN: the previous wrapper reports '$(cmd_of t03-old)', expected bash"
echo "ok 5 - the agent pane's foreground process is claude; control: the previous wrapper reports bash while claude runs under it"

LINEAGE=$(tmux list-sessions -F '#{session_name}|#{@agent_parent}|#{@agent_owner}|#{@agent_task}|#{@agent_role}' | grep '^t03-agent|')
IFS='|' read -r _ PARENT OWNER TASK ROLE <<< "${LINEAGE}"
{ [ "${PARENT}" == "operator" ] && [ "${OWNER}" == "do-agent-aws" ] && [ "${ROLE}" == "agent" ] && [ -n "${TASK}" ]; } \
	|| fail "the session's lineage options are wrong: '${LINEAGE}'"
[ "$(tmux display -p -t "=t03-agent:" '#{pane_pipe}')" == "1" ] || fail "the agent pane is not piped"
LOG=${TMUX_AGENT_HOME}/logs/t03-agent.log
[ -f "${LOG}" ] || fail "no capture log at ${LOG}"
{ [ "$(stat -c %a "${LOG}")" == "600" ] && [ "$(stat -c %a "${TMUX_AGENT_HOME}/logs")" == "700" ]; } || fail "capture log modes: file $(stat -c %a "${LOG}"), dir $(stat -c %a "${TMUX_AGENT_HOME}/logs")"
SIZE1=$(stat -c %s "${LOG}")
tmux send-keys -t "=t03-agent:" " " 2>/dev/null
sleep 2
tmux send-keys -t "=t03-agent:" BSpace 2>/dev/null
[ "$(stat -c %s "${LOG}")" -gt 0 ] || fail "the capture log stays empty"
tmux list-sessions -F '#{session_name}|#{@agent_parent}' | grep -q '^t03-old|.\+' && fail "the control session unexpectedly has lineage"
echo "ok 6 - lineage parent=operator owner=do-agent-aws role=agent task='${TASK}'; the pane is piped to ${LOG} (0600 in 0700, ${SIZE1} -> $(stat -c %s "${LOG}") bytes)"

# --- 6b. the folder the hub's pane starts in is trusted before the pane starts ---
# tmux-session-start.sh trusts that folder (claude-onboarding.py --dir): /wd when it exists, else HOME. The image's config
# trusts /wd alone (claude-settings-sync.sh at the build and at every start), so in a container without /wd - a plain
# docker run of the image, a sandbox - the pane opened at Claude Code's trust question, where check 7's dashboard read a
# menu, not the agent. A throwaway config and HOME, claude off in the pane: the folder is trusted before anything starts.
# PLANTED CONTROL: a copy of the start without the trust step (its removal asserted) leaves the config as it was
mkdir -p ${D}/trust/cfg ${D}/trust/cfg-old ${D}/trust/home
echo '{}' > ${D}/trust/cfg/.claude.json
echo '{}' > ${D}/trust/cfg-old/.claude.json
python3 - "${AGENT_DIR}/tmux-session-start.sh" ${D}/old-agent/tmux-session-start-notrust.sh << 'PYEOF' || fail "could not derive the control: tmux-session-start.sh has no trust step for the hub's folder (claude-onboarding.py --dir on SESSION_WORKDIR)"
import sys
t = open(sys.argv[1]).read()
a = t.index("\n# The pane's folder is trusted for claude before the pane starts")
b = t.index("\n\n", a)
assert "claude-onboarding.py" in t[a:b] and "SESSION_WORKDIR" in t[a:b], "the trust step is not where the control expects it"
open(sys.argv[2], "w").write(t[:a] + t[b:])
PYEOF
chmod +x ${D}/old-agent/tmux-session-start-notrust.sh
SESSIONS+=(t06-trust t06-notrust)
HOME=${D}/trust/home CLAUDE_CONFIG_DIR=${D}/trust/cfg AGENT_TMUX_CLAUDE=false AGENT_TMUX_SESSION_NAME=t06-trust "${AGENT_DIR}/tmux-session-start.sh" > ${D}/trust/start.log 2>&1 \
	|| fail "tmux-session-start.sh with a throwaway config and HOME: $(cat ${D}/trust/start.log)"
HOME=${D}/trust/home CLAUDE_CONFIG_DIR=${D}/trust/cfg-old AGENT_TMUX_CLAUDE=false AGENT_TMUX_SESSION_NAME=t06-notrust ${D}/old-agent/tmux-session-start-notrust.sh > ${D}/trust/start-old.log 2>&1 \
	|| fail "the control's session start failed: $(cat ${D}/trust/start-old.log)"
TRUST_DIR=$(tmux display -p -t "=t06-trust:" '#{pane_current_path}')
[ -n "${TRUST_DIR}" ] || fail "no working directory for the t06-trust pane"
trusted() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if ((d.get("projects") or {}).get(sys.argv[2]) or {}).get("hasTrustDialogAccepted") is True else 1)' "$1" "$2"; }
trusted ${D}/trust/cfg/.claude.json "${TRUST_DIR}" || fail "the folder the hub's pane starts in (${TRUST_DIR}) is not trusted in the pane's config: $(cat ${D}/trust/cfg/.claude.json)"
trusted ${D}/trust/cfg-old/.claude.json "${TRUST_DIR}" && fail "PLANTED CONTROL BROKEN: without the trust step the folder is trusted anyway: $(cat ${D}/trust/cfg-old/.claude.json)"
echo "ok 6b - the hub's pane starts in ${TRUST_DIR}, trusted in its config before the pane starts; control: the start without the trust step leaves the config as it was"

TA_JS=${TMUX_AGENT_JS:-/opt/tmux-agent/dist/bin/tmux-agent.js}
NODE=${NODE_BIN:-/usr/local/bin/node}
if [ -f "${TA_JS}" ] && [ -x "${NODE}" ]; then
	DASH_PIDS=()
	dashboard()
	{
		# dashboard <port> [lexicon] - the vendored dashboard on the test server and home
		if [ -n "$2" ]; then
			env TMUX_AGENT_DEFAULT_SERVER=1 TMUX_AGENT_LEXICON="$2" "${NODE}" "${TA_JS}" web --port "$1" --host 127.0.0.1 --no-token --strict-port > "${D}/dash-$1.log" 2>&1 &
		else
			env -u TMUX_AGENT_LEXICON TMUX_AGENT_DEFAULT_SERVER=1 "${NODE}" "${TA_JS}" web --port "$1" --host 127.0.0.1 --no-token --strict-port > "${D}/dash-$1.log" 2>&1 &
		fi
		DASH_PIDS+=($!)
		for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/api/health" && return 0; sleep 0.3; done
		fail "the dashboard on $1 did not come up: $(tail -5 "${D}/dash-$1.log")"
	}
	trap 'for S in "${SESSIONS[@]}"; do tmux kill-session -t "=${S}" 2>/dev/null; done; for P in "${DASH_PIDS[@]}"; do kill "${P}" 2>/dev/null; done' EXIT
	dashboard 18494 "${AGENT_DIR}/tmux-agent-lexicon.json"
	dashboard 18495
	# row <port> <session> - the session's fields from /api/session (which also focuses it for /api/fleet's deep pass)
	# and /api/fleet, as one JSON object
	row()
	{
		python3 - "$1" "$2" << 'PYEOF'
import json, sys, urllib.request
port, name = sys.argv[1], sys.argv[2]
get = lambda p: json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}{p}", timeout=8))
det = get(f"/api/session/{name}")
fleet = [s for s in get("/api/fleet").get("sessions", []) if s.get("session") == name]
f = fleet[0] if fleet else {}
print(json.dumps({"classifiedBy": det["snapshot"].get("classifiedBy"), "contextPct": det["snapshot"].get("contextPct"),
                  "logBytes": det["snapshot"].get("logBytes"), "process": (det.get("info") or {}).get("currentCmd"),
                  "engagement": f.get("engagement"), "parent": f.get("parent"), "state": det["snapshot"].get("state")}))
PYEOF
	}
	field() { python3 -c "import json, sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))" "$1" "$2"; }
	A=""
	for _ in $(seq 1 45); do
		A=$(row 18494 t03-agent 2>/dev/null)
		[ "$(field "${A}" classifiedBy)" == "claude-code-harness" ] && [ "$(field "${A}" contextPct)" != "None" ] && break
		sleep 2
	done
	echo "${A}" > ${D}/row-agent.json
	[ "$(field "${A}" classifiedBy)" == "claude-code-harness" ] || fail "the dashboard does not classify the agent by the harness profile: ${A} (pane: $(tmux capture-pane -p -t "=t03-agent:" | grep -v '^\s*$' | tail -4))"
	[ "$(field "${A}" contextPct)" != "None" ] || fail "the dashboard reads no context % for the agent: ${A}"
	[ "$(field "${A}" process)" == "claude" ] || fail "the dashboard's process for the agent is not claude: ${A}"
	{ [ "$(field "${A}" engagement)" != "ORPHANED" ] && [ "$(field "${A}" engagement)" != "None" ]; } || fail "the dashboard lists the agent as orphaned: ${A}"
	{ [ "$(field "${A}" logBytes)" != "None" ] && [ "$(field "${A}" logBytes)" -gt 0 ]; } || fail "the dashboard sees no capture log for the agent: ${A}"
	O=$(row 18494 t03-old 2>/dev/null)
	echo "${O}" > ${D}/row-old.json
	{ [ "$(field "${O}" process)" == "bash" ] && [ "$(field "${O}" engagement)" == "ORPHANED" ] && [ "$(field "${O}" logBytes)" == "None" ]; } \
		|| fail "PLANTED CONTROL BROKEN: the previous wrapper's row is not process bash / ORPHANED / no log: ${O}"
	N=$(row 18495 t03-agent 2>/dev/null)
	echo "${N}" > ${D}/row-nolexicon.json
	[ "$(field "${N}" classifiedBy)" == "None" ] || fail "PLANTED CONTROL BROKEN: without the lexicon the idle agent is still classified: ${N}"
	echo "ok 7 - dashboard API: agent ${A}; controls: previous wrapper ${O}; no lexicon ${N}"
else
	echo "ok 7 - (skipped: no vendored dashboard at ${TA_JS} or no node)"
fi

CPID=$(pgrep -P "$(tmux display -p -t "=t03-agent:" '#{pane_pid}')" -x claude)
[ -n "${CPID}" ] || fail "no claude to stop in the agent pane"
kill -TERM "${CPID}"
for _ in $(seq 1 30); do [ "$(cmd_of t03-agent)" == "bash" ] && break; sleep 1; done
tmux has-session -t "=t03-agent" 2>/dev/null || fail "the session died with claude"
[ "$(cmd_of t03-agent)" == "bash" ] || fail "the pane did not fall back to a shell after claude exited (it reports '$(cmd_of t03-agent)')"
echo "ok 8 - claude stopped: the pane falls back to a shell and the session stays"

# --- 9. the GitHub plugin follows the token ---
mkdir -p ${D}/gh
plant_gh() { echo '{"env": {"A": "1"}, "enabledPlugins": {"claude-mem@thedotmack": true, "github@claude-plugins-official": true, "context7@claude-plugins-official": true}, "hooks": {"Stop": []}}' > ${D}/gh/settings.json; }
gh_state() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["enabledPlugins"][sys.argv[2]])' ${D}/gh/settings.json "${1:-github@claude-plugins-official}"; }
sync_gh() { env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN -u CONTEXT7_PLUGIN "$@" CLAUDE_CONFIG_DIR=${D}/gh KNOWLEDGE_DIR=${D}/knowledge "${AGENT_DIR}/claude-settings-sync.sh" > ${D}/gh/sync.log 2>&1; }
plant_gh
sync_gh
[ "$(gh_state)" == "False" ] || fail "with no token the GitHub plugin stays enabled: $(cat ${D}/gh/sync.log)"
python3 - ${D}/gh/settings.json << 'PYEOF' || fail "the GitHub gate changed another key"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["env"] == {"A": "1"} and d["enabledPlugins"]["claude-mem@thedotmack"] is True and d["hooks"]["Stop"] == []
PYEOF
SHA=$(sha256sum ${D}/gh/settings.json)
sync_gh
[ "$(sha256sum ${D}/gh/settings.json)" == "${SHA}" ] || fail "a re-sync with no token rewrote the settings"
for V in GH_TOKEN GITHUB_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
	plant_gh
	sync_gh "${V}=planted-not-a-token"
	[ "$(gh_state)" == "True" ] || fail "with ${V} set the GitHub plugin is not enabled: $(cat ${D}/gh/sync.log)"
	sync_gh
	[ "$(gh_state)" == "False" ] || fail "with ${V} removed again the GitHub plugin stays enabled"
done
echo '{"enabledPlugins": {"claude-mem@thedotmack": true}}' > ${D}/gh/settings.json
sync_gh GH_TOKEN=planted-not-a-token
python3 -c 'import json, sys; sys.exit(0 if "github@claude-plugins-official" not in json.load(open(sys.argv[1]))["enabledPlugins"] else 1)' ${D}/gh/settings.json \
	|| fail "the gate added the GitHub plugin to settings that did not have it installed"
# context7: off unless CONTEXT7_PLUGIN=true, and back off when the flag goes
plant_gh
sync_gh
[ "$(gh_state context7@claude-plugins-official)" == "False" ] || fail "with CONTEXT7_PLUGIN unset the context7 plugin stays enabled: $(cat ${D}/gh/sync.log)"
sync_gh CONTEXT7_PLUGIN=true
[ "$(gh_state context7@claude-plugins-official)" == "True" ] || fail "with CONTEXT7_PLUGIN=true the context7 plugin is not enabled: $(cat ${D}/gh/sync.log)"
[ "$(gh_state)" == "False" ] || fail "CONTEXT7_PLUGIN=true enabled the GitHub plugin too"
sync_gh CONTEXT7_PLUGIN=false
[ "$(gh_state context7@claude-plugins-official)" == "False" ] || fail "with CONTEXT7_PLUGIN=false the context7 plugin stays enabled"
# startup.sh's hand-over, run as startup.sh runs it (sh)
BLOCK=$(python3 -c 'import re, sys; print(re.search(r"\nif \[ -z \"\$\{GITHUB_PERSONAL_ACCESS_TOKEN\}\" \].*?\nfi\n", open(sys.argv[1]).read(), re.S).group(0))' "${BASE_DIR%/}/startup.sh") \
	|| fail "startup.sh has no GitHub token hand-over"
# shellcheck disable=SC2016 # the inner sh expands the variable
handed() { env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN "$@" sh -c "${BLOCK};"' echo "[${GITHUB_PERSONAL_ACCESS_TOKEN}]"'; }
{ [ "$(handed GH_TOKEN=a)" == "[a]" ] && [ "$(handed GITHUB_TOKEN=b)" == "[b]" ] && [ "$(handed)" == "[]" ] \
	&& [ "$(handed GH_TOKEN=a GITHUB_PERSONAL_ACCESS_TOKEN=c)" == "[c]" ]; } || fail "startup.sh's token hand-over is wrong: $(handed GH_TOKEN=a) $(handed GITHUB_TOKEN=b) $(handed) $(handed GH_TOKEN=a GITHUB_PERSONAL_ACCESS_TOKEN=c)"
echo "ok 9 - the GitHub plugin follows the token: off with none, on with GH_TOKEN, GITHUB_TOKEN or GITHUB_PERSONAL_ACCESS_TOKEN, every other key kept, no plugin -> untouched; startup.sh hands GH_TOKEN/GITHUB_TOKEN over, never over an explicit one; context7 only on CONTEXT7_PLUGIN=true"
IMG_DIR=${CLAUDE_CONFIG_DIR:-/home/agent/.claude}
if [ -x "${CLAUDE_BIN}" ] && [ -d "${IMG_DIR}/plugins" ] && [ -f "${IMG_DIR}/settings.json" ]; then
	mkdir -p ${D}/gh-live
	cp "${IMG_DIR}/settings.json" ${D}/gh-live/
	[ -f "${IMG_DIR}/.claude.json" ] && cp "${IMG_DIR}/.claude.json" ${D}/gh-live/
	ln -s "${IMG_DIR}/plugins" ${D}/gh-live/plugins
	# stdin from /dev/null: under ./test.sh's docker run -it the test's stdin is a terminal, and claude then waits for
	# an answer to its workspace-trust question about this untrusted folder (measured: no output until the timeout)
	mcp_list() { (cd ${D}/workdir && env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN "$@" CLAUDE_CONFIG_DIR=${D}/gh-live timeout 120 "${CLAUDE_BIN}" mcp list < /dev/null 2>&1); }
	live_sync() { env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN -u CONTEXT7_PLUGIN "$@" CLAUDE_CONFIG_DIR=${D}/gh-live KNOWLEDGE_DIR=${D}/knowledge "${AGENT_DIR}/claude-settings-sync.sh" > /dev/null 2>&1; }
	live_sync
	OFF=$(mcp_list)
	echo "${OFF}" > ${D}/gh-live/mcp-off.txt
	echo "${OFF}" | grep -q "Checking MCP server health" || fail "claude mcp list did not run: ${OFF}"
	echo "${OFF}" | grep -q "plugin:github:github" && fail "without a token claude still lists the GitHub MCP server: $(echo "${OFF}" | grep github)"
	echo "${OFF}" | grep -q "plugin:context7:context7" && fail "by default claude still lists the context7 MCP server: $(echo "${OFF}" | grep context7)"
	echo "${OFF}" | grep -qi "needs authentication" && fail "by default an MCP server still needs authentication: $(echo "${OFF}" | grep -i 'needs authentication')"
	live_sync GH_TOKEN=planted-not-a-token
	ON=$(mcp_list GITHUB_PERSONAL_ACCESS_TOKEN=planted-not-a-token)
	echo "${ON}" > ${D}/gh-live/mcp-on.txt
	echo "${ON}" | grep -q "plugin:github:github" || fail "with a token claude does not list the GitHub MCP server: ${ON}"
	live_sync CONTEXT7_PLUGIN=true
	C7=$(mcp_list)
	echo "${C7}" > ${D}/gh-live/mcp-context7.txt
	echo "${C7}" | grep -q "plugin:context7:context7" || fail "with CONTEXT7_PLUGIN=true claude does not list the context7 MCP server: ${C7}"
	echo "ok 9 - claude mcp list: by default no GitHub or context7 MCP server and nothing needing authentication; a token -> GitHub listed and tried ($(echo "${ON}" | grep -o 'plugin:github:github.\{0,60\}')); CONTEXT7_PLUGIN=true -> context7 listed ($(echo "${C7}" | grep -o 'plugin:context7:context7.\{0,40\}' | tail -c 30))"
else
	echo "ok 9 - (claude mcp list skipped: no claude or plugins in this context)"
fi

# --- 10. the user's /wd/knowledge is left alone ---
[ "$(wd_knowledge_state)" == "${KNOWLEDGE_BEFORE}" ] || fail "this test wrote under the user's /wd/knowledge (a settings sync without a test-local KNOWLEDGE_DIR): $(find /wd/knowledge -maxdepth 2 2>/dev/null | head -5 | tr '\n' ' ')"
[ "${AGENT_KNOWLEDGE:-true}" == "false" ] || [ -d ${D}/knowledge/defaults ] || fail "the settings syncs wrote no test-local knowledge copy (${D}/knowledge): the knowledge step did not run where this test points it"
echo "ok 10 - the user's /wd/knowledge is as it was; the settings syncs wrote their knowledge copy under ${D}/knowledge"

echo "Test-agent-terminal succeeded"
