#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Autonomy loop - recurring headless agent fire against a goals file.
#
# Started by startup.sh (via /agent/loop-start.sh) when the loop autostart gate is on:
# AUTONOMY_LOOP=true, or auto (the .env default) or unset while SLACK_BOT_TOKEN and SLACK_CHANNELS
# are set - the shared decision in /agent/slack-gates.sh (see docs/manual/autonomy.md "Autonomy loop"). Each
# fire runs one headless claude cycle
# (Observe -> Act -> Persist -> Stop) against the goals file, appends an outcome line to
# ${AUTONOMY_LOOP_DIR}/loop.log, saves the fire transcript under ${AUTONOMY_LOOP_DIR}/fires/,
# and keeps a one-line machine-readable state in ${AUTONOMY_LOOP_DIR}/loop.state so an outside
# probe can tell whether the loop is firing, sleeping, idle, or stopped.
#
# Watchdog discipline:
# - single instance: flock on ${AUTONOMY_LOOP_DIR}/loop.lock; a second instance exits
# - per-fire timeout: timeout(1) around the claude call (AUTONOMY_LOOP_FIRE_TIMEOUT)
# - stop flag: creating ${AUTONOMY_LOOP_DIR}/STOP halts the loop before the next fire (see
#   /agent/loop-stop.sh); the agent creates it itself when all goals are complete;
#   /agent/loop-start.sh removes it on the next explicit start
#
# Slack context (the watch gate: SLACK_WATCH_ENABLED=true, or auto/unset while SLACK_BOT_TOKEN and
# SLACK_CHANNELS are set - /agent/slack-gates.sh; see docs/manual/channels.md "Slack connectivity"): every cycle
# runs /agent/slack-watch.sh once, whether or not a goals file exists; a fire then includes the
# oldest unprocessed inbox lines in its prompt and moves them to processed.jsonl afterwards - when it
# ended well (rc 0, no stale refusal). Otherwise - its answer refused as stale (slack-post.sh exit 3, a
# newer message had arrived), a timeout, any other nonzero exit - the batch stays in the inbox and the
# next fire gets it marked CARRIED, with the posts the fires so far did land listed so that it does not
# repeat them, up to SLACK_LOOP_CARRY_MAX carries (default 3); at the bound the next SLACK_LOOP_BOUND_FIRES
# fires (default 3) post without the newest-message check, the batch staying in the inbox, logged; when
# none ends well the batch is set aside in ${SLACK_DIR}/unanswered.jsonl, logged with the path. With
# the gate off (SLACK_WATCH_ENABLED=false, or no token and channels configured) no Slack code runs
# and the fire is exactly as before.
#
# Bus intake (docs/INTER-AGENT-MESSAGING.md "A loop fire reads its inbox first"): a fire is the hub on the bus, agent
# (AGENT_TMUX_SESSION_NAME). Before its prompt is written the cycle reads the hub's open requests, then its open notices,
# oldest first, with /agent/bus.sh poll and peek, which write no receipt - at most LOOP_INBOX_MAX of them, the rest
# waiting for the next fire - and the prompt gets them after its first line, before the goals: one bus envelope per line,
# between two marker lines, with the instruction to answer each request through /agent/bus-answer.sh reply and to mark
# each message with a receipt. Replies and errors to agent are not handed over: they stay open for whoever asked. The
# fire runs with BUS_AGENT_ID set to the hub and without the TMUX and TMUX_PANE of a shell the loop was started from, so
# what it sends is from agent. After the fire's END line the loop logs the fire's record - the ids it was handed, the
# replies they got and the ones still open (bus.sh state) - and only then closes the open ones, when the fire ended well
# (exit status 0): a request with a denied receipt, a notice with a read receipt. When it did not (a failure, a timeout)
# they stay open for the next fire, and the third such fire sets a message aside with a denied receipt; a fire with no
# working credentials (rc=97) counts against none, and a fire that dies before its record (the loop killed) leaves them
# open as well. A cycle that does not fire reads no message. LOOP_INBOX=false turns the intake off: no bus read, no
# inbox in the prompt, no record. The intake's code is loop-inbox.sh, beside this script, which loop-once.sh sources as
# well.
# While the CHAT gate is on (SLACK_CHAT_ENABLED, same auto rule - the .env default), none of that
# happens here: the Slack chat responder /agent/slack-chat.sh is the only consumer of the inbox,
# answering messages on its own poll interval; this loop logs that once at start, works on the goals
# file alone, and with no goals file idles as it did before Slack intake existed. The two processes
# may run at the same time; they share only the goals file (chat appends through
# /agent/goals-add.sh) and /agent/slack-post.sh (single-line appends to posted.jsonl).
#
# What a cycle fires against:
# - the user goals file ${AUTONOMY_LOOP_GOALS} when it exists - the normal path;
# - otherwise, when the Slack watch is on and the inbox holds unprocessed messages, the shipped
#   default goals ${AUTONOMY_LOOP_DEFAULT_GOALS}: one standing goal that handles the inbox and,
#   when a message states a goal, creates the user goals file;
# - otherwise the cycle idles with no claude call (state IDLE) until the goals file appears or
#   a Slack message arrives.
#
# The fire's claude call:
# - the shipped default AUTONOMY_LOOP_CLAUDE_OPTS is the safe value: the fire reads and edits files in its working
#   directory under acceptEdits and runs only /agent/slack-post.sh, /agent/slack-upload.sh, /agent/recall.sh and
#   /agent/bus-answer.sh; headless claude denies every other Bash call. A fire is unattended and its goals and Slack
#   messages come from other people, so the authority a native Claude Code instance driven by a loop has
#   (--dangerously-skip-permissions, docs/manual/autonomy.md "Autonomy loop") is an explicit opt-in in
#   .env.local. Claude Code refuses that flag to root unless the process declares itself a deliberate sandbox, so
#   whenever the options skip permissions the fire's environment carries IS_SANDBOX=1 (this container is that sandbox);
#   options that do not skip them get no such variable. The
#   permissions.deny rules of the agent's settings.json still bind under the flag (claude-settings-sync.sh's store rules).
# - the SAFE VALUE, the shipped default, is documented and tested:
#   "--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits".
#   Headless claude (claude -p) under --permission-mode acceptEdits denies every Bash tool call, so a fire could read
#   the Slack inbox but never run /agent/slack-post.sh, which the prompt tells it to reply with: the value carries the
#   allow rule --allowedTools Bash(/agent/slack-post.sh:*), which admits exactly that script (and Bash(/agent/slack-upload.sh:*)
#   for the file the prompt may ask it to attach: the same gate and channel list, the file message read back); everything
#   else in the fire stays under acceptEdits, and an override meant to reply must keep the rules. The recall rule,
#   Bash(/agent/recall.sh:*), lets a fire look the default knowledge and its own learnings up (ranked recall over the
#   LogLearner bank and every Hindsight bank), the way its CLAUDE.md tells it to; the fire can also grep the copy in
#   /wd/knowledge/defaults with its Read and Grep tools. The third, Bash(/agent/bus-answer.sh:*), lets it answer the
#   messages of its bus inbox and mark them (see "Bus intake" above) and nothing more on the bus: bus-answer.sh passes
#   reply, error, receipt and state to bus.sh and refuses request, note, send, poll, peek and last, so a fire starts no
#   conversation; a rule for bus.sh itself would admit those too, and a narrower rule such as
#   Bash(/agent/bus.sh reply:*) - one word, a space inside parentheses stays in its rule - would need
#   one rule per verb. bus.sh writes the harness's own journal and nothing outside the container.
# - --allowedTools is a VARIADIC option: it consumes every following argument up to the next one
#   that starts with "-", so a positional prompt placed after it is swallowed and claude fails with
#   "Error: Input must be provided either through stdin or as a prompt argument when using --print".
#   The safe value therefore puts the rule FIRST (before --permission-mode), and the prompt is passed
#   on stdin, never as a positional argument, so no override order can swallow it.
# - The option string becomes the call's arguments through claude_opts_split (/agent/claude-opts.sh, sourced below): a
#   blank ends a word outside parentheses and stays inside them, so a rule with a space - Bash(bash /path/script.sh:*),
#   Bash(kubectl get:*) - is ONE argument, which claude takes; quotes are not quotes. The words are expanded quoted, so a
#   Bash(...) pattern is never glob-expanded. Word-split by the shell, such a rule would
#   reach claude as two words - "Bash(bash" a harmless unknown tool name, "/path/script.sh:*)" refused with
#   "Ignoring --allowedTools rule ... Wildcard tool name ... is not supported in allow rules" - the rule gone, every call
#   it allowed denied, the fire working around the denials until AUTONOMY_LOOP_FIRE_TIMEOUT. A Bash rule is a prefix of
#   the command text the model types: a script run as `bash /path/x.sh` needs Bash(bash /path/x.sh:*), and
#   Bash(/path/x.sh:*) matches it only when it is run as /path/x.sh.
# - Before the first fire claude_opts_check reads the rule words (those after --allowedTools and --disallowedTools):
#   one that cannot be a rule - parentheses that do not pair up, quotes, a tool name that can match no tool (claude
#   refuses a * in it and takes a slash or a dot silently; both allow nothing) - is reported at LOOP START with the word
#   quoted, and with AUTONOMY_LOOP_OPTS_CHECK=true (the default) each fire is
#   SKIPPED instead of run: no claude call, END rc=96 outcome=config <report>, the report as the fire's transcript (the
#   Agent loop page shows it), the loop sleeping and trying again next interval (the value changes only with a new
#   container). With false the report is a LOOP WARNING and the fires run as before. fire-outcome.sh is the backstop
#   for what the check does not see: an "Ignoring --allowedTools rule" line in a fire's transcript is named on its END
#   line (outcome=ok ignored-rule "<word>") without changing the fire's exit status.
#
# Plane board mirror (docs/manual/boards.md "Plane board"): while the Plane board runs on this target (PLANE_URL, set by
# run.sh), each fire is mirrored as a work item by /agent/plane-sync.py - the goal the fire works on moves to In
# Progress at BEGIN and to Done or In Review at END, with the fire's result as a comment. Best effort: unset = no
# call; a failed call logs one line and the fire is unaffected. PLANE_SYNC_BIN (default plane-sync.py beside this
# script) and PLANE_SYNC_TIMEOUT (default 30 seconds per call) tune it.
#
# Settings (all overridable via environment; the first four are declared in .env):
#   AUTONOMY_LOOP_INTERVAL      - seconds between fires (default 300)
#   AUTONOMY_LOOP_GOALS         - goals file the loop works toward (default /wd/goals/GOALS.md)
#   AUTONOMY_LOOP_FIRE_TIMEOUT  - per-fire timeout in seconds (default 1500)
#   AUTONOMY_LOOP_DIR           - loop state directory (default /wd/loop)
#   AUTONOMY_LOOP_WORKDIR       - working directory for the agent (default /wd)
#   AUTONOMY_LOOP_CLAUDE_OPTS   - claude options for the fire (default the safe value "--allowedTools
#                                 Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits";
#                                 "--dangerously-skip-permissions" is the opt-in; see "The fire's claude call" above)
#   AUTONOMY_LOOP_OPTS_CHECK    - check the option string before the fires and skip a fire whose string holds a word
#                                 that cannot be a rule: true (default) or false (see "The fire's claude call" above
#                                 and /agent/claude-opts.sh)
#   LOOP_INBOX                  - the bus intake: true (default) or false (see "Bus intake" above)
#   LOOP_INBOX_MAX              - the most bus messages handed to one fire (default 8, at most 50); the rest wait
#                                 for the next fire, and the fire's context line says how many
#   BUS_BIN                     - the bus helper (default bus.sh beside this script)
#   LOOP_INBOX_BIN              - the bus intake (default loop-inbox.sh beside this script)
#   AUTONOMY_LOOP_DEFAULT_GOALS - shipped default goals, fired against only while the user goals
#                                 file is absent and Slack messages arrived (default
#                                 /agent/goals-default.md, from Container-Root/agent/)
#   SLACK_WATCH_ENABLED         - watch Slack every cycle and include the inbox in fires:
#                                 true|false|auto (default auto = on when SLACK_BOT_TOKEN and
#                                 SLACK_CHANNELS are set; declared in .env; decided in
#                                 /agent/slack-gates.sh together with the post and autostart gates)
#   SLACK_CHAT_ENABLED          - same values; while on, /agent/slack-chat.sh owns the inbox and
#                                 this loop runs no watch (see "Slack context" above)
#   SLACK_DIR                   - Slack state directory (default /wd/slack)
#   SLACK_LOOP_BATCH_MAX        - max inbox lines handed to one fire (default 50); the rest wait
#                                 for the next fire, and the log states how many were held back
#   KANBAN_BOARD_URL            - the self-hosted kanban board (set by run.sh when it started the board,
#                                 docs/manual/boards.md "Kanban board"): each fire is mirrored on it by
#                                 /agent/kanban-sync.py - the goal the fire works on moves to In progress at
#                                 BEGIN and to Done or In review at END, with the fire's result as a comment.
#                                 Best effort: unset = no call; a failed call logs one line and the fire is
#                                 unaffected. KANBAN_SYNC_BIN (default kanban-sync.py beside this script) and
#                                 KANBAN_SYNC_TIMEOUT (default 30 seconds per call) tune it
#   SLACK_LOOP_CARRY_MAX        - how many fires in a row a batch left unanswered is carried into the
#                                 next fire (default 3) before the fires post without the newest-message
#                                 check; the batch is processed only by a fire that ends well
#   SLACK_LOOP_BOUND_FIRES      - how many fires at the bound may fail (default 3) before the batch is set
#                                 aside in ${SLACK_DIR}/unanswered.jsonl, logged, instead of being fed again
#   SLACK_LOOP_CARRY_POSTS_MAX  - how many landed posts the carry note lists (default 20, the newest; the
#                                 rest counted)
#   AUTONOMY_LOOP_MODE          - serial (default: the cycle above, one fire at a time, unchanged) or supervisor
#                                 (docs/manual/autonomy.md "Supervisor mode"): a cycle runs the planner
#                                 supervisor-plan.py over the goals file and the notes tail, groups the open goals into
#                                 serial chains (goals sharing a checkout, file, AWS account, Slack thread or pending
#                                 answer) and independent goals, and fires one WORKER per group at once - up to
#                                 SUPERVISOR_MAX_WORKERS - each worker a fire of its own (FIRE number, transcript, END
#                                 line, mirrors) with the group's resource locks held by the loop for its life; the next
#                                 cycle starts at once while a worker ended well, the interval applies otherwise. The
#                                 loop, not a worker, creates STOP when no goal is open. A planner failure falls back to
#                                 one serial fire with a LOOP WARNING. The default goals file (no user goals yet) always
#                                 fires serially
#   AUTONOMY_LOOP_DRY_RUN       - true: run ONE cycle that prints what it would fire - serial: `WOULD FIRE <N> mode=serial`;
#                                 supervisor: one `WOULD FIRE <N> group=<id> goals=... hashes=...` line per worker, the
#                                 planner's dispatch - with no claude call, no Slack watch, no bus read, no mirror call, no
#                                 STOP or WAKE change, then exit (state STOPPED reason=dry-run). The offline test of the
#                                 dispatch (test-lib/supervisor-loop-dryrun-test.py). Default false
#   SUPERVISOR_MAX_WORKERS      - workers per supervisor cycle (default 3; 1 = one fire at a time in priority order)
#   SUPERVISOR_MODEL_PASS       - true: a model pass over the plan that may only merge groups.
#                                 Declared and reserved: this staging logs that it is not implemented and the
#                                 deterministic plan stands (default false)
#   SUPERVISOR_MODEL_TIMEOUT    - seconds for that pass when it exists (default 120)
#   SUPERVISOR_STRIKES_MAX      - a goal whose worker ended rc != 0 (timeout 124/137, config 96 and credentials 97
#                                 excepted, as the bus intake counts) this many fires in a row is parked (default 3)
#   SUPERVISOR_PARK_CYCLES      - cycles a parked goal sits out before it is retried (default 6); goals-add.sh --unpark
#                                 G<n> ends it sooner, and a worker that ends well clears the goal's strikes
#   SUPERVISOR_WORKER_OPTS      - extra claude options for a worker, after AUTONOMY_LOOP_CLAUDE_OPTS (e.g. --max-turns 60;
#                                 default none; split by claude-opts.sh like the main option string)
#   SUPERVISOR_PLAN_BIN         - the planner (default supervisor-plan.py beside this script)

