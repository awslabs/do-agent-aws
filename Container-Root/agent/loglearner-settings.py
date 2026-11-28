#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""LogLearner - register, remove or report the PreToolUse hook entry in Claude Code's settings.json.

Usage: loglearner-settings.py register|unregister|sync|status [--settings FILE]
  register    add the entry when it is missing or differs from the current one (idempotent)
  unregister  remove it when present (idempotent)
  sync        register when LOGLEARNER_HOOK (default true) is true, unregister otherwise - what
              /agent/claude-settings-sync.sh runs at build and before the agent tmux session starts claude,
              because Claude Code reads its hooks once at session start
  status      print whether the current entry is registered; exit 0 when it is, 1 when it is not
  --settings  default ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json

The entry is the one the runtime's START.md documents, widened to Bash and pointed at the harness's
fail-open wrapper:
  hooks.PreToolUse[] += {"matcher": "Edit|Write|Bash",
                         "hooks": [{"type": "command", "command": "/agent/loglearner-hook.sh", "timeout": 10}]}
Only that command's hooks are ever touched: every other key, plugin and hook in the file is kept as it is
(the hindsight memory hooks and the plugins' own registrations included). An older entry for the same
command (another matcher or timeout) is replaced by the current one. A missing file is created for register.
The file is rewritten only when something changed, atomically (temp file + rename in the same directory),
keeping its permission bits.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

COMMAND = "/agent/loglearner-hook.sh"
ENTRY = {"matcher": "Edit|Write|Bash", "hooks": [{"type": "command", "command": COMMAND, "timeout": 10}]}


def ours(hook):
    return isinstance(hook, dict) and hook.get("command") == COMMAND


def groups(settings):
    hooks = settings.get("hooks")
    pre = hooks.get("PreToolUse") if isinstance(hooks, dict) else None
    return pre if isinstance(pre, list) else []


def registered(settings):
    """True only when the CURRENT entry is there exactly once (an outdated matcher or timeout is not)."""
    mine = [(g, h) for g in groups(settings) if isinstance(g, dict) for h in (g.get("hooks") or []) if ours(h)]
    return len(mine) == 1 and mine[0][0].get("matcher") == ENTRY["matcher"] and mine[0][1] == ENTRY["hooks"][0]


def unregister(settings):
    """Drop every hook with our command; drop a group, PreToolUse or hooks key only when it is left empty."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    kept = []
    for g in groups(settings):
        if isinstance(g, dict) and any(ours(h) for h in (g.get("hooks") or [])):
            g = dict(g, hooks=[h for h in g.get("hooks") or [] if not ours(h)])
            if not g["hooks"]:
                continue
        kept.append(g)
    if kept:
        hooks["PreToolUse"] = kept
    else:
        hooks.pop("PreToolUse", None)
    if not hooks:
        del settings["hooks"]


def register(settings):
    if registered(settings):
        return
    unregister(settings)
    if not isinstance(settings.get("hooks"), dict):
        settings["hooks"] = {}
    settings["hooks"].setdefault("PreToolUse", []).append(json.loads(json.dumps(ENTRY)))


def write(path, settings):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=str(path.parent))
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def main(argv):
    args = list(argv)
    path = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "settings.json"
    if "--settings" in args:
        i = args.index("--settings")
        if i + 1 >= len(args):
            args = []
        else:
            path = Path(args[i + 1])
            del args[i:i + 2]
    if len(args) != 1 or args[0] not in ("register", "unregister", "sync", "status"):
        print(__doc__.split("\n\n")[1])
        return 2
    action = args[0]
    flag = os.environ.get("LOGLEARNER_HOOK", "true")
    if action == "sync":
        action = "register" if flag == "true" else "unregister"
    try:
        settings = json.loads(path.read_text()) if path.is_file() else {}
    except (OSError, ValueError) as e:
        print(f"loglearner-hook: settings unreadable, left untouched: {path}: {e}")
        return 2
    if not isinstance(settings, dict):
        print(f"loglearner-hook: settings is not a JSON object, left untouched: {path}")
        return 2
    if action == "status":
        state = "registered" if registered(settings) else "not registered"
        print(f"loglearner-hook: {state} in {path} (LOGLEARNER_HOOK={flag}, matcher {ENTRY['matcher']}, command {COMMAND})")
        return 0 if registered(settings) else 1
    if action == "unregister" and not path.is_file():
        print(f"loglearner-hook: not registered (no {path})")
        return 0
    before = json.dumps(settings, sort_keys=True)
    register(settings) if action == "register" else unregister(settings)
    changed = json.dumps(settings, sort_keys=True) != before
    if changed:
        write(path, settings)
    done = {"register": f"registered for {ENTRY['matcher']}", "unregister": "removed"}[action]
    print(f"loglearner-hook: {done if changed else 'unchanged, already ' + ('registered' if action == 'register' else 'absent')}"
          f" in {path} (LOGLEARNER_HOOK={flag})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
