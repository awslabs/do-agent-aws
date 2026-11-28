#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Upload one file into a watched Slack channel or thread - with read-back verification.
#
# Usage: /agent/slack-upload.sh "<channel-id>" "<file-path>" [thread_ts] [initial_comment]
#
# With the optional third argument the file is shared as a reply in that thread (the thread_ts field
# of an inbox line, or a parent message's ts); pass "" for it to share the file in the channel with a
# comment. The optional fourth argument is the text of the message the file is attached to.
#
# The three-step upload Slack ships today (the retired files.upload is never called):
#   1. files.getUploadURLExternal (filename, length)    -> upload_url, file_id      [bot token]
#   2. POST the file's bytes to upload_url               -> HTTP 200                 [no token: the URL is the grant]
#   3. files.completeUploadExternal (files, channel_id, thread_ts, initial_comment)   [bot token]
#      -> ok:true, and Slack posts the file message into the channel or thread
# Steps 1 and 2 are invisible to the channel: a failure there leaves nothing on the platform (an
# upload that is never completed expires on Slack's side), so it is exit 1 and a retry is safe.
# Step 3 returning ok:true is the moment the file LANDED - from then on this script never lets the
# caller upload the file again (exit 4 or 5 below), the discipline slack-post.sh has for a message.
#
# Gated exactly as slack-post.sh is: the post gate (slack-gates.sh: SLACK_POST_ENABLED true, or auto /
# unset with SLACK_BOT_TOKEN and SLACK_CHANNELS set; false turns it off) and the SLACK_CHANNELS
# allow-list. The bot shares the file as ITSELF, never as a person. The scope needed is files:write
# (the manifest's second opt-in beside chat:write); a token without it is told so at step 1, with the
# reinstall step, and nothing is uploaded.
#
# ok:true from files.completeUploadExternal is a claim, not proof: the thread (conversations.replies)
# or the channel (conversations.history) is re-read and a message carrying this file_id in its files[]
# must be present before success is reported - three reads (at once, after 2 s, after 5 s more; file
# messages can lag). The message ts is then printed, and one line is appended to
# ${SLACK_DIR}/posted.jsonl (ts, channel, thread_ts for a thread, file_id, filename, and the first 200
# characters of the comment), as slack-post.sh does for a message; a thread share registers the thread
# with the watcher (register_thread), a channel share is watched for a threaded answer (watch_answer).
#
# Exit status, so a caller never uploads a file twice: 0 - uploaded, shared and read back; 4 - the
# file LANDED (files.completeUploadExternal returned ok:true) but the read-back could not find its
# message: the file is on the platform, do not upload it again; 5 - a transport failure on
# files.completeUploadExternal after the request may have reached Slack (a timeout, an empty reply):
# whether it landed is unknown, so do not upload it again either; 1 - nothing landed (a gate refusal, a
# bad argument, an unreadable or empty file, a failed step 1 or 2, an ok:false from step 3). An HTTP
# 429 on step 1 or 3 posts nothing, so it is retried once in place after Slack's Retry-After (at most
# 30 s); a second 429 fails the upload.
#
# SLACK_POST_RECORD (optional, the same file slack-post.sh writes) gets the word "unknown" the moment the
# file lands at step 3 - before the read-back - so the chat responder posts no fallback for an answer
# that is on the platform; once the read-back finds the file message its ts is appended and that
# "unknown" removed, so a landed-and-verified upload reads as one posted ts, as a message does.
#
# Safety of step 2: the bytes go only to an upload_url on *.slack.com over https, or to the origin of
# SLACK_API_BASE (the offline stub, /test24.sh); any other host is refused before a byte is sent.
# Settings, as for slack-post.sh: SLACK_BOT_TOKEN, SLACK_CHANNELS, SLACK_POST_ENABLED, SLACK_API_BASE,
# SLACK_DIR, SLACK_GATES_BIN, SLACK_POST_RECORD. The token reaches curl only through its config on stdin
# (slack_curl): never a word of a command line, never in an xtrace.

