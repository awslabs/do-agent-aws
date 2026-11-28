#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing Claude Code Plugins ..."

claude plugin marketplace add anthropics/claude-plugins-official
# oh-my-claudecode is PINNED: its marketplace is a clone of the plugin's repository at OMC_COMMIT, added as a local path, not
# the repository's moving head - three releases in 36 hours (5.8.0 to 5.8.2, 2026-11-08/09) changed the plugin under the build,
# and 5.8.2 arrived without the node_modules tree harden.sh hardens, so the build stopped there. 0564555 is 5.7.31, the release
# the image was last built and tested with (THIRD-PARTY-LICENSES). Move the pin by editing OMC_COMMIT after a build and a
# ./test.sh with the new release; a fetched head that is not the pin fails the build.
export OMC_REPO=https://github.com/Yeachan-Heo/oh-my-claudecode
export OMC_COMMIT=0564555b63dfedd158669c6799d53743abd7d6bf
export OMC_MARKETPLACE_DIR=/opt/claude-marketplaces/oh-my-claudecode
mkdir -p "${OMC_MARKETPLACE_DIR}" && git -C "${OMC_MARKETPLACE_DIR}" init -q \
	&& git -C "${OMC_MARKETPLACE_DIR}" fetch -q --depth 1 "${OMC_REPO}" "${OMC_COMMIT}" \
	&& git -C "${OMC_MARKETPLACE_DIR}" checkout -q --detach FETCH_HEAD \
	&& [ "$(git -C "${OMC_MARKETPLACE_DIR}" rev-parse HEAD)" == "${OMC_COMMIT}" ] \
	|| { echo "install-plugins.sh: FAILED - oh-my-claudecode ${OMC_COMMIT} could not be checked out from ${OMC_REPO}"; exit 1; }
claude plugin marketplace add "${OMC_MARKETPLACE_DIR}"
claude plugin marketplace add thedotmack/claude-mem

for p in superpowers context7 code-review github claude-md-management ralph-loop; do
	echo "Installing plugin: $p ..."
	claude plugin install "$p@claude-plugins-official" -s user -y ;
done

echo "Installing plugin: oh-my-claudecode ..."
claude plugin install oh-my-claudecode@omc

# claude-mem is installed by install-claudemem.sh, pinned (CLAUDE_MEM_VERSION). Not again here: on an installed plugin
# `claude plugin install` refreshes the marketplace and caches the version it offers beside the pinned one, so a
# release published between the two steps landed in the image next to the registered version.

