#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Seed Claude Code's first-run answers so the agent's tmux pane opens at the prompt.

Usage: claude-onboarding.py [--config FILE] [--dir DIR ...] [--check]
  --config  Claude Code's global config (default ${CLAUDE_CONFIG_DIR:-~/.claude}/.claude.json; the image keeps it
            inside /home/agent/.claude so it persists with the agent state)
  --dir     a folder the interactive agent works in, trusted without the dialog (default /wd, the folder
            /agent/tmux-session-start.sh starts the pane in); repeatable
  --check   change nothing; exit 0 when the answers are all there, 1 when one is missing

On a fresh agent state the interactive claude in the shared tmux session (the browser terminal /tmux/ and
`docker exec` shells) otherwise stops at Claude Code's first-run screens - the theme picker, "Security notes ...
Press Enter to continue" and "Is this a project you created or one you trust? > No, exit / Yes, I trust this
folder" - and three Enters EXIT claude to the bare shell. The answers those screens record are written here:
  hasCompletedOnboarding: true, theme: "dark", projects[<dir>].hasTrustDialogAccepted: true
(the theme only with hasCompletedOnboarding, on a first run: Claude Code removes it after it starts, and a completed
onboarding shows no theme picker without it).
Merge-safe: only a MISSING key is added; a value already there (a user's own theme, a project's other keys) is
never changed; a file that is not valid JSON is left untouched (reported, exit 0). Written only when something
was added, atomically (temp file + rename in the same directory), keeping the file's mode (0600 for a new one).
Run by /agent/claude-settings-sync.sh at image build and at every container start, before the pane starts.
"""
import json
import os
import sys
import tempfile
from pathlib import Path


def main(argv):
    args, dirs, check = list(argv), [], False
    path = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / ".claude.json"
    while args:
        a = args.pop(0)
        if a == "--config" and args:
            path = Path(args.pop(0))
        elif a == "--dir" and args:
            dirs.append(args.pop(0))
        elif a == "--check":
            check = True
        else:
            print(__doc__.split("\n\n")[1])
            return 2
    dirs = dirs or ["/wd"]
    # a .claude.json that is a link (an agent state kept elsewhere) is read and written where it points: the link stays;
    # a link to nothing is left alone (seeding it would create the missing directory and file as root)
    if path.is_symlink():
        try:
            path = path.resolve(strict=True)
        except (OSError, RuntimeError):
            print(f"claude-onboarding: {path} is a link to a file that does not exist - left alone")
            return 0
    try:
        cfg = json.loads(path.read_text()) if path.is_file() else {}
    except (OSError, ValueError) as e:
        print(f"claude-onboarding: {path} is not readable JSON, left untouched ({e})")
        return 0
    if not isinstance(cfg, dict):
        print(f"claude-onboarding: {path} is not a JSON object, left untouched")
        return 0
    added = []
    # The theme answers the first of the first-run screens, so it is part of a FIRST run's answers only: once
    # onboarding is complete Claude Code shows no theme picker without it (measured, v2.1.296) and removes the key
    # from .claude.json after it starts - required on every start it made --check fail and the file be rewritten.
    first_run = "hasCompletedOnboarding" not in cfg
    if first_run:
        cfg["hasCompletedOnboarding"] = True
        added.append("hasCompletedOnboarding")
    if first_run and "theme" not in cfg:
        cfg["theme"] = "dark"
        added.append("theme")
    projects = cfg.get("projects")
    if not isinstance(projects, dict):
        if projects is not None:
            print(f"claude-onboarding: {path} has a non-object 'projects', left as it is")
        else:
            projects = cfg["projects"] = {}
    if isinstance(projects, dict):
        for d in dirs:
            entry = projects.setdefault(d, {})
            if isinstance(entry, dict) and "hasTrustDialogAccepted" not in entry:
                entry["hasTrustDialogAccepted"] = True
                added.append(f"projects[{d}].hasTrustDialogAccepted")
    if check:
        print(f"claude-onboarding: {path}: " + ("missing " + ", ".join(added) if added else "first-run answers present"))
        return 1 if added else 0
    if not added:
        print(f"claude-onboarding: first-run answers already in {path}")
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    fd, tmp = tempfile.mkstemp(prefix=".claude.json.", suffix=".tmp", dir=str(path.parent))
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    print(f"claude-onboarding: added {', '.join(added)} to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
