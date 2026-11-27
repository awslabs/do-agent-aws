#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""plane-signin.py - the home page's one-click sign-in to the self-hosted Plane board (docs/manual/boards.md "Plane board").

Started by /agent/ui-start.sh when the board runs on this target (PLANE_URL, set by run.sh) and
PLANE_LOGIN_BYPASS=true. It listens on 127.0.0.1:UI_PORT_PLANE_SIGNIN only, and the home proxy forwards exactly one
URL to it: http://plane.localhost:<home port>/__harness/sign-in - the Plane tile's link (the kanban board's
one-click sign-in uses the same path on kanban.localhost). A loopback-only
convenience: whoever can reach the loopback home port lands in the board signed in as the seeded admin.

  GET /__harness/sign-in       with Host plane.localhost[:port]:
      1. the browser's own Plane session is reused when it is still valid (GET /api/users/me/ answers 200);
      2. otherwise the seeded admin is signed in server-side through Plane's own email sign-in - GET
         /auth/get-csrf-token/, then POST /auth/sign-in/ with the login from PLANE_AUTH_FILE - and the new session is
         checked with GET /api/users/me/;
      3. the answer is a 302 to the project's board, /<workspace>/projects/<project id>/issues/ (a RELATIVE Location,
         so any ssh -L or port-forward port works), carrying Plane's own Set-Cookie headers without any Domain
         attribute (host-only cookies for plane.localhost): the browser then holds an ordinary Plane session.
      Any other Host is refused with 403 and nothing else happens (the DNS-rebinding guard: a page served from another
      hostname that resolves to this machine arrives with its own Host, so it can never obtain a session). So is a
      request that does not come from the harness home page on the same port: its Origin, or for the tile's link
      click (a GET navigation carries no Origin) its Referer, must be http://localhost:<that port> (or 127.0.0.1,
      [::1]) - a cross-site page can forge neither, and a missing one is refused (no login CSRF). That refusal is a
      page with a Harness home link for the same port, where a bookmark or a shared link to the tile's URL lands.
      Every answer forbids framing (X-Frame-Options DENY, CSP frame-ancestors 'none') and MIME sniffing.
      A missing or unreadable login file answers 503 (a local fault), a failing Plane 502. Plane's limit on anonymous
      calls is waited out once when its 429 asks for a short wait (RETRY_WAIT_MAX below); otherwise the 502 page names
      the limit and the wait.
  GET /healthz                 200 "ok", no side effect (ui-status.sh probes it).

The password, the API key and every cookie value stay out of the responses' bodies and out of the log: one line per
request on stdout (ui-start.sh sends it to /wd/ui/plane-signin.log).

