#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the spoke agents (docs/manual/agents.md "Spoke agents"): the registry (/agent/spokes/registry.json, the only source of
# what runs), the charters (/agent/charters/<name>/charter.md) and their check (/agent/spoke.sh), the start of a session
# from its entry (/agent/tmux-session-start.sh <name>), the messages (/agent/bus.sh), the supervisor (/agent/supervisor.sh,
# /agent/fleet-check.sh) and the tiles.
# Fully OFFLINE: a test-local registry, charters, working directories and state under /tmp/spokes-smoke (or TEST22_DIR);
# nothing under /wd.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the scripts parse (bash -n) and the registry is JSON; with a checkout, every deletion in the spoke scripts passes
#      tools/check-deletions.py (a literal target or ${VAR:?} guards). PLANTED CONTROL: the lint's own self-test
#   2. the registry and the charters: the shipped registry passes /agent/spoke.sh check - its hub, its supervisor and
#      its spokes, each spoke's charter carrying a North Star, a Source and a Writes section and the six rules every spoke
#      carries (loopback only; nothing leaves without a human GO; read-only on clusters unless a goal says otherwise;
#      never type into another session's menu; ${VAR:?} guards on deletions; the charter states what it writes) - and it
#      lists the decided spokes: conversations, insights, clusters, sessions, loops, issues, docker and the example, each with its
#      SPOKE_<NAME> flag off, its working directory /wd/<name>, its charter /agent/charters/<name>/charter.md and agent as
#      its parent; the template carries the sections and the rules; the seed's privacy scan passes the charters and the
#      registry (tree mode). PLANTED CONTROLS, each failing for its own reason: a copy of the example charter without
#      each of the six rules in turn and without each of the three sections; registry entries whose source is not public
#      or not shipped - ssh, a token in the URL, plain http, a host path, a vendored path outside the image's trees, a
#      vendored path climbing out, a URL without a ref, a ref that opens with a dash (git would read it as an option) -
#      a reserved name, the hub's name, a name twice, a flag that is not SPOKE_<NAME>, no writes, a cycle that is not in
#      the image, notices that climb out of the workdir; a registry with no spoke at all (nothing to check is not a
#      pass); and, through the scan, a registry source naming a private repository and a charter naming a person
#   3. a session starts from its entry (/agent/tmux-session-start.sh <name>; a test-local spoke from a copy of the
#      example's charter, a stub claude that records where it runs and stays up): the default tmux server - the one the
#      browser terminal's session picker (C-b s) and the tmux-agent dashboard read - lists the session within 30 s; its
#      options carry @agent_parent <the entry's parent>, @agent_owner do-agent-aws and @agent_task <the entry's task>,
#      and the dashboard (the vendored build, started by ui-start.sh on a test port) lists it in /api/fleet with that
#      lineage; claude runs in the entry's workdir, where CLAUDE.md is the charter byte for byte, repo/ links the
#      vendored tree and the folder is trusted in claude's configuration; the entry's env reaches the pane;
#      state.json records the start (time, generation 1, the charter's sha256, the source); a second start leaves the
#      session untouched. PLANTED CONTROLS: an entry whose charter lacks its writes rule is refused and starts no session;
#      a claude that exits at once ends its spoke's session within 3 s - five times, and the other spoke's session on the
#      same server outlives each (this image's tmux 3.2a crashed its server when a start queried such a session) - while
#      the same claude in a pane with the shell fallback on (the hub's default) leaves a shell behind
#   3b. a URL source, served by a test-local https remote (self-signed certificate, git's dumb http): the clone is at the
#      entry's ref with its commit in state.json; after a new upstream commit a restart refreshes it (git pull
#      --ff-only); a source that answers 401 is refused, and a credential helper in the git configuration the start
#      inherits is never asked. PLANTED CONTROL: git with that same configuration asks the helper
#   4. messages (/agent/bus.sh, the bus v1 journal and projections, test-local): the hub's request to a spoke is one
#      message.accepted line in the journal (the v1 envelope - v 1, a UUID id, from, to, a UTC millisecond ts, kind,
#      text, reply_to - and its routing, seq 1) and one record in the spoke's inbox with its canonical hash; the journal
#      is private (0700, 0600); poll lists it, peek shows it, the spoke's reply goes back with reply_to in the same
#      conversation, marks the request replied and closes it; both ends' sessions carry @agent_last_message; inside a
#      tmux pane the pane's session is the sender whatever BUS_AGENT_ID says, and a pane of a session the registry does
#      not list sends nothing; terminal controls and direction overrides are removed, a credential shape is redacted, a
#      text that is a shell command is data and nothing runs it; the supervisor's notice to the hub and the hub's read
#      receipt. Refused, and never journaled: an unknown recipient, a spoke writing to another spoke, a request from the
#      supervisor, a reply by an agent the request was not sent to, a second answer (a reply, then an error) to a
#      request already answered, a kind that is not one of the four, an empty text, a
#      text too long for its journal line, a sender outside tmux without BUS_AGENT_ID, a sender the registry does not
#      list. The vendored bus-v1-check.py passes the projection root and the journal bus.sh wrote. PLANTED CONTROLS: the
#      validator refuses a record whose kind is not v1 (exit 2) and its own self-test passes; an inbox record written
#      around bus.sh (never journaled) and a journaled record whose text was changed afterwards are held back and named
#   5. the supervisor (/agent/supervisor.sh; interval 1 s, cap 3, cooldown 2 s here): it starts an enabled spoke within
#      one interval; one cycle later last-cycle is newer than the start, the cycle's status.txt is in the workdir, the
#      status row reads LIVE and status.json "live"; tmux kill-session brings the session back within the interval + 5 s
#      with one restart line and a notice to the hub; a hub question gets the spoke's answer from its own cycle - in the journal with reply_to,
#      open in the hub's inbox, and as the spoke's last message in status.json; each pass is one record of passes.jsonl;
#      the supervisor's tmux session shows its last pass, sits under the hub and carries it as its task, which the tmux-agent
#      dashboard lists; a second loop refuses to run. PLANTED CONTROLS: a spoke whose claude exits at once is restarted
#      with a growing backoff, then marked stuck at the cap - three restart lines and one stuck line, state.json and
#      status.json "stuck", a STUCK row and exit 1, its reason naming what the last start said, a notice to the hub - and
#      is never started again; a spoke whose flag is on but whose charter is not there goes stuck the same way, its reason
#      naming the missing charter; a spoke whose flag is off gets no session
#      Started from a tmux pane, the loop runs without that pane's TMUX and TMUX_PANE; an interval of 0 or "abc" is
#      refused before anything runs; a supervisor.sh stop lasts through ensure (STOPPED, the flag kept), and only start
#      clears it. In check 8, a /compact that fleet-check.sh refused is not recorded as sent, and the agent session's
#      own menu stays in status.json with no notice to the inbox.
#   5c. a spoke whose entry requires settings that are unset (the shipped conversations entry's SLACK_BOT_TOKEN and
#      SLACK_CHANNELS, "Slack") waits: its state reads "waiting for Slack (SLACK_BOT_TOKEN/SLACK_CHANNELS)" (and its own
#      state.json "waiting", "live" once it goes on - never the "starting" of its start) within a few
#      passes and stays so for three more, its cycle never runs, nothing restarts, no notice goes to the hub, its row
#      reads WAITING with how to set them and ui-status's exit is not failed by it, and the supervisor's task line names
#      it; started again with both set, it leaves the waiting state and goes live after its cycle
#   5b. the supervisor's cost: with every session off, a pass starts at most 4 python3 processes and supervisor.sh status
#      (ui-status.sh's rows) at most 4 (PLANTED CONTROL: the shim that counts them saw some); the mailbox log is read
#      from where the last pass stopped (last-messages.json, its offset at the log's end): an appended message is read, a
#      line still being written waits, and a log replaced by a new file or rewritten shorter in place is read again from
#      its start
#   6. flags, rows and tiles (home-render.sh, ui-start.sh, ui-status.sh; a test-local home listener): the line under the
#      Agents heading names the spokes that run and how to turn one off (with every flag off, that none runs); with the
#      shipped defaults the seven spokes' tiles are live and every agent tile's link keeps its opener; with every flag
#      off, the home page has a greyed tile per spoke of the registry - the example's "off - set SPOKE_EXAMPLE=true in
#      .env.local" with what it writes and what it costs - and the supervisor's greyed with its flag, no tile is live,
#      nginx.conf has no /__spokes route, ui-status.sh's rows read OFF and leave its exit code 0 - also for a spoke whose
#      flag is on while SUPERVISOR=false, whose row names the setting that runs none (PLANTED CONTROL: the same spoke
#      with SUPERVISOR=true and no supervisor running reads the supervisor DOWN, the spoke UNKNOWN, and exits 1) - and
#      the supervisor's
#      start with SUPERVISOR=false starts and writes nothing. With the supervisor on (the shipped default) its tile is
#      live and the route is there. With a spoke's flag on: ui-start.sh's rows name the supervisor and the spoke, its tile
#      is live with the state line the page's script fills from /__spokes, and the proxy serves /__spokes (the spoke
#      "live", its last message; never cached; POST refused). PLANTED CONTROLS: a stuck spoke makes ui-status.sh exit 1;
#      a supervisor whose last pass is old reads STALE (exit 1), ensure starts it again and tells the hub, and ensure is
#      quiet when all is well
#   7. the .env contract (when a checkout is at hand): seven SPOKE_ flags ship true, SPOKE_EXAMPLE false and SUPERVISOR true,
#      SPOKE_ENV_OPTS passes them and the supervisor's settings and AGENT_ENV_OPTS carries it, the compose and
#      kubernetes templates pass each; startup.sh starts the supervisor after the shared agent session and its keepalive
#      loop runs supervisor.sh ensure; every test that runs the real startup.sh turns the supervisor off; the docker
#      spoke's build substrate as shipped: both sidecar images pinned by tag and digest in .env, run.sh's
#      DOCKER_SUBSTRATE=failed marker for a substrate that did not come up, the home listener's /v1/ path reserved
#      from spoke pages (spoke.sh's HOME_PATHS), and the README's four Docker agent limits
#   7b [plain-run-set]. a plain start, .env's own defaults with no .env.local, as startup.sh runs it (the agent session,
#      then the supervisor) on a fresh tmux server at the shipped interval: tmux ls has a session for each session the
#      registry enables, agent, clusters, conversations, docker, insights, issues, loops, sessions and supervisor, and the check names any
#      it lacks (PLANTED CONTROL: with the supervisor stopped and loops killed, it names loops; started again, it passes)
#      - the shipped registry with no fetch, no cycles and its directories test-local, a stub claude
#   7c [killed-spoke-returns]. on that start, a killed spoke is back within 20 s at the shipped interval, with one restart
#      line
#   8. the fleet check (/agent/fleet-check.sh, through the supervisor): planted panes - a menu and a menu whose answer
#      would send read stuck and get no key in five more passes; "API Error", "Prompt is too long" and a failed
#      compaction read stuck; an idle pane whose status line is the image's own (/agent/claude-statusline.sh, at 85%)
#      gets /compact exactly once; a pane that runs a turn at
#      92% reads working and gets nothing; a pane without claude reads down; the hub's pane with a shell is reported and
#      never replaced, and its session gone is started again; the memory API's /health and the session-memory worker's
#      queue depth (900, deep) are in status.json, a memory API that stops answering reads down and its recovery is told,
#      and one that comes up within the start grace is never reported (PLANTED CONTROL: without the grace it is); every finding is one
#      bus notice from the supervisor to the hub; the fleet check by hand refuses to compact a busy pane or one at a menu,
#      and reads the fleet HUD's form of the status line, ctx:[bar]85%, as context at 85%; an idle pane whose last turn left
#      "✻ Cooked for 8s · done" is not working and gets /compact exactly once; a pane whose input line does not show the
#      typed /compact gets no Enter. A window a person opens in a session is not the agent's pane (@agent_pane, recorded at
#      its start): in a spoke's session the person's own claude idle at 85% gets nothing and the agent's pane gets the
#      /compact; in the hub's session the hub stays live, with no notice. A pane at 85% whose input line holds a person's
#      draft gets no key: PLANTED CONTROL, a fleet check without its idle gate types into it.
#      With the stack on, no session the harness started reads ORPHANED on the tmux-agent dashboard, and the dashboard
#      does not read the supervisor itself as ERROR or BLOCKED while it reports stuck panes. PLANTED CONTROL: a
#      copy of the supervisor whose menu branch types "1" and Enter is caught by the planted pane's log
#   8b [menu-prose]. a sentence is not a menu: an idle pane whose answer says "returned yes, and the API" (a spoke's
#      own words, which the fleet check read as an open menu, so the supervisor marked that idle spoke stuck), opens
#      a line with "Yes, and" and has a numbered item "1. Yes, and ..." reads idle; the same answer in a pane whose
#      prompt holds a person's draft reads no menu; Claude Code's approval menu (2.1.296, as test-agent-chat.sh check 20
#      captured it) reads menu, decided by its numbered option line "3. Yes, and switch to auto mode". PLANTED CONTROLS:
#      a fleet check that counts a numbered option line above an empty prompt line reads the idle pane as a menu on its
#      numbered item, and one that takes "Yes, and" anywhere on a line, in any case, for a menu option reads the pane
#      with the draft as a menu
#   9. the hub alone (no spoke, no supervisor): its session carries @agent_parent operator, @agent_owner do-agent-aws and
#      the registry's task, and the dashboard lists it under operator, not ORPHANED. PLANTED CONTROL: a session started
#      without lineage, the way the hub's session was started before, reads ORPHANED
#  10. the documentation: docs/AGENT-STACK.md has a row per session of the registry in each of its two tables, with its
#      flag and shipped default, and the North Star register's agents and North Stars as written (an agent the register
#      scores before its session ships is not in the registry yet: test-north-star.sh check 9 holds it); the README and the
#      Guide link it and docs/INTER-AGENT-MESSAGING.md; home-render.sh serves both under /guide/. PLANTED CONTROL: a
#      missing source renders a page that says so
# 10b. the spokes' own checks: every cycle the shipped registry names is installed and executable under
#      /agent/charters/<name>/, no charter runs ./loop.sh in the working directory, and no charter or loop names an interval
#      variable of its own (the supervisor drives every cycle at the registry's cadence); the clusters loop's --self-test,
#      one cycle against a stub kubectl whose context is named like an EKS cluster ARN (read, with a safe cache stem), its
#      wrapper refusing kubectl auth reconcile and passing auth can-i; the insights loop's --self-test; the conversations
#      loop's --stub-test where the engine has the stub Slack API override
#  11. in the test container (TEST_CONTAINER=true, /wd the suite's throwaway) the test leaves no entry under /wd that
#      was not there when it started: every ui-start.sh it runs keeps the UIs it does not test off and points
#      LOOP_DECK_DATA_DIR, which ui-start.sh's Loop Deck adapter writes at every start, into the test's directory.
#      PLANTED CONTROL: an entry planted under /wd during the test is named

fail()
{
	echo "Test22 FAILED: $1"
	exit 1
}

# run from inside a tmux pane, bus.sh would take every sender from that pane, and every tmux call would mean the pane's
# server: this test means its own
unset TMUX TMUX_PANE

D=${TEST22_DIR:-/tmp/spokes-smoke}
rm -rf "${D:?}"
mkdir -p "${D}/planted"
# what /wd holds before this test (check 11)
find /wd -mindepth 1 2>/dev/null | sort > "${D}/wd-before.txt"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
CHARTERS="${AGENT_DIR}/charters"
SPOKE="${AGENT_DIR}/spoke.sh"
SHIPPED_REGISTRY="${AGENT_DIR}/spokes/registry.json"
SCAN=/seed/scan.py; [ -f "${SCAN}" ] || SCAN="${BASE_DIR%/}/seed/scan.py"
# ports found free now, one list for the whole run (python holds them all open while it looks, so none repeats): the
# tmux-agent dashboard, the home page, the https git server, the session-memory worker, the memory API and the memory API
# that comes up late
mapfile -t PORTS < <(python3 - << 'PYEOF'
import socket
socks = []
for _ in range(6):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); socks.append(s)
for s in socks:
    print(s.getsockname()[1])
for s in socks:
    s.close()
PYEOF
)
[ "${#PORTS[@]}" == "6" ] || fail "could not find 6 free ports"
DASH_PORT=${PORTS[0]} HOME_PORT=${PORTS[1]} GIT_PORT=${PORTS[2]} WORKER_PORT=${PORTS[3]} API_PORT=${PORTS[4]} LATE_API_PORT=${PORTS[5]}
# every shipped spoke's flag off, for the runs that read the shipped registry: seven ship on, and a suite's container gets
# the .env flags, so "every spoke off" names each one
mapfile -t ALL_OFF < <(SPOKES_REGISTRY="${SHIPPED_REGISTRY}" "${SPOKE}" table | awk '$2 == "spoke" { print $4 "=false" }')
[ "${#ALL_OFF[@]}" -ge 6 ] || fail "the shipped registry's table lists ${#ALL_OFF[@]} spokes"

