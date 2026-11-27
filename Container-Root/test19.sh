#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the self-hosted Plane board wiring inside the container (docs/manual/boards.md "Plane board"): the home proxy's
# plane.localhost route and the Plane tile (/agent/home-render.sh), the tile's one-click sign-in
# (/agent/plane-signin.py), the ui-status.sh row, the goal mirror /agent/plane-sync.py and its hooks in the autonomy
# loop (/agent/loop-once.sh, kept in sync with /agent/loop.sh), and the agent's board tool (/agent/board.sh, its
# settings /agent/board-settings.sh). Fully OFFLINE but check 11 (opt-in): Plane is a stub of the API surface
# these scripts use, on a test-local port; claude is a stub; everything binds 127.0.0.1; all state lives under
# /tmp/plane-smoke. The real board (the sidecar containers ./run.sh starts) is checked from the host by
# ./test-plane.sh live. Inside a running instance (a board in its environment) it is skipped with a pointer to ./test.sh.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the scripts parse (bash -n, python3 py_compile)
#   2. home-render.sh with PLANE_URL routes plane.localhost to the board through a variable with a resolver (a board
#      that is down is a 502 on that route, never an nginx that cannot start) and the exact URL /__harness/sign-in to
#      the sign-in helper; the Plane tile (PR #31's tile()) opens in a new tab, links to that URL, names the login FILE
#      and carries a status probe: /__probe/plane on the home listener's loopback-names server, GET-only and
#      status-only, asks the board's /api/instances/ through the resolver variable; the board route and the sign-in
#      keep their redirects on plane.localhost (the board's own URL, Plane's own plane.localhost URLs, a relative
#      Location); with PLANE_LOGIN_BYPASS=false there is no sign-in location and the tile links to /; without
#      PLANE_URL (control: test.sh's container, compose, kubernetes) there is no plane.localhost route and no probe, and
#      the tile says the board is not on this target; with UI_PLANE=false (the shipped default: the board is opt-in,
#      docs/manual/boards.md "Plane board") and a PLANE_URL passed there is no route, no probe, no sign-in location, no Plane tile
#      and no Board tile at all, and the page names no UI_PLANE flag; a PLANE_URL carrying nginx syntax is refused; every
#      config validates
#   3. through the running proxy: plane.localhost reaches the board, /__harness/harness.css on it is the harness
#      stylesheet (nginx's own file, not forwarded to the board), and its pages carry the shared home badge
#      (badge-host.conf's markup, the one every host route carries, with the home page's port) exactly once and end
#      with the script that keeps that badge in the page (Plane's app drops it) and has no badge of its own - PLANTED
#      CONTROLS: a page without the shared badge and a script with its own link fail that check; a sign-in that does not
#      come from the home page on that port (no Referer or Origin, a foreign one, another port, null) is refused 403
#      and signs nobody in, with a page that links the harness home on that port (PLANTED CONTROLS: a bare 403 and a
#      page linking another instance's home fail that check), and every answer forbids framing; from the home page the
#      sign-in answers 302 to the project's
#      board on plane.localhost at the browser's port (PR #31: a host route's redirects stay on its host), with the
#      board's session cookie, host-only (a Domain attribute is stripped) and with the browser's User-Agent
#      passed on; a second click with that cookie reuses the session; a non-loopback Host gets no cookie through the
#      proxy and a 403 from the helper itself; the board's own redirects are re-hosted the same way and a foreign site's
#      is left alone; the tile's probe answers 204 and reaches the board with the browser's address and scheme
#      (X-Forwarded-For, X-Forwarded-Proto: Plane counts anonymous calls per caller, and without them every open home
#      tab's dot spent the budget the sign-in's CSRF request is counted against) - PLANTED CONTROL: a copy of the agent
#      directory whose home-render.sh lacks them (its configuration differs from its unplanted twin by exactly those
#      two lines), served by a second proxy, fails that check; Plane's rate limit on the CSRF request (429 with
#      Retry-After): a short wait is waited out and the request sent once more, so the click signs in; a long one is
#      not waited out and the page names Plane's limit and the wait, never a bare 429; a 429 again after that one retry
#      ends in the same page (one retry, no loop); a Retry-After that is not 1 to 6 digits (a superscript two) is not
#      waited on and the page names the limit, never Python's error text; no rate-limited click signs in; the
#      password is in no response or log; with the board stopped plane.localhost answers 502 and the probe 500 while
#      the home page still answers 200
#   4. ui-status.sh: the plane row is UP only when the board SERVES is_setup_done true; a served false (the setup
#      wizard) and a stopped board are reported as such with rc 1
#   5. plane-sync.py against the stub API: sync creates one work item per goal (checkbox items and "## Goal"
#      headings; a checked one in Done; In Review added once), a second sync creates and moves nothing;
#      fire-start moves the first open goal to In Progress and fire-end to In Review, with one comment carrying the
#      rc and the transcript's end and a "Last fire" note in the description; a repeated fire-end posts no second
#      comment; a fire whose fire-start failed (the board down) and that checked its goal off is still filed under
#      that goal, not the next open one; planted secrets in a fire's transcript (the secrets file's password and API
#      key, a secret-named environment value, a value of a planted AWS credentials file, AWS's documented example
#      credentials as the credentials file and the CLI's JSON print them, a bearer token, Slack/JWT shapes,
#      NAME=value, and a value spanning the cut of the posted end) reach neither a comment, a description nor the
#      state file, and a note an older version left unmasked in the state file is masked by the next sync, in the
#      description and in the state file; the API key is in no output
#   6. loop-once.sh with a stub claude that checks its goal off: the item is In Progress WHILE the fire runs, Done
#      after it, and loop.log has the two PLANE lines; with the board DOWN the same kind of fire still ends rc=0 and
#      loop.log says "not mirrored"; without PLANE_URL no PLANE line and no board call (the pre-board behavior);
#      a board that accepts and never answers holds neither loop-once.sh's fire nor loop.sh's for longer than
#      PLANE_SYNC_TIMEOUT per call (3 s here: each fire ends within 15 s; without the bound it is 20 s or more)
#   7. a refused API key exits 3, a host that is not loopback or a docker network name exits 4 (the key never leaves
#      the host), a missing secrets file exits 4; a board that answers 302 to another host (a stand-in: 127.0.0.2)
#      gets exit 2 and the other host no request, so the API key never follows a redirect
#   8. the start's seed (ui-start.sh -> plane-sync.py seed in the background, the board's first view before any
#      fire): ui-start.sh starts it and nothing else, and does not wait for it; it waits for a board that is down and
#      then mirrors a planted goals
#      file; the next start's seed writes nothing; with no goals file (a new instance) it mirrors the shipped default
#      goals' standing goal - CONTROL: a ui-start.sh without the seed leaves that board without any work item;
#      a fire on the default goals that creates the goals file posts its result on the default goal's work item and
#      Cancels it, which comes back to Todo without the goals file; a refused API key ends the seed at once (3), a
#      board that stays down ends it after PLANE_SEED_WAIT (2)
#   9. the board tool against the stub API: list shows every goal of the goals file in file order with its work item
#      and state, and a goal the mirror has not seen yet; create tracks work as a Todo work item with the tool's own
#      key, NOT a goal: the goals file is unchanged, a fire's start takes the first open goal and no fire or sync
#      moves the item, a second create of the title reuses it, its note is masked; tracked work moves to any state,
#      an unknown state is refused; create --goal adds the goal through goals-add.sh and mirrors it, an option-shaped
#      goal is refused; move G<n> done checks the goal off (the file's mode kept) and its work item reaches Done, open
#      unchecks it, a heading goal's item moved to Done checks the heading off; a direct board write the mirror would
#      fight (a goal's item to In Progress) is refused with nothing written; a comment lands once a day, masked;
#      no goals-file write while the loop is FIRING (5; a call from within the fire itself and a FIRING line with no
#      live process do not hold it), a
#      write waits for the goals lock and gives up after BOARD_LOCK_WAIT (5, nothing written); without a board the
#      goals file only and tracking exits 4; the shipped default goals are listed and never edited
#  10. board-settings.sh adds the allow rule Bash(/agent/board.sh:*) and the deny rules on the tool's files, the
#      mirror's state file and the board's secrets once, beside the user's own rules and keys; copies the usage and
#      references it once from CLAUDE.md, the user's lines kept; a second run changes nothing; a malformed
#      settings.json is left alone (rc 0); startup.sh runs it
#  11. (TEST19_CLAUDE=true, live Bedrock) a headless claude: CONTROL - without the allow rule, dontAsk refuses the
#      board tool; with it the tool runs; in auto mode "update the board" goes through the tool with no permission
#      denial and reaches the stub board; a direct write to the mirror's state file (a Bash redirect) and a Write of
#      the tool itself are refused, both files unchanged

D=/tmp/plane-smoke
rm -rf "${D:?}"
mkdir -p ${D}

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
SYNC=${AGENT_DIR}/plane-sync.py
SIGNIN=${AGENT_DIR}/plane-signin.py

HOME_PORT=18290
BOARD_PORT=18292
DEAD_PORT=18293
SIGNIN_PORT=18294
HANG_PORT=18295
REDIR_PORT=18296
CAPTURE_PORT=18297
PLANTED_PORT=18298
PASSWORD=test19-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
API_KEY=plane_api_test19$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

cleanup()
{
	for P in board nginx nginx2 signin hang loopH redirect; do
		[ -f "${D}/${P}.pid" ] && kill "$(cat "${D}/${P}.pid")" 2>/dev/null
	done
}

fail()
{
	echo "Test19 FAILED: $1"
	cleanup
	exit 1
}

# --- 1. syntax ---
for S in "${AGENT_DIR}/home-render.sh" "${AGENT_DIR}/ui-status.sh" "${AGENT_DIR}/ui-start.sh" "${AGENT_DIR}/loop.sh" "${AGENT_DIR}/loop-once.sh" \
	"${AGENT_DIR}/board.sh" "${AGENT_DIR}/board-settings.sh"; do
	bash -n "${S}" || fail "bash -n ${S}"
done
for P in "${SYNC}" "${SIGNIN}" "${AGENT_DIR}/board.py"; do
	python3 -c "import py_compile, sys; py_compile.compile(sys.argv[1], cfile='${D}/x.pyc', doraise=True)" "${P}" \
		|| fail "python3 py_compile ${P}"
done
echo "ok 1 - syntax"

if ! command -v nginx > /dev/null || ! command -v python3 > /dev/null || ! command -v curl > /dev/null; then
	echo "Test19 skipped: nginx/python3/curl not installed"
	exit 0
fi
# The container ./test.sh starts has a throwaway /wd and no board in its environment. A running instance has its boards
# there (run.sh passes PLANE_URL, and KANBAN_BOARD_URL for the Goals board), so the routes this test renders and counts
# would carry that instance's boards too, and it would fail for a reason that is no defect. In a running instance it
# stops and names the way to run it. A container started with TEST_CONTAINER=true is a test container and always runs it
if [ "${TEST_CONTAINER}" != "true" ] && [ -n "${PLANE_URL}${KANBAN_BOARD_URL}" ]; then
	echo "Test19 skipped: this is a running instance (PLANE_URL or KANBAN_BOARD_URL is set in its environment), not the container ./test.sh starts - run ./test.sh on the host"
	exit 0
fi

# --- the stub Plane: the surface plane-signin.py, plane-sync.py and ui-status.sh use (Plane v1.4.2 behaviour:
# paginated lists, 409 with the id on a repeated external id, X-Api-Key, the CSRF-guarded email sign-in that fails
# without a User-Agent, session cookie session-id, and on request its limit on anonymous calls for the CSRF request:
# 429 with Retry-After in whole seconds, rounded up as Plane's REST framework sends it, so never 0), plus GET /__state
# for the checks below (with the forwarding headers each /api/instances/ request arrived with) ---
cat > ${D}/stub-plane.py << 'EOF'
import json, math, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
EMAIL, PASSWORD, KEY = os.environ["STUB_EMAIL"], os.environ["STUB_PASSWORD"], os.environ["STUB_KEY"]
SETUP = os.environ.get("STUB_SETUP", "true") == "true"
WS, PID = "do-agent-aws", "11111111-2222-3333-4444-555555555555"
S = {"states": [{"id": str(uuid.uuid4()), "name": n, "group": g} for n, g in
                (("Backlog", "backlog"), ("Todo", "unstarted"), ("In Progress", "started"), ("Done", "completed"),
                 ("Cancelled", "cancelled"))],
     "issues": {}, "comments": {}, "calls": [], "sessions": [], "signin_ua": [], "csrf": [], "instances": []}
