# Tile names

The names a new user sees on the home page, after the UI/UX review of 2026-10-13 (naming suggestions N1 to N9). A
tile is named for what the user gets; the product behind it stays in the purpose line or the README's table.

| # | Was | Now | Where | Why |
|---|---|---|---|---|
| N2 | vibe-kanban (the runner's workspaces) | **Agent workspaces** | this change (main's tile); the integration stack's "Worktree agent runner" tile takes the same name | users think "a workspace for an agent", not "worktree runner" |
| N4 | LogLearner dashboard | **Session insights** (LogLearner in the purpose) | this change | says what the user gets |
| N5 | Hindsight memory UI + Hindsight API docs | **Memory**, one tile; the API docs are a link in its note | this change | two tiles for one service |
| N6 | claude-mem viewer | **Session memory** | this change | next to Memory, the difference is session-level capture |
| N7 | Comms UI | **Conversations** (Comms UI in the purpose) | this change | matches its subtitle: what needs a human |
| N1 | Goals board tile; "Issue", "New Issue", `BBA-n` inside | keep **Goals board**; in-app "Issue" -> **Goal**, keys `GOAL-n` | the integration stack (the board is not on main) | one noun end to end |
| N3 | Meta Learner (LogLearner's /learnings) | **Learned rules**, or a tab of Session insights | the integration stack | it is LogLearner's rules page, not a separate learner |
| N8 | Plane board, next to Goals board | **Project board (Plane)** | the board's change (its tile lands with it) | two boards confuse; say which is for what |
| N9 | project `<container>-do-agent-aws` on the board | the repository name | the integration stack (`kanban-sync.py`) | see the review's G5 |

Unchanged: Guide, Headlamp, tmux terminal, tmux cheatsheet, tmux-agent dashboard, Loop Deck (grey, with its reason).

Names elsewhere are unchanged on purpose: `.env` flags (`UI_HINDSIGHT`, `UI_VIBE_KANBAN`, `COMMS_UI_ENABLED`, ...),
the scripts (`comms-ui-start.sh`, `loglearner-serve.sh`, ...), the hostnames (`hindsight.localhost`, `kanban.localhost`,
`claude-mem.localhost`, `loglearner.localhost`) and the README sections that document each product. Anything that
reads the home page by tile title (test16's live-title list, an end-to-end kit) reads the new names.
