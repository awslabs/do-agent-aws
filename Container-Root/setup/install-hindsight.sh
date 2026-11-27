#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing Hindsight ..."

# Claude Code side of the hindsight long-term memory: the npm installer merges three hooks into
# $CLAUDE_CONFIG_DIR/settings.json (SessionStart / UserPromptSubmit / Stop -> node
# ~/.hindsight/coding-agents/dist/claude-*-hook.js), installs the hindsight-coding-agent skill and
# registers the hindsight MCP server. The server those hooks talk to is the SELF-HOSTED
# hindsight-api this image also serves (setup/install-hindsight-ui.sh, started by /agent/ui-start.sh on
# UI_PORT_HINDSIGHT_API, 8888, behind the home proxy at /memory-api/): ONE memory store - the one the
# Hindsight UI shows, the one /agent/hindsight-seed.sh fills with the default knowledge, and the one
# persisted with the agent state (/home/hindsight/.pg0 on the agent-state mounts, .env). The earlier
# "--server daemon" wiring gave the hooks their own embedded server on :9077: a second store the UI
# never showed and that was lost with the container.
#
# Pinned: the installer is what every build re-fetches from npm, so an unpinned install is a different
# image every day (0.8.1 is the latest at the time of pinning, 2026-10-12).
export HINDSIGHT_CODING_AGENTS_VERSION=${HINDSIGHT_CODING_AGENTS_VERSION:-0.8.1}
# The hooks read this URL from ~/.hindsight/coding-agent.json at every session; the port must be
# the in-container hindsight-api port (PORT_INTERNAL_HINDSIGHT_API in .env, UI_PORT_HINDSIGHT_API
# inside - 8888 unless changed, and a changed port means re-running this installer).
export HINDSIGHT_HOOKS_API_URL=${HINDSIGHT_HOOKS_API_URL:-http://localhost:8888}
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-${HOME}/.claude}

# Self-hosted: the hooks use the hindsight-api served by this container
npx --yes @vectorize-io/hindsight-coding-agents@${HINDSIGHT_CODING_AGENTS_VERSION} install claude-code \
	--server self-hosted --api-url "${HINDSIGHT_HOOKS_API_URL}"
RC=$?
if [ ${RC} -ne 0 ]; then
	echo "install-hindsight.sh: hindsight-coding-agents install FAILED (exit ${RC})" >&2
	exit ${RC}
fi

# Local daemon alternative - NOT used: it gives the hooks a private embedded server on :9077,
# a second memory store that the Hindsight UI never shows and that dies with the container.
#npx --yes @vectorize-io/hindsight-coding-agents install claude-code --server daemon

# What the prompt hook injects. Hindsight's own UserPromptSubmit hook injects, by default (autoInject "reflect"), a
# narrative: the bank's reflect answer to the prompt, a synthesis with no record behind any sentence, under the heading
# of memory - one such narrative told the agent a question's subject was part of the only project the bank knew. The
# config gets autoInject "none" (the hook's tool guide stays), and the harness's own hook, /agent/hindsight-recall-hook.py,
# is registered next to it: the bank's recall RECORDS for the prompt, each with its id, under a header naming the bank.
# The hooks name a session's bank after its git project, outside one after its directory, and a session that runs
# outside any directory (its cwd "/", or none) gets the bank coding-agent::unknown: "/" has no name. The config's bank
# map sends that one to the workspace's bank, coding-agent::wd, so no bank named unknown is created.
# /agent/hindsight-hooks-repair.sh keeps all three in a persisted settings.json and config at every start.
# The session's records are the memory service's extraction from the transcript, which keeps the user's and the agent's
# words and the names of the tools the agent called, never a tool's result: the config's retainContext (the text of
# /agent/hindsight-retain-context.txt) tells the extractor who said what, its retainMetadata verified "false" goes on every
# record of the session (nothing in a transcript was checked), and /agent/hindsight-session-guard.py, registered
# for Stop next to Hindsight's stop hook, checks what was stored (the agent's claims marked as such, records in another
# language or repeated set aside, failed operations logged with their reasons).
RECALL_HOOK=/agent/hindsight-recall-hook.py
GUARD_HOOK=/agent/hindsight-session-guard.py
RETAIN_CONTEXT=/agent/hindsight-retain-context.txt
for F in "${RECALL_HOOK}" "${GUARD_HOOK}" "${RETAIN_CONTEXT}"; do
	[ -f "${F}" ] || { echo "install-hindsight.sh: ${F} is not in the image (Container-Root/agent)" >&2; exit 1; }
done
node - "${CLAUDE_DIR}/settings.json" "${HOME}/.hindsight/coding-agent.json" "${RECALL_HOOK}" "${GUARD_HOOK}" "${RETAIN_CONTEXT}" << 'JS' || exit 1
const fs = require("fs");
const [settingsFile, configFile, recallHook, guardHook, contextFile] = process.argv.slice(2);
const fail = (msg) => { console.error("install-hindsight.sh: " + msg); process.exit(1); };
let settings, config;
try { settings = JSON.parse(fs.readFileSync(settingsFile, "utf8")); } catch (e) { fail(settingsFile + ": " + e.message); }
try { config = JSON.parse(fs.readFileSync(configFile, "utf8")); } catch (e) { fail(configFile + ": " + e.message); }
settings.hooks = settings.hooks || {};
const groups = Array.isArray(settings.hooks.UserPromptSubmit) ? settings.hooks.UserPromptSubmit : (settings.hooks.UserPromptSubmit = []);
if (!groups.some((g) => JSON.stringify(g).includes("/hindsight-recall-hook.py")))
	groups.push({ hooks: [{ type: "command", command: 'python3 "' + recallHook + '"', timeout: 20 }] });
