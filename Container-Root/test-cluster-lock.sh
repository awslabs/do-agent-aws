#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the cluster lock and the GPU broker (docs/cluster-lock.md): /agent/cluster-lock.sh on a test-local lock
# directory, a planted race, the clusters spoke's broker (/agent/charters/clusters/broker.py) answering the hub over the
# bus, expiry, one cycle of the spoke's loop, and the rule that every job that touches a cluster takes a lease first and
# releases it when it ends. Fully OFFLINE: no cluster (a stub kubectl), no tmux server, no network; a test-local
# registry, journal and working directories under /tmp/cluster-lock-smoke (or TEST_CLUSTER_LOCK_DIR); nothing under /wd.
#
# Properties proven (each check FAILS if the property is removed):
#   1 [claim-grants]. a claim on a free cluster exits 0 with one line naming the holder and the expiry; the lock file
#      holds the holder, its reason, claimed_at and expires_at (claimed_at plus the ttl) and an empty queue, beside the
#      file lock it is changed under
#   2 [second-claim-queues]. a second claim exits 2, queued at position 1, a third at position 2, in the order they came;
#      a repeated claim queues nothing twice; the holder's own claim exits 0 and renews its lease, the queue kept; a
#      claim naming the holder from a session that is neither the holder nor the lease's session is refused (exit 2) and
#      changes nothing; the holder's own renewal keeps the lease's session, and that session can still renew and
#      release it
#   3 [extend]. the holder's extend moves expires_at later, and an extend shorter than what the lease has left keeps
#      it (an extend never shortens a lease); another holder's extend exits 2 and changes nothing; an extend of a
#      free cluster exits 3
#   4 [release-hands-over]. a release by someone else exits 2 and changes nothing; a queued holder's release leaves the
#      queue; the holder's release hands the lock to the queue head, whose ttl runs from the hand-over; the last release
#      frees it, and releasing a free lock exits 0
#   5 [reclaim-stale]. reclaim-stale refuses a live lease (exit 2, unchanged); an expired one is reclaimed and the
#      displaced holder recorded (who, its expiry, when, by whom), the queue head then holding it, or nobody; a claim
#      on an expired lease reclaims it the same way, recording the claimer; the holder's own claim on its expired lease
#      renews it and displaces nobody
#   6 [race-one-holder]. two claims at once, each holding the file lock for a second inside its change, are serialized
#      and end with exactly one holder: one exits 0, the other 2 and is queued
#   7 [invalid-refused]. a malformed cluster name (a path, a slash, an EKS ARN, a leading dash, a space, 65 characters,
#      empty), a malformed holder, a ttl of 0, 1441, a negative number, a word, 1_0, +5 or ' 5' (digits only), a
#      missing --holder or --ttl, node counts that do not add up, an unknown option and an unknown verb exit 3 and
#      write no lock file, in the lock directory or, for '../x', above it (control: a file planted there is seen); a lock file that is not the harness's (an older format, not JSON, or a v1 file with a
#      malformed queue entry or no holder field) is reported by status, and every verb on it exits 3 and changes
#      nothing
#   8 [status-output]. status prints one line per lock file: free, or held by whom, until when, live or EXPIRED, its
#      scope, its reason and its queue; status <cluster> only that one; --json the documents with their state
#   9 [run-wraps-job]. run claims, runs the job while its holder holds the lock (the job reads status), releases it at
#      the end and passes the job's exit code through; held by someone else, the job does not run (exit 2) and no
#      queue entry is left behind; after a run killed before its release, the next run under the same holder owns the
#      lease (live while its job runs, released at the end); a run inside a run of the same cluster and holder leaves
#      the lock to the outer one (an inner run with a shorter ttl changes nothing of the outer lease), and a marker
#      inherited with no live lease of its holder behind it makes an ordinary run (it claims and releases); run uses the cluster, holder and ttl as the claim read them (a zero-padded ttl
#      renews at half its own value with no error, options before the cluster release that cluster); a captured run
#      returns at once (no renewer outlives it holding the caller's pipe); after run is killed with SIGKILL its
#      renewer stops renewing; a renewal refused while the job runs is said on stderr; a queue entry of the
#      holder's from before the run outlives the run's not running; a TERM while the claim is written leaves no lease
#  10 [broker-lease]. the hub's gpu-lease requests over the bus get the broker's replies (from the spoke, reply_to set):
#      with no view of the clusters yet, the whole cluster's lock, saying so; then from the spoke's view, 12 GPUs on
#      named usable nodes (n1=8 and n3=4, never the cordoned node) and 2 on an EKS-ARN-named context's best-fitting
#      node, named by its Kubernetes node name, each lock file holding it; a second request for a held cluster is queued (position 1); a cluster not in
#      the view, one with too few free GPUs and a view older than 30 minutes give the whole cluster's lock, saying why;
#      a free-text request stays open for the spoke's session; a malformed gpu-lease gets an error and writes nothing,
#      above the lock directory either (the cluster '../x'); a 200-node lease
#      gets its one short answer naming the lock file that lists the nodes
#  11 [broker-release-expiry]. the hub's gpu-release frees its lease and the queue head holds it; a release naming
#      someone else is refused, and so are the hub's release and its renewal (a gpu-lease naming the holder) of a lease
#      a job took from another session, the lock file unchanged, while the
#      lease the hub asked for on a worker's behalf is released; a lease past its expiry is reclaimed by the next
#      broker run, its holder recorded as
#      displaced by the spoke; two broker runs at once (the cycle's and the session's) answer a request once; a view
#      age that is not a number is named (the request still answered) and a bus call past
#      CLUSTERS_BROKER_CALL_TIMEOUT_SEC is a named error (exit 1), neither a crash; an envelope with no sender and a
#      view row with no node name are answered and named, not a crash; an error reply carries at most 300 characters of
#      why; a run that cannot take broker.lock within CLUSTERS_BROKER_LOCK_WAIT_SEC ends at once (exit 1) naming the run
#      that holds it
#  12 [cycle-status-notice]. one cycle of the spoke's loop (a stub kubectl) answers a gpu-lease from the view it just
#      read, naming the node by its Kubernetes name (n2.ec2.internal; status.json's rows carry it, the table shows n2); STATUS.md and status.json list the lease and the queue; the holder's change since the previous cycle is a
#      LOCK-HOLDER change and exactly one notice for the hub, and a cycle with no change sends none; a malformed v1
#      lock file in the directory is listed with the other files and never stops the cycle; a lease the cycle's broker
#      reclaims is a LOCK-RECLAIMED change whose notice names the reclaim; the status.json written before the broker
#      runs carries the previous cycle's locks
#  13 [rule-named]. the clusters charter, the operating rules every session loads (agent-rules/AGENT_RULES.md) and
#      docs/cluster-lock.md (where the docs are at hand) say every job that touches a cluster takes a lease first and
#      releases it when it ends, naming /agent/cluster-lock.sh. PLANTED CONTROL: a copy without the rule fails
#  14. in the test container (TEST_CONTAINER=true) nothing is left under /wd. PLANTED CONTROL: an entry planted there is
#      named

fail()
{
	echo "Test-cluster-lock FAILED: $1"
	exit 1
}
unset TMUX TMUX_PANE BUS_AGENT_ID CLUSTER_LOCK_DIR CLUSTER_LOCK_HOLD_SEC CLUSTERS_SPOKE_WD CLUSTERS_SPOKE_LOCKS CLUSTERS_SPOKE_CONTEXTS

D=${TEST_CLUSTER_LOCK_DIR:-/tmp/cluster-lock-smoke}
# the directory is removed and made again, so it must be one named cluster-lock-smoke*, never a path that is merely set
case "$(basename "${D}")" in cluster-lock-smoke*) ;; *) fail "TEST_CLUSTER_LOCK_DIR must name a directory cluster-lock-smoke*, not '${D}'" ;; esac
rm -rf "${D:?}"
mkdir -p "${D}/bin"
find /wd -mindepth 1 2>/dev/null | sort > "${D}/wd-before.txt"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
CH="${AGENT_DIR}/charters/clusters"
CL="${AGENT_DIR}/cluster-lock.sh"
BUS="${AGENT_DIR}/bus.sh"
bash -n "$0" || fail "bash -n $0"
[ -x "${CL}" ] || fail "no executable cluster lock at ${CL}"
[ -f "${CH}/broker.py" ] || fail "the clusters spoke ships no broker at ${CH}/broker.py"
bash -n "${CL}" && bash -n "${CH}/loop.sh" || fail "bash -n cluster-lock.sh or the clusters loop"

# lk <dir> <args...> - the lock tool on a test-local lock directory
lk() { local L=$1; shift; CLUSTER_LOCK_DIR=${L} "${CL}" "$@"; }
# doc <dir> <cluster> <python expression over d, the lock file's document> - exit 0 when it holds
doc()
{
	python3 - "$1/$2.json" "$3" << 'PY'
import json, sys
from datetime import datetime, timezone
d = json.load(open(sys.argv[1]))
t = lambda s: datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
now = datetime.now(timezone.utc).timestamp()
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
}
# plant_expired <dir> <cluster> - the lease's expiry moved one minute into the past, as time passing would leave it
plant_expired()
{
	python3 - "$1/$2.json" << 'PY' || fail "could not plant an expired lease in $1/$2.json"
import json, os, sys
from datetime import datetime, timedelta, timezone
p = sys.argv[1]
d = json.load(open(p))
f = lambda x: x.strftime("%Y-%m-%dT%H:%M:%SZ")
now = datetime.now(timezone.utc)
d["claimed_at"], d["expires_at"] = f(now - timedelta(minutes=31)), f(now - timedelta(minutes=1))
json.dump(d, open(p + ".planted", "w"), indent=1)
os.replace(p + ".planted", p)
PY
}
STAMP='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# --- 1. a claim on a free cluster grants it ---
L=${D}/locks
OUT=$(lk "${L}" claim demo --holder h1 --ttl 30 --reason "first job" 2>&1)
RC=$?
[ ${RC} -eq 0 ] || fail "claim-grants: a claim on a free cluster exited ${RC}: ${OUT}"
echo "${OUT}" | grep -qxE "granted demo to h1 until ${STAMP} \(the whole cluster\)" || fail "claim-grants: the result is not one line naming the holder and the expiry: ${OUT}"
doc "${L}" demo 'd["v"] == 1 and d["cluster"] == "demo" and d["holder"] == "h1" and d["reason"] == "first job" and d["queue"] == [] and t(d["expires_at"]) - t(d["claimed_at"]) == 1800 and abs(t(d["claimed_at"]) - now) < 60' \
	|| fail "claim-grants: the lock file does not hold the claim: $(cat "${L}/demo.json" 2>&1)"
