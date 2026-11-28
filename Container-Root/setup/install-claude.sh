#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Usage: install-claude.sh           install claude, check that it runs, link the commands (setup.sh, at image build)
#        install-claude.sh --check   only the check, on the claude already installed: exit 0 when it runs, 1 with why
#
# The claude command is the package's bin/claude.exe: a small stub until the package's postinstall (install.cjs) puts
# the platform-native binary from its optional dependency (@anthropic-ai/claude-code-<platform>) in its place. An
# install whose postinstall did not run (install scripts blocked or ignored) or whose native package did not arrive
# (optional dependencies omitted, a failed download) still exits 0, and the stub only prints "claude native binary not
# installed". So the install is checked: claude --version exits 0 and prints a version, and bin/claude.exe is the
# native binary (an ELF file), not the stub. A failed check installs once more, saying so; a second failure exits 1,
# which setup.sh counts as missing, and the build fails. harden.sh runs --check again after it installs this version
# once more under the pinned npm, the npm claude's own updates use. The version is CLAUDE_CODE_VERSION (a build argument,
# .env; pinned, so every build ships the client this tree was tested with - set it to latest in .env.local for the newest).

claude_works()
{
	CLAUDE_PKG="$(npm root -g)/@anthropic-ai/claude-code"
	CLAUDE_EXE=$(readlink -f "$(command -v claude)" 2> /dev/null)
	CLAUDE_V=$(timeout 60 claude --version 2>&1) && echo "${CLAUDE_V}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' \
		&& [ "$(head -c 4 "${CLAUDE_EXE}" 2> /dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]
}

claude_failed()
{
	NATIVE=$(find "$(npm root -g)/@anthropic-ai" -maxdepth 5 -path '*/claude-code-linux-*/claude' -type f 2> /dev/null | head -1)
	echo "install-claude.sh: FAILED - claude does not run: claude --version said: ${CLAUDE_V}"
	F=${CLAUDE_EXE:-${CLAUDE_PKG}/bin/claude.exe}
	echo "install-claude.sh: claude runs ${F} ($(stat -c '%s bytes' "${F}" 2> /dev/null || echo missing)), not the native binary;" \
		"the platform-native package's binary is ${NATIVE:-not installed}"
	echo "install-claude.sh: npm installs the native binary as an optional dependency and places it with the package's postinstall:"
	echo "install-claude.sh:   no native package - optional dependencies omitted (--omit=optional, omit=optional in an npmrc) or the download failed"
	echo "install-claude.sh:   native package but the stub - install scripts blocked (npm 12 runs only those allow-scripts covers; --ignore-scripts)"
	echo "install-claude.sh: reinstall with: npm install -g --include=optional --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code"
	echo "install-claude.sh: or run the postinstall: node ${CLAUDE_PKG}/install.cjs"
}

if [ "$1" == "--check" ]; then
	claude_works || { claude_failed; exit 1; }
	echo "install-claude.sh: claude ${CLAUDE_V} runs (${CLAUDE_EXE} is the native binary)"
	exit 0
fi

echo ""
echo "Installing Claude Code ..."

CLAUDE_PIN=${CLAUDE_CODE_VERSION:?install-claude.sh: CLAUDE_CODE_VERSION is not set (a build argument, .env)}
npm install -g "@anthropic-ai/claude-code@${CLAUDE_PIN}"
claude_works || {
	echo "install-claude.sh: claude does not run after the install (claude --version: ${CLAUDE_V}) - installing it once more"
	npm install -g "@anthropic-ai/claude-code@${CLAUDE_PIN}"
	claude_works
} || { claude_failed; exit 1; }
echo "install-claude.sh: claude ${CLAUDE_V} runs (${CLAUDE_EXE} is the native binary)"

# Make node, npm, npx and claude available to non-interactive shells for headless use, where nvm's directory is not
# on the PATH: the agent runner (vibe-kanban, /agent/ui-start.sh) starts its coding agents and discovers their
# options with npx (/test20.sh)
ln -sf "$(which node)" /usr/local/bin/node
ln -sf "$(which npm)" /usr/local/bin/npm
ln -sf "$(which npx)" /usr/local/bin/npx
ln -sf "$(which claude)" /usr/local/bin/claude