const stops = Array.isArray(settings.hooks.Stop) ? settings.hooks.Stop : (settings.hooks.Stop = []);
if (!stops.some((g) => JSON.stringify(g).includes("/hindsight-session-guard.py")))
	stops.push({ hooks: [{ type: "command", command: 'python3 "' + guardHook + '"', timeout: 30 }] });
fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2) + "\n");
let changed = false;
const context = fs.readFileSync(contextFile, "utf8").trim();
if (!(typeof config.retainContext === "string" && config.retainContext.trim())) { config.retainContext = context; changed = true; }
const meta = config.retainMetadata && typeof config.retainMetadata === "object" && !Array.isArray(config.retainMetadata) ? config.retainMetadata : {};
if (!("verified" in meta)) { config.retainMetadata = { ...meta, verified: "false" }; changed = true; }
if (config.autoInject !== "none") { config.autoInject = "none"; changed = true; }
const banks = config.banks && typeof config.banks === "object" && !Array.isArray(config.banks) ? config.banks : (config.banks = {});
const unknown = banks["coding-agent::unknown"] && typeof banks["coding-agent::unknown"] === "object" ? banks["coding-agent::unknown"] : {};
if (unknown.bank !== "coding-agent::wd") { banks["coding-agent::unknown"] = { ...unknown, bank: "coding-agent::wd" }; changed = true; }
if (changed) fs.writeFileSync(configFile, JSON.stringify(config, null, 2) + "\n");
JS

# Fail loud unless the wiring is what the agent will run with: the three hooks in settings.json
# naming the installed dist plus the recall hook, and the config file pointing the hooks at the
# self-hosted API with no synthesis injected. (node, not python: python3 is installed later in
# setup.sh by install-comms.sh.)
node - "${CLAUDE_DIR}/settings.json" "${HOME}/.hindsight/coding-agent.json" "${HINDSIGHT_HOOKS_API_URL}" << 'JS' || exit 1
const fs = require("fs");
const [settingsFile, configFile, apiUrl] = process.argv.slice(2);
const fail = (msg) => { console.error("install-hindsight.sh: " + msg); process.exit(1); };
let settings, config;
try { settings = JSON.parse(fs.readFileSync(settingsFile, "utf8")); } catch (e) { fail(settingsFile + ": " + e.message); }
try { config = JSON.parse(fs.readFileSync(configFile, "utf8")); } catch (e) { fail(configFile + ": " + e.message); }
const expected = { SessionStart: "claude-sessionstart-hook.js", UserPromptSubmit: "claude-hook.js", Stop: "claude-stop-hook.js" };
for (const [event, entry] of Object.entries(expected)) {
	const commands = JSON.stringify((settings.hooks || {})[event] || []);
	if (!commands.includes("/.hindsight/coding-agents/dist/" + entry))
		fail(settingsFile + " lacks the hindsight " + event + " hook (" + entry + ")");
}
if (!JSON.stringify((settings.hooks || {}).UserPromptSubmit || []).includes("/hindsight-recall-hook.py"))
	fail(settingsFile + " lacks the harness's UserPromptSubmit recall hook (/agent/hindsight-recall-hook.py)");
if (!JSON.stringify((settings.hooks || {}).Stop || []).includes("/hindsight-session-guard.py"))
	fail(settingsFile + " lacks the harness's Stop session guard (/agent/hindsight-session-guard.py)");
if (!(typeof config.retainContext === "string" && config.retainContext.includes("claim")))
	fail(configFile + " has no retainContext naming the source of each fact (/agent/hindsight-retain-context.txt): " + JSON.stringify(config));
if (typeof (config.retainMetadata || {}).verified !== "string")
	fail(configFile + " has no retainMetadata verified flag (every session record says it was not checked): " + JSON.stringify(config));
if (config.serverMode !== "self-hosted" || config.apiUrl !== apiUrl)
	fail(configFile + " is not self-hosted at " + apiUrl + ": " + JSON.stringify(config));
if (config.autoInject !== "none")
	fail(configFile + " does not say autoInject none (the prompt hook would inject a synthesis): " + JSON.stringify(config));
if (((config.banks || {})["coding-agent::unknown"] || {}).bank !== "coding-agent::wd")
	fail(configFile + " does not send a session outside any directory to coding-agent::wd (it would create coding-agent::unknown): " + JSON.stringify(config));
console.log("hindsight hooks: SessionStart/UserPromptSubmit/Stop, the recall hook and the session guard in " + settingsFile + ", self-hosted at " + config.apiUrl + ", autoInject none, coding-agent::unknown -> coding-agent::wd, retainContext set");
JS
