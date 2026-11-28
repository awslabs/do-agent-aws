#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""stdin to stdout with the secrets masked: the board mirror's rules (kanban-sync.py redact - the values of this process's
secret-named settings, the board login file and the mounted AWS credentials and config, common token shapes, NAME=value
and JSON forms of secret-named settings, bearer tokens), so a text the agent posts to Slack carries no credential it saw.
Used by /agent/slack-post.sh on every message before it is sent. The board login file is KANBAN_AUTH_FILE (default the
kanban.sh login file under /wd); a missing file is skipped."""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("kanban_sync", os.path.join(HERE, "kanban-sync.py"))
_mirror = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mirror)


def main():
    text = sys.stdin.read()
    sys.stdout.write(_mirror.redact(text, os.environ.get("KANBAN_AUTH_FILE", "/wd/kanban/kanban.env")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
