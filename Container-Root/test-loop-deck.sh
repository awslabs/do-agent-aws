#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the vendored Loop Deck (Container-Root/opt/loop-deck -> /opt/loop-deck in the image) and the way the harness
# serves it: the release tree is the pinned one, the Deck renders this harness's data in harness mode, the server answers
# the page and refuses actions, and the home page routes and lists it. Fully OFFLINE: the Deck is Python standard library,
# the server binds a test-local loopback port, the page is rendered by home-render.sh into a test-local directory.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the vendored tree is the release commit VENDORED.md names: its 21-file sha256 (the recipe in VENDORED.md) equals the
#      recorded one, RELEASE.json carries the recorded source_sha, source_tree and deck_version, and every file the release
#      serves or runs is there; PLANTED: a copy with one byte changed in deck-server.py fails the hash check
#   2. harness mode end to end: the adapter writes a data directory from planted sources and runs the vendored generator,
#      which renders out/status.json and the page's three files there and nowhere else (exit 0); the release's own
#      contract validator accepts the data directory
#   3. deck-server.py on a test port over that out/: GET / is the page (200, text/html), GET /status.json is the generator's
#      JSON, GET /__act says actions are disabled, POST /act answers 403 ("actions are disabled", audited as DENIED-ACT-DISABLED under out/) and the server keeps running;
#      a path outside the served set is not served
#   4. the home page: UI_LOOP_DECK=true renders the loop-deck.localhost server block with the stylesheet location, the
#      redirect rules and badge-host.conf, the probe location for its dot, and a LIVE "Loop Deck" tile on that host whose
#      note names the vendored Deck and the off actions; UI_LOOP_DECK=false renders no block and a greyed tile that says
#      how to turn it on; LOOP_DECK_URL set renders the external tile in the served tile's place (the route stays)
#  4b. through the proxy (when nginx is here - the image ships it): the rendered config serves the Deck's page on
#      loop-deck.localhost; history.jsonl is the Deck's own file while out/ has one and an empty history (200, no
#      lines) while it has none, where the Deck itself answers 404; mermaid.min.js an empty script (200, a comment only)
#      while out/ has none and the placed file once it has one; runs.jsonl stays 404; PLANTED: the same config without
#      the two files' locations answers 404 for each again
#   5. the vendored tree carries no name, id or secret the seed's privacy scan refuses
#   6. ui-status.sh lists the Deck's server, started by ui-start.sh with every other UI off: PLANTED, its process killed by
#      pid, the row reads DOWN and the exit is 1 (the planted kill is the red); started again it reads UP with HTTP 200
#      and the exit is 0; with UI_LOOP_DECK=false the row reads DISABLED and does not count
#   7. ui-stop.sh stops the Deck's server with the other UIs: "loop-deck: stopped (pid N)", its pidfile gone, the process
#      gone and its port silent
#   8. the supervisor (every session off, a pass a second, a cap of 2 and a 1 s cooldown) starts the Deck's server again
#      the way it starts a spoke's session: PLANTED, the server killed by pid, a new server answers within 10 s with one
#      "restart 1/2" line, a notice to the hub, an UP row, and the next pass reads it up; PLANTED, a Deck stopped
#      with ui-stop.sh stays stopped three passes on and reads off; PLANTED, a server that dies at once (its port taken)
#      is started again twice, each start saying it exited at once and why (the log's last line), each restart's
#      notice saying the restart did not start it, then marked stuck with a notice naming that exit, never started
#      again, and its row reads DOWN, with the
#      start grace at 0 three notices in all (two restarts and stuck, none from the pass's health notices); a pid that
#      is gone is read without a line on stderr, by the start and by every supervisor pass
#   9. one start at a time: six loop-deck-start.sh run at once leave one server on the Deck's port, one "started" and
#      five "already running", and the pidfile names that server (PLANTED, the red: a start without its lock)
#  10. a start whose fork has not exec'd yet waits for it, PLANTED with a setsid that keeps, for half a second, a command
#      line naming loop-deck-start.sh and not the server: "started" and exit 0, no sooner than that half second, and
#      the server running
#  11. a start whose fork reads an empty command line, as a process does while it is inside execve (the fork passes
#      through four execs on its way to the server), waits for it, PLANTED with a setsid that is, for half a second,
#      a live process whose command line reads empty: "started" and exit 0, no sooner than that half second, and the
#      server running (a gone() that took an empty command line for a server that is gone said "exited at once",
#      exit 1)
# Test-local: /tmp/loop-deck-smoke-vendored (TEST_LOOP_DECK_DIR); never /wd.

set -u
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
DECK=${LOOP_DECK_DIR:-/opt/loop-deck}; [ -f "${DECK}/deck-server.py" ] || DECK="${BASE_DIR%/}/opt/loop-deck"
D=${TEST_LOOP_DECK_DIR:-/tmp/loop-deck-smoke-vendored}
rm -rf "${D:?}"
mkdir -p ${D}/loop ${D}/slack ${D}/comms ${D}/ui ${D}/data ${D}/mutant
fail() { echo "Test-loop-deck FAILED: $*"; [ -n "${SERVER_PID:-}" ] && kill "${SERVER_PID}" 2>/dev/null; exit 1; }
trap '[ -n "${SERVER_PID:-}" ] && kill "${SERVER_PID}" 2>/dev/null; [ -n "${SUP_PID:-}" ] && kill "${SUP_PID}" 2>/dev/null; [ -n "${LISTENER_PID:-}" ] && kill "${LISTENER_PID}" 2>/dev/null; for c in ${NGINX_CONFS:-}; do nginx -c "${c}" -s stop 2>/dev/null; done' EXIT

