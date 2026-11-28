#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the parity inventory and the fire's authority (docs/manual/autonomy.md "Parity with a native instance" and "Autonomy loop";
# /agent/parity-inventory.sh, tools/parity-inventory.sh in a checkout). Fully OFFLINE: a stand-in
# claude, a planted HOME, nothing under /wd touched; its files under /tmp/parity-inventory-test, kept on a failure and named.
# Each check FAILS if the property it proves is removed:
#   1. the inventory script and this test parse (bash -n), and the Python inside the script compiles
#   2. in an EMPTY home (no settings, no memory, no skills, nothing on PATH but the system tools; the container probe
#      PARITY_AGENT_DIR pointed at a missing directory, so the check reads the same in the image) the inventory exits 0 and
#      prints every row, each reading a value, none or not found: the 24 rows in their order, the model row "Bedrock default
#      (unset)", the context row "no", the fire row "not found" with the PARITY_LOOP_SCRIPT hint
#   3. PLANTED CONTROL: a settings.json in that home whose env block sets ANTHROPIC_MODEL "x[1m]" makes the model row read x
#      from that file's env, the context row yes, the effort row the planted level; a planted autoMemoryEnabled false reads
#      off; a planted enabledPlugins and hooks block are counted
#   4. --json prints one JSON object whose keys are exactly the table's rows, in the same order, with the same values
#   5. PARITY_LOOP_SCRIPT naming a file with two claude -p lines reads their timeout and permission words; a planted
#      CLAUDE.md in the working directory and an @-imported file are counted in the instructions row with their bytes
#   6. the fire's authority (docs/manual/autonomy.md "Autonomy loop"): loop-once.sh with a stand-in claude and AUTONOMY_LOOP_CLAUDE_OPTS
#      unset gives claude exactly -p and the safe value (the four allow rules then acceptEdits) with NO IS_SANDBOX in its
#      environment; the opt-in --dangerously-skip-permissions gets IS_SANDBOX=1, and so does --permission-mode bypassPermissions;
#      the shipped AUTONOMY_LOOP_FIRE_TIMEOUT default of loop.sh and loop-once.sh is 1500, and .env exports 1500 into
#      AUTONOMY_ENV_OPTS when it is found (a checkout, or /do-agent-aws); the inventory's fire row in a stand-in container
#      layout reads both defaults
#   7. the auto-memory setting (docs/manual/memory.md "Agent memory"): /agent/claude-memory-settings.py writes autoMemoryEnabled true into a
#      settings.json with AGENT_MEMORY unset or true and false with AGENT_MEMORY=false, keeping every other key; a second run is
#      a no-op that says so; a file that is not valid JSON is left byte for byte with a message; a missing file is created with
#      the one key; PLANTED CONTROL: claude-settings-sync.sh names the script as its memory step
#   8. the overlay stub (docs/manual/autonomy.md "Parity with a native instance"): /agent/claude-overlay.sh writes the stub into a working
#      directory that has no CLAUDE.md, naming the example; a second run leaves the stub byte for byte and says it is the stub;
#      a planted operator file is never touched and is reported as the operator's; AGENT_OVERLAY=false writes nothing; a
#      working directory that does not exist gets nothing; claude-settings-sync.sh runs the step and the Dockerfile ships the example
#   9. the container branch (PARITY_AGENT_DIR pointed at this tree's agent directory, PARITY_RULES_DIR at its rules): the fire
#      row reads the loop's and the responder's shipped defaults (their safe values, 1500 s) from the scripts; with no
#      CLAUDE.md loaded the instructions row lists the four shipped rules files as shipped but not loaded; with a planted CLAUDE.md
#      that imports a copy of AGENT_RULES.md the copy is counted once and the other three stay in the shipped-but-not-loaded part
set -u
D=/tmp/parity-inventory-test
rm -rf "${D:?}"
mkdir -p "${D}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
INV=${AGENT_DIR}/parity-inventory.sh
FAILED=""
fail() { FAILED=1; echo "Test-parity-inventory FAILED: $* (the files are kept under ${D})"; exit 1; }
trap '[ -n "${FAILED}" ] || rm -rf "${D:?}"' EXIT
ROWS="measured at|cwd|claude|model|context 1M|effort|fallbackModel|max output tokens|instructions|auto-memory|memory|knowledge|skills|agents|plugins|hooks|autonomous fire|kubectl|gh|docker|aws|python3|node|credentials"
# row <table file> <row name> - the value cell of that row
row() { grep -F "| $2 | " "$1" | head -1 | sed -e "s/^| $2 | //" -e 's/ |$//'; }
# the system tools alone on PATH: no claude, kubectl, gh, aws or node of the host (python3 and git are needed)
SYS_PATH=${D}/syspath
mkdir -p "${SYS_PATH}"
for T in python3 git sh bash env; do P=$(command -v "${T}") && ln -s "${P}" "${SYS_PATH}/${T}"; done
[ -x "${SYS_PATH}/python3" ] || fail "python3 is not installed (the inventory needs it)"

