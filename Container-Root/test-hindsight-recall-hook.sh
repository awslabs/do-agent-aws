#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the harness's Hindsight recall hook (/agent/hindsight-recall-hook.py), its registration next to Hindsight's own
# hooks (setup/install-hindsight.sh at build, /agent/hindsight-hooks-repair.sh at every start) and the hooks' config it needs
# (autoInject "none": Hindsight's prompt hook injected a narrative composed over the bank - a synthesis under the heading of
# memory, no record behind any sentence; the harness injects the records, with their ids, instead). Fully OFFLINE: a stub memory
# API on a loopback port, planted git repositories as the cwd, test-local copies of settings.json and coding-agent.json; nothing
# under the real home is read or written. Each check FAILS if the property it proves is removed:
#   1. the hook, the repair script and the installers parse (bash -n; the hook compiled into the test directory, never into /agent)
#   2. the repair script registers the recall hook for UserPromptSubmit next to Hindsight's three (a stripped settings copy gets
#      all four, every other key kept, a second run changes nothing), sets autoInject "none" in the config copy it is given and
#      leaves a config it is not given alone; the installer writes and asserts both; the startup script hands the repair the
#      config; the governance installer appends the CLAUDE.md note once (run where the rules file is, read where it is not)
#   3. PLANTED: the stub answers the bank's recall with exactly one record (rec-planted-1, a sentence about one subject); a prompt
#      about another subject, from a repository named planted-project, yields one block whose opening tag names
#      bank="coding-agent::planted-project" and records="rec-planted-1", whose header says index / verify / no synthesis, and
#      whose only other content is the one record line "- [rec-planted-1] <the record's text> (<its date>)" - no statement
#      without a record id; the stub saw that bank and the prompt as the query; PLANTED CONTROL: the same checker refuses a
#      block with one sentence of its own between the records
#   4. controls: an empty recall injects nothing; a dead API injects nothing and exits 0; HINDSIGHT_BANK_ID wins over the
#      repository's name; a linked worktree resolves to its main worktree's name; a cwd outside any repository is its own name;
#      HINDSIGHT_DISABLE_HOOKS=1 injects nothing; eleven records are cut to eight
set -u
D=/tmp/hindsight-recall-hook-smoke
rm -rf "${D:?}"
mkdir -p ${D}/pyc ${D}/dist ${D}/conf ${D}/home ${D}/plain-dir
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR=${AGENT_DIR:-${BASE_DIR%/}/agent}
SETUP_DIR=${SETUP_DIR:-${BASE_DIR%/}/setup}
HOOK=${AGENT_DIR}/hindsight-recall-hook.py
REPAIR=${AGENT_DIR}/hindsight-hooks-repair.sh
fail() { echo "Test-hindsight-recall-hook FAILED: $*"; exit 1; }
json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2"; }
export HOME=${D}/home
unset HINDSIGHT_BANK_ID HINDSIGHT_BANK_ID_TEMPLATE HINDSIGHT_API_URL HINDSIGHT_HOOKS_CONFIG HINDSIGHT_DISABLE_HOOKS HINDSIGHT_DISABLED HINDSIGHT_AGENT_CONF
STUB_PID=""
cleanup() { [ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null; }
trap cleanup EXIT

# --- 1. syntax ---
[ -f "${HOOK}" ] || fail "no ${HOOK} (the recall hook is not in the agent directory)"
python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)" "${HOOK}" "${D}/pyc/hook.pyc" || fail "the hook does not compile"
for S in "${REPAIR}" "${SETUP_DIR}/install-hindsight.sh" "${SETUP_DIR}/install-governance.sh" "${AGENT_DIR}/ui-start.sh"; do
	[ -f "${S}" ] || fail "missing ${S}"
	bash -n "${S}" || fail "bash -n ${S}"
done
echo "ok 1 - the hook compiles (into the test directory), the repair script and the installers parse"

