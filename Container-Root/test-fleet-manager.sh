#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the session ledger and the bounded close (docs/AGENT-STACK.md "The session ledger"): for each start,
# restart and stop it performs, and for each scratch tmux session that appears or goes, the supervisor
# (/agent/supervisor.sh) appends a line to ${SUPERVISOR_DIR}/sessions-ledger.jsonl (/agent/session-ledger.py) with the
# session's identity, its work and the command that resumes it; supervisor.sh resume <session> recreates a session from
# its latest line; a scratch session whose every pane's process has exited is closed at the second pass that sees it so.
# Fully OFFLINE: a test-local registry (a hub, the supervisor's own session, an enabled spoke and a spoke that is off), a
# stub claude, working directories, the supervisor's state and a tmux server of the test's own (TMUX_TMPDIR) under
# /tmp/fleet-manager-smoke (or TEST_FM_DIR); nothing under /wd.
#
# Properties proven (each check FAILS if the property is removed):
#   1 [ledger-start-line] the supervisor's start of a spoke appends a start line: the spoke's registry name, its pane's
#     pid, the session's creation time, its directory, its launch command, the registry start that resumes it and the
#     supervisor's reason; the hub, found running with the Claude Code session its claude keeps and a resume command that
#     names it, and two scratch sessions, which appear while the supervisor runs, get start lines from its census: a
#     scratch session's line carries its directory, its command, the commit of the git
#     repository it runs in, the last line of the STATUS file there and the tmux command that recreates it.
#     supervisor.sh ledger prints the latest line of each session, ledger <session> that of one, and exits 1 for a
#     session with no line; a view of the harness's own (owner do-agent-aws, not in the registry) gets no line; the
#     hub's line takes no work from a status file of the supervisor's written before the hub's session was created (the
#     last container's, at the first census after a restart)
#   2 [ledger-stop-line] a scratch session that ends gets a stop line with what its start line said; supervisor.sh
#     record-stop (the stack's stop path: ./stop.sh runs it before it removes the container) appends a stop line for each
#     running session, read from its pane, with the Claude Code session id of a spoke and of a scratch session (the stub
#     keeps <config dir>/sessions/<pid>.json as claude does) and a resume command that names it
#   3 [resume-registry] supervisor.sh resume <spoke> recreates a stopped registry spoke through its registry start, with
#     the spoke's own claude options and --resume <the recorded id>, and appends a resume line; the hub too; a resume of
#     a session that runs is refused and appends nothing
#   4b [resume-options] the option words a resume drops (--continue, -c, --resume or -r with its id, --session-id with its
#     value) and keeps (every other word), and the session id read from the options only as a word of its own
#   4 [resume-scratch] supervisor.sh resume <scratch session> recreates it in its recorded directory with its recorded
#     command, and one whose Claude Code session was recorded as its claude, with its own options, and --resume <id>;
#     each appends a resume line, the claude one, with a registry that has gained its name, still as the scratch session
#     its line records; a resume while it runs is refused
#   5 [close-exited] a scratch session whose every pane's process has exited (remain-on-exit keeps the pane and what its
#     process printed) is closed at the second pass in a row that sees it so, with a closed-exited line naming both
#     passes and the file that keeps the pane's output, which holds what the process printed (the old close lost it) under
#     a header naming the pane, its exit status, the lines its history held with its history-limit and its command, and
#     one notice to the hub naming the file; a scratch session whose process runs, a registry session whose pane's
#     process has exited (the spoke that is off) and the running hub and spoke stay, three passes later, with no
#     closed-exited line
#   5b [close-keeps-output] a scratch session whose output cannot be copied (the copies' directory is a plain file) stays
#     open with no closed-exited line, and the supervisor says why once. CONTROL: with the directory back it is closed and
#     its output kept
#   5c [census-read-fails] while every read of all the server's panes fails (a tmux of the test's own refuses it), the
#     supervisor writes no line for the sessions that run, closes nothing, says so once and says when it can read again;
#     supervisor.sh record-stop fails and writes nothing
#   5d [census-no-server] with no tmux server (no socket, and a socket no server listens on) supervisor.sh record-stop
#     exits 0 and writes no line: no server is no session, not a failed read
#   5e [kept-header] a kept pane's header gives "-" for an exit status tmux does not give (a process a signal ended) and
#     0 for a process that exited 0; a pane that printed more than its history-limit keeps its last lines, and its header
#     gives the lines its history held, the limit, and that its earliest lines may be gone
#   5f [close-rereads] a pass whose read again of an exited scratch session's panes fails closes nothing (CONTROL: a later
#     pass closes it); a pane whose process starts again right after that read is neither copied nor closed: its session
#     stays, running, with no closed-exited line and no kept file
#   6 [close-off] with SUPERVISOR_CLOSE_EXITED=false a scratch session whose process has exited stays for five passes
#     with no closed-exited line, and the supervisor's stop and start add no line for the sessions that ran through them.
#     CONTROL: started again with the setting true, the supervisor closes it
#   7 [append-only] every write only appended: the ledger as it was after check 1 is a prefix of the ledger now, in the
#     same file; twenty writers at once add twenty whole lines; every line is a JSON object with the line's keys and one
#     of the four events. PLANTED CONTROL: a copy of the writer that rewrites the file fails the prefix check
#   8 in the test container (TEST_CONTAINER=true) nothing is left under /wd. PLANTED CONTROL: an entry planted there is
#     named

fail()
{
	echo "Test-fleet-manager FAILED: $1"
	exit 1
}

unset TMUX TMUX_PANE
D=${TEST_FM_DIR:-/tmp/fleet-manager-smoke}
rm -rf "${D:?}"
mkdir -p "${D}/tmux" "${D}/stub" "${D}/charters/fm-alpha" "${D}/charters/fm-beta" "${D}/wd/fm-alpha" "${D}/wd/fm-beta" \
	"${D}/wd/fm-sup" "${D}/chat" "${D}/repo" || fail "could not create ${D}"
# what /wd holds before this test (check 8)
find /wd -mindepth 1 2>/dev/null | sort > "${D}/wd-before.txt"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
SUP="${AGENT_DIR}/supervisor.sh"
LEDGER_TOOL="${AGENT_DIR}/session-ledger.py"
SHIPPED_REGISTRY="${AGENT_DIR}/spokes/registry.json"
for F in "${SUP}" "${AGENT_DIR}/tmux-session-start.sh" "${LEDGER_TOOL}" "${SHIPPED_REGISTRY}"; do
	[ -f "${F}" ] || fail "${F} is not there"
done
command -v tmux > /dev/null || fail "tmux is not installed"

