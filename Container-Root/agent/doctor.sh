#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# credentials loaded from AWS Secrets Manager at the start, for a run through `docker exec` (/agent/secrets-env.sh)
if [ -r "${AGENT_DIR:-/agent}/secrets-env.sh" ]; then . "${AGENT_DIR:-/agent}/secrets-env.sh"; fi

# The harness doctor: what is set up in this container, what is not, and for each gap the step the agent takes inside
# the container, the exact lines the person runs on the host, and the command that verifies both (docs/manual/install.md "Setup
# doctor"). The harness-setup skill (/setup, or "help me finish setting up") runs it and walks the gaps in this order.
#
# Usage: /agent/doctor.sh [--brief | --json] [--check <id>[,<id>...]] [--model <model id>] [--cluster <name>]
#                         [--region <region>] [--repo <owner/name>] [--not-needed <id>] [--needed <id>] [-h|--help]
#
# Checks, in the order a person sets them up:
#   bedrock       a one-token Converse call with the model id Claude Code uses here (the us. prefix rule first; a [1m]
#                 suffix, Claude Code's request for the 1M-token context window, is read and left out of the Bedrock call)
#   git-identity  git var GIT_AUTHOR_IDENT, and whether GIT_USER_NAME / GIT_USER_EMAIL from the settings carry it
#   eks           the kubeconfig and kubectl auth can-i; with none, aws eks list-clusters across regions; Headlamp's list
#   slack         SLACK_BOT_TOKEN and SLACK_CHANNELS, then /agent/slack-doctor.sh (reads only, nothing is posted)
#   github        gh auth status, and gh repo view for --repo and for every loaded package's repository
#   memory        the memory API's health, the default seed's extraction state, and a known fact recalled
#   packages      every shared knowledge package: the repositories cloned under /wd/knowledge, checked against their
#                 record, and the packs imported on the Knowledge transfer page (/wd/knowledge/imported), each read as
#                 loaded from the two load ledgers
#   spokes        the tmux-agent dashboard, every home-page tile switched off, and every spoke the agent stack's registry
#                 names (/agent/spokes/registry.json): live, without a session or off, and how to turn one off
#   docker        the docker spoke's build substrate: the BuildKit daemon answers at BUILDKIT_HOST, the stack's registry
#                 answers /v2/ at BUILD_REGISTRY, and DOCKER_MIN_FREE_GB is free where Docker keeps the cache and images
# Each check is PASS, GAP (something to do; one that needs a part of the skill this release does not ship yet names it
# in its "not in this release yet" lines) or SKIP (the person said it is not needed: --not-needed <id>; --needed <id>
# undoes it).
#
# --brief prints the table only, --json the JSON instead of the text; --check runs only the named checks; --model,
# --cluster with --region and --repo name what to check when the person has said it.
#
# Writes only under SETUP_DIR (default /wd/setup): doctor.txt (the text), doctor.json (the same for the skill, one
# entry per check, merged with the entries of an earlier run that --check did not repeat), not-needed (the skipped
# checks), kubectl's discovery cache and the Slack doctor's temporary files (removed after each run). Everything else
# is only read: the settings files (.env, .env.local) are not opened, their values reach the doctor as the container's
# environment, git, kubectl, gh and aws are only asked. No credential value is printed or written: every output is
# masked against the credential variables of the environment and the common token shapes.
#
# Settings (environment): SETUP_DIR; DOCTOR_DEFAULT_MODEL (the model probed when nothing configures one - the shipped .env
# configures AGENT_MODEL, passed as ANTHROPIC_MODEL, so this is the case of an empty AGENT_MODEL: Claude Code's own Bedrock
# default, us.anthropic.claude-opus-5-5[1m] for the Claude Code in this image); DOCTOR_EKS_REGIONS (the
# regions scanned for clusters); DOCTOR_HEADLAMP_WAIT and DOCTOR_SLACK_WAIT (seconds, by default 12 and 40: how long
# the eks check waits for Headlamp to list a cluster, and the Slack doctor's whole run); KNOWLEDGE_DIR (default
# /wd/knowledge); KNOWLEDGE_IMPORTED_DIR and INSTINCTS_JSON, or LOGLEARNER_BANKS_DIR / LOGLEARNER_STATE it defaults from (the
# imported packs and the LogLearner bank they load into, the loaders' own settings); SLACK_DOCTOR_BIN; UI_STATUS_BIN;
# SPOKES_REGISTRY (default /agent/spokes/registry.json); HINDSIGHT_API (default
# http://127.0.0.1:${UI_PORT_HINDSIGHT_API}); the harness's own UI_*, SLACK_*, GIT_USER_*, AWS_* and CLAUDE_CONFIG_DIR.
#
# Exit codes: 0 every check PASS or SKIP; 1 at least one GAP; 2 a usage error.

DOCTOR_AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
export DOCTOR_AGENT_DIR
exec python3 -I - "$@" << 'PY'
import concurrent.futures
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ENV = dict(os.environ)
AGENT_DIR = ENV.get("DOCTOR_AGENT_DIR") or "/agent"
SETUP_DIR = ENV.get("SETUP_DIR") or "/wd/setup"
HOME = ENV.get("HOME") or "/home/agent"
CLAUDE_DIR = ENV.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
SKILL_DIR = os.path.join(AGENT_DIR, "skills", "harness-setup")
UI_DIR = ENV.get("UI_DIR") or "/wd/ui"
KNOWLEDGE_DIR = ENV.get("KNOWLEDGE_DIR") or "/wd/knowledge"
ORDER = ["bedrock", "git-identity", "eks", "slack", "github", "memory", "packages", "spokes", "docker"]
TITLES = {"bedrock": "Bedrock", "git-identity": "git identity", "eks": "EKS cluster", "slack": "Slack",
          "github": "GitHub", "memory": "memory", "packages": "shared packages", "spokes": "tmux-agent and spokes",
          "docker": "image builds"}
RESTART = ["# then, in the same shell:", "./stop.sh && ./run.sh"]
CHECKOUT = "# on the host, in your do-agent-aws checkout:"
SETTINGS = "# in .env.local beside .env (your settings, kept out of git; ./config.sh opens it), set:"
SECRET_VARS = ("SLACK_BOT_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN", "AWS_ACCESS_KEY_ID",
               "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_BEARER_TOKEN_BEDROCK", "HINDSIGHT_API_LLM_API_KEY")
TOKEN_SHAPES = [r"xox[abeoprs]-[A-Za-z0-9-]{8,}", r"gh[opsur]_[A-Za-z0-9]{20,}", r"github_pat_[A-Za-z0-9_]{20,}",
                r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b", r"\bABSK[A-Za-z0-9+/=]{20,}", r"\bsk-[A-Za-z0-9_-]{20,}"]


def usage():
    out = []
    for line in open(os.path.join(AGENT_DIR, "doctor.sh"), encoding="utf-8"):
        if line.startswith("# Usage:"):
            out.append(line[2:])
        elif out and line.startswith("#  ") and len(out) < 3:
            out.append(line[2:])
        elif out:
            break
    return "".join(out)


def die(msg):
    print("doctor: " + msg, file=sys.stderr)
    sys.exit(2)


ARGS = {"mode": "full", "check": None, "model": "", "cluster": "", "region": "", "repo": "", "not_needed": [], "needed": []}
argv = sys.argv[1:]
while argv:
    a = argv.pop(0)
    if a in ("-h", "--help"):
        sys.stdout.write(usage())
        sys.exit(0)
    elif a in ("--brief", "--json"):
        ARGS["mode"] = a[2:]
    elif a in ("--check", "--model", "--cluster", "--region", "--repo", "--not-needed", "--needed"):
        if not argv or not argv[0] or argv[0].startswith("--"):
            die(f"{a} needs a value (see --help)")
        v = argv.pop(0)
        if a == "--check":
            ids = [x.strip() for x in v.split(",") if x.strip()]
            bad = [x for x in ids if x not in ORDER]
            if bad:
                die(f"unknown check {', '.join(bad)} - the checks are {', '.join(ORDER)}")
            ARGS["check"] = ids
        elif a in ("--not-needed", "--needed"):
            if v not in ORDER:
                die(f"unknown check {v} - the checks are {', '.join(ORDER)}")
            ARGS[a[2:].replace("-", "_")].append(v)
        else:
            ARGS[a[2:]] = v
    else:
        die(f"unknown argument '{a}' (see --help)")
if ARGS["cluster"] and not ARGS["region"]:
    die("--cluster needs --region (the cluster's AWS region)")
if ARGS["repo"] and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", ARGS["repo"]):
    die("--repo takes owner/name, for example octo-org/octo-repo")
if ARGS["model"] and not re.fullmatch(r"[A-Za-z0-9.:/_-]+", ARGS["model"]):
    die("--model takes a Bedrock model id or inference profile id")
if ARGS["cluster"] and not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z_-]{0,99}", ARGS["cluster"]):
    die("--cluster takes an EKS cluster name: up to 100 letters, digits, - and _, starting with a letter or digit")
if ARGS["region"] and not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]{1,2}", ARGS["region"]):
    die("--region takes an AWS region, for example us-east-2")


def mask(text):
    """Every credential value of the environment, and every common token shape, becomes [redacted]."""
    for k in SECRET_VARS:
        v = ENV.get(k) or ""
        if len(v) >= 6:
            text = text.replace(v, "[redacted]")
    for shape in TOKEN_SHAPES:
        text = re.sub(shape, "[redacted]", text)
    return text


def run(cmd, timeout=20, env=None):
    """(exit code, stdout, stderr) of cmd; 124 on a timeout, 127 when the command is not installed. Never reads stdin.
    Both outputs are masked as they are captured: a line cut later (first_line, the brief table) can split a value
    the output's masking would no longer recognize, and an AWS secret key has no shape to catch the piece left."""
    e = dict(ENV, GH_NO_UPDATE_NOTIFIER="1", GH_PROMPT_DISABLED="1", AWS_PAGER="", NO_COLOR="1")
    e.update(env or {})
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout, env=e)
        return r.returncode, mask(r.stdout), mask(r.stderr)
    except subprocess.TimeoutExpired:
        return 124, "", f"no answer within {timeout}s"
    except FileNotFoundError:
        return 127, "", f"{cmd[0]} is not installed"


