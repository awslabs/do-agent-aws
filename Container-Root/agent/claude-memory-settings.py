#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Claude Code's auto-memory setting follows AGENT_MEMORY (docs/manual/memory.md "Agent memory"): autoMemoryEnabled in the agent's
settings.json is true when AGENT_MEMORY is true or unset, false when it is false. Merge-safe: every other key is kept, a
file that is not valid JSON is left alone with a message, a missing file is created with the one key. Run by
/agent/claude-settings-sync.sh at the build and at every start. Usage: claude-memory-settings.py [<settings.json>]
(default CLAUDE_CONFIG_DIR/settings.json, else ~/.claude/settings.json). Prints one line; exit 0 unless the file could
not be written (1) or the argument count is wrong (2).

Why a setting at all: the memory - the MEMORY.md index and the fact files the model writes per working directory and
loads at the start of every session - is on by Claude Code's default, so an unstated default carried it. Stating it in
the persisted settings is what makes an older state, or a changed default, follow the harness's knob."""
import json
import os
import sys
import tempfile


def main(argv):
    if len(argv) > 1:
        print(__doc__.split("\n\n")[0]); return 2
    path = argv[0] if argv else os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"), "settings.json")
    path = os.path.realpath(path)   # a linked settings.json is written through, not replaced by a file
    want = os.environ.get("AGENT_MEMORY", "true").strip().lower() != "false"
    try:
        s = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    except ValueError as e:
        print("claude-memory-settings: %s is not valid JSON, the auto-memory setting left it alone (%s)" % (path, e)); return 0
    except OSError as e:
        print("claude-memory-settings: %s cannot be read, the auto-memory setting left it alone (%s)" % (path, e)); return 0
    if not isinstance(s, dict):
        print("claude-memory-settings: %s is not a JSON object, the auto-memory setting left it alone" % path); return 0
    if s.get("autoMemoryEnabled") is want:
        print("claude-memory-settings: autoMemoryEnabled already %s in %s (AGENT_MEMORY=%s)" % (str(want).lower(), path, os.environ.get("AGENT_MEMORY", "unset"))); return 0
    s["autoMemoryEnabled"] = want
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
        fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path) or ".")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(s, f, indent=2)
            f.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except OSError as e:
        print("claude-memory-settings: could not write %s (%s)" % (path, e)); return 1
    print("claude-memory-settings: autoMemoryEnabled set to %s in %s (AGENT_MEMORY=%s)" % (str(want).lower(), path, os.environ.get("AGENT_MEMORY", "unset"))); return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
