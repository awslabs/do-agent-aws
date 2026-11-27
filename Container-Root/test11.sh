#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the claude-mem hook runtime. Every claude-mem hook runs `node bun-runner.js <script>`,
# which spawns Bun. In an image without Bun each hook fails in the Claude CLI with
# "Failed with non-blocking status code: Error: Bun not found. Please install Bun: https://bun.sh"
# and no memory is ever captured. Each check FAILS if the property it proves is removed:
#   1. Bun is installed at /usr/local/bin/bun at the version pinned in /setup/install-bun.sh
#   2. the shipped plugin's own bun-runner.js resolves Bun under a hook-like minimal environment
#      (no nvm/npm paths on PATH) and runs a script under Bun
#   3. PLANTED CONTROL: with Bun hidden, the same runner prints "Bun not found" and exits non-zero
#      (proves check 2 exercises the real lookup instead of passing vacuously)
#   4. the claude-mem plugin is enabled in Claude Code's settings (the hooks are registered at all)
#   5. a headless `claude -p` started with the PATH of a non-login process lands its prompt in the worker's
#      /api/prompts, and the plugin's SessionStart check reports no problem. Every claude-mem hook is the bare
#      command `claude-mem`, and the installer puts that launcher in ~/.local/bin, which only an interactive or a
#      login shell has on PATH; without the /usr/local/bin link from /setup/install-claudemem.sh each hook of a
#      docker exec, autonomy-loop or Slack-reply session fails with 'Executable not found in $PATH: "claude-mem"'
#      and the session records nothing
#   6. PLANTED CONTROL: with the claude-mem that PATH resolves hidden, the same call records nothing and the
#      plugin reports its hooks inactive (proves check 5 exercises the hook lookup on that PATH)
#   6b. no cloud upsell in the agent's session: the message the SessionStart context hook shows ("View Observations
#      Live @ ...") and the user-message hook's context banner ("Claude-Mem Context Loaded ...") carry no "Free Trial"
#      (/setup/install-claudemem.sh takes the two calls that append it out of the pinned worker bundle,
#      thedotmack/claude-mem#4768). PLANTED CONTROL: with the two calls put back in the bundle the same hooks show it
#   7. one pinned claude-mem: the cache holds only the version /setup/install-claudemem.sh pins, the registered
#      version and the worker /agent/ui-start.sh starts are that version, and its marketplace's autoUpdate is off

fail()
{
	echo "Test11 FAILED: $1"
	exit 1
}

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-/home/agent/.claude}
NODE_BIN=$(command -v node || echo /usr/local/bin/node)
[ -x "${NODE_BIN}" ] || fail "node not found"

# 1. pinned Bun at the path the hooks fall back to
PIN=$(sed -n 's/^export BUN_VERSION=//p' /setup/install-bun.sh 2>/dev/null)
[ -n "${PIN}" ] || fail "no BUN_VERSION pin in /setup/install-bun.sh"
[ -x /usr/local/bin/bun ] || fail "/usr/local/bin/bun is missing"
GOT=$(/usr/local/bin/bun --version 2>/dev/null)
[ "${GOT}" = "${PIN}" ] || fail "bun --version is '${GOT}', pinned ${PIN}"

# 2. the shipped plugin's runner under a hook-like minimal environment
RUNNER=$(ls -d ${CONFIG_DIR}/plugins/cache/thedotmack/claude-mem/[0-9]*/scripts/bun-runner.js 2>/dev/null | sort -V | tail -1)
[ -n "${RUNNER}" ] || RUNNER=$(ls ${CONFIG_DIR}/plugins/marketplaces/thedotmack/plugin/scripts/bun-runner.js 2>/dev/null)
[ -f "${RUNNER}" ] || fail "claude-mem bun-runner.js not found under ${CONFIG_DIR}/plugins"
PROBE=$(mktemp /tmp/test11-probe-XXXXXX.js)
echo 'console.log("test11-bun-ok " + (typeof Bun !== "undefined" ? Bun.version : "not-bun"))' > "${PROBE}"
OUT=$(echo '{}' | env -i PATH=/usr/bin:/bin HOME=/home/agent CLAUDE_CONFIG_DIR=${CONFIG_DIR} "${NODE_BIN}" "${RUNNER}" "${PROBE}" 2>&1)
RC=$?
case "${OUT}" in
*"test11-bun-ok ${PIN}"*) [ ${RC} -eq 0 ] || fail "runner ran the probe but exited ${RC}" ;;
*) rm -f "${PROBE:?}"; fail "bun-runner.js did not run the probe under Bun ${PIN} (exit ${RC}): ${OUT}" ;;
esac