def first_line(text, limit=160):
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            return line[:limit]
    return ""


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def http(method, url, body=None, timeout=5):
    """(status, parsed JSON or None); status 0 when nothing answers. Never through a proxy from the environment."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        return e.code, None
    except (urllib.error.URLError, OSError, ValueError):
        return 0, None
    try:
        return status, json.loads(raw or b"null")
    except ValueError:
        return status, None


def flag(name, default="true"):
    return (ENV.get(name) or default).strip().lower()


def writable(path):
    """True when path, or the nearest existing directory above it, can be written here (a read-only mount cannot)."""
    p = os.path.abspath(path)
    while not os.path.exists(p) and os.path.dirname(p) != p:
        p = os.path.dirname(p)
    return os.access(p, os.W_OK)


def is_mount(path):
    """True when path (or the nearest existing parent below /) is a mount point of its own in this container."""
    try:
        points = {line.split()[4] for line in open("/proc/self/mountinfo", encoding="utf-8") if len(line.split()) > 4}
    except OSError:
        return False
    p = os.path.abspath(path)
    while p not in ("/", ""):
        if p in points:
            return True
        p = os.path.dirname(p)
    return False


def env_line(name, value):
    return f"export {name}={shlex.quote(value)}"


def result(state, found, inside=None, done=None, host=None, verify=None, pending=None, facts=None, doc=None, note=None):
    return {"state": state, "found": found, "inside": inside or [], "done": done or [], "host": host or [],
            "verify": verify or [], "pending": pending or [], "facts": facts or {}, "doc": doc or "", "note": note or []}


def pending_input(name):
    """The first line of a skill file that is still a placeholder ('input pending: ...'), else ''."""
    try:
        with open(os.path.join(SKILL_DIR, name), encoding="utf-8") as f:
            head = f.readline().strip().lstrip("#").strip()
    except OSError:
        return f"input pending: {name} is not in this image"
    return head if head.lower().startswith("input pending") else ""


# --- checks (one function per check id; each returns result(...)) ---

# the model Claude Code calls on Bedrock when nothing configures one (the shipped .env configures AGENT_MODEL, passed as
# ANTHROPIC_MODEL: this is the case of an empty AGENT_MODEL), measured for the Claude Code this image installs (unpinned: an
# upgrade can change it): since Claude Code 2.1.287 its Bedrock default runs with the 1M-token context window and is
# reported with the [1m] suffix (measured 2026-10-31 on 2.1.304 with ANTHROPIC_MODEL unset: modelUsage names
# us.anthropic.claude-opus-5-5[1m]). test23's live drive compares it with the model Claude Code called and fails, naming
# both, when they differ
DEFAULT_MODEL = ENV.get("DOCTOR_DEFAULT_MODEL") or "us.anthropic.claude-opus-5-5[1m]"
# Claude Code's context-window suffix on a model id ([1m]: its request for the 1M-token window), which is not part of the
# Bedrock model id - Bedrock refuses the id with it. Exactly the suffix Claude Code strips (/\[1m\]$/i in 2.1.304): another
# bracketed suffix would reach Bedrock as written, so the doctor leaves it in place too
CONTEXT_SUFFIX = re.compile(r"\[1m\]$", re.I)
# the model aliases Claude Code resolves through ANTHROPIC_DEFAULT_<TIER>_MODEL (the shipped .env passes the opus and fable ones)
TIER_ALIASES = ("opus", "sonnet", "haiku", "fable")
PROFILE_PREFIXES = ("us.", "eu.", "apac.", "jp.", "au.", "ca.", "global.", "us-gov.")
BEDROCK_DOC = "docs/bedrock/README.md (model access, the policy, credentials); docs/manual/aws.md \"AWS credentials\""


def geo_prefixes(region):
    """The inference-profile prefixes a region serves, where the rule is known (US, EU, Asia Pacific), else ()."""
    for start, prefixes in (("us-gov-", ("us-gov.",)), ("us-", ("us.", "global.")), ("eu-", ("eu.", "global.")),
                            ("ap-", ("apac.", "jp.", "au.", "global."))):
        if region.startswith(start):
            return prefixes
    return ()


def bedrock_id(model):
    """The model id as Bedrock knows it: the configured id without a trailing context-window suffix such as [1m]."""
    return CONTEXT_SUFFIX.sub("", model)


def context_window(model):
    """What the id asks Claude Code for: '1M' with the [1m] suffix, else 'default' - the window Claude Code gives the model
    on its own."""
    return "1M" if CONTEXT_SUFFIX.search(model) else "default"


def settings_and_env():
    """The agent's settings.json as a dict (empty when absent or not an object) and its env block, whose values outrank the
    process environment for every claude process (measured 2026-10-31 on Claude Code 2.1.304: env.ANTHROPIC_MODEL in
    settings.json was the model called, with another ANTHROPIC_MODEL in the environment)."""
    s = load_json(os.path.join(CLAUDE_DIR, "settings.json"))
    s = s if isinstance(s, dict) else {}
    e = s.get("env") if isinstance(s.get("env"), dict) else {}
    return s, e


def claude_env(name, env_block):
    """The value Claude Code sees for a variable and where it comes from: ('<value>', 'settings') from settings.json's env
    block, ('<value>', 'environment') from the process environment, ('', '') when neither sets it."""
    v = env_block.get(name)
    if isinstance(v, str) and v:
        return v, "settings"
    if ENV.get(name):
        return ENV[name], "environment"
    return "", ""


def resolve_model():
    """The model id Claude Code calls here, where it comes from, and the facts of the resolution: a tier alias (fable,
    opus[1m], ...) is resolved through ANTHROPIC_DEFAULT_<TIER>_MODEL, or left unresolved (alias_unresolved) when nothing
    says which id it stands for; with nothing configured, Claude Code's default follows ANTHROPIC_DEFAULT_OPUS_MODEL when
    that is set (measured 2026-10-31 on 2.1.304: the pinned id was the model called), else DEFAULT_MODEL (default_from)."""
    settings, env_block = settings_and_env()
    extra = {}
    if ARGS["model"]:
        return ARGS["model"], "--model", extra
    model, where = claude_env("ANTHROPIC_MODEL", env_block)
    if model:
        source = "settings" if where == "settings" else "ANTHROPIC_MODEL"
        alias = bedrock_id(model).lower()
        if alias in TIER_ALIASES:
            extra["model_alias"] = model
            resolved, _ = claude_env(f"ANTHROPIC_DEFAULT_{alias.upper()}_MODEL", env_block)
            if not resolved:
                extra["alias_unresolved"] = True
                return model, source, extra
            model = resolved
        return model, source, extra
    m = settings.get("model")
    if isinstance(m, str) and ("anthropic." in m or m.startswith("arn:")):
        return m, "settings-model", extra
    pinned, _ = claude_env("ANTHROPIC_DEFAULT_OPUS_MODEL", env_block)
    if pinned:
        extra["default_from"] = "ANTHROPIC_DEFAULT_OPUS_MODEL"
        return pinned, "default", extra
    extra["default_from"] = "built-in"
    return DEFAULT_MODEL, "default", extra


def prefix_finding(model, region):
    """The us. prefix rule: an Anthropic model is called on demand through an inference profile of the region's geography.
    The id's [1m] suffix, Claude Code's and not Bedrock's, stays on the id the finding proposes."""
    if model.startswith("arn:"):
        return ""
    geo = geo_prefixes(region)
    if model.startswith("anthropic."):
        return (f"{model} has no inference-profile prefix, and Bedrock refuses it on demand - "
                f"use {(geo[0] if geo else 'us.')}{model}")
    head = model.split(".", 1)[0] + "."
    if geo and head in PROFILE_PREFIXES and head not in geo:
        return f"{model} is a {head[:-1]} inference profile, which {region} does not serve - use {geo[0]}{model[len(head):]}"
    return ""


def model_fix(source, model, fixed, pinned=False):
    """(inside, host) lines that change the model where it is configured (pinned: the default follows the opus alias' id)."""
    if source == "ANTHROPIC_MODEL":
        return [], [CHECKOUT, SETTINGS, f"export AGENT_MODEL={shlex.quote(fixed) if fixed else '<a model id with access>'}",
                    "# (AGENT_MODEL reaches the container as ANTHROPIC_MODEL; a [1m] suffix asks Claude Code for the 1M context window;",
                    f"#  empty, nothing is passed and Claude Code uses its own Bedrock default, {DEFAULT_MODEL})"] + RESTART
    if source in ("settings", "settings-model"):
        key = "env.ANTHROPIC_MODEL" if source == "settings" else "model"
        return [f"set {key} to {shlex.quote(fixed or DEFAULT_MODEL)} in {os.path.join(CLAUDE_DIR, 'settings.json')} "
                "(persisted agent state; the next session uses it)"], []
    if source == "--model":
        return [], []
    if pinned:
        return [], [CHECKOUT, SETTINGS, f"export AGENT_MODEL_OPUS={shlex.quote(fixed) if fixed else '<a model id with access>'}   # Claude Code's default here follows the opus alias",
                    "# or set AGENT_MODEL to the model id itself"] + RESTART
    return [], [CHECKOUT, f"export AWS_REGION=<a region that serves {bedrock_id(model)}>"] + RESTART


def check_bedrock():
    region = ENV.get("AWS_REGION") or ENV.get("AWS_DEFAULT_REGION") or ""
    model, source, extra = resolve_model()
    bid, window = bedrock_id(model), context_window(model)
    pinned = extra.get("default_from") == "ANTHROPIC_DEFAULT_OPUS_MODEL"
    verify = ["/agent/doctor.sh --check bedrock   # expect: PASS, the model answered with one token"]
    creds_host = [CHECKOUT, "# give the container AWS credentials that can call Bedrock, one of:",
                  "#   on EC2: an instance role with the policy docs/bedrock/bedrock-agent-policy.json (nothing to export), or",
                  "export AWS_PROFILE=<a profile in ~/.aws/config with Bedrock access>",
                  f"export AWS_REGION={shlex.quote(region) if region else 'us-east-1'}   # a region where the account has model access"] + RESTART
    facts = {"region": region, "model": model, "model_source": source, "bedrock_model_id": bid, "context_window": window, **extra}
    if not region:
        return result("GAP", "AWS_REGION is not set in the container; Claude Code on Bedrock needs it",
                      host=[CHECKOUT, "export AWS_REGION=us-east-1   # or another region with model access"] + RESTART,
                      verify=verify, facts=facts, doc=BEDROCK_DOC)
    rc, out, err = run(["aws", "sts", "get-caller-identity", "--output", "json"], 25)
    if rc != 0:
        why = first_line(err) or f"exit {rc}"
        if "could not be found" in why and "profile" in why:
            host = [CHECKOUT, "export AWS_PROFILE=<a profile that exists in ~/.aws/config on the host>"] + RESTART
        elif re.search(r"expired|refresh failed|sso", why, re.I):
            host = [CHECKOUT, "aws sso login --profile \"$AWS_PROFILE\"   # or renew the keys you export"] + RESTART
        else:
            host = creds_host
        return result("GAP", f"no AWS credentials reach the container ({why})", host=host, verify=verify,
                      done=[f"aws sts get-caller-identity: {why}"], facts=facts, doc=BEDROCK_DOC)
    ident = load_json_text(out)
    arn = str(ident.get("Arn") or "") if isinstance(ident, dict) else ""
    who = re.sub(r"^arn:aws[^:]*:(?:sts|iam)::\d+:(?:assumed-role|role|user)/", "", arn).split("/")[0] or "an AWS identity"
    facts["identity"] = who
    done = [f"aws sts get-caller-identity: {who}"]
    if extra.get("alias_unresolved"):
        alias = bedrock_id(model).lower()
        host = [CHECKOUT, SETTINGS, "export AGENT_MODEL=<a full model id with access>"]
        if alias in ("opus", "fable"):
            host.append(f"# or keep the alias and set AGENT_MODEL_{alias.upper()} to the id it should use")
        return result("GAP", f"{model} is a model alias, and no ANTHROPIC_DEFAULT_{alias.upper()}_MODEL here says which id Claude Code "
                      "resolves it to, so there is nothing to probe", host=host + RESTART, verify=verify, done=done, facts=facts, doc=BEDROCK_DOC)
    finding = prefix_finding(model, region)
    if finding:
        fixed = re.search(r"use (\S+)$", finding)
        inside, host = model_fix(source, model, fixed.group(1) if fixed else "", pinned)
        return result("GAP", finding, inside=inside, host=host, verify=verify, done=done, facts=facts, doc=BEDROCK_DOC)
    msgs = json.dumps([{"role": "user", "content": [{"text": "Reply with OK"}]}])
    rc, out, err = run(["aws", "bedrock-runtime", "converse", "--region", region, "--model-id", bid, "--messages", msgs,
                        "--inference-config", json.dumps({"maxTokens": 1}), "--output", "json"], 45)
    done.append(f"aws bedrock-runtime converse --model-id {bid} (one token"
                + (f"; the {model[len(bid):]} suffix asks Claude Code for the {window} context window and is not part of the "
                   "Bedrock id)" if bid != model else ")"))
    answer = load_json_text(out)
    content = (((answer or {}).get("output") or {}).get("message") or {}).get("content") if isinstance(answer, dict) else None
    if rc == 0 and isinstance(content, list):
        found = f"{model} answers in {region}" + (f" with the {window} context window" if bid != model else "") + f" (as {who})"
        return result("PASS", found, done=done, verify=verify, facts=facts)
    why = re.sub(r"^aws: \[ERROR\]: ", "", first_line(err, 240) or f"exit {rc}")
    if "ThrottlingException" in why:
        # the id and the access may well be right, but no answer came back, so nothing is proven yet
        return result("GAP", f"{model} in {region}: Bedrock throttled the one-token call, so no answer came back (as {who})",
                      inside=["/agent/doctor.sh --check bedrock   # again in a minute: a throttle passes"],
                      host=["# a throttle that does not pass: raise the account's Bedrock quota for this model (Service Quotas,",
                            f"# Amazon Bedrock, requests and tokens per minute for {bid} in {region})"],
                      verify=verify, done=done, facts=facts, doc=BEDROCK_DOC)
    if re.search(r"AccessDenied|don't have access|not authorized|not have access", why, re.I):
        host = ["# in the Bedrock console of " + region + ": Model access - request access to the Anthropic models (once per account)",
                f"# and allow bedrock:InvokeModel* for {who}: the policy in docs/bedrock/bedrock-agent-policy.json"]
        return result("GAP", f"Bedrock refuses {who} for {model} ({why})", host=host, verify=verify, done=done,
                      facts=facts, doc=BEDROCK_DOC)
    if re.search(r"ExpiredToken|UnrecognizedClient|InvalidSignature|security token", why, re.I):
        return result("GAP", f"the AWS credentials were refused ({why})", host=creds_host, verify=verify, done=done,
                      facts=facts, doc=BEDROCK_DOC)
    inside, host = model_fix(source, model, "", pinned)
    if "on-demand throughput" in why:
        geo = geo_prefixes(region)
        inside, host = model_fix(source, model, (geo[0] if geo else "us.") + model.split(".", 1)[-1], pinned)
    called = f"{bid} ({model} without its suffix)" if bid != model else bid
    return result("GAP", f"Bedrock refuses the model id {called} in {region}: {why}", inside=inside, host=host,
                  verify=verify, done=done, facts=facts, doc=BEDROCK_DOC)


