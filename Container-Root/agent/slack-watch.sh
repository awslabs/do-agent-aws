#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Slack channel watcher - one cursor-based poll of the channels in SLACK_CHANNELS.
#
# For each configured channel the watcher fetches the messages newer than the persisted cursor
# (conversations.history) and appends them to the inbox, one JSON object per line
# (ts/channel/user/text, plus thread_ts when the message belongs to a thread), oldest first; the
# cursor advances only once they are in the inbox, so a run that fails on a later call (a 429, a
# timeout) leaves it where it was and the next run brings the same messages, none lost. THREAD REPLIES ARE INVISIBLE TO conversations.history:
# a reply only updates the parent's reply_count, and a parent older than the cursor is never
# returned again - so every thread parent this watcher has seen is remembered in a per-channel
# thread registry and its replies are collected with conversations.replies on every run.
# conversations.replies answers with the thread's parent first on every call, whatever oldest says,
# so only the replies after the thread's own cursor are taken from it: never the parent, which
# history already brought, and nothing at or before the cursor, which an earlier run brought.
# Replies to threads whose parent was never seen by the watcher (parent predates the first
# watch) are not visible to a poller and are not collected - see docs/slack/README.md.
# Recent top-level messages get a bounded watch of their own, because a reply may be threaded under
# one after the watcher saw it with no replies: the agent's own posts (a person answers one in a
# thread) and the people's messages (a person goes on in a thread under their own question) - the
# answers-<channel> and asks-<channel> lists below.
# All those conversations.replies calls share ONE rolling budget: at most SLACK_REPLIES_BUDGET calls
# (default 30) in any SLACK_REPLIES_WINDOW seconds (default 60), across every channel, the thread
# registry and the two lists - Slack's limit for the method is about 50 a minute per app and
# workspace, and the chat responder runs this watcher every few seconds. Each run polls the least
# recently polled threads first, as many as the budget leaves (${SLACK_DIR}/replies-calls holds one
# epoch per call made, pruned to the window), and defers the rest to a later run; a reply in a deferred
# thread waits, it is not lost. The run goes in three phases: history read and the threads to poll
# listed, per channel; the replies calls; then, per channel, everything read put in the inbox at once
# (oldest first, each message once, one checked append per channel, under the inbox lock every inbox
# writer takes - ${SLACK_DIR}/inbox.lock, shared with the chat responder's and the loop's removals of
# handled lines, so no append lands in a file a consumer's sed -i is replacing) and the cursors, registry
# and lists written - so a run that fails on any call or on the append itself (exit 1) moves no cursor, and the next run brings the same
# messages again.
#
# The watcher runs once and exits; the Slack chat responder /agent/slack-chat.sh (when the chat gate
# is on), the autonomy loop (when the chat gate is off and its watch gate is on - see
# /agent/slack-gates.sh) or an operator invokes it per poll. It never posts - posting is
# /agent/slack-post.sh behind its own post gate. It fails loud (nonzero exit, clear message) when the token is empty
# or authentication fails - never a silent no-op.
#
# State lives on the /wd volume so it survives container replacement (see .env):
#   ${SLACK_DIR}/inbox.jsonl       - unprocessed messages, one JSON object per line
#   ${SLACK_DIR}/processed.jsonl   - messages already handled (moved by slack-chat.sh, or by a loop
#                                    fire when the chat gate is off)
#   ${SLACK_DIR}/inbox.lock        - the lock every inbox writer holds while it appends to or removes from
#                                    inbox.jsonl (this script, slack-chat.sh, loop.sh, loop-once.sh)
#   ${SLACK_DIR}/cursor-<channel>  - newest channel-history ts already ingested
#   ${SLACK_DIR}/threads-<channel> - thread registry: "<parent_ts> <newest_ingested_reply_ts> <epoch of
#                                    the last replies call for it>" per line (a line without the third
#                                    field, as slack-post.sh writes one, is polled first)
#   ${SLACK_DIR}/answers-<channel> - the agent's recent top-level posts (listed by slack-post.sh) and
#   ${SLACK_DIR}/asks-<channel>      the people's (listed here), "<ts> <expiry epoch> [<epoch of the
#                                    last replies call>]" per line, each watched for a first reply
#                                    threaded under it
#   ${SLACK_DIR}/replies-calls     - the budget ledger: one epoch per conversations.replies call made
#   ${SLACK_DIR}/replies-failed    - "<channel> <ts> <failures in a row> <epoch of the last>" per thread whose
#                                    replies call answered an API error (ok:false other than thread_not_found, or
#                                    no JSON); a thread at SLACK_THREAD_FAIL_SKIP failures is skipped for
#                                    SLACK_THREAD_FAIL_BACKOFF seconds, logged, so one broken thread does not
#                                    hold every channel's intake (a failed call still ends the run, see below).
#                                    An HTTP 429 or a transport failure (a timeout, a lost connection) does not
#                                    count: a rate limit is the budget's and the Retry-After pause's business, and
#                                    a timeout clears by itself - counting them would park healthy threads
#   ${SLACK_DIR}/identity          - "user_id=<bot> team=<team>" from auth.test (the agent's own identity)
#   ${SLACK_DIR}/last-watch        - one-line summary of the last completed run
#   ${SLACK_DIR}/retry-after       - Slack's Retry-After seconds after an HTTP 429, for slack-chat.sh
#
# Settings (from .env / environment):
#   SLACK_BOT_TOKEN      - bot token (xoxb-...) of the user's own Slack app <required>; it reaches
#                          curl only through its config on stdin (api_get), never as a word of a
#                          command line (every local user can read those in ps) or in an xtrace
#   SLACK_CHANNELS       - comma-separated channel IDs to watch <required>
#   SLACK_ALLOWED_USERS  - comma-separated Slack user IDs (U..., W...) whose messages reach the inbox, or the one word
#                          anyone for every person in the channels. EMPTY (the default) takes no one's message: the
#                          agent acts on what the inbox says, so the people who may drive it are named, not assumed.
#                          A message from another bot (bot_id, or subtype bot_message) never reaches the inbox; the
#                          agent's own posts do, as before (the responder and the loop recognize and skip them).
#                          A message that is not taken still moves the cursor and still registers its thread (an
#                          allowed person's reply in that thread is taken); the run's line counts what was not taken
#   SLACK_API_BASE       - Slack Web API base (default https://slack.com/api); the offline
#                          smoke /test4.sh points this at a local stub - no real Slack call
#   SLACK_DIR            - state directory (default /wd/slack)
#   SLACK_THREAD_MAX_AGE - seconds after which a thread parent is retired from the registry
#                          and its replies stop being polled (default 604800 = 7 days)
#   SLACK_ANSWER_POLL_INTERVAL - at most this often (seconds, default 60) the recent top-level
#                          messages listed in answers-<channel> and asks-<channel> are checked for a
#                          threaded reply
#   SLACK_ANSWER_WATCH_SECONDS, SLACK_ANSWER_WATCH_MAX - how long (default 7200 s) a person's new
#                          top-level message is listed in asks-<channel>, and how many of the newest
#                          stay listed (default 5); slack-post.sh uses the same two for answers-<channel>
#   SLACK_REPLIES_BUDGET, SLACK_REPLIES_WINDOW - at most this many conversations.replies calls (default
#                          30) in any window of this many seconds (default 60), across everything this
#                          watcher polls; the rest wait for a later run, least recently polled first
#   SLACK_THREAD_FAIL_SKIP, SLACK_THREAD_FAIL_BACKOFF - after this many replies calls in a row answered
#                          with an API error (default 3) a thread is skipped for this many seconds (default
#                          600), logged; a 429 or a transport failure is not counted

