# Comms channel: Slack Socket Mode (push add-on)

The comms engine's `slack_socket` adapter receives Slack events over an **outbound WebSocket**
(Socket Mode): no public endpoint, no inbound firewall hole, sub-second detection, zero Web API
rate-limit budget. It is ingestion-only - like every shipped adapter it has no send path.

**Push for latency, poll for truth - never run this alone.** Slack documents that Socket Mode
delivery can be **missed**: a 10-connection cap, connections that cycle every few hours, and
drops when the mode is enabled mid-flow. The engine therefore treats this adapter as a latency
add-on **alongside** the polling [slack](slack.md) adapter on the same channels; the poller
remains the gap-free source of truth, and the engine's push-poll parity tooling exists exactly
to catch divergence. If you only configure one Slack adapter, configure the poller.

## 1. Credential - an app-level token (the third token type)

This adapter authenticates with an **app-level token** (`xapp-...`) alone - not the bot token
(events arrive over the websocket; the adapter makes no Web API reads). On the same Slack app
you created for the poller:

1. App page at [api.slack.com/apps](https://api.slack.com/apps) → **Basic Information** →
   *App-Level Tokens* → generate one with the `connections:write` scope.
2. Enable **Socket Mode** for the app (its own toggle on the app page), and subscribe the app
   to the message events for the channel types you watch (**Event Subscriptions** → bot
   events, e.g. `message.channels`).

On an organization-managed workspace all of section 2 of
[docs/slack/README.md](../slack/README.md) applies - and note the user-token fallback there
does NOT work for this adapter (Socket Mode is an app feature; there is no user-token variant).

## 2. Environment variables into the container

```bash
export MY_SLACK_APP_TOKEN="xapp-..."    # host shell
export MY_SLACK_CHANNELS="C0123ABCDEF"  # same id list the polling instance watches
```

In `.env`: `export COMMS_ENV_NAMES="MY_SLACK_APP_TOKEN MY_SLACK_CHANNELS"` (append to the
poller's names), then `./stop.sh && ./run.sh`.

## 3. The instance - UI fields and file form

UI route: adapter `slack_socket`, auth `app_token` → `MY_SLACK_APP_TOKEN`, auth `channels` →
`MY_SLACK_CHANNELS`; monitored channels as for the poller (same ids, so the push-poll parity
compares like for like).

File route:

```json
{"name": "my-slack-push", "adapter": "slack_socket",
 "auth": {"app_token": "env:MY_SLACK_APP_TOKEN", "channels": "env:MY_SLACK_CHANNELS"},
 "channels": [{"id": "C0123ABCDEF", "label": "team-push", "reply_policy": "never"}]}
```

**The two-place rule** applies as for the poller: channel ids in BOTH the env var and
`channels[]`.

## 4. Verify, then watch

```sh
docker exec do-agent-aws sh -c 'cd /opt/comms && python3 -m core.doctor --config /wd/comms/settings.json'
docker exec do-agent-aws /agent/comms-watch-start.sh
docker exec do-agent-aws /agent/comms-watch-status.sh
```

## Honest limits

* **Documented and offline-verified only** - the engine's own tests pin the reconnect/ack/loss
  behaviors offline; live Socket Mode smoke is operator-owned, and your step-4 doctor run is
  the live verification on your own app.
* **Events can be missed** (Slack's documented behavior, not a bug here) - which is the whole
  reason this adapter is an add-on to the poller, never a replacement.
* Above ~30,000 event deliveries per app per workspace per hour Slack stops delivering and
  says so (`app_rate_limited`); the engine records the admitted gap and drives a recovery poll
  instead of shrugging - but the recovery poll is the *poller's* job: one more reason both run.
* Unwatched channels and ephemeral edit wrappers are never ingested (they would poison the
  push-poll parity permanently).
