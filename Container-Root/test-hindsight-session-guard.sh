#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the harness's Hindsight session guard (/agent/hindsight-session-guard.py, a Claude Code Stop hook registered next
# to Hindsight's own): the records the memory service extracts from a session are checked where they are stored, and the
# session banks' failed operations are logged with their reasons. Fully OFFLINE: a stub memory API on a loopback port (the
# routes the guard and Hindsight's stop hook call; it "extracts" one record per transcript turn and keeps every request), a
# planted git repository as the cwd, a planted transcript, test-local settings, hooks config, guard state and UI directory;
# nothing under the real home is read or written. Each check FAILS if the property it proves is removed:
#   1. the guard compiles (into the test directory), the repair script and the installers parse
#   2. the repair registers the guard for Stop next to Hindsight's stop hook and gives a hooks config without a retainContext
#      the harness's (/agent/hindsight-retain-context.txt: who said what, a request is not an outcome, the agent's account is
#      its claim) and retainMetadata verified "false" (the flag every session record carries), idempotently, a config's
#      own retainContext and retainMetadata keys kept; the installer writes and asserts both; ui-start.sh starts
#      the memory API with HINDSIGHT_API_LLM_OUTPUT_LANGUAGE (English unless set) and .env passes it through
#   3. PLANTED session: Hindsight's stop hook (the installed one; without it the test sends the request it would) retains a
#      transcript whose user asks the agent to load a package, whose agent says it loaded it, says one sentence in German and
#      repeats a record the bank already holds; the stub saw the harness's context with the session id and the verified flag. One guard pass then
#      rewrites both agent claims as "The agent said: ..." with context "agent claim, not verified; session <id>; <time>",
#      leaves the user's request as it is, invalidates the German record (reason language), the marker-only record and the
#      repeat (reason duplicate of the older record), counts each in the tile's state file and logs each once; an English
#      record naming a German word stays; as a hook it prints nothing; a second pass changes nothing and logs nothing
#   3b. the language check counts the words outside quotes, code and addresses, needs more than twice the output
#      language's count and names a non-Latin script (an English record quoting German or listing hosts stays)
#   4. failures: a planted 500 on the guard's first read is retried and logged; a failed retain with a transient reason is
#      re-queued once (logged), one with a permanent reason only logged; a page whose refresh failed twice since its last good
#      refresh has its schedule paused (logged with the reason), a page that failed once does not; a second pass logs nothing
#      new and re-queues nothing inside the backoff
#   4b. failure paths: a planted 400 is counted and logged and the bank's records are still checked; a planted
#      unexpected answer is logged as an error and the pass's state saved (the throttle holds); a 1.5 s budget ends a
#      pass against a 3 s answer
#   4c. bookkeeping: a paused page's cron comes back after a good refresh; the retry and refresh-failure maps are
#      pruned; a session retain behind 120 newer completed retains is found and checked
#   4d. a failed operation whose detail read fails is not marked seen: the next pass logs it, once
#   4e. a detail read that fails on every pass does not stop the failed-operations stage (the operation is logged
#      without its page after three failures); a refresh failure stored once does not count twice toward a pause
#   5. controls: HINDSIGHT_SESSION_GUARD=false and HINDSIGHT_DISABLE_HOOKS=1 send no request; a hook run right after a pass
#      sends none; a dead API exits 0 and writes nothing; no request ever reaches a bank outside the session banks; with no UI
#      directory the records are still checked and nothing is written there
set -u
D=/tmp/hindsight-session-guard-smoke
rm -rf "${D:?}"
mkdir -p ${D}/pyc ${D}/dist ${D}/conf ${D}/home ${D}/hook-home ${D}/ui
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR=${AGENT_DIR:-${BASE_DIR%/}/agent}
SETUP_DIR=${SETUP_DIR:-${BASE_DIR%/}/setup}
ENV_FILE=${ENV_FILE:-${BASE_DIR%/}/../.env}
GUARD=${AGENT_DIR}/hindsight-session-guard.py
REPAIR=${AGENT_DIR}/hindsight-hooks-repair.sh
CONTEXT_FILE=${AGENT_DIR}/hindsight-retain-context.txt
REAL_HOME=${HOME:-/home/agent}
HOOKS_DIST=${HINDSIGHT_HOOKS_DIST:-${REAL_HOME}/.hindsight/coding-agents/dist}
fail() { echo "Test-hindsight-session-guard FAILED: $*"; exit 1; }
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2"; }
export HOME=${D}/home
unset HINDSIGHT_BANK_ID HINDSIGHT_BANK_ID_TEMPLATE HINDSIGHT_API_URL HINDSIGHT_HOOKS_CONFIG HINDSIGHT_DISABLE_HOOKS HINDSIGHT_DISABLED \
	HINDSIGHT_AGENT_CONF HINDSIGHT_SESSION_GUARD HINDSIGHT_GUARD_STATE HINDSIGHT_API_LLM_OUTPUT_LANGUAGE HINDSIGHT_CONFIG
STUB_PID=""
cleanup() { [ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null; }
trap cleanup EXIT

# --- 1. syntax ---
[ -f "${GUARD}" ] || fail "no ${GUARD} (the session guard is not in the agent directory)"
[ -s "${CONTEXT_FILE}" ] || fail "no ${CONTEXT_FILE} (the context the session write-back sends with a transcript)"
python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)" "${GUARD}" "${D}/pyc/guard.pyc" || fail "the guard does not compile"
for S in "${REPAIR}" "${SETUP_DIR}/install-hindsight.sh" "${AGENT_DIR}/ui-start.sh"; do
	[ -f "${S}" ] || fail "missing ${S}"
	bash -n "${S}" || fail "bash -n ${S}"
done
echo "ok 1 - the guard compiles (into the test directory), the repair script and the installers parse"

# --- 2. registration, the retain context, the language pin ---
touch ${D}/dist/claude-hook.js
printf '{\n  "env": {"CLAUDE_CODE_USE_BEDROCK": "1"},\n  "plantedKey": {"kept": true}\n}\n' > ${D}/settings.json
printf '{\n  "serverMode": "self-hosted",\n  "apiUrl": "http://localhost:8888"\n}\n' > ${D}/conf/coding-agent.json
repair() { CLAUDE_SETTINGS=${D}/settings.json HINDSIGHT_HOOKS_DIST=${D}/dist HINDSIGHT_AGENT_CONF=$1 AGENT_DIR="${AGENT_DIR}" "${REPAIR}"; }
repair ${D}/conf/coding-agent.json > ${D}/repair-1.log 2>&1 || fail "the repair failed: $(cat ${D}/repair-1.log)"
grep -q "Stop(guard)" ${D}/repair-1.log || fail "the repair did not report the session guard restored: $(cat ${D}/repair-1.log)"
[ "$(json ${D}/settings.json "sum(1 for g in d['hooks']['Stop'] for h in g['hooks'] if h.get('command') == 'python3 \"${AGENT_DIR}/hindsight-session-guard.py\"' and h.get('timeout') == 30)")" == "1" ] \
	|| fail "the guard is not registered once for Stop as python3 \"${AGENT_DIR}/hindsight-session-guard.py\" with a 30 s timeout: $(json ${D}/settings.json "json.dumps(d['hooks']['Stop'])")"