[ -f "${L}/demo.lock" ] || fail "claim-grants: no file lock beside the lock file (ls: $(ls "${L}"))"
echo "ok 1 [claim-grants] - '${OUT}'; the lock file holds h1, its reason, a 30 min expiry and an empty queue, beside demo.lock"

# --- 2. a second claim queues ---
OUT=$(lk "${L}" claim demo --holder h2 --ttl 20 2>&1)
RC=$?
[ ${RC} -eq 2 ] || fail "second-claim-queues: a claim on a held cluster exited ${RC}, not 2: ${OUT}"
echo "${OUT}" | grep -qxE "queued h2 for demo at position 1: held by h1 until ${STAMP}" || fail "second-claim-queues: the result does not say queued at position 1: ${OUT}"
OUT=$(lk "${L}" claim demo --holder h3 --ttl 10 2>&1)
[ $? -eq 2 ] && echo "${OUT}" | grep -qxE "queued h3 for demo at position 2: held by h1 until ${STAMP}" || fail "second-claim-queues: a third claim is not queued at position 2: ${OUT}"
OUT=$(lk "${L}" claim demo --holder h2 --ttl 20 2>&1)
[ $? -eq 2 ] && echo "${OUT}" | grep -qxE "queued h2 for demo at position 1: held by h1 until ${STAMP}" || fail "second-claim-queues: a repeated claim does not report its place: ${OUT}"
doc "${L}" demo '[e["holder"] for e in d["queue"]] == ["h2", "h3"] and d["holder"] == "h1"' || fail "second-claim-queues: the queue is not h2, h3 in claim order: $(cat "${L}/demo.json")"
OUT=$(lk "${L}" claim demo --holder h1 --ttl 45 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qxE "renewed demo for h1 until ${STAMP} \(the whole cluster\)" || fail "second-claim-queues: the holder's own claim does not renew its lease: ${OUT}"
doc "${L}" demo 'd["holder"] == "h1" and abs(t(d["expires_at"]) - now - 2700) < 60 and [e["holder"] for e in d["queue"]] == ["h2", "h3"]' \
	|| fail "second-claim-queues: the holder's renewal did not set its new expiry or lost the queue: $(cat "${L}/demo.json")"
# a renewal is the lease's: a claim naming its holder from a session that is neither the holder nor the lease's session
# is refused (exit 2) and changes nothing; the holder's own renewal goes through and keeps the lease's session, so the
# session that asked for the lease on the holder's behalf can still release it
lk "${L}" claim own --holder w1 --session hub --ttl 60 > /dev/null || fail "second-claim-queues: could not plant the hub's lease for w1"
cp "${L}/own.json" "${D}/own-before.json"
OUT=$(lk "${L}" claim own --holder w1 --session x --ttl 1 2>&1)
RC=$?
{ [ ${RC} -eq 2 ] && echo "${OUT}" | grep -qxF "held by w1 for session hub: x may not renew it"; } \
	|| fail "second-claim-queues: a renewal from a session that is neither the holder nor the lease's was not refused (exit ${RC}): ${OUT}"
cmp -s "${L}/own.json" "${D}/own-before.json" || fail "second-claim-queues: a refused renewal changed the lock file: $(cat "${L}/own.json")"
OUT=$(lk "${L}" claim own --holder w1 --session w1 --ttl 30 2>&1)
{ [ $? -eq 0 ] && echo "${OUT}" | grep -qxE "renewed own for w1 until ${STAMP} \(the whole cluster\)"; } || fail "second-claim-queues: the holder's own renewal was refused: ${OUT}"
doc "${L}" own 'd["holder"] == "w1" and d["session"] == "hub" and abs(t(d["expires_at"]) - now - 1800) < 60' \
	|| fail "second-claim-queues: the holder's renewal did not keep the lease's session or set its new expiry: $(cat "${L}/own.json")"
# and the session that asked for the lease on w1's behalf renews it too, keeping its session
OUT=$(lk "${L}" claim own --holder w1 --session hub --ttl 40 2>&1)
{ [ $? -eq 0 ] && echo "${OUT}" | grep -qxE "renewed own for w1 until ${STAMP} \(the whole cluster\)"; } || fail "second-claim-queues: the session that asked for w1's lease could not renew it: ${OUT}"
doc "${L}" own 'd["holder"] == "w1" and d["session"] == "hub" and abs(t(d["expires_at"]) - now - 2400) < 60' \
	|| fail "second-claim-queues: the hub's renewal of w1's lease did not set its new expiry or keep its session: $(cat "${L}/own.json")"
OUT=$(lk "${L}" release own --holder w1 --session hub 2>&1) || fail "second-claim-queues: the session that asked for w1's lease could not release it after w1 renewed it: ${OUT}"
echo "ok 2 [second-claim-queues] - h2 queued at position 1 (exit 2), h3 at position 2, a repeat queued nothing twice; the holder's own claim renewed its lease, the queue kept; a renewal from a session that is neither the holder nor the lease's was refused (exit 2, unchanged), the holder's own renewal kept the lease's session, that session renewed it too, and released it"

# --- 3. extend ---
OLD=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["expires_at"])' "${L}/demo.json")
OUT=$(lk "${L}" extend demo --holder h1 --ttl 60 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qxE "extended demo for h1 until ${STAMP}" || fail "extend: the holder's extend failed: ${OUT}"
doc "${L}" demo "t(d['expires_at']) > t('${OLD}') and abs(t(d['expires_at']) - now - 3600) < 60" || fail "extend: expires_at did not move to now plus 60 min (it was ${OLD}): $(cat "${L}/demo.json")"
# an extend shorter than what the lease has left keeps the later expiry: an extend never shortens a lease
KEEP=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["expires_at"])' "${L}/demo.json")
OUT=$(lk "${L}" extend demo --holder h1 --ttl 5 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qxF "demo for h1 already runs until ${KEEP}, later than 5 min from now: kept" || fail "extend: a 5-minute extend of a 60-minute lease does not keep the later expiry: ${OUT}"
doc "${L}" demo "d['expires_at'] == '${KEEP}'" || fail "extend: a 5-minute extend shortened the 60-minute lease: $(cat "${L}/demo.json")"
cp "${L}/demo.json" "${D}/demo-before.json"
OUT=$(lk "${L}" extend demo --holder h2 --ttl 600 2>&1)
[ $? -eq 2 ] && echo "${OUT}" | grep -qxF "held by h1, not h2: not extended" || fail "extend: another holder's extend is not refused with exit 2: ${OUT}"
cmp -s "${L}/demo.json" "${D}/demo-before.json" || fail "extend: a refused extend changed the lock file"
OUT=$(lk "${L}" extend free1 --holder h1 --ttl 10 2>&1)
[ $? -eq 3 ] || fail "extend: an extend of a free cluster did not exit 3: ${OUT}"
[ -e "${L}/free1.json" ] && fail "extend: a refused extend wrote free1.json"
echo "ok 3 [extend] - the holder's extend moved expires_at from ${OLD} to now + 60 min, and a 5-minute extend kept it there; h2's extend refused (exit 2, unchanged); a free cluster's extend exit 3"

# --- 4. release hands the lock over ---
OUT=$(lk "${L}" release demo --holder h4 2>&1)
[ $? -eq 2 ] && echo "${OUT}" | grep -qxF "held by h1, not h4: not released" || fail "release-hands-over: a release by someone else is not refused with exit 2: ${OUT}"
cmp -s "${L}/demo.json" "${D}/demo-before.json" || fail "release-hands-over: a refused release changed the lock file"
OUT=$(lk "${L}" release demo --holder h3 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qxF "h3 left the queue of demo" || fail "release-hands-over: a queued holder's release did not leave the queue: ${OUT}"
OUT=$(lk "${L}" release demo --holder h1 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qxE "released demo by h1; now held by h2 until ${STAMP}" || fail "release-hands-over: the holder's release did not hand the lock to the queue head: ${OUT}"
doc "${L}" demo 'd["holder"] == "h2" and d["queue"] == [] and abs(t(d["expires_at"]) - now - 1200) < 60 and abs(t(d["claimed_at"]) - now) < 60' \
	|| fail "release-hands-over: h2 does not hold it with its own 20 min from the hand-over: $(cat "${L}/demo.json")"
OUT=$(lk "${L}" release demo --holder h2 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qxF "released demo by h2; free" || fail "release-hands-over: the last release did not free it: ${OUT}"
doc "${L}" demo 'd["holder"] is None and d["expires_at"] is None and d["queue"] == []' || fail "release-hands-over: the freed lock file still names a holder: $(cat "${L}/demo.json")"
OUT=$(lk "${L}" release demo --holder h2 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qxF "demo is free: nothing to release" || fail "release-hands-over: releasing a free lock did not exit 0: ${OUT}"
echo "ok 4 [release-hands-over] - h4 refused (exit 2, unchanged), h3 left the queue, h1's release handed demo to h2 for its own 20 min, h2's freed it, a second release exit 0"

# --- 5. reclaim-stale ---
lk "${L}" claim demo --holder h5 --ttl 30 > /dev/null || fail "reclaim-stale: could not claim demo for h5"
lk "${L}" claim demo --holder h6 --ttl 15 > /dev/null
cp "${L}/demo.json" "${D}/demo-before.json"
OUT=$(lk "${L}" reclaim-stale demo --by tester 2>&1)
[ $? -eq 2 ] && echo "${OUT}" | grep -qxE "held by h5 until ${STAMP}, live: not reclaimed" || fail "reclaim-stale: a live lease is not refused with exit 2: ${OUT}"
cmp -s "${L}/demo.json" "${D}/demo-before.json" || fail "reclaim-stale: a refused reclaim changed the lock file"
plant_expired "${L}" demo
EXP=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["expires_at"])' "${L}/demo.json")
OUT=$(lk "${L}" reclaim-stale demo --by tester 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qxE "reclaimed demo from h5 \(expired ${EXP}\) by tester; now held by h6 until ${STAMP}" || fail "reclaim-stale: the expired lease was not reclaimed for the queue head: ${OUT}"
doc "${L}" demo "d['holder'] == 'h6' and d['queue'] == [] and d['displaced'][-1]['holder'] == 'h5' and d['displaced'][-1]['expires_at'] == '${EXP}' and d['displaced'][-1]['by'] == 'tester' and abs(t(d['displaced'][-1]['reclaimed_at']) - now) < 60" \
	|| fail "reclaim-stale: the displaced holder is not recorded: $(cat "${L}/demo.json")"
plant_expired "${L}" demo
OUT=$(lk "${L}" reclaim-stale demo --by tester 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qE "^reclaimed demo from h6 \(expired ${STAMP}\) by tester; free$" || fail "reclaim-stale: an expired lease with no queue was not freed: ${OUT}"
lk "${L}" claim demo --holder h7 --ttl 30 > /dev/null || fail "reclaim-stale: could not claim the freed demo for h7"
plant_expired "${L}" demo
OUT=$(lk "${L}" claim demo --holder h8 --ttl 30 2>&1)
[ $? -eq 0 ] && echo "${OUT}" | grep -qE "^granted demo to h8 until ${STAMP} \(the whole cluster\); reclaimed from h7, expired ${STAMP}$" || fail "reclaim-stale: a claim on an expired lease did not reclaim it: ${OUT}"
doc "${L}" demo 'd["holder"] == "h8" and d["displaced"][-1]["holder"] == "h7" and d["displaced"][-1]["by"] == "h8" and len(d["displaced"]) == 3' \
	|| fail "reclaim-stale: the claim's reclaim is not recorded with the claimer: $(cat "${L}/demo.json")"
# the holder's own claim on its expired lease (a job that came back under the same name) renews it, displacing nobody
plant_expired "${L}" demo
OUT2=$(lk "${L}" claim demo --holder h8 --ttl 30 2>&1)
[ $? -eq 0 ] && echo "${OUT2}" | grep -qxE "renewed demo for h8 until ${STAMP} \(the whole cluster\)" || fail "reclaim-stale: the holder's own claim on its expired lease does not renew it: ${OUT2}"
doc "${L}" demo 'd["holder"] == "h8" and abs(t(d["expires_at"]) - now - 1800) < 60 and len(d["displaced"]) == 3' \
	|| fail "reclaim-stale: the holder's renewal of its expired lease left it expired or displaced it: $(cat "${L}/demo.json")"
echo "ok 5 [reclaim-stale] - a live lease refused (exit 2); expired, h5 displaced by tester and h6 holds; expired with no queue, free; a claim on expired h7: '${OUT}'; h8's own claim on its expired lease renewed it"

# --- 6. a planted race: two claims at once, each holding the file lock for a second inside its change ---
R=${D}/race
mkdir -p "${R}"
T0=$(date +%s.%N)
CLUSTER_LOCK_HOLD_SEC=1 CLUSTER_LOCK_DIR=${R} "${CL}" claim race --holder r1 --ttl 5 > "${R}/out1" 2>&1 &
P1=$!
CLUSTER_LOCK_HOLD_SEC=1 CLUSTER_LOCK_DIR=${R} "${CL}" claim race --holder r2 --ttl 5 > "${R}/out2" 2>&1 &
P2=$!
wait ${P1}; RC1=$?
wait ${P2}; RC2=$?
T1=$(date +%s.%N)
[ "$(printf '%s\n' "${RC1}" "${RC2}" | sort | tr '\n' ' ')" == "0 2 " ] || fail "race-one-holder: two claims at once exited ${RC1} and ${RC2}, not one 0 and one 2: $(cat "${R}/out1" "${R}/out2")"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) >= 1.9 else 1)' "${T0}" "${T1}" \
	|| fail "race-one-holder: the two claims took under 2 s, so they did not wait for each other's file lock (the planted hold is not in effect)"
WIN=r1; LOSE=r2; [ ${RC2} -eq 0 ] && WIN=r2 && LOSE=r1
doc "${R}" race "d['holder'] == '${WIN}' and [e['holder'] for e in d['queue']] == ['${LOSE}']" || fail "race-one-holder: the lock file does not hold ${WIN} with ${LOSE} queued: $(cat "${R}/race.json")"
echo "ok 6 [race-one-holder] - two claims at once, each holding the file lock 1 s: serialized ($(python3 -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 1))' "${T0}" "${T1}") s), ${WIN} holds (exit 0), ${LOSE} queued (exit 2)"

# --- 7. invalid input is refused and writes nothing ---
V=${D}/invalid
mkdir -p "${V}"
bad()
{
	# bad <what> <args...> - the tool must exit 3 and leave the lock directory as it was
	local W=$1; shift
	local B; B=$(ls -A "${V}")
	OUT=$(lk "${V}" "$@" 2>&1)
	RC=$?
	[ ${RC} -eq 3 ] || fail "invalid-refused: ${W} exited ${RC}, not 3: ${OUT}"
	[ "$(ls -A "${V}")" == "${B}" ] || fail "invalid-refused: ${W} wrote into the lock directory: $(ls -A "${V}")"
	NBAD=$((NBAD + 1))
}
NBAD=0
for C in "../x" "a/b" "arn:aws:eks:us-east-1:ACCOUNT:cluster/demo" "-x" "x y" "$(printf 'a%.0s' $(seq 1 65))" ""; do
	bad "the cluster name '${C}'" claim "${C}" --holder h1 --ttl 5
done
# '../x' names the directory above the lock directory: nothing lands there either (control: a planted file is seen)
above() { [ -e "${D}/x.json" ] || [ -e "${D}/x.lock" ]; }
above && fail "invalid-refused: the cluster name '../x' wrote above the lock directory: $(ls -A "${D}" | grep -E '^x[.]' | tr '\n' ' ')"
: > "${D}/x.lock"
above || fail "invalid-refused: the check for a write above the lock directory does not see a planted x.lock"
rm -f "${D:?}/x.lock"
for H in "bad holder" "../h" "" "-h"; do bad "the holder '${H}'" claim demo --holder "${H}" --ttl 5; done
for TTL in 0 1441 -5 abc "" 1_0 +5 " 5"; do bad "a ttl of '${TTL}'" claim demo --holder h1 --ttl "${TTL}"; done
bad "a missing --holder" claim demo --ttl 5
bad "a missing --ttl" claim demo --holder h1
bad "node counts that do not add up to --gpus" claim demo --holder h1 --ttl 5 --gpus 4 --nodes n1=8
bad "a node count of 0" claim demo --holder h1 --ttl 5 --nodes n1=0
bad "an unknown option" claim demo --holder h1 --ttl 5 --force
bad "an unknown verb" grab demo --holder h1 --ttl 5
bad "no verb at all"
bad "an extend with no --ttl" extend demo --holder h1
# a lock file that is not the harness's: an older format, and one that is not JSON - reported, never changed
printf '{"holder": "someone", "claimed_at": "2026-10-15T00:00:00Z", "timeout_minutes": 30, "purpose": "theirs", "queue": []}\n' > "${V}/legacy.json"
printf '{not json\n' > "${V}/broken.json"
cp "${V}/legacy.json" "${D}/legacy-before.json"
cp "${V}/broken.json" "${D}/broken-before.json"
for VERB in "claim legacy --holder h1 --ttl 5" "release legacy --holder someone" "reclaim-stale legacy --by tester" "extend legacy --holder someone --ttl 5" "claim broken --holder h1 --ttl 5"; do
	# shellcheck disable=SC2086
	OUT=$(lk "${V}" ${VERB} 2>&1)
	RC=$?
	[ ${RC} -eq 3 ] || fail "invalid-refused: '${VERB}' on a lock file that is not the harness's exited ${RC}, not 3: ${OUT}"
done
cmp -s "${V}/legacy.json" "${D}/legacy-before.json" && cmp -s "${V}/broken.json" "${D}/broken-before.json" || fail "invalid-refused: a lock file that is not the harness's was changed"
OUT=$(lk "${V}" status 2>&1)
echo "${OUT}" | grep -qF "legacy.json: not a lock file of this harness (holder someone, claimed 2026-10-15T00:00:00Z, timeout 30 min)" \
	&& echo "${OUT}" | grep -qF "broken.json: not readable JSON" || fail "invalid-refused: status does not report the files that are not the harness's: ${OUT}"
# a v1 file with a malformed queue entry, or with no holder field, is not the harness's either: exit 3, unchanged
printf '{"v": 1, "cluster": "mq", "holder": "h1", "session": null, "reason": null, "claimed_at": "2026-10-15T00:00:00Z", "expires_at": "2099-01-01T00:00:00Z", "gpus": null, "nodes": null, "queue": [{"x": 1}], "displaced": []}\n' > "${V}/mq.json"
printf '{"v": 1, "cluster": "nh", "queue": [], "displaced": []}\n' > "${V}/nh.json"
cp "${V}/mq.json" "${D}/mq-before.json"
cp "${V}/nh.json" "${D}/nh-before.json"
for VERB in "claim mq --holder h2 --ttl 5" "release mq --holder h1" "claim nh --holder h1 --ttl 5"; do
	# shellcheck disable=SC2086
	OUT=$(lk "${V}" ${VERB} 2>&1)
	RC=$?
	[ ${RC} -eq 3 ] || fail "invalid-refused: '${VERB}' on a malformed v1 lock file exited ${RC}, not 3: ${OUT}"
done
cmp -s "${V}/mq.json" "${D}/mq-before.json" && cmp -s "${V}/nh.json" "${D}/nh-before.json" || fail "invalid-refused: a malformed v1 lock file was changed"
OUT=$(lk "${V}" status 2>&1) || fail "invalid-refused: status failed on malformed v1 lock files: ${OUT}"
echo "${OUT}" | grep -qF "mq.json: not a lock file of this harness" && echo "${OUT}" | grep -qF "nh.json: not a lock file of this harness" \
	|| fail "invalid-refused: status does not report the malformed v1 lock files: ${OUT}"
echo "ok 7 [invalid-refused] - ${NBAD} malformed requests (seven cluster names, four holders, eight ttls, missing options, node counts, an unknown option, verb and none) exit 3 and write nothing; an older-format, a non-JSON and two malformed v1 lock files are reported by status and never changed (exit 3)"

# --- 8. status ---
S=${D}/status
lk "${S}" claim alpha --holder h1 --ttl 10 --reason "nccl sweep" > /dev/null || fail "status-output: could not claim alpha"
lk "${S}" claim alpha --holder h2 --ttl 10 > /dev/null
lk "${S}" claim beta --holder h1 --ttl 10 > /dev/null && lk "${S}" release beta --holder h1 > /dev/null || fail "status-output: could not claim and release beta"
lk "${S}" claim gamma --holder g1 --ttl 10 --gpus 12 --nodes n1=8,n3=4 > /dev/null || fail "status-output: could not claim gamma with nodes"
plant_expired "${S}" gamma
OUT=$(lk "${S}" status 2>&1) || fail "status-output: status exited non-zero: ${OUT}"
[ "$(echo "${OUT}" | grep -c .)" == "3" ] || fail "status-output: status did not print one line per lock file: ${OUT}"
echo "${OUT}" | grep -qxE "alpha: held by h1 \(session -\) until ${STAMP}, live, the whole cluster, for nccl sweep; queue: h2" || fail "status-output: alpha's line: ${OUT}"
echo "${OUT}" | grep -qxF "beta: free" || fail "status-output: beta's line: ${OUT}"
echo "${OUT}" | grep -qxE "gamma: held by g1 \(session -\) until ${STAMP}, EXPIRED, 12 GPUs on n1=8, n3=4; queue: empty" || fail "status-output: gamma's line: ${OUT}"
[ "$(lk "${S}" status beta 2>&1)" == "beta: free" ] || fail "status-output: status beta did not print only beta's line"
[ "$(lk "${S}" status nosuch 2>&1)" == "nosuch: free (no lock file)" ] || fail "status-output: a cluster with no lock file: $(lk "${S}" status nosuch 2>&1)"
lk "${S}" status --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = {x["cluster"]: x for x in d["locks"]}
assert set(s) == {"alpha", "beta", "gamma"}, s
assert s["alpha"]["state"] == "live" and s["alpha"]["holder"] == "h1" and [e["holder"] for e in s["alpha"]["queue"]] == ["h2"], s["alpha"]
assert s["beta"]["state"] == "free" and s["gamma"]["state"] == "expired" and s["gamma"]["nodes"] == {"n1": 8, "n3": 4}, s
' || fail "status-output: status --json does not carry the documents with their state: $(lk "${S}" status --json 2>&1 | head -c 400)"
OUT=$(lk "${S}" queue list alpha 2>&1)
echo "${OUT}" | grep -qE "^1\. h2 \(session -\), the whole cluster, 10 min, queued ${STAMP}$" || fail "status-output: queue list alpha does not list h2: ${OUT}"
echo "ok 8 [status-output] - one line per lock file (alpha held by h1 for nccl sweep with h2 queued, beta free, gamma EXPIRED with its 12 GPUs on n1=8, n3=4), status <cluster> one, --json the documents with their state, queue list the entries"

# --- 9. run: the job runs while its holder holds the lock, and the lock is released at the end ---
U=${D}/run
mkdir -p "${U}"
OUT=$(CLUSTER_LOCK_DIR=${U} "${CL}" run demo --holder job1 --ttl 5 --reason "planted job" -- bash -c '"$1" status demo > "$2"' _ "${CL}" "${U}/during.txt" 2>"${U}/run.err")
RC=$?
[ ${RC} -eq 0 ] || fail "run-wraps-job: run with a job that exits 0 exited ${RC}: $(cat "${U}/run.err")"
grep -qE "^demo: held by job1 \(session -\) until ${STAMP}, live, the whole cluster, for planted job; queue: empty$" "${U}/during.txt" \
	|| fail "run-wraps-job: while the job ran the lock was not held by its holder: $(cat "${U}/during.txt" 2>&1)"
[ "$(lk "${U}" status demo)" == "demo: free" ] || fail "run-wraps-job: the lock was not released after the job: $(lk "${U}" status demo)"
CLUSTER_LOCK_DIR=${U} "${CL}" run demo --holder job1 --ttl 5 -- bash -c 'exit 7' 2>"${U}/run.err"
RC=$?
[ ${RC} -eq 7 ] || fail "run-wraps-job: a job that exits 7 made run exit ${RC}"
[ "$(lk "${U}" status demo)" == "demo: free" ] || fail "run-wraps-job: the lock was not released after a failing job: $(lk "${U}" status demo)"
# a job that runs past a renewal keeps its lease: run renews it while the job runs (the job waits up to 20 s for
# the renewal: on a loaded host the renewer's claim can start seconds after its interval)
CLUSTER_LOCK_RENEW_SEC=1 CLUSTER_LOCK_DIR=${U} "${CL}" run demo --holder job3 --ttl 5 -- bash -c 'e() { python3 -c "import json, sys; print(json.load(open(sys.argv[1]))[\"expires_at\"])" "$1/demo.json"; }; e "$1" > "$1/first"; for i in $(seq 1 20); do sleep 1; e "$1" > "$1/later"; [ "$(cat "$1/later")" \> "$(cat "$1/first")" ] && break; done; true' _ "${U}" 2>"${U}/run.err" \
	|| fail "run-wraps-job: the renewal run failed: $(cat "${U}/run.err")"
[ -s "${U}/first" ] && [ -s "${U}/later" ] && [ "$(cat "${U}/later")" \> "$(cat "${U}/first")" ] || fail "run-wraps-job: the lease was not renewed within 20 s while the job ran (expires_at $(cat "${U}/first" 2>&1) then $(cat "${U}/later" 2>&1))"
# a run killed before its release (SIGKILL, a container restart) left its lease behind under the same holder name: the
# next run under that name owns the lease - live while its job runs, released at the end - and is not taken for nested
lk "${U}" claim demo --holder gpucheck --ttl 5 > /dev/null || fail "run-wraps-job: could not plant a crashed run's lease"
plant_expired "${U}" demo
CLUSTER_LOCK_DIR=${U} "${CL}" run demo --holder gpucheck --ttl 5 -- bash -c '"$1" status demo > "$2"' _ "${CL}" "${U}/crash-during.txt" 2>"${U}/run.err" \
	|| fail "run-wraps-job: a run after a crashed run failed: $(cat "${U}/run.err")"
grep -qE "^demo: held by gpucheck \(session -\) until ${STAMP}, live, " "${U}/crash-during.txt" \
	|| fail "run-wraps-job: after a crashed run, the new run's job ran on the old expired lease: $(cat "${U}/crash-during.txt")"
[ "$(lk "${U}" status demo)" == "demo: free" ] || fail "run-wraps-job: after a crashed run, the new run under the same holder did not release at the end: $(lk "${U}" status demo)"
# a run inside a run of the same cluster and holder (the outer exports its marker) leaves the release to the outer one
CLUSTER_LOCK_DIR=${U} "${CL}" run demo --holder outer --ttl 5 -- bash -c '"$1" run demo --holder outer --ttl 5 -- true && "$1" status demo > "$2"' _ "${CL}" "${U}/nested.txt" 2>"${U}/run.err" \
	|| fail "run-wraps-job: a nested run failed: $(cat "${U}/run.err")"
grep -qE "^demo: held by outer " "${U}/nested.txt" || fail "run-wraps-job: an inner run of the same holder released the outer run's lease: $(cat "${U}/nested.txt")"
[ "$(lk "${U}" status demo)" == "demo: free" ] || fail "run-wraps-job: the outer run did not release at the end: $(lk "${U}" status demo)"
# the inner run touches nothing of the outer run's lease: an inner --ttl 1 inside an outer --ttl 60 neither shortens
# nor renews it (the outer run's renewer is half an hour away, so a 1-minute lease could be reclaimed under its job)
CLUSTER_LOCK_DIR=${U} "${CL}" run demo --holder outer2 --ttl 60 -- bash -c '"$1" status demo --json > "$2/n-before.json" && "$1" run demo --holder outer2 --ttl 1 -- true && "$1" status demo --json > "$2/n-after.json"' _ "${CL}" "${U}" 2>"${U}/run.err" \
	|| fail "run-wraps-job: a nested run with a shorter ttl failed: $(cat "${U}/run.err")"
python3 - "${U}/n-before.json" "${U}/n-after.json" << 'PY' || fail "run-wraps-job: an inner run with --ttl 1 changed the outer run's 60-minute lease: $(cat "${U}/n-before.json" "${U}/n-after.json")"
import json, sys
b, a = (json.load(open(f))["locks"][0] for f in sys.argv[1:3])
keys = ("holder", "claimed_at", "expires_at", "updated_at")
assert b["holder"] == "outer2" and all(b[k] == a[k] for k in keys), [(k, b.get(k), a.get(k)) for k in keys]
PY
# a marker inherited with no live lease of its holder behind it (no outer run holds it) is not a run inside a run: the
# run claims, renews and releases like any other
CLUSTER_LOCK_RUN=demo/stray CLUSTER_LOCK_DIR=${U} "${CL}" run demo --holder stray --ttl 5 -- bash -c '"$1" status demo > "$2"' _ "${CL}" "${U}/stray.txt" 2>"${U}/run.err" \
	|| fail "run-wraps-job: a run with an inherited marker failed: $(cat "${U}/run.err")"
grep -qE "^demo: held by stray " "${U}/stray.txt" || fail "run-wraps-job: a run with an inherited marker and no outer lease ran its job without the lease: $(cat "${U}/stray.txt")"
[ "$(lk "${U}" status demo)" == "demo: free" ] || fail "run-wraps-job: a run with an inherited marker and no outer lease left its lease held: $(lk "${U}" status demo)"
# run takes the cluster, the holder and the ttl as the claim read them: a zero-padded ttl renews at half of its own
# value (no renewal within the job's 2 s, no error), and options before the cluster still release that cluster
CLUSTER_LOCK_DIR=${U} "${CL}" run demo --holder z1 --ttl 08 -- bash -c 'python3 -c "import json, sys; print(json.load(open(sys.argv[1]))[\"updated_at\"])" "$1/demo.json" > "$1/z-first"; sleep 2; python3 -c "import json, sys; print(json.load(open(sys.argv[1]))[\"updated_at\"])" "$1/demo.json" > "$1/z-later"' _ "${U}" 2>"${U}/run.err" \
	|| fail "run-wraps-job: a run with --ttl 08 failed: $(cat "${U}/run.err")"
grep -qi "error\|too great" "${U}/run.err" && fail "run-wraps-job: a run with --ttl 08 printed an error: $(cat "${U}/run.err")"
[ -s "${U}/z-first" ] && [ "$(cat "${U}/z-first")" == "$(cat "${U}/z-later")" ] || fail "run-wraps-job: a run with --ttl 08 renewed its lease within 2 s (a renewal storm): updated_at $(cat "${U}/z-first" 2>&1) then $(cat "${U}/z-later" 2>&1)"
[ "$(lk "${U}" status demo)" == "demo: free" ] || fail "run-wraps-job: a run with --ttl 08 did not release at the end: $(lk "${U}" status demo)"
CLUSTER_LOCK_DIR=${U} "${CL}" run --holder o1 --ttl 5 demo2 -- true 2>"${U}/run.err" || fail "run-wraps-job: a run with its options before the cluster failed: $(cat "${U}/run.err")"
[ "$(lk "${U}" status demo2)" == "demo2: free" ] || fail "run-wraps-job: a run with its options before the cluster left the lease held: $(lk "${U}" status demo2)"
# run's output can be captured: no renewer is left behind holding the caller's pipe (with a renewal every 60 s, a
# leftover sleep would hold each capture for 60 s). The command lasts a second, so the renewer is inside its sleep
# when run ends; a command that ends at once can end before the renewer has started it, and would not show a leak
for I in 1 2 3; do
	timeout 15 bash -c 'X=$(CLUSTER_LOCK_DIR="$1" CLUSTER_LOCK_RENEW_SEC=60 "$2" run demo --holder q1 --ttl 5 -- sleep 1 2>&1)' _ "${U}" "${CL}" \
		|| fail "run-wraps-job: capturing run's output blocked: a renewer outlived run holding its pipe (try ${I})"
done
# run killed with SIGKILL (no exit trap): its renewer stops at its next turn, so the lease is left to expire
CLUSTER_LOCK_DIR=${U} CLUSTER_LOCK_RENEW_SEC=1 "${CL}" run demo --holder k1 --ttl 5 -- sleep 8 > /dev/null 2>&1 &
RP=$!
sleep 2
kill -9 "${RP}"
wait "${RP}" 2>/dev/null
sleep 1.5
K1=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["updated_at"])' "${U}/demo.json")
sleep 3
K2=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["updated_at"])' "${U}/demo.json")
[ "${K1}" == "${K2}" ] || fail "run-wraps-job: after run was killed with SIGKILL its renewer kept renewing the lease (updated_at ${K1} then ${K2})"
doc "${U}" demo 'd["holder"] == "k1"' || fail "run-wraps-job: the killed run's lease is not k1's: $(cat "${U}/demo.json")"
lk "${U}" release demo --holder k1 > /dev/null
# a renewal refused while the job runs (here the job released the lease itself) is said on stderr, not swallowed
# (the job waits up to 20 s for it)
CLUSTER_LOCK_DIR=${U} CLUSTER_LOCK_RENEW_SEC=1 "${CL}" run demo --holder w7 --ttl 5 -- bash -c '"$1" release demo --holder w7 > /dev/null; for i in $(seq 1 40); do grep -q "could not be renewed" "$2" && break; sleep 0.5; done' _ "${CL}" "${U}/run.err" 2>"${U}/run.err"
grep -q "could not be renewed" "${U}/run.err" || fail "run-wraps-job: a renewal refused while the job ran was silent for 20 s: $(cat "${U}/run.err")"
# held by someone else: the job does not run and nothing is left in the queue
lk "${U}" claim demo --holder other --ttl 5 > /dev/null || fail "run-wraps-job: could not claim demo for another holder"
CLUSTER_LOCK_DIR=${U} "${CL}" run demo --holder job2 --ttl 5 -- touch "${U}/ran" 2>"${U}/run.err"
RC=$?
[ ${RC} -eq 2 ] || fail "run-wraps-job: run on a lock held by someone else exited ${RC}, not 2"
[ -e "${U}/ran" ] && fail "run-wraps-job: the job ran while someone else held the lock"
grep -qE "not run: queued job2 for demo at position 1: held by other until ${STAMP}" "${U}/run.err" || fail "run-wraps-job: run does not say the job did not run: $(cat "${U}/run.err")"
doc "${U}" demo 'd["holder"] == "other" and d["queue"] == []' || fail "run-wraps-job: run left a queue entry behind: $(cat "${U}/demo.json")"
# a queue entry of the holder's from before the run (the hub's queued lease, say) is not the run's to take out: run
# leaves the queue only when its own claim joined it
lk "${U}" claim q5 --holder other5 --ttl 5 > /dev/null || fail "run-wraps-job: could not claim q5 for another holder"
lk "${U}" claim q5 --holder job5 --ttl 5 > /dev/null
CLUSTER_LOCK_DIR=${U} "${CL}" run q5 --holder job5 --ttl 5 -- touch "${U}/ran5" 2>"${U}/run.err"
RC=$?
{ [ ${RC} -eq 2 ] && [ ! -e "${U}/ran5" ]; } || fail "run-wraps-job: run on q5, held by other5, exited ${RC} or ran its job: $(cat "${U}/run.err")"
doc "${U}" q5 'd["holder"] == "other5" and [e["holder"] for e in d["queue"]] == ["job5"]' || fail "run-wraps-job: a run that did not run took out the holder's queue entry from before it: $(cat "${U}/q5.json")"
# a TERM while the claim is being written (the claim holds the file lock 2 s) still releases the lease it took
CLUSTER_LOCK_HOLD_SEC=2 CLUSTER_LOCK_DIR=${U} "${CL}" run tw --holder tw1 --ttl 5 -- sleep 30 > /dev/null 2>&1 &
RP=$!
sleep 1
kill -TERM "${RP}"
wait "${RP}" 2>/dev/null
sleep 3
[ "$(lk "${U}" status tw)" == "tw: free" ] || fail "run-wraps-job: a TERM while the claim was written left its lease held: $(lk "${U}" status tw)"
echo "ok 9 [run-wraps-job] - run held the lock for job1 while the job ran and freed it after (exit 0), passed a failing job's exit 7 through and freed it, renewed job3's lease while it ran ($(cat "${U}/first") then $(cat "${U}/later")), and with the lock held by someone else did not run the job (exit 2) and left no queue entry; after a crashed run the next run under its holder owned the lease and released it; a nested run left the release to the outer one; --ttl 08 and options before the cluster ran clean; three captured runs returned at once; after SIGKILL the renewer stopped; a refused renewal was said on stderr; an inner --ttl 1 run left the outer --ttl 60 lease untouched and a marker with no live lease behind it made an ordinary run; the holder's earlier queue entry outlived a run that did not run; a TERM while the claim was written left no lease"

# --- the bus for checks 10 to 12: a test-local registry with the hub and the clusters spoke under test-local names ---
python3 - "${AGENT_DIR}/spokes/registry.json" "${D}/registry.json" "${D}" << 'PY' || fail "could not write the test registry"
import json, sys
src, dst, d = sys.argv[1:4]
doc = json.load(open(src))
keep = []
for e in doc["sessions"]:
    if e["role"] == "hub":
        keep.append(dict(e, session_name="tkl-hub"))
    elif e["session_name"] == "clusters":
        keep.append(dict(e, session_name="tkl-clusters", flag="SPOKE_TKL_CLUSTERS", workdir=f"{d}/wd/tkl-clusters", parent="tkl-hub"))
json.dump(dict(doc, sessions=keep), open(dst, "w"), indent=1)
PY
BUS_ENV=(SPOKES_REGISTRY="${D}/registry.json" SUPERVISOR_DIR="${D}/sup" MAILBOX_STATE_ROOT="${D}/mailbox-state" MAILBOX_PROJECTION_ROOT="${D}/mailbox"
	AGENT_TMUX_SESSION_NAME=tkl-hub)
J=${D}/mailbox-state/journal/000001.jsonl
W=${D}/wd/tkl-clusters
mkdir -p "${W}"
# ask <json> - the hub's request to the spoke; prints its id
ask() { echo "$1" | env "${BUS_ENV[@]}" BUS_AGENT_ID=tkl-hub "${BUS}" request tkl-clusters; }
# broker - one run of the spoke's broker, as the spoke, in its working directory
broker() { env "${BUS_ENV[@]}" BUS_AGENT_ID=tkl-clusters CLUSTERS_SPOKE_WD="${W}" AGENT_DIR="${AGENT_DIR}" python3 -I "${CH}/broker.py"; }
# answer <id> <python expression over K, the answer's kind, and R, its text as JSON> - exit 0 when the spoke's only
# answer to <id> holds it
answer()
{
	python3 - "${J}" "$1" "$2" << 'PY'
import json, sys
found = []
for l in open(sys.argv[1]):
    e = json.loads(l)
    r = (e.get("details") or {}).get("env") or {}
    if e.get("event") == "message.accepted" and r.get("reply_to") == sys.argv[2]:
        found.append(r)
if len(found) != 1:
    sys.exit(f"{len(found)} answers to {sys.argv[2]}")
r = found[0]
if (r["from"], r["to"]) != ("tkl-clusters", "tkl-hub"):
    sys.exit(f"the answer is from {r['from']} to {r['to']}")
K = r["kind"]
try:
    R = json.loads(r["text"])
except ValueError:
    sys.exit("the answer is not JSON: " + r["text"][:300])
if not eval(sys.argv[3]):
    sys.exit("the answer does not hold: " + r["text"][:700])
PY
}
# view <minutes ago> - the spoke's view as its loop writes status.json: demo with n1 and n2 (8 free each), n3 (4 free)
# and a cordoned n4 (8 allocatable, none usable); an EKS-ARN-named context with e1 (8 free) and e2 (2 free), whose
# rows carry their Kubernetes node names (the other contexts' rows have none, as an older loop wrote them); small (4
# free); late (8 free); gone, unreachable
view()
{
	python3 - "${W}/status.json" "$1" << 'PY' || fail "could not write the planted view"
import json, sys
from datetime import datetime, timedelta, timezone
p, ago = sys.argv[1], int(sys.argv[2])
def row(n, alloc, req, usable=True, k8s=None):
    return {"node": n, "itype": "p5.48xlarge", "ready": "True", "cordon": not usable, "taints": [], "gpu_alloc": alloc, "gpu_req": req,
            "gpu_free": max(alloc - req, 0) if usable else 0, "efa_alloc": 32, "efa_req": 0, "prov": "-", "usable": usable,
            **({"k8s_name": k8s} if k8s else {})}
def ctx(rows):
    return {"reachable": True, "nodes": rows, "gpu_usable_allocatable": sum(r["gpu_alloc"] for r in rows if r["usable"]),
            "gpu_requested": sum(r["gpu_req"] for r in rows), "gpu_free": sum(r["gpu_free"] for r in rows), "top_namespaces": [], "pending_gpu_pods": []}
s = {"generated_utc": (datetime.now(timezone.utc) - timedelta(minutes=ago)).strftime("%Y-%m-%dT%H:%M:%SZ"),
     "contexts": {"demo": ctx([row("n1", 8, 0), row("n2", 8, 0), row("n3", 8, 4), row("n4", 8, 0, usable=False)]),
                  "arn:aws:eks:us-east-1:ACCOUNT:cluster/eks1": ctx([row("e1", 8, 0, k8s="e1.ec2.internal"), row("e2", 8, 6, k8s="e2.ec2.internal")]),
                  "small": ctx([row("s1", 8, 4)]), "late": ctx([row("l1", 8, 0)]), "gone": {"reachable": False},
                  "big": ctx([row(f"b{i:03d}", 8, 0) for i in range(200)])}}
json.dump(s, open(p + ".tmp", "w"), indent=1)
import os
os.replace(p + ".tmp", p)
PY
}

# --- 10. the broker: the hub's gpu-lease requests get leases from the spoke's view ---
Q0=$(ask '{"kind": "gpu-lease", "cluster": "nv", "gpus": 8, "ttl_min": 30, "reason": "before any read"}') || fail "broker-lease: bus.sh request: ${Q0}"
OUT=$(broker 2>&1) || fail "broker-lease: the broker failed with no view: ${OUT}"
A=$(answer "${Q0}" 'K == "reply" and R["kind"] == "gpu-lease" and R["result"] == "granted" and R["cluster"] == "nv" and R["holder"] == "tkl-hub" and R["gpus"] == 8 and R["nodes"] is None and "no cluster view" in R["view"]' 2>&1) \
	|| fail "broker-lease: with no view the lease is not the whole cluster's lock saying so: ${A}"
doc "${W}/locks" nv 'd["holder"] == "tkl-hub" and d["session"] == "tkl-hub" and d["gpus"] == 8 and d["nodes"] is None and d["reason"] == "before any read"' \
	|| fail "broker-lease: the lock file does not hold the lease granted with no view: $(cat "${W}/locks/nv.json" 2>&1)"
view 0
Q1=$(ask '{"kind": "gpu-lease", "cluster": "demo", "gpus": 12, "ttl_min": 30, "reason": "nccl test"}') || fail "broker-lease: bus.sh request: ${Q1}"
Q2=$(ask '{"kind": "gpu-lease", "cluster": "demo", "gpus": 4, "ttl_min": 30, "reason": "second", "holder": "worker-1"}')
Q3=$(ask '{"kind": "gpu-lease", "cluster": "other", "gpus": 2, "ttl_min": 10}')
Q4=$(ask '{"kind": "gpu-lease", "cluster": "eks1", "gpus": 2, "ttl_min": 10}')
Q5=$(ask '{"kind": "gpu-lease", "cluster": "small", "gpus": 8, "ttl_min": 10}')
Q6=$(ask '{"kind": "gpu-lease", "cluster": "gone", "gpus": 1, "ttl_min": 10}')
Q7=$(ask 'which cluster has 8 free GPUs?')
Q8=$(ask '{"kind": "gpu-lease", "cluster": "../x", "gpus": 0, "ttl_min": 30}')
OUT=$(broker 2>&1) || fail "broker-lease: the broker failed: ${OUT}"
A=$(answer "${Q1}" 'K == "reply" and R["result"] == "granted" and R["gpus"] == 12 and R["nodes"] == {"n1": 8, "n3": 4} and R["view"].startswith("the view of ") and R["expires_at"]' 2>&1) \
	|| fail "broker-lease: 12 GPUs are not leased on n1=8 and n3=4 from the view: ${A}"
doc "${W}/locks" demo 'd["holder"] == "tkl-hub" and d["gpus"] == 12 and d["nodes"] == {"n1": 8, "n3": 4} and d["reason"] == "nccl test" and abs(t(d["expires_at"]) - now - 1800) < 60' \
	|| fail "broker-lease: the lock file does not hold the scoped lease: $(cat "${W}/locks/demo.json")"
A=$(answer "${Q2}" 'K == "reply" and R["result"] == "queued" and R["holder"] == "worker-1" and R["position"] == 1 and R["held_by"] == "tkl-hub"' 2>&1) \
	|| fail "broker-lease: a second request for a held cluster is not queued at position 1: ${A}"
A=$(answer "${Q3}" 'K == "reply" and R["result"] == "granted" and R["nodes"] is None and "not one of the contexts" in R["view"]' 2>&1) || fail "broker-lease: a cluster not in the view: ${A}"
A=$(answer "${Q4}" 'K == "reply" and R["result"] == "granted" and R["nodes"] == {"e2.ec2.internal": 2}' 2>&1) || fail "broker-lease: the EKS-ARN-named context's lease is not 2 GPUs on its best-fitting node, named e2.ec2.internal as Kubernetes names it: ${A}"
A=$(answer "${Q5}" 'K == "reply" and R["result"] == "granted" and R["nodes"] is None and "4 free GPUs" in R["view"] and "fewer than 8" in R["view"]' 2>&1) || fail "broker-lease: too few free GPUs: ${A}"
A=$(answer "${Q6}" 'K == "reply" and R["result"] == "granted" and R["nodes"] is None and "unreachable" in R["view"]' 2>&1) || fail "broker-lease: an unreachable context: ${A}"
A=$(answer "${Q8}" 'K == "error" and R["result"] == "invalid" and "cluster" in R["why"]' 2>&1) || fail "broker-lease: a malformed gpu-lease did not get an error: ${A}"
# the cluster '../x' would land above the lock directory, in the spoke's working directory
{ [ -e "${W}/x.json" ] || [ -e "${W}/x.lock" ]; } && fail "broker-lease: a malformed request for '../x' wrote above the lock directory: $(ls -A "${W}" | grep -E '^x[.]' | tr '\n' ' ')"
OPEN=$(env "${BUS_ENV[@]}" BUS_AGENT_ID=tkl-clusters "${BUS}" poll --kind request 2>&1)
[ "${OPEN}" == "${Q7}" ] || fail "broker-lease: the open requests after the broker are '${OPEN}', not only the free-text one (${Q7}) left for the spoke's session"
# a lease over 200 nodes still gets its one answer (the journal line holds at most 2048 bytes): the node list and the
# line naming every node stay in the lock file, and the reply names the file
QB=$(ask '{"kind": "gpu-lease", "cluster": "big", "gpus": 1600, "ttl_min": 10}')
OUT=$(broker 2>&1) || fail "broker-lease: the broker failed on a 200-node lease: ${OUT}"
A=$(answer "${QB}" 'K == "reply" and R["result"] == "granted" and "nodes" not in R and R["nodes_file"].endswith("/big.json") and len(R["line"]) < 300' 2>&1) \
	|| fail "broker-lease: a 200-node lease got no single short answer: ${A}"
doc "${W}/locks" big 'd["holder"] == "tkl-hub" and len(d["nodes"]) == 200 and d["gpus"] == 1600' || fail "broker-lease: the lock file does not hold the 200-node lease"
view 120
Q9=$(ask '{"kind": "gpu-lease", "cluster": "late", "gpus": 4, "ttl_min": 10}')
OUT=$(broker 2>&1) || fail "broker-lease: the broker failed on an old view: ${OUT}"
A=$(answer "${Q9}" 'K == "reply" and R["result"] == "granted" and R["nodes"] is None and "older than 30 minutes" in R["view"]' 2>&1) || fail "broker-lease: a view older than 30 minutes still scoped the lease: ${A}"
echo "ok 10 [broker-lease] - with no view, nv's whole cluster saying so; from the view, demo 12 GPUs on n1=8, n3=4 (never the cordoned n4), eks1 (an EKS-ARN-named context) 2 on e2.ec2.internal (its Kubernetes name); worker-1 queued at position 1; other, small (4 free of 8 asked), gone (unreachable) and late (a view 2 h old) the whole cluster's lock, saying why; the free-text question left open; the malformed request an error, with nothing written above the lock directory; a 1600-GPU lease over 200 nodes one short answer naming the lock file that lists them"

# --- 11. the broker: release, and expiry ---
Q10=$(ask '{"kind": "gpu-release", "cluster": "demo"}')
Q11=$(ask '{"kind": "gpu-release", "cluster": "demo", "holder": "nobody"}')
OUT=$(broker 2>&1) || fail "broker-release-expiry: the broker failed: ${OUT}"
A=$(answer "${Q10}" 'K == "reply" and R["kind"] == "gpu-release" and R["result"] == "released" and R["next_holder"] == "worker-1"' 2>&1) || fail "broker-release-expiry: the hub's release: ${A}"
doc "${W}/locks" demo 'd["holder"] == "worker-1" and d["gpus"] == 4 and d["nodes"] is None and d["queue"] == [] and abs(t(d["expires_at"]) - now - 1800) < 60' \
	|| fail "broker-release-expiry: the queue head does not hold demo after the release: $(cat "${W}/locks/demo.json")"
A=$(answer "${Q11}" 'K == "reply" and R["result"] == "refused" and "held by worker-1, not nobody" in R["line"]' 2>&1) || fail "broker-release-expiry: a release naming someone else: ${A}"
# a lease a job took directly, from another session, is not the hub's to release over the bus; the lease the hub
# asked for on worker-1's behalf (its session is the hub's) is
lk "${W}/locks" claim cl3 --holder job-x --session w-sess --ttl 30 > /dev/null || fail "broker-release-expiry: could not plant a job's own lease"
cp "${W}/locks/cl3.json" "${D}/cl3-before.json"
# nor can the hub take it over by renewing it: its gpu-lease naming job-x is refused, the lock file unchanged
Q11A=$(ask '{"kind": "gpu-lease", "cluster": "cl3", "holder": "job-x", "gpus": 1, "ttl_min": 1}')
Q11B=$(ask '{"kind": "gpu-release", "cluster": "cl3", "holder": "job-x"}')
Q11C=$(ask '{"kind": "gpu-release", "cluster": "demo", "holder": "worker-1"}')
OUT=$(broker 2>&1) || fail "broker-release-expiry: the broker failed on the releases: ${OUT}"
A=$(answer "${Q11A}" 'K == "reply" and R["result"] == "refused" and R["held_by"] == "job-x"' 2>&1) || fail "broker-release-expiry: the hub's gpu-lease naming a lease another session took was not refused: ${A}"
A=$(answer "${Q11B}" 'K == "reply" and R["result"] == "refused"' 2>&1) || fail "broker-release-expiry: the hub's release of a lease another session took was not refused: ${A}"
cmp -s "${W}/locks/cl3.json" "${D}/cl3-before.json" || fail "broker-release-expiry: a refused release changed the job's lease: $(cat "${W}/locks/cl3.json")"
A=$(answer "${Q11C}" 'K == "reply" and R["result"] == "released"' 2>&1) || fail "broker-release-expiry: the hub could not release the lease it asked for on worker-1's behalf: ${A}"
plant_expired "${W}/locks" eks1
OUT=$(broker 2>&1) || fail "broker-release-expiry: the broker failed on an expired lease: ${OUT}"
EXPIRY=${OUT}
echo "${OUT}" | grep -q "1 reclaimed" || fail "broker-release-expiry: the broker's line does not count the reclaimed lease: ${OUT}"
doc "${W}/locks" eks1 'd["holder"] is None and d["displaced"][-1]["holder"] == "tkl-hub" and d["displaced"][-1]["by"] == "tkl-clusters"' \
	|| fail "broker-release-expiry: the expired lease is not reclaimed by the spoke: $(cat "${W}/locks/eks1.json")"
# two broker runs at once (the cycle's and the session's): each claim holds its file lock a second, so without the
# broker's own lock both would poll the request before either answered; it is answered once
Q13=$(ask '{"kind": "gpu-lease", "cluster": "twice", "gpus": 1, "ttl_min": 10}')
for X in a b; do
	env "${BUS_ENV[@]}" BUS_AGENT_ID=tkl-clusters CLUSTERS_SPOKE_WD="${W}" AGENT_DIR="${AGENT_DIR}" CLUSTER_LOCK_HOLD_SEC=1 python3 -I "${CH}/broker.py" > "${D}/broker-${X}.out" 2>&1 &
done
wait
A=$(answer "${Q13}" 'K == "reply" and R["result"] == "granted"' 2>&1) || fail "broker-release-expiry: two broker runs at once did not answer the request exactly once: ${A}"
# a malformed setting and a call that hangs are errors of the run, never a crash: a view age that is not a number is
# named and the default used; a call past CLUSTERS_BROKER_CALL_TIMEOUT_SEC is named and the run ends with exit 1
Q14=$(ask '{"kind": "gpu-lease", "cluster": "agecase", "gpus": 1, "ttl_min": 10}')
OUT=$(env "${BUS_ENV[@]}" BUS_AGENT_ID=tkl-clusters CLUSTERS_SPOKE_WD="${W}" AGENT_DIR="${AGENT_DIR}" CLUSTERS_BROKER_VIEW_MAX_AGE_SEC=abc python3 -I "${CH}/broker.py" 2>&1)
{ echo "${OUT}" | grep -q "CLUSTERS_BROKER_VIEW_MAX_AGE_SEC" && ! echo "${OUT}" | grep -q "Traceback"; } || fail "broker-release-expiry: a view age that is not a number crashed the broker or went unnamed: ${OUT}"
A=$(answer "${Q14}" 'K == "reply" and R["result"] == "granted"' 2>&1) || fail "broker-release-expiry: with a malformed view age the request was not answered: ${A}"
SA=${D}/slow-agent
mkdir -p "${SA}"
ln -s "${CL}" "${SA}/cluster-lock.sh"
printf '#!/bin/bash\ncase "$1" in poll) echo 00000000-0000-4000-8000-000000000000 ;; peek) sleep 5 ;; esac\n' > "${SA}/bus.sh"
chmod +x "${SA}/bus.sh"
OUT=$(env BUS_AGENT_ID=tkl-clusters CLUSTERS_SPOKE_WD="${D}/wd/slow" AGENT_DIR="${SA}" CLUSTERS_BROKER_CALL_TIMEOUT_SEC=1 timeout 30 python3 -I "${CH}/broker.py" 2>&1)
RC=$?
{ [ ${RC} -eq 1 ] && echo "${OUT}" | grep -q "timed out" && ! echo "${OUT}" | grep -q "Traceback"; } || fail "broker-release-expiry: a bus call that hangs is not a named error of the run (rc ${RC}): ${OUT}"
# a request or a view the broker did not write itself cannot crash a run: an envelope that names no sender gets an
# error, a view row with no node name is left out (and named), the rest is answered
OA=${D}/odd-agent
mkdir -p "${OA}" "${D}/wd/odd"
ln -s "${CL}" "${OA}/cluster-lock.sh"
cat > "${OA}/bus.sh" << 'EOF'
#!/bin/bash
case "$1" in
	poll) printf '%s\n' 11111111-0000-4000-8000-000000000001 11111111-0000-4000-8000-000000000002 ;;
	peek)
		case "$2" in
			*1) echo '{"id": "11111111-0000-4000-8000-000000000001", "kind": "request", "text": "{\"kind\": \"gpu-lease\", \"cluster\": \"nosender\", \"gpus\": 1, \"ttl_min\": 5}"}' ;;
			*2) echo '{"id": "11111111-0000-4000-8000-000000000002", "kind": "request", "from": "tkl-hub", "text": "{\"kind\": \"gpu-lease\", \"cluster\": \"nn\", \"gpus\": 8, \"ttl_min\": 5}"}' ;;
		esac ;;
	reply|error) printf '%s %s %s\n' "$1" "$2" "$(cat)" >> "${STUB_BUS_LOG:?}" ;;
