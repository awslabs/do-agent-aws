# Connecting the agent to Slack channels

This document walks through connecting do-agent-aws to Slack channels: creating the Slack app,
granting the scopes, configuring `.env`, and **verifying at every stage that a message actually
arrives**. A bot token and a channel
list are enough: with `SLACK_BOT_TOKEN` and `SLACK_CHANNELS` set the chat responder and the autonomy
loop start with the container - the responder answers messages as they arrive (section 6a), the loop
works on the goals stated in them; with nothing set no Slack code runs and the container behaves
exactly as before.

Two principles up front:

* **The bot posts as ITSELF** - the Slack app identity you create below - never as you or any
  other person. Every message it sends is visibly attributed to the app.
* **Chatting, watching and posting are separate gates.** All are on once a token and channels are
  set (`SLACK_CHAT_ENABLED`, `SLACK_WATCH_ENABLED` and `SLACK_POST_ENABLED` are `auto` in the
  shipped `.env`); `SLACK_POST_ENABLED=false` keeps the agent read-only - it watches and never posts
  - and `/agent/slack-post.sh` refuses any target channel that is not one of the watched
  `SLACK_CHANNELS`.

**Two different features talk to Slack - do not conflate them.** *This* page is the **agent's
own** Slack access: `/agent/slack-watch.sh` polls channels into `/wd/slack/inbox.jsonl`, the chat
responder `/agent/slack-chat.sh` answers them (or, with the responder off, the autonomy loop's fires
do), and `/agent/slack-post.sh` (separately gated) posts as the bot. The **comms UI**
([docs/comms/README.md](../comms/README.md)) is a different feature: an operator dashboard built
on the communication engine, configured through its own `/wd/comms/settings.json`, that watches
channels for a *human* to read - it never posts to a real platform. The same Slack app and bot
token can serve both ([docs/comms/slack.md](../comms/slack.md) maps the exact fields), but they
keep separate state and separate cursors - and they differ on first contact: this watcher starts
at *now* (no backfill), the comms engine's first poll backfills the channel's visible history.

## The words this document uses

| Term | Meaning |
|------|---------|
| **Bot token** (`xoxb-...`) | The credential of a Slack *app's* bot user, issued when the app is installed to a workspace. Acts as the app's own identity. This is what `SLACK_BOT_TOKEN` expects. |
| **User token** (`xoxp-...`) | A credential that acts *as a person* - reads what they can read, posts as them. Only relevant here as the corporate-workspace fallback in section 2, and then read-only. |
| **App-level token** (`xapp-...`) | A third token type used only for Slack's Socket Mode (websocket event delivery). Nothing on this page needs one; the comms engine's optional `slack_socket` channel does ([docs/comms/slack-socket.md](../comms/slack-socket.md)). |
| **Channel ID** (`C...`/`G...`/`D...`) | The immutable identifier of a channel, e.g. `C0123ABCDEF`. **Not the channel name** - `#general` is a display name; the API wants the ID. `SLACK_CHANNELS` takes IDs only. |
| **Workspace you own** | A workspace where you are an owner/admin: you can create and install apps yourself. Section 1 assumes this. |
| **Organization-managed workspace** | A workspace whose owners (or, on Slack Enterprise Grid, the org admins) control app installation - typical for corporate Slack. Installing an app there usually requires an approval step you cannot perform yourself. Section 2 covers it. |

## 1. Create your Slack app and bot token (a workspace you own)

A ready-made app manifest ships with the harness-setup skill, and `/setup` prints it:
`Container-Root/agent/skills/harness-setup/slack-app-manifest.yaml`. It asks for the read scopes the harness uses, each
justified in a comment. `chat:write` and `files:write` are its two opt-ins: an agent that answers in Slack, and one that
attaches a file there (section 9a). Create the app from it
(**Create New App** → *From an app manifest*), or from scratch as below. Either way, `/agent/slack-doctor.sh` in the
container checks the installed token's scopes against that manifest, and each channel in `SLACK_CHANNELS`.

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → *From scratch*.
   Pick a name (this is the identity the bot posts under) and your workspace.
2. **OAuth & Permissions** → *Scopes* → **Bot Token Scopes** - add:
   * `channels:history`, `groups:history`, `im:history`, `mpim:history` - read messages in the public channels, private
     channels, DMs and group DMs the bot is in
   * `channels:read`, `groups:read`, `im:read`, `mpim:read` - channel id <-> name, for the dashboard and the doctor
   * `users:read` - sender names on the dashboard
   * `chat:write` - post messages as the bot (only if the agent should answer in Slack; see the note below)
   * `files:write` - attach a file as the bot with `/agent/slack-upload.sh` (section 9a; only if the agent should hand
     over charts or reports in Slack). Adding a scope to an installed app takes effect on **reinstall**, and the doctor
     reads the granted scopes from the live token (`auth.test`), never from the manifest file

   These are the manifest's scopes, the ones `/agent/slack-doctor.sh` checks for.

   **Posting is on by default once Slack is configured.** With `SLACK_BOT_TOKEN` and `SLACK_CHANNELS` set, the post and
   chat gates (`SLACK_POST_ENABLED`, `SLACK_CHAT_ENABLED`, default `auto`) turn on, whether or not the app has
   `chat:write`. Either grant `chat:write` (the manifest has it commented out) or set both gates to `false` in
   `.env.local` for a read-only install; otherwise the agent's answers fail with `missing_scope`.
3. **Install App** → *Install to Workspace* → authorize. Copy the **Bot User OAuth Token**
   (`xoxb-...`). This token is yours; treat it like a password and never commit it.

**Verify this stage:** the token authenticates before anything else is configured -