json ${D}/settings.json "json.dumps(d['hooks']['Stop'])" | grep -qF "${D}/dist/claude-stop-hook.js" || fail "Hindsight's own Stop hook is not registered next to the guard"
WANT_CTX=$(cat "${CONTEXT_FILE}")
[ "$(json ${D}/conf/coding-agent.json "d.get('retainContext')")" == "${WANT_CTX}" ] || fail "the repair did not give the config the harness's retainContext: $(cat ${D}/conf/coding-agent.json)"
[ "$(json ${D}/conf/coding-agent.json "(d.get('retainMetadata') or {}).get('verified')")" == "false" ] \
	|| fail "the repair did not give the config retainMetadata verified \"false\" (the flag every session record carries): $(cat ${D}/conf/coding-agent.json)"
grep -qF "{sessionId}" "${CONTEXT_FILE}" || fail "the retain context does not name the session ({sessionId})"
grep -qi "request" "${CONTEXT_FILE}" && grep -qi "claim" "${CONTEXT_FILE}" || fail "the retain context does not say a request is not an outcome and the agent's account is its claim"
SUM_S=$(md5sum ${D}/settings.json | cut -d' ' -f1); SUM_C=$(md5sum ${D}/conf/coding-agent.json | cut -d' ' -f1)
repair ${D}/conf/coding-agent.json > ${D}/repair-2.log 2>&1 || fail "the second repair run failed"
grep -q "the session guard present in" ${D}/repair-2.log || fail "the second run did not report everything present: $(cat ${D}/repair-2.log)"
[ "$(md5sum ${D}/settings.json | cut -d' ' -f1)" == "${SUM_S}" ] && [ "$(md5sum ${D}/conf/coding-agent.json | cut -d' ' -f1)" == "${SUM_C}" ] \
	|| fail "the second repair run changed settings.json or the config (not idempotent)"
printf '{"serverMode": "self-hosted", "apiUrl": "http://localhost:8888", "retainContext": "a person own wording {sessionId}", "retainMetadata": {"team": "planted"}}\n' > ${D}/conf/own.json
repair ${D}/conf/own.json > ${D}/repair-3.log 2>&1 || fail "the repair on a config with its own retainContext failed"
[ "$(json ${D}/conf/own.json "d.get('retainContext')")" == "a person own wording {sessionId}" ] || fail "the repair replaced a config's own retainContext: $(cat ${D}/conf/own.json)"
[ "$(json ${D}/conf/own.json "json.dumps(d.get('retainMetadata'), sort_keys=True)")" == '{"team": "planted", "verified": "false"}' ] \
	|| fail "the repair did not add the verified flag next to a config's own retainMetadata: $(cat ${D}/conf/own.json)"
INST=${SETUP_DIR}/install-hindsight.sh
grep -qF "/hindsight-session-guard.py" "${INST}" || fail "the installer does not register the session guard"
grep -qF "hindsight-retain-context.txt" "${INST}" || fail "the installer does not set the retain context from /agent/hindsight-retain-context.txt"
grep -q 'includes("/hindsight-session-guard.py")' "${INST}" || fail "the installer does not assert the guard's registration"
grep -q 'config.retainContext' "${INST}" || fail "the installer does not assert the retain context"
grep -q 'verified: "false"' "${INST}" && grep -q '(config.retainMetadata || {}).verified' "${INST}" || fail "the installer does not write and assert the verified flag"
grep -qE 'HINDSIGHT_API_LLM_OUTPUT_LANGUAGE="\$\{HINDSIGHT_API_LLM_OUTPUT_LANGUAGE:-English\}"' "${AGENT_DIR}/ui-start.sh" \
	|| fail "ui-start.sh does not start the memory API with HINDSIGHT_API_LLM_OUTPUT_LANGUAGE (English unless set)"
if [ -f "${ENV_FILE}" ]; then
	grep -q -- '-e HINDSIGHT_API_LLM_OUTPUT_LANGUAGE ' "${ENV_FILE}" || fail ".env does not pass HINDSIGHT_API_LLM_OUTPUT_LANGUAGE to the container"
	ENV_NOTE="and .env passes it through"
else
	ENV_NOTE="(.env is not in the image; read on the host)"
fi
echo "ok 2 - the repair registers the guard for Stop next to Hindsight's stop hook and gives a config without one the harness's retainContext and verified=false (idempotent, a config's own kept); the installer writes and asserts both; ui-start.sh pins the memory API's output language ${ENV_NOTE}"

# --- the stub memory API ---
cat > ${D}/stub-api.py << 'PYSTUB'
import http.server, json, os, re, sys, time, urllib.parse
PORT, STATE, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def load():
    return json.load(open(STATE))
