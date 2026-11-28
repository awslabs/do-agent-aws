#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the self-hosted kanban board wiring inside the container (docs/manual/boards.md "Kanban board"): the home
# proxy's board and runner routes (/agent/home-render.sh), the goal mirror /agent/kanban-sync.py, and its hooks in
# the autonomy loop (/agent/loop-once.sh, kept in sync with /agent/loop.sh). Fully OFFLINE: the board is a stub of
# the board server's REST API on a test-local port, claude is a stub, everything binds 127.0.0.1, and all state
# lives under /tmp/kanban-smoke. The real board (the sidecar containers ./run.sh starts) is checked from the host
# by ./test-kanban.sh.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the scripts parse (bash -n, python3 py_compile)
#   2. home-render.sh with KANBAN_BOARD_URL routes kanban.localhost to the board through a variable with a resolver
#      (a board that is down is a 502 on that route, never an nginx that cannot start), /__harness/sign-in on that
#      host to the sign-in helper, vk-runner.localhost to the agent runner; the board tile links the sign-in and
#      names the login FILE, the runner tile opens the runner's /workspaces (not its start page, which ends in a
#      cloud sign-in), the two are titled by task (Goals board, Agent workspaces) and carry a same-origin
#      status probe (data-probe; /__probe/kanban asks the sign-in helper for a database read), and every tile opens
#      in a new tab; the board's and the runner's routes send one Content-Security-Policy, word for word, that
#      allows the page's own origin and its websocket only (the browser then refuses the third-party calls compiled
#      into vibe-kanban 0.1.44), the sign-in page does not get it; without
#      KANBAN_BOARD_URL (control: test.sh's container, kubernetes) kanban.localhost serves the runner as before, with
#      the same policy, its tile opens /workspaces, and there is no sign-in route; a KANBAN_BOARD_URL carrying nginx
#      syntax is refused; every rendered config validates (nginx -t); the board route injects the live-sync
#      meta and sends its own CSP (connect-src + http://kanban-sync.<home host>), a kanban-sync.localhost block proxies
#      /v1/shape/ alone with CORS for the board's origin only and no credentials (another origin's read is refused by the
#      proxy's same-origin gate before the board server sees it); cut out, the config still validates
#   3. through the running proxy: Host kanban.localhost reaches the board, vk-runner.localhost the runner, both
#      answering with exactly that policy, its websocket source naming the Host the browser sent; the board route
#      drops the board server's CORS headers (it allows any Origin with credentials); the home page's
#      same-origin status probes answer, GET-only and status-only (home-render.sh's probe_location: 204 when the upstream
#      answered 2xx, 500 otherwise, never its body): /__probe/kanban 204 only while the board answers a read from its
#      database (500 with the database failing or the board stopped; with a board that never answers, five probes at
#      once all answer 500 within 9 s), /__probe/vk-runner 204; the one-click sign-in
#      (/agent/kanban-signin.py, started with a dead proxy in its environment) answers kanban.localhost, for a
#      request from the home page on that port (its Referer or Origin), with a no-store page that may not be framed
#      (X-Frame-Options DENY, frame-ancestors 'none'), stores the board session in the board app's IndexedDB and
#      carries no password; it refuses (403) a request with no Origin or Referer, another site's, or the home page's
#      on another port, any other Host (directly, not routed through the proxy), a board answer without a refresh
#      token (502), and an unreadable login file (503); with the board stopped kanban.localhost answers 502 while the
#      home page still answers 200
#   4. kanban-sync.py against the stub API: sync creates the project and one card per goal (checkbox items and
#      "## Goal" headings; a checked one in Done), each card's sort_order minus the time its goal reached the board
#      (the newest on top of its column, Done included; kept in the state file, so a switch and back gives the same
#      values; KANBAN_CARD_ORDER=file gives the file's order and the switch PATCHes every card; an empty value is the
#      default; a bad value exits 4 naming the two values and touches nothing; an upgraded board is re-sorted by its
#      cards' creation times at the first sync), a second sync creates and moves nothing (uuidv5 ids), a sync
#      with a dead proxy in its environment still reaches the board; the board's default name for the personal
#      organization ("<user id>'s Org") becomes the project's name, a name someone chose stays;
#      fire-start moves the first open goal to In progress and fire-end to In review when it stayed open, with one
#      comment carrying the rc and the transcript's end and a "Last fire" note in the card's description that a
#      later sync keeps; the password is in no output; planted secrets in a transcript (the login's password, a
#      secret-named environment value, a value of the AWS credentials file, Slack/AWS/JWT shapes, NAME=value, the
#      credentials file's aws_secret_access_key line, the CLI's credentials JSON and its text output's CREDENTIALS
#      row, a session token alone and after an escaped \n, botocore's secret_key='...', a bearer token, and a value
#      spanning the cut of the posted end) reach the board masked, while a token count in a string ("max_tokens":
#      "4096") stays readable
#   5. loop-once.sh with a stub claude that checks its goal off: the prompt tells it how a goal is marked done, the
#      card is In progress WHILE the fire runs, Done after it, and loop.log has the two KANBAN lines; with the board
#      DOWN the same kind of fire still ends rc=0 and loop.log says "not mirrored"; without KANBAN_BOARD_URL no
#      KANBAN line and no board call (the pre-board behavior); on "## Goal" headings as docs/loop/GOALS.md.example
#      writes them: a fire that adds [x] to its heading moves that card to Done and comments on it, a fire that
#      finishes a later goal than the one it started on is credited to the finished one, and a fire that renames
#      its goal leaves the old card In review with a note
#   6. a refused login exits 3, a login the board fails (5xx) or any unexpected error exits 2, a host that is not
#      loopback or a docker network name exits 4 (the login never leaves the host), and none prints the password
#   7. the startup seed, on a fresh instance with no fire and no goals file: ui-start.sh starts kanban-sync.py seed in
#      the background (it returns at once with the board down) and removes an earlier start's exit status file
#      (kanban-seed.done), the seed waits for the board, then creates the project with the card of the shipped
#      default goals' standing goal in To do and writes its exit status 0 to that file, and the sign-in lands on that
#      project; a second seed changes nothing; once a goals file exists its goals get cards and the default goal's
#      card moves to the hidden Cancelled column (back to To do when the file goes); a fire on the default goals that
#      creates the goals file leaves its result on the default goal's card, Cancelled; a card a fire created between
#      the seed's read and its create keeps the fire's column; with no goals at all the project is still created; an
#      unreachable board ends the seed with rc 2 after KANBAN_SEED_WAIT, a refused login with 3 at once, and --done
#      writes that rc, with the file of an earlier run (and its .tmp) removed while the run lasts. The test reads the
#      seed's end from that file, never from its pid: under an init that does not reap (a container's PID 1 that is
#      no init), a seed that ended stays a zombie, which kill -0 still finds
#   8. the agent runner's first-start settings (vibe-kanban-config.json) are its own 0.1.44 settings, every field,
#      with analytics_enabled false and its Workspaces guide seen, nothing else (terms, disclaimer and onboarding
#      unanswered; the retired cloud's sign-in onboarding alone is seen, so the runner's root goes to the workspaces and
#      not to a cloud sign-in); ui-start.sh writes them when the runner has no settings yet and says so; a later start leaves
#      them; settings that exist are never changed, and with analytics on a one-line notice says so, on the start
#      output, in the runner's log and in a notice file of this start only (a later start without the notice
#      removes it). The runner's agent settings (vibe-kanban-profiles.json) are Claude Code as the image's claude
#      without --dangerously-skip-permissions, alone; ui-start.sh writes them when there are none (with or without
#      other settings) and says so, a later start leaves them, and agent settings that exist are never changed
#   9. a board that answers every signed-in call with a 302 to another loopback listener (it records what reaches it):
#      kanban-sync.py and kanban-signin.py follow no redirect - the sync exits 2 saying so, the probe answers 502, the
#      sign-in lands on the board's start page - and 0 requests, so no board session, reach the other listener

D=/tmp/kanban-smoke
rm -rf "${D:?}"
mkdir -p ${D}

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
SYNC=${AGENT_DIR}/kanban-sync.py

HOME_PORT=18190
RUNNER_PORT=18191
BOARD_PORT=18192
DEAD_PORT=18193
SIGNIN_PORT=18194
RECORDER_PORT=18195
PASSWORD=test18-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