# --- 1. parse ---
bash -n "${INV}" || fail "1: ${INV} does not parse"
bash -n "$0" || fail "1: this test does not parse"
sed -n "/^exec python3 -I - \"\$@\" << 'PY'$/,/^PY$/p" "${INV}" | sed '1d;$d' > "${D}/inventory.py"
[ -s "${D}/inventory.py" ] || fail "1: the Python of ${INV} was not found between the PY markers"
python3 -m py_compile "${D}/inventory.py" || fail "1: the Python of ${INV} does not compile"
echo "ok 1 - ${INV} and this test parse; its Python compiles"

# --- 2. an empty home ---
H=${D}/home-empty
mkdir -p "${H}" "${D}/cwd-empty"
( cd "${D}/cwd-empty" && env -i HOME="${H}" PATH="${SYS_PATH}" PARITY_AGENT_DIR="${D}/no-agent" "${INV}" > "${D}/empty.md" 2> "${D}/empty.err" ) || fail "2: the inventory exited nonzero in an empty home: $(cat "${D}/empty.err")"
[ -s "${D}/empty.err" ] && fail "2: the inventory wrote to stderr in an empty home: $(head -3 "${D}/empty.err")"
head -2 "${D}/empty.md" | grep -qx '| row | value |' || fail "2: the first line is not the table header: $(head -1 "${D}/empty.md")"
grep -E '^\| ' "${D}/empty.md" | sed -n '2,$p' | sed -e 's/^| //' -e 's/ |.*//' | tr '\n' '|' | sed 's/|$//' > "${D}/rows.txt"
[ "$(cat "${D}/rows.txt")" == "${ROWS}" ] || fail "2: the rows are not the 24 expected in order: $(cat "${D}/rows.txt")"
while IFS= read -r L; do
	V=${L#*| }; V=${V#*| }; V=${V% |}
	[ -n "${V}" ] || fail "2: a row has an empty value: ${L}"
done < <(grep -E '^\| ' "${D}/empty.md" | sed -n '2,$p')
[ "$(row "${D}/empty.md" model)" == "Bedrock default (unset)" ] || fail "2: model row in an empty home: $(row "${D}/empty.md" model)"
row "${D}/empty.md" "context 1M" | grep -q '^no' || fail "2: context row in an empty home: $(row "${D}/empty.md" "context 1M")"
row "${D}/empty.md" "autonomous fire" | grep -qF 'not found (set PARITY_LOOP_SCRIPT=' || fail "2: fire row without a loop script: $(row "${D}/empty.md" "autonomous fire")"
[ "$(row "${D}/empty.md" claude)" == "not found" ] || fail "2: claude row with no claude on PATH: $(row "${D}/empty.md" claude)"
[ "$(row "${D}/empty.md" kubectl)" == "not found" ] || fail "2: kubectl row with no kubectl on PATH: $(row "${D}/empty.md" kubectl)"
[ "$(row "${D}/empty.md" skills)" == "none" ] || fail "2: skills row in an empty home: $(row "${D}/empty.md" skills)"
[ "$(row "${D}/empty.md" memory)" == "none (no ~/.claude/projects/*/memory)" ] || fail "2: memory row in an empty home: $(row "${D}/empty.md" memory)"
row "${D}/empty.md" "auto-memory" | grep -q "^on (Claude Code's default, nothing sets it)" || fail "2: auto-memory row in an empty home: $(row "${D}/empty.md" "auto-memory")"
grep -qF "${H}" "${D}/empty.md" && fail "2: the home directory appears spelled out instead of as ~: $(grep -F "${H}" "${D}/empty.md" | head -1)"
echo "ok 2 - empty home: exit 0, the 24 rows in order, every row a value, none or not found; model 'Bedrock default (unset)', context no, fire 'not found' with the hint, the home written as ~"

# --- 3. PLANTED CONTROL: a settings.json with env.ANTHROPIC_MODEL "x[1m]", effort, autoMemoryEnabled false, plugins, hooks ---
H=${D}/home-planted
mkdir -p "${H}/.claude"
cat > "${H}/.claude/settings.json" << 'JSON'
{
  "env": {"ANTHROPIC_MODEL": "x[1m]", "CLAUDE_CODE_EFFORT_LEVEL": "planted-effort"},
  "autoMemoryEnabled": false,
  "fallbackModel": "y-fallback",
  "enabledPlugins": {"planted-a@m": true, "planted-b@m": true, "planted-off@m": false},
  "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "true"}, {"type": "command", "command": "true"}]}], "Stop": [{"hooks": [{"type": "command", "command": "true"}]}]}
}
JSON
( cd "${D}/cwd-empty" && env -i HOME="${H}" PATH="${SYS_PATH}" PARITY_AGENT_DIR="${D}/no-agent" "${INV}" > "${D}/planted.md" 2> "${D}/planted.err" ) || fail "3: the inventory exited nonzero with the planted settings: $(cat "${D}/planted.err")"
[ "$(row "${D}/planted.md" model)" == "x[1m] (~/.claude/settings.json env.ANTHROPIC_MODEL)" ] || fail "3: model row with the planted settings: $(row "${D}/planted.md" model)"
[ "$(row "${D}/planted.md" "context 1M")" == "yes" ] || fail "3: context row with the planted [1m] id: $(row "${D}/planted.md" "context 1M")"
[ "$(row "${D}/planted.md" effort)" == "planted-effort (~/.claude/settings.json env.CLAUDE_CODE_EFFORT_LEVEL)" ] || fail "3: effort row: $(row "${D}/planted.md" effort)"
[ "$(row "${D}/planted.md" fallbackModel)" == "y-fallback (~/.claude/settings.json)" ] || fail "3: fallbackModel row: $(row "${D}/planted.md" fallbackModel)"
[ "$(row "${D}/planted.md" "auto-memory")" == "off (~/.claude/settings.json autoMemoryEnabled false)" ] || fail "3: auto-memory row with autoMemoryEnabled false: $(row "${D}/planted.md" "auto-memory")"
[ "$(row "${D}/planted.md" plugins)" == "2: planted-a@m, planted-b@m" ] || fail "3: plugins row (the disabled one must not count): $(row "${D}/planted.md" plugins)"
[ "$(row "${D}/planted.md" hooks)" == "SessionStart 2, Stop 1" ] || fail "3: hooks row: $(row "${D}/planted.md" hooks)"
# the environment wins over the file, and the row says both agree
( cd "${D}/cwd-empty" && env -i HOME="${H}" PATH="${SYS_PATH}" PARITY_AGENT_DIR="${D}/no-agent" ANTHROPIC_MODEL="x[1m]" "${INV}" > "${D}/planted-env.md" 2>&1 ) || fail "3: the inventory exited nonzero with ANTHROPIC_MODEL in the environment"
[ "$(row "${D}/planted-env.md" model)" == "x[1m] (env ANTHROPIC_MODEL, same in ~/.claude/settings.json env)" ] || fail "3: model row with the id in the environment too: $(row "${D}/planted-env.md" model)"
( cd "${D}/cwd-empty" && env -i HOME="${H}" PATH="${SYS_PATH}" PARITY_AGENT_DIR="${D}/no-agent" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 "${INV}" > "${D}/planted-nomem.md" 2>&1 ) || fail "3: the inventory exited nonzero with CLAUDE_CODE_DISABLE_AUTO_MEMORY"
[ "$(row "${D}/planted-nomem.md" "auto-memory")" == "off (env CLAUDE_CODE_DISABLE_AUTO_MEMORY=1)" ] || fail "3: auto-memory row with the environment variable: $(row "${D}/planted-nomem.md" "auto-memory")"
echo "ok 3 - planted settings: model x[1m] read from the file's env (and from the environment when set there too), context yes, effort and fallbackModel as planted, auto-memory off by the setting and by the variable, 2 enabled plugins of 3, hooks SessionStart 2 Stop 1"

# --- 4. --json: the same rows, the same values ---
( cd "${D}/cwd-empty" && env -i HOME="${H}" PATH="${SYS_PATH}" PARITY_AGENT_DIR="${D}/no-agent" "${INV}" --json > "${D}/planted.json" 2>&1 ) || fail "4: --json exited nonzero"
python3 - "${D}/planted.json" "${D}/planted.md" "${ROWS}" << 'PY' || fail "4: the JSON object does not match the table (see above)"
import json, sys
d = json.load(open(sys.argv[1]))
rows = sys.argv[3].split("|")
if list(d) != rows:
    print("keys %s != rows %s" % (list(d), rows)); sys.exit(1)
table = {}
for line in open(sys.argv[2]):
    if line.startswith("| ") and not line.startswith("| row |") and not line.startswith("|---"):
        k, v = line[2:].rstrip("\n").rstrip(" |").split(" | ", 1)
        table[k] = v.replace("\\|", "|")
for k in rows:
    if k == "measured at":
        continue
    if table[k] != d[k]:
        print("row %r: table %r != json %r" % (k, table[k], d[k])); sys.exit(1)
PY
"${INV}" --nonsense > "${D}/bad.out" 2>&1; RC=$?
[ "${RC}" == "2" ] || fail "4: an unknown option exits ${RC}, not 2: $(cat "${D}/bad.out")"
echo "ok 4 - --json: one object, the 24 keys in the table's order, every value the table's; an unknown option exits 2"

# --- 5. a loop script on a native host; a CLAUDE.md and its @-import in the working directory ---
W=${D}/cwd-with-instructions
mkdir -p "${W}/.claude/rules"
printf '# planted\n@planted-import.md\n' > "${W}/CLAUDE.md"   # 29 bytes
printf 'twelve bytes\n' > "${W}/planted-import.md"      # 13 bytes
printf 'rule\n' > "${W}/.claude/rules/planted.md"       # 5 bytes
cat > "${D}/loop-planted.sh" << 'EOF2'
#!/bin/bash
# a native loop: two fires
timeout 1500 claude -p --dangerously-skip-permissions "$PROMPT" > out 2>&1
timeout 900 "${CLAUDE_BIN}" -p --permission-mode=acceptEdits --allowedTools "Bash(git status:*)" Read "$PROMPT"
# claude -p in a comment does not count
EOF2
( cd "${W}" && env -i HOME="${D}/home-empty" PATH="${SYS_PATH}" PARITY_AGENT_DIR="${D}/no-agent" PARITY_LOOP_SCRIPT="${D}/loop-planted.sh" "${INV}" > "${D}/native.md" 2>&1 ) || fail "5: the inventory exited nonzero with PARITY_LOOP_SCRIPT"
F=$(row "${D}/native.md" "autonomous fire")
[ "${F}" == "2 claude -p line(s) in ${D}/loop-planted.sh: timeout 1500 --dangerously-skip-permissions; timeout 900 --permission-mode acceptEdits --allowedTools Bash(git status:*) Read" ] || fail "5: fire row from the planted loop script (the \${CLAUDE_BIN} form, --permission-mode=, a rule with a space): ${F}"
I=$(row "${D}/native.md" instructions)
echo "${I}" | grep -qF "${W}/CLAUDE.md 29" || fail "5: the working directory's CLAUDE.md (29 bytes) is not in the instructions row: ${I}"
echo "${I}" | grep -qF "${W}/.claude/rules/planted.md 5" || fail "5: .claude/rules/planted.md (5 bytes) is not in the instructions row: ${I}"
echo "${I}" | grep -qF "${W}/planted-import.md 13" || fail "5: the @-imported file (13 bytes) is not in the instructions row: ${I}"
echo "${I}" | grep -q "^3 file(s), 47 bytes: " || fail "5: the instructions total is not 3 files, 47 bytes: ${I}"
echo "ok 5 - PARITY_LOOP_SCRIPT: both claude -p lines (one through \${CLAUDE_BIN}, with --permission-mode= and a quoted rule) with their timeout and permission words, the comment not counted; the cwd's CLAUDE.md, its .claude/rules file and its @-import counted with their bytes (3 files, 47 bytes)"

# --- 6. the fire's authority: loop-once.sh with a stand-in claude ---
mkdir -p "${D}/bin"
cat > "${D}/bin/claude" << 'EOF2'
#!/bin/sh
printf '%s\n' "$@" > "${FAKE_ARGV_OUT}"
printf '%s\n' "${IS_SANDBOX-unset}" > "${FAKE_SANDBOX_OUT}"
cat > /dev/null
echo "stand-in done"
EOF2
chmod +x "${D}/bin/claude"
SAFE="--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits"
# once <dir> [VAR=value ...] - one loop-once.sh fire against a planted goals file, offline (no Slack, no bus intake)
once()
{
	local L=$1; shift
	mkdir -p "${L}"; echo "planted goal" > "${L}/GOALS.md"
	env -u IS_SANDBOX "$@" LOOP_INBOX=false SLACK_WATCH_ENABLED=false SLACK_CHAT_ENABLED=false CLAUDE_BIN="${D}/bin/claude" \
		FAKE_ARGV_OUT="${L}/argv.txt" FAKE_SANDBOX_OUT="${L}/sandbox.txt" \
		AUTONOMY_LOOP_DIR="${L}" AUTONOMY_LOOP_WORKDIR="${L}" AUTONOMY_LOOP_GOALS="${L}/GOALS.md" \
		"${AGENT_DIR}/loop-once.sh" > "${L}/once.out" 2>&1 < /dev/null || fail "6: loop-once.sh exited nonzero (${L}): $(tail -3 "${L}/once.out")"
	grep -q " END rc=0 " "${L}/loop.log" || fail "6: the fire did not end rc=0 (${L}): $(grep ' END ' "${L}/loop.log")"
}
once "${D}/fire-default" -u AUTONOMY_LOOP_CLAUDE_OPTS
printf '%s\n' -p --allowedTools "Bash(/agent/slack-post.sh:*)" "Bash(/agent/slack-upload.sh:*)" "Bash(/agent/recall.sh:*)" "Bash(/agent/bus-answer.sh:*)" --permission-mode acceptEdits > "${D}/argv-default.expected"
cmp -s "${D}/argv-default.expected" "${D}/fire-default/argv.txt" || fail "6: the default fire's argv is not exactly -p and the safe value: $(tr '\n' ' ' < "${D}/fire-default/argv.txt")"
[ "$(cat "${D}/fire-default/sandbox.txt")" == "unset" ] || fail "6: the default fire's claude got IS_SANDBOX (got: $(cat "${D}/fire-default/sandbox.txt")); the default skips no permission check"
once "${D}/fire-optin" AUTONOMY_LOOP_CLAUDE_OPTS="--dangerously-skip-permissions"
printf '%s\n' -p --dangerously-skip-permissions > "${D}/argv-optin.expected"
cmp -s "${D}/argv-optin.expected" "${D}/fire-optin/argv.txt" || fail "6: the opt-in fire's argv is not exactly '-p --dangerously-skip-permissions': $(tr '\n' ' ' < "${D}/fire-optin/argv.txt")"
[ "$(cat "${D}/fire-optin/sandbox.txt")" == "1" ] || fail "6: the opt-in fire's claude did not get IS_SANDBOX=1 (got: $(cat "${D}/fire-optin/sandbox.txt"))"
once "${D}/fire-safe" AUTONOMY_LOOP_CLAUDE_OPTS="${SAFE}"
printf '%s\n' -p --allowedTools "Bash(/agent/slack-post.sh:*)" "Bash(/agent/recall.sh:*)" "Bash(/agent/bus-answer.sh:*)" --permission-mode acceptEdits > "${D}/argv-safe.expected"
cmp -s "${D}/argv-safe.expected" "${D}/fire-safe/argv.txt" || fail "6: the safe value's argv is not the three rules then acceptEdits: $(tr '\n' ' ' < "${D}/fire-safe/argv.txt")"
[ "$(cat "${D}/fire-safe/sandbox.txt")" == "unset" ] || fail "6: the safe value's claude got IS_SANDBOX (got: $(cat "${D}/fire-safe/sandbox.txt")); only a fire that skips permissions gets it"
once "${D}/fire-bypass" AUTONOMY_LOOP_CLAUDE_OPTS="--permission-mode bypassPermissions"
[ "$(cat "${D}/fire-bypass/sandbox.txt")" == "1" ] || fail "6: --permission-mode bypassPermissions did not get IS_SANDBOX=1 (got: $(cat "${D}/fire-bypass/sandbox.txt"))"
once "${D}/fire-bypass-eq" AUTONOMY_LOOP_CLAUDE_OPTS="--permission-mode=bypassPermissions"
[ "$(cat "${D}/fire-bypass-eq/sandbox.txt")" == "1" ] || fail "6: --permission-mode=bypassPermissions did not get IS_SANDBOX=1 (got: $(cat "${D}/fire-bypass-eq/sandbox.txt"))"
# the real loop (loop.sh), one fire with the stand-in, then the STOP flag
LP=${D}/loop-real
mkdir -p "${LP}"; echo "planted goal" > "${LP}/GOALS.md"
env -u IS_SANDBOX -u AUTONOMY_LOOP_CLAUDE_OPTS LOOP_INBOX=false SLACK_WATCH_ENABLED=false SLACK_CHAT_ENABLED=false CLAUDE_BIN="${D}/bin/claude" \
	FAKE_ARGV_OUT="${LP}/argv.txt" FAKE_SANDBOX_OUT="${LP}/sandbox.txt" AUTONOMY_LOOP_INTERVAL=1 \
	AUTONOMY_LOOP_DIR="${LP}" AUTONOMY_LOOP_WORKDIR="${LP}" AUTONOMY_LOOP_GOALS="${LP}/GOALS.md" \
	"${AGENT_DIR}/loop.sh" > "${LP}/loop.stdout" 2>&1 < /dev/null &
LPID=$!
W=0; while ! grep -q " END rc=" "${LP}/loop.log" 2>/dev/null && [ "${W}" -lt 60 ]; do sleep 1; W=$((W + 1)); done
touch "${LP}/STOP"
W=0; while kill -0 "${LPID}" 2>/dev/null && [ "${W}" -lt 30 ]; do sleep 1; W=$((W + 1)); done
kill "${LPID}" 2>/dev/null
grep -q " END rc=0 " "${LP}/loop.log" || fail "6: loop.sh's fire did not end rc=0: $(tail -3 "${LP}/loop.log")"
cmp -s "${D}/argv-default.expected" "${LP}/argv.txt" || fail "6: loop.sh's default fire argv is not exactly -p and the safe value: $(tr '\n' ' ' < "${LP}/argv.txt")"
[ "$(cat "${LP}/sandbox.txt")" == "unset" ] || fail "6: loop.sh's default fire got IS_SANDBOX (got: $(cat "${LP}/sandbox.txt"))"
for S in loop.sh loop-once.sh; do
	grep -qxF 'AUTONOMY_LOOP_FIRE_TIMEOUT=${AUTONOMY_LOOP_FIRE_TIMEOUT:-1500}' "${AGENT_DIR}/${S}" || fail "6: ${S} does not default AUTONOMY_LOOP_FIRE_TIMEOUT to 1500"
	grep -qxF 'AUTONOMY_LOOP_CLAUDE_OPTS=${AUTONOMY_LOOP_CLAUDE_OPTS:-"--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits"}' "${AGENT_DIR}/${S}" || fail "6: ${S} does not default AUTONOMY_LOOP_CLAUDE_OPTS to the safe value"
done
# .env exports the 1500 into the container's options (where the file is reachable: a checkout, or the checkout mounted at /do-agent-aws)
ENV_FILE=""
for C in "${BASE_DIR}/../.env" "/do-agent-aws/.env"; do
	[ -f "${C}" ] && [ -f "$(dirname "${C}")/.fun" ] && ENV_FILE="$(cd "$(dirname "${C}")" && pwd)/.env" && break
done
ENV_NOTE="(.env not reachable from here: its export was not checked)"
if [ -n "${ENV_FILE}" ]; then
	mkdir -p "${D}/envpass"
	cp "${ENV_FILE}" "$(dirname "${ENV_FILE}")/.fun" "${D}/envpass/"
	OPTS=$(cd "${D}/envpass" && env -i HOME="${D}/home-empty" PATH="${SYS_PATH}:/usr/bin:/bin" ENV_LOCAL_SETUP=false bash -c 'source ./.env > /dev/null 2>&1; printf "%s" "${AUTONOMY_ENV_OPTS}"')
	echo " ${OPTS} " | grep -qF -- " -e AUTONOMY_LOOP_FIRE_TIMEOUT=1500 " || fail "6: sourcing .env does not put -e AUTONOMY_LOOP_FIRE_TIMEOUT=1500 into AUTONOMY_ENV_OPTS: ${OPTS}"
	echo " ${OPTS} " | grep -qF -- " -e AUTONOMY_LOOP_CLAUDE_OPTS " || fail "6: sourcing .env does not pass AUTONOMY_LOOP_CLAUDE_OPTS bare in AUTONOMY_ENV_OPTS: ${OPTS}"
	ENV_NOTE="(.env: -e AUTONOMY_LOOP_FIRE_TIMEOUT=1500 and the bare -e AUTONOMY_LOOP_CLAUDE_OPTS in AUTONOMY_ENV_OPTS)"
fi
# the inventory's fire row in a stand-in container layout: /agent/loop.sh is where IN_CONTAINER is decided, so the layout is
# imitated with PARITY_LOOP_SCRIPT pointing at the real loop.sh of this tree; the row then reads a native host's lines - the
# container branch itself is read from the defaults by the same loop_default() regex, exercised here on the two scripts
python3 - "${AGENT_DIR}/loop.sh" "${AGENT_DIR}/slack-chat.sh" << 'PY' || fail "6: the NAME=\${NAME:-default} lines of loop.sh/slack-chat.sh are not readable by the inventory's regex (see above)"
import re, sys
def loop_default(path, name):
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r'^\s*%s=\$\{%s:-"?(.*?)"?\}\s*$' % (name, name), line)
        if m:
            return m.group(1)
    return None
