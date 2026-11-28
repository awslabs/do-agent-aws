#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Offline test of slack-upload.sh against slack-upload-stub.py (127.0.0.1 only, no real Slack call) - the body of
# /test24.sh. Usage: python3 -I slack-upload-test.py [<agent dir, default /agent>] [<test-lib dir, default: this
# file's>]. Prints one "ok N - ..." line per check and "Test24 succeeded"; the first failing check prints
# "Test24 FAILED: ..." and exits 1. Each check FAILS if the property it proves is removed from the script.
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request


# The http(s) URLs this script builds itself go through one opener, with the scheme checked first: file: or any other
# scheme is refused before a request is made (the urllib default would open it)
_HTTP_OPENER = urllib.request.build_opener()


def http_open(req, timeout):
    """urllib.request.urlopen for an http or https URL (or Request) only; ValueError for any other scheme."""
    url = req.full_url if isinstance(req, urllib.request.Request) else req
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise ValueError("refusing a non-http(s) URL: %r" % (url,))
    return _HTTP_OPENER.open(req, timeout=timeout)

AGENT_DIR = sys.argv[1] if len(sys.argv) > 1 else "/agent"
LIB_DIR = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(AGENT_DIR, "slack-upload.sh")
STUB = os.path.join(LIB_DIR, "slack-upload-stub.py")
TOKEN = "xoxb-test-stub"
CHAN = "C0TESTCHAN"

D = tempfile.mkdtemp(prefix="test24-")
STATE = os.path.join(D, "state")
os.makedirs(STATE)
stub = None
outputs = []      # every stdout/stderr captured, for the no-token-leak check
N = 0


def fail(msg):
    print("Test24 FAILED: %s" % msg)
    if stub:
        stub.kill()
    sys.exit(1)


def ok(msg):
    global N
    N += 1
    print("ok %d - %s" % (N, msg), flush=True)


def get(path):
    with http_open("http://127.0.0.1:%d/api/%s" % (PORT, path), 10) as r:
        return json.loads(r.read().decode())


def state():
    return get("stub.state")


def run(args, env_over=None, record=None):
    env = {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
           "SLACK_API_BASE": "http://127.0.0.1:%d/api" % PORT, "SLACK_DIR": STATE, "SLACK_CHANNELS": CHAN,
           "SLACK_BOT_TOKEN": TOKEN, "SLACK_POST_ENABLED": "auto"}
    if os.environ.get("NODE_BIN"):
        env["NODE_BIN"] = os.environ["NODE_BIN"]
    env.update(env_over or {})
    env = {k: v for k, v in env.items() if v is not None}
    if record:
        env["SLACK_POST_RECORD"] = record
        if os.path.exists(record):
            os.unlink(record)
    p = subprocess.run(["bash", SCRIPT, *args], env=env, capture_output=True, text=True, timeout=180)
    outputs.append(p.stdout + p.stderr)
    return p.returncode, p.stdout, p.stderr


def record_lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [ln.rstrip("\n") for ln in f if ln.strip()]


def posted_lines():
    p = os.path.join(STATE, "posted.jsonl")
    if not os.path.exists(p):
        return []
    with open(p) as f:
        return [json.loads(ln) for ln in f if ln.strip()]


def file_msg(fid, msgs):
    return next((m for m in msgs if any(f.get("id") == fid for f in m.get("files") or [])), None)


def parse_ok(stdout):
    line = next((ln for ln in stdout.splitlines() if ln.startswith("Uploaded and read-back verified:")), None)
    if not line:
        return None
    kv = dict(w.split("=", 1) for w in line.split(" ") if "=" in w)
    return kv


# --- 1. syntax ---
if not os.path.isfile(SCRIPT):
    fail("%s is missing" % SCRIPT)
p = subprocess.run(["bash", "-n", SCRIPT], capture_output=True, text=True)
if p.returncode != 0:
    fail("bash -n %s: %s" % (SCRIPT, p.stderr))
