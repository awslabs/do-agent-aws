# The autonomy loop

How the agent works on goals by itself, and how it compares with a native Claude Code instance. Part of the [Do Agent on AWS manual](README.md).

Contents:

- [Autonomy loop](#autonomy-loop)
- [Parity with a native instance](#parity-with-a-native-instance)

## Autonomy loop

The container can drive goals autonomously instead of only answering one-shot prompts. The loop starts with the
container when `AUTONOMY_LOOP=true` in `.env`, or when it is `auto` (the shipped default) and Slack is configured
(`SLACK_BOT_TOKEN` and `SLACK_CHANNELS` set - see "Slack connectivity"); `AUTONOMY_LOOP=false` keeps it off. Place a
goals file at `wd/goals/GOALS.md` in the project directory (visible in the container as
`/wd/goals/GOALS.md`) - [docs/loop/GOALS.md.example](../loop/GOALS.md.example) is a ready-to-copy example
that also explains how to write goals the loop can finish; on startup the container runs `/agent/loop-start.sh`, which launches the loop
`/agent/loop.sh` detached. The loop fires one headless claude cycle (Observe -> Act -> Persist -> Stop) against
the goals file every `AUTONOMY_LOOP_INTERVAL` seconds. Each fire appends an outcome line to `/wd/loop/loop.log`,
saves its transcript under `/wd/loop/fires/`, and updates the one-line machine-readable `/wd/loop/loop.state` so
an outside probe can tell whether the loop is firing, sleeping, idle, or stopped. The loop holds a
single-instance lock, wraps every fire in an `AUTONOMY_LOOP_FIRE_TIMEOUT` timeout, and halts cleanly when the
stop flag `/wd/loop/STOP` is created - the agent creates the flag itself when all goals are complete.

**The goal form, and how to add one.** A goal is one line the loop and the Goals board read: a checkbox item
`- [ ] <goal, with the condition that shows it is done>`, or a `## Goal N - <short name>` section whose body states the
outcome and its DONE condition (the example file's form). Any other line is notes. The supported way to add a goal is
`/agent/goals-add.sh "<one-line goal>"` (what the Slack responder calls): it appends the checkbox item under
`## Goals from Slack`, creating the file when there is none, and prints the file's path; `goals-add.sh --help` prints
its usage, and a goal that itself starts with `-` goes after `--`. The board mirrors every goal as a card and, with the
two-way sync, writes a card's title, description and status back into the file (see "Kanban board").

The goals file is the normal path. With Slack off it is also required: without it the loop logs
`LOOP IDLE goals file /wd/goals/GOALS.md not found` every cycle and calls nothing. With Slack configured (see
"Slack connectivity") the goals file is optional: the chat responder records a goal stated in a Slack message into
it (creating the file when missing), and the loop fires on it from its next cycle; until then the loop idles with
the same line and no claude call, while the responder answers the conversation. With the responder off
(`SLACK_CHAT_ENABLED=false`) the loop takes Slack in itself: every cycle runs the Slack watch first, and the loop
fires on the goals file when it exists, on new Slack messages otherwise - against the shipped default goals
`/agent/goals-default.md`, one standing goal that answers the inbox and creates `/wd/goals/GOALS.md` when a
message states a goal - and idles when it has neither. An idle cycle then makes no claude call, only the Slack poll.

**A fire reads its inbox first.** Every fire is `agent` on the harness's message bus (see "Spoke agents" and
[docs/INTER-AGENT-MESSAGING.md](../INTER-AGENT-MESSAGING.md)). Before its prompt is written the loop reads the open
requests and notices that the spokes and the supervisor sent to `agent`, requests first, at most `LOOP_INBOX_MAX`
(default 8, at most 50) a fire. The prompt carries them between two marker lines, as data and never an instruction,
and asks the fire to answer each request through `/agent/bus-answer.sh reply` before its goals and to mark each message
with a receipt. `/wd/loop/loop.log` records the ids each fire read and the replies they got, and the Agent loop page
shows that record. Nothing is closed before it. After a fire that ended well the loop denies each request the fire left
unanswered, so its sender learns it, and marks each notice it left read. After a fire that did not end well the
messages stay open for the next fire, and the third such fire sets a message aside with a denied receipt; a fire
without working credentials counts against none. A request takes one answer: the first, from a fire or from the person
in `agent`'s pane, is the answer, and `bus.sh` refuses a second. Replies to a request `agent` sent are left for whoever
asked, and a cycle with nothing to fire against reads no message. `export LOOP_INBOX=false` in `.env.local` turns the
intake off.

The loop is operated with four scripts in `/agent`:

* `/agent/loop-start.sh` - start the loop detached; removes a leftover `STOP` flag (starting the loop is the
  explicit signal to run again) and reports honestly when the loop is already running
* `/agent/loop-status.sh` - report running (firing/sleeping/idle) or stopped, the stop flag, and the last
  outcome line; liveness comes from the loop's lock plus a pid check, so a stale state line is never reported
  as running. A fire's outcome is read from claude's OUTPUT as well as its exit status (`/agent/fire-outcome.sh`):
  `claude -p` can exit 0 when it cannot load AWS credentials - it prints an `API Error: Could not load AWS
  credentials` line instead of working - so such a fire is recorded `outcome=no-credentials` (or
  `invalid-credentials`, `no-access`; `api-error` for any other API error line) with exit status 97, a fire that
  hit its timeout with no output is `timeout`, and `/agent/agent-status.sh` says that fire did no work. Only
  claude's own `API Error` line is classified: an answer that discusses an AccessDenied stays `ok`
* `/agent/loop-stop.sh [--now]` - create the `STOP` flag so the loop halts cleanly before its next fire; with
  `--now` also terminate the loop process immediately (exact pid from `loop.state`) along with any in-flight fire
* `/agent/loop-once.sh` - optional debugging aid: run exactly one fire in the foreground with the transcript
  streamed to the terminal; refuses to run while the loop is running

The loop state directory is written by the container's agent user, so operate the loop from the host through the
running container, e.g. `docker exec do-agent-aws /agent/loop-stop.sh`. Because the goals and loop
state live on the `/wd` volume, they survive `./stop.sh` / `./run.sh` and fire numbering resumes where it left
off. With `AUTONOMY_LOOP=false`, or at `auto` with no Slack configured, the loop does not start and the container
runs without it; `docker exec do-agent-aws /agent/slack-gates.sh` prints the decision and its reason.
In the browser the `Agent loop` tile shows the same state with every fire, its transcript and the goals (see "Agent
loop page"), and the tmux-agent dashboard's tree has the loop and its fire in flight under the operator (see "tmux-agent
dashboard").

**A fire's authority, and the safe value.** A fire runs `claude -p` with the options in `AUTONOMY_LOOP_CLAUDE_OPTS`,
by default the **safe value** below. The opt-in `--dangerously-skip-permissions` runs every tool without a permission
check, the authority a native Claude Code instance driven by a loop has (see "Parity with a native instance"); it is not
the default because an unattended fire is driven by its goals file and its Slack inbox, which other people write. Claude Code refuses that flag to root
unless the process declares itself a deliberate sandbox, so the fire's environment carries `IS_SANDBOX=1` whenever its
options skip the permission checks: the container's own user is the unprivileged `agent` ("Container user"), and the
Docker Sandboxes kit, which runs as root inside its microVM, is that sandbox. The `permissions.deny` rules of the agent's
`settings.json` (the stores, "Agent learning tools") still bind under the flag. The risk of the opt-in in one sentence: an
unattended fire with it can run any command its container can, on any cluster or account its credentials reach, driven
by whatever its goals file and its Slack inbox say (the inbox holds only the messages of the people `SLACK_ALLOWED_USERS`
names, "Slack connectivity"). Each fire is still bounded by `AUTONOMY_LOOP_FIRE_TIMEOUT` (1500 s).
The **safe value**, the shipped default,
is `--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode
acceptEdits`: the fire reads and edits files in its project directory and runs those four scripts (the second attaches a
file in Slack, docs/slack/README.md section 9a), and headless claude
denies every other Bash call. `/agent/bus-answer.sh` answers and closes the messages to `agent` and starts none: it
refuses `bus.sh`'s `request`, `note`, `send`, `poll`, `peek` and `last`. To give the fires of one host the safe value
plus a rule, set the whole option string in `.env.local`, keeping the four rules, for example

```
export AUTONOMY_LOOP_CLAUDE_OPTS="--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/slack-upload.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) Read(//opt/comms/**) --permission-mode acceptEdits"
```

`./run.sh` passes it into the container: with the docker target (`TO=docker`, the default) as a bare
`-e AUTONOMY_LOOP_CLAUDE_OPTS`, so docker copies the value whole, and with `TO=compose` or `TO=kubernetes` in the
files it renders from the templates; with `TO=sandbox` it is not passed at all, since a sandbox runs the kit image's own
environment (`to/sandbox/README.md`). Unset, docker passes nothing and the templates pass an empty value; either way
fires keep the shipped default, the safe value. The opt-in for a host whose goals and channels are trusted with every
tool is `export AUTONOMY_LOOP_CLAUDE_OPTS="--dangerously-skip-permissions"` in `.env.local`. In those rendered files the value is YAML text, like the other loop settings: a `"` or `\`
breaks the kubernetes manifest's quoted string, and in compose ` #` starts a comment that cuts the value and a `$` is
interpolated a second time, so keep these characters out of it.
It takes effect when the container is next created (`./stop.sh && ./run.sh`, or `./stop.sh -s && ./run.sh -s` for the
agent container alone - "Restart only the agent container"). Four rules:

* Put `--allowedTools` first and `--permission-mode` after it, as the safe value does. That order is the safe convention,
  not a requirement: `--allowedTools` takes every following word as a rule until the next option (it is variadic),
  and a fire passes its prompt on stdin, so the other order works as well.
* A rule may hold spaces inside its parentheses: the value is split on blanks outside parentheses only, so
  `Bash(kubectl get:*)` and `Bash(bash /wd/loop/run-next-fire/apply_to_source.sh:*)` are one rule each (split on every
  blank, such a rule would reach claude as two words, the second refused with `Ignoring --allowedTools rule "...":
  Wildcard tool name ... is not supported in allow rules`, the rule gone and every call it allowed denied until the
  fire timed out). Quotes in the value are still not quotes. A `Bash`
  rule is a prefix of the command text the model types: a script the goal says to run as `bash /path/x.sh` needs
  `Bash(bash /path/x.sh:*)`, and `Bash(/path/x.sh:*)` matches it only when it is run as `/path/x.sh`.
* Before its fires the loop checks the value (`AUTONOMY_LOOP_OPTS_CHECK`, `true` by default): a word of an allow or deny
  list that cannot be a rule - parentheses that do not pair up, quotes around a rule, a tool name that can match no tool
  (the check is stricter than the client: claude refuses only a `*` in an allow rule's tool name, outside the tool part
  of an `mcp__` name, and takes a name with a slash or a dot silently; both allow nothing) - is reported with every such
  word quoted in `/wd/loop/loop.log` (`LOOP CONFIG ...` at start), and each fire is skipped instead of
  run: no claude call, `FIRE n END rc=96 ... outcome=config <report>`, the report as the fire's transcript (the Agent
  loop page shows it, `/agent/agent-status.sh` says the fire did no work), the loop trying again next interval. The
  chat responder checks `SLACK_CHAT_CLAUDE_OPTS` the same way and answers each message that needs the model with one
  line saying so. `AUTONOMY_LOOP_OPTS_CHECK=false` in `.env.local` logs the report as a `WARNING` and runs the calls as
  before (claude ignores the rule and says so at the top of the transcript, which the fire's END line then names:
  `outcome=ok ignored-rule "<word>"`). The check reads the shape of the rules, not the tools they name.
* A `Read` or `Edit` rule for an absolute path takes two slashes, `Read(//opt/comms/**)`; with one slash,
  `Read(/opt/comms/**)` is a path in its project directory (the fire's working directory, `AUTONOMY_LOOP_WORKDIR`,
  `/wd` by default).

These rules were checked with Claude Code 2.1.304 (2026-11-03): the client itself takes a space inside the parentheses
of one argument, refuses an allow rule whose tool name holds a `*` outside the tool part of an `mcp__` name (the
`Ignoring --allowedTools rule` line), takes any other unknown tool name silently (it matches nothing), and matches a
`Bash` rule as a prefix of the command text. The image installs the client `CLAUDE_CODE_VERSION` pins in `.env` (`claude --version`
in the container prints it), and a later client may change the rule grammar.

The risk is plain: a fire runs unattended, with no one to approve a step. The opt-in hands the loop every
tool, so write power over any cluster or account its credentials reach, and lets a fire that a message drives run
`/agent/bus.sh` and send requests and notices to every spoke; under the safe value a blanket rule such as
`Bash(kubectl:*)` or `Bash(aws:*)` hands over the same write power one command at a time, and `Bash(/agent/bus.sh:*)`
the bus. The safe value stays read and edit only, plus the three scripts, of which the bus script only answers the
messages to `agent`; with it, goals that change a cluster belong to the interactive agent session, where a person sees
each step. A host whose goals and channels are trusted with that authority sets the opt-in in `.env.local`.

**Supervisor mode.** The cycle above is the shipped mode, `AUTONOMY_LOOP_MODE=serial`: one fire at a time on the first
open goal in file order, `AUTONOMY_LOOP_INTERVAL` between fires, however many goals are open. `AUTONOMY_LOOP_MODE=supervisor`
makes the loop a coordinator instead. Every cycle it runs the planner `/agent/supervisor-plan.py` over the goals file and
the tail of `/wd/loop/notes.md`, takes the open goals and sorts them: a goal whose line carries the leading note
`(priority: high)` comes first, `(priority: low)` last, file order otherwise; goals that share a resource - a checkout or
directory named in the goal text or in its earlier notes lines (the leading components of every absolute path), a Slack
thread (`(from Slack <channel> <ts>)`, `thread <ts>`), a pending `[QUESTION <N>]` or `[ACTION <N>]` answer, an AWS account
or profile, or an explicit `(serial-with: G<n>)` or `(after: G<n>)` note on the line - form one serial chain, and goals that
share nothing are independent. The loop then fires one worker per chain or independent goal at once, up to
`SUPERVISOR_MAX_WORKERS` (default 3), and starts the next cycle as soon as a worker has ended well; the interval applies
only when nothing could be dispatched or no worker ended well. Each worker is a fire of its own - FIRE number,
transcript under `/wd/loop/fires/`, `END` line, outcome, board card - running the same `claude -p` call with the same
options, timeout and `IS_SANDBOX` rule as a serial fire, plus a YOUR GOALS section in its prompt: the goals it works on
and no other (their `G<n> (line L)` ids, hashes and text), the other workers' paths to leave alone, and the two gated
scripts it writes through. For every resource key of a group the loop holds a lock (`flock` on
`/wd/loop/locks/<sha256 of the key>.lock`) for the worker's life, so no two workers edit one checkout or post in one
thread, and one post order per thread is kept; a group whose lock is busy waits for the next cycle, logged. The bus inbox
(and the Slack batch, when the loop owns the inbox) goes to the first worker of a cycle only. The planner only ever
over-merges: a false shared key makes two goals serial, which costs speed, never correctness.
`python3 -I /agent/supervisor-plan.py --goals /wd/goals/GOALS.md --notes /wd/loop/notes.md --explain` prints the order,
the groups with the keys that bound them and the dispatch, read-only - the way to see why two goals are one chain. The
default goals file (no user goals yet) always fires serially; a planner failure falls back to one serial fire with a
`LOOP WARNING`; the loop, not a worker, creates `STOP` when no goal is open.

*How a worker differs from a serial fire.* Its prompt has no STOP step: it never creates `/wd/loop/STOP` (the loop does),
never runs `goals-add.sh`, never edits the goals file or the notes file directly. It marks one of its own goals done with
`/agent/goals-mark.sh G<n> --note '<the evidence>'` - the script flips that one `- [ ]` under the goals lock and refuses a
goal whose hash is not in the worker's `WORKER_GOAL_HASHES` (exit 3; 4 no such goal or already done, 5 lock busy, 6 the
line changed meanwhile) - and appends its one progress line with `/agent/notes-append.sh '<one line>'` (under
`/wd/loop/notes.lock`; exit 5 lock busy). A fire that is not a worker has `WORKER_GOAL_HASHES` empty, so `goals-mark.sh`
refuses it every goal: the serial fire keeps editing the goals file itself, as its prompt says. The notes lines of two
workers may interleave; each names its fire and goal. The board mirrors record each worker's own goal
(`fire-start --goal-key`), so two cards move at once and a worker's end never credits another worker's goal.

*Priority.* The marker is a leading parenthesised note on the goal line, `- [ ] (priority: high) <goal> ...`, so it
changes no board card (both mirrors key a card by the text without its leading notes).
`/agent/goals-add.sh --priority high|low "<goal>" "<channel> <ts>"` writes it on a new goal, and the chat responder passes
`--priority high` when the message says high priority, first, urgent, ASAP or top priority and `--priority low` for "can
wait" or "low priority"; `/agent/goals-add.sh --set-priority G<n>|L<line> high|low|normal` changes the marker of a goal
already in the file (the responder runs it for "make G<n> high priority", "G<n> first", "G<n> can wait", "G<n> back to
normal"; `normal` removes the note; exit 4 no such goal, 5 busy, 6 changed meanwhile). `G<n>` is `board.sh`'s number -
the n-th checkbox goal counting from the top, done ones included - and `L<line>` a file line. A high priority also
touches the WAKE flag, so a sleeping loop starts its next cycle within seconds and the goal is dispatched in it. In
serial mode the marker is part of the goal text a fire reads; only the supervisor's planner orders by it.

*Strikes and parking.* A worker that ends with a non-zero status adds one strike per goal of its group to
`/wd/loop/supervisor/strikes.tsv` (a timeout 124/137, a config 96 or a credentials 97 end counts against none, as the
bus intake counts); a goal with `SUPERVISOR_STRIKES_MAX` (default 3) strikes in a row is parked for
`SUPERVISOR_PARK_CYCLES` (default 6) cycles - a row in `/wd/loop/supervisor/parked`, one `loop.log` line and one notes
line - the planner leaves it out of the dispatch and the other groups go on. A worker that ends well clears its goals'
strikes; the parking ends at its cycle, or sooner with `/agent/goals-add.sh --unpark G<n>` (the operator's "retry G<n>" in
chat). The post in the goal's thread that announces a parking is not implemented in this version.

*Preview, files, state.* `AUTONOMY_LOOP_DRY_RUN=true` runs ONE cycle that prints what it would fire -
`WOULD FIRE <N> group=<id> goals=... hashes=...` per worker (serial mode: `WOULD FIRE <N> mode=serial goals=<file>`), the
planner's dispatch over the live goals file - with no claude call, no Slack watch, no bus read, no board call and no
`STOP` or `WAKE` change, then exits with the state `STOPPED reason=dry-run`; set it back to `false` afterwards, since the
goal watcher starts the loop again on the next new goal. The cycle's files are under `/wd/loop/supervisor/`: `cycle` (the
counter), `plan-<cycle>.json` and `.txt` (the planner's plan), `dispatch-<cycle>.tsv`, one `worker-<cycle>-<group>.txt`
per dispatched worker (its YOUR GOALS section), `strikes.tsv` and `parked`; plans, dispatches and worker files older than
two days are removed at the next cycle. `loop.log` names the mode and its settings at start (`LOOP MODE supervisor
max_workers=... planner=... plans=... locks=...`), each cycle's summary (`LOOP SUPERVISOR cycle N: open=.. groups=..
dispatch=.. waiting=.. blocked=.. parked=..`) and each worker's `FIRE <N> BEGIN ... group=<id> group_goals=G.. worker=k/K
cycle=C` and `END ... group=<id> cycle=C`; `loop.state` reads `FIRING fire=<N>,<M> workers=K cycle=C mode=supervisor` and
`SLEEPING ... mode=supervisor cycle=C workers=K`, its first token as before, so the Agent loop page, `loop-status.sh` and
the loops monitor keep working and show the first worker. `/agent/loop-once.sh` runs one serial fire whatever the mode
says.

*Settings.* Declared in `.env` with their defaults and passed to the container like the other loop settings (the docker
option string, the compose and kubernetes templates); set them in `.env.local` and restart (`./stop.sh && ./run.sh`):

| Setting | Default | Effect |
|---|---|---|
| `AUTONOMY_LOOP_MODE` | `serial` | `serial`: the cycle above, one fire at a time; `supervisor`: this mode. Any other value, or `supervisor` with the planner missing, runs serial with a `LOOP MODE` warning in `loop.log` |
| `AUTONOMY_LOOP_DRY_RUN` | `false` | `true`: one cycle of `WOULD FIRE` lines, no claude call, then exit (above) |
| `SUPERVISOR_MAX_WORKERS` | `3` | workers a cycle fires at once; `1` = one fire at a time in priority order. Start with 2 while you watch the planner's groupings |
| `SUPERVISOR_MODEL_PASS` | `false` | reserved: a short model pass over the plan that may only merge groups. This version logs that it is not implemented and the deterministic plan stands |
| `SUPERVISOR_MODEL_TIMEOUT` | `120` | seconds that pass may take, when it exists |
| `SUPERVISOR_STRIKES_MAX` | `3` | fires in a row that did not end well before a goal is parked |
| `SUPERVISOR_PARK_CYCLES` | `6` | cycles a parked goal sits out |
| `SUPERVISOR_WORKER_OPTS` | (empty) | extra claude options for a worker after `AUTONOMY_LOOP_CLAUDE_OPTS`, e.g. `--max-turns 60`; split and checked like the main option string |

Everything ships behind `AUTONOMY_LOOP_MODE`: with the default nothing changes. The mode is the autonomy loop's own; the
`supervisor` of "Spoke agents" (`SUPERVISOR`, `SUPERVISOR_INTERVAL`, ...) is the process that starts and watches the spoke
sessions, and the two share no setting. Known limits: every concurrent worker is a model session, so provider throttling
shows as slower fires, not wrong ones; the pages that assume one fire at a time show the first worker; a worker that
ignores a prompt rule (a direct edit of the goals file, a post in another goal's thread) is stopped by the locks and the
gated scripts where it can be and is visible in its transcript where it cannot.

## Parity with a native instance

A Claude Code instance a person runs natively on a host, with their own settings, instructions, memory and skills, can
be put side by side with this container: `/agent/parity-inventory.sh` (in a checkout `tools/parity-inventory.sh`) prints
one table of what the instance it runs in runs with - the client, the model and where it is set, effort, the 1M context,
every `CLAUDE.md` on the load path with its bytes, the auto-memory and the memory files, the knowledge banks and the
memory API, skills, agents, plugins, hooks, the loop fire's and the chat responder's claude options and timeouts, the
tools and credential files it can reach - the same rows on either side (`--json` for the same as JSON). It only reads,
and writes nothing; no account id, login, context name or credential is printed, and the home directory is written as `~`. On a
native host run it from the directory a session works in, with `PARITY_LOOP_SCRIPT=<the loop script whose claude -p lines
carry the fire's flags>`; in the container `docker exec do-agent-aws /agent/parity-inventory.sh`.

Put side by side, a native instance and this harness's shipped defaults differ in the model and how hard it thinks, the
fire's authority, the standing instructions, the agent's own memory, the skills and agents, and the process a native
instance keeps as scripts. What the harness ships for that, each with its test:

* the fire's authority - `AUTONOMY_LOOP_CLAUDE_OPTS` and `SLACK_CHAT_CLAUDE_OPTS` default to their safe values; a native
  instance's authority, `--dangerously-skip-permissions` with `IS_SANDBOX=1`, is the opt-in in `.env.local`; the
  timeouts are 1500 s ("Autonomy loop";
  `test-parity-inventory.sh` ok 6, `test-slack-senders.sh`). The trust boundary of the opt-in is the people
  `SLACK_ALLOWED_USERS` names: each of them can have the responder run commands in the container, with the container's
  credentials, and a long reply holds the responder's queue (status, goals and help included) for up to its timeout,
  since replies are answered one at a time;
* the operator's overlay - [docs/parity/CLAUDE.md.example](../parity/CLAUDE.md.example), copied to `wd/CLAUDE.md` and
  filled in, is the standing instruction every fire, the responder and the pane read (`/wd` is their working directory).
  `AGENT_OVERLAY=true` (the default) has `/agent/claude-overlay.sh` write a short stub there at a start that finds no
  file - it says the overlay is not filled yet and names the shipped example, `/agent/CLAUDE.md.example`, so a session
  knows the state instead of guessing; a file that exists is never touched, and `AGENT_OVERLAY=false` writes nothing
  (`test-parity-inventory.sh` ok 8; ok 9 reads the container's own defaults through the inventory);
* the agent's own memory stated - `AGENT_MEMORY` ("Agent memory"; `test-parity-inventory.sh` ok 7);
* a skills pack - 35 domain-general skills imported from a native instance's library by one stated rule, scrubbed, under
  `/agent/skills` ([docs/parity/SKILLS-PACK.md](../parity/SKILLS-PACK.md) lists each with its verdict;
  `tools/import-skills.py` repeats the import from any such library). `AGENT_SKILLS_PACK=true` (the default) syncs them
  into the agent's Claude configuration at every start with the harness's own skills; `false` leaves them out and removes
  the copies an earlier start made, the harness's own two untouched; a skill of the person's own under a shipped name is
  kept and reported, never overwritten (`test-skills-pack.sh` ok 4-6).
