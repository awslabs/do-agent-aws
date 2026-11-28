#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of how often the home page's status dots probe their UIs (/agent/home-render.sh's page script: probe() and
# sweep()). The page's own two functions and the sweep's interval are read from the page as served - site/index.html,
# rendered with the shipped defaults, which the home listener's root location serves as it is - and run in node under
# simulated time against a stand-in fetch that answers at once, after a few seconds or never: every probe failing (a UI
# that is down), every probe answering, or eight tabs sharing a budget of 30 answers a minute (a rate-limited upstream: the
# self-hosted Plane board allows 30 anonymous calls a minute per caller, and the home proxy answers its 429 as a 500).
# Needs node and python3. Fully OFFLINE: no browser, no nginx, no network; test-local state under /tmp/home-probe-test.
#
# Properties proven (each check FAILS if the property is removed):
#   1. home-render.sh and this test parse (bash -n), and so does the page's probe script as served (node --check)
#   2. a UI that is down and fails at once: its tile is probed once every 10 s, 6 times in each of 6 minutes - the 15 s
#      sweep starts no second retry while one is pending (before, one tab's probes grew 16, 40, 64, ... a minute)
#   3. a UI that is down and takes 3 s to fail, so a sweep can start a second probe while one is still out: at most 8
#      probes in any of 6 minutes and at most 2 out at once - only the first failure of such a pair schedules a retry
#   4. a UI that answers after 3 s: 4 probes a minute in each of 6 minutes, the 15 s sweep as before
#   5. eight tabs sharing 30 answers a minute, each after 3 s: no tab probes more than 8 times in any of 10 minutes (one
#      sweep and at most one retry per 15 s; before, the eight tabs' probes climbed every minute)
#   6. the dot of the last of eight tiles that are all down reads "starting" for its first five failures in a row and
#      "down" from the sixth: the count is the tile's own, not its index in the list
#   7. a UI that never answers: each probe is aborted after 8 s and counts as a failure - the dot's first change, to
#      "starting", comes at 8000 ms on the simulated clock, then "starting" four more times and "down" - with at most 2
#      probes out at once and at most 8 a minute (before, every sweep left one more probe hanging: 24 out after 6
#      minutes, and the dot never changed)
#   8. the Learned rules tile's read of its contract never ends, without headers or with headers and no body: it is
#      aborted after 8 s and the tile reads "down" at 8000 ms, with one read a sweep and at most 1 out at once (before,
#      every sweep left one more read hanging)
#   9. PLANTED CONTROLS, run once checks 2-8 pass (a check that fails shows on its own that it can fail): the script
#      without both pending-retry checks climbs past check 2's 6 a minute; without only the failure handler's re-check
#      it climbs past check 3's 8 a minute; with the probe's abort doing nothing it keeps more than 2 probes out; with
#      the probe's abort at 14 s check 7's first change comes at 14000 ms; with the contract read's abort doing nothing
#      it keeps more than 1 read out; with the read's timer cleared at the headers a body that hangs is never aborted

D=/tmp/home-probe-test
rm -rf "${D:?}"
mkdir -p "${D}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"

fail()
{
	echo "Test-home-probe FAILED: $1"
	exit 1
}

# --- 1. syntax ---
bash -n "${AGENT_DIR}/home-render.sh" || fail "bash -n home-render.sh"
bash -n "$0" || fail "bash -n $0"
for TOOL in node python3; do
	if ! command -v "${TOOL}" > /dev/null 2>&1; then
		case "${TOOL}" in
			node) FROM="the image installs it with setup/install-nodejs.sh" ;;
			*) FROM="setup.sh lists it among the commands the image must have" ;;
		esac
		[ "${TEST_CONTAINER}" == "true" ] && fail "${TOOL} is not installed in the test container (${FROM})"
		echo "Test-home-probe skipped: ${TOOL} is not installed"
		exit 0
	fi
done
UI_DIR=${D}/ui UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME=18490 "${AGENT_DIR}/home-render.sh" > ${D}/render.log 2>&1 \
	|| fail "home-render.sh did not render: $(tail -3 ${D}/render.log)"
PAGE=${D}/ui/home/site/index.html
[ -s "${PAGE}" ] || fail "home-render.sh wrote no ${PAGE}"

