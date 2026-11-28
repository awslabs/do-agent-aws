# Installing and running

How to install the harness, run it, configure it and keep its state. Part of the [Do Agent on AWS manual](README.md).

Contents:

- [Installation](#installation)
- [Container project description](#container-project-description)
- [What runs](#what-runs)
- [Settings](#settings)
- [Setup doctor](#setup-doctor)
- [Docker Sandboxes](#docker-sandboxes)
- [Persistent agent state](#persistent-agent-state)
- [Container user](#container-user)
- [Git identity](#git-identity)

## Installation

Prerequisites (`./build.sh` checks the first three and names what is missing; `./run.sh` checks the Docker ones again
before a start):

- **Docker Engine with the BuildKit builder.** Ubuntu 22.04+ / Debian 13+: `sudo apt install docker.io docker-buildx`
  (the `docker.io` package alone has no `docker buildx`; `./build.sh` says so and stops before building); Debian 12
  has no `docker-buildx` package - use [Docker's own packages](https://docs.docker.com/engine/install/), which
  include `docker-buildx-plugin`.
- **Your user in the `docker` group**: `sudo usermod -aG docker $USER`, then log out and in again (or `newgrp docker`).
- **About 30 GB of free disk** where Docker keeps its images (`/var/lib/docker`): the image is about 12 GB and its
  build cache about as much again - a fresh build took disk use from 2 GB to 29 GB. A cloud image's default 8 GB
  root volume is too small: give the machine a root volume of 40 GB or more before building. `BUILD_MIN_FREE_GB`
  (the environment wins over the `.env` default of 30) is the threshold `./build.sh` checks.
- **Free Docker address pools.** Every bridge network takes a subnet from Docker's default address pools (31 unless
  `/etc/docker/daemon.json` sets `default-address-pools`), and one harness instance takes four: its own network, the
  board's internal one and the docker spoke's build substrate's two (two with `SPOKE_DOCKER=false`; the Plane board, off
  by default, adds its two with `UI_PLANE=true`). Both
  scripts print `N of T in use, F free`; `./run.sh` refuses to start when fewer are free than it needs, because the start
  would fail with "could not find an available, non-overlapping IPv4
  address pool", and names the stale networks of past instances that have no container left plus the command that
  removes every unused network, `docker network prune`. Neither script prunes anything itself.
- **git**, and **AWS credentials that can call Amazon Bedrock** in the region you choose (see "AWS credentials" and
  [docs/bedrock/README.md](../bedrock/README.md)).

No registry account is needed: the image builds and runs locally as `do-agent-aws:latest` (`REGISTRY` is empty
by default in `.env`; set it only to push).

```bash
git clone https://github.com/awslabs/do-agent-aws.git
cd do-agent-aws
export AWS_REGION=us-east-1    # a region where your account has Bedrock model access
./build.sh      # builds the image: Claude Code + plugins, the memory server, every UI; tens of minutes the first time
./run.sh        # starts the container; the ONLY published port is 127.0.0.1:8000
```

Your own settings (Slack, the git identity, ports, which UIs run) go in `.env.local`, which `git pull` never touches;
`.env` keeps the defaults (see "Settings").

Credentials, one of two ways - and only one:

- **On EC2 with an instance role** (the role allows `bedrock:InvokeModel*`): set nothing. Leave `AWS_PROFILE` unset;
  the container picks the role up through IMDS.
- **With a named profile** from `~/.aws/config` (keys or SSO): `export AWS_PROFILE=myprofile` before `./run.sh`, with
  the profile's actual name - `run.sh` passes it through and mounts `~/.aws` into the container (read-write: an SSO
  login's cache refreshes in place; see "AWS credentials"). Static
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` variables work the same way.

Open `http://localhost:8000` (from another machine: `ssh -L 8000:localhost:8000 user@host` first). The
home page lists every UI with a live up/down dot; the first start copies the image's baked agent state
(plugins, settings, the initialised memory database) into `wd/agent-state`, which can take a few minutes
on a slow disk - later starts take well under a minute - and then all of them are green:
the Guide, Headlamp, Memory (Hindsight, with its API docs), Agent workspaces (vibe-kanban), Conversations
(the Comms UI), the browser terminal with the agent's Claude session in it, the tmux cheatsheet, the
tmux-agent dashboard, Session memory (the claude-mem viewer), Session insights (LogLearner), the Agent loop page
(see "Agent loop page") and Files, the shared folder between you and the agent (see "Files"). Every tile's dot turns green once its service is up; on the first start the
tmux-agent dashboard is built from its public source (see "tmux-agent dashboard"), so its dot can be the last.
The memory store starts non-empty: two Hindsight banks, of general AWS, container, Claude Code and
harness knowledge and of starter rules, are loaded on the first start and can be browsed in the memory UI,
queried through the API and reached by the agent over the `hindsight` MCP tools ("Agent memory" below), and the
agent gets that knowledge four ways: the PreToolUse hook injects the matching rules into its Edit, Write and Bash
calls on its own (the same records, in the LogLearner bank, beside the image's example knowledge pack of GPU
cluster troubleshooting); a copy in `/wd/knowledge/defaults` that its CLAUDE.md points to and a skill indexes -
what a headless loop fire, which may Read and Grep but not call the memory tools, actually uses; `/agent/recall.sh` searches every bank
on request, also from a loop fire; and the Hindsight UI shows each bank (its bank selector lists the two seed banks) -
"Agent learning tools" below. The agent's own session memory - what its hooks write and recall automatically -
lives in a per-repository bank of the same store; both survive `./stop.sh && ./run.sh`.

`./test.sh` runs the whole in-container suite (`test3` fires the autonomy loop against Bedrock and
skips itself without credentials; `test15` and `test17` prove memory extraction when Bedrock is reachable
and say so when it is not; everything else is offline). `./exec.sh` lands in the agent's tmux
session; `./logs.sh` tails the container; `./stop.sh` removes it and every sidecar, keeping all state under `wd/` (`./stop.sh -s`
removes the agent container alone - see "Restart only the agent container").

## Container project description

This is a Depend on Docker project which comes operational out of the box 
and is configured with reasonable defaults, which can be customized as needed.


The project contains the following scripts:
* `config.sh` - open your settings file `.env.local` in an editor (see "Settings"); `.env` holds the defaults
* `build.sh` - build the container image
* `test.sh` - run container unit tests
* `push.sh` - push the container image to a registry
* `pull.sh` - pull the container image from a registry
* `run.sh [-s|--single] [cmd]` - run the container, passing an argument overrides the default command; a start that fails, or that leaves
  the agent container not running, exits non-zero with one `run.sh: ERROR` line saying why (`test-run.sh`); `-s` starts the
  agent container alone and joins it to the boards and the build substrate that already run (see "Restart only the agent container")
* `stop.sh [-s|--single]` - remove the containers: every container and service of the instance by default, the agent container
  alone with `-s` (see "Restart only the agent container"); `test-stop.sh` proves both
* `plane.sh pull|init|start|seed|up|down|status` - the self-hosted Plane board's sidecar containers; `build.sh`, `run.sh` and `stop.sh` call it, only with `UI_PLANE=true` - the board is optional and off by default, its license being AGPL-3.0 (see "Plane board")
* `status.sh` - show container status - running, exited, etc.
* `logs.sh` - tail container logs
* `exec.sh [-s|--shell] [cmd]` - open a shell or execute a specified command in the running container; `-s` starts a plain bash shell instead of attaching to the shared tmux session, `-h` displays usage
* `kanban.sh build|init|up|down|status` - the self-hosted kanban board's server image and sidecar containers; `build.sh`, `run.sh` and `stop.sh` call it (see "Kanban board")

## What runs

`./run.sh` (docker target) starts **6 containers** on this host with the shipped defaults, **18 with the Plane board on**
(`UI_PLANE=true`; the board is optional and off by default, its license being AGPL-3.0 - see "Plane board"), every one
named after `CONTAINER` (`do-agent-aws` by default, so the names below read `do-agent-aws-plane-db` and so on) and every
one on loopback: the only published port is the agent container's home port, `127.0.0.1:8000`. One is the agent, three
are the Goals board, two are the docker spoke's build substrate ("Docker agent") and, with the Plane board on, twelve are
the Project board. `./run.sh -s` starts the first of them alone, the agent container, and joins it to the boards and the
substrate that already run ("Restart only the agent container" below).

| Container | Image | What it does | Board | Data |
|---|---|---|---|---|
| `do-agent-aws` (the name itself) | `do-agent-aws:latest`, built by `./build.sh` | the agent: Claude Code in tmux, the home page and reverse proxy, every harness UI, the memory API, the autonomy loop | - | bind mounts under `wd/` beside the checkout ("Persistent agent state"); `wd/files` among them is the Files tile's shared folder ("Files") |
| `-kanban-server` | `do-agent-aws-kanban:latest`, built by `./build.sh` from the pinned vibe-kanban source | the Goals board's server: its API and pages, behind `kanban.localhost` | Goals board | - (its state is in the database) |
| `-kanban-db` | `postgres:16-alpine` from ECR Public, by digest (`KANBAN_POSTGRES_IMAGE`) | the Goals board's database | Goals board | volume `<CONTAINER>-kanban-db` |
| `-kanban-electric` | `electricsql/electric:1.4.13`, by digest (`KANBAN_ELECTRIC_IMAGE`) | the Goals board's live sync | Goals board | volume `<CONTAINER>-kanban-electric` |
| `-plane-db` | `postgres:15.7-alpine` | Plane's database | Project board | volume `<CONTAINER>-plane-pgdata` |
| `-plane-redis` | `valkey/valkey:7.2.11-alpine` | Plane's cache and session store | Project board | volume `<CONTAINER>-plane-redisdata` |
| `-plane-mq` | `rabbitmq:3.13.6-management-alpine` | Plane's task queue | Project board | volume `<CONTAINER>-plane-rabbitmq` |
| `-plane-minio` | `pgsty/minio:RELEASE.2026-08-04T00-00-00Z` | Plane's object store (uploads): pgsty/silo, a fork of MinIO (AGPL-3.0) | Project board | volume `<CONTAINER>-plane-uploads` |
| `-plane-api` | `makeplane/plane-backend:v1.4.2` | Plane's REST API | Project board | - |
| `-plane-worker` | `makeplane/plane-backend:v1.4.2` | Plane's background worker | Project board | - |
| `-plane-beat-worker` | `makeplane/plane-backend:v1.4.2` | Plane's scheduler of periodic tasks | Project board | - |
| `-plane-web` | `makeplane/plane-frontend:v1.4.2` | Plane's web app | Project board | - |
| `-plane-space` | `makeplane/plane-space:v1.4.2` | Plane's public-pages app | Project board | - |
| `-plane-admin` | `makeplane/plane-admin:v1.4.2` | Plane's instance-admin app | Project board | - |
| `-plane-live` | `makeplane/plane-live:v1.4.2` | Plane's live-collaboration server | Project board | - |
| `-plane-proxy` | `makeplane/plane-proxy:v1.4.2` | Plane's front door (Caddy), the one board container on the agent's network, behind `plane.localhost` | Project board | volumes `<CONTAINER>-plane-proxy-config`, `<CONTAINER>-plane-proxy-data` |
| `-buildkit` | `moby/buildkit`'s rootless release image (`DOCKER_BUILDKIT_IMAGE`) | the BuildKit daemon, as an unprivileged user: builds the agent's images; its socket is on a volume the agent container mounts | Build substrate | volumes `<CONTAINER>-buildkit-cache` (the build cache), `<CONTAINER>-buildkit-socket` (a small tmpfs) |
| `-registry` | `registry:3.1.2` | the stack's registry, `registry:5000`: the images the agent builds | Build substrate | volume `<CONTAINER>-registry-data` |

The twelve `-plane-*` rows (the Project board) exist only with the Plane board on, `UI_PLANE=true` in `.env.local`; with the
shipped default nothing of them is pulled or started ("Plane board").

Two more names appear at times:

* `-plane-migrator` (`makeplane/plane-backend:v1.4.2`, with the Plane board on): Plane's database migrations, a fresh container on every start
  that is removed once it exits 0 (its log is `wd/plane/migrator.log`); after a failed migration it stays, for
  `docker logs`, and `./run.sh` warns.
* `-kanban-relay` (`do-agent-aws-kanban-relay:latest`): the Goals board's relay, a nineteenth container only with
  `UI_KANBAN_RELAY=true` ("Kanban board").

They sit on four networks by default, six with the Plane board on, each a subnet from Docker's address pools
("Quickstart"): `<CONTAINER>-kanban` (the agent and the board server, plus the relay), `<CONTAINER>-kanban-internal` (the
board server, its database and Electric; no route out), `<CONTAINER>-docker` (the agent and the registry; no route out),
`<CONTAINER>-docker-build` (the daemon and the registry, with egress for base images) and, with `UI_PLANE=true`,
`<CONTAINER>-plane` (the agent and Plane's proxy) and `<CONTAINER>-plane-internal` (all twelve Plane containers; no route
out). The agent container itself is on the boards' outer networks and the registry's internal one and on nothing else,
so no board container but the servers it talks to, and no build step, can reach it ("Kanban board", "Plane board",
"Docker agent").

**Seeing them.** `docker ps` lists them all (six, eighteen with the Plane board on); `./status.sh` lists every container whose name carries `CONTAINER`,
running or exited (`docker ps -a | grep do-agent-aws`; on the compose target, `docker compose ps -a` with the board's
overlay); `./plane.sh status` and `./kanban.sh status` add each board's volumes, its secrets or login file and its
setup state, and `./docker.sh status` the build substrate's containers and volumes and whether each answers; the home
page shows each board's tile with a live dot. `./stop.sh` removes all of them (it calls `./kanban.sh down`,
`./docker.sh down` and `./plane.sh down` after the agent container) and keeps every volume and everything under `wd/`,
so the next `./run.sh` starts with the same data; `./stop.sh -s` removes the agent container alone and leaves the
sidecars running (next paragraph); `docker volume rm` of a board's volumes deletes that board's data, and
of the substrate's volumes its build cache and its registry's images.

**Restart only the agent container.** Rebuilding or reconfiguring the agent does not need the boards and the build
substrate to stop and start again: `./build.sh && ./stop.sh -s && ./run.sh -s` (`--single` is the same flag) removes
and starts the agent container alone. `./stop.sh -s` runs the session ledger's `record-stop` and `docker container rm
-f -v` of the agent container and none of the three `down` scripts, so the kanban board, the Plane board and the build
substrate keep running with their networks; `./run.sh -s` starts no sidecar and joins the new agent container to what
runs, as a full start does: the Plane board's network and the kanban board's when they exist, the build substrate's
socket volume and network when its network, its socket volume and its daemon and registry containers are there (what
`./docker.sh up` leaves). On the docker target a board whose network is not there, or a substrate that is not running,
is one `WARNING` naming it, and the agent starts without it (`./stop.sh -s && ./run.sh` brings it: each `up` leaves a
running sidecar alone); a substrate not running at a single start is marked `DOCKER_SUBSTRATE=not-running`, which the
Docker spoke's rows show as DOWN with that reason. The preflight still runs (disk, the engine) and, on the docker target,
counts no address pool for `-s`, which creates no network there. Without the flag both scripts do everything: that
is the default. The flag applies to the docker and compose targets (`TO=compose`: `up -d --no-deps` and
`rm -s -f -v` of the agent service, with the board's overlay files as `./run.sh` rendered them); on swarm, kubernetes
and the sandbox, where the instance is one unit, it is refused by name (exit 2). Only a leading `-s` or `--single` is
read as the flag: `./run.sh <command>` runs the command, and `./stop.sh` refuses any other argument
with its usage line (`-h` prints it). `test-run.sh` (check 12) and `test-stop.sh` prove this offline.

**Running fewer, or more, per host.** Put the switch in `.env.local` (never in `.env`): the Plane board is off by default
(`UI_PLANE=false`: no Plane container is built or started, nothing of it is pulled by `./build.sh`, and the home page has
no Plane tile and no Board tile) and `UI_PLANE=true` turns it on if its AGPL-3.0 license is acceptable to you - twelve
more containers, pulled by `./build.sh`, and the two tiles appear ("Plane board");
`SPOKE_DOCKER=false` starts neither build substrate container and no docker spoke (two fewer, nothing pulled by
`./build.sh`; the Docker spoke tile shows as off),
`UI_VIBE_KANBAN=false` builds and starts no Goals board container (three fewer; the Goals board tile shows as off), and
`UI_START=false` runs no UI at all. The narrower `PLANE_RUN_OPTS=""` keeps Plane's twelve from starting while the tile
stays configured (it then reads down). For the Goals board use its UI flag: its run options and the agent's network
option are derived together in `.env`, and emptying `KANBAN_RUN_OPTS` alone would send the agent container to a
network that does not exist. On swarm and kubernetes targets no board runs.

## Settings

`.env` holds every setting with its default and its description, and it is tracked: `git pull` updates it. Your
own settings go in `.env.local` beside it, which is gitignored: lines of `export NAME=value`, each a line of `.env`
copied and changed. `.env` reads `.env.local` after its defaults, and then itself once more with your settings kept,
so every value derived from one of them (the container's `-e` options, the port and volume maps, the test
container's options, the rendered compose and kubernetes files) follows yours, and a default that changes upstream
still reaches you unless you set it yourself. `./run.sh` and `./build.sh` create `.env.local` on their first run,
with a few commented lines for the settings people change most; `./config.sh` opens it in an editor.

If you edited `.env` itself before `.env.local` existed, `git pull` stops with "Your local changes to the following
files would be overwritten by merge: .env". Then run `git stash && git pull && git stash pop` and start once with
`./run.sh` (or `./build.sh`). On that first run `./env-local.sh` moves your edited `export NAME=value` lines into the
new `.env.local`, keeps the edited file as `.env.edited-<UTC time>` (gitignored too) and restores `.env`, so the next
`git pull` goes through. It moves nothing, and prints the lines for you to move by hand, when `.env.local` already
exists or when your edit to `.env` changes more than settings; `git checkout -- .env` restores the file after.
`ENV_LOCAL_SETUP=false` skips the step.

The model settings, each a knob shipped on, overridden in `.env.local` (the docker, compose and kubernetes targets follow it:
the container's `-e` options, the test container's, and the compose and kubernetes files rendered from the templates;
`TO=sandbox` keeps its kit's pinned model) and documented in "Bedrock connectivity" ("The model") and in `.env`'s own comments:

| Setting | Shipped default | Reaches the container as | Empty | Prerequisite |
|---|---|---|---|---|
| `AGENT_MODEL` | `us.anthropic.claude-fable-5-1[1m]` - Claude Fable 5.1 through the `us.` inference profile; `[1m]` is Claude Code's request for the 1M-token context window | `ANTHROPIC_MODEL` | nothing is passed; Claude Code uses its own Bedrock default (`us.anthropic.claude-opus-5-5[1m]` for the Claude Code in this image), which the doctor names | model access to Claude Fable 5.1 in `AWS_REGION` ([docs/bedrock/README.md](../bedrock/README.md), step 1); an account without it sets another id it can call, `us.anthropic.claude-opus-5-5[1m]` keeping the 1M window |
| `AGENT_EFFORT` | `max` - the deepest effort level, applied to every session | `CLAUDE_CODE_EFFORT_LEVEL` | nothing is passed; the model's own default effort applies (`auto` makes Claude Code send no effort level) | a model with effort levels (Fable 5.1 and Opus 5.5 offer low, medium, high, xhigh, max) |
| `AGENT_MODEL_OPUS` | `us.anthropic.claude-opus-5-5[1m]` - the id the `opus` alias resolves to | `ANTHROPIC_DEFAULT_OPUS_MODEL` | nothing is passed; Claude Code's own alias default applies | model access to Claude Opus 5.5 in `AWS_REGION` |
| `AGENT_MODEL_FABLE` | `us.anthropic.claude-fable-5-1[1m]` - the id the `fable` alias resolves to | `ANTHROPIC_DEFAULT_FABLE_MODEL` | nothing is passed; Claude Code's own alias default applies | model access to Claude Fable 5.1 in `AWS_REGION` |

The compose and kubernetes templates list the four by name and pass an empty setting as an empty value (the docker target
passes nothing); an empty `ANTHROPIC_MODEL` left Claude Code on its own default model when measured. The doctor's `bedrock`
row shows the model in effect, where it comes from and the context window ("Setup doctor"); a model pinned in the `env` block
of the agent's `settings.json` outranks these settings, as it does for Claude Code, and the row names `settings` as the source then.

## Setup doctor

`/agent/doctor.sh` says what is set up in the container and what is not, in the order a person sets it up:

* Bedrock: a one-token Converse call with the model id Claude Code uses here - `AGENT_MODEL` from the settings, whose
  `[1m]` suffix is read as the request for the 1M-token context window and left out of the call (see "Bedrock
  connectivity"). The inference-profile rule is checked first: an Anthropic model is called through the `us.`, `eu.` or
  `apac.` profile of the region's geography.
* git identity, and whether `GIT_USER_NAME` and `GIT_USER_EMAIL` in the settings carry it.
* an EKS cluster: the kubeconfig and `kubectl auth can-i`; with none, `aws eks list-clusters` across regions; Headlamp's
  list.
* Slack, through `/agent/slack-doctor.sh`: the token, its scopes against the app manifest the skill prints, each
  channel; nothing is posted unless the person runs its `--post-test` round-trip in `SLACK_TEST_CHANNEL`.
* GitHub (`gh auth status`, `gh repo view`), memory (the memory API, the default seed's extraction, a known fact
  recalled), the shared knowledge packages (the repositories cloned under `/wd/knowledge`, checked against their
  record, and the packs imported on the Knowledge transfer page, each listed as loaded once the ledger of each of its
  stores carries it), the tmux-agent dashboard with every tile that is switched off, and the spokes of the agent stack:
  each one live, without a session or off, and the line that turns one off, the home page's sentence: "To turn one off,
  set SPOKE_<NAME>=false in .env.local, then ./stop.sh && ./run.sh."
* image builds: the docker spoke's BuildKit daemon answers, the stack's registry answers, and the disk where Docker
  keeps the build cache and the images has `DOCKER_MIN_FREE_GB` free ("Docker agent").

Each check is PASS, GAP or SKIP (the person said it is not needed: `--not-needed <check>`; `--needed <check>` undoes
it); a gap that needs a part of the skill this release does not ship yet names it under "not in this release yet". For
each gap it prints what the agent does now inside the container, the exact lines the person runs on the host, and the
command that verifies both. The split follows the boundary: the person's settings live on the host, in `.env.local`
(see "Settings"), `~/.aws` and `~/.kube`. The agent leaves them to the person, although the checkout and those folders
are mounted into its container, and it cannot restart the container.

Run it inside the container (`./exec.sh`, the browser terminal, or `docker exec <container> /agent/doctor.sh`).
`--brief` prints the table alone and `--check <id>` repeats one check. `--model`, `--cluster` with `--region`, and
`--repo` name what to check when the person has said it. It writes only under `/wd/setup/`: the table (`doctor.txt`),
the same as JSON (`doctor.json`), the skipped checks, kubectl's discovery cache and the Slack doctor's temporary
files, removed after each run. No credential value is printed or written. It exits 0 when every check passes or is
skipped, 1 otherwise. `test23.sh` proves it offline with stub tools: on an unconfigured instance every check is a gap
with host lines and a verification, every check passes once configured (the shipped model id reaches Bedrock without its
`[1m]` suffix), a wrong model id fails Bedrock, nothing is written outside `/wd/setup/`, and planted credentials are
masked.

A GitHub token reaches the container as `GH_TOKEN` from the AWS Secrets Manager secret the container reads at start
("Credentials from AWS Secrets Manager"); exported on the host before `./run.sh` it works too, with a start WARNING
(`GITHUB_ENV_OPTS` in `.env` passes it with a bare `-e`, like the Slack token).

**The harness-setup skill.** In the agent's session, `/setup` (or "help me finish setting up", "what do I still need to
set up") starts the `harness-setup` skill. It runs the doctor, shows its table and walks the gaps in order, one question
at a time: it does the inside part, prints the host part, waits for the person and verifies with the doctor. It also
carries three quickstarts as conversations: working through the agent, starting a project, and installing your own. The
skill and its `/setup` command ship under `Container-Root/agent/skills/` and `Container-Root/agent/commands/`, and
`/agent/claude-skills-sync.sh` copies them into the agent's Claude configuration at the build and at every start (Docker
seeds the persisted configuration only once). For the turn it runs in, the skill pre-approves the doctor, the reads of
its own files, the read-only commands of its steps, and two writes: `git config --global`, the container's own git
identity, and `aws eks update-kubeconfig` with any arguments. By default that writes the container's `~/.kube/config`,
and `--kubeconfig` can point it at any other file the container can write. The container's `~/.kube/config` is the
agent's own unless the host's `~/.kube` is mounted there, read-write: then the doctor gives update-kubeconfig as the
person's host line and the skill is told not to run it, but the pre-approval does not tell the two apart. Its files lie
outside the session's working directory `/wd`, and Claude Code asks before a read there, so the same sync also adds
one rule to the configuration's `settings.json` that allows reading the skill's directory in every later turn.
`test23.sh` checks the skill's files, its install and its first turn (live when claude answers on Bedrock: under 25
lines, ending with one question).

## Docker Sandboxes

`to/sandbox` packages the harness as a [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)
workload kit (its end-to-end test passes in a local sandbox on a KVM host; it has not been run
in Docker's cloud yet), so it can run
in a microVM - on a host with KVM or in Docker's cloud - with its own
Docker Engine, a declared CPU/memory size, a network allowlist (the whole egress under a
deny-by-default policy), and the model key injected by the sandbox proxy instead of stored in
the image. With `export TO=sandbox` in `.env.local` the scripts above drive it: `./build.sh`
renders and builds the kit, `./run.sh` creates the sandbox, `./status.sh`, `./exec.sh` and
`./stop.sh` list, enter and remove it (`to/sandbox/README.md`, "`TO=sandbox`"). `to/sandbox/README.md` has
the commands for local and cloud sandboxes, the tests (four need no sign-in), and a worked
example in which the agent builds, runs and tests a Compose stack inside the sandbox.

## Persistent agent state

The agent's mutable state - Claude Code configuration, plugins, and session data (`/home/agent/.claude`),
claude-mem memory (`/home/agent/.claude-mem`), the hindsight hook runtime and its settings (`/home/agent/.hindsight`),
the hindsight memory database itself (the embedded PostgreSQL cluster at `/home/hindsight/.pg0`) and vibe-kanban's
state (its configuration, workspace database and signing key at `/home/agent/.local/share/vibe-kanban`) - is
persisted in the `wd/agent-state` folder of the project directory (`.claude`, `.claude-mem`, `.hindsight`,
`hindsight-pg0`, `vibe-kanban`) through mounts declared in `.env` (`AGENT_STATE_VOL_MAP`). So is the container's own
kubeconfig (`/home/agent/.kube`, under `.kube`, written by the agent's `aws eks update-kubeconfig`), unless the host's
`~/.kube` is mounted there instead. That kubeconfig is then the person's own: the setup doctor gives update-kubeconfig
as their host line, since it also makes the new context the current one, and the setup skill is told not to write it.
The mount is read-write, so nothing else stops the agent from writing it: in a `/setup` turn, the skill's pre-approved
`aws eks update-kubeconfig` would, without asking.
The compose template mounts no host `~/.kube`, so there the container's kubeconfig is always kept under `.kube`.
The mounts are bind-backed volumes, so on first run Docker seeds the image's baked plugins, settings and the
initialised memory database into the empty host folders; from then on agent memory and configuration survive
container restarts and replacement. Claude Code's configuration file lives inside the persisted folder
(`CLAUDE_CONFIG_DIR=/home/agent/.claude`). Set `AGENT_STATE_PATH_EXTERNAL` in `.env.local` to change the location, or set it
empty to run with ephemeral state.

On kubernetes nothing is persistent. The deployment (`to/kubernetes/template/020-deployment.yaml`) mounts an
`emptyDir` volume at `/wd`, where docker mounts the project's `wd` folder, so the goals file, loop notes, Slack
cursors, UI logs and comms journal outlive a restart of the container, but the volume is deleted with the pod: a
replaced or rescheduled pod starts with an empty `/wd`. The agent state directories above stay on the image and
start from its baked content in every new container. A volume over them needs a PersistentVolumeClaim populated
once from a running pod, because Kubernetes does not seed an empty volume with the image's content the way docker
does (the commented `agent-state` block in the deployment).

## Container user

The agent container runs as the unprivileged user `agent` (uid and gid 1000 by default), never as root: Claude Code,
the autonomy loop, the UIs, the memory API, the tmux sessions and every `docker exec` shell run as that user, with the
home `/home/agent`. The image's own files (the harness scripts in `/agent`, the tools, `/etc`) belong to root and are
read-only to the agent; what the agent writes is its home, `/wd` and `/tmp`. So a command the agent runs - its own, or
one a prompt injection talks it into - cannot change the harness, the system or another user's files, and cannot install
operating-system packages: tools come with the image (`Container-Root/setup/`), while `npm`, `npx`, `pip` and `uv`
installs into the agent's home work. Claude Code updates come with the image too (`DISABLE_AUTOUPDATER=1`).

* **uid and gid.** `AGENT_UID` and `AGENT_GID` (`.env`, default `1000`) are build arguments. 1000 is the uid of the rootless
  BuildKit daemon whose socket the agent uses and of a typical Linux host user, so the files the agent writes under `wd/`
  stay the host user's. On a Linux host whose user has another uid, set both in `.env.local` and run `./build.sh`. On
  macOS, Docker Desktop maps file ownership itself.
* **Upgrading from an image that ran as root.** On a Linux host, the files a root container wrote under `wd/` (agent state,
  loop state, logs) belong to root, and the agent cannot update them. Hand them over once, then start again:
  `sudo chown -R 1000:1000 wd && ./stop.sh && ./run.sh` (your `AGENT_UID:AGENT_GID` if you set them).
* **Kubernetes** enforces it in the pod (`runAsNonRoot: true`, `runAsUser: 1000`, `fsGroup: 1000`;
  `to/kubernetes/template/020-deployment.yaml`).
* **Docker Sandboxes** is the exception: its kit layer switches to root, because the agent runs a Docker Engine inside
  the sandbox microVM, which is the isolation boundary there (`to/sandbox/README.md` "Identity").
* **What the host runs is read-only inside.** `./run.sh` mounts the checkout at `/do-agent-aws`, the host's `~/.aws` and
  `~/.kube` READ-ONLY (`.env` `VOL_MAP`): every host script sources the checkout's `.env` and `.env.local`, `~/.aws/config`
  may name a `credential_process` command and a kubeconfig an `exec` plugin, so a container that could write them could
  run code as you on the host. The container writes `/wd` (the checkout's `wd/`), its own state and, when the host has
  them, the two token caches the AWS CLI and the SDKs refresh in place (`~/.aws/sso/cache`, `~/.aws/cli/cache`: data the
  host reads, never runs), so an SSO session still refreshes from inside. kubectl runs without its discovery cache there.
  Change a kubeconfig or an AWS profile on the host (the setup doctor gives the host line). `test-mounts.sh` (run by
  `test.sh`) proves it with real docker.
* **Changing the harness itself** (self-improvement) goes through a clone and a review: the agent clones the read-only
  checkout into the workspace, commits on a branch there, and you review and merge on the host:
  ```
  # in the container (the agent or you):
  git clone /do-agent-aws /wd/projects/do-agent-aws && cd /wd/projects/do-agent-aws && git switch -c agent/<topic>
  # ... edits and commits ...
  # on the host, in the checkout:
  git fetch wd/projects/do-agent-aws agent/<topic> && git log -p HEAD..FETCH_HEAD   # review, then merge or drop
  ```

## Git identity

A commit the agent makes carries the operator's identity, never a guessed or placeholder one. Set `GIT_USER_NAME` and
`GIT_USER_EMAIL` in `.env.local` (beside the GitHub token); at every container start `/agent/git-identity.sh` writes them as
the container's git configuration (`user.name`, `user.email`), with `user.useConfigOnly` so git never derives an
identity from the host name. Unset, the agent cannot commit: a thin wrapper ahead of the system git on `PATH` stops a
`git commit` that has no identity (from the environment, the repository's or the global configuration) with one line
naming the two variables, and nothing is committed - git's own "Author identity unknown" would stop it too, but in
its own words. An identity given another way, in the environment (`GIT_AUTHOR_*`/`GIT_COMMITTER_*`) or in a
repository's own configuration, passes, except the agent runner's placeholder: with no identity set, the runner writes
its placeholder author ("Vibe Kanban", a `noreply` address at its project's domain) into a repository's configuration
before it commits, and the wrapper refuses a commit under that author, by anyone, with one line saying how to remove it. The runner's automatic commit, the changes a
coding agent left uncommitted at the end of its turn, committed with the agent's last reply as the message, is off:
the wrapper refuses it with one line, and the changes stay in the workspace for the agent (the runner asks it to commit
them, with a message of its own) or you to commit; the runner's Merge action still commits its squash merge.
`VK_RUNNER_AUTO_COMMIT=true` in `.env.local` turns the automatic commit back on. Every other git command is the system git
untouched. The per-user excludes file the image ships (`setup/install-plugins.sh`) keeps the plugins' state
(`.omc/`, `.claude/*.local.md`, `.claude/settings.local.json`) out of every commit. `/test-git-identity.sh` proves it,
and `/test-runner-auto-commit.sh` the runner's two cases.
