#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the Board (docs/manual/boards.md "Board": /agent/board-server.py and its page, the home proxy's board.localhost
# route and tile) and of the home page's North Star section (docs/NORTH-STAR.md, rendered from the register the image
# ships at /agent/north-star.json). Fully OFFLINE: a stub Plane API and a stub agent runner on loopback, the server and
# nginx on test-local ports, test-local state under /tmp/board-smoke; nothing under /wd is touched.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the scripts parse (bash -n, py_compile); the page's script has no HTML sink (no innerHTML, insertAdjacentHTML,
#      outerHTML or document.write - it renders with textContent); the page has no inline script or style of its own
#   2. against the stub Plane (the project, its six states, its work items over two pages, the agent's key required) and
#      the stub runner (three attempts, one naming AGENT-2 and one naming AGENT-20): the snapshot holds the columns in
#      Plane's order, the cards under their states, and AGENT-2's attempt - running, with its branch, its sessions and
#      what git reports - while the attempt naming AGENT-20 is on AGENT-20's card and NOT on AGENT-2's (a whole-token
#      match), the archived one is left out and the unrelated one is listed as unlinked; no description and no person
#      reaches the snapshot; the harness stylesheet's path answers an empty text/css fallback; every response says no-store, nosniff and a
#      'self'-only policy; CONTROL: once the stub refuses the key, /healthz turns 503 within two passes (10 s, while the
#      snapshot is younger than STALE_AFTER: the error, not the age, must do it) and the snapshot is served stale with the
#      reason - and recovers when the key is accepted again; CONTROL of that control: a server copy whose health follows the
#      age alone stays 200 for those 10 s and is caught
#   3. the planted API key is in no response (page, script, stylesheet, snapshot, health) and no log line;
#      CONTROL: a server copy that leaks the key into its snapshot fails the same scan
#   4. read-only and own-origin: POST, PUT, DELETE, OPTIONS, PATCH and any method the server has no handler for (TRACE, an
#      arbitrary token) answer 405 with Allow: GET, HEAD and the same headers as every response, a foreign Host 421 first, a
#      malformed request line 400 as plain text (never the stdlib's HTML error page); the snapshot refuses a
#      foreign Origin (403), an opaque "null" Origin (403) and Sec-Fetch-Site cross-site or same-site (403), and answers
#      its own origin (200), an absent Origin (200) and same-origin (200); a foreign Host gets 421 on every path;
#      CONTROL: a server copy without the origin guard answers a foreign Origin 200
#   5. through the home proxy (home-render.sh with PLANE_URL and test-local ports, nginx): board.localhost serves the page
#      with the home badge exactly once, returning to //localhost:<port>/; the badge's three inline parts (its style
#      attribute, its phone-width rule, its keeper script) are the page's only inline parts, under a policy that is
#      exactly the server's own plus their three hashes, and one stylesheet link (the page's own); POST through the
#      route is refused (403); the dot probe /__probe/board is 204 while the server is fresh, 500 once Plane refuses
#      the key (the server's 503), 500 with the server stopped, and 204 again when it is back; CONTROLS: a
#      home-render.sh copy without the route's badge include fails the badge check, and so does one whose policy lacks
#      only the keeper script's hash, each for its own reason; planted copies of the served page (each hash taken out,
#      an inline part the badge does not bring, a source the server's policy lacks) fail it for theirs; a csp_hash
#      that prints nothing stops home-render.sh with an error instead of rendering a policy that refuses the badge
#   6. the tile: UI_BOARD=false greys it "off - set UI_BOARD=true in .env"; UI_PLANE=false (the shipped default - the Plane
#      board is opt-in, docs/manual/boards.md "Plane board") renders NO Board tile at all, and no Plane tile, and the page names no
#      UI_PLANE flag; PLANE_URL unset greys it "not on this target"; all on, it is live with data-host=board and
#      data-probe=/__probe/board and opens in a new tab (target _blank, rel noopener, as every live tile here), and neither the
#      route nor the probe exists in the first three cases
#   7. the North Star section equals the register: the page's rows (id, verdict, today, the check) equal
#      /agent/north-star.json's, the agents table (agent, North Star, UI, talks to, the check or "no tracked check", the
#      verdict, today, the caveat) equals the register's agents and the components table its components, and
#      docs/NORTH-STAR.md's three tables equal them too where the checkout is mounted; the section sits between the tiles and
#      the footer; CONTROLS: a planted register with one verdict changed renders rows the comparison against the shipped file
#      fails, and so do one with one agent's verdict changed and one with one component's state changed; a missing register
#      renders one line saying so, never an empty section
#   8. ui-start.sh (every other UI off, the Loop Deck adapter's data dir test-local) starts the server (pidfile, 127.0.0.1
#      only) and ui-status.sh reports it UP once its first pass is in;
#      ui-stop.sh stops it (pidfile gone, port closed); without PLANE_URL ui-start.sh starts nothing and ui-status.sh
#      says NOT CONFIGURED; with UI_BOARD=false it says DISABLED

D=/tmp/board-smoke
rm -rf "${D:?}"
mkdir -p "${D}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
CHECKOUT=${CHECKOUT:-/do-agent-aws}
SITE=home/site   # where home-render.sh writes the page under a UI_DIR
REGISTER=${NORTH_STAR_JSON_SHIPPED:-/agent/north-star.json}
PORT_PLANE=18821
PORT_RUNNER=18822
PORT_BOARD=18823
PORT_HOME=18824
PORT_BOARD_MUTANT=18825
PORT_HOME_MUTANT=18826
PORT_HOME_MUTANT2=18829
PORT_BOARD_UI=18827
PORT_HOME_UI=18828
PIDS=()
H=http://127.0.0.1:${PORT_HOME}
B=http://127.0.0.1:${PORT_BOARD}
BH="Host: board.localhost:${PORT_BOARD}"

cleanup()
{
	for P in "${PIDS[@]}"; do kill "${P}" 2>/dev/null; done
	[ -f "${D}/ui/home/nginx.pid" ] && kill "$(cat "${D}/ui/home/nginx.pid")" 2>/dev/null
	[ -f "${D}/mutant-ui/home/nginx.pid" ] && kill "$(cat "${D}/mutant-ui/home/nginx.pid")" 2>/dev/null
	UI_DIR=${D}/ui2 "${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
}
trap cleanup EXIT

fail()
{
	echo "Test-board FAILED: $1"
	exit 1
}

code()
{
	# code [curl options] <url> - the status code, 000 when nothing answers
	curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || echo 000
}

upto()
{
	# upto <code> [curl options] <url> - true once the url answers that code, within UPTO_TRIES quarter-seconds (default 80,
	# about 20 s; a check that must see a change within 10 s sets UPTO_TRIES=40)
	WANT=$1; shift
	for _ in $(seq 1 "${UPTO_TRIES:-80}"); do [ "$(code "$@")" == "${WANT}" ] && return 0; sleep 0.25; done
	return 1
}

# --- 1. syntax, and the page's rendering discipline ---
for S in home-render.sh ui-start.sh ui-status.sh ui-stop.sh; do bash -n "${AGENT_DIR}/${S}" || fail "bash -n ${S}"; done
bash -n "$0" || fail "bash -n $0"
# the bytecode goes under ${D}: py_compile writes a __pycache__ next to the source, and /agent is the image's, read-only to the agent
PYTHONPYCACHEPREFIX="${D}/pycache" python3 -m py_compile "${AGENT_DIR}/board-server.py" || fail "board-server.py does not compile"
for F in index.html board.js board.css; do [ -s "${AGENT_DIR}/board-ui/${F}" ] || fail "the page file board-ui/${F} is missing"; done
grep -nE 'innerHTML|insertAdjacentHTML|outerHTML|document\.write' "${AGENT_DIR}/board-ui/board.js" && fail "board.js has an HTML sink (the page must render with textContent)"
grep -q 'textContent' "${AGENT_DIR}/board-ui/board.js" || fail "board.js does not render with textContent"
grep -qE '<script[^>]*>[^<]' "${AGENT_DIR}/board-ui/index.html" && fail "index.html carries an inline script (the policy is 'self' alone)"
grep -qE ' style="' "${AGENT_DIR}/board-ui/index.html" && fail "index.html carries an inline style attribute"
grep -qE '<style' "${AGENT_DIR}/board-ui/index.html" && fail "index.html carries an inline style element"
grep -q 'href="/__harness/harness.css"' "${AGENT_DIR}/board-ui/index.html" || fail "the page does not link the shared harness stylesheet"
echo "ok 1 - syntax; the page renders with textContent, carries no inline script or style, links the harness stylesheet"