# test-local everything, and a tmux server of the test's own: every tmux call below, and in the scripts it runs, uses it
export TMUX_TMPDIR=${D}/tmux
export SPOKES_REGISTRY=${D}/registry.json SUPERVISOR_DIR=${D}/supervisor AGENT_TMUX_SESSION_NAME=fm-hub
export MAILBOX_STATE_ROOT=${D}/mailbox-state MAILBOX_PROJECTION_ROOT=${D}/mailbox
export CLAUDE_CONFIG_DIR=${D}/claude-config TMUX_AGENT_HOME=${D}/tmux-agent-home
export UI_START=false UI_HINDSIGHT=false UI_CLAUDE_MEM=false HINDSIGHT_WAIT_SECS=0
export SUPERVISOR=true SUPERVISOR_INTERVAL=1 SUPERVISOR_CLOSE_EXITED=true AGENT_TMUX_SESSION=true AGENT_TMUX_CLAUDE=true
export SPOKE_FM_ALPHA=true SPOKE_FM_BETA=false
# the claude options the sessions start with, which a resume keeps
export AGENT_TMUX_CLAUDE_OPTS=--fm-opt
# the stub claude, for the registry's sessions (CLAUDE_BIN) and for a scratch pane's plain "claude" (PATH): it logs where
# it runs and how it was called, keeps a Claude Code session record for its pid (<config dir>/sessions/<pid>.json, as
# claude does while it runs: with --resume <id> that id, else a new one) and stays up. It is in a test-local HOME's
# .local/bin, which supervisor.sh puts first on its PATH: tmux gives a new pane the PATH of the client that creates it,
# and supervisor.sh resume creates the scratch sessions' panes
export HOME=${D}/home FM_STUB_LOG=${D}/stub/claude.log
export CLAUDE_BIN=${HOME}/.local/bin/claude PATH="${HOME}/.local/bin:${PATH}"
mkdir -p "${HOME}/.local/bin" || fail "could not create ${HOME}/.local/bin"
cat > "${CLAUDE_BIN}" << 'EOF'
#!/bin/bash
SID=$(cat /proc/sys/kernel/random/uuid)
PREV=""
for A in "$@"; do
	[ "${PREV}" == "--resume" ] && SID=${A}
	PREV=${A}