def save(s):
    json.dump(s, open(STATE + ".tmp", "w"), indent=1)
    os.replace(STATE + ".tmp", STATE)
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body):
        out = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers()
        self.wfile.write(out)
    def handle_any(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        body = json.loads(raw) if raw else None
        u = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        s = load()
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": method, "path": urllib.parse.unquote(u.path), "query": q, "body": body}) + "\n")
        key = "%s %s?%s" % (method, urllib.parse.unquote(u.path), u.query)
        for planted in list(s.get("fail_once", [])):
            if planted in key:
                s["fail_once"].remove(planted); save(s)
                return self.reply(500, {"detail": "planted failure"})
        for planted in s.get("fail_4xx", []):
            if planted in key:
                return self.reply(400, {"detail": "planted bad request"})
        for planted, secs in s.get("slow", {}).items():
            if planted in key:
                time.sleep(secs)
        for planted in s.get("malformed", []):
            if planted in key:
                return self.reply(200, {"operations": ["planted"], "items": ["planted"]})
        if u.path in ("/v1/version", "/version"):
            return self.reply(200, {"api_version": "0.9.2"})
        if u.path == "/health":
            return self.reply(200, {"status": "healthy"})
        if u.path == "/v1/default/banks":
            return self.reply(200, {"banks": [{"bank_id": b} for b in s["banks"]]})
        m = re.match(r"^/v1/default/banks/([^/]+)(/.*)?$", u.path)
        if not m:
            return self.reply(404, {"detail": "no route"})
        bank, rest = urllib.parse.unquote(m.group(1)), m.group(2) or ""
        units = s["units"].setdefault(bank, [])
        ops = s["ops"].setdefault(bank, [])
        mms = s["mms"].setdefault(bank, [])
        if rest == "/config":
            return self.reply(200, {"config": {"store_document_text": True}})
        if rest == "/memories" and method == "POST":
            for item in body.get("items", []):
                units[:] = [x for x in units if x.get("document_id") != item.get("document_id")]
                for line in str(item.get("content") or "").split("\n"):
                    try:
                        turn = json.loads(line)
                    except ValueError:
                        continue
                    role, text = turn.get("role"), str(turn.get("content") or "")
                    if role == "system" and text.startswith("REF-ID: "):
                        text, ftype = "%s was mentioned on %s." % (text, str(item.get("timestamp") or "")[:10]), "world"
                    elif role == "user":
                        ftype = "world"
                    elif role == "assistant":
                        ftype = "experience" if text.startswith("I ") else "world"
                    else:
                        continue
                    s["next"] += 1
                    units.append({"id": "u-%d" % s["next"], "text": text, "fact_type": ftype, "context": item.get("context"),
                                  "document_id": item.get("document_id"), "mentioned_at": item.get("timestamp"),
                                  "tags": item.get("tags"), "metadata": item.get("metadata"), "state": "valid"})
                op = body.get("operation_id") or "op-retain-%d" % s["next"]
                ops.append({"id": op, "task_type": "retain", "status": "completed", "document_id": item.get("document_id"),
                            "created_at": item.get("timestamp"), "error_message": None, "retry_count": 0, "items_count": 1})
            s["retains"].append(body)
            save(s)
            return self.reply(200, {"success": True, "operation_id": op, "async": True})
        if rest == "/operations" and method == "GET":
            sel = [o for o in ops if not q.get("status") or o["status"] == q["status"]]
            sel = [o for o in sel if not q.get("type") or o["task_type"] == q["type"]]
            off = int(q.get("offset", 0))
            sel = sorted(sel, key=lambda o: o.get("created_at") or "", reverse=True)[off: off + int(q.get("limit", 20))]
            return self.reply(200, {"bank_id": bank, "total": len(sel), "operations": [{k: v for k, v in o.items() if k != "result_metadata"} for o in sel]})
        m2 = re.match(r"^/operations/([^/]+)(/retry)?$", rest)
        if m2:
            op = next((o for o in ops if o["id"] == m2.group(1)), None)
            if op is None:
                return self.reply(404, {"detail": "no operation"})
            if m2.group(2) and method == "POST":
                op["retry_count"] += 1   # re-queued, and (planted) failed again at once
                save(s)
                return self.reply(200, {"success": True, "message": "queued for retry"})
            full = {"operation_id": op["id"], "status": op["status"], "operation_type": op["task_type"], "error_message": op.get("error_message"),
                    "created_at": op.get("created_at"), "retry_count": op.get("retry_count"), "result_metadata": op.get("result_metadata", {})}
            return self.reply(200, full)
        if rest == "/memories/list" and method == "GET":
            want = q.get("state", "valid")
            sel = [x for x in units if x["state"] == want]
            if q.get("document_id"):
                sel = [x for x in sel if x.get("document_id") == q["document_id"]]
            if q.get("q"):
                sel = [x for x in sel if q["q"].lower() in x["text"].lower()]
            off, lim = int(q.get("offset", 0)), int(q.get("limit", 100))
            return self.reply(200, {"items": sel[off:off + lim], "total": len(sel)})
        m3 = re.match(r"^/memories/([^/]+)$", rest)
        if m3:
            x = next((x for x in units if x["id"] == m3.group(1) and x["state"] == "valid"), None)
            if x is None:
                return self.reply(404, {"detail": "Memory unit '%s' not found" % m3.group(1)})
            if method == "PATCH":
                for k in ("text", "context"):
                    if body.get(k) is not None:
                        x[k] = body[k]
                if body.get("state") == "invalidated":
                    x["state"], x["invalidation_reason"] = "invalidated", body.get("reason")
                save(s)
            return self.reply(200, x)
        m4 = re.match(r"^/mental-models/([^/]+)$", rest)
        if m4:
            mm = next((x for x in mms if x["id"] == m4.group(1)), None)
            if mm is None:
                return self.reply(404, {"detail": "no mental model"})
            if method == "PATCH":
                mm["trigger"] = {**mm["trigger"], **(body.get("trigger") or {})}
                save(s)
            return self.reply(200, mm)
        return self.reply(404, {"detail": "no route"})
    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PATCH(self): self.handle_any("PATCH")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYSTUB
BANK="coding-agent::planted-guard"
python3 - ${D}/state.json "${BANK}" << 'PY'
import json, sys
bank = sys.argv[2]
json.dump({"banks": [bank, "harness-knowledge"], "next": 0, "retains": [], "fail_once": [], "ops": {}, "mms": {},
           "units": {bank: [{"id": "u-old-1", "text": "The staging deploy uses the blue-green switch on the planted gateway | When: 2026-10-14 | Involving: user",
                             "fact_type": "world", "context": "", "document_id": "conversation:older-session", "mentioned_at": "2026-10-14T09:00:00+00:00",
                             "tags": ["source:chat"], "metadata": {}, "state": "valid"}],
                     "harness-knowledge": [{"id": "hk-1", "text": "Die Seed-Datei wurde mit dem Werkzeug erstellt, das nur Lesezugriff auf die Banken gibt.",
                                            "fact_type": "world", "document_id": "conversation:not-a-session-bank", "state": "valid"}]}},
          open(sys.argv[1], "w"), indent=1)
PY
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 ${D}/stub-api.py ${PORT} ${D}/state.json ${D}/stub.log > ${D}/stub.out 2>&1 &
STUB_PID=$!
for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:${PORT}/health" && break; sleep 0.2; done
curl -s -o /dev/null "http://127.0.0.1:${PORT}/health" || fail "test setup: the stub API did not come up on ${PORT}: $(cat ${D}/stub.out)"
: > ${D}/stub.log
API=http://127.0.0.1:${PORT}
python3 - ${D}/conf/coding-agent.json ${D}/conf/hook.json "${API}" << 'PY'
import json, sys
c = json.load(open(sys.argv[1])); c.update({"apiUrl": sys.argv[3], "autoInject": "none"}); json.dump(c, open(sys.argv[2], "w"), indent=2)
PY
guard() { HINDSIGHT_HOOKS_CONFIG=${D}/conf/hook.json HINDSIGHT_GUARD_STATE=${D}/guard-state.json UI_DIR=${UI_DIR_UNDER_TEST:-${D}/ui} "$@"; }
unit() { python3 -c "import json,sys; s=json.load(open(sys.argv[1])); u=[x for x in s['units'][sys.argv[2]] if sys.argv[3] in x['text']]; print(json.dumps(u[0]) if len(u) == 1 else 'NOT-ONE:%d' % len(u))" ${D}/state.json "${BANK}" "$1"; }
field() { python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))" "$1" "$2"; }
events() { python3 -c "import json,sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l).get('kind') == sys.argv[2]))" ${D}/ui/hindsight-memory-guard.jsonl "$1" 2>/dev/null || echo 0; }
stateval() { grep -E "^$1=" ${D}/ui/hindsight-memory-guard.state | cut -d= -f2-; }
requests() { python3 -c "import json,sys; print(sum(1 for l in open(sys.argv[1]) if (lambda r: r['method'] == sys.argv[2] and sys.argv[3] in r['path'] + '?' + json.dumps(r['query']))(json.loads(l))))" ${D}/stub.log "$1" "$2"; }