# 3. planted control: hide Bun, the runner must fail loudly. The image's Bun is root's /usr/local/bin/bun, which the agent
# user cannot move, so the control runs a copy of the runner, beside it, whose fixed install paths name a directory that
# does not exist, with a PATH and a HOME that hold no Bun either
NOBUN_RUNNER="${RUNNER%.js}.test11-nobun.js"
sed -e 's#/usr/local/bin/bun#/nonexistent-test11/bun#g' -e 's#/opt/homebrew/bin/bun#/nonexistent-test11/bun#g' \
	-e 's#/home/linuxbrew/.linuxbrew/bin/bun#/nonexistent-test11/bun#g' "${RUNNER}" > "${NOBUN_RUNNER}" || fail "planted control: cannot write ${NOBUN_RUNNER}"
CTRL=$(echo '{}' | env -i PATH=/usr/bin:/bin HOME="${D:-/tmp}/test11-nobun-home" CLAUDE_CONFIG_DIR=${CONFIG_DIR} "${NODE_BIN}" "${NOBUN_RUNNER}" "${PROBE}" 2>&1)
CRC=$?
rm -f "${NOBUN_RUNNER:?}"
rm -f "${PROBE:?}"
[ ${CRC} -ne 0 ] || fail "planted control: runner exited 0 with Bun hidden"
case "${CTRL}" in
*"Bun not found"*) : ;;
*) fail "planted control: expected 'Bun not found', got: ${CTRL}" ;;
esac

# 4. plugin enabled in Claude Code settings
"${NODE_BIN}" -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.exit(s.enabledPlugins && s.enabledPlugins["claude-mem@thedotmack"]===true ? 0 : 1)' "${CONFIG_DIR}/settings.json" \
	|| fail "claude-mem@thedotmack is not enabled in ${CONFIG_DIR}/settings.json"

# 5. a headless session records its prompt from the PATH docker gives every process it starts (PID 1's: the image's
# PATH, the one of docker exec, startup.sh, the autonomy loop and the Slack chat replies), not this script's own, which
# an interactive or a login shell running the suite would extend. The prompt is recorded on UserPromptSubmit, before
# the model call, so no model credentials are needed: without them the call ends in an API error after the hook ran.
PLAIN_PATH=$(tr '\0' '\n' < /proc/1/environ 2> /dev/null | sed -n 's/^PATH=//p')
[ -n "${PLAIN_PATH}" ] || PLAIN_PATH=${PATH}
CM_PORT=${UI_PORT_CLAUDE_MEM:-37700}
CM_URL=http://127.0.0.1:${CM_PORT}
CM_WD=$(mktemp -d /tmp/test11-cm-XXXXXX)
CM_PID=""
cm_up()
{
	curl -s --max-time 2 "${CM_URL}/api/prompts?limit=1" 2> /dev/null | grep -q '"items"'
}
cm_fail()
{
	[ -n "${CM_PID}" ] && kill "${CM_PID}" 2> /dev/null
	rm -rf "${CM_WD:?}"
	fail "$1"
}
# one headless call; its stream-json (with the SessionStart hook results) goes to ${CM_WD}/<marker>.jsonl
cm_call()
{
	( cd "${CM_WD}" && env PATH="${PLAIN_PATH}" timeout 120 claude -p "$1: reply with exactly OK" --output-format stream-json --verbose > "${CM_WD}/$1.jsonl" 2>&1 < /dev/null )
}
cm_landed()
{
	curl -s --max-time 5 "${CM_URL}/api/prompts?limit=100" 2> /dev/null | grep -qF "\"$1: reply"
}
if ! cm_up; then
	# no worker (the test container starts no UI): started the way /agent/ui-start.sh starts it, and stopped at the end
	WORKER=$(ls -d "${CONFIG_DIR}"/plugins/cache/thedotmack/claude-mem/[0-9]*/scripts/worker-service.cjs 2> /dev/null | sort -V | tail -1)
	[ -f "${WORKER}" ] || cm_fail "claude-mem worker-service.cjs not found under ${CONFIG_DIR}/plugins"
	CLAUDE_MEM_WORKER_HOST=127.0.0.1 CLAUDE_MEM_WORKER_PORT=${CM_PORT} CLAUDE_MEM_IDLE_EXIT_SEC=0 \
		/usr/local/bin/bun "${WORKER}" --daemon > "${CM_WD}/worker.log" 2>&1 < /dev/null &
	CM_PID=$!
	for _ in $(seq 1 60); do cm_up && break; sleep 1; done
	cm_up || cm_fail "the claude-mem worker did not answer on ${CM_URL} within 60 s: $(tail -3 "${CM_WD}/worker.log")"
