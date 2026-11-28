#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""board.py - the agent's board tool, run as /agent/board.sh (docs/manual/boards.md "Plane board", the board tool).

  board.sh list
      the GOALS - the goals file the autonomy loop fires on (AUTONOMY_LOOP_GOALS), in file order as G1, G2, ... -
      with their done mark and their Plane work item and its state; then the TRACKED work: the project's other work
      items, which the loop never fires on. Without a board on this target (no PLANE_URL), the goals alone.
  board.sh create "<title>" [--note "<text>"]
      TRACK work: a Plane work item in Todo that is not a goal, so the loop does not work on it. The same title
      again answers with the first one's id instead of making a second item.
  board.sh create --goal "<goal>"
      GIVE THE LOOP A GOAL: /agent/goals-add.sh adds "- [ ] <goal>" to the goals file, the loop works on it from its
      next fire, and the mirror (plane-sync.py sync) puts it on the board at once.
  board.sh move <ref> <state>
      tracked work to one of the project's states (Backlog, Todo, In Progress, In Review, Done, Cancelled); a goal to
      done (checked off in the goals file) or open (unchecked), then mirrored. A goal's other states are its fires'.
  board.sh comment <ref> "<text>"
      a comment on the work item of a goal or of tracked work, masked as a fire's result is (plane-sync.py redact)
  <ref> is G<n> (the n-th goal of list) or a work item's id as list prints it (AGENT-12).

