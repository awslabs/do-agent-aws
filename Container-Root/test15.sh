#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the hindsight memory wiring: the claude CLI's memory hooks write to the SELF-HOSTED
# hindsight-api on :8888 - the store the Hindsight UI shows and /agent/hindsight-seed.sh fills - and
# what they wrote reads back through that same API (setup/install-hindsight.sh, the settings merge in
# setup/install-plugins.sh, the build pre-warm in setup/install-hindsight-ui.sh, the UI-first order
# in /startup.sh and the bounded wait in /agent/tmux-claude.sh). Before this wiring the image had NO
# hooks at all (install-plugins.sh overwrote settings.json after the hindsight installer had merged
# them) and the hooks' configured server was a private daemon on :9077 that the UI never showed.
#
# Properties proven (each check FAILS if the property is removed):
#   1. all new/changed scripts parse (bash -n, sh -n for startup.sh)
#   2. settings.json carries the three hindsight hooks (SessionStart / UserPromptSubmit / Stop ->
#      the installed ~/.hindsight/coding-agents/dist/claude-*-hook.js) - the merge survived the
#      plugin step - and the hindsight MCP server is registered in .claude.json
#   2b. /agent/hindsight-hooks-repair.sh (run by ui-start.sh with the API) puts the three hooks back
#      into a persisted settings.json that lost them (an agent-state folder first seeded by the
#      pre-fix image keeps its hook-less file): a copy stripped of its hooks gets exactly them back,
#      every other key untouched; a second run changes nothing; the real file is never touched
#   2c. the same repair gives a persisted hooks config without it the bank map that sends coding-agent::unknown to
#      coding-agent::wd, every other key kept; a second run changes nothing
#   3. ~/.hindsight/coding-agent.json is self-hosted and its apiUrl port is the hindsight-api port
#      (UI_PORT_HINDSIGHT_API, 8888): one store, not the daemon; its bank map sends coding-agent::unknown (the bank
#      the hooks give a session outside any directory, cwd "/") to coding-agent::wd
#   4. startup.sh starts the UIs before the tmux session and launches the seed detached; the pane
#      program waits for the memory API (bounded) only when the UIs are on - and does not when off
#   -- live, where hindsight-api is installed (the image; skipped from a bare checkout) --
#   5. hindsight-api answers /health on the hooks' port (started here with a TEST-LOCAL home for its
#      database and the image's baked model cache; an API already answering there is reused)
#   6. a Stop hook fire (the installed claude-stop-hook.js, a Claude-Code-shaped stdin event, a planted
#      git repo as cwd, a planted transcript) REACHES the API: the per-repo bank coding-agent::<repo>
#      appears with a retain operation
#   7. planted controls: HINDSIGHT_DISABLED=1 creates nothing; a dead apiUrl creates nothing and the
#      hook logs the write-back failure (the fire in 6 was not vacuous)
#   7b. a Stop hook fired from / with no cwd in its event lands in coding-agent::wd and no bank named
#      coding-agent::unknown appears; PLANTED CONTROL: with the bank map taken out of a copy of the config the same
#      fire creates coding-agent::unknown (deleted again). Only on a test-local API: it writes into coding-agent::wd
#   8. read-back via :8888 (needs the LLM the API extracts with - skipped honestly when the API's
#      own health/llm reports no working provider): the document conversation:<session> carries the
#      planted token in its text, memories/list?q=<token> finds it, total_nodes > 0
# Uses test-local directories (/tmp/hindsight-hooks-smoke, or TEST15_DIR); the hook's own state
# goes to a test-local HOME while it reads the REAL config through HINDSIGHT_CONFIG, so nothing
# under /home/agent/.hindsight is touched.

D=${TEST15_DIR:-/tmp/hindsight-hooks-smoke}
rm -rf "${D:?}"
mkdir -p "${D}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
SETUP_DIR="${BASE_DIR%/}/setup"
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-/home/agent/.claude}
HOOKS_DIST=/home/agent/.hindsight/coding-agents/dist
HOOK_CONFIG=/home/agent/.hindsight/coding-agent.json
API_PORT=${UI_PORT_HINDSIGHT_API:-8888}
API=http://127.0.0.1:${API_PORT}
HINDSIGHT_BIN=/home/hindsight/.local/bin/hindsight-api
API_PGID=""

