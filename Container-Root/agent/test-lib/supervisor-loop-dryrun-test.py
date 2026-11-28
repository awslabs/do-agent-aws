#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""supervisor-loop-dryrun-test.py - offline test of loop.sh's supervisor mode dispatch:
`AUTONOMY_LOOP_DRY_RUN=true AUTONOMY_LOOP_MODE=supervisor loop.sh` on the planner's fixture prints the same
dispatch as supervisor-plan.py (one `WOULD FIRE <N> group=<id> goals=... hashes=...` line per worker) and makes no
claude call; a held resource lock blocks that group as the planner says; an all-done file would create STOP and does not
in a dry run; the serial mode and the planner-failure fallback print one serial WOULD FIRE; a bad mode value runs serial
with a warning. Stdlib only, `python3 -I`; everything happens in a temp directory (its own loop dir, goals file, fake
claude), never in the live loop dir. Exit 0 = every check passed, 1 = a check failed.

    python3 -I test-lib/supervisor-loop-dryrun-test.py [--agent-dir DIR]
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import tempfile


def load_planner(path):
    spec = importlib.util.spec_from_file_location("supervisor_plan", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sha(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(description="offline dry-run test of loop.sh supervisor mode")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--agent-dir", default=os.path.dirname(here), help="the directory holding loop.sh and the planner")
    args = ap.parse_args(argv)
    agent = os.path.abspath(args.agent_dir)
    loop_sh = os.path.join(agent, "loop.sh")
    planner = os.path.join(agent, "supervisor-plan.py")
    sp = load_planner(planner)
    results = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok)))
        print("%s %s%s" % ("PASS" if ok else "FAIL", name, (": " + detail) if detail else ""))

    def read(p):
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()

    with tempfile.TemporaryDirectory(prefix="supervisor-loop-dryrun-") as d:
        goals = os.path.join(d, "goals", "GOALS.md")
        os.makedirs(os.path.dirname(goals))
        with open(goals, "w", encoding="utf-8") as f:
            f.write(sp.FIXTURE)
        fake_log = os.path.join(d, "fake-claude.log")
        fake = os.path.join(d, "fake-claude")
        with open(fake, "w", encoding="utf-8") as f:
            f.write('#!/bin/bash\necho "CALLED $*" >> "%s"\nexit 0\n' % fake_log)
        os.chmod(fake, 0o755)
        print("agent dir %s, temp %s" % (agent, d))

        def env_for(loop_dir, mode="supervisor", extra=None):
            env = {k: v for k, v in os.environ.items() if not k.startswith(("SLACK_", "AUTONOMY_", "SUPERVISOR_", "PLANE_", "KANBAN_", "LOOP_"))}
            env.update({"HOME": d, "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "AUTONOMY_LOOP_DIR": loop_dir,
                        "AUTONOMY_LOOP_GOALS": goals, "AUTONOMY_LOOP_WORKDIR": os.path.join(d, "wd"), "AUTONOMY_LOOP_DRY_RUN": "true",
                        "AUTONOMY_LOOP_INTERVAL": "1", "CLAUDE_BIN": fake, "SLACK_CHAT_ENABLED": "false", "SLACK_WATCH_ENABLED": "false",
                        "SLACK_POST_ENABLED": "false", "LOOP_INBOX": "false", "SLACK_DIR": os.path.join(d, "slack")})
            if mode is not None:
                env["AUTONOMY_LOOP_MODE"] = mode
            env.update(extra or {})
            return env

        def run_loop(name, mode="supervisor", extra=None, goals_text=None):
            loop_dir = os.path.join(d, "loop-" + name)
            os.makedirs(loop_dir)
            if goals_text is not None:
                with open(goals, "w", encoding="utf-8") as f:
                    f.write(goals_text)
            with open(os.path.join(loop_dir, "notes.md"), "w", encoding="utf-8") as f:
                f.write(sp.FIXTURE_NOTES)
            try:
                r = subprocess.run(["bash", loop_sh], capture_output=True, text=True, env=env_for(loop_dir, mode, extra), timeout=90)
                rc, out, err = r.returncode, r.stdout, r.stderr
            except subprocess.TimeoutExpired as e:
                rc, out, err = -1, (e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or ""), "TIMEOUT 90s"
            log = read(os.path.join(loop_dir, "loop.log")) if os.path.exists(os.path.join(loop_dir, "loop.log")) else ""
            return loop_dir, rc, out, err, log

        goals_sha = sha(goals)
        # ---- the planner's own dispatch on the fixture (what the dry run must print)
        pj = os.path.join(d, "plan-direct.json")
        rp = subprocess.run([sys.executable, "-I", planner, "--goals", goals, "--notes", os.path.join(d, "none.md"), "--max-workers", "3", "--json", pj],  # nosemgrep: dangerous-subprocess-use-audit -- test harness argv run without a shell
                            capture_output=True, text=True)
        plan = json.load(open(pj, encoding="utf-8"))
        groups = {g["id"]: g for g in plan["groups"]}
        expected = ["WOULD FIRE %d group=%s goals=%s hashes=%s" % (
            i + 1, gid, ",".join(x["id"].split(" ")[0] for x in groups[gid]["goals"]), " ".join(x["hash"] for x in groups[gid]["goals"]))
            for i, gid in enumerate(plan["dispatch"])]
        check("planner on the fixture: rc 0, dispatch g1 g2 g3 (the high-priority goal first), waiting g4 g5",
              rp.returncode == 0 and plan["dispatch"] == ["g1", "g2", "g3"] and plan["waiting"] == ["g4", "g5"], "dispatch=%s waiting=%s" % (plan["dispatch"], plan["waiting"]))

        # ---- 1. supervisor dry run on the fixture
        ld, rc, out, err, log = run_loop("sup")
        would = [l for l in out.splitlines() if l.startswith("WOULD FIRE")]
        check("supervisor dry run: loop.sh exits 0", rc == 0, "rc=%d err=%r" % (rc, err[-300:]))
        check("supervisor dry run: LOOP MODE supervisor logged with the settings", "LOOP MODE supervisor" in log and "max_workers=3" in log and "DRY RUN" in log, log[-400:])
        check("supervisor dry run: exactly three WOULD FIRE lines = the planner's dispatch (ids and hashes)", would == expected, "got=%s expected=%s" % (would, expected))
        check("supervisor dry run: fire numbers 1, 2, 3 (no END line in a fresh loop.log)", [l.split()[2] for l in would] == ["1", "2", "3"], str(would))
        check("supervisor dry run: the fake claude was never called", not os.path.exists(fake_log), "log exists" if os.path.exists(fake_log) else "")
        check("supervisor dry run: no FIRE BEGIN/END lines in loop.log", " BEGIN " not in log and " END rc=" not in log, log[-300:])
        check("supervisor dry run: the summary names open=6 groups=5 dispatch=g1,g2,g3 waiting=g4,g5", "open=6 groups=5 dispatch=g1,g2,g3 waiting=g4,g5 blocked=- parked=-" in log, log[-600:])
        check("supervisor dry run: plan-1.json and dispatch-1.tsv written under <loop dir>/supervisor, cycle file = 1",
              os.path.exists(os.path.join(ld, "supervisor", "plan-1.json")) and os.path.exists(os.path.join(ld, "supervisor", "dispatch-1.tsv"))
              and read(os.path.join(ld, "supervisor", "cycle")).strip() == "1", str(sorted(os.listdir(os.path.join(ld, "supervisor")))))
        wp = os.path.join(ld, "supervisor", "worker-1-g1.txt")
        wtxt = read(wp) if os.path.exists(wp) else ""
        check("supervisor dry run: the worker prompt section of g1 names its goal, goals-mark.sh, notes-append.sh and the STOP rule",
              "YOUR GOALS" in wtxt and "G7 (line 11)" in wtxt and "goals-mark.sh G<n>" in wtxt and "notes-append.sh" in wtxt and "never create" in wtxt
              and "post only in the Slack thread(s) of your goals: 1793000000.000050" in wtxt, wtxt[:400])
        check("supervisor dry run: the goals file, notes and the fixture are untouched; no STOP, no WAKE, no locks held",
              sha(goals) == goals_sha and read(os.path.join(ld, "notes.md")) == sp.FIXTURE_NOTES and not os.path.exists(os.path.join(ld, "STOP"))
              and not os.path.exists(os.path.join(ld, "WAKE")), "")
        state = read(os.path.join(ld, "loop.state")) if os.path.exists(os.path.join(ld, "loop.state")) else ""
        check("supervisor dry run: loop.state says STOPPED reason=dry-run", state.startswith("STOPPED reason=dry-run"), state)
        check("supervisor dry run: the Slack watch and the bus intake were not run (no slack-watch.log, no bus.err)",
              not os.path.exists(os.path.join(ld, "slack-watch.log")) and not os.path.exists(os.path.join(ld, "bus.err")), str(sorted(os.listdir(ld))))

        # ---- 2. a held lock on G1's path blocks its group: dispatch becomes g1 (G7), g3 (G2), g4 (G3), as the planner says
        ld2 = os.path.join(d, "loop-lock")
        os.makedirs(os.path.join(ld2, "locks"))
        lock_path = sp.lock_path_for(os.path.join(ld2, "locks"), "path:/wd/loop/alpha")
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with open(os.path.join(ld2, "notes.md"), "w", encoding="utf-8") as f:
            f.write(sp.FIXTURE_NOTES)
        r = subprocess.run(["bash", loop_sh], capture_output=True, text=True, env=env_for(ld2), timeout=90)
        os.close(fd)
        would2 = [l.split("goals=")[1].split(" ")[0] for l in r.stdout.splitlines() if l.startswith("WOULD FIRE")]
        log2 = read(os.path.join(ld2, "loop.log"))
        check("held lock path:/wd/loop/alpha: the dry run dispatches G7, G2, G3 and the summary says blocked=g2",
              r.returncode == 0 and would2 == ["G7", "G2", "G3"] and "blocked=g2" in log2, "would=%s rc=%d log=%s" % (would2, r.returncode, log2[-300:]))

        # ---- 3. every goal done: the loop would create STOP (and does not, in a dry run)
        done_text = sp.FIXTURE.replace("- [ ] ", "- [x] (done, fixture) ")
        ld3, rc3, out3, err3, log3 = run_loop("done", goals_text=done_text)
        check("all goals done: `WOULD STOP` printed, 'WOULD create' logged, no STOP file, exit 0, no claude call",
              rc3 == 0 and "WOULD STOP (no open goal)" in out3 and "WOULD create" in log3 and not os.path.exists(os.path.join(ld3, "STOP"))
              and not os.path.exists(fake_log), "rc=%d out=%r log=%s" % (rc3, out3[-200:], log3[-300:]))
        with open(goals, "w", encoding="utf-8") as f:
            f.write(sp.FIXTURE)

        # ---- 4. serial mode (the default, mode unset): one serial WOULD FIRE, no planner run
        ld4, rc4, out4, err4, log4 = run_loop("serial", mode=None)
        check("serial mode (AUTONOMY_LOOP_MODE unset): `WOULD FIRE 1 mode=serial`, LOOP MODE serial, no supervisor dir, no claude call",
              rc4 == 0 and ("WOULD FIRE 1 mode=serial goals=%s" % goals) in out4.splitlines() and "LOOP MODE serial" in log4
              and not os.path.exists(os.path.join(ld4, "supervisor")) and not os.path.exists(fake_log) and "STOPPED reason=dry-run" in read(os.path.join(ld4, "loop.state")),
              "rc=%d out=%r log=%s" % (rc4, out4[-200:], log4[-300:]))

        # ---- 5. the planner missing: LOOP MODE serial with the warning (checked at start), one serial WOULD FIRE
        ld5, rc5, out5, err5, log5 = run_loop("noplanner", extra={"SUPERVISOR_PLAN_BIN": os.path.join(d, "no-such-planner.py")})
        check("planner missing: the loop says so at start and runs serial (WOULD FIRE 1 mode=serial)",
              rc5 == 0 and "is missing: running serial" in log5 and "WOULD FIRE 1 mode=serial" in out5, "rc=%d log=%s" % (rc5, log5[-300:]))

        # ---- 6. the planner failing at run time (an unreadable goals file is not possible here, so a planner that exits 3):
        bad = os.path.join(d, "bad-planner.py")
        with open(bad, "w", encoding="utf-8") as f:
            f.write("import sys\nprint('boom', file=sys.stderr)\nsys.exit(3)\n")
        ld6, rc6, out6, err6, log6 = run_loop("badplanner", extra={"SUPERVISOR_PLAN_BIN": bad})
        check("planner fails rc=3: LOOP WARNING with the rc and the fallback to one serial fire (WOULD FIRE 1 mode=serial)",
              rc6 == 0 and "supervisor planner" in log6 and "failed rc=3" in log6 and "WOULD FIRE 1 mode=serial" in out6, "rc=%d log=%s" % (rc6, log6[-300:]))

        # ---- 7. a bad mode value runs serial with a warning
        ld7, rc7, out7, err7, log7 = run_loop("badmode", mode="turbo")
        check("AUTONOMY_LOOP_MODE=turbo: 'neither serial nor supervisor: running serial' logged, serial WOULD FIRE",
              rc7 == 0 and "neither serial nor supervisor: running serial" in log7 and "WOULD FIRE 1 mode=serial" in out7, "rc=%d log=%s" % (rc7, log7[-300:]))

        # ---- 8. SUPERVISOR_MAX_WORKERS=1: one worker, the high-priority group only
        ld8, rc8, out8, err8, log8 = run_loop("one", extra={"SUPERVISOR_MAX_WORKERS": "1"})
        would8 = [l for l in out8.splitlines() if l.startswith("WOULD FIRE")]
        check("SUPERVISOR_MAX_WORKERS=1: exactly one WOULD FIRE, the high-priority G7", len(would8) == 1 and "goals=G7 " in would8[0] and "max_workers=1" in log8, str(would8))

        # ---- 9. a parked goal is left out: parked file with G1's hash
        ld9 = os.path.join(d, "loop-parked")
        os.makedirs(os.path.join(ld9, "supervisor"))
        g1hash = next(x["hash"] for g in plan["groups"] for x in g["goals"] if x["index"] == 1)
        with open(os.path.join(ld9, "supervisor", "parked"), "w", encoding="utf-8") as f:
            f.write("# hash\tsince\tuntil\tutc\n%s\t1\t99\t2026-11-05T00:00:00Z\n" % g1hash)
        with open(os.path.join(ld9, "notes.md"), "w", encoding="utf-8") as f:
            f.write(sp.FIXTURE_NOTES)
        r9 = subprocess.run(["bash", loop_sh], capture_output=True, text=True, env=env_for(ld9), timeout=90)
        would9 = [l.split("goals=")[1].split(" ")[0] for l in r9.stdout.splitlines() if l.startswith("WOULD FIRE")]
        log9 = read(os.path.join(ld9, "loop.log"))
        check("parked G1: the dry run dispatches G7, G2, G3 and the summary says parked=g2 (the parked file untouched by a dry run)",
              r9.returncode == 0 and would9 == ["G7", "G2", "G3"] and "parked=g2" in log9 and read(os.path.join(ld9, "supervisor", "parked")).count("\n") == 2,
              "would=%s log=%s" % (would9, log9[-300:]))

        check("bash -n loop.sh", subprocess.run(["bash", "-n", loop_sh], capture_output=True).returncode == 0)
        check("loop.sh is executable", bool(os.stat(loop_sh).st_mode & stat.S_IXUSR))

    ok = sum(1 for _n, r in results if r)
    print("VERDICT %s %d/%d checks" % ("PASS" if ok == len(results) else "FAIL", ok, len(results)))
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