got = (loop_default(sys.argv[1], "AUTONOMY_LOOP_CLAUDE_OPTS"), loop_default(sys.argv[1], "AUTONOMY_LOOP_FIRE_TIMEOUT"))
if got != ("--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits", "1500"):
    print("loop.sh defaults read as %r" % (got,)); sys.exit(1)
if loop_default(sys.argv[2], "SLACK_CHAT_CLAUDE_OPTS") is None or loop_default(sys.argv[2], "SLACK_CHAT_TIMEOUT") is None:
    print("slack-chat.sh defaults not readable"); sys.exit(1)
PY
echo "ok 6 - fire authority: the default fire (loop-once.sh and loop.sh) gets exactly -p and the safe value (four rules then acceptEdits) and no IS_SANDBOX, the three-rule value the same way, the opt-in --dangerously-skip-permissions and --permission-mode bypassPermissions (either spelling) IS_SANDBOX=1; both scripts default the timeout to 1500 ${ENV_NOTE}; the inventory reads the scripts' defaults"

# --- 7. the auto-memory setting ---
MS=${AGENT_DIR}/claude-memory-settings.py
[ -f "${MS}" ] || fail "7: ${MS} is missing"
PYTHONPYCACHEPREFIX="${D}/pycache" python3 -m py_compile "${MS}" || fail "7: ${MS} does not compile"
mkdir -p "${D}/mem"
printf '{"env": {"K": "v"}, "hooks": {"Stop": []}, "permissions": {"deny": ["Edit(//wd/loglearner/**)"]}}\n' > "${D}/mem/settings.json"
OUT=$(env -u AGENT_MEMORY python3 "${MS}" "${D}/mem/settings.json") || fail "7: the first run exited nonzero: ${OUT}"
echo "${OUT}" | grep -q "autoMemoryEnabled set to true" || fail "7: the first run did not report setting true: ${OUT}"
python3 - "${D}/mem/settings.json" << 'PY' || fail "7: after the first run the file does not carry autoMemoryEnabled true with every other key kept"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["autoMemoryEnabled"] is True, s
assert s["env"] == {"K": "v"} and s["hooks"] == {"Stop": []} and s["permissions"] == {"deny": ["Edit(//wd/loglearner/**)"]}, s
PY
OUT=$(env -u AGENT_MEMORY python3 "${MS}" "${D}/mem/settings.json") || fail "7: the second run exited nonzero"
echo "${OUT}" | grep -q "already true" || fail "7: the second run is not a no-op that says so: ${OUT}"
OUT=$(AGENT_MEMORY=false python3 "${MS}" "${D}/mem/settings.json") || fail "7: the AGENT_MEMORY=false run exited nonzero"
python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); assert s["autoMemoryEnabled"] is False and s["env"] == {"K": "v"}, s' "${D}/mem/settings.json" \
	|| fail "7: AGENT_MEMORY=false did not set autoMemoryEnabled false with the other keys kept: $(cat "${D}/mem/settings.json")"