SLACK_API_BASE=${SLACK_API_BASE:-https://slack.com/api}
SLACK_DIR=${SLACK_DIR:-/wd/slack}
SLACK_THREAD_MAX_AGE=${SLACK_THREAD_MAX_AGE:-604800}
SLACK_ANSWER_POLL_INTERVAL=${SLACK_ANSWER_POLL_INTERVAL:-60}
SLACK_ANSWER_WATCH_SECONDS=${SLACK_ANSWER_WATCH_SECONDS:-7200}
SLACK_ANSWER_WATCH_MAX=${SLACK_ANSWER_WATCH_MAX:-5}
SLACK_REPLIES_BUDGET=${SLACK_REPLIES_BUDGET:-30}
SLACK_REPLIES_WINDOW=${SLACK_REPLIES_WINDOW:-60}
SLACK_THREAD_FAIL_SKIP=${SLACK_THREAD_FAIL_SKIP:-3}
SLACK_THREAD_FAIL_BACKOFF=${SLACK_THREAD_FAIL_BACKOFF:-600}
SLACK_ALLOWED_USERS=${SLACK_ALLOWED_USERS:-}

# Absolute path - may run detached without a login shell PATH (same pattern as loop.sh CLAUDE_BIN);
# node is used to parse Slack JSON because the image ships node (for Claude Code) but not jq.
NODE_BIN=${NODE_BIN:-/usr/local/bin/node}
[ -x "${NODE_BIN}" ] || NODE_BIN=$(command -v node)

err()
{
	echo "ERROR: $*" >&2
}

count_lines()
{
	C=$(grep -c . "$1" 2>/dev/null)
	echo "${C:-0}"
}

if [ -z "${NODE_BIN}" ]; then
	err "node not found (looked at /usr/local/bin/node and PATH); set NODE_BIN"
	exit 1
fi

if [ -z "${SLACK_BOT_TOKEN:+set}" ]; then
	err "SLACK_BOT_TOKEN is empty - set it in .env.local or the host environment (see docs/slack/README.md); refusing to run silently"
	exit 1
fi

if [ -z "${SLACK_CHANNELS}" ]; then
	err "SLACK_CHANNELS is empty - set the comma-separated channel IDs to watch in .env.local (see docs/slack/README.md)"
	exit 1
fi

# The sender allowlist: user IDs, or the one word anyone - a value that is neither is refused loud, never read as "no one"
# or "everyone" by accident
for U in ${SLACK_ALLOWED_USERS//,/ }; do
	if [ "${U}" == "anyone" ]; then
		[ "${SLACK_ALLOWED_USERS}" == "anyone" ] || { err "SLACK_ALLOWED_USERS: anyone stands alone, not beside user IDs (${SLACK_ALLOWED_USERS})"; exit 1; }
	elif ! [[ "${U}" =~ ^[UW][A-Z0-9]{2,}$ ]]; then
		err "SLACK_ALLOWED_USERS: '${U}' is not a Slack user ID (U... or W..., comma-separated) or the word anyone"
		exit 1
	fi
done

mkdir -p "${SLACK_DIR}"

INBOX=${SLACK_DIR}/inbox.jsonl

# Single-instance guard - two concurrent watchers would double-append and race the cursors
exec 9> "${SLACK_DIR}/watch.lock"
if ! flock -n 9; then
	echo "Another slack-watch is already running (lock ${SLACK_DIR}/watch.lock held); exiting."
	exit 0
fi

# Shared JSON parser for conversations.history / conversations.replies responses.
# stdin: raw API response; argv: <channel> <the agent's own user id> <SLACK_ALLOWED_USERS>
# stdout, tab-separated:
#   ERR\t<error>                     when ok:false
#   MSG\t<ts>\t<one-line JSON>[\t<why not taken>]
#                                    per message (ts/channel/user/text; thread_ts when in a thread); a 4th field
#                                    bot (another bot's message) or sender (a person SLACK_ALLOWED_USERS does not
#                                    name) marks one that moves the cursor but never reaches the inbox
#   THR\t<parent_ts>                 per thread parent discovered (reply_count>0 or a reply's thread_ts)
#   TOP\t<ts>\t<user>                per top-level message from a user with no thread yet
#   NEXT\t<cursor>                   when the response has another page
PARSE_MESSAGES='
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
	let r;
	try { r = JSON.parse(raw); } catch (e) { console.log("ERR\tunparseable-response"); return; }
	if (!r.ok) { console.log("ERR\t" + (r.error || "unknown-error")); return; }
	const channel = process.argv[1];
	const self = process.argv[2] || "";
	const allow = (process.argv[3] || "").split(",").filter(Boolean);
	for (const m of (r.messages || [])) {
		if (!m.ts) continue;
		const o = { ts: m.ts, channel: channel, user: m.user || m.bot_id || "", text: m.text || "" };
		if (m.thread_ts) o.thread_ts = m.thread_ts;
		const own = self !== "" && m.user === self;
		const bot = !own && !!(m.bot_id || m.subtype === "bot_message");
		const sender = !own && !bot && !(allow[0] === "anyone" || (m.user && allow.includes(m.user)));
		console.log("MSG\t" + m.ts + "\t" + JSON.stringify(o) + (bot ? "\tbot" : sender ? "\tsender" : ""));
		if (m.reply_count && m.reply_count > 0) console.log("THR\t" + m.ts);
		if (m.thread_ts && m.thread_ts !== m.ts) console.log("THR\t" + m.thread_ts);
		if (m.user && !bot && !sender && !m.thread_ts && !(m.reply_count > 0) && (!m.subtype || m.subtype === "file_share"))
			console.log("TOP\t" + m.ts + "\t" + m.user);
	}
	const next = r.response_metadata && r.response_metadata.next_cursor;
	if (r.has_more && next) console.log("NEXT\t" + next);
});
'

