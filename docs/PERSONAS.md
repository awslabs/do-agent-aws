# do-agent-aws: who uses it, and what the docs must cover for each

Seven kinds of people the harness serves, each with the jobs they come for, what they use today, the surfaces the
harness gives them, what is still missing, and the quickstart written for them.

| # | Persona | One-line need |
|---|---|---|
| P1 | GPU cluster co-tenant | "Can I use the cluster now without breaking someone's run?" |
| P2 | Workstream collaborator | "Run my experiment and show me the result, without waiting for the owner." |
| P3 | Owner / operator | "Run many agent lanes alone; approve, gate and report once." |
| P4 | Manager / leader | "What moved this week, and what's the impact?" |
| P5 | External partner engineer | "Show me the problem and fix ledger for our project, and nothing else." |
| P6 | Visiting account team | "We need compute, access for our team, and a progress page we can watch." |
| P7 | Colleague installing their own | "Get this running on my machine today." |

## P1. GPU cluster co-tenant

- **Jobs:** check whether a cluster is free; claim, queue, extend or release it; see per-namespace GPU use.
- **Today:** lock files and a who-uses-what dashboard. Stale locks dominate, real queueing rarely happens, and a lock holder is recorded as a session or host, not a person.
- **Harness surfaces:** Headlamp, tmux monitors.
- **Gaps:** locks tied to people; a queue with "notify me when it's free"; reservations; reclaiming stale locks automatically.
- **Doc:** *Sharing a cluster.* Lock commands, queue and extend etiquette, reading tenant use in Headlamp, and "requested GPUs ≠ GPUs in use".
- **Quickstart:** [quickstarts/sharing-a-cluster.md](quickstarts/sharing-a-cluster.md)

## P2. Workstream collaborator (co-develops with the owner, drives experiments through the agent)

- **Jobs:** send run requests ("cluster has N nodes, run the sweep"); get charts back; review PRs; ask status questions.
- **Today:** messages to a dedicated supervisor loop that acknowledges each request and relays it to the owner: execution requests, questions and commitment asks, about status, compute, reports and charts, and pull requests. Giving a collaborator their own boards and memory takes a hand-built export to a separate repository, and adding them as a user is a manual step.
- **Harness surfaces:** Goals board, Project board (Plane; opt-in, off by default), Agent workspaces, memory, Conversations.
- **Gaps:** **per-user identity**, private boards and memory, self-serve request intake, and run status visible without the owner.
- **Doc:** *Working through the agent.* Request format, what the acknowledgement promises, where results land, the PR flow.
- **Quickstart:** [quickstarts/working-through-the-agent.md](quickstarts/working-through-the-agent.md)

## P3. Owner / operator

- **Jobs:** approve capacity use, gate external posts, consolidate status, onboard people, keep things private.
- **Today:** privacy and redaction asks, leadership reports, compute asks and status reports, all routed through one person.
- **Gaps:** delegating approvals and roles; one fleet-wide status view; an audit trail.
- **Doc:** *Operating the fleet.* Approval gates, the external-post GO, monitors and recovery.
- **Quickstart:** [quickstarts/operating-the-fleet.md](quickstarts/operating-the-fleet.md)

## P4. Manager / leader (status consumer)

- **Jobs:** half-year impact summaries, project status, success stories, and honest PR and merge counts.
- **Today:** reports compiled by hand from several agent sessions and cross-checked.
- **Gaps:** a generated, exportable **status digest** (weekly or half-year) from the boards, goals and PRs; a read-only link.
- **Doc:** *Reading status.* Where the digest is and how often it's made; what "merged" vs "in review" means.
- **Quickstart:** [quickstarts/reading-status.md](quickstarts/reading-status.md)

## P5. External partner engineer (vendor co-debugging)

- **Jobs:** read the problem and fix ledger, follow upstream PRs, get reproductions.
- **Today:** a shared channel plus private write-ups. External posts need the owner's explicit GO because they can't be taken back.
- **Gaps:** **redacted, external-safe views**; access scoped to one project.
- **Doc:** *Partner view.* What's shared, how redaction works, how to file and track a problem.
- **Quickstart:** [quickstarts/partner-view.md](quickstarts/partner-view.md)

## P6. Visiting account team (arrives needing support on a project)

- **Jobs:** ask for compute, get their team added, follow a POC board, receive a handoff guide.
- **Today:** POCs set up by script (one board and a private repository per POC) and a capacity playbook; idle devices can go unnoticed during a capacity ask.
- **Gaps:** a **compute request → allocation** flow; **team onboarding in one step** (board + repo + memory slice + access); a per-project read-only portal.
- **Doc:** *Starting a project with us.* How to ask for compute, the onboarding checklist, where progress shows, quota limit vs real capacity shortage.
- **Quickstart:** [quickstarts/starting-a-project-with-us.md](quickstarts/starting-a-project-with-us.md)

## P7. Colleague installing their own harness

- **Jobs:** reproduce the setup on their own OS.
- **Today:** paste-in prompts and long per-platform guides, which go stale.
- **Gaps:** a versioned install per OS; the build's preflight, the `doctor` check and the quickstart below cover part of it.
- **Doc:** *Install your own.* Prerequisites, credentials two ways, wiring, `doctor`, the common traps.
- **Quickstart:** [quickstarts/install-your-own.md](quickstarts/install-your-own.md)

## Cross-cutting needs, ranked (for the roadmap)

1. **Multi-user identity, roles and access.** Today: a single operator on 127.0.0.1 over an SSH tunnel, and no user model. This blocks P2, P5 and P6.
2. **Compute request and allocation.** Locks and leases tied to people, a queue, reservations, and reclaim of stale locks.
3. **Manager status digest.** Generated from boards, goals and PRs; exported to markdown or PDF.
4. **Team onboarding template.** Board + private repo + memory slice + invite, replacing the hand-built exports.
5. **External-safe sharing.** Redaction profiles and scoped read-only links.
6. **Audit.** Who asked, who approved, what was posted, who held which GPUs.
7. **Request intake with acknowledgement.** Not a relay through one person.