# the simulator: the page's probe() and sweep() under simulated time. "extract" writes the two functions as the page
# carries them and prints the sweep's interval; "run" sweeps every tab at load and at that interval, as the page does,
# with each tab's own document, fetch, timers and AbortController, its tiles plain dots or, with kind "contract",
# contract tiles (the Learned rules tile, read through readContract() and contract()). The stand-in fetch decides when
# it is called and answers that many ms later through the same timer queue (in mode "hang" never, in "hangbody" with
# headers and no body), so a sweep can come while a probe is out; an abort of the request's signal ends it with an
# AbortError. It prints the requests per tab per minute, the most each tab had out at once, and the dot classes the
# last tile of the first tab went through, with the simulated time of each change
cat > ${D}/probe-sim.js << 'JSEOF'
const fs = require('fs');
const args = process.argv.slice(2);
if (args[0] === 'extract') {
  const html = fs.readFileSync(args[1], 'utf8');
  const fn = (name) => {
    const i = html.indexOf('\nfunction ' + name + '(');
    const j = i < 0 ? -1 : html.indexOf('\n}\n', i);
    if (j < 0) { console.error('the page has no function ' + name + '()'); process.exit(2); }
    return html.slice(i + 1, j + 3);
  };
  const m = html.match(/\nsetInterval\(sweep, (\d+)\);/);
  if (!m) { console.error('the page has no setInterval(sweep, <ms>)'); process.exit(2); }
  fs.writeFileSync(args[2], fn('probe') + fn('readContract') + fn('contract') + fn('sweep'));
  process.stdout.write(m[1] + '\n');
  process.exit(0);
}
const [, script, everyArg, mode, tabsArg, tilesArg, minArg, settleArg, kindArg] = args;
const kind = kindArg || 'probe';
const src = fs.readFileSync(script, 'utf8');
const every = Number(everyArg), tabs = Number(tabsArg), tiles = Number(tilesArg), end = Number(minArg) * 60000;
const settleMs = Number(settleArg);
let now = 0, nextId = 1;
const timers = [], budget = [], calls = [], dots = [], dotTimes = [], out = [], mostOut = [];
const later = (fn, ms, repeat) => { const id = nextId++; timers.push({ id, t: now + ms, fn, repeat }); return id; };
const cancel = (id) => { const i = timers.findIndex((x) => x.id === id); if (i >= 0) timers.splice(i, 1); };
class StandInAbortController {
  constructor() {
    const listeners = [];
    this.signal = { aborted: false, addEventListener: (type, fn) => { if (type === 'abort') listeners.push(fn); } };
    this.notify = () => listeners.forEach((fn) => fn());
  }
  abort() { if (!this.signal.aborted) { this.signal.aborted = true; this.notify(); } }
}
const answers = () => {   // dead and hang: never; up: always; limit30: while fewer than 30 answers fell in the last minute
  if (mode === 'up') return true;
  if (mode !== 'limit30') return false;
  while (budget.length && budget[0] <= now - 60000) budget.shift();
  if (budget.length >= 30) return false;
  budget.push(now);
  return true;
};
for (let tab = 0; tab < tabs; tab++) {
  out.push(0);
  mostOut.push(0);
  const list = [];
  for (let i = 0; i < tiles; i++) {
    let cls = 'dot';
    const watched = tab === 0 && i === tiles - 1;
    const dot = { classList: { contains: () => false } };
    Object.defineProperty(dot, 'className', {
      get: () => cls, set: (v) => { cls = v; if (watched) { dots.push(v); dotTimes.push(now); } } });
    const why = { textContent: '' };
    const dataset = kind === 'contract' ? { contract: '/__tile/tile' + i } : { probe: '/__probe/tile' + i };
    list.push({ dataset, querySelector: (sel) => (sel === '.why' ? why : dot), querySelectorAll: () => [],
      classList: { toggle: () => {} } });
  }
  const fetchStub = (url, opts) => new Promise((resolve, reject) => {
    calls.push({ tab, t: now });
    out[tab] += 1;
    mostOut[tab] = Math.max(mostOut[tab], out[tab]);
    let done = false;
    const finish = (fn) => { if (!done) { done = true; out[tab] -= 1; fn(); } };
    const onAbort = (fn) => { if (opts && opts.signal) opts.signal.addEventListener('abort', fn); };
    const aborted = () => { const e = new Error('aborted'); e.name = 'AbortError'; return e; };
    if (mode === 'hangbody') {   // the headers come at once, the body never: only an abort ends the read, through its body
      resolve({ type: 'basic', status: 200, json: () => new Promise((res, rej) => onAbort(() => finish(() => rej(aborted())))) });
      return;
    }
    onAbort(() => finish(() => reject(aborted())));
    if (mode === 'hang') return;
    const status = answers() ? (kind === 'contract' ? 200 : 204) : 500;
    const body = { schema: 'loglearner-tile/v1', status: 'ok', meta_learner: {} };
    const answer = () => finish(() => resolve({ type: 'basic', status, json: () => Promise.resolve(body) }));
    if (settleMs > 0) later(answer, settleMs, 0); else answer();
  });
  const sweep = new Function('document', 'fetch', 'setTimeout', 'clearTimeout', 'AbortController',
    src + '\nreturn sweep;')({ querySelectorAll: () => list }, fetchStub, (fn, ms) => later(fn, ms, 0), cancel,
    StandInAbortController);
  sweep();
  later(sweep, every, every);
}
(async () => {
  const settle = async () => { for (let i = 0; i < 10; i++) await Promise.resolve(); };
  await settle();
  while (timers.length) {
    timers.sort((a, b) => a.t - b.t || a.id - b.id);
    const tm = timers.shift();
    if (tm.t >= end) break;
    now = tm.t;
    tm.fn();
    if (tm.repeat) later(tm.fn, tm.repeat, tm.repeat);
    await settle();
  }
  const perTab = [];
  for (let tab = 0; tab < tabs; tab++) {
    const row = [];
    for (let m = 0; m * 60000 < end; m++) {
      row.push(calls.filter((c) => c.tab === tab && c.t >= m * 60000 && c.t < (m + 1) * 60000).length);
    }
    perTab.push(row);
  }
  process.stdout.write(JSON.stringify({ per_tab: perTab, most_out: mostOut, dots, dot_times: dotTimes }) + '\n');
})();
JSEOF
EVERY=$(node ${D}/probe-sim.js extract "${PAGE}" ${D}/dots.js 2> ${D}/extract.err) || fail "the page's probe script: $(cat ${D}/extract.err)"
node --check ${D}/dots.js > ${D}/check.err 2>&1 || fail "the page's probe() and sweep(), as served, do not parse: $(head -3 ${D}/check.err)"
[ "${EVERY}" == "15000" ] || fail "the page sweeps every ${EVERY} ms, not every 15000"
echo "ok 1 - syntax: home-render.sh, this test, and the page's probe() and sweep() as served (the sweep every ${EVERY} ms)"

