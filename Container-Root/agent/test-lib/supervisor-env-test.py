#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""supervisor-env-test.py - offline test of G99 part 2 step 2b(e): the supervisor mode's settings in .env.

The loop reads eight settings with a default (loop.sh: AUTONOMY_LOOP_MODE, AUTONOMY_LOOP_DRY_RUN, SUPERVISOR_MAX_WORKERS,
SUPERVISOR_MODEL_PASS, SUPERVISOR_MODEL_TIMEOUT, SUPERVISOR_STRIKES_MAX, SUPERVISOR_PARK_CYCLES, SUPERVISOR_WORKER_OPTS;
SUPERVISOR_PLAN_BIN is a container-internal path like BUS_BIN and stays out of .env). This test proves, without
sourcing .env (that would run $(whoami), mkdir and read .env.local):

  (a) the source: `bash -n .env`; exactly one `export NAME=value` line per setting, its value equal to the default
      loop.sh's `${NAME:-default}` line carries; a `### NAME` comment above each; the block sits inside the autonomy loop
      section; the names loop.sh reads with a default in its supervisor block are exactly these eight plus the planner path;
      the docker pass-through AUTONOMY_ENV_OPTS carries each one (shq-quoted values, SUPERVISOR_WORKER_OPTS bare like
      AUTONOMY_LOOP_CLAUDE_OPTS); the spoke supervisor's seven SUPERVISOR_* settings and SPOKE_ENV_OPTS are untouched and
      share no name with the new ones;
  (b) the render: the shq() function, the autonomy exports and the AUTONOMY_ENV_OPTS line are cut out of .env and run
      through `bash -s` under `set -u` - the option string holds `-e NAME=default` for the seven valued settings and a
      bare `-e SUPERVISOR_WORKER_OPTS`, the ten entries that were there before are still there (18 `-e` words); a second
      render with .env.local-style overrides placed before the option line (mode supervisor, 2 workers, worker options
      with a space, a goals path with a space) follows them, shq quotes the space so the word survives `eval`, and the
      worker options travel exported in the environment, which is what a bare -e copies;
  (c) the other targets: the compose template lists `- NAME=${NAME}` and the kubernetes template `- name: NAME` /
      `value: "${NAME}"` for each setting, in the same environment list as AUTONOMY_LOOP, and both files still parse as YAML;
  (d) the operator's file and git: .env.local is byte-identical to the baseline recorded before the staging
      (/wd/loop/supervisor/env-local-baseline.txt: mtime_ns, size, sha256 - its content is never printed); the git diff of
      .env removes only the two AUTONOMY_ENV_OPTS lines it replaced, the two templates only gain lines.

    python3 -I test-lib/supervisor-env-test.py [--repo /do-agent-aws] [--baseline /wd/loop/supervisor/env-local-baseline.txt]