esac
EOF
chmod +x "${OA}/bus.sh"
python3 - "${D}/wd/odd/status.json" << 'PY' || fail "could not write the odd view"
import json, sys
from datetime import datetime, timezone
row = lambda **k: dict({"itype": "p5.48xlarge", "ready": "True", "cordon": False, "taints": [], "gpu_alloc": 8, "gpu_req": 0, "gpu_free": 8, "usable": True}, **k)
ctx = {"reachable": True, "nodes": [row(), row(node="n2")]}
json.dump({"generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "contexts": {"nn": ctx}}, open(sys.argv[1], "w"))
PY
OUT=$(env BUS_AGENT_ID=tkl-clusters CLUSTERS_SPOKE_WD="${D}/wd/odd" AGENT_DIR="${OA}" STUB_BUS_LOG="${D}/odd-bus.log" CLUSTER_LOCK_DIR="${D}/wd/odd/locks" timeout 60 python3 -I "${CH}/broker.py" 2>&1)
echo "${OUT}" | grep -q "Traceback" && fail "broker-release-expiry: a request or a view row with a key missing crashed the broker: ${OUT}"
python3 - "${D}/odd-bus.log" << 'PY' || fail "broker-release-expiry: the request with no sender or the view row with no name was not answered as it should be: $(cat "${D}/odd-bus.log" 2>&1); ${OUT}"
import json, sys
got = {}
for line in open(sys.argv[1]):
    verb, mid, text = line.rstrip("\n").split(" ", 2)
    got[mid[-1]] = (verb, json.loads(text))
v1, r1 = got["1"]
v2, r2 = got["2"]
assert v1 == "error" and "sender" in r1["why"], got["1"]
assert v2 == "reply" and r2["result"] == "granted" and r2["nodes"] == {"n2": 8}, got["2"]
PY
echo "${OUT}" | grep -q "no node name" || fail "broker-release-expiry: the view row with no node name was not named: ${OUT}"
# an error reply carries at most 300 characters of why, so it fits the bus: a lease whose 200 node names the lock tool
# refuses gets one short error, not a refusal it would echo node by node
BA=${D}/bad-agent
mkdir -p "${BA}" "${D}/wd/bad"
ln -s "${CL}" "${BA}/cluster-lock.sh"
cat > "${BA}/bus.sh" << 'EOF'
#!/bin/bash
case "$1" in
	poll) echo 22222222-0000-4000-8000-000000000001 ;;
	peek) echo '{"id": "22222222-0000-4000-8000-000000000001", "kind": "request", "from": "tkl-hub", "text": "{\"kind\": \"gpu-lease\", \"cluster\": \"bad\", \"gpus\": 1600, \"ttl_min\": 5}"}' ;;
	reply|error) printf '%s %s %s\n' "$1" "$2" "$(cat)" >> "${STUB_BUS_LOG:?}" ;;