export HOME=${HOME:-/home/agent}

AUTONOMY_LOOP_INTERVAL=${AUTONOMY_LOOP_INTERVAL:-300}
AUTONOMY_LOOP_GOALS=${AUTONOMY_LOOP_GOALS:-/wd/goals/GOALS.md}
AUTONOMY_LOOP_FIRE_TIMEOUT=${AUTONOMY_LOOP_FIRE_TIMEOUT:-1500}
AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}
AUTONOMY_LOOP_WORKDIR=${AUTONOMY_LOOP_WORKDIR:-/wd}
AUTONOMY_LOOP_CLAUDE_OPTS=${AUTONOMY_LOOP_CLAUDE_OPTS:-"--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits"}
# Supervisor mode - everything behind AUTONOMY_LOOP_MODE, serial by default, so a rebuild
# changes nothing until the mode is set; the planner and the locks live under ${AUTONOMY_LOOP_DIR}
AUTONOMY_LOOP_MODE=${AUTONOMY_LOOP_MODE:-serial}
AUTONOMY_LOOP_DRY_RUN=${AUTONOMY_LOOP_DRY_RUN:-false}
SUPERVISOR_MAX_WORKERS=${SUPERVISOR_MAX_WORKERS:-3}
case "${SUPERVISOR_MAX_WORKERS}" in "" | *[!0-9]* | 0) SUPERVISOR_MAX_WORKERS=3 ;; esac
SUPERVISOR_MODEL_PASS=${SUPERVISOR_MODEL_PASS:-false}
SUPERVISOR_MODEL_TIMEOUT=${SUPERVISOR_MODEL_TIMEOUT:-120}
SUPERVISOR_STRIKES_MAX=${SUPERVISOR_STRIKES_MAX:-3}
case "${SUPERVISOR_STRIKES_MAX}" in "" | *[!0-9]* | 0) SUPERVISOR_STRIKES_MAX=3 ;; esac
SUPERVISOR_PARK_CYCLES=${SUPERVISOR_PARK_CYCLES:-6}
case "${SUPERVISOR_PARK_CYCLES}" in "" | *[!0-9]*) SUPERVISOR_PARK_CYCLES=6 ;; esac
SUPERVISOR_WORKER_OPTS=${SUPERVISOR_WORKER_OPTS:-}
SUPERVISOR_PLAN_BIN=${SUPERVISOR_PLAN_BIN:-$(dirname "$0")/supervisor-plan.py}
SUPERVISOR_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}/supervisor
LOCKS_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}/locks
# the directory this script runs from: /agent in the image, Container-Root/agent in a checkout - where a worker's prompt
# finds goals-mark.sh and notes-append.sh (section 7)
AGENT_BIN_DIR=$(cd "$(dirname "$0")" && pwd)
LOOP_MODE=${AUTONOMY_LOOP_MODE}
LOOP_MODE_WARNING=""
case "${LOOP_MODE}" in
	serial | supervisor) ;;
	*) LOOP_MODE_WARNING="AUTONOMY_LOOP_MODE=${AUTONOMY_LOOP_MODE} is neither serial nor supervisor: running serial"; LOOP_MODE=serial ;;