done
mkdir -p "${CLAUDE_CONFIG_DIR:?}/sessions"
echo "{\"pid\": $$, \"sessionId\": \"${SID}\", \"cwd\": \"$(pwd)\"}" > "${CLAUDE_CONFIG_DIR:?}/sessions/$$.json"
echo "cwd=$(pwd) args=$* sid=${SID}" >> "${FM_STUB_LOG:?}"
while :; do sleep 1; done
EOF
chmod +x "${CLAUDE_BIN}"
# the test's tmux, in the same directory and so first on the scripts' PATH: the real one, except that a read of all the
# server's panes fails while ${D}/tmux-read-fails exists (check 5c plants that failure), and that the close's read again
# of a session's panes (list-panes -s -t =<session>: -F #{pane_dead}) fails once while ${D}/reread-fails.<session>
# exists, or starts the pane's process again right after it read while ${D}/respawn-after-reread.<session> exists (check
# 5f plants both); a flag is renamed when it acts
REAL_TMUX=$(command -v tmux) || fail "tmux is not installed"
cat > "${HOME}/.local/bin/tmux" << EOF
#!/bin/bash
[ "\$1" == "list-panes" ] && [ "\$2" == "-a" ] && [ -e "${D}/tmux-read-fails" ] && { echo "planted read failure" >&2; exit 1; }
if [ "\$1" == "list-panes" ] && [ "\$2" == "-s" ] && [ "\$3" == "-t" ] && [ "\$5" == "-F" ] && [ "\$6" == "#{pane_dead}" ]; then
	S=\${4#=}
	S=\${S%:}
	if [ -e "${D}/reread-fails.\${S}" ]; then
		mv "${D}/reread-fails.\${S}" "${D}/reread-failed.\${S}"
		echo "planted read failure" >&2
		exit 1
	fi
	if [ -e "${D}/respawn-after-reread.\${S}" ]; then
		OUT=\$("${REAL_TMUX}" "\$@")
		RC=\$?
		"${REAL_TMUX}" respawn-pane -t "=\${S}:" "sleep 600"
		mv "${D}/respawn-after-reread.\${S}" "${D}/respawned.\${S}"
		printf '%s\n' "\${OUT}"
		exit "\${RC}"
	fi
fi
exec "${REAL_TMUX}" "\$@"
EOF
chmod +x "${HOME}/.local/bin/tmux"
LEDGER=${SUPERVISOR_DIR}/sessions-ledger.jsonl
MARK=fm-kept-output-$$
REPO=${D}/repo

# the test registry: the shipped hub, supervisor and example entries under test-local names, directories and charters
python3 -I - "${SHIPPED_REGISTRY}" "${SPOKES_REGISTRY}" "${D}" << 'EOF' || fail "could not write the test registry"
import json, sys
shipped, dst, d = sys.argv[1:4]
src = {e["session_name"]: e for e in json.load(open(shipped))["sessions"]}
hub = dict(src["agent"], session_name="fm-hub")
sup = dict(src["supervisor"], session_name="fm-sup", workdir=f"{d}/wd/fm-sup", parent="fm-hub")
def spoke(name):
    e = {k: v for k, v in src["example"].items() if k not in ("cycle", "cadence_sec", "notices", "requires", "requires_what", "ref")}
    e.update(session_name=name, flag="SPOKE_" + name.upper().replace("-", "_"), workdir=f"{d}/wd/{name}",
             charter=f"{d}/charters/{name}/charter.md", source="none", parent="fm-hub", task=f"test spoke {name}",
             writes=[f"{d}/wd/{name}/status.txt"])
    return e
json.dump({"version": 1, "sessions": [hub, sup, spoke("fm-alpha"), spoke("fm-beta")]}, open(dst, "w"), indent=1)
EOF
cp "${AGENT_DIR}/charters/example/charter.md" "${D}/charters/fm-alpha/charter.md" || fail "could not copy the example charter"
cp "${AGENT_DIR}/charters/example/charter.md" "${D}/charters/fm-beta/charter.md" || fail "could not copy the example charter"
OUT=$("${AGENT_DIR}/spoke.sh" check 2>&1) || fail "the test registry breaks the registry's rules: ${OUT}"
# a git repository with a STATUS file, for the scratch sessions' directory
git -C "${REPO}" init -q && git -C "${REPO}" -c user.name=fm -c user.email=fm@example.invalid commit -q --allow-empty -m one \
	|| fail "could not make the test repository"
HEAD_SHA=$(git -C "${REPO}" rev-parse HEAD)
printf '2026-01-01T00:00:00Z the first step\n2026-01-01T00:01:00Z the last step: tests written\n\n' > "${REPO}/STATUS"

SESSIONS="fm-hub fm-sup fm-alpha fm-beta fm-scratch fm-chat fm-exited fm-live fm-exited2 fm-keep fm-signal fm-long fm-reread fm-respawn fm-holder"
cleanup()
{
	"${SUP}" stop > /dev/null 2>&1
	for S in ${SESSIONS}; do tmux kill-session -t "=${S}" 2>/dev/null; done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# lj <session> <key> - <key> of the session's latest ledger line as supervisor.sh ledger prints it ("" when none)
lj()
{
	"${SUP}" ledger "$1" 2>/dev/null | python3 -I -c 'import json, sys
t = sys.stdin.read()
v = json.loads(t).get(sys.argv[1]) if t.strip() else None
print("" if v is None else v)' "$2"
}
# lines <session> [<event>] - how many ledger lines the session has (with that event)
lines()
{
	python3 -I -c 'import json, sys
n = 0
try:
    for l in open(sys.argv[1]):
        r = json.loads(l)
        n += r.get("session") == sys.argv[2] and (not sys.argv[3] or r.get("event") == sys.argv[3])
except OSError:
    pass
print(n)' "${LEDGER}" "$1" "${2:-}"
}
has_line() { [ "$(lines "$1" "$2")" -ge 1 ]; }
# lines_of <session...> - how many ledger lines those sessions have together
lines_of() { local N=0 X; for X in "$@"; do N=$(( N + $(lines "${X}") )); done; echo "${N}"; }
# pane <session> - "<pane pid> <session created>" of the session's first pane (nothing when it has no session)
pane() { tmux list-panes -t "=$1:" -F '#{pane_pid} #{session_created}' 2>/dev/null | head -1; }
running() { tmux has-session -t "=$1" 2>/dev/null; }
gone() { ! running "$1"; }
pane_exited() { [ "$(tmux list-panes -t "=$1:" -F '#{pane_dead}' 2>/dev/null)" == "1" ]; }
# status_is <session> <status> - tmux gives the exit status <status> to the session's pane ("" when it gives none)
status_is() { [ "$(tmux list-panes -t "=$1:" -F '#{pane_dead_status}' 2>/dev/null)" == "$2" ]; }
# passes - how many passes the supervisor has recorded (passes.jsonl, a line a pass)
passes() { [ -f "${SUPERVISOR_DIR}/passes.jsonl" ] && wc -l < "${SUPERVISOR_DIR}/passes.jsonl" || echo 0; }
passes_from() { [ "$(passes)" -ge "$1" ]; }
# upto <seconds> <command...> - true as soon as the command is, within the seconds given
upto()
{
	local N=$(( $1 * 2 ))
	shift
	for I in $(seq 1 "${N}"); do "$@" && return 0; sleep 0.5; done
	"$@"
}
# is_prefix <old> <new> - the file <new> begins with every byte of <old> and is longer
is_prefix() { python3 -I -c 'import sys; a, b = (open(p, "rb").read() for p in sys.argv[1:3]); sys.exit(0 if b.startswith(a) and len(b) > len(a) else 1)' "$1" "$2"; }
# expect <check> <what> <got> <want>
expect() { [ "$3" == "$4" ] || fail "$1: $2 is '$3', not '$4'"; }

# --- 1 [ledger-start-line] ---
# a view of the harness's own (owner do-agent-aws, not in the registry: as the autonomy loop's), which the ledger leaves
# out; it keeps the test's tmux server, with the test's environment, up for the whole test, as the hub keeps a container's
tmux new-session -d -s fm-holder "sleep 3600" \; set-option -t "=fm-holder:" @agent_owner do-agent-aws || fail "could not start fm-holder"
OUT=$("${AGENT_DIR}/tmux-session-start.sh" 2>&1) || fail "the hub's start: ${OUT}"
# the hub's claude runs (its session record is written before its log line) when the supervisor's census first reads it
upto 10 grep -q " args=--fm-opt sid=" "${FM_STUB_LOG}" || fail "the hub's claude did not start: ${OUT}"
# a status file of the supervisor's written before the hub's session was created, as a container's restart leaves the last
# container's: the census's start line for the hub must not take the hub's work from it
mkdir -p "${SUPERVISOR_DIR}" || fail "could not create ${SUPERVISOR_DIR}"
echo '{"updated_at": "2026-01-01T00:00:00Z", "pass": 9, "pid": 1, "sessions": {"fm-hub": {"enabled": true, "state": "fm-stale-state", "why": "a pass of the last container"}}, "health": {}}' \
	> "${SUPERVISOR_DIR}/status.json" || fail "could not plant an old status.json"
OUT=$("${SUP}" start 2>&1) || fail "supervisor.sh start: ${OUT}"
upto 30 has_line fm-alpha start || fail "ledger-start-line: no start line for the spoke fm-alpha within 30 s: $(tail -3 "${LEDGER}" 2>&1)"
read -r APID ACREATED <<< "$(pane fm-alpha)"
[ -n "${APID}" ] || fail "ledger-start-line: fm-alpha has a start line and no session"
C=ledger-start-line
expect ${C} "fm-alpha's event" "$(lj fm-alpha event)" start
expect ${C} "fm-alpha's agent" "$(lj fm-alpha agent)" fm-alpha
expect ${C} "fm-alpha's pane_pid" "$(lj fm-alpha pane_pid)" "${APID}"
expect ${C} "fm-alpha's created" "$(lj fm-alpha created)" "${ACREATED}"
expect ${C} "fm-alpha's cwd" "$(lj fm-alpha cwd)" "${D}/wd/fm-alpha"
expect ${C} "fm-alpha's command" "$(lj fm-alpha command)" "$("${AGENT_DIR}/spoke.sh" entry fm-alpha launch_cmd)"
expect ${C} "fm-alpha's resume" "$(lj fm-alpha resume)" "${AGENT_DIR}/tmux-session-start.sh fm-alpha"
case "$(lj fm-alpha reason)" in "supervisor: "*) ;; *) fail "${C}: fm-alpha's start line is not the supervisor's start: its reason is '$(lj fm-alpha reason)'" ;; esac
upto 10 has_line fm-hub start || fail "${C}: no start line for the hub"
read -r HPID HCREATED <<< "$(pane fm-hub)"
expect ${C} "the hub's pane_pid" "$(lj fm-hub pane_pid)" "${HPID}"
expect ${C} "the hub's created" "$(lj fm-hub created)" "${HCREATED}"
expect ${C} "the hub's agent" "$(lj fm-hub agent)" fm-hub
expect ${C} "the hub's reason" "$(lj fm-hub reason)" "found running"
case "$(lj fm-hub work)" in *fm-stale-state*) fail "${C}: the hub's start line took its work from a status file written before the hub's session was created: '$(lj fm-hub work)'" ;; esac
HSID0=$(grep "^cwd=$(lj fm-hub cwd) args=--fm-opt sid=" "${FM_STUB_LOG}" | tail -1 | sed -n 's/.* sid=//p')
[ -n "${HSID0}" ] || fail "${C}: no claude of the hub in its directory $(lj fm-hub cwd)"
expect ${C} "the hub's claude_session" "$(lj fm-hub claude_session)" "${HSID0}"
expect ${C} "the hub's resume" "$(lj fm-hub resume)" "AGENT_TMUX_CLAUDE_OPTS='--fm-opt --resume ${HSID0}' ${AGENT_DIR}/tmux-session-start.sh"
tmux new-session -d -s fm-scratch -c "${REPO}" "sleep 600" || fail "could not start the scratch session fm-scratch"
tmux new-session -d -s fm-chat -c "${D}/chat" "claude --fm-chat-opt" || fail "could not start the scratch session fm-chat"
upto 20 has_line fm-scratch start || fail "${C}: no start line for the scratch session fm-scratch within 20 s"
upto 20 has_line fm-chat start || fail "${C}: no start line for the scratch session fm-chat within 20 s"
read -r SPID SCREATED <<< "$(pane fm-scratch)"
expect ${C} "fm-scratch's agent" "$(lj fm-scratch agent)" scratch
expect ${C} "fm-scratch's pane_pid" "$(lj fm-scratch pane_pid)" "${SPID}"
expect ${C} "fm-scratch's created" "$(lj fm-scratch created)" "${SCREATED}"
expect ${C} "fm-scratch's cwd" "$(lj fm-scratch cwd)" "${REPO}"
expect ${C} "fm-scratch's command" "$(lj fm-scratch command)" "sleep 600"
expect ${C} "fm-scratch's git_head" "$(lj fm-scratch git_head)" "${HEAD_SHA}"
expect ${C} "fm-scratch's work" "$(lj fm-scratch work)" "2026-01-01T00:01:00Z the last step: tests written"
expect ${C} "fm-scratch's reason" "$(lj fm-scratch reason)" appeared
expect ${C} "fm-scratch's resume" "$(lj fm-scratch resume)" "tmux new-session -d -s fm-scratch -c ${REPO} 'sleep 600'"
expect ${C} "fm-chat's command" "$(lj fm-chat command)" "claude --fm-chat-opt"
ALL=$("${SUP}" ledger) || fail "${C}: supervisor.sh ledger failed: ${ALL}"
expect ${C} "the sessions supervisor.sh ledger lists" "$(echo "${ALL}" | python3 -I -c 'import json, sys; print(" ".join(json.loads(l)["session"] for l in sys.stdin))')" "fm-alpha fm-chat fm-hub fm-scratch fm-sup"
expect ${C} "supervisor.sh ledger fm-scratch" "$("${SUP}" ledger fm-scratch)" "$(echo "${ALL}" | grep '"session": "fm-scratch"')"
OUT=$("${SUP}" ledger fm-nothing 2>&1) && fail "${C}: supervisor.sh ledger of a session with no line exited 0: ${OUT}"
expect ${C} "the ledger lines of fm-holder, a view of the harness's own" "$(lines fm-holder)" 0
# the ledger as it is now, for check 7
cp "${LEDGER}" "${D}/ledger-after-1.jsonl" || fail "could not copy the ledger"
INODE=$(stat -c %i "${LEDGER}")
echo "ok 1 [ledger-start-line] - the supervisor's start of fm-alpha (pane ${APID}), the hub found running and the scratch sessions fm-scratch (at ${HEAD_SHA:0:12}, its STATUS line) and fm-chat each have a start line with their resume command; supervisor.sh ledger lists the five sessions, one line each; the hub's line took no work from a status file older than its session"

