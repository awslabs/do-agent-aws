#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the home proxy's same-origin gate (/agent/home-render.sh): every server block refuses with 403 a
# request whose Origin names another site than the Host it was sent to - a browser sends Origin on every WebSocket
# handshake and every cross-origin request, so a page the operator visits cannot open the writable terminal's
# websocket (cross-site WebSocket hijacking) or post to a UI. The terminal's own check (ttyd --check-origin, started by
# ui-start.sh) is proven end to end by test9.sh check 7d. Each check FAILS on what it guards:
#   1. syntax
#   2. rendered with every UI on, every server block of nginx.conf carries the gate, and kanban-sync.localhost the
#      board's variant (its one cross-origin reader, kanban.<home host>); PLANTED CONTROL: a copy with one gate removed
#      is caught
#   3. live (nginx with the rendered config, no upstream running): on every host the proxy serves, a request with
#      Origin https://evil.example gets 403, which may not be framed (X-Frame-Options DENY, frame-ancestors 'none';
#      CONTROL: an answer the gate did not give carries neither), one with the page's own Origin or none does not; the terminal's websocket handshake
#      with a foreign Origin gets 403, never 101; so does a cross-site POST to each path route of the home host (the comms
#      UI, headlamp, the memory API, the tmux-agent dashboard, the knowledge page); host names compare case-insensitively, the scheme is not compared, and
#      look-alike origins (another port, a suffix, a prefix) are foreign
#   4. live: the board's live sync admits http://kanban.<home host> and its own origin, and refuses evil.example
#   5. PLANTED CONTROL, live: the same config without the gate on the home host answers the foreign Origin there
#      (the checks above can tell a refusal)
# Test-local: TEST_ORIGIN_GATE_DIR (default /tmp/origin-gate-smoke), ports 18311 and 18312; never /wd.

AGENT_DIR=${AGENT_DIR:-/agent}
D=${TEST_ORIGIN_GATE_DIR:-/tmp/origin-gate-smoke}
PORT=18311
PORT_CONTROL=18312
NGINX_PIDS=""
cleanup() { for P in ${NGINX_PIDS}; do kill "${P}" 2> /dev/null; done; }
fail() { echo "Test-origin-gate FAILED: $*"; cleanup; exit 1; }
trap cleanup EXIT
command -v nginx > /dev/null || { echo "Test-origin-gate skipped: no nginx"; exit 0; }
rm -rf "${D:?}" && mkdir -p "${D}" || fail "cannot create ${D}"

# 1. syntax
bash -n "${AGENT_DIR}/home-render.sh" || fail "1: home-render.sh"
echo "ok 1 - syntax"

# 2. every server block carries the gate
( export UI_DIR="${D}/ui" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME=${PORT} UI_PLANE=true PLANE_URL=http://127.0.0.1:18391 \
	KANBAN_BOARD_URL=http://127.0.0.1:18392 UI_BOARD=true; "${AGENT_DIR}/home-render.sh" > "${D}/render.log" 2>&1 ) \
	|| fail "2: home-render.sh with every UI on: $(tail -3 "${D}/render.log")"
CONF="${D}/ui/home/nginx.conf"
cat > "${D}/gates.py" << 'PY'
import sys
# server blocks are the lines from "\tserver {" to the next "\t}" (their directives are indented deeper; a
# sub_filter's script stays on its own line, so its braces never end a block)
lines, blocks, cur = open(sys.argv[1]).read().split("\n"), [], None
for line in lines:
    if line == "\tserver {":
        cur = []
    elif cur is not None and line == "\t}":
        blocks.append(cur)
        cur = None
    elif cur is not None:
        cur.append(line.strip())
bad, names = [], []
for b in blocks:
    name = next((l[len("server_name "):-1] for l in b if l.startswith("server_name ")), "?")
    want = "if ($sync_foreign_origin) { return 403; }" if name == "kanban-sync.localhost" else "if ($foreign_origin) { return 403; }"
    if want not in b:
        bad.append(name)
    names.append(name)
print(" ".join(n.split()[0] for n in names if n != "_"))
if bad or len(blocks) < 10:
    sys.exit("%d server blocks; without their gate: %s" % (len(blocks), bad))
PY
HOSTS=$(python3 -I "${D}/gates.py" "${CONF}") || fail "2: ${HOSTS:-the gate is missing}"
case " ${HOSTS} " in *" kanban-sync.localhost "*) ;; *) fail "2: the render has no kanban-sync.localhost block - check 4 would prove nothing (${HOSTS})" ;; esac
python3 -I - "${CONF}" "${D}/no-gate.conf" << 'PY' || fail "2: the planted copy was not written"
import sys
s = open(sys.argv[1]).read()
gate = "\t\tif ($foreign_origin) { return 403; }\n"
i = s.index("\t\tserver_name localhost ")
j = s.index(gate, i)
open(sys.argv[2], "w").write(s[:j] + s[j + len(gate):])
PY
python3 -I "${D}/gates.py" "${D}/no-gate.conf" > /dev/null 2>&1 && fail "2: PLANTED CONTROL: a server block without its gate was not caught"
echo "ok 2 - every server block carries the same-origin gate ($(echo "${HOSTS}" | wc -w) hosts, kanban-sync.localhost the board's variant); a block without it is caught"