# --- the stubs: Plane (the key required; a flag file makes it refuse) and the agent runner ---
KEY_HEX=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
KEY="plane_api_${KEY_HEX}"   # assembled here, so no file in the tree holds a credential-shaped string
printf 'PLANE_ADMIN_EMAIL=agent@do-agent-aws.local\nPLANE_API_KEY=%s\n' "${KEY}" > "${D}/plane.env"
chmod 600 "${D}/plane.env"
cat > "${D}/stub-plane.py" << 'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT, FLAG, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
KEY = os.environ["STUB_PLANE_KEY"]   # never on the command line: ps would show it
WS = "/api/v1/workspaces/do-agent-aws"
STATES = [("s-backlog", "Backlog", "backlog", 15000), ("s-todo", "Todo", "unstarted", 25000),
          ("s-prog", "In Progress", "started", 35000), ("s-rev", "In Review", "started", 40000),
          ("s-done", "Done", "completed", 45000), ("s-can", "Cancelled", "cancelled", 55000)]
ISSUE = {"id": "", "sequence_id": 0, "name": "", "state": "", "priority": "none", "updated_at": "2026-10-13T12:00:00.000000Z",
         "description_html": "<p>a fire's transcript excerpt: SECRET-DESCRIPTION-MARKER</p>", "assignees": ["person-uuid"],
         "created_by": "person-uuid", "external_source": "do-agent-aws", "external_id": "x"}
def issue(i, name, state, pri="none"):
    d = dict(ISSUE); d.update({"id": f"i{i}", "sequence_id": i, "name": name, "state": state, "priority": pri}); return d
PAGE1 = [issue(1, "Add a README quickstart", "s-todo"), issue(2, "Ship the board tile", "s-prog", "high")]
PAGE2 = [issue(3, "Seed the default knowledge", "s-done"), issue(20, "Twenty: a decoy for the whole-token match", "s-todo")]
class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path} {self.headers.get('X-Api-Key', '')}\n")
    def send(self, code, body):
        b = json.dumps(body).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if os.path.exists(FLAG) or self.headers.get("X-Api-Key") != KEY:
            return self.send(401, {"error": "Authentication credentials were not provided."})
        p, _, q = self.path.partition("?")
        if p == WS + "/projects/":
            return self.send(200, {"results": [{"id": "p1", "identifier": "AGENT", "name": "do agent aws"},
                                               {"id": "p2", "identifier": "OTHER", "name": "another project"}], "next_page_results": False})
        if p == WS + "/projects/p1/states/":
            return self.send(200, {"results": [{"id": i, "name": n, "group": g, "sequence": s, "color": "#4A5568"} for i, n, g, s in STATES], "next_page_results": False})
        if p == WS + "/projects/p1/issues/":
            if "cursor=" in q:
                return self.send(200, {"results": PAGE2, "next_page_results": False})
            return self.send(200, {"results": PAGE1, "next_page_results": True, "next_cursor": "100:1:0"})
        self.send(404, {"error": "not found"})
    def do_POST(self):
        with open(LOG, "a") as f:
            f.write(f"WRITE {self.command} {self.path}\n")
        self.send(405, {"error": "the stub takes no write"})
    do_PATCH = do_PUT = do_DELETE = do_POST
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
cat > "${D}/stub-runner.py" << 'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT = int(sys.argv[1])
def ws(i, name, branch):
    return {"id": i, "task_id": None, "container_ref": None, "branch": branch, "setup_completed_at": "2026-10-13T12:00:00Z",
            "created_at": "2026-10-13T11:00:00Z", "updated_at": "2026-10-13T12:30:00Z", "archived": False, "pinned": False,
            "name": name, "worktree_deleted": False}
WORKSPACES = [ws("w-linked-0001", "AGENT-2 ship the board tile", "vk/w-li-agent-2-ship-the-board"),
              ws("w-decoy-00002", "a decoy", "vk/w-de-agent-20-twenty"),
              ws("w-unlinked-03", "something else entirely", "vk/w-un-something"),
              dict(ws("w-archived-04", "AGENT-2 old attempt", "vk/old"), archived=True)]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def send(self, code, body):
        b = json.dumps(body).encode(); self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p, _, q = self.path.partition("?")
        if p == "/api/health":
            return self.send(200, {"success": True, "data": "OK", "error_data": None, "message": None})
        if p == "/api/workspaces":
            return self.send(200, {"success": True, "data": WORKSPACES, "error_data": None, "message": None})
        if p == "/api/sessions":
            running = "workspace_id=w-linked-0001" in q
            return self.send(200, {"success": True, "data": [{"id": "s1", "status": "running" if running else "completed", "executor": "CLAUDE_CODE"}] if "w-linked" in q or "w-decoy" in q else [], "error_data": None, "message": None})
        if p.startswith("/api/workspaces/") and p.endswith("/git/status"):
            if "w-linked" in p:
                return self.send(200, {"success": True, "data": {"ahead": 2, "behind": 0, "uncommitted_count": 3, "head_oid": "deadbeef"}, "error_data": None, "message": None})
            return self.send(200, {"success": False, "data": None, "error_data": None, "message": "An internal error occurred."})
        self.send(404, {"success": False, "data": None, "error_data": None, "message": "not found"})
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
STUB_PLANE_KEY="${KEY}" python3 "${D}/stub-plane.py" "${PORT_PLANE}" "${D}/plane-refuse" "${D}/plane-calls.log" > "${D}/stub-plane.out" 2>&1 &
PIDS+=($!)
python3 "${D}/stub-runner.py" "${PORT_RUNNER}" > "${D}/stub-runner.out" 2>&1 &
PIDS+=($!)
upto 200 "http://127.0.0.1:${PORT_RUNNER}/api/health" || fail "the stub runner did not come up"
upto 401 "http://127.0.0.1:${PORT_PLANE}/api/v1/workspaces/do-agent-aws/projects/" || fail "the stub Plane did not come up"

# the server under test: a short pass interval so the controls below turn around in seconds
serve()
{
	# serve <port> <log> [<server file>] - starts a board server, prints its pid
	env UI_PORT_BOARD="$1" PLANE_URL="http://127.0.0.1:${PORT_PLANE}" PLANE_AUTH_FILE="${D}/plane.env" PLANE_WORKSPACE=do-agent-aws \
		PLANE_PROJECT=AGENT BOARD_RUNNER_URL="http://127.0.0.1:${PORT_RUNNER}" BOARD_REFRESH=5 \
		BOARD_UI_DIR="${AGENT_DIR}/board-ui" python3 "${3:-${AGENT_DIR}/board-server.py}" > "$2" 2>&1 &
	echo $!
}
SRV=$(serve "${PORT_BOARD}" "${D}/board.log")
PIDS+=("${SRV}")
upto 200 -H "${BH}" "${B}/api/board" || { cat "${D}/board.log"; fail "the board server gave no snapshot within 20 s"; }

# --- 2. the snapshot from the stubs ---
curl -s -D "${D}/snap.h" -o "${D}/snap.json" --max-time 5 -H "${BH}" "${B}/api/board" || fail "GET /api/board"
python3 - "${D}/snap.json" << 'PY' || fail "the snapshot is not what the stubs describe (see above)"
import json, sys
d = json.load(open(sys.argv[1]))
def check(cond, msg):
    if not cond:
        sys.exit("snapshot: " + msg)
