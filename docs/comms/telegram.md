# Comms channel: Telegram (bot)

The comms engine's `telegram` adapter watches ONE Telegram chat through a bot you create. It is
a **read-only poller** with no send path at any layer (the transport allows only `getMe` /
`getUpdates` / `getChat`).

**Telegram is structurally unlike Slack - read this before wiring it.** Telegram bots have
**no history API**: `getUpdates` is a queue, and advancing its offset is a **destructive
acknowledgement** - acknowledged updates are gone from the platform forever. The engine
handles the consequences correctly (the cursor is committed only after the journal write, one
`getUpdates` call per poll), but two operational rules fall out of it and are yours to keep:

1. **Never point a second consumer at the same bot token.** Two `getUpdates` readers steal
   updates from each other - the other consumer's messages are silently lost. One bot, one
   engine instance, nothing else. (This is also why we could not live-fire this adapter
   ourselves - see honest limits.)
2. **One chat per instance.** The adapter refuses more at construction (one bot queue has one
   ack authority). To watch two chats, create two bots and two instances.

## 1. Credential

Create a bot with Telegram's own **@BotFather** (message `/newbot`, follow the prompts) - it
returns the **bot token** (`123456789:AA...`). Add the bot to the chat you want watched. Get
the **chat id**: for a group, it is a **negative** number (e.g. `-1001234567890`); the easiest
read is to send one message in the chat and call
`https://api.telegram.org/bot<TOKEN>/getUpdates` once yourself - the `chat.id` field is in the
response. (That single manual call is safe *before* the engine starts; do not keep doing it
alongside a running watcher - rule 1.)

## 2. Environment variables into the container

The bot token is a credential: add `TELEGRAM_BOT_TOKEN` to the AWS Secrets Manager secret the container reads at
start (docs/manual/aws.md "Credentials from AWS Secrets Manager"). The chat id is a plain setting:

```bash
export TELEGRAM_CHAT_ID="-1001234567890"      # exactly one chat id
```

In `.env.local`: `export AGENT_SECRETS_ID=do-agent-aws/credentials` and
`export COMMS_ENV_NAMES="TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID"`, then `./stop.sh && ./run.sh`. For a quick local
trial, `export TELEGRAM_BOT_TOKEN=...` in the host shell before `./run.sh` works too, with a start WARNING naming it.

## 3. The instance - UI fields and file form

UI route: adapter `telegram`, auth `token` → `TELEGRAM_BOT_TOKEN`, auth `channels` →
`TELEGRAM_CHAT_ID`, monitored channel id = the same chat id.

File route:

```json
{"name": "telegram-watch", "adapter": "telegram",
 "auth": {"token": "env:TELEGRAM_BOT_TOKEN", "channels": "env:TELEGRAM_CHAT_ID"},
 "channels": [{"id": "-1001234567890", "label": "ops", "reply_policy": "never"}]}
```

**The two-place rule:** the chat id appears in BOTH the `TELEGRAM_CHAT_ID` variable and
`channels[]`, and must match byte for byte (including the minus sign).

## 4. Verify, then watch

```sh
docker exec do-agent-aws sh -c 'cd /opt/comms && python3 -m core.doctor --config /wd/comms/settings.json'
```

The doctor's health check uses `getMe` (it never touches the destructive queue) and its
readable probe makes one real `getUpdates` poll. Expect `DOCTOR OK`, then:

```sh
docker exec do-agent-aws /agent/comms-watch-start.sh
docker exec do-agent-aws /agent/comms-watch-status.sh
```

Send a message in the chat; the next cycle ingests it.

## Honest limits

* **Documented and offline-verified only.** The engine's Telegram adapter is proven by its own
  offline test suite; the engine's docs state that live Telegram smoke is **operator-owned**,
  and we have not live-fired it here either (our only bot token feeds another consumer - rule 1
  forbids sharing it). Your `core.doctor` run in step 4 is the live verification, on your own
  throwaway bot.
* No history: messages sent before the watcher's first poll are not retrievable, and lost
  journal rows are not re-readable from the platform (the engine's parity check for this store
  is permanently fail-closed - honest, not cosmetic).
* Burst messages within the same second can merge only in ordering, not identity (ids are
  message_ids); edits land as revisions of the same message.
* File attachments are ingested **without URLs** - Telegram download URLs embed the bot token,
  and the store must never hold a credential.
* Group chat ids are negative; a positive id is a private chat with the bot.