esac
if [ "${LOOP_MODE}" = "supervisor" ] && [ ! -f "${SUPERVISOR_PLAN_BIN}" ]; then
	LOOP_MODE_WARNING="AUTONOMY_LOOP_MODE=supervisor but the planner ${SUPERVISOR_PLAN_BIN} is missing: running serial"
	LOOP_MODE=serial
fi
# a dry run makes no outside call: no Slack watch, no bus read, no mirror call (see the mirrors' first line)
WORKER_OPTS_ARGV=()
# IS_SANDBOX=1 in the fire's environment whenever its options skip the permission checks (see "The fire's claude call"):
# Claude Code accepts --dangerously-skip-permissions from root only inside a declared sandbox, and this container is one
FIRE_SANDBOX=""
case " ${AUTONOMY_LOOP_CLAUDE_OPTS} " in *" --dangerously-skip-permissions "*|*bypassPermissions*) FIRE_SANDBOX=1 ;; esac   # --permission-mode bypassPermissions, or =bypassPermissions
# The option string's words and their check (see "The fire's claude call") are one file beside this script, shared by
# loop.sh, loop-once.sh and slack-chat.sh: FIRE_OPTS_ARGV is what claude gets, FIRE_OPTS_REPORT the check's one line
# (empty when every rule word can be a rule) - both fixed here, since the value changes only with a new container
CLAUDE_OPTS_BIN=${CLAUDE_OPTS_BIN:-$(dirname "$0")/claude-opts.sh}
if [ ! -f "${CLAUDE_OPTS_BIN}" ]; then
	echo "ERROR: ${CLAUDE_OPTS_BIN} not found - claude-opts.sh ships beside loop.sh; set CLAUDE_OPTS_BIN if it lives elsewhere" >&2
	exit 1
fi
. "${CLAUDE_OPTS_BIN}"
claude_opts_split FIRE_OPTS_ARGV "${AUTONOMY_LOOP_CLAUDE_OPTS}"
FIRE_OPTS_REPORT=$(claude_opts_check FIRE_OPTS_ARGV)
AUTONOMY_LOOP_DEFAULT_GOALS=${AUTONOMY_LOOP_DEFAULT_GOALS:-/agent/goals-default.md}
# The bus intake (see "Bus intake" above) - its settings and its two steps, inbox_read and inbox_record - is one file
# beside this script, shared by loop.sh and loop-once.sh
LOOP_INBOX_BIN=${LOOP_INBOX_BIN:-$(dirname "$0")/loop-inbox.sh}
if [ ! -f "${LOOP_INBOX_BIN}" ]; then
	echo "ERROR: ${LOOP_INBOX_BIN} not found - loop-inbox.sh ships beside loop.sh; set LOOP_INBOX_BIN if it lives elsewhere" >&2
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
	echo "ERROR: ${SLACK_GATES_BIN} not found - slack-gates.sh ships beside loop.sh; set SLACK_GATES_BIN if it lives elsewhere" >&2
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

# The Plane board mirror (see "Plane board mirror" above)
PLANE_URL=${PLANE_URL:-}
PLANE_SYNC_BIN=${PLANE_SYNC_BIN:-$(dirname "$0")/plane-sync.py}
LOOP_DECK_ADAPTER_BIN=${LOOP_DECK_ADAPTER_BIN:-$(dirname "$0")/loop-deck-adapter.py}
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

# Absolute paths - the loop may run detached without a login shell PATH
CLAUDE_BIN=${CLAUDE_BIN:-/usr/local/bin/claude}
SLACK_WATCH_BIN=${SLACK_WATCH_BIN:-/agent/slack-watch.sh}
KANBAN_BOARD_URL=${KANBAN_BOARD_URL:-}
KANBAN_SYNC_BIN=${KANBAN_SYNC_BIN:-$(dirname "$0")/kanban-sync.py}
KANBAN_SYNC_TIMEOUT=${KANBAN_SYNC_TIMEOUT:-30}

