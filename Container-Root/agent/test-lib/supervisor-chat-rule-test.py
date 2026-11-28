#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""supervisor-chat-rule-test.py - offline test of slack-chat.sh's rule 2 in supervisor mode:
the prompt the chat responder gives the model tells it to pass goals-add.sh --priority high|low when the person says how
urgent a NEW goal is, and to run goals-add.sh --set-priority G<n> high|low|normal when the person re-ranks a goal that is
already in the file. Three kinds of check, stdlib only, `python3 -I`, nothing live touched (no Slack, no claude call, no
live goals file, no WAKE flag):
  (a) the source: bash -n passes; the RULES block still has exactly the rules 1, 2 and 3; rule 2 holds the priority words,
      both option forms through ${GOALS_ADD_CMD} (the path the allow rule Bash(/agent/goals-add.sh:*) covers - a prefix
      rule, so the options pass through it), the G<n> / L<line> explanation and the exit codes 4, 5 and 6; the header
      comment says the same; the default claude options still allow goals-add.sh;
  (b) the rendered prompt: the PROMPT=... assignment is cut out of the script and run through bash with fixture values
      (set -u, so a variable the script never sets fails the render), so the text the model actually gets is checked -
      the fixture path and the thread ts substituted into every goals-add.sh call, no ${...} left unexpanded, no stray
      quote broke the string (the render exits 0 and ends with rule 3), the ts fallback to the message's own ts when it
      is not in a thread;
  (c) the interface the rule promises exists: goals-add.sh --help names --priority high|low and --set-priority
      G<n>|L<line> high|low|normal, and a --set-priority run on a fixture goals file in a temp dir, spelled as the rule
      spells it (G<n> high, L<line> low, G<n> normal, an unknown G<n>), changes exactly that line, removes the marker on
      normal and exits 4 for no such goal - the three facts rule 2 tells the model.
Exit 0 = every check passed, 1 = a check failed.

    python3 -I test-lib/supervisor-chat-rule-test.py [--agent-dir DIR]
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

REQUIRED_IN_RULE_2 = [
    # the plain add, unchanged
    "${GOALS_ADD_CMD} '<one-line goal>' '${M_CH} ${M_THREAD:-${M_TS}}'",
    # the new goal's priority: the words that set it and the option before the goal text
    "high priority, first, urgent, ASAP or top priority",
    "${GOALS_ADD_CMD} --priority high '<one-line goal>' '${M_CH} ${M_THREAD:-${M_TS}}'",
    "can wait or is low priority, --priority low",
    "otherwise no option",
    # re-ranking a goal already in the file
    "'make G<n> high priority'",
    "'G<n> first'",
    "'G<n> can wait'",
    "${GOALS_ADD_CMD} --set-priority G<n> high|low|normal",
    "board.sh's number, the n-th checkbox goal",
    "done ones included",
    "ask when it is not clear which goal they mean",
    "'(priority: high|low)'",
    "normal removes it",
    # the exit codes goals-add.sh documents for --set-priority (planner codes 4, 5, 6)
    "Exit 4 means no such goal",
    "L<n> addresses that line",
    "5 that the goals file was busy",
    "6 that the line changed meanwhile",
]

FIXTURE_VARS = {
    "M_TS": "1793000000.000123", "M_CH": "C0FIXTURE", "M_USER": "U0FIXTURE",
    "M_THREAD": "1793000000.000100", "M_REPLY_THREAD": "1793000000.000100",
    "M_TEXT": "make G3 high priority", "NEWER_TEXT": "", "STATUS_TEXT": "STATUS fixture",
    "GOALS_TEXT": "GOALS fixture", "NOTES_TEXT": "NOTES fixture",
    "THREAD_NOTE": "in its thread (thread_ts 1793000000.000100)", "THREAD_ARG": " '1793000000.000100'",
    "SLACK_POST_CMD": "/agent/slack-post.sh", "GOALS_ADD_CMD": "/agent/goals-add.sh",
    "AUTONOMY_LOOP_DIR": "/wd/loop",
}


def sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def main(argv=None):
    ap = argparse.ArgumentParser(description="offline test of slack-chat.sh rule 2 (priority / --set-priority)")
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--agent-dir", default=os.path.dirname(here), help="the directory holding slack-chat.sh and goals-add.sh")
    args = ap.parse_args(argv)
    agent = args.agent_dir
    chat_sh = os.path.join(agent, "slack-chat.sh")
    add_sh = os.path.join(agent, "goals-add.sh")
    results = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok)))
        print("%s %s%s" % ("PASS" if ok else "FAIL", name, (": " + detail) if detail else ""))

    def run(cmd, env_extra=None, stdin=None):
        env = dict(os.environ)
        env.update(env_extra or {})
        r = subprocess.run(cmd, capture_output=True, text=True, env=env, input=stdin)  # nosemgrep: dangerous-subprocess-use-audit -- test harness argv run without a shell
        return r.returncode, r.stdout, r.stderr

    with open(chat_sh, encoding="utf-8") as f:
        src = f.read()
    lines = src.splitlines()
    print("slack-chat.sh %s (%d lines), goals-add.sh %s" % (chat_sh, len(lines), add_sh))

    # ---- (a) the source
    rc, _o, e = run(["bash", "-n", chat_sh])
    check("bash -n slack-chat.sh exits 0", rc == 0, e.strip()[:200])
    rules_at = [i for i, l in enumerate(lines) if l == "RULES:"]
    check("exactly one RULES: line in the prompt", len(rules_at) == 1, "at %s" % [i + 1 for i in rules_at])
    numbered = [l for l in lines if re.match(r"^[0-9]+\. ", l)]
    check("the RULES block has exactly the rules 1, 2 and 3 (one line each)",
          [l[:3] for l in numbered] == ["1. ", "2. ", "3. "], "%r" % [l[:40] for l in numbered])
    rule2 = [l for l in lines if l.startswith("2. ")]
    rule2 = rule2[0] if rule2 else ""
    for needle in REQUIRED_IN_RULE_2:
        check("rule 2 holds %r" % needle, needle in rule2)
    check("rule 2 names goals-add.sh only through ${GOALS_ADD_CMD} (the path the allow rule covers), 3 calls",
          rule2.count("${GOALS_ADD_CMD}") == 3 and "/agent/goals-add.sh" not in rule2,
          "count=%d" % rule2.count("${GOALS_ADD_CMD}"))
    check("rule 2 has no double quote and no backtick (it sits inside the double-quoted PROMPT string)",
          '"' not in rule2 and "`" not in rule2)
    check("rule 2 says the loop's next cycle starts at once on high (the WAKE touch of goals-add.sh)",
          "starts its next cycle at once" in rule2)
    check("rule 3 still forbids every other command and the STOP flag",
          any(l.startswith("3. ") and "do not run anything else" in l and "STOP" in l for l in lines))
    header = "\n".join(lines[:60])
    check("the header comment names --priority high|low and --set-priority G<n> high|low|normal",
          "--priority high|low" in header and "--set-priority G<n> high|low|normal" in header)
    # the claude options: the shipped default skips the permission checks (every call the rules name runs), and the
    # documented safe value in the header names Bash(/agent/goals-add.sh:*) - a prefix rule, so the options pass through it
    opts = [l for l in lines if not l.lstrip().startswith("#") and "SLACK_CHAT_CLAUDE_OPTS=" in l]
    check("the SLACK_CHAT_CLAUDE_OPTS default is --dangerously-skip-permissions or an allow list naming goals-add.sh",
          len(opts) == 1 and ("--dangerously-skip-permissions" in opts[0] or "Bash(/agent/goals-add.sh:*)" in opts[0]),
          "%r" % [l[:160] for l in opts])
    doc_opts = [l for l in lines[:140] if l.lstrip().startswith("#") and "Bash(/agent/goals-add.sh:*)" in l]
    check("the header's documented allow list names Bash(/agent/goals-add.sh:*) (a prefix rule: --priority and --set-priority pass)",
          len(doc_opts) >= 1, "%d comment lines" % len(doc_opts))

    # ---- (b) the rendered prompt: cut the PROMPT=... assignment out and render it with fixture values
    start = [i for i, l in enumerate(lines) if l.lstrip().startswith('PROMPT="SLACK CHAT:')]
    end = [i for i, l in enumerate(lines) if l.startswith("3. ") and l.endswith('"')]
    check("the PROMPT assignment is found (one start, one closing rule-3 line, start before end)",
          len(start) == 1 and len(end) == 1 and start[0] < end[0], "start=%s end=%s" % (start, end))
    if len(start) == 1 and len(end) == 1 and start[0] < end[0]:
        block = "\n".join(lines[start[0]:end[0] + 1]).lstrip()

        def render(overrides):
            vals = dict(FIXTURE_VARS)
            vals.update(overrides)
            script = "set -u\n" + "".join("%s=%s\n" % (k, sh_quote(v)) for k, v in vals.items())
            script += block + "\nprintf '%s' \"${PROMPT}\"\n"
            return run(["bash", "-s"], stdin=script)

        rc, out, err = render({})
        check("the prompt renders through bash with set -u (rc 0, no stderr)", rc == 0 and not err.strip(),
              "rc=%d err=%r" % (rc, err.strip()[:200]))
        check("the rendered prompt starts with SLACK CHAT: and ends with rule 3 (no quote broke the string)",
              out.startswith("SLACK CHAT: you are the do-agent-aws") and "\n3. Answer questions about status" in out
              and out.rstrip().endswith("STOP."), "tail=%r" % out[-80:])
        r2 = [l for l in out.splitlines() if l.startswith("2. ")]
        r2 = r2[0] if r2 else ""
        check("rendered rule 2: the plain add with the fixture path, channel and thread ts",
              "/agent/goals-add.sh '<one-line goal>' 'C0FIXTURE 1793000000.000100'" in r2)
        check("rendered rule 2: --priority high before the goal text, same path and thread ts",
              "/agent/goals-add.sh --priority high '<one-line goal>' 'C0FIXTURE 1793000000.000100'" in r2)
        check("rendered rule 2: --set-priority G<n> high|low|normal through the same path",
              "/agent/goals-add.sh --set-priority G<n> high|low|normal" in r2)
        check("rendered rule 2 has no unexpanded ${...} and no empty '' argument",
              "${" not in r2 and "''" not in r2 and "'C0FIXTURE '" not in r2)
        check("rendered rule 2 keeps the literal G<n>, L<n> and high|low|normal for the model",
              "G<n>" in r2 and "L<n>" in r2 and "high|low|normal" in r2)
        rc, out, err = render({"M_THREAD": "", "M_REPLY_THREAD": "1793000000.000123",
                               "THREAD_NOTE": "in a thread under it (thread_ts 1793000000.000123)",
                               "THREAD_ARG": " '1793000000.000123'"})
        r2b = [l for l in out.splitlines() if l.startswith("2. ")]
        r2b = r2b[0] if r2b else ""
        check("a top-level message (no thread_ts): both add calls fall back to the message's own ts",
              rc == 0 and r2b.count("'C0FIXTURE 1793000000.000123'") == 2 and "1793000000.000100" not in r2b,
              "rc=%d count=%d" % (rc, r2b.count("'C0FIXTURE 1793000000.000123'")))

    # ---- (c) the interface the rule promises: goals-add.sh --help, then --set-priority on a fixture, spelled as rule 2 spells it
    rc, out, err = run(["bash", add_sh, "--help"])
    helptext = out + err
    check("goals-add.sh --help exits 0 and names --priority high|low and --set-priority G<n>|L<line> high|low|normal",
          rc == 0 and "--priority high|low" in helptext and "--set-priority G<n>|L<line> high|low|normal" in helptext,
          "rc=%d" % rc)
    with tempfile.TemporaryDirectory(prefix="supervisor-chat-rule-test-") as d:
        gpath = os.path.join(d, "goals", "GOALS.md")
        os.mkdir(os.path.dirname(gpath))
        ldir = os.path.join(d, "loop")
        os.mkdir(ldir)
        fixture = ["# Goals", "", "## Goals from Slack",
                   "- [x] Goal one (from Slack C0FIXTURE 1793000000.000001)",
                   "- [ ] Goal two (from Slack C0FIXTURE 1793000000.000002)",
                   "- [ ] Goal three (from Slack C0FIXTURE 1793000000.000003)", ""]
        with open(gpath, "w", encoding="utf-8") as f:
            f.write("\n".join(fixture))
        env = {"AUTONOMY_LOOP_GOALS": gpath, "AUTONOMY_LOOP_DIR": ldir}

        def goals():
            with open(gpath, encoding="utf-8") as f:
                return f.read().splitlines()

        rc, out, err = run(["bash", add_sh, "--set-priority", "G3", "high"], env)
        g = goals()
        check("--set-priority G3 high (G<n> = the 3rd checkbox goal, the done one counted): rc 0, only line 6 changed, WAKE touched",
              rc == 0 and g[5] == "- [ ] (priority: high) Goal three (from Slack C0FIXTURE 1793000000.000003)"
              and g[:5] == fixture[:5] and len(g) == len(fixture) - 1 and os.path.exists(os.path.join(ldir, "WAKE")),
              "rc=%d line6=%r err=%r" % (rc, g[5] if len(g) > 5 else None, err.strip()[:160]))
        rc, out, err = run(["bash", add_sh, "--set-priority", "L5", "low"], env)
        g = goals()
        check("--set-priority L5 low (L<line> = the file line): rc 0, line 5 gets (priority: low), line 6 keeps high",
              rc == 0 and g[4] == "- [ ] (priority: low) Goal two (from Slack C0FIXTURE 1793000000.000002)"
              and g[5].startswith("- [ ] (priority: high) Goal three"), "rc=%d line5=%r" % (rc, g[4] if len(g) > 4 else None))
        rc, out, err = run(["bash", add_sh, "--set-priority", "G3", "normal"], env)
        g = goals()
        check("--set-priority G3 normal removes the marker (the line is the fixture's again)",
              rc == 0 and g[5] == fixture[5], "rc=%d line6=%r" % (rc, g[5] if len(g) > 5 else None))
        before = goals()
        rc, out, err = run(["bash", add_sh, "--set-priority", "G9", "high"], env)
        check("--set-priority G9 high on a 3-goal file exits 4 (no such goal) and writes nothing",
              rc == 4 and goals() == before, "rc=%d out=%r err=%r" % (rc, out.strip()[:120], err.strip()[:120]))

    passed = sum(1 for _n, ok in results if ok)
    print("VERDICT %s %d/%d checks" % ("PASS" if passed == len(results) else "FAIL", passed, len(results)))
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