ok("bash -n %s" % SCRIPT)

# --- 2. the stub ---
stub = subprocess.Popen([sys.executable, "-I", STUB], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)  # nosemgrep: dangerous-subprocess-use-audit, dangerous-subprocess-use-tainted-env-args -- test harness argv run without a shell
PORT = None
SEED = {}
deadline = time.time() + 20
while time.time() < deadline:
    line = stub.stdout.readline()
    if not line:
        break
    if line.startswith("SEED"):
        SEED = dict(w.split("=", 1) for w in line.split()[1:])
    if line.startswith("LISTENING"):
        PORT = int(line.split()[1])
        break
if not PORT or "m2" not in SEED:
    fail("the stub did not start (port %r, seed %r)" % (PORT, SEED))
M2 = SEED["m2"]
ok("stub Slack API on 127.0.0.1:%d, thread parent %s" % (PORT, M2))

# the file: 200 KB, a PNG signature then random bytes
PNG = os.path.join(D, "chart.png")
data = b"\x89PNG\r\n\x1a\n" + os.urandom(200 * 1024 - 8)
with open(PNG, "wb") as f:
    f.write(data)
SHA = hashlib.sha256(data).hexdigest()
SIZE = len(data)
EMPTY = os.path.join(D, "empty.png")
open(EMPTY, "wb").close()
REC = os.path.join(D, "record")
COMMENT = "the sweep chart c=1..128 <https://example.com/chart|chart> & notes"


def no_calls(before, after, what):
    for k in ("getUrl", "upload", "complete"):
        if before[k] != after[k]:
            fail("%s: the stub saw a %s call (%d -> %d) although nothing may be sent" % (what, k, before[k], after[k]))


# --- 3. the post gate off: no call ---
c0 = state()["calls"]
rc, out, err = run([CHAN, PNG, M2, COMMENT], {"SLACK_POST_ENABLED": "false"}, REC)
if rc != 1 or "post gate is off" not in err:
    fail("gate off: rc %d, stderr %r" % (rc, err))
no_calls(c0, state()["calls"], "gate off")
if record_lines(REC):
    fail("gate off: the record is not empty: %r" % record_lines(REC))
ok("SLACK_POST_ENABLED=false refuses (exit 1, 'post gate is off'), no API call, nothing recorded")

# --- 4. a channel outside SLACK_CHANNELS: no call ---
rc, out, err = run(["C0OTHER", PNG, M2, COMMENT], None, REC)
if rc != 1 or "not in SLACK_CHANNELS" not in err:
    fail("other channel: rc %d, stderr %r" % (rc, err))
no_calls(c0, state()["calls"], "other channel")
ok("a channel outside SLACK_CHANNELS refuses (exit 1), no API call")

# --- 5. a missing file, 6. an empty file, 7. a bad thread_ts, 8. no token: no call ---
rc, out, err = run([CHAN, os.path.join(D, "nothing.png"), M2, COMMENT], None, REC)
if rc != 1 or "does not exist or is not readable" not in err:
    fail("missing file: rc %d, stderr %r" % (rc, err))
no_calls(c0, state()["calls"], "missing file")
ok("a missing file refuses (exit 1), no API call")
rc, out, err = run([CHAN, EMPTY, M2, COMMENT], None, REC)
if rc != 1 or "is empty" not in err:
    fail("empty file: rc %d, stderr %r" % (rc, err))
no_calls(c0, state()["calls"], "empty file")
ok("an empty file refuses (exit 1), no API call")
rc, out, err = run([CHAN, PNG, "not-a-ts", COMMENT], None, REC)
if rc != 1 or "not a Slack message ts" not in err:
    fail("bad thread_ts: rc %d, stderr %r" % (rc, err))
no_calls(c0, state()["calls"], "bad thread_ts")
ok("a thread_ts that is not digits.digits refuses (exit 1), no API call")
rc, out, err = run([CHAN, PNG, M2, COMMENT], {"SLACK_BOT_TOKEN": "", "SLACK_POST_ENABLED": "true"}, REC)
if rc != 1 or "SLACK_BOT_TOKEN is empty" not in err:
    fail("no token: rc %d, stderr %r" % (rc, err))
