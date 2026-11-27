#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""files-server.py - the Files tile: a shared folder between the person and the agent, served by the harness itself
(docs/manual/ui.md "Files"). The agent puts what it produced for the person under FILES_DIR (/wd/files, on the /wd volume: persisted
with the agent's data on the docker target, an emptyDir that dies with the pod on kubernetes); the person downloads it from
the page and uploads files there for the agent to read.

Started by /agent/ui-start.sh (UI_FILES=true, the default). It listens on 127.0.0.1:UI_PORT_FILES only; the home proxy
is the exposure: host route files.localhost, and the tile's dot probe /__probe/files is this server's /healthz.

What it does, and what it refuses to do:
  list      GET /api/list?path=<folder>: the folder's entries (name, type, size, mtime; folders first), as JSON; a
            symlink is reported, never followed out of FILES_DIR (one that points outside is marked and not served); an
            entry whose name the rules below refuse, or that is not UTF-8, is listed as served:false under a name the
            page can show (the agent renames it in the container) - every other entry carries served:true
  download  GET /api/download?path=<file>: the file, streamed in chunks, always as an attachment
            (Content-Disposition: attachment; filename*=UTF-8''...) with X-Content-Type-Options: nosniff and a plain
            type (application/octet-stream unless a harmless known type) - NOTHING renders in the browser, so an uploaded
            .html can never become a page on this origin
  upload    PUT /api/upload?path=<folder>&name=<file>[&replace=1]: the request body IS the file (no multipart parsing;
            the page sends the File object as the body). Content-Length is required and must be at most
            FILES_MAX_UPLOAD_MB, else 413 BEFORE a byte of the body is read (also on Expect: 100-continue, so a client
            that waits for the go-ahead never sends it); a body sent anyway is then read and dropped, bounded, so the
            refusal reaches the client through the proxy instead of a reset (Handler.drain). The body is streamed to a temporary file in the target folder,
            then moved onto its name: a new name by a hard link, which an existing file makes fail (409) whatever the
            timing; replace=1 moves over an existing file. The name is a basename only: '', '.', '..', a '/' or '\\', a
            NUL, a control character, a name longer than 255 bytes and a name shaped like a temporary file are refused.
  mkdir     POST /api/mkdir?path=<folder>&name=<folder>: a new folder (the same name rules; an existing name is 409)
  delete    POST /api/delete?path=<folder>&name=<entry>[&recursive=1]: a file or a link is unlinked (a link as a link,
            whatever it points at, inside or out); a folder when it is empty, else 409 with how many entries it holds -
            recursive=1 removes it with everything under it (the page sends that only after a confirm naming the count)
  move      POST /api/move?path=<folder>&name=<entry>[&to=<folder>][&newname=<name>][&replace=1]: a rename (a new name
            in the same folder), a move (another folder) or both. The destination folder passes the same fence as the
            source (to=../ or a link out of FILES_DIR is refused exactly like path=) and the new name the same name
            rules; a destination that exists is 409 unless replace=1 and both sides are files (a folder is never
            replaced and never replaces one); a folder cannot move into itself or under itself (400). The shared folder
            is one volume, so a move is a rename on the filesystem, never a copy
  health    GET /healthz: 200 while FILES_DIR is a directory this process may write, 503 otherwise (the dot probe)
  The DELETE method itself stays 405: every change is a PUT or a POST, behind the one own-origin guard below. Nothing is
  ever executed - the one thing this server does not do with a file. The page builds its DOM with textContent only and
  asks before it deletes or replaces anything.

Confinement: every path= is split on '/', each segment must be a name the rules above allow (no '..'), and the result is
resolved with os.path.realpath against the resolved FILES_DIR - whatever it resolves to must stay inside, so a symlink
that points out of the folder, a percent-encoded or dotted traversal, an absolute path and a NUL answer 400 or 404, never
500 and never a byte from outside. Writes (PUT, POST) and the listing are answered to the page's own origin only: an
Origin, when sent, must name this host (files.localhost or a loopback name) on the port the request arrived on, and a
Sec-Fetch-Site, when sent, must be same-origin or none; "null" and every other origin get 403. A Host other than
files.localhost or a loopback name gets 421 everywhere; a method without a handler 405 with Allow; a malformed request
line 400 as plain text, never the stdlib's HTML page. Every response carries Cache-Control: no-store, nosniff,
no-referrer, X-Frame-Options DENY and a Content-Security-Policy of this origin alone (the home proxy widens it by exactly
the hashes of the home badge it injects). Each response closes its connection, so an unread body (a refused upload) is
never read as the next request. Log lines carry the method, the path without its query (so no file name), the status
and the Host - never a file's contents.

Settings (environment):
  UI_PORT_FILES           the port on 127.0.0.1 (default 8098); UI_BACKEND_LISTEN_HOST the address (default 127.0.0.1)
  FILES_DIR               the shared folder (default /wd/files; created at start, mode 0755, when it does not exist)
  FILES_MAX_UPLOAD_MB     the largest upload accepted, in MiB (default 1024; a value that is not a number of MiB above 0
                          falls back to 1024 with a log line, the rule home-render.sh applies to the route's limit)
  FILES_UI_DIR            the page's files (default: the files-ui/ directory beside this script)

  GET /                   the page;  GET /files.js, /files.css  its script and stylesheet
  GET /__harness/harness.css  an empty stylesheet, so the page's link to the harness stylesheet (served by the home proxy
                          on this path once it is installed) never fails; files.css is written against that stylesheet's
                          tokens and components, so without it the page is unstyled but readable
"""
import datetime
import errno
import json
import os
import re
import secrets
import shutil
import stat
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

E = os.environ
FILES_HOST = "files.localhost"
PORT = int(E.get("UI_PORT_FILES", "8098") or 8098)
LISTEN = E.get("UI_BACKEND_LISTEN_HOST", "127.0.0.1") or "127.0.0.1"
FILES_DIR = E.get("FILES_DIR", "/wd/files") or "/wd/files"


def mb_or_default(raw):
    """FILES_MAX_UPLOAD_MB as a number of MiB above 0, else 1024 (home-render.sh's rule for the route's limit, so the two
    keep refusing alike); the fallback is logged at start."""
    try:
        n = int(str(raw).strip())
    except (TypeError, ValueError):
        n = 0
    if n <= 0:
        print(f"files: FILES_MAX_UPLOAD_MB={raw!r} is not a number of MiB above 0 - 1024 used", flush=True)
        return 1024
    return n


MAX_MB = mb_or_default(E.get("FILES_MAX_UPLOAD_MB", "1024") or "1024")
MAX_BYTES = MAX_MB * 1024 * 1024
# what a refusal answered before the body was read drops of that body before the connection closes (Handler.drain): at
# most the route's own limit, the cap plus 1 MiB (home-render.sh), for at most DRAIN_SECONDS
DRAIN_BYTES = MAX_BYTES + 1024 * 1024
DRAIN_SECONDS = 10
UI_DIR = E.get("FILES_UI_DIR", "") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "files-ui")
CHUNK = 64 * 1024
NAME_MAX_BYTES = 255
TEMP_PREFIX = ".files-uploading-"   # an upload in flight, in its target folder; hidden from listings, refused as a name
TEMP_MAX_AGE = 3600                 # an in-flight file older than this at start was abandoned by a process that died
# the bidi controls that make "invoice\u202etxt.exe" read as "invoiceexe.txt": refused in a name like the C0 and C1 controls
BIDI_CONTROLS = frozenset("\u061c\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069")
ALLOW = "GET, HEAD, PUT, POST"
FILES = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
         "/files.js": ("files.js", "text/javascript; charset=utf-8"), "/files.css": ("files.css", "text/css; charset=utf-8")}
# The harness stylesheet the page links (its design tokens and components, shared by every page the harness builds itself)
# is served by the home proxy on this path of every host route once that base is installed; until then, or on a route
# without it, the page's link lands here and gets an empty stylesheet rather than an error.
SHARED_CSS_PATH = "/__harness/harness.css"
SHARED_CSS_FALLBACK = (b"/* the harness stylesheet is served by the home proxy on this path when its base is installed; "
                       b"this empty fallback keeps the page's link valid, and the page reads unstyled until then */\n")
CSP = ("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; "
       "form-action 'none'; frame-ancestors 'none'")
# the download types that are not active content; everything else is application/octet-stream. With the attachment
# disposition and nosniff nothing renders either way - the type only helps the receiving side pick a program
SAFE_TYPES = {".txt": "text/plain; charset=utf-8", ".md": "text/plain; charset=utf-8", ".log": "text/plain; charset=utf-8",
              ".csv": "text/csv; charset=utf-8", ".json": "application/json", ".pdf": "application/pdf",
              ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp",
              ".zip": "application/zip", ".gz": "application/gzip", ".tar": "application/x-tar"}


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    print(f"{now()} {msg}", flush=True)


class Refused(Exception):
    """A request this server answers with a status and one plain sentence."""

    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code
        self.msg = msg


def name_ok(name):
    """A basename this folder can hold: no separator, no '.' or '..', no NUL, no C0 or C1 control character, no bidi
    control (a name that reads as another), at most 255 bytes, and not shaped like one of this server's temporary files."""
    if not name or name in (".", "..") or len(name.encode("utf-8", "surrogateescape")) > NAME_MAX_BYTES:
        return False
    if "/" in name or "\\" in name or name.startswith(TEMP_PREFIX):
        return False
    return not any(ord(c) < 32 or 127 <= ord(c) < 160 or c in BIDI_CONTROLS for c in name)


def root_dir():
    """FILES_DIR as it resolves right now (a link at the folder itself is followed; the result is the fence)."""
    return os.path.realpath(FILES_DIR)


def resolve(rel):
    """(root, real path, clean relative path) of a request's path= inside FILES_DIR, or Refused.

    The path is split on '/', every segment must pass name_ok (so '..' never gets near the filesystem), and the joined
    path is resolved with realpath: a symlink along the way may point anywhere, so the RESOLVED path is what must stay
    under the resolved root. Outside is 404 - nothing about what is there is told."""
    rel = rel or ""
    if "\x00" in rel:
        raise Refused(400, "refused: a NUL in the path")
    parts = [p for p in rel.replace("\\", "/").split("/") if p not in ("", ".")]
    for p in parts:
        if not name_ok(p):
            raise Refused(400, "refused: a path segment this folder cannot hold")
    root = root_dir()
    real = os.path.realpath(os.path.join(root, *parts)) if parts else root
    if real != root and not real.startswith(root + os.sep):
        raise Refused(404, "not found: that path is not inside the shared folder")
    return root, real, "/".join(parts)


def inside(root, real):
    return real == root or real.startswith(root + os.sep)


def opendir_inside(root, real):
    """An open descriptor of the folder at real, checked AFTER the open: resolve() checked a path string, and between that
    check and the operation a rename could swap the folder for a link out of FILES_DIR. What the descriptor points at
    (/proc/self/fd) is what is checked, and the operation then goes through the descriptor (dir_fd), so the fence holds
    whatever moves under it. Outside, missing or not a folder: 404."""
    try:
        fd = os.open(real, os.O_RDONLY | os.O_DIRECTORY)
    except (FileNotFoundError, NotADirectoryError):
        raise Refused(404, "not found: no such folder in the shared folder")
    if not inside(root, os.path.realpath(f"/proc/self/fd/{fd}")):
        os.close(fd)
        raise Refused(404, "not found: that path is not inside the shared folder")
    return fd


def lstat_at(dfd, name):
    """The stat of the entry called name in the folder descriptor dfd, the entry itself (a link as a link), or None when
    nothing of that name is there."""
    try:
        return os.stat(name, dir_fd=dfd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def listing(root, real, rel):
    """The entries of one folder: folders first, then files, each by name; a symlink is reported with where it leads
    (inside: served like what it points at; outside: marked, never served); in-flight uploads are hidden."""
    entries, hidden = [], 0
    dfd = opendir_inside(root, real)
    try:
        with os.scandir(dfd) as it:
            for e in it:
                if e.name.startswith(TEMP_PREFIX):
                    hidden += 1
                    continue
                # a name this server will not take back in a request (a separator, a control character, too long) or that
                # is not UTF-8 (a lone surrogate from os.scandir) is shown under a printable form and marked unservable,
                # so the page never builds a request from it and never chokes on it
                shown = e.name.encode("utf-8", "surrogateescape").decode("utf-8", "replace")
                item = {"name": shown, "type": "other", "size": None, "mtime": None, "link": False,
                        "served": shown == e.name and name_ok(e.name)}
                try:
                    st = e.stat(follow_symlinks=False)
                    item["mtime"] = iso(st.st_mtime)
                    if e.is_symlink():
                        item["link"] = True
                        target = os.path.realpath(os.path.join(real, e.name))
                        if not inside(root, target):
                            item["type"] = "outside"
                        elif os.path.isdir(target):
                            item["type"] = "dir"
                        elif os.path.isfile(target):
                            item["type"] = "file"
                            item["size"] = os.stat(target).st_size
                    elif e.is_dir(follow_symlinks=False):
                        item["type"] = "dir"
                    elif e.is_file(follow_symlinks=False):
                        item["type"] = "file"
                        item["size"] = st.st_size
                except (OSError, ValueError, OverflowError):
                    pass   # an entry that vanished, cannot be read or carries a time outside the calendar is listed with what was read
                entries.append(item)
    finally:
        os.close(dfd)
    order = {"dir": 0, "file": 1, "outside": 2, "other": 3}
    entries.sort(key=lambda i: (order[i["type"]], i["name"].casefold(), i["name"]))
    parent = rel.rsplit("/", 1)[0] if "/" in rel else ("" if rel else None)
    return {"schema": "do-agent-aws-files/v1", "root": FILES_DIR, "path": rel, "parent": parent,
            "max_upload_bytes": MAX_BYTES, "max_upload_mb": MAX_MB, "entries": entries, "hidden_in_flight": hidden,
            "generated_at": now()}


def count_entries(real):
    """How many entries a folder holds, at every depth; a link counts as one entry and is never followed."""
    return sum(len(dirs) + len(files) for _, dirs, files in os.walk(real))


def health():
    root = root_dir()
    if not os.path.isdir(root):
        return 503, {"ok": False, "dir": FILES_DIR, "error": "the shared folder does not exist (ui-start.sh creates it)"}
    if not os.access(root, os.W_OK):
        return 503, {"ok": False, "dir": FILES_DIR, "error": "the shared folder is not writable by this server"}
    return 200, {"ok": True, "dir": FILES_DIR, "max_upload_mb": MAX_MB}


def host_name(host_header):
    name = (host_header or "").strip().lower()
    if name.startswith("[") and "]" in name:
        return name[1:name.index("]")]
    return name.rsplit(":", 1)[0] if re.search(r":[0-9]{1,5}$", name) else name


def host_ok(host_header):
    name = host_name(host_header).rstrip(".")
    return name in (FILES_HOST, "127.0.0.1", "localhost", "::1")


def origin_ok(headers, host_header):
    """The listing and every write are answered to their own origin only: an Origin, when sent, must name THIS host - the
    name the request's Host carries (files.localhost through the proxy, a loopback name on the direct port), not another
    loopback name - on the port the request arrived on; a Sec-Fetch-Site, when sent, must be same-origin or none. An
    Origin that does not parse (a port out of range, an unclosed IPv6 literal) is refused, never an error."""
    sfs = (headers.get("Sec-Fetch-Site") or "").strip().lower()
    if sfs and sfs not in ("same-origin", "none"):
        return False
    origin = (headers.get("Origin") or "").strip()
    if not origin or origin.lower() == "null":
        return not origin  # "null" (an opaque origin: a sandboxed or file page) is refused
    try:
        p = urllib.parse.urlparse(origin)
        port = p.port
    except ValueError:
        return False
    if p.scheme not in ("http", "https") or not host_ok(p.netloc):
        return False
    if host_name(p.netloc).rstrip(".") != host_name(host_header).rstrip("."):
        return False
    want = re.search(r":([0-9]{1,5})$", (host_header or "").strip())
    have = str(port or (443 if p.scheme == "https" else 80))
    return have == (want.group(1) if want else "80")


def disposition(name):
    """Content-Disposition: attachment with the name twice - an ASCII fallback, and the UTF-8 form every browser uses."""
    fallback = re.sub(r"[^A-Za-z0-9._-]", "_", name) or "download"
    return f"attachment; filename=\"{fallback}\"; filename*=UTF-8''{urllib.parse.quote(name, safe='')}"


class Handler(BaseHTTPRequestHandler):
    server_version = "do-agent-aws-files"
    sys_version = ""
    # HTTP/1.1, so a client's Expect: 100-continue reaches handle_expect_100 and an upload over the cap is refused
    # before its body is sent; every response still closes the connection (send below), so a body left unread by a
    # refusal is never parsed as the next request
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype, extra=None):
        self.close_connection = True
        self.send_response(code)
        headers = {"Content-Type": ctype, "Content-Length": str(len(body)), "Cache-Control": "no-store",
                   "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY",
                   "Cross-Origin-Resource-Policy": "same-origin", "Content-Security-Policy": CSP, "Connection": "close"}
        headers.update(extra or {})
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.note(code)

    def note(self, code, more=""):
        headers = getattr(self, "headers", None)
        shown = re.sub(r"[^A-Za-z0-9.:\[\]_-]", "?", (headers.get("Host") if headers else "") or "")[:60]
        path = re.sub(r"[^A-Za-z0-9/._~-]", "?", str(getattr(self, "path", "") or "").split("?", 1)[0])[:80]
        log(f"{self.command or '?'} {path} -> {code} host={shown}{more}")

    def text(self, code, msg, extra=None):
        self.send(code, (msg + "\n").encode("utf-8"), "text/plain; charset=utf-8", extra)

    def json(self, code, body, extra=None):
        self.send(code, json.dumps(body).encode("utf-8"), "application/json", extra)

    def misdirected(self):
        self.text(421, f"misdirected: this folder answers on {FILES_HOST} through the harness home port, or on loopback")

    def refuse(self):
        """Any method without a handler: the same Host check first (a foreign Host is misdirected, whatever it asks),
        then 405 with what is allowed."""
        headers = getattr(self, "headers", None)
        if not host_ok(headers.get("Host", "") if headers else ""):
            return self.misdirected()
        self.text(405, f"not here: {ALLOW} only (a deletion or a move is a POST to /api/delete or /api/move; nothing executed)",
                  {"Allow": ALLOW})

    do_DELETE = do_PATCH = do_OPTIONS = refuse

    def send_error(self, code, message=None, explain=None):
        """The stdlib's error path answers like every other response here - plain text with the same headers, never its
        HTML page: a method this server has no handler for (TRACE, PROPFIND, any token: the stdlib's 501) is 405 with
        Allow, after the same Host check; a malformed request line (400, 414, 431) is refused as plain text."""
        self.close_connection = True
        if code == 501:
            return self.refuse()
        self.text(code, re.sub(r"[^A-Za-z0-9 .,:;()'_-]", "?", str(message or "request refused"))[:120])

    # --- the request's parts ---

    def query(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query, keep_blank_values=True)
        return {k: v[-1] for k, v in q.items()}

    def precheck_write(self):
        """What refuses an upload or a mkdir before its body is read: (code, message) or None. Shared by the method
        handlers and by handle_expect_100, so a client that waits for the go-ahead never sends a body in vain."""
        host = self.headers.get("Host", "")
        if not host_ok(host):
            return 421, f"misdirected: this folder answers on {FILES_HOST} through the harness home port, or on loopback"
        if not origin_ok(self.headers, host):
            return 403, "refused: the shared folder takes uploads and folders from its own page only"
        if self.command == "PUT":
            length = self.headers.get("Content-Length")
            length = (length or "").strip()
            # ascii digits only, and not more than 15 of them: "²".isdigit() is True but int("²") raises, and a number of
            # thousands of digits is nobody's upload
            if not (length.isascii() and length.isdigit() and len(length) <= 15):
                return 411, "length required: the upload's Content-Length must be sent as a plain number (chunked bodies are not taken)"
            if int(length) > MAX_BYTES:
                return 413, f"too large: the shared folder takes files up to {MAX_MB} MiB (FILES_MAX_UPLOAD_MB)"
        return None

    def handle_expect_100(self):
        if self.command in ("PUT", "POST"):
            refusal = self.precheck_write()
            if refusal:
                self.text(*refusal)
                return False
        return super().handle_expect_100()

    # --- GET ---

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        try:
            self.get()
        except Refused as r:
            self.text(r.code, r.msg)
        except (BrokenPipeError, ConnectionResetError) as e:
            self.close_connection = True   # the client went away: nothing can be answered, one log line and no traceback
            self.note(0, f" client gone ({type(e).__name__})")
        except PermissionError:
            self.text(403, "refused: this server may not read that")
        except FileNotFoundError:
            self.text(404, "not found")
        except OSError as e:
            self.text(500, f"the folder could not be read ({type(e).__name__})")

    def get(self):
        path = urllib.parse.urlparse(self.path).path
        host = self.headers.get("Host", "")
        if not host_ok(host):
            return self.misdirected()
        if path == "/healthz":
            code, body = health()
            return self.json(code, body)
        if path == "/api/list":
            if not origin_ok(self.headers, host):
                return self.text(403, "refused: the shared folder's listing is answered to its own origin only")
            root, real, rel = resolve(self.query().get("path", ""))
            if not os.path.isdir(real):
                return self.text(404, "not found: no such folder in the shared folder")
            return self.json(200, listing(root, real, rel))
        if path == "/api/download":
            # a download is a navigation from this page or a direct client; a fetch from another site (an <img> or a
            # <video> on a foreign page probing names and sizes, a download it starts) is refused, and the
            # Cross-Origin-Resource-Policy header on every response tells the browser the same
            sfs = (self.headers.get("Sec-Fetch-Site") or "").strip().lower()
            if sfs and sfs not in ("same-origin", "none"):
                return self.text(403, "refused: a download is taken from this page or a direct client, not from another site")
            root, real, rel = resolve(self.query().get("path", ""))
            if os.path.isdir(real):
                return self.text(400, "a folder is not downloaded as one file: open it and download its files")
            if not os.path.isfile(real):
                return self.text(404, "not found: no such file in the shared folder")
            return self.stream(root, real, rel.rsplit("/", 1)[-1])
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

    def stream(self, root, real, name):
        """One file as an attachment, in chunks; the size from the open descriptor, so what is announced is what is sent.
        The descriptor is checked after the open: what it points at must be a regular file inside FILES_DIR (resolve()
        checked a path string; a rename between that check and this open could have swapped the file for a link out)."""
        ctype = SAFE_TYPES.get(os.path.splitext(name)[1].lower(), "application/octet-stream")
        with open(real, "rb") as f:
            st = os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode) or not inside(root, os.path.realpath(f"/proc/self/fd/{f.fileno()}")):
                return self.text(404, "not found: no such file in the shared folder")
            size = st.st_size
            self.close_connection = True
            self.send_response(200)
            for k, v in (("Content-Type", ctype), ("Content-Length", str(size)), ("Content-Disposition", disposition(name)),
                         ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
                         ("X-Frame-Options", "DENY"), ("Cross-Origin-Resource-Policy", "same-origin"), ("Content-Security-Policy", CSP),
                         ("Connection", "close")):
                self.send_header(k, v)
            self.end_headers()
            sent = 0
            if self.command != "HEAD":
                try:
                    while sent < size:
                        buf = f.read(min(CHUNK, size - sent))
                        if not buf:
                            break
                        self.wfile.write(buf)
                        sent += len(buf)
                except OSError as e:
                    # the headers are out: a read error or a client that went away ends the response with the connection,
                    # never with a second status line in the body
                    self.close_connection = True
                    self.note(200, f" bytes={sent} of {size} - cut short ({type(e).__name__})")
                    return
        self.note(200, f" bytes={sent}")

    # --- PUT: an upload ---

    def do_PUT(self):
        length = (self.headers.get("Content-Length") or "").strip()
        self.unread = int(length) if length.isascii() and length.isdigit() and len(length) <= 15 else 0
        try:
            self.put()
        except Refused as r:
            self.text(r.code, r.msg)
        except PermissionError:
            self.text(403, "refused: this server may not write there")
        except OSError as e:
            self.text(500, f"the upload could not be stored ({type(e).__name__})")
        finally:
            self.drain()

    def drain(self):
        """A refusal answered before the body was read (the 413 above all) leaves the client sending that body, and a
        connection closed with input unread is reset: the reset can reach the home proxy before it has read the refusal,
        and the proxy then answers 502 in its place. So the rest of the body is read and dropped first, after the answer
        went out - at most DRAIN_BYTES (the route's own limit) and for at most DRAIN_SECONDS. A client that asked for the
        go-ahead (Expect: 100-continue) and was refused never reaches do_PUT (handle_expect_100 answers it), so it sends
        no body; one that got the go-ahead sends it, and is drained like any other."""
        left = min(getattr(self, "unread", 0), DRAIN_BYTES)
        self.unread = 0
        if left <= 0:
            return
        deadline = time.monotonic() + DRAIN_SECONDS
        try:
            self.connection.settimeout(1)
            while left > 0 and time.monotonic() < deadline:
                buf = self.rfile.read1(min(CHUNK, left))
                if not buf:
                    break
                left -= len(buf)
        except OSError:
            pass   # the client stopped sending or went away: nothing more to drop

    def put(self):
        path = urllib.parse.urlparse(self.path).path
        if path != "/api/upload":
            if not host_ok(self.headers.get("Host", "")):
                return self.misdirected()
            return self.text(404, "not found: uploads go to PUT /api/upload?path=<folder>&name=<file>")
        refusal = self.precheck_write()
        if refusal:
            return self.text(*refusal)
        q = self.query()
        name = q.get("name", "")
        if not name_ok(name):
            return self.text(400, "refused: the name must be a plain file name (no '/', no '..', no control character)")
        replace = q.get("replace", "") == "1"
        root, folder, rel = resolve(q.get("path", ""))
        length = int(self.headers["Content-Length"].strip())
        # the folder as a descriptor, checked after the open; every step below goes through it (dir_fd), so a rename of the
        # folder between the check and the write changes nothing about where the bytes land
        dfd = opendir_inside(root, folder)
        try:
            there = lstat_at(dfd, name)
            if there is not None:
                if not replace:
                    return self.text(409, "exists: a file of that name is in the folder (replace=1 overwrites it)")
                if stat.S_ISDIR(there.st_mode):
                    return self.text(409, "exists: a folder of that name is in the folder")
            tmp = TEMP_PREFIX + secrets.token_hex(8)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=dfd)
            try:
                with os.fdopen(fd, "wb") as out:
                    remaining = length
                    while remaining > 0:
                        buf = self.rfile.read(min(CHUNK, remaining))
                        if not buf:
                            raise Refused(400, f"the upload ended after {length - remaining} of {length} bytes")
                        out.write(buf)
                        remaining -= len(buf)
                        self.unread = remaining
                    os.fchmod(out.fileno(), 0o644)
                if replace:
                    existed = lstat_at(dfd, name) is not None
                    os.replace(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
                else:
                    existed = False
                    try:
                        os.link(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd, follow_symlinks=False)   # fails on an existing name whatever happened since the check above
                    except FileExistsError:
                        raise Refused(409, "exists: a file of that name is in the folder (replace=1 overwrites it)")
                    os.unlink(tmp, dir_fd=dfd)
            except BaseException:
                try:
                    os.unlink(tmp, dir_fd=dfd)
                except OSError:
                    pass
                raise
        finally:
            os.close(dfd)
        self.json(200 if existed else 201, {"name": name, "path": (rel + "/" if rel else "") + name, "size": length,
                                              "replaced": existed})

    # --- POST: a new folder, a deletion, a rename or a move. Never the DELETE method: a POST keeps every change behind
    #     the one own-origin guard (precheck_write), and the verb stays 405 ---

    POSTS = {"/api/mkdir": "mkdir", "/api/delete": "delete", "/api/move": "move"}

    def do_POST(self):
        try:
            self.post()
        except Refused as r:
            self.text(r.code, r.msg)
        except PermissionError:
            self.text(403, "refused: this server may not change that")
        except OSError as e:
            self.text(500, f"the folder could not be changed ({type(e).__name__})")

    def post(self):
        path = urllib.parse.urlparse(self.path).path
        if path not in self.POSTS:
            if not host_ok(self.headers.get("Host", "")):
                return self.misdirected()
            return self.text(404, "not found: POST /api/mkdir, /api/delete or /api/move, each ?path=<folder>&name=<entry>")
        refusal = self.precheck_write()
        if refusal:
            return self.text(*refusal)
        getattr(self, self.POSTS[path])(self.query())

    def entry(self, q, what):
        """The ?path=<folder>&name=<entry> of a POST through the fence: (root, the folder's open descriptor, the folder's
        real path, its clean relative path, the name, the entry's path as the page shows it) - or Refused. The name is a
        plain basename (name_ok), the folder resolves inside FILES_DIR (resolve) and is opened and checked as a descriptor
        (opendir_inside), so the entry is at a path the fence allows and every operation goes through the descriptor. The
        caller closes it."""
        name = q.get("name", "")
        if not name_ok(name):
            raise Refused(400, f"refused: the name must be a plain {what} name (no '/', no '..', no control character)")
        root, folder, rel = resolve(q.get("path", ""))
        dfd = opendir_inside(root, folder)
        return root, dfd, folder, rel, name, (rel + "/" if rel else "") + name

    def mkdir(self, q):
        root, dfd, folder, rel, name, shown = self.entry(q, "folder")
        try:
            os.mkdir(name, 0o755, dir_fd=dfd)
        except FileExistsError:
            return self.text(409, "exists: something of that name is in the folder")
        finally:
            os.close(dfd)
        self.json(201, {"name": name, "path": shown})

    def delete(self, q):
        """What is removed is always the entry AT folder/name through the folder's descriptor, which the fence put inside
        FILES_DIR: a link is unlinked as a link (what it points at, inside or out, is never touched); a folder is removed
        when empty, else refused with its count, unless recursive=1 removes it with everything under it (shutil.rmtree does
        not follow links; it looks the folder up by path once - the one step here that is not through a descriptor)."""
        root, dfd, folder, rel, name, shown = self.entry(q, "file or folder")
        try:
            st = lstat_at(dfd, name)
            if st is None:
                return self.text(404, "not found: nothing of that name is in the folder")
            kind = "link" if stat.S_ISLNK(st.st_mode) else "dir" if stat.S_ISDIR(st.st_mode) else "file"
            if kind != "dir":
                os.unlink(name, dir_fd=dfd)
                return self.json(200, {"path": shown, "type": kind, "removed": 1})
            target = os.path.join(folder, name)
            held = count_entries(target)
            if held and q.get("recursive", "") != "1":
                return self.json(409, {"error": f"not empty: the folder holds {held} {'entry' if held == 1 else 'entries'} "
                                                "(recursive=1 removes it with everything in it)",
                                       "path": shown, "type": "dir", "entries": held})
            if held:
                shutil.rmtree(target)
            else:
                os.rmdir(name, dir_fd=dfd)
        finally:
            os.close(dfd)
        self.json(200, {"path": shown, "type": "dir", "removed": held + 1})

    def move(self, q):
        """A rename (newname=, same folder), a move (to=<folder>) or both. The destination folder goes through resolve() and
        opendir_inside() exactly like the source, so to=../, a percent-encoded traversal, an absolute path or a link out of
        FILES_DIR is refused before anything moves, and the operation itself goes through both descriptors; the new name
        through name_ok. A file lands on a new name by a hard link that an existing name makes fail (409 whatever the
        timing), then its old name is unlinked; replace=1 moves a file over an existing file (never over or onto a folder);
        a folder is renamed in place and never onto an existing name."""
        root, sfd, folder, rel, name, shown = self.entry(q, "file or folder")
        dfd = None
        try:
            st = lstat_at(sfd, name)
            if st is None:
                return self.text(404, "not found: nothing of that name is in the folder")
            if "to" not in q and "newname" not in q:
                return self.text(400, "refused: say to=<folder> (a move), newname=<name> (a rename) or both")
            newname = q.get("newname") or name
            if not name_ok(newname):
                return self.text(400, "refused: the new name must be a plain name (no '/', no '..', no control character)")
            _, dest, drel = resolve(q.get("to", q.get("path", "")))
            src = os.path.join(folder, name)
            kind = "link" if stat.S_ISLNK(st.st_mode) else "dir" if stat.S_ISDIR(st.st_mode) else "file"
            if kind == "dir" and (dest == src or dest.startswith(src + os.sep)):
                return self.text(400, "refused: a folder cannot move into itself or into a folder under it")
            if os.path.join(dest, newname) == src:
                return self.text(400, "nothing to do: that is where it is, under that name")
            dfd = opendir_inside(root, dest)
            replace = q.get("replace", "") == "1"
            dst = lstat_at(dfd, newname)
            there = dst is not None
            dst_dir = there and stat.S_ISDIR(dst.st_mode)
            if there and (kind == "dir" or not replace or dst_dir):
                return self.text(409, "exists: something of that name is in the destination folder"
                                      + ("" if kind == "dir" or dst_dir else " (replace=1 replaces a file)"))
            to_shown = (drel + "/" if drel else "") + newname
            try:
                if kind == "dir":
                    os.rename(name, newname, src_dir_fd=sfd, dst_dir_fd=dfd)
                elif there:
                    os.replace(name, newname, src_dir_fd=sfd, dst_dir_fd=dfd)
                else:
                    try:
                        os.link(name, newname, src_dir_fd=sfd, dst_dir_fd=dfd, follow_symlinks=False)   # fails on an existing name whatever happened since the check
                    except FileExistsError:
                        return self.text(409, "exists: something of that name is in the destination folder (replace=1 replaces a file)")
                    os.unlink(name, dir_fd=sfd)
            except OSError as e:
                if e.errno == errno.EXDEV:
                    return self.text(400, "refused: the destination is on another filesystem than the source (the shared folder is one volume)")
                if e.errno in (errno.ENOTEMPTY, errno.EEXIST, errno.ENOTDIR, errno.EISDIR):
                    return self.text(409, "exists: something of that name is in the destination folder")
                raise
        finally:
            os.close(sfd)
            if dfd is not None:
                os.close(dfd)
        self.json(200, {"from": shown, "to": to_shown, "type": kind, "replaced": there})

def sweep_temp():
    """An upload in flight is a TEMP_PREFIX file in its target folder, removed on every failure this process sees. One the
    process did not see end (a kill, an OOM, a container stop mid-body) would stay: hidden from the listing, out of the
    page's reach. At start, such files older than TEMP_MAX_AGE are removed - a live upload keeps its mtime fresh. The walk
    follows no link, so it never leaves FILES_DIR."""
    swept = 0
    try:
        for d, _, files in os.walk(root_dir()):
            for n in files:
                if n.startswith(TEMP_PREFIX):
                    p = os.path.join(d, n)
                    try:
                        if time.time() - os.lstat(p).st_mtime > TEMP_MAX_AGE:
                            os.unlink(p)
                            swept += 1
                    except OSError:
                        pass
    except OSError:
        pass
    if swept:
        log(f"files: {swept} abandoned upload file(s) removed from {FILES_DIR}")


def main():
    for name, _ in FILES.values():
        if not os.path.isfile(os.path.join(UI_DIR, name)):
            raise SystemExit(f"files: the page file {name} is missing from {UI_DIR}")
    try:
        os.makedirs(FILES_DIR, mode=0o755, exist_ok=True)
    except OSError as e:
        log(f"files: WARNING - {FILES_DIR} could not be created ({type(e).__name__}); /healthz answers 503 until it exists")
    sweep_temp()
    server = ThreadingHTTPServer((LISTEN, PORT), Handler)
    server.daemon_threads = True
    log(f"files listening on {LISTEN}:{PORT} for {FILES_HOST} - the shared folder {FILES_DIR}, uploads up to {MAX_MB} MiB")
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