esac
EOF
chmod +x "${BA}/bus.sh"
python3 - "${D}/wd/bad/status.json" << 'PY' || fail "could not write the bad view"
import json, sys
from datetime import datetime, timezone
rows = [{"node": f"b:{i:03d}", "itype": "p5.48xlarge", "ready": "True", "cordon": False, "taints": [], "gpu_alloc": 8, "gpu_req": 0, "gpu_free": 8, "usable": True} for i in range(200)]
json.dump({"generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "contexts": {"bad": {"reachable": True, "nodes": rows}}}, open(sys.argv[1], "w"))
PY
OUT=$(env BUS_AGENT_ID=tkl-clusters CLUSTERS_SPOKE_WD="${D}/wd/bad" AGENT_DIR="${BA}" STUB_BUS_LOG="${D}/bad-bus.log" CLUSTER_LOCK_DIR="${D}/wd/bad/locks" timeout 60 python3 -I "${CH}/broker.py" 2>&1)
python3 - "${D}/bad-bus.log" << 'PY' || fail "broker-release-expiry: the refused 200-node lease did not get one error with at most 300 characters of why: $(cut -c1-300 "${D}/bad-bus.log" 2>&1)"
import json, sys
lines = open(sys.argv[1]).read().splitlines()
verb, mid, text = lines[0].split(" ", 2)
r = json.loads(text)
assert len(lines) == 1 and verb == "error" and r["result"] == "invalid" and 0 < len(r["why"]) <= 300, (len(lines), verb, len(r.get("why", "")))
PY
# a run that cannot take broker.lock within CLUSTERS_BROKER_LOCK_WAIT_SEC answers nothing and says which run holds it
# (here a stand-in that holds it 15 s), rather than waiting out the loop's own timeout
mkdir -p "${D}/wd/held"
python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "a+")
fcntl.flock(f, fcntl.LOCK_EX)
f.seek(0)
f.truncate()
f.write("pid 0 (the test stand-in) since now")
f.flush()
time.sleep(15)' "${D}/wd/held/broker.lock" &
for I in $(seq 1 50); do grep -q "stand-in" "${D}/wd/held/broker.lock" 2>/dev/null && break; sleep 0.1; done
T0=$(date +%s)
OUT=$(env BUS_AGENT_ID=tkl-clusters CLUSTERS_SPOKE_WD="${D}/wd/held" AGENT_DIR="${AGENT_DIR}" CLUSTERS_BROKER_LOCK_WAIT_SEC=1 timeout 12 python3 -I "${CH}/broker.py" 2>&1)
RC=$?
T1=$(date +%s)
{ [ ${RC} -eq 1 ] && echo "${OUT}" | grep -q "the test stand-in" && [ $((T1 - T0)) -le 6 ] && ! echo "${OUT}" | grep -q "Traceback"; } \
	|| fail "broker-release-expiry: a run that could not take broker.lock within 1 s did not end at once naming the run that holds it (rc ${RC}, $((T1 - T0)) s): ${OUT}"
echo "ok 11 [broker-release-expiry] - the hub's gpu-release handed demo to worker-1; a release naming someone else and the hub's release of the lease job-x took from session w-sess were refused, the release the hub asked for on worker-1's behalf went through; the next broker run reclaimed eks1's expired lease ('${EXPIRY}'); two broker runs at once answered a request once; a view age of 'abc' was named and a hung bus call was a named timeout; the hub's gpu-lease renewing job-x's lease was refused, the file unchanged; an envelope with no sender got an error and a view row with no node name was left out and named; a refusal echoing 200 node names became an error with at most 300 characters of why; a run that could not take broker.lock within 1 s ended at once, naming the run that held it"

# --- 12. one cycle of the spoke's loop answers from the view it just read, and STATUS.md lists the lease and the queue ---
cat > "${D}/bin/kubectl" << 'EOF'
#!/bin/bash
case " $* " in
	*" config get-contexts "*) echo 'demo' ;;
	*" get nodes "*) echo '{"items": [{"metadata": {"name": "n1", "labels": {}}, "spec": {}, "status": {"allocatable": {"nvidia.com/gpu": "8"}, "capacity": {"nvidia.com/gpu": "8"}, "conditions": [{"type": "Ready", "status": "True"}]}}, {"metadata": {"name": "n2.ec2.internal", "labels": {}}, "spec": {}, "status": {"allocatable": {"nvidia.com/gpu": "8"}, "capacity": {"nvidia.com/gpu": "8"}, "conditions": [{"type": "Ready", "status": "True"}]}}]}' ;;
	*" get pods "*) cat "${STUB_PODS:?}" ;;
	*) echo '{}' ;;
