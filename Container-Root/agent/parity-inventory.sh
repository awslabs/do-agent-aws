#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The parity inventory: what this Claude Code instance runs with, as ONE markdown table that reads the same on a native
# host and inside the agent container, so two instances can be put side by side (docs/manual/autonomy.md "Parity with a
# native instance"). It only
# reads: the client, the settings files on Claude Code's load path, the instruction files, the memory and knowledge
# directories, the skills, agents, plugins and hooks, the autonomy loop's claude options, and the tools and credential
# files the instance can reach. Nothing is written, nothing is posted.
#
# Usage: /agent/parity-inventory.sh [--json] [-h|--help]      (in a checkout: tools/parity-inventory.sh, the same file)
#   no option   the table: one row per fact, `| row | value |`
#   --json      the same rows as one JSON object, the row names as keys, the values as the table prints them
#
# Rows: measured at, cwd, claude (the client's version), model (the id and where it is set: the environment, a
# settings.json env.ANTHROPIC_MODEL, a settings.json model key, or Claude Code's Bedrock default when nothing sets it),
# effort (CLAUDE_CODE_EFFORT_LEVEL), context 1M (the [1m] suffix of the id), fallbackModel, max output tokens
# (CLAUDE_CODE_MAX_OUTPUT_TOKENS), instructions (every CLAUDE.md on the load path with its size and the total: the user
# file under CLAUDE_CONFIG_DIR and its rules/*.md, CLAUDE.md and CLAUDE.local.md of the working directory and each parent,
# .claude/CLAUDE.md and .claude/rules/*.md of the working directory and of its repository's top level, the managed file,
# the files an @-line of any of them names - one level deep - and, in the container, the shipped /agent-rules/*.md files:
# one whose bytes a loaded file already carries is not counted again, one no loaded file carries is listed apart as
# shipped but not loaded), auto-memory (whether Claude Code's own memory -
# the MEMORY.md index and files it writes and loads itself, per working directory - is on: the autoMemoryEnabled setting,
# CLAUDE_CODE_DISABLE_AUTO_MEMORY, and the working directory's memory directory), memory (Claude Code's own memory files
# under <config dir>/projects/*/memory, their MEMORY.md bytes, and the working directory's project among them), knowledge (the
# LogLearner banks: every *.jsonl under LOGLEARNER_STATE, KNOWLEDGE_DIR, KNOWLEDGE_IMPORTED_DIR and PARITY_KNOWLEDGE_DIRS,
# the imported packs ledger beside the bank, and the Hindsight memory API's /health), skills (SKILL.md files under
# <config dir>/skills, ~/.claude/skills, the working directory's .claude/skills and the plugin cache), agents (*.md under
# <config dir>/agents, ~/.claude/agents and .claude/agents), plugins (the enabledPlugins of the settings files), hooks
# (event -> entries, summed over the settings files), autonomous fire (the claude options and timeout of the loop's
# fire: in the container the effective AUTONOMY_LOOP_CLAUDE_OPTS and AUTONOMY_LOOP_FIRE_TIMEOUT, the defaults read from
# /agent/loop.sh, and the Slack chat responder's SLACK_CHAT_CLAUDE_OPTS and SLACK_CHAT_TIMEOUT the same way from
# /agent/slack-chat.sh; on a host the flags of the claude -p lines of the file PARITY_LOOP_SCRIPT names), kubectl (version and
# the number of contexts), gh (the account gh auth status names), docker, aws (version, and whether sts
# get-caller-identity answers), python3, node, credentials (whether ~/.kube/config, ~/.config/gh/hosts.yml and
# ~/.aws/{config,credentials} exist). A fact that is not there reads "none" or "not found"; a probe that fails reads so.
# The gh row says whether gh is logged in and to which host, never the account's login.
#
# Settings (environment): CLAUDE_CONFIG_DIR (default ~/.claude); PARITY_AGENT_DIR (where the container's scripts are, default
# /agent: a loop.sh there is what makes this the container; a test points it elsewhere) and PARITY_RULES_DIR (the shipped
# rules, default /agent-rules); PARITY_LOOP_SCRIPT (a native host's loop script, the
# file whose claude -p lines carry the fire's flags; default <PARITY_AGENT_DIR>/loop.sh when that file exists); PARITY_KNOWLEDGE_DIRS
# (more directories of *.jsonl banks to count, colon-separated); the loaders' own LOGLEARNER_STATE, LOGLEARNER_BANKS_DIR,
# KNOWLEDGE_DIR, KNOWLEDGE_IMPORTED_DIR; HINDSIGHT_API_URL, else HINDSIGHT_API, else http://127.0.0.1:${UI_PORT_HINDSIGHT_API
# or 8888}; AUTONOMY_LOOP_CLAUDE_OPTS, AUTONOMY_LOOP_FIRE_TIMEOUT, SLACK_CHAT_CLAUDE_OPTS and SLACK_CHAT_TIMEOUT. Probes of
# tools time out after 5 s, the memory API after 3 s.
#
# Printed values are versions, counts, sizes, model ids, option words and paths (the home directory written as ~). Of
# the settings' env block only ANTHROPIC_MODEL, CLAUDE_CODE_EFFORT_LEVEL, CLAUDE_CODE_MAX_OUTPUT_TOKENS,
# CLAUDE_CODE_DISABLE_AUTO_MEMORY and HINDSIGHT_API_URL are read; no other environment value, no account id, no login, no
# context name and no credential is printed.
#
# Exit codes: 0 after an inventory, whatever it found; 2 an unknown option.

