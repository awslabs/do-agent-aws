#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# install-governance.sh — bake the agent operating rules into the Claude config so every
# headless fire loads them. The rules (agent-rules/AGENT_RULES.md, ADD'd to / by the Dockerfile)
# are generic safety/integrity constraints (verify-before-claim, private-by-default, loopback-only,
# do-not-disturb-others'-work, stage-irreversible-actions, explicit commit identity, record-learnings).
# They outrank any goal in GOALS.md.
#
# Mechanism: copy the rules under $CLAUDE_CONFIG_DIR and reference them from CLAUDE.md, which Claude
# Code reads at the start of every session/fire. Idempotent: safe to re-run (skip-if-present).
set -euo pipefail

echo ""
echo "Installing agent governance rules ..."

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-/home/agent/.claude}"
mkdir -p "${CLAUDE_DIR}"

# The rules file is ADD'd to the image root at /agent-rules/AGENT_RULES.md (see Dockerfile).
SRC=/agent-rules/AGENT_RULES.md
DEST="${CLAUDE_DIR}/AGENT_RULES.md"
if [ ! -f "${SRC}" ]; then
	echo "install-governance.sh: FATAL: ${SRC} not found in image (Dockerfile ADD missing?)" >&2
	exit 1
fi
cp "${SRC}" "${DEST}"
echo "  rules -> ${DEST}"

# Reference the rules from CLAUDE.md so every headless fire loads them (Claude Code reads CLAUDE.md
# at session start). Append idempotently; do not clobber an existing CLAUDE.md.
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"
MARKER="@AGENT_RULES.md"
if ! grep -qF "${MARKER}" "${CLAUDE_MD}" 2>/dev/null; then
	{
		echo ""
		echo "## Agent operating rules (hard constraints — outrank any goal)"
		echo "${MARKER}"
	} >> "${CLAUDE_MD}"
	echo "  referenced rules from ${CLAUDE_MD}"
else
	echo "  ${CLAUDE_MD} already references the rules (skip)"
fi

# What a recalled memory block is. The Hindsight prompt hook injects the bank's recall records for each prompt under a
# header naming the bank and the record ids (/agent/hindsight-recall-hook.py); the agent must read it as an index, not
# as an answer. Appended once, on its own marker; an existing CLAUDE.md keeps everything else.
RECALL_MARKER="## Recalled memory is an index, not an answer"
if ! grep -qF "${RECALL_MARKER}" "${CLAUDE_MD}" 2>/dev/null; then
	{
		echo ""
		echo "${RECALL_MARKER}"
		echo "A \`<hindsight_memory bank=... records=...>\` block is a list of records recalled from that memory bank for your prompt: the"
		echo "header names the bank and the record ids, each line is one record with its id and date. Verify a record before relying on"
		echo "it (the Memory tile, \`/agent/recall.sh\`, or the record itself); do not join records into a story the records do not"
		echo "tell. A statement without a record id is a synthesis, not a memory - say so if you repeat it."
	} >> "${CLAUDE_MD}"
	echo "  recall note appended to ${CLAUDE_MD}"
else
	echo "  ${CLAUDE_MD} already carries the recall note (skip)"
fi

# Fail-loud: prove the rules landed and are referenced, and the recall note is there.
test -f "${DEST}"
grep -qF "${MARKER}" "${CLAUDE_MD}"
grep -qF "${RECALL_MARKER}" "${CLAUDE_MD}"
echo "install-governance.sh complete."
