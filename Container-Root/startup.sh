#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Container startup script
# Outbound telemetry off for everything this script starts (/agent/telemetry-off.sh, docs/manual/ui.md "Telemetry")
. /agent/telemetry-off.sh
echo "Container-Root/startup.sh executed"

# Credentials from AWS Secrets Manager (AGENT_SECRETS_ID), before anything below starts a process that reads one: sourced, so
# the tmux server, the UIs, the loop and the watchers all inherit them (/agent/secrets-load.sh, docs/manual/aws.md "Credentials from AWS
# Secrets Manager"). It never fails the start; unset, it only warns about credentials passed as container environment variables
. /agent/secrets-load.sh

# The agent's git identity from .env (GIT_USER_NAME, GIT_USER_EMAIL), before anything below can commit: /agent/git-identity.sh
# writes it as the container's git configuration, or, unset, leaves git refusing a commit with one line naming the two
# variables - never a placeholder author (docs/manual/install.md "Git identity")
/agent/git-identity.sh

# A GitHub token passed as GH_TOKEN or GITHUB_TOKEN (.env GITHUB_ENV_OPTS) also reaches the GitHub plugin, whose MCP
# server reads GITHUB_PERSONAL_ACCESS_TOKEN: exported here, before anything below starts a claude, so the tmux
# session, the loop and the chat responder all inherit it. The value is never written to a file.
if [ -z "${GITHUB_PERSONAL_ACCESS_TOKEN}" ] && [ -n "${GH_TOKEN:-${GITHUB_TOKEN}}" ]; then
	export GITHUB_PERSONAL_ACCESS_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN}}"
fi

# The agent's Claude Code configuration and its LogLearner knowledge bank, FIRST - before the UIs and the agent
# tmux session below start anything that reads them. Claude Code reads its settings once per session and they
# live in the persisted agent state, so /agent/claude-settings-sync.sh re-applies the harness settings to it on
# every start (the LogLearner PreToolUse hook entry per LOGLEARNER_HOOK, the GitHub plugin per the token, the
# harness's own skills and commands - the harness-setup skill behind /setup - ...);
# /agent/loglearner-packs.sh loads
# the /seed banks into the bank that hook delivers from (idempotent, a no-op once loaded). Neither is a UI, so
# neither is gated by UI_START; both are quick, never fail the start, and are described in docs/manual/memory.md
# "Agent learning tools".
/agent/claude-settings-sync.sh
/agent/loglearner-packs.sh

# The agent's board tool in the persisted Claude configuration, before anything below starts a claude session
# (/agent/board-settings.sh; docs/manual/boards.md "Plane board"): the allow rule Bash(/agent/board.sh:*), the deny rules on the
# tool's own files and the goal mirror's, and the tool's usage referenced from the agent's CLAUDE.md. It never fails
# the start
/agent/board-settings.sh
# The issues spoke's GO gate in the same configuration (/agent/charters/issues/shared-settings.sh): every session's deny
# rules refuse post.sh, which a person runs at a terminal, and the GO files, which are the person's. It never fails the
# start
/agent/charters/issues/shared-settings.sh

# A starter repository when the workspace has none: /agent/starter-repo.sh makes /wd/projects/scratch with a
# README and one commit at the first start, so the agent runner has somewhere to work; idempotent, never touching an
# existing repository; STARTER_REPO=false opts out (docs/manual/ui.md "Starter repository"). BEFORE the UIs: ui-start.sh
# launches the runner's registration scan (/agent/vk-runner-repos.sh), which runs as soon as the runner answers and
# registers the repositories it finds then - the starter repository must already be there, or a first start
# registers nothing.
/agent/starter-repo.sh

