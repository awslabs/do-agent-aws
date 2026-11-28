#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""supervisor-plan.py - the deterministic planner of the autonomy loop's supervisor (chief-of-staff) mode.

docs/manual/autonomy.md "Supervisor mode". Stdlib only; run it with `python3 -I`.

  supervisor-plan.py --goals GOALS.md [--notes notes.md] [--notes-tail 200] [--max-workers 3]
                     [--locks-dir DIR] [--parked FILE] [--json plan.json] [--explain]
  supervisor-plan.py --set-priority G<n>|L<line> high|low|normal --goals GOALS.md [--lock PATH]
  supervisor-plan.py --mark G<n>|L<line> [--note TEXT] [--allowed-hashes "h1 h2"] --goals GOALS.md [--lock PATH]
  supervisor-plan.py --unpark G<n>|L<line> --supervisor-dir DIR --goals GOALS.md
  supervisor-plan.py --selftest

What it does: reads the goals with the board mirrors' rules (checkbox items and `## Goal` headings, code fences
skipped, goal_key = the text without its leading parenthesised notes), takes the OPEN goals, derives each goal's
priority (a leading note `(priority: high|low)`), its resource keys (path:, thread:, answer:, account:, explicit:) from
the goal text plus the notes lines that name it, groups goals that share a resource into one SERIAL CHAIN (union-find),
orders the groups by priority then file order, and prints the plan (text) or writes it (--json) for loop.sh. It can only
over-merge: a false shared key makes two goals serial, which costs speed, never correctness.

Keep CHECKBOX, HEADING, DONE_MARK and strip_note() identical to plane-sync.py / kanban-sync.py: the mirrors key a card
by the same goal_key, which is why the priority marker is a leading note (it changes no card key).

G<n> is board.sh's numbering: the n-th goal item in file order, done ones included. Every record prints `G<n> (line L)`.

