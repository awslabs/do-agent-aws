# Sharing knowledge between harnesses

A harness keeps what it knows in two stores. This page shows how to move that knowledge from one harness to another
with the Knowledge transfer page, and how a group of harnesses can share one body of knowledge today.

- **The LogLearner bank** (`/wd/loglearner/banks/global/instincts.jsonl`, one record per line). The PreToolUse hook
  hands matching records to the agent before its Edit, Write and Bash calls, and `/agent/recall.sh` searches them. It
  holds the default knowledge every start loads and every rule `/agent/learn.sh` banked.
- **The Hindsight memory banks**, behind the memory API. Each bank holds documents and the facts extracted from them.
  The agent's own sessions land in `coding-agent::<project>`; the default seed fills two more.

## Export and import on the Knowledge transfer page

Open the Memory tile on the home page and follow its **Knowledge transfer** link (`/knowledge/` on the home port,
through the same SSH tunnel as every other page). The page lists both stores with their counts.

**Export.** Tick the LogLearner bank, any Hindsight banks, or both. A tag, a range of days or a search narrows the
selection: a LogLearner record's day is the day it was banked or loaded, a Hindsight document's the day it was
retained. To pick single records, type a search and press **Find records**: the page lists the matching records of the
ticked stores, a LogLearner record by its id or its title and a Hindsight document by its id (the memory API's own
search). Tick the ones you want, and the pack holds exactly those. Name the pack and press Export. One `.tar.gz` file
downloads. It holds three files, the shape `/agent/loglearner-packs.sh` loads:

| File | What it holds |
|---|---|
| `<name>.jsonl` | the LogLearner records, as the bank holds them |
| `<name>.hindsight.jsonl` | one Hindsight document per line with its bank, its chunks and its extracted facts |
| `<name>.manifest.json` | the name, the version (the export's time), the record counts, each file's sha256, the image build and memory API version it came from, and what the scrub gate ran with |

This image's own default knowledge stays out of a pack unless you tick **Include this image's default knowledge**:
the records of its packs (the packs it ships in `/opt/loglearner-packs`, such as the example pack `gpu-cluster-basics`,
and the `seed-*` packs) and its seed banks' documents. Every harness of the same image already has them. The loader
also replaces a record of the same id that has other content, so a pack from an older image would put the older copies
back on a newer one. Records you find and tick by id travel either way. The export result says how many it left out,
and a harness that holds nothing else is told so. A pack cannot take the name of a pack the image ships: such an export
or import is refused.

A Hindsight bank is read through the memory API's own document transfer. The facts travel as they are and are embedded
again where they land, so neither side calls a model. Bank configuration, mental models, directives and consolidated
observations are not part of a pack. The receiving bank consolidates on its own.

A rule this harness banked itself travels as `<id>-<hash>`, for example `kb-0003-8f3a2c1d9e`. `learn.sh` numbers rules
per bank, and a pack record replaces the record of the same id in the bank it is loaded into. A plain `kb-0003` from one
harness would replace another harness's own `kb-0003`.

**The scrub gate.** Every export passes the LogLearner runtime's export gate before a byte of it is written, the same
gate the runtime's dashboard uses for its own export. With a scrub config (`LOGLEARNER_SCRUB_CONFIG`, or
`state/scrub-patterns.json` under `/opt/loglearner`) the gate applies all of it: its replacements and numbered classes
rewrite what they match, and its detectors look for secrets. Without one it runs the detectors the runtime ships, which
look for the shapes of cloud access keys, tokens and private keys and rewrite nothing. The runtime's own classes for
home directories apply either way, except to the image's own `hindsight` account, whose home is the container's layout. A detector hit stops the whole export, and the page names each record and the class,
never the value. Edit or remove the record, or leave it out of the selection. A `LOGLEARNER_SCRUB_CONFIG` that names no
file refuses every export. The manifest records which gate ran and what it replaced.

**Import.** Choose a pack file and press **Check**. Every file is checked against the sha256 its manifest records. A
pack that does not match is refused whole, with the reason. A pack that matches gets a summary of what the import would
do, and nothing is written yet:

- its LogLearner records: how many the runtime's loader would add, which records of the same id it would replace, and
  how many are already in the bank. The same pack loaded twice is a no-op;
- per Hindsight bank: how many documents are new and which the bank already has;
- this image's own default records the pack would replace, which happens only with a pack from another image that
  carries them, and per bank the documents it already has that are this image's own seed documents, which replace
  would overwrite.

Then choose what happens to a document a bank already has and press **Import**: keep the bank's (skip, the default),
replace it with the pack's, or add the pack's beside it under a new id. A bank the harness does not have yet is created
with the name the pack gives it. The page shows what each store took.

**Kept, and loaded again at every start.** An imported pack is kept in `/wd/knowledge/imported/`, the
`wd/knowledge/imported/` folder of the checkout on the host. A pack of the same name replaces the one kept before. At
every start, after the default knowledge, `loglearner-packs.sh` loads the kept LogLearner files and
`knowledge-transfer.py load` the kept Hindsight documents, with skip. A pack loaded before is left alone while its
banks still hold every one of its documents by id; a bank that lost one gets it back. A kept pack that cannot be read
or loaded is named in `wd/ui/knowledge-load.log`, and the other packs still load. So an import survives a restart, a
new memory database (`AGENT_STATE_PATH_EXTERNAL` empty) and a fresh LogLearner state. `knowledge-files.py verify`, which restores
the default knowledge copy before every session, never touches this folder. On kubernetes `/wd` is an `emptyDir`, so
a kept pack lasts as long as the pod. The setup doctor's `packages` row (`/agent/doctor.sh --check packages`) lists a
kept pack as `imported <name> <version> (<records> records, loaded)` once the ledger of each of its stores carries it,
and names one the loads have not taken with the two load commands as the remedy.