# Optional harness web UIs (UI_START=true in .env) - see /agent/ui-start.sh and docs/manual/ui.md "Harness UIs".
# Started FIRST, before the shared agent tmux session below, on purpose: the hindsight memory API is
# one of these UIs and it is also what the claude CLI's memory hooks talk to (setup/install-hindsight.sh,
# self-hosted at UI_PORT_HINDSIGHT_API) - the first session's SessionStart hook can only find its
# memory if the API is already coming up, and /agent/tmux-claude.sh waits a bounded time for it.
# The UIs start detached and return at once, so nothing below waits on them; ttyd's attach-or-create
# (`tmux new-session -A`) still joins the session created below on the first browser connect.
if [ "${UI_START}" = "true" ]; then
	echo "Starting harness UIs /agent/ui-start.sh"
	/agent/ui-start.sh
fi

# Default knowledge seed for the hindsight memory (HINDSIGHT_SEED=true in .env, the default): the
# curated banks under /seed are posted once into the self-hosted hindsight-api - idempotent document ids,
# a stamp on the /wd volume, SEED=false opts out - see /agent/hindsight-seed.sh and docs/manual/memory.md
# "Default knowledge seed". Detached: it waits for the API itself and startup never blocks on it.
if [ "${UI_START}" = "true" ] && [ "${UI_HINDSIGHT:-true}" != "false" ] && [ "${HINDSIGHT_SEED:-true}" != "false" ]; then
	echo "Seeding hindsight default knowledge in the background via /agent/hindsight-seed.sh (log ${UI_DIR:-/wd/ui}/hindsight-seed.log)"
	mkdir -p "${UI_DIR:-/wd/ui}" 2>/dev/null
	setsid nohup /agent/hindsight-seed.sh >> "${UI_DIR:-/wd/ui}/hindsight-seed.log" 2>&1 &
else
	echo "Hindsight seed not started (UI_START=${UI_START:-unset} UI_HINDSIGHT=${UI_HINDSIGHT:-unset} HINDSIGHT_SEED=${HINDSIGHT_SEED:-unset})"
fi
# The Hindsight documents of the packs imported on the Knowledge transfer page (KNOWLEDGE_IMPORTED_DIR, docs/manual/memory.md "Moving
# knowledge between instances"; their LogLearner files loaded with the defaults above): /agent/knowledge-transfer.py load posts them
# into the memory API again once it answers - on_conflict=skip, a document a bank already holds stays as it is, and a
# pack its stamp records as in is left alone. Detached like the seed; with no kept pack it ends at once
if [ "${UI_START}" = "true" ] && [ "${UI_HINDSIGHT:-true}" != "false" ]; then
	setsid nohup python3 /agent/knowledge-transfer.py load >> "${UI_DIR:-/wd/ui}/knowledge-load.log" 2>&1 &
fi

# Shared agent tmux session (AGENT_TMUX_SESSION=true in .env, the default) - created eagerly,
# so `docker exec` + `tmux ls` find the agent session from the first second, and ttyd's
# attach-or-create joins THIS session (with claude running in it) instead of creating its
# own on the first browser connect. Deliberately OUTSIDE the UI_START gate: the session must
# exist even with every UI off - see /agent/tmux-session-start.sh and docs/manual/ui.md "tmux in the browser".
if [ "${AGENT_TMUX_SESSION:-true}" = "true" ]; then
	echo "Starting shared agent tmux session via /agent/tmux-session-start.sh"
	/agent/tmux-session-start.sh
fi

# The supervisor (SUPERVISOR=true in .env, the default) - a script that never calls a model: it starts every enabled
# session of the registry (/agent/spokes/registry.json: the spoke agents, SPOKE_<NAME>=true; six spokes ship on, the example off) and
# keeps them and the agent session alive and unstuck (docs/manual/agents.md "Spoke agents", docs/AGENT-STACK.md). After the shared
# session, so the spokes join its tmux server. Deliberately outside the UI_START gate, like the session itself: it runs
# with every UI off. It prints one row per session; SUPERVISOR=false starts nothing.
/agent/supervisor.sh start