# Settings are MERGED into $CLAUDE_CONFIG_DIR/settings.json, never written over it. Earlier steps of
# setup.sh already own keys in that file - install-hindsight.sh merges the hindsight memory hooks
# (hooks.SessionStart/UserPromptSubmit/Stop) and install-claudemem.sh enables its plugin - and an
# overwrite here silently dropped them: the image built from the overwrite had no `hooks` key at all,
# so no agent session ever wrote to or read from hindsight. The check after the merge fails the build
# if any key present before is missing or a pre-existing `hooks` block changed.
# (node, not python: python3 arrives later in setup.sh, from install-comms.sh.)
SETTINGS=${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json
mkdir -p "$(dirname "${SETTINGS}")"
node - "${SETTINGS}" << 'JS' || exit 1
const fs = require("fs");
const file = process.argv[2];
const fail = (msg) => { console.error("install-plugins.sh: " + msg); process.exit(1); };
let before = {};
if (fs.existsSync(file)) {
	try { before = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { fail(file + " is not valid JSON, refusing to overwrite it: " + e.message); }
}
const after = JSON.parse(JSON.stringify(before));
after.env = Object.assign({}, after.env, { CLAUDE_CODE_USE_BEDROCK: "1", CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "1" });
after.enabledPlugins = Object.assign({}, after.enabledPlugins, {
	"superpowers@claude-plugins-official": true,
	"context7@claude-plugins-official": true,
	"code-review@claude-plugins-official": true,
	"github@claude-plugins-official": true,
	"claude-md-management@claude-plugins-official": true,
	"ralph-loop@claude-plugins-official": true,
	"oh-my-claudecode@omc": true,
	"claude-mem@thedotmack": true
});
fs.writeFileSync(file + ".tmp", JSON.stringify(after, null, 2) + "\n");
fs.renameSync(file + ".tmp", file);
// prove the merge: nothing that was there is gone, and a pre-existing hooks block is byte-identical
const written = JSON.parse(fs.readFileSync(file, "utf8"));
for (const key of Object.keys(before))
	if (!(key in written)) fail("merge lost the settings key '" + key + "'");
if ("hooks" in before && JSON.stringify(before.hooks) !== JSON.stringify(written.hooks))
	fail("merge changed the pre-existing hooks block");
for (const key of Object.keys(before.enabledPlugins || {}))
	if (written.enabledPlugins[key] !== before.enabledPlugins[key]) fail("merge changed enabledPlugins." + key);
console.log("settings merged into " + file + ": keys " + Object.keys(written).join(", ")
	+ (written.hooks ? " (hooks: " + Object.keys(written.hooks).join("/") + ")" : " (no hooks block)"));
JS

# The plugins keep state in the working tree a session runs in: oh-my-claudecode its .omc/, ralph-loop its
# .claude/ralph-loop.local.md, Claude Code its .claude/settings.local.json. Git's per-user excludes file (read when
# no core.excludesFile is set) keeps that state out of every commit made in the container, the agent runner's commit
# of a workspace run (git add -A) included (/test21.sh)
mkdir -p /home/agent/.config/git
cat << 'IGNORE' >> /home/agent/.config/git/ignore
# do-agent-aws: agent state a session writes into a working tree (/setup/install-plugins.sh)
.omc/
.claude/*.local.md
.claude/settings.local.json
IGNORE

# Fail loud unless every plugin asked for above is installed: the list is checked by name (the
# earlier count of '@claude-plugins-official' lines was never >= 7 - six official plugins are
# installed - and only passed because the build ignored this script's exit status).
echo ""
PLUGIN_LIST=$(claude plugin list 2>&1) || { echo "${PLUGIN_LIST}"; echo "install-plugins.sh: claude plugin list failed" >&2; exit 1; }
echo "${PLUGIN_LIST}"
for p in superpowers@claude-plugins-official context7@claude-plugins-official code-review@claude-plugins-official \
         github@claude-plugins-official claude-md-management@claude-plugins-official ralph-loop@claude-plugins-official \
         oh-my-claudecode@omc claude-mem@thedotmack; do
	echo "${PLUGIN_LIST}" | grep -qF "${p}" || { echo "install-plugins.sh: plugin ${p} is not in 'claude plugin list'" >&2; exit 1; }
done
echo "install-plugins.sh: 8 plugins installed"
# claude-mem is the one pinned version and nothing else: the only version in the plugin cache (the worker
# /agent/ui-start.sh starts is the newest one there), the registered one (whose hooks.json the sessions run) and
# CLAUDE_MEM_VERSION are the same, and its marketplace does not update itself
CM_PIN=$(sed -n 's/^export CLAUDE_MEM_VERSION=//p' /setup/install-claudemem.sh 2>/dev/null)
CM_DIR=${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins
CM_CACHED=$(ls "${CM_DIR}/cache/thedotmack/claude-mem" 2>/dev/null | tr '\n' ' ')
CM_REG=$(node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log((d.plugins["claude-mem@thedotmack"] || []).map(x => x.version).join(" "))' "${CM_DIR}/installed_plugins.json" 2>/dev/null)
CM_AUTO=$(node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(String((d.thedotmack || {}).autoUpdate))' "${CM_DIR}/known_marketplaces.json" 2>/dev/null)
if [ -z "${CM_PIN}" ] || [ "${CM_CACHED}" != "${CM_PIN} " ] || [ "${CM_REG}" != "${CM_PIN}" ] || [ "${CM_AUTO}" != "false" ]; then
	echo "install-plugins.sh: claude-mem is not the one pinned version: pinned '${CM_PIN}', cached '${CM_CACHED}', registered '${CM_REG}', marketplace autoUpdate '${CM_AUTO}'" >&2
	exit 1
fi
echo "install-plugins.sh: claude-mem ${CM_PIN} only (cached, registered; marketplace autoUpdate off)"
