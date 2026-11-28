#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Stateful stub of the Slack Web API's file-upload path, for test24.sh (slack-upload.sh) - 127.0.0.1 only,
# ephemeral port, stdlib only. Run: python3 -I slack-upload-stub.py; it prints "SEED m1=<ts> m2=<ts> r1=<ts>"
# then "LISTENING <port>" and serves until killed. Point the scripts at it with
# SLACK_API_BASE=http://127.0.0.1:<port>/api and SLACK_BOT_TOKEN=xoxb-test-stub.
#
# Slack methods (token required, else ok:false invalid_auth):
#   auth.test                       ok, user_id U0STUB
#   files.getUploadURLExternal      form fields filename + length -> upload_url (http://127.0.0.1:<port>/upload/<id>), file_id
#   POST /upload/<id>               the bytes (raw body); records their length and sha256; answers 200 "OK - <n>"
#   files.completeUploadExternal    JSON files=[{id,title}], channel_id, thread_ts?, initial_comment? -> ok, files[];
#                                   appends the file message (user U0STUB, text = initial_comment, files=[{id,name,title}],
#                                   thread_ts when given; the parent's reply_count grows), as Slack posts it
#   conversations.history           channel, oldest, inclusive, limit -> top-level messages newer than oldest, newest first
#   conversations.replies           channel, ts, oldest, inclusive, limit -> the parent first, then its replies ascending
# Test-only knobs (no token needed), each armed for the NEXT matching call unless said otherwise:
#   stub.state                      {messages, uploads, calls}
#   stub.failGetUrl?error=E&needed=S   files.getUploadURLExternal answers ok:false error E (needed S when given)
#   stub.evilUrl                    files.getUploadURLExternal answers an upload_url on another origin (http://127.0.0.1:1/...)
#   stub.failUpload?code=500        the next POST /upload/<id> answers that HTTP code, stores nothing
#   stub.failComplete?mode=error|hide|drop   error: ok:false upload_failed, no message; hide: ok:true but no message is
#                                   posted (the read-back must fail); drop: the message IS posted and the connection
#                                   closes without a response (landed, response lost)
#   stub.ratelimit?method=getUrl|complete&n=N   the next N calls of that method answer HTTP 429, Retry-After: 1
# Message ts values are the real clock with microseconds, strictly increasing, so a reader's oldest=<now - margin>
# finds what was just posted, as against Slack.
import hashlib
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = "Bearer xoxb-test-stub"
CHAN = "C0TESTCHAN"
_last_ts = 0.0


def ts():
    global _last_ts
    t = time.time()
    if t <= _last_ts:
        t = _last_ts + 0.000001
    _last_ts = t
    return "%.6f" % t


msgs = []
uploads = []          # {id, filename, declared_length, length, sha256, completed}
calls = {"getUrl": 0, "upload": 0, "complete": 0, "history": 0, "replies": 0}
knobs = {"failGetUrl": None, "evilUrl": False, "failUpload": None, "failComplete": None,
         "ratelimit": {"getUrl": 0, "complete": 0}}
_seq = 0

m1 = {"ts": ts(), "user": "U0PERSON", "text": "hello agent"}
m2 = {"ts": ts(), "user": "U0PERSON", "text": "please attach the chart", "reply_count": 0}
msgs.extend([m1, m2])
r1 = {"ts": ts(), "user": "U0PERSON", "text": "thread reply one", "thread_ts": m2["ts"]}
msgs.append(r1)
m2["reply_count"] = 1
m2["thread_ts"] = m2["ts"]


def parents():
    return [m for m in msgs if not m.get("thread_ts") or m["thread_ts"] == m["ts"]]


