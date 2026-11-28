#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the home page's Memory tile note (/agent/home-render.sh's page script: memoryState()), which reads the
# seed's state at /__seed-state, then the bank list and every bank's counts through /memory-api/, at load and once a
# minute. The page's own function, its load-time call and its interval are read from the page as served -
# site/index.html, rendered with the shipped defaults, which the home listener's root location serves as it is - and
# run in node under simulated time against a stand-in fetch whose /memory-api/ answers, never answers, answers with
# headers and no body, answers an error whose body stalls, leaves the banks' counts hanging (all of them or one),
# answers an empty bank list or one the page cannot read, or is missing (calling fetch throws). An error the page throws
# or leaves unhandled stops every run but the two that cause one on purpose. Needs node and python3. Fully OFFLINE: no
# browser, no nginx, no network; test-local state under /tmp/home-memory-note-test.
#
# Properties proven (each check FAILS if the property is removed):
#   1. home-render.sh and this test parse (bash -n), and so does the page's memoryState() as served (node --check);
#      the page calls it at load and every 60 s
#   2. a memory API that answers: the note reads its counts, not styled as a warning and with no mark on the dot, 3
#      passes in 3 minutes (one at load)
#   3. a memory API that never answers: the read gives up at 8000 ms on the simulated clock and the note says the API
#      did not answer, styled as a warning, with at most 1 request to it out at once in 10 minutes (before, one more
#      each minute: 10)
#   4. the same with headers and no body: the body is cut at 8000 ms too
#   5. a browser with no AbortController and a memory API that never answers: a minute's pass is skipped while the last
#      one reads, so at most 1 request is out at once in 10 minutes
#   6. four banks whose counts never answer: at most 4 requests out at once in 10 minutes, the bank count, and at 8000
#      ms the note says the API did not answer for 4 of 4 banks; with one bank, "1 of 1 bank"
#   7. four banks, one of whose counts never answers: at 8000 ms the note names it ("1 of 4 banks did not answer"),
#      styled as a warning
#   8. an error answer whose body stalls: the read ends at once (the note changes at 0 ms) and at most 1 request is out
#      in 10 minutes (before, the unread body stayed open: one more each minute)
#   9. a bank list the page cannot read, so the pass throws: the error still reaches the console (an unhandled
#      rejection) and the next minutes' passes still run
#  10. an empty bank list (the seed can be off): the note reads "memory: no banks yet", neutral, no mark on the dot
#  11. a browser where calling fetch throws at once: each minute's pass still starts (3 errors in 3 minutes), because the
#      pass starts inside its promise chain and the error clears the pending flag
#  12. a bank with 3 failed operations (two refreshes of a knowledge page that failed for one reason, a retain for another)
#      and the session guard's counts: the note names the count and both reasons, the most frequent first, adds what the
#      guard did (records set aside by reason, claims marked, a page refresh paused), styled as a warning, the dot warned
#  13. the guard's counts with no failed operation: the note adds them and stays neutral; with neither (check 2) the note
#      is the counts alone
#  14. PLANTED CONTROLS, run once checks 2-13 pass (a check that fails shows on its own that it can fail): without the
#      pending flag check 5 keeps more than 1 request out; with the read's abort doing nothing check 3's note never
#      changes; with an error handler that only clears the flag check 9's error does not reach the console, and with
#      none the next pass never runs; without the abort after a read check 8 keeps more than 1 request out; a page
#      without the load-time call has 2 passes in check 2's 3 minutes; a pass started outside its chain leaves check
#      11 with 1 error in 3 minutes; a pass that throws while the API answers stops the simulator's run (exit 3)

D=/tmp/home-memory-note-test
rm -rf "${D:?}"
mkdir -p "${D}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"