# The MSG lines of a parsed conversations.replies answer that are new replies: not the thread's
# parent (awk -v parent=<ts>) and later than the thread's cursor (-v cursor=<ts>).
# shellcheck disable=SC2016 # $1 and $2 are awk fields, not shell expansions
NEW_REPLIES='$1 == "MSG" && $2 != parent && ($2 + 0) > (cursor + 0)'

api_get()
{
	# api_get <method> <curl -G data-urlencode args...> - body on stdout; an HTTP 429 records
	# Slack's Retry-After seconds in ${SLACK_DIR}/retry-after for the caller (slack-chat.sh sleeps
	# that long before its next poll); the body then says ratelimited and the run fails loud as usual
	METHOD=$1; shift
	ARGS=()
	for A in "$@"; do
		ARGS+=(--data-urlencode "${A}")
	done
	HDRS=$(mktemp)
	if ! curl -sS --max-time 30 -D "${HDRS}" -K - \
		-G "${SLACK_API_BASE}/${METHOD}" "${ARGS[@]}" 2>> "${SLACK_DIR}/curl.err" \
		<<< "header = \"Authorization: Bearer ${SLACK_BOT_TOKEN}\""; then
		rm -f "${HDRS:?}"
		err "curl to ${SLACK_API_BASE}/${METHOD} failed (see ${SLACK_DIR}/curl.err)"
		return 1
	fi
	if head -1 "${HDRS}" | grep -q " 429"; then
		RETRY_AFTER=$(grep -i '^Retry-After:' "${HDRS}" | tail -1 | tr -d '\r' | awk '{print $2}')
		echo "${RETRY_AFTER:-30}" > "${SLACK_DIR}/retry-after"
		err "Slack rate limited ${METHOD} (HTTP 429, Retry-After ${RETRY_AFTER:-unknown}s; recorded in ${SLACK_DIR}/retry-after)"
	fi
	rm -f "${HDRS:?}"
}

max_ts()
{
	# highest ts in column 2 of a MSG-line file; empty when no lines
	cut -f2 "$1" 2>/dev/null | sort -n | tail -1
}

