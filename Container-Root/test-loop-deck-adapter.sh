#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the Loop Deck harness adapter (/agent/loop-deck-adapter.py): the harness's own loops become Loop Deck's
# harness-mode inputs (docs: loop-deck-harness-contract.md), from planted copies of the sources, fully OFFLINE.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the adapter parses (ast.parse, nothing written beside it) and a dry run writes nothing
#   2. registry.json: the seven rows in order (autonomy-loop, slack-watch, slack-chat, comms-watch, kanban-sync,
#      plane-sync, hindsight-seed) with the contract's fields; a row's enabled follows its flag (SLACK_CHAT_ENABLED=false
#      -> false, a board URL -> kanban-sync true, no PLANE_URL -> plane-sync false); the seed row has no cadence
#   3. runs.jsonl: one record per source line/stamp with the SOURCE's ts and rc - four END lines (rc 0, 124, 97, 1 with
#      their durations and outcomes), a KANBAN line (rc 0) and a failed one (rc 3 from "not mirrored (rc=3"), the Slack
#      watch stamp, a CHAT MODEL line, the comms cycle (ts = the log's mtime, the note says the source has no ts/rc),
#      the seed stamp; an END line the adapter cannot read is skipped with a WARNING, never invented
#   4. loop-ledger.json: three failed fires in a row are one breaker item with attempts 3 (>= max_attempts 3)
#   5. state.json: never paused; the STOP flag makes the autonomy-loop ROW enabled:false on the next run instead
#   6. a second run appends nothing (no duplicate (ts, tag)); a new END line appends exactly one record
#   7. the adapter writes only its four files under the data dir: a planted out/status.json is byte-identical after the
#      run (no generator runs here: LOOP_DECK_GENERATOR=), and nothing outside the data dir changed (the sources included)
#   8. an unwritable data dir (a file in its place) exits 2 with one ERROR line
set -u
D=/tmp/loop-deck-smoke
rm -rf "${D:?}"
mkdir -p ${D}/loop ${D}/slack ${D}/comms ${D}/ui ${D}/deck/out ${D}/other
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
ADAPTER="${AGENT_DIR}/loop-deck-adapter.py"
fail() { echo "Test-loop-deck-adapter FAILED: $*"; exit 1; }
j() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$1" "$2"; }

# LOOP_DECK_GENERATOR= (empty) runs no generator: this test proves the adapter's own writes. By default the adapter runs
# the vendored Deck's generator after writing when /opt/loop-deck is there (in the image), and the generator renders out/,
# status.json included; that path is test-loop-deck.sh check 2's
export AUTONOMY_LOOP_DIR=${D}/loop SLACK_DIR=${D}/slack COMMS_DIR=${D}/comms HINDSIGHT_SEED_STAMP=${D}/hindsight-seed.stamp \
       HINDSIGHT_SEED_STATE=${D}/ui/hindsight-seed.state LOOP_DECK_DATA_DIR=${D}/deck AUTONOMY_LOOP_INTERVAL=120 \
       SLACK_WATCH_ENABLED=true SLACK_CHAT_ENABLED=false COMMS_WATCH_ENABLED=true KANBAN_BOARD_URL=http://board:1 PLANE_URL= HINDSIGHT_SEED=true \
       LOOP_DECK_GENERATOR=
unset AUTONOMY_LOOP