# --- 2. registration and the config ---
touch ${D}/dist/claude-hook.js
printf '{\n  "env": {"CLAUDE_CODE_USE_BEDROCK": "1"},\n  "plantedKey": {"kept": true}\n}\n' > ${D}/settings.json
printf '{\n  "serverMode": "self-hosted",\n  "apiUrl": "http://localhost:8888"\n}\n' > ${D}/conf/coding-agent.json
CLAUDE_SETTINGS=${D}/settings.json HINDSIGHT_HOOKS_DIST=${D}/dist HINDSIGHT_AGENT_CONF=${D}/conf/coding-agent.json AGENT_DIR="${AGENT_DIR}" "${REPAIR}" > ${D}/repair-1.log 2>&1 || fail "the repair failed: $(cat ${D}/repair-1.log)"
grep -q "restored SessionStart/UserPromptSubmit/Stop/UserPromptSubmit(recall)/Stop(guard) in" ${D}/repair-1.log || fail "the repair did not report the five hooks restored: $(cat ${D}/repair-1.log)"
grep -q -E "autoInject none.* in ${D}/conf/coding-agent.json" ${D}/repair-1.log || fail "the repair did not report autoInject none for the config it was given: $(cat ${D}/repair-1.log)"
UPS=$(json ${D}/settings.json "json.dumps(d['hooks']['UserPromptSubmit'])")
echo "${UPS}" | grep -qF "${D}/dist/claude-hook.js" || fail "Hindsight's own UserPromptSubmit hook is not registered: ${UPS}"
[ "$(json ${D}/settings.json "any(h.get('command') == 'python3 \"${AGENT_DIR}/hindsight-recall-hook.py\"' and h.get('timeout') == 20 for g in d['hooks']['UserPromptSubmit'] for h in g['hooks'])")" == "True" ] || fail "the recall hook is not registered for UserPromptSubmit as python3 \"${AGENT_DIR}/hindsight-recall-hook.py\" with a 20 s timeout: ${UPS}"
[ "$(json ${D}/settings.json "len(d['hooks']['UserPromptSubmit'])")" == "2" ] || fail "UserPromptSubmit does not carry exactly two entries: ${UPS}"
json ${D}/settings.json "json.dumps(d['hooks']['SessionStart'])" | grep -qF "claude-sessionstart-hook.js" || fail "the SessionStart hook is missing"
json ${D}/settings.json "json.dumps(d['hooks']['Stop'])" | grep -qF "claude-stop-hook.js" || fail "the Stop hook is missing"
[ "$(json ${D}/settings.json "d['plantedKey']['kept']")" == "True" ] || fail "the repair dropped another settings key"
[ "$(json ${D}/settings.json "d['env']['CLAUDE_CODE_USE_BEDROCK']")" == "1" ] || fail "the repair dropped env.CLAUDE_CODE_USE_BEDROCK"
[ "$(json ${D}/conf/coding-agent.json "d.get('autoInject')")" == "none" ] || fail "the config did not get autoInject none: $(cat ${D}/conf/coding-agent.json)"
[ "$(json ${D}/conf/coding-agent.json "d.get('serverMode') + ' ' + d.get('apiUrl')")" == "self-hosted http://localhost:8888" ] || fail "the config lost its server keys: $(cat ${D}/conf/coding-agent.json)"
SUM_S=$(md5sum ${D}/settings.json | cut -d' ' -f1); SUM_C=$(md5sum ${D}/conf/coding-agent.json | cut -d' ' -f1)
CLAUDE_SETTINGS=${D}/settings.json HINDSIGHT_HOOKS_DIST=${D}/dist HINDSIGHT_AGENT_CONF=${D}/conf/coding-agent.json AGENT_DIR="${AGENT_DIR}" "${REPAIR}" > ${D}/repair-2.log 2>&1 || fail "the second repair run failed"
grep -q "the recall hook and the session guard present in" ${D}/repair-2.log || fail "the second run did not report everything present: $(cat ${D}/repair-2.log)"
[ "$(md5sum ${D}/settings.json | cut -d' ' -f1)" == "${SUM_S}" ] || fail "the second run changed settings.json (not idempotent)"
[ "$(md5sum ${D}/conf/coding-agent.json | cut -d' ' -f1)" == "${SUM_C}" ] || fail "the second run changed the config (not idempotent)"
printf '{"serverMode": "self-hosted", "apiUrl": "http://localhost:8888"}\n' > ${D}/conf/not-given.json
SUM_N=$(md5sum ${D}/conf/not-given.json | cut -d' ' -f1)
CLAUDE_SETTINGS=${D}/settings.json HINDSIGHT_HOOKS_DIST=${D}/dist AGENT_DIR="${AGENT_DIR}" "${REPAIR}" > ${D}/repair-3.log 2>&1 || fail "the repair without a config failed"
[ "$(md5sum ${D}/conf/not-given.json | cut -d' ' -f1)" == "${SUM_N}" ] || fail "a config the repair was not given was written"
grep -q "autoInject" ${D}/repair-3.log && fail "the repair reported a config change it was not given one for: $(cat ${D}/repair-3.log)"
INST=${SETUP_DIR}/install-hindsight.sh
grep -qF "/hindsight-recall-hook.py" "${INST}" || fail "the installer does not register the recall hook"
grep -q 'config.autoInject = "none"' "${INST}" || fail "the installer does not set autoInject none"
grep -q 'config.autoInject !== "none"' "${INST}" || fail "the installer does not assert autoInject none"
grep -q 'includes("/hindsight-recall-hook.py")' "${INST}" || fail "the installer does not assert the recall hook's registration"
grep -qE 'HINDSIGHT_AGENT_CONF="\$\{HINDSIGHT_AGENT_CONF\}" .*hindsight-hooks-repair.sh' "${AGENT_DIR}/ui-start.sh" || fail "ui-start.sh does not hand the repair the hooks' config"
GOV=${SETUP_DIR}/install-governance.sh
grep -qF 'RECALL_MARKER="## Recalled memory is an index, not an answer"' "${GOV}" || fail "the governance installer has no recall note"
if [ -f /agent-rules/AGENT_RULES.md ]; then
	mkdir -p ${D}/claude
	CLAUDE_CONFIG_DIR=${D}/claude bash "${GOV}" > ${D}/gov-1.log 2>&1 || fail "install-governance.sh failed: $(cat ${D}/gov-1.log)"
	CLAUDE_CONFIG_DIR=${D}/claude bash "${GOV}" > ${D}/gov-2.log 2>&1 || fail "the second install-governance.sh run failed: $(cat ${D}/gov-2.log)"
	[ "$(grep -c '## Recalled memory is an index, not an answer' ${D}/claude/CLAUDE.md)" == "1" ] || fail "the recall note is not in CLAUDE.md exactly once after two runs: $(grep -c 'Recalled memory' ${D}/claude/CLAUDE.md)"
	grep -q 'A statement without a record id is a synthesis, not a memory' ${D}/claude/CLAUDE.md || fail "the recall note lacks its rule"
	GOV_NOTE="appended once by the installer (two runs, one note)"