# Authenticate loud and record the bot's own identity (the loop uses it to recognize the
# agent's own posts in the inbox). A bad or revoked token fails the whole run here.
AUTH=$(api_get auth.test) || exit 1
AUTH_LINE=$(echo "${AUTH}" | "${NODE_BIN}" -e '
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
	let r;
	try { r = JSON.parse(raw); } catch (e) { console.log("ERR\tunparseable-response"); return; }
	if (!r.ok) { console.log("ERR\t" + (r.error || "unknown-error")); return; }
	console.log("OK\tuser_id=" + (r.user_id || "") + " team=" + (r.team || "") + " user=" + (r.user || ""));
});
')
case "${AUTH_LINE}" in
ERR*)
	err "Slack authentication failed: $(echo "${AUTH_LINE}" | cut -f2-) - check SLACK_BOT_TOKEN (auth.test at ${SLACK_API_BASE})"
	exit 1
	;;
OK*)
	echo "${AUTH_LINE}" | cut -f2- > "${SLACK_DIR}/identity"
	;;
*)
	err "unexpected auth.test parse result: ${AUTH_LINE}"
	exit 1
	;;
esac

NOW=$(date +%s)
TOTAL_NEW=0
TOTAL_REPLIES=0

# --- the conversations.replies budget (see the header): the ledger pruned to the window, what is left ---
LEDGER=${SLACK_DIR}/replies-calls
awk -v since="$(( NOW - SLACK_REPLIES_WINDOW ))" '$1 > since' "${LEDGER}" 2>/dev/null > "${LEDGER:?}.tmp" && mv "${LEDGER:?}.tmp" "${LEDGER:?}"
REMAINING=$(( SLACK_REPLIES_BUDGET - $(count_lines "${LEDGER}") ))
[ "${REMAINING}" -lt 0 ] && REMAINING=0

# Per-thread state across the channels, keyed "<channel> <parent_ts>": the reply cursor (the newest reply
# ingested; the parent ts until there is one) and the epoch of the last replies call for it (0: never)
declare -A THREAD_CURSOR=()
declare -A THREAD_POLLED=()
# Per channel: the history read this run and its newest ts, the replies batch, the counts; per list
# ("<channel> answer|ask"): the lines kept, and whether the lists were due this run
declare -A CH_HIST=()
declare -A CH_MAXTS=()
declare -A CH_REPL=()
declare -A CH_NEW=()
declare -A CH_REPLY_COUNT=()
declare -A LIST_KEEP=()
declare -A LIST_DUE=()
CANDIDATES=$(mktemp)      # "<last polled> <channel> <kind> <ts> <expiry or ->", kind thread|answer|ask
SELF_ID=$(sed -n 's/.*user_id=\([^ ]*\).*/\1/p' "${SLACK_DIR}/identity")
# Failed replies calls, per thread, kept outside the commit point: "<channel> <ts> <failures in a row> <epoch>"
FAILED_FILE=${SLACK_DIR}/replies-failed
declare -A THREAD_FAILS=()
declare -A THREAD_FAILED_AT=()
if [ -f "${FAILED_FILE}" ]; then
	while read -r F_CH F_TS F_N F_AT; do
		[ -n "${F_TS}" ] && THREAD_FAILS["${F_CH} ${F_TS}"]=${F_N:-0} && THREAD_FAILED_AT["${F_CH} ${F_TS}"]=${F_AT:-0}
	done < "${FAILED_FILE}"
fi

# replies_failed <channel> <ts> - one more API error for that thread, recorded at once (the run ends)
replies_failed()
{
	N=$(( ${THREAD_FAILS["$1 $2"]:-0} + 1 ))
	{ awk -v ch="$1" -v ts="$2" '!($1 == ch && $2 == ts)' "${FAILED_FILE}" 2>/dev/null; echo "$1 $2 ${N} ${NOW}"; } > "${FAILED_FILE:?}.tmp" && mv "${FAILED_FILE:?}.tmp" "${FAILED_FILE:?}"
	[ "${N}" -ge "${SLACK_THREAD_FAIL_SKIP}" ] && echo "Channel $1: thread $2 failed ${N} replies call(s) in a row; it is skipped for ${SLACK_THREAD_FAIL_BACKOFF}s from now so the other threads and the channels' history get through"
}

# replies_ok <channel> <ts> - a call succeeded: the thread's failures are forgotten
replies_ok()
{
	[ -n "${THREAD_FAILS["$1 $2"]}" ] || return 0
	awk -v ch="$1" -v ts="$2" '!($1 == ch && $2 == ts)' "${FAILED_FILE}" 2>/dev/null > "${FAILED_FILE:?}.tmp" && mv "${FAILED_FILE:?}.tmp" "${FAILED_FILE:?}"
	unset "THREAD_FAILS[$1 $2]" "THREAD_FAILED_AT[$1 $2]"
}

# skipping <channel> <ts> - true while a thread with SLACK_THREAD_FAIL_SKIP failures in a row is in its backoff
skipping()
{
	[ "${THREAD_FAILS["$1 $2"]:-0}" -ge "${SLACK_THREAD_FAIL_SKIP}" ] && [ $(( NOW - ${THREAD_FAILED_AT["$1 $2"]:-0} )) -lt "${SLACK_THREAD_FAIL_BACKOFF}" ]
}

cleanup_run()
{
	rm -f "${CANDIDATES:?}" "${CANDIDATES:?}.sorted"
	for C in "${!CH_REPL[@]}"; do T_REPL=${CH_REPL[${C}]}; T_HIST=${CH_HIST[${C}]}; rm -f "${T_REPL:?}" "${T_HIST:?}"; done
}