# --- 2 [ledger-stop-line] ---
C=ledger-stop-line
tmux kill-session -t "=fm-scratch" || fail "could not end fm-scratch"
upto 20 has_line fm-scratch stop || fail "${C}: no stop line for fm-scratch within 20 s of its end"
expect ${C} "fm-scratch's reason" "$(lj fm-scratch reason)" "its session ended"
expect ${C} "fm-scratch's pane_pid" "$(lj fm-scratch pane_pid)" "${SPID}"
expect ${C} "fm-scratch's cwd" "$(lj fm-scratch cwd)" "${REPO}"
expect ${C} "fm-scratch's command" "$(lj fm-scratch command)" "sleep 600"
expect ${C} "fm-scratch's resume" "$(lj fm-scratch resume)" "tmux new-session -d -s fm-scratch -c ${REPO} 'sleep 600'"
# the stack's stop, as ./stop.sh does it: the supervisor's loop stops (the container's removal stops it), record-stop
# records every running session from its pane, then the sessions end
OUT=$("${SUP}" stop 2>&1) || fail "${C}: supervisor.sh stop: ${OUT}"
upto 10 grep -q "^cwd=${D}/wd/fm-alpha " "${FM_STUB_LOG}" || fail "${C}: fm-alpha's claude never ran"
upto 10 grep -q "^cwd=${D}/chat " "${FM_STUB_LOG}" || fail "${C}: fm-chat's claude never ran"
ASID=$(grep "^cwd=${D}/wd/fm-alpha " "${FM_STUB_LOG}" | tail -1 | sed -n 's/.* sid=//p')
CSID=$(grep "^cwd=${D}/chat " "${FM_STUB_LOG}" | tail -1 | sed -n 's/.* sid=//p')
OUT=$("${SUP}" record-stop 2>&1) || fail "${C}: supervisor.sh record-stop: ${OUT}"
for S in fm-hub fm-sup fm-alpha fm-chat; do
	expect ${C} "${S}'s event after record-stop" "$(lj "${S}" event)" stop
	expect ${C} "${S}'s reason after record-stop" "$(lj "${S}" reason)" "the stack is stopping (supervisor.sh record-stop)"
done
expect ${C} "fm-alpha's claude_session" "$(lj fm-alpha claude_session)" "${ASID}"
expect ${C} "fm-alpha's resume" "$(lj fm-alpha resume)" "AGENT_TMUX_CLAUDE_OPTS='--fm-opt --resume ${ASID}' ${AGENT_DIR}/tmux-session-start.sh fm-alpha"
expect ${C} "fm-chat's claude_session" "$(lj fm-chat claude_session)" "${CSID}"
expect ${C} "fm-chat's resume" "$(lj fm-chat resume)" "tmux new-session -d -s fm-chat -c ${D}/chat 'claude --fm-chat-opt --resume ${CSID}'"
HSID=$(lj fm-hub claude_session)
[ -n "${HSID}" ] || fail "${C}: the hub's stop line has no Claude Code session"
for S in fm-hub fm-sup fm-alpha fm-chat; do tmux kill-session -t "=${S}" || fail "could not end ${S}"; done
echo "ok 2 [ledger-stop-line] - fm-scratch's end got its stop line; record-stop gave the hub, fm-sup, fm-alpha and fm-chat a stop line each, with fm-alpha's and fm-chat's Claude Code sessions in their resume commands"

# --- 3 [resume-registry] ---
C=resume-registry
OUT=$("${SUP}" resume fm-alpha 2>&1) || fail "${C}: supervisor.sh resume fm-alpha: ${OUT}"
read -r APID2 ACREATED2 <<< "$(pane fm-alpha)"
[ -n "${APID2}" ] || fail "${C}: fm-alpha is not running after its resume: ${OUT}"
upto 10 grep -q "^cwd=${D}/wd/fm-alpha args=--fm-opt --resume ${ASID} " "${FM_STUB_LOG}" \
	|| fail "${C}: fm-alpha's claude did not start with its options and --resume ${ASID}: $(tail -2 "${FM_STUB_LOG}")"
