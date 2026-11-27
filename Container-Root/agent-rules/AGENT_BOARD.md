# The boards: track work, or give the autonomy loop a goal

Use `/agent/board.sh` for every board read or write; it runs without a permission prompt. Two writes look alike and
are not the same - pick the one that matches what you were asked:

| You were asked to | Run | What happens |
|---|---|---|
| put something on the board, track it, record a task, a plan step, a finding | `/agent/board.sh create "<title>" [--note "<text>"]` | a Plane work item in Todo that is **not a goal**: nobody works on it until someone does |
| have the autonomy loop do it, unattended | `/agent/board.sh create --goal "<goal with a checkable DONE condition>"` | a goal in the goals file (through `/agent/goals-add.sh`): the loop starts working on it at its next fire |
| see the goals and the tracked work | `/agent/board.sh list` | the goals G1, G2, ... with their work items and states, then the tracked work items |
| move tracked work | `/agent/board.sh move AGENT-12 "In Progress"` | Backlog, Todo, In Progress, In Review, Done or Cancelled |
| mark a goal done or open again | `/agent/board.sh move G2 done` (or `open`) | its checkbox in the goals file, then its work item |
| comment on a goal or on tracked work | `/agent/board.sh comment AGENT-12 "<text>"` | a comment on the work item, secrets masked |

"Put these tasks on the board" means **track**: do not turn them into goals unless the user asks for the loop to
work on them. Tracked work lives on the Plane board only. The Goals board (vibe-kanban) shows the goals: its sync is
two-way, so every card on it is a goal the loop works on, and it follows the goals file within its sync interval. A goal's other states (In Progress, In Review) belong to the loop's fires; `board.sh` refuses them.
While a fire runs, the goals file is that fire's: `board.sh` refuses a goal's done mark from anywhere else (exit 5,
try again when it ends). A fire marks its own goal done in the goals file, as its prompt says, or with
`board.sh move G<n> done`.

Do not write the boards any other way: no edits to `/agent/plane-sync.py`, its state file or the board's secrets, and
no calls to the board's API of your own. The goals file is the source of truth for the goals; the mirror moves a
goal's work item back to the file's state on the next sync, so a direct change does not stick. Without a Plane board
(it is optional and off by default, `UI_PLANE=false`; or not on this target: no `PLANE_URL`), `board.sh` lists and changes
the goals only and says so.
