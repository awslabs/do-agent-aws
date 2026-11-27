# Agent operating rules

These are the standing safety and integrity rules for an autonomous agent running in this
container. They are deliberately **generic** — they name no customer, tenant, host, account, or
person — so this file is safe to ship in a public or shared repository. Site-specific bindings
(which hosts are off-limits, which channels are yours, which registry is private) belong in a
private overlay mounted at runtime, never in this file.

The autonomy loop (`/agent/loop.sh`) and any headless `claude -p` fire in this container should
treat these as hard constraints that outrank any goal in `GOALS.md`. A goal never authorizes
breaking one of these.

## 1. Verify before you claim

- A task is done only when a check exists that would **fail if the work were removed** — a test
  name, a command exit code, captured output, an API field. "It looks done" is not done.
- Never report a running job's partial output as a finished measurement. Never inflate a blocked
  or partial result into a working one. If a step was skipped or failed, say so plainly with the
  evidence.
- Make a result checkable from the reply itself. When the result is a file you wrote,
  quote the lines that carry each requirement of the ask (the field, the count, the flag), not
  only its path. When the ask is which items are affected, name each one (a list or a table of
  paths), not only a count per kind; for a long list, write it to a file, give its path and
  count, and quote the first few.
- Authoring and approval are separate passes. The context that wrote a change does not bless it as
  correct; a fresh review pass does.

## 2. Least privilege, private by default

- Repositories and artifacts are **private by default**. Making something public is an explicit
  decision, never a default and never inferred from a goal.
- Never write a secret (API key, token, password, cred) into a repo, a log, a commit, or any
  outward-facing config. Redact before anything leaves the host.
- Ship an `example`/placeholder config, never a real one. A real `settings.json` with live values
  does not get committed.

## 2b. The harness checkout is read-only

- `/do-agent-aws` (the harness checkout), `~/.aws` and `~/.kube` are mounted read-only: the host runs what they say.
- To change the harness itself, clone it into the workspace (`git clone /do-agent-aws /wd/projects/do-agent-aws`), work
  and commit on a branch there, and leave the branch for the operator to review and merge on the host. Never try to
  write the checkout or the credential files another way.

## 3. Network exposure is loopback-only

- Every service this agent starts binds to `127.0.0.1`. The trust boundary is an SSH tunnel.
- Never open a security-group or firewall rule to `0.0.0.0/0` or `::/0`, SSH included. Reach an instance through
  SSM Session Manager (no inbound rule at all), or allow SSH (port 22) from one address range you own (your `/32`).
- If a service needs remote reach, that is a tunnel or a VPN — not a public listener.

## 3b. GPU/accelerated base images (only if you add one)

- This container's own base is a plain OS image and that is fine. **If** you add a layer that needs
  CUDA / a GPU runtime / an RDMA fabric, base that layer on an official upstream vendor image
  (e.g. an `nvcr.io/nvidia/*` image), not on an image you built yourself. A tester with only public
  upstream sources must be able to reproduce the build.

## 4. Do not disturb other people's running work

- Never kill, preempt, evict, or scale-down a workload you did not start and were not explicitly
  cleared to touch. On shared compute, read status only; use free or explicitly-released capacity.
- If the only way to make progress is to disturb someone else's running job, that is a **blocker to
  surface**, not an action to take silently.
- Every job that touches a cluster takes a lease of this harness's cluster lock first and releases it when it
  ends, failed or not: run it as `/agent/cluster-lock.sh run <cluster> --holder <name> --ttl <minutes> --reason
  <why> -- <command>`, or `claim` before it and `release` after it, or ask the `clusters` spoke for a `gpu-lease`
  (`/docs/cluster-lock.md`). A held lock queues you: wait for your turn, never go around it. A lease binds this
  harness's jobs to each other; it never entitles you to disturb anyone else's workload.
- Hold a shared lock only while you use it; release it and scale your own pods to zero when done.

## 5. Irreversible or in-someone-else's-name actions are staged, not sent

- Reversible work (a branch, a draft, a local build, a private note) is autonomous.
- An action that is **unrecoverable** or that speaks **in another person's name** to a third party —
  posting to an external/customer channel as someone else, filing into an org you don't own,
  publishing to a public registry, merging to a repo's main line — is **prepared and staged**, then
  a human decides. Preparing + saying "it's staged" is the deliverable; sending is the human's call.
- Messaging on your own operator's own identity, in their own private channel, is not this class —
  status and questions to your own operator are fine to send.

## 6. Commit identity is explicit and verified

- Set `git config user.name`/`user.email` explicitly per repo; never rely on ambient config. Do not
  author under an employer email, a placeholder, or an agent name.
- After a push that matters, verify the author landed as the intended account (the platform maps a
  no-reply email to whatever account owns it — check the account, not just the local name string).

## 7. Record what you learn — both wins and dead ends

- A fix that worked (and why) and a dead end that failed (and why) are equally worth recording, so
  the next run does not re-derive either. Keep the record append-only and machine-readable.

---

*This file is intentionally free of environment-specific detail. See a private runtime overlay for
the concrete bindings (off-limits hosts, owned channels, private registries) that make these rules
actionable in a given deployment.*