SLACK_API_BASE=${SLACK_API_BASE:-https://slack.com/api}
SLACK_DIR=${SLACK_DIR:-/wd/slack}
SLACK_UPLOAD_MAX_BYTES=${SLACK_UPLOAD_MAX_BYTES:-1073741824}

# Absolute path - may run detached without a login shell PATH; node builds and parses JSON because the
# image ships node (for Claude Code) but not jq - the same choice as slack-post.sh.
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

# upload_failed <message> - the upload did not complete. Exit 4 once the file has landed (step 3 said
# ok:true; "unknown" is in SLACK_POST_RECORD when set): the caller must not upload it again. Else exit 1.
LANDED=0
upload_failed()
{
	if [ "${LANDED}" -gt 0 ]; then
		err "$* - the file landed already (files.completeUploadExternal returned ok:true for file_id ${FILE_ID}${SLACK_POST_RECORD:+; \"unknown\" recorded in ${SLACK_POST_RECORD}}): do not upload this file again (exit 4)"
		exit 4
	fi
	err "$*"
	exit 1
}

# register_thread - add this share's thread to slack-watch.sh's thread registry (one line per thread,
# under the watcher's lock; a registered thread keeps its line) - the same function as slack-post.sh's,
# for the same reason: the replies that follow the agent's share must be collected.
register_thread()
{
	REGISTRY=${SLACK_DIR}/threads-${CHANNEL}
	(
		flock -w 60 7 || { echo "WARNING: thread ${THREAD_TS} not registered for watching: ${SLACK_DIR}/watch.lock busy for 60s" >&2; exit 0; }
		awk -v t="${THREAD_TS}" '$1 == t { found = 1 } END { exit !found }' "${REGISTRY}" 2>/dev/null \
			|| echo "${THREAD_TS} ${THREAD_TS}" >> "${REGISTRY}"
	) 7> "${SLACK_DIR}/watch.lock"
}

# watch_answer - list this top-level share in slack-watch.sh's answers-<channel> file (as slack-post.sh
# does for a channel post): a person may answer it in a thread under it.
watch_answer()
{
	ANSWERS=${SLACK_DIR}/answers-${CHANNEL}
	(
		flock -w 60 7 || { echo "WARNING: share ${TS} not watched for threaded replies: ${SLACK_DIR}/watch.lock busy for 60s" >&2; exit 0; }
		NOW_S=$(date +%s)
		{ awk -v now="${NOW_S}" 'NF >= 2 && $2 > now' "${ANSWERS}" 2>/dev/null
		  echo "${TS} $(( NOW_S + ${SLACK_ANSWER_WATCH_SECONDS:-7200} ))"; } \
			| tail -n "${SLACK_ANSWER_WATCH_MAX:-5}" > "${ANSWERS:?}.tmp" && mv "${ANSWERS:?}.tmp" "${ANSWERS:?}"
	) 7> "${SLACK_DIR}/watch.lock"
}

# Gate 1: the post gate must be on - the shared decision in slack-gates.sh (beside this script)
SLACK_GATES_BIN=${SLACK_GATES_BIN:-$(dirname "$0")/slack-gates.sh}
if [ ! -f "${SLACK_GATES_BIN}" ]; then
	err "${SLACK_GATES_BIN} not found - slack-gates.sh ships beside slack-upload.sh; set SLACK_GATES_BIN if it lives elsewhere"
	exit 1
fi
. "${SLACK_GATES_BIN}"
if [ "${SLACK_POST_EFFECTIVE}" != "on" ]; then
	err "refusing to upload: the post gate is off (${SLACK_POST_REASON}). Uploading, like posting, is on when SLACK_POST_ENABLED=true, or when it is auto or unset (the .env default) and both SLACK_BOT_TOKEN and SLACK_CHANNELS are set; SLACK_POST_ENABLED=false turns it off. /agent/slack-status.sh shows the effective gates."
	exit 1
fi

CHANNEL=$1
FILE=$2
THREAD_TS=$3
COMMENT=$4
if [ -z "${CHANNEL}" ] || [ -z "${FILE}" ]; then
	err "usage: $0 \"<channel-id>\" \"<file-path>\" [thread_ts] [initial_comment]"
	exit 1
fi
if [ -n "${THREAD_TS}" ] && ! echo "${THREAD_TS}" | grep -qE '^[0-9]+\.[0-9]+$'; then
	err "thread_ts '${THREAD_TS}' is not a Slack message ts (digits.digits) - pass the thread_ts field of the inbox line, or \"\" to share the file in the channel"
	exit 1
fi

# Gate 2: only channels the agent is configured to watch
ALLOWED=false
for C in $(echo "${SLACK_CHANNELS}" | tr ',' ' '); do
	[ "${C}" = "${CHANNEL}" ] && ALLOWED=true
done
if [ "${ALLOWED}" != "true" ]; then
	err "refusing to upload: channel '${CHANNEL}' is not in SLACK_CHANNELS ('${SLACK_CHANNELS:-empty}'). Add it to SLACK_CHANNELS in .env.local to allow sharing files there."
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

# The file: present, readable, not empty, within Slack's size limit
if [ ! -f "${FILE}" ] || [ ! -r "${FILE}" ]; then
	err "file '${FILE}' does not exist or is not readable - nothing uploaded"
	exit 1
fi
SIZE=$(stat -c %s -- "${FILE}" 2>/dev/null)
if ! echo "${SIZE}" | grep -qE '^[0-9]+$' || [ "${SIZE}" -eq 0 ]; then
	err "file '${FILE}' is empty (${SIZE:-unreadable} bytes) - nothing uploaded"
	exit 1
fi
if [ "${SIZE}" -gt "${SLACK_UPLOAD_MAX_BYTES}" ]; then
	err "file '${FILE}' is ${SIZE} bytes, above the ${SLACK_UPLOAD_MAX_BYTES}-byte limit (SLACK_UPLOAD_MAX_BYTES; Slack's own is 1 GB) - nothing uploaded"
	exit 1
fi
FILENAME=$(basename -- "${FILE}")

# parse_json_line <node snippet> - reads ${RESP}, prints one tab-separated line
# 429 handling shared by steps 1 and 3: honor Retry-After once (at most 30 s), then fail
# rate_limited <method> <headers file> <try number> - returns 0 when the call should be made again
rate_limited()
{
	head -1 "$2" | grep -q " 429" || return 1
	RETRY_AFTER=$(grep -i '^Retry-After:' "$2" | tail -1 | tr -d '\r' | awk '{print $2}')
	mkdir -p "${SLACK_DIR}"
	echo "${RETRY_AFTER:-30}" > "${SLACK_DIR}/retry-after"
	if [ "$3" -eq 1 ]; then
		WAIT=$(echo "${RETRY_AFTER}" | tr -dc '0-9')
		[ -z "${WAIT}" ] && WAIT=30
		[ "${WAIT}" -gt 30 ] && WAIT=30
		[ "${WAIT}" -lt 1 ] && WAIT=1
		echo "Note: Slack rate limited $1 (HTTP 429, Retry-After ${RETRY_AFTER:-unknown}s); nothing was uploaded by it - calling it again in ${WAIT}s"
		sleep "${WAIT}"
		return 0
	fi
	upload_failed "Slack rate limited $1 twice (HTTP 429, Retry-After ${RETRY_AFTER:-unknown}s; recorded in ${SLACK_DIR}/retry-after)"
}

# --- step 1: files.getUploadURLExternal -> upload_url, file_id (nothing visible yet: every failure is exit 1) ---
TRIES=0
while :; do
	TRIES=$((TRIES + 1))
	HDRS=$(mktemp)
	RESP=$(slack_curl -sS --max-time 30 -D "${HDRS}" \
		--data-urlencode "filename=${FILENAME}" \
		--data-urlencode "length=${SIZE}" \
		"${SLACK_API_BASE}/files.getUploadURLExternal")
	CURL_RC=$?
	if [ "${CURL_RC}" -ne 0 ]; then
		rm -f "${HDRS:?}"
		upload_failed "curl to ${SLACK_API_BASE}/files.getUploadURLExternal failed (curl exit ${CURL_RC}) - nothing uploaded, a retry is safe"
	fi
	if rate_limited files.getUploadURLExternal "${HDRS}" "${TRIES}"; then
		rm -f "${HDRS:?}"
		continue
	fi
	rm -f "${HDRS:?}"
	[ "${TRIES}" -gt 1 ] && rm -f "${SLACK_DIR:?}/retry-after"
	break
done
URL_LINE=$(echo "${RESP}" | "${NODE_BIN}" -e '
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
	let r;
	try { r = JSON.parse(raw); } catch (e) { console.log("ERR\tunparseable-response"); return; }
	if (!r.ok) { console.log("ERR\t" + (r.error || "unknown-error") + (r.needed ? "\t" + r.needed : "")); return; }
	if (!r.upload_url || !r.file_id) { console.log("ERR\tno-upload_url-or-file_id-in-response"); return; }
	console.log("OK\t" + r.upload_url + "\t" + r.file_id);
});
')
case "${URL_LINE}" in
OK*)
	UPLOAD_URL=$(echo "${URL_LINE}" | cut -f2)
	FILE_ID=$(echo "${URL_LINE}" | cut -f3)
	;;
