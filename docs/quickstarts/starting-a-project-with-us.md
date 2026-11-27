# Starting a project with us (visiting account team)

For a team that arrives needing compute, access for its people and a progress page it can watch.

1. Compute and access are the operator's to grant: ask for a cluster context and a namespace; what you get is a
   kubeconfig the harness loads (`aws eks update-kubeconfig --name <cluster>` in the **tmux terminal** tile) and the
   **Headlamp** tile to watch it. A quota limit and a real capacity shortage look alike from a pending pod; Headlamp's
   node pages show which it is.
2. Your onboarding checklist is the goals file: the operator adds each step with `/agent/goals-add.sh` and the
   **Goals board** tile shows them move; you watch progress there without an account.
3. Your repositories live under `/wd/projects/` in the harness; the **Agent workspaces** tile is where the agent works
   on them, each change in its own git worktree, reviewed before it lands.
4. Questions go to the project's Slack channel when it is configured (`docs/slack/README.md`) or through the operator;
   a question is answered in its thread.

What you should see: a board with your checklist moving, a cluster view of your namespace, and the agent's changes as
reviewable commits.