# the planted sources, in the harness's own formats
cat > ${D}/loop/loop.log << 'LOG'
2026-10-13T16:44:08Z FIRE 1 START goals=/wd/goals/GOALS.md
2026-10-13T16:44:51Z FIRE 1 KANBAN fire 1 end: 'write the hello file' -> Done; 2 card(s), 0 created, 1 moved (project exists)
2026-10-13T16:44:51Z FIRE 1 END rc=0 duration=43s outcome=ok
2026-10-13T16:50:00Z FIRE 2 KANBAN fire 2 start not mirrored (rc=3, see /wd/loop/kanban-sync.log); the fire is unaffected
2026-10-13T17:00:11Z FIRE 2 END rc=124 duration=600s outcome=timeout
2026-10-13T17:02:30Z FIRE 3 END rc=97 duration=4s outcome=no-credentials
2026-10-13T17:05:00Z FIRE 4 END rc=1 duration=9s outcome=error
2026-10-13T17:06:00Z FIRE 5 END duration=9s
LOG
echo "2026-10-13T16:44:10Z new=2 replies=1 deferred=0 inbox=3" > ${D}/slack/last-watch
printf '2026-10-13T17:27:50Z CHAT POLLING channels=2\n2026-10-13T17:27:59Z CHAT MODEL ts=1791912476.869000 rc=0 duration=9s posted=yes transcript=/wd/slack/chat/C1-1791912476.869000.txt\n' > ${D}/slack/chat.log
printf 'scheduler: starting\ncycle: polled=2 fresh=0 unattended=0 next-fire<=300s\ncycle: polled=2 fresh=1 unattended=1 next-fire<=300s answered=0\n' > ${D}/comms/watch.log
printf 'seeded_at=2026-10-13T11:51:31Z\napi=http://127.0.0.1:8888\nitems=276\n' > ${D}/hindsight-seed.stamp
printf 'state=complete\n' > ${D}/ui/hindsight-seed.state
echo '{"planted": "deck output"}' > ${D}/deck/out/status.json
find ${D} -type f -not -path "${D}/deck/*" -not -path "${D}/other/*" -exec md5sum {} + | sort > ${D}/other/before.md5

# --- 1. parses; a dry run writes nothing ---
python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "${ADAPTER}" || fail "the adapter does not parse"   # no .pyc beside a read-only /agent
OUT=$(python3 -I "${ADAPTER}" --dry-run 2>&1) || fail "dry run exited non-zero: ${OUT}"
echo "${OUT}" | grep -q "dry run - 7 rows, 10 run record(s)" || fail "the dry run does not report 7 rows and 10 records: ${OUT}"
[ "$(ls ${D}/deck | tr '\n' ' ')" == "out " ] || fail "the dry run wrote into the data dir: $(ls ${D}/deck)"
echo "ok 1 - the adapter compiles; --dry-run reports 7 rows and 10 records and writes nothing"

# --- 2. the registry ---
OUT=$(python3 -I "${ADAPTER}" 2> ${D}/run1.err) || fail "run 1 exited non-zero: ${OUT} $(cat ${D}/run1.err)"
R=${D}/deck/registry.json
[ "$(j ${R} 'd["schema"]')" == "loop-deck-registry/1" ] || fail "registry schema: $(j ${R} 'd["schema"]')"
[ "$(j ${R} '"|".join(l["slug"] for l in d["loops"])')" == "autonomy-loop|slack-watch|slack-chat|comms-watch|kanban-sync|plane-sync|hindsight-seed" ] \
	|| fail "the rows are not the seven loops in order: $(j ${R} '[l["slug"] for l in d["loops"]]')"
for F in slug name kind owner cadence_s tags enabled depends_on runbook_md; do
	[ "$(j ${R} "all('${F}' in l for l in d['loops'])")" == "True" ] || fail "a row lacks the field ${F}"
done
[ "$(j ${R} '[l["enabled"] for l in d["loops"]]')" == "[True, True, False, True, True, False, True]" ] \
	|| fail "enabled flags do not follow the environment (chat off, board on, no Plane): $(j ${R} '[(l["slug"], l["enabled"]) for l in d["loops"]]')"
[ "$(j ${R} '[l["cadence_s"] for l in d["loops"]]')" == "[120, 120, 120, 300, 120, 120, None]" ] || fail "cadences: $(j ${R} '[l["cadence_s"] for l in d["loops"]]')"
[ "$(j ${R} 'd["loops"][6]["kind"]')" == "seed" ] || fail "the seed row is not kind seed"
[ "$(j ${R} 'd["loops"][4]["depends_on"]')" == "['autonomy-loop']" ] || fail "kanban-sync does not depend on the autonomy loop (Topology edge)"
[ "$(j ${R} 'all(len(l["tags"]) >= 1 for l in d["loops"])')" == "True" ] || fail "a row has no tag"
grep -q "7 rows (5 enabled), 10 new run record(s) appended (0 already recorded), 1 ledger item(s), 1 source line(s) skipped" <<< "${OUT}" || fail "run 1's summary: ${OUT}"
echo "ok 2 - registry.json: the seven rows in order with the contract's fields, enabled from the flags, cadences from the loop interval, the seed row one-shot"

