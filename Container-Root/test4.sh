#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the Slack connectivity scripts (/agent/slack-*.sh) and their autonomy-loop hook.
# Fully OFFLINE: a stateful stub Slack API (node http server, 127.0.0.1, ephemeral port) stands
# in for slack.com via the SLACK_API_BASE override that the scripts support precisely for this
# purpose. No real Slack call is made by this test.
#
# Properties proven:
#   1.  all new/changed scripts parse (bash -n)
#   2.  empty SLACK_BOT_TOKEN fails loud (nonzero + clear message) for watch and post
#   3.  a bad token fails loud with the API error (invalid_auth)
#   4.  watch ingests channel messages AND thread replies (invisible to history), inbox is
#       chronological JSONL, the cursor advances, pagination is followed (stub pages at 2)
#   5.  a second watch ingests nothing new (no duplicates, cursor stable)
#   6.  a NEW reply to an OLD thread parent is collected on a later watch - the load-bearing
#       thread-reply trap (see docs/slack/README.md)
#   7.  post refuses when SLACK_POST_ENABLED is not true, and for channels not in
#       SLACK_CHANNELS - and the stub proves nothing was posted
#   8.  post + read-back verify passes and prints the message ts
#   9.  status reports honestly and never prints the token value
#   10. a loop fire (loop-once.sh, same gated block as loop.sh) includes the unprocessed inbox
#       in the prompt and moves it to processed.jsonl afterwards; with the gate off (default)
#       the prompt and state are exactly as before
#   11. with NO user goals file, a fire happens on the shipped default goals
#       (/agent/goals-default.md) when the watch is on and the inbox is non-empty: the prompt
#       names the default goals file and the absent user goals path, the BEGIN line marks the
#       default, and the inbox is drained to processed.jsonl
#   12. with no user goals file and an EMPTY inbox, loop-once.sh refuses (nothing to fire
#       against, no claude call) but the watch DID run - this is the check that fails if the
#       watch is coupled to the goals file again ("LOOP IDLE goals file not found" with a
#       watcher that never polled)
#   13. loop.sh itself: idles with no claude call while the inbox is empty, runs exactly one
#       watch per cycle, fires on the default goals within one interval of a Slack message
#       arriving (with a prompt that forbids the stop flag), and halts on the STOP flag
#   14. gate off + no goals file: loop-once.sh still refuses with "nothing to fire against" and
#       loop.sh logs exactly the pre-change IDLE line; no SLACK lines, no slack-watch.log, no
#       claude call
#   15. the fire's claude call (ok 18-20): by default claude gets exactly `-p` and the safe value (the allow rules
#       FIRST, then acceptEdits) with no IS_SANDBOX; the opt-in --dangerously-skip-permissions gets IS_SANDBOX=1; no
#       positional argument - and the full prompt (SLACK INBOX included) on stdin; an
#       AUTONOMY_LOOP_CLAUDE_OPTS override is passed verbatim (no rule when it names none); and the
#       old-order override `--permission-mode acceptEdits --allowedTools Bash(...)`, which used to
#       swallow a positional prompt into the variadic --allowedTools and fail the fire, now
#       completes because the prompt is on stdin. The fake claude mimics the real parser, so the
#       checks fail if the prompt becomes positional again or the default changes.
#   16. the gates (ok 21-24; /agent/slack-gates.sh, shared by loop.sh, loop-once.sh, slack-post.sh,
#       slack-status.sh and startup.sh): with AUTONOMY_LOOP, SLACK_WATCH_ENABLED and
#       SLACK_POST_ENABLED unset and a token and channels set, all three are on - a fire gets the
#       inbox and slack-post.sh posts with read-back (ok 21; fails if slack-post.sh requires the
#       literal "true" again); SLACK_POST_ENABLED=false refuses posting while the watch still runs
#       (ok 22); with the token empty all three are off, the refusal names the auto rule, and a fire
#       runs without Slack context and without error (ok 23); AUTONOMY_LOOP=false turns the
#       autostart decision off, a value other than true/false/auto is off with a WARNING, and an
#       explicit true is on with nothing configured (ok 24)
#   17. the Slack chat responder (ok 25-30; /agent/slack-chat.sh with slack-chat-start/stop/status.sh,
#       agent-status.sh, goals-add.sh): with SLACK_CHAT_ENABLED unset and a token and channels set it
#       runs beside a loop whose interval is 600 s and answers a seeded message within 15 s while the
#       loop stays IDLE - the check that fails if replies ride the loop interval - its claude argv is exact even with
#       a path matching its rule planted in its working directory (PLANTED CONTROL: the shell expands the word there),
#       and the loop logs
#       that the intake is owned by the responder and idles with the plain goals-file IDLE line (ok 25); "status"
#       and "goals" are answered with NO claude call and the status reply carries the loop.state line
#       (ok 26); "please add a goal: ..." lands in the goals file under "## Goals from Slack" and the
#       reply says so (ok 27); no double answer: exactly one reply per inbound message while both
#       processes run, the bot's own replies are skipped when they come back through the watch, each
#       handled line is in processed.jsonl once, a message in a thread is answered in that thread, and
#       a TOP-LEVEL message is answered in a thread under it (SLACK_REPLY_IN_THREAD, the default): the
#       reply's thread_ts is the message's own ts, posted.jsonl and the watcher's registry carry that
#       thread, and the person's follow-up in it is collected and answered there (ok 28);
#       an HTTP 429 from the stub is honored (Retry-After slept, the next message still
#       answered) (ok 29); slack-chat-stop.sh halts it (chat.state STOPPED), slack-chat-status.sh
#       reports it, slack-chat-start.sh brings it back - restarted with SLACK_REPLY_IN_THREAD=false it
#       answers a top-level message top-level, where the person wrote, its log says reply_thread=none (ok 30)
#   18. SLACK_CHAT_ENABLED=false (ok 31): the responder refuses to start with a clear message, the
#       chat gate reports off while the other three stay on, and the loop keeps its own per-cycle Slack watch -
#       checks 12-24 above run with the explicit false and are unchanged
#   19. no answer from stale context, bounded (ok 37-38): slack-post.sh refuses (exit 3) an answer
#       written before a newer message in the same conversation; a thread reply also sent to the channel
#       counts in its thread, never for a channel answer (the inbox files it under its thread, so counting
#       it would refuse the channel answer on every poll); the chat responder answers again with the
#       newer message, and after 3 refusals (or 120 s) for a message the watch never brings in it
#       answers without the check and logs CHAT STALE CAP - the queue is never held forever. The
#       responder's conversation is the thread its answer goes to (SLACK_REPLY_IN_THREAD): a follow-up in
#       the thread under a top-level message refuses the answer, a newer top-level message - another
#       topic - does not; a refused thread post registers its thread for the watch, so the follow-up that
#       refused it is in view when the message is answered again; with SLACK_REPLY_IN_THREAD=false the
#       conversation is the channel's top level again - a top-level follow-up refuses the answer, written
#       again with it in view, top-level (ok 38)
#   20. never a text twice (ok 42): slack-post.sh retries a rate-limited part once in place, exits 4
#       once a part has landed but the post did not complete (a later part failed, a read-back failed)
#       with each landed part's ts in SLACK_POST_RECORD, and 5 when a transport failure left it unknown
#       whether a part landed, recorded as "unknown" in SLACK_POST_RECORD; the responder's post_reply retries
#       only a run that posted nothing (exit 1) and never a run that exited 4 or 5, and the model path posts no
#       fallback after an unknown post; both prompts tell the model what exits 4 and 5 mean
#   21. no message lost to a failed call (ok 43): the channel cursor advances only once the run's
#       messages are in the inbox, so a conversations.replies call that fails (HTTP 429) after history
#       brought a new message leaves the cursor where it was, and the next watch collects it exactly once
#   26. one broken thread does not hold the intake (ok 47): a thread whose conversations.replies call answers an
#       API error ends the run (nothing committed) the first SLACK_THREAD_FAIL_SKIP times (3), then is skipped
#       for SLACK_THREAD_FAIL_BACKOFF seconds, logged, so the channels' history and the other threads get
#       through; a success forgets its failures; a 429 or a transport failure counts against no thread
#   25. a long post as a whole (ok 46): every part of a multi-part top-level post is listed for the answer
#       watch, so a reply threaded under any part is collected; a split inside a ``` code block closes the
#       fence at the end of the part and reopens it at the start of the next, each part within the limit
#   24. nothing to processed.jsonl unanswered (ok 45): a loop fire whose answer was refused as stale, or
#       that timed out, leaves its batch in the inbox; the next fire gets it marked CARRIED with the posts
#       the fire landed listed, answers each message once, and only then is the batch processed; after 3
#       carries the next fire posts without the newest check and the batch is processed when it ends well
#   27. nothing consumed by a failed fire (ok 48): a fire that exits nonzero carries its batch like a stale
#       refusal or a timeout; at the carry bound a fire that fails again leaves the batch in the inbox, marked,
#       logging the carry bound with the message count and the oldest ts; a fire that ends well processes it, once
#   28. no message lost to a failed inbox write (ok 49): the channel's batch is appended in one checked write; when
#       it fails (here: the inbox path is a directory) the run ends with an error, neither the channel cursor nor a
#       thread's reply cursor moves, nothing is in the inbox, and the next watch brings the messages exactly once
#   29. no message consumed by a post that did not land (ok 50): a post that failed outright keeps the message first
#       in the inbox and it is answered again next poll (two failures, one answer, processed once); after
#       SLACK_CHAT_POST_RETRIES failed attempts the line is set aside in unanswered.jsonl, logged with the path,
#       never processed, and the queue moves on; the model path keeps the message when its post and the fallback fail
#   30. no answer before the thread is read (ok 51): with the replies budget used up, a new thread's first
#       conversations.replies call is deferred and its parent reaches the inbox alone; the responder waits (CHAT WAIT,
#       no model call) until the call is made, then answers once with the early reply in view - no stale refusal, one
#       model call, one handling; a thread never read is answered after SLACK_CHAT_STALE_MAX_SECONDS (CHAT WAIT CAP)
#   31. one lock for every inbox writer (ok 52): a consumer's removal of a handled line cannot land under the watcher's
#       append (a cat shim tries it, taking the lock as the consumers do: the append is clean, every line JSON); a writer
#       that ignores the lock replaces the file under the append and the watcher refuses without touching it - no NUL
#       padding, the cursor held, the message brought once by the next watch; the responder's and the loop's removals
#       wait while another process holds the lock
#   32. a batch no fire answers is set aside, not fed forever (ok 53): after SLACK_LOOP_CARRY_MAX carries and
#       SLACK_LOOP_BOUND_FIRES failing fires at the bound the batch moves to unanswered.jsonl with a loud line naming
#       the path, the count and the oldest ts, never to processed.jsonl, and the next fire gets no batch; the carry
#       note's list of landed posts keeps each post once and the newest SLACK_LOOP_CARRY_POSTS_MAX, the rest counted
#   33. a line without a channel is not fatal (ok 54): an inbox line with a ts but no channel is skipped with a CHAT SKIP
#       line and moved to processed.jsonl like an unparseable one; the responder stays up and answers the valid message
#       behind it once
#   23. one rolling conversations.replies budget (ok 44): SLACK_REPLIES_BUDGET calls per
#       SLACK_REPLIES_WINDOW seconds across the thread registry and the answers/asks lists, the least
#       recently polled threads first - 6 threads with a budget of 3 get exactly 3 calls, the run says it
#       deferred 3, a run right after makes none, and the other 3 are polled in the next window; a reply
#       in a deferred thread is collected then, once
#   22. the exact read-back accepts a text sent with Slack's own <url|label> link markup (ok 35): both
#       sides are compared with the rendering undone, so a correct post is not reported FAILED and
#       re-posted for its markup
#   24. AUTONOMY_LOOP_CLAUDE_OPTS set in .env.local reaches a fire's claude (ok 58): the checkout's .env passes it
#       bare (-e NAME: docker copies the value from the environment of the ./run.sh that read .env and .env.local).
#       With a planted .env.local beside a scratch copy of .env, the container would hold the value whole and the
#       fire's claude gets it word for word; unset, nothing is passed (the fire keeps the default, ok 18). Fails
#       while .env does not pass it (the value never arrives) or passes it as NAME=value (its spaces split the
#       value, and its parentheses stop ./run.sh's eval with a syntax error)
#   25. the compose and kubernetes templates pass AUTONOMY_LOOP_CLAUDE_OPTS like the other four loop settings (ok 59):
#       AUTONOMY_LOOP_CLAUDE_OPTS=${AUTONOMY_LOOP_CLAUDE_OPTS} in the compose environment and a name/value pair with
#       "${AUTONOMY_LOOP_CLAUDE_OPTS}" in the deployment, each in the list and at the indentation of
#       AUTONOMY_LOOP_FIRE_TIMEOUT (unset, they render an empty value, which loop.sh reads as its default)
#   26. a fire's option words are split on spaces but never glob-expanded (ok 60): with paths planted in the fire's
#       working directory that match Bash(/agent/slack-post.sh:*) and Read(//opt/planted-60/**) - PLANTED CONTROL: the
#       shell expands the words there - loop-once.sh's fire and loop.sh's give claude the words as written
#   27. a rule with a space inside its parentheses is ONE argument of the fire's claude call (ok 61): the option string
#       is split on blanks outside parentheses only (/agent/claude-opts.sh, shared by loop.sh, loop-once.sh and
#       slack-chat.sh), so Bash(bash /wd/loop/run-next-fire/apply_to_source.sh:*) reaches claude whole - PLANTED CONTROL:
#       the shell's own word splitting breaks it in two - through loop-once.sh and loop.sh; the safe value's argv is
#       byte for byte what it was. Split by the shell, such a rule would reach claude as two
#       words, the second refused ("Ignoring --allowedTools rule ... Wildcard tool name ... is not supported in allow
#       rules"), every call it allowed denied, the fire running on until its timeout
#   28. a word that cannot be a rule is reported BEFORE the fire, not after its timeout (ok 62): the tail of a rule
#       split on its space, a parenthesis left open and a rule without its tool name each make loop-once.sh (exit 96, the
#       report on stderr) and loop.sh (LOOP CONFIG at start) skip the fire with no claude call - END rc=96 duration=0s
#       outcome=config <report> with the word quoted, the report as the transcript, the state and agent-status.sh naming
#       it; AUTONOMY_LOOP_OPTS_CHECK=false runs the fire with the words as written and a WARNING names the word
#   29. claude's own "Ignoring --allowedTools rule" line in a transcript is named on the END line (ok 63): a completed
#       fire stays rc=0, outcome=ok ignored-rule "<word>" (not 97: it did its work), agent-status.sh says so; a fire that
#       also timed out keeps timeout first
#   30. the chat responder reads the same file (ok 64): a word that cannot be a rule in SLACK_CHAT_CLAUDE_OPTS is reported
#       at CHAT START and each message that needs the model is answered with one honest line, no model call (CHAT MODEL
#       rc=96 config=<report>, the report as the transcript), while status is still answered; with
#       AUTONOMY_LOOP_OPTS_CHECK=false the model is called with the words as written and a CHAT WARNING names the word;
#       a rule with a space is one argument of the responder's call
# Uses a test-local state directory (/tmp/slack-smoke); does not disturb live state under /wd.

D=/tmp/slack-smoke
rm -rf "${D:?}"
mkdir -p ${D}

# Locate the agent scripts both in-container (/agent) and in a repo checkout (Container-Root/agent)
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"

NODE_BIN=${NODE_BIN:-$(command -v node || echo /usr/local/bin/node)}
if [ ! -x "${NODE_BIN}" ]; then
	echo "Test4 skipped: node not found (needed for the stub Slack API and the scripts)"
	exit 0
fi
export NODE_BIN

STUB_PID=""
LOOP_PID=""
CHAT_PID=""
trap 'kill ${LOOP_PID} ${CHAT_PID} ${STUB_PID} 2>/dev/null' EXIT
fail()
{
	echo "Test4 FAILED: $1"
	[ -n "${CHAT_PID}" ] && kill "${CHAT_PID}" 2>/dev/null
	[ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null
	exit 1
}

# --- 1. syntax ---
for S in slack-watch.sh slack-post.sh slack-upload.sh slack-status.sh slack-gates.sh loop.sh loop-once.sh loop-inbox.sh claude-opts.sh fire-outcome.sh \
	slack-chat.sh slack-chat-start.sh slack-chat-stop.sh slack-chat-status.sh agent-status.sh goals-add.sh; do
	bash -n "${AGENT_DIR}/${S}" || fail "bash -n ${S}"
done
echo "ok 1 - syntax"

# --- stub Slack API ---
cat > ${D}/stub.js << 'EOF'
// Stateful stub Slack Web API for test4.sh - 127.0.0.1 only, ephemeral port.
// Seeds channel C0TESTCHAN with 3 channel messages; the 2nd is a thread parent with 1 reply.
// history: parents only (the thread-reply trap), newest first, PAGE SIZE 2 to force pagination.
// Extra test-only endpoints: stub.seedReply (adds a reply to the parent m2, or to the parent named by
// ?thread=<ts>), stub.seedMessage (adds a top-level human message), stub.ratelimit?n=N (the next N
// conversations.history calls answer HTTP 429 with Retry-After: 1), stub.state (message count, number
// of chat.postMessage posts, the last post, and every post in order). chat.postMessage keeps thread_ts,
// so a thread reply is invisible to history and visible to replies; a reply, seeded or posted, bumps
// its parent's reply_count, as Slack does. stub.alterNext?mode=escape|truncate changes how the next
// post is stored: escape renders & < > as Slack does, truncate keeps only its first half. A parent that gets a
// reply carries thread_ts equal to its own ts from then on, as Slack's does. A post longer
// than 4,000 characters is stored as consecutive messages of at most 4,000, and only the first ts is
// returned - Slack's silent split. conversations.replies answers with the thread's parent first on
// every call, whatever oldest says, as Slack's does; a ts that is no message is thread_not_found.
// stub.seedBroadcast?thread=<ts>&text= adds a reply "also sent to the channel": subtype thread_broadcast
// with its thread_ts, listed by history (as Slack lists broadcasts) and by replies on its thread.
// stub.failPosts?calls=2,3 makes those chat.postMessage calls, counted from the knob being set, answer
// HTTP 429 with Retry-After: 1 and post nothing, as Slack's rate limit does; with &mode=drop they store the
// message and close the connection without a response instead - the post landed, the response was lost;
// with &mode=error they answer ok:false fatal_error and post nothing - an API error that is no rate limit.
// stub.failThread?ts=<ts>&n=K: the next K conversations.replies calls for that thread answer ok:false internal_error. stub.ratelimitReplies?n=N:
// the next N conversations.replies calls answer HTTP 429 with Retry-After: 1.
const http = require("http");
const TOKEN = "Bearer xoxb-test-stub";
const CHAN = "C0TESTCHAN";
let seq = 0;
const t0 = Math.floor(Date.now() / 1000);
const ts = () => (t0 + seq++).toFixed(6) ;
const msgs = [];
const m1 = { ts: ts(), user: "U0PERSON", text: "hello agent" };
const m2 = { ts: ts(), user: "U0PERSON", text: "please review the deployment", reply_count: 0 };
const m3 = { ts: ts(), user: "U0PERSON", text: "third message" };
msgs.push(m1, m2, m3);
const r1 = { ts: ts(), user: "U0PERSON", text: "thread reply one", thread_ts: m2.ts };
msgs.push(r1); m2.reply_count = 1;
let posted = 0;
let lastPost = null;
const posts = [];
let ratelimit = 0;
let alterNext = null;
let failPosts = new Set();
let failPostsMode = "429";
let postCalls = 0;
let ratelimitReplies = 0;
let repliesCalls = 0;
let failThread = null, failThreadN = 0;
const parents = () => msgs.filter(m => !m.thread_ts || m.thread_ts === m.ts || m.subtype === "thread_broadcast");
const inThread = p => msgs.filter(m => m.ts === p || m.thread_ts === p);
const newer = (list, oldest, inclusive) =>
	list.filter(m => parseFloat(m.ts) > parseFloat(oldest) || (inclusive && m.ts === oldest));
const server = http.createServer((req, res) => {
	const u = new URL(req.url, "http://x");
	const q = u.searchParams;
	let body = "";
	req.on("data", d => body += d);
	req.on("end", () => {
		const send = o => { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(o)); };
		const method = u.pathname.replace(/^\/api\//, "");
		if (method === "stub.state") return send({ ok: true, count: msgs.length, posted: posted, last_post: lastPost, posts: posts, replies_calls: repliesCalls });
		if (method === "stub.seedReply") {
			const parent = msgs.find(m => m.ts === (q.get("thread") || m2.ts));
			if (!parent) return send({ ok: false, error: "thread_not_found" });
			const r = { ts: ts(), user: "U0PERSON", text: q.get("text") || "second thread reply", thread_ts: parent.ts };
			msgs.push(r); parent.reply_count = (parent.reply_count || 0) + 1; parent.thread_ts = parent.ts;
			return send({ ok: true, ts: r.ts });
		}
		if (method === "stub.seedBroadcast") {
			const parent = msgs.find(m => m.ts === q.get("thread"));
			if (!parent) return send({ ok: false, error: "thread_not_found" });
			const b = { ts: ts(), user: q.get("user") || "U0PERSON", text: q.get("text") || "a reply also sent to the channel", thread_ts: parent.ts, subtype: "thread_broadcast" };
			msgs.push(b); parent.reply_count = (parent.reply_count || 0) + 1; parent.thread_ts = parent.ts;
			return send({ ok: true, ts: b.ts });
		}
		if (method === "stub.seedMessage") {
			const m = { ts: ts(), user: q.get("user") || "U0PERSON", text: q.get("text") || "a message" };
			msgs.push(m);
			return send({ ok: true, ts: m.ts });
		}
		if (method === "stub.ratelimit") { ratelimit = parseInt(q.get("n") || "1", 10); return send({ ok: true, n: ratelimit }); }
		if (method === "stub.alterNext") { alterNext = q.get("mode"); return send({ ok: true, mode: alterNext }); }
		if (method === "stub.failThread") { failThread = q.get("ts"); failThreadN = parseInt(q.get("n") || "1", 10); return send({ ok: true }); }
		if (method === "stub.ratelimitReplies") { ratelimitReplies = parseInt(q.get("n") || "1", 10); return send({ ok: true, n: ratelimitReplies }); }
		if (method === "stub.failPosts") { failPosts = new Set((q.get("calls") || "").split(",").filter(Boolean).map(Number)); failPostsMode = q.get("mode") || "429"; postCalls = 0; return send({ ok: true }); }
		if ((req.headers.authorization || "") !== TOKEN) return send({ ok: false, error: "invalid_auth" });
		if (method === "auth.test") return send({ ok: true, user_id: "U0STUB", team: "T0STUB", user: "stubbot" });
		if (method === "conversations.history") {
			if (ratelimit > 0) {
				ratelimit--;
				res.statusCode = 429; res.setHeader("Retry-After", "1");
				return send({ ok: false, error: "ratelimited" });
			}
			if (q.get("channel") !== CHAN) return send({ ok: false, error: "channel_not_found" });
			const list = newer(parents(), q.get("oldest") || "0", q.get("inclusive") === "true")
				.sort((a, b) => parseFloat(b.ts) - parseFloat(a.ts));
			const idx = parseInt(q.get("cursor") || "0", 10);
			const page = list.slice(idx, idx + 2);
			const more = idx + 2 < list.length;
			return send({ ok: true, messages: page, has_more: more,
				response_metadata: { next_cursor: more ? String(idx + 2) : "" } });
		}
		if (method === "conversations.replies") {
			repliesCalls++;
			if (ratelimitReplies > 0) {
				ratelimitReplies--;
				res.statusCode = 429; res.setHeader("Retry-After", "1");
				return send({ ok: false, error: "ratelimited" });
			}
			if (failThread && q.get("ts") === failThread && failThreadN > 0) { failThreadN--; return send({ ok: false, error: "internal_error" }); }
			const parent = msgs.find(m => m.ts === q.get("ts"));
			if (!parent) return send({ ok: false, error: "thread_not_found" });
			const list = newer(inThread(parent.ts).filter(m => m !== parent), q.get("oldest") || "0", q.get("inclusive") === "true")
				.sort((a, b) => parseFloat(a.ts) - parseFloat(b.ts));
			return send({ ok: true, messages: [parent, ...list], has_more: false });
		}
		if (method === "chat.postMessage") {
			postCalls++;
			if (failPosts.has(postCalls) && failPostsMode === "429") {
				res.statusCode = 429; res.setHeader("Retry-After", "1");
				return send({ ok: false, error: "ratelimited" });
			}
			if (failPosts.has(postCalls) && failPostsMode === "error") return send({ ok: false, error: "fatal_error" });
			const dropResponse = failPosts.has(postCalls) && failPostsMode === "drop";
			let p; try { p = JSON.parse(body); } catch (e) { return send({ ok: false, error: "invalid_json" }); }
			if (p.channel !== CHAN) return send({ ok: false, error: "channel_not_found" });
			let text = p.text;
			if (alterNext === "escape") text = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
			if (alterNext === "truncate") text = text.slice(0, Math.floor(text.length / 2));
			alterNext = null;
			const chunks = [];
			for (let i = 0; i < text.length; i += 4000) chunks.push(text.slice(i, i + 4000));
			if (!chunks.length) chunks.push("");
			let first = null;
			for (const c of chunks) {
				const m = { ts: ts(), user: "U0STUB", text: c };
				if (p.thread_ts) {
					m.thread_ts = p.thread_ts;
					const parent = msgs.find(x => x.ts === p.thread_ts);
					if (parent) { parent.reply_count = (parent.reply_count || 0) + 1; parent.thread_ts = parent.ts; }
				}
				msgs.push(m); posts.push(m);
				if (!first) first = m;
			}
			posted++; lastPost = first;
			if (dropResponse) { req.socket.destroy(); return; }
			return send({ ok: true, ts: first.ts, channel: CHAN });
		}
		send({ ok: false, error: "unknown_method" });
	});
});
server.listen(0, "127.0.0.1", () => {
	console.log("SEED m1=" + m1.ts + " m2=" + m2.ts + " m3=" + m3.ts + " r1=" + r1.ts);
	console.log("LISTENING " + server.address().port);
});
EOF

"${NODE_BIN}" ${D}/stub.js > ${D}/stub.out 2>&1 &
STUB_PID=$!
WAITED=0
while ! grep -q "^LISTENING" ${D}/stub.out 2>/dev/null; do
	[ ${WAITED} -ge 20 ] && fail "stub did not start: $(cat ${D}/stub.out 2>/dev/null)"
	sleep 0.5
	WAITED=$((WAITED + 1))
done
PORT=$(grep "^LISTENING" ${D}/stub.out | awk '{print $2}')
M1_TS=$(sed -n 's/^SEED m1=\([0-9.]*\).*/\1/p' ${D}/stub.out)
M2_TS=$(sed -n 's/.* m2=\([0-9.]*\).*/\1/p' ${D}/stub.out)
M3_TS=$(sed -n 's/.* m3=\([0-9.]*\).*/\1/p' ${D}/stub.out)
[ -n "${PORT}" ] && [ -n "${M3_TS}" ] || fail "could not parse stub port/seed"
echo "ok 2 - stub Slack API on 127.0.0.1:${PORT}"

export SLACK_API_BASE="http://127.0.0.1:${PORT}/api"
export SLACK_DIR=${D}/state
export SLACK_CHANNELS=C0TESTCHAN
export SLACK_BOT_TOKEN=xoxb-test-stub
# The conversations.replies budget is not what these checks measure: the watch runs every second here,
# so the default 30 calls a minute would defer thread polls the checks wait for. Check 44 sets its own.
export SLACK_REPLIES_BUDGET=1000

# From here on every curl call goes through a shim that logs its command line (check 42): the bot
# token must never be a word of one, since any local user can read a command line in ps
REAL_CURL=$(command -v curl)
mkdir -p ${D}/shim
cat > ${D}/shim/curl << EOF
#!/bin/bash
printf '%s\n' "\$*" >> ${D}/curl-argv.log
exec ${REAL_CURL} "\$@"
EOF
chmod +x ${D}/shim/curl
export PATH=${D}/shim:${PATH}

inbox_depth()
{
	C=$(grep -c . "${SLACK_DIR}/inbox.jsonl" 2>/dev/null)
	echo "${C:-0}"
}

stub_count()
{
	curl -s -H "Authorization: Bearer x" "${SLACK_API_BASE}/stub.state" | "${NODE_BIN}" -e '
let raw=""; process.stdin.on("data",d=>raw+=d);
process.stdin.on("end",()=>console.log(JSON.parse(raw).count));'
}

stub_posted()
{
	# number of chat.postMessage calls the stub has accepted
	curl -s -H "Authorization: Bearer x" "${SLACK_API_BASE}/stub.state" | "${NODE_BIN}" -e '
let raw=""; process.stdin.on("data",d=>raw+=d);
process.stdin.on("end",()=>console.log(JSON.parse(raw).posted));'
}

stub_last_post()
{
	# stub_last_post text|thread_ts|ts - the field of the last posted message
	curl -s -H "Authorization: Bearer x" "${SLACK_API_BASE}/stub.state" | "${NODE_BIN}" -e '
let raw=""; process.stdin.on("data",d=>raw+=d);
process.stdin.on("end",()=>{ const p=JSON.parse(raw).last_post; console.log(p ? (p[process.argv[1]] || "") : ""); });' "$1"
}

stub_post_thread()
{
	# stub_post_thread <exact text> - the thread_ts of the stub's post with that text ("none" when top-level)
	curl -s -H "Authorization: Bearer x" "${SLACK_API_BASE}/stub.state" | "${NODE_BIN}" -e '
let raw=""; process.stdin.on("data",d=>raw+=d);
process.stdin.on("end",()=>{ const p = JSON.parse(raw).posts.filter(x => x.text === process.argv[1]);
	console.log(p.length === 1 ? (p[0].thread_ts || "none") : "posts=" + p.length); });' "$1"
}

# The chat gate is OFF for checks 3-24: with it on, the Slack chat responder owns the inbox and the
# loop runs no watch of its own (checks 25-30 turn it on and prove exactly that). The explicit false
# is the opt-out a user has; the loop checks below therefore prove the loop's own Slack watch with chat off.
export SLACK_CHAT_ENABLED=false

# --- 2/3. loud failures: empty token, bad token ---
OUT=$(SLACK_BOT_TOKEN= "${AGENT_DIR}/slack-watch.sh" 2>&1) && fail "watch with empty token exited 0"
echo "${OUT}" | grep -q "SLACK_BOT_TOKEN" || fail "empty-token watch error does not name SLACK_BOT_TOKEN: ${OUT}"
OUT=$(SLACK_BOT_TOKEN= SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN hi 2>&1) && fail "post with empty token exited 0"
echo "${OUT}" | grep -q "SLACK_BOT_TOKEN" || fail "empty-token post error does not name SLACK_BOT_TOKEN: ${OUT}"
echo "ok 3 - empty token fails loud (watch + post)"

OUT=$(SLACK_BOT_TOKEN=xoxb-wrong "${AGENT_DIR}/slack-watch.sh" 2>&1) && fail "watch with bad token exited 0"
echo "${OUT}" | grep -q "invalid_auth" || fail "bad-token watch error does not surface invalid_auth: ${OUT}"
echo "ok 4 - bad token fails loud with the API error"

# --- 4. first watch: history (paginated) + existing thread reply ---
mkdir -p ${SLACK_DIR}
echo "1.000000" > ${SLACK_DIR}/cursor-C0TESTCHAN   # pre-set cursor so the seeded backlog is "new"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch1.out 2>&1 || fail "watch 1: $(cat ${D}/watch1.out)"
[ "$(inbox_depth)" = "4" ] || fail "watch 1 inbox depth $(inbox_depth) != 4 (3 messages + 1 thread reply)"
grep -q "hello agent" ${SLACK_DIR}/inbox.jsonl || fail "watch 1 inbox missing m1"
grep -q "thread reply one" ${SLACK_DIR}/inbox.jsonl || fail "watch 1 inbox missing the thread reply"
[ "$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)" = "${M3_TS}" ] || fail "cursor did not advance to m3 (${M3_TS}): $(cat ${SLACK_DIR}/cursor-C0TESTCHAN)"
grep -q "^${M2_TS} " ${SLACK_DIR}/threads-C0TESTCHAN || fail "thread registry missing parent m2"
grep -q "user_id=U0STUB" ${SLACK_DIR}/identity || fail "identity not recorded from auth.test"
head -1 ${SLACK_DIR}/inbox.jsonl | grep -q "\"ts\":\"${M1_TS}\"" || fail "inbox not chronological (first line is not m1)"
echo "ok 5 - watch ingests history (paginated) + thread reply; cursor, registry, identity correct"

# --- 5. idempotency ---
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch2.out 2>&1 || fail "watch 2: $(cat ${D}/watch2.out)"
[ "$(inbox_depth)" = "4" ] || fail "watch 2 duplicated messages: inbox depth $(inbox_depth) != 4"
[ "$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)" = "${M3_TS}" ] || fail "watch 2 moved the cursor with no new messages"
echo "ok 6 - second watch ingests nothing new (no duplicates)"

# --- 6. the thread-reply trap: new reply to an OLD parent ---
curl -s "${SLACK_API_BASE}/stub.seedReply?text=second+thread+reply" > /dev/null
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch3.out 2>&1 || fail "watch 3: $(cat ${D}/watch3.out)"
[ "$(inbox_depth)" = "5" ] || fail "watch 3 inbox depth $(inbox_depth) != 5 (new thread reply not collected)"
grep -q "second thread reply" ${SLACK_DIR}/inbox.jsonl || fail "watch 3 missing the new reply to the old parent"
echo "ok 7 - NEW reply to OLD thread parent collected (invisible to history alone)"

# --- 7. post gates ---
COUNT_BEFORE=$(stub_count)
OUT=$(SLACK_POST_ENABLED=false "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "must be refused" 2>&1) && fail "post with SLACK_POST_ENABLED=false exited 0"
echo "${OUT}" | grep -q "SLACK_POST_ENABLED" || fail "gate-off refusal does not name SLACK_POST_ENABLED: ${OUT}"
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0UNLISTED "must be refused" 2>&1) && fail "post to unlisted channel exited 0"
echo "${OUT}" | grep -q "SLACK_CHANNELS" || fail "unlisted-channel refusal does not name SLACK_CHANNELS: ${OUT}"
[ "$(stub_count)" = "${COUNT_BEFORE}" ] || fail "a refused post still reached the API"
echo "ok 8 - post refused with SLACK_POST_ENABLED=false / channel unlisted; nothing reached the API"

# --- 8. post + read-back verify ---
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "agent post smoke" 2>&1) || fail "post: ${OUT}"
echo "${OUT}" | grep -q "read-back verified" || fail "post did not read-back verify: ${OUT}"
echo "${OUT}" | grep -qE "ts=[0-9]+\.[0-9]+" || fail "post did not print the message ts: ${OUT}"
[ "$(stub_count)" = "$(( COUNT_BEFORE + 1 ))" ] || fail "posted message not in the API state"
echo "ok 9 - post + read-back verify passed, ts printed"

# --- own post arrives on the next watch (recognizable via identity) ---
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch4.out 2>&1 || fail "watch 4: $(cat ${D}/watch4.out)"
[ "$(inbox_depth)" = "6" ] || fail "watch 4 inbox depth $(inbox_depth) != 6 (own post not ingested)"
grep -q "agent post smoke" ${SLACK_DIR}/inbox.jsonl || fail "watch 4 missing the bot's own post"
echo "ok 10 - the bot's own post arrives in the inbox (identity file marks it as own)"

# --- 9. status: honest, token never printed ---
OUT=$("${AGENT_DIR}/slack-status.sh" 2>&1) || fail "status exited nonzero when configured: ${OUT}"
echo "${OUT}" | grep -q "token:      configured" || fail "status does not report the token as configured: ${OUT}"
echo "${OUT}" | grep -q "xoxb-test-stub" && fail "status printed the token value"
echo "${OUT}" | grep -q "6 unprocessed" || fail "status inbox depth wrong: ${OUT}"
SLACK_BOT_TOKEN= "${AGENT_DIR}/slack-status.sh" > /dev/null 2>&1 && fail "status exited 0 while unconfigured"
echo "ok 11 - status honest; token value never printed; exit reflects configuration"

