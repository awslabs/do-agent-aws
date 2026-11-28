---
name: claude-code-best-practices
description: Use when a Claude Code session is going sideways or could be run better — context filling up / performance degrading, repeated corrections on the same issue, an unattended/long/autonomous run, a large or multi-file feature, or deciding whether to plan, clear, spawn subagents, or parallelize. Symptoms — "looks done" with no check, vague prompt, kitchen-sink session, bloated CLAUDE.md, infinite exploration.
---

# Claude Code Best Practices

## Overview

Source: Anthropic's official best-practices guide (code.claude.com/docs/en/best-practices).

**The one constraint everything follows from: the context window fills fast, and
model performance degrades as it fills.** Context holds the whole conversation —
every message, file read, and command output. Manage it as your scarcest resource.

## Give Claude a way to verify its work

Claude stops when work "looks done." Without a check it can run, YOU are the
verification loop. Give it a pass/fail signal — tests, build exit code, linter, a
diff against a fixture, a screenshot vs a design — and it closes the loop itself.

- **In one prompt:** "implement X, run the tests, iterate until they pass."
- **Across a session:** a `/goal` condition re-checked every turn.
- **Deterministic gate:** a Stop hook that blocks turn-end until a script passes.
- **Second opinion:** a verification subagent / `/code-review` on a fresh context.

Show evidence (test output, command + result, screenshot), don't assert success.

## Explore -> plan -> code -> commit

Jumping straight to code solves the wrong problem. Use **plan mode** to separate
research from execution: (1) Explore — read files, answer questions, no edits;
(2) Plan — detailed implementation plan (`Ctrl+G` to edit it); (3) Implement —
code, verify against the plan; (4) Commit — descriptive message + PR.

**Skip the plan** when you could describe the diff in one sentence (typo, log
line, rename). Plan when uncertain of approach, multi-file, or unfamiliar code.

## Provide specific context

Precise instructions = fewer corrections. Scope the task (which file, what
scenario, test prefs). Point to sources ("look through X's git history"). Name
example patterns ("follow HotDogWidget.php"). Describe the symptom + likely
location + what "fixed" looks like. Vague prompts are fine only when exploring.

Rich input: `@file` refs, paste/drag images, give doc URLs (allowlist domains),
`cat error.log | claude`, or tell Claude to fetch context itself.

## Configure the environment

- **CLAUDE.md** (`/init` to seed): Bash commands Claude can't guess, non-default
  style rules, test runners, repo etiquette, project-specific architecture, env
  quirks, gotchas. EXCLUDE anything inferable from code, standard conventions,
  volatile info, tutorials. Keep it short — bloat makes Claude ignore real rules.
  Test each line: "would removing this cause a mistake?" Broadly-applicable only;
  put sometimes-relevant knowledge in **skills** (loaded on demand).
- **Permissions:** auto mode (classifier gates risky actions), `/permissions`
  allowlist, or `/sandbox` OS isolation — each cuts prompts, keeps you in control.
- **CLI tools** (`gh`, `aws`, `gcloud`): most context-efficient external access.
- **MCP servers**, **hooks** (deterministic, must-happen-every-time actions),
  **skills** (`.claude/skills/`), **subagents** (`.claude/agents/`), **plugins**.

## Manage the session

- **Course-correct early:** `Esc` to interrupt (context preserved), "undo that",
  `Esc Esc`/`/rewind` to restore a checkpoint. Corrected the same issue twice?
  `/clear` and write a better prompt — a clean session beats an accumulated one.
- **Manage context aggressively:** `/clear` between unrelated tasks; `/compact
  <focus>`; `/rewind` to summarize part of a conversation; `/btw` for
  out-of-context questions.
- **Subagents for investigation/verification:** they explore in a separate
  context and report summaries — keeps the main conversation clean. This is one
  of the most powerful tools since context is the constraint.
- **Resume/branch:** `claude --continue` / `--resume`, `/rename` sessions like
  branches (`oauth-migration`). Checkpoints persist across sessions.

## Let Claude interview you (big features)

"I want to build X. Interview me in detail using AskUserQuestion — technical
implementation, UI/UX, edge cases, tradeoffs. Keep going, then write SPEC.md."
Then start a FRESH session to execute the spec. Best specs are self-contained:
name the files/interfaces, state what's out of scope, end with an E2E check.

## Automate & scale

- **Headless:** `claude -p "prompt"` for CI/hooks/scripts;
  `--output-format json|stream-json --verbose`; `--allowedTools` to scope.
- **Parallel sessions:** worktrees, desktop app, web, agent teams. Fresh context
  improves review (unbiased). **Writer/Reviewer** and write-tests-then-code patterns.
- **Fan out:** loop `claude -p` over a task list; test on 2-3 first, then scale.
- **Auto mode** for unattended runs; **adversarial review** subagent on the diff
  in fresh context before "done" — but tell it to flag only correctness/requirement
  gaps (a reviewer asked for gaps always finds some -> over-engineering).

## Common failure patterns (recognize -> fix)

| Pattern | Fix |
|---|---|
| Kitchen-sink session (unrelated tasks pile up) | `/clear` between tasks |
| Correcting over and over | after 2 failed corrections, `/clear` + better prompt |
| Over-specified CLAUDE.md (rules get lost) | ruthlessly prune; convert to a hook |
| Trust-then-verify gap (plausible but wrong) | always provide a check; can't verify -> don't ship |
| Infinite exploration (reads 100s of files) | scope narrowly OR use a subagent |

## Develop intuition

These are starting points, not laws. Sometimes let context accumulate (deep in
one problem), skip planning (exploratory), or stay vague (want to see Claude's
read). Notice what worked when output was great and why it struggled when it wasn't.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
