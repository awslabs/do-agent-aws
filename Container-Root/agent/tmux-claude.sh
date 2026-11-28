#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Pane program of the shared agent tmux session (started by /agent/tmux-session-start.sh).
#
# Runs the interactive claude CLI so the session both doors land in (browser /tmux/ and
# docker exec - docs/manual/ui.md "tmux in the browser") is ready to accept prompts, and ALWAYS
# falls back to a shell: if claude exits (e.g. /exit) or is not installed, the pane must
# survive - killing the pane would kill the session the browser UI and every exec shell
# depend on. Claude's own UI (including its authentication prompt on an unconfigured
# container) is shown as-is; nothing here swallows it.
#
# Settings (all overridable via environment; declared in .env):
#   AGENT_TMUX_CLAUDE      - run claude in this pane, true|false (default true); false
#                            drops straight to the shell
#   AGENT_TMUX_CLAUDE_OPTS - extra options for the claude call (word-split on purpose)
#   CLAUDE_BIN             - claude binary (default /usr/local/bin/claude, the symlink
#                            install-claude.sh creates for shells without the login PATH)
#   HINDSIGHT_WAIT_SECS    - how long to wait for the hindsight memory API before starting
#                            claude (default 30; 0 = do not wait). Only when the harness UIs are
#                            on (UI_START=true) and hindsight is among them (UI_HINDSIGHT not
#                            false): the claude session's memory hooks (setup/install-hindsight.sh,
#                            self-hosted at UI_PORT_HINDSIGHT_API) reach the API only if it is
#                            already answering, and hindsight-api needs a few seconds after
#                            startup.sh starts the UIs to open its embedded database. Claude starts
#                            either way when the wait runs out - memory is a convenience, the
#                            agent is the point.
#   AGENT_TMUX_SHELL_FALLBACK - true (default): the pane becomes a shell when claude exits, so the shared session
#                            survives; false: the pane ends with claude, and so does a session that has no other
#                            pane - a spoke's (/agent/tmux-session-start.sh <name>), which /agent/supervisor.sh
#                            starts again

export HOME=${HOME:-/home/agent}
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

AGENT_TMUX_CLAUDE=${AGENT_TMUX_CLAUDE:-true}
CLAUDE_BIN=${CLAUDE_BIN:-/usr/local/bin/claude}
HINDSIGHT_WAIT_SECS=${HINDSIGHT_WAIT_SECS:-30}
AGENT_TMUX_SHELL_FALLBACK=${AGENT_TMUX_SHELL_FALLBACK:-true}
RC=0

# wait_for_memory_api - bounded wait for the self-hosted hindsight-api (see HINDSIGHT_WAIT_SECS above)
wait_for_memory_api()
{
	URL="http://127.0.0.1:${UI_PORT_HINDSIGHT_API:-8888}/health"
	WAITED=0
	while ! curl -sf --max-time 2 "${URL}" 2>/dev/null | grep -q '"healthy"'; do
		if [ "${WAITED}" -ge "${HINDSIGHT_WAIT_SECS}" ]; then
			echo "hindsight memory API not answering at ${URL} after ${HINDSIGHT_WAIT_SECS}s - starting claude anyway (its memory hooks log their own warning)"
			return 1
		fi
		sleep 1
		WAITED=$((WAITED + 1))
	done
	echo "hindsight memory API answering at ${URL} (waited ${WAITED}s)"
}

if [ "${AGENT_TMUX_CLAUDE}" = "true" ]; then
	if [ "${UI_START}" = "true" ] && [ "${UI_HINDSIGHT:-true}" != "false" ] && [ "${HINDSIGHT_WAIT_SECS}" -gt 0 ] 2>/dev/null; then
		wait_for_memory_api
	fi
	if [ -x "${CLAUDE_BIN}" ] || command -v claude > /dev/null; then
		[ -x "${CLAUDE_BIN}" ] || CLAUDE_BIN=$(command -v claude)
		# Job control for this one command: a non-interactive bash keeps a child in its OWN process group, so the
		# pane's foreground process - what tmux reports as pane_current_command, what the Agent chat page and the
		# tmux-agent dashboard read as the pane's command - stayed this script's bash while claude ran, and the
		# chat page refused the harness's own agent pane as a shell. With `set -m` claude gets its own process
		# group and the terminal: it IS the pane's foreground process. The script still takes the pane back when
		# claude exits, so the session survives a /exit as before; a claude suspended with Ctrl-Z is resumed at
		# once (this pane has no job-control shell that could bring it back later).
		set -m
		# the option words are split on spaces but never glob-expanded (as in loop.sh: a rule word is claude's pattern)
		set -f
		"${CLAUDE_BIN}" ${AGENT_TMUX_CLAUDE_OPTS}
		RC=$?
		set +f
		while [ -n "$(jobs -ps)" ]; do fg > /dev/null; done
		set +m
		echo ""
		[ "${AGENT_TMUX_SHELL_FALLBACK}" == "true" ] && echo "claude exited - this pane is now a shell and the session survives; type 'claude' to start it again"
	else
		RC=127
		[ "${AGENT_TMUX_SHELL_FALLBACK}" == "true" ] && echo "claude not found (${CLAUDE_BIN}) - dropping to a shell; set CLAUDE_BIN or run setup/install-claude.sh"
	fi
fi

[ "${AGENT_TMUX_SHELL_FALLBACK}" == "true" ] || exit ${RC}
exec bash
