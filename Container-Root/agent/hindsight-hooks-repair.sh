#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Hindsight memory hooks - make sure the five Claude Code hooks are registered, that Hindsight's own prompt
# hook injects records, not a synthesis, and that a session write-back tells the extractor who said what.
#
# setup/install-hindsight.sh merges Hindsight's three hooks into $CLAUDE_CONFIG_DIR/settings.json at image build
# (SessionStart / UserPromptSubmit / Stop -> node ~/.hindsight/coding-agents/dist/claude-*-hook.js) and the harness's
# own two next to them: UserPromptSubmit python3 /agent/hindsight-recall-hook.py (the bank's recall RECORDS for the
# prompt, each with its id and provenance, under a header naming the bank) and Stop python3
# /agent/hindsight-session-guard.py (the session records checked where they are stored: the agent's claims marked,
# records in another language or repeated set aside, failed operations logged with their reasons). The config also gets
# a retainContext, the text of /agent/hindsight-retain-context.txt, when it has none of its own: the context Hindsight's
# stop hook sends with a transcript, naming the source of each fact; and retainMetadata verified "false", which the stop
# hook puts on every record of the session. Hindsight's prompt hook injected a narrative by default -
# the bank's reflect answer, no record behind any sentence - so the hooks' config (~/.hindsight/coding-agent.json,
# HINDSIGHT_AGENT_CONF) carries autoInject "none": its tool guide stays, the memory block comes from the recall hook.
# That file is persisted agent state (.env AGENT_STATE_VOL_MAP -> wd/agent-state/.claude), and Docker
# seeds a volume from the image only while it is EMPTY: an agent-state folder first filled by an image
# built before the fix (setup/install-plugins.sh used to overwrite settings.json after the merge, so
# that image carried no hooks at all) keeps its hook-less settings.json through every later image.
# Called by /agent/ui-start.sh with the hindsight API: when the installed hook runtime is there and a
# hook is missing, it is added back exactly as the installer writes it. Existing entries are never
# changed or removed; an unreadable file is reported and left alone. The config (persisted too, so an
# older copy has no autoInject key and means "reflect") gets autoInject "none" when it says otherwise,
# and its bank map sends coding-agent::unknown (the bank of a session outside any directory, cwd "/")
# to coding-agent::wd when it does not; every other key stays. Idempotent.
#
# Settings (environment):
#   CLAUDE_SETTINGS         - the settings file (default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json)
#   HINDSIGHT_HOOKS_DIST    - the installed hook runtime (default $HOME/.hindsight/coding-agents/dist)
#   HINDSIGHT_AGENT_CONF    - the hooks' config to set autoInject "none" and the coding-agent::unknown bank map in;
#                             unset = the config is not touched
#                             (ui-start.sh passes ~/.hindsight/coding-agent.json; a test passes its copy)
#   AGENT_DIR               - where the recall hook lives (default: this script's directory, /agent in the image)
#   HINDSIGHT_HOOKS_REPAIR  - true|false (default true); false = an operator who removed the hooks on
#                             purpose keeps them removed (nothing is checked or written)
# The file keeps its permission bits. Exit 0 whether or not anything was added (one line says
# which); exit 1 only when the settings file cannot be written.

export HOME=${HOME:-/home/agent}
CLAUDE_SETTINGS=${CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json}
HINDSIGHT_HOOKS_DIST=${HINDSIGHT_HOOKS_DIST:-${HOME}/.hindsight/coding-agents/dist}
HINDSIGHT_HOOKS_REPAIR=${HINDSIGHT_HOOKS_REPAIR:-true}
AGENT_DIR=${AGENT_DIR:-$(cd "$(dirname "$0")" && pwd)}
HINDSIGHT_AGENT_CONF=${HINDSIGHT_AGENT_CONF:-}

if [ "${HINDSIGHT_HOOKS_REPAIR}" = "false" ]; then
	echo "hindsight hooks: repair disabled (HINDSIGHT_HOOKS_REPAIR=false) - settings left as they are"
	exit 0
fi

if [ ! -f "${HINDSIGHT_HOOKS_DIST}/claude-hook.js" ]; then
	echo "hindsight hooks: no hook runtime at ${HINDSIGHT_HOOKS_DIST} (setup/install-hindsight.sh installs it) - nothing to register"
	exit 0
fi
if [ ! -f "${CLAUDE_SETTINGS}" ]; then
	echo "hindsight hooks: no ${CLAUDE_SETTINGS} - nothing to repair"
	exit 0
fi
command -v python3 > /dev/null 2>&1 || { echo "hindsight hooks: python3 not found - hooks not checked"; exit 0; }

python3 - "${CLAUDE_SETTINGS}" "${HINDSIGHT_HOOKS_DIST}" "${AGENT_DIR}" "${HINDSIGHT_AGENT_CONF}" << 'EOF'
import json, os, sys

