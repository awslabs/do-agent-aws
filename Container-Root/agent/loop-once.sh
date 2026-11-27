#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Run exactly one autonomy-loop fire in the foreground - a debugging aid.
#
# Optional: drop this file if unused; nothing else depends on it.
#
# The fire is the same claude invocation as a /agent/loop.sh fire (same settings, Slack watch -
# only while the chat gate is off; with it on /agent/slack-chat.sh owns the inbox and a fire gets
# none of it - choice of goals file, prompt, transcript, log, and state contract - keep the blocks
# below in sync with loop.sh) with the transcript additionally streamed to the terminal. It takes the
# same single-instance lock, so it refuses to run while the loop is running, and its END line
# lands in loop.log so fire numbering stays continuous. The STOP flag is not consulted - it
# governs the loop, not an explicit one-shot fire.
#
# The mode: this is one SERIAL fire whatever AUTONOMY_LOOP_MODE says. loop.sh's supervisor mode (G99 - several workers
# per cycle, one per group of goals the planner supervisor-plan.py forms; docs/manual/autonomy.md "Autonomy loop", "Supervisor mode")
# belongs to the loop: loop-once.sh reads neither AUTONOMY_LOOP_MODE, AUTONOMY_LOOP_DRY_RUN nor the SUPERVISOR_* settings,
# and the fire it runs gets no WORKER_GOAL_HASHES, so goals-mark.sh refuses it every goal and it edits the goals file
# itself, as its prompt says.
#
# The claude call is loop.sh's (see its header "The fire's claude call"): the default AUTONOMY_LOOP_CLAUDE_OPTS is the
# safe value below; --dangerously-skip-permissions is the opt-in, and gets IS_SANDBOX=1 in the fire's environment (Claude
# Code accepts the flag from root only inside a declared sandbox; this container is one). The safe value carries the allow rules --allowedTools
# Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) FIRST, because headless claude
# under acceptEdits alone denies every Bash call (the fire could never run slack-post.sh or answer its bus inbox) and
# because --allowedTools is variadic and swallows a positional prompt that follows it; the prompt therefore goes on
# stdin. An override of AUTONOMY_LOOP_CLAUDE_OPTS that uses acceptEdits must keep the rules if the agent is meant to reply.
# The option string is split by claude_opts_split and checked by claude_opts_check (/agent/claude-opts.sh, shared with
# loop.sh and slack-chat.sh): a space inside parentheses stays in its rule, and a word that cannot be a rule is reported
# before the fire - with AUTONOMY_LOOP_OPTS_CHECK=true (the default) this fire is then skipped: the report on stderr and
# as the transcript, END rc=96 outcome=config <report>, exit status 96; with false the report is a WARNING and the fire runs.
#
# The bus intake is loop.sh's, from the same file, loop-inbox.sh (see loop.sh's header "Bus intake"): the hub's open
# requests and notices in the prompt before the goals, at most LOOP_INBOX_MAX; the fire runs as the hub; after END the
# fire's record, then the receipts that close what it left (loop-inbox.sh's header). LOOP_INBOX=false turns it off.
#
# The Plane board mirror is loop.sh's (see its header "Plane board mirror"; kept in sync): fire-start after BEGIN,
# fire-end after END, best effort.

export HOME=${HOME:-/home/agent}

AUTONOMY_LOOP_GOALS=${AUTONOMY_LOOP_GOALS:-/wd/goals/GOALS.md}
AUTONOMY_LOOP_FIRE_TIMEOUT=${AUTONOMY_LOOP_FIRE_TIMEOUT:-1500}
AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}
AUTONOMY_LOOP_WORKDIR=${AUTONOMY_LOOP_WORKDIR:-/wd}
AUTONOMY_LOOP_CLAUDE_OPTS=${AUTONOMY_LOOP_CLAUDE_OPTS:-"--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits"}
# IS_SANDBOX=1 in the fire's environment whenever its options skip the permission checks (loop.sh, kept in sync)
FIRE_SANDBOX=""
case " ${AUTONOMY_LOOP_CLAUDE_OPTS} " in *" --dangerously-skip-permissions "*|*bypassPermissions*) FIRE_SANDBOX=1 ;; esac   # --permission-mode bypassPermissions, or =bypassPermissions
# The option string's words and their check (loop.sh's header "The fire's claude call") are one file beside this script,
# shared by loop.sh, loop-once.sh and slack-chat.sh: FIRE_OPTS_ARGV is what claude gets, FIRE_OPTS_REPORT the check's one
# line (empty when every rule word can be a rule)
CLAUDE_OPTS_BIN=${CLAUDE_OPTS_BIN:-$(dirname "$0")/claude-opts.sh}
if [ ! -f "${CLAUDE_OPTS_BIN}" ]; then
	echo "ERROR: ${CLAUDE_OPTS_BIN} not found - claude-opts.sh ships beside loop-once.sh; set CLAUDE_OPTS_BIN if it lives elsewhere" >&2
	exit 1