esac
EOF
chmod +x "${D}/bin/kubectl"
# pods <node> <gpus> - the pod list the stub serves: one pod requesting <gpus> GPUs on <node>
pods() { printf '{"items": [{"metadata": {"namespace": "team-a", "name": "p1"}, "spec": {"nodeName": "%s", "containers": [{"resources": {"requests": {"nvidia.com/gpu": "%s"}}}]}, "status": {"phase": "Running"}}]}\n' "$1" "$2" > "${D}/pods.json"; }
CY=${D}/wd/cycle
mkdir -p "${CY}/locks"
printf '{"v": 1, "cluster": "mq", "holder": "h1", "session": null, "reason": null, "claimed_at": "2026-10-15T00:00:00Z", "expires_at": "2099-01-01T00:00:00Z", "gpus": null, "nodes": null, "queue": [{"x": 1}], "displaced": []}\n' > "${CY}/locks/mq.json"
cycle() { env "${BUS_ENV[@]}" BUS_AGENT_ID=tkl-clusters CLUSTERS_SPOKE_WD="${CY}" AGENT_DIR="${AGENT_DIR}" PATH="${D}/bin:${PATH}" STUB_PODS="${D}/pods.json" bash "${CH}/loop.sh"; }
# the first cycle reads n1 free and n2 half taken; the second reads n1 taken and n2 free, so only its own read leases n2;
# n2 is n2.ec2.internal to Kubernetes, the name a lease must carry (the table shows n2)
pods n2.ec2.internal 4
OUT=$(cycle 2>&1) || fail "cycle-status-notice: the first cycle failed (a malformed v1 lock file is in its directory): ${OUT}"
[ -s "${CY}/notices.jsonl" ] && fail "cycle-status-notice: a first cycle with no lock sent a notice: $(cat "${CY}/notices.jsonl")"
grep -q "^Other lock files there, not this harness's .*mq.json" "${CY}/STATUS.md" || fail "cycle-status-notice: STATUS.md does not report the malformed v1 lock file: $(grep -A3 '## Cluster lock' "${CY}/STATUS.md")"
Q12=$(ask '{"kind": "gpu-lease", "cluster": "demo", "gpus": 8, "ttl_min": 20, "reason": "cycle test"}')
pods n1 8
OUT=$(cycle 2>&1) || fail "cycle-status-notice: the second cycle failed: ${OUT}"
A=$(answer "${Q12}" 'K == "reply" and R["result"] == "granted" and R["nodes"] == {"n2.ec2.internal": 8}' 2>&1) || fail "cycle-status-notice: the cycle did not lease 8 GPUs on n2.ec2.internal from the view it had just read (n1 taken, n2 free): ${A}"
grep -qE "^\| demo \| tkl-hub \| tkl-hub \| 8 GPUs on n2[.]ec2[.]internal=8 \| ${STAMP} \| ${STAMP} \| live \| empty \|$" "${CY}/STATUS.md" \
	|| fail "cycle-status-notice: STATUS.md does not list the lease: $(grep -A6 '## Cluster lock' "${CY}/STATUS.md")"
