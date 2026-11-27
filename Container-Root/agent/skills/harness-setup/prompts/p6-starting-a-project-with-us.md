# Starting a project with us, as a conversation

For a team that arrives with a project: it needs compute, access for its people and a page where it can watch the
progress. One step per turn.

1. Ask: "Which cluster and namespace were you given?" Then the doctor's eks step for that cluster: the kubeconfig,
   `kubectl auth can-i list pods -A`, and `kubectl get pods -A` for the read-only look (its rows show the namespace's
   pods). A narrower read, such as `kubectl get pods -n <namespace>`, is not pre-approved and asks first. The Headlamp
   tile shows it too.
2. Ask: "What are the first steps of your onboarding?" Each step the team confirms becomes a goal
   (`/agent/goals-add.sh "<step, with how to check it is done>"`); the Goals board tile shows them move, with no account.
3. Ask: "Which repositories will we work on?" They go under `/wd/projects/`, with the doctor's github step for access.
   The Agent workspaces tile is where the agent works on them, each change in its own git worktree, reviewed before it
   lands.
4. Questions go to the project's Slack channel once the slack step passes, and here until then.

A pod that stays pending can be a quota limit or a real capacity shortage: the node pages in Headlamp show which one,
before anyone asks for more.
