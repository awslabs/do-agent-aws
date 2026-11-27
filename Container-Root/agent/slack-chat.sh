#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Slack chat responder - an always-on process that answers Slack messages as they arrive,
# independent of the autonomy loop and its interval.
#
# Started by startup.sh (via /agent/slack-chat-start.sh) when the chat gate is on:
# SLACK_CHAT_ENABLED=true, or auto (the .env default) or unset while SLACK_BOT_TOKEN and
# SLACK_CHANNELS are set - the shared decision in /agent/slack-gates.sh. Every poll interval it
# runs /agent/slack-watch.sh once (that script keeps its own lock and cursors) and then answers
# every unprocessed inbox line, oldest first, in the thread of the message it answers: a message in
# a thread (the line carries thread_ts) is answered in that thread, and a top-level message is
# answered in a thread under it - the thread where the topic continues, so the channel's top level
# stays the list of topics (SLACK_REPLY_IN_THREAD, the .env default true; false answers a top-level
# message top-level, where the person wrote - the behaviour until 2026-10-31). A reply therefore
# takes one poll interval plus, for a free-form question, one claude call; the loop's
# AUTONOMY_LOOP_INTERVAL plays no part.
#
# Who owns the inbox: while this process is on it is the ONLY consumer of ${SLACK_DIR}/inbox.jsonl.
# The loop (loop.sh, loop-once.sh) sees the chat gate on and neither runs the watch nor hands
# the inbox to its fires; it works on the goals file alone. This process moves each line it has
# handled to ${SLACK_DIR}/processed.jsonl right away (slack-watch.sh only appends, so the line
# just handled is always the first line of the inbox), under the inbox lock every inbox writer
# takes (${SLACK_DIR}/inbox.lock: the watch's append, this process's and the loop's removals), so
# that a watch run by hand beside this process never appends into a file sed -i is replacing. With
# the chat gate off, the loop's own per-cycle watch is the intake, exactly as before this process existed.
#
# How a message is answered:
# - FAST PATH, no model call, from files: the text, after a leading <@bot> mention is stripped,
#   trimmed and lower-cased, is "status" (the output of /agent/agent-status.sh), "goals", "tasks",
#   "list goals" or "list tasks" (the goals file's headings and checkbox lines, or a line saying no
#   goals file exists yet), or "help" (the command list).
# - EVERYTHING ELSE: one headless claude call (claude -p, prompt on stdin, cwd
#   AUTONOMY_LOOP_WORKDIR, timeout SLACK_CHAT_TIMEOUT, transcript under ${SLACK_DIR}/chat/). The
#   prompt carries the message (ts/channel/user/text/thread_ts), the agent status, the goals file
#   (first 200 lines), the last 20 notes lines, and the rules: answer with one short Slack message
#   by running /agent/slack-post.sh; when the message states a goal, record it with
#   /agent/goals-add.sh and say so (the loop fires on the goals file from its next cycle) - with
#   --priority high|low when the person says how urgent it is ("first", "urgent", "ASAP" / "can
#   wait"), and /agent/goals-add.sh --set-priority G<n> high|low|normal when they re-rank a goal
#   already in the file ("make G<n> high priority"; the supervisor mode of G99 orders goals by that
#   marker, a high one wakes a sleeping loop); edit no other file; never create the loop's STOP flag. If the call fails, times out, or posts nothing,
#   this process posts one honest line itself ("I could not produce an answer: ...", or claude's
#   final text when it answered on stdout only), so the person is never left waiting silently.
#   Whether the model posted is known exactly: slack-post.sh records every post it makes in the
#   file named by SLACK_POST_RECORD, set per message for the claude call - each landed part's ts, and
#   the word "unknown" when a part's response was lost (exit 5): the answer may be on the platform, so
#   no fallback is posted for it either.
# - NOT FROM STALE CONTEXT: the answer is posted with SLACK_POST_AFTER_TS, the newest message of the
#   conversation the answer goes to (the thread it is posted in - for a top-level message with
#   SLACK_REPLY_IN_THREAD on, the thread under that message, where the person's follow-ups on the topic
#   are expected; else the channel's top level) in the inbox when the answer began, so
#   slack-post.sh refuses it (exit 3) when a newer one arrived meanwhile; the line stays first in the
#   inbox and is answered again, with the newer message in view, on the next poll. That re-answer is
#   bounded: after SLACK_CHAT_STALE_MAX_REFUSALS refusals (default 3), or SLACK_CHAT_STALE_MAX_SECONDS
#   (default 120) after the first, the message is answered without the check and the log says so
#   (CHAT STALE CAP) - a newer message that is not in this conversation as the inbox files it (one lost
#   to a failed call, one in a thread no longer polled) must not hold the channel's queue forever. The
#   refusals are counted in
#   ${SLACK_DIR}/chat/<channel>-<ts>.refusals, removed once the message is handled.
# - NOT CONSUMED UNANSWERED: a post that did not land - slack-post.sh exit 1 after post_reply's own retry
#   of a rate-limited run: a failed call, an API error - leaves the message first in the inbox, logged
#   CHAT POST FAILED, and it is answered again next poll, SLACK_CHAT_POST_RETRIES attempts (default 3) in
#   all; past that it is set aside in ${SLACK_DIR}/unanswered.jsonl, logged CHAT UNANSWERED with that
#   path, never put in processed.jsonl as if handled. A post that exited 4 (a part landed) or 5 (unknown
#   whether it landed) is not sent again and the message is processed, as before. The attempts are
#   counted in ${SLACK_DIR}/chat/<channel>-<ts>.failures, removed once the message is handled or set aside.
# - NOT BEFORE ITS THREAD IS READ: a message whose thread the registry (${SLACK_DIR}/threads-<channel>)
#   lists as never polled - its first conversations.replies call deferred by the watch's budget - is not
#   answered yet: the replies the person may already have written there are not in the inbox, so an answer
#   now would miss them and be refused as stale (slack-post.sh exit 3) for each of them. The line stays
#   first in the inbox, logged CHAT WAIT, with no model call, until the thread's first replies call has
#   been made - at most SLACK_CHAT_STALE_MAX_SECONDS from the first wait (${SLACK_DIR}/chat/<channel>-<ts>.wait),
#   then it is answered as any message, logged CHAT WAIT CAP.
#
# The claude call (the same facts as the loop's fire, see loop.sh "The fire's claude call"): the default
# SLACK_CHAT_CLAUDE_OPTS is the SAFE VALUE below - a reply is driven by whoever posts in SLACK_CHANNELS (and only by the
# people SLACK_ALLOWED_USERS names, slack-watch.sh), so it may reply, attach a file and record a goal, and nothing more.
# --dangerously-skip-permissions, the authority a native instance's responder has (docs/manual/autonomy.md "Autonomy loop",
# docs/parity/PARITY-GAP.md), is the opt-in; with it the call's environment carries IS_SANDBOX=1 (Claude Code accepts
# the flag from root only inside a declared sandbox; this container is one). The prompt's RULES still bound what the
# model is asked to do. The SAFE VALUE, the default again since the Guardian review of 2026-11-11:
# "--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/goals-add.sh:*) --permission-mode acceptEdits" - headless
# claude under acceptEdits denies every Bash call, so that value carries the allow rules for exactly those three scripts,
# placed FIRST because --allowedTools is variadic and would swallow a positional prompt; the prompt is passed on stdin.
# An override that uses acceptEdits must keep both rules if the agent is meant to reply and record goals. The string is
# split by claude_opts_split and checked by claude_opts_check (/agent/claude-opts.sh, shared with loop.sh and
# loop-once.sh): a space inside parentheses stays in its rule - Bash(kubectl get:*) is one word - and nothing is
# glob-expanded; a word that cannot be a rule (parentheses that do not pair up, quotes, a tool name that can match no
# tool) is reported at CHAT START, the word quoted, and with AUTONOMY_LOOP_OPTS_CHECK=true (the default) no
# model call is made for a message: the person gets one line saying so (CHAT MODEL rc=96 config=<report>, the report as
# the transcript) and the fast-path answers (status, goals, help) still work; with false the report is a CHAT WARNING
# and the call runs as before (claude ignores the rule and says so at the top of the transcript).
#
# Concurrency: this process and a loop fire may run at the same time. They share nothing but the
# goals file (append-only from here, through goals-add.sh) and slack-post.sh (single-line appends
# to posted.jsonl). A loop fire never reads the inbox while this process is on.
#
# Watchdog discipline (as loop.sh): single instance via flock on ${SLACK_DIR}/chat.lock; a stop
# flag ${SLACK_DIR}/chat.STOP halts the process at its next poll (/agent/slack-chat-stop.sh;
# /agent/slack-chat-start.sh removes the flag); one-line state in ${SLACK_DIR}/chat.state
# (POLLING, ANSWERING, STOPPED); log ${SLACK_DIR}/chat.log; the watch's own output in
# ${SLACK_DIR}/chat-watch.log. Slack's HTTP 429 is honored: slack-watch.sh and slack-post.sh
# record the Retry-After seconds in ${SLACK_DIR}/retry-after and this process sleeps that long
# (at most 300 s) before polling again; it never polls faster than SLACK_CHAT_POLL_INTERVAL.
#
# Settings (all overridable via environment; the first three are declared in .env):
#   SLACK_CHAT_ENABLED        - run the responder: true|false|auto (default auto = on when
#                               SLACK_BOT_TOKEN and SLACK_CHANNELS are set; /agent/slack-gates.sh)
#   SLACK_CHAT_POLL_INTERVAL  - seconds between polls (default 5)
#   SLACK_CHAT_TIMEOUT        - per-reply claude timeout in seconds (default 1500, a native responder's bound; 180 until 2026-10-31)
#   SLACK_CHAT_STALE_MAX_REFUSALS, SLACK_CHAT_STALE_MAX_SECONDS - the bound on answering a message
#                               again after a stale refusal (default 3 refusals, or 120 s after the
#                               first); past it the message is answered without the newest check; the
#                               seconds also bound the wait for a thread the watch has not read yet (CHAT WAIT)
#   SLACK_CHAT_POST_RETRIES   - how many attempts in all a message whose post landed nothing gets, one per
#                               poll (default 3); past it the line is set aside in unanswered.jsonl
#   SLACK_CHAT_CLAUDE_OPTS    - claude options for a reply (default the safe value "--allowedTools
#                               Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/goals-add.sh:*)
#                               --permission-mode acceptEdits"; "--dangerously-skip-permissions" is the opt-in; see "The claude call" above; not
#                               passed by value from .env, which passes it bare - export it in
#                               the host shell or .env.local to override)
#   AUTONOMY_LOOP_OPTS_CHECK  - check SLACK_CHAT_CLAUDE_OPTS at start and answer without a model call while it holds a
#                               word that cannot be a rule: true (default) or false (see "The claude call" above; the
#                               loop's fires read the same setting)
#   SLACK_DIR                 - Slack state directory (default /wd/slack)
#   AUTONOMY_LOOP_DIR         - loop state directory, for notes.md and the status (default /wd/loop)
#   AUTONOMY_LOOP_GOALS       - goals file (default /wd/goals/GOALS.md)
#   AUTONOMY_LOOP_WORKDIR     - working directory for the claude call (default /wd)
#   SLACK_BOT_TOKEN, SLACK_CHANNELS, SLACK_API_BASE - as for slack-watch.sh and slack-post.sh
#   SLACK_REPLY_IN_THREAD     - where the answer to a TOP-LEVEL message goes: true (default) = in a thread
#                               under it, the thread this topic continues in; false = top-level, where the
#                               person wrote. A message in a thread is answered in that thread either way

