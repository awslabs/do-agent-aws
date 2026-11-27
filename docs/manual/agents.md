# Spoke agents and the Docker agent

The supervisor, the spoke agents beside the hub agent, and the Docker agent's build substrate. Part of the [Do Agent on AWS manual](README.md).

Contents:

- [Spoke agents](#spoke-agents)
- [Docker agent](#docker-agent)

## Spoke agents

The `agent` session is the hub: the agent you talk to. A **spoke** is another resident Claude Code session beside it,
in a tmux session of its own, that keeps one dashboard's data current and answers the hub about it. The registry,
`Container-Root/agent/spokes/registry.json` (`/agent/spokes/registry.json` in the image), lists every agent session and
is the only source of what runs. Each spoke has a charter, its CLAUDE.md, in `Container-Root/agent/charters/<name>/`,
and a `.env` flag. The stack as a whole is described in [docs/AGENT-STACK.md](../AGENT-STACK.md) and how its agents talk
in [docs/INTER-AGENT-MESSAGING.md](../INTER-AGENT-MESSAGING.md); this section is the reference for the scripts.

| Flag | Spoke | The tile it keeps current |
|---|---|---|
| `SPOKE_CONVERSATIONS` | `conversations`: polls, classifies and journals the configured channels; stages replies, never sends | Conversations |
| `SPOKE_INSIGHTS` | `insights`: mines new session transcripts into rule candidates through the gates | Session insights |
| `SPOKE_CLUSTERS` | `clusters`: read-only status of every configured Kubernetes context | Headlamp |
| `SPOKE_SESSIONS` | `sessions`: the books of the container's tmux sessions from the dashboard's census (its cycle is not written yet) | tmux-agent dashboard |
| `SPOKE_LOOPS` | `loops`: the Loop Deck's topology and loop health | Loop Deck |
| `SPOKE_ISSUES` | `issues`: triages the open issues and pull requests in scope (conflicts, failing checks, requested changes, what needs a reply) and stages reply drafts; nothing posts without a person's GO through `post.sh` | Board |
| `SPOKE_DOCKER` | `docker`: builds container images through the stack's build substrate and keeps its page: the daemon, the registry and its images, the build cache, the disk ("Docker agent") | its own tile, which opens its page at `/docker/` |
| `SPOKE_EXAMPLE` | `example`: a timestamp every cycle and an answer to every question, from a shell loop that spends no model tokens - the way to see the scaffold work end to end | its own tile |

**Seven spokes ship on.** `SPOKE_CONVERSATIONS`, `SPOKE_INSIGHTS`, `SPOKE_CLUSTERS`, `SPOKE_SESSIONS`, `SPOKE_LOOPS`,
`SPOKE_ISSUES` and `SPOKE_DOCKER` ship `true` and `SPOKE_EXAMPLE` `false`, so a fresh clone's `./run.sh` starts seven
resident Claude Code sessions beside `agent`: `tmux ls` in the container shows `agent`, `clusters`, `conversations`,
`docker`, `insights`, `issues`, `loops`, `sessions` and `supervisor`. Each of the seven spends Bedrock tokens when `agent`
or a person talks to it. Their loops are scripts: the clusters loop makes read-only kubectl calls every 15 minutes (no
kubeconfig: it reports no context), insights mines transcripts hourly, loops reads local files every minute, the docker
loop reads the build substrate and the disk every 5 minutes ("Docker agent"), and sessions has no cycle yet. The
conversations loop makes Slack read calls every minute once `SLACK_BOT_TOKEN` and `SLACK_CHANNELS` are set, and until
then waits for Slack; the issues loop makes read-only GitHub calls every 15 minutes once `GH_TOKEN` is set, and until then
waits for GitHub. The issues spoke posts nothing itself: a draft reaches GitHub only through
`/agent/charters/issues/post.sh`, run by a person at a terminal after their GO names the draft's sha256. Its session
holds no GitHub token, and its deny rules and hook refuse the write paths; they bind its tools, not a sandbox, and
[docs/AGENT-STACK.md](../AGENT-STACK.md) section 7 states the limits. To
turn one off, set its flag to `false` in `.env.local` and restart (`./stop.sh && ./run.sh`); the home page's Agents
group lists the spokes that run and says the same.

**The cluster lock.** A job that touches a cluster takes a lease of the harness's cluster lock first and releases it
when it ends: `/agent/cluster-lock.sh run <cluster> --holder <name> --ttl <minutes> -- <command>` claims, runs the
command and releases, and `claim`, `queue`, `extend`, `release`, `status` and `reclaim-stale` are its other verbs. The
`clusters` spoke brokers the lock. `agent` asks it for a lease with a bus request (`{"kind": "gpu-lease", ...}`), and
its cycle answers from the view it has just read, scoped to GPUs on named nodes when they are free. The cycle also
reclaims expired leases. A lease is advisory and per harness: it reserves nothing from other people's workloads.
[docs/cluster-lock.md](../cluster-lock.md) has the state file, the verbs and the request and reply shapes.

**What starts.** At container start, after the `agent` session, `startup.sh` runs `/agent/supervisor.sh start`
(`SUPERVISOR=true`, the default). The supervisor starts each enabled spoke with `/agent/tmux-session-start.sh <name>`,
which reads the spoke's registry entry and:
- checks the entry and the charter (`/agent/spoke.sh check`) and refuses one that breaks a rule below;
- prepares the spoke's repository in `repo/` of its working directory, `/wd/<name>`. A `vendored: <path>` source is a
  link to the tree the image ships. A URL source is cloned at the entry's ref, anonymously: none of the container's git
  configuration, no credential helper, no prompt, https only. A later start refreshes a branch with
  `git pull --ff-only`. A source of `none` has nothing to fetch;
- writes the charter, byte for byte, as `/wd/<name>/CLAUDE.md`, marks the folder trusted for Claude Code (so it opens
  at its prompt), and starts the entry's command there in the tmux session `<name>` with the entry's environment;
- sets the session's lineage, which the tmux-agent dashboard shows: `@agent_parent agent`, `@agent_owner do-agent-aws`,
  `@agent_task <the entry's task>`; and `@agent_pane`, the pane it started, the only one the supervisor reads or types
  into (a window a person opens in the session is not it).

A spoke's session is on the same tmux server as `agent`, so `tmux ls`, the browser terminal's session picker (`C-b s`)
and the tmux-agent dashboard list it, under `agent`. The `agent` session itself carries `@agent_parent operator`,
`@agent_owner do-agent-aws` and its task from the registry, so the dashboard lists it as the person's, not as
ORPHANED (its word for a session no lineage claims).

**The supervisor** (`/agent/supervisor.sh start|status|ensure|stop|ledger|resume`) is a script that never calls a model, one loop at a
time; its tmux session, `supervisor`, shows the last pass as names and states. Every `SUPERVISOR_INTERVAL` seconds
(default 15, a whole number of at least 1), for the `agent` session and every enabled spoke:
- **Alive** means the session and a `claude` process in its agent's pane, the one `@agent_pane` names. A spoke without
  its session is started again: the first restart at once, each further one after twice the wait of the one before,
  starting at the entry's `cooldown_sec`. After `SUPERVISOR_RESTART_CAP` restarts without staying up
  `SUPERVISOR_HEALTHY_SECS`, the spoke is stuck and left alone until the supervisor starts again. The `agent` session is
  started again when it is gone; an `agent` pane that runs a shell is reported, never replaced. Each restart is a line
  in `/wd/supervisor/<name>/restarts.log`.
- **Stuck** means a menu is open, or the pane shows "API Error", "Prompt is too long" or a failed compaction, or a status
  line reads 80% context or more (`/agent/fleet-check.sh <session>` reads a pane the same way). The supervisor reports
  each one and answers nothing: no menu, no prompt that would send, spend or delete.
- **The one repair** is `/compact`, once, into a spoke's pane that is idle at an empty prompt line at 80% context or more;
  never into the `agent` pane, never at a menu, never while a turn runs. A send its read-back refuses is not counted
  and is tried again at the next pass. `/clear` is not in this version.
- **Health:** the memory API's `/health`, and the session-memory worker's queue depth
  (`SUPERVISOR_MEMORY_QUEUE_WARN`).
- **The Loop Deck's server** is the one UI the supervisor starts again. `ui-start.sh` starts it with
  `/agent/loop-deck-start.sh`, which records its pid in `/wd/ui/loop-deck.pid`. When that pid is no longer the Deck's
  server, the supervisor runs the script again the way it restarts a spoke: at once, then after
  `SUPERVISOR_DECK_COOLDOWN` seconds (default 60), doubling, and stuck after `SUPERVISOR_RESTART_CAP` restarts that did
  not stay up. Each restart is a line in `/wd/supervisor/loop-deck/restarts.log` and a notice to `agent`. A Deck stopped
  with `/agent/ui-stop.sh` (no pidfile) is left stopped. Restarting a UI is new here; the other UIs are not restarted.
- **Cycles:** a running spoke gets its entry's cycle every `cadence_sec` seconds, in its working directory, as
  `BUS_AGENT_ID=<name>`. The output goes to `/wd/supervisor/<name>/cycle.out`; a cycle that exits 0 writes `last-cycle`
  beside it. What the cycle leaves for the hub (the entry's `notices`) becomes bus notices from the spoke.
- **Waiting:** a spoke whose entry `requires` settings that are unset (environment variable names) waits: its session
  runs at its prompt, no cycle runs, nothing restarts and no notice goes out; its row, its tile and the supervisor's
  task line read "waiting for <what>" with what to set. The `conversations` spoke waits for Slack, `SLACK_BOT_TOKEN`
  and `SLACK_CHANNELS`, and the `issues` spoke for GitHub, `GH_TOKEN`, until they are set and the container starts
  again.
- **The session ledger:** each start, restart and stop of a session, the registry's and the scratch ones a person or
  `agent` starts, is a line of `/wd/supervisor/sessions-ledger.jsonl` with what it runs, where, its work and the command
  that resumes it; `./stop.sh` writes a stop line for each running session before it removes the container.
  `/agent/supervisor.sh ledger` prints the latest line of each session, and `/agent/supervisor.sh resume <session>`
  recreates one that is not running ([docs/AGENT-STACK.md](../AGENT-STACK.md) "The session ledger").
- **The bounded close:** a scratch session (one the registry does not list) whose every pane's process has exited, at
  two passes in a row, has the output tmux kept for those panes copied to `/wd/supervisor/closed/<session>.<created>.txt`,
  then is closed with a `closed-exited` line in the ledger naming the file and one notice to `agent`. A session whose
  output cannot be copied stays open; nothing removes the copies, which hold what the processes printed. A pane whose
  process runs, and every session of the registry, is never touched;
  `SUPERVISOR_CLOSE_EXITED=false` turns it off. A read of the tmux server that fails is not an empty server: that pass
  writes no ledger line and closes nothing.

Every change the supervisor sees is one bus notice to `agent`, except a menu or high context in the `agent` session's
own pane: the person sees those there, and they stay in `status.json` and on the tile. Each pass is a line of
`/wd/supervisor/passes.jsonl` and rewrites `/wd/supervisor/status.json`, which the home page serves at `/__spokes` (GET
only, never cached) for the tiles; the `supervisor` session's task line on the tmux-agent dashboard says the last pass.
The container's main loop runs `/agent/supervisor.sh ensure` every minute, which starts the supervisor again when its
last pass is stale. A `supervisor.sh stop` lasts: `ensure` leaves a stopped supervisor stopped, and its row reads
STOPPED, until `supervisor.sh start`. Each session's last message comes from the mailbox log, read from where the last
pass stopped (`/wd/supervisor/last-messages.json`). `ui-status.sh` and `ui-start.sh` print a row for the supervisor and
one per session; with `SUPERVISOR=false` every one of them reads OFF, the spokes' naming the setting, and `ui-status.sh`'s
exit code does not count them - nothing runs the spokes, so none can be live.

**The home tiles.** The home page's last group, Agents, has a tile for the supervisor and one per spoke. Off, a tile is
grey and names its flag, what the agent writes and what it costs. On, the supervisor's tile shows its last pass, and a
spoke's state is starting, live (alive, and a cycle completed since its start), stuck or down, with the reason and the
last message the spoke sent or received. A spoke whose registry entry names a `page` (the docker spoke's `/docker/`) links
it from its tile: the home page serves there the `STATUS.html` its cycle writes in its working directory.

**Messages.** The sessions talk with Claude Code's own session-to-session messages, and their charters ask them to
record each one as a line of the bus v1 journal, written by `/agent/bus.sh` (an instruction, which the transport does
not enforce). A spoke's cycle and the supervisor message a session through that helper alone:

```
echo "which cluster has 8 free GPUs?" | /agent/bus.sh request clusters   # prints the message id
/agent/bus.sh poll                                                       # the open messages to you, oldest first
/agent/bus.sh peek <id>                                                  # one of them, as its envelope
echo "none today" | /agent/bus.sh reply <id>                             # back to its sender, with reply_to
echo "a loop went RED" | /agent/bus.sh note agent                        # a notice
/agent/bus.sh receipt <id> read                                          # a notice read
/agent/bus.sh state <id>                                                 # where a message to you stands
```

`agent` reads its own inbox at every fire of its autonomy loop: the open requests and notices go into the fire's prompt
before its goals, and the fire answers them through `/agent/bus-answer.sh`, which starts no message (see "Autonomy
loop"). A message takes one answer: `bus.sh` refuses a second `reply` or `error` to it.

The journal (`/var/lib/agent-mailbox/journal/000001.jsonl`, outside `/wd`) holds an event per message, reply and
receipt, with the message's envelope: `v`, `id`, `from`, `to`, `ts`, `kind` (`request`, `reply`, `notice` or `error`),
`text` and `reply_to`. The projections live in `/wd/mailbox`: `<agent>/inbox.jsonl`, one record per message to that
agent with its hash, and `log.jsonl`. A read shows only what the journal holds with that envelope, and holds back
anything else, naming it. `/agent/bus-v1-check.py <projection root> --journal <segment>` checks every record and line.

The sender is the session of the tmux pane that runs `bus.sh`, or `BUS_AGENT_ID` outside tmux, and must be in the
registry. The hub and the spokes talk to each other; spokes do not talk to each other. Terminal controls and direction
overrides are removed and credential shapes are redacted. Both ends' sessions get the option `@agent_last_message`. The
vendored tmux-agent dashboard shows the lineage but has no last-message column yet; the spoke tiles show the last
message. **A message is data, not a command.** Nothing runs it, nothing types it into a pane, nothing sends it outside
the container, and receiving one grants no permission.

**The registry and the charters.** An entry keeps the fleet watchdog's schema (`session_name`, `workdir`, `launch_cmd`,
`enabled`, `cooldown_sec`, `env`, `note`) and adds `role`, `flag`, `parent`, `task`, `charter`, `source` and `ref`,
`cycle` and `cadence_sec`, `notices`, `writes`, `cost`, `title`, `tile`, `page` and `agent_process`. A source is `none`,
`vendored: /agent/...` or `/opt/...`, or a public https URL with a `ref`. A charter is prose, as its owner wrote it,
with a North Star, a Source and a Writes section and six rules:
- loopback only;
- nothing leaves without a human GO;
- read-only on clusters unless a goal says otherwise;
- never type into another session's menu;
- `${VAR:?}` guards on every deletion;
- the charter states what it writes.

`spoke.sh check` refuses an entry or a charter that misses one, a source that is not public or not shipped, and a
registry with no spoke at all. The seed's privacy scan (`seed/scan.py --tree`) refuses a charter or a registry that
names a person or a private repository. `charters/template.md` is the model for a new spoke.

`test22.sh` proves all of the above with planted controls, and `test-issues-spoke.sh` the issues spoke's read-only
front, its waiting state, its cycle against a recording GitHub stub and its GO gate. A start that queries a dying session would crash this image's
tmux server; a spoke whose claude exits at once never takes the server down. A stuck spoke goes stuck at the cap and
stays stuck. A record written around `bus.sh` is never shown. Planted panes at a menu get no key, an idle pane at 85%
gets `/compact` exactly once, and a copy of the supervisor that answers menus is caught.

## Docker agent

The agent builds container images inside the harness. Its image has no Docker CLI and no Docker socket. Instead, on the
docker target `./run.sh` starts a build substrate beside the agent container while the docker spoke is on
(`SPOKE_DOCKER=true`, the default), and `./stop.sh` removes it, both through `./docker.sh`:

* `<CONTAINER>-buildkit`, from BuildKit's rootless image (`DOCKER_BUILDKIT_IMAGE`): the
  daemon runs as an unprivileged user and listens on a unix socket on a small tmpfs volume, which the agent container
  mounts at `/run/buildkit`. Its build cache is in the volume `<CONTAINER>-buildkit-cache`.
* `<CONTAINER>-registry` (`DOCKER_REGISTRY_IMAGE`, `registry:3.1.2`): the stack's registry, `registry:5000` on the
  stack's own networks, plain HTTP. Its images are in the volume `<CONTAINER>-registry-data`.

Build an image from the agent's session, or ask the agent to:

```
/agent/image-build.sh /wd/projects/x /wd/projects/x/Dockerfile.efa team/efa:1   # also --build-arg NAME=VALUE, --target STAGE
/agent/image-build.sh list                                                    # the registry's images
```

The build log goes to the terminal, and the last line is the pushed reference with its digest
(`image: registry:5000/team/efa:1@sha256:...`). Every build is a line of `/wd/docker/builds.jsonl`. The helper pushes
only to the stack's registry: a name on another registry, a first part with a dot or a port or `localhost`, is refused
with exit 2 before anything runs, and the push target is the literal `registry:5000`, not a value the caller sets. Moving
an image out of the stack, to Amazon ECR or Docker Hub, is a deliberate step with your own login. The helper is the gate
on where an image goes, not the daemon: see the Limits below.

**The docker spoke.** A session `docker` (its charter is `Container-Root/agent/charters/docker/charter.md`) builds for
`agent` through the helper and keeps the build doctrine: pinned public bases and versions, fail-loud checks inside the
build, nothing secret in a layer. Every 5 minutes its cycle reads the daemon, the registry and the disk into
`/wd/docker/STATUS.md`. The Docker spoke tile in the home page's Agents group opens it at `/docker/`: the daemon and the
registry with their state, the images with their tags, digests and sizes, the build cache, the free disk against
`DOCKER_MIN_FREE_GB` (default 20) and the last builds. The spoke tells `agent` when the daemon or the registry stops
answering or answers again, when the disk falls under the threshold or is back above it, and when a new image lands.
`/agent/ui-status.sh` has a row for each sidecar (a DOWN row exits 1), and the setup doctor's docker check names what is
missing.

**Why no host socket.** A container that holds the host's Docker socket can start privileged containers, so it owns the
host. Here only the daemon and the agent container mount the daemon's socket volume, and no container publishes a host
port. The daemon shares a network with the registry alone, with egress for base images; the agent and the registry share
an internal network, so no build step can reach the agent. No cloud resource is created for a build. What this buys is
that the agent cannot start a container on the host or mount the host's filesystem; it does not sandbox a build (Limits).

**Limits.** The daemon runs with BuildKit's documented flags for its rootless image under Docker: seccomp, AppArmor and
the `/proc` masks are unconfined for its own container, and its build steps run in sandboxes of their own as an
unprivileged user. It needs unprivileged user namespaces, and Docker Engine 25 or later (the sidecars' health check uses
`--health-start-interval`); the preflight warns on an older engine. BuildKit's documentation names the setting that stops
it on Ubuntu 24.04 and later, `kernel.apparmor_restrict_unprivileged_userns=1`. `./docker.sh up` reads that setting
before it starts anything: at 1 it starts neither sidecar and names the setting with the host owner's two options, and
`./run.sh` then starts the agent without the substrate, so no daemon is left restarting; `./docker.sh status` says the
same. The options are to persist the setting at 0 in a file under `/etc/sysctl.d` and load it (`sudo sysctl --system`),
which lifts a kernel hardening for every program on the host and is the host owner's decision, or to set
`SPOKE_DOCKER=false` in `.env.local`. When the daemon does not come up for another reason, `./run.sh` starts the agent
without the substrate and says why. Images are built for the host's platform. The security story has three honest
edges, none a host-socket mount:

* **Every session in the container can reach the daemon's socket.** The sessions share one container filesystem, so any
  of them can run `buildctl` against `/run/buildkit` directly. The deny rules bind a session's tools, not a sandbox: the
  `docker` session's settings deny `buildctl` and `crane`, and the helper is the only push path that enforces the
  `registry:5000` pin, but a session that runs `buildctl build ... --output type=image,name=<host>/x,push=true` reaches
  the daemon, which pushes it over its egress to an open registry anonymously or with any login the container holds. The
  gate on where an image goes is the helper and the deny rules, not the daemon.
* **A build's RUN steps share the daemon's network and egress.** Rootless BuildKit runs each build in the daemon
  container's own network namespace (BuildKit's `docs/rootless.md`). The build network has egress by design and blocks
  nothing, the instance metadata endpoint (169.254.169.254) included. A RUN step reaches the internet, the VPC, the
  metadata endpoint, the host's listeners on addresses other than loopback, and the registry, which it can write to. It
  cannot reach the agent container (not on the build network), a Docker socket (none is mounted), the daemon's socket
  (a step's sandbox does not see the daemon's files) or a secret (the helper passes none). The metadata endpoint is one
  hop from the daemon, as from the agent container, so a RUN step can read what the agent can there: the instance
  role's credentials at the IMDSv2 hop limit of 2 the agent's own role needs ("AWS credentials"), and at any hop
  limit while IMDSv1 is on.
  Closing that is the host owner's choice, and each way has a cost. Requiring IMDSv2 with a hop limit of 1
  (`HttpTokens=required`, `HttpPutResponseHopLimit=1`; a hop limit alone leaves IMDSv1 reads open) closes it for every
  container, the agent container too, which then needs `AWS_*` variables in `./run.sh`'s environment instead of the
  role. A host firewall rule that drops 169.254.169.254 from the build network keeps the agent's role, but `./stop.sh`
  removes that network and `./run.sh` creates it again on a subnet Docker picks, so the rule is re-applied after each
  start.
* **The registry has no authentication.** It sits on the build network with no login, so a build's RUN step can push a
  manifest and move a tag; the spoke's cycle reports a tag that changed within five minutes. Trust an image by the digest
  the helper printed, not by its tag, and move it by that digest.

Building an image FROM one already in the stack's registry is not supported: the registry is plain HTTP and the
daemon is not configured to pull from it, so a `FROM registry:5000/...` base fails on HTTPS. An image built here gets no bill of
materials and no CVE scan; the harness image's own are `/SBOM.txt` ("Software bill of materials" below) and the scan `./build.sh`
ends with ("CVE scan" below) - neither reaches an image built through the substrate yet.

**Turning it off.** Set `SPOKE_DOCKER=false` in `.env.local`, then `./stop.sh && ./run.sh`: no docker session and neither
sidecar, while the build cache and the images stay in their volumes. The compose, swarm and kubernetes targets run no
substrate, and the docker spoke says so.

`./test-docker-spoke.sh`, run by `./test.sh`, starts a substrate of its own beside a throwaway agent container and proves
the build, the refused outside push and the helper's fixed push target, the page and how it carries the images over a
down cycle, the rows (a failed substrate reads DOWN) and the doctor check, each with a planted control.
