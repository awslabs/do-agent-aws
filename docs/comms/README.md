# Comms UI - communication-engine operator dashboard

The comms UI is a **read-only observability layer over the agent's communication channels**. It
answers the question "which conversations need a human right now?" by rendering a severity-ordered
attention queue over a local sqlite journal:

| Severity | Meaning |
|----------|---------|
| `engine_lost` | the platform still serves a message the engine lost - the worst state, listed first |
| `in_flight` | a send left the outbox but its arrival was never confirmed |
| `edited_after_response` | a message was edited *after* it was answered - the answer may address stale text |
| `staged` | a draft is staged in the outbox waiting for an explicit operator gate |
| `unanswered` | a question/request classified as owed an answer with no response yet - and no thread with a reply from someone else under it (see "What unanswered means") |

It is built on the [communication-engine](https://github.com/dmvevents/communication-engine)
(Apache-2.0), installed by `setup/install-comms.sh` under `/opt/comms` and **pinned to commit
`1156a40ca7021cbae9a4e89f42a5b0478bd2c86f`** (tag `v0.1.0`) - no floating refs. The engine core is stdlib-only
Python; `streamlit` (pinned in the install script) is its one third-party dependency, used only by
the dashboard.

**Posting to real Slack from the comms UI: not at this engine pin; a follow-up engine PR is
pending.** At this pin the engine's Slack adapter has no send path (it declares `send: false`,
and its transport refuses any method outside its read allowlist), so the compose form and its
Send button exist only for the credential-free demo channel of the fake adapter: that is where
the UI composes and sends today. A draft for a channel whose adapter cannot send offers Discard
only. The planned design is read and write from both posters, the agent and the comms UI,
deduped by the same guards as the agent's sender; posting to Slack from the comms UI, and a DM
ask closed by a top-level answer from the other person, are in that pending engine PR.

Until then the agent posts to real Slack with its own `/agent/slack-post.sh`
([docs/slack/README.md](../slack/README.md)): it re-reads what it posted exactly, refuses an
answer a newer message has overtaken, and answers in the thread of the message it answers - in the
thread for a message in a thread, and in a thread under a top-level message (`SLACK_REPLY_IN_THREAD`,
shipped `true`; `false` answers top-level, where the person wrote, the behaviour until 2026-10-31).
The watcher (below) fetches the replies in the threads of open asks every cycle, so an ask that
someone other than the asker answered in its thread shows as answered once the watcher has polled
it. A top-level reply cannot be tied to the ask it answers, so a top-level ask answered top-level
stays open on the dashboard - the one reason the agent now answers in a thread.