check(d.get("schema") == "do-agent-aws-board/v1", f"schema {d.get('schema')!r}")
check(d.get("project", {}).get("identifier") == "AGENT" and d["project"]["name"] == "do agent aws", f"project {d.get('project')}")
names = [c["name"] for c in d["columns"]]
check(names == ["Backlog", "Todo", "In Progress", "In Review", "Done", "Cancelled"], f"columns {names}")
by = {c["name"]: c["cards"] for c in d["columns"]}
check([k["key"] for k in by["Todo"]] == ["AGENT-20", "AGENT-1"], f"Todo holds {[k['key'] for k in by['Todo']]} (newest first)")
check([k["key"] for k in by["In Progress"]] == ["AGENT-2"] and [k["key"] for k in by["Done"]] == ["AGENT-3"], "the cards are not under their states")
check(d["cards"] == 4, f"{d['cards']} cards counted")
two = by["In Progress"][0]
check(two["priority"] == "high" and two["name"] == "Ship the board tile" and two["mirrored"] is True, f"card AGENT-2 {two}")
check(len(two["attempts"]) == 1, f"AGENT-2 has {len(two['attempts'])} attempts (want the one naming AGENT-2; AGENT-20's and the archived one are not it)")
a = two["attempts"][0]
check(a["branch"] == "vk/w-li-agent-2-ship-the-board" and a["running"] is True and a["sessions"] == 1, f"the attempt {a}")
check(a["git"].get("ahead") == 2 and a["git"].get("uncommitted_count") == 3 and "head_oid" not in a["git"], f"git facts {a['git']}")
twenty = by["Todo"][0]
check(len(twenty["attempts"]) == 1 and twenty["attempts"][0]["branch"] == "vk/w-de-agent-20-twenty", f"AGENT-20 does not carry the decoy attempt that names it: {twenty['attempts']}")
check(d["runner"] == {"ok": True, "attempts": 3, "linked": 2, "error": None}, f"runner {d['runner']} (the archived attempt is left out; two of three name a card)")
un = [u["name"] for u in d["unlinked_attempts"]]
check(un == ["something else entirely"], f"unlinked {un}")
check(d["stale"] is False and d["error"] is None, "the fresh snapshot reads stale")
raw = open(sys.argv[1]).read()
for forbidden in ("SECRET-DESCRIPTION-MARKER", "person-uuid", "description", "assignees", "created_by", "external_id"):
    check(forbidden not in raw, f"the snapshot carries {forbidden!r} - a card is its key, name, priority and time, nothing of a person or a description")
check("w-linked-0001" not in raw and a["id"] == "w-linked", "an attempt id is shown in full (the first 8 characters identify it)")
print(f"columns {names}; {d['cards']} cards; AGENT-2 carries its running attempt ({a['branch']}, {a['git']}); {len(un)} unlinked")
PY
for P in / /board.js /board.css /api/board /healthz; do
	curl -s -D "${D}/h.txt" -o /dev/null --max-time 5 -H "${BH}" "${B}${P}" || fail "GET ${P}"
	grep -qi '^Cache-Control: no-store' "${D}/h.txt" || fail "${P}: no Cache-Control: no-store"
	grep -qi '^X-Content-Type-Options: nosniff' "${D}/h.txt" || fail "${P}: no nosniff"
	grep -qi "^Content-Security-Policy: default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" "${D}/h.txt" \
		|| fail "${P}: the policy is not the page's own origin alone: $(grep -i '^Content-Security-Policy' "${D}/h.txt")"
done
grep -qi '^Content-Type: text/html' "${D}/h.txt" && fail "/healthz is html"
# the page's link to the harness stylesheet never fails: the proxy serves the stylesheet on this path once installed, and
# the server answers an empty text/css for it otherwise (a 404 would be a console error on every page load)
curl -s -D "${D}/css.h" -o "${D}/css.b" --max-time 5 -H "${BH}" "${B}/__harness/harness.css" || fail "GET /__harness/harness.css"
grep -q '^HTTP/1.[01] 200' "${D}/css.h" && grep -qi '^Content-Type: text/css' "${D}/css.h" || fail "/__harness/harness.css is not an empty text/css fallback: $(head -1 "${D}/css.h")"
grep -q 'harness stylesheet' "${D}/css.b" || fail "the stylesheet fallback does not say what it is"
curl -s --max-time 5 -H "${BH}" "${B}/healthz" | grep -q '"fresh": true' || fail "/healthz does not read fresh while Plane answers"
[ "$(code -H "${BH}" "${B}/healthz")" == "200" ] || fail "/healthz is not 200 while Plane answers"
# CONTROL: Plane refuses the key -> the health turns 503 at the next pass (within 2 x BOARD_REFRESH = 10 s, while the
# snapshot is still younger than STALE_AFTER = 15 s: a health that only followed the snapshot's age would still read 200
# here), the snapshot stays (stale, with the reason), then recovers
touch "${D}/plane-refuse"
UPTO_TRIES=40 upto 503 -H "${BH}" "${B}/healthz" || fail "CONTROL: with Plane refusing the key /healthz stayed $(code -H "${BH}" "${B}/healthz") for 10 s (Plane's error must turn the health 503 at the next pass, not the snapshot's age)"
curl -s --max-time 5 -H "${BH}" "${B}/healthz" | grep -q '"fresh": false' || fail "the health does not read fresh:false with Plane refusing the key"
curl -s --max-time 5 -H "${BH}" "${B}/api/board" > "${D}/snap-stale.json"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["stale"] is True and "refused the API key" in (d["error"] or ""), d.get("error"); assert d["cards"] == 4' "${D}/snap-stale.json" \
	|| fail "CONTROL: the stale snapshot does not say Plane refused the key while keeping the last good view: $(head -c 300 "${D}/snap-stale.json")"
rm -f "${D:?}/plane-refuse"
upto 200 -H "${BH}" "${B}/healthz" || fail "the health did not recover once Plane accepted the key again"
# CONTROL of the control: a server copy whose health follows the snapshot's age alone (Plane's error ignored) keeps
# answering 200 for the 10 s the check above allows - the check must catch it
mkdir -p "${D}/mutant"
cp -r "${AGENT_DIR}/board-ui" "${D}/mutant/"
python3 - "${AGENT_DIR}/board-server.py" "${D}/mutant/board-server.py" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = "return self.good_at is not None and (time.time() - self.good_at) <= STALE_AFTER and self.error is None"
assert anchor in s, "the control's anchor moved"
open(sys.argv[2], "w").write(s.replace(anchor, "return self.good_at is not None and (time.time() - self.good_at) <= STALE_AFTER"))
PY
MUT=$(serve "${PORT_BOARD_MUTANT}" "${D}/mutant-health.log" "${D}/mutant/board-server.py")
PIDS+=("${MUT}")
upto 200 -H "Host: board.localhost:${PORT_BOARD_MUTANT}" "http://127.0.0.1:${PORT_BOARD_MUTANT}/healthz" || fail "the control server did not come up"
touch "${D}/plane-refuse"
if UPTO_TRIES=40 upto 503 -H "Host: board.localhost:${PORT_BOARD_MUTANT}" "http://127.0.0.1:${PORT_BOARD_MUTANT}/healthz"; then
	fail "CONTROL: a health that ignores Plane's error turned 503 within 10 s - the check above could not tell it from the real one"
fi
rm -f "${D:?}/plane-refuse"
kill "${MUT}" 2>/dev/null
upto 200 -H "${BH}" "${B}/healthz" || fail "the health did not recover after the control"
echo "ok 2 - the snapshot holds the stub project's columns and cards with AGENT-2's attempt; no-store, nosniff, 'self' policy; control: a refused key -> 503 + stale with the reason, then recovery"

# --- 3. the key is nowhere ---
grep -rF "${KEY}" "${D}/board.log" "${D}/snap.json" "${D}/snap-stale.json" && fail "the API key is in a response or the log"
for P in / /board.js /board.css /api/board /healthz /nonexistent; do
	curl -s -D - --max-time 5 -H "${BH}" "${B}${P}" 2>/dev/null | grep -qF "${KEY}" && fail "the API key is in the response to ${P}"
done
grep -F "${KEY}" "${D}/plane-calls.log" > /dev/null || fail "the stub Plane never saw the key (then nothing was read with it)"
grep -q '^WRITE' "${D}/plane-calls.log" && fail "the board wrote to Plane: $(grep '^WRITE' "${D}/plane-calls.log" | head -2)"
grep -q 'cursor=' "${D}/plane-calls.log" || fail "the board did not follow the work items' second page"
# CONTROL: a server copy that leaks the key into the snapshot
mkdir -p "${D}/mutant"
cp -r "${AGENT_DIR}/board-ui" "${D}/mutant/"
python3 - "${AGENT_DIR}/board-server.py" "${D}/mutant/board-server.py" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = '"workspace": WORKSPACE, "project": board["project"],'
assert anchor in s, "the control's anchor moved"
open(sys.argv[2], "w").write(s.replace(anchor, anchor + ' "debug_key": load_key(AUTH_FILE),'))
PY
MUT=$(serve "${PORT_BOARD_MUTANT}" "${D}/mutant.log" "${D}/mutant/board-server.py")
PIDS+=("${MUT}")
upto 200 -H "Host: board.localhost:${PORT_BOARD_MUTANT}" "http://127.0.0.1:${PORT_BOARD_MUTANT}/api/board" || fail "the control server gave no snapshot"
curl -s --max-time 5 -H "Host: board.localhost:${PORT_BOARD_MUTANT}" "http://127.0.0.1:${PORT_BOARD_MUTANT}/api/board" | grep -qF "${KEY}" \
	|| fail "CONTROL: the leaking copy's snapshot does not carry the key - the scan above could not have caught a leak"
