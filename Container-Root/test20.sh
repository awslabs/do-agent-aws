#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the agent runner's Node toolchain and agent settings. vibe-kanban 0.1.44, the agent runner that
# /agent/ui-start.sh starts, launches its coding agents and discovers their options with npx (its default command for
# Claude Code is npx -y @anthropic-ai/claude-code@<its pin>), looked up on the PATH of the runner process. That PATH,
# the one ui-start.sh gives it, holds no nvm directory, while node, npm and npx are nvm's: without links beside node
# every workspace start answers 500 with Executor(ExecutableNotFound { program: "npx" }). Its default Claude Code is
# that npx copy (2.1.119), with --dangerously-skip-permissions, which runs only because the image's npm allows the
# package's install scripts (setup/harden.sh); without agent settings of its own the runner gets Claude Code as the
# image's claude, without that flag.
# Each check FAILS if the property it proves is removed:
#   1. node, npm and npx are in /usr/local/bin (the links /setup/install-claude.sh makes) and run; npm and npx are
#      the same npm
#   2. the runner ui-start.sh starts (the real one, on a test-local port and data home, stopped again at once) has a
#      PATH on which npx and npm resolve and run (npx --version, npm --version)
#   3. PLANTED CONTROL: on that same PATH without /usr/local/bin, npx does not resolve, so check 2 proves the links and
#      not some other npx
#   4. the runner's agent settings (/agent/vibe-kanban-profiles.json) are Claude Code as the image's claude without
#      --dangerously-skip-permissions, alone
#   5. ui-start.sh writes them when the runner has none (with or without its other settings) and says so, a later
#      start leaves them, and agent settings that exist are never changed (a live pid named vibe-kanban stands in for
#      the runner, so no real one starts)
#   6. the relay (docs/manual/boards.md "Kanban board"): started with the board (KANBAN_BOARD_URL, a stub board answering its
#      login) and the relay (KANBAN_RELAY_URL), ui-start.sh stores the runner's sign-in to the board where the runner
#      keeps it (/agent/vk-runner-signin.py: its credentials.json, mode 600) before the runner starts, and the runner
#      has VK_SHARED_API_BASE and VK_SHARED_RELAY_API_BASE set to them; a start while the runner runs leaves its
#      stored sign-in as it is (the same file); without the relay (check 2's start) the runner has neither variable, no
#      sign-in is stored and the helper does not run