# sim <out.json> <script> <mode> <tabs> <tiles> <minutes> <answer after ms> [contract] - the simulator's JSON for that run,
# written to <out.json> (called in this shell, never in a command substitution, so a failing simulator stops the test)
sim()
{
	node ${D}/probe-sim.js run "$2" "${EVERY}" "$3" "$4" "$5" "$6" "$7" "${8:-probe}" > "$1" 2> ${D}/sim.err || fail "the simulator: $(head -3 ${D}/sim.err)"
}
FIRST_OF='(d["dot_times"] or ["none"])[0]'
# value <variable> <out.json> <python expression over d> - sets <variable> to one value of a run; output the simulator
# did not write stops the test, so it is never read as a probe count
value()
{
	local V
	V=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$2" "$3" 2> ${D}/value.err) \
		|| fail "the simulator's output ${2} is unreadable: $(head -2 ${D}/value.err)"
	printf -v "$1" '%s' "${V}"
}
SERIES_OF='" ".join(map(str, d["per_tab"][0]))'
PROBLEMS=""

# --- 2. a UI that is down and fails at once: one probe every 10 s, never a second retry chain ---
sim ${D}/dead.json ${D}/dots.js dead 1 1 6 0
value SERIES ${D}/dead.json "${SERIES_OF}"
if [ "${SERIES}" == "6 6 6 6 6 6" ]; then
	echo "ok 2 - a UI that is down and fails at once: its tile is probed 6 times a minute in each of 6 minutes (${SERIES})"
else
	PROBLEMS+="check 2: a UI that is down and fails at once is probed [${SERIES}] times a minute, not 6 in each minute; "
fi

# --- 3. a UI that takes 3 s to fail: a sweep's second probe never starts a second retry chain ---
sim ${D}/slow.json ${D}/dots.js dead 1 1 6 3000
value SERIES ${D}/slow.json "${SERIES_OF}"
value MOST ${D}/slow.json 'max(d["per_tab"][0])'
value OUT ${D}/slow.json 'd["most_out"][0]'
if [ "${MOST}" -le 8 ] && [ "${OUT}" -le 2 ]; then
	echo "ok 3 - a UI that takes 3 s to fail: [${SERIES}] probes a minute, at most ${OUT} out at once"