def load_json_text(text):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def check_git_identity():
    name, email = ENV.get("GIT_USER_NAME") or "", ENV.get("GIT_USER_EMAIL") or ""
    # under the harness's own rule (git-identity.sh sets user.useConfigOnly): without it git invents root@<host> where the
    # host name has a domain (a Docker Sandbox's VM does), and a commit the harness refuses would read as configured
    rc, out, _ = run(["git", "-c", "user.useConfigOnly=true", "var", "GIT_AUTHOR_IDENT"], 10)
    ident = re.sub(r"\s+\d+\s+[+-]\d{4}$", "", out.strip()) if rc == 0 else ""
    verify = ["git var GIT_AUTHOR_IDENT   # expect: your name <your email> and a timestamp",
              "/agent/doctor.sh --check git-identity"]
    facts = {"identity": ident, "env_set": bool(name and email)}
    if name and email and ident.startswith(f"{name} <{email}>"):
        return result("PASS", f"{ident} (GIT_USER_NAME, GIT_USER_EMAIL from the settings)", verify=verify, facts=facts)
    if name and email:
        return result("GAP", f"GIT_USER_NAME and GIT_USER_EMAIL are set, but git uses {ident or 'no identity'}",
                      inside=["/agent/git-identity.sh   # writes them as the container's git configuration again"],
                      verify=verify, facts=facts, doc="docs/manual/install.md \"Git identity\"")
    m = re.match(r"(.*) <([^>]*)>$", ident)
    vname, vemail = (m.group(1), m.group(2)) if m else ("<your name>", "<your email>")
    host = [CHECKOUT, SETTINGS,
            env_line("GIT_USER_NAME", vname), env_line("GIT_USER_EMAIL", vemail)] + RESTART[1:]
    if ident:
        return result("GAP", f"{ident} is set for this container only: the next start clears it",
                      host=host, verify=verify, facts=facts, doc="docs/manual/install.md \"Git identity\"")
    return result("GAP", "no git identity: a commit here is refused",
                  inside=["git config --global user.name '<your name>'    # this container only, until the next start",
                          "git config --global user.email '<your email>'"],
                  host=host, verify=verify, facts=facts, doc="docs/manual/install.md \"Git identity\"")

EKS_REGIONS = (ENV.get("DOCTOR_EKS_REGIONS") or "us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 eu-west-1 eu-west-2 "
               "eu-west-3 eu-central-1 eu-north-1 ap-south-1 ap-northeast-1 ap-northeast-2 ap-northeast-3 ap-southeast-1 "
               "ap-southeast-2 sa-east-1").split()
EKS_DOC = "eks-access-entry.md beside the harness-setup skill; docs/manual/ui.md \"Harness UIs\" (cluster access is the container's)"


# the host's ~/.kube is the container's /home/agent/.kube when ./run.sh mounts it (.env KUBE_MOUNT, KUBE_HOST_MOUNT=true): a
# kubeconfig written there is the person's own file, and update-kubeconfig also makes its new context the current one,
# so the eks check gives that step as a host line then and never as one the agent runs
KUBE_HOST = flag("KUBE_HOST_MOUNT", "false") == "true"


def kubectl(args, timeout=20):
    # the discovery and HTTP caches go under SETUP_DIR, never into the person's ~/.kube
    return run(["kubectl", "--cache-dir", os.path.join(SETUP_DIR, "kube-cache")] + args, timeout)


def principal():
    """(ARN, role) of the IAM principal the container acts as, for an access entry. An assumed role's ARN is its role's,
    which only IAM gives whole: the assumed-role ARN leaves out the role's path (an IAM Identity Center role has one).
    When the container may not ask IAM, the ARN is '' and role names the role for the person's host line; otherwise
    role is ''. ('', '') without an identity."""
    rc, out, _ = run(["aws", "sts", "get-caller-identity", "--output", "json"], 20)
    arn = str((load_json_text(out) or {}).get("Arn") or "") if rc == 0 else ""
    m = re.match(r"arn:(aws[^:]*):sts::(\d+):assumed-role/([^/]+)/", arn)
    if not m:
        return arn, ""
    rc, out, _ = run(["aws", "iam", "get-role", "--role-name", m.group(3), "--query", "Role.Arn", "--output", "text"], 20)
    role_arn = out.strip() if rc == 0 else ""
    if re.fullmatch(r"arn:%s:iam::%s:role/(?:[\w+=,.@-]+/)*%s" % (re.escape(m.group(1)), m.group(2), re.escape(m.group(3))), role_arn):
        return role_arn, ""
    return "", m.group(3)


# Headlamp's watcher re-reads ~/.kube/config every 10 s (a changed file, and a missing one until it appears), so a
# context written moments ago is listed on its next re-read: the eks check waits that long before calling it a gap
try:
    HEADLAMP_WAIT = max(0.0, float(ENV.get("DOCTOR_HEADLAMP_WAIT") or 12))
except ValueError:
    HEADLAMP_WAIT = 12.0


def headlamp_clusters():
    """The cluster names Headlamp lists, or None when Headlamp is off or does not answer."""
    if flag("UI_HEADLAMP") != "true":
        return None
    base = "/headlamp" if flag("UI_HOME") == "true" else ""
    status, body = http("GET", f"http://127.0.0.1:{ENV.get('UI_PORT_HEADLAMP') or '4466'}{base}/config")
    if status != 200 or not isinstance(body, dict):
        return None
    return [str(c.get("name")) for c in body.get("clusters") or [] if isinstance(c, dict) and c.get("name")]


def headlamp_lists(listed, ctx, name):
    """Headlamp lists a kubeconfig context under a sanitized name: every "/" of it becomes "--"."""
    names = {ctx, name, ctx.replace("/", "--")}
    return any(c in names or c.endswith((f"/{name}", f"--{name}")) for c in listed)


def access_entry_host(who, cluster, region, role=""):
    """The host part when the cluster refuses the container's role: eks-access-entry.md's lines, filled in - the access
    entry (runnable) and, for a cluster on the aws-auth ConfigMap, its alternative (commented). role (principal()):
    the container could not ask IAM for its role's ARN, so the first line asks for it on the host."""
    shown = who or (f"the role {role}" if role else "aws sts get-caller-identity in the container shows it")
    lines = ["# with your own credentials, on a machine with admin access to the cluster: give the container's identity",
             f"# ({shown}) read-only access to {cluster}"]
    arn = shlex.quote(who) if who else "<principal-arn>"
    if role:
        lines += ["# the role's ARN as IAM gives it, with its path (the container's identity may not ask IAM for it):",
                  f"PRINCIPAL_ARN=\"$(aws iam get-role --role-name {shlex.quote(role)} --query Role.Arn --output text)\""]
        arn = '"$PRINCIPAL_ARN"'
    pend = pending_input("eks-access-entry.md")
    if pend:
        return lines + [f"# {pend}"]
    try:
        text = open(os.path.join(SKILL_DIR, "eks-access-entry.md"), encoding="utf-8").read()
    except OSError:
        return lines
    # every value quoted for the shell: the person pastes these lines as they are
    fill = lambda x: (x.replace("<principal-arn>", arn).replace("<cluster>", shlex.quote(cluster))
                      .replace("<region>", shlex.quote(region) if region else "<region>"))
    blocks = re.findall(r"```(?:sh|bash)\n(.*?)```", text, re.S)
    entry = next((b for b in blocks if "create-access-entry" in b), "")
    auth = next((b for b in blocks if "iamidentitymapping" in b), "")
    out = lines + [fill(x) for x in entry.splitlines()]
    if auth:
        out += ["# or, on a cluster that still uses the aws-auth ConfigMap, instead:"] + ["#   " + fill(x) for x in auth.splitlines()]
    return out


def kube_persist_host(name, region):
    # this release keeps the container's ~/.kube under wd/agent-state (the host's own ~/.kube instead, when it has one):
    # a container started before it has neither, and a restart brings the mount
    return [CHECKOUT, "./stop.sh && ./run.sh   # the container's ~/.kube is kept under wd/agent-state from then on",
            f"# then the agent writes the kubeconfig again: aws eks update-kubeconfig --name {shlex.quote(name)} "
            f"--region {shlex.quote(region) if region else '<region>'} --kubeconfig ~/.kube/config"]