# test-local everything: the registry, charters, working directories, the supervisor's state, the journal, claude's
# configuration; the hub's name; the tmux sessions this test starts
REG=${D}/registry.json
export SPOKES_REGISTRY=${REG} SUPERVISOR_DIR=${D}/supervisor AGENT_TMUX_SESSION_NAME=t22-hub
export MAILBOX_STATE_ROOT=${D}/mailbox-state MAILBOX_PROJECTION_ROOT=${D}/mailbox
export CLAUDE_CONFIG_DIR=${D}/claude-config UI_START=false
# the dashboard's home, where an agent session's start pipes its pane (tmux-session-start.sh's capture log)
export TMUX_AGENT_HOME=${D}/tmux-agent-home
mkdir -p "${D}/charters" "${CLAUDE_CONFIG_DIR}"
SESSIONS="t22ex t22url t22priv t22exits t22fallback t22nowrites t22-hub t22pane t22w t22dies t22off t22none t22two"
HTTPS_PID=""
HEALTH_PIDS=""
FIRST_TMPDIRS=""
cleanup()
{
	for F in ${FIRST_TMPDIRS}; do
		for S in t22first supervisor t22later agent clusters conversations docker insights issues loops sessions; do
			env -u TMUX -u TMUX_PANE TMUX_TMPDIR="${F}" tmux kill-session -t "=${S}" 2>/dev/null
		done
	done
	for P in "${D}/sup-slack/supervisor.pid" "${D}/plain/sup/supervisor.pid"; do [ -f "${P}" ] && kill "$(cat "${P}")" 2>/dev/null; done
	[ -f "${SUPERVISOR_DIR}/supervisor.pid" ] && kill "$(cat "${SUPERVISOR_DIR}/supervisor.pid")" 2>/dev/null
	[ -n "${HEALTH_PIDS}" ] && kill ${HEALTH_PIDS} 2>/dev/null
	for S in ${SESSIONS}; do tmux kill-session -t "=${S}" 2>/dev/null; done
	[ -n "${HTTPS_PID}" ] && kill "${HTTPS_PID}" 2>/dev/null
	[ -f "${D}/ui/tmux-agent.pid" ] && UI_DIR=${D}/ui "${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
	[ -f "${D}/ui-home/home.pid" ] && UI_DIR=${D}/ui-home "${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT TERM
EXAMPLE="${CHARTERS}/example/charter.md"
# charter <name> [<sed expression>] - a test-local copy of the example charter, as ${D}/charters/<name>/charter.md
charter()
{
	mkdir -p "${D}/charters/$1"
	sed -e "${2:-}" "${EXAMPLE}" > "${D}/charters/$1/charter.md"
}
# entry <name> [<json object of keys to set or, with a null value, to drop>] - a test-local spoke in ${REG}: the example's
# entry from the shipped registry with this name, its charter and workdir test-local, its parent the test's hub
entry()
{
	python3 - "${REG}" "${SHIPPED_REGISTRY}" "${D}" "$1" "${2:-{\}}" "${AGENT_TMUX_SESSION_NAME}" << 'EOF' || fail "could not write the test registry entry $1"
import json, os, sys
reg, shipped, d, name, extra, hub = sys.argv[1:7]
doc = json.load(open(reg)) if os.path.exists(reg) else {"version": 1, "sessions": []}
if not doc["sessions"]:
    h = next(e for e in json.load(open(shipped))["sessions"] if e["role"] == "hub")
    doc["sessions"].append(dict(h, session_name=hub))
e = dict(next(e for e in json.load(open(shipped))["sessions"] if e["session_name"] == "example"))
e.update(session_name=name, flag="SPOKE_" + name.upper().replace("-", "_").replace(".", "_"), workdir=f"{d}/wd/{name}",
         charter=f"{d}/charters/{name}/charter.md", parent=hub, task=f"test spoke {name}: a timestamp every cycle")
for k, v in json.loads(extra).items():
    if v is None:
        e.pop(k, None)
    else:
        e[k] = v
doc["sessions"] = [s for s in doc["sessions"] if s.get("session_name") != name] + [e]
json.dump(doc, open(reg, "w"), indent=1)
EOF
}
# stub <dir> <exit|stay> - a claude (named claude, in <dir>) that records its directory, the sha256 of the CLAUDE.md
# there, its arguments and one variable of the entry's env
stub()
{
	mkdir -p "$1"
	{
		echo '#!/bin/bash'
		echo "echo \"cwd=\$(pwd) claude_md=\$(sha256sum < CLAUDE.md 2>/dev/null | cut -d' ' -f1) args=\$* t22_env=\${T22_ENV:-}\" >> $1/claude.log"
		[ "$2" == "stay" ] && echo 'while :; do sleep 1; done'
		[ "$2" == "exit" ] && echo 'exit 3'
	} > "$1/claude"
	chmod +x "$1/claude"
}

# --- 1. syntax ---
for S in "${SPOKE}" "${CHARTERS}"/*/cycle.sh "${CHARTERS}"/*/loop.sh "${AGENT_DIR}/tmux-session-start.sh" "${AGENT_DIR}/tmux-claude.sh" \
         "${AGENT_DIR}/bus.sh" "${AGENT_DIR}/supervisor.sh" "${AGENT_DIR}/fleet-check.sh" "${AGENT_DIR}/home-render.sh" "${AGENT_DIR}/ui-start.sh" \
         "${AGENT_DIR}/ui-status.sh" "${BASE_DIR%/}/startup.sh"; do
	[ -f "${S}" ] || fail "${S} is missing"
	bash -n "${S}" || fail "bash -n ${S}"
done
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "${SHIPPED_REGISTRY}" || fail "the registry ${SHIPPED_REGISTRY} is not JSON"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${AGENT_DIR}/bus-v1-check.py" || fail "the vendored bus-v1-check.py does not parse"
# every deletion in the spoke scripts names a target a static reader can verify: the checkout's tools/check-deletions.py
LINT=""
for C in "${BASE_DIR}/.." /do-agent-aws; do [ -f "${C}/tools/check-deletions.py" ] && LINT="${C}/tools/check-deletions.py" && break; done
LINT_NOTE="(no checkout here: the deletion lint runs from one)"
if [ -n "${LINT}" ]; then
	python3 -I "${LINT}" --self-test > /dev/null || fail "PLANTED CONTROL: the deletion lint's self-test fails, so a clean lint proves nothing"
	OUT=$(python3 -I "${LINT}" "${SPOKE}" "${CHARTERS}" "${AGENT_DIR}/tmux-session-start.sh" "${AGENT_DIR}/tmux-claude.sh" "${AGENT_DIR}/bus.sh" \
		"${AGENT_DIR}/supervisor.sh" "${AGENT_DIR}/fleet-check.sh" "$0" 2>&1) || fail "a deletion in the spoke scripts uses an unguarded variable: ${OUT}"
	LINT_NOTE="every deletion in the spoke scripts passes tools/check-deletions.py (its self-test passes)"
fi
echo "ok 1 - syntax, and the registry is JSON; ${LINT_NOTE}"

# --- 2. the registry and the charters: the check, the decided spokes, the six rules, the sources, the scan ---
OUT=$(SPOKES_REGISTRY=${SHIPPED_REGISTRY} AGENT_TMUX_SESSION_NAME=agent "${SPOKE}" check 2>&1) || fail "the shipped registry breaks its rules: ${OUT}"
python3 - "${SHIPPED_REGISTRY}" << 'EOF' || fail "the shipped registry does not list the decided agents the way they were decided"
import json, sys
s = json.load(open(sys.argv[1]))["sessions"]
roles = [(e["session_name"], e["role"]) for e in s]
assert roles[:2] == [("agent", "hub"), ("supervisor", "supervisor")], roles
spokes = [e for e in s if e["role"] == "spoke"]
assert [e["session_name"] for e in spokes] == ["conversations", "insights", "clusters", "sessions", "loops", "issues", "docker", "example"], spokes
for e in spokes:
    n = e["session_name"]
    assert e["flag"] == "SPOKE_" + n.upper() and e["enabled"] is (n != "example"), e
    assert e["workdir"] == "/wd/" + n and e["charter"] == f"/agent/charters/{n}/charter.md" and e["parent"] == "agent", e
    # every spoke's claude starts through the harness's launcher; the issues spoke's pane first drops its GitHub token and
    # writes its session's settings (charters/issues/pane.sh), the docker spoke's its registry login (charters/docker/pane.sh),
    # then each execs it
    want = f"/agent/charters/{n}/pane.sh" if n in ("issues", "docker") else "/agent/tmux-claude.sh"
    assert e["launch_cmd"] == want and e["agent_process"] == "claude", e
EOF
for P in issues docker; do
	grep -qxF 'exec "${AGENT_TMUX_LAUNCHER:-${HERE%/*/*}/tmux-claude.sh}"' "${CHARTERS}/${P}/pane.sh" \
		|| fail "the ${P} spoke's pane.sh does not end in the harness's launcher, tmux-claude.sh"
done
N=$(SPOKES_REGISTRY=${SHIPPED_REGISTRY} "${SPOKE}" names | grep -c .)
[ "${N}" -ge 1 ] || fail "the shipped registry lists no spoke"
OUT=$("${SPOKE}" check-charter "${CHARTERS}/template.md" 2>&1) || fail "the template does not carry the sections and the six rules every charter starts from: ${OUT}"
python3 "${SCAN}" --tree "${CHARTERS}" "${AGENT_DIR}/spokes" > "${D}/scan.out" 2>&1 || fail "the seed's privacy scan refuses the charters or the registry: $(tail -3 "${D}/scan.out")"
# plant <name> <finding the check must print> - a copy of the example charter, changed by the sed expression in $SED:
# the charter check must exit 1 with that finding
plant()
{
	P="${D}/planted/$1.md"
	sed -e "${SED}" "${EXAMPLE}" > "${P}"
	cmp -s "${P}" "${EXAMPLE}" && fail "PLANTED CONTROL '$1': the expression changed nothing"
	OUT=$("${SPOKE}" check-charter "${P}") && fail "PLANTED CONTROL: '$1' passed the charter check"
	echo "${OUT}" | grep -qF "$2" || fail "PLANTED CONTROL: '$1' failed for another reason: ${OUT}"
}
SED='/Loopback only/d'; plant no-loopback "the rule 'loopback only' is missing"
SED='/Nothing leaves without a human GO/d'; plant no-go "the rule 'nothing leaves without a human GO' is missing"
SED='/Read-only on clusters/d'; plant no-readonly "the rule 'read-only on clusters unless a goal says otherwise' is missing"
SED="/Never type into another session's menu/d"; plant no-menu "the rule 'never type into another session's menu' is missing"
SED='/guards on every deletion/d'; plant no-guard "the rule '\${VAR:?} guards on deletions' is missing"
SED='/What it writes is stated here/d'; plant no-writes "the rule 'the charter states what it writes' is missing"
SED='s/^## North Star$/## Purpose/'; plant no-north-star "no a North Star section"
SED='s/^## Source$/## Origin/'; plant no-source "no a Source section"
SED='s/^## Writes only$/## Output/'; plant no-writes-section "no a section on what it writes"
# rplant <name> <json of the entry's keys> <finding> - a test-local registry with one bad spoke: the check must exit 1 with
# that finding
mkdir -p "${D}/charters/t22ex"
cp "${EXAMPLE}" "${D}/charters/t22ex/charter.md"
rplant()
{
	cp "${REG}" "${D}/planted/registry.json" 2>/dev/null || rm -f "${D:?}/planted/registry.json"
	OUT=$(REG=${D}/planted/registry.json; entry t22ex "$2"; SPOKES_REGISTRY=${REG} "${SPOKE}" check 2>&1) && fail "PLANTED CONTROL: the registry entry '$1' passed the check"
	echo "${OUT}" | grep -qF -- "$3" || fail "PLANTED CONTROL: the registry entry '$1' failed for another reason: ${OUT}"
}
rplant ssh-source '{"source": "git@git.example.com:someone/spoke.git", "ref": "main"}' "is neither 'none', 'vendored: <path>' nor a public https URL"
rplant token-source '{"source": "https://user:planted@git.example.com/someone/spoke.git", "ref": "main"}' "is not a plain public https URL"
rplant http-source '{"source": "http://github.com/someone/spoke.git", "ref": "main"}' "is neither 'none', 'vendored: <path>' nor a public https URL"
rplant host-path '{"source": "/home/someone/spoke"}' "is neither 'none', 'vendored: <path>' nor a public https URL"
rplant wd-vendored '{"source": "vendored: /wd/elsewhere"}' "is not a tree the image ships (under /agent/ or /opt/)"
rplant climbing '{"source": "vendored: /agent/../etc"}' "is not a plain path"
rplant no-ref '{"source": "https://github.com/someone/spoke.git", "ref": null}' "a URL source needs a ref"
rplant dash-ref '{"source": "https://github.com/someone/spoke.git", "ref": "--no-checkout"}' "that opens with a letter or digit"
rplant reserved '{"session_name": "operator"}' "the name is reserved"
rplant hub-name "{\"session_name\": \"${AGENT_TMUX_SESSION_NAME}\"}" "takes the hub session's name"
rplant bad-flag '{"flag": "KUBE"}' "is not SPOKE_<NAME>"
rplant no-writes '{"writes": []}' "writes is not a list of the paths it writes"
rplant no-cycle '{"cycle": "/agent/charters/nowhere/cycle.sh"}' "is not an executable file in this image"
rplant climbing-notices '{"notices": "jsonl:../other/alerts.jsonl"}' "climbs out of the workdir"
rplant bad-env '{"env": {"T22": "two\nlines"}}' "env is not an object of NAME: one-line string"
rplant bad-requires '{"requires": ["slack token"]}' "requires is not a list of environment variable NAMES"
rplant bad-requires-what '{"requires": ["T22_NEEDS"], "requires_what": "a Slack app"}' "requires_what is not one word"
# a name twice: the same entry appended under its own name again
entry t22ex
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["sessions"].append(dict(d["sessions"][-1])); json.dump(d, open(sys.argv[2], "w"))' "${REG}" "${D}/planted/twice.json"
OUT=$(SPOKES_REGISTRY=${D}/planted/twice.json "${SPOKE}" check 2>&1) && fail "PLANTED CONTROL: a registry with a name twice passed the check"
echo "${OUT}" | grep -qF "the name is in the registry twice" || fail "PLANTED CONTROL: the name twice failed for another reason: ${OUT}"
# nothing to check is not a pass: a registry with the hub and no spoke
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["sessions"] = [e for e in d["sessions"] if e["role"] != "spoke"]; json.dump(d, open(sys.argv[2], "w"))' \
	"${SHIPPED_REGISTRY}" "${D}/planted/no-spoke.json"
OUT=$(SPOKES_REGISTRY=${D}/planted/no-spoke.json AGENT_TMUX_SESSION_NAME=agent "${SPOKE}" check 2>&1) && fail "PLANTED CONTROL: a registry with no spoke passed the check"
echo "${OUT}" | grep -qF "lists no spoke" || fail "PLANTED CONTROL: the registry with no spoke failed for another reason: ${OUT}"
[ "$(SPOKES_REGISTRY=${D}/planted/no-spoke.json "${SPOKE}" names | grep -c .)" == "0" ] || fail "the planted registry still lists a spoke"
rm -f "${REG:?}"
# through the scan: names are assembled here so this file carries none of them
PRIVATE=$(printf 'fleet-%s-engineering' loop)
PERSON=$(printf 'Al%s' ex)
mkdir -p "${D}/scan-private" "${D}/scan-person"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); [e.update(source="https://github.com/someone/" + sys.argv[3] + ".git", ref="main") for e in d["sessions"] if e["session_name"] == "example"]; json.dump(d, open(sys.argv[2], "w"), indent=1)' \
	"${SHIPPED_REGISTRY}" "${D}/scan-private/registry.json" "${PRIVATE}"
grep -qF "${PRIVATE}.git" "${D}/scan-private/registry.json" || fail "could not plant the private source in a registry copy"
python3 "${SCAN}" --tree "${D}/scan-private" > "${D}/scan-private.out" 2>&1 && fail "PLANTED CONTROL: the scan passed a registry whose source names a private repository"
grep -q "denylist-name" "${D}/scan-private.out" || fail "the private-source finding is not a denylist-name: $(cat "${D}/scan-private.out")"
sed -e "s/^A resident session in the container's tmux/${PERSON} asked for you. A resident session in the container's tmux/" "${EXAMPLE}" > "${D}/scan-person/charter.md"
grep -qF "${PERSON} asked for you" "${D}/scan-person/charter.md" || fail "could not plant the person's name in a charter copy"
python3 "${SCAN}" --tree "${D}/scan-person" > "${D}/scan-person.out" 2>&1 && fail "PLANTED CONTROL: the scan passed a charter naming a person"
grep -q "denylist-name" "${D}/scan-person.out" || fail "the person finding is not a denylist-name: $(cat "${D}/scan-person.out")"
echo "ok 2 - the shipped registry (${N} spokes: the decided seven on and the example off, /wd/<name>, parent agent) and its charters pass the check and the privacy scan, the template carries the sections and the six rules; 9 planted charters, 18 planted registry entries, a registry without a spoke and 2 planted names are refused, each for its own reason"

# --- 3. a session from its entry: the session, its lineage, its directory, its start ---
if ! command -v tmux > /dev/null; then
	fail "tmux is not installed - the spokes cannot run (setup/install-tmux.sh)"
fi
charter t22ex
entry t22ex '{"env": {"T22_ENV": "from-the-entry"}}'
stub "${D}/stay" stay
OUT=$(CLAUDE_BIN=${D}/stay/claude "${AGENT_DIR}/tmux-session-start.sh" t22ex 2>&1) || fail "tmux-session-start.sh t22ex: ${OUT}"
for I in $(seq 1 30); do tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qx t22ex && break; sleep 1; done
tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qx t22ex || fail "the default tmux server does not list the spoke's session t22ex 30 s after its start: ${OUT}"
TITLE=$("${SPOKE}" entry t22ex task)
for KV in "@agent_parent=${AGENT_TMUX_SESSION_NAME}" "@agent_owner=do-agent-aws" "@agent_task=${TITLE}"; do
	V=$(tmux show-options -t "=t22ex:" -v "${KV%%=*}" 2>/dev/null)
	[ "${V}" == "${KV#*=}" ] || fail "the spoke's session option ${KV%%=*} is '${V}', not '${KV#*=}'"
done
SD=${D}/wd/t22ex
for I in $(seq 1 20); do [ -s "${D}/stay/claude.log" ] && break; sleep 0.5; done
grep -qxF "cwd=${SD} claude_md=$(sha256sum < "${D}/charters/t22ex/charter.md" | cut -d' ' -f1) args= t22_env=from-the-entry" "${D}/stay/claude.log" \
	|| fail "claude did not start in ${SD} with the charter as its CLAUDE.md and the entry's env: $(cat "${D}/stay/claude.log" 2>/dev/null)"
cmp -s "${SD}/CLAUDE.md" "${D}/charters/t22ex/charter.md" || fail "${SD}/CLAUDE.md is not the charter byte for byte"
TREE=$("${SPOKE}" entry t22ex source | sed 's/^vendored: //')
[ "$(readlink "${SD}/repo")" == "${TREE}" ] && [ -f "${SD}/repo/cycle.sh" ] || fail "${SD}/repo is not the link to the vendored tree ${TREE}: $(ls -ld "${SD}/repo" 2>&1)"
python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["projects"][sys.argv[2]]["hasTrustDialogAccepted"] is True' "${CLAUDE_CONFIG_DIR}/.claude.json" "${SD}" \
	|| fail "the spoke's folder is not trusted in claude's configuration, so claude would open at the trust question: $(head -c 300 "${CLAUDE_CONFIG_DIR}/.claude.json" 2>&1)"
python3 - "${SUPERVISOR_DIR}/t22ex/state.json" "$(sha256sum < "${D}/charters/t22ex/charter.md" | cut -d' ' -f1)" << 'EOF' || fail "state.json does not record the start: $(cat "${SUPERVISOR_DIR}/t22ex/state.json" 2>&1)"
import json, re, sys
s = json.load(open(sys.argv[1]))
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", s.get("started_at") or ""), s
assert s.get("charter_sha256") == sys.argv[2] and s.get("source") == "vendored: /agent/charters/example" and s.get("state") == "starting", s
assert s.get("generation") == 1, s
EOF
CREATED=$(tmux display-message -p -t "=t22ex:" '#{session_created} #{pane_pid}')
OUT=$(CLAUDE_BIN=${D}/stay/claude "${AGENT_DIR}/tmux-session-start.sh" t22ex 2>&1) || fail "a second start of t22ex failed: ${OUT}"
echo "${OUT}" | grep -q "already exists (left untouched)" || fail "a second start did not leave the session alone: ${OUT}"
[ "$(tmux display-message -p -t "=t22ex:" '#{session_created} #{pane_pid}')" == "${CREATED}" ] || fail "a second start replaced the running session"
# the dashboard: the vendored build, as ui-start.sh serves it, on a test port and with its own state
VENDORED_JS=${TMUX_AGENT_VENDORED_DIR:-/opt/tmux-agent}/dist/bin/tmux-agent.js
if [ -f "${VENDORED_JS}" ] && command -v node > /dev/null; then
	( unset TMUX_AGENT_SRC; UI_DIR=${D}/ui UI_LISTEN_HOST=127.0.0.1 UI_HOME=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false \
		UI_TMUX=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false UI_CHAT=false UI_BOARD=false UI_FILES=false UI_TMUX_AGENT=true UI_PORT_TMUX_AGENT=${DASH_PORT} \
		LOOP_DECK_DATA_DIR=${D}/loop-deck TMUX_AGENT_HOME=${D}/tmux-agent-home "${AGENT_DIR}/ui-start.sh" > "${D}/ui-start.log" 2>&1 ) || fail "ui-start.sh (the dashboard): $(cat "${D}/ui-start.log")"
	ROW=""
	for I in $(seq 1 40); do
		ROW=$(curl -s --max-time 5 http://127.0.0.1:${DASH_PORT}/api/fleet | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d.get("sessions") or d.get("rows") or (d if isinstance(d, list) else [])
for r in rows:
    if r.get("session") == "t22ex":
        print(r.get("parent"), r.get("owner"), r.get("task"), sep="\t")
' 2>/dev/null)
		[ -n "${ROW}" ] && break
		sleep 1
	done
	[ "${ROW}" == "${AGENT_TMUX_SESSION_NAME}"$'\t'"do-agent-aws"$'\t'"${TITLE}" ] || fail "the tmux-agent dashboard does not list t22ex with its lineage: '${ROW}' ($(curl -s --max-time 5 http://127.0.0.1:${DASH_PORT}/api/fleet | head -c 300))"
	DASH="the tmux-agent dashboard lists it with that lineage"
else
	fail "the vendored tmux-agent dashboard is not in this image (${VENDORED_JS}) or node is missing - the lineage cannot be checked where it is shown"
fi
# PLANTED CONTROL: an entry whose charter lacks its writes rule is refused, and no session starts
charter t22nowrites '/What it writes is stated here/d'
entry t22nowrites
OUT=$(CLAUDE_BIN=${D}/stay/claude "${AGENT_DIR}/tmux-session-start.sh" t22nowrites 2>&1) && fail "PLANTED CONTROL: a charter without its writes rule started: ${OUT}"
echo "${OUT}" | grep -qF "the rule 'the charter states what it writes' is missing" || fail "the refusal does not name the missing rule: ${OUT}"
tmux has-session -t "=t22nowrites" 2>/dev/null && fail "the refused charter's session exists"
# PLANTED CONTROL: a claude that exits at once ends its spoke's session; the hub's shell fallback would keep a shell
charter t22exits
entry t22exits
stub "${D}/exits" exit
# (the start may or may not see the end: claude can exit before or after the lineage is set - the watchdog sees it either
# way). Five starts, and after each the spoke started above is still there: on this image's tmux a query of a session whose
# pane is exiting crashed the whole server, every session with it - the hub's included
for N in 1 2 3 4 5; do
	CLAUDE_BIN=${D}/exits/claude "${AGENT_DIR}/tmux-session-start.sh" t22exits > "${D}/exits.out" 2>&1
	for I in 1 2 3 4 5 6; do tmux has-session -t "=t22exits" 2>/dev/null || break; sleep 0.5; done
	tmux has-session -t "=t22exits" 2>/dev/null && fail "the spoke's session outlived its claude by 3 s (a shell fallback?): $(cat "${D}/exits.out")"
	tmux has-session -t "=t22ex" 2>/dev/null || fail "start ${N} of a spoke whose claude exits at once took the other spoke's session down (the tmux server died): $(cat "${D}/exits.out")"
done
[ "$(grep -c "cwd=${D}/wd/t22exits " "${D}/exits/claude.log")" == "5" ] || fail "the exiting claude did not run 5 times in the spoke's directory: $(cat "${D}/exits.out")"
tmux new-session -d -s t22fallback -e AGENT_TMUX_CLAUDE=true -e "CLAUDE_BIN=${D}/exits/claude" "${AGENT_DIR}/tmux-claude.sh" || fail "could not start the fallback control's session"
sleep 2
tmux has-session -t "=t22fallback" 2>/dev/null || fail "PLANTED CONTROL: with the shell fallback on (the hub's default) the pane did not survive its claude"
tmux kill-session -t "=t22fallback"
echo "ok 3 - the spoke's session is on the default tmux server with its lineage options, ${DASH}; claude runs in ${SD} with the charter as CLAUDE.md and the entry's env, repo/ links the vendored tree, the folder is trusted, state.json records the start (generation 1), a second start leaves it alone; a charter without its writes rule is refused, a claude that exits ends the spoke's session 5 times without taking the server down (with the hub's fallback a shell stays)"

# --- 3b. a URL source: an anonymous clone at the ref, a refresh, and a source that wants credentials refused ---
command -v openssl > /dev/null || fail "openssl is not installed - the test-local https remote cannot be made"
W=${D}/https
mkdir -p "${W}/www" "${W}/work"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${W}/key.pem" -out "${W}/cert.pem" -days 1 -subj /CN=127.0.0.1 \
	-addext subjectAltName=IP:127.0.0.1 > "${W}/openssl.log" 2>&1 || fail "openssl: $(cat "${W}/openssl.log")"
cat > "${W}/server.py" << 'EOF'
import http.server, ssl, sys
root, port, cert, key = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def do_GET(self):
        if self.path.startswith("/private/"):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="private"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        super().do_GET()
    def log_message(self, *a):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
EOF
python3 "${W}/server.py" "${W}/www" ${GIT_PORT} "${W}/cert.pem" "${W}/key.pem" > "${W}/server.log" 2>&1 &
HTTPS_PID=$!
G() { git -c user.name=test22 -c user.email=test22@example.invalid -c init.defaultBranch=main "$@"; }
G init -q --bare "${W}/www/spoke.git" && G init -q "${W}/work" || fail "git init"
echo one > "${W}/work/README.md"
G -C "${W}/work" add README.md && G -C "${W}/work" commit -q -m one && G -C "${W}/work" push -q "${W}/www/spoke.git" main 2> "${W}/push.err" \
	|| fail "could not seed the test-local remote: $(cat "${W}/push.err")"
G -C "${W}/www/spoke.git" update-server-info
ONE=$(git -C "${W}/work" rev-parse HEAD)
export GIT_SSL_CAINFO=${W}/cert.pem
for I in $(seq 1 20); do curl -s --cacert "${W}/cert.pem" -o /dev/null https://127.0.0.1:${GIT_PORT}/spoke.git/HEAD && break; sleep 0.5; done
charter t22url
entry t22url "{\"source\": \"https://127.0.0.1:${GIT_PORT}/spoke.git\", \"ref\": \"main\"}"
OUT=$(CLAUDE_BIN=${D}/stay/claude "${AGENT_DIR}/tmux-session-start.sh" t22url 2>&1) || fail "a spoke with a URL source did not start: ${OUT}"
U=${D}/wd/t22url
[ "$(git -C "${U}/repo" rev-parse HEAD 2>/dev/null)" == "${ONE}" ] || fail "the URL source is not cloned at its ref (${ONE}): $(git -C "${U}/repo" log --oneline -1 2>&1)"
[ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("commit"))' "${SUPERVISOR_DIR}/t22url/state.json")" == "${ONE}" ] || fail "state.json does not record the commit checked out"
echo two > "${W}/work/README.md"
G -C "${W}/work" commit -q -am two && G -C "${W}/work" push -q "${W}/www/spoke.git" main && G -C "${W}/www/spoke.git" update-server-info || fail "could not add an upstream commit"
TWO=$(git -C "${W}/work" rev-parse HEAD)
tmux kill-session -t "=t22url"
OUT=$(CLAUDE_BIN=${D}/stay/claude "${AGENT_DIR}/tmux-session-start.sh" t22url 2>&1) || fail "the restart of the URL spoke failed: ${OUT}"
[ "$(git -C "${U}/repo" rev-parse HEAD)" == "${TWO}" ] || fail "a restart did not refresh the checkout to the new upstream commit ${TWO}: ${OUT}"
# a source that wants credentials: refused, and the credential helper of the git configuration the start inherits is never asked
printf '#!/bin/sh\necho asked >> %s\necho username=someone\necho password=planted\n' "${W}/helper.log" > "${W}/helper"
chmod +x "${W}/helper"
printf '[credential]\n\thelper = %s\n' "${W}/helper" > "${W}/gitconfig"
charter t22priv
entry t22priv "{\"source\": \"https://127.0.0.1:${GIT_PORT}/private/spoke.git\", \"ref\": \"main\"}"
OUT=$(GIT_CONFIG_GLOBAL=${W}/gitconfig CLAUDE_BIN=${D}/stay/claude "${AGENT_DIR}/tmux-session-start.sh" t22priv 2>&1) \
	&& fail "a source that answers 401 started a spoke: ${OUT}"
echo "${OUT}" | grep -q "anonymous clone of https://127.0.0.1:${GIT_PORT}/private/spoke.git at main failed" || fail "the refusal does not say the anonymous clone failed: ${OUT}"
[ -e "${W}/helper.log" ] && fail "the start asked the inherited credential helper for the private source"
tmux has-session -t "=t22priv" 2>/dev/null && fail "the refused URL spoke's session exists"
GIT_CONFIG_GLOBAL=${W}/gitconfig GIT_TERMINAL_PROMPT=0 git clone -q https://127.0.0.1:${GIT_PORT}/private/spoke.git "${W}/control-clone" > /dev/null 2>&1
[ -s "${W}/helper.log" ] || fail "PLANTED CONTROL: git with the planted configuration did not ask the helper either, so the check above proves nothing"
unset GIT_SSL_CAINFO
echo "ok 3b - a URL source is cloned anonymously at its ref (commit in state.json) and a restart refreshes it to the new upstream commit; a source that answers 401 is refused without asking the inherited credential helper, which git with that configuration does ask"

# --- 4. messages: the bus v1 journal and its projections; what is refused, what is held back; the validator ---
BUS="${AGENT_DIR}/bus.sh"
CHECK="${AGENT_DIR}/bus-v1-check.py"
J=${MAILBOX_STATE_ROOT}/journal/000001.jsonl
IB=${MAILBOX_PROJECTION_ROOT}
ID=$(echo "when did your last cycle run?" | BUS_AGENT_ID=t22-hub "${BUS}" request t22ex) || fail "bus.sh request (hub to spoke): ${ID}"
python3 - "${J}" "${IB}/t22ex/inbox.jsonl" "${ID}" << 'EOF' || fail "the request's journal line or inbox record is not bus v1: $(cat "${J}" 2>&1)"
import hashlib, json, re, sys
ev = [json.loads(l) for l in open(sys.argv[1])]
assert len(ev) == 1 and ev[0]["event"] == "message.accepted" and ev[0]["id"] == sys.argv[3] and ev[0]["seq"] == 1 and ev[0]["actor"] == "t22-hub", ev
env, meta = ev[0]["details"]["env"], ev[0]["details"]["meta"]
assert sorted(env) == ["from", "id", "kind", "reply_to", "text", "to", "ts", "v"], env
assert re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", env["id"]) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z", env["ts"]), env
assert (env["v"], env["from"], env["to"], env["kind"], env["text"], env["reply_to"]) == (1, "t22-hub", "t22ex", "request", "when did your last cycle run?", None), env
assert meta["seq"] == 1 and meta["causation_id"] is None and meta["origin"] == "agent" and meta["assurance"] == "cooperative", meta
assert meta["from_generation"] >= 1 and meta["to_generation"] == 1, meta   # t22ex was started once (check 3)
recs = [json.loads(l) for l in open(sys.argv[2])]
assert len(recs) == 1 and recs[0]["env"] == env and recs[0]["meta"] == meta, recs
canon = json.dumps({"env": env, "meta": meta}, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
assert recs[0]["hash"] == hashlib.sha256(canon).hexdigest(), recs
EOF
[ "$(stat -c %a "${MAILBOX_STATE_ROOT}")" == "700" ] && [ "$(stat -c %a "${J}")" == "600" ] || fail "the journal is not private: $(stat -c '%a %n' "${MAILBOX_STATE_ROOT}" "${J}")"
[ "$(BUS_AGENT_ID=t22ex "${BUS}" poll)" == "${ID}" ] || fail "the spoke's poll does not list the request: $(BUS_AGENT_ID=t22ex "${BUS}" poll 2>&1)"
BUS_AGENT_ID=t22ex "${BUS}" peek "${ID}" | grep -qF '"text": "when did your last cycle run?"' || fail "peek does not show the request's text"
RID=$(echo "at 00:00Z" | BUS_AGENT_ID=t22ex "${BUS}" reply "${ID}") || fail "bus.sh reply (the spoke): ${RID}"
python3 - "${J}" "${ID}" "${RID}" << 'EOF' || fail "the reply is not addressed back with reply_to, or the request is not marked replied: $(tail -2 "${J}")"
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1])]
req, rep, done = ev[0]["details"], ev[1], ev[2]
assert [e["seq"] for e in ev] == [1, 2, 3], ev
e = rep["details"]["env"]
assert (rep["event"], e["id"], e["from"], e["to"], e["kind"], e["reply_to"]) == ("message.accepted", sys.argv[3], "t22ex", "t22-hub", "reply", sys.argv[2]), rep
assert rep["details"]["meta"]["conversation_id"] == req["meta"]["conversation_id"] and rep["details"]["meta"]["causation_id"] == sys.argv[2], rep
assert (done["event"], done["id"], done["details"]) == ("message.replied", sys.argv[2], {"reply": sys.argv[3]}), done
EOF
[ -z "$(BUS_AGENT_ID=t22ex "${BUS}" poll)" ] || fail "the request is still open after its reply"
[ "$(BUS_AGENT_ID=t22-hub "${BUS}" poll)" == "${RID}" ] || fail "the hub's poll does not list the reply"
OPT=$(tmux show-options -t "=t22ex:" -v @agent_last_message 2>/dev/null)
echo "${OPT}" | grep -qE '^[0-9T:.-]+Z t22ex -> t22-hub reply: at 00:00Z$' || fail "the spoke's session does not carry the last message: '${OPT}'"
# inside a tmux pane the pane's session is the sender, whatever BUS_AGENT_ID says: a window of the spoke's own session
# sends as the spoke; a pane of a session the registry does not list sends nothing
tmux new-window -d -t "=t22ex:" -e "SPOKES_REGISTRY=${SPOKES_REGISTRY}" -e "MAILBOX_STATE_ROOT=${MAILBOX_STATE_ROOT}" -e "MAILBOX_PROJECTION_ROOT=${MAILBOX_PROJECTION_ROOT}" \
	-e "SUPERVISOR_DIR=${SUPERVISOR_DIR}" -e "AGENT_TMUX_SESSION_NAME=${AGENT_TMUX_SESSION_NAME}" \
	"bash -c 'echo from-a-pane | BUS_AGENT_ID=t22-hub \"${BUS}\" note t22-hub > \"${D}/pane.out\" 2>&1'" || fail "could not open a window in the spoke's session"
