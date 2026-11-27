# Working through the agent (workstream collaborator)

For the person who drives experiments through the agent: "run my sweep and show me the result, without waiting for the
owner." Your requests become goals; the autonomy loop works them one fire at a time and reports on the board.

1. State the goal as an outcome with a check that only exists once the work is done: in the terminal,
   `/agent/goals-add.sh "Run the sweep on 2 nodes - DONE when results/sweep.csv exists with 10 rows"`. The goal is one
   line in `/wd/goals/GOALS.md`; the loop fires on it at its next interval (`/agent/loop-status.sh` says when).
2. Watch it: the **Goals board** tile shows the goal as a card moving To do -> In progress -> Done, with the fire's
   summary in the description; the **tmux terminal** tile shows the agent working.
3. Results land where the goal said (under `/wd`, the shared workspace); a change to a repository is a commit in the
   agent's worktree under `/wd/projects/`, which you review before it goes anywhere.
4. Ask a question instead of a goal through the **Agent chat** tile, or in Slack when it is configured
   (`docs/slack/README.md`): a question is answered in its thread, a goal-shaped message is added to the goals file.
5. Stop the loop from working on more: `/agent/loop-stop.sh`; start it again with `/agent/loop-start.sh`.

What you should see: your goal's card reaches Done with a "Last fire" summary, and the file or result it named exists.
