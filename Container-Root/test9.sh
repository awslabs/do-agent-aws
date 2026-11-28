#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the harness home page + reverse proxy (/agent/home-render.sh, the UI_HOME /
# UI_TMUX blocks of /agent/ui-start.sh, and the single-port publish contract in .env).
# Fully OFFLINE: everything binds 127.0.0.1 on test-local ports and state directories.
#
# Properties proven (each check FAILS if the property is removed):
#   1. all new/changed scripts parse (bash -n)
#   2. .env defaults: UI_HOME on, tmux terminal on and WRITABLE, tmux-agent dashboard on
#      (the vendored build), claude-mem viewer and LogLearner dashboard on, direct publishes
#      off, comms UI on
#   3. .env publish contract: defaults publish EXACTLY one port, the home port, on loopback (the mapping
#      .env builds from UI_BIND_HOST/PORT_EXTERNAL_HOME/PORT_INTERNAL_HOME, so a changed external port
#      passes); UI_START=false publishes nothing; UI_HOME=false restores the pre-home per-UI direct publishes (every
#      UI, the three newer ones included)
#   4. home-render.sh renders a location block (or host-route server block) ONLY for an
#      enabled UI (a disabled UI is not reachable through the proxy) and greys its home tile
#      with the enabling flag; the claude-mem viewer's server block, and no other, includes the
#      strict Content-Security-Policy (connect-src 'self': the viewer's GitHub star-count fetch
#      to api.github.com is refused by the browser)
#   5. the home page answers 200 at / with the harness title, offline (no external assets)
#   6. every enabled UI answers 2xx/3xx THROUGH the proxy port: /headlamp/,
#      /memory-api/docs (and its "Try it out": a request built from the served openapi.json lands under
#      /memory-api and answers 200), /comms/, /tmux/, and the hindsight.localhost / kanban.localhost /
#      claude-mem.localhost / loglearner.localhost host routes; on the host routes the injected home badge targets
#      //localhost:<the port the browser sent>/ (a bare href="/" would be the app's own
#      root there, not the home page), the port in the Host header is echoed back
#      unchanged (tunnel/port-forward ports keep working), and the path-routed badge
#      stays plain href="/" (control); the claude-mem viewer's response through the proxy
#      carries that policy - CONTROL: the worker's own response carries none
#   7. the tmux terminal is WRITABLE by default: a keystroke planted over the proxied
#      websocket (python3 websockets, the client the image ships; tornado accepted) reaches the
#      tmux pane (the browser drives the agent session) - and a READ-ONLY twin
#      (UI_TMUX_WRITABLE=false) REFUSES the same probe, proving the flag; no client = FAIL, not skip
#      still works and the probe can fail. The probe runs against a TEST-LOCAL session
#      (via AGENT_TMUX_SESSION_NAME, itself shipped wiring) and types WITHOUT a submitting
#      carriage return: the real shared session's pane runs the live interactive claude CLI
#      (/agent/tmux-claude.sh, test12.sh), which must never receive - let alone be sent -
#      test keystrokes; reaching the pane is the property under test
#   7c. the session picker: through the proxy, /tmux/ws?arg=<session> attaches to that session of the container's
#      own tmux server (a keystroke lands in it, not in the agent session), ?arg=pick lists the sessions that
#      exist, a missing name says so honestly and lists them, and -L, -S, a TMUX= override or a path is refused as
#      a session name; CONTROL: the previous fixed attach (no --url-arg) ignores the argument and lands in the
#      agent session
#   7d. a page on another origin cannot drive the terminal (cross-site WebSocket hijacking): through the proxy the
#      handshake with Origin https://evil.example gets 403 and never 101, and the same probe as 7a types nothing into
#      the pane; straight to ttyd's port (ui-start.sh's ttyd, --check-origin) a foreign Origin is not upgraded while
#      the page's own is (CONTROL: the check can tell an upgrade)
#   8. a stopped UI is reported down through the proxy (no false 2xx), and after
#      ui-stop.sh the home port answers nothing
# Uses test-local state directories (/tmp/home-smoke*); does not disturb live state under /wd.

D=/tmp/home-smoke
rm -rf "${D:?}"
mkdir -p ${D}

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"

