---
name: harness-setup
description: Walk the person through finishing the setup of this do-agent-aws harness, one step at a time - Bedrock, git identity, an EKS cluster, Slack, GitHub, memory, a shared knowledge package, the tmux-agent dashboard and the other home-page tiles. Use it for /setup and "help me finish setting up", for "what's working" or "what do I still need to set up", to set a git identity that survives restarts, to connect Slack, an EKS cluster or GitHub, to load a shared knowledge package, when a home-page tile is grey or red, and for the quickstarts on working through the agent, starting a project with us, or installing your own harness.
allowed-tools:
  - Read(~/.claude/skills/harness-setup/**)
  - Bash(/agent/doctor.sh *)
  - Bash(git var GIT_AUTHOR_IDENT)
  - Bash(git config --global user.name *)
  - Bash(git config --global user.email *)
  - Bash(aws sts get-caller-identity *)
  - Bash(aws eks list-clusters *)
  - Bash(aws eks describe-cluster *)
  - Bash(aws eks update-kubeconfig *)
  - Bash(kubectl auth can-i *)
  - Bash(kubectl config get-contexts *)
  - Bash(kubectl config current-context)
  - Bash(kubectl get nodes)
  - Bash(kubectl get namespaces)
  - Bash(kubectl get pods -A)
  - Bash(kubectl get pods --all-namespaces)
  - Bash(kubectl get deployments -A)
  - Bash(gh auth status *)
  - Bash(gh repo view *)
  - Bash(/agent/ui-status.sh)
  - Bash(/agent/slack-status.sh)
  - Bash(/agent/slack-chat-status.sh)
  - Bash(/agent/slack-doctor.sh)
  - Bash(/agent/hindsight-seed.sh --status)
  - Bash(/agent/loop-status.sh)
---

# Finish setting up the harness: the doctor's gaps, one at a time

You run inside the harness container. The person's settings live on the host: in the checkout's `.env.local` (their
own settings over the defaults in `.env`), in `~/.aws` and in `~/.kube`. You do not edit them, and you cannot restart
your own container. So every step has two halves: what you do now, inside the container, and the exact lines the
person runs on the host. Then you verify both. `/agent/doctor.sh` knows both halves for every check; you never invent
a host line it did not give.

## The first turn: under 20 lines
1. Run `/agent/doctor.sh --brief`. It exits 1 when it finds gaps: that is its answer, not an error, so do not mention
   it. Show its table in a code block, as printed, but without its last line ("next: ..."): step 2 replaces it.
2. Then one line of at most 76 characters: how many checks are ready and which gap comes first, with no reasons (the
   table has them). The agent's pane is 80 columns wide until a browser attaches, and a longer line wraps.
3. Then that gap's one question exactly as prompts/steps.md words it (the section named after the check), adding
   nothing, and stop.
Do not list the other gaps' steps, paste documentation, or start two steps at once. When the person asked about one
thing (a cluster, Slack, a tile), start with that check instead: `/agent/doctor.sh --check <id>`.

## Every step after that
1. Run `/agent/doctor.sh --check <id>` (with `--cluster <name> --region <region>`, `--repo <owner/name>` or `--model <id>`
   when the person named one) and use what it prints.
2. Do the "agent does now" lines yourself, after the person's answer when they need one (a name, a cluster, a
   repository). Say what you did and what it changes: "this container, until the next restart" where that is so.
3. Print the "you run on the host" lines exactly, in one `sh` code block, filled in with what the person told you.
4. Ask the person to run them and to tell you when they are done. One question; stop.
5. When they answer, run `/agent/doctor.sh --check <id>` again, and its verify lines. PASS: say so, and go to the next
   gap with its one question. Still a gap: say what is still missing in the doctor's words, and repeat 3 and 4.

A person who does not need a step (no Slack, no cluster, no shared package) says so: run
`/agent/doctor.sh --not-needed <id>` and move on. A question asked in the middle is answered first. A line marked
"input pending" is not in this release yet: say so plainly and give the rest of the step.

## Never
- edit `.env.local`, `.env`, `~/.aws` or `~/.kube` on the host, or say you did; restart the container; run `./stop.sh` or `./run.sh`;
- run a line the doctor gives under "you run on the host": those lines are the person's to run;
- answer a menu or a permission prompt for the person, or type into another session;
- post to Slack: `/agent/slack-doctor.sh --post-test` is the person's explicit choice, in their own SLACK_TEST_CHANNEL;
- write to a cluster: read with `kubectl get` and `kubectl auth can-i`, and never read secrets;
- print a token, a key or a password, or ask the person to paste one: say "set", or its length.

## The files beside this skill
- [prompts/steps.md](prompts/steps.md): for each check, its one question and what to do with the answer.
- [prompts/p2-working-through-the-agent.md](prompts/p2-working-through-the-agent.md),
  [prompts/p6-starting-a-project-with-us.md](prompts/p6-starting-a-project-with-us.md) and
  [prompts/p7-install-your-own.md](prompts/p7-install-your-own.md): the quickstarts as conversations, for "how do I work
  through the agent", "we are starting a project with you" and "how do I install my own". Follow one, one step and one
  question per turn, with the doctor for anything it checks.
- [slack-app-manifest.yaml](slack-app-manifest.yaml): the Slack app's manifest, printed in the slack step.
- [eks-access-entry.md](eks-access-entry.md): read-only cluster access for the container's role, in the eks step.