LOOP_LOG=${AUTONOMY_LOOP_DIR}/loop.log
LOOP_STATE=${AUTONOMY_LOOP_DIR}/loop.state
STOP_FLAG=${AUTONOMY_LOOP_DIR}/STOP
# Wake flag: "Run next fire" creates it while the loop is SLEEPING or IDLE; the sleep below ends at its next 5 s step,
# removes it and starts the next cycle at once. A flag created during a fire is cleared at the fire's start, so it never
# causes a second fire back to back.
WAKE_FLAG=${AUTONOMY_LOOP_DIR}/WAKE
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
# line - a board outage never fails, blocks or changes a fire. Keep in sync with loop-once.sh.
plane_sync()
{
	[ -n "${PLANE_URL}" ] || return 0
	[ "${AUTONOMY_LOOP_DRY_RUN}" != "true" ] || return 0
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

# Mirror the fire on the kanban board (see KANBAN_BOARD_URL above): best effort, bounded by the timeout, and a
# failure only logs a line - a board outage never fails, blocks or changes a fire. Keep in sync with loop-once.sh.
kanban_sync()
{
	[ -n "${KANBAN_BOARD_URL}" ] || return 0
	[ "${AUTONOMY_LOOP_DRY_RUN}" != "true" ] || return 0
	SYNC_OUT=$(timeout --kill-after=5 "${KANBAN_SYNC_TIMEOUT}" "${KANBAN_SYNC_BIN}" "$@" 2>> "${AUTONOMY_LOOP_DIR}/kanban-sync.log")
	SYNC_RC=$?
	if [ "${SYNC_RC}" -eq 0 ]; then
		log "FIRE ${FIRE} KANBAN ${SYNC_OUT##*$'\n'}"
	else
		log "FIRE ${FIRE} KANBAN $1 not mirrored (rc=${SYNC_RC}, see ${AUTONOMY_LOOP_DIR}/kanban-sync.log); the fire is unaffected"
	fi
	return 0
}

# ---- one fire's Slack context, claude call and Slack settlement: today's serial fire body, as three functions shared
# by the serial path (called at the same points, statements unchanged) and the supervisor's workers (section 5). They
# read and set the fire's variables (FIRE, FIRE_OUT, PROMPT, SLACK_BATCH, SLACK_PROMPT, SLACK_AFTER_TS, CARRIES, RC,
# OUTCOME) as the inline code did. Keep in sync with loop-once.sh.

# fire_slack_context - the oldest unprocessed inbox lines for this fire (SLACK_BATCH, SLACK_PROMPT) and the newest ts it
# was handed (SLACK_AFTER_TS; empty at the carry bound) - nothing when the loop does not own the inbox
fire_slack_context()
{
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
			# off, the sentence says to answer where the person wrote. The sentence is what test4's fake
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
	SLACK_AFTER_TS=$(head -n "${SLACK_BATCH}" "${SLACK_DIR}/inbox.jsonl" 2>/dev/null | sed -n 's/^{"ts":"\([0-9.]*\)".*/\1/p' | sort -n | tail -1)
	[ "${SLACK_BATCH}" -gt 0 ] || SLACK_AFTER_TS=""
	CARRIES=${CARRIES:-0}
	if [ "${SLACK_BATCH}" -gt 0 ] && [ "${CARRIES}" -ge "${SLACK_LOOP_CARRY_MAX}" ]; then
		log "FIRE ${FIRE} SLACK the batch was carried ${SLACK_LOOP_CARRY_MAX} time(s), the bound: this fire posts without the newest-message check; the batch is processed after it if it ends well, else it stays in the inbox (fire $(( CARRIES - SLACK_LOOP_CARRY_MAX + 1 )) of ${SLACK_LOOP_BOUND_FIRES} at the bound)"
		SLACK_AFTER_TS=""
	fi
}

# fire_claude - the fire's claude call: PROMPT on stdin, options from FIRE_OPTS_ARGV (AUTONOMY_LOOP_CLAUDE_OPTS split by
# claude_opts_split - see the header: the variadic --allowedTools would swallow a positional prompt) plus WORKER_OPTS_ARGV
# (a supervisor worker's SUPERVISOR_WORKER_OPTS; empty for a serial fire). Keep in sync with loop-once.sh.
# The fire is the hub on the bus (see "Bus intake"): BUS_AGENT_ID, and no TMUX or TMUX_PANE of the loop's. A supervisor
# worker also gets WORKER_GOAL_HASHES (the goals it may mark through goals-mark.sh) and SUPERVISOR_WORKER (its tag).
# SLACK_POST_AFTER_TS: the newest message the fire was handed (see loop-once.sh; kept in sync). Sets RC and OUTCOME.
fire_claude()
{
	FIRE_BASE=${FIRE_OUT%.out}
	rm -f "${FIRE_BASE:?}.stale" "${FIRE_BASE:?}.posted"
	if [ -n "${FIRE_OPTS_REPORT}" ] && [ "${AUTONOMY_LOOP_OPTS_CHECK}" != "false" ]; then
		# the option string holds a word that cannot be a rule (claude_opts_check, said at LOOP START): no claude
		# call - the report is this fire's transcript, and the fire ends rc=96 outcome=config (see the header)
		printf 'FIRE SKIPPED, no claude call: AUTONOMY_LOOP_CLAUDE_OPTS holds a word that cannot be a rule - %s. Claude would ignore that rule and deny every call it allows, and the fire would run on until its timeout. Fix the value in .env.local and recreate the container (./stop.sh -s && ./run.sh -s), or set AUTONOMY_LOOP_OPTS_CHECK=false to run the fires anyway.\n' "${FIRE_OPTS_REPORT}" > "${FIRE_OUT}"
		RC=96
		OUTCOME="config ${FIRE_OPTS_REPORT}"
	else
		# the option words are FIRE_OPTS_ARGV (claude_opts_split), expanded quoted: a rule such as Bash(/agent/slack-post.sh:*)
		# or Read(//opt/comms/**) is a pattern for claude, never a glob for the shell, and a space inside parentheses stays
		# in its rule. IS_SANDBOX=1 whenever the options skip the permission checks (FIRE_SANDBOX, see the header)
		FIRE_ENV=(-u TMUX -u TMUX_PANE)
		[ -z "${FIRE_SANDBOX}" ] || FIRE_ENV+=(IS_SANDBOX=1)
		FIRE_ENV+=("BUS_AGENT_ID=${BUS_HUB}")
		[ -z "${WORKER_GOAL_HASHES:-}" ] || FIRE_ENV+=("WORKER_GOAL_HASHES=${WORKER_GOAL_HASHES}" "SUPERVISOR_WORKER=${WORKER_TAG:-}")
		printf '%s' "${PROMPT}" | SLACK_POST_AFTER_TS=${SLACK_AFTER_TS} SLACK_POST_STALE_RECORD="${FIRE_BASE}.stale" SLACK_POST_RECORD="${FIRE_BASE}.posted" \
			env "${FIRE_ENV[@]}" timeout --kill-after=30 "${AUTONOMY_LOOP_FIRE_TIMEOUT}" "${CLAUDE_BIN}" -p "${FIRE_OPTS_ARGV[@]}" "${WORKER_OPTS_ARGV[@]}" > "${FIRE_OUT}" 2>&1
		RC=${PIPESTATUS[1]}
		OUTCOME=$("${FIRE_OUTCOME_BIN}" "${FIRE_OUT}" "${RC}" 2>/dev/null || echo "ok")
		# a fire whose claude could not use its credentials did no work: exit status 97 where claude's own was 0
		[ "${OUTCOME%% *}" == "ok" ] || [ "${RC}" != "0" ] || RC=97
	fi
}

# fire_slack_settle - after the fire's END line: the handed-over Slack lines are processed, carried or set aside (see the
# header "Slack context") - nothing when the fire had no batch
fire_slack_settle()
{
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
}

# ---- supervisor mode (AUTONOMY_LOOP_MODE=supervisor). The planner, supervisor-plan.py,
# groups the open goals; the loop fires one worker per dispatched group at once, each a fire of its own, holding the
# group's resource locks (flock on ${LOCKS_DIR}/<sha256 of key>.lock, closed in the worker so nothing it leaves behind
# keeps a lock) for the worker's life; the bus inbox and the Slack batch go to the first worker only. Strikes and parking
# are section 8: ${SUPERVISOR_DIR}/strikes.tsv (hash, fire, rc, utc) and parked (hash, since cycle, until cycle, utc),
# both under strikes.lock, the formats goals-add.sh --unpark reads. The loop creates STOP when no goal is open.

# supervisor_lock_fds <keys...> - take every lock non-blocking; LOCK_FDS gets the fds, LOCK_BUSY the first busy key
# (every fd taken so far closed again)
supervisor_lock_fds()
{
	LOCK_FDS=""
	LOCK_BUSY=""
	for KEY in "$@"; do
		LP=${LOCKS_DIR}/$(printf '%s' "${KEY}" | sha256sum | cut -d' ' -f1).lock
		exec {LFD}> "${LP}"
		if ! flock -n "${LFD}"; then
			LOCK_BUSY=${KEY}
			eval "exec ${LFD}>&-"
			supervisor_unlock_fds ${LOCK_FDS}
			LOCK_FDS=""
			return 1
		fi
		LOCK_FDS="${LOCK_FDS:+${LOCK_FDS} }${LFD}"
	done
	return 0
}

# supervisor_unlock_fds <fds...> - close the lock fds (the flocks vanish with them)
supervisor_unlock_fds()
{
	for LFD in "$@"; do eval "exec ${LFD}>&-"; done
}

# supervisor_strikes <fire> <rc> <hashes...> - one strike row per goal of a group whose worker did not end well; a goal
# with SUPERVISOR_STRIKES_MAX rows (= in a row: a worker that ends well clears them) is parked for SUPERVISOR_PARK_CYCLES
supervisor_strikes()
{
	S_FIRE=$1
	S_RC=$2
	shift 2
	{
		flock -w 10 7 || log "FIRE ${S_FIRE} SUPERVISOR WARNING the strikes lock ${SUPERVISOR_DIR}/strikes.lock was not free within 10 s; writing anyway"
		for H in "$@"; do
			printf '%s\t%s\t%s\t%s\n' "${H}" "${S_FIRE}" "${S_RC}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${SUPERVISOR_DIR}/strikes.tsv"
			S_N=$(awk -F '\t' -v h="${H}" '$1 == h { n++ } END { print n + 0 }' "${SUPERVISOR_DIR}/strikes.tsv")
			if [ "${S_N}" -ge "${SUPERVISOR_STRIKES_MAX}" ] && ! grep -q "^${H}"$'\t' "${SUPERVISOR_DIR}/parked" 2>/dev/null; then
				printf '%s\t%s\t%s\t%s\n' "${H}" "${SUPERVISOR_CYCLE}" "$(( SUPERVISOR_CYCLE + SUPERVISOR_PARK_CYCLES ))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${SUPERVISOR_DIR}/parked"
				log "FIRE ${S_FIRE} SUPERVISOR parked goal hash ${H}: ${S_N} fire(s) in a row did not end well (rc=${S_RC} now); retried at cycle $(( SUPERVISOR_CYCLE + SUPERVISOR_PARK_CYCLES )), or sooner with goals-add.sh --unpark G<n>"
				PARKED_NOW="${PARKED_NOW:+${PARKED_NOW} }${H}"
			fi
		done
	} 7>> "${SUPERVISOR_DIR}/strikes.lock"
}

# supervisor_clear_strikes <hashes...> - a worker that ended well: the goals' strike rows go
supervisor_clear_strikes()
{
	[ -s "${SUPERVISOR_DIR}/strikes.tsv" ] || return 0
	{
		flock -w 10 7 || return 0
		for H in "$@"; do
			grep -q "^${H}"$'\t' "${SUPERVISOR_DIR}/strikes.tsv" || continue
			grep -v "^${H}"$'\t' "${SUPERVISOR_DIR}/strikes.tsv" > "${SUPERVISOR_DIR}/strikes.tsv.tmp"
			mv -f "${SUPERVISOR_DIR}/strikes.tsv.tmp" "${SUPERVISOR_DIR}/strikes.tsv"
			log "LOOP SUPERVISOR strikes of goal hash ${H} cleared: its worker ended well"
		done
	} 7>> "${SUPERVISOR_DIR}/strikes.lock"
}

# supervisor_unpark_due - at a cycle's start: parked rows whose until-cycle has come leave parked, their strikes with them
supervisor_unpark_due()
{
	[ -s "${SUPERVISOR_DIR}/parked" ] || return 0
	{
		flock -w 10 7 || return 0
		DUE=$(awk -F '\t' -v c="${SUPERVISOR_CYCLE}" '$1 !~ /^#/ && $3 != "" && $3 + 0 <= c + 0 { print $1 }' "${SUPERVISOR_DIR}/parked")
		if [ -n "${DUE}" ]; then
			awk -F '\t' -v c="${SUPERVISOR_CYCLE}" '!($1 !~ /^#/ && $3 != "" && $3 + 0 <= c + 0)' "${SUPERVISOR_DIR}/parked" > "${SUPERVISOR_DIR}/parked.tmp"
			mv -f "${SUPERVISOR_DIR}/parked.tmp" "${SUPERVISOR_DIR}/parked"
			for H in ${DUE}; do
				if [ -s "${SUPERVISOR_DIR}/strikes.tsv" ]; then
					grep -v "^${H}"$'\t' "${SUPERVISOR_DIR}/strikes.tsv" > "${SUPERVISOR_DIR}/strikes.tsv.tmp"
					mv -f "${SUPERVISOR_DIR}/strikes.tsv.tmp" "${SUPERVISOR_DIR}/strikes.tsv"
				fi
				log "LOOP SUPERVISOR cycle ${SUPERVISOR_CYCLE}: goal hash ${H} unparked (its parking ended), strikes cleared - it is planned again"
			done
		fi
	} 7>> "${SUPERVISOR_DIR}/strikes.lock"
}

# supervisor_cycle - one supervisor cycle on GOALS_SRC: plan, dispatch, wait, record. Returns 0 when the cycle ran (or
# dry-ran) and sets NEXT_SLEEP (0 = start the next cycle at once); returns 1 when the planner failed, and the caller runs
# one serial fire instead
supervisor_cycle()
{
	mkdir -p "${SUPERVISOR_DIR}" "${LOCKS_DIR}"
	SUPERVISOR_CYCLE=$(( $(cat "${SUPERVISOR_DIR}/cycle" 2>/dev/null || echo 0) + 1 ))
	echo "${SUPERVISOR_CYCLE}" > "${SUPERVISOR_DIR}/cycle"
	PARKED_NOW=""
	[ "${AUTONOMY_LOOP_DRY_RUN}" = "true" ] || supervisor_unpark_due
	PLAN_JSON=${SUPERVISOR_DIR}/plan-${SUPERVISOR_CYCLE}.json
	PLAN_TXT=${SUPERVISOR_DIR}/plan-${SUPERVISOR_CYCLE}.txt
	python3 -I "${SUPERVISOR_PLAN_BIN}" --goals "${GOALS_SRC}" --notes "${AUTONOMY_LOOP_DIR}/notes.md" --max-workers "${SUPERVISOR_MAX_WORKERS}" \
		--locks-dir "${LOCKS_DIR}" --parked "${SUPERVISOR_DIR}/parked" --json "${PLAN_JSON}" > "${PLAN_TXT}" 2>&1
	PLAN_RC=$?
	if [ "${PLAN_RC}" -ne 0 ]; then
		log "LOOP WARNING supervisor planner ${SUPERVISOR_PLAN_BIN} failed rc=${PLAN_RC} (see ${PLAN_TXT}): this cycle runs one serial fire on the first open goal in file order instead"
		return 1
	fi
	# the plan, read for the shell: a SUMMARY line, then one GROUP line per dispatched group (id, goal ids, hashes, lock
	# keys, the first goal's key for the mirrors, the file holding the worker's YOUR GOALS section)
	DISPATCH_FILE=${SUPERVISOR_DIR}/dispatch-${SUPERVISOR_CYCLE}.tsv
	if ! python3 -I - "${PLAN_JSON}" "${SUPERVISOR_DIR}" "${SUPERVISOR_CYCLE}" "${AGENT_BIN_DIR}" "${GOALS_SRC}" "${STOP_FLAG}" > "${DISPATCH_FILE}" 2> "${DISPATCH_FILE}.err" <<'PY'
import json, os, re, sys
plan_path, out_dir, cycle, agent_dir, goals_file, stop_flag = sys.argv[1:7]
with open(plan_path, encoding="utf-8") as f:
    p = json.load(f)
groups = {g["id"]: g for g in p["groups"]}
def ids(xs):
    return ",".join(xs) if xs else "-"
print("SUMMARY\topen=%d groups=%d dispatch=%s waiting=%s blocked=%s parked=%s" % (
    p["open"], len(p["groups"]), ids(p["dispatch"]), ids(p["waiting"]), ids(p["blocked"]), ids(p["parked"])))
disp = [groups[i] for i in p["dispatch"]]
for g in disp:
    others = sorted({k[5:] for o in disp if o["id"] != g["id"] for k in o["lock_keys"] if k.startswith("path:")})
    gids = ",".join(x["id"].split(" ")[0] for x in g["goals"])
    hashes = " ".join(x["hash"] for x in g["goals"])
    threads = set()
    for x in g["goals"]:
        threads.update(m.group(1) for m in re.finditer(r"\(from Slack \S+ (\d+\.\d+)\)", x["text"]))
        threads.update(m.group(1) for m in re.finditer(r"\bthread\s+(\d+\.\d+)", x["text"]))
    lines = ["YOUR GOALS - this cycle you work on these goals and no other (the supervisor dispatched them to you%s):" % (
        "" if len(g["goals"]) < 2 else " as one serial chain, in this order; they share " + ", ".join(g["keys"]))]
    for x in g["goals"]:
        lines.append("  %s hash %s: %s" % (x["id"], x["hash"], x["text"]))
    lines.append("Other open goals are being worked on by other workers right now: do not read their records, edit their files or post about them%s." % (
        " - leave these paths alone: " + ", ".join(others) if others else ""))
    lines.append("Mark one of your goals done only with `%s/goals-mark.sh G<n> --note '<what proves it>'` (it checks that the goal is yours and flips its one line under the goals lock); append your progress note with `%s/notes-append.sh '<one line>'`; never edit %s or the notes file directly, never run goals-add.sh, never create %s (the loop creates it when every goal is done); %s." % (
        agent_dir, agent_dir, goals_file, stop_flag,
        ("post only in the Slack thread(s) of your goals: " + ", ".join(sorted(threads))) if threads else "post in no Slack thread but one your goals name"))
    pf = os.path.join(out_dir, "worker-%s-%s.txt" % (cycle, g["id"]))
    with open(pf, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("GROUP\t%s\t%s\t%s\t%s\t%s\t%s" % (g["id"], gids, hashes, " ".join(g["lock_keys"]), g["goals"][0]["key"], pf))
PY
	then
		log "LOOP WARNING supervisor plan ${PLAN_JSON} could not be read for dispatch (see ${DISPATCH_FILE}.err): this cycle runs one serial fire instead"
		return 1
	fi
	rm -f "${DISPATCH_FILE:?}.err"
	SUMMARY=$(sed -n 's/^SUMMARY\t//p' "${DISPATCH_FILE}")
	OPEN_N=${SUMMARY#open=}
	OPEN_N=${OPEN_N%% *}
	N_GROUPS=$(grep -c '^GROUP' "${DISPATCH_FILE}")
	log "LOOP SUPERVISOR cycle ${SUPERVISOR_CYCLE}: ${SUMMARY} max_workers=${SUPERVISOR_MAX_WORKERS} plan=${PLAN_JSON}"
	find "${SUPERVISOR_DIR}" -maxdepth 1 \( -name 'plan-*.json' -o -name 'plan-*.txt' -o -name 'dispatch-*.tsv' -o -name 'worker-*.txt' \) -mtime +2 -delete 2>/dev/null
	if [ "${OPEN_N:-0}" -eq 0 ]; then
		if [ "${AUTONOMY_LOOP_DRY_RUN}" = "true" ]; then
			log "LOOP DRY RUN: no open goal in ${GOALS_SRC} - WOULD create ${STOP_FLAG}; not created"
			echo "WOULD STOP (no open goal)"
		else
			log "LOOP SUPERVISOR no open goal in ${GOALS_SRC}: creating ${STOP_FLAG} (in this mode the loop stops the loop, no worker does)"
			touch "${STOP_FLAG}"
		fi
		NEXT_SLEEP=0
		return 0
	fi
	if [ "${N_GROUPS}" -eq 0 ]; then
		log "LOOP SUPERVISOR cycle ${SUPERVISOR_CYCLE}: nothing to dispatch (every group blocked by a lock or parked); next cycle in ${AUTONOMY_LOOP_INTERVAL}s"
		NEXT_SLEEP=${AUTONOMY_LOOP_INTERVAL}
		return 0
	fi
	# dispatch: a FIRE number per worker (sequential, as today - each worker IS a fire), the group's locks held by this
	# process, the bus inbox and the Slack batch to the first worker only
	BASE=$(completed_fires)
	K=0
	FIRES_CSV=""
	INBOX_WORKER=""
	W_PID=(); W_FIRE=(); W_GID=(); W_IDS=(); W_HASHES=(); W_FDS=(); W_START=()
	if [ "${AUTONOMY_LOOP_DRY_RUN}" != "true" ]; then
		FIRE=$(( BASE + 1 ))
		fire_slack_context
		inbox_read
	fi
	while IFS=$'\t' read -r KIND GID IDS HASHES LOCK_KEYS KEY1 PFILE; do
		[ "${KIND}" = "GROUP" ] || continue
		if ! supervisor_lock_fds ${LOCK_KEYS}; then
			log "LOOP SUPERVISOR cycle ${SUPERVISOR_CYCLE}: group ${GID} (${IDS}) waits - its resource ${LOCK_BUSY} is locked by a running worker"
			continue
		fi
		K=$(( K + 1 ))
		FIRE=$(( BASE + K ))
		FIRE_OUT=${AUTONOMY_LOOP_DIR}/fires/fire-${FIRE}.out
		if [ "${AUTONOMY_LOOP_DRY_RUN}" = "true" ]; then
			log "LOOP DRY RUN: WOULD FIRE ${FIRE} group=${GID} goals=${IDS} hashes=${HASHES} locks=$(echo ${LOCK_KEYS} | wc -w) prompt=${PFILE}"
			echo "WOULD FIRE ${FIRE} group=${GID} goals=${IDS} hashes=${HASHES}"
			supervisor_unlock_fds ${LOCK_FDS}
			continue
		fi
		rm -f "${WAKE_FLAG:?}"
		log "FIRE ${FIRE} BEGIN goals=${GOALS_SRC} group=${GID} group_goals=${IDS} worker=${K}/${N_GROUPS} cycle=${SUPERVISOR_CYCLE} hashes=${HASHES}"
		plane_sync fire-start --fire "${FIRE}" --goal-key "${KEY1}"
		W_START[K]=$(date +%s)
		kanban_sync fire-start --fire "${FIRE}" --started "${W_START[K]}" --goal-key "${KEY1}"
		if [ -z "${INBOX_WORKER}" ]; then
			INBOX_WORKER=${K}
			W_INBOX_PROMPT=${INBOX_PROMPT}
			W_SLACK_PROMPT=${SLACK_PROMPT}
			W_AFTER_TS=${SLACK_AFTER_TS}
		else
			W_INBOX_PROMPT=""
			W_SLACK_PROMPT=""
			W_AFTER_TS=""
		fi
		YOUR_GOALS=$(cat "${PFILE}")
		# the worker prompt (section 7): today's first line and steps, the YOUR GOALS section, the two gated scripts, no STOP step
		PROMPT="You are one fire of the do-agent-aws autonomy loop - a WORKER of its supervisor mode. Work exactly one cycle: Observe -> Act -> Persist -> Stop.${W_INBOX_PROMPT}
${YOUR_GOALS}
1. OBSERVE: read the goals file ${GOALS_SRC} and the progress notes ${AUTONOMY_LOOP_DIR}/notes.md if it exists; work only on YOUR GOALS above.
2. ACT: complete the single smallest unfinished increment of work toward your goals.
3. PERSIST: save your work to files; append your one-line progress note with ${AGENT_BIN_DIR}/notes-append.sh '<one line>'. When one of your goals' DONE condition holds, mark it with ${AGENT_BIN_DIR}/goals-mark.sh G<n> --note '<the evidence>'.
4. STOP: end after one increment. Do not create ${STOP_FLAG}: the loop creates it when every goal is done.${W_SLACK_PROMPT}"
		(
			# the worker's copy of the lock fds closes here: a process the worker leaves behind holds no group lock
			supervisor_unlock_fds ${LOCK_FDS}
			WORKER_GOAL_HASHES=${HASHES}
			WORKER_TAG="cycle ${SUPERVISOR_CYCLE} worker ${K}/${N_GROUPS} group ${GID}"
			SLACK_AFTER_TS=${W_AFTER_TS}
			WORKER_OPTS_ARGV=()
			[ -z "${SUPERVISOR_WORKER_OPTS}" ] || claude_opts_split WORKER_OPTS_ARGV "${SUPERVISOR_WORKER_OPTS}"
			fire_claude
			printf 'rc=%s\tduration=%s\toutcome=%s\n' "${RC}" "$(( $(date +%s) - W_START[K] ))" "${OUTCOME}" > "${FIRE_OUT%.out}.outcome"
			exit "${RC}"
		) &
		W_PID[K]=$!
		W_FIRE[K]=${FIRE}
		W_GID[K]=${GID}
		W_IDS[K]=${IDS}
		W_HASHES[K]=${HASHES}
		W_FDS[K]=${LOCK_FDS}
		FIRES_CSV="${FIRES_CSV:+${FIRES_CSV},}${FIRE}"
	done < "${DISPATCH_FILE}"
	if [ "${AUTONOMY_LOOP_DRY_RUN}" = "true" ]; then
		log "LOOP DRY RUN cycle ${SUPERVISOR_CYCLE}: ${K} worker(s) would fire (${SUMMARY}); no claude call"
		NEXT_SLEEP=0
		return 0
	fi
	if [ "${K}" -eq 0 ]; then
		log "LOOP SUPERVISOR cycle ${SUPERVISOR_CYCLE}: nothing dispatched (every group's locks were busy); next cycle in ${AUTONOMY_LOOP_INTERVAL}s"
		NEXT_SLEEP=${AUTONOMY_LOOP_INTERVAL}
		return 0
	fi
	state "FIRING fire=${FIRES_CSV} workers=${K} cycle=${SUPERVISOR_CYCLE} mode=supervisor"
	# wait: each worker is bounded by its own timeout (the cycle by the longest); each is recorded as a fire is today
	ANY_OK=no
	LAST_FIRE=""
	LAST_RC=""
	LAST_OUTCOME=""
	for (( I = 1; I <= K; I++ )); do
		wait "${W_PID[I]}"
		RC=$?
		FIRE=${W_FIRE[I]}
		FIRE_OUT=${AUTONOMY_LOOP_DIR}/fires/fire-${FIRE}.out
		DURATION=$(( $(date +%s) - W_START[I] ))
		OUTLINE=$(cat "${FIRE_OUT%.out}.outcome" 2>/dev/null)
		case "${OUTLINE}" in
			rc=*) DURATION=${OUTLINE#*duration=}; DURATION=${DURATION%%$'\t'*}; OUTCOME=${OUTLINE#*outcome=} ;;
			*) OUTCOME="error worker ended without its outcome record (exit status ${RC})" ;;
		esac
		supervisor_unlock_fds ${W_FDS[I]}
		log "FIRE ${FIRE} END rc=${RC} duration=${DURATION}s outcome=${OUTCOME} group=${W_GID[I]} cycle=${SUPERVISOR_CYCLE}"
		# the fire's inbox record, then its receipts: nothing it was handed is marked read before this point
		[ "${I}" = "${INBOX_WORKER}" ] && [ -n "${INBOX_IDS}" ] && inbox_record
		# the Loop Deck's inputs follow the fire (loop-deck-adapter.py reads this log); best effort, the fire is unaffected
		[ -f "${LOOP_DECK_ADAPTER_BIN}" ] && timeout 30 python3 -I "${LOOP_DECK_ADAPTER_BIN}" >> "${AUTONOMY_LOOP_DIR}/loop-deck-adapter.log" 2>&1 || true
		kanban_sync fire-end --fire "${FIRE}" --started "${W_START[I]}" --rc "${RC}" --duration "${DURATION}" --out "${FIRE_OUT}"
		[ "${I}" = "${INBOX_WORKER}" ] && fire_slack_settle
		plane_sync fire-end --fire "${FIRE}" --rc "${RC}" --duration "${DURATION}" --out "${FIRE_OUT}"
		case "${RC}" in
			0) ANY_OK=yes; supervisor_clear_strikes ${W_HASHES[I]} ;;
			124 | 137 | 96 | 97) ;;
			*) supervisor_strikes "${FIRE}" "${RC}" ${W_HASHES[I]} ;;
		esac
		LAST_FIRE=${FIRE}
		LAST_RC=${RC}
		LAST_OUTCOME=${OUTCOME%% *}
	done
	if [ -n "${PARKED_NOW}" ]; then
		timeout 70 "${AGENT_BIN_DIR}/notes-append.sh" "- $(date -u +%Y-%m-%dT%H:%M:%SZ) loop supervisor cycle ${SUPERVISOR_CYCLE}: parked goal hash(es) ${PARKED_NOW} after ${SUPERVISOR_STRIKES_MAX} fires in a row that did not end well; retried after ${SUPERVISOR_PARK_CYCLES} cycles, or sooner with goals-add.sh --unpark G<n> (the hash is in the plan files under ${SUPERVISOR_DIR})" >> "${SUPERVISOR_DIR}/notes-append.log" 2>&1 \
			|| log "LOOP SUPERVISOR WARNING the parking notes line was not appended (see ${SUPERVISOR_DIR}/notes-append.log)"
	fi
	# the next cycle starts at once while a worker ended well; a cycle whose workers all failed waits the interval
	if [ "${ANY_OK}" = "yes" ]; then NEXT_SLEEP=0; else NEXT_SLEEP=${AUTONOMY_LOOP_INTERVAL}; fi
	state "SLEEPING last_fire=${LAST_FIRE} last_rc=${LAST_RC} last_outcome=${LAST_OUTCOME} interval=${NEXT_SLEEP}s mode=supervisor cycle=${SUPERVISOR_CYCLE} workers=${K}"
	return 0
}