cleanup()
{
	for P in "${D}"/relay.pid "${D}"/nginx-relay.pid "${D}"/board.pid "${D}"/runner.pid "${D}"/nginx.pid "${D}"/signin.pid "${D}"/recorder.pid "${D}"/repos-runner.pid "${D}"/watch.pid "${D}"/fake-loop.pid "${D}"/ui-seed/*.pid; do
		[ -f "${P}" ] && kill "$(cat "${P}")" 2>/dev/null
	done
}

fail()
{
	echo "Test18 FAILED: $1"
	cleanup
	exit 1
}

# --- 1. syntax ---
for S in "${AGENT_DIR}/home-render.sh" "${AGENT_DIR}/ui-start.sh" "${AGENT_DIR}/ui-status.sh" "${AGENT_DIR}/ui-stop.sh" \
         "${AGENT_DIR}/loop.sh" "${AGENT_DIR}/loop-once.sh"; do
	bash -n "${S}" || fail "bash -n ${S}"
done
for S in "${SYNC}" "${AGENT_DIR}/kanban-signin.py"; do
	python3 -c "import py_compile, sys; py_compile.compile(sys.argv[1], cfile='${D}/py.pyc', doraise=True)" "${S}" \
		|| fail "python3 py_compile ${S}"
done
echo "ok 1 - syntax"

if ! command -v nginx > /dev/null || ! command -v python3 > /dev/null; then
	echo "Test18 skipped: nginx/python3 not installed"
	exit 0
fi

# --- the stub board: the board server's REST API as kanban-sync.py uses it (create-or-409, PATCH, statuses
# created with the project, Bearer auth), plus GET /__state for the checks below ---
cat > ${D}/stub-board.py << 'EOF'
import datetime, json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
EMAIL, PASSWORD = os.environ["STUB_EMAIL"], os.environ["STUB_PASSWORD"]
TOKEN = "stub-token"
ORG = {"id": "00000000-0000-0000-0000-00000000000a", "name": "1f0e4c7a-3b2d-4e5f-8a9b-0c1d2e3f4a5b's Org", "slug": "p",
       "is_personal": True}
S = {"projects": {}, "statuses": {}, "issues": {}, "comments": {}, "calls": []}
NAMES = ["Backlog", "To do", "In progress", "In review", "Done", "Cancelled"]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def reply(self, code, body=None, ctype="application/json"):
        raw = (json.dumps(body) if ctype == "application/json" else body or "").encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        if self.headers.get("Origin"):  # the board server's CORS: any Origin, with credentials
            self.send_header("Access-Control-Allow-Origin", self.headers["Origin"])
            self.send_header("Access-Control-Allow-Credentials", "true")
        self.end_headers()
        self.wfile.write(raw)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
    def authed(self):
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.reply(401, {"error": "unauthorized"})
            return False
        if os.path.exists(os.environ.get("STUB_REDIRECT", "/nonexistent")):  # a 302 to another host, for check 9
            self.send_response(302)
            self.send_header("Location", os.environ["STUB_REDIRECT_TO"] + self.path)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        return True
    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/__state":
            return self.reply(200, S)
        if u.path == "/workspaces" or u.path.startswith("/workspaces/"):   # the board's bundle: the route that crashes in the browser
            return self.reply(200, "<html><head><title>board-stub</title></head><body>board-stub workspaces (the bundle crashes here)</body></html>", "text/html")
        if u.path == "/":
            return self.reply(200, "<html><head><title>board-stub</title></head><body>board-stub</body></html>", "text/html")
        if u.path == "/v1/health":
            return self.reply(200, {"status": "ok"})
        if u.path == "/__redirect":  # an upstream redirect to the Location asked for (check 3: re-hosted on the tile)
            self.send_response(302)
            self.send_header("Location", q.get("to", "/"))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self.authed():
            return
        S["calls"].append("GET " + u.path)
        if u.path == "/v1/organizations":
            if os.path.exists(os.environ.get("STUB_HANG_DB", "/nonexistent")):  # a board that accepts and never answers
                time.sleep(20)
            if os.path.exists(os.environ.get("STUB_FAIL_DB", "/nonexistent")):
                return self.reply(500, {"error": "database error"})
            return self.reply(200, {"organizations": [ORG]})
        if u.path == "/v1/project_statuses":
            return self.reply(200, {"project_statuses": S["statuses"].get(q.get("project_id"), [])})
        if u.path == "/v1/issues":
            if os.path.exists(os.environ.get("STUB_HIDE_ISSUES", "/nonexistent")):  # a read before a concurrent create
                return self.reply(200, {"issues": []})
            return self.reply(200, {"issues": [i for i in S["issues"].values() if i["project_id"] == q.get("project_id")]})
        if u.path.startswith("/v1/projects/"):
            pid = u.path.rsplit("/", 1)[-1]
            return self.reply(200, S["projects"][pid]) if pid in S["projects"] else self.reply(404, {"error": "not found"})
        if u.path.startswith("/v1/shape/"):  # an Electric shape (the live-sync proxy): the client's headers, the board's CORS
            raw = b"[]"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            for k, v in (("electric-handle", "h-1"), ("electric-offset", "0_0"), ("electric-schema", "{}"),
                         ("electric-cursor", "c-1"), ("electric-up-to-date", "true"), ("Vary", "Authorization")):
                self.send_header(k, v)
            if self.headers.get("Origin"):  # the board server mirrors ANY Origin, with credentials, and exposes everything
                self.send_header("Access-Control-Allow-Origin", self.headers["Origin"])
                self.send_header("Access-Control-Allow-Credentials", "true")
                self.send_header("Access-Control-Expose-Headers", "*")
            self.end_headers()
            self.wfile.write(raw)
            return
        self.reply(404, {"error": "not found"})
    def do_OPTIONS(self):  # a preflight that reached the board: recorded (the proxy must answer it itself)
        S["calls"].append("OPTIONS " + urlparse(self.path).path)
        self.reply(200, {})
    def do_POST(self):
        u = urlparse(self.path)
        b = self.body()
        if u.path == "/v1/auth/local/login":
            if os.path.exists(os.environ.get("STUB_FAIL_LOGIN", "/nonexistent")):
                return self.reply(500, {"error": "internal_error"})
            if b.get("email") == EMAIL and b.get("password") == PASSWORD:
                if os.path.exists(os.environ.get("STUB_NO_REFRESH", "/nonexistent")):
                    return self.reply(200, {"access_token": TOKEN})
                return self.reply(200, {"access_token": TOKEN, "refresh_token": "r"})
            return self.reply(401, {"error": "invalid_credentials"})
        if not self.authed():
            return
        S["calls"].append("POST " + u.path)
        table = {"/v1/projects": "projects", "/v1/issues": "issues", "/v1/issue_comments": "comments"}.get(u.path)
        if not table:
            return self.reply(404, {"error": "not found"})
        if b["id"] in S[table]:
            return self.reply(409, {"error": "conflict"})
        if table == "issues":  # the server stamps a created issue
            b.setdefault("created_at", datetime.datetime.now(datetime.timezone.utc).isoformat())
        S[table][b["id"]] = b
        if table == "projects":
            S["statuses"][b["id"]] = [{"id": str(uuid.uuid4()), "name": n} for n in NAMES]
        self.reply(200, {"data": b, "txid": 1})
    def do_PATCH(self):
        u = urlparse(self.path)
        if not self.authed():
            return
        S["calls"].append("PATCH " + u.path)
        if u.path == "/v1/organizations/" + ORG["id"]:
            ORG["name"] = self.body()["name"]
            return self.reply(200, ORG)
        if u.path.startswith("/v1/projects/"):
            pid = u.path.rsplit("/", 1)[-1]
            if pid not in S["projects"]:
                return self.reply(404, {"error": "not found"})
            S["projects"][pid].update(self.body())
            return self.reply(200, {"data": S["projects"][pid], "txid": 3})
        iid = u.path.rsplit("/", 1)[-1]
        if not u.path.startswith("/v1/issues/") or iid not in S["issues"]:
            return self.reply(404, {"error": "not found"})
        S["issues"][iid].update(self.body())
        self.reply(200, {"data": S["issues"][iid], "txid": 2})
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF

start_board()
{
	STUB_EMAIL=agent@test18.local STUB_PASSWORD="${PASSWORD}" STUB_FAIL_LOGIN=${D}/fail-login STUB_FAIL_DB=${D}/fail-db STUB_NO_REFRESH=${D}/no-refresh \
		STUB_HIDE_ISSUES=${D}/hide-issues STUB_HANG_DB=${D}/hang-db STUB_REDIRECT=${D}/redirect STUB_REDIRECT_TO=http://127.0.0.1:${RECORDER_PORT} \
		setsid nohup python3 ${D}/stub-board.py ${BOARD_PORT} > ${D}/board.log 2>&1 &
	echo $! > ${D}/board.pid
	for _ in $(seq 1 50); do
		curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${BOARD_PORT}/v1/health" && return 0
		sleep 0.2
	done
	fail "stub board did not start: $(cat ${D}/board.log)"
}

# status_of <goal text> - the column of that goal's card in the stub board, by title
status_of()
{
	curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | GOAL="$1" python3 -c '
import json, os, sys
s = json.load(sys.stdin)
names = {st["id"]: st["name"] for sts in s["statuses"].values() for st in sts}
hits = [names.get(i["status_id"]) for i in s["issues"].values() if i["title"] == os.environ["GOAL"]]
print(hits[0] if len(hits) == 1 else "cards=%d" % len(hits))'
}

state_count()
{
	curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "import json, sys; s = json.load(sys.stdin); print(len(s['$1']))"
}

cat > ${D}/kanban.env << EOF
SELF_HOST_LOCAL_AUTH_EMAIL=agent@test18.local
SELF_HOST_LOCAL_AUTH_PASSWORD=${PASSWORD}
EOF
chmod 600 ${D}/kanban.env

# --- 2. rendering: board route, runner route, the tile, the control, the refusal ---
render()
{
	# render <dir> [KANBAN_BOARD_URL] - the defaults of every other UI, test-local ports
	# UI_VIBE_KANBAN forced on, as test13/test14 force their own flags: this test is about the board's wiring
	UI_DIR=$1 UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME=${HOME_PORT} UI_PORT_VIBE_KANBAN=${RUNNER_PORT} UI_TMUX_AGENT=false \
		UI_VIBE_KANBAN=true UI_PORT_KANBAN_SIGNIN=${SIGNIN_PORT} COMMS_UI_ENABLED=false KANBAN_BOARD_URL="$2" \
		KANBAN_AUTH_FILE=/wd/kanban/kanban.env "${AGENT_DIR}/home-render.sh"
}
render ${D}/ui > ${D}/render.log 2>&1 "http://127.0.0.1:${BOARD_PORT}" || fail "home-render.sh (board): $(cat ${D}/render.log)"
CONF=${D}/ui/home/nginx.conf
PAGE=${D}/ui/home/site/index.html
BOARD_BLOCK=$(sed -n '/server_name kanban.localhost;/,/^\t}/p' ${CONF})
# shellcheck disable=SC2016 # the literal nginx variable, not a shell expansion
echo "${BOARD_BLOCK}" | grep -qF 'proxy_pass $kanban_board;' || fail "kanban.localhost does not proxy through the board variable: ${BOARD_BLOCK}"
echo "${BOARD_BLOCK}" | grep -qF "set \$kanban_board http://127.0.0.1:${BOARD_PORT};" || fail "the board URL is not the one passed"
echo "${BOARD_BLOCK}" | grep -qE '^\s*resolver \S+ valid=10s ipv6=off;' || fail "the board route has no per-request resolver"
sed -n '/server_name vk-runner.localhost;/,/^\t}/p' ${CONF} | grep -qF "proxy_pass http://127.0.0.1:${RUNNER_PORT};" \
	|| fail "vk-runner.localhost does not proxy to the agent runner"
grep -qF 'data-host="kanban"' ${PAGE} || fail "no Kanban board tile"
grep -qF 'data-host="vk-runner"' ${PAGE} || fail "no agent runner tile"
# tile_li <host> - the home page's <li> of that host's tile, so its attributes are matched one by one, in any order
tile_li()
{
	grep -o "<li class=\"tile\"[^>]*data-host=\"$1\"[^>]*>" "${2:-${PAGE}}"
}
tile_li vk-runner | grep -qF 'data-path="/workspaces"' \
	|| fail "the runner tile does not open its workspaces (its start page ends in a vibe-kanban cloud sign-in)"
# the two views are told apart by task-first titles, and their dots read same-origin status probes
grep -qE '<a [^>]*target="_blank"[^>]*>Goals board</a>' ${PAGE} || fail "the board tile is not titled Goals board"
grep -qE '<a [^>]*target="_blank"[^>]*>Agent workspaces</a>' ${PAGE} || fail "the runner tile is not titled Agent workspaces"
# the board tile says what a first load costs, and a UI that does not answer yet reads "starting", not "down"
grep -oE 'Goals board</a>.{0,700}' ${PAGE} | grep -qF 'the first load after a container start takes up to half a minute' || fail "the board tile does not say what a first load costs"
grep -qF ".dot.starting {" ${PAGE} || fail "the home page has no starting state for a UI that does not answer yet"
grep -qF "dot.className = 'dot ' + (failures < 6 ? 'starting' : 'down')" ${PAGE} || fail "a failed probe does not read starting before down"
# the runner routes' harness touches: /settings (not a route of the runner's frontend) answers a redirect to the workspaces,
# and the retired cloud's prompts are hidden by a script injected before </head> - on the runner route only, never on the board
grep -qF 'location = /settings { return 302 /workspaces; }' ${D}/ui/home/runner-harness.conf || fail "runner-harness.conf does not redirect /settings to /workspaces: $(cat ${D}/ui/home/runner-harness.conf)"
sed -n '/server_name vk-runner.localhost;/,/^\t}/p' ${CONF} | grep -qF "include ${D}/ui/home/runner-harness.conf;" || fail "the runner route does not include runner-harness.conf (/settings -> /workspaces)"
sed -n '/server_name vk-runner.localhost;/,/^\t}/p' ${CONF} | grep -qF "include ${D}/ui/home/runner-hide-cloud.conf;" || fail "the runner route does not include runner-hide-cloud.conf"
for S in 'data-harness="hide-cloud"' 'Kanban Boards' 'Sign in to organise your coding agents with kanban boards.' 'Sign in to view projects' 'Organization'; do
	grep -qF -- "${S}" ${D}/ui/home/runner-hide-cloud.conf || fail "runner-hide-cloud.conf does not target '${S}' (the runner's own string for the retired cloud prompt)"
done
sed -n '/server_name kanban.localhost;/,/^\t}/p' ${CONF} | grep -q "runner-hide-cloud\|runner-harness" && fail "the BOARD route carries the runner's harness touches"
tile_li kanban | grep -qF 'data-probe="/__probe/kanban"' || fail "the Goals board tile has no status probe"
tile_li vk-runner | grep -qF 'data-probe="/__probe/vk-runner"' || fail "the runner tile has no status probe"
grep -qF 'el.dataset.probe' ${PAGE} || fail "the page does not read the tiles' data-probe"
# the probes live in the home listener's loopback-names server (server_name _; is the 421 catch-all), GET-only
# and status-only: the client location only runs an auth_request to an internal location that holds the upstream
HOME_BLOCK=$(sed -n '/server_name localhost 127.0.0.1 \[::1\]/,/^\t}/p' ${CONF})
# status_probe <name> <upstream> - the status-only probe pair of that tile, with that upstream
status_probe()
{
	# the whole location, to its closing brace on the location's own indent (limit_except's braces sit inside it)
	local P U
	P=$(echo "${HOME_BLOCK}" | sed -n "/location = \/__probe\/$1 {/,/^\t\t}$/p")
	U=$(echo "${HOME_BLOCK}" | sed -n "/location = \/__probe_up\/$1 {/,/^\t\t}$/p")
	echo "${P}" | grep -qF 'limit_except GET { deny all; }' && echo "${P}" | grep -qF "auth_request /__probe_up/$1;" \
		&& ! echo "${P}" | grep -q 'proxy_pass' && echo "${U}" | grep -qF "proxy_pass $2;" && echo "${U}" | grep -qF 'internal;'
}
status_probe kanban "http://127.0.0.1:${SIGNIN_PORT}/healthz/board" \
	|| fail "/__probe/kanban is not a status-only probe of the sign-in helper's database-backed board health"
status_probe vk-runner "http://127.0.0.1:${RUNNER_PORT}/api/health" \
	|| fail "/__probe/vk-runner is not a status-only probe of the runner's /api/health"
[ "$(grep -c 'location = /__probe/kanban {' ${CONF})" == "1" ] || fail "more than one /__probe/kanban location (nginx -t refuses a duplicate)"
grep -qF 'this link signs you in (the login is in /wd/kanban/kanban.env' ${PAGE} || fail "the board tile does not say where the login is"
tile_li kanban | grep -qF 'data-path="/__harness/sign-in"' || fail "the board tile does not link the one-click sign-in"
echo "${BOARD_BLOCK}" | sed -n '/location = \/__harness\/sign-in {/,/}/p' | grep -qF "proxy_pass http://127.0.0.1:${SIGNIN_PORT};" \
	|| fail "kanban.localhost has no /__harness/sign-in route to the sign-in helper"
TILE_LINKS=$(grep -o '<li class="tile"[^>]*><span class="dot"></span><a [^>]*>' ${PAGE})
[ "$(echo "${TILE_LINKS}" | grep -c .)" -ge 6 ] || fail "fewer tile links than enabled UIs: ${TILE_LINKS}"
echo "${TILE_LINKS}" | grep -vE 'target="_blank" rel="(no)?opener"' | grep -q . && fail "a tile link does not open in a new tab: $(echo "${TILE_LINKS}" | grep -v 'target="_blank"')"
# every vibe-kanban host route keeps its redirects on its own host (home-render.sh's host_redirect_rules); the board's route
# proxies through a variable, where nginx refuses "proxy_redirect default", so it also names the board's own URL
BOARD_ROOT=$(echo "${BOARD_BLOCK}" | sed -n '/location \/ {/,/^\t\t}$/p')
echo "${BOARD_ROOT}" | grep -qF "proxy_redirect http://127.0.0.1:${BOARD_PORT}/ http://\$http_host/;" \
	|| fail "the board route does not rewrite the board's own redirects onto kanban.localhost"
echo "${BOARD_ROOT}" | grep -q 'proxy_redirect default' && fail "the board route uses 'proxy_redirect default' (nginx refuses it with a variable proxy_pass)"
# relative_rule <server block> - 0 when it re-hosts a relative Location on the browser's host and port
relative_rule()
{
	grep -qF 'proxy_redirect ~^(/(?![/\x5c]).*)$ http://$http_host$1;'
}
echo "${BOARD_ROOT}" | relative_rule || fail "the board route does not keep a relative redirect on kanban.localhost"
sed -n '/server_name vk-runner.localhost;/,/^\t}/p' ${CONF} | relative_rule \
	|| fail "the runner route does not keep a relative redirect on vk-runner.localhost"
sed -n '/server_name vk-runner.localhost;/,/^\t}/p' ${CONF} \
	| grep -qF "proxy_redirect ~^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\]):${RUNNER_PORT}(/.*)?\$ http://\$http_host\$2;" \
	|| fail "the runner route does not re-host the runner's own loopback address"
grep -qF "${PASSWORD}" ${PAGE} ${CONF} && fail "the password reached the home page or the proxy config"
# the browser egress lock of the vibe-kanban pages: one policy, own origin and its websocket only, on the board's and
# the runner's routes
CSP=${D}/ui/home/csp-vibe-kanban.conf
# the whole policy, word for word: one widened source (font-src *, style-src http:) lets a third party back in
# nosemgrep: detect-insecure-websocket -- the test asserts the Content-Security-Policy's same-host websocket sources
CSP_POLICY="default-src 'self'; connect-src 'self' ws://\$http_host wss://\$http_host; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; worker-src 'self' blob:; frame-src 'self' http://localhost:* http://127.0.0.1:* http://*.localhost:*; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
[ "$(cat ${CSP})" == "add_header Content-Security-Policy \"${CSP_POLICY}\" always;" ] \
	|| fail "the vibe-kanban CSP is not exactly the own-origin policy: $(cat ${CSP})"
# nosemgrep: detect-insecure-websocket -- the test asserts the Content-Security-Policy's same-host websocket sources
grep -qF "connect-src 'self' ws://\$http_host wss://\$http_host;" ${CSP} \
	|| fail "the vibe-kanban CSP does not limit connect-src to the page's own origin: $(cat ${CSP})"
grep -qiE 'sentry|posthog|google|github|discord|https:' ${CSP} && fail "the vibe-kanban CSP lets a third-party host in: $(cat ${CSP})"
grep -qF "frame-ancestors 'self'" ${CSP} || fail "the vibe-kanban CSP lets other sites frame the board and the runner: $(cat ${CSP})"
echo "${BOARD_BLOCK}" | sed -n '/location \/ {/,/}/p' | grep -qF "include ${CSP};" && fail "the board route sends the shared vibe-kanban CSP instead of its own file (connect-src + the live-sync origin)"
echo "${BOARD_BLOCK}" | sed -n '/location = \/__harness\/sign-in {/,/}/p' | grep -qF "csp-vibe-kanban" \
	&& fail "the sign-in page got the board's CSP (its inline script is the page)"
sed -n '/server_name vk-runner.localhost;/,/^\t}/p' ${CONF} | grep -qF "include ${CSP};" || fail "the agent runner route does not send the CSP"
# the live-sync origin: a second server block, kanban-sync.localhost, for the board's shape long-polls -
# the same board variable, the shape endpoints alone (404 elsewhere), CORS from the maps for the board's own origin only and
# never with credentials, the five Electric headers exposed, the preflight answered in nginx, the board server's own CORS
# hidden; the board route carries the meta naming that origin and its own CSP file letting the page connect to it; the
# runner route has neither; PLANTED: the sync block cut out of the config leaves it valid (the board does not depend on it)
SYNC_BLOCK=$(sed -n '/server_name kanban-sync.localhost;/,/^\t}/p' ${CONF})
[ -n "${SYNC_BLOCK}" ] || fail "no kanban-sync.localhost server block"
for L in 'location ^~ /v1/shape/ {' 'proxy_pass $kanban_board;' 'proxy_read_timeout 75s;' 'return 404;' 'if ($request_method = OPTIONS) {' 'return 204;' \
         'add_header Access-Control-Allow-Origin $sync_origin always;' 'add_header Access-Control-Expose-Headers $sync_expose always;' 'add_header Vary Origin always;' \
         'proxy_hide_header Access-Control-Allow-Origin;' 'proxy_hide_header Access-Control-Allow-Credentials;' 'proxy_hide_header Access-Control-Expose-Headers;' \
         'resolver '; do
	echo "${SYNC_BLOCK}" | grep -qF -- "${L}" || fail "the kanban-sync block lacks '${L}'"
done
echo "${SYNC_BLOCK}" | grep -qi 'add_header Access-Control-Allow-Credentials' && fail "the kanban-sync block sets Allow-Credentials"
echo "${SYNC_BLOCK}" | grep -qE 'badge|sub_filter' && fail "the kanban-sync block injects into responses (badge or sub_filter)"
grep -qE '^\s*map "\$http_origin\|\$home_host" \$sync_origin \{' ${CONF} || fail "no sync_origin map (the Origin must equal http://kanban.<home host>)"
grep -qF '"electric-cursor, electric-handle, electric-offset, electric-schema, electric-up-to-date"' ${CONF} || fail "the exposed Electric headers are not exactly the five the client reads"
BOARD_CSP_FILE=${D}/ui/home/csp-kanban-board.conf
BOARD_CSP_POLICY="${CSP_POLICY/ws:\/\/\$http_host wss:\/\/\$http_host;/ws:\/\/\$http_host wss:\/\/\$http_host http:\/\/kanban-sync.\$home_host;}"
[ "${BOARD_CSP_POLICY}" != "${CSP_POLICY}" ] || fail "test setup: the board policy did not take the sync origin"
[ "$(cat ${BOARD_CSP_FILE})" == "add_header Content-Security-Policy \"${BOARD_CSP_POLICY}\" always;" ] \
	|| fail "the board's CSP is not the vibe-kanban policy plus the live-sync origin in connect-src: $(cat ${BOARD_CSP_FILE})"
# nosemgrep: detect-insecure-websocket -- the test asserts the Content-Security-Policy's same-host websocket sources
grep -qF 'ws://kanban-sync' ${BOARD_CSP_FILE} && fail "the board's CSP lets a websocket to the sync origin (the shapes are fetch long-polls)"
echo "${BOARD_BLOCK}" | sed -n '/location \/ {/,/}/p' | grep -qF "include ${BOARD_CSP_FILE};" || fail "the board route does not send its own CSP file"
echo "${BOARD_BLOCK}" | sed -n '/location \/ {/,/}/p' | grep -qF "include ${D}/ui/home/board-sync-meta.conf;" || fail "the board route does not inject the live-sync meta"
[ "$(cat ${D}/ui/home/board-sync-meta.conf)" == "sub_filter '</head>' '<meta name=\"harness-sync-origin\" content=\"//kanban-sync.\$home_host\"></head>';" ] \
	|| fail "board-sync-meta.conf is not the one meta sub_filter: $(cat ${D}/ui/home/board-sync-meta.conf)"
sed -n '/server_name vk-runner.localhost;/,/^\t}/p' ${CONF} | grep -qE 'board-sync-meta|csp-kanban-board' && fail "the runner route took the board's meta or CSP"
sed '/^\t# kanban-sync.localhost - the board.s live-sync shapes/,/^\t}$/d' ${CONF} > ${D}/nginx-nosync.conf
grep -qE 'server_name kanban-sync.localhost;|location \^~ /v1/shape/' ${D}/nginx-nosync.conf && fail "PLANTED CONTROL BROKEN: the sync block was not cut out of the copy"
nginx -t -c ${D}/nginx-nosync.conf > ${D}/nginx-nosync.log 2>&1 || fail "without the kanban-sync block the config does not validate (the board route must not depend on it): $(cat ${D}/nginx-nosync.log)"
nginx -t -c ${CONF} > ${D}/nginx-t.log 2>&1 || fail "the board-mode nginx.conf does not validate: $(cat ${D}/nginx-t.log)"
render ${D}/ui-off > ${D}/render-off.log 2>&1 "" || fail "home-render.sh (no board)"
sed -n '/server_name kanban.localhost;/,/^\t}/p' ${D}/ui-off/home/nginx.conf | grep -qF "proxy_pass http://127.0.0.1:${RUNNER_PORT};" \
	|| fail "control: without KANBAN_BOARD_URL kanban.localhost does not serve the runner"
grep -qF 'kanban_board' ${D}/ui-off/home/nginx.conf && fail "control: a board route was rendered without KANBAN_BOARD_URL"
grep -qE 'server_name kanban-sync.localhost;|location \^~ /v1/shape/|board-sync-meta|csp-kanban-board' ${D}/ui-off/home/nginx.conf && fail "control: a live-sync route was rendered without KANBAN_BOARD_URL"   # the CORS maps alone are inert
grep -qF '__harness/sign-in' ${D}/ui-off/home/nginx.conf && fail "control: a sign-in route was rendered without KANBAN_BOARD_URL"
tile_li kanban ${D}/ui-off/home/site/index.html | grep -qF 'data-path="/workspaces"' \
	|| fail "control: without a board the kanban tile does not open the runner's workspaces"
sed -n '/server_name kanban.localhost;/,/^\t}/p' ${D}/ui-off/home/nginx.conf | grep -qF "include ${D}/ui-off/home/runner-hide-cloud.conf;" \
	|| fail "control: the runner on kanban.localhost (no board) does not hide the cloud prompts"
sed -n '/server_name kanban.localhost;/,/^\t}/p' ${D}/ui-off/home/nginx.conf | grep -qF "include ${D}/ui-off/home/runner-harness.conf;" \
	|| fail "control: the runner on kanban.localhost (no board) does not redirect /settings"
sed -n '/server_name kanban.localhost;/,/^\t}/p' ${D}/ui-off/home/nginx.conf | grep -qF "include ${D}/ui-off/home/csp-vibe-kanban.conf;" \
	|| fail "control: the runner on kanban.localhost (no board) does not send the CSP"
sed -n '/location = \/__probe_up\/kanban {/,/^\t\t}$/p' ${D}/ui-off/home/nginx.conf | grep -qF "proxy_pass http://127.0.0.1:${RUNNER_PORT}/api/health;" \
	|| fail "control: without a board /__probe/kanban does not probe the runner that kanban.localhost serves"
# the vibe-kanban policy is on exactly the board's (or, without a board, the runner-fallback's) and the runner's
# routes: a silent auto-merge once put the runner's include into loglearner.localhost instead
for C in ${CONF} ${D}/ui-off/home/nginx.conf; do
	for S in hindsight claude-mem loglearner; do
		sed -n "/server_name ${S}.localhost;/,/^\t}/p" ${C} | grep -qF 'csp-vibe-kanban.conf;' \
			&& fail "${S}.localhost carries the vibe-kanban Content-Security-Policy (${C})"
	done
	sed -n '/server_name localhost 127.0.0.1 \[::1\]/,/^\t}/p' ${C} | grep -qF 'csp-vibe-kanban.conf;' \
		&& fail "the home listener's own server carries the vibe-kanban Content-Security-Policy (${C})"
	if [ "${C}" == "${CONF}" ]; then   # with a board: the runner route has the shared policy, the board route its own file
		[ "$(grep -c 'csp-vibe-kanban.conf;' ${C})" == "1" ] && [ "$(grep -c 'csp-kanban-board.conf;' ${C})" == "1" ] \
			|| fail "with a board the shared vibe-kanban CSP must be on the runner route alone and the board's own CSP on the board route alone (${C}: $(grep -c 'csp-vibe-kanban.conf;' ${C}) shared, $(grep -c 'csp-kanban-board.conf;' ${C}) board)"
	else                               # no board: the runner on both hosts, the shared policy twice, no board file
		[ "$(grep -c 'csp-vibe-kanban.conf;' ${C})" == "2" ] && [ "$(grep -c 'csp-kanban-board.conf;' ${C})" == "0" ] \
			|| fail "the vibe-kanban Content-Security-Policy is not on exactly the kanban and vk-runner routes (${C}: $(grep -c 'csp-vibe-kanban.conf;' ${C}) includes, $(grep -c 'csp-kanban-board.conf;' ${C}) board files)"
	fi
done
sed -n '/server_name kanban.localhost;/,/^\t}/p' ${D}/ui-off/home/nginx.conf | relative_rule \
	|| fail "control: the runner on kanban.localhost (no board) does not keep a relative redirect on its host"
nginx -t -c ${D}/ui-off/home/nginx.conf > /dev/null 2>&1 || fail "the no-board nginx.conf does not validate"
render ${D}/ui-bad > ${D}/render-bad.log 2>&1 'http://127.0.0.1:1; } server { listen 9' || fail "home-render.sh (bad URL)"
grep -q "not a plain http(s)://host\[:port\] URL" ${D}/render-bad.log || fail "a KANBAN_BOARD_URL with nginx syntax was not refused"
grep -qF 'listen 9' ${D}/ui-bad/home/nginx.conf && fail "nginx syntax from KANBAN_BOARD_URL reached the config"
nginx -t -c ${D}/ui-bad/home/nginx.conf > /dev/null 2>&1 || fail "the refused-URL nginx.conf does not validate"
echo "ok 2 - kanban.localhost -> the board (variable + resolver) and the sign-in helper, vk-runner.localhost -> the runner, board tile = one-click sign-in naming the login file, runner tile = /workspaces, titles Goals board / Agent workspaces with same-origin status probes, tiles open new tabs; both vibe-kanban routes send exactly the own-origin CSP (not the sign-in page); runner fallback without a board; nginx syntax refused; all validate; live-sync: the kanban-sync block proxies /v1/shape/ alone to the board variable with CORS from the maps for the board's own origin and no credentials, the five Electric headers exposed, the preflight answered in nginx; the board route carries the sync meta and its own CSP file (connect-src + the sync origin, http only), the runner route neither; cut out, the config still validates"

# --- 3. through the running proxy ---
mkdir -p ${D}/runner/api && echo "<html><head><title>runner-stub</title></head><body>runner-stub</body></html>" > ${D}/runner/index.html && echo '{"success":true}' > ${D}/runner/api/health
( cd ${D}/runner && setsid nohup python3 -m http.server ${RUNNER_PORT} --bind 127.0.0.1 > ${D}/runner.log 2>&1 & echo $! > ${D}/pid.tmp ) && mv "${D:?}/pid.tmp" "${D:?}/runner.pid"
start_board
setsid nohup nginx -c ${CONF} -g "daemon off;" > ${D}/nginx.log 2>&1 &
echo $! > ${D}/nginx.pid
body()
{
	# body <host header> [<marker>] - the page through the proxy, retried while the stubs and nginx come up until it
	# answers 200 with a whole body, holding <marker> when one is given: an error page of the proxy (a 502 while an
	# upstream does not listen yet) is retried, not taken for the page. When the tries run out it prints no page and
	# returns 1, and the last answer's HTTP code and the start of its body go to stderr on one line, so the check that
	# fails says what came back
	local CODE TRIES=25
	for _ in $(seq 1 ${TRIES}); do
		rm -f "${D:?}/body.out"
		if CODE=$(curl -s -o ${D}/body.out -w '%{http_code}' --max-time 2 -H "Host: $1" "http://127.0.0.1:${HOME_PORT}/") \
			&& [ "${CODE}" == "200" ] && [ -s ${D}/body.out ] && { [ -z "$2" ] || grep -qF -- "$2" ${D}/body.out; }; then
			cat ${D}/body.out
			return 0
		fi
		sleep 0.2
	done
	echo "Test18: Host $1 gave no 200 page${2:+ holding ${2}} through the proxy in ${TRIES} tries; the last answer: HTTP ${CODE}, body: $(head -c 200 ${D}/body.out 2>/dev/null | tr '\r\n' '  ')" >&2
	return 1
}
body "kanban.localhost:${HOME_PORT}" board-stub | grep -q board-stub || fail "Host kanban.localhost does not reach the board through the proxy"
body "vk-runner.localhost:${HOME_PORT}" runner-stub | grep -q runner-stub || fail "Host vk-runner.localhost does not reach the runner through the proxy"
body "kanban.localhost:${HOME_PORT}" | grep -qF "href=\"//localhost:${HOME_PORT}/\"" || fail "the board page lacks the home badge"
body "vk-runner.localhost:${HOME_PORT}" | grep -qF "href=\"//localhost:${HOME_PORT}/\"" || fail "the runner page lacks the home badge"
body "vk-runner.localhost:${HOME_PORT}" | grep -qF 'data-harness="hide-cloud"' || fail "the runner page through the proxy lacks the cloud-prompt hiding script"
# the hiding script parses as served: nginx unescapes a backslash in a quoted sub_filter argument, and the script once
# went out with its selector's quotes unescaped, stopped at "missing ) after argument list" and hid nothing
script_ok()
{
	# script_ok - 0 when the runner page's hide-cloud script, as the proxy serves it, parses (node --check)
	body "vk-runner.localhost:${HOME_PORT}" > ${D}/runner-page.html
	python3 -c 'import re, sys; m = re.search(r"<script data-harness=\"hide-cloud\">(.*?)</script>", open(sys.argv[1]).read(), re.S); open(sys.argv[2], "w").write(m.group(1) if m else "")' \
		${D}/runner-page.html ${D}/hide-cloud.js
	[ -s ${D}/hide-cloud.js ] && node --check ${D}/hide-cloud.js > ${D}/hide-cloud.check 2>&1
}
command -v node > /dev/null 2>&1 || fail "node is needed to check the runner page's script as the proxy serves it"
script_ok || fail "the runner page's cloud-prompt hiding script, as served, does not parse: $(head -5 ${D}/hide-cloud.check)"
# PLANTED CONTROL: the selector's quotes written \" in the configuration (nginx serves them as ") - the script does not parse
cp ${D}/ui/home/runner-hide-cloud.conf ${D}/hide-cloud.conf.ok
python3 -c 'import sys; p = sys.argv[1]; c = open(p).read(); assert "\\\x27" in c; open(p, "w").write(c.replace("\\\x27", "\\\x22"))' ${D}/ui/home/runner-hide-cloud.conf \
	|| fail "PLANTED CONTROL BROKEN: runner-hide-cloud.conf has no \\' to plant"
nginx -c ${CONF} -s reload && sleep 1
script_ok && fail "PLANTED CONTROL BROKEN: the hiding script with its quotes written \\\" parsed as served"
cp ${D}/hide-cloud.conf.ok ${D}/ui/home/runner-hide-cloud.conf && nginx -c ${CONF} -s reload && sleep 1
script_ok || fail "the hiding script did not parse again with the configuration restored"
body "kanban.localhost:${HOME_PORT}" board-stub > ${D}/board-page.html || fail "the board page through the proxy did not answer for the hiding-script check"
grep -qF 'data-harness="hide-cloud"' ${D}/board-page.html && fail "the BOARD page through the proxy carries the runner's hiding script"
LOC=$(curl -s -D - -o /dev/null --max-time 5 -H "Host: vk-runner.localhost:${HOME_PORT}" "http://127.0.0.1:${HOME_PORT}/settings" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p')
[ "${LOC}" == "/workspaces" ] || fail "/settings on the runner host does not redirect to /workspaces on this listener (Location '${LOC}')"
for H in kanban vk-runner; do
	GOT=$(curl -s -D - -o /dev/null --max-time 5 -H "Host: ${H}.localhost:${HOME_PORT}" "http://127.0.0.1:${HOME_PORT}/" \
		| tr -d '\r' | sed -n 's/^[Cc]ontent-[Ss]ecurity-[Pp]olicy: //p')
	WANT=${CSP_POLICY//\$http_host/${H}.localhost:${HOME_PORT}}
	if [ "${H}" == "kanban" ]; then   # the board's own policy: the shared one plus the live-sync origin on the browser's port
		WANT=${BOARD_CSP_POLICY//\$http_host/${H}.localhost:${HOME_PORT}}; WANT=${WANT//\$home_host/localhost:${HOME_PORT}}
	fi
	[ "${GOT}" == "${WANT}" ] || fail "${H}.localhost does not answer with exactly its own-origin CSP: [${GOT}] (wanted [${WANT}])"
done
# /workspaces on the board host: the board's bundle crashes on the runner's route, so the proxy sends the
# path and everything under it to the runner's host on the port the browser is on, path and query kept; CONTROL: the same
# config with the two redirect locations cut out serves the board's page there (the crash) - the rule is what redirects
for P in /workspaces "/workspaces/abc?x=1&y=2" /workspaces/create; do
	HDRS=$(curl -s -D - -o /dev/null --max-time 5 -H "Host: kanban.localhost:${HOME_PORT}" "http://127.0.0.1:${HOME_PORT}${P}" | tr -d '\r')
	echo "${HDRS}" | head -1 | grep -q ' 302 ' || fail "kanban.localhost${P} is not a 302 to the runner: $(echo "${HDRS}" | head -1)"
	[ "$(echo "${HDRS}" | sed -n 's/^[Ll]ocation: //p')" == "http://vk-runner.localhost:${HOME_PORT}${P}" ] \
		|| fail "kanban.localhost${P} does not redirect to the runner's same path on the browser's port: $(echo "${HDRS}" | grep -i '^location')"
done
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: kanban.localhost:${HOME_PORT}" "http://127.0.0.1:${HOME_PORT}/workspacesx")" != "302" ] || fail "a path that merely starts with /workspaces was redirected"
cp ${CONF} ${CONF}.full
python3 - ${CONF} << 'PYCUT'
import re, sys
p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r"\n\t\tlocation = /workspaces \{\n\t\t\treturn 302 [^\n]*\n\t\t\}\n\t\tlocation \^~ /workspaces/ \{\n\t\t\treturn 302 [^\n]*\n\t\t\}", "", s)
assert s2 != s, "the redirect locations were not found in the config"
open(p, "w").write(s2)
PYCUT
nginx -c ${CONF} -s reload && sleep 1
CODE=$(curl -s -o ${D}/ws-control.html -w '%{http_code}' --max-time 5 -H "Host: kanban.localhost:${HOME_PORT}" "http://127.0.0.1:${HOME_PORT}/workspaces")
[ "${CODE}" == "200" ] && grep -q "board-stub workspaces" ${D}/ws-control.html || fail "PLANTED CONTROL BROKEN: without the redirect /workspaces on the board host does not reach the board's page (http=${CODE})"
cp ${CONF}.full ${CONF} && nginx -c ${CONF} -s reload && sleep 1
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: kanban.localhost:${HOME_PORT}" "http://127.0.0.1:${HOME_PORT}/workspaces")" == "302" ] || fail "the redirect did not come back with the config"
# the live-sync origin through the proxy: a shape read from the board's own origin carries exactly the
# CORS the contract names; another origin's read is refused by the proxy's same-origin gate (403, no CORS header) before the
# board server sees it; the preflight is a
# 204 answered in nginx that never reaches the board; everything but /v1/shape/ is 404 there; the board page carries the
# meta naming the sync origin on the port the browser is on, the runner page does not
SYNC_HOST="kanban-sync.localhost:${HOME_PORT}"
BOARD_ORIGIN="http://kanban.localhost:${HOME_PORT}"
HDRS=$(curl -s -D - -o ${D}/shape.body --max-time 5 -H "Host: ${SYNC_HOST}" -H "Origin: ${BOARD_ORIGIN}" -H "Authorization: Bearer stub-token" "http://127.0.0.1:${HOME_PORT}/v1/shape/issues?offset=-1" | tr -d '\r')
echo "${HDRS}" | head -1 | grep -q ' 200 ' || fail "a shape request on the sync host did not reach the board: $(echo "${HDRS}" | head -1)"
[ "$(echo "${HDRS}" | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: //p')" == "${BOARD_ORIGIN}" ] || fail "the sync host does not allow the board's own origin: $(echo "${HDRS}" | grep -i '^access-control')"
echo "${HDRS}" | grep -qi '^access-control-allow-credentials' && fail "the sync host passes Allow-Credentials on (the board server's): a cookie-bearing cross-origin read"
[ "$(echo "${HDRS}" | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Ee]xpose-[Hh]eaders: //p')" == "electric-cursor, electric-handle, electric-offset, electric-schema, electric-up-to-date" ] \
	|| fail "the exposed headers are not exactly the five Electric headers: $(echo "${HDRS}" | grep -i '^access-control-expose')"
for E in electric-handle electric-offset electric-schema electric-cursor electric-up-to-date; do
	echo "${HDRS}" | grep -qi "^${E}: " || fail "the shape response lost the ${E} header through the proxy"
done
echo "${HDRS}" | grep -i '^vary: ' | grep -qi 'origin' || fail "the sync response does not vary on Origin: $(echo "${HDRS}" | grep -i '^vary')"
echo "${HDRS}" | grep -i '^vary: ' | grep -qi 'authorization' || fail "the board server's own Vary was dropped: $(echo "${HDRS}" | grep -i '^vary')"
N_SHAPE=$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | grep -o '"GET /v1/shape/' | wc -l)
HDRS=$(curl -s -D - -o /dev/null --max-time 5 -H "Host: ${SYNC_HOST}" -H "Origin: http://evil.localhost:${HOME_PORT}" -H "Authorization: Bearer stub-token" "http://127.0.0.1:${HOME_PORT}/v1/shape/issues?offset=-1" | tr -d '\r')
echo "${HDRS}" | head -1 | grep -q ' 403 ' || fail "the sync host did not refuse the shape request from another origin with 403 (the proxy's same-origin gate): $(echo "${HDRS}" | head -1)"
echo "${HDRS}" | grep -qi '^access-control-' && fail "a foreign Origin got CORS headers on the sync host: $(echo "${HDRS}" | grep -i '^access-control')"
[ "$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | grep -o '"GET /v1/shape/' | wc -l)" == "${N_SHAPE}" ] || fail "the shape request from another origin reached the board server"
N_OPT=$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | grep -o '"OPTIONS ' | wc -l)
HDRS=$(curl -s -D - -o /dev/null --max-time 5 -X OPTIONS -H "Host: ${SYNC_HOST}" -H "Origin: ${BOARD_ORIGIN}" -H "Access-Control-Request-Method: GET" -H "Access-Control-Request-Headers: authorization" "http://127.0.0.1:${HOME_PORT}/v1/shape/issues?offset=-1" | tr -d '\r')
echo "${HDRS}" | head -1 | grep -q ' 204 ' || fail "the preflight is not a 204: $(echo "${HDRS}" | head -1)"
[ "$(echo "${HDRS}" | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Mm]ethods: //p')" == "GET, HEAD, OPTIONS" ] || fail "preflight methods: $(echo "${HDRS}" | grep -i allow-methods)"
[ "$(echo "${HDRS}" | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Hh]eaders: //p')" == "Authorization, Content-Type" ] || fail "preflight headers: $(echo "${HDRS}" | grep -i allow-headers)"
[ "$(echo "${HDRS}" | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Mm]ax-[Aa]ge: //p')" == "600" ] || fail "preflight max-age: $(echo "${HDRS}" | grep -i max-age)"
[ "$(echo "${HDRS}" | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: //p')" == "${BOARD_ORIGIN}" ] || fail "the preflight does not allow the board's origin: $(echo "${HDRS}" | grep -i '^access-control')"
[ "$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | grep -o '"OPTIONS ' | wc -l)" == "${N_OPT}" ] || fail "the preflight reached the board server"
HDRS=$(curl -s -D - -o /dev/null --max-time 5 -X OPTIONS -H "Host: ${SYNC_HOST}" -H "Origin: http://evil.localhost:${HOME_PORT}" -H "Access-Control-Request-Method: GET" "http://127.0.0.1:${HOME_PORT}/v1/shape/issues" | tr -d '\r')
echo "${HDRS}" | grep -qi '^access-control-' && fail "a foreign preflight got CORS headers: $(echo "${HDRS}" | grep -i '^access-control')"
for P in /v1/health / /v1/issues /projects/x; do
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: ${SYNC_HOST}" -H "Authorization: Bearer stub-token" "http://127.0.0.1:${HOME_PORT}${P}")" == "404" ] \
		|| fail "the sync host answers ${P} (only /v1/shape/ belongs there)"
done
body "kanban.localhost:${HOME_PORT}" board-stub | grep -qF "<meta name=\"harness-sync-origin\" content=\"//kanban-sync.localhost:${HOME_PORT}\">" \
	|| fail "the board page lacks the live-sync meta: $(body "kanban.localhost:${HOME_PORT}" | head -c 300)"
body "vk-runner.localhost:${HOME_PORT}" runner-stub > ${D}/runner-sync-page.html || fail "the runner page through the proxy did not answer for the live-sync meta check"
grep -q 'harness-sync-origin' ${D}/runner-sync-page.html && fail "the runner page carries the board's live-sync meta"
# the board server answers any Origin with credentials allowed; the board route drops both headers
curl -s -D - -o /dev/null --max-time 5 -H "Origin: https://evil.example" "http://127.0.0.1:${BOARD_PORT}/v1/health" \
	| grep -qi '^access-control-allow-origin: https://evil.example' || fail "control: the stub board does not answer CORS as the board server does"
HDRS=$(curl -s -D - -o /dev/null --max-time 5 -H "Host: kanban.localhost:${HOME_PORT}" -H "Origin: https://evil.example" "http://127.0.0.1:${HOME_PORT}/v1/health")
echo "${HDRS}" | grep -qi '^access-control-allow-' && fail "the board route passes the board server's CORS headers on: $(echo "${HDRS}" | grep -i '^access-control')"
# with a dead proxy in its environment (port 9, nothing listens): the helper must reach the board directly
KANBAN_BOARD_URL=http://127.0.0.1:${BOARD_PORT} KANBAN_AUTH_FILE=${D}/kanban.env KANBAN_PROJECT=test18 UI_PORT_KANBAN_SIGNIN=${SIGNIN_PORT} \
	http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 no_proxy='' NO_PROXY='' \
	setsid nohup python3 "${AGENT_DIR}/kanban-signin.py" > ${D}/signin.log 2>&1 &
echo $! > ${D}/signin.pid
for _ in $(seq 1 25); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${SIGNIN_PORT}/healthz" && break; sleep 0.2; done
# signin <host header> <out file> [<curl option>...] - the sign-in through the proxy, as the home page's tile
# click sends it (Referer: the home page on this port) unless options are given; prints the HTTP code
signin()
{
	SH=$1
	SO=$2
	shift 2
	[ $# -eq 0 ] && set -- -H "Referer: http://localhost:${HOME_PORT}/"
	curl -s -D ${D}/signin.hdr -o "${SO}" -w '%{http_code}' --max-time 10 -H "Host: ${SH}" "$@" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in"
}
HTTP=$(signin "kanban.localhost:${HOME_PORT}" ${D}/signin.html)
[ "${HTTP}" == "200" ] || fail "the sign-in through the proxy answered ${HTTP}: $(cat ${D}/signin.html ${D}/signin.log)"
grep -qF 'indexedDB.open("rf-auth", 1)' ${D}/signin.html || fail "the sign-in page does not store the session where the board app reads it"
grep -qF '"access_token": "stub-token"' ${D}/signin.html || fail "the sign-in page does not carry the board session"
grep -qF 'var target = "/";' ${D}/signin.html || fail "before the project exists the sign-in does not land on the board's start page"
grep -qF 'Opening the Goals board' ${D}/signin.html || fail "the sign-in page is not the loading page"
grep -qF "take up to half a minute" ${D}/signin.html || fail "the loading page does not say what a first load costs"
grep -qF "<a class=\"home\" href=\"//localhost:${HOME_PORT}/\">Harness home</a>" ${D}/signin.html || fail "the loading page has no Harness home link for this host: $(grep -o 'href="[^"]*"' ${D}/signin.html | tr '\n' ' ')"
grep -qiF 'cache-control: no-store' ${D}/signin.hdr || fail "the sign-in page may be cached"
grep -qF "${PASSWORD}" ${D}/signin.html && fail "the sign-in page carries the password"
grep -qi '^x-frame-options: deny' ${D}/signin.hdr || fail "the sign-in page may be framed (no X-Frame-Options DENY)"
grep -qi "^content-security-policy: frame-ancestors 'none'" ${D}/signin.hdr || fail "the sign-in page may be framed (no frame-ancestors 'none')"
# only a request from the home page on this port signs in (another site's page could frame a signed-in board, or
# sign the browser in): no Origin or Referer, another site's, the home page on another port, an opaque origin. A foreign
# Origin (and null) is refused before the sign-in runs, by the proxy's same-origin gate (test-origin-gate.sh), with a 403
# that may not be framed: a browser sends Origin on a script's request or a form post, not on a person's click
for HDR in "Referer:" "Referer: https://evil.example/" "Origin: https://evil.example" "Referer: http://localhost:1/" \
	"Referer: http://localhost.evil.example:${HOME_PORT}/" "Origin: null"; do
	HTTP=$(signin "kanban.localhost:${HOME_PORT}" ${D}/signin-x.html -H "${HDR}")
	[ "${HTTP}" == "403" ] || fail "a sign-in that did not come from the home page answered ${HTTP} (${HDR})"
	grep -qF stub-token ${D}/signin-x.html && fail "a sign-in that did not come from the home page got the board session (${HDR})"
	case "${HDR}" in Origin:*)
		{ grep -qi '^x-frame-options: deny' ${D}/signin.hdr && grep -qi "^content-security-policy: frame-ancestors 'none'" ${D}/signin.hdr; } \
			|| fail "the gate's refusal of a sign-in may be framed (${HDR})"
		continue ;;
	esac
	# the sign-in's own refusal is a page a person can act on (a bookmark showed raw text), still a 403
	grep -qF "Open the Goals board from the harness home page" ${D}/signin-x.html || fail "the refusal is not the styled page (${HDR}): $(head -c 160 ${D}/signin-x.html)"
	grep -qF "<a class=\"home\" href=\"//localhost:${HOME_PORT}/\">Harness home</a>" ${D}/signin-x.html || fail "the refusal page has no Harness home link (${HDR})"
done
# never half a session: a board answer without a refresh token is refused
touch ${D}/no-refresh
HTTP=$(signin "kanban.localhost:${HOME_PORT}" ${D}/signin-norefresh.html)
rm -f "${D:?}/no-refresh"
# (the helper's own 502 names the reason; nginx answers a bare 502 when the helper drops the connection instead)
if [ "${HTTP}" != "502" ] || ! grep -qF "without a refresh token" ${D}/signin-norefresh.html; then
	fail "a board sign-in without a refresh token was not refused by the helper: ${HTTP} $(head -c 200 ${D}/signin-norefresh.html)"
fi
grep -qF stub-token ${D}/signin-norefresh.html && fail "half a board session reached the page"
# an unreadable login file is a 503 that says so, not a dropped connection
cp ${D}/kanban.env ${D}/kanban.env.ok
printf 'SELF_HOST_LOCAL_AUTH_EMAIL=\377\376\n' > ${D}/kanban.env
HTTP=$(signin "kanban.localhost:${HOME_PORT}" ${D}/signin-bad.html)
mv -f "${D:?}/kanban.env.ok" "${D:?}/kanban.env"
if [ "${HTTP}" != "503" ] || ! grep -qF "unreadable" ${D}/signin-bad.html; then
	fail "an unreadable login file did not answer 503: ${HTTP} $(cat ${D}/signin-bad.html)"
fi
HTTP=$(signin "evil.example:${HOME_PORT}" ${D}/signin-evil.html)
if [ "${HTTP}" == "200" ] || grep -qF stub-token ${D}/signin-evil.html; then
	fail "a foreign Host got the sign-in through the proxy (http=${HTTP})"
fi
# the Host check on its own: the home page's Referer on the same port passes the origin check, so only the Host can
# refuse this one
HTTP=$(curl -s -o ${D}/signin-direct.txt -w '%{http_code}' --max-time 5 -H "Host: evil.example:${HOME_PORT}" \
	-H "Referer: http://localhost:${HOME_PORT}/" "http://127.0.0.1:${SIGNIN_PORT}/__harness/sign-in")
if [ "${HTTP}" != "403" ] || ! grep -qF "answers only on kanban.localhost" ${D}/signin-direct.txt; then
	fail "the sign-in helper did not refuse a foreign Host (http=${HTTP}): $(cat ${D}/signin-direct.txt)"
fi
# the board's redirects stay on kanban.localhost, on the browser's port: a relative Location and the board's own
# absolute URL are re-hosted, a foreign site's is left as sent (location_of <Location the stub board answers>)
location_of()
{
	curl -s -o /dev/null -D - --max-time 5 -H "Host: kanban.localhost:${HOME_PORT}" "http://127.0.0.1:${HOME_PORT}/__redirect?to=$1" \
		| tr -d '\r' | sed -n 's/^[Ll]ocation: //p'
}
L=$(location_of /projects/p1)
[ "${L}" == "http://kanban.localhost:${HOME_PORT}/projects/p1" ] || fail "a relative redirect of the board did not stay on kanban.localhost: Location [${L}]"
L=$(location_of "http://127.0.0.1:${BOARD_PORT}/projects/p2")
[ "${L}" == "http://kanban.localhost:${HOME_PORT}/projects/p2" ] || fail "the board's own URL in a redirect was not re-hosted on kanban.localhost: Location [${L}]"
L=$(location_of "https://github.com/login")
[ "${L}" == "https://github.com/login" ] || fail "a redirect to another site was rewritten: Location [${L}]"
# probe <name> - the HTTP code of the home page's same-origin status probe for that tile
probe()
{
	curl -s -o ${D}/probe.out -w '%{http_code}' --max-time 10 "http://127.0.0.1:${HOME_PORT}/__probe/$1"
}
HTTP=$(probe kanban)
[ "${HTTP}" == "204" ] || fail "the Goals board probe answered ${HTTP} with the board and its database up: $(cat ${D}/probe.out)"
[ -s ${D}/probe.out ] && fail "the Goals board probe is not status-only: it answered a body ($(head -c 80 ${D}/probe.out))"
touch ${D}/fail-db
HTTP=$(probe kanban)
rm -f "${D:?}/fail-db"
[ "${HTTP}" == "500" ] || fail "with the board's database failing, the Goals board probe answered ${HTTP}, not 500: $(cat ${D}/probe.out)"
[ "$(probe kanban)" == "204" ] || fail "the Goals board probe did not recover with the database back"
[ "$(probe vk-runner)" == "204" ] || fail "the runner probe does not answer 204 with the runner up"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "http://127.0.0.1:${HOME_PORT}/__probe/kanban")
[ "${HTTP}" == "403" ] || fail "the Goals board probe is not GET-only: a POST answered ${HTTP}"
# a board that accepts and never answers: every probe still answers within seconds, and five at once (several home
# tabs) do not queue up behind each other
touch ${D}/hang-db
T0=$(date +%s)
HANG_PIDS=""
for i in 1 2 3 4 5; do
	curl -s -o /dev/null -w '%{http_code}' --max-time 40 "http://127.0.0.1:${HOME_PORT}/__probe/kanban" > ${D}/probe-hang-${i}.code &
	HANG_PIDS="${HANG_PIDS} $!"
done
# shellcheck disable=SC2086 # the pids, one word each
wait ${HANG_PIDS}
T1=$(date +%s)
rm -f "${D:?}/hang-db"
CODES=$(for i in 1 2 3 4 5; do printf '%s ' "$(cat ${D}/probe-hang-${i}.code)"; done)
for i in 1 2 3 4 5; do
	grep -qE '^500$' ${D}/probe-hang-${i}.code || fail "a status probe of a hanging board answered $(cat ${D}/probe-hang-${i}.code) (all: ${CODES})"
done
[ $(( T1 - T0 )) -le 9 ] || fail "five status probes of a hanging board took $(( T1 - T0 )) s (codes ${CODES}): unbounded, they queue up"
grep -rqF "stub-token" ${D}/probe.out && fail "a probe answer carries the board session"
kill "$(cat ${D}/board.pid)" 2>/dev/null
sleep 1
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: kanban.localhost" "http://127.0.0.1:${HOME_PORT}/")
[ "${HTTP}" == "502" ] || fail "a stopped board does not answer 502 through the proxy (http=${HTTP})"
HTTP=$(probe kanban)
[ "${HTTP}" == "500" ] || fail "with the board stopped, the Goals board probe answered ${HTTP}, not 500"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${HOME_PORT}/")
[ "${HTTP}" == "200" ] || fail "the home page went down with the board (http=${HTTP})"
kill "$(cat ${D}/nginx.pid)" "$(cat ${D}/runner.pid)" 2>/dev/null
echo "ok 3 - through the proxy: kanban.localhost -> board, vk-runner.localhost -> runner, both with exactly the own-origin CSP header, the board without the board server's CORS headers; home badge on both; board redirects kept on kanban.localhost; status-only GET-only probes: board 204, 500 with its database failing or the board stopped, bounded with a board that hangs, runner 204; sign-in page (IndexedDB session, no password, no-store, not framable, only from the home page, never half a session, never through an environment proxy), foreign Host refused (403); board stopped -> 502 on its route only, home still 200; /workspaces and everything under it on the board host are a 302 to the runner's host with the path and query kept (control: without the rule the board's page, the crash, answers there); live-sync origin through the proxy: a shape read from the board's origin carries exactly the contract's CORS (no credentials, the five Electric headers exposed and passed, Vary Origin beside the server's own), a foreign Origin gets none, the preflight is a 204 from nginx that never reaches the board, 404 elsewhere on that host, the board page carries the sync meta on the browser's port and the runner page does not"

# --- 4. kanban-sync.py against the stub API ---
start_board
export KANBAN_BOARD_URL=http://127.0.0.1:${BOARD_PORT} KANBAN_AUTH_FILE=${D}/kanban.env KANBAN_PROJECT=test18
export AUTONOMY_LOOP_DIR=${D}/loop AUTONOMY_LOOP_GOALS=${D}/loop/GOALS.md
unset KANBAN_CARD_ORDER  # the default order below; a live container's environment may carry the setting
mkdir -p ${D}/loop
cat > ${AUTONOMY_LOOP_GOALS} << 'EOF'
# Goals
Mark an item done by changing its `- [ ]` to `- [x]`.

```
- [ ] an example inside a code fence, not a goal
```

## Goal 1 - write the hello file
Create /tmp/kanban-smoke/hello.txt.
DONE when: the file exists.

## Goals from Slack

- [x] an already finished goal
- [ ] open goal B
EOF
OUT=$(${SYNC} sync 2>&1) || fail "sync: ${OUT}"
[ "$(state_count projects)" == "1" ] || fail "sync did not create exactly one project: ${OUT}"
[ "$(state_count issues)" == "3" ] || fail "sync did not create exactly 3 cards (2 open, 1 done; the fenced example is no goal): ${OUT}"
[ "$(status_of 'an already finished goal')" == "Done" ] || fail "a checked goal is not in Done"
[ "$(status_of 'Goal 1 - write the hello file')" == "To do" ] || fail "a heading goal is not in To do"
# the order within a column: the board sorts a column by each card's sort_order, ascending (the smallest on top), and the
# mirror sets it to minus the time the goal first reached the board (KANBAN_CARD_ORDER=newest-first, the default; goals
# first seen in the same sync keep the file's order among them) - the newest goal is on top of its column, Done included,
# and the time is kept in the state file, so the values survive a switch and back; KANBAN_CARD_ORDER=file is the file's
# order (the oldest on top: 1.0, 2.0, 3.0) and the switch PATCHes every card; an empty value is the default; a bad value
# is a bad setting: exit 4, the two values named, nothing touched. An upgraded board (the file-order values of the earlier
# mirror, a state without the times) is re-sorted by the cards' creation times on the board at the first sync, and the
# sync after it (the idempotence check below) changes nothing
sort_order_of()
{
	curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | GOAL="$1" python3 -c '
import json, os, sys
hits = [i.get("sort_order") for i in json.load(sys.stdin)["issues"].values() if i["title"] == os.environ["GOAL"]]
print(hits[0] if len(hits) == 1 else "cards=%d" % len(hits))'
}
# orders - the sort_order of the three cards in FILE order: Goal 1, the finished goal (in Done), open goal B
orders() { echo "$(sort_order_of 'Goal 1 - write the hello file') $(sort_order_of 'an already finished goal') $(sort_order_of 'open goal B')"; }
# board_order - the titles of the cards top to bottom (sort_order ascending, the board's Manual sort), |-joined
board_order()
{
	curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c '
import json, sys
print("|".join(i["title"] for i in sorted(json.load(sys.stdin)["issues"].values(), key=lambda i: i["sort_order"])))'
}
# minus_times - every sort_order is minus a time within a day of now (the scheme, not just the order)
minus_times()
{
	curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c '
import json, sys, time
now = time.time()
sys.exit(0 if all(-(now + 86400) < i["sort_order"] < -(now - 86400) for i in json.load(sys.stdin)["issues"].values()) else 1)'
}
NEWEST="open goal B|an already finished goal|Goal 1 - write the hello file"
[ "$(board_order)" == "${NEWEST}" ] || fail "the cards are not newest on top (the goal that reached the board last first, Done included; expected ${NEWEST}): $(board_order)"
minus_times || fail "the sort_order values are not minus the time the goals reached the board: $(orders)"
VALS0=$(orders)
CALLS_ORDER=$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "import json, sys; print(len(json.load(sys.stdin)['calls']))")
OUTO=$(KANBAN_CARD_ORDER=file ${SYNC} sync 2>&1) || fail "sync with KANBAN_CARD_ORDER=file: ${OUTO}"
[ "$(orders)" == "1.0 2.0 3.0" ] || fail "KANBAN_CARD_ORDER=file does not give the file's order (the oldest on top, expected 1.0 2.0 3.0): $(orders)"
# all_patched <calls index> - every card of the board was PATCHed since that index
all_patched()
{
	curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | N="$1" python3 -c "
import json, os, sys
s = json.load(sys.stdin)
patched = {c.rsplit('/', 1)[-1] for c in s['calls'][int(os.environ['N']):] if c.startswith('PATCH /v1/issues/')}
sys.exit(0 if patched == set(s['issues']) else 1)"
}
all_patched "${CALLS_ORDER}" || fail "the switch to KANBAN_CARD_ORDER=file did not PATCH every card (a running board picks a changed setting up at the first sync after its restart)"
OUTO=$(KANBAN_CARD_ORDER=newest-first ${SYNC} sync 2>&1) || fail "sync with KANBAN_CARD_ORDER=newest-first: ${OUTO}"
[ "$(board_order)" == "${NEWEST}" ] || fail "KANBAN_CARD_ORDER=newest-first, the default named, does not give newest on top back: $(board_order)"
[ "$(orders)" == "${VALS0}" ] || fail "the times kept in the state file did not give the same values back after the switch (${VALS0} -> $(orders))"
OUTO=$(KANBAN_CARD_ORDER= ${SYNC} sync 2>&1) || fail "sync with an empty KANBAN_CARD_ORDER: ${OUTO}"
[ "$(orders)" == "${VALS0}" ] || fail "an empty KANBAN_CARD_ORDER is not the default: $(orders)"
OUTO=$(KANBAN_CARD_ORDER=oldest-first ${SYNC} sync 2>&1); RCO=$?
[ "${RCO}" -eq 4 ] || fail "a bad KANBAN_CARD_ORDER exited ${RCO}, expected 4 (bad settings): ${OUTO}"
echo "${OUTO}" | grep -q "KANBAN_CARD_ORDER must be newest-first .* or file" || fail "the bad-setting message does not name KANBAN_CARD_ORDER and its two values: ${OUTO}"
[ "$(orders)" == "${VALS0}" ] || fail "a bad KANBAN_CARD_ORDER changed the board: $(orders)"
# the upgrade: the earlier mirror's values (the file's order) and a state that knows no times
OUTO=$(KANBAN_CARD_ORDER=file ${SYNC} sync 2>&1) || fail "test setup (upgrade): ${OUTO}"
python3 - "${AUTONOMY_LOOP_DIR}/kanban-sync.state" << 'PY' || fail "test setup (upgrade): could not strip the times from the state file"
import json, sys
p = sys.argv[1]
s = json.load(open(p))
for m in s.get("mirrored", {}).values():
    m.pop("since", None)
json.dump(s, open(p, "w"))
PY
[ "$(orders)" == "1.0 2.0 3.0" ] || fail "test setup (upgrade): the cards do not carry the earlier mirror's values: $(orders)"
CALLS_ORDER=$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "import json, sys; print(len(json.load(sys.stdin)['calls']))")
OUTO=$(${SYNC} sync 2>&1) || fail "the first sync after the upgrade: ${OUTO}"
[ "$(board_order)" == "${NEWEST}" ] || fail "the first sync after the upgrade did not re-sort the cards by their creation time on the board (expected ${NEWEST}): $(board_order)"
minus_times || fail "after the upgrade the values are not minus the cards' creation times: $(orders)"
all_patched "${CALLS_ORDER}" || fail "the first sync after the upgrade did not PATCH every card"
# org_name - the name of the login's organization on the stub board
org_name()
{
	curl -s -H "Authorization: Bearer stub-token" "http://127.0.0.1:${BOARD_PORT}/v1/organizations" \
		| python3 -c 'import json, sys; print(json.load(sys.stdin)["organizations"][0]["name"])'
}
[ "$(org_name)" == "test18" ] || fail "sync did not name the board's default personal organization after the project: $(org_name)"
echo "${OUT}" | grep -q "organization named after the project" || fail "sync does not say it named the organization: ${OUT}"
CALLS=$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['calls']))")
OUT2=$(${SYNC} sync 2>&1) || fail "second sync: ${OUT2}"
echo "${OUT2}" | grep -q "3 card(s), 0 created, 0 moved" || fail "a second sync is not idempotent: ${OUT2}"
[ "$(state_count issues)" == "3" ] || fail "a second sync duplicated cards"
# a proxy from the environment is never used for the board (the container has http_proxy from .env)
OUT=$(env http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 no_proxy='' NO_PROXY='' "${SYNC}" sync 2>&1) \
	|| fail "with a dead proxy in the environment the sync failed - it went through the proxy: ${OUT}"
curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "
import json, sys
calls = json.load(sys.stdin)['calls'][${CALLS}:]
sys.exit(1 if any(c.startswith('PATCH') for c in calls) else 0)" || fail "a second sync rewrote unchanged cards"
# a name someone gave the organization stays
curl -s -o /dev/null -X PATCH -H "Authorization: Bearer stub-token" -H "Content-Type: application/json" -d '{"name": "Team X"}' \
	"http://127.0.0.1:${BOARD_PORT}/v1/organizations/00000000-0000-0000-0000-00000000000a"
${SYNC} sync > /dev/null 2>&1
[ "$(org_name)" == "Team X" ] || fail "sync renamed an organization someone had named: $(org_name)"
OUT=$(${SYNC} fire-start --fire 1 --started 1000 2>&1) || fail "fire-start: ${OUT}"
[ "$(status_of 'Goal 1 - write the hello file')" == "In progress" ] || fail "fire-start did not move the first open goal to In progress: ${OUT}"
[ "$(status_of 'open goal B')" == "To do" ] || fail "fire-start moved a goal it does not work on"
echo "transcript line one" > ${D}/fire-1.out
echo "the fire's final words" >> ${D}/fire-1.out
OUT=$(${SYNC} fire-end --fire 1 --started 1000 --rc 0 --duration 7 --out ${D}/fire-1.out 2>&1) || fail "fire-end: ${OUT}"
[ "$(status_of 'Goal 1 - write the hello file')" == "In review" ] || fail "fire-end did not move a still-open goal to In review: ${OUT}"
[ "$(state_count comments)" == "1" ] || fail "fire-end did not post exactly one comment"
curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "
import json, sys
m = list(json.load(sys.stdin)['comments'].values())[0]['message']
sys.exit(0 if 'rc=0' in m and \"the fire's final words\" in m and '7s' in m else 1)" || fail "the comment lacks the rc, the duration or the transcript"
description_of()
{
	curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | GOAL="$1" python3 -c '
import json, os, sys
print([i["description"] for i in json.load(sys.stdin)["issues"].values() if i["title"] == os.environ["GOAL"]][0])'
}
description_of 'Goal 1 - write the hello file' | grep -qF '**Last fire:** fire 1 ended rc=0 after 7s - the goal is still open: In review. transcript line one' \
	|| fail "the card description lacks the last-fire note: $(description_of 'Goal 1 - write the hello file')"
${SYNC} fire-end --fire 1 --started 1000 --rc 0 --duration 7 --out ${D}/fire-1.out > /dev/null 2>&1
[ "$(state_count comments)" == "1" ] || fail "a repeated fire-end posted a second comment"
${SYNC} sync > /dev/null 2>&1
description_of 'Goal 1 - write the hello file' | grep -qF '**Last fire:** fire 1' || fail "a later sync dropped the last-fire note"
grep -rqF "${PASSWORD}" ${D}/loop/kanban-sync.state 2>/dev/null && fail "the password reached the state file"
echo "${OUT}" | grep -qF "${PASSWORD}" && fail "the password is in kanban-sync.py output"
PID15=$(python3 -c 'import uuid; ns = uuid.UUID("403ef658-05ce-59aa-97e8-8aea9ecc4f02"); print(uuid.uuid5(ns, "project:test18"))')
curl -s --max-time 10 -H "Host: kanban.localhost:${HOME_PORT}" -H "Referer: http://localhost:${HOME_PORT}/" "http://127.0.0.1:${SIGNIN_PORT}/__harness/sign-in" \
	| grep -qF "var target = \"/projects/${PID15}\";" \
	|| fail "once the project exists the sign-in does not land on it (/projects/${PID15})"
# a fire's transcript is masked before its first line and its end go on the board: the login file's password, the
# environment's secret-named values, the AWS credentials file's values, token shapes, NAME=value secrets, AWS's
# credentials forms (the credentials file's lines, the CLI's JSON) and a bearer token; one value spans the start of
# the end that is posted (masked before the cut, so no half of it remains). AWS values: AWS's documented examples
PLANTED=test18-planted-env-token-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
mkdir -p ${D}/aws
# The planted values are assembled at run time ("AKIA""..."), so no credential-shaped string is in this file: e2e.sh
# refuses to upload a tree that holds one, and the values the test feeds the code under test are unchanged.
printf '[user1]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "AKIA""I44QH8DHBEXAMPLE" "je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY" \
	> ${D}/aws/credentials
python3 - "${D}/fire-9.out" "${PASSWORD}" "${PLANTED}" << 'PY' || fail "test setup: the planted transcript"
import sys
out, password, planted = sys.argv[1:4]
head = f"first line with the password {password} and xo" "xb-123456789012-abcdefghijklmnop\n"
# everything below lies inside the end that is posted
end = (" the end of fire 9 \n"
       "aws AKIA" "ABCDEFGHIJKLMNOP jwt eyJhbGciOiJIUzI1NiJ9." "eyJzdWIiOiJ0ZXN0MTUifQ." "c2lnbmF0dXJldGVzdDE1"
       " MY_API_KEY=test18-assigned-secret\n"
       "aws_secret_access_key = " "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"
       '{"Version": 1, "AccessKeyId": "ASIA' 'IOSFODNN7EXAMPLE", "SecretAccessKey": ' '"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", '
       '"SessionToken": "IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZVERYLONGSTRINGEXAMPLE"}\n'
       "the profile's key is je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY\n"
       "Authorization: Bearer test18opaque0123456789abcdefEXAMPLE\n"
       # aws sts ... --output text, a session token alone (--query ... --output text), botocore's credentials repr
       "CREDENTIALS\tASIA" "IOSFODNN7EXAMPLE\t2026-10-13T20:00:00+00:00\ttest18+sts+text+secret+0123456EXAMPLEKEY"
       "\tFwoGZXIvYXdzEtest18stsTextSessionToken0123456789EXAMPLE\n"
       "IQoJb3JpZ2luX2VjEtest18bareSessionToken0123456789abcdefEXAMPLE\n"
       '{"type": "tool_result", "content": "ok\\nIQoJb3JpZ2luX2VjEtest18escapedToken0123456789abcdefEXAMPLE"}\n'
       "ReadOnlyCredentials(access_key='ASIA" "IOSFODNN7EXAMPLE', secret_key='test18/readonly/creds/secret0123EXAMPLEKEY',"
       " token='AQoDYXdzEtest18ReadOnlyToken0123456789abcdefEXAMPLE')\n"
       # token counts in strings stay readable; an all-digit password does not
       '{"max_tokens": "4096", "token_count": "1234", "password": "4815162342"}\n')
assert len(end) <= 1480, len(end)  # all of it inside the posted end
end += "x" * (1500 - 20 - len(end))  # the posted end starts 20 characters before the planted value ends
open(out, "w").write(head + "env " + planted + end + "\n")
PY
OUT=$(TEST18_PLANTED_TOKEN=${PLANTED} AWS_SHARED_CREDENTIALS_FILE=${D}/aws/credentials ${SYNC} fire-end --fire 9 --started 9000 \
	--rc 0 --duration 3 --out ${D}/fire-9.out 2>&1) || fail "fire-end with secrets in its transcript: ${OUT}"
curl -s "http://127.0.0.1:${BOARD_PORT}/__state" > ${D}/state-9.json
N=0
for S in "${PASSWORD}" "${PLANTED}" "${PLANTED: -20}" "xo""xb-123456789012-abcdefghijklmnop" "AKIA""ABCDEFGHIJKLMNOP" \
	"eyJhbGciOiJIUzI1NiJ9.""eyJzdWIiOiJ0ZXN0MTUifQ.""c2lnbmF0dXJldGVzdDE1" test18-assigned-secret \
	wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZVERYLONGSTRINGEXAMPLE \
	je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY test18opaque0123456789abcdefEXAMPLE \
	test18+sts+text+secret+0123456EXAMPLEKEY FwoGZXIvYXdzEtest18stsTextSessionToken0123456789EXAMPLE \
	IQoJb3JpZ2luX2VjEtest18bareSessionToken0123456789abcdefEXAMPLE test18/readonly/creds/secret0123EXAMPLEKEY \
	AQoDYXdzEtest18ReadOnlyToken0123456789abcdefEXAMPLE 4815162342 \
	IQoJb3JpZ2luX2VjEtest18escapedToken0123456789abcdefEXAMPLE; do
	N=$(( N + 1 ))
	grep -qF -- "${S}" ${D}/state-9.json && fail "planted secret ${N} of the fire's transcript reached the board"
done
grep -qF '"SecretAccessKey\": \"[redacted]\"' ${D}/state-9.json || fail "the CLI's credentials JSON did not reach the board masked"
for S in '"max_tokens\": \"4096\"' '"token_count\": \"1234\"'; do
	grep -qF -- "${S}" ${D}/state-9.json || fail "a token count in a string was masked: ${S} is not on the board"
done
grep -qF "the end of fire 9" ${D}/state-9.json || fail "the masked end of the transcript did not reach the board"
grep -qF "first line with the password [redacted]" ${D}/state-9.json || fail "the masked first line is not the card's last-fire note"
echo "ok 4 - sync: 3 cards, newest on top (KANBAN_CARD_ORDER: minus the time a goal reached the board, every column, Done included, kept across a switch and an upgrade; file gives the old order; a bad value exits 4), idempotent, never through an environment proxy, the default org named after the project (a chosen name kept); fire-start: In progress; fire-end: In review, one comment (rc, duration, transcript) and a last-fire note that a later sync keeps; the sign-in lands on the project; a transcript's secrets are masked before they reach the board"

# --- 5. the loop hooks (loop-once.sh, a stub claude) ---
cat > ${D}/fakeclaude << 'STUB'
#!/bin/bash
# stub claude: keep the prompt, record the board while "working", then edit the goals file as FAKE_ACTION says -
# check:<item> ticks a checkbox item, heading:<heading> adds [x] to a "## Goal" heading (docs/loop/GOALS.md.example),
# rename:<old>=><new> renames a heading
cat > "${FAKE_PROMPT_OUT:-/dev/null}"
curl -s "http://127.0.0.1:${BOARD_PORT}/__state" > "${FAKE_STATE_OUT:-/dev/null}"
case "${FAKE_ACTION}" in
check:*) G=${FAKE_ACTION#check:}; sed -i "s/^- \[ \] ${G}\$/- [x] ${G}/" "${AUTONOMY_LOOP_GOALS}" ;;
heading:*) G=${FAKE_ACTION#heading:}; sed -i "s/^## ${G}\$/## ${G} [x]/" "${AUTONOMY_LOOP_GOALS}" ;;
rename:*) R=${FAKE_ACTION#rename:}; sed -i "s/^## ${R%%=>*}\$/## ${R#*=>}/" "${AUTONOMY_LOOP_GOALS}" ;;
esac
echo "stub fire result: ${FAKE_ACTION}"
STUB
chmod +x ${D}/fakeclaude
export BOARD_PORT
# once <log> [env assignments ...] - one loop-once.sh fire with the stub claude
once()
{
	OUTF=$1
	shift
	env SLACK_WATCH_ENABLED=false SLACK_CHAT_ENABLED=false AUTONOMY_LOOP_WORKDIR=${D}/loop CLAUDE_BIN=${D}/fakeclaude "$@" \
		"${AGENT_DIR}/loop-once.sh" > "${OUTF}" 2>&1
}
# comment_on <goal title> <text> - 0 when a comment containing <text> is on that goal's card
comment_on()
{
	curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | GOAL="$1" WANT="$2" python3 -c '
import json, os, sys
s = json.load(sys.stdin)
ids = [i["id"] for i in s["issues"].values() if i["title"] == os.environ["GOAL"]]
sys.exit(0 if any(m["issue_id"] in ids and os.environ["WANT"] in m["message"] for m in s["comments"].values()) else 1)'
}
# goal 1 done by hand, so the fire works on "open goal B"
sed -i 's/^## Goal 1 - write the hello file$/## [x] Goal 1 - write the hello file/' ${AUTONOMY_LOOP_GOALS}
once ${D}/once1.out FAKE_ACTION="check:open goal B" FAKE_PROMPT_OUT=${D}/prompt1.txt FAKE_STATE_OUT=${D}/during-fire.json \
	|| fail "loop-once (board up) exited non-zero: $(cat ${D}/once1.out)"
# shellcheck disable=SC2016 # the backquotes are the prompt's own, not a command substitution
grep -qF 'mark it done in the goals file: `- [x]`, or `[x]` in its `## Goal` heading.' ${D}/prompt1.txt \
	|| fail "the fire prompt does not say how a goal is marked done: $(cat ${D}/prompt1.txt)"
python3 - "${D}/during-fire.json" << 'EOF' || fail "the card was not In progress while the fire ran"
import json, sys
s = json.load(open(sys.argv[1]))
names = {st["id"]: st["name"] for sts in s["statuses"].values() for st in sts}
sys.exit(0 if [names[i["status_id"]] for i in s["issues"].values() if i["title"] == "open goal B"] == ["In progress"] else 1)
EOF
[ "$(status_of 'open goal B')" == "Done" ] || fail "the card did not move to Done after the fire checked the goal off"
[ "$(status_of 'Goal 1 - write the hello file')" == "Done" ] || fail "a heading marked [x] is not in Done"
grep -q "FIRE 1 KANBAN fire 1 start: 'open goal B' -> In progress" ${D}/loop/loop.log || fail "loop.log lacks the fire-start KANBAN line: $(cat ${D}/loop/loop.log)"
grep -q "FIRE 1 KANBAN fire 1 end: 'open goal B' -> Done" ${D}/loop/loop.log || fail "loop.log lacks the fire-end KANBAN line: $(cat ${D}/loop/loop.log)"
[ "$(grep -c ' END rc=' ${D}/loop/loop.log)" == "1" ] || fail "the KANBAN lines changed the loop's fire count"
# the board is DOWN: the fire must not notice
sed -i 's/^- \[x\] open goal B$/- [ ] open goal B/' ${AUTONOMY_LOOP_GOALS}
once ${D}/once2.out FAKE_ACTION="check:open goal B" KANBAN_BOARD_URL=http://127.0.0.1:${DEAD_PORT} \
	|| fail "a board outage failed the fire: $(cat ${D}/once2.out)"
grep -q "FIRE 2 END rc=0" ${D}/loop/loop.log || fail "the fire with the board down did not end rc=0"
grep -q "FIRE 2 KANBAN fire-start not mirrored (rc=2" ${D}/loop/loop.log || fail "loop.log does not say fire-start was not mirrored: $(tail -5 ${D}/loop/loop.log)"
grep -q "FIRE 2 KANBAN fire-end not mirrored (rc=2" ${D}/loop/loop.log || fail "loop.log does not say fire-end was not mirrored"
# no KANBAN_BOARD_URL: no KANBAN line, no board call (the pre-board loop)
sed -i 's/^- \[x\] open goal B$/- [ ] open goal B/' ${AUTONOMY_LOOP_GOALS}
CALLS=$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['calls']))")
once ${D}/once3.out FAKE_ACTION="check:open goal B" KANBAN_BOARD_URL='' || fail "loop-once without a board exited non-zero"
grep -q "FIRE 3 KANBAN" ${D}/loop/loop.log && fail "a KANBAN line was logged without KANBAN_BOARD_URL"
[ "$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['calls']))")" == "${CALLS}" ] \
	|| fail "the board was called without KANBAN_BOARD_URL"
grep -rqF "${PASSWORD}" ${D}/loop/loop.log ${D}/loop/kanban-sync.log ${D}/once1.out ${D}/once2.out 2>/dev/null && fail "the password reached a loop log"
# "## Goal" headings, the way docs/loop/GOALS.md.example writes them
cat > ${AUTONOMY_LOOP_GOALS} << 'GOALS'
# Example goals

## Goal 1 - hello file

Create /wd/demo/hello.md containing exactly one line.

DONE when: /wd/demo/hello.md exists with that single line.

## Goal 2 - workspace inventory

Write /wd/demo/inventory.md listing /wd.

DONE when: /wd/demo/inventory.md lists the contents of /wd.

## Goal 3 - closing note

Write /wd/demo/closing.md.

## Completion

When the goals above meet their DONE conditions, create the stop flag.
GOALS
once ${D}/once4.out FAKE_ACTION="heading:Goal 1 - hello file" || fail "loop-once (heading goal) exited non-zero: $(cat ${D}/once4.out)"
[ "$(status_of 'Goal 1 - hello file')" == "Done" ] || fail "a heading the fire marked [x] is not in Done: $(status_of 'Goal 1 - hello file')"
comment_on 'Goal 1 - hello file' '**Fire 4**' || fail "fire 4's result is not on the card of the heading goal it finished"
[ "$(status_of 'Goal 2 - workspace inventory')" == "To do" ] || fail "an untouched heading goal is not in To do"
[ "$(status_of 'Completion')" == "cards=0" ] || fail "the Completion section became a card"
# the fire starts on goal 2 (the first open goal) but finishes goal 3: credited to goal 3
once ${D}/once5.out FAKE_ACTION="heading:Goal 3 - closing note" || fail "loop-once (other goal) exited non-zero: $(cat ${D}/once5.out)"
[ "$(status_of 'Goal 3 - closing note')" == "Done" ] || fail "the goal the fire finished is not in Done"
comment_on 'Goal 3 - closing note' '**Fire 5**' || fail "fire 5's result is not on the card of the goal it finished"
comment_on 'Goal 2 - workspace inventory' '**Fire 5**' && fail "fire 5's result landed on the goal it started on, not the one it finished"
[ "$(status_of 'Goal 2 - workspace inventory')" == "To do" ] || fail "the goal the fire did not finish is not back in To do: $(status_of 'Goal 2 - workspace inventory')"
grep -q "FIRE 5 KANBAN fire 5 end: 'Goal 3 - closing note' -> Done" ${D}/loop/loop.log || fail "loop.log does not credit fire 5 to goal 3: $(grep 'FIRE 5 KANBAN' ${D}/loop/loop.log)"
# the fire renames the goal it started on: the old card goes to In review with a note, the new text gets a card
once ${D}/once6.out FAKE_ACTION="rename:Goal 2 - workspace inventory=>Goal 2 - workspace list" || fail "loop-once (rename) exited non-zero: $(cat ${D}/once6.out)"
[ "$(status_of 'Goal 2 - workspace inventory')" == "In review" ] || fail "the card of a renamed goal is not in In review: $(status_of 'Goal 2 - workspace inventory')"
comment_on 'Goal 2 - workspace inventory' 'its text is no longer in' || fail "the card of a renamed goal has no note"
[ "$(status_of 'Goal 2 - workspace list')" == "To do" ] || fail "the renamed goal has no card of its own in To do"
grep -q "FIRE 6 KANBAN fire 6 end: .*the card of the renamed or removed goal 'Goal 2 - workspace inventory' -> In review" ${D}/loop/loop.log \
	|| fail "loop.log does not report the renamed goal's card: $(grep 'FIRE 6 KANBAN' ${D}/loop/loop.log)"
grep -rqF "${PASSWORD}" ${D}/loop/loop.log ${D}/loop/kanban-sync.log ${D}/once4.out ${D}/once5.out ${D}/once6.out 2>/dev/null && fail "the password reached a loop log"
echo "ok 5 - loop-once: prompt says how to mark a goal done; In progress during the fire, Done after; board down -> rc=0 + 'not mirrored'; no board URL -> no KANBAN line; heading [x] -> Done + comment there; finished goal credited over the started one; renamed goal -> old card In review with a note"

# --- 6. refusals ---
sed "s/^SELF_HOST_LOCAL_AUTH_PASSWORD=.*/SELF_HOST_LOCAL_AUTH_PASSWORD=wrong/" ${D}/kanban.env > ${D}/wrong.env
OUT=$(KANBAN_AUTH_FILE=${D}/wrong.env ${SYNC} sync 2>&1)
[ $? -eq 3 ] || fail "a refused login does not exit 3: ${OUT}"
OUT=$(KANBAN_BOARD_URL=http://board.example.com ${SYNC} sync 2>&1)
[ $? -eq 4 ] || fail "a non-private board host does not exit 4: ${OUT}"
echo "${OUT}" | grep -q "refusing KANBAN_BOARD_URL host 'board.example.com'" || fail "the refusal does not name the host: ${OUT}"
OUT=$(KANBAN_BOARD_URL=http://kanban-server:8081 KANBAN_AUTH_FILE=${D}/missing.env ${SYNC} sync 2>&1)
[ $? -eq 4 ] || fail "a missing login file does not exit 4: ${OUT}"
touch ${D}/fail-login
OUT=$(${SYNC} sync 2>&1)
RC=$?
rm -f "${D:?}/fail-login"
[ ${RC} -eq 2 ] || fail "a login the board fails (5xx) does not exit 2: ${OUT}"
mkdir -p ${D}/goals-dir
OUT=$(AUTONOMY_LOOP_GOALS=${D}/goals-dir ${SYNC} sync 2>&1)
[ $? -eq 2 ] || fail "an unexpected error does not exit 2: ${OUT}"
echo "${OUT}" | grep -q "kanban-sync: unexpected" || fail "an unexpected error is not named: ${OUT}"
echo "ok 6 - refused login -> 3, failed login (5xx) -> 2, unexpected error -> 2, non-private host -> 4, missing login file -> 4"

# --- 7. the startup seed: ui-start.sh -> kanban-sync.py seed, on a fresh instance with no fire and no goals file ---
# a fresh stub board (it keeps its state in memory), down while the container "starts"; the sign-in helper comes
# from ui-start.sh this time
kill "$(cat ${D}/board.pid)" "$(cat ${D}/signin.pid)" 2>/dev/null
sleep 1
export KANBAN_PROJECT=test18-seed AUTONOMY_LOOP_DIR=${D}/seed AUTONOMY_LOOP_GOALS=${D}/seed/GOALS.md \
	AUTONOMY_LOOP_DEFAULT_GOALS=${AGENT_DIR}/goals-default.md
STANDING="Standing goal - handle the Slack inbox handed to this fire"
grep -qxF "## ${STANDING}" "${AUTONOMY_LOOP_DEFAULT_GOALS}" || fail "the shipped default goals have no '## ${STANDING}' heading"
mkdir -p ${D}/seed ${D}/ui-seed
# the agent runner is not this check's subject: a live pid whose command line names vibe-kanban, which ui-start.sh
# takes for a running runner (it leaves a live UI alone), so no real runner starts
bash -c 'exec -a vibe-kanban-stub sleep 900' > /dev/null 2>&1 &
echo $! > ${D}/ui-seed/vibe-kanban.pid
# the seed's exit status file of an earlier start, which must not count for this one
SEED_DONE=${D}/ui-seed/kanban-seed.done
echo earlier-start > ${SEED_DONE}
T0=$(date +%s)
UI_DIR=${D}/ui-seed UI_LISTEN_HOST=127.0.0.1 UI_HOME=false UI_FILES=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_TMUX=false \
	UI_TMUX_AGENT=false UI_VIBE_KANBAN=true UI_PORT_VIBE_KANBAN=${RUNNER_PORT} UI_PORT_KANBAN_SIGNIN=${SIGNIN_PORT} \
	KANBAN_SEED_WAIT=60 VIBE_KANBAN_DATA_HOME=${D}/vk-home-seed "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-seed.log 2>&1 \
	|| fail "ui-start.sh failed with the board down: $(cat ${D}/ui-start-seed.log)"
[ $(( $(date +%s) - T0 )) -le 10 ] || fail "ui-start.sh waited for the board (the seed must run in the background)"
grep -q "vibe-kanban: already running" ${D}/ui-start-seed.log || fail "ui-start.sh did not take the stub runner: $(cat ${D}/ui-start-seed.log)"
grep -q "kanban-seed: started" ${D}/ui-start-seed.log || fail "ui-start.sh did not start the board seed: $(cat ${D}/ui-start-seed.log)"
[ "$(cat ${SEED_DONE} 2>/dev/null)" == "earlier-start" ] && fail "ui-start.sh left an earlier start's ${SEED_DONE}"
sleep 3
[ -e ${SEED_DONE} ] && fail "the seed did not wait for the board (it ended, rc $(cat ${SEED_DONE})): $(cat ${D}/ui-seed/kanban-seed.log)"
start_board
for _ in $(seq 1 30); do [ -e ${SEED_DONE} ] && break; sleep 1; done
[ -e ${SEED_DONE} ] || fail "the seed did not finish within 30 s of the board coming up: $(cat ${D}/ui-seed/kanban-seed.log)"
[ "$(cat ${SEED_DONE})" == "0" ] || fail "the seed ended with rc $(cat ${SEED_DONE}), not 0: $(cat ${D}/ui-seed/kanban-seed.log)"
SEED_LOG=$(cat ${D}/ui-seed/kanban-seed.log)
echo "${SEED_LOG}" | grep -q "trying again every 2s" || fail "the seed does not say it waited for the board: ${SEED_LOG}"
echo "${SEED_LOG}" | grep -qF "seed: 1 card(s), 1 created, 0 moved (project created); from the default goals ${AUTONOMY_LOOP_DEFAULT_GOALS} (no goals file yet)" \
	|| fail "the seed did not mirror the default goals into a new project: ${SEED_LOG}"
[ "$(state_count projects)" == "1" ] || fail "the seed did not create exactly one project"
[ "$(state_count issues)" == "1" ] || fail "the seed did not create exactly one card (the default goals' one standing goal)"
[ "$(status_of "${STANDING}")" == "To do" ] || fail "the default goal's card is not in To do: $(status_of "${STANDING}")"
description_of "${STANDING}" | grep -qF "the shipped default goals" || fail "the default goal's card does not say where it comes from"
grep -qF "${PASSWORD}" ${D}/ui-seed/kanban-seed.log ${D}/ui-start-seed.log && fail "the password reached the seed's log"
# one click from the home page's tile now lands on the project
PIDSEED=$(python3 -c 'import uuid; ns = uuid.UUID("403ef658-05ce-59aa-97e8-8aea9ecc4f02"); print(uuid.uuid5(ns, "project:test18-seed"))')
for _ in $(seq 1 25); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${SIGNIN_PORT}/healthz" && break; sleep 0.2; done
curl -s --max-time 10 -H "Host: kanban.localhost:${HOME_PORT}" -H "Referer: http://localhost:${HOME_PORT}/" "http://127.0.0.1:${SIGNIN_PORT}/__harness/sign-in" \
	| grep -qF "var target = \"/projects/${PIDSEED}\";" || fail "after the seed, the sign-in does not land on the project (/projects/${PIDSEED})"
# idempotent: a second seed (the next start) creates, moves and rewrites nothing
CALLS=$(curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['calls']))")
OUT=$(${SYNC} seed 2>&1) || fail "second seed: ${OUT}"
echo "${OUT}" | grep -q "seed: 1 card(s), 0 created, 0 moved (project exists)" || fail "a second seed is not idempotent: ${OUT}"
curl -s "http://127.0.0.1:${BOARD_PORT}/__state" | python3 -c "
import json, sys
calls = json.load(sys.stdin)['calls'][${CALLS}:]
sys.exit(1 if any(c.startswith('PATCH') for c in calls) else 0)" || fail "a second seed rewrote the board"
# the goals file appears: its goals get cards, and the default goal's card leaves the board (the hidden Cancelled)
echo "- [ ] a goal of my own" > ${AUTONOMY_LOOP_GOALS}
OUT=$(${SYNC} sync 2>&1) || fail "sync with a goals file: ${OUT}"
[ "$(status_of 'a goal of my own')" == "To do" ] || fail "the goals file's goal has no card in To do"
[ "$(status_of "${STANDING}")" == "Cancelled" ] || fail "with a goals file, the default goal's card is not Cancelled: $(status_of "${STANDING}")"
echo "${OUT}" | grep -q "; 1 card(s) of the default goals -> Cancelled" || fail "the sync does not say it retired the default goal's card: ${OUT}"
OUT=$(${SYNC} sync 2>&1)
echo "${OUT}" | grep -q "default goals -> Cancelled" && fail "a second sync retired the default goal's card again: ${OUT}"
# the goals file goes away: the default goal's card comes back to To do
rm -f "${AUTONOMY_LOOP_GOALS:?}"
${SYNC} sync > /dev/null 2>&1
[ "$(status_of "${STANDING}")" == "To do" ] || fail "without the goals file, the default goal's card did not come back to To do: $(status_of "${STANDING}")"
# a fire on the default goals that creates the goals file (a Slack message stated a goal): the default goal's card
# gets the fire's result and leaves the board; the new goal gets its card
OUT=$(${SYNC} fire-start --fire 1 --started 3000 2>&1) || fail "fire-start on the default goals: ${OUT}"
[ "$(status_of "${STANDING}")" == "In progress" ] || fail "a fire on the default goals did not move the default goal's card to In progress"
echo "- [ ] a goal from Slack" > ${AUTONOMY_LOOP_GOALS}
echo "recorded the goal from Slack" > ${D}/seed/fire-1.out
OUT=$(${SYNC} fire-end --fire 1 --started 3000 --rc 0 --duration 4 --out ${D}/seed/fire-1.out 2>&1) || fail "fire-end: ${OUT}"
[ "$(status_of "${STANDING}")" == "Cancelled" ] || fail "after the fire that created the goals file, the default goal's card is not Cancelled: $(status_of "${STANDING}") ${OUT}"
[ "$(status_of 'a goal from Slack')" == "To do" ] || fail "the goal the fire recorded has no card in To do"
comment_on "${STANDING}" "recorded the goal from Slack" || fail "the default goal's card lacks the result of the fire that worked on it"
comment_on "${STANDING}" "exists now" || fail "the default goal's card does not say why it was Cancelled"
comment_on "${STANDING}" "no longer in" && fail "the default goal's card got the renamed-goal note"
echo "${OUT}" | grep -qF "fire 1's result is on the card of the default goal" || fail "fire-end does not report the default goal's card: ${OUT}"
# a card that a fire creates between the seed's read and its own create (a 409) keeps the fire's column
printf '%s\n' "- [ ] a racing goal" "- [ ] a goal from Slack" > ${AUTONOMY_LOOP_GOALS}
${SYNC} fire-start --fire 2 --started 3100 > /dev/null 2>&1
[ "$(status_of 'a racing goal')" == "In progress" ] || fail "fire-start did not move the racing goal to In progress"
touch ${D}/hide-issues
OUT=$(${SYNC} seed 2>&1)
rm -f "${D:?}/hide-issues"
[ "$(status_of 'a racing goal')" == "In progress" ] || fail "a seed that lost the create race moved the fire's card: $(status_of 'a racing goal') ${OUT}"
# no goals at all (no goals file, no default goals): the seed still creates the project with its columns
OUT=$(KANBAN_PROJECT=test18-empty AUTONOMY_LOOP_GOALS=${D}/none.md AUTONOMY_LOOP_DEFAULT_GOALS=${D}/none-default.md ${SYNC} seed 2>&1) \
	|| fail "a seed without goals: ${OUT}"
echo "${OUT}" | grep -q "seed: 0 card(s), 0 created, 0 moved (project created)" || fail "a seed without goals did not create the project: ${OUT}"
# bounded: an unreachable board ends the seed with rc 2 after KANBAN_SEED_WAIT; a refused login or a bad setting at once
kill "$(cat ${D}/board.pid)" 2>/dev/null
sleep 1
T0=$(date +%s)
# an earlier run's file and its .tmp: --done removes both when it starts, so none reads as this run's end
echo 0 > ${D}/seed-unreachable.done
echo 0 > ${D}/seed-unreachable.done.tmp
timeout 30 env KANBAN_SEED_WAIT=3 "${SYNC}" seed --done ${D}/seed-unreachable.done > ${D}/seed-unreachable.out 2>&1 &
SEED_JOB=$!
for _ in $(seq 1 50); do grep -q "trying again every 2s" ${D}/seed-unreachable.out && break; sleep 0.2; done
grep -q "trying again every 2s" ${D}/seed-unreachable.out || fail "a seed against a board that never answers does not say it waits: $(cat ${D}/seed-unreachable.out)"
[ "$(cat ${D}/seed-unreachable.done 2>/dev/null)" == "0" ] && fail "--done kept an earlier run's file while the seed runs (it reads 0, success)"
[ "$(cat ${D}/seed-unreachable.done.tmp 2>/dev/null)" == "0" ] && fail "--done kept an earlier run's .tmp while the seed runs"
wait ${SEED_JOB}
RC=$?
OUT=$(cat ${D}/seed-unreachable.out)
[ ${RC} -eq 2 ] || fail "a seed against a board that never answers did not exit 2 (rc=${RC}): ${OUT}"
[ "$(cat ${D}/seed-unreachable.done 2>&1)" == "2" ] || fail "--done does not hold the seed's rc 2: $(cat ${D}/seed-unreachable.done 2>&1)"
echo "${OUT}" | grep -qF "after waiting 3s (KANBAN_SEED_WAIT)" || fail "the seed's last line does not say it gave up: ${OUT}"
[ $(( $(date +%s) - T0 )) -le 12 ] || fail "the seed waited past KANBAN_SEED_WAIT"
start_board
T0=$(date +%s)
OUT=$(timeout 30 env KANBAN_SEED_WAIT=60 KANBAN_AUTH_FILE=${D}/wrong.env "${SYNC}" seed --done ${D}/seed-refused.done 2>&1)
RC=$?
[ ${RC} -eq 3 ] || fail "a seed with a refused login did not exit 3 (rc=${RC}): ${OUT}"
[ "$(cat ${D}/seed-refused.done 2>&1)" == "3" ] || fail "--done does not hold the seed's rc 3: $(cat ${D}/seed-refused.done 2>&1)"
[ $(( $(date +%s) - T0 )) -le 5 ] || fail "a seed with a refused login waited (it cannot get better by waiting)"
OUT=$(KANBAN_SEED_WAIT=soon ${SYNC} seed 2>&1)
[ $? -eq 4 ] || fail "a KANBAN_SEED_WAIT that is no number does not exit 4: ${OUT}"
echo "ok 7 - startup seed: ui-start.sh starts it in the background, it waits for a board that is not up yet, then creates the project with the default goal's card (the sign-in lands there); idempotent; a goals file's goals replace the default goal (Cancelled, back when the file goes), a fire on the default goals that creates the goals file leaves its result there; a lost create race keeps the fire's column; no goals -> the project still; bounded: rc 2 after KANBAN_SEED_WAIT, a refused login 3 at once, a bad wait 4; its end read from its --done file (rc 0, 2, 3; an earlier start's file removed by ui-start.sh, an earlier run's by --done), not its pid"

# --- 8. the agent runner's first-start settings: analytics off and nothing else; a user's settings never touched ---
TEMPLATE=${AGENT_DIR}/vibe-kanban-config.json
python3 - "${TEMPLATE}" << 'EOF' || fail "the runner's first-start settings are not its 0.1.44 settings with analytics off and the Workspaces guide seen, nothing else"
import json, sys
c = json.load(open(sys.argv[1]))
keys = {"config_version", "theme", "executor_profile", "disclaimer_acknowledged", "onboarding_acknowledged",
        "remote_onboarding_acknowledged", "notifications", "editor", "github", "analytics_enabled", "workspace_dir",
        "last_app_version", "show_release_notes", "language", "git_branch_prefix", "showcases",
        "pr_auto_description_enabled", "pr_auto_description_prompt", "commit_reminder_enabled", "commit_reminder_prompt",
        "send_message_shortcut", "relay_enabled", "host_nickname"}
assert set(c) == keys, sorted(set(c) ^ keys)  # every field of the runner's v8 settings, so it parses as v8
assert c["config_version"] == "v8" and c["last_app_version"] == "0.1.44"
assert c["analytics_enabled"] is False
# consent stays the user's: terms, disclaimer, onboarding unanswered
assert not c["disclaimer_acknowledged"] and not c["onboarding_acknowledged"]
# the retired cloud's sign-in onboarding is seen: with it unseen the runner's root sends every visit to a cloud sign-in
# (RootRedirectPage.tsx in 0.1.44); nothing about it is the user's consent
assert c["remote_onboarding_acknowledged"] is True
# only the Workspaces guide is seen: the id vibe-kanban 0.1.44 checks before it opens the guide over /workspaces
# (WORKSPACES_GUIDE_ID in packages/web-core/src/pages/workspaces/WorkspacesLayout.tsx)
assert c["showcases"] == {"seen_features": ["workspaces-guide"]}, c["showcases"]
EOF
PROFILES=${AGENT_DIR}/vibe-kanban-profiles.json
python3 - "${PROFILES}" << 'EOF' || fail "the runner's agent settings are not Claude Code as the image's claude without --dangerously-skip-permissions, alone"
import json, sys
p = json.load(open(sys.argv[1]))
# vibe-kanban 0.1.44 replaces a default configuration by a user one of the same name, whole (merge_with_defaults in
# crates/executors/src/profile.rs): Claude Code's DEFAULT is then exactly these two settings, the flag off
assert p == {"executors": {"CLAUDE_CODE": {"DEFAULT": {"CLAUDE_CODE": {
    "base_command_override": "claude", "dangerously_skip_permissions": False}}}}}, p
EOF
# vk_start <data home> - ui-start.sh with the runner on only (check 7's stub runner is "running", so no real one starts)
vk_start()
{
	UI_DIR=${D}/ui-seed UI_LISTEN_HOST=127.0.0.1 UI_HOME=false UI_FILES=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_TMUX=false \
		UI_TMUX_AGENT=false UI_VIBE_KANBAN=true UI_PORT_VIBE_KANBAN=${RUNNER_PORT} KANBAN_BOARD_URL='' VIBE_KANBAN_DATA_HOME="$1" \
		"${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-vk.log 2>&1 || fail "ui-start.sh: $(cat ${D}/ui-start-vk.log)"
}
# a first start: the runner gets those settings
vk_start ${D}/vk-fresh
cmp -s "${TEMPLATE}" ${D}/vk-fresh/vibe-kanban/config.json || fail "a first start did not give the runner its analytics-off settings"
grep -qF "vibe-kanban: first start - its analytics are off in ${D}/vk-fresh/vibe-kanban/config.json" ${D}/ui-start-vk.log \
	|| fail "a first start does not say the runner's analytics are off: $(cat ${D}/ui-start-vk.log)"
cmp -s "${PROFILES}" ${D}/vk-fresh/vibe-kanban/profiles.json || fail "a first start did not give the runner its agent settings"
grep -qF "vibe-kanban: no agent settings yet - its Claude Code is the image's claude, without --dangerously-skip-permissions (${D}/vk-fresh/vibe-kanban/profiles.json" \
	${D}/ui-start-vk.log || fail "a first start does not say what the runner's agent settings are: $(cat ${D}/ui-start-vk.log)"
# the next start leaves them as they are now (the runner and the user own them)
vk_start ${D}/vk-fresh
grep -q "vibe-kanban: first start" ${D}/ui-start-vk.log && fail "a second start seeded the runner's settings again"
grep -q "vibe-kanban: no agent settings yet" ${D}/ui-start-vk.log && fail "a second start wrote the runner's agent settings again"
cmp -s "${PROFILES}" ${D}/vk-fresh/vibe-kanban/profiles.json || fail "a second start changed the runner's agent settings"
# a user's settings with analytics on: never changed, and a one-line notice says they are on
mkdir -p ${D}/vk-user/vibe-kanban
sed 's/"analytics_enabled": false/"analytics_enabled": true/' "${TEMPLATE}" > ${D}/vk-user/vibe-kanban/config.json
grep -q '"analytics_enabled": true' ${D}/vk-user/vibe-kanban/config.json || fail "test setup: no analytics-on settings"
BEFORE=$(sha256sum < ${D}/vk-user/vibe-kanban/config.json)
# and agent settings of their own (skip permissions on, vibe-kanban's command)
echo '{"executors": {"CLAUDE_CODE": {"DEFAULT": {"CLAUDE_CODE": {"dangerously_skip_permissions": true}}}}}' \
	> ${D}/vk-user/vibe-kanban/profiles.json
BEFORE_PROFILES=$(sha256sum < ${D}/vk-user/vibe-kanban/profiles.json)
: > ${D}/ui-seed/vibe-kanban.log
vk_start ${D}/vk-user
[ "$(sha256sum < ${D}/vk-user/vibe-kanban/config.json)" == "${BEFORE}" ] || fail "ui-start.sh changed the user's runner settings"
[ "$(sha256sum < ${D}/vk-user/vibe-kanban/profiles.json)" == "${BEFORE_PROFILES}" ] || fail "ui-start.sh changed the user's agent settings"
grep -q "vibe-kanban: no agent settings yet" ${D}/ui-start-vk.log && fail "ui-start.sh said it wrote agent settings over the user's"
[ "$(grep -c 'vibe-kanban: NOTICE - analytics are on in' ${D}/ui-start-vk.log)" == "1" ] \
	|| fail "the user's analytics-on settings got no one-line notice: $(cat ${D}/ui-start-vk.log)"
grep -q 'vibe-kanban: NOTICE - analytics are on in' ${D}/ui-seed/vibe-kanban.log || fail "the notice is not in the runner's log"
[ "$(grep -c 'vibe-kanban: NOTICE - analytics are on in' ${D}/ui-seed/vibe-kanban-analytics.notice 2>/dev/null)" == "1" ] \
	|| fail "this start's notice is not in its notice file"
# a user's settings with analytics off: unchanged and no notice
mkdir -p ${D}/vk-off/vibe-kanban
sed 's/"onboarding_acknowledged": false/"onboarding_acknowledged": true/' "${TEMPLATE}" > ${D}/vk-off/vibe-kanban/config.json
BEFORE=$(sha256sum < ${D}/vk-off/vibe-kanban/config.json)
vk_start ${D}/vk-off
[ "$(sha256sum < ${D}/vk-off/vibe-kanban/config.json)" == "${BEFORE}" ] || fail "ui-start.sh changed the user's runner settings (analytics off)"
grep -q "vibe-kanban: NOTICE" ${D}/ui-start-vk.log && fail "a notice for settings with analytics off"
cmp -s "${PROFILES}" ${D}/vk-off/vibe-kanban/profiles.json || fail "a start with settings but no agent settings did not write the agent settings"
[ -e ${D}/ui-seed/vibe-kanban-analytics.notice ] && fail "the notice file of an earlier start survived this start (analytics off)"
echo "ok 8 - the runner's first-start settings are its 0.1.44 ones with analytics off, its Workspaces guide seen and the retired cloud's sign-in onboarding seen, nothing else (terms, disclaimer, onboarding unanswered); a first start writes them, a later start leaves them; a user's settings are never changed, and with analytics on a one-line notice says so (on the start output and in the runner's log); without agent settings it gets Claude Code as the image's claude without --dangerously-skip-permissions, and agent settings that exist are never changed"

# --- 9. no redirect carries the board session: a board that answers every signed-in call with a 302 to another
# loopback listener, which records every request it gets ---
cat > ${D}/recorder.py << 'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def record(self):
        with open(sys.argv[2], "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "headers": dict(self.headers)}) + "\n")
        raw = b'{"organizations": []}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    do_GET = do_POST = do_PATCH = record
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
setsid nohup python3 ${D}/recorder.py ${RECORDER_PORT} ${D}/recorder.jsonl > ${D}/recorder.log 2>&1 &
echo $! > ${D}/recorder.pid
for _ in $(seq 1 25); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${RECORDER_PORT}/ready" && break; sleep 0.2; done
grep -q '"/ready"' ${D}/recorder.jsonl 2>/dev/null || fail "test setup: the recording listener does not record"
: > ${D}/recorder.jsonl
touch ${D}/redirect
LOC=$(curl -s -D - -o /dev/null --max-time 5 -H "Authorization: Bearer stub-token" "http://127.0.0.1:${BOARD_PORT}/v1/organizations" \
	| tr -d '\r' | sed -n 's/^[Ll]ocation: //p')
[ "${LOC}" == "http://127.0.0.1:${RECORDER_PORT}/v1/organizations" ] || fail "test setup: the stub board does not redirect (${LOC})"
OUT=$(${SYNC} sync 2>&1)
RC=$?
SIGNIN=$(curl -s -o ${D}/signin-redirect.html -w '%{http_code}' --max-time 10 -H "Host: kanban.localhost:${HOME_PORT}" \
	-H "Referer: http://localhost:${HOME_PORT}/" "http://127.0.0.1:${SIGNIN_PORT}/__harness/sign-in")
PROBE=$(curl -s -o ${D}/probe-redirect.txt -w '%{http_code}' --max-time 10 "http://127.0.0.1:${SIGNIN_PORT}/healthz/board")
rm -f "${D:?}/redirect"
if [ -s ${D}/recorder.jsonl ]; then
	fail "a redirect was followed: $(wc -l < ${D}/recorder.jsonl) request(s) reached the other listener, $(grep -c '"Authorization": "Bearer' ${D}/recorder.jsonl) with the board session"
fi
[ ${RC} -eq 2 ] || fail "with a board that redirects, the sync did not exit 2 (rc=${RC}): ${OUT}"
echo "${OUT}" | grep -q "the board answered a redirect to 'http://127.0.0.1:${RECORDER_PORT}/v1/organizations', not followed" \
	|| fail "the sync does not say it refused the redirect: ${OUT}"
if [ "${PROBE}" != "502" ] || ! grep -q "redirect" ${D}/probe-redirect.txt; then
	fail "the board probe did not refuse the redirect: ${PROBE} $(cat ${D}/probe-redirect.txt)"
fi
if [ "${SIGNIN}" != "200" ] || ! grep -qF 'var target = "/";' ${D}/signin-redirect.html; then
	fail "the sign-in did not keep to the board when its project read was redirected: ${SIGNIN}"
fi
echo "ok 9 - a board that answers signed-in calls with a 302 to another listener: the sync (rc 2, says so), the sign-in and the probe (502) follow none of them, and 0 requests, so no board session, reach that listener"

# --- 10. the runner's Recent repositories: /agent/vk-runner-repos.sh registers the workspace's git repositories with the
#         runner (POST /api/repos), idempotently, and ui-start.sh runs it in the background after the runner ---
REPOS_PORT=18196
cat > ${D}/stub-runner.py << 'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
REPOS = []
LOG = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == '/api/health': return self._json(200, {"success": True})
        if self.path == '/api/repos': return self._json(200, {"success": True, "data": REPOS, "error_data": None, "message": None})
        return self._json(404, {})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        if self.path == '/api/repos':
            r = {"id": str(len(REPOS) + 1), "path": body["path"], "name": body["path"].rsplit('/', 1)[-1], "display_name": body.get("display_name")}
            REPOS.append(r); open(LOG, 'a').write(json.dumps(body) + "\n"); return self._json(200, {"success": True, "data": r})
        return self._json(404, {})
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
: > ${D}/repos-posted.log
( setsid nohup python3 ${D}/stub-runner.py ${REPOS_PORT} ${D}/repos-posted.log > ${D}/stub-runner.log 2>&1 & echo $! > ${D}/pid.tmp ) && mv "${D:?}/pid.tmp" "${D:?}/repos-runner.pid"
for _ in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${REPOS_PORT}/api/health" && break; sleep 0.25; done
REPOS_HELPER=${AGENT_DIR}/vk-runner-repos.sh
[ -x "${REPOS_HELPER}" ] || fail "no executable ${REPOS_HELPER}"
mkdir -p ${D}/wd/repo-a ${D}/wd/plain ${D}/wd/repo-b
git -C ${D}/wd/repo-a init -q && git -C ${D}/wd/repo-b init -q
OUT=$(VK_RUNNER_URL=http://127.0.0.1:${REPOS_PORT} VK_REPOS_ROOT=${D}/wd VK_REPOS_WAIT=10 "${REPOS_HELPER}") || fail "vk-runner-repos.sh exited $? against a runner that answers: ${OUT}"
[ "$(wc -l < ${D}/repos-posted.log)" == "2" ] || fail "the workspace (not a repository) with two repositories and a plain directory under it: expected 2 registrations, got $(cat ${D}/repos-posted.log)"
grep -qF "\"path\": \"${D}/wd/repo-a\"" ${D}/repos-posted.log && grep -qF "\"path\": \"${D}/wd/repo-b\"" ${D}/repos-posted.log || fail "the two repositories were not the ones registered: $(cat ${D}/repos-posted.log)"
grep -qF "${D}/wd/plain" ${D}/repos-posted.log && fail "a plain directory was registered as a repository"
echo "${OUT}" | grep -qF "2 registered" || fail "the summary line does not count 2 registered: ${OUT}"
echo "${OUT}" | grep -qF "is not a git repository itself" || fail "the summary line does not say the workspace itself is not a repository: ${OUT}"
OUT=$(VK_RUNNER_URL=http://127.0.0.1:${REPOS_PORT} VK_REPOS_ROOT=${D}/wd VK_REPOS_WAIT=10 "${REPOS_HELPER}") || fail "second run exited $?: ${OUT}"
[ "$(wc -l < ${D}/repos-posted.log)" == "2" ] || fail "a second run registered again (not idempotent): $(cat ${D}/repos-posted.log)"
echo "${OUT}" | grep -qF "0 registered" && echo "${OUT}" | grep -qF "2 listed already" || fail "the second run's summary does not say 0 registered, 2 listed already: ${OUT}"
git -C ${D}/wd init -q
OUT=$(VK_RUNNER_URL=http://127.0.0.1:${REPOS_PORT} VK_REPOS_ROOT=${D}/wd VK_REPOS_WAIT=10 "${REPOS_HELPER}") || fail "third run exited $?: ${OUT}"
grep -qF "\"path\": \"${D}/wd\"" ${D}/repos-posted.log || fail "the workspace, once a repository, was not registered: $(cat ${D}/repos-posted.log)"
echo "${OUT}" | grep -qF "is a git repository" || fail "the summary line does not say the workspace is a repository: ${OUT}"
# a runner that never answers: one line, exit 2, within the wait
START=$(date +%s)
OUT=$(VK_RUNNER_URL=http://127.0.0.1:${DEAD_PORT} VK_REPOS_ROOT=${D}/wd VK_REPOS_WAIT=3 "${REPOS_HELPER}")
RC=$?
[ ${RC} -eq 2 ] || fail "with no runner the helper exited ${RC}, expected 2: ${OUT}"
[ $(( $(date +%s) - START )) -le 15 ] || fail "with no runner the helper took $(( $(date +%s) - START ))s for a 3 s wait"
echo "${OUT}" | grep -qF "did not answer within 3s" || fail "with no runner the line does not say so: ${OUT}"
# the hook: ui-start.sh with the runner "running" (check 7's stub pid) runs the helper in the background against the runner's port
mkdir -p ${D}/wd2/repo-c && git -C ${D}/wd2/repo-c init -q
: > ${D}/repos-posted.log
UI_DIR=${D}/ui-seed UI_LISTEN_HOST=127.0.0.1 UI_HOME=false UI_FILES=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_TMUX=false \
	UI_TMUX_AGENT=false UI_VIBE_KANBAN=true UI_PORT_VIBE_KANBAN=${REPOS_PORT} KANBAN_BOARD_URL='' VIBE_KANBAN_DATA_HOME=${D}/vk-fresh \
	VK_REPOS_ROOT=${D}/wd2 VK_REPOS_WAIT=10 "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-repos.log 2>&1 || fail "ui-start.sh (repos hook): $(cat ${D}/ui-start-repos.log)"
grep -qF "vk-runner-repos: registering the workspace's repositories with the runner in the background" ${D}/ui-start-repos.log \
	|| fail "ui-start.sh does not say it runs the repositories helper: $(cat ${D}/ui-start-repos.log)"
for _ in $(seq 1 60); do grep -q "1 registered" ${D}/ui-seed/vk-runner-repos.log 2>/dev/null && break; sleep 0.5; done
grep -qF "\"path\": \"${D}/wd2/repo-c\"" ${D}/repos-posted.log || fail "ui-start.sh's helper did not register the workspace's repository within 30 s: $(cat ${D}/ui-seed/vk-runner-repos.log 2>/dev/null)"
ls ${D}/ui-seed/vk-runner-repos.pid 2>/dev/null && fail "the one-shot helper left a pid file (ui-stop.sh would report it)"
# a fresh start: the workspace holds only the starter repository that /agent/starter-repo.sh makes, two levels down
# (projects/scratch), and the runner gets it; a repository deeper under projects/ is no candidate
starter_workspace()
{
	# starter_workspace <dir> - a fresh workspace with the starter repository alone, as a first start leaves it
	STARTER_REPO_ROOT=$1 "${AGENT_DIR}/starter-repo.sh" > ${D}/starter-repo.log 2>&1 || fail "10: starter-repo.sh: $(cat ${D}/starter-repo.log)"
	[ -d "$1/projects/scratch/.git" ] || fail "10: test setup: starter-repo.sh made no $1/projects/scratch: $(cat ${D}/starter-repo.log)"
}
starter_workspace ${D}/wd3
mkdir -p ${D}/wd3/projects/group/deep && git -C ${D}/wd3/projects/group/deep init -q
: > ${D}/repos-posted.log
OUT=$(VK_RUNNER_URL=http://127.0.0.1:${REPOS_PORT} VK_REPOS_ROOT=${D}/wd3 VK_REPOS_WAIT=10 "${REPOS_HELPER}") || fail "10: a fresh start's run exited $?: ${OUT}"
if [ "$(wc -l < ${D}/repos-posted.log)" != "1" ] || ! grep -qF "\"path\": \"${D}/wd3/projects/scratch\"" ${D}/repos-posted.log; then
	fail "10: a fresh start's workspace: expected the starter repository ${D}/wd3/projects/scratch alone registered, got: [$(cat ${D}/repos-posted.log)] (${OUT})"
fi
echo "${OUT}" | grep -qF "1 registered (${D}/wd3/projects/scratch)" || fail "10: the summary line does not name the starter repository: ${OUT}"
# PLANTED CONTROL: the helper without the projects/ candidates registers nothing of another fresh workspace
starter_workspace ${D}/wd4
python3 - "${REPOS_HELPER}" ${D}/repos-planted.sh << 'PYEOF' || fail "10: PLANTED CONTROL BROKEN: the projects/ candidates are not in the helper as expected"
import sys
c = open(sys.argv[1]).read()
old = ' "${ROOT}"/projects/*/'
assert c.count(old) == 1
open(sys.argv[2], "w").write(c.replace(old, ""))
PYEOF
chmod +x ${D}/repos-planted.sh
: > ${D}/repos-posted.log
OUT=$(VK_RUNNER_URL=http://127.0.0.1:${REPOS_PORT} VK_REPOS_ROOT=${D}/wd4 VK_REPOS_WAIT=10 ${D}/repos-planted.sh) || fail "10: the planted helper exited $?: ${OUT}"
[ -s ${D}/repos-posted.log ] && fail "10: PLANTED CONTROL BROKEN: without the projects/ candidates the helper still registered $(cat ${D}/repos-posted.log)"
kill "$(cat ${D}/repos-runner.pid)" 2>/dev/null
echo "ok 10 - vk-runner-repos.sh: the workspace's git repositories (not the plain directory, not the workspace until it is one) registered with the runner once, the starter repository under projects/ on a fresh start (PLANTED CONTROL: not without the projects/ candidates; a repository deeper down never), a second run registers nothing, a runner that never answers gives one line and exit 2 within the wait; ui-start.sh runs it in the background against the runner's port, no pid file"

# --- 11. two-way: what a user does on the board reaches the goals file, one atomic rewrite under the
#         goals lock; a card created on the board is a new goal; title and description edits write back; a field edited in
#         both places: the file wins and the card says so; the project is shown under the goal set's name; the
#         card projection (the standing goal's instructions folded; a checkbox goal's title not repeated) ---
export KANBAN_BOARD_URL=http://127.0.0.1:${BOARD_PORT} KANBAN_AUTH_FILE=${D}/kanban.env KANBAN_PROJECT=test18-twoway
export AUTONOMY_LOOP_DIR=${D}/twoway AUTONOMY_LOOP_GOALS=${D}/twoway/GOALS.md
unset KANBAN_PROJECT_NAME
mkdir -p ${D}/twoway
cat > ${AUTONOMY_LOOP_GOALS} << 'EOF'
# Two-way goals

## Goal 1 - the hello file
Create /tmp/kanban-smoke/hello.txt with one line.
DONE when: the file exists with that line.

## Goal 2 - the inventory
List the workspace.
DONE when: /tmp/kanban-smoke/inventory.md exists.

## Goals from Slack

- [ ] open goal B
EOF
PID11=$(python3 -c "import uuid; print(uuid.uuid5(uuid.UUID('403ef658-05ce-59aa-97e8-8aea9ecc4f02'), 'project:test18-twoway'))")
OUT=$(${SYNC} sync 2>&1) || fail "11: first sync: ${OUT}"
# the board's state helpers for this project
board_json() { curl -s "http://127.0.0.1:${BOARD_PORT}/__state"; }
card_field() { board_json | T="$1" F="$2" P="${PID11}" python3 -c '
import json, os, sys
s = json.load(sys.stdin); hits = [i for i in s["issues"].values() if i["project_id"] == os.environ["P"] and i["title"] == os.environ["T"]]
print(hits[0].get(os.environ["F"], "") if len(hits) == 1 else "cards=%d" % len(hits))'; }
status_id() { board_json | P="${PID11}" N="$1" python3 -c 'import json, os, sys; s = json.load(sys.stdin); print(next(st["id"] for st in s["statuses"][os.environ["P"]] if st["name"] == os.environ["N"]))'; }
# own_text - a card description without the agent's cue line (check 13), the one line the mirror puts above a card's
# own text on the card the agent acts on next
own_text() { awk 'NR == 1 && /^\*\*Agent:\*\* / { cue = 1; next } cue && NR == 2 && /^$/ { next } { print }'; }
patch_card() { curl -s -o /dev/null -X PATCH -H "Authorization: Bearer stub-token" -H "Content-Type: application/json" -d "$2" "http://127.0.0.1:${BOARD_PORT}/v1/issues/$1"; }
project_name() { board_json | P="${PID11}" python3 -c 'import json, os, sys; print(json.load(sys.stdin)["projects"][os.environ["P"]]["name"])'; }
comments_with() { board_json | NEEDLE="$1" python3 -c 'import json, os, sys; s = json.load(sys.stdin); print(sum(1 for c in s["comments"].values() if os.environ["NEEDLE"] in c["message"]))'; }
comments_on() { board_json | IID="$1" NEEDLE="$2" python3 -c 'import json, os, sys; s = json.load(sys.stdin); print(sum(1 for c in s["comments"].values() if c["issue_id"] == os.environ["IID"] and os.environ["NEEDLE"] in c["message"]))'; }
[ "$(project_name)" == "Two-way goals" ] || fail "11: the project is not shown under the goals file's heading: $(project_name)"
# a checkbox goal's card does not repeat its title as its description; the standing goal's folding is checked on the default goal below
card_field "open goal B" description | grep -q "^open goal B" && fail "11 (checkbox goal): the checkbox goal's description repeats its title: $(card_field 'open goal B' description | head -c 80)"
card_field "open goal B" description | grep -qF "Synced with ${AUTONOMY_LOOP_GOALS}" || fail "11: the card footer does not say the sync is two-way: $(card_field 'open goal B' description | tail -c 200)"
# (a) a card dragged to Done checks the goal off; dragged back, it is unchecked
C1=$(card_field "Goal 1 - the hello file" id)
patch_card "${C1}" "{\"status_id\": \"$(status_id Done)\"}"
OUT=$(${SYNC} sync 2>&1) || fail "11 (a): sync after the drag: ${OUT}"
grep -q '^## Goal 1 - the hello file \[x\]$' ${AUTONOMY_LOOP_GOALS} || fail "11 (a): the goal was not checked off in the file after its card went to Done: $(grep 'Goal 1' ${AUTONOMY_LOOP_GOALS})"
echo "${OUT}" | grep -q "from the board: .*done on the board" || fail "11 (a): the sync does not say the board checked the goal off: ${OUT}"
[ "$(card_field 'Goal 1 - the hello file' status_id)" == "$(status_id Done)" ] || fail "11 (a): the card left Done after the sync"
patch_card "${C1}" "{\"status_id\": \"$(status_id 'To do')\"}"
OUT=$(${SYNC} sync 2>&1) || fail "11 (a2): ${OUT}"
grep -q '^## Goal 1 - the hello file$' ${AUTONOMY_LOOP_GOALS} || fail "11 (a2): the goal was not unchecked after its card left Done: $(grep 'Goal 1' ${AUTONOMY_LOOP_GOALS})"
# (b) a card created on the board becomes a new goal in the file's form; its card keeps its id, no duplicate
NEW=$(python3 -c 'import uuid; print(uuid.uuid4())')
curl -s -o /dev/null -X POST -H "Authorization: Bearer stub-token" -H "Content-Type: application/json" \
	-d "{\"id\": \"${NEW}\", \"project_id\": \"${PID11}\", \"title\": \"a goal from the board\", \"description\": \"Write /tmp/kanban-smoke/board.md.\nDONE when: that file exists.\", \"status_id\": \"$(status_id 'To do')\"}" \
	"http://127.0.0.1:${BOARD_PORT}/v1/issues"
G1_BEFORE=$(card_field "Goal 1 - the hello file" sort_order)
OUT=$(${SYNC} sync 2>&1) || fail "11 (b): ${OUT}"
grep -q '^## Goal 3 - a goal from the board$' ${AUTONOMY_LOOP_GOALS} || fail "11 (b): the board's card did not become a goal in the file's form: $(grep -n 'from the board' ${AUTONOMY_LOOP_GOALS})"
grep -q '^DONE when: that file exists.$' ${AUTONOMY_LOOP_GOALS} || fail "11 (b): the new goal lacks its DONE condition from the card"
N_BEFORE=$(state_count issues)
OUT=$(${SYNC} sync 2>&1) || fail "11 (b2): ${OUT}"
[ "$(state_count issues)" == "${N_BEFORE}" ] || fail "11 (b2): a sync after the new goal duplicated its card (${N_BEFORE} -> $(state_count issues))"
# the adopted card takes the goal's heading as its title, like every other card of a heading-form file, and keeps its id
[ "$(card_field 'Goal 3 - a goal from the board' id)" == "${NEW}" ] || fail "11 (b2): the board-created card lost its id or did not take the goal's heading as its title: $(card_field 'Goal 3 - a goal from the board' id)"
# the board puts a new card on top of its column; mirrored after the others, it is the newest and stays on top, and no
# other card's value changes (the time each goal reached the board is kept)
top_card() { board_json | P="${PID11}" python3 -c 'import json, os, sys; s = json.load(sys.stdin); print(min((i for i in s["issues"].values() if i["project_id"] == os.environ["P"]), key=lambda i: i["sort_order"])["title"])'; }
[ "$(top_card)" == "Goal 3 - a goal from the board" ] || fail "11 (b2): the board-created card is not on top once mirrored (the project's smallest sort_order is $(top_card)'s)"
[ "$(card_field 'Goal 1 - the hello file' sort_order)" == "${G1_BEFORE}" ] || fail "11 (b2): the new goal changed an older card's value (Goal 1: ${G1_BEFORE} -> $(card_field 'Goal 1 - the hello file' sort_order))"
# (b4) a goal goals-add.sh adds now goes under its heading, ABOVE the section the board's card appended: still the newest,
#      so its card is on top, and Goal 3's value does not change
G3_BEFORE=$(card_field "Goal 3 - a goal from the board" sort_order)
OUT=$("${AGENT_DIR}/goals-add.sh" "a later goal from Slack" 2>&1) || fail "11 (b4): goals-add.sh: ${OUT}"
python3 - "${AUTONOMY_LOOP_GOALS}" << 'PY' || fail "11 (b4): test setup: goals-add.sh did not put the goal under its heading, above Goal 3: $(grep -n 'open goal B\|later goal\|^## Goal 3' ${AUTONOMY_LOOP_GOALS})"
import sys
lines = open(sys.argv[1]).read().splitlines()
at = {l: n for n, l in enumerate(lines)}
sys.exit(0 if at["- [ ] open goal B"] < at["- [ ] a later goal from Slack"] < at["## Goal 3 - a goal from the board"] else 1)
PY
OUT=$(${SYNC} sync 2>&1) || fail "11 (b4): ${OUT}"
[ "$(top_card)" == "a later goal from Slack" ] || fail "11 (b4): the goal added under the Slack heading, newer than Goal 3 but above it in the file, is not on top: $(top_card)"
[ "$(card_field 'Goal 3 - a goal from the board' sort_order)" == "${G3_BEFORE}" ] || fail "11 (b4): the added goal changed Goal 3's value (${G3_BEFORE} -> $(card_field 'Goal 3 - a goal from the board' sort_order))"
card_field "Goal 3 - a goal from the board" description | grep -qF "Synced with" || fail "11 (b2): the board-created card got no footer"
# (b3) a board-created goal's number is past every number the file uses: with Goal 2 removed, the file's Goal 1 and
#      Goal 3 make the new one Goal 4, not a second Goal 3
numbered_goal()
{
	# numbered_goal <sync> <project> - a file with Goal 1 and Goal 3, synced; a card created on that project's board;
	# synced again; prints the file's goal headings
	local N="${D}/num-$2" PIDN OPEN_COLUMN
	mkdir -p "${N}"
	printf '# Goals\n\n## Goal 1 - the first goal\nWrite one.\nDONE when: one exists.\n\n## Goal 3 - the third goal\nWrite three.\nDONE when: three exists.\n' > "${N}/GOALS.md"
	KANBAN_PROJECT=$2 AUTONOMY_LOOP_DIR="${N}" AUTONOMY_LOOP_GOALS="${N}/GOALS.md" "$1" sync > "${N}/sync1.log" 2>&1 || fail "11 (b3): sync: $(cat "${N}/sync1.log")"
	PIDN=$(python3 -c "import uuid, sys; print(uuid.uuid5(uuid.UUID('403ef658-05ce-59aa-97e8-8aea9ecc4f02'), 'project:' + sys.argv[1]))" "$2")
	OPEN_COLUMN=$(board_json | P="${PIDN}" python3 -c 'import json, os, sys; s = json.load(sys.stdin); print(next(st["id"] for st in s["statuses"][os.environ["P"]] if st["name"] == "To do"))')
	curl -s -o /dev/null -X POST -H "Authorization: Bearer stub-token" -H "Content-Type: application/json" \
		-d "{\"id\": \"$(python3 -c 'import uuid; print(uuid.uuid4())')\", \"project_id\": \"${PIDN}\", \"title\": \"a numbered goal from the board\", \"description\": \"Write four.\", \"status_id\": \"${OPEN_COLUMN}\"}" \
		"http://127.0.0.1:${BOARD_PORT}/v1/issues"
	KANBAN_PROJECT=$2 AUTONOMY_LOOP_DIR="${N}" AUTONOMY_LOOP_GOALS="${N}/GOALS.md" "$1" sync > "${N}/sync2.log" 2>&1 || fail "11 (b3): second sync: $(cat "${N}/sync2.log")"
	grep '^## Goal' "${N}/GOALS.md"
}
HEADS=$(numbered_goal "${SYNC}" test18-num)
[ "${HEADS}" == "$(printf '## Goal 1 - the first goal\n## Goal 3 - the third goal\n## Goal 4 - a numbered goal from the board')" ] \
	|| fail "11 (b3): with Goal 1 and Goal 3 in the file the board's card did not become Goal 4: [${HEADS}]"
# PLANTED CONTROL: numbered by counting the headings, the same card becomes a second Goal 3
python3 - "${SYNC}" ${D}/kanban-sync-count.py << 'PYEOF' || fail "11 (b3): PLANTED CONTROL BROKEN: the numbering is not in kanban-sync.py as expected"
import sys
c = open(sys.argv[1]).read()
old = "    number = max(numbers + [len(headings)]) + 1\n"
assert c.count(old) == 1
open(sys.argv[2], "w").write(c.replace(old, "    number = len(headings) + 1\n"))
PYEOF
chmod +x ${D}/kanban-sync-count.py
HEADS=$(numbered_goal ${D}/kanban-sync-count.py test18-num-planted)
[ "$(echo "${HEADS}" | grep -c '^## Goal 3 - ')" == "2" ] || fail "11 (b3): PLANTED CONTROL BROKEN: counting the headings did not repeat Goal 3: [${HEADS}]"
# (c) a title edit renames the goal; the card keeps its id
CB=$(card_field "open goal B" id)
patch_card "${CB}" '{"title": "open goal C"}'
OUT=$(${SYNC} sync 2>&1) || fail "11 (c): ${OUT}"
grep -q '^- \[ \] open goal C$' ${AUTONOMY_LOOP_GOALS} || fail "11 (c): the renamed card did not rename the goal: $(grep 'open goal' ${AUTONOMY_LOOP_GOALS})"
[ "$(card_field 'open goal C' id)" == "${CB}" ] || fail "11 (c): the renamed goal got another card (id $(card_field 'open goal C' id), was ${CB})"
# (d) a description edit rewrites the outcome lines, the DONE-when line kept
C2=$(card_field "Goal 2 - the inventory" id)
patch_card "${C2}" '{"description": "List the workspace, one line per directory."}'
OUT=$(${SYNC} sync 2>&1) || fail "11 (d): ${OUT}"
grep -q '^List the workspace, one line per directory.$' ${AUTONOMY_LOOP_GOALS} || fail "11 (d): the description edit did not reach the file: $(sed -n '/Goal 2/,/^## /p' ${AUTONOMY_LOOP_GOALS})"
grep -q '^DONE when: /tmp/kanban-smoke/inventory.md exists.$' ${AUTONOMY_LOOP_GOALS} || fail "11 (d): the DONE-when line was lost"
# (e) a conflict on one card: the file and the board changed Goal 2's description differently - the file wins, the card
#     shows the file's text again and says so
sed -i 's/^List the workspace, one line per directory.$/List the workspace, two lines per directory./' ${AUTONOMY_LOOP_GOALS}
patch_card "${C2}" '{"description": "List everything."}'
OUT=$(${SYNC} sync 2>&1) || fail "11 (e): ${OUT}"
grep -q '^List the workspace, two lines per directory.$' ${AUTONOMY_LOOP_GOALS} || fail "11 (e): the file did not win the description conflict: $(sed -n '/Goal 2/,/^## /p' ${AUTONOMY_LOOP_GOALS})"
card_field "Goal 2 - the inventory" description | grep -q 'two lines per directory' || fail "11 (e): the card does not show the file's description after the conflict: $(card_field 'Goal 2 - the inventory' description | head -c 200)"
[ "$(comments_with 'the goals file wins')" -ge 1 ] || fail "11 (e): no comment on the card says the goals file won"
# (e2) a goal renamed in the file keeps the existing contract (its new text gets its own card; the old card stays), so
#      a board rename of the old card meanwhile comes back to the file's last text, with a comment
sed -i 's/^- \[ \] open goal C$/- [ ] open goal D/' ${AUTONOMY_LOOP_GOALS}
patch_card "${CB}" '{"title": "open goal E"}'
OUT=$(${SYNC} sync 2>&1) || fail "11 (e2): ${OUT}"
grep -q '^- \[ \] open goal D$' ${AUTONOMY_LOOP_GOALS} || fail "11 (e2): the file changed: $(grep 'open goal' ${AUTONOMY_LOOP_GOALS})"
[ "$(card_field 'open goal C' id)" == "${CB}" ] || fail "11 (e2): the old card did not come back to the file's last title (cards C: $(card_field 'open goal C' id), E: $(card_field 'open goal E' id))"
[ "$(card_field 'open goal D' id)" != "cards=0" ] || fail "11 (e2): the file's renamed goal got no card of its own"
[ "$(comments_with 'the goals file wins')" -ge 2 ] || fail "11 (e2): no comment on the old card says the goals file won"
# (f) the write is one atomic rewrite under the goals lock: with the lock held the sync does not write, and no .tmp is left
( exec 7> ${D}/twoway/goals.lock; flock -x 7; sleep 30 ) & LOCKER=$!
sleep 0.5
patch_card "${C2}" "{\"status_id\": \"$(status_id Done)\"}"
OUT=$(${SYNC} sync 2>&1); RC=$?
kill ${LOCKER} 2>/dev/null; wait ${LOCKER} 2>/dev/null
[ ${RC} -eq 5 ] || fail "11 (f): a sync against a held goals lock exited ${RC}, expected 5 (the lock's own status, never mistaken for an unreachable board): ${OUT}"
echo "${OUT}" | grep -q "goals file is locked" || fail "11 (f): the sync does not say the goals file was locked: ${OUT}"
grep -q '^## Goal 2 - the inventory$' ${AUTONOMY_LOOP_GOALS} || fail "11 (f): the file changed while the lock was held"
[ ! -e ${AUTONOMY_LOOP_GOALS}.tmp ] || fail "11 (f): a temp file was left beside the goals file"
OUT=$(${SYNC} sync 2>&1) || fail "11 (f2): ${OUT}"
grep -q '^## Goal 2 - the inventory \[x\]$' ${AUTONOMY_LOOP_GOALS} || fail "11 (f2): the lock released, the pending Done did not reach the file"
# (g) a card created while the loop is stopped: the goal is added and the card says how to start the loop
touch ${D}/twoway/STOP
NEW2=$(python3 -c 'import uuid; print(uuid.uuid4())')
curl -s -o /dev/null -X POST -H "Authorization: Bearer stub-token" -H "Content-Type: application/json" \
	-d "{\"id\": \"${NEW2}\", \"project_id\": \"${PID11}\", \"title\": \"a goal while the loop is stopped\", \"description\": \"x\", \"status_id\": \"$(status_id 'To do')\"}" \
	"http://127.0.0.1:${BOARD_PORT}/v1/issues"
OUT=$(${SYNC} sync 2>&1) || fail "11 (g): ${OUT}"
grep -q 'a goal while the loop is stopped' ${AUTONOMY_LOOP_GOALS} || fail "11 (g): the goal was not added while the loop is stopped"
[ "$(comments_with 'The autonomy loop is stopped')" -ge 1 ] || fail "11 (g): no comment tells how to start the stopped loop"
rm -f "${D:?}/twoway/STOP"
# a name chosen on the board stays
curl -s -o /dev/null -X PATCH -H "Authorization: Bearer stub-token" -H "Content-Type: application/json" -d '{"name": "My own board"}' "http://127.0.0.1:${BOARD_PORT}/v1/projects/${PID11}"
OUT=$(${SYNC} sync 2>&1) || fail "11 (chosen name): ${OUT}"
[ "$(project_name)" == "My own board" ] || fail "11 (chosen name): a project name chosen on the board was overwritten: $(project_name)"
# the standing (default) goal's card leads with one line and folds the agent's instructions
mkdir -p ${D}/g4
OUT=$(KANBAN_PROJECT=test18-g4 AUTONOMY_LOOP_DIR=${D}/g4 AUTONOMY_LOOP_GOALS=${D}/g4/GOALS.md ${SYNC} sync 2>&1) || fail "11 (standing goal): ${OUT}"
PIDG4=$(python3 -c "import uuid; print(uuid.uuid5(uuid.UUID('403ef658-05ce-59aa-97e8-8aea9ecc4f02'), 'project:test18-g4'))")
DESC=$(board_json | P="${PIDG4}" python3 -c 'import json, os, sys; s = json.load(sys.stdin); print(next(i["description"] for i in s["issues"].values() if i["project_id"] == os.environ["P"]))')
echo "${DESC}" | grep -qx '## Full instructions' || fail "11 (standing goal): the standing goal's card has no '## Full instructions' marker line: $(echo "${DESC}" | head -c 200)"
[ "$(echo "${DESC}" | own_text | head -1 | wc -c)" -lt 300 ] || fail "11 (standing goal): the standing goal's card does not lead with one line"
AFTER=$(echo "${DESC}" | sed -n '/^## Full instructions$/,$p' | sed '1d' | grep -c .)
[ "${AFTER}" -ge 2 ] || fail "11 (standing goal): the full instructions do not follow the marker (${AFTER} non-empty lines after it): $(echo "${DESC}" | head -c 300)"
[ "$(echo "${DESC}" | sed -n '/^## Full instructions$/,$p' | sed '1d' | grep -m1 .)" == "$(echo "${DESC}" | own_text | head -1)" ] || fail "11 (standing goal): the summary is not the first line of the full instructions"
# idempotent: a re-projection is byte-identical, and a round trip of the whole description (the editor saves it all) is no edit
OUT=$(KANBAN_PROJECT=test18-g4 AUTONOMY_LOOP_DIR=${D}/g4 AUTONOMY_LOOP_GOALS=${D}/g4/GOALS.md ${SYNC} sync 2>&1) || fail "11 (G4b): ${OUT}"
DESC2=$(board_json | P="${PIDG4}" python3 -c 'import json, os, sys; s = json.load(sys.stdin); print(next(i["description"] for i in s["issues"].values() if i["project_id"] == os.environ["P"]))')
[ "${DESC}" == "${DESC2}" ] || fail "11 (G4b): re-projecting the standing goal changed its description"
echo "${OUT}" | grep -q "0 created, 0 moved" || fail "11 (G4b): a re-projection moved or created cards: ${OUT}"
# the same shape for a mirrored goal with an outcome and a DONE condition (Goal 1 of the two-way project)
card_field "Goal 1 - the hello file" description | grep -qx '## Full instructions' || fail "11 (G4c): a mirrored goal's multi-line body is not projected as summary + marker + full text"
[ "$(card_field 'Goal 1 - the hello file' description | own_text | head -1)" == "Create /tmp/kanban-smoke/hello.txt with one line." ] || fail "11 (G4c): the mirrored goal's card does not lead with its first line: $(card_field 'Goal 1 - the hello file' description | head -1)"
# a goal removed from the file - the next sync moves its card to In review with one note saying so; a further sync adds
# no second note and the card stays; the goal does not come back into the file. The note count is per card: the same
# sync retires every mirrored card whose goal left the file, and this project has another one (the old card of the goal
# renamed in the file above), so a count over the whole board read two notes - both kanban-sync.py's, not the stub's
printf '\n## Goal 9 - a goal to be removed\nDo the thing.\nDONE when: done.\n' >> ${AUTONOMY_LOOP_GOALS}
OUT=$(${SYNC} sync 2>&1) || fail "11 (removed goal, add): ${OUT}"
RMID=$(card_field 'Goal 9 - a goal to be removed' id); [ -n "${RMID}" ] || fail "11 (removed goal): the goal to be removed got no card"
[ "$(card_field 'Goal 9 - a goal to be removed' status_id)" == "$(status_id 'To do')" ] || fail "11 (removed goal): the new goal's card is not To do"
python3 - "${AUTONOMY_LOOP_GOALS}" << 'PYRM'
import re, sys
p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r"\n## Goal 9 - a goal to be removed\n(?:[^\n]*\n)*?(?=\n## |\Z)", "\n", s)
assert s2 != s, "the section to remove was not found"
open(p, "w").write(s2)
PYRM
grep -q 'Goal 9' ${AUTONOMY_LOOP_GOALS} && fail "11 (removed goal): test setup: the goal is still in the file"
OUT=$(${SYNC} sync 2>&1) || fail "11 (removed goal, remove): ${OUT}"
[ "$(card_field 'Goal 9 - a goal to be removed' status_id)" == "$(status_id 'In review')" ] || fail "11 (removed goal): the removed goal's card is not In review (${OUT})"
[ "$(comments_on "${RMID}" 'Removed from the goals file')" == "1" ] || fail "11 (removed goal): expected one removal note on the card, found $(comments_on "${RMID}" 'Removed from the goals file')"
echo "${OUT}" | grep -qE "[0-9]+ card\(s\) of goals removed from the file -> In review" || fail "11 (removed goal): the summary does not count the removed goal's card: ${OUT}"
grep -q 'Goal 9' ${AUTONOMY_LOOP_GOALS} && fail "11 (removed goal): the removed goal came back into the file (its card is not mirrored any more)"
OUT=$(${SYNC} sync 2>&1) || fail "11 (removed goal, again): ${OUT}"
[ "$(comments_on "${RMID}" 'Removed from the goals file')" == "1" ] || fail "11 (removed goal): a second sync added another removal note ($(comments_on "${RMID}" 'Removed from the goals file'))"
[ "$(card_field 'Goal 9 - a goal to be removed' status_id)" == "$(status_id 'In review')" ] || fail "11 (removed goal): the card left In review on the second sync"
echo "${OUT}" | grep -q "removed from the file" && fail "11 (removed goal): the second sync counted the removed goal again: ${OUT}"
echo "ok 11 - two-way: a card to Done checks the goal off and back; a board-created card becomes a goal in the file's form, keeps its id and stays on top of its column, as does a Slack goal added under its heading above it, no older card's value changing; a title edit renames the goal; a description edit rewrites the outcome lines with DONE-when kept; a conflict: the file wins with a comment; the write waits for the goals lock (exit 2, no .tmp) and lands once it is free; a card created while the loop is stopped says how to start it; the project shows the goal set's name and a name chosen on the board stays; the standing goal's instructions are folded; a checkbox goal's title is not repeated; a goal removed from the file: its card In review with one note, once, and the goal stays out of the file"

# --- 12. the watcher: kanban-sync.py watch pulls the board between fires, never while the loop is FIRING; ui-start.sh
#         started one beside the seed (check 7) ---
WATCH_PID=$(cat ${D}/ui-seed/kanban-watch.pid 2>/dev/null)
{ [ -n "${WATCH_PID}" ] && kill -0 "${WATCH_PID}" 2>/dev/null; } || fail "12: ui-start.sh (check 7) did not start kanban-sync.py watch (pid file ${D}/ui-seed/kanban-watch.pid)"
grep -q "kanban-watch: started" ${D}/ui-start-seed.log || fail "12: ui-start.sh does not say it started the watcher: $(grep kanban ${D}/ui-start-seed.log)"
kill "${WATCH_PID}" 2>/dev/null
echo "FIRING fire=9 started=1" > ${D}/twoway/loop.state
KANBAN_WATCH_INTERVAL=5 setsid nohup ${SYNC} watch > ${D}/watch.log 2>&1 &
echo $! > ${D}/watch.pid
patch_card "${C1}" "{\"status_id\": \"$(status_id Done)\"}"
sleep 8
grep -q '^## Goal 1 - the hello file$' ${AUTONOMY_LOOP_GOALS} || fail "12: the watcher wrote the file while the loop was FIRING: $(grep 'Goal 1' ${AUTONOMY_LOOP_GOALS}); $(cat ${D}/watch.log)"
echo "SLEEPING last_fire=9" > ${D}/twoway/loop.state
for _ in $(seq 1 30); do grep -q '^## Goal 1 - the hello file \[x\]$' ${AUTONOMY_LOOP_GOALS} && break; sleep 0.5; done
grep -q '^## Goal 1 - the hello file \[x\]$' ${AUTONOMY_LOOP_GOALS} || fail "12: the watcher did not pull the board within 15 s of the loop leaving FIRING: $(cat ${D}/watch.log)"
grep -q "watch: from the board: .*done on the board" ${D}/watch.log || fail "12: the watcher does not log what it pulled: $(cat ${D}/watch.log)"
kill "$(cat ${D}/watch.pid)" 2>/dev/null
echo "ok 12 - the watcher pulls the board every KANBAN_WATCH_INTERVAL seconds, never while the loop is FIRING, and ui-start.sh starts it with the board"

# --- 13. the relay (UI_KANBAN_RELAY=true, KANBAN_RELAY_URL): the board route sends /v1/relay/ to it, on its own origin ---
RELAY_PORT=18196
RHOME_PORT=18197
cat > ${D}/stub-relay.py << 'EOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _any(self):
        b = f"relay-stub {self.command} {self.path}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/plain")
        # the relay's own CORS, as upstream's layer sends it: any Origin, with credentials
        self.send_header("Access-Control-Allow-Origin", self.headers.get("Origin") or "*")
        self.send_header("Access-Control-Allow-Credentials", "true")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST = _any
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
setsid nohup python3 ${D}/stub-relay.py ${RELAY_PORT} > ${D}/relay.log 2>&1 &
echo $! > ${D}/relay.pid
# relay_render <dir> [KANBAN_RELAY_URL] - the board's wiring on the relay check's own home port
relay_render()
{
	UI_DIR=$1 UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME=${RHOME_PORT} UI_PORT_VIBE_KANBAN=${RUNNER_PORT} UI_TMUX_AGENT=false \
		UI_VIBE_KANBAN=true UI_PORT_KANBAN_SIGNIN=${SIGNIN_PORT} COMMS_UI_ENABLED=false KANBAN_BOARD_URL="http://127.0.0.1:${BOARD_PORT}" \
		KANBAN_RELAY_URL="$2" KANBAN_AUTH_FILE=/wd/kanban/kanban.env "${AGENT_DIR}/home-render.sh"
}
relay_render ${D}/ui-relay "" > ${D}/render-relay.log 2>&1 || fail "13: home-render.sh without the relay: $(cat ${D}/render-relay.log)"
cp ${D}/ui-relay/home/nginx.conf ${D}/relay-off.conf
relay_render ${D}/ui-relay "http://127.0.0.1:${RELAY_PORT}" > ${D}/render-relay.log 2>&1 || fail "13: home-render.sh with the relay: $(cat ${D}/render-relay.log)"
RCONF=${D}/ui-relay/home/nginx.conf
grep -q "/v1/relay/" ${D}/relay-off.conf && fail "13: without KANBAN_RELAY_URL the configuration has a /v1/relay/ route"
# the relay's only change: the one location, in the board's server block
ADDED=$(diff ${D}/relay-off.conf ${RCONF} | grep -c '^>')
REMOVED=$(diff ${D}/relay-off.conf ${RCONF} | grep -c '^<')
if [ "${REMOVED}" != "0" ] || [ "${ADDED}" != "9" ]; then
	fail "13: the relay changed more than its location ($(diff ${D}/relay-off.conf ${RCONF} | head -20))"
fi
BLOCK=$(awk '/server_name kanban.localhost;/{s=1} s&&/^\t}$/{print; exit} s' ${RCONF})
# shellcheck disable=SC2016
echo "${BLOCK}" | grep -q 'set \$kanban_board' || fail "13: test setup: the first kanban.localhost block is not the board's"
# shellcheck disable=SC2016
for L in 'location ^~ /v1/relay/ {' "set \$kanban_relay http://127.0.0.1:${RELAY_PORT};" 'proxy_pass $kanban_relay;' "include ${D}/ui-relay/home/proxy-common.conf;" \
	'proxy_hide_header Access-Control-Allow-Origin;' 'proxy_hide_header Access-Control-Allow-Credentials;'; do
	echo "${BLOCK}" | grep -qF -- "${L}" || fail "13: the board's server block lacks '${L}' in its relay route"
done
sed -n '/server_name vk-runner.localhost;/,/^\t}/p' ${RCONF} | grep -q "/v1/relay/" && fail "13: the runner's host carries the relay route"
# through the proxy: the relay's path (and query) on the board's origin reaches the relay, without its CORS
setsid nohup nginx -c ${RCONF} -g "daemon off;" > ${D}/nginx-relay.log 2>&1 &
echo $! > ${D}/nginx-relay.pid
relay_call()
{
	# relay_call <method> <path> [<host>] - the answer's headers and body through the relay check's proxy
	for _ in $(seq 1 25); do
		curl -s -D ${D}/relay-hdrs.txt -o ${D}/relay-body.txt --max-time 3 -X "$1" -H "Host: ${3:-kanban.localhost}:${RHOME_PORT}" \
			-H "Origin: http://kanban.localhost:${RHOME_PORT}" "http://127.0.0.1:${RHOME_PORT}$2" && [ -s ${D}/relay-hdrs.txt ] && return 0
		sleep 0.2
	done
	return 1
}
relay_call POST /v1/relay/create/host-1 || fail "13: the relay check's proxy did not answer: $(cat ${D}/nginx-relay.log)"
[ "$(cat ${D}/relay-body.txt)" == "relay-stub POST /v1/relay/create/host-1" ] \
	|| fail "13: POST /v1/relay/create/host-1 on kanban.localhost did not reach the relay as sent: $(head -c 200 ${D}/relay-body.txt)"
grep -qi '^access-control-' ${D}/relay-hdrs.txt && fail "13: the relay's CORS headers reached the board's page: $(grep -i '^access-control' ${D}/relay-hdrs.txt)"
relay_call GET "/v1/relay/h/host-1/s/sess-1/api/info?x=1" || fail "13: no answer for a relay path"
[ "$(cat ${D}/relay-body.txt)" == "relay-stub GET /v1/relay/h/host-1/s/sess-1/api/info?x=1" ] \
	|| fail "13: a relay path lost its tail or query: $(head -c 200 ${D}/relay-body.txt)"
relay_call GET /v1/health || fail "13: no answer for /v1/health"
grep -q "relay-stub" ${D}/relay-body.txt && fail "13: a board path outside /v1/relay/ went to the relay"
relay_call POST /v1/relay/create/host-1 vk-runner.localhost || fail "13: no answer on the runner's host"
grep -q "relay-stub" ${D}/relay-body.txt && fail "13: the runner's host sent /v1/relay/ to the relay"
# PLANTED CONTROL: the configuration without the relay location sends the same request to the board, not the relay
cp ${RCONF} ${D}/relay-on.conf && cp ${D}/relay-off.conf ${RCONF} && nginx -c ${RCONF} -s reload && sleep 1
relay_call POST /v1/relay/create/host-1 || fail "13: no answer from the proxy without its relay route"
grep -q "relay-stub" ${D}/relay-body.txt && fail "13: PLANTED CONTROL BROKEN: without the route the request still reached the relay"
kill "$(cat ${D}/nginx-relay.pid)" "$(cat ${D}/relay.pid)" 2> /dev/null
echo "ok 13 - the relay: KANBAN_RELAY_URL adds exactly the board's /v1/relay/ route (path and query kept, the relay's CORS hidden; not on the runner's host, nothing else changed); PLANTED CONTROL: without it the request goes to the board"

# --- 14. what the agent does next: one card, the goal the loop's next fire starts on (during a fire, the fire's own),
#         leads with one "**Agent:**" line from the loop's state file, its STOP flag and the goal order; no other card
#         has one; the line never reaches the goals file ---
mkdir -p ${D}/cue
cat > ${D}/cue/GOALS.md << 'EOF'
# Goals

## Goal 1 - the first goal [x]
Write one.
DONE when: one exists.

## Goal 2 - the second goal
Write two.
DONE when: two exists.

## Goal 3 - the third goal
Write three.
DONE when: three exists.
EOF
cue_sync()
{
	# cue_sync <action> [args...] - kanban-sync.py on the cue check's own project, goals and loop directory
	KANBAN_PROJECT=test18-cue AUTONOMY_LOOP_DIR=${D}/cue AUTONOMY_LOOP_GOALS=${D}/cue/GOALS.md ${SYNC} "$@"
}
PIDC=$(python3 -c "import uuid; print(uuid.uuid5(uuid.UUID('403ef658-05ce-59aa-97e8-8aea9ecc4f02'), 'project:test18-cue'))")
cues()
{
	# cues - one line per card of the project whose description carries an agent line: <title>|<that line>|<the next
	# non-empty line>, sorted
	board_json | P="${PIDC}" python3 -c '
import json, os, sys
for i in json.load(sys.stdin)["issues"].values():
    if i["project_id"] != os.environ["P"] or "**Agent:**" not in (i["description"] or ""):
        continue
    lines = [l for l in i["description"].splitlines() if l.strip()]
    print("|".join([i["title"], lines[0], lines[1] if len(lines) > 1 else ""]))' | sort
}
# a running loop, as loop.sh's state file names it (its pid, a process named loop.sh)
setsid nohup bash -c 'exec -a /agent/loop.sh sleep 600' > /dev/null 2>&1 &
LOOP_PID=$!
echo ${LOOP_PID} > ${D}/fake-loop.pid
echo "SLEEPING last_fire=3 last_rc=0 last_outcome=ok interval=300s pid=${LOOP_PID} utc=2026-10-14T05:00:00Z" > ${D}/cue/loop.state
OUT=$(cue_sync sync 2>&1) || fail "14: sync: ${OUT}"
[ "$(cues)" == "Goal 2 - the second goal|**Agent:** next - the loop's next fire, at about 05:05 UTC, starts on this goal|Write two." ] \
	|| fail "14 (a): a sleeping loop: not exactly the next goal's card with the next line (its time from the state file) above its own text: [$(cues)]"
CALLS=$(board_json | python3 -c "import json, sys; print(len(json.load(sys.stdin)['calls']))")
OUT=$(cue_sync sync 2>&1) || fail "14: second sync: ${OUT}"
board_json | python3 -c "
import json, sys
sys.exit(1 if any(c.startswith('PATCH') for c in json.load(sys.stdin)['calls'][${CALLS}:]) else 0)" || fail "14 (a): a second sync in the same state rewrote cards: ${OUT}"
echo "FIRING fire=4 pid=${LOOP_PID} utc=2026-10-14T05:06:00Z" > ${D}/cue/loop.state
OUT=$(cue_sync fire-start --fire 4 --started 1000 2>&1) || fail "14: fire-start: ${OUT}"
[ "$(cues)" == "Goal 2 - the second goal|**Agent:** working on this goal now (fire 4, since 05:06 UTC)|Write two." ] \
	|| fail "14 (b): a fire: not exactly the fire's goal's card saying it is worked on now: [$(cues)]"
sed -i 's/^## Goal 2 - the second goal$/## Goal 2 - the second goal [x]/' ${D}/cue/GOALS.md
OUT=$(cue_sync fire-end --fire 4 --started 1000 --rc 0 --duration 5 2>&1) || fail "14: fire-end: ${OUT}"
[ "$(cues)" == "Goal 3 - the third goal|**Agent:** next - the loop's next fire starts on this goal|Write three." ] \
	|| fail "14 (c): after a fire that checked its goal off: the line is not on the next goal's card alone: [$(cues)]"
touch ${D}/cue/STOP
OUT=$(cue_sync sync 2>&1) || fail "14: sync with STOP: ${OUT}"
[ "$(cues)" == "Goal 3 - the third goal|**Agent:** not picked up - the loop is stopped (its STOP flag is set; /agent/loop-start.sh starts it)|Write three." ] \
	|| fail "14 (d): the STOP flag: the next goal's card does not say the loop is stopped: [$(cues)]"
rm -f "${D:?}/cue/STOP"
kill "${LOOP_PID}" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "${LOOP_PID}" 2>/dev/null || break; sleep 0.1; done
echo "SLEEPING last_fire=4 last_rc=0 last_outcome=ok interval=300s pid=${LOOP_PID} utc=2026-10-14T05:07:00Z" > ${D}/cue/loop.state
OUT=$(cue_sync sync 2>&1) || fail "14: sync with no loop process: ${OUT}"
[ "$(cues)" == "Goal 3 - the third goal|**Agent:** not picked up - the loop is not running (/agent/loop-start.sh starts it)|Write three." ] \
	|| fail "14 (d): a state file whose loop process is gone: the next goal's card does not say the loop is not running: [$(cues)]"
# a description edit on the board that kept the agent line: the goals file gets the edit, never the line
C3=$(board_json | P="${PIDC}" python3 -c 'import json, os, sys; print(next(i["id"] for i in json.load(sys.stdin)["issues"].values() if i["project_id"] == os.environ["P"] and i["title"] == "Goal 3 - the third goal"))')
patch_card "${C3}" '{"description": "**Agent:** not picked up - the loop is not running (/agent/loop-start.sh starts it)\n\nWrite three, then a fourth line.\nDONE when: three exists."}'
OUT=$(cue_sync sync 2>&1) || fail "14 (e): sync after the board edit: ${OUT}"
grep -qF "Write three, then a fourth line." ${D}/cue/GOALS.md || fail "14 (e): the board's description edit did not reach the goals file: ${OUT}"
grep -qF "Agent:" ${D}/cue/GOALS.md && fail "14 (e): the agent line reached the goals file: $(grep -F 'Agent:' ${D}/cue/GOALS.md)"
# PLANTED CONTROL: the sync without the cue puts no agent line on any card of a project of its own
python3 - "${SYNC}" ${D}/kanban-sync-nocue.py << 'PYEOF' || fail "14: PLANTED CONTROL BROKEN: agent_cue is not in kanban-sync.py as expected"
import sys
c = open(sys.argv[1]).read()
old = "def agent_cue(cfg, goals, state, phase=None):\n"
assert c.count(old) == 1
open(sys.argv[2], "w").write(c.replace(old, old + "    return None, None\n"))
PYEOF
chmod +x ${D}/kanban-sync-nocue.py
OUT=$(KANBAN_PROJECT=test18-cue-planted AUTONOMY_LOOP_DIR=${D}/cue AUTONOMY_LOOP_GOALS=${D}/cue/GOALS.md ${D}/kanban-sync-nocue.py sync 2>&1) \
	|| fail "14: the planted copy's sync: ${OUT}"
PIDC=$(python3 -c "import uuid; print(uuid.uuid5(uuid.UUID('403ef658-05ce-59aa-97e8-8aea9ecc4f02'), 'project:test18-cue-planted'))")
[ -z "$(cues)" ] || fail "14: PLANTED CONTROL BROKEN: the copy without the cue still put an agent line on a card: [$(cues)]"
echo "ok 14 - what the agent does next: the next goal's card alone leads with one agent line above its own text - next (with the time from the loop's state file), working during the fire on the fire's goal, moved to the next goal after it, stopped under the STOP flag, not running without a loop process - a second sync changes nothing, and a board edit that kept the line writes the goals file without it; PLANTED CONTROL: without the cue no card has the line"

cleanup
echo "Test18 succeeded"
