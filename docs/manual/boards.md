# The boards

The Goals board (vibe-kanban), the optional Plane project board and the Board page. Part of the [Do Agent on AWS manual](README.md).

Contents:

- [Kanban board](#kanban-board)
- [Plane board](#plane-board)
- [Board](#board)

## Kanban board

`http://kanban.localhost:8000/` is a self-hosted [vibe-kanban](https://github.com/BloopAI/vibe-kanban) board that
shows what the agent is working on: one card per goal of the autonomy loop's goals file, in the columns To do, In
progress, In review and Done. Its home page tile is **Goals board**. It is on by default (`UI_VIBE_KANBAN=true`,
under `UI_START`) and needs no account with any service: vibe-kanban's cloud is shutting down, and its 0.1.44 release
replaced the board with a "Project functionality has been retired" page, so the harness builds and runs the board
server itself. A second vendored patch keeps the cloud's "Vibe Kanban Cloud is shutting down" banner off the
board's project pages (it stays on its export page), and the agent's mirror names the board's organization after
the project (the board names a local account's organization "<user id>'s Org"; a name you give it stays).

* `./build.sh` also builds the board server image `${REGISTRY}${IMAGE}-kanban${TAG}` (`./kanban.sh build`): the
  public upstream source at a pinned commit (v0.1.44, `KANBAN_VK_SHA` in `.env`) plus one vendored patch that puts
  the board component back (`kanban/patches/`; provenance in [kanban/README.md](../../kanban/README.md)). The first build
  compiles a Rust server and a web bundle and takes several minutes; later builds come from the cache. The base images
  of its Dockerfile (`node:20-alpine`, `rust:1.93-slim-bookworm`, `debian:bookworm-slim`) are taken from ECR Public by
  digest (`KANBAN_BUILD_BASES`, each passed as a `--build-context`, the Dockerfile unchanged) and its `# syntax=`
  frontend by digest (`KANBAN_BUILD_SYNTAX`); a base image without a pin fails the build, so a new pin of the source
  cannot pull one by its tag. The two sidecar images below are pinned by digest too.
* `./run.sh` starts the board before the agent container, as three sidecar containers: `${CONTAINER}-kanban-db`
  (`postgres:16-alpine`), `${CONTAINER}-kanban-server` (the board server) and `${CONTAINER}-kanban-electric`
  (`electricsql/electric:1.4.13`, the board's live sync). The database and Electric are on an internal network of
  their own with the board server, `${CONTAINER}-kanban-internal` (no route out); the board server is also on
  `${CONTAINER}-kanban`, the network the agent container joins. With `NETWORK` unset, the agent container is on
  `${CONTAINER}-kanban` only, not on Docker's default bridge network beside every container started without a
  network of its own. None of the sidecars publishes a host port: the board is meant to be reached through the home
  port's `kanban.localhost` route, on loopback like every other UI. Like any container's, their bridge addresses are
  reachable from the host itself; the database there answers only to its own generated password
  (`KANBAN_DB_PASSWORD` in the login file below), which `./kanban.sh` applies on every start. They come back with the
  Docker daemon (`restart: unless-stopped`). With `NETWORK` set in `.env.local`, the agent container starts on that network
  and is connected to the board's afterwards; that needs a user-defined bridge network, and with host, none or the
  default bridge networking the board is skipped with a warning.
* Every container on the agent container's networks is its neighbour. The home listener admits only loopback, the
  gateway of the agent's default route (the published port's path) and the sources in `UI_HOME_ALLOW_FROM`, and
  answers anything else 403; it answers only loopback names (421 for any other Host), and the UI backends listen on
  127.0.0.1 only ("Home page and reverse proxy"). So the board server, built from the pinned source and the agent's
  one neighbour on `${CONTAINER}-kanban`, is refused by the home port (421, and 403 on kanban.localhost) and gets no
  answer from the terminal; with `NETWORK` set, every container on that network is a neighbour too and
  is refused the same way. The database and Electric are not neighbours: they never need to reach the agent (the
  agent reaches the board server, which reaches them), and on their internal network they cannot.
  `./test-kanban.sh neighbours` checks all three from inside each. With the relay on (below), the relay is a second
  neighbour on `${CONTAINER}-kanban`, refused the same way, and the check probes it too.
* `./stop.sh` removes the agent container and the three sidecars, and keeps the board's data in the volumes
  `${CONTAINER}-kanban-db` and `${CONTAINER}-kanban-electric` for the next `./run.sh`. `./kanban.sh status` shows the
  sidecars; `docker volume rm` of both volumes deletes the board's data.

**Signing in.** The board has local accounts only. The first `./run.sh` generates its login into
`wd/kanban/kanban.env` (mode 600, in the gitignored `wd/` folder; `/wd/kanban/kanban.env` in the container): the
email `agent@do-agent-aws.local`, a random password, a database password and the server's own secrets. **The home
page's Goals board tile signs you in with one click** (a loading page says the first load after a container start takes
up to half a minute, and the board shows empty columns while its data syncs): it opens `http://kanban.localhost:8000/__harness/sign-in` in
a new tab, where `/agent/kanban-signin.py` (inside the agent container, behind the home proxy) signs in server-side
with that login and hands the board app a session, never the password, then shows the agent's project. It answers
only on `kanban.localhost`, the home port's own host route, so a page that reaches the port under another name (a
DNS-rebinding page) gets nothing, and only to a request from the harness home page on that port: its Origin, or the
Referer the tile's click sends. Another site's page can therefore neither frame a signed-in board nor sign your
browser in, and nothing may frame the sign-in page or the board. A browser that strips the Referer gets a 403;
sign in by hand then. Each sign-in starts a new board session, and the earlier ones are not revoked. To sign in by
hand, use the email and password from `wd/kanban/kanban.env`
on the host (the first sign-in creates the account and its organization). No script prints the password, and the
tile only says where the file is. The sign-in helper and the goal mirror follow no redirect, so the board session is
never sent anywhere but the board server. Delete the file to rotate everything on the next `./stop.sh` and `./run.sh`; the
cards stay, and the database password is re-applied. On the board, the agent's project is in the left bar (the
project cards on the board's own start page ask to link a vibe-kanban host first: that is the agent runner's
workspaces feature, not needed for the board).

**What the agent puts on it.** The autonomy loop mirrors its goals file on the board with `/agent/kanban-sync.py`,
in a project named after the container (`CONTAINER`), signed in with the same login. The board has it from the first
start, before any fire: at container start `/agent/ui-start.sh` runs `kanban-sync.py seed` in the background, which
waits for the board (up to `KANBAN_SEED_WAIT` seconds, 300 by default), creates the project with its columns and
mirrors the goals file - or, while there is none, the shipped default goals the loop fires on then
(`/agent/goals-default.md`: one standing goal, the Slack inbox). A start never waits for it, and a board that does
not come up only leaves a line in `/wd/ui/kanban-seed.log`. Once a goals file exists, the default goals' card moves
to the board's hidden Cancelled column.

* every goal is a card: a checkbox item `- [ ] ...` (the form `/agent/goals-add.sh` writes for a goal stated in
  Slack) or a `## Goal ...` heading (the form of [docs/loop/GOALS.md.example](../loop/GOALS.md.example); the
  default goals use `## Standing goal ...`);
* the newest goal is on top: in every column, Done included, the cards are ordered by when their goals reached the
  board, the latest first - so Done shows its most recently added goal without scrolling, and a card created on the
  board, which the board itself puts on top of its column, stays on top once mirrored. The board orders a column by
  each card's `sort_order` (its **Manual** sort, the default); the mirror sets it to minus the time the goal first
  reached the board and keeps that time in `/wd/loop/kanban-sync.state`, so a card's value never changes (goals that
  arrive together keep the file's order among them: for a file whose goals were all added at the end this is reverse
  file order). A card dragged within its column keeps its place until the next sync. `KANBAN_CARD_ORDER=file` in
  `.env.local`, then `./stop.sh -s && ./run.sh -s`, restores the file's order (the oldest on top): the setting reaches
  the container at its start, and the first sync after it re-sorts the cards already on the board;
* a checked goal (`- [x]`, or `[x]` in its `## Goal` heading) is in Done - the fire prompt tells the agent to mark a
  goal done in exactly these two ways when its DONE condition holds;
* the goal a fire starts on - the first open goal in the file, the card with the **Agent:** line (below) - moves to In
  progress when the fire starts. When it ends, the fire is credited to the goal it finished (a goal that turned done
  during the fire), else to the goal it
  started on, which moves to Done or In review (still open); the other open goals are in To do. A goal whose text
  the fire changed keeps its old card, moved to In review with a note, and the new text gets a card of its own;
* one card says what the agent does next: the card of the goal the loop's next fire starts on (the first open goal;
  during a fire, the fire's own) leads its description with one line, which the board shows on the card itself -
  **Agent:** working on this goal now (fire N, since HH:MM UTC) while the loop fires on it; next - the loop's next
  fire, at about HH:MM UTC, starts on this goal while it sleeps between fires; next - the loop is idle while it waits
  for a goals file or a Slack message; not picked up - the loop is stopped while its STOP flag is set, or not running
  when no loop process is behind its state file (`/wd/loop/loop.state`). It comes from what the loop writes there,
  its STOP flag and the goal order, nothing else; no other card has such a line, and it never reaches the goals file;
* every fire leaves a comment on its card - the exit code, the duration and the end of the fire's transcript - and
  a one-line "Last fire" note in the card's description. The note is there because the board's issue panel can
  leave its comment list loading over plain HTTP: the browser allows six connections per host, and the board
  holds one open per live query (seen in Chromium against this stack); the comments themselves are complete in
  the board's API (`GET /v1/issue_comments?issue_id=...`). Both are masked first, since a transcript can print
  anything the agent saw: the values of secret-named settings (`*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*API_KEY*`,
  ...) of the loop's environment, the board login file and the AWS credentials and config files
  (`AWS_SHARED_CREDENTIALS_FILE`, `AWS_CONFIG_FILE`, by default the mounted `~/.aws`), common token shapes (Slack,
  AWS key ids, GitHub, `sk-` and Bedrock API keys, JWTs, private keys), `NAME=value` secrets, AWS's credentials forms
  (`aws_secret_access_key = ...`, `aws_session_token = ...`, and any JSON string under a secret-named key such as the
  CLI's `"SecretAccessKey"` and `"SessionToken"`) and bearer tokens become `[redacted]`.

The mirror is one-way - the goals file is the source of truth, and a card moved by hand moves back on the next
fire - and best effort: while the board is down a fire runs exactly as without it, and `loop.log` carries one
`KANBAN ... not mirrored` line. `docker exec <container> /agent/kanban-sync.py sync` mirrors the goals without a fire.

**The board writes back.** The sync is two-way: a card dragged to **Done** checks its goal off in the
goals file, and dragged out of Done it is unchecked; a card created on the board (**New Issue**) becomes a new goal in the
file's own form (a `## Goal N - title` section with the card's description as its outcome, or a `- [ ] title` item in a
checklist file) and keeps its card, which then carries the goal's heading as its title; a title edit renames the goal; a description edit rewrites the goal's outcome lines
with its `DONE when:` line kept. A field edited in both places since the last sync: the goals file wins and the card
gets a comment saying so. Every write-back is one atomic rewrite under `/wd/loop/goals.lock`, and nothing writes while
the loop is firing (a fire reads and edits the file itself). The board is read at every sync, at the start of every
fire, and every `KANBAN_WATCH_INTERVAL` seconds (default 30) by `/agent/kanban-sync.py watch`, which `ui-start.sh`
starts with the board, so a change on the board reaches the file between fires too. A card created while the loop is
stopped (its `STOP` flag set, as the agent sets it once every goal is complete) is added to the file and gets a comment
saying how to start the loop again (`/agent/loop-start.sh`); nothing starts it on its own. The project is shown under
the goal set's name - `KANBAN_PROJECT_NAME`, else the goals file's first `# ` heading, else `do-agent-aws goals` -
while its id still derives from `KANBAN_PROJECT`, so a rename never makes a second project, and a name chosen on the
board stays. The standing (default) goal's card leads with one line and keeps the agent's full instructions behind a
disclosure; a checklist goal's card does not repeat its title as its description.

**The agent runner.** The npm `vibe-kanban` package (port 8081 in the container) keeps running, now at
`http://vk-runner.localhost:8000/`: its workspaces run coding agents in git worktrees, and need no account. Its home
page tile, **Agent workspaces**, opens them at `/workspaces` in a new tab, on the "Which repositories would you
like to work on?" view - its **Recent** list already holds the harness workspace `/wd` (when it is a git repository)
and every git repository one level under it or under `/wd/projects/`, the starter repository `/wd/projects/scratch`
among them ("Starter repository"), registered by `/agent/vk-runner-repos.sh` once the runner answers at
container start (best effort, in the background, log `wd/ui/vk-runner-repos.log`; after cloning a repository under
`/wd`, run `docker exec <container> /agent/vk-runner-repos.sh` or use Browse) - with no tour over it: the runner's first-start settings (below) mark its one-time
Workspaces guide as seen, which a first visit would otherwise open on top of the page (its question-mark button,
"Workspaces Guide", still opens it). The runner's start page `/` is a setup wizard instead: a first visit goes
through its onboarding (the coding agent, the editor, the notification sound, and its warning that agents run with
`--dangerously-skip-permissions`). Its own board pages need the retired vibe-kanban cloud; use the Goals board instead.
The harness hides the retired cloud's prompts on the runner's pages (a script the home proxy injects, like the home
badge): the app bar's "Kanban Boards / Sign in to organise your coding agents with kanban boards." block with its Sign
in button, the Projects button whose tooltip is "Sign in to view projects", and the drawer's "Organization" header; the
Settings dialog's own Remote sections stay as they are. The runner's `/settings` is not a page (its Settings is a
dialog from the nav), so a typed `http://vk-runner.localhost:8000/settings` lands on the workspaces, where the Settings
button is, instead of the app's "Not Found".

* **Your consent stays yours.** The harness does not accept the runner's terms or its disclaimer for you, and does
  not answer its onboarding; the one first-start setting it marks as seen is the retired cloud's sign-in onboarding
  (`remote_onboarding_acknowledged`), without which the runner's root sends every visit to a cloud sign-in. The tile goes past the onboarding page to `/workspaces`, so that
  path does not show the runner's own warning, which is: "Vibe Kanban runs AI coding agents with
  `--dangerously-skip-permissions` / `--yolo` by default. Always review what agents are doing." Here they run in
  the container, with its credentials, and this image's agent settings (below) turn that flag off for Claude Code.
  Open `http://vk-runner.localhost:8000/` to go through the runner's onboarding yourself.
* **Its analytics are off by default.** The runner's own server process sends anonymous usage events to
  vibe-kanban's analytics service (PostHog) while its "Enable Telemetry" setting is on, which is the default of a
  new vibe-kanban 0.1.44 configuration; the Content-Security-Policy below covers only its pages. So on its first
  start `/agent/ui-start.sh` gives the runner its own first-start settings with that setting off and its Workspaces
  guide seen, nothing else (`Container-Root/agent/vibe-kanban-config.json`; the image build's warm-up of the runner
  uses them too, and the image keeps no runner settings). To turn analytics on, tick "Enable Telemetry" in the
  runner's Settings, General, Privacy; the choice persists. Settings that already exist are never changed: when their
  analytics are on, the start prints a one-line notice (`vibe-kanban: NOTICE - analytics are on in ...`), also in
  `/wd/ui/vibe-kanban.log` and, for that start only, in `/wd/ui/vibe-kanban-analytics.notice`.
* **Its coding agent is this image's Claude Code.** vibe-kanban 0.1.44 runs Claude Code as
  `npx -y @anthropic-ai/claude-code@<its pin>` (2.1.119), a copy fetched at the first agent start, with
  `--dangerously-skip-permissions`. That copy runs only because the image's npm allows the package's install scripts
  (`setup/harden.sh`). When the runner has no
  agent settings yet (`profiles.json` beside its settings), `/agent/ui-start.sh` gives it this image's
  (`Container-Root/agent/vibe-kanban-profiles.json`): Claude Code's base command is `claude`, the image's own Claude
  Code with its Bedrock settings, and "Dangerously Skip Permissions" is off. Both are in the runner's Settings,
  Agents, Claude Code, where you can change them; agent settings that exist are never changed.
* **Asked once.** The runner keeps its settings and your answers (that you have seen its tour, for one), its
  workspaces and its signing key in `/home/agent/.local/share/vibe-kanban`, which is persisted under `wd/agent-state` (see
  "Persistent agent state"), so they survive `./stop.sh` and `./run.sh` and the tour shows only once. A workspace's git worktree lives in the
  container's `/var/tmp/vibe-kanban/worktrees`, which a new container does not have: the runner checks it out again
  from the workspace's branch when the workspace is opened, so anything not committed to that branch is lost with
  the old container.

**The relay (off by default).** With `UI_KANBAN_RELAY=true` in `.env.local`, the board can open the agent runner as
its host: a goal card's Workspaces, Create starts a workspace in the runner from the board, through vibe-kanban's own
relay server. Without it the build and the start are exactly as described above. With it (docker and compose targets):

* `./build.sh` also builds the relay server image `${REGISTRY}${IMAGE}-kanban-relay${TAG}` from the board's pinned
  source, with upstream's `crates/relay-tunnel/Dockerfile` unchanged: one more Rust build (265 crates, about three
  minutes the first time on a large build host; later builds come from the cache). The board image gets one more
  patch, `kanban/patches-relay/0101`, which shows the app bar's "Pair a remote device" again (patch 0006 hides it in
  harness mode); its labels list that patch after the others.
