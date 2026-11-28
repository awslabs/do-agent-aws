#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""kanban-signin.py - one click from the harness home page to the kanban board, already signed in.

Serves GET /__harness/sign-in on 127.0.0.1:UI_PORT_KANBAN_SIGNIN (default 8092) inside the agent container;
/agent/ui-start.sh starts it while the board is up (KANBAN_BOARD_URL), and the home proxy routes that one path on
the kanban.localhost host route only (/agent/home-render.sh). The home page's Kanban board tile links to it. Each
request:
  1. is refused with 403 unless its Host is kanban.localhost[:port] - the defense against DNS rebinding: a page
     that rebinds its own name to 127.0.0.1 arrives with that name - and unless it comes from the harness home page
     on that same port: its Origin, or for the tile's link click (a navigation carries no Origin) its Referer, must
     be http://localhost, 127.0.0.1 or [::1] on the request's port. Another site's page cannot forge either, so it
     can neither frame a signed-in board nor sign the browser in (a login CSRF); a request without either header is
     refused too. Every answer also forbids framing (X-Frame-Options DENY, frame-ancestors 'none');
  2. signs in to the board server (KANBAN_BOARD_URL) server-side, with the generated login (KANBAN_AUTH_FILE),
     never through a proxy from the environment;
  3. answers a no-store page that writes the session into the board app's own storage - IndexedDB "rf-auth",
     object store "tokens", keys access_token and refresh_token, as packages/remote-web/src/shared/lib/auth.ts
     stores them at the pinned commit - and replaces itself with the agent's project (/projects/<id>, the id
     /agent/kanban-sync.py gives it), or the board's start page before the project exists.
The password never reaches the browser; the page carries only the session tokens, for the board's own origin. Each
sign-in mints a new board session; earlier ones are not revoked (the board has no call for it). The
trust boundary is the harness's: the home port is published on loopback only (UI_BIND_HOST in .env) and reached
through an SSH tunnel, like the writable terminal at /tmux/. GET /healthz answers 200 for ui-status.sh.

GET /healthz/board is the Goals board tile's status probe (the home proxy's same-origin /__probe/kanban): 200 only
when the board server answers a read that goes to its database (the organization list, with a session this helper
signs in for once and keeps in memory, signing in again when the board refuses it). The board server's own
/v1/health answers without its database, so it cannot tell a board whose database is down. It answers 503 or 502
with the reason otherwise, and never a token. It is bounded: one probe at a time, each board call times out after
3 s, and a probe that waits 5 s for the one in flight answers 503, so a hanging board cannot pile probes up.
"""
import html
import http.server
import json
import os
import re
import sys
import threading
import urllib.error
import urllib.request
import uuid

PORT = int(os.environ.get("UI_PORT_KANBAN_SIGNIN", "8092"))
BOARD = os.environ.get("KANBAN_BOARD_URL", "").rstrip("/")
AUTH_FILE = os.environ.get("KANBAN_AUTH_FILE", "/wd/kanban/kanban.env")
PROJECT = os.environ.get("KANBAN_PROJECT", "do-agent-aws") or "do-agent-aws"
# the same namespace and project id as /agent/kanban-sync.py
NS = uuid.UUID("403ef658-05ce-59aa-97e8-8aea9ecc4f02")
PROJECT_ID = str(uuid.uuid5(NS, f"project:{PROJECT}"))
HOST_OK = re.compile(r"^kanban\.localhost(:[0-9]{1,5})?$", re.I)
HOME_SRC = re.compile(r"^https?://(?:localhost|127\.0\.0\.1|\[::1\])(?::([0-9]{1,5}))?(?:/|$)", re.I)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Follow no redirect: urllib would send the request's headers, the board session included, to wherever the
    Location points, another host too. The board server's API never redirects, so a 3xx is answered as itself."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
# the status probe's board session: one sign-in, reused until the board refuses it; one probe at a time, bounded
PROBE = {"token": None}
PROBE_LOCK = threading.Lock()
PROBE_TIMEOUT = 3  # seconds per board call of a probe
PROBE_WAIT = 5  # seconds a probe waits for the one in flight

STYLE = ("body{font:15px/1.5 system-ui,sans-serif;margin:0;background:#f4f5f7;color:#1a1a1a}"
         "main{max-width:640px;margin:12vh auto 0;padding:28px;background:#fff;border:1px solid #e0e2e6;border-radius:8px}"
         "h1{font-size:20px;margin:0 0 10px}p{margin:8px 0}a.home{display:inline-block;margin-top:14px;color:#fff;background:#0972d3;"
         "border-radius:6px;padding:7px 14px;text-decoration:none}.spin{display:inline-block;width:14px;height:14px;border:2px solid #0972d3;"
         "border-right-color:transparent;border-radius:50%;animation:s .8s linear infinite;vertical-align:-2px;margin-right:8px}"
         "@keyframes s{to{transform:rotate(360deg)}}")

PAGE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="referrer" content="no-referrer">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Opening the Goals board</title><style>%s</style></head>
<body><main><h1><span class="spin"></span>Opening the Goals board</h1>
<p>Signing you in and opening the board. The first load after a container start can take up to half a minute, and
the board shows empty columns while its data syncs - the cards follow.</p>
<p><a class="home" href="%s">Harness home</a></p></main>
<script>
(function () {
  var session = %s;
  var target = %s;
  var fail = function (e) { document.querySelector("main").innerHTML = "<h1>Kanban sign-in failed</h1><p>" + String(e).replace(/[<&]/g, "") + "</p>"; };
  var open = indexedDB.open("rf-auth", 1);
  open.onupgradeneeded = function () { open.result.createObjectStore("tokens"); };
  open.onerror = function () { fail(open.error); };
  open.onsuccess = function () {
    var db = open.result;
    var tx = db.transaction("tokens", "readwrite");
    tx.objectStore("tokens").put(session.access_token, "access_token");
    tx.objectStore("tokens").put(session.refresh_token, "refresh_token");
    tx.oncomplete = function () { db.close(); location.replace(target); };
    tx.onerror = function () { fail(tx.error); };
  };
})();
</script></body></html>
"""


