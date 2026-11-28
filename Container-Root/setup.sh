#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# What is missing at the end of the build: installers below that exited non-zero, and the components the
# check at the end does not find. The build fails if it is not empty (an install script's own exit status alone
# is not enough: a failed step in the middle of a script is followed by more commands, and a Dockerfile RUN of the
# scripts in a row only sees the last script's status).
MISSING=""

if [ -d /etc/apt ]; then
        [ -n "$http_proxy" ] && echo "Acquire::http::proxy \"${http_proxy}\";" > /etc/apt/apt.conf; \
        [ -n "$https_proxy" ] && echo "Acquire::https::proxy \"${https_proxy}\";" >> /etc/apt/apt.conf; \
        [ -f /etc/apt/apt.conf ] && cat /etc/apt/apt.conf
fi

# Install basic tools. python3-yaml and python3-venv are the agent's own: a manifest it writes or checks parses with
# PyYAML, and `python3 -m venv` makes an environment with pip for anything else (test-agent-tools.sh)
apt update
# The base image's packages at their current security and bug-fix updates (the release does not move: jammy stays jammy):
# the ubuntu:22.04 tag lags the archive - its apt 2.4.14 carried CVE-2026-109518 (HIGH in the CVE scan, docs/manual/supply-chain.md "CVE scan")
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade || MISSING="${MISSING} apt-get-upgrade"
apt install -y curl vim unzip sudo python3-yaml python3-venv

/setup/install-nodejs.sh || MISSING="${MISSING} install-nodejs.sh"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

/setup/install-tmux-agent-dashboard.sh || MISSING="${MISSING} install-tmux-agent-dashboard.sh"

/setup/install-claude.sh || MISSING="${MISSING} install-claude.sh"

/setup/install-uv.sh || MISSING="${MISSING} install-uv.sh"
export PATH="$HOME/.local/bin:$PATH"

/setup/install-bun.sh || MISSING="${MISSING} install-bun.sh"

/setup/install-claudemem.sh || MISSING="${MISSING} install-claudemem.sh"

/setup/install-hindsight.sh || MISSING="${MISSING} install-hindsight.sh"

/setup/install-gh.sh || MISSING="${MISSING} install-gh.sh"

/setup/install-aws.sh || MISSING="${MISSING} install-aws.sh"

/setup/install-kubectl.sh || MISSING="${MISSING} install-kubectl.sh"

/setup/install-kubectx.sh || MISSING="${MISSING} install-kubectx.sh"

/setup/install-tmux.sh || MISSING="${MISSING} install-tmux.sh"

/setup/install-plugins.sh || MISSING="${MISSING} install-plugins.sh"

/setup/install-governance.sh || MISSING="${MISSING} install-governance.sh"

/setup/install-crane.sh || MISSING="${MISSING} install-crane.sh"

/setup/install-buildctl.sh || MISSING="${MISSING} install-buildctl.sh"

/setup/install-headlamp.sh || MISSING="${MISSING} install-headlamp.sh"

/setup/install-hindsight-ui.sh || MISSING="${MISSING} install-hindsight-ui.sh"

/setup/install-vibe-kanban.sh || MISSING="${MISSING} install-vibe-kanban.sh"

/setup/install-comms.sh || MISSING="${MISSING} install-comms.sh"

/setup/install-claude-onboarding.sh || MISSING="${MISSING} install-claude-onboarding.sh"

/setup/install-loglearner.sh || MISSING="${MISSING} install-loglearner.sh"

/setup/install-agent-learning.sh || MISSING="${MISSING} install-agent-learning.sh"

/setup/install-ttyd.sh || MISSING="${MISSING} install-ttyd.sh"

/setup/install-nginx.sh || MISSING="${MISSING} install-nginx.sh"

/setup/install-swagger-ui.sh || MISSING="${MISSING} install-swagger-ui.sh"

/setup/install-bashrc.sh || MISSING="${MISSING} install-bashrc.sh"

/setup/harden.sh || MISSING="${MISSING} harden.sh"

# Fail the build when a component the harness relies on is missing, or when one of the installers above
# exited non-zero: the files, the commands, the registrations, the baked memory database and model. The comms
# dashboard is a file check because install-comms.sh exits with its streamlit check, not with its ls of the
# dashboard; the vibe-kanban link too, because command -v alone also finds nvm's copy on this script's PATH.
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-/home/agent/.claude}
for F in /usr/local/bin/claude /usr/local/bin/bun /home/hindsight/.local/bin/hindsight-api \
         /opt/headlamp/headlamp-server /opt/hindsight/control-plane/server.js \
         /opt/tmux-agent/dist/bin/tmux-agent.js /opt/tmux-agent/node_modules/zod/package.json \
         /opt/loglearner/dashboard/app.py /usr/local/bin/loglearner /seed/banks.json \
         /opt/swagger-ui-dist/swagger-ui-bundle.js \
         /opt/comms/scripts/dashboard.py /usr/local/bin/vibe-kanban \
         /home/agent/.hindsight/coding-agents/dist/claude-stop-hook.js /home/agent/.hindsight/coding-agent.json \
         "${CLAUDE_DIR}/settings.json" /home/hindsight/.pg0/instances /home/hindsight/.cache/huggingface/hub \
         "${CLAUDE_DIR}/skills/harness-setup/SKILL.md" "${CLAUDE_DIR}/commands/setup.md"; do
	[ -e "${F}" ] || MISSING="${MISSING} ${F}"
done
for C in node git python3 nginx ttyd tmux kubectl aws gh crane buildctl vibe-kanban; do
	command -v "${C}" > /dev/null 2>&1 || MISSING="${MISSING} cmd:${C}"
done
grep -q claude-mem "${CLAUDE_DIR}/plugins/installed_plugins.json" 2>/dev/null || MISSING="${MISSING} claude-mem"
grep -q claude-stop-hook.js "${CLAUDE_DIR}/settings.json" 2>/dev/null || MISSING="${MISSING} hindsight-hooks-in-settings"
grep -q '"self-hosted"' /home/agent/.hindsight/coding-agent.json 2>/dev/null || MISSING="${MISSING} hindsight-self-hosted"
/opt/comms-venv/bin/python -c 'import streamlit' > /dev/null 2>&1 || MISSING="${MISSING} streamlit"
python3 -c 'import yaml' > /dev/null 2>&1 || MISSING="${MISSING} python3-yaml"
python3 -m venv /tmp/setup-venv-check > /dev/null 2>&1 && /tmp/setup-venv-check/bin/python -m pip --version > /dev/null 2>&1 \
	|| MISSING="${MISSING} python3-venv"
rm -rf /tmp/setup-venv-check
nginx -V 2>&1 | grep -q http_sub_module || MISSING="${MISSING} nginx:http_sub_module"
nginx -V 2>&1 | grep -q http_auth_request_module || MISSING="${MISSING} nginx:http_auth_request_module"
if [ -n "${MISSING}" ]; then
	echo "setup.sh: FAILED - required components missing or failed to install:${MISSING}"
	exit 1
fi
echo "setup.sh: all required components present"
