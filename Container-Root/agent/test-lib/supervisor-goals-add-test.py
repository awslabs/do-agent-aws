#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""supervisor-goals-add-test.py - offline test of goals-add.sh's supervisor options (G99, DESIGN.md sections 3, 8
and 11): --priority high|low on a new goal (the marker, the WAKE touch on high only), --set-priority G<n>|L<line>
high|low|normal (one line changes in place, the goal key and hash do not, WAKE on high), --unpark G<n> (the goal's
hash leaves parked and strikes.tsv, the goals file is untouched), and the plain add path unchanged. Stdlib only,
`python3 -I`; runs the script through bash in a temp directory and never touches the live goals file, loop dir or
WAKE flag. Exit 0 = every check passed, 1 = a check failed.

    python3 -I test-lib/supervisor-goals-add-test.py [--agent-dir DIR]
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
    ap = argparse.ArgumentParser(description="offline test of goals-add.sh --priority / --set-priority / --unpark")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--agent-dir", default=os.path.dirname(here), help="the directory holding goals-add.sh and the planner")
    args = ap.parse_args(argv)
    agent = args.agent_dir
    add_sh = os.path.join(agent, "goals-add.sh")
    planner = os.path.join(agent, "supervisor-plan.py")
    sp = load_planner(planner)
    results = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok)))
        print("%s %s%s" % ("PASS" if ok else "FAIL", name, (": " + detail) if detail else ""))

    def lines(p):
        with open(p, encoding="utf-8") as f:
            return f.read().splitlines()

    def run(cmd, env_extra=None):
        env = dict(os.environ)
        env.update(env_extra or {})
        r = subprocess.run(["bash", *cmd], capture_output=True, text=True, env=env)
        return r.returncode, r.stdout.strip(), r.stderr.strip()

    def items(p):
        return [x for x in lines(p) if x.startswith("- [")]

    with tempfile.TemporaryDirectory(prefix="supervisor-goals-add-test-") as d:
        gpath = os.path.join(d, "goals", "GOALS.md")
        ldir = os.path.join(d, "loop")
        os.mkdir(ldir)
        wake = os.path.join(ldir, "WAKE")
        base = {"AUTONOMY_LOOP_GOALS": gpath, "AUTONOMY_LOOP_DIR": ldir}
        print("goals %s, loop dir %s, agent dir %s" % (gpath, ldir, agent))

        # ---- the add path, unchanged
        rc, o, e = run([add_sh, "Goal one", "C0FIXTURE 1793000000.000001"], base)
        check("plain add creates the file and appends `- [ ] Goal one (from Slack ...)`: rc 0, prints the path, no WAKE",
              rc == 0 and o == gpath and os.path.exists(gpath) and "## Goals from Slack" in lines(gpath)
              and items(gpath) == ["- [ ] Goal one (from Slack C0FIXTURE 1793000000.000001)"] and not os.path.exists(wake),
              "rc=%d out=%r err=%r" % (rc, o[:120], e[:120]))
        # ---- --priority
        rc, o, e = run([add_sh, "--priority", "high", "Goal two", "C0FIXTURE 1793000000.000002"], base)
        check("--priority high: the new line reads `- [ ] (priority: high) Goal two (from Slack ...)` and WAKE is touched",
              rc == 0 and items(gpath)[-1] == "- [ ] (priority: high) Goal two (from Slack C0FIXTURE 1793000000.000002)"
              and os.path.exists(wake) and "WAKE touched" in o, "rc=%d out=%r err=%r" % (rc, o[:160], e[:120]))
        goals, _raw = sp.parse_goals(gpath)
        sp.plan(goals, {}, 3)  # plan() annotates each goal with its priority (the marker is read there, not in parse_goals)
        check("--priority high: the planner reads priority high and a key without the marker (mirror-key invariant)",
              len(goals) == 2 and goals[1]["priority"] == "high" and goals[1]["key"] == "Goal two (from Slack C0FIXTURE 1793000000.000002)"
              and goals[1]["hash"] == sp.key_hash("Goal two (from Slack C0FIXTURE 1793000000.000002)"), "%s / %s" % (goals[1]["priority"], goals[1]["key"]))
        os.remove(wake)
        rc, o, e = run([add_sh, "--priority", "low", "Goal three"], base)
        check("--priority low: `- [ ] (priority: low) Goal three`, WAKE not touched", rc == 0 and items(gpath)[-1] == "- [ ] (priority: low) Goal three" and not os.path.exists(wake), "rc=%d %s" % (rc, e[:120]))
        rc, o, e = run([add_sh, "--priority=normal", "Goal four"], base)
        check("--priority=normal: a plain line without a marker", rc == 0 and items(gpath)[-1] == "- [ ] Goal four" and not os.path.exists(wake), "rc=%d %s" % (rc, e[:120]))
        n_before = len(items(gpath))
        rc_a, _o, e_a = run([add_sh, "--priority", "urgent", "Goal x"], base)
        rc_b, _o, _e = run([add_sh, "--priority"], base)
        rc_c, _o, _e = run([add_sh, "--priority", "high"], base)
        rc_d, _o, _e = run([add_sh, "-x", "Goal y"], base)
        check("--priority usage errors (bad level; no level; no goal; an unknown option): rc 1 four times, nothing added",
              (rc_a, rc_b, rc_c, rc_d) == (1, 1, 1, 1) and len(items(gpath)) == n_before and not os.path.exists(wake), "rc=%d/%d/%d/%d %s" % (rc_a, rc_b, rc_c, rc_d, e_a[:100]))
        rc, o, e = run([add_sh, "--priority", "high", "--", "-dash goal"], base)
        check("--priority high -- `-dash goal`: a goal starting with - still lands with the marker, WAKE touched",
              rc == 0 and items(gpath)[-1] == "- [ ] (priority: high) -dash goal" and os.path.exists(wake), "rc=%d %s" % (rc, e[:120]))
        os.remove(wake)
        goals, _raw = sp.parse_goals(gpath)
        check("five goals parsed, G1..G5 in file order", [g["key"] for g in goals][:1] == ["Goal one (from Slack C0FIXTURE 1793000000.000001)"] and len(goals) == 5 and goals[4]["key"] == "-dash goal", str([g["id"] for g in goals]))

        # ---- --set-priority
        before = lines(gpath)
        g1, g3 = goals[0], goals[2]
        rc, o, e = run([add_sh, "--set-priority", "G1", "high"], base)
        after = lines(gpath)
        changed = [i + 1 for i in range(max(len(before), len(after))) if (before[i] if i < len(before) else None) != (after[i] if i < len(after) else None)]
        check("--set-priority G1 high: rc 0, exactly G1's line changed, it reads `- [ ] (priority: high) Goal one ...`, WAKE touched",
              rc == 0 and changed == [g1["line"]] and after[g1["line"] - 1] == "- [ ] (priority: high) Goal one (from Slack C0FIXTURE 1793000000.000001)" and os.path.exists(wake)
              and "set-priority G1 (line %d) high" % g1["line"] in o, "rc=%d changed=%s out=%r err=%r" % (rc, changed, o[:160], e[:120]))
        g_after, _ = sp.parse_goals(gpath)
        sp.plan(g_after, {}, 3)
        check("--set-priority: G1's key and hash unchanged (the cards stay)", g_after[0]["key"] == g1["key"] and g_after[0]["hash"] == g1["hash"] and g_after[0]["priority"] == "high", g_after[0]["hash"])
        os.remove(wake)
        rc, o, e = run([add_sh, "--set-priority", "G1", "normal"], base)
        check("--set-priority G1 normal: rc 0, the file is byte-identical to before, WAKE not touched", rc == 0 and lines(gpath) == before and not os.path.exists(wake), "rc=%d %s" % (rc, e[:120]))
        rc, o, e = run([add_sh, "--set-priority", "L%d" % g3["line"], "high"], base)
        check("--set-priority L<line of G3> high: the low marker is replaced, `- [ ] (priority: high) Goal three`",
              rc == 0 and lines(gpath)[g3["line"] - 1] == "- [ ] (priority: high) Goal three" and os.path.exists(wake), "rc=%d %s" % (rc, lines(gpath)[g3["line"] - 1]))
        os.remove(wake)
        rc, o, e = run([add_sh, "--set-priority", "G3", "low"], base)
        check("--set-priority G3 low: back to `- [ ] (priority: low) Goal three`, the file as before, no WAKE", rc == 0 and lines(gpath) == before and not os.path.exists(wake), "rc=%d" % rc)
        rc, o, e = run([add_sh, "--set-priority", "G3", "low"], base)
        check("--set-priority G3 low again: rc 0 reported unchanged", rc == 0 and "unchanged" in o, "rc=%d out=%r" % (rc, o[:120]))
        rc4, _o, e4 = run([add_sh, "--set-priority", "G99", "high"], base)
        rc2a, _o, _e = run([add_sh, "--set-priority", "G1", "urgent"], base)
        rc2b, _o, _e = run([add_sh, "--set-priority", "G1"], base)
        rc2c, _o, _e = run([add_sh, "--set-priority", "X1", "high"], base)
        rc2d, _o, _e = run([add_sh, "--set-priority", "G1", "high", "extra"], base)
        check("--set-priority errors (missing goal rc 4; bad level, no level, bad id, extra arg rc 2), nothing written, no WAKE",
              rc4 == 4 and (rc2a, rc2b, rc2c, rc2d) == (2, 2, 2, 2) and lines(gpath) == before and not os.path.exists(wake), "rc=%d/%d/%d/%d/%d %s" % (rc4, rc2a, rc2b, rc2c, rc2d, e4[:100]))
        fd = os.open(gpath + ".lock", os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            rc, o, e = run([add_sh, "--set-priority", "G2", "low"], base)
        finally:
            os.close(fd)
        check("--set-priority under a held goals lock: rc 5, nothing written", rc == 5 and lines(gpath) == before, "rc=%d %s" % (rc, e[:120]))
        rc, o, e = run([add_sh, "--set-priority", "G2", "low"], base)
        snap = lines(gpath)
        check("--set-priority G2 low once the lock is free: rc 0, `- [ ] (priority: low) Goal two ...`, no WAKE for low",
              rc == 0 and snap[goals[1]["line"] - 1] == "- [ ] (priority: low) Goal two (from Slack C0FIXTURE 1793000000.000002)" and not os.path.exists(wake), "rc=%d" % rc)
        plan = sp.plan(sp.parse_goals(gpath)[0], {}, 3)
        check("re-plan: the high goal (G5) first, then G1, G3's and G2's low ones last",
              [m["index"] for m in plan["order"]] == [5, 1, 4, 2, 3], str([m["id"] for m in plan["order"]]))

        # ---- --unpark
        sdir = os.path.join(ldir, "supervisor")
        os.mkdir(sdir)
        gh = {g["index"]: g["hash"] for g in goals}
        ppath, spath = os.path.join(sdir, "parked"), os.path.join(sdir, "strikes.tsv")
        with open(ppath, "w", encoding="utf-8") as f:
            f.write("# hash\tsince_cycle\tuntil_cycle\tutc\n%s\t12\t18\t2026-11-05T07:00:00Z\n%s\t12\t18\t2026-11-05T07:00:00Z\n" % (gh[2], gh[4]))
        with open(spath, "w", encoding="utf-8") as f:
            f.write("".join("%s\t%d\t1\t2026-11-05T07:0%d:00Z\n" % (gh[2], 3150 + i, i) for i in range(3)))
            f.write("%s\t3153\t1\t2026-11-05T07:03:00Z\n" % gh[4])
        rc, o, e = run([add_sh, "--unpark", "G2"], base)
        check("--unpark G2: rc 0, G2's hash gone from parked (header + G4 left) and strikes.tsv (G4's line left), goals untouched",
              rc == 0 and sp.read_parked(ppath) == frozenset([gh[4]]) and len(lines(ppath)) == 2 and lines(spath) == ["%s\t3153\t1\t2026-11-05T07:03:00Z" % gh[4]]
              and lines(gpath) == snap and "3 strike(s) removed" in o, "rc=%d out=%r err=%r" % (rc, o[:160], e[:120]))
        rc, o, e = run([add_sh, "--unpark", "G2"], base)
        check("--unpark G2 again: rc 0, `nothing was parked`, files unchanged", rc == 0 and "nothing was parked" in o and len(lines(ppath)) == 2 and len(lines(spath)) == 1, "rc=%d out=%r" % (rc, o[:120]))
        rc4, _o, e4 = run([add_sh, "--unpark", "G99"], base)
        rc2a, _o, _e = run([add_sh, "--unpark"], base)
        rc2b, _o, _e = run([add_sh, "--unpark", "G2", "extra"], base)
        rc2c, _o, _e = run([add_sh, "--unpark", "7"], base)
        check("--unpark errors (missing goal rc 4; no id, extra arg, bare number rc 2), files unchanged",
              rc4 == 4 and (rc2a, rc2b, rc2c) == (2, 2, 2) and len(lines(ppath)) == 2 and len(lines(spath)) == 1, "rc=%d/%d/%d/%d %s" % (rc4, rc2a, rc2b, rc2c, e4[:100]))
        fd = os.open(os.path.join(sdir, "strikes.lock"), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            rc, o, e = run([add_sh, "--unpark", "G4"], base)
        finally:
            os.close(fd)
        check("--unpark under a held strikes lock: rc 5, nothing removed", rc == 5 and sp.read_parked(ppath) == frozenset([gh[4]]), "rc=%d %s" % (rc, e[:120]))
        rc, o, e = run([add_sh, "--unpark", "L%d" % goals[3]["line"]], base)
        check("--unpark L<line of G4> once the lock is free: rc 0, parked and strikes.tsv hold no hash lines", rc == 0 and sp.read_parked(ppath) == frozenset() and lines(spath) == [], "rc=%d %s" % (rc, e[:120]))
        check("--unpark never touched the goals file; neither STOP nor notes.md nor WAKE were written by the option paths",
              lines(gpath) == snap and not os.path.exists(os.path.join(ldir, "STOP")) and not os.path.exists(os.path.join(ldir, "notes.md")) and not os.path.exists(wake))
        # ---- the add path still works after the options (a second file section after the heading is kept in place)
        rc, o, e = run([add_sh, "Goal six", "C0FIXTURE 1793000000.000006"], base)
        check("plain add after the option paths: rc 0, `- [ ] Goal six (from Slack ...)` is the last item, six items",
              rc == 0 and items(gpath)[-1] == "- [ ] Goal six (from Slack C0FIXTURE 1793000000.000006)" and len(items(gpath)) == 6, "rc=%d %s" % (rc, e[:120]))
    passed = sum(1 for _n, ok in results if ok)
    print("VERDICT %s %d/%d checks" % ("PASS" if passed == len(results) else "FAIL", passed, len(results)))
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