kill "${MUT}" 2>/dev/null
echo "ok 3 - the key (${#KEY} chars) is in no response and no log line, Plane saw it and took no write, both pages were read; control: a leaking copy is caught"

# --- 4. read-only and own-origin ---
# the five methods with a handler, and two the server has none for (TRACE, an arbitrary token): the same 405, the same
# headers (no stdlib HTML error page), and the Host check first
for M in POST PUT DELETE OPTIONS PATCH TRACE PROPFIND; do
	curl -s -D "${D}/m.h" -o "${D}/m.b" --max-time 5 -X "${M}" -H "${BH}" "${B}/api/board"
	grep -q '^HTTP/1.[01] 405' "${D}/m.h" || fail "${M} /api/board is not refused with 405: $(head -1 "${D}/m.h")"
	grep -qi '^Allow: GET, HEAD' "${D}/m.h" || fail "${M} /api/board: no Allow: GET, HEAD"
	grep -qi '^Cache-Control: no-store' "${D}/m.h" && grep -qi '^Content-Security-Policy: ' "${D}/m.h" && grep -qi '^X-Content-Type-Options: nosniff' "${D}/m.h" \
		|| fail "${M} /api/board: the refusal lacks the headers every response carries"
	grep -qi '^Content-Type: text/plain' "${D}/m.h" || fail "${M} /api/board: the refusal is not plain text (the stdlib's HTML error page?)"
	[ "$(code -X "${M}" -H "${BH}" "${B}/")" == "405" ] || fail "${M} / is not refused with 405"
	[ "$(code -X "${M}" -H "Host: evil.example:${PORT_BOARD}" "${B}/")" == "421" ] || fail "${M} with a foreign Host is not refused with 421"
done
# a malformed request line (four words, a valid version: the stdlib's 400 "Bad request syntax") is refused as plain text with
# the headers too; a request whose version the stdlib cannot read is answered without any header by the stdlib itself
# (HTTP/0.9 mode), which no handler can change - so that case is only checked to carry no HTML
printf 'GET /api/board junk HTTP/1.1\r\nHost: %s\r\n\r\n' "board.localhost:${PORT_BOARD}" | timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT_BOARD}; cat >&3; cat <&3" > "${D}/bad.h" 2>/dev/null
grep -q '^HTTP/1.[01] 400' "${D}/bad.h" && grep -qi '^Cache-Control: no-store' "${D}/bad.h" && grep -qi '^Content-Type: text/plain' "${D}/bad.h" && ! grep -qi '<html' "${D}/bad.h" \
	|| fail "a malformed request line is not refused as plain text 400 with the headers: $(head -1 "${D}/bad.h")"