tmux new-session -d -s t22pane -e "SPOKES_REGISTRY=${SPOKES_REGISTRY}" -e "MAILBOX_STATE_ROOT=${MAILBOX_STATE_ROOT}" -e "MAILBOX_PROJECTION_ROOT=${MAILBOX_PROJECTION_ROOT}" \
	-e "AGENT_TMUX_SESSION_NAME=${AGENT_TMUX_SESSION_NAME}" \
	"bash -c 'echo from-elsewhere | BUS_AGENT_ID=t22-hub \"${BUS}\" note t22ex > \"${D}/pane2.out\" 2>&1; sleep 30'" || fail "could not start the pane session"
for I in $(seq 1 20); do [ -s "${D}/pane.out" ] && [ -s "${D}/pane2.out" ] && break; sleep 0.5; done
tmux kill-session -t "=t22pane" 2>/dev/null
tail -1 "${J}" | grep -q '"from": "t22ex", "to": "t22-hub", "ts": "[^"]*", "kind": "notice", "text": "from-a-pane"' || fail "a message sent from the spoke's pane is not attributed to the spoke: $(cat "${D}/pane.out") / $(tail -1 "${J}")"
grep -qF "'t22pane' is not a session of the registry" "${D}/pane2.out" || fail "a pane of a session the registry does not list was not refused: $(cat "${D}/pane2.out")"
grep -q "from-elsewhere" "${J}" && fail "the refused pane's message is in the journal"
# cleaned, redacted, and never run
printf 'red: \033[31mred\033[0m title: \033]0;owned\007 bidi: \xe2\x80\xaeevil\n$(touch %s/ran-1) `touch %s/ran-2`; touch %s/ran-3\n' "${D}" "${D}" "${D}" \
	| BUS_AGENT_ID=t22-hub "${BUS}" note t22ex > "${D}/hostile.id" || fail "bus.sh refused a text with controls instead of cleaning it"
BUS_AGENT_ID=t22ex "${BUS}" peek "$(cat "${D}/hostile.id")" > "${D}/hostile.out" || fail "bus.sh peek (hostile)"
grep -q $'\033\|\xe2\x80\xae\|\a' "${D}/hostile.out" "${J}" "${IB}/t22ex/inbox.jsonl" && fail "the text still carries a terminal control or a direction override: $(cat -A "${D}/hostile.out")"
grep -qF 'red: red title:  bidi: evil' "${D}/hostile.out" || fail "the cleaned text is not what was sent minus the controls: $(cat "${D}/hostile.out")"
grep -qF '$(touch' "${D}/hostile.out" || fail "the command text did not arrive as data: $(cat "${D}/hostile.out")"
ls "${D}"/ran-* > /dev/null 2>&1 && fail "a message's text was run"
TOKEN=$(printf 'xox%s-%s' b 1234567890-abcdefghijklm)
printf 'the token is %s\n' "${TOKEN}" | BUS_AGENT_ID=t22-hub "${BUS}" note t22ex > /dev/null 2> "${D}/redact.err" || fail "bus.sh refused a text with a credential shape instead of redacting it"
grep -qF "redacted 1 x a Slack token" "${D}/redact.err" || fail "bus.sh did not say what it redacted: $(cat "${D}/redact.err")"
grep -qF "${TOKEN}" "${J}" "${IB}/t22ex/inbox.jsonl" "${IB}/log.jsonl" && fail "a credential shape reached the journal or a projection"
grep -qF 'the token is [redacted: a Slack token]' "${IB}/t22ex/inbox.jsonl" || fail "the redacted text is not in the inbox"
# refused
refused()
{
	# refused <why> <expected stderr> <command...> - stdin from the caller; exit non-zero with that line
	WHY=$1; WANT=$2; shift 2
	OUT=$("$@" 2>&1) && fail "bus.sh accepted ${WHY}: ${OUT}"
	echo "${OUT}" | grep -qF -- "${WANT}" || fail "bus.sh refused ${WHY} for another reason: ${OUT}"
}
charter t22two
entry t22two
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["sessions"].insert(1, {"session_name": "supervisor", "role": "supervisor", "flag": "SUPERVISOR", "enabled": True, "workdir": sys.argv[2], "launch_cmd": "true", "env": {}}); json.dump(d, open(sys.argv[1], "w"), indent=1)' \
	"${REG}" "${D}/wd/supervisor"
