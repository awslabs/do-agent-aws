# Comms channel: Slack (polling)

The comms engine's `slack` adapter watches Slack channels for the operator dashboard. At the
pinned engine it is a **read-only poller**: gap-free cursored `conversations.history`, all pages
or fail loudly, plus `conversations.replies` under each open ask, because history never serves a
thread reply. It has **no send path at any layer** - the transport refuses any Web API method
outside its read allowlist, a tested invariant of the engine at this pin. So the comms UI cannot
post to Slack yet; posting from it, with the same guards as the agent's sender, is planned in a
follow-up engine PR (pending). The agent posts with its own `/agent/slack-post.sh`
([docs/slack/README.md](../slack/README.md)).

This is a different feature from the agent's own Slack watch/post
([docs/slack/README.md](../slack/README.md)) - separate config, separate state, separate
cursors. **The same Slack app and bot token can serve both.** One first-contact difference to
expect: the agent's watcher starts at *now*, while this adapter's **first poll backfills the
channel's full visible history** (no cursor yet) - a busy channel takes a minute, and old
messages appearing in the dashboard on day one is correct.

## 1. Credential

A Slack **bot token** (`xoxb-...`) with the history read scopes, exactly as
[docs/slack/README.md](../slack/README.md) section 1 creates one (section 2 there covers
organization-managed/corporate workspaces; its read-only user-token caveats apply here
unchanged). `chat:write` is never needed for this adapter. The bot must be a member of every
public/private channel it polls (`/invite @<your-app-name>`), and you need the **channel IDs**
(`C...`), never names.

## 2. Environment variables into the container

Pick your own names; these are the conventional ones. The token is a credential: add `MY_SLACK_TOKEN` to the AWS
Secrets Manager secret the container reads at start (docs/manual/aws.md "Credentials from AWS Secrets Manager"); the channel list
can go there too or be exported as a plain setting:

```bash
export MY_SLACK_CHANNELS="C0123ABCDEF"      # comma-separated channel IDs, no spaces
```

In `.env.local`: `export AGENT_SECRETS_ID=do-agent-aws/credentials` and
`export COMMS_ENV_NAMES="MY_SLACK_TOKEN MY_SLACK_CHANNELS"`, then `./stop.sh && ./run.sh`. For a quick local
trial, `export MY_SLACK_TOKEN=...` in the host shell before `./run.sh` works too, with a start WARNING naming it.

## 3. The instance - UI fields and file form

UI route (dashboard → connections & monitored channels):

| UI field | Value |
|----------|-------|
| instance name | `my-slack` (any label) |
| adapter | `slack` |
| auth key / environment variable name | `token` → `MY_SLACK_TOKEN` |
| auth key / environment variable name (second entry) | `channels` → `MY_SLACK_CHANNELS` |
| add monitored channel: channel id | `C0123ABCDEF` |

In the UI you add the two auth entries one at a time: the add-connection form creates
`my-slack` with the `token` entry, then the edit-connection form (shown only once the
connection exists) adds the `channels` entry. Between the two applies the connection is
incomplete, and the dashboard shows a warning naming it - that is expected, and adding
`channels` clears it.

File route (`/wd/comms/settings.json`, inside `"instances": [...]`):

```json
{"name": "my-slack", "adapter": "slack",
 "auth": {"token": "env:MY_SLACK_TOKEN", "channels": "env:MY_SLACK_CHANNELS"},
 "channels": [{"id": "C0123ABCDEF", "label": "team", "poll_interval_s": 60,
               "reply_policy": "never"}]}
```

**The two-place rule:** every channel ID must appear in BOTH `MY_SLACK_CHANNELS` (what the
adapter polls) and `channels[]` (what the engine keeps). An ID in only one place is not an
error - it is a successful-looking poll that stores nothing. The doctor names it.

## 4. Verify, then watch

```sh
docker exec do-agent-aws sh -c 'cd /opt/comms && python3 -m core.doctor --config /wd/comms/settings.json'
```

Expect `[PASS]` per check and `DOCTOR OK`. A wrong token fails the `health` check with Slack's
error name (`invalid_auth`); a two-place miss fails `readable` naming the channel.

```sh
docker exec do-agent-aws sh -c '/agent/comms-watch-stop.sh; /agent/comms-watch-start.sh'   # it reads settings.json at start
docker exec do-agent-aws /agent/comms-watch-status.sh   # cycle line + row counts growing
```

First rows: the backfilled channel history, in the dashboard on its next refresh. The watcher is
on by default (`COMMS_WATCH_ENABLED=true` in `.env`), so after the restart above it keeps polling.
Each cycle it also fetches the replies under the open asks, and an ask with a reply in its
thread from someone other than the asker (the agent's own in-thread answer included) shows as
answered. An ask whose history row already shows such a reply - every answered thread parent in
the first poll's backfill - shows as answered in the cycle that polls it, with no replies call
(`threaded_is_answered`, [README.md](README.md) "What unanswered means").

## Honest limits

* Read-only by authorization; `reply_policy` stays `never` unless you deliberately promote it,
  and even then no shipped Slack adapter can send.
* An answer counts only inside the ask's thread: a reply posted top-level in the channel cannot
  be tied to the ask it answers, and the ask stays open. A message that has a thread with a reply
  from someone other than the asker is answered, whatever that reply says (`threaded_is_answered`,
  on by default; `false` on the instance refuses a reply that is itself a question as the answer).
  A thread whose only replies are the asker's own stays open.
* Thread replies are fetched for at most 25 open asks per connection per cycle, shared across
  its channels: a channel with a backlog takes the bulk but every waiting channel keeps one, and
  a channel skipped in a cycle is swept first in the next; the watch log names it
  (`sweep: SKIPPED channel=...`).
* A Slack 429 is honored with the platform's exact `Retry-After` (the engine backs off
  per-instance); a busy first backfill may take several cycles.
* Corporate workspaces: everything in [docs/slack/README.md](../slack/README.md) section 2
  (admin approval, the read-only user-token stopgap and its identity caveat) applies here too.
