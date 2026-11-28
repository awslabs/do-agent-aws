---
name: comms-connect
description: Connect this do-agent-aws harness to the person's own Slack workspace and to Telegram, step by step, and prove each step works - the Slack app from the shipped manifest, its bot token and channels, read-only or posting, the conversations spoke, the comms dashboard's Slack and Telegram watchers, and Telegram notifications to a phone. Use it for "connect Slack", "connect Telegram", "set up Slack/Telegram", "why is the conversations spoke waiting for Slack", "the agent doesn't answer in Slack", a missing_scope or not_in_channel error, and "how does the agent talk to Slack".
allowed-tools:
  - Bash(/agent/slack-status.sh)
  - Bash(/agent/slack-chat-status.sh)
  - Bash(/agent/slack-doctor.sh *)
  - Bash(cat /agent/skills/harness-setup/slack-app-manifest.yaml)
  - Bash(/agent/slack-gates.sh)
  - Bash(/agent/comms-watch-status.sh)
  - Bash(/agent/supervisor.sh status)
  - Bash(cd /opt/comms && python3 -m core.doctor --config /wd/comms/settings.json)
---

# Connect Slack and Telegram

This harness reaches Slack and Telegram in three separate ways. Find out which ones the person wants before any step:

| Way | What it does | Credential | Sends anything? |
|---|---|---|---|
| **Agent Slack** (`/agent/slack-watch.sh`, `slack-chat.sh`, `slack-post.sh`) | the agent reads the channels in `SLACK_CHANNELS`, answers a question asked there, takes a goal from a thread | a Slack app's **bot** token (`xoxb-`) in `SLACK_BOT_TOKEN` | only with the `chat:write` scope and the post gate on, and only into `SLACK_CHANNELS` |
| **Conversations spoke** (tmux session `conversations`) | triages those channels and **stages** `[AGENT]` replies for a human to send | the same bot token and channels | never - it stages only |
| **Comms dashboard watchers** (the Conversations tile, `/opt/comms`) | lists Slack channels and a Telegram chat on one page | the variable *names* in `COMMS_ENV_NAMES`, the values in the host shell | never - the live adapters have no send path |

Telegram push notifications to a phone from Claude Code itself (session ended, needs input) are a fourth thing,
outside the harness - see "Telegram notifications" at the end.

## Ground rules (say them once, then follow them)

- Credentials go in the **host shell** or in `.env.local` (gitignored, sourced last), never in `.env`, never in a
  committed file, never pasted into this chat. Ask the person to set them; never echo a token's value back.
- The container reads its environment when it starts: after any change, `./stop.sh && ./run.sh` on the host.
- Use the person's **own** Slack app and **own** Telegram bot. Never reuse someone else's token: a Telegram bot token
  has one reader (two readers each lose messages), and a borrowed Slack token speaks as its owner.
- A user token (`xoxp-`) makes the agent read and post *as the person*, with nothing to tell the two apart. If the person
  has no way to get a bot approved, a user token is a read-only stopgap only: `SLACK_POST_ENABLED=false` and
  `SLACK_CHAT_ENABLED=false` in `.env.local`.
- Never post to test anything except `slack-doctor.sh --post-test`, into the person's own `SLACK_TEST_CHANNEL`, when
  they ask for it.

## Step 0 - where it stands (run, then report in under 10 lines)

```
/agent/slack-status.sh          # config only, no API call: token set? channels? each gate and why
/agent/slack-gates.sh           # the effective watch / post / chat / loop-autostart gates
/agent/supervisor.sh status     # the conversations spoke's line ("waiting for Slack" until a token and channels are set)
/agent/comms-watch-status.sh    # the dashboard watchers
```

Name what is missing and pick up at that step.

## Step 1 - the Slack app (host side: the person does this in a browser)

1. https://api.slack.com/apps -> **Create New App** -> **From an app manifest** -> their workspace -> paste the
   manifest the image ships at `/agent/skills/harness-setup/slack-app-manifest.yaml` (print it with `cat` for them).
2. **Decide read-only or answering, now.** The manifest grants read scopes only; `chat:write` is commented out. But with
   a token and channels set, the post and chat gates default to **on** (`auto`). So either:
   - **answering**: uncomment `chat:write` in the manifest before creating the app (or add it later and reinstall), or
   - **read-only**: put `export SLACK_POST_ENABLED=false` and `export SLACK_CHAT_ENABLED=false` in `.env.local`.
   Otherwise every answer the agent tries fails with `missing_scope`.
3. **Install to Workspace.** On a company workspace an admin may have to approve the app first; that is the person's
   request to make, not a step to work around.
4. Copy the **Bot User OAuth Token** (`xoxb-...`) - the person keeps it; it goes in the next step, not into this chat.

## Step 2 - channels and token into the harness (host side)

1. In each channel the agent should read: `/invite @<the app's name>`. A bot sees only channels it was invited to.
2. Channel **ids**, not names: in Slack, the channel's name -> "About" -> the `C...` id at the bottom.
3. On the host, in the harness checkout's `.env.local`:
   ```bash
   export SLACK_BOT_TOKEN="xoxb-..."           # or export it in the shell before ./run.sh instead
   export SLACK_CHANNELS="C0123456789,C0987654321"
   export SLACK_TEST_CHANNEL="C0123456789"     # optional: the one channel --post-test may write to
   ```
4. `./stop.sh && ./run.sh`.

