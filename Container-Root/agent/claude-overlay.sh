#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The operator's overlay stub (docs/manual/autonomy.md "Parity with a native instance"; AGENT_OVERLAY in .env). The standing instructions
# of a deployment live at /wd/CLAUDE.md - the working directory of every autonomy-loop fire, of the Slack chat responder and
# of the agent's pane, and the parent of every spoke's directory - where Claude Code reads them at the start of each session,
# below the harness's rules. The shape of that file is the shipped example /agent/CLAUDE.md.example
# (docs/parity/CLAUDE.md.example in the checkout). Run by /agent/claude-settings-sync.sh at the build and at every start:
#   AGENT_OVERLAY=true (the default) and OVERLAY_DIR exists and holds no CLAUDE.md -> a short stub is written there saying the
#   overlay is not filled yet and naming the example; a session that reads it knows the state instead of guessing
#   the file exists (the stub, or the operator's own) -> never touched, whatever it holds
#   OVERLAY_DIR does not exist (the image build has no /wd) -> nothing written, one line says so
#   AGENT_OVERLAY=false -> nothing written, one line says so (an existing file stays)
# Settings: AGENT_OVERLAY (true), OVERLAY_DIR (AUTONOMY_LOOP_WORKDIR, else /wd), OVERLAY_EXAMPLE (/agent/CLAUDE.md.example).
# Prints one line; exit 0 always but 1 when the stub could not be written.

AGENT_OVERLAY=${AGENT_OVERLAY:-true}
AGENT_OVERLAY=${AGENT_OVERLAY,,}   # false, False and FALSE are one answer
OVERLAY_DIR=${OVERLAY_DIR:-${AUTONOMY_LOOP_WORKDIR:-/wd}}
OVERLAY_EXAMPLE=${OVERLAY_EXAMPLE:-/agent/CLAUDE.md.example}
TARGET=${OVERLAY_DIR%/}/CLAUDE.md

if [ "${AGENT_OVERLAY}" == "false" ]; then
	echo "claude-overlay: AGENT_OVERLAY=false - no stub written ($([ -e "${TARGET}" ] && echo "${TARGET} stays as it is" || echo "no ${TARGET}"))"
	exit 0
fi
if [ ! -d "${OVERLAY_DIR}" ]; then
	echo "claude-overlay: ${OVERLAY_DIR} does not exist here (the image build) - the stub is written at the first start"
	exit 0
fi
if [ -e "${TARGET}" ] || [ -L "${TARGET}" ]; then
	if grep -q '^<!-- do-agent-aws overlay stub -->' "${TARGET}" 2>/dev/null; then
		echo "claude-overlay: ${TARGET} is the stub - the overlay is not filled yet (copy ${OVERLAY_EXAMPLE} over it and fill the placeholders)"
	else
		echo "claude-overlay: ${TARGET} exists ($(wc -c < "${TARGET}" 2>/dev/null || echo "?") bytes) - the operator's overlay, left as it is"
	fi
	exit 0
fi
TMP=$(mktemp "${OVERLAY_DIR%/}/.CLAUDE.md.XXXXXX") || { echo "claude-overlay: could not write under ${OVERLAY_DIR}"; exit 1; }
cat > "${TMP}" << STUB
<!-- do-agent-aws overlay stub -->
# Operator's overlay - not filled yet

This file is where the standing instructions of THIS deployment go: who the agent works for and as whom it speaks, what it
may do unasked and what stays staged, how it verifies and reports, the clusters, repositories and channels it is bound to,
the failure modes seen here. Every autonomy-loop fire, the Slack chat responder and the agent's pane read this file at the
start of their session (their working directory is ${OVERLAY_DIR}), below the harness's rules.

Nothing is filled in yet, so the harness's generic rules alone apply. To fill it: copy the example over this file and
replace the \`<...>\` placeholders - on the host, in the project directory, \`cp\` the checkout's
\`docs/parity/CLAUDE.md.example\` to \`wd/CLAUDE.md\`; inside the container the same example is \`${OVERLAY_EXAMPLE}\`.
docs/manual/autonomy.md "Parity with a native instance" says what each section is for. This stub is written once by the harness when no
file exists (AGENT_OVERLAY in .env); whatever replaces it is never touched.
STUB
chmod 0644 "${TMP}"   # mktemp makes it 0600; the operator on the host reads and replaces this file
if mv -f "${TMP}" "${TARGET}"; then
	echo "claude-overlay: wrote the stub ${TARGET} (no overlay yet; the example is ${OVERLAY_EXAMPLE})"
else
	rm -f "${TMP:?}"
	echo "claude-overlay: could not write ${TARGET}"
	exit 1
fi