def check_eks():
    verify = ["kubectl get pods -A   # expect: the cluster's pods, read-only", "/agent/doctor.sh --check eks"]
    paths = [p for p in (ENV.get("KUBECONFIG") or "").split(":") if p] or [os.path.join(HOME, ".kube", "config")]
    kc = next((p for p in paths if os.path.isfile(p)), "")
    persists = KUBE_HOST or is_mount(os.path.dirname(kc or paths[0]))
    facts = {"kubeconfig": kc, "kubeconfig_persists": persists}
    want, want_region = ARGS["cluster"], ARGS["region"]
    done, contexts, current = [], [], ""
    if kc:
        rc, out, _ = kubectl(["config", "get-contexts", "-o", "name"], 10)
        contexts = [c.strip() for c in out.splitlines() if c.strip()] if rc == 0 else []
        rc, out, _ = kubectl(["config", "current-context"], 10)
        current = out.strip() if rc == 0 else ""
        done.append(f"kubeconfig {kc}: {len(contexts)} context(s)" + (f", current {current}" if current else ""))
    if want:
        ctx = next((c for c in contexts if c == want or c.endswith(f"/{want}")), "")
    else:
        ctx = current
    if ctx:
        name = want or ctx.rsplit("/", 1)[-1]
        m = re.match(r"arn:aws[^:]*:eks:([a-z0-9-]+):", ctx)
        region = want_region or (m.group(1) if m else "")
        # the read the printed grants give (AmazonEKSViewPolicy, the view ClusterRole): namespaced objects in every
        # namespace; nodes are cluster-scoped and outside that policy, so they are read only when the cluster allows it
        rc, out, err = kubectl(["--context", ctx, "auth", "can-i", "list", "pods", "--all-namespaces", "--request-timeout=15s"], 30)
        answer = out.strip().lower()
        done.append(f"kubectl auth can-i list pods --all-namespaces (context {ctx}): {answer or first_line(err) or 'exit ' + str(rc)}")
        if answer != "yes":
            if answer == "no" or re.search(r"Unauthorized|forbidden|must be logged in", err, re.I):
                who, role = principal()
                pend = pending_input("eks-access-entry.md")
                return result("GAP", f"{name}: the container's identity cannot read the cluster ({answer or first_line(err)})",
                              host=access_entry_host(who, name, region, role), verify=verify, done=done,
                              pending=[pend] if pend else [], facts=dict(facts, principal=who or (f"role {role}" if role else "")), doc=EKS_DOC)
            return result("GAP", f"{name}: the cluster does not answer ({first_line(err) or 'exit ' + str(rc)})",
                          inside=[f"aws eks describe-cluster --name {shlex.quote(name)} --region "
                                  f"{shlex.quote(region) if region else '<region>'} --query cluster.status"],
                          host=["# an endpoint that does not answer is often a private one the container's network cannot reach:",
                                "# that is a VPC question for the cluster's owner, not an access entry"],
                          verify=verify, done=done, facts=facts, doc=EKS_DOC)
        rc, out, err = kubectl(["--context", ctx, "get", "pods", "--all-namespaces", "--no-headers", "--request-timeout=15s"], 30)
        if rc != 0:
            # can-i answered, so the API answered: this is the cluster's refusal or error, not the network
            return result("GAP", f"{name}: can-i answers yes, but kubectl get pods fails: {first_line(err) or 'exit ' + str(rc)}",
                          inside=[f"kubectl --context {shlex.quote(ctx)} get pods -A   # shows the whole error; the API answered can-i"],
                          verify=verify, done=done, facts=facts, doc=EKS_DOC)
        pods = [x.split() for x in out.splitlines() if x.strip()]
        spaces = len({x[0] for x in pods if x})
        done.append(f"kubectl get pods --all-namespaces: {len(pods)} pod(s) in {spaces} namespace(s)")
        rc, out, _ = kubectl(["--context", ctx, "auth", "can-i", "list", "nodes", "--request-timeout=15s"], 30)
        nodes = None
        if out.strip().lower() == "yes":
            rc, out, _ = kubectl(["--context", ctx, "get", "nodes", "-o", "name", "--request-timeout=15s"], 30)
            nodes = len([n for n in out.splitlines() if n.strip()]) if rc == 0 else None
        done.append(f"kubectl get nodes: {nodes} node(s)" if nodes is not None else
                    "nodes: not readable - they are cluster-scoped, outside the view policy the access entry grants (optional)")
        what = f"{len(pods)} pod(s) in {spaces} namespace(s)" + (f", {nodes} node(s)" if nodes is not None else "")
        listed = headlamp_clusters()
        deadline = time.monotonic() + HEADLAMP_WAIT
        while listed is not None and not headlamp_lists(listed, ctx, name) and time.monotonic() < deadline:
            time.sleep(2)
            listed = headlamp_clusters()
        facts.update(pods=len(pods), namespaces=spaces, nodes=nodes, headlamp=listed)
        # every gap of a readable cluster in one answer: Headlamp's list is the agent's to fix inside (a context it has
        # not listed after its re-read needs a restart, which loads the kubeconfig at the start), the kubeconfig's
        # survival the person's on the host
        gaps, inside, host = [], [], []
        if listed is not None and not headlamp_lists(listed, ctx, name):
            gaps.append("Headlamp does not list the cluster")
            inside.append(f"kill \"$(cat {UI_DIR}/headlamp.pid)\"; /agent/ui-start.sh   # not listed after its 10 s re-read of ~/.kube/config: a restart loads it")
        if not persists:
            gaps.append("the kubeconfig is lost at the next restart")
            host = kube_persist_host(name, region)
        if gaps:
            return result("GAP", f"{name}: {what} readable, but " + " and ".join(gaps), inside=inside, host=host,
                          verify=verify, done=done, facts=facts, doc=EKS_DOC)
        return result("PASS", f"{name}: {what} readable" + (", listed in Headlamp" if listed else ""),
                      verify=verify, done=done, facts=facts)
    def ask(cmd):
        """(answer, error kind) of one aws eks call: kind is '', 'denied', 'creds' or 'other'."""
        rc, out, err = run(cmd, 25)
        if rc == 0:
            return load_json_text(out) or {}, ""
        if re.search(r"AccessDenied|not authorized", err, re.I):
            return None, "denied"
        if re.search(r"Unable to locate credentials|ExpiredToken|security token|could not be found|refresh failed", err, re.I):
            return None, "creds"
        return None, "other"

    if want:
        regions = [want_region]
        answer, kind = ask(["aws", "eks", "describe-cluster", "--name", want, "--region", want_region, "--output", "json"])
        found, kinds = ([(want, want_region)] if answer is not None else []), [kind]
        done.append(f"aws eks describe-cluster --name {want} --region {want_region}: {'found' if found else kind or 'not found'}")
    else:
        regions, found, kinds = EKS_REGIONS, [], []

        def scan(region):
            answer, kind = ask(["aws", "eks", "list-clusters", "--region", region, "--output", "json"])
            return region, [str(n) for n in (answer or {}).get("clusters") or []], kind

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            for region, names, kind in pool.map(scan, regions):
                found += [(n, region) for n in names]
                kinds.append(kind)
        done.append(f"aws eks list-clusters in {len(regions)} regions: "
                    + (", ".join(f"{n} ({r})" for n, r in found) if found else "no cluster")
                    + "".join(f"; {kinds.count(k)} {k}" for k in ("denied", "creds", "other") if k in kinds))
    denied = kinds.count("denied")
    facts["clusters_found"] = [f"{n} ({r})" for n, r in found]
    if not found and kinds and all(k == "creds" for k in kinds):
        return result("GAP", "no AWS credentials to look for a cluster with (the bedrock check names the fix)",
                      host=[CHECKOUT, "export AWS_PROFILE=<a profile in ~/.aws/config>   # or an EC2 instance role: nothing to export"]
                      + RESTART, verify=verify, done=done, facts=facts, doc=EKS_DOC)
    if found:
        n, r = found[0]
        others = f" (+{len(found) - 1} more: {', '.join(f'{x} ({y})' for x, y in found[1:4])})" if len(found) > 1 else ""
        if KUBE_HOST:
            return result("GAP", f"no kubeconfig for {n} ({r}){others}",
                          inside=["kubectl auth can-i list pods -A   # after your host line: yes is read access; no or Unauthorized: the access entry"],
                          host=["# your ~/.kube is the container's (./run.sh mounts it), so its kubeconfig is yours: on the host, this adds",
                                "# the cluster's context to ~/.kube/config and makes it the current one (kubectl config use-context",
                                "# <the context you had> switches back)",
                                f"aws eks update-kubeconfig --name {shlex.quote(n)} --region {shlex.quote(r)}"],
                          verify=verify, done=done, facts=facts, doc=EKS_DOC)
        if not writable(os.path.join(HOME, ".kube")):
            # a kubeconfig mounted read-only (a Secret, a :ro bind mount): the agent cannot write one, so the cluster's
            # context is added where that file comes from
            return result("GAP", f"no kubeconfig for {n} ({r}){others}; the container's ~/.kube is on a read-only mount",
                          inside=["kubectl auth can-i list pods -A   # after the host line: yes is read access; no or Unauthorized: the access entry"],
                          host=["# the container's ~/.kube is read-only (a mounted kubeconfig): add the cluster where that file comes",
                                "# from, on the machine that owns it; this also makes the new context the current one there",
                                f"aws eks update-kubeconfig --name {shlex.quote(n)} --region {shlex.quote(r)}"],
                          verify=verify, done=done, facts=facts, doc=EKS_DOC)
        return result("GAP", f"no kubeconfig for {n} ({r}){others}",
                      inside=[f"aws eks update-kubeconfig --name {shlex.quote(n)} --region {shlex.quote(r)} --kubeconfig ~/.kube/config",
                              "kubectl auth can-i list pods -A   # yes: read access; no or Unauthorized: the host step (an access entry)"],
                      host=[] if persists else kube_persist_host(n, r), verify=verify, done=done, facts=facts, doc=EKS_DOC)
    if denied:
        why = "the container's role may not list or describe clusters (eks:ListClusters, eks:DescribeCluster)"
    else:
        where = f"the region {regions[0]}" if want or len(regions) == 1 else f"{len(regions)} regions"
        why = f"no EKS cluster in {where} for this account"
    return result("GAP", f"no cluster: {why}",
                  host=[CHECKOUT, "# give the container role eks:DescribeCluster and eks:ListClusters (docs/manual/ui.md \"Harness UIs\"),",
                        "# or share a kubeconfig you already have: ./run.sh mounts the host's ~/.kube when it exists, and the",
                        "# agent then reads it; the setup skill leaves writing it to you (update-kubeconfig becomes your host line)",
                        "mkdir -p ~/.kube && touch ~/.kube/config && chmod 600 ~/.kube/config",
                        "# that mount hides the kubeconfig the agent keeps in this container: merge its contexts into yours first,",
                        "# read through the running container (the kept file is root's), by the name ./run.sh gives it (CONTAINER_NAME",
                        "# from .env or .env.local); yours win where both name the same one, and a read that fails says so and leaves",
                        "# yours as it was",
                        "(umask 077 && C=$(bash -c '. ./.env > /dev/null 2>&1; printf %s \"${CONTAINER_NAME#--name }\"') && "
                        "{ [ -n \"${C}\" ] || { echo 'no container name from ./.env: run this in your do-agent-aws checkout' >&2; false; }; } && "
                        "docker exec -i \"${C}\" sh -c 'KUBECONFIG=/dev/stdin:/home/agent/.kube/config kubectl config view --flatten' "
                        "< ~/.kube/config > ~/.kube/config.merged) && mv ~/.kube/config.merged ~/.kube/config "
                        "|| { rm -f ~/.kube/config.merged; echo 'not merged: ~/.kube/config is as it was' >&2; false; }"]
                  + RESTART[1:],
                  verify=verify, done=done, facts=facts, doc=EKS_DOC)


SLACK_DOC = "slack-app-manifest.yaml beside the harness-setup skill; docs/slack/README.md (the verification ladder)"
SLACK_ROW = re.compile(r"^(PASS|GAP)\s+(token|scopes|chat:write|channels|channel \S+|post-round-trip|thread-round-trip)\s+(.*)$")
# the Slack doctor's whole run: a Slack API that does not answer costs it one request (curl's 20 s, then it stops), and
# the other checks need the rest of the first turn's Bash call (two minutes in Claude Code by default)
try:
    SLACK_WAIT = max(1.0, float(ENV.get("DOCTOR_SLACK_WAIT") or 40))
except ValueError:
    SLACK_WAIT = 40.0


def slack_host(rows=None):
    """The person's Slack steps: the app from the manifest the skill ships, its token, the channels, the settings."""
    manifest = os.path.join(SKILL_DIR, "slack-app-manifest.yaml")
    steps = ["# 1. create the app at https://api.slack.com/apps: Create New App -> From an app manifest -> your workspace ->",
             f"#    paste the manifest the agent prints ({manifest}; read-only, chat:write the opt-in)",
             "# 2. Install to Workspace (OAuth & Permissions) and copy the Bot User OAuth Token: it starts with xoxb-",
             "# 3. in each channel the agent should read: /invite @<your app>; a channel's id is in its details (C...)",
             CHECKOUT, "export SLACK_BOT_TOKEN=<the xoxb- token>   # in this shell, or in .env.local (kept out of git)",
             SETTINGS + " the channel ids, comma-separated, no spaces, and a test channel of your own:",
             "export SLACK_CHANNELS=<channel id>,<channel id>",
             "export SLACK_TEST_CHANNEL=<channel id>   # for the doctor's --post-test round-trip only; may equal one above"]
    if "SPOKE_COMMS" in ENV:
        steps.append("export SPOKE_COMMS=true   # start the comms spoke (off by default: it costs calls and tokens)")
    return steps + RESTART[1:]