# 3. live, every host
start_nginx()
{
	# start_nginx <config> <port> - nginx in the foreground of a background job; waits until the port answers
	nginx -c "$1" -g "daemon off;" > "${D}/nginx-$2.log" 2>&1 &
	NGINX_PIDS="${NGINX_PIDS} $!"
	for _ in $(seq 1 50); do
		curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$2/" -H "Host: localhost:$2" && return 0
		sleep 0.2
	done
	fail "nginx did not answer on $2: $(tail -3 "${D}/nginx-$2.log")"
}
code()
{
	# code <port> <host> [origin] [path] [method] - the HTTP status the proxy answers
	curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X "${5:-GET}" -H "Host: $2" ${3:+-H "Origin: $3"} "http://127.0.0.1:$1${4:-/}"
}
framed()
{
	# framed <port> <host> [origin] [path] - prints the framing headers of the answer unless both forbid framing
	# (X-Frame-Options DENY and Content-Security-Policy frame-ancestors 'none'); silent when they do
	local R
	R=$(curl -s -D - -o /dev/null --max-time 5 -H "Host: $2" ${3:+-H "Origin: $3"} "http://127.0.0.1:$1${4:-/}" | tr -d '\r')
	grep -qix "x-frame-options: DENY" <<< "${R}" && grep -qix "content-security-policy: frame-ancestors 'none'" <<< "${R}" \
		|| echo "[$(grep -iE '^(x-frame-options|content-security-policy):' <<< "${R}" | paste -sd'|' -)]"
}
start_nginx "${CONF}" ${PORT}
for H in ${HOSTS}; do
	[ "${H}" == "kanban-sync.localhost" ] && continue
	C=$(code ${PORT} "${H}:${PORT}" "https://evil.example")
	[ "${C}" == "403" ] || fail "3: ${H}: a request with Origin https://evil.example got ${C}, not 403"
	F=$(framed ${PORT} "${H}:${PORT}" "https://evil.example")
	[ -z "${F}" ] || fail "3: ${H}: the gate's 403 does not forbid framing: ${F}"
	C=$(code ${PORT} "${H}:${PORT}" "http://${H}:${PORT}")
	[ "${C}" == "403" ] && fail "3: ${H}: a request with the page's own Origin got 403"
	C=$(code ${PORT} "${H}:${PORT}")
	[ "${C}" == "403" ] && fail "3: ${H}: a request with no Origin got 403"
