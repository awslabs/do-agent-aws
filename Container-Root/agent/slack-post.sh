#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Post one message to a watched Slack channel - with read-back verification.
#
# Usage: /agent/slack-post.sh "<channel-id>" "<text>" [thread_ts]
#
# With the optional third argument the message is posted as a reply in that thread (the thread_ts
# field of an inbox line); the two-argument form posts in the channel, unchanged. A thread reply
# is invisible to conversations.history, so its read-back uses conversations.replies, and once it
# is verified the thread goes into the watcher's thread registry (${SLACK_DIR}/threads-<channel>),
# so /agent/slack-watch.sh collects the replies that follow it (register_thread below). A verified
# channel post is watched for 2 hours for a reply threaded under it (watch_answer below) - every part
# of a long one, since a person may thread a reply under any of them.
#
# Posting is deliberately double-gated and refuses loud (nonzero exit, clear message):
#   1. the post gate must be on: SLACK_POST_ENABLED=true, or auto (the .env default) or unset
#      while SLACK_BOT_TOKEN and SLACK_CHANNELS are set; SLACK_POST_ENABLED=false turns it off.
#      The decision is /agent/slack-gates.sh, shared with the loop - a bot token and a channel
#      list are enough for the agent to reply, and the explicit false is the opt-out for an agent
#      that may read but must not speak
#   2. the target channel must be one of the IDs in SLACK_CHANNELS - the agent can only post
#      where it is allowed to watch
# The bot posts as ITSELF - the Slack app identity the user created - never as a person.
#
# chat.postMessage returning ok:true is treated as a claim, not proof: the channel is re-read
# (conversations.history) and the posted ts must be present, with the exact text posted, before this
# script reports success. On success the message ts is printed. Slack renders some text server-side
# (& < > become entities, links become <url|label>), so both texts - the one sent and the one read
# back - are compared after undoing that rendering (a text sent with Slack's own <url|label> link
# markup reads back as sent, and must not fail for it), and then once more ignoring whitespace and an
# added http:// (an autolinked bare host); any other difference - a truncated message, say - is a
# FAILED post.
# Every verified post is appended as one line to ${SLACK_DIR}/posted.jsonl (ts, channel, thread_ts for
# a thread reply, and the first 200 characters of the text, so the loop can tell a later fire what was
# already said) - the autonomy loop's fires and the chat responder /agent/slack-chat.sh both post
# through this script, possibly at the same time, and a single-line append is all they share here.
#
# Exit status, so a caller never posts a text twice: 0 - every part posted and read back; 3 - refused,
# a newer message arrived (below; nothing posted); 4 - a part LANDED (chat.postMessage returned ok:true
# with its ts) but the post did not complete: a later part failed, or a read-back failed or found
# other text. Whatever landed stays on the platform and its ts is in SLACK_POST_RECORD (when set) -
# the caller must not send the text again. 5 - a transport failure on chat.postMessage after the
# request may have reached Slack (curl's timeout, an empty reply, a receive failure): whether the part
# landed is unknown, so the caller must not send the text again either. 1 - nothing landed (a gate
# refusal, a bad argument, a call that failed before anything was sent: no route, no connection, no
# TLS). An HTTP 429 posts nothing, so a rate-limited part is retried once in place after Slack's
# Retry-After (at most 30 s); a second 429 fails the post as above.
#
# Pre-send newest check (opt-in, our DM sender's guard): with SLACK_POST_AFTER_TS set - the newest
# message the caller had read when its answer began - the script first re-reads the place it posts to
# (the thread for a thread reply, else the channel). When a newer message from someone other than the
# agent has arrived since, the answer may be stale: it refuses with exit 3, names that message, and
# appends "<its ts> <its user>" to SLACK_POST_STALE_RECORD when set, so the caller answers again with
# it. A refused THREAD post also puts that thread into the watcher's registry (register_thread): the
# newer message is a reply in a thread the agent may never have posted in - the thread it is about to
# start under a top-level message (SLACK_REPLY_IN_THREAD) - which no registry lists yet and the asks
# list polls only every SLACK_ANSWER_POLL_INTERVAL, so without the entry the caller answers again
# without the reply in view, is refused again, and reaches its cap. A failed re-read refuses too
# (exit 1): a stale answer is never posted for want of a check.
# What counts as newer is what the caller's inbox counts: for a channel post only a top-level message
# (a thread reply "also sent to the channel" shows in the channel's history with its thread_ts, and the
# watcher and the chat responder file it under its thread - counting it here would refuse the channel
# answer again on every poll, for a message the caller's top-level conversation never contains); for a
# thread reply any message in that thread, a broadcast one included.
#
# Settings (from .env / environment): SLACK_BOT_TOKEN, SLACK_CHANNELS, SLACK_POST_ENABLED
# (true|false|auto), SLACK_API_BASE (default https://slack.com/api; the offline smoke /test4.sh
# points it at a local stub), SLACK_DIR (default /wd/slack, used only to log posts to
# ${SLACK_DIR}/posted.jsonl), SLACK_GATES_BIN (default: slack-gates.sh beside this script),
# SLACK_POST_RECORD (optional: a file each landed part's ts is appended to, the moment chat.postMessage
# returns ok:true - before its read-back - so a caller knows what is on the platform even when this
# script exits 4, and the word "unknown" when a part's response was lost (exit 5), so the caller knows a
# post may be there; the chat responder sets it per message to know whether the model's claude call
# posted, and posts no fallback when it did or may have; an HTTP 429 from chat.postMessage records
# Slack's Retry-After seconds in ${SLACK_DIR}/retry-after the same way).
# The token reaches curl only through its config on stdin (slack_curl below): it is never a word of
# a command line, which every local user can read in ps, and never shows in an xtrace.