export HOME=${HOME:-/home/agent}

SLACK_DIR=${SLACK_DIR:-/wd/slack}
SLACK_CHAT_POLL_INTERVAL=${SLACK_CHAT_POLL_INTERVAL:-5}
SLACK_CHAT_TIMEOUT=${SLACK_CHAT_TIMEOUT:-1500}
SLACK_CHAT_STALE_MAX_REFUSALS=${SLACK_CHAT_STALE_MAX_REFUSALS:-3}
SLACK_CHAT_STALE_MAX_SECONDS=${SLACK_CHAT_STALE_MAX_SECONDS:-120}
SLACK_CHAT_POST_RETRIES=${SLACK_CHAT_POST_RETRIES:-3}
SLACK_CHAT_CLAUDE_OPTS=${SLACK_CHAT_CLAUDE_OPTS:-"--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/goals-add.sh:*) --permission-mode acceptEdits"}
# IS_SANDBOX=1 for a reply whose options skip the permission checks (as loop.sh does for a fire; see "The claude call")
CHAT_SANDBOX=""
case " ${SLACK_CHAT_CLAUDE_OPTS} " in *" --dangerously-skip-permissions "*|*bypassPermissions*) CHAT_SANDBOX=1 ;; esac   # either spelling of the mode option
AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}
AUTONOMY_LOOP_GOALS=${AUTONOMY_LOOP_GOALS:-/wd/goals/GOALS.md}
AUTONOMY_LOOP_WORKDIR=${AUTONOMY_LOOP_WORKDIR:-/wd}
SLACK_REPLY_IN_THREAD=${SLACK_REPLY_IN_THREAD:-true}

