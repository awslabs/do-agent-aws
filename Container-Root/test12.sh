#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the shared agent tmux session contract (/agent/tmux-session-start.sh,
# /agent/tmux-claude.sh, the startup.sh hook, and the .bashrc auto-attach appended by
# /setup/install-bashrc.sh): both doors - the browser /tmux/ terminal and a
# docker exec / ./exec.sh shell - land in the SAME tmux session with the interactive claude
# CLI running in it (docs/manual/ui.md "tmux in the browser"). Fully OFFLINE: no port is bound and
# no prompt is ever submitted to claude. Each check FAILS if the property it proves is removed:
#   1. all new/changed scripts parse (bash -n)
#   2. EAGER creation: after tmux-session-start.sh - with NO client ever connected -
#      `tmux ls` lists the session (the exact thing missing before: ttyd -A only created
#      the session on the first browser connect, so `docker exec` + `tmux ls` found
#      "no server running")
#   3. the session's pane runs claude, not a bare shell (asserted on the pane's live child
#      process, never on scraped text)
#   4. PLANTED CONTROL: AGENT_TMUX_CLAUDE=false -> the pane runs a shell with NO claude
#      under it (proves check 3's assert exercises the real process tree and can go red)
#   5. idempotent: re-running tmux-session-start.sh keeps the same session id and creates
#      no second session
#   6. an interactive pty shell sourcing the shipped .bashrc ATTACHES to the session
#      (asserted on the tmux client count, before/after), and a re-run of
#      tmux-session-start.sh UNDER that attachment disturbs neither the session id nor
#      the client
#   7. PLANTED CONTROL: TMUX_AUTO_ATTACH=false -> the same pty shell adds NO client and is
#      a usable plain shell (the documented escape hatch, and the proof check 6 can go red)
#   8. a NON-interactive command adds no client and returns its own output - the
#      `docker exec <container> <command>` scripted path is untouched
# The default session ("agent") is left in place afterwards - that is the shipped state of
# a running container (test9's writable-terminal probe runs against its own test-local
# session and leaves this one alone). The control session uses a test-local name.

D=/tmp/tmux-parity-smoke
rm -rf "${D:?}"
mkdir -p ${D}

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
SETUP_DIR="${BASE_DIR%/}/setup"
S=${AGENT_TMUX_SESSION_NAME:-agent}
S_CTRL=tmux-parity-noclaude

cleanup()
{
	tmux kill-session -t "=${S_CTRL}" 2>/dev/null
	rm -rf "${D:?}"
}

fail()
{
	echo "Test12 FAILED: $1"
	cleanup
	exit 1
}

# --- 1. syntax ---
for F in "${AGENT_DIR}/tmux-session-start.sh" "${AGENT_DIR}/tmux-claude.sh" \
         "${AGENT_DIR}/ui-start.sh" "${SETUP_DIR}/install-bashrc.sh" "${BASE_DIR%/}/startup.sh"; do
	bash -n "${F}" || fail "bash -n ${F}"
done
echo "ok 1 - syntax"

# --- preflight: tmux installed (setup/install-tmux.sh) ---
if ! command -v tmux > /dev/null; then
	echo "Test12 skipped: tmux not installed (run setup/install-tmux.sh)"
	exit 0
fi

# claude in the pane needs the claude CLI; without it (a bare repo checkout) the
# claude-side checks are skipped rather than failed - the session contract still holds
CLAUDE_PRESENT=true
[ -x /usr/local/bin/claude ] || command -v claude > /dev/null || CLAUDE_PRESENT=false

# The pane's live process tree: the claude BINARY must be running as a descendant of the
# pane (children AND grandchildren: tmux may wrap the pane command in a default-shell
# layer, making claude a grandchild). The match is anchored to an argv TOKEN ending in
# "claude", so the wrapper's own script path (/agent/tmux-claude.sh) can never satisfy it -
# this can go red, and check 4 proves it does. The matched argv is left in MATCHED_ARGS.
pane_runs_claude()
{
	MATCHED_ARGS=""
	PANE_PID=$(tmux list-panes -t "=$1" -F '#{pane_pid}' 2>/dev/null | head -1)
	[ -n "${PANE_PID}" ] || return 1
	PIDS=$(ps -o pid= --ppid "${PANE_PID}" 2>/dev/null | tr -d ' ')
	for K in ${PIDS}; do
		PIDS="${PIDS} $(ps -o pid= --ppid "${K}" 2>/dev/null | tr -d ' ')"
	done
	[ -n "$(echo ${PIDS} | tr -d ' ')" ] || return 1
	MATCHED_ARGS=$(ps -o args= -p ${PIDS} 2>/dev/null | grep -E '(^| )([^ ]*/)?claude( |$)' | head -1)
	[ -n "${MATCHED_ARGS}" ]
}