SLACK_API_BASE=${SLACK_API_BASE:-https://slack.com/api}
SLACK_DIR=${SLACK_DIR:-/wd/slack}

# Absolute path - may run detached without a login shell PATH (same pattern as loop.sh CLAUDE_BIN);
# node is used to build/parse JSON because the image ships node (for Claude Code) but not jq.
NODE_BIN=${NODE_BIN:-/usr/local/bin/node}
[ -x "${NODE_BIN}" ] || NODE_BIN=$(command -v node)

err()
{
	echo "ERROR: $*" >&2
}

# slack_curl <curl args...> - curl with the bot token's Authorization header read from curl's config
# on stdin (-K -), so the token is not on curl's command line; a here-string, so not in an xtrace
slack_curl()
{
	curl -K - "$@" <<< "header = \"Authorization: Bearer ${SLACK_BOT_TOKEN}\""
}

# post_failed <message> - the post did not complete. Exit 4 when a part has landed (its ts is on the
# platform and in SLACK_POST_RECORD when set): the caller must not send this text again. Else exit 1.
LANDED=0
post_failed()
{
	if [ "${LANDED}" -gt 0 ]; then
		err "$* - ${LANDED} part(s) of this message landed already${SLACK_POST_RECORD:+ (ts in ${SLACK_POST_RECORD})}: do not post this text again (exit 4)"
		exit 4
	fi
	err "$*"
	exit 1
}

# register_thread - add this post's thread to slack-watch.sh's thread registry, so the watcher collects
# the replies that follow. The watcher registers a thread only when it first sees the parent with
# replies; a post in the thread of a message it saw before that message had any (an operator's or a
# goal's slack-post.sh <channel> <text> <ts>) starts a thread the channel cursor is already past, so
# conversations.history never shows it again and the person's follow-up there would never be
# collected. One line per thread, written under the watcher's own lock: a thread already registered
# keeps its line, because a second line would reset its reply cursor and collect old replies again.
# The reply cursor starts at the parent, as for a parent the watcher finds itself.
register_thread()
{
	REGISTRY=${SLACK_DIR}/threads-${CHANNEL}
	(
		flock -w 60 7 || { echo "WARNING: thread ${THREAD_TS} not registered for watching: ${SLACK_DIR}/watch.lock busy for 60s" >&2; exit 0; }
		awk -v t="${THREAD_TS}" '$1 == t { found = 1 } END { exit !found }' "${REGISTRY}" 2>/dev/null \
			|| echo "${THREAD_TS} ${THREAD_TS}" >> "${REGISTRY}"
	) 7> "${SLACK_DIR}/watch.lock"
}

# watch_answer - list this top-level post in slack-watch.sh's answers-<channel> file: a person may answer
# it in a thread under it, and the watcher saw it before it had any replies. Each line is "<ts> <expiry
# epoch>": SLACK_ANSWER_WATCH_SECONDS (default 7200) from now, and only the SLACK_ANSWER_WATCH_MAX
# (default 5) newest stay listed, so the watcher's check of them costs at most that many
# conversations.replies calls per SLACK_ANSWER_POLL_INTERVAL. Under the watcher's lock, like
# register_thread.
watch_answer()
{
	ANSWERS=${SLACK_DIR}/answers-${CHANNEL}
	(
		flock -w 60 7 || { echo "WARNING: post ${TS} not watched for threaded replies: ${SLACK_DIR}/watch.lock busy for 60s" >&2; exit 0; }
		NOW_S=$(date +%s)
		{ awk -v now="${NOW_S}" 'NF >= 2 && $2 > now' "${ANSWERS}" 2>/dev/null
		  echo "${TS} $(( NOW_S + ${SLACK_ANSWER_WATCH_SECONDS:-7200} ))"; } \
			| tail -n "${SLACK_ANSWER_WATCH_MAX:-5}" > "${ANSWERS:?}.tmp" && mv "${ANSWERS:?}.tmp" "${ANSWERS:?}"
	) 7> "${SLACK_DIR}/watch.lock"
}

# Gate 1: the post gate must be on - the shared decision in slack-gates.sh (beside this script)
SLACK_GATES_BIN=${SLACK_GATES_BIN:-$(dirname "$0")/slack-gates.sh}
if [ ! -f "${SLACK_GATES_BIN}" ]; then
	err "${SLACK_GATES_BIN} not found - slack-gates.sh ships beside slack-post.sh; set SLACK_GATES_BIN if it lives elsewhere"
	exit 1
fi
. "${SLACK_GATES_BIN}"
if [ "${SLACK_POST_EFFECTIVE}" != "on" ]; then
	err "refusing to post: the post gate is off (${SLACK_POST_REASON}). Posting is on when SLACK_POST_ENABLED=true, or when it is auto or unset (the .env default) and both SLACK_BOT_TOKEN and SLACK_CHANNELS are set; SLACK_POST_ENABLED=false turns it off. /agent/slack-status.sh shows the effective gates."
	exit 1
fi

CHANNEL=$1
TEXT=$2
THREAD_TS=$3
if [ -z "${CHANNEL}" ] || [ -z "${TEXT}" ]; then
	err "usage: $0 \"<channel-id>\" \"<text>\" [thread_ts]"
	exit 1
fi
# The text is masked before it is sent (/agent/redact.py, the board mirror's rules: the values of secret-named settings, the
# mounted AWS credentials, common token shapes): a credential the agent saw never reaches the channel. The read-back below
# compares the masked text. A text that cannot be masked is not posted.
TEXT=$(printf '%s' "${TEXT}" | python3 -I "$(dirname "$0")/redact.py") || { err "refusing to post: the text could not be masked for credentials"; exit 1; }
if [ -n "${THREAD_TS}" ] && ! echo "${THREAD_TS}" | grep -qE '^[0-9]+\.[0-9]+$'; then
	err "thread_ts '${THREAD_TS}' is not a Slack message ts (digits.digits) - pass the thread_ts field of the inbox line, or omit it to post in the channel"
	exit 1
fi

# Gate 2: only channels the agent is configured to watch
ALLOWED=false
for C in $(echo "${SLACK_CHANNELS}" | tr ',' ' '); do
	[ "${C}" = "${CHANNEL}" ] && ALLOWED=true
done
if [ "${ALLOWED}" != "true" ]; then
	err "refusing to post: channel '${CHANNEL}' is not in SLACK_CHANNELS ('${SLACK_CHANNELS:-empty}'). Add it to SLACK_CHANNELS in .env.local to allow posting there."
	exit 1
fi

if [ -z "${SLACK_BOT_TOKEN:+set}" ]; then
	err "SLACK_BOT_TOKEN is empty - set it in .env.local or the host environment (see docs/slack/README.md)"
	exit 1
fi

if [ -z "${NODE_BIN}" ]; then
	err "node not found (looked at /usr/local/bin/node and PATH); set NODE_BIN"
	exit 1
fi

# post_one - post ${TEXT} (one part) and read it back; ${PART_NOTE} names the part. Exits the script on any
# failure (post_failed: 4 once a part has landed).
post_one()
{
	# Post - body built with JSON.stringify so arbitrary text is escaped correctly; thread_ts only when given
	BODY=$("${NODE_BIN}" -e '
	const body = { channel: process.argv[1], text: process.argv[2] };
	if (process.argv[3]) body.thread_ts = process.argv[3];
	console.log(JSON.stringify(body));' "${CHANNEL}" "${TEXT}" "${THREAD_TS}")
	# A 429 posts nothing: honor Retry-After once (at most 30 s) and post this same part again
	POST_TRIES=0
	while :; do
		POST_TRIES=$((POST_TRIES + 1))
		HDRS=$(mktemp)
		RESP=$(slack_curl -sS --max-time 30 -D "${HDRS}" \
			-H "Content-Type: application/json; charset=utf-8" \
			-d "${BODY}" "${SLACK_API_BASE}/chat.postMessage")
		CURL_RC=$?
		if [ "${CURL_RC}" -ne 0 ]; then
			rm -f "${HDRS:?}"
			case "${CURL_RC}" in
			5|6|7|35)
				# nothing was sent: no proxy, no route, no connection, no TLS - a retry is safe
				post_failed "curl to ${SLACK_API_BASE}/chat.postMessage failed before anything was sent (curl exit ${CURL_RC})${PART_NOTE}"
				;;
			*)
				# the request may have reached Slack (a timeout, an empty reply, a lost connection): whether
				# this part landed is unknown, so it is treated as landed - never sent again
				[ -n "${SLACK_POST_RECORD}" ] && echo "unknown" >> "${SLACK_POST_RECORD}"
				err "curl to ${SLACK_API_BASE}/chat.postMessage failed after the request may have reached Slack (curl exit ${CURL_RC})${PART_NOTE}: whether it landed is unknown - do not post this text again (exit 5)"
				exit 5
				;;
			esac
		fi
		if head -1 "${HDRS}" | grep -q " 429"; then
			RETRY_AFTER=$(grep -i '^Retry-After:' "${HDRS}" | tail -1 | tr -d '\r' | awk '{print $2}')
			rm -f "${HDRS:?}"
			mkdir -p "${SLACK_DIR}"
			echo "${RETRY_AFTER:-30}" > "${SLACK_DIR}/retry-after"
			if [ "${POST_TRIES}" -eq 1 ]; then
				WAIT=$(echo "${RETRY_AFTER}" | tr -dc '0-9')
				[ -z "${WAIT}" ] && WAIT=30
				[ "${WAIT}" -gt 30 ] && WAIT=30
				[ "${WAIT}" -lt 1 ] && WAIT=1
				echo "Note: Slack rate limited chat.postMessage${PART_NOTE} (HTTP 429, Retry-After ${RETRY_AFTER:-unknown}s); nothing was posted for it - posting this part again in ${WAIT}s"
				sleep "${WAIT}"
				continue
			fi
			post_failed "Slack rate limited chat.postMessage${PART_NOTE} twice (HTTP 429, Retry-After ${RETRY_AFTER:-unknown}s; recorded in ${SLACK_DIR}/retry-after)"
		fi
		rm -f "${HDRS:?}"
		# the limit was honored: the record for the chat responder's pause is not needed
		[ "${POST_TRIES}" -gt 1 ] && rm -f "${SLACK_DIR:?}/retry-after"
		break
	done

	POST_LINE=$(echo "${RESP}" | "${NODE_BIN}" -e '
	let raw = "";
	process.stdin.on("data", d => raw += d);
	process.stdin.on("end", () => {
		let r;
		try { r = JSON.parse(raw); } catch (e) { console.log("ERR\tunparseable-response"); return; }
		if (!r.ok) { console.log("ERR\t" + (r.error || "unknown-error")); return; }
		console.log("OK\t" + r.ts);
	});
	')
	case "${POST_LINE}" in
	OK*)
		TS=$(echo "${POST_LINE}" | cut -f2)
		# Landed: on the platform from here on, whatever the read-back finds - recorded at once, so the
		# caller never sends this text again (see the header)
		LANDED=$((LANDED + 1))
		if [ -n "${SLACK_POST_RECORD}" ]; then
			echo "${TS}" >> "${SLACK_POST_RECORD}"
		fi
		;;
	*)
		post_failed "chat.postMessage failed for channel ${CHANNEL}${PART_NOTE}: $(echo "${POST_LINE}" | cut -f2-)"
		;;
	esac

	# Read-back verify: ok:true is not proof - the message must be present when the channel is re-read.
	# A channel message is re-read with conversations.history; a thread reply with conversations.replies
	# on its thread (history never lists replies). One retry covers propagation delay.
	verify()
	{
		if [ -n "${THREAD_TS}" ]; then
			READ_METHOD=conversations.replies
			READ_ARGS=(--data-urlencode "channel=${CHANNEL}" --data-urlencode "ts=${THREAD_TS}")
		else
			READ_METHOD=conversations.history
			READ_ARGS=(--data-urlencode "channel=${CHANNEL}")
		fi
		# shellcheck disable=SC2016 # "$1" in the node script is the regex replacement, not a shell expansion
		slack_curl -sS --max-time 30 \
			-G "${SLACK_API_BASE}/${READ_METHOD}" "${READ_ARGS[@]}" \
			--data-urlencode "oldest=${TS}" \
			--data-urlencode "inclusive=true" \
			--data-urlencode "limit=10" \
		| "${NODE_BIN}" -e '
	let raw = "";
	process.stdin.on("data", d => raw += d);
	process.stdin.on("end", () => {
		let r;
		try { r = JSON.parse(raw); } catch (e) { console.log("MISSING\tunparseable-response"); return; }
		if (!r.ok) { console.log("MISSING\t" + (r.error || "unknown-error")); return; }
		const hit = (r.messages || []).find(m => m.ts === process.argv[1]);
		if (!hit) { console.log("MISSING\tts-not-in-history"); return; }
		// undo Slack rendering: <url|label> and <mailto:x|label> back to the url, entities back to characters
		const norm = s => s.replace(/<(https?:\/\/[^|>]+)(\|[^>]*)?>/g, "$1").replace(/<mailto:([^|>]+)(\|[^>]*)?>/g, "$1")
			.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "\x27").replace(/&amp;/g, "&");
		const canon = s => s.replace(/http:\/\//g, "").replace(/\s+/g, "");
		const want = norm(process.argv[2]).replace(/\s+$/, ""), got = norm(hit.text || "").replace(/\s+$/, "");
		if (got === want) { console.log("FOUND\tEXACT"); return; }
		if (canon(got) === canon(want)) { console.log("FOUND\tCANONICAL"); return; }
		let i = 0;
		while (i < got.length && i < want.length && got[i] === want[i]) i++;
		console.log("FOUND\tMISMATCH\t" + JSON.stringify({ sent_chars: want.length, read_chars: got.length,
			first_difference_at: i, sent: want.slice(i, i + 40), read: got.slice(i, i + 40) }));
	});
	' "${TS}" "${TEXT}"
	}

	VERIFY_LINE=$(verify)
	case "${VERIFY_LINE}" in
	FOUND*) ;;
	*)
		sleep 2
		VERIFY_LINE=$(verify)
		;;
	esac

	VERDICT=$(echo "${VERIFY_LINE}" | cut -f2)
	if [ "${VERIFY_LINE%%$'\t'*}" = "FOUND" ] && [ "${VERDICT}" = "MISMATCH" ]; then
		# The message is on the platform, but not as written: it landed (recorded above, so the chat
		# responder posts no second, fallback message), and the post is FAILED, exit 4
		post_failed "chat.postMessage returned ok:true ts=${TS} and the message is in channel ${CHANNEL}${THREAD_TS:+ thread ${THREAD_TS}}, but its text is not the text posted ($(echo "${VERIFY_LINE}" | cut -f3-)); treating as FAILED"
	fi
	case "${VERIFY_LINE}" in
	FOUND*)
		if [ "${VERDICT}" = "CANONICAL" ]; then
			echo "Note: the read-back text matches once Slack's whitespace and link rendering is undone"
		fi
		mkdir -p "${SLACK_DIR}"
		TEXT_EXCERPT=$("${NODE_BIN}" -e 'process.stdout.write(JSON.stringify(Array.from(process.argv[1]).slice(0, 200).join("")))' "${TEXT}")
		if [ -n "${THREAD_TS}" ]; then
			echo "{\"ts\":\"${TS}\",\"channel\":\"${CHANNEL}\",\"thread_ts\":\"${THREAD_TS}\",\"text\":${TEXT_EXCERPT}}" >> "${SLACK_DIR}/posted.jsonl"
			register_thread
			echo "Posted and read-back verified: channel=${CHANNEL} ts=${TS} thread_ts=${THREAD_TS}${PART_NOTE}"
		else
			echo "{\"ts\":\"${TS}\",\"channel\":\"${CHANNEL}\",\"text\":${TEXT_EXCERPT}}" >> "${SLACK_DIR}/posted.jsonl"
			watch_answer
			echo "Posted and read-back verified: channel=${CHANNEL} ts=${TS}${PART_NOTE}"
		fi
		;;
	*)
		# Slack answered ok:true with a ts, so the message landed as far as the caller can know: exit 4
		post_failed "chat.postMessage returned ok:true ts=${TS}, but read-back could not find the message in channel ${CHANNEL}${THREAD_TS:+ thread ${THREAD_TS}} ($(echo "${VERIFY_LINE}" | cut -f2-)); treating as FAILED"
		;;
	esac
}