# Sibling scripts: /agent in the image, Container-Root/agent in a checkout (how /test4.sh runs them)
AGENT_DIR=$(cd "$(dirname "$0")" && pwd)
SLACK_GATES_BIN=${SLACK_GATES_BIN:-${AGENT_DIR}/slack-gates.sh}
SLACK_WATCH_BIN=${SLACK_WATCH_BIN:-${AGENT_DIR}/slack-watch.sh}
SLACK_POST_BIN=${SLACK_POST_BIN:-${AGENT_DIR}/slack-post.sh}
AGENT_STATUS_BIN=${AGENT_STATUS_BIN:-${AGENT_DIR}/agent-status.sh}
# The paths the model is told to run - they must match the allow rules in SLACK_CHAT_CLAUDE_OPTS
SLACK_POST_CMD=${SLACK_POST_CMD:-/agent/slack-post.sh}
GOALS_ADD_CMD=${GOALS_ADD_CMD:-/agent/goals-add.sh}
# The option string's words and their check (see "The claude call") are one file beside this script, shared with loop.sh
# and loop-once.sh: CHAT_OPTS_ARGV is what claude gets, CHAT_OPTS_REPORT the check's one line (empty when every rule
# word can be a rule) - both fixed here, since the value changes only with a new container
CLAUDE_OPTS_BIN=${CLAUDE_OPTS_BIN:-${AGENT_DIR}/claude-opts.sh}
if [ ! -f "${CLAUDE_OPTS_BIN}" ]; then
	echo "ERROR: ${CLAUDE_OPTS_BIN} not found - claude-opts.sh ships beside slack-chat.sh; set CLAUDE_OPTS_BIN if it lives elsewhere" >&2
	exit 1
fi
. "${CLAUDE_OPTS_BIN}"
claude_opts_split CHAT_OPTS_ARGV "${SLACK_CHAT_CLAUDE_OPTS}"
CHAT_OPTS_REPORT=$(claude_opts_check CHAT_OPTS_ARGV)

# Absolute paths - the responder runs detached without a login shell PATH
CLAUDE_BIN=${CLAUDE_BIN:-/usr/local/bin/claude}
NODE_BIN=${NODE_BIN:-/usr/local/bin/node}
[ -x "${NODE_BIN}" ] || NODE_BIN=$(command -v node)

CHAT_LOG=${SLACK_DIR}/chat.log
CHAT_STATE=${SLACK_DIR}/chat.state
STOP_FLAG=${SLACK_DIR}/chat.STOP
LOCK_FILE=${SLACK_DIR}/chat.lock
INBOX=${SLACK_DIR}/inbox.jsonl
INBOX_LOCK=${SLACK_DIR}/inbox.lock
PROCESSED=${SLACK_DIR}/processed.jsonl
UNANSWERED=${SLACK_DIR:?}/unanswered.jsonl
RETRY_AFTER_FILE=${SLACK_DIR:?}/retry-after
TRANSCRIPTS=${SLACK_DIR:?}/chat
NOTES=${AUTONOMY_LOOP_DIR}/notes.md

if [ ! -f "${SLACK_GATES_BIN}" ]; then
	echo "ERROR: ${SLACK_GATES_BIN} not found - slack-gates.sh ships beside slack-chat.sh; set SLACK_GATES_BIN if it lives elsewhere" >&2
	exit 1
fi
. "${SLACK_GATES_BIN}"
if [ "${SLACK_CHAT_EFFECTIVE}" != "on" ]; then
	echo "Slack chat responder refusing to run: the chat gate is off (${SLACK_CHAT_REASON}). It is on when SLACK_CHAT_ENABLED=true, or when it is auto or unset (the .env default) and both SLACK_BOT_TOKEN and SLACK_CHANNELS are set; SLACK_CHAT_ENABLED=false turns it off. /agent/slack-gates.sh shows the effective gates." >&2
	exit 1
fi

if [ -z "${NODE_BIN}" ]; then
	echo "ERROR: node not found (looked at /usr/local/bin/node and PATH); set NODE_BIN" >&2
	exit 1
fi

case "${SLACK_CHAT_POLL_INTERVAL}" in
''|*[!0-9]*|0)
	echo "WARNING: SLACK_CHAT_POLL_INTERVAL='${SLACK_CHAT_POLL_INTERVAL}' is not a positive number of seconds - using 5" >&2
	SLACK_CHAT_POLL_INTERVAL=5
	;;
esac
case "${SLACK_REPLY_IN_THREAD}" in
true|false) ;;
*)
	echo "WARNING: SLACK_REPLY_IN_THREAD='${SLACK_REPLY_IN_THREAD}' is not true or false - using true (a top-level message is answered in a thread under it)" >&2
	SLACK_REPLY_IN_THREAD=true
	;;
esac

mkdir -p "${SLACK_DIR}" "${TRANSCRIPTS}" "${AUTONOMY_LOOP_WORKDIR}"

log()
{
	LINE="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
	echo "${LINE}"
	echo "${LINE}" >> "${CHAT_LOG}"
}

state()
{
	echo "$* pid=$$ utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${CHAT_STATE}"
}

count_lines()
{
	C=$(grep -c . "$1" 2>/dev/null)
	echo "${C:-0}"
}

# Sleep in 1 s steps so the stop flag takes effect promptly
pause()
{
	SLEPT=0
	while [ "${SLEPT}" -lt "$1" ] && [ ! -f "${STOP_FLAG}" ]; do
		sleep 1
		SLEPT=$((SLEPT + 1))
	done
}

# After a Slack HTTP 429 (recorded by slack-watch.sh / slack-post.sh): honor Retry-After, at most 300 s
rate_limit_pause()
{
	[ -f "${RETRY_AFTER_FILE}" ] || return 0
	RA=$(tr -dc '0-9' < "${RETRY_AFTER_FILE}")
	rm -f "${RETRY_AFTER_FILE:?}"
	[ -z "${RA}" ] && RA=30
	[ "${RA}" -gt 300 ] && RA=300
	[ "${RA}" -lt 1 ] && RA=1
	log "CHAT RATE LIMITED retry_after=${RA}s - sleeping before the next poll"
	pause "${RA}"
}

