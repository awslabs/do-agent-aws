#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Configuring bashrc ..."

echo "alias ll='ls -alh --color=auto'" >> ${HOME}/.bashrc
echo "alias k=kubectl" >> ${HOME}/.bashrc

# credentials loaded from AWS Secrets Manager at the start (/agent/secrets-env.sh), before the tmux attach below, so a server
# that an exec shell starts carries them too
echo 'if [ -r /agent/secrets-env.sh ]; then . /agent/secrets-env.sh; fi' >> ${HOME}/.bashrc
echo "/welcome.sh" >> ${HOME}/.bashrc

# Land interactive shells in the shared agent tmux session - the same session the browser
# /tmux/ terminal attaches - so both doors behave the same (docs/manual/ui.md "tmux in the browser").
# Appended after /welcome.sh: the banner is the container's identity, so it shows once
# before the attach; the session's own pane never sources it twice (the pane program is
# /agent/tmux-claude.sh, not a login shell, and the $TMUX guard stops any nesting).
# Guarded against re-runs: duplicate aliases are harmless, but a duplicated attach block
# would re-attach on every detach - the user could never reach a plain shell.
grep -q "TMUX_AUTO_ATTACH" ${HOME}/.bashrc || cat << 'EOF' >> ${HOME}/.bashrc

# Auto-attach to the shared agent tmux session (see /agent/tmux-session-start.sh and
# docs/manual/ui.md "tmux in the browser"). Every guard below is load-bearing:
#   case $- in *i*   - interactive shells only: a non-interactive
#                      `docker exec <container> <command>` must run untouched
#   -t 0 && -t 1     - no pty, no attach (CI/build shells, `bash -ic` without a terminal)
#   -z "$TMUX"       - never nest: the shell inside the session's own pane stays put
#   command -v tmux  - attach only where tmux exists
#   TMUX_AUTO_ATTACH - the escape hatch: `docker exec -e TMUX_AUTO_ATTACH=false -it
#                      do-agent-aws bash` gets a plain shell
#   AGENT_TMUX_SESSION - false turns the shared-session feature off end to end, so the
#                      exec door then behaves exactly as before the feature existed
# Attach-or-create (-A) self-heals a killed session. The attach is deliberately NOT exec'd:
# a detach (Ctrl-b d) returns to this shell instead of ending the docker exec.
case $- in
*i*)
	if [ -t 0 ] && [ -t 1 ] && [ -z "${TMUX}" ] && command -v tmux > /dev/null \
		&& [ "${TMUX_AUTO_ATTACH:-true}" = "true" ] && [ "${AGENT_TMUX_SESSION:-true}" = "true" ]; then
		tmux new-session -A -s "${AGENT_TMUX_SESSION_NAME:-agent}" \
			&& echo "detached from tmux session '${AGENT_TMUX_SESSION_NAME:-agent}' - reattach: tmux attach -t ${AGENT_TMUX_SESSION_NAME:-agent}"
	fi
	;;
esac
EOF