# The pre-send newest check (see the header), once, before the first part
if [ -n "${SLACK_POST_AFTER_TS}" ]; then
	if ! echo "${SLACK_POST_AFTER_TS}" | grep -qE '^[0-9]+\.[0-9]+$'; then
		err "SLACK_POST_AFTER_TS '${SLACK_POST_AFTER_TS}' is not a Slack message ts (digits.digits)"
		exit 1
	fi
	SELF_ID=$(sed -n 's/.*user_id=\([^ ]*\).*/\1/p' "${SLACK_DIR}/identity" 2>/dev/null)
	if [ -z "${SELF_ID}" ]; then
		SELF_ID=$(slack_curl -sS --max-time 30 "${SLACK_API_BASE}/auth.test" \
			| "${NODE_BIN}" -e 'let r="";process.stdin.on("data",d=>r+=d);process.stdin.on("end",()=>{try{console.log(JSON.parse(r).user_id||"")}catch(e){console.log("")}})')
	fi
	if [ -n "${THREAD_TS}" ]; then
		NEWER_ARGS=(-G "${SLACK_API_BASE}/conversations.replies" --data-urlencode "channel=${CHANNEL}" --data-urlencode "ts=${THREAD_TS}")
	else
		NEWER_ARGS=(-G "${SLACK_API_BASE}/conversations.history" --data-urlencode "channel=${CHANNEL}")
	fi
	NEWER=$(slack_curl -sS --max-time 30 "${NEWER_ARGS[@]}" \
		--data-urlencode "oldest=${SLACK_POST_AFTER_TS}" --data-urlencode "limit=100" \
	| "${NODE_BIN}" -e '
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
	let r;
	try { r = JSON.parse(raw); } catch (e) { console.log("ERR\tunparseable-response"); return; }
	if (!r.ok) { console.log("ERR\t" + (r.error || "unknown-error")); return; }
	const [after, self, parent] = process.argv.slice(1);
	// the conversation the caller read: for a channel post only the top-level messages of the channel (a
	// thread_broadcast carries its thread_ts and belongs to its thread); for a thread post, that thread
	const inConversation = m => parent ? true : (!m.thread_ts || m.thread_ts === m.ts);
	const human = m => m.user && m.user !== self && (!m.subtype || m.subtype === "thread_broadcast" || m.subtype === "file_share") && inConversation(m);
	const newer = (r.messages || []).filter(m => m.ts !== parent && parseFloat(m.ts) > parseFloat(after) && human(m))
		.sort((a, b) => parseFloat(a.ts) - parseFloat(b.ts));
	if (newer.length) console.log("NEWER\t" + newer[0].ts + "\t" + newer[0].user + "\t" + (newer[0].text || "").replace(/\s+/g, " ").slice(0, 80));
	else console.log("NONE");
});' "${SLACK_POST_AFTER_TS}" "${SELF_ID}" "${THREAD_TS}")
	case "${NEWER}" in
	NONE) ;;
	NEWER*)
		N_TS=$(echo "${NEWER}" | cut -f2); N_USER=$(echo "${NEWER}" | cut -f3)
		[ -n "${SLACK_POST_STALE_RECORD}" ] && echo "${N_TS} ${N_USER}" >> "${SLACK_POST_STALE_RECORD}"
		# the newer message is a reply in this thread: the watcher must bring it in before the caller answers again
		# (see the header) - a thread the agent has not posted in yet is in no registry until this line
		if [ -n "${THREAD_TS}" ]; then
			mkdir -p "${SLACK_DIR}"
			register_thread
		fi
		echo "STALE: not posting - a newer message arrived in channel ${CHANNEL}${THREAD_TS:+ thread ${THREAD_TS}} after ts ${SLACK_POST_AFTER_TS}, which this answer was written from: ts=${N_TS} user=${N_USER} text=\"$(echo "${NEWER}" | cut -f4-)\" - read it and answer again" >&2
		exit 3
		;;
	*)
		err "refusing to post: the pre-send newest check could not re-read channel ${CHANNEL}${THREAD_TS:+ thread ${THREAD_TS}} ($(echo "${NEWER}" | cut -f2-))"
		exit 1
		;;
	esac