```sh
printf 'header = "Authorization: Bearer %s"\n' "$SLACK_BOT_TOKEN" | curl -s -K - https://slack.com/api/auth.test
```

The header goes to curl through its config on stdin (`-K -`; `printf` is a shell builtin), so the
token is never on a command line, where any local user could read it in `ps`; the agent's scripts
pass it the same way.

Expect `"ok":true` with a `user_id` and your team name. `"ok":false,"error":"invalid_auth"`
means the token is wrong or truncated - fix it now, before it is buried in a container.

## 2. Connecting to an organization-managed (corporate) workspace

On a corporate workspace the section-1 flow usually stops at step 3: **Install to Workspace**
is replaced by a *request* step, because the workspace requires app approval. This is Slack's
documented behavior, not a bug in this harness: when approval is required, a member can submit
the app for review (if the owners allow requests at all), and a Workspace Owner or App Manager
approves or restricts it in the workspace's App Management settings. On Slack Enterprise Grid
(most large corporations), an org-level app policy can govern every workspace in the
organization. See Slack's own pages:
[Manage app approval for your workspace](https://slack.com/help/articles/222386767-Manage-app-approval-for-your-workspace)
and [api.slack.com/apps](https://api.slack.com/apps).

So there are two workable paths - pick deliberately:

**Path A - request approval for your app (the right way for ongoing use).** Create the app as
in section 1, submit the install request, and tell the approving admin exactly what it is: the
four read scopes above (plus `chat:write` only if posting is wanted), which channels it will be
invited to, and that it acts under its own bot identity. After approval you get the same
`xoxb-` token as section 1 and everything below applies unchanged. The cost: an admin is in the
loop, and approval can take time or be refused.

**Path B - a user token, READ-ONLY, as a stopgap.** Technically the watcher only needs a token
that passes `auth.test` and can call `conversations.history`. A **user token** (`xoxp-`, user
scopes `channels:history`, `groups:history`, `im:history`) satisfies that - it reads the
channels *you* can read, no bot invite needed. Two hard caveats:

* The token acts **as you**. Reading is done in your name, and if posting were enabled the
  agent would post **as you** - so with a user token, set `SLACK_POST_ENABLED=false` explicitly:
  it is a **hard rule**, and the shipped `auto` default would otherwise turn posting on as soon as
  the channels are set. Watching only.
* Check your organization's policy before doing this. A user token wired into an autonomous
  agent may be exactly what your security team wants to know about first. Path B is a
  documented technical possibility, not a recommendation to route around app approval.

Which is right for you: **own workspace → section 1. Corporate, ongoing → Path A. Corporate,
read-only evaluation while approval is pending, policy permitting → Path B** (and switch to the
bot token when Path A lands, so the identity in channels is the app, not you).

## 3. Invite the bot and collect channel IDs

* In each channel the agent should watch, invite the bot: `/invite @<your-app-name>`.
  (Path B user tokens skip this - a user token reads what the user can already read.)
* Get the channel ID (a `C...` string, not the channel name): open the channel → click the
  channel name → *About* tab → the ID is at the bottom; it is also the last path segment of a
  channel link (`https://<workspace>.slack.com/archives/C0123ABCDEF`).

## 4. Configure `.env` - and restart, because the environment is baked at `docker run`

The bot token is a credential: put it in the AWS Secrets Manager secret the container reads at start
(docs/manual/aws.md "Credentials from AWS Secrets Manager": add `SLACK_BOT_TOKEN` to the secret's JSON and set `AGENT_SECRETS_ID`
in `.env.local`). The channel list is a plain setting:

```bash
export AGENT_SECRETS_ID=do-agent-aws/credentials   # the secret holds SLACK_BOT_TOKEN
export SLACK_CHANNELS="C0123ABCDEF,C0456GHIJKL"
```

For a quick local trial, `export SLACK_BOT_TOKEN=...` in the host shell before `./run.sh` works too; the container
then logs a `WARNING: secrets: SLACK_BOT_TOKEN comes from the container environment` line at start.

Nothing else: `SLACK_CHAT_ENABLED`, `AUTONOMY_LOOP`, `SLACK_WATCH_ENABLED` and `SLACK_POST_ENABLED`
are `auto` in the shipped `.env`, which means on once the two lines above are set. Opt out of a part
with an explicit `false` (`true` forces a part on regardless of the token):

```bash
export SLACK_CHAT_ENABLED=false     # no chat responder; the loop's own per-cycle watch is the intake (section 6)
export AUTONOMY_LOOP=false          # no loop - goals stated in chat are recorded but not worked on
export SLACK_WATCH_ENABLED=false    # a loop without Slack (matters only with the responder off)
export SLACK_POST_ENABLED=false     # watch only: the agent never posts (a hard rule with a user token)
```

Two more settings tune the responder: `SLACK_CHAT_POLL_INTERVAL` (seconds between polls, default 5)
and `SLACK_CHAT_TIMEOUT` (per-reply model timeout, default 1500) - section 6a.

Two asymmetries worth knowing:

* The **token** may be exported in the host shell instead of written here - `run.sh` passes it
  with a bare `-e SLACK_BOT_TOKEN` (value resolved from the environment, never echoed in the
  docker command - the same pattern the AWS credentials use). The **channel list is read from
  this file** (`SLACK_CHANNELS=...` is passed by value), so put the IDs in `.env.local` (docs/manual/install.md "Settings").
* **A `.env` edit does nothing to a running container.** The environment is fixed when
  `docker run` executes, so after any change here:

```sh
./stop.sh && ./run.sh
```

The compose template mirrors the same variables; on kubernetes the token belongs in the
optional secret `<app>-slack` (see the comment in `to/kubernetes/template/020-deployment.yaml`).

**Verify this stage:**

```sh
docker exec do-agent-aws /agent/slack-status.sh
```

Expect `token: configured (value not shown)`, your channel IDs, and four gate lines each ending in
`(effective: on - token and channels set)` - the loop autostart, the watch, the post and the chat
gate, as decided by `/agent/slack-gates.sh` (run it directly for just those four lines). Know what this does
and does not tell you: `slack-status.sh` **makes no Slack API call** - it reports configuration and local
state only. It cannot detect a bad token, a bot that was never invited, a channel *name* typed
where an ID is needed, or a missing scope. The first command that can is the watch below.

## 5. See a message arrive - the manual verification ladder

Run these four steps once after setup; each has a stated expected output. (This exact ladder,
stub-backed, is `test10.sh`'s section 3 - the doc and the test cannot drift apart silently.)

**Step 1 - one manual poll.** The first watch of a channel initializes its cursor to *now*:
history is **not** backfilled, so `0 new` on a first watch is correct behavior, not a failure. A watch
run by hand is safe beside the running responder or loop: every writer of the inbox takes the same lock
(`/wd/slack/inbox.lock`) around its append or removal.

```sh
docker exec do-agent-aws /agent/slack-watch.sh
```

Expect, per channel:

```
Channel C0123ABCDEF: cursor initialized to now (176...); watching messages from this point on
Channel C0123ABCDEF: 0 new message(s), 0 thread reply(ies); cursor=176... threads=0
Watch complete: <UTC> new=0 replies=0 inbox=0
```

Any `ERROR:` line here instead is diagnosable in the troubleshooting table below.

**Step 2 - post a test message yourself** in the watched channel, as yourself, e.g.
`test message for the agent`.

**Step 3 - poll again:**

```sh
docker exec do-agent-aws /agent/slack-watch.sh
```

Expect `1 new message(s)` and `inbox=1`.

**Step 4 - see the message itself:**

```sh
docker exec do-agent-aws cat /wd/slack/inbox.jsonl
```

Expect one JSON line with your channel, your user ID, and the text you typed. **This is the
proof the connection works.** Everything past this point is wiring, not connectivity. (Run this
ladder with the chat responder stopped - `docker exec do-agent-aws /agent/slack-chat-stop.sh` - or
your message is answered and moved to `processed.jsonl` before step 4 reads the inbox; that, too,
is proof.)

## 6. Automatic operation - who takes messages in

Nothing here starts a separate poller process for the watch gate alone. Two things can run
`/agent/slack-watch.sh` automatically, and the chat gate decides which:

* **The chat responder** (`SLACK_CHAT_ENABLED` at its `auto` default with a token and channels
  set - section 6a). While it runs it is the **only** consumer of `/wd/slack/inbox.jsonl`: it polls
  every `SLACK_CHAT_POLL_INTERVAL` seconds, answers each message, and moves the line to
  `processed.jsonl` once an answer landed (a post that landed nothing keeps the line first in the inbox
  for another attempt next poll, `SLACK_CHAT_POST_RETRIES` attempts in all, default 3; past that the line
  is set aside in `/wd/slack/unanswered.jsonl`, logged `CHAT UNANSWERED` with that path, so that a
  message is never marked processed without an answer). The autonomy loop then runs no watch of its own and hands no Slack messages to
  its fires; it logs `LOOP SLACK intake owned by /agent/slack-chat.sh ...` once at start, works on
  `/wd/goals/GOALS.md` alone, and with no goals file idles with the plain
  `LOOP IDLE goals file /wd/goals/GOALS.md not found` line and no claude call. A goal stated in chat
  reaches the loop through the goals file (section 6a).
* **The autonomy loop's own watch - the fallback when chat is off** (`SLACK_CHAT_ENABLED=false`).
  Every loop cycle runs `/agent/slack-watch.sh` first - whether or not a goals file exists - and
  then decides what to fire against: the goals file `/wd/goals/GOALS.md` when it exists (docs/manual/autonomy.md
  "Autonomy loop"), the fire getting the unprocessed inbox lines as context; otherwise, when the
  inbox holds new messages, the shipped default goals `/agent/goals-default.md` - one standing goal
  that answers the messages (posting only through `/agent/slack-post.sh`, behind its own gate) and,
  when a message states a goal, creates `/wd/goals/GOALS.md` so the next cycle fires on it;
  otherwise nothing: `LOOP IDLE goals file /wd/goals/GOALS.md not found; Slack watch ran, inbox
  empty - the loop fires on the next Slack message or when the goals file appears` in `loop.log`,
  and no claude call - an idle cycle costs one Slack poll. In this mode a reply waits for the next
  loop cycle (`AUTONOMY_LOOP_INTERVAL`), and `AUTONOMY_LOOP=false` stops the automatic watch with
  the loop.

Either way a goals file is not required for Slack to work. Note what this means: anyone who can
post in a watched channel can talk to the agent and, by stating a goal, have it written into the
goals file - a message is a request, never an authorization, and the operating rules still bind,
but keep `SLACK_CHANNELS` to channels whose members you would hand work to. The bot's own posts
also come back through the watch; the responder recognizes them by the identity recorded in
`/wd/slack/identity` and skips them (with chat off, a fire that ignores them costs one claude
call). `docker exec do-agent-aws /agent/slack-gates.sh` prints the four decisions with their
reasons, e.g. `chat gate: SLACK_CHAT_ENABLED=auto (effective: on - token and channels set)`. After
any `.env` change: `./stop.sh && ./run.sh`. Where to see it working:

* `docker exec do-agent-aws tail /wd/slack/chat.log` - the responder logs one `CHAT MSG` line per
  message it handles (with `kind=status|goals|help|model`), the `CHAT REPLY ... ok posted=<ts>` line
  after the read-back verified post, and `CHAT MODEL ... posted=yes|no transcript=<path>` for a
  model answer. `/wd/slack/chat-watch.log` is the watcher's own output from every poll, errors
  included.
* `docker exec do-agent-aws tail /wd/loop/loop.log` - with chat off, a fire logs `FIRE <n> SLACK
  context: <k> of <m> unprocessed message(s) included` when inbox lines were handed to the agent
  (at most `SLACK_LOOP_BATCH_MAX`, default 50, per fire), and its BEGIN line ends in `(default: no
  user goals file at /wd/goals/GOALS.md)` when it fired on the default goals; the watcher's output
  is then in `/wd/loop/slack-watch.log` (a failed watch is `LOOP SLACK WATCH FAILED` in `loop.log`,
  loud, never blocking the cycle).
* Handled lines move to `/wd/slack/processed.jsonl`. A fire's batch moves after a fire that ended well
  (rc 0 and no stale refusal). Otherwise - its answer refused as stale (a newer message arrived during
  the fire), a timeout, any other nonzero exit - the batch stays in the inbox and the next fire gets the
  same lines marked `CARRIED`, with the posts the fires so far did land listed so that it does not repeat
  them, up to `SLACK_LOOP_CARRY_MAX` carries (default 3); at the bound the next `SLACK_LOOP_BOUND_FIRES`
  fires (default 3) post without the newest-message check, the batch staying in the inbox, each such fire
  logging `carry bound reached` with the message count and the oldest ts; when none of them ends well the
  batch is set aside in `/wd/slack/unanswered.jsonl` - the side file the responder uses for a message it
  could not answer - logged `set aside` with the path, never in `processed.jsonl`. The note's list of
  landed posts keeps each post once and the newest `SLACK_LOOP_CARRY_POSTS_MAX` (default 20), the rest
  counted. Nothing is processed unanswered: a stall is visible in `loop.log` and ends with a fire that
  ends well or with the batch set aside. What a fire that ended well did with each message - posting off, a message it chose
  to skip - is not checked. Not repeating a listed post is the model's part. Every
  verified post is a line in `/wd/slack/posted.jsonl` (ts, channel, thread_ts, the first 200 characters
  of the text).

Whether and how to respond is the agent's decision; the ability to respond at all stays behind
`SLACK_POST_ENABLED`. The shipped fire and the shipped responder run with their safe values (docs/manual/autonomy.md "Autonomy
loop"; `--dangerously-skip-permissions` with `IS_SANDBOX=1` is the opt-in in `.env.local`). Under the safe value each claude call is allowed to run exactly the scripts it needs: the fire's call
`/agent/slack-post.sh` and `/agent/slack-upload.sh` (the safe `AUTONOMY_LOOP_CLAUDE_OPTS` is `--allowedTools
Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits`: the
two Slack scripts, the recall script and the bus command a fire answers its inbox with), the responder's call
`/agent/slack-post.sh`, `/agent/slack-upload.sh` and `/agent/goals-add.sh` (the safe `SLACK_CHAT_CLAUDE_OPTS`, its shipped
default; with the opt-in, every person `SLACK_ALLOWED_USERS` names can have the responder run commands in the container, with
the container's credentials). Only those people's messages reach the inbox at all: `SLACK_ALLOWED_USERS` (comma-separated
user IDs, or `anyone`; empty, the default, takes no one's), and never another bot's (docs/manual/channels.md "Slack connectivity"). Everything
else stays under `acceptEdits`, which in headless mode denies Bash calls outright. Two consequences:
an override of either variable that uses `acceptEdits` must keep its rules if the agent is meant to reply (and record
goals), and - because `--allowedTools` is variadic and swallows a positional prompt that follows it - both
pass their prompt on stdin, so no override order can lose it.

## 6a. Chatting with the agent

The responder (`/agent/slack-chat.sh`) is how you talk to the agent while the loop works. Post in
a watched channel - a plain message, or a reply in a thread; the answer comes back in the thread of
your message: in the thread when you wrote in one, and in a new thread under your message when you
wrote top-level - that thread is where the topic continues (your follow-ups there are collected and
answered there), so the channel's top level stays the list of topics. That placement is
`SLACK_REPLY_IN_THREAD` in `.env` (shipped `true`; only the value `false` turns it off:
`export SLACK_REPLY_IN_THREAD=false` in `.env.local` answers a top-level message top-level, where
you wrote; the same knob places the replies of a loop that takes
Slack in itself, section 9). A goal you state is recorded with the `ts` of your message's thread
root, so a later post about it can land in that thread; nothing posts progress on a goal by itself.
Three commands are answered **from the state files, with no
model call**, so they arrive within one poll interval:

| You write (case-insensitive; a leading `@bot` mention is ignored) | You get |
|---|---|
| `status` | `/agent/agent-status.sh`: the loop's state line, its last three log lines, completed fires, the last five progress notes, whether a goals file exists and how many items are open, the responder's state, the inbox counters |
| `goals`, `tasks`, `list goals`, `list tasks` | the goals file's headings and checkbox lines - or `no goals file yet - tell me a goal and I will add it` |
| `help` | this list |

**Anything else** goes to one headless claude call whose prompt carries your message, the same
status report, the first 200 lines of the goals file and the last 20 progress notes, with three
rules: answer with one short message through `/agent/slack-post.sh`; when the message states a goal
or task, record it with `/agent/goals-add.sh` and say so; edit nothing else and never create the
loop's stop flag. So "how far is the release-notes goal?" or "what are you working on?" are answered
from the current state, and "please write the release notes for v2" becomes the line
`- [ ] write the release notes for v2 (from Slack C... 1791...)` under `## Goals from Slack` in
`/wd/goals/GOALS.md` (the file is created when missing) - the loop fires on it from its next cycle.
If the loop is stopped (every earlier goal done, stop flag present) the answer says so; `docker exec
do-agent-aws /agent/loop-start.sh` starts it again. If the model call fails, times out, or posts
nothing, the responder posts one line itself - `I could not produce an answer: <first error line>`,
or the model's final text when it answered on stdout only - and logs it; you are never left waiting
silently.

**The latency floor.** A command answer takes one poll interval; a free-form answer takes one poll
interval plus one model call (a few seconds to a minute, bounded by `SLACK_CHAT_TIMEOUT`, default
1500 s). The loop's `AUTONOMY_LOOP_INTERVAL` is not part of it. `SLACK_CHAT_POLL_INTERVAL` (default
5 s) is the knob: every poll is one `conversations.history` call per watched channel plus one
`conversations.replies` call per registered thread (section 8), and at most once a minute up to 10
more for the recent top-level messages (section 8). Slack rates both methods in its
Tier 3 (about 50 calls per minute per method, per app and workspace); at the default, one channel
with a few live threads uses a fraction of that, and the responder honors an HTTP 429 by sleeping
Slack's `Retry-After` before polling again. Going below 2 s, or watching many channels with many
threads, is where that tier becomes the limit - lengthen the interval or retire threads sooner with
`SLACK_THREAD_MAX_AGE`.

Operating it - the same shape as the loop's scripts:

```sh
docker exec do-agent-aws /agent/slack-chat-status.sh   # running (polling|answering) or stopped, the gate, messages handled, last reply
docker exec do-agent-aws /agent/slack-chat-stop.sh     # halts at the next poll; --now terminates it and any model call in flight
docker exec do-agent-aws /agent/slack-chat-start.sh    # removes the stop flag and starts it detached
docker exec do-agent-aws /agent/agent-status.sh        # the same report "status" posts
```

State: `/wd/slack/chat.log`, `chat.state` (one line: `POLLING ...`, `ANSWERING ...` or `STOPPED
...`), `chat.STOP`, and one transcript per model answer under `/wd/slack/chat/`. The responder and a
loop fire may run at the same time; they share only the goals file (the responder appends to it,
through `/agent/goals-add.sh`) and `/agent/slack-post.sh`.

## 7. Troubleshooting - symptom → cause → the one command that confirms it

Every error text below is the script's real output, reproduced against the offline stub API or
the live API before being written here.

| Symptom (what you see) | Cause | Confirm with |
|---|---|---|
| `slack-status.sh` says configured, but nothing answers in the channel | The chat responder is not running: `SLACK_CHAT_ENABLED=false` set explicitly, or a stop flag left from `slack-chat-stop.sh` - section 6a; **or** the container predates your `.env` edit (section 4); **or** you expected an answer to a message posted before the responder started - the first watch starts at *now* (section 5). | `docker exec do-agent-aws /agent/slack-chat-status.sh` (running or stopped, the gate and its reason, messages handled); `docker exec do-agent-aws tail /wd/slack/chat.log` and `/wd/slack/chat-watch.log` (did it poll? did a reply fail?); `docker exec do-agent-aws /agent/slack-gates.sh` |
| The responder answered `I could not produce an answer: ...` | The model call failed or timed out (`SLACK_CHAT_TIMEOUT`), or `SLACK_CHAT_CLAUDE_OPTS` was overridden without the allow rules so the model could not run `/agent/slack-post.sh` and its answer never reached Slack (the responder then posts the model's final text, or this line); the first error line of the transcript is quoted. | `docker exec do-agent-aws grep "CHAT MODEL" /wd/slack/chat.log` (rc, duration, `posted=no`, the transcript path); `docker exec do-agent-aws cat /wd/slack/chat/<channel>-<ts>.out`; `docker exec do-agent-aws env \| grep SLACK_CHAT_CLAUDE_OPTS` (unset means the default, which carries both rules) |
| `CHAT UNANSWERED ts=... set aside in /wd/slack/unanswered.jsonl` in `chat.log` | Three attempts to answer that message landed nothing (an API error other than a rate limit, a failed call); it was not answered and was not marked processed. The `CHAT REPLY ... FAILED, nothing landed` lines before it quote the error. | fix the cause (the quoted error), then answer by hand, or move the line from `unanswered.jsonl` back to the top of `inbox.jsonl` for another attempt |
| `slack-status.sh` says configured, chat is off (`SLACK_CHAT_ENABLED=false`), but nothing ever arrives | The watch then only runs inside the autonomy loop and the loop is not running: `AUTONOMY_LOOP=false` or `SLACK_WATCH_ENABLED=false` set explicitly (in `.env` or a compose/kubernetes template), or a gate value other than `true`/`false`/`auto` (treated as `false`, with a `WARNING:` line in the container log) - section 6; **or** the container predates your `.env` edit (section 4); **or** a gate that did not reach the container: with the watch gate on and chat off the loop's IDLE line ends `; Slack watch ran, inbox empty - ...`, and the bare `LOOP IDLE goals file /wd/goals/GOALS.md not found` with chat off means the watch did not run (with chat ON the bare line is correct - the responder polls, not the loop - so check `chat.log` first); **or** you expected history - the first watch starts at *now* (section 5). | `docker exec do-agent-aws /agent/slack-gates.sh` (three lines: effective on/off and why); `docker exec do-agent-aws /agent/loop-status.sh` (loop stopped, or idle?); `docker exec do-agent-aws tail /wd/loop/slack-watch.log` (did the watch run at all?); `docker exec do-agent-aws env \| grep -E "SLACK\|AUTONOMY_LOOP"` (did your edit reach the container?); then the section-5 ladder. |
| `ERROR: Slack authentication failed: invalid_auth - check SLACK_BOT_TOKEN` | Token wrong, truncated, or for the wrong workspace. | `printf 'header = "Authorization: Bearer %s"\n' "$SLACK_BOT_TOKEN" \| curl -s -K - https://slack.com/api/auth.test` (section 1) |
| `ERROR: Slack authentication failed: token_revoked ...` | The app was uninstalled or the token rotated - reinstall the app and take the fresh token. | same `auth.test` call |
| `ERROR: Slack authentication failed: account_inactive ...` | The installing user or bot was deactivated (common after off-boarding in corporate workspaces). | same `auth.test` call |
| `ERROR: conversations.history failed for channel C...: not_in_channel` | The bot was never invited to that channel (bot tokens read only channels they are members of). | `/invite @<your-app-name>` in the channel, then re-run the watch |
| `ERROR: conversations.history failed for channel general: channel_not_found` | A channel **name** where an **ID** belongs (or an ID from another workspace). | section 3 - fetch the `C...` ID, fix `SLACK_CHANNELS`, restart |
| `ERROR: conversations.history failed for channel C...: missing_scope` | The token lacks the history scope for that channel type (e.g. `groups:history` for a private channel). | add the scope in **OAuth & Permissions**, **reinstall the app** (scope changes need a reinstall), update the token |
| `ERROR: SLACK_BOT_TOKEN is empty - set it in .env.local or the host environment ...` | The token never reached the container - typo in `.env.local`, or exported in a different shell than the one that ran `./run.sh`. | `docker exec do-agent-aws env \| grep -c SLACK_BOT_TOKEN` (expect 1) |
| `ERROR: SLACK_CHANNELS is empty - set the comma-separated channel IDs to watch in .env.local ...` | `SLACK_CHANNELS` is read from your settings in `.env.local` (not the host shell - section 4) and was left blank. | edit `.env.local`, `./stop.sh && ./run.sh` |
| Watch ingests messages, but the agent never answers in the channel | Posting is off: `SLACK_POST_ENABLED=false` set explicitly (the opt-out), or `slack-post.sh` refuses for channels outside `SLACK_CHANNELS`; or the agent chose not to answer (the goals decide). | `docker exec do-agent-aws /agent/slack-status.sh` (the `post gate:` line); `docker exec do-agent-aws /agent/slack-post.sh "C..." "test"` - read its refusal message |
| A fire's transcript `/wd/loop/fires/fire-N.out` starts with `Ignoring --allowedTools rule "<word>": Wildcard tool name ... is not supported in allow rules`, the calls that rule should allow are denied and the fire runs until `AUTONOMY_LOOP_FIRE_TIMEOUT`; or `loop.log` has `LOOP CONFIG AUTONOMY_LOOP_CLAUDE_OPTS: the word "<word>" cannot be a rule ...` and every fire ends `rc=96 ... outcome=config` with no claude call | `AUTONOMY_LOOP_CLAUDE_OPTS` holds a word that cannot be a rule: for example a parenthesis left open, or a rule written without its tool name (`/agent/x.sh:*`), which the loop reports before the fire instead of running it (docs/manual/autonomy.md "Autonomy loop") | fix the value in `.env.local` - a rule with a space is one rule, `Bash(...)` around it, the script's command text as the model types it - then `./stop.sh -s && ./run.sh -s`, or unset the variable: the shipped default is the safe value of section 6 |
| The inbox reaches the fire and the goals ask for a reply, but `/wd/loop/fires/fire-N.out` shows the `slack-post.sh` call denied (`This command requires approval`) | `AUTONOMY_LOOP_CLAUDE_OPTS` was set to a value under `acceptEdits` without the allow rule `--allowedTools Bash(/agent/slack-post.sh:*)`: headless claude under `acceptEdits` alone denies every Bash call (section 6); unset, the shipped default (the safe value of section 6) carries that rule. | `docker exec do-agent-aws env \| grep AUTONOMY_LOOP_CLAUDE_OPTS` (unset means the shipped safe default, which carries the rule); `docker exec do-agent-aws grep -l "requires approval" /wd/loop/fires/fire-*.out` |

## 8. What the watcher does - and the thread-reply trap

`/agent/slack-watch.sh` runs one poll and exits. Per channel it:

1. fetches messages newer than the persisted cursor (`conversations.history`, cursor-paginated),
2. appends them to `/wd/slack/inbox.jsonl` - one JSON object per line: `ts`, `channel`,
   `user`, `text`, and `thread_ts` when the message belongs to a thread - oldest first, in one
   write that is verified (the inbox grew by exactly the batch); a failed or short write is undone
   and ends the run with an error, so that
3. the per-channel cursor file `/wd/slack/cursor-<channel>` (and the thread registry) advances only
   once the messages are in the inbox - the next run brings them again otherwise. The append runs
   under `/wd/slack/inbox.lock`, the lock the chat responder and the loop take around their `sed -i`
   removals of handled lines, so an append never lands in a file being replaced; a failed append cuts
   the inbox back only when it is still the same file and did grow, never padding it.

**Thread replies are invisible to `conversations.history`.** A reply only bumps the parent's
`reply_count`; the parent itself is older than the cursor, so a history poll never sees the
reply. The watcher therefore keeps a per-channel thread registry
(`/wd/slack/threads-<channel>`) of every thread parent it has seen with replies, and polls
`conversations.replies` for them run after run, so replies to old threads keep
arriving - within one rolling budget: at most `SLACK_REPLIES_BUDGET` calls (default 30) in any
`SLACK_REPLIES_WINDOW` seconds (default 60), across every channel, the registry and the
answers/asks lists below (Slack allows about 50 a minute per app and workspace, and the chat
responder runs the watcher every few seconds). Each run polls the least recently polled threads
first, as many as the budget leaves, and defers the rest to a later run; a reply in a deferred
thread waits, it is not lost. The registry lines are `<parent ts> <newest reply ts> <epoch of the
last poll>`, and `/wd/slack/replies-calls` is the budget's ledger. `conversations.replies` answers with the thread's parent first every time, whatever
`oldest` says, so the watcher takes only the replies after each thread's own cursor: the parent
arrives once, from the history poll, and is never answered again. A thread the agent posts into
is added too (`slack-post.sh`, section 9): a post in the thread of a message the watcher saw
before it had any replies starts a thread the cursor is already past, and without the entry the
person's follow-up there would never arrive. Registry entries retire after `SLACK_THREAD_MAX_AGE`
(default 7 days) to keep the poll bounded.

A reply can also be threaded under a top-level message after the watcher saw it with no replies:
a person answers the agent in a thread under its post, or goes on in a thread under their own
message after the agent answered it. So the recent top-level messages get a bounded watch: each
top-level post of the agent (every part of a long one), listed by `slack-post.sh` in `/wd/slack/answers-<channel>`, and each
new top-level message of a person, listed by the watcher in `/wd/slack/asks-<channel>`, for 2
hours (`SLACK_ANSWER_WATCH_SECONDS`), the newest 5 of each (`SLACK_ANSWER_WATCH_MAX`), checked at
most every 60 s (`SLACK_ANSWER_POLL_INTERVAL`), within the same replies budget. A first reply
threaded under such a message arrives within about a minute rather than one poll. A message that gets a reply joins the
thread registry and is polled like any thread from then on. A thread started under an older
top-level message (more than 2 hours old, or past the newest 5) is still not collected. Known
limitation of any poller: replies to threads whose parent predates the very first watch are never
discovered (that would need the Slack Events API).

More behavior worth knowing:

* On the first watch of a channel the cursor initializes to *now* - history is not backfilled.
* The watcher records the bot's own identity from `auth.test` in `/wd/slack/identity`; the
  agent's own posts appear in the inbox like any message and are recognizable by that user id
  (the chat responder skips them; the loop prompt tells the agent to never reply to those).
* On an HTTP 429 it records Slack's `Retry-After` seconds in `/wd/slack/retry-after` (and fails
  loud as for any API error); the chat responder sleeps that long before its next poll.
* It fails **loud** - empty token, failed authentication, an API error, or an inbox write that failed
  or stopped short is a nonzero exit with a clear message, never a silent no-op.
* All state lives under `/wd/slack/`, which is on the `/wd` volume - cursors, inbox, and
  registry survive container replacement.

## 9. Posting - `/agent/slack-post.sh`

```bash
docker exec do-agent-aws /agent/slack-post.sh "C0123ABCDEF" "build finished: all tests green"
docker exec do-agent-aws /agent/slack-post.sh "C0123ABCDEF" "done - see the log" "1791617228.641039"   # reply in that thread
```

The optional third argument is a `thread_ts` (the `thread_ts` field of an inbox line, or a parent
message's `ts`): the message is posted as a reply in that thread, and - because a thread reply is
invisible to `conversations.history` - its read-back uses `conversations.replies` on that thread.
Once the reply is verified, the thread is added to the watcher's thread registry (section 8),
once per thread, so the replies that follow it are collected. The two-argument form posts in the
channel, unchanged.

**Where the agent's own answers go** (`SLACK_REPLY_IN_THREAD`, shipped `true`): the chat responder
and a loop fire answer in the thread of the message they answer - a message in a thread in that
thread, a top-level message in a thread under it, keyed by the message's own `ts` - and everything
later on the topic goes to the same thread (the fire's prompt says so for a goal recorded from
Slack: `(from Slack <channel> <ts>)` names the thread root; a fire posts only when it answers its
inbox, so this directs that path - nothing posts progress on a goal by itself). The responder's newest-message check
(below) then watches that thread, the same place this script re-reads before posting: a newer
top-level message is another topic and does not hold the answer back, a follow-up in the thread
does. With `false` the answer to a top-level message is posted top-level, where the person wrote
and the check watches the channel's top level.

The script refuses (nonzero, clear message) when the post gate is off - `SLACK_POST_ENABLED=false`,
or `auto`/unset without a token and channels - and for a channel that is not in `SLACK_CHANNELS`;
with a token and channels set posting is on unless you set the explicit `false`. After
`chat.postMessage` it **read-back verifies**: `ok:true` from the
API is treated as a claim, not proof - the channel is re-read and the posted `ts` must be
present, with the exact text posted, before success is reported (the `ts` is printed and logged to
`/wd/slack/posted.jsonl`, with the `thread_ts` for a thread reply). The text is compared after
undoing Slack's rendering (`&`, `<`, `>` as entities, links as `<url|label>`), and once more
ignoring whitespace and an added `http://` (an autolinked bare host); any other difference, a
message stored truncated for instance, fails the post with exit 1. Slack splits a message longer
than about 4,000 characters into several on its own and returns only the first `ts`, so a longer
text goes out in parts of at most `SLACK_POST_MAX_CHARS` (default 3500) characters, split at line
ends where it can (a split inside a ``` code block closes the fence at the end of the part and reopens
it at the start of the next, so each part renders as the whole did), each posted in the same place
and read back on its own; the output names the
parts (`(part 1 of 3)`).

**No answer from stale context.** With `SLACK_POST_AFTER_TS` set - the newest message the caller had
read when its answer began - the script first re-reads where it posts (the thread for a thread reply,
else the channel). If a newer message from someone other than the agent has arrived since, it posts
nothing and exits 3, naming that message (and appending `<ts> <user>` to `SLACK_POST_STALE_RECORD`
when set); a refused thread post also puts that thread into the watcher's registry (section 8), so
the reply that refused it is collected before the caller answers again - the thread the agent starts
under a top-level message is in no registry until its first post lands; a failed re-read refuses too. The chat responder sets it for every answer, to the newest
message it has of that conversation, and lists those newer messages in the model's prompt. On exit 3
it posts nothing, not even its fallback line, leaves the message first in the inbox, and on the
next poll answers it again with the newer message in view, then the newer message itself. A message
whose thread the watch has registered but not read yet (its first `conversations.replies` call deferred
by the replies budget, section 8) is not answered before that read: the responder logs `CHAT WAIT`,
leaves the line first in the inbox with no model call until the thread's first call has been made, at
most `SLACK_CHAT_STALE_MAX_SECONDS` from the first wait (then `CHAT WAIT CAP`, answered as any message). A loop
fire posts with the newest message of its batch; on exit 3 its prompt tells it not to post that
answer, and the newer message is in the next cycle's inbox. From an autonomy-loop fire the
call is permitted by the allow rule of the shipped safe `AUTONOMY_LOOP_CLAUDE_OPTS` (or by the opt-in
`--dangerously-skip-permissions`), from the chat responder's model call by the allow rule of its shipped safe
`SLACK_CHAT_CLAUDE_OPTS` (section 6; or the opt-in); the gates above still apply. The responder and a fire may post at the same time; `posted.jsonl` only ever gets single-line
appends.

## 9a. Attaching a file - `/agent/slack-upload.sh`

```bash
docker exec do-agent-aws /agent/slack-upload.sh "C0123ABCDEF" /wd/files/reports/chart.png "" "the sweep chart"                    # in the channel
docker exec do-agent-aws /agent/slack-upload.sh "C0123ABCDEF" /wd/files/reports/chart.png "1791617228.641039" "the sweep chart"   # in that thread
```

The arguments are the channel, the file, the `thread_ts` (`""` for the channel) and an optional comment, the text of
the message the file is attached to. The script is gated exactly as `slack-post.sh` is - the post gate and the
`SLACK_CHANNELS` allow-list - and needs the `files:write` scope (the manifest's second opt-in; without it step 1 answers
`missing_scope` and the script says so, with the reinstall step; nothing is uploaded). It makes Slack's three-step
upload, never the retired `files.upload`: `files.getUploadURLExternal` (filename, length) for an `upload_url` and a
`file_id`, a POST of the bytes to that URL (no token travels with them; the URL is accepted only on `*.slack.com` over
https, or at the origin of `SLACK_API_BASE` for the stub), then `files.completeUploadExternal` with the channel, the
thread and the comment - the call that posts the file message. The first two steps leave nothing in the channel (an
uncompleted upload expires on Slack's side), so a failure there is exit 1 and a retry is safe. `ok:true` from the third
is a claim, not proof: the thread (`conversations.replies`) or the channel (`conversations.history`) is re-read and a
message whose `files[]` carries the `file_id` must be present - three reads, at once, after 2 s and after 5 s more -
before the ts is printed and the share is logged to `/wd/slack/posted.jsonl` (ts, channel, `thread_ts`, `file_id`,
filename, the comment's first 200 characters); a thread share registers its thread with the watcher, a channel share
is watched for a threaded answer, as a post is. The exit codes are `slack-post.sh`'s: 0 shared and read back; 4 the
file landed but its message was not found; 5 the completion's response was lost - in both the file is on the platform,
do not upload it again (`SLACK_POST_RECORD` holds `unknown`, then the ts once the read-back finds it); 1 nothing landed.
An HTTP 429 on either token call is honored once (Retry-After, at most 30 s). Files above `SLACK_UPLOAD_MAX_BYTES`
(default 1 GB, Slack's limit) and empty files are refused before any call. A loop fire and the chat responder may
call it the way they call `slack-post.sh` (their prompts say when: a chart or a report the person asks for, never a
secret), and the safe values carry its rule `Bash(/agent/slack-upload.sh:*)`.

## 10. Testing without Slack

`/test24.sh` proves `/agent/slack-upload.sh` offline against the stub in `/test-lib/slack-upload-stub.py` (127.0.0.1,
ephemeral port): each refusal makes no API call, a 200 KB PNG lands byte-for-byte (length and sha256 at the stub) in a
thread and in the channel and is read back by `file_id`, `missing_scope` names the scope and the reinstall step, a refused
upload or a failed completion is exit 1 with nothing shared, a landed file whose message is missing is exit 4 with
`unknown` recorded, a lost completion response is exit 5, a 429 on either call is honored once, an `upload_url` on a
foreign origin is refused before a byte is sent, and the token appears in no output (19 checks).
`/test4.sh` (run by `./test.sh` with the other unit tests) proves the whole path offline
against a local stub Slack API on `127.0.0.1` - cursor advance, pagination, the thread-reply
trap, post + exact read-back verify, a long post in parts, an answer overtaken by a newer message, a follow-up in a thread the agent posted into, a reply threaded under
the agent's own post (watched 2 h, the newest 5, checked once a minute), loud failures, the fire's claude call, the four gates (`auto` with
and without a token, explicit `false`, explicit `true`), and the chat responder running beside a loop
with a 600 s interval (a reply within 15 s while the loop stays idle, `status`/`goals` without a
model call, a goal landing in the goals file, no double answers, thread replies, an HTTP 429
honored, stop/status/start, the explicit `false`) - its model is a fake claude that follows the
prompt's rules, so the live model's answers are not what the test proves. `/test10.sh` additionally walks
section 5's verification ladder against the stub, step for step, so the sequence this document
tells you to run is itself under test. The scripts honor `SLACK_API_BASE` (default
`https://slack.com/api`) precisely so the stub can stand in; no real Slack call is made by any
test. Your own token and app are what activate the live path.