path, dist, agent_dir, conf_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(path, encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError) as e:
    print(f"hindsight hooks: {path} unreadable ({e}) - left alone")
    sys.exit(0)
if not isinstance(settings, dict):
    print(f"hindsight hooks: {path} is not a JSON object - left alone")
    sys.exit(0)

# the installer's own entries (hindsight-coding-agents 0.8.1, claude-code harness), then the harness's recall hook:
# (event, the marks that say the entry is present, the command, its timeout, the name reported)
wanted = [
    ("SessionStart", ("/.hindsight/coding-agents/dist/claude-sessionstart-hook.js", f"{dist}/claude-sessionstart-hook.js"),
     f'node "{dist}/claude-sessionstart-hook.js"', 30, "SessionStart"),
    ("UserPromptSubmit", ("/.hindsight/coding-agents/dist/claude-hook.js", f"{dist}/claude-hook.js"),
     f'node "{dist}/claude-hook.js"', 30, "UserPromptSubmit"),
    ("Stop", ("/.hindsight/coding-agents/dist/claude-stop-hook.js", f"{dist}/claude-stop-hook.js"),
     f'node "{dist}/claude-stop-hook.js"', 60, "Stop"),
    ("UserPromptSubmit", ("/hindsight-recall-hook.py",), f'python3 "{agent_dir}/hindsight-recall-hook.py"', 20, "UserPromptSubmit(recall)"),
    ("Stop", ("/hindsight-session-guard.py",), f'python3 "{agent_dir}/hindsight-session-guard.py"', 30, "Stop(guard)"),
]
hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
    settings["hooks"] = hooks
added = []
for event, present, command, timeout, name in wanted:
    groups = hooks.get(event)
    if not isinstance(groups, list):
        groups = []
        hooks[event] = groups
    if any(any(mark in json.dumps(g) for mark in present) for g in groups):
        continue
    groups.append({"hooks": [{"type": "command", "command": command, "timeout": timeout}]})
    added.append(name)


def write_json(target, data):
    mode = os.stat(target).st_mode & 0o777
    tmp = target + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, target)


# the hooks' config: Hindsight's own prompt hook injects no synthesis; the records come from the recall hook
conf_note = ""
if conf_path:
    try:
        with open(conf_path, encoding="utf-8") as f:
            conf = json.load(f)
    except (OSError, ValueError) as e:
        conf = None
        conf_note = f"; {conf_path} unreadable ({e}) - left alone"
    fixed = []
    if isinstance(conf, dict) and conf.get("autoInject") != "none":
        conf["autoInject"] = "none"
        fixed.append("autoInject none (the memory block is the recall hook's records, no synthesis)")
    if isinstance(conf, dict):
        # a session outside any directory (cwd "/", which has no name) would get the bank coding-agent::unknown
        banks = conf.get("banks") if isinstance(conf.get("banks"), dict) else {}
        unknown = banks.get("coding-agent::unknown") if isinstance(banks.get("coding-agent::unknown"), dict) else {}
        if unknown.get("bank") != "coding-agent::wd":
            banks["coding-agent::unknown"] = {**unknown, "bank": "coding-agent::wd"}
            conf["banks"] = banks
            fixed.append("coding-agent::unknown -> coding-agent::wd (a session outside any directory)")
        # the context a session write-back sends with its transcript: who said what (a config's own wording is kept)
        try:
            with open(os.path.join(agent_dir, "hindsight-retain-context.txt"), encoding="utf-8") as f:
                context = f.read().strip()
        except OSError:
            context = ""
        if context and not str(conf.get("retainContext") or "").strip():
            conf["retainContext"] = context
            fixed.append("retainContext (each fact names its source; the agent's account is its claim)")
        # the flag every session record carries: nothing in a transcript was checked against a tool's result (the stop
        # hook adds the config's retainMetadata to each record's metadata; a config's own value for the key is kept)
        meta = conf.get("retainMetadata") if isinstance(conf.get("retainMetadata"), dict) else {}
        if "verified" not in meta:
            conf["retainMetadata"] = {**meta, "verified": "false"}
            fixed.append("retainMetadata verified=false (a session record is the transcript's account, not checked)")
    if fixed:
        try:
            write_json(conf_path, conf)
            conf_note = f"; {', '.join(fixed)} in {conf_path}"
        except OSError as e:
            print(f"hindsight hooks: cannot write {conf_path}: {e}", file=sys.stderr)
            sys.exit(1)

if not added:
    print(f"hindsight hooks: SessionStart/UserPromptSubmit/Stop, the recall hook and the session guard present in {path}{conf_note}")
    sys.exit(0)
try:
    write_json(path, settings)
except OSError as e:
    print(f"hindsight hooks: cannot write {path}: {e}", file=sys.stderr)
    sys.exit(1)
print(f"hindsight hooks: restored {'/'.join(added)} in {path} (persisted settings from an image that had lost them){conf_note}")
EOF