**What unanswered means.** A message that has a thread is answered: an ask whose thread holds a
reply from someone other than the asker leaves the UNANSWERED queue. That rule is the engine's
instance setting `threaded_is_answered`, on by default, carried into this image as the build-time
patch `setup/comms-patches/0001-thread-answered-at-ingest.patch`
(the engine's PR #13, merged in its `v0.2.0`,
applied by `setup/install-comms.sh` on the pinned sha; it goes away when `COMMS_ENGINE_SHA` moves
to `v0.2.0` or later). With it on, two things hold that did not at the bare pin: (1) an ask whose polled
row already shows such a reply - every thread parent the first poll of a channel serves, and an
ask whose reply landed before the engine's first poll of it - is tied the moment it is polled, from the row's own
`reply_users`, with no `conversations.replies` call, so neither the thread sweep's window of 25
roots per cycle nor a 429 holds a visibly answered ask open; (2) in the thread sweep any reply
from someone else answers, a question included (the follow-up question is owed on its own row) -
the bare pin refused a reply that was itself a question as the answer, which left an ask open
whose thread anyone could see answered. What stays open, by design: a thread whose only replies
are the asker's own, a reply the platform attributes to nobody, and a top-level reply (it cannot
be tied). Two limits of this pin to know: the tie is text-blind - anyone other than the asker in
the row's `reply_users` ties it, a teammate's "+1" or question, an app's auto-reply - and once an
ask is tied, by either route, the engine does not fetch its thread again (the sweep works from open
asks; a thread that grows after its parent was polled reaches the engine through the sweep only
while its ask is still open, since a cursored history poll never serves a parent twice). So a
follow-up question the person writes in a thread the agent has already answered - exactly where
the first half of this change steers it - is answered by the agent (its own watcher collects it)
but does not reach the comms dashboard, as unanswered or as answered, until the engine's follow-up
sweep of answered asks' threads lands (communication-engine PR #12, open). To turn the
rule off for one connection, set `"threaded_is_answered": false` on that instance in
`/wd/comms/settings.json` and restart the watcher
(`docker exec do-agent-aws sh -c '/agent/comms-watch-stop.sh && /agent/comms-watch-start.sh'`):
the sweep is then the one in-thread route and a reply that is itself a question does not answer.
The engine is cloned at build time, so a running container gets this with `./build.sh` and a
restart (`./stop.sh && ./run.sh`); `docker exec do-agent-aws git -C /opt/comms rev-parse HEAD`
prints the pin, and `docker exec do-agent-aws git -C /opt/comms status --short` the files the
patch changed. `test-comms-defaults.sh` check 8 proves the patch applied and the rule in effect.

**Viewing is read-only by construction:** the dashboard opens every database in sqlite
`mode=ro`, and with the write gate off it never even imports the engine's send layer (both
properties are AST-checked by the engine's own test suite, which `test6.sh` runs). A
separately-gated **write surface** - `COMMS_UI_WRITE_ENABLED`, shipped `true` in the harness
`.env`, see "The write surface" below - lets the operator answer from the dashboard: composing
STAGES a draft and only an explicit human click on that exact text sends it; the agent/engine
never auto-sends. Set `COMMS_UI_WRITE_ENABLED=false` for the strictly read-only viewer. The
agent's own gated Slack
*posting* path is a different feature, [docs/slack/README.md](../slack/README.md)
(`/agent/slack-post.sh`): that one lets the agent speak in its own bot identity; this one lets
the operator *observe* communication state and, behind the write gate, *answer* it themselves.

## The .env gates

| Variable | Default | Effect |
|----------|---------|--------|
| `COMMS_UI_ENABLED` | `true` | start the dashboard at container startup and publish its port on `127.0.0.1`. With the gate off no dashboard runs and no port or route is published; the watcher has its own gate, `COMMS_WATCH_ENABLED` below. |
| `COMMS_DEMO_SEED` | `true` | on the **first start only** (no journal exists yet), run one read-only engine cycle with `--seed-demo`, planting the engine's demo message in the credential-free fake adapter so the dashboard renders content out of the box. The seed only touches adapters that expose a dry-run `seed()` hook - only the fake adapter does; real channels are never seeded. |
| `COMMS_UI_WRITE_ENABLED` | `true` | the engine's gated **write surface** on the dashboard (see "The write surface" below). On (the shipped default): composing STAGES a draft into the outbox; only an explicit human click on that exact staged text sends it, and Discard is terminal and kept - nothing auto-sends. Off: the UI is the strictly read-only viewer, and the engine's send layer is never even imported. The engine refuses any value other than `true`/`false` by name. |
| `COMMS_WATCH_ENABLED` | `true` | start the **real-channel watcher** at container startup: the engine's own read-only scheduler, polling the channels configured in `/wd/comms/settings.json` into the journal the dashboard renders, and fetching the replies in the threads of open asks, which marks an ask answered by someone other than the asker. Without a watcher, a configured real channel is never polled and the dashboard only ever shows the demo seed - see "Connect a real channel" below. With the generated demo settings it polls only the fake adapter, which makes no network call. It reads the `settings.json` the dashboard generates at its first start, so with the dashboard off and no `settings.json` it says so and exits. Independent of `UI_START`: a watcher is not a UI. `false` runs no watcher. |
| `COMMS_ENV_NAMES` | *(empty)* | space-separated **names** of host environment variables to pass into the container - the variables your `settings.json` `env:` auth references name. Rendered as bare `-e NAME` docker switches, so the values never appear in `.env` or in the echoed docker command; an entry containing `=` is refused loudly. |