# post_reply <channel> <thread_ts or empty> <text> - one post through slack-post.sh (read-back
# verified there). Prints the posted ts on success. Returns 3 when slack-post.sh refused because a
# newer message arrived (SLACK_POST_AFTER_TS, set per message below); 4 when a part of the text
# landed but the post did not complete, and 5 when a transport failure left it unknown whether a part
# landed: that text is never sent again - slack-post.sh records each landed part's ts in
# ${TRANSCRIPTS}/<channel>-<ts>.landed (its SLACK_POST_RECORD here), and a run that landed anything,
# or may have, is not retried. One retry after a rate limit, only for a run that posted nothing (exit 1).
# inbox_move <destination> - the first inbox line appended to <destination> and removed from the inbox,
# under the inbox lock shared with slack-watch.sh's append and the loop's removals (no append lands in a
# file sed -i is replacing). The line is the one just handled: the watch only appends.
inbox_move()
{
	{
		flock -w 60 8 || log "CHAT WARNING the inbox lock ${INBOX_LOCK} was not free within 60 s; moving the line anyway"
		head -n 1 "${INBOX}" >> "$1"
		sed -i '1d' "${INBOX}"
	} 8>> "${INBOX_LOCK}"
}

post_reply()
{
	ATTEMPT=0
	LANDED_REC=${TRANSCRIPTS:?}/${M_CH:?}-${M_TS:?}.landed
	rm -f "${LANDED_REC:?}"
	while :; do
		ATTEMPT=$((ATTEMPT + 1))
		if [ -n "$2" ]; then
			OUT=$(SLACK_POST_RECORD="${LANDED_REC}" "${SLACK_POST_BIN}" "$1" "$3" "$2" 2>&1)
		else
			OUT=$(SLACK_POST_RECORD="${LANDED_REC}" "${SLACK_POST_BIN}" "$1" "$3" 2>&1)
		fi
		RC=$?
		if [ ${RC} -eq 0 ]; then
			echo "${OUT}" | grep -o 'ts=[0-9.]*' | head -1 | cut -d= -f2
			return 0
		fi
		POST_ERR=$(echo "${OUT}" | grep -m1 -E '^(ERROR|STALE):')
		[ -z "${POST_ERR}" ] && POST_ERR=$(echo "${OUT}" | grep -m1 .)
		if [ ${RC} -eq 3 ]; then
			echo "${POST_ERR}"
			return 3
		fi
		if [ ${RC} -eq 4 ] || [ ${RC} -eq 5 ] || [ -s "${LANDED_REC}" ]; then
			echo "${POST_ERR}"
			return ${RC}
		fi
		if [ ${ATTEMPT} -eq 1 ] && [ -f "${RETRY_AFTER_FILE}" ]; then
			rate_limit_pause
			continue
		fi
		echo "${POST_ERR}"
		return ${RC}
	done
}

goals_summary()
{
	if [ -f "${AUTONOMY_LOOP_GOALS}" ]; then
		G=$(grep -E '^#|^[[:space:]]*[-*] \[[ xX]\]' "${AUTONOMY_LOOP_GOALS}" | head -60)
		N=$(grep -c -E '^[[:space:]]*[-*] \[ \]' "${AUTONOMY_LOOP_GOALS}")
		printf 'Goals file %s (%s unchecked item(s); headings and checkbox lines):\n%s' "${AUTONOMY_LOOP_GOALS}" "${N:-0}" "${G:-(no headings or checkbox lines)}"
	else
		echo "no goals file yet at ${AUTONOMY_LOOP_GOALS} - tell me a goal and I will add it; the autonomy loop fires on it from its next cycle"
	fi
}

# conversation_after <channel> <thread_ts or empty> <ts> - the inbox lines of the same conversation (the
# channel's top level, or the same thread) newer than <ts>, from someone other than the agent. Prints
# the newest ts seen in that conversation (<ts> itself when there is none), the unit separator, then one
# "ts=<ts> user=<user>: <text>" line per newer message. A line is top-level when it has no thread_ts or
# its thread_ts is its own ts - a top-level message that already has replies carries the latter - the
# one rule slack-post.sh applies to the channel it re-reads before posting; the two must agree, or an
# answer is refused for a message the responder never puts in view.
conversation_after()
{
	"${NODE_BIN}" -e '
const fs = require("fs");
const [inbox, ch, thread, ts, self] = process.argv.slice(1);
let newest = ts; const lines = [];
for (const l of fs.readFileSync(inbox, "utf8").split("\n")) {
	if (!l.trim()) continue;
	let m; try { m = JSON.parse(l); } catch (e) { continue; }
	const conv = (m.thread_ts && m.thread_ts !== m.ts) ? m.thread_ts : "";
	if (m.channel !== ch || conv !== thread || m.user === self) continue;
	if (parseFloat(m.ts) <= parseFloat(ts)) continue;
	if (parseFloat(m.ts) > parseFloat(newest)) newest = m.ts;
	lines.push("ts=" + m.ts + " user=" + m.user + ": " + (m.text || "").replace(/\s+/g, " "));
}
process.stdout.write(newest + "\x1f" + lines.join("\n"));' "${INBOX}" "$1" "$2" "$3" "${IDENTITY_UID}"
}

HELP_TEXT="I answer these from the agent's state files, without a model call: \"status\" (loop and chat state, last fires and notes), \"goals\" / \"tasks\" / \"list goals\" / \"list tasks\" (the goals file), \"help\" (this list). Anything else goes to the model with the current status, goals and notes as context. To give me work, state the goal: I add it to the goals file and the autonomy loop works on it from its next cycle."

# Parse one inbox line: ts, channel, user, thread_ts and text, separated by the unit separator
# (text may contain tabs and newlines)
parse_line()
{
	printf '%s' "$1" | "${NODE_BIN}" -e '
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
	let m;
	try { m = JSON.parse(raw); } catch (e) { process.exit(1); }
	process.stdout.write([m.ts || "", m.channel || "", m.user || "", m.thread_ts || "", m.text || ""].join("\x1f"));
});
'
}