export UI_DIR=${D}/ui
# the real hooks config and settings are persisted agent state: ui-start.sh keeps coding-agent.json
# on the API port it starts and repairs settings.json, so a test-local run points both at copies
export HINDSIGHT_AGENT_CONF=${D}/coding-agent.json
export CLAUDE_SETTINGS=${D}/settings.json
# the LogLearner runtime's state (banks, ledgers, index) - test-local too, never /wd/loglearner
export LOGLEARNER_STATE=${D}/loglearner
export UI_LISTEN_HOST=127.0.0.1
export UI_HOME=true
export UI_TMUX=true
export UI_TMUX_WRITABLE=true
# the tmux-agent dashboard has its own test (test14.sh); kept out of this stack
export UI_TMUX_AGENT=false
export UI_CLAUDE_MEM=true
export UI_LOGLEARNER=true
export UI_PORT_HOME=18000
export UI_PORT_HEADLAMP=14466
export UI_PORT_HINDSIGHT_API=18888
export UI_PORT_HINDSIGHT_UI=19999
export UI_PORT_VIBE_KANBAN=18081
export UI_PORT_TMUX=17681
export UI_PORT_TMUX_AGENT=17337
export UI_PORT_CLAUDE_MEM=37709
export UI_PORT_LOGLEARNER=17779
export UI_PORT_LOOP=17791
export UI_PORT_KNOWLEDGE=17797
# the Files tile's server: its port, and its shared folder test-local, never the shipped /wd/files
export UI_PORT_FILES=18198
export FILES_DIR=${D}/files
# test-local state for the UIs that would otherwise share the agent's: the hindsight cluster
# (HINDSIGHT_HOME, the way test.sh isolates its container), the claude-mem worker's data dir
# and the LogLearner index
export HINDSIGHT_HOME=${HINDSIGHT_HOME:-/tmp/hindsight-test-home}
export CLAUDE_MEM_DATA_DIR=${D}/claude-mem
export LOGLEARNER_DB=${D}/loglearner/index.db
export COMMS_UI_ENABLED=true
export COMMS_UI_PORT=18502
export COMMS_UI_BASE_PATH=comms
export COMMS_UI_LISTEN_HOST=127.0.0.1
export COMMS_DIR=${D}/comms
export COMMS_DEMO_SEED=true
# Test-local tmux session for the writable-terminal probe. ui-start.sh points ttyd at
# ${AGENT_TMUX_SESSION_NAME} (shipped wiring, exercised here), so this test's ttyd stays
# away from the shared "agent" session: that session's pane runs the live interactive
# claude CLI (test12.sh), which must never receive test keystrokes - and may not even echo
# them (a menu prompt swallows typed text), which would make the capture-pane grep flaky.
export AGENT_TMUX_SESSION_NAME=home-smoke-rw
# the docker spoke's build substrate rows (ui-status.sh) read sidecar containers this test has none of: off
export SPOKE_DOCKER=false
TMUX_RO_PORT=17682

cleanup()
{
	[ -n "${TTYD_RO_PID}" ] && kill "${TTYD_RO_PID}" 2>/dev/null
	[ -f "${D}/badge-stub.pid" ] && kill "$(cat ${D}/badge-stub.pid)" 2>/dev/null
	"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
	COMMS_DIR=${D}/comms "${AGENT_DIR}/comms-ui-stop.sh" > /dev/null 2>&1
	tmux kill-session -t home-smoke-ro 2>/dev/null
	tmux kill-session -t home-smoke-rw 2>/dev/null
}

fail()
{
	echo "Test9 FAILED: $1"
	cleanup
	exit 1
}

# --- 1. syntax ---
for S in "${AGENT_DIR}/home-render.sh" "${AGENT_DIR}/ui-start.sh" "${AGENT_DIR}/ui-status.sh" \
         "${AGENT_DIR}/ui-stop.sh" "${AGENT_DIR}/comms-ui-start.sh" "${AGENT_DIR}/tmux-attach.sh"; do
	bash -n "${S}" || fail "bash -n ${S}"
done
echo "ok 1 - syntax"

# --- preflight: proxy + terminal installed (setup/install-nginx.sh, install-ttyd.sh) ---
if ! command -v nginx > /dev/null || ! command -v ttyd > /dev/null || ! command -v tmux > /dev/null; then
	echo "Test9 skipped: nginx/ttyd/tmux not installed (run setup/install-nginx.sh and setup/install-ttyd.sh)"
	exit 0
fi

# --- 2+3. .env defaults and the single-port publish contract ---
ENV_FILE=""
for C in "${BASE_DIR}/../.env" "/do-agent-aws/.env" "${BASE_DIR}/.env"; do
	[ -f "${C}" ] && ENV_FILE="$(cd "$(dirname "${C}")" && pwd)/.env" && break