* `./run.sh` starts the relay as a fourth sidecar, `${CONTAINER}-kanban-relay`, with no published port: on the
  board's internal network for the board's database and on `${CONTAINER}-kanban` for the agent. Its settings are in
  `wd/kanban/relay.env` (mode 600: the database URL and the board server's token secret), written by `./kanban.sh
  init`; `./stop.sh` removes it with the other sidecars.
* The agent runner starts with the board as its shared API and the relay (`VK_SHARED_API_BASE`,
  `VK_SHARED_RELAY_API_BASE`), already signed in to the board: just before it starts, `/agent/vk-runner-signin.py`
  signs in to the board with the board login and stores that sign-in where the runner keeps its own
  (`credentials.json` beside its settings, mode 600; one line in `/wd/ui/vk-runner-signin.log`; each start stores a
  new one). The runner's own sign-in is not used: in vibe-kanban 0.1.44 it turns the runner's analytics on and sends
  usage events, the login's email among them. Signed in, the runner registers with the relay as the board's host.
* The home proxy sends `kanban.localhost/v1/relay/...` to the relay, on the board's own origin (the board app falls
  back to its own origin for the relay), and drops the relay's CORS headers as it drops the board server's. The
  Content-Security-Policy is unchanged, and the runner's own Kanban Boards stay hidden.

**Pairing your browser with the runner, once.** The relay lets a browser into the runner only once the two are paired
(a 6-character code, SPAKE2): in the runner (`http://vk-runner.localhost:8000/`), open Settings, Remote Access, Host and
click "Generate pairing code"; on the board, click the unpaired host in the app bar, type the code into the six boxes
and click "Pair this device". The browser keeps the pairing, and the runner keeps it in its persisted settings, so it
survives `./stop.sh` and `./run.sh`. A goal card's Workspaces, Create then opens the runner's create page through the
relay. This step stays manual: a pairing hands the browser control of the runner's workspaces.

**Status dots and the home badge.** Both tiles' dots read a same-origin probe on the home port, so a route that is
down shows red. `/__probe/kanban` asks the sign-in helper for a board read that goes to its database: the board
server's own `/v1/health` answers without its database. Without a board, it probes the runner that
`kanban.localhost` serves then. `/__probe/vk-runner` is the runner's `/api/health`. Both probes are GET-only and
status-only, like every tile probe: the page gets 204 when the upstream answered 2xx and 500 otherwise, never the
upstream's answer. Both routes carry the home page's floating "home" badge, like every proxied UI.

**No third-party requests.** vibe-kanban 0.1.44 calls third parties from the browser: the runner's prebuilt npm
bundle sends Sentry error reports and PostHog analytics, and both apps load Google Fonts and fetch the GitHub star
count and the Discord online count. The board is built without telemetry: the `SENTRY_DSN_REMOTE`, `POSTHOG_API_KEY`
and `POSTHOG_API_ENDPOINT` build arguments of its Dockerfile stay empty, and its web bundle has no Sentry at all. For
the rest, the home proxy answers on `kanban.localhost` and `vk-runner.localhost` with one Content-Security-Policy
that lets those pages load from and connect to their own origin and its websocket only, so the browser refuses each
of those requests before it leaves; the pages show local fonts and no counts, and none of their own requests is
refused (measured in Chromium).

**Targets.** docker: as above. compose: the same three services (`kanban-db`, `kanban-server`, `kanban-electric`)
are an overlay, `to/compose/template/docker-compose.kanban.yaml`, that `run.sh` renders and adds with `-f` only while
the board is on (`stop.sh` and `status.sh` add it when it was rendered), with the same env files and the same
internal network for the database and Electric (`kanban-internal`; the board server is also on the project's default
network, with the agent); `run.sh` applies the database password after the start, and a compose `down` keeps their
volumes; with the relay on, a second overlay, `to/compose/template/docker-compose.kanban-relay.yaml`, adds its
service the same way. swarm: no board - the base compose file stays a valid `docker stack deploy` file, and `kanban.localhost`
serves the agent runner. kubernetes: not yet - the board needs a StatefulSet with a volume and a board server image
pushed to a registry; on kubernetes `kanban.localhost` serves the agent runner, as it did before the board.

**Tests.** `./test.sh` runs `./test-kanban.sh bundle` on the host: the built image must carry the restored board,
none of the sunset page and no compiled-in telemetry endpoint (a Sentry DSN ingest host or a PostHog project key).
With the harness up, `./test-kanban.sh live` checks through the home port that a login answers 200 with a token (the
database answered), that a wrong password gets 401 (local sign-in is on), that the project list answers, that the
one-click sign-in hands out a board session on `kanban.localhost` and nothing under another Host, that the home page
opens the board and the runner's workspaces in new tabs (both with the home badge), that both routes send the
Content-Security-Policy, that both status probes answer, that the start seeded the board (the one-click sign-in
lands on the agent's project, with its four columns and its goal cards, without any fire), and that the runner's
analytics are off. With the relay on, `bundle` expects the relay's patch after the vendored ones, and `live` also
checks that the runner is signed in to the board, that the board lists it as an online host and that the relay opens a
session to it (skipped with the relay off).
`test18.sh` covers the proxy routes (the relay's among them), the policy, the sign-in helper, the start seed and the
loop mirror offline, inside the container; `test20.sh` the runner's start with the relay and
`test-vk-runner-signin.sh` the runner's stored sign-in.

## Plane board

The harness can run a self-hosted [Plane](https://plane.so) project-management board beside the agent (community
edition, the public images `makeplane/*:v1.4.2`) that opens with no setup wizard and no login screen and shows the
agent's work: its goals as work items that its autonomy loop fires move across the board.

**License, and why it is off by default.** Plane community edition is licensed under the GNU Affero General Public License
v3.0 ([AGPL-3.0](https://github.com/makeplane/plane/blob/v1.4.2/LICENSE.txt), the `LICENSE.txt` of the v1.4.2 tag), not the
Apache-2.0 of this repository. So the board is **optional and OFF by default** (`UI_PLANE=false` in `.env`): nothing of
Plane is pulled by `./build.sh`, started by `./run.sh` or shown on the home page - no Plane tile, no Board tile (the Board
reads the Plane project), no `plane.localhost` route - and `./stop.sh` has nothing of it to remove. This repository's own
Plane client scripts stay: `/agent/plane-sync.py`, `/agent/plane-signin.py`, `/agent/board.py` and `/agent/board-server.py`
in the image, `plane/seed.py` in the repository (it runs in the board's api container) - Apache-2.0 code of this repository
that talks to Plane's API and runs only while the board does. The AGPL-3.0 software is Plane's six `makeplane/*:v1.4.2`
images, pulled only when you turn the board on, together with four datastore images (postgres, valkey, rabbitmq and the pgsty/silo object store, AGPL-3.0)
under their own licenses: ten images, twelve containers.

**Turning it on, if the AGPL-3.0 is acceptable to you.** In `.env.local` (never in `.env`):

```bash
export UI_PLANE=true
```

then `./build.sh` (pulls the ten images, 3.21 GB) and `./run.sh` (starts the sidecars, seeds the board and joins the agent
to its network; on an instance that is already running, `./stop.sh && ./run.sh`). The home page then shows the **Project board (Plane)** tile, signed in, and the **Board** tile; the
twelve `-plane-*` containers and the one-shot migrator appear in `docker ps` ("What runs"); `./stop.sh` removes them and
keeps their data volumes. `UI_PLANE` sits under the `UI_START` master switch like every UI; an existing `.env.local` that
already sets `UI_PLANE=true` keeps its instance as it was - the default changed, not your setting.

* **What the board costs**, measured on a 96-CPU host: `./build.sh` pulls 3.21 GB of images (2.74 GB unique); the
  board runs 12 containers that use about 1.1 GiB of RAM and about 2% of one core at idle; the first `./run.sh` takes
  about 6-8 minutes, about 3 of them Plane's 164 database migrations (`PLANE_MIGRATE_TIMEOUT`, default 1800 s,
  bounds the wait for them; a wait that a stalling docker daemon holds past it still passes when the migrator
  itself exited 0), and later starts take 1-3 minutes.
  Off (the default), none of this happens: no images pulled, no sidecars, no tile.
* `./build.sh` pulls the board's images (`./plane.sh pull`) when the board is on, so `./run.sh` pulls nothing.
* `./run.sh` (docker target, with the board on) starts Plane's twelve services as sidecar containers before the agent:
  `<CONTAINER>-plane-{db,redis,mq,minio,api,worker,beat-worker,web,space,admin,live,proxy}` on their own network
  `<CONTAINER>-plane-internal`, plus a one-shot migrator. The agent container joins `<CONTAINER>-plane`, where the
  board's proxy is the only other container, so no other board container can reach the agent. **No sidecar
  publishes a host port**: the board is reached only through the home port, at `http://plane.localhost:8000/` (the `*.localhost`
  host route, like `hindsight.localhost`). Its pages carry the harness's floating home badge, the same one as every
  other host route (`badge-host.conf`, to the home page on the port the browser is on): Plane's web app drops a link
  put into its page, so the route appends a small script after each page that keeps that badge there through the
  app's own render. The data stays in the volumes `<CONTAINER>-plane-{pgdata,redisdata,
  uploads,rabbitmq,proxy-config,proxy-data}`.
* On every start `./plane.sh seed` applies `plane/seed.py` through Plane's own Django shell: the admin
  `agent@do-agent-aws.local`, the instance flags that retire the setup wizard, the workspace `do-agent-aws`, this
  instance's project (named after `CONTAINER`, identifier `AGENT`, created through Plane's REST API so it has its
  states, shown as a Kanban board) and the agent's API token, and on the first seed turns Plane's telemetry off. Then
  it clears Plane's cache and **asserts the
  served** `/api/instances/` `is_setup_done` is true: Plane's web app gates the whole app on that cached value, so
  a database write, or even a successful sign-in, does not prove the wizard is gone. `./plane.sh` fails loud if it
  is not; `./run.sh` then warns and starts the agent anyway (`./plane.sh status` shows the sidecars).
* **Nothing phones home.** Plane's api queues a push of instance metrics (instance id, versions, counts, workspace
  slugs) to telemetry.plane.so at every start, which its worker runs before the first seed can turn telemetry off,
  and it asks api.github.com for the latest release at every start, with no setting to stop either. So the board's
  services run on an `--internal` network with no egress, and `OTLP_ENDPOINT` points Plane's metrics exporter at a
  closed loopback port (`http://127.0.0.1:9`): neither call can leave, and the release check falls back to the
  running version. Only the proxy also joins the agent's network; the browser's requests stay on loopback too.
* Secrets: `wd/plane/plane.env` (mode 600 in the mode-700 `wd/plane/`, created on the first `./run.sh`, gitignored)
  holds the admin password, the agent's API key, Plane's server keys and the passwords of its database, queue and
  object store, all random per install. The services get them only through mode-600 `--env-file` files derived
  from it (each written beside its target and moved into place), the seed reads them from stdin, and every start
  applies the database and queue passwords to an existing volume over stdin, so no value is on a command line, in
  the VERBOSE output or in a log (`wd/plane/migrator.log`, mode 600, has them masked). Delete the file to rotate
  everything on the next `./stop.sh` + `./run.sh`; the data stays.
* **One-click sign-in** (`PLANE_LOGIN_BYPASS=true`, the default): the home page's Plane tile opens a new tab (as
  every tile on the home page does) at
  `http://plane.localhost:<port>/__harness/sign-in`. `/agent/plane-signin.py` (loopback-only inside the
  container, reached through the home proxy on that host route only) signs the seeded admin in server-side with
  Plane's own email sign-in and redirects to the project's board with an ordinary Plane session cookie
  (host-only, for `plane.localhost`); a browser that already holds a valid session is just redirected. The
  password never reaches the browser. The home proxy turns its relative Location into an absolute one on
  `plane.localhost` at the port the browser is on, as it does for every host route's redirects ("Home page and
  reverse proxy"). It answers only a Host of `plane.localhost` - any other name (a
  DNS-rebinding page arrives with its own) gets 403 and no session - and only a request from the harness home page
  on the same port: its Origin, or for the tile's link click its Referer, must be `http://localhost:<port>`, so
  another site cannot sign your browser in (login CSRF); its answers may not be framed. A bookmark or a shared link
  to that URL gets the 403 as a page with a Harness home link for the same port. This is a loopback
  convenience with the harness's usual trust boundary: whoever reaches the loopback home port (through your SSH
  tunnel) lands in the board as the admin, as they already reach the writable terminal at `/tmux/`. Containers on
  the agent's docker networks are outside it: the home listener admits only loopback, the gateway of the agent's
  default route (the published port's path) and `UI_HOME_ALLOW_FROM`, and answers every other source 403, and the
  UI backends listen on 127.0.0.1 ("Home page and reverse proxy"). So the board's proxy, the one board container
  on the agent's network, gets 403 from the home port and no answer from the backends; with a user-set `NETWORK`
  its containers are refused the same way.
  Plane allows 30 anonymous calls a minute per caller, with no setting. The sign-in's CSRF request is one, counted
  against the agent container's address like `ui-status.sh`'s Plane row (about 2 a minute, the Agent loop page's
  service refresh). The home page's Plane dot sends the browser's address instead, so open tabs do not spend the
  sign-in's budget; they share the browser's own budget with Plane's login page, the fallback the sign-in's failure
  page names. Every open home tab probes the dot when it loads and every 15 s after, and does not pause in a
  background tab; a failed probe is also tried again every 10 s. So about seven open home tabs fill that minute: the
  dot then reads starting or down while the board is up (the home proxy answers the probe's 429 as a 500), and
  Plane's login page can meet the same 429. This relies on the board's proxy keeping a forwarded address from every
  sender, as `makeplane/plane-proxy:v1.4.2` does by default (its Caddyfile trusts `0.0.0.0/0` unless
  `TRUSTED_PROXIES` is set, and `plane.sh` sets none): a `TRUSTED_PROXIES` that leaves out the agent container puts
  the dots back on the container's address. A 429 that asks for at most 10 s is waited out and the request sent once
  more; otherwise the page names the limit and the wait.
  `PLANE_LOGIN_BYPASS=false` turns it off: the tile opens Plane's login page; the login is in `wd/plane/plane.env`.
* **What the agent mirrors**: `/agent/plane-sync.py`, called by `loop.sh` and `loop-once.sh` after a fire's BEGIN
  and END line, keeps one work item per goal in `AUTONOMY_LOOP_GOALS` (checkbox items and `## Goal` headings;
  Plane's own integration keys `external_source`/`external_id`, so re-runs never duplicate) - or, while there is no
  goals file, in the shipped default goals the loop fires on then (`/agent/goals-default.md`: one standing goal, the
  Slack inbox): Todo, then In Progress while a fire works on it, then Done when the fire checked it off or In Review
  when it stayed open, with the fire's result as a comment and a "Last fire" note in the description. Best effort:
  it is bounded by `timeout 30` and a board outage only logs one `PLANE ... not mirrored` line in `loop.log` - the
  fire is unchanged. Header `X-Api-Key`, the token from `plane.env`.
* **The board has the goals from the first start**, before any fire (and with Slack off, when the loop does not
  run): at container start `/agent/ui-start.sh` runs `plane-sync.py seed` in the background, which waits for the
  board (up to `PLANE_SEED_WAIT` seconds, 300 by default) and mirrors the goals, so a new instance's board shows the
  standing goal. A start never waits for it, a later start's seed never duplicates a work item, and a board that does not come up
  only leaves a line in `/wd/ui/plane-seed.log`. Once a goals file exists, the default goals' work item moves to
  Cancelled (a fire on the default goals that created the file posts its result there).
* **The agent's board tool**: `/agent/board.sh` is how the agent - its tmux session, a loop fire, the Slack
  responder - reads and writes the board, and its CLAUDE.md says which command to use when
  (`agent-rules/AGENT_BOARD.md`). Two writes look alike and are not the same. `board.sh create "<title>" [--note
  "<text>"]` **tracks** work: a Plane work item in Todo that is not a goal, so the autonomy loop never works on it and
  the mirror never moves it (it carries the tool's own key, `external_source` `do-agent-aws-board`). Tracked work lives
  on Plane only: the Goals board's sync is two-way and makes every card created there a goal ("Kanban board").
  `board.sh create --goal "<goal>"` **gives the loop a goal**, through `goals-add.sh`. `board.sh list` shows the goals
  (G1, G2, ... in the goals file's order, with their work items and states), then the tracked work. `board.sh move`
  takes tracked work to any state, and a goal only to done or open: its checkbox in the goals file, one atomic
  rewrite under `${AUTONOMY_LOOP_DIR}/goals.lock`, never while the loop is firing, then mirrored (a goal's In Progress
  and In Review are its fires'). `board.sh comment` posts on a work item, masked like a fire's result. At every start
  `/agent/board-settings.sh` puts three things in the agent's Claude configuration: the allow rule
  `Bash(/agent/board.sh:*)`, so the tool runs without a permission prompt, which a headless call or the Agent chat
  page cannot answer; Edit deny rules on the tool's own files, the mirror's state file and the board's secrets, so
  the rule never runs code a session wrote; and the usage, referenced from CLAUDE.md. Without a Plane board on the
  target, `board.sh` lists and changes the goals only.
* `./stop.sh` removes every container and the networks that carry the label `do-agent-aws.plane=<CONTAINER>`,
  after the agent container, and keeps the volumes. `./plane.sh status` shows the services, the volumes and the
  served setup state; inside the container `ui-status.sh` has a `plane` row (UP only when the board serves
  `is_setup_done` true) and a `plane-signin` row.
* Tests: `./test-plane.sh dry` (run by `test.sh`, docker stubbed: the 13 sidecar commands publish no port, carry
  the label and no secret, only the proxy joins the agent's network, the agent has one published port, and the log
  filter and the datastore passwords keep every secret off all command lines), `./test-plane.sh live` (with
  `./run.sh` up: the served setup state, the API key, the sign-in from the home page and its session, refused from
  anywhere else or for a foreign Host, no host port, no agent port reachable from the board's api container), and the in-container offline `test19.sh` (routes, the tile and its status-only probe
  `/__probe/plane` with the browser's address, the redirects kept on `plane.localhost`, the home badge, the sign-in against a stub Plane and its rate limit, ui-status, the mirror
  and the loop hooks, refusals, the start's seed, the board tool and its settings; check 11, `TEST19_CLAUDE=true`, runs a headless claude against the stub board).
* Images: Plane's own (`makeplane/plane-{backend,frontend,space,admin,live,proxy}:v1.4.2`) and its compose file's
  datastores (`postgres:15.7-alpine`, `valkey/valkey:7.2.11-alpine`, `rabbitmq:3.13.6-management-alpine`). The object
  store is pgsty/silo (https://github.com/pgsty/silo, a fork of MinIO, AGPL-3.0), whose image is
  `pgsty/minio:RELEASE.2026-08-04T00-00-00Z`, the one Plane's next release (v1.4.3) ships, because upstream's
  `minio/minio` can no longer be pulled anonymously (makeplane/plane#9834). All are set in `.env` (`PLANE_*_IMAGE`).
* Targets: docker only. The compose, swarm and kubernetes targets do not run the board yet; there the tile says
  the board is not on this target.

## Board

The home page's **Board** tile (`http://board.localhost:8000/`, `UI_BOARD=true` by default, shown only while the Plane board is
on - `UI_PLANE=true`, see "Plane board") is a read-only kanban
view the harness renders itself over two things it already runs: the Plane project of this instance and the agent runner.

* **What it shows.** The project's states as columns, in Plane's order (Backlog, Todo, In Progress, In Review, Done,
  Cancelled), and its work items as cards: the key (`AGENT-3`), the name, the priority and the time of the last change -
  the agent's goals, which `/agent/plane-sync.py` mirrors around every loop fire. Never a description (a fire's transcript
  excerpt lives there) and never a person. On a card, the agent runner's attempts that belong to it: an attempt (a
  vibe-kanban workspace, read from the runner's local API) shows on a card when its name or branch carries the card's
  key as a whole token (`AGENT-3`, not `AGENT-30`), with its branch, whether an agent session is running, and what git
  reports for its worktree. Attempts that name no card are listed below the columns.
* **Read-only, by construction.** `/agent/board-server.py` (python standard library, `127.0.0.1:8096`) answers GET and
  HEAD only; the home proxy's `board.localhost` route refuses every other method too. Nothing on the page acts on the
  board or the runner. Every 30 seconds one background pass reads Plane (three or four calls, however many browsers are
  open: the agent's API key is rate-limited to 60 calls a minute) and the runner, and keeps the result as the one
  snapshot every request is answered from; the page re-fetches it on the same cadence. The agent's API key is read from
  `wd/plane/plane.env` (`PLANE_AUTH_FILE`) at each pass, sent as `X-Api-Key` to the Plane proxy only, and is in no page,
  URL or log line; the data endpoint `/api/board` answers its own origin only (another `Origin`, or a `Sec-Fetch-Site`
  other than `same-origin` or `none`, gets 403), every response says `Cache-Control: no-store`, the policy is the page's own
  origin alone (the route adds exactly the hashes of the home badge's three inline pieces: its style attribute and
  phone-width rule in `style-src`, its keeper script in `script-src`), and the page builds its DOM with `textContent`
  only.
* **An honest dot.** The tile's dot reads `/__probe/board`, the server's `/healthz`: 200 only while the last pass is fresh
  and Plane answered, 503 otherwise - so the dot goes red for a stopped server and for a board that lost Plane, and the
  page then shows the last good view marked stale, with the reason. The runner being down is a notice on the page, not a
  red dot: the runner has its own tile.
* **With the Plane board, or not at all.** The Board reads Plane, so it runs only while the Plane sidecars run on this
  target (`UI_PLANE=true`, docker target). With the Plane board off (`UI_PLANE=false`, the default) there is no Board tile
  at all; with it on but not on this target (compose, kubernetes) the tile is grey with that reason; `UI_BOARD=false`
  turns it off like any other UI.

`test-board.sh` proves each of these against a stub Plane API and a stub runner on loopback: the columns and a card
in the snapshot, the planted key absent from every response and the log (and caught once a control plants a leak),
every other method and a foreign origin refused, the dot following the probe, the tile greyed for each reason and absent with
the Plane board off, the North Star
section equal to the shipped register (a planted mismatch fails), the home badge once on the route under that policy.
