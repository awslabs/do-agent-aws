#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""supervisor-readme-test.py - offline test of the "Supervisor mode" subsection of the project's docs/manual/autonomy.md
and the mode line in loop-once.sh's header.

  (a) README.md, section "# Autonomy loop": exactly one such heading; inside the section (up to the next top-level heading)
      exactly one paragraph lead `**Supervisor mode.**`, the section's last subsection; a settings table with one row per
      setting loop.sh reads with a default in its supervisor block (the eight; SUPERVISOR_PLAN_BIN is container-internal and
      excepted), each row's default equal to loop.sh's `${NAME:-default}` ("(empty)" for an empty default) and to the .env
      export; the phrases the design asks for - the switch-on (.env.local, ./stop.sh && ./run.sh), the dry run
      (AUTONOMY_LOOP_DRY_RUN=true, WOULD FIRE, STOPPED reason=dry-run), the priority marker and the chat phrases of rule 2,
      the three goals-add.sh options (--priority, --set-priority, --unpark), strikes and parking (strikes.tsv, parked), the
      plan files and the locks, the two gated scripts, what is not implemented (the model pass, the parking post), the spoke
      supervisor distinction ("Spoke agents"), loop-once.sh; every /agent/<script> the subsection names exists in
      Container-Root/agent; the .env comment on AUTONOMY_LOOP_MODE points to the subsection by its lead; git: README.md only
      gains lines and every added line is a line of the subsection.
  (b) loop-once.sh: bash -n rc 0; a header comment line (before the first code line) names AUTONOMY_LOOP_MODE, says SERIAL
      and points to the README subsection; its code reads none of the eight settings (the header's claim); git: deletions 0
      and every added line is a comment line.
  (c) cross-checks of the README's claims against the staged sources: the loop.sh tokens it quotes exist in loop.sh, the
      goals-mark.sh and notes-append.sh exit codes it names are the ones their headers declare, the chat phrases it names are
      in slack-chat.sh's rule 2, goals-add.sh carries the three options.

    python3 -I test-lib/supervisor-readme-test.py [--repo /do-agent-aws]

Prints one PASS/FAIL line per check and `VERDICT PASS|FAIL n/m checks`; exit 0 only on PASS. Read-only.
"""
import argparse
import os
import re
import subprocess
import sys

NAMES = ["AUTONOMY_LOOP_MODE", "AUTONOMY_LOOP_DRY_RUN", "SUPERVISOR_MAX_WORKERS", "SUPERVISOR_MODEL_PASS",
         "SUPERVISOR_MODEL_TIMEOUT", "SUPERVISOR_STRIKES_MAX", "SUPERVISOR_PARK_CYCLES", "SUPERVISOR_WORKER_OPTS"]
PLANNER_PATH = "SUPERVISOR_PLAN_BIN"
LEAD = "**Supervisor mode.**"
SECTION = "# Autonomy loop"
POINTER = 'docs/manual/autonomy.md "Autonomy loop", "Supervisor mode"'
# what the subsection must say, as exact substrings
PHRASES = [
    ("switch-on in .env.local", "`.env.local`"), ("restart", "`./stop.sh && ./run.sh`"),
    ("dry run setting", "`AUTONOMY_LOOP_DRY_RUN=true`"), ("dry run line", "WOULD FIRE"),
    ("dry run state", "`STOPPED reason=dry-run`"), ("priority marker", "`(priority: high)`"),
    ("priority option", "--priority high"), ("low priority option", "--priority low"),
    ("set-priority", "--set-priority G<n>|L<line> high|low|normal"), ("unpark", "--unpark G<n>"),
    ("chat: high priority", "high priority"), ("chat: first", " first,"), ("chat: urgent", "urgent"), ("chat: ASAP", "ASAP"),
    ("chat: top priority", "top priority"), ("chat: can wait", "can wait"), ("chat: low priority", "low priority"),
    ("chat: make G<n> high priority", "make G<n> high priority"), ("chat: G<n> first", "G<n> first"),
    ("chat: G<n> can wait", "G<n> can wait"), ("chat: G<n> back to normal", "G<n> back to normal"),
    ("strikes file", "`/wd/loop/supervisor/strikes.tsv`"), ("parked file", "`/wd/loop/supervisor/parked`"),
    ("plan dir", "`/wd/loop/supervisor/`"), ("locks", "`/wd/loop/locks/<sha256 of the key>.lock`"),
    ("goals-mark.sh", "/agent/goals-mark.sh"), ("notes-append.sh", "/agent/notes-append.sh"),
    ("planner", "/agent/supervisor-plan.py"), ("planner --explain", "--explain"),
    ("model pass not implemented", "not implemented and the deterministic plan stands"),
    ("parking post not implemented", "announces a parking is not implemented"),
    ("spoke supervisor", '"Spoke agents"'), ("loop-once.sh", "`/agent/loop-once.sh` runs one serial fire whatever the mode"),
    ("WORKER_GOAL_HASHES", "`WORKER_GOAL_HASHES`"), ("STOP by the loop", "the loop, not a worker, creates `STOP`"),
    ("no STOP step", "never creates `/wd/loop/STOP`"), ("WAKE on high", "touches the WAKE flag"),
    ("loop.state", "`FIRING fire=<N>,<M> workers=K cycle=C mode=supervisor`"),
    ("worker is a fire", "Each worker is a fire of its own"), ("over-merge", "over-merges"),
]
LOOP_TOKENS = ["STOPPED reason=dry-run", "WOULD FIRE", "mode=supervisor", "LOOP SUPERVISOR cycle", "group_goals=",
               "LOOP MODE", "WORKER_GOAL_HASHES", "goals-mark.sh", "notes-append.sh", "-mtime +2"]
CHAT_PHRASES = ["high priority", "urgent", "ASAP", "top priority", "can wait", "low priority", "make G<n> high priority",
                "G<n> first", "G<n> can wait", "G<n> back to normal"]
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok)))
    print("%s %s%s" % ("PASS" if ok else "FAIL", name, (" - " + detail) if detail else ""))
    return ok


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def git(repo, *args):
    r = subprocess.run(["git", "-c", "safe.directory=" + repo, "-C", repo, *args], capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def loop_defaults(loop_text):
    """NAME -> default for every `NAME=${NAME:-default}` line of loop.sh's supervisor block (the env test's rule)."""
    out = {}
    for line in loop_text.splitlines():
        m = re.match(r'^(AUTONOMY_LOOP_MODE|AUTONOMY_LOOP_DRY_RUN|SUPERVISOR_[A-Z_]+)=\$\{\1:-(.*)\}$', line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def cell(default):
    return "`%s`" % default if default != "" else "(empty)"


def verdict():
    ok = sum(1 for _n, r in RESULTS if r)
    print("VERDICT %s %d/%d checks" % ("PASS" if ok == len(RESULTS) else "FAIL", ok, len(RESULTS)))
    return 0 if ok == len(RESULTS) else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="/do-agent-aws")
    a = ap.parse_args()
    src = os.path.join(a.repo, "Container-Root", "agent")
    readme_p = os.path.join(a.repo, "README.md")
    readme = read(readme_p)
    lines = readme.splitlines()
    loop_text = read(os.path.join(src, "loop.sh"))
    env_text = read(os.path.join(a.repo, ".env"))

    # ---- (a) the README subsection
    heads = [i for i, l in enumerate(lines) if l == SECTION]
    if not check("a1 exactly one '%s' heading in README.md" % SECTION, len(heads) == 1, "at line(s) %s" % [i + 1 for i in heads]):
        return verdict()
    start = heads[0]
    nxt = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("# ")), len(lines))
    leads = [i for i in range(start, nxt) if lines[i].startswith(LEAD)]
    if not check("a2 exactly one '%s' lead inside the section (lines %d-%d, next heading %r)" % (LEAD, start + 1, nxt, lines[nxt] if nxt < len(lines) else "EOF"),
                 len(leads) == 1, "at line(s) %s" % [i + 1 for i in leads]):
        return verdict()
    sub_start = leads[0]
    sub_lines = lines[sub_start:nxt]
    sub = "\n".join(sub_lines)
    later = [i + 1 for i in range(sub_start + 1, nxt) if lines[i].startswith("**")]
    check("a3 the subsection is the section's last (no later bold lead before the next heading)", not later, "later leads at %s" % later)
    rows = {}
    for l in sub_lines:
        m = re.match(r'^\| `([A-Z_]+)` \| (.+?) \| (.*) \|$', l)
        if m:
            rows[m.group(1)] = (m.group(2), m.group(3))
    defaults = loop_defaults(loop_text)
    loop_names = sorted(n for n in defaults if n != PLANNER_PATH)
    check("a4 the settings table has exactly the names loop.sh reads with a default in its supervisor block (%s excepted) == the eight" % PLANNER_PATH,
          sorted(rows) == loop_names == sorted(NAMES), "table=%s loop=%s" % (sorted(rows), loop_names))
    exports = {m.group(1): m.group(2) for m in re.finditer(r'^export ([A-Z_]+)=(.*)$', env_text, re.M)}
    for n in NAMES:
        shown = rows.get(n, ("<no row>", ""))[0]
        want = cell(defaults[n]) if n in defaults else "<not in loop.sh>"
        want_env = cell(exports[n]) if n in exports else "<not in .env>"
        check("a5 %s: table default %s == loop.sh %s == .env %s" % (n, shown, want, want_env), shown == want == want_env)
    # wrapped prose: a phrase may break across a line, so match on whitespace-normalised text (first run: one miss on a wrap)
    sub_norm = re.sub(r'\s+', ' ', sub)
    missing = [k for k, p in PHRASES if p not in sub_norm]
    check("a6 the subsection holds each of the %d required phrases (whitespace-normalised)" % len(PHRASES), not missing, "missing: %s" % missing)
    scripts = sorted(set(re.findall(r'/agent/([A-Za-z0-9_.-]+\.(?:sh|py))', sub)))
    absent = [s for s in scripts if not os.path.exists(os.path.join(src, s))]
    check("a7 every /agent/<script> the subsection names exists in Container-Root/agent (%s)" % ", ".join(scripts), scripts and not absent, "absent: %s" % absent)
    m = re.search(r'^### AUTONOMY_LOOP_MODE - .*?(?=^export AUTONOMY_LOOP_MODE=)', env_text, re.S | re.M)
    pointer = m.group(0) if m else ""
    check("a8 the .env comment on AUTONOMY_LOOP_MODE points to %s and the lead resolves" % POINTER, POINTER in pointer and len(leads) == 1,
          ("..." + pointer.replace("\n", " ")[-90:]) if pointer else "no AUTONOMY_LOOP_MODE comment block in .env")
    rc, ns, _e = git(a.repo, "diff", "--numstat", "--", "README.md")
    parts = ns.strip().split("\t") if ns.strip() else []
    check("a9 git diff --numstat README.md: additions > 0, deletions 0", rc == 0 and len(parts) == 3 and parts[0].isdigit() and int(parts[0]) > 0 and parts[1] == "0",
          ns.strip() or "(no diff)")
    rc, diff, _e = git(a.repo, "diff", "--", "README.md")
    added = [l[1:] for l in diff.splitlines() if l.startswith("+") and not l.startswith("+++")]
    subset = set(sub_lines)
    stray = [l for l in added if l.strip() and l not in subset]
    check("a10 every added README line is a line of the subsection", rc == 0 and bool(added) and not stray,
          "%d added, %d subsection lines, stray: %s" % (len(added), len(sub_lines), [s[:60] for s in stray][:3]))
    check("a11 the subsection names no working document outside the repository (no DESIGN.md)", "DESIGN.md" not in sub)

    # ---- (b) loop-once.sh
    lo_p = os.path.join(src, "loop-once.sh")
    lo_lines = read(lo_p).splitlines()
    r = subprocess.run(["bash", "-n", lo_p], capture_output=True, text=True)
    check("b1 bash -n loop-once.sh rc 0", r.returncode == 0, r.stderr.strip()[:200])
    first_code = next((i for i, l in enumerate(lo_lines) if l.strip() and not l.startswith("#")), len(lo_lines))
    header = lo_lines[:first_code]
    mode_lines = [l for l in header if "AUTONOMY_LOOP_MODE" in l]
    check("b2 a header comment line (before the first code line, %d) names AUTONOMY_LOOP_MODE and says SERIAL" % (first_code + 1),
          bool(mode_lines) and any("SERIAL" in l for l in mode_lines), " | ".join(mode_lines)[:200])
    check("b3 the header points to the README subsection (%s)" % POINTER, any(POINTER in l for l in header))
    code_only = "\n".join(l for l in lo_lines[first_code:] if not l.lstrip().startswith("#"))
    reads = [n for n in NAMES + [PLANNER_PATH] if n in code_only]
    check("b4 loop-once.sh's code reads none of the supervisor settings (the header's claim)", not reads, "found: %s" % reads)
    rc, ns, _e = git(a.repo, "diff", "--numstat", "--", "Container-Root/agent/loop-once.sh")
    parts = ns.strip().split("\t") if ns.strip() else []
    rc2, diff, _e2 = git(a.repo, "diff", "--", "Container-Root/agent/loop-once.sh")
    added = [l[1:] for l in diff.splitlines() if l.startswith("+") and not l.startswith("+++")]
    check("b5 git diff loop-once.sh: deletions 0 and every added line a comment line",
          rc == 0 and rc2 == 0 and len(parts) == 3 and parts[1] == "0" and bool(added) and all(l.startswith("#") for l in added),
          "%s; %d added" % (ns.strip() or "(no diff)", len(added)))

    # ---- (c) the README's claims against the staged sources
    miss = [t for t in LOOP_TOKENS if t not in loop_text]
    check("c1 every loop.sh token the README quotes exists in loop.sh (%d tokens)" % len(LOOP_TOKENS), not miss, "missing: %s" % miss)
    gm_header = "\n".join(l for l in read(os.path.join(src, "goals-mark.sh")).splitlines() if l.startswith("#"))
    codes = ["0 marked", "3 not yours", "4 no such goal", "5 goals lock busy", "6 the line changed"]
    miss = [c for c in codes if c not in gm_header]
    check("c2 goals-mark.sh's header declares the exit codes the README names (%s)" % ", ".join(codes), not miss, "missing: %s" % miss)
    na_header = "\n".join(l for l in read(os.path.join(src, "notes-append.sh")).splitlines() if l.startswith("#"))
    check("c3 notes-append.sh's header declares exit 5 for the busy lock (the README's claim)", "5 the lock was not free" in na_header)
    sc = read(os.path.join(src, "slack-chat.sh"))
    miss = [p for p in CHAT_PHRASES if p not in sc]
    check("c4 the chat phrases the README names are in slack-chat.sh (%d phrases)" % len(CHAT_PHRASES), not miss, "missing: %s" % miss)
    ga = read(os.path.join(src, "goals-add.sh"))
    miss = [o for o in ["--priority", "--set-priority", "--unpark"] if o not in ga]
    check("c5 goals-add.sh carries the three options the README names", not miss, "missing: %s" % miss)
    check("c6 the README's WAKE claim: goals-add.sh touches WAKE on a high priority", "WAKE" in ga)
    return verdict()


if __name__ == "__main__":
    sys.exit(main())
