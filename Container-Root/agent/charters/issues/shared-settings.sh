#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# issues spoke - its GO gate in every session's Claude Code configuration. Run by startup.sh at every start, before the
# agent tmux session, as board-settings.sh is: Claude Code reads its settings once per session, and the configuration is
# persisted agent state. A person's GO is never a session's act, so permissions.deny of the shared settings gets:
#   Bash(<this directory>/post.sh:*) and Bash(bash <this directory>/post.sh:*)   post.sh, which a person runs at a terminal
#   Edit(/<ISSUES_SPOKE_WD>/outbox/*.GO)                                          the GO files, which are the person's
# Claude Code checks Edit rules for its file tools, the file commands it recognises in Bash and redirect targets. Each
# rule is added once, beside the user's own rules and keys; a file that is not JSON or has a permissions block of
# another shape is left alone with one line. It never fails the start (exit 0).
# Settings (environment): CLAUDE_CONFIG_DIR (default ~/.claude), ISSUES_SPOKE_WD (default /wd/issues).
HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-/home/agent}/.claude}
python3 -I - "${CLAUDE_DIR}/settings.json" "${HERE}" "${ISSUES_SPOKE_WD:-/wd/issues}" << 'PYEOF' || echo "issues shared settings: the GO gate's deny rules were not synced"
import json, os, sys, tempfile
path, here, wd = sys.argv[1:4]
rules = [f"Bash({here}/post.sh:*)", f"Bash(bash {here}/post.sh:*)", "Edit(/%s/outbox/*.GO)" % os.path.normpath(wd)]
try:
    s = json.load(open(path)) if os.path.exists(path) else {}
except ValueError as e:
    print(f"issues shared settings: {path} is not valid JSON, the GO gate's deny rules left it alone ({e})")
    sys.exit(0)
perms = s.setdefault("permissions", {}) if isinstance(s, dict) else None
deny = perms.setdefault("deny", []) if isinstance(perms, dict) else None
if not isinstance(deny, list):
    print(f"issues shared settings: {path} has a permissions block of another shape, the GO gate's deny rules left it alone")
    sys.exit(0)
missing = [r for r in rules if r not in deny]
if not missing:
    print("issues shared settings: the GO gate's deny rules already in place: " + " ".join(rules))
    sys.exit(0)
deny.extend(missing)
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
print("issues shared settings: the GO gate's deny rules added: " + " ".join(missing))
PYEOF
exit 0