## A shared knowledge base for a group of harnesses

Today a group shares knowledge as **one pack that every harness loads at its start**. The pack is a set of plain files,
so anything that can put files in a folder can share it.

1. On the harness whose knowledge the group wants, export a pack. Name it after that harness, for example `team-a`.
   Packs of different names live side by side. A pack of the same name replaces the earlier version.
2. Unpack it where the group keeps shared files:
   - **git**: commit `team-a.jsonl`, `team-a.hindsight.jsonl` and `team-a.manifest.json` to a private repository the
     group can read. The files are text, so a new version shows as a diff.
   - **S3**: publish it for the pull below.
3. With git, put the files into `wd/knowledge/imported/` on each harness, or import the `.tar.gz` on its Knowledge
   transfer page. The next start loads them. A pack that has not changed since is a no-op at every later start.

### From S3, at every start

With `LOGLEARNER_S3_BUCKET` set (docs/manual/install.md "Settings"; empty, the default, is off), every start runs the runtime's
`/opt/loglearner/scripts/loglearner-pull.sh` after the default knowledge. It reads one LogLearner pack from
`s3://<bucket>/<LOGLEARNER_S3_PREFIX>/<LOGLEARNER_PACK>/` with the container's own AWS access: the version
`LOGLEARNER_PACK_VERSION` names, or the one its `latest.json` names. It checks that version's `instincts.jsonl` against
its `manifest.json`, loads it with the same loader, and never writes to S3. A file whose sha256 differs leaves the bank
as it was, and the same version again is a no-op. Empty prefix, pack and version mean `loglearner/packs`, `aws-default`
and `latest`.

The pull carries the LogLearner half of a pack. To publish `team-a`, unpack the exported file and copy its two
LogLearner files under a version, then point `latest.json` at it:

```bash
tar xzf team-a-<version>.tar.gz
aws s3 cp team-a.jsonl s3://<bucket>/loglearner/packs/team-a/<version>/instincts.jsonl
aws s3 cp team-a.manifest.json s3://<bucket>/loglearner/packs/team-a/<version>/manifest.json
echo '{"version": "<version>"}' | aws s3 cp - s3://<bucket>/loglearner/packs/team-a/latest.json
```

Then each harness of the group sets `LOGLEARNER_S3_BUCKET=<bucket>` and `LOGLEARNER_PACK=team-a` in its `.env.local`.

### Worked example: two harnesses on one host

Harness A runs from `~/harness-a` with its home on port 8000; harness B from `~/harness-b` with `PORT_EXTERNAL_HOME`
and the other published ports moved in its `.env.local` (docs/manual/install.md "Settings"), its home on port 8100.

1. In A's browser tab, `http://localhost:8000/knowledge/`: name the pack `team-a`, keep every box ticked, press Export.
   `team-a-<version>.tar.gz` downloads, and the page lists each file with its record count and sha256. The pack holds
   what A learned and remembered beyond its image's default knowledge, which B already has.
2. In B's tab, `http://localhost:8100/knowledge/`: choose that file and press Check. The page says how many LogLearner
   records B would add and, per Hindsight bank, which documents B already has. Keep the default choice and press
   Import.
3. Restart B. Its start log reads `loglearner-packs: imported pack team-a -> ...: no-op (already loaded)`, and
   `wd/ui/knowledge-load.log` reads "already in the memory API".

The same from the command line, with the container names from each checkout's `.env`:

```bash
docker exec <container-a> python3 /agent/knowledge-transfer.py export /wd/team-a.tar.gz --name team-a
cp ~/harness-a/wd/team-a.tar.gz ~/harness-b/wd/
docker exec <container-b> python3 /agent/knowledge-transfer.py preview /wd/team-a.tar.gz
docker exec <container-b> python3 /agent/knowledge-transfer.py import /wd/team-a.tar.gz
```

`export` takes `--store loglearner|hindsight`, `--bank <bank>` (each repeatable), `--tag <tag>`, `--since YYYY-MM-DD`,
`--until YYYY-MM-DD`, `--search <text>`, `--id <id>` (repeatable) and `--include-defaults`, the same selection as the page; `records
--search <text>` lists what the page's finder lists; `import` takes `--on-conflict skip|replace|new-id`.

## What this does not do

- **No hub.** Every harness keeps its own copy, and a new version reaches a harness at its next import or start. Records
  removed from a pack are not removed where it was loaded before. A knowledge service that every harness of a group
  reads and writes live is the designed next step; its design decisions are still open.
- **An export leaves its archive.** An export of a Hindsight bank leaves the bank's transfer archive in the memory API's
  file storage, as the API's own export does, until the API's retention removes the export operation.
- **An import never deletes.** With skip it only adds. With replace it rewrites a bank's document of the same id, and
  with new-id it adds the pack's copy beside it.
- **One pack name per source.** Two harnesses exporting under the same name replace each other's kept pack where both
  are imported.
- **An import rewrites the bank file.** The runtime's loader writes the LogLearner bank whole, as it does at every
  start, so a rule `learn.sh` banks in the same second can be lost. Import while no session is banking a rule.
- **The S3 pull carries the LogLearner half.** The Hindsight documents of a pack travel by git or by an import.
