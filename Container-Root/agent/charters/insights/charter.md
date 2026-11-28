# Charter — the `insights` spoke

The resident agent that keeps the Log Learner dashboard current inside the harness. It mines the person's own Claude Code
transcripts into **rule candidates**, puts them where a human can review them, and tells `agent` when something new is
there. It never promotes a candidate into the rules agents receive; a human does.

## North Star

"LogLearner turns an agent's work exhaust — coding-session transcripts, private code-snippet gists, legacy knowledge
folders — into consensus-screened, scrubbed, recallable knowledge: paired positive/negative examples and
confidence-scored rules that measurably improve the next agent session." (the LogLearner project's North Star)

## Source

- Runtime: the vendored **Log Learner minimal runtime 0.1.13** at `${LOGLEARNER_DIR:-/opt/loglearner}` (the tarball
  `loglearner-minimal-0.1.13-20261126.tar.gz`, sha256 `9ddb7ece309dc8a9899937b061d6a04e0bbaec3b33f212c6ba38d6fcef460b99`,
  recorded in `/opt/loglearner/VENDORED.md`). The spoke runs the vendored tree; it does not clone anything.
- Repository: `https://github.com/dmvevents/loglearning` (public; the minimal runtime only, tag `v0.1.13`). The spoke
  still runs the vendored copy the harness pins.

## What it reads

- New transcripts under `${HOME:-/home/agent}/.claude/projects/**/*.jsonl` (or `CLAUDE_PROJECTS_ROOT`), read-only, streaming;
  only `primary` sessions (observers, crons and sub-agent files are skipped). "New" = modified since the last cycle marker.
- The installed knowledge banks under `LOGLEARNER_BANKS_DIR`, read-only, to avoid re-proposing what is already banked.

## What it writes — and nothing else

1. **Rule candidates** into `${LOGLEARNER_CANDIDATES:-$LOGLEARNER_BANKS_DIR/candidates/mined.jsonl}`, through the same
   gates `learn.sh` applies: a credential-shape refusal (access keys, tokens, private keys, bearer tokens, passwords), the
   runtime's schema gate, its duplicate and near-duplicate refusal, a stable `kb-NNNN` id. A candidate carries
   `lifecycle_state: candidate` (runtimes before 0.1.10 record `screened`; the file location carries the meaning),
   `status: negative` for a correction or an error cluster, `confidence: low`, `provenance` naming heuristic mining with no
   model and no review, and `evidence` as a pointer (`session:<8 chars> lines:a-b`), never transcript text.
   The hook does **not** deliver this file: it serves `INSTINCTS_JSON` (the global bank) and the top level of
   `FLEET_LEARNINGS_DIR`; candidates sit one directory below. The Knowledge page shows them live by class (`/knowledge`,
   filter `?cls=`), and the Meta Learner tile counts them.
2. **A Hindsight memory** per candidate into `LOGLEARNER_HINDSIGHT_BANK` (default `loglearner-rules`) on the loopback
   Hindsight API (`${HINDSIGHT_API:-http://127.0.0.1:8888}`), best effort: if the API is down the cycle reports
   `hindsight: skipped` and carries on.
3. Its own state under `LOGLEARNER_UCB_DIR/state/spoke-insights/` (last-cycle marker, last summary) and a refreshed
   dashboard index (`LOGLEARNER_DB`).

Promotion is a separate, human-gated step: after reading a candidate, a person (or `agent` on the person's GO) banks the
generalized rule into the global bank with `/agent/learn.sh '<json>'` (or `python3 -m loglearner.cli bank`), optionally
with `"corrects": ["<candidate id>"]`. Only then does the hook deliver it.

## Loop and cadence

    /agent/charters/insights/loop.sh            # one cycle; exit 0 even when there is nothing new
    loop.sh --since-hours 24 --max-candidates 20 --dry-run
    loop.sh --self-test                          # plants one transcript in a scratch HOME and proves the cycle end to end

Cadence: the supervisor runs one cycle every `cadence_sec` of the `insights` entry in `/agent/spokes/registry.json`
(3600 s), in `/wd/insights`, with the entry's environment and a timeout of one cadence; it spends no model tokens, and
the loop reads no interval variable of its own. Lines the cycle prints that start with `HUB: ` reach `agent` as
notices. A cycle with no new primary transcript is quiet. Each cycle prints one JSON summary line:
`{"transcripts": n, "gaps": n, "candidates": n, "banked": [ids], "duplicates": n, "refused": n, "hindsight": "...", "reindex": "..."}`.

## Who it talks to, and about what

- **To `agent`**, after a cycle that banked something:
  `insights: new candidate kb-0042 from today's sessions — <rule, first 120 chars> — review: /knowledge?cls=<class>, promote with learn.sh`.
  One message per cycle, listing every new id; nothing when the cycle was quiet.
- **From `agent`**: "what did you learn today / this week?" → the spoke answers from the candidates file and the cycle
  summaries (ids, classes, counts), and "promote kb-0042" → the spoke replies with the exact `learn.sh` command and the
  generalized wording for the person to approve; it does not run it on `agent`'s word alone.
- Message format: the harness's inter-agent message spec; every message is logged where the tmux-agent dashboard shows it.
- It talks to no other spoke and to nothing outside the container.

## The six rules

1. **Loopback only.** Everything it serves or calls is on 127.0.0.1 (the dashboard, the Hindsight API). No other network.
2. **Nothing leaves without a human GO.** Candidates stay in the candidates file; promotion into the delivered rules is a
   human (or human-approved) act; nothing is sent off the host.
3. **Read-only on clusters** and on every external system: the spoke has no cloud, cluster, Slack or GitHub access and asks
   for none.
4. **Never type into another session's menu.** It communicates only through the harness's session messages.
5. **`${VAR:?}` guards on every deletion**, or literal paths; it deletes only its own scratch (self-test) directories.
6. **It states what it writes** (the three items above), and its tile names them. Anything else is out of scope.

## Health, and what "green" means

- `GET /api/tile.json` → `status: ok` (index present, banks present).
- `/knowledge?cls=<class>` shows the candidates with `lifecycle` candidate (or screened on 0.1.9) and the honest count.
- The spoke's last summary under `LOGLEARNER_UCB_DIR/state/spoke-insights/last-summary.json` has a fresh timestamp.
- With the `.env` flag off, nothing runs and the tile says how to turn it on.

## What it deliberately does not do

No model calls inside the cycle (generalizing a candidate into a rule is the agent's interactive work, with the person);
no editing of settings, hooks or any other session's files; no reading of transcripts outside `HOME/.claude/projects`;
no scrub of transcript text into rules — candidates quote at most the user's own correction sentence, and that is why
they wait for review.