no_calls(c0, state()["calls"], "no token")
ok("an empty SLACK_BOT_TOKEN with the gate forced on refuses (exit 1), no API call")

# --- 9. the happy path into a thread ---
rc, out, err = run([CHAN, PNG, M2, COMMENT], None, REC)
if rc != 0:
    fail("thread upload: rc %d, stdout %r, stderr %r" % (rc, out, err))
kv = parse_ok(out)
if not kv or kv.get("channel") != CHAN or kv.get("thread_ts") != M2 or not kv.get("file_id") or kv.get("filename") != "chart.png" or kv.get("bytes") != str(SIZE):
    fail("thread upload: the success line is wrong: %r" % out)
FID = kv["file_id"]
TS1 = kv["ts"]
st = state()
up = next((u for u in st["uploads"] if u["id"] == FID), None)
if not up or up["length"] != SIZE or up["declared_length"] != SIZE or up["sha256"] != SHA or up["filename"] != "chart.png" or not up["completed"]:
    fail("thread upload: the stub's upload record differs from the file: %r (size %d sha256 %s)" % (up, SIZE, SHA))
m = file_msg(FID, st["messages"])
if not m or m["ts"] != TS1 or m.get("thread_ts") != M2 or m.get("text") != COMMENT or m.get("user") != "U0STUB":
    fail("thread upload: the file message is wrong: %r" % m)
if st["calls"]["getUrl"] != c0["getUrl"] + 1 or st["calls"]["upload"] != c0["upload"] + 1 or st["calls"]["complete"] != c0["complete"] + 1:
    fail("thread upload: call counts %r vs before %r (expected exactly one of each)" % (st["calls"], c0))
pl = posted_lines()
if not pl or pl[-1] != {"ts": TS1, "channel": CHAN, "thread_ts": M2, "file_id": FID, "filename": "chart.png", "text": COMMENT[:200]}:
    fail("thread upload: posted.jsonl last line %r" % (pl[-1] if pl else None))
if record_lines(REC) != [TS1]:
    fail("thread upload: SLACK_POST_RECORD should hold exactly the ts, holds %r" % record_lines(REC))
reg = os.path.join(STATE, "threads-" + CHAN)
if not os.path.exists(reg) or not any(ln.split()[0] == M2 for ln in open(reg) if ln.strip()):
    fail("thread upload: the thread %s is not in the watcher's registry %s" % (M2, reg))
ok("a 200 KB PNG shared into a thread: exit 0, the bytes and sha256 the stub received equal the file's, the file message (files[].id, comment, thread_ts) is in conversations.replies, the success line names channel/ts/thread_ts/file_id, posted.jsonl has the line, SLACK_POST_RECORD holds the ts alone, the thread is registered")

# --- 10. the happy path into the channel ---
c1 = state()["calls"]
rc, out, err = run([CHAN, PNG, "", "chart in the channel"], None, REC)
if rc != 0:
    fail("channel upload: rc %d, stdout %r, stderr %r" % (rc, out, err))
kv = parse_ok(out)
if not kv or "thread_ts" in kv or not kv.get("file_id"):
    fail("channel upload: the success line is wrong: %r" % out)
FID2 = kv["file_id"]
TS2 = kv["ts"]
st = state()
m = file_msg(FID2, st["messages"])
if not m or m.get("thread_ts") or m["ts"] != TS2 or m.get("text") != "chart in the channel":
    fail("channel upload: the file message is wrong: %r" % m)
if st["calls"]["history"] <= c1["history"]:
    fail("channel upload: the read-back did not use conversations.history")
pl = posted_lines()
if pl[-1] != {"ts": TS2, "channel": CHAN, "file_id": FID2, "filename": "chart.png", "text": "chart in the channel"}:
    fail("channel upload: posted.jsonl last line %r" % pl[-1])