else
	PROBLEMS+="check 3: a UI that takes 3 s to fail is probed [${SERIES}] times a minute with up to ${OUT} out at once, not at most 8 and 2; "
fi

# --- 4. a UI that answers: the 15 s sweep as before ---
sim ${D}/up.json ${D}/dots.js up 1 1 6 3000
value SERIES ${D}/up.json "${SERIES_OF}"
if [ "${SERIES}" == "4 4 4 4 4 4" ]; then
	echo "ok 4 - a UI that answers after 3 s: 4 probes a minute in each of 6 minutes (${SERIES})"
else
	PROBLEMS+="check 4: a UI that answers is probed [${SERIES}] times a minute, not 4 in each minute; "
fi

# --- 5. eight tabs sharing 30 answers a minute: bounded ---
sim ${D}/shared.json ${D}/dots.js limit30 8 1 10 3000
value MOST ${D}/shared.json 'max(max(r) for r in d["per_tab"])'
value TOTALS ${D}/shared.json '" ".join(str(sum(r[m] for r in d["per_tab"])) for m in range(len(d["per_tab"][0])))'
if [ "${MOST}" -le 8 ]; then
	echo "ok 5 - eight tabs sharing 30 answers a minute: at most ${MOST} probes a minute from any tab in 10 minutes (all tabs: ${TOTALS})"
else
	PROBLEMS+="check 5: eight tabs sharing 30 answers a minute: a tab probed ${MOST} times in one minute, more than 8 (all tabs a minute: ${TOTALS}); "
fi

# --- 6. the failure count is the tile's own ---
sim ${D}/count.json ${D}/dots.js dead 1 8 2 0
value DOTS ${D}/count.json '" ".join(c.split()[1] for c in d["dots"][:7])'
if [ "${DOTS}" == "starting starting starting starting starting down down" ]; then
	echo "ok 6 - the 8th of 8 tiles that are down reads starting for its first five failures, then down (${DOTS})"
else
	PROBLEMS+="check 6: the 8th of 8 tiles that are down read [${DOTS}] over its first seven failures, not starting five times and then down; "
fi

# --- 7. a UI that never answers: the abort after 8 s ends each probe and counts ---
sim ${D}/hang.json ${D}/dots.js hang 1 1 6 0
value SERIES ${D}/hang.json "${SERIES_OF}"
value MOST ${D}/hang.json 'max(d["per_tab"][0])'
value OUT ${D}/hang.json 'd["most_out"][0]'
value DOTS ${D}/hang.json '" ".join(c.split()[1] for c in d["dots"][:7])'
value FIRST ${D}/hang.json "${FIRST_OF}"
if [ "${FIRST}" == "8000" ] && [ "${DOTS}" == "starting starting starting starting starting down down" ] && [ "${OUT}" -le 2 ] && [ "${MOST}" -le 8 ]; then
	echo "ok 7 - a UI that never answers: each probe aborted after 8 s counts (the first change at ${FIRST} ms; ${DOTS}), [${SERIES}] probes a minute, at most ${OUT} out at once"
else
	PROBLEMS+="check 7: a UI that never answers: its dot first changed at [${FIRST}] ms (want 8000) and read [${DOTS}] (want starting five times, then down), [${SERIES}] probes a minute with up to ${OUT} out at once, not at most 8 and 2; "
fi

# --- 8. the Learned rules tile's contract read that never ends: aborted after 8 s, the tile reads down ---
for HOW in hang hangbody; do
	sim ${D}/contract-${HOW}.json ${D}/dots.js "${HOW}" 1 1 6 0 contract
	value SERIES ${D}/contract-${HOW}.json "${SERIES_OF}"
	value OUT ${D}/contract-${HOW}.json 'd["most_out"][0]'
	value FIRST ${D}/contract-${HOW}.json "${FIRST_OF}"
	value DOTS ${D}/contract-${HOW}.json '" ".join(c.split()[1] for c in d["dots"][:3])'
	if [ "${FIRST}" == "8000" ] && [ "${DOTS}" == "down down down" ] && [ "${OUT}" -le 1 ] && [ "${SERIES}" == "4 4 4 4 4 4" ]; then
		echo "ok 8 - the Learned rules tile's read that never ends (${HOW}): aborted at ${FIRST} ms, the tile reads ${DOTS}, [${SERIES}] reads a minute, at most ${OUT} out at once"
	else
		PROBLEMS+="check 8: the Learned rules tile's read that never ends (${HOW}): its first change at [${FIRST}] ms (want 8000), the tile read [${DOTS}] (want down), [${SERIES}] reads a minute with up to ${OUT} out at once (want 4 a minute, at most 1); "
	fi
