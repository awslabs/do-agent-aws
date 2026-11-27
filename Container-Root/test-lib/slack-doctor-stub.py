#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""A loopback Slack Web API stub for slack-doctor.sh — enough of auth.test, conversations.info,
conversations.history, conversations.replies and chat.postMessage to prove the doctor's rows,
including the planted controls: a NARROW token missing channels:history, a channel the bot is not
in, and a wrong channel id. Binds 127.0.0.1:0 and prints its base URL; nothing else listens.

    python3 slack-doctor-stub.py &            # prints  SLACK_API_BASE=http://127.0.0.1:PORT
    SLACK_API_BASE=... SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK,C_NOTIN,C_NOPE \
        SLACK_TEST_CHANNEL=C_OK slack-doctor.sh --post-test       # C_OK PASS, C_NOTIN not_in_channel, C_NOPE channel_not_found
    SLACK_API_BASE=... SLACK_BOT_TOKEN=xoxb-narrow SLACK_CHANNELS=C_OK slack-doctor.sh
                                                                   # scopes row: missing scope channels:history

Tokens: `xoxb-full` carries every manifest scope; `xoxb-narrow` lacks channels:history (and
chat:write); `STUB_EXTRA_TOKEN` (env) adds one more with every scope; anything else is invalid_auth. Pass `--once` to exit after the first doctor run's
requests stop for 3 s, or kill it.
"""
import json
import os
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FULL = ("channels:history groups:history im:history mpim:history channels:read groups:read "
        "im:read mpim:read users:read chat:write")
NARROW = "groups:history im:history mpim:history channels:read groups:read im:read mpim:read users:read"
TOKENS = {"xoxb-full": FULL, "xoxb-narrow": NARROW}
# STUB_EXTRA_TOKEN: one more accepted token with every scope, so test23.sh can prove that an
# awkward token (a quote, a backslash) reaches curl byte-exact through the doctor's stdin config line
if os.environ.get("STUB_EXTRA_TOKEN"):
    TOKENS[os.environ["STUB_EXTRA_TOKEN"]] = FULL
CHANNELS = {"C_OK": {"name": "doctor-test", "member": True},
            "C_NOTIN": {"name": "elsewhere", "member": False}}
MESSAGES = {"C_OK": [{"type": "message", "ts": "1700000000.000100", "user": "U_SOMEONE", "text": "hello"}]}
_ts = [time.time()]
LAST = [time.time()]


def next_ts():
    _ts[0] = max(time.time(), _ts[0] + 0.001)
    return f"{_ts[0]:.6f}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def do_POST(self):
        LAST[0] = time.time()
        method = self.path.strip("/").split("/")[-1]
        length = int(self.headers.get("Content-Length") or 0)
        form = dict(urllib.parse.parse_qsl(self.rfile.read(length).decode()))
        auth = self.headers.get("Authorization", "")
        token = auth.removeprefix("Bearer ").strip()
        scopes = TOKENS.get(token)
        if scopes is None:
            return self.answer(200, {"ok": False, "error": "invalid_auth"}, None)
        granted = set(scopes.split())
        if method == "auth.test":
            return self.answer(200, {"ok": True, "user_id": "U_BOT", "user": "comms-engine", "team": "T_STUB"}, scopes)
        need = {"conversations.info": "channels:read", "conversations.history": "channels:history",
                "conversations.replies": "channels:history", "chat.postMessage": "chat:write"}.get(method)
        if need is None:
            return self.answer(200, {"ok": False, "error": "unknown_method"}, scopes)
        if need not in granted:
            return self.answer(200, {"ok": False, "error": "missing_scope", "needed": need,
                                     "provided": ",".join(sorted(granted))}, scopes)
        ch = form.get("channel", "")
        if ch not in CHANNELS:
            return self.answer(200, {"ok": False, "error": "channel_not_found"}, scopes)
        if method == "conversations.info":
            return self.answer(200, {"ok": True, "channel": {"id": ch, "name": CHANNELS[ch]["name"]}}, scopes)
        if not CHANNELS[ch]["member"]:
            return self.answer(200, {"ok": False, "error": "not_in_channel"}, scopes)
        msgs = MESSAGES.setdefault(ch, [])
        if method == "chat.postMessage":
            m = {"type": "message", "ts": next_ts(), "user": "U_BOT", "text": form.get("text", "")}
            if form.get("thread_ts"):
                m["thread_ts"] = form["thread_ts"]
            msgs.append(m)
            return self.answer(200, {"ok": True, "channel": ch, "ts": m["ts"]}, scopes)
        if method == "conversations.history":
            out = [m for m in msgs if not m.get("thread_ts")]
            if form.get("latest") and form.get("oldest") and form.get("inclusive"):
                out = [m for m in out if float(form["oldest"]) <= float(m["ts"]) <= float(form["latest"])]
            out.sort(key=lambda m: float(m["ts"]), reverse=True)
            return self.answer(200, {"ok": True, "messages": out[: int(form.get("limit") or 100)], "has_more": False}, scopes)
        if method == "conversations.replies":
            root = form.get("ts")
            out = [m for m in msgs if m.get("ts") == root or m.get("thread_ts") == root]
            return self.answer(200, {"ok": True, "messages": out, "has_more": False}, scopes)

    def answer(self, status, payload, scopes):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if scopes is not None:
            self.send_header("x-oauth-scopes", scopes.replace(" ", ","))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(f"SLACK_API_BASE=http://127.0.0.1:{srv.server_address[1]}", flush=True)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        if "--once" in sys.argv:
            while time.time() - LAST[0] < 3:
                time.sleep(0.2)  # nosemgrep: arbitrary-sleep -- test stub: poll interval while its client finishes
        else:
            while True:
                time.sleep(1)  # nosemgrep: arbitrary-sleep -- test stub: keeps the process serving
    except KeyboardInterrupt:
        pass
    finally:
        srv.shutdown()


if __name__ == "__main__":
    main()