# --- 3. the runs ---
RUNS=${D}/deck/runs.jsonl
[ "$(wc -l < ${RUNS})" == "10" ] || fail "runs.jsonl has $(wc -l < ${RUNS}) records, expected 10: $(cat ${RUNS})"
rec() { grep -F "\"tag\": \"$1\"" ${RUNS} | grep -F "\"ts\": \"$2\""; }
rec harness-autonomy-loop 2026-10-13T16:44:51Z | grep -q '"rc": 0, "dur_s": 43, "note": "fire 1 outcome=ok"' || fail "fire 1's record: $(rec harness-autonomy-loop 2026-10-13T16:44:51Z)"
rec harness-autonomy-loop 2026-10-13T17:00:11Z | grep -q '"rc": 124, "dur_s": 600, "note": "fire 2 outcome=timeout"' || fail "fire 2's record"
rec harness-autonomy-loop 2026-10-13T17:02:30Z | grep -q '"rc": 97, "dur_s": 4' || fail "fire 3's record"
rec harness-autonomy-loop 2026-10-13T17:05:00Z | grep -q '"rc": 1, "dur_s": 9' || fail "fire 4's record"
grep -c '"tag": "harness-autonomy-loop"' ${RUNS} | grep -qx 4 || fail "the autonomy loop has $(grep -c harness-autonomy-loop ${RUNS}) records, expected 4 (the unreadable END line skipped)"
grep -q "WARNING - loop.log: an END line the adapter cannot read, skipped (nothing invented): 2026-10-13T17:06:00Z FIRE 5 END duration=9s" ${D}/run1.err || fail "the unreadable END line was not reported: $(cat ${D}/run1.err)"
rec harness-kanban-sync 2026-10-13T16:44:51Z | grep -q '"rc": 0, "dur_s": null' || fail "the mirrored fire's record is not rc 0 without a duration"
rec harness-kanban-sync 2026-10-13T16:50:00Z | grep -q '"rc": 3, "dur_s": null' || fail "the failed mirror's rc was not read from 'not mirrored (rc=3'"
rec harness-slack-watch 2026-10-13T16:44:10Z | grep -q '"rc": 0, "dur_s": null, "note": "new=2 replies=1 deferred=0 inbox=3 (rc 0: slack-watch.sh writes this stamp only after a completed run' || fail "the watch stamp's record: $(rec harness-slack-watch 2026-10-13T16:44:10Z)"
rec harness-slack-chat 2026-10-13T17:27:59Z | grep -q '"rc": 0, "dur_s": 9, "note": "ts=1791912476.869000 posted=yes' || fail "the chat line's record"
MT=$(date -u -r ${D}/comms/watch.log +%Y-%m-%dT%H:%M:%SZ)
rec harness-comms-watch "${MT}" | grep -q 'no ts/rc in the source: ts = watch.log mtime, rc 0 = a cycle was logged; 2 cycle line(s); last: cycle: polled=2 fresh=1 unattended=1 next-fire<=300s answered=0' || fail "the comms record does not say its ts and rc are not the source's, with the count and the last cycle line: $(grep harness-comms-watch ${RUNS})"
rec harness-hindsight-seed 2026-10-13T11:51:31Z | grep -q '"rc": 0, "dur_s": null, "note": "items=276; accepted by the memory API' || fail "the seed's record: $(grep hindsight-seed ${RUNS})"
grep -q '"tag": "harness-plane-sync"' ${RUNS} && fail "a plane-sync record was invented without a PLANE line"
echo "ok 3 - runs.jsonl: 10 records with the sources' ts and rc (END lines, a mirrored and a failed KANBAN line, the watch stamp, the chat line, the comms cycle with its honest note, the seed stamp); an unreadable END line skipped with a WARNING"