## Step 3 - prove it (in the container)

```
/agent/slack-status.sh      # token set, the channel ids, the gates now on (or off as chosen)
/agent/slack-doctor.sh      # calls Slack read-only: token valid, every manifest scope granted, the bot in each channel
```

Every doctor row must be PASS (or the `chat:write` row a deliberate GAP for read-only). For each GAP the doctor names the
fix: a missing scope -> add it in the app's "OAuth & Permissions", **reinstall**, replace the token, restart; a channel
`not_in_channel` -> `/invite` the bot there.

Then the live ladder, one rung at a time, each confirmed before the next:
1. The person posts a message in one of the channels; within a minute `/agent/slack-status.sh`'s `identity:` line shows
   the bot (recorded by the first successful watch), and the conversations spoke's line in `/agent/supervisor.sh status`
   is LIVE, no longer WAITING "waiting for Slack".
2. Answering only: the person asks a question in a thread there; `/agent/slack-chat-status.sh` shows it taken, and the
   answer appears in the thread from the app's bot.
3. Answering only, if they want the round trip on record: `/agent/slack-doctor.sh --post-test` (writes two labelled messages into
   `SLACK_TEST_CHANNEL`, a post and a thread reply, and reads each back).

## Step 4 (optional) - the comms dashboard

The Conversations tile can watch the same Slack channels and a Telegram chat. It takes credential **names**, never values:

1. `.env.local`: `export COMMS_ENV_NAMES="SLACK_BOT_TOKEN SLACK_CHANNELS"` (add `TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID`
   for Telegram), then `./stop.sh && ./run.sh`.
2. Add the instance on the Conversations page (or in `/wd/comms/settings.json`) with `env:SLACK_BOT_TOKEN` as its auth
   and the channel ids in its `channels` - the ids must be in both `SLACK_CHANNELS` and the instance (docs/comms/slack.md).
3. Prove it: `cd /opt/comms && python3 -m core.doctor --config /wd/comms/settings.json`, then
   `/agent/comms-watch-status.sh`. The first poll backfills the channel's history.

## Telegram (comms dashboard, read-only)

1. In Telegram, talk to **@BotFather**: `/newbot`, a name, a username ending in `bot`. Keep the token it gives.
   Make a **new** bot for this harness - never one another program already reads.
2. Add the bot to the chat (or message it directly), send one message, then get the chat id once:
   `curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates"` on the host -> `result[].message.chat.id`.
   Do this once, before the watcher starts: two readers of one bot token race for its updates.
3. `.env.local`: `export TELEGRAM_BOT_TOKEN=...`, `export TELEGRAM_CHAT_ID=...`, both names in `COMMS_ENV_NAMES`;
   `./stop.sh && ./run.sh`; add the Telegram instance (docs/comms/telegram.md); prove it with `core.doctor` and
   `/agent/comms-watch-status.sh`.

## Telegram notifications (Claude Code on the person's own machine, outside this harness)

For pings to a phone when a session ends or needs input, on the person's own machine: a notification hook that calls
Telegram's `sendMessage` with a bot token and chat id from the steps above (oh-my-claudecode users have this as its
`configure-notifications` skill). Use a *separate* bot from the dashboard's - one reader per bot. For two-way chat with
a session there is a Telegram channel plugin in the official Claude Code plugin marketplace. Neither is part of this
harness, and its doctor checks neither.

## Other ways (outside this harness)

When the person asks about other ways to connect an agent to Slack or Telegram, or wants one of these instead:

1. **Claude Code + a Slack MCP server on a laptop**. An MCP server registered in
   `~/.claude.json` (`claude mcp add`, stdio) gives a Claude Code session tools to read a channel or DM, search, react
   and send. It runs on a **user** token, so it reads everything the person can read, with no app approval, and posts
   *as the person*. Keep the token in a mode-600 env file the wrapper sources, never inline in the wrapper; send only
   to DMs agreed for it, each message prefixed `[AGENT]` so readers (and the agent itself, which would otherwise re-read
   its own posts as commands) can tell them apart.
2. **A polling loop on a server**. A cron job every few minutes reads
   one DM with `conversations.history`, hands each new ask to a headless `claude -p` with the rules in its prompt, and
   answers through one helper that enforces the `[AGENT]` prefix, claims each ask in a file (no double answers),
   checks that no newer message arrived, and reads its post back. It posts only to that DM; anything for a shared or
   customer channel is staged for a human to send. Same user-token caveats as 1.
3. **This harness's Slack app** (Steps 1-3 above) - the supported way: a bot identity, only the channels it was invited
   to, posting only with `chat:write` and the post gate, and the conversations spoke staging rather than sending.
4. **Telegram as a two-way bridge on a server**. A small service on
   localhost holds the bot token and an allow-list of Telegram user ids; sessions send through a script that signs
   each request, and inbound messages land in a queue file that sessions pull. One reader per bot token.
5. **Telegram for this harness's dashboard, and notifications** - the two Telegram sections above.

Pick by who should be speaking: the person themselves (1, 2: a user token, their name on every post) or an app (3, 4,
5: its own identity, scoped to what it was given).

## What is and is not proven

The doctor, the gates and the ladder are tested against a stub Slack API in this image's tests (test10, test23). The
person's workspace, their app's approval, and Telegram are proven only by Step 3's ladder and `core.doctor` on their
own harness - say so plainly when you report.