fi

# Slack splits a message longer than about 4,000 characters into several messages and returns only the
# first ts, so a long text goes out in parts of at most SLACK_POST_MAX_CHARS (default 3500) characters,
# split at line ends where it can; each part is posted and read back on its own, in order, in the same
# place (the same thread, or the channel). A split inside a ``` code block closes the fence at the end
# of the part and reopens it at the start of the next, so each part renders as the whole did.
FULL_TEXT=${TEXT}
mapfile -d '' PARTS < <("${NODE_BIN}" -e '
const text = process.argv[1], max = parseInt(process.argv[2], 10) || 3500;
const parts = [];
if (Array.from(text).length <= max) parts.push(text);
else {
	// a fence line toggles "inside a code block"; a part that ends inside one gets a closing fence and
	// the next part an opening one, so the budget for content leaves room for both (4 characters each)
	const fenced = /^```/m.test(text), room = fenced ? max - 8 : max;
	let cur = [], inFence = false, openNext = false;
	const flush = () => {
		let p = cur.join("").replace(/\n+$/, "");
		if (p.trim()) {
			if (openNext) p = "```\n" + p;
			openNext = false;
			if (inFence) { p += "\n```"; openNext = true; }
			parts.push(p);
		}
		cur = [];
	};
	for (const line of text.split(/(?<=\n)/)) {
		const lc = Array.from(line);
		if (lc.length > room) { flush(); for (let i = 0; i < lc.length; i += room) { cur = lc.slice(i, i + room); flush(); } }
		else { if (cur.length + lc.length > room) flush(); cur.push(...lc); }
		if (/^```/.test(line)) inFence = !inFence;
	}
	flush();
}
process.stdout.write(parts.join("\0") + "\0");' "${FULL_TEXT}" "${SLACK_POST_MAX_CHARS:-3500}")
N_PARTS=${#PARTS[@]}
if [ "${N_PARTS}" -eq 0 ]; then
	err "nothing to post: the text is empty once split"
	exit 1
fi
for I in "${!PARTS[@]}"; do
	TEXT=${PARTS[${I}]}
	PART_NOTE=""
	[ "${N_PARTS}" -gt 1 ] && PART_NOTE=" (part $((I + 1)) of ${N_PARTS})"
	post_one
done