def check_slack():
    token, chans = ENV.get("SLACK_BOT_TOKEN") or "", [c for c in (ENV.get("SLACK_CHANNELS") or "").split(",") if c.strip()]
    sd = ENV.get("SLACK_DOCTOR_BIN") or os.path.join(AGENT_DIR, "slack-doctor.sh")
    verify = ["/agent/slack-doctor.sh   # token, scopes against the manifest, each channel; reads only, posts nothing",
              "/agent/slack-doctor.sh --post-test   # your choice: two labelled messages in SLACK_TEST_CHANNEL, read back",
              "# then post a message in a watched channel: it is in the agent's inbox (/agent/slack-status.sh), and with",
              "# chat:write the agent answers in its thread (/agent/slack-chat-status.sh)",
              "/agent/doctor.sh --check slack"]
    kind = ", a bot token" if token.startswith("xoxb-") else (", a user token" if token.startswith("xoxp-") else "")
    facts = {"token": f"set ({len(token)} characters{kind})" if token else "not set", "channels": len(chans)}
    if not token or not chans:
        missing = " and ".join(n for n, v in (("SLACK_BOT_TOKEN", token), ("SLACK_CHANNELS", chans)) if not v)
        return result("GAP", f"not connected: no {missing}", host=slack_host(), verify=verify, facts=facts, doc=SLACK_DOC)
    if not (os.path.isfile(sd) and os.access(sd, os.X_OK)):
        return result("GAP", f"the Slack doctor is missing from this image ({sd}): rebuild the image", verify=verify,
                      host=[CHECKOUT, "git pull && ./build.sh"] + RESTART, facts=facts, doc=SLACK_DOC)
    tmp = os.path.join(SETUP_DIR, "tmp")
    os.makedirs(tmp, exist_ok=True)
    # a directory of this run's own, removed after it: a Slack doctor stopped at the budget cannot remove its files
    work = tempfile.mkdtemp(dir=tmp)
    try:
        rc, out, err = run([sd], SLACK_WAIT, env={"TMPDIR": work})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    rows = [(m.group(1), m.group(2), m.group(3).strip()) for m in (SLACK_ROW.match(x.strip()) for x in out.splitlines()) if m]
    gaps = [r for r in rows if r[0] == "GAP"]
    write = next((d for s, ck, d in rows if ck == "chat:write"), "")
    scope_set = ("read and write (chat:write granted)" if write.startswith("granted") else
                 "read-only (no chat:write)" if write else "scopes unknown")
    facts.update(rows=[f"{s} {ck}" for s, ck, _ in rows], scope_set=scope_set)
    done = [f"slack-doctor.sh (reads only, at most {SLACK_WAIT:g} s): exit {rc}, {len(rows)} row(s)"
            + (f", first gap: {gaps[0][1]}" if gaps else "")]
    if rc == 0 and rows and not gaps:
        return result("PASS", f"token, scopes and {len(chans)} channel(s) proven (slack-doctor.sh); {scope_set}",
                      done=done, verify=verify, facts=facts)
    if rc == 124:
        return result("GAP", f"slack-doctor.sh did not finish within {SLACK_WAIT:g} s: the Slack API answers slowly or not "
                      "at all from here (network, DNS or a proxy)", verify=verify, done=done, facts=facts, doc=SLACK_DOC)
    if rc == 2 or not rows:
        return result("GAP", f"slack-doctor.sh refused to run: {first_line(err) or first_line(out) or 'exit ' + str(rc)}",
                      verify=verify, done=done, facts=facts, doc=SLACK_DOC)
    _, ck, detail = gaps[0]
    if ck == "token":
        host = [CHECKOUT, "export SLACK_BOT_TOKEN=<the app's Bot User OAuth Token, xoxb->   # in this shell, or in .env.local"] + RESTART
    elif ck in ("scopes", "chat:write") or "missing_scope" in detail or "missing scope" in detail:
        host = ["# in your app's OAuth & Permissions: add the missing bot scope (the manifest beside the skill lists them),",
                "# then Reinstall to Workspace: a scope reaches a token only by the reinstall, and the token is new",
                CHECKOUT, "export SLACK_BOT_TOKEN=<the new xoxb- token>   # in this shell, or in .env.local"] + RESTART
    elif ck == "channels":
        host = [CHECKOUT, SETTINGS, "export SLACK_CHANNELS=<channel id>,<channel id>"] + RESTART[1:]
    else:
        host = [f"# {ck}: invite the bot there (/invite @<your app> in that channel), or fix the id in SLACK_CHANNELS:",
                CHECKOUT, SETTINGS, "export SLACK_CHANNELS=<channel id>,<channel id>"] + RESTART[1:]
    return result("GAP", f"slack-doctor.sh {ck}: {detail}", host=host, verify=verify, done=done, facts=facts, doc=SLACK_DOC)


def github_host(repos):
    return [CHECKOUT, "# a fine-grained token: https://github.com/settings/personal-access-tokens/new",
            "#   Repository access: Only select repositories - " + (", ".join(repos) or "<the repositories the agent works on>"),
            "#   Permissions: Contents read (write to push a branch); Pull requests read and write to open one",
            "export GH_TOKEN=<the token>   # in this shell; never commit it"] + RESTART


# the packs imported on the Knowledge transfer page (docs/manual/memory.md "Moving knowledge between instances"): kept where
# knowledge-transfer.py keeps them and loaded at every start by loglearner-packs.sh (each pack's LogLearner file, into the
# bank INSTINCTS_JSON names; its ledger .installed-packs.json beside the bank, loglearner.pack.INSTALLED_FILE) and by
# knowledge-transfer.py load (its Hindsight documents; its stamp .loaded.json in the kept folder). The same settings and
# defaults as the loaders (loglearner-env.sh, knowledge-transfer.py)
IMPORTED_DIR = ENV.get("KNOWLEDGE_IMPORTED_DIR") or os.path.join(KNOWLEDGE_DIR, "imported")
LOGLEARNER_BANKS = ENV.get("LOGLEARNER_BANKS_DIR") or os.path.join(ENV.get("LOGLEARNER_STATE") or "/wd/loglearner", "banks")
LOGLEARNER_BANK = ENV.get("INSTINCTS_JSON") or os.path.join(LOGLEARNER_BANKS, "global", "instincts.jsonl")
INSTALLED_LEDGER = os.path.join(os.path.dirname(LOGLEARNER_BANK), ".installed-packs.json")
LOADED_STAMP = os.path.join(IMPORTED_DIR, ".loaded.json")
LOAD_INSIDE = ["/agent/loglearner-packs.sh   # the kept packs' LogLearner files into the bank (a pack already in it is a no-op)",
               "python3 /agent/knowledge-transfer.py load   # their Hindsight documents into the memory API "
               "(a start logs this to " + os.path.join(UI_DIR, "knowledge-load.log") + ")"]
IMPORTED_DOC = "docs/manual/memory.md \"Moving knowledge between instances\" (kept packs, loaded at every start); docs/knowledge-sharing.md"


def package_dirs():
    """The cloned shared knowledge packages: the directories under KNOWLEDGE_DIR, but the harness's own default copy and
    the imported packs' folder (kept_packs reads that one)."""
    try:
        names = sorted(os.listdir(KNOWLEDGE_DIR))
    except OSError:
        return []
    imported = os.path.realpath(IMPORTED_DIR)
    return [n for n in names if not n.startswith(".") and n != "defaults" and os.path.isdir(os.path.join(KNOWLEDGE_DIR, n))
            and os.path.realpath(os.path.join(KNOWLEDGE_DIR, n)) != imported]


def kept_packs():
    """The imported packs the Knowledge transfer page keeps: [(name, manifest path)] of IMPORTED_DIR's *.manifest.json,
    plain files only (knowledge-transfer.py kept())."""
    try:
        names = sorted(os.listdir(IMPORTED_DIR))
    except OSError:
        return []
    out = []
    for n in names:
        p = os.path.join(IMPORTED_DIR, n)
        if n.endswith(".manifest.json") and not n.startswith(".") and os.path.isfile(p) and not os.path.islink(p):
            out.append((n[:-len(".manifest.json")], p))
    return out


def manifest_files(manifest):
    """The files a kept pack's manifest lists, by store: {"loglearner": entry, "hindsight": entry} (the first of each);
    empty for a manifest no loader would take (one listing neither)."""
    out = {}
    for f in manifest.get("files") if isinstance(manifest.get("files"), list) else []:
        if isinstance(f, dict) and f.get("store") in ("loglearner", "hindsight") and f["store"] not in out:
            out[f["store"]] = f
    return out


def sha_text(value):
    """A sha256 as the ledgers compare it: the lower-case string; '' for anything that is not a string (verify_manifest
    takes a string only), and '' never matches."""
    return value.strip().lower() if isinstance(value, str) else ""


def pack_not_loaded(name, manifest, files, installed, stamp):
    """The stores a kept pack is not loaded in, by the loaders' own ledgers. LogLearner: .installed-packs.json beside the
    bank holds no entry with the manifest's name, version and sha256 (loglearner.pack ingest's no-op test; the sha256 is
    the LogLearner file's: the manifest's own, else that file's entry, as verify_manifest reads it). Hindsight: the
    .loaded.json stamp of the last completed Hindsight load does not hold the pack with its Hindsight file's sha256
    (knowledge-transfer.py load also recounts the bank's documents by id before it skips a pack; the doctor reads the stamp
    only). A sha256 missing on either side never matches. A store the manifest lists no file for is not expected: a pack
    of Hindsight documents alone has no LogLearner half, and the other way round."""
    out = []
    if "loglearner" in files:
        sha = sha_text(manifest.get("sha256")) or sha_text(files["loglearner"].get("sha256"))
        version = str(manifest.get("version"))
        if not sha or not any(isinstance(e, dict) and e.get("name") == name and str(e.get("version")) == version
                              and sha_text(e.get("sha256")) == sha for e in installed):
            out.append("LogLearner")
    if "hindsight" in files:
        want, entry = sha_text(files["hindsight"].get("sha256")), stamp.get(name)
        if not want or not isinstance(entry, dict) or sha_text(entry.get("sha256")) != want:
            out.append("Hindsight")
    return out


def package_repo(name):
    """owner/name of the GitHub repository a package directory was cloned from, or ''."""
    d = os.path.join(KNOWLEDGE_DIR, name)
    if not os.path.isdir(os.path.join(d, ".git")):
        return ""
    rc, out, _ = run(["git", "-C", d, "config", "--get", "remote.origin.url"], 10)
    m = re.search(r"github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$", out.strip()) if rc == 0 else None
    return f"{m.group(1)}/{m.group(2)}" if m else ""


def package_repos():
    return [r for r in (package_repo(n) for n in package_dirs()) if r]


