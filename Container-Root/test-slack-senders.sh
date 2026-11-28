#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of who may drive the agent through Slack: /agent/slack-watch.sh puts in the inbox
# only the messages of the people SLACK_ALLOWED_USERS names (empty, the shipped default: no one; anyone: every
# person), never another bot's, and the agent's own posts as before; /agent/slack-chat.sh, /agent/loop.sh and
# /agent/loop-once.sh default to the safe option values, --dangerously-skip-permissions being the opt-in. Offline: a
# local Slack stub (127.0.0.1:18321). Each check FAILS on what it guards:
#   1. syntax; the three scripts' shipped option defaults are the safe values, word for word
#   2. SLACK_ALLOWED_USERS unset: no person's message reaches the inbox (the agent's own post does), the run says why
#      on stderr, the cursor still moves past every message read
#   3. SLACK_ALLOWED_USERS=<one person>: that person's top-level message and their reply in a stranger's thread are
#      taken; the stranger's messages and two other bots' (bot_id; subtype bot_message) are not, and the run counts them
#   4. SLACK_ALLOWED_USERS=anyone: every person's message, still no other bot's
#   5. a value that is neither user IDs nor the word anyone alone stops the watch (exit 1), naming the setting
#   6. PLANTED CONTROL: a watcher without the filter puts the stranger's message in the inbox (check 3 can tell)
# Test-local: TEST_SLACK_SENDERS_DIR (default /tmp/slack-senders-smoke); never /wd.

AGENT_DIR=${AGENT_DIR:-/agent}
D=${TEST_SLACK_SENDERS_DIR:-/tmp/slack-senders-smoke}
PORT=18321
STUB_PID=""
cleanup() { [ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2> /dev/null; }
fail() { echo "Test-slack-senders FAILED: $*"; cleanup; exit 1; }
trap cleanup EXIT
rm -rf "${D:?}" && mkdir -p "${D}" || fail "cannot create ${D}"

# 1. syntax and the shipped defaults
for S in slack-watch.sh slack-chat.sh loop.sh loop-once.sh; do bash -n "${AGENT_DIR}/${S}" || fail "1: ${S}"; done
LOOP_SAFE='--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits'
CHAT_SAFE='--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/goals-add.sh:*) --permission-mode acceptEdits'
grep -qxF "SLACK_CHAT_CLAUDE_OPTS=\${SLACK_CHAT_CLAUDE_OPTS:-\"${CHAT_SAFE}\"}" "${AGENT_DIR}/slack-chat.sh" \
	|| fail "1: slack-chat.sh does not default SLACK_CHAT_CLAUDE_OPTS to the safe value"
for S in loop.sh loop-once.sh; do
	grep -qxF "AUTONOMY_LOOP_CLAUDE_OPTS=\${AUTONOMY_LOOP_CLAUDE_OPTS:-\"${LOOP_SAFE}\"}" "${AGENT_DIR}/${S}" \
		|| fail "1: ${S} does not default AUTONOMY_LOOP_CLAUDE_OPTS to the safe value"
done
echo "ok 1 - syntax; the responder and both loops default to their safe values (the permission bypass is an opt-in)"

# the stub: auth.test, conversations.history and conversations.replies of one channel, newest first, honouring oldest
cat > "${D}/stub.py" << 'PY'
import http.server, json, sys, urllib.parse
B = sys.argv[2]   # the messages are minutes old: an old thread would be retired from the registry, unpolled
PARENT = {"ts": B + ".000400", "user": "U0STRANGER", "text": "stranger's thread", "reply_count": 1, "thread_ts": B + ".000400"}
REPLY = {"ts": B + ".000500", "user": "U0ALLOWED", "text": "allowed reply in the stranger's thread", "thread_ts": B + ".000400"}
HISTORY = [
    {"ts": B + ".000700", "user": "U0AGENT", "bot_id": "B0AGENT", "text": "the agent's own post"},
    {"ts": B + ".000600", "bot_id": "B0OTHER", "subtype": "bot_message", "text": "another bot, no user"},
    {"ts": B + ".000300", "user": "U0OTHERBOT", "bot_id": "B0OTHER2", "text": "another bot with a user field"},
    PARENT,
    {"ts": B + ".000200", "user": "U0STRANGER", "text": "stranger top-level"},
    {"ts": B + ".000100", "user": "U0ALLOWED", "text": "allowed top-level"},
]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path); q = dict(urllib.parse.parse_qsl(u.query)); m = u.path.rsplit("/", 1)[-1]
        if m == "auth.test":
            body = {"ok": True, "user_id": "U0AGENT", "team": "T0TEST", "user": "agent"}
        elif m == "conversations.history":
            body = {"ok": True, "messages": [x for x in HISTORY if float(x["ts"]) > float(q.get("oldest", "0"))], "has_more": False}
        elif m == "conversations.replies":
            body = {"ok": True, "messages": [PARENT, REPLY] if q.get("ts") == PARENT["ts"] else [], "has_more": False}
        else:
            body = {"ok": False, "error": "unknown_method"}
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
BASE=$(( $(date +%s) - 600 ))
python3 -I "${D}/stub.py" ${PORT} ${BASE} > "${D}/stub.log" 2>&1 &
STUB_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:${PORT}/auth.test" && break; sleep 0.1; done