# --- 1. the pinned tree ---
[ -f "${DECK}/VENDORED.md" ] || fail "no ${DECK}/VENDORED.md"
for f in deck-server.py generate-loop-viz.py tools/check-contract.py app/index.html app/app.js app/app.css docs/CONTRACT.md RELEASE.json LICENSE README.md examples/registry.json; do
	[ -f "${DECK}/${f}" ] || fail "the vendored Deck lacks ${f}"
done
WANT_SHA=$(grep -oE '21-file sha256 \| `[0-9a-f]{64}`' "${DECK}/VENDORED.md" | grep -oE '[0-9a-f]{64}')
[ -n "${WANT_SHA}" ] || fail "VENDORED.md records no 21-file sha256"
tree_sha() { (cd "$1" && find . -type f ! -name VENDORED.md ! -path '*/__pycache__/*' | sort | xargs -d '\n' sha256sum | sha256sum | cut -d' ' -f1); }
GOT_SHA=$(tree_sha "${DECK}")
[ "${GOT_SHA}" == "${WANT_SHA}" ] || fail "the vendored tree's sha256 ${GOT_SHA} is not VENDORED.md's ${WANT_SHA} (re-vendor with tools/vendor-loop-deck.sh or update the record)"
[ "$(cd "${DECK}" && find . -type f ! -name VENDORED.md ! -path '*/__pycache__/*' | wc -l)" == "21" ] || fail "the vendored tree has $(cd "${DECK}" && find . -type f ! -name VENDORED.md ! -path '*/__pycache__/*' | wc -l) files, the release has 21"
for KEY in source_sha source_tree deck_version; do
	V=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['${KEY}'])" "${DECK}/RELEASE.json")
	grep -qF "${V}" "${DECK}/VENDORED.md" || fail "RELEASE.json's ${KEY} ${V} is not recorded in VENDORED.md"
done
grep -qE '^\| Commit \| `[0-9a-f]{40}`' "${DECK}/VENDORED.md" || fail "VENDORED.md records no release commit"
cp -r "${DECK}" ${D}/mutant/deck && printf 'x' >> ${D}/mutant/deck/deck-server.py
[ "$(tree_sha ${D}/mutant/deck)" != "${WANT_SHA}" ] || fail "PLANTED CONTROL BROKEN: a tree with one byte changed hashes like the pinned one"
echo "ok 1 - the vendored tree is the pinned release: 21 files, sha256 ${GOT_SHA:0:12}..., RELEASE.json's pins recorded; a changed byte is detected"

# --- 2. harness mode end to end: adapter -> generator -> out/ ---
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) FIRE 1 END rc=0 duration=12s outcome=ok" "$(date -u +%Y-%m-%dT%H:%M:%SZ) FIRE 2 END rc=0 duration=9s outcome=ok" > ${D}/loop/loop.log
printf '%s new=0 replies=0 deferred=0 inbox=0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > ${D}/slack/last-watch
printf 'seeded_at=%s\nitems=3\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > ${D}/hindsight-seed.stamp
printf 'state=complete\ndocuments=3/3\n' > ${D}/ui/hindsight-seed.state
OUT=$(AUTONOMY_LOOP_DIR=${D}/loop SLACK_DIR=${D}/slack COMMS_DIR=${D}/comms HINDSIGHT_SEED_STAMP=${D}/hindsight-seed.stamp HINDSIGHT_SEED_STATE=${D}/ui/hindsight-seed.state \
	LOOP_DECK_DATA_DIR=${D}/data AUTONOMY_LOOP_INTERVAL=120 AUTONOMY_LOOP=true SLACK_WATCH_ENABLED=true SLACK_CHAT_ENABLED=false COMMS_WATCH_ENABLED=false KANBAN_BOARD_URL= PLANE_URL= HINDSIGHT_SEED=true \
	PYTHONDONTWRITEBYTECODE=1 python3 -I "${AGENT_DIR}/loop-deck-adapter.py" --generator "${DECK}/generate-loop-viz.py" 2>&1) || fail "adapter + generator exited non-zero: ${OUT}"
for f in status.json index.html app.js app.css; do [ -f "${D}/data/out/${f}" ] || fail "the generator did not write out/${f}: ${OUT}"; done
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d, dict) and d else 1)" ${D}/data/out/status.json || fail "out/status.json is not a JSON object"
[ "$(find ${D}/data -newer ${D}/loop/loop.log -type f | grep -v '/out/' | grep -vcE 'registry.json|runs.jsonl|loop-ledger.json|state.json')" == "0" ] || fail "the generator wrote outside out/: $(find ${D}/data -newer ${D}/loop/loop.log -type f | grep -v '/out/' | tr '\n' ' ')"
PYTHONDONTWRITEBYTECODE=1 python3 -I "${DECK}/tools/check-contract.py" ${D}/data > ${D}/contract.out 2>&1 || fail "the release's validator refuses the adapter's data directory: $(cat ${D}/contract.out)"
echo "ok 2 - harness mode: the adapter's data directory renders out/status.json and the page's files, nothing outside out/, and passes the release's contract validator"