exec python3 -I - "$@" << 'PY'
import datetime
import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import urllib.request

ARGS = sys.argv[1:]
if ARGS not in ([], ["--json"]):
    if ARGS in (["-h"], ["--help"]):
        print("usage: parity-inventory.sh [--json]   one markdown table (or JSON object) of what this Claude Code instance runs with")
        sys.exit(0)
    print("parity-inventory.sh: unknown option %s (only --json)" % " ".join(ARGS), file=sys.stderr)
    sys.exit(2)
AS_JSON = ARGS == ["--json"]

ENV = dict(os.environ)
HOME = ENV.get("HOME") or os.path.expanduser("~")
CLAUDE_DIR = ENV.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
HOME_CLAUDE = os.path.join(HOME, ".claude")
CWD = os.getcwd()
AGENT_DIR = ENV.get("PARITY_AGENT_DIR") or "/agent"   # the container's scripts; a test points it elsewhere
IN_CONTAINER = os.path.isfile(os.path.join(AGENT_DIR, "loop.sh"))
RULES_DIR = ENV.get("PARITY_RULES_DIR") or "/agent-rules"
TOOL_TIMEOUT = 5
ROWS = []


def tilde(path):
    """A path with the home directory written as ~ (no account or host name in the output)."""
    if path == HOME or path.startswith(HOME + "/"):
        return "~" + path[len(HOME):]
    return path


def row(name, value):
    ROWS.append((name, value if value not in (None, "") else "none"))


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def run(args, timeout=TOOL_TIMEOUT, env=None, stderr_too=True):
    """(rc, output) of a command - stdout, with stderr appended unless stderr_too is False (a caller that parses wants
    stdout alone) - or (None, reason) when it is not installed, times out or cannot start."""
    if shutil.which(args[0]) is None:
        return None, "not found"
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, "no answer in %d s" % timeout
    except OSError as e:
        return None, "cannot run (%s)" % e.strerror
    return p.returncode, (p.stdout or "") + ((p.stderr or "") if stderr_too else "")


def size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def dedupe(paths):
    seen, out = set(), []
    for p in paths:
        r = os.path.realpath(p)
        if r not in seen:
            seen.add(r)
            out.append(p)
    return out


# --- the settings files on the load path, highest precedence first (managed, the project's local and shared files, the
# user's); only their model, effort, output-token and memory-API entries are ever read
def settings_files():
    files = ["/etc/claude-code/managed-settings.json"]
    roots = [CWD]
    rc, out = run(["git", "-C", CWD, "rev-parse", "--show-toplevel"])
    if rc == 0 and out.strip() and os.path.realpath(out.strip()) != os.path.realpath(CWD):
        roots.append(out.strip())
    for r in roots:
        files += [os.path.join(r, ".claude", "settings.local.json"), os.path.join(r, ".claude", "settings.json")]
    files.append(os.path.join(CLAUDE_DIR, "settings.json"))
    return [(p, load_json(p)) for p in dedupe(files) if os.path.isfile(p)]


SETTINGS = [(p, s) for p, s in settings_files() if isinstance(s, dict)]


def settings_env(key):
    """(value, file) of the first settings file whose env block sets key, else (None, None)."""
    for p, s in SETTINGS:
        e = s.get("env")
        if isinstance(e, dict) and isinstance(e.get(key), str) and e[key]:
            return e[key], p
    return None, None


