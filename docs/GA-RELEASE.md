# do-agent-aws GA release

Status: **not shippable yet** (2026-10-13). Main is at the merge of PR #31. The blocking work is listed under
"Open blockers" below, and every item has a command that fails while the property is missing.

## 1. What GA means

A new user clones the repository, follows only the README, and can run do-agent-aws end to end and verify it:

- every UI on the home page runs and can do real work, at as much parity as possible with the reference deployment;
- the agent does real work without Slack, and that work is visible in the loop page, the board, memory and the
  session viewer;
- nothing leaves the host that the user did not send, and no internal name ships in the tree, the image or the commit
  messages.

GA is reached when all four hold:

1. Every GA-required PR below is merged in order.
2. Every acceptance item in section 3 passes on the merged main.
3. Two consecutive clone-and-go runs pass with zero P0 and zero P1 findings, each on a brand-new EC2 instance and in a
   Docker-in-Docker client (section 5).
4. Each change carries an independent review approval at the head that merges, plus a second review by a different
   model.

Severity follows the clone-and-go plan. **P0:** a README-only user is blocked, or something leaks. **P1:** a check
fails, or the user needs an undocumented step. **P2:** polish.

## 2. Merge order

This order is a proposal; the maintainer decides the final order. Merge top to bottom. Before each merge, re-check
the next branch against the new main (`git merge-tree` reports no conflict) and re-run `./build.sh && ./test.sh`. The
order of #30 to #36 has not been checked for conflicts between the PRs yet.

| # | PR | What it does | GA | State on 2026-10-13 |
|---|---|---|---|---|
| 1 | #31 | Out of the box: one memory store with its hooks, a default knowledge seed, every UI on the home page, the tmux-agent dashboard | required | **merged** 2026-10-13 11:57Z |
| 2 | #30 | A failed install or test fails `build.sh` / `test.sh`; compose and Kubernetes renders validate | required | open, being rebased onto main |
| 3 | #32 | Read-only `~/.aws` and `~/.kube` in the test container; README note on the LogLearner index | post-GA | open, in review |
| 4 | #33 | A memory API that cannot reach Bedrock is reported: one WARNING, an amber tile, `ui-status.sh` rc 1 | required | open, in review |
| 5 | #35 | Quickstart preflight (Docker, buildx, docker group, 30 GB free), README prerequisites, two credential paths, mounts only when present | required | open, in review |
| 6 | #36 | LogLearner tree scan and build gate, LogLearner 0.1.5 vendored unedited, the home page's loop-registry text reworded | required | draft until its gate passes with 0 findings |
| 7 | #34 | Fresh-deploy proof tool, host-neutral | post-GA | open, not yet reviewed |

Then the stacked series, one PR each, in this order (PR numbers are assigned when they open):

| # | Branch | What it does | GA |
|---|---|---|---|
| 8 | `feat/agent-learning-cli-and-terminal` | Recall and learn commands over layered memory banks, a LogLearner hook on Edit/Write/Bash, the Learned rules tile, the terminal opens at Claude's prompt, GitHub plugin only with a token, context7 opt-in, the session viewer link | required |
| 9 | `feat/kanban-self-hosted` | A self-hosted kanban board that opens signed in; the runner on its workspaces view with analytics off; loop fires mirrored to cards with credentials masked | required |
| 10 | `feat/plane-board` | A Plane board that opens signed in on a seeded project; a status-only probe | required |
| 11 | `test/hermetic-and-live-slack` | Slack doctor, a hermetic E2E kit and CI with named expected failures that cite public engine issues | required |
| 12 | `fix/sandbox-current-main` | The Docker sandbox kit re-proven on current main | post-GA |
| 13 | `fix/comms-out-of-the-box-a` | Comms watcher on by default, the engine pinned to its current main, the bot token off the command line | required |
| 14 | comms posting fixes | Exactly one post per reply, no stall on a broadcast, four smaller safety fixes | required |
| 15 | agent loop page | The agent loop page and the fleet tree (operator, loop, fire); replaces the grey Loop Deck tile | required |
| 16 | agent chat page | Talk to the agent without Slack; same-origin POST only; literal text | required |
| 17 | failure-derived knowledge v2 | Knowledge derived from real failures, a backtest, a home-page panel rendered from the results | post-GA |
| 18 | `docs/guides/kanban-coding.md` | A guide to coding with the kanban board, with seven evaluation criteria | post-GA |

Not in this release: inter-agent messaging (a spec exists) and a shared team knowledge fabric (a spec is being
written).

## 3. Acceptance checklist

Run on a fresh clone of the merged main with the default `.env`. The container is `do-agent-aws` and the home page is
`http://localhost:8000`. Each item names the control that must make it fail; a check that cannot fail is not a check.
"Main today" is main at the PR #31 merge, measured on 2026-10-13.