expect ${C} "fm-alpha's event" "$(lj fm-alpha event)" resume
expect ${C} "fm-alpha's pane_pid" "$(lj fm-alpha pane_pid)" "${APID2}"
expect ${C} "fm-alpha's created" "$(lj fm-alpha created)" "${ACREATED2}"
expect ${C} "fm-alpha's claude_session" "$(lj fm-alpha claude_session)" "${ASID}"
case "$(lj fm-alpha reason)" in "supervisor.sh resume, from its stop line of "*) ;; *) fail "${C}: fm-alpha's resume line's reason is '$(lj fm-alpha reason)'" ;; esac
OUT=$("${SUP}" resume fm-hub 2>&1) || fail "${C}: supervisor.sh resume fm-hub: ${OUT}"
running fm-hub || fail "${C}: the hub is not running after its resume: ${OUT}"
upto 10 grep -qF "args=--fm-opt --resume ${HSID} " "${FM_STUB_LOG}" || fail "${C}: the hub's claude did not start with --resume ${HSID}"
expect ${C} "the hub's event" "$(lj fm-hub event)" resume
expect ${C} "the hub's claude_session" "$(lj fm-hub claude_session)" "${HSID}"
N=$(lines fm-alpha)
OUT=$("${SUP}" resume fm-alpha 2>&1) && fail "${C}: a resume of the running fm-alpha was not refused: ${OUT}"
case "${OUT}" in *"fm-alpha is running"*) ;; *) fail "${C}: the refusal does not say that fm-alpha runs: ${OUT}" ;; esac
expect ${C} "fm-alpha's line count after the refused resume" "$(lines fm-alpha)" "${N}"
echo "ok 3 [resume-registry] - fm-alpha came back through its registry start with --fm-opt --resume ${ASID}, and the hub with its own session, each with a resume line; a resume of the running fm-alpha was refused and appended nothing"

# --- 4 [resume-scratch] ---
C=resume-scratch
OUT=$("${SUP}" resume fm-scratch 2>&1) || fail "${C}: supervisor.sh resume fm-scratch: ${OUT}"
read -r SPID2 _ <<< "$(pane fm-scratch)"
[ -n "${SPID2}" ] || fail "${C}: fm-scratch is not running after its resume: ${OUT}"
P=$(tmux list-panes -t "=fm-scratch:" -F '#{pane_current_path}|#{pane_start_command}' 2>/dev/null | head -1)
case "${P}" in "${REPO}|"*"sleep 600"*) ;; *) fail "${C}: fm-scratch's pane is '${P}', not sleep 600 in ${REPO}" ;; esac
expect ${C} "fm-scratch's event" "$(lj fm-scratch event)" resume
expect ${C} "fm-scratch's pane_pid" "$(lj fm-scratch pane_pid)" "${SPID2}"
expect ${C} "fm-scratch's command" "$(lj fm-scratch command)" "sleep 600"
# the registry has since gained a session of fm-chat's name (its flag off): fm-chat comes back as the scratch session its
# line records, and its resume line says so
python3 -I - "${SPOKES_REGISTRY}" "${D}/registry-gained.json" << 'EOF' || fail "could not write a registry that has gained fm-chat"
import json, sys
d = json.load(open(sys.argv[1]))
d["sessions"].append(dict(next(e for e in d["sessions"] if e["session_name"] == "fm-beta"), session_name="fm-chat", flag="SPOKE_FM_CHAT"))
json.dump(d, open(sys.argv[2], "w"), indent=1)
EOF
OUT=$(SPOKES_REGISTRY=${D}/registry-gained.json "${SUP}" resume fm-chat 2>&1) || fail "${C}: supervisor.sh resume fm-chat: ${OUT}"
upto 10 grep -q "^cwd=${D}/chat args=--fm-chat-opt --resume ${CSID} " "${FM_STUB_LOG}" \
	|| fail "${C}: fm-chat's claude did not start with --fm-chat-opt --resume ${CSID} in ${D}/chat: $(tail -2 "${FM_STUB_LOG}")"
expect ${C} "fm-chat's event" "$(lj fm-chat event)" resume
expect ${C} "fm-chat's command" "$(lj fm-chat command)" "claude --fm-chat-opt --resume ${CSID}"
expect ${C} "fm-chat's claude_session" "$(lj fm-chat claude_session)" "${CSID}"
expect ${C} "fm-chat's agent, the registry having gained its name" "$(lj fm-chat agent)" scratch
expect ${C} "fm-chat's resume, the registry having gained its name" "$(lj fm-chat resume)" "tmux new-session -d -s fm-chat -c ${D}/chat 'claude --fm-chat-opt --resume ${CSID}'"
N=$(lines fm-scratch)
OUT=$("${SUP}" resume fm-scratch 2>&1) && fail "${C}: a resume of the running fm-scratch was not refused: ${OUT}"
expect ${C} "fm-scratch's line count after the refused resume" "$(lines fm-scratch)" "${N}"
echo "ok 4 [resume-scratch] - fm-scratch came back in ${REPO} running sleep 600, fm-chat with claude --fm-chat-opt --resume ${CSID} as the scratch session its line records though the registry had gained its name, each with a resume line; a resume of the running fm-scratch was refused"

# --- 4b [resume-options] ---
C=resume-options
python3 -I - "${LEDGER_TOOL}" << 'EOF' || fail "${C}: the resume's option words are not the ones expected"
import importlib.util, os, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
U = "0123abcd-0000-4000-8000-0123456789ab"
got = m.other_conversation_out(["--fm-opt", "--continue", "-c", "--resume", U, "-r", U, "--resume=" + U, "--session-id", U,
                                "--session-id=" + U, "--model", "x", "--fork-session"])
assert got == ["--fm-opt", "--model", "x", "--fork-session"], got
for opts, want in ((f"--foo-r {U}", None), (f"--fm-opt -r {U}", U), (f"--resume={U}", U), (f"--resume {U} --x", U),
                   (f"-r{U}", None)):
    os.environ["AGENT_TMUX_CLAUDE_OPTS"] = opts
    assert m.opts_session() == want, (opts, m.opts_session())
EOF
echo "ok 4b [resume-options] - a resume drops --continue, -c, --resume/-r and its id and --session-id and its value, and keeps every other word; a session id is read from the options only after --resume or -r as words of their own"

# --- 5 [close-exited] ---
C=close-exited
tmux new-session -d -s fm-exited -c "${REPO}" "echo ${MARK}; sleep 2; exit 3" \; set-option -w -t "=fm-exited:" remain-on-exit on \
	|| fail "could not plant fm-exited"
# fm-beta's process exits a second after fm-exited's, whose status the checks read: tmux 3.2a at times gives no exit
# status to a process that exits while tmux is busy, as with another pane's exit at the same moment
tmux new-session -d -s fm-beta -c "${D}/wd/fm-beta" "sleep 3; exit 4" \; set-option -w -t "=fm-beta:" remain-on-exit on \
	|| fail "could not plant fm-beta"
tmux new-session -d -s fm-live -c "${REPO}" "sleep 600" || fail "could not plant fm-live"
upto 10 pane_exited fm-exited || fail "${C}: fm-exited's process did not exit"
upto 10 pane_exited fm-beta || fail "${C}: fm-beta's process did not exit"
tmux capture-pane -p -J -S - -E - -t "=fm-exited:" | grep -q "^${MARK} *$" || fail "${C}: fm-exited's exited pane does not keep what it printed"
OUT=$("${SUP}" start 2>&1) || fail "${C}: supervisor.sh start: ${OUT}"
upto 30 has_line fm-exited closed-exited || fail "${C}: no closed-exited line for fm-exited within 30 s: $(tail -2 "${LEDGER}")"
gone fm-exited || fail "${C}: fm-exited has a closed-exited line and still runs"
expect ${C} "fm-exited's closed-exited lines" "$(lines fm-exited closed-exited)" 1
R=$(lj fm-exited reason)
KEPT=$(lj fm-exited output)
python3 -I -c 'import re, sys
m = re.fullmatch(r"every pane.s process had exited \(exit status 3\) at passes (\d+) and (\d+); the supervisor kept its panes. output in (\S+) and closed the session", sys.argv[1])
sys.exit(0 if m and int(m.group(2)) == int(m.group(1)) + 1 and m.group(3) == sys.argv[2] else 1)' "${R}" "${KEPT}" \
	|| fail "${C}: fm-exited's closed-exited line does not name two passes in a row and the file that keeps its output: '${R}'"