Prints one PASS/FAIL line per check and `VERDICT PASS|FAIL n/m checks`; exit 0 only on PASS.
"""
import argparse
import hashlib
import os
import re
import shlex
import subprocess
import sys

NAMES = ["AUTONOMY_LOOP_MODE", "AUTONOMY_LOOP_DRY_RUN", "SUPERVISOR_MAX_WORKERS", "SUPERVISOR_MODEL_PASS",
         "SUPERVISOR_MODEL_TIMEOUT", "SUPERVISOR_STRIKES_MAX", "SUPERVISOR_PARK_CYCLES", "SUPERVISOR_WORKER_OPTS"]
BARE = {"SUPERVISOR_WORKER_OPTS"}          # passed as a bare -e NAME (the value travels in the environment)
PLANNER_PATH = "SUPERVISOR_PLAN_BIN"       # read with a default too, container-internal, not a .env setting
SPOKE = ["SUPERVISOR", "SUPERVISOR_INTERVAL", "SUPERVISOR_RESTART_CAP", "SUPERVISOR_HEALTHY_SECS",
         "SUPERVISOR_START_GRACE", "SUPERVISOR_MEMORY_QUEUE_WARN", "SUPERVISOR_CLOSE_EXITED"]
OLD_ENTRIES = ["-e AUTONOMY_LOOP=auto", "-e AUTONOMY_LOOP_INTERVAL=300", "-e AUTONOMY_LOOP_GOALS=/wd/goals/GOALS.md",
               "-e AUTONOMY_LOOP_FIRE_TIMEOUT=1500", "-e AUTONOMY_LOOP_CLAUDE_OPTS -e AUTONOMY_LOOP_OPTS_CHECK "
               "-e LOOP_INBOX -e LOOP_INBOX_MAX -e GOAL_WATCH -e GOAL_WATCH_INTERVAL"]
OLD_NAMES = ["AUTONOMY_LOOP", "AUTONOMY_LOOP_INTERVAL", "AUTONOMY_LOOP_GOALS", "AUTONOMY_LOOP_FIRE_TIMEOUT",
             "AUTONOMY_LOOP_CLAUDE_OPTS", "AUTONOMY_LOOP_OPTS_CHECK", "LOOP_INBOX", "LOOP_INBOX_MAX", "GOAL_WATCH",
             "GOAL_WATCH_INTERVAL"]
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok)))
    print("%s %s%s" % ("PASS" if ok else "FAIL", name, (" - " + detail) if detail else ""))
    return ok


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def loop_defaults(loop_text):
    """NAME -> default for every `NAME=${NAME:-default}` line of loop.sh's supervisor block."""
    out = {}
    for line in loop_text.splitlines():
        m = re.match(r'^(AUTONOMY_LOOP_MODE|AUTONOMY_LOOP_DRY_RUN|SUPERVISOR_[A-Z_]+)=\$\{\1:-(.*)\}$', line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def env_exports(env_text, name):
    return [l for l in env_text.splitlines() if l.startswith("export %s=" % name)]


def cut_shq(env_text):
    lines = env_text.splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith("shq()"))
    end = next(i for i in range(start, len(lines)) if lines[i] == "}")
    return lines[start:end + 1]


def render(env_text, overrides):
    """Run shq() + the autonomy exports (+ overrides before the option line) + the AUTONOMY_ENV_OPTS line through bash."""
    script = ["set -u"] + cut_shq(env_text)
    pat = re.compile(r'^export (AUTONOMY_LOOP[A-Z_]*|SUPERVISOR_(MAX_WORKERS|MODEL_PASS|MODEL_TIMEOUT|STRIKES_MAX|PARK_CYCLES|WORKER_OPTS))=')
    opts_line = None
    for l in env_text.splitlines():
        if l.startswith("export AUTONOMY_ENV_OPTS="):
            opts_line = l
        elif pat.match(l):
            script.append(l)
    script += overrides + [opts_line, 'printf \'%s\\n\' "${AUTONOMY_ENV_OPTS}"',
                           'printf \'%s\\n\' "${SUPERVISOR_WORKER_OPTS}"',
                           "env | grep -c '^SUPERVISOR_WORKER_OPTS=' || true"]
    r = subprocess.run(["bash", "-s"], input="\n".join(script) + "\n", capture_output=True, text=True)
    return r.returncode, r.stdout.splitlines(), r.stderr


def names_of(opts):
    """The NAME of every `-e NAME[=value]` word of a rendered option string, in order."""
    words = shlex.split(opts)
    out = []
    for i, w in enumerate(words):
        if w == "-e" and i + 1 < len(words):
            out.append(words[i + 1].split("=", 1)[0])
    return out