fail()
{
	echo "Test15 FAILED: $1"
	exit 1
}

cleanup()
{
	# a live API that was reused keeps running; the bank this test planted in it does not
	if [ "${REUSED:-false}" == "true" ] && [ -n "${BANK_URL:-}" ]; then
		curl -s -o /dev/null --max-time 10 -X DELETE "${BANK_URL}" 2>/dev/null
	fi
	if [ -n "${API_PGID}" ]; then
		kill -TERM -- "-${API_PGID}" 2>/dev/null
		for i in $(seq 1 30); do
			kill -0 -- "-${API_PGID}" 2>/dev/null || break
			sleep 1
		done
		kill -KILL -- "-${API_PGID}" 2>/dev/null
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# json <file-or-'-'> <python expression over d> - one JSON field, no jq in the image
json()
{
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1]) if sys.argv[1] != "-" else sys.stdin); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null
}

# --- 1. syntax ---
for S in "${AGENT_DIR}/hindsight-seed.sh" "${AGENT_DIR}/tmux-claude.sh" "${SETUP_DIR}/install-hindsight.sh" \
         "${SETUP_DIR}/install-plugins.sh" "${SETUP_DIR}/install-hindsight-ui.sh"; do
	[ -f "${S}" ] || fail "missing ${S}"
	bash -n "${S}" || fail "bash -n ${S}"
done
STARTUP=${BASE_DIR%/}/startup.sh
[ -f "${STARTUP}" ] || STARTUP=/startup.sh
[ -f "${STARTUP}" ] && { sh -n "${STARTUP}" || fail "sh -n ${STARTUP}"; }
echo "ok 1 - syntax"