N0=$(wc -l < "${J}")
echo x | refused "an unknown recipient" "unknown recipient 'nobody'" env BUS_AGENT_ID=t22-hub "${BUS}" note nobody
echo x | refused "a spoke writing to another spoke" "may not send a notice to t22two (spoke)" env BUS_AGENT_ID=t22ex "${BUS}" note t22two
echo x | refused "a request from the supervisor (it sends notices)" "may not send a request to t22-hub (hub)" env BUS_AGENT_ID=supervisor "${BUS}" request t22-hub
echo x | refused "a reply by an agent the request was not sent to" "was sent to t22ex, not to you (t22-hub)" env BUS_AGENT_ID=t22-hub "${BUS}" send t22ex reply --reply-to "${ID}"
echo x | refused "a second reply to a request already answered" "was answered already, by ${RID}" env BUS_AGENT_ID=t22ex "${BUS}" reply "${ID}"
echo x | refused "an error to a request already answered" "was answered already, by ${RID}" env BUS_AGENT_ID=t22ex "${BUS}" error "${ID}"
echo x | refused "a kind that is not one of the four" "kind 'alert' is not one of" env BUS_AGENT_ID=t22-hub "${BUS}" send t22ex alert
printf '\n\n' | refused "an empty text" "the text (stdin) is empty" env BUS_AGENT_ID=t22-hub "${BUS}" note t22ex
python3 -c 'print("x" * 3000)' | refused "a text too long for its journal line" "at most 2048 bytes" env BUS_AGENT_ID=t22-hub "${BUS}" note t22ex
echo x | refused "a sender outside tmux without BUS_AGENT_ID" "who is sending?" env -u BUS_AGENT_ID -u TMUX -u TMUX_PANE "${BUS}" note t22ex
echo x | refused "a sender the registry does not list" "'nobody' is not a session of the registry" env BUS_AGENT_ID=nobody "${BUS}" note t22ex
[ "$(wc -l < "${J}")" == "${N0}" ] || fail "a refused message reached the journal"
NOTE=$(echo "t22ex is stuck: a menu is open" | BUS_AGENT_ID=supervisor "${BUS}" note t22-hub) || fail "the supervisor's notice to the hub was refused: ${NOTE}"
BUS_AGENT_ID=t22-hub "${BUS}" receipt "${NOTE}" read > /dev/null || fail "the hub's receipt for the supervisor's notice was refused"
BUS_AGENT_ID=t22-hub "${BUS}" poll | grep -qxF "${NOTE}" && fail "a notice with a read receipt is still open"
tail -1 "${J}" | grep -qF "\"event\": \"message.read\", \"id\": \"${NOTE}\"" || fail "the receipt is not a message.read event in the journal"
# the validator: the projection root and the journal are bus v1; a planted invalid record is refused; its self-test
OUT=$(python3 "${CHECK}" "${IB}" --journal "${J}" 2>&1) || fail "bus-v1-check.py refuses the projection root and the journal bus.sh wrote: ${OUT}"
echo "${OUT}" | grep -qF "'inboxes': 2, 'records': 6, 'journal_events': 8}" || fail "the validator did not count what bus.sh wrote (2 inboxes, 6 records, 8 events): ${OUT}"
cp -r "${IB}" "${D}/bus-planted"
python3 - "${D}/bus-planted/t22ex/inbox.jsonl" << 'EOF'
import hashlib, json, sys
p = sys.argv[1]
rec = json.loads(open(p).readline())
rec["env"]["kind"] = "alert"
rec["hash"] = hashlib.sha256(json.dumps({"env": rec["env"], "meta": rec["meta"]}, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
open(p, "a").write(json.dumps(rec) + "\n")
EOF
OUT=$(python3 "${CHECK}" "${D}/bus-planted" 2>&1); RC=$?
[ "${RC}" == "2" ] && echo "${OUT}" | grep -qF "kind 'alert' is not one of" || fail "PLANTED CONTROL: the validator did not refuse a record whose kind is not v1 (rc ${RC}): ${OUT}"
OUT=$(python3 "${CHECK}" --self-test 2>&1) || fail "the validator's self-test failed: $(echo "${OUT}" | tail -3)"
echo "${OUT}" | grep -q "^SELF-TEST PASSED" || fail "the validator's self-test did not pass: $(echo "${OUT}" | tail -2)"
# PLANTED CONTROLS: what the journal does not hold is never shown
python3 - "${IB}/t22ex/inbox.jsonl" << 'EOF'
import hashlib, json, sys
p = sys.argv[1]
lines = open(p).read().splitlines()
canon = lambda r: hashlib.sha256(json.dumps({"env": r["env"], "meta": r["meta"]}, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
forged = json.loads(lines[0]); forged["env"]["id"] = "00000000-0000-4000-8000-000000000001"; forged["env"]["text"] = "forged"; forged["hash"] = canon(forged)
altered = json.loads(lines[0]); altered["env"]["text"] = "altered after journaling"; altered["hash"] = canon(altered)
open(p, "a").write(json.dumps(forged) + "\n" + json.dumps(altered) + "\n")
EOF
GOOD=$(echo "genuine" | BUS_AGENT_ID=t22-hub "${BUS}" request t22ex)
OUT=$(BUS_AGENT_ID=t22ex "${BUS}" poll --kind request 2> "${D}/held.err")
[ "${OUT}" == "${GOOD}" ] || fail "the poll did not list exactly the journaled open request: ${OUT}"
grep -qF "held back message 00000000-0000-4000-8000-000000000001: not in the journal" "${D}/held.err" || fail "PLANTED CONTROL: an unjournaled inbox record was not held back and named: $(cat "${D}/held.err")"
grep -qF "held back message ${ID}: differs from its journal record" "${D}/held.err" || fail "PLANTED CONTROL: an altered inbox record was not held back: $(cat "${D}/held.err")"
BUS_AGENT_ID=t22ex "${BUS}" peek 00000000-0000-4000-8000-000000000001 > /dev/null 2>&1 && fail "PLANTED CONTROL: peek showed a message the journal does not hold"
echo "ok 4 [bus-request-reply-journaled] - bus.sh: the request is one message.accepted journal line (v1 envelope and routing, seq 1) and one inbox record with its canonical hash, the journal private; poll, peek, a reply with reply_to in the same conversation and message.replied, the request closed, the hub's poll, @agent_last_message; a pane sends as its own session and a session the registry does not list sends nothing; controls cleaned, a credential redacted, commands never run; 11 refusals; the supervisor's notice and a read receipt; bus-v1-check.py passes the projection root and the journal and refuses a planted record, its self-test passes; an unjournaled and an altered inbox record are held back"

# --- 5. the supervisor: start, cycle, restart, an answered question, the pass record; the stuck and off controls ---
SUP="${AGENT_DIR}/supervisor.sh"
for S in t22w t22dies t22off; do
	charter "${S}"
	entry "${S}" '{"cadence_sec": 3, "cooldown_sec": 2}'
done
# a flag on and no charter
entry t22none '{"cadence_sec": 3, "cooldown_sec": 2}'
# the supervisor's own entry: its session shows its log, under the hub
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for e in d["sessions"]:
    if e["role"] == "supervisor":
        e.update(parent=sys.argv[2], task="starts the enabled spokes from the registry", launch_cmd=sys.argv[3] + "/supervisor.sh view",
                 title="Supervisor", writes=[sys.argv[4] + "/passes.jsonl", sys.argv[4] + "/status.json"], cooldown_sec=2)
json.dump(d, open(sys.argv[1], "w"), indent=1)' "${REG}" "${AGENT_TMUX_SESSION_NAME}" "${AGENT_DIR}" "${SUPERVISOR_DIR}"
SESSIONS="${SESSIONS} supervisor"
# a spoke's start and the supervisor session's start, each the first client of a fresh tmux server, which keeps that
# call's command line for its whole life (ps, pgrep -f): the pane's settings are not on it, the pane has them, and the
# server's global environment does not, so a later pane on that server inherits none of them
charter t22first
entry t22first '{"env": {"T22_ENV": "first-client"}}'
stub "${D}/first" stay
for FIRST in t22first supervisor; do
	FT=${D}/tmux-first-${FIRST}
	mkdir -p "${FT}"
	FIRST_TMPDIRS="${FIRST_TMPDIRS} ${FT}"
	ft() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="${FT}" tmux "$@"; }
	ft list-sessions > /dev/null 2>&1 && fail "a tmux server already runs under ${FT}"
	OUT=$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="${FT}" SUPERVISOR_DIR="${D}/sup-first" CLAUDE_BIN="${D}/first/claude" \
		"${AGENT_DIR}/tmux-session-start.sh" "${FIRST}" 2>&1) || fail "tmux-session-start.sh ${FIRST} as a tmux server's first client: ${OUT}"
	SRV=$(ft list-sessions -F '#{pid}' 2>/dev/null | head -1)
	[ -n "${SRV}" ] || fail "no tmux server under ${FT} after ${FIRST}'s start: ${OUT}"
	ARGV=$(tr '\0' ' ' < "/proc/${SRV}/cmdline")
	echo " ${ARGV}" | grep -qE ' -e |BUS_AGENT_ID=|SUPERVISOR_DIR=|CLAUDE_BIN=' \
		&& fail "the tmux server that ${FIRST}'s start started keeps the pane's settings on its command line: ${ARGV:0:300}"
	PP=$(ft list-panes -t "=${FIRST}:" -F '#{pane_pid}' 2>/dev/null | head -1)
	PENV=$(tr '\0' '\n' < "/proc/${PP}/environ" 2>/dev/null)
	echo "${PENV}" | grep -qx "BUS_AGENT_ID=${FIRST}" && echo "${PENV}" | grep -qx "SUPERVISOR_DIR=${D}/sup-first" \
		|| fail "${FIRST}'s pane, started by a tmux server's first client, lacks its settings: $(echo "${PENV}" | grep -E '^(BUS_AGENT_ID|SUPERVISOR_DIR)=')"
	ft show-environment -g BUS_AGENT_ID > /dev/null 2>&1 \
		&& fail "the tmux server that ${FIRST}'s start started holds BUS_AGENT_ID in its global environment: a later pane would send as ${FIRST}"
	ft new-session -d -s t22later "sleep 600" || fail "could not start a later session under ${FT}"
	PL=$(ft list-panes -t "=t22later:" -F '#{pane_pid}' 2>/dev/null | head -1)
	LEAK=$(tr '\0' '\n' < "/proc/${PL}/environ" 2>/dev/null | grep -E '^(BUS_AGENT_ID|T22_ENV|AGENT_TMUX_SHELL_FALLBACK)=')
	[ -z "${LEAK}" ] || fail "a later pane on the tmux server that ${FIRST}'s start started inherits its settings: ${LEAK}"
	if [ "${FIRST}" == t22first ]; then
		for I in $(seq 1 20); do [ -s "${D}/first/claude.log" ] && break; sleep 0.5; done
		grep -q " t22_env=first-client$" "${D}/first/claude.log" \
			|| fail "t22first's claude, started by a tmux server's first client, did not get its entry's env: $(cat "${D}/first/claude.log" 2>&1)"
	fi
	ft kill-session -t "=t22later"
	ft kill-session -t "=${FIRST}"
done
# the hub stays out of this run (check 8 has it); the memory UIs too (check 8 has their health)
export SUPERVISOR=true SUPERVISOR_INTERVAL=1 SUPERVISOR_RESTART_CAP=3 SUPERVISOR_START_GRACE=10 AGENT_TMUX_SESSION=false UI_HINDSIGHT=false UI_CLAUDE_MEM=false
# one stub per spoke: the claude that stays for t22w, the one that exits at once for t22dies
mkdir -p "${D}/bydir"
printf '#!/bin/bash\n[ "$(basename "$(pwd)")" == t22dies ] && { echo "$(date +%%s) start" >> %s/dies.log; exit 3; }\nexec %s/stay/claude\n' "${D}" "${D}" > "${D}/bydir/claude"
chmod +x "${D}/bydir/claude"
# an interval that is not a whole number of seconds of at least 1 would spin the loop: refused before anything runs
for BAD in 0 abc; do
	OUT=$(SUPERVISOR_INTERVAL=${BAD} "${SUP}" start 2>&1) && fail "supervisor.sh start ran with SUPERVISOR_INTERVAL=${BAD}: ${OUT}"
	echo "${OUT}" | grep -q "SUPERVISOR_INTERVAL" || fail "the refused start does not name SUPERVISOR_INTERVAL: ${OUT}"
	flock -n "${SUPERVISOR_DIR}/supervisor.lock" true 2>/dev/null || fail "a loop runs after the refused start with SUPERVISOR_INTERVAL=${BAD}"
done
# started from a tmux pane, as the DOWN row invites a person to: the loop drops that pane, or bus.sh would send every
# notice as the pane's session (one the registry does not list sends nothing); the pane stays until the hub has the
# stuck notice below
tmux new-session -d -s t22from "sleep 600" || fail "could not start the pane the supervisor is started from"
SESSIONS="${SESSIONS} t22from"
FROM_ENV=(TMUX="$(tmux display -p -t "=t22from:" '#{socket_path},#{pid},0')" TMUX_PANE="$(tmux display -p -t "=t22from:" '#{pane_id}')")
T0=$(date -u +%FT%TZ)
OUT=$(env "${FROM_ENV[@]}" CLAUDE_BIN=${D}/bydir/claude SPOKE_T22W=true SPOKE_T22DIES=true SPOKE_T22NONE=true SPOKE_T22OFF=false "${SUP}" start 2>&1) || fail "supervisor.sh start: ${OUT}"
tr '\0' '\n' < "/proc/$(cat "${SUPERVISOR_DIR}/supervisor.pid")/environ" | grep -qE '^TMUX(_PANE)?=' \
	&& fail "the supervisor's loop kept the TMUX_PANE of the pane it was started from: its notices would go out as that pane's session"
echo "${OUT}" | grep -qx "spoke t22off: OFF (set SPOKE_T22OFF=true in .env.local to run it)" || fail "the start's rows do not say t22off is off and how to turn it on: ${OUT}"
export SPOKE_T22W=true SPOKE_T22DIES=true SPOKE_T22NONE=true SPOKE_T22OFF=false
for I in $(seq 1 7); do tmux has-session -t "=t22w" 2>/dev/null && break; sleep 1; done
tmux has-session -t "=t22w" 2>/dev/null || fail "the supervisor did not start the enabled spoke t22w within the interval + 5 s: $(cat "${SUPERVISOR_DIR}/t22w/restarts.log" 2>&1)"
W=${SUPERVISOR_DIR}/t22w
for I in $(seq 1 15); do [ -s "${W}/last-cycle" ] && break; sleep 1; done
STARTED=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["started_at"])' "${W}/state.json")
LAST=$(cat "${W}/last-cycle" 2>/dev/null)
[ -n "${LAST}" ] && [[ ! "${LAST}" < "${STARTED}" ]] && [[ ! "${LAST}" < "${T0}" ]] || fail "no cycle completed after the start (${STARTED}): last-cycle '${LAST}'; $(tail -5 "${W}/cycle.out" 2>&1)"
grep -q "^example spoke: cycle at " "${D}/wd/t22w/status.txt" || fail "the cycle did not write its status.txt in the workdir"
for I in $(seq 1 8); do ROW=$(CLAUDE_BIN=${D}/bydir/claude "${SUP}" status 2>&1 | grep '^spoke t22w:'); echo "${ROW}" | grep -q LIVE && break; sleep 1; done
echo "${ROW}" | grep -q "^spoke t22w: LIVE session=t22w last_cycle=" || fail "the status row of the live spoke: ${ROW}"
tile() { python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["sessions"][sys.argv[2]]; print(s[sys.argv[3]] if not isinstance(s[sys.argv[3]], dict) else json.dumps(s[sys.argv[3]], sort_keys=True))' "${SUPERVISOR_DIR}/status.json" "$1" "$2" 2>/dev/null; }
for I in $(seq 1 5); do [ "$(tile t22w state)" == "live" ] && break; sleep 1; done
[ "$(tile t22w state)" == "live" ] || fail "status.json does not say t22w is live: $(head -c 900 "${SUPERVISOR_DIR}/status.json" 2>&1)"
# a kill: back within the interval + 5 s, one restart logged
tmux kill-session -t "=t22w"
K=$(date +%s)
for I in $(seq 1 7); do tmux has-session -t "=t22w" 2>/dev/null && break; sleep 1; done
tmux has-session -t "=t22w" 2>/dev/null || fail "the killed spoke t22w is not back $(( $(date +%s) - K )) s later: $(cat "${W}/restarts.log")"
# the session is back before its start returns, and the restart line is written after that
for I in $(seq 1 10); do grep -q ' restart 1/3 (the session was gone)' "${W}/restarts.log" && break; sleep 0.5; done
[ "$(grep -c ' restart 1/3 (the session was gone)' "${W}/restarts.log")" == "1" ] && [ "$(grep -c ' restart ' "${W}/restarts.log")" == "1" ] \
	|| fail "restarts.log does not carry exactly one restart line: $(cat "${W}/restarts.log")"
BACK=$(( $(date +%s) - K ))
for I in $(seq 1 5); do grep -q '"text": "t22w was gone and was started again (restart 1/3)"' "${J}" && break; sleep 1; done
grep -q '"text": "t22w was gone and was started again (restart 1/3)"' "${J}" || fail "the supervisor did not tell the hub that it started t22w again"
# a hub question, answered by the spoke's own cycle
Q=$(echo "how are you?" | BUS_AGENT_ID=t22-hub "${BUS}" request t22w) || fail "bus.sh request t22w: ${Q}"
A=""
for I in $(seq 1 15); do
	A=$(python3 -c 'import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    r = (e.get("details") or {}).get("env") or {}
    if e.get("event") == "message.accepted" and r.get("reply_to") == sys.argv[2] and r.get("from") == "t22w" and r.get("to") == "t22-hub":
        print(r["id"])' "${J}" "${Q}")
	[ -n "${A}" ] && break
	sleep 1
done
[ -n "${A}" ] || fail "the spoke's cycle did not answer the hub's question within 15 s: $(tail -5 "${W}/cycle.out")"
BUS_AGENT_ID=t22-hub "${BUS}" poll | grep -qxF "${A}" || fail "the answer is not an open message in the hub's inbox"
for I in $(seq 1 5); do tile t22w last_message | grep -qF "\"id\": \"${A}\"" && break; sleep 1; done
tile t22w last_message | grep -qF "\"id\": \"${A}\"" || fail "status.json does not show the answer as t22w's last message: $(tile t22w last_message)"
# PLANTED CONTROL: claude exits at once - growing backoff, stuck at the cap, never started again, the hub told
for I in $(seq 1 40); do grep -q '"state": "stuck"' "${SUPERVISOR_DIR}/t22dies/state.json" 2>/dev/null && break; sleep 1; done
DL=${SUPERVISOR_DIR}/t22dies/restarts.log
grep -q '"state": "stuck"' "${SUPERVISOR_DIR}/t22dies/state.json" 2>/dev/null || fail "PLANTED CONTROL: the spoke whose claude exits at once was never marked stuck: $(cat "${DL}" 2>&1)"
[ "$(grep -c ' restart [123]/3 (the session was gone)' "${DL}")" == "3" ] && [ "$(grep -c ' stuck: ' "${DL}")" == "1" ] \
	|| fail "PLANTED CONTROL: restarts.log of t22dies is not three restarts and one stuck line: $(cat "${DL}")"
python3 - "${D}/dies.log" << 'EOF' || fail "PLANTED CONTROL: the restarts did not back off (the gaps must grow): $(cat "${D}/dies.log")"
import sys
t = [int(l.split()[0]) for l in open(sys.argv[1])]
assert len(t) == 4, t                      # the first start and three restarts
gaps = [b - a for a, b in zip(t, t[1:])]
assert gaps[1] >= 2 and gaps[2] >= 4, gaps   # the first restart at the next pass, then the cooldown (2 s), then 4 s
EOF
for I in $(seq 1 5); do [ "$(tile t22dies state)" == "stuck" ] && break; sleep 1; done
[ "$(tile t22dies state)" == "stuck" ] || fail "status.json does not say t22dies is stuck"
OUT=$("${SUP}" status 2>&1) && fail "the status exits 0 with a stuck spoke: ${OUT}"
echo "${OUT}" | grep -q "^spoke t22dies: STUCK - it did not stay up 300s through 3 restarts; the last start said: spoke t22dies: " || fail "no STUCK row for t22dies naming its last start: ${OUT}"
grep -qF '"from": "supervisor", "to": "t22-hub", "ts": ' "${J}" && grep -q '"text": "t22dies is stuck: it did not stay up' "${J}" \
	|| fail "the supervisor did not tell the hub that t22dies is stuck (a bus notice): $(grep -c supervisor "${J}") supervisor lines"
tmux kill-session -t "=t22from" 2>/dev/null
# a flag on with no charter: refused at every start, then stuck with that reason
for I in $(seq 1 25); do grep -q '"state": "stuck"' "${SUPERVISOR_DIR}/t22none/state.json" 2>/dev/null && break; sleep 1; done
OUT=$("${SUP}" status 2>&1)
echo "${OUT}" | grep -q "^spoke t22none: STUCK - .*the last start said: ${D}/charters/t22none/charter.md: no such charter" \
	|| fail "a flag on without a charter did not go stuck naming the missing charter: ${OUT}"
N0=$(wc -l < "${D}/dies.log")
sleep 6
[ "$(wc -l < "${D}/dies.log")" == "${N0}" ] || fail "PLANTED CONTROL: the stuck spoke was started again"
# the flag that is off: no session, no state
tmux has-session -t "=t22off" 2>/dev/null && fail "the spoke whose flag is off has a session"
[ -e "${SUPERVISOR_DIR}/t22off" ] || [ -e "${D}/wd/t22off" ] && fail "the supervisor wrote state for the spoke whose flag is off"
# the pass record, and the pass on the dashboard: the supervisor's session, its lineage and its task line
python3 - "${SUPERVISOR_DIR}/passes.jsonl" << 'EOF' || fail "passes.jsonl is not one record per pass with each enabled spoke's state: $(tail -2 "${SUPERVISOR_DIR}/passes.jsonl" 2>&1)"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
assert len(recs) >= 5, len(recs)
assert [r["pass"] for r in recs] == list(range(recs[0]["pass"], recs[0]["pass"] + len(recs))), [r["pass"] for r in recs]
last = recs[-1]
assert set(last["sessions"]) == {"t22w", "t22dies", "t22none"}, last
assert last["sessions"]["t22w"]["state"] == "live" and last["sessions"]["t22dies"]["state"] == "stuck", last
EOF
tmux has-session -t "=supervisor" 2>/dev/null || fail "the supervisor has no tmux session"
[ "$(tmux show-options -t "=supervisor:" -v @agent_parent 2>/dev/null)" == "${AGENT_TMUX_SESSION_NAME}" ] || fail "the supervisor's session is not under the hub"
TASK=$(tmux show-options -t "=supervisor:" -v @agent_task 2>/dev/null)
echo "${TASK}" | grep -qE '^last pass [0-9T:-]+Z: 1 of 3 live - ' || fail "the supervisor's session does not carry its last pass for the dashboard: '${TASK}'"
FLEET=$(curl -s --max-time 5 http://127.0.0.1:${DASH_PORT}/api/fleet | python3 -c 'import json, sys
d = json.load(sys.stdin)
for r in d.get("sessions") or []:
    if r.get("session") == "supervisor":
        print(r.get("parent"), r.get("task"), sep="\t")' 2>/dev/null)
echo "${FLEET}" | grep -qE "^${AGENT_TMUX_SESSION_NAME}"$'\t''last pass ' || fail "the tmux-agent dashboard does not list the supervisor with its last pass: '${FLEET}'"
for I in $(seq 1 10); do tmux capture-pane -p -t "=supervisor:" | grep -qE '^supervisor, pass [0-9]+ at .*: 1 of 3 sessions live$' && break; sleep 1; done
tmux capture-pane -p -t "=supervisor:" | grep -qE '^supervisor, pass [0-9]+ at .*: 1 of 3 sessions live$' || fail "the supervisor's session does not show its last pass: $(tmux capture-pane -p -t "=supervisor:" | head -5)"
# one loop at a time; stop ends it and leaves the sessions
OUT=$(timeout 10 "${SUP}" run 2>&1)
echo "${OUT}" | grep -q "already running" || fail "a second loop did not refuse to run: ${OUT}"
echo "ok 5 [spoke-answers-hub] - the supervisor started t22w, a cycle completed after its start (LIVE row, status.json live), a kill was back in ${BACK} s with one restart line, the spoke's cycle answered the hub (journal, inbox, last message); a claude that exits at once backed off, went stuck at 3/3 naming its last start, stayed stuck and the hub was told; a flag without a charter went stuck naming the missing charter; the off flag ran nothing; one record per pass; its session is on the dashboard under the hub with its last pass; one loop at a time"

# --- 5c. a spoke whose required settings are unset waits for them ---
python3 -c 'import json, sys
c = next(e for e in json.load(open(sys.argv[1]))["sessions"] if e["session_name"] == "conversations")
assert c.get("requires") == ["SLACK_BOT_TOKEN", "SLACK_CHANNELS"] and c.get("requires_what") == "Slack", (c.get("requires"), c.get("requires_what"))' \
	"${SHIPPED_REGISTRY}" || fail "the shipped conversations entry does not require SLACK_BOT_TOKEN and SLACK_CHANNELS as Slack"
# the plant's cycle logs each run and, like the conversations loop, fails without both settings
charter t22slack
mkdir -p "${D}/slack-cycle"
printf '#!/bin/bash\necho "$(date -u +%%FT%%TZ)" >> %s/slack-cycle/runs.log\n[ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNELS:-}" ] || { echo "SLACK_BOT_TOKEN is not set"; exit 3; }\necho "cycle with Slack"\n' "${D}" \
	> "${D}/slack-cycle/cycle.sh"
chmod +x "${D}/slack-cycle/cycle.sh"
entry t22slack "{\"cycle\": \"${D}/slack-cycle/cycle.sh\", \"cadence_sec\": 1, \"cooldown_sec\": 2, \"requires\": [\"SLACK_BOT_TOKEN\", \"SLACK_CHANNELS\"], \"requires_what\": \"Slack\"}"
# its own registry and supervisor session, beside check 5's loop, which still runs: the hub, the plant and a supervisor
# entry named t22slacksup, whose session carries this run's task line
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
keep = [dict(e, session_name="t22slacksup") if e.get("role") == "supervisor" else e for e in d["sessions"]
        if e.get("role") in ("hub", "supervisor") or e.get("session_name") == "t22slack"]
json.dump(dict(d, sessions=keep), open(sys.argv[2], "w"), indent=1)' "${REG}" "${D}/slack-registry.json"
tmux new-session -d -s t22slacksup "sleep 600" || fail "could not start the session of t22slack's supervisor"
SESSIONS="${SESSIONS} t22slack t22slacksup"
SLK=${D}/sup-slack
SLACK_ENV=(SPOKES_REGISTRY="${D}/slack-registry.json" SUPERVISOR_DIR="${SLK}" SPOKE_T22SLACK=true CLAUDE_BIN="${D}/bydir/claude")
slack_state() { python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["sessions"]["t22slack"]; print(s["state"], s["why"], sep=": ")' "${SLK}/status.json" 2>/dev/null; }
slack_pass() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "${SLK}/status.json" 2>/dev/null; }
J0=$(wc -l < "${J}")
OUT=$(env -u SLACK_BOT_TOKEN -u SLACK_CHANNELS "${SLACK_ENV[@]}" "${SUP}" start 2>&1) || fail "supervisor.sh start (t22slack, Slack unset): ${OUT}"
WANT='waiting: waiting for Slack (SLACK_BOT_TOKEN/SLACK_CHANNELS)'
for I in $(seq 1 15); do [ "$(slack_state)" == "${WANT}" ] && break; sleep 1; done
[ "$(slack_state)" == "${WANT}" ] || fail "t22slack, its Slack settings unset, does not read '${WANT}': '$(slack_state)'"
P0=$(slack_pass)
for I in $(seq 1 30); do [ "$(slack_pass)" -ge $((P0 + 3)) ] 2>/dev/null && break; sleep 1; done
[ "$(slack_pass)" -ge $((P0 + 3)) ] 2>/dev/null || fail "the supervisor did not finish three passes after t22slack began waiting"
[ "$(slack_state)" == "${WANT}" ] || fail "t22slack left the waiting state with its settings unset: '$(slack_state)'"
# its own state.json says the same word as status.json
slack_own() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("state"))' "${SLK}/t22slack/state.json" 2>/dev/null; }
[ "$(slack_own)" == "waiting" ] || fail "t22slack's own state.json reads '$(slack_own)' while its status.json reads waiting"
[ -e "${D}/slack-cycle/runs.log" ] && fail "t22slack's cycle ran while it waited for its settings: $(cat "${D}/slack-cycle/runs.log")"
grep -q ' restart ' "${SLK}/t22slack/restarts.log" 2>/dev/null && fail "t22slack was restarted while it waited: $(cat "${SLK}/t22slack/restarts.log")"
tail -n +$((J0 + 1)) "${J}" | grep -q '"text": "t22slack ' && fail "the supervisor sent a notice about the waiting t22slack: $(tail -n +$((J0 + 1)) "${J}" | grep '"text": "t22slack ' | head -1)"
OUT=$(env -u SLACK_BOT_TOKEN -u SLACK_CHANNELS "${SLACK_ENV[@]}" "${SUP}" status 2>&1) || fail "supervisor.sh status fails while t22slack only waits: ${OUT}"
echo "${OUT}" | grep -qxF "spoke t22slack: WAITING session=t22slack - waiting for Slack (SLACK_BOT_TOKEN/SLACK_CHANNELS); set SLACK_BOT_TOKEN and SLACK_CHANNELS in .env.local, then ./stop.sh && ./run.sh" \
	|| fail "the status row of the waiting spoke does not say what it waits for and how to set it: $(echo "${OUT}" | grep t22slack)"
TASK=$(tmux show-options -t "=t22slacksup:" -v @agent_task 2>/dev/null)
[[ "${TASK}" == *" - t22slack waiting for Slack"* ]] || fail "the supervisor's task line does not name the waiting spoke: '${TASK}'"
env "${SLACK_ENV[@]}" "${SUP}" stop > /dev/null 2>&1
# started again with both set, it goes on: the cycle runs and the spoke goes live
OUT=$(env SLACK_BOT_TOKEN=planted SLACK_CHANNELS=C0PLANTED "${SLACK_ENV[@]}" "${SUP}" start 2>&1) || fail "supervisor.sh start (t22slack, Slack set): ${OUT}"
for I in $(seq 1 20); do slack_state | grep -q '^live: ' && break; sleep 1; done
slack_state | grep -q '^live: ' || fail "t22slack, its Slack settings set, did not go live: '$(slack_state)'"
[ "$(slack_own)" == "live" ] || fail "t22slack's own state.json reads '$(slack_own)' while its status.json reads live"
[ -s "${D}/slack-cycle/runs.log" ] || fail "t22slack's cycle did not run with its settings set"
env "${SLACK_ENV[@]}" "${SUP}" stop > /dev/null 2>&1
tmux kill-session -t "=t22slack" 2>/dev/null
tmux kill-session -t "=t22slacksup" 2>/dev/null
echo "ok 5c [waiting-for-settings] - a spoke whose required settings are unset read '${WANT}' and kept it for three passes, its cycle never ran, it was never restarted and no notice went out; its row read WAITING with how to set them, the status did not fail, and the task line named it; with both set it went live after its cycle"

# --- 5b. the supervisor's cost: python3 starts against a budget, and the mailbox log read from where it stopped ---
PYS=${D}/pyshim
mkdir -p "${PYS}" "${D}/mbx-cost"
printf '#!/bin/bash\necho x >> %s/count\nexec %s "$@"\n' "${PYS}" "$(command -v python3)" > "${PYS}/python3"
chmod +x "${PYS}/python3"
# the shipped registry with every session off, its supervisor renamed so this run never touches the test's own session
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for e in d["sessions"]:
    if e.get("role") == "supervisor":
        e["session_name"] = "t22costsup"
json.dump(d, open(sys.argv[2], "w"), indent=1)' "${SHIPPED_REGISTRY}" "${D}/cost-registry.json"
COST_ENV=("${ALL_OFF[@]}" SPOKES_REGISTRY="${D}/cost-registry.json" SUPERVISOR_DIR="${D}/sup-cost" MAILBOX_PROJECTION_ROOT="${D}/mbx-cost" AGENT_TMUX_SESSION_NAME=agent
	AGENT_TMUX_SESSION=false UI_HINDSIGHT=false UI_CLAUDE_MEM=false SUPERVISOR_INTERVAL=1 PATH="${PYS}:${PATH}")
: > "${PYS}/count"
env "${COST_ENV[@]}" timeout 7 "${SUP}" run > "${D}/sup-cost.log" 2>&1
PASSES=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "${D}/sup-cost/status.json" 2>/dev/null)
NPY=$(wc -l < "${PYS}/count")
[ "${NPY}" -gt 0 ] || fail "PLANTED CONTROL: the python3 shim saw no start, so the budget below proves nothing"
[ -n "${PASSES}" ] && [ "${PASSES}" -ge 3 ] || fail "the cost run finished ${PASSES:-no} passes in 7 s: $(tail -3 "${D}/sup-cost.log")"
[ "${NPY}" -le $((4 * PASSES + 2)) ] || fail "the supervisor started ${NPY} python3 processes in ${PASSES} passes with every session off (budget: 4 a pass)"
: > "${PYS}/count"
env "${COST_ENV[@]}" "${SUP}" status > /dev/null 2>&1
NST=$(wc -l < "${PYS}/count")
[ "${NST}" -le 4 ] || fail "supervisor.sh status, ui-status.sh's rows, started ${NST} python3 processes (budget: 4)"
# the mailbox log, read from where the last pass stopped
LOGC="${D:?}/mbx-cost/log.jsonl"
msg() { python3 -c 'import json, sys; env = {"v": 1, "id": sys.argv[1], "from": "example", "to": "agent", "ts": "2026-10-14T00:00:00Z", "kind": "notice", "text": sys.argv[2]}; print(json.dumps({"v": 1, "seq": 1, "event": "message.accepted", "id": sys.argv[1], "details": {"env": env, "meta": {}}}))' "$@"; }
cost_pass()
{
	# cost_pass <want> <what> - two passes, then the agent session's last message must read <want>, and the index's offset
	# must be the log's last line end
	env "${COST_ENV[@]}" timeout 3 "${SUP}" run > /dev/null 2>&1
	GOT=$(python3 -c 'import json, sys; m = json.load(open(sys.argv[1]))["sessions"]["agent"]["last_message"]; print(m["text"] if m else "")' "${D}/sup-cost/status.json")
	[ "${GOT}" == "$1" ] || fail "after $2, the agent session's last message reads '${GOT}', not '$1'"
	python3 -c 'import json, os, sys
i = json.load(open(sys.argv[1]))
data = open(sys.argv[2], "rb").read()
assert i["offset"] == data.rfind(b"\n") + 1, (i["offset"], len(data))' "${D}/sup-cost/last-messages.json" "${LOGC}" 2>/dev/null \
		|| fail "after $2, last-messages.json does not stop at the log's last line end: $(cat "${D}/sup-cost/last-messages.json" 2>&1 | head -c 300)"
}
{ msg m1 first; msg m2 second; } > "${LOGC}"
cost_pass second "two messages"
msg m3 third >> "${LOGC}"
cost_pass third "an appended message"
msg m4 fourth | tr -d '\n' >> "${LOGC}"
cost_pass third "a line still being written"
echo >> "${LOGC}"
cost_pass fourth "that line's end"
msg m5 replaced > "${LOGC:?}.new" && mv "${LOGC:?}.new" "${LOGC:?}"
cost_pass replaced "the log replaced by a new file"
{ msg m6 shorter; } > "${LOGC}.tmp" && cat "${LOGC}.tmp" > "${LOGC}" && rm -f "${D:?}/mbx-cost/log.jsonl.tmp"
cost_pass shorter "the log rewritten shorter in place"
echo "ok 5b - with every session off ${NPY} python3 processes started in ${PASSES} passes (budget 4 a pass) and ${NST} in supervisor.sh status (budget 4); the mailbox log is read from where the last pass stopped: an appended message, a line still being written, a replaced and a rewritten log"

# --- 6. flags, rows and tiles ---
# every UI off but the home page, on a test port; the shipped registry for the default view
HOME_ENV="UI_DIR=${D}/ui-home UI_LISTEN_HOST=127.0.0.1 UI_HOME=true UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false LOOP_DECK_DATA_DIR=${D}/loop-deck COMMS_UI_ENABLED=false UI_CHAT=false UI_BOARD=false UI_FILES=false UI_PORT_HOME=${HOME_PORT}"
PAGE=${D}/ui-home/home/site/index.html
OFF_ENV="SPOKES_REGISTRY=${SHIPPED_REGISTRY} SUPERVISOR_DIR=${D}/sup-off ${ALL_OFF[*]} SPOKE_T22W=false SUPERVISOR=false AGENT_TMUX_SESSION_NAME=agent"
env ${HOME_ENV} ${OFF_ENV} "${AGENT_DIR}/home-render.sh" > "${D}/render-off.log" 2>&1 || fail "home-render.sh with every spoke off: $(cat "${D}/render-off.log")"
WRITES=$(SPOKES_REGISTRY=${SHIPPED_REGISTRY} "${SPOKE}" entry example writes)
COST=$(SPOKES_REGISTRY=${SHIPPED_REGISTRY} "${SPOKE}" entry example cost)
grep -oE '<li class="tile spoke off" data-spoke="example">.*' "${PAGE}" | head -1 > "${D}/tile-off.html"
grep -qF 'off - set SPOKE_EXAMPLE=true in .env.local;' "${D}/tile-off.html" || fail "the example spoke's tile is not greyed with the flag that turns it on: $(cat "${D}/tile-off.html")"
grep -qF "writes only ${WRITES}" "${D}/tile-off.html" || fail "the off tile does not name what the spoke writes: $(cat "${D}/tile-off.html")"
grep -qF "${COST}" "${D}/tile-off.html" || fail "the off tile does not say what the spoke costs"
[ "$(grep -c '<li class="tile spoke off" data-spoke=' "${PAGE}")" == "$(SPOKES_REGISTRY=${SHIPPED_REGISTRY} "${SPOKE}" names | grep -c .)" ] || fail "the page has not one greyed tile per spoke of the registry"
grep -qF '<li class="tile spoke off" data-supervisor="supervisor">' "${PAGE}" && grep -qF 'off - set SUPERVISOR=true in .env.local;' "${PAGE}" || fail "the supervisor's tile is not greyed with its flag"
grep -q '<li class="tile spoke" ' "${PAGE}" && fail "with every flag off an agent tile is live"
grep -qF '<p class="group-note" id="agents-on">Every spoke is off. To run one, set SPOKE_&lt;NAME&gt;=true in .env.local, then ./stop.sh &amp;&amp; ./run.sh.</p>' "${PAGE}" \
	|| fail "with every spoke off the line under the Agents heading does not say so and how to run one: $(grep -o '<p class="group-note"[^<]*</p>' "${PAGE}")"
# the shipped defaults, the registry's (no flag set): the seven spokes' tiles live, each link keeping its opener for the
# home badge, the example's off, and the line under the heading naming the seven and how to turn one off
mapfile -t UNSET < <(for KV in "${ALL_OFF[@]}"; do echo "-u"; echo "${KV%%=*}"; done)
env "${UNSET[@]}" ${HOME_ENV} UI_DIR=${D}/ui-home-on UI_TMUX_AGENT=true SPOKES_REGISTRY=${SHIPPED_REGISTRY} SUPERVISOR_DIR=${D}/sup-off \
	SUPERVISOR=true AGENT_TMUX_SESSION_NAME=agent "${AGENT_DIR}/home-render.sh" > "${D}/render-on.log" 2>&1 \
	|| fail "home-render.sh with the shipped defaults: $(cat "${D}/render-on.log")"
PON=${D}/ui-home-on/home/site/index.html
for N in conversations insights clusters sessions loops issues docker; do
	grep -qF "<li class=\"tile spoke\" data-spoke=\"${N}\">" "${PON}" || fail "with the shipped defaults the ${N} tile is not live"
done
grep -qF '<li class="tile spoke off" data-spoke="example">' "${PON}" || fail "with the shipped defaults the example's tile is not off"
grep '<li class="tile spoke" ' "${PON}" | grep -q 'noopener' && fail "a live agent tile opens noopener, so the home badge could not return to the home tab"
[ "$(grep '<li class="tile spoke" ' "${PON}" | grep -c 'target="_blank" rel="opener"')" == "8" ] \
	|| fail "the eight live agent tiles (the supervisor and seven spokes) do not each open with rel=opener: $(grep -c '<li class="tile spoke" ' "${PON}")"
grep -qF '<p class="group-note" id="agents-on">On: conversations, insights, clusters, sessions, loops, issues, docker. To turn one off, set SPOKE_&lt;NAME&gt;=false in .env.local, then ./stop.sh &amp;&amp; ./run.sh.</p>' "${PON}" \
	|| fail "with the shipped defaults the line under the Agents heading does not name the seven and how to turn one off: $(grep -o '<p class="group-note"[^<]*</p>' "${PON}")"
grep -qF "document.getElementById('agents-on')" "${PON}" || fail "the page's script does not keep the Agents line to the supervisor's last pass"
# a setting a person changes goes in .env.local: no spoke or supervisor tile, off or on, sends them to .env - the
# conversations tile's token among them - and the supervisor's reason for a spoke that is off (5b's run, every spoke
# off) names .env.local too
NSPOKES=$(SPOKES_REGISTRY=${SHIPPED_REGISTRY} "${SPOKE}" names | grep -c .)
python3 - "${NSPOKES}" "${PAGE}" "${PON}" << 'EOF' || fail "a spoke or supervisor tile names .env for a setting, or the conversations tile does not name .env.local for its token"
import re, sys
n, pages = int(sys.argv[1]), sys.argv[2:]
tiles = [t for p in pages for t in re.findall(r'<li class="tile spoke[^"]*" data-(?:spoke|supervisor)="[^"]*">.*?</li>', open(p).read(), re.S)]
# each page has one tile per spoke of the registry and one for the supervisor
assert n > 0 and len(tiles) == len(pages) * (n + 1), ("not one tile per spoke of the registry and one for the supervisor on each page", n, len(tiles))
# .env in any shape (".env;", "<code>.env</code>", a sentence's last ".env.") but .env.local
bad = [t for t in tiles if re.search(r"\.env(?!\.local)(?!\w)", t)]
assert not bad, bad
conv = [t for t in tiles if 'data-spoke="conversations"' in t]
assert len(conv) == 2 and all("a token in .env.local;" in t for t in conv), conv
EOF
python3 - "${D}/sup-cost/status.json" << 'EOF' || fail "status.json's reason for a spoke that is off does not name .env.local: $(head -c 600 "${D}/sup-cost/status.json")"
import json, sys
off = [(n, s) for n, s in json.load(open(sys.argv[1]))["sessions"].items() if s.get("role") == "spoke" and s.get("state") == "off"]
assert off, "no spoke is off in the run with every spoke off"
for n, s in off:
    assert s["why"] == "set %s=true in .env.local to run it" % s["flag"], (n, s["why"])
EOF
# the example spoke's README tells a person to turn it on the way its greyed tile does: SPOKE_EXAMPLE=true in .env.local
python3 - "${AGENT_DIR}/charters/example/README.md" << 'EOF' || fail "the example spoke's README does not say to set SPOKE_EXAMPLE=true in .env.local: $(grep -n 'SPOKE_EXAMPLE' "${AGENT_DIR}/charters/example/README.md")"
import re, sys
t = " ".join(open(sys.argv[1]).read().split())
assert "`SPOKE_EXAMPLE=true` in `.env.local`, then `./stop.sh && ./run.sh`" in t, "no SPOKE_EXAMPLE=true in .env.local"
bad = re.findall(r".{0,40}\.env(?!\.local)(?!\w).{0,20}", t)
assert not bad, bad
EOF
# the Slack scripts and the git identity tell a person where the token, the channels and the identity go the same way:
# in .env.local (no secrets in the tracked .env)
python3 - "${AGENT_DIR}/slack-post.sh" "${AGENT_DIR}/slack-watch.sh" "${AGENT_DIR}/slack-status.sh" "${AGENT_DIR}/git-identity.sh" << 'EOF' \
	|| fail "a Slack script or git-identity.sh tells a person to put a setting in .env, not .env.local"
import re, sys
bad = [(p, n, l.strip()[:160]) for p in sys.argv[1:] for n, l in enumerate(open(p), 1) if re.search(r"\bin \.env(?!\.local)(?!\w)", l)]
assert not bad, bad
missing = [p for p in sys.argv[1:] if "in .env.local" not in open(p).read()]
assert not missing, ("no hint names .env.local", missing)
EOF
# the docs that repeat these hints say the same: each row of docs/slack/README.md's troubleshooting table that names a
# settings file quotes a message a Slack script gives today and names only .env.local, and the manual's "Git identity"
# (docs/manual/install.md) says to set the identity in .env.local. ./test.sh mounts the checkout at /do-agent-aws, so a
# missing doc fails the check
CHECKOUT=""
for C in "${BASE_DIR}/.." /do-agent-aws; do [ -f "${C}/docs/manual/install.md" ] && [ -f "${C}/docs/slack/README.md" ] && CHECKOUT=${C} && break; done
[ -n "${CHECKOUT}" ] || fail "no checkout with docs/manual/install.md and docs/slack/README.md beside this test or at /do-agent-aws, where ./test.sh mounts it"
python3 - "${CHECKOUT}/docs/slack/README.md" "${CHECKOUT}/docs/manual/install.md" "${AGENT_DIR}/slack-post.sh" "${AGENT_DIR}/slack-watch.sh" "${AGENT_DIR}/slack-status.sh" << 'EOF' \
	|| fail "docs/slack/README.md quotes a message no Slack script gives or names .env for a setting, or docs/manual/install.md does not say to set the identity in .env.local"
import re, sys
doc, readme, scripts = sys.argv[1], sys.argv[2], sys.argv[3:]
src = "".join(open(p).read() for p in scripts)
rows = [l.strip() for l in open(doc) if l.startswith("| `ERROR: ") and ".env" in l]
assert rows, "no troubleshooting row of docs/slack/README.md names a settings file"
for r in rows:
    quote = r.split("`")[1][len("ERROR: "):]
    quote = quote[:-len(" ...")] if quote.endswith(" ...") else quote
    assert quote in src, ("a row quotes a message no Slack script gives", quote)
    assert not re.search(r"\.env(?!\.local)(?!\w)", r), ("a row names .env", r[:200])
t = " ".join(open(readme).read().split())
assert "Set `GIT_USER_NAME` and `GIT_USER_EMAIL` in `.env.local`" in t, "docs/manual/install.md does not say to set the identity in .env.local"
bad = re.findall(r"GIT_USER_(?:NAME|EMAIL)`? in `?\.env(?!\.local)(?!\w)", t)
assert not bad, bad
EOF
grep -q '__spokes' "${D}/ui-home/home/nginx.conf" && fail "with every flag off nginx.conf has the /__spokes route"
OUT=$(env UI_DIR=${D}/ui-status UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_HOME=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false UI_PLANE=false UI_CHAT=false UI_BOARD=false UI_FILES=false ${OFF_ENV} AGENT_TMUX_SESSION=false "${AGENT_DIR}/ui-status.sh" 2>&1) \
	|| fail "ui-status.sh exits non-zero with every spoke off: ${OUT}"
echo "${OUT}" | grep -qx "spoke example: OFF (set SPOKE_EXAMPLE=true in .env.local to run it)" || fail "ui-status.sh has no OFF row naming the example's flag: ${OUT}"
echo "${OUT}" | grep -q "^supervisor: OFF (SUPERVISOR=false in .env.local;" || fail "ui-status.sh has no row for the supervisor that is off: ${OUT}"
# the Plane board off (UI_PLANE=false, the shipped default - it is opt-in, docs/manual/boards.md "Plane board"): its row says so with the
# flag, and the Board's (UI_BOARD=false here) is a plain DISABLED row; both keep the DISABLED word the Agent loop page's
# services panel parses (loop-view.py STATUS_RE)
echo "${OUT}" | grep -q '^plane: DISABLED (UI_PLANE=false' || fail "ui-status.sh with UI_PLANE=false has no 'plane: DISABLED (UI_PLANE=false' row: ${OUT}"
echo "${OUT}" | grep -q '^board: DISABLED' || fail "ui-status.sh with UI_BOARD=false has no 'board: DISABLED' row: ${OUT}"
# a spoke's flag on while SUPERVISOR=false: nothing starts or watches it, so its row says so and the exit stays 0 - the
# supervisor's own OFF row does not count, and a spoke it would have run cannot count either (every test that runs
# ui-status.sh with the supervisor off relies on this: outside ./test.sh the shipped flags are on). PLANTED CONTROL: the
# same spoke with SUPERVISOR=true and no loop running - the supervisor DOWN, the spoke UNKNOWN, exit 1
OUT=$(env UI_DIR=${D}/ui-status UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_HOME=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false UI_PLANE=false UI_CHAT=false UI_BOARD=false UI_FILES=false ${OFF_ENV} SPOKE_EXAMPLE=true AGENT_TMUX_SESSION=false "${AGENT_DIR}/ui-status.sh" 2>&1) \
	|| fail "ui-status.sh exits non-zero with a spoke on and SUPERVISOR=false: ${OUT}"
echo "${OUT}" | grep -qx "spoke example: OFF (SUPERVISOR=false in .env.local: nothing starts or watches it; SPOKE_EXAMPLE=true)" \
	|| fail "with SUPERVISOR=false the row of a spoke that is on does not name the setting that runs none: ${OUT}"
OUT=$(env UI_DIR=${D}/ui-status UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_HOME=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false UI_PLANE=false UI_CHAT=false UI_BOARD=false UI_FILES=false ${OFF_ENV} SPOKE_EXAMPLE=true SUPERVISOR=true AGENT_TMUX_SESSION=false "${AGENT_DIR}/ui-status.sh" 2>&1) \
	&& fail "PLANTED CONTROL: ui-status.sh exits 0 with a spoke on, SUPERVISOR=true and no supervisor running: ${OUT}"
echo "${OUT}" | grep -q "^supervisor: DOWN - SUPERVISOR=true and the loop does not run" || fail "PLANTED CONTROL: no DOWN row for the supervisor that is on and not running: ${OUT}"
echo "${OUT}" | grep -qx "spoke example: UNKNOWN - SPOKE_EXAMPLE=true and the supervisor has not reported on it" || fail "PLANTED CONTROL: no UNKNOWN row for the spoke the running-less supervisor has not seen: ${OUT}"
OUT=$(env ${OFF_ENV} "${SUP}" start 2>&1) || fail "the supervisor's start with SUPERVISOR=false: ${OUT}"
[ -e "${D}/sup-off" ] && fail "the supervisor's start with SUPERVISOR=false wrote ${D}/sup-off"
# the shipped default: the supervisor on - its tile is live and the route is there, with every spoke off
env ${HOME_ENV} ${OFF_ENV} SUPERVISOR=true "${AGENT_DIR}/home-render.sh" > "${D}/render-sup.log" 2>&1 || fail "home-render.sh with the supervisor on: $(cat "${D}/render-sup.log")"
grep -qF '<li class="tile spoke" data-supervisor="supervisor">' "${PAGE}" || fail "with the supervisor on its tile is not live"
grep -q '__spokes' "${D}/ui-home/home/nginx.conf" || fail "with the supervisor on nginx.conf has no /__spokes route"
# a spoke on and the supervisor running (check 5's): the live tile, /__spokes through the proxy, ui-start.sh's rows
OUT=$(env ${HOME_ENV} SPOKE_T22W=true "${AGENT_DIR}/ui-start.sh" 2>&1) || fail "ui-start.sh with t22w on: ${OUT}"
echo "${OUT}" | grep -q "^supervisor: UP pid=" || fail "ui-start.sh has no row for the supervisor: ${OUT}"
echo "${OUT}" | grep -q "^spoke t22w: LIVE" || fail "ui-start.sh has no row for t22w: ${OUT}"
grep -oE '<li class="tile spoke" data-spoke="t22w">.*' "${PAGE}" | head -1 > "${D}/tile-on.html"
grep -qF '<p class="note spoke-state">checking the spoke</p>' "${D}/tile-on.html" || fail "t22w's tile is not live with a state line: $(cat "${D}/tile-on.html")"
grep -q "off - set SPOKE_T22W" "${D}/tile-on.html" && fail "t22w's live tile still says how to turn it on"
grep -qF "fetch('/__spokes'" "${PAGE}" || fail "the page's script does not read /__spokes"
grep -qF "s.state === 'waiting'" "${PAGE}" && grep -qF '.dot.waiting::after { content: "waiting"; }' "${PAGE}" \
	|| fail "the page has no waiting state for a spoke that waits for its settings"
H=http://127.0.0.1:${HOME_PORT}
for I in $(seq 1 20); do [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${H}/__spokes")" == "200" ] && break; sleep 1; done
curl -s -D "${D}/spokes.hdr" -o "${D}/spokes.json" --max-time 5 "${H}/__spokes"
grep -qi '^cache-control: no-store' "${D}/spokes.hdr" || fail "/__spokes is not served with Cache-Control no-store: $(cat "${D}/spokes.hdr")"
python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["sessions"]["t22w"]; assert s["state"] == "live" and s["last_message"]["from"] == "t22w", s' "${D}/spokes.json" \
	|| fail "the proxy's /__spokes does not say t22w is live with its last message: $(head -c 600 "${D}/spokes.json")"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "${H}/__spokes")" == "403" ] || fail "/__spokes accepts a POST"
# PLANTED CONTROL: a stuck spoke (t22dies, from check 5) makes ui-status.sh exit 1
OUT=$(env UI_DIR=${D}/ui-status UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_HOME=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false UI_PLANE=false UI_CHAT=false UI_BOARD=false UI_FILES=false "${AGENT_DIR}/ui-status.sh" 2>&1) \
	&& fail "PLANTED CONTROL: ui-status.sh exits 0 with a stuck spoke: ${OUT}"
echo "${OUT}" | grep -q "^spoke t22dies: STUCK " || fail "ui-status.sh has no STUCK row for t22dies: ${OUT}"
OUT=$("${SUP}" stop 2>&1) || fail "supervisor.sh stop: ${OUT}"
[ -e "${SUPERVISOR_DIR}/supervisor.lock" ] && flock -n "${SUPERVISOR_DIR}/supervisor.lock" true || fail "the loop still holds its lock after stop"
tmux has-session -t "=t22w" 2>/dev/null || fail "stop took the spoke's session down"
# a stop lasts: the keepalive's ensure leaves a stopped supervisor stopped, until supervisor.sh start
OUT=$(CLAUDE_BIN=${D}/bydir/claude "${SUP}" ensure 2>&1) || fail "supervisor.sh ensure after a stop: ${OUT}"
sleep 2
flock -n "${SUPERVISOR_DIR}/supervisor.lock" true || fail "ensure started the supervisor again after supervisor.sh stop: ${OUT}"
[ -f "${SUPERVISOR_DIR}/STOP" ] || fail "ensure removed the stop flag"
"${SUP}" status 2>&1 | grep -q "^supervisor: STOPPED" || fail "a stopped supervisor does not read STOPPED: $("${SUP}" status 2>&1 | head -1)"
# PLANTED CONTROL: a supervisor whose last pass is old reads STALE; ensure starts it again and tells the hub (a loop that
# hung, so no stop flag)
rm -f "${SUPERVISOR_DIR:?}/STOP"
touch -d '-10 minutes' "${SUPERVISOR_DIR}/status.json"
setsid nohup bash -c "exec 9> '${SUPERVISOR_DIR}/supervisor.lock'; flock -n 9 && { echo \$\$ > '${SUPERVISOR_DIR}/supervisor.pid'; exec -a 'supervisor.sh run' sleep 600; }" > /dev/null 2>&1 < /dev/null &
# wait for the planted loop's pid file to name it, never by taking the lock: a probe that holds the lock at the moment
# the planted loop runs its own flock -n makes it give up, and the status then reads DOWN
for I in $(seq 1 20); do HOLDER=$(cat "${SUPERVISOR_DIR}/supervisor.pid" 2>/dev/null); tr '\0' ' ' 2>/dev/null < "/proc/${HOLDER:-0}/cmdline" | grep -q '^supervisor.sh run' && break; sleep 0.25; done
tr '\0' ' ' 2>/dev/null < "/proc/${HOLDER:-0}/cmdline" | grep -q '^supervisor.sh run' || fail "PLANTED CONTROL: the planted loop did not start: its pid file names ${HOLDER:-nothing}"
OUT=$("${SUP}" status 2>&1) && fail "PLANTED CONTROL: the status exits 0 with a stale pass: ${OUT}"
echo "${OUT}" | grep -q "^supervisor: STALE pid=.* - its last pass was [0-9]* s ago" || fail "PLANTED CONTROL: no STALE row for an old pass: ${OUT}"
OUT=$(CLAUDE_BIN=${D}/bydir/claude "${SUP}" ensure 2>&1) || fail "supervisor.sh ensure: ${OUT}"
echo "${OUT}" | grep -q "supervisor: started again - its last pass was [0-9]* s old" || fail "ensure did not start the stale supervisor again: ${OUT}"
for I in $(seq 1 10); do OUT=$("${SUP}" status 2>&1 | head -1); echo "${OUT}" | grep -q "^supervisor: UP" && break; sleep 1; done
echo "${OUT}" | grep -q "^supervisor: UP" || fail "after ensure the supervisor is not up: ${OUT}"
grep -q '"text": "the supervisor was started again: its last pass was' "${J}" || fail "ensure did not tell the hub it started the supervisor again"
[ -z "$("${SUP}" ensure 2>&1)" ] || fail "ensure is not quiet when the supervisor is well"
"${SUP}" stop > /dev/null 2>&1
echo "ok 6 - every flag off: a greyed tile per spoke with its flag, what it writes and costs, the supervisor's greyed with SUPERVISOR, no live tile, the Agents line saying none runs and how to run one, no /__spokes route, OFF rows with exit 0 (a spoke on while SUPERVISOR=false too; control: on with SUPERVISOR=true and no supervisor running, DOWN and UNKNOWN with exit 1), a start that writes nothing; the shipped defaults: seven live spoke tiles, eight agent links that keep their opener (the docker spoke's to its page), the Agents line naming the seven and how to turn one off; a setting goes in .env.local: no spoke or supervisor tile, off or on, names .env, status.json gives .env.local as the reason for every spoke that is off, the example's README says so for SPOKE_EXAMPLE, and so do the hints of the Slack scripts and git-identity.sh, the Slack troubleshooting rows that quote them and README.md's Git identity section; the supervisor on: its live tile and the route; t22w on: ui-start.sh's rows, a live tile with its state line, /__spokes through the proxy (live, its last message, no-store, POST refused); a stuck spoke makes ui-status.sh exit 1; a stale pass reads STALE and ensure starts the supervisor again, tells the hub, and is quiet when all is well"

# --- 7. the .env contract, when a checkout is at hand: seven flags ship on, the example's off, the supervisor on, and they reach the
#        container; startup.sh starts the supervisor after the shared session and its keepalive watches the pass ---
ENV_FILE=""
for C in "${BASE_DIR}/../.env" "/do-agent-aws/.env"; do
	[ -f "${C}" ] && ENV_FILE="$(cd "$(dirname "${C}")" && pwd)/.env" && break
done
if [ -n "${ENV_FILE}" ]; then
	ENV_DIR="$(dirname "${ENV_FILE}")"
	COMPOSE="${ENV_DIR}/to/compose/template/docker-compose.yaml"
	K8S="${ENV_DIR}/to/kubernetes/template/020-deployment.yaml"
	grep -qx "export SPOKE_EXAMPLE=false" "${ENV_FILE}" || fail "SPOKE_EXAMPLE=false is not the .env default (the example ships off)"
	for V in SPOKE_CONVERSATIONS SPOKE_INSIGHTS SPOKE_CLUSTERS SPOKE_SESSIONS SPOKE_LOOPS SPOKE_ISSUES SPOKE_DOCKER; do
		grep -qx "export ${V}=true" "${ENV_FILE}" || fail "${V}=true is not the .env default (the seven spokes ship on)"
	done
	grep -qx "export SUPERVISOR=true" "${ENV_FILE}" || fail "SUPERVISOR=true is not the .env default (the supervisor watches the agent session even with no spoke on)"
	for V in SPOKE_EXAMPLE SPOKE_CONVERSATIONS SPOKE_INSIGHTS SPOKE_CLUSTERS SPOKE_SESSIONS SPOKE_LOOPS SPOKE_ISSUES SPOKE_DOCKER SUPERVISOR SUPERVISOR_INTERVAL SUPERVISOR_RESTART_CAP SUPERVISOR_HEALTHY_SECS SUPERVISOR_START_GRACE SUPERVISOR_MEMORY_QUEUE_WARN SUPERVISOR_CLOSE_EXITED; do
		grep -E '^export SPOKE_ENV_OPTS=' "${ENV_FILE}" | grep -qE -- "-e ${V}( |\"\$)" || fail "SPOKE_ENV_OPTS does not pass ${V} into the container"
		[ -f "${COMPOSE}" ] && { grep -qxE -- " +- ${V}" "${COMPOSE}" || fail "the compose template does not pass ${V}"; }
		[ -f "${K8S}" ] && { grep -qF -- "- name: ${V}" "${K8S}" || fail "the kubernetes template does not pass ${V}"; }
	done
	grep -E '^export AGENT_ENV_OPTS=' "${ENV_FILE}" | grep -qF '${SPOKE_ENV_OPTS}' || fail "AGENT_ENV_OPTS does not carry SPOKE_ENV_OPTS (run.sh and test.sh would not pass the flags)"
	# the suite's container starts no spoke: TEST_RUN_OPTS ends each shipped spoke's flag at false (the last -e wins)
	TRO=$(cd "${ENV_DIR}" && bash -c 'source ./.env > /dev/null 2>&1; echo "${TEST_RUN_OPTS}"')
	for KV in "${ALL_OFF[@]}"; do
		LASTV=$(echo " ${TRO}" | grep -oE -- " -e ${KV%%=*}(=[^ ]*)?( |$)" | tail -1 | tr -d ' ')
		[ "${LASTV}" == "-e${KV}" ] || fail "TEST_RUN_OPTS does not end ${KV%%=*} at false for the suite's container (its last switch: '${LASTV}')"
	done
	OPTS=$(cd "${ENV_DIR}" && bash -c 'source ./.env > /dev/null 2>&1; echo "${AGENT_ENV_OPTS}"')
	echo "${OPTS}" | grep -qE -- "-e SPOKE_EXAMPLE( |$)" || fail "the sourced AGENT_ENV_OPTS does not carry -e SPOKE_EXAMPLE: ${OPTS}"
	# the bare switch passes the value .env exports: docker run reads it from run.sh's environment
	VAL=$(cd "${ENV_DIR}" && bash -c 'source ./.env > /dev/null 2>&1; env | grep -E "^(SPOKE_EXAMPLE|SUPERVISOR)=" | sort | tr "\n" " "')
	[ "${VAL}" == "SPOKE_EXAMPLE=false SUPERVISOR=true " ] || fail "sourcing .env does not export SPOKE_EXAMPLE=false and SUPERVISOR=true for the bare -e switches: '${VAL}'"
	# the docker spoke's build substrate as shipped (docs/manual/agents.md "Docker agent")
	for V in DOCKER_BUILDKIT_IMAGE DOCKER_REGISTRY_IMAGE; do
		grep -qE "^export ${V}=[^ @]+:[^ @]+@sha256:[0-9a-f]{64}\$" "${ENV_FILE}" || fail "${V} is not pinned by tag and digest in .env (export ${V}=<image>:<tag>@sha256:<64 hex digits>)"
	done
	grep -qF 'RUN_OPTS="${RUN_OPTS} -e DOCKER_SUBSTRATE=failed"' "${ENV_DIR}/run.sh" \
		|| fail "run.sh does not mark a build substrate that did not come up (-e DOCKER_SUBSTRATE=failed), so the agent's rows would read it as a target that runs none"
	grep -qE '^HOME_PATHS = \{.*"v1"' "${BASE_DIR%/}/agent/spoke.sh" || fail "spoke.sh does not reserve the home listener's /v1/ path from spoke pages (HOME_PATHS)"
	for L in "* **Every session in the container can reach the daemon's socket.**" "* **A build's RUN steps share the daemon's network and egress.**" \
		"* **The registry has no authentication.**" "Building an image FROM one already in the stack's registry is not supported"; do
		grep -qF -- "${L}" "${ENV_DIR}/docs/manual/agents.md" || fail "the manual's Docker agent limits (docs/manual/agents.md) lack: ${L}"
	done
	ENV_NOTE=".env, compose and kubernetes carry the eight flags (seven on, the example off), SUPERVISOR (true) and the supervisor's settings, and the suite's container gets every spoke off; the build substrate's images are pinned by digest, run.sh marks a failed substrate, /v1/ is reserved from spoke pages and the README states its four limits"
else
	ENV_NOTE="(no .env found in this context: the .env half skipped)"
fi
SU=${BASE_DIR%/}/startup.sh
[ -f "${SU}" ] || SU=/startup.sh
awk '/\/agent\/tmux-session-start.sh$/ { s = NR } /^\/agent\/supervisor.sh start$/ { w = NR } END { exit !(s && w && w > s) }' "${SU}" \
	|| fail "startup.sh does not start the supervisor after the shared agent session (${SU})"
sed -n '/^while true; do$/,/^done$/p' "${SU}" | grep -q '/agent/supervisor.sh ensure' || fail "startup.sh's keepalive loop does not watch the supervisor's pass (${SU})"
# every test that runs the real startup.sh (its output redirected, a continued command line) turns the supervisor off
# (the tests' directory as it is: in the image BASE_DIR is "/", which a trailing-slash strip would turn into "")
python3 - "${BASE_DIR}" << 'EOF' || fail "a test runs the real startup.sh without SUPERVISOR=false, so the supervisor would write under the suite's /wd"
import glob, os, sys
runs = 0
for t in sorted(glob.glob(os.path.join(sys.argv[1], "test*.sh"))):
    if os.path.basename(t) == "test22.sh":
        continue
    lines = open(t).read().splitlines()
    for i, l in enumerate(lines):
        if '/startup.sh" >' not in l:
            continue
        cmd, j = [l], i - 1
        while j >= 0 and lines[j].rstrip().endswith("\\"):
            cmd.insert(0, lines[j]); j -= 1
        runs += 1
        assert "SUPERVISOR=false" in " ".join(cmd), (t, i + 1)
assert runs >= 4, runs   # test6, test10 (twice), test-comms-defaults
EOF
echo "ok 7 - ${ENV_NOTE}; startup.sh starts the supervisor after the shared session and its keepalive watches the pass; the tests that run startup.sh turn the supervisor off"

# --- 7b [plain-run-set] and 7c [killed-spoke-returns]: a plain start - .env's own defaults, no .env.local - as
#     startup.sh starts it (the agent session, then the supervisor) on a fresh tmux server, at the shipped interval ---
if [ -n "${ENV_FILE}" ]; then
	# the defaults as .env writes them (sourcing it would read an .env.local beside it)
	PLAIN=()
	for V in AGENT_TMUX_SESSION SUPERVISOR SUPERVISOR_INTERVAL $(SPOKES_REGISTRY="${SHIPPED_REGISTRY}" "${SPOKE}" table | awk '$2 == "spoke" { print $4 }'); do
		X=$(grep -E "^export ${V}=" "${ENV_FILE}" | tail -1 | cut -d= -f2-)
		[ -n "${X}" ] || fail ".env has no default for ${V}"
		PLAIN+=("${V}=${X}")
	done
	# the shipped registry where this test can run it: nothing fetched, its directories here, no cycles (which sessions
	# run is the question here) and a stub claude
	PL=${D}/plain
	mkdir -p "${PL}/sup"
	python3 - "${SHIPPED_REGISTRY}" "${PL}/registry.json" "${PL}" << 'EOF' || fail "could not write the plain start's registry"
import json, sys
src, dst, d = sys.argv[1:4]
doc = json.load(open(src))
for e in doc["sessions"]:
    if e.get("role") in ("spoke", "supervisor"):
        e["workdir"] = f"{d}/wd/{e['session_name']}"
    if e.get("role") == "spoke":
        e["source"] = "none"
        for k in ("ref", "cycle", "cadence_sec", "notices", "requires", "requires_what"):
            e.pop(k, None)
json.dump(doc, open(dst, "w"), indent=1)
EOF
	FT=${D}/tmux-plain
	mkdir -p "${FT}"
	FIRST_TMPDIRS="${FIRST_TMPDIRS} ${FT}"
	pt() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="${FT}" tmux "$@"; }
	PLAIN_ENV=("${PLAIN[@]}" SPOKES_REGISTRY="${PL}/registry.json" SUPERVISOR_DIR="${PL}/sup" AGENT_TMUX_SESSION_NAME=agent
		CLAUDE_BIN="${D}/stay/claude" UI_HINDSIGHT=false UI_CLAUDE_MEM=false HINDSIGHT_WAIT_SECS=0)
	psup() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="${FT}" "${PLAIN_ENV[@]}" "${AGENT_DIR}/supervisor.sh" "$@"; }
	# the sessions the registry enables with those defaults: agent, the seven spokes that ship on and the supervisor
	ENABLED=$(env "${PLAIN_ENV[@]}" "${SPOKE}" table | awk '$3 == "true" { print $1 }' | sort | tr '\n' ' ' | sed 's/ $//')
	[ "${ENABLED}" == "agent clusters conversations docker insights issues loops sessions supervisor" ] \
		|| fail "plain-run-set: .env's defaults enable '${ENABLED}', not agent, the seven spokes that ship on and the supervisor"
	# plain_run_set - the enabled sessions the plain start's tmux server has no session for, by name (empty: all run)
	plain_run_set() { comm -23 <(echo "${ENABLED}" | tr ' ' '\n') <(pt list-sessions -F '#{session_name}' 2>/dev/null | sort) | tr '\n' ' ' | sed 's/ $//'; }
	OUT=$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="${FT}" "${PLAIN_ENV[@]}" bash -c '"$1/tmux-session-start.sh" && "$1/supervisor.sh" start' _ "${AGENT_DIR}" 2>&1) \
		|| fail "the plain start (the agent session, then the supervisor): ${OUT}"
	for I in $(seq 1 30); do [ -z "$(plain_run_set)" ] && break; sleep 1; done
	MISS=$(plain_run_set)
	[ -z "${MISS}" ] || fail "plain-run-set: a plain start with .env's defaults has no tmux session for ${MISS} (tmux ls: $(pt list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ' '))"
	# 7c: the supervisor at the shipped interval brings a killed spoke back within 20 s, with one restart line
	SIV=$(printf '%s\n' "${PLAIN[@]}" | sed -n 's/^SUPERVISOR_INTERVAL=//p')
	plain_pass() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "${PL}/sup/status.json" 2>/dev/null; }
	for I in $(seq 1 30); do [ "$(plain_pass)" -ge 1 ] 2>/dev/null && break; sleep 1; done
	pt kill-session -t "=loops" || fail "could not kill the plain start's loops session"
	K=$(date +%s)
	for I in $(seq 1 25); do pt has-session -t "=loops" 2>/dev/null && break; sleep 1; done
	BACK=$(( $(date +%s) - K ))
	pt has-session -t "=loops" 2>/dev/null && [ "${BACK}" -le 20 ] \
		|| fail "killed-spoke-returns: the killed loops spoke is not back within 20 s at the shipped interval of ${SIV} s (${BACK} s)"
	for I in $(seq 1 10); do grep -q ' restart 1/' "${PL}/sup/loops/restarts.log" 2>/dev/null && break; sleep 0.5; done
	[ "$(grep -c ' restart ' "${PL}/sup/loops/restarts.log" 2>/dev/null)" == "1" ] \
		|| fail "killed-spoke-returns: loops' restarts.log does not carry one restart line: $(cat "${PL}/sup/loops/restarts.log" 2>&1)"
	# PLANTED CONTROL: with the supervisor stopped and loops killed, nothing brings it back and plain-run-set names it,
	# not the supervisor (its session stays); started again, the supervisor brings loops back and the set is whole
	psup stop > /dev/null 2>&1
	pt kill-session -t "=loops" 2>/dev/null
	sleep 2
	[ "$(plain_run_set)" == "loops" ] || fail "PLANTED CONTROL: with the supervisor stopped and loops killed, plain-run-set reads '$(plain_run_set)', not 'loops'"
	psup start > /dev/null 2>&1 || fail "could not start the plain start's supervisor again"
	for I in $(seq 1 25); do [ -z "$(plain_run_set)" ] && break; sleep 1; done
	MISS=$(plain_run_set)
	psup stop > /dev/null 2>&1
	for S in $(pt list-sessions -F '#{session_name}' 2>/dev/null); do pt kill-session -t "=${S}" 2>/dev/null; done
	[ -z "${MISS}" ] || fail "plain-run-set: with the supervisor started again, the plain start still has no tmux session for ${MISS}"
	PLAIN_NOTE="a plain start with .env's defaults (${PLAIN[*]}) runs a tmux session for each session the registry enables: ${ENABLED}; with the supervisor stopped and loops killed it names loops (control), and with the supervisor started again the set is whole"
	BACK_NOTE="a killed loops spoke was back in ${BACK} s at the shipped interval of ${SIV} s (budget 20 s), with one restart line"