*)
	API_ERR=$(echo "${URL_LINE}" | cut -f2)
	if [ "${API_ERR}" = "missing_scope" ]; then
		upload_failed "files.getUploadURLExternal refused: missing_scope (needed: $(echo "${URL_LINE}" | cut -f3-)) - the bot token has no files:write. Add files:write to the app manifest's bot scopes (the opt-in beside chat:write), reinstall the app to the workspace, replace SLACK_BOT_TOKEN, restart; /agent/slack-doctor.sh shows the granted scopes. Nothing uploaded."
	fi
	upload_failed "files.getUploadURLExternal failed for '${FILENAME}' (${SIZE} bytes): $(echo "${URL_LINE}" | cut -f2-) - nothing uploaded"
	;;
esac

# The bytes go to Slack's file host, or to the stub that SLACK_API_BASE names - nowhere else
URL_VERDICT=$("${NODE_BIN}" -e '
let v = "DENY";
try {
	const u = new URL(process.argv[1]), base = new URL(process.argv[2]);
	if ((u.protocol === "https:" && (u.hostname === "slack.com" || u.hostname.endsWith(".slack.com"))) || u.origin === base.origin) v = "ALLOW";
} catch (e) { v = "DENY"; }
console.log(v);' "${UPLOAD_URL}" "${SLACK_API_BASE}")
if [ "${URL_VERDICT}" != "ALLOW" ]; then
	upload_failed "refusing to upload: files.getUploadURLExternal answered with an upload_url that is neither on slack.com over https nor at the origin of SLACK_API_BASE (${SLACK_API_BASE}): $(echo "${UPLOAD_URL}" | cut -c1-120) - no byte sent"
fi

# --- step 2: POST the bytes to upload_url (no token; nothing visible yet: every failure is exit 1) ---
UP_BODY=$(mktemp)
UP_CODE=$(curl -sS --max-time 600 -o "${UP_BODY}" -w '%{http_code}' \
	-H "Content-Type: application/octet-stream" \
	--data-binary "@${FILE}" "${UPLOAD_URL}")
CURL_RC=$?
if [ "${CURL_RC}" -ne 0 ]; then
	rm -f "${UP_BODY:?}"
	upload_failed "the upload of '${FILENAME}' (${SIZE} bytes) to Slack's upload URL failed (curl exit ${CURL_RC}) - nothing shared (an uncompleted upload expires on Slack's side), a retry is safe"
fi
case "${UP_CODE}" in
2[0-9][0-9]) ;;
*)
	UP_TEXT=$(head -c 200 "${UP_BODY}" | tr '\n' ' ')
	rm -f "${UP_BODY:?}"
	upload_failed "the upload of '${FILENAME}' (${SIZE} bytes) to Slack's upload URL answered HTTP ${UP_CODE}: ${UP_TEXT} - nothing shared, a retry is safe"
	;;
