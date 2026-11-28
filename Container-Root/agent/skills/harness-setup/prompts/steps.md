# The steps, in the doctor's order

Each section is one check: the one question to ask, what to do with the answer, and what to watch for. The exact host
lines and the verification come from `/agent/doctor.sh --check <id>`; print those, not lines of your own.
When the person's message already answers a section's question (they asked for Slack, or named a cluster, a
repository or a package), do not ask it again: take the section's first step in that turn. Walk the host steps one
per turn, and do not list the later ones ahead.

## bedrock
Ask only when the doctor reports a gap: "Is this harness on EC2 with an instance role, or on a machine where you use an
AWS profile?" Then print only that path's host lines. Model access is requested once per account, in the Bedrock
console of the region. A model id the doctor flags is fixed where it is configured: `settings.json` here is yours to
change (inside); `ANTHROPIC_MODEL` comes from `AGENT_MODEL` in the person's settings (host: `.env.local`; empty leaves
Claude Code its own Bedrock default, which the doctor names). PASS means the model answered with one token; the doctor
makes the call without the id's `[1m]` suffix, Claude Code's request for the 1M-token context window, and names the window.

## git-identity
Ask: "Which name and email should your commits carry?" With the answer, run the two `git config --global` lines for
this container now, then print the two `.env.local` lines with exactly that name and email, and
`./stop.sh && ./run.sh`. Until the restart, a commit here works; after it, the identity comes from `.env.local`. Verify after the restart:
`git var GIT_AUTHOR_IDENT` shows them and the check passes.

## eks
When the doctor found clusters, ask: "Which cluster should I connect to, read-only?" and name the ones it found. When
the person named one already, check it: `/agent/doctor.sh --check eks --cluster <name> --region <region>`. The owner's
walk-through is eks-access-entry.md beside this skill; follow it:
1. Write the kubeconfig into your own home, which this harness keeps under `wd/agent-state`: the doctor's
   `aws eks update-kubeconfig ... --kubeconfig ~/.kube/config` inside line. Then `kubectl auth can-i list pods -A`.
   When the doctor gives update-kubeconfig as a host line instead, print it with the other host lines, and say that it
   also makes the new context the current one.
2. Yes: read what is on it (`kubectl get namespaces`, `kubectl get pods -A`) and sum it up in a few lines: the
   namespaces, and how many pods run where. Nodes are outside the view policy: read them (`kubectl get nodes`) only
   when the doctor's line counts them.
3. No, or `Unauthorized`: that is expected until the host step is done. Print the doctor's host lines: the access entry
   with the read-only `AmazonEKSViewPolicy`, filled in for the identity the container calls AWS as; a cluster that still
   uses the aws-auth ConfigMap takes the commented alternative instead. The cluster's administrator runs them; then you
   check again.
4. `can-i` cannot reach the cluster at all (a timeout, no route): the endpoint is private and the container's network
   cannot reach it, a VPC question for the person, not an access entry. `can-i` says yes but a read fails: the API
   answered, so give the doctor's error as it is.
5. What is still missing for a readable cluster is in the doctor's line. Headlamp re-reads `~/.kube/config` every ten
   seconds and the doctor waits for that; a cluster it still does not list is yours to fix with the doctor's inside
   line, which restarts Headlamp. A kubeconfig that would be lost at the next restart needs the person's restart into
   this release, after which `~/.kube` is kept under `wd/agent-state`.

## slack
Ask: "Do you want me in Slack, and can you create an app in that workspace?" A person who asks for Slack has said yes.
No: mark it not needed. Yes: walk the host steps one at a time, one per turn, starting with step 1 in that turn:
1. Print slack-app-manifest.yaml beside this skill exactly as it is, comments included, in a yaml code block: do not
   edit it. It is read-only: the agent reads the channels the person names. chat:write is its one opt-in, commented in
   the file: tell the person to uncomment that line before pasting if they want the agent to answer in Slack threads,
   or to send a staged reply after their GO. Without it, ask them to also set `export SLACK_POST_ENABLED=false` in
   .env.local, so the agent never tries to post.
