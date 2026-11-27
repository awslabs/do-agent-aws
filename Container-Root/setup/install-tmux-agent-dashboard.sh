#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing tmux-agent dashboard (vendored build) ..."

# The tmux-agent web dashboard (github.com/dmvevents/tmux-agent-public, Apache-2.0) is vendored into
# the image as a PREBUILT tree at /opt/tmux-agent (dist/, package.json, package-lock.json, LICENSE,
# NOTICE, README.md; see /opt/tmux-agent/VENDORED.md for the upstream commit and how to refresh
# it), at the commit .env pins as TMUX_AGENT_REF for the first-start build by install-tmux-agent.sh.
# The vendored build is what serves UI_TMUX_AGENT=true offline, with TMUX_AGENT_SRC empty;
# install-tmux-agent.sh builds from TMUX_AGENT_SRC when it is set (see .env).
#
# The `web` verb needs only node builtins; the two runtime dependencies (zod and the MCP SDK) serve
# the MCP bin (dist/mcp/server.js), installed here from the lockfile with the public registry.
# npm lives under nvm in this image (setup/install-nodejs.sh); node itself is /usr/local/bin/node.
export TMUX_AGENT_VENDORED_DIR=${TMUX_AGENT_VENDORED_DIR:-/opt/tmux-agent}

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "${NVM_DIR}/nvm.sh" ] && \. "${NVM_DIR}/nvm.sh" > /dev/null 2>&1

fail()
{
	echo "ERROR: tmux-agent dashboard: $1" >&2
	exit 1
}

[ -f "${TMUX_AGENT_VENDORED_DIR}/dist/bin/tmux-agent.js" ] \
	|| fail "no vendored build at ${TMUX_AGENT_VENDORED_DIR}/dist/bin/tmux-agent.js (Container-Root/opt/tmux-agent is missing from the build context)"
[ -f "${TMUX_AGENT_VENDORED_DIR}/LICENSE" ] && [ -f "${TMUX_AGENT_VENDORED_DIR}/NOTICE" ] \
	|| fail "the vendored tree must carry its LICENSE and NOTICE (Apache-2.0 redistribution)"
[ -f "${TMUX_AGENT_VENDORED_DIR}/package-lock.json" ] || fail "no package-lock.json in ${TMUX_AGENT_VENDORED_DIR}"
command -v npm > /dev/null 2>&1 || fail "npm not found (setup/install-nodejs.sh must run first)"
command -v node > /dev/null 2>&1 || fail "node not found (setup/install-nodejs.sh must run first)"

cd "${TMUX_AGENT_VENDORED_DIR}" || fail "cannot enter ${TMUX_AGENT_VENDORED_DIR}"
# --ignore-scripts: nothing in the lockfile needs a lifecycle script, and a build must not run
# arbitrary install hooks from the registry
npm ci --omit=dev --ignore-scripts --no-fund --no-audit --loglevel=error \
	|| fail "npm ci --omit=dev failed in ${TMUX_AGENT_VENDORED_DIR} (the registry must be reachable at build time)"

# The product must run: the dashboard's own version line is the proof (it reads dist/build.json)
VERSION=$(node "${TMUX_AGENT_VENDORED_DIR}/dist/bin/tmux-agent.js" --version 2>&1)
[ $? -eq 0 ] && [ -n "${VERSION}" ] || fail "node dist/bin/tmux-agent.js --version failed: ${VERSION}"
echo "tmux-agent dashboard: ${VERSION} at ${TMUX_AGENT_VENDORED_DIR}"