# --- phase 1, per channel: history since the cursor read (into the inbox only in phase 3); the thread
# registry and the answers/asks lists read, and every replies call worth making listed as a candidate ---
for CHANNEL in $(echo "${SLACK_CHANNELS}" | tr ',' ' '); do

	CURSOR_FILE=${SLACK_DIR}/cursor-${CHANNEL}
	THREADS_FILE=${SLACK_DIR}/threads-${CHANNEL}
	CH_REPL[${CHANNEL}]=$(mktemp)
	CH_HIST[${CHANNEL}]=$(mktemp)
	HIST_MSGS=${CH_HIST[${CHANNEL}]}

	# First watch of a channel starts at "now" - history is not backfilled (see docs/slack/README.md)
	if [ ! -f "${CURSOR_FILE}" ]; then
		echo "${NOW}.000000" > "${CURSOR_FILE}"
		echo "Channel ${CHANNEL}: cursor initialized to now (${NOW}.000000); watching messages from this point on"
	fi
	CURSOR=$(cat "${CURSOR_FILE}")

	# --- channel history since the cursor, following pagination ---
	NEW_PARENTS=$(mktemp)
	NEW_TOPS=""
	PAGE_CURSOR=""
	while true; do
		PAGE_ARGS=("channel=${CHANNEL}" "oldest=${CURSOR}" "limit=200")
		[ -n "${PAGE_CURSOR}" ] && PAGE_ARGS+=("cursor=${PAGE_CURSOR}")
		RESP=$(api_get conversations.history "${PAGE_ARGS[@]}") || { rm -f "${NEW_PARENTS:?}"; cleanup_run; exit 1; }
		PARSED=$(echo "${RESP}" | "${NODE_BIN}" -e "${PARSE_MESSAGES}" "${CHANNEL}" "${SELF_ID}" "${SLACK_ALLOWED_USERS}")
		E=$(echo "${PARSED}" | grep "^ERR" | head -1 | cut -f2)
		if [ -n "${E}" ]; then
			err "conversations.history failed for channel ${CHANNEL}: ${E}"
			rm -f "${NEW_PARENTS:?}"
			cleanup_run
			exit 1
		fi
		echo "${PARSED}" | grep "^MSG" >> "${HIST_MSGS}"
		echo "${PARSED}" | grep "^THR" | cut -f2 >> "${NEW_PARENTS}"
		NEW_TOPS="${NEW_TOPS}$(echo "${PARSED}" | grep "^TOP" | cut -f2,3)