grep -qxF -- "- LOCK-HOLDER demo free -> tkl-hub" "${CY}/STATUS.md" || fail "cycle-status-notice: STATUS.md's changes do not name the holder change: $(grep -A5 '## Changes' "${CY}/STATUS.md")"
python3 - "${CY}/status.json" "${CY}/notices.jsonl" << 'PY' || fail "cycle-status-notice: status.json or the notices do not carry the lease: $(cat "${CY}/notices.jsonl" 2>&1)"
import json, sys
s = json.load(open(sys.argv[1]))
lk = {x["cluster"]: x for x in s["locks"]}["demo"]
assert lk["holder"] == "tkl-hub" and lk["state"] == "live" and lk["nodes"] == {"n2.ec2.internal": 8} and lk["queue"] == [], lk
rows = s["contexts"]["demo"]["nodes"]
assert [(r["node"], r["k8s_name"]) for r in rows] == [("n1", "n1"), ("n2", "n2.ec2.internal")], rows
n = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
assert len(n) == 1 and n[0]["text"].startswith("lock demo: free -> tkl-hub until "), n
PY
lk "${CY}/locks" claim demo --holder w2 --ttl 10 > /dev/null
[ $? -eq 2 ] || fail "cycle-status-notice: a worker's claim on the leased cluster was not queued"
OUT=$(cycle 2>&1) || fail "cycle-status-notice: the third cycle failed: ${OUT}"
grep -qE "^\| demo \| tkl-hub \| tkl-hub \| 8 GPUs on n2[.]ec2[.]internal=8 \| ${STAMP} \| ${STAMP} \| live \| w2 \|$" "${CY}/STATUS.md" || fail "cycle-status-notice: STATUS.md does not list the queue: $(grep -A6 '## Cluster lock' "${CY}/STATUS.md")"
[ "$(grep -c . "${CY}/notices.jsonl")" == "1" ] || fail "cycle-status-notice: a cycle with no holder change sent a notice: $(tail -2 "${CY}/notices.jsonl")"
# the lease expires: the next cycle's broker reclaims it for the queue head, and the notice names the reclaim
plant_expired "${CY}/locks" demo
OUT=$(cycle 2>&1) || fail "cycle-status-notice: the fourth cycle failed: ${OUT}"
grep -qxF -- "- LOCK-RECLAIMED demo tkl-hub -> w2" "${CY}/STATUS.md" || fail "cycle-status-notice: STATUS.md's changes do not name the reclaim: $(grep -A5 '## Changes' "${CY}/STATUS.md")"
tail -1 "${CY}/notices.jsonl" | grep -q '"lock demo: the lease of tkl-hub expired at [^ ]* and was reclaimed by tkl-clusters; now held by w2 until ' \
	|| fail "cycle-status-notice: the reclaim's notice reads like a release: $(tail -1 "${CY}/notices.jsonl")"