done
if [ -n "${ENV_FILE}" ]; then
	ENV_DIR="$(dirname "${ENV_FILE}")"
	for KV in "UI_HOME=true" "UI_TMUX=true" "UI_TMUX_WRITABLE=true" "UI_TMUX_AGENT=true" \
	          "UI_CLAUDE_MEM=true" "UI_LOGLEARNER=true" \
	          "UI_PUBLISH_DIRECT_PORTS=false" "COMMS_UI_ENABLED=true"; do
		grep -qE "^export ${KV}$" "${ENV_FILE}" || fail "${KV} is not the .env default"
	done
	echo "ok 2 - .env defaults (home+tmux on, terminal writable, tmux-agent/claude-mem/loglearner on, direct ports off)"

	# Source .env variants in throwaway subshells and inspect the PORT_MAP they build.
	# Variants are sed-edited copies (the flags are unconditional exports), sourced from
	# the repo dir so its relative "source .fun" resolves.
	port_map_for()
	{
		VARIANT=$1
		cp "${ENV_FILE}" ${D}/env-variant
		shift
		for EDIT in "$@"; do
			sed -i "s|^export ${EDIT%%=*}=.*|export ${EDIT}|" ${D}/env-variant
		done
		( cd "${ENV_DIR}" && source ${D}/env-variant > /dev/null 2>&1; echo "${PORT_MAP}" )
	}
	PM_DEFAULT=$(port_map_for default)
	[ "$(echo "${PM_DEFAULT}" | grep -o '\-p ' | wc -l)" == "1" ] \
		|| fail "default PORT_MAP is not exactly one publish: '${PM_DEFAULT}'"
	# That one publish is the home port, on loopback. The expected mapping comes from the variables .env
	# builds it from, so a changed PORT_EXTERNAL_HOME (docs/manual/ui.md "Home page and reverse proxy": change the
	# external side only) passes; the bind address must be loopback whatever UI_BIND_HOST says.
	PUBLISH=$(echo "${PM_DEFAULT}" | sed -n 's/^.*-p \([^ ]*\).*$/\1/p')
	# shellcheck source=/dev/null
	EXPECTED=$( cd "${ENV_DIR}" && source "${ENV_FILE}" > /dev/null 2>&1; echo "${UI_BIND_HOST}:${PORT_EXTERNAL_HOME}:${PORT_INTERNAL_HOME}" )
	# the published port also reaches the container (the home page's tunnel hint reads it; test16 check 2a renders it)
	grep -qF -- '-e PORT_EXTERNAL_HOME=$(shq "${PORT_EXTERNAL_HOME}")' "${ENV_FILE}" || fail ".env does not pass PORT_EXTERNAL_HOME into the container (UI_ENV_OPTS)"
	[ "${PUBLISH}" == "${EXPECTED}" ] \
		|| fail "default PORT_MAP does not publish the home port ${EXPECTED}: '${PM_DEFAULT}'"
	[[ "${PUBLISH%%:*}" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| fail "the home port is not published on loopback (${PUBLISH%%:*}): '${PM_DEFAULT}'"
	# UI_START=false must publish NOTHING even though every UI (incl. comms) is enabled by
		# default - the master switch gates comms too. Leave COMMS_UI_ENABLED at its .env default
		# (true) so this control FAILS if the comms port map stops gating on UI_START.
		PM_OFF=$(port_map_for off "UI_START=false")
	[ -z "$(echo ${PM_OFF} | tr -d '[:space:]')" ] \
		|| fail "UI_START=false still publishes ports (comms not gated by UI_START?): '${PM_OFF}'"
	PM_NOHOME=$(port_map_for nohome "UI_HOME=false")
	for P in 4466 8888 9999 8081 7681 7337 8502; do
		echo "${PM_NOHOME}" | grep -q ":${P}" || fail "UI_HOME=false lost the direct publish of ${P}: '${PM_NOHOME}'"
	done
	# claude-mem (37700) and loglearner (7777) bind 127.0.0.1 INSIDE the container by design, so a
	# docker publish of either could never answer: they are proxy-only and must NOT be published
	for P in 37700 7777; do
		echo "${PM_NOHOME}" | grep -q ":${P}" && fail "UI_HOME=false publishes ${P}, a loopback-only backend that can never answer a docker publish: '${PM_NOHOME}'"
	done
	echo "${PM_NOHOME}" | grep -q ":8000" && fail "UI_HOME=false still publishes the home port: '${PM_NOHOME}'"
	echo "ok 3 - publish contract: one port by default, none with UI_START=false, per-UI with UI_HOME=false (proxy-only backends never published)"
else
	echo "ok 2 - (skipped: no .env found in this context)"
	echo "ok 3 - (skipped: no .env found in this context)"
fi

# --- 4. a location block exists ONLY for an enabled UI; disabled tiles grey out ---
( export UI_HEADLAMP=false UI_TMUX_AGENT=true UI_CLAUDE_MEM=false UI_LOGLEARNER=false; "${AGENT_DIR}/home-render.sh" > /dev/null ) || fail "home-render.sh (variant)"
CONF=${UI_DIR}/home/nginx.conf
PAGE=${UI_DIR}/home/site/index.html
grep -q "location /headlamp/" "${CONF}" && fail "disabled headlamp still has a proxy route"
grep -q "location /tmux-agent/" "${CONF}" || fail "enabled tmux-agent route missing"
grep -q "server_name claude-mem.localhost" "${CONF}" && fail "disabled claude-mem still has a host route"
grep -q "server_name loglearner.localhost" "${CONF}" && fail "disabled loglearner still has a host route"
grep -q "off - set UI_HEADLAMP=true" "${PAGE}" || fail "disabled headlamp tile not greyed with its flag"
grep -q "off - set UI_CLAUDE_MEM=true" "${PAGE}" || fail "disabled claude-mem tile not greyed with its flag"
grep -q "off - set UI_LOGLEARNER=true" "${PAGE}" || fail "disabled loglearner tile not greyed with its flag"
"${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh (defaults)"
grep -q "location /headlamp/" "${CONF}" || fail "enabled headlamp route missing"
grep -q "location /tmux-agent/" "${CONF}" && fail "disabled tmux-agent still has a proxy route"
grep -q "server_name claude-mem.localhost" "${CONF}" || fail "enabled claude-mem host route missing"
grep -q "server_name loglearner.localhost" "${CONF}" || fail "enabled loglearner host route missing"
grep -q 'data-host="claude-mem"' "${PAGE}" || fail "enabled claude-mem tile is not live"
grep -q 'data-host="loglearner"' "${PAGE}" || fail "enabled loglearner tile is not live"
nginx -t -c "${CONF}" > /dev/null 2>&1 || { nginx -t -c "${CONF}"; fail "rendered nginx.conf does not validate"; }
CMCSP=${UI_DIR}/home/csp-claude-mem.conf
{ grep -q "default-src 'self';" "${CMCSP}" && grep -q "connect-src 'self';" "${CMCSP}"; } \
	|| fail "csp-claude-mem.conf does not hold the strict policy: $(cat "${CMCSP}" 2>&1)"
python3 - "${CONF}" << 'EOF' || fail "the claude-mem viewer's Content-Security-Policy is not on exactly its own server block"
import re, sys


def clean(line):
    """A config line without its comment and with every quoted string emptied (comments carry apostrophes, the
    sub_filter scripts braces)."""
    out, quote = [], None
    for ch in line:
        if quote:
            quote = None if ch == quote else quote
        elif ch in "'\"":
            quote = ch
            out.append("''")
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out)


conf = "\n".join(clean(l) for l in open(sys.argv[1]).read().split("\n"))
# each server { ... } block (braces balanced), its server_name and how often it includes the claude-mem policy
blocks, i = [], 0
for m in re.finditer(r"\bserver\s*\{", conf):
    if m.start() < i:
        continue
    depth, j = 0, m.end() - 1
    while True:
        depth += {"{": 1, "}": -1}.get(conf[j], 0)
        j += 1
        if depth == 0:
            break
    body, i = conf[m.start():j], j
    name = (re.search(r"server_name\s+([^;]+);", body) or [None, "(default)"])[1].strip()
    blocks.append((name, body.count("csp-claude-mem.conf;")))
assert any(n == "claude-mem.localhost" for n, _ in blocks), blocks
hits = {n: c for n, c in blocks if c}
assert hits == {"claude-mem.localhost": 1}, blocks
EOF
grep -qE 'src="http|href="http.*\.(css|js)' "${PAGE}" && fail "home page references external assets (must render offline)"
echo "ok 4 - routes exist only for enabled UIs (host routes included); tiles grey out with their flag; config validates"

# --- start the whole stack on the test ports ---
"${AGENT_DIR}/ui-start.sh" || fail "ui-start.sh"
"${AGENT_DIR}/comms-ui-start.sh" || fail "comms-ui-start.sh"

probe()
{
	# probe <url> [<host-header>] - retries until 2xx/3xx or timeout, echoes last code
	URL=$1
	HOST_HEADER=$2
	HDR=()
	[ -n "${HOST_HEADER}" ] && HDR=(-H "Host: ${HOST_HEADER}")
	HTTP=000
	for i in $(seq 1 90); do
		HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${HDR[@]}" "${URL}" 2>/dev/null)
		[ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null && break
		sleep 2
	done
	echo "${HTTP}"
}

# --- 5. the home page itself ---
HTTP=$(probe "http://127.0.0.1:${UI_PORT_HOME}/")
[ "${HTTP}" == "200" ] || { tail -5 ${UI_DIR}/home.log 2>/dev/null; fail "home page not answering (last=${HTTP})"; }
curl -s "http://127.0.0.1:${UI_PORT_HOME}/" | grep -q "do-agent-aws harness" \
	|| fail "home page does not carry the harness title"
echo "ok 5 - home page 200 with title on 127.0.0.1:${UI_PORT_HOME}"

# --- 6. every enabled UI through the single proxy port ---
for ROUTE in /headlamp/ /memory-api/docs /comms/ /tmux/; do
	HTTP=$(probe "http://127.0.0.1:${UI_PORT_HOME}${ROUTE}")
	[ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null \
		|| fail "route ${ROUTE} not answering through the proxy (last=${HTTP})"
	echo "ok 6 - ${ROUTE} -> ${HTTP} through the proxy"
done
# the bare prefix and the trailing-slash spellings of the memory API a user types by hand: the API has no root
# page, and its own answer to /docs/ or /redoc/ was a redirect carrying the request's Host but dropping the prefix
# (found by a fresh-deploy walk): each now answers a redirect to the same path without the slash on THIS listener and
# ends 200
for CASE in "/memory-api|/memory-api/docs" "/memory-api/|/memory-api/docs" "/memory-api/docs/|/memory-api/docs" "/memory-api/redoc/|/memory-api/redoc"; do
	ROUTE=${CASE%%|*}; WANT=${CASE#*|}
	LOC=$(curl -s -D - -o /dev/null --max-time 10 "http://127.0.0.1:${UI_PORT_HOME}${ROUTE}" | grep -i '^location:' | cut -d' ' -f2- | tr -d '\r')
	[ "${LOC}" == "${WANT}" ] || fail "${ROUTE} does not redirect to ${WANT} on this listener (Location '${LOC}')"
	HTTP=$(curl -s -L --max-redirs 5 -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:${UI_PORT_HOME}${ROUTE}")
	[ "${HTTP}" == "200" ] || fail "${ROUTE} followed does not end on a 200 page (http=${HTTP})"
done
echo "ok 6 - /memory-api, /memory-api/, /memory-api/docs/ and /memory-api/redoc/ redirect to the slash-less path on this listener and end 200"
# the docs page's "Try it out": Swagger UI sends an operation to the first server the openapi.json names, resolved
# against the document's own URL (no server named means "/", the proxy's root), followed by the operation's path.
# Built that way from the document the proxy serves, GET /v1/default/banks must land under /memory-api and answer
# 200 - before the API's base path was set the document named no server, the request went to /v1/default/banks
# on this listener and got its 404
OPENAPI_URL="http://127.0.0.1:${UI_PORT_HOME}/memory-api/openapi.json"
curl -s --max-time 20 -o ${D}/openapi.json "${OPENAPI_URL}" || fail "no openapi.json through the proxy at ${OPENAPI_URL}"
TRY=$(python3 - "${D}/openapi.json" "${OPENAPI_URL}" << 'EOF'
import json, sys, urllib.parse
doc = json.load(open(sys.argv[1]))
if "get" not in doc.get("paths", {}).get("/v1/default/banks", {}):
    sys.exit("the served openapi.json has no GET /v1/default/banks")
servers = doc.get("servers") or [{"url": "/"}]
print(urllib.parse.urljoin(sys.argv[2], servers[0]["url"]).rstrip("/") + "/v1/default/banks")
EOF
) || fail "${TRY}"
[ "${TRY}" == "http://127.0.0.1:${UI_PORT_HOME}/memory-api/v1/default/banks" ] \
	|| fail "the docs page's Try it out request for GET /v1/default/banks goes to ${TRY}, not under /memory-api (the document's servers: $(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("servers"))' ${D}/openapi.json))"
HTTP=$(curl -s -o ${D}/try-banks.json -w '%{http_code}' --max-time 20 "${TRY}")
[ "${HTTP}" == "200" ] && grep -q '"banks"' ${D}/try-banks.json \
	|| fail "the docs page's Try it out request ${TRY} answered ${HTTP}: $(head -c 200 ${D}/try-banks.json)"
# ... while the API still answers its own port without the prefix: the agent's hooks and the memory UI call it there
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:${UI_PORT_HINDSIGHT_API}/v1/default/banks")
[ "${HTTP}" == "200" ] || fail "the memory API no longer answers GET /v1/default/banks on its own port without the prefix (${HTTP})"
echo "ok 6 - the docs page's Try it out: GET /v1/default/banks, built from the served openapi.json, goes to /memory-api/v1/default/banks and answers 200 with the bank list; the API's own port still answers it without the prefix"
probe_body()
{
	# probe_body <url> <host-header> <expect> - retries until the FOLLOWED body carries
	# <expect> or timeout, echoes the last body. -L with a cookie engine (-b "") because
	# an upstream may redirect (with a set-cookie) before landing on its page.
	URL=$1
	HOST_HEADER=$2
	EXPECT=$3
	HDR=()
	[ -n "${HOST_HEADER}" ] && HDR=(-H "Host: ${HOST_HEADER}")
	BODY=""
	for i in $(seq 1 30); do
		BODY=$(curl -sL -b "" --max-time 5 "${HDR[@]}" "${URL}" 2>/dev/null)
		echo "${BODY}" | grep -qF "${EXPECT}" && break
		sleep 2
	done
	echo "${BODY}"
}

for H in hindsight.localhost kanban.localhost claude-mem.localhost loglearner.localhost; do
	HTTP=$(probe "http://127.0.0.1:${UI_PORT_HOME}/" "${H}")
	[ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null \
		|| fail "host route ${H} not answering through the proxy (last=${HTTP})"
	echo "ok 6 - ${H} -> ${HTTP} through the proxy"
done

# The injected badge must return HOME from the host routes: there a bare href="/" is the
# app's own root (the hostname is kept), so the badge must target //localhost:<port> - the
# host with its first label stripped, port preserved. Asserted against RENDERED responses.
# hindsight-ui cannot serve a followable page on this test's 127.0.0.1 bind (its locale
# middleware treats the rewrite as cross-origin and self-redirects; the shipped 0.0.0.0
# bind is fine in the browser), so ITS badge is asserted against a minimal-html stub on the
# same upstream port - the property under test is the proxy's injection, not the app.
# vibe-kanban, the claude-mem viewer and the LogLearner dashboard answer 200 html directly, so
# their checks exercise the real upstreams.
kill "$(cat ${UI_DIR}/hindsight-ui.pid 2>/dev/null)" 2>/dev/null
mkdir -p ${D}/badge-stub
echo "<html><body>badge-stub</body></html>" > ${D}/badge-stub/index.html
(
	cd ${D}/badge-stub || exit 1
	setsid nohup python3 -m http.server ${UI_PORT_HINDSIGHT_UI} --bind 127.0.0.1 > ${D}/badge-stub.log 2>&1 &
	echo $! > ${D}/badge-stub.pid
)
for H in hindsight.localhost kanban.localhost claude-mem.localhost loglearner.localhost; do
	WANT="href=\"//localhost:${UI_PORT_HOME}/\" title=\"do-agent-aws harness home\""
	BODY=$(probe_body "http://127.0.0.1:${UI_PORT_HOME}/" "${H}:${UI_PORT_HOME}" "${WANT}")
	echo "${BODY}" | grep -qF "${WANT}" \
		|| fail "host route ${H} badge does not target //localhost:${UI_PORT_HOME}/ (home unreachable from ${H})"
	echo "${BODY}" | grep -qF 'href="/" title="do-agent-aws harness home"' \
		&& fail "host route ${H} still carries the bare href=\"/\" badge (resolves to the app, not home)"
	echo "ok 6 - ${H} badge returns home to //localhost:${UI_PORT_HOME}/"
done
# port preservation: whatever :port the browser sends in Host must be echoed into the badge
# target verbatim - a tunnel/port-forward port (kubectl port-forward 19999:8000, ssh -L), not
# the port nginx itself listens on
BODY=$(probe_body "http://127.0.0.1:${UI_PORT_HOME}/" "kanban.localhost:19999" 'href="//localhost:19999/"')
echo "${BODY}" | grep -qF 'href="//localhost:19999/"' \
	|| fail "badge does not preserve a forwarded port (Host: kanban.localhost:19999 must yield //localhost:19999/)"
echo "ok 6 - badge preserves the browser's port (kanban.localhost:19999 -> //localhost:19999/)"
# positive control: the PATH-routed badge is unchanged - on the default server href="/" IS the
# home page; this line failing means the host-aware badge leaked into the path routes
BODY=$(probe_body "http://127.0.0.1:${UI_PORT_HOME}/comms/" "" 'href="/" title="do-agent-aws harness home"')
echo "${BODY}" | grep -qF 'href="/" title="do-agent-aws harness home"' \
	|| fail "path-routed badge control: /comms/ no longer carries the plain href=\"/\" badge"
echo "ok 6 - path-routed badge control: /comms/ keeps href=\"/\""
# the claude-mem viewer through the proxy carries the strict policy; CONTROL: the worker's own response carries none,
# so the header is the proxy's and the check can tell a response without it
CMHDR=$(curl -s -D - -o /dev/null --max-time 5 -H "Host: claude-mem.localhost:${UI_PORT_HOME}" "http://127.0.0.1:${UI_PORT_HOME}/" | tr -d '\r' | grep -i '^content-security-policy:')
echo "${CMHDR}" | grep -q "connect-src 'self';" || fail "the claude-mem viewer through the proxy carries no connect-src 'self' Content-Security-Policy: [${CMHDR}]"
[ "$(curl -s -D - -o /dev/null --max-time 5 "http://127.0.0.1:${UI_PORT_CLAUDE_MEM}/" | tr -d '\r' | grep -ci '^content-security-policy:')" == "0" ] \
	|| fail "CONTROL BROKEN: the claude-mem worker sends a Content-Security-Policy of its own - this check cannot tell the proxy's apart"
echo "ok 6 - the claude-mem viewer through the proxy carries the strict Content-Security-Policy (connect-src 'self'); control: the worker's own response carries none"

# --- 7. the default terminal is writable (and a read-only twin proves the flag) ---
# The probe needs a websocket client: the image ships the `websockets` package as a streamlit
# dependency, in streamlit's own environment (COMMS_PYTHON, setup/install-comms.sh) since the comms UI moved
# off the system python3; tornado, the previous choice, is no longer pulled in. No client at all is a
# FAILURE here, not a skip - brief item 5 (a reliably writable terminal) rests on this check.
WS_CLIENT=""; WS_PY=""
for P in python3 "${COMMS_PYTHON:-/opt/comms-venv/bin/python}"; do
	command -v "${P}" > /dev/null 2>&1 || continue
	"${P}" -c "import websockets" 2>/dev/null && { WS_CLIENT=websockets; WS_PY=${P}; break; }
	"${P}" -c "import tornado.websocket" 2>/dev/null && { WS_CLIENT=tornado; WS_PY=${P}; break; }
done
[ -n "${WS_CLIENT}" ] || fail "no websocket client for the writable-terminal probe (websockets or tornado in python3 or ${COMMS_PYTHON:-/opt/comms-venv/bin/python}) - check 7 cannot run"
if true; then
	# Read-only twin on its own port and its own tmux session: the SAME keystroke probe
	# must be REFUSED there - the negative control proving UI_TMUX_WRITABLE=false still
	# works and the probe can fail (otherwise the writable pass below could not go red).
	# the read-only flag by capability, the way ui-start.sh picks its flags: a ttyd that
	# knows --readonly (1.6.x) is writable until told otherwise; one that does not (1.7+) is
	# read-only by default and takes no -R
	TTYD_RO_ARGS=""
	ttyd --help 2>&1 | grep -q -- '--readonly' && TTYD_RO_ARGS="-R"
	setsid nohup ttyd -p ${TMUX_RO_PORT} -i lo -b /tmux ${TTYD_RO_ARGS} \
		tmux new-session -A -s home-smoke-ro > ${D}/ttyd-ro.log 2>&1 &
	TTYD_RO_PID=$!
	sleep 2

	ws_probe()
	{
		# ws_probe <ws-url> <marker> - open the ttyd websocket, TYPE "echo <marker>" into
		# the pane. Deliberately NO trailing \r: reaching the pane is the property under
		# test (capture-pane shows typed-but-unsubmitted text), and when the pane runs the
		# interactive claude CLI a \r would submit the marker as a real prompt.
		# ttyd only passes input to a terminal with a real size: without the resize
		# message (and a beat for tmux to attach at that size) the keystroke is dropped
		# even on a WRITABLE terminal, and both sides of check 7 would be vacuous.
		WS_URL=$1 MARKER=$2 WS_CLIENT=${WS_CLIENT} WS_ORIGIN_OVERRIDE=${WS_ORIGIN_OVERRIDE:-} "${WS_PY}" - << 'EOF'
import asyncio, os, urllib.parse

URL, MARKER = os.environ["WS_URL"], os.environ["MARKER"]
# a browser's handshake: the page's own origin (ttyd runs with --check-origin, the proxy has a same-origin gate)
ORIGIN = os.environ.get("WS_ORIGIN_OVERRIDE") or "http://" + urllib.parse.urlsplit(URL).netloc

async def with_websockets():
    import websockets
    async with websockets.connect(URL, subprotocols=["tty"], origin=ORIGIN) as ws:
        await ws.send('{"AuthToken":""}')
        await ws.send(b'1{"columns":120,"rows":30}')
        await ws.recv()                 # wait for the terminal to answer before typing
        await asyncio.sleep(2)          # let tmux attach at the announced size
        await ws.send(b"0echo " + MARKER.encode())
        await asyncio.sleep(2)

async def with_tornado():
    from tornado import httpclient, websocket
    conn = await websocket.websocket_connect(httpclient.HTTPRequest(URL, headers={"Origin": ORIGIN}), subprotocols=["tty"])
    conn.write_message('{"AuthToken":""}')
    conn.write_message('1{"columns":120,"rows":30}', binary=True)
    await conn.read_message()
    await asyncio.sleep(2)
    conn.write_message("0echo " + MARKER, binary=True)
    await asyncio.sleep(2)
    conn.close()

asyncio.run(asyncio.wait_for(with_websockets() if os.environ["WS_CLIENT"] == "websockets" else with_tornado(), 30))
EOF
	}

	# The shipped default (UI_TMUX_WRITABLE=true), THROUGH the proxy: the planted keystroke
	# must reach the pane - the browser terminal drives the shared session. This test's
	# ui-start.sh instance pointed its ttyd at the test-local session (AGENT_TMUX_SESSION_NAME
	# above, created by -A on this first client connect with a bare shell in the pane, so the
	# typed text is deterministically echoed); the shipped wiring under test is identical.
	ws_probe "ws://127.0.0.1:${UI_PORT_HOME}/tmux/ws" "WRITABLE_DEFAULT_PROBE" || fail "writable websocket probe errored"
	sleep 1
	tmux capture-pane -p -t home-smoke-rw 2>/dev/null | grep -q "WRITABLE_DEFAULT_PROBE" \
		|| fail "WRITABLE DEFAULT BROKEN: keystroke did not reach the tmux pane with UI_TMUX_WRITABLE=true"
	# clear the typed-but-unsubmitted text rather than leaving it staged in the pane
	tmux send-keys -t home-smoke-rw C-u 2>/dev/null
	echo "ok 7a - default terminal is writable: planted keystroke lands in the shared-session wiring"

	# The read-only twin: the SAME probe must NOT reach its pane (negative control).
	ws_probe "ws://127.0.0.1:${TMUX_RO_PORT}/tmux/ws" "READONLY_LEAK_PROBE" || fail "read-only twin websocket probe errored"
	sleep 1
	tmux capture-pane -p -t home-smoke-ro 2>/dev/null | grep -q "READONLY_LEAK_PROBE" \
		&& fail "READ-ONLY VIOLATION: keystroke reached the pane of the UI_TMUX_WRITABLE=false twin"
	echo "ok 7b - read-only twin (UI_TMUX_WRITABLE=false) refuses the same probe (negative control)"

	# 7d. cross-site WebSocket hijacking: what a page on another origin gets from the writable terminal.
	# ws_code <url> [origin] - the HTTP status of a terminal websocket handshake (101 = upgraded; curl then waits
	# until --max-time, which is the expected exit 28 here)
	ws_code()
	{
		curl -s -o /dev/null -w '%{http_code}' --max-time 3 ${2:+-H "Origin: $2"} -H 'Connection: Upgrade' \
			-H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
			-H 'Sec-WebSocket-Protocol: tty' "$1"
	}
	C=$(ws_code "http://127.0.0.1:${UI_PORT_HOME}/tmux/ws" "https://evil.example")
	[ "${C}" == "403" ] || fail "CROSS-SITE: a foreign Origin's terminal handshake through the proxy got ${C}, not 403"
	C=$(ws_code "http://127.0.0.1:${UI_PORT_HOME}/tmux/ws" "http://127.0.0.1:${UI_PORT_HOME}")
	[ "${C}" == "101" ] || fail "CONTROL BROKEN: the page's own Origin did not upgrade through the proxy (${C}) - the 403 above proves nothing"
	WS_ORIGIN_OVERRIDE="https://evil.example" ws_probe "ws://127.0.0.1:${UI_PORT_HOME}/tmux/ws" "CROSS_SITE_PROBE" 2> /dev/null
	sleep 1
	tmux capture-pane -p -t home-smoke-rw 2>/dev/null | grep -q "CROSS_SITE_PROBE" \
		&& fail "CROSS-SITE: a page on another origin typed into the terminal's pane"
	C=$(ws_code "http://127.0.0.1:${UI_PORT_TMUX}/tmux/ws" "https://evil.example")
	[ "${C}" == "101" ] && fail "CROSS-SITE: ttyd itself upgraded a foreign Origin on its own port - ui-start.sh started it without --check-origin"
	C2=$(ws_code "http://127.0.0.1:${UI_PORT_TMUX}/tmux/ws" "http://127.0.0.1:${UI_PORT_TMUX}")
	[ "${C2}" == "101" ] || fail "CONTROL BROKEN: ttyd did not upgrade its own origin (${C2}) - the refusal above (${C}) proves nothing"
	echo "ok 7d - a foreign Origin gets 403 through the proxy and never 101 (the page's own: 101), types nothing into the pane, and ttyd refuses it on its own port (${C}; its own origin: 101)"
	kill "${TTYD_RO_PID}" 2>/dev/null; TTYD_RO_PID=""
	tmux kill-session -t home-smoke-ro 2>/dev/null

	# The session picker (/agent/tmux-attach.sh behind --url-arg): the page URL names a session of this container's
	# own tmux server. ws_screen <ws-url> - what the terminal shows a fresh client in its first seconds
	ws_screen()
	{
		WS_URL=$1 WS_CLIENT=${WS_CLIENT} "${WS_PY}" - << 'EOF'
import asyncio, os, urllib.parse

URL = os.environ["WS_URL"]
ORIGIN = "http://" + urllib.parse.urlsplit(URL).netloc   # as ws_probe: the page's own origin

async def run():
    out = b""
    if os.environ["WS_CLIENT"] == "websockets":
        import websockets
        async with websockets.connect(URL, subprotocols=["tty"], origin=ORIGIN) as ws:
            await ws.send('{"AuthToken":""}')
            await ws.send(b'1{"columns":160,"rows":40}')
            try:
                while True:
                    m = await asyncio.wait_for(ws.recv(), 4)
                    m = m if isinstance(m, bytes) else m.encode()
                    out += m[1:] if m[:1] == b"0" else b""
            except asyncio.TimeoutError:
                pass
    else:
        from tornado import httpclient, websocket
        conn = await websocket.websocket_connect(httpclient.HTTPRequest(URL, headers={"Origin": ORIGIN}), subprotocols=["tty"])
        conn.write_message('{"AuthToken":""}')
        conn.write_message('1{"columns":160,"rows":40}', binary=True)
        try:
            while True:
                m = await asyncio.wait_for(conn.read_message(), 4)
                if m is None:
                    break
                m = m if isinstance(m, bytes) else m.encode()
                out += m[1:] if m[:1] == b"0" else b""
        except asyncio.TimeoutError:
            pass
        conn.close()
    print(out.decode(errors="replace"))

asyncio.run(run())
EOF
	}
	tmux new-session -d -s pick-a 2>/dev/null; tmux new-session -d -s pick-b 2>/dev/null
	TT="ws://127.0.0.1:${UI_PORT_HOME}/tmux/ws"
	# 1. a session that exists: the browser lands in it, not in the agent session
	ws_probe "${TT}?arg=pick-b" "PICKED_SESSION_PROBE" || fail "picker websocket probe errored"
	sleep 1
	tmux capture-pane -p -t pick-b 2>/dev/null | grep -q "PICKED_SESSION_PROBE" || fail "?arg=pick-b did not land in the session pick-b"
	tmux capture-pane -p -t home-smoke-rw 2>/dev/null | grep -q "PICKED_SESSION_PROBE" && fail "?arg=pick-b landed in the agent session"
	tmux send-keys -t pick-b C-u 2>/dev/null
	# 2. the menu lists the sessions that exist
	SCREEN=$(ws_screen "${TT}?arg=pick")
	for S in pick-a pick-b home-smoke-rw; do
		echo "${SCREEN}" | grep -q ") ${S}" || fail "?arg=pick does not list the session ${S}: $(echo "${SCREEN}" | tr -d '\r' | head -8)"
	done
	# 3. a session that does not exist: an honest error, then the same list
	SCREEN=$(ws_screen "${TT}?arg=no-such-session")
	{ echo "${SCREEN}" | grep -q "there is no tmux session named 'no-such-session' in this container" && echo "${SCREEN}" | grep -q ") pick-a"; } \
		|| fail "?arg=no-such-session did not say so and list the sessions: $(echo "${SCREEN}" | tr -d '\r' | head -6)"
	# 4. an argument that would choose a socket, a server or a path is refused with the same honest menu
	for A in "-L" "-S" "TMUX%3D%2Ftmp%2Fother" "pick-a%2F..%2Fx"; do
		SCREEN=$(ws_screen "${TT}?arg=${A}")
		echo "${SCREEN}" | grep -q "is not a tmux session name" || fail "?arg=${A} was not refused as a session name: $(echo "${SCREEN}" | tr -d '\r' | head -4)"
	done
	# CONTROL: the previous terminal command (no --url-arg, a fixed attach) ignores the argument - ?arg=pick-b lands
	# in the agent session; the checks above can tell the two apart
	setsid nohup ttyd -p ${TMUX_RO_PORT} -i lo -b /tmux tmux new-session -A -s home-smoke-rw > ${D}/ttyd-fixed.log 2>&1 &
	TTYD_FIXED_PID=$!
	sleep 2
	ws_probe "ws://127.0.0.1:${TMUX_RO_PORT}/tmux/ws?arg=pick-b" "FIXED_ATTACH_PROBE" || fail "fixed-attach websocket probe errored"
	sleep 1
	tmux capture-pane -p -t pick-b 2>/dev/null | grep -q "FIXED_ATTACH_PROBE" && fail "CONTROL BROKEN: the fixed attach honoured ?arg="
	tmux capture-pane -p -t home-smoke-rw 2>/dev/null | grep -q "FIXED_ATTACH_PROBE" || fail "CONTROL BROKEN: the fixed attach did not land in the agent session"
	tmux send-keys -t home-smoke-rw C-u 2>/dev/null
	kill "${TTYD_FIXED_PID}" 2>/dev/null
	tmux kill-session -t pick-a 2>/dev/null; tmux kill-session -t pick-b 2>/dev/null
	echo "ok 7c - the session picker: ?arg=pick-b lands in pick-b, ?arg=pick lists this container's sessions, a missing name says so and lists them, -L, -S, TMUX= and a path are refused as names; control: the fixed attach ignores ?arg= and lands in the agent session"
fi

# --- 8. downness is reported honestly ---
# Stop just the terminal daemon: its proxied route must stop returning 2xx (a dead
# upstream must never look green through the proxy - this is what the home tile dot reads)
TTYD_PID=$(cat ${UI_DIR}/tmux.pid 2>/dev/null)
[ -n "${TTYD_PID}" ] && kill -TERM -- "-${TTYD_PID}" 2>/dev/null
sleep 1
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${UI_PORT_HOME}/tmux/" 2>/dev/null)
if [ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null; then
	fail "stopped terminal still answers 2xx/3xx through the proxy (http=${HTTP})"
fi
echo "ok 8a - stopped UI reports down through the proxy (http=${HTTP})"
# ui-stop stops everything including nginx; the home port must then answer nothing at all
"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${UI_PORT_HOME}/" 2>/dev/null)
[ "${HTTP}" == "000" ] || fail "home port still answers after ui-stop.sh (http=${HTTP})"
echo "ok 8b - ui-stop.sh takes the proxy down with everything else"

cleanup
echo "Test9 succeeded"