"
		PAGE_CURSOR=$(echo "${PARSED}" | grep "^NEXT" | head -1 | cut -f2)
		[ -z "${PAGE_CURSOR}" ] && break
	done
	NEW_COUNT=$(grep -c "^MSG" "${HIST_MSGS}" 2>/dev/null)
	CH_NEW[${CHANNEL}]=${NEW_COUNT:-0}

	# The newest history message: the cursor advances to it in phase 3, once the run's messages are in
	# the inbox, so a failed call later in the run leaves nothing behind that no inbox got
	CH_MAXTS[${CHANNEL}]=$(max_ts "${HIST_MSGS}")

	# --- thread registry: known parents, with their reply cursor and last poll, + parents discovered this run ---
	if [ -f "${THREADS_FILE}" ]; then
		while read -r P_TS P_CUR P_POLLED; do
			[ -n "${P_TS}" ] || continue
			THREAD_CURSOR["${CHANNEL} ${P_TS}"]=${P_CUR:-${P_TS}}
			THREAD_POLLED["${CHANNEL} ${P_TS}"]=${P_POLLED:-0}
		done < "${THREADS_FILE}"
	fi
	while read -r P_TS; do
		if [ -n "${P_TS}" ] && [ -z "${THREAD_CURSOR["${CHANNEL} ${P_TS}"]}" ]; then
			THREAD_CURSOR["${CHANNEL} ${P_TS}"]=${P_TS}
			THREAD_POLLED["${CHANNEL} ${P_TS}"]=0
		fi
	done < "${NEW_PARENTS}"
	for KEY in "${!THREAD_CURSOR[@]}"; do
		[ "${KEY%% *}" = "${CHANNEL}" ] || continue
		P_TS=${KEY#* }
		# Retire threads older than SLACK_THREAD_MAX_AGE so the poll set stays bounded
		P_AGE=$(( NOW - ${P_TS%%.*} ))
		if [ "${P_AGE}" -gt "${SLACK_THREAD_MAX_AGE}" ]; then
			echo "Channel ${CHANNEL}: thread ${P_TS} retired (age ${P_AGE}s > ${SLACK_THREAD_MAX_AGE}s)"
			unset "THREAD_CURSOR[${KEY}]" "THREAD_POLLED[${KEY}]"
			continue
		fi
		if skipping "${CHANNEL}" "${P_TS}"; then
			echo "Channel ${CHANNEL}: thread ${P_TS} skipped, ${THREAD_FAILS[${KEY}]} replies calls failed in a row (polled again $(( SLACK_THREAD_FAIL_BACKOFF - NOW + ${THREAD_FAILED_AT[${KEY}]} ))s from now)"
			continue
		fi
		echo "${THREAD_POLLED[${KEY}]} ${CHANNEL} thread ${P_TS} -" >> "${CANDIDATES}"
	done

	# --- the people's new top-level messages, listed for the bounded watch ---
	# Each new top-level message without replies from someone other than the agent: the agent answers
	# it, and the person may go on in a thread under it. Listed SLACK_ANSWER_WATCH_SECONDS from now,
	# the newest SLACK_ANSWER_WATCH_MAX.
	ASKS_FILE=${SLACK_DIR}/asks-${CHANNEL}
	NEW_ASKS=$(printf '%s' "${NEW_TOPS}" | awk -v self="${SELF_ID}" -v until="$(( NOW + SLACK_ANSWER_WATCH_SECONDS ))" \
		'NF >= 2 && $2 != self { print $1, until }' | sort -n)
	if [ -n "${NEW_ASKS}" ]; then
		{ awk -v now="${NOW}" 'NF >= 2 && $2 > now' "${ASKS_FILE}" 2>/dev/null; echo "${NEW_ASKS}"; } \
			| tail -n "${SLACK_ANSWER_WATCH_MAX}" > "${ASKS_FILE:?}.tmp" && mv "${ASKS_FILE:?}.tmp" "${ASKS_FILE:?}"
	fi

	# --- recent top-level messages: a first reply threaded under one ---
	# A reply may be threaded under a top-level message after the watcher saw it with no replies; the
	# cursor is past it, so neither history nor the registry would show the reply. A person answers the
	# agent in a thread under its post (answers-<channel>, listed by slack-post.sh), or goes on in a
	# thread under their own message (asks-<channel>, listed above). Each list holds "<ts> <expiry
	# epoch> [<last poll>]" lines (2 h, the newest 5), and both are checked at most every
	# SLACK_ANSWER_POLL_INTERVAL seconds, within the budget. A message with a reply moves to the thread
	# registry and is polled like any thread from then on.
	ANSWERS_FILE=${SLACK_DIR}/answers-${CHANNEL}
	ANSWERS_STAMP=${SLACK_DIR}/answers-polled-${CHANNEL}
	if { [ -s "${ANSWERS_FILE}" ] || [ -s "${ASKS_FILE}" ]; } \
		&& [ $(( NOW - $(cat "${ANSWERS_STAMP}" 2>/dev/null || echo 0) )) -ge "${SLACK_ANSWER_POLL_INTERVAL}" ]; then
		echo "${NOW}" > "${ANSWERS_STAMP}"
		LIST_DUE[${CHANNEL}]=1
		for KIND in answer ask; do
			LIST=${ANSWERS_FILE}
			[ "${KIND}" = "ask" ] && LIST=${ASKS_FILE}
			LIST_KEEP["${CHANNEL} ${KIND}"]=""
			[ -s "${LIST}" ] || continue
			while read -r A_TS A_EXP A_POLLED; do
				[ -n "${A_TS}" ] || continue
				# expired, or already a thread the registry polls: dropped from the list
				if [ "${A_EXP:-0}" -le "${NOW}" ] || [ -n "${THREAD_CURSOR["${CHANNEL} ${A_TS}"]}" ]; then
					continue
				fi
				if skipping "${CHANNEL}" "${A_TS}"; then
					LIST_KEEP["${CHANNEL} ${KIND}"]="${LIST_KEEP["${CHANNEL} ${KIND}"]}${A_TS} ${A_EXP} ${A_POLLED:-0}
"
					continue
				fi
				echo "${A_POLLED:-0} ${CHANNEL} ${KIND} ${A_TS} ${A_EXP}" >> "${CANDIDATES}"
			done < "${LIST}"
		done
	fi

	rm -f "${NEW_PARENTS:?}"
done

# --- phase 2: the conversations.replies calls, least recently polled first, within the budget ---
# Only replies newer than the thread's cursor are taken, never the parent, which every answer carries
# (NEW_REPLIES). The replies and the moved cursors are committed in phase 3, once every call succeeded:
# a failed call ends the run with nothing of this phase written, and the next run polls the same threads.
DEFERRED=0
sort -k1,1n -k2,2 -k4,4n "${CANDIDATES}" > "${CANDIDATES}.sorted"
while read -r C_POLLED CHANNEL KIND TS EXTRA; do
	[ -n "${TS}" ] || continue
	KEY="${CHANNEL} ${TS}"
	case "${KIND}" in
	thread) OLDEST=${THREAD_CURSOR[${KEY}]}; WHOSE="thread" ;;
	answer) OLDEST=${TS}; WHOSE="the agent's post" ;;
	*) OLDEST=${TS}; WHOSE="a person's message" ;;
	esac
	if [ "${REMAINING}" -le 0 ]; then
		# over budget: left for a later run with its state unchanged (a list entry keeps its line)
		DEFERRED=$((DEFERRED + 1))
		[ "${KIND}" != "thread" ] && LIST_KEEP["${CHANNEL} ${KIND}"]="${LIST_KEEP["${CHANNEL} ${KIND}"]}${TS} ${EXTRA} ${C_POLLED}