# Single-instance guard
exec 9> "${LOCK_FILE}"
if ! flock -n 9; then
	echo "Autonomy loop already running (lock ${LOCK_FILE} held); exiting."
	exit 0
fi

trap 'log "LOOP EXIT signal received"; state "STOPPED reason=signal"; exit 0' TERM INT

log "LOOP START interval=${AUTONOMY_LOOP_INTERVAL}s goals=${AUTONOMY_LOOP_GOALS} fire_timeout=${AUTONOMY_LOOP_FIRE_TIMEOUT}s workdir=${AUTONOMY_LOOP_WORKDIR}"
log "LOOP MODE ${LOOP_MODE}${LOOP_MODE_WARNING:+ (${LOOP_MODE_WARNING})}$( [ "${LOOP_MODE}" = "supervisor" ] && echo " max_workers=${SUPERVISOR_MAX_WORKERS} strikes_max=${SUPERVISOR_STRIKES_MAX} park_cycles=${SUPERVISOR_PARK_CYCLES} planner=${SUPERVISOR_PLAN_BIN} plans=${SUPERVISOR_DIR} locks=${LOCKS_DIR}" )$( [ "${AUTONOMY_LOOP_DRY_RUN}" = "true" ] && echo " DRY RUN: one cycle, no claude call, then exit" )"
if [ "${LOOP_MODE}" = "supervisor" ] && [ "${SUPERVISOR_MODEL_PASS}" = "true" ]; then
	log "LOOP WARNING SUPERVISOR_MODEL_PASS=true: the model pass is not implemented in this version; the deterministic plan stands"