esac
rm -f "${UP_BODY:?}"

# --- step 3: files.completeUploadExternal - the file lands here ---
BODY=$("${NODE_BIN}" -e '
const body = { files: [{ id: process.argv[1], title: process.argv[2] }], channel_id: process.argv[3] };
if (process.argv[4]) body.thread_ts = process.argv[4];
if (process.argv[5]) body.initial_comment = process.argv[5];
console.log(JSON.stringify(body));' "${FILE_ID}" "${FILENAME}" "${CHANNEL}" "${THREAD_TS}" "${COMMENT}")
OLDEST=$(( $(date +%s) - 300 )).000000
TRIES=0
while :; do
	TRIES=$((TRIES + 1))
	HDRS=$(mktemp)
	RESP=$(slack_curl -sS --max-time 60 -D "${HDRS}" \
		-H "Content-Type: application/json; charset=utf-8" \
		-d "${BODY}" "${SLACK_API_BASE}/files.completeUploadExternal")
	CURL_RC=$?
	if [ "${CURL_RC}" -ne 0 ]; then
		rm -f "${HDRS:?}"
		case "${CURL_RC}" in
		5|6|7|35)
			# nothing was sent: no proxy, no route, no connection, no TLS - the file is uploaded but unshared
			upload_failed "curl to ${SLACK_API_BASE}/files.completeUploadExternal failed before anything was sent (curl exit ${CURL_RC}) - nothing shared, a retry (a new upload) is safe"
			;;
		*)
			# the request may have reached Slack (a timeout, an empty reply, a lost connection): whether the
			# file message landed is unknown, so it is treated as landed - never uploaded again
			[ -n "${SLACK_POST_RECORD}" ] && echo "unknown" >> "${SLACK_POST_RECORD}"
			err "curl to ${SLACK_API_BASE}/files.completeUploadExternal failed after the request may have reached Slack (curl exit ${CURL_RC}) for file_id ${FILE_ID}: whether the file message landed is unknown - do not upload this file again (exit 5)"
			exit 5
			;;
		esac
	fi
	if rate_limited files.completeUploadExternal "${HDRS}" "${TRIES}"; then
		rm -f "${HDRS:?}"
		continue
	fi
	rm -f "${HDRS:?}"
	[ "${TRIES}" -gt 1 ] && rm -f "${SLACK_DIR:?}/retry-after"
	break
