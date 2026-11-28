#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# issues spoke - the pane its session runs in (the registry's launch_cmd; tmux-session-start.sh starts it in the spoke's
# working directory). The session drafts replies and never posts, so before claude starts:
#   1. no credential in the pane: GH_TOKEN, GITHUB_TOKEN, GITHUB_PERSONAL_ACCESS_TOKEN (the GitHub plugin's), their
#      enterprise forms and the operator token GH_WRITE_OPERATOR_OK are unset here, and gh gets an empty configuration
#      directory (GH_CONFIG_DIR) instead of a stored login. The cycle, which the supervisor starts outside the pane,
#      keeps the token for its reads through the read-only front
#   2. the session's own Claude Code settings, .claude/settings.json in this directory, are written at every start from
#      session-settings.json beside this file: deny rules on the GitHub plugin's tools, a bare gh, curl and wget, post.sh,
#      the GO files, other processes' environments, the spoke's own files, and - so no file tool can reach them - the
#      cycle's gh shim, the gate, gate.log, the private directory (ISSUES_SPOKE_PRIVATE_DIR), the vendored tracker and
#      the agent tree; and session-hook.sh as the PreToolUse hook of Bash, the file-writing tools (Write, Edit,
#      MultiEdit, NotebookEdit) and the GitHub plugin's tools, with the vendored issues tracker's block-gh-write.sh
#      behind it
#   3. the hub's permission bypass stays the hub's: --dangerously-skip-permissions, --allow-dangerously-skip-permissions
#      and a bypassPermissions permission mode are dropped from AGENT_TMUX_CLAUDE_OPTS for this session
# Then the harness's launcher, tmux-claude.sh two directories up (AGENT_TMUX_LAUNCHER), runs claude. Without its
# settings the session does not start: one line on stderr, exit 1, and the supervisor reports the session down.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
unset GH_TOKEN GITHUB_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_WRITE_OPERATOR_OK
WD="$(pwd)"
# gh's own stored login (hosts.yml under ~/.config/gh, after a `gh auth login` in the container) is a credential too: the
# session's gh gets an empty configuration directory of its own
export GH_CONFIG_DIR="${WD}/.gh-config"
mkdir -p "${GH_CONFIG_DIR}" || { echo "issues pane: could not make ${GH_CONFIG_DIR}" >&2; exit 1; }
# the private directory, outside this working directory, where the cycle keeps its gh shim and post.sh its copy; its
# deny rule names it too, so the session cannot write there even if a tool reached outside the working directory
PRIV="${ISSUES_SPOKE_PRIVATE_DIR:-${SUPERVISOR_DIR:-/wd/supervisor}/issues/private}"
mkdir -p "${WD}/.claude" && python3 -I - "${HERE}/session-settings.json" "${WD}/.claude/settings.json" "${WD}" "${HERE}" "${PRIV}" << 'PY' \
	|| { echo "issues pane: could not write ${WD}/.claude/settings.json; claude does not start without it" >&2; exit 1; }
import json, os, sys
src, dst, wd, here, priv = sys.argv[1:6]
def sub(x):
    if isinstance(x, str):
        return x.replace("{WORKDIR}", wd).replace("{CHARTER_DIR}", here).replace("{PRIVATE_DIR}", priv)
    if isinstance(x, list):
        return [sub(i) for i in x]
    if isinstance(x, dict):
        return {k: sub(v) for k, v in x.items()}
    return x
doc = sub(json.load(open(src)))
tmp = dst + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=1)
    f.write("\n")
os.replace(tmp, dst)
PY
# the hub's options, word for word but the permission bypass (split on spaces, never glob-expanded, as tmux-claude.sh does)
set -f
# shellcheck disable=SC2206 # split on purpose: the option words
W=(${AGENT_TMUX_CLAUDE_OPTS:-})
set +f
KEEP=()
SKIP=""
for A in "${W[@]}"; do
	if [ -n "${SKIP}" ]; then
		SKIP=""
		[ "${A}" == "bypassPermissions" ] && continue
		KEEP+=("--permission-mode")
	fi
	case "${A}" in
		--dangerously-skip-permissions|--allow-dangerously-skip-permissions|--permission-mode=bypassPermissions) continue ;;
		--permission-mode) SKIP=1; continue ;;
	esac
	KEEP+=("${A}")
done
[ -n "${SKIP}" ] && KEEP+=("--permission-mode")
export AGENT_TMUX_CLAUDE_OPTS="${KEEP[*]}"
exec "${AGENT_TMUX_LAUNCHER:-${HERE%/*/*}/tmux-claude.sh}"