fail()
{
	echo "Test-home-memory-note FAILED: $1"
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
		echo "Test-home-memory-note skipped: ${TOOL} is not installed"
		exit 0
	fi
done
UI_DIR=${D}/ui UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME=18489 "${AGENT_DIR}/home-render.sh" > ${D}/render.log 2>&1 \
	|| fail "home-render.sh did not render: $(tail -3 ${D}/render.log)"
PAGE=${D}/ui/home/site/index.html
[ -s "${PAGE}" ] || fail "home-render.sh wrote no ${PAGE}"

# the simulator: the page's memoryState() under simulated time. "extract" writes the function as the page carries it
# and prints its interval and whether the page calls it at load; "run" calls it at load (when the page does) and at
# that interval, with a stand-in document, fetch, timers and (unless told "none") AbortController. /__seed-state
# answers at once; /memory-api/ follows the mode: up, hang (never), hangbody (headers, no body), errbody (an error
# whose body stalls), stats-hang (the bank list answers, no bank's counts do), one-stats-hang (only the last bank's
# counts hang), empty (an empty bank list), notarray (a bank list the page cannot read) or nofetch (fetch is missing).
# A request is out until its body ends or it is aborted. It prints the /memory-api/ requests and the passes (seed
# reads) per minute, the most requests out at once, every text the note was given with its time, class and the dot's
# warning, and the errors the page left unhandled or threw; outside notarray and nofetch any such error fails the run
cat > ${D}/note-sim.js << 'JSEOF'
const fs = require('fs');
const args = process.argv.slice(2);
if (args[0] === 'extract') {
  const html = fs.readFileSync(args[1], 'utf8');
  const i = html.indexOf('\nfunction memoryState(');
  const j = i < 0 ? -1 : html.indexOf('\n}\n', i);
  if (j < 0) { console.error('the page has no function memoryState()'); process.exit(2); }
  const m = html.match(/\nsetInterval\(memoryState, (\d+)\);/);
  if (!m) { console.error('the page has no setInterval(memoryState, <ms>)'); process.exit(2); }
  fs.writeFileSync(args[2], html.slice(i + 1, j + 3));
  process.stdout.write(m[1] + ' ' + (/\nmemoryState\(\);\n/.test(html) ? 'load' : 'noload') + '\n');
  process.exit(0);
}
const [, script, everyArg, loadArg, mode, minArg, banksArg, abortArg] = args;
const src = fs.readFileSync(script, 'utf8');
const every = Number(everyArg), end = Number(minArg) * 60000, banks = Number(banksArg);
let now = 0, nextId = 1, out = 0, mostOut = 0, text = '', cls = 'memory', warn = false;
const timers = [], calls = [], passes = [], notes = [], rejections = [], thrown = [];
// mode failed: one bank's failed operations as the memory API lists them; modes failed and guard: the session guard's counts
const refresh = 'MentalModelRefreshError: Refresh failed for mental_model_id=mm-1: delta operations did not reach the document, and the reflect candidate covers only memories newer than the last refresh.';
const FAILED = [{ task_type: 'refresh_mental_model', error_message: refresh }, { task_type: 'refresh_mental_model', error_message: refresh },
  { task_type: 'retain', error_message: 'ThrottlingException: An error occurred (ThrottlingException) when calling the Converse operation: Too many requests' }];
const GUARD = 'updated_at=2026-10-15T12:00:00Z\nlanguage=en\nbanks=bank1\nfailed_logged=3\nretried=1\npaused_pages=1\nrejected_language=1\nrejected_duplicate=1\nrejected_marker=0\nclaims_marked=2\napi_errors=0\n';
process.on('unhandledRejection', (e) => rejections.push(String(e && e.message)));
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
const dot = { classList: { add: (c) => { if (c === 'warn') warn = true; }, remove: (c) => { if (c === 'warn') warn = false; } } };
const el = { parentNode: { querySelector: () => dot } };
Object.defineProperty(el, 'className', { get: () => cls, set: (v) => { cls = v; } });
Object.defineProperty(el, 'textContent', { get: () => text, set: (v) => { text = v; notes.push({ t: now, text: v, cls, warn }); } });
const documentStub = { getElementById: (id) => (id === 'memory-state' ? el : null) };
const aborted = () => { const e = new Error('aborted'); e.name = 'AbortError'; return e; };
const never = () => new Promise(() => {});
const fetchStub = (url, opts) => new Promise((resolve, reject) => {
  const onAbort = (fn) => { if (opts && opts.signal) opts.signal.addEventListener('abort', fn); };
  if (url === '/__memory-guard') {   // the session guard's counts, served by nginx itself: 404 until the guard wrote them
    const g = (mode === 'failed' || mode === 'guard') ? GUARD : null;
    return resolve({ ok: !!g, status: g ? 200 : 404, text: () => Promise.resolve(g || ''), json: () => Promise.resolve({}) });
  }
  if (!url.startsWith('/memory-api/')) {   // the seed's state file, served by nginx itself: one per pass
    passes.push(now);
    return resolve({ ok: true, status: 200, text: () => Promise.resolve('state=done\n'), json: () => Promise.resolve({}) });
  }
  calls.push(now);
  out += 1;
  mostOut = Math.max(mostOut, out);
  let done = false;
  const finish = (fn) => { if (!done) { done = true; out -= 1; fn(); } };
  const stats = url.includes('/stats');
  const hangs = mode === 'hang' || (mode === 'stats-hang' && stats)
    || (mode === 'one-stats-hang' && stats && url.includes('/bank' + banks + '/'));
  if (mode === 'hangbody' || mode === 'errbody') {   // headers now, a body that never comes: out until an abort,
    let failBody = null;                               // which also fails a body read the page has started
    onAbort(() => finish(() => { if (failBody) failBody(aborted()); }));
    resolve({ ok: mode === 'hangbody', status: mode === 'hangbody' ? 200 : 500,
      json: () => new Promise((res, rej) => { failBody = rej; }), text: never });
    return;
  }
  onAbort(() => finish(() => reject(aborted())));
  if (hangs) return;
  const list = { banks: Array.from({ length: banks }, (x, k) => ({ bank_id: 'bank' + (k + 1) })) };
  const listed = mode === 'notarray' ? { banks: 1 } : (mode === 'empty' ? { banks: [] } : list);
  const failedOps = url.includes('/operations?status=failed');
  const body = stats ? { total_documents: 3, pending_operations: 0, failed_operations: mode === 'failed' ? FAILED.length : 0 }
    : (failedOps ? { operations: FAILED } : listed);
  finish(() => resolve({ ok: true, status: 200, json: () => Promise.resolve(body), text: () => Promise.resolve('') }));
});
const memoryState = new Function('document', 'fetch', 'setTimeout', 'clearTimeout', 'AbortController',
  src + '\nreturn memoryState;')(documentStub, mode === 'nofetch' ? undefined : fetchStub, (fn, ms) => later(fn, ms, 0), cancel,
  abortArg === 'none' ? undefined : StandInAbortController);
const call = (fn) => { try { fn(); } catch (e) { thrown.push(String(e && e.message)); } };   // a timer callback that throws
if (loadArg === 'load') call(memoryState);
later(memoryState, every, every);
(async () => {
  // one turn of node's event loop runs every queued microtask, however deep the page's promise chains go
  const settle = () => new Promise((resolve) => setImmediate(resolve));
  await settle();
  while (timers.length) {
    timers.sort((a, b) => a.t - b.t || a.id - b.id);
    const tm = timers.shift();
    if (tm.t >= end) break;
    now = tm.t;
    call(tm.fn);
    if (tm.repeat) later(tm.fn, tm.repeat, tm.repeat);
    await settle();
  }
  const perMinute = (times) => Array.from({ length: Math.ceil(end / 60000) }, (x, m) => times.filter((t) => t >= m * 60000 && t < (m + 1) * 60000).length);
  if ((rejections.length || thrown.length) && mode !== 'notarray' && mode !== 'nofetch') {
    console.error('mode ' + mode + ': the page left ' + rejections.length + ' errors unhandled and threw ' + thrown.length + ': ' + rejections.concat(thrown).join('; '));
    process.exit(3);
  }
  process.stdout.write(JSON.stringify({ per_minute: perMinute(calls), passes_per_minute: perMinute(passes), most_out: mostOut,
    notes, rejections: rejections.length, thrown: thrown.length }) + '\n');
})();
JSEOF
read -r EVERY LOAD < <(node ${D}/note-sim.js extract "${PAGE}" ${D}/note.js 2> ${D}/extract.err) || fail "the page's note script: $(cat ${D}/extract.err)"
node --check ${D}/note.js > ${D}/check.err 2>&1 || fail "the page's memoryState(), as served, does not parse: $(head -3 ${D}/check.err)"
{ [ "${EVERY}" == "60000" ] && [ "${LOAD}" == "load" ]; } || fail "the page reads the note every [${EVERY}] ms and [${LOAD}], not every 60000 ms and at load"
echo "ok 1 - syntax: home-render.sh, this test, and the page's memoryState() as served (at load and every ${EVERY} ms)"

# sim <out.json> <script> <mode> <minutes> [banks] [with|none] [load|noload] - the simulator's JSON for that run,
# written to <out.json> (called in this shell, never in a command substitution, so a failing simulator stops the test)
sim()
{
	node ${D}/note-sim.js run "$2" "${EVERY}" "${7:-${LOAD}}" "$3" "$4" "${5:-1}" "${6:-with}" > "$1" 2> ${D}/sim.err \
		|| fail "the simulator: $(head -3 ${D}/sim.err)"
}
# value <variable> <out.json> <python expression over d> - sets <variable> to one value of a run; output the simulator
# did not write stops the test, so it is never read as a count
value()
{
	local V
	V=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$2" "$3" 2> ${D}/value.err) \
		|| fail "the simulator's output ${2} is unreadable: $(head -2 ${D}/value.err)"
	printf -v "$1" '%s' "${V}"
}
NOTE='(d["notes"] or [{"t": "none", "text": "none", "cls": "none", "warn": "none"}])[0]'
SERIES_OF='" ".join(map(str, d["per_minute"]))'
PROBLEMS=""

# --- 2. a memory API that answers: the counts, one pass at load and one a minute ---
sim ${D}/up.json ${D}/note.js up 3
value TEXT ${D}/up.json "${NOTE}[\"text\"]"
value CLS ${D}/up.json "${NOTE}[\"cls\"]"
value WARN ${D}/up.json "${NOTE}[\"warn\"]"
value PASSES ${D}/up.json 'sum(d["passes_per_minute"])'
if [ "${TEXT}" == "memory: 3 documents in 1 bank" ] && [ "${CLS}" == "memory" ] && [ "${WARN}" == "False" ] && [ "${PASSES}" == "3" ]; then
	echo "ok 2 - a memory API that answers: the note reads '${TEXT}' (class ${CLS}, no mark on the dot), ${PASSES} passes in 3 minutes"
else
	PROBLEMS+="check 2: a memory API that answers: the note read '${TEXT}' (class ${CLS}, dot warning ${WARN}) after ${PASSES} passes in 3 minutes (want its counts, class memory, no mark, 3 passes); "
fi

# --- 3. and 4. a memory API that never answers, or answers with headers and no body: cut at 8 s, a warning ---
CHECK=3
for HOW in hang hangbody; do
	case "${HOW}" in hang) WHAT="never answers" ;; *) WHAT="answers with headers and no body" ;; esac
	sim ${D}/${HOW}.json ${D}/note.js "${HOW}" 10
	value FIRST ${D}/${HOW}.json "${NOTE}[\"t\"]"
	value TEXT ${D}/${HOW}.json "${NOTE}[\"text\"]"
	value CLS ${D}/${HOW}.json "${NOTE}[\"cls\"]"
	value WARN ${D}/${HOW}.json "${NOTE}[\"warn\"]"
	value OUT ${D}/${HOW}.json 'd["most_out"]'
	if [ "${FIRST}" == "8000" ] && [ "${TEXT}" == "memory: the API did not answer" ] && [ "${CLS}" == "memory warn" ] && [ "${WARN}" == "True" ] && [ "${OUT}" -le 1 ]; then
		echo "ok ${CHECK} - a memory API that ${WHAT}: at ${FIRST} ms the note says '${TEXT}' (class ${CLS}, the dot warned), at most ${OUT} out at once in 10 minutes"
	else
		PROBLEMS+="check ${CHECK}: a memory API that ${WHAT}: the note first changed at [${FIRST}] ms to '${TEXT}' (class ${CLS}, dot warning ${WARN}) with up to ${OUT} requests out at once (want 8000, the API did not answer, memory warn, warned, at most 1); "
	fi
	CHECK=4