# the status.json the cycle writes before its broker runs keeps the previous cycle's locks, so a cycle that dies after
# it leaves the next one its comparison (a copy of the loop with a stub broker that keeps that file)
CC=${D}/charter-copy
mkdir -p "${CC}"
cp "${CH}/loop.sh" "${CC}/loop.sh"
printf 'import os, shutil\nwd = os.environ["CLUSTERS_SPOKE_WD"]\nshutil.copy(os.path.join(wd, "status.json"), os.path.join(wd, "status-mid.json"))\nprint("broker: stub")\n' > "${CC}/broker.py"
CM=${D}/wd/midcycle
mkdir -p "${CM}"
cp "${CY}/status.json" "${CM}/status.json"
OUT=$(env CLUSTERS_SPOKE_WD="${CM}" PATH="${D}/bin:${PATH}" STUB_PODS="${D}/pods.json" bash "${CC}/loop.sh" 2>&1) || fail "cycle-status-notice: the loop copy failed: ${OUT}"
python3 - "${CY}/status.json" "${CM}/status-mid.json" << 'PY' || fail "cycle-status-notice: the status.json written before the broker has not the previous cycle's locks"
import json, sys
prev, mid = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert "locks" in mid and [x["holder"] for x in mid["locks"]] == [x["holder"] for x in prev["locks"]], mid.get("locks")
PY
echo "ok 12 [cycle-status-notice] - a cycle leased 8 GPUs on n2.ec2.internal (its Kubernetes name; the table shows n2) from the view it had just read (n1 taken since the cycle before); STATUS.md and status.json list the lease, then the queued w2; the holder change was one LOCK-HOLDER notice, and the cycle after it sent none; a malformed v1 lock file was listed with the other files; the expired lease the cycle's broker reclaimed was a LOCK-RECLAIMED change and notice; the status.json written before the broker kept the previous cycle's locks"