# --- 3. the server ---
PORT=$(( 18100 + RANDOM % 400 ))
( cd ${D}/data && env -u LOOP_DECK_ACT_TOKEN PYTHONDONTWRITEBYTECODE=1 LOOP_DECK_MODE=harness LOOP_DECK_DATA_DIR=${D}/data python3 -I "${DECK}/deck-server.py" --port ${PORT} --root ${D}/data/out > ${D}/server.log 2>&1 & echo $! > ${D}/server.pid )
SERVER_PID=$(cat ${D}/server.pid)
for i in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${PORT}/" && break; sleep 0.2; done
H=http://127.0.0.1:${PORT}
[ "$(curl -s -o ${D}/page.html -w '%{http_code} %{content_type}' --max-time 5 ${H}/)" == "200 text/html" ] || fail "GET / is not the page (200 text/html): $(tail -3 ${D}/server.log)"
grep -qi '<html' ${D}/page.html || fail "GET / did not return html"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 ${H}/status.json)" == "200" ] || fail "GET /status.json is not 200"
curl -s --max-time 5 ${H}/__act | grep -q '"enabled": *false' || fail "GET /__act does not say actions are disabled: $(curl -s ${H}/__act)"
ACT=$(curl -s -o ${D}/act.out -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:${PORT}" -d '{"verb":"rerun-viz","slug":"autonomy-loop"}' ${H}/act)
[ "${ACT}" == "403" ] || fail "POST /act answered ${ACT}, not 403 (actions must be off without LOOP_DECK_ACT_TOKEN): $(cat ${D}/act.out)"
grep -q 'actions are disabled' ${D}/act.out || fail "the 403 does not say actions are disabled: $(cat ${D}/act.out)"
AUDIT=$(grep -rl 'DENIED-ACT-DISABLED' ${D}/data/out 2>/dev/null | head -1)
[ -n "${AUDIT}" ] || fail "the refused POST left no DENIED-ACT-DISABLED audit record under out/: $(ls ${D}/data/out | tr '\n' ' ')"
kill -0 "${SERVER_PID}" 2>/dev/null || fail "the server died on the refused POST: $(tail -3 ${D}/server.log)"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 ${H}/../../etc/passwd)" != "200" ] || fail "a path outside the served set was served"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 ${H}/registry.json)" != "200" ] || fail "the adapter's input file was served from the Deck (only out/ is the root)"
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""
echo "ok 3 - deck-server.py: the page and status.json answer, /__act says disabled, POST /act is 403 (audited DENIED-ACT-DISABLED) and the server stays up, inputs and paths outside out/ are not served"

# --- 4. the home page ---
render() { UI_DIR=$1 LOOP_DECK_DIR=${DECK} "${AGENT_DIR}/home-render.sh" > $1.render.out 2>&1 || fail "home-render.sh ($2): $(cat $1.render.out)"; }
UI_LOOP_DECK=true render ${D}/ui-on "UI_LOOP_DECK=true"
CONF=${D}/ui-on/home/nginx.conf; PAGE=${D}/ui-on/home/site/index.html
BLOCK=$(sed -n '/server_name loop-deck.localhost;/,/^\t}/p' ${CONF})
[ -n "${BLOCK}" ] || fail "no loop-deck.localhost server block in the rendered nginx.conf"
echo "${BLOCK}" | grep -q 'location = /__harness/harness.css' || fail "the loop-deck route lacks the stylesheet location"
echo "${BLOCK}" | grep -q 'badge-host.conf' || fail "the loop-deck route lacks the home badge (badge-host.conf)"
echo "${BLOCK}" | grep -qE 'proxy_pass http://127.0.0.1:[0-9]+;' || fail "the loop-deck route does not proxy a loopback port"
grep -q 'location = /__probe/loop-deck' ${CONF} || fail "no probe location for the Loop Deck tile's dot"
grep -q 'data-host="loop-deck" data-probe="/__probe/loop-deck"' ${PAGE} || fail "the home page has no live Loop Deck tile probed on the loop-deck host"
grep -oE '<li class="tile" data-host="loop-deck"[^<]*<span class="dot"></span><a [^>]*>Loop Deck</a>' ${PAGE} | grep -q . || fail "the Loop Deck tile is not a live tile titled Loop Deck"
grep -qF "the Deck shipped in the image (/opt/loop-deck, harness mode)" ${PAGE} || fail "the Loop Deck tile's note does not name the vendored Deck"
grep -qF "actions are off (every POST /act answers 403)" ${PAGE} || fail "the Loop Deck tile's note does not say actions are off"
UI_LOOP_DECK=false render ${D}/ui-off "UI_LOOP_DECK=false"
grep -q 'server_name loop-deck.localhost' ${D}/ui-off/home/nginx.conf && fail "UI_LOOP_DECK=false still renders the loop-deck route"
grep -oE '<li class="tile off"[^<]*<span class="dot"></span><span class="title">Loop Deck</span>.{0,200}' ${D}/ui-off/home/site/index.html | grep -q 'off - set UI_LOOP_DECK=true' || fail "UI_LOOP_DECK=false does not grey the tile with how to turn it on: $(grep -oE 'Loop Deck</span>.{0,160}' ${D}/ui-off/home/site/index.html | head -1)"
LOOP_DECK_URL='http://localhost:8091/' UI_LOOP_DECK=true render ${D}/ui-ext "LOOP_DECK_URL set"
grep -q 'rel="noopener noreferrer">Fleet Loop Deck</a>' ${D}/ui-ext/home/site/index.html || fail "LOOP_DECK_URL did not render the external tile"
grep -q 'data-host="loop-deck"' ${D}/ui-ext/home/site/index.html && fail "the served tile is still on the page next to the external one"
grep -q 'server_name loop-deck.localhost' ${D}/ui-ext/home/nginx.conf || fail "LOOP_DECK_URL removed the served route (it must stay; only the tile changes)"
if command -v nginx > /dev/null; then nginx -t -c ${CONF} > ${D}/nginx-t.out 2>&1 || fail "the rendered nginx.conf with the loop-deck route is invalid: $(tail -2 ${D}/nginx-t.out)"; fi
echo "ok 4 - home page: the loop-deck.localhost route with stylesheet, badge and probe, a live Loop Deck tile naming the vendored Deck and its off actions; off: no route, a greyed tile with the flag; LOOP_DECK_URL: the external tile replaces the served one, the route stays"