def check_github():
    repos = ([ARGS["repo"]] if ARGS["repo"] else []) + [r for r in package_repos() if r != ARGS["repo"]]
    verify = ["gh auth status   # expect: Logged in to github.com account <you>"]
    verify += [f"gh repo view {shlex.quote(r)} --json nameWithOwner" for r in repos] or ["gh repo view <owner/repo> --json nameWithOwner"]
    verify += ["/agent/doctor.sh --check github"]
    token_set = bool(ENV.get("GH_TOKEN") or ENV.get("GITHUB_TOKEN"))
    rc, out, err = run(["gh", "auth", "status", "--hostname", "github.com"], 25)
    m = re.search(r"Logged in to github\.com (?:account|as) (\S+)", out + "\n" + err)
    facts = {"token": "set" if token_set else "not set", "repos": repos}
    done = ["gh auth status: " + (f"signed in as {m.group(1)}" if m and rc == 0 else "not signed in")]
    if rc != 0 or not m:
        why = (f"GH_TOKEN is set but GitHub refuses it ({first_line(out + chr(10) + err)})" if token_set
               else "no GH_TOKEN reaches the container")
        return result("GAP", f"gh is not signed in: {why}", host=github_host(repos), verify=verify, done=done, facts=facts,
                      doc="docs/manual/install.md \"Setup doctor\"")
    login = m.group(1)
    if not token_set:
        # signed in from gh's own configuration (a gh auth login in this container): not persisted, gone at the restart
        return result("GAP", f"signed in as {login} for this container only: gh's sign-in is lost at the next restart",
                      host=github_host(repos), verify=verify, done=done, facts=dict(facts, login=login),
                      doc="docs/manual/install.md \"Setup doctor\"")
    cannot = []
    for r in repos:
        rc, out, err = run(["gh", "repo", "view", r, "--json", "nameWithOwner"], 25)
        done.append(f"gh repo view {r}: " + ("readable" if rc == 0 else first_line(err) or f"exit {rc}"))
        if rc != 0:
            cannot.append(r)
    facts["login"] = login
    if cannot:
        return result("GAP", f"signed in as {login}, but the token cannot read {', '.join(cannot)}", host=github_host(repos),
                      verify=verify, done=done, facts=facts, doc="docs/manual/install.md \"Setup doctor\"")
    return result("PASS", f"signed in as {login}" + (f"; reads {', '.join(repos)}" if repos else ""), done=done,
                  verify=verify, facts=facts)


MEMORY_API = ENV.get("HINDSIGHT_API") or f"http://127.0.0.1:{ENV.get('UI_PORT_HINDSIGHT_API') or '8888'}"
KNOWN_FACT = ("harness-knowledge", "cross-region inference profile model id prefix", r"inference[- ]profile")
MEMORY_DOC = "docs/manual/memory.md \"Agent memory\" (the default knowledge seed and what an empty memory means)"


def bank_documents(bank):
    status, stats = http("GET", f"{MEMORY_API}/v1/default/banks/{urllib.request.quote(bank, safe=':')}/stats", timeout=10)
    return int((stats or {}).get("total_documents") or 0) if status == 200 and isinstance(stats, dict) else -1


def seed_banks(seed_dir):
    banks = load_json(os.path.join(seed_dir, "banks.json"))
    if isinstance(banks, dict):
        return sorted(banks)
    if isinstance(banks, list):
        return sorted(str(b.get("bank_id") or b.get("id") or b) if isinstance(b, dict) else str(b) for b in banks)
    return []


def check_memory():
    verify = ["/agent/hindsight-seed.sh --status   # expect: seeded, extraction state=complete", "/agent/doctor.sh --check memory"]
    if flag("UI_START") != "true" or flag("UI_HINDSIGHT") != "true":
        return result("GAP", "the memory API is switched off (UI_START or UI_HINDSIGHT is false)",
                      host=[CHECKOUT, SETTINGS, "export UI_START=true", "export UI_HINDSIGHT=true"]
                      + RESTART[1:], verify=verify, doc=MEMORY_DOC)
    status, health = http("GET", f"{MEMORY_API}/health")
    if status != 200 or not isinstance(health, dict) or health.get("status") != "healthy":
        return result("GAP", f"the memory API does not answer (http {status or 'none'} at {MEMORY_API})",
                      inside=["/agent/ui-start.sh   # starts what is not running; the API's log is " + os.path.join(UI_DIR, "hindsight-api.log")],
                      host=[CHECKOUT] + RESTART[1:], verify=verify, doc=MEMORY_DOC)
    if flag("HINDSIGHT_SEED") == "false":
        return result("GAP", "the default knowledge seed is off (HINDSIGHT_SEED=false): the memory starts empty",
                      inside=["/agent/hindsight-seed.sh --force   # posts the default banks now (idempotent ids)"],
                      host=[CHECKOUT, SETTINGS, "export HINDSIGHT_SEED=true   # every start seeds it"] + RESTART[1:],
                      verify=verify, doc=MEMORY_DOC)
    state_file = ENV.get("HINDSIGHT_SEED_STATE") or os.path.join(UI_DIR, "hindsight-seed.state")
    state = {}
    try:
        for line in open(state_file, encoding="utf-8"):
            k, _, v = line.rstrip("\n").partition("=")
            state[k] = v
    except OSError:
        pass
    banks = seed_banks(ENV.get("HINDSIGHT_SEED_DIR") or "/seed") or [KNOWN_FACT[0]]
    docs = {b: bank_documents(b) for b in banks}
    facts = {"seed_state": state.get("state") or "none", "documents": state.get("documents") or "", "banks": docs}
    done = [f"seed state {state_file}: {state.get('state') or 'none'} {state.get('documents') or ''}".rstrip(),
            "bank documents: " + ", ".join(f"{b} {n if n >= 0 else '?'}" for b, n in docs.items())]
    if state.get("state") == "failed":
        return result("GAP", f"the seed's extraction failed: {state.get('reason') or 'see ' + os.path.join(UI_DIR, 'hindsight-seed.log')}",
                      host=["# the memory API extracts with Bedrock: fix what the bedrock check names, then"] + [CHECKOUT] + RESTART[1:],
                      inside=["/agent/hindsight-seed.sh --status"], verify=verify, done=done, facts=facts, doc=MEMORY_DOC)
    missing = [b for b, n in docs.items() if n <= 0]
    if missing and state.get("state") in ("accepted", "extracting"):
        return result("GAP", f"the seed is still being extracted ({state.get('documents') or '?'} documents): nothing to do but wait",
                      inside=["/agent/hindsight-seed.sh --status   # repeat in a few minutes"], verify=verify, done=done,
                      facts=facts, doc=MEMORY_DOC)
    if missing:
        return result("GAP", f"the default banks hold no documents: {', '.join(missing)}",
                      inside=["/agent/hindsight-seed.sh   # posts the default knowledge (idempotent ids)"],
                      host=["# if the seed then fails, the memory API cannot call Bedrock: fix the bedrock check, then"] + [CHECKOUT]
                      + RESTART[1:], verify=verify, done=done, facts=facts, doc=MEMORY_DOC)
    bank, query, pattern = KNOWN_FACT
    status, body = http("POST", f"{MEMORY_API}/v1/default/banks/{bank}/memories/recall", {"query": query}, timeout=20)
    results = (body.get("results") if isinstance(body, dict) else body) if status == 200 else None
    texts = [str(r.get("text") or r.get("content") or "") for r in results or [] if isinstance(r, dict)]
    hit = any(re.search(pattern, t, re.I) for t in texts)
    done.append(f"recall from {bank} '{query}': {len(texts)} record(s), the known fact {'found' if hit else 'not found'}")
    if not hit:
        return result("GAP", f"a known fact of the seed was not recalled from {bank} (http {status or 'none'})",
                      inside=["/agent/hindsight-seed.sh --status", "/agent/hindsight-seed.sh --force   # re-posts; stable ids update in place"],
                      host=["# if the extraction keeps failing, fix the bedrock check, then"] + [CHECKOUT] + RESTART[1:],
                      verify=verify, done=done, facts=facts, doc=MEMORY_DOC)
    total = sum(n for n in docs.values() if n > 0)
    return result("PASS", f"{total} documents in {len(docs)} banks, a known fact recalled (seed {state.get('state') or 'loaded'})",
                  done=done, verify=verify, facts=facts)


def check_packages():
    """The shared knowledge packages: the repositories cloned under KNOWLEDGE_DIR (their seed banks hold documents, the
    agent's CLAUDE.md says where each is) and the packs imported on the Knowledge transfer page, each read as loaded from
    the two loaders' ledgers; a kept pack that is not loaded gets the load commands, never the CLAUDE.md remedy."""
    verify = ["/agent/doctor.sh --check packages"]
    names, kept = package_dirs(), kept_packs()
    claude_md = ""
    try:
        claude_md = open(os.path.join(os.path.dirname(KNOWLEDGE_DIR.rstrip("/")) or "/", "CLAUDE.md"), encoding="utf-8").read()
    except OSError:
        pass
    if not names and not kept:
        return result("GAP", f"no shared knowledge package loaded (none under {KNOWLEDGE_DIR}, none kept in {IMPORTED_DIR})",
                      inside=["# none to load: /agent/doctor.sh --not-needed packages",
                              f"gh repo clone <owner>/<package> {shlex.quote(KNOWLEDGE_DIR)}/<package>   # needs the github check to pass",
                              "# then the package's own INSTRUCTIONS.md steps, run inside the container (the harness-setup skill walks them)",
                              "# or import a pack another harness exported, on the Knowledge transfer page (the Memory tile links it): "
                              f"kept in {IMPORTED_DIR} and loaded at every start"],
                      host=["# the package is a private repository: name it in the GitHub token's repository access (the github check),"]
                      + github_host(["<owner>/<package>"])[1:],
                      verify=verify, doc="the package's INSTRUCTIONS.md; " + IMPORTED_DOC)
    rows, gaps, inside = [], [], []
    for n in names:
        d = os.path.join(KNOWLEDGE_DIR, n)
        banks = seed_banks(os.path.join(d, "seeds"))
        empty = [b for b in banks if bank_documents(b) <= 0]
        told = d in claude_md
        rows.append(f"{n} ({len(banks)} bank(s){', ' + str(len(empty)) + ' empty' if empty else ''}{'' if told else ', not in CLAUDE.md'})")
        if empty:
            gaps.append(f"{n}: bank(s) without documents: {', '.join(empty[:4])}{' ...' if len(empty) > 4 else ''}")
            inside.append(f"HINDSIGHT_SEED_DIR={shlex.quote(os.path.join(d, 'seeds'))} "
                          f"HINDSIGHT_SEED_STAMP={shlex.quote(f'/wd/hindsight-seed-{n}.stamp')} /agent/hindsight-seed.sh")
        if not told:
            gaps.append(f"{n}: the agent is not told where it is")
            inside.append(f"# add the package's CLAUDE.md block (its INSTRUCTIONS.md) to {os.path.join(os.path.dirname(KNOWLEDGE_DIR.rstrip('/')), 'CLAUDE.md')}")
    repo_rows = list(rows)
    installed, stamp = load_json(INSTALLED_LEDGER), load_json(LOADED_STAMP)
    installed = installed if isinstance(installed, list) else []
    stamp = stamp if isinstance(stamp, dict) else {}
    memory_off = flag("UI_START") != "true" or flag("UI_HINDSIGHT") != "true"   # startup.sh runs no Hindsight load then
    imported, unloaded = [], False
    for n, p in kept:
        m = load_json(p)
        files = manifest_files(m) if isinstance(m, dict) else {}
        if not files:   # no loader takes a manifest that is not a JSON object or lists no file: never "loaded"
            why = "cannot be read as a JSON object" if not isinstance(m, dict) else "lists no LogLearner or Hindsight file"
            rows.append(f"imported {n} (its manifest {why})")
            gaps.append(f"imported {n}: its manifest {p} {why}")
            inside.append(f"# {p} {why}: import the pack again on the Knowledge transfer page, or remove the file")
            imported.append({"name": n, "error": f"the manifest {why}"})
            continue
        missing = pack_not_loaded(n, m, files, installed, stamp)
        version = str(m.get("version") or "?")
        records = m.get("records") if isinstance(m.get("records"), int) and not isinstance(m.get("records"), bool) else None
        state = "loaded" if not missing else "not loaded in " + " and ".join(missing)
        rows.append(f"imported {n} {version} ({records if records is not None else '?'} records, {state})")
        imported.append({"name": n, "version": version, "records": records, "loaded": not missing})
        if missing:
            unloaded = True
            why = " (the memory API is off: the memory check names the setting)" if "Hindsight" in missing and memory_off else ""
            gaps.append(f"imported {n} {version}: {state}{why}")
    host = []
    if unloaded:
        inside += LOAD_INSIDE
        host = ["# or a restart: it runs the LogLearner loader, and the Hindsight load while the memory API is on",
                CHECKOUT] + RESTART[1:]
    facts = {"packages": rows, "repos": package_repos(), "imported": imported}
    done = [f"cloned under {KNOWLEDGE_DIR}: " + (", ".join(repo_rows) or "none"),
            f"kept in {IMPORTED_DIR}: " + (", ".join(rows[len(repo_rows):]) or "none")
            + (f" (ledgers: {INSTALLED_LEDGER}, {LOADED_STAMP})" if kept else "")]
    doc = "; ".join(d for d, on in (("the package's INSTRUCTIONS.md", names), (IMPORTED_DOC, kept)) if on)
    if gaps:
        return result("GAP", "; ".join(gaps), inside=inside, host=host, verify=verify, done=done, facts=facts, doc=doc)
    return result("PASS", f"{len(rows)} package(s): " + ", ".join(rows), done=done, verify=verify, facts=facts)