case "${KEPT}" in "${SUPERVISOR_DIR}/closed/fm-exited."*.txt) ;; *) fail "${C}: fm-exited's output is not kept under ${SUPERVISOR_DIR}/closed/: '${KEPT}'" ;; esac
grep -qx "${MARK}" "${KEPT}" 2> /dev/null || fail "${C}: the output fm-exited printed is not in the file its closed-exited line names (${KEPT})"
HLIMIT=$(tmux show-options -gv history-limit 2> /dev/null)
[ -n "${HLIMIT}" ] || fail "${C}: could not read the server's history-limit"
grep -q "^=== %[0-9]*: its process exited with status 3; its history held [0-9]* lines (history-limit ${HLIMIT}); its command: echo ${MARK}; sleep 2; exit 3$" "${KEPT}" \
	|| fail "${C}: the kept output has no header line naming the pane, its status, its history with its history-limit and its command: $(head -1 "${KEPT}")"
lj fm-exited output_tail | grep -qx "${MARK}" || fail "${C}: fm-exited's closed-exited line does not carry the end of its output"
expect ${C} "fm-exited's agent" "$(lj fm-exited agent)" scratch
expect ${C} "fm-exited's resume" "$(lj fm-exited resume)" "tmux new-session -d -s fm-exited -c ${REPO} 'echo ${MARK}; sleep 2; exit 3'"
NOTICES=$(python3 -I -c 'import json, sys
n = 0
try:
    for l in open(sys.argv[1]):
        t = str(json.loads(l).get("env", {}).get("text"))
        n += "closed the scratch session fm-exited" in t and sys.argv[2] in t
except OSError:
    pass
print(n)' "${MAILBOX_PROJECTION_ROOT}/fm-hub/inbox.jsonl" "${KEPT}")
expect ${C} "the hub's notices of fm-exited's close that name its kept output" "${NOTICES}" 1
NP=$(( $(passes) + 3 ))
upto 20 passes_from "${NP}" || fail "${C}: the supervisor did not run three more passes"
for S in fm-live fm-beta fm-hub fm-alpha; do
	running "${S}" || fail "${C}: ${S} was closed"
	expect ${C} "${S}'s closed-exited lines" "$(lines "${S}" closed-exited)" 0
done
pane_exited fm-beta || fail "${C}: fm-beta's pane is not the exited one planted"
echo "ok 5 [close-exited] - fm-exited was closed at the second pass in a row that saw it exited ('${R}'), what it printed kept in ${KEPT}, with one notice to the hub naming it; fm-live, the registry's fm-beta with its exited pane, the hub and fm-alpha stayed three passes later"

# --- 5b [close-keeps-output] ---
C=close-keeps-output
# the directory of the copies a plain file, so no copy can be written there
mv "${SUPERVISOR_DIR:?}/closed" "${D:?}/closed-moved" || fail "could not move ${SUPERVISOR_DIR}/closed"
: > "${SUPERVISOR_DIR}/closed" || fail "could not plant a file at ${SUPERVISOR_DIR}/closed"
tmux new-session -d -s fm-keep -c "${REPO}" "echo ${MARK}-b; sleep 1; exit 6" \; set-option -w -t "=fm-keep:" remain-on-exit on \
	|| fail "could not plant fm-keep"
upto 10 pane_exited fm-keep || fail "${C}: fm-keep's process did not exit"
NP=$(( $(passes) + 4 ))
upto 30 passes_from "${NP}" || fail "${C}: the supervisor did not run four passes"
running fm-keep || fail "${C}: fm-keep was closed though its output could not be kept"
expect ${C} "fm-keep's closed-exited lines" "$(lines fm-keep closed-exited)" 0
expect ${C} "the supervisor's lines saying fm-keep's output could not be kept" "$(grep -c "close: the output of fm-keep could not be kept in " "${SUPERVISOR_DIR}/supervisor.log")" 1
rm -f "${SUPERVISOR_DIR:?}/closed" && mv "${D:?}/closed-moved" "${SUPERVISOR_DIR:?}/closed" || fail "could not put ${SUPERVISOR_DIR}/closed back"
upto 30 has_line fm-keep closed-exited || fail "CONTROL: ${C}: with the directory back, the supervisor did not close fm-keep"
grep -qx "${MARK}-b" "$(lj fm-keep output)" 2> /dev/null || fail "CONTROL: ${C}: fm-keep's output is not in $(lj fm-keep output)"
echo "ok 5b [close-keeps-output] - with no place to copy its output fm-keep stayed open four passes, no closed-exited line, one line saying why (control: with the directory back it was closed, its output kept)"

# --- 5c [census-read-fails] ---
C=census-read-fails
N0=$(wc -l < "${LEDGER}")
: > "${D}/tmux-read-fails" || fail "could not plant the failing read"
NP=$(( $(passes) + 4 ))
upto 30 passes_from "${NP}" || fail "${C}: the supervisor did not run four passes"
expect ${C} "the ledger's lines after four passes whose reads of the server failed" "$(wc -l < "${LEDGER}")" "${N0}"
for S in fm-hub fm-sup fm-alpha fm-live fm-beta; do
	running "${S}" || fail "${C}: ${S} was closed while the reads failed"
done
expect ${C} "the supervisor's lines about the failed read" "$(grep -c "ledger: the tmux server could not be read (planted read failure); no census and no close until it can" "${SUPERVISOR_DIR}/supervisor.log")" 1
OUT=$("${SUP}" record-stop 2>&1) && fail "${C}: supervisor.sh record-stop exited 0 while the reads failed: ${OUT}"
expect ${C} "the ledger's lines after a record-stop whose read failed" "$(wc -l < "${LEDGER}")" "${N0}"
rm -f "${D:?}/tmux-read-fails"
NP=$(( $(passes) + 3 ))
upto 30 passes_from "${NP}" || fail "${C}: the supervisor did not run three more passes"
expect ${C} "the ledger's lines once the server could be read again" "$(wc -l < "${LEDGER}")" "${N0}"
grep -q "ledger: the tmux server can be read again" "${SUPERVISOR_DIR}/supervisor.log" || fail "${C}: the supervisor did not say it can read the server again"
echo "ok 5c [census-read-fails] - four passes whose reads of the server failed wrote no line and closed nothing, with one line saying so; record-stop failed and wrote nothing; read again, the sessions' lines still held"

# --- 5d [census-no-server] ---
C=census-no-server
N0=$(wc -l < "${LEDGER}")
# no socket at all, where no server has run
mkdir -p "${D}/no-server" || fail "could not create ${D}/no-server"
W=$(TMUX_TMPDIR=${D}/no-server tmux list-sessions 2>&1)
case "${W}" in *"error connecting to"*"(No such file or directory)"*) ;; *) fail "${C}: a directory with no socket does not read as no server: ${W}" ;; esac
OUT=$(TMUX_TMPDIR=${D}/no-server "${SUP}" record-stop 2>&1) || fail "${C}: with no tmux server supervisor.sh record-stop failed: ${OUT}"
expect ${C} "the ledger's lines after a record-stop with no tmux server" "$(wc -l < "${LEDGER}")" "${N0}"
# a socket no server listens on, as a server that stopped can leave
mkdir -p -m 700 "${D}/stale-server/tmux-$(id -u)" || fail "could not create ${D}/stale-server"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${D}/stale-server/tmux-$(id -u)/default" \
	|| fail "could not plant a socket no server listens on"
