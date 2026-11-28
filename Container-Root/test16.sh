#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the home page's promise: EVERY UI the harness lists as live answers through the
# single proxy port, out of the box. Where test9.sh proves the proxy contract route by route,
# this test takes the home page's OWN inventory as the input - it renders the page with the
# shipped defaults, reads the tiles back out of index.html (data-url for path routes, data-host
# for the *.localhost host routes - exactly what the page's probe script reads) and probes each
# one the way the browser does. A tile added to home-render.sh is covered without touching this
# test; a tile the page lists that nothing serves is a failure.
# Fully OFFLINE: everything binds 127.0.0.1 on test-local ports and state directories.
#
# Properties proven (each check FAILS if the property is removed):
#   1. all scripts involved parse (bash -n)
#   2. with the shipped defaults (every UI flag on) the rendered page lists every expected UI
#      as a LIVE tile - none is greyed "off" - and lists the Loop Deck as a greyed tile that
#      carries the reason it is not served here (not an "off - set ..." flag hint); every tile() call in
#      home-render.sh passes a status contract (empty or a /__tile/ location) as its 8th argument, and the
#      Memory tile's state note renders as its own <p id="memory-state"> (a note passed 8th would land in
#      the tile's data-contract attribute and never render)
#   3. with the whole stack started on test-local ports, every live tile answers 2xx/3xx THROUGH
#      the proxy port (path tiles at their path, host tiles via the Host header the browser
#      would send AND at the same-origin /__probe/<name> location the page's dot reads), there are
#      at least ten of them, and every live link opens in a new tab; the LogLearner server started
#      here indexes into LOGLEARNER_STATE/index.db - read from the RUNNING process, with no
#      LOGLEARNER_DB set by this test (a fixed default sent the test suite's sessions into the
#      user's /wd/loglearner/index.db)
#      the memory tile's note reads the seed's extraction state (/__seed-state, GET-only, 404 until
#      written) and the live bank stats through /memory-api/; a planted failed state is a FAILED row
#      and exit 1 in ui-status.sh
#      the session guard against this test's memory API: planted session records in a bank that stores
#      them as sent (chunks mode, no model); one pass rewrites the agent's claim as "The agent said: ...",
#      keeps the user's request and English records quoting German or listing hosts, invalidates the German record, the REF-ID marker and the repeat with their
#      reasons; all keep their verified flag, recall leaves the three out, the recall hook marks the rest
#      "not verified"
#      the LogLearner dashboard's Hindsight page links to the memory API under /memory-api on its own host
#      (loglearner-serve.sh's LOGLEARNER_HINDSIGHT_LINK_BASE; the dashboard's host route serves the memory API's
#      locations), never at the server's own address, and the created bank's link answers the API's graph through that
#      host, where a write is refused; a bank name carrying </body> comes through both hosts as JSON untouched (the
#      badge filter is text/html only) and the docs page carries the badge once with the swagger copy's rewrites
#   4. PLANTED CONTROLS: a tile whose upstream has died reads DOWN through the proxy - on the host
#      route and on its /__probe/ location (no false 2xx from nginx; the dot can go red); and with the
#      memory API stopped the memory UI's dot probe reads down although the control plane's own health
#      path keeps answering (the probe reads the API-backed /api/banks)
#   4b. PLANTED UPSTREAM: a stand-in on a host-routed port answers chosen Location values; through the
#      proxy a relative one and the upstream's own loopback address come back absolute on the tile's
#      host with the BROWSER's port (also a port other than the listen port, the published-elsewhere
#      case), while an external site, another tile, a protocol-relative //host and a loopback service
#      on another port pass through untouched (29 cases)
#   5. ui-stop.sh takes everything down: the home port answers nothing
#   6. the agent's REAL persisted hooks config and settings are untouched by the test-local runs;
#      under test.sh (TEST_CONTAINER=true) nothing was written under the throwaway /wd (6b)
#   7. the home listener answers loopback names only: a foreign Host gets 421 on the home page, the
#      terminal, headlamp, the memory API and a dot probe (it was 200 before - the DNS-rebinding route),
#      while localhost/127.0.0.1 answer and UI_HOME_HOSTNAMES renders into the allowlist; the dot
#      probes are GET-only (POST -> 403) and status-only (204, no body); PLANTED CONTROL: a regex,
#      wildcard, catch-all or malformed UI_HOME_HOSTNAMES entry is refused and left out
#   8. every backend behind the proxy listens on 127.0.0.1 only (nothing but the home port on all
#      interfaces), and the proxy admits only loopback, the default route's gateway (from the routing
#      table, never guessed from a subnet) and UI_HOME_ALLOW_FROM: a connection
#      from the container's own non-loopback address (a neighbour's position) gets 403, is admitted once
#      that address is listed (control), and refused again after the default re-render; junk and /0
#      entries never reach the config
# Uses test-local state directories (/tmp/tiles-smoke*); does not disturb live state under /wd.

D=/tmp/tiles-smoke
rm -rf "${D:?}"
mkdir -p ${D}

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"

# The agent's REAL persisted files this test must never change (ui-start.sh keeps the hooks' config on
# the API port it starts and repairs the settings): their checksums before and after the whole run
REAL_FILES="/home/agent/.hindsight/coding-agent.json ${CLAUDE_CONFIG_DIR:-/home/agent/.claude}/settings.json"
real_sums() { for F in ${REAL_FILES}; do [ -f "${F}" ] && md5sum "${F}"; done; }
REAL_BEFORE=$(real_sums)

export UI_DIR=${D}/ui
# the home proxy on every interface of the test container (nothing is published; it is what ./run.sh does),
# so check 8 can connect to it from the container's own NON-loopback address; the backends must bind
# 127.0.0.1 regardless (UI_BACKEND_LISTEN_HOST's default behind the proxy)
export UI_LISTEN_HOST=0.0.0.0
# every flag at its shipped default (on) - deliberately NOT exported as false anywhere here
export UI_HOME=true
export UI_HEADLAMP=true
export UI_HINDSIGHT=true
export UI_VIBE_KANBAN=true
export UI_TMUX=true
export UI_TMUX_WRITABLE=true
export UI_TMUX_AGENT=true
export UI_CLAUDE_MEM=true
export UI_LOGLEARNER=true
export COMMS_UI_ENABLED=true
# the real hooks config and settings are persisted agent state: ui-start.sh keeps coding-agent.json
# on the API port it starts and repairs settings.json, so a test-local run points both at copies
export HINDSIGHT_AGENT_CONF=${D}/coding-agent.json
export CLAUDE_SETTINGS=${D}/settings.json
# the LogLearner runtime's state (banks, ledgers, index) - test-local too, never /wd/loglearner
export LOGLEARNER_STATE=${D}/loglearner
export UI_PORT_HOME=18016
export UI_PORT_HEADLAMP=14467
export UI_PORT_HINDSIGHT_API=18889
export UI_PORT_HINDSIGHT_UI=19998
export UI_PORT_VIBE_KANBAN=18082
export UI_PORT_TMUX=17683
export UI_PORT_TMUX_AGENT=17339
export UI_PORT_CLAUDE_MEM=37716
export UI_PORT_LOGLEARNER=17777
export UI_PORT_CHAT=18094
export UI_PORT_LOOP=17790
# the Loop Deck's server too: ui-status.sh lists it, so this test's own server must be the one on the port it reads
export UI_PORT_LOOP_DECK=18091
export UI_PORT_KNOWLEDGE=17796
# the Files tile's server too (ui-status.sh lists it, check 3 reaches its route): its port, and its shared folder
# test-local - never the shipped /wd/files
export UI_PORT_FILES=18098
export FILES_DIR=${D}/files
export COMMS_UI_PORT=18503
export COMMS_UI_BASE_PATH=comms
export COMMS_UI_LISTEN_HOST=127.0.0.1
export COMMS_DIR=${D}/comms
export COMMS_DEMO_SEED=true
# test-local state for the UIs that would otherwise share the agent's: the hindsight cluster
# (HINDSIGHT_HOME, the way test.sh isolates its container), the claude-mem worker's data dir,
# the LogLearner index, the tmux-agent dashboard's own state, and a test-local tmux session
# for ttyd so the shared "agent" session never sees a test client
export HINDSIGHT_HOME=${HINDSIGHT_HOME:-/tmp/hindsight-test-home}
export CLAUDE_MEM_DATA_DIR=${D}/claude-mem
# LOGLEARNER_DB is deliberately NOT set: ui-start.sh must derive it from LOGLEARNER_STATE above (check 3 reads the
# running server's path) - a fixed default sent the test suite's sessions into the user's /wd/loglearner/index.db
export TMUX_AGENT_HOME=${D}/tmux-agent-state
export AGENT_TMUX_SESSION_NAME=tiles-smoke
# the docker spoke's build substrate rows (ui-status.sh) read sidecar containers this test has none of: off, so
# check 3's all-UP status counts only the UIs this test starts
export SPOKE_DOCKER=false
# the Loop Deck adapter writes the Deck's inputs at every UI start (/wd/loop-deck by default): test-local too, so 6b
# finds the throwaway /wd empty
export LOOP_DECK_DATA_DIR=${D}/loop-deck
# the supervisor and the spokes are not part of the stack this test starts (test22 covers them): off, so ui-status.sh's
# rows for them read OFF and check 3's exit code is the UIs' alone. Under ./test.sh the spokes' flags are off anyway
# (TEST_RUN_OPTS); in a container it did not start - a plain docker run of the image, a sandbox - they ship on, and a
# supervisor that does not run read DOWN and failed check 3 with every UI up
export SUPERVISOR=false