# Model path: one headless claude call for the message; posts a fallback line itself when the
# call fails, times out, or posts nothing
answer_with_model()
{
	# answer_with_model <ts> <channel> <user> <thread_ts> <text>
	M_TS=$1; M_CH=$2; M_USER=$3; M_THREAD=$4; M_TEXT=$5
	TRANSCRIPT=${TRANSCRIPTS}/${M_CH}-${M_TS}.out
	RECORD=${TRANSCRIPTS:?}/${M_CH:?}-${M_TS:?}.posted
	rm -f "${RECORD:?}"
	STATUS_TEXT=$("${AGENT_STATUS_BIN}" 2>&1)
	if [ -f "${AUTONOMY_LOOP_GOALS}" ]; then
		GOALS_TEXT="GOALS FILE ${AUTONOMY_LOOP_GOALS} (first 200 lines):
$(head -200 "${AUTONOMY_LOOP_GOALS}")"
	else
		GOALS_TEXT="GOALS FILE: none yet at ${AUTONOMY_LOOP_GOALS} (${GOALS_ADD_CMD} creates it)"
	fi
	if [ -s "${NOTES}" ]; then
		NOTES_TEXT="PROGRESS NOTES ${NOTES} (last 20 lines):
$(tail -20 "${NOTES}")"
	else
		NOTES_TEXT="PROGRESS NOTES ${NOTES}: none yet"
	fi
	# Where the answer goes: M_REPLY_THREAD (set per message in the main loop) - the message's own thread, or
	# the thread under a top-level message; empty only with SLACK_REPLY_IN_THREAD=false for a top-level message
	THREAD_ARG=""
	THREAD_NOTE="in the channel"
	if [ -n "${M_REPLY_THREAD}" ]; then
		THREAD_ARG=" '${M_REPLY_THREAD}'"
		if [ -n "${M_THREAD}" ]; then
			THREAD_NOTE="in its thread (thread_ts ${M_THREAD})"
		else
			THREAD_NOTE="in a thread under it (thread_ts ${M_REPLY_THREAD}) - the thread this topic continues in"
		fi
	fi
	NEWER_TEXT=""
	if [ -n "${M_NEWER}" ]; then
		NEWER_TEXT="
NEWER MESSAGES in this conversation, already here (each is answered after this one; take them into account):
${M_NEWER}"
	fi
	PROMPT="SLACK CHAT: you are the do-agent-aws answering one Slack message. The autonomy loop works on the goals file separately; you only talk to the person, from the state below.
MESSAGE: ts=${M_TS} channel=${M_CH} user=${M_USER} thread_ts=${M_THREAD:-none} reply_thread=${M_REPLY_THREAD:-none}
text: ${M_TEXT}${NEWER_TEXT}

${STATUS_TEXT}

${GOALS_TEXT}

${NOTES_TEXT}

RULES:
1. Answer with ONE short Slack message, ${THREAD_NOTE}, by running: ${SLACK_POST_CMD} '${M_CH}' '<text>'${THREAD_ARG} - that is the only way to reply; your final text on stdout is not seen by the person unless no post was made. If it exits 4, part of your message is already posted, and if it exits 5 it may be: do not post that text again. When the person asks for a file the harness holds (a chart, a report under /wd/files or /wd/loop - never a secret or a credential), attach it by running: /agent/slack-upload.sh '${M_CH}' '<file-path>' '${M_REPLY_THREAD:-${M_THREAD:-${M_TS}}}' '<one-line comment>' - the same gate and channel list, the file message read back; it exits 4 or 5 when the file landed or may have: do not upload it again.
2. If the message states a goal or task the person wants done, record it by running: ${GOALS_ADD_CMD} '<one-line goal>' '${M_CH} ${M_THREAD:-${M_TS}}' (the channel and the ts of this message's thread root - the thread this topic lives in) - then tell the person it was added to the goals file and that the autonomy loop picks it up on its next cycle (the status above says whether the loop is running or stopped; if it is stopped, say that /agent/loop-start.sh starts it). Priority: when the person says the new goal is high priority, first, urgent, ASAP or top priority, put --priority high before the goal text: ${GOALS_ADD_CMD} --priority high '<one-line goal>' '${M_CH} ${M_THREAD:-${M_TS}}' (a sleeping loop then starts its next cycle at once); when they say it can wait or is low priority, --priority low; otherwise no option. When the message re-ranks a goal that is ALREADY in the goals file ('make G<n> high priority', 'G<n> first', 'G<n> can wait', 'G<n> back to normal'), run: ${GOALS_ADD_CMD} --set-priority G<n> high|low|normal - G<n> is board.sh's number, the n-th checkbox goal counting from the top of the goals file above, done ones included: pass the number the person used; when they name the goal by its text, count the checkbox lines to find its number, or ask when it is not clear which goal they mean. It changes only that goal's line (the leading note '(priority: high|low)'; normal removes it) and prints what it did - tell the person. Exit 4 means no such goal (when the progress notes above call a goal 'G<n> (line <n>)' by its file line, L<n> addresses that line), 5 that the goals file was busy (run it once more), 6 that the line changed meanwhile (nothing written).
3. Answer questions about status, goals, tasks and progress from the state above; say plainly what you do not know. Do not edit any other file, do not run anything else, and never create ${AUTONOMY_LOOP_DIR}/STOP."
	state "ANSWERING ts=${M_TS} channel=${M_CH} kind=model"
	MODEL_START=$(date +%s)
	if [ -n "${CHAT_OPTS_REPORT}" ] && [ "${AUTONOMY_LOOP_OPTS_CHECK}" != "false" ]; then
		# SLACK_CHAT_CLAUDE_OPTS holds a word that cannot be a rule (claude_opts_check, said at CHAT START): no claude call -
		# the report is the transcript, the MODEL line below says rc=96 config=..., and the person gets the honest line
		printf 'REPLY SKIPPED, no claude call: SLACK_CHAT_CLAUDE_OPTS holds a word that cannot be a rule - %s. Claude would ignore that rule and deny every call it allows. Fix the value in .env.local and recreate the container (./stop.sh -s && ./run.sh -s), or set AUTONOMY_LOOP_OPTS_CHECK=false to run the calls anyway.\n' "${CHAT_OPTS_REPORT}" > "${TRANSCRIPT}"
		RC=96
	else
		# Prompt on stdin, options from CHAT_OPTS_ARGV - SLACK_CHAT_CLAUDE_OPTS split by claude_opts_split (see the header:
		# the variadic --allowedTools would swallow a positional prompt), expanded quoted: a rule such as
		# Bash(/agent/slack-post.sh:*) is a pattern for claude, never a glob for the shell, and a space inside parentheses
		# stays in its rule (as in loop.sh). SLACK_POST_RECORD lets slack-post.sh prove, per message, whether the model posted.
		printf '%s' "${PROMPT}" | SLACK_POST_RECORD="${RECORD}" env ${CHAT_SANDBOX:+IS_SANDBOX=1} timeout --kill-after=30 "${SLACK_CHAT_TIMEOUT}" \
			"${CLAUDE_BIN}" -p "${CHAT_OPTS_ARGV[@]}" > "${TRANSCRIPT}" 2>&1
		RC=${PIPESTATUS[1]}
	fi
	MODEL_DURATION=$(( $(date +%s) - MODEL_START ))
	if grep -qE '^[0-9]+\.[0-9]+$' "${RECORD}" 2>/dev/null; then
		LOST_NOTE=""
		grep -qx unknown "${RECORD}" && LOST_NOTE=", and one more post's response was lost (it may be on the platform)"
		log "CHAT MODEL ts=${M_TS} rc=${RC} duration=${MODEL_DURATION}s posted=yes${LOST_NOTE:++unknown} transcript=${TRANSCRIPT}"
		log "CHAT REPLY ts=${M_TS} kind=model ok posted=$(grep -E '^[0-9]+\.[0-9]+$' "${RECORD}" | tail -1) reply_thread=${M_REPLY_THREAD:-none}${LOST_NOTE}"
		return 0
	fi
	# A post's response was lost (slack-post.sh exit 5): the answer may be on the platform, so no
	# fallback - a second copy is worse than an unverified one
	if grep -qx unknown "${RECORD}" 2>/dev/null; then
		log "CHAT MODEL ts=${M_TS} rc=${RC} duration=${MODEL_DURATION}s posted=unknown transcript=${TRANSCRIPT}"
		log "CHAT REPLY ts=${M_TS} kind=model UNKNOWN, a post's response was lost and the platform may hold the answer; no fallback posted"
		return 0
	fi
	# No post landed because a newer message arrived while answering: no fallback - the message is
	# answered again, with the newer one, on the next poll
	if [ -s "${SLACK_POST_STALE_RECORD}" ]; then
		log "CHAT MODEL ts=${M_TS} rc=${RC} duration=${MODEL_DURATION}s posted=no stale=$(head -1 "${SLACK_POST_STALE_RECORD}") transcript=${TRANSCRIPT}"
		return 3
	fi
	# No post landed: say so honestly in one line
	CONFIG_NOTE=""
	if [ ${RC} -eq 96 ]; then
		CONFIG_NOTE=" config=${CHAT_OPTS_REPORT}"
		# the report in backticks: Slack would read its * and <...> as formatting
		FALLBACK="I could not produce an answer: no model call was made, because the responder's claude options hold a word that cannot be a rule - \`${CHAT_OPTS_REPORT}\`. Fix SLACK_CHAT_CLAUDE_OPTS in .env.local and recreate the container, or set AUTONOMY_LOOP_OPTS_CHECK=false to run the calls anyway."
	elif [ ${RC} -eq 124 ] || [ ${RC} -eq 137 ]; then
		FALLBACK="I could not produce an answer: the model call timed out after ${SLACK_CHAT_TIMEOUT}s."
	elif [ ${RC} -ne 0 ]; then
		FIRST_ERR=$(grep -i -m1 'error' "${TRANSCRIPT}" 2>/dev/null)
		[ -z "${FIRST_ERR}" ] && FIRST_ERR=$(grep -m1 . "${TRANSCRIPT}" 2>/dev/null)
		FALLBACK="I could not produce an answer: ${FIRST_ERR:-the model call exited ${RC} with no output}"
	else
		FINAL_TEXT=$(grep -v '^[[:space:]]*$' "${TRANSCRIPT}" 2>/dev/null | head -c 1500)
		if [ -n "${FINAL_TEXT}" ]; then
			FALLBACK="${FINAL_TEXT}"
		else
			FALLBACK="I could not produce an answer: the model call returned nothing."
		fi
	fi
	log "CHAT MODEL ts=${M_TS} rc=${RC} duration=${MODEL_DURATION}s posted=no${CONFIG_NOTE} transcript=${TRANSCRIPT}"
	POSTED=$(post_reply "${M_CH}" "${M_REPLY_THREAD}" "${FALLBACK}")
	FB_RC=$?
	case ${FB_RC} in
	0) log "CHAT REPLY ts=${M_TS} kind=model-fallback ok posted=${POSTED} reply_thread=${M_REPLY_THREAD:-none}" ;;
	3) return 3 ;;
	4) log "CHAT REPLY ts=${M_TS} kind=model-fallback INCOMPLETE, part of it landed and is not sent again: ${POSTED}" ;;
	5) log "CHAT REPLY ts=${M_TS} kind=model-fallback UNKNOWN, the platform may hold it, not sent again: ${POSTED}" ;;
	*)
		# nothing landed, neither the model's post nor this line: the message is not answered (the caller keeps it)
		log "CHAT REPLY ts=${M_TS} kind=model-fallback FAILED, nothing landed: ${POSTED}"
		return 1
		;;
	esac
	return 0
}

