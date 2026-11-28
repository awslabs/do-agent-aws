# Slack and other channels

How the agent watches and answers Slack, and the comms engine's channels. Part of the [Do Agent on AWS manual](README.md).

Contents:

- [Slack connectivity](#slack-connectivity)
- [Comms UI](#comms-ui)

## Slack connectivity

The agent can watch Slack channels and reply in them - using a Slack app **you** create in your own workspace
(the bot posts as that app identity, never as a person). Set `SLACK_BOT_TOKEN` and the comma-separated channel
IDs in `SLACK_CHANNELS` in `.env`, then `./run.sh` - nothing else: with those two set the Slack chat responder and
the autonomy loop start with the container. Four explicit opt-outs, each `auto` in the shipped `.env`:
`SLACK_CHAT_ENABLED=false` (no chat responder - the loop's own per-cycle watch is then the intake),
`AUTONOMY_LOOP=false` (no loop), `SLACK_WATCH_ENABLED=false` (a loop without Slack), `SLACK_POST_ENABLED=false`
(watch only - the agent never posts); `true` on any of them forces that part on regardless of the token.
`/agent/slack-gates.sh` prints the four effective values with their reasons.

**Talking to the agent - the chat responder.** `/agent/slack-chat.sh` is an always-on process, started by
`startup.sh` beside the loop and independent of it, that polls the channels every `SLACK_CHAT_POLL_INTERVAL`
seconds (default 5) and answers every message in the thread of the message it answers: a message written in a
thread is answered in that thread, and a top-level message is answered in a thread under it, where the topic then
continues - your follow-ups there and the agent's later answers - so the channel's top level stays the list of
topics. That placement is the knob `SLACK_REPLY_IN_THREAD`
(see "Where an answer goes" below). Say `status` and it posts the agent's state (loop and chat state, last fires and progress
notes, whether a goals file exists) read from the state files; `goals`, `tasks`, `list goals` or `list tasks`
post the goals file's headings and checkbox lines; `help` lists these. None of those makes a model call, so the
answer arrives within one poll interval. Anything else is answered by one headless claude call that gets the
same state as context, so you can ask for an update on a task or how far a goal is while the loop keeps working.
When a message states a goal, the responder records it with `/agent/goals-add.sh`: the line
`- [ ] <goal> (from Slack <channel> <ts>)` is appended under `## Goals from Slack` in `/wd/goals/GOALS.md`
(the file is created when missing), and the loop fires on it from its next cycle - that is how a conversation
turns into work. A free-form answer therefore takes one poll interval plus one model call; the loop's
`AUTONOMY_LOOP_INTERVAL` plays no part in how fast the agent talks. The responder is operated like the
loop: `/agent/slack-chat-start.sh`, `/agent/slack-chat-status.sh` (the first thing to run when Slack is
configured and nothing answers) and `/agent/slack-chat-stop.sh [--now]`; its log is `/wd/slack/chat.log`, its
state line `/wd/slack/chat.state`, and each model reply's transcript is under `/wd/slack/chat/`. If a model call
fails or times out (`SLACK_CHAT_TIMEOUT`, default 1500 s - replies are answered one at a time, so one
long reply holds the queue for up to that long) it posts one honest line saying so instead of staying
silent. `/agent/agent-status.sh` prints the same status report in a shell.

**Where an answer goes.** One knob, shipped on, decides it for the chat responder and for a loop fire alike:

| Setting | Shipped default | Effect | Off |
|---|---|---|---|
| `SLACK_REPLY_IN_THREAD` | `true` - a top-level message is answered in a thread under it (the thread's `thread_ts` is the message's own `ts`), and everything later on that topic goes to the same thread: the responder's next answers, and the replies of a loop that takes Slack in itself (`SLACK_CHAT_ENABLED=false`) - its fire prompt also says that a goal recorded from Slack carries `(from Slack <channel> <ts>)`, the `ts` of the topic's thread root, and that anything it posts about that goal goes there. A fire posts to Slack only when it answers its inbox; nothing posts progress on a goal by itself. A message written in a thread is answered in that thread. Only the value `false` turns the knob off; any other value is read as `true`. | The channel's top level stays the list of topics; the comms UI's watcher (see "Comms UI") sees the answer in the ask's thread and lists the ask as answered. | `export SLACK_REPLY_IN_THREAD=false` in `.env.local`, then `./stop.sh && ./run.sh`: a top-level message is answered top-level, where the person wrote (a message in a thread, or a top-level message that already had a thread when the agent first saw it, is still answered in its thread). Off, the comms UI cannot tie those top-level answers to their asks, so such asks read as unanswered on its dashboard. |

Documented in `.env`'s own comment, here, and in [docs/slack/README.md](../slack/README.md) section 6a; the
compose and kubernetes templates list it by name with the other Slack settings. Two consequences of the thread
rule worth knowing: the responder's newest-message check (below) watches the thread the answer goes to, so a
newer top-level message - another topic - does not hold an answer back, while your follow-up in the thread
still does; and the thread the agent starts under your message joins its watcher's registry at once, so your
replies there are collected and answered in the same thread. `test4.sh` proves both placements and the knob.

While the chat responder is on it is the only consumer of the Slack inbox: the loop runs no watch and hands no
Slack messages to its fires, it works on the goals file alone (with no goals file it idles with no claude call).
The two processes may run at the same time; they share only the goals file (the responder appends to it) and
`/agent/slack-post.sh`. With `SLACK_CHAT_ENABLED=false` the loop takes Slack in itself: every cycle
runs `/agent/slack-watch.sh`, which appends new channel messages - including thread replies, which
`conversations.history` alone would miss - to `/wd/slack/inbox.jsonl`; a fire hands the unprocessed lines to the
agent as context (moved to `/wd/slack/processed.jsonl` after a fire that ended well - or carried into the next fire,
marked, when it did not: its answer refused as stale, a timeout, any other failure; at the carry bound the batch stays
in the inbox, logged, for a few more fires, then is set aside in `/wd/slack/unanswered.jsonl`, logged, unless a fire
ends well), and the loop fires on the goals file when it
exists and on new Slack messages otherwise (against `/agent/goals-default.md` - see "Autonomy loop"). In that
mode a reply waits for the next loop cycle, and with `AUTONOMY_LOOP=false` nothing polls automatically. A `.env`
change reaches the container only after `./stop.sh && ./run.sh` (or `-s` on both: the agent container alone, "Restart
only the agent container").

Posting is a second, deliberate gate: `/agent/slack-post.sh "<channel>" "<text>" [thread_ts]` refuses when the
post gate is off (`SLACK_POST_ENABLED=false`, or no token and channels) or the channel is not watched, and
reports success only after re-reading the channel - or the thread, for a reply with `thread_ts` - and finding the
posted message with the exact text posted (`ok:true` alone is not proof); given the newest message an answer
was written from (`SLACK_POST_AFTER_TS`), it posts nothing when a newer one has arrived (exit 3). Both the responder's and a loop fire's claude call run with
their safe value by default (the authority, the risk and the fire's safe value are in "Autonomy loop"; the responder's
safe value is `--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/goals-add.sh:*)
--permission-mode acceptEdits` - under a safe value headless claude runs exactly those scripts and denies every other
Bash call); `--dangerously-skip-permissions`, set in `.env.local` as `SLACK_CHAT_CLAUDE_OPTS`, is the opt-in. Both pass
their prompt on stdin so no override of the claude options can swallow it.

**Who may drive the agent.** The watcher (`/agent/slack-watch.sh`) puts in the inbox only the messages of the people
`SLACK_ALLOWED_USERS` names - comma-separated Slack user IDs (`U...` or `W...`, a person's "Copy member ID"), or the one word
`anyone` for every person in the channels. Empty, the shipped default, takes no one's message and says so in the watch log
(`WARNING: SLACK_ALLOWED_USERS is empty ...`), so a Slack-connected agent answers nobody until the operator names who may
drive it. Another bot's message (a `bot_id`, or subtype `bot_message`) never reaches the inbox; the agent's own posts do,
and the responder and the loop skip them. A message that is not taken still moves the cursor and still
registers its thread, so an allowed person's reply in a stranger's thread is taken; each run's line counts what it did not
take (`test-slack-senders.sh`). With the opt-in above, every person `SLACK_ALLOWED_USERS` names can have the responder run
commands in the container, with the container's credentials, and a long reply holds the responder's queue (status, goals
and help included) for up to its timeout, since replies are answered one at a time.
`/agent/slack-status.sh` shows configuration, the four gates, cursors, and inbox depth without ever printing the
token (it makes no API call - only a watch run proves the connection). Cursors, inbox and chat state live on the
`/wd` volume and survive container replacement. With no token and channels configured no Slack code runs and the
container behaves exactly as it does without Slack. There is no listener and no port of its own - the scripts make outbound HTTPS
calls to the Slack Web API only. Setup (creating the app, bot scopes, organization-managed/corporate workspaces,
inviting the bot, finding channel IDs, the step-by-step verification ladder, chatting with the agent, and a
troubleshooting table) is documented in [docs/slack/README.md](../slack/README.md).

## Comms UI

The dashboard runs with Streamlit's own toolbar off (`--client.toolbarMode viewer`): its Deploy menu offered Streamlit Community
Cloud and other public hosts from inside the tool that holds the Slack credentials, a publishing path no one needs here;
the app's own widgets are unchanged. `/test7.sh` check 5 asserts the running daemon's flag and environment.

The comms UI is a dashboard over the agent's communication channels - a severity-ordered
attention queue (`engine_lost` -> `in_flight` -> `edited_after_response` -> `staged` -> `unanswered`)
answering "which conversations need a human right now?". It is built on the
[communication-engine](https://github.com/dmvevents/communication-engine) (Apache-2.0), installed by
`setup/install-comms.sh` pinned to a full commit sha. It is one of the harness UIs, so it is
subordinate to the `UI_START` master switch: with `UI_START=false` the comms UI does not run and
publishes nothing, exactly like the rest of the UI stack. Enabled per-UI by default
(`COMMS_UI_ENABLED=true` in `.env` - demo mode is credential-free and fully offline) and served
through the home proxy at `http://localhost:8000/comms/` (see "Home page and reverse proxy";
`COMMS_UI_BASE_PATH` in `.env` carries the path to streamlit). When the home proxy is off
(`UI_HOME=false`) but `UI_START=true`, the dashboard is published directly on `127.0.0.1:8502` -
reach it with `ssh -L 8502:127.0.0.1:8502 user@host`, then open `http://localhost:8502`.
With `COMMS_UI_ENABLED=false` no comms dashboard runs and no comms port or route exists (the
watcher below has its own gate). The write
surface is a separate gate and ships **on** (`COMMS_UI_WRITE_ENABLED=true`): the dashboard
includes the engine's human-gated write surface, where nothing ever auto-sends (see below). Set
`COMMS_UI_WRITE_ENABLED=false` for the strictly read-only viewer.

Out of the box the dashboard runs in **demo mode**: on first start it generates
`/wd/comms/settings.json` keeping only the engine's credential-free fake adapter, and
`COMMS_DEMO_SEED=true` plants the engine's demo message so there is something to look at - nothing
contacts a real service. Watching real Slack/Telegram/email channels is a deliberate second step with
your own tokens as `env:` references in your own `settings.json` - and it takes the **watcher**: the
dashboard is a viewer and never polls. The watcher, the engine's own read-only scheduler, starts
with the container by default (`COMMS_WATCH_ENABLED=true` in `.env`; `/agent/comms-watch-start.sh` /
`comms-watch-stop.sh` / `comms-watch-status.sh` by hand) and loads `settings.json` when it starts, so
restart it after a change. Besides polling the channels it fetches the replies in the threads of
open asks, so an ask answered in its thread by someone other than the asker shows as answered. Your
credential variables reach the container via `COMMS_ENV_NAMES`. The full walk-through, one page per
channel (Slack incl. corporate workspaces, Telegram, email, Slack Socket Mode), the `core.doctor`
preflight, and the exact UI field values are in [docs/comms/README.md](../comms/README.md)
"Connect a real channel". A second gate,
`COMMS_UI_WRITE_ENABLED` (default `true`), carries the engine's human-gated write surface:
composing STAGES a draft into the outbox and only an explicit human click on that exact text
sends it - the agent never auto-sends, discard is terminal and kept, and in demo mode the send
goes to the credential-free fake adapter so the whole cycle is provable offline (`test7.sh`). No
shipped live adapter has a send path at the pinned engine, so the comms UI cannot post to real
Slack at this pin; the agent posts there with its own
`/agent/slack-post.sh` ("Slack connectivity" above). Set `COMMS_UI_WRITE_ENABLED=false` for the
strictly read-only viewer: every database opens read-only and the engine's send layer is never
even imported. The agent's own gated posting feature is "Slack connectivity" above, a different
thing. Engine state lives under `/wd/comms` and survives container
replacement; manage the UI with `/agent/comms-ui-start.sh` / `comms-ui-stop.sh` /
`comms-ui-status.sh`. Details, severity definitions, the write-surface gates, and the real-channel
setup walk-through: [docs/comms/README.md](../comms/README.md).
