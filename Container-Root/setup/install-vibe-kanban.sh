#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing vibe-kanban ..."

# vibe-kanban (github.com/BloopAI/vibe-kanban) is the task board the agent harness uses
# as its work queue UI. The npm package is a wrapper that fetches the platform binary on
# first launch; warm that fetch at build time so container startup does not depend on it.
export VIBE_KANBAN_VERSION=0.1.44

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Installed into its own prefix, /opt/vibe-kanban, so its package.json can carry an npm override: 0.1.44 (the newest) asks for
# adm-zip ^0.5, and 0.5.x carries CVE-2026-39244 (a crafted archive forces an unbounded allocation; HIGH in the CVE scan,
# docs/manual/supply-chain.md "CVE scan"), fixed in 0.6.0. The launcher loads adm-zip at run time (its bundle keeps it external) and calls
# only new AdmZip(path).extractAllTo(dir, true), which 0.6 keeps as it was
export VIBE_KANBAN_DIR=/opt/vibe-kanban
mkdir -p "${VIBE_KANBAN_DIR}"
cat > "${VIBE_KANBAN_DIR}/package.json" << EOF
{"name": "do-agent-aws-vibe-kanban", "private": true, "dependencies": {"vibe-kanban": "${VIBE_KANBAN_VERSION}"},
 "overrides": {"adm-zip": "0.6.1"}}
EOF
(cd "${VIBE_KANBAN_DIR}" && npm install --omit=dev --no-fund --no-audit --loglevel=error) \
	|| { echo "install-vibe-kanban.sh: FAILED - npm install of vibe-kanban ${VIBE_KANBAN_VERSION} in ${VIBE_KANBAN_DIR}"; exit 1; }
node -p "require('${VIBE_KANBAN_DIR}/node_modules/adm-zip/package.json').version" | grep -qx 0.6.1 \
	|| { echo "install-vibe-kanban.sh: FAILED - the adm-zip override did not take in ${VIBE_KANBAN_DIR}"; exit 1; }

# Make vibe-kanban available to non-interactive shells for headless use
ln -sf "${VIBE_KANBAN_DIR}/node_modules/.bin/vibe-kanban" /usr/local/bin/vibe-kanban

# Warm the platform binary download (non-fatal: the wrapper re-fetches at first
# launch if this step could not complete). The warm-up runner starts with the harness's
# first-start settings (analytics off, /agent/ui-start.sh), so the build sends no usage
# event, and its state is removed afterwards: the image carries no runner settings or
# database, and a container's first start gets the harness's.
VK_DATA=${HOME}/.local/share/vibe-kanban
mkdir -p "${VK_DATA}" && cp /agent/vibe-kanban-config.json "${VK_DATA}/config.json"
HOST=127.0.0.1 PORT=18081 vibe-kanban > /tmp/vibe-kanban-warm.log 2>&1 &
WARM_PID=$!
for i in $(seq 1 45); do
	BIN=$(find ${HOME}/.vibe-kanban/bin -type f -name vibe-kanban 2>/dev/null | head -1)
	[ -n "${BIN}" ] && break
	sleep 2
done
sleep 5
kill ${WARM_PID} 2>/dev/null
pkill -x vibe-kanban 2>/dev/null
sleep 1
rm -rf "${VK_DATA:?}"

if [ -n "${BIN}" ]; then
	echo "vibe-kanban binary warmed: ${BIN}"
else
	echo "WARNING: vibe-kanban binary warm-up did not complete; it will be fetched on first launch"
	cat /tmp/vibe-kanban-warm.log
fi