Every write takes a path the goals' mirrors do not fight. The goals file is their source of truth: plane-sync.py puts
a goal's work item back to the file's state at every sync and fire, and the Goals board's sync (kanban-sync.py, on
the self-hosted kanban branch) is two-way, so a card created there becomes a goal. So a goal changes only in the
goals file: goals-add.sh's append, or one atomic rewrite of its done mark, both under ${AUTONOMY_LOOP_DIR}/goals.lock
(the lock kanban-sync.py's write-back takes), and no rewrite while the loop is FIRING (a fire edits the file itself).
Tracked work is a Plane work item with a key of its own (external_source do-agent-aws-board), which neither mirror
reads or moves. The shipped default goals (what the loop fires on while there is no goals file) are never edited.

Settings (environment), as plane-sync.py's: PLANE_URL, PLANE_AUTH_FILE, PLANE_WORKSPACE, PLANE_PROJECT,
AUTONOMY_LOOP_GOALS, AUTONOMY_LOOP_DEFAULT_GOALS, AUTONOMY_LOOP_DIR; PLANE_SYNC_TIMEOUT (default 30 s) bounds the
mirror after a goals-file write, BOARD_LOCK_WAIT (default 20 s) the wait for the goals lock.

Exit status: 0 done (a mirror that fails after a goals-file write says so and still exits 0: the file is the record,
and the next sync or fire mirrors it); 1 usage, an unknown ref or state, or a refused write (the line says why);
2 the board is unreachable or answered an error; 3 the API key is refused; 4 bad settings or no board on this
target; 5 the goals file is locked or the loop is firing - nothing written.
"""
import datetime
import fcntl
import importlib.util
import os
import re
import subprocess
import sys
import time
import uuid

AGENT_DIR = os.path.dirname(os.path.realpath(__file__))
# The Plane client, the goal rules and the masking are the mirror's own (plane-sync.py), so both read a goal the same
_spec = importlib.util.spec_from_file_location("plane_sync", os.path.join(AGENT_DIR, "plane-sync.py"))
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)

TRACK_SOURCE = "do-agent-aws-board"  # tracked work's key: not the mirror's (ps.SOURCE), so no mirror touches it
USAGE = """usage: board.sh list                                      the goals (G1, G2, ...) and the tracked work
       board.sh create "<title>" [--note "<text>"]     TRACK work: a Plane work item, not a goal
       board.sh create --goal "<goal>"                  GIVE THE LOOP A GOAL (/agent/goals-add.sh)
       board.sh move <ref> <state>                      tracked work: any state; a goal: done or open
       board.sh comment <ref> "<text>"
<ref>: G<n> (a goal, numbered as list prints them) or a work item id (AGENT-12)"""


class Refused(ps.SyncError):
    def __init__(self, message, code=1):
        super().__init__(code, message)


def config():
    return {
        "url": os.environ.get("PLANE_URL", ""),
        "auth": os.environ.get("PLANE_AUTH_FILE", "/wd/plane/plane.env"),
        "workspace": os.environ.get("PLANE_WORKSPACE", "do-agent-aws") or "do-agent-aws",
        "project": os.environ.get("PLANE_PROJECT", "AGENT") or "AGENT",
        "goals": os.environ.get("AUTONOMY_LOOP_GOALS", "/wd/goals/GOALS.md"),
        "default_goals": os.environ.get("AUTONOMY_LOOP_DEFAULT_GOALS", "/agent/goals-default.md"),
        "loop_dir": os.environ.get("AUTONOMY_LOOP_DIR", "/wd/loop"),
    }


def one_line(text):
    return " ".join((text or "").split())


def norm(name):
    return re.sub(r"[\s_-]+", "", (name or "").lower())


# ------------------------------------------------------------------ goals
def load_goals(cfg):
    """(goals, path, default): the goals file, else the shipped default goals the loop fires on while there is none."""
    goals = ps.parse_goals(cfg["goals"])
    if goals is not None:
        return goals, cfg["goals"], False
    return ps.parse_goals(cfg["default_goals"]) or [], cfg["default_goals"], True


def locate(lines):
    """[(key, line index)] of the goals in file order, by parse_goals' rules (code fences skipped, a repeated text
    numbered)."""
    out, seen, fence = [], {}, False
    for n, line in enumerate(lines):
        s = line.rstrip("\r\n")
        if s.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        m = ps.CHECKBOX.match(s)
        if m:
            text = m.group(2)
        else:
            m = ps.HEADING.match(s)
            if not m:
                continue
            text = " ".join(ps.DONE_MARK.sub("", m.group(1)).split())
            if not re.match(r"(standing\s+)?goal\b", text, re.I):
                continue
        k = seen[text] = seen.get(text, 0) + 1
        out.append((text if k == 1 else f"{text}#{k}", n))
    return out


def marked(line, done):
    """The goal's line with its done mark set or cleared: "- [x] <goal>", or a "## Goal" heading carrying " [x]" at
    its end (the form kanban-sync.py writes)."""
    s = line.rstrip("\r\n")
    end = line[len(s):]
    m = re.match(r"^(\s*[-*]\s+\[)[ xX](\].*)$", s)
    if m:
        return m.group(1) + ("x" if done else " ") + m.group(2) + end
    s = re.sub(r"\[[xX]\]\s*", "", s).rstrip()
    return s + (" [x]" if done else "") + end


def ancestors():
    """The pids this process descends from (its parent, that one's parent, ... up to init)."""
    out, pid = set(), os.getppid()
    while pid > 1 and pid not in out:
        out.add(pid)
        try:
            with open(f"/proc/{pid}/stat") as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return out


def loop_firing(cfg):
    """The loop's fire number while a fire runs (loop.state "FIRING fire=N pid=P ..." with P alive) and the caller is
    not that fire itself, else None. A FIRING line whose process is gone is a killed loop's, not a fire; a call from
    within the fire (the loop's pid among the caller's ancestors) is the fire editing its own goals file."""
    try:
        with open(os.path.join(cfg["loop_dir"], "loop.state")) as f:
            state = f.read()
    except OSError:
        return None
    if state.split(" ", 1)[0] != "FIRING":
        return None
    pid = re.search(r"\bpid=(\d+)", state)
    if pid:
        try:
            os.kill(int(pid.group(1)), 0)
        except ProcessLookupError:
            return None
        except OSError:
            pass
        if int(pid.group(1)) in ancestors():
            return None
    fire = re.search(r"\bfire=(\S+)", state)
    return fire.group(1) if fire else "?"


class GoalsLock:
    """${AUTONOMY_LOOP_DIR}/goals.lock, the lock kanban-sync.py's write-back takes; waits up to BOARD_LOCK_WAIT."""

    def __init__(self, cfg):
        self.path = os.path.join(cfg["loop_dir"], "goals.lock")
        try:
            self.wait = float(os.environ.get("BOARD_LOCK_WAIT", "20"))
        except ValueError:
            raise ps.SyncError(4, "BOARD_LOCK_WAIT must be a number of seconds")

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.f = open(self.path, "w")
        deadline = time.monotonic() + self.wait
        while True:
            try:
                fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError:
                if time.monotonic() >= deadline:
                    self.f.close()
                    raise Refused(f"the goals file is locked ({self.path}) - nothing written; try again", 5)
                time.sleep(0.2)  # nosemgrep: arbitrary-sleep -- retry interval of a bounded lock wait

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def set_done(cfg, key, done):
    """The goal's done mark in the goals file: one atomic rewrite (temp file + rename, the file's mode kept) under
    the goals lock. The file is read again just before the rename and the rewrite redone if it changed meanwhile
    (an append by goals-add.sh, which another caller runs without the lock)."""
    path = cfg["goals"]
    with GoalsLock(cfg):
        for _ in range(3):
            with open(path, encoding="utf-8", newline="") as f:
                before = f.read()
            lines = before.splitlines(keepends=True)
            at = dict(locate(lines)).get(key)
            if at is None:
                raise Refused(f"the goal is no longer in {path}: {key}")
            lines[at] = marked(lines[at], done)
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8", newline="") as f:
                f.write("".join(lines))
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
            with open(path, encoding="utf-8", newline="") as f:
                if f.read() != before:
                    continue
            os.replace(tmp, path)
            break
        else:
            os.unlink(tmp)
            raise Refused(f"{path} kept changing while it was written - nothing written; try again", 5)
    goal = next((g for g in ps.parse_goals(path) or [] if g["key"] == key), None)
    if goal is None or goal["done"] != done:
        raise Refused(f"the done mark did not land in {path}: {key}")


def mirror(cfg):
    """plane-sync.py sync after a goals-file write, bounded; one line says what it did."""
    if not cfg["url"]:
        print("no Plane board on this target (PLANE_URL is not set): the goals file is the record")
        return
    try:
        wait = int(os.environ.get("PLANE_SYNC_TIMEOUT", "30"))
    except ValueError:
        wait = 30
    try:
        r = subprocess.run([sys.executable, "-I", "-B", os.path.join(AGENT_DIR, "plane-sync.py"), "sync"],  # nosemgrep: dangerous-subprocess-use-audit -- argv list run without a shell; its values are the harness's own paths and settings
                           capture_output=True, text=True, timeout=wait)
        out = (r.stdout if r.returncode == 0 else r.stderr).strip().splitlines()
        line = out[-1] if out else f"exit {r.returncode}"
    except subprocess.TimeoutExpired:
        r, line = None, f"no answer within {wait}s (PLANE_SYNC_TIMEOUT)"
    if r is not None and r.returncode == 0:
        print(f"mirrored on the board: {line}")
    else:
        print(f"not mirrored on the board yet ({line}) - the next sync or fire mirrors it")


# ------------------------------------------------------------------ the board
def view(cfg):
    """The project's ids, states and work items."""
    if not cfg["url"]:
        raise ps.SyncError(4, "no Plane board on this target (PLANE_URL is not set): tracked work and comments need "
                              "it; the goals are in " + cfg["goals"])
    board = ps.Board(cfg["url"], ps.load_key(cfg["auth"]), cfg["workspace"])
    project = next((p for p in board.all("/projects/") if p.get("identifier") == cfg["project"]), None)
    if project is None:
        raise ps.SyncError(2, f"no project {cfg['project']} in workspace {cfg['workspace']} (./run.sh seeds it)")
    pid = project["id"]
    states = {s["name"]: s["id"] for s in board.all(f"/projects/{pid}/states/")}
    return {"board": board, "pid": pid, "states": states, "names": {v: k for k, v in states.items()},
            "items": board.all(f"/projects/{pid}/issues/")}


def goal_eid(v, key):
    return str(uuid.uuid5(ps.NS, f"{v['pid']}:goal:{key}"))


def item_ref(cfg, item):
    return f"{cfg['project']}-{item.get('sequence_id')}"


def owned(cfg, v):
    """{external id: (goal, default)} of the work items the mirror keeps: the goals file's and the default goals'."""
    keyed = {}
    for g in ps.parse_goals(cfg["default_goals"]) or []:
        keyed[goal_eid(v, g["key"])] = (g, True)
    for g in ps.parse_goals(cfg["goals"]) or []:
        keyed[goal_eid(v, g["key"])] = (g, False)
    return keyed


def resolve(cfg, ref, need_item):
    """(goal, item, v): a goal (with its work item when the board has one) or tracked work (goal None)."""
    goals, path, default = load_goals(cfg)
    m = re.fullmatch(r"[Gg](\d+)", ref or "")
    if m:
        n = int(m.group(1))
        if not 1 <= n <= len(goals):
            raise Refused(f"no goal G{n}: {path} has {len(goals)} (board.sh list)")
        goal = dict(goals[n - 1], number=n, default=default)
        if not need_item:
            return goal, None, None
        v = view(cfg)
        eid = goal_eid(v, goal["key"])
        item = next((i for i in v["items"]
                     if i.get("external_source") == ps.SOURCE and i.get("external_id") == eid), None)
        return goal, item, v
    m = re.fullmatch(r"([A-Za-z][A-Za-z0-9]*)-(\d+)", ref or "")
    if not m or m.group(1).upper() != cfg["project"].upper():
        raise Refused(f"not a goal (G<n>) or a work item id of project {cfg['project']} ({cfg['project']}-<n>): "
                      f"{ref!r}")
    v = view(cfg)
    item = next((i for i in v["items"] if str(i.get("sequence_id")) == str(int(m.group(2)))), None)
    if item is None:
        raise Refused(f"no work item {ref} on the board (board.sh list)")
    hit = owned(cfg, v).get(item.get("external_id")) if item.get("external_source") == ps.SOURCE else None
    if hit is None:
        return None, item, v
    goal, is_default = hit
    number = next((n for n, g in enumerate(goals, 1) if g["key"] == goal["key"]), None) if is_default == default \
        else None
    return dict(goal, number=number, default=is_default), item, v


def cmd_list(cfg):
    goals, path, default = load_goals(cfg)
    v, err = None, None
    if cfg["url"]:
        try:
            v = view(cfg)
        except ps.SyncError as e:
            err = e
    mirrored = {i.get("external_id"): i for i in (v["items"] if v else []) if i.get("external_source") == ps.SOURCE}
    print(f"Goals in {path}" + (" (the shipped default goals: there is no goals file yet)" if default else "")
          + " - the autonomy loop fires on these, the first open one first:")
    for n, g in enumerate(goals, 1):
        item = mirrored.get(goal_eid(v, g["key"])) if v else None
        ref = item_ref(cfg, item) if item else "-"
        state = v["names"].get(item.get("state"), "?") if item else ("not on the board yet" if v else "-")
        print(f"  G{n:<3} [{'x' if g['done'] else ' '}]  {ref:<10} {state:<12} {g['title']}")
    if not goals:
        print("  (none)")
    if not cfg["url"]:
        print("Tracked work: no Plane board on this target (PLANE_URL is not set)")
        return 0
    if err:
        print(f"Tracked work: the board did not answer - {err}")
        return err.code
    keep = owned(cfg, v)
    tracked = sorted((i for i in v["items"]
                      if not (i.get("external_source") == ps.SOURCE and i.get("external_id") in keep)),
                     key=lambda i: i.get("sequence_id") or 0)
    print(f"Tracked work on Plane project {cfg['project']} - not goals; the loop never fires on these:")
    for i in tracked:
        former = " (a former goal, no longer in the goals file)" if i.get("external_source") == ps.SOURCE else ""
        print(f"  {item_ref(cfg, i):<10} {v['names'].get(i.get('state'), '?'):<12} {i.get('name')}{former}")
    if not tracked:
        print("  (none)")
    return 0


def cmd_track(cfg, title, note):
    title = one_line(title)
    if not title:
        raise Refused("a tracked item needs a title\n" + USAGE)
    v = view(cfg)
    if ps.TODO not in v["states"]:
        raise ps.SyncError(2, f"project {cfg['project']} has no state {ps.TODO}")
    name = ps.redact(title, cfg["auth"])[:250]
    description = ((ps._html(ps.redact(note, cfg["auth"])) if (note or "").strip() else "")
                   + "<p><em>Tracked with /agent/board.sh: a work item, not a goal - the autonomy loop does not work "
                     "on it.</em></p>")
    eid = str(uuid.uuid5(ps.NS, f"{v['pid']}:track:{name}"))
    code, payload = v["board"].call("POST", f"/projects/{v['pid']}/issues/", {
        "name": name, "description_html": description, "state": v["states"][ps.TODO], "priority": "none",
        "external_source": TRACK_SOURCE, "external_id": eid}, ok=(200, 201, 409))
    if code == 409:
        item = next((i for i in view(cfg)["items"] if i.get("id") == payload.get("id")), {})
        print(f"already tracked as {item_ref(cfg, item)}: {name} - nothing created")
        return 0
    print(f"tracked {item_ref(cfg, payload)}: {name} ({ps.TODO}) - not a goal; the autonomy loop does not work on it")
    return 0


def cmd_goal(cfg, goal):
    goal = one_line(goal)
    if not goal:
        raise Refused("a goal needs its text\n" + USAGE)
    if goal.startswith("-"):
        raise Refused(f"a goal does not start with '-': {goal!r}")
    with GoalsLock(cfg):
        # bash -p: not the caller's BASH_ENV or exported functions
        r = subprocess.run(["/bin/bash", "-p", os.path.join(AGENT_DIR, "goals-add.sh"), goal],
                           capture_output=True, text=True, timeout=30)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        raise Refused(f"goals-add.sh did not add the goal (exit {r.returncode})")
    for line in r.stdout.strip().splitlines()[1:]:
        print(line)
    print(f"goal added to {cfg['goals']}: {goal} - the autonomy loop works on it from its next fire")
    mirror(cfg)
    return 0


def cmd_move(cfg, ref, state):
    want = norm(state)
    if not want:
        raise Refused("move needs a state\n" + USAGE)
    goal, item, v = resolve(cfg, ref, need_item=not re.fullmatch(r"[Gg]\d+", ref or ""))
    if goal is not None:
        name = f"G{goal['number']}" if goal.get("number") else ref
        if goal["default"]:
            raise Refused(f"{name} is one of the shipped default goals ({cfg['default_goals']}), which this tool does "
                          "not edit; give the loop a goal of its own with board.sh create --goal")
        if want not in ("done", "open", "todo"):
            raise Refused(f"{name} is a goal: its work item follows the goals file and the loop's fires (plane-sync.py "
                          f"puts it back at the next sync), so it moves only to done or open, not {state!r}")
        done = want == "done"
        if goal["done"] == done:
            print(f"{name} is already {'done' if done else 'open'} in {cfg['goals']}: {goal['title']}")
            return 0
        fire = loop_firing(cfg)
        if fire:
            raise Refused(f"the autonomy loop is firing (fire {fire}) and edits the goals file itself - nothing "
                          "written; try again when the fire ends (/agent/loop-status.sh)", 5)
        set_done(cfg, goal["key"], done)
        print(f"{name} {'checked off' if done else 'unchecked'} in {cfg['goals']}: {goal['title']}")
        mirror(cfg)
        return 0
    target = next((n for n in v["states"] if norm(n) == want), None)
    if target is None:
        raise Refused(f"no state {state!r} in project {cfg['project']}: {', '.join(v['states'])}")
    if item.get("state") == v["states"][target]:
        print(f"{ref} is already {target}: {item.get('name')}")
        return 0
    v["board"].call("PATCH", f"/projects/{v['pid']}/issues/{item['id']}/", {"state": v["states"][target]})
    print(f"{item_ref(cfg, item)} -> {target}: {item.get('name')}")
    return 0


def cmd_comment(cfg, ref, text):
    if not (text or "").strip():
        raise Refused("comment needs its text\n" + USAGE)
    goal, item, v = resolve(cfg, ref, need_item=True)
    if item is None:
        raise Refused(f"{ref} has no work item on the board yet - the next sync or fire mirrors it (board.sh list)")
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    cid = str(uuid.uuid5(ps.NS, f"{v['pid']}:comment:{item['id']}:{day}:{text}"))
    code, _ = v["board"].call("POST", f"/projects/{v['pid']}/issues/{item['id']}/comments/", {
        "comment_html": ps._html(ps.redact(text, cfg["auth"])), "external_source": TRACK_SOURCE,
        "external_id": cid}, ok=(200, 201, 409))
    print(f"commented on {item_ref(cfg, item)}: {item.get('name')}"
          + (" - the same comment was already posted today, nothing added" if code == 409 else ""))
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        return 0 if argv else 1
    verb, args = argv[0], argv[1:]
    cfg = config()
    try:
        if verb == "list" and not args:
            return cmd_list(cfg)
        if verb == "create" and len(args) == 2 and args[0] == "--goal":
            return cmd_goal(cfg, args[1])
        if verb == "create" and len(args) in (1, 3) and not args[0].startswith("--") and args[1:2] in ([], ["--note"]):
            return cmd_track(cfg, args[0], args[2] if len(args) == 3 else "")
        if verb == "move" and len(args) >= 2:
            return cmd_move(cfg, args[0], " ".join(args[1:]))
        if verb == "comment" and len(args) == 2:
            return cmd_comment(cfg, args[0], args[1])
    except ps.SyncError as e:
        print(f"board.sh: {e}", file=sys.stderr)
        return e.code
    print(USAGE, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