UI_FLAGS = (("UI_HEADLAMP", "Headlamp"), ("UI_HINDSIGHT", "Memory"), ("UI_VIBE_KANBAN", "Goals board and Agent workspaces"),
            ("UI_PLANE", "Project board (Plane)"), ("UI_TMUX", "tmux terminal"), ("UI_CLAUDE_MEM", "Session memory"),
            ("UI_LOGLEARNER", "Session insights"), ("COMMS_UI_ENABLED", "Conversations"))
# the optional components, OFF by default - their tiles are absent while off, not greyed, so an off one is never a gap:
# the flag -> how to turn it on. docs/manual/boards.md "Plane board": Plane community edition is AGPL-3.0, so nothing of it is pulled,
# started or shown unless a person accepts that license and opts in
UI_OPT_IN = {"UI_PLANE": "the Plane board (AGPL-3.0): export UI_PLANE=true in .env.local, then ./build.sh and ./stop.sh && ./run.sh (docs/manual/boards.md \"Plane board\")"}


SPOKES_REGISTRY = ENV.get("SPOKES_REGISTRY") or "/agent/spokes/registry.json"
# the home page's sentence, word for word, so /setup and the page say the same
SPOKE_OFF = "To turn one off, set SPOKE_<NAME>=false in .env.local, then ./stop.sh && ./run.sh."


JSON_KINDS = {list: "array", str: "string", int: "number", float: "number", bool: "boolean", type(None): "null"}


def registry_spokes():
    """The agent stack's registry as the supervisor reads it, or None without one: (spokes, problems, read), read false
    when the supervisor cannot read it at all. A spoke is (name, flag, on, the settings it waits for, what they are, what
    is wrong with its entry, its flag as written), on as spoke.sh decides it: its flag when the environment sets it,
    exactly "true" meaning on, its "enabled": true otherwise. Each problem is a gap: spoke.sh reads only version 1 with a
    sessions list, and spoke.sh check refuses a registry that lists no spoke, an entry that is not an object, a spoke
    whose flag is not SPOKE_<NAME> and a requires that is not a list of environment variable names."""
    if not os.path.isfile(SPOKES_REGISTRY):
        return None
    where = f"the spoke registry {SPOKES_REGISTRY}"
    try:
        with open(SPOKES_REGISTRY, encoding="utf-8") as f:
            reg = json.load(f)
    except OSError as e:
        return [], [f"the supervisor cannot read {where}: reading it fails ({e.strerror or e})"], False
    except (ValueError, RecursionError) as e:
        return [], [f"the supervisor cannot read {where}: it does not parse ({e})"], False
    if not isinstance(reg, dict):
        kind = JSON_KINDS.get(type(reg), type(reg).__name__)
        return [], [f"the supervisor cannot read {where}: it is a JSON {kind}, not an object with a sessions list"], False
    if not isinstance(reg.get("sessions"), list):
        return [], [f"the supervisor cannot read {where}: it has no sessions list"], False
    if reg.get("version") != 1:
        return [], [f"the supervisor cannot read {where}: its version is {json.dumps(reg.get('version'))}, not 1"], False
    out, problems = [], []
    if any(not isinstance(e, dict) for e in reg["sessions"]):
        problems.append(f"{where} has an entry that is not an object, which spoke.sh check refuses")
    for e in reg["sessions"]:
        if not isinstance(e, dict) or e.get("role") != "spoke" or not e.get("session_name"):
            continue
        name = str(e["session_name"])
        own = e.get("flag")
        fl = own if isinstance(own, str) else ""
        on = ENV[own] == "true" if fl and own in ENV else e.get("enabled") is True
        bads = []
        if not (fl and re.fullmatch(r"SPOKE_[A-Z0-9_]+", fl)):
            bads.append("it has no SPOKE_<NAME> flag" if own is None else f"its flag {own!r} is not SPOKE_<NAME>")
        rq = e.get("requires")
        rq_ok = rq is None or (isinstance(rq, list) and rq and all(
            isinstance(n, str) and re.fullmatch(r"[A-Z_][A-Z0-9_]*", n) for n in rq))
        if not rq_ok:
            bads.append("its requires is not a list of environment variable names")
        bad = ", and ".join(bads) + ", which spoke.sh check refuses" if bads else ""
        missing = [n for n in rq or [] if not ENV.get(n)] if rq_ok else []
        out.append((name, fl, on, missing, str(e.get("requires_what") or "its settings"), bad, own))
    if not out:
        problems.append(f"{where} lists no spoke, which spoke.sh check refuses")
    return out, problems, True


# a registry problem's step: the image carries the registry, so a corrected one comes with the checkout and a build
REGISTRY_FIX = [CHECKOUT, "# the image carries the spoke registry, from Container-Root/agent/spokes/registry.json in the",
                "# checkout: a corrected one comes with git pull and the next build", "git pull && ./build.sh"] + RESTART


def with_registry_fix(host):
    """host lines that also bring a corrected spoke registry: what another gap already set (a tile's setting), the
    registry's build step unless a build is there already, then the one restart"""
    lines = [x for x in host if x not in RESTART] or [CHECKOUT]
    built = any(x.startswith("git pull && ./build.sh") for x in lines)
    return lines + [x for x in REGISTRY_FIX[1:] if x not in RESTART and x not in lines
                    and not (built and x.startswith("git pull && ./build.sh"))] + RESTART


def check_spokes():
    verify = ["/agent/ui-status.sh   # expect: tmux-agent: UP", "/agent/doctor.sh --check spokes"]
    if flag("UI_START") != "true":
        return result("GAP", "every UI is off (UI_START=false), the home page too",
                      host=[CHECKOUT, SETTINGS, "export UI_START=true"] + RESTART[1:],
                      verify=verify, doc="docs/manual/ui.md \"Harness UIs\"")
    off = [(f, label) for f, label in UI_FLAGS if f not in UI_OPT_IN and flag(f) == "false"]
    opt_off = [(f, label) for f, label in UI_FLAGS if f in UI_OPT_IN and flag(f, "false") != "true"]
    facts = {"tiles_off": [f for f, _ in off], "opt_in_off": [f for f, _ in opt_off]}
    reg = registry_spokes()
    spokes = [] if reg is not None else sorted(
        (k[len("SPOKE_"):].lower(), flag(k, "false")) for k in ENV if re.fullmatch(r"SPOKE_[A-Z0-9_]+", k)
        and not k.endswith(("_INTERVAL", "_OPTS")))
    status_bin = ENV.get("UI_STATUS_BIN") or os.path.join(AGENT_DIR, "ui-status.sh")
    rc, out, _ = run([status_bin], 90)
    rows = [x.strip() for x in out.splitlines() if x.startswith("tmux-agent:")]
    row = rows[0] if rows else ""
    note = next((x for x in rows[1:] if "not installed at" in x or "vendored build missing" in x), "")
    done = [f"ui-status.sh: {x}" for x in rows] or ["ui-status.sh: no tmux-agent row"]
    gaps, inside, host = [], [], []
    if flag("UI_TMUX_AGENT") == "false":
        gaps.append("the tmux-agent dashboard is off: its tile is grey (UI_TMUX_AGENT=false)")
        host = [CHECKOUT, SETTINGS, "export UI_TMUX_AGENT=true"] + RESTART[1:]
    elif not row.startswith("tmux-agent: UP") and "not installed at" in note:
        # the default build: from TMUX_AGENT_SRC (the public source) at the first start, which needs the network
        log = os.path.join(UI_DIR, "tmux-agent-install.log")
        gaps.append("the tmux-agent dashboard is not built from its source yet: its dot is red")
        inside += [f"tail -20 {log}   # why the build from TMUX_AGENT_SRC stopped", "/agent/ui-start.sh   # tries the build again"]
        host = ["# the first start builds the dashboard from github.com and registry.npmjs.org: allow both, or serve the",
                "# copy the image carries instead:", CHECKOUT, SETTINGS, "export TMUX_AGENT_SRC=   # empty: the vendored copy"] + RESTART[1:]
    elif not row.startswith("tmux-agent: UP") and "vendored build missing" in note:
        gaps.append("the image's tmux-agent dashboard copy is missing: its dot is red")
        host = [CHECKOUT, "git pull && ./build.sh   # the image carries the copy at /opt/tmux-agent"] + RESTART
    elif not row.startswith("tmux-agent: UP"):
        gaps.append(f"the tmux-agent dashboard is not up: its dot is red ({row[len('tmux-agent: '):] or 'no answer'})")
        inside.append(f"/agent/ui-start.sh   # starts what is not running; the log is {os.path.join(UI_DIR, 'tmux-agent.log')}")
        host = [CHECKOUT] + RESTART[1:]
    live = []
    for name, on in spokes:
        if on != "true":
            continue
        has = run(["tmux", "has-session", "-t", "=" + name], 10)[0] == 0
        live.append(f"{name} {'live' if has else 'no session'}")
        if not has:
            gaps.append(f"the spoke {name} is on (SPOKE_{name.upper()}=true) but has no tmux session")
            starter = os.path.join(AGENT_DIR, "spoke-start.sh")
            inside.append(f"{shlex.quote(starter)} {shlex.quote(name)}" if os.path.isfile(starter) else "# a restart starts the enabled spokes")
            host = host or [CHECKOUT] + RESTART[1:]
    # the spokes the agent stack's registry names, each live, waiting for its settings (the supervisor's WAITING: its
    # session runs, its cycle does not), without a session or off, and how to turn one off
    spoke_host, states = [], {}
    if reg is not None:
        listed, problems, read = reg
        if problems:
            gaps += problems
            host = with_registry_fix(host)
        for name, fl, on, missing, what, bad, fl_raw in listed:
            if bad:
                gaps.append(f"the spoke {name}: {bad}")
                host = with_registry_fix(host)
            if not on:
                states[name] = "off"
                continue
            has = run(["tmux", "has-session", "-t", "=" + name], 10)[0] == 0
            states[name] = (f"waiting for {what}" if missing else "live") if has else "no session"
            if not has:
                why = (f"{fl}{'' if fl in ENV else ' unset: on by default'}" if fl
                       else 'no flag of its own: "enabled": true' if fl_raw is None else f'a flag that is not a name: "enabled": true')
                gaps.append(f"the spoke {name} is on ({why}) but has no tmux session")
                sup = os.path.join(AGENT_DIR, "supervisor.sh")
                line = (f"{shlex.quote(sup)} ensure   # the supervisor starts the enabled spokes" if os.path.isfile(sup)
                        else "# a restart starts the enabled spokes")
                if line not in inside:
                    inside.append(line)
                host = host or [CHECKOUT] + RESTART[1:]
        if listed:
            spoke_host = [f"# {SPOKE_OFF}"]
        if read:
            done.append(f"{SPOKES_REGISTRY}: {len(listed)} spoke(s)")
    facts.update(spokes=states or {n: on for n, on in spokes}, spoke_registry=SPOKES_REGISTRY if reg is not None else "",
                 tmux_agent=row)
    off_note = ("; tiles off by the settings: " + ", ".join(f for f, _ in off)) if off else ""
    off_note += ("; optional, off by default (no tile): " + ", ".join(f"{label} - {UI_OPT_IN[f]}" for f, label in opt_off)) if opt_off else ""
    if states:
        spoke_note = "; spokes: " + ", ".join(f"{n} {s}" for n, s in states.items())
    elif reg is None:
        spoke_note = (("; spokes: " + ", ".join(live)) if live else ("; spokes off: " + ", ".join(n for n, _ in spokes)
                      if spokes else "")) + "; no spoke registry in this image"
    else:
        spoke_note = ""
    if gaps:
        if off:
            host = host or [CHECKOUT]
            host += [f"# optional, to turn a greyed tile on: export {f}=true in .env.local ({label})" for f, label in off]
        return result("GAP", "; ".join(gaps) + spoke_note + off_note, inside=inside, host=(host or [CHECKOUT]) + spoke_host if spoke_host else host,
                      verify=verify, done=done, facts=facts, doc="docs/manual/ui.md \"tmux-agent dashboard\", \"Harness UIs\"")
    return result("PASS", "tmux-agent dashboard UP" + spoke_note + off_note, done=done, verify=verify, facts=facts,
                  note=([SPOKE_OFF] if spoke_host else []) + [
                        "its tile is live on this container's home page; a grey one seen elsewhere is another page:",
                        "a grey tmux-agent tile that says it has no install source is an older image's (on the host: git pull,",
                        "./build.sh, then ./stop.sh && ./run.sh); a tile still 'checking' is a tab from before the last start (reload it)"])