else
	GOV_NOTE="installer read, not run (no /agent-rules here)"
fi
echo "ok 2 - the repair registers the recall hook next to Hindsight's three and sets autoInject none in the config it is given (idempotent, other keys kept, a config not given untouched); the installer writes and asserts both; ui-start.sh hands over the config; the CLAUDE.md recall note ${GOV_NOTE}"

# --- 3. planted: one record in the bank, a prompt about something else -> one block, one record line, nothing else ---
cat > ${D}/stub-api.py << 'PYSTUB'
import http.server, json, re, sys, urllib.parse
PORT, RECORDS, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        m = re.match(r"^/v1/default/banks/([^/]+)/memories/recall$", self.path)
        if not m:
            self.send_response(404); self.end_headers(); return
        bank = urllib.parse.unquote(m.group(1))
        try:
            req = json.loads(body or b"{}")
        except ValueError:
            req = {}
        query = req.get("query")
        sources = isinstance(req.get("include"), dict) and isinstance(req["include"].get("source_facts"), dict)
        with open(LOG, "a") as f:
            f.write(json.dumps({"bank": bank, "query": query}) + "\n")
        try:
            recs = json.load(open(RECORDS))
        except (OSError, ValueError):
            recs = {}
        reply = {"results": recs.get(bank, []), "entities": []}
        if sources:   # only when the hook asks for them, as the API does
            reply["source_facts"] = recs.get(bank + "#source_facts", {})
        out = json.dumps(reply).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYSTUB
python3 - ${D}/records.json << 'PY'
import json, sys
SID = "5f1fae85-0000-4000-8000-000000000001"
many =[{"id": "rec-many-%02d" % i, "text": "Record number %d of the many project." % i, "mentioned_at": "2026-09-%02dT08:00:00+00:00" % (i + 1)} for i in range(11)]
json.dump({
    "coding-agent::planted-project": [{"id": "rec-planted-1", "text": "The planted project's build runs   make check\nbefore every release.", "mentioned_at": "2026-10-01T10:00:00+00:00", "type": "observation"}],
    "team-bank": [{"id": "rec-team-1", "text": "The team bank's one record.", "mentioned_at": "2026-10-02T10:00:00+00:00"}],
    "coding-agent::many-project": many,
    "coding-agent::provenance-project": [
        {"id": "rec-p-1", "text": "The agent said: I loaded the planted package.", "type": "world", "document_id": "conversation:" + SID,
         "mentioned_at": "2026-10-15T06:10:00+00:00", "context": "agent claim, not verified; session %s; 2026-10-15T06:10:00" % SID},
        {"id": "rec-p-2", "text": "The planted gateway uses blue-green deploys.", "type": "world", "document_id": "conversation:" + SID, "mentioned_at": "2026-10-15T06:10:00+00:00"},
        {"id": "rec-p-3", "text": "The planted gateway uses blue-green deploys | When: 2026-10-15 | Involving: user", "type": "observation", "mentioned_at": "2026-10-15T06:11:00+00:00"},
        {"id": "rec-p-4", "text": "Die Slack-App wurde mit dem Manifest erstellt, das nur Lesezugriff auf die Kanäle ermöglicht.", "type": "world", "document_id": "conversation:" + SID, "mentioned_at": "2026-10-15T06:10:00+00:00"},
        {"id": "rec-p-5", "text": "REF-ID: conversation:%s was mentioned on 2026-10-15." % SID, "type": "world", "document_id": "conversation:" + SID, "mentioned_at": "2026-10-15T06:10:00+00:00"},
        {"id": "rec-p-7", "text": "I pushed the planted branch.", "type": "experience", "document_id": "conversation:" + SID, "mentioned_at": "2026-10-15T06:12:00+00:00"},
        {"id": "rec-p-8", "text": "The planted Slack app was created with the read-only manifest.", "type": "world", "document_id": "conversation:" + SID, "mentioned_at": "2026-10-15T06:12:00+00:00"},
        {"id": "rec-p-9", "text": "The planted runner uses spot capacity.", "type": "observation", "mentioned_at": "2026-10-15T06:13:00+00:00", "source_fact_ids": ["rec-src-1"]},
        {"id": "rec-p-6", "text": "GPU nodes in the planted seed need gdrcopy.", "type": "world", "document_id": "seed:v3:harness-knowledge:0042", "mentioned_at": "2026-10-01T00:00:00+00:00"},
    ],
    "coding-agent::provenance-two": [
        {"id": "rec-q-1", "text": "Endpoints: api.github.com, uploads.github.com and raw.githubusercontent.com", "type": "world", "document_id": "conversation:" + SID, "mentioned_at": "2026-10-15T06:14:00+00:00"},
        {"id": "rec-q-2", "text": "Сервис был обновлён до новой версии.", "type": "world", "document_id": "conversation:" + SID, "mentioned_at": "2026-10-15T06:14:00+00:00"},
        {"id": "rec-q-3", "text": "The user asked the agent to load the planted runbook, which the agent loaded.", "type": "world", "document_id": "conversation:" + SID, "mentioned_at": "2026-10-15T06:15:00+00:00"},
        {"id": "rec-q-4", "text": "The planted runner was deployed to the spot pool.", "type": "observation", "mentioned_at": "2026-10-15T06:16:00+00:00", "source_fact_ids": ["rec-src-2"]},
        {"id": "rec-q-5", "text": "Die Knoten brauchen gdrcopy, damit der Treiber mit dem Speicher arbeiten kann.", "type": "world", "document_id": "seed:v1:de-0001", "mentioned_at": "2026-10-01T00:00:00+00:00"},
        {"id": "rec-q-6", "text": "Die Planung wurde mit dem Team besprochen, das nur heute arbeitet.", "type": "observation", "mentioned_at": "2026-10-15T06:17:00+00:00", "source_fact_ids": ["rec-src-3"]},
    ],
    "coding-agent::provenance-two#source_facts": {"rec-src-2": {"id": "rec-src-2", "text": "The planted runner was deployed to the spot pool.", "type": "world", "document_id": "conversation:a1b2c3d4-0000-4000-8000-000000000002"}, "rec-src-3": {"id": "rec-src-3", "text": "Die Planung wurde mit dem Team besprochen, das nur heute arbeitet.", "type": "world", "document_id": "conversation:a1b2c3d4-0000-4000-8000-000000000002"}},
    "coding-agent::provenance-project#source_facts": {"rec-src-1": {"id": "rec-src-1", "text": "The planted runner uses spot capacity.", "type": "world", "document_id": "conversation:a1b2c3d4-0000-4000-8000-000000000002"}},
}, open(sys.argv[1], "w"))
PY
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 ${D}/stub-api.py ${PORT} ${D}/records.json ${D}/stub.log > ${D}/stub.out 2>&1 &
STUB_PID=$!
for i in $(seq 1 50); do curl -s -o /dev/null -X POST "http://127.0.0.1:${PORT}/v1/default/banks/x/memories/recall" -d '{"query":"up?"}' && break; sleep 0.2; done
curl -s -o /dev/null -X POST "http://127.0.0.1:${PORT}/v1/default/banks/x/memories/recall" -d '{"query":"up?"}' || fail "test setup: the stub API did not come up on ${PORT}: $(cat ${D}/stub.out)"
git init -q ${D}/planted-project || fail "test setup: git init"
printf '{"serverMode": "self-hosted", "apiUrl": "http://127.0.0.1:%s", "autoInject": "none"}\n' "${PORT}" > ${D}/conf/hook.json
PROMPT="where does the orchard irrigation plan stand, and what is still open?"
OUT=$(printf '{"prompt": "%s", "cwd": "%s/planted-project", "session_id": "test-3", "hook_event_name": "UserPromptSubmit"}' "${PROMPT}" "${D}" | HINDSIGHT_HOOKS_CONFIG=${D}/conf/hook.json "${HOOK}"); RC=$?
[ ${RC} -eq 0 ] || fail "3: the hook exited ${RC}"
[ -n "${OUT}" ] || fail "3: the hook injected nothing for a bank with one record"
printf '%s' "${OUT}" > ${D}/out-3.json
[ "$(json ${D}/out-3.json "d['hookSpecificOutput']['hookEventName']")" == "UserPromptSubmit" ] || fail "3: not a UserPromptSubmit hook output: ${OUT:0:300}"
json ${D}/out-3.json "d['hookSpecificOutput']['additionalContext']" > ${D}/block-3.txt
cat > ${D}/check-block.py << 'PY'
import re, sys
lines = open(sys.argv[1]).read().rstrip("\n").split("\n")
bank, ids = sys.argv[2], sys.argv[3]
if lines[0] != '<hindsight_memory bank="%s" records="%s">' % (bank, ids): sys.exit("the opening tag does not name the bank and the record ids: " + lines[0])
if "Index entries recalled from the Hindsight bank %s" % bank not in lines[1] or "synthesis" not in lines[1] or "erify" not in lines[1]:
    sys.exit("the header does not say index / verify / no synthesis: " + lines[1])