# --- 4b. through the proxy: the Deck's optional files ---
if command -v nginx > /dev/null; then
	NGINX_CONFS=""
	pxstart() { UI_PORT_HOME=$2 UI_LISTEN_HOST=127.0.0.1 UI_PORT_LOOP_DECK=${PORT} UI_LOOP_DECK=true render $1 "$3"; [ -z "${4:-}" ] || sed -i "$4" $1/home/nginx.conf
		nginx -c $1/home/nginx.conf > $1.nginx.out 2>&1 || fail "nginx did not start on the rendered config ($3): $(tail -3 $1.nginx.out)"; NGINX_CONFS="${NGINX_CONFS} $1/home/nginx.conf"
		for i in $(seq 1 50); do curl -s -o /dev/null --max-time 1 -H 'Host: loop-deck.localhost' "http://127.0.0.1:$2/" && break; sleep 0.2; done; }
	px() { curl -s -o $3 -w '%{http_code}' --max-time 5 -H 'Host: loop-deck.localhost' "http://127.0.0.1:$1$2"; }
	HP=$(( 18600 + RANDOM % 300 ))
	pxstart ${D}/ui-live ${HP} "the proxy over the test server"
	[ "$(px ${HP} / ${D}/px-page.html)" == "200" ] && grep -q '<title>Loop Deck' ${D}/px-page.html || fail "the Deck's page does not answer through the proxy"
	# history.jsonl: the Deck's own file while out/ has one, an empty history (200, no lines) while it has none
	[ -s ${D}/data/out/history.jsonl ] || fail "check 2's run left no out/history.jsonl to pass through"
	[ "$(px ${HP} /history.jsonl ${D}/px-history.jsonl)" == "200" ] && cmp -s ${D}/px-history.jsonl ${D}/data/out/history.jsonl || fail "the proxy does not pass the Deck's own history.jsonl through"
	mv "${D:?}/data/out/history.jsonl" "${D:?}/history.jsonl.saved"
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 ${H}/history.jsonl)" == "404" ] || fail "with no out/history.jsonl the Deck itself does not answer 404 - the case the route covers"
	[ "$(px ${HP} /history.jsonl ${D}/px-history-none)" == "200" ] && [ ! -s ${D}/px-history-none ] || fail "with no out/history.jsonl the proxy does not answer an empty history (200, no lines): $(head -c 200 ${D}/px-history-none)"
	# mermaid.min.js: an empty script while out/ has none, the file itself once one is placed there
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 ${H}/mermaid.min.js)" == "404" ] || fail "with no out/mermaid.min.js the Deck itself does not answer 404 - the case the route covers"
	[ "$(curl -s -o ${D}/px-mermaid.js -w '%{http_code} %{content_type}' --max-time 5 -H 'Host: loop-deck.localhost' http://127.0.0.1:${HP}/mermaid.min.js)" == "200 application/javascript" ] || fail "with no out/mermaid.min.js the proxy does not answer a script (200 application/javascript)"
	grep -qvE '^/\*.*\*/$' ${D}/px-mermaid.js && fail "the proxy's stand-in mermaid.min.js is more than a comment: $(head -c 200 ${D}/px-mermaid.js)"
	printf 'window.plantedMermaid = 1;\n' > ${D}/data/out/mermaid.min.js
	[ "$(px ${HP} /mermaid.min.js ${D}/px-mermaid-placed.js)" == "200" ] && cmp -s ${D}/px-mermaid-placed.js ${D}/data/out/mermaid.min.js || fail "a mermaid.min.js placed in out/ is not passed through"
	rm -f "${D:?}/data/out/mermaid.min.js"
	[ "$(px ${HP} /runs.jsonl /dev/null)" == "404" ] || fail "the proxy serves runs.jsonl, a path outside the Deck's allowlist"
	# PLANTED: the same config without the locations answers the Deck's 404 again
	HP2=$(( HP + 300 ))
	pxstart ${D}/ui-planted ${HP2} "planted: no optional-file locations" '/location = \/history.jsonl {/,/^\t\t}/d; /location @loop_deck_no_history {/,/^\t\t}/d; /location = \/mermaid.min.js {/,/^\t\t}/d; /location @loop_deck_no_mermaid {/,/^\t\t}/d'
	grep -q 'location = /history.jsonl' ${D}/ui-planted/home/nginx.conf && fail "PLANTED CONTROL: the history.jsonl location was not removed from the planted config"
	[ "$(px ${HP2} /history.jsonl /dev/null)" == "404" ] || fail "PLANTED CONTROL: without its location the proxy still answers history.jsonl"
	grep -q 'location = /mermaid.min.js' ${D}/ui-planted/home/nginx.conf && fail "PLANTED CONTROL: the mermaid.min.js location was not removed from the planted config"
	[ "$(px ${HP2} /mermaid.min.js /dev/null)" == "404" ] || fail "PLANTED CONTROL: without its location the proxy still answers mermaid.min.js"
	mv "${D:?}/history.jsonl.saved" "${D:?}/data/out/history.jsonl"
	for c in ${NGINX_CONFS}; do nginx -c ${c} -s stop 2> /dev/null; done; NGINX_CONFS=""
	echo "ok 4b - through the proxy: the Deck's page; history.jsonl passed through while out/ has it and an empty history (200) while it has none, mermaid.min.js an empty script (200) until a placed file passes through, where the Deck answers 404 for each; runs.jsonl stays 404; PLANTED: without the locations the proxy answers 404 for both again"
else
	echo "skipped 4b - no nginx here (the image ships it): the proxy's answers for the Deck's optional files are not exercised"
fi

# --- 5. privacy ---
SCAN=/seed/scan.py; [ -f "${SCAN}" ] || SCAN="${BASE_DIR%/}/seed/scan.py"
python3 -I "${SCAN}" --tree "${DECK}" > ${D}/scan.out 2>&1 || fail "the vendored Loop Deck tree fails the privacy scan: $(tail -3 ${D}/scan.out)"
echo "ok 5 - the vendored tree passes the privacy scan ($(tail -1 ${D}/scan.out))"