THROTTLE = {"until": 0.0, "say": None}
def page(rows):
    return {"results": rows, "next_page_results": False, "next_cursor": None}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def reply(self, code, body=None, ctype="application/json", headers=()):
        raw = (json.dumps(body) if ctype == "application/json" else body or "").encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def keyed(self):
        if self.headers.get("X-Api-Key") != KEY:
            self.reply(403, {"detail": "Given API token is not valid"})
            return False
        return True
    def route(self):
        u = urlparse(self.path)
        p = u.path
        base = f"/api/v1/workspaces/{WS}/projects/"
        if p.startswith(base) and p != base:
            return u, p[len(base) + len(PID) + 1:] if p.startswith(base + PID + "/") else None
        return u, p
    def do_GET(self):
        u, rest = self.route()
        if u.path == "/__state":
            return self.reply(200, S)
        if u.path == "/__hide_issues_once":  # the next work item list reads empty, as before a concurrent create
            S["hide_issues"] = True
            return self.reply(200, {})
        if u.path == "/":
            return self.reply(200, "<html><head><title>plane-stub</title></head><body>plane-stub</body></html>", "text/html")
        if u.path == "/__harness/sign-in":
            return self.reply(200, "<html><body>plane-stub-route</body></html>", "text/html")
        if u.path == "/__throttle_csrf":  # the CSRF request answers 429 for the next for= seconds; say= fixes its Retry-After
            q = parse_qs(u.query)
            THROTTLE.update(until=time.time() + float(q.get("for", ["0"])[0]), say=q.get("say", [None])[0])
            return self.reply(200, {})
        if u.path == "/api/instances/":
            S["instances"].append({"ua": self.headers.get("User-Agent"), "xff": self.headers.get("X-Forwarded-For"),
                                   "proto": self.headers.get("X-Forwarded-Proto")})
            return self.reply(200, {"instance": {"is_setup_done": SETUP}})
        if u.path == "/__redirect":  # a board redirect to the Location asked for (check 3: re-hosted on plane.localhost)
            return self.reply(302, "", "text/plain", [("Location", parse_qs(u.query).get("to", ["/"])[0])])
        if u.path == "/auth/get-csrf-token/":
            left = THROTTLE["until"] - time.time()
            if left > 0:
                after = THROTTLE["say"] or "%d" % math.ceil(left)
                S["csrf"].append({"status": 429, "retry_after": after})
                return self.reply(429, {"error_code": 5900, "error_message": "RATE_LIMIT_EXCEEDED"}, headers=[("Retry-After", after)])
            S["csrf"].append({"status": 200})
            return self.reply(200, {"csrf_token": "csrf-1"}, headers=[("Set-Cookie", "csrftoken=csrf-1; Path=/; SameSite=Lax")])
        if u.path == "/api/users/me/":
            cookie = self.headers.get("Cookie", "")
            ok = any(f"session-id={s}" in cookie for s in S["sessions"])
            return self.reply(200 if ok else 401, {"email": EMAIL} if ok else {"detail": "no"})
        if not self.keyed():
            return
        S["calls"].append("GET " + u.path)
        if u.path == f"/api/v1/workspaces/{WS}/projects/":
            return self.reply(200, page([{"id": PID, "identifier": "AGENT", "name": "do agent aws"}]))
        if rest == "states/":
            return self.reply(200, page(S["states"]))
        if rest == "issues/":
            return self.reply(200, page([] if S.pop("hide_issues", False) else list(S["issues"].values())))
        self.reply(404, {"error": "not found"})
    def do_POST(self):
        u, rest = self.route()
        raw = self.body()
        if u.path == "/auth/sign-in/":
            f = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
            if not self.headers.get("User-Agent"):
                return self.reply(500, "users.last_login_uagent may not be null", "text/plain")
            if "csrftoken=csrf-1" not in self.headers.get("Cookie", "") or f.get("csrfmiddlewaretoken") != "csrf-1":
                return self.reply(403, "CSRF", "text/plain")
            if f.get("email") != EMAIL or f.get("password") != PASSWORD:
                return self.reply(302, "", "text/plain", [("Location", "http://plane.localhost/?error_code=5005")])
            sid = "sess-" + uuid.uuid4().hex
            S["sessions"].append(sid)
            S["signin_ua"].append(self.headers.get("User-Agent"))
            return self.reply(302, "", "text/plain", [
                ("Location", "http://plane.localhost" + f.get("next_path", "/")),
                ("Set-Cookie", f"session-id={sid}; Domain=plane.localhost; HttpOnly; Max-Age=604800; Path=/; SameSite=Lax"),
                ("Set-Cookie", "csrftoken=csrf-2; Max-Age=31449600; Path=/; SameSite=Lax")])
        if not self.keyed():
            return
        b = json.loads(raw or b"{}")
        S["calls"].append("POST " + u.path)
        if rest == "states/":
            st = dict(b, id=str(uuid.uuid4()))
            S["states"].append(st)
            return self.reply(200, st)
        if rest == "issues/":
            for i in S["issues"].values():
                if (i["external_source"], i["external_id"]) == (b.get("external_source"), b.get("external_id")):
                    return self.reply(409, {"error": "exists", "id": i["id"]})
            i = dict(b, id=str(uuid.uuid4()), sequence_id=len(S["issues"]) + 1,
                     description_html="<div>" + b.get("description_html", "") + "</div>")
            S["issues"][i["id"]] = i
            return self.reply(201, i)
        if rest and rest.endswith("/comments/"):
            for c in S["comments"].values():
                if c["external_id"] == b.get("external_id"):
                    return self.reply(409, {"error": "exists", "id": c["id"]})
            c = dict(b, id=str(uuid.uuid4()), issue=rest.split("/")[1])
            S["comments"][c["id"]] = c
            return self.reply(201, c)
        self.reply(404, {"error": "not found"})
    def do_PATCH(self):
        u, rest = self.route()
        raw = self.body()
        if not self.keyed():
            return
        S["calls"].append("PATCH " + u.path)
        iid = (rest or "").strip("/").split("/")[-1]
        if not (rest or "").startswith("issues/") or iid not in S["issues"]:
            return self.reply(404, {"error": "not found"})
        b = json.loads(raw or b"{}")
        if "description_html" in b:
            b["description_html"] = "<div>" + b["description_html"] + "</div>"
        S["issues"][iid].update(b)
        self.reply(200, S["issues"][iid])
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF

start_board()
{
	# start_board [setup true|false]
	STUB_EMAIL=agent@test19.local STUB_PASSWORD="${PASSWORD}" STUB_KEY="${API_KEY}" STUB_SETUP="${1:-true}" \
		setsid nohup python3 ${D}/stub-plane.py ${BOARD_PORT} > ${D}/board.log 2>&1 &
	echo $! > ${D}/board.pid
	for _ in $(seq 1 50); do
		curl -s --noproxy '*' -o /dev/null --max-time 1 "http://127.0.0.1:${BOARD_PORT}/api/instances/" && return 0
		sleep 0.2
	done
	fail "stub Plane did not start: $(cat ${D}/board.log)"
}

stop_board()
{
	kill "$(cat ${D}/board.pid)" 2>/dev/null
	sleep 0.5
}

state_json()
{
	curl -s --noproxy '*' "http://127.0.0.1:${BOARD_PORT}/__state"
}

cat > ${D}/plane.env << EOF
PLANE_ADMIN_EMAIL=agent@test19.local
PLANE_ADMIN_PASSWORD=${PASSWORD}
PLANE_API_KEY=${API_KEY}
EOF
chmod 600 ${D}/plane.env

# --- 2. rendering: the board route, the sign-in location, the tile, the controls, the refusal ---
render()
{
	# render <dir> <PLANE_URL> [PLANE_LOGIN_BYPASS] - the defaults of every other UI, test-local ports. UI_PLANE=true is set
	# here: the board is off by default (docs/manual/boards.md "Plane board") and the test container gets the host's value - false
	# unless the host opted in - so this test's Plane renders turn it on themselves
	UI_DIR=$1 UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME=${HOME_PORT} UI_TMUX_AGENT=false COMMS_UI_ENABLED=false UI_PLANE=true \
		PLANE_URL="$2" PLANE_LOGIN_BYPASS="${3:-true}" UI_PORT_PLANE_SIGNIN=${SIGNIN_PORT} \
		PLANE_AUTH_FILE=/wd/plane/plane.env "${AGENT_DIR}/home-render.sh"
}
block()
{
	sed -n '/server_name plane.localhost;/,/^\t}/p' "$1"
}
render ${D}/ui > ${D}/render.log 2>&1 "http://127.0.0.1:${BOARD_PORT}" || fail "home-render.sh (board): $(cat ${D}/render.log)"
CONF=${D}/ui/home/nginx.conf
PAGE=${D}/ui/home/site/index.html
# shellcheck disable=SC2016 # literal nginx variables, not shell expansions
block ${CONF} | grep -qF 'proxy_pass $plane_board;' || fail "plane.localhost does not proxy through the board variable: $(block ${CONF})"
block ${CONF} | grep -qF "set \$plane_board http://127.0.0.1:${BOARD_PORT};" || fail "the board URL is not the one passed"
block ${CONF} | grep -qE '^\s*resolver \S+ valid=10s ipv6=off;' || fail "the board route has no per-request resolver"
block ${CONF} | grep -A2 -F 'location = /__harness/sign-in {' | grep -qF "proxy_pass http://127.0.0.1:${SIGNIN_PORT};" \
	|| fail "the sign-in URL does not go to the sign-in helper"
[ "$(grep -c 'location = /__harness/sign-in' ${CONF})" == "1" ] || fail "the sign-in location is not exactly one, on the plane.localhost route"
TILE=$(grep -F 'data-host="plane"' ${PAGE})
echo "${TILE}" | grep -qF 'data-path="/__harness/sign-in"' || fail "the Plane tile does not link to the sign-in: ${TILE}"
echo "${TILE}" | grep -qE 'target="_blank" rel="(no)?opener"' || fail "the Plane tile does not open in a new tab: ${TILE}"
# the tile's dot: a status probe on the home listener's loopback-names server (server_name _; is PR #31's 421
# catch-all), GET-only and status-only, to the board's /api/instances/ through a resolver variable
echo "${TILE}" | grep -qF 'data-probe="/__probe/plane"' || fail "the Plane tile has no status probe: ${TILE}"
HOME_BLOCK=$(sed -n '/server_name localhost 127.0.0.1 \[::1\]/,/^\t}/p' ${CONF})
PROBE_LOC=$(echo "${HOME_BLOCK}" | sed -n '/location = \/__probe\/plane {/,/^\t\t}$/p')
PROBE_UP=$(echo "${HOME_BLOCK}" | sed -n '/location = \/__probe_up\/plane {/,/^\t\t}$/p')
{ echo "${PROBE_LOC}" | grep -qF 'limit_except GET { deny all; }' && echo "${PROBE_LOC}" | grep -qF 'auth_request /__probe_up/plane;' \
	&& ! echo "${PROBE_LOC}" | grep -q 'proxy_pass'; } || fail "/__probe/plane is not a GET-only, status-only probe: ${PROBE_LOC}"
{ echo "${PROBE_UP}" | grep -qF 'internal;' && echo "${PROBE_UP}" | grep -qE '^\s*resolver \S+ valid=10s ipv6=off;' \
	&& echo "${PROBE_UP}" | grep -qF "set \$plane_probe http://127.0.0.1:${BOARD_PORT}/api/instances/;" \
	&& echo "${PROBE_UP}" | grep -qF 'proxy_pass $plane_probe;' && echo "${PROBE_UP}" | grep -qF 'proxy_set_header Cookie "";'; } \
	|| fail "/__probe_up/plane does not ask the board's /api/instances/ through the resolver variable: ${PROBE_UP}"
# the board route and the sign-in keep their redirects on plane.localhost, at the browser's port
BOARD_ROOT=$(block ${CONF} | sed -n '/location \/ {/,/^\t\t}$/p')
echo "${BOARD_ROOT}" | grep -qF "proxy_redirect http://127.0.0.1:${BOARD_PORT}/ http://\$http_host/;" \
	|| fail "the board route does not rewrite the board proxy's own redirects onto plane.localhost"
echo "${BOARD_ROOT}" | grep -qF 'proxy_redirect ~^https?://plane\.localhost(:[0-9]+)?(/.*)?$ http://$http_host$2;' \
	|| fail "the board route does not put Plane's own plane.localhost redirects on the browser's port"
echo "${BOARD_ROOT}" | grep -qF 'proxy_redirect ~^(/(?![/\x5c]).*)$ http://$http_host$1;' \
	|| fail "the board route does not keep a relative redirect on plane.localhost"
block ${CONF} | sed -n '/location = \/__harness\/sign-in {/,/^\t\t}$/p' | grep -qF 'proxy_redirect ~^(/(?![/\x5c]).*)$ http://$http_host$1;' \
	|| fail "the sign-in's relative redirect is not kept on plane.localhost"
echo "${TILE}" | grep -qF 'the login is in /wd/plane/plane.env' || fail "the Plane tile does not say where the login is"
grep -qF "${PASSWORD}" ${PAGE} ${CONF} && fail "the password reached the home page or the proxy config"
nginx -t -c ${CONF} > ${D}/nginx-t.log 2>&1 || fail "the board-mode nginx.conf does not validate: $(cat ${D}/nginx-t.log)"
render ${D}/ui-nobypass > /dev/null 2>&1 "http://127.0.0.1:${BOARD_PORT}" false || fail "home-render.sh (no bypass)"
grep -qF '__harness/sign-in' ${D}/ui-nobypass/home/nginx.conf && fail "control: PLANE_LOGIN_BYPASS=false still routes the sign-in URL"
grep -F 'data-host="plane"' ${D}/ui-nobypass/home/site/index.html | grep -qF 'data-path="/"' || fail "control: PLANE_LOGIN_BYPASS=false, yet the tile does not link to /"
nginx -t -c ${D}/ui-nobypass/home/nginx.conf > /dev/null 2>&1 || fail "the no-bypass nginx.conf does not validate"
render ${D}/ui-off > /dev/null 2>&1 "" || fail "home-render.sh (no board)"
grep -qF 'plane.localhost' ${D}/ui-off/home/nginx.conf && fail "control: a plane.localhost route was rendered without PLANE_URL"
grep -qF 'not on this target' ${D}/ui-off/home/site/index.html || fail "control: without PLANE_URL the tile does not say the board is not on this target"
grep -qF '__probe/plane' ${D}/ui-off/home/nginx.conf ${D}/ui-off/home/site/index.html && fail "control: a Plane probe was rendered without PLANE_URL"
nginx -t -c ${D}/ui-off/home/nginx.conf > /dev/null 2>&1 || fail "the no-board nginx.conf does not validate"
# the board off by its flag (UI_PLANE=false, the shipped default: the Plane board is opt-in, docs/manual/boards.md "Plane board"), a
# PLANE_URL passed all the same: no plane.localhost route, no probe, no sign-in location, no Plane tile and no Board tile
# at all (nothing of the board is shown), the page names no flag to flip, and the config validates
UI_DIR=${D}/ui-flag-off UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME=${HOME_PORT} UI_TMUX_AGENT=false COMMS_UI_ENABLED=false UI_PLANE=false \
	PLANE_URL="http://127.0.0.1:${BOARD_PORT}" PLANE_LOGIN_BYPASS=true UI_PORT_PLANE_SIGNIN=${SIGNIN_PORT} PLANE_AUTH_FILE=/wd/plane/plane.env \
	"${AGENT_DIR}/home-render.sh" > /dev/null 2>&1 || fail "home-render.sh (UI_PLANE=false)"
grep -qF 'plane.localhost' ${D}/ui-flag-off/home/nginx.conf && fail "UI_PLANE=false: a plane.localhost route was rendered"
grep -qF '__probe/plane' ${D}/ui-flag-off/home/nginx.conf ${D}/ui-flag-off/home/site/index.html && fail "UI_PLANE=false: a Plane probe was rendered"
grep -qF '__harness/sign-in' ${D}/ui-flag-off/home/nginx.conf && fail "UI_PLANE=false: the sign-in location was rendered"
grep -qE '<li class="tile[^>]*><span class="dot"></span>(<span class="title">|<a [^>]*>)Project board \(Plane\)<' ${D}/ui-flag-off/home/site/index.html && fail "UI_PLANE=false: a Plane tile is rendered (the board is opt-in: off, nothing of it is shown)"
grep -qE '<li class="tile[^>]*><span class="dot"></span>(<span class="title">|<a [^>]*>)Board<' ${D}/ui-flag-off/home/site/index.html && fail "UI_PLANE=false: a Board tile is rendered (it reads the Plane board, which is off)"
grep -q 'UI_PLANE' ${D}/ui-flag-off/home/site/index.html && fail "UI_PLANE=false: the page names the UI_PLANE flag"
nginx -t -c ${D}/ui-flag-off/home/nginx.conf > /dev/null 2>&1 || fail "the UI_PLANE=false nginx.conf does not validate"
render ${D}/ui-bad > ${D}/render-bad.log 2>&1 'http://127.0.0.1:1; } server { listen 9' || fail "home-render.sh (bad URL)"
grep -q "PLANE_URL is not a plain http(s)://host\[:port\] URL" ${D}/render-bad.log || fail "a PLANE_URL with nginx syntax was not refused"
grep -qF 'listen 9' ${D}/ui-bad/home/nginx.conf && fail "nginx syntax from PLANE_URL reached the config"
nginx -t -c ${D}/ui-bad/home/nginx.conf > /dev/null 2>&1 || fail "the refused-URL nginx.conf does not validate"
echo "ok 2 - plane.localhost -> the board (variable + resolver), /__harness/sign-in -> the helper; tile: new tab, sign-in link, login file named, status-only probe /__probe/plane through the resolver; redirects kept on plane.localhost; controls: no bypass, no board, nginx syntax refused; all validate"

# --- 3. through the running proxy: the board route and the one-click sign-in ---
start_board
PLANE_URL=http://127.0.0.1:${BOARD_PORT} PLANE_AUTH_FILE=${D}/plane.env PLANE_WORKSPACE=do-agent-aws PLANE_PROJECT=AGENT \
	UI_PORT_PLANE_SIGNIN=${SIGNIN_PORT} setsid nohup python3 "${SIGNIN}" > ${D}/signin.log 2>&1 &