cleanup()
{
	# the banks check 3 creates in the test-local memory API go with the test, on every path (LL_BANK_CLEANUP and
	# GUARD_BANK_CLEANUP are set right after the creation and cleared once the check deleted its bank itself)
	[ -n "${LL_BANK_CLEANUP:-}" ] && curl -s -o /dev/null --max-time 10 -X DELETE "http://127.0.0.1:${UI_PORT_HINDSIGHT_API}/v1/default/banks/test16-links" 2>/dev/null
	[ -n "${GUARD_BANK_CLEANUP:-}" ] && curl -s -o /dev/null --max-time 10 -X DELETE "http://127.0.0.1:${UI_PORT_HINDSIGHT_API}/v1/default/banks/coding-agent%3A%3At16-session-guard" 2>/dev/null
	"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
	COMMS_DIR=${D}/comms "${AGENT_DIR}/comms-ui-stop.sh" > /dev/null 2>&1
	tmux kill-session -t tiles-smoke 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail()
{
	echo "Test16 FAILED: $1"
	exit 1
}

# --- 1. syntax ---
for S in "${AGENT_DIR}/home-render.sh" "${AGENT_DIR}/ui-start.sh" "${AGENT_DIR}/ui-status.sh" \
         "${AGENT_DIR}/ui-stop.sh" "${AGENT_DIR}/loglearner-serve.sh" "${AGENT_DIR}/comms-ui-start.sh"; do
	bash -n "${S}" || fail "bash -n ${S}"
done
echo "ok 1 - syntax"

# --- preflight: the proxy and the UIs this image ships ---
if ! command -v nginx > /dev/null || ! command -v ttyd > /dev/null || ! command -v tmux > /dev/null; then
	echo "Test16 skipped: nginx/ttyd/tmux not installed (run setup/install-nginx.sh and setup/install-ttyd.sh)"
	exit 0
fi

# --- 1b. under test.sh the container works on the image's baked agent state, never the user's: no agent-state
#         mount, a throwaway /wd (tmpfs) with no LogLearner index put there by an earlier test, test-local state ---
if [ "${TEST_CONTAINER}" == "true" ]; then
	for M in /home/agent/.claude /home/agent/.claude-mem /home/agent/.hindsight /home/hindsight/.pg0 /home/agent/.local/share/vibe-kanban; do
		mountpoint -q "${M}" 2>/dev/null && fail "the test container mounts the agent's persisted state at ${M} - test sessions, memories and hook writes would land in the user's own agent state (a -tmp-loop-smoke project showed up in a fresh deploy's LogLearner)"
	done
	[ "${LOGLEARNER_STATE:-/wd/loglearner}" != "/wd/loglearner" ] || fail "the test container's LOGLEARNER_STATE is the shared /wd/loglearner - a test's indexer would write the user's dashboard index"
	[ "${FILES_DIR:-/wd/files}" != "/wd/files" ] || fail "the test container's FILES_DIR is the shared /wd/files - a test's ui-start.sh would create the user's shared folder under /wd (TEST_RUN_OPTS must send it to /tmp)"
	# the throwaway /wd: test.sh gives the test container a tmpfs in place of the user's wd/ (TEST_VOL_MAP), so a
	# write under /wd by any test outlives nothing; and no test before this one may have put a LogLearner index
	# there (test9 starts the UIs with the shipped index default - the writer of the leaked sessions)
	[ "$(stat -f -c %T /wd 2>/dev/null)" == "tmpfs" ] || fail "the test container's /wd is not a throwaway tmpfs ($(stat -f -c %T /wd 2>/dev/null)) - a test writing under /wd would write the user's checkout"
	[ ! -e /wd/loglearner/index.db ] || fail "a LogLearner index exists at /wd/loglearner/index.db in the test container - a test's ui-start.sh indexed into the shipped default path instead of its LOGLEARNER_STATE (the suite's sessions would show in the user's dashboard)"
	echo "ok 1b - the test container carries no agent-state mount (${TEST_CONTAINER}), its /wd is a throwaway tmpfs with no LogLearner index, and its LogLearner state is ${LOGLEARNER_STATE}"
else
	echo "ok 1b - (not under test.sh: TEST_CONTAINER unset, mount isolation not asserted)"
fi

# --- 2. the inventory the page promises with the shipped defaults ---
"${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh (defaults)"
PAGE=${UI_DIR}/home/site/index.html
# tile()'s arguments line up: the 8th of every call is the status contract (empty, or a /__tile/ location) and raw html
# for the tile goes in the 9th. A note in the 8th lands in the tile's data-contract attribute, so it never renders and
# the page's script reads it as a contract URL. Static, over every tile() call in home-render.sh
python3 - "${AGENT_DIR}/home-render.sh" > ${D}/tile-args.out 2>&1 << 'EOF' || fail "a tile() call passes something other than a contract as its 8th argument: $(cat ${D}/tile-args.out)"
import shlex, sys
calls, bad = 0, []
for n, line in enumerate(open(sys.argv[1]), 1):
    i = line.find("$(tile ")
    if i < 0:
        continue
    args = shlex.split(line[i + 7:line.rfind(')"')])
    calls += 1
    if len(args) >= 8 and args[7] and not args[7].startswith("/__tile/"):
        bad.append("line %d (%s): 8th argument %r" % (n, args[1], args[7][:60]))
if calls < 10:
    sys.exit("only %d tile() calls found in %s" % (calls, sys.argv[1]))
print("%d tile() calls" % calls)
sys.exit("; ".join(bad) if bad else 0)
EOF
# ... and the Memory tile's state note renders as an element: exactly one <p class="memory" id="memory-state">, inside the
# Memory tile, and no attribute anywhere on the page holds markup
python3 - "${PAGE}" > ${D}/memory-state.out 2>&1 << 'EOF' || fail "the Memory tile's state note does not render as its own element: $(cat ${D}/memory-state.out)"
import sys
from html.parser import HTMLParser
class P(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack, self.hits, self.markup = [], [], []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.markup += [(tag, k) for k, v in attrs if v and "<" in v]
        if a.get("id") == "memory-state":
            tile = next((s for s in reversed(self.stack) if s[0] == "li"), None)
            self.hits.append((tag, a.get("class", ""), tile))
        if tag not in ("br", "img", "input", "meta", "link", "hr"):
            self.stack.append((tag, a.get("class", "")))
    def handle_endtag(self, tag):
        while self.stack and self.stack.pop()[0] != tag:
            pass
p = P()
p.feed(open(sys.argv[1]).read())
if p.markup:
    sys.exit("markup inside an attribute: %s" % p.markup[:3])
if len(p.hits) != 1:
    sys.exit("%d elements with id=memory-state" % len(p.hits))
tag, cls, tile = p.hits[0]
if tag != "p" or "memory" not in cls.split() or not tile or "tile" not in tile[1].split():
    sys.exit("id=memory-state is <%s class=%r> in %r, not a <p class=memory> in a tile" % (tag, cls, tile))
print("one <p class=memory id=memory-state> in a tile")
EOF
grep -oE '<li class="tile" [^>]*><span class="dot"></span><a [^>]*>Memory</a>.*id="memory-state"' "${PAGE}" > /dev/null \
	|| fail "the memory-state note is not in the Memory tile"
echo "ok 2a - every tile() call's 8th argument is a contract ($(cat ${D}/tile-args.out)); the Memory tile's state note renders as its own element in the Memory tile"
# title -> the live tiles are <a ...>title</a>, the greyed ones <span class="title">title</span>
live_titles()   { grep -oE '<li class="tile" [^>]*><span class="dot"></span><a href="[^"]*"[^>]*>[^<]*' "${PAGE}" | sed -E 's/.*>//'; }
greyed_titles() { grep -oE '<li class="tile off[^"]*"><span class="dot"></span><span class="title">[^<]*' "${PAGE}" | sed -E 's/.*">//'; }
for T in "Guide" "Headlamp" "Memory" "Goals board" "Agent workspaces" "Conversations" "tmux terminal" \
         "tmux cheatsheet" "tmux-agent dashboard" "Session memory" "Session insights" "Agent loop" "Files"; do
	live_titles | grep -qxF "${T}" || fail "with the shipped defaults the home page does not list '${T}' as a live tile (live: $(live_titles | tr '\n' ','))"
done
# the Plane board is opt-in (UI_PLANE=false by default, docs/manual/boards.md "Plane board"): off, the page has no Plane tile and no
# Board tile at all (the Board reads that board), live or greyed, and names no flag for them. On, it runs as sidecar
# containers that only ./run.sh starts (TO=docker): in a container without them (PLANE_URL unset - this one, compose,
# kubernetes) its tile is greyed with that reason, never with a .env flag, and so is the Board's
PLANE_OFF='^$'
if [ "${UI_PLANE:-false}" != "true" ]; then
	for T in 'Project board \(Plane\)' 'Board'; do
		grep -qE '<li class="tile[^>]*><span class="dot"></span>(<span class="title">|<a [^>]*>)'"${T}<" "${PAGE}" && fail "with the Plane board off (UI_PLANE=${UI_PLANE:-unset}) the home page renders a tile titled ${T//\\/}"
	done
	grep -q 'UI_PLANE' "${PAGE}" && fail "with the Plane board off the home page names the UI_PLANE flag"
elif [ -z "${PLANE_URL}" ]; then
	PLANE_OFF='^(Project board \(Plane\)|Board)$'   # and the Board, which reads that board
fi
greyed_titles | grep -vE "${PLANE_OFF}" | grep -q . && fail "with the shipped defaults a UI is greyed out: $(greyed_titles | grep -vE "${PLANE_OFF}" | tr '\n' ',')"
if [ "${UI_PLANE:-false}" == "true" ] && [ -z "${PLANE_URL}" ]; then
	grep -oE 'Project board \(Plane\)</span>.{0,300}' "${PAGE}" | grep -qF 'not on this target - ./run.sh with TO=docker runs Plane as sidecar containers' \
		|| fail "without PLANE_URL the Plane tile does not say the board is not on this target"
	grep -oE 'Project board \(Plane\)</span>.{0,300}' "${PAGE}" | grep -q 'off - set' && fail "the Plane tile pretends a .env flag would turn it on here"
	grep -oE '>Board</span>.{0,300}' "${PAGE}" | grep -qF 'not on this target - ./run.sh with TO=docker runs Plane as sidecar containers, which the Board reads' \
		|| fail "without PLANE_URL the Board tile does not say the Plane board is not on this target"
	grep -oE '>Board</span>.{0,300}' "${PAGE}" | grep -q 'off - set' && fail "the Board tile pretends a .env flag would turn it on here"
fi
# the Loop Deck is served from the image (/opt/loop-deck, harness mode): a LIVE tile on the loop-deck host, probed like the
# other UIs, whose note says where the Deck comes from and that its actions are off; no external tile without LOOP_DECK_URL
live_titles | grep -qxF "Loop Deck" || fail "the Loop Deck is not a live tile with the shipped defaults: $(greyed_titles | tr '\n' ',')"
grep -q 'data-host="loop-deck" data-probe="/__probe/loop-deck"' "${PAGE}" || fail "the Loop Deck tile is not probed on the loop-deck host"
grep -qF "the Deck shipped in the image (/opt/loop-deck, harness mode) over this harness's own loops, rendered from /wd/loop-deck after every fire; actions are off (every POST /act answers 403)" "${PAGE}" \
	|| fail "the Loop Deck tile's note does not say where the Deck comes from and that its actions are off"
grep -q "Fleet Loop Deck" "${PAGE}" && fail "a Fleet Loop Deck tile rendered with LOOP_DECK_URL unset"
greyed_titles | grep -qxF "Loop Deck" && fail "the Loop Deck tile is greyed although UI_LOOP_DECK defaults to true"
grep -E '<li class="tile" [^>]*>.*>Headlamp</a>' "${PAGE}" | grep -qF 'aws eks update-kubeconfig --name &lt;cluster&gt;' \
	|| fail "the Headlamp tile does not say how to add a cluster (it opens on 'No clusters found' without one)"
# a link inside a tile's note must be clickable: with the harness stylesheet's stretched title link the rule below is what
# keeps it reachable (headless Chromium: elementFromPoint at the Memory tile's API-docs link returned the title anchor without it)
grep -qF 'li.tile p.note a { position: relative; z-index: 1; }' "${PAGE}" || fail "the page lacks the rule that lifts a note's link above the title's stretched link"
[ "$(live_titles | head -1)" == "Guide" ] || fail "the Guide is not the first tile (first: $(live_titles | head -1))"
# the home page by the user's task: a "Start here" strip with one primary action (the Goals board signed in when a board
# is configured, the Guide's goals section without one), then the groups Get started (the Guide alone, first), Run and
# review, Memory and learning, Administration in that order, each tile under its group by its NAME and Run and review in
# the decided order, and last Agents, a tile per spoke agent of the registry (docs/manual/agents.md "Spoke agents"; test22 checks
# those tiles); the shipped page has no Other group. PLANTED: a tile no group names lands under Other; a copy of
# home-render.sh without the strip fails the strip check
grep -q '<h2 id="start-h">Start here</h2>' "${PAGE}" || fail "no Start here strip"
strip() { sed -n '/<section class="start"/,/<\/section>/p' "$1"; }   # the strip spans several lines
strip "${PAGE}" | grep -q 'class="primary"' || fail "the Start here strip has no primary action: $(strip "${PAGE}" | tr '\n' ' ' | cut -c1-300)"
if [ -n "${KANBAN_BOARD_URL}" ]; then
	strip "${PAGE}" | grep -qF 'class="primary" data-host="kanban" data-path="/__harness/sign-in"' && strip "${PAGE}" | grep -qF '>Open the Goals board</a>' \
		|| fail "with a board the strip's action is not the Goals board signed in: $(strip "${PAGE}" | grep -oE 'class="primary"[^>]*>[^<]*')"
else
	strip "${PAGE}" | grep -qF 'href="/guide/#goals-and-the-goals-board-vibe-kanban">How to add a goal</a>' \
		|| fail "without a board the strip's action is not the Guide's goals section: $(strip "${PAGE}" | grep -oE 'class="primary"[^>]*>[^<]*')"
fi
# the strip's promise follows the loop's autostart gate: with the loop on it names the next fire, off it says what turns the
# loop on; the shipped page follows the gate as this environment decides it, and PLANTED renders with AUTONOMY_LOOP=true and
# =false each carry their sentence and not the other's
ON='The autonomy loop picks it up at its next fire and writes the result on the goal'"'"'s card.'
OFF='Enable the autonomy loop (<code>AUTONOMY_LOOP=true</code> in .env, or <code>/agent/loop-start.sh</code> in the terminal) and it picks the goal up at its next fire; until then the goal waits.'
GATE=$("${AGENT_DIR}/slack-gates.sh" loop 2>/dev/null); WANT="${OFF}"; [ "${GATE}" == "on" ] && WANT="${ON}"
strip "${PAGE}" | grep -qF "${WANT}" || fail "the strip's loop sentence does not follow the loop gate (${GATE:-off}): $(strip "${PAGE}" | grep -oE 'Give the agent a goal.{0,260}' | tr '\n' ' ')"
AUTONOMY_LOOP=true UI_DIR=${D}/ui-loop-on "${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh with AUTONOMY_LOOP=true"
strip ${D}/ui-loop-on/home/site/index.html | grep -qF "${ON}" || fail "PLANTED: with AUTONOMY_LOOP=true the strip does not promise the next fire"
strip ${D}/ui-loop-on/home/site/index.html | grep -qF 'Enable the autonomy loop' && fail "PLANTED: with AUTONOMY_LOOP=true the strip still says to enable the loop"
AUTONOMY_LOOP=false UI_DIR=${D}/ui-loop-off "${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh with AUTONOMY_LOOP=false"
strip ${D}/ui-loop-off/home/site/index.html | grep -qF "${OFF}" || fail "PLANTED: with AUTONOMY_LOOP=false the strip does not say what turns the loop on"
strip ${D}/ui-loop-off/home/site/index.html | grep -qF 'picks it up at its next fire and writes' && fail "PLANTED: with AUTONOMY_LOOP=false the strip still promises the next fire"
group_order() { grep -oE '<h2 class="group">[^<]*</h2>' "$1" | sed -E 's/<[^>]*>//g' | tr '\n' '|'; }
[ "$(group_order "${PAGE}")" == "Get started|Run and review|Memory and learning|Administration|Agents|" ] \
	|| fail "the groups are not Get started, Run and review, Memory and learning, Administration, Agents in that order (and no Other with the shipped tiles): $(group_order "${PAGE}")"
# the titles under one group heading, live and greyed, in page order (tile openings only - a link inside a tile's note is not a title)
group_titles() { awk -v g="<h2 class=\"group\">$2</h2>" 'index($0, g) {on=1; next} /<h2 class="group">/ {on=0} on' "$1" \
	| grep -oE '^<li class="tile" [^>]*><span class="dot"></span><a href="[^"]*"[^>]*>[^<]*|^<li class="tile external"><span class="dot external"></span><a href="[^"]*"[^>]*>[^<]*|^<li class="tile off[^"]*"><span class="dot"></span><span class="title">[^<]*' | sed -E 's/.*>//'; }
[ "$(group_titles "${PAGE}" 'Get started' | tr '\n' '|')" == "Guide|" ] || fail "Get started is not the Guide alone: $(group_titles "${PAGE}" 'Get started' | tr '\n' ',')"
# the Project board (Plane) and the Board are in the group only with the Plane board on (UI_PLANE=true): off by default, so absent
RUN_TILES="Agent loop|Agent chat|Files|Goals board|Agent workspaces|Conversations|Loop Deck|"
[ "${UI_PLANE:-false}" == "true" ] && RUN_TILES="Agent loop|Agent chat|Files|Goals board|Agent workspaces|Project board (Plane)|Board|Conversations|Loop Deck|"
[ "$(group_titles "${PAGE}" 'Run and review' | tr '\n' '|')" == "${RUN_TILES}" ] \
	|| fail "Run and review is not ${RUN_TILES//|/, } in that order (UI_PLANE=${UI_PLANE:-unset}; the Plane tiles only with UI_PLANE=true): $(group_titles "${PAGE}" 'Run and review' | tr '\n' ',')"
for P in "Memory and learning:Memory" "Memory and learning:Session memory" "Memory and learning:Learned rules" "Memory and learning:Session insights" \
         "Administration:Headlamp" "Administration:tmux terminal" "Administration:tmux cheatsheet" "Administration:tmux-agent dashboard"; do
	group_titles "${PAGE}" "${P%%:*}" | grep -qxF "${P#*:}" || fail "'${P#*:}' is not under '${P%%:*}' (there: $(group_titles "${PAGE}" "${P%%:*}" | tr '\n' ','))"
done
[ "$(group_titles "${PAGE}" 'Memory and learning' | wc -l)" == "4" ] && [ "$(group_titles "${PAGE}" 'Administration' | wc -l)" == "4" ] \
	|| fail "a group carries a tile the decision does not place there: memory=$(group_titles "${PAGE}" 'Memory and learning' | tr '\n' ',') admin=$(group_titles "${PAGE}" 'Administration' | tr '\n' ',')"
grep -q "querySelectorAll('li.tile\[data-host\], .start a\[data-host\]')" "${PAGE}" || fail "the strip's board action would not be completed to the board's host like the tiles"
mkdir -p ${D}/mutant
python3 - "${AGENT_DIR}/home-render.sh" ${D}/mutant/home-render-planted-tile.sh ${D}/mutant/home-render-no-strip.sh << 'PY'
import re, sys
s = open(sys.argv[1]).read()
anchor = 'TILES+="$(tile "${UI_HEADLAMP}" "Headlamp"'
assert s.count(anchor) == 1, "the Headlamp tile line is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, 'TILES+="$(tile true "Planted tile" "a tile no group names" "/planted/" "" "")"$\'\\n\'\n' + anchor))
t = re.sub(r'<section class="start" aria-labelledby="start-h">.*?</section>\n', "", s, count=1, flags=re.S)
assert t != s, "the strip is not where the control expects it"
open(sys.argv[3], "w").write(t)
PY
UI_DIR=${D}/ui-planted bash ${D}/mutant/home-render-planted-tile.sh > /dev/null 2>&1 || fail "the planted-tile home-render.sh did not render"
PP=${D}/ui-planted/home/site/index.html
[ "$(group_order "${PP}")" == "Get started|Run and review|Memory and learning|Administration|Other|" ] || fail "PLANTED CONTROL: a tile no group names did not open an Other group after the four: $(group_order "${PP}")"
[ "$(group_titles "${PP}" 'Other' | tr '\n' '|')" == "Planted tile|" ] || fail "PLANTED CONTROL: Other does not hold the planted tile alone: $(group_titles "${PP}" 'Other' | tr '\n' ',')"
[ "$(group_titles "${PP}" 'Administration' | wc -l)" == "4" ] || fail "PLANTED CONTROL: the planted tile leaked into Administration"
UI_DIR=${D}/ui-nostrip bash ${D}/mutant/home-render-no-strip.sh > /dev/null 2>&1 || fail "the strip-less home-render.sh did not render"
grep -q '<h2 id="start-h">Start here</h2>' ${D}/ui-nostrip/home/site/index.html && fail "PLANTED CONTROL: a page rendered without the strip still passes the strip check"
# the rendered page carries no denylisted name: the seed's privacy scan in tree mode over the served HTML. The rendered
# README's Contributing section names the project's contributors on purpose, so the scan reads a copy of the site
# without that one section (and fails if the copy lost anything else); PLANTED: a copy of the page with such a name
# written into a tile note fails it (the name is assembled at run time - this test must not spell it)
SCAN=/seed/scan.py; [ -f "${SCAN}" ] || SCAN="${BASE_DIR%/}/seed/scan.py"
# site_copy <site dir> <copy dir>: the copy the privacy scan reads, without the rendered README page's Contributing section
site_copy()
{
	rm -rf "${2:?}"; cp -r "$1" "$2"
	[ -f "$2/guide/readme/index.html" ] || return 0
	python3 - "$2/guide/readme/index.html" << 'PY' || fail "the rendered README copy for the scan ($2): no Contributing section, or the copy lost more than that section"
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
n = len(re.findall(r"<h2[ >]", s))
m = re.search(r'<h2 id="contributing">.*?(?=<h2[ >])', s, re.S)
if not m:
    sys.exit("no Contributing section before another h2")
t = s[:m.start()] + s[m.end():]
if len(re.findall(r"<h2[ >]", t)) != n - 1 or 'id="license-and-third-party-software"' not in t:
    sys.exit("the copy lost more than the Contributing section")
open(p, "w", encoding="utf-8").write(t)
PY
}
site_copy "${UI_DIR}/home/site" "${D}/site-scan"
python3 "${SCAN}" --tree "${D}/site-scan" > ${D}/scan-page.out 2>&1 || { cat ${D}/scan-page.out | head -5; fail "the rendered home page carries a denylisted name or secret: $(tail -1 ${D}/scan-page.out)"; }
PN=$(printf 'fleet-%s-engineering' loop)
sed "s#LOOP_DECK_URL links a fleet Deck instead#it renders ${PN}'s registry#" "${PAGE}" > ${D}/page-planted.html
python3 "${SCAN}" --tree ${D}/page-planted.html > ${D}/scan-page-planted.out 2>&1
[ $? -eq 1 ] || fail "PLANTED CONTROL BROKEN: the page scan passed a tile note naming a private repository: $(cat ${D}/scan-page-planted.out)"
grep -q "denylist-name" ${D}/scan-page-planted.out || fail "the planted page's finding is not a denylist-name: $(cat ${D}/scan-page-planted.out)"
echo "ok 2 - shipped defaults: $(live_titles | wc -l) live tiles, none greyed; the Loop Deck live, probed on its own host, its note naming the shipped Deck with its actions off; the Headlamp tile says how to add a cluster; a note's link is lifted above the title link; the Guide first; the Start here strip with its action and its loop sentence following the autostart gate (planted on and off), then Get started (the Guide alone), Run and review in the decided order, Memory and learning, Administration with their tiles and no Other; planted: a tile no group names lands under Other alone, a page without the strip fails; the rendered page passes the privacy scan ($(tail -1 ${D}/scan-page.out | cut -d'(' -f1)) and a planted private repository name in a tile note fails it"

# --- 2c. the Fleet Loop Deck tile: LOOP_DECK_URL set -> the served Loop Deck tile gives way to an external tile linking exactly
#         that URL in a new tab with no opener and no referrer and carrying no probe (the page probes only its own routes);
#         the page with it passes the privacy scan; it sits in Run and review, last, where the served tile was, and the
#         page opens no Other group for it; PLANTED: a value with HTML markup, another scheme, nginx syntax or no
#         scheme is refused with a WARNING and the served tile stays; the default page (check 2) has no external tile ---
DECK_URL='http://localhost:8091/#/topology'
DPAGE=${D}/ui-deck/home/site/index.html
LOOP_DECK_URL="${DECK_URL}" UI_DIR=${D}/ui-deck "${AGENT_DIR}/home-render.sh" > ${D}/render-deck.out 2>&1 || fail "home-render.sh with LOOP_DECK_URL: $(cat ${D}/render-deck.out)"
grep -q "WARNING - LOOP_DECK_URL" ${D}/render-deck.out && fail "a plain LOOP_DECK_URL was refused: $(grep 'LOOP_DECK_URL' ${D}/render-deck.out)"
DT=$(grep -oE '<li class="tile external"><span class="dot external"></span><a href="[^"]*" target="_blank" rel="noopener noreferrer">Fleet Loop Deck</a>' "${DPAGE}")
[ -n "${DT}" ] || fail "no external Fleet Loop Deck tile with LOOP_DECK_URL set: $(grep -oE 'Fleet Loop Deck.{0,120}' "${DPAGE}" | head -1)"
echo "${DT}" | grep -qF "href=\"${DECK_URL}\"" || fail "the Fleet Loop Deck tile does not link LOOP_DECK_URL as given: ${DT}"
grep -oE '<li class="tile external">[^<]*<span[^>]*></span><a [^>]*>' "${DPAGE}" | grep -qE 'data-(url|probe|host)=' && fail "the external tile carries a probe attribute (the page would probe a foreign site)"
grep -q 'data-host="loop-deck"' "${DPAGE}" && fail "the served Loop Deck tile is still on the page next to the external one"
[ "$(grep -c 'Fleet Loop Deck' "${DPAGE}")" == "1" ] || fail "the Fleet Loop Deck tile is on the page $(grep -c 'Fleet Loop Deck' "${DPAGE}") times"
site_copy "${D}/ui-deck/home/site" "${D}/site-scan-deck"
python3 "${SCAN}" --tree "${D}/site-scan-deck" > ${D}/scan-deck.out 2>&1 || fail "the page with the Fleet Loop Deck tile fails the privacy scan: $(tail -1 ${D}/scan-deck.out)"
# its group: Run and review (home-render.sh's GROUP_RUN names it), last, where the served Loop Deck tile was - not an Other
# group of its own
[ "$(group_order "${DPAGE}")" == "Get started|Run and review|Memory and learning|Administration|Agents|" ] \
	|| fail "with LOOP_DECK_URL set the groups are not Get started, Run and review, Memory and learning, Administration, Agents (no Other): $(group_order "${DPAGE}")"
[ "$(group_titles "${DPAGE}" 'Run and review' | tail -1)" == "Fleet Loop Deck" ] \
	|| fail "the Fleet Loop Deck tile is not the last of Run and review: $(group_titles "${DPAGE}" 'Run and review' | tr '\n' ',')"
for BAD in 'http://localhost:8091/"><script>x</script>' 'javascript:alert(1)' 'http://localhost:8091/; }' 'localhost:8091'; do
	LOOP_DECK_URL="${BAD}" UI_DIR=${D}/ui-deck "${AGENT_DIR}/home-render.sh" > ${D}/render-deck-bad.out 2>&1 || fail "home-render.sh failed on LOOP_DECK_URL='${BAD}' (it must warn and keep the served tile): $(cat ${D}/render-deck-bad.out)"
	grep -q "WARNING - LOOP_DECK_URL is not a plain http(s)://host\[:port\]\[/path\] URL; no Fleet Loop Deck tile" ${D}/render-deck-bad.out || fail "no WARNING for LOOP_DECK_URL='${BAD}': $(cat ${D}/render-deck-bad.out)"
	grep -q 'Fleet Loop Deck' "${DPAGE}" && fail "a Fleet Loop Deck tile rendered from LOOP_DECK_URL='${BAD}'"
	grep -q 'data-host="loop-deck"' "${DPAGE}" || fail "the served Loop Deck tile is gone after a refused LOOP_DECK_URL='${BAD}'"
	grep -qF 'script>x' "${DPAGE}" && fail "LOOP_DECK_URL's markup reached the page"
done
echo "ok 2c - Fleet Loop Deck: LOOP_DECK_URL renders an external tile in place of the served one, linking the URL as given in a new tab (noopener noreferrer) with no probe, once, and the page passes the privacy scan; four planted values (markup, another scheme, nginx syntax, no scheme) are refused with a WARNING and keep the served tile"

# --- 2a. the header's tunnel hint names the port the harness is published on (PORT_EXTERNAL_HOME, which run.sh, the
#         compose and the kubernetes templates pass in); the default page says 8000; PLANTED: a render with 24100 says 24100
#         in both commands and 8000 nowhere, a render without the variable falls back to 8000 ---
grep -qF 'ssh -L 8000:localhost:8000 (docker) or kubectl port-forward svc/do-agent-aws 8000:8000 (kubernetes)' "${PAGE}" || fail "the default page's hint does not name port 8000: $(grep -oE 'reach it with.{0,120}' "${PAGE}" | tr '\n' ' ')"
PORT_EXTERNAL_HOME=24100 UI_DIR=${D}/ui-port "${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh with PORT_EXTERNAL_HOME=24100"
grep -qF 'ssh -L 24100:localhost:24100 (docker) or kubectl port-forward svc/do-agent-aws 24100:24100 (kubernetes)' ${D}/ui-port/home/site/index.html \
	|| fail "PLANTED CONTROL: published on 24100, the hint does not name it: $(grep -oE 'reach it with.{0,120}' ${D}/ui-port/home/site/index.html | tr '\n' ' ')"
grep -qE '8000:localhost|svc/do-agent-aws 8000' ${D}/ui-port/home/site/index.html && fail "PLANTED CONTROL: published on 24100, the hint still names 8000"
env -u PORT_EXTERNAL_HOME UI_DIR=${D}/ui-noport "${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh without PORT_EXTERNAL_HOME"
grep -qF 'ssh -L 8000:localhost:8000' ${D}/ui-noport/home/site/index.html || fail "without PORT_EXTERNAL_HOME the hint does not fall back to 8000"
echo "ok 2a - the header's tunnel hint names the published port: 8000 by default, 24100 when PORT_EXTERNAL_HOME says so (both commands, 8000 nowhere), 8000 again without the variable"

# --- 2b. the Guide tile's page: docs/user-guide.md rendered by md2html.py (the renderer's own planted cases first);
#         with no readable source the render still succeeds and the page says so (planted: a missing path) ---
python3 -I "${AGENT_DIR}/md2html.py" --self-test > ${D}/md2html.txt 2>&1 || { cat ${D}/md2html.txt; fail "md2html.py --self-test"; }
GUIDE=${UI_DIR}/home/site/guide/index.html
[ -s "${GUIDE}" ] || fail "home-render.sh wrote no ${GUIDE}"
for H in "The 5-minute tour" "Troubleshooting"; do
	grep -qE "<h2[^>]*>${H}</h2>" "${GUIDE}" || fail "the rendered guide lacks the heading '${H}' (source: ${USER_GUIDE_MD:-/docs/user-guide.md}): $(grep -oE '<h2>[^<]*' "${GUIDE}" | tr '\n' ',')"
done
grep -q '<a class="home" href="/">Harness home</a>' "${GUIDE}" || fail "the rendered guide has no 'Harness home' link"
grep -q '<h2 id="the-5-minute-tour">' "${GUIDE}" || fail "the guide's headings carry no GitHub-style anchors (id=the-5-minute-tour)"
grep -q '<table>' "${GUIDE}" || fail "the guide's troubleshooting table did not render as a table"
grep -q '<script' "${GUIDE}" && fail "the rendered guide carries a script element - md2html.py must escape markup, not pass it"
USER_GUIDE_MD="${D}/no-such-<guide>.md" "${AGENT_DIR}/home-render.sh" > ${D}/render-noguide.out 2>&1 || fail "home-render.sh failed with no readable guide source (it must warn and render a placeholder): $(cat ${D}/render-noguide.out)"
grep -q "WARNING - Guide is not rendered" ${D}/render-noguide.out || fail "no WARNING for a missing guide source: $(cat ${D}/render-noguide.out)"
grep -q "This document is not in this image" "${GUIDE}" || fail "the placeholder page is missing with no guide source: $(head -c 300 "${GUIDE}")"
grep -q "no-such-&lt;guide&gt;.md" "${GUIDE}" || fail "the placeholder page does not escape the source path it prints: $(grep -o 'no readable [^)]*' "${GUIDE}")"
grep -q "<guide>" "${GUIDE}" && fail "the placeholder page prints the source path as markup"
"${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh (defaults, again)"
grep -qE "<h2[^>]*>The 5-minute tour</h2>" "${GUIDE}" || fail "the guide did not come back after the placeholder render"
# the README and the manual served locally (the footer's help links went to the GitHub repository, a 404 for a reader
# without access): the README page exists with its Quickstart, the manual has its index and one page per file of
# /docs/manual, its UI page carries the two sections the footer links to as anchors, and the footer links are local
RM=${UI_DIR}/home/site/guide/readme/index.html
[ -s "${RM}" ] || fail "home-render.sh wrote no ${RM}"
grep -q '<h2 id="quickstart">' "${RM}" || fail "the rendered README lacks its Quickstart heading: $(grep -oE '<h2 id="[^"]*"' "${RM}" | tr '\n' ',')"
grep -q '<img src="/guide/img/how-it-works.svg" alt="How Do Agent on AWS works' "${RM}" || fail "the rendered README does not show its How it works picture from /guide/img/: $(grep -o '<img[^>]*>' "${RM}" | head -2)"
[ -s "${UI_DIR}/home/site/guide/img/how-it-works.svg" ] || fail "home-render.sh did not place the README's picture at /guide/img/how-it-works.svg (the Dockerfile copies it to /docs/img)"
[ -s "${UI_DIR}/home/site/guide/manual/index.html" ] || fail "home-render.sh wrote no manual index (/guide/manual/)"
NMAN=0
for MF in /docs/manual/*.md; do
	[ "$(basename "${MF}")" == "README.md" ] && continue
	NMAN=$((NMAN + 1))
	[ -s "${UI_DIR}/home/site/guide/manual/$(basename "${MF}" .md)/index.html" ] || fail "home-render.sh wrote no page for the manual's ${MF}"
done
[ "${NMAN}" -ge 9 ] || fail "only ${NMAN} manual pages in /docs/manual (the Dockerfile copies docs/manual there)"
RU=${UI_DIR}/home/site/guide/manual/ui/index.html
for A in harness-uis home-page-and-reverse-proxy; do
	grep -q "<h2 id=\"${A}\">" "${RU}" || fail "the manual's UI page lacks the anchored heading #${A}: $(grep -oE '<h2 id="[^"]*"' "${RU}" | tr '\n' ',')"
done
grep -oE '<footer>.*</footer>' "${PAGE}" | grep -q 'href="/guide/manual/ui/#home-page-and-reverse-proxy"' || fail "the footer's manual link is not the local page: $(grep -oE '<footer>.*</footer>' "${PAGE}")"
grep -oE '<footer>.*</footer>' "${PAGE}" | grep -q 'href="/guide/manual/ui/#harness-uis"' || fail "the footer's Harness UIs link is not the local page"
grep -oE '<footer>.*</footer>' "${PAGE}" | grep -oE 'href="https://github.com[^"]*"' | grep -v 'href="https://github.com/awslabs/do-agent-aws"' | grep -q . && fail "a footer help link still points at a GitHub page: $(grep -oE '<footer>.*</footer>' "${PAGE}")"
# the North Star register, served the same way (the home page's North Star section links the local page): it exists with
# its first section heading as an anchor (the renderer takes the document's first h1 as the page title)
for P in "north-star:the-rule"; do
	F=${UI_DIR}/home/site/guide/${P%%:*}/index.html
	[ -s "${F}" ] || fail "home-render.sh wrote no ${F}"
	grep -q "<h2 id=\"${P#*:}\">" "${F}" || fail "the rendered ${P%%:*} page lacks its anchored heading #${P#*:}: $(grep -oE '<h[12] id="[^"]*"' "${F}" | head -2 | tr '\n' ',')"
done
echo "ok 2b - the Guide tile's page: rendered from the source with headings, the troubleshooting table and the home link, markup escaped; a missing source warns and renders a placeholder; the README is served at /guide/readme/ with anchored sections and the footer's help links are local"

# --- 3. every live tile answers through the proxy ---
"${AGENT_DIR}/ui-start.sh" > ${D}/ui-start.log 2>&1 || { cat ${D}/ui-start.log; fail "ui-start.sh"; }
"${AGENT_DIR}/comms-ui-start.sh" > ${D}/comms-start.log 2>&1 || { cat ${D}/comms-start.log; fail "comms-ui-start.sh"; }
# the LogLearner server ui-start.sh just started: its EFFECTIVE index path (read from the running process, not
# from a variable) must be derived from LOGLEARNER_STATE - this test sets no LOGLEARNER_DB; a fixed default here
# wrote the user's /wd/loglearner/index.db from the test container
LL_PID=$(cat ${UI_DIR}/loglearner.pid 2>/dev/null)
[ -n "${LL_PID}" ] && kill -0 "${LL_PID}" 2>/dev/null || fail "ui-start.sh left no live loglearner pid (${UI_DIR}/loglearner.pid)"
LL_DB=$(tr '\0' '\n' < /proc/${LL_PID}/environ 2>/dev/null | sed -n 's/^LOGLEARNER_DB=//p')
[ "${LL_DB}" == "${LOGLEARNER_STATE}/index.db" ] || fail "the running LogLearner server (pid ${LL_PID}) indexes into '${LL_DB}' - expected ${LOGLEARNER_STATE}/index.db derived from LOGLEARNER_STATE (a fixed default writes the user's /wd/loglearner/index.db from a test container)"

probe()
{
	# probe <url> [<host-header>] [<max-tries>] - retries until 2xx/3xx or timeout, echoes the last code
	URL=$1
	HOST_HEADER=$2
	TRIES=${3:-90}
	HDR=()
	[ -n "${HOST_HEADER}" ] && HDR=(-H "Host: ${HOST_HEADER}")
	HTTP=000
	for i in $(seq 1 ${TRIES}); do
		HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${HDR[@]}" "${URL}" 2>/dev/null)
		[ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null && break
		sleep 2
	done
	echo "${HTTP}"
}
H=http://127.0.0.1:${UI_PORT_HOME}
HTTP=$(probe "${H}/")
[ "${HTTP}" == "200" ] || { tail -5 ${UI_DIR}/home.log 2>/dev/null; fail "home page not answering (last=${HTTP})"; }

# the page's own inventory, the way its probe script reads it
PATH_TILES=$(grep -oE 'data-url="[^"]+"' "${PAGE}" | sed -E 's/data-url="([^"]+)"/\1/')
# badge_policy <header file> <page file> <label>: the page carries the home badge once with its three inline pieces (the
# style attribute, the phone-width <style> rule, the keeper <script>), and every policy that applies to it - each
# Content-Security-Policy header and each <meta http-equiv> one - admits all three by CSP's rules: 'unsafe-inline' counts
# only in a list without a hash (sha256, sha384, sha512) or nonce, and for a script without 'strict-dynamic'; a style
# attribute needs 'unsafe-inline' or 'unsafe-hashes' with its hash; keywords compare case-insensitively; the first of a
# repeated directive is the one that counts
badge_policy()
{
	python3 - "$1" "$2" "$3" << 'PY'
import base64, hashlib, re, sys
head, page, label = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
sha = lambda s: "'sha256-%s'" % base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()
pol = [l.split(":", 1)[1].strip() for l in head.splitlines() if l.lower().startswith("content-security-policy:")]
pol += re.findall(r'<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]*)"', page, re.I)
marker = '<a class="hs-badge" data-harness-home'
m = re.search(r'<a class="hs-badge" data-harness-home [^>]*style="([^"]*)"[^>]*>&#8962; home</a>'
              r'<style id="do-agent-aws-home-style">([^<]*)</style><script>([^<]*)</script>', page)
if page.count(marker) != 1 or not m:
    sys.exit("%s: the badge with its three inline pieces is not in the page exactly once (%d)" % (label, page.count(marker)))
HASHED = re.compile(r"'(sha256|sha384|sha512|nonce)-", re.I)
def norm(x):
    # a keyword, or a hash or nonce prefix, compares case-insensitively; a hash's value does not
    if HASHED.match(x):
        pre, val = x.split("-", 1)
        return pre.lower() + "-" + val
    return x.lower() if x.startswith("'") else x
def srcs(policy, names):
    d = {}
    for part in policy.split(";"):
        bits = part.strip().split()
        if bits and bits[0].lower() not in d:
            d[bits[0].lower()] = [norm(x) for x in bits[1:]]
    return next((d[n] for n in names if n in d), None)
def ok(s, h, attr, script):
    if s is None:
        return True
    void = any(HASHED.match(x) for x in s) or (script and "'strict-dynamic'" in s)
    return ("'unsafe-inline'" in s and not void) or (h in s and ("'unsafe-hashes'" in s or not attr))
for policy in pol:
    for name, value, names, attr, script in (
            ("style attribute", m.group(1), ("style-src-attr", "style-src", "default-src"), True, False),
            ("phone-width rule", m.group(2), ("style-src-elem", "style-src", "default-src"), False, False),
            ("keeper script", m.group(3), ("script-src-elem", "script-src", "default-src"), False, True)):
        if not ok(srcs(policy, names), sha(value), attr, script):
            sys.exit("%s: a policy refuses the badge's %s: %s" % (label, name, policy))
print("%s: the badge's three inline pieces admitted by its %d polic%s" % (label, len(pol), "y" if len(pol) == 1 else "ies"))
PY
}
# the rendered Guide through the proxy: no-store, a CSP whose only script is the badge's keeper (by its hash), and the
# floating home badge every UI carries
curl -s -D ${D}/guide.hdr -o ${D}/guide.html --max-time 10 "http://127.0.0.1:${UI_PORT_HOME}/guide/" || fail "/guide/ did not answer through the proxy"
grep -qi '^cache-control: no-store' ${D}/guide.hdr || fail "/guide/ is cacheable: $(grep -i cache ${D}/guide.hdr)"
grep -qi '^content-security-policy: ' ${D}/guide.hdr || fail "/guide/ answers without a Content-Security-Policy"
grep -q 'title="do-agent-aws harness home"' ${D}/guide.html || fail "/guide/ lacks the floating home badge"
grep -q "<h2 id=\"the-5-minute-tour\">" ${D}/guide.html || fail "/guide/ through the proxy is not the rendered guide"
BG=$(badge_policy ${D}/guide.hdr ${D}/guide.html "/guide/" 2>&1) || fail "${BG}"
# the README page under the same location: the same headers and badge (a later split of the location would show here)
curl -s -D ${D}/readme.hdr -o ${D}/readme.html --max-time 10 "http://127.0.0.1:${UI_PORT_HOME}/guide/readme/" || fail "/guide/readme/ did not answer through the proxy"
grep -qi '^cache-control: no-store' ${D}/readme.hdr || fail "/guide/readme/ is cacheable: $(grep -i cache ${D}/readme.hdr)"
grep -qi '^content-security-policy: ' ${D}/readme.hdr || fail "/guide/readme/ answers without a Content-Security-Policy"
grep -q 'title="do-agent-aws harness home"' ${D}/readme.html || fail "/guide/readme/ lacks the floating home badge"
grep -q '<h2 id="quickstart">' ${D}/readme.html || fail "/guide/readme/ through the proxy is not the rendered README"
BR=$(badge_policy ${D}/readme.hdr ${D}/readme.html "/guide/readme/" 2>&1) || fail "${BR}"
# the README's picture, under the same location: served as an SVG image (a picture served as anything else stays blank),
# and left alone by the badge's sub_filter, which rewrites HTML only
curl -s -D ${D}/img.hdr -o ${D}/img.svg --max-time 10 "http://127.0.0.1:${UI_PORT_HOME}/guide/img/how-it-works.svg" || fail "/guide/img/how-it-works.svg did not answer through the proxy"
grep -qi '^content-type: image/svg+xml' ${D}/img.hdr || fail "/guide/img/how-it-works.svg is not served as image/svg+xml: $(grep -i '^content-type' ${D}/img.hdr)"
cmp -s ${D}/img.svg /docs/img/how-it-works.svg || fail "/guide/img/how-it-works.svg is not the image's /docs/img/how-it-works.svg byte for byte"
# the manual's UI page, where the footer's help links land: the same location, so the same headers and badge
curl -s -D ${D}/manual.hdr -o ${D}/manual.html --max-time 10 "http://127.0.0.1:${UI_PORT_HOME}/guide/manual/ui/" || fail "/guide/manual/ui/ did not answer through the proxy"
grep -qi '^cache-control: no-store' ${D}/manual.hdr || fail "/guide/manual/ui/ is cacheable: $(grep -i cache ${D}/manual.hdr)"
grep -qi '^content-security-policy: ' ${D}/manual.hdr || fail "/guide/manual/ui/ answers without a Content-Security-Policy"
grep -q 'title="do-agent-aws harness home"' ${D}/manual.html || fail "/guide/manual/ui/ lacks the floating home badge"
grep -q '<h2 id="harness-uis">' ${D}/manual.html || fail "/guide/manual/ui/ through the proxy is not the rendered manual page"
BM=$(badge_policy ${D}/manual.hdr ${D}/manual.html "/guide/manual/ui/" 2>&1) || fail "${BM}"
PATH_TILES="${PATH_TILES} /guide/readme/ /guide/manual/ui/"   # the README and the manual page the footer's help links point at: pages of the home listener, not tiles
# the badge on the Guide's North Star page and on the Loop Deck page (whose vendored page declares a <meta> policy of its
# own): every policy there admits its three inline pieces, so a browser runs the keeper and applies the phone-width rule
BPS=""
for GU in north-star:/guide/north-star/; do
	G=${GU%%:*}; U=${GU#*:}
	HC=$(curl -s -D ${D}/badge-${G}.hdr -o ${D}/badge-${G}.html -w '%{http_code}' --max-time 10 "${H}${U}")
	[ "${HC}" == "200" ] || fail "${U} did not answer 200 through the proxy (${HC})"
	BP=$(badge_policy ${D}/badge-${G}.hdr ${D}/badge-${G}.html "${U}" 2>&1) || fail "${BP}"
	BPS="${BPS}${BPS:+; }${BP}"
done
[ "$(probe "${H}/" "loop-deck.localhost:${UI_PORT_HOME}")" == "200" ] || fail "the Loop Deck page does not answer through the proxy"
HC=$(curl -s -D ${D}/badge-deck.hdr -o ${D}/badge-deck.html -w '%{http_code}' --max-time 10 -H "Host: loop-deck.localhost:${UI_PORT_HOME}" "${H}/")
[ "${HC}" == "200" ] || fail "the Loop Deck page did not answer 200 through the proxy (${HC})"
BD=$(badge_policy ${D}/badge-deck.hdr ${D}/badge-deck.html "loop-deck.localhost" 2>&1) || fail "${BD}"
# PLANTED CONTROLS, each failing the check for its own reason: the two policies the badge met before - the Guide's
# script-src 'none', and the Deck's <meta> as the vendored page has it, script-src 'self' - and a hash in the Guide's
# style-src, which switches its 'unsafe-inline' off for the badge's style attribute
sed "s/script-src 'sha256-[^']*'/script-src 'none'/I" ${D}/guide.hdr > ${D}/guide-planted-none.hdr
grep -qi "script-src 'none'" ${D}/guide-planted-none.hdr || fail "PLANTED CONTROL: the Guide's script-src 'none' could not be planted"
CG=$(badge_policy ${D}/guide-planted-none.hdr ${D}/guide.html "planted /guide/" 2>&1) && fail "PLANTED CONTROL: a Guide policy with script-src 'none' passed: ${CG}"
case "${CG}" in *"refuses the badge's keeper script"*) ;; *) fail "PLANTED CONTROL: the Guide's script-src 'none' failed for another reason: ${CG}" ;; esac
python3 - ${D}/badge-deck.html ${D}/badge-deck-planted.html << 'PY' || fail "PLANTED CONTROL: the Deck's vendored <meta> could not be planted"
import re, sys
s = open(sys.argv[1]).read()
t, n = re.subn(r"script-src 'self' 'sha256-[^']*';", "script-src 'self';", s, count=1)
assert n == 1, "the Deck page's <meta> policy does not carry the keeper's hash where the control expects it"
open(sys.argv[2], "w").write(t)
PY
CD=$(badge_policy ${D}/badge-deck.hdr ${D}/badge-deck-planted.html "planted loop-deck.localhost" 2>&1) && fail "PLANTED CONTROL: the Deck's vendored <meta> policy passed: ${CD}"
case "${CD}" in *"refuses the badge's keeper script"*) ;; *) fail "PLANTED CONTROL: the Deck's vendored <meta> failed for another reason: ${CD}" ;; esac
sed "s/style-src 'self' 'unsafe-inline'/style-src 'self' 'unsafe-inline' 'sha256-planted+style+hash='/I" ${D}/guide.hdr > ${D}/guide-planted-style.hdr
grep -qF "'sha256-planted+style+hash='" ${D}/guide-planted-style.hdr || fail "PLANTED CONTROL: the hash in the Guide's style-src could not be planted"
CS=$(badge_policy ${D}/guide-planted-style.hdr ${D}/guide.html "planted /guide/" 2>&1) && fail "PLANTED CONTROL: a hash in the Guide's style-src passed: ${CS}"
case "${CS}" in *"refuses the badge's style attribute"*) ;; *) fail "PLANTED CONTROL: the hash in the Guide's style-src failed for another reason: ${CS}" ;; esac
echo "ok 3 - the home badge's three inline pieces are admitted on the Guide's three pages and the Loop Deck page (${BG}; ${BR}; ${BPS}; ${BD}); controls: ${CG%%: default-src*}; ${CD%%: default-src*}; ${CS%%: default-src*}"
HOST_TILES=$(grep -oE 'data-host="[^"]+"' "${PAGE}" | sed -E 's/data-host="([^"]+)"/\1/')
N=0
for P in ${PATH_TILES}; do
	HTTP=$(probe "${H}${P}")
	[ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null \
		|| { tail -3 ${UI_DIR}/*.log 2>/dev/null | tail -20; fail "tile ${P} does not answer through the proxy (last=${HTTP})"; }
	echo "ok 3 - tile ${P} -> ${HTTP}"
	N=$((N + 1))
done
for HOST in ${HOST_TILES}; do
	HTTP=$(probe "${H}/" "${HOST}.localhost:${UI_PORT_HOME}")
	[ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null \
		|| { tail -3 ${UI_DIR}/*.log 2>/dev/null | tail -20; fail "tile ${HOST}.localhost does not answer through the proxy (last=${HTTP})"; }
	# the dot reads a same-origin probe location, not the host route: it must exist and answer too
	grep -qF "data-host=\"${HOST}\" data-probe=\"/__probe/${HOST}\"" "${PAGE}" || fail "tile ${HOST} carries no data-probe=/__probe/${HOST} for its dot"
	PHTTP=$(probe "${H}/__probe/${HOST}")
	[ "${PHTTP}" -ge 200 ] 2>/dev/null && [ "${PHTTP}" -lt 400 ] 2>/dev/null \
		|| fail "the dot's probe /__probe/${HOST} does not answer through the proxy (last=${PHTTP})"
	echo "ok 3 - tile ${HOST}.localhost -> ${HTTP}, dot probe /__probe/${HOST} -> ${PHTTP}"
	N=$((N + 1))
done
[ -s "${LL_DB}" ] || fail "the LogLearner server answers but its index ${LL_DB} does not exist - the indexer wrote somewhere else"
echo "ok 3 - the LogLearner server indexes into ${LL_DB} (derived from LOGLEARNER_STATE; $(wc -c < "${LL_DB}") bytes), never the shipped default from a test"
# every tile route FOLLOWED to its final page: a 3xx is only acceptable when it leads to a 2xx within a few hops
# (the memory UI once answered 307 to itself in a loop - its Next.js server bound as 127.0.0.1 would not serve
# the middleware's rewrite to localhost - and a first-hop 3xx check called that tile fine); the deep links too
follow()
{
	# follow <url> [<host-header>] -> "<final code> <redirects>"; a loop ends with curl's 47 and code 000
	URL=$1; HOST_HEADER=$2; HDR=()
	[ -n "${HOST_HEADER}" ] && HDR=(-H "Host: ${HOST_HEADER}")
	OUT=$(curl -s -L --max-redirs 8 -o ${D}/follow-body.html -w '%{http_code} %{num_redirects}' --max-time 20 "${HDR[@]}" "${URL}" 2>/dev/null) || echo "000 loop"
	echo "${OUT}"
}
for P in ${PATH_TILES}; do
	read -r FINAL HOPS <<< "$(follow "${H}${P}")"
	[ "${FINAL}" -ge 200 ] 2>/dev/null && [ "${FINAL}" -lt 300 ] 2>/dev/null || fail "tile ${P} followed to its end does not reach a 2xx page (final=${FINAL} after ${HOPS} redirect(s))"
done
# browser_follow <host> <path> -> "<final code> <hops> <chain>": what a browser does - connect to the tile's
# host (resolved to this proxy), resolve each Location against the current URL, keep the host the Location
# names; fails the test when a hop leaves the tile's host (a Location on 127.0.0.1 or localhost would land a
# browser that reached the tile through the tunnel address on the home listener's 404)
browser_follow()
{
	BF_HOST=$1; BF_URL="http://$1.localhost:${UI_PORT_HOME}$2"; BF_CHAIN=""; BF_CODE=000; BF_HOPS=0
	for i in $(seq 0 8); do
		BF_HDRS=$(curl -s -D - -o ${D}/follow-body.html --max-time 20 --resolve "${BF_HOST}.localhost:${UI_PORT_HOME}:127.0.0.1" "${BF_URL}" 2>/dev/null)
		BF_CODE=$(echo "${BF_HDRS}" | head -1 | awk '{print $2}')
		BF_LOC=$(echo "${BF_HDRS}" | grep -i '^location:' | head -1 | cut -d' ' -f2- | tr -d '\r')
		BF_CHAIN="${BF_CHAIN}${BF_CHAIN:+ -> }${BF_URL#http://} ${BF_CODE}"
		[ -n "${BF_LOC}" ] || break
		case "${BF_LOC}" in
			http://${BF_HOST}.localhost:${UI_PORT_HOME}/*) BF_URL=${BF_LOC} ;;
			http://*|https://*) echo "${BF_CODE} ${BF_HOPS} ${BF_CHAIN} -> LEAVES THE TILE HOST: ${BF_LOC}"; return ;;
			/*) BF_URL="http://${BF_HOST}.localhost:${UI_PORT_HOME}${BF_LOC}" ;;
			*) BF_URL="http://${BF_HOST}.localhost:${UI_PORT_HOME}/${BF_LOC}" ;;
		esac
		BF_HOPS=$((BF_HOPS + 1))
	done
	echo "${BF_CODE} ${BF_HOPS} ${BF_CHAIN}"
}
for HOST in $(printf '%s\n' ${HOST_TILES} | sort -u); do
	read -r FINAL HOPS CHAIN <<< "$(browser_follow "${HOST}" /)"
	[ "${FINAL}" -ge 200 ] 2>/dev/null && [ "${FINAL}" -lt 300 ] 2>/dev/null || fail "tile ${HOST}.localhost followed like a browser does not reach a 2xx page on its own host (final=${FINAL} after ${HOPS} redirect(s): ${CHAIN})"
	echo "ok 3 - tile ${HOST}.localhost root, followed like a browser: ${CHAIN}"
	# every deep link on that host: two tiles can share one (Session insights and Learned rules)
	mapfile -t DPS < <(grep -oE "data-host=\"${HOST}\" data-probe=\"[^\"]*\" data-path=\"[^\"]+\"" "${PAGE}" | sed -E 's/.*data-path="([^"]+)"/\1/' | sort -u)
	for DP in "${DPS[@]}"; do
		read -r FINAL HOPS CHAIN <<< "$(browser_follow "${HOST}" "${DP}")"
		[ "${FINAL}" -ge 200 ] 2>/dev/null && [ "${FINAL}" -lt 300 ] 2>/dev/null || fail "the ${HOST} tile's deep link ${DP} does not reach a 2xx page on its own host (final=${FINAL} after ${HOPS} redirect(s): ${CHAIN})"
		echo "ok 3 - deep link ${HOST}.localhost${DP}, followed like a browser: ${CHAIN}"
	done
done
# the memory UI's root redirect leaves the proxy ABSOLUTE on the tile's host, while the upstream itself answers
# it relative (the control: the proxy did the re-hosting) - a client that connected through 127.0.0.1 with a
# Host header would otherwise resolve the relative Location against 127.0.0.1 and hit the home page's 404
LOC=$(curl -s -D - -o /dev/null --max-time 10 -H "Host: hindsight.localhost:${UI_PORT_HOME}" "${H}/" | grep -i '^location:' | cut -d' ' -f2- | tr -d '\r')
[ "${LOC}" == "http://hindsight.localhost:${UI_PORT_HOME}/dashboard" ] || fail "the memory UI root's redirect through the proxy is '${LOC}' - expected the absolute http://hindsight.localhost:${UI_PORT_HOME}/dashboard (a relative or loopback Location sends a tunnelled client to the home listener's 404)"
ULOC=$(curl -s -D - -o /dev/null --max-time 10 -H "Host: hindsight.localhost:${UI_PORT_HOME}" "http://127.0.0.1:${UI_PORT_HINDSIGHT_UI}/" | grep -i '^location:' | cut -d' ' -f2- | tr -d '\r')
[ "${ULOC}" == "/dashboard" ] || echo "    (note: the control plane itself now answers Location '${ULOC}' on /; the proxy re-hosts whatever it sends)"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -L --max-redirs 5 -H "Host: hindsight.localhost:${UI_PORT_HOME}" --resolve "hindsight.localhost:${UI_PORT_HOME}:127.0.0.1" "${H}/")
[ "${HTTP}" == "200" ] || fail "curl -L with the tile's Host header on the 127.0.0.1 address does not end on the dashboard (http=${HTTP}) - the case of a browser behind the tunnel"
echo "ok 3 - the memory UI root redirects to http://hindsight.localhost:${UI_PORT_HOME}/dashboard (absolute on the tile's host; upstream says '${ULOC}'); curl -L through 127.0.0.1 with the Host header ends 200"
# the memory UI's bank view names the bank it shows (no browser in the image: the served HTML is checked)
read -r FINAL HOPS <<< "$(follow "${H}/banks/harness-knowledge?view=data" "hindsight.localhost:${UI_PORT_HOME}")"
[ "${FINAL}" == "200" ] || fail "the memory UI's bank view is not a 200 page (final=${FINAL} after ${HOPS} redirect(s))"
grep -q "harness-knowledge" ${D}/follow-body.html || fail "the memory UI's bank view page does not name the bank harness-knowledge ($(wc -c < ${D}/follow-body.html) bytes served)"
grep -qi "<title>[^<]*Hindsight" ${D}/follow-body.html || fail "the memory UI's bank view is not the control plane's page: $(grep -o '<title>[^<]*</title>' ${D}/follow-body.html | head -1)"
echo "ok 3 - the memory UI bank view /banks/harness-knowledge?view=data renders (200, names the bank, $(wc -c < ${D}/follow-body.html) bytes)"
# the LogLearner dashboard's Hindsight page links to the memory API where the BROWSER reaches it: under /memory-api on
# the page's own host (loglearner-serve.sh exports LOGLEARNER_HINDSIGHT_LINK_BASE, and the dashboard's host route serves
# the memory API's locations like the home listener), never at the address the dashboard's server uses, which on a
# shared host opens somebody else's memory API and from a browser opens nothing (the API publishes no port). The first
# link of a bank created here is followed through the proxy on the dashboard's host and must answer the API's JSON.
# This test's memory API starts with no bank (the seed is startup.sh's, not ui-start.sh's), so one is created first, in
# the test-local API (HINDSIGHT_HOME above), the way the API's own clients do
# The bank's name carries the badge's anchor, </body>, on purpose: the API's JSON must come through the proxy byte for
# byte on both hosts (the substitution filter of the memory API location applies to text/html only), and the docs page
# alone gets the badge and the swagger rewrites
LL_NAME='test16 links </body> bank'
HTTP=$(curl -s -o ${D}/ll-bank.json -w '%{http_code}' --max-time 30 -X PUT -H 'Content-Type: application/json' -d "{\"name\": \"${LL_NAME}\"}" \
	"http://127.0.0.1:${UI_PORT_HINDSIGHT_API}/v1/default/banks/test16-links")
[ "${HTTP}" == "200" ] || [ "${HTTP}" == "201" ] || fail "could not create a bank in the test-local memory API (http=${HTTP}): $(head -c 200 ${D}/ll-bank.json)"
LL_BANK_CLEANUP=1
for HOSTNAME_ROUTE in "localhost:${UI_PORT_HOME}" "loglearner.localhost:${UI_PORT_HOME}"; do
	curl -s -o ${D}/ll-banks-proxied.json --max-time 30 -H "Host: ${HOSTNAME_ROUTE}" "${H}/memory-api/v1/default/banks"
	python3 - ${D}/ll-banks-proxied.json "${LL_NAME}" << 'PYEOF' || fail "the banks list through the proxy on ${HOSTNAME_ROUTE} is not the API's JSON (a </body> in a bank name drew the badge into it?): $(head -c 300 ${D}/ll-banks-proxied.json)"
import json, sys
d = json.load(open(sys.argv[1]))
banks = d if isinstance(d, list) else d.get("banks", [])
names = [b.get("name") for b in banks]
sys.exit(0 if sys.argv[2] in names else 1)
PYEOF
	grep -q 'do-agent-aws-home' ${D}/ll-banks-proxied.json && fail "the badge was injected into the API's JSON on ${HOSTNAME_ROUTE}"
	curl -s -o ${D}/ll-docs.html --max-time 30 -H "Host: ${HOSTNAME_ROUTE}" "${H}/memory-api/docs"
	[ "$(grep -o 'id="do-agent-aws-home"' ${D}/ll-docs.html | wc -l)" == "1" ] || fail "the memory API docs page on ${HOSTNAME_ROUTE} does not carry the badge exactly once ($(grep -o 'id="do-agent-aws-home"' ${D}/ll-docs.html | wc -l))"
	grep -q '/memory-api/__swagger/' ${D}/ll-docs.html || fail "the memory API docs page on ${HOSTNAME_ROUTE} does not load swagger from the image's copy"
	grep -q 'cdn.jsdelivr.net' ${D}/ll-docs.html && fail "the memory API docs page on ${HOSTNAME_ROUTE} still names the CDN"
done
curl -s --max-time 10 -H "Host: loglearner.localhost:${UI_PORT_HOME}" "${H}/hindsight" > ${D}/ll-hindsight.html
LL_LINKS=$(grep -oE 'href="[^"]*/v1/default/banks/[^"]*/graph"' ${D}/ll-hindsight.html | sed 's/^href="//; s/"$//')
[ -n "${LL_LINKS}" ] || fail "the dashboard's Hindsight page carries no entity-graph link although the API holds a bank (does the dashboard reach the memory API on ${UI_PORT_HINDSIGHT_API}?): $(grep -oE '<h[12][^<]*</h[12]>|API not reachable[^<]*' ${D}/ll-hindsight.html | head -3 | tr '\n' ' ')"
BAD=$(echo "${LL_LINKS}" | grep -vE '^/memory-api/v1/default/banks/[^/]+/graph$' | head -3)
[ -z "${BAD}" ] || fail "a Hindsight link on the dashboard is not under /memory-api on the page's own host: ${BAD}"
grep -qE 'href="https?://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+/v1/' ${D}/ll-hindsight.html && fail "a Hindsight link on the dashboard points at the server's own address: $(grep -oE 'href="https?://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+/v1/[^"]*"' ${D}/ll-hindsight.html | head -2)"
LL_LINK=/memory-api/v1/default/banks/test16-links/graph
echo "${LL_LINKS}" | grep -qxF "${LL_LINK}" || fail "the dashboard's Hindsight page does not link the bank created above (${LL_LINK}); its links: $(echo "${LL_LINKS}" | head -3 | tr '\n' ' ')"
HTTP=$(curl -s -o ${D}/ll-graph.json -w '%{http_code}' --max-time 30 -H "Host: loglearner.localhost:${UI_PORT_HOME}" "${H}${LL_LINK}")
[ "${HTTP}" == "200" ] && python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if "nodes" in d and "edges" in d else 1)' ${D}/ll-graph.json 2>/dev/null \
	|| fail "the dashboard's link ${LL_LINK} does not reach the memory API's graph through the dashboard's own host (http=${HTTP}): $(head -c 200 ${D}/ll-graph.json)"
# the dashboard's host serves the API read-only: a write there is refused by the proxy (the dashboard's pages only read)
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X DELETE -H "Host: loglearner.localhost:${UI_PORT_HOME}" "${H}/memory-api/v1/default/banks/test16-links")
[ "${HTTP}" == "403" ] || fail "a DELETE through the dashboard's host was not refused (http=${HTTP})"
# ...while the home listener still takes writes: the test's own cleanup goes through it
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X DELETE -H "Host: localhost:${UI_PORT_HOME}" "${H}/memory-api/v1/default/banks/test16-links")
[ "${HTTP}" == "200" ] || [ "${HTTP}" == "204" ] || fail "a DELETE through the home listener was not accepted (http=${HTTP}); the home listener must keep taking writes to the memory API"
LL_BANK_CLEANUP=""
echo "ok 3 - the LogLearner dashboard's $(echo "${LL_LINKS}" | wc -l) Hindsight link(s) are under /memory-api on its own host, none at the server's address; the created bank's (${LL_LINK}) answers the API's graph through that host, where writes are refused while the home listener still takes them; the API's JSON with a </body> in it passes both hosts untouched and the docs page carries the badge once with the swagger copy"
# planted control: the loop the follow check must catch - the control plane bound as 127.0.0.1 on a spare port
LOOP_PORT=${TEST16_LOOP_PORT:-19997}
( cd /opt/hindsight/control-plane && env HOSTNAME=127.0.0.1 PORT=${LOOP_PORT} HINDSIGHT_CP_DATAPLANE_API_URL="http://127.0.0.1:${UI_PORT_HINDSIGHT_API}" setsid nohup /usr/local/bin/node server.js > ${D}/loop-control.log 2>&1 & echo $! > ${D}/loop-control.pid )
for i in $(seq 1 40); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${LOOP_PORT}/api/health" 2>/dev/null && break; sleep 0.5; done
read -r FINAL HOPS <<< "$(follow "http://127.0.0.1:${LOOP_PORT}/dashboard")"
kill -TERM -- "-$(cat ${D}/loop-control.pid)" 2>/dev/null || kill -TERM "$(cat ${D}/loop-control.pid)" 2>/dev/null
if [ "${FINAL}" -ge 200 ] 2>/dev/null && [ "${FINAL}" -lt 300 ] 2>/dev/null; then
	fail "planted control: the control plane bound as 127.0.0.1 answered a 2xx on /dashboard (final=${FINAL} after ${HOPS}) - the follow check would not have caught the redirect loop this image used to ship (did the control plane change its middleware?)"
fi
echo "ok 3 - planted control: the control plane bound as 127.0.0.1 loops (final=${FINAL}, ${HOPS}) and the follow check catches it"
# the memory UI tile deep-links to the seeded bank (the control plane has no default-bank setting)
grep -qF 'data-host="hindsight" data-probe="/__probe/hindsight" data-path="/banks/harness-knowledge?view=data"' "${PAGE}" \
	|| fail "the Memory tile does not deep-link to /banks/harness-knowledge?view=data"
grep -q "el.dataset.path || '/'" "${PAGE}" || fail "the home page's link script ignores data-path"
# the page's script must read the real status (same-origin, no cross-origin no-cors fetch left)
grep -q "mode = 'no-cors'" "${PAGE}" && fail "the home page still probes host tiles with a no-cors fetch (a 502 would read green)"
grep -q "el.dataset.probe || el.dataset.url" "${PAGE}" || fail "the home page's probe script does not read data-probe"
# the memory tile's note: the seed's extraction state file is served same-origin (404 until the seed wrote it,
# GET-only) and the page's script reads it together with the live bank stats through /memory-api/ - a memory API
# that is up but cannot call Bedrock would otherwise read green over empty banks (the owner's check 9)
grep -q 'id="memory-state"' "${PAGE}" || fail "the Hindsight tile carries no memory-state note"
grep -q "read('/__seed-state'" "${PAGE}" || fail "the page's script does not read /__seed-state"
grep -q "/memory-api/v1/default/banks" "${PAGE}" || fail "the page's script does not read the live bank stats through /memory-api/"
grep -q "EXTRACTION FAILING" "${PAGE}" || fail "the page's script has no failing-extraction wording"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${H}/__seed-state")
[ "${HTTP}" == "404" ] || fail "/__seed-state answers ${HTTP} with no state file (expected 404)"
printf 'state=failed\nreason=planted: the AWS profile named by AWS_PROFILE does not exist\ndocuments=0/276\n' > "${UI_DIR}/hindsight-seed.state"
BODY=$(curl -s --max-time 5 "${H}/__seed-state")
echo "${BODY}" | grep -qx "state=failed" || fail "/__seed-state does not serve the planted state file: '${BODY}'"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "${H}/__seed-state")
[ "${HTTP}" == "403" ] || fail "/__seed-state accepts POST (${HTTP}); it must be GET-only"
# ui-status.sh reads the same file: a failed extraction is a FAILED row and a non-zero exit
"${AGENT_DIR}/ui-status.sh" > ${D}/status-failed.log 2>&1 && fail "ui-status.sh exits 0 with a failed extraction state planted"
grep -q "^hindsight-seed: FAILED documents=0/276 - planted: the AWS profile" ${D}/status-failed.log || fail "ui-status.sh has no FAILED hindsight-seed row with the planted reason: $(grep hindsight-seed ${D}/status-failed.log)"
rm -f "${UI_DIR:?}/hindsight-seed.state"
# the session guard's counts: same-origin, 404 until the guard wrote them, GET-only; the page reads them and, for a bank
# with failed operations, those operations (their reasons)
grep -q "read('/__memory-guard'" "${PAGE}" || fail "the page's script does not read /__memory-guard"
grep -q "/operations?status=failed" "${PAGE}" || fail "the page's script does not read the failed operations' reasons"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${H}/__memory-guard")
[ "${HTTP}" == "404" ] || fail "/__memory-guard answers ${HTTP} with no state file (expected 404)"
printf 'updated_at=2026-10-15T12:00:00Z\nrejected_language=1\n' > "${UI_DIR}/hindsight-memory-guard.state"
BODY=$(curl -s --max-time 5 "${H}/__memory-guard")
echo "${BODY}" | grep -qx "rejected_language=1" || fail "/__memory-guard does not serve the planted state file: '${BODY}'"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "${H}/__memory-guard")
[ "${HTTP}" == "403" ] || fail "/__memory-guard accepts POST (${HTTP}); it must be GET-only"
rm -f "${UI_DIR:?}/hindsight-memory-guard.state"
echo "ok 3 - the memory tile's note: /__seed-state serves the seed's state file and /__memory-guard the session guard's counts (404 before each exists, GET-only), the page reads them with the live bank stats and the failed operations' reasons; ui-status.sh reports a planted failed extraction and exits 1"
# the session guard against this test's memory API, the real one, so what the guard assumes about it is checked here and
# not only against a stub: a completed retain operation names its document, an invalidated record reads back with its
# reason, recall leaves it out. The bank stores each record as it is sent (chunks mode: no model in this test); the
# planted session records (English ones quoting German or listing hosts among them), one guard pass, then the recall
# hook on the same bank.
mkdir -p ${D}/guard-ui
GUARD_BANK_CLEANUP=1
GUARD_SUMMARY=$(python3 - "http://127.0.0.1:${UI_PORT_HINDSIGHT_API}" "${AGENT_DIR}" "${D}" << 'PY' 2>&1
import json, os, subprocess, sys, time, urllib.error, urllib.parse, urllib.request, uuid
api, agent_dir, d = sys.argv[1:4]
bank = "coding-agent::t16-session-guard"
b = api + "/v1/default/banks/" + urllib.parse.quote(bank, safe="")
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(method, url, body=None):
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method,
                                 headers={"Content-Type": "application/json"})
    with opener.open(req, timeout=60) as r:
        raw = r.read()
    return json.loads(raw) if raw else {}