printf 'GET /api/board HTTP/9.9\r\nHost: %s\r\n\r\n' "board.localhost:${PORT_BOARD}" | timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT_BOARD}; cat >&3; cat <&3" > "${D}/bad2.h" 2>/dev/null
grep -qi '<html' "${D}/bad2.h" && fail "an unreadable HTTP version is answered with the stdlib's HTML page"
[ "$(code -I -H "${BH}" "${B}/api/board")" == "200" ] || fail "HEAD /api/board is not answered"
[ "$(code -H "${BH}" -H "Origin: http://board.localhost:${PORT_BOARD}" "${B}/api/board")" == "200" ] || fail "the board's own origin is refused"
[ "$(code -H "${BH}" -H "Origin: http://evil.localhost:${PORT_BOARD}" "${B}/api/board")" == "403" ] || fail "a foreign Origin (another *.localhost host) is not refused"
[ "$(code -H "${BH}" -H "Origin: http://localhost:${PORT_BOARD}" "${B}/api/board")" == "200" ] || fail "a loopback Origin on the same port is refused"
[ "$(code -H "${BH}" -H "Origin: http://board.localhost:1" "${B}/api/board")" == "403" ] || fail "the board's host on another port is not refused"
[ "$(code -H "${BH}" -H "Origin: https://example.com" "${B}/api/board")" == "403" ] || fail "an external Origin is not refused"
[ "$(code -H "${BH}" -H "Origin: null" "${B}/api/board")" == "403" ] || fail "an opaque null Origin is not refused"
[ "$(code -H "${BH}" -H "Sec-Fetch-Site: cross-site" "${B}/api/board")" == "403" ] || fail "Sec-Fetch-Site cross-site is not refused"
[ "$(code -H "${BH}" -H "Sec-Fetch-Site: same-site" "${B}/api/board")" == "403" ] || fail "Sec-Fetch-Site same-site (another host of the same site) is not refused"
[ "$(code -H "${BH}" -H "Sec-Fetch-Site: same-origin" "${B}/api/board")" == "200" ] || fail "Sec-Fetch-Site same-origin is refused"
[ "$(code -H "${BH}" -H "Sec-Fetch-Site: none" "${B}/api/board")" == "200" ] || fail "a direct navigation (Sec-Fetch-Site none) is refused"
for P in / /api/board /healthz /board.js; do
	[ "$(code -H "Host: evil.example:${PORT_BOARD}" "${B}${P}")" == "421" ] || fail "a foreign Host is not refused with 421 on ${P}"
	[ "$(code -H "Host: evil.localhost:${PORT_BOARD}" "${B}${P}")" == "421" ] || fail "another *.localhost Host is not refused with 421 on ${P}"
done
[ "$(code "${B}/")" == "200" ] || fail "the loopback Host (no header) is refused"
# the page itself is a navigation from the home page (another host): it must not carry the data endpoint's origin guard
[ "$(code -H "${BH}" -H "Sec-Fetch-Site: cross-site" -H "Sec-Fetch-Mode: navigate" "${B}/")" == "200" ] || fail "the tile's own navigation to the page is refused"
# CONTROL: a server copy without the origin guard answers a foreign Origin
python3 - "${AGENT_DIR}/board-server.py" "${D}/mutant/board-server.py" << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = "            if not origin_ok(self.headers, host):\n                return self.text(403,"
assert anchor in s, "the control's anchor moved"
open(sys.argv[2], "w").write(s.replace(anchor, "            if False:\n                return self.text(403,"))
PY
MUT=$(serve "${PORT_BOARD_MUTANT}" "${D}/mutant2.log" "${D}/mutant/board-server.py")
PIDS+=("${MUT}")
upto 200 -H "Host: board.localhost:${PORT_BOARD_MUTANT}" "http://127.0.0.1:${PORT_BOARD_MUTANT}/api/board" || fail "the control server gave no snapshot"
[ "$(code -H "Host: board.localhost:${PORT_BOARD_MUTANT}" -H "Origin: https://example.com" "http://127.0.0.1:${PORT_BOARD_MUTANT}/api/board")" == "200" ] \
	|| fail "CONTROL: the copy without the origin guard refused a foreign Origin - the check above proves nothing"
kill "${MUT}" 2>/dev/null
echo "ok 4 - POST/PUT/DELETE/OPTIONS/PATCH/TRACE/PROPFIND 405 with Allow and the headers, a malformed line 400 as text; a foreign, external, null or other-port Origin and a cross-site or same-site fetch 403; own origin, no Origin, same-origin and the navigation 200; a foreign Host 421; control: without the guard a foreign Origin passes"

# --- 5. through the home proxy ---
if ! command -v nginx > /dev/null; then
	fail "nginx is not installed (setup/install-nginx.sh) - the route checks cannot run"
fi
render()
{
	# render <UI_DIR> [VAR=value ...] - home-render.sh with the Board on, Plane present and every other UI off
	OUT=$1; shift
	env UI_DIR="${OUT}" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME="${PORT_HOME}" UI_PORT_BOARD="${PORT_BOARD}" \
		UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false \
		UI_LOGLEARNER=false COMMS_UI_ENABLED=false UI_HOME=true UI_PLANE=true PLANE_LOGIN_BYPASS=false \
		PLANE_URL="http://127.0.0.1:${PORT_PLANE}" UI_BOARD=true NORTH_STAR_JSON="${REGISTER}" "$@" \
		bash "${AGENT_DIR}/home-render.sh"
}
render "${D}/ui" > "${D}/render.log" 2>&1 || { cat "${D}/render.log"; fail "home-render.sh"; }
CONF=${D}/ui/home/nginx.conf
PAGE=${D}/ui/${SITE}/index.html
nginx -t -c "${CONF}" > "${D}/nginx-t.log" 2>&1 || { cat "${D}/nginx-t.log"; fail "the rendered nginx.conf does not pass nginx -t"; }
nginx -c "${CONF}" -g "daemon off;" > "${D}/nginx.log" 2>&1 &
PIDS+=($!)
upto 200 "${H}/" || fail "the home page does not answer on the test port"
LH="board.localhost:${PORT_HOME}"
# the board server's own policy (check 4 reads it from the server): the route's must be exactly this plus the badge's
# three hashes
SERVER_CSP="default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
badge_check()
{
	# badge_check <header file> <page file> <port> - the page carries the badge once, returning to //localhost:<port>/;
	# its three inline parts (the style attribute, the phone rule, the keeper script) are the page's only inline parts,
	# each allowed by its sha256 in the route's policy; that policy is exactly the server's own plus those three hashes
	python3 - "$1" "$2" "$3" "${SERVER_CSP}" << 'PY'
import base64, hashlib, re, sys
head, page, port, server = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3], sys.argv[4]
csp = [l.split(":", 1)[1].strip() for l in head.splitlines() if l.lower().startswith("content-security-policy:")]
if len(csp) != 1:
    sys.exit("the route sends %d Content-Security-Policy headers (want exactly 1)" % len(csp))
csp = csp[0]
h = lambda s: "'sha256-%s'" % base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()
def directives(policy):
    d = {}
    for part in policy.split(";"):
        bits = part.strip().split()
        if bits and bits[0].lower() not in d:
            d[bits[0].lower()] = bits[1:]
    return d
marker = '<a class="hs-badge" data-harness-home'
m = re.search(r'<a class="hs-badge" data-harness-home href="([^"]*)"[^>]*style="([^"]*)"[^>]*>', page)
if page.count(marker) != 1 or not m:
    sys.exit("the badge is not in the page exactly once (%d)" % page.count(marker))
if m.group(1) != "//localhost:%s/" % port:
    sys.exit("the badge returns to %s" % m.group(1))
k = re.search(r'</a><style id="do-agent-aws-home-style">([^<]*)</style><script>([^<]*)</script>', page)
if not k:
    sys.exit("the badge's phone-width rule and keeper script are not in the page right after it")
inline = len(re.findall(r"<script(?![^>]*\bsrc=)[^>]*>", page)) + page.count("<style") + page.count("style=")
if inline != 3:
    sys.exit("the page carries %d inline parts (want the badge's three: its style attribute, rule and script)" % inline)
d = directives(csp)
style, script = d.get("style-src", []), d.get("script-src", [])
if not ("'unsafe-hashes'" in style and h(m.group(2)) in style):
    sys.exit("the route's policy does not allow the badge's style attribute by hash: %s" % csp)
if h(k.group(1)) not in style:
    sys.exit("the route's policy does not allow the badge's phone-width rule by hash: %s" % csp)
if h(k.group(2)) not in script:
    sys.exit("the route's policy does not allow the badge's keeper script by hash: %s" % csp)
want = directives(server)
want["script-src"] = ["'self'", h(k.group(2))]
want["style-src"] = ["'self'", "'unsafe-hashes'", h(m.group(2)), h(k.group(1))]
if d != want:
    sys.exit("the route's policy is not the server's own plus the badge's three hashes: %s" % csp)
if page.count('href="/__harness/harness.css"') != 1:
    sys.exit("the page links the stylesheet %d times (the page's own link, and the badge adds none)" % page.count('href="/__harness/harness.css"'))
if "<title>Board - do-agent-aws harness</title>" not in page:
    sys.exit("the route did not serve the Board page")
print("badge once, back to //localhost:%s/, its three inline parts (the page's only ones) each allowed by hash, the policy "
      "exactly the server's own plus those hashes, one stylesheet link" % port)
PY
}
badge_ok()
{
	# badge_ok <url> <host> - badge_check on the page the route serves
	curl -s -D "${D}/badge.h" -o "${D}/badge.html" --max-time 5 -H "Host: $2" "$1/"
	badge_check "${D}/badge.h" "${D}/badge.html" "${2#*:}"
}
BO=$(badge_ok "${H}" "${LH}" 2>&1) || fail "${BO}"
cp "${D}/badge.h" "${D}/badge-real.h" && cp "${D}/badge.html" "${D}/badge-real.html" || fail "could not keep the page the route served"
[ "$(code -X POST -H "Host: ${LH}" "${H}/api/board")" == "403" ] || fail "POST through the route is not refused by the proxy (limit_except GET)"
[ "$(code -H "Host: ${LH}" "${H}/api/board")" == "200" ] || fail "the snapshot does not answer through the route"
[ "$(code -H "Host: ${LH}" "${H}/board.js")" == "200" ] || fail "the page's script does not answer through the route"
curl -s --max-time 5 -H "Host: ${LH}" "${H}/api/board" | grep -qF "${KEY}" && fail "the key is in the snapshot served through the route"
grep -qF 'data-host="board" data-probe="/__probe/board" data-path="/"' "${PAGE}" || fail "the Board tile does not carry its probe"
upto 204 "${H}/__probe/board" || fail "the dot probe /__probe/board is not 204 while the server is fresh ($(code "${H}/__probe/board"))"
[ "$(code -X POST "${H}/__probe/board")" == "403" ] || fail "the probe is not GET-only"
touch "${D}/plane-refuse"
UPTO_TRIES=40 upto 500 "${H}/__probe/board" || fail "the dot probe stayed $(code "${H}/__probe/board") 10 s after Plane refused the key (the server's 503 must read down at the next pass)"
rm -f "${D:?}/plane-refuse"
upto 204 "${H}/__probe/board" || fail "the dot probe did not recover with Plane"
kill "${SRV}" 2>/dev/null
upto 500 "${H}/__probe/board" || fail "the dot probe is not 500 with the server stopped ($(code "${H}/__probe/board"))"
[ "$(code -H "Host: ${LH}" "${H}/")" == "502" ] || fail "the route does not read 502 with the server stopped"
SRV=$(serve "${PORT_BOARD}" "${D}/board2.log")
PIDS+=("${SRV}")
upto 204 "${H}/__probe/board" || fail "the dot probe did not come back with the server"
# CONTROL: the route without its badge include
mkdir -p "${D}/mutant-home"
python3 - "${AGENT_DIR}/home-render.sh" "${D}/mutant-home/home-render.sh" << 'PY' || fail "CONTROL: the badge-include mutant could not be planted"
import sys
s = open(sys.argv[1]).read()
anchor = ('\t\t\tproxy_pass http://127.0.0.1:${UI_PORT_BOARD};\n\t\t\tinclude ${HOME_DIR}/proxy-common.conf;\n'
          '$(host_redirect_rules "${UI_PORT_BOARD}")\n\t\t\tinclude ${HOME_DIR}/badge-host-nolink.conf;\n')
assert anchor in s, "the board route's badge include is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, anchor.replace("\t\t\tinclude ${HOME_DIR}/badge-host-nolink.conf;\n", "")))
PY
env UI_DIR="${D}/mutant-ui" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME="${PORT_HOME_MUTANT}" UI_PORT_BOARD="${PORT_BOARD}" \
	UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false \
	UI_LOGLEARNER=false COMMS_UI_ENABLED=false UI_HOME=true UI_PLANE=true PLANE_LOGIN_BYPASS=false \
	PLANE_URL="http://127.0.0.1:${PORT_PLANE}" UI_BOARD=true NORTH_STAR_JSON="${REGISTER}" \
	bash "${D}/mutant-home/home-render.sh" > /dev/null 2>&1 || fail "the mutant home-render.sh did not render"
nginx -c "${D}/mutant-ui/home/nginx.conf" -g "daemon off;" > "${D}/nginx-mutant.log" 2>&1 &
PIDS+=($!)
upto 200 "http://127.0.0.1:${PORT_HOME_MUTANT}/" || fail "the mutant proxy did not come up"
MB=$(badge_ok "http://127.0.0.1:${PORT_HOME_MUTANT}" "board.localhost:${PORT_HOME_MUTANT}" 2>&1) && fail "CONTROL: without the route's badge include the badge check passed: ${MB}"
case "${MB}" in *"the badge is not in the page exactly once"*) ;; *) fail "CONTROL: the badge-include mutant failed for another reason: ${MB}" ;; esac
kill "$(cat "${D}/mutant-ui/home/nginx.pid" 2>/dev/null)" 2>/dev/null
# CONTROL: a policy that lacks only the keeper script's hash - a browser refuses the script there - must fail the badge
# check, for that reason (the shared source both policies are built from, emptied)
mkdir -p "${D}/mutant-csp"
python3 - "${AGENT_DIR}/home-render.sh" "${D}/mutant-csp/home-render.sh" << 'PY' || fail "CONTROL: the policy mutant could not be planted"
import sys
s = open(sys.argv[1]).read()
anchor = "BADGE_SCRIPT_SRC=\"'${BADGE_KEEPER_SHA}'\"\n"
assert s.count(anchor) == 1, "the badge's script source is not defined where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, "BADGE_SCRIPT_SRC=\"\"\n"))
PY
env UI_DIR="${D}/mutant-csp-ui" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME="${PORT_HOME_MUTANT2}" UI_PORT_BOARD="${PORT_BOARD}" \
	UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false \
	UI_LOGLEARNER=false COMMS_UI_ENABLED=false UI_HOME=true UI_PLANE=true PLANE_LOGIN_BYPASS=false \
	PLANE_URL="http://127.0.0.1:${PORT_PLANE}" UI_BOARD=true NORTH_STAR_JSON="${REGISTER}" \
	bash "${D}/mutant-csp/home-render.sh" > /dev/null 2>&1 || fail "the policy mutant home-render.sh did not render"
nginx -c "${D}/mutant-csp-ui/home/nginx.conf" -g "daemon off;" > "${D}/nginx-mutant-csp.log" 2>&1 &
PIDS+=($!)
upto 200 "http://127.0.0.1:${PORT_HOME_MUTANT2}/" || fail "the policy mutant proxy did not come up"
MK=$(badge_ok "http://127.0.0.1:${PORT_HOME_MUTANT2}" "board.localhost:${PORT_HOME_MUTANT2}" 2>&1) && fail "CONTROL: a policy without the keeper's hash passed the badge check: ${MK}"
case "${MK}" in *"keeper script by hash"*) ;; *) fail "CONTROL: the policy mutant failed for another reason: ${MK}" ;; esac
kill "$(cat "${D}/mutant-csp-ui/home/nginx.pid" 2>/dev/null)" 2>/dev/null
# PLANTED CONTROLS on the page the route served: each of the badge's three hashes taken out of the policy, an inline part
# the badge does not bring, and a source the server's own policy does not have - each fails the check for its own reason
python3 - "${D}/badge-real.h" "${D}/badge-real.html" "${D}/planted" << 'PY' || fail "PLANTED CONTROL: the planted copies could not be written"
import base64, hashlib, re, sys
head, page, out = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
h = lambda s: "'sha256-%s'" % base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()
m = re.search(r'<a class="hs-badge" data-harness-home [^>]*style="([^"]*)"[^>]*>', page)
k = re.search(r'</a><style id="do-agent-aws-home-style">([^<]*)</style><script>([^<]*)</script>', page)
assert m and k, "the served page has no badge to plant against"
for name, value in (("attr", m.group(1)), ("rule", k.group(1)), ("keeper", k.group(2))):
    assert head.count(" " + h(value)) == 1, "the %s hash is not in the served policy exactly once" % name
    open("%s-%s.h" % (out, name), "w").write(head.replace(" " + h(value), "", 1))
    open("%s-%s.html" % (out, name), "w").write(page)
