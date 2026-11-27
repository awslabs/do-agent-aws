# Parity with a native Claude Code instance: the measured gap, the reasons, and what this branch changes

## The question (the operator's words, 2026-10-31)

> Please help me with the following deep question: There are two agents - one of them is you (Agent Anton) and the other
> one is Agent Alex. Agent Anton is running natively on an EC2 instance and was set up by Anton, Agent Alex is the
> do-agent-aws project running in a container and was set up by Alex. The two are up and running, but Agent Anton is
> more helpful than Agent Alex. Agent Anton appears to know more, behave better, give better answers, act more wisely,
> while Agent Alex is not able to do work at the level of Agent Anton. My question is, what are possible reasons for
> this and how can we achieve parity so that Agent Alex is just as good as Agent Anton?

Two follow-ups the same hour: a PR that sets Agent Alex to Claude Fable 5.1 with the 1M context and
`CLAUDE_CODE_EFFORT_LEVEL=max` (the first PR, separate), and "a separate PR with changes to match the rest of the
differences as much as possible" (this branch).

## Method

The same program measures both sides: `tools/parity-inventory.sh` (in the image `/agent/parity-inventory.sh`) prints one
table of what a Claude Code instance runs with - the client, the model and its source, effort, context, the instruction
files on the load path with their bytes, the memory and knowledge stores, skills, agents, plugins, hooks, the autonomous
fire's claude options and timeout, the tools and credential files it can reach. It reads; it writes nothing. The first
column below is that table run on the native instance. The second column is the container's **shipped defaults**, read
from the files of `main` at `fd1e3a9` (the base of this branch; the lines were read at `44b3922` and re-checked at
`fd1e3a9`, where the goal watcher's five `.env` lines moved the responder's below them) with the file and line each fact
comes from - not a running container. The third column is the operator's live container, which nobody but the operator can measure: run

    docker exec do-agent-aws /agent/parity-inventory.sh        # or --json; ./exec.sh opens a shell in the same container

and paste the table there. Every number in the first two columns was measured or read on 2026-10-31; nothing is
estimated. "After this branch" says what the same row reads once this branch and the first PR are merged and the
container is rebuilt.

## The table