done
DONE_LINE=$(echo "${RESP}" | "${NODE_BIN}" -e '
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
	let r;
	try { r = JSON.parse(raw); } catch (e) { console.log("ERR\tunparseable-response"); return; }
	if (!r.ok) { console.log("ERR\t" + (r.error || "unknown-error") + (r.needed ? " (needed: " + r.needed + ")" : "")); return; }
	console.log("OK\t" + ((r.files || []).map(f => f.id).join(",") || "no-files-listed"));
});
')
case "${DONE_LINE}" in
OK*)
	# Landed: on the platform from here on, whatever the read-back finds - recorded at once
	LANDED=1
	if [ -n "${SLACK_POST_RECORD}" ]; then
		echo "unknown" >> "${SLACK_POST_RECORD}"
	fi
	;;
*)
	upload_failed "files.completeUploadExternal failed for file_id ${FILE_ID} ('${FILENAME}') in channel ${CHANNEL}${THREAD_TS:+ thread ${THREAD_TS}}: $(echo "${DONE_LINE}" | cut -f2-) - the file is uploaded but not shared (it expires unshared), nothing is in the channel; a retry (a new upload) is safe"
	;;
esac

# --- read-back: the message carrying this file_id must be in the thread or the channel ---
verify()
{
	if [ -n "${THREAD_TS}" ]; then
		READ_METHOD=conversations.replies
		READ_ARGS=(--data-urlencode "channel=${CHANNEL}" --data-urlencode "ts=${THREAD_TS}")
	else
		READ_METHOD=conversations.history
		READ_ARGS=(--data-urlencode "channel=${CHANNEL}")
	fi
	slack_curl -sS --max-time 30 \
		-G "${SLACK_API_BASE}/${READ_METHOD}" "${READ_ARGS[@]}" \
		--data-urlencode "oldest=${OLDEST}" \
		--data-urlencode "inclusive=true" \
		--data-urlencode "limit=100" \
	| "${NODE_BIN}" -e '
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
	let r;
	try { r = JSON.parse(raw); } catch (e) { console.log("MISSING\tunparseable-response"); return; }
	if (!r.ok) { console.log("MISSING\t" + (r.error || "unknown-error")); return; }
	const id = process.argv[1];
	const hit = (r.messages || []).find(m => (m.files || []).some(f => f && f.id === id));
	if (!hit) { console.log("MISSING\tfile-message-not-found\t" + (r.messages || []).length); return; }
	console.log("FOUND\t" + hit.ts + "\t" + (hit.text || "").replace(/\s+/g, " ").slice(0, 200));
});
' "${FILE_ID}"
}