assert page.count("</body>") == 1 and head.count("img-src 'self' data:;") == 1
open(out + "-inline.h", "w").write(head)
open(out + "-inline.html", "w").write(page.replace("</body>", "<style>p{}</style></body>"))
open(out + "-wider.h", "w").write(head.replace("img-src 'self' data:;", "img-src 'self' data: https:;"))
open(out + "-wider.html", "w").write(page)
PY
PC=""
for C in "attr:style attribute by hash" "rule:phone-width rule by hash" "keeper:keeper script by hash" "inline:inline parts" \
	"wider:not the server's own plus"; do
	R=$(badge_check "${D}/planted-${C%%:*}.h" "${D}/planted-${C%%:*}.html" "${PORT_HOME}" 2>&1) && fail "PLANTED CONTROL ${C%%:*}: the badge check passed: ${R}"
	case "${R}" in *"${C#*:}"*) ;; *) fail "PLANTED CONTROL ${C%%:*}: the badge check failed for another reason: ${R}" ;; esac
	PC="${PC}${PC:+; }${C%%:*}: ${R%%: default-src*}"
done
# CONTROL: a csp_hash that prints nothing (python3 failing) stops the render loudly, instead of leaving a policy that
# nginx accepts and the browser uses to refuse the badge
mkdir -p "${D}/mutant-hash"
python3 - "${AGENT_DIR}/home-render.sh" "${D}/mutant-hash/home-render.sh" << 'PY' || fail "CONTROL: the empty-hash mutant could not be planted"
import sys
s = open(sys.argv[1]).read()
anchor = "\tprintf '%s' \"$1\" | python3 -c 'import base64, hashlib, sys; print(\"sha256-\" + base64.b64encode(hashlib.sha256(sys.stdin.buffer.read()).digest()).decode())'\n"
assert s.count(anchor) == 1, "csp_hash is not defined where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, "\ttrue\n"))
PY
env UI_DIR="${D}/mutant-hash-ui" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME="${PORT_HOME_MUTANT2}" UI_PORT_BOARD="${PORT_BOARD}" \
	UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false \
	UI_LOGLEARNER=false COMMS_UI_ENABLED=false UI_HOME=true UI_PLANE=true PLANE_LOGIN_BYPASS=false \
	PLANE_URL="http://127.0.0.1:${PORT_PLANE}" UI_BOARD=true NORTH_STAR_JSON="${REGISTER}" \
	bash "${D}/mutant-hash/home-render.sh" > "${D}/mutant-hash.log" 2>&1 && fail "CONTROL: home-render.sh rendered with an empty badge hash"
EH=$(grep -o "home-render: ERROR - a hash of the home badge's inline pieces is empty or malformed[^;]*" "${D}/mutant-hash.log") \
	|| fail "CONTROL: the empty-hash render failed for another reason: $(tail -n 2 "${D}/mutant-hash.log")"
echo "ok 5 - through the proxy: ${BO}; POST 403; the dot 204 fresh, 500 with the key refused, 500 with the server stopped, 204 back; control: without its include -> ${MB}; control: without the keeper's hash -> ${MK}; planted: ${PC}; control: an empty hash -> ${EH}"

# --- 6. the tile, for each reason ---
tile_note()
{
	grep -oE '>Board</span><p>[^<]*</p><p class="note">[^<]*' "$1/${SITE}/index.html" | sed -E 's/.*<p class="note">//'
}
render "${D}/ui-off" UI_BOARD=false > /dev/null 2>&1 || fail "render UI_BOARD=false"
[ "$(tile_note "${D}/ui-off")" == "off - set UI_BOARD=true in .env" ] || fail "UI_BOARD=false: the tile reads '$(tile_note "${D}/ui-off")'"
render "${D}/ui-noplane" UI_PLANE=false > /dev/null 2>&1 || fail "render UI_PLANE=false"
# the Plane board off (the shipped default): no Board tile, greyed or live, and no Plane tile either - the board is opt-in and
# nothing of it is shown (docs/manual/boards.md "Plane board"); the page names no UI_PLANE flag to flip
grep -qE '<li class="tile[^>]*><span class="dot"></span>(<span class="title">|<a [^>]*>)Board<' "${D}/ui-noplane/${SITE}/index.html" && fail "UI_PLANE=false: a Board tile is rendered: $(grep -oE '<li class="tile[^>]*><span class="dot"></span>(<span class="title">|<a [^>]*>)Board<[^<]*' "${D}/ui-noplane/${SITE}/index.html" | head -1)"
grep -qE '<li class="tile[^>]*><span class="dot"></span>(<span class="title">|<a [^>]*>)Project board \(Plane\)<' "${D}/ui-noplane/${SITE}/index.html" && fail "UI_PLANE=false: a Plane tile is rendered"
grep -q 'UI_PLANE' "${D}/ui-noplane/${SITE}/index.html" && fail "UI_PLANE=false: the page names the UI_PLANE flag"
render "${D}/ui-notarget" PLANE_URL= > /dev/null 2>&1 || fail "render PLANE_URL="
tile_note "${D}/ui-notarget" | grep -qF "not on this target - ./run.sh with TO=docker runs Plane as sidecar containers, which the Board reads" || fail "PLANE_URL unset: the tile reads '$(tile_note "${D}/ui-notarget")'"
for V in ui-off ui-noplane ui-notarget; do
	grep -q 'server_name board.localhost' "${D}/${V}/home/nginx.conf" && fail "${V}: the board route is rendered although the Board is not served"
	grep -q '/__probe/board' "${D}/${V}/home/nginx.conf" && fail "${V}: the board probe is rendered although the Board is not served"
	grep -q 'data-host="board"' "${D}/${V}/${SITE}/index.html" && fail "${V}: the tile is live although the Board is not served"