fi
MARK=test11-path-$$-$(date +%s)
cm_call "${MARK}"
for _ in $(seq 1 20); do cm_landed "${MARK}" && break; sleep 1; done
cm_landed "${MARK}" || cm_fail "a headless claude -p with the non-login PATH (${PLAIN_PATH}) did not land in ${CM_URL}/api/prompts: claude-mem resolves there to '$(env PATH="${PLAIN_PATH}" sh -c 'command -v claude-mem')'; $(grep -o 'Executable not found in [^,]*' "${CM_WD}/${MARK}.jsonl" | head -1) $(grep -o 'memory hooks are not active[^"]*' "${CM_WD}/${MARK}.jsonl" | head -1)"
# and the plugin's own SessionStart check is satisfied: it reports any claude-mem on PATH that is not its launcher (a
# copy) as shadowing it, with the same "memory hooks are not active" message
grep -q 'memory hooks are not active' "${CM_WD}/${MARK}.jsonl" \
	&& cm_fail "the prompt landed, but the plugin reported: $(grep -o 'memory hooks are not active[^"]*' "${CM_WD}/${MARK}.jsonl" | head -1)"

# 6. planted control: the claude-mem that PATH resolves hidden for one call. The link is root's (/usr/local/bin) and the agent
# user cannot move it, so the call gets a PATH whose directories hold everything they hold but claude-mem: the directory
# with the link is replaced by a test-local one with a link to each of its other entries
HIT=$(env PATH="${PLAIN_PATH}" sh -c 'command -v claude-mem')
[ -n "${HIT}" ] || cm_fail "planted control: no claude-mem on the non-login PATH to hide"
SHADOW="${CM_WD}/path-without-claude-mem"
mkdir -p "${SHADOW}" || cm_fail "planted control: cannot create ${SHADOW}"
for E in "$(dirname "${HIT}")"/*; do
	[ "${E}" == "${HIT}" ] || ln -s "${E}" "${SHADOW}/$(basename "${E}")"
done
SAVED_PATH=${PLAIN_PATH}
PLAIN_PATH=$(echo "${PLAIN_PATH}" | tr ':' '\n' | sed "s#^$(dirname "${HIT}")\$#${SHADOW}#" | paste -sd: -)
env PATH="${PLAIN_PATH}" sh -c 'command -v claude-mem' > /dev/null && cm_fail "planted control: claude-mem still resolves on ${PLAIN_PATH}"
env PATH="${PLAIN_PATH}" sh -c 'command -v claude' > /dev/null || cm_fail "planted control: the shadowed PATH lost claude itself"
cm_call "${MARK}-control"
PLAIN_PATH=${SAVED_PATH}
sleep 10
cm_landed "${MARK}-control" && cm_fail "planted control: the prompt landed with claude-mem hidden from the non-login PATH"
grep -q 'memory hooks are not active' "${CM_WD}/${MARK}-control.jsonl" \
	|| cm_fail "planted control: the session did not report the claude-mem hooks inactive: $(tail -c 300 "${CM_WD}/${MARK}-control.jsonl")"

# 6b. the two hooks that show a message, run as a session runs them (the bare launcher, PID 1's PATH, an event on stdin);
# each must show its own message (so the check reads a real one) and no upsell in it
cm_hook()
{
	# cm_hook <hook> <event> <out> - the hook's JSON answer in <out>
	echo "{\"session_id\":\"${MARK}-$1\",\"cwd\":\"${CM_WD}\",\"hook_event_name\":\"$2\",\"source\":\"startup\",\"prompt\":\"test11\"}" \
		| ( cd "${CM_WD}" && env PATH="${PLAIN_PATH}" timeout 60 claude-mem hook claude-code "$1" ) > "$3" 2>&1
}
cm_messages()
{
	# cm_messages <tag> - both hooks' answers, in ${CM_WD}/<tag>-context.json and <tag>-user-message.json
	cm_hook context SessionStart "${CM_WD}/$1-context.json"
	cm_hook user-message UserPromptSubmit "${CM_WD}/$1-user-message.json"
}
cm_upsell()
{
	# cm_upsell <tag> - fails unless each hook showed its own message; prints the answers whose message carries the upsell
	grep -q 'View Observations Live @' "${CM_WD}/$1-context.json" || cm_fail "6b ($1): the SessionStart context hook showed no message: $(head -c 300 "${CM_WD}/$1-context.json")"
	grep -q 'Claude-Mem Context Loaded' "${CM_WD}/$1-user-message.json" || cm_fail "6b ($1): the user-message hook showed no context banner: $(head -c 300 "${CM_WD}/$1-user-message.json")"
	grep -l 'Free Trial' "${CM_WD}/$1-context.json" "${CM_WD}/$1-user-message.json" 2> /dev/null | sed 's#.*/##' | tr '\n' ' '
}
cm_messages shipped
UPSELL=$(cm_upsell shipped)
[ -z "${UPSELL}" ] || cm_fail "6b: the agent's session shows claude-mem's cloud upsell: $(grep -oh '[^"]\{0,40\}Free Trial[^"]\{0,60\}' "${CM_WD}"/shipped-*.json | head -1) (in ${UPSELL})"
# planted control: the two calls put back in the bundle the hooks load, the shipped bundle restored before any verdict
CM_BUNDLE=$(ls -d "${CONFIG_DIR}"/plugins/cache/thedotmack/claude-mem/[0-9]*/scripts/worker-service.cjs 2> /dev/null | sort -V | tail -1)
cp "${CM_BUNDLE:?}" "${CM_WD:?}/worker-service.cjs.shipped"
# shellcheck disable=SC2016 # the script's ${h} is a JavaScript template literal, not a shell expansion
"${NODE_BIN}" -e 'const fs = require("fs"); const f = process.argv[1]; let s = fs.readFileSync(f, "utf8");
for (const h of ["session-start", "context-banner"]) s = s.split(`""/*claude-mem upsell removed: ${h} (thedotmack/claude-mem#4768)*/`).join(`vg("${h}")`);
fs.writeFileSync(f, s);' "${CM_BUNDLE}"
cm_messages control
cp "${CM_WD:?}/worker-service.cjs.shipped" "${CM_BUNDLE:?}"
CONTROL=$(cm_upsell control)
[ "${CONTROL}" == "control-context.json control-user-message.json " ] \
	|| cm_fail "6b planted control: with the two calls put back the hooks did not show the upsell (showed it: '${CONTROL}')"
[ -n "${CM_PID}" ] && kill "${CM_PID}" 2> /dev/null
rm -rf "${CM_WD:?}"

# 7. one pinned claude-mem: the plugin cache holds the version /setup/install-claudemem.sh pins and nothing else, that
# is the version the sessions' hooks are registered at (installed_plugins.json) and the worker /agent/ui-start.sh
# starts (the newest cached one), and its marketplace does not update itself. Unpinned, two builds 20 minutes apart
# differed: one registered 13.38.0 and cached the 13.39.0 published in between beside it
CM_PIN=$(sed -n 's/^export CLAUDE_MEM_VERSION=//p' /setup/install-claudemem.sh 2>/dev/null)
[ -n "${CM_PIN}" ] || fail "no CLAUDE_MEM_VERSION pin in /setup/install-claudemem.sh"
CM_CACHE=${CONFIG_DIR}/plugins/cache/thedotmack/claude-mem
CM_CACHED=$(ls "${CM_CACHE}" 2>/dev/null | tr '\n' ' ')
[ "${CM_CACHED}" == "${CM_PIN} " ] || fail "the plugin cache holds claude-mem '${CM_CACHED}', not the pinned ${CM_PIN} alone"
CM_REG=$("${NODE_BIN}" -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log((d.plugins["claude-mem@thedotmack"] || []).map(x => x.version).join(" "))' "${CONFIG_DIR}/plugins/installed_plugins.json")
[ "${CM_REG}" == "${CM_PIN}" ] || fail "claude-mem is registered at '${CM_REG}', not the pinned ${CM_PIN}"
CM_NEWEST=$(ls -d "${CM_CACHE}"/[0-9]*/ 2>/dev/null | sort -V | tail -1)
[ "$(basename "${CM_NEWEST}")" == "${CM_PIN}" ] || fail "the worker ui-start.sh starts is ${CM_NEWEST}, not the pinned ${CM_PIN}"
CM_AUTO=$("${NODE_BIN}" -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(String((d.thedotmack || {}).autoUpdate))' "${CONFIG_DIR}/plugins/known_marketplaces.json")
[ "${CM_AUTO}" == "false" ] || fail "the claude-mem marketplace updates itself (autoUpdate ${CM_AUTO})"

echo "Test11 succeeded"
