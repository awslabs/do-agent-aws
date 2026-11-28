# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash
# LogLearner runtime layout for the agent-side tools: the PreToolUse hook (/agent/loglearner-hook.sh), the
# seed-pack ingest (/agent/loglearner-packs.sh), /agent/recall.sh and /agent/learn.sh. Sourced, not run.
# The defaults are the ones /agent/loglearner-serve.sh gives the dashboard, so the hook delivers from, recall
# searches, learn writes to and the Learned rules tile counts the SAME bank files. Every value can be
# overridden from the environment (the tests point them at test-local directories).
#
# All state lives under LOGLEARNER_STATE on the /wd volume, so it survives container replacement:
#   banks/global/instincts.jsonl     the global knowledge bank the hook serves (INSTINCTS_JSON)
#   banks/global/.installed-packs.json  which pack bytes are already in it (re-ingesting them is a no-op)
#   output/                          the bandit and exposure ledgers (which session received which rule)

# the vendored runtime (Container-Root/opt/loglearner, VENDORED.md)
LOGLEARNER_DIR=${LOGLEARNER_DIR:-/opt/loglearner}
LOGLEARNER_STATE=${LOGLEARNER_STATE:-/wd/loglearner}
LOGLEARNER_BANKS_DIR=${LOGLEARNER_BANKS_DIR:-${LOGLEARNER_STATE}/banks}
INSTINCTS_JSON=${INSTINCTS_JSON:-${LOGLEARNER_BANKS_DIR}/global/instincts.jsonl}
FLEET_LEARNINGS_DIR=${FLEET_LEARNINGS_DIR:-${LOGLEARNER_BANKS_DIR}}
LOGLEARNER_UCB_DIR=${LOGLEARNER_UCB_DIR:-${LOGLEARNER_STATE}/output}
# the hindsight-api this container serves (recall.sh reads its recall API; loopback only)
UI_PORT_HINDSIGHT_API=${UI_PORT_HINDSIGHT_API:-8888}

export LOGLEARNER_DIR LOGLEARNER_STATE LOGLEARNER_BANKS_DIR INSTINCTS_JSON FLEET_LEARNINGS_DIR LOGLEARNER_UCB_DIR \
	UI_PORT_HINDSIGHT_API