# --- 3. a planted session: the write path, then one guard pass ---
command -v git > /dev/null || fail "git is not installed - the hooks name the bank after the git project"
git init -q ${D}/planted-guard || fail "test setup: git init"
SID=$(python3 -c 'import uuid; print(uuid.uuid4())')
TS=2026-10-15T06:10:00.000Z
cat > ${D}/transcript.jsonl << EOF
{"type":"user","sessionId":"${SID}","timestamp":"${TS}","message":{"role":"user","content":"Please load the private knowledge package at github.com/example-org/planted-pack so you know our shared workstreams."}}
{"type":"assistant","sessionId":"${SID}","timestamp":"${TS}","message":{"role":"assistant","content":[{"type":"text","text":"I loaded the private knowledge package github.com/example-org/planted-pack."}]}}
{"type":"assistant","sessionId":"${SID}","timestamp":"${TS}","message":{"role":"assistant","content":[{"type":"text","text":"Die Slack-App wurde mit dem Manifest erstellt, das nur Lesezugriff auf die Kanäle ermöglicht."}]}}
{"type":"assistant","sessionId":"${SID}","timestamp":"${TS}","message":{"role":"assistant","content":[{"type":"text","text":"The staging deploy uses the blue-green switch on the planted gateway."}]}}
{"type":"assistant","sessionId":"${SID}","timestamp":"${TS}","message":{"role":"assistant","content":[{"type":"text","text":"Agent connected to the Kanäle dashboard in us-east-2 with read access."}]}}
EOF
EVENT=$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"Stop","stop_hook_active":false}' "${SID}" "${D}/transcript.jsonl" "${D}/planted-guard")
if [ -f "${HOOKS_DIST}/claude-stop-hook.js" ] && command -v node > /dev/null; then
	printf '%s\n' "${EVENT}" | env HOME=${D}/hook-home HINDSIGHT_CONFIG=${D}/conf/hook.json timeout 60 node "${HOOKS_DIST}/claude-stop-hook.js" > ${D}/stop-hook.out 2>&1 \
		|| fail "Hindsight's stop hook failed: $(head -5 ${D}/stop-hook.out)"
	WRITER="Hindsight's stop hook (${HOOKS_DIST})"
else
	python3 - "${API}" "${BANK}" "${SID}" "${TS}" ${D}/transcript.jsonl "${CONTEXT_FILE}" ${D}/conf/hook.json << 'PY' || fail "test setup: the planted retain"
import json, sys, urllib.parse, urllib.request
api, bank, sid, ts, path, ctx, conf = sys.argv[1:8]
turns = [{"role": "system", "content": "REF-ID: conversation:" + sid, "timestamp": ts}]
for l in open(path):
    m = json.loads(l)["message"]
    text = m["content"] if isinstance(m["content"], str) else "\n".join(b["text"] for b in m["content"])
    turns.append({"role": m["role"], "content": text, "timestamp": ts})
item = {"content": "\n".join(json.dumps(t) for t in turns), "context": open(ctx).read().strip().replace("{sessionId}", sid),
        "document_id": "conversation:" + sid, "tags": ["source:chat", "harness:claude-code"], "strategy": "conversation", "timestamp": ts,
        "metadata": {**json.load(open(conf)).get("retainMetadata", {}), "source": "chat", "session_id": sid}}
req = urllib.request.Request(api + "/v1/default/banks/" + urllib.parse.quote(bank, safe="") + "/memories", method="POST",
                             data=json.dumps({"items": [item], "async": True}).encode(), headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10).read()
PY
	WRITER="the test's own request (Hindsight's stop hook is not installed here)"
fi
[ "$(json ${D}/state.json "len(d['retains'])")" == "1" ] || fail "3: the stub saw $(json ${D}/state.json "len(d['retains'])") retain(s) of the session, want 1 ($(head -3 ${D}/stop-hook.out 2>/dev/null))"
[ "$(json ${D}/state.json "d['retains'][0]['items'][0]['context']")" == "${WANT_CTX//\{sessionId\}/${SID}}" ] \
	|| fail "3: the session's retain did not carry the harness's context with the session id: $(json ${D}/state.json "d['retains'][0]['items'][0]['context']")"
[ "$(json ${D}/state.json "(d['retains'][0]['items'][0].get('metadata') or {}).get('verified')")" == "false" ] \
	|| fail "3: the session's retain did not carry the verified flag (metadata verified \"false\"): $(json ${D}/state.json "json.dumps(d['retains'][0]['items'][0].get('metadata'))")"
OUT=$(printf '%s\n' "${EVENT}" | guard python3 "${GUARD}"); RC=$?
[ ${RC} -eq 0 ] || fail "3: the guard exited ${RC} as a Stop hook"
[ -z "${OUT}" ] || fail "3: the guard printed to stdout as a Stop hook (a hook's stdout can block the stop): ${OUT:0:200}"
U=$(unit "loaded the private knowledge package")
[ "$(field "${U}" text)" == "The agent said: I loaded the private knowledge package github.com/example-org/planted-pack." ] || fail "3: the false claim was not rewritten as the agent's claim: ${U}"
WHEN=$(field "${U}" mentioned_at); WHEN=${WHEN:0:19}
[ "$(field "${U}" context)" == "agent claim, not verified; session ${SID}; ${WHEN}" ] || fail "3: the claim's context does not say agent claim, not verified, the session and the time: ${U}"
U=$(unit "Kanäle dashboard")
{ [ "$(field "${U}" text)" == "The agent said: Agent connected to the Kanäle dashboard in us-east-2 with read access." ] && [ "$(field "${U}" state)" == "valid" ]; } \
	|| fail "3: an English record naming a German word is not kept as the agent's claim: ${U}"
U=$(unit "Please load the private knowledge package")
{ [ "$(field "${U}" text)" == "Please load the private knowledge package at github.com/example-org/planted-pack so you know our shared workstreams." ] && [ "$(field "${U}" state)" == "valid" ]; } \
	|| fail "3: the user's request was changed: ${U}"
U=$(unit "Die Slack-App")
{ [ "$(field "${U}" state)" == "invalidated" ] && [ "$(field "${U}" invalidation_reason)" == "language: de, not en" ]; } || fail "3: the German record was not set aside for its language: ${U}"
U=$(unit "REF-ID: conversation:${SID}")
{ [ "$(field "${U}" state)" == "invalidated" ] && [ "$(field "${U}" invalidation_reason)" == "no content: the transcript's REF-ID marker" ]; } || fail "3: the marker-only record was not set aside: ${U}"
U=$(python3 -c "import json,sys; s=json.load(open(sys.argv[1])); print(json.dumps([x for x in s['units'][sys.argv[2]] if x['text'] == 'The staging deploy uses the blue-green switch on the planted gateway.'][0]))" ${D}/state.json "${BANK}")
{ [ "$(field "${U}" state)" == "invalidated" ] && [ "$(field "${U}" invalidation_reason)" == "duplicate of u-old-1" ]; } || fail "3: the repeat of a stored record was not set aside as its duplicate: ${U}"
U=$(unit "planted gateway | When")
{ [ "$(field "${U}" state)" == "valid" ] && [ "$(field "${U}" id)" == "u-old-1" ]; } || fail "3: the older record the repeat duplicates was touched: ${U}"
[ "$(stateval rejected_language)" == "1" ] && [ "$(stateval rejected_duplicate)" == "1" ] && [ "$(stateval rejected_marker)" == "1" ] && [ "$(stateval claims_marked)" == "2" ] \
	|| fail "3: the tile's state file does not count 1/1/1 set aside and 2 claims: $(cat ${D}/ui/hindsight-memory-guard.state 2>&1)"