fi
. "${CLAUDE_OPTS_BIN}"
claude_opts_split FIRE_OPTS_ARGV "${AUTONOMY_LOOP_CLAUDE_OPTS}"
FIRE_OPTS_REPORT=$(claude_opts_check FIRE_OPTS_ARGV)
AUTONOMY_LOOP_DEFAULT_GOALS=${AUTONOMY_LOOP_DEFAULT_GOALS:-/agent/goals-default.md}
# The bus intake (see loop.sh's header "Bus intake") - its settings and its two steps, inbox_read and inbox_record -
# is one file beside this script, shared by loop.sh and loop-once.sh
LOOP_INBOX_BIN=${LOOP_INBOX_BIN:-$(dirname "$0")/loop-inbox.sh}
if [ ! -f "${LOOP_INBOX_BIN}" ]; then
	echo "ERROR: ${LOOP_INBOX_BIN} not found - loop-inbox.sh ships beside loop-once.sh; set LOOP_INBOX_BIN if it lives elsewhere" >&2
	exit 1
fi
. "${LOOP_INBOX_BIN}"
# The Slack gates - whether this loop watches Slack (and, for the prompt, whether a fire may
# post) - are one decision shared with slack-post.sh, slack-status.sh and startup.sh. The file
# sits beside this script: /agent in the image, Container-Root/agent in a checkout (how /test4.sh
# runs it).
SLACK_GATES_BIN=${SLACK_GATES_BIN:-$(dirname "$0")/slack-gates.sh}
# the fire's outcome from its OUTPUT, not only claude's exit status (fire-outcome.sh: `claude -p` exits 0 when it
# cannot load AWS credentials)
FIRE_OUTCOME_BIN=${FIRE_OUTCOME_BIN:-$(dirname "$0")/fire-outcome.sh}
if [ ! -f "${SLACK_GATES_BIN}" ]; then
	echo "ERROR: ${SLACK_GATES_BIN} not found - slack-gates.sh ships beside loop-once.sh; set SLACK_GATES_BIN if it lives elsewhere" >&2
	exit 1
fi
. "${SLACK_GATES_BIN}"
# Who takes Slack messages in: while the chat gate is on, /agent/slack-chat.sh owns the inbox - it
# polls and answers on its own interval and this loop neither runs the watch nor hands the inbox to
# fires (a goal stated in chat arrives in ${AUTONOMY_LOOP_GOALS}, which a cycle fires on as usual).
# With the chat gate off, the watch gate decides, exactly as before the responder existed.
if [ "${SLACK_CHAT_EFFECTIVE}" = "on" ]; then
	LOOP_SLACK_INTAKE=off
	LOOP_SLACK_INTAKE_REASON="the Slack inbox is owned by /agent/slack-chat.sh while the chat gate is on (${SLACK_CHAT_REASON})"
else
	LOOP_SLACK_INTAKE=${SLACK_WATCH_EFFECTIVE}
	LOOP_SLACK_INTAKE_REASON=${SLACK_WATCH_REASON}
fi
SLACK_DIR=${SLACK_DIR:-/wd/slack}
SLACK_LOOP_BATCH_MAX=${SLACK_LOOP_BATCH_MAX:-50}

# The Plane board mirror - the same settings as loop.sh (kept in sync)
PLANE_URL=${PLANE_URL:-}
PLANE_SYNC_BIN=${PLANE_SYNC_BIN:-$(dirname "$0")/plane-sync.py}
PLANE_SYNC_TIMEOUT=${PLANE_SYNC_TIMEOUT:-30}
# The Slack carry (see the header): a fire that did not end well - its answer refused as stale, a
# timeout, any other nonzero exit - leaves its batch in the inbox for the next fire, which gets the lines
# marked CARRIED with the posts the fires so far did land listed so that it does not repeat them, up to
# SLACK_LOOP_CARRY_MAX carries. At the bound the next SLACK_LOOP_BOUND_FIRES fires post without the
# newest-message check, the batch staying in the inbox, each such fire logging "carry bound reached" with
# the message count and the oldest ts; a fire that ends well (rc 0 and no stale refusal) processes it, and
# when none does the batch is set aside in ${SLACK_DIR}/unanswered.jsonl - the side file the chat
# responder uses for a message it could not answer - logged loud with the path, never processed.jsonl.
# The landed-posts list keeps each post once and the newest SLACK_LOOP_CARRY_POSTS_MAX of them, the rest
# counted, so the prompt does not grow without bound. Nothing is processed unanswered.
SLACK_LOOP_CARRY_MAX=${SLACK_LOOP_CARRY_MAX:-3}
SLACK_LOOP_BOUND_FIRES=${SLACK_LOOP_BOUND_FIRES:-3}
SLACK_LOOP_CARRY_POSTS_MAX=${SLACK_LOOP_CARRY_POSTS_MAX:-20}
CARRIED_FILE=${AUTONOMY_LOOP_DIR:?}/slack-carried
CARRY_COUNT_FILE=${AUTONOMY_LOOP_DIR:?}/slack-carried-count
CARRIED_POSTS_FILE=${AUTONOMY_LOOP_DIR:?}/slack-carried-posts
# The inbox lock every inbox writer takes (slack-watch.sh's append, slack-chat.sh's and this script's
# removals of handled lines): no append lands in a file sed -i is replacing
INBOX_LOCK=${SLACK_DIR:?}/inbox.lock
NODE_BIN=${NODE_BIN:-/usr/local/bin/node}
[ -x "${NODE_BIN}" ] || NODE_BIN=$(command -v node)