def no(msg):
    print(msg)
    sys.exit(1)


try:
    call("DELETE", b)   # a bank an earlier run left behind when it was killed; this run's goes with the test
except urllib.error.HTTPError:
    pass
call("PUT", b, {"name": "test16 session guard"})
call("PATCH", b + "/config", {"updates": {"retain_extraction_mode": "chunks", "enable_observations": False,
                                          "enable_auto_consolidation": False}})
ask = "The user asked the agent to load the private knowledge package github.com/example-org/planted-pack."
sids = {k: str(uuid.uuid4()) for k in ("claim", "request", "german", "marker", "repeat", "quote", "endpoints", "outcome", "outcome2", "assistant", "quote2", "reported", "askedwhat", "passive2")}
texts = {"claim": "I loaded the private knowledge package github.com/example-org/planted-pack.", "request": ask,
         "german": "Die Slack-App wurde mit dem Manifest erstellt, das nur Lesezugriff auf die Kanäle ermöglicht.",
         "marker": "REF-ID: conversation:%s was mentioned on 2026-10-15." % sids["marker"], "repeat": ask,
         "quote": "The user asked the agent to reply with one German sentence: 'Die Slack-App wurde mit dem Manifest erstellt, das nur Lesezugriff auf die Kanäle ermöglicht.'",
         "endpoints": "Endpoints: api.github.com, uploads.github.com and raw.githubusercontent.com",
         "outcome": "The user asked the agent to load the planted runbook, which the agent loaded.",
         "outcome2": "The user asked the agent to load the planted guide which the agent then loaded.",
         "assistant": "The assistant loaded the planted knowledge package.",
         "quote2": "User requested a reply in German: ‘Die Slack-App wurde mit dem Manifest erstellt, das nur Lesezugriff auf die Kanäle ermöglicht.’",
         "reported": "The user reported that the agent deleted the planted file.",
         "askedwhat": "The user asked what the agent changed in the planted config.",
         "passive2": "The user asked to load the planted pack, which was loaded."}