# Single-instance guard
exec 9> "${LOCK_FILE}"
if ! flock -n 9; then
	echo "Slack chat responder already running (lock ${LOCK_FILE} held); exiting."
	exit 0
fi

trap 'log "CHAT EXIT signal received"; state "STOPPED reason=signal"; exit 0' TERM INT

log "CHAT START poll=${SLACK_CHAT_POLL_INTERVAL}s timeout=${SLACK_CHAT_TIMEOUT}s channels=${SLACK_CHANNELS} workdir=${AUTONOMY_LOOP_WORKDIR} (${SLACK_CHAT_REASON}); this process owns the Slack inbox while it runs"
# the option string's check (claude_opts_check; see the header "The claude call"): said once here, then on every message it keeps from the model
if [ -n "${CHAT_OPTS_REPORT}" ]; then
	if [ "${AUTONOMY_LOOP_OPTS_CHECK}" != "false" ]; then
		log "CHAT CONFIG SLACK_CHAT_CLAUDE_OPTS: ${CHAT_OPTS_REPORT}; no model call is made until the value is fixed - each message that needs the model is answered with one line saying so (status, goals and help still work); set it in .env.local and recreate the container, or set AUTONOMY_LOOP_OPTS_CHECK=false to run the calls anyway"
	else
		log "CHAT WARNING SLACK_CHAT_CLAUDE_OPTS: ${CHAT_OPTS_REPORT}; the calls run anyway (AUTONOMY_LOOP_OPTS_CHECK=false): claude ignores that rule, says so at the top of each transcript, and denies every call it would have allowed"
	fi
