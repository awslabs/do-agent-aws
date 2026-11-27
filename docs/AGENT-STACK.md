# The agent stack

After `./build.sh && ./run.sh` the container starts **`agent`**, the hub you talk to, and **`supervisor`**, a script that
never calls a model. The supervisor starts every spoke switched on in `.env` and keeps the sessions alive and unstuck.
Each spoke is a resident Claude Code session that keeps one home-page tile's data current and answers `agent` about it.
Project work runs as workers that `agent` starts per goal; they are not resident.

The registry, `Container-Root/agent/spokes/registry.json` (`/agent/spokes/registry.json` in the image), lists every
session and is the only source of what runs. Each spoke's charter, the CLAUDE.md of its session, is
`Container-Root/agent/charters/<name>/charter.md`. Every agent is named for the tile it keeps current, the way
[naming.md](naming.md) names tiles for what the user gets. The home page's North Star section lists the same agents with
the same one-line North Stars ([north-star.json](north-star.json)). How the sessions talk is in
[INTER-AGENT-MESSAGING.md](INTER-AGENT-MESSAGING.md); the "Spoke agents" section of docs/manual/agents.md is the reference for each script.

## 1. The agents: what each one is

| Session | Role | North Star | The tile it keeps current | Writes only | `.env` flag (shipped default) |
|---|---|---|---|---|---|
| `agent` | Hub: plans, delegates to the spokes, starts workers, answers the person with sources; also runs the autonomy loop | A new user clones the repository, runs ./build.sh and ./run.sh, and gets a running multi-agent harness that does real work and shows it, with nothing undocumented and nothing leaking | tmux terminal, Agent chat, and Agent loop once its page ships | `/wd` work trees, the goals file, the boards through `board.sh`, `/wd/loop`, the cluster lock through `/agent/cluster-lock.sh` | `AGENT_TMUX_SESSION=true` |
| `supervisor` | Keeps every enabled agent alive and unstuck; no model calls | Every enabled agent is running and unstuck, and every repair it makes is one a person would make without thinking: it never answers a menu and never sends, spends or deletes | its tile in the home page's Agents group; its last pass on the tmux-agent dashboard | `/wd/supervisor/`: `passes.jsonl`, `status.json`, `last-messages.json`, `supervisor.log`, `sessions-ledger.jsonl`, `census.err`, the kept output of closed sessions under `closed/`, each session's `state.json` and `restarts.log`, each cycle's `cycle.out` and `last-cycle` | `SUPERVISOR=true` |
| `conversations` | Polls, classifies and journals the configured channels; stages replies, never sends | Lets the agents take part in human communication channels without ever silently losing an incoming message or silently sending an outgoing one | Conversations | `/wd/conversations/state/` (the comms store and its outbox, STAGED rows only), `last-cycle`, `cycle.log`, `settings.json` | `SPOKE_CONVERSATIONS=true`: Slack read calls every cycle; needs `SLACK_BOT_TOKEN` and `SLACK_CHANNELS` |
| `insights` | Mines new session transcripts into rule candidates through the gates; best-effort memory per candidate | Turns the agents' work exhaust into screened, recallable rules that measurably improve the next session | Session insights, and Learned rules once that tile ships | the candidates file (`/wd/loglearner/banks/candidates/mined.jsonl`), a memory per candidate in the `loglearner-rules` bank, its cycle record, the dashboard's index | `SPOKE_INSIGHTS=true`: no model calls in its hourly cycle |
| `clusters` | Read-only status of every configured Kubernetes context; brokers the harness's cluster lock (GPU leases) | Shares GPU clusters with other people without ever acting on a stale picture or presenting one as fresh; never mutates a cluster | Headlamp | `/wd/clusters/`: `STATUS.md`, `HEADLAMP-NOTE.md`, `status.json`, `prev.json`, `cache/`, `refusals.log`, `notices.jsonl`, `broker.lock`, and the cluster lock's `locks/` through `/agent/cluster-lock.sh` | `SPOKE_CLUSTERS=true`: needs a kubeconfig |
| `sessions` | Keeps the books of the container's tmux sessions from the tmux-agent dashboard's census | Reports no state it did not read from the census; never spawns, sends to or kills a session | tmux-agent dashboard | `/wd/sessions/` (its book, `alerts.jsonl`, `last-cycle`) | `SPOKE_SESSIONS=true`: its charter is complete, its cycle script is not written yet |
| `loops` | Keeps the Loop Deck's topology and loop health true every cycle | Never shows a loop as healthy without evidence of a completed run, and fails closed when it cannot validate | Loop Deck | `/wd/loops/` (its state) and, through the adapter, the Deck's four input files under `/wd/loop-deck` | `SPOKE_LOOPS=true` |
| `issues` | Triages the open issues and pull requests in scope: conflicts, failing checks, requested changes, what needs a reply; stages reply drafts, never posts | Outward drafts are evidence-driven, scrubbed and human-confirmed; nothing is ever posted automatically | Board (its rows are in `status.json` until the Board reads a spoke's rows) | `/wd/issues/`: `STATUS.md`, `status.json`, `state.json`, `notices.jsonl`, `outbox/` (drafts and their records; the `.GO` files are the person's), `cycle.log`, `refusals.log`, and in the private directory the shim, `gate.log` and the gate's copies | `SPOKE_ISSUES=true`: read-only GitHub calls every 15 minutes; needs `GH_TOKEN` |
| `docker` | Builds container images inside the harness through the stack's BuildKit daemon into its registry; keeps the build doctrine and the substrate's health in view | Builds container images inside the harness from a Dockerfile into the stack's own registry, without a host Docker socket or cloud resources made for the occasion, and never pushes outside the stack without a person's say | its own tile in the Agents group, which opens its page at `/docker/` | `/wd/docker/`: `STATUS.md`, `STATUS.html`, `status.json`, `prev.json`, `builds.jsonl` (the build helper's), its pane's `.claude/settings.json` and `.docker-config/`; the images it builds, in the stack's registry | `SPOKE_DOCKER=true`: local reads every 5 minutes; with it, `./run.sh` starts the BuildKit daemon and the registry on the docker target |
| `example` | A timestamp every cycle and an answer to every question | Proves the scaffold end to end without spending a model token on a loop | its own tile | `/wd/example/status.txt` | `SPOKE_EXAMPLE=false` |

Seven spokes ship on and the example off, so a fresh clone starts seven resident Claude Code sessions beside `agent`;
`tmux ls` shows `agent`, `clusters`, `conversations`, `docker`, `insights`, `issues`, `loops`, `sessions` and
`supervisor`. A
spoke's session spends model tokens only when someone talks to it; its loop is a script the supervisor runs at the
registry's `cadence_sec`. The conversations loop also reads Slack every cycle once its settings are set (until then it
waits for Slack), and the issues loop reads GitHub every 15 minutes once `GH_TOKEN` is set (until then it waits for
GitHub). `SPOKE_<NAME>=false` in `.env.local` turns one off; the home page's Agents group lists the spokes that run.