| # | Property | Command and expected result | Must fail when | Answered by | Main today |
|---|---|---|---|---|---|
| 1 | The build tells a README-only user what is missing | On Ubuntu 24.04 with only `docker.io`: `./build.sh` exits 1, names `docker-buildx` and the install command, and builds nothing | buildx installed: the build proceeds | #35 | FAIL (exit 125, "unknown flag: --progress") |
| 2 | Build and suite | `./build.sh && ./test.sh`: build rc 0; the suite prints 0 `not ok` and nothing skipped | a planted install failure gives build rc 1 | #30 | PASS (180 ok); the failure path needs #30 |
| 3 | One loopback port | `docker port do-agent-aws` prints exactly `8000/tcp -> 127.0.0.1:8000` | `UI_PUBLISH_DIRECT_PORTS=true` adds mappings | #31 | PASS |
| 4 | Every tile green within 120 s, none grey | `./run.sh`, then `docker exec do-agent-aws /agent/ui-status.sh; echo rc=$?`: rc 0, every dot green | any UI flag off greys a tile | #31, agent loop page | FAIL (the Loop Deck tile is grey) |
| 5 | Every tile link works on its own host | follow each tile link with redirects (`curl -sL -o /dev/null -w '%{http_code}'`, Host kept): 200, no hop to another port | a removed route | #31 | PASS (10 of 10) |
| 6 | Tiles open in new tabs | every tile anchor on the home page has `target="_blank"`, with `rel="opener"` on the harness's own UIs and the agents (the home badge returns to the tab that opened it) and `rel="noopener noreferrer"` on an external site | the attribute removed | #31 | PASS |
| 7 | A green dot means the backend works | stop a backing service (the memory API, LogLearner, the session viewer, the board): its dot turns red within one 15 s sweep; `docker exec do-agent-aws /agent/ui-start.sh` restores green | the probe replaced by a page-only check | #31 | PASS for the shipped UIs |
| 8 | The terminal opens at Claude's prompt | on a fresh state (`./stop.sh`, move `wd/` aside, `./run.sh`) the terminal page shows the prompt and none of "Choose the text style", "Security notes", "trust this folder" | the first-run answers removed | agent learning branch | FAIL (three first-run screens; trust defaults to "No, exit") |
| 9 | Default knowledge, kept across restarts | the memory UI lists the three seed banks with their counts; `./stop.sh && ./run.sh` keeps the counts, and the log says the seed is already there and nothing was posted | an empty pack, or random document ids (the count grows) | #31 | PASS |
| 10 | Memory failure is visible | start with no AWS credentials, and again with a model Bedrock refuses: one WARNING in `docker logs do-agent-aws`, an amber memory tile, `ui-status.sh` rc 1; fix and restart: clear | the extraction watch removed | #33 | FAIL (all green, memory silently empty) |
| 11 | The agent's own memory shows | after one goal, the agent's bank shows at least one fact in the memory UI | the hooks removed | #31 | PASS |
| 12 | Real work without Slack, visible everywhere | give one goal with `/agent/goals-add.sh` and start with `/agent/loop-start.sh` (or the chat page): done in one fire; it shows on the agent loop page within 30 s, its kanban card reaches Done, the memory bank gains a fact, the session viewer lists it | `AUTONOMY_LOOP=false` and no start: no fire | agent loop page, kanban, chat page | FAIL (only the loop log and the memory show it) |
| 13 | The kanban board | from its tile: one click, a new tab, no password, no cloud sign-in, four columns, no welcome modal, no console 401; the runner opens on its workspaces view | the local login enforced: a password form | kanban branch | FAIL (welcome modal and a 401) |
| 14 | The Plane board | from its tile: one click, a new tab, signed in, the agent's project with at least one card from a goal | the session cleared: the login form | Plane branch | FAIL (no tile) |
| 15 | Comms work by default | the comms page reports the watcher running; in demo mode a staged reply sent from the compose form marks the demo ask answered (Unanswered 1 to 0); with Slack, one reply makes exactly one post | `COMMS_WATCH_ENABLED=false`; a top-level reply stays unanswered | comms branches | FAIL (`COMMS_WATCH_ENABLED=false` by default) |
| 16 | The fleet dashboard sees the agent | the tmux-agent dashboard lists the agent session as process claude with a profile and an owner, not orphaned | the old bash wrapper | agent learning branch | lists the session; classification FAIL |
| 17 | LogLearner and Learned rules | every LogLearner page loads with its knowledge populated; the Learned rules page shows the pack's record count and learnings per category | an empty pack | #31, agent learning branch | LogLearner PASS; no Learned rules page |
| 18 | Chat without Slack | text typed on the chat page reaches the agent verbatim and the reply shows; a cross-origin POST is refused | the origin check removed | chat page | FAIL (no page) |
| 19 | Nothing leaves the host | a browser DevTools network capture across every UI shows zero requests to a non-loopback origin | the old kanban runner (it sends error telemetry off-host) | kanban branch | FAIL |
| 20 | No internal names ship | `scan.py --tree` (added by #36) reports 0 findings over the tree; the same scan over the image and over the commit messages of the merged range reports 0 | a planted name makes the build fail | #36, every branch | FAIL (an internal identifier in the vendored LogLearner) |

## 4. Open blockers, known gaps and decisions

**Open blockers (GA waits on these):**

- Clone-and-go run 1 failed in both environments (section 5). Its P0 and P1 findings are answered by #33, #35, #36 and
  the agent learning branch; run 2 starts when those land.
- The second-model review found five P1 blockers in the stacked series. Each has a reproduction, and each fix needs
  its control to fail first:
  - the agent learning branch copies trusted default knowledge into a tree a fire can write, with no integrity check
    before the next fire;
  - the kanban branch's sync and sign-in helpers forward the session token across a cross-host redirect;
  - the Plane branch writes transcript secrets into a comment, a description and saved state, and forwards the API key
    across a redirect;
  - the E2E kit's verdict could pass an empty, clone-only or unknown-status report (a fix is committed; its re-review
    is pending).
