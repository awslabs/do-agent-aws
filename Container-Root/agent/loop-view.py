#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The Agent loop page: the autonomy loop (/agent/loop.sh) at a glance, for the harness home page.

Started by /agent/ui-start.sh (UI_LOOP=true, the default) as the loop-view UI. Every LOOP_VIEW_INTERVAL seconds it reads
the loop's state files and writes, atomically (a temp file, then a rename), ${UI_DIR}/loop/data.json and the page that
renders it (index.html, fire.html, app.js and style.css, from /agent/loop-view/); it serves that directory and the fire
transcripts on 127.0.0.1:UI_PORT_LOOP. The home proxy is the exposure: host route loop.localhost, and the tile's dot
probe /__probe/loop is this server's /health.

Read-only over the loop: the renderer never writes the loop's directory and never takes its lock (loop.sh and
loop-start.sh test it with flock -n, so a reader holding it for an instant could turn a start away as "already
running"). The one exception is the page's Control section: POST /control/run and /control/pause run the loop's own
loop-start.sh and loop-stop.sh and answer with the loop's state read back afterwards (control() below;
UI_LOOP_CONTROL=false turns them off). The data, the page and /health stay GET only. What it reads:
  loop.lock, loop.state  the hub: running (a loop.sh or loop-once.sh process holds the lock - /proc/<pid>/fdinfo names
                        the flock on the holding file description; /proc/locks hides it inside a container), stopped,
                        stale (the state line claims a phase no process backs, or only a non-loop process holds the
                        lock) or not started; the STOP flag; the phase
  loop.log              the running loop's interval, timeout and goals (its LOOP START line, not this process's
                        environment); every fire: begin, end, duration, rc, the goals it fired on, and fires with a
                        BEGIN and no END (loop-stop.sh --now, a crash); a fire's bus inbox (its INBOX lines: the ids it
                        was handed, then its record - the ids it read, the replies they got, the ones it left open and
                        what the loop did with them - the ones set aside, and the intake's warnings); the 24 h strip
  fires/fire-N.out      each fire's transcript (served as text/plain, never as HTML) and its first line as a summary
  notes.md, the goals   the progress notes' tail; goals open and done (the checkbox lines agent-status.sh counts)
  Claude Code sessions  each fire's own session under CLAUDE_CONFIG_DIR/projects (its first prompt is the fire prompt
                        and it starts inside the fire): the sub-agents it spawned (Task/Agent tool uses), done once
                        their result is in
  tmux list-sessions    the agent's terminal sessions with their lineage (@agent_parent) and the loop's own sessions
                        (/agent/loop-lineage.sh), on the default tmux server - the one the agent session lives on
  ui-status.sh & co.    the sidecar services' probe state, every LOOP_VIEW_SERVICES_INTERVAL seconds
Health follows one legend: GREEN - the last fire (or, idle with nothing to fire against, the last cycle) within 2x the
interval (at least 10 min), or a fire running inside its timeout; STALE - within 6x (at least 30 min); RED - beyond
that, a fire running past its timeout, a lock no loop process holds, a state line no loop process backs, or a loop
that stopped after a failed or timed-out fire. A loop that is not running is otherwise not a fault: COMPLETE when every
goal is done (it stopped on the STOP flag its last fire set), STOPPED when it was stopped or never started - the goals
it left open stay under needs attention. The page always shows the word next to the colour.

/health answers 200 while the last successful write is at most LOOP_VIEW_STALE_SECS old and 503 otherwise, so the home
page's dot and ui-status.sh read down for a stopped renderer AND for one that stopped writing.

Usage: loop-view.py [--port N] [--once]   (--once: render once and exit)
Settings (environment):
  UI_PORT_LOOP                 the port on 127.0.0.1 (default 7790)
  UI_DIR                       the UI state directory; the page goes to ${UI_DIR}/loop (default /wd/ui)
  LOOP_VIEW_INTERVAL           seconds between renders (default 5)
  LOOP_VIEW_STALE_SECS         data age at which /health answers 503 (default 6 renders, at least 30 s)
  LOOP_VIEW_FIRES              fires listed (default 50)
  LOOP_VIEW_SERVICES_INTERVAL  seconds between service probes (default 30)
  AUTONOMY_LOOP_DIR, AUTONOMY_LOOP_GOALS, AUTONOMY_LOOP_INTERVAL, AUTONOMY_LOOP_FIRE_TIMEOUT, AUTONOMY_LOOP_WORKDIR
                               the loop's settings with loop.sh's defaults (the running loop's LOOP START line wins)
  AUTONOMY_LOOP_TMUX_SESSION   the loop's tmux session (default ${AGENT_TMUX_SESSION_NAME:-agent}-loop, as
                               /agent/loop-lineage.sh names it)
  CLAUDE_CONFIG_DIR            where Claude Code keeps its sessions (default ~/.claude)