fail()
{
	echo "Test20 FAILED: $1"
	[ -n "${RUNNER_PID}" ] && kill -TERM -- "-${RUNNER_PID}" 2> /dev/null
	[ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2> /dev/null
	exit 1
}

D=/tmp/runner-toolchain
rm -rf "${D:?}"
mkdir -p ${D}/ui

# --- 1. node, npm and npx beside each other in /usr/local/bin ---
for B in node npm npx; do
	[ -x /usr/local/bin/${B} ] || fail "/usr/local/bin/${B} is missing (/setup/install-claude.sh links it beside node)"
done
NODE_V=$(/usr/local/bin/node -v 2>&1) || fail "/usr/local/bin/node -v: ${NODE_V}"
NPM_V=$(/usr/local/bin/npm --version 2>&1) || fail "/usr/local/bin/npm --version: ${NPM_V}"
NPX_V=$(/usr/local/bin/npx --version 2>&1) || fail "/usr/local/bin/npx --version: ${NPX_V}"
[ "${NPM_V}" == "${NPX_V}" ] || fail "npm ${NPM_V} and npx ${NPX_V} are not the same npm"
echo "ok 1 - /usr/local/bin has node ${NODE_V} and npm and npx ${NPM_V}"

# --- 2. the PATH of the runner process that ui-start.sh starts ---
UI_DIR=${D}/ui UI_LISTEN_HOST=127.0.0.1 UI_HOME=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_TMUX=false \
	UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_FILES=false UI_VIBE_KANBAN=true UI_PORT_VIBE_KANBAN=18197 \
	KANBAN_BOARD_URL='' VIBE_KANBAN_DATA_HOME=${D}/data /agent/ui-start.sh > ${D}/ui-start.log 2>&1 \
	|| fail "ui-start.sh: $(cat ${D}/ui-start.log)"
RUNNER_PID=$(cat ${D}/ui/vibe-kanban.pid 2> /dev/null)
[ -n "${RUNNER_PID}" ] || fail "ui-start.sh started no runner: $(cat ${D}/ui-start.log)"
RUNNER_ENV=$(tr '\0' '\n' < "/proc/${RUNNER_PID}/environ" 2> /dev/null)
RUNNER_PATH=$(echo "${RUNNER_ENV}" | sed -n 's/^PATH=//p')
kill -TERM -- "-${RUNNER_PID}" 2> /dev/null
RUNNER_PID=""
[ -n "${RUNNER_PATH}" ] || fail "no PATH in the environment of the runner ui-start.sh started"
OUT=$(env -i HOME=/home/agent PATH="${RUNNER_PATH}" sh -c 'command -v npx && npx --version && command -v npm && npm --version' 2>&1) \
	|| fail "npx or npm does not resolve and run on the runner's PATH ${RUNNER_PATH}: ${OUT}"
echo "ok 2 - on the runner's PATH (${RUNNER_PATH}) npx and npm resolve and run: ${OUT//$'\n'/ }"

# --- 3. PLANTED CONTROL: the same PATH without /usr/local/bin ---
NO_LOCAL=$(echo "${RUNNER_PATH}" | tr ':' '\n' | grep -vxF /usr/local/bin | paste -sd: -)
OTHER=$(env -i HOME=/home/agent PATH="${NO_LOCAL}" sh -c 'command -v npx' 2>&1) \
	&& fail "PLANTED CONTROL: npx resolves on the runner's PATH without /usr/local/bin (${OTHER}), so check 2 does not prove the links"
echo "ok 3 - PLANTED CONTROL: without /usr/local/bin on that PATH npx does not resolve"

# --- 4. the runner's agent settings: Claude Code as the image's claude, without --dangerously-skip-permissions ---
PROFILES=/agent/vibe-kanban-profiles.json
python3 - "${PROFILES}" << 'EOF' || fail "the runner's agent settings (${PROFILES}) are not Claude Code as the image's claude without --dangerously-skip-permissions, alone"
import json, sys
p = json.load(open(sys.argv[1]))
# vibe-kanban 0.1.44 replaces a default configuration by a user one of the same name, whole (merge_with_defaults in
# crates/executors/src/profile.rs): Claude Code's DEFAULT is then exactly these two settings, the flag off
assert p == {"executors": {"CLAUDE_CODE": {"DEFAULT": {"CLAUDE_CODE": {
    "base_command_override": "claude", "dangerously_skip_permissions": False}}}}}, p
EOF
echo "ok 4 - ${PROFILES} is Claude Code as the image's claude without --dangerously-skip-permissions, alone"

# --- 5. ui-start.sh gives the runner those settings when it has none, and never changes agent settings that exist ---
# the runner is not this check's subject: a live pid whose command line names vibe-kanban, which ui-start.sh takes for
# a running runner (it leaves a live UI alone), so no real runner starts
mkdir -p ${D}/ui-stub
bash -c 'exec -a vibe-kanban-stub sleep 900' > /dev/null 2>&1 &
STUB_PID=$!
echo ${STUB_PID} > ${D}/ui-stub/vibe-kanban.pid
# vk_start <data home> - ui-start.sh with the runner on only, the runner's data home <data home>/vibe-kanban
vk_start()
{
	UI_DIR=${D}/ui-stub UI_LISTEN_HOST=127.0.0.1 UI_HOME=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_TMUX=false \
		UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_FILES=false UI_VIBE_KANBAN=true UI_PORT_VIBE_KANBAN=18197 \
		KANBAN_BOARD_URL='' VIBE_KANBAN_DATA_HOME="$1" /agent/ui-start.sh > ${D}/ui-start-vk.log 2>&1 \
		|| fail "ui-start.sh: $(cat ${D}/ui-start-vk.log)"
	grep -q "vibe-kanban: already running" ${D}/ui-start-vk.log || fail "ui-start.sh did not take the stub runner: $(cat ${D}/ui-start-vk.log)"
}
WROTE="vibe-kanban: no agent settings yet - its Claude Code is the image's claude, without --dangerously-skip-permissions"
# a first start: no settings at all
vk_start ${D}/vk-fresh
cmp -s "${PROFILES}" ${D}/vk-fresh/vibe-kanban/profiles.json || fail "a first start did not give the runner its agent settings"
grep -qF "${WROTE} (${D}/vk-fresh/vibe-kanban/profiles.json" ${D}/ui-start-vk.log \
	|| fail "a first start does not say what the runner's agent settings are: $(cat ${D}/ui-start-vk.log)"
# the next start leaves them as they are now (the runner and the user own them)
vk_start ${D}/vk-fresh
grep -qF "${WROTE}" ${D}/ui-start-vk.log && fail "a second start wrote the runner's agent settings again"
cmp -s "${PROFILES}" ${D}/vk-fresh/vibe-kanban/profiles.json || fail "a second start changed the runner's agent settings"
# the runner's other settings, but no agent settings: they are written, and the other settings stay as they are
mkdir -p ${D}/vk-settings/vibe-kanban
echo '{"config_version": "v8"}' > ${D}/vk-settings/vibe-kanban/config.json
BEFORE=$(sha256sum < ${D}/vk-settings/vibe-kanban/config.json)
vk_start ${D}/vk-settings
cmp -s "${PROFILES}" ${D}/vk-settings/vibe-kanban/profiles.json || fail "a start with settings but no agent settings did not write the agent settings"
[ "$(sha256sum < ${D}/vk-settings/vibe-kanban/config.json)" == "${BEFORE}" ] || fail "ui-start.sh changed the runner's other settings"
# a user's own agent settings (skip permissions on, vibe-kanban's command): never changed
mkdir -p ${D}/vk-user/vibe-kanban
echo '{"executors": {"CLAUDE_CODE": {"DEFAULT": {"CLAUDE_CODE": {"dangerously_skip_permissions": true}}}}}' \
	> ${D}/vk-user/vibe-kanban/profiles.json
BEFORE=$(sha256sum < ${D}/vk-user/vibe-kanban/profiles.json)
vk_start ${D}/vk-user
[ "$(sha256sum < ${D}/vk-user/vibe-kanban/profiles.json)" == "${BEFORE}" ] || fail "ui-start.sh changed the user's agent settings"
grep -qF "${WROTE}" ${D}/ui-start-vk.log && fail "ui-start.sh said it wrote agent settings over the user's"
kill ${STUB_PID} 2> /dev/null
STUB_PID=""
echo "ok 5 - without agent settings (with or without its other settings) the runner gets ${PROFILES} and the start says so; a later start leaves them; a user's agent settings are never changed"

# --- 6. the relay: the runner's sign-in stored before it starts, and its shared API and relay ---
echo "${RUNNER_ENV}" | grep -q '^VK_SHARED_' && fail "6: without the relay the runner's environment has $(echo "${RUNNER_ENV}" | grep '^VK_SHARED_')"
grep -q "vk-runner-signin" ${D}/ui-start.log && fail "6: without the relay ui-start.sh ran the sign-in helper: $(grep vk-runner-signin ${D}/ui-start.log)"
[ -e ${D}/data/vibe-kanban/credentials.json ] && fail "6: without the relay a sign-in was stored for the runner"
# a stub board on a test port answers the board's login (nothing answers on the relay's test port: the runner keeps
# trying it in the background); the seed and the watcher end on their own, ui-stop.sh stops the rest; every state
# stays under ${D}
TOKEN="refresh-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf 'SELF_HOST_LOCAL_AUTH_EMAIL=agent@do-agent-aws.local\nSELF_HOST_LOCAL_AUTH_PASSWORD=test20-%s\n' "$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')" > ${D}/kanban.env
chmod 600 ${D}/kanban.env
cat > ${D}/stub-board.py << 'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        return self._json(404, {})
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/v1/auth/local/login":
            open(sys.argv[3], "a").write("login\n")
            return self._json(200, {"access_token": "access-not-stored", "refresh_token": sys.argv[2]})
        return self._json(404, {})
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
python3 ${D}/stub-board.py 18194 "${TOKEN}" ${D}/logins.log > ${D}/stub-board.log 2>&1 &
STUB_PID=$!
for _ in $(seq 1 40); do curl -s -o /dev/null --max-time 1 http://127.0.0.1:18194/ && break; sleep 0.1; done
mkdir -p ${D}/ui-relay ${D}/loop-relay
relay_start()
{
	UI_DIR=${D}/ui-relay UI_LISTEN_HOST=127.0.0.1 UI_HOME=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_TMUX=false \
		UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_FILES=false UI_PLANE=false UI_VIBE_KANBAN=true UI_PORT_VIBE_KANBAN=18196 \
		UI_PORT_KANBAN_SIGNIN=18195 KANBAN_BOARD_URL=http://127.0.0.1:18194 KANBAN_RELAY_URL=http://127.0.0.1:18193 \
		KANBAN_AUTH_FILE=${D}/kanban.env KANBAN_SEED_WAIT=2 VK_SIGNIN_WAIT=5 AUTONOMY_LOOP_DIR=${D}/loop-relay \
		VIBE_KANBAN_DATA_HOME=${D}/data-relay /agent/ui-start.sh
}
relay_start > ${D}/ui-start-relay.log 2>&1 || fail "6: ui-start.sh with the relay: $(cat ${D}/ui-start-relay.log)"
RUNNER_PID=$(cat ${D}/ui-relay/vibe-kanban.pid 2> /dev/null)
[ -n "${RUNNER_PID}" ] || fail "6: ui-start.sh with the relay started no runner: $(cat ${D}/ui-start-relay.log)"
RELAY_ENV=$(tr '\0' '\n' < "/proc/${RUNNER_PID}/environ" 2> /dev/null)
CREDS=${D}/data-relay/vibe-kanban/credentials.json
STORED=$(grep -n "^vk-runner-signin: the runner's sign-in to the board at http://127.0.0.1:18194 as agent@do-agent-aws.local is stored in ${CREDS} " ${D}/ui-start-relay.log | cut -d: -f1)
STARTED=$(grep -n "^vibe-kanban: started" ${D}/ui-start-relay.log | cut -d: -f1)
# a second start while the runner runs: its sign-in is left as it is (the helper writes a new file, so a new inode,
# whenever it stores one)
INODE=$(stat -c %i "${CREDS}" 2> /dev/null)
relay_start > ${D}/ui-start-relay2.log 2>&1
UI_DIR=${D}/ui-relay /agent/ui-stop.sh > ${D}/ui-stop-relay.log 2>&1
kill -TERM -- "-${RUNNER_PID}" 2> /dev/null
RUNNER_PID=""
kill "${STUB_PID}" 2> /dev/null
STUB_PID=""
if [ -z "${STORED}" ] || [ -z "${STARTED}" ] || [ "${STORED}" -ge "${STARTED}" ]; then
	fail "6: ui-start.sh did not store the runner's sign-in before it started the runner (stored at line ${STORED:-none}, started at ${STARTED:-none}): $(grep -E 'vk-runner-signin|vibe-kanban:' ${D}/ui-start-relay.log)"
fi
python3 - "${CREDS}" "${TOKEN}" << 'EOF' || fail "6: ${CREDS} is not the board's sign-in as the runner stores it (mode 600)"
import json, os, stat, sys
assert json.load(open(sys.argv[1])) == {"refresh_token": sys.argv[2]}
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
EOF
grep -q '^vk-runner-signin: ' ${D}/ui-relay/vk-runner-signin.log || fail "6: the sign-in's line is not in ${D}/ui-relay/vk-runner-signin.log"
echo "${RELAY_ENV}" | grep -qx 'VK_SHARED_API_BASE=http://127.0.0.1:18194' \
	|| fail "6: the runner's VK_SHARED_API_BASE is not the board: [$(echo "${RELAY_ENV}" | grep '^VK_SHARED_API_BASE')]"
echo "${RELAY_ENV}" | grep -qx 'VK_SHARED_RELAY_API_BASE=http://127.0.0.1:18193' \
	|| fail "6: the runner's VK_SHARED_RELAY_API_BASE is not the relay: [$(echo "${RELAY_ENV}" | grep '^VK_SHARED_RELAY_API_BASE')]"
grep -q "^vibe-kanban: already running" ${D}/ui-start-relay2.log || fail "6: the second start did not find the runner running: $(grep 'vibe-kanban' ${D}/ui-start-relay2.log)"
grep -q "vk-runner-signin" ${D}/ui-start-relay2.log && fail "6: a start while the runner runs stored a new sign-in: $(grep vk-runner-signin ${D}/ui-start-relay2.log)"
if [ -z "${INODE}" ] || [ "$(stat -c %i "${CREDS}" 2> /dev/null)" != "${INODE}" ]; then
	fail "6: a start while the runner runs replaced its stored sign-in"
fi
echo "ok 6 - with the board and the relay ui-start.sh stores the runner's sign-in (mode 600) before it starts the runner, which has VK_SHARED_API_BASE and VK_SHARED_RELAY_API_BASE; a start while it runs signs in no more; without them, none of it"

echo "Test20 succeeded"