# session_id <name> - by exact-name match over list-sessions: display-message's
# "-t =name" target resolves inconsistently across tmux lines (empty on 3.4)
session_id()
{
	tmux list-sessions -F '#{session_name} #{session_id}' 2>/dev/null | awk -v s="$1" '$1==s {print $2}'
}

# poll_pane <session> <want:0|1> - wait for the pane's claude child to appear (or for the
# wrapper to have exec'd into its shell), up to 30s; echoes nothing, returns the last state
poll_pane()
{
	for i in $(seq 1 30); do
		if [ "$2" == "1" ]; then pane_runs_claude "$1" && return 0
		else pane_runs_claude "$1" || return 0; fi
		sleep 1
	done
	[ "$2" == "1" ] && return 1 || return 0
}

# --- 2. eager creation, no client ever connected ---
PREEXISTING=false
tmux has-session -t "=${S}" 2>/dev/null && PREEXISTING=true
"${AGENT_DIR}/tmux-session-start.sh" || fail "tmux-session-start.sh errored"
tmux ls 2>/dev/null | grep -q "^${S}:" || fail "tmux ls does not list session '${S}' after tmux-session-start.sh"
if [ "${PREEXISTING}" == "false" ]; then
	[ -z "$(tmux list-clients -t "=${S}" 2>/dev/null)" ] \
		|| fail "freshly created session '${S}' already has a client (eager-creation check is vacuous)"
	echo "ok 2 - session '${S}' exists eagerly, before any client ever connected"
else
	echo "ok 2 - session '${S}' exists (pre-existing in this environment; eager-creation exercised by the control below)"
fi

# --- 3. the pane runs claude ---
# Quote characters in the OPTS environment value are always a threading bug (an eval-only
# quoting pattern leaking through a non-eval consumer): claude would receive them literally
# - as a prompt, not a flag. Catch it here regardless of how the value was delivered.
case "${AGENT_TMUX_CLAUDE_OPTS}" in
*\"*|*\'*)
	fail "AGENT_TMUX_CLAUDE_OPTS carries literal quote characters ('${AGENT_TMUX_CLAUDE_OPTS}') - the env threading is passing quotes through to claude"
	;;
esac
if [ "${CLAUDE_PRESENT}" == "true" ]; then
	poll_pane "${S}" 1 || fail "pane of '${S}' is not running claude (expected a live claude descendant of the pane program)"
	pane_runs_claude "${S}"
	echo "ok 3 - pane of '${S}' runs claude (live process: $(echo "${MATCHED_ARGS}" | cut -c1-60))"
	# with no options configured, nothing may trail the binary: a stray argument (e.g. a
	# literal "" from a quoting bug in the env threading) becomes an initial PROMPT that
	# claude submits on start - exactly what this test promises never happens
	if [ -z "${AGENT_TMUX_CLAUDE_OPTS}" ]; then
		TRAILING=$(echo "${MATCHED_ARGS}" | sed -E 's#^(.* )?([^ ]*/)?claude##' | tr -d ' ')
		[ -z "${TRAILING}" ] \
			|| fail "claude was launched with unexpected trailing arguments ('${MATCHED_ARGS}') while AGENT_TMUX_CLAUDE_OPTS is empty - a stray token would be submitted as a prompt"
	fi
else
	echo "ok 3 - (skipped: claude CLI not installed in this context)"
fi

# --- 4. planted control: AGENT_TMUX_CLAUDE=false -> shell pane, no claude child ---
tmux kill-session -t "=${S_CTRL}" 2>/dev/null
AGENT_TMUX_SESSION_NAME=${S_CTRL} AGENT_TMUX_CLAUDE=false "${AGENT_DIR}/tmux-session-start.sh" \
	|| fail "tmux-session-start.sh errored for the AGENT_TMUX_CLAUDE=false control"
