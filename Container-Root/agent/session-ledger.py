#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The session ledger: one JSON line for each start, stop, resume and closed-exited of a tmux session on the watched tmux
server, so a stopped session can be brought back (docs/AGENT-STACK.md "The session ledger"; /agent/supervisor.sh runs it).

  session-ledger.py record <event> <session> [--reason R] [--pane-pid N --cwd D --command C --created T] [--output F]
      one line for the session: from its pane when it runs (or from the values given: the start script's, read from
      the call that created the session, so nothing queries a pane that may be exiting), else from its latest line;
      --output names the file a close kept the session's output in
  session-ledger.py census [--first]      stdin: "<session> <agent pane pid> <created>" for each session on the server
      now. A session whose latest line is a start or a resume of another session or pane, or of none now, gets its stop
      line; a session with no such line for itself gets a start line
  session-ledger.py stop-all <reason>     stdin as for census: a stop line for each of them (the stack's stop path)
  session-ledger.py latest [<session>]    the latest line of each session, by name (of one: exit 1 when it has none)
  session-ledger.py resume <session>      recreate a session that is not running from its latest line and record it:
      a registry session through the registry's start (/agent/tmux-session-start.sh), a scratch one in its recorded
      directory with its recorded command, or claude --resume <id> when its Claude Code session id is known

A line: ts, event (start, stop, resume or closed-exited), session, agent (the registry's name, or scratch), pane_pid,
created (the session's creation time, epoch seconds: with pane_pid, which a new container can hand out again, it tells
one session of a name from the next), cwd, command (the pane's command as tmux started it), git_head (of cwd, when it is
in a repository), work (the
supervisor's state and why for the session, read from a pass after the session's creation, or the last line of a STATUS
file in cwd), claude_session (the id of the Claude Code session in the pane, when known), resume (the command that
recreates the session), reason, and for a close output (the file that keeps what its panes showed) and output_tail (that
file's last 40 lines, at most 4000 characters); both are null on every other line.

The file (${SUPERVISOR_DIR}/sessions-ledger.jsonl) is only ever appended to: every writer opens it for appending and
adds whole lines under one lock (sessions-ledger.lock beside it); nothing rewrites, shortens or replaces it.
"""

import fcntl
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone

AGENT_DIR = os.path.dirname(os.path.abspath(__file__))
SUP = os.environ.get("SUPERVISOR_DIR") or "/wd/supervisor"
LEDGER = os.path.join(SUP, "sessions-ledger.jsonl")
LOCK = os.path.join(SUP, "sessions-ledger.lock")
EVENTS = ("start", "stop", "resume", "closed-exited")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")


def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def registry():
    try:
        doc = json.load(open(os.environ.get("SPOKES_REGISTRY") or "/agent/spokes/registry.json"))
        return {e["session_name"]: e for e in doc.get("sessions", []) if isinstance(e, dict) and isinstance(e.get("session_name"), str)}
    except (OSError, ValueError, AttributeError, TypeError):
        return {}


def enabled(e):
    # spoke.sh's rule: the entry's .env flag decides when it is set, its "enabled" is the default
    flag = e.get("flag")
    if flag and flag in os.environ:
        return os.environ[flag] == "true"
    return e.get("enabled") is True


def tmux(*args):
    try:
        p = subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 else None


def command_of(start):
    # tmux shows a pane's command quoted ("sleep 1; exit 3"); kept as the one shell line it runs
    if not start:
        return ""
    try:
        args = shlex.split(start)
    except ValueError:
        return start
    return args[0] if len(args) == 1 else shlex.join(args)


def descendants(root):
    kids = {}
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                ppid = open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()[1]
            except (OSError, IndexError):
                continue
            kids.setdefault(ppid, []).append(p)
    todo, seen = [str(root)], [str(root)]
    while todo:
        for k in kids.get(todo.pop(), []):
            seen.append(k)
            todo.append(k)
    return seen


def claude_session(pane_pid):
    # Claude Code keeps a record per running process, <config dir>/sessions/<pid>.json, with its session id
    base = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"), "sessions")
    if not pane_pid or not os.path.isdir(base):
        return None
    for p in descendants(pane_pid):
        try:
            sid = json.load(open(os.path.join(base, p + ".json"))).get("sessionId")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(sid, str) and UUID.match(sid):
            return sid
    return None


def live(s):
    # the session's agent pane as fleet-check.sh picks it (the one @agent_pane names, else the active pane of the active
    # window): (pane pid, its directory, its command, the Claude Code session in it, the session's creation time), or None
    # when the session is gone. A pane whose process has exited has no current path: the session's directory stands in
    out = tmux("list-panes", "-s", "-t", f"={s}:", "-F",
               "#{pane_id}\t#{pane_pid}\t#{window_active}#{pane_active}\t#{@agent_pane}\t#{session_created}\t"
               "#{session_path}\t#{pane_current_path}\t#{pane_start_command}")
    if out is None:
        return None
    hit = None
    for line in out.splitlines():
        f = line.split("\t", 7)
        if len(f) < 8:
            continue
        if (f[3] and f[0] == f[3]) or (not f[3] and f[2] == "11"):
            hit = f
    if hit is None or not hit[1].isdigit():
        return None
    pid = int(hit[1])
    return pid, hit[6] or hit[5] or None, command_of(hit[7]), claude_session(pid), int(hit[4]) if hit[4].isdigit() else None


def git_head(cwd):
    # the commit the repository holding cwd is at, read from its files (no git process in a directory that may not be ours)
    d = os.path.abspath(cwd) if cwd else None
    while d:
        g = os.path.join(d, ".git")
        if os.path.exists(g):
            break
        d = None if os.path.dirname(d) == d else os.path.dirname(d)
    if not d:
        return None
    try:
        if os.path.isfile(g):
            t = open(g).read().strip()
            if not t.startswith("gitdir:"):
                return None
            g = os.path.normpath(os.path.join(d, t[len("gitdir:"):].strip()))
        head = open(os.path.join(g, "HEAD")).read().strip()
        if re.fullmatch(r"[0-9a-f]{40}([0-9a-f]{24})?", head):
            return head
        if not head.startswith("ref: "):
            return None
        ref = head[len("ref: "):]
        common = g
        if os.path.isfile(os.path.join(g, "commondir")):
            common = os.path.normpath(os.path.join(g, open(os.path.join(g, "commondir")).read().strip()))
        for base in (g, common):
            if os.path.isfile(os.path.join(base, ref)):
                return open(os.path.join(base, ref)).read().strip() or None
        for line in open(os.path.join(common, "packed-refs")):
            f = line.split()
            if len(f) == 2 and f[1] == ref:
                return f[0]
    except (OSError, UnicodeDecodeError):
        return None
    return None


def work(s, cwd, reg, created=None):
    one = lambda t: " ".join(str(t).split())[:300]
    if s in reg:
        try:
            doc = json.load(open(os.path.join(SUP, "status.json")))
            st = doc["sessions"].get(s) or {}
            # a pass written before the session was created speaks of another session of the name (at the first census
            # after a restart, the last container's)
            at = datetime.strptime(doc["updated_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
            if st.get("state") and not (created and at < created):
                return one(st["state"] + (": " + str(st["why"]) if st.get("why") else ""))
        except (OSError, ValueError, KeyError, AttributeError, TypeError):
            pass
    for f in ("STATUS", "STATUS.md"):
        try:
            lines = [l for l in open(os.path.join(cwd or "/nonexistent", f), errors="replace").read().splitlines() if l.strip()]
        except OSError:
            continue
        if lines:
            return one(lines[-1])
    return None


def other_conversation_out(words):
    # claude's words less those that pick a conversation: --continue, -c, --resume or -r with the id that follows it,
    # --session-id with its value
    out, after, value = [], False, False
    for w in words:
        if value:
            value = False
            continue
        if after:
            after = False
            if UUID.match(w):
                continue
        if w in ("--continue", "-c") or w.startswith(("--resume=", "--session-id=")):
            continue
        if w in ("--resume", "-r"):
            after = True
            continue
        if w == "--session-id":
            value = True
            continue
        out.append(w)
    return out


def resume_of(s, agent, role, cwd, command, claude):
    """(argv, env, text): the command that recreates the session, and the same command as one line of shell"""
    if agent != "scratch":
        start = os.path.join(AGENT_DIR, "tmux-session-start.sh")
        argv = [start] if role == "hub" else [start, s]
        env = {}
        if claude:
            # the claude options the session starts with (tmux-claude.sh splits them on spaces), and --resume <id>
            keep = other_conversation_out((os.environ.get("AGENT_TMUX_CLAUDE_OPTS") or "").split())
            env = {"AGENT_TMUX_CLAUDE_OPTS": " ".join(keep + ["--resume", claude])}
    else:
        cmd = command
        if claude:
            # a pane started as claude keeps its own words; any other runs claude --resume <id> in its place
            try:
                words = shlex.split(command or "")
            except ValueError:
                words = []
            if words and os.path.basename(words[0]) == "claude":
                cmd = shlex.join([words[0]] + other_conversation_out(words[1:]) + ["--resume", claude])
            else:
                cmd = "claude --resume " + claude
        argv = ["tmux", "new-session", "-d", "-s", s, "-c", cwd or os.path.expanduser("~")] + ([cmd] if cmd else [])
        env = {}
    return argv, env, " ".join([f"{k}={shlex.quote(v)}" for k, v in env.items()] + [shlex.quote(a) for a in argv])


def opts_session():
    m = re.search(r"(?:^|\s)(?:--resume|-r)(?:=|\s+)([0-9a-f-]{36})(?=\s|$)", os.environ.get("AGENT_TMUX_CLAUDE_OPTS") or "")
    return m.group(1) if m and UUID.match(m.group(1)) else None


def same(r, now):
    # the line is of the session that runs now: the same pane pid and, where both carry it, the same creation time
    pid, created = now
    return r.get("pane_pid") == pid and (r.get("created") is None or created is None or r.get("created") == created)


def tail_of(path, lines=40, size=4000):
    # the last lines of a file, at most size characters of them
    try:
        with open(path, errors="replace") as f:
            return "\n".join(f.read().splitlines()[-lines:])[-size:]
    except OSError:
        return None


def line_for(event, s, reason, reg, prev, given=None, gone=False, claude_hint=None, agent_hint=None, output=None):
    # given: (pane pid, directory, command, creation time) from the call that created the session; claude_hint: the
    # Claude Code session it was started to resume; agent_hint: the agent of the line a resume recreated the session from
    # (a scratch session whose name the registry has gained since stays scratch); output: the file a close kept its
    # panes' output in
    e = reg.get(s)
    agent = agent_hint or (s if e else "scratch")
    if agent == "scratch":
        e = None
    lv = None if (given or gone) else live(s)
    if given:
        pane_pid, cwd, command, created = given
        claude = claude_hint or opts_session()
    elif lv:
        pane_pid, cwd, command, claude, created = lv
        cwd = cwd or prev.get("cwd")
        claude = claude or claude_hint or (prev.get("claude_session") if same(prev, (pane_pid, created)) else None)
    else:
        pane_pid, cwd, command, claude, created = (prev.get(k) for k in ("pane_pid", "cwd", "command", "claude_session", "created"))
    if not cwd and e:
        cwd = e.get("workdir")
    if not command and e and not lv and not given:
        command = e.get("launch_cmd")
    _, _, text = resume_of(s, agent, (e or {}).get("role"), cwd, command or "", claude)
    return {"ts": utc(), "event": event, "session": s, "agent": agent, "pane_pid": pane_pid, "created": created, "cwd": cwd,
            "command": command or "", "git_head": git_head(cwd), "work": work(s, cwd, reg if e else {}, created),
            "claude_session": claude, "resume": text, "reason": reason, "output": output,
            "output_tail": tail_of(output) if output else None}


class Locked:
    def __enter__(self):
        os.makedirs(SUP, exist_ok=True)
        self.f = open(LOCK, "a")  # nosemgrep: open-never-closed -- closed by Locked.__exit__
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        self.f.close()


def append(lines):
    # the only write: whole lines added at the end, never a rewrite
    if not lines:
        return
    fd = os.open(LEDGER, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, "".join(json.dumps(l, sort_keys=True) + "\n" for l in lines).encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def latest_map():
    m = {}
    try:
        with open(LEDGER, errors="replace") as f:
            for raw in f:
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(r, dict) and isinstance(r.get("session"), str):
                    m[r["session"]] = r
    except OSError:
        pass
    return m


def current():
    cur = {}
    for l in sys.stdin:
        f = l.split()
        if len(f) >= 2 and NAME.match(f[0]) and f[1].isdigit():
            cur[f[0]] = (int(f[1]), int(f[2]) if len(f) > 2 and f[2].isdigit() else None)
    return cur


def die(msg, rc=1):
    print("session-ledger: " + msg, file=sys.stderr)
    sys.exit(rc)


def main(argv):
    cmd, args = (argv[0] if argv else ""), argv[1:]
    if cmd == "record":
        if len(args) < 2 or args[0] not in EVENTS or not NAME.match(args[1]):
            die("usage: record start|stop|resume|closed-exited <session> [--reason R] [--pane-pid N --cwd D --command C"
                " --created T] [--output F]", 64)
        opt = dict(zip(args[2::2], args[3::2]))
        given = None
        if "--pane-pid" in opt:
            num = lambda v: int(v) if v and v.isdigit() else None
            given = (num(opt["--pane-pid"]), opt.get("--cwd") or None, opt.get("--command", ""), num(opt.get("--created")))
        reg = registry()
        with Locked():
            prev = latest_map().get(args[1]) or {}
            append([line_for(args[0], args[1], opt.get("--reason") or args[0], reg, prev, given,
                             gone=args[0] == "closed-exited", output=opt.get("--output") or None)])
    elif cmd in ("census", "stop-all"):
        first = "--first" in args
        cur, reg = current(), registry()
        with Locked():
            lat, out = latest_map(), []
            if cmd == "stop-all":
                out = [line_for("stop", s, " ".join(args) or "stop", reg, lat.get(s) or {}) for s in sorted(cur)]
            else:
                for s, r in sorted(lat.items()):
                    if r.get("event") in ("start", "resume") and not (s in cur and same(r, cur[s])):
                        if s in cur:
                            why = "a new session of this name replaced it; no stop was recorded"
                        elif first:
                            why = "not running when the supervisor started; no stop was recorded"
                        else:
                            why = "its session ended"
                        out.append(line_for("stop", s, why, reg, r, gone=True))
                for s, now in sorted(cur.items()):
                    r = lat.get(s) or {}
                    if not (r.get("event") in ("start", "resume") and same(r, now)):
                        out.append(line_for("start", s, "found running" if s in reg else "appeared", reg, r))
            append(out)
    elif cmd == "latest":
        lat = latest_map()
        if args:
            if args[0] not in lat:
                die(f"no ledger line for {args[0]} in {LEDGER}")
            print(json.dumps(lat[args[0]], sort_keys=True))
        else:
            for s in sorted(lat):
                print(json.dumps(lat[s], sort_keys=True))
    elif cmd == "resume":
        if len(args) != 1 or not NAME.match(args[0]):
            die("usage: resume <session>", 64)
        s = args[0]
        r = latest_map().get(s)
        if not r:
            die(f"no ledger line for {s} in {LEDGER}: nothing to resume it from")
        if tmux("has-session", "-t", f"={s}") is not None:
            die(f"{s} is running: resume recreates only a session that is not")
        reg = registry()
        e = reg.get(s)
        role = (e or {}).get("role")
        if r.get("agent") != "scratch":
            if not e:
                die(f"{s} is no longer in the registry ({os.environ.get('SPOKES_REGISTRY') or '/agent/spokes/registry.json'})")
            if not enabled(e):
                die(f"{s} is off ({e.get('flag')}=false): the registry decides what runs; set {e.get('flag')}=true in .env.local, then ./stop.sh && ./run.sh")
        elif not (r.get("cwd") and os.path.isdir(r["cwd"])):
            die(f"{s}'s directory {r.get('cwd')} is not there: nothing to recreate it in")
        argv, env, text = resume_of(s, r.get("agent"), role, r.get("cwd"), r.get("command") or "", r.get("claude_session"))
        why = f"supervisor.sh resume, from its {r.get('event')} line of {r.get('ts')}"
        if r.get("agent") == "scratch":
            p = subprocess.run(argv[:2] + ["-P", "-F", "#{pane_pid} #{session_created}"] + argv[2:], capture_output=True,  # nosemgrep: dangerous-subprocess-use-audit -- argv list run without a shell; its values are the harness's own paths and settings
                               text=True, timeout=30)
            f = p.stdout.split()
            if p.returncode != 0 or len(f) != 2 or not (f[0].isdigit() and f[1].isdigit()):
                die(f"tmux could not create {s}: {(p.stderr or p.stdout).strip()}")
            ran = argv[7] if len(argv) > 7 else ""
            given = (int(f[0]), r.get("cwd"), ran, int(f[1]))
        else:
            p = subprocess.run(argv, env={**os.environ, **env, "SESSION_LEDGER_EVENT": "resume", "SESSION_LEDGER_REASON": why},  # nosemgrep: dangerous-subprocess-use-audit -- argv list run without a shell; its values are the harness's own paths and settings
                               capture_output=True, text=True, timeout=600)
            print((p.stdout + p.stderr).strip())
            if "(left untouched)" in p.stdout:
                die(f"{s} was started by another start in the meantime: nothing resumed")
            if tmux("has-session", "-t", f"={s}") is None:
                die(f"the start did not bring {s} back (rc {p.returncode})")
            given = None
        print(f"resumed {s}: {text}")
        if r.get("agent") == "scratch" or role == "hub":
            # the start script records a registry spoke's resume itself; a scratch session and the hub are recorded here
            with Locked():
                append([line_for("resume", s, why, reg, r, given, claude_hint=r.get("claude_session"),
                                 agent_hint=r.get("agent"))])
    else:
        die("usage: record | census [--first] | stop-all <reason> | latest [<session>] | resume <session>", 64)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except OSError as e:
        die(f"{LEDGER}: {e}")