## 2. The agents: how each one talks, is supervised, is seen and is tested

| Session | Talks to, and about what | Supervisor rules beyond the common set (section 4) | See it | Checks |
|---|---|---|---|---|
| `agent` | the person (Agent chat, the terminal); each spoke: questions and tasks as a `request`; every fire of its autonomy loop reads its open requests and notices first and answers each request with a `reply`, a receipt on each one | its pane is the person's, never typed into: a menu or high context there stays in `status.json` and its tile, an error or a shell is reported; a window a person opens in the session is not the agent's pane; a gone session is started again | `tmux ls`; the root of the dashboard's tree, under `operator`; each fire's inbox record on the Agent loop page | test22 checks 8 and 9; test3 `[fire-reads-inbox]` (a loop fire reads the inbox first) |
| `supervisor` | `agent`: one `notice` per change (died, restarted, stuck, repaired, cap reached, health, a scratch session closed); the person: its tile | it is watched by the container's keepalive, which runs `supervisor.sh ensure` every minute and starts it again when its last pass is stale; a `supervisor.sh stop` lasts until `supervisor.sh start` | `tmux ls`: its session shows the last pass; its task line on the dashboard | test22 checks 5, 6 and 8; test-fleet-manager.sh checks 1 to 7 |
| `conversations` | `agent` only: a `notice` per new open ask, once; a `reply` to "stage a reply" with the STAGED row key, never "sent" | its charter never answers a send prompt; it waits for Slack (`SLACK_BOT_TOKEN`, `SLACK_CHANNELS`) while either is unset | `tmux ls`; a child of `agent` on the dashboard | its loop's `--stub-test`: a planted ask is journaled, a reply staged, zero posts (test22 check 10b runs it where the engine has the stub Slack API override) |
| `insights` | `agent` only: a `notice` per cycle that banked candidates; "promote" gets the exact command back, not a run | none | `tmux ls`; a child of `agent` | its loop's `--self-test`: a planted correction banks one candidate, a duplicate none (test22 check 10b) |
| `clusters` | `agent` only: answers cluster questions from its latest status and `gpu-lease` and `gpu-release` requests with leases of the cluster lock; a `notice` only when placement changes, a lock's holder among it | its loop's wrapper refuses every cluster write verb | `tmux ls`; a child of `agent` | its loop's `--self-test`: the write verbs refused, `auth` passed only as `can-i` and `whoami`; test22 check 10b runs it and one cycle with a context named like an EKS cluster ARN; `test-cluster-lock.sh` checks 1 to 13: the lock's verbs, a planted race, the broker's leases from a view, expiry, one cycle's lease table and notice, the rule |
| `sessions` | `agent` only: a `notice` per transition (dead, blocked, stalled, without lineage, gone); refuses spawn, send and kill with an `error` | needs the dashboard tile on; never runs a second collector | `tmux ls`; a child of `agent` | its charter's acceptance, once its cycle is written |
| `loops` | `agent` only: a `notice` when a loop goes RED or recovers, or the Deck stalls | never pauses or resumes a loop | `tmux ls`; a child of `agent` | the Deck's inputs validate at the pinned contract after a cycle |
| `issues` | `agent` only: a `notice` per change (a pull request starts or stops conflicting or failing, an item starts or stops needing a reply, a person posted a draft); its cycle answers which pull requests conflict, what needs a reply and what is staged; "draft a reply" gets the draft's name and sha256, never "posted" | it waits for GitHub (`GH_TOKEN`) while the token is unset; nothing posts except through `post.sh` after a person's GO (section 7) | `tmux ls`; a child of `agent` | `test-issues-spoke.sh` checks 1 to 7: the front refuses every write form, the waiting state, one cycle's rows with reads only, the hub's question answered, the GO gate |
| `docker` | `agent` only: a `notice` per change (the daemon or the registry stops answering or answers again, the disk falls under `DOCKER_MIN_FREE_GB` or is back above it, a new image or tag); "build X" gets the reference and digest the helper printed, never a push outside the stack | its pane holds no registry login, and its session's settings deny `buildctl` and `crane` called directly (section 8) | `tmux ls`; a child of `agent`; its page at `/docker/` | `./test-docker-spoke.sh` checks 1 to 10: the substrate up and isolated, a build through the helper into the registry, the refused outside push, the cycle's inventory and notice, the tile and the page, the rows and the doctor check with a sidecar stopped, the helper's push target that a caller's `BUILD_REGISTRY` cannot move, a failed substrate's rows, and a cycle after a failed registry read that announces no image as new; test22 check 7b (the plain start's set includes docker) |
| `example` | `agent`: every request gets the time of the last cycle back, from the cycle itself | none | `tmux ls`; its tile | test22 checks 3, 5 and 6 |