tmux ls 2>/dev/null | grep -q "^${S_CTRL}:" || fail "control session '${S_CTRL}' was not created"
poll_pane "${S_CTRL}" 0 || fail "PLANTED CONTROL BROKEN: AGENT_TMUX_CLAUDE=false but the pane still runs claude"
pane_runs_claude "${S_CTRL}" && fail "PLANTED CONTROL BROKEN: claude child found under the AGENT_TMUX_CLAUDE=false pane"
echo "ok 4 - planted control: AGENT_TMUX_CLAUDE=false pane runs a shell, no claude under it"

# --- 5. idempotency: same session id, no second session, quiet re-run ---
SID1=$(session_id "${S}")
[ -n "${SID1}" ] || fail "could not read the session id of '${S}' (the idempotency check would be vacuous)"
"${AGENT_DIR}/tmux-session-start.sh" > ${D}/rerun.out || fail "tmux-session-start.sh errored on re-run"
grep -q "already exists" ${D}/rerun.out || fail "re-run did not report the existing session: $(cat ${D}/rerun.out)"
SID2=$(session_id "${S}")
[ "${SID1}" == "${SID2}" ] || fail "re-run changed the session id (${SID1} -> ${SID2})"
[ "$(tmux ls 2>/dev/null | grep -c "^${S}:")" == "1" ] || fail "re-run created a second '${S}' session"
echo "ok 5 - tmux-session-start.sh is idempotent (session id ${SID1} stable, one session)"

# --- 6+7+8. the exec-shell door: auto-attach, its escape hatch, and the scripted path ---
if ! grep -q "TMUX_AUTO_ATTACH" "${HOME}/.bashrc" 2>/dev/null; then
	echo "ok 6 - (skipped: shipped .bashrc auto-attach not installed in this context)"
	echo "ok 7 - (skipped: shipped .bashrc auto-attach not installed in this context)"
else
	# Interactive shells under a REAL pty, exactly like `docker exec -it ... bash`.
	# Asserted on the tmux client count, never on scraped text. The attach mode holds the
	# client open while tmux-session-start.sh re-runs, proving an attached client is not
	# disturbed; it then detaches (Ctrl-b d) and must get its shell back (the attach is not
	# exec'd). Nothing is ever typed into the attached pane itself.
	cat > ${D}/pty-shell.py << 'EOF'
import fcntl, os, pty, struct, subprocess, sys, termios, threading, time

MODE, SESSION = sys.argv[1], sys.argv[2]          # attach | noattach
START = sys.argv[3] if len(sys.argv) > 3 else ""

def clients():
    r = subprocess.run(["tmux", "list-clients", "-t", "=" + SESSION],
                       capture_output=True, text=True)
    return len([l for l in r.stdout.splitlines() if l.strip()])

def sid():
    # exact-name match over list-sessions: display-message's "-t =name" target
    # resolves inconsistently across tmux lines (empty on 3.4)
    r = subprocess.run(["tmux", "list-sessions", "-F",
                        "#{session_name} #{session_id}"], capture_output=True, text=True)
    for l in r.stdout.splitlines():
        parts = l.split()
        if len(parts) == 2 and parts[0] == SESSION:
            return parts[1]
    return ""

before = clients()
pid, fd = pty.fork()
if pid == 0:
    os.environ.pop("TMUX", None)
    os.environ.setdefault("TERM", "xterm-256color")
    if MODE == "noattach":
        os.environ["TMUX_AUTO_ATTACH"] = "false"
    os.execvp("bash", ["bash", "-i"])

# a real terminal size - tmux refuses zero-sized clients
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
buf = bytearray()
def reader():                                      # drain so the child never blocks on tty writes
    while True:
        try:
            d = os.read(fd, 4096)
        except OSError:
            return
        if not d:
            return
        buf.extend(d)
threading.Thread(target=reader, daemon=True).start()

def finish(rc):
    for _ in range(20):
        p, _st = os.waitpid(pid, os.WNOHANG)
        if p == pid:
            break
        time.sleep(0.5)
    else:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    print("T12 RESULT " + ("PASS" if rc == 0 else "FAIL"))
    sys.exit(rc)

