# do-agent-aws harness: user guide

The harness runs a Claude Code agent (on Amazon Bedrock) with its tools and memory, and puts every UI behind one
home page: `http://127.0.0.1:8000` after `./run.sh`. From a laptop, reach it with `ssh -L 8000:localhost:8000 <host>`.
Every tile opens in a new tab with a **Harness home** button back.

**Finish the setup first:** in the **tmux terminal**, type `/setup` (or ask the agent to help you finish setting up). It
runs `/agent/doctor.sh`, which checks Bedrock, your git identity, a cluster, Slack, GitHub, memory and the dashboards,
and walks each gap with you, one question at a time: what the agent does itself, the lines you run on the host, and the
check that shows it worked.

## The 5-minute tour
1. **Give the agent a goal:** open the **Goals board** and look at the cards, or add a goal to `/wd/goals/GOALS.md`
   (see "Goals" below).
2. **Watch it work:** **tmux-agent dashboard** shows the agent's session live; **tmux terminal** lets you type into it.
3. **See the result:** the goal's card moves to **Done**, and its description gains a "Last fire" line with what the agent
   did and its exit code.
4. **See what it learned:** **Hindsight memory** holds facts the agent saved; **LogLearner** shows rules mined from its
   sessions.

## Goals and the Goals board (vibe-kanban)
The agent's autonomy loop works through **goals**, one card per goal, in the columns To do → In progress → In review → Done.

- **Source of truth:** `/wd/goals/GOALS.md`. The board is its mirror, written by `/agent/kanban-sync.py` at each loop
  fire, and the sync is two-way: a card's title, description and column edited on the board are written back into the
  file before the next sync, and a card created on the board becomes a goal. When both changed since the last sync, the
  file wins and the card gets a comment saying so.
- **Adding a goal:** `/agent/goals-add.sh "<one-line goal>"` in the terminal (the supported way; it is what the Slack
  responder calls). It appends one checkbox item under `## Goals from Slack` and prints the file's path. `--help`
  prints its usage; a goal that starts with `-` goes after `--`.
- **Goal format:** one checkbox item per goal is what the loop fires on and the board mirrors:
  ```
  - [ ] <the outcome you want> - DONE when <a file or a command result that only exists once the work is done>
  ```
  A longer goal is a section (the form of `docs/loop/GOALS.md.example`); its heading is the card's title and its body
  the description:
  ```
  ## Goal 1 - <short name>
  <the outcome you want>
  DONE when: <a file or a command result that only exists once the work is done>
  ```
  Plain text in any other shape is notes, not a goal: it makes no card and the loop does not fire on it.
- **The loop:** `loop-start.sh` starts it, `loop-status.sh` shows its state, and `loop-stop.sh` (or creating
  `/wd/loop/STOP`) stops it. It also stops on its own when every goal is checked off. It starts with the container when
  `AUTONOMY_LOOP=true` in `.env`; the default `auto` starts it only while Slack is configured (`SLACK_BOT_TOKEN` and
  `SLACK_CHANNELS`), so without Slack set `AUTONOMY_LOOP=true` or run `loop-start.sh` - until then a goal waits. The home
  page's **Start here** strip says which of the two applies to this deployment. A stopped loop restarts by itself: the
  goal watcher (`/agent/goal-watch.sh`, started with the container) checks the goals file every 2 minutes
  (`GOAL_WATCH_INTERVAL`) and runs `loop-start.sh` when a new unchecked goal appears - from chat, `board.sh` or an
  edit. `GOAL_WATCH=false` turns it off; its log is `/wd/loop/goal-watch.log`.
- **Reading a card:** the description ends with **Last fire**: which fire ran, its result (`rc=0` = success),
  its duration and what changed. That is the agent's own account of its work.