printf 'not json\n' > "${D}/mem/bad.json"
OUT=$(python3 "${MS}" "${D}/mem/bad.json") || fail "7: the invalid-JSON run exited nonzero: ${OUT}"
echo "${OUT}" | grep -q "is not valid JSON" || fail "7: the invalid-JSON run did not say so: ${OUT}"
[ "$(cat "${D}/mem/bad.json")" == "not json" ] || fail "7: the invalid JSON file was changed"
python3 "${MS}" "${D}/mem/new/settings.json" > /dev/null || fail "7: the missing-file run exited nonzero"
[ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])))' "${D}/mem/new/settings.json")" == "{'autoMemoryEnabled': True}" ] || fail "7: the missing file was not created with the one key: $(cat "${D}/mem/new/settings.json")"
grep -q 'claude-memory-settings.py" "${CLAUDE_DIR}/settings.json"' "${AGENT_DIR}/claude-settings-sync.sh" || fail "7: claude-settings-sync.sh does not run claude-memory-settings.py on the agent's settings.json"
echo "ok 7 - auto-memory setting: true written with every other key kept, a no-op second run, false on AGENT_MEMORY=false, invalid JSON left alone with a message, a missing file created; claude-settings-sync.sh runs the step"

# --- 8. the overlay stub ---
OV=${AGENT_DIR}/claude-overlay.sh
[ -f "${OV}" ] || fail "8: ${OV} is missing"
bash -n "${OV}" || fail "8: ${OV} does not parse"
mkdir -p "${D}/ov/wd" "${D}/ov/own"
OUT=$(env -u AGENT_OVERLAY OVERLAY_DIR="${D}/ov/wd" OVERLAY_EXAMPLE=/agent/CLAUDE.md.example "${OV}") || fail "8: the first run exited nonzero: ${OUT}"
echo "${OUT}" | grep -q "wrote the stub ${D}/ov/wd/CLAUDE.md" || fail "8: the first run did not report writing the stub: ${OUT}"
head -1 "${D}/ov/wd/CLAUDE.md" | grep -qx '<!-- do-agent-aws overlay stub -->' || fail "8: the stub does not start with its marker"
grep -q '/agent/CLAUDE.md.example' "${D}/ov/wd/CLAUDE.md" || fail "8: the stub does not name the example"
grep -q "working directory is ${D}/ov/wd" "${D}/ov/wd/CLAUDE.md" || fail "8: the stub does not name the working directory"
cp "${D}/ov/wd/CLAUDE.md" "${D}/ov/stub.copy"
OUT=$(OVERLAY_DIR="${D}/ov/wd" "${OV}") || fail "8: the second run exited nonzero"
echo "${OUT}" | grep -q "is the stub - the overlay is not filled yet" || fail "8: the second run does not say the file is the stub: ${OUT}"
cmp -s "${D}/ov/stub.copy" "${D}/ov/wd/CLAUDE.md" || fail "8: the second run changed the stub"
printf '# my overlay\nOperator: someone\n' > "${D}/ov/own/CLAUDE.md"
OUT=$(OVERLAY_DIR="${D}/ov/own" "${OV}") || fail "8: the run on an operator file exited nonzero"
echo "${OUT}" | grep -q "the operator's overlay, left as it is" || fail "8: an operator file was not reported as the operator's: ${OUT}"
[ "$(cat "${D}/ov/own/CLAUDE.md")" == "$(printf '# my overlay\nOperator: someone')" ] || fail "8: the operator's file was changed"
mkdir -p "${D}/ov/off"
OUT=$(AGENT_OVERLAY=false OVERLAY_DIR="${D}/ov/off" "${OV}") || fail "8: the AGENT_OVERLAY=false run exited nonzero"
[ ! -e "${D}/ov/off/CLAUDE.md" ] || fail "8: AGENT_OVERLAY=false wrote a file"
echo "${OUT}" | grep -q "AGENT_OVERLAY=false - no stub written" || fail "8: the AGENT_OVERLAY=false run did not say so: ${OUT}"
OUT=$(OVERLAY_DIR="${D}/ov/missing" "${OV}") || fail "8: the missing-directory run exited nonzero"
[ ! -e "${D}/ov/missing" ] || fail "8: the missing directory was created"
echo "${OUT}" | grep -q "does not exist here" || fail "8: the missing-directory run did not say so: ${OUT}"
grep -q '"${AGENT_DIR}/claude-overlay.sh"' "${AGENT_DIR}/claude-settings-sync.sh" || fail "8: claude-settings-sync.sh does not run claude-overlay.sh"
DF=""
for C in "${BASE_DIR}/../Dockerfile" "/do-agent-aws/Dockerfile"; do [ -f "${C}" ] && DF=${C} && break; done
if [ -n "${DF}" ]; then
	grep -q '^COPY docs/parity/CLAUDE.md.example /agent/CLAUDE.md.example$' "${DF}" || fail "8: the Dockerfile does not copy the example to /agent/CLAUDE.md.example"
	DF_NOTE="; the Dockerfile ships the example"