## 3. How they talk

- **Transport:** Claude Code's session-to-session messages (ListAgents, SendMessage) between the tmux sessions in the
  container. They were measured working in the harness image before anything was built on them
  ([INTER-AGENT-MESSAGING.md](INTER-AGENT-MESSAGING.md), "The measured basis").
- **Addressing:** a sender finds a session when it sends. Each ListAgents row names its tmux pane, so the hub is the row
  whose pane is in the session `agent`. The names change on every restart, so none is cached.
- **The record:** each message is meant to be one line of the bus v1 journal, written by `/agent/bus.sh` (`request`,
  `note`, `reply`, `error`). A session's charter asks it to journal what it sends, which the transport does not enforce;
  a spoke's cycle and the supervisor message through `bus.sh` alone, because they are scripts, not sessions.
- **The hub's intake:** every fire of the hub's autonomy loop reads `agent`'s open requests and notices before its
  goals, answers each request through `bus-answer.sh reply`, which can only answer, and marks each message with a
  receipt. After a fire that ended well the loop denies a request the fire left unanswered and marks a notice read;
  after one that did not, the message stays open, until three such fires set it aside
  ([INTER-AGENT-MESSAGING.md](INTER-AGENT-MESSAGING.md), "A loop fire reads its inbox first"). A spoke's request to
  `agent` gets one answer, from the loop's next fire while the loop runs or from the person in `agent`'s pane;
  `export LOOP_INBOX=false` in `.env.local` turns the intake off.