VERIFY_LINE=$(verify)
case "${VERIFY_LINE}" in
FOUND*) ;;
*)
	sleep 2
	VERIFY_LINE=$(verify)
	case "${VERIFY_LINE}" in
	FOUND*) ;;
	*)
		sleep 5
		VERIFY_LINE=$(verify)
		;;
	esac
	;;
esac

case "${VERIFY_LINE}" in
FOUND*)
	TS=$(echo "${VERIFY_LINE}" | cut -f2)
	if [ -n "${SLACK_POST_RECORD}" ]; then
		# the landed file now has its message ts: the "unknown" written at step 3 is resolved by it
		echo "${TS}" >> "${SLACK_POST_RECORD}"
		awk 'BEGIN { d = 0 } $0 == "unknown" && !d { d = 1; next } { print }' "${SLACK_POST_RECORD}" > "${SLACK_POST_RECORD}.tmp" \
			&& mv "${SLACK_POST_RECORD}.tmp" "${SLACK_POST_RECORD}"
	fi
	mkdir -p "${SLACK_DIR}"
	REC=$("${NODE_BIN}" -e '
	const o = { ts: process.argv[1], channel: process.argv[2] };
	if (process.argv[3]) o.thread_ts = process.argv[3];
	o.file_id = process.argv[4]; o.filename = process.argv[5];
	o.text = Array.from(process.argv[6] || "").slice(0, 200).join("");
	process.stdout.write(JSON.stringify(o));' "${TS}" "${CHANNEL}" "${THREAD_TS}" "${FILE_ID}" "${FILENAME}" "${COMMENT}")
	echo "${REC}" >> "${SLACK_DIR}/posted.jsonl"
	if [ -n "${THREAD_TS}" ]; then
		register_thread
		echo "Uploaded and read-back verified: channel=${CHANNEL} ts=${TS} thread_ts=${THREAD_TS} file_id=${FILE_ID} filename=${FILENAME} bytes=${SIZE}"
	else
		watch_answer
		echo "Uploaded and read-back verified: channel=${CHANNEL} ts=${TS} file_id=${FILE_ID} filename=${FILENAME} bytes=${SIZE}"
	fi
	;;
*)
	upload_failed "files.completeUploadExternal returned ok:true for file_id ${FILE_ID}, but the read-back could not find a message carrying it in channel ${CHANNEL}${THREAD_TS:+ thread ${THREAD_TS}} ($(echo "${VERIFY_LINE}" | cut -f2-)); treating as FAILED"
	;;
esac
