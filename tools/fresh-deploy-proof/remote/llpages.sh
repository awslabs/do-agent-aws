#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# the LogLearner dashboard on the fresh deploy (<tag> = before|after the suite): each page's status and its count of
# the internal name the 0.1.2 runtime leaked, the projects it lists, the harness server's effective index path and
# the persisted claude projects. Appends to evidence 27b. The name counted is the caller's second argument (proof.sh
# passes LL_LEAK_NEEDLE from the operator's environment); this file never spells it, and with no needle the count
# reads "-" (not measured) rather than a number that means nothing.
set -u
TAG=$1; NEEDLE=${2:-}; E=../evidence
{
printf 'LogLearner pages on the fresh deploy (%s the suite):' "${TAG}"
for p in / /knowledge /learnings /hindsight; do
	c=$(curl -s -o ${E}/ll-page.html -w '%{http_code}' --max-time 10 -H 'Host: loglearner.localhost:8000' "http://127.0.0.1:8000${p}")
	if [ -n "${NEEDLE}" ]; then h=$(grep -ci -- "${NEEDLE}" ${E}/ll-page.html); else h=-; fi
	printf ' %s=%s/%s' "${p}" "${c}" "${h}"
done
echo ' (code/internal-name hits; - = no needle given)'
echo "LogLearner projects listed (${TAG}): $(curl -s -H 'Host: loglearner.localhost:8000' http://127.0.0.1:8000/ | grep -oE 'href="/project/[^"]*"' | sed -E 's#.*/project/##; s#"$##' | sort -u | tr '\n' ' ')"
echo "harness LogLearner server (${TAG}): $(docker exec do-agent-aws sh -c 'for p in $(pgrep -f dashboard/app.py); do tr "\0" "\n" < /proc/$p/environ | grep -E "^LOGLEARNER_(STATE|DB)="; done' | sort -u | tr '\n' ' ')"
echo "persisted claude projects (${TAG}): $(sudo -n ls wd/agent-state/.claude/projects 2>/dev/null | tr '\n' ' ')"
} | tee -a ${E}/27b-loglearner-pages.txt
rm -f "${E:?}/ll-page.html"