def newer(lst, oldest, inclusive):
    o = float(oldest or "0")
    return [m for m in lst if float(m["ts"]) > o or (inclusive and m["ts"] == oldest)]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, obj, code=200, headers=None, raw=None):
        body = raw if raw is not None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain" if raw is not None else "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def _handle(self):
        global _seq
        u = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(u.query).items()}
        raw = self._body()
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        params = dict(q)
        payload = None
        if u.path.startswith("/upload/"):
            fid = u.path[len("/upload/"):]
            calls["upload"] += 1
            if knobs["failUpload"]:
                code = int(knobs["failUpload"])
                knobs["failUpload"] = None
                return self._send(None, code=code, raw=b"upload refused by the stub")
            up = next((x for x in uploads if x["id"] == fid), None)
            if up is None:
                return self._send(None, code=404, raw=b"no such upload")
            up["length"] = len(raw)
            up["sha256"] = hashlib.sha256(raw).hexdigest()
            return self._send(None, raw=("OK - %d" % len(raw)).encode())
        if ctype == "application/x-www-form-urlencoded" and raw:
            params.update({k: v[-1] for k, v in parse_qs(raw.decode()).items()})
        elif ctype == "application/json" and raw:
            try:
                payload = json.loads(raw.decode())
            except Exception:
                return self._send({"ok": False, "error": "invalid_json"})
        method = u.path[len("/api/"):] if u.path.startswith("/api/") else u.path.lstrip("/")
        # knobs
        if method == "stub.state":
            return self._send({"ok": True, "messages": msgs, "uploads": uploads, "calls": calls, "knobs": {
                "failGetUrl": knobs["failGetUrl"], "evilUrl": knobs["evilUrl"], "failUpload": knobs["failUpload"],
                "failComplete": knobs["failComplete"], "ratelimit": knobs["ratelimit"]}})
        if method == "stub.failGetUrl":
            knobs["failGetUrl"] = {"error": params.get("error", "fatal_error"), "needed": params.get("needed")}
            return self._send({"ok": True})
        if method == "stub.evilUrl":
            knobs["evilUrl"] = True
            return self._send({"ok": True})
        if method == "stub.failUpload":
            knobs["failUpload"] = params.get("code", "500")
            return self._send({"ok": True})
        if method == "stub.failComplete":
            knobs["failComplete"] = params.get("mode", "error")
            return self._send({"ok": True})
        if method == "stub.ratelimit":
            knobs["ratelimit"][params.get("method", "getUrl")] = int(params.get("n", "1"))
            return self._send({"ok": True})
        # Slack methods
        if (self.headers.get("Authorization") or "") != TOKEN:
            return self._send({"ok": False, "error": "invalid_auth"})
        if method == "auth.test":
            return self._send({"ok": True, "user_id": "U0STUB", "team": "T0STUB", "user": "stubbot"})
        if method == "files.getUploadURLExternal":
            calls["getUrl"] += 1
            if knobs["ratelimit"]["getUrl"] > 0:
                knobs["ratelimit"]["getUrl"] -= 1
                return self._send({"ok": False, "error": "ratelimited"}, code=429, headers={"Retry-After": "1"})
            if knobs["failGetUrl"]:
                f = knobs["failGetUrl"]
                knobs["failGetUrl"] = None
                o = {"ok": False, "error": f["error"]}
                if f.get("needed"):
                    o["needed"] = f["needed"]
                    o["provided"] = "channels:history,chat:write"
                return self._send(o)
            fn = params.get("filename")
            ln = params.get("length")
            if not fn or not ln or not ln.isdigit():
                return self._send({"ok": False, "error": "invalid_arguments"})
            _seq += 1
            fid = "F0STUB%04d" % _seq
            uploads.append({"id": fid, "filename": fn, "declared_length": int(ln), "length": None, "sha256": None, "completed": False})
            host = self.headers.get("Host") or "127.0.0.1"
            url = "http://%s/upload/%s" % (host, fid)
            if knobs["evilUrl"]:
                knobs["evilUrl"] = False
                url = "http://127.0.0.1:1/upload/%s" % fid
            return self._send({"ok": True, "upload_url": url, "file_id": fid})
        if method == "files.completeUploadExternal":
            calls["complete"] += 1
            if knobs["ratelimit"]["complete"] > 0:
                knobs["ratelimit"]["complete"] -= 1
                return self._send({"ok": False, "error": "ratelimited"}, code=429, headers={"Retry-After": "1"})
            p = payload if isinstance(payload, dict) else {}
            files = p.get("files") or []
            if not files or p.get("channel_id") != CHAN:
                return self._send({"ok": False, "error": "invalid_arguments" if not files else "channel_not_found"})
            mode = knobs["failComplete"]
            knobs["failComplete"] = None
            if mode == "error":
                return self._send({"ok": False, "error": "upload_failed"})
            out = []
            for f in files:
                up = next((x for x in uploads if x["id"] == f.get("id")), None)
                if up is None or up["length"] is None:
                    return self._send({"ok": False, "error": "file_not_found"})
                up["completed"] = True
                out.append({"id": up["id"], "name": up["filename"], "title": f.get("title") or up["filename"]})
            if mode != "hide":
                m = {"ts": ts(), "user": "U0STUB", "text": p.get("initial_comment") or "", "files": out}
                if p.get("thread_ts"):
                    m["thread_ts"] = p["thread_ts"]
                    parent = next((x for x in msgs if x["ts"] == p["thread_ts"]), None)
                    if parent is not None:
                        parent["reply_count"] = parent.get("reply_count", 0) + 1
                        parent["thread_ts"] = parent["ts"]
                msgs.append(m)
            if mode == "drop":
                self.close_connection = True
                return
            return self._send({"ok": True, "files": out})
        if method == "conversations.history":
            calls["history"] += 1
            if params.get("channel") != CHAN:
                return self._send({"ok": False, "error": "channel_not_found"})
            lst = newer(parents(), params.get("oldest", "0"), params.get("inclusive") == "true")
            lst = sorted(lst, key=lambda m: float(m["ts"]), reverse=True)[: int(params.get("limit", "100"))]
            return self._send({"ok": True, "messages": lst, "has_more": False})
        if method == "conversations.replies":
            calls["replies"] += 1
            if params.get("channel") != CHAN:
                return self._send({"ok": False, "error": "channel_not_found"})
            parent = next((x for x in msgs if x["ts"] == params.get("ts")), None)
            if parent is None:
                return self._send({"ok": False, "error": "thread_not_found"})
            reps = [m for m in msgs if m is not parent and m.get("thread_ts") == parent["ts"]]
            lst = sorted(newer(reps, params.get("oldest", "0"), params.get("inclusive") == "true"), key=lambda m: float(m["ts"]))
            return self._send({"ok": True, "messages": [parent] + lst[: int(params.get("limit", "100"))], "has_more": False})
        return self._send({"ok": False, "error": "unknown_method"})


def main():
    srv = HTTPServer(("127.0.0.1", 0), H)
    print("SEED m1=%s m2=%s r1=%s" % (m1["ts"], m2["ts"], r1["ts"]), flush=True)
    print("LISTENING %d" % srv.server_address[1], flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