echo $! > ${D}/signin.pid
setsid nohup nginx -c ${CONF} -g "daemon off;" > ${D}/nginx.log 2>&1 &
echo $! > ${D}/nginx.pid
for _ in $(seq 1 25); do
	curl -s --noproxy '*' -o /dev/null --max-time 1 "http://127.0.0.1:${SIGNIN_PORT}/healthz" \
		&& curl -s --noproxy '*' -o /dev/null --max-time 1 "http://127.0.0.1:${HOME_PORT}/" && break
	sleep 0.2
done
H="Host: plane.localhost:${HOME_PORT}"
curl -s --noproxy '*' --max-time 3 -H "${H}" "http://127.0.0.1:${HOME_PORT}/" | grep -q plane-stub || fail "Host plane.localhost does not reach the board through the proxy"
# the harness stylesheet the shared badge links (root-relative, like on every host route) is nginx's own file on this
# route too, never forwarded to the board: forwarded, the link gets the board's answer (Plane's app HTML) and the badge
# on every Plane page goes unstyled
CSS_FILE=${HARNESS_CSS:-/agent/ui/harness.css}
CODE=$(curl -s --noproxy '*' --max-time 3 -H "${H}" -o ${D}/plane-css.out -w '%{http_code}' "http://127.0.0.1:${HOME_PORT}/__harness/harness.css")
[ "${CODE}" == "200" ] && [ -s "${CSS_FILE}" ] && cmp -s ${D}/plane-css.out "${CSS_FILE}" \
	|| fail "the harness stylesheet on plane.localhost is not the stylesheet (http ${CODE}): $(head -c 120 ${D}/plane-css.out)"
PAGE_HTML=$(curl -s --noproxy '*' --max-time 3 -H "${H}" "http://127.0.0.1:${HOME_PORT}/")
# the home badge: the shared one (badge-host.conf, the markup every host route carries) with the home page's port,
# exactly once, and after the end of the document the script that keeps that badge in the page through the app's own
# render and has none of its own
SHARED=$(sed -n "s|^sub_filter '</body>' '\(.*\)</body>';\$|\1|p" ${D}/ui/home/badge-host.conf)
SHARED=${SHARED//\$home_host/localhost:${HOME_PORT}}
badge_problems()
{
	# badge_problems <page html> - one line per way the Plane page's badge differs from the host routes' badge
	[ -n "${SHARED}" ] || echo "badge-host.conf carries no badge markup"
	[ "$(echo "$1" | grep -oF "${SHARED}" | wc -l)" == "1" ] || echo "the shared badge (badge-host.conf's markup, to localhost:${HOME_PORT}) is not in the page exactly once"
	echo "$1" | grep -qF "href=\"//localhost:${HOME_PORT}/\" title=\"do-agent-aws harness home\"" || echo "no badge returns to //localhost:${HOME_PORT}/"
	[ "$(echo "$1" | grep -o 'id="do-agent-aws-home"' | wc -l)" == "$(echo "${SHARED}" | grep -o 'id="do-agent-aws-home"' | wc -l)" ] \
		|| echo "a second badge id beside the shared badge's"
	local KEEP=${1##*</html>}
	case "${KEEP}" in
		"<script>(function(){var me=document.currentScript;"*"</script>") ;;
		*) echo "no badge script after the end of the document" ;;
	esac
	local P
	for P in "#do-agent-aws-home,a[title='do-agent-aws harness home']" 'a.cloneNode(true)' 'document.documentElement' \
		'r.appendChild(b.cloneNode(true))' 'new MutationObserver(put).observe(document,{childList:true,subtree:true})'; do
		echo "${KEEP}" | grep -qF "${P}" || echo "the badge script does not keep the shared badge (no ${P})"
	done
	for P in 'createElement("a")' '&#8962;' 'data-harness-home' 'cssText' 'home</a>'; do
		echo "${KEEP}" | grep -qF "${P}" && echo "the badge script carries a badge of its own (${P})"
	done
}
PROBLEMS=$(badge_problems "${PAGE_HTML}")
[ -z "${PROBLEMS}" ] || fail "the board page's home badge: ${PROBLEMS}"
# PLANTED CONTROLS: the same check on the page without the shared badge, and with the earlier route's own labelled
# link in its script, must fail
PROBLEMS=$(badge_problems "${PAGE_HTML//"${SHARED}"/}")
echo "${PROBLEMS}" | grep -q "is not in the page exactly once" || fail "control: a page without the shared badge passed the badge check"
PROBLEMS=$(badge_problems "${PAGE_HTML%</script>}var a=document.createElement(\"a\");a.innerHTML=\"&#8962; home\";</script>")
echo "${PROBLEMS}" | grep -q "carries a badge of its own" || fail "control: a badge script with a link of its own passed the badge check"
CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 -H "${H}" "http://127.0.0.1:${HOME_PORT}/__harness/home-badge.html")
[ "${CODE}" == "404" ] || fail "the badge snippet is reachable on its own (http ${CODE}); it must be internal"
HOMEREF="http://localhost:${HOME_PORT}/"
refusal_problems()
{
	# refusal_problems <body> <headers> - one line per way a refused sign-in is not a page a person can act on: an
	# HTML page that says to open the board from the harness home page and links to the harness home on THIS port
	grep -qi '^content-type: text/html' "$2" || echo "not an HTML page ($(grep -i '^content-type' "$2" | tr -d '\r'))"
	grep -qF "Open the Plane board from the harness home page" "$1" || echo "no explanation"
	grep -qF "<a class=\"home\" href=\"//localhost:${HOME_PORT}/\">Harness home</a>" "$1" || echo "no Harness home link to //localhost:${HOME_PORT}/"
}
# a request that does not come from the home page on this port never signs in: no Referer/Origin (a bookmark or a
# shared link), a foreign one, the home page on another port, an Origin of null. The refusal stays a 403 that may not be
# framed; one the sign-in gives is a page with a way home. A foreign Origin (and null) is refused before the sign-in runs,
# by the proxy's same-origin gate (test-origin-gate.sh): a browser sends Origin on a script's request or a form post, not
# on a person's click, so that refusal is no page of the sign-in's
for HDR in "X-None: 1" "Referer: https://evil.example/" "Origin: https://evil.example" "Referer: http://localhost:9/" "Origin: null"; do
	CODE=$(curl -s --noproxy '*' -o ${D}/csrf.html -D ${D}/csrf.hdr -w '%{http_code}' --max-time 10 -H "${H}" -H "${HDR}" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in")
	{ [ "${CODE}" == "403" ] && ! grep -qi '^set-cookie' ${D}/csrf.hdr; } || fail "a sign-in with '${HDR}' was not refused (http ${CODE})"
	{ grep -qi "^x-frame-options: DENY" ${D}/csrf.hdr && grep -qi "^content-security-policy: frame-ancestors 'none'" ${D}/csrf.hdr; } \
		|| fail "the refusal for '${HDR}' does not forbid framing"
	case "${HDR}" in Origin:*) continue ;; esac
	PROBLEMS=$(refusal_problems ${D}/csrf.html ${D}/csrf.hdr)
	[ -z "${PROBLEMS}" ] || fail "the refusal for '${HDR}' is not a page with a way home: ${PROBLEMS}"