Exit codes: 0 ok (selftest: every check passed); 1 selftest failed; 2 usage; 3 goals file unreadable (plan,
--set-priority) or, for --mark, the goal is not one of --allowed-hashes (not this worker's goal); 4 goal not found,
not a checkbox item or (--mark) already done; 5 goals lock busy; 6 the line changed under us, the written line did not
read back as expected or (--mark) the note would change the goal key; 7 (--mark) goals file unreadable.

--mark is the write behind goals-mark.sh (design section 7): the one way a supervisor worker marks a goal done. With
--allowed-hashes (the worker's WORKER_GOAL_HASHES, space-separated) a goal whose hash is not listed is refused with
rc 3 and nothing is written; an EMPTY value refuses every goal (a fire that is not a worker). Without the option there
is no ownership gate (the loop's own use). The note becomes a leading parenthesised note, so goal_key does not change.

--unpark is the write behind goals-add.sh --unpark (design section 8, the operator's "retry G<n>"): every line whose
first field is the goal's hash leaves DIR/parked and DIR/strikes.tsv (DIR = ${AUTONOMY_LOOP_DIR}/supervisor), under
DIR/strikes.lock; the goals file is only read. Exit 0 (also when nothing was parked), 2 usage, 3 goals unreadable,
4 no such goal or a heading, 5 strikes lock busy. Both files are hash-first: parked = `<hash>\\t<since cycle>\\t<until
cycle>\\t<utc>`, strikes.tsv = `<hash>\\t<fire>\\t<rc>\\t<utc>`; `#` lines are comments and stay.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
import time

# ------------------------------------------------------------------ goals (the rules of plane-sync.py / kanban-sync.py)
CHECKBOX = re.compile(r"^\s*[-*]\s+\[([ xX])\]\s+(\S.*?)\s*$")
HEADING = re.compile(r"^##\s+(\S.*?)\s*$")
DONE_MARK = re.compile(r"\[[xX]\]")

# ------------------------------------------------------------------ markers and resource keys
PRIORITY_RANK = {"high": 1, "normal": 2, "low": 3}
PRIORITY_NOTE = re.compile(r"^\(\s*priority\s*:\s*(high|normal|low)\s*\)$", re.I)
SERIAL_WITH = re.compile(r"\(\s*serial-with\s*:\s*G(\d+)\s*\)", re.I)
AFTER = re.compile(r"\(\s*after\s*:\s*G(\d+)\s*\)", re.I)
PATH = re.compile(r"(?<![\w:.\-/])(/[A-Za-z0-9_.@+-]+(?:/[A-Za-z0-9_.@+-]+)+)")
FROM_SLACK = re.compile(r"\(from Slack (\S+) (\d{9,11}\.\d{3,6})\)")
THREAD = re.compile(r"\bthread\s+(\d{9,11}\.\d{3,6})", re.I)
QA_BRACKET = re.compile(r"\[(QUESTION|ACTION)\s+(\d+)\]", re.I)
QA_SHORT = re.compile(r"\b([QA])(\d{1,3})\b")
ACCOUNT_DIGITS = re.compile(r"\baccount\s+(?:\.\.\.)?(\d{4,12})\b", re.I)
PROFILE = re.compile(r"(--profile|\bprofile)\s+([A-Za-z0-9][A-Za-z0-9_.-]*)", re.I)
ACCOUNT_WORD = re.compile(r"--account\s+([A-Za-z0-9_-]+)|\b(vended|sa)\s+account\b|\baccount\s+(vended|sa)\b", re.I)
NOTE_GOAL_REF = re.compile(r"\bG(\d+)\b|\bline\s+(\d+)\b")


def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def leading_notes(text):
    """([note, ...], rest): the run of leading parenthesised notes of a goal text and the text after them, with
    strip_note's rule - an unbalanced note, or a text that is nothing but a note, stays in the rest."""
    t = (text or "").strip()
    notes = []
    while t.startswith("("):
        depth, end = 0, -1
        for i, ch in enumerate(t):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        rest = t[end + 1:].strip() if end >= 0 else ""
        if not rest:
            break
        notes.append(t[:end + 1])
        t = rest
    return notes, t


def strip_note(text):
    return leading_notes(text)[1]


def goal_key(text):
    return strip_note(text)


def key_hash(key):
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]


def parse_goals(path):
    """([goal, ...] in file order, raw text). goal = {index, id, line, kind, text, body, done, key, hash}."""
    with open(path, encoding="utf-8", errors="replace") as f:
        raw = f.read()
    lines = raw.splitlines()
    goals, seen, fence, heading_goal = [], {}, False, None
    for lineno, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        m = CHECKBOX.match(line)
        if m:
            goals.append({"text": m.group(2), "done": m.group(1) in "xX", "line": lineno, "kind": "item"})
            continue
        m = HEADING.match(line)
        if m:
            heading_goal = None
            text = " ".join(DONE_MARK.sub("", m.group(1)).split())
            if re.match(r"(standing\s+)?goal\b", text, re.I):
                heading_goal = {"text": text, "done": bool(DONE_MARK.search(m.group(1))), "line": lineno,
                                "kind": "heading", "lines": []}
                goals.append(heading_goal)
            continue
        if heading_goal is not None and line.strip():
            heading_goal["lines"].append(line.strip())
    for n, g in enumerate(goals, 1):
        body_lines = g.pop("lines", None)
        g["body"] = "\n".join(body_lines)[:2000] if body_lines else g["text"]
        base = goal_key(g["text"])
        k = seen[base] = seen.get(base, 0) + 1
        g["key"] = base if k == 1 else "%s#%d" % (base, k)
        g["index"] = n
        g["id"] = "G%d (line %d)" % (n, g["line"])
        g["hash"] = key_hash(g["key"])
    return goals, raw


def reduce_path(p):
    """A path to the resource it belongs to: the first three components; four for a checkout under /wd/projects
    (five under /do-agent-aws/wd/projects); anything else under /do-agent-aws is the source tree, one resource."""
    parts = [x for x in p.split("/") if x]
    if not parts:
        return None
    if parts[0] == "do-agent-aws":
        if len(parts) >= 3 and parts[1] == "wd" and parts[2] == "projects":
            return "/" + "/".join(parts[:5])
        return "/do-agent-aws"
    if parts[0] == "wd" and len(parts) >= 2 and parts[1] == "projects":
        return "/" + "/".join(parts[:4])
    return "/" + "/".join(parts[:3])


def extract_keys(text, kinds=("path", "thread", "answer", "account")):
    keys = set()
    if "path" in kinds:
        for p in PATH.findall(text):
            r = reduce_path(p)
            if r:
                keys.add("path:" + r)
    if "thread" in kinds:
        for _ch, ts in FROM_SLACK.findall(text):
            keys.add("thread:" + ts)
        for ts in THREAD.findall(text):
            keys.add("thread:" + ts)
    if "answer" in kinds:
        for kind, n in QA_BRACKET.findall(text):
            keys.add("answer:%s%d" % (kind[0].upper(), int(n)))
        for kind, n in QA_SHORT.findall(text):
            keys.add("answer:%s%d" % (kind, int(n)))
    if "account" in kinds:
        for d in ACCOUNT_DIGITS.findall(text):
            keys.add("account:" + d)
        for m in PROFILE.finditer(text):
            name = m.group(2)
            if m.group(1).startswith("--") or re.search(r"[-_0-9]", name):
                keys.add("account:profile=" + name)
        for m in ACCOUNT_WORD.finditer(text):
            w = m.group(1) or m.group(2) or m.group(3)
            keys.add("account:" + w.lower())
    return keys


def goal_markers(g):
    notes, _rest = leading_notes(g["text"])
    prio = "normal"
    for n in notes:
        m = PRIORITY_NOTE.match(n)
        if m:
            prio = m.group(1).lower()
    text = g["text"] + "\n" + g.get("body", "")
    serial = [int(x) for x in SERIAL_WITH.findall(text)]
    after = [int(x) for x in AFTER.findall(text)]
    return prio, serial, after


def notes_keys_by_goal(notes_path, tail, goals):
    """{goal index: set(path:/thread: keys)} from the last `tail` notes lines that name a goal by G<index>, G<line>
    (the notes' own convention) or `line <L>`. A lead, not a measurement: over-attaching only merges more."""
    out = {}
    if not notes_path or not os.path.exists(notes_path):
        return out, 0
    with open(notes_path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    if tail > 0:
        lines = lines[-tail:]
    by_index = {g["index"]: g for g in goals}
    by_line = {g["line"]: g for g in goals}
    for line in lines:
        refs = set()
        for a, b in NOTE_GOAL_REF.findall(line):
            if a:
                n = int(a)
                if n in by_index:
                    refs.add(n)
                if n in by_line:
                    refs.add(by_line[n]["index"])
            if b:
                n = int(b)
                if n in by_line:
                    refs.add(by_line[n]["index"])
        if not refs:
            continue
        keys = extract_keys(line, kinds=("path", "thread"))
        if not keys:
            continue
        for idx in refs:
            out.setdefault(idx, set()).update(keys)
    return out, len(lines)


def order_members(members, by_index):
    """Priority, then file order; an `(after: G<n>)` marker moves a goal right behind its target."""
    ms = sorted(members, key=lambda m: (m["rank"], m["index"]))
    idxs = {m["index"] for m in ms}
    for _ in range(len(ms) * len(ms) + 1):
        moved = False
        for m in list(ms):
            for t in m["after"]:
                if t in idxs and t != m["index"]:
                    i, j = ms.index(m), ms.index(by_index[t])
                    if i < j:
                        ms.pop(i)
                        ms.insert(j, m)
                        moved = True
                        break
            if moved:
                break
        if not moved:
            break
    return ms


def lock_path_for(locks_dir, key):
    return os.path.join(locks_dir, hashlib.sha256(key.encode("utf-8")).hexdigest() + ".lock")


def locks_busy(locks_dir, keys):
    """The keys whose lock file is held by someone (flock non-blocking probe, released at once)."""
    busy = []
    for k in sorted(keys):
        fd = os.open(lock_path_for(locks_dir, k), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
        except (BlockingIOError, OSError):
            busy.append(k)
        finally:
            os.close(fd)
    return busy


def plan(goals, notes_keys, max_workers, locks_dir=None, parked=frozenset()):
    open_goals = [g for g in goals if not g["done"]]
    by_index = {g["index"]: g for g in open_goals}
    for g in open_goals:
        prio, serial, after = goal_markers(g)
        g["priority"], g["rank"] = prio, PRIORITY_RANK[prio]
        g["serial_with"], g["after"] = serial, after
        text_keys = extract_keys(g["text"] + "\n" + g["body"])
        note_keys = set(notes_keys.get(g["index"], set()))
        g["resources_text"] = sorted(text_keys)
        g["resources_notes"] = sorted(note_keys - text_keys)
        g["resources"] = sorted(text_keys | note_keys | {"goal:" + g["hash"]})
    parent = {g["index"]: g["index"] for g in open_goals}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    owner, bonds, unresolved = {}, {}, []
    for g in open_goals:
        for k in g["resources"]:
            if k.startswith("goal:"):
                continue
            bonds.setdefault(k, set()).add(g["index"])
            if k in owner:
                union(owner[k], g["index"])
            else:
                owner[k] = g["index"]
    for g in open_goals:
        for t in g["serial_with"] + g["after"]:
            if t in by_index:
                union(g["index"], t)
                bonds.setdefault("explicit:G%d" % t, set()).update({g["index"], t})
            else:
                unresolved.append("%s -> G%d (not an open goal)" % (g["id"], t))
    groups = {}
    for g in open_goals:
        groups.setdefault(find(g["index"]), []).append(g)
    glist = []
    for members in groups.values():
        ms = order_members(members, by_index)
        idxs = {m["index"] for m in ms}
        shared = sorted(k for k, s in bonds.items() if len(s & idxs) >= 2)
        glist.append({"members": ms, "keys": shared, "rank": min(m["rank"] for m in ms),
                      "pos": min(m["index"] for m in ms)})
    glist.sort(key=lambda x: (x["rank"], x["pos"]))
    for i, grp in enumerate(glist, 1):
        grp["id"] = "g%d" % i
    dispatch, waiting, blocked, parked_groups = [], [], [], []
    for grp in glist:
        if any(m["hash"] in parked for m in grp["members"]):
            parked_groups.append(grp)
            continue
        if len(dispatch) >= max_workers:
            waiting.append(grp)
            continue
        busy = []
        if locks_dir:
            all_keys = set()
            for m in grp["members"]:
                all_keys.update(m["resources"])
            busy = locks_busy(locks_dir, all_keys)
        if busy:
            grp["busy"] = busy
            blocked.append(grp)
            continue
        dispatch.append(grp)
    order = [m for grp in glist for m in grp["members"]]
    return {"open": open_goals, "groups": glist, "order": order, "dispatch": dispatch, "waiting": waiting,
            "blocked": blocked, "parked": parked_groups, "unresolved": unresolved}


def gid(grp):
    return "%s %s [%s]" % (grp["id"], "P%d" % grp["rank"], " -> ".join(m["id"] for m in grp["members"]))


def render(p, args, total, notes_read):
    out = []
    out.append("supervisor-plan %s goals=%s total=%d open=%d max-workers=%d notes=%s(%d lines) locks=%s parked=%d" % (
        utc(), args.goals, total, len(p["open"]), args.max_workers, args.notes or "-", notes_read,
        args.locks_dir or "-", sum(len(g["members"]) for g in p["parked"])))
    out.append("order (priority, then file order; a chain stays together):")
    for i, m in enumerate(p["order"], 1):
        out.append("  %d. %s P%d h=%s | %s" % (i, m["id"], m["rank"], m["hash"], m["key"][:90]))
    out.append("groups (goals sharing a resource = one serial chain, one worker):")
    for grp in p["groups"]:
        out.append("  %s keys: %s" % (gid(grp), ", ".join(grp["keys"]) if grp["keys"] else "-"))
    out.append("dispatch (max-workers %d): %s" % (args.max_workers, " ".join(g["id"] for g in p["dispatch"]) or "-"))
    out.append("waiting: %s" % (" ".join(g["id"] for g in p["waiting"]) or "-"))
    out.append("blocked (lock busy): %s" % ("; ".join("%s <- %s" % (g["id"], ", ".join(g["busy"])) for g in p["blocked"]) or "-"))
    out.append("parked: %s" % (" ".join(g["id"] for g in p["parked"]) or "-"))
    if p["unresolved"]:
        out.append("explicit markers ignored: %s" % "; ".join(p["unresolved"]))
    if args.explain:
        out.append("explain:")
        for m in p["order"]:
            out.append("  %s text-keys: %s" % (m["id"], ", ".join(k for k in m["resources_text"]) or "-"))
            if m["resources_notes"]:
                out.append("  %s notes-keys: %s" % (m["id"], ", ".join(m["resources_notes"])))
            if m["serial_with"] or m["after"]:
                out.append("  %s explicit: serial-with=%s after=%s" % (m["id"], m["serial_with"], m["after"]))
        for grp in p["groups"]:
            ms = grp["members"]
            for i in range(len(ms)):
                for j in range(i + 1, len(ms)):
                    shared = sorted((set(ms[i]["resources"]) & set(ms[j]["resources"])) - {k for k in ms[i]["resources"] if k.startswith("goal:")})
                    expl = [("explicit:G%d" % t) for t in ms[i]["serial_with"] + ms[i]["after"] if t == ms[j]["index"]]
                    expl += [("explicit:G%d" % t) for t in ms[j]["serial_with"] + ms[j]["after"] if t == ms[i]["index"]]
                    out.append("  %s | %s and %s share: %s" % (grp["id"], ms[i]["id"], ms[j]["id"], ", ".join(shared + expl) or "(via a third goal)"))
    return "\n".join(out)


def to_json(p, args, total, notes_read):
    def goal_dict(m):
        return {"id": m["id"], "index": m["index"], "line": m["line"], "hash": m["hash"], "key": m["key"],
                "priority": m["priority"], "resources": m["resources"], "resources_from_notes": m["resources_notes"],
                "serial_with": m["serial_with"], "after": m["after"], "text": m["text"]}

    def group_dict(grp):
        d = {"id": grp["id"], "priority": grp["rank"], "goals": [goal_dict(m) for m in grp["members"]],
             "keys": grp["keys"], "lock_keys": sorted({k for m in grp["members"] for k in m["resources"]})}
        if grp.get("busy"):
            d["busy"] = grp["busy"]
        return d
    return {"planner": "supervisor-plan.py", "version": 1, "generated": utc(), "goals_file": args.goals,
            "notes_file": args.notes, "notes_lines_read": notes_read, "total": total, "open": len(p["open"]),
            "max_workers": args.max_workers, "order": [m["id"] for m in p["order"]],
            "groups": [group_dict(g) for g in p["groups"]], "dispatch": [g["id"] for g in p["dispatch"]],
            "waiting": [g["id"] for g in p["waiting"]], "blocked": [g["id"] for g in p["blocked"]],
            "parked": [g["id"] for g in p["parked"]], "unresolved_markers": p["unresolved"]}


def read_parked(path):
    if not path or not os.path.exists(path):
        return frozenset()
    with open(path, encoding="utf-8", errors="replace") as f:
        return frozenset(x.strip().split()[0] for x in f if x.strip() and not x.startswith("#"))


def run_plan(args):
    try:
        goals, _raw = parse_goals(args.goals)
    except OSError as e:
        print("supervisor-plan: cannot read %s: %s" % (args.goals, e), file=sys.stderr)
        return 3
    notes_keys, notes_read = notes_keys_by_goal(args.notes, args.notes_tail, goals)
    p = plan(goals, notes_keys, args.max_workers, args.locks_dir, read_parked(args.parked))
    print(render(p, args, len(goals), notes_read))
    if args.json:
        tmp = args.json + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(to_json(p, args, len(goals), notes_read), f, indent=1, sort_keys=True)
            f.write("\n")
        os.replace(tmp, args.json)
        print("json: %s" % args.json)
    return 0


# ------------------------------------------------------------------ --set-priority (the one in-place edit)
def set_priority(goals_path, target, level, lock_path=None, out=sys.stdout):
    m = re.fullmatch(r"([GL])(\d+)", target or "")
    if not m or level not in PRIORITY_RANK:
        print("set-priority: usage G<n>|L<line> high|low|normal", file=sys.stderr)
        return 2
    try:
        goals, raw = parse_goals(goals_path)
    except OSError as e:
        print("set-priority: cannot read %s: %s" % (goals_path, e), file=sys.stderr)
        return 3
    n = int(m.group(2))
    g = next((x for x in goals if (x["index"] if m.group(1) == "G" else x["line"]) == n), None)
    if g is None:
        print("set-priority: no goal %s in %s" % (target, goals_path), file=sys.stderr)
        return 4
    if g["kind"] != "item":
        print("set-priority: %s is a `## Goal` heading; only checkbox items take a priority marker" % g["id"], file=sys.stderr)
        return 4
    notes, rest = leading_notes(g["text"])
    kept = [x for x in notes if not PRIORITY_NOTE.match(x)]
    new_notes = (["(priority: %s)" % level] if level != "normal" else []) + kept
    new_text = " ".join(new_notes + [rest])
    if goal_key(new_text) != goal_key(g["text"]):
        print("set-priority: refused, the goal key would change: %r -> %r" % (goal_key(g["text"]), goal_key(new_text)), file=sys.stderr)
        return 6
    lines = raw.splitlines()
    old_line = lines[g["line"] - 1]
    cm = CHECKBOX.match(old_line)
    new_line = old_line[:cm.start(2)] + new_text
    if new_line == old_line:
        print("set-priority %s %s: unchanged (line %d already reads so)" % (g["id"], level, g["line"]), file=out)
        return 0
    rc = replace_line(goals_path, g["line"], old_line, new_line, lock_path, "set-priority")
    if rc:
        return rc
    print("set-priority %s %s: line %d\n  - %s\n  + %s\n  key unchanged: %s" % (
        g["id"], level, g["line"], old_line, new_line, goal_key(new_text) == goal_key(g["text"])), file=out)
    return 0


def replace_line(goals_path, lineno, old_line, new_line, lock_path, who):
    """Replace exactly one line of the goals file: non-blocking flock on <goals>.lock, a re-read that refuses when the
    line changed since the caller read it, an atomic replace of the whole file, and a read-back of the written line.
    Returns 0 ok; 5 lock busy; 6 changed under us or did not read back (nothing written in both cases)."""
    lock_path = lock_path or goals_path + ".lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError):
            print("%s: goals lock busy (%s), try again" % (who, lock_path), file=sys.stderr)
            return 5
        with open(goals_path, encoding="utf-8", errors="replace") as f:
            raw2 = f.read()
        lines2 = raw2.splitlines()
        if len(lines2) < lineno or lines2[lineno - 1] != old_line:
            print("%s: line %d changed under us, nothing written" % (who, lineno), file=sys.stderr)
            return 6
        lines2[lineno - 1] = new_line
        text = "\n".join(lines2) + ("\n" if raw2.endswith("\n") else "")
        d = os.path.dirname(os.path.abspath(goals_path)) or "."
        tfd, tpath = tempfile.mkstemp(prefix=".goals-", suffix=".tmp", dir=d)
        with os.fdopen(tfd, "w", encoding="utf-8") as f:
            f.write(text)
        try:
            os.chmod(tpath, os.stat(goals_path).st_mode & 0o7777)
        except OSError:
            pass
        os.replace(tpath, goals_path)
        with open(goals_path, encoding="utf-8", errors="replace") as f:
            back = f.read().splitlines()
        if len(back) < lineno or back[lineno - 1] != new_line:
            print("%s: the written line did not read back" % who, file=sys.stderr)
            return 6
    finally:
        os.close(fd)
    return 0


# ------------------------------------------------------------------ --unpark (the write behind goals-add.sh --unpark)
def _drop_hash_lines(path, h):
    """Remove every line of a hash-first file whose first field is h (atomic replace; `#` lines stay).
    Returns (removed, kept), or None when the file does not exist."""
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    keep = [x for x in lines if not (x.strip() and not x.lstrip().startswith("#") and x.split()[0] == h)]
    removed = len(lines) - len(keep)
    if removed:
        d = os.path.dirname(os.path.abspath(path)) or "."
        tfd, tpath = tempfile.mkstemp(prefix=".unpark-", suffix=".tmp", dir=d)
        with os.fdopen(tfd, "w", encoding="utf-8") as f:
            f.write("".join(x + "\n" for x in keep))
        try:
            os.chmod(tpath, os.stat(path).st_mode & 0o7777)
        except OSError:
            pass
        os.replace(tpath, path)
    return removed, len(keep)


def unpark(goals_path, target, sup_dir, out=sys.stdout):
    """Clear one goal's parking and strikes (design section 8: the operator's "retry G<n>"): every line whose first
    field is the goal's hash leaves <sup_dir>/parked and <sup_dir>/strikes.tsv, under <sup_dir>/strikes.lock
    (non-blocking). The goals file is only read. Returns 0 (also when nothing was parked), 2 usage, 3 goals file
    unreadable, 4 no such goal or a `## Goal` heading, 5 strikes lock busy."""
    m = re.fullmatch(r"([GL])(\d+)", target or "")
    if not m or not sup_dir:
        print("unpark: usage --unpark G<n>|L<line> --supervisor-dir DIR", file=sys.stderr)
        return 2
    try:
        goals, _raw = parse_goals(goals_path)
    except OSError as e:
        print("unpark: cannot read %s: %s" % (goals_path, e), file=sys.stderr)
        return 3
    n = int(m.group(2))
    g = next((x for x in goals if (x["index"] if m.group(1) == "G" else x["line"]) == n), None)
    if g is None:
        print("unpark: no goal %s in %s" % (target, goals_path), file=sys.stderr)
        return 4
    if g["kind"] != "item":
        print("unpark: %s is a `## Goal` heading; only checkbox items are parked" % g["id"], file=sys.stderr)
        return 4
    parked_path, strikes_path = os.path.join(sup_dir, "parked"), os.path.join(sup_dir, "strikes.tsv")
    if not (os.path.exists(parked_path) or os.path.exists(strikes_path)):
        print("unpark %s (hash %s): nothing parked, no strikes (%s holds no parked or strikes.tsv file)" % (
            g["id"], g["hash"], sup_dir), file=out)
        return 0
    lock_path = os.path.join(sup_dir, "strikes.lock")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError):
            print("unpark: strikes lock busy (%s), try again" % lock_path, file=sys.stderr)
            return 5
        rp = _drop_hash_lines(parked_path, g["hash"])
        rs = _drop_hash_lines(strikes_path, g["hash"])
    finally:
        os.close(fd)
    n_p, n_s = (rp[0] if rp else 0), (rs[0] if rs else 0)
    print("unpark %s (hash %s): %d parked line(s) and %d strike(s) removed%s" % (
        g["id"], g["hash"], n_p, n_s, "" if (n_p or n_s) else " - nothing was parked"), file=out)
    return 0


# ------------------------------------------------------------------ --mark (the write behind goals-mark.sh)
def mark_done(goals_path, target, note=None, allowed=None, lock_path=None, out=sys.stdout):
    """Flip one OPEN checkbox goal to `- [x]`, prefixing an optional parenthesised note (the completion form the fires
    write by hand today, so goal_key and the cards stay). allowed: None = no ownership gate; a set of hashes = the goal's
    hash must be in it (a worker's WORKER_GOAL_HASHES), an empty set refuses every goal."""
    m = re.fullmatch(r"([GL])(\d+)", target or "")
    if not m:
        print("mark: usage --mark G<n>|L<line> [--note TEXT] [--allowed-hashes 'h1 h2']", file=sys.stderr)
        return 2
    try:
        goals, raw = parse_goals(goals_path)
    except OSError as e:
        print("mark: cannot read %s: %s" % (goals_path, e), file=sys.stderr)
        return 7
    n = int(m.group(2))
    g = next((x for x in goals if (x["index"] if m.group(1) == "G" else x["line"]) == n), None)
    if g is None:
        print("mark: no goal %s in %s" % (target, goals_path), file=sys.stderr)
        return 4
    if g["kind"] != "item":
        print("mark: %s is a `## Goal` heading; only checkbox items are flipped here" % g["id"], file=sys.stderr)
        return 4
    if g["done"]:
        print("mark: %s is already done (line %d reads `[x]`); nothing written" % (g["id"], g["line"]), file=sys.stderr)
        return 4
    if allowed is not None and g["hash"] not in allowed:
        if allowed:
            print("mark: %s (hash %s) is not one of this worker's goals (%s); nothing written" % (
                g["id"], g["hash"], " ".join(sorted(allowed))), file=sys.stderr)
        else:
            print("mark: WORKER_GOAL_HASHES is empty - only a supervisor worker, given its goals by the loop, marks a "
                  "goal through this path; nothing written", file=sys.stderr)
        return 3
    note = " ".join((note or "").split())
    if note and not (note.startswith("(") and note.endswith(")")):
        note = "(%s)" % note
    new_text = (note + " " + g["text"]) if note else g["text"]
    if goal_key(new_text) != goal_key(g["text"]):
        print("mark: refused, the note would change the goal key (unbalanced parentheses?): %r; nothing written" % note,
              file=sys.stderr)
        return 6
    lines = raw.splitlines()
    old_line = lines[g["line"] - 1]
    cm = CHECKBOX.match(old_line)
    new_line = old_line[:cm.start(1)] + "x" + old_line[cm.end(1):cm.start(2)] + new_text
    rc = replace_line(goals_path, g["line"], old_line, new_line, lock_path, "mark")
    if rc:
        return rc
    print("marked %s done: line %d\n  - %s\n  + %s\n  key unchanged: %s hash %s" % (
        g["id"], g["line"], old_line, new_line, goal_key(new_text) == goal_key(g["text"]), g["hash"]), file=out)
    return 0


# ------------------------------------------------------------------ --selftest
FIXTURE = """# Goals (supervisor-plan selftest fixture)

## Goals from Slack

- [ ] Fix the README typo in /wd/loop/alpha/README.md (from Slack C0FIXTURE 1793000000.000010)
- [ ] Measure the beta service latency and write /wd/loop/beta/FINDINGS.md (from Slack C0FIXTURE 1793000000.000020)
- [ ] Write the gamma runbook under /wd/loop/gamma/ (from Slack C0FIXTURE 1793000000.000030)
- [ ] Stage fix A in /wd/projects/workshopstudio/demo-workshop/static/a.yaml (from Slack C0FIXTURE 1793000000.000001)
- [ ] Stage fix B in /wd/projects/workshopstudio/demo-workshop/static/b.yaml and post in thread 1793000000.000001 (from Slack C0FIXTURE 1793000000.000001)
- [x] (done 2026-11-01, fixture) An already finished goal in /wd/loop/alpha (from Slack C0FIXTURE 1793000000.000040)
- [ ] (priority: high) Rotate the delta dashboard certificate before the demo (from Slack C0FIXTURE 1793000000.000050)

```text
- [ ] a goal inside a code fence that the parser must ignore
```
"""
FIXTURE_NOTES = """- 2026-11-05 ~06:00Z fire 3001 (G3 line 7 OPEN): wrote /wd/files/gamma-reports/draft.md; next: finish the runbook.
- 2026-11-05 ~06:05Z fire 3002 (G7 line 11 OPEN): read the dashboard docs, nothing written yet.
"""


class _Args:
    def __init__(self, **kw):
        self.goals, self.notes, self.notes_tail, self.max_workers = kw.get("goals"), kw.get("notes"), 200, 3
        self.locks_dir, self.parked, self.json, self.explain = kw.get("locks_dir"), None, None, kw.get("explain", True)


def selftest():
    results = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok), detail))
        print("%s %s%s" % ("PASS" if ok else "FAIL", name, (": " + detail) if detail else ""))

    def ids(seq):
        return [m["id"] for m in seq]

    def gids(grp):
        return ids(grp["members"])

    with tempfile.TemporaryDirectory(prefix="supervisor-plan-selftest-") as d:
        gpath, npath, lpath = os.path.join(d, "GOALS.md"), os.path.join(d, "notes.md"), os.path.join(d, "locks")
        os.mkdir(lpath)
        with open(gpath, "w", encoding="utf-8") as f:
            f.write(FIXTURE)
        with open(npath, "w", encoding="utf-8") as f:
            f.write(FIXTURE_NOTES)
        print("fixture: %s (%d lines) + notes (%d lines)" % (gpath, FIXTURE.count("\n"), FIXTURE_NOTES.count("\n")))
        goals, _raw = parse_goals(gpath)
        nk, nread = notes_keys_by_goal(npath, 200, goals)
        p = plan(goals, nk, 3)
        args = _Args(goals=gpath, notes=npath)
        print(render(p, args, len(goals), nread))
        print("---- checks")
        check("parse: 7 goal items, the fenced `- [ ]` ignored", len(goals) == 7, "parsed %d" % len(goals))
        check("parse: 6 open (the `- [x]` line excluded)", len(p["open"]) == 6, "open %d" % len(p["open"]))
        check("ids: G<n> is the n-th item, line is the file line", [g["id"] for g in goals][:2] == ["G1 (line 5)", "G2 (line 6)"] and goals[6]["id"] == "G7 (line 11)", str([g["id"] for g in goals]))
        check("priority: the leading (priority: high) note is read", goals[6]["priority"] == "high" and goals[0]["priority"] == "normal")
        check("key: the priority note is not part of the goal key", goals[6]["key"].startswith("Rotate the delta"), goals[6]["key"][:40])
        check("order: the high-priority goal (last in the file) first, then file order",
              ids(p["order"]) == ["G7 (line 11)", "G1 (line 5)", "G2 (line 6)", "G3 (line 7)", "G4 (line 8)", "G5 (line 9)"], str(ids(p["order"])))
        check("groups: five - the chain of two plus four singletons", len(p["groups"]) == 5 and sorted(len(g["members"]) for g in p["groups"]) == [1, 1, 1, 1, 2], str([gids(g) for g in p["groups"]]))
        chain = next((g for g in p["groups"] if len(g["members"]) == 2), None)
        check("chain: G4 -> G5 in that order", chain is not None and gids(chain) == ["G4 (line 8)", "G5 (line 9)"], str(gids(chain)) if chain else "no chain")
        check("chain: bound by the checkout path and the Slack thread",
              chain is not None and chain["keys"] == ["path:/wd/projects/workshopstudio/demo-workshop", "thread:1793000000.000001"], str(chain["keys"]) if chain else "")
        check("dispatch (max 3): the high-priority group, then the first two groups in file order",
              [gids(g) for g in p["dispatch"]] == [["G7 (line 11)"], ["G1 (line 5)"], ["G2 (line 6)"]], str([gids(g) for g in p["dispatch"]]))
        check("waiting: G3 and the chain", [gids(g) for g in p["waiting"]] == [["G3 (line 7)"], ["G4 (line 8)", "G5 (line 9)"]], str([gids(g) for g in p["waiting"]]))
        g3 = next(g for g in p["open"] if g["index"] == 3)
        check("notes: the notes line naming G3 adds its path key to G3 only",
              "path:/wd/files/gamma-reports" in g3["resources_notes"] and not any("gamma-reports" in k for g in p["open"] if g["index"] != 3 for k in g["resources"]), str(g3["resources_notes"]))
        check("notes: a notes key never merges groups here", len(p["groups"]) == 5)
        # locks: hold G1's path lock -> its group is blocked, the next free group takes the slot
        fd = os.open(lock_path_for(lpath, "path:/wd/loop/alpha"), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            goals_l, _ = parse_goals(gpath)
            pl = plan(goals_l, {}, 3, locks_dir=lpath)
            check("locks: a held resource lock blocks only that group and frees its slot",
                  [gids(g) for g in pl["dispatch"]] == [["G7 (line 11)"], ["G2 (line 6)"], ["G3 (line 7)"]] and [gids(g) for g in pl["blocked"]] == [["G1 (line 5)"]] and pl["blocked"][0]["busy"] == ["path:/wd/loop/alpha"],
                  "dispatch=%s blocked=%s" % ([gids(g) for g in pl["dispatch"]], [(gids(g), g.get("busy")) for g in pl["blocked"]]))
        finally:
            os.close(fd)
        # parked: G2's hash parked -> left out of dispatch, nothing else delayed
        goals_p, _ = parse_goals(gpath)
        g2hash = next(g["hash"] for g in goals_p if g["index"] == 2)
        pp = plan(goals_p, {}, 3, parked=frozenset([g2hash]))
        check("parked: a parked goal leaves dispatch, the next group takes its slot",
              [gids(g) for g in pp["dispatch"]] == [["G7 (line 11)"], ["G1 (line 5)"], ["G3 (line 7)"]] and [gids(g) for g in pp["parked"]] == [["G2 (line 6)"]],
              "dispatch=%s parked=%s" % ([gids(g) for g in pp["dispatch"]], [gids(g) for g in pp["parked"]]))
        # explicit markers: (serial-with: G1) on G3 -> one chain; (after: G3) on G1 -> G3 before G1
        variant = FIXTURE.replace("- [ ] Write the gamma runbook", "- [ ] (serial-with: G1) Write the gamma runbook", 1)
        vpath = os.path.join(d, "GOALS-variant.md")
        with open(vpath, "w", encoding="utf-8") as f:
            f.write(variant)
        gv, _ = parse_goals(vpath)
        pv = plan(gv, {}, 3)
        chain13 = next((g for g in pv["groups"] if {m["index"] for m in g["members"]} == {1, 3}), None)
        check("explicit: (serial-with: G1) on G3 makes G1 -> G3 one chain of four groups",
              chain13 is not None and gids(chain13) == ["G1 (line 5)", "G3 (line 7)"] and len(pv["groups"]) == 4 and "explicit:G1" in chain13["keys"],
              "groups=%s" % [gids(g) for g in pv["groups"]])
        check("explicit: the serial-with goal keeps its key (a leading note)", gv[2]["key"].startswith("Write the gamma runbook"), gv[2]["key"][:40])
        variant2 = FIXTURE.replace("- [ ] Fix the README typo", "- [ ] (after: G3) Fix the README typo", 1)
        with open(vpath, "w", encoding="utf-8") as f:
            f.write(variant2)
        gv2, _ = parse_goals(vpath)
        pv2 = plan(gv2, {}, 3)
        chain31 = next((g for g in pv2["groups"] if {m["index"] for m in g["members"]} == {1, 3}), None)
        check("explicit: (after: G3) on G1 joins them and orders G3 before G1",
              chain31 is not None and gids(chain31) == ["G3 (line 7)", "G1 (line 5)"], "groups=%s" % [gids(g) for g in pv2["groups"]])
        # --set-priority: exactly one line changes, the goal key does not, normal restores the file byte for byte
        before = FIXTURE.splitlines()
        rc = set_priority(gpath, "L6", "high")
        with open(gpath, encoding="utf-8") as f:
            after_raw = f.read()
        after = after_raw.splitlines()
        changed = [i + 1 for i in range(max(len(before), len(after))) if (before[i] if i < len(before) else None) != (after[i] if i < len(after) else None)]
        check("set-priority L6 high: rc 0 and exactly line 6 changed", rc == 0 and changed == [6], "rc=%d changed=%s" % (rc, changed))
        check("set-priority: line 6 now carries the marker", len(after) >= 6 and after[5].startswith("- [ ] (priority: high) Measure the beta"), after[5] if len(after) >= 6 else "")
        g_after, _ = parse_goals(gpath)
        check("set-priority: goal_key of line 6 unchanged (mirror-key invariant)", g_after[1]["key"] == goals[1]["key"] and g_after[1]["hash"] == goals[1]["hash"], "%s / %s" % (g_after[1]["hash"], goals[1]["hash"]))
        p2 = plan(g_after, {}, 3)
        check("re-plan: two high goals in file order first (G2 then G7), then the rest",
              ids(p2["order"]) == ["G2 (line 6)", "G7 (line 11)", "G1 (line 5)", "G3 (line 7)", "G4 (line 8)", "G5 (line 9)"], str(ids(p2["order"])))
        rc_same = set_priority(gpath, "G2", "high")
        check("set-priority twice: rc 0, reported unchanged, no rewrite", rc_same == 0)
        rc2 = set_priority(gpath, "G2", "normal")
        with open(gpath, encoding="utf-8") as f:
            restored = f.read()
        check("set-priority G2 normal: the file is byte-identical to the fixture again", rc2 == 0 and restored == FIXTURE, "rc=%d identical=%s" % (rc2, restored == FIXTURE))
        rc_busy_fd = os.open(gpath + ".lock", os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(rc_busy_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            rc5 = set_priority(gpath, "G1", "low")
        finally:
            os.close(rc_busy_fd)
        with open(gpath, encoding="utf-8") as f:
            still = f.read()
        check("set-priority under a held goals lock: rc 5 and nothing written", rc5 == 5 and still == FIXTURE, "rc=%d" % rc5)
        check("set-priority on a missing goal: rc 4", set_priority(gpath, "G99", "high") == 4)
        check("set-priority with a bad level: rc 2", set_priority(gpath, "G1", "urgent") == 2)
        # json round trip
        jpath = os.path.join(d, "plan.json")
        args_j = _Args(goals=gpath, notes=npath)
        args_j.json, args_j.explain = jpath, False
        rcj = run_plan(args_j)
        with open(jpath, encoding="utf-8") as f:
            j = json.load(f)
        check("json: written, lists order/groups/dispatch/waiting with the same ids", rcj == 0 and j["order"][0] == "G7 (line 11)" and j["dispatch"] == ["g1", "g2", "g3"] and j["waiting"] == ["g4", "g5"] and len(j["groups"]) == 5 and j["groups"][4]["lock_keys"][0].startswith("goal:"),
              "dispatch=%s waiting=%s" % (j.get("dispatch"), j.get("waiting")))

        # --mark: the one write a supervisor worker makes to the goals file (the fixture is byte-identical again here)
        def file_lines(p):
            with open(p, encoding="utf-8") as f:
                return f.read().splitlines()
        gm, _ = parse_goals(gpath)
        h1 = gm[0]["hash"]
        rcm = mark_done(gpath, "G1", note="done by the selftest worker", allowed={h1})
        marked = file_lines(gpath)
        changed_m = [i + 1 for i in range(max(len(before), len(marked))) if (before[i] if i < len(before) else None) != (marked[i] if i < len(marked) else None)]
        check("mark G1 (own hash): rc 0 and exactly line 5 changed", rcm == 0 and changed_m == [5], "rc=%d changed=%s" % (rcm, changed_m))
        check("mark: line 5 reads `- [x] (done by the selftest worker) Fix the README typo ...`", len(marked) >= 5 and marked[4].startswith("- [x] (done by the selftest worker) Fix the README typo"), marked[4] if len(marked) >= 5 else "")
        gm2, _ = parse_goals(gpath)
        check("mark: G1 is done, its key and hash unchanged (the cards stay), still 7 items", gm2[0]["done"] and gm2[0]["key"] == gm[0]["key"] and gm2[0]["hash"] == h1 and len(gm2) == 7, "%s / %s" % (gm2[0]["hash"], h1))
        rc3 = mark_done(gpath, "G2", allowed={h1})
        rc3e = mark_done(gpath, "G2", allowed=set())
        check("mark G2 with another worker's hashes, then with an empty set: rc 3 twice, nothing written", rc3 == 3 and rc3e == 3 and file_lines(gpath) == marked, "rc=%d/%d" % (rc3, rc3e))
        check("mark an already done goal (G1 again; G6, the fixture's `- [x]` line): rc 4 twice", mark_done(gpath, "G1", allowed={h1}) == 4 and mark_done(gpath, "G6") == 4)
        check("mark a missing goal / a bad target: rc 4 / rc 2", mark_done(gpath, "L99") == 4 and mark_done(gpath, "x1") == 2)
        rc6 = mark_done(gpath, "G3", note="unbalanced (note")
        check("mark with a note that would change the key: rc 6, nothing written", rc6 == 6 and file_lines(gpath) == marked, "rc=%d" % rc6)
        lk = os.open(gpath + ".lock", os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            rc5m = mark_done(gpath, "G3")
        finally:
            os.close(lk)
        check("mark under a held goals lock: rc 5, nothing written", rc5m == 5 and file_lines(gpath) == marked, "rc=%d" % rc5m)
        pm = plan(gm2, {}, 3)
        check("re-plan after the mark: 5 open goals and G1 gone from the order", len(pm["open"]) == 5 and "G1 (line 5)" not in ids(pm["order"]), str(ids(pm["order"])))

        # --unpark: the goal's hash leaves parked and strikes.tsv, other goals' lines and `#` lines stay, goals untouched
        sdir = os.path.join(d, "supervisor")
        os.mkdir(sdir)
        gh = {g["index"]: g["hash"] for g in gm2}
        ppath, spath = os.path.join(sdir, "parked"), os.path.join(sdir, "strikes.tsv")
        with open(ppath, "w", encoding="utf-8") as f:
            f.write("# hash\tsince_cycle\tuntil_cycle\tutc\n%s\t12\t18\t2026-11-05T07:00:00Z\n%s\t12\t18\t2026-11-05T07:00:00Z\n" % (gh[2], gh[3]))
        with open(spath, "w", encoding="utf-8") as f:
            f.write("".join("%s\t%d\t1\t2026-11-05T07:0%d:00Z\n" % (gh[2], 3150 + i, i) for i in range(3)))
            f.write("%s\t3153\t1\t2026-11-05T07:03:00Z\n" % gh[3])
        goals_snapshot = file_lines(gpath)
        rcu = unpark(gpath, "G2", sdir)
        check("unpark G2: rc 0, its hash gone from parked (header + G3 left) and from strikes.tsv (G3's line left), goals untouched",
              rcu == 0 and read_parked(ppath) == frozenset([gh[3]]) and len(file_lines(ppath)) == 2
              and file_lines(spath) == ["%s\t3153\t1\t2026-11-05T07:03:00Z" % gh[3]] and file_lines(gpath) == goals_snapshot,
              "rc=%d parked=%s strikes=%d" % (rcu, sorted(read_parked(ppath)), len(file_lines(spath))))
        check("unpark G2 again: rc 0 (nothing was parked), files unchanged", unpark(gpath, "G2", sdir) == 0 and len(file_lines(ppath)) == 2 and len(file_lines(spath)) == 1)
        check("unpark a missing goal / a bad target / no dir given: rc 4 / rc 2 / rc 2", unpark(gpath, "G99", sdir) == 4 and unpark(gpath, "x1", sdir) == 2 and unpark(gpath, "G2", None) == 2)
        check("unpark with a supervisor dir that holds no parked or strikes file: rc 0", unpark(gpath, "G3", os.path.join(d, "no-such-dir")) == 0)
        sl = os.open(os.path.join(sdir, "strikes.lock"), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(sl, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            rc5u = unpark(gpath, "G3", sdir)
        finally:
            os.close(sl)
        check("unpark under a held strikes lock: rc 5, nothing removed", rc5u == 5 and read_parked(ppath) == frozenset([gh[3]]), "rc=%d" % rc5u)
        pu = plan(gm2, {}, 3, parked=read_parked(ppath))
        check("re-plan with the parked file: G3 parked, G2 dispatched again",
              [m["index"] for g in pu["parked"] for m in g["members"]] == [3] and any(m["index"] == 2 for g in pu["dispatch"] for m in g["members"]),
              "dispatch=%s parked=%s" % ([gids(g) for g in pu["dispatch"]], [gids(g) for g in pu["parked"]]))
    passed = sum(1 for _n, ok, _d in results if ok)
    verdict = "PASS" if passed == len(results) else "FAIL"
    print("VERDICT %s %d/%d checks" % (verdict, passed, len(results)))
    return 0 if verdict == "PASS" else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="deterministic planner of the autonomy loop's supervisor mode")
    ap.add_argument("--goals", help="the goals file (AUTONOMY_LOOP_GOALS)")
    ap.add_argument("--notes", help="the progress notes; its tail lends path/thread keys to the goals it names")
    ap.add_argument("--notes-tail", type=int, default=200)
    ap.add_argument("--max-workers", type=int, default=3)
    ap.add_argument("--locks-dir", help="the loop's per-resource flock directory; a held lock blocks a group")
    ap.add_argument("--parked", help="file with one parked goal hash per line (the loop writes it from strikes.tsv)")
    ap.add_argument("--json", help="write the plan here (atomic replace)")
    ap.add_argument("--explain", action="store_true", help="print every goal's keys and why each pair is one chain")
    ap.add_argument("--set-priority", nargs=2, metavar=("G<n>|L<line>", "high|low|normal"))
    ap.add_argument("--lock", help="goals lock path for --set-priority and --mark (default <goals>.lock)")
    ap.add_argument("--mark", metavar="G<n>|L<line>", help="flip that open goal to `- [x]` (the write behind goals-mark.sh)")
    ap.add_argument("--note", help="for --mark: the completion note, written as a leading parenthesised note")
    ap.add_argument("--allowed-hashes", help="for --mark: the space-separated goal hashes this worker owns (WORKER_GOAL_HASHES); empty = refuse every goal")
    ap.add_argument("--unpark", metavar="G<n>|L<line>", help="clear that goal's parking and strikes (the write behind goals-add.sh --unpark)")
    ap.add_argument("--supervisor-dir", help="for --unpark: the directory holding parked and strikes.tsv (${AUTONOMY_LOOP_DIR}/supervisor)")
    ap.add_argument("--selftest", action="store_true", help="run the built-in fixture; exit 0 = pass")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    if not args.goals:
        ap.print_usage(sys.stderr)
        print("supervisor-plan: --goals is required", file=sys.stderr)
        return 2
    if args.set_priority:
        return set_priority(args.goals, args.set_priority[0], args.set_priority[1].lower(), args.lock)
    if args.mark:
        allowed = None if args.allowed_hashes is None else set(args.allowed_hashes.split())
        return mark_done(args.goals, args.mark, args.note, allowed, args.lock)
    if args.unpark:
        return unpark(args.goals, args.unpark, args.supervisor_dir)
    if args.max_workers < 1:
        print("supervisor-plan: --max-workers must be >= 1", file=sys.stderr)
        return 2
    return run_plan(args)


if __name__ == "__main__":
    sys.exit(main())