"
		continue
	fi
	REMAINING=$((REMAINING - 1))
	echo "${NOW}" >> "${LEDGER}"
	REPL_MSGS=$(mktemp)
	# a transport failure (api_get returns 1) ends the run but is not counted against the thread
	RESP=$(api_get conversations.replies "channel=${CHANNEL}" "ts=${TS}" "oldest=${OLDEST}" "limit=200") \
		|| { rm -f "${REPL_MSGS:?}"; cleanup_run; exit 1; }
	PARSED=$(echo "${RESP}" | "${NODE_BIN}" -e "${PARSE_MESSAGES}" "${CHANNEL}" "${SELF_ID}" "${SLACK_ALLOWED_USERS}")
	E=$(echo "${PARSED}" | grep "^ERR" | head -1 | cut -f2)
	if [ -n "${E}" ]; then
		if [ "${E}" = "thread_not_found" ]; then
			# the message was deleted: a thread leaves the registry, a list entry its list
			if [ "${KIND}" = "thread" ]; then
				echo "Channel ${CHANNEL}: thread ${TS} dropped (${E})"
				unset "THREAD_CURSOR[${KEY}]" "THREAD_POLLED[${KEY}]"
			fi
			rm -f "${REPL_MSGS:?}"
			continue
		fi
		err "conversations.replies failed for channel ${CHANNEL} ${WHOSE} ${TS}: ${E}"
		# a rate limit is not the thread's fault: not counted (the retry-after record pauses the caller)
		[ "${E}" = "ratelimited" ] || replies_failed "${CHANNEL}" "${TS}"
		rm -f "${REPL_MSGS:?}"
		cleanup_run
		exit 1
	fi
	replies_ok "${CHANNEL}" "${TS}"
	echo "${PARSED}" | awk -F '\t' -v parent="${TS}" -v cursor="${OLDEST}" "${NEW_REPLIES}" >> "${REPL_MSGS}"
	R=$(grep -c "^MSG" "${REPL_MSGS}" 2>/dev/null)
	R=${R:-0}
	if [ "${KIND}" = "thread" ]; then
		THREAD_POLLED[${KEY}]=${NOW}
		if [ "${R}" -gt 0 ]; then
			cat "${REPL_MSGS}" >> "${CH_REPL[${CHANNEL}]}"
			THREAD_CURSOR[${KEY}]=$(max_ts "${REPL_MSGS}")
			CH_REPLY_COUNT[${CHANNEL}]=$(( ${CH_REPLY_COUNT[${CHANNEL}]:-0} + R ))
		fi
	elif [ "${R}" -gt 0 ]; then
		# a reply under the listed message: its thread joins the registry, polled like any other from now on
		cat "${REPL_MSGS}" >> "${CH_REPL[${CHANNEL}]}"
		THREAD_CURSOR[${KEY}]=$(max_ts "${REPL_MSGS}")
		THREAD_POLLED[${KEY}]=${NOW}
		CH_REPLY_COUNT[${CHANNEL}]=$(( ${CH_REPLY_COUNT[${CHANNEL}]:-0} + R ))
		echo "Channel ${CHANNEL}: ${R} reply(ies) threaded under ${WHOSE} ${TS}; its thread is now watched like any other"
	else
		LIST_KEEP["${CHANNEL} ${KIND}"]="${LIST_KEEP["${CHANNEL} ${KIND}"]}${TS} ${EXTRA} ${NOW}
"
	fi
	rm -f "${REPL_MSGS:?}"
done < "${CANDIDATES}.sorted"
if [ "${DEFERRED}" -gt 0 ]; then
	echo "Deferred ${DEFERRED} conversations.replies call(s) to a later run: the budget of ${SLACK_REPLIES_BUDGET} per ${SLACK_REPLIES_WINDOW}s is used up (${LEDGER}); the least recently polled went first"
fi

# --- phase 3, per channel: everything read into the inbox, oldest first, each message once (a thread
# reply "also sent to the channel" is listed by history and by its thread's replies; a ts names one
# message in a channel), in one checked append; only then the cursor; the registry and the lists written.
# The whole phase runs under the inbox lock (${SLACK_DIR}/inbox.lock, fd 8), which the chat responder and
# the loop take around their removals of handled lines: an append never lands in a file a consumer's
# sed -i is replacing, and a consumer never edits a file an append is going into ---
exec 8>> "${SLACK_DIR}/inbox.lock"
if ! flock -w 60 8; then
	err "the inbox lock ${SLACK_DIR}/inbox.lock was not free within 60 s: nothing committed, no cursor moved - the next run brings the same messages"
	cleanup_run
	exit 1