def settings_key(key):
    for p, s in SETTINGS:
        if s.get(key) not in (None, "", [], {}):
            return s[key], p
    return None, None


def env_or_settings(key, label):
    """The effective value of an environment setting and where it comes from: the process environment first (a setting
    Claude Code read from a settings file is in the environment of every process it starts), then the settings files."""
    sv, sf = settings_env(key)
    if ENV.get(key):
        src = "env " + key
        if sv == ENV[key]:
            src += ", same in %s env" % tilde(sf)
        return ENV[key], src
    if sv:
        return sv, "%s env.%s" % (tilde(sf), key)
    return None, label


# --- measured at, cwd, the client ---
row("measured at", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
row("cwd", tilde(CWD))
rc, out = run(["claude", "--version"])
if rc is None:
    row("claude", out)
else:
    m = re.search(r"\d+\.\d+\.\d+\S*", out)
    row("claude", m.group(0) if m else (out.strip().splitlines() or ["unreadable version"])[0])

# --- model, effort, context, fallback, output tokens ---
model, model_src = env_or_settings("ANTHROPIC_MODEL", "")
if not model:
    mk, mf = settings_key("model")
    if isinstance(mk, str):
        model, model_src = mk, "%s model" % tilde(mf)
if model:
    value = "%s (%s)" % (model, model_src)
    mk, mf = settings_key("model")
    if isinstance(mk, str) and mk != model:
        value += "; %s model key also set: %s (lower precedence)" % (tilde(mf), mk)
    row("model", value)
    row("context 1M", "yes" if "[1m]" in model.lower() else "no")
else:
    row("model", "Bedrock default (unset)")
    row("context 1M", "no (nothing sets a model, so no [1m] suffix)")
effort, src = env_or_settings("CLAUDE_CODE_EFFORT_LEVEL", "none (Claude Code's default)")
row("effort", "%s (%s)" % (effort, src) if effort else src)
fb, ff = settings_key("fallbackModel")
if fb is not None:
    row("fallbackModel", "%s (%s)" % (", ".join(fb) if isinstance(fb, list) else str(fb), tilde(ff)))
else:
    row("fallbackModel", "none")
tok, src = env_or_settings("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "none (Claude Code's default)")
row("max output tokens", "%s (%s)" % (tok, src) if tok else src)

# --- instructions: every CLAUDE.md on the load path, @-references one level deep ---
def at_references(path):
    """The existing files the @-imports of an instruction file name: an @path at the start of a line or after a space
    or parenthesis, ~ the home, a relative path relative to the file's directory; a token that is no file is skipped."""
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                for m in re.finditer(r"(?:^|[\s(])@([^\s)]+)", line):
                    ref = os.path.expanduser(m.group(1).rstrip(",.;:"))
                    if not os.path.isabs(ref):
                        ref = os.path.join(os.path.dirname(path), ref)
                    if os.path.isfile(ref):
                        out.append(ref)
    except OSError:
        pass
    return out


# the user's file and rules (under CLAUDE_CONFIG_DIR: Claude Code reads that directory, not ~/.claude as well), the managed
# file, CLAUDE.md and CLAUDE.local.md of the working directory and each parent, and .claude/CLAUDE.md with .claude/rules/*.md
# of the working directory and of its repository's top level
candidates = ["/etc/claude-code/CLAUDE.md", os.path.join(CLAUDE_DIR, "CLAUDE.md")] + sorted(glob.glob(os.path.join(CLAUDE_DIR, "rules", "*.md")))
project_roots = [CWD]
rc, out = run(["git", "-C", CWD, "rev-parse", "--show-toplevel"])
if rc == 0 and out.strip() and os.path.realpath(out.strip()) != os.path.realpath(CWD):
    project_roots.append(out.strip())
d = CWD
while True:
    candidates += [os.path.join(d, "CLAUDE.md"), os.path.join(d, "CLAUDE.local.md")]
    if any(os.path.realpath(d) == os.path.realpath(r) for r in project_roots):
        candidates += [os.path.join(d, ".claude", "CLAUDE.md")] + sorted(glob.glob(os.path.join(d, ".claude", "rules", "*.md")))
    parent = os.path.dirname(d)
    if parent == d:
        break
    d = parent
files = dedupe([p for p in candidates if os.path.isfile(p)])
refs = []
for p in files:
    refs += at_references(p)
files = dedupe(files + [r for r in refs if r not in files])
shipped_only = []
if IN_CONTAINER:
    # the shipped rules files (/agent-rules): a session loads them through the configuration's copies (CLAUDE.md's
    # @AGENT_RULES.md and the like), which the @-imports above already list, so a shipped file whose bytes are listed is not
    # counted again; one that no loaded file carries is listed apart, as shipped but not loaded
    def sha256(path):
        try:
            with open(path, "rb") as f:
                return hashlib.sha256(f.read()).hexdigest()
        except OSError:
            return None
    listed = set(sha256(p) for p in files)
    shipped_only = [p for p in sorted(glob.glob(os.path.join(RULES_DIR, "*.md"))) if os.path.isfile(p) and sha256(p) not in listed]
if files or shipped_only:
    total = sum(size(p) for p in files)
    value = "%d file(s), %d bytes: " % (len(files), total) + "; ".join("%s %d" % (tilde(p), size(p)) for p in files) if files else "none loaded"
    if shipped_only:
        value += "; shipped but not loaded by any of them: " + "; ".join("%s %d" % (tilde(p), size(p)) for p in shipped_only)
    row("instructions", value)
else:
    row("instructions", "none (no CLAUDE.md on the load path from %s)" % tilde(CWD))

# --- auto-memory: whether Claude Code writes and loads its own memory (on unless a setting or the environment turns it off) ---
am_env = ENV.get("CLAUDE_CODE_DISABLE_AUTO_MEMORY")
am_setting, am_file = settings_key("autoMemoryEnabled")
am_env_setting, am_env_file = settings_env("CLAUDE_CODE_DISABLE_AUTO_MEMORY")
mem_slug = re.sub(r"[^A-Za-z0-9]", "-", CWD)
mem_here = os.path.join(CLAUDE_DIR, "projects", mem_slug, "memory")
if am_env not in (None, "", "0", "false"):
    row("auto-memory", "off (env CLAUDE_CODE_DISABLE_AUTO_MEMORY=%s)" % am_env)
elif am_env_setting not in (None, "", "0", "false"):
    row("auto-memory", "off (%s env.CLAUDE_CODE_DISABLE_AUTO_MEMORY=%s)" % (tilde(am_env_file), am_env_setting))
elif am_setting is False:
    row("auto-memory", "off (%s autoMemoryEnabled false)" % tilde(am_file))
else:
    src = ("%s autoMemoryEnabled true" % tilde(am_file)) if am_setting is True else "Claude Code's default, nothing sets it"
    row("auto-memory", "on (%s); this cwd's memory directory %s %s" % (src, tilde(mem_here), "exists" if os.path.isdir(mem_here) else "not created yet"))

# --- memory: Claude Code's own memory files ---
mem_dirs = [m for m in sorted(glob.glob(os.path.join(CLAUDE_DIR, "projects", "*", "memory"))) if os.path.isdir(m)]
if mem_dirs:
    n_files = n_bytes = idx_bytes = idx_files = 0
    for m in mem_dirs:
        for root, dirs, names in os.walk(m):
            for name in names:
                n_files += 1
                n_bytes += size(os.path.join(root, name))
        idx = os.path.join(m, "MEMORY.md")
        if os.path.isfile(idx):
            idx_files += 1
            idx_bytes += size(idx)
    value = "%d project(s): %d file(s), %d bytes; MEMORY.md %d bytes in %d file(s)" % (len(mem_dirs), n_files, n_bytes, idx_bytes, idx_files)
    slug = re.sub(r"[^A-Za-z0-9]", "-", CWD)
    this = [m for m in mem_dirs if os.path.basename(os.path.dirname(m)) == slug]
    if this:
        t = this[0]
        tf = sum(len(names) for _, _, names in os.walk(t))
        tb = sum(size(os.path.join(root, name)) for root, _, names in os.walk(t) for name in names)
        value += "; this cwd's project: %d file(s), %d bytes, MEMORY.md %d bytes" % (tf, tb, size(os.path.join(t, "MEMORY.md")))
    else:
        value += "; this cwd's project: none"
    row("memory", value)
else:
    row("memory", "none (no %s)" % tilde(os.path.join(CLAUDE_DIR, "projects", "*", "memory")))

# --- knowledge: the LogLearner banks, the imported packs ledger, the memory API ---
def jsonl_records(top):
    """(files, non-blank lines) of every *.jsonl under top, links not followed."""
    n_files = n_lines = 0
    for root, dirs, names in os.walk(top):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            p = os.path.join(root, name)
            if os.path.islink(p):
                continue
            n_files += 1
            try:
                with open(p, "rb") as f:
                    n_lines += sum(1 for line in f if line.strip())
            except OSError:
                pass
    return n_files, n_lines


knowledge_dir = ENV.get("KNOWLEDGE_DIR") or "/wd/knowledge"
imported_dir = ENV.get("KNOWLEDGE_IMPORTED_DIR") or os.path.join(knowledge_dir, "imported")
loglearner_state = ENV.get("LOGLEARNER_STATE") or "/wd/loglearner"
banks_dir = ENV.get("LOGLEARNER_BANKS_DIR") or os.path.join(loglearner_state, "banks")
tops = [loglearner_state, knowledge_dir, imported_dir] + [p for p in (ENV.get("PARITY_KNOWLEDGE_DIRS") or "").split(":") if p]
parts, total_records = [], 0
tops = dedupe([t for t in tops if os.path.isdir(t)])
tops = [t for t in tops if not any(o != t and os.path.realpath(t).startswith(os.path.realpath(o) + "/") for o in tops)]   # inside another: walked with it
for top in tops:
    nf, nl = jsonl_records(top)
    total_records += nl
    parts.append("%s %d record(s) in %d file(s)" % (tilde(top), nl, nf))
value = ("LogLearner banks: %d record(s) (%s)" % (total_records, "; ".join(parts))) if parts else "LogLearner banks: none (no %s, %s, %s)" % (tilde(loglearner_state), tilde(knowledge_dir), tilde(imported_dir))
ledger = load_json(os.path.join(banks_dir, "global", ".installed-packs.json"))
if isinstance(ledger, list) and ledger:
    value += "; imported packs: " + ", ".join("%s %s" % (e.get("name", "?"), e.get("version", "?")) for e in ledger if isinstance(e, dict))
else:
    value += "; imported packs: none"
api = ENV.get("HINDSIGHT_API_URL") or settings_env("HINDSIGHT_API_URL")[0] or ENV.get("HINDSIGHT_API") \
    or "http://127.0.0.1:%s" % (ENV.get("UI_PORT_HINDSIGHT_API") or "8888")
try:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(api.rstrip("/") + "/health", timeout=3) as r:
        body = r.read(4096).decode("utf-8", "replace")
    try:
        health = str(json.loads(body).get("status", body.strip()[:60]))
    except (ValueError, AttributeError):
        health = body.strip()[:60] or "answered"
except Exception as e:  # any failure to reach it is the fact reported
    health = "not reachable (%s)" % (getattr(e, "reason", None) or e.__class__.__name__)
value += "; Hindsight %s: %s" % (re.sub(r"//[^/@]*@", "//", api), health)
row("knowledge", value)

# --- skills, agents, plugins, hooks ---
def count(pattern):
    return len(dedupe(glob.glob(pattern, recursive=True)))


skill_dirs = [os.path.join(CLAUDE_DIR, "skills"), os.path.join(CWD, ".claude", "skills")]
skill_parts, skills_total = [], 0
for sd in dedupe(skill_dirs):
    if os.path.isdir(sd):
        n = count(os.path.join(sd, "**", "SKILL.md"))
        skills_total += n
        skill_parts.append("%d under %s" % (n, tilde(sd)))
# the plugins' skills: one installed version per enabled plugin (plugins/cache/<marketplace>/<plugin>/<version>/skills), the
# marketplace clones and older cached versions left out
enabled = []
for p, s in SETTINGS:
    ep = s.get("enabledPlugins")
    if isinstance(ep, dict):
        enabled += [k for k, v in ep.items() if v and k not in enabled]
n_plugin_skills, n_plugins_with = 0, 0
for key in enabled:
    name, _, mkt = key.partition("@")
    versions = sorted(glob.glob(os.path.join(CLAUDE_DIR, "plugins", "cache", mkt, name, "*", "skills")))
    if versions:
        n = count(os.path.join(versions[-1], "**", "SKILL.md"))
        if n:
            n_plugin_skills += n
            n_plugins_with += 1
if n_plugin_skills:
    skills_total += n_plugin_skills
    skill_parts.append("%d from %d enabled plugin(s) (one installed version each, %s)" % (n_plugin_skills, n_plugins_with, tilde(os.path.join(CLAUDE_DIR, "plugins", "cache"))))
row("skills", ("%d SKILL.md: " % skills_total + "; ".join(skill_parts)) if skill_parts else "none")
agent_parts, agents_total = [], 0
for ad in dedupe([os.path.join(CLAUDE_DIR, "agents"), os.path.join(CWD, ".claude", "agents")]):
    if os.path.isdir(ad):
        n = len(glob.glob(os.path.join(ad, "*.md")))
        agents_total += n
        agent_parts.append("%d under %s" % (n, tilde(ad)))
row("agents", ("%d agent(s): " % agents_total + "; ".join(agent_parts)) if agent_parts else "none")
row("plugins", ("%d: " % len(enabled) + ", ".join(enabled)) if enabled else "none")
hooks = {}
for p, s in SETTINGS:
    h = s.get("hooks")
    if isinstance(h, dict):
        for event, groups in h.items():
            if isinstance(groups, list):
                hooks[event] = hooks.get(event, 0) + sum(len(g.get("hooks") or []) if isinstance(g, dict) else 1 for g in groups)
row("hooks", ", ".join("%s %d" % (e, n) for e, n in sorted(hooks.items())) if hooks else "none")

# --- autonomous fire: the loop's claude options and timeout ---
def loop_default(path, name):
    """The default a loop script gives NAME in NAME=${NAME:-...}; None when the line is not there."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r'^\s*%s=\$\{%s:-"?(.*?)"?\}\s*$' % (name, name), line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def fire_flags(path):
    """The flags of the claude -p lines of a loop script - a line that runs claude, "${CLAUDE_BIN}" or another CLAUDE_*
    variable with -p: the timeout and the permission words, one entry per line. The line is split like the shell splits it
    (quotes kept together), so a rule with a space survives; a line the shell cannot split is read word by word."""
    found = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.lstrip().startswith("#") or not re.search(r'(?:\bclaude|\$\{?CLAUDE\w*\}?"?)\s+-p\b', line):
                    continue
                try:
                    toks = shlex.split(line, comments=False, posix=True)
                except ValueError:
                    toks = line.split()
                words = []
                for i, t in enumerate(toks):
                    if t == "timeout":
                        rest = [x for x in toks[i + 1:] if not x.startswith("-")]
                        if rest:
                            words.append("timeout " + rest[0])
                    elif t == "--dangerously-skip-permissions":
                        words.append(t)
                    elif t == "--permission-mode" and i + 1 < len(toks):
                        words.append("--permission-mode " + toks[i + 1])
                    elif t.startswith("--permission-mode="):
                        words.append("--permission-mode " + t.split("=", 1)[1])
                    elif t in ("--allowedTools", "--allowed-tools"):
                        rules = []
                        for x in toks[i + 1:]:
                            if x.startswith("-") or x.startswith("$") or x.startswith("<") or x in ("|", ">", "2>&1"):
                                break
                            rules.append(x)
                        words.append("--allowedTools " + " ".join(rules))
                    elif re.fullmatch(r"\$\{?\w*(CLAUDE_OPTS|OPTS_ARGV)\w*(\[@\])?\}?", t):
                        # the option variable, or the array a loop script builds from it (FIRE_OPTS_ARGV, CHAT_OPTS_ARGV)
                        words.append("$" + t.strip("${}").replace("[@]", ""))
                found.append(" ".join(words) if words else "(no permission flag on the line)")
    except OSError:
        return None
    return found


loop_script = ENV.get("PARITY_LOOP_SCRIPT") or (os.path.join(AGENT_DIR, "loop.sh") if IN_CONTAINER else "")
if loop_script and os.path.isfile(loop_script):
    if IN_CONTAINER and os.path.realpath(loop_script) == os.path.realpath(os.path.join(AGENT_DIR, "loop.sh")):
        d_opts = loop_default(loop_script, "AUTONOMY_LOOP_CLAUDE_OPTS")
        d_to = loop_default(loop_script, "AUTONOMY_LOOP_FIRE_TIMEOUT")
        opts = ENV.get("AUTONOMY_LOOP_CLAUDE_OPTS")
        to = ENV.get("AUTONOMY_LOOP_FIRE_TIMEOUT")
        value = "loop fire: claude -p %s (%s); timeout %s s (%s)" % (
            opts or d_opts or "?", "AUTONOMY_LOOP_CLAUDE_OPTS set" if opts else "the default of %s" % tilde(loop_script),
            to or d_to or "?", "AUTONOMY_LOOP_FIRE_TIMEOUT set" if to else "the default of %s" % tilde(loop_script))
        chat = os.path.join(os.path.dirname(os.path.realpath(loop_script)), "slack-chat.sh")
        if os.path.isfile(chat):
            c_opts, c_to = ENV.get("SLACK_CHAT_CLAUDE_OPTS"), ENV.get("SLACK_CHAT_TIMEOUT")
            value += "; chat responder: claude -p %s (%s); timeout %s s (%s)" % (
                c_opts or loop_default(chat, "SLACK_CHAT_CLAUDE_OPTS") or "?", "SLACK_CHAT_CLAUDE_OPTS set" if c_opts else "the default of %s" % tilde(chat),
                c_to or loop_default(chat, "SLACK_CHAT_TIMEOUT") or "?", "SLACK_CHAT_TIMEOUT set" if c_to else "the default of %s" % tilde(chat))
    else:
        flags = fire_flags(loop_script) or []
        distinct = []
        for fl in flags:
            if fl not in distinct:
                distinct.append(fl)
        value = ("%d claude -p line(s) in %s: " % (len(flags), tilde(loop_script)) + "; ".join(distinct)) if flags \
            else "no claude -p line in %s" % tilde(loop_script)
else:
    value = "not found (set PARITY_LOOP_SCRIPT=<the loop script whose claude -p lines carry the fire's flags>)" if not IN_CONTAINER \
        else "not found (%s)" % tilde(loop_script)
row("autonomous fire", value)

# --- tools ---
rc, out = run(["kubectl", "version", "--client", "-o", "json"], stderr_too=False)
if rc is None:
    row("kubectl", out)
else:
    try:
        ver = json.loads(out).get("clientVersion", {}).get("gitVersion", "?")
    except ValueError:
        ver = "?"
    rc2, out2 = run(["kubectl", "config", "get-contexts", "-o", "name"], stderr_too=False)
    n = len([l for l in out2.splitlines() if l.strip()]) if rc2 == 0 else 0
    row("kubectl", "%s, %d context(s)" % (ver, n))
rc, out = run(["gh", "auth", "status"], timeout=TOOL_TIMEOUT * 2)
if rc is None:
    row("gh", out)
else:
    m = re.search(r"Logged in to (\S+) account ", out)
    row("gh", "logged in to %s" % m.group(1) if m else "installed, not logged in")   # the account's login is not printed
rc, out = run(["docker", "--version"])
row("docker", out if rc is None else ((re.search(r"\d+\.\d+\.\d+", out) or re.match(r"\S*", out.strip())).group(0) or "unreadable version"))
rc, out = run(["aws", "--version"])
if rc is None:
    row("aws", out)
else:
    m = re.search(r"aws-cli/(\S+)", out)
    rc2, out2 = run(["aws", "sts", "get-caller-identity", "--output", "json"], timeout=TOOL_TIMEOUT)
    row("aws", "%s, sts get-caller-identity %s" % (m.group(1) if m else "?", "ok" if rc2 == 0 else ("no (%s)" % out2 if rc2 is None else "no")))
rc, out = run(["python3", "--version"])
row("python3", out if rc is None else ((re.search(r"\d+\.\d+\.\d+", out) or re.match(r"\S*", out.strip())).group(0) or "unreadable version"))
rc, out = run(["node", "--version"])
row("node", out if rc is None else ((out.strip().lstrip("v").splitlines() or ["unreadable version"])[0]))

# --- credential files present ---
creds = [("~/.kube/config", os.path.join(HOME, ".kube", "config")), ("~/.config/gh/hosts.yml", os.path.join(HOME, ".config", "gh", "hosts.yml")),
         ("~/.aws/config", os.path.join(HOME, ".aws", "config")), ("~/.aws/credentials", os.path.join(HOME, ".aws", "credentials"))]
row("credentials", ", ".join("%s %s" % (label, "present" if os.path.isfile(p) else "absent") for label, p in creds))

# --- output ---
if AS_JSON:
    print(json.dumps({k: v for k, v in ROWS}, indent=1))
else:
    print("| row | value |")
    print("|---|---|")
    for k, v in ROWS:
        print("| %s | %s |" % (k, v.replace("|", "\\|")))
PY