ans = os.path.join(STATE, "answers-" + CHAN)
if not os.path.exists(ans) or not any(ln.split()[0] == TS2 for ln in open(ans) if ln.strip()):
    fail("channel upload: the share %s is not in %s (watch_answer)" % (TS2, ans))
if record_lines(REC) != [TS2]:
    fail("channel upload: SLACK_POST_RECORD %r" % record_lines(REC))
ok("the same PNG shared in the channel (thread_ts \"\"): exit 0, read back through conversations.history, the top-level file message carries the comment, watched for a threaded answer, posted.jsonl line without thread_ts")

# --- 11. missing_scope at step 1: nothing uploaded, the reinstall step named ---
c2 = state()["calls"]
n_up = len(state()["uploads"])
get("stub.failGetUrl?error=missing_scope&needed=files:write")
rc, out, err = run([CHAN, PNG, M2, COMMENT], None, REC)
if rc != 1 or "missing_scope" not in err or "files:write" not in err or "reinstall" not in err:
    fail("missing_scope: rc %d, stderr %r" % (rc, err))
st = state()
if len(st["uploads"]) != n_up or st["calls"]["upload"] != c2["upload"] or st["calls"]["complete"] != c2["complete"]:
    fail("missing_scope: bytes or a complete call went out: uploads %d -> %d, calls %r -> %r" % (n_up, len(st["uploads"]), c2, st["calls"]))
if record_lines(REC):
    fail("missing_scope: the record is not empty: %r" % record_lines(REC))
ok("files.getUploadURLExternal ok:false missing_scope: exit 1 naming files:write and the reinstall step, no bytes sent, nothing recorded")

# --- 12. the bytes refused (HTTP 500): nothing shared ---
c3 = state()["calls"]
get("stub.failUpload?code=500")
rc, out, err = run([CHAN, PNG, M2, COMMENT], None, REC)
if rc != 1 or "HTTP 500" not in err or "retry is safe" not in err:
    fail("upload 500: rc %d, stderr %r" % (rc, err))
st = state()
if st["calls"]["complete"] != c3["complete"]:
    fail("upload 500: files.completeUploadExternal was called after a failed upload")
if record_lines(REC):
    fail("upload 500: the record is not empty: %r" % record_lines(REC))
ok("the upload URL answering HTTP 500: exit 1 ('retry is safe'), no completeUploadExternal call, nothing recorded")

# --- 13. completeUploadExternal ok:false: nothing shared ---
n_msgs = len(state()["messages"])
get("stub.failComplete?mode=error")
rc, out, err = run([CHAN, PNG, M2, COMMENT], None, REC)
if rc != 1 or "files.completeUploadExternal failed" not in err or "upload_failed" not in err:
    fail("complete error: rc %d, stderr %r" % (rc, err))
if len(state()["messages"]) != n_msgs:
    fail("complete error: a message was posted")
if record_lines(REC):
    fail("complete error: the record is not empty: %r" % record_lines(REC))
ok("files.completeUploadExternal ok:false: exit 1, no message, nothing recorded")

# --- 14. landed but not found: exit 4, 'unknown' recorded ---
get("stub.failComplete?mode=hide")
t0 = time.time()
rc, out, err = run([CHAN, PNG, M2, COMMENT], None, REC)
dt = time.time() - t0
if rc != 4 or "do not upload this file again (exit 4)" not in err or "read-back could not find" not in err:
    fail("hidden message: rc %d, stderr %r" % (rc, err))
if record_lines(REC) != ["unknown"]:
    fail("hidden message: SLACK_POST_RECORD should hold 'unknown', holds %r" % record_lines(REC))
if dt < 6:
    fail("hidden message: the read-back gave up after %.1f s - the three reads (0, 2, 5 s) were not all made" % dt)
ok("ok:true from completeUploadExternal but no file message found after three reads (%.0f s): exit 4 'do not upload this file again', 'unknown' in SLACK_POST_RECORD" % dt)

