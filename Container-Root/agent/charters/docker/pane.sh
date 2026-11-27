#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# docker spoke - the pane its session runs in (the registry's launch_cmd; tmux-session-start.sh starts it in the spoke's
# working directory). The session builds through /agent/image-build.sh, which pushes only to the stack's registry, so
# before claude starts:
#   1. no registry login in the pane: DOCKER_CONFIG is an empty directory of its own (.docker-config here), so neither
#      buildctl, which hands the client's registry logins to the daemon for a push, nor crane finds a stored one
#   2. the session's own Claude Code settings, .claude/settings.json in this directory, are written at every start from
#      session-settings.json beside this file: deny rules on buildctl and crane called directly (the helper is the
#      session's push path; the rules bind its tools, not the daemon), on other processes' environments and on the
#      spoke's own files
#   3. the hub's permission bypass stays the hub's: --dangerously-skip-permissions, --allow-dangerously-skip-permissions
#      and a bypassPermissions permission mode are dropped from AGENT_TMUX_CLAUDE_OPTS for this session
# Then the harness's launcher, tmux-claude.sh two directories up (AGENT_TMUX_LAUNCHER), runs claude. Without its
# settings the session does not start: one line on stderr, exit 1, and the supervisor reports the session down. The
# rules bind the session's tools, not a sandbox: docs/manual/agents.md "Docker agent" states the limits.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WD="$(pwd)"
export DOCKER_CONFIG="${WD}/.docker-config"
mkdir -p "${DOCKER_CONFIG}" || { echo "docker pane: could not make ${DOCKER_CONFIG}" >&2; exit 1; }
mkdir -p "${WD}/.claude" && python3 -I - "${HERE}/session-settings.json" "${WD}/.claude/settings.json" "${WD}" "${HERE}" << 'PY' \
	|| { echo "docker pane: could not write ${WD}/.claude/settings.json; claude does not start without it" >&2; exit 1; }
import json, os, sys
src, dst, wd, here = sys.argv[1:5]
def sub(x):
    if isinstance(x, str):
        return x.replace("{WORKDIR}", wd).replace("{CHARTER_DIR}", here)
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