# --- 4. the ledger ---
L=${D}/deck/loop-ledger.json
[ "$(j ${L} 'd["max_attempts"]')" == "3" ] || fail "max_attempts"
[ "$(j ${L} 'list(d["items"])')" == "['autonomy-loop:streak-2']" ] || fail "the breaker items are not the one streak starting at fire 2: $(j ${L} 'd["items"]')"
[ "$(j ${L} 'd["items"]["autonomy-loop:streak-2"]["attempts"]')" == "3" ] || fail "the streak's attempts: $(j ${L} 'd["items"]')"
[ "$(j ${L} 'd["items"]["autonomy-loop:streak-2"]["last_ts"]')" == "2026-10-13T17:05:00Z" ] || fail "the streak's last_ts"
echo "ok 4 - loop-ledger.json: fires 2-4 failing in a row are one breaker item with attempts 3 (max_attempts 3)"

# --- 5. state and the STOP flag ---
S=${D}/deck/state.json
[ "$(j ${S} 'd["paused"]')" == "False" ] || fail "state.json is paused"
touch ${D}/loop/STOP
python3 -I "${ADAPTER}" > /dev/null 2>&1 || fail "run with STOP failed"
[ "$(j ${R} 'd["loops"][0]["enabled"]')" == "False" ] || fail "the STOP flag did not disable the autonomy-loop row"
[ "$(j ${S} 'd["paused"]')" == "False" ] || fail "the STOP flag paused the whole deck (it is the row's enabled:false)"
j ${R} 'd["loops"][0]["runbook_md"]' | grep -q "Currently stopped" || fail "the row's runbook does not say the loop is stopped"
rm -f "${D:?}/loop/STOP"
echo "ok 5 - state.json never paused; the STOP flag turns the autonomy-loop row to enabled:false (and back) and says so in its runbook"

# --- 6. idempotent appends ---
OUT=$(python3 -I "${ADAPTER}" 2>/dev/null) || fail "run 3 failed"
echo "${OUT}" | grep -q "0 new run record(s) appended (10 already recorded)" || fail "a re-run appended records: ${OUT}"
[ "$(wc -l < ${RUNS})" == "10" ] || fail "runs.jsonl grew on a re-run"
echo "2026-10-13T17:30:00Z FIRE 6 END rc=0 duration=12s outcome=ok" >> ${D}/loop/loop.log
OUT=$(python3 -I "${ADAPTER}" 2>/dev/null) || fail "run 4 failed"
echo "${OUT}" | grep -q "1 new run record(s) appended (10 already recorded)" || fail "a new END line did not append exactly one record: ${OUT}"
[ "$(wc -l < ${RUNS})" == "11" ] || fail "runs.jsonl does not have 11 records"
[ "$(j ${L} 'list(d["items"])')" == "['autonomy-loop:streak-2']" ] || fail "a success after the streak changed the breaker: $(j ${L} 'd["items"]')"
echo "ok 6 - a re-run appends nothing; a new END line appends exactly one record; the breaker item stays"

# --- 7. writes only its four files; the Deck's out/ and the sources untouched ---
[ "$(cd ${D}/deck && ls | sort | tr '\n' ' ')" == "loop-ledger.json out registry.json runs.jsonl state.json " ] || fail "the data dir holds more than the four inputs and out/: $(ls ${D}/deck)"
[ "$(cat ${D}/deck/out/status.json)" == '{"planted": "deck output"}' ] || fail "the adapter touched the Deck's out/status.json"
find ${D} -type f -not -path "${D}/deck/*" -not -path "${D}/other/*" -not -name run1.err -exec md5sum {} + | sort > ${D}/other/after.md5
# the sources changed only where the test appended (loop.log) - everything else is byte-identical
grep -v '/loop/loop.log$' ${D}/other/before.md5 > ${D}/other/before-rest.md5; grep -v '/loop/loop.log$' ${D}/other/after.md5 > ${D}/other/after-rest.md5
diff -q ${D}/other/before-rest.md5 ${D}/other/after-rest.md5 > /dev/null || fail "a source file changed: $(diff ${D}/other/before-rest.md5 ${D}/other/after-rest.md5)"
echo "ok 7 - the adapter writes registry.json, runs.jsonl, loop-ledger.json and state.json alone; out/ and the sources are untouched"