# --- 2. the hooks are registered: the plugin step merged, not overwrote ---
SETTINGS=${CLAUDE_DIR}/settings.json
[ -f "${SETTINGS}" ] || fail "no ${SETTINGS}"
for EV_ENTRY in SessionStart:claude-sessionstart-hook.js UserPromptSubmit:claude-hook.js Stop:claude-stop-hook.js; do
	EV=${EV_ENTRY%%:*}
	ENTRY=${EV_ENTRY#*:}
	json "${SETTINGS}" "json.dumps(d.get('hooks',{}).get('${EV}',[]))" | grep -qF "/.hindsight/coding-agents/dist/${ENTRY}" \
		|| fail "${SETTINGS} lacks the hindsight ${EV} hook (${ENTRY}) - install-plugins.sh overwrote the settings again?"
done
# the plugin step's own keys must be there too (the merge kept both sides)
[ "$(json "${SETTINGS}" "d.get('env',{}).get('CLAUDE_CODE_USE_BEDROCK')")" == "1" ] || fail "settings.json lost env.CLAUDE_CODE_USE_BEDROCK"
[ "$(json "${SETTINGS}" "d.get('enabledPlugins',{}).get('claude-mem@thedotmack')")" == "True" ] || fail "settings.json lost enabledPlugins.claude-mem"
json "${CLAUDE_DIR}/.claude.json" "json.dumps(d.get('mcpServers',{}).get('hindsight',{}))" | grep -qF "coding-agents/dist/mcp-server.js" \
	|| fail "the hindsight MCP server is not registered in ${CLAUDE_DIR}/.claude.json"
echo "ok 2 - settings.json carries the SessionStart/UserPromptSubmit/Stop hindsight hooks next to the plugin keys; MCP server registered"

# --- 2b. the startup repair of a persisted settings.json that lost its hooks ---
REPAIR="${AGENT_DIR}/hindsight-hooks-repair.sh"
[ -f "${REPAIR}" ] || fail "missing ${REPAIR}"
bash -n "${REPAIR}" || fail "bash -n ${REPAIR}"
REAL_SUM=$(md5sum "${SETTINGS}" | cut -d' ' -f1)
python3 - "${SETTINGS}" "${D}/settings-stripped.json" << 'PY' || fail "could not plant the hook-less settings copy"
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("hooks", None)
d["plantedKey"] = {"kept": True}
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
CLAUDE_SETTINGS="${D}/settings-stripped.json" HINDSIGHT_HOOKS_DIST="${HOOKS_DIST}" "${REPAIR}" > "${D}/repair-1.log" 2>&1 || fail "hindsight-hooks-repair.sh failed: $(cat "${D}/repair-1.log")"
grep -q "restored SessionStart/UserPromptSubmit/Stop" "${D}/repair-1.log" || fail "the repair did not report restoring the three hooks: $(cat "${D}/repair-1.log")"
for EV_ENTRY in SessionStart:claude-sessionstart-hook.js UserPromptSubmit:claude-hook.js Stop:claude-stop-hook.js; do
	json "${D}/settings-stripped.json" "json.dumps(d.get('hooks',{}).get('${EV_ENTRY%%:*}',[]))" | grep -qF "${HOOKS_DIST}/${EV_ENTRY#*:}" \
		|| fail "the repair did not restore the ${EV_ENTRY%%:*} hook naming ${HOOKS_DIST}/${EV_ENTRY#*:}"
done
[ "$(json "${D}/settings-stripped.json" "d.get('plantedKey',{}).get('kept')")" == "True" ] || fail "the repair dropped another settings key"
[ "$(json "${D}/settings-stripped.json" "d.get('env',{}).get('CLAUDE_CODE_USE_BEDROCK')")" == "1" ] || fail "the repair dropped env.CLAUDE_CODE_USE_BEDROCK"
SUM1=$(md5sum "${D}/settings-stripped.json" | cut -d' ' -f1)
CLAUDE_SETTINGS="${D}/settings-stripped.json" HINDSIGHT_HOOKS_DIST="${HOOKS_DIST}" "${REPAIR}" > "${D}/repair-2.log" 2>&1 || fail "second repair run failed"
grep -q "present in" "${D}/repair-2.log" || fail "the second repair run did not report the hooks present: $(cat "${D}/repair-2.log")"
[ "$(md5sum "${D}/settings-stripped.json" | cut -d' ' -f1)" == "${SUM1}" ] || fail "the second repair run changed the file (not idempotent)"
[ "$(md5sum "${SETTINGS}" | cut -d' ' -f1)" == "${REAL_SUM}" ] || fail "the repair touched the real ${SETTINGS}"
echo "ok 2b - hindsight-hooks-repair.sh restores the three hooks into a stripped copy, keeps every other key, is idempotent, leaves the real file alone"

# --- 2c. the same repair gives a persisted hooks config the coding-agent::unknown bank map ---
printf '{"serverMode":"self-hosted","apiUrl":"http://localhost:8888","autoInject":"none","plantedKey":"kept"}\n' > "${D}/config-old.json"
CLAUDE_SETTINGS="${D}/settings-stripped.json" HINDSIGHT_HOOKS_DIST="${HOOKS_DIST}" HINDSIGHT_AGENT_CONF="${D}/config-old.json" "${REPAIR}" > "${D}/repair-3.log" 2>&1 \
	|| fail "the repair failed on an old hooks config: $(cat "${D}/repair-3.log")"
[ "$(json "${D}/config-old.json" "d.get('banks',{}).get('coding-agent::unknown',{}).get('bank')")" == "coding-agent::wd" ] \
	|| fail "the repair did not give the old config the coding-agent::unknown -> coding-agent::wd bank map: $(cat "${D}/config-old.json")"
[ "$(json "${D}/config-old.json" "d.get('plantedKey')")" == "kept" ] || fail "the repair dropped another key of the hooks config"
grep -q "coding-agent::unknown -> coding-agent::wd" "${D}/repair-3.log" || fail "the repair did not say it added the bank map: $(cat "${D}/repair-3.log")"
SUM3=$(md5sum "${D}/config-old.json" | cut -d' ' -f1)
CLAUDE_SETTINGS="${D}/settings-stripped.json" HINDSIGHT_HOOKS_DIST="${HOOKS_DIST}" HINDSIGHT_AGENT_CONF="${D}/config-old.json" "${REPAIR}" > "${D}/repair-4.log" 2>&1 || fail "second repair run on the config failed"
[ "$(md5sum "${D}/config-old.json" | cut -d' ' -f1)" == "${SUM3}" ] || fail "the second repair run changed the hooks config (not idempotent)"
echo "ok 2c - hindsight-hooks-repair.sh gives an old hooks config the coding-agent::unknown -> coding-agent::wd bank map, keeps its other keys, is idempotent"

# --- 3. self-hosted at the hindsight-api port ---
[ -f "${HOOK_CONFIG}" ] || fail "no ${HOOK_CONFIG}"
[ "$(json "${HOOK_CONFIG}" "d.get('serverMode')")" == "self-hosted" ] || fail "${HOOK_CONFIG} is not self-hosted: $(cat "${HOOK_CONFIG}")"
HOOK_URL=$(json "${HOOK_CONFIG}" "d.get('apiUrl','')")
HOOK_PORT=$(echo "${HOOK_URL}" | sed -nE 's#^https?://[^/:]+:([0-9]+).*#\1#p')
[ "${HOOK_PORT}" == "${API_PORT}" ] || fail "the hooks' apiUrl ${HOOK_URL} is not on the hindsight-api port ${API_PORT}"
[ "$(json "${HOOK_CONFIG}" "d.get('banks',{}).get('coding-agent::unknown',{}).get('bank')")" == "coding-agent::wd" ] \
	|| fail "${HOOK_CONFIG} does not send a session outside any directory to coding-agent::wd: $(cat "${HOOK_CONFIG}")"
echo "ok 3 - ${HOOK_CONFIG}: self-hosted at ${HOOK_URL} (the UI's hindsight-api, not the :9077 daemon); coding-agent::unknown -> coding-agent::wd"

# --- 4. startup order and the pane program's bounded wait (static + a dry run of the wait) ---
if [ -f "${STARTUP}" ]; then
	UI_LINE=$(grep -n '/agent/ui-start.sh$' "${STARTUP}" | head -1 | cut -d: -f1)
	TMUX_LINE=$(grep -n '/agent/tmux-session-start.sh$' "${STARTUP}" | head -1 | cut -d: -f1)
	SEED_LINE=$(grep -n 'hindsight-seed.sh' "${STARTUP}" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
	[ -n "${UI_LINE}" ] && [ -n "${TMUX_LINE}" ] && [ "${UI_LINE}" -lt "${TMUX_LINE}" ] \
		|| fail "startup.sh does not start the UIs (line ${UI_LINE:-none}) before the tmux session (line ${TMUX_LINE:-none})"
	[ -n "${SEED_LINE}" ] && grep -qE 'setsid nohup /agent/hindsight-seed.sh' "${STARTUP}" || fail "startup.sh does not launch /agent/hindsight-seed.sh detached"
	grep -qE 'HINDSIGHT_SEED:-true}" != "false"' "${STARTUP}" || fail "startup.sh has no HINDSIGHT_SEED=false opt-out around the seed"
fi
# the wait is bounded and only on when the UIs are: a dead port with a 2 s budget must cost about
# 2 s and continue, and UI_START unset must not wait at all. The pane program's claude step is
# skipped (AGENT_TMUX_CLAUDE=false) so only the wait is timed; exec bash is replaced by a no-op.
T0=$(date +%s)
( export UI_START=true UI_HINDSIGHT=true UI_PORT_HINDSIGHT_API=9 HINDSIGHT_WAIT_SECS=2 AGENT_TMUX_CLAUDE=true CLAUDE_BIN=/bin/true
  sed 's/^exec bash$/exit 0/' "${AGENT_DIR}/tmux-claude.sh" > "${D}/tmux-claude-under-test.sh"
  bash "${D}/tmux-claude-under-test.sh" > "${D}/wait-on.log" 2>&1 )
T1=$(date +%s)
grep -q "hindsight memory API not answering at http://127.0.0.1:9/health after 2s - starting claude anyway" "${D}/wait-on.log" \
	|| fail "tmux-claude.sh did not report the bounded wait running out: $(cat "${D}/wait-on.log")"
[ $((T1 - T0)) -ge 2 ] && [ $((T1 - T0)) -le 8 ] || fail "the bounded wait took $((T1 - T0))s for a 2 s budget"
( export UI_HINDSIGHT=true UI_PORT_HINDSIGHT_API=9 HINDSIGHT_WAIT_SECS=2 AGENT_TMUX_CLAUDE=true CLAUDE_BIN=/bin/true
  unset UI_START; bash "${D}/tmux-claude-under-test.sh" > "${D}/wait-off.log" 2>&1 )
grep -q "hindsight memory API" "${D}/wait-off.log" && fail "tmux-claude.sh waited for the memory API with UI_START unset: $(cat "${D}/wait-off.log")"
echo "ok 4 - startup.sh: UIs first, seed detached with the SEED=false gate; tmux-claude.sh waits a bounded time only when the UIs are on"

# --- live preflight: hindsight-api installed, the hooks dist present ---
if [ ! -x "${HINDSIGHT_BIN}" ] || [ ! -f "${HOOKS_DIST}/claude-stop-hook.js" ]; then
	echo "ok 5-8 - (skipped: hindsight-api or the hooks dist are not installed here - the live checks run in the image)"
	echo "Test15 succeeded"
	exit 0
fi

# --- 5. the API on the hooks' port ---
api_healthy()
{
	curl -sf --max-time 3 "${API}/health" 2>/dev/null | grep -q '"healthy"'
}
REUSED=false
if api_healthy; then
	REUSED=true
	echo "    (an API already answers on ${API} - reusing it, it is left running)"
else
	# A test-local HOME for the API: its own pg0 cluster, never the persisted one under
	# /home/hindsight/.pg0 (which the live container may have open); the baked model cache is
	# shared read-only through HF_HOME so no download happens here. The bank LLM health probe is
	# enabled so check 8 can tell "no provider" from "broken".
	HHOME=${D}/hindsight-home
	mkdir -p "${HHOME}"
	# the agent's AWS config for the API (what ui-start.sh does before the real API)
	"${AGENT_DIR}/hindsight-aws-config.sh" > /dev/null 2>&1 || true
	setsid env HOME="${HHOME}" HF_HOME=/home/hindsight/.cache/huggingface \
		HINDSIGHT_API_LLM_PROVIDER="${HINDSIGHT_API_LLM_PROVIDER:-bedrock}" HINDSIGHT_API_WORKER_ID=test15 \
	AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-/home/hindsight/.aws/config}" AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/home/hindsight/.aws/credentials}" \
		HINDSIGHT_API_ENABLE_BANK_LLM_HEALTH=true \
		"${HINDSIGHT_BIN}" --host 127.0.0.1 --port "${API_PORT}" > "${D}/api.log" 2>&1 &
	API_PGID=$!
	for i in $(seq 1 300); do
		api_healthy && break
		sleep 1
	done
	api_healthy || { tail -20 "${D}/api.log"; fail "hindsight-api did not answer ${API}/health within 300s"; }
fi
echo "ok 5 - hindsight-api healthy at ${API} (reused: ${REUSED})"

# --- 6. a Stop hook fire reaches the API ---
command -v git > /dev/null || fail "git is not installed (setup/install-comms.sh) - the hook names the bank after the git project"
REPO_NAME=t15-planted-repo-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
REPO=${D}/${REPO_NAME}
git init -q "${REPO}" && git -C "${REPO}" -c user.name=test15 -c user.email=test15@localhost commit -q --allow-empty -m init \
	|| fail "could not plant the git repo ${REPO}"
BANK="coding-agent::${REPO_NAME}"
BANK_URL="${API}/v1/default/banks/$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${BANK}")"
TOKEN=plantedtoken$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
HOOK_HOME=${D}/hook-home
mkdir -p "${HOOK_HOME}"
# fire <session-id> <token> <log> [env...] - one Stop hook run: Claude Code's stdin event over a
# planted two-turn transcript; HOME is test-local (the hook's cursors/logs), the config is the REAL one
fire()
{
	SID=$1
	TOK=$2
	LOG=$3
	shift 3
	TS=$(date -u +%FT%T.000Z)
	cat > "${D}/transcript-${SID}.jsonl" << EOF
{"type":"user","sessionId":"${SID}","timestamp":"${TS}","message":{"role":"user","content":"Please remember for later: the deployment codeword for this project is ${TOK}. It unlocks the staging rollout."}}
{"type":"assistant","sessionId":"${SID}","timestamp":"${TS}","message":{"role":"assistant","content":[{"type":"text","text":"Noted. The deployment codeword ${TOK} is recorded for the staging rollout."}]}}
EOF
	printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"Stop","stop_hook_active":false}\n' \
		"${SID}" "${D}/transcript-${SID}.jsonl" "${REPO}" \
		| env HOME="${HOOK_HOME}" HINDSIGHT_CONFIG="${HOOK_CONFIG}" HINDSIGHT_LOG_LEVEL=debug HINDSIGHT_LOG_FILE="${LOG}" \
		  HINDSIGHT_DIAG_FILE="${D}/diag.jsonl" "$@" timeout 120 node "${HOOKS_DIST}/claude-stop-hook.js" > "${LOG}.out" 2> "${LOG}.err"
}
bank_ops()
{
	# bank_ops [<bank url>] - retain operations recorded for the bank (default ${BANK_URL}; 0 when the bank does not exist); the API's own
	# consolidation/maintenance operations are not counted as "the hook wrote something".
	# Paged: the API caps limit at 100.
	python3 - "${1:-${BANK_URL}}" << 'PY' 2>/dev/null || echo 0
import json, sys, urllib.request
base = sys.argv[1]
n = offset = 0
while True:
    with urllib.request.urlopen(f"{base}/operations?limit=100&offset={offset}", timeout=10) as r:
        d = json.load(r)
    ops = d.get("operations", [])
    n += sum(1 for o in ops if o.get("task_type") in ("retain", "batch_retain"))
    if len(ops) < 100:
        break
    offset += 100
print(n)
PY
}
bank_listed()
{
	curl -s --max-time 10 "${API}/v1/default/banks?limit=100" | json - "[b['bank_id'] for b in d.get('banks',[])]" | grep -qF "'${BANK}'"
}
bank_listed && fail "the planted bank ${BANK} already exists before the hook fired"
SID1=$(cat /proc/sys/kernel/random/uuid)
fire "${SID1}" "${TOKEN}" "${D}/plugin-1.log"
RC=$?
[ ${RC} -eq 0 ] || fail "claude-stop-hook.js exited ${RC}: $(cat "${D}/plugin-1.log.err" | head -3)"
grep -q "retain_ok" "${D}/plugin-1.log" || fail "the hook did not report retain_ok: $(tail -5 "${D}/plugin-1.log")"
OPS=0
for i in $(seq 1 30); do
	OPS=$(bank_ops)
	[ "${OPS:-0}" -ge 1 ] 2>/dev/null && break
	sleep 1