Settings (environment): PLANE_URL (the Plane proxy, http://plane-proxy:80 - only loopback or a single-label docker
network name is accepted, so the login never leaves the host), PLANE_AUTH_FILE (default /wd/plane/plane.env:
PLANE_ADMIN_EMAIL, PLANE_ADMIN_PASSWORD, PLANE_API_KEY), PLANE_WORKSPACE, PLANE_PROJECT (the project identifier),
UI_PORT_PLANE_SIGNIN (default 8090).
"""
import datetime
import html
import http.client
import json
import os
import re
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SIGN_IN_PATH = "/__harness/sign-in"
BOARD_HOST = "plane.localhost"
SESSION_COOKIE = "session-id"
# Plane allows 30 anonymous calls a minute per caller (Plane v1.4.2: REST_FRAMEWORK's AnonRateThrottle, "anon":
# "30/minute", no setting) and tells callers apart by the X-Forwarded-For its proxy passes on. The CSRF request of the
# sign-in is one of them, counted against this container's address as ui-status.sh's Plane row is (the home page's
# Plane dot sends the browser's address). Its 429 carries Retry-After in whole seconds, rounded up (the REST framework
# takes the ceiling of the wait, so it is never 0): a wait of at most RETRY_WAIT_MAX seconds is waited out, plus a
# one-second margin, and the request is sent once more.
PLANE_ANON_LIMIT = "30 per minute"
RETRY_WAIT_MAX = 10


def log(msg):
    print(f"{datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} {msg}", flush=True)


def private_base(url):
    """(scheme, host, port) of PLANE_URL, refusing anything but loopback or a single-label docker network name."""
    p = urllib.parse.urlparse(url)
    host = p.hostname or ""
    if p.scheme != "http":
        raise SystemExit(f"plane-signin: PLANE_URL must be http://host[:port], got {url!r}")
    if not (host in ("127.0.0.1", "localhost", "::1") or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", host)):
        raise SystemExit(f"plane-signin: refusing PLANE_URL host {host!r}: only loopback or a docker network name")
    return host, p.port or 80


def load_login(path):
    vals = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    vals[k.strip()] = v.strip()
    except (OSError, ValueError):
        raise ConfigError(f"the login file {path} is missing or unreadable")
    if not (vals.get("PLANE_ADMIN_EMAIL") and vals.get("PLANE_ADMIN_PASSWORD")):
        raise ConfigError(f"{path} lacks PLANE_ADMIN_EMAIL or PLANE_ADMIN_PASSWORD")
    return vals.get("PLANE_ADMIN_EMAIL"), vals.get("PLANE_ADMIN_PASSWORD"), vals.get("PLANE_API_KEY")


HOME_SRC = re.compile(r"^https?://(?:localhost|127\.0\.0\.1|\[::1\])(?::([0-9]{1,5}))?(?:/|$)", re.I)


def from_home(headers, host_header):
    """True when the request came from the harness home page on the port it arrived on: its Origin, or, for the
    tile's link click (a GET navigation carries no Origin), its Referer."""
    m = re.search(r":([0-9]{1,5})$", host_header or "")
    port = m.group(1) if m else "80"
    src = HOME_SRC.match(headers.get("Origin") or headers.get("Referer") or "")
    return bool(src) and (src.group(1) or "80") == port


# The refusal a person sees when the tile's URL is opened from a bookmark or a shared link: the Goals board's sign-in
# refusal page (kanban-signin.py), for the Plane board
STYLE = ("body{font:15px/1.5 system-ui,sans-serif;margin:0;background:#f4f5f7;color:#1a1a1a}"
         "main{max-width:640px;margin:12vh auto 0;padding:28px;background:#fff;border:1px solid #e0e2e6;border-radius:8px}"
         "h1{font-size:20px;margin:0 0 10px}p{margin:8px 0}a.home{display:inline-block;margin-top:14px;color:#fff;background:#0972d3;"
         "border-radius:6px;padding:7px 14px;text-decoration:none}")
