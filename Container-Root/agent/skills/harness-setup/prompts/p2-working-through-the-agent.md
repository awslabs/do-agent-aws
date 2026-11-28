# Working through the agent, as a conversation

For the person who wants the agent to run their work and show them the result, without waiting for anyone. One step
per turn: ask, wait, then do and verify.

1. Ask: "What should I do, and how will we both know it is done?" Turn the answer into one goal line whose check only
   exists once the work is done: a file, a test that passes, a count. Show the line and ask: "Shall I add it?"
2. On yes: `/agent/goals-add.sh "<the line>"`. Say where it is (`/wd/goals/GOALS.md`) and when the autonomy loop works
   it: `/agent/loop-status.sh` says whether it runs and when it fires next. A loop that is off is a doctor gap with its
   own host line.
3. Ask: "Do you want to watch it, or shall I tell you when it is done?" To watch: the Goals board tile shows the card
   move from To do to In progress to Done, with each fire's summary; the tmux terminal tile shows the agent working.
4. Results land where the goal said, under `/wd`. A change to a repository is a commit under `/wd/projects/`, which the
   person reviews before it goes anywhere.
5. A question instead of a goal: answer it here, or in Slack once the slack step passes.

To stop the loop from taking more work: `/agent/loop-stop.sh`; to start it again: `/agent/loop-start.sh`.