2. Install to Workspace and copy the Bot User OAuth Token (`xoxb-`); a user token (`xoxp-`) is refused, because it
   would post in a person's name.
3. Invite the bot to each channel it should read (`/invite @<the app's name>`); a channel's id is in its details.
4. Set `SLACK_BOT_TOKEN`, `SLACK_CHANNELS` and `SLACK_TEST_CHANNEL` (the doctor's host lines), then restart.
Verify with `/agent/slack-doctor.sh`: one row per check, and each gap says what to change. The doctor reports which
scope set the token carries. Only when the person asks, and in their own SLACK_TEST_CHANNEL, run
`/agent/slack-doctor.sh --post-test`, which posts two labelled messages and reads them back. Last, ask them to post
in a watched channel: the message reaches the agent's inbox, and with chat:write the agent answers in its thread.

## github
Ask: "Which repositories should I work on?" The doctor's host lines (`--repo <owner/name>` names one) describe a
fine-grained token for exactly those, exported as `GH_TOKEN` before `./run.sh`. Never ask for the token itself.
Verify: `gh auth status`, and `gh repo view <owner/name>` for each.

## memory
Usually nothing to ask: the default knowledge loads at the first start and is extracted with Bedrock within minutes.
A failed extraction is the bedrock step's problem: fix that first. Still extracting: say so and check again later.

## packages
A pack imported on the Knowledge transfer page counts: a loaded one reads `imported <name> <version> (<records> records,
loaded)` in the row (with another gap on the row, in its "the doctor checked" lines and `facts.packages`), and one the
loads have not taken is fixed by the row's inside lines (`/agent/loglearner-packs.sh`, then
`python3 /agent/knowledge-transfer.py load`), not by a CLAUDE.md block. Ask "Do you have a shared knowledge package to
load? Which repository?" only when the row shows no package at all. None: mark it not needed. With the github check
passing for that repository:
1. `gh repo clone <owner>/<name> /wd/knowledge/<name>`.
2. Read its `INSTRUCTIONS.md` (or `README.md`) and run each step's in-container form yourself: a step written as
   `docker exec <container> <command>` is `<command>` here; a `docker cp` into the container is not needed, the files
   are already here; the host path of the harness's `/wd` is `/wd`. A step with no in-container form is a host line for
   the person.
3. Add a package's goals to the goals file only when the person asks for that one goal: every goal there is work the
   autonomy loop then does unattended.
4. Run the package's own checks, then `/agent/doctor.sh --check packages` (its banks hold documents, and `/wd/CLAUDE.md`
   says where the package is).

## spokes
The doctor's row names the spokes the agent stack starts (clusters, conversations, insights, sessions and loops are on
by default; example is off) and whether each one's session is live; conversations waits for Slack until its settings
are set. To turn one off, set SPOKE_<NAME>=false in .env.local, then ./stop.sh && ./run.sh. That is the person's
host step. For a tile, answer from the doctor's row, without searching the harness's scripts:
- the tile's flag is off: that is why it is grey; print the doctor's host lines that turn it on;
- the UI is on but not up: its dot is red, not grey; run the doctor's inside line (`/agent/ui-start.sh` starts what
  is not running) and check again;
- the doctor finds it up, yet the person sees it grey: the page they look at is not this container's. A grey
  tmux-agent tile that says it has no install source comes from an older image, and the host lines are `git pull`,
  `./build.sh` and `./stop.sh && ./run.sh`; a tile still saying "checking" is a tab opened before the last start:
  reload it. Ask which words the grey tile shows when that decides between the two.

## docker
The doctor's row says whether images can be built here: the BuildKit daemon answers, the stack's registry answers and
the disk has headroom. Ask nothing when it passes; a person who wants to build an image says so. On a gap, print the
doctor's host lines: the daemon and the registry are two sidecar containers that `./run.sh` starts on the host
(`./docker.sh status` shows them), and the agent never starts, stops or reaches them any other way. Never offer a
Docker socket, a docker CLI or a cloud build service instead; a push outside the stack is the person's step.