| row | the native instance (measured 2026-10-31T03:49Z) | do-agent-aws main fd1e3a9 (shipped defaults) | your container | after this branch (+ the first PR) |
|---|---|---|---|---|
| claude | 2.1.304 | the newest client at build time (`setup/install-claude.sh`) | not measured | same |
| model | `us.anthropic.claude-fable-5-1[1m]` (env `ANTHROPIC_MODEL`, same in `~/.claude/settings.json`) | Bedrock default: nothing sets a model (`Dockerfile` l.52 is only `CLAUDE_CODE_USE_BEDROCK=1`; `agent/doctor.sh` reads `ANTHROPIC_MODEL` only when the person sets it) | not measured | the first PR: `AGENT_MODEL` in `.env`, shipped as Fable 5.1 `[1m]` |
| context 1M | yes | no (no `[1m]` id) | not measured | yes (first PR) |
| effort | max (env `CLAUDE_CODE_EFFORT_LEVEL`) | none (Claude Code's default) | not measured | max (first PR, `AGENT_EFFORT`) |
| fallbackModel | `us.anthropic.claude-opus-5-5[1m]` | none | not measured | the first PR's choice |
| max output tokens | 16384 (env `CLAUDE_CODE_MAX_OUTPUT_TOKENS`) | none (Claude Code's default) | not measured | unchanged (a knob for a later PR) |
| instructions | 9 files, 85,374 bytes: a user `CLAUDE.md` (16,683) and a rules file, a project `CLAUDE.md` (30,979) and 5 project rules, a toolkit note | 4 generic rules files, 12,380 bytes (`Container-Root/agent-rules`: `AGENT_RULES.md` 5,486, `AGENT_LEARNING.md` 3,094, `AGENT_BOARD.md` 2,426, `AGENT_FILES.md` 1,374), referenced from the agent's `CLAUDE.md` by `setup/install-governance.sh` and `agent/claude-settings-sync.sh`; `AGENT_RULES.md` l.3-7 says the site-specific bindings belong in "a private overlay mounted at runtime" and nothing ships one | not measured | the 4 rules files + the overlay the operator fills from `docs/parity/CLAUDE.md.example` (12,077 bytes of contract and placeholders) at `wd/CLAUDE.md` |
| auto-memory | on (Claude Code's default); the cwd's memory directory exists | on by Claude Code's default, stated nowhere | not measured | on, stated: `AGENT_MEMORY=true`, `autoMemoryEnabled` written at every start |
| memory | 10 projects, 597 files, 2.7 MB of self-written memory; this cwd's project 248 files, `MEMORY.md` 24 KB | empty at the first start; persisted under `wd/agent-state/.claude` (`.env` `AGENT_STATE_VOL_MAP`) | not measured | the same mechanism, now stated and kept on; grows as the agent works |
| knowledge | LogLearner banks none on this path (an earlier run at 03:07Z with `PARITY_KNOWLEDGE_DIRS` naming the instance's own learnings banks counted 5,403 records in them); Hindsight not running | 1,331 seed records (`Container-Root/seed/*.jsonl`) + 1,055 records of a team pack loaded into LogLearner and Hindsight at every start (the public release ships 168 seed records and the 21-record example pack `gpu-cluster-basics` instead); delivered by the PreToolUse hook and the recall hook; `agent/learn.sh` the write path | not measured | unchanged; a fire can now call `learn.sh` (under the safe value it could not: Bash was limited to three scripts) |
| skills | 477 `SKILL.md`: 395 of its own, 82 from its 4 enabled plugins that ship skills (one installed version each) | 2 synced into the configuration from `agent/skills` (the vendored issues tracker ships none since its 0.1.9) + the plugins' | not measured | 37 synced (the 2 + 35 imported by `tools/import-skills.py`, `docs/parity/SKILLS-PACK.md`) + the plugins' |
| agents | 51 | the plugins' (oh-my-claudecode ships its agent set; the vendored issues tracker ships none since its 0.1.9) | not measured | unchanged (see P5) |
| plugins | 11 | 8 (`setup/install-plugins.sh` l.10-16: superpowers, context7, code-review, github, claude-md-management, ralph-loop, oh-my-claudecode; claude-mem by `install-claudemem.sh`) | not measured | unchanged |
| hooks | 13 events, 19 entries (its settings files) | 3 Hindsight hooks (SessionStart, UserPromptSubmit, Stop), the LogLearner PreToolUse hook, the recall hook, the session guard, the knowledge integrity hook (`setup/install-hindsight.sh`, `agent/claude-settings-sync.sh`) | not measured | unchanged |
| autonomous fire | `timeout 1500 claude -p --dangerously-skip-permissions` (the claude line of the instance's loop script) | `--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits`, 600 s (`agent/loop.sh` l.138/141, `agent/loop-once.sh` l.32/35, `.env` l.571); the chat responder `--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/goals-add.sh:*) --permission-mode acceptEdits`, 180 s (`agent/slack-chat.sh` l.112/116, `.env` l.720 at fd1e3a9) | not measured | `claude -p --dangerously-skip-permissions`, 1500 s, `IS_SANDBOX=1`, for the fire and the responder; the former values documented as the safe value |
| kubectl, gh, docker, aws, python3, node | all present; kubectl 7 contexts, gh logged in, aws identity answers | all installed in the image (`setup/install-*.sh`); the credentials are the person's mounts (`~/.aws`, `~/.kube`, `GH_TOKEN`) - the setup doctor names each gap | not measured | unchanged (the doctor and the `/setup` skill are the path) |
| credentials | kube config and gh hosts present | none in the image by design | not measured | unchanged |

## The six reasons, in order of effect

1. **The model and how hard it thinks.** Fable 5.1 with the 1M context, effort max and a fallback, against Claude Code's
   Bedrock default with no effort set. The first PR closes this.
2. **Authority to act.** A native fire runs any tool for 1500 s and its operator's loop restarts work that outlives one
   fire; the container's fire could run three scripts under `acceptEdits` for 600 s and its responder two scripts for
   180 s. Most of "does not do the work" is this row: the agent was told to act and could not run the command.
3. **Standing instruction.** 85 KB of operator-specific instruction (who it works for, what it may do unasked, what is
   gated, how to report, what went wrong before) against 12 KB of deliberately generic rules. The harness planned for an
   overlay and shipped none.
4. **Memory of its own.** 248 self-written memory files loaded at every session start against an auto-memory that was
   on but unstated, in a container whose fires could not write anything but their notes file.
5. **Skills and agents.** 477 skills against 2 synced plus the plugins'. Most of the native instance's are domain-specific
   to its own work or bound to its own site; the method skills are what travel, and few of them are free of both.
6. **Process as code.** The native instance's receipts, read-back checks, status files and watchdog lines are scripts;
   the container's fire has the loop's log, the notes file and the boards. This branch narrows it (the inventory, the
   tests) and names what is left (the detached driver).

## What this branch changes, item by item

The operator's rule for every behaviour change (2026-10-31, 03:24Z): configurable, enabled by default, documented. Each
row names the knob, its default, where it is documented and how to turn it off.

| item | status | what landed / what is left | knob | default | documented | off |
|---|---|---|---|---|---|---|
| P1 model, context, effort | **APPLIED** in the first PR (open, separate) | `AGENT_MODEL`, `AGENT_EFFORT` and the tier ids in `.env`, the doctor reading the `[1m]` suffix. Not in this branch, by the operator's split. | `AGENT_MODEL`, `AGENT_EFFORT` (first PR) | Fable 5.1 `[1m]`, max | the first PR's README rows | another id, or empty for Claude Code's default |
| P2 fire authority: options and bound | **APPLIED as an opt-in** (the default again the safe value since the security review of 2026-11-11) | `AUTONOMY_LOOP_CLAUDE_OPTS` and `SLACK_CHAT_CLAUDE_OPTS` take `--dangerously-skip-permissions` when set in `.env.local` (their defaults are the safe values), both timeouts 1500 s; `IS_SANDBOX=1` goes with the flag (Claude Code refuses it to root otherwise: the binary's check is `uid 0 && IS_SANDBOX != "1"`); `permissions.deny` rules still bind under the flag (measured 2026-10-31: a planted deny on `touch` held, the control created the file). Tests: `test4.sh` ok 18 and 25 (the argv and `IS_SANDBOX=1` of the fire and of the reply), `test-parity-inventory.sh` ok 6 (loop-once.sh and loop.sh). | `AUTONOMY_LOOP_CLAUDE_OPTS`, `AUTONOMY_LOOP_FIRE_TIMEOUT`, `SLACK_CHAT_CLAUDE_OPTS`, `SLACK_CHAT_TIMEOUT` | `--dangerously-skip-permissions`, 1500, the same, 1500 | docs/manual/autonomy.md "Autonomy loop" (the authority, the one-sentence risk, the safe value), "Slack connectivity", `.env`, `docs/slack/README.md` | the safe value in `.env.local`: `export AUTONOMY_LOOP_CLAUDE_OPTS="--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/recall.sh:*) Bash(/agent/bus-answer.sh:*) --permission-mode acceptEdits"` and `export SLACK_CHAT_CLAUDE_OPTS="--allowedTools Bash(/agent/slack-post.sh:*) Bash(/agent/goals-add.sh:*) --permission-mode acceptEdits"`; the timeouts as numbers |
| P2 fire authority: work longer than one fire | **NOT DONE** | The native instance runs long work as a detached driver: a launcher that re-runs `claude -p` on a brief until a status file carries a terminal line, grades every exit, caps the attempts, and a `WATCHDOG` line its loop probes to relaunch a dead driver. The harness has one bounded fire per cycle, the goals file plus `notes.md` between fires, and since fd1e3a9 the goal watcher that restarts a stopped loop on a new goal. What closing it takes: `/agent/driver.sh` (the launcher, ~100 lines), a `WATCHDOG` probe in `loop.sh`'s cycle that composes with the goal watcher (a probe relaunches a driver, never a second loop), a test with a stand-in claude; left out of this branch for budget, named here so it is not forgotten. | - | - | this row | - |
| P3 the operator's overlay | **APPLIED** (the bytes are the operator's to fill) | `docs/parity/CLAUDE.md.example` (shipped as `/agent/CLAUDE.md.example`): the native instance's standing instructions, scrubbed to placeholders, keeping the contract. Copied to `wd/CLAUDE.md` it is read by every fire, the responder and the pane (`/wd` is their working directory). `/agent/claude-overlay.sh`, run at every start, writes a short stub there when no file exists - "not filled yet, the example is here" - so a session knows the state; a file that exists is never touched. Test: `test-parity-inventory.sh` ok 5 (a planted `CLAUDE.md` in the working directory is counted) and ok 8 (the stub). | `AGENT_OVERLAY` | true (the stub is written when no file exists) | docs/manual/autonomy.md "Parity with a native instance", `.env`, the example's own header | `AGENT_OVERLAY=false` (nothing written; an existing file stays) |
| P4 memory: auto-memory | **APPLIED** | `/agent/claude-memory-settings.py` writes `autoMemoryEnabled` into the persisted `settings.json` at every start (merge-safe), so an older state or a changed default follows the knob. The plan's "SessionStart hook that injects the index" was not built: Claude Code loads `MEMORY.md` itself, also under `claude -p` (measured on the native instance's own headless sessions), so a hook would inject it twice. Test: `test-parity-inventory.sh` ok 7. | `AGENT_MEMORY` | true | docs/manual/memory.md "Agent memory", `.env` | `AGENT_MEMORY=false` (off at the next start) |
| P4 memory: an agent-writable learnings path | **APPLIED by P2** (no new mechanism) | `learn.sh` was never human-gated (the bank's `--lifecycle` defaults to `screened`, the caller-verified state; `candidate` is the human-review state); what kept a fire from banking was its permission mode, which allowed three scripts. With the shipped default a fire runs `learn.sh`; the Edit deny rules on the stores still hold, so `learn.sh` stays the only write path (its schema and credential gates, its stable ids). | P2's knobs | - | docs/manual/memory.md "Agent learning tools" | P2's safe value (a fire then cannot bank) |
| P5 skills | **APPLIED** | 35 of 395 skills imported by one rule (`docs/parity/SKILLS-PACK.md`: subject not domain-specific, body not saturated, description unchanged by the scrub, at most two references to the source host - paths, its names, the skill's own files not copied -, no dependence on an unshipped skill, not a plugin's, nothing leak-shaped after the scrub); dropped: 294 domain-specific, 29 host-bound, 15 about the source site, 14 depending on an unshipped skill, 5 over the size limit, 3 shipped by a plugin. They ship under `/agent/skills` and reach the configuration the way the harness's own skills do. Test: `test-skills-pack.sh` ok 1-6. | `AGENT_SKILLS_PACK` | true (synced at every start) | docs/manual/autonomy.md "Parity with a native instance", `.env`, `docs/parity/SKILLS-PACK.md` | `AGENT_SKILLS_PACK=false` (left out; an earlier start's copies removed; the harness's own two skills stay) |
| P5 agents | **NOT DONE** (by the rule, not by omission) | The native instance's 51 agent files are 20 copies of oh-my-claudecode's agents (the image installs that plugin, so they are already there), 29 specific to its own hardware and frameworks, and 2 personas tied to its own repositories. None passes the rule the skills were held to. The rule and the counts are stated so a future pack can apply it. | - | - | this row | - |
| P6 the evaluation | **REMOVED** | The replay set (the five most recent deliverable asks of the native instance with their rubric) and its runner are not part of the public release: they were taken out with the evaluation records. | - | - | - | - |
| the inventory | **APPLIED** | `tools/parity-inventory.sh`, 24 rows, the same on either side; `test-parity-inventory.sh` ok 1-5 and 9 (the native and the container branch). | none (a read-only tool; `PARITY_LOOP_SCRIPT` names a native loop script) | - | docs/manual/autonomy.md "Parity with a native instance", the script's header | - |
| the fire replies in the thread of the message it answers | not this branch | the third PR of the same day owns the reply placement in `slack-chat.sh`, the fire prompts and the comms UI; this branch does not touch those hunks | - | - | - | - |

## Decisions that are the operator's

- **P1, model access and cost**: made (the first PR; the override for an account without Fable access is there).
- **P2, the authority and its risk**: made for this branch ("match the rest of the differences") and turned into an
  opt-in by the security review of 2026-11-11. The one-sentence risk: an unattended fire with the opt-in can run any
  command its container can, on any cluster or account its credentials reach, driven by whatever its goals file and its
  Slack inbox say. The opt-in is one line in `.env.local` (docs/manual/autonomy.md "Autonomy loop"), for the loop and the chat responder
  alike. The Slack inbox holds only the messages of the people `SLACK_ALLOWED_USERS` names (empty, the default, takes no
  one's; another bot's message never), so with the opt-in those people, and only they, can have the responder run
  commands in the container, with the container's credentials. A bypass default set in a settings file rather than in the
  options gets no `IS_SANDBOX=1` from the loop and is refused as root: set it in the options.
- **P3, the overlay's content**: the operator's bindings; the example says where each goes.
- **P6, running the replay**: none left in the public release, which does not carry the replay set.
- **The detached driver**: whether the harness should run work longer than one fire the way the native instance does,
  or keep the goals file as the carrier between fires.

## How to check it after a merge

1. In the container: `docker exec do-agent-aws /agent/parity-inventory.sh` - the `autonomous fire`, `auto-memory`,
   `skills` and `instructions` rows read as the last column above; the `model` row as the first PR says.
2. `./test.sh` runs `test-parity-inventory.sh` (ok 1-9), `test-skills-pack.sh` (ok 1-6) and `test4.sh` (ok 1-60) with
   the suite; from a checkout each runs alone: `bash Container-Root/<test>.sh`.
3. One fire that does what the native instance does: a goal that says "run `kubectl get nodes` against `<context>` and
   open a draft pull request with the output as a file" ends with the command run and the PR open - the check the plan
   named for P2. It needs the operator's kubeconfig and GitHub token in the container (the setup doctor's rows).
4. The overlay in place: `wd/CLAUDE.md` filled from the example; the inventory's `instructions` row lists it.