[ "$(events rejected)" == "3" ] && [ "$(events claim)" == "2" ] || fail "3: the guard's log does not hold 3 rejected and 2 claim events: $(cat ${D}/ui/hindsight-memory-guard.jsonl 2>&1 | head -10)"
PATCHES=$(requests PATCH /memories/)
LINES=$(wc -l < ${D}/ui/hindsight-memory-guard.jsonl)
guard python3 "${GUARD}" --once > ${D}/pass-2.out 2>&1 || fail "3: the second pass failed: $(cat ${D}/pass-2.out)"
[ "$(requests PATCH /memories/)" == "${PATCHES}" ] || fail "3: the second pass changed records again ($(requests PATCH /memories/) PATCH requests, want ${PATCHES})"
[ "$(wc -l < ${D}/ui/hindsight-memory-guard.jsonl)" == "${LINES}" ] || fail "3: the second pass logged again: $(tail -3 ${D}/ui/hindsight-memory-guard.jsonl)"
echo "ok 3 - planted session through ${WRITER}: the stub saw the harness's context with the session id and verified=false; one guard pass rewrote 2 agent claims as 'The agent said: ...' (context: agent claim, not verified, the session, the time), kept the request and an English record naming a German word, set aside the German, the marker-only and the duplicate record with their reasons, counted and logged each once, printed nothing; a second pass changed nothing"

