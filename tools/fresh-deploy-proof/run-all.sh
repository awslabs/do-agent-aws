#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Proof orchestration after `proof.sh bundle` and `proof.sh build` (same PROOF_* settings as proof.sh): waits for the remote build, then every proof
# step in order with the waits between them, STOPS at the first failed step, and collects the evidence. The
# final verdict comes from the rc files only (20-run-rc.txt, 32-test-rc.txt). One log; never edited while it runs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
P=${HERE}/proof.sh
HOST=${PROOF_HOST:?PROOF_HOST: the ssh destination of the proof host}
RD=${PROOF_DIR:-'~/ado-proof'}
# the remote command strings below are single-quoted (their $ are the remote's), so RD is handed to the remote shell
R() { ssh -o BatchMode=yes "${HOST}" "RD=${RD}; $*"; }
die() { echo; echo "##### $(date -u +%FT%TZ) PROOF FAILED: $*"; exit 1; }
step() { echo; echo "##### $(date -u +%FT%TZ) $*"; "${P}" "$@"; local RC=$?; echo "##### rc=${RC}"; [ ${RC} -eq 0 ] || die "step $* exited ${RC}"; }

echo "##### $(date -u +%FT%TZ) waiting for the remote build"
for i in $(seq 1 80); do R 'cat ${RD}/evidence/12-build-rc.txt 2>/dev/null' | grep -q '^rc=' && break; sleep 30; done
R 'cat ${RD}/evidence/12-build-rc.txt; grep -E "setup.sh: (FAILED|all required)" ${RD}/evidence/11-build.log | tail -1'
R 'grep -q "^rc=0" ${RD}/evidence/12-build-rc.txt' || die "build rc is not 0"

step run
R 'cat ${RD}/evidence/20-run-rc.txt'
step hostcheck
step neighbour
step neighbour2
step neighbour3
step routemove
step llpages before
step wdbefore
step tests
echo "##### $(date -u +%FT%TZ) waiting for the tests"
for i in $(seq 1 60); do R 'cat ${RD}/evidence/32-test-rc.txt 2>/dev/null' | grep -q '^rc=' && break; sleep 30; done
R 'cat ${RD}/evidence/32-test-rc.txt; echo "succeeded/PASSED lines: $(grep -cE "succeeded|PASSED" ${RD}/evidence/31-test.log)"; grep -E "FAILED|skipped" ${RD}/evidence/31-test.log | head -5'
R 'grep -q "^rc=0" ${RD}/evidence/32-test-rc.txt' || die "test rc is not 0 (see 31-test.log)"
step wdafter
step llpages after
echo "##### $(date -u +%FT%TZ) waiting for the seed extraction to drain"
for i in $(seq 1 40); do
	PEND=$(R 'for b in harness-knowledge loglearner-rules; do curl -s http://127.0.0.1:8000/memory-api/v1/default/banks/$b/stats | python3 -c "import sys,json; print(json.load(sys.stdin)[\"pending_operations\"])"; done 2>/dev/null | paste -sd+ | bc')
	echo "pending=${PEND}"; [ "${PEND}" == "0" ] && break; sleep 30
done
step seed
step persist
step persistafter
step collect
E=${HERE}/evidence
grep -E "^Test-exec PASSED|^Test[0-9]+ (succeeded|FAILED)|^FAILED|skipped|^ok 1b - the test container|^ok 3 - the LogLearner|^ok 3 - tile hindsight.localhost root|^ok 3 - the memory UI|^ok 3 - planted|^ok 4 - planted controls: stopped|^ok 4b|^ok 6b - nothing|^ok 7 - foreign|^ok 8 - every backend|^ok 8b - planted|^ok 1b - .env|^ok 2 - compound|^ok 6 - counts|^ok 6b - planted control: with|^ok 8 - read back|^test.sh: nothing" "${E}/31-test.log" > "${E}/33-test-verdicts.txt"
echo "##### verdict lines: $(wc -l < "${E}/33-test-verdicts.txt")"; cat "${E}/33-test-verdicts.txt"
echo
echo "##### $(date -u +%FT%TZ) run-all done - the rc files:"
echo "20-run-rc.txt:  $(paste -sd' ' "${E}/20-run-rc.txt")"
echo "32-test-rc.txt: $(paste -sd' ' "${E}/32-test-rc.txt")"
grep -q '^rc=0' "${E}/20-run-rc.txt" && grep -q '^rc=0' "${E}/32-test-rc.txt" && echo "PROOF OK (run rc 0, test rc 0)" || die "an rc file is not 0"
