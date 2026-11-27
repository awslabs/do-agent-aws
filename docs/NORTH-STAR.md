# North Star

A new user clones do-agent-aws, runs ./build.sh and ./run.sh, and gets a running multi-agent harness that does real work and shows it - with nothing undocumented and nothing leaking.

That sentence is the one goal every part of this repository serves: the harness UIs, the autonomy loop, the memory, the
boards, the tests. The four goals the README lists (self-improvement, autonomy, code writing, knowledge gathering) are the
capabilities; the North Star is what a person must be able to do with them, written so that it can be checked.

## The rule

A row counts only when a tracked check exists that FAILS if the property is removed. A green run proves the check; the check proves the property.

So every row below names its check: the command that goes red when the property is taken away. A row without such a
check is scored **NO**, whatever the code looks like. The home page carries this register in its "North Star" section,
rendered from the same file as this table (`docs/north-star.json`), and `Container-Root/test-board.sh` fails when the
page, this document and that file disagree. `Container-Root/test-north-star.sh` holds the register to its own rule: a
verdict with no check, a check that names no file or one the repository does not have, this document saying what the
file does not, a link to a private repository, a page that drops an agent's verdict, or an agent's row that says its
session does not run while a plain start runs it each fails it.

## The rows

| ID | The harness must | Check that fails if the property is removed | Verdict | Today | Caveat |
|---|---|---|---|---|---|
| NS-1 | A new user clones the repository, runs ./build.sh and ./run.sh, and gets a running multi-agent harness: every tile on the home page green and the agent answering through Amazon Bedrock. | `./test.sh (the in-container suite); Container-Root/test3.sh (two headless fires complete a goal against Bedrock, skipped without credentials); tools/fresh-deploy-proof/run-all.sh (a clean clone, ./build.sh, ./run.sh, every tile through 127.0.0.1:8000 and the suite, on a host that never saw the image); Container-Root/test22.sh checks 7b [plain-run-set] and 7c [killed-spoke-returns] (a plain start with .env's defaults runs a session for every enabled agent, and a killed spoke is back within 20 s)` | **YES\*** | PARTIAL | a plain start with .env's defaults runs the hub, the supervisor and six spokes, and test22 checks 7b and 7c fail when one of them is missing or a killed spoke does not come back; on 2026-10-15 a fresh clone of main 3dc96e0, before the issues spoke shipped (an empty HOME, the stock scripts and defaults, only the container name, image tag and home port renamed to share a host) built, and ./run.sh started all seven sessions with every service up and the supervisor's pass at 5 of 6 live, conversations waiting for Slack; its ./test.sh passed 40 of 44 tests with one skip, test3's two fires answering through Bedrock: test9 and test16 fail on the renamed home port and pass with the default, and test18 failed once and passed alone; three fresh clones of main on 2026-10-14 (6c92c1b, 78afff8, b7cd1f0; an empty HOME, the stock scripts) built and ran with every tile up (13, 14 and 15 tiles) and the agent answered through Bedrock from the chat page; the four ./test.sh reds recorded on b7cd1f0 and the two found after them have their fixes merged (#104, #121, #122); the proof driver's last recorded runs are the eleven behind #31 |
| NS-2 | The agent does real work without Slack: a goal given to the autonomy loop reaches Done in one fire, shows on the board, and leaves a fact in the agent's memory. | `Container-Root/test3.sh (two fires complete a trivial goal against Bedrock; skipped without credentials); Container-Root/test18.sh (offline: a fire that checks a goal off moves its card to Done on the kanban board, and back); Container-Root/test-board.sh (offline: the Board tile and page); Container-Root/test-north-star.sh check 8 (the default start path: with .env's AUTONOMY_LOOP and no Slack the loop's autostart gate reads off, so that path cannot exercise the property, and the check fails once it starts the loop)` | **YES\*** | FAIL | FAIL is the default start path's result: .env ships AUTONOMY_LOOP=auto, which starts the loop only when SLACK_BOT_TOKEN and SLACK_CHANNELS are set (whether auto should also start it without Slack is an open decision for the maintainer), so a fresh clone without Slack runs no loop and a goal on the board is never worked (measured on a fresh clone of 3dc96e0 on 2026-10-15, whose start log says the loop was not started because SLACK_BOT_TOKEN and SLACK_CHANNELS are not set); the first three checks pass only where the loop runs, with AUTONOMY_LOOP=true or Slack configured, because they start their fires themselves, so a check that works a goal on the default path is what is missing (check 8 pins only that the path starts no loop); on that path the home page says the goal waits until the loop is enabled and names AUTONOMY_LOOP=true (Container-Root/test16.sh check 2), the container's start log gives the reason and no page does; the fact the agent's memory gains from a goal has no tracked check yet, though a fresh clone shows the agent's bank after one chat session |
| NS-3 | A new user needs only the README: no undocumented step between a fresh clone and the first green home page. | `a clone-and-go run on a brand-new host (tools/fresh-deploy-proof/run-all.sh: a host that never saw the image, from git clone to the suite) and the acceptance checklist, docs/GA-RELEASE.md section 3 row 1 (the build names a missing prerequisite)` | **YES\*** | FAIL | as of 2026-10-14 the last run on a brand-new host is run 1 on 2026-10-13 (a fresh instance and a Docker-in-Docker client), which found two blocking and four high-priority findings; the preflight that names the missing prerequisites is on main since 2026-10-14 (#96), and the re-run on a brand-new host is pending, so the row stays FAIL until one passes; the three fresh clones of 2026-10-14, on a host that already had the image's base layers, needed no step the README does not name beyond credentials for the private repository |
| NS-4 | No secret and no internal name ships: not in the tree, not in the image, not in the commit messages. | `Container-Root/test17.sh check 2 (Container-Root/seed/scan.py over the shipped seed and, in tree mode, over the vendored LogLearner tree, each with a planted control) and the build gate in install-loglearner.sh (a denylisted name fails the build)` | **YES\*** | PARTIAL | the tree, the shipped seed and the vendored tree are scanned with planted controls, and the internal identifier found in the vendored tree on 2026-10-13 is gone since #36; the scan over the whole image and over a merged range's commit messages is not a tracked check on main (docs/GA-RELEASE.md section 3 row 20) |

Updated 2026-10-15. "Today" is the result of the named check at this commit, read from its last run - not a
promise. A FAIL can also mean that the default start path cannot exercise the property at all, as for NS-2; the row's
check names the check that pins it and its caveat says why.

## Scoring

| Verdict | Meaning |
|---|---|
| **YES** | a tracked check proves the property today and fails when the property is removed |
| **YES\*** | a tracked check exists and fails when the property is removed, but today it reports a failure, a skip or covers only part of the property; the caveat is named on the row |
| **NO** | no tracked check: the property rests on a person having looked |

| Today | Meaning |
|---|---|
| PASS | the check passed at this commit |
| FAIL | the property does not hold at this commit (its check fails, or the default start path cannot exercise it) |
| PARTIAL | part of the property passes, part is unchecked or fails |
| SKIP | the check cannot run here (for example, no credentials) |

A row moves to **YES** when its named check passes on the merged main and still fails with the property removed. It
moves back the day the check is deleted, skipped or turned into a check that cannot fail.

## Today's honest state (2026-10-15)

* Every row names a check that is on main and can go red; none of them passes whole yet. The build-and-run path (NS-1)
  passed on three fresh clones of main on 2026-10-14 - every tile up, the agent answering through Bedrock - before the
  agent stack shipped. A plain start now runs the hub, the supervisor and seven spokes, and test22 checks 7b and 7c fail
  when one is missing or a killed spoke does not come back. On 2026-10-15 a fresh clone of main at 3dc96e0, the first
  with the stack and before the issues spoke shipped, ran with an empty HOME and the stock scripts and defaults, only
  its container name, image tag and home port renamed to share a host. It built, and `./run.sh` started all seven
  sessions with every service up and the supervisor's pass at 5 of 6 live, conversations waiting for Slack. Its
  `./test.sh` passed 40 of 44 tests with one skip, test3's two fires answering through Bedrock; test9 and test16 fail on
  the renamed home port and pass with the default, and test18 failed once and passed alone. The row stays PARTIAL:
  that suite was not green as run, and the proof driver's last recorded runs are the eleven behind #31.
* The agent's work (NS-2) fails on the default start path: `.env` ships `AUTONOMY_LOOP=auto`, which starts the loop only
  with Slack configured, so on a fresh clone without Slack no goal is worked. Its checks pass where the loop runs
  (`AUTONOMY_LOOP=true`, or Slack configured), and the fact the agent's memory gains from a goal is observed, not yet
  checked.
* The README-only path (NS-3) was last run on a brand-new host on 2026-10-13 and failed; the preflight that names the
  missing prerequisites has merged since, the re-run on a brand-new host is pending, and the row stays FAIL until one
  passes.
* Nothing leaks (NS-4) is proven for the tree, the shipped seed and the vendored LogLearner tree, each with a planted
  control; the scan over the whole image and over commit messages is not a tracked check yet.
* All nine agents run on a plain start. The hub, the supervisor and five spokes are scored YES\*: three spokes on
  test22's checks, conversations also on `Container-Root/test-comms-defaults.sh`, the issues spoke on
  `Container-Root/test-issues-spoke.sh` and test22 check 7b, and the docker agent on `./test-docker-spoke.sh` and
  test22 check 7b. Sessions and loops score NO, since no check of their North Stars is written yet; each says how it
  becomes YES.

## The agents

The harness is an agent stack: a hub, a supervisor and spokes, each a tmux session with a charter, all listed in
`Container-Root/agent/spokes/registry.json`. A plain start with `.env`'s defaults runs the hub, the supervisor and seven
spokes, and `Container-Root/test22.sh` check 7b fails when one of them is missing. Each carries its own North Star, one
line that says what it must never get wrong. The names and the lines below are those of the stack's charter
(`docs/AGENT-STACK.md`), taken as written; the UI column names the tiles as the home page titles them today. Each agent
is scored by the rule above, like a row. An agent scored **NO** says in its caveat how it becomes YES: the check that
would score it and the change it lands with, or that no such check is written yet. The home page's North Star section
shows the same table, rendered from `docs/north-star.json`, and `Container-Root/test-board.sh` and
`Container-Root/test-north-star.sh` fail when the page, this table and the file disagree.

| Agent | North Star | UI it keeps | Talks to | Check that fails if the property is removed | Verdict | Today | Caveat |
|---|---|---|---|---|---|---|---|
| `agent` | A new user clones the repository, runs ./build.sh and ./run.sh, and gets a running multi-agent harness that does real work and shows it, with nothing undocumented and nothing leaking | tmux terminal, Agent chat, Agent loop | the person; each spoke | `Container-Root/test12.sh (the hub's own session: the shared agent tmux session runs the claude CLI, with a planted control); Container-Root/test22.sh checks 4 [bus-request-reply-journaled] and 5 [spoke-answers-hub] (a hub request to a spoke is journaled and answered by the spoke's own cycle); Container-Root/test3.sh [fire-reads-inbox] (offline: a loop fire reads the hub's open bus requests and notices before its goals, its reply is journaled with reply_to, and what a fire that fails or dies was handed stays open); the checks of rows NS-1 to NS-4 (the hub's North Star is the harness's own statement)` | **YES\*** | PARTIAL | the hub's session, its requests to the spokes, its loop fires' bus inbox and the four rows above are checked; the inbox check answers with a stand-in claude, so a real fire's answer is not a tracked check; NS-2 and NS-3 still fail, and no check exercises native SendMessage between two sessions |
| `supervisor` | Every enabled agent is running and unstuck, and every repair it makes is one a person would make without thinking: it never answers a menu and never sends, spends or deletes | its last pass on the tmux-agent dashboard and a home-page row | reports to agent and to the person | `Container-Root/test22.sh checks 7b [plain-run-set] (every enabled session runs on a plain start), 7c [killed-spoke-returns] (a killed spoke is back within 20 s at the shipped interval, with one restart line), 5 [spoke-answers-hub] (a spoke whose claude keeps exiting is marked stuck at the cap and not started again), 8 (planted menus, one whose answer would send, get no key); Container-Root/test-fleet-manager.sh checks 5 [close-exited], 5b [close-keeps-output] and 6 [close-off] (its one close: a scratch session whose every pane's process has exited, at two passes in a row, the output tmux kept for those panes copied to a file first and the session left open when it cannot be; never a running pane or a session of the registry, and none with SUPERVISOR_CLOSE_EXITED=false)` | **YES\*** | PARTIAL | every clause but one is checked: nothing checks that it never spends or deletes |
| `conversations` | Lets the agents take part in human communication channels without ever silently losing an incoming message or silently sending an outgoing one | Conversations | agent only | `Container-Root/test22.sh checks 5c [waiting-for-settings] (without SLACK_BOT_TOKEN and SLACK_CHANNELS it waits and says so) and 10b [spokes-own-checks] (its cycle against a stub Slack, when the engine has the stub override); Container-Root/test-comms-defaults.sh (the engine behind it: the pinned Slack adapter has no send path)` | **YES\*** | PARTIAL | the engine at /opt/comms has no stub Slack API override (the spoke's pinned ref has it), so test22 check 10b does not run its cycle against a stub Slack and says so; a stub Slack is not Slack, and never silently losing an incoming message rests on the engine's own tests |
| `insights` | Turns the agents' work exhaust into screened, recallable rules that measurably improve the next session | Session insights, Learned rules | agent only | `Container-Root/test22.sh check 10b [spokes-own-checks] (its loop's self-test: a planted correction banks one candidate, a duplicate none)` | **YES\*** | PARTIAL | no check yet measures that its rules improve the next session |
| `clusters` | Shares GPU clusters with other people without ever acting on a stale picture or presenting one as fresh; never mutates a cluster | Headlamp | agent only; unprompted only when placement changes | `Container-Root/test22.sh check 10b [spokes-own-checks] (its loop's self-test: every write verb refused, a context named like an EKS cluster read with a safe cache name); Container-Root/test-cluster-lock.sh checks 10 to 13 (the cluster lock it brokers: the hub's gpu-lease requests answered from its view, never on a cordoned node or from a view older than 30 minutes, release and expiry, one cycle's lease table and its notice, the claim-and-release rule in its charter and the agent's rules; checks 1 to 9 prove the lock itself)` | **YES\*** | PARTIAL | its 15-minute cadence is not checked, and its own North Star scores 2 of its 10 rows YES; a lease binds this harness's jobs to each other and reserves nothing from other people's workloads, and the lock's checks run on planted views, not a live cluster |
| `sessions` | Reports no state it did not read from the census; never spawns, sends to or kills a session | tmux-agent dashboard | agent only | no tracked check | **NO** | - | it runs on a plain start (test22 check 7b); Container-Root/test-fleet-manager.sh checks 1 to 7 cover the session ledger, the books of the container's tmux sessions that the supervisor keeps from tmux, not this spoke's reports, and no check that its reports match the census is written yet |
| `loops` | Never shows a loop as healthy without evidence of a completed run, and fails closed when it cannot validate | Loop Deck | agent only | no tracked check | **NO** | - | it runs on a plain start (test22 check 7b), but no check of its North Star is written yet; the Loop Deck it keeps true is checked on its own by Container-Root/test-loop-deck.sh and Container-Root/test-loop-deck-adapter.sh |
| `issues` | Outward drafts are evidence-driven, scrubbed and human-confirmed; nothing is ever posted automatically | Board, Goals board, Project board (Plane) | agent only | `Container-Root/test-issues-spoke.sh checks 2 [front-refuses-writes] and 6b [session-walls] (nothing is posted automatically: every write form is refused before gh runs, and the session holds no GitHub token and is denied the write paths), 6 [go-gate] (scrubbed and human-confirmed: a draft is sent only after a GO naming its sha256 and its first 12 characters typed at a terminal, and a token-shaped draft or one the redact scan refuses is refused), 3 [waiting-for-github], 4 [cycle-rows-read-only], 4b [named-repos-own-scan], 5 [hub-asks-conflicting], 1 [registry-entry] and 7; Container-Root/test22.sh check 7b [plain-run-set] (a plain start runs issues)` | **YES\*** | PARTIAL | check 6 sends through a stub gh, so a real GitHub send behind a person's GO is never exercised; evidence-driven has no tracked check (its own North Star, Container-Root/agent/charters/issues/NORTH-STAR.md, scores that row NO: a person checks the evidence at the GO); every session runs as root in one container, so one that worked around its deny rules could type the GO's prefix or read another process's token; and the boards it names do not show its rows yet |
| `docker` | Builds container images inside the harness from a Dockerfile into the stack's own registry, without a host Docker socket or cloud resources made for the occasion, and never pushes outside the stack without a person's say | Docker spoke, its page at /docker/ | agent only | `./test-docker-spoke.sh checks 1 [substrate-up] to 10 [prev-carry-forward] (a build through the helper lands in the stack's registry with its digest, a push to another registry is refused before buildctl runs and the helper's push target cannot be redirected, the cycle's page lists the images, its rows and the doctor's check go red with a sidecar stopped and a failed substrate reads DOWN, and a down cycle announces no image as new); Container-Root/test22.sh check 7b [plain-run-set] (the plain start's set includes docker)` | **YES\*** | PARTIAL | the build into the registry, the refused outside push, the page and the red rows and doctor check are checked; nothing checks its notices for a stopped daemon or a low disk, a failed build's record, its session's deny rules in a live session, or that no cloud resource is made, and the test needs a host that allows unprivileged user namespaces; every session runs as root in one container and can reach the daemon's socket, so a session that worked around its deny rules, or any other session, could push an image outside the stack with buildctl directly: the helper and the deny rules, not the daemon, are the gate on where an image goes |

## The components' own North Stars

Each component the agents stand on keeps a North Star of its own, written to the same rule. A public repository's
document is linked; a private one's is described, never linked. The agent column names the agent of the stack that
stands on the component; the as-of date is the day this register read the document. The home page's North Star section
shows the same table.

| Component | Agent | Where its North Star lives | As of | State |
|---|---|---|---|---|
| communication-engine | `conversations` | https://github.com/dmvevents/communication-engine/blob/1156a40ca7021cbae9a4e89f42a5b0478bd2c86f/docs/NORTH-STAR.md, at the commit Container-Root/setup/install-comms.sh pins (the image's clone at /opt/comms carries the same file) | 2026-10-14 | five ordered priorities and the ways to falsify it; last changed 2026-09-02, before the write surface (a person's click sends a staged reply, 2026-09-04) that the pinned commit carries, which its open items do not reflect yet |
| tmux-agent | `sessions` | https://github.com/dmvevents/tmux-agent-public/blob/92113b54b755cffc7666c0f475cb706b38d9ade9/docs/NORTH-STAR.md, at the commit the dashboard vendored under Container-Root/opt/tmux-agent is built from (that copy links the document and does not carry it) | 2026-10-14 | one sentence, four non-negotiables and its own definition of done; it records that its GA claim rests on adoption by a stranger, a property its 2026-08-27 refutation run found never measured |
| LogLearner | `insights` | the LogLearner source repository, which is private; the minimal runtime vendored under Container-Root/opt/loglearner carries no North Star document | 2026-10-14 | not read here: the vendored docs cite two of its gates, N4 (an inventory of every path data can leave the host, audited 2026-08-27) and N5 (the knowledge lifecycle, closed 2026-08-27) |
| Loop Deck | `loops` | the Loop Deck's source repository, which is private; its statement also ships with the loops spoke at Container-Root/agent/charters/loops/NORTH-STAR.md, and the release tree vendored under Container-Root/opt/loop-deck carries none | 2026-10-14 | one statement paragraph, written 2026-10-14, which the loops agent's North Star above shortens; no scored rows yet |
| clusters spoke | `clusters` | ships with the clusters spoke: its statement at Container-Root/agent/charters/clusters/NORTH-STAR.md, its scored rows with the spoke's private source | 2026-10-14 | 10 rows, 2 YES on 2026-10-14 (write verbs refused, and safe cache names for EKS-style contexts); seven have no automated check, and one has a check the running code does not pass yet |

## Reproduce

```bash
./test.sh                                   # the in-container suite, every test named below included
tools/fresh-deploy-proof/run-all.sh         # a clean clone, build, run, every tile and the suite, on a host that never saw the image
```

`./test.sh` takes no argument: it runs every test the image carries. The ones this register relies on are `test3`
(offline, a loop fire reads the hub's bus inbox first; then two fires complete a goal against Bedrock, skipped without
credentials), `test18` (offline: a checked-off goal moves its
card to Done, and back), `test17` (the seed scan and the vendored tree, with their planted controls), `test12` (the hub's
session runs the claude CLI), `test16` (the home page, the Start here strip's loop sentence among it), `test-board` (the
page, this file and the JSON agree) and `test-north-star` (the register keeps its own rule).

The companion to this register is the release checklist, [docs/GA-RELEASE.md](GA-RELEASE.md): the merge order, the
acceptance items with their failing controls, and the verification record. The North Star says what must be true; the
checklist says what is left to make it true.