fi
if [ "${AUTONOMY_LOOP_DRY_RUN}" = "true" ]; then
	LOOP_SLACK_INTAKE=off
	LOOP_INBOX=false
fi
# the option string's check (claude_opts_check; see the header "The fire's claude call"): said once here, then on every fire it skips
if [ -n "${FIRE_OPTS_REPORT}" ]; then
	if [ "${AUTONOMY_LOOP_OPTS_CHECK}" != "false" ]; then
		log "LOOP CONFIG AUTONOMY_LOOP_CLAUDE_OPTS: ${FIRE_OPTS_REPORT}; every fire is skipped with no claude call (END rc=96 outcome=config) until the value is fixed - set it in .env.local and recreate the container, or set AUTONOMY_LOOP_OPTS_CHECK=false to run the fires anyway"
	else
		log "LOOP WARNING AUTONOMY_LOOP_CLAUDE_OPTS: ${FIRE_OPTS_REPORT}; the fires run anyway (AUTONOMY_LOOP_OPTS_CHECK=false): claude ignores that rule, says so at the top of each transcript, and denies every call it would have allowed"
	fi
fi
if [ "${SLACK_CHAT_EFFECTIVE}" = "on" ]; then
	log "LOOP SLACK intake owned by /agent/slack-chat.sh (chat gate on: ${SLACK_CHAT_REASON}) - this loop runs no watch and hands no inbox to fires; goals stated in chat arrive in ${AUTONOMY_LOOP_GOALS}"