else
	PLAIN_NOTE="(no .env found in this context: the plain start skipped)"
	BACK_NOTE="(no .env found in this context: skipped with the plain start)"
fi
echo "ok 7b [plain-run-set] - ${PLAIN_NOTE}"
echo "ok 7c [killed-spoke-returns] - ${BACK_NOTE}"

# --- 8. the fleet check: planted panes - menus never answered, /compact once, errors stuck, a shell pane down; the hub;
#        health ---
FC="${AGENT_DIR}/fleet-check.sh"
mkdir -p "${D}/fleet"
# one claude for every planted spoke: it prints the screen its directory names and logs whatever is typed into it
cat > "${D}/fleet/claude" << 'EOF'
#!/bin/bash
NAME=$(basename "$(pwd)")
LOG=__D__/fleet/${NAME}.input
screen()
{
	case "${NAME}" in
		t22menu) printf 'I will edit the file.\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n' ;;
		t22send) printf 'Draft reply ready.\n\n Post this reply to the channel?\n ❯ 1. Yes, send it\n   2. No, and tell Claude what to do differently\n' ;;
		t22ctx|t22second|t22person) printf 'done.\n\n────────\n❯ \n────────\n  __STATUS__\n' ;;
		t22work) printf '✻ Synthesizing… (4m 3s · esc to interrupt)\n\n────────\n❯ \n────────\n  ctx:92%%\n' ;;
		t22hud) printf 'done.\n\n────────\n❯ \n────────\n  [OMC#5.5.0] | Model: Fable 5.1 | session:622m | ctx:[########--]85%% | 🔧103\n' ;;
		t22cooked) printf '  ⎿  done\n\n✻ Cooked for 8s · done 3:45 AM\n\n────────\n❯ \n────────\n  __STATUS__\n' ;;
		t22noecho|t22noecho2) printf 'done.\n\n────────\n❯ \n────────\n  __STATUS__\n' ;;
		t22draft) printf 'done.\n\n────────\n❯ draft reply to the thread\n────────\n  __STATUS__\n' ;;
		t22hubmenu) printf 'Edit the file?\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n' ;;
		t22api) printf '  ⎿  API Error: 500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}\n\n────────\n❯ \n────────\n' ;;
		t22long) printf '  ⎿  Prompt is too long\n\n────────\n❯ \n────────\n' ;;
		t22compf) printf '  ⎿  Error: Compaction failed: the conversation could not be summarized\n\n────────\n❯ \n────────\n' ;;
		*) printf 'ready\n\n────────\n❯ \n────────\n' ;;
	esac
}
# the panes that take /compact draw Claude Code's input line, the prompt mark and a no-break space, where typed text
# shows; t22noecho's input line never shows it
case "${NAME}" in t22ctx|t22cooked|t22second|t22person) RP=(-p $'\u276f\u00a0') ;; t22noecho|t22noecho2) RP=(-s -p $'\u276f\u00a0') ;; *) RP=() ;; esac
# t22draft holds a person's draft at the prompt, at 85%: it logs every key that reaches it, one at a time, Enter or not
if [ "${NAME}" == t22draft ]; then
	screen
	while IFS= read -r -n 1 -d '' K; do printf '%s' "${K}" >> "${LOG}"; done
	exit 0