done
[ "${OPS:-0}" -ge 1 ] || fail "no retain operation reached ${BANK} on ${API} after the hook fired (operations=${OPS})"
bank_listed || fail "${BANK} is not listed by ${API}/v1/default/banks"
echo "ok 6 - Stop hook fire: retain_ok, bank ${BANK} created on ${API} with ${OPS} operation(s)"

# --- 7. planted controls ---
OPS_BEFORE=$(bank_ops)
SID2=$(cat /proc/sys/kernel/random/uuid)
fire "${SID2}" "disabledtoken" "${D}/plugin-2.log" HINDSIGHT_DISABLED=1
sleep 3
[ "$(bank_ops)" == "${OPS_BEFORE}" ] || fail "HINDSIGHT_DISABLED=1 still wrote to the bank (operations ${OPS_BEFORE} -> $(bank_ops))"
grep -q "retain_ok" "${D}/plugin-2.log" 2>/dev/null && fail "HINDSIGHT_DISABLED=1 still reported retain_ok"
printf '{"serverMode":"self-hosted","apiUrl":"http://127.0.0.1:9"}\n' > "${D}/config-dead.json"
SID3=$(cat /proc/sys/kernel/random/uuid)
fire "${SID3}" "deadtoken" "${D}/plugin-3.log" HINDSIGHT_CONFIG="${D}/config-dead.json"
sleep 3
[ "$(bank_ops)" == "${OPS_BEFORE}" ] || fail "a dead apiUrl still wrote to the bank (operations ${OPS_BEFORE} -> $(bank_ops))"
grep -q "session write-back failed" "${D}/plugin-3.log" || fail "the hook did not log the write-back failure against the dead apiUrl: $(tail -3 "${D}/plugin-3.log")"
echo "ok 7 - planted controls: HINDSIGHT_DISABLED=1 writes nothing; a dead apiUrl writes nothing and the hook logs 'session write-back failed'"