if MODE == "attach":
    after = before
    for _ in range(60):
        after = clients()
        if after > before:
            break
        time.sleep(0.5)
    print("T12 CLIENTS before=%d after=%d" % (before, after))
    if after <= before:
        os.kill(pid, 9); finish(1)
    sid1 = sid()
    if not sid1:                                   # an empty id would make the assert vacuous
        os.kill(pid, 9); finish(1)
    if START:                                      # idempotency UNDER the live attachment
        subprocess.run([START], capture_output=True)
        time.sleep(1)
        sid2, held = sid(), clients()
        print("T12 UNDER-ATTACH sid=%s->%s clients=%d" % (sid1, sid2, held))
        if sid1 != sid2 or held != after:
            os.kill(pid, 9); finish(1)
    os.write(fd, b"\x02d")                         # Ctrl-b d: detach
    for _ in range(20):                            # only type again once REALLY detached -
        if clients() == before:                    # otherwise keystrokes would land in the pane
            break
        time.sleep(0.5)
    else:
        os.kill(pid, 9); finish(1)
    time.sleep(1)
    os.write(fd, b"exit\r")                        # the detached shell must be alive to take this
    finish(0)
else:
    time.sleep(4)                                  # give a would-be attach every chance to happen
    now = clients()
    os.write(fd, b"echo T12_PLAIN_$((6*7))\r")     # expansion proves a live shell EXECUTED it -
    deadline = time.time() + 10                    # the echoed raw input alone cannot match
    ok = False
    while time.time() < deadline:
        if b"T12_PLAIN_42" in bytes(buf):
            ok = True
            break
        time.sleep(0.5)
    os.write(fd, b"exit\r")
    print("T12 CLIENTS before=%d after=%d shell_usable=%s" % (before, now, ok))
    finish(0 if (now == before and ok) else 1)
EOF

	OUT=$(python3 ${D}/pty-shell.py attach "${S}" "${AGENT_DIR}/tmux-session-start.sh" 2>&1)
	echo "${OUT}" | grep -q "T12 RESULT PASS" \
		|| fail "interactive pty shell did not attach/detach cleanly: ${OUT}"
	echo "ok 6 - interactive pty shell attaches ($(echo "${OUT}" | grep 'T12 CLIENTS')); re-run under attachment leaves id+client alone ($(echo "${OUT}" | grep 'T12 UNDER-ATTACH'))"

	OUT=$(python3 ${D}/pty-shell.py noattach "${S}" 2>&1)
	echo "${OUT}" | grep -q "T12 RESULT PASS" \
		|| fail "PLANTED CONTROL BROKEN: TMUX_AUTO_ATTACH=false shell attached or was unusable: ${OUT}"
	echo "ok 7 - planted control: TMUX_AUTO_ATTACH=false adds no client and stays a usable plain shell"
fi

# --- 8. the scripted exec path is untouched ---
# Two shapes of `docker exec <container> <command>`: a plain non-interactive command, and
# the harder one - `bash -ic` (interactive flag, .bashrc IS sourced) WITHOUT a terminal,
# which only the [ -t 0 ] / [ -t 1 ] guards keep from trying to attach.
BEFORE=$(tmux list-clients -t "=${S}" 2>/dev/null | grep -c . )
GOT=$(bash -c 'echo tmux-parity-noninteractive-$((6*7))')
[ "${GOT}" == "tmux-parity-noninteractive-42" ] || fail "non-interactive command output hijacked: '${GOT}'"
GOT=$(bash -ic 'echo tmux-parity-bashic-$((6*7))' 2>/dev/null </dev/null)
echo "${GOT}" | grep -q "tmux-parity-bashic-42" || fail "bash -ic without a tty lost its own output: '${GOT}'"
AFTER=$(tmux list-clients -t "=${S}" 2>/dev/null | grep -c . )
[ "${BEFORE}" == "${AFTER}" ] || fail "scripted command changed the client count (${BEFORE} -> ${AFTER})"
echo "ok 8 - scripted commands (bash -c, tty-less bash -ic) return their output and add no client"

cleanup
echo "Test12 succeeded"