fi
for CHANNEL in $(echo "${SLACK_CHANNELS}" | tr ',' ' '); do
	THREADS_FILE=${SLACK_DIR}/threads-${CHANNEL}
	# The channel's batch is built first and appended in one write that is checked twice: the write's own
	# status, and the inbox grown by exactly the batch's bytes. A failed or short append (a full disk, a
	# write error) is undone - the inbox cut back to its size before the write, only when it is still the
	# same file (same inode) and did grow; a file replaced under the append, or one that did not grow, is
	# left as it is, never padded - and the run ends with exit 1 before this channel's cursor, registry or
	# lists move, so the next run brings the same messages. Anything less would advance the cursor past
	# messages no inbox holds.
	BATCH=$(mktemp)
	# the messages taken (no 4th field); the others moved the cursor above and are only counted
	cat "${CH_HIST[${CHANNEL}]}" "${CH_REPL[${CHANNEL}]}" | sort -t "$(printf '\t')" -k2,2n -u > "${BATCH}.all"
	awk -F '\t' '$4 == ""' "${BATCH}.all" | cut -f3 > "${BATCH}"
	NOT_BOT=$(awk -F '\t' '$4 == "bot"' "${BATCH}.all" | grep -c .)
	NOT_SENDER=$(awk -F '\t' '$4 == "sender"' "${BATCH}.all" | grep -c .)
	rm -f "${BATCH:?}.all"
	BATCH_BYTES=$(stat -c %s "${BATCH}")
	if [ "${BATCH_BYTES}" -gt 0 ]; then
		INBOX_BYTES=$(stat -c %s "${INBOX}" 2>/dev/null || echo 0)
		INBOX_INODE=$(stat -c %i "${INBOX}" 2>/dev/null || echo none)
		APPEND_OK=true
		cat "${BATCH}" 2> "${BATCH}.err" >> "${INBOX}" || APPEND_OK=false
		INBOX_NOW=$(stat -c %s "${INBOX}" 2>/dev/null || echo 0)
		INBOX_INODE_NOW=$(stat -c %i "${INBOX}" 2>/dev/null || echo none)
		if [ "${APPEND_OK}" = "false" ] || [ "${INBOX_NOW}" -ne $(( INBOX_BYTES + BATCH_BYTES )) ]; then
			APPEND_ERR=$(tr '\n' ' ' < "${BATCH}.err" 2>/dev/null)
			if [ "${INBOX_INODE_NOW}" != "${INBOX_INODE}" ]; then
				OUTCOME="the inbox was replaced under the append (inode ${INBOX_INODE} -> ${INBOX_INODE_NOW}: a writer that does not take ${SLACK_DIR}/inbox.lock) and is left as it is"
			elif [ -f "${INBOX}" ] && [ "${INBOX_NOW}" -gt "${INBOX_BYTES}" ]; then
				truncate -s "${INBOX_BYTES}" "${INBOX}"
				OUTCOME="the inbox is cut back to its previous size"
			else
				OUTCOME="the inbox did not grow and is left as it is"
			fi
			err "inbox append failed for channel ${CHANNEL}: wrote $(( INBOX_NOW - INBOX_BYTES )) of ${BATCH_BYTES} byte(s) to ${INBOX}${APPEND_ERR:+ (${APPEND_ERR})}; ${OUTCOME}; no cursor moves - the next run brings the same messages"
			rm -f "${BATCH:?}" "${BATCH:?}.err"
			flock -u 8
			cleanup_run
			exit 1
		fi
	fi
	rm -f "${BATCH:?}" "${BATCH:?}.err"
	[ -n "${CH_MAXTS[${CHANNEL}]}" ] && echo "${CH_MAXTS[${CHANNEL}]}" > "${SLACK_DIR}/cursor-${CHANNEL}"
	NEW_THREADS_CONTENT=""
	for KEY in "${!THREAD_CURSOR[@]}"; do
		[ "${KEY%% *}" = "${CHANNEL}" ] || continue
		NEW_THREADS_CONTENT="${NEW_THREADS_CONTENT}${KEY#* } ${THREAD_CURSOR[${KEY}]} ${THREAD_POLLED[${KEY}]}
"
	done
	printf '%s' "${NEW_THREADS_CONTENT}" | sort -n > "${THREADS_FILE}"
	if [ -n "${LIST_DUE[${CHANNEL}]}" ]; then
		printf '%s' "${LIST_KEEP["${CHANNEL} answer"]}" > "${SLACK_DIR}/answers-${CHANNEL}"
		printf '%s' "${LIST_KEEP["${CHANNEL} ask"]}" > "${SLACK_DIR}/asks-${CHANNEL}"
	fi
	REPLY_COUNT=${CH_REPLY_COUNT[${CHANNEL}]:-0}
	NOT_TAKEN=""
	[ "${NOT_SENDER:-0}" -gt 0 ] && NOT_TAKEN="${NOT_SENDER} not taken (sender not in SLACK_ALLOWED_USERS)"
	[ "${NOT_BOT:-0}" -gt 0 ] && NOT_TAKEN="${NOT_TAKEN:+${NOT_TAKEN}, }${NOT_BOT} not taken (another bot)"
	[ -z "${SLACK_ALLOWED_USERS}" ] && [ "${NOT_SENDER:-0}" -gt 0 ] \
		&& echo "WARNING: SLACK_ALLOWED_USERS is empty, so no person's message reaches the agent - set the Slack user IDs of the people who may drive it (or anyone) in .env.local (docs/manual/channels.md \"Slack connectivity\")" >&2
	echo "Channel ${CHANNEL}: ${CH_NEW[${CHANNEL}]} new message(s), ${REPLY_COUNT} thread reply(ies); cursor=$(cat "${SLACK_DIR}/cursor-${CHANNEL}") threads=$(count_lines "${THREADS_FILE}") answers=$(count_lines "${SLACK_DIR}/answers-${CHANNEL}") asks=$(count_lines "${SLACK_DIR}/asks-${CHANNEL}")${NOT_TAKEN:+; ${NOT_TAKEN}}"
	TOTAL_NEW=$(( TOTAL_NEW + CH_NEW[${CHANNEL}] ))
	TOTAL_REPLIES=$(( TOTAL_REPLIES + REPLY_COUNT ))
done
flock -u 8
cleanup_run

SUMMARY="$(date -u +%Y-%m-%dT%H:%M:%SZ) new=${TOTAL_NEW} replies=${TOTAL_REPLIES} deferred=${DEFERRED} inbox=$(count_lines "${INBOX}")"
echo "${SUMMARY}" > "${SLACK_DIR}/last-watch"
echo "Watch complete: ${SUMMARY}"