def _call(method, path, body=None, token=None, timeout=10):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{BOARD}{path}", data=data, method=method, headers=headers)
    try:
        with OPENER.open(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, None
    except (urllib.error.URLError, OSError, ValueError):
        return 0, None


def _login():
    vals = {}
    with open(AUTH_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip()
    return vals.get("SELF_HOST_LOCAL_AUTH_EMAIL"), vals.get("SELF_HOST_LOCAL_AUTH_PASSWORD")


def _board_health():
    """(code, text) for GET /healthz/board - 200 when the board answered a read from its database."""
    if not BOARD:
        return 503, "no kanban board on this target (KANBAN_BOARD_URL is not set)\n"
    if not PROBE_LOCK.acquire(timeout=PROBE_WAIT):
        return 503, f"busy: the status probe in flight has been waiting for the board for over {PROBE_WAIT}s\n"
    try:
        for _ in range(2):
            if not PROBE["token"]:
                try:
                    email, password = _login()
                except (OSError, ValueError):
                    return 503, f"the board login file {AUTH_FILE} is missing or unreadable\n"
                if not (email and password):
                    return 503, f"{AUTH_FILE} lacks the board login\n"
                code, session = _call("POST", "/v1/auth/local/login", {"email": email, "password": password},
                                      timeout=PROBE_TIMEOUT)
                if code != 200 or not isinstance(session, dict) or "access_token" not in session:
                    return 502, f"the board did not sign in (HTTP {code})\n"
                PROBE["token"] = session["access_token"]
            code, _ = _call("GET", "/v1/organizations", token=PROBE["token"], timeout=PROBE_TIMEOUT)
            if code == 200:
                return 200, "ok: the board server answered a read from its database\n"
            if 300 <= code < 400:
                return 502, f"the board answered a redirect (HTTP {code}), not followed\n"
            if code != 401:
                return 502, f"the board's organization list answered HTTP {code} (is its database up?)\n"
            PROBE["token"] = None
        return 502, "the board refused a fresh session\n"
    finally:
        PROBE_LOCK.release()


def _from_home(headers, host):
    """True when the request came from the harness home page on the port it arrived on: its Origin, or, for the
    tile's link click (a GET navigation carries no Origin), its Referer. A cross-site page cannot forge either; it
    can only suppress the Referer, and an absent one is refused."""
    port = host.rsplit(":", 1)[1] if re.search(r":[0-9]{1,5}$", host) else "80"
    m = HOME_SRC.match(headers.get("Origin") or headers.get("Referer") or "")
    return bool(m) and (m.group(1) or "80") == port


REFUSED = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="referrer" content="no-referrer">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Goals board - open it from the harness home page</title><style>%s</style></head>
<body><main><h1>Open the Goals board from the harness home page</h1>
<p>%s</p>
<p>The home page's Goals board tile signs you in with one click; a bookmark or a shared link to the board cannot (the login stays
in wd/kanban/kanban.env on the host).</p>
<p><a class="home" href="%s">Harness home</a></p></main></body></html>
"""


def _home_href(host):
    """The harness home for this request: the Host without its first label (kanban.localhost:8000 -> localhost:8000)."""
    return "//" + host.split(".", 1)[1] + "/" if "." in host else "/"


def _js(value):
    # JSON is valid JavaScript; "<" escaped so no value can close the script element
    return json.dumps(value).replace("<", "\\u003c")


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "do-agent-aws-kanban-signin"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            return self._send(200, "ok\n")
        if path == "/healthz/board":
            return self._send(*_board_health())
        if path != "/__harness/sign-in":
            return self._send(404, "not found\n")
        host = self.headers.get("Host", "")
        if not HOST_OK.match(host):
            return self._send(403, f"refused: the sign-in answers only on kanban.localhost, not {host[:80]!r}\n")
        if not _from_home(self.headers, host):
            return self._send(403, REFUSED % (STYLE, html.escape("refused: this link did not come from the harness home page, so it cannot sign you in"), html.escape(_home_href(host), quote=True)),
                              "text/html; charset=utf-8")
        if not BOARD:
            return self._send(503, "no kanban board on this target (KANBAN_BOARD_URL is not set)\n")
        try:
            email, password = _login()
        except (OSError, ValueError):
            return self._send(503, f"the board login file {AUTH_FILE} is missing or unreadable (./run.sh creates it)\n")
        if not (email and password):
            return self._send(503, f"{AUTH_FILE} lacks the board login\n")
        code, session = _call("POST", "/v1/auth/local/login", {"email": email, "password": password})
        if code != 200 or not isinstance(session, dict) or "access_token" not in session:
            return self._send(502, f"the board did not sign in (HTTP {code}); ui-status.sh shows kanban-board\n")
        target = "/"
        if _call("GET", f"/v1/projects/{PROJECT_ID}", token=session["access_token"])[0] == 200:
            target = f"/projects/{PROJECT_ID}"
        if not session.get("refresh_token"):
            return self._send(502, "the board's sign-in answered without a refresh token; ui-status.sh shows kanban-board\n")
        tokens = {"access_token": session["access_token"], "refresh_token": session["refresh_token"]}
        self._send(200, PAGE % (STYLE, html.escape(_home_href(host), quote=True), _js(tokens), _js(target)), "text/html; charset=utf-8")


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
