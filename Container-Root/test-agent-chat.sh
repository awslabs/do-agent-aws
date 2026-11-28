#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the Agent chat page (docs/manual/ui.md "Agent chat"): /agent/agent-chat.py, its chat.localhost route, status
# probe and tile in /agent/home-render.sh, and its rows in ui-start.sh, ui-stop.sh and ui-status.sh. Fully OFFLINE: a
# test-local tmux server (its own socket directory) runs a STUB in place of the agent CLI - a shell loop that prints
# every line it receives, started so that tmux reports its foreground command as "claude" - and everything binds
# 127.0.0.1 on ports found free at the start, with state under a directory of its own (mktemp; removed when the test
# succeeds, kept for a look when it fails). Two runs on one host do not meet. The real agent is never touched.
# AGENT_CHAT_BACKEND points the checks at another copy of the backend (a review's, an older commit's), the way AGENT_DIR
# does for the Slack tests; the controls are still planted from that copy.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the scripts parse (bash -n, python3 ast.parse)
#   2. home-render.sh with UI_CHAT=true routes chat.localhost to the backend (badge-host-nolink.conf included - the badge without a second stylesheet link, the page links the sheet itself; the shared
#      redirect rules) and gives the tile a GET-only, status-only probe /__probe/chat on the home listener; the tile is
#      live with that probe and opens in a new tab; with UI_CHAT=false there is no route, no probe and a greyed tile
#      naming the flag; both configs validate
#   3. the page renders the pane's text ESCAPED: with "<script>alert(...)</script>" on the stub's screen the page
#      carries it as text and never as markup; PLANTED CONTROL: a copy of the backend without the escaping serves the
#      markup, and this check fails on it
#   4. a send reaches the pane as LITERAL text plus Enter: a message with $(...), ";", a tmux key name (C-c, Enter) and
#      markup arrives character for character, nothing in it runs, the stub keeps running; control characters in the
#      message (newline, tab, escape) arrive as spaces; 4000 characters pass and 4001 are 413; the acknowledgement
#      names the transport only; PLANTED CONTROLS: a copy of the backend that hands tmux a shell command line runs the
#      ";" part on the host and delivers only the first word; a copy that does not replace control characters hands
#      the newline to the pane, which makes two inputs of one message; a copy without the cap types the 4001
#   5. the write is same-origin and POST-only: a POST whose Origin is another host, the chat host on another port, or
#      "null", or that carries neither Origin nor Referer, answers 403, types nothing and makes NO tmux call (counted
#      through a logging tmux on the backend's PATH); an accepted send is exactly two tmux calls, one literal
#      `send-keys -l --` with the text and one `Enter`; the Referer of the page stands in for a missing Origin; GET
#      /send and POST /pane are refused; a Host other than chat.localhost is 403 on every route but /healthz; PLANTED
#      CONTROL: a copy without the same-origin check types a foreign page's message, which this check catches
#   6. a pane whose foreground command is not the agent CLI is refused: with a shell window active the send answers
#      409 naming the command and nothing is typed, /state says why; the stub pane active again, a send goes through;
#      PLANTED CONTROL: a copy without the command check types into the shell, which this check catches. A missing
#      session: the page still answers 200 and says so, /state and a send say so
#   7. the tile's dot follows the probe: /__probe/chat answers 204 through the proxy while the backend runs, 403 to a
#      POST (GET-only), and 500 - the dot reads down - with the backend stopped (the CONTROL); a restarted backend
#      brings it back
#   8. ui-start.sh starts the backend on UI_PORT_CHAT, ui-status.sh reports it UP, ui-stop.sh stops it and the port
#      closes; with UI_CHAT=false nothing starts and the row reads DISABLED
#   9. UI_TMUX_WRITABLE=false (a watch-only harness): the page and the pane still answer, /state says sending is off and
#      why, a POST from the page is 403 and types nothing; the default-writable backend is the control
#  10. every answer carries Cache-Control: no-store and X-Content-Type-Options: nosniff and no CORS header, also
#      to a request with an Origin; PLANTED CONTROL: a copy that allows any origin and drops no-store fails the check
#  11. sends are serialized: three senders posting at once for twenty rounds each give sixty intact lines on the pane,
#      and the tmux log shows every literal send followed by its own Enter (counted); the page sends one message at a
#      time (its in-flight guard is in the served script); PLANTED CONTROL: a copy without the lock, two senders, ten
#      rounds: an interleaving (a merged input, or two literal sends before an Enter) shows
#  12. watch-only is every spelling but exactly "true" - False, FALSE, no, 0 and off refuse a send (403, /state off),
#      true accepts; PLANTED CONTROL: a copy that refuses only the exact "false" types with False
#  13. a message that ends in ";" arrives exactly: the six cases hello; a\; "end ;" x;; "mid ; dle" and ";" (tmux reads
#      a trailing ";" in an argument as a command separator; the backend escapes it); PLANTED CONTROL: a copy without
#      the escape delivers hello; as hello
#  14. the standard library's own answers carry the headers too: 501 for OPTIONS, HEAD and an unknown method on the
#      request line, 431 for too many header lines - no-store, nosniff, the policy, no CORS header (a request line without
#      an HTTP version gets the standard library's HTTP/0.9 answer: by protocol no status line and no headers, only the
#      library's error page as its body - the one answer without them); PLANTED CONTROL: a copy
#      without the end_headers override answers 501 without them
#  16. the chat route requires the harness design system: home-render.sh fails loudly, naming it, on a tree where
#      harness_css_location is not defined (a copy of home-render.sh without the function; on a tree that never had it,
#      the copy is the original), so a stacking order that puts the chat above a base without the design system cannot
#      ship an unstyled page with a 404ing stylesheet silently. Check 2's render is the positive side: it needs the
#      function, so this whole test is red on such a base, on purpose
#  15. timeouts: a body that never arrives is dropped at AGENT_CHAT_READ_TIMEOUT (the connection closes; PLANTED CONTROL:
#      a copy without the timeout holds it open); a tmux that does not answer within AGENT_CHAT_TMUX_TIMEOUT is an error
#      answer - 503 on /pane and on a send (the pane is read before anything is typed), each naming it - not an unanswered request (PLANTED CONTROL: a copy whose
#      tmux call may raise answers nothing)
#  17. a message is typed only at the agent's PROMPT: with a stub that draws Claude Code's approval dialog ("Do you want
#      to proceed?", numbered choices, the cursor on 1, the prompt hidden) a send is 409 naming the question, nothing is
#      typed (the stub logs every key it reads), the menu stays; /state names the menu, its question and options; the
#      page carries the menu panel. PLANTED CONTROL - the page before this check: a copy without the gate types the
#      message into the menu and its Enter answers it with the highlighted choice, "1. Yes" - an approval nobody gave
#  18. a menu is answered with exactly one key: POST /answer with the option's number and the menu's key presses "2" in
#      the pane and nothing else (the stub answers at once on a digit, as Claude Code does), and the prompt that follows
#      takes a message again; a stale key (another menu was shown) is 409 and presses nothing; an option the menu does
#      not have is 400; a checkbox list is named as a list, has no numbered answer (409) and refuses a message (409);
#      PLANTED CONTROL: a copy without the key check answers a menu the page never showed
#  19. the Enter after the key is conditional: a menu that only moves its cursor on a digit gets the key and then Enter;
#      a menu that answers on the digit gets no Enter - with a second menu right behind the first, the second stays
#      unanswered and /state shows it; PLANTED CONTROL: a copy that always follows the key with Enter answers the second
#      menu with its highlighted choice
#  20. the reading of the pane is proven on the agent CLI's own screens, captured from Claude Code 2.1.296: the approval
#      dialog (4 choices), a question with options (descriptions under the options, a rule before the last one), the
#      checkbox list of new MCP servers, the prompt under a transcript that echoes earlier inputs as "❯ text" and shows
#      a numbered list in the agent's answer (no menu), the prompt with wrapped typed text, a dialog without a cursor
#      ("other": refused for claude, naming the missing prompt); a pane that runs another configured CLI is held only
#      for a menu, never for a prompt shape this page does not know
#  21. the harness's own agent pane qualifies: tmux-claude.sh (the session's wrapper) runs the agent CLI under job
#      control, in its own process group as the pane's foreground process, so tmux reports it as the pane's command and
#      a send goes through; PLANTED CONTROL: the wrapper without the job control (the lines removed, each removal
#      asserted) reports bash for the same running CLI, and the page refuses the harness's own agent pane as a shell
#  22. only the hub's pane: with AGENT_TMUX_SESSION_NAME naming a session the registry (SPOKES_REGISTRY) lists as a
#      spoke, /state says it takes no message and why, a send and a menu answer are 409 naming the spoke, and nothing
#      reaches its pane; the same pane listed as the hub takes the message; PLANTED CONTROL: a copy of the backend
#      without the registry check types into the spoke's pane
# The badge's position inside a browser's viewport is a browser check, outside this test; nothing here
# renders a page.

D=$(mktemp -d /tmp/agent-chat-smoke.XXXXXX) || { echo "Test-agent-chat FAILED: no temp dir"; exit 1; }

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
CHAT=${AGENT_CHAT_BACKEND:-${AGENT_DIR}/agent-chat.py}

# ports found free now, one list for the whole run (python holds them all open while it looks, so none repeats)
mapfile -t PORTS < <(python3 - << 'PYEOF'
import socket
socks = []
for _ in range(45):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); socks.append(s)
for s in socks:
    print(s.getsockname()[1])
for s in socks:
    s.close()
PYEOF
)
[ "${#PORTS[@]}" == "45" ] || { echo "Test-agent-chat FAILED: could not find 45 free ports"; exit 1; }
HOME_PORT=${PORTS[0]} CHAT_PORT=${PORTS[1]} RO_PORT=${PORTS[2]}
# every other UI on a test-local port with nothing behind it: nginx starts all the same
export UI_DIR=${D}/ui
export UI_LISTEN_HOST=127.0.0.1
export UI_HOME_ROUTE_TABLE=/dev/null
# the Loop Deck adapter writes the Deck's inputs at every UI start (/wd/loop-deck by default): test-local, so this test
# writes nothing under /wd in a container ./test.sh did not start either (./test.sh passes LOOP_DECK_DATA_DIR itself;
# without it, a plain run of this test created /wd/loop-deck - and /wd itself where the image has none)
export LOOP_DECK_DATA_DIR=${D}/loop-deck
export UI_PORT_HOME=${HOME_PORT} UI_PORT_CHAT=${CHAT_PORT} UI_PORT_HEADLAMP=${PORTS[3]} UI_PORT_HINDSIGHT_API=${PORTS[4]} \
	UI_PORT_HINDSIGHT_UI=${PORTS[5]} UI_PORT_VIBE_KANBAN=${PORTS[6]} UI_PORT_TMUX=${PORTS[7]} UI_PORT_TMUX_AGENT=${PORTS[8]} \
	UI_PORT_CLAUDE_MEM=${PORTS[9]} UI_PORT_LOGLEARNER=${PORTS[10]} COMMS_UI_PORT=${PORTS[11]} UI_PORT_KANBAN_SIGNIN=${PORTS[12]}
P_NOESC=${PORTS[13]} P_SHELL=${PORTS[14]} P_NOSTRIP=${PORTS[15]} P_NOCAP=${PORTS[16]} P_COUNT=${PORTS[17]} P_NOORIGIN=${PORTS[18]}
P_NOCMD=${PORTS[19]} P_NOSESSION=${PORTS[20]} P_CORS=${PORTS[21]} P_LIFECYCLE=${PORTS[22]} P_NOLOCK=${PORTS[23]}
# shellcheck disable=SC2034 # the P_WR_* ports are read through ${!PV} in check 12
P_WR_False=${PORTS[24]} P_WR_FALSE=${PORTS[25]} P_WR_no=${PORTS[26]} P_WR_0=${PORTS[27]} P_WR_off=${PORTS[28]} P_WR_true=${PORTS[29]}
P_WR_MUT=${PORTS[30]} P_NOSEMI=${PORTS[31]} P_NOHDR=${PORTS[32]} P_RT=${PORTS[33]} P_NORT=${PORTS[34]} P_TT=${PORTS[35]} P_NOTT=${PORTS[36]}
P_NOMENU=${PORTS[37]} P_NOKEY=${PORTS[38]} P_BLINDENTER=${PORTS[39]} P_OTHERCLI=${PORTS[40]} P_WRAPPER=${PORTS[41]}
P_SPOKE=${PORTS[42]} P_HUBREG=${PORTS[43]} P_NOREG=${PORTS[44]}
unset KANBAN_BOARD_URL PLANE_URL
# a tmux server of this test's own: its socket directory, and no TMUX of a pane this test may run in (the variable
# would send every tmux call to that pane's server)
export TMUX_TMPDIR=${D}/tmux
mkdir -p "${TMUX_TMPDIR}"
unset TMUX
SESSION=chat-smoke-$$
export AGENT_TMUX_SESSION_NAME=${SESSION}
PIDS=()
OK=false