W=$(TMUX_TMPDIR=${D}/stale-server tmux list-sessions 2>&1)
case "${W}" in *"no server running"*) ;; *) fail "${C}: the planted socket does not read as no server: ${W}" ;; esac
OUT=$(TMUX_TMPDIR=${D}/stale-server "${SUP}" record-stop 2>&1) || fail "${C}: with a socket no server listens on supervisor.sh record-stop failed: ${OUT}"
expect ${C} "the ledger's lines after a record-stop with a socket no server listens on" "$(wc -l < "${LEDGER}")" "${N0}"
echo "ok 5d [census-no-server] - with no tmux server (no socket, and a socket no server listens on) record-stop exited 0 and wrote no line: no server is no session, not a failed read"

# --- 5e [kept-header] ---
C=kept-header
# planted with the supervisor stopped, one pane at a time: tmux 3.2a at times gives no exit status to a process that
# exits while tmux is busy (another pane's exit, or reads such as the supervisor's own), and fm-long's must be its 0
OUT=$("${SUP}" stop 2>&1) || fail "${C}: supervisor.sh stop: ${OUT}"
# a pane that prints more than its history-limit (20, set for the pane's making, the one time tmux reads it) and exits 0
tmux set-option -g history-limit 20 \; new-session -d -s fm-long -c "${REPO}" "seq 1 200; sleep 1; exit 0" \; set-option -w -t "=fm-long:" remain-on-exit on \; set-option -g history-limit "${HLIMIT}" \
	|| fail "could not plant fm-long"
upto 10 pane_exited fm-long || fail "${C}: fm-long's process did not exit"
upto 5 status_is fm-long 0 || fail "${C}: tmux gives fm-long, which exited 0, the exit status '$(tmux list-panes -t "=fm-long:" -F '#{pane_dead_status}')'"
# a process a signal ends: tmux gives no exit status for it
tmux new-session -d -s fm-signal -c "${REPO}" "sleep 1; exec python3 -c 'import signal; signal.raise_signal(signal.SIGTERM)'" \; set-option -w -t "=fm-signal:" remain-on-exit on \
	|| fail "could not plant fm-signal"
upto 10 pane_exited fm-signal || fail "${C}: fm-signal's process did not exit"
sleep 1
status_is fm-signal "" || fail "${C}: tmux gives fm-signal, which a signal ended, the exit status '$(tmux list-panes -t "=fm-signal:" -F '#{pane_dead_status}')'"
OUT=$("${SUP}" start 2>&1) || fail "${C}: supervisor.sh start: ${OUT}"
upto 30 has_line fm-signal closed-exited || fail "${C}: no closed-exited line for fm-signal within 30 s"
upto 30 has_line fm-long closed-exited || fail "${C}: no closed-exited line for fm-long within 30 s"
SK=$(lj fm-signal output)
grep -q "^=== %[0-9]*: its process exited with status -; its history held [0-9]* lines (history-limit ${HLIMIT}); its command: sleep 1; exec python3 -c " "${SK}" 2> /dev/null \
	|| fail "${C}: fm-signal's header does not give '-' for the status tmux does not give, its history with its limit and its command: $(head -1 "${SK}" 2>&1)"
case "$(lj fm-signal reason)" in *"(exit status -)"*) ;; *) fail "${C}: fm-signal's closed-exited reason does not give '-': $(lj fm-signal reason)" ;; esac
LK=$(lj fm-long output)
grep -q "^=== %[0-9]*: its process exited with status 0; its history held [0-9]* lines (history-limit 20: its earliest lines may be gone); its command: seq 1 200; sleep 1; exit 0$" "${LK}" 2> /dev/null \
	|| fail "${C}: fm-long's header does not give status 0, its history, the limit 20 and that its earliest lines may be gone: $(head -1 "${LK}" 2>&1)"
grep -qx 200 "${LK}" || fail "${C}: fm-long's last printed line is not kept"
grep -qx 1 "${LK}" && fail "${C}: fm-long's first printed line is kept: its history-limit of 20 did not hold"
grep -q "its earliest lines may be gone" "$(lj fm-exited output)" && fail "${C}: fm-exited's header, a pane with no history, says its earliest lines may be gone"
echo "ok 5e [kept-header] - fm-signal's header gives '-' for the exit status tmux does not give; fm-long, which printed 200 lines with a history-limit of 20, kept its last lines with status 0 and a header saying its earliest lines may be gone; fm-exited's says no such thing"

# --- 5f [close-rereads] ---
C=close-rereads
# the close's read again of fm-reread's panes fails once; that of fm-respawn's is followed at once by a new start of its pane
: > "${D}/reread-fails.fm-reread" && : > "${D}/respawn-after-reread.fm-respawn" || fail "could not plant the read-again flags"
tmux new-session -d -s fm-reread -c "${REPO}" "sleep 1; exit 8" \; set-option -w -t "=fm-reread:" remain-on-exit on || fail "could not plant fm-reread"
upto 10 pane_exited fm-reread || fail "${C}: fm-reread's process did not exit"
tmux new-session -d -s fm-respawn -c "${REPO}" "sleep 1; exit 9" \; set-option -w -t "=fm-respawn:" remain-on-exit on || fail "could not plant fm-respawn"
upto 10 pane_exited fm-respawn || fail "${C}: fm-respawn's process did not exit"
upto 30 test -e "${D}/reread-failed.fm-reread" || fail "${C}: the close never read fm-reread's panes again"
NP=$(( $(passes) + 1 ))
upto 20 passes_from "${NP}" || fail "${C}: the supervisor did not finish its pass"
running fm-reread || fail "${C}: fm-reread was closed at the pass whose read again of its panes failed"
expect ${C} "fm-reread's closed-exited lines after the pass whose read again failed" "$(lines fm-reread closed-exited)" 0
upto 30 has_line fm-reread closed-exited || fail "CONTROL: ${C}: read again at a later pass, fm-reread was not closed"
upto 30 test -e "${D}/respawned.fm-respawn" || fail "${C}: the close never read fm-respawn's panes again"
NP=$(( $(passes) + 2 ))
upto 20 passes_from "${NP}" || fail "${C}: the supervisor did not run two more passes"
running fm-respawn || fail "${C}: fm-respawn, whose pane runs again, was closed"
pane_exited fm-respawn && fail "${C}: fm-respawn's pane is not running again"
expect ${C} "fm-respawn's closed-exited lines" "$(lines fm-respawn closed-exited)" 0
ls "${SUPERVISOR_DIR}"/closed/fm-respawn.* > /dev/null 2>&1 && fail "${C}: fm-respawn's output was copied though its pane runs: $(ls "${SUPERVISOR_DIR}"/closed/fm-respawn.*)"
echo "ok 5f [close-rereads] - the pass whose read again of fm-reread's panes failed closed nothing (control: a later pass closed it); fm-respawn, whose pane ran again right after that read, was neither copied nor closed and still runs"