fi
# t22second's agent draws its screen only once the test has opened a person's window in its session
[ "${NAME}" == t22second ] && while [ ! -e __D__/fleet/t22second.go ]; do sleep 0.2; done
screen
while IFS= read -r "${RP[@]}" L; do
	echo "${L}" >> "${LOG}"
	screen
done
EOF
# the idle 85% pane shows the status line the image sets for claude, so the 80% rule is proven on that line's form
[ -x "${AGENT_DIR}/claude-statusline.sh" ] || fail "the image's status line script ${AGENT_DIR}/claude-statusline.sh is missing"
STATUS=$(echo '{"model": {"display_name": "Opus"}, "context_window": {"used_percentage": 85}}' | "${AGENT_DIR}/claude-statusline.sh")
[[ "${STATUS}" == *"ctx:85%"* ]] || fail "the image's status line does not print ctx:85% for a session at 85%: '${STATUS}'"
STATUS_FMT=${STATUS//%/%%}
sed -i -e "s#__D__#${D}#" -e "s#__STATUS__#${STATUS_FMT}#" "${D}/fleet/claude"
chmod +x "${D}/fleet/claude"
PLANTS="t22menu t22send t22ctx t22cooked t22noecho2 t22second t22draft t22work t22api t22long t22compf t22shell"
SESSIONS="${SESSIONS} ${PLANTS}"
for S in ${PLANTS}; do
	charter "${S}"
	entry "${S}" '{"cycle": null, "cadence_sec": null, "cooldown_sec": 2}'
	export "SPOKE_$(echo "${S}" | tr '[:lower:]' '[:upper:]')=true"
done
# a pane without claude: its command is a plain sleep
entry t22shell '{"cycle": null, "cadence_sec": null, "cooldown_sec": 2, "launch_cmd": "sleep 600"}'
# the checks of check 5 and 6 are done: their spokes off
export SPOKE_T22W=false SPOKE_T22DIES=false SPOKE_T22NONE=false
tmux kill-session -t "=t22w" 2>/dev/null
# the hub: first a session whose pane runs no claude (a shell the person left)
tmux new-session -d -s "${AGENT_TMUX_SESSION_NAME}" "bash -c 'sleep 600'" || fail "could not plant the hub's shell pane"
HUB_ID=$(tmux list-sessions -F '#{session_name} #{session_id}' | awk -v s="${AGENT_TMUX_SESSION_NAME}" '$1 == s { print $2 }')
# health: a memory API that answers, and a session-memory worker with a deep queue
cat > "${D}/fleet/health.py" << 'EOF'
import http.server, json, sys
port, body = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
python3 "${D}/fleet/health.py" ${API_PORT} '{"status": "healthy"}' > /dev/null 2>&1 &
API_PID=$!
python3 "${D}/fleet/health.py" ${WORKER_PORT} '{"isProcessing": true, "queueDepth": 900, "parkedSessions": 0}' > /dev/null 2>&1 &
WORKER_PID=$!
HEALTH_PIDS="${API_PID} ${WORKER_PID}"
for I in $(seq 1 20); do curl -s --max-time 1 -o /dev/null http://127.0.0.1:${API_PORT}/ && curl -s --max-time 1 -o /dev/null http://127.0.0.1:${WORKER_PORT}/ && break; sleep 0.5; done
N0=$(wc -l < "${J}")
OUT=$(CLAUDE_BIN=${D}/fleet/claude AGENT_TMUX_SESSION=true SUPERVISOR_START_GRACE=3 UI_HINDSIGHT=true UI_PORT_HINDSIGHT_API=${API_PORT} UI_CLAUDE_MEM=true UI_PORT_CLAUDE_MEM=${WORKER_PORT} "${SUP}" start 2>&1) \
	|| fail "supervisor.sh start (the planted panes): ${OUT}"
export AGENT_TMUX_SESSION=true SUPERVISOR_START_GRACE=3 UI_HINDSIGHT=true UI_PORT_HINDSIGHT_API=${API_PORT} UI_CLAUDE_MEM=true UI_PORT_CLAUDE_MEM=${WORKER_PORT}
verdict_of() { python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["sessions"][sys.argv[2]]; print(s["state"], s["why"], sep=": ")' "${SUPERVISOR_DIR}/status.json" "$1" 2>/dev/null; }
wait_verdict()
{
	# wait_verdict <session> <grep -E pattern for "state: why"> - up to 30 s
	for I in $(seq 1 30); do verdict_of "$1" | grep -qE "$2" && return 0; sleep 1; done
	fail "$1's verdict is not /$2/: '$(verdict_of "$1")' ($(tail -3 "${SUPERVISOR_DIR}/supervisor.log"))"
}
wait_verdict t22menu '^stuck: a menu is open: .*1\. Yes'
wait_verdict t22send '^stuck: a menu is open: '
wait_verdict t22api '^stuck: .*API Error: 500'
wait_verdict t22long '^stuck: .*Prompt is too long'
wait_verdict t22compf '^stuck: .*Compaction failed'
wait_verdict t22ctx '^stuck: context at 85%'
wait_verdict t22cooked '^stuck: context at 85%'
# a /compact fleet-check.sh refused is not recorded as sent, and is tried again
wait_verdict t22noecho2 '^stuck: context at 85%; /compact not sent'
wait_verdict t22work '^live: working'
wait_verdict t22shell '^down: no claude process in its pane'
wait_verdict "${AGENT_TMUX_SESSION_NAME}" '^down: no claude process in its pane \(a shell\); left for the person'
wait_verdict t22ctx '^stuck: context at 85% after the /compact at '
wait_verdict t22cooked '^stuck: context at 85% after the /compact at '
# a person's window in a spoke's session, the active one, with the person's own claude idle at 85%: the /compact goes
# into the agent's pane, which draws its screen only now, and nothing into the person's
mkdir -p "${D}/fleet/t22person"
tmux new-window -t "=t22second:" -n person -c "${D}/fleet/t22person" "bash -c '${D}/fleet/claude; exit'" \
	|| fail "could not open a person's window in t22second's session"
sleep 2
touch "${D}/fleet/t22second.go"
wait_verdict t22second '^stuck: context at 85%; /compact sent'
sleep 1
[ -s "${D}/fleet/t22person.input" ] && fail "the person's window in t22second's session got keys: $(cat -A "${D}/fleet/t22person.input")"
[ "$(cat "${D}/fleet/t22second.input" 2>/dev/null)" == "/compact" ] || fail "t22second's agent pane did not get /compact exactly once: '$(cat -A "${D}/fleet/t22second.input" 2>&1)'"
tmux kill-window -t "=t22second:person" 2>/dev/null
# more passes, then: the menus got nothing, the busy pane got nothing, the idle pane at 85% got /compact exactly once
P0=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "${SUPERVISOR_DIR}/status.json")
for I in $(seq 1 30); do [ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "${SUPERVISOR_DIR}/status.json")" -ge $((P0 + 5)) ] && break; sleep 1; done
for S in t22menu t22send t22work t22api t22long t22compf t22draft; do
	[ -s "${D}/fleet/${S}.input" ] && fail "PLANTED CONTROL: the supervisor typed into ${S}'s pane: $(cat -A "${D}/fleet/${S}.input")"
done
[ "$(cat "${D}/fleet/t22ctx.input" 2>/dev/null)" == "/compact" ] || fail "PLANTED CONTROL: the idle pane at 85% did not get /compact exactly once: '$(cat -A "${D}/fleet/t22ctx.input" 2>&1)'"
[ -s "${D}/fleet/t22noecho2.input" ] && fail "PLANTED CONTROL: Enter reached the spoke whose input line never showed /compact: $(cat -A "${D}/fleet/t22noecho2.input")"
python3 -c 'import json, sys; assert not json.load(open(sys.argv[1])).get("compact_sent_at")' "${SUPERVISOR_DIR}/t22noecho2/state.json" \
	|| fail "a refused /compact was recorded as sent for t22noecho2"
[ "$(cat "${D}/fleet/t22cooked.input" 2>/dev/null)" == "/compact" ] || fail "PLANTED CONTROL: the idle pane at 85% whose last turn left 'Cooked for 8s' did not get /compact exactly once: '$(cat -A "${D}/fleet/t22cooked.input" 2>&1)'"
# the hub's shell pane is the person's: reported, never replaced
[ "$(tmux list-sessions -F '#{session_name} #{session_id}' | awk -v s="${AGENT_TMUX_SESSION_NAME}" '$1 == s { print $2 }')" == "${HUB_ID}" ] \
	|| fail "the supervisor replaced the hub's session that runs a shell"
# each finding is one bus notice from the supervisor to the hub
python3 - "${J}" "${N0}" << 'EOF' || fail "the findings are not one supervisor notice each in the journal: $(tail -c 1500 "${J}")"
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1]).read().splitlines()[int(sys.argv[2]):]]
texts = [e["details"]["env"]["text"] for e in ev if e["event"] == "message.accepted" and e["details"]["env"]["from"] == "supervisor"]
for want in ("t22menu is stuck: a menu is open", "t22send is stuck: a menu is open", "t22api is stuck: ", "t22long is stuck: ",
             "t22compf is stuck: ", "t22ctx is stuck: context at 85%; /compact sent", "t22cooked is stuck: context at 85%; /compact sent", "t22noecho2 is stuck: context at 85%; /compact not sent", "t22shell is down: no claude process",
             "is down: no claude process in its pane (a shell)", "the session-memory queue is 900 deep (warning at 500)"):
    hits = [t for t in texts if want in t]
    assert len(hits) == 1, (want, hits, texts)
