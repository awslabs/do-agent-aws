#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""supervisor-mirrors-test.py - offline test of the board mirrors' `fire-start --goal-key` (G99, DESIGN.md section 6):
plane-sync.py and kanban-sync.py record ONE goal per running fire in their state file (fires: {"<fire>": {...}}), fire-end
reads the record by fire number, the goals of the other fires still running stay In Progress, and a fire started with
--goal-key is never credited with another worker's goal. Stdlib only, `python3 -I`; the two mirrors are loaded from the
agent directory and talk to fake boards (no network, no board URL needed beyond the setting, no /agent, a temp state
file). Exit 0 = every check passed, 1 = a check failed.

    python3 -I test-lib/supervisor-mirrors-test.py [--agent-dir DIR]
"""
import argparse
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ALPHA = "Alpha: write the alpha report under /wd/loop/alpha - DONE when alpha.md exists (from Slack C1 1.1)"
BETA = "Beta: build the beta image - DONE when the image tag exists (from Slack C1 2.2)"
GAMMA = "Gamma: post the gamma summary in thread 3.3 - DONE when posted (from Slack C1 3.3)"
DELTA = "Delta: rotate the delta log - DONE when rotated (from Slack C1 4.4)"
OMEGA = "Omega: a goal that is not in the file at all"


def write_goals(path, lines):
    """lines: [(checked, prefix, text)] -> the fixture goals file."""
    with open(path, "w", encoding="utf-8") as f:
        f.write("# Goals for the autonomy loop\n\n## Goals from Slack\n")
        for checked, prefix, text in lines:
            f.write("- [%s] %s%s\n" % ("x" if checked else " ", (prefix + " ") if prefix else "", text))


def quiet(fn, *a, **kw):
    out = io.StringIO()
    with redirect_stdout(out), redirect_stderr(out):
        r = fn(*a, **kw)
    return r, out.getvalue()


def parse_via_main(mod, argv):
    """mod.main() on argv with act() replaced: (rc, the parsed args it would have run with)."""
    captured = []
    with mock.patch.object(mod, "act", lambda a: captured.append(a) or 0), mock.patch.object(sys, "argv", ["x"] + argv):
        rc = mod.main()
    return rc, (captured[0] if captured else None)


# ------------------------------------------------------------------ the fake boards (the REST surface the mirrors use)
class FakeKanban:
    def __init__(self, ks):
        self.ks = ks
        self.status_ids = {n: "st-%s" % n for n in (ks.TODO, ks.IN_PROGRESS, ks.IN_REVIEW, ks.DONE, ks.CANCELLED)}
        self.cards, self.comments, self.clock = {}, [], 0

    def login(self, email, password):
        pass

    def organization(self):
        return {"id": "org-1", "name": "Test Org", "is_personal": True}

    def name_organization(self, org, name):
        return False

    def ensure_project(self, pid, org_id, name):
        return "exists"

    def project(self, pid):
        return {"id": pid, "name": "Test goals"}

    def rename_project(self, pid, name):
        pass

    def statuses(self, pid):
        return dict(self.status_ids)

    def issues(self, pid):
        return {k: dict(v) for k, v in self.cards.items()}

    def create_issue(self, body):
        if body["id"] in self.cards:
            return False
        self.clock += 1
        self.cards[body["id"]] = dict(body, created_at="2026-01-01T00:00:%02dZ" % self.clock)
        return True

    def update_issue(self, iid, changes):
        self.cards[iid].update(changes)

    def comment(self, cid, issue_id, message):
        if any(c[0] == cid for c in self.comments):
            return False
        self.comments.append((cid, issue_id, message))
        return True

    def status(self, iid):
        names = {v: k for k, v in self.status_ids.items()}
        return names[self.cards[iid]["status_id"]]


class FakePlane:
    def __init__(self, ps):
        self.ps = ps
        self.project = {"id": "proj-1", "identifier": "AGENT"}
        self.states = [{"id": "s-%s" % n, "name": n} for n in ("Backlog", ps.TODO, ps.IN_PROGRESS, ps.IN_REVIEW, ps.DONE, ps.CANCELLED)]
        self.items, self.comments, self.seq = {}, [], 0

    def all(self, path):
        if path.endswith("/projects/"):
            return [dict(self.project)]
        if path.endswith("/states/"):
            return [dict(s) for s in self.states]
        if path.endswith("/issues/"):
            return [dict(i) for i in self.items.values()]
        raise AssertionError("unexpected list %s" % path)

    def call(self, method, path, body=None, ok=(200, 201, 204)):
        if method == "POST" and path.endswith("/issues/"):
            for i in self.items.values():
                if i.get("external_id") == body["external_id"]:
                    return 409, {"id": i["id"]}
            self.seq += 1
            item = {"id": "item-%d" % self.seq, "sequence_id": self.seq, "name": body["name"][:250],
                    "description_html": body.get("description_html", ""), "state": body["state"],
                    "external_id": body["external_id"], "external_source": self.ps.SOURCE,
                    "created_at": "2026-01-01T00:00:%02dZ" % self.seq}
            self.items[item["id"]] = item
            return 201, item
        if method == "PATCH" and "/issues/" in path:
            iid = path.rstrip("/").split("/")[-1]
            self.items[iid].update(body)
            return 200, dict(self.items[iid])
        if method == "POST" and path.endswith("/comments/"):
            iid = path.rstrip("/").split("/")[-2]
            if any(c[0] == body["external_id"] for c in self.comments):
                return 409, {"id": "c"}
            self.comments.append((body["external_id"], iid, body["comment_html"]))
            return 201, {"id": "c"}
        if method == "POST" and path.endswith("/states/"):
            s = dict(body, id="s-%s" % body["name"])
            self.states.append(s)
            return 201, s
        raise AssertionError("unexpected call %s %s" % (method, path))

    def state(self, iid):
        names = {s["id"]: s["name"] for s in self.states}
        return names[self.items[iid]["state"]]

    def item_of(self, eid):
        return next(i["id"] for i in self.items.values() if i["external_id"] == eid)


def main(argv=None):
    ap = argparse.ArgumentParser(description="offline test of the board mirrors' fire-start --goal-key")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--agent-dir", default=os.path.dirname(here), help="the directory holding plane-sync.py and kanban-sync.py")
    args = ap.parse_args(argv)
    ps = load("plane_sync", os.path.join(args.agent_dir, "plane-sync.py"))
    ks = load("kanban_sync", os.path.join(args.agent_dir, "kanban-sync.py"))
    results = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok)))
        print("%s %s%s" % ("PASS" if ok else "FAIL", name, (": " + detail) if detail else ""))

    def ns(**kw):
        base = {"action": None, "fire": None, "started": None, "rc": None, "duration": None, "out": None, "goal_key": None, "done": None}
        base.update(kw)
        return argparse.Namespace(**base)

    # ---------------------------------------------------------------- argparse: the option exists on both mirrors
    rc, a = parse_via_main(ps, ["fire-start", "--fire", "5", "--goal-key", BETA])
    check("plane: argparse takes --goal-key on fire-start", rc == 0 and a is not None and a.action == "fire-start" and a.fire == 5 and a.goal_key == BETA)
    rc, a = parse_via_main(ps, ["fire-start", "--fire", "5"])
    check("plane: argparse without --goal-key gives None (today's call)", rc == 0 and a is not None and a.goal_key is None)
    rc, a = parse_via_main(ks, ["fire-start", "--fire", "5", "--started", "1000", "--goal-key", GAMMA])
    check("kanban: argparse takes --goal-key on fire-start", rc == 0 and a is not None and a.action == "fire-start" and a.started == 1000 and a.goal_key == GAMMA)
    rc, a = parse_via_main(ks, ["fire-end", "--fire", "5", "--started", "1000", "--rc", "0", "--duration", "3"])
    check("kanban: argparse without --goal-key gives None", rc == 0 and a is not None and a.goal_key is None)

    with tempfile.TemporaryDirectory(prefix="supervisor-mirrors-test-") as d:
        goals_path = os.path.join(d, "GOALS.md")
        loop_dir = os.path.join(d, "loop")
        os.mkdir(loop_dir)
        write_goals(goals_path, [(False, "", ALPHA), (False, "", BETA), (False, "", GAMMA), (True, "", DELTA)])
        common = {"AUTONOMY_LOOP_GOALS": goals_path, "AUTONOMY_LOOP_DEFAULT_GOALS": os.path.join(d, "none.md"),
                  "AUTONOMY_LOOP_DIR": loop_dir}

        # ================================================================ plane-sync.py
        board = FakePlane(ps)
        env = dict(common, PLANE_URL="http://127.0.0.1:1", PLANE_AUTH_FILE=os.path.join(d, "no.env"), PLANE_WORKSPACE="do-agent-aws",
                   PLANE_PROJECT="AGENT")
        pid = board.project["id"]

        def eid(key):
            return str(ps.uuid.uuid5(ps.NS, "%s:goal:%s" % (pid, key)))

        def pstate():
            return ps.read_state(loop_dir)

        def pst(key):
            return board.state(board.item_of(eid(key)))

        with mock.patch.object(ps, "Board", lambda base, key, ws: board), mock.patch.object(ps, "load_key", lambda p: "k"):
            # no board URL: bad settings, rc 4, nothing written (the behaviour so far)
            with mock.patch.dict(os.environ, common, clear=False):
                os.environ.pop("PLANE_URL", None)
                rc, out = quiet(ps.act, ns(action="fire-start", fire=11, goal_key=BETA))
            check("plane: without PLANE_URL fire-start --goal-key is rc 4 and writes no state", rc == 4 and not os.path.exists(os.path.join(loop_dir, "plane-sync.state")), out.strip()[-120:])
            with mock.patch.dict(os.environ, env, clear=False):
                # two workers start on Beta and Gamma: both In Progress, Alpha Todo, one record per fire
                rc, out = quiet(ps.act, ns(action="fire-start", fire=11, goal_key=BETA))
                s = pstate()
                check("plane: fire-start 11 --goal-key Beta -> Beta In Progress, Alpha and Gamma Todo, Delta Done", rc == 0 and pst(BETA) == ps.IN_PROGRESS and pst(ALPHA) == ps.TODO and pst(GAMMA) == ps.TODO and pst(DELTA) == ps.DONE, out.strip()[-160:])
                check("plane: the state records fire 11 under fires with its goal and the requested key", s.get("fire") == 11 and (s.get("fires") or {}).get("11", {}).get("goal") == BETA and s["fires"]["11"].get("requested") == BETA and isinstance(s["fires"]["11"].get("started"), int))
                rc, out = quiet(ps.act, ns(action="fire-start", fire=12, goal_key=GAMMA))
                s = pstate()
                check("plane: fire-start 12 --goal-key Gamma -> Gamma In Progress and Beta STAYS In Progress (held for fire 11)", rc == 0 and pst(GAMMA) == ps.IN_PROGRESS and pst(BETA) == ps.IN_PROGRESS and pst(ALPHA) == ps.TODO, out.strip()[-160:])
                check("plane: both fires recorded, the single record is the latest start", sorted(s.get("fires") or {}) == ["11", "12"] and s.get("fire") == 12 and s.get("goal") == GAMMA)
                check("plane: the summary names the fire's own goal", "'Gamma: post the gamma summary" in out and "-> In Progress" in out, out.strip()[-160:])
                # fire 11 ends with Beta still open: Beta In Review, Gamma still In Progress, record 11 gone
                n_comments = len(board.comments)
                rc, out = quiet(ps.act, ns(action="fire-end", fire=11, rc=0, duration=30))
                s = pstate()
                beta_item = board.item_of(eid(BETA))
                check("plane: fire-end 11 -> Beta In Review, Gamma still In Progress (fire 12 runs), Alpha Todo", rc == 0 and pst(BETA) == ps.IN_REVIEW and pst(GAMMA) == ps.IN_PROGRESS and pst(ALPHA) == ps.TODO, out.strip()[-160:])
                check("plane: fire 11's record is removed, fire 12's stays", sorted(s.get("fires") or {}) == ["12"])
                check("plane: fire 11's result is a comment on Beta's item", len(board.comments) == n_comments + 1 and board.comments[-1][1] == beta_item and "Fire 11" in board.comments[-1][2])
                # fire 12 marks Gamma done with a note prefixed (the key stays): Done on the same item, record gone
                write_goals(goals_path, [(False, "", ALPHA), (False, "", BETA), (True, "(done by worker 12, evidence x)", GAMMA), (True, "", DELTA)])
                gamma_item = board.item_of(eid(GAMMA))
                rc, out = quiet(ps.act, ns(action="fire-end", fire=12, rc=0, duration=40))
                s = pstate()
                check("plane: fire-end 12 after its goal was checked off with a note -> Gamma Done on the same item, no new item", rc == 0 and pst(GAMMA) == ps.DONE and len(board.items) == 4 and "-> Done" in out, out.strip()[-160:])
                check("plane: no record left; the comment of fire 12 is on Gamma's item", not s.get("fires") and board.comments[-1][1] == gamma_item and "Fire 12" in board.comments[-1][2])
                # a fire without --goal-key: the first open goal, as a serial fire today; its record carries no requested key
                rc, out = quiet(ps.act, ns(action="fire-start", fire=13))
                s = pstate()
                check("plane: fire-start 13 without --goal-key -> the first open goal (Alpha) In Progress", rc == 0 and pst(ALPHA) == ps.IN_PROGRESS and pst(BETA) == ps.TODO, out.strip()[-160:])
                check("plane: its record has goal Alpha and requested None", (s.get("fires") or {}).get("13", {}).get("goal") == ALPHA and s["fires"]["13"].get("requested") is None)
                rc, out = quiet(ps.act, ns(action="fire-end", fire=13, rc=0, duration=5))
                check("plane: fire-end 13 -> Alpha In Review (today's rule kept)", rc == 0 and pst(ALPHA) == ps.IN_REVIEW and not pstate().get("fires"), out.strip()[-160:])
                # a key that is not in the file: rc 0, nothing moved to In Progress, the summary says so; its end moves nothing
                rc, out = quiet(ps.act, ns(action="fire-start", fire=14, goal_key=OMEGA))
                s = pstate()
                in_prog = [k for k in (ALPHA, BETA) if pst(k) == ps.IN_PROGRESS]
                check("plane: fire-start 14 --goal-key of a goal not in the file -> rc 0, no item In Progress, the summary names it", rc == 0 and not in_prog and "is not in the goals file" in out, out.strip()[-200:])
                check("plane: its record has goal None and the requested key", (s.get("fires") or {}).get("14", {}).get("goal") is None and s["fires"]["14"].get("requested") == OMEGA)
                n_comments = len(board.comments)
                rc, out = quiet(ps.act, ns(action="fire-end", fire=14, rc=0, duration=5))
                check("plane: fire-end 14 -> nothing credited (no '->' in the summary, no comment, no item In Review)", rc == 0 and "->" not in out and len(board.comments) == n_comments and pst(ALPHA) != ps.IN_REVIEW and pst(BETA) != ps.IN_REVIEW, out.strip()[-160:])
                # the goal's line renamed between the plan and the start (a priority note prefixed): the key is unchanged, found
                write_goals(goals_path, [(False, "", ALPHA), (False, "(priority: high)", BETA), (True, "(done by worker 12, evidence x)", GAMMA), (True, "", DELTA)])
                rc, out = quiet(ps.act, ns(action="fire-start", fire=15, goal_key=BETA))
                check("plane: fire-start 15 --goal-key Beta with a priority note prefixed to its line -> Beta In Progress, same item", rc == 0 and pst(BETA) == ps.IN_PROGRESS and len(board.items) == 4, out.strip()[-160:])
                rc, out = quiet(ps.act, ns(action="fire-end", fire=15, rc=1, duration=5))
                check("plane: fire-end 15 rc 1 -> Beta In Review", rc == 0 and pst(BETA) == ps.IN_REVIEW, out.strip()[-160:])
                # an older fire-start's single record (no fires): fire-end still finds the goal by the single record
                ps.write_state(loop_dir, {"fire": 21, "started": 5, "goal": ALPHA, "last_fire": {}, "aliases": {}})
                rc, out = quiet(ps.act, ns(action="fire-end", fire=21, rc=0, duration=5))
                check("plane: fire-end 21 on the single record of an older fire-start -> Alpha In Review, Fire 21 comment on Alpha", rc == 0 and pst(ALPHA) == ps.IN_REVIEW and board.comments[-1][1] == board.item_of(eid(ALPHA)) and "Fire 21" in board.comments[-1][2], out.strip()[-160:])
                # pruning: a record older than FIRES_TTL and more than FIRES_MAX records leave; a stale record holds no goal
                now = int(time.time())
                stale = {"1": {"goal": ALPHA, "started": 0, "requested": ALPHA}}
                stale.update({str(100 + i): {"goal": None, "started": now, "requested": None} for i in range(25)})
                ps.write_state(loop_dir, {"fire": 124, "started": now, "goal": None, "last_fire": {}, "aliases": {}, "fires": stale})
                rc, out = quiet(ps.act, ns(action="fire-start", fire=125, goal_key=BETA))
                s = pstate()
                check("plane: fire-start 125 prunes the stale record (Alpha not held In Progress) and keeps FIRES_MAX records", rc == 0 and "1" not in (s.get("fires") or {}) and "125" in s["fires"] and len(s["fires"]) == ps.FIRES_MAX and pst(ALPHA) == ps.TODO, "%d records" % len(s.get("fires") or {}))

        # ================================================================ kanban-sync.py
        write_goals(goals_path, [(False, "", ALPHA), (False, "", BETA), (False, "", GAMMA), (True, "", DELTA)])
        kboard = FakeKanban(ks)
        kenv = dict(common, KANBAN_BOARD_URL="http://127.0.0.1:1", KANBAN_AUTH_FILE=os.path.join(d, "no.env"), KANBAN_PROJECT="test")
        kpid = ks.project_id("test")
        # --started values as loop.sh passes them (date +%s, the real epoch): a record older than FIRES_TTL is pruned,
        # so a small made-up epoch would be dropped at once - the first run of this test did exactly that
        T0 = int(time.time()) - 600
        T = {11: T0, 12: T0 + 1, 13: T0 + 2, 14: T0 + 3, 16: T0 + 4, 18: T0 + 5, 19: T0 + 6, 31: T0 + 7}

        def cid(key):
            return ks.card_id(kpid, key)

        def kst(key):
            return kboard.status(cid(key))

        def kstate():
            return ks.read_state(loop_dir)

        def desc(key):
            return kboard.cards[cid(key)].get("description") or ""

        with mock.patch.object(ks, "Board", lambda url: kboard), mock.patch.object(ks, "load_login", lambda p: ("e", "p")):
            with mock.patch.dict(os.environ, common, clear=False):
                os.environ.pop("KANBAN_BOARD_URL", None)
                rc, out = quiet(ks.act, ns(action="fire-start", fire=11, started=T[11], goal_key=BETA))
            check("kanban: without KANBAN_BOARD_URL fire-start --goal-key is rc 4 and writes no state", rc == 4 and not os.path.exists(os.path.join(loop_dir, "kanban-sync.state")), out.strip()[-120:])
            with mock.patch.dict(os.environ, kenv, clear=False):
                rc, out = quiet(ks.act, ns(action="fire-start", fire=11, started=T[11], goal_key=BETA))
                s = kstate()
                r11 = (s.get("fires") or {}).get("11", {})
                check("kanban: fire-start 11 --goal-key Beta -> Beta In progress, Alpha and Gamma To do, Delta Done", rc == 0 and kst(BETA) == ks.IN_PROGRESS and kst(ALPHA) == ks.TODO and kst(GAMMA) == ks.TODO and kst(DELTA) == ks.DONE, out.strip()[-160:])
                check("kanban: the record of fire 11 has goal, card, done_before, started and the requested key", r11.get("goal") == BETA and r11.get("card") == cid(BETA) and r11.get("done_before") == [DELTA] and r11.get("started") == T[11] and r11.get("requested") == BETA, json.dumps(r11)[:200])
                check("kanban: the cue 'working on this goal now (fire 11)' leads Beta's card", desc(BETA).startswith("**Agent:** working on this goal now (fire 11)"), desc(BETA)[:80])
                rc, out = quiet(ks.act, ns(action="fire-start", fire=12, started=T[12], goal_key=GAMMA))
                s = kstate()
                check("kanban: fire-start 12 --goal-key Gamma -> Gamma In progress and Beta STAYS In progress (held for fire 11)", rc == 0 and kst(GAMMA) == ks.IN_PROGRESS and kst(BETA) == ks.IN_PROGRESS and kst(ALPHA) == ks.TODO, out.strip()[-160:])
                check("kanban: both fires recorded, the single record is the latest start", sorted(s.get("fires") or {}) == ["11", "12"] and s.get("fire") == 12 and s.get("goal") == GAMMA and s.get("card") == cid(GAMMA))
                check("kanban: the cue names fire 12 on Gamma's card", desc(GAMMA).startswith("**Agent:** working on this goal now (fire 12)"), desc(GAMMA)[:80])
                # a sync between the starts (the watcher) keeps the records
                rc, out = quiet(ks.act, ns(action="sync"))
                check("kanban: a sync while both fires run keeps their records and columns", rc == 0 and sorted(kstate().get("fires") or {}) == ["11", "12"] and kst(BETA) == ks.IN_PROGRESS and kst(GAMMA) == ks.IN_PROGRESS, out.strip()[-160:])
                # fire 11 ends with Beta still open
                n_comments = len(kboard.comments)
                rc, out = quiet(ks.act, ns(action="fire-end", fire=11, started=T[11], rc=0, duration=30))
                s = kstate()
                check("kanban: fire-end 11 -> Beta In review, Gamma still In progress (fire 12 runs), Alpha To do", rc == 0 and kst(BETA) == ks.IN_REVIEW and kst(GAMMA) == ks.IN_PROGRESS and kst(ALPHA) == ks.TODO, out.strip()[-160:])
                check("kanban: fire 11's record is removed, fire 12's stays", sorted(s.get("fires") or {}) == ["12"])
                check("kanban: fire 11's result is a comment on Beta's card", len(kboard.comments) == n_comments + 1 and kboard.comments[-1][1] == cid(BETA) and "Fire 11" in kboard.comments[-1][2])
                check("kanban: at fire-end the cue stays with the running fire 12 on Gamma's card", desc(GAMMA).startswith("**Agent:** working on this goal now (fire 12)") and not desc(ALPHA).startswith("**Agent:**"), desc(GAMMA)[:80])
                # fire 12 marks Gamma done with a note: Done on the same card; the cue moves to the next open goal
                write_goals(goals_path, [(False, "", ALPHA), (False, "", BETA), (True, "(done by worker 12, evidence x)", GAMMA), (True, "", DELTA)])
                rc, out = quiet(ks.act, ns(action="fire-end", fire=12, started=T[12], rc=0, duration=40))
                s = kstate()
                check("kanban: fire-end 12 after its goal was checked off with a note -> Gamma Done on the same card, no new card", rc == 0 and kst(GAMMA) == ks.DONE and len(kboard.cards) == 4 and "-> Done" in out, out.strip()[-160:])
                check("kanban: no record left; the comment of fire 12 is on Gamma's card; the cue is 'next' on Alpha", not s.get("fires") and kboard.comments[-1][1] == cid(GAMMA) and "Fire 12" in kboard.comments[-1][2] and desc(ALPHA).startswith("**Agent:** next - the loop's next fire starts on this goal"), desc(ALPHA)[:80])
                # two workers; the other one's goal flips to done during this one's fire: not credited to this one
                rc, _ = quiet(ks.act, ns(action="fire-start", fire=13, started=T[13], goal_key=ALPHA))
                rc2, out = quiet(ks.act, ns(action="fire-start", fire=14, started=T[14], goal_key=BETA))
                check("kanban: fire-start 13 Alpha and 14 Beta -> both In progress", rc == 0 and rc2 == 0 and kst(ALPHA) == ks.IN_PROGRESS and kst(BETA) == ks.IN_PROGRESS, out.strip()[-160:])
                write_goals(goals_path, [(False, "", ALPHA), (True, "(done by worker 14)", BETA), (True, "(done by worker 12, evidence x)", GAMMA), (True, "", DELTA)])
                n_comments = len(kboard.comments)
                rc, out = quiet(ks.act, ns(action="fire-end", fire=13, started=T[13], rc=0, duration=9))
                check("kanban: fire-end 13 (Alpha open) while worker 14 checked Beta off -> Alpha In review, Beta Done, the Fire 13 comment on Alpha's card only", rc == 0 and kst(ALPHA) == ks.IN_REVIEW and kst(BETA) == ks.DONE and len(kboard.comments) == n_comments + 1 and kboard.comments[-1][1] == cid(ALPHA) and "Fire 13" in kboard.comments[-1][2] and "-> In review" in out, out.strip()[-160:])
                rc, out = quiet(ks.act, ns(action="fire-end", fire=14, started=T[14], rc=0, duration=9))
                check("kanban: fire-end 14 -> Beta Done with the Fire 14 comment on Beta's card, no record left", rc == 0 and kst(BETA) == ks.DONE and kboard.comments[-1][1] == cid(BETA) and "Fire 14" in kboard.comments[-1][2] and not kstate().get("fires"), out.strip()[-160:])
                # a key that is not in the file
                rc, out = quiet(ks.act, ns(action="fire-start", fire=16, started=T[16], goal_key=OMEGA))
                s = kstate()
                check("kanban: fire-start 16 --goal-key of a goal not in the file -> rc 0, Alpha not In progress, the summary names it", rc == 0 and kst(ALPHA) == ks.TODO and "is not in the goals file" in out and (s.get("fires") or {}).get("16", {}).get("goal") is None and s["fires"]["16"].get("requested") == OMEGA, out.strip()[-200:])
                n_comments = len(kboard.comments)
                rc, out = quiet(ks.act, ns(action="fire-end", fire=16, started=T[16], rc=0, duration=5))
                check("kanban: fire-end 16 -> nothing credited (Alpha To do, no comment, no '->' in the summary)", rc == 0 and kst(ALPHA) == ks.TODO and len(kboard.comments) == n_comments and "->" not in out, out.strip()[-160:])
                # an older fire-start's single record (no fires): fire-end still credits by it
                ks.write_state(loop_dir, dict(ks._carry(kstate()), fire=31, started=T[31], goal=ALPHA, card=cid(ALPHA), done_before=[BETA, GAMMA, DELTA], last_fire={}))
                rc, out = quiet(ks.act, ns(action="fire-end", fire=31, started=T[31], rc=0, duration=5))
                check("kanban: fire-end 31 on the single record of an older fire-start -> Alpha In review, Fire 31 comment on Alpha", rc == 0 and kst(ALPHA) == ks.IN_REVIEW and kboard.comments[-1][1] == cid(ALPHA) and "Fire 31" in kboard.comments[-1][2], out.strip()[-160:])
                # the goal's line renamed (a priority note): the key is unchanged, found, same card
                write_goals(goals_path, [(False, "(priority: high)", ALPHA), (True, "(done by worker 14)", BETA), (True, "(done by worker 12, evidence x)", GAMMA), (True, "", DELTA)])
                rc, out = quiet(ks.act, ns(action="fire-start", fire=18, started=T[18], goal_key=ALPHA))
                check("kanban: fire-start 18 --goal-key Alpha with a priority note prefixed to its line -> Alpha In progress, same card", rc == 0 and kst(ALPHA) == ks.IN_PROGRESS and len(kboard.cards) == 4, out.strip()[-160:])
                rc, out = quiet(ks.act, ns(action="fire-end", fire=18, started=T[18], rc=124, duration=5))
                check("kanban: fire-end 18 rc 124 -> Alpha In review", rc == 0 and kst(ALPHA) == ks.IN_REVIEW, out.strip()[-160:])
                # a serial fire (no --goal-key): the first open goal, and the flip credit as today
                rc, out = quiet(ks.act, ns(action="fire-start", fire=19, started=T[19]))
                s = kstate()
                check("kanban: fire-start 19 without --goal-key -> the first open goal (Alpha) In progress, requested None", rc == 0 and kst(ALPHA) == ks.IN_PROGRESS and (s.get("fires") or {}).get("19", {}).get("goal") == ALPHA and s["fires"]["19"].get("requested") is None, out.strip()[-160:])
                write_goals(goals_path, [(True, "(done by fire 19) (priority: high)", ALPHA), (True, "(done by worker 14)", BETA), (True, "(done by worker 12, evidence x)", GAMMA), (True, "", DELTA)])
                rc, out = quiet(ks.act, ns(action="fire-end", fire=19, started=T[19], rc=0, duration=5))
                check("kanban: fire-end 19 -> Alpha Done (checked off with two notes, same card), Fire 19 comment on Alpha", rc == 0 and kst(ALPHA) == ks.DONE and len(kboard.cards) == 4 and kboard.comments[-1][1] == cid(ALPHA) and "Fire 19" in kboard.comments[-1][2], out.strip()[-160:])
                # pruning
                now = int(time.time())
                stale = {"1": {"goal": GAMMA, "started": 0, "requested": GAMMA, "card": cid(GAMMA), "done_before": []}}
                stale.update({str(100 + i): {"goal": None, "started": now, "requested": None, "card": None, "done_before": []} for i in range(25)})
                ks.write_state(loop_dir, dict(ks._carry(kstate()), fires=stale))
                rc, out = quiet(ks.act, ns(action="fire-start", fire=125, started=now, goal_key=ALPHA))
                s = kstate()
                check("kanban: fire-start 125 prunes the stale record and keeps FIRES_MAX records", rc == 0 and "1" not in (s.get("fires") or {}) and "125" in s["fires"] and len(s["fires"]) == ks.FIRES_MAX, "%d records" % len(s.get("fires") or {}))
                check("kanban: _carry keeps fires across a state write", "fires" in ks._carry(s))

    passed = sum(1 for _n, ok in results if ok)
    print("VERDICT %s %d/%d checks" % ("PASS" if passed == len(results) else "FAIL", passed, len(results)))
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
