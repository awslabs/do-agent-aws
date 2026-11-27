#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The bus as an autonomy-loop fire may use it (docs/INTER-AGENT-MESSAGING.md "A loop fire reads its inbox first"):
#   /agent/bus-answer.sh reply <id>      the answer to a request sent to you, to its sender (the text on stdin)
#   /agent/bus-answer.sh error <id>      a failure to act on it, to its sender (the text on stdin)
#   /agent/bus-answer.sh receipt <id> read|completed|denied [--reason <text>]   a receipt for a message to you
#   /agent/bus-answer.sh state <id>...   where each message to you stands
# Each runs /agent/bus.sh beside it with the same arguments and the caller's identity. Every other bus.sh command -
# request, note, send, poll, peek, last - is refused with exit status 2, so the loop's default allow rule
# Bash(/agent/bus-answer.sh:*) - one rule for the four verbs a fire needs - lets an unattended fire answer and close the
# messages to it, and it cannot start one. The projections under /wd/mailbox are files of its working directory, which
# it can read. bus.sh itself stays for the sessions and the spokes' cycles.

case "${1:-}" in
	reply | error | receipt | state)
		exec "$(dirname "$0")/bus.sh" "$@"
		;;
esac
echo "bus-answer.sh: '${1:-}' is not reply, error, receipt or state - a loop fire answers the messages to it and starts none (/agent/bus.sh has the rest)" >&2
exit 2
