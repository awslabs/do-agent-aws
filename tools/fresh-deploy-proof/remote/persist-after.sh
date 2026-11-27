#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# after the persist step's ./stop.sh && ./run.sh: the UI status, the seed's view and the dangling-volume count (55-57)
set -u
E=../evidence
for i in $(seq 1 90); do curl -sf -o /dev/null http://127.0.0.1:8000/ && break; sleep 2; done; sleep 45
docker exec do-agent-aws /agent/ui-status.sh > ${E}/55-ui-status-after-restart.txt 2>&1; cat ${E}/55-ui-status-after-restart.txt
docker exec do-agent-aws /agent/hindsight-seed.sh --status 2>&1 | head -1 > ${E}/56-seed-status-after-restart.txt; cat ${E}/56-seed-status-after-restart.txt
B=$(cat ${E}/56-volumes-before.txt 2>/dev/null || echo '?'); A=$(docker volume ls -qf dangling=true | wc -l)
echo "dangling volumes before the persist stop/run: ${B}, after: ${A} (stop.sh removes the container's anonymous volumes with -v)" | tee ${E}/56-volumes.txt
# the first run on a fresh clone seeds; only the restart's seed run says "already seeded" - wait for that line
for i in $(seq 1 36); do docker exec do-agent-aws sh -c 'grep "already seeded" /wd/ui/hindsight-seed.log | tail -1' > ${E}/57-seed-log-after-restart.txt 2>/dev/null; [ -s ${E}/57-seed-log-after-restart.txt ] && break; sleep 5; done
cat ${E}/57-seed-log-after-restart.txt
