#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The agent's board tool in the agent's Claude Code configuration (docs/manual/boards.md "Plane board", the board tool).
#
# Run by startup.sh at EVERY start, before the agent tmux session: Claude Code reads its settings once per session, and
# the configuration is persisted agent state (.env AGENT_STATE_VOL_MAP -> wd/agent-state/.claude), which Docker seeds
# from the image only while it is empty - so a state from an image without the tool would never get it otherwise.
# Each step adds what is missing and changes nothing else (the user's own rules, keys and CLAUDE.md lines stay), is
# idempotent, and a step that cannot run prints one line; it never fails the start (exit 0).
#
# Steps:
#   allow  permissions.allow gets Bash(/agent/board.sh:*): every agent session - the tmux pane (auto mode), a loop
#          fire, the Slack responder - runs the board tool without a permission prompt, which a headless call has
#          nobody to answer and the Agent chat page cannot show
#   deny   permissions.deny gets Edit rules on the files the tool runs and the goal mirror keeps: /agent/board.sh,
#          /agent/board.py, /agent/plane-sync.py, /agent/goals-add.sh, the mirror's state file
#          ${AUTONOMY_LOOP_DIR}/plane-sync.state and the board's secrets (the directory of PLANE_AUTH_FILE). The allow
#          rule then never runs code a session wrote, and a direct write to the mirror's files stays refused. Claude
#          Code checks Edit rules for its file tools, for the file commands it recognises in Bash and for redirect
#          targets, in every session
#   usage  agent-rules/AGENT_BOARD.md (which command only tracks work and which gives the loop a goal, and what to
#          leave alone) copied next to CLAUDE.md when the image's copy differs, and referenced from CLAUDE.md once
#          (@AGENT_BOARD.md), the pattern of the agent rules (setup/install-governance.sh)
#
# Settings (environment): CLAUDE_CONFIG_DIR (default ~/.claude), AGENT_RULES_DIR (default /agent-rules),
# AUTONOMY_LOOP_DIR (default /wd/loop), PLANE_AUTH_FILE (default /wd/plane/plane.env).

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-/home/agent}/.claude}
AGENT_RULES_DIR=${AGENT_RULES_DIR:-/agent-rules}
LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}
AUTH_DIR=$(dirname "${PLANE_AUTH_FILE:-/wd/plane/plane.env}")

# allow + deny ("//abs/path": a path from the filesystem root in a permission rule)
mkdir -p "${CLAUDE_DIR}" 2>/dev/null
python3 -I - "${CLAUDE_DIR}/settings.json" "Bash(${AGENT_DIR}/board.sh:*)" \
	"Edit(/${AGENT_DIR}/board.sh)" "Edit(/${AGENT_DIR}/board.py)" "Edit(/${AGENT_DIR}/plane-sync.py)" \
	"Edit(/${AGENT_DIR}/goals-add.sh)" "Edit(/${LOOP_DIR}/plane-sync.state)" "Edit(/${AUTH_DIR}/**)" << 'PYEOF' \
	|| echo "board-settings: the board tool's permission rules were not synced"
import json, os, sys, tempfile
path, allow, deny = sys.argv[1], [sys.argv[2]], sys.argv[3:]
try:
    s = json.load(open(path)) if os.path.exists(path) else {}
except ValueError as e:
    print(f"board-settings: {path} is not valid JSON, the board tool's permission rules left it alone ({e})")
    sys.exit(0)
perms = s.setdefault("permissions", {}) if isinstance(s, dict) else None
lists = [perms.setdefault(k, []) for k in ("allow", "deny")] if isinstance(perms, dict) else []
if len(lists) != 2 or not all(isinstance(l, list) for l in lists):
    print(f"board-settings: {path} has a permissions block of another shape, the board tool's rules left it alone")
    sys.exit(0)
added = []
for rules, have in ((allow, lists[0]), (deny, lists[1])):
    for r in rules:
        if r not in have:
            have.append(r)
            added.append(r)
if not added:
    print("board-settings: the board tool's permission rules are in place")
    sys.exit(0)
mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
print("board-settings: permission rules added to " + path + ": " + " ".join(added))
PYEOF

# usage: the harness owns AGENT_BOARD.md (refreshed when the image's copy differs); CLAUDE.md is the user's
USAGE_SRC=${AGENT_RULES_DIR}/AGENT_BOARD.md
if [ -f "${USAGE_SRC}" ] && [ -d "${CLAUDE_DIR}" ]; then
	if ! cmp -s "${USAGE_SRC}" "${CLAUDE_DIR}/AGENT_BOARD.md"; then
		cp "${USAGE_SRC}" "${CLAUDE_DIR}/AGENT_BOARD.md.tmp" && mv -f "${CLAUDE_DIR:?}/AGENT_BOARD.md.tmp" "${CLAUDE_DIR:?}/AGENT_BOARD.md" \
			&& echo "board-settings: ${CLAUDE_DIR}/AGENT_BOARD.md updated from ${USAGE_SRC}"
	fi
	if ! grep -qxF "@AGENT_BOARD.md" "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null; then
		printf '\n## Boards: track work, or give the autonomy loop a goal\n@AGENT_BOARD.md\n' >> "${CLAUDE_DIR}/CLAUDE.md" \
			&& echo "board-settings: ${CLAUDE_DIR}/CLAUDE.md now references AGENT_BOARD.md"
	fi
else
	echo "board-settings: no ${USAGE_SRC} (or no ${CLAUDE_DIR}) - the board tool's usage was not synced"
fi
exit 0