# --- 6 [close-off] ---
C=close-off
RAN=$(lines_of fm-hub fm-sup fm-alpha fm-live fm-beta)
OUT=$("${SUP}" stop 2>&1) || fail "${C}: supervisor.sh stop: ${OUT}"
tmux new-session -d -s fm-exited2 -c "${REPO}" "sleep 1; exit 5" \; set-option -w -t "=fm-exited2:" remain-on-exit on \
	|| fail "could not plant fm-exited2"
upto 10 pane_exited fm-exited2 || fail "${C}: fm-exited2's process did not exit"
OUT=$(SUPERVISOR_CLOSE_EXITED=false "${SUP}" start 2>&1) || fail "${C}: supervisor.sh start with SUPERVISOR_CLOSE_EXITED=false: ${OUT}"
NP=$(( $(passes) + 5 ))
upto 30 passes_from "${NP}" || fail "${C}: the supervisor did not run five passes"
running fm-exited2 || fail "${C}: with SUPERVISOR_CLOSE_EXITED=false the supervisor closed fm-exited2"
expect ${C} "fm-exited2's closed-exited lines with the close off" "$(lines fm-exited2 closed-exited)" 0
expect ${C} "the lines of the sessions that ran through the supervisor's stop and start" "$(lines_of fm-hub fm-sup fm-alpha fm-live fm-beta)" "${RAN}"
OUT=$("${SUP}" stop 2>&1) || fail "${C}: supervisor.sh stop: ${OUT}"
OUT=$("${SUP}" start 2>&1) || fail "${C}: supervisor.sh start: ${OUT}"
upto 30 has_line fm-exited2 closed-exited || fail "CONTROL: ${C}: started again with the close on, the supervisor did not close fm-exited2"
gone fm-exited2 || fail "CONTROL: ${C}: fm-exited2 has a closed-exited line and still runs"
echo "ok 6 [close-off] - with SUPERVISOR_CLOSE_EXITED=false fm-exited2 stayed five passes with no closed-exited line, and the supervisor's stop and start added no line for the sessions that ran (control: with the close on it was closed)"

# --- 7 [append-only] ---
C=append-only
OUT=$("${SUP}" stop 2>&1) || fail "${C}: supervisor.sh stop: ${OUT}"
is_prefix "${D}/ledger-after-1.jsonl" "${LEDGER}" || fail "${C}: the ledger as it was after check 1 is not where the ledger begins now"
expect ${C} "the ledger's inode" "$(stat -c %i "${LEDGER}")" "${INODE}"
cp "${LEDGER}" "${D}/ledger-before-7.jsonl" || fail "could not copy the ledger"
B=$(wc -l < "${LEDGER}")
seq 1 20 | xargs -P 20 -I{} python3 -I "${LEDGER_TOOL}" record start fm-par-{} --pane-pid {} --cwd "${D}" --command "par {}" --reason parallel \
	|| fail "${C}: a writer of the twenty failed"
expect ${C} "the ledger's lines after twenty writers" "$(wc -l < "${LEDGER}")" "$(( B + 20 ))"
is_prefix "${D}/ledger-before-7.jsonl" "${LEDGER}" || fail "${C}: the twenty writers did not only append"
python3 -I - "${LEDGER}" << 'EOF' || fail "${C}: a ledger line is not a whole line of the ledger's form"
import json, sys
keys = {"ts", "event", "session", "agent", "pane_pid", "created", "cwd", "command", "git_head", "work", "claude_session",
        "resume", "reason", "output", "output_tail"}
par = set()
for n, l in enumerate(open(sys.argv[1]), 1):
    r = json.loads(l)
    if not isinstance(r, dict) or set(r) != keys or r["event"] not in ("start", "stop", "resume", "closed-exited"):
        sys.exit(f"line {n}: {l.strip()[:200]}")
    if r["session"].startswith("fm-par-"):
        par.add(r["session"])
if par != {f"fm-par-{i}" for i in range(1, 21)}:
    sys.exit(f"the twenty writers' sessions: {sorted(par)}")
EOF
# PLANTED CONTROL: a copy of the writer whose one write opens the file to replace it
mkdir -p "${D}/planted/sup"
cp "${LEDGER}" "${D}/planted/sup/sessions-ledger.jsonl"
python3 -I - "${LEDGER_TOOL}" "${D}/planted/session-ledger.py" << 'EOF' || fail "could not plant the rewriting writer"
import sys
s = open(sys.argv[1]).read()
old = "os.O_WRONLY | os.O_APPEND | os.O_CREAT"
if s.count(old) != 1:
    sys.exit("the writer's open is not the one expected")
open(sys.argv[2], "w").write(s.replace(old, "os.O_WRONLY | os.O_TRUNC | os.O_CREAT"))
EOF
SUPERVISOR_DIR=${D}/planted/sup python3 -I "${D}/planted/session-ledger.py" record start fm-planted --pane-pid 1 --cwd "${D}" \
	--command x --reason planted || fail "PLANTED CONTROL: the rewriting writer failed"
is_prefix "${LEDGER}" "${D}/planted/sup/sessions-ledger.jsonl" && fail "PLANTED CONTROL: a writer that rewrites the ledger passed the prefix check"
echo "ok 7 [append-only] - the ledger after check 1 begins the ledger now, same inode; twenty writers at once added twenty whole lines; every line has the line's keys and one of the four events (planted control: a rewriting writer fails the prefix check)"

# --- 8. nothing under /wd ---
if [ "${TEST_CONTAINER}" == "true" ]; then
	wd_new() { find /wd -mindepth 1 2>/dev/null | sort | comm -13 "${D}/wd-before.txt" -; }
	NEW=$(wd_new)
	[ -z "${NEW}" ] || fail "this test wrote $(echo "${NEW}" | wc -l) entries under /wd: $(echo "${NEW}" | head -5 | tr '\n' ' ')"
	touch /wd/.test-fleet-manager-planted || fail "PLANTED CONTROL: could not plant an entry under /wd"
	NEW=$(wd_new)
	rm -f /wd/.test-fleet-manager-planted
	[ "${NEW}" == "/wd/.test-fleet-manager-planted" ] || fail "PLANTED CONTROL: the entry planted under /wd is not the one new entry named: '${NEW}'"
	echo "ok 8 - nothing under /wd that was not there when the test started (control: an entry planted there is named)"
fi
echo "Test-fleet-manager succeeded"