for n, k in enumerate(texts):
    sid = sids[k]
    call("POST", b + "/memories", {"async": True, "items": [{
        "content": texts[k], "timestamp": "2026-10-15T08:%02d:00Z" % n, "document_id": "conversation:" + sid,
        "context": "Conversation between a user and a coding agent, session %s." % sid,
        "metadata": {"source": "chat", "session_id": sid, "verified": "false"}, "tags": ["source:chat", "harness:claude-code"]}]})
docs = {"conversation:" + s for s in sids.values()}
deadline = time.time() + 180
while True:
    failed = [o for o in call("GET", b + "/operations?status=failed&limit=100").get("operations", []) if o.get("document_id") in docs]
    if failed:
        no("a planted retain failed: %s" % str(failed[0].get("error_message"))[:200])
    done = {o.get("document_id") for o in call("GET", b + "/operations?status=completed&limit=100").get("operations", [])}
    if docs <= done:
        break
    if time.time() > deadline:
        no("the planted retains did not complete within 180 s (%d of %d)" % (len(docs & done), len(docs)))
    time.sleep(2)
ids = {}
for k, sid in sids.items():
    items = call("GET", b + "/memories/list?limit=50&document_id=" + urllib.parse.quote("conversation:" + sid, safe="")).get("items", [])
    if len(items) != 1:
        no("the %s session holds %d records, want 1 (chunks mode stores each as sent)" % (k, len(items)))
    ids[k] = items[0]["id"]