- Commit messages in the stacked branches still name internal workstreams. They are reworded before their PRs open.
- Three acceptance checks are specified but not implemented yet: the agent answers three questions only the knowledge
  pack can answer, and scores higher with the pack than without; a thread reply in comms demo mode is listed and the
  UI count equals the journal; a loop fire shows in the fleet dashboard within 30 s.

**Known gaps, after GA:**

- #32 (read-only credentials in tests) and #34 (the proof tool) can merge any time; GA does not wait for them.
- UX review findings so far: the terminal's cheatsheet is squeezed on a phone, the terminal page has no home link, and
  the home label on proxied pages is ambiguous.
- LogLearner dashboard formatting ships through LogLearner's own releases and is vendored unedited.
- LogLearner 0.1.5 renders each rule's version scope. It becomes a GA item only if the knowledge backtest shows the
  scoped rules change outcomes.
- Failure-derived knowledge v2, the kanban coding guide, inter-agent messaging and a shared team knowledge fabric.

**Decisions for the maintainer:**

| Decision | Options and cost | Default until decided |
|---|---|---|
| The image's `LABEL MAINTAINER` default | decided: the maintaining GitHub team, `awslabs/aws-do-framework` (https://github.com/orgs/awslabs/teams/aws-do-framework), no personal names or addresses; `build.sh` sets the label to the builder's user name | decided |
| Repository visibility | private: GA for invited users, no extra gate. Public: needs the privacy scan clean over the whole history, a license review and a history secret scan first | private |
| Comms direct auto-post | confirm: refused by configuration, and the UI only stages a reply that a person sends. Change: a new design and review, not in this release | refused |
| The kanban runner's terms | confirm: the user accepts them on first open (one extra click). Pre-accept: accepts third-party terms on the user's behalf, not recommended | never pre-accepted |

## 5. Verification record

| When (UTC) | What | Result |
|---|---|---|
| 2026-10-13 00:38-02:10 | Parity audit of main `3defadd` against the reference deployment, plus a fresh-machine Docker-in-Docker harness run | 12 PASS, 17 FAIL; the 27 acceptance rows behind section 3 |
| 2026-10-13, to 11:50 | Independent review of PR #31 | first round REQUEST-CHANGES (the build could not fail on the new installer checks; the memory dot stayed green with its store down); final APPROVE-WITH-NITS at `3640780`; full suite 16 of 16 scripts, 180 ok; planted controls failed as required |
| 2026-10-13 11:57 | PR #31 merged | main `44f7bc9` (same tree as `3640780`) |
| 2026-10-13 11:59-13:04 | Clone-and-go run 1, environment A: a brand-new m8i.2xlarge from the stock Ubuntu 24.04 image, a Bedrock-only instance role | **FAIL**: 2 P0, 4 P1, 4 P2. Checks 2-6 and 8 pass; clone to all tiles green in 11 min 27 s after undocumented steps; `./test.sh` 180 ok; instance terminated |
| 2026-10-13 | Clone-and-go run 1, environment B: `docker:dind` with a clean `ubuntu:24.04` client | **FAIL**: 2 P0 plus the shared buildx P0, 5 P1, 9 P2. Checks 2-6 and 8 pass; `./test.sh` 180 ok; host returned to its baseline |
| 2026-10-13 13:36 | Clone-and-go of the stacked series by a second model, on a clean Ubuntu 24.04 host with Docker 29.1.3 | reproduced the buildx P0; found that the Plane test needs host python3; found internal names in commit messages |
| 2026-10-13 13:10-14:00 | Second-model review of the stacked series | 5 P1 blockers in four branches; the sandbox branch approved |
| 2026-10-13 | Independent branch reviews | kanban, Plane and sandbox: APPROVE-WITH-NITS; E2E kit: APPROVE-WITH-NITS, re-review of its verdict fix pending; agent learning: REQUEST-CHANGES (four should-fix items); comms: REQUEST-CHANGES (two blockers), its fix branch awaits re-review; #32, #33 and #35: grading in progress |

GA is declared only when section 3 passes on the merged main and two consecutive clean clone-and-go runs follow it.
Each later run is appended to this table with its date, head and result.