# --- 10. loop fire integration (loop-once.sh shares the gated block with loop.sh) ---
cat > ${D}/fakeclaude << 'EOF'
#!/bin/bash
# fake headless claude - mimics the real option parser where it matters for the loop's call:
# --allowedTools (and the other list options) is VARIADIC: it consumes every following argument up
# to the next one that starts with "-", so a positional prompt placed after it is swallowed;
# --permission-mode (and the other single-value options) consumes exactly one argument; "--" ends
# the options; the prompt is the first remaining positional argument, else stdin; with neither the
# real binary fails exactly like this (Claude Code 2.1.287):
#   Error: Input must be provided either through stdin or as a prompt argument when using --print
# Records the prompt it received at ${FAKE_PROMPT_OUT} and, when FAKE_ARGV_OUT is set, its
# argument list one per line at ${FAKE_ARGV_OUT}; then succeeds.
# A prompt carrying the marker "SLACK CHAT" is the chat responder's: the fake then behaves like a
# model that follows the prompt's rules - it posts a canned reply through the REAL slack-post.sh
# (${FAKE_POST_BIN}), in the thread named by the prompt when there is one, so the reply is
# observable in the stub; and when the message text says "please add a goal" it first records the
# goal with the real goals-add.sh (${FAKE_GOALS_ADD_BIN}).
# With FAKE_LOOP_POST set, a loop fire's prompt (SLACK INBOX) is answered the same way: one canned reply
# per human inbox line, through the real slack-post.sh, placed by the rule the prompt states - the reply
# placement under test is the prompt's, and this fake applies it the way a model following it would. It
# follows the prompt's CARRIED note too: a reply the note lists as already landed is not posted again. A
# line saying it "gets a follow-up while the loop fires" has the follow-up arrive before its answer is
# posted (seeded here), the post is refused as stale, and this model stops, as the prompt says - unless
# the line comes back CARRIED (one saying "always" is refused every time, until a fire posts without the
# check); a line saying the fire "sleeps past the fire timeout" makes this model sleep, once, until it is
# killed; a line saying it "makes the fire fail N times" makes this model exit 2 before posting anything,
# on N fires that get it (a counter beside the prompt file), then answer it like any line; one saying it
# "posts then makes the fire fail N times" posts a distinct reply ("... (attempt k)") first each time.
if [ -n "${FAKE_ARGV_OUT}" ]; then
	printf '%s\n' "$@" > "${FAKE_ARGV_OUT}"
	printf '%s\n' "${IS_SANDBOX-unset}" > "${FAKE_ARGV_OUT}.sandbox"   # the fire's IS_SANDBOX, as the real claude would see it
fi
[ -n "${FAKE_ENV_OUT}" ] && echo "SLACK_POST_AFTER_TS=${SLACK_POST_AFTER_TS}" > "${FAKE_ENV_OUT}"
PROMPT=""
HAVE_PROMPT=false
while [ $# -gt 0 ]; do
	case "$1" in
	--)
		shift
		if [ $# -gt 0 ]; then PROMPT=$1; HAVE_PROMPT=true; fi
		break
		;;
	--allowedTools|--allowed-tools|--disallowedTools|--disallowed-tools|--tools|--add-dir)
		shift
		while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do shift; done
		;;
	--permission-mode|--output-format|--model|--max-turns|--system-prompt|--append-system-prompt)
		shift
		[ $# -gt 0 ] && shift
		;;
	-*)
		shift
		;;
	*)
		if [ "${HAVE_PROMPT}" = "false" ]; then PROMPT=$1; HAVE_PROMPT=true; fi
		shift
		;;
	esac
done
if [ "${HAVE_PROMPT}" = "false" ] && [ ! -t 0 ]; then
	PROMPT=$(cat)
	[ -n "${PROMPT}" ] && HAVE_PROMPT=true
fi
if [ "${HAVE_PROMPT}" = "false" ]; then
	echo "Error: Input must be provided either through stdin or as a prompt argument when using --print"
	exit 1
fi
printf '%s' "${PROMPT}" > "${FAKE_PROMPT_OUT}"
if printf '%s' "${PROMPT}" | grep -q "SLACK CHAT"; then
	CH=$(printf '%s' "${PROMPT}" | sed -n 's/^MESSAGE: ts=[0-9.]* channel=\([A-Z0-9]*\) .*/\1/p' | head -1)
	TS=$(printf '%s' "${PROMPT}" | sed -n 's/^MESSAGE: ts=\([0-9.]*\) .*/\1/p' | head -1)
	# where the answer goes, as the prompt's MESSAGE line names it (reply_thread=<ts>, or none): the message's own
	# thread, or the thread under a top-level message - this fake follows it, as a model following RULE 1 would; a
	# prompt without reply_thread (a responder without the thread rule) named only where the message is, and the fake
	# answered there - kept, so the red run of this test against that responder fails at the placement checks
	THREAD=$(printf '%s' "${PROMPT}" | sed -n 's/^MESSAGE: .* reply_thread=\([0-9.]*\)$/\1/p' | head -1)
	printf '%s' "${PROMPT}" | grep -q '^MESSAGE: .* reply_thread=' \
		|| THREAD=$(printf '%s' "${PROMPT}" | sed -n 's/^MESSAGE: .* thread_ts=\([0-9.]*\)$/\1/p' | head -1)
	TEXT=$(printf '%s' "${PROMPT}" | sed -n 's/^text: //p' | head -1)
	if printf '%s' "${TEXT}" | grep -qi "please add a goal"; then
		GOAL=$(printf '%s' "${TEXT}" | sed -e 's/.*[Pp]lease add a goal:* *//')
		"${FAKE_GOALS_ADD_BIN}" "${GOAL}" "${CH} ${TS}" > /dev/null || { echo "fake claude: goals-add.sh failed"; exit 1; }
		REPLY="Added to the goals file: ${GOAL}. The autonomy loop picks it up on its next cycle."
	else
		REPLY="fake model reply to: ${TEXT}"
	fi
	# the newer messages the prompt lists, if any, are taken into account; a message saying it "gets a
	# follow-up while answered" has the follow-up arrive before the answer is posted (seeded here), the
	# post is refused as stale, and this model stops, as a model reading the refusal would
	NEWER_N=$(printf '%s' "${PROMPT}" | sed -n '/^NEWER MESSAGES/,/^$/p' | grep -c '^ts=')
	[ "${NEWER_N}" -gt 0 ] && REPLY="${REPLY} (with ${NEWER_N} newer message(s))"
	if printf '%s' "${TEXT}" | grep -q "gets a follow-up while answered" && [ "${NEWER_N}" -eq 0 ]; then
		# the follow-up arrives where the conversation is: in the thread the answer goes to, else top-level
		if [ -n "${THREAD}" ]; then
			curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${THREAD}&text=the+follow-up+that+arrives+while+the+agent+answers" > /dev/null
		else
			curl -s "${SLACK_API_BASE}/stub.seedMessage?text=the+follow-up+that+arrives+while+the+agent+answers" > /dev/null
		fi
		if "${FAKE_POST_BIN}" "${CH}" "${REPLY}" ${THREAD:+"${THREAD}"} > "${FAKE_PROMPT_OUT}.stale-post" 2>&1; then
			echo "fake claude: the stale answer was posted"
			exit 1
		fi
		echo "the post was refused: a newer message arrived; not answering from older context"
		exit 0
	fi
	# an obedient model whose post loses its response: it posts the answer, then prints it, as a model
	# does whatever slack-post.sh exited with
	if printf '%s' "${TEXT}" | grep -q "response is lost"; then
		"${FAKE_POST_BIN}" "${CH}" "${REPLY}" ${THREAD:+"${THREAD}"} > "${FAKE_PROMPT_OUT}.lost-post" 2>&1
		echo "${REPLY}"
		exit 0
	fi
	if [ -n "${THREAD}" ]; then
		"${FAKE_POST_BIN}" "${CH}" "${REPLY}" "${THREAD}" > /dev/null || { echo "fake claude: slack-post.sh failed"; exit 1; }
	else
		"${FAKE_POST_BIN}" "${CH}" "${REPLY}" > /dev/null || { echo "fake claude: slack-post.sh failed"; exit 1; }
	fi
	echo "posted the reply"
	exit 0