assert not [t for t in texts if t.startswith("t22work")], texts
EOF
# health: the memory API up, the worker's queue deep; the API stopped: down, and the hub told
python3 -c 'import json, sys; h = json.load(open(sys.argv[1]))["health"]; assert h["memory_api"]["state"] == "up" and h["memory_worker"]["state"] == "deep", h' "${SUPERVISOR_DIR}/status.json" \
	|| fail "status.json's health is not the memory API up and the worker's queue deep: $(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["health"])' "${SUPERVISOR_DIR}/status.json")"
kill "${API_PID}"
for I in $(seq 1 15); do python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["health"]["memory_api"]["state"] == "down"' "${SUPERVISOR_DIR}/status.json" 2>/dev/null && break; sleep 1; done
python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["health"]["memory_api"]["state"] == "down"' "${SUPERVISOR_DIR}/status.json" || fail "a stopped memory API does not read down"
for I in $(seq 1 10); do grep -q '"text": "the memory API does not answer /health' "${J}" && break; sleep 1; done
grep -q '"text": "the memory API does not answer /health' "${J}" || fail "the hub was not told that the memory API stopped answering"
python3 "${D}/fleet/health.py" ${API_PORT} '{"status": "healthy"}' > /dev/null 2>&1 &
API_PID=$!
HEALTH_PIDS="${API_PID} ${WORKER_PID}"
for I in $(seq 1 15); do grep -q '"text": "the memory API answers /health again"' "${J}" && break; sleep 1; done
grep -q '"text": "the memory API answers /health again"' "${J}" || fail "the hub was not told that the memory API answers again"
# the hub's session gone: started again, with claude in its pane
tmux kill-session -t "=${AGENT_TMUX_SESSION_NAME}"
for I in $(seq 1 10); do tmux has-session -t "=${AGENT_TMUX_SESSION_NAME}" 2>/dev/null && break; sleep 1; done
tmux has-session -t "=${AGENT_TMUX_SESSION_NAME}" 2>/dev/null || fail "the supervisor did not start the hub's session again"
wait_verdict "${AGENT_TMUX_SESSION_NAME}" '^live: idle'
# with the stack on, no session the harness started reads ORPHANED on the tmux-agent dashboard: the hub under operator,
# the supervisor and every spoke under the hub
curl -s --max-time 5 -o "${D}/fleet.json" http://127.0.0.1:${DASH_PORT}/api/fleet
python3 - "${D}/fleet.json" "${AGENT_TMUX_SESSION_NAME}" ${PLANTS} supervisor << 'EOF' || fail "the dashboard reads a session the harness started as ORPHANED, or without its lineage: $(head -c 1200 "${D}/fleet.json")"
import json, sys
hub, names = sys.argv[2], sys.argv[2:]
rows = {r.get("session"): r for r in json.load(open(sys.argv[1])).get("sessions") or []}
for n in names:
    r = rows.get(n)
    assert r is not None, ("not listed", n)
    assert r.get("engagement") != "ORPHANED", (n, r.get("engagement"), r.get("parent"))
    assert r.get("parent") == ("operator" if n == hub else hub) and r.get("owner") == "do-agent-aws", (n, r.get("parent"), r.get("owner"))
# the supervisor reports stuck panes without reading as stuck itself: its pane shows names and states, never their words
assert rows["supervisor"].get("state") not in ("ERROR", "BLOCKED"), ("the dashboard reads the supervisor as", rows["supervisor"].get("state"))
EOF
# the fleet check by hand: a busy pane is never compacted
OUT=$("${FC}" compact t22work) && fail "PLANTED CONTROL: fleet-check.sh compacted a pane that runs a turn: ${OUT}"
echo "${OUT}" | grep -q "^not sent: the pane reads working" || fail "fleet-check.sh compact refused a busy pane for another reason: ${OUT}"
OUT=$("${FC}" compact t22menu) && fail "PLANTED CONTROL: fleet-check.sh compacted a pane at a menu: ${OUT}"
[ -s "${D}/fleet/t22menu.input" ] && fail "PLANTED CONTROL: something was typed into the menu's pane"
# the fleet HUD's status line form, ctx:[bar]NN%: a pane outside the registry that shows it at 85%, idle, reads context
mkdir -p "${D}/fleet/t22hud"
SESSIONS="${SESSIONS} t22hud"
tmux new-session -d -s t22hud -c "${D}/fleet/t22hud" "${D}/fleet/claude" || fail "could not start the HUD-form pane"
for I in $(seq 1 20); do OUT=$("${FC}" t22hud); echo "${OUT}" | grep -q '"verdict": "context"' && break; sleep 0.5; done
echo "${OUT}" | python3 -c 'import json, sys; v = json.load(sys.stdin); assert v["verdict"] == "context" and v["ctx"] == 85, v' \
	|| fail "a pane whose status line is the fleet HUD's ctx:[########--]85% does not read context at 85%: ${OUT}"
tmux kill-session -t "=t22hud" 2>/dev/null
# the input line read back before Enter: a pane whose input line does not show the typed /compact gets no Enter
mkdir -p "${D}/fleet/t22noecho"
SESSIONS="${SESSIONS} t22noecho"
tmux new-session -d -s t22noecho -c "${D}/fleet/t22noecho" "${D}/fleet/claude" || fail "could not start the no-echo pane"
for I in $(seq 1 20); do "${FC}" t22noecho | grep -q '"verdict": "context"' && break; sleep 0.5; done
OUT=$("${FC}" compact t22noecho) && fail "PLANTED CONTROL: fleet-check.sh pressed Enter although the input line never showed /compact: ${OUT}"
echo "${OUT}" | grep -q "^not sent: after typing /compact the input line reads" || fail "fleet-check.sh refused the no-echo pane for another reason: ${OUT}"
sleep 1
[ -s "${D}/fleet/t22noecho.input" ] && fail "PLANTED CONTROL: Enter reached the no-echo pane: $(cat -A "${D}/fleet/t22noecho.input")"
tmux kill-session -t "=t22noecho" 2>/dev/null
# the agent session's own menu is its person's: status.json says so, and no notice goes to the inbox, nor one when it clears
NH0=$(grep -c "\"text\": \"${AGENT_TMUX_SESSION_NAME} is " "${J}")
mkdir -p "${D}/fleet/t22hubmenu" "${D}/fleet/t22hubidle"
tmux respawn-pane -k -t "=${AGENT_TMUX_SESSION_NAME}:" -c "${D}/fleet/t22hubmenu" -e "CLAUDE_BIN=${D}/fleet/claude" -e AGENT_TMUX_CLAUDE=true \
	-e HINDSIGHT_WAIT_SECS=0 "${AGENT_DIR}/tmux-claude.sh" || fail "could not plant the hub's menu"
wait_verdict "${AGENT_TMUX_SESSION_NAME}" '^stuck: a menu is open'
tmux respawn-pane -k -t "=${AGENT_TMUX_SESSION_NAME}:" -c "${D}/fleet/t22hubidle" -e "CLAUDE_BIN=${D}/fleet/claude" -e AGENT_TMUX_CLAUDE=true \
	-e HINDSIGHT_WAIT_SECS=0 "${AGENT_DIR}/tmux-claude.sh" || fail "could not clear the hub's menu"
wait_verdict "${AGENT_TMUX_SESSION_NAME}" '^live: idle'
sleep 2
NH1=$(grep -c "\"text\": \"${AGENT_TMUX_SESSION_NAME} is " "${J}")
[ "${NH1}" == "${NH0}" ] || fail "the agent session's own menu sent notices to its inbox: $(grep "\"text\": \"${AGENT_TMUX_SESSION_NAME} is " "${J}" | tail -2)"
# a window a person opens in the agent session, the active one with a shell in it, is not the agent's pane: the hub
# stays live through three more passes (one whole pass at least after the window opened), with no notice
P0=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "${SUPERVISOR_DIR}/status.json")
tmux new-window -t "=${AGENT_TMUX_SESSION_NAME}:" -n person "sleep 600" || fail "could not open a person's window in the hub's session"
for I in $(seq 1 60); do [ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "${SUPERVISOR_DIR}/status.json")" -ge $((P0 + 3)) ] && break; sleep 1; done
[ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "${SUPERVISOR_DIR}/status.json")" -ge $((P0 + 3)) ] \
	|| fail "the supervisor did not finish three passes in 60 s after the person's window opened, so the check below proves nothing"
verdict_of "${AGENT_TMUX_SESSION_NAME}" | grep -qE '^live: idle' \
	|| fail "a person's window in the agent session changed its verdict: '$(verdict_of "${AGENT_TMUX_SESSION_NAME}")'"
NH2=$(grep -c "\"text\": \"${AGENT_TMUX_SESSION_NAME} is " "${J}")
[ "${NH2}" == "${NH1}" ] || fail "a person's window in the agent session sent notices: $(grep "\"text\": \"${AGENT_TMUX_SESSION_NAME} is " "${J}" | tail -2)"
tmux kill-window -t "=${AGENT_TMUX_SESSION_NAME}:person" 2>/dev/null
"${SUP}" stop > /dev/null 2>&1
kill ${WORKER_PID} ${API_PID} 2>/dev/null
HEALTH_PIDS=""
# the runs below turn every planted spoke off but the ones they name, from PLANTS: a plant whose pass is slow (a refused
# /compact reads its input line back for 2 s) would otherwise delay their first pass
plants_off()
{
	local S
	for S in ${PLANTS}; do
		case " $* " in *" ${S} "*) ;; *) echo "SPOKE_$(echo "${S}" | tr '[:lower:]' '[:upper:]')=false" ;; esac
	done
}
# health at a container start: a memory API that comes up within SUPERVISOR_START_GRACE is never reported down
start_health_run()
{
	# start_health_run <grace> <log> - a supervisor whose memory API port answers only 2 s after its start
	local G=$1 LOGF=$2 OFF
	mapfile -t OFF < <(plants_off)
	env "${OFF[@]}" SUPERVISOR_DIR=${D}/sup-health-${G} SUPERVISOR_START_GRACE=${G} UI_PORT_HINDSIGHT_API=${LATE_API_PORT} UI_CLAUDE_MEM=false \
		AGENT_TMUX_SESSION=false timeout 12 "${SUP}" run > "${LOGF}" 2>&1 &
	local SUP_PID=$!
	sleep 2
	python3 "${D}/fleet/health.py" ${LATE_API_PORT} '{"status": "healthy"}' > /dev/null 2>&1 &
	local LATE_API=$!
	wait "${SUP_PID}"
	kill "${LATE_API}" 2>/dev/null
}
J0=$(wc -l < "${J}")
start_health_run 6 "${D}/health-grace.log"
tail -n +$((J0 + 1)) "${J}" | grep -q '"text": "the memory API does not answer /health' && fail "a memory API that came up within the start grace was reported down: $(cat "${D}/health-grace.log")"
python3 -c 'import json, sys; assert json.load(open(sys.argv[1]))["health"]["memory_api"]["state"] == "up"' "${D}/sup-health-6/status.json" || fail "the late memory API does not read up after its start"
# PLANTED CONTROL: with no grace the same start is reported down
J0=$(wc -l < "${J}")
start_health_run 0 "${D}/health-nograce.log"
tail -n +$((J0 + 1)) "${J}" | grep -q '"text": "the memory API does not answer /health' || fail "PLANTED CONTROL: without the start grace the late memory API was not reported down, so the check above proves nothing"
# PLANTED CONTROL: a supervisor that answers menus is caught - a copy of the scripts whose menu branch types "1" and
# Enter into the pane; a few of its passes over the planted menu, and that pane's input log is no longer empty
M=${D}/mutant-agent
mkdir -p "${M}"
cp -r "${AGENT_DIR}/." "${M}/"
python3 - "${M}/supervisor.sh" << 'EOF' || fail "could not make the menu-answering mutant"
import sys
p = sys.argv[1]
c = open(p).read()
old = 'CP_STATE=stuck; CP_WHY="a menu is open: ${FWHY}" ;;'
assert c.count(old) == 1, "the menu branch is not where the mutant expects it"
open(p, "w").write(c.replace(old, 'tmux send-keys -t "=${N}:" 1 Enter; CP_STATE=stuck; CP_WHY="a menu is open: ${FWHY}" ;;'))
EOF
mapfile -t OFF < <(plants_off t22menu)
env "${OFF[@]}" SUPERVISOR_DIR=${D}/mutant-sup AGENT_TMUX_SESSION=false UI_HINDSIGHT=false UI_CLAUDE_MEM=false \
	timeout 8 "${M}/supervisor.sh" run > "${D}/mutant.log" 2>&1
[ -s "${D}/fleet/t22menu.input" ] || fail "PLANTED CONTROL: a supervisor that answers menus typed nothing the planted pane logged, so the zero-keys checks above prove nothing: $(tail -3 "${D}/mutant.log")"
# PLANTED CONTROL: a fleet check without its idle gate is caught - a copy whose context verdict and compact skip the
# empty-prompt rule types into the pane at 85% that holds a person's draft, which logs every key
M2=${D}/mutant-idle
mkdir -p "${M2}"
cp -r "${AGENT_DIR}/." "${M2}/"
python3 - "${M2}/fleet-check.sh" << 'EOF' || fail "could not make the fleet check without its idle gate"
import sys
p = sys.argv[1]
c = open(p).read()
for old, new in (("elif ctx is not None and ctx >= 80 and idle:", "elif ctx is not None and ctx >= 80:"),
                 ('if [ "${VERDICT}" != "context" ] || [ "${IDLE}" != "true" ]; then', 'if [ "${VERDICT}" != "context" ]; then')):
    assert c.count(old) == 1, old
    c = c.replace(old, new)
open(p, "w").write(c)
EOF
mapfile -t OFF < <(plants_off t22draft)
env "${OFF[@]}" SUPERVISOR_DIR=${D}/mutant-idle-sup AGENT_TMUX_SESSION=false UI_HINDSIGHT=false UI_CLAUDE_MEM=false \
	timeout 8 "${M2}/supervisor.sh" run > "${D}/mutant-idle.log" 2>&1
[ -s "${D}/fleet/t22draft.input" ] \
	|| fail "PLANTED CONTROL: a fleet check without its idle gate typed nothing the draft pane logged, so its zero-keys check proves nothing: $(tail -3 "${D}/mutant-idle.log")"
ORPH="no session the harness started reads ORPHANED on the dashboard"
echo "ok 8 - planted panes: two menus (one would send) read stuck and got no key in 5 more passes, API Error, Prompt is too long and a failed compaction read stuck, an idle pane at 85% got /compact exactly once, into the agent's pane and not a person's window, a busy pane at 92% read working and got nothing, a pane at 85% holding a person's draft got no key, a pane with no claude read down; the hub's shell pane was reported and never replaced, the hub's session gone was started again; the memory API and the worker's queue in status.json; every finding one notice to the hub, a recovery too; a memory API that comes up within the start grace is not reported (without the grace it is); ${ORPH}; a mutant that answers menus and a fleet check without its idle gate are caught"

# --- 8b [menu-prose]. a sentence is not a menu: an idle pane whose answer says "yes, and" reads idle, and Claude Code's
#        own approval menu still reads menu, on its numbered option line ---
mkdir -p "${D}/prose/t22prose" "${D}/prose/t22approval" "${D}/prose/t22prosedraft"
# a spoke's answer to a bus request, idle at its prompt: the fleet check read its "returned yes, and the API" as a menu
cat > "${D}/prose/t22prose/screen.txt" << 'EOF'
  - Contexts: there is exactly one, eks-static-cluster in us-east-2.
  - Reachability: kubectl auth can-i list pods -A returned yes, and the API
    server reports version v1.32.13-eks.
  Yes, and I only used read-only commands.
  Your two questions, in order:
  1. Yes, and the node group is ACTIVE with two nodes.
  2. No pod is pending.
✻ Worked for 27s · done 5:23 PM
────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
  do-agent-aws · ctx:5%
EOF
# Claude Code 2.1.296's approval menu, as test-agent-chat.sh check 20 captured it
cat > "${D}/prose/t22approval/screen.txt" << 'EOF'
● Bash(openssl rand -hex 4)
  ⎿  Waiting…

────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
 Generate 4 random bytes as hex
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 openssl rand -hex 4
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don’t ask again for: openssl rand *
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
EOF
# the same answer in a pane whose prompt holds a person's draft, so no empty prompt line sits below it
cat > "${D}/prose/t22prosedraft/screen.txt" << 'EOF'
  - Reachability: kubectl auth can-i list pods -A returned yes, and the API
    server reports version v1.32.13-eks.
  Yes, and I only used read-only commands.
✻ Worked for 27s · done 5:23 PM
────────────────────────────────────────────────────────────────────────
❯ thanks, now list the nodes
────────────────────────────────────────────────────────────────────────
  do-agent-aws · ctx:5%
EOF
SESSIONS="${SESSIONS} t22prose t22approval t22prosedraft"
for S in t22prose t22approval t22prosedraft; do
	tmux new-session -d -s "${S}" -x 100 -y 30 -c "${D}/prose/${S}" "cat screen.txt; sleep 600" || fail "could not start the planted pane ${S}"
done
# the prose pane has drawn once its empty prompt line shows: idle, decided by that line
for I in $(seq 1 20); do OUT=$("${FC}" t22prose); echo "${OUT}" | grep -q '"idle_prompt": true' && break; sleep 0.5; done
echo "${OUT}" | python3 -c 'import json, sys; v = json.load(sys.stdin); assert v["verdict"] == "idle" and v["why"] == "an empty prompt line", v' \
	|| fail "an idle pane whose answer says \"returned yes, and the API\" does not read idle - a sentence is not a menu option: ${OUT}"
# the real menu reads menu, decided by its last option line: the numbered option form is what the check reads there
for I in $(seq 1 20); do OUT=$("${FC}" t22approval); echo "${OUT}" | grep -q '"verdict": "menu"' && break; sleep 0.5; done
echo "${OUT}" | python3 -c 'import json, sys; v = json.load(sys.stdin); assert v["verdict"] == "menu" and v["why"].startswith("3. Yes, and switch to auto mode"), v' \
	|| fail "Claude Code's approval menu does not read menu on its numbered option line '3. Yes, and switch to auto mode': ${OUT}"
# the pane with the draft has drawn once its draft shows: its answer is no menu either
for I in $(seq 1 20); do tmux capture-pane -p -t "=t22prosedraft" 2>/dev/null | grep -q 'now list the nodes' && break; sleep 0.5; done
OUT=$("${FC}" t22prosedraft)
echo "${OUT}" | python3 -c 'import json, sys; v = json.load(sys.stdin); assert v["verdict"] != "menu" and not v["idle_prompt"], v' \
	|| fail "a pane whose prompt holds a person's draft reads its answer \"returned yes, and the API\" as a menu: ${OUT}"
