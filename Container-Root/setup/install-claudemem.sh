#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing Claude Mem ..."

# Since claude-mem v13.18.1 (2026-08-31) the installer asks which memory provider to use (CMEM Pro
# or local) and ABORTS when stdin is not a terminal unless the provider is passed explicitly:
#   "Installation Aborted: unknown-install-error ... A provider must be explicit when stdin is not interactive."
# A docker build is never interactive, so without --provider this step aborted before its runtime
# setup (Bun, plugin dependencies) while the plugin itself was still installed by install-plugins.sh,
# and every claude-mem hook then failed in the Claude CLI with "Error: Bun not found".
# --provider claude keeps memory local, on the same Claude credentials the CLI already uses.
#
# The version is pinned: claude-mem publishes several releases a day (13.36.0 to 13.39.0 between 2026-10-12 18:17Z and
# 2026-10-13 21:40Z), and two unpinned builds 20 minutes apart differed - one registered 13.38.0 and cached 13.39.0
# beside it (0.5 GB more, and /agent/ui-start.sh starts the newest cached worker while the hooks were 13.38.0's).
export CLAUDE_MEM_VERSION=13.39.0
npx --yes --quiet "claude-mem@${CLAUDE_MEM_VERSION}" install --provider claude
RC=$?
if [ ${RC} -ne 0 ]; then
	echo "claude-mem install FAILED (exit ${RC})"
	exit ${RC}
fi
# The installer registers its marketplace with autoUpdate on, which lets Claude Code replace the pinned plugin at
# runtime with whatever the marketplace offers then. Off, in the marketplace state Claude Code reads (node: python3
# arrives later in setup.sh)
KNOWN=${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins/known_marketplaces.json
node - "${KNOWN}" << 'JS' || { echo "claude-mem install FAILED: could not turn off the marketplace's autoUpdate in ${KNOWN}"; exit 1; }
const fs = require("fs");
const file = process.argv[2];
const known = JSON.parse(fs.readFileSync(file, "utf8"));
if (!known.thedotmack) { console.error("no thedotmack marketplace in " + file); process.exit(1); }
known.thedotmack.autoUpdate = false;
fs.writeFileSync(file + ".tmp", JSON.stringify(known, null, 2) + "\n");
fs.renameSync(file + ".tmp", file);
JS

# claude-mem appends a "30 Day Free Trial" cloud upsell to the message every session start shows ("View Observations
# Live @ ... 30 Day Free Trial - memory runs off-plan ...", its SessionStart context hook) and to the context banner of
# its user-message hook, and has no setting for either. Until upstream adds one (thedotmack/claude-mem#4768) the two
# calls that append it are taken out of the pinned worker bundle, which the hooks load at every call: each must occur
# exactly once, and the patch is written for one version, so a version bump fails the build here until the patch is
# looked at again instead of silently not applying. test11 check 6b runs both hooks and a planted control.
UPSELL_PATCHED_FOR=13.39.0
WORKER=${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins/cache/thedotmack/claude-mem/${CLAUDE_MEM_VERSION}/scripts/worker-service.cjs
if [ "${CLAUDE_MEM_VERSION}" != "${UPSELL_PATCHED_FOR}" ]; then
	echo "claude-mem install FAILED: the session upsell patch is written for claude-mem ${UPSELL_PATCHED_FOR}, the pin is ${CLAUDE_MEM_VERSION}: check the two calls in its worker bundle (thedotmack/claude-mem#4768), then set UPSELL_PATCHED_FOR"
	exit 1
fi
node - "${WORKER}" << 'JS' || { echo "claude-mem install FAILED: could not take the session upsell out of ${WORKER}"; exit 1; }
const fs = require("fs");
const file = process.argv[2];
let s = fs.readFileSync(file, "utf8");
for (const hook of ["session-start", "context-banner"]) {
	const call = `vg("${hook}")`;
	const n = s.split(call).length - 1;
	if (n !== 1) { console.error(`${call} occurs ${n} times in ${file}, not once`); process.exit(1); }
	s = s.replace(call, `""/*claude-mem upsell removed: ${hook} (thedotmack/claude-mem#4768)*/`);
}
fs.writeFileSync(file + ".tmp", s);
fs.renameSync(file + ".tmp", file);
JS

# Every claude-mem hook in the plugin's hooks.json is the bare command `claude-mem` (the prompt is recorded by
# `claude-mem hook claude-code session-init` on UserPromptSubmit), and the installer places that launcher in
# ~/.local/bin, which only an interactive or a login shell has on PATH (.bashrc and .profile add it). The image's
# PATH - the PATH of docker exec, of startup.sh and of everything it starts (the autonomy loop, the Slack chat
# replies) - does not include it, so every headless session's claude-mem hooks failed with 'Executable not found in
# $PATH: "claude-mem"' and recorded nothing. Make the launcher available to non-interactive shells the way
# install-claude.sh does for node and claude. A link, not a copy: the plugin's SessionStart check compares the real
# path of the claude-mem it finds on PATH with its launcher's and reports any other file as a claude-mem shadowing
# the launcher.
ln -sf "$(which claude-mem)" /usr/local/bin/claude-mem
if ! /usr/local/bin/claude-mem --version > /dev/null 2>&1; then
	echo "claude-mem install FAILED: /usr/local/bin/claude-mem does not run the hook launcher (link to '$(readlink /usr/local/bin/claude-mem)')"
	exit 1
fi
