#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The container agent's Claude Code status line (settings.json "statusLine", set by /agent/claude-settings-sync.sh
# when no status line is configured): one line under the input box,
#   do-agent-aws · <model> · ctx:<N>%
# where N is the share of the context window the session uses, as Claude Code reports it on stdin
# (context_window.used_percentage; 0 until the first reply, when nothing has been sent yet). The tmux-agent
# dashboard reads the "ctx:N%" form as the session's context % (its claude-code profile and the harness lexicon,
# /agent/tmux-agent-lexicon.json, whose idle rule also keys on the "do-agent-aws ·" prefix). Never fails: a bad or
# empty input still prints the line, with ctx:0%.

python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
d = d if isinstance(d, dict) else {}
model = (d.get("model") or {}).get("display_name") or "claude"
pct = (d.get("context_window") or {}).get("used_percentage")
try:
    pct = max(0, min(100, int(round(float(pct)))))
except (TypeError, ValueError):
    pct = 0
print(f"do-agent-aws · {model} · ctx:{pct}%")
' 2> /dev/null || echo "do-agent-aws · claude · ctx:0%"