# --- 6. ui-status.sh lists the Deck's server ---
# free_port - a loopback port nothing listens on now
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
P6=$(free_port)
# every other UI and the boards off, the supervisor off, the state test-local: ui-start.sh starts the Deck alone
DECK_ENV=(UI_DIR=${D}/ui-keep UI_START=true UI_HOME=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false
	UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_CHAT=false UI_BOARD=false UI_FILES=false UI_PLANE=false
	COMMS_UI_ENABLED=false PLANE_URL= KANBAN_BOARD_URL= UI_LOOP_DECK=true UI_PORT_LOOP_DECK=${P6} LOOP_DECK_DIR=${DECK}
	LOOP_DECK_DATA_DIR=${D}/data6 SUPERVISOR=false SUPERVISOR_DIR=${D}/sup6 AUTONOMY_LOOP_DIR=${D}/loop SLACK_DIR=${D}/slack
	COMMS_DIR=${D}/comms HINDSIGHT_SEED_STAMP=${D}/hindsight-seed.stamp HINDSIGHT_SEED_STATE=${D}/ui/hindsight-seed.state)
# deck_start <log> - ui-start.sh with only the Deck on; SERVER_PID its server, answering
deck_start()
{
	env "${DECK_ENV[@]}" "${AGENT_DIR}/ui-start.sh" > "$1" 2>&1 || fail "ui-start.sh with only the Deck on: $(tail -3 "$1")"
	grep -q '^loop-deck: started (pid [0-9]*' "$1" || fail "ui-start.sh did not start the Deck: $(cat "$1")"
	SERVER_PID=$(cat ${D}/ui-keep/loop-deck.pid)
	for i in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${P6}/status.json" && break; sleep 0.2; done
}
# deck_alive <pid> - the pid is a running Deck server (a killed one that no process has reaped yet has no command line)
deck_alive() { tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline" | grep -q deck-server.py; }
# deck_kill - the Deck's server killed by its pid, and gone
deck_kill()
{
	kill "${SERVER_PID}" 2>/dev/null
	for i in $(seq 1 50); do deck_alive "${SERVER_PID}" || break; sleep 0.1; done
	deck_alive "${SERVER_PID}" && fail "the Deck's server outlived its kill"
	SERVER_PID=""
}
# PLANTED: the server killed - DOWN and exit 1
deck_start ${D}/ui-start6.log
deck_kill
OUT=$(env "${DECK_ENV[@]}" "${AGENT_DIR}/ui-status.sh" 2>&1) && fail "ui-status.sh exits 0 with the Deck's server killed: ${OUT}"
echo "${OUT}" | grep -qx "loop-deck: DOWN port=${P6}" || fail "ui-status.sh has no DOWN row for the killed Deck's server: ${OUT}"
# started again - UP, exit 0
deck_start ${D}/ui-start6b.log
OUT=$(env "${DECK_ENV[@]}" "${AGENT_DIR}/ui-status.sh" 2>&1) || fail "ui-status.sh exits non-zero with the Deck up: ${OUT}"
echo "${OUT}" | grep -qx "loop-deck: UP pid=${SERVER_PID} http=200 port=${P6}" || fail "ui-status.sh has no UP row for the Deck's server: ${OUT}"
# off (no server running, as with UI_LOOP_DECK=false) - DISABLED, not counted
deck_kill
OUT=$(env "${DECK_ENV[@]}" UI_LOOP_DECK=false "${AGENT_DIR}/ui-status.sh" 2>&1) || fail "ui-status.sh exits non-zero with the Deck off: ${OUT}"
echo "${OUT}" | grep -qx "loop-deck: DISABLED" || fail "ui-status.sh has no DISABLED row with UI_LOOP_DECK=false: ${OUT}"
echo "ok 6 - ui-status.sh lists the Deck's server: killed by pid, DOWN and exit 1; started again by ui-start.sh, UP (http 200, exit 0); UI_LOOP_DECK=false, DISABLED and not counted"

# --- 7. ui-stop.sh stops the Deck's server ---
deck_start ${D}/ui-start7.log
deck_alive "${SERVER_PID}" || fail "the Deck's server did not start for check 7: $(cat ${D}/ui-start7.log)"
env "${DECK_ENV[@]}" "${AGENT_DIR}/ui-stop.sh" > ${D}/ui-stop7.log 2>&1
grep -qx "loop-deck: stopped (pid ${SERVER_PID})" ${D}/ui-stop7.log || fail "ui-stop.sh did not stop the Deck's server: $(cat ${D}/ui-stop7.log)"
[ -f ${D}/ui-keep/loop-deck.pid ] && fail "ui-stop.sh left the Deck's pidfile"
for i in $(seq 1 50); do deck_alive "${SERVER_PID}" || break; sleep 0.1; done
deck_alive "${SERVER_PID}" && fail "the Deck's server still runs after ui-stop.sh"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${P6}/status.json")" == "000" ] || fail "the Deck's port still answers after ui-stop.sh"
SERVER_PID=""
echo "ok 7 - ui-stop.sh stops the Deck's server: loop-deck: stopped, its pidfile gone, the process gone, its port silent"

# --- 8. the supervisor starts the Deck's server again when it died, the way it starts a spoke's session ---
mapfile -t ALL_OFF < <(SPOKES_REGISTRY="${AGENT_DIR}/spokes/registry.json" "${AGENT_DIR}/spoke.sh" table | awk '$2 == "spoke" { print $4 "=false" }')
[ "${#ALL_OFF[@]}" -ge 1 ] || fail "the registry's table lists no spoke"
# every session off, a pass a second, a cap of 2 and a 1 s cooldown, the bus and the state test-local
SUP_ENV=("${DECK_ENV[@]}" "${ALL_OFF[@]}" "SPOKES_REGISTRY=${AGENT_DIR}/spokes/registry.json" SUPERVISOR=true SUPERVISOR_INTERVAL=1
	SUPERVISOR_RESTART_CAP=2 SUPERVISOR_DECK_COOLDOWN=1 SUPERVISOR_START_GRACE=600 SUPERVISOR_HEALTHY_SECS=300
	"MAILBOX_STATE_ROOT=${D}/mbx8-state" "MAILBOX_PROJECTION_ROOT=${D}/mbx8" AGENT_TMUX_SESSION=false UI_HINDSIGHT=false UI_CLAUDE_MEM=false)