- **Pairs are default-deny:** `agent` and each spoke talk to each other; the supervisor sends notices to `agent`; the
  spokes do not talk to each other.
- **A message is never permission:** each spoke's charter and tool permissions decide what it does, and nothing a
  message asks reaches outside the container.

## 4. What the supervisor does on every pass

Every `SUPERVISOR_INTERVAL` seconds (default 15, a whole number of at least 1), for `agent` and every enabled spoke of
the registry:

1. **Alive?** The tmux session, and its agent process (`claude`) in the agent's pane, the one the session's start
   recorded as `@agent_pane` (a window a person opens in the session is not it): a session whose pane runs only a shell
   is not alive. A spoke without its session is started again with its entry's launch command, the first restart at once
   and each further one after twice the wait of the one before, from the entry's `cooldown_sec`; after
   `SUPERVISOR_RESTART_CAP` restarts without staying up `SUPERVISOR_HEALTHY_SECS` it is stuck and left alone. A gone
   `agent` session is started again; an `agent` pane that runs a shell is reported, never replaced.
2. **Stuck?** `/agent/fleet-check.sh` reads the pane: a menu open, "API Error", "Prompt is too long", a failed
   compaction, or a status line at 80% context or more. Each is reported; the reading errs toward "working".
3. **Safe repairs.** `/compact`, once per high-context spell, into a spoke's pane that is idle at an empty prompt line
   at 80% or more, read again just before the keys go in (a send its read-back refuses is tried again at the next pass);
   never into the `agent` pane, never at a menu, never while a turn runs. No menu is ever answered, and no prompt that
   would send, spend or delete.
4. **Health.** The memory API's `/health`, and the session-memory worker's queue depth against
   `SUPERVISOR_MEMORY_QUEUE_WARN`. The Loop Deck's server too, the one UI the supervisor starts again: when the pid
   `ui-start.sh` recorded in `/wd/ui/loop-deck.pid` is no longer the Deck's server, `/agent/loop-deck-start.sh` runs
   again with a spoke's restart schedule (at once, then `SUPERVISOR_DECK_COOLDOWN` seconds doubling, stuck at
   `SUPERVISOR_RESTART_CAP`); a Deck stopped with `ui-stop.sh` stays stopped.