else
	DF_NOTE="; the Dockerfile not reachable from here"
	[ -f /agent/CLAUDE.md.example ] && DF_NOTE="; /agent/CLAUDE.md.example is in the image"
fi
echo "ok 8 - overlay stub: written into an empty working directory naming the example and the directory, left byte for byte on a second run, an operator's file never touched, nothing with AGENT_OVERLAY=false or without the directory; claude-settings-sync.sh runs the step${DF_NOTE}"

# --- 9. the container branch ---
RULES=${BASE_DIR%/}/agent-rules
[ -d "${RULES}" ] || fail "9: no rules directory at ${RULES}"
mkdir -p "${D}/home-c" "${D}/cwd-c"
( cd "${D}/cwd-c" && env -i HOME="${D}/home-c" PATH="${SYS_PATH}" PARITY_AGENT_DIR="${AGENT_DIR}" PARITY_RULES_DIR="${RULES}" "${INV}" > "${D}/container.md" 2> "${D}/container.err" ) || fail "9: the inventory exited nonzero in the container layout: $(cat "${D}/container.err")"
F=$(row "${D}/container.md" "autonomous fire")
echo "${F}" | grep -qF "loop fire: claude -p --allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits (the default of " || fail "9: the fire row does not read the loop's shipped default: ${F}"
echo "${F}" | grep -qF "timeout 1500 s (the default of " || fail "9: the fire row does not read the loop's 1500 s default: ${F}"
echo "${F}" | grep -qF "chat responder: claude -p --allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/goals-add.sh:*) --permission-mode acceptEdits (the default of " || fail "9: the fire row does not read the responder's shipped default: ${F}"
[ "$(echo "${F}" | grep -o "timeout 1500 s" | wc -l)" == "2" ] || fail "9: the fire row does not read both 1500 s defaults: ${F}"
I=$(row "${D}/container.md" instructions)
echo "${I}" | grep -q "^none loaded; shipped but not loaded by any of them: " || fail "9: with no CLAUDE.md the instructions row does not list the shipped rules apart: ${I}"
for N in AGENT_BOARD AGENT_FILES AGENT_LEARNING AGENT_RULES; do echo "${I}" | grep -qF "${RULES}/${N}.md" || fail "9: the shipped ${N}.md is not listed: ${I}"; done
# a planted CLAUDE.md that imports a copy of AGENT_RULES.md: the copy is counted once, the other three stay apart
mkdir -p "${D}/home-c2/.claude"
cp "${RULES}/AGENT_RULES.md" "${D}/home-c2/.claude/AGENT_RULES.md"
printf '# agent\n@AGENT_RULES.md\n' > "${D}/home-c2/.claude/CLAUDE.md"   # 24 bytes
( cd "${D}/cwd-c" && env -i HOME="${D}/home-c2" PATH="${SYS_PATH}" PARITY_AGENT_DIR="${AGENT_DIR}" PARITY_RULES_DIR="${RULES}" "${INV}" > "${D}/container2.md" 2>&1 ) || fail "9: the inventory exited nonzero with the planted CLAUDE.md"
I=$(row "${D}/container2.md" instructions)
RB=$(wc -c < "${RULES}/AGENT_RULES.md")
echo "${I}" | grep -q "^2 file(s), $(( 24 + RB )) bytes: ~/.claude/CLAUDE.md 24; ~/.claude/AGENT_RULES.md ${RB}; shipped but not loaded by any of them: " || fail "9: the imported copy is not counted once with the planted CLAUDE.md: ${I}"
echo "${I}" | grep -qF "${RULES}/AGENT_RULES.md" && fail "9: the shipped AGENT_RULES.md is listed although its bytes are loaded through the copy: ${I}"
for N in AGENT_BOARD AGENT_FILES AGENT_LEARNING; do echo "${I}" | grep -qF "${RULES}/${N}.md" || fail "9: the shipped ${N}.md is not listed as not loaded: ${I}"; done
echo "ok 9 - container branch: the fire row reads the loop's and the responder's shipped defaults (their safe values, 1500 s each); with no CLAUDE.md the four shipped rules read as shipped but not loaded; a planted CLAUDE.md importing a copy of AGENT_RULES.md counts the copy once and leaves the other three apart"

echo "Test-parity-inventory succeeded"