# --- 13. the rule: every job that touches a cluster takes a lease first and releases it when it ends ---
RULE='every job that touches a cluster takes a lease'
rule_in() { grep -qiF "${RULE}" "$1" && grep -qF "/agent/cluster-lock.sh" "$1"; }
CHARTER=${CH}/charter.md
RULES=${BASE_DIR%/}/agent-rules/AGENT_RULES.md
DOCS=""
for DC in "${BASE_DIR%/}/../docs" /docs; do [ -f "${DC}/cluster-lock.md" ] && DOCS=${DC} && break; done
[ -n "${DOCS}" ] || fail "rule-named: docs/cluster-lock.md is in neither a checkout nor the image (/docs)"
for F in "${CHARTER}" "${RULES}" "${DOCS}/cluster-lock.md"; do
	rule_in "${F}" || fail "rule-named: ${F} does not say '${RULE} ...' naming /agent/cluster-lock.sh"
	grep -viF "${RULE}" "${F}" > "${D}/no-rule.md"
	rule_in "${D}/no-rule.md" && fail "PLANTED CONTROL: a copy of ${F} without the rule passed"
done
OUT=$("${AGENT_DIR}/spoke.sh" check-charter "${CHARTER}" 2>&1) || fail "rule-named: the clusters charter no longer passes the charter check: ${OUT}"
python3 - "${AGENT_DIR}/spokes/registry.json" << 'PY' || fail "rule-named: the clusters entry does not declare the lock files and the notices it writes"
import json, sys
e = next(x for x in json.load(open(sys.argv[1]))["sessions"] if x["session_name"] == "clusters")
assert "/wd/clusters/locks/" in e["writes"] and "/wd/clusters/notices.jsonl" in e["writes"] and e.get("notices") == "jsonl:notices.jsonl", e
PY
echo "ok 13 [rule-named] - the clusters charter, the operating rules every session loads and docs/cluster-lock.md say '${RULE} ...' and name /agent/cluster-lock.sh (control: a copy without the rule fails); the charter passes the charter check; the registry entry declares the lock files and the notices"

# --- 14. nothing under /wd ---
if [ "${TEST_CONTAINER}" == "true" ]; then
	wd_new() { find /wd -mindepth 1 2>/dev/null | sort | comm -13 "${D}/wd-before.txt" -; }
	NEW=$(wd_new)
	[ -z "${NEW}" ] || fail "this test wrote $(echo "${NEW}" | wc -l) entries under /wd: $(echo "${NEW}" | head -5 | tr '\n' ' ')"
	touch /wd/.test-cluster-lock-planted || fail "PLANTED CONTROL: could not plant an entry under /wd"
	NEW=$(wd_new)
	rm -f /wd/.test-cluster-lock-planted
	[ "${NEW}" == "/wd/.test-cluster-lock-planted" ] || fail "PLANTED CONTROL: the entry planted under /wd is not the one new entry named: '${NEW}'"
	echo "ok 14 - nothing under /wd that was not there when the test started (control: an entry planted there is named)"
fi
echo "Test-cluster-lock succeeded"