# --- 7b. a session outside any directory gets no bank named coding-agent::unknown ---
bank_url_of() { echo "${API}/v1/default/banks/$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1")"; }
listed() { curl -s --max-time 10 "${API}/v1/default/banks?limit=100" | json - "[b['bank_id'] for b in d.get('banks',[])]" | grep -qF "'$1'"; }
# fire_root <session-id> <log> [env...] - fire()'s Stop event without a cwd, the hook started at /
fire_root()
{
	SID=$1
	LOG=$2
	shift 2
	TS=$(date -u +%FT%T.000Z)
	cat > "${D}/transcript-${SID}.jsonl" << EOF
{"type":"user","sessionId":"${SID}","timestamp":"${TS}","message":{"role":"user","content":"Note for later: the root-session marker is ${SID}."}}
{"type":"assistant","sessionId":"${SID}","timestamp":"${TS}","message":{"role":"assistant","content":[{"type":"text","text":"Noted: the root-session marker ${SID}."}]}}
EOF
	( cd / && printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","stop_hook_active":false}\n' "${SID}" "${D}/transcript-${SID}.jsonl" \
		| env HOME="${HOOK_HOME}" HINDSIGHT_CONFIG="${HOOK_CONFIG}" HINDSIGHT_LOG_LEVEL=debug HINDSIGHT_LOG_FILE="${LOG}" \
		  HINDSIGHT_DIAG_FILE="${D}/diag.jsonl" "$@" timeout 120 node "${HOOKS_DIST}/claude-stop-hook.js" > "${LOG}.out" 2> "${LOG}.err" )
}
if [ "${REUSED}" == "true" ]; then
	echo "ok 7b - (skipped: the API answering here is the running one, and this check writes into its coding-agent::wd)"
else
	listed "coding-agent::unknown" && fail "7b: coding-agent::unknown exists before the root fire"
	WD_URL=$(bank_url_of "coding-agent::wd")
	WD_OPS0=$(bank_ops "${WD_URL}")
	fire_root "$(cat /proc/sys/kernel/random/uuid)" "${D}/plugin-root.log" || fail "7b: the Stop hook fired from / exited non-zero: $(head -3 "${D}/plugin-root.log.err")"
	grep -q "retain_ok" "${D}/plugin-root.log" || fail "7b: the root fire did not report retain_ok: $(tail -5 "${D}/plugin-root.log")"
	for i in $(seq 1 30); do [ "$(bank_ops "${WD_URL}")" -gt "${WD_OPS0:-0}" ] 2>/dev/null && break; sleep 1; done
	[ "$(bank_ops "${WD_URL}")" -gt "${WD_OPS0:-0}" ] 2>/dev/null || fail "7b: the root fire's retain did not reach coding-agent::wd (operations ${WD_OPS0} -> $(bank_ops "${WD_URL}"))"
	listed "coding-agent::unknown" && fail "7b: the root fire created coding-agent::unknown"
	# planted control: the bank map taken out of a copy of the config
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("banks", None); json.dump(d, open(sys.argv[2], "w"))' "${HOOK_CONFIG}" "${D}/config-nomap.json" \
		|| fail "7b: could not plant the config without the bank map"
	fire_root "$(cat /proc/sys/kernel/random/uuid)" "${D}/plugin-root-nomap.log" HINDSIGHT_CONFIG="${D}/config-nomap.json"
	for i in $(seq 1 30); do listed "coding-agent::unknown" && break; sleep 1; done
	CONTROL_SAW=$(listed "coding-agent::unknown" && echo yes || echo no)
	curl -s -o /dev/null --max-time 30 -X DELETE "$(bank_url_of "coding-agent::unknown")"
	[ "${CONTROL_SAW}" == "yes" ] || fail "7b planted control: without the bank map the root fire created no coding-agent::unknown (the check would not see one)"
	echo "ok 7b - a Stop hook fired from / with no cwd lands in coding-agent::wd and creates no coding-agent::unknown; planted control: without the bank map it creates coding-agent::unknown"
fi

# --- 8. read-back through :8888 (the extraction needs the API's LLM) ---
LLM=$(curl -s --max-time 60 -X POST -H 'content-type: application/json' --data '{}' "${BANK_URL}/health/llm" \
	| json - "next((o.get('status','?') for o in d.get('operations',[]) if o.get('operation')=='retain'), 'unknown')" 2>/dev/null)
LLM=${LLM:-unknown}
DOC_URL="${BANK_URL}/documents/conversation%3A${SID1}"
DOC_HTTP=000
for i in $(seq 1 180); do
	DOC_HTTP=$(curl -s -o "${D}/doc.json" -w '%{http_code}' --max-time 10 "${DOC_URL}" 2>/dev/null)
	[ "${DOC_HTTP}" == "200" ] && break
	sleep 1
done
if [ "${DOC_HTTP}" == "200" ]; then
	json "${D}/doc.json" "d.get('original_text','')" | grep -qF "${TOKEN}" || fail "document conversation:${SID1} does not carry the planted token"
	HITS=$(curl -s --max-time 30 "${BANK_URL}/memories/list?q=${TOKEN}&limit=5" | json - "len(d.get('items',[]))")
	[ "${HITS:-0}" -ge 1 ] 2>/dev/null || fail "memories/list?q=${TOKEN} found nothing although the document landed"
	NODES=$(curl -s --max-time 30 "${BANK_URL}/stats" | json - "d.get('total_nodes',0)")
	[ "${NODES:-0}" -ge 1 ] 2>/dev/null || fail "total_nodes is ${NODES} after the document landed"
	echo "ok 8 - read back via ${API}: document conversation:${SID1} carries the planted token, memories/list finds it (${HITS} hit(s)), total_nodes=${NODES}"
elif [ "${LLM}" == "connected" ]; then
	curl -s --max-time 10 "${BANK_URL}/operations" | json - "[(o['task_type'],o['status'],(o.get('error_message') or '')[:160]) for o in d['operations']]"
	fail "the LLM is connected but document conversation:${SID1} never appeared within 180s"
else
	ERR=$(curl -s --max-time 10 "${BANK_URL}/operations" | json - "next(((o.get('error_message') or '')[:160] for o in d['operations'] if o.get('error_message')), '')")
	echo "ok 8 - (skipped: no working LLM for the API's extraction here - health/llm says '${LLM}'${ERR:+; last error: ${ERR}}; the retain reached the API in check 6, extraction needs Bedrock credentials)"
fi

echo "Test15 succeeded"