# --- 8. an unwritable data dir ---
touch ${D}/notadir
OUT=$(LOOP_DECK_DATA_DIR=${D}/notadir python3 -I "${ADAPTER}" 2>&1); RC=$?
[ "${RC}" == "2" ] || fail "a data dir that is a file did not exit 2 (rc=${RC}): ${OUT}"
echo "${OUT}" | grep -q "^loop-deck-adapter: ERROR - cannot write the data directory" || fail "no ERROR line for the unwritable data dir: ${OUT}"
echo "ok 8 - an unwritable data dir exits 2 with one ERROR line"

# --- 9. the Deck's data contract: the vendored release's validator (/opt/loop-deck/tools/check-contract.py, VENDORED.md) accepts the
#        adapter's output and its own examples, and REFUSES a planted wrong row (a periodic loop with cadence_s null, which only
#        a seed row may have) and a planted run whose tag no row claims ---
LOOP_DECK_DIR=${LOOP_DECK_DIR:-/opt/loop-deck}; [ -f "${LOOP_DECK_DIR}/tools/check-contract.py" ] || LOOP_DECK_DIR="${BASE_DIR%/}/opt/loop-deck"
VAL="${LOOP_DECK_DIR}/tools/check-contract.py"
[ -f "${VAL}" ] || fail "no ${VAL} (the vendored Loop Deck release ships its contract validator)"
PYTHONDONTWRITEBYTECODE=1 python3 -I "${VAL}" --self-test > ${D}/val-selftest.out 2>&1 || fail "the validator's self-test fails (it would not discriminate): $(tail -3 ${D}/val-selftest.out)"
PYTHONDONTWRITEBYTECODE=1 python3 -I "${VAL}" "${D}/deck" > ${D}/val-deck.out 2>&1 || fail "the adapter's output fails the Deck's contract: $(cat ${D}/val-deck.out)"
grep -q "^OK: " ${D}/val-deck.out || fail "the validator did not report OK on the adapter's output: $(cat ${D}/val-deck.out)"
rm -rf "${D:?}/deck-bad" && cp -r "${D}/deck" "${D}/deck-bad"
python3 - "${D}/deck-bad/registry.json" << 'PYBAD'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
rows = d["loops"] if isinstance(d.get("loops"), list) else list(d["loops"].values())
row = next(r for r in rows if r["kind"] != "seed"); row["cadence_s"] = None
json.dump(d, open(p, "w"))
PYBAD
PYTHONDONTWRITEBYTECODE=1 python3 -I "${VAL}" "${D}/deck-bad" > ${D}/val-bad.out 2>&1; RC=$?
[ ${RC} -eq 2 ] || fail "PLANTED CONTROL BROKEN: a periodic row with cadence_s null passed the validator (rc ${RC}): $(cat ${D}/val-bad.out)"
grep -q "CONTRACT VIOLATION" ${D}/val-bad.out || fail "the validator did not name the violation: $(cat ${D}/val-bad.out)"
rm -rf "${D:?}/deck-bad2" && cp -r "${D}/deck" "${D}/deck-bad2"
printf '{"ts": "2026-10-13T00:00:00Z", "tag": "harness-nobody-claims-this", "rc": 0, "dur_s": 1}\n' >> "${D}/deck-bad2/runs.jsonl"
PYTHONDONTWRITEBYTECODE=1 python3 -I "${VAL}" "${D}/deck-bad2" > ${D}/val-bad2.out 2>&1; RC=$?
[ ${RC} -eq 2 ] || fail "PLANTED CONTROL BROKEN: a run with a tag no row claims passed the validator (rc ${RC}): $(cat ${D}/val-bad2.out)"
echo "ok 9 - the vendored release's contract validator: self-test discriminates, the adapter's output passes (OK), a periodic row with cadence_s null and a run with an unclaimed tag are refused (exit 2)"

echo "Test-loop-deck-adapter succeeded"