SUP_PID=""; LISTENER_PID=""
# sup_start <dir> [NAME=value...] - the supervisor's loop in the background with SUPERVISOR_DIR=<dir> (and the settings
# given), its output in <dir>.log; SUP_PID
sup_start()
{
	env "${SUP_ENV[@]}" "${@:2}" SUPERVISOR_DIR="$1" "${AGENT_DIR}/supervisor.sh" run > "$1.log" 2>&1 < /dev/null &
	SUP_PID=$!
	for i in $(seq 1 50); do [ -f "$1/status.json" ] && break; sleep 0.2; done
	[ -f "$1/status.json" ] || fail "the supervisor wrote no pass: $(tail -3 "$1.log")"
}
sup_stop() { kill "${SUP_PID}" 2>/dev/null; wait "${SUP_PID}" 2>/dev/null; SUP_PID=""; }
# wait_line <file> <text> - until <file> has a line with <text> (at most 10 s): the supervisor writes a restart's line
# and its notice after the start returns
wait_line() { for i in $(seq 1 50); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
# deck_health <dir> - the last pass's state of the Deck's server; passes <dir> - the last pass's number
deck_health() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["health"]["loop_deck"]["state"])' "$1/status.json" 2>/dev/null; }
passes() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "$1/status.json" 2>/dev/null; }
# after_passes <dir> <n> - until <n> more passes are written (at most 20 s)
after_passes()
{
	local P0
	P0=$(passes "$1")
	for i in $(seq 1 100); do [ "$(passes "$1")" -ge $(( P0 + $2 )) ] 2>/dev/null && return 0; sleep 0.2; done
	fail "the supervisor did not write $2 more passes: $(tail -3 "$1.log")"
}
S8=${D}/sup8
# a pidfile naming a pid that is gone (a reaped child of this shell): the start reads it without a word on stderr
sh -c 'exit 0' & GONE_PID=$!; wait "${GONE_PID}"
echo "${GONE_PID}" > ${D}/ui-keep/loop-deck.pid
deck_start ${D}/ui-start8.log
grep -q 'No such file or directory' ${D}/ui-start8.log && fail "the Deck's start printed the missing /proc entry of the pid it read: $(grep 'No such file' ${D}/ui-start8.log)"
P1=${SERVER_PID}
sup_start ${S8}
after_passes ${S8} 1
# PLANTED: the server killed by pid - started again at once
deck_kill
P2=""
for i in $(seq 1 50); do P2=$(cat ${D}/ui-keep/loop-deck.pid 2>/dev/null); [ -n "${P2}" ] && [ "${P2}" != "${P1}" ] && deck_alive "${P2}" && break; sleep 0.2; done
{ [ -n "${P2}" ] && [ "${P2}" != "${P1}" ] && deck_alive "${P2}"; } || fail "the supervisor did not start the killed Deck's server again within 10 s: $(tail -3 ${S8}.log)"
SERVER_PID=${P2}
# the new pid is in the pidfile before the start returns (it waits, up to 5 s, until that pid listens on the Deck's
# port), and the line and the notice come after it: wait for them
wait_line "${S8}/loop-deck/restarts.log" "restart 1/2 (its server was gone): loop-deck: started (pid ${P2}, " \
	|| fail "no restart line for the Deck's server: $(cat ${S8}/loop-deck/restarts.log 2>&1)"
wait_line "${S8}.log" "notice: the Loop Deck's server was gone and was started again (restart 1/2)" || fail "no notice to the hub for the restart: $(tail -5 ${S8}.log)"
for i in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${P6}/status.json" && break; sleep 0.2; done
OUT=$(env "${DECK_ENV[@]}" "${AGENT_DIR}/ui-status.sh" 2>&1) || fail "ui-status.sh exits non-zero after the restart: ${OUT}"
echo "${OUT}" | grep -qx "loop-deck: UP pid=${P2} http=200 port=${P6}" || fail "ui-status.sh does not read the restarted Deck's server UP: ${OUT}"
after_passes ${S8} 1
[ "$(deck_health ${S8})" == "up" ] || fail "the supervisor does not read the restarted Deck's server up: '$(deck_health ${S8})'"
# PLANTED: stopped on purpose with ui-stop.sh - it stays stopped
env "${DECK_ENV[@]}" "${AGENT_DIR}/ui-stop.sh" > ${D}/ui-stop8.log 2>&1
grep -qx "loop-deck: stopped (pid ${P2})" ${D}/ui-stop8.log || fail "ui-stop.sh did not stop the restarted Deck's server: $(cat ${D}/ui-stop8.log)"
SERVER_PID=""
after_passes ${S8} 3
[ -f ${D}/ui-keep/loop-deck.pid ] && fail "the supervisor started a Deck stopped with ui-stop.sh again: $(tail -2 ${S8}/loop-deck/restarts.log)"
[ "$(deck_health ${S8})" == "off" ] || fail "a Deck stopped with ui-stop.sh does not read off: '$(deck_health ${S8})'"
[ "$(grep -c ' restart ' ${S8}/loop-deck/restarts.log)" == "1" ] || fail "the supervisor restarted the Deck after its stop: $(cat ${S8}/loop-deck/restarts.log)"
sup_stop
# PLANTED: a server that dies at once (a listener holds its port) - started again twice, then stuck and left alone
mkdir -p ${D}/listener
python3 -m http.server "${P6}" --bind 127.0.0.1 --directory ${D}/listener > ${D}/listener.log 2>&1 &
LISTENER_PID=$!
for i in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${P6}/" && break; sleep 0.2; done
env "${DECK_ENV[@]}" "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start8b.log 2>&1
P3=$(cat ${D}/ui-keep/loop-deck.pid)
for i in $(seq 1 50); do deck_alive "${P3}" || break; sleep 0.1; done
deck_alive "${P3}" && fail "the Deck's server runs although a listener holds its port"
# its start says it exited at once, with the reason its log ends on, and not that it started
grep -qE "^loop-deck: exited at once \(pid ${P3}\): .*Address already in use" ${D}/ui-start8b.log \
	|| fail "the start of a Deck whose port is taken does not say it exited at once and why: $(grep '^loop-deck:' ${D}/ui-start8b.log)"