# --- 15. the response to completeUploadExternal lost: exit 5, 'unknown' recorded, the message IS there ---
n_msgs = len(state()["messages"])
get("stub.failComplete?mode=drop")
rc, out, err = run([CHAN, PNG, M2, COMMENT], None, REC)
if rc != 5 or "whether the file message landed is unknown" not in err or "(exit 5)" not in err:
    fail("dropped response: rc %d, stderr %r" % (rc, err))
if record_lines(REC) != ["unknown"]:
    fail("dropped response: SLACK_POST_RECORD %r" % record_lines(REC))
if len(state()["messages"]) != n_msgs + 1:
    fail("dropped response: the stub should hold the landed message")
ok("the connection closed without a response after completeUploadExternal: exit 5, 'unknown' recorded, the file message is on the platform")

# --- 16. HTTP 429 once on step 1, 17. once on step 3: honored once, then success ---
c4 = state()["calls"]
get("stub.ratelimit?method=getUrl&n=1")
rc, out, err = run([CHAN, PNG, M2, "after a 429 on step 1"], None, REC)
if rc != 0 or "rate limited files.getUploadURLExternal" not in out:
    fail("429 on getUploadURLExternal: rc %d, stdout %r, stderr %r" % (rc, out, err))
st = state()
if st["calls"]["getUrl"] != c4["getUrl"] + 2 or st["calls"]["upload"] != c4["upload"] + 1:
    fail("429 on getUploadURLExternal: calls %r vs %r (expected 2 getUrl, 1 upload)" % (st["calls"], c4))
if os.path.exists(os.path.join(STATE, "retry-after")):
    fail("429 on getUploadURLExternal: retry-after was left behind after the honored retry")
ok("HTTP 429 on files.getUploadURLExternal: honored once (Retry-After 1 s), the second call succeeds, exit 0, retry-after cleared")
c5 = state()["calls"]
n_msgs = len(state()["messages"])
get("stub.ratelimit?method=complete&n=1")
rc, out, err = run([CHAN, PNG, M2, "after a 429 on step 3"], None, REC)
if rc != 0 or "rate limited files.completeUploadExternal" not in out:
    fail("429 on completeUploadExternal: rc %d, stdout %r, stderr %r" % (rc, out, err))
st = state()
if st["calls"]["complete"] != c5["complete"] + 2 or len(st["messages"]) != n_msgs + 1:
    fail("429 on completeUploadExternal: calls %r vs %r, messages %d -> %d (expected 2 calls, 1 message)" % (st["calls"], c5, n_msgs, len(st["messages"])))
kv = parse_ok(out)
if record_lines(REC) != [kv["ts"]]:
    fail("429 on completeUploadExternal: SLACK_POST_RECORD %r" % record_lines(REC))
ok("HTTP 429 on files.completeUploadExternal: honored once, one message posted, exit 0, the record holds the ts alone")

# --- 18. an upload_url on another origin: refused before a byte is sent ---
c6 = state()["calls"]
get("stub.evilUrl")
rc, out, err = run([CHAN, PNG, M2, COMMENT], None, REC)
if rc != 1 or "refusing to upload" not in err or "no byte sent" not in err:
    fail("evil upload_url: rc %d, stderr %r" % (rc, err))
st = state()
if st["calls"]["upload"] != c6["upload"] or st["calls"]["complete"] != c6["complete"]:
    fail("evil upload_url: bytes or a complete call went out: %r vs %r" % (st["calls"], c6))
ok("an upload_url that is neither *.slack.com over https nor the origin of SLACK_API_BASE: exit 1 before any byte is sent")

# --- 19. the token is in no output ---
if any(TOKEN in o for o in outputs):
    fail("the bot token appeared in the script's output")
ok("the bot token appears in none of the %d runs' stdout/stderr" % len(outputs))

stub.kill()
print("Test24 succeeded (%d checks, stub state dir %s)" % (N, D))