REFUSED = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="referrer" content="no-referrer">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Plane board - open it from the harness home page</title><style>%s</style></head>
<body><main><h1>Open the Plane board from the harness home page</h1>
<p>This link did not come from the harness home page, so it cannot sign you in.</p>
<p>The home page's Plane board tile signs you in with one click; a bookmark or a shared link to the board cannot (the
login stays in wd/plane/plane.env on the host).</p>
<p><a class="home" href="%s">Harness home</a></p></main></body></html>"""


def home_href(host_header):
    """The harness home for a request on the board's host: localhost on the port the browser is on
    (plane.localhost:8000 -> //localhost:8000/, the home badge's rule). Called once host_is_board accepted the Host."""
    m = re.fullmatch(r"[A-Za-z0-9.-]+(?::([0-9]{1,5}))?", host_header or "")
    return f"//localhost:{m.group(1)}/" if m and m.group(1) else "//localhost/"


class ConfigError(Exception):
    """A local fault (the login file): answered 503, not 502."""


class RateLimited(Exception):
    """Plane refused the sign-in's anonymous call for its rate limit (429), with the wait it asked for (None: it named
    none). The text goes on the failure page, which turns quotes into ?, so it has none."""

    def __init__(self, wait):
        limit = f"Plane rate-limits the anonymous calls of the harness ({PLANE_ANON_LIMIT})"
        if wait is None:
            super().__init__(f"{limit}; click the Plane tile again in a minute")
        else:
            n = max(wait, 1)
            super().__init__(f"{limit} and asked to wait {n} second{'' if n == 1 else 's'}; click the Plane tile again "
                             "after that")


def retry_after(headers):
    """The Retry-After of an answer in whole seconds (1 to 6 ASCII digits), or None when it carries none in that form:
    str.isdigit() also accepts digits such as a superscript two, which int() refuses."""
    value = next((v for k, v in headers if k.lower() == "retry-after"), "").strip()
    return int(value) if re.fullmatch(r"[0-9]{1,6}", value) else None


def host_is_board(host_header):
    """True when the request's Host names the board's loopback hostname: plane.localhost, any port."""
    m = re.fullmatch(r"([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?", host_header or "")
    return bool(m) and m.group(1).lower().rstrip(".") == BOARD_HOST


class Plane:
    def __init__(self, url, auth_file, workspace, project):
        self.host, self.port = private_base(url)
        self.auth_file, self.workspace, self.project = auth_file, workspace, project
        self.project_id = None

    def call(self, method, path, headers=None, body=None):
        """One request, no redirect following: (status, headers list, body bytes)."""
        conn = http.client.HTTPConnection(self.host, self.port, timeout=15)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            r = conn.getresponse()
            return r.status, r.getheaders(), r.read()
        finally:
            conn.close()

    def session_ok(self, cookie_header, ua):
        if not cookie_header:
            return False
        status, _, _ = self.call("GET", "/api/users/me/", {"Cookie": cookie_header, "User-Agent": ua})
        return status == 200

    def board_path(self, api_key):
        """The project's board, resolved by its identifier through the agent's API key (cached)."""
        if self.project_id is None and api_key:
            status, _, raw = self.call("GET", f"/api/v1/workspaces/{self.workspace}/projects/", {"X-Api-Key": api_key})
            if status == 200:
                data = json.loads(raw or b"{}")
                rows = data.get("results", data) if isinstance(data, dict) else data
                self.project_id = next((p["id"] for p in rows if p.get("identifier") == self.project), None)
        if self.project_id:
            return f"/{self.workspace}/projects/{self.project_id}/issues/"
        return f"/{self.workspace}/projects/"

    def sign_in(self, email, password, next_path, ua):
        """Plane's own email sign-in, as the browser (its User-Agent: Plane records it on the user and the session,
        and a sign-in without one fails with 500 - users.last_login_uagent is NOT NULL). Returns the Set-Cookie
        headers to relay, or raises with a reason."""
        status, headers, raw = self.call("GET", "/auth/get-csrf-token/", {"User-Agent": ua})
        wait = retry_after(headers) if status == 429 else None
        if wait is not None and wait <= RETRY_WAIT_MAX:
            log(f"Plane answered the CSRF request 429 (Retry-After {wait}): sending it once more in {wait + 1} s")
            time.sleep(wait + 1)
            status, headers, raw = self.call("GET", "/auth/get-csrf-token/", {"User-Agent": ua})
        if status == 429:
            raise RateLimited(retry_after(headers))
        if status != 200:
            raise RuntimeError(f"/auth/get-csrf-token/ answered {status}")
        token = json.loads(raw or b"{}").get("csrf_token")
        csrf_cookie = next((c.split(";", 1)[0] for k, c in headers if k.lower() == "set-cookie"
                            and c.startswith("csrftoken=")), None)
        if not token or not csrf_cookie:
            raise RuntimeError("Plane gave no CSRF token")
        form = urllib.parse.urlencode({"csrfmiddlewaretoken": token, "email": email, "password": password,
                                       "next_path": next_path})
        status, headers, _ = self.call("POST", "/auth/sign-in/", {
            "Cookie": csrf_cookie, "Content-Type": "application/x-www-form-urlencoded",
            "X-CSRFToken": token, "User-Agent": ua}, form)
        cookies = [c for k, c in headers if k.lower() == "set-cookie"]
        session = next((c.split(";", 1)[0] for c in cookies if c.startswith(SESSION_COOKIE + "=")), None)
        if status not in (301, 302) or not session:
            location = next((v for k, v in headers if k.lower() == "location"), "")
            code = urllib.parse.parse_qs(urllib.parse.urlparse(location).query).get("error_code", ["?"])[0]
            raise RuntimeError(f"/auth/sign-in/ answered {status} with no session (error_code {code})")
        if not self.session_ok(session, ua):
            raise RuntimeError("the new session is not accepted by /api/users/me/")
        # host-only cookies for plane.localhost: drop any Domain attribute
        return [re.sub(r";\s*[Dd]omain=[^;]*", "", c) for c in cookies]


class Handler(BaseHTTPRequestHandler):
    server_version = "do-agent-aws-plane-signin"
    sys_version = ""

    def log_message(self, *args):
        pass

    def answer(self, code, text, headers=()):
        body = (text + "\n").encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", "text/html; charset=utf-8" if text.startswith("<") else "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        host = self.headers.get("Host", "")
        if path == "/healthz":
            return self.answer(200, "ok")
        if path != SIGN_IN_PATH:
            return self.answer(404, "not found")
        shown = re.sub(r"[^A-Za-z0-9.:\[\]_-]", "?", host)[:80]
        if not host_is_board(host):
            log(f"refused host {shown!r}: only {BOARD_HOST} (the home port's host route) may sign in")
            return self.answer(403, f"refused: the Plane sign-in answers only on {BOARD_HOST} through the harness "
                                    "home port (loopback)")
        if not from_home(self.headers, host):
            log(f"host {shown}: refused - the request does not come from the harness home page on this port")
            return self.answer(403, REFUSED % (STYLE, html.escape(home_href(host), quote=True)))
        plane = self.server.plane
        try:
            email, password, api_key = load_login(plane.auth_file)
            target = plane.board_path(api_key)
            ua = (self.headers.get("User-Agent") or "do-agent-aws-plane-signin")[:500]
            if plane.session_ok(self.headers.get("Cookie", ""), ua):
                log(f"host {shown}: the browser's session is valid - to the board")
                return self.answer(302, "to the board", [("Location", target), ("Referrer-Policy", "no-referrer")])
            cookies = plane.sign_in(email, password, target, ua)
        except Exception as e:  # noqa: BLE001 - every failure is one page and one log line
            # the reasons above never carry the login; html-escape the rest (a socket error text)
            reason = re.sub(r"[<>&\"']", "?", str(e))[:300] or type(e).__name__
            log(f"host {shown}: sign-in FAILED - {reason}")
            return self.answer(503 if isinstance(e, ConfigError) else 502, "<!DOCTYPE html><title>Plane sign-in failed</title><p>The one-click sign-in to "
                                    f"the Plane board failed: {reason}.</p><p>Plane's own login page is at "
                                    "<a href=\"/\">/</a>; the login is PLANE_ADMIN_EMAIL / PLANE_ADMIN_PASSWORD in "
                                    "the project's wd/plane/plane.env on the host.</p>")
        log(f"host {shown}: signed in as the seeded admin (new session) - to the board")
        return self.answer(302, "to the board", [("Location", target), ("Referrer-Policy", "no-referrer")]
                           + [("Set-Cookie", c) for c in cookies])

    def do_HEAD(self):
        self.answer(405, "method not allowed")

    do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD


def main():
    plane = Plane(os.environ.get("PLANE_URL", ""), os.environ.get("PLANE_AUTH_FILE", "/wd/plane/plane.env"),
                  os.environ.get("PLANE_WORKSPACE", "do-agent-aws"), os.environ.get("PLANE_PROJECT", "AGENT"))
    port = int(os.environ.get("UI_PORT_PLANE_SIGNIN", "8090"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.plane = plane
    log(f"plane-signin listening on 127.0.0.1:{port} for {BOARD_HOST}{SIGN_IN_PATH} -> {plane.host}:{plane.port}")
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