if lines[-1] != "</hindsight_memory>": sys.exit("no closing tag: " + lines[-1])
body = lines[2:-1]
bad = [l for l in body if not re.match(r"^- \[[^\]\s]+\] \S", l)]
if bad: sys.exit("a line that is not a record with an id: " + bad[0])
if len(body) != len(ids.split(",")): sys.exit("%d record lines for %d ids" % (len(body), len(ids.split(","))))
print("\n".join(body))
PY
BODY=$(python3 ${D}/check-block.py ${D}/block-3.txt "coding-agent::planted-project" "rec-planted-1" 2>&1) || fail "3: ${BODY}"
[ "${BODY}" == "- [rec-planted-1] The planted project's build runs make check before every release. (2026-10-01)" ] || fail "3: the record line is not the record, its id and its date: ${BODY}"
LAST=$(tail -1 ${D}/stub.log)
[ "${LAST}" == "{\"bank\": \"coding-agent::planted-project\", \"query\": \"${PROMPT}\"}" ] || fail "3: the stub did not see the repository's bank with the prompt as the query: ${LAST}"
grep -q "orchard" ${D}/block-3.txt && fail "3: the block repeats the prompt's subject (a sentence of its own): $(cat ${D}/block-3.txt)"
# planted control: the checker refuses a sentence of the block's own between the records
python3 - ${D}/block-3.txt ${D}/block-3-bad.txt << 'PY'
import sys
lines = open(sys.argv[1]).read().rstrip("\n").split("\n")
lines.insert(3, "The orchard irrigation plan is part of the planted project.")
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PY
python3 ${D}/check-block.py ${D}/block-3-bad.txt "coding-agent::planted-project" "rec-planted-1" > ${D}/check-bad.log 2>&1 && fail "3: PLANTED CONTROL: a block with a sentence of its own passed the checker"
grep -q "not a record with an id" ${D}/check-bad.log || fail "3: the control failed for the wrong reason: $(cat ${D}/check-bad.log)"
echo "ok 3 - one record in the bank, a prompt about something else: one block naming bank coding-agent::planted-project and records=rec-planted-1, a header saying index / verify / no synthesis, one record line with the id, the text and the date, nothing else; the stub saw the bank and the prompt; the control (a sentence of the block's own) is refused"