env = dict(os.environ, HINDSIGHT_API_URL=api, HINDSIGHT_BANK_ID=bank, HINDSIGHT_GUARD_STATE=d + "/guard-state.json",
           UI_DIR=d + "/guard-ui", HINDSIGHT_HOOKS_CONFIG=d + "/guard-no-config.json", HINDSIGHT_API_LLM_OUTPUT_LANGUAGE="English",
           HINDSIGHT_RECALL_TIMEOUT="30")
g = subprocess.run([sys.executable, agent_dir + "/hindsight-session-guard.py", "--once"], env=env, capture_output=True, text=True,
                   timeout=120)
if g.returncode != 0:
    no("the guard pass exited %d: %s" % (g.returncode, (g.stderr or g.stdout)[-300:]))
got = {k: call("GET", b + "/memories/" + ids[k]) for k in ids}
claim = got["claim"]
if claim.get("text") != "The agent said: " + texts["claim"] or claim.get("state") != "valid" \
        or not str(claim.get("context") or "").startswith("agent claim, not verified; session " + sids["claim"]):
    no("the agent's claim was not rewritten as its claim: %s" % json.dumps({f: claim.get(f) for f in ("text", "context", "state")}))
if got["request"].get("text") != ask or got["request"].get("state") != "valid":
    no("the user's request changed: %s" % json.dumps({f: got["request"].get(f) for f in ("text", "state")}))