DOCKER_DOC = "docs/manual/agents.md \"Docker agent\""


def check_docker():
    """The docker spoke's build substrate (docs/manual/agents.md "Docker agent"): the BuildKit daemon answers at BUILDKIT_HOST, the
    stack's registry answers /v2/ at BUILD_REGISTRY, and the disk Docker keeps the build cache and the images on has at
    least DOCKER_MIN_FREE_GB free, as this container sees it (its root filesystem). Read-only: one buildctl call, one GET."""
    verify = ["/agent/doctor.sh --check docker", "/agent/image-build.sh list   # the registry's images"]
    addr, reg = ENV.get("BUILDKIT_HOST") or "", ENV.get("BUILD_REGISTRY") or ""
    if flag("SPOKE_DOCKER") == "false":
        return result("GAP", "the docker spoke and its build substrate are off (SPOKE_DOCKER=false): no image can be built in the harness",
                      host=[CHECKOUT, SETTINGS, "export SPOKE_DOCKER=true"] + RESTART[1:], verify=verify, doc=DOCKER_DOC)
    if not addr or not reg:
        return result("GAP", "no build substrate reaches this container (BUILDKIT_HOST and BUILD_REGISTRY are unset): ./run.sh starts it on the docker target",
                      host=[CHECKOUT, "# the BuildKit daemon and the registry run beside the agent on the docker target (TO=docker) with SPOKE_DOCKER=true;",
                            "# ./run.sh says why it started the agent without them",
                            "./docker.sh status   # the two sidecars and whether each answers"] + RESTART,
                      verify=verify, doc=DOCKER_DOC)
    gaps, done, host = [], [], []
    facts = {"buildkit_host": addr, "registry": reg}
    rc, out, err = run(["buildctl", "--addr", addr, "--timeout", "5", "debug", "info"], 20)
    if rc == 0:
        m = re.search(r"BuildKit:\s+\S+\s+(v\S+)", out)
        facts["buildkit"] = m.group(1) if m else ""
        done.append(f"the BuildKit daemon answers at {addr} ({facts['buildkit'] or 'its version not read'})")
    else:
        gaps.append(f"the BuildKit daemon does not answer at {addr} ({first_line(err) or first_line(out) or f'buildctl exited {rc}'})")
        host = [CHECKOUT, "./docker.sh status   # the two sidecars and whether each answers",
                "./docker.sh up       # starts the one that is not running; the agent keeps running"]
        try:
            restrict = open("/proc/sys/kernel/apparmor_restrict_unprivileged_userns", encoding="utf-8").read().strip()
        except OSError:
            restrict = ""
        if restrict == "1":
            host += ["# this host restricts unprivileged user namespaces, which the rootless daemon needs (BuildKit's docs/rootless.md);",
                     "# lifting it is the host owner's decision: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"]
    code, _ = http("GET", f"http://{reg}/v2/")
    if code == 200:
        done.append(f"the registry answers http://{reg}/v2/")
    else:
        gaps.append(f"the registry does not answer http://{reg}/v2/ (HTTP {code or 'none'})")
        host = host or [CHECKOUT, "./docker.sh status   # the two sidecars and whether each answers",
                        "./docker.sh up       # starts the one that is not running; the agent keeps running"]
    try:
        want = float(ENV.get("DOCKER_MIN_FREE_GB") or 20)
    except ValueError:
        want = 20.0
    free = shutil.disk_usage("/").free / 1024 ** 3
    facts.update(free_gb=round(free, 1), min_free_gb=want)
    if free < want:
        gaps.append(f"{free:.1f} GB free where Docker keeps the build cache and the images, under DOCKER_MIN_FREE_GB={want:g}")
        host = (host or [CHECKOUT]) + ["docker system df   # what Docker keeps: images, build cache, volumes",
                                       "# free disk there, or set DOCKER_MIN_FREE_GB in .env.local if a smaller headroom is enough"]
    else:
        done.append(f"{free:.1f} GB free where Docker keeps the build cache and the images (threshold {want:g} GB)")
    if gaps:
        return result("GAP", "; ".join(gaps), host=host, verify=verify, done=done, facts=facts, doc=DOCKER_DOC)
    return result("PASS", f"BuildKit {facts.get('buildkit') or ''} and the registry {reg} answer; {free:.0f} GB free".replace("  ", " "),
                  done=done, verify=verify, facts=facts)

# --- end of checks ---


CHECKS = {"bedrock": check_bedrock, "git-identity": check_git_identity, "eks": check_eks, "slack": check_slack,
          "github": check_github, "memory": check_memory, "packages": check_packages, "spokes": check_spokes,
          "docker": check_docker}


def not_needed_path():
    return os.path.join(SETUP_DIR, "not-needed")


def write_atomic(path, text):
    """path replaced whole by text, through a temp file of this run's own: two runs at once (the pane and the chat page)
    never write through the same name"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", suffix=".tmp", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main():
    skipped = set()
    try:
        skipped = {line.strip() for line in open(not_needed_path(), encoding="utf-8") if line.strip() in ORDER}
    except OSError:
        pass
    if ARGS["not_needed"] or ARGS["needed"]:
        skipped = (skipped | set(ARGS["not_needed"])) - set(ARGS["needed"])
        write_atomic(not_needed_path(), "".join(i + "\n" for i in ORDER if i in skipped))
    ids = ARGS["check"] or ORDER
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    entries = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(ids)) as pool:
        futures = {i: pool.submit(CHECKS[i]) for i in ids if i not in skipped}
        for i in ids:
            if i in skipped:
                entries[i] = result("SKIP", f"not needed (you said so; /agent/doctor.sh --needed {i} brings it back)")
                continue
            try:
                entries[i] = futures[i].result()
            except Exception as e:  # a check that breaks is a gap in the doctor, never a crash
                entries[i] = result("GAP", f"the check itself failed: {type(e).__name__}: {e}",
                                    verify=[f"/agent/doctor.sh --check {i}"])
    for i, e in entries.items():
        e.update({"id": i, "title": TITLES[i], "checked_at": now})
    merged = dict(entries)
    old = load_json(os.path.join(SETUP_DIR, "doctor.json")) if ARGS["check"] else None
    if isinstance(old, dict):
        for e in old.get("checks") or []:
            if isinstance(e, dict) and e.get("id") in ORDER and e["id"] not in merged:
                merged[e["id"]] = e
    checks = [merged[i] for i in ORDER if i in merged]
    doc = {"version": 1, "time": now, "setup_dir": SETUP_DIR, "checks": checks,
           "summary": {s: sum(1 for c in checks if c["state"] == s) for s in ("PASS", "GAP", "SKIP")}}
    write_atomic(os.path.join(SETUP_DIR, "doctor.json"), mask(json.dumps(doc, indent=1) + "\n"))
    write_atomic(os.path.join(SETUP_DIR, "doctor.txt"), mask(render(checks, now, "full")))
    shown = [entries[i] for i in ids]
    if ARGS["mode"] == "json":
        sys.stdout.write(mask(json.dumps(doc, indent=1) + "\n"))
    else:
        sys.stdout.write(mask(render(shown, now, ARGS["mode"])))
    return 0 if all(e["state"] in ("PASS", "SKIP") for e in shown) else 1


BRIEF_WIDTH = 78  # the agent's tmux pane is 80 columns until a browser attaches; the brief table fits it unwrapped


def clip(text, width):
    """text cut at a word boundary to at most width characters, '...' marking the cut."""
    while len(text) > width and text.endswith(")"):
        depth, i = 0, len(text) - 1
        while i >= 0:  # the parenthesis that opens the trailing group, nested ones included
            depth += {")": 1, "(": -1}.get(text[i], 0)
            if depth == 0:
                break
            i -= 1
        if i <= 0:
            break
        text = text[:i].rstrip()
    if len(text) <= width:
        return text
    return text[:width - 3].rsplit(" ", 1)[0].rstrip(",;:( ") + "..."


def render(checks, now, mode):
    ready = sum(1 for c in checks if c["state"] in ("PASS", "SKIP"))
    todo = [c for c in checks if c["state"] == "GAP"]
    head = f"{ready} of {len(checks)} ready" + (f", {len(todo)} to do" if todo else "")
    if mode == "brief":
        lines = [f"harness doctor: {head}"]
        lines += [f"  {c['id']:<12} {c['state']:<7} {clip(c['found'], BRIEF_WIDTH - 23)}" for c in checks]
        if todo:
            lines.append(f"next: {todo[0]['id']} - /agent/doctor.sh --check {todo[0]['id']} prints its steps")
        return "\n".join(lines) + "\n"
    lines = [f"harness doctor {now}: {head} (details: {os.path.join(SETUP_DIR, 'doctor.txt')}, "
             f"{os.path.join(SETUP_DIR, 'doctor.json')})"]
    for c in checks:
        lines.append(f"  {c['id']:<13} {c['state']:<7} {c['found']}")
    # every gap gets its steps; a check the person asked about by name gets its details even when it passes
    for c in [c for c in checks if c in todo or ARGS["check"]]:
        lines += ["", f"{c['id']}: {c['state']} - {c['found']}"]
        if c["done"]:
            lines += ["  the doctor checked:"] + ["    " + x for x in c["done"]]
        if c["inside"]:
            lines += ["  the agent does now, inside the container:"] + ["    " + x for x in c["inside"]]
        if c["host"]:
            lines += ["  you run on the host:"] + ["    " + x for x in c["host"]]
        if c["pending"]:
            lines += ["  not in this release yet:"] + ["    " + x for x in c["pending"]]
        if c["verify"]:
            lines += ["  verify:"] + ["    " + x for x in c["verify"]]
        if c.get("note"):
            lines += ["  note:"] + ["    " + x for x in c["note"]]
        if c["doc"]:
            lines += ["  more: " + c["doc"]]
    return "\n".join(lines) + "\n"


try:
    sys.exit(main())
except OSError as e:
    print(f"doctor: cannot write under {SETUP_DIR}: {e}", file=sys.stderr)
    sys.exit(1)
PY