def git(repo, *args):
    r = subprocess.run(["git", "-c", "safe.directory=" + repo, "-C", repo, *args], capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="/do-agent-aws")
    ap.add_argument("--baseline", default="/wd/loop/supervisor/env-local-baseline.txt")
    a = ap.parse_args()
    env_p = os.path.join(a.repo, ".env")
    loop_p = os.path.join(a.repo, "Container-Root/agent/loop.sh")
    compose_p = os.path.join(a.repo, "to/compose/template/docker-compose.yaml")
    k8s_p = os.path.join(a.repo, "to/kubernetes/template/020-deployment.yaml")
    env = read(env_p)
    loop = read(loop_p)
    env_lines = env.splitlines()
    print("supervisor-env-test repo=%s .env=%d lines loop.sh=%d lines" % (a.repo, len(env_lines), len(loop.splitlines())))

    # ---- (a) the source
    r = subprocess.run(["bash", "-n", env_p], capture_output=True, text=True)
    check("a1 bash -n .env rc 0", r.returncode == 0, r.stderr.strip()[:200])
    defaults = loop_defaults(loop)
    read_set = set(defaults) - {PLANNER_PATH}
    check("a2 loop.sh's supervisor-block defaults are exactly the eight names (+ %s)" % PLANNER_PATH,
          read_set == set(NAMES) and PLANNER_PATH in defaults,
          "loop.sh reads %s; .env declares %s" % (sorted(defaults), sorted(NAMES)))
    one_each = {n: len(env_exports(env, n)) for n in NAMES}
    check("a3 exactly one export line per setting in .env", all(c == 1 for c in one_each.values()), str(one_each))
    mism = {}
    for n in NAMES:
        ex = env_exports(env, n)
        val = ex[0].split("=", 1)[1] if ex else None
        if val != defaults.get(n):
            mism[n] = (val, defaults.get(n))
    check("a4 each .env value equals loop.sh's default", not mism,
          "all equal: %s" % ", ".join("%s=%s" % (n, defaults.get(n) or "(empty)") for n in NAMES) if not mism else "mismatch %s" % mism)
    no_comment = [n for n in NAMES if not any(l.startswith("### %s " % n) for l in env_lines)]
    check("a5 a '### NAME' comment line documents each setting", not no_comment, "missing: %s" % no_comment if no_comment else "8/8")
    idx = {l.split("=", 1)[0].replace("export ", ""): i for i, l in enumerate(env_lines) if l.startswith("export ")}
    gw = next((i for i, l in enumerate(env_lines) if l.startswith("### GOAL_WATCH_INTERVAL")), -1)
    inside = gw >= 0 and all(gw < idx.get(n, -1) < idx.get("AUTONOMY_ENV_OPTS", -1) for n in NAMES)
    check("a6 the block sits after GOAL_WATCH_INTERVAL and before AUTONOMY_ENV_OPTS", inside,
          "lines %d .. %d, AUTONOMY_ENV_OPTS at %d" % (min(idx.get(n, 0) for n in NAMES) + 1, max(idx.get(n, 0) for n in NAMES) + 1, idx.get("AUTONOMY_ENV_OPTS", -1) + 1))
    opts_src = env_exports(env, "AUTONOMY_ENV_OPTS")
    opts_src = opts_src[0] if opts_src else ""
    missing_e = [n for n in NAMES if n not in BARE and ('-e %s=$(shq "${%s}")' % (n, n)) not in opts_src]
    check("a7 AUTONOMY_ENV_OPTS passes each valued setting shq-quoted", not missing_e, "missing: %s" % missing_e if missing_e else "7/7")
    check("a8 AUTONOMY_ENV_OPTS passes SUPERVISOR_WORKER_OPTS bare (no '=')",
          " -e SUPERVISOR_WORKER_OPTS" in opts_src and "-e SUPERVISOR_WORKER_OPTS=" not in opts_src)
    old_ok = all(("-e %s" % n) in opts_src for n in OLD_NAMES)
    check("a9 the ten earlier entries of AUTONOMY_ENV_OPTS are still passed", old_ok)
    spoke_src = env_exports(env, "SPOKE_ENV_OPTS")
    spoke_src = spoke_src[0] if spoke_src else ""
    spoke_counts = {n: len(env_exports(env, n)) for n in SPOKE}
    check("a10 the spoke supervisor's seven settings and SPOKE_ENV_OPTS are untouched, no shared name",
          all(c == 1 for c in spoke_counts.values()) and all(("-e %s" % n) in spoke_src for n in SPOKE)
          and not any(("-e %s" % n) in spoke_src for n in NAMES) and not (set(SPOKE) & set(NAMES)),
          "spoke exports %s" % spoke_counts)

    # ---- (b) the render
    rc, out, err = render(env, [])
    check("b1 render rc 0, no stderr", rc == 0 and not err.strip(), (err.strip() or "")[:200])
    opts = out[0] if out else ""
    print("  rendered: %s" % opts)
    want = ["-e %s=%s" % (n, defaults[n]) for n in NAMES if n not in BARE]
    miss = [w for w in want if w not in opts]
    check("b2 the rendered string holds -e NAME=default for the seven valued settings", not miss, "missing: %s" % miss if miss else "7/7")
    check("b3 the rendered string ends with a bare -e SUPERVISOR_WORKER_OPTS", opts.endswith(" -e SUPERVISOR_WORKER_OPTS"))
    old_miss = [o for o in OLD_ENTRIES if o not in opts]
    check("b4 the earlier entries are rendered as before", not old_miss, "missing: %s" % old_miss if old_miss else "5 fragments")
    got = names_of(opts)
    check("b5 18 -e words, every name expected, each once", len(got) == 18 and sorted(got) == sorted(OLD_NAMES + NAMES), "%d words" % len(got))
    check("b6 the default render carries an empty SUPERVISOR_WORKER_OPTS in the environment", len(out) >= 3 and out[1] == "" and out[2].strip() == "1",
          "value=%r env-count=%s" % (out[1] if len(out) > 1 else None, out[2].strip() if len(out) > 2 else None))
    rc2, out2, err2 = render(env, ["AUTONOMY_LOOP_MODE=supervisor", "SUPERVISOR_MAX_WORKERS=2",
                                   "SUPERVISOR_WORKER_OPTS='--max-turns 60'", "AUTONOMY_LOOP_GOALS='/wd/my goals/GOALS.md'"])
    check("b7 override render rc 0, no stderr", rc2 == 0 and not err2.strip(), (err2.strip() or "")[:200])
    opts2 = out2[0] if out2 else ""
    print("  rendered (overrides): %s" % opts2)
    check("b8 overrides placed before the option line are followed", "-e AUTONOMY_LOOP_MODE=supervisor" in opts2 and "-e SUPERVISOR_MAX_WORKERS=2" in opts2)
    words2 = shlex.split(opts2) if opts2 else []
    check("b9 a value with a space is shq-quoted and splits back to one word", "/wd/my\\ goals/GOALS.md" in opts2
          and "AUTONOMY_LOOP_GOALS=/wd/my goals/GOALS.md" in words2)
    check("b10 the worker options travel exported in the environment (bare -e copies them), the string stays bare",
          len(out2) >= 3 and out2[1] == "--max-turns 60" and out2[2].strip() == "1" and opts2.endswith(" -e SUPERVISOR_WORKER_OPTS")
          and "-e SUPERVISOR_WORKER_OPTS=" not in opts2)

    # ---- (c) the other targets
    compose = read(compose_p)
    k8s = read(k8s_p)
    c_lines = [l.strip() for l in compose.splitlines()]
    c_miss = [n for n in NAMES if c_lines.count("- %s=${%s}" % (n, n)) != 1]
    check("c1 compose template lists - NAME=${NAME} once per setting", not c_miss, "missing/dup: %s" % c_miss if c_miss else "8/8")
    k_miss = [n for n in NAMES if len(re.findall(r'^\s*- name: %s\n\s*value: "\$\{%s\}"$' % (n, n), k8s, re.M)) != 1]
    check("c2 kubernetes template lists - name: NAME / value: \"${NAME}\" once per setting", not k_miss, "missing/dup: %s" % k_miss if k_miss else "8/8")
    try:
        import yaml  # PyYAML 5.4 on this image; the placeholders are plain scalars
        cdoc = yaml.safe_load(compose)
        envlists = [v for s in (cdoc.get("services") or {}).values() if isinstance(s, dict) and isinstance(s.get("environment"), list)
                    for v in [s["environment"]] if "AUTONOMY_LOOP=${AUTONOMY_LOOP}" in v]
        check("c3 compose parses; the eight entries sit in the same environment list as AUTONOMY_LOOP",
              len(envlists) == 1 and all(("%s=${%s}" % (n, n)) in envlists[0] for n in NAMES), "%d matching service(s)" % len(envlists))
        kdocs = [d for d in yaml.safe_load_all(k8s) if d]
        klists = []
        for d in kdocs:
            try:
                for c in d["spec"]["template"]["spec"]["containers"]:
                    if any(e.get("name") == "AUTONOMY_LOOP" for e in c.get("env", [])):
                        klists.append(c["env"])
            except (KeyError, TypeError):
                pass
        check("c4 kubernetes parses; the eight entries sit in the same env list as AUTONOMY_LOOP",
              len(klists) == 1 and all({"name": n, "value": "${%s}" % n} in klists[0] for n in NAMES), "%d matching container(s)" % len(klists))
    except ImportError:
        check("c3 compose parses (PyYAML)", False, "PyYAML not importable")
        check("c4 kubernetes parses (PyYAML)", False, "PyYAML not importable")

    # ---- (d) the operator's file and git
    local_p = os.path.join(a.repo, ".env.local")
    base = read(a.baseline).strip() if os.path.exists(a.baseline) else ""
    bm = re.search(r'mtime_ns=(\d+) size=(\d+) sha256=([0-9a-f]{64})', base)
    if bm and os.path.exists(local_p):
        st = os.stat(local_p)
        with open(local_p, "rb") as f:
            h = hashlib.sha256(f.read()).hexdigest()
        same = (str(st.st_mtime_ns), str(st.st_size), h) == bm.groups()
        check("d1 .env.local is byte-identical to the baseline recorded before the staging", same,
              "%s; now mtime_ns=%d size=%d sha256=%s..." % (base.split(" file=")[0], st.st_mtime_ns, st.st_size, h[:12]))
    else:
        check("d1 .env.local baseline present and the file exists", False, "baseline=%r exists=%s" % (base[:80], os.path.exists(local_p)))
    rc, diff, err = git(a.repo, "diff", "--", ".env")
    removed = [l[1:] for l in diff.splitlines() if l.startswith("-") and not l.startswith("---")]
    only_opts = bool(removed) and all(l.startswith("### AUTONOMY_ENV_OPTS") or l.startswith("export AUTONOMY_ENV_OPTS=") for l in removed)
    check("d2 git diff .env removes only the two AUTONOMY_ENV_OPTS lines it replaced", rc == 0 and only_opts,
          "%d removed line(s): %s" % (len(removed), [l[:40] for l in removed]))
    rc, numstat, err = git(a.repo, "diff", "--numstat", "--", ".env", "to/compose/template/docker-compose.yaml", "to/kubernetes/template/020-deployment.yaml")
    rows = {}
    for l in numstat.splitlines():
        parts = l.split("\t")
        if len(parts) == 3:
            rows[parts[2]] = (parts[0], parts[1])
    check("d3 the two templates only gain lines (numstat deletions 0), all three files changed",
          rc == 0 and set(rows) == {".env", "to/compose/template/docker-compose.yaml", "to/kubernetes/template/020-deployment.yaml"}
          and rows.get("to/compose/template/docker-compose.yaml", ("", "x"))[1] == "0"
          and rows.get("to/kubernetes/template/020-deployment.yaml", ("", "x"))[1] == "0", str(rows))

    ok = sum(1 for _n, r in RESULTS if r)
    print("VERDICT %s %d/%d checks" % ("PASS" if ok == len(RESULTS) else "FAIL", ok, len(RESULTS)))
    return 0 if ok == len(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