fi
if [ "${SLACK_POST_EFFECTIVE}" != "on" ]; then
	log "CHAT WARNING post gate off (${SLACK_POST_REASON}) - messages are handled but no reply can be posted; set SLACK_POST_ENABLED=auto or true"
fi

cd "${AUTONOMY_LOOP_WORKDIR}"

HANDLED=0
IDENTITY_UID=""

while true; do

	if [ -f "${STOP_FLAG}" ]; then
		log "CHAT STOPPED stop flag ${STOP_FLAG} present"
		state "STOPPED reason=stop-flag"
		exit 0
	fi

	state "POLLING interval=${SLACK_CHAT_POLL_INTERVAL}s handled=${HANDLED}"

	# One watch per poll - slack-watch.sh keeps its own lock and cursors and only appends to the inbox
	if ! "${SLACK_WATCH_BIN}" >> "${SLACK_DIR}/chat-watch.log" 2>&1; then
		log "CHAT WATCH FAILED (see ${SLACK_DIR}/chat-watch.log); handling the inbox as it stands"
		rate_limit_pause
	fi
	[ -f "${SLACK_DIR}/identity" ] && IDENTITY_UID=$(sed -n 's/.*user_id=\([^ ]*\).*/\1/p' "${SLACK_DIR}/identity")

	# Every unprocessed line, oldest first; each one is moved to processed.jsonl as soon as it is
	# handled - it is the first line of the inbox, because only the watch above appends to it
	while [ "$(count_lines "${INBOX}")" -gt 0 ] && [ ! -f "${STOP_FLAG}" ]; do
		LINE=$(head -n 1 "${INBOX}")
		PARSED=$(parse_line "${LINE}")
		IFS=$'\x1f' read -r -d '' M_TS M_CH M_USER M_THREAD M_TEXT < <(printf '%s' "${PARSED}") || true
		SHORT=$(printf '%s' "${M_TEXT}" | tr '\n\r\t' '   ' | head -c 80)
		# Where the answer goes (see the header): the message's own thread, or - a top-level message with
		# SLACK_REPLY_IN_THREAD on - a thread under it, keyed by the message's own ts; the stale check and the
		# watcher's registry (slack-post.sh register_thread) then follow that thread, where the topic continues
		M_REPLY_THREAD=${M_THREAD}
		if [ "${SLACK_REPLY_IN_THREAD}" = "true" ] && [ -z "${M_THREAD}" ]; then
			M_REPLY_THREAD=${M_TS}
		fi
		if [ -z "${M_TS}" ]; then
			log "CHAT SKIP unparseable inbox line: $(printf '%s' "${LINE}" | head -c 120)"
		elif [ -z "${M_CH}" ]; then
			# no channel to answer in, and every record path below is built from it: skipped like an
			# unparseable line, never fatal (a failed :? expansion would end this process on the same line
			# at every restart)
			log "CHAT SKIP ts=${M_TS} line without a channel: $(printf '%s' "${LINE}" | head -c 120)"
		elif [ -n "${IDENTITY_UID}" ] && [ "${M_USER}" = "${IDENTITY_UID}" ]; then
			log "CHAT SKIP ts=${M_TS} channel=${M_CH} own post (user ${M_USER})"
		elif [ -z "${M_TEXT}" ]; then
			log "CHAT SKIP ts=${M_TS} channel=${M_CH} user=${M_USER} empty text"
		else
			# A thread the watch has registered but not read yet (its first replies call deferred by the
			# budget): the replies already there are not in the inbox, so wait for that read (see the header)
			WAITED=${TRANSCRIPTS:?}/${M_CH:?}-${M_TS:?}.wait
			WAIT_KEY=${M_THREAD:-${M_TS}}
			WAIT_POLLED=$(awk -v p="${WAIT_KEY}" '$1 == p { print (NF >= 3 ? $3 : "unknown"); exit }' "${SLACK_DIR}/threads-${M_CH}" 2>/dev/null)
			if [ "${WAIT_POLLED}" = "0" ]; then
				[ -f "${WAITED}" ] || date +%s > "${WAITED}"
				WAITED_FOR=$(( $(date +%s) - $(head -1 "${WAITED}") ))
				if [ "${WAITED_FOR}" -lt "${SLACK_CHAT_STALE_MAX_SECONDS}" ]; then
					log "CHAT WAIT ts=${M_TS} channel=${M_CH}: thread ${WAIT_KEY} is registered but its replies have not been read yet (its first conversations.replies call waits for the budget); answering once they are in, at most ${SLACK_CHAT_STALE_MAX_SECONDS}s from the first wait (${WAITED_FOR}s so far)"
					break
				fi
				# past the bound the message is answered as any other; said once (the record's second line), as a
				# stale refusal for the replies still unread brings the message back here on the next polls
				if [ "$(count_lines "${WAITED}")" -lt 2 ]; then
					log "CHAT WAIT CAP ts=${M_TS} channel=${M_CH}: thread ${WAIT_KEY} still unread after ${WAITED_FOR}s; answering now from the inbox as it stands"
					echo capped >> "${WAITED}"
				fi
			fi
			# Fast path: strip a leading <@bot> mention, trim, lower-case, drop trailing punctuation
			CMD=$(printf '%s' "${M_TEXT}" | tr '\n\r\t' '   ' | sed -E -e 's/^[[:space:]]*<@[A-Z0-9]+(\|[^>]*)?>[[:space:]]*//' -e 's/^[[:space:]]+//' -e 's/[[:space:]?!.:]+$//' | tr '[:upper:]' '[:lower:]')
			case "${CMD}" in
			status)
				KIND=status
				REPLY="\`\`\`