done

# --- 5. no AbortController: a minute's pass is skipped while the last one reads ---
sim ${D}/noabort.json ${D}/note.js hang 10 1 none
value OUT ${D}/noabort.json 'd["most_out"]'
value SERIES ${D}/noabort.json "${SERIES_OF}"
if [ "${OUT}" -le 1 ]; then
	echo "ok 5 - no AbortController and a memory API that never answers: at most ${OUT} request out at once in 10 minutes ([${SERIES}] a minute)"
else
	PROBLEMS+="check 5: no AbortController and a memory API that never answers: ${OUT} requests out at once after 10 minutes (want at most 1), [${SERIES}] a minute; "
fi

# --- 6. banks whose counts never answer: one pass's reads, one per bank ---
for BANKS in 4 1; do
	case "${BANKS}" in 1) WANT="memory: the API did not answer (1 of 1 bank)" ;; *) WANT="memory: the API did not answer (${BANKS} of ${BANKS} banks)" ;; esac
	sim ${D}/stats-hang-${BANKS}.json ${D}/note.js stats-hang 10 "${BANKS}"
	value OUT ${D}/stats-hang-${BANKS}.json 'd["most_out"]'
	value FIRST ${D}/stats-hang-${BANKS}.json "${NOTE}[\"t\"]"
	value TEXT ${D}/stats-hang-${BANKS}.json "${NOTE}[\"text\"]"
	if [ "${OUT}" -le "${BANKS}" ] && [ "${FIRST}" == "8000" ] && [ "${TEXT}" == "${WANT}" ]; then
		echo "ok 6 - ${BANKS} bank(s) whose counts never answer: at most ${OUT} requests out at once in 10 minutes, at ${FIRST} ms '${TEXT}'"
	else
		PROBLEMS+="check 6: ${BANKS} bank(s) whose counts never answer: up to ${OUT} requests out at once (want at most ${BANKS}), the note at [${FIRST}] ms '${TEXT}' (want 8000 and '${WANT}'); "
	fi
