#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""board-server.py - the Board: a read-only kanban view of this harness's own Plane project, with the agent runner's
attempts on the cards they belong to (docs/manual/boards.md "Board").

Started by /agent/ui-start.sh (UI_BOARD=true, the default) while the Plane board runs on this target (PLANE_URL, set by
run.sh; UI_PLANE=true - the board is optional and off by default, docs/manual/boards.md "Plane board"; off, this server is not
started and the home page has no Board tile). It listens on 127.0.0.1:UI_PORT_BOARD only; the home proxy is the exposure: host route
board.localhost, and the tile's dot probe /__probe/board is this server's /healthz.

What it shows, and where it comes from:
  columns   the project's states (Backlog, Todo, In Progress, In Review, Done, Cancelled), in Plane's own order
  cards     the project's work items - the agent's goals, which /agent/plane-sync.py mirrors around every loop fire -
            with their key (AGENT-3), priority and last change; never a description (a fire's transcript excerpt lives
            there) and never a person
  strip     on a card, the agent runner's attempts (vibe-kanban's workspaces, read from its local API on this
            container) whose name or branch carries the card's key, each with its branch, its agent sessions and what
            git reports for its worktree; attempts that name no card are listed below the columns
Every 30 seconds (BOARD_REFRESH) one background pass reads Plane (three or four calls, whatever the number of browsers:
the agent's API key is rate-limited to 60 calls a minute) and the runner, and keeps the result as the one snapshot every
request is answered from; the page re-fetches it on the same cadence. When Plane stops answering the last good snapshot
is served marked stale, with the reason, and /healthz turns 503, so the home page's dot and ui-status.sh read down.

Read-only: GET and HEAD only (anything else is 405), no action of any kind reaches Plane or the runner, and the API key
is read from PLANE_AUTH_FILE at each pass, sent as X-Api-Key to PLANE_URL only (loopback or a single-label docker
network name, no redirect ever followed), and appears in no response, no URL and no log line. The data endpoint
/api/board is answered only to its own origin: a request carrying another Origin, or a Sec-Fetch-Site other than
same-origin or none, gets 403; a Host other than board.localhost or a loopback name gets 421 everywhere. Every response
carries Cache-Control: no-store, nosniff, no-referrer and a Content-Security-Policy of this origin alone (the home proxy
widens it by exactly the hashes of the home badge it injects). The page builds its DOM with textContent only.

Settings (environment):
  UI_PORT_BOARD           the port on 127.0.0.1 (default 8096); UI_BACKEND_LISTEN_HOST the address (default 127.0.0.1)
  PLANE_URL               the Plane proxy (run.sh: http://plane-proxy:80)
  PLANE_AUTH_FILE         the board's secrets file (default /wd/plane/plane.env; PLANE_API_KEY)
  PLANE_WORKSPACE         the workspace slug (default do-agent-aws); PLANE_PROJECT the project identifier (default AGENT)
  BOARD_RUNNER_URL        the agent runner's local API (default http://127.0.0.1:${UI_PORT_VIBE_KANBAN:-8081})
  BOARD_REFRESH           seconds between passes (default 30, at least 5); the page refreshes on the same cadence
  BOARD_UI_DIR            the page's files (default: the board-ui/ directory beside this script)

  GET /                   the page;  GET /board.js, /board.css  its script and stylesheet
  GET /__harness/harness.css  an empty stylesheet, so the page's link to the harness stylesheet (served by the home proxy
                          on this path once it is installed) never fails; board.css is written against that stylesheet's
                          tokens and components, so without it the page is unstyled but readable (states are words)
  GET /api/board          the snapshot (JSON; 503 with the reason before the first pass)
  GET /healthz            200 while the last pass is fresh and Plane answered, 503 otherwise (the dot probe)
"""
import datetime
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

E = os.environ
BOARD_HOST = "board.localhost"
PORT = int(E.get("UI_PORT_BOARD", "8096"))
LISTEN = E.get("UI_BACKEND_LISTEN_HOST", "127.0.0.1") or "127.0.0.1"
PLANE_URL = E.get("PLANE_URL", "")
AUTH_FILE = E.get("PLANE_AUTH_FILE", "/wd/plane/plane.env")
WORKSPACE = E.get("PLANE_WORKSPACE", "do-agent-aws") or "do-agent-aws"
PROJECT = E.get("PLANE_PROJECT", "AGENT") or "AGENT"
RUNNER_URL = E.get("BOARD_RUNNER_URL", "") or f"http://127.0.0.1:{E.get('UI_PORT_VIBE_KANBAN', '8081') or '8081'}"
REFRESH = max(5, int(E.get("BOARD_REFRESH", "30") or 30))
RUNNER_MAX = max(1, int(E.get("BOARD_RUNNER_MAX", "40") or 40))   # attempts read in detail per pass (two runner calls each)
STALE_AFTER = 3 * REFRESH
UI_DIR = E.get("BOARD_UI_DIR", "") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "board-ui")
TIMEOUT = 10
# Plane's state groups, in board order; the states inside a group follow Plane's sequence
GROUP_ORDER = {"backlog": 0, "unstarted": 1, "started": 2, "completed": 3, "cancelled": 4, "triage": 5}
FILES = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
         "/board.js": ("board.js", "text/javascript; charset=utf-8"), "/board.css": ("board.css", "text/css; charset=utf-8")}
# The harness stylesheet the page links (its design tokens and components, shared by every page the harness builds itself)
# is served by the home proxy on this path of every host route once that base is installed; until then, or on a route
# without it, the page's link lands here and gets an empty stylesheet rather than an error. board.css is written against
# the stylesheet (no fallback of its own), so the page then renders unstyled but readable: every state is a word
SHARED_CSS_PATH = "/__harness/harness.css"
SHARED_CSS_FALLBACK = (b"/* the harness stylesheet is served by the home proxy on this path when its base is installed; "
                       b"this empty fallback keeps the page's link valid, and the page reads unstyled until then */\n")
CSP = ("default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; "
       "frame-ancestors 'none'")
# what git reports for a worktree, reduced to the scalar facts a strip can show (the runner's own field names)
GIT_KEYS = re.compile(r"ahead|behind|uncommitted|untracked|conflict|dirty|changed|added|deleted|modified|insertion|"
                      r"deletion|merged|rebase|status", re.I)


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    print(f"{now()} {msg}", flush=True)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """No redirect is followed: urllib would send X-Api-Key again to wherever Location points."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


# never through a proxy from the environment: both upstreams are on this host or on the agent's docker network
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


class Unreachable(Exception):
    pass


def private_base(url, what, docker_names=True):
    """url without a trailing slash, refused unless its host is loopback (or, for Plane, a single-label docker name)."""
    p = urllib.parse.urlparse(url)
    host = p.hostname or ""
    if p.scheme != "http":
        raise SystemExit(f"board: {what} must be http://host[:port], got {url!r}")
    if host in ("127.0.0.1", "localhost", "::1") or (docker_names and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", host)):
        return url.rstrip("/")
    raise SystemExit(f"board: refusing {what} host {host!r}: only loopback"
                     + (" or a single-label docker network name" if docker_names else ""))


def load_key(path):
    """PLANE_API_KEY from the board's secrets file; read at each pass, so a rotated key is picked up."""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("PLANE_API_KEY=") and line.split("=", 1)[1].strip():
                    return line.split("=", 1)[1].strip()
    except OSError:
        raise Unreachable(f"the board's secrets file {path} is missing or unreadable (./run.sh creates it on the host)")
    raise Unreachable(f"{path} holds no PLANE_API_KEY")


def get_json(url, headers=None, what="upstream"):
    """(status, payload) of one GET; a network failure is Unreachable."""
    req = urllib.request.Request(url, headers=headers or {}, method="GET")
    try:
        with OPENER.open(req, timeout=TIMEOUT) as r:
            raw = r.read()
            return r.status, (json.loads(raw.decode("utf-8", "replace")) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        raw = e.read() if e.fp else b""
        try:
            payload = json.loads(raw.decode("utf-8", "replace")) if raw.strip() else None
        except ValueError:
            payload = None
        return e.code, payload
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Unreachable(f"{what} not answering ({type(e).__name__})")


def plane_pages(base, key, path):
    """Every row of a paginated Plane v1 list (per_page is capped at 100 by Plane)."""
    rows, cursor = [], None
    for _ in range(50):
        sep = "&" if "?" in path else "?"
        url = f"{base}{path}{sep}per_page=100" + (f"&cursor={urllib.parse.quote(cursor)}" if cursor else "")
        status, page = get_json(url, {"X-Api-Key": key}, "Plane")
        if status in (401, 403):
            raise Unreachable("Plane refused the API key (check PLANE_API_KEY in the secrets file)")
        if status == 429:
            raise Unreachable("Plane rate-limited the API key; the next pass retries")
        if status != 200:
            raise Unreachable(f"Plane answered {status} on {path.split('?')[0]}")
        if isinstance(page, list):
            return page
        if not isinstance(page, dict):
            raise Unreachable(f"Plane answered no list on {path.split('?')[0]}")
        rows += page.get("results") or []
        if not page.get("next_page_results"):
            break
        cursor = page.get("next_cursor")
        if not cursor:
            break
    return rows


def short(text, n=200):
    text = " ".join(str(text or "").split())
    return text if len(text) <= n else text[:n - 3] + "..."


def read_plane():
    """The project's columns and cards, from Plane: {project, columns}."""
    base = f"{PLANE_URL}/api/v1/workspaces/{urllib.parse.quote(WORKSPACE)}"
    key = load_key(AUTH_FILE)
    projects = plane_pages(base, key, "/projects/")
    project = next((p for p in projects if isinstance(p, dict) and p.get("identifier") == PROJECT), None)
    if project is None:
        raise Unreachable(f"no project {PROJECT} in workspace {WORKSPACE} (./run.sh seeds it)")
    pid = project["id"]
    states = [s for s in plane_pages(base, key, f"/projects/{pid}/states/") if isinstance(s, dict) and s.get("id")]
    states.sort(key=lambda s: (GROUP_ORDER.get(str(s.get("group") or ""), 9), float(s.get("sequence") or 0), str(s.get("name") or "")))
    columns = [{"id": s["id"], "name": short(s.get("name") or "?", 60), "group": str(s.get("group") or ""),
                "color": s.get("color") if re.fullmatch(r"#[0-9A-Fa-f]{3,8}", str(s.get("color") or "")) else None,
                "cards": []} for s in states]
    by_state = {c["id"]: c for c in columns}
    orphans = {"id": "", "name": "No state", "group": "", "color": None, "cards": []}
    for it in plane_pages(base, key, f"/projects/{pid}/issues/"):
        if not isinstance(it, dict) or not it.get("id"):
            continue
        seq = it.get("sequence_id")
        card = {"key": f"{PROJECT}-{seq}" if seq is not None else PROJECT, "seq": seq,
                "name": short(it.get("name") or "(untitled)", 160), "priority": str(it.get("priority") or "none"),
                "updated_at": str(it.get("updated_at") or "")[:19], "mirrored": it.get("external_source") == "do-agent-aws",
                "attempts": []}
        by_state.get(str(it.get("state") or ""), orphans)["cards"].append(card)
    if orphans["cards"]:
        columns.append(orphans)
    for c in columns:
        c["cards"].sort(key=lambda k: (k["seq"] is None, -(k["seq"] or 0)))
    return {"project": {"identifier": PROJECT, "name": short(project.get("name") or PROJECT, 80)}, "columns": columns}


def git_facts(d):
    """The scalar facts of a runner git status that a strip can show."""
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            if GIT_KEYS.search(str(k)) and isinstance(v, (int, float, bool, str)):
                out[short(k, 40)] = short(v, 40) if isinstance(v, str) else v
            if len(out) >= 8:
                break
    return out


def read_runner():
    """The agent runner's attempts (vibe-kanban workspaces): [{id, name, branch, ...}], from its local API."""
    status, info = get_json(f"{RUNNER_URL}/api/workspaces", what="the agent runner")
    if status != 200 or not isinstance(info, dict) or not isinstance(info.get("data"), list):
        raise Unreachable(f"the agent runner answered {status} on /api/workspaces")
    attempts = []
    rows = [w for w in info["data"] if isinstance(w, dict) and w.get("id") and not w.get("archived")]
    # the newest RUNNER_MAX attempts get their two detail calls (sessions, git status); a pass stays bounded whatever the
    # runner holds, and a slow runner cannot stretch it (the Plane read above is what the dot's freshness follows)
    rows.sort(key=lambda w: str(w.get("updated_at") or ""), reverse=True)
    for w in rows[:RUNNER_MAX]:
        wid = str(w["id"])
        a = {"id": wid[:8], "name": short(w.get("name") or "", 120), "branch": short(w.get("branch") or "", 80),
             "pinned": bool(w.get("pinned")), "setup_done": bool(w.get("setup_completed_at")),
             "worktree_deleted": bool(w.get("worktree_deleted")), "updated_at": str(w.get("updated_at") or "")[:19],
             "sessions": None, "running": None, "git": {}}
        # the attempt's agent sessions, and whether one is still running (the field names the runner uses, if any)
        try:
            s, sess = get_json(f"{RUNNER_URL}/api/sessions?workspace_id={urllib.parse.quote(wid)}", what="the agent runner")
            if s == 200 and isinstance(sess, dict) and isinstance(sess.get("data"), list):
                rows = [x for x in sess["data"] if isinstance(x, dict)]
                a["sessions"] = len(rows)
                states = [str(x.get("status") or x.get("state") or "").lower() for x in rows]
                a["running"] = any(st in ("running", "active", "in_progress") for st in states) if rows else False
            s, git = get_json(f"{RUNNER_URL}/api/workspaces/{urllib.parse.quote(wid)}/git/status", what="the agent runner")
            if s == 200 and isinstance(git, dict) and git.get("success"):
                a["git"] = git_facts(git.get("data"))
        except Unreachable:
            pass
        attempts.append(a)
    attempts.sort(key=lambda x: x["updated_at"], reverse=True)
    return attempts


def link_attempts(columns, attempts):
    """An attempt belongs to the card whose key its name or branch carries, as a whole token (AGENT-3, not AGENT-30)."""
    linked = 0
    unlinked = []
    cards = [c for col in columns for c in col["cards"] if c["seq"] is not None]
    for a in attempts:
        hay = f"{a['name']} {a['branch']}"
        hits = [c for c in cards if re.search(r"(?<![A-Za-z0-9])" + re.escape(c["key"]) + r"(?![0-9])", hay, re.I)]
        for c in hits:
            c["attempts"].append(a)
        if hits:
            linked += 1
        else:
            unlinked.append(a)
    return linked, unlinked[:50]


class Snapshot:
    """The one view every request is answered from; rebuilt by the pass loop, served read-only."""

    def __init__(self):
        self.lock = threading.Lock()
        self.data = None          # the last good board (plane ok)
        self.good_at = None       # time.time() of that pass
        self.error = None         # the last pass's Plane error, or None
        self.runner_error = None
        self.passes = 0

    def run_pass(self):
        plane_err, board, runner_err, attempts, plane_at = None, None, None, [], None
        try:
            board = read_plane()
            plane_at = time.time()   # the freshness the dot follows: Plane's answer, not the runner's
        except Unreachable as e:
            plane_err = str(e)
        except Exception as e:  # noqa: BLE001 - a malformed payload is a pass that failed, never a crash
            plane_err = f"Plane answered something this board cannot read ({type(e).__name__})"
        try:
            attempts = read_runner()
        except Unreachable as e:
            runner_err = str(e)
        except Exception as e:  # noqa: BLE001
            runner_err = f"the agent runner answered something this board cannot read ({type(e).__name__})"
        with self.lock:
            self.passes += 1
            self.runner_error = runner_err
            if board is not None:
                linked, unlinked = link_attempts(board["columns"], attempts)
                self.data = {"schema": "do-agent-aws-board/v1", "generated_at": now(), "refresh_s": REFRESH,
                             "workspace": WORKSPACE, "project": board["project"], "columns": board["columns"],
                             "cards": sum(len(c["cards"]) for c in board["columns"]),
                             "runner": {"ok": runner_err is None, "attempts": len(attempts), "linked": linked,
                                        "error": runner_err},
                             "unlinked_attempts": unlinked}
                self.good_at = plane_at
                self.error = None
            else:
                self.error = plane_err
        if plane_err:
            log(f"pass {self.passes}: Plane - {plane_err}")
        if runner_err and (self.passes in (1, 2) or self.passes % 20 == 0):
            log(f"pass {self.passes}: runner - {runner_err}")

    def fresh(self):
        return self.good_at is not None and (time.time() - self.good_at) <= STALE_AFTER and self.error is None

    def view(self):
        with self.lock:
            if self.data is None:
                return 503, {"schema": "do-agent-aws-board/v1", "error": self.error or "no snapshot yet - the first pass is running",
                             "refresh_s": REFRESH, "columns": [], "cards": 0}
            d = dict(self.data)
            d["stale"] = not self.fresh()
            d["error"] = self.error
            d["age_s"] = round(time.time() - self.good_at)
            return 200, d

    def health(self):
        with self.lock:
            ok = self.fresh()
            age = None if self.good_at is None else round(time.time() - self.good_at)
            return (200 if ok else 503), {"fresh": ok, "age_s": age, "stale_after_s": STALE_AFTER,
                                           "error": self.error, "passes": self.passes}


SNAP = Snapshot()


def pass_loop():
    while True:
        SNAP.run_pass()
        time.sleep(REFRESH)


def host_name(host_header):
    name = (host_header or "").strip().lower()
    if name.startswith("[") and "]" in name:
        return name[1:name.index("]")]
    return name.rsplit(":", 1)[0] if re.search(r":[0-9]{1,5}$", name) else name


def host_ok(host_header):
    name = host_name(host_header).rstrip(".")
    return name in (BOARD_HOST, "127.0.0.1", "localhost", "::1")


def origin_ok(headers, host_header):
    """The data endpoint answers its own origin only: an Origin, when sent, must name this host (board.localhost or a
    loopback name) on the port the request arrived on; a Sec-Fetch-Site, when sent, must be same-origin or none."""
    sfs = (headers.get("Sec-Fetch-Site") or "").strip().lower()
    if sfs and sfs not in ("same-origin", "none"):
        return False
    origin = (headers.get("Origin") or "").strip()
    if not origin or origin.lower() == "null":
        return not origin  # "null" (an opaque origin: a sandboxed or file page) is refused
    p = urllib.parse.urlparse(origin)
    if p.scheme not in ("http", "https") or not host_ok(p.netloc):
        return False
    want = re.search(r":([0-9]{1,5})$", (host_header or "").strip())
    have = str(p.port or (443 if p.scheme == "https" else 80))
    return have == (want.group(1) if want else "80")


class Handler(BaseHTTPRequestHandler):
    server_version = "do-agent-aws-board"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype, extra=None):
        self.send_response(code)
        headers = {"Content-Type": ctype, "Content-Length": str(len(body)), "Cache-Control": "no-store",
                   "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY",
                   "Content-Security-Policy": CSP}
        headers.update(extra or {})
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        headers = getattr(self, "headers", None)
        shown = re.sub(r"[^A-Za-z0-9.:\[\]_-]", "?", (headers.get("Host") if headers else "") or "")[:60]
        path = re.sub(r"[^A-Za-z0-9/._~-]", "?", str(getattr(self, "path", "") or "").split("?", 1)[0])[:80]
        log(f"{self.command or '?'} {path} -> {code} host={shown}")

    def text(self, code, msg, extra=None):
        self.send(code, (msg + "\n").encode("utf-8"), "text/plain; charset=utf-8", extra)

    def refuse(self):
        """Any method but GET and HEAD: the same Host check first (a foreign Host is misdirected, whatever it asks), then 405."""
        headers = getattr(self, "headers", None)
        if not host_ok(headers.get("Host", "") if headers else ""):
            return self.text(421, f"misdirected: this board answers on {BOARD_HOST} through the harness home port, or on loopback")
        self.text(405, "read-only: GET and HEAD only", {"Allow": "GET, HEAD"})

    do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = refuse

    def send_error(self, code, message=None, explain=None):
        """The stdlib's error path answers like every other response here - plain text with the same headers, never its
        HTML page: a method this server has no handler for (TRACE, PROPFIND, any token: the stdlib's 501) is 405 with
        Allow, after the same Host check as a GET; a malformed request line (400, 414, 431) is refused as plain text."""
        self.close_connection = True
        if code == 501:
            return self.refuse()
        self.text(code, re.sub(r"[^A-Za-z0-9 .,:;()'_-]", "?", str(message or "request refused"))[:120])

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        host = self.headers.get("Host", "")
        if not host_ok(host):
            return self.text(421, f"misdirected: this board answers on {BOARD_HOST} through the harness home port, or on loopback")
        if path == "/healthz":
            code, body = SNAP.health()
            return self.send(code, json.dumps(body).encode("utf-8"), "application/json")
        if path == "/api/board":
            if not origin_ok(self.headers, host):
                return self.text(403, "refused: the board's data is answered to its own origin only")
            code, body = SNAP.view()
            return self.send(code, json.dumps(body).encode("utf-8"), "application/json")
        if path == SHARED_CSS_PATH:
            return self.send(200, SHARED_CSS_FALLBACK, "text/css; charset=utf-8")
        if path not in FILES:
            return self.text(404, "not found")
        name, ctype = FILES[path]
        try:
            with open(os.path.join(UI_DIR, name), "rb") as f:
                body = f.read()
        except OSError:
            return self.text(503, f"the page file {name} is missing from {UI_DIR}")
        return self.send(200, body, ctype)


def main():
    global PLANE_URL, RUNNER_URL
    if not PLANE_URL:
        raise SystemExit("board: PLANE_URL is not set (no Plane board on this target) - nothing to show")
    PLANE_URL = private_base(PLANE_URL, "PLANE_URL")
    RUNNER_URL = private_base(RUNNER_URL, "BOARD_RUNNER_URL", docker_names=False)
    for name, _ in FILES.values():
        if not os.path.isfile(os.path.join(UI_DIR, name)):
            raise SystemExit(f"board: the page file {name} is missing from {UI_DIR}")
    threading.Thread(target=pass_loop, daemon=True).start()
    server = ThreadingHTTPServer((LISTEN, PORT), Handler)
    server.daemon_threads = True
    log(f"board listening on {LISTEN}:{PORT} for {BOARD_HOST} - project {PROJECT} of workspace {WORKSPACE} at "
        f"{urllib.parse.urlparse(PLANE_URL).hostname}, runner at {urllib.parse.urlparse(RUNNER_URL).netloc}; a pass every {REFRESH}s")
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