"""
import argparse
import calendar
import html
import http.client
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote


def _num(name, default, kind=int):
    try:
        return kind(os.environ.get(name, "") or default)
    except ValueError:
        return default


E = os.environ
LOOP_DIR = E.get("AUTONOMY_LOOP_DIR", "/wd/loop")
GOALS_FILE = E.get("AUTONOMY_LOOP_GOALS", "/wd/goals/GOALS.md")
ENV_INTERVAL = _num("AUTONOMY_LOOP_INTERVAL", 300)
ENV_TIMEOUT = _num("AUTONOMY_LOOP_FIRE_TIMEOUT", 1500)
ENV_WORKDIR = E.get("AUTONOMY_LOOP_WORKDIR", "/wd")
OUT_DIR = os.path.join(E.get("UI_DIR", "/wd/ui"), "loop")
PORT = _num("UI_PORT_LOOP", 7790)
INTERVAL = max(1.0, _num("LOOP_VIEW_INTERVAL", 5, float))
STALE_AFTER = _num("LOOP_VIEW_STALE_SECS", max(30.0, 6 * INTERVAL), float)
N_FIRES = max(1, _num("LOOP_VIEW_FIRES", 50))
SERVICES_EVERY = max(5.0, _num("LOOP_VIEW_SERVICES_INTERVAL", 30, float))
AGENT_DIR = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(AGENT_DIR, "loop-view")
CLAUDE_DIR = E.get("CLAUDE_CONFIG_DIR") or os.path.join(E.get("HOME", "/home/agent"), ".claude")
LOOP_SESSION = E.get("AUTONOMY_LOOP_TMUX_SESSION") or (E.get("AGENT_TMUX_SESSION_NAME") or "agent") + "-loop"
FIRE_PROMPT = "You are one fire of the do-agent-aws autonomy loop"
DAY = 86400
SLOT = 1800
SLOTS = 48

LINE_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (.*)$")
START_RE = re.compile(r"^LOOP START interval=(\d+)s goals=(.*) fire_timeout=(\d+)s workdir=(.*)$")
BEGIN_RE = re.compile(r"^FIRE (\d+) BEGIN( \(once\))? goals=(.*?)( \(default: .*\))?$")
END_RE = re.compile(r"^FIRE (\d+) END rc=(-?\d+) duration=(\d+)s")
# a fire's bus inbox (loop.sh "Bus intake", loop-inbox.sh): "FIRE N INBOX context: ...: <ids>" or "... not read: ..."
# before it; after END its record ("read=..."), then "set aside: <id>, ..." and "WARNING ..." lines
INBOX_RE = re.compile(r"^FIRE (\d+) INBOX (context: |read=|set aside: |not read: |WARNING )")
INBOX_RECORD_RE = re.compile(r"^FIRE \d+ INBOX read=(\S+) replies=(\S+) open=([^;\s]+);? ?(.*)$")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
LOOP_CMD_RE = re.compile(r"(^|[/\s])loop(-once)?\.sh(\s|$)")


def epoch(ts):
    return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))


def iso(t):
    return None if t is None else time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def iso_epoch(ts):
    """2026-10-13T12:00:05.123Z (a Claude Code session timestamp) as epoch seconds; None when unreadable."""
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) + float("0" + ts[19:].rstrip("Z"))
    except (TypeError, ValueError):
        return None


def read_text(path, limit=1 << 20):
    try:
        with open(path, "rb") as f:
            return f.read(limit).decode("utf-8", "replace")
    except OSError:
        return None


def cmdline(pid):
    try:
        with open("/proc/%s/cmdline" % pid, "rb") as f:
            return f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
    except OSError:
        return ""


class LoopLog:
    """loop.log, parsed incrementally: only the bytes appended since the last read (the file is append-only; a smaller
    file or another inode starts over). Keeps every fire and the timestamps of the last 26 h of lines (the strip)."""

    def __init__(self, path):
        self.path = path
        self.reset(None)

    def reset(self, ino):
        self.ino, self.offset, self.partial = ino, 0, b""
        self.fires, self.open, self.start, self.seen, self.last_line = [], None, None, [], ""

    def refresh(self):
        try:
            st = os.stat(self.path)
        except OSError:
            self.reset(None)
            return
        if st.st_ino != self.ino or st.st_size < self.offset:
            self.reset(st.st_ino)
        if st.st_size == self.offset:
            return
        with open(self.path, "rb") as f:
            f.seek(self.offset)
            chunk = f.read(min(st.st_size - self.offset, 16 << 20))
        self.offset += len(chunk)
        lines = (self.partial + chunk).split(b"\n")
        self.partial = lines.pop()
        for raw in lines:
            self.ingest(raw.decode("utf-8", "replace"))
        cut = time.time() - DAY - 2 * SLOT
        if self.seen and self.seen[0] < cut:
            self.seen = [t for t in self.seen if t >= cut]

    def interrupt(self, why):
        if self.open:
            self.open.update(status="interrupted", why=why)
            self.open = None

    def ingest(self, line):
        m = LINE_RE.match(line)
        if not m:
            return
        t, msg = epoch(m.group(1)), m.group(2)
        self.seen.append(t)
        self.last_line = line
        s, b, e = START_RE.match(msg), BEGIN_RE.match(msg), END_RE.match(msg)
        if s:
            self.interrupt("the loop restarted before this fire logged its END")
            self.start = {"at": t, "interval_s": int(s.group(1)), "goals": s.group(2), "timeout_s": int(s.group(3)),
                          "workdir": s.group(4)}
        elif b:
            self.interrupt("another fire began before this one logged its END")
            self.open = {"n": int(b.group(1)), "begin": t, "end": None, "duration_s": None, "rc": None,
                         "status": "running", "goals": b.group(3), "goals_mode": "default" if b.group(4) else "user",
                         "once": bool(b.group(2)), "timeout_s": (self.start or {}).get("timeout_s", ENV_TIMEOUT)}
            self.fires.append(self.open)
        elif e:
            n, rc, dur = int(e.group(1)), int(e.group(2)), int(e.group(3))
            f = self.open if self.open and self.open["n"] == n else None
            if f is None:
                # an END whose BEGIN this log does not have (written before the log was truncated)
                self.interrupt("another fire ended before this one logged its END")
                f = {"n": n, "begin": t - dur, "goals": None, "goals_mode": None, "once": False,
                     "timeout_s": (self.start or {}).get("timeout_s", ENV_TIMEOUT)}
                self.fires.append(f)
            f.update(end=t, rc=rc, duration_s=dur)
            f["status"] = "ok" if rc == 0 else "timeout" if rc == 124 or dur >= f["timeout_s"] else "failed"
            self.open = None
        elif INBOX_RE.match(msg):
            self.inbox(int(INBOX_RE.match(msg).group(1)), msg)
        elif msg.startswith("LOOP EXIT"):
            self.interrupt("the loop was terminated during this fire (signal)")

    def inbox(self, n, msg):
        """A fire's bus inbox: the ids its context line names (handed, before it ran), its record after END (the ids it
        read, the replies they got, the ones still open, and what the loop did with those), the ids the loop set aside
        after it, and the intake's warnings (a poll that failed, a receipt refused, a count not written). A fire with a
        context line and no record did not reach its end: what it was handed stayed open."""
        f = next((x for x in reversed(self.fires) if x["n"] == n), None)
        if f is None:
            return
        ib = f.setdefault("inbox", {"handed": [], "read": [], "replies": [], "open": [], "set_aside": [], "warnings": [],
                                    "note": None})
        m = INBOX_RECORD_RE.match(msg)
        if m:
            ib.update(read=UUID_RE.findall(m.group(1)), replies=UUID_RE.findall(m.group(2)),
                      open=UUID_RE.findall(m.group(3)), note=clip(m.group(4), 1200) or None)
        elif " INBOX set aside: " in msg:
            ib["set_aside"] += UUID_RE.findall(msg)[:1]
        elif " INBOX not read: " in msg or " INBOX WARNING " in msg:
            ib["warnings"].append(clip(msg.split(" INBOX ", 1)[1], 300))
        else:
            ib["handed"] = UUID_RE.findall(msg)


def lock_holders(path):
    """Every process whose open file description holds the flock on <path> (loop.sh takes it on fd 9 and its children
    inherit the fd: timeout, claude). Read from /proc/<pid>/fdinfo/<fd>, whose lock: line names a flock on that file
    description - the lock is never taken here. None when there is no lock file."""
    try:
        want = os.stat(path)
    except OSError:
        return None
    out = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            fds = os.listdir("/proc/%s/fd" % pid)
        except OSError:
            continue
        for fd in fds:
            try:
                st = os.stat("/proc/%s/fd/%s" % (pid, fd))
            except OSError:
                continue
            if st.st_ino != want.st_ino or st.st_dev != want.st_dev:
                continue
            info = read_text("/proc/%s/fdinfo/%s" % (pid, fd), 4096) or ""
            if "FLOCK" in info:
                out.append({"pid": int(pid), "cmd": cmdline(pid)[:200]})
                break
    return out


def clip(text, width):
    """text cut to width characters, its last one an ellipsis when anything was cut (a cut never reads as whole)"""
    return text if len(text) <= width else text[:width - 1] + "\u2026"


def goals_summary(path, stop_flag):
    """Goals open and done, counted the way /agent/agent-status.sh counts them: unchecked and checked checkbox lines.
    A file of '## Goal ...' sections without checkboxes has nothing to count; its sections are listed as open until
    the agent's own STOP flag says every goal is complete."""
    text = read_text(path)
    if text is None:
        return {"file": path, "exists": False, "open": 0, "done": 0, "headings": 0, "mode": "none", "items": []}
    open_items = re.findall(r"(?m)^[ \t]*[-*] \[ \] (.*)$", text)
    done_items = re.findall(r"(?m)^[ \t]*[-*] \[[xX]\] (.*)$", text)
    headings = re.findall(r"(?m)^## (.*)$", text)
    sections = [h.strip() for h in headings if re.match(r"(?i)goal\b", h) and not re.match(r"(?i)goals from ", h)]
    if open_items or done_items:
        mode, n_open, n_done = "checkboxes", len(open_items), len(done_items)
        items = [{"text": clip(i.strip(), 300), "done": False} for i in open_items[:30]]
        items += [{"text": clip(i.strip(), 300), "done": True} for i in done_items[:15]]
    elif sections:
        mode = "sections"
        n_open, n_done = (0, len(sections)) if stop_flag else (len(sections), 0)
        items = [{"text": clip(s, 300), "done": stop_flag} for s in sections[:30]]
    else:
        mode, n_open, n_done, items = "none", 0, 0, []
    return {"file": path, "exists": True, "open": n_open, "done": n_done, "headings": len(headings), "mode": mode,
            "items": items}


def tail_lines(path, n, width=300):
    text = read_text(path, 1 << 22)
    if not text:
        return []
    return [clip(l, width) for l in text.splitlines() if l.strip()][-n:]


_summaries = {}


def transcript_info(n):
    """(path, bytes, first non-empty line) of fires/fire-<n>.out, cached by size and mtime."""
    path = os.path.join(LOOP_DIR, "fires", "fire-%d.out" % n)
    try:
        st = os.stat(path)
    except OSError:
        return None, 0, None
    key = (st.st_size, st.st_mtime)
    hit = _summaries.get(path)
    if hit and hit[0] == key:
        return path, st.st_size, hit[1]
    head = read_text(path, 8192) or ""
    first = next((l.strip() for l in head.splitlines() if l.strip()), None)
    first = clip(first, 200) if first else None
    _summaries[path] = (key, first)
    return path, st.st_size, first