done

# --- 7. four banks, one of whose counts never answers: named in the note ---
sim ${D}/one-stats.json ${D}/note.js one-stats-hang 2 4
value FIRST ${D}/one-stats.json "${NOTE}[\"t\"]"
value TEXT ${D}/one-stats.json "${NOTE}[\"text\"]"
value CLS ${D}/one-stats.json "${NOTE}[\"cls\"]"
if [ "${FIRST}" == "8000" ] && [ "${TEXT}" == "memory: 9 documents in 3 banks, 1 of 4 banks did not answer" ] && [ "${CLS}" == "memory warn" ]; then
	echo "ok 7 - four banks, one of whose counts never answers: at ${FIRST} ms '${TEXT}' (class ${CLS})"
else
	PROBLEMS+="check 7: four banks, one of whose counts never answers: the note at [${FIRST}] ms '${TEXT}' (class ${CLS}; want 8000, 9 documents in 3 banks and 1 of 4 banks did not answer, memory warn); "
fi

# --- 8. an error answer whose body stalls: the read ends at once ---
sim ${D}/errbody.json ${D}/note.js errbody 10
value OUT ${D}/errbody.json 'd["most_out"]'
value FIRST ${D}/errbody.json "${NOTE}[\"t\"]"
if [ "${OUT}" -le 1 ] && [ "${FIRST}" == "0" ]; then
	echo "ok 8 - an error answer whose body stalls: the note changes at ${FIRST} ms, at most ${OUT} request out at once in 10 minutes"