for k in ("quote", "endpoints", "quote2"):   # English, though two quote German and one lists hosts
    if got[k].get("text") != texts[k] or got[k].get("state") != "valid":
        no("the %s record changed: %s" % (k, json.dumps({f: got[k].get(f) for f in ("text", "state", "invalidation_reason")})))
for k in ("outcome", "outcome2", "passive2"):   # the user's request with the agent's account of the outcome: text kept, claim context
    o = got[k]
    if o.get("text") != texts[k] or o.get("state") != "valid" \
            or not str(o.get("context") or "").startswith("agent claim, not verified; session " + sids[k]):
        no("the %s record (a request with the agent's account) was not marked as its claim: %s"
           % (k, json.dumps({f: o.get(f) for f in ("text", "context", "state")})))
a = got["assistant"]   # the assistant as the agent: its account rewritten as the agent's claim
if a.get("text") != "The agent said: " + texts["assistant"] or not str(a.get("context") or "").startswith("agent claim, not verified"):
    no("the assistant's account was not rewritten as the agent's claim: %s" % json.dumps({f: a.get(f) for f in ("text", "context")}))
for k in ("reported", "askedwhat"):   # an action the user reports or asks about: the user's words, unchanged
    if got[k].get("text") != texts[k] or got[k].get("state") != "valid" or str(got[k].get("context") or "").startswith("agent claim"):
        no("the %s record was changed or marked as the agent's claim: %s"
           % (k, json.dumps({f: got[k].get(f) for f in ("text", "context", "state")})))
