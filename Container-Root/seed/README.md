# Default knowledge seed for Hindsight

This directory ships inside the image at `/seed` and is loaded once per `/wd` volume into the
harness's self-hosted Hindsight API (`http://127.0.0.1:8888`) by `/agent/hindsight-seed.sh`,
which `startup.sh` runs in the background after the UIs are up. A fresh container therefore
answers memory questions about AWS, containers, Claude Code operations, git hygiene and this
harness from its first session, before any conversation has been retained.

## The banks

| Bank (`banks.json`) | File | Items | What it holds |
|---|---|---|---|
| `harness-knowledge` | `harness-knowledge.jsonl` | 140 | General, durable knowledge: AWS as an agent uses it (EC2 and IMDS 8, IAM 8, S3 6, CLI 3, CloudWatch 5, EKS and kubectl 10, Amazon Bedrock 10, quotas 4, Spot and capacity reservations 6, general 2), Docker and containers (18), Claude Code agent operations (22), git and pull-request hygiene (14), and this harness's own conventions (24: the single home port behind an SSH tunnel, `/wd` state, the shared agent tmux session, the loop and Slack gates, the memory stack, the test style). |
| `loglearner-rules` | `loglearner-rules.jsonl` | 28 | Starter anti-regression rules in the LogLearner style - `rule`, an `evidence:` line naming the kind of evidence that shows the rule was broken, a `confidence:` line. |

168 items in total; the cap is 300 items per bank (`scan.py` enforces it). The LogLearner bank also gets the example
knowledge pack the image ships beside the seed, `gpu-cluster-basics` (`/opt/loglearner-packs`, its own
`VENDORED.md`): it is not a Hindsight bank.

### Item schema

One JSON object per line:

```json
{"document_id": "aws-iam-003", "content": "1-6 sentences, the fact or rule and how to check it", "context": "one line: what kind of knowledge this is", "tags": ["area", "sub-area"]}
```

`document_id` is stable, kebab-case and unique within its bank: it is the Hindsight document id,
so re-running the seed updates an item in place instead of duplicating it. `timestamp` and
`metadata` are the only optional keys, and the shipped banks use neither (`hindsight-seed.sh` posts each `metadata`
value of an item of your own as a string, the API's only value type).

## How the items were curated

- **harness-knowledge** was written for this seed from the AWS, Docker, Claude Code and git
  documentation the harness itself relies on (`docs/bedrock/README.md`, `README.md`, `.env`,
  `Container-Root/agent-rules/AGENT_RULES.md`, the `/agent/*.sh` headers, `docs/loop/GOALS.md.example`).
  Facts are phrased as checkable statements with the command that verifies them; version numbers
  and limits that change over time are described as "check with ..." rather than stated.
- **loglearner-rules** was written from general engineering learnings and from the harness's own
  operating rules.

### Exclusion list (enforced by `scan.py`, not just by review)

Nothing in this directory may carry: AWS access keys or any token shape (Slack, GitHub,
Hugging Face, `sk-` keys, bearer values, `key=value` assignments of secret-named keys), PEM
private keys, 12-digit account ids, ARNs, IPv4 addresses other than loopback, the wildcard
address and the IMDS endpoint, hostnames and EC2/VPC resource ids, Slack channel/user/DM ids,
email addresses outside the documentation domain `example.com`, customer names, people's names
and handles (the denylist is `DENYLIST_SHA256` in `scan.py` - sha256 digests of the terms, so neither this
document nor the scanner spells them out and the scanner never flags its own documentation; `python3 scan.py --hash
"<term>"` prints the digest for a new term), or an excluded topic - drawn per bank:
- the general banks (`harness-knowledge`, `loglearner-rules`, and any other bank that is not a `layer-*.jsonl`)
  exclude the deep-research topics whole, DeepEP, NVSHMEM, NIXL, GDAKI, IBGDA, EFA, NCCL and libfabric
  (`SCOPE_EXCLUDED`), as they always have;
- a layer bank (`layer-*.jsonl`, a bank of one layer of the GPU stack that you add; the seed ships none), and
  `banks.json` and this README, draw the line at depth instead (`DEPTH_EXCLUDED`): the practical level of those
  topics - versions, environment variables, modules, checks, failure signatures - may go in a layer bank; device-API
  calls, kernel signatures and launches and transport internals may not.

## Re-running the scan

```bash
python3 Container-Root/seed/scan.py Container-Root/seed      # from a checkout
python3 /seed/scan.py /seed                                   # inside the container
```

It scans every `*.jsonl`, `*.json` and `*.md` (never `*.py`), validates the item schema, and
prints one masked line per finding followed by `scan: <files> files, <items> items, <findings>
findings`; exit 0 only when there are no findings, exit 2 when there was nothing to scan (an
empty scan is an error, not a pass). The scanner was proven on one planted fixture per
category - access key, account id, ARN, IPv4, hostname and instance id, Slack id, email, four
token shapes, private key, denylisted name and handle, excluded topic - plus three schema
fixtures (duplicate id, missing fields and a non-list `tags`, a non-kebab id and a non-JSON
line), a 301-item cap fixture and an empty directory. `test17.sh` plants its controls itself: an access key fails, a
kernel-internals item fails in a planted layer bank, a practical networking item passes in a planted layer bank and
fails as scope in a general bank, and a bank of 301 items fails the per-bank cap while one of 300 passes. Each returned exit 1 (exit 2 for the empty
directory) naming its kind; a clean control with loopback, the IMDS endpoint, an `example.com`
address and an all-letters word starting with C returned exit 0 with 0 findings. The fixtures
are not shipped;
`test17.sh` check 2 re-plants the key ones on every run.

## How `/agent/hindsight-seed.sh` consumes these files

1. Waits for `GET /health` on the API (`HINDSIGHT_SEED_API`, default `http://127.0.0.1:8888`)
   for up to `HINDSIGHT_SEED_WAIT` seconds (default 300).
2. `PUT /v1/default/banks/<bank>` with the `name` and `mission` from `banks.json` (idempotent).
3. Posts each file's items to `POST /v1/default/banks/<bank>/memories` as
   `{"items": [...], "async": true}` in batches of `HINDSIGHT_SEED_BATCH` (default 20). Every
   batch carries unique `document_id`s - the API rejects a batch with a duplicate id, and a
   stable id makes a re-post an update, not a duplicate.
4. Writes `/wd/hindsight-seed.stamp` (`HINDSIGHT_SEED_STAMP`) with the UTC time, the per-bank counts
   and the sha256 of the seed content. A later start with the same hash does nothing; a changed
   seed (an edited or added item) re-runs and updates in place. `--force` re-seeds regardless,
   `--dry-run` only reports, `--status` prints the stamp.
5. `HINDSIGHT_SEED=false` in `.env` (passed through by `run.sh`, the compose template and the
   kubernetes deployment) turns the whole step off; the memory extraction behind the API needs the
   same Bedrock credentials as the rest of the container, so on a host without them the documents
   are stored and the extracted memories arrive when credentials do.

## Adding your own items

Append lines to the bank file they belong to (or add a new bank: a new `.jsonl` file plus its
entry in `banks.json`), keep `document_id`s unique and kebab-case, run `scan.py` until it reports
0 findings, then either restart the container or run `/agent/hindsight-seed.sh` inside it - the
hash changed, so it re-seeds; existing ids update in place and new ids are added. Check the result
in the Hindsight UI (`http://hindsight.localhost:8000/`) or with
`curl -s http://127.0.0.1:8888/v1/default/banks/<bank>/stats` inside the container
(`total_documents` and `total_nodes`).