fi
if [ -n "${FAKE_LOOP_POST}" ] && printf '%s' "${PROMPT}" | grep -q "^SLACK INBOX:"; then
	if printf '%s' "${PROMPT}" | grep -qF "always in-thread: pass the message's thread_ts when it has one, else its ts"; then
		RULE=always-in-thread
	elif printf '%s' "${PROMPT}" | grep -qF "adding the message's thread_ts as a third argument only when the message has one"; then
		RULE=where-written
	else
		echo "fake claude: the SLACK INBOX prompt states no reply-placement rule this fake knows"
		exit 1
	fi
	BOT=$(sed -n 's/^user_id=\([^ ]*\).*/\1/p' "${SLACK_DIR}/identity")
	LANDED_TEXTS=$(printf '%s' "${PROMPT}" | sed -n 's/^  ts=[0-9.]* thread_ts=[^ ]* text: //p')
	printf '%s' "${PROMPT}" | sed -n '/^SLACK INBOX:/,$p' | grep -E '^(CARRIED )?\{' | while IFS= read -r LINE; do
		L_CARRIED=false
		case "${LINE}" in "CARRIED "*) L_CARRIED=true; LINE=${LINE#CARRIED }; ;; esac
		F=$(printf '%s' "${LINE}" | "${NODE_BIN:-node}" -e '
let raw = ""; process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => { const m = JSON.parse(raw);
	process.stdout.write([m.ts || "", m.channel || "", m.user || "", m.thread_ts || "", m.text || ""].join("\x1f")); });')
		IFS=$'\x1f' read -r -d '' L_TS L_CH L_USER L_THREAD L_TEXT < <(printf '%s' "${F}") || true
		[ "${L_USER}" = "${BOT}" ] && continue
		L_REPLY="fake loop reply to: ${L_TEXT}"
		# where this reply goes, by the rule the prompt states: in-thread always (the message's thread, else a thread
		# under the message), or where the person wrote
		if [ "${RULE}" = "always-in-thread" ]; then L_REPLY_THREAD=${L_THREAD:-${L_TS}}; else L_REPLY_THREAD=${L_THREAD}; fi
		# already said by the previous fire, per the carry note: not again
		printf '%s\n' "${LANDED_TEXTS}" | grep -qxF -- "${L_REPLY}" && continue
		FAILS_WANTED=$(printf '%s' "${L_TEXT}" | sed -n 's/.*makes the fire fail \([0-9]*\) times.*/\1/p')
		if [ -n "${FAILS_WANTED}" ]; then
			FAIL_COUNT_FILE="$(dirname "${FAKE_PROMPT_OUT}")/fake-fails-${L_TS}"
			FAILED_SO_FAR=$(cat "${FAIL_COUNT_FILE}" 2>/dev/null || echo 0)
			if [ "${FAILED_SO_FAR}" -lt "${FAILS_WANTED}" ]; then
				echo $(( FAILED_SO_FAR + 1 )) > "${FAIL_COUNT_FILE}"
				if printf '%s' "${L_TEXT}" | grep -q "posts then makes the fire fail"; then
					"${FAKE_POST_BIN}" "${L_CH}" "${L_REPLY} (attempt $(( FAILED_SO_FAR + 1 )))" ${L_REPLY_THREAD:+"${L_REPLY_THREAD}"} > /dev/null || { echo "fake claude: slack-post.sh failed"; exit 1; }
				fi
				echo "fake claude: failing this fire on purpose ($(( FAILED_SO_FAR + 1 )) of ${FAILS_WANTED})"
				exit 2
			fi
		fi
		if printf '%s' "${L_TEXT}" | grep -q "gets a follow-up while the loop fires" && { [ "${L_CARRIED}" = "false" ] || printf '%s' "${L_TEXT}" | grep -q "always"; }; then
			# the follow-up arrives where the conversation is: in the thread the reply goes to, else top-level
			if [ -n "${L_REPLY_THREAD}" ]; then
				curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${L_REPLY_THREAD}&text=a+follow-up+that+arrives+while+the+loop+fires+$(date +%s%N)" > /dev/null
			else
				curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+follow-up+that+arrives+while+the+loop+fires+$(date +%s%N)" > /dev/null
			fi
			if "${FAKE_POST_BIN}" "${L_CH}" "${L_REPLY}" ${L_REPLY_THREAD:+"${L_REPLY_THREAD}"} > /dev/null 2>&1; then
				[ -z "${SLACK_POST_AFTER_TS}" ] && continue   # the bound: this fire posts without the check
				echo "fake claude: the stale answer was posted"
				exit 1
			fi
			echo "the post was refused: a newer message arrived; not answering from older context"
			exit 0
		fi
		if printf '%s' "${L_TEXT}" | grep -q "sleeps past the fire timeout" && [ "${L_CARRIED}" = "false" ]; then
			sleep 120
		fi
		if [ -n "${L_REPLY_THREAD}" ]; then
			"${FAKE_POST_BIN}" "${L_CH}" "${L_REPLY}" "${L_REPLY_THREAD}" > /dev/null || { echo "fake claude: slack-post.sh failed"; exit 1; }
		else
			"${FAKE_POST_BIN}" "${L_CH}" "${L_REPLY}" > /dev/null || { echo "fake claude: slack-post.sh failed"; exit 1; }
		fi
	done || exit $?
	echo "fake-fire-ok (answered the inbox, rule ${RULE})"
	exit 0
fi
echo "fake-fire-ok"
EOF
chmod +x ${D}/fakeclaude
export FAKE_POST_BIN="${AGENT_DIR}/slack-post.sh"
export FAKE_GOALS_ADD_BIN="${AGENT_DIR}/goals-add.sh"

mkdir -p ${D}/loop
echo "test goal" > ${D}/loop/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt1.txt
SLACK_WATCH_ENABLED=true SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop AUTONOMY_LOOP_WORKDIR=${D}/loop AUTONOMY_LOOP_GOALS=${D}/loop/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once1.out 2>&1 || fail "loop-once (slack on): $(cat ${D}/once1.out)"
grep -q "SLACK INBOX" ${D}/prompt1.txt || fail "fire prompt has no SLACK INBOX section"
grep -q "agent post smoke" ${D}/prompt1.txt || fail "fire prompt missing an inbox line"
[ "$(inbox_depth)" = "0" ] || fail "inbox not drained after the fire: depth $(inbox_depth)"
C=$(grep -c . ${SLACK_DIR}/processed.jsonl 2>/dev/null); [ "${C:-0}" = "6" ] || fail "processed.jsonl has ${C:-0} lines != 6"
grep -q "SLACK processed=6" ${D}/loop/loop.log || fail "loop.log missing the SLACK processed line"
echo "ok 12 - loop fire included the inbox in the prompt and marked it processed"

mkdir -p ${D}/loop2
echo "test goal" > ${D}/loop2/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt2.txt
SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop2 AUTONOMY_LOOP_WORKDIR=${D}/loop2 AUTONOMY_LOOP_GOALS=${D}/loop2/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once2.out 2>&1 || fail "loop-once (slack off): $(cat ${D}/once2.out)"
grep -q "SLACK INBOX" ${D}/prompt2.txt && fail "gate off but the fire prompt contains a SLACK INBOX section"
grep -q "SLACK" ${D}/loop2/loop.log && fail "gate off but loop.log contains SLACK lines"
echo "ok 13 - gate off: fire prompt and loop state exactly as before"

# --- 11. no user goals file: the shipped default goals fire only on Slack messages ---
# (loop-once.sh shares the cycle logic with loop.sh; check 16 below exercises loop.sh itself)
DEFAULT_GOALS="${AGENT_DIR}/goals-default.md"
[ -f "${DEFAULT_GOALS}" ] || fail "shipped default goals file ${DEFAULT_GOALS} is missing"
export AUTONOMY_LOOP_DEFAULT_GOALS="${DEFAULT_GOALS}"
mkdir -p ${D}/loop3                                                   # deliberately no GOALS.md
[ "$(inbox_depth)" = "0" ] || fail "precondition: inbox not empty before check 14 (depth $(inbox_depth))"
curl -s "${SLACK_API_BASE}/stub.seedReply?text=please+add+a+goal" > /dev/null   # a new human message
PROCESSED_BEFORE=$(grep -c . ${SLACK_DIR}/processed.jsonl 2>/dev/null)
export FAKE_PROMPT_OUT=${D}/prompt3.txt
SLACK_WATCH_ENABLED=true SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop3 AUTONOMY_LOOP_WORKDIR=${D}/loop3 AUTONOMY_LOOP_GOALS=${D}/loop3/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once3.out 2>&1 || fail "loop-once (no goals file, slack on, inbox non-empty) exited nonzero: $(cat ${D}/once3.out)"
[ -f ${D}/prompt3.txt ] || fail "no fire happened with a Slack message waiting (prompt file missing)"
grep -qF "read the goals file ${DEFAULT_GOALS}" ${D}/prompt3.txt || fail "fire prompt does not read the default goals file"
grep -qF "No user goals file" ${D}/prompt3.txt || fail "fire prompt lacks the default-mode sentence"
grep -qF "${D}/loop3/GOALS.md" ${D}/prompt3.txt || fail "fire prompt does not name the absent user goals path"
grep -qF "please add a goal" ${D}/prompt3.txt || fail "fire prompt missing the new inbox line"
grep -qF "do not create ${D}/loop3/STOP" ${D}/prompt3.txt || fail "default-mode prompt does not forbid the stop flag"
grep -qF "If every goal is already complete" ${D}/prompt3.txt && fail "default-mode prompt still invites the stop flag"
grep -qF "If every goal is already complete, create the file ${D}/loop/STOP" ${D}/prompt1.txt || fail "user-mode prompt (check 12) lost its step 4"
grep -qF "FIRE 1 BEGIN (once) goals=${DEFAULT_GOALS} (default: no user goals file at ${D}/loop3/GOALS.md)" ${D}/loop3/loop.log \
	|| fail "loop.log BEGIN line does not mark the default: $(grep BEGIN ${D}/loop3/loop.log)"
[ "$(inbox_depth)" = "0" ] || fail "inbox not drained after the default fire: depth $(inbox_depth)"
C=$(grep -c . ${SLACK_DIR}/processed.jsonl 2>/dev/null); [ "${C:-0}" = "$(( PROCESSED_BEFORE + 1 ))" ] || fail "processed.jsonl has ${C:-0} lines != $(( PROCESSED_BEFORE + 1 ))"
[ ! -f ${D}/loop3/GOALS.md ] || fail "a user goals file appeared during the test (fakeclaude writes none)"
echo "ok 14 - no goals file + Slack message waiting: fired on the shipped default goals, inbox drained"

# --- 12. no user goals file + empty inbox: nothing to fire against, but the watch DID run ---
# (this fails if the watch is coupled to the goals file again)
WATCHES_BEFORE=$(grep -c "^Watch complete:" ${D}/loop3/slack-watch.log)
FIRES_BEFORE=$(grep -c " BEGIN " ${D}/loop3/loop.log)
rm -f "${D:?}/prompt3.txt"
OUT=$(SLACK_WATCH_ENABLED=true SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop3 AUTONOMY_LOOP_WORKDIR=${D}/loop3 AUTONOMY_LOOP_GOALS=${D}/loop3/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" 2>&1) && fail "loop-once (no goals file, inbox empty) exited 0: ${OUT}"
echo "${OUT}" | grep -q "nothing to fire against" || fail "refusal does not say 'nothing to fire against': ${OUT}"
echo "${OUT}" | grep -q "Slack inbox is empty" || fail "refusal does not name the empty inbox: ${OUT}"
[ "$(grep -c " BEGIN " ${D}/loop3/loop.log)" = "${FIRES_BEFORE}" ] || fail "a FIRE line was logged with nothing to fire against"
[ ! -f ${D}/prompt3.txt ] || fail "claude was called with nothing to fire against"
WATCHES_AFTER=$(grep -c "^Watch complete:" ${D}/loop3/slack-watch.log)
[ "${WATCHES_AFTER}" = "$(( WATCHES_BEFORE + 1 ))" ] || fail "expected exactly one more completed watch with the goals file absent (${WATCHES_BEFORE} -> ${WATCHES_AFTER}) - the watch is coupled to the goals file again, or ran twice"
echo "ok 15 - no goals file + empty inbox: nothing to fire against, no claude call, but the watch ran"

# --- 13. loop.sh itself: idle for free, fire on a message, halt on STOP ---
wait_for_line()
{
	# wait_for_line <seconds> <fixed string> <file> - poll every 0.5s
	N=0
	while ! grep -qF -- "$2" "$3" 2>/dev/null; do
		[ ${N} -ge $(( $1 * 2 )) ] && return 1
		sleep 0.5
		N=$((N + 1))
	done
	return 0
}

loop_fail()
{
	kill "${LOOP_PID}" 2>/dev/null
	fail "$1"
}

mkdir -p ${D}/loop4                                                   # deliberately no GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt4.txt
SLACK_WATCH_ENABLED=true SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop4 AUTONOMY_LOOP_WORKDIR=${D}/loop4 AUTONOMY_LOOP_GOALS=${D}/loop4/GOALS.md \
	AUTONOMY_LOOP_INTERVAL=2 \
	"${AGENT_DIR}/loop.sh" > ${D}/loop4.out 2>&1 &
LOOP_PID=$!
wait_for_line 15 "LOOP IDLE" ${D}/loop4/loop.log || loop_fail "loop.sh did not log LOOP IDLE within 15s: $(cat ${D}/loop4/loop.log ${D}/loop4.out 2>/dev/null)"
grep -q "FIRE 1 BEGIN" ${D}/loop4/loop.log && loop_fail "loop.sh fired with no goals file and an empty inbox"
grep -q "Slack watch ran, inbox empty" ${D}/loop4/loop.log || loop_fail "idle line does not say the watch ran and the inbox is empty: $(grep 'LOOP IDLE' ${D}/loop4/loop.log | head -1)"
grep -q "^IDLE reason=no-goals-file" ${D}/loop4/loop.state || loop_fail "loop.state is not 'IDLE reason=no-goals-file': $(cat ${D}/loop4/loop.state)"
[ ! -f ${D}/prompt4.txt ] || loop_fail "claude was called while the loop was idle"
[ -s ${D}/loop4/slack-watch.log ] || loop_fail "the idle loop did not run the Slack watch (slack-watch.log empty)"
curl -s "${SLACK_API_BASE}/stub.seedReply?text=loop+please+wake+up" > /dev/null
wait_for_line 15 "FIRE 1 BEGIN goals=${DEFAULT_GOALS}" ${D}/loop4/loop.log || loop_fail "loop.sh did not fire on the default goals within 15s of a Slack message: $(cat ${D}/loop4/loop.log)"
wait_for_line 15 "FIRE 1 END rc=0" ${D}/loop4/loop.log || loop_fail "fire 1 did not end: $(cat ${D}/loop4/loop.log)"
grep -qF "(default: no user goals file at ${D}/loop4/GOALS.md)" ${D}/loop4/loop.log || loop_fail "BEGIN line lacks the default marker: $(grep BEGIN ${D}/loop4/loop.log)"
grep -qF "loop please wake up" ${D}/prompt4.txt || loop_fail "fire prompt missing the message that woke the loop"
grep -qF "read the goals file ${DEFAULT_GOALS}" ${D}/prompt4.txt || loop_fail "fire prompt does not read the default goals file"
wait_for_line 10 "FIRE 1 SLACK processed=1" ${D}/loop4/loop.log || loop_fail "loop.log missing the SLACK processed line for fire 1: $(grep 'FIRE 1' ${D}/loop4/loop.log)"
touch ${D}/loop4/STOP
if ! wait_for_line 20 "STOPPED reason=stop-flag" ${D}/loop4/loop.state; then
	kill "${LOOP_PID}" 2>/dev/null
	fail "loop.sh did not stop on the STOP flag within 20s (killed pid ${LOOP_PID} as a fallback): $(cat ${D}/loop4/loop.state)"
fi
wait "${LOOP_PID}" 2>/dev/null
WATCHES=$(grep -c "^Watch complete:" ${D}/loop4/slack-watch.log)
CYCLES=$(( $(grep -c " LOOP IDLE " ${D}/loop4/loop.log) + $(grep -c " BEGIN " ${D}/loop4/loop.log) ))
[ "${WATCHES}" = "${CYCLES}" ] || fail "expected exactly one watch per cycle: ${WATCHES} completed watches for ${CYCLES} cycles"
grep -qF "do not create ${D}/loop4/STOP" ${D}/prompt4.txt || fail "default-mode prompt (loop.sh) does not forbid the stop flag"
echo "ok 16 - loop.sh: idle with no claude call, one watch per cycle, fired on the Slack message against the default goals, halted on STOP"

# --- 14. gate off + no goals file: today's behavior exactly, no Slack code runs ---
mkdir -p ${D}/loop5                                                   # deliberately no GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt5.txt
OUT=$(SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop5 AUTONOMY_LOOP_WORKDIR=${D}/loop5 AUTONOMY_LOOP_GOALS=${D}/loop5/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" 2>&1) && fail "loop-once (gate off, no goals file) exited 0: ${OUT}"
echo "${OUT}" | grep -q "nothing to fire against" || fail "gate-off refusal does not say 'nothing to fire against': ${OUT}"
echo "${OUT}" | grep -q "Slack watch is off" || fail "gate-off refusal does not say the watch is off: ${OUT}"
[ ! -f ${D}/prompt5.txt ] || fail "gate off, no goals file, but loop-once.sh called claude"
grep -q "SLACK" ${D}/loop5/loop.log 2>/dev/null && fail "gate off but loop.log contains SLACK lines"
[ ! -f ${D}/loop5/slack-watch.log ] || fail "gate off but loop-once.sh wrote slack-watch.log"
SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop5 AUTONOMY_LOOP_WORKDIR=${D}/loop5 AUTONOMY_LOOP_GOALS=${D}/loop5/GOALS.md \
	AUTONOMY_LOOP_INTERVAL=2 \
	"${AGENT_DIR}/loop.sh" > ${D}/loop5.out 2>&1 &
LOOP_PID=$!
wait_for_line 15 "LOOP IDLE" ${D}/loop5/loop.log || loop_fail "gate off: loop.sh did not log LOOP IDLE within 15s: $(cat ${D}/loop5/loop.log ${D}/loop5.out 2>/dev/null)"
grep "LOOP IDLE" ${D}/loop5/loop.log | head -1 | grep -qE " LOOP IDLE goals file ${D}/loop5/GOALS.md not found$" \
	|| loop_fail "gate off: the IDLE line is not today's exact text: $(grep 'LOOP IDLE' ${D}/loop5/loop.log | head -1)"
grep -q "^IDLE reason=no-goals-file" ${D}/loop5/loop.state || loop_fail "gate off: loop.state is not 'IDLE reason=no-goals-file': $(cat ${D}/loop5/loop.state)"
touch ${D}/loop5/STOP
if ! wait_for_line 20 "STOPPED reason=stop-flag" ${D}/loop5/loop.state; then
	kill "${LOOP_PID}" 2>/dev/null
	fail "gate off: loop.sh did not stop on the STOP flag within 20s (killed pid ${LOOP_PID} as a fallback): $(cat ${D}/loop5/loop.state)"
fi
wait "${LOOP_PID}" 2>/dev/null
grep -q "SLACK" ${D}/loop5/loop.log && fail "gate off but loop.sh wrote SLACK lines to loop.log"
[ ! -f ${D}/loop5/slack-watch.log ] || fail "gate off but loop.sh wrote slack-watch.log"
[ ! -f ${D}/prompt5.txt ] || fail "gate off, no goals file, but loop.sh called claude"
echo "ok 17 - gate off + no goals file: refusal still says nothing to fire against, IDLE line exactly as before, no SLACK lines, no claude call"

# --- 15. the fire's claude call: allow rule first, no positional prompt, prompt on stdin ---
# The fake claude parses like the real binary (variadic --allowedTools), so these checks fail if
# the prompt becomes a positional argument again or the allow rule leaves the default.
mkdir -p ${D}/loop6
echo "test goal" > ${D}/loop6/GOALS.md
curl -s "${SLACK_API_BASE}/stub.seedReply?text=argv+check+message" > /dev/null
export FAKE_PROMPT_OUT=${D}/prompt6.txt
export FAKE_ARGV_OUT=${D}/argv6.txt
env -u AUTONOMY_LOOP_CLAUDE_OPTS SLACK_WATCH_ENABLED=true SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop6 AUTONOMY_LOOP_WORKDIR=${D}/loop6 AUTONOMY_LOOP_GOALS=${D}/loop6/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once6.out 2>&1 < /dev/null || fail "loop-once (default claude opts) exited nonzero: $(cat ${D}/once6.out)"
printf '%s\n' "-p" "--allowedTools" "Bash(/agent/slack-post.sh:*)" "Bash(/agent/slack-upload.sh:*)" "Bash(/agent/recall.sh:*)" "Bash(/agent/bus-answer.sh:*)" "--permission-mode" "acceptEdits" > ${D}/argv6.expected
cmp -s ${D}/argv6.expected ${D}/argv6.txt \
	|| fail "default fire argv is not exactly -p and the safe value with no positional argument: $(tr '\n' ' ' < ${D}/argv6.txt)"
grep -q "SLACK INBOX" ${D}/prompt6.txt || fail "default fire: the prompt on stdin has no SLACK INBOX section"
grep -qF "argv check message" ${D}/prompt6.txt || fail "default fire: the prompt on stdin lacks the inbox line"
grep -qF "You are one fire of the do-agent-aws autonomy loop" ${D}/prompt6.txt || fail "default fire: the prompt on stdin is not the fire prompt"
grep -q "Input must be provided" ${D}/once6.out && fail "default fire: claude reported a missing prompt"
[ "$(cat ${D}/argv6.txt.sandbox 2>/dev/null)" == "1" ] && fail "default fire: claude got IS_SANDBOX=1, though the safe value skips no permission check"
echo "ok 18 - default fire: claude gets exactly -p and the safe value, no IS_SANDBOX, no positional argument, the full prompt on stdin"

mkdir -p ${D}/loop7
echo "test goal" > ${D}/loop7/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt7.txt
export FAKE_ARGV_OUT=${D}/argv7.txt
AUTONOMY_LOOP_CLAUDE_OPTS="--permission-mode acceptEdits" SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop7 AUTONOMY_LOOP_WORKDIR=${D}/loop7 AUTONOMY_LOOP_GOALS=${D}/loop7/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once7.out 2>&1 < /dev/null || fail "loop-once (override without the rule) exited nonzero: $(cat ${D}/once7.out)"
printf '%s\n' "-p" "--permission-mode" "acceptEdits" > ${D}/argv7.expected
cmp -s ${D}/argv7.expected ${D}/argv7.txt || fail "override argv is not passed verbatim: $(tr '\n' ' ' < ${D}/argv7.txt)"
grep -qx -- "--allowedTools" ${D}/argv7.txt && fail "override without the rule still carries --allowedTools"
[ "$(cat ${D}/argv7.txt.sandbox 2>/dev/null)" == "unset" ] || fail "override under acceptEdits: claude got IS_SANDBOX (only a fire that skips permissions gets it): $(cat ${D}/argv7.txt.sandbox 2>/dev/null)"
grep -qF "You are one fire of the do-agent-aws autonomy loop" ${D}/prompt7.txt || fail "override fire: the prompt did not arrive on stdin"
echo "ok 19 - AUTONOMY_LOOP_CLAUDE_OPTS override is passed verbatim (no --allowedTools when it names none); the prompt still arrives on stdin"

# The old-order override (rule AFTER --permission-mode) used to swallow a positional prompt into
# the variadic --allowedTools and fail the fire with "Input must be provided ..." - with the prompt
# on stdin the same override completes and the rule reaches claude.
mkdir -p ${D}/loop8
echo "test goal" > ${D}/loop8/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt8.txt
export FAKE_ARGV_OUT=${D}/argv8.txt
AUTONOMY_LOOP_CLAUDE_OPTS="--permission-mode acceptEdits --allowedTools Bash(/agent/slack-post.sh:*)" SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop8 AUTONOMY_LOOP_WORKDIR=${D}/loop8 AUTONOMY_LOOP_GOALS=${D}/loop8/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once8.out 2>&1 < /dev/null || fail "loop-once (old-order override) exited nonzero - the prompt was swallowed by --allowedTools: $(cat ${D}/once8.out)"
grep -q "Input must be provided" ${D}/once8.out && fail "old-order override: claude reported a missing prompt"
printf '%s\n' "-p" "--permission-mode" "acceptEdits" "--allowedTools" "Bash(/agent/slack-post.sh:*)" > ${D}/argv8.expected
cmp -s ${D}/argv8.expected ${D}/argv8.txt || fail "old-order override argv is not passed verbatim: $(tr '\n' ' ' < ${D}/argv8.txt)"
grep -qF "You are one fire of the do-agent-aws autonomy loop" ${D}/prompt8.txt || fail "old-order override: the prompt did not arrive on stdin"
grep -q "FIRE 1 END rc=0" ${D}/loop8/loop.log || fail "old-order override: fire did not end rc=0: $(grep ' END ' ${D}/loop8/loop.log)"
echo "ok 20 - the old-order override (rule after --permission-mode) completes: the prompt is on stdin, nothing is swallowed"

# --- 16. the gates: a bot token and a channel list are enough ---
GATES="${AGENT_DIR}/slack-gates.sh"
UNSET_GATES="env -u AUTONOMY_LOOP -u SLACK_WATCH_ENABLED -u SLACK_POST_ENABLED"
G=$(${UNSET_GATES} "${GATES}" 2>&1) || fail "slack-gates.sh exited nonzero with token and channels set: ${G}"
[ "$(echo "${G}" | grep -c "(effective: on - token and channels set)")" = "3" ] || fail "gates unset + token and channels: not all three effective on: ${G}"
echo "${G}" | grep -q "^loop autostart: AUTONOMY_LOOP=unset (effective: on" || fail "loop autostart line missing or off: ${G}"
echo "${G}" | grep -q "^watch gate: SLACK_WATCH_ENABLED=unset (effective: on" || fail "watch gate line missing or off: ${G}"
echo "${G}" | grep -q "^post gate: SLACK_POST_ENABLED=unset (effective: on" || fail "post gate line missing or off: ${G}"
for GATE in loop watch post; do
	[ "$(${UNSET_GATES} "${GATES}" ${GATE})" = "on" ] || fail "slack-gates.sh ${GATE} did not answer on with token and channels set"
	${UNSET_GATES} "${GATES}" ${GATE} > /dev/null || fail "slack-gates.sh ${GATE} exited nonzero while on"
done
# a fire with the gate variables unset: the watch runs and the inbox reaches the prompt
mkdir -p ${D}/loop9
echo "test goal" > ${D}/loop9/GOALS.md
curl -s "${SLACK_API_BASE}/stub.seedReply?text=auto+gate+message" > /dev/null
export FAKE_PROMPT_OUT=${D}/prompt9.txt
export FAKE_ARGV_OUT=${D}/argv9.txt
${UNSET_GATES} SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop9 AUTONOMY_LOOP_WORKDIR=${D}/loop9 AUTONOMY_LOOP_GOALS=${D}/loop9/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once9.out 2>&1 < /dev/null || fail "loop-once (gates unset, token and channels set) exited nonzero: $(cat ${D}/once9.out)"
grep -q "SLACK INBOX" ${D}/prompt9.txt || fail "gates unset: the fire prompt has no SLACK INBOX section (the watch gate did not come on)"
grep -qF "auto gate message" ${D}/prompt9.txt || fail "gates unset: the fire prompt lacks the new inbox line"
grep -qF "currently on: token and channels set" ${D}/prompt9.txt || fail "gates unset: the fire prompt does not state that posting is on: $(grep -o 'allowed when posting is enabled[^;]*' ${D}/prompt9.txt)"
grep -qF "/agent/slack-status.sh shows the effective gates" ${D}/prompt9.txt || fail "the fire prompt does not point at slack-status.sh for the gates"
grep -q "SLACK processed=" ${D}/loop9/loop.log || fail "gates unset: loop.log has no SLACK processed line"
# posting with the gate variable unset: on, with read-back
COUNT_BEFORE=$(stub_count)
OUT=$(env -u SLACK_POST_ENABLED "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "auto gate post" 2>&1) || fail "post with SLACK_POST_ENABLED unset (token and channels set) refused: ${OUT}"
echo "${OUT}" | grep -q "read-back verified" || fail "auto-gate post did not read-back verify: ${OUT}"
[ "$(stub_count)" = "$(( COUNT_BEFORE + 1 ))" ] || fail "auto-gate post not in the API state"
OUT=$(${UNSET_GATES} "${AGENT_DIR}/slack-status.sh" 2>&1) || fail "status exited nonzero with the gates unset: ${OUT}"
echo "${OUT}" | grep -q "post gate: SLACK_POST_ENABLED=unset (effective: on - token and channels set)" || fail "status does not show the effective post gate: ${OUT}"
echo "${OUT}" | grep -q "loop autostart: AUTONOMY_LOOP=unset (effective: on - token and channels set)" || fail "status does not show the effective loop autostart: ${OUT}"
echo "ok 21 - gates unset + token and channels: all three on; a fire got the inbox; slack-post.sh posted with read-back; status shows the effective gates"

# explicit SLACK_POST_ENABLED=false: posting refused, the watch still runs
COUNT_BEFORE=$(stub_count)
OUT=$(env -u SLACK_WATCH_ENABLED SLACK_POST_ENABLED=false "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "must be refused" 2>&1) && fail "post with SLACK_POST_ENABLED=false exited 0"
echo "${OUT}" | grep -q "post gate is off (SLACK_POST_ENABLED=false)" || fail "explicit-false refusal does not name the gate: ${OUT}"
[ "$(stub_count)" = "${COUNT_BEFORE}" ] || fail "a post refused by SLACK_POST_ENABLED=false still reached the API"
G=$(env -u AUTONOMY_LOOP -u SLACK_WATCH_ENABLED SLACK_POST_ENABLED=false "${GATES}" 2>&1)
echo "${G}" | grep -q "^watch gate: SLACK_WATCH_ENABLED=unset (effective: on - token and channels set)" || fail "SLACK_POST_ENABLED=false turned the watch off: ${G}"
echo "${G}" | grep -q "^post gate: SLACK_POST_ENABLED=false (effective: off - SLACK_POST_ENABLED=false)" || fail "post gate not off with SLACK_POST_ENABLED=false: ${G}"
WATCHES_BEFORE=$(grep -c "^Watch complete:" ${D}/loop9/slack-watch.log)
export FAKE_PROMPT_OUT=${D}/prompt9b.txt
env -u AUTONOMY_LOOP -u SLACK_WATCH_ENABLED SLACK_POST_ENABLED=false SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop9 AUTONOMY_LOOP_WORKDIR=${D}/loop9 AUTONOMY_LOOP_GOALS=${D}/loop9/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once9b.out 2>&1 < /dev/null || fail "loop-once (SLACK_POST_ENABLED=false) exited nonzero: $(cat ${D}/once9b.out)"
WATCHES_AFTER=$(grep -c "^Watch complete:" ${D}/loop9/slack-watch.log)
[ "${WATCHES_AFTER}" = "$(( WATCHES_BEFORE + 1 ))" ] || fail "SLACK_POST_ENABLED=false: the watch did not run exactly once more (${WATCHES_BEFORE} -> ${WATCHES_AFTER})"
grep -qF "currently off: SLACK_POST_ENABLED=false" ${D}/prompt9b.txt || fail "SLACK_POST_ENABLED=false: the fire prompt does not state that posting is off"
echo "ok 22 - SLACK_POST_ENABLED=false: slack-post.sh refuses naming the gate, nothing reached the API, the watch still runs, the prompt says posting is off"

# token empty, gates unset: all off, the refusal names the auto rule, a fire runs without Slack
G=$(${UNSET_GATES} SLACK_BOT_TOKEN= "${GATES}" 2>&1) || fail "slack-gates.sh (report mode) exited nonzero with no token: ${G}"
[ "$(echo "${G}" | grep -c "(effective: off - SLACK_BOT_TOKEN not set)")" = "3" ] || fail "token empty + gates unset: not all three off naming SLACK_BOT_TOKEN: ${G}"
for GATE in loop watch post; do
	[ "$(${UNSET_GATES} SLACK_BOT_TOKEN= "${GATES}" ${GATE})" = "off" ] || fail "slack-gates.sh ${GATE} did not answer off with no token"
	${UNSET_GATES} SLACK_BOT_TOKEN= "${GATES}" ${GATE} > /dev/null && fail "slack-gates.sh ${GATE} exited 0 while off"
done
OUT=$(env -u SLACK_POST_ENABLED SLACK_BOT_TOKEN= "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "must be refused" 2>&1) && fail "post with no token and the gate unset exited 0"
echo "${OUT}" | grep -q "SLACK_BOT_TOKEN not set" || fail "no-token refusal does not say why the gate is off: ${OUT}"
echo "${OUT}" | grep -q "auto or unset" || fail "no-token refusal does not name the auto rule: ${OUT}"
mkdir -p ${D}/loop10
echo "test goal" > ${D}/loop10/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt10.txt
${UNSET_GATES} SLACK_BOT_TOKEN= SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop10 AUTONOMY_LOOP_WORKDIR=${D}/loop10 AUTONOMY_LOOP_GOALS=${D}/loop10/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once10.out 2>&1 < /dev/null || fail "loop-once (no token, gates unset) exited nonzero: $(cat ${D}/once10.out)"
grep -q "SLACK INBOX" ${D}/prompt10.txt && fail "no token: the fire prompt has a SLACK INBOX section"
grep -qF "You are one fire of the do-agent-aws autonomy loop" ${D}/prompt10.txt || fail "no token: the fire did not run"
grep -q "SLACK" ${D}/loop10/loop.log && fail "no token: loop.log contains SLACK lines"
[ ! -f ${D}/loop10/slack-watch.log ] || fail "no token: the watch ran (slack-watch.log exists)"
grep -qi "error" ${D}/once10.out && fail "no token: the fire printed an error: $(cat ${D}/once10.out)"
echo "ok 23 - token empty + gates unset: all three off naming SLACK_BOT_TOKEN, the refusal names the auto rule, a fire ran without Slack context and without error"

# the loop autostart decision: explicit false off; a stray value off with a WARNING; explicit true on regardless
[ "$(AUTONOMY_LOOP=false "${GATES}" loop)" = "off" ] || fail "AUTONOMY_LOOP=false: autostart decision is not off"
AUTONOMY_LOOP=false "${GATES}" loop > /dev/null && fail "AUTONOMY_LOOP=false: slack-gates.sh loop exited 0"
G=$(env -u SLACK_WATCH_ENABLED -u SLACK_POST_ENABLED AUTONOMY_LOOP=false "${GATES}" 2>&1)
echo "${G}" | grep -q "^loop autostart: AUTONOMY_LOOP=false (effective: off - AUTONOMY_LOOP=false)" || fail "AUTONOMY_LOOP=false: report line wrong: ${G}"
[ "$(echo "${G}" | grep -c "(effective: on - token and channels set)")" = "2" ] || fail "AUTONOMY_LOOP=false turned the watch or post gate off: ${G}"
WARN=$(SLACK_WATCH_ENABLED=yes "${GATES}" watch 2>&1 > /dev/null)
echo "${WARN}" | grep -q "^WARNING: SLACK_WATCH_ENABLED='yes' is not true, false or auto" || fail "stray gate value: no WARNING naming the variable and value: ${WARN}"
[ "$(SLACK_WATCH_ENABLED=yes "${GATES}" watch 2>/dev/null)" = "off" ] || fail "stray gate value 'yes' did not resolve to off"
[ "$(SLACK_BOT_TOKEN= SLACK_CHANNELS= AUTONOMY_LOOP=true "${GATES}" loop 2>/dev/null)" = "on" ] || fail "AUTONOMY_LOOP=true with nothing configured is not on"
echo "ok 24 - AUTONOMY_LOOP=false: autostart off while watch and post stay on; a stray value is off with a WARNING; explicit true is on with nothing configured"

# --- 17. the Slack chat responder: answers on its own interval, independent of the loop ---
# Both processes run: a loop with a 600 s interval and no goals file, and the responder with a 1 s poll.
CHAT="${AGENT_DIR}/slack-chat.sh"
replies_done()
{
	# successful replies the responder has logged (written after slack-post.sh read-back verified and
	# appended posted.jsonl - the stub's own post count is incremented earlier, at chat.postMessage)
	C=$(grep -c " CHAT REPLY .* ok posted=" ${SLACK_DIR}/chat.log 2>/dev/null)
	echo "${C:-0}"
}
wait_for_replies()
{
	# wait_for_replies <seconds> <expected replies_done count> - poll every 0.5s
	N=0
	while [ "$(replies_done)" != "$2" ]; do
		[ ${N} -ge $(( $1 * 2 )) ] && return 1
		sleep 0.5
		N=$((N + 1))
	done
	return 0
}
chat_fail()
{
	kill "${CHAT_PID}" "${LOOP_PID}" 2>/dev/null
	fail "$1"
}
[ "$(inbox_depth)" = "0" ] || fail "precondition: inbox not empty before check 25 (depth $(inbox_depth))"
mkdir -p ${D}/loop11                                                  # deliberately no GOALS.md
# the responder's option words are split on spaces but never glob-expanded (as a fire's, check 60): a path matching its
# rule Bash(/agent/slack-post.sh:*) lies in its working directory, and the exact argv below still holds the rule as written
mkdir -p "${D}/loop11/Bash(/agent"
: > "${D}/loop11/Bash(/agent/slack-post.sh:p25)"
W25="Bash(/agent/slack-post.sh:*)"
# shellcheck disable=SC2086 # PLANTED CONTROL: the shell itself expands the word there
[ "$(cd ${D}/loop11 && printf '%s\n' ${W25})" == "Bash(/agent/slack-post.sh:p25)" ] \
	|| fail "PLANTED CONTROL BROKEN: the planted path does not match the responder's rule word, so check 25 could not see an expansion"
CHAT_ENV="env -u SLACK_CHAT_ENABLED -u SLACK_WATCH_ENABLED -u SLACK_POST_ENABLED -u AUTONOMY_LOOP"
export FAKE_PROMPT_OUT="${D:?}/chat-prompt.txt"
export FAKE_ARGV_OUT="${D:?}/chat-argv.txt"
rm -f "${FAKE_PROMPT_OUT:?}" "${FAKE_ARGV_OUT:?}"
${CHAT_ENV} SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	AUTONOMY_LOOP_INTERVAL=600 \
	"${AGENT_DIR}/loop.sh" > ${D}/loop11.out 2>&1 &
LOOP_PID=$!
${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	AUTONOMY_LOOP_INTERVAL=600 \
	"${CHAT}" > ${D}/chat11.out 2>&1 &
CHAT_PID=$!
wait_for_line 15 "CHAT START" ${SLACK_DIR}/chat.log || chat_fail "slack-chat.sh did not log CHAT START within 15s: $(cat ${SLACK_DIR}/chat.log ${D}/chat11.out 2>/dev/null)"
wait_for_line 15 "LOOP IDLE" ${D}/loop11/loop.log || chat_fail "loop.sh did not log LOOP IDLE within 15s: $(cat ${D}/loop11/loop.log ${D}/loop11.out 2>/dev/null)"
grep -q "LOOP SLACK intake owned by /agent/slack-chat.sh" ${D}/loop11/loop.log || chat_fail "the loop did not log that the intake is owned by the responder: $(cat ${D}/loop11/loop.log)"
grep "LOOP IDLE" ${D}/loop11/loop.log | head -1 | grep -qE " LOOP IDLE goals file ${D}/loop11/GOALS.md not found$" \
	|| chat_fail "chat on: the loop's IDLE line is not the plain goals-file text: $(grep 'LOOP IDLE' ${D}/loop11/loop.log | head -1)"
grep -q "^IDLE reason=no-goals-file" ${D}/loop11/loop.state || chat_fail "loop.state is not IDLE: $(cat ${D}/loop11/loop.state)"
[ ! -f ${D}/loop11/slack-watch.log ] || chat_fail "chat on: the loop ran its own Slack watch (slack-watch.log exists)"
grep -q "^POLLING interval=1s" ${SLACK_DIR}/chat.state || chat_fail "chat.state is not POLLING: $(cat ${SLACK_DIR}/chat.state)"
POSTED0=$(stub_posted)
SEED_T0=$(date +%s)
HELLO_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=hello+from+a+teammate" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${HELLO_TS}" ] || chat_fail "the stub did not seed the first message"
wait_for_replies 15 1 || chat_fail "no reply within 15s of a seeded message (stub posted ${POSTED0} -> $(stub_posted)): $(cat ${SLACK_DIR}/chat.log)"
REPLY_SECS=$(( $(date +%s) - SEED_T0 ))
[ "$(stub_posted)" = "$(( POSTED0 + 1 ))" ] || chat_fail "stub posted count $(stub_posted) != $(( POSTED0 + 1 )) after the first reply"
grep -q "CHAT MSG .* kind=model text=\"hello from a teammate\"" ${SLACK_DIR}/chat.log || chat_fail "chat.log has no CHAT MSG line for the message: $(cat ${SLACK_DIR}/chat.log)"
grep -q "CHAT REPLY .* kind=model ok posted=" ${SLACK_DIR}/chat.log || chat_fail "chat.log has no successful CHAT REPLY line: $(cat ${SLACK_DIR}/chat.log)"
[ "$(stub_last_post text)" = "fake model reply to: hello from a teammate" ] || chat_fail "the posted reply is not the model's: '$(stub_last_post text)'"
grep -q "^IDLE reason=no-goals-file" ${D}/loop11/loop.state || chat_fail "the loop left IDLE while the responder answered: $(cat ${D}/loop11/loop.state)"
grep -q " BEGIN " ${D}/loop11/loop.log && chat_fail "the loop fired while the responder answered"
printf '%s\n' "-p" "--allowedTools" "Bash(/agent/slack-post.sh:*)" "Bash(/agent/slack-upload.sh:*)" "Bash(/agent/goals-add.sh:*)" "--permission-mode" "acceptEdits" > ${D}/chat-argv.expected
cmp -s ${D}/chat-argv.expected ${FAKE_ARGV_OUT} \
	|| chat_fail "the responder's claude argv is not exactly -p and its safe value (the shipped default): $(tr '\n' ' ' < ${FAKE_ARGV_OUT})"
[ "$(cat ${FAKE_ARGV_OUT}.sandbox 2>/dev/null)" == "1" ] && chat_fail "the responder's claude got IS_SANDBOX=1, though its safe value skips no permission check"
grep -q "^SLACK CHAT" ${FAKE_PROMPT_OUT} || chat_fail "the responder's prompt does not start with the SLACK CHAT marker"
grep -q "^text: hello from a teammate" ${FAKE_PROMPT_OUT} || chat_fail "the responder's prompt lacks the message text"
# the prompt of a TOP-LEVEL message names where the message is (thread_ts=none) and where the answer goes (reply_thread=
# its own ts), and RULE 1 says so (SLACK_REPLY_IN_THREAD, the default)
grep -q "^MESSAGE: ts=${HELLO_TS} .* thread_ts=none reply_thread=${HELLO_TS}$" ${FAKE_PROMPT_OUT} || chat_fail "the model prompt does not name both where the message is (thread_ts=none) and where the answer goes (reply_thread=${HELLO_TS}): $(grep '^MESSAGE' ${FAKE_PROMPT_OUT})"
grep -q "in a thread under it (thread_ts ${HELLO_TS}) - the thread this topic continues in" ${FAKE_PROMPT_OUT} || chat_fail "RULE 1 of the model prompt does not say the answer goes in a thread under the message: $(grep '^1\.' ${FAKE_PROMPT_OUT})"
grep -q "^loop: IDLE reason=no-goals-file" ${FAKE_PROMPT_OUT} || chat_fail "the responder's prompt lacks the agent status"
grep -q "never create ${D}/loop11/STOP" ${FAKE_PROMPT_OUT} || chat_fail "the responder's prompt does not forbid the stop flag"
ls ${SLACK_DIR}/chat/C0TESTCHAN-*.out > /dev/null 2>&1 || chat_fail "no transcript under ${SLACK_DIR}/chat/"
echo "ok 25 - chat responder: replied in ${REPLY_SECS}s to a Slack message while the loop (interval 600s) stayed IDLE and ran no watch; loop logs the intake hand-over; claude argv and prompt as designed"

# "status" and "goals": answered from files, no claude call
rm -f "${FAKE_PROMPT_OUT:?}" "${FAKE_ARGV_OUT:?}"
POSTED0=$(stub_posted)
curl -s "${SLACK_API_BASE}/stub.seedMessage?text=Status" > /dev/null
wait_for_replies 15 2 || chat_fail "no reply to 'status' within 15s: $(cat ${SLACK_DIR}/chat.log)"
[ ! -f ${FAKE_PROMPT_OUT} ] || chat_fail "'status' was answered with a claude call (prompt record written)"
grep -q "CHAT MSG .* kind=status " ${SLACK_DIR}/chat.log || chat_fail "chat.log does not classify 'status' as the fast path: $(tail -3 ${SLACK_DIR}/chat.log)"
stub_last_post text | grep -q "^loop: IDLE reason=no-goals-file" || chat_fail "the status reply lacks the loop.state line: $(stub_last_post text)"
stub_last_post text | grep -q "^chat: POLLING" || chat_fail "the status reply lacks the chat.state line: $(stub_last_post text)"
curl -s "${SLACK_API_BASE}/stub.seedMessage?text=list+goals" > /dev/null
wait_for_replies 15 3 || chat_fail "no reply to 'list goals' within 15s: $(cat ${SLACK_DIR}/chat.log)"
[ ! -f ${FAKE_PROMPT_OUT} ] || chat_fail "'list goals' was answered with a claude call (prompt record written)"
grep -q "CHAT MSG .* kind=goals " ${SLACK_DIR}/chat.log || chat_fail "chat.log does not classify 'list goals' as the fast path: $(tail -3 ${SLACK_DIR}/chat.log)"
stub_last_post text | grep -q "no goals file yet" || chat_fail "the goals reply with no goals file does not say so: $(stub_last_post text)"
echo "ok 26 - 'status' and 'goals' answered from files with no claude call; the status reply carries the loop.state and chat.state lines"

# a goal stated in chat lands in the goals file for the loop
POSTED0=$(stub_posted)
curl -s "${SLACK_API_BASE}/stub.seedMessage?text=please+add+a+goal:+write+the+release+notes" > /dev/null
wait_for_replies 15 4 || chat_fail "no reply to the goal message within 15s: $(cat ${SLACK_DIR}/chat.log)"
[ -f ${FAKE_PROMPT_OUT} ] || chat_fail "the goal message did not reach the model (no prompt record)"
grep -q "please add a goal: write the release notes" ${FAKE_PROMPT_OUT} || chat_fail "the model prompt lacks the goal message text"
[ -f ${D}/loop11/GOALS.md ] || chat_fail "no goals file was created at ${D}/loop11/GOALS.md"
grep -qxF "## Goals from Slack" ${D}/loop11/GOALS.md || chat_fail "the goals file has no '## Goals from Slack' heading: $(cat ${D}/loop11/GOALS.md)"
grep -qE "^- \[ \] write the release notes \(from Slack C0TESTCHAN [0-9]+\.[0-9]+\)$" ${D}/loop11/GOALS.md || chat_fail "the goal line is not under the heading as designed: $(grep -n 'release notes' ${D}/loop11/GOALS.md)"
H=$(grep -nxF "## Goals from Slack" ${D}/loop11/GOALS.md | cut -d: -f1); L=$(grep -n "write the release notes" ${D}/loop11/GOALS.md | cut -d: -f1)
[ "${L}" -gt "${H}" ] || chat_fail "the goal line (${L}) is not below the heading (${H})"
stub_last_post text | grep -qi "added" || chat_fail "the reply does not say the goal was added: $(stub_last_post text)"
echo "ok 27 - 'please add a goal: ...' is recorded under '## Goals from Slack' in the goals file and the reply says so"

# no double answer, own posts skipped, each handled line processed once, thread replies in-thread
curl -s "${SLACK_API_BASE}/stub.seedReply?text=question+in+the+thread" > /dev/null
wait_for_replies 15 5 || chat_fail "no reply to the thread message within 15s: $(cat ${SLACK_DIR}/chat.log)"
[ "$(stub_last_post thread_ts)" = "${M2_TS}" ] || chat_fail "the reply to a thread message is not in that thread (thread_ts '$(stub_last_post thread_ts)' != ${M2_TS})"
grep -q "CHAT MSG .* thread_ts=${M2_TS} reply_thread=${M2_TS} kind=model" ${SLACK_DIR}/chat.log || chat_fail "chat.log does not carry the message's thread_ts and the reply thread: $(tail -3 ${SLACK_DIR}/chat.log)"
grep -q "\"thread_ts\":\"${M2_TS}\"" ${SLACK_DIR}/posted.jsonl || chat_fail "posted.jsonl lacks the thread_ts of the thread reply"
# a TOP-LEVEL message is answered in a thread under it (SLACK_REPLY_IN_THREAD, the default): the model's reply to the
# first message carries that message's own ts as its thread, the log names the reply thread, posted.jsonl carries it,
# and the thread is in the watcher's registry, so the person's follow-up there is collected and answered there
[ "$(stub_post_thread "fake model reply to: hello from a teammate")" = "${HELLO_TS}" ] \
	|| chat_fail "the reply to the top-level message 'hello from a teammate' is not in a thread under it (thread_ts '$(stub_post_thread "fake model reply to: hello from a teammate")' != ${HELLO_TS})"
grep -q "CHAT MSG ts=${HELLO_TS} channel=C0TESTCHAN user=U0PERSON reply_thread=${HELLO_TS} kind=model" ${SLACK_DIR}/chat.log \
	|| chat_fail "chat.log does not name the reply thread of the top-level message: $(grep "CHAT MSG ts=${HELLO_TS}" ${SLACK_DIR}/chat.log)"
grep -q "CHAT REPLY ts=${HELLO_TS} kind=model ok posted=[0-9.]* reply_thread=${HELLO_TS}" ${SLACK_DIR}/chat.log \
	|| chat_fail "the CHAT REPLY line of the top-level message does not name its reply thread: $(grep "CHAT REPLY ts=${HELLO_TS}" ${SLACK_DIR}/chat.log)"
grep -q "\"thread_ts\":\"${HELLO_TS}\"" ${SLACK_DIR}/posted.jsonl || chat_fail "posted.jsonl lacks the thread_ts of the reply to the top-level message"
grep -q "^${HELLO_TS} " ${SLACK_DIR}/threads-C0TESTCHAN || chat_fail "the thread the responder started under the top-level message is not in the watcher's registry"
sleep 3                                                               # three more polls: the bot's own replies come back through the watch
[ "$(stub_posted)" = "$(( POSTED0 + 2 ))" ] || chat_fail "double answer: stub posted count $(stub_posted) != $(( POSTED0 + 2 )) after the inbox settled (own replies answered?)"
[ "$(grep -c 'CHAT SKIP .* own post' ${SLACK_DIR}/chat.log)" -ge 5 ] || chat_fail "the responder did not skip its own posts coming back through the watch: $(grep -c 'own post' ${SLACK_DIR}/chat.log) skips"
[ "$(grep -c ' CHAT MSG ' ${SLACK_DIR}/chat.log)" = "5" ] || chat_fail "expected exactly 5 handled messages, chat.log has $(grep -c ' CHAT MSG ' ${SLACK_DIR}/chat.log)"
[ "$(replies_done)" = "5" ] || chat_fail "expected exactly 5 successful replies, chat.log has $(replies_done)"
[ "$(inbox_depth)" = "0" ] || chat_fail "inbox not drained by the responder: depth $(inbox_depth)"
for T in "hello from a teammate" "Status" "list goals" "please add a goal: write the release notes" "question in the thread"; do
	# the exact text field: the bot's own replies quote the human text and are in processed.jsonl too (skipped)
	[ "$(grep -cF "\"text\":\"${T}\"" ${SLACK_DIR}/processed.jsonl)" = "1" ] || chat_fail "processed.jsonl holds '${T}' $(grep -cF "\"text\":\"${T}\"" ${SLACK_DIR}/processed.jsonl) times, expected once"
done
grep -q " BEGIN " ${D}/loop11/loop.log && chat_fail "the loop fired during the chat checks (interval 600s)"
# the topic continues in the thread the responder started: the person's follow-up there is collected (the registry) and
# answered in the same thread, with the first answer in view
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${HELLO_TS}&text=a+follow-up+in+the+thread+under+hello" > /dev/null
wait_for_replies 15 6 || chat_fail "no reply within 15s to the follow-up in the thread the responder started: $(tail -5 ${SLACK_DIR}/chat.log)"
[ "$(stub_post_thread "fake model reply to: a follow-up in the thread under hello")" = "${HELLO_TS}" ] \
	|| chat_fail "the reply to the follow-up is not in the thread under the first message: $(stub_post_thread "fake model reply to: a follow-up in the thread under hello")"
grep -q "CHAT MSG .* thread_ts=${HELLO_TS} reply_thread=${HELLO_TS} kind=model text=\"a follow-up in the thread under hello\"" ${SLACK_DIR}/chat.log \
	|| chat_fail "the follow-up was not handled as a message in the thread under the first message: $(grep 'follow-up in the thread under hello' ${SLACK_DIR}/chat.log | head -2)"
echo "ok 28 - exactly one reply per inbound message while both processes run; own replies skipped; each handled line in processed.jsonl once; a thread message answered in its thread; a top-level message answered in a thread under it (its own ts), named in the log, posted.jsonl and the registry; the follow-up in that thread collected and answered there"

# HTTP 429: Retry-After honored, the next message still answered
curl -s "${SLACK_API_BASE}/stub.ratelimit?n=1" > /dev/null
wait_for_line 15 "CHAT RATE LIMITED retry_after=1s" ${SLACK_DIR}/chat.log || chat_fail "the responder did not log the rate limit: $(tail -5 ${SLACK_DIR}/chat.log)"
grep -q "CHAT WATCH FAILED" ${SLACK_DIR}/chat.log || chat_fail "the rate-limited watch was not logged as failed"
grep -q "HTTP 429, Retry-After 1s" ${SLACK_DIR}/chat-watch.log || chat_fail "slack-watch.sh did not report the 429 with its Retry-After: $(tail -3 ${SLACK_DIR}/chat-watch.log)"
[ ! -f ${SLACK_DIR}/retry-after ] || chat_fail "retry-after file left behind after the pause"
POSTED0=$(stub_posted)
curl -s "${SLACK_API_BASE}/stub.seedMessage?text=still+there" > /dev/null
wait_for_replies 15 7 || chat_fail "no reply after the rate limit: $(tail -5 ${SLACK_DIR}/chat.log)"
[ "$(stub_posted)" = "$(( POSTED0 + 1 ))" ] || chat_fail "stub posted count $(stub_posted) != $(( POSTED0 + 1 )) after the rate limit"
echo "ok 29 - HTTP 429 from the API: Retry-After slept and logged, the next message still answered"

# stop, status, start
OUT=$(SLACK_DIR=${SLACK_DIR} "${AGENT_DIR}/slack-chat-stop.sh" 2>&1) || chat_fail "slack-chat-stop.sh exited nonzero: ${OUT}"
echo "${OUT}" | grep -q "halts at its next poll" || chat_fail "slack-chat-stop.sh did not say the responder halts at its next poll: ${OUT}"
wait_for_line 15 "STOPPED reason=stop-flag" ${SLACK_DIR}/chat.state || chat_fail "chat.state did not become STOPPED within 15s: $(cat ${SLACK_DIR}/chat.state)"
wait "${CHAT_PID}" 2>/dev/null
CHAT_PID=""
OUT=$(${CHAT_ENV} "${AGENT_DIR}/slack-chat-status.sh" 2>&1) && chat_fail "slack-chat-status.sh exited 0 with the responder stopped: ${OUT}"
echo "${OUT}" | grep -q "Slack chat responder: stopped - STOPPED reason=stop-flag" || chat_fail "status does not report the stop: ${OUT}"
echo "${OUT}" | grep -q "Stop flag: present" || chat_fail "status does not report the stop flag: ${OUT}"
echo "${OUT}" | grep -q "Messages handled: 7" || chat_fail "status does not count the 7 handled messages: ${OUT}"
OUT=$(SLACK_DIR=${SLACK_DIR} "${AGENT_DIR}/slack-chat-stop.sh" 2>&1) || chat_fail "second slack-chat-stop.sh exited nonzero: ${OUT}"
echo "${OUT}" | grep -q "is not running" || chat_fail "second stop did not say the responder is not running: ${OUT}"
# the restart runs with SLACK_REPLY_IN_THREAD=false: a top-level message answered top-level
OUT=$(${CHAT_ENV} SLACK_REPLY_IN_THREAD=false SLACK_CHAT_POLL_INTERVAL=1 CLAUDE_BIN=${D}/fakeclaude AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${AGENT_DIR}/slack-chat-start.sh" 2>&1) || chat_fail "slack-chat-start.sh failed: ${OUT}"
echo "${OUT}" | grep -q "Removing stop flag" || chat_fail "slack-chat-start.sh did not remove the stop flag: ${OUT}"
echo "${OUT}" | grep -q "Slack chat responder started pid=" || chat_fail "slack-chat-start.sh did not report a start: ${OUT}"
RESTART_PID=$(echo "${OUT}" | sed -n 's/.*started pid=\([0-9]*\).*/\1/p')
kill -0 "${RESTART_PID}" 2>/dev/null || chat_fail "restarted responder pid ${RESTART_PID} is not alive: $(tail -3 ${SLACK_DIR}/chat.stdout)"
OUT=$(${CHAT_ENV} "${AGENT_DIR}/slack-chat-status.sh" 2>&1) || chat_fail "slack-chat-status.sh exited nonzero with the responder running: ${OUT}"
echo "${OUT}" | grep -q "Slack chat responder: running (pid ${RESTART_PID})" || chat_fail "status does not report the restarted responder as running: ${OUT}"
OFF30_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+top-level+message+with+the+knob+off" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${OFF30_TS}" ] || chat_fail "the stub did not seed the knob-off message"
wait_for_replies 15 8 || chat_fail "no reply within 15s to the message with SLACK_REPLY_IN_THREAD=false: $(tail -5 ${SLACK_DIR}/chat.log)"
[ "$(stub_post_thread "fake model reply to: a top-level message with the knob off")" = "none" ] \
	|| chat_fail "with SLACK_REPLY_IN_THREAD=false the reply to a top-level message is in a thread ($(stub_post_thread "fake model reply to: a top-level message with the knob off")), not top-level where the person wrote"
grep -q "CHAT MSG ts=${OFF30_TS} channel=C0TESTCHAN user=U0PERSON reply_thread=none kind=model" ${SLACK_DIR}/chat.log \
	|| chat_fail "with SLACK_REPLY_IN_THREAD=false the log does not say reply_thread=none: $(grep "CHAT MSG ts=${OFF30_TS}" ${SLACK_DIR}/chat.log)"
grep -q "^${OFF30_TS} " ${SLACK_DIR}/threads-C0TESTCHAN && chat_fail "with SLACK_REPLY_IN_THREAD=false a top-level answer registered a thread"
OUT=$(${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 "${AGENT_DIR}/slack-chat-start.sh" 2>&1) || chat_fail "second slack-chat-start.sh exited nonzero: ${OUT}"
echo "${OUT}" | grep -q "already running (pid ${RESTART_PID})" || chat_fail "second start did not report already running: ${OUT}"
OUT=$(SLACK_DIR=${SLACK_DIR} "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1) || chat_fail "slack-chat-stop.sh --now failed: ${OUT}"
echo "${OUT}" | grep -q "stopped (pid ${RESTART_PID} terminated)" || chat_fail "stop --now did not report the termination: ${OUT}"
kill -0 "${RESTART_PID}" 2>/dev/null && chat_fail "responder pid ${RESTART_PID} still alive after stop --now"
touch ${D}/loop11/STOP
wait_for_line 20 "STOPPED reason=stop-flag" ${D}/loop11/loop.state || chat_fail "loop.sh did not stop on the STOP flag: $(cat ${D}/loop11/loop.state)"
wait "${LOOP_PID}" 2>/dev/null
LOOP_PID=""
echo "ok 30 - slack-chat-stop.sh halts the responder (chat.state STOPPED), slack-chat-status.sh reports stopped/running, slack-chat-start.sh removes the flag and restarts it, --now terminates it; restarted with SLACK_REPLY_IN_THREAD=false it answers a top-level message top-level (reply_thread=none, no thread registered)"

# --- 18. SLACK_CHAT_ENABLED=false: the responder refuses, the loop keeps its own intake ---
OUT=$(SLACK_CHAT_ENABLED=false "${AGENT_DIR}/slack-chat-start.sh" 2>&1) && fail "slack-chat-start.sh exited 0 with SLACK_CHAT_ENABLED=false: ${OUT}"
echo "${OUT}" | grep -q "chat gate is off (SLACK_CHAT_ENABLED=false)" || fail "the refusal does not name the gate: ${OUT}"
OUT=$(SLACK_CHAT_ENABLED=false "${CHAT}" 2>&1) && fail "slack-chat.sh exited 0 with SLACK_CHAT_ENABLED=false: ${OUT}"
echo "${OUT}" | grep -q "refusing to run: the chat gate is off (SLACK_CHAT_ENABLED=false)" || fail "slack-chat.sh did not refuse naming the gate: ${OUT}"
[ "$(SLACK_CHAT_ENABLED=false "${GATES}" chat)" = "off" ] || fail "slack-gates.sh chat is not off with SLACK_CHAT_ENABLED=false"
G=$(${UNSET_GATES} SLACK_CHAT_ENABLED=false "${GATES}" 2>&1)
echo "${G}" | grep -q "^chat gate: SLACK_CHAT_ENABLED=false (effective: off - SLACK_CHAT_ENABLED=false)" || fail "chat gate line wrong with the explicit false: ${G}"
[ "$(echo "${G}" | grep -c "(effective: on - token and channels set)")" = "3" ] || fail "SLACK_CHAT_ENABLED=false turned another gate off: ${G}"
G=$(${CHAT_ENV} "${GATES}" 2>&1)
[ "$(echo "${G}" | grep -c "(effective: on - token and channels set)")" = "4" ] || fail "all four gates unset + token and channels: not all four on: ${G}"
echo "${G}" | grep -q "^chat gate: SLACK_CHAT_ENABLED=unset (effective: on - token and channels set)" || fail "chat gate not on by the auto rule: ${G}"
[ "$(${CHAT_ENV} SLACK_BOT_TOKEN= "${GATES}" chat)" = "off" ] || fail "chat gate not off with no token"
OUT=$(${CHAT_ENV} "${AGENT_DIR}/slack-status.sh" 2>&1) || fail "slack-status.sh exited nonzero: ${OUT}"
echo "${OUT}" | grep -q "chat gate: SLACK_CHAT_ENABLED=unset (effective: on - token and channels set)" || fail "slack-status.sh does not show the chat gate: ${OUT}"
# the loop with the explicit false: checks 12-24 above ran exactly so; one more cycle here proves the intake line is absent
mkdir -p ${D}/loop12
echo "test goal" > ${D}/loop12/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt12.txt
curl -s "${SLACK_API_BASE}/stub.seedMessage?text=for+the+loop" > /dev/null
SLACK_CHAT_ENABLED=false SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop12 AUTONOMY_LOOP_WORKDIR=${D}/loop12 AUTONOMY_LOOP_GOALS=${D}/loop12/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once12.out 2>&1 < /dev/null || fail "loop-once (chat off) exited nonzero: $(cat ${D}/once12.out)"
grep -q "SLACK INBOX" ${D}/prompt12.txt || fail "chat off: the fire prompt has no SLACK INBOX section (the loop lost its intake)"
grep -qF "for the loop" ${D}/prompt12.txt || fail "chat off: the fire prompt lacks the new inbox line"
grep -q "intake owned by" ${D}/loop12/loop.log && fail "chat off: loop.log claims the responder owns the intake"
echo "ok 31 - SLACK_CHAT_ENABLED=false: responder and its start script refuse naming the gate; chat gate off while the other three stay on; all four on when unset; the loop keeps its own intake (checks 12-24 ran with the explicit false)"

# --- 19. a loop fire answers in the thread of the message: a thread under a top-level message, the thread of a thread reply ---
# (SLACK_REPLY_IN_THREAD, the .env default true: the person starts a topic top-level and everything on it goes to the
# thread under that message, so the channel's top level stays the list of topics; false answers top-level - for people
# who DM the agent top-level and expect the answer below their message. The sentence the prompt states is what
# the fake parses: a wording it does not know fails the fire, so a prompt that lost the rule fails this check.)
mkdir -p ${D}/loop13
echo "test goal" > ${D}/loop13/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt13.txt
Q32_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+top-level+question+for+the+loop" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${Q32_TS}" ] || fail "check 32: the stub did not seed the top-level question"
curl -s "${SLACK_API_BASE}/stub.seedReply?text=a+question+in+the+thread+for+the+loop" > /dev/null
FAKE_LOOP_POST=1 SLACK_POST_ENABLED=true SLACK_CHAT_ENABLED=false SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop13 AUTONOMY_LOOP_WORKDIR=${D}/loop13 AUTONOMY_LOOP_GOALS=${D}/loop13/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once13.out 2>&1 < /dev/null || fail "check 32: loop-once exited nonzero: $(cat ${D}/once13.out)"
grep -q "a top-level question for the loop" ${D}/prompt13.txt || fail "check 32: the fire prompt lacks the top-level message"
grep -q "a question in the thread for the loop" ${D}/prompt13.txt || fail "check 32: the fire prompt lacks the thread message"
grep -qF "always in-thread: pass the message's thread_ts when it has one, else its ts" ${D}/prompt13.txt || fail "check 32: the fire prompt does not state the in-thread rule (SLACK_REPLY_IN_THREAD unset = true)"
grep -qF "(from Slack <channel> <ts>)" ${D}/prompt13.txt || fail "check 32: the fire prompt does not tell a fire where a goal recorded from Slack is reported on"
T_TOP=$(stub_post_thread "fake loop reply to: a top-level question for the loop")
T_THR=$(stub_post_thread "fake loop reply to: a question in the thread for the loop")
[ "${T_TOP}" = "${Q32_TS}" ] || fail "check 32: the fire's reply to a top-level message is not in a thread under it (thread_ts '${T_TOP}' != ${Q32_TS})"
[ "${T_THR}" = "${M2_TS}" ] || fail "check 32: the fire's reply to a message in a thread is not in that thread (${T_THR} != ${M2_TS})"
# SLACK_REPLY_IN_THREAD=false: a top-level message is answered top-level
mkdir -p ${D}/loop13b
echo "test goal" > ${D}/loop13b/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt13b.txt
curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+top-level+question+for+the+loop+with+the+knob+off" > /dev/null
curl -s "${SLACK_API_BASE}/stub.seedReply?text=a+thread+question+for+the+loop+with+the+knob+off" > /dev/null
SLACK_REPLY_IN_THREAD=false FAKE_LOOP_POST=1 SLACK_POST_ENABLED=true SLACK_CHAT_ENABLED=false SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop13b AUTONOMY_LOOP_WORKDIR=${D}/loop13b AUTONOMY_LOOP_GOALS=${D}/loop13b/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once13b.out 2>&1 < /dev/null || fail "check 32: loop-once (knob off) exited nonzero: $(cat ${D}/once13b.out)"
grep -qF "adding the message's thread_ts as a third argument only when the message has one - answer where the person wrote: in the thread for a message in a thread, top-level for a top-level message" ${D}/prompt13b.txt \
	|| fail "check 32: with SLACK_REPLY_IN_THREAD=false the fire prompt does not state the where-written rule verbatim"
grep -qF "always in-thread" ${D}/prompt13b.txt && fail "check 32: with SLACK_REPLY_IN_THREAD=false the fire prompt still states the in-thread rule"
T_TOP2=$(stub_post_thread "fake loop reply to: a top-level question for the loop with the knob off")
T_THR2=$(stub_post_thread "fake loop reply to: a thread question for the loop with the knob off")
[ "${T_TOP2}" = "none" ] || fail "check 32: with SLACK_REPLY_IN_THREAD=false the fire's reply to a top-level message was posted in a thread (${T_TOP2}), not top-level where the person wrote"
[ "${T_THR2}" = "${M2_TS}" ] || fail "check 32: with SLACK_REPLY_IN_THREAD=false the fire's reply to a message in a thread is not in that thread (${T_THR2} != ${M2_TS})"
echo "ok 32 - a loop fire answers in the thread of the message: a top-level message in a thread under it and a thread message in its thread by default (the prompt states the in-thread rule and the goal-thread rule); SLACK_REPLY_IN_THREAD=false restores the where-written rule verbatim, a top-level message answered top-level"

# --- 20. a thread the agent posts into stays watched: the person's follow-up in it is collected ---
# The agent can post in the thread of a message its watcher saw before that message had any replies:
# an operator's or a goal's slack-post.sh <channel> <text> <ts> (docs/slack/README.md section 9). The
# watcher registers a thread only when it first sees the parent with replies, and its cursor is past
# the parent, so conversations.history never shows that thread again: only the registry can bring the
# person's follow-up in.
TOP_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+top-level+message+the+agent+posts+under" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${TOP_TS}" ] || fail "check 33: the stub did not seed the top-level message"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch33a.out 2>&1 || fail "check 33: first watch failed: $(cat ${D}/watch33a.out)"
grep -q "\"ts\":\"${TOP_TS}\"" ${SLACK_DIR}/inbox.jsonl || fail "check 33: the top-level message was not collected"
grep -q "^${TOP_TS} " ${SLACK_DIR}/threads-C0TESTCHAN && fail "check 33: precondition - the message's thread is registered before any reply"
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a status in the thread of that message" "${TOP_TS}" 2>&1) \
	|| fail "check 33: the in-thread post failed: ${OUT}"
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${TOP_TS}&text=a+follow-up+under+the+agent+post" > /dev/null
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch33b.out 2>&1 || fail "check 33: second watch failed: $(cat ${D}/watch33b.out)"
grep -q "a follow-up under the agent post" ${SLACK_DIR}/inbox.jsonl \
	|| fail "check 33: the person's follow-up in the thread the agent posted into was never collected - thread ${TOP_TS} is not watched ($(tail -1 ${D}/watch33b.out))"
grep "a follow-up under the agent post" ${SLACK_DIR}/inbox.jsonl | grep -q "\"thread_ts\":\"${TOP_TS}\"" \
	|| fail "check 33: the follow-up was collected without its thread_ts"
[ "$(grep -c "^${TOP_TS} " ${SLACK_DIR}/threads-C0TESTCHAN)" = "1" ] || fail "check 33: thread ${TOP_TS} has $(grep -c "^${TOP_TS} " ${SLACK_DIR}/threads-C0TESTCHAN) registry lines, not 1"
# a second post in the same thread keeps one registry line, so the reply cursor is not reset
SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a second post in the same thread" "${TOP_TS}" > /dev/null 2>&1 \
	|| fail "check 33: the second in-thread post failed"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch33c.out 2>&1 || fail "check 33: third watch failed: $(cat ${D}/watch33c.out)"
[ "$(grep -c "^${TOP_TS} " ${SLACK_DIR}/threads-C0TESTCHAN)" = "1" ] || fail "check 33: a second post in the thread added a second registry line"
[ "$(grep -c "a follow-up under the agent post" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 33: the follow-up was collected twice (its thread's reply cursor was reset)"
# a channel post registers no thread
LINES0=$(grep -c . ${SLACK_DIR}/threads-C0TESTCHAN)
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a top-level post" 2>&1) || fail "check 33: the channel post failed: ${OUT}"
[ "$(grep -c . ${SLACK_DIR}/threads-C0TESTCHAN)" = "${LINES0}" ] || fail "check 33: a channel post registered a thread"
echo "ok 33 - a post in the thread of a message the watcher saw without replies: the person's follow-up there is collected; one registry line per thread, its cursor kept; a channel post registers nothing"

# --- 21. a reply threaded under the agent's own top-level post is collected - for a while, at a slow cadence ---
# People answer the agent top-level, but may thread a reply under its post. The watcher saw the post
# before it had replies and its cursor is past it; slack-post.sh lists the post for a bounded watch
# (2 h, the newest 5, checked at most every SLACK_ANSWER_POLL_INTERVAL seconds).
post_ts()
{
	# post_ts <text> - post top-level through slack-post.sh, print the posted ts
	SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "$1" 2>&1 | sed -n 's/^Posted and read-back verified: channel=C0TESTCHAN ts=\([0-9.]*\)$/\1/p'
}
watch_once()
{
	# watch_once <log name> - one watch with the default cadence; the agent's new post is seen with no replies
	"${AGENT_DIR}/slack-watch.sh" > "${D}/$1" 2>&1 || fail "check 34: watch failed: $(cat "${D}/$1")"
}
A_TS=$(post_ts "an answer from the agent, top-level")
[ -n "${A_TS}" ] || fail "check 34: the top-level post failed"
watch_once watch34-seen-a.out
grep -q "^${A_TS} " ${SLACK_DIR}/threads-C0TESTCHAN && fail "check 34: precondition - the post's thread is registered before it has a reply"
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${A_TS}&text=a+reply+threaded+under+the+agent+answer" > /dev/null
SLACK_ANSWER_POLL_INTERVAL=0 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch34a.out 2>&1 || fail "check 34: watch failed: $(cat ${D}/watch34a.out)"
grep "a reply threaded under the agent answer" ${SLACK_DIR}/inbox.jsonl | grep -q "\"thread_ts\":\"${A_TS}\"" \
	|| fail "check 34: the reply threaded under the agent's top-level post was never collected ($(tail -2 ${D}/watch34a.out | tr '\n' ' '))"
grep -q "^${A_TS} " ${SLACK_DIR}/threads-C0TESTCHAN || fail "check 34: the post with a reply did not move to the thread registry"
grep -q "^${A_TS} " ${SLACK_DIR}/answers-C0TESTCHAN && fail "check 34: the post with a reply is still listed for the slow watch"
# the cadence: right after a check, a run with the default interval (60 s) does not check again
B_TS=$(post_ts "a second answer from the agent")
watch_once watch34-seen-b.out
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${B_TS}&text=a+reply+under+the+second+answer" > /dev/null
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch34b.out 2>&1 || fail "check 34: watch (default cadence) failed"
grep -q "a reply under the second answer" ${SLACK_DIR}/inbox.jsonl && fail "check 34: the slow watch ran again within SLACK_ANSWER_POLL_INTERVAL (60 s)"
SLACK_ANSWER_POLL_INTERVAL=0 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch34c.out 2>&1 || fail "check 34: watch failed"
grep -q "a reply under the second answer" ${SLACK_DIR}/inbox.jsonl || fail "check 34: once the interval passed, the reply under the second post was not collected"
# expiry: a post no longer watched is not checked again
C_TS=$(export SLACK_ANSWER_WATCH_SECONDS=1; post_ts "a third answer from the agent, watched for 1 s")
watch_once watch34-seen-c.out
sleep 2
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${C_TS}&text=a+late+reply+under+the+third+answer" > /dev/null
SLACK_ANSWER_POLL_INTERVAL=0 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch34d.out 2>&1 || fail "check 34: watch failed"
grep -q "a late reply under the third answer" ${SLACK_DIR}/inbox.jsonl && fail "check 34: a post past its watch expiry was still checked"
grep -q "^${C_TS} " ${SLACK_DIR}/answers-C0TESTCHAN && fail "check 34: the expired post is still listed"
# the bound: at most 5 posts listed, the newest
for N in 1 2 3 4 5 6; do LAST_TS=$(post_ts "answer number ${N}"); done
[ "$(grep -c . ${SLACK_DIR}/answers-C0TESTCHAN)" = "5" ] || fail "check 34: $(grep -c . ${SLACK_DIR}/answers-C0TESTCHAN) posts listed, not the newest 5"
grep -q "^${LAST_TS} " ${SLACK_DIR}/answers-C0TESTCHAN || fail "check 34: the newest post is not listed"
echo "ok 34 - a reply threaded under the agent's top-level post is collected and its thread joins the registry; checked at most every 60 s, for 2 h, the newest 5 posts"

# --- 22. the read-back is exact: the message must be in the channel AS WRITTEN ---
curl -s "${SLACK_API_BASE}/stub.alterNext?mode=escape" > /dev/null
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "R&D <ok> > fine" 2>&1) \
	|| fail "check 35: a post Slack stores with & < > as entities failed its read-back: ${OUT}"
curl -s "${SLACK_API_BASE}/stub.alterNext?mode=truncate" > /dev/null
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a message the platform stores only the first half of" 2>&1) \
	&& fail "check 35: a post whose read-back text is truncated was reported as verified: ${OUT}"
echo "${OUT}" | grep -q "its text is not the text posted" || fail "check 35: the truncated post's refusal does not say the text differs: ${OUT}"
grep -q "a message the platform" ${SLACK_DIR}/posted.jsonl 2>/dev/null && fail "check 35: posted.jsonl logged the truncated post as verified"
# a text sent with Slack's own link markup reads back as sent: verified, not FAILED for its own markup
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "See <https://example.com/pr/30|PR 30> and <mailto:ops@example.com|ops> for the fix" 2>&1) \
	|| fail "check 35: a post written with Slack link markup <url|label> failed its read-back, though it reads back as sent: $(echo "${OUT}" | tail -1)"
echo "${OUT}" | grep -q "^Posted and read-back verified" || fail "check 35: the link-markup post was not reported verified: ${OUT}"
grep -q "See <https://example.com/pr/30|PR 30>" <<< "$(stub_last_post text)" || fail "check 35: precondition - the platform did not store the link markup as sent: $(stub_last_post text)"
echo "ok 35 - the read-back is exact: Slack's entity rendering is undone and accepted, link markup sent is accepted when it reads back as sent; a post stored truncated is FAILED, not verified"

# --- 23. a long message goes out in parts Slack does not split, each read back whole ---
stub_posts_since()
{
	# stub_posts_since <post count before> - the texts of the stub's posts since then, NUL-separated
	curl -s -H "Authorization: Bearer x" "${SLACK_API_BASE}/stub.state" | "${NODE_BIN}" -e '
let raw=""; process.stdin.on("data",d=>raw+=d);
process.stdin.on("end",()=>{ const p = JSON.parse(raw).posts.slice(parseInt(process.argv[1], 10));
	process.stdout.write(p.map(x => x.text).join("\0")); });' "$1"
}
stub_post_total()
{
	curl -s -H "Authorization: Bearer x" "${SLACK_API_BASE}/stub.state" | "${NODE_BIN}" -e '
let raw=""; process.stdin.on("data",d=>raw+=d); process.stdin.on("end",()=>console.log(JSON.parse(raw).posts.length));'
}
LONG=$(for N in $(seq 1 100); do printf 'line %03d of a long status from the agent, padded out to about seventy chars\n' "${N}"; done)
P0=$(stub_post_total)
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "${LONG}" 2>&1) \
	|| fail "check 36: a ${#LONG}-character post failed: $(echo "${OUT}" | tail -2)"
[ "$(echo "${OUT}" | grep -cE '^Posted and read-back verified: channel=C0TESTCHAN ts=[0-9.]+ \(part [0-9] of 3\)$')" = "3" ] \
	|| fail "check 36: the ${#LONG}-character post was not posted and verified as 3 parts: ${OUT}"
mapfile -d '' GOT < <(stub_posts_since "${P0}")
[ "${#GOT[@]}" = "3" ] || fail "check 36: the stub holds ${#GOT[@]} messages for the post, not 3 (did Slack's split happen?)"
for P in "${GOT[@]}"; do [ "${#P}" -le 3500 ] || fail "check 36: a part has ${#P} characters, above 3500"; done
[ "$(printf '%s\n' "${GOT[@]}")" = "${LONG}" ] || fail "check 36: the parts joined again are not the text posted"
ONE_LINE=$(printf 'x%.0s' $(seq 1 5000))
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "${ONE_LINE}" 2>&1) || fail "check 36: a 5000-character single-line post failed: $(echo "${OUT}" | tail -1)"
[ "$(echo "${OUT}" | grep -c '(part [0-9] of 2)$')" = "2" ] || fail "check 36: a 5000-character line was not posted as 2 parts: ${OUT}"
echo "ok 36 - a ${#LONG}-character message goes out as 3 parts of at most 3500 characters, each read back exactly, joined again equal to the text; a 5000-character line is split too"

# --- 24. the pre-send newest check: no answer from stale context ---
BEFORE_X=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=an+earlier+message" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
X_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+newer+message+from+the+person" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
P0=$(stub_post_total)
STALE_REC=${D:?}/stale37.rec; rm -f "${STALE_REC:?}"
OUT=$(SLACK_POST_ENABLED=true SLACK_POST_AFTER_TS=${BEFORE_X} SLACK_POST_STALE_RECORD=${STALE_REC} "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "an answer written before the newer message" 2>&1)
RC=$?
[ ${RC} -eq 3 ] || fail "check 37: a post written from before a newer message exited ${RC}, not 3: ${OUT}"
echo "${OUT}" | grep -q "STALE: not posting - a newer message arrived .* ts=${X_TS} user=U0PERSON" || fail "check 37: the refusal does not name the newer message: ${OUT}"
[ "$(cat "${STALE_REC}")" = "${X_TS} U0PERSON" ] || fail "check 37: SLACK_POST_STALE_RECORD is not '${X_TS} U0PERSON': $(cat "${STALE_REC}" 2>/dev/null)"
[ "$(stub_post_total)" = "${P0}" ] || fail "check 37: the stale answer reached the platform"
OUT=$(SLACK_POST_ENABLED=true SLACK_POST_AFTER_TS=${X_TS} "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "an answer that has read the newer message" 2>&1) \
	|| fail "check 37: a post written from the newest message was refused: ${OUT}"
OUT=$(SLACK_POST_ENABLED=true SLACK_POST_AFTER_TS=${X_TS} "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "another answer, after the agent's own post" 2>&1) \
	|| fail "check 37: the agent's own newer post counted as a newer message: ${OUT}"
Y_TS=$(curl -s "${SLACK_API_BASE}/stub.seedReply?text=a+newer+reply+in+the+thread" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
OUT=$(SLACK_POST_ENABLED=true SLACK_POST_AFTER_TS=${X_TS} "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a thread answer written before the newer reply" "${M2_TS}" 2>&1)
[ $? -eq 3 ] || fail "check 37: a thread post written from before a newer reply in the thread was not refused (exit 3): ${OUT}"
OUT=$(SLACK_POST_ENABLED=true SLACK_POST_AFTER_TS=${Y_TS} "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a thread answer that has read it" "${M2_TS}" 2>&1) \
	|| fail "check 37: a thread post written from the newest reply was refused: ${OUT}"
# a thread reply "also sent to the channel" belongs to its thread, as the inbox files it: it is not a newer
# message for a channel answer (which would be refused on every poll, for a message the channel's
# conversation never contains), and it is one for an answer in its thread
W_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+the+agent+answers+top-level" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
BC_TS=$(curl -s "${SLACK_API_BASE}/stub.seedBroadcast?thread=${M2_TS}&text=a+thread+reply+also+sent+to+the+channel" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
{ [ -n "${W_TS}" ] && [ -n "${BC_TS}" ]; } || fail "check 37: the stub did not seed the message and the broadcast"
OUT=$(SLACK_POST_ENABLED=true SLACK_POST_AFTER_TS=${W_TS} "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a channel answer written after a broadcast arrived" 2>&1)
RC=$?
[ ${RC} -eq 0 ] || fail "check 37: a channel post was refused (exit ${RC}) for a newer thread reply also sent to the channel, which the inbox files under its thread - the responder would refuse this answer on every poll: ${OUT}"
OUT=$(SLACK_POST_ENABLED=true SLACK_POST_AFTER_TS=${Y_TS} SLACK_POST_STALE_RECORD=${STALE_REC} "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a thread answer written before the broadcast reply" "${M2_TS}" 2>&1)
RC=$?
[ ${RC} -eq 3 ] || fail "check 37: a thread post written before a newer broadcast reply in that thread exited ${RC}, not 3: ${OUT}"
grep -q "^${BC_TS} U0PERSON$" "${STALE_REC}" || fail "check 37: the broadcast reply was not recorded as the newer message: $(cat "${STALE_REC}")"
# a newer top-level message that already has a reply under it (Slack then marks it with thread_ts equal to its ts) is
# still a top-level message: a channel answer written before it is refused
PT_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+newer+top-level+message+that+gets+a+reply" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${PT_TS}&text=a+reply+under+the+newer+message" > /dev/null
rm -f "${STALE_REC:?}"
OUT=$(SLACK_POST_ENABLED=true SLACK_POST_AFTER_TS=${W_TS} SLACK_POST_STALE_RECORD=${STALE_REC} "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a channel answer written before a message that has a thread" 2>&1)
RC=$?
[ ${RC} -eq 3 ] || fail "check 37: a channel post written before a newer top-level message that has a reply exited ${RC}, not 3: ${OUT}"
grep -q "^${PT_TS} U0PERSON$" "${STALE_REC}" || fail "check 37: the newer message with a thread was not the one recorded: $(cat "${STALE_REC}")"
echo "ok 37 - pre-send newest check: an answer written before a newer message is refused (exit 3, the message named and recorded) in the channel and in a thread; the agent's own posts do not count; a thread reply also sent to the channel counts in its thread, not for a channel answer; a newer top-level message that already has a thread counts"

collected_count()
{
	# collected_count <ts> - how many inbox and processed lines carry that ts
	cat ${SLACK_DIR}/inbox.jsonl ${SLACK_DIR}/processed.jsonl 2>/dev/null | grep -c "\"ts\":\"$1\""
}
# --- 25. the chat responder answers again, with the newer message, instead of posting a stale answer ---
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl   # a clean inbox
rm -f "${D:?}/loop11/STOP" "${SLACK_DIR:?}/chat.STOP"   # check 30 left the responder's stop flag
P0=$(stub_post_total)
export FAKE_PROMPT_OUT=${D}/chat38-prompt.txt
${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat38.out 2>&1 &
CHAT_PID=$!
Q_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+question+that+gets+a+follow-up+while+answered" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
for N in $(seq 1 90); do   # up to 45 s: the responder answers every message seeded since check 37 first, and the host may be loaded
	grep -q "CHAT REPLY .* kind=model ok" ${SLACK_DIR}/chat.log 2>/dev/null && [ "$(grep -c "CHAT MSG .* text=\"the follow-up that arrives" ${SLACK_DIR}/chat.log)" -ge 1 ] \
		&& [ "$(curl -s -H "Authorization: Bearer x" "${SLACK_API_BASE}/stub.state" | grep -o 'fake model reply to: the follow-up' | wc -l)" -ge 1 ] && break
	sleep 0.5
done
OUT=$(SLACK_DIR=${SLACK_DIR} "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
grep -q "CHAT STALE ts=${Q_TS} channel=C0TESTCHAN: a newer message arrived while answering" ${SLACK_DIR}/chat.log \
	|| fail "check 38: the responder did not hold back the stale answer: $(grep "${Q_TS}" ${SLACK_DIR}/chat.log | tail -5) | $(tail -5 ${SLACK_DIR}/chat.log) | $(tail -3 ${D}/chat38.out)"
# the follow-up sits in the thread the answer goes to, a thread the agent had not posted in: the refused post registered
# it for the watch, so the re-answer had the follow-up in view instead of being refused until the cap
grep -q "^${Q_TS} " ${SLACK_DIR}/threads-C0TESTCHAN || fail "check 38: the thread of the refused answer was not registered for the watch"
grep -q "CHAT STALE CAP ts=${Q_TS} " ${SLACK_DIR}/chat.log && fail "check 38: the answer reached the stale cap - the follow-up in the thread was never brought in: $(grep "ts=${Q_TS}" ${SLACK_DIR}/chat.log | tail -4)"
mapfile -d '' NEWP < <(stub_posts_since "${P0}")
printf '%s\n' "${NEWP[@]}" | grep -qx "fake model reply to: a question that gets a follow-up while answered" \
	&& fail "check 38: the answer written before the follow-up was posted anyway"
printf '%s\n' "${NEWP[@]}" | grep -qx "fake model reply to: a question that gets a follow-up while answered (with 1 newer message(s))" \
	|| fail "check 38: the question was not answered again with the follow-up in view: $(printf '%s | ' "${NEWP[@]}")"
printf '%s\n' "${NEWP[@]}" | grep -q "^fake model reply to: the follow-up that arrives while the agent answers" \
	|| fail "check 38: the follow-up itself was not answered: $(printf '%s | ' "${NEWP[@]}")"
printf '%s\n' "${NEWP[@]}" | grep -q "I could not produce an answer" && fail "check 38: a fallback line was posted for the held-back answer"
# a thread reply "also sent to the channel" arrives right after a top-level question: the question is
# answered top-level (the broadcast belongs to its thread, where it is answered too), not refused on
# every poll until someone else writes in the channel
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl
Q38_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+question+followed+by+a+broadcast" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
B38_TS=$(curl -s "${SLACK_API_BASE}/stub.seedBroadcast?thread=${M2_TS}&text=a+thread+reply+also+sent+to+the+channel+right+after" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
{ [ -n "${Q38_TS}" ] && [ -n "${B38_TS}" ]; } || fail "check 38: the stub did not seed the question and the broadcast"
rm -f "${SLACK_DIR:?}/chat.STOP"
P0=$(stub_post_total)
${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat38b.out 2>&1 &
CHAT_PID=$!
wait_for_line 20 "CHAT REPLY ts=${Q38_TS} kind=model ok posted=" ${SLACK_DIR}/chat.log \
	|| chat_fail "check 38: the question followed by a thread reply also sent to the channel was not answered in 20 s - $(grep -c "CHAT STALE ts=${Q38_TS}" ${SLACK_DIR}/chat.log) stale refusal(s) for a message the channel conversation never contains: $(grep "ts=${Q38_TS}" ${SLACK_DIR}/chat.log | tail -2)"
wait_for_line 20 "CHAT REPLY ts=${B38_TS} kind=model ok posted=" ${SLACK_DIR}/chat.log || chat_fail "check 38: the broadcast reply itself was not answered: $(tail -3 ${SLACK_DIR}/chat.log)"
grep -q "CHAT STALE ts=${Q38_TS}" ${SLACK_DIR}/chat.log && chat_fail "check 38: the channel answer was refused as stale for the broadcast: $(grep "CHAT STALE ts=${Q38_TS}" ${SLACK_DIR}/chat.log | head -1)"
[ "$(stub_post_thread "fake model reply to: a question followed by a broadcast")" = "${Q38_TS}" ] || chat_fail "check 38: the question's answer is not in the thread under it: $(stub_post_thread "fake model reply to: a question followed by a broadcast")"
[ "$(collected_count "${B38_TS}")" = "1" ] || chat_fail "check 38: the broadcast was collected $(collected_count "${B38_TS}") times - history and its thread's replies both list it, and each copy gets an answer"
sleep 3                                                               # three more polls: a second copy, if any, would be answered by now
[ "$(stub_post_thread "fake model reply to: a thread reply also sent to the channel right after")" = "${M2_TS}" ] || chat_fail "check 38: the broadcast was not answered in its thread exactly once: $(stub_post_thread "fake model reply to: a thread reply also sent to the channel right after")"
[ "$(stub_post_total)" = "$(( P0 + 2 ))" ] || chat_fail "check 38: $(( $(stub_post_total) - P0 )) posts for the question and the broadcast, not 2"
OUT=$(SLACK_DIR=${SLACK_DIR} "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
# a question followed by a top-level message that already has a reply (Slack marks such a message with
# thread_ts equal to its ts): the responder files it as top-level - another topic, not part of the thread the
# answer goes to (SLACK_REPLY_IN_THREAD) - so the question is answered once, in the thread under it, without
# the newer message in view and without a stale refusal for it; slack-post.sh re-reads that thread, the same
# conversation, so the two rules agree
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl
Q38B=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+question+followed+by+a+message+that+has+a+thread" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
Y38B=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+newer+top-level+message+with+a+thread" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${Y38B}&text=a+reply+under+the+newer+message" > /dev/null
{ [ -n "${Q38B}" ] && [ -n "${Y38B}" ]; } || fail "check 38: the stub did not seed the question and the threaded message"
rm -f "${SLACK_DIR:?}/chat.STOP"
${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat38d.out 2>&1 &
CHAT_PID=$!
wait_for_line 20 "CHAT REPLY ts=${Q38B} kind=model ok posted=" ${SLACK_DIR}/chat.log \
	|| chat_fail "check 38: the question followed by a message that has a thread was not answered in 20 s: $(grep "ts=${Q38B}" ${SLACK_DIR}/chat.log | tail -2)"
grep -q "CHAT STALE ts=${Q38B}" ${SLACK_DIR}/chat.log && chat_fail "check 38: the answer was refused as stale for a newer top-level message the responder did not put in view: $(grep "CHAT STALE ts=${Q38B}" ${SLACK_DIR}/chat.log | head -1)"
[ "$(stub_post_thread "fake model reply to: a question followed by a message that has a thread")" = "${Q38B}" ] \
	|| chat_fail "check 38: the question was not answered once, in the thread under it, without the newer top-level message in view: $(stub_post_thread "fake model reply to: a question followed by a message that has a thread")"
OUT=$(SLACK_DIR=${SLACK_DIR} "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
# the bound: a newer message the watch never brings in (a no-op watch here) refuses the answer 3 times,
# then the message is answered without the check and the log says so - the queue is never held forever
mkdir -p ${D}/state-cap
cp ${SLACK_DIR}/identity ${D}/state-cap/identity
H38_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=help" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
# the newer message sits in the thread under the question - where the answer goes and where slack-post.sh re-reads
N38_TS=$(curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${H38_TS}&text=a+newer+message+the+watch+never+brings+in" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
{ [ -n "${H38_TS}" ] && [ -n "${N38_TS}" ]; } || fail "check 38: the stub did not seed the two messages"
printf '{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"help"}\n' "${H38_TS}" > ${D}/state-cap/inbox.jsonl
P0=$(stub_post_total)
SLACK_DIR=${D}/state-cap ${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 SLACK_WATCH_BIN=/bin/true CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat38c.out 2>&1 &
CHAT_PID=$!
wait_for_line 25 "CHAT STALE CAP ts=${H38_TS} channel=C0TESTCHAN: refused 3 time(s)" ${D}/state-cap/chat.log \
	|| chat_fail "check 38: a message refused as stale for a newer message the watch never brings in was not answered without the check after 3 refusals: $(grep -c "CHAT STALE ts=${H38_TS}" ${D}/state-cap/chat.log) refusal(s) in 25 s, $(( $(stub_post_total) - P0 )) post(s)"
wait_for_line 15 "CHAT REPLY ts=${H38_TS} kind=help ok posted=" ${D}/state-cap/chat.log || chat_fail "check 38: no reply after the cap: $(tail -3 ${D}/state-cap/chat.log)"
[ "$(grep -c "CHAT STALE ts=${H38_TS}" ${D}/state-cap/chat.log)" = "3" ] || chat_fail "check 38: $(grep -c "CHAT STALE ts=${H38_TS}" ${D}/state-cap/chat.log) stale refusals before the cap, not 3"
[ "$(stub_post_total)" = "$(( P0 + 1 ))" ] || chat_fail "check 38: $(( $(stub_post_total) - P0 )) posts for the capped message, not exactly 1"
[ "$(grep -c . ${D}/state-cap/inbox.jsonl)" = "0" ] || chat_fail "check 38: the capped message is still in the inbox"
[ "$(grep -c "\"ts\":\"${H38_TS}\"" ${D}/state-cap/processed.jsonl)" = "1" ] || chat_fail "check 38: the capped message is not in processed.jsonl once"
[ -f "${D}/state-cap/chat/C0TESTCHAN-${H38_TS}.refusals" ] && chat_fail "check 38: the refusals file was not removed once the message was handled"
OUT=$(SLACK_DIR=${D}/state-cap "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
# (e) SLACK_REPLY_IN_THREAD=false: the conversation is the channel's top level - a follow-up
# that arrives TOP-LEVEL while the answer is written (the fake seeds it there, since the prompt names no reply thread)
# refuses the answer, which is written again with the follow-up in view and posted top-level; then the follow-up is
# answered top-level. Conditions relative to this part: the texts also occur in (a), in a thread. A settling watch first:
# (d) seeded messages on the stub that this state never collected (its responder ran on a private state directory)
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch38e.out 2>&1 || fail "check 38: the settling watch failed: $(tail -2 ${D}/watch38e.out)"
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl
rm -f "${SLACK_DIR:?}/chat.STOP"
S38E=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+question+that+gets+a+follow-up+while+answered+with+the+knob+off" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${S38E}" ] || fail "check 38: the stub did not seed the knob-off question"
${CHAT_ENV} SLACK_REPLY_IN_THREAD=false SLACK_CHAT_POLL_INTERVAL=1 CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat38e.out 2>&1 &
CHAT_PID=$!
wait_for_line 25 "CHAT REPLY ts=${S38E} kind=model ok posted=" ${SLACK_DIR}/chat.log \
	|| chat_fail "check 38: with SLACK_REPLY_IN_THREAD=false the question was not answered within 25 s: $(grep "ts=${S38E}" ${SLACK_DIR}/chat.log | tail -3)"
grep -q "CHAT STALE ts=${S38E} channel=C0TESTCHAN: a newer message arrived while answering" ${SLACK_DIR}/chat.log \
	|| chat_fail "check 38: with SLACK_REPLY_IN_THREAD=false a top-level follow-up did not refuse the answer: $(grep "ts=${S38E}" ${SLACK_DIR}/chat.log | tail -3)"
F38E=$(grep "CHAT STALE ts=${S38E} " ${SLACK_DIR}/chat.log | head -1 | sed -n 's/.*while answering (\([0-9.]*\) .*/\1/p')
[ -n "${F38E}" ] || chat_fail "check 38: the stale line does not name the follow-up: $(grep "CHAT STALE ts=${S38E} " ${SLACK_DIR}/chat.log | head -1)"
wait_for_line 20 "CHAT REPLY ts=${F38E} kind=model ok posted=" ${SLACK_DIR}/chat.log || chat_fail "check 38: the top-level follow-up itself was not answered: $(tail -3 ${SLACK_DIR}/chat.log)"
grep -q "CHAT MSG ts=${F38E} channel=C0TESTCHAN user=U0PERSON reply_thread=none kind=model" ${SLACK_DIR}/chat.log \
	|| chat_fail "check 38: the follow-up was not a top-level message answered top-level: $(grep "CHAT MSG ts=${F38E}" ${SLACK_DIR}/chat.log)"
[ "$(stub_post_thread "fake model reply to: a question that gets a follow-up while answered with the knob off (with 1 newer message(s))")" = "none" ] \
	|| chat_fail "check 38: with SLACK_REPLY_IN_THREAD=false the question was not answered once, top-level, with the follow-up in view: $(stub_post_thread "fake model reply to: a question that gets a follow-up while answered with the knob off (with 1 newer message(s))")"
[ "$(stub_post_thread "fake model reply to: a question that gets a follow-up while answered with the knob off")" = "posts=0" ] \
	|| chat_fail "check 38: with SLACK_REPLY_IN_THREAD=false the answer written before the top-level follow-up was posted anyway"
OUT=$(SLACK_DIR=${SLACK_DIR} "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
echo "ok 38 - chat: an answer overtaken by a follow-up in its thread is not posted; the message is answered again with the follow-up in view, then the follow-up is answered; a thread reply also sent to the channel does not stall the channel's queue; a newer top-level message that has a thread is another topic - the answer goes to the thread under its own message, not refused; after 3 refusals for a reply the watch never brings in, the answer goes out without the check (CHAT STALE CAP) - once; with SLACK_REPLY_IN_THREAD=false a top-level follow-up refuses the answer, written again with it in view, top-level"

# --- 26. a loop fire's posts carry the newest message of its batch ---
mkdir -p ${D}/loop14
echo "test goal" > ${D}/loop14/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt14.txt FAKE_ENV_OUT=${D}/env14.txt
curl -s "${SLACK_API_BASE}/stub.seedMessage?text=for+the+loop+with+a+batch" > /dev/null
Z_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=the+newest+in+the+batch" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
SLACK_CHAT_ENABLED=false SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop14 AUTONOMY_LOOP_WORKDIR=${D}/loop14 AUTONOMY_LOOP_GOALS=${D}/loop14/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once14.out 2>&1 < /dev/null || fail "check 39: loop-once exited nonzero: $(cat ${D}/once14.out)"
unset FAKE_ENV_OUT
[ "$(cat ${D}/env14.txt)" = "SLACK_POST_AFTER_TS=${Z_TS}" ] || fail "check 39: the fire's SLACK_POST_AFTER_TS is '$(cat ${D}/env14.txt)', not the newest message of its batch (${Z_TS})"
grep -q "If slack-post.sh refuses with exit 3, a newer message arrived after this inbox was read" ${D}/prompt14.txt \
	|| fail "check 39: the fire prompt does not explain the exit-3 refusal"
echo "ok 39 - a loop fire posts with SLACK_POST_AFTER_TS = the newest message of its batch, and its prompt explains the exit-3 refusal"

# --- 27. the thread parent, which every conversations.replies answer carries, is collected once ---
# Slack's conversations.replies answers with the parent first whatever oldest says, and so does the
# stub: a registered thread's parent must not come back into the inbox on every poll, where the agent
# would answer it again, and the thread's reply cursor must not move back to it.
P40=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+question+with+an+early+reply+in+its+thread" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
R40=$(curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${P40}&text=the+early+reply+under+it" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
{ [ -n "${P40}" ] && [ -n "${R40}" ]; } || fail "check 40: the stub did not seed the thread"
for N in 1 2 3 4 5 6; do
	"${AGENT_DIR}/slack-watch.sh" > ${D}/watch40-${N}.out 2>&1 || fail "check 40: watch ${N} failed: $(cat ${D}/watch40-${N}.out)"
done
[ "$(collected_count "${P40}")" = "1" ] || fail "check 40: with the parent in every conversations.replies answer, the parent was collected $(collected_count "${P40}") times in six watches, not once - the agent would answer it again on every poll"
[ "$(collected_count "${R40}")" = "1" ] || fail "check 40: the early reply was collected $(collected_count "${R40}") times in six watches, not once"
grep -qE "^${P40} ${R40}( [0-9]+)?$" ${SLACK_DIR}/threads-C0TESTCHAN || fail "check 40: the thread's reply cursor is not its newest reply ${R40}: $(grep "^${P40} " ${SLACK_DIR}/threads-C0TESTCHAN)"
echo "ok 40 - the thread parent that every conversations.replies answer carries is collected once in six watches, its reply once, and the thread's cursor stays at the reply"

# --- 28. a person goes on in a thread under their own top-level message: collected, for a while ---
# The agent answers a top-level message top-level; the person may then reply in a thread under their
# own message (a chain scenario of the end-to-end test). The watcher saw that message with no replies and its cursor
# is past it, so it lists each person's new top-level message for the same bounded watch as the
# agent's posts (2 h, the newest 5, at most every SLACK_ANSWER_POLL_INTERVAL seconds).
Q41=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=can+you+check+the+deploy+status" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${Q41}" ] || fail "check 41: the stub did not seed the top-level message"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch41a.out 2>&1 || fail "check 41: watch failed: $(cat ${D}/watch41a.out)"
grep -q "^${Q41} " ${SLACK_DIR}/threads-C0TESTCHAN && fail "check 41: precondition - the message's thread is registered before it has a reply"
A41=$(post_ts "the agent's answer to the deploy question, top-level")
[ -n "${A41}" ] || fail "check 41: the agent's top-level answer failed"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch41b.out 2>&1 || fail "check 41: watch failed: $(cat ${D}/watch41b.out)"
grep -q "^${A41} " ${SLACK_DIR}/asks-C0TESTCHAN 2>/dev/null && fail "check 41: the agent's own post is listed as a person's message"
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${Q41}&text=one+more+thing+could+you+also+check+the+alarms" > /dev/null
SLACK_ANSWER_POLL_INTERVAL=0 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch41c.out 2>&1 || fail "check 41: watch failed: $(cat ${D}/watch41c.out)"
grep "could you also check the alarms" ${SLACK_DIR}/inbox.jsonl | grep -q "\"thread_ts\":\"${Q41}\"" \
	|| fail "check 41: the reply in the thread under the person's own top-level message was never collected - thread ${Q41} is not watched ($(tail -2 ${D}/watch41c.out | tr '\n' ' '))"
grep -q "^${Q41} " ${SLACK_DIR}/threads-C0TESTCHAN || fail "check 41: the message with a reply did not move to the thread registry"
grep -q "^${Q41} " ${SLACK_DIR}/asks-C0TESTCHAN && fail "check 41: the message with a reply is still listed for the slow watch"
SLACK_ANSWER_POLL_INTERVAL=0 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch41d.out 2>&1 || fail "check 41: watch failed"
[ "$(grep -c "could you also check the alarms" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 41: the reply was collected more than once"
# expiry: a message no longer watched is not checked again
E41=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+watched+for+1+s" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
SLACK_ANSWER_WATCH_SECONDS=1 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch41e.out 2>&1 || fail "check 41: watch failed"
grep -q "^${E41} " ${SLACK_DIR}/asks-C0TESTCHAN || fail "check 41: a person's new top-level message is not listed for the slow watch"
sleep 2
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${E41}&text=a+late+reply+under+the+expired+message" > /dev/null
SLACK_ANSWER_POLL_INTERVAL=0 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch41f.out 2>&1 || fail "check 41: watch failed"
grep -q "a late reply under the expired message" ${SLACK_DIR}/inbox.jsonl && fail "check 41: a message past its watch expiry was still checked"
# the bound: at most 5 listed, the newest
for N in 1 2 3 4 5 6; do LAST41=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=question+number+${N}" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p'); done
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch41g.out 2>&1 || fail "check 41: watch failed"
[ "$(grep -c . ${SLACK_DIR}/asks-C0TESTCHAN)" = "5" ] || fail "check 41: $(grep -c . ${SLACK_DIR}/asks-C0TESTCHAN) messages listed, not the newest 5"
grep -q "^${LAST41} " ${SLACK_DIR}/asks-C0TESTCHAN || fail "check 41: the newest message is not listed"
echo "ok 41 - a reply in the thread under a person's own top-level message is collected once and its thread joins the registry; the agent's posts are not listed as the person's; for 2 h, the newest 5"

# --- 29. a post that fails after a part landed is never sent again; a rate-limited part is retried once in place ---
# post_reply (slack-chat.sh) used to run slack-post.sh again with the whole text after any failure with a
# retry-after file present: parts already on the platform went out twice. Now slack-post.sh retries a
# rate-limited part once after Retry-After (Slack posted nothing for a 429), exits 4 when anything landed
# but the post did not complete, and records each landed part's ts in SLACK_POST_RECORD; post_reply
# retries only a run that posted nothing and never a run that exited 4.
sed -n '/^pause()$/,/^}$/p; /^rate_limit_pause()$/,/^}$/p; /^post_reply()$/,/^}$/p' "${AGENT_DIR}/slack-chat.sh" > ${D}/post_reply.sh
[ "$(grep -cE '^(pause|rate_limit_pause|post_reply)\(\)$' ${D}/post_reply.sh)" = "3" ] || fail "check 42: could not extract pause, rate_limit_pause and post_reply from slack-chat.sh"
run_post_reply()
{
	# run_post_reply <text> - slack-chat.sh's post_reply, its real function body, in a subshell with the
	# globals it uses; prints its output, exits with its status
	# shellcheck disable=SC2034,SC2317,SC1091 # the variables and log() are used by post_reply, sourced at run time from the file extracted above
	( SLACK_POST_BIN="${AGENT_DIR}/slack-post.sh"; RETRY_AFTER_FILE=${SLACK_DIR}/retry-after; STOP_FLAG=${D}/none.STOP
	  TRANSCRIPTS=${D}/pr42; mkdir -p "${TRANSCRIPTS}"; M_CH=C0TESTCHAN; M_TS=$2
	  log() { echo "LOG $*"; }
	  . ${D}/post_reply.sh
	  SLACK_POST_ENABLED=true post_reply C0TESTCHAN "" "$1" )
}
rm -f "${SLACK_DIR:?}/retry-after"
# (a) a 429 on part 2: the part is retried after Retry-After, every part lands once
P0=$(stub_post_total)
curl -s "${SLACK_API_BASE}/stub.failPosts?calls=2" > /dev/null
OUT=$(run_post_reply "${LONG}" 1.000001); RC=$?
[ ${RC} -eq 0 ] || fail "check 42: post_reply with a 429 on part 2 exited ${RC}: ${OUT}"
[ "$(stub_post_total)" = "$(( P0 + 3 ))" ] || fail "check 42: a 429 on part 2 left $(( $(stub_post_total) - P0 )) messages on the platform, not 3 - a part went out twice"
mapfile -d '' GOT42 < <(stub_posts_since "${P0}")
[ "$(printf '%s\n' "${GOT42[@]}")" = "${LONG}" ] || fail "check 42: the three messages on the platform after a 429 on part 2, joined, are not the text - a part is missing or doubled"
# (b) a part rate limited twice: nothing is sent again - exit 4, the landed part recorded, one copy of it
P0=$(stub_post_total)
curl -s "${SLACK_API_BASE}/stub.failPosts?calls=2,3" > /dev/null
REC42=${D:?}/rec42.txt; rm -f "${REC42:?}"
OUT=$(SLACK_POST_ENABLED=true SLACK_POST_RECORD=${REC42} "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "${LONG}" 2>&1); RC=$?
[ ${RC} -eq 4 ] || fail "check 42: slack-post.sh with part 2 rate limited twice exited ${RC}, not 4 (part 1 landed): $(echo "${OUT}" | tail -2)"
echo "${OUT}" | grep -q "do not post this text again" || fail "check 42: the exit-4 message does not say not to post again: $(echo "${OUT}" | tail -2)"
[ "$(stub_post_total)" = "$(( P0 + 1 ))" ] || fail "check 42: $(( $(stub_post_total) - P0 )) messages landed with part 2 failing twice, not 1"
[ "$(grep -c . ${REC42})" = "1" ] || fail "check 42: SLACK_POST_RECORD holds $(grep -c . ${REC42} 2>/dev/null) ts, not the one landed part"
grep -qx "$(stub_last_post ts)" ${REC42} || fail "check 42: SLACK_POST_RECORD does not hold the landed part's ts: $(cat ${REC42})"
P0=$(stub_post_total)
curl -s "${SLACK_API_BASE}/stub.failPosts?calls=2,3" > /dev/null
OUT=$(run_post_reply "${LONG}" 1.000002); RC=$?
[ ${RC} -eq 4 ] || fail "check 42: post_reply after a run that landed part 1 exited ${RC}, not 4: ${OUT}"
[ "$(stub_post_total)" = "$(( P0 + 1 ))" ] || fail "check 42: post_reply sent the text again after a run that had landed part 1: $(( $(stub_post_total) - P0 )) messages, not 1"
mapfile -d '' GOT42 < <(stub_posts_since "${P0}")
{ [ "${LONG#"${GOT42[0]}"}" != "${LONG}" ] && [ "${#GOT42[0]}" -lt "${#LONG}" ]; } || fail "check 42: the one message landed by the failed run is not the first part of the text"
# (c) a landed post whose read-back fails, with a retry-after file present: not sent again
P0=$(stub_post_total)
echo 1 > ${SLACK_DIR}/retry-after
curl -s "${SLACK_API_BASE}/stub.alterNext?mode=truncate" > /dev/null
OUT=$(run_post_reply "a post the platform stores truncated, with a rate limit on record" 1.000003); RC=$?
[ ${RC} -eq 4 ] || fail "check 42: post_reply for a landed post with a failed read-back exited ${RC}, not 4: ${OUT}"
[ "$(stub_post_total)" = "$(( P0 + 1 ))" ] || fail "check 42: a landed post with a failed read-back was sent $(( $(stub_post_total) - P0 )) times, not once"
# (d) a run that posted nothing (part 1 rate limited twice) is retried by post_reply, once
P0=$(stub_post_total)
curl -s "${SLACK_API_BASE}/stub.failPosts?calls=1,2" > /dev/null
OUT=$(run_post_reply "a short reply whose first attempt is rate limited" 1.000004); RC=$?
[ ${RC} -eq 0 ] || fail "check 42: post_reply after a run that posted nothing exited ${RC}: ${OUT}"
[ "$(stub_post_total)" = "$(( P0 + 1 ))" ] || fail "check 42: the retried short reply landed $(( $(stub_post_total) - P0 )) times, not once"
echo "${OUT}" | grep -q "CHAT RATE LIMITED" || fail "check 42: post_reply did not pause for the rate limit before retrying: ${OUT}"
# (e) a post the platform accepted whose response was lost (the connection closed with no reply), with a stale
# retry-after file present: it may have landed, so slack-post.sh exits 5 and post_reply never sends it again
P0=$(stub_post_total)
echo 1 > ${SLACK_DIR}/retry-after
curl -s "${SLACK_API_BASE}/stub.failPosts?calls=1&mode=drop" > /dev/null
OUT=$(run_post_reply "a reply whose response is lost after the platform accepted it" 1.000005); RC=$?
[ ${RC} -eq 5 ] || fail "check 42: post_reply for a post whose response was lost exited ${RC}, not 5: ${OUT}"
echo "${OUT}" | grep -q "whether it landed is unknown - do not post this text again" || fail "check 42: the lost-response error does not say the post may have landed: ${OUT}"
[ "$(stub_post_total)" = "$(( P0 + 1 ))" ] || fail "check 42: a post whose response was lost is on the platform $(( $(stub_post_total) - P0 )) times, not once - it was sent again on a stale retry-after file"
# (f) a failure before anything was sent (no connection) exits 1, which post_reply may retry when a rate limit is on record
echo 1 > ${SLACK_DIR}/retry-after
OUT=$(SLACK_API_BASE=http://127.0.0.1:1/api SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "a reply to a port nothing listens on" 2>&1); RC=$?
[ ${RC} -eq 1 ] || fail "check 42: a connection failure before anything was sent exited ${RC}, not 1: $(echo "${OUT}" | tail -1)"
echo "${OUT}" | grep -q "failed before anything was sent (curl exit 7)" || fail "check 42: the connection failure is not reported as sent nothing: $(echo "${OUT}" | tail -1)"
rm -f "${SLACK_DIR:?}/retry-after"
# (g) the model path: the model's own post loses its response (exit 5) and the model then prints its answer, as a
# model does; the responder posts no fallback, since the answer may be on the platform - one copy at most
mkdir -p ${D}/state-m5
cp ${SLACK_DIR}/identity ${D}/state-m5/identity
M5_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+question+whose+answer+response+is+lost" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${M5_TS}" ] || fail "check 42: the stub did not seed the model-path message"
printf '{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"a question whose answer response is lost"}\n' "${M5_TS}" > ${D}/state-m5/inbox.jsonl
P0=$(stub_post_total)
curl -s "${SLACK_API_BASE}/stub.failPosts?calls=1&mode=drop" > /dev/null
export FAKE_PROMPT_OUT=${D}/chat42g-prompt.txt
SLACK_DIR=${D}/state-m5 ${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 SLACK_WATCH_BIN=/bin/true CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat42g.out 2>&1 &
CHAT_PID=$!
wait_for_line 20 "CHAT REPLY ts=${M5_TS} kind=model UNKNOWN" ${D}/state-m5/chat.log \
	|| chat_fail "check 42: the responder did not treat the model's lost-response post as unknown: $(grep "ts=${M5_TS}" ${D}/state-m5/chat.log | tail -2)"
grep -qE "CHAT MODEL ts=${M5_TS} rc=0 .* posted=unknown" ${D}/state-m5/chat.log || chat_fail "check 42: the MODEL line does not say posted=unknown: $(grep "CHAT MODEL ts=${M5_TS}" ${D}/state-m5/chat.log)"
sleep 3                                                               # a fallback, if any, would be posted by now
grep -q "kind=model-fallback" ${D}/state-m5/chat.log && chat_fail "check 42: a fallback was posted after the model's post lost its response: $(grep 'fallback' ${D}/state-m5/chat.log | head -1)"
[ "$(stub_post_total)" = "$(( P0 + 1 ))" ] || chat_fail "check 42: the model's answer is on the platform $(( $(stub_post_total) - P0 )) times after its response was lost, not once"
[ "$(stub_post_thread "fake model reply to: a question whose answer response is lost")" = "${M5_TS}" ] || chat_fail "check 42: the model's answer was not posted exactly once, in the thread under the message: $(stub_post_thread "fake model reply to: a question whose answer response is lost")"
[ "$(grep -c . ${D}/state-m5/inbox.jsonl)" = "0" ] || chat_fail "check 42: the message stayed in the inbox after the unknown post"
OUT=$(SLACK_DIR=${D}/state-m5 "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
# the prompts tell the model what exit 4 and exit 5 mean
grep -q "exits 4" ${D}/chat-prompt.txt || fail "check 42: the chat prompt does not explain exit 4 (part of the message already posted)"
grep -q "exits 4" ${D}/prompt14.txt || fail "check 42: the loop prompt does not explain exit 4 (part of the message already posted)"
grep -q "exits 5 it may be" ${D}/chat-prompt.txt || fail "check 42: the chat prompt does not explain exit 5 (the post may have landed)"
grep -q "exits 5 it may be" ${D}/prompt14.txt || fail "check 42: the loop prompt does not explain exit 5 (the post may have landed)"
echo "ok 42 - a rate-limited part is retried once in place and lands once; after a part has landed a failure exits 4 with the landed ts recorded and post_reply never sends the text again (a 429 twice, a failed read-back); a run that posted nothing is retried once; a post whose response was lost exits 5 and is never sent again, by post_reply or as the model path's fallback; a failure before anything was sent exits 1; both prompts explain exits 4 and 5"

# --- 30. a failed conversations.replies call loses no channel message ---
# The cursor used to advance as soon as history was read, before the thread registry and the answers/asks
# lists were polled; a failure there (a 429, a timeout) ended the run with the cursor past messages that
# never reached the inbox, and no later run could see them. The cursor now advances only after the inbox
# append, so the next run brings the same history again - exactly once, since the failed run appended nothing.
X43_TS=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+question+that+arrives+just+before+a+rate-limited+replies+call" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${X43_TS}" ] || fail "check 43: the stub did not seed the message"
[ "$(grep -c . ${SLACK_DIR}/threads-C0TESTCHAN)" -gt 0 ] || fail "check 43: precondition - no registered thread, so no conversations.replies call would follow history"
CUR43=$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)
curl -s "${SLACK_API_BASE}/stub.ratelimitReplies?n=1" > /dev/null
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch43a.out 2>&1 && fail "check 43: the watch exited 0 with a rate-limited conversations.replies call: $(cat ${D}/watch43a.out)"
grep -q "HTTP 429" ${D}/watch43a.out || fail "check 43: the failed watch does not report the 429: $(tail -2 ${D}/watch43a.out)"
[ "$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)" = "${CUR43}" ] \
	|| fail "check 43: the failed watch advanced the channel cursor (${CUR43} -> $(cat ${SLACK_DIR}/cursor-C0TESTCHAN)) with the message it brought not in the inbox - no later watch can collect it"
grep -q "\"ts\":\"${X43_TS}\"" ${SLACK_DIR}/inbox.jsonl && fail "check 43: the failed watch appended the message, which the next watch would bring again"
SLACK_ANSWER_POLL_INTERVAL=0 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch43b.out 2>&1 || fail "check 43: the next watch failed: $(cat ${D}/watch43b.out)"
[ "$(grep -c "\"ts\":\"${X43_TS}\"" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 43: the message is in the inbox $(grep -c "\"ts\":\"${X43_TS}\"" ${SLACK_DIR}/inbox.jsonl) times after the next watch, not exactly once"
[ "$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)" = "${X43_TS}" ] || fail "check 43: the cursor did not advance to the collected message: $(cat ${SLACK_DIR}/cursor-C0TESTCHAN)"
rm -f "${SLACK_DIR:?}/retry-after"
echo "ok 43 - a conversations.replies call that fails leaves the channel cursor where it was, and the message history brought in that run reaches the inbox exactly once on the next watch"

# --- 31. one rolling budget of conversations.replies calls, the least recently polled threads first ---
# Slack allows about 50 conversations.replies calls a minute per app and workspace; the chat responder
# runs the watch every few seconds, and every registered thread used to be polled on every run.
stub_replies_calls()
{
	curl -s -H "Authorization: Bearer x" "${SLACK_API_BASE}/stub.state" | "${NODE_BIN}" -e '
let raw=""; process.stdin.on("data",d=>raw+=d); process.stdin.on("end",()=>console.log(JSON.parse(raw).replies_calls));'
}
newest_polled()
{
	# newest_polled - the registered threads whose last-poll stamp (third field) is the newest one, sorted
	awk 'NF >= 3 && $3 > m { m = $3 } { l[NR] = $0 } END { for (i = 1; i <= NR; i++) { split(l[i], f, " "); if (f[3] == m) print f[1] } }' ${SLACK_DIR}/threads-C0TESTCHAN | sort
}
N44=$(grep -c . ${SLACK_DIR}/threads-C0TESTCHAN)
[ "${N44}" -ge 6 ] || fail "check 44: precondition - ${N44} registered threads, fewer than 6"
rm -f "${SLACK_DIR:?}/replies-calls"
# the first run with a budget of 3: exactly 3 calls, 3 threads stamped, the rest deferred and said so
R0=$(stub_replies_calls)
SLACK_REPLIES_BUDGET=3 SLACK_REPLIES_WINDOW=60 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch44a.out 2>&1 || fail "check 44: watch failed: $(cat ${D}/watch44a.out)"
[ "$(( $(stub_replies_calls) - R0 ))" = "3" ] || fail "check 44: a watch over ${N44} registered threads with a budget of 3 made $(( $(stub_replies_calls) - R0 )) conversations.replies calls, not exactly 3"
grep -q "^Deferred $(( N44 - 3 )) conversations.replies call(s) to a later run: the budget of 3 per 60s is used up" ${D}/watch44a.out \
	|| fail "check 44: the run does not say it deferred $(( N44 - 3 )) calls for the budget: $(grep -i deferred ${D}/watch44a.out)"
POLLED44A=$(newest_polled)
[ "$(echo "${POLLED44A}" | grep -c .)" = "3" ] || fail "check 44: $(echo "${POLLED44A}" | grep -c .) threads carry the newest last-poll stamp after the first budgeted run, not the 3 it polled"
[ "$(grep -c . ${SLACK_DIR}/replies-calls)" = "3" ] || fail "check 44: the ledger holds $(grep -c . ${SLACK_DIR}/replies-calls) calls, not 3"
# a run right after, in the same window: the budget is used up, no call
R1=$(stub_replies_calls)
SLACK_REPLIES_BUDGET=3 SLACK_REPLIES_WINDOW=60 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch44b.out 2>&1 || fail "check 44: watch failed: $(cat ${D}/watch44b.out)"
[ "$(( $(stub_replies_calls) - R1 ))" = "0" ] || fail "check 44: a run within the window of a used-up budget made $(( $(stub_replies_calls) - R1 )) calls, not 0"
grep -q "^Deferred ${N44} conversations.replies call(s)" ${D}/watch44b.out || fail "check 44: the second run does not say it deferred all ${N44}: $(grep -i deferred ${D}/watch44b.out)"
# the next window: the 3 threads the first run did not poll go first (least recently polled), and a reply
# seeded in one of them is collected then, once
UNPOLLED44=$(awk 'NF >= 3 { print $3, $1 }' ${SLACK_DIR}/threads-C0TESTCHAN | sort -n | head -1 | cut -d' ' -f2)
echo "${POLLED44A}" | grep -qx "${UNPOLLED44}" && fail "check 44: the least recently polled thread ${UNPOLLED44} was polled by the first budgeted run"
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${UNPOLLED44}&text=a+reply+in+a+thread+the+budget+deferred" > /dev/null
sleep 2
R2=$(stub_replies_calls)
SLACK_REPLIES_BUDGET=3 SLACK_REPLIES_WINDOW=1 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch44c.out 2>&1 || fail "check 44: watch failed: $(cat ${D}/watch44c.out)"
[ "$(( $(stub_replies_calls) - R2 ))" = "3" ] || fail "check 44: the next window's run made $(( $(stub_replies_calls) - R2 )) calls, not 3"
POLLED44C=$(newest_polled)
[ "$(echo "${POLLED44C}" | grep -c .)" = "3" ] || fail "check 44: $(echo "${POLLED44C}" | grep -c .) threads carry the newest stamp after the next window's run, not 3"
[ -z "$(comm -12 <(echo "${POLLED44A}") <(echo "${POLLED44C}"))" ] || fail "check 44: the next window's run polled a thread the first run had just polled ($(comm -12 <(echo "${POLLED44A}") <(echo "${POLLED44C}") | tr '
' ' ')) - the least recently polled did not go first"
[ "$(grep -c "a reply in a thread the budget deferred" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 44: the reply in the deferred thread is in the inbox $(grep -c "a reply in a thread the budget deferred" ${SLACK_DIR}/inbox.jsonl) times after its thread's turn, not once"
rm -f "${SLACK_DIR:?}/replies-calls"
echo "ok 44 - one rolling conversations.replies budget: ${N44} threads with a budget of 3 get exactly 3 calls and the run says it deferred the rest; none in the same window; the other 3 in the next window, least recently polled first, a reply there collected once"

# --- 32. a fire that left its batch unanswered carries it into the next fire, marked; nothing is processed unanswered ---
# The fire's whole batch moved to processed.jsonl after the fire, whatever happened: a message whose answer
# was refused as stale (a newer one arrived during the fire, which can take minutes) or whose fire timed
# out was never answered and never seen again.
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl   # a clean inbox
loop_once_fire()
{
	# loop_once_fire <loop dir> <prompt out> - one loop-once.sh fire with the posting fake and the chat gate off
	# SLACK_ANSWER_POLL_INTERVAL=0: the fire's reply goes in the thread under the person's message (SLACK_REPLY_IN_THREAD),
	# and so does the follow-up the fake seeds while the fire runs; the watch collects a reply threaded under a person's
	# new top-level message within SLACK_ANSWER_POLL_INTERVAL (section 8 of the docs; 60 s by default, every watch here)
	FAKE_PROMPT_OUT=$2 FAKE_LOOP_POST=1 SLACK_POST_ENABLED=true SLACK_CHAT_ENABLED=false SLACK_ANSWER_POLL_INTERVAL=0 SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
		AUTONOMY_LOOP_DIR=$1 AUTONOMY_LOOP_WORKDIR=$1 AUTONOMY_LOOP_GOALS=$1/GOALS.md \
		"${AGENT_DIR}/loop-once.sh" > "$1/once.out" 2>&1 < /dev/null
}
processed_count()
{
	# processed_count <ts> - lines of processed.jsonl with that ts
	grep -c "\"ts\":\"$1\"" ${SLACK_DIR}/processed.jsonl 2>/dev/null || true
}
# (a) a stale refusal: the message stays, comes back CARRIED, is answered once with the follow-up in view
mkdir -p ${D}/loop15
echo "test goal" > ${D}/loop15/GOALS.md
M45=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+question+that+gets+a+follow-up+while+the+loop+fires" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${M45}" ] || fail "check 45: the stub did not seed the message"
loop_once_fire ${D}/loop15 ${D}/prompt15a.txt || fail "check 45: fire 1 exited nonzero: $(tail -3 ${D}/loop15/once.out)"
grep -q "FIRE 1 SLACK carried=1: its answer was refused as stale" ${D}/loop15/loop.log \
	|| fail "check 45: the fire whose answer was refused did not carry its batch: $(grep 'FIRE 1 SLACK' ${D}/loop15/loop.log)"
[ "$(processed_count "${M45}")" = "0" ] || fail "check 45: the message whose answer was refused as stale went to processed.jsonl unanswered"
head -1 ${SLACK_DIR}/inbox.jsonl | grep -q "\"ts\":\"${M45}\"" || fail "check 45: the carried message is not first in the inbox"
[ "$(cat ${D}/loop15/slack-carried)" = "${M45}" ] || fail "check 45: slack-carried does not name the message: $(cat ${D}/loop15/slack-carried 2>/dev/null)"
loop_once_fire ${D}/loop15 ${D}/prompt15b.txt || fail "check 45: fire 2 exited nonzero: $(tail -3 ${D}/loop15/once.out)"
grep -q "^CARRIED {\"ts\":\"${M45}\"" ${D}/prompt15b.txt || fail "check 45: the next fire's prompt does not mark the carried message: $(grep -c '^{' ${D}/prompt15b.txt) plain lines"
grep -q "^CARRIED: the 1 message(s) marked CARRIED below were handed to the previous fire" ${D}/prompt15b.txt || fail "check 45: the next fire's prompt has no carry note"
grep -q "^  none$" ${D}/prompt15b.txt || fail "check 45: the carry note does not say the previous fire landed no post: $(grep -A1 'not to be repeated' ${D}/prompt15b.txt | tail -1)"
grep -q "a follow-up that arrives while the loop fires" ${D}/prompt15b.txt || fail "check 45: the follow-up is not in the next fire's prompt"
grep -q "FIRE 2 SLACK processed=2" ${D}/loop15/loop.log || fail "check 45: fire 2 did not process the carried message and the follow-up: $(grep 'FIRE 2 SLACK' ${D}/loop15/loop.log)"
[ "$(stub_post_thread "fake loop reply to: a question that gets a follow-up while the loop fires")" = "${M45}" ] \
	|| fail "check 45: the carried message was not answered exactly once, in the thread under it: $(stub_post_thread "fake loop reply to: a question that gets a follow-up while the loop fires")"
[ "$(processed_count "${M45}")" = "1" ] || fail "check 45: the carried message is in processed.jsonl $(processed_count "${M45}") times after it was answered, not once"
[ ! -f ${D}/loop15/slack-carried ] || fail "check 45: slack-carried remains after the batch was processed"
# (b) a fire that times out, in loop.sh: the batch is carried too, and answered by the next fire
mkdir -p ${D}/loop16
echo "test goal" > ${D}/loop16/GOALS.md
T45=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+during+which+the+fire+sleeps+past+the+fire+timeout" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${T45}" ] || fail "check 45: the stub did not seed the timeout message"
export FAKE_PROMPT_OUT=${D}/prompt16.txt
FAKE_LOOP_POST=1 SLACK_POST_ENABLED=true SLACK_CHAT_ENABLED=false SLACK_WATCH_BIN="${AGENT_DIR}/slack-watch.sh" CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop16 AUTONOMY_LOOP_WORKDIR=${D}/loop16 AUTONOMY_LOOP_GOALS=${D}/loop16/GOALS.md \
	AUTONOMY_LOOP_INTERVAL=2 AUTONOMY_LOOP_FIRE_TIMEOUT=3 \
	"${AGENT_DIR}/loop.sh" > ${D}/loop16.out 2>&1 &
LOOP_PID=$!
wait_for_line 30 "FIRE 1 END rc=124" ${D}/loop16/loop.log || loop_fail "check 45: fire 1 did not time out (rc 124) within 30s: $(cat ${D}/loop16/loop.log)"
wait_for_line 10 "FIRE 1 SLACK carried=" ${D}/loop16/loop.log || loop_fail "check 45: no carry line after the timed-out fire: $(grep 'FIRE 1 SLACK' ${D}/loop16/loop.log)"
grep -q "FIRE 1 SLACK carried=[0-9]*: it timed out after 3s" ${D}/loop16/loop.log || loop_fail "check 45: the timed-out fire did not carry its batch: $(grep 'FIRE 1 SLACK' ${D}/loop16/loop.log)"
[ "$(processed_count "${T45}")" = "0" ] || loop_fail "check 45: the message of the timed-out fire went to processed.jsonl unanswered"
wait_for_line 30 "FIRE 2 SLACK processed=" ${D}/loop16/loop.log || loop_fail "check 45: fire 2 did not process the carried batch: $(cat ${D}/loop16/loop.log)"
grep -q "^CARRIED {\"ts\":\"${T45}\"" ${D}/prompt16.txt || loop_fail "check 45: fire 2's prompt does not mark the carried message"
[ "$(stub_post_thread "fake loop reply to: a message during which the fire sleeps past the fire timeout")" = "${T45}" ] \
	|| loop_fail "check 45: the message of the timed-out fire was not answered exactly once by the next, in the thread under it: $(stub_post_thread "fake loop reply to: a message during which the fire sleeps past the fire timeout")"
[ "$(processed_count "${T45}")" = "1" ] || loop_fail "check 45: the message is in processed.jsonl $(processed_count "${T45}") times after fire 2, not once"
touch ${D}/loop16/STOP
wait_for_line 20 "STOPPED reason=stop-flag" ${D}/loop16/loop.state || loop_fail "check 45: loop.sh did not stop on the STOP flag"
wait "${LOOP_PID}" 2>/dev/null; LOOP_PID=""
# (c) the bound: a message refused on three fires is answered by the fourth without the newest check, and then
# processed; each follow-up that arrived meanwhile is answered once
mkdir -p ${D}/loop17
echo "test goal" > ${D}/loop17/GOALS.md
A45=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+that+always+gets+a+follow-up+while+the+loop+fires" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
P0=$(stub_post_total)
for N in 1 2 3; do
	loop_once_fire ${D}/loop17 ${D}/prompt17-${N}.txt || fail "check 45: bound fire ${N} exited nonzero: $(tail -3 ${D}/loop17/once.out)"
	grep -q "FIRE ${N} SLACK carried=[0-9]*: its answer was refused as stale .* (carry ${N} of 3)" ${D}/loop17/loop.log \
		|| fail "check 45: fire ${N} did not carry as expected: $(grep "FIRE ${N} SLACK" ${D}/loop17/loop.log)"
done
[ "$(( $(stub_post_total) - P0 ))" = "0" ] || fail "check 45: $(( $(stub_post_total) - P0 )) post(s) landed over three refused fires, not 0"
loop_once_fire ${D}/loop17 ${D}/prompt17-4.txt || fail "check 45: the fourth fire exited nonzero: $(tail -3 ${D}/loop17/once.out)"
grep -q "FIRE 4 SLACK the batch was carried 3 time(s), the bound: this fire posts without the newest-message check" ${D}/loop17/loop.log \
	|| fail "check 45: the fourth fire did not run unchecked at the bound: $(grep 'FIRE 4 SLACK' ${D}/loop17/loop.log)"
grep -q "FIRE 4 SLACK processed=[0-9]*" ${D}/loop17/loop.log || fail "check 45: the fourth fire did not process its batch: $(grep 'FIRE 4 SLACK' ${D}/loop17/loop.log)"
[ "$(grep -c . ${SLACK_DIR}/inbox.jsonl)" -le 1 ] || fail "check 45: after the fourth fire the inbox still holds $(grep -c . ${SLACK_DIR}/inbox.jsonl) line(s) (at most the follow-up seeded during it)"
[ "$(stub_post_thread "fake loop reply to: a message that always gets a follow-up while the loop fires")" = "${A45}" ] \
	|| fail "check 45: the always-refused message was not answered exactly once at the bound, in the thread under it: $(stub_post_thread "fake loop reply to: a message that always gets a follow-up while the loop fires")"
[ "$(( $(stub_post_total) - P0 ))" = "4" ] || fail "check 45: $(( $(stub_post_total) - P0 )) posts at the bound, not 4 (the message and its three follow-ups, once each)"
[ "$(processed_count "${A45}")" = "1" ] || fail "check 45: the message is in processed.jsonl $(processed_count "${A45}") times, not once"
echo "ok 45 - a fire whose answer was refused as stale, or that timed out, carries its batch into the next fire marked CARRIED and nothing reaches processed.jsonl unanswered; the carried message is answered once; after 3 carries the next fire posts without the check and the batch is processed"

# --- 33. a long top-level post: every part watched for a threaded reply; a code block split re-fenced ---
P0=$(stub_post_total)
FENCED=$(printf '%s\n' '```'; for N in $(seq 1 100); do printf 'line %03d of a long status from the agent, padded out to about seventy chars\n' "${N}"; done; printf '%s' '```')
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "${FENCED}" 2>&1) || fail "check 46: the fenced long post failed: $(echo "${OUT}" | tail -1)"
N46=$(echo "${OUT}" | grep -c '^Posted and read-back verified: .* (part [0-9] of [0-9])$')
[ "${N46}" -ge 3 ] || fail "check 46: the fenced long post went out as ${N46} parts, fewer than 3: ${OUT}"
mapfile -d '' FPARTS < <(stub_posts_since "${P0}")
[ "${#FPARTS[@]}" = "${N46}" ] || fail "check 46: the stub holds ${#FPARTS[@]} messages for the ${N46}-part post"
for FP in "${FPARTS[@]}"; do
	[ "${#FP}" -le 3500 ] || fail "check 46: a re-fenced part has ${#FP} characters, above 3500"
	FENCES=$(printf '%s\n' "${FP}" | grep -c '^```')
	{ [ $(( FENCES % 2 )) -eq 0 ] && [ "${FENCES}" -ge 2 ]; } || fail "check 46: a part of a split code block has ${FENCES} fence line(s), not an even number of at least 2 - it renders as broken code: $(printf '%s' "${FP}" | head -c 60)..."
	printf '%s' "${FP}" | head -1 | grep -q '^```' || fail "check 46: a part does not open with a fence: $(printf '%s' "${FP}" | head -c 40)"
	printf '%s' "${FP}" | tail -1 | grep -q '^```$' || fail "check 46: a part does not close its fence: ...$(printf '%s' "${FP}" | tail -c 40)"
done
REJOINED=$(for FP in "${FPARTS[@]}"; do printf '%s\n' "${FP}" | sed -e '1{/^```$/d}' -e '${/^```$/d}'; done)
[ "${REJOINED}" = "$(printf '%s\n' "${FENCED}" | sed -e '1{/^```$/d}' -e '${/^```$/d}')" ] || fail "check 46: the parts without their added fences do not rejoin to the text"
# every part of a top-level post is listed for the answer watch, so a reply under any of them is collected
LISTED46=0
for FP_TS in $(echo "${OUT}" | sed -n 's/^Posted and read-back verified: channel=C0TESTCHAN ts=\([0-9.]*\) (part .*/\1/p'); do
	grep -q "^${FP_TS} " ${SLACK_DIR}/answers-C0TESTCHAN && LISTED46=$((LISTED46 + 1))
done
[ "${LISTED46}" = "${N46}" ] || fail "check 46: ${LISTED46} of the ${N46} parts of a top-level post are listed for the answer watch, not all - a reply threaded under an unlisted part is never collected"
FIRST46=$(echo "${OUT}" | sed -n 's/^Posted and read-back verified: channel=C0TESTCHAN ts=\([0-9.]*\) (part 1 of .*/\1/p')
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${FIRST46}&text=a+reply+threaded+under+the+first+part" > /dev/null
SLACK_ANSWER_POLL_INTERVAL=0 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch46.out 2>&1 || fail "check 46: watch failed: $(cat ${D}/watch46.out)"
grep "a reply threaded under the first part" ${SLACK_DIR}/inbox.jsonl | grep -q "\"thread_ts\":\"${FIRST46}\"" \
	|| fail "check 46: the reply threaded under part 1 of a long post was not collected ($(tail -2 ${D}/watch46.out | tr '\n' ' '))"
echo "ok 46 - a long top-level post: every part is listed for the answer watch and a reply under part 1 is collected; a split inside a code block closes and reopens the fence, each part within the limit, the text intact"

# --- 34. a thread whose replies call keeps failing is skipped after three failures, so the intake goes on ---
# A failed replies call ends the run before anything is committed (the next run brings the same messages). A
# thread that fails on every run would therefore keep every channel's history out of the inbox: after
# SLACK_THREAD_FAIL_SKIP failures in a row it is skipped for SLACK_THREAD_FAIL_BACKOFF seconds, logged, with the
# count kept outside the commit point in replies-failed.
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl
T47=${M2_TS}
B47=$(awk -v t="${T47}" '$1 != t { print $1 }' ${SLACK_DIR}/threads-C0TESTCHAN | head -1)
[ -n "${B47}" ] || fail "check 47: precondition - no second registered thread"
grep -q "^${T47} " ${SLACK_DIR}/threads-C0TESTCHAN || fail "check 47: precondition - thread ${T47} is not registered"
rm -f "${SLACK_DIR:?}/replies-failed"
# a rate limit on a replies call ends the run as before but counts against no thread: a rate-limit spell must not
# park healthy threads for the backoff
curl -s "${SLACK_API_BASE}/stub.ratelimitReplies?n=1" > /dev/null
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch47-429.out 2>&1 && fail "check 47: a run with a rate-limited replies call exited 0"
grep -q "HTTP 429" ${D}/watch47-429.out || fail "check 47: the rate-limited run does not report the 429: $(tail -2 ${D}/watch47-429.out)"
[ ! -s ${SLACK_DIR}/replies-failed ] || fail "check 47: a 429 was counted as the thread's failure: $(cat ${SLACK_DIR}/replies-failed)"
rm -f "${SLACK_DIR:?}/retry-after"
curl -s "${SLACK_API_BASE}/stub.failThread?ts=${T47}&n=99" > /dev/null
X47=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+that+must+get+through+a+broken+thread" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${B47}&text=a+reply+in+a+healthy+thread" > /dev/null
for N in 1 2 3; do
	"${AGENT_DIR}/slack-watch.sh" > ${D}/watch47-${N}.out 2>&1 && fail "check 47: run ${N} exited 0 though thread ${T47} answers internal_error"
	grep -q "conversations.replies failed for channel C0TESTCHAN thread ${T47}: internal_error" ${D}/watch47-${N}.out || fail "check 47: run ${N} does not name the failing thread: $(tail -2 ${D}/watch47-${N}.out)"
	grep -q "\"ts\":\"${X47}\"" ${SLACK_DIR}/inbox.jsonl && fail "check 47: run ${N} committed history though a replies call failed"
	grep -qE "^C0TESTCHAN ${T47} ${N} [0-9]+$" ${SLACK_DIR}/replies-failed || fail "check 47: after run ${N} the failure count is not ${N}: $(cat ${SLACK_DIR}/replies-failed)"
done
grep -q "failed 3 replies call(s) in a row; it is skipped for 600s" ${D}/watch47-3.out || fail "check 47: run 3 did not announce the skip: $(grep -i skip ${D}/watch47-3.out)"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch47-4.out 2>&1 || fail "check 47: run 4 failed though the broken thread should be skipped: $(tail -2 ${D}/watch47-4.out)"
grep -q "thread ${T47} skipped, 3 replies calls failed in a row" ${D}/watch47-4.out || fail "check 47: run 4 does not log the skip: $(grep -i skip ${D}/watch47-4.out)"
[ "$(grep -c "\"ts\":\"${X47}\"" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 47: the message is in the inbox $(grep -c "\"ts\":\"${X47}\"" ${SLACK_DIR}/inbox.jsonl) times after the skipping run, not once - the broken thread held the intake"
[ "$(grep -c "a reply in a healthy thread" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 47: the healthy thread's reply is in the inbox $(grep -c "a reply in a healthy thread" ${SLACK_DIR}/inbox.jsonl) times, not once"
# the thread heals: once its call succeeds again, its failures are forgotten
curl -s "${SLACK_API_BASE}/stub.failThread?ts=${T47}&n=0" > /dev/null
sleep 2
SLACK_THREAD_FAIL_BACKOFF=1 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch47-5.out 2>&1 || fail "check 47: run 5 failed after the thread healed: $(tail -2 ${D}/watch47-5.out)"
grep -q "skipped" ${D}/watch47-5.out && fail "check 47: run 5 still skipped the healed thread after its backoff"
grep -q "^C0TESTCHAN ${T47} " ${SLACK_DIR}/replies-failed 2>/dev/null && fail "check 47: the healed thread still has a failure line: $(cat ${SLACK_DIR}/replies-failed)"
echo "ok 47 - a rate-limited replies call fails the run but counts against no thread; a thread whose replies call answers an API error three runs in a row is skipped (logged) and the run commits: the channel's new message and a healthy thread's reply reach the inbox once; the thread is polled again after its backoff and its failures are forgotten on success"

# --- 35. a fire that fails carries its batch too; at the bound the batch stays in the inbox, nothing is consumed unanswered ---
# A fire that ended any way but a stale refusal or a timeout moved its batch to processed.jsonl, and so did the fire
# at the carry bound: messages a fire never got to answer were consumed without a trace of an answer.
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl   # a clean inbox
# (a) a fire that exits 2 before answering: carried; the next fire answers the message once
mkdir -p ${D}/loop18
echo "test goal" > ${D}/loop18/GOALS.md
F48=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+that+makes+the+fire+fail+1+times" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${F48}" ] || fail "check 48: the stub did not seed the message"
loop_once_fire ${D}/loop18 ${D}/prompt18a.txt; RC48=$?
[ "${RC48}" = "2" ] || fail "check 48: precondition - loop-once.sh exited ${RC48}, not the fire's 2: $(tail -3 ${D}/loop18/once.out)"
grep -q "FIRE 1 SLACK carried=1: it exited 2; the batch stays in the inbox for the next fire, marked CARRIED (carry 1 of 3)" ${D}/loop18/loop.log \
	|| fail "check 48: the fire that exited 2 did not carry its batch: $(grep 'FIRE 1 SLACK' ${D}/loop18/loop.log)"
[ "$(processed_count "${F48}")" = "0" ] || fail "check 48: the message of the failed fire went to processed.jsonl unanswered"
head -1 ${SLACK_DIR}/inbox.jsonl | grep -q "\"ts\":\"${F48}\"" || fail "check 48: the carried message is not first in the inbox"
loop_once_fire ${D}/loop18 ${D}/prompt18b.txt || fail "check 48: fire 2 exited nonzero: $(tail -3 ${D}/loop18/once.out)"
grep -q "^CARRIED {\"ts\":\"${F48}\"" ${D}/prompt18b.txt || fail "check 48: fire 2's prompt does not mark the carried message"
grep -q "FIRE 2 SLACK processed=1" ${D}/loop18/loop.log || fail "check 48: fire 2 did not process the carried message: $(grep 'FIRE 2 SLACK' ${D}/loop18/loop.log)"
[ "$(stub_post_thread "fake loop reply to: a message that makes the fire fail 1 times")" = "${F48}" ] \
	|| fail "check 48: the carried message was not answered exactly once, in the thread under it: $(stub_post_thread "fake loop reply to: a message that makes the fire fail 1 times")"
[ "$(processed_count "${F48}")" = "1" ] || fail "check 48: the message is in processed.jsonl $(processed_count "${F48}") times after it was answered, not once"
# (b) the bound: a fire that keeps failing carries 3 times; the fourth and fifth fires run unchecked at the bound, fail
# too, and the batch stays in the inbox, logged with its count and oldest ts; the sixth fire answers it once and only
# then is it processed
mkdir -p ${D}/loop19
echo "test goal" > ${D}/loop19/GOALS.md
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch48.out 2>&1 || fail "check 48: the settling watch failed: $(tail -2 ${D}/watch48.out)"
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl   # the agent's own reply from (a), seen, out of the way
B48=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+that+makes+the+fire+fail+5+times" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${B48}" ] || fail "check 48: the stub did not seed the second message"
P0=$(stub_post_total)
for N in 1 2 3; do
	loop_once_fire ${D}/loop19 ${D}/prompt19-${N}.txt
	grep -q "FIRE ${N} SLACK carried=1: it exited 2; the batch stays in the inbox for the next fire, marked CARRIED (carry ${N} of 3)" ${D}/loop19/loop.log \
		|| fail "check 48: failing fire ${N} did not carry as expected: $(grep "FIRE ${N} SLACK" ${D}/loop19/loop.log)"
done
for N in 4 5; do
	loop_once_fire ${D}/loop19 ${D}/prompt19-${N}.txt
	grep -q "FIRE ${N} SLACK the batch was carried 3 time(s), the bound: this fire posts without the newest-message check" ${D}/loop19/loop.log \
		|| fail "check 48: fire ${N} did not run unchecked at the bound: $(grep "FIRE ${N} SLACK" ${D}/loop19/loop.log)"
	grep -q "FIRE ${N} SLACK carry bound reached: it exited 2 after 3 carries, the bound; its 1 message(s), the oldest ts=${B48}, stay in the inbox marked CARRIED" ${D}/loop19/loop.log \
		|| fail "check 48: fire ${N}, failing at the bound, did not log the carry bound with the count and the oldest ts: $(grep "FIRE ${N} SLACK" ${D}/loop19/loop.log)"
	grep -q "FIRE ${N} SLACK processed=" ${D}/loop19/loop.log && fail "check 48: fire ${N} consumed the batch at the bound though it failed: $(grep "FIRE ${N} SLACK processed" ${D}/loop19/loop.log)"
	[ "$(processed_count "${B48}")" = "0" ] || fail "check 48: the message went to processed.jsonl unanswered at the bound (fire ${N})"
	head -1 ${SLACK_DIR}/inbox.jsonl | grep -q "\"ts\":\"${B48}\"" || fail "check 48: after fire ${N} the message is not first in the inbox"
	grep -q "^CARRIED {\"ts\":\"${B48}\"" ${D}/prompt19-${N}.txt || fail "check 48: fire ${N}'s prompt does not mark the message CARRIED"
	[ "$(cat ${D}/loop19/slack-carried-count)" = "${N}" ] || fail "check 48: the carry count after fire ${N} is $(cat ${D}/loop19/slack-carried-count), not ${N}"
done
[ "$(( $(stub_post_total) - P0 ))" = "0" ] || fail "check 48: $(( $(stub_post_total) - P0 )) post(s) landed over five failed fires, not 0"
loop_once_fire ${D}/loop19 ${D}/prompt19-6.txt || fail "check 48: the sixth fire exited nonzero: $(tail -3 ${D}/loop19/once.out)"
grep -q "FIRE 6 SLACK processed=1" ${D}/loop19/loop.log || fail "check 48: the sixth fire, which ended well, did not process the batch: $(grep 'FIRE 6 SLACK' ${D}/loop19/loop.log)"
[ "$(stub_post_thread "fake loop reply to: a message that makes the fire fail 5 times")" = "${B48}" ] \
	|| fail "check 48: the message was not answered exactly once by the sixth fire, in the thread under it: $(stub_post_thread "fake loop reply to: a message that makes the fire fail 5 times")"
[ "$(processed_count "${B48}")" = "1" ] || fail "check 48: the message is in processed.jsonl $(processed_count "${B48}") times after the sixth fire, not once"
[ ! -f ${D}/loop19/slack-carried ] || fail "check 48: slack-carried remains after the batch was processed"
echo "ok 48 - a fire that exits nonzero carries its batch like a stale refusal or a timeout; at the carry bound a fire that fails again leaves the batch in the inbox, marked, with a carry-bound line naming the count and the oldest ts, and nothing reaches processed.jsonl until a fire ends well"

# --- 36. a failed inbox append moves no cursor: the next watch brings the same messages ---
# The watch appended the channel's messages and advanced the channel and thread cursors whatever the append did:
# a write that failed (a full disk, a write error) or stopped short lost those messages for good.
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch49-0.out 2>&1 || fail "check 49: the settling watch failed: $(tail -2 ${D}/watch49-0.out)"
CUR49=$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)
T49=$(awk 'NF >= 3 { print $1 }' ${SLACK_DIR}/threads-C0TESTCHAN | head -1)
[ -n "${T49}" ] || fail "check 49: precondition - no registered thread"
REG49=$(grep "^${T49} " ${SLACK_DIR}/threads-C0TESTCHAN | cut -d' ' -f1,2)
X49=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+the+inbox+could+not+take" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${X49}" ] || fail "check 49: the stub did not seed the message"
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${T49}&text=a+reply+the+inbox+could+not+take" > /dev/null
# the planted failure: the inbox path is a directory, so the append cannot open it
mv "${SLACK_DIR:?}/inbox.jsonl" "${SLACK_DIR:?}/inbox.jsonl.keep"
mkdir "${SLACK_DIR:?}/inbox.jsonl"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch49-1.out 2>&1
RC49=$?
rmdir "${SLACK_DIR:?}/inbox.jsonl"
mv "${SLACK_DIR:?}/inbox.jsonl.keep" "${SLACK_DIR:?}/inbox.jsonl"
[ "${RC49}" != "0" ] || fail "check 49: a watch whose inbox append failed exited 0 - the messages it read are lost: $(tail -3 ${D}/watch49-1.out)"
grep -q "inbox append failed for channel C0TESTCHAN: wrote 0 of [0-9]* byte(s)" ${D}/watch49-1.out || fail "check 49: the run does not report the failed append: $(tail -3 ${D}/watch49-1.out)"
[ "$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)" = "${CUR49}" ] || fail "check 49: the channel cursor moved on a failed append (${CUR49} -> $(cat ${SLACK_DIR}/cursor-C0TESTCHAN)): the message is lost"
[ "$(grep "^${T49} " ${SLACK_DIR}/threads-C0TESTCHAN | cut -d' ' -f1,2)" = "${REG49}" ] || fail "check 49: the thread's reply cursor moved on a failed append: $(grep "^${T49} " ${SLACK_DIR}/threads-C0TESTCHAN)"
grep -q "\"ts\":\"${X49}\"" ${SLACK_DIR}/inbox.jsonl && fail "check 49: the message reached the inbox although the append failed"
# the inbox writable again: the next watch brings the message and the reply exactly once
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch49-2.out 2>&1 || fail "check 49: the watch after the restore failed: $(tail -2 ${D}/watch49-2.out)"
[ "$(grep -c "\"ts\":\"${X49}\"" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 49: the message is in the inbox $(grep -c "\"ts\":\"${X49}\"" ${SLACK_DIR}/inbox.jsonl) times after the inbox was writable again, not once - the failed append lost it"
[ "$(grep -c "a reply the inbox could not take" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 49: the thread reply is in the inbox $(grep -c "a reply the inbox could not take" ${SLACK_DIR}/inbox.jsonl) times, not once"
[ "$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)" = "${X49}" ] || fail "check 49: the channel cursor is not at the message after the successful watch: $(cat ${SLACK_DIR}/cursor-C0TESTCHAN)"
echo "ok 49 - a watch whose inbox append fails ends with an error, moves neither the channel cursor nor a thread's reply cursor and puts nothing in the inbox; the next watch brings the message and the thread reply exactly once"

# --- 37. a post that did not land keeps its message in the inbox; past the retry budget it is set aside, not processed ---
# A post that failed outright (an API error, a failed call - nothing landed) was logged FAILED and the message moved
# to processed.jsonl as if handled: the person's message was consumed without an answer.
mkdir -p ${D}/state-fail
cp ${SLACK_DIR}/identity ${D}/state-fail/identity
S50=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=status" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${S50}" ] || fail "check 50: the stub did not seed the message"
printf '{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"status"}\n' "${S50}" > ${D}/state-fail/inbox.jsonl
P0=$(stub_post_total)
# (a) the first two posts fail with an API error, the third lands: answered once, processed once
curl -s "${SLACK_API_BASE}/stub.failPosts?calls=1,2&mode=error" > /dev/null
SLACK_DIR=${D}/state-fail ${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 SLACK_WATCH_BIN=/bin/true CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat50.out 2>&1 &
CHAT_PID=$!
wait_for_line 20 "CHAT REPLY ts=${S50} kind=status ok posted=" ${D}/state-fail/chat.log \
	|| chat_fail "check 50: the status message was not answered within 20 s after two failed posts: $(grep "ts=${S50}" ${D}/state-fail/chat.log | tail -3)"
[ "$(grep -c "CHAT POST FAILED ts=${S50} channel=C0TESTCHAN: nothing landed (attempt [12] of 3); the message stays in the inbox" ${D}/state-fail/chat.log)" = "2" ] \
	|| chat_fail "check 50: expected two CHAT POST FAILED lines (attempts 1 and 2 of 3) for the message, found $(grep -c "CHAT POST FAILED ts=${S50}" ${D}/state-fail/chat.log): $(grep "ts=${S50}" ${D}/state-fail/chat.log | head -4)"
[ "$(( $(stub_post_total) - P0 ))" = "1" ] || chat_fail "check 50: $(( $(stub_post_total) - P0 )) post(s) landed for the message, not 1"
[ "$(grep -c "\"ts\":\"${S50}\"" ${D}/state-fail/processed.jsonl)" = "1" ] || chat_fail "check 50: the answered message is in processed.jsonl $(grep -c "\"ts\":\"${S50}\"" ${D}/state-fail/processed.jsonl 2>/dev/null) times, not once"
[ ! -f "${D}/state-fail/chat/C0TESTCHAN-${S50}.failures" ] || chat_fail "check 50: the failure count remains after the message was answered"
# (b) the budget: three failed posts set the message aside in unanswered.jsonl, logged with the path; the message
# behind it is answered - the queue moves on
U50=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=status" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
H50=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=help" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
{ [ -n "${U50}" ] && [ -n "${H50}" ]; } || chat_fail "check 50: the stub did not seed the two messages"
P1=$(stub_post_total)
curl -s "${SLACK_API_BASE}/stub.failPosts?calls=1,2,3&mode=error" > /dev/null
printf '{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"status"}\n{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"help"}\n' "${U50}" "${H50}" >> ${D}/state-fail/inbox.jsonl
wait_for_line 25 "CHAT REPLY ts=${H50} kind=help ok posted=" ${D}/state-fail/chat.log \
	|| chat_fail "check 50: the message behind the one set aside was not answered within 25 s: $(tail -4 ${D}/state-fail/chat.log)"
grep -q "CHAT UNANSWERED ts=${U50} channel=C0TESTCHAN: 3 attempts to answer landed nothing; the message is set aside in ${D}/state-fail/unanswered.jsonl for a person to answer, not in ${D}/state-fail/processed.jsonl" ${D}/state-fail/chat.log \
	|| chat_fail "check 50: no CHAT UNANSWERED line naming the path after three failed posts: $(grep "ts=${U50}" ${D}/state-fail/chat.log | tail -2)"
[ "$(grep -c "\"ts\":\"${U50}\"" ${D}/state-fail/unanswered.jsonl)" = "1" ] || chat_fail "check 50: the set-aside message is in unanswered.jsonl $(grep -c "\"ts\":\"${U50}\"" ${D}/state-fail/unanswered.jsonl 2>/dev/null) times, not once"
grep -q "\"ts\":\"${U50}\"" ${D}/state-fail/processed.jsonl && chat_fail "check 50: the message that was never answered is in processed.jsonl as if handled"
[ "$(( $(stub_post_total) - P1 ))" = "1" ] || chat_fail "check 50: $(( $(stub_post_total) - P1 )) post(s) landed for the two messages, not 1 (the help reply only)"
[ "$(grep -c . ${D}/state-fail/inbox.jsonl)" = "0" ] || chat_fail "check 50: the inbox still holds $(grep -c . ${D}/state-fail/inbox.jsonl) line(s)"
# (c) the model path: the model's post fails and so does the fallback; next poll the model's post lands - one copy
Q50=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+question+whose+first+post+fails" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${Q50}" ] || chat_fail "check 50: the stub did not seed the question"
P2=$(stub_post_total)
curl -s "${SLACK_API_BASE}/stub.failPosts?calls=1,2&mode=error" > /dev/null
printf '{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"a question whose first post fails"}\n' "${Q50}" >> ${D}/state-fail/inbox.jsonl
wait_for_line 25 "CHAT REPLY ts=${Q50} kind=model ok posted=" ${D}/state-fail/chat.log \
	|| chat_fail "check 50: the question was not answered by the model within 25 s after a failed post: $(grep "ts=${Q50}" ${D}/state-fail/chat.log | tail -3)"
grep -q "CHAT REPLY ts=${Q50} kind=model-fallback FAILED, nothing landed" ${D}/state-fail/chat.log || chat_fail "check 50: the failed fallback is not logged as landed nothing: $(grep "ts=${Q50}" ${D}/state-fail/chat.log | head -3)"
grep -q "CHAT POST FAILED ts=${Q50} channel=C0TESTCHAN: nothing landed (attempt 1 of 3)" ${D}/state-fail/chat.log || chat_fail "check 50: the model-path message whose posts failed was not kept for another attempt: $(grep "ts=${Q50}" ${D}/state-fail/chat.log | head -3)"
[ "$(stub_post_thread "fake model reply to: a question whose first post fails")" = "${Q50}" ] || chat_fail "check 50: the question was not answered exactly once by the model, in the thread under it: $(stub_post_thread "fake model reply to: a question whose first post fails")"
[ "$(( $(stub_post_total) - P2 ))" = "1" ] || chat_fail "check 50: $(( $(stub_post_total) - P2 )) post(s) landed for the question, not 1"
OUT=$(SLACK_DIR=${D}/state-fail "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
echo "ok 50 - a post that did not land keeps its message first in the inbox and it is answered again next poll (two failures, then one answer, processed once); after SLACK_CHAT_POST_RETRIES failed attempts the message is set aside in unanswered.jsonl, logged with the path, never processed, and the queue moves on; the model path keeps the message too when the model's post and the fallback both fail"

# --- 38. a message whose thread the watch has registered but not read yet waits for that read, with no model call ---
# With the replies budget used up, a new thread's first conversations.replies call is deferred: its parent reached the
# inbox alone, the responder answered it, and slack-post.sh refused the answer as stale for the reply it had not seen -
# three model calls refused, then a capped answer that ignored the reply.
mkdir -p ${D}/state-wait
cp ${SLACK_DIR}/identity ${D}/state-wait/identity
# the stub's message clock is not the wall clock: the private state's cursor starts at a marker message, so the
# watch sees what is seeded after it (a cursor initialized to "now" would be ahead of the stub's timestamps)
MARK51=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+marker+before+the+wait+check" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${MARK51}" ] || fail "check 51: the stub did not seed the marker"
echo "${MARK51}" > ${D}/state-wait/cursor-C0TESTCHAN
export FAKE_PROMPT_OUT=${D}/chat51-prompt.txt
SLACK_DIR=${D}/state-wait ${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 SLACK_REPLIES_BUDGET=1 SLACK_REPLIES_WINDOW=5 CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat51.out 2>&1 &
CHAT_PID=$!
wait_for_line 20 "Watch complete:" ${D}/state-wait/chat-watch.log || chat_fail "check 51: the responder's first watch did not complete: $(tail -3 ${D}/state-wait/chat-watch.log ${D}/chat51.out 2>/dev/null)"
# two threads with an early reply each, seeded before the watch sees either: the window's one replies call goes to the
# first (the least recently polled, the older ts among equals), the second's is deferred - whether the watch sees both
# in one run or the second a poll later, within the window
A51=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+first+question+with+a+reply" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${A51}" ] || chat_fail "check 51: the stub did not seed the first question"
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${A51}&text=the+first+reply" > /dev/null
B51=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+second+question+with+an+early+reply" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${B51}" ] || chat_fail "check 51: the stub did not seed the second question"
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${B51}&text=the+early+reply+under+the+second+question" > /dev/null
wait_for_line 20 "CHAT REPLY ts=${A51} kind=model ok posted=" ${D}/state-wait/chat.log || chat_fail "check 51: the first question was not answered within 20 s: $(tail -3 ${D}/state-wait/chat.log)"
wait_for_line 30 "CHAT REPLY ts=${B51} kind=model ok posted=" ${D}/state-wait/chat.log || chat_fail "check 51: the second question was not answered within 30 s: $(grep "ts=${B51}" ${D}/state-wait/chat.log | tail -4)"
grep -q "Deferred [0-9]* conversations.replies call(s)" ${D}/state-wait/chat-watch.log || chat_fail "check 51: precondition - the watch never deferred a replies call, so the second thread was never unread (budget 1 per 5 s): $(grep -c 'Watch complete' ${D}/state-wait/chat-watch.log) watches"
grep -q "CHAT WAIT ts=${B51} channel=C0TESTCHAN: thread ${B51} is registered but its replies have not been read yet" ${D}/state-wait/chat.log \
	|| chat_fail "check 51: the responder did not wait for the unread thread: $(grep "ts=${B51}" ${D}/state-wait/chat.log | head -4)"
grep -q "CHAT STALE ts=${B51}" ${D}/state-wait/chat.log && chat_fail "check 51: the answer to the second question was refused as stale - the model was called before the thread was read: $(grep "CHAT STALE ts=${B51}" ${D}/state-wait/chat.log | head -1)"
[ "$(grep -c "CHAT MODEL ts=${B51} " ${D}/state-wait/chat.log)" = "1" ] || chat_fail "check 51: the model was called $(grep -c "CHAT MODEL ts=${B51} " ${D}/state-wait/chat.log) times for the second question, not once"
[ "$(grep -c "CHAT MSG ts=${B51} " ${D}/state-wait/chat.log)" = "1" ] || chat_fail "check 51: the second question was handled $(grep -c "CHAT MSG ts=${B51} " ${D}/state-wait/chat.log) times, not once"
[ "$(stub_post_thread "fake model reply to: a second question with an early reply (with 1 newer message(s))")" = "${B51}" ] \
	|| chat_fail "check 51: the second question was not answered once, in its thread, with the early reply in view: with it $(stub_post_thread "fake model reply to: a second question with an early reply (with 1 newer message(s))"), without it $(stub_post_thread "fake model reply to: a second question with an early reply")"
wait_for_line 15 "fake model reply to: the early reply under the second question" ${D}/state-wait/posted.jsonl || chat_fail "check 51: the early reply was not answered within 15 s of its parent: $(tail -3 ${D}/state-wait/chat.log)"
[ "$(stub_post_thread "fake model reply to: the early reply under the second question")" = "${B51}" ] || chat_fail "check 51: the early reply was not answered exactly once in its thread: $(stub_post_thread "fake model reply to: the early reply under the second question")"
[ ! -f "${D}/state-wait/chat/C0TESTCHAN-${B51}.wait" ] || chat_fail "check 51: the wait record remains after the message was answered"
OUT=$(SLACK_DIR=${D}/state-wait "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
# the bound: a thread no replies call ever reads (a budget of 0) is answered after SLACK_CHAT_STALE_MAX_SECONDS, logged
rm -f "${D:?}/state-wait/chat.STOP"
C51=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+third+question+whose+thread+is+never+read" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${C51}" ] || fail "check 51: the stub did not seed the third question"
curl -s "${SLACK_API_BASE}/stub.seedReply?thread=${C51}&text=a+reply+the+budget+never+lets+in" > /dev/null
SLACK_DIR=${D}/state-wait ${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 SLACK_REPLIES_BUDGET=0 SLACK_REPLIES_WINDOW=60 SLACK_CHAT_STALE_MAX_SECONDS=4 CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat51b.out 2>&1 &
CHAT_PID=$!
wait_for_line 25 "CHAT WAIT CAP ts=${C51} channel=C0TESTCHAN: thread ${C51} still unread after" ${D}/state-wait/chat.log \
	|| chat_fail "check 51: no CHAT WAIT CAP after SLACK_CHAT_STALE_MAX_SECONDS for a thread never read: $(grep "ts=${C51}" ${D}/state-wait/chat.log | tail -3)"
[ "$(grep -c "CHAT WAIT ts=${C51} " ${D}/state-wait/chat.log)" -ge 2 ] || chat_fail "check 51: the responder waited $(grep -c "CHAT WAIT ts=${C51} " ${D}/state-wait/chat.log) poll(s) before the cap, fewer than 2"
wait_for_line 25 "CHAT REPLY ts=${C51} kind=model" ${D}/state-wait/chat.log || chat_fail "check 51: the third question was not answered after the wait cap: $(grep "ts=${C51}" ${D}/state-wait/chat.log | tail -3)"
[ "$(grep -c "CHAT WAIT CAP ts=${C51} " ${D}/state-wait/chat.log)" = "1" ] || chat_fail "check 51: CHAT WAIT CAP was logged $(grep -c "CHAT WAIT CAP ts=${C51} " ${D}/state-wait/chat.log) times for one message, not once"
OUT=$(SLACK_DIR=${D}/state-wait "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
echo "ok 51 - a message whose thread the watch registered but has not read yet (its first replies call deferred by the budget) waits, logged CHAT WAIT and with no model call, until the call is made, then is answered once with the early reply in view - no stale refusal, one model call, one handling; a thread never read is answered after SLACK_CHAT_STALE_MAX_SECONDS, logged CHAT WAIT CAP"

# --- 39. one lock for every inbox writer: no append into a file being replaced, no padding of a replaced inbox ---
# The watcher's restore wrote the inbox back to its old size whatever had happened to it meanwhile. A consumer's
# sed -i under the append replaced the file (the append went into the old inode), and the restore padded the
# smaller new file with NUL bytes; the next watch appended onto them - a line that is not JSON, and a message lost.
# The watcher took no lock, the consumers remove handled lines with sed -i, and the docs tell operators to run the
# watcher by hand beside the responder.
inbox_json_ok()
{
	# inbox_json_ok <file> - every line parses as JSON
	"${NODE_BIN}" -e 'const fs=require("fs"); for (const l of fs.readFileSync(process.argv[1],"utf8").split("\n")) { if (!l) continue; try { JSON.parse(l); } catch (e) { process.exit(1); } }' "$1"
}
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch52-0.out 2>&1 || fail "check 52: the settling watch failed: $(tail -2 ${D}/watch52-0.out)"
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl
F52=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+line+already+in+the+inbox" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${F52}" ] || fail "check 52: the stub did not seed the first message"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch52-1.out 2>&1 || fail "check 52: the watch bringing the first line failed: $(tail -2 ${D}/watch52-1.out)"
[ "$(grep -c . ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 52: precondition - the inbox holds $(grep -c . ${SLACK_DIR}/inbox.jsonl) line(s), not the one just brought"
# a cat shim: when the watcher appends its batch (one argument, a mktemp file) a consumer's removal of the first inbox
# line happens first - taking the inbox lock as the real consumers do (SHIM_LOCKED=1: it then fails while the watcher
# holds the lock), or ignoring it (a writer from before the lock) - then the real cat runs
mkdir -p ${D}/shim52
cat > ${D}/shim52/cat << 'EOF'
#!/bin/bash
if [ $# -eq 1 ] && [ "${1#/tmp/tmp.}" != "$1" ] && [ -n "${SHIM_INBOX}" ]; then
	if [ "${SHIM_LOCKED}" = "1" ]; then
		if flock -n "${SHIM_INBOX%/*}/inbox.lock" sed -i '1d' "${SHIM_INBOX}" 2>/dev/null; then echo "edited under the lock" >> "${SHIM_INBOX%/*}/shim52.log"; else echo "lock held, no edit" >> "${SHIM_INBOX%/*}/shim52.log"; fi
	else
		sed -i '1d' "${SHIM_INBOX}" && echo "edited unlocked" >> "${SHIM_INBOX%/*}/shim52.log"
	fi
fi
exec /bin/cat "$@"
EOF
chmod +x ${D}/shim52/cat
rm -f "${SLACK_DIR:?}/shim52.log"
# (a) the consumer takes the lock, as the real ones do: the edit cannot happen while the watcher appends; the append is clean
X52=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+appended+while+a+consumer+wants+to+edit" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${X52}" ] || fail "check 52: the stub did not seed the second message"
PATH="${D}/shim52:${PATH}" SHIM_INBOX=${SLACK_DIR}/inbox.jsonl SHIM_LOCKED=1 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch52-2.out 2>&1
RC52=$?
grep -q "lock held, no edit" ${SLACK_DIR}/shim52.log 2>/dev/null || fail "check 52: a consumer's locked removal went through under the watcher's append - the watcher holds no inbox lock (shim log: $(cat ${SLACK_DIR}/shim52.log 2>/dev/null))"
[ ${RC52} -eq 0 ] || fail "check 52: the watch beside a locked consumer exited ${RC52}: $(tail -2 ${D}/watch52-2.out)"
[ "$(tr -cd '\000' < ${SLACK_DIR}/inbox.jsonl | wc -c)" = "0" ] || fail "check 52: the inbox holds NUL bytes after the append beside a locked consumer"
[ "$(grep -c . ${SLACK_DIR}/inbox.jsonl)" = "2" ] || fail "check 52: the inbox holds $(grep -c . ${SLACK_DIR}/inbox.jsonl) line(s), not the earlier line and the new one"
[ "$(grep -c "\"ts\":\"${X52}\"" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 52: the new message is in the inbox $(grep -c "\"ts\":\"${X52}\"" ${SLACK_DIR}/inbox.jsonl) times, not once"
inbox_json_ok ${SLACK_DIR}/inbox.jsonl || fail "check 52: a line of the inbox is not JSON after the append beside a locked consumer"
# (b) a writer that ignores the lock replaces the inbox under the append: the watcher refuses, touches nothing, holds
# the cursor, and the next watch brings the message once onto a well-formed inbox
rm -f "${SLACK_DIR:?}/shim52.log"
CUR52=$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)
Y52=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+appended+while+an+unlocked+writer+edits" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${Y52}" ] || fail "check 52: the stub did not seed the third message"
PATH="${D}/shim52:${PATH}" SHIM_INBOX=${SLACK_DIR}/inbox.jsonl SHIM_LOCKED=0 "${AGENT_DIR}/slack-watch.sh" > ${D}/watch52-3.out 2>&1
RC52=$?
grep -q "edited unlocked" ${SLACK_DIR}/shim52.log 2>/dev/null || fail "check 52: precondition - the unlocked shim did not edit the inbox under the append"
[ ${RC52} -ne 0 ] || fail "check 52: a watch whose inbox was replaced under its append exited 0: $(tail -2 ${D}/watch52-3.out)"
grep -q "inbox append failed for channel C0TESTCHAN: .*replaced under the append (inode" ${D}/watch52-3.out || fail "check 52: the run does not say the inbox was replaced under the append: $(tail -2 ${D}/watch52-3.out)"
[ "$(tr -cd '\000' < ${SLACK_DIR}/inbox.jsonl | wc -c)" = "0" ] || fail "check 52: the restore padded the replaced inbox with $(tr -cd '\000' < ${SLACK_DIR}/inbox.jsonl | wc -c) NUL byte(s)"
[ "$(grep -c . ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 52: the inbox holds $(grep -c . ${SLACK_DIR}/inbox.jsonl) line(s) after the refused append, not the one the unlocked writer left"
[ "$(cat ${SLACK_DIR}/cursor-C0TESTCHAN)" = "${CUR52}" ] || fail "check 52: the cursor moved on the refused append"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch52-4.out 2>&1 || fail "check 52: the next watch failed: $(tail -2 ${D}/watch52-4.out)"
[ "$(grep -c "\"ts\":\"${Y52}\"" ${SLACK_DIR}/inbox.jsonl)" = "1" ] || fail "check 52: the message of the refused append is in the inbox $(grep -c "\"ts\":\"${Y52}\"" ${SLACK_DIR}/inbox.jsonl) times after the next watch, not once"
inbox_json_ok ${SLACK_DIR}/inbox.jsonl || fail "check 52: a line of the inbox is not JSON after the next watch (the message was appended onto padding)"
# (c) the responder's removal waits while another process holds the inbox lock
mkdir -p ${D}/state-lock
cp ${SLACK_DIR}/identity ${D}/state-lock/identity
H52=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=help" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${H52}" ] || fail "check 52: the stub did not seed the help message"
printf '{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"help"}\n' "${H52}" > ${D}/state-lock/inbox.jsonl
flock -x ${D}/state-lock/inbox.lock sleep 10 &
LOCKER52=$!
SLACK_DIR=${D}/state-lock ${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 SLACK_WATCH_BIN=/bin/true CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat52.out 2>&1 &
CHAT_PID=$!
wait_for_line 8 "CHAT REPLY ts=${H52} kind=help ok posted=" ${D}/state-lock/chat.log || { kill ${LOCKER52} 2>/dev/null; chat_fail "check 52: the help message was not answered within 8 s: $(tail -3 ${D}/state-lock/chat.log)"; }
sleep 1
kill -0 ${LOCKER52} 2>/dev/null || chat_fail "check 52: precondition - the lock holder ended before the check"
[ "$(grep -c . ${D}/state-lock/inbox.jsonl)" = "1" ] || { kill ${LOCKER52} 2>/dev/null; chat_fail "check 52: the responder removed the handled line from the inbox while another process held the inbox lock"; }
grep -q "\"ts\":\"${H52}\"" ${D}/state-lock/processed.jsonl 2>/dev/null && { kill ${LOCKER52} 2>/dev/null; chat_fail "check 52: the responder moved the line to processed.jsonl while another process held the inbox lock"; }
wait ${LOCKER52} 2>/dev/null
N=0; while { [ "$(grep -c "\"ts\":\"${H52}\"" ${D}/state-lock/processed.jsonl 2>/dev/null)" != "1" ] || [ "$(grep -c . ${D}/state-lock/inbox.jsonl)" != "0" ]; } && [ ${N} -lt 20 ]; do sleep 0.5; N=$((N + 1)); done
[ "$(grep -c "\"ts\":\"${H52}\"" ${D}/state-lock/processed.jsonl 2>/dev/null)" = "1" ] || chat_fail "check 52: after the lock was released the line was not moved to processed.jsonl once: $(tail -2 ${D}/state-lock/chat.log)"
[ "$(grep -c . ${D}/state-lock/inbox.jsonl)" = "0" ] || chat_fail "check 52: the inbox still holds $(grep -c . ${D}/state-lock/inbox.jsonl) line(s) after the lock was released"
OUT=$(SLACK_DIR=${D}/state-lock "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
# (d) the loop's removal waits too: a fire (its watch a no-op here) answers its batch while the lock is held and moves it
# only once the lock is free
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl
mkdir -p ${D}/loop20
echo "test goal" > ${D}/loop20/GOALS.md
L52=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+handled+while+the+inbox+lock+is+held" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${L52}" ] || fail "check 52: the stub did not seed the loop's message"
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch52-5.out 2>&1 || fail "check 52: the watch bringing the loop's message failed: $(tail -2 ${D}/watch52-5.out)"
flock -x ${SLACK_DIR}/inbox.lock sleep 10 &
LOCKER52=$!
FAKE_PROMPT_OUT=${D}/prompt20.txt FAKE_LOOP_POST=1 SLACK_POST_ENABLED=true SLACK_CHAT_ENABLED=false SLACK_WATCH_BIN=/bin/true CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop20 AUTONOMY_LOOP_WORKDIR=${D}/loop20 AUTONOMY_LOOP_GOALS=${D}/loop20/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/loop20/once.out 2>&1 < /dev/null &
ONCE52=$!
wait_for_line 8 "FIRE 1 END rc=0" ${D}/loop20/loop.log || { kill ${LOCKER52} ${ONCE52} 2>/dev/null; fail "check 52: the fire did not end within 8 s: $(cat ${D}/loop20/loop.log)"; }
sleep 1
kill -0 ${LOCKER52} 2>/dev/null || fail "check 52: precondition - the lock holder ended before the loop check"
[ "$(processed_count "${L52}")" = "0" ] || { kill ${LOCKER52} 2>/dev/null; fail "check 52: the fire moved its batch to processed.jsonl while another process held the inbox lock"; }
grep -q "\"ts\":\"${L52}\"" ${SLACK_DIR}/inbox.jsonl || { kill ${LOCKER52} 2>/dev/null; fail "check 52: the fire removed its batch from the inbox while another process held the inbox lock"; }
wait ${LOCKER52} 2>/dev/null
wait ${ONCE52} 2>/dev/null || fail "check 52: loop-once.sh exited nonzero: $(tail -3 ${D}/loop20/once.out)"
grep -q "FIRE 1 SLACK processed=" ${D}/loop20/loop.log || fail "check 52: the fire did not process its batch once the lock was free: $(grep 'FIRE 1 SLACK' ${D}/loop20/loop.log)"
[ "$(processed_count "${L52}")" = "1" ] || fail "check 52: the message is in processed.jsonl $(processed_count "${L52}") times, not once"
[ "$(stub_post_thread "fake loop reply to: a message handled while the inbox lock is held")" = "${L52}" ] || fail "check 52: the message was not answered exactly once, in the thread under it: $(stub_post_thread "fake loop reply to: a message handled while the inbox lock is held")"
echo "ok 52 - every inbox writer takes one lock: a consumer's locked removal cannot land under the watcher's append (clean append, every line JSON); a writer that ignores the lock makes the watcher refuse without padding the replaced inbox, cursor held, the message brought once by the next watch; the responder's and the loop's removals wait while another process holds the lock"

# --- 40. a batch no fire answers is set aside after the bound's fires; the carry note's post list is capped ---
# At the carry bound a failing batch was handed to every later fire, without end: the fires posted without the
# newest-message check, the carried-posts list grew with every fire's posts, the prompt with it, and nothing newer than
# SLACK_LOOP_BATCH_MAX lines ever reached a fire. The chat responder's twin path sets a message aside after its attempts.
"${AGENT_DIR}/slack-watch.sh" > ${D}/watch53.out 2>&1 || fail "check 53: the settling watch failed: $(tail -2 ${D}/watch53.out)"
cat ${SLACK_DIR}/inbox.jsonl >> ${SLACK_DIR}/processed.jsonl 2>/dev/null; : > ${SLACK_DIR}/inbox.jsonl   # the agent's own earlier posts, seen, out of the way
# (a) a message whose fires keep failing: three carries, three failing fires at the bound, then set aside
mkdir -p ${D}/loop21
echo "test goal" > ${D}/loop21/GOALS.md
S53=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+that+makes+the+fire+fail+9+times" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${S53}" ] || fail "check 53: the stub did not seed the message"
P0=$(stub_post_total)
for N in 1 2 3 4 5; do
	loop_once_fire ${D}/loop21 ${D}/prompt21-${N}.txt
done
grep -q "FIRE 5 SLACK carry bound reached: it exited 2 after 3 carries, the bound; its 1 message(s), the oldest ts=${S53}, stay in the inbox marked CARRIED (fire 2 of 3 at the bound; set aside in ${SLACK_DIR}/unanswered.jsonl after fire 3 unless a fire ends well)" ${D}/loop21/loop.log \
	|| fail "check 53: fire 5 did not log the bound with its place and the set-aside to come: $(grep 'FIRE 5 SLACK' ${D}/loop21/loop.log)"
[ "$(processed_count "${S53}")" = "0" ] || fail "check 53: the message went to processed.jsonl unanswered before the set-aside"
grep -q "\"ts\":\"${S53}\"" ${SLACK_DIR}/unanswered.jsonl 2>/dev/null && fail "check 53: the message was set aside after fewer than 3 fires at the bound"
loop_once_fire ${D}/loop21 ${D}/prompt21-6.txt
grep -q "FIRE 6 SLACK set aside: it exited 2 after 3 carries and 3 fires at the bound; its 1 message(s), the oldest ts=${S53}, are moved to ${SLACK_DIR}/unanswered.jsonl for a person to answer, not to processed.jsonl" ${D}/loop21/loop.log \
	|| fail "check 53: fire 6 did not set the batch aside with the loud line: $(grep 'FIRE 6 SLACK' ${D}/loop21/loop.log)"
[ "$(grep -c "\"ts\":\"${S53}\"" ${SLACK_DIR}/unanswered.jsonl)" = "1" ] || fail "check 53: the set-aside message is in unanswered.jsonl $(grep -c "\"ts\":\"${S53}\"" ${SLACK_DIR}/unanswered.jsonl 2>/dev/null) times, not once"
[ "$(processed_count "${S53}")" = "0" ] || fail "check 53: the set-aside message is in processed.jsonl as if handled"
grep -q "\"ts\":\"${S53}\"" ${SLACK_DIR}/inbox.jsonl && fail "check 53: the set-aside message is still in the inbox"
{ [ ! -f ${D}/loop21/slack-carried ] && [ ! -f ${D}/loop21/slack-carried-count ]; } || fail "check 53: the carry state remains after the set-aside"
[ "$(( $(stub_post_total) - P0 ))" = "0" ] || fail "check 53: $(( $(stub_post_total) - P0 )) post(s) landed for a message no fire answered"
loop_once_fire ${D}/loop21 ${D}/prompt21-7.txt || fail "check 53: the fire after the set-aside exited nonzero: $(tail -3 ${D}/loop21/once.out)"
grep -q "FIRE 7 SLACK" ${D}/loop21/loop.log && fail "check 53: the fire after the set-aside still got a Slack batch: $(grep 'FIRE 7 SLACK' ${D}/loop21/loop.log)"
# (b) the carry note's post list: each landed post once, the newest SLACK_LOOP_CARRY_POSTS_MAX, the rest counted
mkdir -p ${D}/loop22
echo "test goal" > ${D}/loop22/GOALS.md
C53=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+message+that+posts+then+makes+the+fire+fail+3+times" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
[ -n "${C53}" ] || fail "check 53: the stub did not seed the posting message"
P1=$(stub_post_total)
for N in 1 2 3; do
	SLACK_LOOP_CARRY_POSTS_MAX=2 loop_once_fire ${D}/loop22 ${D}/prompt22-${N}.txt
	grep -q "FIRE ${N} SLACK carried=[0-9]*: it exited 2; .* (carry ${N} of 3)" ${D}/loop22/loop.log || fail "check 53: posting fire ${N} did not carry: $(grep "FIRE ${N} SLACK" ${D}/loop22/loop.log)"
done
[ "$(( $(stub_post_total) - P1 ))" = "3" ] || fail "check 53: $(( $(stub_post_total) - P1 )) post(s) landed over three posting fires, not 3"
[ "$(grep -c '^  ts=' ${D}/loop22/slack-carried-posts)" = "2" ] || fail "check 53: the carried-posts list holds $(grep -c '^  ts=' ${D}/loop22/slack-carried-posts) post line(s), not the newest 2: $(cat ${D}/loop22/slack-carried-posts)"
grep -q "^  \.\.\. and 1 earlier post(s), not listed$" ${D}/loop22/slack-carried-posts || fail "check 53: the carried-posts list does not count the post it dropped: $(cat ${D}/loop22/slack-carried-posts)"
SLACK_LOOP_CARRY_POSTS_MAX=2 loop_once_fire ${D}/loop22 ${D}/prompt22-4.txt || fail "check 53: the fourth posting fire exited nonzero: $(tail -3 ${D}/loop22/once.out)"
[ "$(grep -c '^  ts=' ${D}/prompt22-4.txt)" = "2" ] || fail "check 53: the fourth fire's carry note lists $(grep -c '^  ts=' ${D}/prompt22-4.txt) post(s), not 2"
grep -q "^  \.\.\. and 1 earlier post(s), not listed$" ${D}/prompt22-4.txt || fail "check 53: the fourth fire's carry note does not count the dropped post"
grep -q "fake loop reply to: a message that posts then makes the fire fail 3 times (attempt 3)" ${D}/prompt22-4.txt || fail "check 53: the newest post is not in the capped list"
grep -q "FIRE 4 SLACK processed=" ${D}/loop22/loop.log || fail "check 53: the fourth fire, which ended well, did not process the batch: $(grep 'FIRE 4 SLACK' ${D}/loop22/loop.log)"
[ "$(processed_count "${C53}")" = "1" ] || fail "check 53: the posting message is in processed.jsonl $(processed_count "${C53}") times after the fourth fire, not once"
[ "$(( $(stub_post_total) - P1 ))" = "4" ] || fail "check 53: $(( $(stub_post_total) - P1 )) post(s) in all, not 4 (three attempts and the answer)"
echo "ok 53 - a batch no fire answers is set aside after SLACK_LOOP_CARRY_MAX carries and SLACK_LOOP_BOUND_FIRES failing fires at the bound: moved to unanswered.jsonl with a loud line naming the path, the count and the oldest ts, never processed, the carry state cleared, the next fire without a batch; the carry note's post list keeps each post once, the newest SLACK_LOOP_CARRY_POSTS_MAX, the rest counted"

# --- 41. an inbox line without a channel is skipped, logged, and the message behind it is answered ---
# The responder built its per-message record paths with ${M_CH:?}: an inbox line with a ts but no channel made the
# expansion fail, which ends the process - the valid message behind it was never answered, and every restart died on
# the same line.
mkdir -p ${D}/state-nochan
cp ${SLACK_DIR}/identity ${D}/state-nochan/identity
NC54=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=a+line+that+lost+its+channel" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
V54=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=help" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
{ [ -n "${NC54}" ] && [ -n "${V54}" ]; } || fail "check 54: the stub did not seed the two messages"
printf '{"ts":"%s","user":"U0PERSON","text":"a line that lost its channel"}\n{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"help"}\n' "${NC54}" "${V54}" > ${D}/state-nochan/inbox.jsonl
P0=$(stub_post_total)
SLACK_DIR=${D}/state-nochan ${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 SLACK_WATCH_BIN=/bin/true CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
	"${CHAT}" > ${D}/chat54.out 2>&1 &
CHAT_PID=$!
wait_for_line 15 "CHAT REPLY ts=${V54} kind=help ok posted=" ${D}/state-nochan/chat.log \
	|| chat_fail "check 54: the valid message behind a line without a channel was not answered within 15 s (responder alive: $(kill -0 ${CHAT_PID} 2>/dev/null && echo yes || echo no)): $(tail -3 ${D}/state-nochan/chat.log ${D}/chat54.out 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
grep -q "CHAT SKIP ts=${NC54} line without a channel: " ${D}/state-nochan/chat.log || chat_fail "check 54: the line without a channel was not skipped with a log line: $(grep "ts=${NC54}" ${D}/state-nochan/chat.log)"
kill -0 ${CHAT_PID} 2>/dev/null || chat_fail "check 54: the responder is not alive after the line without a channel"
[ "$(grep -c "\"ts\":\"${NC54}\"" ${D}/state-nochan/processed.jsonl)" = "1" ] || chat_fail "check 54: the skipped line is in processed.jsonl $(grep -c "\"ts\":\"${NC54}\"" ${D}/state-nochan/processed.jsonl 2>/dev/null) times, not once"
N=0; while [ "$(grep -c . ${D}/state-nochan/inbox.jsonl)" != "0" ] && [ ${N} -lt 10 ]; do sleep 0.5; N=$((N + 1)); done
[ "$(grep -c . ${D}/state-nochan/inbox.jsonl)" = "0" ] || chat_fail "check 54: the inbox still holds $(grep -c . ${D}/state-nochan/inbox.jsonl) line(s)"
[ "$(( $(stub_post_total) - P0 ))" = "1" ] || chat_fail "check 54: $(( $(stub_post_total) - P0 )) post(s) landed, not the one help answer"
OUT=$(SLACK_DIR=${D}/state-nochan "${AGENT_DIR}/slack-chat-stop.sh" --now 2>&1)
wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
echo "ok 54 - an inbox line with a ts but no channel is skipped with a CHAT SKIP line and moved to processed.jsonl like an unparseable one; the responder stays up and answers the valid message behind it once"

# --- 42. a fire whose claude cannot use its credentials is not a success ---
# `claude -p` CAN exit 0 when it has no credentials: it prints "API Error: Could not load AWS credentials ..." instead
# of working, so the fire's outcome must come from its OUTPUT - the END line says outcome=no-credentials, the exit
# status becomes 97, the state records the outcome and agent-status.sh says the fire did no work. Both callers of
# fire-outcome.sh are driven: loop-once.sh (foreground) and loop.sh (the shipped loop: background, then the STOP flag).
# Controls: a working fake whose ANSWER mentions AccessDenied stays rc=0 outcome=ok (only claude's own API Error line is
# classified); a model-access denial is no-access with the account id in its resource name masked; a fake that ends
# like a timed-out fire (124) is outcome=timeout and agent-status.sh names it.
printf '#!/bin/bash\ncat > /dev/null\necho "API Error: Could not load AWS credentials · Set AWS_PROFILE or attach an instance role"\nexit 0\n' > ${D}/fakeclaude-nocreds
printf '#!/bin/bash\ncat > /dev/null\necho "The AccessDenied on s3:GetObject comes from the bucket policy; I added the statement. Unable to locate credentials was a red herring."\nexit 0\n' > ${D}/fakeclaude-mentions
printf '#!/bin/bash\ncat > /dev/null\necho "API Error: 403 You don'"'"'t have access to the model with the specified model ID. arn:aws:bedrock:us-east-1:123456789012:inference-profile/x"\nexit 0\n' > ${D}/fakeclaude-nomodel
printf '#!/bin/bash\ncat > /dev/null\nexit 124\n' > ${D}/fakeclaude-timeout
chmod +x ${D}/fakeclaude-nocreds ${D}/fakeclaude-mentions ${D}/fakeclaude-nomodel ${D}/fakeclaude-timeout
once32()
{
	# once32 <name> <fake claude> -> loop-once.sh's exit status; the loop directory is ${D}/loop32-<name>
	mkdir -p ${D}/loop32-$1
	echo "test goal" > ${D}/loop32-$1/GOALS.md
	SLACK_WATCH_ENABLED=false CLAUDE_BIN=$2 AUTONOMY_LOOP_DIR=${D}/loop32-$1 AUTONOMY_LOOP_WORKDIR=${D}/loop32-$1 AUTONOMY_LOOP_GOALS=${D}/loop32-$1/GOALS.md \
		"${AGENT_DIR}/loop-once.sh" > ${D}/once32-$1.out 2>&1
	echo $?
}
RC32=$(once32 nocreds ${D}/fakeclaude-nocreds)
[ "${RC32}" == "97" ] || fail "55: loop-once.sh exited ${RC32} with a claude that printed a credentials error and exited 0 (expected 97): $(tail -3 ${D}/once32-nocreds.out)"
grep -q "FIRE 1 END rc=97 .*outcome=no-credentials Could not load AWS credentials" ${D}/loop32-nocreds/loop.log || fail "55: the END line does not record the outcome: $(grep ' END ' ${D}/loop32-nocreds/loop.log)"
grep -q "outcome=no-credentials" ${D}/loop32-nocreds/loop.state || fail "55: the loop state does not record the outcome: $(cat ${D}/loop32-nocreds/loop.state)"
OUT32=$(AUTONOMY_LOOP_DIR=${D}/loop32-nocreds "${AGENT_DIR}/agent-status.sh" 2>/dev/null)
echo "${OUT32}" | grep -q "did NO work: claude could not use AWS credentials" || fail "55: agent-status.sh does not say the fire did no work: ${OUT32}"
RC32=$(once32 mentions ${D}/fakeclaude-mentions)
[ "${RC32}" == "0" ] || fail "55: a working fake whose answer mentions AccessDenied made loop-once.sh exit ${RC32} (expected 0: only claude's own API Error line is classified): $(grep ' END ' ${D}/loop32-mentions/loop.log)"
grep -q "FIRE 1 END rc=0 .*outcome=ok$" ${D}/loop32-mentions/loop.log || fail "55: the answer that mentions AccessDenied is not recorded outcome=ok: $(grep ' END ' ${D}/loop32-mentions/loop.log)"
RC32=$(once32 nomodel ${D}/fakeclaude-nomodel)
[ "${RC32}" == "97" ] || fail "55: loop-once.sh exited ${RC32} with a claude that reported no access to the model and exited 0 (expected 97): $(grep ' END ' ${D}/loop32-nomodel/loop.log)"
grep -q "outcome=no-access 403 You don't have access to the model" ${D}/loop32-nomodel/loop.log || fail "55: the model-access denial is not recorded outcome=no-access: $(grep ' END ' ${D}/loop32-nomodel/loop.log)"
grep -q "123456789012" ${D}/loop32-nomodel/loop.log && fail "55: the END line repeats the account id from the resource name: $(grep ' END ' ${D}/loop32-nomodel/loop.log)"
RC32=$(once32 timeout ${D}/fakeclaude-timeout)
[ "${RC32}" == "124" ] || fail "55: loop-once.sh exited ${RC32} with a claude that ended like a timed-out fire (expected 124): $(grep ' END ' ${D}/loop32-timeout/loop.log)"
grep -q "FIRE 1 END rc=124 .*outcome=timeout exit status 124" ${D}/loop32-timeout/loop.log || fail "55: a timed-out fire is not recorded outcome=timeout: $(grep ' END ' ${D}/loop32-timeout/loop.log)"
OUT32=$(AUTONOMY_LOOP_DIR=${D}/loop32-timeout "${AGENT_DIR}/agent-status.sh" 2>/dev/null)
echo "${OUT32}" | grep -q "timed out with no output" || fail "55: agent-status.sh does not name the timeout: ${OUT32}"
# the shipped loop: one fire with the credential-less fake, the state while sleeping, then the STOP flag
mkdir -p ${D}/loop32-loop
echo "test goal" > ${D}/loop32-loop/GOALS.md
SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude-nocreds AUTONOMY_LOOP_DIR=${D}/loop32-loop AUTONOMY_LOOP_WORKDIR=${D}/loop32-loop AUTONOMY_LOOP_GOALS=${D}/loop32-loop/GOALS.md AUTONOMY_LOOP_INTERVAL=2 \
	"${AGENT_DIR}/loop.sh" > ${D}/loop32-loop.out 2>&1 &
LOOP_PID=$!
wait_for_line 20 "FIRE 1 END" ${D}/loop32-loop/loop.log || loop_fail "55: loop.sh's fire 1 did not end within 20s: $(cat ${D}/loop32-loop/loop.log ${D}/loop32-loop.out 2>/dev/null)"
wait_for_line 10 "last_outcome=no-credentials" ${D}/loop32-loop/loop.state || loop_fail "55: loop.sh's state does not record last_outcome=no-credentials: $(cat ${D}/loop32-loop/loop.state)"
touch ${D}/loop32-loop/STOP
if ! wait_for_line 20 "STOPPED reason=stop-flag" ${D}/loop32-loop/loop.state; then
	kill "${LOOP_PID}" 2>/dev/null
	fail "55: loop.sh did not stop on the STOP flag within 20s (killed pid ${LOOP_PID} as a fallback): $(cat ${D}/loop32-loop/loop.state)"
fi
wait "${LOOP_PID}" 2>/dev/null
grep -q "FIRE 1 END rc=97 .*outcome=no-credentials Could not load AWS credentials" ${D}/loop32-loop/loop.log || fail "55: loop.sh's END line does not record the outcome: $(grep ' END ' ${D}/loop32-loop/loop.log)"
OUT32=$(AUTONOMY_LOOP_DIR=${D}/loop32-loop "${AGENT_DIR}/agent-status.sh" 2>/dev/null)
echo "${OUT32}" | grep -q "did NO work: claude could not use AWS credentials" || fail "55: agent-status.sh does not say loop.sh's fire did no work: ${OUT32}"
grep -q "FIRE 1 END rc=0 .*outcome=ok$" ${D}/loop4/loop.log || fail "55: loop.sh's earlier fire with the answering fake (ok 16) is not recorded outcome=ok: $(grep ' END ' ${D}/loop4/loop.log | head -2)"
echo "ok 55 - a fire whose claude printed a credentials error and exited 0 is recorded outcome=no-credentials, exit 97, by loop-once.sh and by loop.sh (log, state, agent-status.sh); an answer that mentions AccessDenied stays ok; a model-access denial is no-access with the account id masked; a timed-out fire is outcome=timeout"


# --- 43. the bot token is on no command line and in no xtrace ---
# Every curl call of this run went through the shim installed at the start: slack-watch.sh and
# slack-post.sh (and the loop and the chat responder, which call them) pass the Authorization header
# in curl's config on stdin
[ -s ${D}/curl-argv.log ] || fail "check 56: the curl shim logged no call"
for M in auth.test conversations.history conversations.replies chat.postMessage; do
	grep -q "/api/${M}" ${D}/curl-argv.log || fail "check 56: the shim logged no ${M} call, so the scripts' calls did not go through it"
done
N42=$(grep -c . ${D}/curl-argv.log)
if grep -q 'xoxb-' ${D}/curl-argv.log; then
	fail "check 56: a bot token is a word of curl's command line in $(grep -c 'xoxb-' ${D}/curl-argv.log) of ${N42} calls (first: $(grep -m1 'xoxb-' ${D}/curl-argv.log | grep -o '/api/[a-zA-Z.]*' | head -1)) - any local user can read it in ps"
fi
X42=$( { bash -x "${AGENT_DIR}/slack-watch.sh"; SLACK_POST_ENABLED=true bash -x "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "an xtrace probe"
	bash -x "${AGENT_DIR}/slack-status.sh"; } 2>&1 )
echo "${X42}" | grep -q "Posted and read-back verified" || fail "check 56: the post run under xtrace did not verify: $(echo "${X42}" | tail -3)"
if echo "${X42}" | grep -q 'xoxb-test-stub'; then
	fail "check 56: the token shows in $(echo "${X42}" | grep -c 'xoxb-test-stub') xtrace line(s) of slack-watch.sh, slack-post.sh or slack-status.sh"
fi
echo "ok 56 - the bot token is a word of no curl command line in the ${N42} calls of this run, and shows in no xtrace of slack-watch.sh, slack-post.sh or slack-status.sh"

kill "${STUB_PID}" 2>/dev/null

# --- 57. goals-add.sh's arguments ("goals-add.sh --help" added the goal "--help", a card on both boards):
#         -h/--help print the usage and add nothing; a first argument that starts with "-" is refused with one line naming
#         the -- form; after "--" such a goal lands as a checkbox item ---
mkdir -p ${D}/goals49
G49=${D}/goals49/GOALS.md
OUT=$(AUTONOMY_LOOP_GOALS=${G49} AUTONOMY_LOOP_DIR=${D}/goals49 "${AGENT_DIR}/goals-add.sh" --help 2>&1); RC=$?
{ [ "${RC}" == "0" ] && echo "${OUT}" | grep -q '^usage: '; } || fail "57: goals-add.sh --help did not print the usage and exit 0 (rc=${RC}): ${OUT}"
echo "${OUT}" | grep -qF -- '- [ ] <goal>' || fail "57: the usage does not state the checkbox form the loop and the board read: ${OUT}"
[ -f "${G49}" ] && fail "57: goals-add.sh --help created the goals file (it added '--help' as a goal before)"
OUT=$(AUTONOMY_LOOP_GOALS=${G49} AUTONOMY_LOOP_DIR=${D}/goals49 "${AGENT_DIR}/goals-add.sh" -h 2>&1) && echo "${OUT}" | grep -q '^usage: ' || fail "57: -h is not the usage: ${OUT}"
OUT=$(AUTONOMY_LOOP_GOALS=${G49} AUTONOMY_LOOP_DIR=${D}/goals49 "${AGENT_DIR}/goals-add.sh" --verbose 2>&1); RC=$?
{ [ "${RC}" == "1" ] && echo "${OUT}" | grep -q "a goal does not start with '-'" && echo "${OUT}" | grep -qF -- '-- "--verbose"'; } \
	|| fail "57: a leading dash was not refused with the way to add such a goal (rc=${RC}): ${OUT}"
[ -f "${G49}" ] && fail "57: a refused argument reached the goals file"
AUTONOMY_LOOP_GOALS=${G49} AUTONOMY_LOOP_DIR=${D}/goals49 "${AGENT_DIR}/goals-add.sh" -- "--dry-run must be supported by the deploy script" > /dev/null || fail "57: a goal after -- was refused"
grep -qxF -- "- [ ] --dry-run must be supported by the deploy script" "${G49}" || fail "57: the goal after -- did not land as a checkbox item: $(cat "${G49}")"
[ "$(grep -c '^- \[ \]' "${G49}")" == "1" ] || fail "57: the goals file has $(grep -c '^- \[ \]' "${G49}") goals, expected the one after --"
echo "ok 57 - goals-add.sh: -h/--help print the usage (naming the checkbox form) and add nothing; a first argument starting with '-' is refused with one line naming the -- form and nothing lands; after -- such a goal lands as the one checkbox item"

# --- 24. AUTONOMY_LOOP_CLAUDE_OPTS set in .env.local reaches a fire's claude (ok 58) ---
# The checkout's .env and .fun are copied to a scratch folder, so a person's own .env.local stays out of this check;
# a planted .env.local there sets the variable. RUN_OPTS is read the way ./run.sh's eval and then docker's -e read it:
# NAME=value is that value, a bare NAME copies the value from the environment and is skipped when it is unset.
ENV_FILE=""
for C in "${BASE_DIR}/../.env" "/do-agent-aws/.env" "${BASE_DIR}/.env"; do
	[ -f "${C}" ] && ENV_FILE="$(cd "$(dirname "${C}")" && pwd)/.env" && break
done
if [ -n "${ENV_FILE}" ]; then
	mkdir -p ${D}/envpass
	cp "${ENV_FILE}" "$(dirname "${ENV_FILE}")/.fun" ${D}/envpass/
	PLANTED_OPTS="--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/recall.sh:*) Read(//opt/planted-58/**) --permission-mode acceptEdits"
	# container_opts: what the container holds for AUTONOMY_LOOP_CLAUDE_OPTS after ./run.sh's
	# `docker container run ${RUN_OPTS}` with this .env: "unset", or "set:<value>"
	# shellcheck disable=SC2120 # its positional parameters are RUN_OPTS's words, set inside it with set --
	container_opts()
	{
		(
			cd ${D}/envpass || exit 1
			# ENV_LOCAL_FILE too: exported, it would make .env skip the planted .env.local
			unset AUTONOMY_LOOP_CLAUDE_OPTS ENV_LOCAL_FILE
			# shellcheck disable=SC1091
			source ./.env > /dev/null 2>&1
			set -f
			eval "set -- ${RUN_OPTS}"
			R="unset"
			while [ $# -gt 0 ]; do
				if [ "$1" == "-e" ] && [ $# -gt 1 ]; then
					case "$2" in
						AUTONOMY_LOOP_CLAUDE_OPTS=*) R="set:${2#AUTONOMY_LOOP_CLAUDE_OPTS=}" ;;
						AUTONOMY_LOOP_CLAUDE_OPTS) printenv AUTONOMY_LOOP_CLAUDE_OPTS > /dev/null && R="set:$(printenv AUTONOMY_LOOP_CLAUDE_OPTS)" ;;
					esac
					shift
				fi
				shift
			done
			echo "${R}"
		)
	}
	GOT58=$(container_opts)
	[ "${GOT58}" == "unset" ] || fail "58: with AUTONOMY_LOOP_CLAUDE_OPTS unset, the container would still get it: ${GOT58}"
	printf 'export AUTONOMY_LOOP_CLAUDE_OPTS="%s"\n' "${PLANTED_OPTS}" > ${D}/envpass/.env.local
	GOT58=$(container_opts)
	[ "${GOT58}" == "set:${PLANTED_OPTS}" ] \
		|| fail "58: AUTONOMY_LOOP_CLAUDE_OPTS set in .env.local does not reach the container whole (it would hold: ${GOT58})"
	mkdir -p ${D}/loop58
	echo "test goal" > ${D}/loop58/GOALS.md
	export FAKE_PROMPT_OUT=${D}/prompt58.txt
	export FAKE_ARGV_OUT=${D}/argv58.txt
	AUTONOMY_LOOP_CLAUDE_OPTS="${GOT58#set:}" SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
		AUTONOMY_LOOP_DIR=${D}/loop58 AUTONOMY_LOOP_WORKDIR=${D}/loop58 AUTONOMY_LOOP_GOALS=${D}/loop58/GOALS.md \
		"${AGENT_DIR}/loop-once.sh" > ${D}/once58.out 2>&1 < /dev/null || fail "58: loop-once with the options from .env.local exited nonzero: $(cat ${D}/once58.out)"
	printf '%s\n' "-p" "--allowedTools" "Bash(/agent/slack-post.sh:*)" "Bash(/agent/recall.sh:*)" "Read(//opt/planted-58/**)" \
		"--permission-mode" "acceptEdits" > ${D}/argv58.expected
	cmp -s ${D}/argv58.expected ${D}/argv58.txt || fail "58: the fire's claude did not get the options set in .env.local: $(tr '\n' ' ' < ${D}/argv58.txt)"
	echo "ok 58 - AUTONOMY_LOOP_CLAUDE_OPTS set in .env.local reaches the container whole (.env passes it bare) and the fire's claude gets it word for word; unset, nothing is passed"
else
	[ "${TEST_CONTAINER}" == "true" ] && fail "58: no .env at /do-agent-aws or beside ${BASE_DIR} although this is the test container: the checkout mount is missing"
	echo "Test4 skipped check 58: no .env found in this context (./test.sh mounts the checkout at /do-agent-aws)"
fi

# --- 25. the compose and kubernetes templates pass AUTONOMY_LOOP_CLAUDE_OPTS (ok 59) ---
if [ -n "${ENV_FILE}" ]; then
	ROOT=$(dirname "${ENV_FILE}")
	CT=${ROOT}/to/compose/template/docker-compose.yaml
	KT=${ROOT}/to/kubernetes/template/020-deployment.yaml
	CI=$(grep -m1 -oE '^ *- AUTONOMY_LOOP_FIRE_TIMEOUT=' "${CT}" | sed 's/- AUTONOMY_LOOP_FIRE_TIMEOUT=$//')
	KI=$(grep -m1 -oE '^ *- name: AUTONOMY_LOOP_FIRE_TIMEOUT$' "${KT}" | sed 's/- name: AUTONOMY_LOOP_FIRE_TIMEOUT$//')
	{ [ -n "${CI}" ] && [ -n "${KI}" ]; } || fail "59: the templates no longer carry AUTONOMY_LOOP_FIRE_TIMEOUT, the entry this check compares with"
	# shellcheck disable=SC2016 # the templates carry the literal ${...} that envsubst fills in
	grep -qxF "${CI}- AUTONOMY_LOOP_CLAUDE_OPTS=\${AUTONOMY_LOOP_CLAUDE_OPTS}" "${CT}" \
		|| fail "59: the compose template does not pass AUTONOMY_LOOP_CLAUDE_OPTS like AUTONOMY_LOOP_FIRE_TIMEOUT"
	grep -A1 -xF "${KI}- name: AUTONOMY_LOOP_CLAUDE_OPTS" "${KT}" | grep -qxF "${KI}  value: \"\${AUTONOMY_LOOP_CLAUDE_OPTS}\"" \
		|| fail "59: the kubernetes template does not pass AUTONOMY_LOOP_CLAUDE_OPTS like AUTONOMY_LOOP_FIRE_TIMEOUT"
	echo "ok 59 - the compose and kubernetes templates pass AUTONOMY_LOOP_CLAUDE_OPTS like the other four loop settings"
else
	[ "${TEST_CONTAINER}" == "true" ] && fail "59: no .env at /do-agent-aws or beside ${BASE_DIR} although this is the test container: the checkout mount is missing"
	echo "Test4 skipped check 59: no .env found in this context (./test.sh mounts the checkout at /do-agent-aws)"
fi

# --- 26. a fire's option words are never glob-expanded (ok 60) ---
mkdir -p "${D}/loop60/Bash(/agent" "${D}/loop60/Read(/opt/planted-60" ${D}/loop60b
: > "${D}/loop60/Bash(/agent/slack-post.sh:p60)"
: > "${D}/loop60/Read(/opt/planted-60/p60)"
echo "test goal" > ${D}/loop60/GOALS.md
OPTS60="--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/recall.sh:*) Read(//opt/planted-60/**) --permission-mode acceptEdits"
# PLANTED CONTROL: in the fire's working directory the shell itself expands two of those words
# shellcheck disable=SC2086 # the expansion is the point
( cd ${D}/loop60 && printf '%s\n' ${OPTS60} ) > ${D}/glob60.txt
{ grep -qxF "Bash(/agent/slack-post.sh:p60)" ${D}/glob60.txt && grep -qxF "Read(//opt/planted-60/p60)" ${D}/glob60.txt; } \
	|| fail "PLANTED CONTROL BROKEN: the planted paths do not match the rule words, so check 60 could not see an expansion: $(tr '\n' ' ' < ${D}/glob60.txt)"
printf '%s\n' "-p" "--allowedTools" "Bash(/agent/slack-post.sh:*)" "Bash(/agent/recall.sh:*)" "Read(//opt/planted-60/**)" \
	"--permission-mode" "acceptEdits" > ${D}/argv60.expected
export FAKE_PROMPT_OUT=${D}/prompt60.txt
export FAKE_ARGV_OUT=${D}/argv60-once.txt
AUTONOMY_LOOP_CLAUDE_OPTS="${OPTS60}" SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop60 AUTONOMY_LOOP_WORKDIR=${D}/loop60 AUTONOMY_LOOP_GOALS=${D}/loop60/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once60.out 2>&1 < /dev/null || fail "60: loop-once exited nonzero: $(cat ${D}/once60.out)"
cmp -s ${D}/argv60.expected ${D}/argv60-once.txt || fail "60: loop-once.sh's fire got glob-expanded option words: $(tr '\n' ' ' < ${D}/argv60-once.txt)"
export FAKE_ARGV_OUT=${D}/argv60-loop.txt
AUTONOMY_LOOP_CLAUDE_OPTS="${OPTS60}" SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop60b AUTONOMY_LOOP_WORKDIR=${D}/loop60 AUTONOMY_LOOP_GOALS=${D}/loop60/GOALS.md \
	AUTONOMY_LOOP_INTERVAL=2 "${AGENT_DIR}/loop.sh" > ${D}/loop60.out 2>&1 &
LOOP_PID=$!
if ! wait_for_line 20 "FIRE 1 END" ${D}/loop60b/loop.log; then
	kill "${LOOP_PID}" 2>/dev/null
	fail "60: loop.sh's first fire did not end within 20s: $(cat ${D}/loop60b/loop.log ${D}/loop60.out 2>/dev/null)"
fi
touch ${D}/loop60b/STOP
if ! wait_for_line 20 "STOPPED reason=stop-flag" ${D}/loop60b/loop.state; then
	kill "${LOOP_PID}" 2>/dev/null
	fail "60: loop.sh did not stop on the STOP flag within 20s (killed pid ${LOOP_PID} as a fallback)"
fi
wait "${LOOP_PID}" 2>/dev/null
cmp -s ${D}/argv60.expected ${D}/argv60-loop.txt || fail "60: loop.sh's fire got glob-expanded option words: $(tr '\n' ' ' < ${D}/argv60-loop.txt)"
echo "ok 60 - a fire's option words are split on spaces but never glob-expanded: with paths planted in its working directory that match two rules (planted control: the shell expands them there), loop-once.sh's and loop.sh's fires give claude the words as written"

# --- an operator's value: the fixture of checks 61, 62 and 64 (its exact words - the non-rule options
#     --add-dir <dir> and --permission-mode <mode> around four rules, the fourth with a space - and the two words a
#     shell split of it gives claude) ---
OPTS61="--add-dir /do-agent-aws --allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) Bash(bash /wd/loop/run-next-fire/apply_to_source.sh:*) --permission-mode acceptEdits"
WORD62='"/wd/loop/run-next-fire/apply_to_source.sh:*)"'
# PLANTED CONTROL: the shell's own word splitting makes 10 words of that value, the 7th and 8th the two the operator's claude saw
set -f   # the shell's split, not its globbing
# shellcheck disable=SC2086 # the split is the point
printf '%s\n' ${OPTS61} > ${D}/split61.txt
set +f
{ [ "$(grep -c . ${D}/split61.txt)" == "10" ] && [ "$(sed -n '7p' ${D}/split61.txt)" == "Bash(bash" ] && [ "$(sed -n '8p' ${D}/split61.txt)" == "/wd/loop/run-next-fire/apply_to_source.sh:*)" ]; } \
	|| fail "PLANTED CONTROL BROKEN: the shell does not split the operator's value into 10 words with Bash(bash and /wd/loop/run-next-fire/apply_to_source.sh:*) as the 7th and 8th: $(tr '\n' '|' < ${D}/split61.txt)"

# --- 27. a rule with a space inside its parentheses is ONE argument of the fire's claude call (ok 61) ---
# Word-split by the shell, an option string's rule with a space inside its parentheses would reach claude as two
# words, the first a harmless unknown tool name, the second refused ("Ignoring --allowedTools rule ...
# Wildcard tool name ... is not supported in allow rules"), so every call the rule allowed would be denied and the fire
# would run on until its timeout. claude_opts_split (/agent/claude-opts.sh) keeps a blank inside parentheses in its word: the fires of
# loop-once.sh and loop.sh give claude the rule as ONE argument, the other words unchanged, nothing is reported for it,
# and the safe value - no blank inside parentheses - splits exactly as before, its argv byte for byte.
# the operator's exact value (the fixture above) reaches claude as 9 arguments: the non-rule options --add-dir <dir> and
# --permission-mode <mode> pass through unchanged around the four rules, the fourth with a space
printf '%s\n' "-p" "--add-dir" "/do-agent-aws" "--allowedTools" "Bash(/agent/slack-post.sh:*)" "Bash(/agent/recall.sh:*)" "Bash(/agent/bus-answer.sh:*)" \
	"Bash(bash /wd/loop/run-next-fire/apply_to_source.sh:*)" "--permission-mode" "acceptEdits" > ${D}/argv61.expected
mkdir -p ${D}/loop61 ${D}/loop61b ${D}/loop61c
echo "test goal" > ${D}/loop61/GOALS.md
echo "test goal" > ${D}/loop61c/GOALS.md
export FAKE_PROMPT_OUT=${D}/prompt61.txt
export FAKE_ARGV_OUT=${D}/argv61-once.txt
AUTONOMY_LOOP_CLAUDE_OPTS="${OPTS61}" SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop61 AUTONOMY_LOOP_WORKDIR=${D}/loop61 AUTONOMY_LOOP_GOALS=${D}/loop61/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once61.out 2>&1 < /dev/null || fail "61: loop-once.sh exited nonzero with a spaced rule: $(cat ${D}/once61.out)"
cmp -s ${D}/argv61.expected ${D}/argv61-once.txt || fail "61: loop-once.sh's fire did not give claude the spaced rule as one argument: $(tr '\n' '|' < ${D}/argv61-once.txt)"
grep -q "FIRE 1 END rc=0 .*outcome=ok$" ${D}/loop61/loop.log || fail "61: the fire with the spaced rule is not recorded rc=0 outcome=ok: $(grep ' END ' ${D}/loop61/loop.log)"
grep -q "You are one fire of the do-agent-aws autonomy loop" ${D}/prompt61.txt || fail "61: the prompt did not arrive on stdin with the spaced rule"
export FAKE_ARGV_OUT=${D}/argv61-loop.txt
AUTONOMY_LOOP_CLAUDE_OPTS="${OPTS61}" SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop61b AUTONOMY_LOOP_WORKDIR=${D}/loop61 AUTONOMY_LOOP_GOALS=${D}/loop61/GOALS.md \
	AUTONOMY_LOOP_INTERVAL=2 "${AGENT_DIR}/loop.sh" > ${D}/loop61.out 2>&1 &
LOOP_PID=$!
wait_for_line 20 "FIRE 1 END" ${D}/loop61b/loop.log || loop_fail "61: loop.sh's first fire did not end within 20s: $(cat ${D}/loop61b/loop.log ${D}/loop61.out 2>/dev/null)"
touch ${D}/loop61b/STOP
wait_for_line 20 "STOPPED reason=stop-flag" ${D}/loop61b/loop.state || loop_fail "61: loop.sh did not stop on the STOP flag within 20s (killed pid ${LOOP_PID} as a fallback)"
wait "${LOOP_PID}" 2>/dev/null
cmp -s ${D}/argv61.expected ${D}/argv61-loop.txt || fail "61: loop.sh's fire did not give claude the spaced rule as one argument: $(tr '\n' '|' < ${D}/argv61-loop.txt)"
grep -q "LOOP CONFIG AUTONOMY_LOOP_CLAUDE_OPTS:\|LOOP WARNING AUTONOMY_LOOP_CLAUDE_OPTS:" ${D}/loop61b/loop.log && fail "61: a value whose every word can be a rule was reported: $(grep 'AUTONOMY_LOOP_CLAUDE_OPTS:' ${D}/loop61b/loop.log)"
# the safe value: its argv byte for byte what it was (ok 19/20's shape, every word one rule, no blank inside parentheses)
SAFE61="--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits"
printf '%s\n' "-p" "--allowedTools" "Bash(/agent/slack-post.sh:*)" "Bash(/agent/recall.sh:*)" "Bash(/agent/bus-answer.sh:*)" "--permission-mode" "acceptEdits" > ${D}/argv61-safe.expected
export FAKE_ARGV_OUT=${D}/argv61-safe.txt
AUTONOMY_LOOP_CLAUDE_OPTS="${SAFE61}" SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop61c AUTONOMY_LOOP_WORKDIR=${D}/loop61c AUTONOMY_LOOP_GOALS=${D}/loop61c/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once61c.out 2>&1 < /dev/null || fail "61: loop-once.sh exited nonzero with the safe value: $(cat ${D}/once61c.out)"
cmp -s ${D}/argv61-safe.expected ${D}/argv61-safe.txt || fail "61: the safe value's argv changed: $(tr '\n' '|' < ${D}/argv61-safe.txt)"
# a parenthesis never closed OUTSIDE the rule lists (--add-dir /x(y): the value is split on blanks after all, as the shell
# did, the fire runs and nothing is reported - a mistake there costs what it cost before, not every fire
OPTS61C="--add-dir /x(y --allowedTools Bash(/agent/slack-post.sh:*) --permission-mode acceptEdits"
printf '%s\n' "-p" "--add-dir" "/x(y" "--allowedTools" "Bash(/agent/slack-post.sh:*)" "--permission-mode" "acceptEdits" > ${D}/argv61c.expected
mkdir -p ${D}/loop61d
echo "test goal" > ${D}/loop61d/GOALS.md
export FAKE_ARGV_OUT=${D}/argv61c.txt
AUTONOMY_LOOP_CLAUDE_OPTS="${OPTS61C}" SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop61d AUTONOMY_LOOP_WORKDIR=${D}/loop61d AUTONOMY_LOOP_GOALS=${D}/loop61d/GOALS.md \
	"${AGENT_DIR}/loop-once.sh" > ${D}/once61d.out 2>&1 < /dev/null || fail "61: loop-once.sh exited nonzero with a parenthesis left open outside the rule lists: $(cat ${D}/once61d.out)"
cmp -s ${D}/argv61c.expected ${D}/argv61c.txt || fail "61: a parenthesis left open outside the rule lists did not leave the shell's split: $(tr '\n' '|' < ${D}/argv61c.txt)"
grep -q "AUTONOMY_LOOP_CLAUDE_OPTS:\|outcome=config" ${D}/loop61d/loop.log && fail "61: a parenthesis left open outside the rule lists was reported: $(grep 'AUTONOMY_LOOP_CLAUDE_OPTS:\|outcome=config' ${D}/loop61d/loop.log)"
echo "ok 61 - a rule with a space inside its parentheses is ONE argument of the fire's claude call, the other words unchanged (PLANTED CONTROL: the shell's own split breaks it in two), through loop-once.sh and loop.sh, nothing reported; the safe value's argv is byte for byte what it was; a parenthesis left open outside the rule lists leaves the shell's split and is not reported"

# --- 28. a word that cannot be a rule is reported BEFORE the fire, not after its timeout (ok 62) ---
# The word claude refuses, "/wd/loop/run-next-fire/apply_to_source.sh:*)" - the tail of a
# rule split on its space - planted as a word of the allow list: claude_opts_check reports it (parentheses that do not
# pair up) and, with AUTONOMY_LOOP_OPTS_CHECK unset (true), the fire is SKIPPED: the fake claude is never called (no argv
# file), the END line says rc=96 duration=0s outcome=config with the word quoted, the state records it, the transcript
# file carries the report and agent-status.sh says the fire did no work - by loop-once.sh (exit 96, the report on
# stderr) and by loop.sh (LOOP CONFIG at start, the fire skipped, the loop sleeping on). A parenthesis left open and a
# rule written without its tool name are reported the same way. With AUTONOMY_LOOP_OPTS_CHECK=false the fire RUNS, the
# fake gets the words as written, and a WARNING names the word.
BAD62="--allowedTools /wd/loop/run-next-fire/apply_to_source.sh:*) --permission-mode acceptEdits"
# the check itself, on the old shape: the 10 words the shell made of the operator's value (check 61's planted control) name
# word 8, quoted exactly as the client's warning quotes it; the value as written splits into 9 words and passes
# shellcheck disable=SC1090 # the file under test
. "${AGENT_DIR}/claude-opts.sh"
mapfile -t SPLIT62 < ${D}/split61.txt
REPORT62=$(claude_opts_check SPLIT62) && fail "62: claude_opts_check passed the shell's 10-word split of the operator's value: $(tr '\n' '|' < ${D}/split61.txt)"
case "${REPORT62}" in
	*"the word ${WORD62} cannot be a rule: its parentheses do not pair up"*) ;;
	*) fail "62: claude_opts_check does not name word 8 quoted as the client's warning does: ${REPORT62}" ;;
esac
case "${REPORT62}" in
	'the word "Bash(bash" cannot be a rule: its parentheses do not pair up; the word '*) ;;
	*) fail "62: claude_opts_check does not name word 7, the silent half of the split rule, first: ${REPORT62}" ;;
esac
claude_opts_split SPLIT62 "${OPTS61}"
[ "${#SPLIT62[@]}" == "9" ] || fail "62: claude_opts_split made ${#SPLIT62[@]} words of the operator's value, not 9: $(printf '%s|' "${SPLIT62[@]}")"
REPORT62=$(claude_opts_check SPLIT62) || fail "62: claude_opts_check reports the operator's value as written: ${REPORT62}"
# direct: a deny rule may hold a * anywhere, a comma list is split as claude splits it, the = form takes one word (a bare
# word after it is a positional argument, not a rule); a quoted rule is named as quotes
claude_opts_split SPLIT62 "--disallowedTools * mcp__* Bash(rm:*) --allowedTools Bash(/a:*),Read(//opt/x/**),Edit --allowedTools=Bash(git *) /positional"
REPORT62=$(claude_opts_check SPLIT62) || fail "62: claude_opts_check reports a deny list with globs, a comma list or the = form: ${REPORT62}"
claude_opts_split SPLIT62 "--allowedTools 'Bash(git:*)' --permission-mode acceptEdits"
REPORT62=$(claude_opts_check SPLIT62) && fail "62: claude_opts_check passed a quoted rule"
case "${REPORT62}" in
	"the word \"'Bash(git:*)'\" cannot be a rule: quotes in the value are not quotes - remove them"*) ;;
	*) fail "62: a quoted rule is not named as quotes: ${REPORT62}" ;;
esac
once62()
{
	# once62 <name> <options> [NAME=value ...] -> loop-once.sh's exit status; the loop directory is ${D}/loop62-<name>
	N62=$1; O62=$2; shift 2
	mkdir -p ${D}/loop62-${N62}
	echo "test goal" > ${D}/loop62-${N62}/GOALS.md
	env "$@" FAKE_PROMPT_OUT=${D}/loop62-${N62}/prompt.txt FAKE_ARGV_OUT=${D}/loop62-${N62}/argv.txt AUTONOMY_LOOP_CLAUDE_OPTS="${O62}" \
		SLACK_WATCH_ENABLED=false CLAUDE_BIN=${D}/fakeclaude \
		AUTONOMY_LOOP_DIR=${D}/loop62-${N62} AUTONOMY_LOOP_WORKDIR=${D}/loop62-${N62} AUTONOMY_LOOP_GOALS=${D}/loop62-${N62}/GOALS.md \
		"${AGENT_DIR}/loop-once.sh" > ${D}/loop62-${N62}/once.out 2> ${D}/loop62-${N62}/once.err < /dev/null
	echo $?
}
RC62=$(once62 word "${BAD62}")
[ "${RC62}" == "96" ] || fail "62: loop-once.sh exited ${RC62} with a word that cannot be a rule in its options (expected 96): $(cat ${D}/loop62-word/once.out ${D}/loop62-word/once.err)"
[ ! -f ${D}/loop62-word/argv.txt ] || fail "62: claude was called although the options hold a word that cannot be a rule: $(tr '\n' ' ' < ${D}/loop62-word/argv.txt)"
# a skipped fire takes seconds (a second boundary may fall inside it), never the 1500 s timeout
{ grep -qE "FIRE 1 END rc=96 duration=[0-9]s outcome=config " ${D}/loop62-word/loop.log \
	&& grep -qF -- "outcome=config the word ${WORD62} cannot be a rule: its parentheses do not pair up" ${D}/loop62-word/loop.log; } \
	|| fail "62: the END line does not report the word before the fire (rc 96, a duration of seconds): $(grep ' END ' ${D}/loop62-word/loop.log)"
grep -q "outcome=config" ${D}/loop62-word/loop.state || fail "62: the loop state does not record outcome=config: $(cat ${D}/loop62-word/loop.state)"
grep -qF -- "FIRE SKIPPED, no claude call: AUTONOMY_LOOP_CLAUDE_OPTS holds a word that cannot be a rule - the word ${WORD62} cannot be a rule" ${D}/loop62-word/fires/fire-1.out \
	|| fail "62: the fire's transcript does not carry the report: $(cat ${D}/loop62-word/fires/fire-1.out)"
grep -qF -- "FIRE SKIPPED, no claude call" ${D}/loop62-word/once.err || fail "62: loop-once.sh did not print the report on stderr: $(cat ${D}/loop62-word/once.err)"
OUT62=$(AUTONOMY_LOOP_DIR=${D}/loop62-word "${AGENT_DIR}/agent-status.sh" 2>/dev/null)
echo "${OUT62}" | grep -q "did NO work: AUTONOMY_LOOP_CLAUDE_OPTS holds a word that cannot be a rule" || fail "62: agent-status.sh does not say the fire did no work: ${OUT62}"
# a parenthesis left open: the open word and the rest of the value are split on blanks after all (as the shell did), the
# open fragment and the orphaned path both named, the options behind them still options - with the check off the fire
# runs with --permission-mode acceptEdits intact, exactly the shell's words
RC62=$(once62 open "--allowedTools Bash(bash /wd/loop/run-next-fire/apply_to_source.sh:* --permission-mode acceptEdits")
[ "${RC62}" == "96" ] || fail "62: loop-once.sh exited ${RC62} with a parenthesis left open (expected 96): $(grep ' END ' ${D}/loop62-open/loop.log)"
grep -qF -- 'outcome=config the word "Bash(bash" cannot be a rule: its parentheses do not pair up; the word "/wd/loop/run-next-fire/apply_to_source.sh:*" cannot be an allow rule: "/wd/loop/run-next-fire/apply_to_source.sh:*" is not a tool name' ${D}/loop62-open/loop.log \
	|| fail "62: the parenthesis left open is not reported as the open fragment and the orphaned path: $(grep ' END ' ${D}/loop62-open/loop.log)"
[ ! -f ${D}/loop62-open/argv.txt ] || fail "62: claude was called with a parenthesis left open"
RC62=$(once62 open-off "--allowedTools Bash(bash /wd/loop/run-next-fire/apply_to_source.sh:* --permission-mode acceptEdits" AUTONOMY_LOOP_OPTS_CHECK=false)
[ "${RC62}" == "0" ] || fail "62: with the check off loop-once.sh exited ${RC62} with a parenthesis left open (expected 0: the fire runs): $(grep ' END ' ${D}/loop62-open-off/loop.log)"
printf '%s\n' "-p" "--allowedTools" "Bash(bash" "/wd/loop/run-next-fire/apply_to_source.sh:*" "--permission-mode" "acceptEdits" > ${D}/argv62-open.expected
cmp -s ${D}/argv62-open.expected ${D}/loop62-open-off/argv.txt || fail "62: with the check off a parenthesis left open did not give claude the shell's words (the options behind it must stay options): $(tr '\n' '|' < ${D}/loop62-open-off/argv.txt)"
# a rule written without its tool name: not a tool name (claude would refuse it)
RC62=$(once62 notool "--allowedTools /agent/slack-post.sh:* --permission-mode acceptEdits")
[ "${RC62}" == "96" ] || fail "62: loop-once.sh exited ${RC62} with a rule written without its tool name (expected 96): $(grep ' END ' ${D}/loop62-notool/loop.log)"
grep -qF -- 'outcome=config the word "/agent/slack-post.sh:*" cannot be an allow rule: "/agent/slack-post.sh:*" is not a tool name' ${D}/loop62-notool/loop.log \
	|| fail "62: the rule without a tool name is not reported: $(grep ' END ' ${D}/loop62-notool/loop.log)"
# the knob off: the fire runs, claude gets the words as written, a WARNING names the word
RC62=$(once62 off "${BAD62}" AUTONOMY_LOOP_OPTS_CHECK=false)
[ "${RC62}" == "0" ] || fail "62: with AUTONOMY_LOOP_OPTS_CHECK=false loop-once.sh exited ${RC62} (expected 0: the fire runs): $(cat ${D}/loop62-off/once.out ${D}/loop62-off/once.err)"
printf '%s\n' "-p" "--allowedTools" "/wd/loop/run-next-fire/apply_to_source.sh:*)" "--permission-mode" "acceptEdits" > ${D}/argv62.expected
cmp -s ${D}/argv62.expected ${D}/loop62-off/argv.txt || fail "62: with the check off claude did not get the words as written: $(tr '\n' '|' < ${D}/loop62-off/argv.txt)"
grep -qF -- "FIRE 1 WARNING AUTONOMY_LOOP_CLAUDE_OPTS: the word ${WORD62} cannot be a rule" ${D}/loop62-off/loop.log || fail "62: with the check off no WARNING names the word: $(cat ${D}/loop62-off/loop.log)"
grep -q "FIRE 1 END rc=0 .*outcome=ok$" ${D}/loop62-off/loop.log || fail "62: with the check off the fire is not recorded rc=0 outcome=ok: $(grep ' END ' ${D}/loop62-off/loop.log)"
# the shipped loop: LOOP CONFIG at start, the fire skipped with no claude call, the loop sleeps on, then the STOP flag; a
# Slack batch handed to the skipped fire (the watch gate on, the watch a no-op, one planted inbox line) is carried, the
# carry line naming the skip, the line left in the inbox
mkdir -p ${D}/loop62-loop ${D}/state62
echo "test goal" > ${D}/loop62-loop/GOALS.md
printf '{"ts":"1793600000.000100","channel":"C0TESTCHAN","user":"U0PERSON","text":"a message while the options are wrong"}\n' > ${D}/state62/inbox.jsonl
export FAKE_PROMPT_OUT=${D}/loop62-loop/prompt.txt
export FAKE_ARGV_OUT=${D}/loop62-loop/argv.txt
AUTONOMY_LOOP_CLAUDE_OPTS="${BAD62}" SLACK_WATCH_ENABLED=true SLACK_CHAT_ENABLED=false SLACK_WATCH_BIN=/bin/true SLACK_DIR=${D}/state62 CLAUDE_BIN=${D}/fakeclaude \
	AUTONOMY_LOOP_DIR=${D}/loop62-loop AUTONOMY_LOOP_WORKDIR=${D}/loop62-loop AUTONOMY_LOOP_GOALS=${D}/loop62-loop/GOALS.md AUTONOMY_LOOP_INTERVAL=2 \
	"${AGENT_DIR}/loop.sh" > ${D}/loop62-loop.out 2>&1 &
LOOP_PID=$!
wait_for_line 20 "FIRE 1 END" ${D}/loop62-loop/loop.log || loop_fail "62: loop.sh's fire 1 did not end within 20s: $(cat ${D}/loop62-loop/loop.log ${D}/loop62-loop.out 2>/dev/null)"
grep -qF -- "LOOP CONFIG AUTONOMY_LOOP_CLAUDE_OPTS: the word ${WORD62} cannot be a rule: its parentheses do not pair up" ${D}/loop62-loop/loop.log \
	|| loop_fail "62: loop.sh did not report the word at LOOP START: $(cat ${D}/loop62-loop/loop.log)"
{ grep -qE "FIRE 1 END rc=96 duration=[0-9]s outcome=config " ${D}/loop62-loop/loop.log \
	&& grep -qF -- "outcome=config the word ${WORD62} cannot be a rule" ${D}/loop62-loop/loop.log; } \
	|| loop_fail "62: loop.sh's END line does not report the word (rc 96, a duration of seconds): $(grep ' END ' ${D}/loop62-loop/loop.log)"
grep -qF -- "FIRE 1 SLACK carried=1: it was skipped: AUTONOMY_LOOP_CLAUDE_OPTS holds a word that cannot be a rule (the END line names it); the batch stays in the inbox" ${D}/loop62-loop/loop.log \
	|| loop_fail "62: the Slack batch handed to the skipped fire is not carried with the skip as its reason: $(grep ' SLACK ' ${D}/loop62-loop/loop.log)"
[ "$(grep -c . ${D}/state62/inbox.jsonl)" == "1" ] || loop_fail "62: the skipped fire's inbox line did not stay in the inbox ($(grep -c . ${D}/state62/inbox.jsonl) line(s))"
wait_for_line 10 "SLEEPING last_fire=1 last_rc=96 last_outcome=config" ${D}/loop62-loop/loop.state || loop_fail "62: loop.sh's state after the skipped fire is not SLEEPING with rc 96 and outcome config: $(cat ${D}/loop62-loop/loop.state)"
[ ! -f ${D}/loop62-loop/argv.txt ] || loop_fail "62: loop.sh called claude although the options hold a word that cannot be a rule: $(tr '\n' ' ' < ${D}/loop62-loop/argv.txt)"
touch ${D}/loop62-loop/STOP
if ! wait_for_line 20 "STOPPED reason=stop-flag" ${D}/loop62-loop/loop.state; then
	kill "${LOOP_PID}" 2>/dev/null
	fail "62: loop.sh did not stop on the STOP flag within 20s (killed pid ${LOOP_PID} as a fallback): $(cat ${D}/loop62-loop/loop.state)"
fi
wait "${LOOP_PID}" 2>/dev/null
grep -qF -- "FIRE SKIPPED, no claude call" ${D}/loop62-loop/fires/fire-1.out || fail "62: loop.sh's fire transcript does not carry the report: $(cat ${D}/loop62-loop/fires/fire-1.out 2>/dev/null)"
OUT62=$(AUTONOMY_LOOP_DIR=${D}/loop62-loop "${AGENT_DIR}/agent-status.sh" 2>/dev/null)
echo "${OUT62}" | grep -q "did NO work: AUTONOMY_LOOP_CLAUDE_OPTS holds a word that cannot be a rule" || fail "62: agent-status.sh does not say loop.sh's fire did no work: ${OUT62}"
echo "ok 62 - a word of the allow list that cannot be a rule - the operator's refused word, a parenthesis left open, a rule without its tool name - is reported BEFORE the fire, the word quoted: loop-once.sh and loop.sh skip the fire with no claude call (END rc=96 outcome=config <report> within seconds, the report as the transcript and on loop-once.sh's stderr, LOOP CONFIG at the loop's start, the state and agent-status.sh naming it) instead of running it without the rule until its timeout; the check itself names both fragments of the operator's value split the old way, passes it as written, passes a deny list with globs, a comma list and the = form, and names a quoted rule as quotes; a parenthesis left open leaves the shell's words behind it (the options stay options); a Slack batch handed to a skipped fire is carried with the skip as its reason; AUTONOMY_LOOP_OPTS_CHECK=false runs the fire with the words as written and a WARNING names the word"

# --- 29. claude's own "Ignoring --allowedTools rule" line is named on the END line without failing the fire (ok 63) ---
# What the check before the fire does not see (a client whose grammar changed, the check turned off), fire-outcome.sh
# names from the transcript: a fake that prints the line the operator's claude printed, then does its work and exits 0,
# is recorded outcome=ok ignored-rule "<word>" - rc stays 0 (the fire did its work; not 97) and agent-status.sh says the
# rule was ignored; a fake that prints it and ends like a timed-out fire keeps timeout first.
printf '#!/bin/bash\ncat > /dev/null\necho '"'"'Ignoring --allowedTools rule "/wd/loop/run-next-fire/apply_to_source.sh:*)": Wildcard tool name "/wd/loop/run-next-fire/apply_to_source.sh:*)" is not supported in allow rules. An allow pattern must name the scope it widens.'"'"'\necho "the fire worked around the denials"\nexit ${FAKE_EXIT:-0}\n' > ${D}/fakeclaude-ignoring
chmod +x ${D}/fakeclaude-ignoring
RC63=$(once32 ignoring ${D}/fakeclaude-ignoring)
[ "${RC63}" == "0" ] || fail "63: loop-once.sh exited ${RC63} for a completed fire whose claude ignored a rule (expected 0: the fire did its work): $(grep ' END ' ${D}/loop32-ignoring/loop.log)"
grep -qF -- 'FIRE 1 END rc=0 duration=' ${D}/loop32-ignoring/loop.log && grep -qF -- 'outcome=ok ignored-rule "/wd/loop/run-next-fire/apply_to_source.sh:*)"' ${D}/loop32-ignoring/loop.log \
	|| fail "63: the END line does not name the ignored rule after ok: $(grep ' END ' ${D}/loop32-ignoring/loop.log)"
grep -F -- 'ignored-rule' ${D}/loop32-ignoring/loop.log | grep -q 'apply_to_source.sh:\*)"$' || fail "63: the END line does not end with the quoted word: $(grep ' END ' ${D}/loop32-ignoring/loop.log)"
grep -q " rc=0 outcome=ok " ${D}/loop32-ignoring/loop.state || fail "63: the state's outcome word is not ok (loop-once.sh records the first word only): $(cat ${D}/loop32-ignoring/loop.state)"
OUT63=$(AUTONOMY_LOOP_DIR=${D}/loop32-ignoring "${AGENT_DIR}/agent-status.sh" 2>/dev/null)
echo "${OUT63}" | grep -q "claude ignored an allow rule of the last fire's options" || fail "63: agent-status.sh does not name the ignored rule: ${OUT63}"
echo "${OUT63}" | grep -q "did NO work" && fail "63: agent-status.sh says a completed fire did no work: ${OUT63}"
RC63=$(FAKE_EXIT=124 once32 ignoring-timeout ${D}/fakeclaude-ignoring)
[ "${RC63}" == "124" ] || fail "63: loop-once.sh exited ${RC63} for a timed-out fire whose claude ignored a rule (expected 124): $(grep ' END ' ${D}/loop32-ignoring-timeout/loop.log)"
grep -qF -- 'outcome=timeout exit status 124 ignored-rule "/wd/loop/run-next-fire/apply_to_source.sh:*)"' ${D}/loop32-ignoring-timeout/loop.log \
	|| fail "63: a timed-out fire whose claude ignored a rule does not keep timeout first: $(grep ' END ' ${D}/loop32-ignoring-timeout/loop.log)"
echo "ok 63 - claude's own Ignoring line in a transcript is named on the END line (outcome=ok ignored-rule \"<word>\"): a completed fire stays rc=0, not 97, and agent-status.sh says the rule was ignored; a fire that also timed out keeps timeout first"

# --- 30. the chat responder reads the same file: a word that cannot be a rule answers without the model (ok 64) ---
# SLACK_CHAT_CLAUDE_OPTS with the operator's refused word: CHAT START reports it, a message that needs the model gets one
# honest line with no model call (CHAT MODEL rc=96 duration=0s posted=no config=<report>, the report as the transcript),
# the status fast path still answers, and the responder stays up; AUTONOMY_LOOP_OPTS_CHECK=false calls the model with the
# words as written and a CHAT WARNING names the word; a rule with a space is one argument of the responder's call.
stub_post_with()
{
	# stub_post_with <text fragment> - how many of the stub's posts hold the fragment
	curl -s -H "Authorization: Bearer x" "${SLACK_API_BASE}/stub.state" | "${NODE_BIN}" -e '
let raw=""; process.stdin.on("data",d=>raw+=d);
process.stdin.on("end",()=>console.log(JSON.parse(raw).posts.filter(x => (x.text || "").includes(process.argv[1])).length));' "$1"
}
chat64()
{
	# chat64 <state dir> <message text> <options> [NAME=value ...]: the responder in the background (CHAT_PID) on a planted
	# inbox holding that message (its ts in M64) and then "status" (ST64); called plainly, never in a command substitution -
	# the background job and the variables set here must reach this shell
	S64=$1; T64=$2; O64=$3; shift 3
	mkdir -p ${D}/${S64}
	cp ${SLACK_DIR}/identity ${D}/${S64}/identity
	M64=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=$(printf '%s' "${T64}" | tr ' ' '+')" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
	ST64=$(curl -s "${SLACK_API_BASE}/stub.seedMessage?text=status" | sed -n 's/.*"ts":"\([0-9.]*\)".*/\1/p')
	{ [ -n "${M64}" ] && [ -n "${ST64}" ]; } || fail "check 64: the stub did not seed the two messages"
	printf '{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"%s"}\n{"ts":"%s","channel":"C0TESTCHAN","user":"U0PERSON","text":"status"}\n' "${M64}" "${T64}" "${ST64}" > ${D}/${S64}/inbox.jsonl
	export FAKE_PROMPT_OUT=${D}/${S64}/chat-prompt.txt
	export FAKE_ARGV_OUT=${D}/${S64}/chat-argv.txt
	rm -f "${FAKE_PROMPT_OUT:?}" "${FAKE_ARGV_OUT:?}"
	env "$@" SLACK_DIR=${D}/${S64} ${CHAT_ENV} SLACK_CHAT_POLL_INTERVAL=1 SLACK_WATCH_BIN=/bin/true CLAUDE_BIN=${D}/fakeclaude SLACK_CHAT_CLAUDE_OPTS="${O64}" \
		AUTONOMY_LOOP_DIR=${D}/loop11 AUTONOMY_LOOP_WORKDIR=${D}/loop11 AUTONOMY_LOOP_GOALS=${D}/loop11/GOALS.md \
		"${CHAT}" > ${D}/${S64}.out 2>&1 &
	CHAT_PID=$!
}
chat64_stop()
{
	SLACK_DIR=${D}/$1 "${AGENT_DIR}/slack-chat-stop.sh" --now > /dev/null 2>&1
	wait "${CHAT_PID}" 2>/dev/null; CHAT_PID=""
}
# the stub ended with check 56: a fresh one for the responder here, on a new port (SLACK_API_BASE re-exported for the
# scripts and the helpers; the identity file does not depend on it)
"${NODE_BIN}" ${D}/stub.js > ${D}/stub64.out 2>&1 &
STUB_PID=$!
WAITED=0
while ! grep -q "^LISTENING" ${D}/stub64.out 2>/dev/null; do
	[ ${WAITED} -ge 20 ] && fail "64: the stub did not start: $(cat ${D}/stub64.out 2>/dev/null)"
	sleep 0.5
	WAITED=$((WAITED + 1))
done
export SLACK_API_BASE="http://127.0.0.1:$(grep '^LISTENING' ${D}/stub64.out | awk '{print $2}')/api"
P0=$(stub_posted)
chat64 state-opts "what is the plan" "${BAD62}"
wait_for_line 15 "CHAT REPLY ts=${ST64} kind=status ok posted=" ${D}/state-opts/chat.log \
	|| chat_fail "64: the status message behind the model message was not answered within 15 s (responder alive: $(kill -0 ${CHAT_PID} 2>/dev/null && echo yes || echo no)): $(tail -5 ${D}/state-opts/chat.log ${D}/state-opts.out 2>/dev/null | tr '\n' ' ' | cut -c1-600)"
grep -qF -- "CHAT CONFIG SLACK_CHAT_CLAUDE_OPTS: the word ${WORD62} cannot be a rule: its parentheses do not pair up" ${D}/state-opts/chat.log || chat_fail "64: CHAT START did not report the word: $(head -3 ${D}/state-opts/chat.log)"
{ grep -qE "CHAT MODEL ts=${M64} rc=96 duration=[0-9]s posted=no config=" ${D}/state-opts/chat.log \
	&& grep -qF -- "posted=no config=the word ${WORD62} cannot be a rule" ${D}/state-opts/chat.log; } \
	|| chat_fail "64: the model line does not say rc=96, a duration of seconds, config=<report>: $(grep 'CHAT MODEL' ${D}/state-opts/chat.log)"
grep -q "CHAT REPLY ts=${M64} kind=model-fallback ok posted=" ${D}/state-opts/chat.log || chat_fail "64: the message was not answered with the honest line: $(grep "ts=${M64}" ${D}/state-opts/chat.log)"
[ ! -f ${FAKE_PROMPT_OUT} ] || chat_fail "64: the model WAS called although the options hold a word that cannot be a rule: $(head -c 200 ${FAKE_PROMPT_OUT})"
grep -qF -- "REPLY SKIPPED, no claude call: SLACK_CHAT_CLAUDE_OPTS holds a word that cannot be a rule - the word ${WORD62}" ${D}/state-opts/chat/C0TESTCHAN-${M64}.out || chat_fail "64: the transcript does not carry the report: $(cat ${D}/state-opts/chat/C0TESTCHAN-${M64}.out 2>/dev/null)"
[ "$(stub_post_with "no model call was made, because the responder's claude options hold a word that cannot be a rule - \`the word ${WORD62}")" = "1" ] \
	|| chat_fail "64: the honest line did not reach the stub once: $(stub_last_post text | cut -c1-200)"
[ "$(( $(stub_posted) - P0 ))" = "2" ] || chat_fail "64: $(( $(stub_posted) - P0 )) post(s) landed, not the honest line and the status reply"
kill -0 ${CHAT_PID} 2>/dev/null || chat_fail "64: the responder is not alive after the skipped reply"
chat64_stop state-opts
# the knob off: the model IS called with the words as written, a CHAT WARNING names the word, the reply is the model's
chat64 state-opts2 "what is the plan now" "${BAD62}" AUTONOMY_LOOP_OPTS_CHECK=false
wait_for_line 15 "CHAT REPLY ts=${M64} kind=model ok posted=" ${D}/state-opts2/chat.log \
	|| chat_fail "64: with AUTONOMY_LOOP_OPTS_CHECK=false the model message was not answered by the model within 15 s: $(tail -5 ${D}/state-opts2/chat.log ${D}/state-opts2.out 2>/dev/null | tr '\n' ' ' | cut -c1-600)"
grep -qF -- "CHAT WARNING SLACK_CHAT_CLAUDE_OPTS: the word ${WORD62} cannot be a rule" ${D}/state-opts2/chat.log || chat_fail "64: with the check off no CHAT WARNING names the word: $(head -3 ${D}/state-opts2/chat.log)"
cmp -s ${D}/argv62.expected ${FAKE_ARGV_OUT} || chat_fail "64: with the check off the responder's claude did not get the words as written: $(tr '\n' '|' < ${FAKE_ARGV_OUT} 2>/dev/null)"
chat64_stop state-opts2
# a rule with a space: one argument of the responder's call, nothing reported
chat64 state-opts3 "what is the plan today" "${OPTS61}"
wait_for_line 15 "CHAT REPLY ts=${M64} kind=model ok posted=" ${D}/state-opts3/chat.log \
	|| chat_fail "64: with a spaced rule the model message was not answered within 15 s: $(tail -5 ${D}/state-opts3/chat.log ${D}/state-opts3.out 2>/dev/null | tr '\n' ' ' | cut -c1-600)"
cmp -s ${D}/argv61.expected ${FAKE_ARGV_OUT} || chat_fail "64: the responder's claude did not get the spaced rule as one argument: $(tr '\n' '|' < ${FAKE_ARGV_OUT} 2>/dev/null)"
grep -q "CHAT CONFIG SLACK_CHAT_CLAUDE_OPTS:\|CHAT WARNING SLACK_CHAT_CLAUDE_OPTS:" ${D}/state-opts3/chat.log && chat_fail "64: a responder value whose every word can be a rule was reported: $(grep 'SLACK_CHAT_CLAUDE_OPTS:' ${D}/state-opts3/chat.log)"
chat64_stop state-opts3
# --- 65. a credential in a post's text is masked before it is sent (/agent/redact.py); the read-back verifies the masked text ---
# the planted token is assembled at run time, so no credential-shaped string is in this file
PLANTED="xo""xb-4815162342-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
OUT=$(SLACK_POST_ENABLED=true "${AGENT_DIR}/slack-post.sh" C0TESTCHAN "rotated the bot token: ${PLANTED} (done)" 2>&1) || fail "65: post with a planted token: ${OUT}"
echo "${OUT}" | grep -q "read-back verified" || fail "65: the masked post did not read-back verify: ${OUT}"
LAST=$(stub_last_post text)
case "${LAST}" in *"${PLANTED}"*) fail "65: a planted Slack token reached the channel unmasked" ;; esac
[ "${LAST}" == "rotated the bot token: [redacted] (done)" ] || fail "65: the posted text is not the text with the token masked: ${LAST}"
kill "${STUB_PID}" 2>/dev/null
echo "ok 64 - the chat responder: a word that cannot be a rule in SLACK_CHAT_CLAUDE_OPTS is reported at CHAT START, each message that needs the model gets one honest line with no model call (CHAT MODEL rc=96 config=<report>, the report as the transcript) while status is still answered and the responder stays up; AUTONOMY_LOOP_OPTS_CHECK=false calls the model with the words as written and a CHAT WARNING names the word; a rule with a space is one argument of the responder's call"

echo "ok 65 - a credential in a post's text is masked before it reaches the channel; the read-back verifies the masked text"
echo "Test4 succeeded"
