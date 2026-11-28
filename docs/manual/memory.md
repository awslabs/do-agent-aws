# Memory and learning

What the agent remembers, how it learns from its own work, and how knowledge moves between harnesses. Part of the [Do Agent on AWS manual](README.md).

Contents:

- [Agent memory](#agent-memory)
- [Agent learning tools](#agent-learning-tools)
- [Moving knowledge between instances](#moving-knowledge-between-instances)
- [A shared knowledge base for a group](#a-shared-knowledge-base-for-a-group)

## Agent memory

The agent has three memories, all persisted as described above; the first is Claude Code's own and the other two are on
the home page:

* **Claude Code's auto-memory** - the `MEMORY.md` index and the fact files the model writes for itself and reads at the
  start of every session, one directory per working directory under the agent state
  (`/home/agent/.claude/projects/<slug>/memory/`; the autonomy loop's fires, the chat responder and the agent's pane all work
  in `/wd`, so they share one; a spoke has its own under its directory). It is how a native Claude Code instance keeps
  what it learns about its operator, its lanes and its decisions from one session to the next, and it is on by Claude
  Code's default: `AGENT_MEMORY=true` in `.env` states that explicitly, and
  `/agent/claude-memory-settings.py` (run by `claude-settings-sync.sh` at the build and at every start) writes
  `autoMemoryEnabled` into the agent's `settings.json` accordingly, keeping every other key, so a state created by an
  older image or a changed Claude Code default follows the knob; `AGENT_MEMORY=false` turns it off at the next start.
  `/agent/parity-inventory.sh` reports the setting (`auto-memory`) and the files (`memory`). The overlay example
  ([docs/parity/CLAUDE.md.example](../parity/CLAUDE.md.example), section 7) tells the agent what to keep there.

* **claude-mem** (per-session observations, summaries and the "what was I doing" context Claude Code
  gets back after compaction) runs as a plugin with a Bun worker; its viewer is the `Session memory`
  tile (`http://claude-mem.localhost:8000/`). The proxy pre-dismisses the viewer's "Welcome to claude-mem" modal
  (its local dismissed flag), and `CLAUDE_MEM_PUBLIC_URL` (`.env`) makes the "View Observations Live @" line every
  session start prints name that proxied route instead of `localhost:37700`, a port the harness does not publish.
  claude-mem 13.39.0 has no setting for its "30 Day Free Trial" cloud upsell (the viewer's header link and the same
  line at session start): the build takes the session-start line out of the pinned worker (the claude-mem
  paragraph further down names the patch and its guard), and the harness view of the viewer hides the header link. Nor for the GitHub star count its viewer fetches from `api.github.com`
  on every page load: the proxy sends the viewer a Content-Security-Policy that allows only its own origin
  (`connect-src 'self'`), so the browser refuses that request before it leaves and the viewer shows no count.
  The proxy also serves a harness view of the viewer (`CLAUDE_MEM_VIEWER_WRAPPER=true`, the default). A prompt card
  holding one of the harness's own machine prompts (a loop fire's instructions, the Slack chat responder's) is folded
  into a closed "Loop instructions (machine prompt, N lines)" disclosure, so the human prompts, the summaries and the
  observations read first. The trial promotion and the social links are hidden; Documentation, GitHub, settings, the
  project filter and the console stay. It works in the browser only and no stored memory changes. A note on the page
  switches that browser to the stock viewer and back, and `false` serves the stock viewer.
* **Hindsight** (long-term, per-repository memory with recall, reflection and knowledge pages) is ONE
  store: the self-hosted `hindsight-api` server on in-container port 8888, with its embedded PostgreSQL
  under `/home/hindsight/.pg0`. The Claude Code hooks installed by `setup/install-hindsight.sh`
  (`SessionStart`, `UserPromptSubmit`, `Stop` -> `~/.hindsight/coding-agents/dist/claude-*-hook.js`) and the
  `hindsight` MCP server are configured in **self-hosted** mode against that same server
  (`/home/agent/.hindsight/coding-agent.json`: `{"serverMode":"self-hosted","apiUrl":"http://localhost:8888"}`),
  so what the agent writes at the end of a session is what the `Memory` tile (and the API docs it links to)
  shows. (`setup/install-plugins.sh` merges into `settings.json` instead of overwriting it, and the build
  asserts the hooks are still there.) `test15.sh` writes a memory through the installed stop hook and
  reads it back from the API. Changing `PORT_INTERNAL_HINDSIGHT_API` is fine: `ui-start.sh` keeps the
  hooks' `apiUrl` in step with it, and `/agent/hindsight-hooks-repair.sh` (also run by `ui-start.sh`) puts
  the three hooks back into a persisted `settings.json` that an earlier image left without them - Docker
  seeds `wd/agent-state` from the image only once, so an existing deployment would otherwise keep the
  hook-less file forever.
  The hooks name a session's bank after its git repository (`coding-agent::<repo>`) and, outside one, after
  its directory, so work in the workspace itself lands in `coding-agent::wd`. A session started outside any
  directory (its working directory `/`, which has no name) would get a bank named `coding-agent::unknown`;
  the config's bank map sends it to `coding-agent::wd` instead (`"banks": {"coding-agent::unknown":
  {"bank": "coding-agent::wd"}}`, written at build and kept by the repair), so the Memory tile counts no empty
  `unknown` bank. `test15.sh` fires the stop hook from `/` with no directory and checks that no such bank appears.

**What a recall injects.** Hindsight's own prompt hook injected, as installed, a *reflection* - a narrative the memory
service composes over the bank for each prompt - under the heading of memory; composed over a bank that knew one project, it
told the agent that an unrelated question's subject was part of that project, which no stored record said. The harness
therefore runs that hook with `autoInject: "none"` in `/home/agent/.hindsight/coding-agent.json` (its tool guide stays) and
registers its own `UserPromptSubmit` hook, `/agent/hindsight-recall-hook.py`, next to it: it injects the bank's recall
*records* for the prompt as one `<hindsight_memory bank=... records=...>` block - the header names the bank and the record
ids, each line is one record with its id and where it comes from: the date, the session (`session 5f1fae85`) or the
document, and `agent claim, not verified` for a session record that states the agent's own action. A record that repeats
one already listed, one that is only the transcript's `REF-ID` marker and one in another language are left out; nothing is
a synthesis. The agent's `CLAUDE.md` says what the block is
(an index to verify against the records: the `Memory` tile, `/agent/recall.sh`), and `hindsight-hooks-repair.sh` keeps the
hook and the config setting in a persisted deployment. `test-hindsight-recall-hook.sh` proves it against a stub API.

**What a session stores.** At the end of every turn Hindsight's `Stop` hook sends the session's transcript to the memory
API, and the API's model extracts the facts. The transcript holds the user's and the agent's words and the name of each tool
the agent called, never a tool's result, so every outcome in a session record is the agent's own account. Records went
wrong three ways: a request stored as an outcome ("which the agent loaded", for a package the user had only asked to load),
records in German from an English session, and one fact stored twice. Three settings and one hook keep them honest:

* the hooks' config carries a `retainContext` (the text of `/agent/hindsight-retain-context.txt`, written when the config has
  none of its own), the context the stop hook sends with the transcript: a request is a request, and what the agent says
  it did is its claim;
* the hooks' config carries `retainMetadata` `{"verified": "false"}`, which the stop hook puts on every record of the
  session: a transcript holds no tool result, so nothing a session record says was checked. The recall hook marks each
  session record `not verified` (`agent claim, not verified` when it states the agent's own action), and a record the
  memory API derived (an observation) `from session <id>; not verified` when its source facts come from a session
  (`from session <id>; derived claim, not verified` when it states an outcome: it is labelled, not removed);
* the memory API runs with `HINDSIGHT_API_LLM_OUTPUT_LANGUAGE=English` (set another language on the host; `run.sh` passes
  it through), so extraction, consolidation and page refreshes write in that language;
* `/agent/hindsight-session-guard.py`, registered for `Stop` next to Hindsight's stop hook, checks each record a session
  write-back stored, once, in every session bank (`coding-agent::*`). A record that states the agent's own action is
  rewritten as `The agent said: <text>` with the context `agent claim, not verified; session <id>; <time>`. A record that
  opens with the user's request and goes on with the agent's account of the outcome keeps its text and gets the same
  context. A record in
  another language (the words outside quotes are counted, so an English record may quote another language), one whose content (the text before ` | `) a valid record of the bank already holds, and one that is only
  the `REF-ID` marker are invalidated with the reason - reversible: the record moves to the bank's archive, where the
  Hindsight UI shows it.

The same pass logs every failed operation of the session banks once, with its reason, to `/wd/ui/hindsight-memory-guard.jsonl`.
The failures seen are knowledge-page refreshes: the hooks create five pages per bank, each refreshed hourly, and a page whose
refresh fails is queued again by the memory API every five minutes and fails again (`delta operations did not reach the
document`, `LiteLLM response was truncated due to token limit`), so the count grew without bound. A page whose refresh
failed twice since its last good refresh has its schedule paused (its trigger's `refresh_cron` cleared, logged with the
reason, the cron kept in the guard's state). When a refresh by hand from the Hindsight UI succeeds, the guard puts the
cron back. In a git project Hindsight's session start puts it back too: it starts Hindsight's deepen engine in the
background, which re-applies each page's trigger. A bank outside git has only the guard's restore. A failed
retain whose reason is transient (throttling, a timeout, a 5xx, a dropped connection) is queued again, at most 3 times, 2,
8 and 32 minutes apart, and the guard's own calls are retried on a 5xx or a timeout. The guard runs at most once per 20 s,
never blocks the stop and prints nothing; `HINDSIGHT_SESSION_GUARD=false` turns it off. `test-hindsight-session-guard.sh`
proves it offline, through Hindsight's own stop hook against a stub API; `test16.sh` runs one pass against the
test-local memory API (a bank that stores each record as it is sent, so no model is needed) and reads the records back.

**Default knowledge seed.** On the first start (`startup.sh`, after the UIs are up) `/agent/hindsight-seed.sh`
loads `Container-Root/seed/` into two banks: `harness-knowledge` (general AWS - EC2, IAM least privilege, S3,
EKS/kubectl, Bedrock model access and inference profiles, CloudWatch, quotas, Spot and capacity reservations - plus
Docker, Claude Code agent operations, git/PR hygiene and this harness's own conventions) and `loglearner-rules`
(starter anti-regression rules). Every item carries a stable `document_id`, so the load is idempotent - a
re-run or a changed seed updates in place and never duplicates; the API refuses two items with one id in a
batch, so the loader also de-duplicates each batch. A stamp at `/wd/hindsight-seed.stamp` (the seed's
content hash and the counts) makes it run once; `HINDSIGHT_SEED=false` in `.env` turns it off; inside the
container `/agent/hindsight-seed.sh --status | --force | --dry-run` inspects or repeats it. The seed is
general by construction: no customer, person, account, host, channel or token appears in it, and
`Container-Root/seed/scan.py` (run by `test17.sh`) fails on any of
those, so an item that would leak cannot ship. `Container-Root/seed/README.md` describes the curation and
how to add your own items. `test17.sh` proves the banks exist and were accepted, that the loader is
idempotent and opt-out-able, and - when Bedrock is reachable - that every item was extracted into memory.
The home page's Memory tile shows the seed's state and the banks' counts in a note it reads once a
minute: the state, the bank list, then each bank's counts at once. Each read gives up after 8 s, and
a minute's pass is skipped while the last one is still reading, so a memory API that hangs holds one
pass's reads per tab, one per bank, for 8 s at most. Banks that did not answer are counted in the note
("1 of 4 banks did not answer"), and an empty bank list reads "no banks yet". The 8 s include any
time a read waits for one of the browser's connections to the home port. Failed operations are counted with
their reasons, read from each failing bank's failed operations, the most frequent first ("30 failed (page refresh:
delta operations did not reach the document)"), and the note is then styled as a warning; with none it is unchanged. A
failed operation stays counted until it is deleted (`DELETE /v1/default/banks/<bank>/operations/<id>/delete` on the
memory API); the session guard's log keeps each one with its reason, and its pause stops a page from adding new ones.
The
session guard's counts (`/__memory-guard`) follow: records set aside by reason, agent claims marked, page refreshes
paused. `test-home-memory-note.sh` runs the page's own note script, as served, under simulated time and checks each of
these.

claude-mem runs its hooks and worker under [Bun](https://bun.sh). The image installs Bun explicitly
(`Container-Root/setup/install-bun.sh`, pinned, at `/usr/local/bin/bun`) and runs the claude-mem installer
with `--provider claude`, which claude-mem requires for non-interactive installs since v13.18.1. If a Claude
session prints `Failed with non-blocking status code: Error: Bun not found. Please install Bun`, the image
predates this: rebuild with `./build.sh` and confirm with `./test.sh` (test11 checks the hook runtime).

claude-mem appends a "30 Day Free Trial" cloud upsell to the message every session start shows and to the context
banner of its user-message hook, and has no setting that turns it off. Until upstream adds a setting, see
thedotmack/claude-mem#4768: `setup/install-claudemem.sh` takes the two calls that append it out of the pinned
worker bundle. The build fails when either call is not there exactly once, and when the pin moves to a version the
patch was not written for, so a new claude-mem gets the patch checked again (test11 check 6b runs both hooks).

The plugins keep some state in the working tree a session runs in: oh-my-claudecode its `.omc/`, ralph-loop its
`.claude/ralph-loop.local.md`, Claude Code its `.claude/settings.local.json`. Git's per-user excludes file in the
image (`/home/agent/.config/git/ignore`, written by `Container-Root/setup/install-plugins.sh`) keeps that state out of every
commit made in the container, including the agent runner's commit after a workspace run (test21 checks it). A
`core.excludesFile` of your own replaces that file.

## Agent learning tools

What the harness knows reaches the agent in two ways, on by default, and the agent adds to it from the command line.

* **Delivered before every tool call.** A Claude Code PreToolUse hook (`LOGLEARNER_HOOK=true` in `.env`;
  `/agent/loglearner-hook.sh`, matcher `Edit|Write|Bash`) hands every Edit, Write and Bash call to the LogLearner
  runtime's hook, which matches the edited file's path tokens and the command's program names (docker, kubectl,
  `aws <service>`, git, pip, ...) against the LogLearner knowledge bank and adds the matching records to the
  model's context ("Banked learnings matched to this edit|command - N of M shown", each with its id, confidence,
  status, provenance and evidence). It never blocks or changes a tool call: it always exits 0 and gives up after
  9 s. The bank (`/wd/loglearner/banks/global/instincts.jsonl`) is loaded at every start
  (`/agent/loglearner-packs.sh`, idempotent) from the `/seed` banks, the same curated knowledge the Hindsight memory
  is seeded with, converted, and from the packs the image ships in `/opt/loglearner-packs`, each in the runtime's own
  schema and verified against its manifest's sha256: the public example pack `gpu-cluster-basics`, 21 generic GPU,
  NCCL, EFA, Kubernetes and PyTorch troubleshooting records, each written from the public documentation page it
  names (its `VENDORED.md`). So the pack reaches the tool call by itself: a `kubectl drain` or `kubectl describe`
  gets its rule on starting a pod investigation, an `fi_info -p efa` its EFA rules (unless `AGENT_KNOWLEDGE=false`,
  below). `LOGLEARNER_HOOK=false` removes the hook entry at the next start.
* **On disk, for headless fires.** A loop fire (headless `claude -p` in `/wd`) may Read and Grep; under the safe
  value of its options ("Autonomy loop") it cannot call the memory MCP tools, so the Hindsight banks alone never
  reach one. At every start `/agent/knowledge-files.py` (`AGENT_KNOWLEDGE=true` in
  `.env`) copies the shipped packs, their manifests and the seed's general banks to `/wd/knowledge/defaults`,
  writes the skill `aws-defaults-knowledge` (every record's id and title) and a marked "Default knowledge" section
  of the agent's CLAUDE.md naming the copy, the grep and `/agent/recall.sh`. The section also sends a diagnosis, an
  audit or a count to the team's own earlier result first - the records, recall and a grep of every shared package
  loaded under `/wd/knowledge` - and has the answer set a recorded result beside the agent's own, the same or
  different and why. A record is a lead, not a
  measurement: when the artifact itself can be read in seconds the section has the agent read it and give both, an
  image's config with `crane config` (the image ships crane and no docker CLI). `AGENT_KNOWLEDGE=false` switches the
  default knowledge off: it removes the copy, the skill and the section, and a start loads none of the shipped packs
  into the LogLearner bank and takes out of it the records an earlier start loaded from them (they carry the pack's
  name; every other record, a learned one too, stays as it is), so neither the hook nor the bank half of
  `recall.sh` serves one, and the Hindsight half of `recall.sh` skips the memory banks a shipped pack covers (the
  seed banks its manifest names in `hindsight_banks`, which the Hindsight seed put there on an earlier start; the
  example pack names none). Switched on again, the next start loads the packs again and recall searches those banks
  again. The seed's general banks load either way. `HINDSIGHT_SEED=false`
  stops seeding the memory store; it removes nothing, so banks an earlier start seeded stay there (delete them
  through the memory API). A fire runs `/agent/recall.sh` under either value of `AUTONOMY_LOOP_CLAUDE_OPTS`: the shipped
  default, the safe value, allows it next to `/agent/slack-post.sh`, and the opt-in skips the permission checks.
* **`/agent/recall.sh "<what you are about to do>" [--k N]`** searches the LogLearner banks (the runtime's own
  `recall`, the hook's word match) and the Hindsight memory on `127.0.0.1:8888` - every bank the API lists: the
  two seed banks and the agent's own (`coding-agent::<project>`, where its sessions are retained); a memory
  counts only when it contains a query term - semantic recall returns its nearest neighbours even for nonsense.
  Plain text, each Hindsight hit labelled with its bank; exit 0 on a hit, 1 on none.
* **`/agent/learn.sh '<json>'`** banks a verified learning - a positive or a negative - through the runtime's
  gated writer (`python3 -m loglearner.cli bank`: a schema gate, duplicate and near-duplicate refusal, a stable
  `kb-NNNN` id), after a harness gate that refuses credential-shaped text. The hook serves it on the next matching
  call, recall finds it, the Learned rules tile counts it. `learn.sh --help` prints the schema.
* **The stores are written by the harness's tools only.** No Claude session - the interactive agent, a loop fire,
  the Slack chat responder - edits the LogLearner state (`/wd/loglearner`: the bank the hook injects from, its index
  and ledgers) or the default knowledge copy (`/wd/knowledge`) itself: `claude-settings-sync.sh` keeps Edit deny
  rules on their absolute paths in the agent's `settings.json` (`Edit(//wd/loglearner/**)`, `Edit(//wd/knowledge/**)`;
  they follow `LOGLEARNER_STATE` and `KNOWLEDGE_DIR`). Claude Code applies them to its file tools, to the file
  commands it recognises in Bash (`touch`, `cp`, `mv`, `tee`, `sed`) and to redirect targets (`>`, `>>`), under
  `--dangerously-skip-permissions` as well (checked: a headless call with that flag and a planted deny rule on `touch`
  did not create the file; the control without the rule did). Beyond those, a fire with the opt-in
  `--dangerously-skip-permissions` runs any command; under the safe value, the shipped default, its Bash runs the allowed scripts and the read-only commands Claude Code
  allows without asking (`ls`, `grep`, `cat` and the like: a fire greps the copy that way), and anything else needs an
  approval a headless call cannot give. Without these rules a loop fire under the safe value can write the bank with
  Write, Edit, `>>` and `touch`, and the hook then serves what it wrote. learn.sh, the pack loader and the dashboard are processes of
  their own and write as before. A program that opens the files itself is outside what a permission rule sees; the
  sandbox that would cover it (bubblewrap) is not in the image.
* **Every session starts from the image's copy.** The copy is what the CLAUDE.md section tells each session to
  follow, and it lies on the volume fires work in, so its bytes are checked against the image's: at every start (the
  sync) and, through a SessionStart hook that `claude-settings-sync.sh` registers (`python3
  /agent/knowledge-files.py verify`), before every Claude session - each loop fire, each chat reply, the agent's
  pane. A file whose bytes are not the image's is restored, a missing one re-created and a pack the image does not
  ship removed; each case is a line in `/wd/knowledge/integrity.log` (it follows `KNOWLEDGE_DIR`) and in the
  session's context, and the check prints nothing when the copy is the image's. The packs of a newer image read
  "updated", not "restored". A link, a pipe or a directory planted in the copy is replaced or reported, never
  followed or opened, so the check writes and removes nothing outside the copy. If `KNOWLEDGE_DIR` resolves through
  a link below its top-level directory, the start and the check refuse: nothing is written or removed there, and
  the skill and the section are withdrawn until it points at a real directory (a `/wd` that is itself a link is
  the host's layout and is followed). Measured: after another process
  appended a rule to the copy, the next loop fire's grep found no trace of it; with the hook entry removed, the same
  fire read the appended rule.

The container agent is told all of this in its own `CLAUDE.md`: a "Learning tools" section
(`Container-Root/agent-rules/AGENT_LEARNING.md`, referenced as `@AGENT_LEARNING.md` next to the governance rules)
says to recall before a `docker build`, a cluster change or an IAM edit, to bank verified positives and negatives,
and what the hook injects. `/agent/claude-settings-sync.sh` keeps the agent's Claude Code configuration in step
at build and at every start - the hook entry, that section, Claude Code's first-run answers (see "tmux in the
browser"), the status line and the GitHub plugin (below) - editing only the keys it owns, because the
configuration lives in the persisted agent state, where an image change would otherwise never arrive.

On the home page the **Learned rules** tile shows the bank (rules, bank files, deliveries and deliveries in the
last 24 h) from the LogLearner dashboard's status contract (`/api/tile.json`, read same-origin at
`/__tile/metalearner` - unlike the status-only dot probes it returns that one document's body, GET only and
without the browser's cookies or credentials); it turns red with the reason while that contract reads degraded
or does not answer, and its link opens the banked rules (`http://loglearner.localhost:8000/learnings`).

`test-agent-learning.sh` proves the contract: the hook registered in the image and its merge-safe sync, the seed
load and its no-op re-run, on-topic delivery for a Dockerfile, an eksctl yaml, an EKS `.tf`, `docker build`,
`kubectl apply` and `aws iam put-role-policy` with the controls (the flag off, the entry unregistered, a runtime
missing or hanging, an unknown command), recall against a planted Hindsight API, the learn round trip with the
Learned rules count rising by exactly one and its refusals, the CLAUDE.md section, and the tile through nginx.

**A GitHub token.** Put `GH_TOKEN` (or `GITHUB_TOKEN`) in the AWS Secrets Manager secret the container reads at start
("Credentials from AWS Secrets Manager"; for a quick local trial, an export in the host shell before `./run.sh` works
too, through bare `-e` switches like `SLACK_BOT_TOKEN`, with a start WARNING; compose resolves it from the host,
kubernetes reads the optional `do-agent-aws-github` secret) and `gh`, `git` and the GitHub plugin can use it - `startup.sh` hands it to the plugin as
`GITHUB_PERSONAL_ACCESS_TOKEN`, the variable its MCP server reads. Without a token the GitHub plugin is
disabled, so sessions no longer log a GitHub MCP server that cannot connect.

**The context7 plugin** (library documentation for the agent) is installed but off by default: its remote MCP server
needs an OAuth sign-in, so with it on every new terminal opened on "1 MCP server needs authentication". Set
`CONTEXT7_PLUGIN=true` in `.env` and restart, then run `/mcp` in the agent's terminal once to sign in - the
sign-in persists in the agent state. With neither a GitHub token nor context7 the terminal's first screen is clean.

## Moving knowledge between instances

The Memory tile links the **Knowledge transfer** page (`/knowledge/` on the home port), which moves what a harness knows
to another harness: [docs/knowledge-sharing.md](../knowledge-sharing.md), served at `/guide/knowledge-sharing/`.

* **Export** writes one `.tar.gz` of the selected knowledge: the LogLearner bank, Hindsight banks or both, narrowed by
  a tag, a range of days or a search, or exactly the records ticked in the page's finder (a LogLearner record by its id
  or title, a Hindsight document by its id). It holds `<name>.jsonl` (the LogLearner records), `<name>.hindsight.jsonl`
  (the Hindsight documents with their extracted facts, read through the memory API's document transfer, no model call)
  and `<name>.manifest.json` (each file's record count and sha256, the image build and memory API version it came from,
  what the scrub gate ran with), the shape `/agent/loglearner-packs.sh` loads. A rule the harness banked itself travels
  as `<id>-<hash of its rule>`, so it cannot replace another harness's rule that `learn.sh` numbered the same. This
  image's own default knowledge stays out unless the page's **Include this image's default knowledge** box (or
  `--include-defaults`) puts it in: the records of its packs (the packs in `/opt/loglearner-packs`, such as
  `gpu-cluster-basics`, and the `seed-*` packs) and its seed banks' documents. Every harness of the same image already
  has them, and a pack from an older image would put the older copies back. Records named by id travel either way, and
  a pack named like one the image ships is refused, on export and on import.
* **The scrub gate.** Every export passes the LogLearner runtime's export gate first, the one its dashboard's export
  uses. With a scrub config (`LOGLEARNER_SCRUB_CONFIG`, or `state/scrub-patterns.json` under `/opt/loglearner`) it
  applies that config whole; without one it runs the secret detectors the runtime ships. A record that looks like it
  holds a secret stops the whole export, and the page names the record and the class, never the value.
* **Import** checks every file of an uploaded pack against its manifest's sha256 and refuses the whole pack when one
  differs. **Check** first: the page says what the import would do (the LogLearner records it would add, replace or
  skip, and per Hindsight bank the documents the bank already has; it names any of this image's own default records the
  pack would replace and any of its seed documents a bank already has) and writes nothing. The import then loads the
  LogLearner file through the runtime's loader (a record already there is skipped, the same pack twice is a no-op) and
  the Hindsight documents through the memory API's document import, with the choice for a document a bank already has:
  keep the bank's (skip, the default), replace it with the pack's, or add the pack's beside it under a new id.
* **Kept.** An imported pack is kept in `/wd/knowledge/imported` (`KNOWLEDGE_IMPORTED_DIR`), and every start loads it
  again after the default knowledge: `loglearner-packs.sh` its LogLearner file, `/agent/knowledge-transfer.py load`
  (started by `startup.sh` in the background, log `wd/ui/knowledge-load.log`) its Hindsight documents, skipped while
  its stamp matches and its banks still hold every one of its documents by id. A kept pack that cannot be read or
  loaded is named in that log, and the others still load. `knowledge-files.py verify` owns `/wd/knowledge/defaults`
  only and leaves the folder alone.

The page's server is `/agent/knowledge-transfer.py serve`, started by `ui-start.sh` with the home page on 127.0.0.1
(`UI_PORT_KNOWLEDGE`, 8097; nothing is published) and routed by the home proxy, GET and POST only, packs up to 64 MiB
(`KNOWLEDGE_PACK_MAX` in the container, which the proxy and the server both read), each action at most 840 s
(`KNOWLEDGE_REQUEST_BUDGET` in the container, inside the proxy's 900 s). An import that runs out of that time after its
LogLearner load keeps its pack, and the pack's memory documents load at the next start.
Its three POSTs, export, check and import, are taken only with the page's own `X-Knowledge-Transfer` header and the
page's own origin, which a form or a script on another site cannot send. The same commands work from a shell in the
container: `knowledge-transfer.py export <out.tar.gz> [--name N] [--store loglearner|hindsight] [--bank B] [--tag T]
[--since D] [--until D] [--search TEXT] [--id ID]... [--include-defaults]`, `knowledge-transfer.py records [--search TEXT]`,
`knowledge-transfer.py preview <pack.tar.gz>` and `knowledge-transfer.py import <pack.tar.gz> [--on-conflict
skip|replace|new-id]`. `test-knowledge-transfer.sh` proves the export's sha256 and counts, the selections, the scrub
gate, the import into an empty second instance with its preview and its no-op, the choice for a document a bank already
has, the refused packs (a changed byte, a malformed manifest or document), the kept pack through verify and a start
(by document id, past a broken kept pack), the shared pack from S3, this image's own default knowledge left out and
flagged, the page through the proxy with its refusals, and the server's start and stop.

## A shared knowledge base for a group

Every harness of a group loads the same pack at its start. A pack is a set of plain files, so the group keeps it where
it keeps shared files ([docs/knowledge-sharing.md](../knowledge-sharing.md) walks through both ways):

* **A private git repository.** Export the pack on the harness whose knowledge the group wants, commit its three files,
  and put them into `wd/knowledge/imported/` on each harness, or import the `.tar.gz` on its Knowledge transfer page.
  The next start loads them, and a pack that has not changed is a no-op at every later start.
* **S3, pulled at every start.** Set `LOGLEARNER_S3_BUCKET` in `.env.local` (install.md "Settings"; empty, the default, is
  off). At every start `/agent/loglearner-packs.sh` runs the runtime's `/opt/loglearner/scripts/loglearner-pull.sh`,
  which reads `s3://<bucket>/<LOGLEARNER_S3_PREFIX>/<LOGLEARNER_PACK>/latest.json` (or the version
  `LOGLEARNER_PACK_VERSION` names), checks that version's `instincts.jsonl` against its `manifest.json` and loads it
  after the default knowledge with the container's own AWS access. A file whose sha256 differs leaves the bank as it
  was, the same version again is a no-op, and nothing is ever written to S3. It carries the LogLearner half of a pack:
  publish an exported pack's `<name>.jsonl` as `instincts.jsonl` and its `<name>.manifest.json` as `manifest.json` under
  `<version>/`, then point `latest.json` at that version. Empty prefix, pack and version mean `loglearner/packs`,
  `aws-default` and `latest`.
* **Next: a hub.** A knowledge service that every harness of a group reads and writes live is the designed next step.
  Its design decisions are still open; until they are made, the pack files above are how a group shares knowledge.
