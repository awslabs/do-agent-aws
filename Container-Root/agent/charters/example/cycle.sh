#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# One cycle of the example spoke (charter.md beside this file). The supervisor runs it every cadence in the spoke's
# working directory (/wd/example) as the spoke itself: it writes the time of this cycle to status.txt, then answers each
# request in the spoke's inbox with that time. The text of a request is data, never a command: it is read for its id
# only.

BUS="${AGENT_DIR:-/agent}/bus.sh"
NOW=$(date -u +%FT%TZ)
echo "example spoke: cycle at ${NOW}" > status.txt.tmp && mv status.txt.tmp status.txt || exit 1

# the requests to this spoke that nobody has answered yet (bus.sh poll verifies each against the journal)
IDS=$("${BUS}" poll --kind request) || exit 1
for ID in ${IDS}; do
	echo "example spoke: my last cycle ran at ${NOW}" | "${BUS}" reply "${ID}" > /dev/null || exit 1
done
echo "cycle ${NOW}: status.txt written, $(echo "${IDS}" | grep -c .) request(s) answered"