elif [ "${LOOP_SLACK_INTAKE}" = "on" ]; then
	log "LOOP SLACK watch on (${SLACK_WATCH_REASON}); post gate ${SLACK_POST_EFFECTIVE} (${SLACK_POST_REASON})"
fi

cd "${AUTONOMY_LOOP_WORKDIR}"

while true; do

	if [ -f "${STOP_FLAG}" ]; then
		log "LOOP STOPPED stop flag ${STOP_FLAG} present"
		state "STOPPED reason=stop-flag"
		exit 0
	fi

	# Slack watch, when the watch gate is on (slack-gates.sh): poll the channels ONCE per cycle,
	# before deciding whether to fire, so new messages are seen even while no goals file exists.
	# slack-watch.sh only ever appends, so the head of the inbox is stable while a fire runs and
	# the same lines are moved to processed.jsonl afterwards. A failed watch is logged loud but
	# does not block the cycle. Keep this block in sync with loop-once.sh.
	INBOX_DEPTH=0
	if [ "${LOOP_SLACK_INTAKE}" = "on" ]; then
		if ! "${SLACK_WATCH_BIN}" >> "${AUTONOMY_LOOP_DIR}/slack-watch.log" 2>&1; then
			log "LOOP SLACK WATCH FAILED (see ${AUTONOMY_LOOP_DIR}/slack-watch.log); continuing with the inbox as it stands"
		fi
		INBOX_DEPTH=$(count_lines "${SLACK_DIR}/inbox.jsonl")
	fi

	# What this cycle fires against: the user goals file when it exists; else the shipped default
	# goals when Slack messages are waiting; else nothing - idle, no claude call
	GOALS_SRC=""
	GOALS_MODE=""
	if [ -f "${AUTONOMY_LOOP_GOALS}" ]; then
		GOALS_SRC=${AUTONOMY_LOOP_GOALS}
		GOALS_MODE=user
	elif [ "${LOOP_SLACK_INTAKE}" = "on" ] && [ "${INBOX_DEPTH}" -gt 0 ]; then
		if [ -f "${AUTONOMY_LOOP_DEFAULT_GOALS}" ]; then
			GOALS_SRC=${AUTONOMY_LOOP_DEFAULT_GOALS}
			GOALS_MODE=default
		else
			log "LOOP IDLE goals file ${AUTONOMY_LOOP_GOALS} not found; ${INBOX_DEPTH} unprocessed Slack message(s) waiting but the default goals file ${AUTONOMY_LOOP_DEFAULT_GOALS} is missing - restore it or set AUTONOMY_LOOP_DEFAULT_GOALS"
			state "IDLE reason=default-goals-file-missing"
		fi
	elif [ "${LOOP_SLACK_INTAKE}" = "on" ]; then
		log "LOOP IDLE goals file ${AUTONOMY_LOOP_GOALS} not found; Slack watch ran, inbox empty - the loop fires on the next Slack message or when the goals file appears"
		state "IDLE reason=no-goals-file"
	else
		log "LOOP IDLE goals file ${AUTONOMY_LOOP_GOALS} not found"
		state "IDLE reason=no-goals-file"
	fi

	# The mode: supervisor runs supervisor_cycle on the user goals file - the planner, one worker per group; its
	# return 1 (the planner failed) and the serial mode run the one fire below, unchanged. NEXT_SLEEP is the pause after
	# this cycle (the interval, or 0 when a supervisor worker ended well)
	NEXT_SLEEP=${AUTONOMY_LOOP_INTERVAL}
	SERIAL_FIRE=yes
	if [ -n "${GOALS_SRC}" ] && [ "${LOOP_MODE}" = "supervisor" ] && [ "${GOALS_MODE}" = "user" ]; then
		if supervisor_cycle; then SERIAL_FIRE=no; fi
	fi
	if [ -n "${GOALS_SRC}" ] && [ "${SERIAL_FIRE}" = "yes" ]; then
		if [ "${AUTONOMY_LOOP_DRY_RUN}" = "true" ]; then
		# the dry run of the serial fire: the number it would get and the file, no claude call
		FIRE=$(( $(completed_fires) + 1 ))
		log "LOOP DRY RUN mode=serial: WOULD FIRE ${FIRE} goals=${GOALS_SRC} (one fire on the first open goal in file order); no claude call"
		echo "WOULD FIRE ${FIRE} mode=serial goals=${GOALS_SRC}"
		else
		FIRE=$(( $(completed_fires) + 1 ))
		FIRE_OUT=${AUTONOMY_LOOP_DIR}/fires/fire-${FIRE}.out
		BEGIN="FIRE ${FIRE} BEGIN goals=${GOALS_SRC}"
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
		rm -f "${WAKE_FLAG:?}"
		plane_sync fire-start --fire "${FIRE}"
		state "FIRING fire=${FIRE}"
		FIRE_START=$(date +%s)
		kanban_sync fire-start --fire "${FIRE}" --started "${FIRE_START}"
		# Hand the oldest unprocessed inbox lines (watched above, never re-polled here) to this
		# fire. Replying stays the agent's choice via /agent/slack-post.sh, behind its own post
		# gate (SLACK_POST_ENABLED, decided in slack-gates.sh); the prompt states that gate's state.
		fire_slack_context
		# The bus intake (see "Bus intake" in the header; loop-inbox.sh): the hub's open requests and notices, read
		# without a receipt, into INBOX_PROMPT, which the prompt carries after its first line, before the goals
		inbox_read
		PROMPT="You are one fire of the do-agent-aws autonomy loop. Work exactly one cycle: Observe -> Act -> Persist -> Stop.${INBOX_PROMPT}