else
	PROBLEMS+="check 8: an error answer whose body stalls: ${OUT} requests out at once after 10 minutes (want at most 1), the note first at [${FIRST}] ms (want 0); "
fi

# --- 9. a pass that throws: the error reaches the console, the next passes run ---
sim ${D}/notarray.json ${D}/note.js notarray 3
value REJ ${D}/notarray.json 'd["rejections"]'
value PASSES ${D}/notarray.json 'sum(d["passes_per_minute"])'
if [ "${REJ}" -ge 1 ] && [ "${PASSES}" == "3" ]; then
	echo "ok 9 - a bank list the page cannot read: ${REJ} errors reach the console and ${PASSES} passes run in 3 minutes"
else
	PROBLEMS+="check 9: a bank list the page cannot read: ${REJ} errors reached the console (want at least 1) and ${PASSES} passes ran in 3 minutes (want 3); "
fi

# --- 10. an empty bank list: neutral ---
sim ${D}/empty.json ${D}/note.js empty 2
value TEXT ${D}/empty.json "${NOTE}[\"text\"]"
value CLS ${D}/empty.json "${NOTE}[\"cls\"]"
value WARN ${D}/empty.json "${NOTE}[\"warn\"]"
if [ "${TEXT}" == "memory: no banks yet" ] && [ "${CLS}" == "memory" ] && [ "${WARN}" == "False" ]; then
	echo "ok 10 - an empty bank list: the note reads '${TEXT}' (class ${CLS}, no mark on the dot)"
