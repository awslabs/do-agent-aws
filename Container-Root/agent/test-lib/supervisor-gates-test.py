#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""supervisor-gates-test.py - offline test of the two flock-gated writers of the supervisor mode (G99, DESIGN.md
sections 7 and 11): goals-mark.sh (a worker marks ONE of its own goals done) and notes-append.sh (one progress-note
line under the notes lock). Stdlib only, `python3 -I`; runs the scripts through bash in a temp directory on the
planner's selftest fixture and never touches the live goals or notes. Exit 0 = every check passed, 1 = a check failed.

    python3 -I test-lib/supervisor-gates-test.py [--agent-dir DIR]
"""
import argparse
import fcntl
import importlib.util
import os
import subprocess
import sys
import tempfile


def load_planner(path):
    spec = importlib.util.spec_from_file_location("supervisor_plan", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv=None):
    ap = argparse.ArgumentParser(description="offline test of goals-mark.sh and notes-append.sh")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--agent-dir", default=os.path.dirname(here), help="the directory holding the scripts and the planner")
    args = ap.parse_args(argv)
    agent = args.agent_dir
    mark_sh = os.path.join(agent, "goals-mark.sh")
    notes_sh = os.path.join(agent, "notes-append.sh")
    planner = os.path.join(agent, "supervisor-plan.py")
    sp = load_planner(planner)
    results = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok)))
        print("%s %s%s" % ("PASS" if ok else "FAIL", name, (": " + detail) if detail else ""))

    def lines(p):
        with open(p, encoding="utf-8") as f:
            return f.read().splitlines()

    def run(cmd, env_extra=None, unset=()):
        env = dict(os.environ)
        env.update(env_extra or {})
        for k in unset:
            env.pop(k, None)
        r = subprocess.run(["bash", *cmd], capture_output=True, text=True, env=env)
        return r.returncode, r.stdout.strip(), r.stderr.strip()

    with tempfile.TemporaryDirectory(prefix="supervisor-gates-test-") as d:
        gpath = os.path.join(d, "GOALS.md")
        ldir = os.path.join(d, "loop")
        os.mkdir(ldir)
        with open(gpath, "w", encoding="utf-8") as f:
            f.write(sp.FIXTURE)
        goals, _raw = sp.parse_goals(gpath)
        h1, h2 = goals[0]["hash"], goals[1]["hash"]
        base = {"AUTONOMY_LOOP_GOALS": gpath, "AUTONOMY_LOOP_DIR": ldir}
        print("fixture %s (%d goals, %d open; G1 hash %s, G2 hash %s); agent dir %s" % (
            gpath, len(goals), sum(1 for g in goals if not g["done"]), h1, h2, agent))
        before = lines(gpath)

        # ---- goals-mark.sh
        rc, o, e = run([mark_sh, "G1", "--note", "done by the gates test, fire 0"], dict(base, WORKER_GOAL_HASHES="%s %s" % (h1, h2)))
        after = lines(gpath)
        changed = [i + 1 for i in range(max(len(before), len(after))) if (before[i] if i < len(before) else None) != (after[i] if i < len(after) else None)]
        check("goals-mark G1 --note with its hash in WORKER_GOAL_HASHES: rc 0, exactly line 5 changed", rc == 0 and changed == [5], "rc=%d changed=%s %s" % (rc, changed, e[:200]))
        check("goals-mark: line 5 reads `- [x] (done by the gates test, fire 0) Fix the README typo ...`",
              len(after) >= 5 and after[4].startswith("- [x] (done by the gates test, fire 0) Fix the README typo"), after[4] if len(after) >= 5 else "")
        g_after, _ = sp.parse_goals(gpath)
        check("goals-mark: G1 is done, its key and hash unchanged (the cards stay)", g_after[0]["done"] and g_after[0]["hash"] == h1 and g_after[0]["key"] == goals[0]["key"], g_after[0]["hash"])
        check("goals-mark prints the old and the new line", "marked G1 (line 5) done" in o and "- - [ ]" in o and "+ - [x]" in o, o[:200])
        rc, _o, e = run([mark_sh, "G2"], dict(base, WORKER_GOAL_HASHES=h1))
        check("goals-mark G2 with another worker's hash: rc 3, nothing written", rc == 3 and lines(gpath) == after, "rc=%d %s" % (rc, e[:160]))
        rc, _o, e = run([mark_sh, "G2"], base, unset=("WORKER_GOAL_HASHES",))
        check("goals-mark with WORKER_GOAL_HASHES unset (not a worker): rc 3 naming the variable, nothing written",
              rc == 3 and lines(gpath) == after and "WORKER_GOAL_HASHES" in e, "rc=%d %s" % (rc, e[:160]))
        rc, _o, e = run([mark_sh, "G2"], dict(base, WORKER_GOAL_HASHES=""))
        check("goals-mark with WORKER_GOAL_HASHES empty: rc 3, nothing written", rc == 3 and lines(gpath) == after, "rc=%d" % rc)
        rc, _o, e = run([mark_sh, "G1"], dict(base, WORKER_GOAL_HASHES=h1))
        rc6, _o, _e6 = run([mark_sh, "G6"], dict(base, WORKER_GOAL_HASHES=goals[5]["hash"]))
        check("goals-mark on done goals (G1 again; G6, the fixture's `- [x]`): rc 4 twice", rc == 4 and rc6 == 4, "rc=%d/%d %s" % (rc, rc6, e[:120]))
        rc, _o, e = run([mark_sh, "L99"], dict(base, WORKER_GOAL_HASHES=h1))
        check("goals-mark on a missing goal (L99): rc 4", rc == 4, "rc=%d %s" % (rc, e[:120]))
        rc0, _o, _e = run([mark_sh], base)
        rc1, _o, _e = run([mark_sh, "G2", "--bogus"], dict(base, WORKER_GOAL_HASHES=h2))
        rc2, _o, _e = run([mark_sh, "7"], dict(base, WORKER_GOAL_HASHES=h2))
        check("goals-mark usage errors (no target; unknown option; a bare number): rc 2 three times", rc0 == 2 and rc1 == 2 and rc2 == 2, "rc=%d/%d/%d" % (rc0, rc1, rc2))
        rc, _o, e = run([mark_sh, "G2", "--note", "unbalanced (note"], dict(base, WORKER_GOAL_HASHES=h2))
        check("goals-mark with a note that would change the key: rc 6, nothing written", rc == 6 and lines(gpath) == after, "rc=%d %s" % (rc, e[:120]))
        fd = os.open(gpath + ".lock", os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            rc, _o, e = run([mark_sh, "G2"], dict(base, WORKER_GOAL_HASHES=h2))
        finally:
            os.close(fd)
        check("goals-mark under a held goals lock: rc 5, nothing written", rc == 5 and lines(gpath) == after, "rc=%d %s" % (rc, e[:120]))
        rc, _o, e = run([mark_sh, "G2"], dict(base, WORKER_GOAL_HASHES=h2))
        snap = lines(gpath)
        check("goals-mark G2 without a note once the lock is free: rc 0, line 6 `- [x] Measure the beta ...`",
              rc == 0 and len(snap) >= 6 and snap[5].startswith("- [x] Measure the beta"), "rc=%d %s" % (rc, e[:120]))
        check("goals-mark wrote neither STOP nor notes.md", not os.path.exists(os.path.join(ldir, "STOP")) and not os.path.exists(os.path.join(ldir, "notes.md")))

        # ---- notes-append.sh
        npath = os.path.join(ldir, "notes.md")
        line1 = "- 2026-11-05 ~06:50Z fire 0 (G1 line 5 DONE): gates test line one"
        rc, o, e = run([notes_sh, line1], base)
        check("notes-append creates notes.md and appends line 1: rc 0, read back, reports `appended line 1`",
              rc == 0 and os.path.exists(npath) and lines(npath) == [line1] and "appended line 1" in o, "rc=%d %s %s" % (rc, o[:120], e[:120]))
        rc, o, e = run([notes_sh, "two\nlines\twith a tab  "], base)
        check("notes-append collapses newlines and tabs and adds the missing `- `", rc == 0 and lines(npath)[-1] == "- two lines with a tab", repr(lines(npath)[-1]))
        with open(npath, "ab") as f:
            f.write(b"- a line without a trailing newline")
        rc, o, e = run([notes_sh, "- line four"], base)
        check("notes-append completes a missing trailing newline first: 4 lines, nothing joined",
              rc == 0 and lines(npath) == [line1, "- two lines with a tab", "- a line without a trailing newline", "- line four"], str(lines(npath)[-2:]))
        nf = os.path.join(d, "note.txt")
        with open(nf, "w", encoding="utf-8") as f:
            f.write("- line five from a file\n")
        rc, o, e = run([notes_sh, "-f", nf], base)
        check("notes-append -f FILE: rc 0, the file's line appended", rc == 0 and lines(npath)[-1] == "- line five from a file", "rc=%d %s" % (rc, e[:120]))
        rc, o, e = run([notes_sh, "   "], base)
        rce, _o, _e = run([notes_sh], base)
        check("notes-append with an empty note / no argument: rc 2 twice, nothing written", rc == 2 and rce == 2 and len(lines(npath)) == 5, "rc=%d/%d" % (rc, rce))
        fd = os.open(os.path.join(ldir, "notes.lock"), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            rc, o, e = run([notes_sh, "- line six under a held lock"], dict(base, NOTES_LOCK_WAIT="1"))
        finally:
            os.close(fd)
        check("notes-append under a held notes lock (wait 1 s): rc 5, nothing written", rc == 5 and len(lines(npath)) == 5, "rc=%d %s" % (rc, e[:120]))
        rc, o, e = run([notes_sh, "- line six once the lock is free"], base)
        check("notes-append once the lock is free: rc 0, line 6", rc == 0 and len(lines(npath)) == 6 and "appended line 6" in o, "rc=%d" % rc)
        check("notes-append never touched the goals file", lines(gpath) == snap)
    passed = sum(1 for _n, ok in results if ok)
    print("VERDICT %s %d/%d checks" % ("PASS" if passed == len(results) else "FAIL", passed, len(results)))
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