# slack_mark_carried - stdin: inbox lines; stdout: the same, those whose ts a previous fire carried prefixed "CARRIED "
slack_mark_carried()
{
	awk -v carried="${CARRIED_FILE}" 'BEGIN { while ((getline l < carried) > 0) if (l != "") m[l] = 1 }
		{ ts = $0; sub(/^\{"ts":"/, "", ts); sub(/".*/, "", ts); if (ts in m) print "CARRIED " $0; else print }'
}

# slack_landed_posts <record> - one line per ts the fire's SLACK_POST_RECORD holds: where it was posted and its text
# as posted.jsonl logged them, for the next fire's carry note
slack_landed_posts()
{
	[ -s "$1" ] || return 0
	"${NODE_BIN}" -e '
const fs = require("fs");
const [record, posted] = process.argv.slice(1);
const want = fs.readFileSync(record, "utf8").split("\n").filter(Boolean);
const seen = {};
for (const l of (fs.existsSync(posted) ? fs.readFileSync(posted, "utf8") : "").split("\n")) {
	if (!l.trim()) continue;
	let m; try { m = JSON.parse(l); } catch (e) { continue; }
	if (want.includes(m.ts)) seen[m.ts] = m;
}
for (const ts of want) {
	if (ts === "unknown") { console.log("  a post whose response was lost: it may be on the platform (its text is the answer the fire was posting)"); continue; }
	const m = seen[ts]; console.log("  ts=" + ts + " thread_ts=" + ((m && m.thread_ts) || "none") + " text: " + ((m && m.text) || "(landed, text not read back)").replace(/\s+/g, " "));
}
' "$1" "${SLACK_DIR}/posted.jsonl"
}

# slack_cap_carried_posts - the landed-posts list for the carry note: each post once, the newest
# SLACK_LOOP_CARRY_POSTS_MAX kept, the rest counted in a first line
slack_cap_carried_posts()
{
	[ -s "${CARRIED_POSTS_FILE}" ] || return 0
	DROPPED=$(sed -n 's/^  \.\.\. and \([0-9]*\) earlier post(s), not listed$/\1/p' "${CARRIED_POSTS_FILE}" | head -1)
	grep -v '^  \.\.\. and [0-9]* earlier post(s), not listed$' "${CARRIED_POSTS_FILE}" | awk '!seen[$0]++' > "${CARRIED_POSTS_FILE}.tmp"
	N_POSTS=$(count_lines "${CARRIED_POSTS_FILE}.tmp")
	if [ "${N_POSTS}" -gt "${SLACK_LOOP_CARRY_POSTS_MAX}" ]; then
		{ echo "  ... and $(( ${DROPPED:-0} + N_POSTS - SLACK_LOOP_CARRY_POSTS_MAX )) earlier post(s), not listed"; tail -n "${SLACK_LOOP_CARRY_POSTS_MAX}" "${CARRIED_POSTS_FILE}.tmp"; } > "${CARRIED_POSTS_FILE}"
		rm -f "${CARRIED_POSTS_FILE:?}.tmp"
	else
		{ [ -n "${DROPPED}" ] && echo "  ... and ${DROPPED} earlier post(s), not listed"; cat "${CARRIED_POSTS_FILE}.tmp"; } > "${CARRIED_POSTS_FILE}"
		rm -f "${CARRIED_POSTS_FILE:?}.tmp"
	fi
}

# Absolute paths - may run without a login shell PATH
CLAUDE_BIN=${CLAUDE_BIN:-/usr/local/bin/claude}
SLACK_WATCH_BIN=${SLACK_WATCH_BIN:-/agent/slack-watch.sh}
# The kanban board mirror - the same settings and calls as loop.sh (see its header; kept in sync)
KANBAN_BOARD_URL=${KANBAN_BOARD_URL:-}
KANBAN_SYNC_BIN=${KANBAN_SYNC_BIN:-$(dirname "$0")/kanban-sync.py}
KANBAN_SYNC_TIMEOUT=${KANBAN_SYNC_TIMEOUT:-30}

LOOP_LOG=${AUTONOMY_LOOP_DIR}/loop.log
LOOP_STATE=${AUTONOMY_LOOP_DIR}/loop.state
STOP_FLAG=${AUTONOMY_LOOP_DIR}/STOP
LOCK_FILE=${AUTONOMY_LOOP_DIR}/loop.lock

mkdir -p "${AUTONOMY_LOOP_DIR}/fires" "${AUTONOMY_LOOP_WORKDIR}"

log()
{
	LINE="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
	echo "${LINE}"
	echo "${LINE}" >> "${LOOP_LOG}"
}

state()
{
	echo "$* pid=$$ utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${LOOP_STATE}"
}

completed_fires()
{
	C=$(grep -c " END rc=" "${LOOP_LOG}" 2>/dev/null)
	echo "${C:-0}"
}

# Mirror the fire on the Plane board (PLANE_URL): best effort, bounded by the timeout, and a failure only logs a
# line - a board outage never fails, blocks or changes a fire. Keep in sync with loop.sh.
plane_sync()
{
	[ -n "${PLANE_URL}" ] || return 0
	PLANE_SYNC_OUT=$(timeout "${PLANE_SYNC_TIMEOUT}" "${PLANE_SYNC_BIN}" "$@" 2>> "${AUTONOMY_LOOP_DIR}/plane-sync.log")
	PLANE_SYNC_RC=$?
	if [ "${PLANE_SYNC_RC}" -eq 0 ]; then
		log "FIRE ${FIRE} PLANE ${PLANE_SYNC_OUT##*$'\n'}"
	else
		log "FIRE ${FIRE} PLANE $1 not mirrored (rc=${PLANE_SYNC_RC}, see ${AUTONOMY_LOOP_DIR}/plane-sync.log); the fire is unaffected"
	fi
	return 0
}

count_lines()
{
	C=$(grep -c . "$1" 2>/dev/null)
	echo "${C:-0}"
}

# Mirror the fire on the kanban board - same function as loop.sh (kept in sync): best effort, bounded by the
# timeout, and a failure only logs a line
kanban_sync()
{
	[ -n "${KANBAN_BOARD_URL}" ] || return 0
	SYNC_OUT=$(timeout --kill-after=5 "${KANBAN_SYNC_TIMEOUT}" "${KANBAN_SYNC_BIN}" "$@" 2>> "${AUTONOMY_LOOP_DIR}/kanban-sync.log")
	SYNC_RC=$?
	if [ "${SYNC_RC}" -eq 0 ]; then
		log "FIRE ${FIRE} KANBAN ${SYNC_OUT##*$'\n'}"
	else
		log "FIRE ${FIRE} KANBAN $1 not mirrored (rc=${SYNC_RC}, see ${AUTONOMY_LOOP_DIR}/kanban-sync.log); the fire is unaffected"
	fi
	return 0
}

# Same single-instance lock as the loop - a manual fire must not interleave with a running loop
exec 9> "${LOCK_FILE}"
if ! flock -n 9; then
	echo "Autonomy loop is running (lock ${LOCK_FILE} held); stop it first or check /agent/loop-status.sh."
	exit 1
fi

cd "${AUTONOMY_LOOP_WORKDIR}"

# Slack watch when the watch gate is on - same gated block as a loop.sh cycle (kept in sync): poll once, before
# deciding what to fire against, so a one-shot fire sees new messages even with no goals file.
# A failed watch is reported loud but does not block the fire.
INBOX_DEPTH=0
if [ "${LOOP_SLACK_INTAKE}" = "on" ]; then
	if ! "${SLACK_WATCH_BIN}" >> "${AUTONOMY_LOOP_DIR}/slack-watch.log" 2>&1; then
		log "SLACK WATCH FAILED (once) (see ${AUTONOMY_LOOP_DIR}/slack-watch.log); continuing with the inbox as it stands"
	fi
	INBOX_DEPTH=$(count_lines "${SLACK_DIR}/inbox.jsonl")
fi

# What to fire against - same choice as a loop.sh cycle: the user goals file when it exists; else
# the shipped default goals when Slack messages are waiting; else nothing
GOALS_MODE=""
if [ -f "${AUTONOMY_LOOP_GOALS}" ]; then
	GOALS_SRC=${AUTONOMY_LOOP_GOALS}
	GOALS_MODE=user
elif [ "${LOOP_SLACK_INTAKE}" = "on" ] && [ "${INBOX_DEPTH}" -gt 0 ]; then
	if [ -f "${AUTONOMY_LOOP_DEFAULT_GOALS}" ]; then
		GOALS_SRC=${AUTONOMY_LOOP_DEFAULT_GOALS}
		GOALS_MODE=default
	else
		echo "Goals file ${AUTONOMY_LOOP_GOALS} not found and the default goals file ${AUTONOMY_LOOP_DEFAULT_GOALS} is missing (${INBOX_DEPTH} unprocessed Slack message(s) waiting); nothing to fire against."
		exit 1
	fi
elif [ "${LOOP_SLACK_INTAKE}" = "on" ]; then
	echo "Goals file ${AUTONOMY_LOOP_GOALS} not found and the Slack inbox is empty; nothing to fire against."
	exit 1
else
	echo "Goals file ${AUTONOMY_LOOP_GOALS} not found and the Slack watch is off (${LOOP_SLACK_INTAKE_REASON}); nothing to fire against."
	exit 1
fi

FIRE=$(( $(completed_fires) + 1 ))
FIRE_OUT=${AUTONOMY_LOOP_DIR}/fires/fire-${FIRE}.out
BEGIN="FIRE ${FIRE} BEGIN (once) goals=${GOALS_SRC}"
DEFAULT_NOTE=""
STOP_STEP="If every goal is already complete, create the file ${STOP_FLAG} to halt the loop."
# How a goal is marked done - the two forms /agent/kanban-sync.py reads (docs/manual/boards.md "Kanban board"); the default
# goals file is a standing goal that is never edited, so its fires get no such step
MARK_STEP=" When a goal's DONE condition holds, mark it done in the goals file: \`- [x]\`, or \`[x]\` in its \`## Goal\` heading."
if [ "${GOALS_MODE}" = "default" ]; then
	BEGIN="${BEGIN} (default: no user goals file at ${AUTONOMY_LOOP_GOALS})"
	DEFAULT_NOTE=" No user goals file exists at ${AUTONOMY_LOOP_GOALS}; you are firing on the shipped default goals because Slack messages arrived. If a message states a goal, create ${AUTONOMY_LOOP_GOALS} (mkdir -p its directory) with that goal and a checkable DONE condition; the loop fires on it from the next cycle."
	STOP_STEP="The default goals are a standing goal: do not create ${STOP_FLAG}; the loop idles on its own while the inbox is empty."
	MARK_STEP=""
fi
log "${BEGIN}"
plane_sync fire-start --fire "${FIRE}"
state "FIRING fire=${FIRE} once=true"
FIRE_START=$(date +%s)
kanban_sync fire-start --fire "${FIRE}" --started "${FIRE_START}"
# Hand the oldest unprocessed inbox lines (watched above, never re-polled here) to the fire -
# same block as loop.sh (kept in sync); the lines are marked processed afterwards
SLACK_BATCH=0
SLACK_PROMPT=""
if [ "${LOOP_SLACK_INTAKE}" = "on" ]; then
	SLACK_BATCH=$(( INBOX_DEPTH < SLACK_LOOP_BATCH_MAX ? INBOX_DEPTH : SLACK_LOOP_BATCH_MAX ))
	if [ "${SLACK_BATCH}" -gt 0 ]; then
		log "FIRE ${FIRE} SLACK context: ${SLACK_BATCH} of ${INBOX_DEPTH} unprocessed message(s) included"
		# Lines a previous fire left unanswered come back marked CARRIED, with that fire's posts listed
		CARRIES=$(cat "${CARRY_COUNT_FILE}" 2>/dev/null || echo 0)
		CARRIED_NOTE=""
		if [ -s "${CARRIED_FILE}" ]; then
			CARRIED_N=$(head -n "${SLACK_BATCH}" "${SLACK_DIR}/inbox.jsonl" | slack_mark_carried | grep -c '^CARRIED ')
			CARRIED_NOTE="
CARRIED: the ${CARRIED_N} message(s) marked CARRIED below were handed to the previous fire, which left them unanswered - its answer was refused because a newer message had arrived, it timed out, or it failed. The messages that arrived since follow them. Answer the carried messages now, with the newer ones in view, each once. Posts the previous fires did land, not to be repeated:
$( [ -s "${CARRIED_POSTS_FILE}" ] && cat "${CARRIED_POSTS_FILE}" || echo "  none")"
		fi
		# Where a reply goes (SLACK_REPLY_IN_THREAD, the .env default true; the chat responder follows the same rule): with it on,
		# a top-level message is answered in a thread under it, where the topic continues - a goal recorded from Slack carries
		# "(from Slack <channel> <ts>)", and anything a fire posts about that goal goes in the thread of that ts the same way;
		# off, the sentence is the one until 2026-10-31 (answer where the person wrote). The sentence is what test4's fake
		# claude parses, so its wording is load-bearing. The one rule, as in slack-chat.sh: false turns it off, any other value is on
		if [ "${SLACK_REPLY_IN_THREAD:-true}" != "false" ]; then
			SLACK_REPLY_RULE="always in-thread: pass the message's thread_ts when it has one, else its ts, as the third argument - a message in a thread is answered in that thread, and a top-level message gets a thread under it, where the topic continues; a goal recorded from Slack carries '(from Slack <channel> <ts>)', and anything you post about that goal goes in the thread of that ts the same way"
		else
			SLACK_REPLY_RULE="adding the message's thread_ts as a third argument only when the message has one - answer where the person wrote: in the thread for a message in a thread, top-level for a top-level message"
		fi
		SLACK_PROMPT="

SLACK INBOX: the following ${SLACK_BATCH} unprocessed Slack message(s) (one JSON object per line: ts/channel/user/text, plus thread_ts when the message belongs to a thread) arrived on the watched channels. Treat them as input for this cycle where they relate to the goals. Messages whose user matches the bot user_id recorded in ${SLACK_DIR}/identity are your own earlier posts - never reply to those. To reply, run /agent/slack-post.sh '<channel>' '<text>', ${SLACK_REPLY_RULE} (allowed when posting is enabled - currently ${SLACK_POST_EFFECTIVE}: ${SLACK_POST_REASON}; /agent/slack-status.sh shows the effective gates; a refusal is expected while it is off). If slack-post.sh refuses with exit 3, a newer message arrived after this inbox was read: do not post that answer from older context - the newer message is in the next cycle's inbox, and the reply belongs with it. If it exits 4, part of your message is already posted, and if it exits 5 it may be: do not post that text again. To attach a file (a chart, a report - never a secret or a credential), run /agent/slack-upload.sh '<channel>' '<file-path>' '<thread_ts, or empty for the channel>' '<comment>' - the same gate and channel list, the file message read back; it exits 4 or 5 when the file landed or may have: do not upload it again.${CARRIED_NOTE}
$(head -n "${SLACK_BATCH}" "${SLACK_DIR}/inbox.jsonl" | slack_mark_carried)"
	fi
fi
# The bus intake (loop-inbox.sh, as in loop.sh): the hub's open requests and notices, read without a receipt, into
# INBOX_PROMPT, which the prompt carries after its first line, before the goals
inbox_read
PROMPT="You are one fire of the do-agent-aws autonomy loop. Work exactly one cycle: Observe -> Act -> Persist -> Stop.${INBOX_PROMPT}
1. OBSERVE: read the goals file ${GOALS_SRC}, and the progress notes ${AUTONOMY_LOOP_DIR}/notes.md if it exists.${DEFAULT_NOTE}
2. ACT: complete the single smallest unfinished increment of work toward the goals.
3. PERSIST: save your work to files; append a one-line progress note to ${AUTONOMY_LOOP_DIR}/notes.md.${MARK_STEP}
4. STOP: end after one increment. ${STOP_STEP}${SLACK_PROMPT}"
# Prompt on stdin, options from FIRE_OPTS_ARGV (AUTONOMY_LOOP_CLAUDE_OPTS split by claude_opts_split) - same call as
# loop.sh (kept in sync), with the transcript additionally streamed to the terminal
# SLACK_POST_AFTER_TS: the newest message the fire was handed, so slack-post.sh refuses (exit 3) to post
# an answer once a newer one has arrived where it posts (empty, and unchecked, without a batch)
SLACK_AFTER_TS=$(head -n "${SLACK_BATCH}" "${SLACK_DIR}/inbox.jsonl" 2>/dev/null | sed -n 's/^{"ts":"\([0-9.]*\)".*/\1/p' | sort -n | tail -1)
[ "${SLACK_BATCH}" -gt 0 ] || SLACK_AFTER_TS=""
CARRIES=${CARRIES:-0}
if [ "${SLACK_BATCH}" -gt 0 ] && [ "${CARRIES}" -ge "${SLACK_LOOP_CARRY_MAX}" ]; then
	log "FIRE ${FIRE} SLACK the batch was carried ${SLACK_LOOP_CARRY_MAX} time(s), the bound: this fire posts without the newest-message check; the batch is processed after it if it ends well, else it stays in the inbox (fire $(( CARRIES - SLACK_LOOP_CARRY_MAX + 1 )) of ${SLACK_LOOP_BOUND_FIRES} at the bound)"
	SLACK_AFTER_TS=""
fi
FIRE_BASE=${FIRE_OUT%.out}
rm -f "${FIRE_BASE:?}.stale" "${FIRE_BASE:?}.posted"
if [ -n "${FIRE_OPTS_REPORT}" ] && [ "${AUTONOMY_LOOP_OPTS_CHECK}" = "false" ]; then
	log "FIRE ${FIRE} WARNING AUTONOMY_LOOP_CLAUDE_OPTS: ${FIRE_OPTS_REPORT}; the fire runs anyway (AUTONOMY_LOOP_OPTS_CHECK=false): claude ignores that rule, says so at the top of the transcript, and denies every call it would have allowed"
fi
if [ -n "${FIRE_OPTS_REPORT}" ] && [ "${AUTONOMY_LOOP_OPTS_CHECK}" != "false" ]; then
	# the option string holds a word that cannot be a rule (claude_opts_check; loop.sh says so at LOOP START): no claude
	# call - the report is this fire's transcript and goes to stderr, and the fire ends rc=96 outcome=config
	printf 'FIRE SKIPPED, no claude call: AUTONOMY_LOOP_CLAUDE_OPTS holds a word that cannot be a rule - %s. Claude would ignore that rule and deny every call it allows, and the fire would run on until its timeout. Fix the value in .env.local and recreate the container (./stop.sh -s && ./run.sh -s), or set AUTONOMY_LOOP_OPTS_CHECK=false to run the fires anyway.\n' "${FIRE_OPTS_REPORT}" | tee "${FIRE_OUT}" >&2
	RC=96
	OUTCOME="config ${FIRE_OPTS_REPORT}"
else
	# the option words are FIRE_OPTS_ARGV (claude_opts_split), expanded quoted: a rule such as Bash(/agent/slack-post.sh:*) or
	# Read(//opt/comms/**) is a pattern for claude, never a glob for the shell, and a space inside parentheses stays in its rule
	# the fire is the hub on the bus, as in loop.sh (kept in sync): BUS_AGENT_ID, and no TMUX or TMUX_PANE of this shell's
	printf '%s' "${PROMPT}" | SLACK_POST_AFTER_TS=${SLACK_AFTER_TS} SLACK_POST_STALE_RECORD="${FIRE_OUT%.out}.stale" SLACK_POST_RECORD="${FIRE_OUT%.out}.posted" \
		env -u TMUX -u TMUX_PANE ${FIRE_SANDBOX:+IS_SANDBOX=1} BUS_AGENT_ID="${BUS_HUB}" timeout --kill-after=30 "${AUTONOMY_LOOP_FIRE_TIMEOUT}" "${CLAUDE_BIN}" -p "${FIRE_OPTS_ARGV[@]}" 2>&1 | tee "${FIRE_OUT}"
	RC=${PIPESTATUS[1]}
	OUTCOME=$("${FIRE_OUTCOME_BIN}" "${FIRE_OUT}" "${RC}" 2>/dev/null || echo "ok")
	# a fire whose claude could not use its credentials did no work: exit status 97 where claude's own was 0
	[ "${OUTCOME%% *}" == "ok" ] || [ "${RC}" != "0" ] || RC=97
fi
log "FIRE ${FIRE} END rc=${RC} duration=$(( $(date +%s) - FIRE_START ))s outcome=${OUTCOME}"
# the fire's inbox record, then its receipts: nothing it was handed is marked read before this point
[ -n "${INBOX_IDS}" ] && inbox_record
kanban_sync fire-end --fire "${FIRE}" --started "${FIRE_START}" --rc "${RC}" \
	--duration "$(( $(date +%s) - FIRE_START ))" --out "${FIRE_OUT}"
# The handed-over Slack lines: processed (moved to processed.jsonl - exactly the first SLACK_BATCH
# lines, unchanged because slack-watch.sh only appends) when the fire got to answer them; CARRIED
# (left first in the inbox for the next fire, marked) when it did not - its answer was refused as
# stale, or it timed out - up to SLACK_LOOP_CARRY_MAX times
if [ "${SLACK_BATCH}" -gt 0 ]; then
	CARRY_REASON=""
	if [ -s "${FIRE_OUT%.out}.stale" ]; then
		CARRY_REASON="its answer was refused as stale (a newer message: $(head -1 "${FIRE_OUT%.out}.stale"))"
	elif [ "${RC}" -eq 124 ] || [ "${RC}" -eq 137 ]; then
		CARRY_REASON="it timed out after ${AUTONOMY_LOOP_FIRE_TIMEOUT}s"
	elif [ "${RC}" -eq 96 ]; then
		CARRY_REASON="it was skipped: AUTONOMY_LOOP_CLAUDE_OPTS holds a word that cannot be a rule (the END line names it)"
	elif [ "${RC}" -ne 0 ]; then
		CARRY_REASON="it exited ${RC}"
	fi
	if [ -z "${CARRY_REASON}" ]; then
		# the fire ended well: the batch is handled
		{
			flock -w 60 8 || log "FIRE ${FIRE} SLACK WARNING the inbox lock ${INBOX_LOCK} was not free within 60 s; moving the batch anyway"
			head -n "${SLACK_BATCH}" "${SLACK_DIR}/inbox.jsonl" >> "${SLACK_DIR}/processed.jsonl"
			sed -i "1,${SLACK_BATCH}d" "${SLACK_DIR}/inbox.jsonl"
		} 8>> "${INBOX_LOCK}"
		rm -f "${CARRIED_FILE:?}" "${CARRY_COUNT_FILE:?}" "${CARRIED_POSTS_FILE:?}"
		log "FIRE ${FIRE} SLACK processed=${SLACK_BATCH} remaining=$(count_lines "${SLACK_DIR}/inbox.jsonl")"
	else
		# not handled: the whole batch stays first in the inbox, marked for the next fire, with the posts
		# landed so far listed (each once, the newest SLACK_LOOP_CARRY_POSTS_MAX, the rest counted) so that no
		# fire repeats one - until SLACK_LOOP_BOUND_FIRES fires at the bound have failed too: then it is set aside
		head -n "${SLACK_BATCH}" "${SLACK_DIR}/inbox.jsonl" | sed -n 's/^{"ts":"\([0-9.]*\)".*/\1/p' > "${CARRIED_FILE}"
		slack_landed_posts "${FIRE_OUT%.out}.posted" >> "${CARRIED_POSTS_FILE}"
		slack_cap_carried_posts
		CARRIES=$(( CARRIES + 1 ))
		echo "${CARRIES}" > "${CARRY_COUNT_FILE}"
		if [ "${CARRIES}" -le "${SLACK_LOOP_CARRY_MAX}" ]; then
			log "FIRE ${FIRE} SLACK carried=${SLACK_BATCH}: ${CARRY_REASON}; the batch stays in the inbox for the next fire, marked CARRIED (carry ${CARRIES} of ${SLACK_LOOP_CARRY_MAX}), $(grep -c '^  ts=' "${CARRIED_POSTS_FILE}") post(s) landed so far listed"
		elif [ $(( CARRIES - SLACK_LOOP_CARRY_MAX )) -lt "${SLACK_LOOP_BOUND_FIRES}" ]; then
			log "FIRE ${FIRE} SLACK carry bound reached: ${CARRY_REASON} after ${SLACK_LOOP_CARRY_MAX} carries, the bound; its ${SLACK_BATCH} message(s), the oldest ts=$(head -1 "${CARRIED_FILE}"), stay in the inbox marked CARRIED (fire $(( CARRIES - SLACK_LOOP_CARRY_MAX )) of ${SLACK_LOOP_BOUND_FIRES} at the bound; set aside in ${SLACK_DIR}/unanswered.jsonl after fire ${SLACK_LOOP_BOUND_FIRES} unless a fire ends well) - nothing is processed unanswered"
		else
			# the bound's fires failed too: set aside where a person finds it, visibly, never as handled
			{
				flock -w 60 8 || log "FIRE ${FIRE} SLACK WARNING the inbox lock ${INBOX_LOCK} was not free within 60 s; moving the batch anyway"
				head -n "${SLACK_BATCH}" "${SLACK_DIR}/inbox.jsonl" >> "${SLACK_DIR}/unanswered.jsonl"
				sed -i "1,${SLACK_BATCH}d" "${SLACK_DIR}/inbox.jsonl"
			} 8>> "${INBOX_LOCK}"
			OLDEST=$(head -1 "${CARRIED_FILE}")
			rm -f "${CARRIED_FILE:?}" "${CARRY_COUNT_FILE:?}" "${CARRIED_POSTS_FILE:?}"
			log "FIRE ${FIRE} SLACK set aside: ${CARRY_REASON} after ${SLACK_LOOP_CARRY_MAX} carries and ${SLACK_LOOP_BOUND_FIRES} fires at the bound; its ${SLACK_BATCH} message(s), the oldest ts=${OLDEST}, are moved to ${SLACK_DIR}/unanswered.jsonl for a person to answer, not to processed.jsonl"
		fi
	fi
fi
plane_sync fire-end --fire "${FIRE}" --rc "${RC}" --duration "$(( $(date +%s) - FIRE_START ))" --out "${FIRE_OUT}"
state "STOPPED reason=once-complete fire=${FIRE} rc=${RC} outcome=${OUTCOME%% *}"
exit "${RC}"