# --- 3b. the language check counts the words outside quotes: an English record may quote a sentence in another language ---
python3 - "${GUARD}" << 'PY' || fail "3b: the record checks (language, claims)"
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("hindsight_session_guard", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
de = "Die Slack-App wurde mit dem Manifest erstellt, das nur Lesezugriff auf die Kanäle ermöglicht."
cases = [(de, "de"), ("User requested assistant to reply in German with exactly one sentence: '%s'" % de, None),
         ('The user asked the agent to answer "%s" in German.' % de, None), ("'%s'" % de, "de"),
         ("The agent's notes and the user's request are in English, for the team.", None),
         ("Endpoints: api.github.com, uploads.github.com and raw.githubusercontent.com", None),
         ("See https://docs.example.de/wie-und-wo/ist-nicht-mit-dem for the fix.", None),
         ("The job runs with the default limits, und die Logs sind nicht da, mit dem Fehler.", None),
         ("O serviço foi atualizado para a versão nova e não precisa de reinício.", "pt"),
         ("Сервис был обновлён до новой версии.", "cyrillic"), ("服务已更新到新版本，无需重启。", "cjk"),
         ("User requested a reply in German: ‘Die Slack-App wurde mit dem Manifest erstellt, das nur Lesezugriff auf die Kanäle ermöglicht.’", None),
         ("データベースの設定を東京で変更した", "cjk"),
         ("Reply in German: »Die App wurde mit dem Manifest erstellt, das nur lesen darf.«", None),
         ("Reply in German: ›Die App wurde mit dem Manifest erstellt, das nur lesen darf.‹", None),
         ("Reply in Japanese: 「データベースの設定を東京で変更した」", None)]
for text, want in cases:
    got = g.wrong_language(text, "en")
    if got != want:
        sys.exit("3b: wrong_language(%r) = %r, want %r" % (text[:80], got, want))
kinds = [("The user asked the agent to load the private knowledge package X, which the agent loaded.", "outcome"),
         ("The user asked the agent to load X and connect to the planted workspace.", None),
         ("The user asked whether the agent pushed the branch.", None),
         ("The user asked to load X which the agent loaded.", "outcome"),
         ("The user asked to load X, which the agent then loaded.", "outcome"),
         ("The user reported: the build was fixed.", None),
         ("User requested assistant to reply in German with exactly one sentence.", None),
         ("The assistant loaded the knowledge package.", "claim"), ("Claude said it loaded the package.", "worded"),
         ("The user reported that the agent deleted the file.", None), ("The user asked what the agent changed in the config.", None),
         ("The user asked to load X, which was loaded.", "outcome"),
         ("Claude Code loaded the knowledge package.", "claim"), ("Claude Code said it loaded the package.", "worded")]
for text, want in kinds:
    got = g.claim_kind({"text": text, "fact_type": "world"})
    if got != want:
        sys.exit("3b: claim_kind(%r) = %r, want %r" % (text[:80], got, want))
same = [("The user instructed the agent to load the planted package and connect to the planted Slack workspace.",
         "User instructed agent to load planted package and connect to planted Slack workspace | When: 2026-10-15 | Involving: user")]
for a, b in same:
    if g.content_key(a) != g.content_key(b) or g.content_key(a) == g.content_key("User instructed agent to load another package"):
        sys.exit("3b: content_key does not take %r and %r for one content" % (a[:50], b[:50]))
PY
echo "ok 3b - the language check counts the words outside quotes, code and addresses and needs more than twice the output language's count: an English record quoting German, one listing hosts, one with a German URL and a mixed one stay; a German, a Portuguese, a Cyrillic and a Chinese record and one that is only a German quote do not; a user's request followed by the agent's account of the outcome is the agent's claim, the request alone is not"
# --- 4. failures: logged with their reasons, a transient retain re-queued, a wedged page paused, a planted 500 retried ---
python3 - ${D}/state.json "${BANK}" << 'PY'
import json, sys
from datetime import datetime, timedelta, timezone
s, bank = json.load(open(sys.argv[1])), sys.argv[2]
now = datetime.now(timezone.utc)
ago = lambda m: (now - timedelta(minutes=m)).isoformat()
refresh = "MentalModelRefreshError: Refresh failed for mental_model_id=%s: delta operations did not reach the document, and the reflect candidate covers only memories newer than the last refresh, so writing it would drop the rest of the document. Previous content preserved in DB; reflect_response.refresh_skipped == 'delta_ops_failed' for audit."
s["ops"][bank] += [
    {"id": "op-retain-transient", "task_type": "retain", "status": "failed", "created_at": ago(10), "document_id": "conversation:older-session", "retry_count": 3,
     "error_message": "ThrottlingException: An error occurred (ThrottlingException) when calling the Converse operation: Too many requests"},
    {"id": "op-retain-permanent", "task_type": "retain", "status": "failed", "created_at": ago(9), "document_id": "conversation:older-session", "retry_count": 3,
     "error_message": "ValueError: document_id is longer than 512 characters"},
    {"id": "op-refresh-w1", "task_type": "refresh_mental_model", "status": "failed", "created_at": ago(8), "retry_count": 3, "error_message": refresh % "mm-wedged",
     "result_metadata": {"mental_model_id": "mm-wedged", "name": "Conventions and patterns"}},
    {"id": "op-refresh-w2", "task_type": "refresh_mental_model", "status": "failed", "created_at": ago(3), "retry_count": 3, "error_message": refresh % "mm-wedged",
     "result_metadata": {"mental_model_id": "mm-wedged", "name": "Conventions and patterns"}},
    {"id": "op-refresh-once", "task_type": "refresh_mental_model", "status": "failed", "created_at": ago(2), "retry_count": 3,
     "error_message": "OutputTooLongError: LiteLLM response was truncated due to token limit", "result_metadata": {"mental_model_id": "mm-once", "name": "Core concepts"}},
]
s["mms"][bank] = [{"id": "mm-wedged", "name": "Conventions and patterns", "last_refreshed_at": ago(360), "trigger": {"mode": "delta", "refresh_cron": "7 * * * *", "refresh_after_consolidation": False}},
                  {"id": "mm-once", "name": "Core concepts", "last_refreshed_at": ago(120), "trigger": {"mode": "delta", "refresh_cron": "54 * * * *", "refresh_after_consolidation": False}}]
s["fail_once"] = ["GET /v1/default/banks/%s/operations?" % bank + "status=failed"]
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
guard python3 "${GUARD}" --once > ${D}/pass-3.out 2>&1 || fail "4: the guard pass failed: $(cat ${D}/pass-3.out)"
[ "$(requests GET "/v1/default/banks/${BANK}/operations?{\"status\": \"failed\"")" -ge 2 ] || fail "4: the planted 500 on the failed-operations read was not retried"
python3 -c "import json,sys; e=[json.loads(l) for l in open(sys.argv[1])]; a=[x for x in e if x['kind'] == 'api' and x.get('status') == 500 and x.get('outcome') == 'retrying']; g=[x for x in e if x['kind'] == 'api' and x.get('outcome') == 'gave up']; sys.exit(0 if len(a) == 1 and not g else 1)" ${D}/ui/hindsight-memory-guard.jsonl \
	|| fail "4: the guard's log does not hold one 'api' event with status 500 and outcome retrying (and none gave up): $(grep '"api"' ${D}/ui/hindsight-memory-guard.jsonl)"
[ "$(events failed)" == "5" ] || fail "4: $(events failed) failed operations logged, want 5 (each once): $(grep '"failed"' ${D}/ui/hindsight-memory-guard.jsonl)"
python3 - ${D}/ui/hindsight-memory-guard.jsonl << 'PY' || fail "4: a failed operation was logged without its reason"
import json, sys
want = {"op-retain-transient": "Too many requests", "op-retain-permanent": "document_id is longer than 512 characters",
        "op-refresh-w1": "delta operations did not reach the document", "op-refresh-once": "LiteLLM response was truncated due to token limit"}
got = {e["op"]: e for e in map(json.loads, open(sys.argv[1])) if e["kind"] == "failed"}
for op, reason in want.items():
    if got.get(op, {}).get("reason") != reason or not got[op].get("error"):
        sys.exit("%s: %s" % (op, got.get(op)))
PY
[ "$(requests POST /operations/op-retain-transient/retry)" == "1" ] || fail "4: the failed retain with a transient reason was not re-queued once"
[ "$(requests POST /operations/op-retain-permanent/retry)" == "0" ] || fail "4: a failed retain with a permanent reason was re-queued"
[ "$(json ${D}/state.json "[m for m in d['mms']['${BANK}'] if m['id'] == 'mm-wedged'][0]['trigger'].get('refresh_cron')")" == "None" ] \
	|| fail "4: the page whose refresh failed twice since its last good refresh is still scheduled: $(json ${D}/state.json "d['mms']['${BANK}']")"
[ "$(json ${D}/state.json "[m for m in d['mms']['${BANK}'] if m['id'] == 'mm-once'][0]['trigger'].get('refresh_cron')")" == "54 * * * *" ] \
	|| fail "4: a page whose refresh failed once was paused"
grep '"paused"' ${D}/ui/hindsight-memory-guard.jsonl | grep -q 'Conventions and patterns.*delta operations did not reach the document' \
	|| fail "4: the pause was not logged with the page and the reason: $(grep '"paused"' ${D}/ui/hindsight-memory-guard.jsonl)"
[ "$(stateval failed_logged)" == "5" ] && [ "$(stateval retried)" == "1" ] && [ "$(stateval paused_pages)" == "1" ] && [ "$(stateval api_errors)" == "1" ] \
	|| fail "4: the tile's state file does not count 5 failed, 1 retried, 1 paused, 1 API error: $(cat ${D}/ui/hindsight-memory-guard.state)"
LINES=$(wc -l < ${D}/ui/hindsight-memory-guard.jsonl)
guard python3 "${GUARD}" --once > ${D}/pass-4.out 2>&1 || fail "4: the second pass failed"
[ "$(wc -l < ${D}/ui/hindsight-memory-guard.jsonl)" == "${LINES}" ] || fail "4: the second pass logged again: $(tail -3 ${D}/ui/hindsight-memory-guard.jsonl)"
[ "$(requests POST /operations/op-retain-transient/retry)" == "1" ] || fail "4: the second pass re-queued the retain again inside the backoff"
echo "ok 4 - failures: the planted 500 retried and logged; 5 failed operations logged once each with their reasons; the transient retain re-queued once, the permanent one not; the wedged page paused with its reason, the page that failed once kept; a second pass logged and re-queued nothing"

# --- 4b. failure paths: every failure logged, a bank's stages independent, the state kept whatever ends the pass, the budget held ---
python3 - ${D}/state.json "${BANK}" << 'PY'
import json, sys
s, bank = json.load(open(sys.argv[1])), sys.argv[2]
s["fail_4xx"] = ["GET /v1/default/banks/%s/operations?status=failed" % bank]
sid = "4b000000-0000-4000-8000-000000000001"
s["units"][bank].append({"id": "u-4b-marker", "text": "REF-ID: conversation:%s was mentioned on 2026-10-15." % sid, "fact_type": "world",
                         "context": "planted", "document_id": "conversation:" + sid, "mentioned_at": "2026-10-15T09:00:00Z", "state": "valid"})
s["ops"][bank].append({"id": "op-retain-4b", "task_type": "retain", "status": "completed", "document_id": "conversation:" + sid,
                       "created_at": "2026-10-15T09:00:00Z", "error_message": None, "retry_count": 0, "items_count": 1})
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
guard python3 "${GUARD}" --once > ${D}/pass-4b1.out 2>&1 || fail "4b: the guard pass failed: $(cat ${D}/pass-4b1.out)"
python3 -c "import json,sys; sys.exit(0 if any(e.get('kind') == 'api' and e.get('status') == 400 and e.get('outcome') == 'gave up' for e in map(json.loads, open(sys.argv[1]))) else 1)" ${D}/ui/hindsight-memory-guard.jsonl \
	|| fail "4b: a 400 on the failed-operations read is not counted and logged as given up"
[ "$(field "$(unit "4b000000")" state)" == "invalidated" ] || fail "4b: the records stage did not run after the failures stage failed: $(unit "4b000000")"
python3 - ${D}/state.json ${D}/guard-state.json "${BANK}" << 'PY'
import json, sys
s, g, bank = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
s["fail_4xx"], s["malformed"] = [], ["GET /v1/default/banks/%s/operations?status=completed" % bank]
g["last_pass"] = 0   # long ago: only this pass's own record of itself can throttle the hook run below
json.dump(s, open(sys.argv[1], "w"), indent=1)
json.dump(g, open(sys.argv[2], "w"))
PY
T0=$(date +%s.%N)
guard python3 "${GUARD}" --once > ${D}/pass-4b2.out 2>&1 || fail "4b: the guard exited non-zero on an unexpected answer: $(cat ${D}/pass-4b2.out)"
python3 -c "import json,sys; sys.exit(0 if any(e.get('kind') == 'error' and 'AttributeError' in e.get('reason', '') for e in map(json.loads, open(sys.argv[1]))) else 1)" ${D}/ui/hindsight-memory-guard.jsonl \
	|| fail "4b: an unexpected error in the pass is not logged: $(tail -2 ${D}/ui/hindsight-memory-guard.jsonl)"
python3 -c "import json,sys; sys.exit(0 if float(json.load(open(sys.argv[1])).get('last_pass') or 0) >= float(sys.argv[2]) else 1)" ${D}/guard-state.json "${T0}" \
	|| fail "4b: the pass that ended in an error did not save its state (last_pass)"
N0=$(wc -l < ${D}/stub.log)
printf '%s\n' "${EVENT}" | guard python3 "${GUARD}" > /dev/null 2>&1
[ "$(wc -l < ${D}/stub.log)" == "${N0}" ] || fail "4b: a hook run right after a pass that ended in an error sent requests (the throttle lost its last_pass)"
python3 - ${D}/state.json "${BANK}" << 'PY'
import json, sys
s, bank = json.load(open(sys.argv[1])), sys.argv[2]
s["malformed"], s["slow"] = [], {"GET /v1/default/banks/%s/operations?status=failed" % bank: 3}
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
T0=$(date +%s.%N)
HINDSIGHT_GUARD_BUDGET=1.5 guard python3 "${GUARD}" --once > ${D}/pass-4b3.out 2>&1 || fail "4b: the guard pass with a slow API failed: $(cat ${D}/pass-4b3.out)"
SECS=$(python3 -c "import sys,time; print('%.1f' % (time.time() - float(sys.argv[1])))" "${T0}")
python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 2.8 else 1)" "${SECS}" || fail "4b: a 1.5 s budget held a pass for ${SECS} s against a 3 s answer"
[ "$(events budget)" -ge 1 ] || fail "4b: the spent budget is not logged"
python3 - ${D}/state.json << 'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["slow"] = {}
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
sleep 2   # the stub answers the slow request it is still holding before the next check talks to it
echo "ok 4b - failure paths: a 400 is counted and logged as given up and the records stage still runs; an unexpected answer is logged as an error and the pass's state (last_pass) is saved, so the hook run right after sends nothing; a 1.5 s budget ends a pass against a 3 s answer in ${SECS} s, the spent budget logged"
# --- 4c. bookkeeping: a paused page's cron put back after a good refresh, the retry and failure maps pruned, completed retains read page by page ---
python3 - ${D}/state.json "${BANK}" << 'PY'
import json, sys
from datetime import datetime, timezone
s, bank = json.load(open(sys.argv[1])), sys.argv[2]
now = datetime.now(timezone.utc).isoformat()
for mm in s["mms"][bank]:   # a refresh by hand of the paused page succeeded; the page that failed once refreshed again
    mm["last_refreshed_at"] = now
for op in s["ops"][bank]:
    if op["id"] == "op-retain-transient":   # re-queued and done
        op["status"] = "completed"
s["ops"][bank] += [{"id": "op-seed-%03d" % i, "task_type": "retain", "status": "completed", "document_id": "seed:v1:%03d" % i,
                    "created_at": "2026-10-15T10:%02d:%02dZ" % (i // 60, i % 60), "error_message": None, "retry_count": 0,
                    "items_count": 1} for i in range(120)]
sid = "4c000000-0000-4000-8000-000000000001"
s["units"][bank].append({"id": "u-4c-marker", "text": "REF-ID: conversation:%s was mentioned on 2026-10-15." % sid, "fact_type": "world",
                         "context": "planted", "document_id": "conversation:" + sid, "mentioned_at": "2026-10-15T09:30:00Z", "state": "valid"})
s["ops"][bank].append({"id": "op-retain-4c", "task_type": "retain", "status": "completed", "document_id": "conversation:" + sid,
                       "created_at": "2026-10-15T09:30:00Z", "error_message": None, "retry_count": 0, "items_count": 1})
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
guard python3 "${GUARD}" --once > ${D}/pass-4c.out 2>&1 || fail "4c: the guard pass failed: $(cat ${D}/pass-4c.out)"
python3 -c "import json,sys; s=json.load(open(sys.argv[1])); t=[m for m in s['mms'][sys.argv[2]] if m['id'] == 'mm-wedged'][0]['trigger']; sys.exit(0 if t.get('refresh_cron') == '7 * * * *' and t.get('mode') == 'delta' else 1)" ${D}/state.json "${BANK}" \
	|| fail "4c: the paused page's cron was not put back after its refresh succeeded: $(grep -o '"mm-wedged".\{0,200\}' ${D}/state.json | head -1)"
[ "$(events resumed)" == "1" ] || fail "4c: the page's schedule coming back is not logged once ($(events resumed))"
[ "$(stateval paused_pages)" == "0" ] || fail "4c: the tile's state still counts the resumed page as paused ($(stateval paused_pages))"
python3 - ${D}/guard-state.json "${BANK}" << 'PY' || fail "4c: the guard's maps were not pruned: $(head -c 600 ${D}/guard-state.json)"
import json, sys
m = json.load(open(sys.argv[1]))["banks"][sys.argv[2]]
bad = [what for what, gone in (("retries op-retain-transient", "op-retain-transient" not in m.get("retries", {})),
                               ("refresh_fails mm-once", "mm-once" not in m.get("refresh_fails", {})),
                               ("refresh_fails mm-wedged", "mm-wedged" not in m.get("refresh_fails", {})),
                               ("paused mm-wedged", "mm-wedged" not in m.get("paused", {}))) if not gone]
sys.exit("still held: %s" % bad if bad else 0)
PY
[ "$(field "$(unit "4c000000")" state)" == "invalidated" ] || fail "4c: a session retain behind 100 newer completed retains was not checked: $(unit "4c000000")"
echo "ok 4c - bookkeeping: the paused page gets its cron back (delta mode kept) once a refresh succeeds, logged once; the retry entry of a retain no longer failed and the failures older than a page's good refresh are dropped; a session retain behind 120 newer completed retains is found on the second page and checked"
# --- 4d. a failed operation whose detail read fails is not marked seen: the next pass logs it ---
python3 - ${D}/state.json "${BANK}" << 'PY'
import json, sys
from datetime import datetime, timezone
s, bank = json.load(open(sys.argv[1])), sys.argv[2]
s["ops"][bank].append({"id": "op-refresh-4d", "task_type": "refresh_mental_model", "status": "failed", "created_at": datetime.now(timezone.utc).isoformat(),
                       "retry_count": 3, "error_message": "OutputTooLongError: LiteLLM response was truncated due to token limit",
                       "result_metadata": {"mental_model_id": "mm-once", "name": "Core concepts"}})
s["fail_4xx"] = ["GET /v1/default/banks/%s/operations/op-refresh-4d" % bank]
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
logged_4d() { python3 -c "import json,sys; print(sum(1 for e in map(json.loads, open(sys.argv[1])) if e.get('kind') == 'failed' and e.get('op') == 'op-refresh-4d'))" ${D}/ui/hindsight-memory-guard.jsonl; }
guard python3 "${GUARD}" --once > ${D}/pass-4d1.out 2>&1 || fail "4d: the first pass failed: $(cat ${D}/pass-4d1.out)"
[ "$(logged_4d)" == "0" ] || fail "4d: the operation was logged although its detail read failed"
python3 - ${D}/state.json << 'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["fail_4xx"] = []
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
guard python3 "${GUARD}" --once > ${D}/pass-4d2.out 2>&1 || fail "4d: the second pass failed: $(cat ${D}/pass-4d2.out)"
[ "$(logged_4d)" == "1" ] || fail "4d: the operation whose detail read failed was never logged ($(logged_4d) events): it was marked seen before its event"
echo "ok 4d - a failed operation whose detail read fails is not marked seen: the next pass logs it, once"
# --- 4e. a detail read that fails on every pass does not stop the stage; one refresh failure counts once toward a pause ---
python3 - ${D}/state.json ${D}/guard-state.json "${BANK}" << 'PY'
import json, sys
from datetime import datetime, timedelta, timezone
s, g, bank = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
now = datetime.now(timezone.utc)
t = lambda m: (now - timedelta(minutes=m)).isoformat()
s["ops"][bank] += [
    {"id": "op-refresh-4e", "task_type": "refresh_mental_model", "status": "failed", "created_at": t(6), "retry_count": 3,
     "error_message": "MentalModelRefreshError: Refresh failed for mental_model_id=mm-4e: planted",
     "result_metadata": {"mental_model_id": "mm-4e", "name": "Planted page"}},
    {"id": "op-retain-4e", "task_type": "retain", "status": "failed", "created_at": t(5), "retry_count": 3,
     "document_id": "conversation:older-session", "error_message": "ValueError: planted permanent failure 4e"},
    {"id": "op-refresh-dup", "task_type": "refresh_mental_model", "status": "failed", "created_at": t(4), "retry_count": 3,
     "error_message": "MentalModelRefreshError: Refresh failed for mental_model_id=mm-dup: planted",
     "result_metadata": {"mental_model_id": "mm-dup", "name": "Planted page two"}},
]
s["mms"][bank].append({"id": "mm-dup", "name": "Planted page two", "last_refreshed_at": t(360),
                       "trigger": {"mode": "delta", "refresh_cron": "11 * * * *", "refresh_after_consolidation": False}})
s["fail_4xx"] = ["GET /v1/default/banks/%s/operations/op-refresh-4e" % bank]
# the failure of op-refresh-dup is stored already, as by a pass whose event write then failed
g["banks"][bank].setdefault("refresh_fails", {})["mm-dup"] = [[t(4), "planted", "op-refresh-dup"]]
json.dump(s, open(sys.argv[1], "w"), indent=1)
json.dump(g, open(sys.argv[2], "w"))
PY
logged() { python3 -c "import json,sys; print(sum(1 for e in map(json.loads, open(sys.argv[1])) if e.get('kind') == 'failed' and e.get('op') == sys.argv[2]))" ${D}/ui/hindsight-memory-guard.jsonl "$1"; }
guard python3 "${GUARD}" --once > ${D}/pass-4e1.out 2>&1 || fail "4e: the first pass failed: $(cat ${D}/pass-4e1.out)"
[ "$(logged op-retain-4e)" == "1" ] || fail "4e: an operation after the one whose detail read fails was not logged: the stage stopped there"
[ "$(logged op-refresh-4e)" == "0" ] || fail "4e: the operation was logged on its first failed detail read"
python3 -c "import json,sys; s=json.load(open(sys.argv[1])); t=[m for m in s['mms'][sys.argv[2]] if m['id'] == 'mm-dup'][0]['trigger']; sys.exit(0 if t.get('refresh_cron') == '11 * * * *' else 1)" ${D}/state.json "${BANK}" \
	|| fail "4e: one refresh failure, stored once already, paused its page: it was counted twice"
for n in 2 3; do
	guard python3 "${GUARD}" --once > ${D}/pass-4e${n}.out 2>&1 || fail "4e: pass ${n} failed: $(cat ${D}/pass-4e${n}.out)"
done
[ "$(logged op-refresh-4e)" == "1" ] || fail "4e: after its third failed detail read the operation is still not logged ($(logged op-refresh-4e))"
python3 -c "import json,sys; e=[e for e in map(json.loads, open(sys.argv[1])) if e.get('op') == 'op-refresh-4e'][0]; sys.exit(0 if 'page' not in e else 1)" ${D}/ui/hindsight-memory-guard.jsonl \
	|| fail "4e: the operation logged after three failed detail reads names a page it could not read"
python3 - ${D}/state.json << 'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["fail_4xx"] = []
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
echo "ok 4e - a detail read that fails on every pass: the operations after it are logged at once, and it is logged without its page after its third failure; a refresh failure stored once already does not count twice toward a pause"
# --- 5. controls ---
N=$(wc -l < ${D}/stub.log)
HINDSIGHT_SESSION_GUARD=false guard python3 "${GUARD}" --once > /dev/null 2>&1
HINDSIGHT_DISABLE_HOOKS=1 guard python3 "${GUARD}" --once > /dev/null 2>&1
[ "$(wc -l < ${D}/stub.log)" == "${N}" ] || fail "5: HINDSIGHT_SESSION_GUARD=false or HINDSIGHT_DISABLE_HOOKS=1 still sent requests: $(tail -2 ${D}/stub.log)"
printf '%s\n' "${EVENT}" | guard python3 "${GUARD}" > /dev/null 2>&1
[ "$(wc -l < ${D}/stub.log)" == "${N}" ] || fail "5: a Stop hook run right after a pass sent requests"
mkdir -p ${D}/ui-dead
OUT=$(printf '%s\n' "${EVENT}" | HINDSIGHT_API_URL=http://127.0.0.1:1 HINDSIGHT_GUARD_STATE=${D}/dead-state.json UI_DIR=${D}/ui-dead python3 "${GUARD}"); RC=$?
{ [ ${RC} -eq 0 ] && [ -z "${OUT}" ] && [ -z "$(ls -A ${D}/ui-dead)" ]; } || fail "5: a dead API: rc ${RC}, output '${OUT:0:100}', files $(ls -A ${D}/ui-dead)"
grep -q '/banks/harness-knowledge/' ${D}/stub.log && fail "5: the guard sent a request to a bank outside the session banks: $(grep -m1 '/banks/harness-knowledge/' ${D}/stub.log)"
python3 - ${D}/state.json "${BANK}" << 'PY'
import json, sys
s, bank = json.load(open(sys.argv[1])), sys.argv[2]
s["units"][bank].append({"id": "u-late-de", "text": "Der Agent wurde angewiesen, sich mit dem Cluster zu verbinden und den Inhalt zu pruefen.", "fact_type": "world",
                         "document_id": "conversation:late-session", "mentioned_at": "2026-10-15T07:00:00+00:00", "state": "valid"})
s["ops"][bank].append({"id": "op-retain-late", "task_type": "retain", "status": "completed", "document_id": "conversation:late-session", "created_at": "2026-10-15T07:00:00+00:00"})
json.dump(s, open(sys.argv[1], "w"), indent=1)
PY
UI_DIR_UNDER_TEST=${D}/no-ui guard python3 "${GUARD}" --once > ${D}/pass-5.out 2>&1 || fail "5: the pass with no UI directory failed: $(cat ${D}/pass-5.out)"
[ "$(field "$(unit "Der Agent wurde angewiesen")" state)" == "invalidated" ] || fail "5: with no UI directory the late German record was not set aside"
[ -e ${D}/no-ui ] && fail "5: the guard created the missing UI directory"
echo "ok 5 - controls: HINDSIGHT_SESSION_GUARD=false, HINDSIGHT_DISABLE_HOOKS=1 and a hook run right after a pass send nothing; a dead API exits 0 and writes nothing; no request reaches harness-knowledge; with no UI directory the records are still checked and nothing is written there"

echo "Test-hindsight-session-guard succeeded"