done

[ -z "${PROBLEMS}" ] || fail "${PROBLEMS}"

# --- 9. planted controls: each guard removed or moved, its check fails ---
python3 - ${D}/dots.js ${D}/mutant << 'PY' || fail "PLANTED CONTROL BROKEN: the pending-retry checks or the aborts are not where the controls expect them"
import os, sys
s = open(sys.argv[1]).read()
inner, outer = "\n    if (el.probeRetryPending) return;\n", "\n  if (el.probeRetryPending) return;\n"
probe_abort = "ctl.abort(); }, 8000) : null;\n  fetch(url, "
read_abort = "ctl.abort(); }, 8000) : null;\n  fetch(el.dataset.contract, "
read_then = "signal: ctl ? ctl.signal : undefined }).then(function (r) {\n    if (r.status !== 200)"
for anchor in (inner, outer, probe_abort, read_abort, read_then):
    assert s.count(anchor) == 1, anchor
os.makedirs(sys.argv[2], exist_ok=True)
plants = {
    "unguarded": s.replace(inner, "\n").replace(outer, "\n"),
    "no-recheck": s.replace(inner, "\n"),
    "no-abort": s.replace(probe_abort, probe_abort.replace("ctl.abort();", "")),
    "abort14": s.replace(probe_abort, probe_abort.replace("8000", "14000")),
    "read-no-abort": s.replace(read_abort, read_abort.replace("ctl.abort();", "")),
    "read-clear-at-headers": s.replace(read_then, read_then.replace("{\n    if", "{\n    clearTimeout(limit);\n    if")),
}
for name, text in plants.items():
    assert text != s, name
    open(os.path.join(sys.argv[2], name + ".js"), "w").write(text)
PY
sim ${D}/unguarded.json ${D}/mutant/unguarded.js dead 1 1 6 0
value CLIMB ${D}/unguarded.json "${SERIES_OF}"
[ "${CLIMB##* }" -gt 6 ] || fail "PLANTED CONTROL BROKEN: without both pending-retry checks a UI that fails at once was probed [${CLIMB}] times a minute"
sim ${D}/no-recheck.json ${D}/mutant/no-recheck.js dead 1 1 6 3000
value CLIMB2 ${D}/no-recheck.json "${SERIES_OF}"
value MOST ${D}/no-recheck.json 'max(d["per_tab"][0])'
[ "${MOST}" -gt 8 ] || fail "PLANTED CONTROL BROKEN: without the failure handler's re-check a UI that takes 3 s to fail was probed [${CLIMB2}] times a minute"
sim ${D}/no-abort.json ${D}/mutant/no-abort.js hang 1 1 6 0
value OUT ${D}/no-abort.json 'd["most_out"][0]'
[ "${OUT}" -gt 2 ] || fail "PLANTED CONTROL BROKEN: with an abort that does nothing a UI that never answers had at most ${OUT} probes out at once"
sim ${D}/abort14.json ${D}/mutant/abort14.js hang 1 1 2 0
value LATE ${D}/abort14.json "${FIRST_OF}"
[ "${LATE}" != "8000" ] || fail "PLANTED CONTROL BROKEN: with the probe's abort at 14 s the dot still first changed at 8000 ms"
sim ${D}/read-no-abort.json ${D}/mutant/read-no-abort.js hang 1 1 6 0 contract
value ROUT ${D}/read-no-abort.json 'd["most_out"][0]'
[ "${ROUT}" -gt 1 ] || fail "PLANTED CONTROL BROKEN: with the contract read's abort doing nothing at most ${ROUT} read was out at once"
sim ${D}/read-early.json ${D}/mutant/read-clear-at-headers.js hangbody 1 1 2 0 contract
value EARLY ${D}/read-early.json "${FIRST_OF}"
[ "${EARLY}" != "8000" ] || fail "PLANTED CONTROL BROKEN: with the read's timer cleared at the headers a body that hangs was still aborted at 8000 ms"
echo "ok 9 - planted controls: without both pending-retry checks a UI that fails at once is probed [${CLIMB}] times a minute; without the failure handler's re-check one that takes 3 s to fail is probed [${CLIMB2}]; with an abort that does nothing ${OUT} probes are out at once; with the abort at 14 s the first change comes at ${LATE} ms; with the contract read's abort doing nothing ${ROUT} reads are out at once; with its timer cleared at the headers a hanging body is never aborted (first change: ${EARLY})"
echo "Test-home-probe succeeded"
