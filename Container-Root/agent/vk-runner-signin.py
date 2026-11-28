#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""vk-runner-signin.py - the agent runner's sign-in to the self-hosted board, stored before the runner starts, so that
the runner is the board's host.

With the relay on (UI_KANBAN_RELAY=true, docs/manual/boards.md "Kanban board"), /agent/ui-start.sh runs this just before it starts
the agent runner with the board as its shared API (VK_SHARED_API_BASE) and the relay (VK_SHARED_RELAY_API_BASE), and
not while the runner is running. It signs in to the board with the board login (POST <KANBAN_BOARD_URL>/v1/auth/local/
login) and stores the session's refresh token where the runner keeps its sign-in: VK_CREDENTIALS, the credentials.json
beside the runner's config.json, as the one field the runner stores there, mode 600, written to a temporary file in the
same folder and renamed into place. The runner loads it when it starts, gets its access token from the board and
registers with the relay as the board's host. Every start stores a new sign-in. Not through the runner's own sign-in
(its POST /api/auth/local/login): in vibe-kanban 0.1.44 that one turns the runner's analytics on ("analytics
automatically enabled after successful login") and sends usage events, the login's email among them, to vibe-kanban's
PostHog. Bounded: it waits up to VK_SIGNIN_WAIT seconds for the board and prints one line. The password and the token
go only into the request body and the mode-600 file, never onto a command line or into any output.

Environment: KANBAN_BOARD_URL (the board as the agent reaches it: loopback or a single-label docker network name, as
kanban-sync.py allows), KANBAN_AUTH_FILE (default /wd/kanban/kanban.env: SELF_HOST_LOCAL_AUTH_EMAIL and
SELF_HOST_LOCAL_AUTH_PASSWORD), VK_CREDENTIALS (the runner's credentials.json; ui-start.sh passes it), VK_SIGNIN_WAIT
(seconds, default 60).
Exit: 0 stored, 2 the board did not answer in time or failed the login, 3 the board refused the login, 4 a setting is
missing or wrong.
"""
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

BOARD = os.environ.get("KANBAN_BOARD_URL", "")
AUTH = os.environ.get("KANBAN_AUTH_FILE", "/wd/kanban/kanban.env")
CREDENTIALS = os.environ.get("VK_CREDENTIALS", "")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


# the board is called directly, never through an environment proxy, and a redirect is not followed
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


def done(code, line):
    print(f"vk-runner-signin: {line}")
    sys.exit(code)


def login(email, password):
    """The board's answer to the login: (HTTP code, JSON body), (0, None) when it does not answer."""
    req = urllib.request.Request(BOARD.rstrip("/") + "/v1/auth/local/login", method="POST",
                                 data=json.dumps({"email": email, "password": password}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with OPENER.open(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except ValueError:
            return e.code, None
    except (urllib.error.URLError, OSError, ValueError):
        return 0, None


def store(refresh_token):
    """The refresh token as the runner stores it (credentials.json: {"refresh_token": ...}), mode 600, atomically."""
    folder = os.path.dirname(CREDENTIALS)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".credentials-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"refresh_token": refresh_token}, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, CREDENTIALS)
    except BaseException:
        os.unlink(tmp)
        raise


def main():
    p = urllib.parse.urlsplit(BOARD)
    host = p.hostname or ""
    if p.scheme not in ("http", "https") or not (host in ("127.0.0.1", "localhost", "::1")
                                                or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", host)):
        done(4, f"KANBAN_BOARD_URL must be http(s):// on loopback or a single-label docker network name (the board "
                f"sidecar; the login goes there), not {BOARD!r}")
    if not CREDENTIALS.endswith("/credentials.json"):
        done(4, f"VK_CREDENTIALS must be the runner's credentials.json, not {CREDENTIALS!r}")
    try:
        wait = int(os.environ.get("VK_SIGNIN_WAIT", "60"))
    except ValueError:
        done(4, "VK_SIGNIN_WAIT must be a whole number of seconds")
    try:
        vals = dict(l.strip().split("=", 1) for l in open(AUTH) if "=" in l and not l.lstrip().startswith("#"))
    except OSError as e:
        done(4, f"cannot read the board login {AUTH}: {e.strerror}")
    email, password = vals.get("SELF_HOST_LOCAL_AUTH_EMAIL"), vals.get("SELF_HOST_LOCAL_AUTH_PASSWORD")
    if not email or not password:
        done(4, f"{AUTH} has no SELF_HOST_LOCAL_AUTH_EMAIL or SELF_HOST_LOCAL_AUTH_PASSWORD")
    deadline = time.monotonic() + wait
    while True:
        code, answer = login(email, password)
        if code and code < 500:
            break
        if time.monotonic() >= deadline:
            done(2, f"the board at {BOARD} did not answer the login within {wait}s"
                    f"{f' (last HTTP {code})' if code else ''} - the runner starts signed out")
        time.sleep(2)  # nosemgrep: arbitrary-sleep -- retry interval of a bounded wait for the board's login
    if 300 <= code < 400:
        done(2, f"the board answered the login with a redirect (HTTP {code}), not followed - the runner starts signed out")
    token = answer.get("refresh_token") if isinstance(answer, dict) else None
    if code != 200 or not isinstance(token, str) or not token:
        done(3, f"the board refused the runner's sign-in as {email} (HTTP {code}) - the runner starts signed out")
    try:
        store(token)
    except OSError as e:
        done(4, f"cannot store the runner's sign-in in {CREDENTIALS}: {e.strerror}")
    done(0, f"the runner's sign-in to the board at {BOARD} as {email} is stored in {CREDENTIALS} (it loads it when it starts)")


if __name__ == "__main__":
    main()