else
	PROBLEMS+="check 10: an empty bank list: the note read '${TEXT}' (class ${CLS}, dot warning ${WARN}; want memory: no banks yet, class memory, no mark); "
fi

# --- 11. calling fetch throws at once: the next passes still start ---
sim ${D}/nofetch.json ${D}/note.js nofetch 3
value ERRORS ${D}/nofetch.json 'd["rejections"] + d["thrown"]'
if [ "${ERRORS}" == "3" ]; then
	echo "ok 11 - a browser where calling fetch throws: ${ERRORS} errors in 3 minutes, one per pass, so every minute's pass starts"
else
	PROBLEMS+="check 11: a browser where calling fetch throws: ${ERRORS} errors in 3 minutes (want 3, one per pass); "
fi

# --- 12. failed operations: the count with its reasons, a warning; the session guard's counts added ---
sim ${D}/failed.json ${D}/note.js failed 2
value TEXT ${D}/failed.json "${NOTE}[\"text\"]"
value CLS ${D}/failed.json "${NOTE}[\"cls\"]"
value WARN ${D}/failed.json "${NOTE}[\"warn\"]"
WANT="memory: 3 documents in 1 bank, 3 failed (page refresh: delta operations did not reach the document; retain: Too many requests); session guard: 2 records set aside (1 in another language, 1 duplicate), 2 agent claims marked, 1 page refresh paused"
if [ "${TEXT}" == "${WANT}" ] && [ "${CLS}" == "memory warn" ] && [ "${WARN}" == "True" ]; then
	echo "ok 12 - 3 failed operations: the note reads '${TEXT}' (class ${CLS}, the dot warned)"
else
	PROBLEMS+="check 12: 3 failed operations: the note read '${TEXT}' (class ${CLS}, dot warning ${WARN}; want '${WANT}', memory warn, warned); "
fi

# --- 13. the guard's counts and no failed operation: added, neutral ---
sim ${D}/guard.json ${D}/note.js guard 2
value TEXT ${D}/guard.json "${NOTE}[\"text\"]"
value CLS ${D}/guard.json "${NOTE}[\"cls\"]"
value WARN ${D}/guard.json "${NOTE}[\"warn\"]"
WANT="memory: 3 documents in 1 bank; session guard: 2 records set aside (1 in another language, 1 duplicate), 2 agent claims marked, 1 page refresh paused"
if [ "${TEXT}" == "${WANT}" ] && [ "${CLS}" == "memory" ] && [ "${WARN}" == "False" ]; then
	echo "ok 13 - the guard's counts with no failed operation: the note reads '${TEXT}' (class ${CLS}, no mark on the dot)"
else
	PROBLEMS+="check 13: the guard's counts with no failed operation: the note read '${TEXT}' (class ${CLS}, dot warning ${WARN}; want '${WANT}', memory, no mark); "
fi

[ -z "${PROBLEMS}" ] || fail "${PROBLEMS}"

# --- 14. planted controls: each guard removed, its check fails ---
python3 - ${D}/note.js ${D}/mutant "${PAGE}" << 'PY' || fail "PLANTED CONTROL BROKEN: a guard is not where the controls expect it"
import os, sys
s = open(sys.argv[1]).read()
flag = "if (!el || el.memoryReading) return;"
abort = "setTimeout(function () { ctl.abort(); }, 8000)"
handler = ".then(done, function (e) { done(); throw e; });"
after = "if (ctl) ctl.abort(); return v;"
start = "Promise.resolve().then(function () { return read('/__seed-state', false); }).then(function (txt) {"
note = "          el.textContent = line;\n"
for anchor in (flag, abort, handler, after, start, note):
    assert s.count(anchor) == 1, anchor