watch()
{
	# watch <state dir> <script> [VAR=value ...] - one watch run against the stub from a cursor before every message
	local S=$1 W=$2; shift 2
	mkdir -p "${S}"; echo "$(( BASE - 100 )).000000" > "${S}/cursor-C0TEST"
	env -u SLACK_ALLOWED_USERS "$@" SLACK_API_BASE="http://127.0.0.1:${PORT}" SLACK_BOT_TOKEN=xoxb-stub SLACK_CHANNELS=C0TEST \
		SLACK_DIR="${S}" bash "${W}" > "${S}/out" 2> "${S}/err"
}
texts() { python3 -I -c 'import json,sys; [print(json.loads(l)["text"]) for l in open(sys.argv[1]) if l.strip()]' "$1/inbox.jsonl" 2> /dev/null | sort; }

# 2. the shipped default: no one
watch "${D}/none" "${AGENT_DIR}/slack-watch.sh" || fail "2: the watch failed: $(tail -3 "${D}/none/err")"
[ "$(texts "${D}/none")" == "the agent's own post" ] || fail "2: with SLACK_ALLOWED_USERS unset the inbox holds: $(texts "${D}/none" | tr '\n' '|')"
grep -q "WARNING: SLACK_ALLOWED_USERS is empty" "${D}/none/err" || fail "2: the run does not say why no message was taken: $(cat "${D}/none/err")"
[ "$(cat "${D}/none/cursor-C0TEST")" == "${BASE}.000700" ] || fail "2: the cursor did not move past the messages read ($(cat "${D}/none/cursor-C0TEST"))"
echo "ok 2 - SLACK_ALLOWED_USERS unset: no person's message reaches the inbox (the agent's own post does), with a WARNING; the cursor moves past them"

# 3. one person
watch "${D}/one" "${AGENT_DIR}/slack-watch.sh" SLACK_ALLOWED_USERS=U0ALLOWED || fail "3: the watch failed: $(tail -3 "${D}/one/err")"
WANT=$(printf '%s\n' "allowed reply in the stranger's thread" "allowed top-level" "the agent's own post" | sort)
[ "$(texts "${D}/one")" == "${WANT}" ] || fail "3: with SLACK_ALLOWED_USERS=U0ALLOWED the inbox holds: $(texts "${D}/one" | tr '\n' '|')"
grep -q "2 not taken (sender not in SLACK_ALLOWED_USERS), 2 not taken (another bot)" "${D}/one/out" || fail "3: the run does not count what it did not take: $(grep '^Channel' "${D}/one/out")"
grep -q "^${BASE}.000400 " "${D}/one/threads-C0TEST" || fail "3: the stranger's thread is not in the registry (an allowed reply in it would be lost)"
echo "ok 3 - SLACK_ALLOWED_USERS=U0ALLOWED: that person's message and reply are taken; the stranger's and two other bots' are not, and are counted"

# 4. anyone
watch "${D}/any" "${AGENT_DIR}/slack-watch.sh" SLACK_ALLOWED_USERS=anyone || fail "4: the watch failed: $(tail -3 "${D}/any/err")"
WANT=$(printf '%s\n' "allowed reply in the stranger's thread" "allowed top-level" "stranger top-level" "stranger's thread" "the agent's own post" | sort)
[ "$(texts "${D}/any")" == "${WANT}" ] || fail "4: with SLACK_ALLOWED_USERS=anyone the inbox holds: $(texts "${D}/any" | tr '\n' '|')"
echo "ok 4 - SLACK_ALLOWED_USERS=anyone: every person's message, no other bot's"

# 5. a value that is not a list of user IDs
for V in "U0ALLOWED,bob" "anyone,U0ALLOWED" "u0lower"; do
	watch "${D}/bad" "${AGENT_DIR}/slack-watch.sh" SLACK_ALLOWED_USERS="${V}" && fail "5: SLACK_ALLOWED_USERS=${V} did not stop the watch"
	grep -q "SLACK_ALLOWED_USERS" "${D}/bad/err" || fail "5: SLACK_ALLOWED_USERS=${V}: the error does not name the setting: $(cat "${D}/bad/err")"
	rm -rf "${D:?}/bad"
done
echo "ok 5 - a value that is neither user IDs nor anyone alone stops the watch with an error naming the setting"

# 6. PLANTED CONTROL: without the filter the stranger's message is taken
sed "s/awk -F '\\\\t' '\$4 == \"\"' \"\${BATCH}.all\" | cut -f3 > \"\${BATCH}\"/cut -f3 \"\${BATCH}.all\" > \"\${BATCH}\"/" \
	"${AGENT_DIR}/slack-watch.sh" > "${D}/watch-nofilter.sh"
cmp -s "${AGENT_DIR}/slack-watch.sh" "${D}/watch-nofilter.sh" && fail "6: the planted copy is identical to slack-watch.sh (the filter line moved?)"
watch "${D}/nofilter" "${D}/watch-nofilter.sh" SLACK_ALLOWED_USERS=U0ALLOWED || fail "6: the planted watch failed: $(tail -3 "${D}/nofilter/err")"
texts "${D}/nofilter" | grep -qx "stranger top-level" || fail "6: PLANTED CONTROL: without the filter the stranger's message still did not reach the inbox"
echo "ok 6 - PLANTED CONTROL: a watcher without the filter takes the stranger's message"

cleanup; STUB_PID=""
rm -rf "${D:?}"
echo "Test-slack-senders succeeded"