want = {"german": "language: de, not en", "marker": "no content: the transcript's REF-ID marker", "repeat": "duplicate of " + ids["request"]}
for k, reason in want.items():
    if got[k].get("state") != "invalidated" or got[k].get("invalidation_reason") != reason:
        no("the %s record was not set aside with the reason '%s': %s"
           % (k, reason, json.dumps({f: got[k].get(f) for f in ("state", "invalidation_reason")})))
lost = sorted(k for k in got if (got[k].get("metadata") or {}).get("verified") != "false")
if lost:
    no("records lost their verified flag: %s" % lost)
state = dict(line.split("=", 1) for line in open(d + "/guard-ui/hindsight-memory-guard.state").read().split())
counts = {k: state.get(k) for k in ("rejected_language", "rejected_duplicate", "rejected_marker", "claims_marked")}
if counts != {"rejected_language": "1", "rejected_duplicate": "1", "rejected_marker": "1", "claims_marked": "5"}:
    no("the tile's state file does not count what the pass did: %s" % counts)
rec = call("POST", b + "/memories/recall", {"query": "private knowledge package planted-pack Slack-App", "max_tokens": 2048})
if {r.get("id") for r in rec.get("results") or []} & {ids["german"], ids["marker"], ids["repeat"]}:
    no("recall still returns a record the guard set aside")
event = json.dumps({"prompt": "Which private knowledge package planted-pack was loaded?", "cwd": d, "session_id": str(uuid.uuid4())})
h = subprocess.run([sys.executable, agent_dir + "/hindsight-recall-hook.py"], input=event, env=env, capture_output=True, text=True,
                   timeout=90)
try:
    block = json.loads(h.stdout)["hookSpecificOutput"]["additionalContext"]
except (ValueError, KeyError, TypeError):
    no("the recall hook injected no block for the bank: rc=%d %s" % (h.returncode, (h.stdout or h.stderr)[:300]))
lines = {line[3:].split("]")[0]: line for line in block.splitlines() if line.startswith("- [")}
for k, tail in (("claim", "; agent claim, not verified)"), ("request", "; not verified)")):
    if not lines.get(ids[k], "").endswith("session %s%s" % (sids[k][:8], tail)):
        no("the recall hook's line for the %s does not end 'session %s%s': %s" % (k, sids[k][:8], tail, lines.get(ids[k], "absent")))
print("one pass rewrote the agent's claim as 'The agent said: ...' (agent claim, not verified, its session and time), kept the "
      "user's request and two English records (one quoting German, one listing hosts), marked a request followed by the "
      "agent's account as its claim, invalidated the German record, the "
      "REF-ID marker and the repeat with their reasons; all %d keep "
      "verified=false; recall returns none of the three; the recall hook marks the claim 'agent claim, not verified' and the "
      "request 'not verified'" % len(texts))
PY
) || fail "the session guard against the test-local memory API: ${GUARD_SUMMARY}"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X DELETE "http://127.0.0.1:${UI_PORT_HINDSIGHT_API}/v1/default/banks/coding-agent%3A%3At16-session-guard")
[ "${HTTP}" == "200" ] || [ "${HTTP}" == "204" ] || fail "the session guard's test bank could not be deleted (http=${HTTP})"
GUARD_BANK_CLEANUP=""
echo "ok 3 - the session guard against the test-local memory API: ${GUARD_SUMMARY}"
LIVE_LINKS=$(grep -oE '<li class="tile" [^>]*><span class="dot"></span><a [^>]*>' "${PAGE}" | wc -l)
NEWTAB_LINKS=$(grep -oE '<li class="tile" [^>]*><span class="dot"></span><a [^>]*target="_blank" rel="opener"[^>]*>' "${PAGE}" | wc -l)
[ "${LIVE_LINKS}" -ge 10 ] && [ "${LIVE_LINKS}" == "${NEWTAB_LINKS}" ] || fail "not every live tile link opens in a new tab (${NEWTAB_LINKS} of ${LIVE_LINKS})"
[ "${N}" -ge 10 ] || fail "only ${N} live tiles were probed - the inventory shrank (expected at least 10)"
"${AGENT_DIR}/ui-status.sh" > ${D}/status.log 2>&1 || { cat ${D}/status.log; fail "ui-status.sh reports a UI not up"; }
grep -q "^claude-mem: UP" ${D}/status.log || fail "ui-status.sh has no UP row for claude-mem: $(cat ${D}/status.log)"
grep -q "^loglearner: UP" ${D}/status.log || fail "ui-status.sh has no UP row for loglearner: $(cat ${D}/status.log)"
grep -q "^tmux-agent: UP" ${D}/status.log || fail "ui-status.sh has no UP row for tmux-agent: $(cat ${D}/status.log)"
echo "ok 3 - ${N} live tiles answer 2xx/3xx through 127.0.0.1:${UI_PORT_HOME}; ui-status.sh all UP"

# --- 7. Host allowlist and probe hardening (while everything is still up) ---
for P in / /tmux/ /headlamp/ /memory-api/docs /__probe/kanban; do
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: evil.example:${UI_PORT_HOME}" "${H}${P}")
	[ "${HTTP}" == "421" ] || fail "a foreign Host (evil.example) got ${HTTP} on ${P} through the proxy - the DNS-rebinding route is open (expected 421)"
done
for HN in "localhost:${UI_PORT_HOME}" "127.0.0.1:${UI_PORT_HOME}"; do
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: ${HN}" "${H}/tmux/")
	[ "${HTTP}" == "200" ] || fail "Host ${HN} got ${HTTP} on /tmux/ (the loopback names must answer)"
done
HTTP=$(curl -s -o ${D}/probe-body.out -w '%{http_code} %{size_download}' --max-time 5 -H 'Cookie: planted=1' "${H}/__probe/kanban")
[ "${HTTP}" == "204 0" ] || fail "the dot probe is not status-only (expected '204 0', got '${HTTP}')"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "${H}/__probe/kanban")
[ "${HTTP}" == "403" ] || fail "a POST to the dot probe was not refused (expected 403, got ${HTTP})"
( export UI_HOME_HOSTNAMES=agent.example,other.example; "${AGENT_DIR}/home-render.sh" > /dev/null ) || fail "home-render.sh (UI_HOME_HOSTNAMES)"
grep -qE 'server_name localhost 127\.0\.0\.1 \[::1\] agent\.example other\.example;' "${UI_DIR}/home/nginx.conf" \
	|| fail "UI_HOME_HOSTNAMES did not render into the home server's allowlist: $(grep server_name "${UI_DIR}/home/nginx.conf" | head -3)"
grep -qE '^\s+server_name _;' "${UI_DIR}/home/nginx.conf" && grep -qE '^\s+return 421;' "${UI_DIR}/home/nginx.conf" \
	|| fail "the 421 default server is gone from the rendered config"
# planted control: entries that would reopen the listener (a regex, a wildcard, the catch-all) or
# are malformed (a bad character, a leading hyphen) are refused and left out; a plain name next to
# them survives (space and comma are separators by design)
( export UI_HOME_HOSTNAMES='~.,*.evil.example,_,ok.example,bad!name,-leading.example,*'; "${AGENT_DIR}/home-render.sh" > /dev/null 2> ${D}/render-bad.err ) || fail "home-render.sh (planted UI_HOME_HOSTNAMES)"
grep -qE 'server_name localhost 127\.0\.0\.1 \[::1\] ok\.example;' "${UI_DIR}/home/nginx.conf" \
	|| fail "the planted UI_HOME_HOSTNAMES entries were not filtered down to the plain name (a bare * must not expand to file names): $(grep 'server_name localhost' "${UI_DIR}/home/nginx.conf")"
[ "$(grep -c "refused" ${D}/render-bad.err)" -eq 6 ] || fail "home-render.sh did not report the refused UI_HOME_HOSTNAMES entries: $(cat ${D}/render-bad.err)"
"${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh (defaults, re-render)"
echo "ok 7 - foreign Host -> 421 on /, /tmux/, /headlamp/, /memory-api/docs and a probe; loopback names answer; probes status-only (204, empty) and GET-only (POST 403); UI_HOME_HOSTNAMES renders into the allowlist"

# --- 8. backends on loopback only; only loopback and the gateway may connect to the proxy ---
command -v ss > /dev/null || fail "ss is not installed (iproute2) - cannot list the listeners"
for ENTRY in headlamp:${UI_PORT_HEADLAMP} hindsight-api:${UI_PORT_HINDSIGHT_API} hindsight-ui:${UI_PORT_HINDSIGHT_UI} \
             vibe-kanban:${UI_PORT_VIBE_KANBAN} ttyd:${UI_PORT_TMUX} comms:${COMMS_UI_PORT} tmux-agent:${UI_PORT_TMUX_AGENT} \
             claude-mem:${UI_PORT_CLAUDE_MEM} loglearner:${UI_PORT_LOGLEARNER}; do
	ADDRS=$(ss -ltnH "sport = :${ENTRY#*:}" | awk '{print $4}')
	[ -n "${ADDRS}" ] || fail "no listener on ${ENTRY#*:} (${ENTRY%%:*})"
	echo "${ADDRS}" | grep -qvE '^(127\.0\.0\.1:|\[::1\]:)' && fail "${ENTRY%%:*} listens beyond loopback inside the container: ${ADDRS} (a neighbour container could reach it)"
done
# nothing but the home port may listen on all interfaces - this catches an upstream's extra port too
# (vibe-kanban opens a second one; it follows the same HOST) and any backend added without the rule
WIDE=$(ss -ltnH | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | grep -vE ":${UI_PORT_HOME}$" || true)
[ -z "${WIDE}" ] || fail "listeners on all interfaces besides the home port ${UI_PORT_HOME}: $(echo ${WIDE} | tr '\n' ' ')"
ss -ltnH "sport = :${UI_PORT_HOME}" | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*):' || fail "the home proxy is not on all interfaces in this test (ss: $(ss -ltnH "sport = :${UI_PORT_HOME}" | awk '{print $4}' | tr '\n' ' '))"
# the container's own non-loopback address stands in for a neighbour: a connection to it has that
# address as its source - neither loopback nor the gateway - and must be refused
SELF_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
# Requests to SELF_IP skip any proxy in the environment (--noproxy): a Docker Sandbox sets HTTP_PROXY with a
# NO_PROXY of loopback names only, and its egress proxy would answer 403 itself - the refusals below would then pass
# without reaching nginx, and the 421 and 200 would fail. What is under test is the home listener, not the egress.
[ -n "${SELF_IP}" ] || fail "no non-loopback address on this container to probe from"
# (a loopback Host, so the Host allowlist is satisfied and the SOURCE rule is what answers; without it
# the 421 default server refuses first - also a refusal, asserted below)
# the allow list is exactly the default route's gateway(s) read from the routing table - no subnet-derived
# address (a network with a custom gateway has a neighbour holding .1), and never the container's own address
RT_GWS=$(ip -4 route show default 2>/dev/null | awk '$1 == "default" && $2 == "via" {print $3}' | sort -u | tr '\n' ' ')
[ -n "${RT_GWS}" ] || fail "no default route in this container to compare the allow list with"
for GW in ${RT_GWS}; do
	grep -qE "^\s*allow ${GW//./\\.};" "${UI_DIR}/home/nginx.conf" || fail "the default route's gateway ${GW} is not in the home listener's allow list (the host's published port would be refused): $(grep -E '^\s*allow ' "${UI_DIR}/home/nginx.conf" | tr -s ' \t\n' ' ')"
done
RENDERED_GWS=$(grep -E '^\s*allow ' "${UI_DIR}/home/nginx.conf" | awk '{print $2}' | tr -d ';' | grep -vE '^(127\.0\.0\.1|::1)$' | sort -u | tr '\n' ' ')
[ "${RENDERED_GWS}" == "$(echo ${RT_GWS} | tr ' ' '\n' | sort -u | tr '\n' ' ')" ] || fail "the home listener admits more than the default route's gateway(s) [${RT_GWS}]: [${RENDERED_GWS}]"
grep -qE "^\s*allow ${SELF_IP//./\\.};" "${UI_DIR}/home/nginx.conf" && fail "the home listener admits the container's own address"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -H "Host: localhost:${UI_PORT_HOME}" "http://${SELF_IP}:${UI_PORT_HOME}/")
[ "${HTTP}" == "403" ] || fail "a connection from a non-loopback source (${SELF_IP}) was not refused by the home listener (expected 403, got ${HTTP}) - a neighbour container could reach the harness"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -H "Host: localhost:${UI_PORT_HOME}" "http://${SELF_IP}:${UI_PORT_HOME}/tmux/")
[ "${HTTP}" == "403" ] || fail "the terminal route answered a non-loopback source (expected 403, got ${HTTP})"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' "http://${SELF_IP}:${UI_PORT_HOME}/")
[ "${HTTP}" == "421" ] || fail "a non-loopback source with its own address as Host got ${HTTP} (expected 421 from the Host allowlist)"
grep -qE '^\s+allow 127\.0\.0\.1;' "${UI_DIR}/home/nginx.conf" && grep -qE '^\s+deny all;' "${UI_DIR}/home/nginx.conf" || fail "the allow/deny block is gone from the rendered config"
# control: the knob - the same address listed in UI_HOME_ALLOW_FROM is admitted after a reload, and
# refused again once the default config is back; junk entries never make it into the config
( export UI_HOME_ALLOW_FROM="${SELF_IP},evil.example,0.0.0.0/0,::/0,10.0.0.0/8,999.1.1.1,10.0.0.0/1,fd00::/7"; "${AGENT_DIR}/home-render.sh" > /dev/null 2> ${D}/render-allow.err ) || fail "home-render.sh (UI_HOME_ALLOW_FROM)"
nginx -t -c "${UI_DIR}/home/nginx.conf" > /dev/null 2>&1 || fail "the rendered config with the planted UI_HOME_ALLOW_FROM entries does not pass nginx -t (a bad entry would take the home page down): $(nginx -t -c "${UI_DIR}/home/nginx.conf" 2>&1 | tail -2)"
grep -qE "^\s+allow ${SELF_IP};" "${UI_DIR}/home/nginx.conf" || fail "UI_HOME_ALLOW_FROM did not render ${SELF_IP} into the config"
grep -qE '^\s+allow 10\.0\.0\.0/8;' "${UI_DIR}/home/nginx.conf" || fail "UI_HOME_ALLOW_FROM did not render a CIDR"
grep -qE 'allow (evil\.example|0\.0\.0\.0/0|::/0|999\.1\.1\.1|10\.0\.0\.0/1|fd00::/7);' "${UI_DIR}/home/nginx.conf" && fail "a junk, out-of-range or near-/0 UI_HOME_ALLOW_FROM entry reached the config"
[ "$(grep -c refused ${D}/render-allow.err)" -eq 6 ] || fail "home-render.sh did not refuse the six bad UI_HOME_ALLOW_FROM entries (junk name, /0, ::/0, 999.1.1.1, /1, IPv6 /7): $(cat ${D}/render-allow.err)"
nginx -c "${UI_DIR}/home/nginx.conf" -s reload || fail "nginx reload (allow)"
sleep 1
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -H "Host: localhost:${UI_PORT_HOME}" "http://${SELF_IP}:${UI_PORT_HOME}/")
[ "${HTTP}" == "200" ] || fail "an address listed in UI_HOME_ALLOW_FROM was still refused (expected 200, got ${HTTP})"
"${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh (defaults, re-render)"
nginx -c "${UI_DIR}/home/nginx.conf" -s reload || fail "nginx reload (defaults)"
sleep 1
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --noproxy '*' -H "Host: localhost:${UI_PORT_HOME}" "http://${SELF_IP}:${UI_PORT_HOME}/")
[ "${HTTP}" == "403" ] || fail "after the re-render the non-loopback source was admitted again (expected 403, got ${HTTP})"
echo "ok 8 - every backend listens on 127.0.0.1 only and nothing but the home port is on all interfaces; the allow list is exactly the default route's gateway(s) [${RT_GWS}]; the proxy refuses a non-loopback source (403) on / and /tmux/, admits it once UI_HOME_ALLOW_FROM lists it, refuses it again after; junk, /0, out-of-range and near-/0 entries never reach the config (nginx -t passes)"