done
WS_NONCE=$(head -c 16 /dev/urandom | base64)   # a handshake's Sec-WebSocket-Key: 16 random bytes, base64 (RFC 6455)
WS=(-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: ${WS_NONCE}" -H 'Sec-WebSocket-Protocol: tty')
C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${WS[@]}" -H "Host: localhost:${PORT}" -H "Origin: https://evil.example" "http://127.0.0.1:${PORT}/tmux/ws")
[ "${C}" == "403" ] || fail "3: the terminal's websocket handshake with a foreign Origin got ${C}, not 403"
# the home host's path routes by name (the comms UI, headlamp, the memory API, the tmux-agent dashboard, the knowledge page):
# a cross-site POST to each gets 403; the same route with the page's own Origin does not
for R in /comms/ /headlamp/ /memory-api/v1/default/banks /tmux-agent/ /knowledge/; do
	C=$(code ${PORT} "localhost:${PORT}" "https://evil.example" "${R}" POST)
	[ "${C}" == "403" ] || fail "3: a POST to ${R} with a foreign Origin got ${C}, not 403"
	C=$(code ${PORT} "localhost:${PORT}" "http://localhost:${PORT}" "${R}")
	[ "${C}" == "403" ] && fail "3: ${R} with the page's own Origin got 403"
done
for O in "http://LOCALHOST:${PORT}" "https://localhost:${PORT}"; do
	C=$(code ${PORT} "localhost:${PORT}" "${O}")
	[ "${C}" == "403" ] && fail "3: Origin ${O} on Host localhost:${PORT} got 403 (case or scheme compared)"
done
for O in "http://localhost:1${PORT}" "http://localhost:${PORT}.evil.example" "http://evil.localhost:${PORT}" "null"; do
	C=$(code ${PORT} "localhost:${PORT}" "${O}")
	[ "${C}" == "403" ] || fail "3: the look-alike Origin ${O} on Host localhost:${PORT} got ${C}, not 403"
done
C=$(code ${PORT} "evil.example:${PORT}")
[ "${C}" == "421" ] || fail "3: an unknown Host without Origin got ${C}, not the default server's 421"
# CONTROL: an answer the gate did not give (the default server's 421) carries neither framing header - their empty
# values add none, so a request the gate passes is answered as before
F=$(curl -s -D - -o /dev/null --max-time 5 -H "Host: evil.example:${PORT}" "http://127.0.0.1:${PORT}/" | tr -d '\r' | grep -iE '^(x-frame-options|content-security-policy):')
[ -z "${F}" ] || fail "3: CONTROL: an answer the gate did not give carries the gate's framing headers: ${F}"
echo "ok 3 - $(echo "${HOSTS}" | wc -w) hosts refuse a foreign Origin with 403, which may not be framed (control: an answer the gate did not give carries neither header), and serve their own and none; the terminal's handshake gets 403, never 101; case and scheme are not compared, look-alikes are foreign"

# 4. the board's live sync, its one cross-origin reader
SYNC="kanban-sync.localhost:${PORT}"
C=$(code ${PORT} "${SYNC}" "http://kanban.localhost:${PORT}" /v1/shape/x)
[ "${C}" == "403" ] && fail "4: the board's own origin was refused by the live sync"
C=$(code ${PORT} "${SYNC}" "http://kanban-sync.localhost:${PORT}" /v1/shape/x)
[ "${C}" == "403" ] && fail "4: the live sync refused its own origin"
C=$(code ${PORT} "${SYNC}" "https://evil.example" /v1/shape/x)
[ "${C}" == "403" ] || fail "4: the live sync answered a foreign Origin with ${C}, not 403"
F=$(framed ${PORT} "${SYNC}" "https://evil.example" /v1/shape/x)
[ -z "${F}" ] || fail "4: the live sync's refusal does not forbid framing: ${F}"
C=$(code ${PORT} "${SYNC}" "http://kanban.evil.example:${PORT}" /v1/shape/x)
[ "${C}" == "403" ] || fail "4: the live sync answered http://kanban.evil.example with ${C}, not 403"
echo "ok 4 - the board's live sync admits http://kanban.localhost and its own origin, and refuses foreign ones"

# 5. PLANTED CONTROL: without the gate the foreign Origin is answered
sed "s/127\.0\.0\.1:${PORT}\b/127.0.0.1:${PORT_CONTROL}/g; s#${D}/ui/home/nginx.pid#${D}/nginx-control.pid#" "${D}/no-gate.conf" > "${D}/no-gate-port.conf"
start_nginx "${D}/no-gate-port.conf" ${PORT_CONTROL}
C=$(code ${PORT_CONTROL} "localhost:${PORT_CONTROL}" "https://evil.example")
[ "${C}" == "403" ] && fail "5: PLANTED CONTROL: the home host without its gate still refused the foreign Origin - something else answers 403"
echo "ok 5 - PLANTED CONTROL: the home host without the gate answers the foreign Origin (${C})"

cleanup; NGINX_PIDS=""
rm -rf "${D:?}"
echo "Test-origin-gate succeeded"