done
# PLANTED CONTROLS: a bare 403 (the plain-text refusal) and a refusal page that links another instance's home fail it
printf 'refused: open the Plane board from the harness home page; its tile signs you in\n' > ${D}/bare.html
printf 'HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\n' > ${D}/bare.hdr
[ -n "$(refusal_problems ${D}/bare.html ${D}/bare.hdr)" ] || fail "control: a bare 403 passed the refusal check"
sed "s|//localhost:${HOME_PORT}/|//localhost:8000/|" ${D}/csrf.html > ${D}/other.html
refusal_problems ${D}/other.html ${D}/csrf.hdr | grep -q "no Harness home link" || fail "control: a refusal that links another instance's home passed the refusal check"
[ "$(state_json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["sessions"]))')" == "0" ] || fail "a refused request still signed in"
CODE=$(curl -s --noproxy '*' -o /dev/null -D ${D}/signin.hdr -w '%{http_code}' --max-time 10 -A "test19-browser/1.0" -e "${HOMEREF}" -H "${H}" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in")
[ "${CODE}" == "302" ] || fail "the sign-in through the proxy answered ${CODE}: $(cat ${D}/signin.log)"
grep -qi "^location: http://plane.localhost:${HOME_PORT}/do-agent-aws/projects/11111111-2222-3333-4444-555555555555/issues/" ${D}/signin.hdr \
	|| fail "the sign-in does not redirect to the project's board on plane.localhost at the browser's port: $(grep -i '^location' ${D}/signin.hdr)"
grep -qi '^set-cookie: session-id=sess-' ${D}/signin.hdr || fail "the sign-in relayed no session cookie"
grep -qi '^set-cookie:.*domain=' ${D}/signin.hdr && fail "a relayed cookie kept its Domain attribute (must be host-only)"
{ grep -qi "^x-frame-options: DENY" ${D}/signin.hdr && grep -qi '^x-content-type-options: nosniff' ${D}/signin.hdr; } || fail "the sign-in answer does not forbid framing and sniffing"
state_json | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["signin_ua"][-1] == "test19-browser/1.0" else 1)' || fail "the sign-in did not pass the browser's User-Agent on"
COOKIE=$(sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p' ${D}/signin.hdr | tr -d '\r' | paste -sd ';' -)
CODE=$(curl -s --noproxy '*' -o /dev/null -D ${D}/signin2.hdr -w '%{http_code}' --max-time 10 -e "${HOMEREF}" -H "${H}" -H "Cookie: ${COOKIE}" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in")
{ [ "${CODE}" == "302" ] && ! grep -qi '^set-cookie' ${D}/signin2.hdr; } || fail "a second click with a valid session did not reuse it (http ${CODE})"
[ "$(state_json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["sessions"]))')" == "1" ] || fail "a second click signed in again"
for FH in evil.example.com "plane.localhost.evil.example.com:${HOME_PORT}"; do
	CODE=$(curl -s --noproxy '*' -o /dev/null -D ${D}/foreign.hdr -w '%{http_code}' --max-time 5 -e "${HOMEREF}" -H "Host: ${FH}" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in")
	grep -qi '^set-cookie' ${D}/foreign.hdr && fail "Host ${FH} got a cookie through the proxy"
	[ "${CODE}" == "302" ] && fail "Host ${FH} was signed in through the proxy"
done
# asked directly, with a Referer on the Host's port (it passes the home-page check): only the Host check refuses
for FH in "evil.example.com:${SIGNIN_PORT}" "plane.localhost.evil.example.com:${SIGNIN_PORT}"; do
	CODE=$(curl -s --noproxy '*' -o /dev/null -D ${D}/direct.hdr -w '%{http_code}' --max-time 5 -e "http://localhost:${SIGNIN_PORT}/" -H "Host: ${FH}" "http://127.0.0.1:${SIGNIN_PORT}/__harness/sign-in")
	{ [ "${CODE}" == "403" ] && ! grep -qi '^set-cookie' ${D}/direct.hdr; } || fail "the helper itself did not refuse Host ${FH} (http ${CODE})"
done
# the board's own redirects stay on plane.localhost at the browser's port; a foreign site's is left as sent
location_of()
{
	curl -s --noproxy '*' -o /dev/null -D - --max-time 5 -H "${H}" "http://127.0.0.1:${HOME_PORT}/__redirect?to=$1" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p'
}
for PAIR in "/x/1|http://plane.localhost:${HOME_PORT}/x/1" "http://plane.localhost/x/2|http://plane.localhost:${HOME_PORT}/x/2" \
	"http://127.0.0.1:${BOARD_PORT}/x/3|http://plane.localhost:${HOME_PORT}/x/3" "https://github.com/login|https://github.com/login"; do
	L=$(location_of "${PAIR%%|*}")
	[ "${L}" == "${PAIR#*|}" ] || fail "a board redirect to ${PAIR%%|*} became [${L}], not ${PAIR#*|}"
done
# the tile's dot through the proxy: 204, status-only
CODE=$(curl -s --noproxy '*' -o ${D}/probe.out -w '%{http_code} %{size_download}' --max-time 5 "http://127.0.0.1:${HOME_PORT}/__probe/plane")
[ "${CODE}" == "204 0" ] || fail "the Plane tile's probe answered '${CODE}' with the board up, not '204 0'"
CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 -X POST "http://127.0.0.1:${HOME_PORT}/__probe/plane")
[ "${CODE}" == "403" ] || fail "the Plane tile's probe is not GET-only: a POST answered ${CODE}"
# the probe sends the browser's address and scheme to the board (X-Forwarded-For, X-Forwarded-Proto, the values of
# proxy-common.conf): Plane counts anonymous calls per caller (30 a minute) by the X-Forwarded-For its proxy passes on,
# and without them every open home tab's dot counted against the agent container's own address, which the sign-in's
# CSRF request is counted against too
probe_forward_problems()
{
	# probe_forward_problems <nginx.conf> <its home port> <User-Agent> - one line per way the Plane probe does not send
	# the browser's address and scheme: in the rendered location, and as the board received the probe's request
	local UP CODE GOT
	UP=$(sed -n '/server_name localhost 127.0.0.1 \[::1\]/,/^\t}/p' "$1" | sed -n '/location = \/__probe_up\/plane {/,/^\t\t}$/p')
	[ -n "${UP}" ] || echo "the rendered config has no /__probe_up/plane location"
	# shellcheck disable=SC2016 # literal nginx variables, not shell expansions
	echo "${UP}" | grep -qF 'proxy_set_header X-Forwarded-For $remote_addr;' || echo "the rendered /__probe_up/plane sends no X-Forwarded-For"
	# shellcheck disable=SC2016 # literal nginx variables, not shell expansions
	echo "${UP}" | grep -qF 'proxy_set_header X-Forwarded-Proto $scheme;' || echo "the rendered /__probe_up/plane sends no X-Forwarded-Proto"
	CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 -A "$3" "http://127.0.0.1:$2/__probe/plane")
	[ "${CODE}" == "204" ] || echo "the probe answered ${CODE}, not 204"
	GOT=$(state_json | python3 -c 'import json, sys; r = [x for x in json.load(sys.stdin)["instances"] if x["ua"] == sys.argv[1]]; print("%s %s" % (r[-1]["xff"], r[-1]["proto"]) if r else "no request")' "$3")
	[ "${GOT}" == "127.0.0.1 http" ] || echo "the board received the probe with X-Forwarded-For and X-Forwarded-Proto [${GOT}], not [127.0.0.1 http]"
}
PROBLEMS=$(probe_forward_problems ${CONF} ${HOME_PORT} test19-probe/1.0)
[ -z "${PROBLEMS}" ] || fail "the Plane tile's probe does not send the browser's address to the board: ${PROBLEMS//$'\n'/; }"
# PLANTED CONTROL: a copy of the agent directory, so the helpers beside home-render.sh are there as in the image, whose
# home-render.sh probe sends neither header. Its configuration differs from its unplanted twin by exactly those two
# lines, and, served by a second proxy on a port of its own, it fails that check in the rendered location and at the
# board
cp -a "${AGENT_DIR}" ${D}/mutant-agent || fail "could not copy ${AGENT_DIR} for the probe control"
planted_render()
{
	UI_DIR=${D}/ui-probe-planted UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME=${PLANTED_PORT} UI_TMUX_AGENT=false COMMS_UI_ENABLED=false UI_PLANE=true \
		PLANE_URL="http://127.0.0.1:${BOARD_PORT}" UI_PORT_PLANE_SIGNIN=${SIGNIN_PORT} PLANE_AUTH_FILE=/wd/plane/plane.env \
		bash ${D}/mutant-agent/home-render.sh > ${D}/render-planted.log 2>&1 \
		|| fail "the copied home-render.sh did not render: $(tail -3 ${D}/render-planted.log)"
}
planted_render
cp ${D}/ui-probe-planted/home/nginx.conf ${D}/probe-twin.conf || fail "the copied home-render.sh wrote no nginx.conf"
python3 - ${D}/mutant-agent/home-render.sh << 'PY' || fail "could not plant the probe control"
import sys
s = open(sys.argv[1]).read()
lines = "\t\t\tproxy_set_header X-Forwarded-For \\$remote_addr;\n\t\t\tproxy_set_header X-Forwarded-Proto \\$scheme;\n"
assert s.count(lines) == 1, "the Plane probe's two header lines are not where the control expects them"
open(sys.argv[1], "w").write(s.replace(lines, ""))
PY
planted_render
# shellcheck disable=SC2016 # literal nginx variables, not shell expansions
WANT=$(printf '< \t\t\tproxy_set_header X-Forwarded-For $remote_addr;\n< \t\t\tproxy_set_header X-Forwarded-Proto $scheme;')
DIFF=$(diff ${D}/probe-twin.conf ${D}/ui-probe-planted/home/nginx.conf | grep '^[<>]')
[ "${DIFF}" == "${WANT}" ] || fail "the planted configuration differs from its twin by more than the probe's two lines: ${DIFF}"
setsid nohup nginx -c ${D}/ui-probe-planted/home/nginx.conf -g "daemon off;" > ${D}/nginx2.log 2>&1 &
echo $! > ${D}/nginx2.pid
PLANTED_UP=""
for _ in $(seq 1 25); do
	curl -s --noproxy '*' -o /dev/null --max-time 1 "http://127.0.0.1:${PLANTED_PORT}/" && { PLANTED_UP=yes; break; }
	sleep 0.2
done
[ -n "${PLANTED_UP}" ] || fail "the planted control's proxy on port ${PLANTED_PORT} did not answer: $(tail -3 ${D}/nginx2.log)"
PROBLEMS=$(probe_forward_problems ${D}/ui-probe-planted/home/nginx.conf ${PLANTED_PORT} test19-probe-planted/1.0)
kill "$(cat ${D}/nginx2.pid)" 2>/dev/null
{ echo "${PROBLEMS}" | grep -qF "the rendered /__probe_up/plane sends no X-Forwarded-For" \
	&& echo "${PROBLEMS}" | grep -qF "the board received the probe with X-Forwarded-For and X-Forwarded-Proto [None None]" \
	&& ! echo "${PROBLEMS}" | grep -qF "has no /__probe_up/plane location"; } \
	|| fail "PLANTED CONTROL: a probe without X-Forwarded-For passed the check: ${PROBLEMS//$'\n'/; }"
# a missing login file is a local fault: 503 (not the 502 of a failing board), no cookie
mv "${D:?}/plane.env" "${D:?}/plane.env.off"
CODE=$(curl -s --noproxy '*' -o /dev/null -D ${D}/nofile.hdr -w '%{http_code}' --max-time 5 -e "${HOMEREF}" -H "${H}" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in")
mv "${D:?}/plane.env.off" "${D:?}/plane.env"
{ [ "${CODE}" == "503" ] && ! grep -qi '^set-cookie' ${D}/nofile.hdr; } || fail "a sign-in without the login file answered ${CODE}, not 503"
[ "$(state_json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["sessions"]))')" == "1" ] || fail "a refused Host still caused a sign-in"
# Plane's limit on anonymous calls (30 a minute per caller) meets the sign-in at its CSRF request, and Plane's 429
# carries Retry-After in whole seconds. A short wait is waited out and the request sent once more, so the click still
# signs in; a long one is not waited out and the page names the limit and the wait, never a bare 429; a 429 again
# after that one retry ends in the same page (one retry, never a loop)
throttle_csrf()
{
	# throttle_csrf <query> - the stub's CSRF request answers 429 for the next for= seconds (say= fixes its Retry-After)
	curl -s --noproxy '*' -o /dev/null --max-time 3 "http://127.0.0.1:${BOARD_PORT}/__throttle_csrf?$1" || fail "the stub did not take ${1}"
}
csrf_count()
{
	state_json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["csrf"]))'
}
session_count()
{
	state_json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["sessions"]))'
}
rate_page_problems()
{
	# rate_page_problems <page> <the wait it must name> - one line per way the failure page does not explain Plane's limit
	grep -qF "Plane rate-limits the anonymous calls of the harness (30 per minute)" "$1" || echo "it does not name Plane's limit on anonymous calls"
	grep -qF "$2" "$1" || echo "it does not say '${2}'"
	! grep -qF "answered 429" "$1" || echo "it is a bare 429"
}
SIGNIN_PROBLEMS=""
# a short Retry-After, then 200: the request is sent again after the wait and the click signs in
N=$(csrf_count); S0=$(session_count)
throttle_csrf "for=2"
CODE=$(curl -s --noproxy '*' -o ${D}/rl-short.html -D ${D}/rl-short.hdr -w '%{http_code}' --max-time 15 -A "test19-browser/1.0" -e "${HOMEREF}" -H "${H}" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in")
{ [ "${CODE}" == "302" ] && grep -qi '^set-cookie: session-id=sess-' ${D}/rl-short.hdr && [ "$(session_count)" == "$((S0 + 1))" ]; } \
	|| SIGNIN_PROBLEMS+="a short Retry-After then 200 did not sign in (http ${CODE}: $(head -c 300 ${D}/rl-short.html)); "
[ "$(($(csrf_count) - N))" == "2" ] || SIGNIN_PROBLEMS+="a short Retry-After then 200 took $(($(csrf_count) - N)) CSRF requests, not the 429 and one more; "
# a long Retry-After: not waited out (the answer comes within seconds), no session, a page naming the limit and the wait
N=$(csrf_count); S0=$(session_count)
throttle_csrf "for=45"
SECONDS=0
CODE=$(curl -s --noproxy '*' -o ${D}/rl-long.html -D ${D}/rl-long.hdr -w '%{http_code}' --max-time 10 -e "${HOMEREF}" -H "${H}" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in")
ASKED=$(state_json | python3 -c 'import json, sys; print(json.load(sys.stdin)["csrf"][-1].get("retry_after"))')
{ [ "${CODE}" == "502" ] && ! grep -qi '^set-cookie' ${D}/rl-long.hdr && [ "$(session_count)" == "${S0}" ]; } \
	|| SIGNIN_PROBLEMS+="a long Retry-After answered ${CODE} after ${SECONDS} s, not the failure page (502) without a session; "
P=$(rate_page_problems ${D}/rl-long.html "asked to wait ${ASKED} seconds")
[ -z "${P}" ] || SIGNIN_PROBLEMS+="the page for a long wait: ${P//$'\n'/, } ($(head -c 300 ${D}/rl-long.html)); "
[ "$(($(csrf_count) - N))" == "1" ] || SIGNIN_PROBLEMS+="a long Retry-After took $(($(csrf_count) - N)) CSRF requests, not 1 (no retry); "
# a 429 again after the one retry: two CSRF requests, never more, no session, and the failure page with Plane's limit
N=$(csrf_count); S0=$(session_count)
throttle_csrf "for=60&say=1"
CODE=$(curl -s --noproxy '*' -o ${D}/rl-again.html -D ${D}/rl-again.hdr -w '%{http_code}' --max-time 15 -e "${HOMEREF}" -H "${H}" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in")
P=$(rate_page_problems ${D}/rl-again.html "asked to wait 1 second;")
{ [ "${CODE}" == "502" ] && [ -z "${P}" ] && ! grep -qi '^set-cookie' ${D}/rl-again.hdr && [ "$(session_count)" == "${S0}" ]; } \
	|| SIGNIN_PROBLEMS+="a 429 after the retry answered ${CODE} (want the explained 502 page, no cookie, no new session): ${P//$'\n'/, } ($(head -c 300 ${D}/rl-again.html)); "
[ "$(($(csrf_count) - N))" == "2" ] || SIGNIN_PROBLEMS+="a 429 after the retry took $(($(csrf_count) - N)) CSRF requests, not 2 (one retry only); "
# a Retry-After that is not 1 to 6 ASCII digits (a superscript two: str.isdigit() accepts it, int() refuses it) is not
# waited on: one CSRF request, no session, and the page names the limit, never Python's error text
N=$(csrf_count); S0=$(session_count)
throttle_csrf "for=60&say=%C2%B2"
CODE=$(curl -s --noproxy '*' -o ${D}/rl-odd.html -D ${D}/rl-odd.hdr -w '%{http_code}' --max-time 10 -e "${HOMEREF}" -H "${H}" "http://127.0.0.1:${HOME_PORT}/__harness/sign-in")
P=$(rate_page_problems ${D}/rl-odd.html "click the Plane tile again in a minute")
{ [ "${CODE}" == "502" ] && [ -z "${P}" ] && ! grep -qi '^set-cookie' ${D}/rl-odd.hdr && [ "$(session_count)" == "${S0}" ]; } \
	|| SIGNIN_PROBLEMS+="a Retry-After that is not plain digits answered ${CODE} (want the explained 502 page, no cookie, no new session): ${P//$'\n'/, } ($(head -c 300 ${D}/rl-odd.html)); "
[ "$(($(csrf_count) - N))" == "1" ] || SIGNIN_PROBLEMS+="a Retry-After that is not plain digits took $(($(csrf_count) - N)) CSRF requests, not 1 (no wait on it); "
throttle_csrf "for=0"
[ -z "${SIGNIN_PROBLEMS}" ] || fail "the sign-in and Plane's rate limit: ${SIGNIN_PROBLEMS}"
grep -rqF "${PASSWORD}" ${D}/signin.log ${D}/signin.hdr ${D}/nginx.log ${D}/ui/home/nginx-access.log ${D}/rl-*.html ${D}/rl-*.hdr 2>/dev/null && fail "the password reached a log or a response"
stop_board
CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: plane.localhost" "http://127.0.0.1:${HOME_PORT}/")
[ "${CODE}" == "502" ] || fail "a stopped board does not answer 502 through the proxy (http=${CODE})"
CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HOME_PORT}/__probe/plane")
[ "${CODE}" == "500" ] || fail "with the board stopped the Plane tile's probe answered ${CODE}, not 500 (the dot would stay green)"
CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${HOME_PORT}/")
[ "${CODE}" == "200" ] || fail "the home page went down with the board (http=${CODE})"
kill "$(cat ${D}/nginx.pid)" "$(cat ${D}/signin.pid)" 2>/dev/null
echo "ok 3 - through the proxy: plane.localhost -> board, the harness stylesheet served by nginx on the route, with the shared home badge once (badge-host.conf's markup, this port) and the script that keeps it, none of its own (controls: no shared badge, an own link); not from the home page -> 403 with a Harness home link for this port (controls: a bare 403, another instance's link), no session, framing forbidden; sign-in 302 to the board with a host-only session cookie and the browser's User-Agent; a valid session is reused; foreign Hosts get no cookie (helper: 403); the board's redirects kept on plane.localhost; probe 204, GET-only, reaching the board with the browser's X-Forwarded-For and X-Forwarded-Proto (control: a copy without them, differing from its twin by those two lines only, through a second proxy); no login file -> 503; Plane's 429 on the CSRF request: a short Retry-After waited out and the click signs in (2 requests), a long one answered at once with a page naming the limit and the wait, a 429 after the retry -> that page after 2 requests, a Retry-After that is not plain digits -> that page after 1 request, never Python's error text; no rate-limited click signs in; no password in any log; board stopped -> 502 on its route only and probe 500, home 200"

# --- 4. ui-status.sh: the plane row follows the SERVED setup state ---
plane_row()
{
	# every other UI off, PR #31's claude-mem and LogLearner rows, the Agent loop row, the Loop Deck row and the docker
	# spoke's substrate rows included, and the supervisor off (its rows and the spokes' read OFF: with the shipped flags on
	# and no supervisor running they read DOWN and UNKNOWN and set the rc, as a plain docker run of the image showed), so
	# the rc is the plane row's alone
	UI_DIR=${D}/ui UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_HOME=false UI_TMUX_AGENT=false \
		UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_BOARD=false UI_FILES=false UI_CHAT=false UI_LOOP=false UI_LOOP_DECK=false SPOKE_DOCKER=false SUPERVISOR=false \
		UI_PLANE=true PLANE_URL=http://127.0.0.1:${BOARD_PORT} PLANE_LOGIN_BYPASS=false "${AGENT_DIR}/ui-status.sh" > ${D}/status.out 2>&1
	echo "rc=$? $(grep '^plane:' ${D}/status.out)"
}
start_board true
ROW=$(plane_row)
echo "${ROW}" | grep -q '^rc=0 plane: UP http=200 setup_done=true' || fail "ui-status.sh with a set-up board: ${ROW}"
stop_board
start_board false
ROW=$(plane_row)
echo "${ROW}" | grep -q '^rc=1 plane: NOT-SET-UP http=200 setup_done=false' || fail "control: ui-status.sh did not report the setup wizard: ${ROW}"
stop_board
ROW=$(plane_row)
echo "${ROW}" | grep -q '^rc=1 plane: DOWN' || fail "control: ui-status.sh did not report a stopped board: ${ROW}"
echo "ok 4 - ui-status.sh: UP only when the board serves is_setup_done true; the setup wizard and a stopped board -> rc 1"

# --- 5. plane-sync.py against the stub API ---
start_board
export PLANE_URL=http://127.0.0.1:${BOARD_PORT} PLANE_AUTH_FILE=${D}/plane.env PLANE_WORKSPACE=do-agent-aws PLANE_PROJECT=AGENT
export AUTONOMY_LOOP_DIR=${D}/loop AUTONOMY_LOOP_GOALS=${D}/loop/GOALS.md
mkdir -p ${D}/loop
cat > ${AUTONOMY_LOOP_GOALS} << 'EOF'
# Goals
Mark an item done by changing its `- [ ]` to `- [x]`.

```
- [ ] an example inside a code fence, not a goal
```

## Goal 1 - write the hello file
Create /tmp/plane-smoke/hello.txt.
DONE when: the file exists.

## Goals from Slack

- [x] an already finished goal
- [ ] open goal B
EOF
item()
{
	# item <goal title> <field: state|description|count> - read from the stub
	state_json | GOAL="$1" FIELD="$2" python3 -c '
import json, os, sys
s = json.load(sys.stdin)
names = {st["id"]: st["name"] for st in s["states"]}
hits = [i for i in s["issues"].values() if i["name"] == os.environ["GOAL"]]
if os.environ["FIELD"] == "count":
    print(len(hits))
elif len(hits) != 1:
    print("items=%d" % len(hits))
elif os.environ["FIELD"] == "state":
    print(names.get(hits[0]["state"]))
else:
    print(hits[0].get("description_html", ""))'
}
count()
{
	state_json | python3 -c "import json, sys; s = json.load(sys.stdin); print(len(s['$1']) if '$1' != 'patches' else sum(c.startswith('PATCH') for c in s['calls']))"
}
OUT=$(${SYNC} sync 2>&1) || fail "sync: ${OUT}"
[ "$(count issues)" == "3" ] || fail "sync did not create exactly 3 work items (2 open, 1 done; the fenced example is no goal): ${OUT}"
[ "$(item 'an already finished goal' state)" == "Done" ] || fail "a checked goal is not in Done"
[ "$(item 'Goal 1 - write the hello file' state)" == "Todo" ] || fail "a heading goal is not in Todo"
[ "$(state_json | python3 -c 'import json, sys; print(sum(s["name"] == "In Review" for s in json.load(sys.stdin)["states"]))')" == "1" ] || fail "In Review was not added exactly once"
PATCHES=$(count patches)
OUT2=$(${SYNC} sync 2>&1) || fail "second sync: ${OUT2}"
echo "${OUT2}" | grep -q "3 work item(s), 0 created, 0 moved" || fail "a second sync is not idempotent: ${OUT2}"
[ "$(count issues)" == "3" ] || fail "a second sync duplicated work items"
[ "$(count patches)" == "${PATCHES}" ] || fail "a second sync rewrote unchanged work items (Plane's <div> wrapper not recognised)"
[ "$(state_json | python3 -c 'import json, sys; print(sum(s["name"] == "In Review" for s in json.load(sys.stdin)["states"]))')" == "1" ] || fail "a second sync added In Review again"
OUT=$(${SYNC} fire-start --fire 1 2>&1) || fail "fire-start: ${OUT}"
[ "$(item 'Goal 1 - write the hello file' state)" == "In Progress" ] || fail "fire-start did not move the first open goal to In Progress: ${OUT}"
[ "$(item 'open goal B' state)" == "Todo" ] || fail "fire-start moved a goal it does not work on"
echo "transcript line one" > ${D}/fire-1.out
echo "the fire's final words <b>" >> ${D}/fire-1.out
OUT=$(${SYNC} fire-end --fire 1 --rc 0 --duration 7 --out ${D}/fire-1.out 2>&1) || fail "fire-end: ${OUT}"
[ "$(item 'Goal 1 - write the hello file' state)" == "In Review" ] || fail "fire-end did not move a still-open goal to In Review: ${OUT}"
[ "$(count comments)" == "1" ] || fail "fire-end did not post exactly one comment"
state_json | python3 -c "
import json, sys
m = list(json.load(sys.stdin)['comments'].values())[0]['comment_html']
sys.exit(0 if 'rc=0' in m and 'the fire&#x27;s final words &lt;b&gt;' in m and '7s' in m else 1)" || fail "the comment lacks the rc, the duration or the (escaped) transcript"
item 'Goal 1 - write the hello file' description | grep -qF '<strong>Last fire:</strong> fire 1 ended rc=0 after 7s - the goal is still open: In Review. transcript line one' \
	|| fail "the description lacks the last-fire note: $(item 'Goal 1 - write the hello file' description)"
OUT=$(${SYNC} fire-end --fire 1 --rc 0 --duration 7 --out ${D}/fire-1.out 2>&1)
[ "$(count comments)" == "1" ] || fail "a repeated fire-end posted a second comment"
echo "${OUT}" | grep -q 'comment already posted' || fail "a repeated fire-end does not say the comment exists: ${OUT}"
${SYNC} sync > /dev/null 2>&1
item 'Goal 1 - write the hello file' description | grep -qF 'Last fire:</strong> fire 1' || fail "a later sync dropped the last-fire note"
# a fire whose fire-start was not mirrored (the board down) and that checked its goal off ends on that goal, not on
# the next open one
OUT=$(PLANE_URL=http://127.0.0.1:${DEAD_PORT} ${SYNC} fire-start --fire 2 2>&1) && fail "fire-start with the board down answered 0: ${OUT}"
sed -i 's/^## Goal 1 - write the hello file$/## [x] Goal 1 - write the hello file/' ${AUTONOMY_LOOP_GOALS}
COMMENTS=$(count comments)
OUT=$(${SYNC} fire-end --fire 2 --rc 0 --duration 5 --out ${D}/fire-1.out 2>&1) || fail "fire-end after an unmirrored fire-start: ${OUT}"
[ "$(item 'open goal B' state)" == "Todo" ] || fail "fire 2's end was filed under the next open goal: ${OUT}"
[ "$(item 'Goal 1 - write the hello file' state)" == "Done" ] || fail "fire 2's end did not move the goal it started on to Done: ${OUT}"
[ "$(count comments)" == "$((COMMENTS + 1))" ] || fail "fire 2's end did not post its comment: ${OUT}"
item 'open goal B' description | grep -q 'Last fire' && fail "the next open goal got fire 2's last-fire note"
# a fire's transcript is masked before its first line (the note: a description and the state file) and its end (the
# comment) leave plane-sync.py; one value spans the start of the posted end. AWS values: AWS's documented examples
PLANTED=test19-planted-env-token-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
mkdir -p ${D}/aws
printf '[user1]\naws_access_key_id = %s\naws_%s = %s\n' "AKIA""I44QH8DHBEXAMPLE" "secret_access_key" "je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY" \
	> ${D}/aws/credentials
( umask 077; python3 - "${D}/fire-9.out" "${D}/planted.txt" "${PASSWORD}" "${API_KEY}" "${PLANTED}" << 'PY'
import sys
out, listing, password, api_key, planted = sys.argv[1:6]
head = (f"first line with the password {password} and aws_secret" "_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        " Authorization: Bearer test19opaque0123456789abcdefEXAMPLE\n")
end = (" the end of fire 9 \n"
       f"the api key {api_key} and xox" "b-123456789012-abcdefghijklmnop jwt eyJhbGciOiJIUzI1NiJ9." "eyJzdWIiOiJ0ZXN0MTYifQ." "c2lnbmF0dXJldGVzdDE2"
       " MY_API_KEY=test19-assigned-secret\n"
       "aws_session_token = IQoJb3JpZ2luX2VjEXAMPLESESSIONTOKENFORTEST19xyz\n"
       '{"Version": 1, "AccessKeyId": "ASIA' 'IOSFODNN7EXAMPLE", "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzJSONEXAMPLE", '
       '"SessionToken": "IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2JSONSESSIONTOKENEXAMPLE", "Expiration": "2026-10-13T14:00:00Z"}\n'
       "the profile's key is je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY\n"
       "Authorization: Bearer test19tail0123456789abcdefEXAMPLE\n")
end += "x" * (1500 - 20 - len(end))  # the posted end starts 20 characters before the planted value ends
open(out, "w").write(head + "env " + planted + end + "\n")
open(listing, "w").write("\n".join([password, api_key, planted, planted[:-20], planted[-20:],
    "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "test19opaque0123456789abcdefEXAMPLE", "xox" "b-123456789012-abcdefghijklmnop",
    "eyJhbGciOiJIUzI1NiJ9." "eyJzdWIiOiJ0ZXN0MTYifQ." "c2lnbmF0dXJldGVzdDE2", "test19-assigned-secret",
    "IQoJb3JpZ2luX2VjEXAMPLESESSIONTOKENFORTEST19xyz", "ASIA" "IOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzJSONEXAMPLE",
    "IQoJb3JpZ2luX2IQoJb3JpZ2luX2IQoJb3JpZ2luX2JSONSESSIONTOKENEXAMPLE", "je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY",
    "test19tail0123456789abcdefEXAMPLE"]) + "\n")
PY
)
${SYNC} fire-start --fire 9 > /dev/null 2>&1 || fail "fire-start for the transcript check"
OUT=$(TEST19_PLANTED_TOKEN=${PLANTED} AWS_SHARED_CREDENTIALS_FILE=${D}/aws/credentials ${SYNC} fire-end --fire 9 --rc 0 --duration 3 \
	--out ${D}/fire-9.out 2>&1) || fail "fire-end with secrets in its transcript: ${OUT}"
state_json > ${D}/state-after-9.json
LEAKS=$(python3 - "${D}/state-after-9.json" "${D}/loop/plane-sync.state" "${D}/planted.txt" << 'PY'
import html, json, sys
board, state_file, listing = sys.argv[1:4]
s = json.load(open(board))
planted = [l for l in open(listing).read().splitlines() if l]
sinks = {"comment": [html.unescape(c.get("comment_html", "")) for c in s["comments"].values()],
         "description": [html.unescape(i.get("description_html", "")) for i in s["issues"].values()],
         "state file": [open(state_file).read()]}
leaks = [f"{sink}: planted value {n}" for sink, texts in sinks.items() for n, v in enumerate(planted, 1)
         if any(v in t for t in texts)]
last = [html.unescape(c["comment_html"]) for c in s["comments"].values() if "Fire 9" in c.get("comment_html", "")]
if not last or "the end of fire 9" not in last[0] or "[redacted]" not in last[0]:
    leaks.append("fire 9's comment is missing, or lacks its harmless text or the [redacted] marks")
note = [html.unescape(i["description_html"]) for i in s["issues"].values() if "fire 9 ended" in i.get("description_html", "")]
if not note or "[redacted]" not in note[0]:
    leaks.append("fire 9's last-fire note is missing or carries no [redacted] mark")
print("; ".join(leaks))
sys.exit(1 if leaks else 0)
PY
) || fail "a planted secret reached the board or the state file: ${LEAKS}"
# a note an older plane-sync.py left unmasked in the state file is masked before a sync puts it in a description, and
# in the state file itself
python3 - "${D}/loop/plane-sync.state" "${PLANTED}" << 'PY'
import json, sys
path, planted = sys.argv[1:3]
s = json.load(open(path))
s["last_fire"]["open goal B"] = f"fire 8 ended rc=0 after 1s - an older, unmasked note with {planted} in it."
json.dump(s, open(path, "w"))
PY
OUT=$(TEST19_PLANTED_TOKEN=${PLANTED} ${SYNC} sync 2>&1) || fail "sync after an unmasked note: ${OUT}"
{ ! item 'open goal B' description | grep -qF "${PLANTED}" && ! grep -qF "${PLANTED}" ${D}/loop/plane-sync.state \
	&& item 'open goal B' description | grep -qF 'an older, unmasked note with [redacted] in it'; } \
	|| fail "an older unmasked note reached a description or stayed in the state file"
grep -rqF "${API_KEY}" ${D}/loop/plane-sync.state 2>/dev/null && fail "the API key reached the state file"
echo "${OUT}${OUT2}" | grep -qF "${API_KEY}" && fail "the API key is in plane-sync.py output"
echo "ok 5 - sync: 3 work items, In Review added once, idempotent (no PATCH); fire-start: In Progress; fire-end: In Review, one comment (rc, duration, escaped transcript), a last-fire note a later sync keeps; no duplicate comment; an unmirrored fire-start still files the end under its goal; 16 planted transcript secrets in no comment, description or state file"

# --- 6. the loop hooks (loop-once.sh, a stub claude) ---
cat > ${D}/fakeclaude << EOF
#!/bin/bash
# stub claude: record the board while "working", then check the first open goal off
cat > /dev/null
curl -s --noproxy '*' "http://127.0.0.1:${BOARD_PORT}/__state" > ${D}/during-fire.json
sed -i '0,/^- \[ \] open goal B\$/s//- [x] open goal B/' ${D}/loop/GOALS.md
echo "stub fire result: checked off open goal B"
EOF
chmod +x ${D}/fakeclaude
# goal 1 done by hand, so the fire works on "open goal B"
sed -i 's/^## Goal 1 - write the hello file$/## [x] Goal 1 - write the hello file/' ${AUTONOMY_LOOP_GOALS}
SLACK_WATCH_ENABLED=false SLACK_CHAT_ENABLED=false AUTONOMY_LOOP_WORKDIR=${D}/loop CLAUDE_BIN=${D}/fakeclaude \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once1.out 2>&1 || fail "loop-once (board up) exited non-zero: $(cat ${D}/once1.out)"
python3 - "${D}/during-fire.json" << 'EOF' || fail "the work item was not In Progress while the fire ran"
import json, sys
s = json.load(open(sys.argv[1]))
names = {st["id"]: st["name"] for st in s["states"]}
sys.exit(0 if [names[i["state"]] for i in s["issues"].values() if i["name"] == "open goal B"] == ["In Progress"] else 1)
EOF
[ "$(item 'open goal B' state)" == "Done" ] || fail "the work item did not move to Done after the fire checked the goal off"
[ "$(item 'Goal 1 - write the hello file' state)" == "Done" ] || fail "a heading marked [x] is not in Done"
grep -q "FIRE 1 PLANE fire 1 start: 'open goal B' -> In Progress" ${D}/loop/loop.log || fail "loop.log lacks the fire-start PLANE line: $(cat ${D}/loop/loop.log)"
grep -q "FIRE 1 PLANE fire 1 end: 'open goal B' -> Done" ${D}/loop/loop.log || fail "loop.log lacks the fire-end PLANE line: $(cat ${D}/loop/loop.log)"
[ "$(grep -c ' END rc=' ${D}/loop/loop.log)" == "1" ] || fail "the PLANE lines changed the loop's fire count"
# the board is DOWN: the fire must not notice
sed -i 's/^- \[x\] open goal B$/- [ ] open goal B/' ${AUTONOMY_LOOP_GOALS}
SLACK_WATCH_ENABLED=false SLACK_CHAT_ENABLED=false AUTONOMY_LOOP_WORKDIR=${D}/loop CLAUDE_BIN=${D}/fakeclaude \
	PLANE_URL=http://127.0.0.1:${DEAD_PORT} "${AGENT_DIR}/loop-once.sh" > ${D}/once2.out 2>&1 \
	|| fail "a board outage failed the fire: $(cat ${D}/once2.out)"
grep -q "FIRE 2 END rc=0" ${D}/loop/loop.log || fail "the fire with the board down did not end rc=0"
grep -q "FIRE 2 PLANE fire-start not mirrored (rc=2" ${D}/loop/loop.log || fail "loop.log does not say fire-start was not mirrored: $(tail -5 ${D}/loop/loop.log)"
grep -q "FIRE 2 PLANE fire-end not mirrored (rc=2" ${D}/loop/loop.log || fail "loop.log does not say fire-end was not mirrored"
# no PLANE_URL: no PLANE line, no board call (the pre-board loop)
sed -i 's/^- \[x\] open goal B$/- [ ] open goal B/' ${AUTONOMY_LOOP_GOALS}
CALLS=$(state_json | python3 -c "import json, sys; print(len(json.load(sys.stdin)['calls']))")
SLACK_WATCH_ENABLED=false SLACK_CHAT_ENABLED=false AUTONOMY_LOOP_WORKDIR=${D}/loop CLAUDE_BIN=${D}/fakeclaude \
	PLANE_URL='' "${AGENT_DIR}/loop-once.sh" > ${D}/once3.out 2>&1 || fail "loop-once without a board exited non-zero"
grep -q "FIRE 3 PLANE" ${D}/loop/loop.log && fail "a PLANE line was logged without PLANE_URL"
[ "$(state_json | python3 -c "import json, sys; print(len(json.load(sys.stdin)['calls']))")" == "${CALLS}" ] || fail "the board was called without PLANE_URL"
# a board that accepts the connection and never answers: every hook call is cut at PLANE_SYNC_TIMEOUT
python3 -c "import socket, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', ${HANG_PORT})); s.listen(128); time.sleep(900)" > /dev/null 2>&1 &
echo $! > ${D}/hang.pid
fire_seconds()
{
	# fire_seconds <loop.log> <fire> - from its BEGIN line to its fire-end PLANE line (loop.log's UTC timestamps)
	python3 - "$1" "$2" << 'EOF'
import datetime, sys
t = {}
for line in open(sys.argv[1]):
    ts, _, rest = line.partition(" ")
    if rest.startswith(f"FIRE {sys.argv[2]} BEGIN"):
        t["b"] = ts
    elif rest.startswith(f"FIRE {sys.argv[2]} PLANE fire-end"):
        t["e"] = ts
p = lambda s: datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
print(int((p(t["e"]) - p(t["b"])).total_seconds()) if len(t) == 2 else 999)
EOF
}
sed -i 's/^- \[x\] open goal B$/- [ ] open goal B/' ${AUTONOMY_LOOP_GOALS}
SLACK_WATCH_ENABLED=false SLACK_CHAT_ENABLED=false AUTONOMY_LOOP_WORKDIR=${D}/loop CLAUDE_BIN=${D}/fakeclaude \
	PLANE_URL=http://127.0.0.1:${HANG_PORT} PLANE_SYNC_TIMEOUT=3 "${AGENT_DIR}/loop-once.sh" > ${D}/once4.out 2>&1 \
	|| fail "a hanging board failed the fire: $(cat ${D}/once4.out)"
{ grep -q "FIRE 4 PLANE fire-start not mirrored (rc=124" ${D}/loop/loop.log && grep -q "FIRE 4 PLANE fire-end not mirrored (rc=124" ${D}/loop/loop.log \
	&& grep -q "FIRE 4 END rc=0" ${D}/loop/loop.log; } || fail "loop-once against a hanging board: $(grep 'FIRE 4' ${D}/loop/loop.log | tail -4)"
T4=$(fire_seconds ${D}/loop/loop.log 4)
[ "${T4}" -lt 15 ] || fail "a hanging board held loop-once.sh's fire for ${T4}s (PLANE_SYNC_TIMEOUT=3 per call)"
# loop.sh's copy of the hook, one fire in its own loop directory, then the STOP flag
mkdir -p ${D}/loopH
sed -i 's/^- \[x\] open goal B$/- [ ] open goal B/' ${AUTONOMY_LOOP_GOALS}
SLACK_WATCH_ENABLED=false SLACK_CHAT_ENABLED=false CLAUDE_BIN=${D}/fakeclaude AUTONOMY_LOOP_DIR=${D}/loopH \
	AUTONOMY_LOOP_WORKDIR=${D}/loop AUTONOMY_LOOP_INTERVAL=2 PLANE_URL=http://127.0.0.1:${HANG_PORT} PLANE_SYNC_TIMEOUT=3 \
	"${AGENT_DIR}/loop.sh" > ${D}/loopH.out 2>&1 &
echo $! > ${D}/loopH.pid
for _ in $(seq 1 80); do
	grep -q "FIRE 1 PLANE fire-end" ${D}/loopH/loop.log 2>/dev/null && break
	sleep 0.5
done
touch ${D}/loopH/STOP
for _ in $(seq 1 40); do
	grep -q "STOPPED" ${D}/loopH/loop.state 2>/dev/null && break
	sleep 0.5
done
kill "$(cat ${D}/loopH.pid)" "$(cat ${D}/hang.pid)" 2>/dev/null
{ grep -q "FIRE 1 PLANE fire-start not mirrored (rc=124" ${D}/loopH/loop.log && grep -q "FIRE 1 PLANE fire-end not mirrored (rc=124" ${D}/loopH/loop.log \
	&& grep -q "FIRE 1 END rc=0" ${D}/loopH/loop.log; } || fail "loop.sh against a hanging board: $(tail -n 5 ${D}/loopH/loop.log ${D}/loopH.out 2>&1)"
TL=$(fire_seconds ${D}/loopH/loop.log 1)
[ "${TL}" -lt 15 ] || fail "a hanging board held loop.sh's fire for ${TL}s (PLANE_SYNC_TIMEOUT=3 per call)"
grep -rqF "${API_KEY}" ${D}/loop/loop.log ${D}/loop/plane-sync.log ${D}/loopH/loop.log ${D}/loopH/plane-sync.log ${D}/once1.out ${D}/once2.out 2>/dev/null && fail "the API key reached a loop log"
echo "ok 6 - loop-once: In Progress during the fire, Done after; board down -> fire rc=0 + 'not mirrored'; no PLANE_URL -> no PLANE line, no call; a hanging board: loop-once's fire ${T4}s, loop.sh's ${TL}s, both rc=0 + 'not mirrored (rc=124)'"

# --- 7. refusals ---
sed "s/^PLANE_API_KEY=.*/PLANE_API_KEY=plane_api_wrong/" ${D}/plane.env > ${D}/wrong.env
OUT=$(PLANE_AUTH_FILE=${D}/wrong.env ${SYNC} sync 2>&1)
[ $? -eq 3 ] || fail "a refused API key does not exit 3: ${OUT}"
OUT=$(PLANE_URL=http://board.example.com ${SYNC} sync 2>&1)
[ $? -eq 4 ] || fail "a non-private board host does not exit 4: ${OUT}"
echo "${OUT}" | grep -q "refusing PLANE_URL host 'board.example.com'" || fail "the refusal does not name the host: ${OUT}"
OUT=$(PLANE_URL=http://plane-proxy:80 PLANE_AUTH_FILE=${D}/missing.env ${SYNC} sync 2>&1)
[ $? -eq 4 ] || fail "a missing secrets file does not exit 4: ${OUT}"
# a board that redirects every request to another host: the key must not follow (the other host is 127.0.0.2, a
# loopback address that stands in for any host but the board's)
python3 - ${REDIR_PORT} ${CAPTURE_PORT} ${D}/captured.log > /dev/null 2> ${D}/redirect-stub.err << 'EOF' &
import sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
redir, capture, log = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
class Redirect(BaseHTTPRequestHandler):
    def answer(self):
        self.send_response(302)
        self.send_header("Location", f"http://127.0.0.2:{capture}/capture{self.path}")
        self.end_headers()
    do_GET = do_POST = do_PATCH = answer
    def log_message(self, *a):
        pass
class Capture(BaseHTTPRequestHandler):
    def answer(self):
        with open(log, "a") as f:
            f.write(f"{self.command} {self.path} api-key={'yes' if self.headers.get('X-Api-Key') else 'no'}\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"results": []}')
    do_GET = do_POST = do_PATCH = answer
    def log_message(self, *a):
        pass
servers = [ThreadingHTTPServer(("127.0.0.1", redir), Redirect), ThreadingHTTPServer(("127.0.0.2", capture), Capture)]
for s in servers[1:]:
    threading.Thread(target=s.serve_forever, daemon=True).start()
servers[0].serve_forever()
EOF
echo $! > ${D}/redirect.pid
# both of the stub's ports answer before the control's probe: under host load the stub can take seconds to start, which
# is a wait, not a failure; a stub that never answers fails here naming the port, with the stub's own stderr
stub_up()
{
	for _ in $(seq 1 50); do
		curl -s --noproxy '*' -o /dev/null --max-time 1 "$1" && return 0
		sleep 0.2
	done
	return 1
}
stub_err() { tail -5 "${D}/redirect-stub.err" 2> /dev/null | tr '\n' ' '; }
stub_up "http://127.0.0.1:${REDIR_PORT}/" \
	|| fail "the control failed: the stand-in board (127.0.0.1:${REDIR_PORT}) never answered; the stub's stderr: $(stub_err)"
stub_up "http://127.0.0.2:${CAPTURE_PORT}/ready" \
	|| fail "the control failed: the stand-in other host (127.0.0.2:${CAPTURE_PORT}) never answered; the stub's stderr: $(stub_err)"
CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.2:${CAPTURE_PORT}/ready")
[ "${CODE}" == "200" ] || fail "the control failed: the stand-in other host (127.0.0.2:${CAPTURE_PORT}) does not answer (http ${CODE}); the stub's stderr: $(stub_err)"
rm -f "${D:?}/captured.log"
OUT=$(PLANE_URL=http://127.0.0.1:${REDIR_PORT} ${SYNC} sync 2>&1)
RC=$?
[ ! -s ${D}/captured.log ] || fail "the API key followed a redirect to another host: $(head -3 ${D}/captured.log | tr '\n' ' ')"
[ ${RC} -eq 2 ] || fail "a board that answers 302 does not exit 2 (rc ${RC}): ${OUT}"
echo "${OUT}" | grep -q "a redirect is never followed" || fail "the refusal does not say why: ${OUT}"
kill "$(cat ${D}/redirect.pid)" 2>/dev/null
echo "ok 7 - refused API key -> 3, non-private host -> 4, missing secrets file -> 4; a 302 to another host -> 2, the other host got no request"

# --- 8. the start's seed: ui-start.sh -> plane-sync.py seed, the board's first view before any fire ---
# every UI off but the board's seed (PLANE_LOGIN_BYPASS=false: no sign-in helper), against a fresh stub board (its
# state is in memory) that is DOWN while the container "starts"
ui_start_seed()
{
	# ui_start_seed <ui-start.sh> <ui dir> - the container start, its output in <ui dir>.log
	mkdir -p "$2"
	UI_DIR=$2 UI_LISTEN_HOST=127.0.0.1 UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false \
		UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_BOARD=false UI_FILES=false UI_LOOP_DECK=false UI_CHAT=false UI_HOME=false PLANE_LOGIN_BYPASS=false \
		UI_LOOP=false SPOKE_DOCKER=false UI_PLANE=true PLANE_SEED_WAIT=60 "$1" > "$2.log" 2>&1
}
seed_done()
{
	# seed_done <ui dir> - the seed's exit status once it ended (its .done file; waits up to 30 s)
	for _ in $(seq 1 60); do [ -s "$1/plane-seed.done" ] && break; sleep 0.5; done
	cat "$1/plane-seed.done" 2>/dev/null
}
writes()
{
	state_json | python3 -c "import json, sys; print(sum(not c.startswith('GET') for c in json.load(sys.stdin)['calls']))"
}
stop_board
export AUTONOMY_LOOP_DIR=${D}/seed AUTONOMY_LOOP_GOALS=${D}/seed/GOALS.md AUTONOMY_LOOP_DEFAULT_GOALS=${AGENT_DIR}/goals-default.md
mkdir -p ${D}/seed
cat > ${AUTONOMY_LOOP_GOALS} << 'EOF'
## Goal 1 - the planted goal of the start seed
Planted by test19 check 8.

- [x] a planted goal that is done
EOF
T0=$(date +%s)
ui_start_seed "${AGENT_DIR}/ui-start.sh" ${D}/ui-seed1 || fail "ui-start.sh with the board down: $(cat ${D}/ui-seed1.log)"
[ $(( $(date +%s) - T0 )) -le 10 ] || fail "ui-start.sh waited for the board (the seed must run in the background)"
grep -q "plane-seed: started" ${D}/ui-seed1.log || fail "ui-start.sh did not start the board's seed: $(cat ${D}/ui-seed1.log)"
# the seed is all this start starts: every other UI is off, so the check leaves no worker or dashboard running in the
# test container (claude-mem and LogLearner start by default)
STARTED=$(grep -oE '^[a-z0-9-]+: started' ${D}/ui-seed1.log | sort -u | tr '\n' ' ')
[ "${STARTED}" == "plane-seed: started " ] || fail "the seed check's ui-start.sh started more than the board's seed: ${STARTED}"
sleep 3
[ -e ${D}/ui-seed1/plane-seed.done ] && fail "with the board down the seed ended instead of waiting: $(cat ${D}/ui-seed1/plane-seed.log)"
start_board
[ "$(seed_done ${D}/ui-seed1)" == "0" ] || fail "the seed did not end rc=0 within 30 s of the board coming up: $(cat ${D}/ui-seed1/plane-seed.log)"
SEED_LOG=$(cat ${D}/ui-seed1/plane-seed.log)
echo "${SEED_LOG}" | grep -q "trying again every 2s for up to 60s" || fail "the seed does not say it waited for the board: ${SEED_LOG}"
echo "${SEED_LOG}" | grep -qxF "seed: 2 work item(s), 2 created, 0 moved" || fail "the seed did not mirror the planted goals file: ${SEED_LOG}"
[ "$(item 'Goal 1 - the planted goal of the start seed' state)" == "Todo" ] || fail "the planted goal's work item is not in Todo"
[ "$(item 'a planted goal that is done' state)" == "Done" ] || fail "the planted checked goal's work item is not in Done"
# the next start's seed creates, moves and rewrites nothing
WRITES=$(writes)
ui_start_seed "${AGENT_DIR}/ui-start.sh" ${D}/ui-seed2 || fail "the second ui-start.sh: $(cat ${D}/ui-seed2.log)"
[ "$(seed_done ${D}/ui-seed2)" == "0" ] || fail "the second seed did not end rc=0: $(cat ${D}/ui-seed2/plane-seed.log)"
grep -qxF "seed: 2 work item(s), 0 created, 0 moved" ${D}/ui-seed2/plane-seed.log || fail "a second seed is not idempotent: $(cat ${D}/ui-seed2/plane-seed.log)"
[ "$(writes)" == "${WRITES}" ] && [ "$(count issues)" == "2" ] || fail "a second seed wrote to the board or duplicated a work item"
# a new instance has no goals file: its seed mirrors the shipped default goals, the ones the loop fires on then. The
# CONTROL first: a ui-start.sh copy without the seed leaves that board empty until a fire (none with Slack off), so
# the board shows no work item from a goal
stop_board
start_board
rm -f "${AUTONOMY_LOOP_GOALS:?}"
STANDING="Standing goal - handle the Slack inbox handed to this fire"
grep -qxF "## ${STANDING}" "${AUTONOMY_LOOP_DEFAULT_GOALS}" || fail "the shipped default goals have no '## ${STANDING}' heading"
python3 - "${AGENT_DIR}/ui-start.sh" ${D}/ui-start-noseed.sh << 'EOF' || fail "could not plant the control"
import sys
s = open(sys.argv[1]).read()
a = s.index('if [ "${UI_PLANE:-false}" == "true" ] && [ -n "${PLANE_URL}" ]; then\n\trm -f "${UI_DIR:?}/plane-seed.done"')
open(sys.argv[2], "w").write(s[:a] + s[s.index("\nfi\n", a) + 4:])
EOF
chmod +x ${D}/ui-start-noseed.sh
ui_start_seed ${D}/ui-start-noseed.sh ${D}/ui-noseed || fail "control: the ui-start.sh copy failed: $(cat ${D}/ui-noseed.log)"
grep -q "plane-seed" ${D}/ui-noseed.log && fail "control: the ui-start.sh copy still starts the seed"
sleep 5
[ "$(count issues)" == "0" ] || fail "control: without the seed the new board has work items"
ui_start_seed "${AGENT_DIR}/ui-start.sh" ${D}/ui-seed3 || fail "ui-start.sh on a new instance: $(cat ${D}/ui-seed3.log)"
[ "$(seed_done ${D}/ui-seed3)" == "0" ] || fail "the new instance's seed did not end rc=0: $(cat ${D}/ui-seed3/plane-seed.log)"
grep -qxF "seed: 1 work item(s), 1 created, 0 moved; from the default goals ${AUTONOMY_LOOP_DEFAULT_GOALS} (no goals file yet)" \
	${D}/ui-seed3/plane-seed.log || fail "the seed did not mirror the default goals: $(cat ${D}/ui-seed3/plane-seed.log)"
[ "$(count issues)" == "1" ] && [ "$(item "${STANDING}" state)" == "Todo" ] || fail "the new board does not show the standing goal in Todo"
item "${STANDING}" description | grep -qF "the shipped default goals the loop fires on while there is no goals file" \
	|| fail "the standing goal's work item does not say where it comes from"
# a seed that overlaps a fire (a start's seed and the loop's first fire): the work item the fire created meanwhile keeps
# the fire's state - the stub hides the work items from the seed's read once, so the seed's create answers 409
OUT=$(${SYNC} fire-start --fire 7 2>&1) || fail "fire-start before the overlapping seed: ${OUT}"
curl -s --noproxy '*' -o /dev/null --max-time 3 "http://127.0.0.1:${BOARD_PORT}/__hide_issues_once"
OUT=$(${SYNC} seed 2>&1) || fail "the overlapping seed: ${OUT}"
[ "$(item "${STANDING}" state)" == "In Progress" ] && [ "$(count issues)" == "1" ] \
	|| fail "a seed overlapping a fire moved the fire's work item to $(item "${STANDING}" state) (or duplicated it): ${OUT}"
# a fire on the default goals that creates the goals file (a goal arrived in Slack): its result goes on the default
# goal's work item, which moves to Cancelled; the new goal gets its own work item
OUT=$(${SYNC} fire-start --fire 1 2>&1) || fail "fire-start on the default goals: ${OUT}"
[ "$(item "${STANDING}" state)" == "In Progress" ] || fail "a fire on the default goals did not move the standing goal to In Progress: ${OUT}"
printf '## Goal 1 - a goal stated in Slack\n' > ${AUTONOMY_LOOP_GOALS}
echo "stub fire result: wrote the goals file" > ${D}/seed/fire-1.out
OUT=$(${SYNC} fire-end --fire 1 --rc 0 --duration 4 --out ${D}/seed/fire-1.out 2>&1) || fail "fire-end that created the goals file: ${OUT}"
echo "${OUT}" | grep -qF "1 work item(s) of the default goals -> Cancelled, rc=0 commented" || fail "fire-end: ${OUT}"
[ "$(item "${STANDING}" state)" == "Cancelled" ] || fail "the default goal's work item is not Cancelled once the goals file exists"
[ "$(item 'Goal 1 - a goal stated in Slack' state)" == "Todo" ] || fail "the goals file's goal has no work item in Todo"
state_json | python3 -c "
import json, sys
s = json.load(sys.stdin)
ids = [i['id'] for i in s['issues'].values() if i['name'] == sys.argv[1]]
c = [c['comment_html'] for c in s['comments'].values() if c['issue'] == ids[0]]
sys.exit(0 if len(c) == 1 and 'created the goals file' in c[0] and 'wrote the goals file' in c[0] else 1)" "${STANDING}" \
	|| fail "the fire's result is not on the default goal's work item"
# without the goals file again the loop fires on the default goals again: their work item comes back to Todo
rm -f "${AUTONOMY_LOOP_GOALS:?}"
OUT=$(${SYNC} sync 2>&1) || fail "sync without the goals file: ${OUT}"
[ "$(item "${STANDING}" state)" == "Todo" ] || fail "a Cancelled default goal did not come back to Todo: ${OUT}"
# a refused API key ends the seed at once; a board that stays down ends it after PLANE_SEED_WAIT
T0=$(date +%s)
OUT=$(PLANE_AUTH_FILE=${D}/wrong.env ${SYNC} seed --done ${D}/seed/wrong.done 2>&1)
[ $? -eq 3 ] && [ "$(cat ${D}/seed/wrong.done)" == "3" ] && [ $(( $(date +%s) - T0 )) -le 5 ] \
	|| fail "a refused API key did not end the seed at once with 3: ${OUT}"
T0=$(date +%s)
OUT=$(PLANE_URL=http://127.0.0.1:${DEAD_PORT} PLANE_SEED_WAIT=3 ${SYNC} seed --done ${D}/seed/down.done 2>&1)
[ $? -eq 2 ] && [ "$(cat ${D}/seed/down.done)" == "2" ] && [ $(( $(date +%s) - T0 )) -le 10 ] \
	&& echo "${OUT}" | grep -q "still, after waiting 3s (PLANE_SEED_WAIT)" || fail "a board that stays down did not end the seed after PLANE_SEED_WAIT with 2: ${OUT}"
grep -rqF "${API_KEY}" ${D}/ui-seed1 ${D}/ui-seed2 ${D}/ui-seed3 ${D}/seed 2>/dev/null && fail "the API key reached a seed log or the state file"
echo "ok 8 - the start's seed: in the background (ui-start.sh ends at once), waits for a board that is down, mirrors the planted goals file (2 work items), a second start writes nothing; a new instance shows the default goals' standing goal (control: without the seed the board stays empty), a seed overlapping a fire keeps the fire's state; a default-goal fire that creates the goals file comments on that item and Cancels it, and it comes back without the file; a refused key ends the seed at once (3), a board that stays down after PLANE_SEED_WAIT (2)"

# --- 9. the board tool (/agent/board.sh) against the stub API ---
BOARD=${AGENT_DIR}/board.sh
stop_board
start_board
export AUTONOMY_LOOP_DIR=${D}/bt AUTONOMY_LOOP_GOALS=${D}/bt/GOALS.md AUTONOMY_LOOP_DEFAULT_GOALS=${AGENT_DIR}/goals-default.md
mkdir -p ${D}/bt
cat > ${AUTONOMY_LOOP_GOALS} << 'GOALS'
# Goals

## Goal 1 - the planted heading goal
DONE when: test19 says so.

## Goals from Slack

- [ ] the planted open goal
- [x] the planted done goal
GOALS
chmod 640 ${AUTONOMY_LOOP_GOALS}
sum()
{
	sha256sum "$1" | cut -d' ' -f1
}
iid()
{
	# iid <title> - the stub's AGENT-<n> of the one work item with that title
	state_json | GOAL="$1" python3 -c '
import json, os, sys
hits = [i for i in json.load(sys.stdin)["issues"].values() if i["name"] == os.environ["GOAL"]]
print("AGENT-%d" % hits[0]["sequence_id"] if len(hits) == 1 else "items=%d" % len(hits))'
}
patched()
{
	# patched <AGENT-n> - how many PATCH calls went to that work item
	state_json | REF="$1" python3 -c '
import json, os, sys
s = json.load(sys.stdin)
ids = [i["id"] for i in s["issues"].values() if "AGENT-%d" % i["sequence_id"] == os.environ["REF"]]
print(sum(c.startswith("PATCH") and ids[0] in c for c in s["calls"]))'
}
OUT=$(${SYNC} sync 2>&1) || fail "board tool: the first sync: ${OUT}"
# list: every goal of the goals file in file order, with its work item and its state
OUT=$(${BOARD} list 2>&1) || fail "board.sh list: ${OUT}"
echo "${OUT}" | grep -qE "^  G1 +\[ \]  $(iid 'Goal 1 - the planted heading goal') +Todo +Goal 1 - the planted heading goal$" \
	&& echo "${OUT}" | grep -qE "^  G2 +\[ \]  $(iid 'the planted open goal') +Todo +the planted open goal$" \
	&& echo "${OUT}" | grep -qE "^  G3 +\[x\]  $(iid 'the planted done goal') +Done +the planted done goal$" \
	|| fail "board.sh list does not show the planted goals with their work items and states: ${OUT}"
# a goal the mirror has not seen yet is listed from the file (the list reads the goals file, not only the board)
printf -- '- [ ] a goal the mirror has not seen\n' >> ${AUTONOMY_LOOP_GOALS}
${BOARD} list 2>&1 | grep -qE '^  G4 +\[ \]  - +not on the board yet a goal the mirror has not seen$' \
	|| fail "board.sh list does not show a goal that is only in the goals file: $(${BOARD} list 2>&1)"
# create: TRACKED work - a work item that is not a goal; the goals file is not touched and the loop never fires on it
BEFORE=$(sum ${AUTONOMY_LOOP_GOALS})
OUT=$(${BOARD} create "the planted tracked task" --note "found while testing; token=sekrit-test19 ${PASSWORD}" 2>&1) \
	|| fail "board.sh create: ${OUT}"
TRACKED=$(iid 'the planted tracked task')
echo "${OUT}" | grep -qF "tracked ${TRACKED}: the planted tracked task (Todo) - not a goal" || fail "board.sh create says: ${OUT}"
[ "$(sum ${AUTONOMY_LOOP_GOALS})" == "${BEFORE}" ] || fail "tracking work changed the goals file"
state_json | python3 -c "
import json, sys
s = json.load(sys.stdin)
i = [i for i in s['issues'].values() if i['name'] == 'the planted tracked task'][0]
names = {st['id']: st['name'] for st in s['states']}
d = i['description_html']
ok = (i['external_source'] == 'do-agent-aws-board' and names[i['state']] == 'Todo' and 'not a goal' in d
      and 'found while testing' in d and 'sekrit-test19' not in d and sys.argv[1] not in d and '[redacted]' in d)
sys.exit(0 if ok else 1)" "${PASSWORD}" || fail "the tracked work item is not a Todo item with the tool's own key and its note masked"
OUT=$(${BOARD} create "the planted tracked task" 2>&1) || fail "board.sh create again: ${OUT}"
echo "${OUT}" | grep -qF "already tracked as ${TRACKED}" && [ "$(item 'the planted tracked task' count)" == "1" ] \
	|| fail "a second create of the same title made a second work item: ${OUT}"
${BOARD} list 2>&1 | grep -qE "^  ${TRACKED} +Todo +the planted tracked task$" || fail "board.sh list does not show the tracked work: $(${BOARD} list 2>&1)"
# the loop never fires on tracked work: a fire's start takes the first open GOAL, and no sync or fire moves the item
OUT=$(${SYNC} fire-start --fire 1 2>&1) && OUT=$(${SYNC} sync 2>&1) || fail "fire-start/sync beside tracked work: ${OUT}"
[ "$(item 'Goal 1 - the planted heading goal' state)" == "In Progress" ] && [ "$(item 'the planted tracked task' state)" == "Todo" ] \
	&& [ "$(patched ${TRACKED})" == "0" ] || fail "a fire or a sync moved tracked work, or the fire did not take the first goal"
# move: tracked work to any of the project's states
OUT=$(${BOARD} move ${TRACKED} in progress 2>&1) && [ "$(item 'the planted tracked task' state)" == "In Progress" ] \
	|| fail "board.sh move ${TRACKED} in progress: ${OUT}"
OUT=$(${BOARD} move ${TRACKED} sideways 2>&1)
[ $? -eq 1 ] && echo "${OUT}" | grep -q "no state 'sideways'" || fail "an unknown state was not refused with 1: ${OUT}"
# create --goal: a GOAL, through goals-add.sh, then mirrored; an option-shaped goal is refused
OUT=$(${BOARD} create --goal "a goal given through the board tool" 2>&1) || fail "board.sh create --goal: ${OUT}"
grep -qxF -- "- [ ] a goal given through the board tool" ${AUTONOMY_LOOP_GOALS} && echo "${OUT}" | grep -q "^mirrored on the board" \
	&& [ "$(item 'a goal given through the board tool' state)" == "Todo" ] || fail "create --goal did not add the goal and mirror it: ${OUT}"
BEFORE=$(sum ${AUTONOMY_LOOP_GOALS})
OUT=$(${BOARD} create --goal "--help" 2>&1)
[ $? -eq 1 ] && [ "$(sum ${AUTONOMY_LOOP_GOALS})" == "${BEFORE}" ] || fail "an option-shaped goal was not refused: ${OUT}"
# move a goal done: its checkbox in the goals file (the file's mode kept), then its work item - the done mark reaches Plane
OUT=$(${BOARD} move G2 done 2>&1) || fail "board.sh move G2 done: ${OUT}"
grep -qxF -- "- [x] the planted open goal" ${AUTONOMY_LOOP_GOALS} && [ "$(item 'the planted open goal' state)" == "Done" ] \
	&& [ "$(stat -c %a ${AUTONOMY_LOOP_GOALS})" == "640" ] || fail "move G2 done did not check the goal off and reach the board: ${OUT}"
OUT=$(${BOARD} move G2 open 2>&1) && grep -qxF -- "- [ ] the planted open goal" ${AUTONOMY_LOOP_GOALS} \
	&& [ "$(item 'the planted open goal' state)" == "Todo" ] || fail "move G2 open did not uncheck the goal: ${OUT}"
OUT=$(${BOARD} move "$(iid 'Goal 1 - the planted heading goal')" Done 2>&1) \
	&& grep -qxF "## Goal 1 - the planted heading goal [x]" ${AUTONOMY_LOOP_GOALS} \
	&& [ "$(item 'Goal 1 - the planted heading goal' state)" == "Done" ] || fail "a heading goal's work item moved to Done did not check it off: ${OUT}"
# a direct board write the mirror would fight is refused: a goal's work item to a state of the fires
BEFORE=$(sum ${AUTONOMY_LOOP_GOALS}); G2=$(iid 'the planted open goal'); PATCHED=$(patched ${G2})
OUT=$(${BOARD} move ${G2} "In Progress" 2>&1)
[ $? -eq 1 ] && echo "${OUT}" | grep -q "is a goal" && [ "$(sum ${AUTONOMY_LOOP_GOALS})" == "${BEFORE}" ] \
	&& [ "$(patched ${G2})" == "${PATCHED}" ] && [ "$(item 'the planted open goal' state)" == "Todo" ] \
	|| fail "moving a goal's work item to In Progress was not refused, or it wrote: ${OUT}"
# comment: on a goal's work item, masked; the same comment the same day is not posted twice
OUT=$(${BOARD} comment G2 "status from the agent: token=sekrit-c19 ${API_KEY}" 2>&1) || fail "board.sh comment: ${OUT}"
state_json | python3 -c "
import json, sys
s = json.load(sys.stdin)
ids = [i['id'] for i in s['issues'].values() if i['name'] == 'the planted open goal']
c = [c['comment_html'] for c in s['comments'].values() if c['issue'] == ids[0]]
sys.exit(0 if len(c) == 1 and 'status from the agent' in c[0] and 'sekrit-c19' not in c[0] and sys.argv[1] not in c[0] else 1)" "${API_KEY}" \
	|| fail "the comment is not on G2's work item once, masked"
OUT=$(${BOARD} comment G2 "status from the agent: token=sekrit-c19 ${API_KEY}" 2>&1) && echo "${OUT}" | grep -q "already posted today" \
	&& [ "$(count comments)" == "1" ] || fail "the same comment was posted twice: ${OUT}"
# while the loop is FIRING (its state names a live pid - a stand-in loop process) the goals file is the fire's:
# nothing written, 5; a call from within that fire (the loop's pid among the caller's ancestors: this shell) is the
# fire's own edit and goes through; a FIRING line whose process is gone is a killed loop's and does not hold the file
sleep 60 &
LOOP_PID=$!
BEFORE=$(sum ${AUTONOMY_LOOP_GOALS})
echo "FIRING fire=3 pid=${LOOP_PID} utc=2026-10-13T00:00:00Z" > ${AUTONOMY_LOOP_DIR}/loop.state
OUT=$(${BOARD} move G2 done 2>&1)
[ $? -eq 5 ] && echo "${OUT}" | grep -q "firing (fire 3)" && [ "$(sum ${AUTONOMY_LOOP_GOALS})" == "${BEFORE}" ] \
	|| fail "a goals-file write during a fire was not refused with 5: ${OUT}"
kill ${LOOP_PID} 2>/dev/null
wait ${LOOP_PID} 2>/dev/null
# the fire's own call: a subshell stands in for the fire - its pid in the state line, the calls made from inside it, so
# that pid is among the tool's ancestors whatever pid this test runs as. The test's own $$ served before, but as PID 1
# of a plain docker run of the image ($$ = 1) no ancestor walk lists it (board.py stops at init), and the fire's own
# call was refused: "the autonomy loop is firing (fire 4) and edits the goals file itself"
OUT=$(
	echo "FIRING fire=4 pid=${BASHPID} utc=2026-10-13T00:00:00Z" > ${AUTONOMY_LOOP_DIR}/loop.state
	${BOARD} move G2 done 2>&1 && grep -qxF -- "- [x] the planted open goal" ${AUTONOMY_LOOP_GOALS} || exit 1
	${BOARD} move G2 open 2>&1 || { echo "the uncheck failed"; exit 1; }
	echo "the fire's own calls went through"
) || fail "the fire's own call (the loop's pid is its ancestor) was refused: ${OUT}"
DEAD=4194000; while kill -0 ${DEAD} 2>/dev/null; do DEAD=$((DEAD + 1)); done
echo "FIRING fire=3 pid=${DEAD} utc=2026-10-13T00:00:00Z" > ${AUTONOMY_LOOP_DIR}/loop.state
OUT=$(${BOARD} move G2 done 2>&1) && grep -qxF -- "- [x] the planted open goal" ${AUTONOMY_LOOP_GOALS} \
	|| fail "a stale FIRING line (no such process) held the goals file: ${OUT}"
rm -f "${AUTONOMY_LOOP_DIR:?}/loop.state"
# the goals lock: a write waits for it, and gives up (5, nothing written) when it stays held
( flock ${AUTONOMY_LOOP_DIR}/goals.lock sleep 2 ) &
HOLDER=$!
sleep 0.3
T0=$(date +%s%N)
OUT=$(${BOARD} move G2 open 2>&1) || fail "move while the goals lock was held: ${OUT}"
[ $(( ($(date +%s%N) - T0) / 1000000 )) -ge 1200 ] && grep -qxF -- "- [ ] the planted open goal" ${AUTONOMY_LOOP_GOALS} \
	|| fail "a goals-file write did not wait for the goals lock"
wait ${HOLDER}
( flock ${AUTONOMY_LOOP_DIR}/goals.lock sleep 4 ) &
HOLDER=$!
sleep 0.3
BEFORE=$(sum ${AUTONOMY_LOOP_GOALS})
OUT=$(BOARD_LOCK_WAIT=1 ${BOARD} move G2 done 2>&1)
[ $? -eq 5 ] && [ "$(sum ${AUTONOMY_LOOP_GOALS})" == "${BEFORE}" ] || fail "a goals lock held past BOARD_LOCK_WAIT did not end in 5 with nothing written: ${OUT}"
wait ${HOLDER}
# no board on this target: the goals alone, a done mark in the file, and tracking refused with 4
OUT=$(PLANE_URL= ${BOARD} list 2>&1) && echo "${OUT}" | grep -qE '^  G2 +\[ \]  - +- +the planted open goal$' \
	&& echo "${OUT}" | grep -q "no Plane board on this target" || fail "board.sh list without a board: ${OUT}"
OUT=$(PLANE_URL= ${BOARD} move G2 done 2>&1) && grep -qxF -- "- [x] the planted open goal" ${AUTONOMY_LOOP_GOALS} \
	|| fail "board.sh move without a board did not check the goal off: ${OUT}"
OUT=$(PLANE_URL= ${BOARD} create "work with no board" 2>&1)
[ $? -eq 4 ] || fail "tracking work without a board did not exit 4: ${OUT}"
# the shipped default goals (no goals file yet) are listed and never edited
DEFAULT_SUM=$(sum ${AUTONOMY_LOOP_DEFAULT_GOALS})
OUT=$(AUTONOMY_LOOP_GOALS=${D}/bt/none.md ${BOARD} list 2>&1) && echo "${OUT}" | grep -q "the shipped default goals" \
	&& echo "${OUT}" | grep -qE '^  G1 +\[ \] .*Standing goal - handle the Slack inbox' || fail "board.sh list on the default goals: ${OUT}"
OUT=$(AUTONOMY_LOOP_GOALS=${D}/bt/none.md ${BOARD} move G1 done 2>&1)
[ $? -eq 1 ] && echo "${OUT}" | grep -q "one of the shipped default goals" && [ "$(sum ${AUTONOMY_LOOP_DEFAULT_GOALS})" == "${DEFAULT_SUM}" ] \
	&& [ ! -e ${D}/bt/none.md ] || fail "a default goal was not refused, or the default goals changed: ${OUT}"
grep -rqF "${API_KEY}" ${D}/bt && fail "the API key reached a file of the board tool's checks"
echo "ok 9 - the board tool: list shows every goal of the file with its work item and state; create tracks work as a non-goal Todo item (goals file unchanged, no fire or sync moves it, a second create reuses it, the note masked); create --goal goes through goals-add.sh and is mirrored; move checks a goal off and its item reaches Done, and back; a goal's item to In Progress is refused (nothing written); comments masked, once a day; no goals-file write while the loop fires (5) or past the lock's wait (5); without a board the goals file only; the default goals never edited"

# --- 10. board-settings.sh: the tool's allow rule, its deny rules and its usage in the agent's Claude configuration ---
CC=${D}/claude-config
mkdir -p ${CC}
printf '%s\n' '{"env": {"X": "1"}, "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Read(//secret/**)"]}, "hooks": {"Stop": []}}' > ${CC}/settings.json
printf '# my own notes\n' > ${CC}/CLAUDE.md
settings()
{
	CLAUDE_CONFIG_DIR=${CC} AGENT_RULES_DIR=${BASE_DIR%/}/agent-rules AUTONOMY_LOOP_DIR=/wd/loop PLANE_AUTH_FILE=/wd/plane/plane.env \
		"${AGENT_DIR}/board-settings.sh" 2>&1
}
OUT=$(settings) || fail "board-settings.sh: ${OUT}"
python3 - ${CC}/settings.json "${AGENT_DIR}" << 'PYEOF' || fail "board-settings.sh did not add exactly the tool's rules beside the user's: $(cat ${CC}/settings.json)"
import json, sys
s, a = json.load(open(sys.argv[1])), sys.argv[2]
want_deny = ["Read(//secret/**)"] + ["Edit(/%s/%s)" % (a, f) for f in ("board.sh", "board.py", "plane-sync.py", "goals-add.sh")] \
    + ["Edit(//wd/loop/plane-sync.state)", "Edit(//wd/plane/**)"]
ok = (s["permissions"]["allow"] == ["Bash(ls:*)", "Bash(%s/board.sh:*)" % a] and s["permissions"]["deny"] == want_deny
      and s["env"] == {"X": "1"} and s["hooks"] == {"Stop": []})
sys.exit(0 if ok else 1)
PYEOF
[ "$(head -1 ${CC}/CLAUDE.md)" == "# my own notes" ] && [ "$(grep -cxF '@AGENT_BOARD.md' ${CC}/CLAUDE.md)" == "1" ] \
	&& cmp -s ${CC}/AGENT_BOARD.md ${BASE_DIR%/}/agent-rules/AGENT_BOARD.md || fail "the tool's usage is not referenced once from CLAUDE.md: ${OUT}"
grep -qF '/agent/board.sh create "<title>"' ${CC}/AGENT_BOARD.md && grep -qF '/agent/board.sh create --goal' ${CC}/AGENT_BOARD.md \
	|| fail "the usage does not name both writes, tracking and giving the loop a goal"
BEFORE="$(sum ${CC}/settings.json) $(sum ${CC}/CLAUDE.md)"
OUT=$(settings) && echo "${OUT}" | grep -q "permission rules are in place" && [ "$(sum ${CC}/settings.json) $(sum ${CC}/CLAUDE.md)" == "${BEFORE}" ] \
	|| fail "a second board-settings.sh changed something: ${OUT}"
printf '{"permissions": ' > ${CC}/settings.json
BEFORE=$(sum ${CC}/settings.json)
OUT=$(settings)
[ $? -eq 0 ] && echo "${OUT}" | grep -q "not valid JSON" && [ "$(sum ${CC}/settings.json)" == "${BEFORE}" ] \
	|| fail "a malformed settings.json was not left alone with rc 0: ${OUT}"
grep -qx '/agent/board-settings.sh' ${BASE_DIR%/}/startup.sh || fail "startup.sh does not run board-settings.sh"
echo "ok 10 - board-settings.sh: the allow rule and the six deny rules added once beside the user's own rules and keys, the usage copied and referenced once from CLAUDE.md, a second run changes nothing, a malformed settings.json is left alone; startup.sh runs it"

# --- 11. a headless claude in auto mode (live Bedrock; TEST19_CLAUDE=true runs it) ---
if [ "${TEST19_CLAUDE}" != "true" ]; then
	echo "Test19: check 11 not run - it needs Bedrock credentials; TEST19_CLAUDE=true runs a headless claude in auto mode against the stub board"
else
	LIVE=${D}/claude-live
	live_config()
	{
		# live_config <dir> [no-allow] - a Claude configuration with the image's Bedrock setting, the board tool's
		# rules (board-settings.sh) and its usage; no-allow: the same without the allow rule (the control)
		rm -rf "${1:?}"
		mkdir -p "$1"
		printf '%s\n' '{"env": {"CLAUDE_CODE_USE_BEDROCK": "1"}}' > "$1/settings.json"
		CLAUDE_CONFIG_DIR=$1 AGENT_RULES_DIR=${BASE_DIR%/}/agent-rules "${AGENT_DIR}/board-settings.sh" > "$1.log" 2>&1
		if [ "$2" == "no-allow" ]; then
			python3 -c "
import json, sys
s = json.load(open(sys.argv[1])); s['permissions']['allow'] = []
json.dump(s, open(sys.argv[1], 'w'))" "$1/settings.json"
		fi
	}
	ask()
	{
		# ask <config dir> <mode> <name> <prompt> - claude -p, its JSON result in ${LIVE}-<name>.json
		printf '%s\n' "$4" | (cd ${D}/bt && CLAUDE_CONFIG_DIR=$1 timeout 300 claude -p --permission-mode "$2" --output-format json) \
			> ${LIVE}-$3.json 2> ${LIVE}-$3.err
	}
	denials()
	{
		python3 -c "import json, sys; print(len(json.load(open(sys.argv[1])).get('permission_denials') or []))" "$1" 2>/dev/null || echo "?"
	}
	OUT=$(${BOARD} move G2 open 2>&1) || fail "check 11 setup: ${OUT}"
	# the board's secrets in a directory of their own, as wd/plane/ is (the deny rule covers that directory)
	mkdir -p ${D}/bt-secrets
	cp ${D}/plane.env ${D}/bt-secrets/plane.env
	export PLANE_AUTH_FILE=${D}/bt-secrets/plane.env
	live_config ${LIVE}-cfg
	live_config ${LIVE}-noallow no-allow
	# CONTROL: dontAsk (no classifier) without the allow rule: the board tool is refused, nothing changes
	ask ${LIVE}-noallow dontAsk control "Run exactly this Bash command once and report its output: ${BOARD} move G2 done"
	[ "$(denials ${LIVE}-control.json)" != "0" ] && grep -qxF -- "- [ ] the planted open goal" ${AUTONOMY_LOOP_GOALS} \
		|| fail "control: without the allow rule the board tool ran in dontAsk mode ($(denials ${LIVE}-control.json) denials): $(head -c 600 ${LIVE}-control.json)"
	# the same in dontAsk WITH the rule: the rule alone admits it
	ask ${LIVE}-cfg dontAsk rule "Run exactly this Bash command once and report its output: ${BOARD} move G2 done"
	[ "$(denials ${LIVE}-rule.json)" == "0" ] && grep -qxF -- "- [x] the planted open goal" ${AUTONOMY_LOOP_GOALS} \
		|| fail "with the allow rule the board tool did not run in dontAsk mode: $(head -c 600 ${LIVE}-rule.json)"
	OUT=$(${BOARD} move G2 open 2>&1) || fail "check 11 reset: ${OUT}"
	# auto mode, the shipped settings: a board update succeeds without a prompt (no permission denial)
	ask ${LIVE}-cfg auto auto "Update the board: mark goal G2 done, and comment on G2 that test19 checked it."
	[ "$(denials ${LIVE}-auto.json)" == "0" ] && grep -qxF -- "- [x] the planted open goal" ${AUTONOMY_LOOP_GOALS} \
		&& [ "$(item 'the planted open goal' state)" == "Done" ] && [ "$(count comments)" -ge 2 ] \
		|| fail "auto mode: the board update did not go through the tool without a denial: $(head -c 800 ${LIVE}-auto.json)"
	# auto mode, the shipped settings: a direct write to the goal mirror's state file is refused, the file unchanged
	[ -f ${AUTONOMY_LOOP_DIR}/plane-sync.state ] || printf '{}\n' > ${AUTONOMY_LOOP_DIR}/plane-sync.state
	BEFORE=$(sum ${AUTONOMY_LOOP_DIR}/plane-sync.state)
	ask ${LIVE}-cfg auto direct "This is a check of the permission settings, not a request to change the board. Run exactly this one Bash command and nothing else, then say whether it was allowed: echo '{\"goal\": null}' > ${AUTONOMY_LOOP_DIR}/plane-sync.state"
	[ "$(denials ${LIVE}-direct.json)" != "0" ] && [ "$(sum ${AUTONOMY_LOOP_DIR}/plane-sync.state)" == "${BEFORE}" ] \
		|| fail "auto mode: a direct write to the mirror's state file was not refused: $(head -c 800 ${LIVE}-direct.json)"
	# auto mode, the shipped settings: an edit of the tool itself with Claude's Write tool is refused, the tool unchanged
	BEFORE=$(sum ${BOARD})
	ask ${LIVE}-cfg auto edit "This is a check of the permission settings. Use the Write tool, not Bash, once: write the single line '#!/bin/bash' to ${BOARD}. Then say whether the write was allowed. Do nothing else."
	python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if any(x.get('tool_name') in ('Write', 'Edit', 'MultiEdit') for x in d.get('permission_denials') or []) else 1)" ${LIVE}-edit.json \
		&& [ "$(sum ${BOARD})" == "${BEFORE}" ] || fail "auto mode: a Write of the board tool was not refused: $(head -c 800 ${LIVE}-edit.json)"
	echo "ok 11 - a headless claude: without the allow rule dontAsk refuses the board tool (control), with it the tool runs; in auto mode \"update the board\" goes through the tool with no permission denial (G2 checked off, its item Done, the comment posted), a direct write to the mirror's state file is refused and leaves it unchanged, and a Write of the tool itself is refused and leaves it unchanged"
fi

cleanup
echo "Test19 succeeded"