# --- 8b. planted controls: the gateway comes from the routing table, and follows it ---
# (a) a network with a custom gateway, .254, where a neighbour holds .1 (the first address): the allow list
#     must carry .254 and never .1 - the "subnet base + 1" guess an earlier revision made admitted that
#     neighbour to the writable terminal (found in testing)
printf 'default via 172.31.251.254 dev eth0 \n172.31.251.0/24 dev eth0 proto kernel scope link src 172.31.251.2 \n' > ${D}/route-custom-gw
( export UI_HOME_ROUTE_TABLE=${D}/route-custom-gw; "${AGENT_DIR}/home-render.sh" > /dev/null 2>&1 ) || fail "8b: home-render.sh with a planted routing table"
grep -qE '^\s*allow 172\.31\.251\.254;' "${UI_DIR}/home/nginx.conf" || fail "8b: the custom gateway 172.31.251.254 from the planted routing table is not admitted: $(grep -E '^\s*allow ' "${UI_DIR}/home/nginx.conf" | tr -s ' \t\n' ' ')"
grep -qE '^\s*allow 172\.31\.251\.1;' "${UI_DIR}/home/nginx.conf" && fail "8b: the subnet's first address 172.31.251.1 (a neighbour, not the gateway) is admitted - the gateway was guessed from the subnet instead of read from the routing table"
[ "$(UI_HOME_ROUTE_TABLE=${D}/route-custom-gw "${AGENT_DIR}/home-render.sh" --print-gateways)" == "172.31.251.254" ] || fail "8b: --print-gateways does not report the routing table's gateway"
# (b) the watcher: when the default route moves (docker network connect on a running container), the
#     config is re-rendered and nginx reloaded without a restart - planted with a routing-table file
"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1 || true   # (stops everything; the home set is restarted below)
"${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-2.log 2>&1 || { cat ${D}/ui-start-2.log; fail "8b: ui-start.sh (restart for the watcher control)"; }
"${AGENT_DIR}/comms-ui-start.sh" > /dev/null 2>&1
WATCH_PID=$(cat ${UI_DIR}/home-watch.pid 2>/dev/null)
[ -n "${WATCH_PID}" ] && kill -0 "${WATCH_PID}" 2>/dev/null || fail "8b: ui-start.sh did not start the route watcher (no live home-watch.pid)"
kill -TERM -- "-${WATCH_PID}" 2>/dev/null || kill -TERM "${WATCH_PID}" 2>/dev/null; rm -f "${UI_DIR:?}/home-watch.pid"
printf 'default via 10.99.0.1 dev eth0 \n' > ${D}/route-live
( export UI_HOME_ROUTE_TABLE=${D}/route-live; "${AGENT_DIR}/home-render.sh" > /dev/null 2>&1 && nginx -c "${UI_DIR}/home/nginx.conf" -s reload ) || fail "8b: render with the planted live table"
( export UI_HOME_ROUTE_TABLE=${D}/route-live UI_HOME_ROUTE_WATCH_INTERVAL=1; setsid nohup "${AGENT_DIR}/home-route-watch.sh" > ${D}/home-watch-test.log 2>&1 & echo $! > ${D}/home-watch-test.pid )
sleep 2
printf 'default via 10.99.0.254 dev eth1 \n' > ${D}/route-live    # the default route moved
MOVED=false
for i in $(seq 1 20); do grep -qE '^\s*allow 10\.99\.0\.254;' "${UI_DIR}/home/nginx.conf" && { MOVED=true; break; }; sleep 1; done
kill -TERM -- "-$(cat ${D}/home-watch-test.pid)" 2>/dev/null || kill -TERM "$(cat ${D}/home-watch-test.pid)" 2>/dev/null
[ "${MOVED}" == "true" ] || fail "8b: the route watcher did not re-render within 20s of the default route moving: $(cat ${D}/home-watch-test.log)"
grep -qE '^\s*allow 10\.99\.0\.1;' "${UI_DIR}/home/nginx.conf" && fail "8b: the old gateway 10.99.0.1 is still admitted after the route moved"
grep -q "re-rendering and reloading" ${D}/home-watch-test.log || fail "8b: the watcher did not log the re-render: $(cat ${D}/home-watch-test.log)"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${H}/")
[ "${HTTP}" == "200" ] || fail "8b: the home page does not answer after the watcher's reload (http=${HTTP})"
# back to the real table for the remaining checks
"${AGENT_DIR}/home-render.sh" > /dev/null 2>&1 && nginx -c "${UI_DIR}/home/nginx.conf" -s reload || fail "8b: re-render with the real routing table"
echo "ok 8b - planted controls: a routing table with a custom gateway (.254, neighbour at .1) admits .254 only; the route watcher re-renders and reloads within seconds of the default route moving (10.99.0.1 -> 10.99.0.254)"

# --- 4. planted control: a dead upstream reads down ---
LL_PID=$(cat ${UI_DIR}/loglearner.pid 2>/dev/null)
[ -n "${LL_PID}" ] || fail "no loglearner pidfile to plant the control with"
kill -TERM -- "-${LL_PID}" 2>/dev/null || kill -TERM "${LL_PID}" 2>/dev/null
sleep 2
HTTP=$(probe "${H}/" "loglearner.localhost:${UI_PORT_HOME}" 1)
if [ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null; then
	fail "planted control: the stopped LogLearner tile still answers ${HTTP} through the proxy (a dead upstream must read down)"
fi
PHTTP_LL=$(probe "${H}/__probe/loglearner" "" 1)
if [ "${PHTTP_LL}" -ge 200 ] 2>/dev/null && [ "${PHTTP_LL}" -lt 400 ] 2>/dev/null; then
	fail "planted control: the dot's probe /__probe/loglearner still answers ${PHTTP_LL} with the upstream dead (the dot would stay green)"
fi

# --- 4b. planted upstream: the host-route redirect rules, measured ---
# a stand-in on the LogLearner port answers 302 with the Location the request names; through the proxy, with the
# tile's Host header carrying the browser's port (this proxy's, and a DIFFERENT one the way a container published
# on 127.0.0.1:8001 sees it), each Location must come back as the table says: relative and the upstream's own
# loopback address re-hosted onto the tile with the browser's port; an external site, another tile, a
# protocol-relative //host (or /\host), a loopback service on another port left exactly as sent
cat > ${D}/redir-upstream.py << 'PYUP'
import http.server, urllib.parse, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        to = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get('to', [''])[0]
        self.send_response(302); self.send_header('Location', to); self.send_header('Content-Length', '0'); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PYUP
( setsid nohup python3 ${D}/redir-upstream.py "${UI_PORT_LOGLEARNER}" > ${D}/redir-upstream.log 2>&1 & echo $! > ${D}/redir-upstream.pid )
for i in $(seq 1 40); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${UI_PORT_LOGLEARNER}/" 2>/dev/null && break; sleep 0.25; done
redir_stop() { kill -TERM -- "-$(cat ${D}/redir-upstream.pid)" 2>/dev/null || kill -TERM "$(cat ${D}/redir-upstream.pid)" 2>/dev/null; }
redir_case()
{
	# redir_case <Host header> <the upstream's Location> <expected Location through the proxy>
	GOT=$(curl -s -G -D - -o /dev/null --max-time 5 -H "Host: $1" --data-urlencode "to=$2" "${H}/__redir" | grep -i '^location:' | cut -d' ' -f2- | tr -d '\r')
	[ "${GOT}" == "$3" ] || { redir_stop; fail "redirect rules: with Host '$1' the upstream's Location '$2' came back as '${GOT}' - expected '$3'"; }
	RCASES=$((RCASES + 1))
}
RCASES=0
for HH in "loglearner.localhost:${UI_PORT_HOME}" "loglearner.localhost:28001"; do
	redir_case "${HH}" "/dashboard"                                      "http://${HH}/dashboard"
	redir_case "${HH}" "/"                                               "http://${HH}/"
	redir_case "${HH}" "/rel/path?a=1"                                   "http://${HH}/rel/path?a=1"
	redir_case "${HH}" "http://127.0.0.1:${UI_PORT_LOGLEARNER}/self"     "http://${HH}/self"
	redir_case "${HH}" "http://localhost:${UI_PORT_LOGLEARNER}"          "http://${HH}"
	redir_case "${HH}" "https://[::1]:${UI_PORT_LOGLEARNER}/z?q=1"       "http://${HH}/z?q=1"
	redir_case "${HH}" "https://github.com/login/oauth"                  "https://github.com/login/oauth"
	redir_case "${HH}" "http://kanban.localhost:${UI_PORT_HOME}/x"       "http://kanban.localhost:${UI_PORT_HOME}/x"
	redir_case "${HH}" "http://localhost.evil.example/x"                 "http://localhost.evil.example/x"
	redir_case "${HH}" "//github.com/login"                              "//github.com/login"
	redir_case "${HH}" '/\github.com/login'                              '/\github.com/login'
	redir_case "${HH}" "http://localhost:3000/callback"                  "http://localhost:3000/callback"
	redir_case "${HH}" "http://127.0.0.1:8888/docs"                      "http://127.0.0.1:8888/docs"
	redir_case "${HH}" "https://[::1]:9443/y"                            "https://[::1]:9443/y"
done
# the planted-control view of the same rules: the stand-in's own address with ANOTHER tile's port must NOT be
# re-hosted (the rule is bound to this location's upstream port, not to any loopback port)
redir_case "loglearner.localhost:${UI_PORT_HOME}" "http://127.0.0.1:${UI_PORT_CLAUDE_MEM}/x" "http://127.0.0.1:${UI_PORT_CLAUDE_MEM}/x"
redir_stop
echo "ok 4b - host-route redirect rules: ${RCASES} planted Locations through the proxy with the browser's port kept (${UI_PORT_HOME} and 28001) - relative and the upstream's own loopback address re-hosted onto the tile; an external site, another tile, //host, /\\host and loopback services on other ports left as sent"
# the memory UI's dot must follow the memory API, not the control plane's own process: with hindsight-api
# stopped the control plane still answers its health path, and the probe reads the API-backed /api/banks
HA_PID=$(cat ${UI_DIR}/hindsight-api.pid 2>/dev/null)
[ -n "${HA_PID}" ] || fail "no hindsight-api pidfile to plant the memory-UI control with"
kill -TERM -- "-${HA_PID}" 2>/dev/null || kill -TERM "${HA_PID}" 2>/dev/null
for i in $(seq 1 30); do kill -0 "${HA_PID}" 2>/dev/null || break; sleep 1; done
PHTTP=$(probe "${H}/__probe/hindsight" "" 1)
if [ "${PHTTP}" -ge 200 ] 2>/dev/null && [ "${PHTTP}" -lt 400 ] 2>/dev/null; then
	fail "planted control: with hindsight-api stopped the memory UI's dot probe still answers ${PHTTP} (the control plane's health path lies about the API; the probe must read /api/banks)"
fi
echo "ok 4 - planted controls: stopped LogLearner reads down through the proxy (host route http=${HTTP}, dot probe http=${PHTTP_LL:-${PHTTP}}); with hindsight-api stopped the memory UI's dot probe reads down (http=${PHTTP})"

# --- 5. everything down ---
"${AGENT_DIR}/ui-stop.sh" > ${D}/ui-stop.log 2>&1
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${H}/" 2>/dev/null)
[ "${HTTP}" == "000" ] || fail "home port still answers after ui-stop.sh (http=${HTTP})"
for NAME in claude-mem loglearner tmux-agent home-watch; do
	[ -f ${UI_DIR}/${NAME}.pid ] && fail "ui-stop.sh left ${NAME}.pid behind"
done
pgrep -f "home-route-watch.sh" > /dev/null && fail "ui-stop.sh left the route watcher running"
echo "ok 5 - ui-stop.sh: home port silent, no pidfiles left"

# --- 6. the agent's real persisted files were never touched ---
[ "$(real_sums)" == "${REAL_BEFORE}" ] || fail "a test-local ui-start.sh changed the agent's real files: before [${REAL_BEFORE}] after [$(real_sums)]"
echo "ok 6 - the real coding-agent.json and settings.json are byte-identical to before the run"
if [ "${TEST_CONTAINER}" == "true" ]; then
	W=$(find /wd -mindepth 1 2>/dev/null | wc -l)
	[ "${W}" -eq 0 ] || fail "the suite so far wrote ${W} entries under the throwaway /wd: $(find /wd -mindepth 1 2>/dev/null | head -5 | tr '\n' ' ') - with the user's wd/ mounted these would be in the checkout"
	echo "ok 6b - nothing under /wd after test1-test16 (the throwaway tmpfs holds ${W} entries)"
fi

echo "Test16 succeeded"