cleanup()
{
	for P in "${PIDS[@]}"; do kill "${P}" 2>/dev/null; done
	[ -f "${UI_DIR}/home/nginx.pid" ] && kill "$(cat "${UI_DIR}/home/nginx.pid")" 2>/dev/null
	tmux kill-session -t "=${SESSION}" 2>/dev/null
	tmux kill-session -t "=${SESSION}-wrapper" 2>/dev/null
	if [ "${OK}" == "true" ]; then
		rm -rf "${D:?}"
	else
		echo "Test-agent-chat: state kept at ${D}"
	fi
}
trap cleanup EXIT

fail()
{
	echo "Test-agent-chat FAILED: $1"
	exit 1
}

# --- 1. syntax ---
bash -n "$0" || fail "bash -n $0"
for S in home-render.sh ui-start.sh ui-stop.sh ui-status.sh; do
	bash -n "${AGENT_DIR}/${S}" || fail "bash -n ${S}"
done
# ast.parse, not py_compile: the latter writes a __pycache__ next to the source, and the checkout is mounted read-only
# in the test container
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${CHAT}" || fail "python3 cannot parse agent-chat.py"
echo "ok 1 - syntax"

# --- 2. the route, the probe and the tile ---
"${AGENT_DIR}/home-render.sh" > /dev/null 2> "${D}/render.err" || fail "home-render.sh"
HOME_DIR=${UI_DIR}/home
CONF=${HOME_DIR}/nginx.conf
PAGE=${HOME_DIR}/site/index.html
# block <server_name> - the server block of a host route, as one line
block() { python3 -c '
import sys
t = open(sys.argv[1]).read()
i = t.find("server_name " + sys.argv[2] + ";")
assert i > 0, "no server block for " + sys.argv[2]
s = t.rfind("server {", 0, i)
depth, opened = 0, False
for j in range(s, len(t)):
    depth += {"{": 1, "}": -1}.get(t[j], 0)
    opened = opened or depth > 0
    if opened and depth == 0:
        print(" ".join(t[s:j + 1].split())); break
' "${CONF}" "$1"; }
B=$(block chat.localhost) || fail "no chat.localhost server block"
echo "${B}" | grep -qF "proxy_pass http://127.0.0.1:${CHAT_PORT};" || fail "chat.localhost does not proxy to the backend port: ${B}"
echo "${B}" | grep -qF "badge-host-nolink.conf" || fail "the chat route carries no home badge include (the page links the stylesheet itself, so the link-free badge)"
echo "${B}" | grep -qF 'proxy_redirect ~^https?://(127\.0\.0\.1|localhost|\[::1\]):'"${CHAT_PORT}" || fail "the chat route lacks the shared host redirect rules"
echo "${B}" | grep -qF "client_max_body_size 64k;" || fail "the chat route does not bound the request body"
echo "${B}" | grep -qF "location = /__harness/harness.css" || fail "the chat route does not serve the harness stylesheet (the design system must be beneath this branch): ${B}"
PROBE=$(python3 -c '
import sys
t = open(sys.argv[1]).read()
i = t.find("location = /__probe/chat {"); j = t.find("location = /__probe_up/chat {")
assert i > 0 and j > i, "no /__probe/chat pair"
k = t.find("}", t.find("proxy_set_header Host", j))
print(" ".join(t[i:k + 1].split()))
' "${CONF}") || fail "no /__probe/chat location pair"
for W in "limit_except GET { deny all; }" "auth_request /__probe_up/chat;" "try_files /__probe_nonexistent =204;" \
         "proxy_pass http://127.0.0.1:${CHAT_PORT}/healthz;" "proxy_pass_request_body off;" 'proxy_set_header Cookie "";'; do
	echo "${PROBE}" | grep -qF "${W}" || fail "the chat probe lacks '${W}': ${PROBE}"
done
TILE=$(grep -o '<li class="tile" data-host="chat"[^>]*>.*Agent chat</a>' "${PAGE}") || fail "no live Agent chat tile"
echo "${TILE}" | grep -qF 'data-probe="/__probe/chat"' || fail "the Agent chat tile reads no probe: ${TILE}"
# a new tab; whether the tab keeps its opener (the home badge's return path) is the home page's rule for every tile,
# and differs between bases, so it is not asserted here
echo "${TILE}" | grep -qE 'target="_blank" rel="(no)?opener"' || fail "the Agent chat tile does not open a new tab: ${TILE}"
# the loopback-names server block is the only place the probe may live (test16 check 7's rule): it comes before any host block
[ "$(grep -n 'location = /__probe/chat' "${CONF}" | cut -d: -f1)" -lt "$(grep -n 'server_name chat.localhost' "${CONF}" | cut -d: -f1)" ] \
	|| fail "the chat probe is not on the home listener's loopback-names server"
if command -v nginx > /dev/null; then
	nginx -t -c "${CONF}" > /dev/null 2>&1 || { nginx -t -c "${CONF}"; fail "the rendered nginx.conf does not validate"; }
fi
# off: no route, no probe, a greyed tile naming the flag
( export UI_CHAT=false UI_DIR=${D}/ui-off; "${AGENT_DIR}/home-render.sh" > /dev/null 2>&1 ) || fail "home-render.sh (UI_CHAT=false)"
grep -q "server_name chat.localhost" "${D}/ui-off/home/nginx.conf" && fail "UI_CHAT=false still renders the chat route"
grep -q "__probe/chat" "${D}/ui-off/home/nginx.conf" && fail "UI_CHAT=false still renders the chat probe"
grep -oE 'Agent chat</span>.{0,300}' "${D}"/ui-off/home/*/index.html | grep -q "off - set UI_CHAT=true in .env" || fail "UI_CHAT=false does not grey the tile with its flag"
if command -v nginx > /dev/null; then
	nginx -t -c "${D}/ui-off/home/nginx.conf" > /dev/null 2>&1 || fail "the UI_CHAT=false nginx.conf does not validate"
fi
echo "ok 2 - chat.localhost routes to the backend with the badge and the redirect rules; /__probe/chat is GET-only and status-only; the tile is live with the probe and greyed with its flag when off"

# --- the stub agent session and the backend ---
if ! command -v tmux > /dev/null; then
	echo "Test-agent-chat skipped checks 3-15: tmux not installed (setup/install-tmux.sh)"
	OK=true
	echo "Test-agent-chat succeeded"
	exit 0
fi
cat > "${D}/stub-agent.sh" << 'EOF'
#!/bin/bash
# a stand-in for the agent CLI: prints every line it receives, so a test can read what was typed at its prompt, and
# draws its prompt the way Claude Code does - a "❯" line between two rules - after each, since the page types only
# at a prompt it can see (check 20 proves the reading on the CLI's own screens, and refuses a pane without one)
prompt() { echo "────────────────────────────────────────────────────────────────────"; echo "❯ "; echo "────────────────────────────────────────────────────────────────────"; }
echo "stub agent ready"
prompt
while IFS= read -r line; do printf 'stub agent received: [%s]\n' "$line"; prompt; done
EOF
# `exec -a claude`: the pane's foreground process is this bash with argv[0] "claude" - what tmux reports as the
# pane's current command, and what the backend's check reads (the real agent CLI reports "claude" the same way)
tmux new-session -d -s "${SESSION}" -x 160 -y 40 "exec -a claude bash ${D}/stub-agent.sh" || fail "could not start the stub session"
for _ in $(seq 1 50); do [ "$(tmux display-message -t "=${SESSION}:" -p '#{pane_current_command}')" == "claude" ] && break; sleep 0.2; done
[ "$(tmux display-message -t "=${SESSION}:" -p '#{pane_current_command}')" == "claude" ] || fail "the stub pane does not report claude as its command"
# screen - the stub pane's text, as the backend captures it
screen() { tmux capture-pane -p -t "=${SESSION}:" -S -400; }
# wait_screen <text> - polls (up to 6 s) until the pane shows the text
wait_screen() { for _ in $(seq 1 30); do screen | grep -qF -- "$1" && return 0; sleep 0.2; done; return 1; }
# backend <port> <script> [VAR=value ...] - a backend on the port, waited for
backend()
{
	local PORT=$1 SCRIPT=$2; shift 2
	env UI_PORT_CHAT="${PORT}" "$@" python3 "${SCRIPT}" > "${D}/chat-${PORT}.log" 2>&1 &
	PIDS+=($!)
	echo $! > "${D}/chat-${PORT}.pid"
	for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${PORT}/healthz" && return 0; sleep 0.2; done
	fail "the backend on ${PORT} did not come up: $(tail -3 "${D}/chat-${PORT}.log")"
}
# mutant <name> <anchor> <replacement> - a copy of the backend with one line changed (the anchor must be there once)
mutant()
{
	mkdir -p "${D}/mutant"
	python3 - "${CHAT}" "${D}/mutant/$1.py" "$2" "$3" << 'PYEOF' || fail "could not plant the control $1"
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src).read()
assert s.count(a) == 1, f"anchor found {s.count(a)} times: {a!r}"
open(dst, "w").write(s.replace(a, b))
PYEOF
}
# req <port> <method> <path> [curl args...] - status code, headers in ${D}/hdr, body in ${D}/body; the Host of the
# chat page on that port unless a Host is given
req()
{
	local PORT=$1 METHOD=$2 P=$3; shift 3
	local HOSTARG=(-H "Host: chat.localhost:${PORT}")
	for A in "$@"; do case "${A}" in Host:*) HOSTARG=() ;; esac; done
	curl -s -o "${D}/body" -D "${D}/hdr" -w '%{http_code}' --max-time 10 -X "${METHOD}" "${HOSTARG[@]}" "$@" "http://127.0.0.1:${PORT}${P}"
}
# post <port> <text> [curl args...] - a JSON send from the page's own origin on that port unless headers say otherwise
post()
{
	local PORT=$1 TEXT=$2; shift 2
	local ORIGIN=(-H "Origin: http://chat.localhost:${PORT}")
	for A in "$@"; do case "${A}" in Origin:*|Referer:*|no-origin) ORIGIN=() ;; esac; done
	local ARGS=(); for A in "$@"; do [ "${A}" == "no-origin" ] || ARGS+=("${A}"); done
	req "${PORT}" POST /send -H "Content-Type: application/json" "${ORIGIN[@]}" "${ARGS[@]}" --data-binary "$(python3 -c 'import json, sys; print(json.dumps({"text": sys.argv[1]}))' "${TEXT}")"
}
hdr() { grep -i "^$1:" "${D}/hdr" | tr -d '\r' | cut -d' ' -f2-; }
backend "${CHAT_PORT}" "${CHAT}"

# --- 3. the pane's text is escaped ---
PLANTED='<script>alert("planted")</script>'
tmux send-keys -t "=${SESSION}:" -l -- "${PLANTED}"
tmux send-keys -t "=${SESSION}:" Enter
wait_screen "stub agent received: [${PLANTED}]" || fail "the stub never showed the planted markup: $(screen | tail -5)"
[ "$(req "${CHAT_PORT}" GET /)" == "200" ] || fail "GET / is not 200: $(cat "${D}/body")"
hdr content-type | grep -q "text/html" || fail "the page is not text/html: $(hdr content-type)"
grep -q "Agent chat" "${D}/body" || fail "the page does not say Agent chat"
grep -qF '&lt;script&gt;alert(&quot;planted&quot;)&lt;/script&gt;' "${D}/body" || fail "the page does not carry the pane's markup as escaped text"
grep -qF "${PLANTED}" "${D}/body" && fail "the page carries the pane's markup as markup"
[ "$(req "${CHAT_PORT}" GET /pane)" == "200" ] || fail "GET /pane is not 200"
hdr content-type | grep -q "text/plain" || fail "/pane is not text/plain: $(hdr content-type)"
grep -qF "${PLANTED}" "${D}/body" || fail "/pane does not carry the pane's text"
mutant no-escape '.replace("__PANE__", html.escape(shown)))' '.replace("__PANE__", shown))'
backend "${P_NOESC}" "${D}/mutant/no-escape.py"
[ "$(req "${P_NOESC}" GET /)" == "200" ] || fail "the no-escape control did not serve its page"
grep -qF "${PLANTED}" "${D}/body" || fail "PLANTED CONTROL BROKEN: the backend without escaping does not serve the markup as markup"
echo "ok 3 - the page carries the pane's <script> as text, never as markup (/pane is text/plain); control: without the escaping the markup is served as markup"

# --- 4. a literal send plus Enter ---
MSG="hello \$(touch ${D}/never) ; C-c Enter <b>x</b>"
CODE=$(post "${CHAT_PORT}" "${MSG}"$'\n\t'"tab"$'\x1b'"[2Jend")
[ "${CODE}" == "200" ] || fail "the send answered ${CODE}: $(cat "${D}/body")"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["sent"] is True and d["chars"] > 0 and "transport" in d["note"] and "prompt" in d["note"], d' "${D}/body" \
	|| fail "the acknowledgement is not a transport acknowledgement: $(cat "${D}/body")"
WANT="stub agent received: [${MSG}  tab [2Jend]"
wait_screen "${WANT}" || fail "the stub did not receive the literal message with its control characters as spaces: $(screen | tail -5)"
[ -e "${D}/never" ] && fail "the \$(...) in the message ran somewhere"
[ "$(tmux display-message -t "=${SESSION}:" -p '#{pane_current_command}')" == "claude" ] || fail "the stub is gone after a message carrying C-c (it was read as a key, not as text)"
# the control sends through a shell command line (the reads stay as they are, so it gets as far as the send)
mutant shell-send 'return subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=TMUX_TIMEOUT, stdin=subprocess.DEVNULL)' \
	'return subprocess.run("tmux " + " ".join(args), shell=True, capture_output=True, text=True, timeout=TMUX_TIMEOUT, stdin=subprocess.DEVNULL) if args[0] == "send-keys" else subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=TMUX_TIMEOUT, stdin=subprocess.DEVNULL)'
backend "${P_SHELL}" "${D}/mutant/shell-send.py"
LEAK="hi; touch ${D}/leak"
post "${P_SHELL}" "${LEAK}" > /dev/null
sleep 1
if wait_screen "stub agent received: [${LEAK}]" && [ ! -e "${D}/leak" ]; then
	fail "PLANTED CONTROL BROKEN: the backend that hands tmux a shell command line delivered the message literally and ran nothing"
fi
[ -e "${D}/leak" ] || fail "PLANTED CONTROL BROKEN: the shell-sending backend ran no part of the message"
# the control characters: a copy that does not replace them hands the newline to the pane, where it ends a line of
# its own - two inputs out of one message
mutant no-strip 'text = CONTROL.sub(" ", text).strip()' 'text = text.strip()'
backend "${P_NOSTRIP}" "${D}/mutant/no-strip.py"
post "${P_NOSTRIP}" "first half"$'\n'"second half" > /dev/null
wait_screen "stub agent received: [first half]" || fail "PLANTED CONTROL BROKEN: the backend without the stripping did not hand the newline to the pane as a line end"
wait_screen "stub agent received: [second half]" || fail "PLANTED CONTROL BROKEN: the backend without the stripping did not deliver the second half on its own"
# the cap: 4000 characters go through, 4001 are 413; a copy without the cap types the 4001
LONG=$(head -c 4001 /dev/zero | tr '\0' 'x')
[ "$(post "${CHAT_PORT}" "${LONG}")" == "413" ] || fail "a 4001-character message is not 413: $(cat "${D}/body")"
grep -q '"sent": false' "${D}/body" || fail "the cap's refusal does not say sent false"
[ "$(post "${CHAT_PORT}" "${LONG:1}")" == "200" ] || fail "a 4000-character message is refused: $(cat "${D}/body")"
wait_screen "stub agent received: [xxxxxxxx" || fail "the 4000-character message never arrived"
mutant no-cap 'if len(text) > MAX_LEN:' 'if False and len(text) > MAX_LEN:'
backend "${P_NOCAP}" "${D}/mutant/no-cap.py"
[ "$(post "${P_NOCAP}" "${LONG}")" == "200" ] || fail "PLANTED CONTROL BROKEN: the backend without the cap still refused 4001 characters"
echo "ok 4 - the message arrived character for character with Enter (\$(...), ';', C-c, Enter and <b> as text; newline, tab and escape as spaces), nothing ran, the stub lives; 4000 characters pass, 4001 are 413; controls: the shell-sending backend ran the ';' part and delivered only 'hi', the non-stripping one made two inputs of one message, the uncapped one typed 4001"

# --- 5. same-origin, POST only, the chat Host ---
SCREEN_BEFORE=$(screen | grep -c 'stub agent received')
for CASE in "Origin: http://evil.localhost:${CHAT_PORT}" "Origin: http://chat.localhost:9" "Origin: null" "Origin: http://localhost:${CHAT_PORT}" "Referer: http://evil.localhost:${CHAT_PORT}/" no-origin; do
	if [ "${CASE}" == "no-origin" ]; then
		CODE=$(post "${CHAT_PORT}" "cross-origin ${CASE}" no-origin)
	else
		CODE=$(post "${CHAT_PORT}" "cross-origin ${CASE}" -H "${CASE}")
	fi
	[ "${CODE}" == "403" ] || fail "a POST with '${CASE}' answered ${CODE}, not 403: $(cat "${D}/body")"
	grep -q '"sent": false' "${D}/body" || fail "the refusal does not say sent false: $(cat "${D}/body")"
done
sleep 1
[ "$(screen | grep -c 'stub agent received')" == "${SCREEN_BEFORE}" ] || fail "a refused POST still typed into the pane: $(screen | tail -3)"
CODE=$(post "${CHAT_PORT}" "via referer" no-origin -H "Referer: http://chat.localhost:${CHAT_PORT}/")
[ "${CODE}" == "200" ] || fail "a POST with the page's Referer and no Origin answered ${CODE}: $(cat "${D}/body")"
wait_screen "stub agent received: [via referer]" || fail "the Referer-authorised message never arrived"
[ "$(req "${CHAT_PORT}" GET /send)" == "404" ] || fail "GET /send is not refused"
[ "$(req "${CHAT_PORT}" POST /pane -H "Origin: http://chat.localhost:${CHAT_PORT}")" == "404" ] || fail "POST /pane is not refused"
for P in / /pane /state; do
	[ "$(req "${CHAT_PORT}" GET "${P}" -H "Host: 127.0.0.1:${CHAT_PORT}")" == "403" ] || fail "GET ${P} with a loopback Host is not 403"
done
[ "$(post "${CHAT_PORT}" "wrong host" -H "Host: evil.localhost:${CHAT_PORT}" -H "Origin: http://evil.localhost:${CHAT_PORT}")" == "403" ] || fail "a POST with a foreign Host is not 403"
[ "$(req "${CHAT_PORT}" GET /healthz -H "Host: 127.0.0.1:${CHAT_PORT}")" == "200" ] || fail "/healthz does not answer the probe's loopback Host"
# a refusal makes NO tmux call at all, and an accepted send makes exactly the two keystroke calls - counted through a
# tmux on the backend's PATH that logs every call before handing it to the real one
mkdir -p "${D}/bin"
cat > "${D}/bin/tmux" << TMUXEOF
#!/bin/bash
echo "\$*" >> "${D}/tmux-calls.log"
exec $(command -v tmux) "\$@"
TMUXEOF
chmod +x "${D}/bin/tmux"
backend "${P_COUNT}" "${CHAT}" PATH="${D}/bin:${PATH}"
: > "${D}/tmux-calls.log"
post "${P_COUNT}" "cross-origin, counted" -H "Origin: http://evil.localhost:${P_COUNT}" > /dev/null
[ "$(wc -l < "${D}/tmux-calls.log")" == "0" ] || fail "a cross-origin POST made $(wc -l < "${D}/tmux-calls.log") tmux call(s): $(cat "${D}/tmux-calls.log")"
post "${P_COUNT}" "same-origin, counted" > /dev/null
wait_screen "stub agent received: [same-origin, counted]" || fail "the counted same-origin send never arrived"
[ "$(grep -c '^send-keys ' "${D}/tmux-calls.log")" == "2" ] || fail "an accepted send made $(grep -c '^send-keys ' "${D}/tmux-calls.log") send-keys calls, not 2: $(cat "${D}/tmux-calls.log")"
grep -q '^send-keys -t %[0-9]* -l -- same-origin, counted$' "${D}/tmux-calls.log" || fail "the text is not one literal send-keys -l -- call: $(cat "${D}/tmux-calls.log")"
grep -q '^send-keys -t %[0-9]* Enter$' "${D}/tmux-calls.log" || fail "the Enter is not a send-keys call of its own: $(cat "${D}/tmux-calls.log")"
mutant no-origin-check 'if not same_origin(self.headers, host):' 'if False and not same_origin(self.headers, host):'
backend "${P_NOORIGIN}" "${D}/mutant/no-origin-check.py"
CODE=$(post "${P_NOORIGIN}" "mutant typed from a foreign origin" -H "Origin: http://evil.localhost:${P_NOORIGIN}")
[ "${CODE}" == "200" ] || fail "PLANTED CONTROL BROKEN: the backend without the same-origin check still refused (${CODE})"
wait_screen "stub agent received: [mutant typed from a foreign origin]" || fail "PLANTED CONTROL BROKEN: the backend without the check typed nothing"
echo "ok 5 - a foreign, other-port, null or absent origin is 403, types nothing and makes no tmux call; an accepted send is exactly one literal send-keys -l -- and one Enter; the page's Referer stands in for Origin; GET /send and POST /pane are refused; a Host that is not chat.localhost is 403 (/healthz excepted); control: without the check a foreign page's message is typed"

# --- 6. the pane must run the agent CLI ---
tmux new-window -t "=${SESSION}:" bash
for _ in $(seq 1 25); do [ "$(tmux display-message -t "=${SESSION}:" -p '#{pane_current_command}')" == "bash" ] && break; sleep 0.2; done
[ "$(tmux display-message -t "=${SESSION}:" -p '#{pane_current_command}')" == "bash" ] || fail "the shell window did not become the active pane"
CODE=$(post "${CHAT_PORT}" ": typed into a shell")
[ "${CODE}" == "409" ] || fail "a send to a shell pane answered ${CODE}, not 409: $(cat "${D}/body")"
grep -q "runs 'bash', not the agent CLI (claude)" "${D}/body" || fail "the refusal does not name the pane's command: $(cat "${D}/body")"
[ "$(req "${CHAT_PORT}" GET /state)" == "200" ] || fail "/state is not 200"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["writable"] is False and d["command"] == "bash" and "not the agent CLI" in d["reason"], d' "${D}/body" \
	|| fail "/state does not say why sending is off: $(cat "${D}/body")"
sleep 1
tmux capture-pane -p -t "=${SESSION}:1" | grep -qF "typed into a shell" && fail "the refused message was typed into the shell"
mutant no-command-check '    if command not in COMMANDS:' '    if False and command not in COMMANDS:'
backend "${P_NOCMD}" "${D}/mutant/no-command-check.py"
CODE=$(post "${P_NOCMD}" ": mutant typed into a shell")
[ "${CODE}" == "200" ] || fail "PLANTED CONTROL BROKEN: the backend without the command check still refused the shell pane (${CODE}): $(cat "${D}/body")"
for _ in $(seq 1 30); do tmux capture-pane -p -t "=${SESSION}:1" | grep -qF ": mutant typed into a shell" && break; sleep 0.2; done
tmux capture-pane -p -t "=${SESSION}:1" | grep -qF ": mutant typed into a shell" || fail "PLANTED CONTROL BROKEN: the backend without the check typed nothing into the shell"
tmux kill-window -t "=${SESSION}:1"
for _ in $(seq 1 25); do [ "$(tmux display-message -t "=${SESSION}:" -p '#{pane_current_command}')" == "claude" ] && break; sleep 0.2; done
[ "$(post "${CHAT_PORT}" "back at the agent")" == "200" ] || fail "with the stub pane active again the send did not go through: $(cat "${D}/body")"
wait_screen "stub agent received: [back at the agent]" || fail "the message after the shell window never arrived"
# a session that is not there
backend "${P_NOSESSION}" "${CHAT}" AGENT_TMUX_SESSION_NAME=no-such-session
[ "$(req "${P_NOSESSION}" GET /)" == "200" ] || fail "with no session the page is not 200"
grep -q "no pane to show: no tmux session named &#x27;no-such-session&#x27;" "${D}/body" || fail "with no session the page does not say so (escaped): $(grep -o 'no pane to show[^<]*' "${D}/body")"
[ "$(post "${P_NOSESSION}" "nobody home")" == "409" ] || fail "with no session a send is not 409: $(cat "${D}/body")"
[ "$(req "${P_NOSESSION}" GET /pane)" == "503" ] || fail "with no session /pane is not 503"
echo "ok 6 - a shell pane: 409 naming 'bash', nothing typed, /state says why; the agent pane again: typed; control: without the check the shell receives the message; no session: page 200 saying so, send 409, /pane 503"

# --- 7. the dot follows the probe (through nginx) ---
if command -v nginx > /dev/null; then
	nginx -c "${CONF}" -g "daemon off;" > "${D}/nginx.log" 2>&1 &
	PIDS+=($!)
	for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${HOME_PORT}/" && break; sleep 0.2; done
	H=http://127.0.0.1:${HOME_PORT}
	probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X "${1:-GET}" "${H}/__probe/chat"; }
	[ "$(probe)" == "204" ] || fail "/__probe/chat is not 204 with the backend up ($(probe))"
	[ "$(probe POST)" == "403" ] || fail "a POST to /__probe/chat is not 403"
	# through the proxy: the page with the badge once, pointing home on the browser's port, and a send end to end
	CODE=$(curl -s -o "${D}/proxied.html" -D "${D}/hdr" -w '%{http_code}' -H "Host: chat.localhost:${HOME_PORT}" "${H}/")
	[ "${CODE}" == "200" ] || fail "the page through the proxy is ${CODE}"
	# the badge by its marker (data-harness-home, or the id the earlier badge carried), not by its text or style, which are
	# the home page's to change: one link carrying either marker is one badge (the badge may carry both)
	[ "$(grep -oE '<a [^>]*(data-harness-home|id="do-agent-aws-home")[^>]*>' "${D}/proxied.html" | wc -l)" == "1" ] || fail "the proxied page carries the badge $(grep -oE '<a [^>]*(data-harness-home|id="do-agent-aws-home")[^>]*>' "${D}/proxied.html" | wc -l) times"
	grep -qF "href=\"//localhost:${HOME_PORT}/\" title=\"do-agent-aws harness home\"" "${D}/proxied.html" || fail "the badge does not return to //localhost:${HOME_PORT}/"
	CODE=$(curl -s -o "${D}/body" -w '%{http_code}' --max-time 10 -H "Host: chat.localhost:${HOME_PORT}" -H "Origin: http://chat.localhost:${HOME_PORT}" \
		-H "Content-Type: application/json" --data-binary '{"text": "through the proxy"}' "${H}/send")
	[ "${CODE}" == "200" ] || fail "a send through the proxy answered ${CODE}: $(cat "${D}/body")"
	wait_screen "stub agent received: [through the proxy]" || fail "the message sent through the proxy never arrived"
	CODE=$(curl -s -o "${D}/body" -w '%{http_code}' --max-time 10 -H "Host: chat.localhost:${HOME_PORT}" -H "Origin: http://localhost:${HOME_PORT}" \
		-H "Content-Type: application/json" --data-binary '{"text": "from the home page"}' "${H}/send")
	[ "${CODE}" == "403" ] || fail "through the proxy a send from the home page's origin is ${CODE}, not 403"
	# the control: the backend stopped
	kill "$(cat "${D}/chat-${CHAT_PORT}.pid")"
	for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${CHAT_PORT}/healthz" || break; sleep 0.2; done
	[ "$(probe)" == "500" ] || fail "PLANTED CONTROL: with the backend stopped /__probe/chat is $(probe), not 500 (the dot would stay green)"
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: chat.localhost:${HOME_PORT}" "${H}/")" == "502" ] || fail "with the backend stopped the page is not 502"
	backend "${CHAT_PORT}" "${CHAT}"
	[ "$(probe)" == "204" ] || fail "with the backend back /__probe/chat is not 204"
	echo "ok 7 - /__probe/chat: 204 up, 403 to POST, 500 with the backend stopped (control), 204 again; the proxied page carries the badge once, pointing home on the browser's port; a send through the proxy from the page's origin is typed, one from the home page's origin is 403"
else
	echo "ok 7 - (skipped: nginx not installed - setup/install-nginx.sh)"
fi

# --- 8. ui-start.sh, ui-status.sh, ui-stop.sh ---
# every other UI off (UI_LOOP: the loop view, where a tree has it), so the start, status and stop logs are the chat row's
UI_ENV=("UI_DIR=${D}/ui-lifecycle" UI_HOME=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_FILES=false "UI_PORT_CHAT=${P_LIFECYCLE}")
env "${UI_ENV[@]}" UI_CHAT=true "${AGENT_DIR}/ui-start.sh" > "${D}/ui-start.log" 2>&1 || { cat "${D}/ui-start.log"; fail "ui-start.sh"; }
grep -q "^agent-chat: started" "${D}/ui-start.log" || fail "ui-start.sh did not start agent-chat: $(cat "${D}/ui-start.log")"
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${P_LIFECYCLE}/healthz" && break; sleep 0.2; done
env "${UI_ENV[@]}" UI_CHAT=true "${AGENT_DIR}/ui-status.sh" > "${D}/ui-status.log" 2>&1
grep -q "^agent-chat: UP pid=[0-9]* http=200 port=${P_LIFECYCLE}" "${D}/ui-status.log" || fail "ui-status.sh does not report agent-chat UP: $(grep agent-chat "${D}/ui-status.log")"
PID_OF_UI=$(cat "${D}/ui-lifecycle/agent-chat.pid")
tr '\0' ' ' < "/proc/${PID_OF_UI}/cmdline" | grep -q "agent-chat.py" || fail "the recorded pid is not the backend"
env "${UI_ENV[@]}" UI_CHAT=true "${AGENT_DIR}/ui-start.sh" > "${D}/ui-start2.log" 2>&1
grep -q "^agent-chat: already running" "${D}/ui-start2.log" || fail "a second ui-start.sh did not leave the running backend alone: $(cat "${D}/ui-start2.log")"
env "${UI_ENV[@]}" "${AGENT_DIR}/ui-stop.sh" > "${D}/ui-stop.log" 2>&1
grep -q "^agent-chat: stopped" "${D}/ui-stop.log" || fail "ui-stop.sh did not stop agent-chat: $(cat "${D}/ui-stop.log")"
curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${P_LIFECYCLE}/healthz" && fail "the backend still answers after ui-stop.sh"
env "${UI_ENV[@]}" UI_CHAT=true "${AGENT_DIR}/ui-status.sh" > "${D}/ui-status2.log" 2>&1 && fail "ui-status.sh exits 0 with the enabled chat down"
grep -q "^agent-chat: DOWN port=${P_LIFECYCLE}" "${D}/ui-status2.log" || fail "ui-status.sh does not report the stopped chat DOWN: $(grep agent-chat "${D}/ui-status2.log")"
env "${UI_ENV[@]}" UI_CHAT=false "${AGENT_DIR}/ui-start.sh" > "${D}/ui-start3.log" 2>&1
# the chat ROW must be absent - anchored to the row format, because another UI's start line names its log under the
# instance directory, whose path carries this test's name (agent-chat-smoke): a planted line of that shape stands in
# for it, and an unanchored grep for "agent-chat" would read it as the chat started
printf 'other-ui: started (pid 1, log %s/other-ui.log)\n' "${D}/ui-lifecycle" >> "${D}/ui-start3.log"
grep -q "^agent-chat:" "${D}/ui-start3.log" && fail "UI_CHAT=false still starts agent-chat: $(cat "${D}/ui-start3.log")"
env "${UI_ENV[@]}" UI_CHAT=false "${AGENT_DIR}/ui-status.sh" > "${D}/ui-status3.log" 2>&1
grep -q "^agent-chat: DISABLED" "${D}/ui-status3.log" || fail "UI_CHAT=false does not read DISABLED: $(grep agent-chat "${D}/ui-status3.log")"
echo "ok 8 - ui-start.sh starts the backend once (a re-run leaves it alone), ui-status.sh reads UP then DOWN with rc 1, ui-stop.sh stops it and the port closes; UI_CHAT=false starts nothing and reads DISABLED"

# --- 9. watch-only ---
backend "${RO_PORT}" "${CHAT}" UI_TMUX_WRITABLE=false
[ "$(req "${RO_PORT}" GET /)" == "200" ] || fail "the watch-only page is not 200"
[ "$(req "${RO_PORT}" GET /pane)" == "200" ] || fail "the watch-only /pane is not 200"
[ "$(req "${RO_PORT}" GET /state)" == "200" ] || fail "the watch-only /state is not 200"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["writable"] is False and "UI_TMUX_WRITABLE=false" in d["reason"], d' "${D}/body" \
	|| fail "the watch-only /state does not say sending is off and why: $(cat "${D}/body")"
[ "$(post "${RO_PORT}" "watch-only message")" == "403" ] || fail "a send to the watch-only backend is not 403: $(cat "${D}/body")"
grep -q "watch-only" "${D}/body" || fail "the watch-only refusal does not say watch-only: $(cat "${D}/body")"
sleep 1
screen | grep -qF "watch-only message" && fail "the watch-only backend typed the message"
[ "$(post "${CHAT_PORT}" "writable control")" == "200" ] || fail "the default-writable backend refused: $(cat "${D}/body")"
wait_screen "stub agent received: [writable control]" || fail "the writable control's message never arrived"
echo "ok 9 - UI_TMUX_WRITABLE=false: the page and the pane answer, /state says sending is off and why, a send is 403 and types nothing; control: the default backend types it"

# --- 10. the headers ---
for CASE in "GET /" "GET /pane" "GET /state" "GET /healthz" "GET /nowhere"; do
	# shellcheck disable=SC2086 # the case is a method and a path, two words on purpose
	req "${CHAT_PORT}" ${CASE} -H "Origin: http://evil.localhost:${CHAT_PORT}" > /dev/null
	[ "$(hdr cache-control)" == "no-store" ] || fail "${CASE} lacks Cache-Control: no-store ($(hdr cache-control))"
	[ "$(hdr x-content-type-options)" == "nosniff" ] || fail "${CASE} lacks X-Content-Type-Options: nosniff"
	grep -qi '^access-control-' "${D}/hdr" && fail "${CASE} answers a CORS header: $(grep -i '^access-control-' "${D}/hdr")"
	grep -qi '^content-security-policy:.*frame-ancestors .none.' "${D}/hdr" || fail "${CASE} does not forbid framing"
done
for CASE in 200 403; do
	if [ "${CASE}" == "200" ]; then post "${CHAT_PORT}" "headers ${CASE}" > /dev/null; else post "${CHAT_PORT}" "headers ${CASE}" -H "Origin: http://evil.localhost:${CHAT_PORT}" > /dev/null; fi
	[ "$(hdr cache-control)" == "no-store" ] || fail "a ${CASE} send answer lacks Cache-Control: no-store"
	grep -qi '^access-control-' "${D}/hdr" && fail "a ${CASE} send answer carries a CORS header"
done
mutant cors 'self.send_header(name, value)' 'self.send_header("Access-Control-Allow-Origin", "*")'
backend "${P_CORS}" "${D}/mutant/cors.py"
req "${P_CORS}" GET /pane -H "Origin: http://evil.localhost:${P_CORS}" > /dev/null
{ [ "$(hdr cache-control)" != "no-store" ] && grep -qi '^access-control-allow-origin' "${D}/hdr"; } || fail "PLANTED CONTROL BROKEN: the backend that allows any origin passes the header check"
echo "ok 10 - every answer: Cache-Control no-store, nosniff, frame-ancestors none, no CORS header (an Origin on the request changes nothing); control: the any-origin backend fails the check"

# --- 11. one send at a time ---
# three senders, twenty rounds each, all at once, against the counting backend: every line arrives intact and every
# literal send is followed by its own Enter in the tmux log
: > "${D}/tmux-calls.log"
sender() { for r in $(seq 1 "$2"); do post "${P_COUNT}" "s$1-r${r}" > /dev/null; done; }
# wait for the three senders only: a bare wait would also wait for the backends started in the background
sender 1 20 & S1=$!; sender 2 20 & S2=$!; sender 3 20 & S3=$!
wait "${S1}" "${S2}" "${S3}"
for s in 1 2 3; do for r in $(seq 1 20); do
	wait_screen "stub agent received: [s${s}-r${r}]" || fail "concurrent sends: s${s}-r${r} did not arrive as its own line: $(screen | grep 'received' | tail -5)"
done; done
# interleavings <log> - prints the count of literal sends not followed by their own Enter (two texts before an Enter)
interleavings() { python3 -c '
import sys
seq = [l for l in open(sys.argv[1]).read().splitlines() if l.startswith("send-keys ")]
bad = 0
for a, b in zip(seq, seq[1:] + ["Enter"]):
    if " -l -- " in a and not b.endswith(" Enter"):
        bad += 1
print(bad)' "$1"; }
[ "$(interleavings "${D}/tmux-calls.log")" == "0" ] || fail "concurrent sends interleaved: $(interleavings "${D}/tmux-calls.log") literal send(s) not followed by their own Enter"
[ "$(grep -c '^send-keys .* -l -- s[123]-r' "${D}/tmux-calls.log")" == "60" ] || fail "the tmux log does not hold 60 literal sends"
# the page sends one message at a time: its in-flight guard is in the served script
req "${CHAT_PORT}" GET / > /dev/null
grep -qF "if (!v || inFlight) return;" "${D}/body" || fail "the page's send() has no in-flight guard"
# the control: a copy without the lock, with the gap between text and Enter widened to 50 ms, two senders ten rounds
mutant no-lock '        with SEND_LOCK:
            ok, pane_id, command, reason = writable()
            if not ok:
                return self._json(409, {"sent": False, "error": reason})' '        if True:
            ok, pane_id, command, reason = writable()
            if not ok:
                return self._json(409, {"sent": False, "error": reason})'
python3 - "${D}/mutant/no-lock.py" << 'PYEOF' || fail "could not widen the control's gap"
import sys
p = sys.argv[1]; s = open(p).read()
a = 'r = tmux("send-keys", "-t", pane_id, "-l", "--", keys)\n'
assert s.count(a) == 1
open(p, "w").write(s.replace(a, a + '            time.sleep(0.05)\n'))
PYEOF
backend "${P_NOLOCK}" "${D}/mutant/no-lock.py" PATH="${D}/bin:${PATH}"
: > "${D}/tmux-calls.log"
sender_nolock() { for r in $(seq 1 10); do post "${P_NOLOCK}" "u$1-r${r}" > /dev/null; done; }
sender_nolock 1 & S1=$!; sender_nolock 2 & S2=$!
wait "${S1}" "${S2}"
[ "$(interleavings "${D}/tmux-calls.log")" -gt 0 ] || fail "PLANTED CONTROL BROKEN: the backend without the lock never interleaved two senders"
echo "ok 11 - 60 messages from three senders at once arrived as 60 lines, every literal send followed by its own Enter; the page sends one at a time; control: without the lock $(interleavings "${D}/tmux-calls.log") interleaving(s) in 20 sends from two senders"

# --- 12. watch-only is every spelling but exactly true ---
for V in False FALSE no 0 off; do
	PV="P_WR_${V}"
	backend "${!PV}" "${CHAT}" "UI_TMUX_WRITABLE=${V}"
	[ "$(post "${!PV}" "typed with UI_TMUX_WRITABLE=${V}")" == "403" ] || fail "UI_TMUX_WRITABLE=${V} still types: $(cat "${D}/body")"
	req "${!PV}" GET /state > /dev/null
	python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["writable"] is False, d' "${D}/body" || fail "UI_TMUX_WRITABLE=${V}: /state says writable: $(cat "${D}/body")"
done
sleep 1
screen | grep -qF "typed with UI_TMUX_WRITABLE=" && fail "a non-true UI_TMUX_WRITABLE typed into the pane: $(screen | grep -F 'UI_TMUX_WRITABLE=' | tail -2)"
backend "${P_WR_true}" "${CHAT}" UI_TMUX_WRITABLE=true
[ "$(post "${P_WR_true}" "typed with the exact true")" == "200" ] || fail "UI_TMUX_WRITABLE=true refuses: $(cat "${D}/body")"
wait_screen "stub agent received: [typed with the exact true]" || fail "the exact true's message never arrived"
mutant writable-not-false 'WRITABLE = os.environ.get("UI_TMUX_WRITABLE", "true") == "true"' 'WRITABLE = os.environ.get("UI_TMUX_WRITABLE", "true") != "false"'
backend "${P_WR_MUT}" "${D}/mutant/writable-not-false.py" UI_TMUX_WRITABLE=False
[ "$(post "${P_WR_MUT}" "mutant typed with False")" == "200" ] || fail "PLANTED CONTROL BROKEN: the backend that refuses only the exact false still refused False"
wait_screen "stub agent received: [mutant typed with False]" || fail "PLANTED CONTROL BROKEN: the not-false backend typed nothing"
echo "ok 12 - False, FALSE, no, 0 and off are watch-only (403, /state off, nothing typed), true types; control: a copy refusing only the exact 'false' typed with False"

# --- 13. a trailing semicolon arrives ---
for T in 'hello;' 'a\;' 'end ;' 'x;;' 'mid ; dle' ';'; do
	[ "$(post "${CHAT_PORT}" "${T}")" == "200" ] || fail "the send of '${T}' answered $(cat "${D}/body")"
	wait_screen "stub agent received: [${T}]" || fail "'${T}' did not arrive exactly: $(screen | grep 'received' | tail -3)"
done
mutant no-semicolon-escape 'keys = text[:-1] + "\\;" if text.endswith(";") else text' 'keys = text'
backend "${P_NOSEMI}" "${D}/mutant/no-semicolon-escape.py"
[ "$(post "${P_NOSEMI}" "semi;")" == "200" ] || fail "the control's send failed: $(cat "${D}/body")"
wait_screen "stub agent received: [semi]" || fail "PLANTED CONTROL BROKEN: the backend without the escape did not lose the trailing semicolon: $(screen | grep 'received' | tail -3)"
screen | grep -qF "stub agent received: [semi;]" && fail "PLANTED CONTROL BROKEN: the backend without the escape delivered the semicolon"
echo "ok 13 - hello; a\; 'end ;' x;; 'mid ; dle' and ; arrive exactly; control: without the escape semi; arrives as semi"

# --- 14. the standard library's own answers carry the headers ---
for M in OPTIONS HEAD; do
	CODE=$(req "${CHAT_PORT}" "${M}" /send -H "Origin: http://evil.localhost:${CHAT_PORT}")
	[ "${CODE}" == "501" ] || fail "${M} /send is ${CODE}, not 501"
	[ "$(hdr cache-control)" == "no-store" ] || fail "the 501 to ${M} lacks Cache-Control: no-store"
	[ "$(hdr x-content-type-options)" == "nosniff" ] || fail "the 501 to ${M} lacks nosniff"
	grep -qi '^content-security-policy:.*frame-ancestors .none.' "${D}/hdr" || fail "the 501 to ${M} does not forbid framing"
	grep -qi '^access-control-' "${D}/hdr" && fail "the 501 to ${M} carries a CORS header"
done
# the standard library's other answers, through a raw socket: an unknown method on the request line (501) and a
# request with too many header lines (431). A request line without an HTTP version gets the library's HTTP/0.9 answer -
# by protocol no status line and no headers, only its error page as the body - so it is not a case here
raw() { python3 - "${CHAT_PORT}" "$1" << 'PYEOF'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(sys.argv[2].encode().replace(b"\\n", b"\r\n"))
data = b""
try:
    while True:
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
except socket.timeout:
    pass
sys.stdout.write(data.decode(errors="replace"))
PYEOF
}
raw "GARBAGE /send HTTP/1.1\nHost: chat.localhost:${CHAT_PORT}\n\n" > "${D}/raw-501.txt"
head -1 "${D}/raw-501.txt" | grep -q " 501 " || fail "an unknown method on the request line is not answered 501: $(head -1 "${D}/raw-501.txt")"
MANY=$(for i in $(seq 1 120); do printf 'X-%s: y\\n' "${i}"; done)
raw "GET /healthz HTTP/1.1\nHost: chat.localhost:${CHAT_PORT}\n${MANY}\n" > "${D}/raw-431.txt"
head -1 "${D}/raw-431.txt" | grep -q " 431 " || fail "a request with too many header lines is not answered 431: $(head -1 "${D}/raw-431.txt")"
for F in raw-501 raw-431; do
	grep -qi '^cache-control: no-store' "${D}/${F}.txt" || fail "the ${F#raw-} answer lacks Cache-Control: no-store"
	grep -qi '^x-content-type-options: nosniff' "${D}/${F}.txt" || fail "the ${F#raw-} answer lacks nosniff"
	grep -qi '^content-security-policy:.*frame-ancestors .none.' "${D}/${F}.txt" || fail "the ${F#raw-} answer does not forbid framing"
	grep -qi '^access-control-' "${D}/${F}.txt" && fail "the ${F#raw-} answer carries a CORS header"
done
mutant no-end-headers '        for name, value in SECURITY_HEADERS:
            self.send_header(name, value)
        super().end_headers()' '        super().end_headers()'
python3 - "${D}/mutant/no-end-headers.py" << 'PYEOF' || fail "could not plant the control no-end-headers"
import sys
p = sys.argv[1]; s = open(p).read()
# the control keeps the headers on the page's own answers (in _send), so only the standard library's lose them
a = '        self.send_header("Content-Length", str(len(raw)))\n        self.end_headers()'
assert s.count(a) == 1
open(p, "w").write(s.replace(a, '        self.send_header("Content-Length", str(len(raw)))\n        for name, value in SECURITY_HEADERS:\n            self.send_header(name, value)\n        self.end_headers()'))
PYEOF
backend "${P_NOHDR}" "${D}/mutant/no-end-headers.py"
[ "$(req "${P_NOHDR}" OPTIONS /send)" == "501" ] || fail "the control did not answer 501"
[ "$(hdr cache-control)" != "no-store" ] || fail "PLANTED CONTROL BROKEN: the backend without the end_headers override still sends no-store on its 501"
[ "$(req "${P_NOHDR}" GET /healthz)" == "200" ] && [ "$(hdr cache-control)" == "no-store" ] || fail "the control lost the headers on its own answers too (it must differ in the standard library's answers only)"
echo "ok 14 - 501 (OPTIONS, HEAD, an unknown method on the request line) and 431 (too many header lines) carry no-store, nosniff, the policy and no CORS header; control: without the end_headers override the 501 carries none"

# --- 15. timeouts ---
# a body that never arrives: the connection closes at the read timeout (2 s here)
backend "${P_RT}" "${CHAT}" AGENT_CHAT_READ_TIMEOUT=2
# slow_body <port> - sends a POST whose body is short of its Content-Length and prints the seconds until the server
# closes the connection (or 'open' after 6 s)
slow_body() { python3 - "$1" << 'PYEOF'
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=6)
s.sendall(b"POST /send HTTP/1.1\r\nHost: chat.localhost:" + sys.argv[1].encode() + b"\r\nOrigin: http://chat.localhost:" + sys.argv[1].encode() + b"\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{\"text\": \"")
t0 = time.time()
try:
    while True:
        if not s.recv(65536): break
    print(round(time.time() - t0, 1))
except socket.timeout:
    print("open")
PYEOF
}
RT=$(slow_body "${P_RT}")
{ [ "${RT}" != "open" ] && python3 -c 'import sys; sys.exit(0 if 1.5 <= float(sys.argv[1]) <= 5 else 1)' "${RT}"; } || fail "a body that never arrives did not close the connection at the read timeout (${RT})"
[ "$(req "${P_RT}" GET /healthz)" == "200" ] || fail "the backend does not answer after the dropped request"
mutant no-read-timeout '    timeout = READ_TIMEOUT' '    timeout = None'
backend "${P_NORT}" "${D}/mutant/no-read-timeout.py" AGENT_CHAT_READ_TIMEOUT=2
[ "$(slow_body "${P_NORT}")" == "open" ] || fail "PLANTED CONTROL BROKEN: the backend without the read timeout closed the connection"
# a tmux that does not answer: a tmux on the PATH that sleeps 3 s on capture-pane and send-keys, a 1 s tmux timeout
mkdir -p "${D}/slowbin"
cat > "${D}/slowbin/tmux" << TMUXEOF
#!/bin/bash
case "\$1" in capture-pane|send-keys) sleep 3 ;; esac
exec $(command -v tmux) "\$@"
TMUXEOF
chmod +x "${D}/slowbin/tmux"
backend "${P_TT}" "${CHAT}" PATH="${D}/slowbin:${PATH}" AGENT_CHAT_TMUX_TIMEOUT=1
[ "$(req "${P_TT}" GET /pane)" == "503" ] || fail "/pane with a tmux that does not answer is not 503: $(cat "${D}/body")"
grep -q "tmux did not answer" "${D}/body" || fail "/pane's error does not say tmux did not answer: $(cat "${D}/body")"
# the pane is read before anything is typed, so the first tmux call that does not answer is the capture: 503, as on /pane
[ "$(post "${P_TT}" "typed into a tmux that does not answer")" == "503" ] || fail "a send with a tmux that does not answer is not 503: $(cat "${D}/body")"
grep -q "tmux did not answer" "${D}/body" || fail "the send's error does not say tmux did not answer: $(cat "${D}/body")"
[ "$(req "${P_TT}" GET /healthz)" == "200" ] || fail "the backend does not answer after the tmux timeouts"
mutant raising-tmux '    try:
        return subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=TMUX_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(["tmux", *args], -1, "", f"tmux did not answer ({e.__class__.__name__})")' '    return subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=TMUX_TIMEOUT, stdin=subprocess.DEVNULL)'
backend "${P_NOTT}" "${D}/mutant/raising-tmux.py" PATH="${D}/slowbin:${PATH}" AGENT_CHAT_TMUX_TIMEOUT=1
[ "$(req "${P_NOTT}" GET /pane)" == "000" ] || fail "PLANTED CONTROL BROKEN: the backend whose tmux call may raise still answered /pane ($(cat "${D}/body" | head -c 80))"
echo "ok 15 - a body that never arrives closes at the read timeout (${RT} s; control: without it the connection stays open); a tmux that does not answer is 503 on /pane and on a send (read before typing), both naming it (control: a raising tmux call answers nothing)"

# --- 16. the chat route requires the harness design system ---
mkdir -p "${D}/no-design"
python3 - "${AGENT_DIR}/home-render.sh" "${D}/no-design/home-render.sh" << 'PYEOF' || fail "could not derive the home-render.sh without the design system"
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# the function's definition, from its name to the closing brace at column 0 (absent on a tree that never had it)
s2, n = re.subn(r"\nharness_css_location\(\)\n\{.*?\n\}\n", "\n", s, count=1, flags=re.S)
assert "harness_css_location()" not in s2, "the definition is still there"
open(dst, "w").write(s2)
print("definition removed" if n else "no definition in this tree (the copy is the original)")
PYEOF
UI_DIR=${D}/no-design/ui bash "${D}/no-design/home-render.sh" > "${D}/no-design/out.txt" 2> "${D}/no-design/err.txt"
RC=$?
[ "${RC}" == "1" ] || fail "home-render.sh without harness_css_location exits ${RC}, not 1 (a silent unstyled page with a 404ing stylesheet)"
grep -q "the Agent chat route requires the harness design system" "${D}/no-design/err.txt" || fail "the failure does not name the design system: $(cat "${D}/no-design/err.txt")"
echo "ok 16 - home-render.sh without harness_css_location fails loudly, naming the harness design system (rc 1); with it (check 2) the chat block carries the stylesheet location"

# --- 17.-19. a menu on the pane: nothing is typed into it; it is answered with one key ---
# a stand-in for the agent CLI showing a menu, drawn as Claude Code 2.1.296 draws its approval dialog (a rule, the
# dialog, "Do you want to proceed?", numbered choices with the cursor on the first, a hint line; the prompt hidden) and
# reading keys the way it does: a digit chooses that option and, in mode "select" (the CLI's way), answers at once; in
# mode "cursor" it only moves the cursor and Enter answers; mode "two" is "select" with a second menu right behind the
# first; mode "list" draws a checkbox list instead. Every key read is logged, so a check reads exactly what was typed.
# After the answer the prompt is drawn (a "❯" line between two rules) and every line typed at it is printed back.
cat > "${D}/stub-menu.sh" << 'EOF'
#!/bin/bash
LOG=$1 MODE=$2
OPTS=("" "Yes" "Yes, and don't ask again for: rm *" "No")
SEL=1 MENU=1
draw()
{
	clear
	echo "❯ remove the old scratch directory"
	echo
	echo "● Removing it now."
	echo
	echo "────────────────────────────────────────────────────────────────────"
	if [ "${MODE}" == "list" ]; then
		echo " 2 new MCP servers found in this project"
		echo " Select any you wish to enable."
		echo " ❯ [✔] memory"
		echo "   [ ] tracker"
		echo "      Enable selected"
		echo " Space to select · Esc to reject all"
		return
	fi
	if [ "${MENU}" == "1" ]; then
		echo " Bash command"
		echo " Remove the old scratch directory"
		echo "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
		echo " rm -rf scratch/old"
		echo "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
		echo " This command requires approval"
	else
		echo " Write file"
		echo " scratch/notes.txt"
	fi
	echo
	echo " Do you want to proceed?"
	for i in 1 2 3; do
		if [ "${i}" == "${SEL}" ]; then echo " ❯ ${i}. ${OPTS[$i]}"; else echo "   ${i}. ${OPTS[$i]}"; fi
	done
	echo
	echo " Esc to cancel · Tab to amend"
}
prompt()
{
	clear
	echo "$1"
	echo
	echo "────────────────────────────────────────────────────────────────────"
	echo "❯ "
	echo "────────────────────────────────────────────────────────────────────"
	echo "  stub · ready"
	while IFS= read -r line; do printf 'stub agent received: [%s]\n' "$line"; done
	exit 0
}
answer()
{
	if [ "${MODE}" == "two" ] && [ "${MENU}" == "1" ]; then
		echo "first menu answered: $1. ${OPTS[$1]}" >> "${LOG}"
		MENU=2 SEL=1
		draw
		return
	fi
	prompt "menu ${MENU} answered: $1. ${OPTS[$1]}"
}
draw
while IFS= read -rsn1 key; do
	case "${key}" in
		"") printf 'ENTER\n' >> "${LOG}"; [ "${MODE}" == "list" ] && prompt "list answered with Enter"; answer "${SEL}" ;;
		$'\e') printf 'ESC\n' >> "${LOG}"; prompt "menu cancelled" ;;
		[123]) printf '%s\n' "${key}" >> "${LOG}"; [ "${MODE}" == "list" ] && continue; SEL=${key}; if [ "${MODE}" == "cursor" ]; then draw; else answer "${SEL}"; fi ;;
		*) printf '%q\n' "${key}" >> "${LOG}" ;;
	esac
done
EOF
# menu_window <mode> - the menu stub in a new window of the stub session, active; its key log emptied
menu_window()
{
	: > "${D}/menu-keys.log"
	tmux new-window -t "=${SESSION}:" "exec -a claude bash ${D}/stub-menu.sh ${D}/menu-keys.log $1"
	for _ in $(seq 1 30); do screen | grep -qE 'Do you want to proceed|Select any you wish' && break; sleep 0.2; done
	screen | grep -qE 'Do you want to proceed|Select any you wish' || fail "the menu stub ($1) did not draw its menu: $(screen | tail -5)"
	[ "$(tmux display-message -t "=${SESSION}:" -p '#{pane_current_command}')" == "claude" ] || fail "the menu stub's pane does not report claude"
}
# menu_close - back to the plain stub's window
menu_close()
{
	tmux kill-window -t "=${SESSION}:1" 2> /dev/null
	for _ in $(seq 1 25); do [ "$(tmux display-message -t "=${SESSION}:" -p '#{window_index}')" == "0" ] && break; sleep 0.2; done
}
# answer_post <port> <option> <key> - POST /answer from the page's own origin (a non-numeric option goes as a string)
answer_post()
{
	req "$1" POST /answer -H "Content-Type: application/json" -H "Origin: http://chat.localhost:$1" --data-binary "$(python3 -c 'import json, sys; print(json.dumps({"option": int(sys.argv[1]) if sys.argv[1].isdigit() else sys.argv[1], "key": sys.argv[2]}))' "$2" "$3")"
}
# state_field <a.b.0> - a field of the JSON in ${D}/body (strings bare, the rest as JSON)
state_field() { python3 -c 'import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k] if isinstance(v, dict) else v[int(k)]
print(v if isinstance(v, str) else json.dumps(v))' "${D}/body" "$1"; }

# 17. the approval menu: nothing typed, the menu named; the page before this check types into it
menu_window select
[ "$(req "${CHAT_PORT}" GET /state)" == "200" ] || fail "/state is not 200 with the menu up"
[ "$(state_field writable)" == "true" ] || fail "/state with the menu up does not say the pane runs the agent: $(cat "${D}/body")"
[ "$(state_field screen)" == "menu" ] || fail "/state does not read the menu: $(cat "${D}/body")"
[ "$(state_field menu.kind)" == "numbered" ] || fail "/state does not read a numbered menu: $(cat "${D}/body")"
[ "$(state_field menu.question)" == "Do you want to proceed?" ] || fail "/state does not carry the menu's question: $(cat "${D}/body")"
[ "$(state_field menu.selected)" == "1" ] || fail "/state does not carry the highlighted choice: $(cat "${D}/body")"
[ "$(state_field menu.options.1.text)" == "Yes, and don't ask again for: rm *" ] || fail "/state does not carry the options' text: $(cat "${D}/body")"
[ "$(state_field menu.context.0)" == "Bash command" ] || fail "/state does not carry the dialog above the options: $(cat "${D}/body")"
state_field hold | grep -q "asking 'Do you want to proceed?' with 3 numbered options" || fail "/state's hold does not name the menu: $(cat "${D}/body")"
CODE=$(post "${CHAT_PORT}" "hello there")
[ "${CODE}" == "409" ] || fail "a send with the menu up answered ${CODE}, not 409: $(cat "${D}/body")"
grep -q "asking 'Do you want to proceed?'" "${D}/body" || fail "the refusal does not name the menu's question: $(cat "${D}/body")"
grep -q '"menu": {' "${D}/body" || fail "the refusal does not carry the menu: $(cat "${D}/body")"
sleep 0.5
[ ! -s "${D}/menu-keys.log" ] || fail "a refused send still typed into the menu: $(tr '\n' ' ' < "${D}/menu-keys.log")"
screen | grep -q "Do you want to proceed?" || fail "the menu is gone after a refused send: $(screen | tail -4)"
[ "$(req "${CHAT_PORT}" GET /)" == "200" ] || fail "the page is not 200 with the menu up"
grep -q 'id="menu" hidden' "${D}/body" && grep -q 'id="menu-options"' "${D}/body" && grep -q "/answer" "${D}/body" || fail "the page carries no menu panel that answers through /answer"
# the control: the page before this check - a copy that reads every pane as the prompt (no menu reading at all, so
# neither the gate before the text nor the look before the Enter sees the menu)
mutant no-menu-gate '    cursors = [i for i, l in enumerate(lines) if CURSOR.match(l)]' '    return "prompt", None
    cursors = [i for i, l in enumerate(lines) if CURSOR.match(l)]'
backend "${P_NOMENU}" "${D}/mutant/no-menu-gate.py"
CODE=$(post "${P_NOMENU}" "hello")
[ "${CODE}" == "200" ] || fail "PLANTED CONTROL BROKEN: the backend without the gate still refused the menu (${CODE}): $(cat "${D}/body")"
wait_screen "menu 1 answered: 1. Yes" || fail "PLANTED CONTROL BROKEN: the backend without the gate did not answer the menu with the highlighted choice: $(screen | tail -4)"
[ "$(tr '\n' ' ' < "${D}/menu-keys.log")" == "h e l l o ENTER " ] || fail "PLANTED CONTROL BROKEN: the keys the menu read are not the message and its Enter: $(tr '\n' ' ' < "${D}/menu-keys.log")"
menu_close
echo "ok 17 - an approval menu on the pane: /state names it (question, 3 options, the highlighted one, the dialog above), a send is 409 naming the question, no key reaches the menu, the menu stays, the page carries the menu panel; control: the page before this check types the message into the menu and its Enter answers 'Yes'"

# 18. one key answers; a stale key, a wrong option, a foreign origin, a list
menu_window select
[ "$(req "${CHAT_PORT}" GET /state)" == "200" ] || fail "/state is not 200"
MENU_KEY=$(state_field menu.key)
CODE=$(answer_post "${CHAT_PORT}" 2 "${MENU_KEY}")
[ "${CODE}" == "200" ] || fail "answering the menu with option 2 answered ${CODE}: $(cat "${D}/body")"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["answered"] is True and d["option"] == 2 and d["how"] == "the key 2" and d["menu_gone"] is True and d["text"].startswith("Yes, and"), d' "${D}/body" \
	|| fail "the answer's acknowledgement is not the one key: $(cat "${D}/body")"
wait_screen "menu 1 answered: 2. Yes, and don't ask again for: rm *" || fail "the menu was not answered with option 2: $(screen | tail -4)"
[ "$(tr '\n' ' ' < "${D}/menu-keys.log")" == "2 " ] || fail "the menu read other keys than the one '2': $(tr '\n' ' ' < "${D}/menu-keys.log")"
[ "$(req "${CHAT_PORT}" GET /state)" == "200" ] || fail "/state is not 200 after the answer"
[ "$(state_field screen)" == "prompt" ] && [ "$(state_field hold)" == "" ] || fail "/state does not read the prompt after the answer: $(cat "${D}/body")"
[ "$(post "${CHAT_PORT}" "after the menu")" == "200" ] || fail "a send at the prompt after the menu was refused: $(cat "${D}/body")"
wait_screen "stub agent received: [after the menu]" || fail "the message after the menu never arrived: $(screen | tail -4)"
menu_close
# a stale key, an option the menu does not have, a malformed option, a foreign origin
menu_window select
CODE=$(answer_post "${CHAT_PORT}" 2 "${MENU_KEY}0")
[ "${CODE}" == "409" ] || fail "an answer with a stale key answered ${CODE}, not 409: $(cat "${D}/body")"
grep -q "the menu changed since the page showed it" "${D}/body" || fail "the stale-key refusal does not say so: $(cat "${D}/body")"
CODE=$(answer_post "${CHAT_PORT}" 9 "${MENU_KEY}")
[ "${CODE}" == "400" ] || fail "an answer with option 9 answered ${CODE}, not 400: $(cat "${D}/body")"
CODE=$(answer_post "${CHAT_PORT}" two "${MENU_KEY}")
[ "${CODE}" == "400" ] || fail "an answer with a non-numeric option answered ${CODE}, not 400: $(cat "${D}/body")"
CODE=$(req "${CHAT_PORT}" POST /answer -H "Content-Type: application/json" -H "Origin: http://evil.localhost:${CHAT_PORT}" --data-binary "{\"option\": 1, \"key\": \"${MENU_KEY}\"}")
[ "${CODE}" == "403" ] || fail "a foreign-origin answer answered ${CODE}, not 403"
sleep 0.3
[ ! -s "${D}/menu-keys.log" ] || fail "a refused answer still pressed a key: $(tr '\n' ' ' < "${D}/menu-keys.log")"
screen | grep -q "Do you want to proceed?" || fail "the menu is gone after refused answers"
# the control: without the key check a menu the page never showed is answered
mutant no-key-check '            if menu["key"] != key:' '            if False and menu["key"] != key:'
backend "${P_NOKEY}" "${D}/mutant/no-key-check.py"
CODE=$(answer_post "${P_NOKEY}" 3 "${MENU_KEY}0")
[ "${CODE}" == "200" ] || fail "PLANTED CONTROL BROKEN: the backend without the key check refused the stale key (${CODE}): $(cat "${D}/body")"
wait_screen "menu 1 answered: 3. No" || fail "PLANTED CONTROL BROKEN: the backend without the key check did not answer: $(screen | tail -4)"
menu_close
# a checkbox list: named, no numbered answer, no message
menu_window list
[ "$(req "${CHAT_PORT}" GET /state)" == "200" ] || fail "/state is not 200 with the list up"
[ "$(state_field screen)" == "menu" ] && [ "$(state_field menu.kind)" == "list" ] || fail "/state does not read the checkbox list as a list: $(cat "${D}/body")"
[ "$(state_field menu.options.0.text)" == "memory" ] && [ "$(state_field menu.options.1.checked)" == "false" ] || fail "/state does not carry the list's items: $(cat "${D}/body")"
state_field hold | grep -q "shows a selection list" || fail "/state's hold does not name the list: $(cat "${D}/body")"
[ "$(post "${CHAT_PORT}" "into the list")" == "409" ] || fail "a send with the list up was not 409: $(cat "${D}/body")"
grep -q "selection list" "${D}/body" || fail "the refusal does not name the list: $(cat "${D}/body")"
LIST_KEY=$(state_field menu.key)
[ "$(answer_post "${CHAT_PORT}" 1 "${LIST_KEY}")" == "409" ] || fail "answering a list by number was not 409: $(cat "${D}/body")"
grep -q "no numbered menu to answer" "${D}/body" || fail "the list refusal does not say there is no numbered menu: $(cat "${D}/body")"
sleep 0.3
[ ! -s "${D}/menu-keys.log" ] || fail "the list read a key from a refused request: $(tr '\n' ' ' < "${D}/menu-keys.log")"
menu_close
echo "ok 18 - option 2 answers the menu with exactly the key '2' (no Enter: the menu took the number), then the prompt takes a message again; a stale key is 409, option 9 and a non-numeric option are 400, a foreign origin is 403, none presses a key; a checkbox list is named as a list, refuses a message and a numbered answer; control: without the key check a menu the page never showed is answered"

# 19. the Enter follows the key only when the menu waits for it
menu_window cursor
[ "$(req "${CHAT_PORT}" GET /state)" == "200" ] || fail "/state is not 200"
MENU_KEY=$(state_field menu.key)
CODE=$(answer_post "${CHAT_PORT}" 2 "${MENU_KEY}")
[ "${CODE}" == "200" ] || fail "answering the cursor menu answered ${CODE}: $(cat "${D}/body")"
grep -q '"how": "the key 2, then Enter"' "${D}/body" || fail "the acknowledgement does not say Enter followed the key: $(cat "${D}/body")"
wait_screen "menu 1 answered: 2. Yes, and don't ask again for: rm *" || fail "the cursor menu was not answered with option 2: $(screen | tail -4)"
[ "$(tr '\n' ' ' < "${D}/menu-keys.log")" == "2 ENTER " ] || fail "the cursor menu did not read the key and then Enter: $(tr '\n' ' ' < "${D}/menu-keys.log")"
menu_close
menu_window two
[ "$(req "${CHAT_PORT}" GET /state)" == "200" ] || fail "/state is not 200"
MENU_KEY=$(state_field menu.key)
CODE=$(answer_post "${CHAT_PORT}" 2 "${MENU_KEY}")
[ "${CODE}" == "200" ] || fail "answering the first of two menus answered ${CODE}: $(cat "${D}/body")"
grep -q '"how": "the key 2"' "${D}/body" || fail "the acknowledgement says more than the key was pressed: $(cat "${D}/body")"
sleep 0.5
grep -q "first menu answered: 2. Yes, and don't ask again for: rm \*" "${D}/menu-keys.log" || fail "the first menu was not answered with option 2: $(cat "${D}/menu-keys.log")"
grep -q "^ENTER$" "${D}/menu-keys.log" && fail "an Enter followed the key although the first menu took the number: $(tr '\n' ' ' < "${D}/menu-keys.log")"
screen | grep -q "Write file" || fail "the second menu is not up: $(screen | tail -6)"
[ "$(req "${CHAT_PORT}" GET /state)" == "200" ] || fail "/state is not 200 with the second menu"
[ "$(state_field screen)" == "menu" ] && [ "$(state_field menu.context.0)" == "Write file" ] || fail "/state does not show the second menu: $(cat "${D}/body")"
[ "$(state_field menu.key)" != "${MENU_KEY}" ] || fail "the second menu has the first one's key"
menu_close
# the control: a copy that follows the key with Enter whatever the menu did
mutant blind-enter '            if outcome == "selected":' '            if outcome in ("selected", "gone"):'
backend "${P_BLINDENTER}" "${D}/mutant/blind-enter.py"
menu_window two
[ "$(req "${P_BLINDENTER}" GET /state)" == "200" ] || fail "/state is not 200"
MENU_KEY=$(state_field menu.key)
[ "$(answer_post "${P_BLINDENTER}" 2 "${MENU_KEY}")" == "200" ] || fail "PLANTED CONTROL BROKEN: the blind-Enter backend refused the answer: $(cat "${D}/body")"
wait_screen "menu 2 answered: 1. Yes" || fail "PLANTED CONTROL BROKEN: the blind Enter did not answer the second menu with its highlighted choice: $(screen | tail -4)"
[ "$(grep -c '^ENTER$' "${D}/menu-keys.log")" == "1" ] || fail "PLANTED CONTROL BROKEN: the blind-Enter backend pressed no Enter: $(tr '\n' ' ' < "${D}/menu-keys.log")"
menu_close
echo "ok 19 - a menu that moves its cursor on the key gets the key and then Enter; a menu that answers on the key gets no Enter, so the second menu behind it stays unanswered and /state shows it; control: a copy that always follows the key with Enter answers the second menu with 'Yes'"

# 20. the reading of the pane, on the agent CLI's own screens (captured from Claude Code 2.1.296)
mkdir -p "${D}/screens"
cat > "${D}/screens/approval.txt" << 'EOF'
❯ run exactly this shell command and nothing else, then stop: openssl rand -hex 4

● Running openssl rand -hex 4 now.

● Bash(openssl rand -hex 4)
  ⎿  Waiting…

─────────────────────────────────────────�
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
 Generate 4 random bytes as hex
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌�
 openssl rand -hex 4
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌�
 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don’t ask again for: openssl rand *
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
EOF
cat > "${D}/screens/question.txt" << 'EOF'
● The command finished. Output:

  d304fb79

  Now asking the one question you requested.
─────────────────────────────────────────�
 ☐ Next step

What should I do with the generated value d304fb79?

❯ 1. Nothing, discard it
     Leave it as a one-off output; no files or state touched.
  2. Save it to scratch
     Write it to a file under ./scratch/ in the current working directory for later reuse.
  3. Use it as a run tag
     Adopt it as the identifier for the next lane, log, or evidence directory you ask me to create.
  4. Type something.
─────────────────────────────────────────�
  5. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
EOF
cat > "${D}/screens/checkboxes.txt" << 'EOF'
───────────────────────────────────────────�
  4 new MCP servers found in this project
  Select any you wish to enable.
  MCP servers may execute code or access system resources. All tool calls require approval. Learn more in the MCP
  documentation.
  ❯ [✔] agentmemory
    [✔] hindsight
    [✔] plane
    [✔] tmux-monitor
       Enable selected
 Space to select · Esc to reject all
EOF
cat > "${D}/screens/prompt.txt" << 'EOF'
❯ list three fruits

● Three fruits:
  1. apple
  2. pear
  3. plum

✻ Crunched for 3s · done 5:50 PM

────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────
  do-agent-aws · Opus 5.5 · ctx:4%
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
EOF
cat > "${D}/screens/prompt-wrapped.txt" << 'EOF'
● CHAT-OK

────────────────────────────────────────────────────────────────────────────────
❯ a long message that a person is still typing in the terminal and that wraps onto a second and a
third line of the input box before it is sent
────────────────────────────────────────────────────────────────────────────────
  do-agent-aws · Opus 5.5 · ctx:4%
EOF
cat > "${D}/screens/no-cursor.txt" << 'EOF'
❯ /login

● Opening the browser for sign-in.

────────────────────────────────────────────────────────────────────────────────
 Paste the code here if prompted:

 Press Enter to continue…
EOF
python3 - "${CHAT}" "${D}/screens" << 'PYEOF' || fail "the pane reading failed on the agent CLI's own screens"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("chat", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
S = sys.argv[2] + "/"
def read(name): return m.screen_state(open(S + name).read())
screen, menu = read("approval.txt")
assert screen == "menu" and menu["kind"] == "numbered" and menu["question"] == "Do you want to proceed?" and menu["selected"] == 1, (screen, menu)
assert [o["text"] for o in menu["options"]] == ["Yes", "Yes, and don’t ask again for: openssl rand *", "Yes, and switch to auto mode · auto mode handles these prompts for you", "No"], menu["options"]
assert menu["context"][0] == "Bash command" and "openssl rand -hex 4" in menu["context"], menu["context"]
assert m.hold_reason("claude", screen, menu).startswith("the agent is asking 'Do you want to proceed?' with 4 numbered options")
screen, menu = read("question.txt")
assert screen == "menu" and menu["kind"] == "numbered" and menu["question"] == "What should I do with the generated value d304fb79?", (screen, menu)
assert [o["n"] for o in menu["options"]] == [1, 2, 3, 4, 5] and menu["options"][4]["text"] == "Chat about this", menu["options"]
screen, menu = read("checkboxes.txt")
assert screen == "menu" and menu["kind"] == "list" and len(menu["options"]) == 4 and menu["options"][0]["text"] == "agentmemory" and menu["options"][0]["checked"], (screen, menu)
assert menu["question"] == "4 new MCP servers found in this project", menu["question"]
assert "selection list" in m.hold_reason("claude", screen, menu)
for name in ("prompt.txt", "prompt-wrapped.txt"):
    screen, menu = read(name)
    assert screen == "prompt" and menu is None and m.hold_reason("claude", screen, menu) == "", (name, screen, menu)
screen, menu = read("no-cursor.txt")
assert screen == "other" and menu is None, (screen, menu)
assert "prompt is not shown" in m.hold_reason("claude", screen, menu)
# another configured CLI: held for a menu, not for a prompt shape this page does not know
assert m.hold_reason("codex", "other", None) == ""
assert "numbered options" in m.hold_reason("codex", *read("approval.txt"))
print("screens read")
PYEOF
# the same rule live: a pane that runs claude without its prompt drawn (starting, or a dialog without a cursor) is
# refused naming the prompt; the same screen under another configured CLI name is typed into
cat > "${D}/stub-bare.sh" << 'EOF'
#!/bin/bash
echo "stub agent starting"
while IFS= read -r line; do printf 'bare stub received: [%s]\n' "$line"; done
EOF
tmux new-window -t "=${SESSION}:" "exec -a claude bash ${D}/stub-bare.sh"
wait_screen "stub agent starting" || fail "the bare stub did not start"
for _ in $(seq 1 25); do [ "$(tmux display-message -t "=${SESSION}:" -p '#{pane_current_command}')" == "claude" ] && break; sleep 0.2; done
CODE=$(post "${CHAT_PORT}" "typed at no prompt")
[ "${CODE}" == "409" ] || fail "a send to a claude pane without a prompt answered ${CODE}, not 409: $(cat "${D}/body")"
grep -q "the agent's prompt is not shown" "${D}/body" || fail "the refusal does not name the missing prompt: $(cat "${D}/body")"
[ "$(req "${CHAT_PORT}" GET /state)" == "200" ] && [ "$(state_field screen)" == "other" ] || fail "/state does not read the bare pane as other: $(cat "${D}/body")"
sleep 0.3
screen | grep -q "bare stub received" && fail "the refused message was typed into the pane without a prompt"
tmux kill-window -t "=${SESSION}:1"
for _ in $(seq 1 25); do [ "$(tmux display-message -t "=${SESSION}:" -p '#{window_index}')" == "0" ] && break; sleep 0.2; done
tmux new-window -t "=${SESSION}:" "exec -a codex bash ${D}/stub-bare.sh"
for _ in $(seq 1 25); do [ "$(tmux display-message -t "=${SESSION}:" -p '#{pane_current_command}')" == "codex" ] && break; sleep 0.2; done
backend "${P_OTHERCLI}" "${CHAT}" AGENT_CHAT_COMMANDS=codex
[ "$(post "${P_OTHERCLI}" "typed at another cli")" == "200" ] || fail "a send to another configured CLI without a known prompt shape was refused: $(cat "${D}/body")"
wait_screen "bare stub received: [typed at another cli]" || fail "the message to the other CLI never arrived: $(screen | tail -3)"
tmux kill-window -t "=${SESSION}:1"
for _ in $(seq 1 25); do [ "$(tmux display-message -t "=${SESSION}:" -p '#{window_index}')" == "0" ] && break; sleep 0.2; done
echo "ok 20 - the agent CLI's own screens read right: the approval dialog (4 choices, the command above them), the question with descriptions and a rule (5 choices), the checkbox list (a list), the prompt under an echoed input and a numbered list in an answer (no menu), the prompt with wrapped text, a dialog without a cursor (other: refused for claude, naming the missing prompt); live: a claude pane without a prompt is 409 naming it and nothing is typed, the same pane under another configured CLI name is typed into"

# --- 21. the harness's own agent pane: the wrapper gives the agent CLI the pane ---
# a stand-in agent CLI named claude, drawing the prompt shape. tmux names a pane's command from its foreground
# process's argv[0]: the real claude is a binary, so its argv[0] is its path; a script's is its interpreter, so the
# stub re-executes itself once with argv[0] "claude" (exec -a), as the other stubs of this test are started
mkdir -p "${D}/wrapper/bin"
cat > "${D}/wrapper/bin/claude" << 'EOF'
#!/bin/bash
[ -z "${STUB_CLAUDE_REEXEC:-}" ] && STUB_CLAUDE_REEXEC=1 exec -a claude bash "$0" "$@"
echo "stub claude at its prompt"
prompt() { echo "────────────────────────────────────────────────────────────────────"; echo "❯ "; echo "────────────────────────────────────────────────────────────────────"; }
prompt
while IFS= read -r line; do printf 'stub claude received: [%s]\n' "$line"; prompt; done
EOF
chmod +x "${D}/wrapper/bin/claude"
W_SESSION=${SESSION}-wrapper
# wrapper_session <wrapper script> - the session's pane runs the wrapper, which starts the stub claude (no memory wait)
wrapper_session()
{
	tmux kill-session -t "=${W_SESSION}" 2> /dev/null
	tmux new-session -d -s "${W_SESSION}" -x 120 -y 30 "env AGENT_TMUX_CLAUDE=true UI_START=false CLAUDE_BIN=${D}/wrapper/bin/claude AGENT_TMUX_CLAUDE_OPTS= bash $1" || fail "could not start the wrapper session"
	for _ in $(seq 1 50); do tmux capture-pane -p -t "=${W_SESSION}:" | grep -q "stub claude at its prompt" && break; sleep 0.2; done
	tmux capture-pane -p -t "=${W_SESSION}:" | grep -q "stub claude at its prompt" || fail "the wrapper $1 did not start the stub claude: $(tmux capture-pane -p -t "=${W_SESSION}:" | tail -4)"
	sleep 0.3
}
wrapper_session "${AGENT_DIR}/tmux-claude.sh"
CMD=$(tmux display-message -t "=${W_SESSION}:" -p '#{pane_current_command}')
[ "${CMD}" == "claude" ] || fail "the wrapper does not give claude the pane: tmux reports '${CMD}' as the pane's command"
backend "${P_WRAPPER}" "${CHAT}" AGENT_TMUX_SESSION_NAME="${W_SESSION}"
[ "$(req "${P_WRAPPER}" GET /state)" == "200" ] && [ "$(state_field command)" == "claude" ] && [ "$(state_field writable)" == "true" ] || fail "/state on the wrapper's pane: $(cat "${D}/body")"
[ "$(post "${P_WRAPPER}" "through the wrapper")" == "200" ] || fail "a send to the harness's own agent pane was refused: $(cat "${D}/body")"
for _ in $(seq 1 30); do tmux capture-pane -p -t "=${W_SESSION}:" | grep -qF "stub claude received: [through the wrapper]" && break; sleep 0.2; done
tmux capture-pane -p -t "=${W_SESSION}:" | grep -qF "stub claude received: [through the wrapper]" || fail "the message through the wrapper never arrived: $(tmux capture-pane -p -t "=${W_SESSION}:" | tail -4)"
kill "$(cat "${D}/chat-${P_WRAPPER}.pid")" 2> /dev/null
# the control: the wrapper without the job control - the three lines removed, each removal asserted
python3 - "${AGENT_DIR}/tmux-claude.sh" "${D}/wrapper/tmux-claude-nojc.sh" << 'PYEOF' || fail "could not derive the wrapper without job control"
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
for line in ("\t\tset -m\n", "\t\twhile [ -n \"$(jobs -ps)\" ]; do fg > /dev/null; done\n", "\t\tset +m\n"):
    assert s.count(line) == 1, line
    s = s.replace(line, "")
open(dst, "w").write(s)
PYEOF
wrapper_session "${D}/wrapper/tmux-claude-nojc.sh"
CMD=$(tmux display-message -t "=${W_SESSION}:" -p '#{pane_current_command}')
[ "${CMD}" == "bash" ] || fail "PLANTED CONTROL BROKEN: the wrapper without job control reports '${CMD}', not bash"
backend "${P_WRAPPER}" "${CHAT}" AGENT_TMUX_SESSION_NAME="${W_SESSION}"
[ "$(post "${P_WRAPPER}" "into the wrapper's bash")" == "409" ] || fail "PLANTED CONTROL BROKEN: the pane reporting bash was not refused: $(cat "${D}/body")"
grep -q "runs 'bash', not the agent CLI" "${D}/body" || fail "PLANTED CONTROL BROKEN: the refusal does not name bash: $(cat "${D}/body")"
tmux kill-session -t "=${W_SESSION}" 2> /dev/null
echo "ok 21 - the session's wrapper runs the agent CLI in its own process group: tmux reports claude for the harness's own agent pane and a send goes through; control: the wrapper without the job control reports bash for the same running CLI and the page refuses the pane as a shell"

# --- 22. only the hub's pane: a session the registry lists as a spoke is never typed into, and its menu never answered ---
S_SESSION=${SESSION}-spoke
tmux new-session -d -s "${S_SESSION}" -x 160 -y 40 "exec -a claude bash ${D}/stub-agent.sh" || fail "could not start the spoke's stub session"
for _ in $(seq 1 50); do tmux capture-pane -p -t "=${S_SESSION}:" | grep -q "stub agent ready" && break; sleep 0.2; done
s_screen() { tmux capture-pane -p -t "=${S_SESSION}:" -S -200; }
mkdir -p "${D}/registry"
# reg <file> <role> - a registry that lists the stub's session in that role
reg() { python3 -c 'import json, sys; json.dump({"version": 1, "sessions": [{"session_name": sys.argv[2], "role": sys.argv[3]}]}, open(sys.argv[1], "w"))' "$1" "${S_SESSION}" "$2"; }
reg "${D}/registry/spoke.json" spoke
reg "${D}/registry/hub.json" hub
backend "${P_SPOKE}" "${CHAT}" AGENT_TMUX_SESSION_NAME="${S_SESSION}" SPOKES_REGISTRY="${D}/registry/spoke.json"
[ "$(req "${P_SPOKE}" GET /state)" == "200" ] && [ "$(state_field writable)" == "false" ] || fail "/state does not say a spoke's pane takes no message: $(cat "${D}/body")"
grep -qF "is the registry's spoke" "${D}/body" || fail "/state does not name the spoke: $(cat "${D}/body")"
[ "$(post "${P_SPOKE}" "typed into a spoke")" == "409" ] || fail "a send into a spoke's pane was not refused: $(cat "${D}/body")"
grep -qF "is the registry's spoke" "${D}/body" || fail "the refusal does not name the spoke: $(cat "${D}/body")"
[ "$(req "${P_SPOKE}" POST /answer -H "Content-Type: application/json" -H "Origin: http://chat.localhost:${P_SPOKE}" --data-binary '{"option": 1, "key": "any"}')" == "409" ] \
	&& grep -qF "is the registry's spoke" "${D}/body" || fail "an answer to a spoke's menu was not refused naming the spoke: $(cat "${D}/body")"
sleep 1
s_screen | grep -qF "stub agent received:" && fail "something reached the spoke's pane: $(s_screen | grep 'stub agent received' | head -3)"
kill "$(cat "${D}/chat-${P_SPOKE}.pid")" 2> /dev/null
# the same pane, listed as the hub: the message goes through
backend "${P_HUBREG}" "${CHAT}" AGENT_TMUX_SESSION_NAME="${S_SESSION}" SPOKES_REGISTRY="${D}/registry/hub.json"
[ "$(post "${P_HUBREG}" "typed into the hub")" == "200" ] || fail "a send into the registry's hub was refused: $(cat "${D}/body")"
for _ in $(seq 1 30); do s_screen | grep -qF "stub agent received: [typed into the hub]" && break; sleep 0.2; done
s_screen | grep -qF "stub agent received: [typed into the hub]" || fail "the message to the registry's hub never arrived"
kill "$(cat "${D}/chat-${P_HUBREG}.pid")" 2> /dev/null
# PLANTED CONTROL: a copy of the backend without the registry check types into the spoke's pane
mutant noregistry 'role = registry_role(SESSION)' 'role = None'
backend "${P_NOREG}" "${D}/mutant/noregistry.py" AGENT_TMUX_SESSION_NAME="${S_SESSION}" SPOKES_REGISTRY="${D}/registry/spoke.json"
[ "$(post "${P_NOREG}" "the mutant typed into a spoke")" == "200" ] || fail "PLANTED CONTROL BROKEN: the copy without the registry check refused too: $(cat "${D}/body")"
for _ in $(seq 1 30); do s_screen | grep -qF "stub agent received: [the mutant typed into a spoke]" && break; sleep 0.2; done
s_screen | grep -qF "stub agent received: [the mutant typed into a spoke]" || fail "PLANTED CONTROL BROKEN: the copy without the registry check did not type into the spoke"
kill "$(cat "${D}/chat-${P_NOREG}.pid")" 2> /dev/null
tmux kill-session -t "=${S_SESSION}" 2> /dev/null
echo "ok 22 - a session the registry lists as a spoke: /state says no and why, a send and an answer are 409 naming the spoke, nothing reaches its pane; the same pane listed as the hub takes the message; control: a copy without the registry check types into the spoke"

[ -z "${TEST_CONTAINER}" ] || [ "$(find /wd -mindepth 1 2>/dev/null | wc -l)" == "0" ] || fail "this test wrote under /wd: $(find /wd -mindepth 1 | head -5)"
OK=true
echo "Test-agent-chat succeeded"