$("${AGENT_STATUS_BIN}" 2>&1)
\`\`\`"
				;;
			goals|tasks|"list goals"|"list tasks"|"list of goals"|"list of tasks"|"show goals"|"show tasks")
				KIND=goals
				REPLY=$(goals_summary)
				;;
			help)
				KIND=help
				REPLY=${HELP_TEXT}
				;;
			*)
				KIND=model
				REPLY=""
				;;
			esac
			log "CHAT MSG ts=${M_TS} channel=${M_CH} user=${M_USER}${M_THREAD:+ thread_ts=${M_THREAD}} reply_thread=${M_REPLY_THREAD:-none} kind=${KIND} text=\"${SHORT}\""
			# The newest message seen in the conversation the answer goes to (M_REPLY_THREAD: the thread the
			# answer is posted in, else the channel's top level - the same place slack-post.sh re-reads, so the
			# two rules agree) when the answer begins: slack-post.sh refuses (exit 3) when a newer one arrives
			# there before the answer is posted - bounded per message (see the header): past
			# SLACK_CHAT_STALE_MAX_REFUSALS refusals, or SLACK_CHAT_STALE_MAX_SECONDS after the first, the
			# answer goes out without the check. For a top-level message answered in a thread under it, a newer
			# TOP-LEVEL message is another topic, not a reason to hold this answer: the person's follow-ups on
			# this topic are expected in the thread, where they do refuse a stale answer
			CONV=$(conversation_after "${M_CH}" "${M_REPLY_THREAD}" "${M_TS}")
			M_NEWER=${CONV#*$'\x1f'}
			export SLACK_POST_STALE_RECORD=${TRANSCRIPTS:?}/${M_CH:?}-${M_TS:?}.stale
			rm -f "${SLACK_POST_STALE_RECORD:?}"
			REFUSALS=${TRANSCRIPTS:?}/${M_CH:?}-${M_TS:?}.refusals
			FAILURES=${TRANSCRIPTS:?}/${M_CH:?}-${M_TS:?}.failures
			N_REFUSED=$(count_lines "${REFUSALS}")
			FIRST_REFUSED=$(head -1 "${REFUSALS}" 2>/dev/null | cut -d' ' -f1)
			REFUSED_FOR=$(( $(date +%s) - ${FIRST_REFUSED:-$(date +%s)} ))
			if [ "${N_REFUSED}" -ge "${SLACK_CHAT_STALE_MAX_REFUSALS}" ] || { [ "${N_REFUSED}" -gt 0 ] && [ "${REFUSED_FOR}" -ge "${SLACK_CHAT_STALE_MAX_SECONDS}" ]; }; then
				log "CHAT STALE CAP ts=${M_TS} channel=${M_CH}: refused ${N_REFUSED} time(s) over ${REFUSED_FOR}s for a newer message ($(tail -1 "${REFUSALS}" | cut -d' ' -f2-)) that is not in this conversation as the inbox files it; answering now without the newest-message check"
				unset SLACK_POST_AFTER_TS
			else
				export SLACK_POST_AFTER_TS=${CONV%%$'\x1f'*}
			fi
			if [ "${KIND}" = "model" ]; then
				answer_with_model "${M_TS}" "${M_CH}" "${M_USER}" "${M_THREAD}" "${M_TEXT}"
				A_RC=$?
			else
				state "ANSWERING ts=${M_TS} channel=${M_CH} kind=${KIND}"
				POSTED=$(post_reply "${M_CH}" "${M_REPLY_THREAD}" "${REPLY}")
				A_RC=$?
				if [ ${A_RC} -eq 0 ]; then
					log "CHAT REPLY ts=${M_TS} kind=${KIND} ok posted=${POSTED} reply_thread=${M_REPLY_THREAD:-none}"
				elif [ ${A_RC} -eq 4 ]; then
					log "CHAT REPLY ts=${M_TS} kind=${KIND} INCOMPLETE, part of it landed and is not sent again: ${POSTED}"
				elif [ ${A_RC} -eq 5 ]; then
					log "CHAT REPLY ts=${M_TS} kind=${KIND} UNKNOWN, the platform may hold it, not sent again: ${POSTED}"
				elif [ ${A_RC} -ne 3 ]; then
					log "CHAT REPLY ts=${M_TS} kind=${KIND} FAILED, nothing landed: ${POSTED}"
				fi
			fi
			unset SLACK_POST_AFTER_TS
			if [ ${A_RC} -eq 3 ]; then
				# Not answered from stale context: leave the line first in the inbox and poll again, so
				# the watch brings the newer message in and this one is answered with it; count the
				# refusal toward the bound
				echo "$(date +%s) $(head -1 "${SLACK_POST_STALE_RECORD}" 2>/dev/null)" >> "${REFUSALS}"
				log "CHAT STALE ts=${M_TS} channel=${M_CH}: a newer message arrived while answering ($(head -1 "${SLACK_POST_STALE_RECORD}" 2>/dev/null)); nothing posted, answering again with it (refusal $(count_lines "${REFUSALS}") of ${SLACK_CHAT_STALE_MAX_REFUSALS}, or ${SLACK_CHAT_STALE_MAX_SECONDS}s, before answering unchecked)"
				unset SLACK_POST_STALE_RECORD
				break
			fi
			unset SLACK_POST_STALE_RECORD
			if [ ${A_RC} -ne 0 ] && [ ${A_RC} -ne 4 ] && [ ${A_RC} -ne 5 ]; then
				# Nothing landed (exit 1: a failed call, an API error; post_reply already retried a rate-limited
				# run once): the message is not answered. It stays first in the inbox and is answered again
				# next poll, SLACK_CHAT_POST_RETRIES attempts in all; past that it is set aside in
				# unanswered.jsonl, logged with the path - never in processed.jsonl, which means handled
				echo "$(date +%s) exit ${A_RC}" >> "${FAILURES}"
				N_FAILED=$(count_lines "${FAILURES}")
				if [ "${N_FAILED}" -lt "${SLACK_CHAT_POST_RETRIES}" ]; then
					log "CHAT POST FAILED ts=${M_TS} channel=${M_CH}: nothing landed (attempt ${N_FAILED} of ${SLACK_CHAT_POST_RETRIES}); the message stays in the inbox and is answered again next poll"
					break
				fi
				inbox_move "${UNANSWERED}"
				rm -f "${FAILURES:?}" "${REFUSALS:?}" "${WAITED:?}"
				log "CHAT UNANSWERED ts=${M_TS} channel=${M_CH}: ${N_FAILED} attempts to answer landed nothing; the message is set aside in ${UNANSWERED} for a person to answer, not in ${PROCESSED}"
				state "POLLING interval=${SLACK_CHAT_POLL_INTERVAL}s handled=${HANDLED} last=${M_TS}"
				continue
			fi
			rm -f "${REFUSALS:?}" "${FAILURES:?}" "${WAITED:?}"
			HANDLED=$((HANDLED + 1))
		fi
		# Mark this line processed: it is still the first line (only the watch appends, and the
		# watch runs only above, in this process)
		inbox_move "${PROCESSED}"
		state "POLLING interval=${SLACK_CHAT_POLL_INTERVAL}s handled=${HANDLED} last=${M_TS}"
	done

	# Never poll faster than the poll interval
	pause "${SLACK_CHAT_POLL_INTERVAL}"

done