- **Order:** newest on top. In every column, Done included, the cards are ordered by when their goals reached the board,
  the latest first (goals added together keep the file's order), so Done shows its most recently added goal without
  scrolling. A card you drag within a column keeps its place until the next sync. `KANBAN_CARD_ORDER=file` in
  `.env.local`, then `./stop.sh -s && ./run.sh -s`, puts the oldest on top instead.
- **Filters:** the board opens on **Active**, which hides Done and Cancelled. Click **All** to see finished goals.
- **First load** can take ~30 s after the container starts.
- **Slack:** with `SLACK_BOT_TOKEN` and `SLACK_CHANNELS` set, messages become work. A question gets answered in the thread,
  and a goal-shaped message is added to GOALS.md. Posting can be disabled with `SLACK_POST_ENABLED=false`, in which case
  replies go to `/wd/loop/notes.md`.

## Agent workspaces (Worktree agent runner)
Start a coding agent on a repository in its own git worktree, then review its changes before they land.
1. Open the tile → **Which repositories would you like to work on?** → **Browse** and pick `/wd` or a repo under it
   (or **Create** a new one).
2. **Continue**: the agent works in an isolated worktree, so your checkout is untouched.
3. Review the diff and keep or discard it.
From a goal card you can also open **Workspaces → Create** to start a workspace prefilled with that goal.
Ignore the "Sign in", "Remote" and "Projects" prompts: they belong to a retired cloud service and aren't needed.

## Memory
- **Hindsight memory** (tile opens the `harness-knowledge` bank): long-term facts.
  - **Seeded banks:** `harness-knowledge` (general AWS and agent operations) and `loglearner-rules` (starter rules).
  - **Agent memories** land in `coding-agent::<project>`.
  - **Use it:** open a bank → **Data** to browse, or use recall (search) to ask a question in plain words.
- **Hindsight API docs:** the same memory over HTTP (Swagger), for scripts.
- **claude-mem viewer:** session-level capture (observations, summaries, prompts) from the claude-mem plugin.
- Seeding needs working Bedrock credentials. If Hindsight stays empty, check credentials and model access first.

## Learning
- **LogLearner dashboard:** reads the agent's own Claude Code sessions, then shows gaps, instincts (rules) and a Hindsight
  panel. Tabs: Overview, Instincts, Learnings, Knowledge, Gists, Graph, Hindsight, Export.
- **Learned rules:** LogLearner's Learnings page. It shows the rules delivered into the agent's sessions before each Edit,
  Write and Bash call, and what it banks.

## Files
**Files** is the folder you and the agent share: `/wd/files` in the container, on the agent's volume. Download what the
agent saved for you there; upload files for it to read (drop them on the page or use **Upload files**) and tell the agent the
name - it looks under `/wd/files`. Make folders, rename, move and delete from the page; anything that removes or replaces a
file asks first, and a folder that is not empty asks twice. Uploads up to `FILES_MAX_UPLOAD_MB` (1 GiB by default) each; nothing is executed, and
every download is saved, never shown.

## Operations
- **Restart only the agent:** `./stop.sh -s && ./run.sh -s` removes and starts the agent container alone; the Goals board,
  the Plane board and the build substrate keep running, and the new container joins them. After `./build.sh`, the same
  line puts the new image to work. Without `-s`, both scripts stop and start everything.
- **tmux terminal:** a writable browser terminal on the agent's session (`UI_TMUX_WRITABLE=false` makes it watch-only).
- **tmux cheatsheet:** keys for detaching, windows, panes and scrollback.
- **tmux-agent dashboard:** the fleet tree, history, waste and memory per tmux session.
- **Comms UI:** conversations across channels that need a human.
- **Headlamp:** Kubernetes dashboard. Run `aws eks update-kubeconfig --name <cluster>` first.
- **Plane board:** an optional project-management board, off by default: Plane community edition is AGPL-3.0, so it runs
  only if you set `UI_PLANE=true` in `.env.local` (then `./build.sh` and `./run.sh`, or `./stop.sh && ./run.sh` on a running
  instance; docs/manual/boards.md "Plane board"). On, the agent's
  goals appear as work items and the Board tile shows them read-only.

## The agent stack
- **`agent`** is the session you talk to, in the tmux terminal and the Agent chat. **`supervisor`** is a script, started
  with the container, that keeps `agent` and every spoke alive and unstuck; it reports a session at a menu or an error
  and never answers one. Its tile is in the home page's last group, **Agents**.
- **Spokes** are more Claude Code sessions, each keeping one tile's data current. Seven run by default:
  `conversations`, `insights`, `clusters`, `sessions`, `loops`, `issues` and `docker`. A spoke's session spends model
  tokens only when someone talks to it; `conversations` waits for Slack until `SLACK_BOT_TOKEN` and `SLACK_CHANNELS` are
  set, and `issues` waits for GitHub until `GH_TOKEN` is set. `issues` stages reply drafts and posts nothing: a draft
  reaches GitHub only when you write its GO and run `/agent/charters/issues/post.sh` (docs/AGENT-STACK.md section 7).
  `docker` builds container images inside the harness: ask `agent` to build a Dockerfile and it runs
  `/agent/image-build.sh`, which pushes to the stack's own registry, never anywhere else; the Docker spoke tile opens its
  page, the images with their digests and the build substrate's health (docs/AGENT-STACK.md section 8). To
  turn one off, set `SPOKE_<NAME>=false` in `.env.local`, then `./stop.sh && ./run.sh`. `-s` on both restarts the agent
  container alone - not for `SPOKE_DOCKER`, whose build substrate only a full `./stop.sh` removes. `example` is off by default; it
  proves the set-up without spending tokens, and `SPOKE_EXAMPLE=true` in `.env.local` turns it on. Each spoke's tile in
  **Agents** shows its state and its last message.
- **See them:** `tmux ls` in the container, the browser terminal's session picker (`C-b s`), or the tmux-agent
  dashboard, where the spokes sit under `agent`.
- **Read more:** [the agent stack](/guide/agent-stack/) (each agent, what it keeps, writes and talks about, and what the
  supervisor does on every pass) and [how the agents talk](/guide/messaging/) (session-to-session messages and the
  journal); in the repository, `docs/AGENT-STACK.md` and `docs/INTER-AGENT-MESSAGING.md`.

## Troubleshooting
| Symptom | Check |
|---|---|
| Not sure what is set up | `/agent/doctor.sh` in the tmux terminal, or `/setup` to the agent |
| A tile is grey or "down" | `./status.sh`; the tile's text names the `.env` flag that enables it |
| Hindsight is empty | AWS credentials in the container and Bedrock model access (the seed needs them) |
| Goals board shows no cards | Click **All**; check `/wd/goals/GOALS.md` exists; wait for the next fire |
| Goals board URL says "refused" | Open it from the home page tile (it signs you in) |
| Files: the dot is red, or an upload is refused | `/agent/ui-status.sh` in the container (the `files` row; the folder `/wd/files` must exist and be writable); a 413 means the file is over `FILES_MAX_UPLOAD_MB` |
| Agent didn't act on a goal | `loop-status.sh`; look for `/wd/loop/STOP`; read the card's **Last fire** line |
| A spoke's tile says stuck or down | `/agent/supervisor.sh status` in the container names the reason; the session's pane shows it |
| Rebuilt or reconfigured the agent, the boards should stay up | `./build.sh && ./stop.sh -s && ./run.sh -s` - the agent container alone; `./run.sh -s` says which board or substrate it could not join |