done
# a new tab that keeps its opener, like every tile: the badge on the page it opens returns to the home tab by its name
grep -qE '<li class="tile" data-host="board" data-probe="/__probe/board" data-path="/"><span class="dot"></span><a [^>]*target="_blank" rel="opener"[^>]*>Board</a>' "${PAGE}" \
	|| fail "with everything on the Board tile is not a live tile opening a new tab"
echo "ok 6 - the tile: off with its flag; no Board tile and no Plane tile with the Plane board off (UI_PLANE=false, the default); grey 'not on this target'; live with its probe when all is on; no route or probe in the three off cases"

# --- 7. the North Star section equals the register ---
compare_ns()
{
	# compare_ns <index.html> <register.json> [<NORTH-STAR.md>] - the page's rows equal the register's (and the document's)
	python3 - "$@" << 'PY'
import html, json, re, sys
page = open(sys.argv[1], encoding="utf-8").read()
reg = json.load(open(sys.argv[2], encoding="utf-8"))
sec = re.search(r'<section class="north-star[^>]*>.*?</section>', page, re.S)
if not sec:
    sys.exit("no North Star section on the page")
rows = re.findall(r'<tr data-ns-id="([^"]*)" data-ns-status="([^"]*)" data-ns-today="([^"]*)">(.*?)</tr>', sec.group(0), re.S)
# a row scored NO has no check and no today: an empty attribute, "no tracked check" and a dash, as for an agent
want = [(r["id"], r["status"], r["today"] or "") for r in reg["rows"]]
have = [(html.unescape(a), html.unescape(b), html.unescape(c)) for a, b, c, _ in rows]
if have != want:
    sys.exit("the page's rows %r differ from the register's %r" % (have, want))
for (_, _, _, body), r in zip(rows, reg["rows"]):
    check = re.search(r'<td data-label="Check">(.*?)</td>', body, re.S)
    shown = check and html.unescape(re.sub(r"<[^>]+>", "", check.group(1)))
    if shown != (r["check"] or "no tracked check"):
        sys.exit("row %s: the page names the check %r, the register %r" % (r["id"], shown, r["check"]))
    goal = re.search(r'<td data-label="The harness must">(.*?)</td>', body, re.S)
    if not goal or html.unescape(goal.group(1)) != r["goal"]:
        sys.exit("row %s: the goal text differs from the register" % r["id"])
if 'data-ns-rows="%d"' % len(want) not in sec.group(0):
    sys.exit("the section's row count differs from the register's")
# the agents of the stack: name, North Star, the UI it keeps, who it talks to, and its score - the check (or "no tracked
# check"), the verdict, today (a dash when it has none) and the caveat - equal to the register's
agents = reg.get("agents") or []
arows = re.findall(r'<tr data-ns-agent="([^"]*)" data-ns-agent-status="([^"]*)" data-ns-agent-today="([^"]*)">(.*?)</tr>', sec.group(0), re.S)
if len(arows) != len(agents) or 'data-ns-agents="%d"' % len(agents) not in sec.group(0):
    sys.exit("the page lists %d agents, the register %d" % (len(arows), len(agents)))
for (name, st, today, body), x in zip(arows, agents):
    cells = [html.unescape(re.sub(r"<[^>]+>", "", c)) for c in re.findall(r"<td[^>]*>(.*?)</td>", body, re.S)]
    acells = [x["agent"], x["north_star"], x["ui"], x["talks_to"], x.get("check") or "no tracked check", x.get("status", ""),
              x.get("today") or "-", x.get("caveat", "")]
    if html.unescape(name) != x["agent"] or cells != acells or (html.unescape(st), html.unescape(today)) != (x.get("status", ""), x.get("today") or ""):
        sys.exit("agent %r on the page differs from the register: %r" % (html.unescape(name), cells))
# the components' own North Stars: name, agent, where (its URL a link), as of and state
comps = reg.get("components") or []
crows = re.findall(r'<tr data-ns-component="([^"]*)">(.*?)</tr>', sec.group(0), re.S)
if len(crows) != len(comps) or (comps and 'data-ns-components="%d"' % len(comps) not in sec.group(0)):
    sys.exit("the page lists %d components, the register %d" % (len(crows), len(comps)))
for (name, body), c in zip(crows, comps):
    cells = [html.unescape(re.sub(r"<[^>]+>", "", v)) for v in re.findall(r"<td[^>]*>(.*?)</td>", body, re.S)]
    if html.unescape(name) != c["name"] or cells != [c["name"], c["agent"], c["where"], c["as_of"], c["state"]]:
        sys.exit("component %r on the page differs from the register: %r" % (html.unescape(name), cells))
# below the tiles, above the footer
ul, s, foot = page.find("</ul>"), page.find('<section class="north-star'), page.find("<footer>")
if not (0 < ul < s < foot):
    sys.exit("the section is not between the tiles and the footer")
if "docs/NORTH-STAR.md" not in sec.group(0):
    sys.exit("the section does not link docs/NORTH-STAR.md")
if len(sys.argv) > 3:
    doc = open(sys.argv[3], encoding="utf-8").read()
    drows = [(i, v.replace("\\*", "*"), "" if t == "-" else t) for i, v, t in
             re.findall(r'^\| (NS-\d+) \| .*? \| (?:`[^`]*`|no tracked check) \| \*\*((?:[A-Z]|\\\*)+)\*\* \| ([A-Z]+|-) \|', doc, re.M)]
    if drows != want:
        sys.exit("docs/NORTH-STAR.md's rows %r differ from the register's %r" % (drows, want))
    for r in reg["rows"]:
        if "| %s |" % ("`%s`" % r["check"] if r["check"] else "no tracked check") not in doc:
            sys.exit("docs/NORTH-STAR.md does not name row %s's check as the register does" % r["id"])
    lines = doc.split("\n")
    for x in reg.get("agents") or []:
        check = "`%s`" % x["check"] if x.get("check") else "no tracked check"
        if "| `%s` | %s | %s | %s | %s | **%s** | %s | %s |" % (x["agent"], x["north_star"], x["ui"], x["talks_to"], check,
                                                              x["status"].replace("*", "\\*"), x.get("today") or "-", x["caveat"]) not in lines:
            sys.exit("docs/NORTH-STAR.md's agents table differs from the register for %s" % x["agent"])
    for c in comps:
        if "| %s | `%s` | %s | %s | %s |" % (c["name"], c["agent"], c["where"], c["as_of"], c["state"]) not in lines:
            sys.exit("docs/NORTH-STAR.md's components table differs from the register for %s" % c["name"])
print("%d rows, %d agents and %d components equal%s" % (len(want), len(agents), len(comps), "; the document's tables equal them too" if len(sys.argv) > 3 else ""))
PY
}
[ -s "${REGISTER}" ] || fail "the image ships no register at ${REGISTER}"
NS=$(compare_ns "${PAGE}" "${REGISTER}" 2>&1) || fail "the North Star section differs from the shipped register: ${NS}"
if [ -f "${CHECKOUT}/docs/north-star.json" ]; then
	cmp -s "${CHECKOUT}/docs/north-star.json" "${REGISTER}" || fail "the image's ${REGISTER} differs from the checkout's docs/north-star.json - rebuild the image"
	NS2=$(compare_ns "${PAGE}" "${CHECKOUT}/docs/north-star.json" "${CHECKOUT}/docs/NORTH-STAR.md" 2>&1) || fail "the page, the checkout's register and docs/NORTH-STAR.md disagree: ${NS2}"
	grep -q 'docs/NORTH-STAR.md' "${CHECKOUT}/README.md" || fail "the README does not link docs/NORTH-STAR.md"
	NS="${NS2}; the image's copy equals the checkout's"
else
	NS="${NS} (no checkout at ${CHECKOUT}: the document's table was not compared here)"
fi
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == "do-agent-aws-north-star/v1" and d["rows"], "schema"
for r in d["rows"]:
    assert r["status"] in d["scoring"], r["id"] + ": a verdict outside the scoring"
    assert r["today"] in d["today_values"] or (r["today"] is None and r["status"] == "NO"), r["id"] + ": a today value outside the legend"
    assert r["goal"].strip(), r["id"] + ": an empty goal"
    assert r["status"] == "NO" or (r["check"] or "").strip() not in ("", "-"), r["id"] + ": a YES verdict with no check"