# Autonomy loop - started when its autostart gate is on: AUTONOMY_LOOP=true, or auto (the .env
# default) or unset while SLACK_BOT_TOKEN and SLACK_CHANNELS are set (a Slack-connected agent needs
# the loop to watch and reply); false keeps it off. The decision is /agent/slack-gates.sh, shared
# with the loop and Slack scripts - see /agent/loop.sh and docs/manual/autonomy.md "Autonomy loop".
LOOP_GATE=$(/agent/slack-gates.sh | grep '^loop autostart:')
if [ "$(/agent/slack-gates.sh loop)" = "on" ]; then
	echo "Starting autonomy loop via /agent/loop-start.sh (${LOOP_GATE})"
	/agent/loop-start.sh
else
	echo "Autonomy loop not started (${LOOP_GATE})"
fi

# Goal watcher - always running (GOAL_WATCH=false keeps it off): every GOAL_WATCH_INTERVAL seconds (default 120)
# it checks the goals file and, when a new unchecked goal appears while the loop is stopped, runs
# /agent/loop-start.sh. Single instance via its own flock; log /wd/loop/goal-watch.log. See /agent/goal-watch.sh.
if [ "${GOAL_WATCH:-true}" != "false" ] && [ -f /agent/goal-watch.sh ]; then
	echo "Starting goal watcher via /agent/goal-watch.sh (interval ${GOAL_WATCH_INTERVAL:-120}s)"
	# Run through bash so the watcher starts even if the file lost its execute bit in the image.
	nohup bash /agent/goal-watch.sh > /dev/null 2>&1 &
else
	echo "Goal watcher not started (GOAL_WATCH=${GOAL_WATCH:-true})"
fi

# Slack chat responder - started when the chat gate is on: SLACK_CHAT_ENABLED=true, or auto (the
# .env default) or unset while SLACK_BOT_TOKEN and SLACK_CHANNELS are set; false keeps it off.
# Deliberately independent of UI_START and of whether the loop above runs: the responder is how a
# person talks to the agent (status, goals, questions, new goals) while the loop works on the goals
# file - see /agent/slack-chat.sh and docs/manual/channels.md "Slack connectivity".
CHAT_GATE=$(/agent/slack-gates.sh | grep '^chat gate:')
if [ "$(/agent/slack-gates.sh chat)" = "on" ]; then
	echo "Starting Slack chat responder via /agent/slack-chat-start.sh (${CHAT_GATE})"
	/agent/slack-chat-start.sh
else
	echo "Slack chat responder not started (${CHAT_GATE})"
fi

# Optional comms UI - one of the harness UIs, so it is subordinate to the UI_START master
# switch: with UI_START=false nothing UI-related runs (docs/manual/ui.md "Harness UIs"/"Comms UI").
# Enabled per-UI by COMMS_UI_ENABLED=true; served through the home proxy at /comms/.
if [ "${UI_START}" = "true" ] && [ "${COMMS_UI_ENABLED}" = "true" ]; then
	echo "Starting comms UI via /agent/comms-ui-start.sh"
	/agent/comms-ui-start.sh
fi

# Comms real-channel watcher (COMMS_WATCH_ENABLED=true in .env, the default) - deliberately
# independent of the UI_START master switch: a watcher is not a UI (it serves no port and
# renders nothing; it POLLS the configured channels into the journal), so what is collected
# is not gated by what is served - see /agent/comms-watch-start.sh and docs/comms/README.md
# "Connect a real channel". It starts after the comms UI, which generates settings.json on
# the first start; COMMS_WATCH_ENABLED=false (or unset) starts no watcher.
if [ "${COMMS_WATCH_ENABLED}" = "true" ]; then
	echo "Starting comms watcher via /agent/comms-watch-start.sh"
	/agent/comms-watch-start.sh
fi

# Keepalive. Every minute it also checks that the supervisor's last pass is fresh and starts the supervisor again when
# it is not (someone watches the watcher; /agent/supervisor.sh ensure says nothing when all is well)
I=0
while true; do
	date
	[ $((I % 6)) -eq 0 ] && /agent/supervisor.sh ensure
	I=$((I + 1))
	sleep 10
done