# --- 4. controls ---
git init -q ${D}/empty-project && git init -q ${D}/many-project || fail "test setup: git init"
run_hook() { printf '{"prompt": "%s", "cwd": "%s", "session_id": "test-4"}' "$1" "$2" | HINDSIGHT_API_URL=http://127.0.0.1:${PORT} HINDSIGHT_RECALL_TIMEOUT=2 "${HOOK}"; }
OUT=$(run_hook "anything" ${D}/empty-project); RC=$?
[ ${RC} -eq 0 ] && [ -z "${OUT}" ] || fail "4: an empty recall must inject nothing and exit 0 (rc ${RC}): ${OUT:0:200}"
OUT=$(printf '{"prompt": "anything", "cwd": "%s/planted-project"}' "${D}" | HINDSIGHT_API_URL=http://127.0.0.1:1 HINDSIGHT_RECALL_TIMEOUT=2 "${HOOK}"); RC=$?
[ ${RC} -eq 0 ] && [ -z "${OUT}" ] || fail "4: a dead API must inject nothing and exit 0 (rc ${RC}): ${OUT:0:200}"
OUT=$(printf '{"prompt": "anything", "cwd": "%s/planted-project"}' "${D}" | HINDSIGHT_BANK_ID=team-bank HINDSIGHT_API_URL=http://127.0.0.1:${PORT} "${HOOK}")
printf '%s' "${OUT}" > ${D}/out-4-bank.json
json ${D}/out-4-bank.json "d['hookSpecificOutput']['additionalContext']" > ${D}/block-4-bank.txt 2>/dev/null || fail "4: no block for HINDSIGHT_BANK_ID=team-bank: ${OUT:0:200}"
python3 ${D}/check-block.py ${D}/block-4-bank.txt "team-bank" "rec-team-1" > /dev/null 2>&1 || fail "4: HINDSIGHT_BANK_ID did not win over the repository's name: $(cat ${D}/block-4-bank.txt)"
[ "$(tail -1 ${D}/stub.log)" == '{"bank": "team-bank", "query": "anything"}' ] || fail "4: the stub did not see team-bank: $(tail -1 ${D}/stub.log)"
git -C ${D}/planted-project -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m init || fail "test setup: a commit for the worktree"
git -C ${D}/planted-project worktree add -q ${D}/linked-wt > /dev/null 2>&1 || fail "test setup: git worktree add"
OUT=$(run_hook "anything" ${D}/linked-wt)
[ -n "${OUT}" ] || fail "4: a linked worktree injected nothing (its bank must be the main worktree's)"
[ "$(tail -1 ${D}/stub.log)" == '{"bank": "coding-agent::planted-project", "query": "anything"}' ] || fail "4: a linked worktree did not resolve to its main worktree's bank: $(tail -1 ${D}/stub.log)"
OUT=$(run_hook "anything" ${D}/plain-dir)
[ "$(tail -1 ${D}/stub.log)" == '{"bank": "coding-agent::plain-dir", "query": "anything"}' ] || fail "4: a cwd outside a repository is not its own name: $(tail -1 ${D}/stub.log)"
OUT=$(printf '{"prompt": "anything", "cwd": "%s/planted-project"}' "${D}" | HINDSIGHT_DISABLE_HOOKS=1 HINDSIGHT_API_URL=http://127.0.0.1:${PORT} "${HOOK}")
[ -z "${OUT}" ] || fail "4: HINDSIGHT_DISABLE_HOOKS=1 still injected: ${OUT:0:200}"
OUT=$(run_hook "anything" ${D}/many-project)
printf '%s' "${OUT}" > ${D}/out-4-many.json
json ${D}/out-4-many.json "d['hookSpecificOutput']['additionalContext']" > ${D}/block-4-many.txt 2>/dev/null || fail "4: no block for the many project: ${OUT:0:200}"
IDS=$(python3 -c "print(','.join('rec-many-%02d' % i for i in range(8)))")
python3 ${D}/check-block.py ${D}/block-4-many.txt "coding-agent::many-project" "${IDS}" > /dev/null 2>&1 || fail "4: eleven records were not cut to the first eight: $(head -1 ${D}/block-4-many.txt)"
echo "ok 4 - controls: an empty recall and a dead API inject nothing (exit 0); HINDSIGHT_BANK_ID wins; a linked worktree takes its main worktree's bank; a plain directory is its own name; HINDSIGHT_DISABLE_HOOKS=1 injects nothing; eleven records are cut to eight"

# --- 5. provenance and de-duplication: each line says where its record comes from; a repeat, a marker, another language are left out ---
git init -q ${D}/provenance-project || fail "test setup: git init"
OUT=$(run_hook "anything" ${D}/provenance-project)
printf '%s' "${OUT}" > ${D}/out-5.json
json ${D}/out-5.json "d['hookSpecificOutput']['additionalContext']" > ${D}/block-5.txt 2>/dev/null || fail "5: no block for the provenance project: ${OUT:0:200}"
BODY=$(python3 ${D}/check-block.py ${D}/block-5.txt "coding-agent::provenance-project" "rec-p-1,rec-p-2,rec-p-7,rec-p-8,rec-p-9,rec-p-6" 2>&1) \
	|| fail "5: not the six records (the repeat, the marker-only and the German record left out): ${BODY}; $(head -1 ${D}/block-5.txt)"
cat > ${D}/want-5.txt << 'EOF'
- [rec-p-1] The agent said: I loaded the planted package. (2026-10-15; session 5f1fae85; agent claim, not verified)
- [rec-p-2] The planted gateway uses blue-green deploys. (2026-10-15; session 5f1fae85; not verified)
- [rec-p-7] I pushed the planted branch. (2026-10-15; session 5f1fae85; agent claim, not verified)
- [rec-p-8] The planted Slack app was created with the read-only manifest. (2026-10-15; session 5f1fae85; agent claim, not verified)
- [rec-p-9] The planted runner uses spot capacity. (2026-10-15; from session a1b2c3d4; not verified)
- [rec-p-6] GPU nodes in the planted seed need gdrcopy. (2026-10-01; document seed:v3:harness-knowledge:0042)
EOF
[ "${BODY}" == "$(cat ${D}/want-5.txt)" ] || fail "5: the record lines do not carry their provenance as expected: $(diff <(echo "${BODY}") ${D}/want-5.txt)"
echo "ok 5 - provenance: each record line names its session (or document) and its date, each session record says 'not verified' (an observation whose source facts are a session's 'from session <id>; not verified'), the agent's claims 'agent claim, not verified' (marked by the guard or not yet); the repeat of a record (its observation with When/Involving parts), the marker-only and the German record are left out"

# --- 5b. provenance of records the language check must keep, and of one it must leave out ---
git init -q ${D}/provenance-two || fail "test setup: git init"
OUT=$(run_hook "anything" ${D}/provenance-two)
printf '%s' "${OUT}" > ${D}/out-5b.json
json ${D}/out-5b.json "d['hookSpecificOutput']['additionalContext']" > ${D}/block-5b.txt 2>/dev/null || fail "5b: no block for the second provenance project: ${OUT:0:200}"
BODY=$(python3 ${D}/check-block.py ${D}/block-5b.txt "coding-agent::provenance-two" "rec-q-1,rec-q-3,rec-q-4,rec-q-5" 2>&1) \
	|| fail "5b: not the four records (the Cyrillic session record left out): ${BODY}; $(head -1 ${D}/block-5b.txt)"
cat > ${D}/want-5b.txt << 'EOF'
- [rec-q-1] Endpoints: api.github.com, uploads.github.com and raw.githubusercontent.com (2026-10-15; session 5f1fae85; not verified)
- [rec-q-3] The user asked the agent to load the planted runbook, which the agent loaded. (2026-10-15; session 5f1fae85; agent claim, not verified)
- [rec-q-4] The planted runner was deployed to the spot pool. (2026-10-15; from session a1b2c3d4; derived claim, not verified)
- [rec-q-5] Die Knoten brauchen gdrcopy, damit der Treiber mit dem Speicher arbeiten kann. (2026-10-01; document seed:v1:de-0001)
EOF
[ "${BODY}" == "$(cat ${D}/want-5b.txt)" ] || fail "5b: the record lines do not carry their provenance as expected: $(diff <(echo "${BODY}") ${D}/want-5b.txt)"
echo "ok 5b - a session record listing hosts is kept with its provenance, a Cyrillic one is left out; the user's request followed by the agent's account of the outcome is the agent's claim; an observation that states an outcome from a session's facts is a derived claim; a German record from a seed document is kept (only session records and their observations are checked for language), and a German observation from a session's facts is left out"
echo "Test-hindsight-recall-hook succeeded"