`PORT_INTERNAL_COMMS_UI` / `PORT_EXTERNAL_COMMS_UI` (default 8502) set the port pair.

## Access - loopback only

`run.sh` publishes the port on `127.0.0.1` only (`UI_BIND_HOST` in `.env`), same as the harness
UIs. Reach the dashboard through an SSH tunnel:

```sh
ssh -L 8502:127.0.0.1:8502 user@host     # then open http://localhost:8502
```

On kubernetes the service stays `ClusterIP`: `kubectl -n <namespace> port-forward
svc/do-agent-aws 8502:8502`.

Inside the container the dashboard is managed with `/agent/comms-ui-start.sh`,
`/agent/comms-ui-stop.sh`, and `/agent/comms-ui-status.sh` (status reports UP only when the port
actually answers HTTP, and prints the journal/message/cursor counts read from disk). Engine state -
`settings.json`, `state/journal.db`, `state/messages.db` with per-channel cursors - lives under
`/wd/comms` and survives container replacement.

A note on the listen address: the engine's own `scripts/dashboard-serve.sh` pins `127.0.0.1`,
which is correct on a bare host but unreachable through a docker port publish (a loopback bind
inside the container's network namespace never sees the docker-proxy). `comms-ui-start.sh` uses
the exact same streamlit flags with only the address made container-aware (default `0.0.0.0`
in-container, `COMMS_UI_LISTEN_HOST=127.0.0.1` outside one) - the exposure control is the
`127.0.0.1` host-side publish, so the engine's tunnel-only contract is preserved either way.

## Demo mode - what you get out of the box

Out of the box the UI runs in **demo mode**: on first start `comms-ui-start.sh` generates
`/wd/comms/settings.json` from the engine's `settings.example.json` keeping **only the
credential-free fake adapter** (an instance with unresolved `env:` auth references makes the
engine refuse to start, by design), and `COMMS_DEMO_SEED` plants one demo message. Nothing
contacts a real service. The demo message is an open ask, listed as UNANSWERED until you answer
it with its Reply button (see "The write surface" below). The watcher runs too
(`COMMS_WATCH_ENABLED=true`) and polls the fake adapter, which finds nothing new: its log,
`/wd/comms/watch.log`, gets one `cycle:` line per poll. While an ask is open the engine keeps
polling at the base interval, the fastest channel's `poll_interval_s`. The generated demo
channel polls every 60 s (the engine's example says 15 s), so that is one line a minute; with
nothing owed the engine backs off, up to 16 times the base interval.

## Connect a real channel

Every real channel is the same four steps, whatever the platform. The platform-specific
details - what credential to create, where, its exact field names, and each platform's honest
limits - live on one page per channel:

| Channel | Page | How it ingests | Direction | Verified how |
|---------|------|----------------|-----------|--------------|
| Slack (polling) | [slack.md](slack.md) | `conversations.history` poll, cursor-paginated, first poll backfills; `conversations.replies` under each open ask, for the thread replies history never serves | read-only | offline stub (`test10.sh`, against a loopback stub of the Slack API; the engine's own adapter tests); **not live-verified by us** |
| Slack Socket Mode | [slack-socket.md](slack-socket.md) | push (outbound WebSocket) - **latency add-on that must run alongside the poller**, push can miss events | read-only (ingestion) | engine's own offline tests; live smoke is operator-owned |
| Telegram | [telegram.md](telegram.md) | `getUpdates` bot queue - **no history; reading acknowledges destructively; one chat per instance** | read-only | engine's own offline tests; **not live-verified by us** |
| Email (IMAP) | [email.md](email.md) | IMAP poll, read-only by transport (`EXAMINE` + `BODY.PEEK`) | read-only | engine's own offline tests; **not live-verified by us** |
| fake | (built in) | in-memory demo adapter | read + gated send | fully offline, `test6.sh`-`test8.sh` |

No shipped live adapter has a send path - "read-only" above is enforced at the transport layer,
not promised (see "The write surface" below for what the write gate does and does not add).

**Step 1 - get the credential into the container.** The engine reads credentials only through
`env:NAME` references, so the named variables must exist in the *container's* environment. Put the
values in the AWS Secrets Manager secret the container reads at start (docs/manual/aws.md "Credentials from AWS Secrets Manager"),
list the **names** in `COMMS_ENV_NAMES` - every name there is taken from the secret - and restart:

```bash
# the secret's JSON holds MY_SLACK_TOKEN (and MY_SLACK_CHANNELS if you like)
# in .env.local:  export AGENT_SECRETS_ID=do-agent-aws/credentials
#                 export COMMS_ENV_NAMES="MY_SLACK_TOKEN MY_SLACK_CHANNELS"
./stop.sh && ./run.sh
```

For a quick local trial the values can be exported in the host shell before `./run.sh` instead; the
container then logs a WARNING naming each credential that came from its environment.

On compose, add one value-less line per name to the template's `environment:` list; on
kubernetes put the same variables in the optional secret `<app>-comms` (see the comments in
`to/compose/template/docker-compose.yaml` and `to/kubernetes/template/020-deployment.yaml`).

**Step 2 - describe the channel in `settings.json`, either through the UI or in the file.**
The two routes write the same thing; use whichever you prefer.

*The UI route* (needs `COMMS_UI_WRITE_ENABLED=true`, the shipped default): dashboard →
**connections & monitored channels** → *add connection*: `instance name` = any label you like,
`adapter` = picked from the discovered set (e.g. `slack`), auth entries = the **auth key** the
adapter documents (e.g. `token`) and the **environment variable name** from step 1 (e.g.
`MY_SLACK_TOKEN` - the name, never the value). Then *add monitored channel* with the channel
`id`. Every edit is STAGED as an exact `settings.json` diff and applies only on your click
(see "Config management" below). Three refusals you can meet here are by design:

* pasting a **token value** where the variable name belongs →
  `refused: ... expected the NAME of an environment variable (letters, digits, '_'); got a
  30-char string — raw secrets never enter configuration, the staged record, or an error message`
* naming a variable that is **not set** in the container →
  `refused: environment variable MY_SLACK_TOKEN is not set — the engine refuses to start
  half-configured rather than fail at first send` (fix: step 1, then restart)
* a channel id present in only **one** of the two places it must appear (the platform pages
  explain each adapter's pair) - this one is NOT refused at load: it looks healthy and stores
  nothing. The doctor in step 3 names it.

*The file route*: edit `/wd/comms/settings.json` directly, following
`/opt/comms/settings.example.json` - add one instance per workspace/bot/mailbox, `auth` values
as `env:` references, channels under `channels[]`. Every unknown key or unresolved reference is
refused loudly at load. The per-channel pages give the exact JSON for each adapter.

**Step 3 - preflight with the engine's doctor.** Before trusting anything, run the engine's
own preflight - it validates the config, resolves the credentials (naming which, never echoing
values), makes **one live read-only poll per instance** to prove each configured channel
readable, and cross-checks the two-place rule:

```sh
docker exec do-agent-aws sh -c 'cd /opt/comms && python3 -m core.doctor --config /wd/comms/settings.json'
```

Expect every check `[PASS]` and the last line `DOCTOR OK — <n> check(s) passed, ...` (exit 0).
A `[FAIL]` names the channel and the fix; `DOCTOR REFUSED` means the config did not load.

**Step 4 - restart the watcher, and watch the rows arrive.** The dashboard is a viewer: nothing
in it polls. A configured, doctor-green real channel still shows **nothing** until a scheduler
polls it into the journal (that is by construction - every dashboard database connection is
read-only). That scheduler is the container's watcher, started at container startup by
default (`COMMS_WATCH_ENABLED=true` in `.env`). It reads `settings.json` only when it starts, so
restart it after the change (with `COMMS_WATCH_ENABLED=false`, the start alone runs it once
for this container):

```sh
docker exec do-agent-aws sh -c '/agent/comms-watch-stop.sh; /agent/comms-watch-start.sh'
```

then

```sh
docker exec do-agent-aws /agent/comms-watch-status.sh
```

which reports the watcher RUNNING, the last poll cycle (`cycle: polled=... fresh=...`), and
the journal/message row counts growing as channels are polled - the numbers the dashboard
renders. New rows appear in the dashboard on its next refresh. The watcher is the engine's own
`scripts/scheduler.py`: read-only by construction (it never imports the engine's send layer -
enforced by the engine's own AST test), single-instance per state directory (a second start is
a no-op), stopped with `/agent/comms-watch-stop.sh`. Its log is `/wd/comms/watch.log`.

One truth to keep in mind for **every** later config change: the watcher loads `settings.json`
at startup only (the engine has no hot-reload path - the UI's apply flash says the same), so
after any change: `docker exec do-agent-aws sh -c '/agent/comms-watch-stop.sh && /agent/comms-watch-start.sh'`.

The adapters are read-only pollers; every channel starts at `reply_policy: never` (except the
fake demo channel, generated at `staged` when the write gate is on - see below).

## The write surface (`COMMS_UI_WRITE_ENABLED`)

`COMMS_UI_WRITE_ENABLED=true` in `.env` (the shipped default; set `false` to remove the
surface) gives the dashboard the engine's write surface. The contract, in one sentence: **composing STAGES a draft; only an
explicit human click on that exact staged text sends it; Discard is terminal and kept as the
audit record.** The agent/engine never auto-sends - there is no compose path that skips the
gate, and the engine's own `tests/mutation_check.sh` deletes the gate one piece at a time to
prove a test goes red each time. The approval is durable (an approved send that crashes
mid-flight is completed by outbox recovery, never silently dropped), deduped (a double-click
cannot double-message), and read-back-proven before it renders as "sent".

Three independent gates all have to open before anything can leave:

1. `COMMS_UI_WRITE_ENABLED=true` - otherwise the write surface does not exist (the engine's
   send layer is never even imported; any value other than `true`/`false` is refused by name).
2. Per-channel `reply_policy: staged` (or `direct`) in `settings.json` - every channel
   defaults to `never` = deny, and the policy is re-checked at the click, so a channel demoted
   back to `never` refuses even already-staged drafts.
3. The instance's adapter must actually implement sending. **No shipped live adapter does** -
   slack/telegram/email are read-only by authorization at the transport layer - so flipping
   the gate gives no real platform a send path. Only the credential-free **fake** adapter
   declares send capability, which is what makes the whole write cycle provable offline.

**Demo mode:** when the write gate is `true` at *first* start (the shipped default),
`comms-ui-start.sh` generates the demo channel at `reply_policy: staged` so the full offline
cycle is clickable out of the box: compose -> STAGED row in the outbox -> Send button ->
fake-adapter delivery with a read-back-proven receipt -> the "sent" table. Each open ask on a
composable channel also has a **Reply** button: it fills the compose form for that ask, the
draft stages in the ask's thread, and the Send click that proves the delivery marks the ask
answered, so it leaves the UNANSWERED queue. Staging alone does not; a draft is not an answer.

`settings.json` is generated once and then left alone, with one exception. A start with the
write gate on regenerates a file that is still exactly a default an earlier start generated,
and prints `comms-ui: migrated ...`. That covers a read-only default, from before the write
surface or generated while the gate was off: it has the demo channel at `never`, so the
dashboard has no compose form, and this is how a container upgraded across the write surface
gets one. It also covers an earlier composable default, whose demo channel polled every 15 s.
A file you edited is never rewritten or widened. If it leaves no channel composable, the start
prints one line naming the channel. To compose to it, open the comms UI, go to
**connections & monitored channels** > *edit monitored channel*, set `reply_policy` to
`staged` and click Apply.

`test7.sh` proves the write cycle offline: gate-on default in `.env`, absence of the write
surface when the gate is flipped off (the read-only control), gate wiring into the daemon
environment, stage-without-send, click-to-deliver, and discard-is-terminal.
`test-comms-defaults.sh` proves the out-of-the-box path: the watcher on by default and idling,
the generated, migrated and user-edited `settings.json` cases with the compose form present or
absent, the Reply -> Send flow and a thread reply from another user marking asks answered, and
that the pinned Slack adapter still has no send path.

### Config management (same gate)

The same `COMMS_UI_WRITE_ENABLED=true` gate also adds the engine's **configuration
surface** (`scripts/dashboard_config.py`): connections (`instances[]`, adapter picked from
the engine's discovered `channels/` set - never typed free-form) and monitored channels
(`channels[]` with `reply_policy`/`thread_reply_policy`) can be added, edited and removed
from the dashboard instead of hand-editing `/wd/comms/settings.json`. The trust shape is
the outbox's, applied to config: an edit **STAGES an exact `settings.json` diff**; nothing
touches the file until an explicit human click on that exact diff; Discard is terminal and
kept. Every candidate is validated with the engine's own loader *before* it can be staged,
a new channel defaults to `reply_policy: never` (deny) by omission, and any change that
**widens** a policy (toward `staged`/`direct`) is flagged POLICY WIDENING in red on the
card being clicked. Auth is environment-variable **names** only (`env:NAME`): the surface
shows whether the named variable is set, never its value, and a pasted secret is refused
unstored and unechoed. Applying states the truth about reload semantics: the dashboard
re-reads settings on every rerun, but a **running scheduler/watcher loads settings only at
startup and must be restarted** - the engine has no hot-reload path. `test8.sh` proves the
whole cycle offline through the real UI widgets.

## Provenance

Upstream: <https://github.com/dmvevents/communication-engine>, public, Apache-2.0, pinned at
`1156a40ca7021cbae9a4e89f42a5b0478bd2c86f` (tag `v0.1.0`): the tree of the engine's `main` at `2f55b2a` (internal examples and names
replaced by synthetic ones in comments, docstrings, test data and docs), that `main` after its PRs #2-#6 merged by
fast-forward (#5 in-thread answers, #6 a fair thread sweep), plus the build-time patch
`setup/comms-patches/0001-thread-answered-at-ingest.patch` (engine PR #13, "What unanswered means"
above) applied on it. `setup/install-comms.sh` verifies the
checkout equals the pinned sha and fails the build otherwise, then applies each patch under
`setup/comms-patches/` with `git apply --check` first, failing the build when one no longer fits the
pin. `test6.sh` proves the read-only
offline path end to end: settings generation, demo seed, dashboard answering on loopback, no
non-loopback listener, the engine's own unit-test suite green, and journal/cursor survival
across stop/start. `test7.sh` proves the write path offline: the gate defaults on in `.env`,
no write surface (and no send-layer import) when the gate is flipped off, and the full
compose -> stage -> human click -> fake-adapter delivery -> discard cycle through the real
UI widgets. `test8.sh`
proves config management offline: gate-off absence, stage-without-write, click-to-apply with
the engine loader accepting the result and the restart-required truth stated, deny-by-omission
for new channels, the POLICY WIDENING flag, discard-is-terminal, and env-value non-disclosure.