def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
    return ""


class Sessions:
    """The fires' own Claude Code sessions (CLAUDE_CONFIG_DIR/projects/<the workdir, '-' for every character that is
    not a letter or a digit>/*.jsonl), parsed incrementally. A file is a fire's when its first user prompt is the fire
    prompt; every other session (the interactive agent's, the Slack chat responder's) is skipped after its first
    prompt and never read again. A fire session's Task/Agent tool uses are its sub-agents."""

    def __init__(self):
        self.files = {}

    def refresh(self, workdir, since):
        d = os.path.join(CLAUDE_DIR, "projects", re.sub(r"[^A-Za-z0-9]", "-", workdir or ENV_WORKDIR))
        try:
            names = [n for n in os.listdir(d) if n.endswith(".jsonl")]
        except OSError:
            return
        budget = 8 << 20
        for name in names:
            path = os.path.join(d, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if st.st_mtime < since:
                continue
            rec = self.files.get(path)
            if rec is None or rec["ino"] != st.st_ino or st.st_size < rec["offset"]:
                rec = self.files[path] = {"ino": st.st_ino, "offset": 0, "partial": b"", "kind": None, "first": None,
                                          "id": name[:-6], "agents": {}, "order": []}
            if rec["kind"] == "other" or st.st_size == rec["offset"] or budget <= 0:
                continue
            with open(path, "rb") as f:
                f.seek(rec["offset"])
                chunk = f.read(min(st.st_size - rec["offset"], budget))
            budget -= len(chunk)
            rec["offset"] += len(chunk)
            lines = (rec["partial"] + chunk).split(b"\n")
            rec["partial"] = lines.pop()
            for raw in lines:
                if rec["kind"] == "other":
                    break
                try:
                    e = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(e, dict):
                    self.ingest(rec, e)
        cut = time.time() - 3 * DAY
        for path in [p for p, r in self.files.items() if (r["first"] or time.time()) < cut]:
            del self.files[path]

    @staticmethod
    def ingest(rec, e):
        if rec["first"] is None and e.get("timestamp"):
            rec["first"] = iso_epoch(e["timestamp"])
        msg = e.get("message") if isinstance(e.get("message"), dict) else {}
        if rec["kind"] is None:
            if e.get("type") == "user" and not e.get("isMeta"):
                text = _text_of(msg.get("content")).lstrip()
                if text:
                    rec["kind"] = "fire" if text.startswith(FIRE_PROMPT) else "other"
            return
        for c in msg.get("content") or []:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use" and c.get("name") in ("Task", "Agent"):
                inp = c.get("input") if isinstance(c.get("input"), dict) else {}
                rec["agents"][c.get("id")] = {"name": str(inp.get("name") or "")[:80],
                                              "type": str(inp.get("subagent_type") or "general-purpose")[:80],
                                              "description": str(inp.get("description") or "")[:200],
                                              "at": iso_epoch(e.get("timestamp")), "done": False}
                rec["order"].append(c.get("id"))
            elif c.get("type") == "tool_result" and c.get("tool_use_id") in rec["agents"]:
                rec["agents"][c["tool_use_id"]]["done"] = True

    def match(self, fires, now):
        """Each fire's session: the earliest fire session that started inside the fire (15 s slack either side)."""
        taken = set()
        found = sorted((r["first"], p) for p, r in self.files.items() if r["kind"] == "fire" and r["first"])
        for f in sorted(fires, key=lambda x: x["begin"]):
            hi = (f.get("end") or now) + 15
            for first, path in found:
                if path not in taken and f["begin"] - 15 <= first <= hi:
                    taken.add(path)
                    rec = self.files[path]
                    f["session"] = rec["id"]
                    f["subagents"] = [dict(rec["agents"][i], at=iso(rec["agents"][i]["at"])) for i in rec["order"]]
                    break


TMUX_FMT = "\t".join(["#{session_name}", "#{session_attached}", "#{session_windows}", "#{session_created}",
                      "#{@agent_parent}", "#{@agent_role}", "#{@agent_task}", "#{pane_current_command}"])


def tmux_sessions():
    """The default tmux server's sessions with their lineage options; never starts a server."""
    try:
        r = subprocess.run(["tmux", "list-sessions", "-F", TMUX_FMT], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"reachable": False, "error": str(e)[:200], "sessions": []}
    if r.returncode != 0:
        return {"reachable": False, "error": (r.stderr.strip().splitlines() or ["tmux exited %d" % r.returncode])[0][:200],
                "sessions": []}
    out = []
    for line in r.stdout.splitlines():
        f = (line.split("\t") + [""] * 8)[:8]
        out.append({"name": f[0], "attached": int(f[1] or 0), "windows": int(f[2] or 1), "created": int(f[3] or 0),
                    "parent": f[4] or None, "role": f[5] or None, "task": f[6] or None, "command": f[7] or None})
    return {"reachable": True, "error": None, "sessions": out}


SERVICE_LABELS = {
    "headlamp": "Headlamp (Kubernetes dashboard)", "hindsight-api": "Hindsight memory API",
    "hindsight-ui": "Hindsight memory UI", "vibe-kanban": "Kanban board (vibe-kanban)", "tmux": "Browser terminal (ttyd)",
    "home": "Home page and proxy", "home-watch": "Home route watcher", "tmux-agent": "tmux-agent dashboard",
    "claude-mem": "claude-mem viewer", "loglearner": "LogLearner dashboard", "comms-ui": "Comms UI",
    "slack-chat": "Slack chat responder",
}
STATUS_RE = re.compile(r"^([A-Za-z0-9_.-]+): (UP|DOWN|DISABLED|STARTING-OR-UNHEALTHY)\b ?(.*)$")
STATE_WORD = {"UP": "up", "DOWN": "down", "DISABLED": "off", "STARTING-OR-UNHEALTHY": "unhealthy"}


def _status_rows(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)  # nosemgrep: dangerous-subprocess-use-audit -- argv of the harness's own status scripts; no shell
    except (OSError, subprocess.TimeoutExpired) as e:
        return [], "%s: %s" % (os.path.basename(cmd[0]), str(e)[:120])
    rows = []
    for line in r.stdout.splitlines():
        m = STATUS_RE.match(line.strip())
        if m and m.group(1) != "loop-view" and m.group(1) not in [x["name"] for x in rows]:
            rows.append({"name": m.group(1), "label": SERVICE_LABELS.get(m.group(1), m.group(1)),
                         "state": STATE_WORD[m.group(2)], "detail": m.group(3)[:200]})
    return rows, None


def slack_chat():
    """The Slack chat responder from its state file and pid, the way slack-chat-status.sh reads it - without the
    brief flock that script takes (a poll every few seconds would race the responder's own single-instance check)."""
    sdir = E.get("SLACK_DIR", "/wd/slack")
    line = (read_text(os.path.join(sdir, "chat.state"), 4096) or "").strip().splitlines()
    line = line[0] if line else ""
    pid = re.search(r"\bpid=(\d+)", line)
    if pid and "slack-chat.sh" in cmdline(pid.group(1)):
        return {"name": "slack-chat", "label": SERVICE_LABELS["slack-chat"], "state": "up", "detail": line[:200]}
    gate = ""
    try:
        gate = subprocess.run(["bash", os.path.join(AGENT_DIR, "slack-gates.sh"), "chat"], capture_output=True, text=True,
                              timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    if gate != "on":
        return {"name": "slack-chat", "label": SERVICE_LABELS["slack-chat"], "state": "off",
                "detail": "the chat gate is off (no Slack token and channels, or SLACK_CHAT_ENABLED=false)"}
    return {"name": "slack-chat", "label": SERVICE_LABELS["slack-chat"], "state": "down",
            "detail": ("not running - " + line)[:200] if line else "not running (no state recorded)"}


class Services(threading.Thread):
    """The sidecar services' probe state, refreshed in the background: the rows of /agent/ui-status.sh (each UI's pid
    AND its HTTP answer), /agent/comms-ui-status.sh and the Slack chat responder."""

    def __init__(self):
        super().__init__(daemon=True)
        self.rows, self.at, self.error = None, None, None

    def probe(self):
        rows, err = _status_rows([os.path.join(AGENT_DIR, "ui-status.sh")])
        if E.get("COMMS_UI_ENABLED", "false") == "true":
            more, err2 = _status_rows([os.path.join(AGENT_DIR, "comms-ui-status.sh")])
            rows += more
            err = err or err2
        rows.append(slack_chat())
        self.rows, self.at, self.error = rows, time.time(), err

    def run(self):
        while True:
            try:
                self.probe()
            except Exception as e:  # a failed probe never stops the page; the next round retries
                self.error = "%s: %s" % (type(e).__name__, str(e)[:160])
            time.sleep(SERVICES_EVERY)


def exec_prefix():
    """How a person reaches this container to run a command: docker exec <id> (the container's hostname is its id),
    or kubectl exec <pod> in a pod."""
    host = socket.gethostname()
    if E.get("KUBERNETES_SERVICE_HOST"):
        ns = (read_text("/var/run/secrets/kubernetes.io/serviceaccount/namespace", 256) or "<namespace>").strip()
        return "kubectl -n %s exec %s -- " % (ns, host), "kubectl -n %s exec -it %s -- " % (ns, host)
    return "docker exec %s " % host, "docker exec -it %s " % host


def commands(last_fire):
    p, pi = exec_prefix()
    out = [
        {"label": "Status of the loop", "cmd": p + "/agent/loop-status.sh"},
        {"label": "Start the loop (removes a STOP flag)", "cmd": p + "/agent/loop-start.sh"},
        {"label": "Stop it before its next fire", "cmd": p + "/agent/loop-stop.sh"},
        {"label": "Stop it now, ending a fire in flight", "cmd": p + "/agent/loop-stop.sh --now"},
        {"label": "Add a goal (an outcome with a DONE condition)", "cmd": p + "/agent/goals-add.sh '<the goal>'"},
        {"label": "Run one fire in the foreground (the loop stopped)", "cmd": pi + "/agent/loop-once.sh"},
        {"label": "Loop, chat and goals in one report", "cmd": p + "/agent/agent-status.sh"},
    ]
    if last_fire:
        out.append({"label": "Print the last fire's transcript",
                    "cmd": p + "cat %s/fires/fire-%d.out" % (LOOP_DIR, last_fire["n"])})
    return out


def human(s):
    s = int(max(0, s))
    return "%ds" % s if s < 120 else "%d min" % (s // 60) if s < 7200 else "%.1f h" % (s / 3600.0)


class View:
    """One render: everything the page shows, from the files above, as one JSON document."""

    def __init__(self):
        self.log = LoopLog(os.path.join(LOOP_DIR, "loop.log"))
        self.sessions = Sessions()
        self.services = Services()
        self.last_ok, self.last_error = None, None
        self.assets = {}

    def hub(self, now, lg):
        start = lg.start or {}
        state_line = ((read_text(os.path.join(LOOP_DIR, "loop.state"), 4096) or "").strip().splitlines() or [""])[0]
        pid = re.search(r"\bpid=(\d+)", state_line)
        utc = re.search(r"\butc=(\S+)", state_line)
        phase = state_line.split(" ", 1)[0] if state_line else None
        lock = os.path.join(LOOP_DIR, "loop.lock")
        holders = lock_holders(lock) or []
        loop_holders = [h for h in holders if LOOP_CMD_RE.search(h["cmd"])]
        if holders and not loop_holders:
            # loop-start.sh and loop-status.sh hold the lock for an instant when they test it: look again
            time.sleep(0.5)  # nosemgrep: arbitrary-sleep -- a second look after an instant (the loop scripts hold the lock briefly)
            holders = lock_holders(lock) or []
            loop_holders = [h for h in holders if LOOP_CMD_RE.search(h["cmd"])]
        # a lock held by no loop process: the loop is gone, and loop-start.sh refuses to start until that process ends
        stale_lock = bool(holders) and not loop_holders
        if loop_holders:
            state = "running"
        elif stale_lock:
            state = "stale"
        elif not os.path.isdir(LOOP_DIR) or not state_line:
            state = "not started"
        elif phase == "STOPPED":
            state = "stopped"
        else:
            state = "stale"
        return {"state": state, "state_line": state_line[:300], "phase": phase if state == "running" else None,
                "pid": int(pid.group(1)) if pid else None, "state_utc": utc.group(1) if utc else None,
                "lock_holders": holders[:8], "stale_lock": stale_lock,
                "stop_flag": os.path.exists(os.path.join(LOOP_DIR, "STOP")),
                "interval_s": start.get("interval_s", ENV_INTERVAL), "fire_timeout_s": start.get("timeout_s", ENV_TIMEOUT),
                "goals": start.get("goals", GOALS_FILE), "workdir": start.get("workdir", ENV_WORKDIR),
                "started_at": iso(start.get("at")), "loop_dir": LOOP_DIR}

    @staticmethod
    def health(hub, live, last_end, now, goals=None, fires=()):
        """GREEN, STALE or RED for a running loop, by the legend; for one that is not running, RED only for a fault - a
        lock no loop holds, a state line no process backs, a last fire that failed or timed out - and otherwise
        COMPLETE (every goal done) or STOPPED (stopped or not started, with the goals left open named)."""
        p, t = hub["interval_s"], hub["fire_timeout_s"]
        green, stale = max(2 * p, 600), max(6 * p, 1800)
        if hub["state"] != "running":
            if hub["stale_lock"]:
                return "RED", "a process that is not the loop holds its lock (%s)" % hub["state"]
            last = next((f for f in fires if not f.get("live")), None)
            if last and last["status"] in ("failed", "timeout"):
                return "RED", "the loop is not running (%s) and its last fire, %d, %s (rc %s)" % (
                    hub["state"], last["n"], "failed" if last["status"] == "failed" else "timed out", last["rc"])
            if hub["state"] == "stale":
                return "RED", "the loop is not running: its state line reads %s but no loop process backs it" % (
                    (hub["state_line"].split(" ", 1)[0] or "nothing"))
            g = goals or {}
            after = " after fire %d (rc %s)" % (last["n"], last["rc"]) if last and last["status"] == "ok" else ""
            if hub["state"] == "stopped" and g.get("exists") and g.get("open") == 0 and g.get("done", 0) > 0:
                return "COMPLETE", "all %d goal(s) done; the loop stopped%s%s" % (
                    g["done"], " on its STOP flag" if hub["stop_flag"] else "", after)
            why = "the loop is stopped" if hub["state"] == "stopped" else "the loop has not started"
            if last and last["status"] == "interrupted":
                why += "; fire %d was cut off when it stopped" % last["n"]
            elif after:
                why += after
            if g.get("open"):
                why += "; %d goal(s) open" % g["open"]
            return "STOPPED", why
        if live:
            age = now - live["begin"]
            if age <= t + 90:
                return "GREEN", "fire %d running for %s, inside its %ds timeout" % (live["n"], human(age), t)
            return "RED", "fire %d has run %s, past its %ds timeout" % (live["n"], human(age), t)
        if hub["phase"] == "IDLE" or last_end is None:
            ref = epoch(hub["state_utc"]) if hub["state_utc"] else None
            what = "last cycle (idle - nothing to fire against)"
        else:
            ref, what = last_end, "last fire"
        if ref is None:
            return "STALE", "no fire and no cycle recorded yet"
        age = now - ref
        word = "GREEN" if age <= green else "STALE" if age <= stale else "RED"
        return word, "%s %s ago; GREEN within %s, STALE within %s at a %ds interval" % (
            what, human(age), human(green), human(stale), p)

    def fires(self, lg, hub, now):
        out, seen_n = [], set()
        for f in reversed(lg.fires[-N_FIRES:]):
            g = dict(f)
            if g["status"] == "running" and not (hub["state"] == "running" and f is lg.open):
                g.update(status="interrupted", why="no END line, and no loop process runs (it stopped or died during "
                                                    "this fire)")
            g["live"] = g["status"] == "running"
            if g["n"] not in seen_n:
                path, size, first = transcript_info(g["n"])
                if path:
                    g.update(transcript="transcripts/fire-%d.out" % g["n"], transcript_bytes=size, summary=first)
            else:
                g["transcript_note"] = "overwritten by the later fire %d (fire numbers repeat after an interrupted " \
                                       "fire)" % g["n"]
            seen_n.add(g["n"])
            g.setdefault("subagents", [])
            out.append(g)
        self.sessions.refresh(hub["workdir"], min([f["begin"] for f in out] or [now]) - 60)
        self.sessions.match(out, now)
        for g in out:
            g["begin"], g["end"] = iso(g["begin"]), iso(g.get("end"))
        return out

    @staticmethod
    def attention(hub, fires, goals, now, complete=False):
        items = []
        if hub["stale_lock"]:
            who = ", ".join("pid %d (%s)" % (h["pid"], h["cmd"][:80]) for h in hub["lock_holders"][:3])
            items.append({"kind": "stale-lock", "level": "red", "text": "stale lock: %s/loop.lock is held by %s and no "
                          "loop process runs - /agent/loop-start.sh refuses to start until it exits" % (LOOP_DIR, who)})
        if hub["stop_flag"] and not complete:
            # a loop whose goals are all done stops on its own STOP flag: that is the expected end, shown in the
            # Loop tile, not something to attend to
            items.append({"kind": "stop-flag", "level": "amber", "text": "the STOP flag is present (%s/STOP): the "
                          "loop halts before its next fire; /agent/loop-start.sh removes it" % LOOP_DIR})
        if hub["state"] != "running" and goals["open"] > 0:
            items.append({"kind": "not-running", "level": "red", "text": "the loop is not running (%s) while %d "
                          "goal(s) are open in %s" % (hub["state"], goals["open"], goals["file"])})
        recent = [f for f in fires if f.get("end") and epoch(f["end"]) >= now - DAY]
        for f in recent:
            if f["status"] == "failed":
                items.append({"kind": "failed", "level": "red", "fire": f["n"], "text": "fire %d failed: rc %d after "
                              "%ds (ended %s)" % (f["n"], f["rc"], f["duration_s"], f["end"])})
            elif f["status"] == "timeout":
                items.append({"kind": "timeout", "level": "red", "fire": f["n"], "text": "fire %d hit its %ds "
                              "timeout: rc %d after %ds (ended %s)" % (f["n"], f["timeout_s"], f["rc"],
                                                                      f["duration_s"], f["end"])})
        for f in fires:
            if f["live"] and now - epoch(f["begin"]) > f["timeout_s"] + 90:
                items.append({"kind": "timeout", "level": "red", "fire": f["n"], "text": "fire %d has run past its "
                              "%ds timeout and is still running" % (f["n"], f["timeout_s"])})
        return items

    def strip(self, lg, hub, now):
        end = (int(now) // SLOT + 1) * SLOT
        start = end - SLOTS * SLOT
        slots = [{"start": iso(start + i * SLOT), "fires": 0, "ok": 0, "failed": 0, "alive": False}
                 for i in range(SLOTS)]
        for t in lg.seen:
            if start <= t < end:
                slots[int((t - start) // SLOT)]["alive"] = True
        if hub["state"] == "running":
            slots[-1]["alive"] = True
        for f in lg.fires:
            t = f.get("end") or (f["begin"] if f["status"] == "running" else None)
            if t is None or not start <= t < end:
                continue
            s = slots[int((t - start) // SLOT)]
            s["fires"] += 1
            s["ok"] += f["status"] == "ok"
            s["failed"] += f["status"] in ("failed", "timeout")
        for s in slots:
            s["state"] = "failed" if s["failed"] else "ok" if s["ok"] else "idle" if s["alive"] else "none"
        return {"slot_s": SLOT, "slots": slots}

    def fleet(self, hub, health, fires):
        tm = tmux_sessions()
        mine = [s for s in tm["sessions"] if s["role"] in ("loop", "fire") and
                (s["name"] == LOOP_SESSION or s["name"].startswith(LOOP_SESSION + "-fire-"))]
        others = [s for s in tm["sessions"] if s not in mine]
        nodes = {}
        for s in others:
            bits = ["%d client(s) attached" % s["attached"] if s["attached"] else "detached",
                    "%d window(s)" % s["windows"]]
            if s["command"]:
                bits.append("running %s" % s["command"])
            nodes[s["name"]] = {"kind": "terminal", "label": s["name"], "state": "attached" if s["attached"] else
                                "detached", "detail": ", ".join(bits), "task": s["task"], "parent": s["parent"],
                                "children": []}
        operator = {"kind": "operator", "label": "operator", "state": None, "children": [],
                    "detail": "the person who runs this harness - the browser terminal, exec shells, the commands below"}
        for s in others:
            parent = nodes.get(s["parent"]) if s["parent"] != s["name"] else None
            (parent["children"] if parent else operator["children"]).append(nodes[s["name"]])
            if not parent and s["parent"] not in (None, "operator"):
                nodes[s["name"]]["detail"] += "; its parent is %s" % s["parent"]
        live_tmux = {s["name"] for s in mine}
        kids = []
        for f in fires[:8]:
            sub = [{"kind": "subagent", "label": a["name"] or a["type"],
                    "state": "done" if a["done"] else "running" if f["live"] else "no result",
                    # an unnamed sub-agent is labelled by its type already: its detail is the description alone
                    "detail": ("%s - " % a["type"] if a["name"] else "") + (a["description"] or "")}
                   for a in f.get("subagents", [])]
            tmux_name = "%s-fire-%d" % (LOOP_SESSION, f["n"])
            kids.append({"kind": "fire", "label": "fire %d" % f["n"], "fire": f["n"], "state": f["status"],
                         "live": f["live"], "children": sub,
                         "tmux": tmux_name if f["live"] and tmux_name in live_tmux else None,
                         "detail": "began %s%s" % (f["begin"], ", rc %d after %ds" % (f["rc"], f["duration_s"])
                                                   if f.get("rc") is not None else "")})
        operator["children"].append({
            "kind": "loop", "label": "Autonomy loop", "state": hub["state"], "health": health[0],
            "detail": "%s; every %ds against %s" % (hub["phase"].lower() if hub["phase"] else hub["state"],
                                                   hub["interval_s"], hub["goals"]),
            "tmux": LOOP_SESSION if LOOP_SESSION in live_tmux else None, "children": kids})
        rows = self.services.rows
        return {"root": operator, "tmux": {"reachable": tm["reachable"], "error": tm["error"]},
                "services": rows if rows is not None else [], "services_at": iso(self.services.at),
                "services_error": self.services.error, "loop_session": LOOP_SESSION}

    def build(self):
        now = time.time()
        self.log.refresh()
        lg = self.log
        hub = self.hub(now, lg)
        live = lg.open if hub["state"] == "running" and lg.open else None
        ends = [f["end"] for f in lg.fires if f.get("end")]
        last_end = max(ends) if ends else None
        fires = self.fires(lg, hub, now)
        goals = goals_summary(hub["goals"] or GOALS_FILE, hub["stop_flag"])
        word, why = self.health(hub, live, last_end, now, goals, fires)
        hub.update(health=word, health_reason=why, last_fire_end=iso(last_end),
                   last_fire_age_s=int(now - last_end) if last_end else None, live_fire=live["n"] if live else None)
        day = [f for f in fires if f.get("end") and epoch(f["end"]) >= now - DAY]
        ok = sum(1 for f in day if f["status"] == "ok")
        last = next((f for f in fires if f.get("end")), None)
        return {
            "schema": "agent-loop-view/v1", "generated_at": iso(now), "generated_epoch": round(now, 3),
            "renderer": {"interval_s": INTERVAL, "stale_after_s": STALE_AFTER, "pid": os.getpid(),
                         "version": (read_text("/version.txt", 256) or "do-agent-aws").strip()},
            "hub": hub, "goals": goals,
            "stats": {"fires_24h": len(day), "ok_24h": ok, "failed_24h": len(day) - ok,
                      "success_rate_24h": round(ok / float(len(day)), 3) if day else None, "fires_total": len(lg.fires)},
            "attention": self.attention(hub, fires, goals, now, complete=word == "COMPLETE"),
            "fires": fires, "last_fire": last["n"] if last else None,
            "strip": self.strip(lg, hub, now), "fleet": self.fleet(hub, (word, why), fires),
            "notes": tail_lines(os.path.join(LOOP_DIR, "notes.md"), 8), "last_log_line": clip(lg.last_line, 300),
            "commands": commands(last),
            "control": {"enabled": CONTROL, "actions": sorted(ACTIONS)},
            "loop_deck": loop_deck(now),
        }

    def write(self):
        data = self.build()
        os.makedirs(OUT_DIR, exist_ok=True)
        for name in ("app.js", "style.css", "fire.html", "status.html", "index.html"):
            src = os.path.join(ASSETS_DIR, name)
            st = os.stat(src)
            if name == "index.html" or self.assets.get(name) != (st.st_size, st.st_mtime):
                with open(src, "rb") as f:
                    body = f.read()
                if name == "index.html":
                    body = body.replace(b"<!--SNAPSHOT-->", snapshot(data).encode("utf-8"))
                write_atomic(os.path.join(OUT_DIR, name), body)
                self.assets[name] = (st.st_size, st.st_mtime)
        write_atomic(os.path.join(OUT_DIR, "data.json"), json.dumps(data, indent=1).encode("utf-8"))
        self.last_ok, self.last_error = time.time(), None
        return data


def snapshot(d):
    """The page without JavaScript: a few escaped lines inside <noscript>."""
    import html
    h, s = d["hub"], d["stats"]
    lines = ["Agent loop: %s - %s (%s)" % (h["state"], h["health"], h["health_reason"]),
             "fires in the last 24 h: %d, %d ok" % (s["fires_24h"], s["ok_24h"]),
             "needs attention: %d item(s)" % len(d["attention"]),
             "This page draws its full view with JavaScript; the same data is in data.json next to it."]
    return "<p>" + "<br>".join(html.escape(l) for l in lines) + "</p>"


def write_atomic(path, body):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "wb") as f:
        f.write(body)
    os.replace(tmp, path)


# ---------------------------------------------------------------- the Control section's two actions
# Run next fire and Pause loop are the only writes this server makes, and only through the loop's own scripts:
# /agent/loop-start.sh (removes a STOP flag and starts the loop, which fires at once when it has goals; a running loop
# is left alone) and /agent/loop-stop.sh (sets the STOP flag: the loop halts before its next fire, a fire in flight
# finishes). Each answer is what the loop's files say after the script ran, never the script's word alone:
# loop-start.sh says "already running" whenever any process holds the lock, and touch succeeds on a STOP that is a
# directory. On by default (UI_LOOP_CONTROL=true; false refuses both and the page shows them off). POST only, to
# /control/run and /control/pause, with this page's own Origin and its X-Loop-Control header - a form or a page on
# another site can send neither - and one action at a time.
CONTROL = E.get("UI_LOOP_CONTROL", "true") == "true"
CONTROL_LOCK = threading.Lock()
ACTIONS = {"run": "loop-start.sh", "pause": "loop-stop.sh"}


def loop_now():
    """The loop as its files say now: the hub's state, phase and pid, whether STOP is a file, the lock's holders."""
    h = VIEW.hub(time.time(), VIEW.log)
    stop = os.path.join(LOOP_DIR, "STOP")
    kind = "file" if os.path.isfile(stop) else "directory" if os.path.isdir(stop) else \
        "absent" if not os.path.lexists(stop) else "other"
    return {"state": h["state"], "phase": h["phase"], "pid": h["pid"], "state_line": h["state_line"],
            "stop_flag": kind == "file", "stop_kind": kind, "stale_lock": h["stale_lock"],
            "lock_holders": h["lock_holders"][:3]}


def control(action):
    """Run the action's script, then read the loop back; the result says what was read back."""
    script = ACTIONS[action]
    before = loop_now()
    try:
        r = subprocess.run(["bash", os.path.join(AGENT_DIR, script)], capture_output=True, text=True, timeout=60,
                           stdin=subprocess.DEVNULL)
        rc, out = r.returncode, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        rc, out = None, "%s: %s" % (type(e).__name__, str(e)[:200])
    after = loop_now()
    where = "pid %s, %s" % (after["pid"], (after["phase"] or after["state"]).lower())
    if action == "run":
        ok = after["state"] == "running" and not after["stop_flag"]  # done only when the loop runs, read back
        if before["state"] == "running" and ok and "woke it" in out:
            result, msg = "done", "woke the sleeping loop (%s); the next fire starts within ~5 s" % where
        elif before["state"] == "running" and ok and (before["phase"] or "").upper() == "FIRING":
            result, msg = "unchanged", "a fire is running (%s); the next fire starts when it ends" % where
        elif before["state"] == "running" and ok:
            result, msg = "unchanged", "the loop was already running (%s); it fires on its own schedule" % where
        elif ok:
            result, msg = "done", "the loop runs (%s)%s" % (where, "; the STOP flag was removed" if before["stop_flag"] else "")
        elif after["state"] == "running" and after["stop_flag"]:
            result, msg = "failed", ("the loop runs (%s) with its STOP flag still set - loop-start.sh leaves a running loop "
                                     "alone - so it halts before its next fire; Run next fire again once it has stopped" % where)
        elif after["stale_lock"]:
            who = ", ".join("pid %d (%s)" % (x["pid"], x["cmd"][:60]) for x in after["lock_holders"])
            result, msg = "failed", "the loop did not start: its lock is held by %s, which is not a loop" % who
        else:
            result, msg = "failed", "the loop did not start: it reads %s" % after["state"]
    else:
        ok = after["stop_flag"]  # done only when STOP is a file the loop sees, read back
        if before["stop_flag"] and ok:
            result, msg = "unchanged", "the STOP flag was already set"
        elif ok:
            result, msg = "done", "the STOP flag is set"
        else:
            result, msg = "failed", "the STOP flag is not set: %s/STOP is %s" % (LOOP_DIR, after["stop_kind"])
        if ok:
            msg += ("; the loop (%s) halts before its next fire, a fire in flight finishes" % where
                    if after["state"] == "running" else "; the loop is not running (%s) - Run next fire removes the "
                    "flag and starts it" % after["state"])
    return {"action": action, "result": result, "message": msg, "script": "/agent/" + script, "rc": rc,
            "output": clip(out, 600), "before": before, "after": after, "at": iso(time.time())}


VIEW = None
# The page's own origin only - nothing inline, nothing from elsewhere. The home proxy replaces this header on the
# loop.localhost route with the same policy plus the hash of the home badge's style attribute (home-render.sh).
CSP = ("default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; "
       "frame-ancestors 'none'")
FILES = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
         "/fire.html": ("fire.html", "text/html; charset=utf-8"),
         "/status.html": ("status.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"),
         "/style.css": ("style.css", "text/css; charset=utf-8"), "/data.json": ("data.json", "application/json")}
TRANSCRIPT_RE = re.compile(r"^/transcripts/fire-(\d{1,9})\.out$")
# One page per loop at /loop/<loop-id>/ - with the page's own relative
# addresses (data.json, fire.html, transcripts/, control/) resolving under it; the autonomy loop is also /, as before.
# Any other id answers 404 with a page that says so, and names the loops this renderer shows.
LOOPS = {
    "autonomy-loop": "the autonomy loop, /agent/loop.sh",
    "slack-chat": "the Slack chat responder, /agent/slack-chat.sh - each message it answered is a fire",
    "slack-watch": "the Slack watch, /agent/slack-watch.sh - the one-line summary of its last run",
    "comms-watch": "the comms watch, /agent/comms-watch-start.sh - its process and the tail of its log",
    "kanban-sync": "the kanban board's mirror of the goals, /agent/kanban-sync.py - its state file",
    "plane-sync": "the Plane board's mirror of the goals, /agent/plane-sync.py - its state file",
    "hindsight-seed": "the memory seed, /agent/hindsight-seed.sh - its extraction state",
}
# where the other loops leave their records (the same defaults their own scripts use)
SLACK_DIR = E.get("SLACK_DIR", "/wd/slack")
COMMS_DIR = E.get("COMMS_DIR", "/wd/comms")
SEED_STATE = E.get("HINDSIGHT_SEED_STATE") or os.path.join(E.get("UI_DIR", "/wd/ui"), "hindsight-seed.state")
CHAT_RE = re.compile(r"^(\S+) CHAT (MSG|MODEL|REPLY) ts=(\S+)(.*)$")
LOOP_ROUTE_RE = re.compile(r"^/loop/([^/]*)(/.*)?$")


def loop_deck_href(host):
    """Loop Deck's Loops view beside this host route - loop.localhost:<port> -> //loop-deck.localhost:<port>/#/loops, the
    first label replaced as the home badge does - or None off a *.localhost host."""
    m = re.match(r"^[^.:/]+\.((?:[^.:/]+\.)*localhost(?::\d+)?)$", (host or "").strip().lower())
    return "//loop-deck.%s/#/loops" % m.group(1) if m else None


# The page's link to Loop Deck, every loop of this harness. A fleet's Deck named by LOOP_DECK_URL - the URL the home
# page's Fleet Loop Deck tile links, under the same check - is the link, to its Loops view. Otherwise the Deck this
# harness serves on loop-deck.localhost is, but only while the home proxy reaches it: GET /__probe/loop-deck on the home
# listener answers 2xx (the probe the home page's Loop Deck dot reads; status only), asked at most every
# LOOP_VIEW_DECK_PROBE_SECS. With neither there is no link - never a dead one.
DECK_URL = E.get("LOOP_DECK_URL", "").strip()
DECK_URL_RE = re.compile(r"https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~!$&()*+,;=:@/%#?-]*)?")
DECK_PROBE_SECS = _num("LOOP_VIEW_DECK_PROBE_SECS", 30, float)
HOME_PORT = _num("UI_PORT_HOME", 8000)


class DeckProbe:
    """Whether the home proxy reaches the Loop Deck it serves; the answer is kept DECK_PROBE_SECS."""

    def __init__(self):
        self.at, self.up, self.lock = None, False, threading.Lock()

    def reachable(self, now):
        with self.lock:
            if self.at is not None and now - self.at < DECK_PROBE_SECS:
                return self.up
            self.at = now
        up = False
        try:
            c = http.client.HTTPConnection("127.0.0.1", HOME_PORT, timeout=2)
            try:
                c.request("GET", "/__probe/loop-deck", headers={"Host": "localhost"})
                up = 200 <= c.getresponse().status < 300
            finally:
                c.close()
        except (OSError, http.client.HTTPException):
            up = False
        self.up = up
        return up


DECK = DeckProbe()


def loop_deck(now):
    """The page's Loop Deck link: {"href": LOOP_DECK_URL's Loops view}, {"route": true} for the Deck this harness serves
    while it is reachable (the page derives its address from its own host, loop_deck_href), or None."""
    if DECK_URL and DECK_URL_RE.fullmatch(DECK_URL):
        return {"href": DECK_URL.split("#", 1)[0] + "#/loops", "via": "LOOP_DECK_URL"}
    return {"route": True, "via": "loop-deck.localhost"} if DECK.reachable(now) else None
def read_tail(path, limit=1 << 18):
    """The last `limit` bytes of a file as text (from a line start), or None."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - limit))
            data = f.read(limit)
    except OSError:
        return None
    text = data.decode("utf-8", "replace")
    return text.split("\n", 1)[1] if size > limit and "\n" in text else text


def record(path, now, lines=1):
    """A record file as it stands: its first lines, when it was written and how long ago; or that it is missing."""
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return {"file": path, "missing": True}
    text = read_text(path, 1 << 14) or ""
    out = {"file": path, "at": iso(mtime), "age_s": int(max(0, now - mtime)), "lines": [clip(l, 400) for l in text.splitlines() if l.strip()][:lines]}
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if isinstance(data, dict):  # a JSON state file: its scalar fields, as words
        out["fields"] = [[str(k)[:60], clip(json.dumps(v) if not isinstance(v, str) else v, 200)]
                         for k, v in list(data.items())[:24] if not isinstance(v, (dict, list))]
        out["lines"] = []
    return out


def pid_process(path):
    """The process a pid file names: alive only while /proc has it - a stale pid file reads not running."""
    text = (read_text(path, 64) or "").strip()
    if not text:
        return {"file": path, "missing": True, "alive": False}
    if not text.isdigit():
        return {"file": path, "pid": None, "alive": False, "note": "the pid file holds no pid"}
    cmd = cmdline(text)
    return {"file": path, "pid": int(text), "alive": bool(cmd), "cmd": clip(cmd or "", 160)}


def chat_fires(path, limit=50):
    """The chat responder's answered messages as fires, from its log: CHAT MSG opens one, CHAT MODEL adds the model's rc,
    duration and whether it posted, CHAT REPLY closes it with its outcome. Newest first."""
    fires, by_ts = [], {}
    for line in (read_tail(path) or "").splitlines():
        m = CHAT_RE.match(line)
        if not m:
            continue
        at, what, ts, rest = m.groups()
        if what == "MSG":
            kind = re.search(r"\bkind=(\S+)", rest)
            text = re.search(r'\btext="(.*)"\s*$', rest)
            channel = re.search(r"\bchannel=(\S+)", rest)
            f = {"n": len(fires) + 1, "ts": ts, "begin": at, "end": None, "channel": channel.group(1) if channel else None,
                 "kind": kind.group(1) if kind else None, "text": clip(text.group(1), 160) if text else "",
                 "rc": None, "duration_s": None, "posted": None, "outcome": None, "status": "answering"}
            fires.append(f)
            by_ts[ts] = f
            continue
        f = by_ts.get(ts)
        if f is None:
            continue
        if what == "MODEL":
            rc = re.search(r"\brc=(-?\d+)", rest)
            dur = re.search(r"\bduration=(\d+)s", rest)
            posted = re.search(r"\bposted=(\S+)", rest)
            f.update(rc=int(rc.group(1)) if rc else None, duration_s=int(dur.group(1)) if dur else None,
                     posted=posted.group(1) if posted else None)
        else:
            out = re.search(r"\bkind=\S+ (ok|UNKNOWN|INCOMPLETE|FAILED)\b", rest)
            word = out.group(1) if out else "unknown"
            f.update(end=at, outcome=word.lower(), status={"ok": "ok", "FAILED": "failed"}.get(word, "unknown"))
    return list(reversed(fires))[:limit]


def other_loop(slug, now):
    """What the page of a loop other than the autonomy loop shows, read from the files that loop leaves."""
    d = {"schema": "agent-loop-status/v1", "slug": slug, "about": LOOPS[slug], "generated_at": iso(now),
         "generated_epoch": int(now), "record": None, "process": None, "log_tail": [], "fires": None,
         "renderer": {"stale_after_s": STALE_AFTER},
         "loop_deck": loop_deck(now)}
    if slug == "slack-chat":
        d["record"] = record(os.path.join(SLACK_DIR, "chat.state"), now)
        holders = lock_holders(os.path.join(SLACK_DIR, "chat.lock")) or []
        d["process"] = {"file": os.path.join(SLACK_DIR, "chat.lock"), "holders": holders[:3],
                        "alive": any("slack-chat.sh" in h["cmd"] for h in holders)}
        d["fires"] = chat_fires(os.path.join(SLACK_DIR, "chat.log"))
    elif slug == "slack-watch":
        d["record"] = record(os.path.join(SLACK_DIR, "last-watch"), now)
    elif slug == "comms-watch":
        d["process"] = pid_process(os.path.join(COMMS_DIR, "watch.pid"))
        d["log_tail"] = tail_lines(os.path.join(COMMS_DIR, "watch.log"), 20)
    elif slug in ("kanban-sync", "plane-sync"):
        d["record"] = record(os.path.join(LOOP_DIR, slug + ".state"), now)
    elif slug == "hindsight-seed":
        d["record"] = record(SEED_STATE, now, lines=8)
    return d


def loop_route(path):
    """(None, path) for a path outside /loop/; (loop id, the rest) for /loop/<id><rest>, the rest None for /loop/<id>."""
    m = LOOP_ROUTE_RE.match(path)
    return (m.group(1), m.group(2)) if m else (None, path)
TRANSCRIPT_MAX = 4 << 20


def host_ok(host):
    name = (host or "").strip().lower()
    name = name[1:name.index("]")] if name.startswith("[") and "]" in name else name.split(":")[0]
    return name in ("127.0.0.1", "localhost", "::1") or name.endswith(".localhost")


class Handler(BaseHTTPRequestHandler):
    server_version = "loop-view"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype, extra=None):
        self.send_response(code)
        headers = {"Content-Type": ctype, "Content-Length": str(len(body)), "Cache-Control": "no-store",
                   "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
                   "Content-Security-Policy": CSP}
        headers.update(extra or {})
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def refuse(self):
        self.send(405, b"GET and HEAD only; POST only to /control/run and /control/pause\n", "text/plain; charset=utf-8",
                  {"Allow": "GET, HEAD"})

    do_PUT = do_PATCH = do_DELETE = do_OPTIONS = refuse

    def do_POST(self):
        loop_id, path = loop_route(self.path.split("?", 1)[0])
        action = path[len("/control/"):] if path and path.startswith("/control/") else None
        if action not in ACTIONS:
            return self.refuse()

        def no(code, why):
            body = json.dumps({"action": action, "result": "refused", "message": why}).encode("utf-8")
            return self.send(code, body, "application/json")
        host = self.headers.get("Host") or ""
        if not host_ok(host):
            return no(421, "refused: loopback names only")
        if loop_id not in (None, "autonomy-loop"):
            return no(404, "refused: Run next fire and Pause loop are the autonomy loop's (/loop/autonomy-loop/)")
        if not CONTROL:
            return no(403, "refused: the loop's controls are off (UI_LOOP_CONTROL=false in .env)")
        if self.headers.get("X-Loop-Control") != "1":
            return no(403, "refused: not sent by the Agent loop page (no X-Loop-Control header)")
        origin = self.headers.get("Origin") or ""
        if origin != "http://" + host or (self.headers.get("Sec-Fetch-Site") or "same-origin") != "same-origin":
            return no(403, "refused: the request comes from another origin (%s)" % (origin[:80] or "none given"))
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return no(400, "refused: the Content-Length is not a number")
        if length > 0:
            self.rfile.read(min(length, 4096))
        if not CONTROL_LOCK.acquire(blocking=False):
            return no(409, "refused: another action is still running")
        try:
            res = control(action)
        finally:
            CONTROL_LOCK.release()
        self.send(200, json.dumps(res).encode("utf-8"), "application/json")

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if not host_ok(self.headers.get("Host")):
            return self.send(421, b"misdirected: loopback names only\n", "text/plain; charset=utf-8")
        loop_id, path = loop_route(path)
        if loop_id is not None and loop_id not in LOOPS:
            return self.no_such_loop(loop_id)
        if loop_id is not None and path is None:
            # /loop/<id> without its slash: the page's relative addresses would resolve one level up
            return self.send(301, b"", "text/plain; charset=utf-8", {"Location": "/loop/%s/" % loop_id})
        if loop_id not in (None, "autonomy-loop"):
            # another loop of the harness: its status page, and its status read from its files at each request
            if path == "/data.json":
                return self.send(200, json.dumps(other_loop(loop_id, time.time())).encode("utf-8"), "application/json")
            path = "/status.html" if path in ("/", "/index.html") else path
            if path not in ("/status.html", "/app.js", "/style.css"):
                return self.send(404, b"not found\n", "text/plain; charset=utf-8")
        if path == "/health":
            age = time.time() - VIEW.last_ok if VIEW.last_ok else None
            fresh = age is not None and age <= STALE_AFTER
            body = json.dumps({"fresh": fresh, "age_s": None if age is None else round(age, 1),
                               "stale_after_s": STALE_AFTER, "error": VIEW.last_error}).encode("utf-8")
            return self.send(200 if fresh else 503, body, "application/json")
        m = TRANSCRIPT_RE.match(path)
        if m:
            return self.transcript(int(m.group(1)))
        if path not in FILES:
            return self.send(404, b"not found\n", "text/plain; charset=utf-8")
        name, ctype = FILES[path]
        try:
            with open(os.path.join(OUT_DIR, name), "rb") as f:
                body = f.read()
        except OSError:
            return self.send(503, b"the page is not rendered yet\n", "text/plain; charset=utf-8")
        self.send(200, body, ctype)

    def no_such_loop(self, raw):
        """404 for /loop/<id>/ with an id this renderer does not show: a page that says so, the id escaped, the loops
        it does show linked; the harness stylesheet and the page's own, nothing inline."""
        name = html.escape(unquote(raw)[:80], quote=True) or "(none)"
        known = "".join('<li><a href="/loop/%s/">%s</a> - %s</li>' % (k, k, html.escape(v)) for k, v in sorted(LOOPS.items()))
        link = loop_deck(time.time())
        deck = link and (link.get("href") or loop_deck_href(self.headers.get("Host")))
        deck = '<p><a href="%s">Loop Deck</a>: every loop of this harness</p>\n' % html.escape(deck, quote=True) if deck else ""
        body = ('<!DOCTYPE html>\n<html lang="en" class="hs-root">\n<head>\n<meta charset="utf-8">\n'
                '<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>No such loop - Agent loop</title>\n'
                '<link rel="stylesheet" href="/__harness/harness.css">\n<link rel="stylesheet" href="/style.css">\n</head>\n'
                '<body class="hs-page" data-view="none">\n<header class="hs-header">\n<h1>No such loop</h1>\n'
                '<p class="sub">this harness has no loop named <code>%s</code> - the Agent loop page shows the loops below</p>\n'
                '</header>\n<main>\n<section>\n<ul class="known">%s</ul>\n<p><a href="/">Agent loop</a></p>\n%s</section>\n'
                '</main>\n</body>\n</html>\n' % (name, known, deck)).encode("utf-8")
        return self.send(404, body, "text/html; charset=utf-8")

    def transcript(self, n):
        """A fire's transcript as plain text - never HTML, whatever it contains: text/plain, nosniff, and a policy
        under which nothing in it could run even if a browser rendered it."""
        path = os.path.join(LOOP_DIR, "fires", "fire-%d.out" % n)
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as f:
                if size > TRANSCRIPT_MAX:
                    f.seek(size - TRANSCRIPT_MAX)
                body = f.read(TRANSCRIPT_MAX)
        except OSError:
            return self.send(404, b"no transcript for this fire\n", "text/plain; charset=utf-8")
        if size > TRANSCRIPT_MAX:
            body = ("[the first %d bytes are not shown: %s holds the whole transcript]\n"
                    % (size - TRANSCRIPT_MAX, path)).encode("utf-8") + body
        self.send(200, body, "text/plain; charset=utf-8", {"Content-Security-Policy": "default-src 'none'; sandbox",
                                                           "Content-Disposition": "inline; filename=\"fire-%d.out\"" % n})


def render_forever():
    while True:
        t0 = time.time()
        try:
            VIEW.write()
        except Exception as e:  # logged; /health turns 503 once the last good write is STALE_AFTER old
            VIEW.last_error = "%s: %s" % (type(e).__name__, str(e)[:240])
            print("loop-view: render failed: %s" % VIEW.last_error, file=sys.stderr, flush=True)
        time.sleep(max(0.5, INTERVAL - (time.time() - t0)))


def main():
    global VIEW
    ap = argparse.ArgumentParser(description="The Agent loop page (read-only view of /agent/loop.sh)")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--once", action="store_true", help="render once into %s and exit" % OUT_DIR)
    args = ap.parse_args()
    VIEW = View()
    if args.once:
        VIEW.services.probe()
        VIEW.write()
        print("loop-view: wrote %s/data.json and the page" % OUT_DIR)
        return 0
    VIEW.services.start()
    VIEW.write()
    threading.Thread(target=render_forever, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print("loop-view: serving %s on 127.0.0.1:%d (loop %s, a render every %ss, stale after %ss)"
          % (OUT_DIR, args.port, LOOP_DIR, INTERVAL, STALE_AFTER), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