S8B=${D}/sup8b
# the start grace at 0: the pass's health notices run from the first pass, and must not add one for the Deck; a 2 s
# cooldown, so passes fall inside each backoff
sup_start ${S8B} SUPERVISOR_START_GRACE=0 SUPERVISOR_DECK_COOLDOWN=2
for i in $(seq 1 100); do grep -q ' stuck: ' ${S8B}/loop-deck/restarts.log 2>/dev/null && break; sleep 0.2; done
grep -qF " stuck: it did not stay up 300s through 2 restarts; the last start said: loop-deck: exited at once (pid " ${S8B}/loop-deck/restarts.log \
	|| fail "the Deck's server that dies at once was not marked stuck at the cap, naming its last start's exit: $(cat ${S8B}/loop-deck/restarts.log 2>&1)"
# each restart's notice says the restart did not start it, with the reason, never that it was started again
[ "$(grep -cE "notice: the Loop Deck's server was gone, and restart [12]/2 did not start it: loop-deck: exited at once \(pid [0-9]+\): .*Address already in use" ${S8B}.log)" == "2" ] \
	|| fail "the restarts of a Deck that dies at once are not two notices saying they did not start it: $(grep "notice: the Loop Deck" ${S8B}.log | cut -c1-160 | tr '\n' '|')"
grep -q "notice: the Loop Deck's server was gone and was started again" ${S8B}.log && fail "a restart of the Deck that dies at once was announced as started again"
[ "$(grep -cE ' restart [12]/2 \(its server was gone\)' ${S8B}/loop-deck/restarts.log)" == "2" ] || fail "not two restarts before the cap: $(cat ${S8B}/loop-deck/restarts.log)"
wait_line "${S8B}.log" "notice: the Loop Deck's server is stuck: it did not stay up 300s" || fail "no notice to the hub for the stuck Deck: $(tail -5 ${S8B}.log)"
# one notice per restart and one for the stuck verdict: three, and none from the pass's health notices
[ "$(grep -c "notice: the Loop Deck's server" ${S8B}.log)" == "3" ] \
	|| fail "the Deck that dies at once sent $(grep -c "notice: the Loop Deck's server" ${S8B}.log) notices, not 3 (two restarts, stuck): $(grep "notice: the Loop Deck" ${S8B}.log | cut -c1-110 | tr '\n' '|')"
after_passes ${S8B} 3
[ "$(deck_health ${S8B})" == "stuck" ] || fail "the stuck Deck does not read stuck: '$(deck_health ${S8B})'"
[ "$(grep -c ' restart ' ${S8B}/loop-deck/restarts.log)" == "2" ] || fail "the stuck Deck was started again: $(cat ${S8B}/loop-deck/restarts.log)"
OUT=$(env "${DECK_ENV[@]}" "${AGENT_DIR}/ui-status.sh" 2>&1) && fail "ui-status.sh exits 0 with the stuck Deck: ${OUT}"
echo "${OUT}" | grep -qx "loop-deck: DOWN port=${P6}" || fail "ui-status.sh has no DOWN row for the stuck Deck: ${OUT}"
sup_stop
# every pass read the dead server's pid; none wrote the missing /proc entry to the supervisor's log
grep -q 'No such file or directory' ${S8}.log ${S8B}.log && fail "the supervisor's log carries the missing /proc entry of the Deck's pid: $(grep -h 'No such file' ${S8}.log ${S8B}.log | head -2)"
kill "${LISTENER_PID}" 2>/dev/null; wait "${LISTENER_PID}" 2>/dev/null; LISTENER_PID=""
echo "ok 8 - the supervisor starts the Deck's server again: killed, a new server within 10 s, one restart line, a notice, UP; stopped with ui-stop.sh, left stopped (off); dying at once, started again twice, then stuck with a notice and left alone, DOWN"

# --- 9. one start at a time ---
RACE_ENV=("${DECK_ENV[@]}" "UI_DIR=${D}/ui-race")
mkdir -p ${D}/ui-race
RACE_PIDS=()
for n in 1 2 3 4 5 6; do
	env "${RACE_ENV[@]}" "${AGENT_DIR}/loop-deck-start.sh" > ${D}/race-${n}.out 2>&1 &
	RACE_PIDS+=($!)
done
for p in "${RACE_PIDS[@]}"; do wait "${p}"; done
STARTED=$(cat ${D}/race-*.out | grep -c '^loop-deck: started (pid ')
RUNNING=$(cat ${D}/race-*.out | grep -c '^loop-deck: already running (pid ')
# the Deck servers on this check's port, by their command lines
SERVERS=$(for p in /proc/[0-9]*; do tr '\0' ' ' 2>/dev/null < "${p}/cmdline" | grep -q "deck-server.py --port ${P6} " && echo "${p#/proc/}"; done)
SERVER_PID=$(echo "${SERVERS}" | head -1)
[ "${STARTED}" == "1" ] && [ "${RUNNING}" == "5" ] \
	|| fail "six starts at once: ${STARTED} started, ${RUNNING} already running (expected 1 and 5): $(cat ${D}/race-*.out | cut -c1-90 | tr '\n' '|')"
[ "$(echo "${SERVERS}" | grep -c .)" == "1" ] || fail "six starts at once left $(echo "${SERVERS}" | grep -c .) servers on port ${P6}: $(echo ${SERVERS})"
[ "$(cat ${D}/ui-race/loop-deck.pid)" == "${SERVER_PID}" ] || fail "the pidfile names $(cat ${D}/ui-race/loop-deck.pid), not the one server ${SERVER_PID}"
deck_kill
echo "ok 9 - one start at a time: six loop-deck-start.sh at once left one server, one started and five already running, and the pidfile names it"

# --- 10. a fork that has not exec'd yet is a start under way, not a server that is gone ---
# PLANTED: a setsid on PATH that holds, for half a second, a command line naming loop-deck-start.sh and not the server,
# as the start's fork does before its exec; then the real setsid with the arguments as given
mkdir -p ${D}/slowfork-bin ${D}/ui-slow
command -v setsid > ${D}/slowfork-bin/real-setsid || fail "no setsid on PATH"
cat > ${D}/slowfork-bin/setsid << 'SLOWFORK'
#!/bin/bash
B=$(dirname "$0")
A=$(mktemp -p "${B}")
printf '%s\0' "$@" > "${A}"
SLOWFORK_REAL=$(cat "${B}/real-setsid")
export SLOWFORK_ARGS=${A} SLOWFORK_REAL
exec -a loop-deck-start.sh /bin/bash -c 'sleep 0.5; mapfile -d "" -t ARGS < "${SLOWFORK_ARGS}"; exec "${SLOWFORK_REAL}" "${ARGS[@]}"'
SLOWFORK
chmod +x ${D}/slowfork-bin/setsid
S0=$(date +%s%N)
env "${DECK_ENV[@]}" "UI_DIR=${D}/ui-slow" "PATH=${D}/slowfork-bin:${PATH}" "${AGENT_DIR}/loop-deck-start.sh" > ${D}/start10.out 2>&1
RC=$?
MS=$(( ($(date +%s%N) - S0) / 1000000 ))
SERVER_PID=$(cat ${D}/ui-slow/loop-deck.pid 2>/dev/null)
# started, listening or (on a loaded host) not yet after 5 s; either way after the fork's exec, so not before 500 ms
[ "${RC}" == "0" ] && grep -qxE "loop-deck: started \(pid ${SERVER_PID}, log ${D}/ui-slow/loop-deck.log\)( - not listening on ${P6} after 5 s)?" ${D}/start10.out \
	|| fail "a start whose fork had not exec'd yet is not reported as started (exit ${RC}, ${MS} ms): $(cat ${D}/start10.out)"
[ "${MS}" -ge 500 ] || fail "the start returned after ${MS} ms, before its fork's exec at 500 ms: $(cat ${D}/start10.out)"
deck_alive "${SERVER_PID}" || fail "the server of the start whose fork was slow to exec is not running: $(tail -3 ${D}/ui-slow/loop-deck.log)"
deck_kill
echo "ok 10 - a start whose fork has not exec'd yet waits for it: with a setsid that holds the start script's command line for half a second, started (exit 0) after ${MS} ms and the server running"

# --- 11. a fork whose command line reads empty (inside execve) is a start under way, not a server that is gone ---
# PLANTED: a setsid on PATH that is, for half a second, a live process whose command line reads empty - a bash under an
# empty argv[0] reading its script from a file, as a fork's reads while it is inside execve - then the real setsid with
# the arguments as given
mkdir -p ${D}/blankfork-bin ${D}/ui-blank
command -v setsid > ${D}/blankfork-bin/real-setsid || fail "no setsid on PATH"
cat > ${D}/blankfork-bin/blank.sh << 'BLANK'
sleep 0.5
mapfile -d "" -t ARGS < "${BLANKFORK_ARGS}"
exec "${BLANKFORK_REAL}" "${ARGS[@]}" < /dev/null
BLANK
cat > ${D}/blankfork-bin/setsid << 'BLANKFORK'
#!/bin/bash
B=$(dirname "$0")
A=$(mktemp -p "${B}")
printf '%s\0' "$@" > "${A}"
BLANKFORK_REAL=$(cat "${B}/real-setsid")
export BLANKFORK_ARGS=${A} BLANKFORK_REAL
exec -a '' /bin/bash < "${B}/blank.sh"
BLANKFORK
chmod +x ${D}/blankfork-bin/setsid
S0=$(date +%s%N)
env "${DECK_ENV[@]}" "UI_DIR=${D}/ui-blank" "PATH=${D}/blankfork-bin:${PATH}" "${AGENT_DIR}/loop-deck-start.sh" > ${D}/start11.out 2>&1
RC=$?
MS=$(( ($(date +%s%N) - S0) / 1000000 ))
SERVER_PID=$(cat ${D}/ui-blank/loop-deck.pid 2>/dev/null)
[ "${RC}" == "0" ] && grep -qxE "loop-deck: started \(pid ${SERVER_PID}, log ${D}/ui-blank/loop-deck.log\)( - not listening on ${P6} after 5 s)?" ${D}/start11.out \
	|| fail "a start whose fork read an empty command line is not reported as started (exit ${RC}, ${MS} ms): $(cat ${D}/start11.out)"
[ "${MS}" -ge 500 ] || fail "the start returned after ${MS} ms, before its fork's exec at 500 ms: $(cat ${D}/start11.out)"
deck_alive "${SERVER_PID}" || fail "the server of the start whose fork read an empty command line is not running: $(tail -3 ${D}/ui-blank/loop-deck.log)"
deck_kill
echo "ok 11 - a fork whose command line reads empty, as one inside execve does, is a start under way: with a setsid that is a live process with an empty command line for half a second, started (exit 0) after ${MS} ms and the server running"

echo "Test-loop-deck succeeded"