1. OBSERVE: read the goals file ${GOALS_SRC}, and the progress notes ${AUTONOMY_LOOP_DIR}/notes.md if it exists.${DEFAULT_NOTE}
2. ACT: complete the single smallest unfinished increment of work toward the goals.
3. PERSIST: save your work to files; append a one-line progress note to ${AUTONOMY_LOOP_DIR}/notes.md.${MARK_STEP}
4. STOP: end after one increment. ${STOP_STEP}${SLACK_PROMPT}"
		# Prompt on stdin, options from FIRE_OPTS_ARGV - AUTONOMY_LOOP_CLAUDE_OPTS split by claude_opts_split (see the header:
		# the variadic --allowedTools would swallow a positional prompt). Keep in sync with loop-once.sh.
		# The fire is the hub on the bus (see "Bus intake"): BUS_AGENT_ID, and no TMUX or TMUX_PANE of the loop's.
		# SLACK_POST_AFTER_TS: the newest message the fire was handed (see loop-once.sh; kept in sync)
		fire_claude
		log "FIRE ${FIRE} END rc=${RC} duration=$(( $(date +%s) - FIRE_START ))s outcome=${OUTCOME}"
		# the fire's inbox record, then its receipts: nothing it was handed is marked read before this point
		[ -n "${INBOX_IDS}" ] && inbox_record
		# the Loop Deck's inputs follow the fire (loop-deck-adapter.py reads this log); best effort, the fire is unaffected
		[ -f "${LOOP_DECK_ADAPTER_BIN}" ] && timeout 30 python3 -I "${LOOP_DECK_ADAPTER_BIN}" >> "${AUTONOMY_LOOP_DIR}/loop-deck-adapter.log" 2>&1 || true
		kanban_sync fire-end --fire "${FIRE}" --started "${FIRE_START}" --rc "${RC}" \
			--duration "$(( $(date +%s) - FIRE_START ))" --out "${FIRE_OUT}"
		fire_slack_settle
		plane_sync fire-end --fire "${FIRE}" --rc "${RC}" --duration "$(( $(date +%s) - FIRE_START ))" --out "${FIRE_OUT}"
		state "SLEEPING last_fire=${FIRE} last_rc=${RC} last_outcome=${OUTCOME%% *} interval=${AUTONOMY_LOOP_INTERVAL}s"
		fi
	fi
	if [ "${AUTONOMY_LOOP_DRY_RUN}" = "true" ]; then
		log "LOOP DRY RUN complete (mode=${LOOP_MODE}): exiting; no claude call was made"
		state "STOPPED reason=dry-run"
		exit 0
	fi


	# Sleep in short steps so a STOP flag takes effect promptly and a WAKE flag ("Run next fire") starts the next cycle
	SLEPT=0
	while [ "${SLEPT}" -lt "${NEXT_SLEEP}" ] && [ ! -f "${STOP_FLAG}" ] && [ ! -f "${WAKE_FLAG}" ]; do
		sleep 5
		SLEPT=$((SLEPT + 5))
	done
	if [ -f "${WAKE_FLAG}" ]; then
		rm -f "${WAKE_FLAG:?}"
		log "LOOP WAKE ${WAKE_FLAG} found after ${SLEPT}s of ${NEXT_SLEEP}s: starting the next cycle now"
	fi

done