# PLANTED CONTROL: a fleet check that counts a numbered option line with an empty prompt line below it reads the idle
# pane as a menu on its numbered item, so the idle verdict above is the prompt rule's
M8B=${D}/mutant-prompt
mkdir -p "${M8B}"
cp "${FC}" "${M8B}/fleet-check.sh"
python3 - "${M8B}/fleet-check.sh" << 'EOF' || fail "could not make the fleet check without the prompt rule"
import sys
p = sys.argv[1]
c = open(p).read()
old = "(OPTION.search(ls[i]) and not any(PROMPT.fullmatch(b) for b in ls[i + 1:]))"
assert c.count(old) == 1, "the prompt rule is not where the mutant expects it"
open(p, "w").write(c.replace(old, "OPTION.search(ls[i])"))
EOF
OUT=$("${M8B}/fleet-check.sh" t22prose)
echo "${OUT}" | python3 -c 'import json, sys; v = json.load(sys.stdin); assert v["verdict"] == "menu" and v["why"].startswith("1. Yes, and the node group"), v' \
	|| fail "PLANTED CONTROL: a fleet check without the prompt rule does not read the idle pane as a menu on its numbered item, so the idle verdict above proves nothing: ${OUT}"
# PLANTED CONTROL: a fleet check that takes "Yes, and" anywhere on a line, in any case, for a menu option - the pattern
# before 8b - reads the pane with the draft as a menu, so its verdict above is the numbered option form's
M3=${D}/mutant-prose
mkdir -p "${M3}"
cp "${FC}" "${M3}/fleet-check.sh"
python3 - "${M3}/fleet-check.sh" << 'EOF' || fail "could not make the fleet check that reads a sentence as a menu option"
import sys
p = sys.argv[1]
c = open(p).read()
old = r"^[\s│]*(?:❯\s*)?[0-9]+\.\s+(?:Yes, and|No, and tell)"
assert c.count(old) == 1, "the menu option pattern is not where the mutant expects it"
open(p, "w").write(c.replace(old, "(?i:Yes, and|No, and tell)"))
EOF
OUT=$("${M3}/fleet-check.sh" t22prosedraft)
echo "${OUT}" | grep -q '"verdict": "menu"' \
	|| fail "PLANTED CONTROL: a fleet check that takes \"yes, and\" in a sentence for a menu option does not read the pane with the draft as a menu, so its verdict above proves nothing: ${OUT}"
tmux kill-session -t "=t22prose" 2>/dev/null
tmux kill-session -t "=t22approval" 2>/dev/null
tmux kill-session -t "=t22prosedraft" 2>/dev/null
echo "ok 8b [menu-prose] - an idle pane whose answer says \"returned yes, and the API\", opens a line with \"Yes, and\" and has a numbered item \"1. Yes, and\" read idle, the same answer in a pane whose prompt holds a draft read no menu, Claude Code's approval menu read menu on its numbered option line, and a fleet check without the prompt rule and one that takes \"yes, and\" in a sentence for a menu option are caught"

# --- 9. the hub alone: with no spoke and no supervisor, the agent session carries its lineage, so the dashboard reads
#        it as the person's and never as ORPHANED ---
tmux kill-session -t "=${AGENT_TMUX_SESSION_NAME}" 2>/dev/null
OUT=$(CLAUDE_BIN=${D}/stay/claude AGENT_TMUX_SESSION=true AGENT_TMUX_CLAUDE=true "${AGENT_DIR}/tmux-session-start.sh" 2>&1) || fail "tmux-session-start.sh (the hub): ${OUT}"
HUB_TASK=$("${SPOKE}" entry "${AGENT_TMUX_SESSION_NAME}" task)
for KV in "@agent_parent=operator" "@agent_owner=do-agent-aws" "@agent_task=${HUB_TASK}"; do
	V=$(tmux show-options -t "=${AGENT_TMUX_SESSION_NAME}:" -v "${KV%%=*}" 2>/dev/null)
	[ "${V}" == "${KV#*=}" ] || fail "the hub's session option ${KV%%=*} is '${V}', not '${KV#*=}'"
done
ROW=""
for I in $(seq 1 20); do
	ROW=$(curl -s --max-time 5 http://127.0.0.1:${DASH_PORT}/api/fleet | python3 -c 'import json, sys
for r in json.load(sys.stdin).get("sessions") or []:
    if r.get("session") == sys.argv[1]:
        print(r.get("parent"), r.get("owner"), r.get("engagement"), sep="\t")' "${AGENT_TMUX_SESSION_NAME}" 2>/dev/null)
	[ -n "${ROW}" ] && break
	sleep 1
done
echo "${ROW}" | grep -qE "^operator"$'\t'"do-agent-aws"$'\t' || fail "the dashboard does not list the hub under operator: '${ROW}'"
echo "${ROW}" | grep -q "ORPHANED" && fail "the dashboard reads the hub alone as ORPHANED: '${ROW}'"
# PLANTED CONTROL: a session started the way main started the hub, with no lineage, does read ORPHANED
tmux new-session -d -s t22bare "sleep 600" || fail "could not start the bare control session"
SESSIONS="${SESSIONS} t22bare"
for I in $(seq 1 20); do
	BARE=$(curl -s --max-time 5 http://127.0.0.1:${DASH_PORT}/api/fleet | python3 -c 'import json, sys
for r in json.load(sys.stdin).get("sessions") or []:
    if r.get("session") == "t22bare":
        print(r.get("engagement"))' 2>/dev/null)
	[ -n "${BARE}" ] && break
	sleep 1
done
[ "${BARE}" == "ORPHANED" ] || fail "PLANTED CONTROL: a session without lineage does not read ORPHANED ('${BARE}'), so the check above proves nothing"
tmux kill-session -t "=t22bare"
echo "ok 9 - the hub alone carries @agent_parent operator, @agent_owner do-agent-aws and its registry task, and the dashboard lists it under operator, not ORPHANED; a session without lineage does read ORPHANED"

# --- 10. the documentation: the agent stack and how the agents talk, linked from the README and the Guide, served under
#         /guide/, and in step with the registry and the home page's North Star register ---
DOCS=""
for C in /docs "${BASE_DIR}/../docs" /do-agent-aws/docs; do
	[ -f "${C}/AGENT-STACK.md" ] && [ -f "${C}/INTER-AGENT-MESSAGING.md" ] && [ -f "${C}/user-guide.md" ] && DOCS=$(cd "${C}" && pwd) && break
done
[ -n "${DOCS}" ] || fail "docs/AGENT-STACK.md and docs/INTER-AGENT-MESSAGING.md are in neither the image (/docs) nor a checkout"
python3 - "${DOCS}/AGENT-STACK.md" "${SHIPPED_REGISTRY}" << 'EOF' || fail "docs/AGENT-STACK.md does not list every session of the registry with its flag and its shipped default"
import json, re, sys
doc = open(sys.argv[1]).read()
for e in json.load(open(sys.argv[2]))["sessions"]:
    n, flag = e["session_name"], e["flag"]
    default = "true" if e.get("enabled") else "false"
    rows = [l for l in doc.splitlines() if l.startswith("| `" + n + "` |")]
    assert len(rows) == 2, (n, len(rows))           # one row in each of the two tables
    assert "`%s=%s`" % (flag, default) in rows[0], (n, flag, default, rows[0][-160:])
EOF
REGISTER=""
for C in /agent/north-star.json "${BASE_DIR}/../docs/north-star.json" /do-agent-aws/docs/north-star.json; do [ -f "${C}" ] && REGISTER=${C} && break; done
[ -n "${REGISTER}" ] || fail "the North Star register is in neither the image (/agent/north-star.json) nor a checkout"
python3 - "${DOCS}/AGENT-STACK.md" "${REGISTER}" "${SHIPPED_REGISTRY}" << 'EOF' || fail "docs/AGENT-STACK.md and the North Star register name the agents or their North Stars differently"
import json, sys
doc = open(sys.argv[1]).read()
shipped = {e["session_name"] for e in json.load(open(sys.argv[3]))["sessions"]}
for a in json.load(open(sys.argv[2]))["agents"]:
    if a["agent"] not in shipped:
        continue   # scored before its session ships: test-north-star.sh check 9 holds it to NO and the change it lands with
    assert ("| `%s` |" % a["agent"]) in doc, a["agent"]
    assert a["north_star"] in doc, (a["agent"], a["north_star"][:60])
EOF
CHECKOUT=""
for C in "${BASE_DIR}/.." /do-agent-aws; do [ -f "${C}/README.md" ] && [ -f "${C}/docs/user-guide.md" ] && CHECKOUT=$(cd "${C}" && pwd) && break; done
if [ -n "${CHECKOUT}" ]; then
	for F in "${CHECKOUT}/README.md" "${CHECKOUT}/docs/user-guide.md"; do
		for P in AGENT-STACK.md INTER-AGENT-MESSAGING.md; do grep -qF "docs/${P}" "${F}" || fail "$(basename "${F}") does not name docs/${P}"; done
	done
	grep -qF '[docs/AGENT-STACK.md](docs/AGENT-STACK.md)' "${CHECKOUT}/README.md" && grep -qF '[docs/INTER-AGENT-MESSAGING.md](docs/INTER-AGENT-MESSAGING.md)' "${CHECKOUT}/README.md" \
		|| fail "the README does not link the two pages"
	grep -qF '](/guide/agent-stack/)' "${CHECKOUT}/docs/user-guide.md" && grep -qF '](/guide/messaging/)' "${CHECKOUT}/docs/user-guide.md" \
		|| fail "the Guide does not link the two pages where the home page serves them"
	DOC_NOTE="the README and the Guide link both"
else
	DOC_NOTE="(no checkout here: the README and Guide links are checked from one)"
fi
# served: home-render writes both pages under /guide/ from the shipped documents; a missing source renders a page that says so
GD=${D}/ui-docs
env ${HOME_ENV} UI_DIR=${GD} AGENT_STACK_MD=${DOCS}/AGENT-STACK.md MESSAGING_MD=${DOCS}/INTER-AGENT-MESSAGING.md USER_GUIDE_MD=${DOCS}/user-guide.md SPOKES_REGISTRY=${SHIPPED_REGISTRY} \
	"${AGENT_DIR}/home-render.sh" > "${D}/render-docs.log" 2>&1 || fail "home-render.sh (the documents): $(tail -3 "${D}/render-docs.log")"
grep -q '<h2[^>]*>1. The agents: what each one is</h2>' "${GD}/home/site/guide/agent-stack/index.html" || fail "the home page does not serve the agent stack at /guide/agent-stack/: $(head -c 300 "${GD}/home/site/guide/agent-stack/index.html" 2>&1)"
grep -q '<h2[^>]*>The record: the bus v1 journal</h2>' "${GD}/home/site/guide/messaging/index.html" || fail "the home page does not serve how the agents talk at /guide/messaging/"
grep -q 'href="/guide/agent-stack/"' "${GD}/home/site/guide/index.html" && grep -q 'href="/guide/messaging/"' "${GD}/home/site/guide/index.html" \
	|| fail "the served Guide does not link the two pages"
# the served Guide states the spokes' defaults as the registry ships them: the ones that run by default, the home page's
# turn-off line word for word, each off one with its flag to turn it on, and none of the old "every one is off" wording
cat > "${D}/guide-defaults.py" << 'EOF'
import html, json, re, sys
page, reg = sys.argv[1], sys.argv[2]
text = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", open(page, encoding="utf-8").read())))
spokes = [e for e in json.load(open(reg))["sessions"] if e.get("role") == "spoke"]
on = [e["session_name"] for e in spokes if e.get("enabled")]
words = {2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight"}
want = ["To turn one off, set SPOKE_<NAME>=false in .env.local, then ./stop.sh && ./run.sh."]
if len(on) in words:
    want.append("%s run by default: %s and %s." % (words[len(on)], ", ".join(on[:-1]), on[-1]))
else:
    print("the registry enables %d spokes; the Guide's sentence for that count is not written" % len(on))
for e in spokes:
    if not e.get("enabled"):
        want += ["%s is off by default" % e["session_name"], "%s=true in .env.local turns it on" % e["flag"]]
bad = ["the Guide lacks: " + w for w in want if w not in text]
bad += ["the Guide still says: " + s for s in ("Every one is off", "turn one on with its flag in .env") if s in text]
print("\n".join(bad))
sys.exit(1 if bad or len(on) not in words else 0)
EOF
python3 "${D}/guide-defaults.py" "${GD}/home/site/guide/index.html" "${SHIPPED_REGISTRY}" > "${D}/guide-defaults.out" 2>&1 \
	|| fail "the served Guide does not state the spokes' defaults (source: ${DOCS}/user-guide.md): $(head -4 "${D}/guide-defaults.out" | tr '\n' ';')"
# PLANTED CONTROL: without its source the page says the document is not in this image
env ${HOME_ENV} UI_DIR=${GD}-missing AGENT_STACK_MD=${D}/no-such.md MESSAGING_MD=${DOCS}/INTER-AGENT-MESSAGING.md SPOKES_REGISTRY=${SHIPPED_REGISTRY} \
	"${AGENT_DIR}/home-render.sh" > "${D}/render-docs-missing.log" 2>&1
grep -q "This document is not in this image" "${GD}-missing/home/site/guide/agent-stack/index.html" || fail "PLANTED CONTROL: a missing agent stack page does not say so"
# PLANTED CONTROL: a Guide with the old wording ("Every one is off; turn one on with its flag in .env") fails the defaults check
cat > "${D}/guide-stale.md" << 'EOF'
# Guide

## The agent stack
- **Spokes** are more Claude Code sessions, each keeping one tile's data current: `conversations`, `insights`,
  `clusters`, `sessions` and `loops`, and `example`, which proves the set-up without spending tokens. Every one is off;
  turn one on with its flag in `.env` (`SPOKE_EXAMPLE=true`, for example), then `./stop.sh && ./run.sh`.
EOF
env ${HOME_ENV} UI_DIR=${GD}-stale AGENT_STACK_MD=${DOCS}/AGENT-STACK.md MESSAGING_MD=${DOCS}/INTER-AGENT-MESSAGING.md USER_GUIDE_MD=${D}/guide-stale.md SPOKES_REGISTRY=${SHIPPED_REGISTRY} \
	"${AGENT_DIR}/home-render.sh" > "${D}/render-docs-stale.log" 2>&1 || fail "home-render.sh (the planted stale Guide): $(tail -3 "${D}/render-docs-stale.log")"
python3 "${D}/guide-defaults.py" "${GD}-stale/home/site/guide/index.html" "${SHIPPED_REGISTRY}" > "${D}/guide-defaults-stale.out" 2>&1 \
	&& fail "PLANTED CONTROL: a Guide that says every spoke is off passes the defaults check"
grep -q "the Guide still says: Every one is off" "${D}/guide-defaults-stale.out" && grep -q "the Guide lacks: To turn one off" "${D}/guide-defaults-stale.out" \
	|| fail "PLANTED CONTROL: the defaults check does not name the stale Guide's wording: $(head -4 "${D}/guide-defaults-stale.out" | tr '\n' ';')"
echo "ok 10 - docs/AGENT-STACK.md lists every session of the registry with its flag and default and the North Star register's agents as written, ${DOC_NOTE}, and the home page serves both at /guide/agent-stack/ and /guide/messaging/ (a missing source says so); the served Guide says which spokes run by default (from the registry), the home page's turn-off line and how to turn the example on (a Guide that says every one is off fails)"

# --- 10b. the spokes' own checks, and the registry's real paths ---
# every cycle the shipped registry names is an executable file installed under /agent/charters/<name>/, and no charter
# sends its session to ./loop.sh: the session reads its charter as /wd/<name>/CLAUDE.md, where no loop.sh is
python3 - "${SHIPPED_REGISTRY}" "${AGENT_DIR}" "${CHARTERS}" << 'EOF' || fail "a cycle path of the registry or a charter's loop path is wrong"
import json, os, re, sys
reg, agent_dir, charters = sys.argv[1:4]
bad = []
for e in json.load(open(reg))["sessions"]:
    n, cyc = e["session_name"], e.get("cycle")
    if e.get("role") != "spoke" or not cyc:
        continue
    if not cyc.startswith(f"/agent/charters/{n}/"):
        bad.append(f"{n}: its cycle {cyc} is not under /agent/charters/{n}/")
        continue
    local = os.path.join(agent_dir, cyc[len("/agent/"):])
    if not (os.path.isfile(local) and os.access(local, os.X_OK)):
        bad.append(f"{n}: its cycle {cyc} is not an executable file here ({local})")
for n in sorted(os.listdir(charters)):
    p = os.path.join(charters, n, "charter.md")
    if os.path.isfile(p):
        for m in re.finditer(r"`\./(loop|cycle)\.sh`", open(p).read()):
            bad.append(f"{n}: its charter runs `./{m.group(1)}.sh` in the working directory")
    # the supervisor runs every cycle at the registry's cadence_sec: no charter or loop keeps an interval of its own
    d = os.path.join(charters, n)
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        fp = os.path.join(d, f)
        if os.path.isfile(fp):
            for v in sorted(set(re.findall(r"\b[A-Z_]*SPOKE[A-Z_]*INTERVAL\b", open(fp, errors="replace").read()))):
                bad.append(f"{n}: {f} names an interval variable of its own, {v}; the supervisor runs each cycle at the registry's cadence_sec")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
EOF
CL=${D}/clusters-own
mkdir -p "${CL}/bin"
# the clusters loop's own --self-test (the refusal wrapper and the cache file stems)
OUT=$(CLUSTERS_SPOKE_WD=${CL}/selftest bash "${CHARTERS}/clusters/loop.sh" --self-test 2>&1)
RC=$?
{ [ ${RC} -eq 0 ] && ! echo "${OUT}" | grep -q '^FAIL'; } || fail "the clusters loop's --self-test fails (rc ${RC}): $(echo "${OUT}" | grep -E '^FAIL' | head -3)"
CL_PASS=$(echo "${OUT}" | grep -c '^PASS')
# a stub kubectl that knows one context named like an EKS cluster ARN, with one GPU node
cat > "${CL}/bin/kubectl" << 'EOF'
#!/bin/bash
echo "$*" >> "${STUB_KUBECTL_LOG:?}"
case " $* " in
	*" config get-contexts "*) echo 'arn:aws:eks:us-east-1:ACCOUNT:cluster/demo' ;;
	*" get nodes "*) echo '{"items": [{"metadata": {"name": "n1", "labels": {}}, "spec": {}, "status": {"allocatable": {"nvidia.com/gpu": "8"}, "capacity": {"nvidia.com/gpu": "8"}, "conditions": [{"type": "Ready", "status": "True"}]}}]}' ;;
	*" get pods "*) echo '{"items": []}' ;;
	*) echo '{}' ;;
esac
EOF
chmod +x "${CL}/bin/kubectl"
# one cycle against that context: it is read (not UNREACHABLE) and its cache files carry the safe stem
OUT=$(PATH="${CL}/bin:${PATH}" STUB_KUBECTL_LOG=${CL}/kubectl.log CLUSTERS_SPOKE_WD=${CL}/cycle bash "${CHARTERS}/clusters/loop.sh" 2>&1)
python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); c = s["contexts"]["arn:aws:eks:us-east-1:ACCOUNT:cluster/demo"]; assert c.get("reachable") is True, c' "${CL}/cycle/status.json" 2>/dev/null \
	|| fail "a context named like an EKS cluster ARN does not read reachable in one cycle: $(head -c 300 "${CL}/cycle/status.json" 2>/dev/null) ${OUT}"
compgen -G "${CL}/cycle/cache/nodes.arn_aws_eks_us-east-1_ACCOUNT_cluster_demo.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].json" > /dev/null \
	|| fail "the ARN-named context's cache file has no safe stem: $(ls "${CL}/cycle/cache/")"
# the refusal wrapper: kubectl auth reconcile (an RBAC write) is refused and never reaches kubectl; auth can-i does
WRAP=$(awk '/--self-test" \]; then/ {exit} {print}' "${CHARTERS}/clusters/loop.sh")
: > "${CL}/kubectl.log"
OUT=$(PATH="${CL}/bin:${PATH}" STUB_KUBECTL_LOG=${CL}/kubectl.log CLUSTERS_SPOKE_WD=${CL}/wrap bash -c "${WRAP}"$'\n''kubectl auth reconcile -f x.yaml; echo "rc=$?"; kubectl --context c1 auth can-i list nodes; echo "rc=$?"' 2>&1)
echo "${OUT}" | grep -q '^rc=2$' && grep -q 'REFUSED kubectl auth reconcile' "${CL}/wrap/refusals.log" 2>/dev/null \
	|| fail "the clusters wrapper does not refuse kubectl auth reconcile: ${OUT}"
grep -q 'auth reconcile' "${CL}/kubectl.log" && fail "kubectl auth reconcile reached kubectl through the wrapper"
grep -q 'auth can-i list nodes' "${CL}/kubectl.log" || fail "kubectl auth can-i did not reach kubectl through the wrapper: $(cat "${CL}/kubectl.log")"
# the insights loop's own --self-test (a planted correction banks one candidate, a duplicate none)
OUT=$(cd "${D}" && bash "${CHARTERS}/insights/loop.sh" --self-test 2>&1) || fail "the insights loop's --self-test fails: $(echo "${OUT}" | tail -3)"
echo "${OUT}" | grep -q '^self-test PASS' || fail "the insights loop's --self-test did not say PASS: $(echo "${OUT}" | tail -3)"
# the conversations loop's own --stub-test needs an engine with the stub Slack API override (its v0.2.0 and later; the
# spoke's ref and the image's /opt/comms, the harness installer's pin, are v0.1.0). It runs where COMMS_ENGINE_DIR has the override, and says so if not.
ENGINE=${COMMS_ENGINE_DIR:-/opt/comms}
if grep -rqs "COMMS_SLACK_API_BASE" "${ENGINE}/channels"; then
	OUT=$(cd "${D}" && CONVERSATIONS_SPOKE_WD=${D}/conversations-own COMMS_ENGINE_DIR=${ENGINE} bash "${CHARTERS}/conversations/loop.sh" --stub-test 2>&1) \
		|| fail "the conversations loop's --stub-test fails: $(echo "${OUT}" | tail -3)"
	CONV_NOTE="the conversations loop's --stub-test passes (${ENGINE})"
else
	CONV_NOTE="the conversations loop's --stub-test not run: the engine at ${ENGINE} has no stub Slack API override (it came with the engine's v0.2.0; the pin is v0.1.0)"
fi
echo "ok 10b [spokes-own-checks] - every cycle the registry names is installed under /agent/charters/<name>/, no charter runs ./loop.sh and none names an interval variable of its own; the clusters loop's --self-test (${CL_PASS} PASS), an EKS-ARN-named context read in one cycle with a safe cache stem, auth reconcile refused and auth can-i passed by its wrapper; the insights loop's --self-test passes; ${CONV_NOTE}"

# --- 11. nothing under /wd: in the test container it is the suite's throwaway, and a user's checkout once mounted ---
if [ "${TEST_CONTAINER}" == "true" ]; then
	wd_new() { find /wd -mindepth 1 2>/dev/null | sort | comm -13 "${D}/wd-before.txt" -; }
	NEW=$(wd_new)
	[ -z "${NEW}" ] || fail "this test wrote $(echo "${NEW}" | wc -l) entries under /wd: $(echo "${NEW}" | head -5 | tr '\n' ' ')"
	# PLANTED CONTROL: an entry written under /wd now is named
	touch /wd/.test22-planted || fail "PLANTED CONTROL: could not plant an entry under /wd"
	NEW=$(wd_new)
	rm -f /wd/.test22-planted
	[ "${NEW}" == "/wd/.test22-planted" ] || fail "PLANTED CONTROL: the entry planted under /wd is not the one new entry named: '${NEW}'"
	echo "ok 11 - nothing under /wd that was not there when the test started (control: an entry planted there is named)"
fi

echo "Test22 succeeded"