5. **Cycles.** A spoke's cycle command every `cadence_sec` seconds in its working directory; what the cycle leaves for
   the hub (the entry's `notices`) becomes bus notices from the spoke. A spoke whose entry `requires` settings that
   are unset waits instead: its session runs, no cycle runs, nothing restarts or notifies, and its row and tile read
   "waiting for <what>" with what to set.
6. **Report.** One bus notice to `agent` per change (a menu or high context in the `agent` session's own pane stays in
   `status.json`), one line of `/wd/supervisor/passes.jsonl` per pass, the home tiles (from `status.json`) and the
   dashboard's task line of the `supervisor` session.
7. **The session ledger**, first in each pass: every session on the tmux server, the registry's and the scratch ones a
   person or `agent` starts (not the views the harness's own scripts start and end), against its latest line in
   `/wd/supervisor/sessions-ledger.jsonl`. A session that came gets a start line and one that went a stop line; every
   start and restart of step 1 writes its own start line. A read of the tmux server that fails is not an empty server:
   that pass writes no line and closes nothing, and the supervisor says so once. See "The session ledger" below.
8. **The bounded close**, after the restarts in each pass. It applies to a scratch session (one the registry does not
   list) whose every pane's process has exited at two passes in a row, and still when read again; tmux keeps such a
   pane, and what its process printed, only because the session's `remain-on-exit` option asks it to. The supervisor copies that
   output (each pane's history and screen, under a header naming the pane, its exit status, the lines its history held
   with its history-limit, and its command) to `/wd/supervisor/closed/<session>.<created>.txt`, then closes the session
   with a `closed-exited` line naming the file and one notice to `agent`. A session whose output cannot be copied stays
   open, and the supervisor says why once; a pass whose read again of the panes fails closes nothing. A pane whose
   process runs is never touched, nor is a session of the registry: the copy refuses a pane whose process started again
   after the census read it, and that session stays. `SUPERVISOR_CLOSE_EXITED=false` turns the close off.

Two limits of this version, stated so nobody relies on them:
- The 80% rule reads the `ctx:NN%` that the agent's status line prints (`/agent/claude-statusline.sh`, which
  `/agent/claude-settings-sync.sh` sets when no status line is configured), the form the tmux-agent dashboard reads
  too, and the oh-my-claudecode HUD's `ctx:[bar]NN%`. A status line of your own that prints neither leaves the rule
  nothing to read, and Claude Code's own automatic compaction is what applies.
- `/clear` is not in this version: no rule for a backlog on which `/clear` would be safe is defined.

### The session ledger

`/wd/supervisor/sessions-ledger.jsonl` (`/agent/session-ledger.py`) has one JSON line for each `start`, `stop`, `resume`
and `closed-exited` of a tmux session, so a session that stopped can be brought back. Lines are only appended: every
writer opens the file to append and adds whole lines under one lock; nothing rewrites it. A line carries:

| Field | What it holds |
|---|---|
| `ts`, `event`, `reason` | when, which of the four, and why: the supervisor's start, "appeared", "its session ended", the stack's stop |
| `session`, `agent` | the tmux session's name, and its registry name or `scratch` |
| `pane_pid`, `created` | the agent pane's process id and the session's creation time: together they tell one session of a name from the next |
| `cwd`, `command` | the pane's directory and the command tmux started in it |
| `git_head` | the commit of the git repository that holds `cwd`, when one does |
| `work` | the supervisor's state and reason for a registry session, or the last line of a `STATUS` file in `cwd` |
| `claude_session` | the Claude Code session id of the claude in the pane, when one ran there as the line was read |
| `resume` | the command that recreates the session |
| `output`, `output_tail` | on a `closed-exited` line, the file that keeps what the session's panes showed, and its last 40 lines (at most 4000 characters); null on every other line |

The writers: the supervisor's census, first in each pass (step 7), which also records the hub, found running;
`/agent/tmux-session-start.sh` at every start of a spoke or of the supervisor's own session, with the pane's pid from the
call that created it; the supervisor, when it starts a gone hub again; the bounded close (step 8);
`/agent/supervisor.sh resume`; and `./stop.sh`, which runs `/agent/supervisor.sh record-stop` in the container before
it removes it: a stop line for each running session, read from its pane while it runs, with its Claude Code session.
Only the default docker target runs `record-stop`; with compose, swarm or kubernetes the next start's census writes the
stops nobody saw, without a Claude Code session.

In the container (`./exec.sh`):

```
/agent/supervisor.sh ledger              # the latest line of each session
/agent/supervisor.sh ledger <session>    # the latest line of one session; exit 1 when it has none
/agent/supervisor.sh resume <session>    # recreate a session that is not running from its latest line
```

`resume` refuses a session that runs, and writes a `resume` line for the one it recreates. A registry session comes back
through its registry start (`/agent/tmux-session-start.sh <name>`, the hub's with no name), its claude options kept and
`--resume <id>` added when its Claude Code session is known; a spoke whose flag is off is refused, since the registry
decides what runs. A scratch session comes back in its recorded directory with its recorded command, or with
`claude --resume <id>` when its Claude Code session is known. The Claude Code session is read from the running pane, so
a scratch session whose claude started after its start line, and that ended on its own, comes back with its recorded
command. A resume runs the command its line records: whoever can write `/wd/supervisor/` chooses it, the same boundary as
`/wd`. The loop page's Fleet section does not show the ledger: `supervisor.sh ledger` is how to read it.

The ledger is never rotated. Most lines are a few hundred bytes; a `closed-exited` line also carries the last 40 lines
of the panes' output, at most 4000 characters. The census writes a line only when a session comes or goes, and every
census and `ledger` reads the whole file. To start afresh, stop the supervisor and move the file aside; the next census
records the sessions that run as found running.

The kept copies are never removed either: `/wd/supervisor/closed/` gains a file at each close, each holding at most
each pane's history-limit of lines (2000 unless set) and its screen. The supervisor removes nothing it kept, so removing
old copies is a person's choice. A copy, and the end of it in its `closed-exited` line, holds what the processes
printed, a secret too if one printed it: `/wd/supervisor/` is as private as the rest of `/wd`. A copy's header gives `-`
for an exit status tmux does not give (tmux 3.2a gives none for a process a signal ended, nor at times for one that
exited while tmux was busy), and the lines the pane's history held with its history-limit. tmux keeps no more than that
limit and drops the earliest lines a tenth of it at a time, so a history within a tenth of its limit is marked as one
whose earliest lines may be gone.

## 5. Candidates judged on evidence, and not built as agents

| Candidate | Verdict | Why |
|---|---|---|
| docker (builds, the build cache, disk) | built as the `docker` spoke (section 8) | Its builds run through a rootless BuildKit daemon in a sidecar container, over a socket of its own: the host's Docker socket, which would give the agents root on the host, is never mounted. The network pools stay a host-side preflight of `./run.sh`, and Docker Sandboxes stay `to/sandbox`. |
| memory (extraction health, the capture queue) | folded into the supervisor | Reading a health endpoint and a queue depth needs no model: section 4, step 4. |
| board (the goals and project boards, stale cards) | scripts in the hub's loop | `loop.sh` already runs `kanban-sync.py` and `plane-sync.py` around every fire. |

The github candidate (pull requests, merges, conflicts) of this table's first version is now the `issues` spoke
(section 7), at the owner's request: it triages the person's issues and pull requests and stages replies behind a GO
gate, and it keeps the Board tile in the registry while no pull-request tile ships.

## 6. Why these names

- **`agent`, not "lead":** `AGENT_TMUX_SESSION_NAME=agent` is the default, `test12.sh` checks it, and bus v1 names
  `agent` as the hub; its tiles are Agent chat and Agent loop.
- **`clusters`, plural:** it reads every configured context, not one.
- **`sessions`, not "fleet":** the tile shows the container's tmux sessions; a harness user has a handful.
- **`docker`:** it builds images and keeps the build substrate in view; it never reaches the host's Docker (section 8).

## 7. The issues spoke and its GO gate

**What it does.** Every 15 minutes (`cadence_sec` 900) the supervisor runs `/agent/charters/issues/loop.sh` in
`/wd/issues/`. One cycle reads the open issues and pull requests in scope - the repositories in `/wd/issues/settings.json`
(from `settings.example.json` beside the charter) and `ISSUES_REPOS`, and by default the login's own open items - and
writes `STATUS.md` and `status.json`: the pull requests that conflict, those whose checks fail, those with changes
requested, and the items whose last human word is not the login's (bots never count). Each change of those sets since
the last complete scan becomes a notice to `agent`, and the cycle answers `agent`'s requests it has the data for
(which pull requests conflict, what needs a reply, what is staged). A read that fails makes the scan PARTIAL: the last
complete scan stays in `status.json` and the cycle exits 1, never "nothing new".

**Its UIs.** The Board, the Goals board and the Project board (Plane) are this spoke's UIs. Their data still comes from
the hub's autonomy loop, which runs `kanban-sync.py` and `plane-sync.py` around every fire, and the Board reads the Plane
project and the agent runner; this spoke changes none of that. The Project board and the Board are there only with the
Plane board on (`UI_PLANE=true`; it is optional and off by default - docs/manual/boards.md "Plane board"). Its `status.json` carries
the triage rows for when those boards show them; moving the boards' data to this spoke comes later.

**Reads only.** Every gh call of the cycle goes through a front that refuses each write form before gh runs and logs it
in `/wd/issues/refusals.log`: `gh pr|issue` reads, `gh search`, `gh repo view`, `gh auth status`, and `gh api` with an
endpoint path, GET and output flags only (no `-X`, field, input or graphql). `loop.sh --self-test` proves it. With the
vendored issues tracker in the image (`/opt/issues-tracker`, refreshed by `tools/vendor-issues-tracker.sh`; its
`VENDORED.md` names the export), the front is its `scripts/gh-ro`, which also admits GraphQL queries and refuses a
mutation, reporting a refusal on stderr. With no repository named, the scan is its `scripts/gh-dashboard.py`, of the
login's own open items; repositories named in `settings.json` or `ISSUES_REPOS` are read by the spoke's own scan. An
export that does not pass the harness's tree scan is not vendored; without one, that directory holds only `VENDORED.md`
and the cycle uses its own scan and front.

**The GO gate.** The spoke's session drafts a reply as `/wd/issues/outbox/<owner>.<repository>-<n>.md` with a record
beside it (`<same>.FILING-READY.md`: the evidence, the duplicate search, the scan result, the exact send command, the
verify steps, a watch trigger). Nothing posts it but a person: they write `/wd/issues/outbox/<same>.GO` with their
words and the draft's sha256 (`sha256sum`), then run `/agent/charters/issues/post.sh <owner>.<repository>-<n>` in a
terminal and type the first 12 characters of the draft's sha256 when it asks (`--check` runs every gate and sends
nothing). `post.sh` refuses, logs the refusal in the private directory's `gate.log` and sends nothing when the GO is
missing or names another sha256, the draft was posted before, the record's send line is not its command, the privacy
scan (`seed/scan.py --tree`) finds anything in the draft, it runs without a terminal or the typed characters are not
the sha256 prefix, or it runs from the spoke's own session or cycle; with the vendored tree its
`redact-scan.sh --strict` and its hooks gate too, and its `block-gh-write.sh` keeps merge, close and review blocked
even with the operator token. Everything after the record check works on one private copy of the draft, made in the
private directory outside the session's working directory and re-hashed just before the send, so neither a draft nor
the copy changed after its hash is what goes out. Otherwise it sends the one comment, reads it back (its author is the
login, its body the draft byte for byte) and writes `<same>.POSTED`.

**Cost.** Read-only GitHub calls every 15 minutes with `GH_TOKEN` set: about one per open item and one more per pull
request, paced at one a second. Without the token it waits for GitHub: its session runs, its cycle does not. Model tokens
only when `agent` or the person talks to it.

**Off.** To turn one off, set SPOKE_<NAME>=false in .env.local, then ./stop.sh && ./run.sh - for this spoke,
`SPOKE_ISSUES=false`.

**The session's walls.** The session reads planted text, every issue and comment it triages, so more than its charter
keeps it from posting. Its pane (`charters/issues/pane.sh`, the registry's `launch_cmd`) starts claude without
`GH_TOKEN`, `GITHUB_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`, the operator token or a stored gh login, and without the
hub's permission bypass;
the cycle, which the supervisor runs outside the pane, keeps the token for its reads. Its own
`/wd/issues/.claude/settings.json`, written at every start, denies the GitHub plugin's tools, a bare `gh`, `curl` and
`wget`, `post.sh`, the GO files, `/proc`, the tmux server's environment, its own files, and - so no file tool can reach
them - the cycle's gh shim, the gate, the private directory, the vendored tracker and the agent tree, and registers
`charters/issues/session-hook.sh` for Bash, the file-writing tools (Write, Edit, MultiEdit, NotebookEdit) and the
plugin's tools: that hook refuses a file write to those paths, the operator token, `post.sh`, a GO file and a read of
the server's environment, then hands the rest to the vendored tracker's `block-gh-write.sh`. The session gets a draft's
send line from `charters/issues/send-line.sh`.

Every session's shared settings deny `post.sh` and the GO files as well: `charters/issues/shared-settings.sh`, which
startup.sh runs before the agent session, adds the rules beside the person's own.

**Limits, stated.** The front and the gate bind the spoke's scripts, and the walls bind its session's tools. They are
not a sandbox: every session runs as root in one container, so a session that reads another process's environment
around its deny rules could still reach the token, and one that built a pseudo-terminal around them, or a person
running `post.sh` under a wrapper such as `script`, could pass the terminal check; the charter forbids the first. The
hook's shell check names the shim, the gate, `gate.log` and the private directory by their common spellings (the path
fragments, the `SUPERVISOR_DIR` variable, doubled or repeated `/./` separators), so a plain copy into them is refused;
a spelling that carries none of those substrings - a glob, a `cd` then a bare relative name, a quoted or
command-substituted path - reaches the session's permission prompt, where a person's decision is the wall. And the
gate binds the drafting session, not the hub: `agent` holds the operator's token and could post with its own `gh` -
the gate's narrower purpose, that the session reading the issues is not the one answering them, still holds.

## 8. The docker spoke and its build substrate

**What it does.** The agent image has no Docker CLI and no Docker socket. On the docker target, `./run.sh` starts two
sidecar containers beside the agent while `SPOKE_DOCKER=true` (`./docker.sh`; `./stop.sh` removes them): a BuildKit
daemon from BuildKit's rootless image, which runs as an unprivileged user, and a registry. `/agent/image-build.sh <context
dir> <Dockerfile> <name:tag>` builds through the daemon and pushes to the registry, `registry:5000`, and prints the
reference with its digest; `agent` and the `docker` spoke both use it. Every 5 minutes the spoke's cycle reads the daemon,
the registry and the disk into `STATUS.md`, which its tile serves at `/docker/`, and tells `agent` what changed.

**Why no host socket.** A container that holds the host's Docker socket can start a privileged container and owns the
host. The daemon instead listens on a unix socket on a small tmpfs volume that only it and the agent container mount.
The daemon and the registry share a network with egress, for base images; the agent and the registry share an internal
one, so no build step can reach the agent. No container publishes a host port, and no cloud resource is made for a build.

**Pushes.** The helper refuses a name on any other registry before anything runs. A push outside the stack is a person's
step: the spoke names the image and its digest. Its pane holds no registry login, and its session's settings deny
`buildctl` and `crane` called directly, so the helper is the push path its session is given. Those rules bind the
session's tools, not the daemon, which pushes wherever a client tells it (Limits, below).

**Limits, stated.** The deny rules bind the session's tools; they are not a sandbox. Every session runs as root in one
container and can reach the daemon's socket, so the helper and the deny rules, not the daemon, are the gate on where an
image goes. A build's RUN steps share the daemon's network (rootless BuildKit's), which has egress by design and blocks
nothing: a RUN step reaches the internet, the VPC, the instance metadata endpoint, the host's listeners on addresses
other than loopback, and the registry with write access, and cannot reach the agent container, a Docker socket, the
daemon's socket or a secret. Closing the metadata endpoint is the host owner's choice: IMDSv2 required with a hop
limit of 1 closes it for the agent container too, which then needs `AWS_*` variables instead of the instance role,
and a firewall drop for the build network is re-applied after every start, since the network is created again on a
subnet Docker picks (docs/manual/agents.md, "Docker agent").
The registry has no authentication, so a RUN step can move a tag (the cycle reports it within five minutes); trust an
image by the digest the helper printed. The rootless daemon needs unprivileged user namespaces and Docker Engine 25 or
later; where the host restricts the namespaces or runs an older engine, it does not start and the doctor says so.
Building FROM an image already in the registry is not supported: it is plain HTTP and the daemon is not told to pull
from it insecurely.

## 9. The cluster lock and GPU leases

**The rule.** Every job that touches a cluster takes a lease of the harness's cluster lock first and releases it when
it ends, failed or not. The agent's operating rules and the `clusters` charter say so.
`/agent/cluster-lock.sh run <cluster> --holder <name> --ttl <minutes> -- <command>` does all three around one command,
renewing the lease while the command runs.

**The lock.** One JSON file per cluster in `/wd/clusters/locks/`: the lease (holder, session, reason, claimed_at,
expires_at, its GPUs and nodes), a first-come queue and the holders a stale reclaim displaced. Every change is made
under a file lock and lands by an atomic rename. Its verbs are claim, queue, extend, release, status, reclaim-stale and
run, with exit 0 done, 2 held by another and 3 invalid. A lease past its expiry is reclaimable: the holder is recorded
as displaced and the queue head gets the lock.

**The broker.** `agent` asks the `clusters` spoke for a lease with a bus request
(`{"kind": "gpu-lease", "cluster": ..., "gpus": N, "ttl_min": M, "reason": ...}`) and releases it with
`{"kind": "gpu-release", ...}`. The spoke's cycle answers it with `broker.py` from the view it has just read. The
lease is scoped to N GPUs on named usable nodes when that view shows them free and is at most 30 minutes old, else it
is the whole cluster's lock, and the reply says why. Expired leases are reclaimed every cycle, and a change of a lock's
holder is a notice for `agent`. The lease is advisory and per harness: it binds the harness's jobs to each other and
reserves nothing from other people's workloads. The state file, the shapes and an example are in
[cluster-lock.md](cluster-lock.md).

## See them, test them

- `tmux ls` in the container lists `agent`, `supervisor` and every running spoke; the browser terminal's session picker
  (`C-b s`) and the tmux-agent dashboard list them too, the spokes and the supervisor under `agent`, `agent` under
  `operator`.
- `/agent/supervisor.sh status` in the container prints a row per session with the reason; `/agent/ui-status.sh` prints the
  same rows after every UI's. With `SUPERVISOR=false` every row reads OFF and neither exit code counts them.
- The home page's last group, Agents, has the supervisor's tile and one per spoke.
- `./test-docker-spoke.sh` on the host checks the docker spoke's build substrate against a daemon and a registry of its
  own (section 8).
- `test22.sh` checks the registry and the charters, a session's start, the messages, the supervisor with planted panes,
  the tiles and the `.env` contract, each with a planted control that fails when its property is removed.
