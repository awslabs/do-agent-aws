#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# /agent/recall.sh "<query>" [--k N] [--category C] [--status positive|negative] [--no-hindsight]
#
# Search what the agent already knows before it acts, in both places the harness keeps knowledge:
#   1. the LogLearner knowledge banks (the /seed banks, the starter rules, everything /agent/learn.sh banked -
#      the records the PreToolUse hook delivers): the runtime's own `python3 -m loglearner.cli recall`, the
#      hook's word match, best first;
#   2. the Hindsight memory API on 127.0.0.1:8888, every bank (the seed banks and the agent's own session
#      memories): /agent/hindsight-recall.py, which counts a memory only when it contains a query term.
# --k N caps each source (default 5). --category and --status filter the bank records and skip Hindsight, whose
# memories carry neither; --no-hindsight skips it too. Plain text out, a summary line last.
# Exit 0 when either source found something, 1 when neither did, 2 on a usage error.
# The agent's CLAUDE.md ("Learning tools") says when to use it.

# shellcheck source=loglearner-env.sh
. "$(dirname "$0")/loglearner-env.sh"

usage() { echo "usage: recall.sh \"<query>\" [--k N] [--category C] [--status positive|negative] [--no-hindsight]" >&2; exit 2; }
K=5; QUERY=""; BANK_OPTS=(); HINDSIGHT=true
while [ $# -gt 0 ]; do
	case "$1" in
	--k) { [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ]; } || usage; K=$2; shift 2 ;;
	--category|--status) [ -n "$2" ] || usage; BANK_OPTS+=("$1" "$2"); HINDSIGHT=false; shift 2 ;;
	--no-hindsight) HINDSIGHT=false; shift ;;
	-h|--help) sed -n '5,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) usage ;;
	*) QUERY="${QUERY:+${QUERY} }$1"; shift ;;
	esac
done
[ -n "${QUERY// /}" ] || usage

echo "== LogLearner banks (${LOGLEARNER_BANKS_DIR})"
( cd "${LOGLEARNER_DIR}" && python3 -m loglearner.cli recall "${QUERY}" --k "${K}" "${BANK_OPTS[@]}" ) 2>&1
BANK_RC=$?
HS_RC=1
if [ "${HINDSIGHT}" == "true" ]; then
	echo "== Hindsight memory (127.0.0.1:${UI_PORT_HINDSIGHT_API})"
	python3 "$(dirname "$0")/hindsight-recall.py" "${QUERY}" --k "${K}" 2>&1
	HS_RC=$?
fi
[ "${BANK_RC}" -eq 0 ] && B="found" || B="nothing"
[ "${HS_RC}" -eq 0 ] && H="found" || H="nothing"
[ "${HINDSIGHT}" == "true" ] || H="not asked"
echo "recall: LogLearner banks: ${B}; Hindsight: ${H}"
[ "${BANK_RC}" -eq 0 ] || [ "${HS_RC}" -eq 0 ]