' "${REGISTER}" || fail "the register is not consistent with its own legend"
# CONTROL: a planted register with one verdict changed
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["rows"][0]["status"] = "YES"; d["rows"][0]["today"] = "PASS"; json.dump(d, open(sys.argv[2], "w"))' "${REGISTER}" "${D}/mutant-register.json"
render "${D}/ui-mutant-ns" NORTH_STAR_JSON="${D}/mutant-register.json" > /dev/null 2>&1 || fail "render with the planted register"
MN=$(compare_ns "${D}/ui-mutant-ns/${SITE}/index.html" "${REGISTER}" 2>&1) && fail "CONTROL: a page rendered from a changed register passed the comparison with the shipped one: ${MN}"
compare_ns "${D}/ui-mutant-ns/${SITE}/index.html" "${D}/mutant-register.json" > /dev/null 2>&1 || fail "the page does not follow the register it was rendered from"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["agents"][0]["north_star"] = "something else"; json.dump(d, open(sys.argv[2], "w"))' "${REGISTER}" "${D}/mutant-agents.json"
render "${D}/ui-mutant-agents" NORTH_STAR_JSON="${D}/mutant-agents.json" > /dev/null 2>&1 || fail "render with the planted agents register"
MA=$(compare_ns "${D}/ui-mutant-agents/${SITE}/index.html" "${REGISTER}" 2>&1) && fail "CONTROL: a page rendered from a register with one agent's North Star changed passed the comparison with the shipped one: ${MA}"
echo "${MA}" | grep -q "^agent 'agent' on the page differs" || fail "the agents control failed for the wrong reason: ${MA}"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["agents"][1]["status"] = "YES"; json.dump(d, open(sys.argv[2], "w"))' "${REGISTER}" "${D}/mutant-agent-verdict.json"
render "${D}/ui-mutant-verdict" NORTH_STAR_JSON="${D}/mutant-agent-verdict.json" > /dev/null 2>&1 || fail "render with the planted agent verdict"
MV=$(compare_ns "${D}/ui-mutant-verdict/${SITE}/index.html" "${REGISTER}" 2>&1) && fail "CONTROL: a page rendered from a register with one agent's verdict changed passed the comparison with the shipped one: ${MV}"
echo "${MV}" | grep -q "^agent 'supervisor' on the page differs" || fail "the agent verdict control failed for the wrong reason: ${MV}"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["components"][0]["state"] = "something else"; json.dump(d, open(sys.argv[2], "w"))' "${REGISTER}" "${D}/mutant-component.json"
CN=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["components"][0]["name"])' "${REGISTER}")
render "${D}/ui-mutant-component" NORTH_STAR_JSON="${D}/mutant-component.json" > /dev/null 2>&1 || fail "render with the planted component"
MC=$(compare_ns "${D}/ui-mutant-component/${SITE}/index.html" "${REGISTER}" 2>&1) && fail "CONTROL: a page rendered from a register with one component's state changed passed the comparison with the shipped one: ${MC}"
echo "${MC}" | grep -qF "component '${CN}' on the page differs" || fail "the components control failed for the wrong reason: ${MC}"
render "${D}/ui-missing-ns" NORTH_STAR_JSON="${D}/does-not-exist.json" > "${D}/render-missing.log" 2>&1 || fail "render with a missing register"
grep -q 'the register /tmp/board-smoke/does-not-exist.json is missing or unreadable' "${D}/ui-missing-ns/${SITE}/index.html" || fail "a missing register does not render as a line saying so"
echo '{"rows": [1, "two"]}' > "${D}/bad-register.json"
render "${D}/ui-bad-ns" NORTH_STAR_JSON="${D}/bad-register.json" > "${D}/render-bad.log" 2>&1 || fail "render with a malformed register"
grep -q 'the register /tmp/board-smoke/bad-register.json is missing or unreadable (AssertionError)' "${D}/ui-bad-ns/${SITE}/index.html" || fail "a register whose rows are not objects does not render as a line saying so: $(grep -o '<section class="north-star[^>]*>.\{0,200\}' "${D}/ui-bad-ns/${SITE}/index.html" | head -1)"
echo "ok 7 - the North Star section: ${NS}; controls: a planted verdict change -> ${MN}; a planted agent change, a planted agent verdict and a planted component state are caught; a missing or malformed register says so"

# --- 8. ui-start.sh, ui-status.sh, ui-stop.sh ---
(
	export UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false \
		UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false LOOP_DECK_DATA_DIR="${D}/loop-deck" UI_CHAT=false UI_FILES=false COMMS_UI_ENABLED=false UI_HOME=true UI_PLANE=true \
		PLANE_LOGIN_BYPASS=false UI_BOARD=true UI_PORT_BOARD="${PORT_BOARD_UI}" UI_PORT_HOME="${PORT_HOME_UI}" UI_LISTEN_HOST=127.0.0.1 UI_DIR="${D}/ui2" \
		PLANE_URL="http://127.0.0.1:${PORT_PLANE}" PLANE_AUTH_FILE="${D}/plane.env" PLANE_WORKSPACE=do-agent-aws PLANE_PROJECT=AGENT \
		BOARD_RUNNER_URL="http://127.0.0.1:${PORT_RUNNER}" BOARD_REFRESH=5 NORTH_STAR_JSON="${REGISTER}"
	"${AGENT_DIR}/ui-start.sh" > "${D}/ui-start.log" 2>&1 || { cat "${D}/ui-start.log"; exit 11; }
	grep -q '^board: started' "${D}/ui-start.log" || { cat "${D}/ui-start.log"; exit 12; }
	for _ in $(seq 1 80); do "${AGENT_DIR}/ui-status.sh" > "${D}/ui-status.log" 2>&1 && break; sleep 0.25; done
	grep -q "^board: UP pid=[0-9]* http=200 port=${PORT_BOARD_UI}" "${D}/ui-status.log" || { cat "${D}/ui-status.log"; exit 13; }
	ADDRS=$(ss -ltnH "sport = :${PORT_BOARD_UI}" | awk '{print $4}')
	[ "${ADDRS}" == "127.0.0.1:${PORT_BOARD_UI}" ] || { echo "the board listens on: ${ADDRS}"; exit 14; }
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: board.localhost:${PORT_HOME_UI}" "http://127.0.0.1:${PORT_HOME_UI}/")" == "200" ] || exit 15
	"${AGENT_DIR}/ui-stop.sh" > "${D}/ui-stop.log" 2>&1
	grep -q '^board: stopped' "${D}/ui-stop.log" || { cat "${D}/ui-stop.log"; exit 16; }
	[ -f "${D}/ui2/board.pid" ] && exit 17
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT_BOARD_UI}/healthz")" == "000" ] || exit 18
	# no Plane on this target: nothing starts, the status says so
	export PLANE_URL=
	"${AGENT_DIR}/ui-start.sh" > "${D}/ui-start2.log" 2>&1 || { cat "${D}/ui-start2.log"; exit 19; }
	grep -q '^board:' "${D}/ui-start2.log" && exit 20
	"${AGENT_DIR}/ui-status.sh" > "${D}/ui-status2.log" 2>&1
	grep -q '^board: NOT CONFIGURED' "${D}/ui-status2.log" || { cat "${D}/ui-status2.log"; exit 21; }
	"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
	export UI_BOARD=false PLANE_URL="http://127.0.0.1:${PORT_PLANE}"
	"${AGENT_DIR}/ui-status.sh" > "${D}/ui-status3.log" 2>&1
	grep -q '^board: DISABLED' "${D}/ui-status3.log" || { cat "${D}/ui-status3.log"; exit 22; }
	exit 0
)
RC=$?
[ "${RC}" == "0" ] || fail "ui-start/ui-status/ui-stop (step ${RC}; see ${D}/ui-*.log)"
echo "ok 8 - ui-start.sh starts the board on 127.0.0.1 only, ui-status.sh reports it UP, ui-stop.sh stops it; NOT CONFIGURED without Plane, DISABLED with UI_BOARD=false"

if [ "${TEST_CONTAINER}" == "true" ]; then
	W=$(find /wd -mindepth 1 2>/dev/null | wc -l)
	[ "${W}" -eq 0 ] || fail "this test wrote ${W} entries under /wd"
fi
echo "Test-board succeeded"