os.makedirs(sys.argv[2], exist_ok=True)
plants = {
    "no-flag": s.replace(flag, "if (!el) return;"),
    "no-abort": s.replace(abort, "setTimeout(function () { }, 8000)"),
    "swallow": s.replace(handler, ".then(done, done);"),
    "no-handler": s.replace(handler, ".then(done);"),
    "no-abort-after": s.replace(after, "return v;"),
    "start-outside": s.replace(start, "read('/__seed-state', false).then(function (txt) {"),
    "throws": s.replace(note, note + "          throw new Error('planted');\n"),
}
for name, text in plants.items():
    open(os.path.join(sys.argv[2], name + ".js"), "w").write(text)
page = open(sys.argv[3]).read()
assert page.count("\nmemoryState();\n") == 1, "the page's load-time call"
open(os.path.join(sys.argv[2], "noload.html"), "w").write(page.replace("\nmemoryState();\n", "\n"))
PY
sim ${D}/c-no-flag.json ${D}/mutant/no-flag.js hang 10 1 none
value C1 ${D}/c-no-flag.json 'd["most_out"]'
[ "${C1}" -gt 1 ] || fail "PLANTED CONTROL BROKEN: without the pending flag at most ${C1} request was out at once"
sim ${D}/c-no-abort.json ${D}/mutant/no-abort.js hang 2
value C2 ${D}/c-no-abort.json "${NOTE}[\"t\"]"
[ "${C2}" == "none" ] || fail "PLANTED CONTROL BROKEN: with the abort doing nothing the note still changed (at ${C2} ms)"
sim ${D}/c-swallow.json ${D}/mutant/swallow.js notarray 3
value C3 ${D}/c-swallow.json 'd["rejections"]'
[ "${C3}" == "0" ] || fail "PLANTED CONTROL BROKEN: with an error handler that only clears the flag ${C3} errors still reached the console"
sim ${D}/c-no-handler.json ${D}/mutant/no-handler.js notarray 3
value C4 ${D}/c-no-handler.json 'sum(d["passes_per_minute"])'
[ "${C4}" -lt 3 ] || fail "PLANTED CONTROL BROKEN: with no error handler ${C4} passes still ran in 3 minutes"
sim ${D}/c-no-abort-after.json ${D}/mutant/no-abort-after.js errbody 10
value C5 ${D}/c-no-abort-after.json 'd["most_out"]'
[ "${C5}" -gt 1 ] || fail "PLANTED CONTROL BROKEN: without the abort after a read at most ${C5} error body was left open"
read -r _ C6LOAD < <(node ${D}/note-sim.js extract ${D}/mutant/noload.html ${D}/mutant/noload.js 2> ${D}/extract6.err) \
	|| fail "PLANTED CONTROL BROKEN: the page without its load-time call: $(cat ${D}/extract6.err)"
sim ${D}/c-noload.json ${D}/note.js up 3 1 with "${C6LOAD}"
value C6 ${D}/c-noload.json 'sum(d["passes_per_minute"])'
{ [ "${C6LOAD}" == "noload" ] && [ "${C6}" == "2" ]; } || fail "PLANTED CONTROL BROKEN: the page without its load-time call read [${C6LOAD}] and ran ${C6} passes in 3 minutes"
sim ${D}/c-start-outside.json ${D}/mutant/start-outside.js nofetch 3
value C7 ${D}/c-start-outside.json 'd["rejections"] + d["thrown"]'
[ "${C7}" -lt 3 ] || fail "PLANTED CONTROL BROKEN: with the pass started outside its chain ${C7} errors still came in 3 minutes"
node ${D}/note-sim.js run ${D}/mutant/throws.js "${EVERY}" "${LOAD}" up 2 1 with > ${D}/c-throws.json 2> ${D}/c-throws.err
C8=$?
{ [ "${C8}" == "3" ] && grep -q "planted" ${D}/c-throws.err; } || fail "PLANTED CONTROL BROKEN: a pass that throws while the API answers ended the simulator with ${C8}: $(head -2 ${D}/c-throws.err)"
echo "ok 14 - planted controls: without the pending flag ${C1} requests are out at once; with the abort doing nothing the note never changes (${C2}); an error handler that only clears the flag lets ${C3} errors reach the console, and with none ${C4} pass runs in 3 minutes; without the abort after a read ${C5} error bodies stay open; a page without the load-time call runs ${C6} passes in 3 minutes; a pass started outside its chain leaves ${C7} error in 3 minutes; a pass that throws while the API answers stops the run (exit ${C8})"
echo "Test-home-memory-note succeeded"
