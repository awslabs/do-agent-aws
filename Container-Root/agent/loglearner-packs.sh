#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# LogLearner - load the image's default knowledge seed into the runtime's global knowledge bank, the store the
# PreToolUse hook (/agent/loglearner-hook.sh) delivers from and /agent/recall.sh searches.
#
# The seed (/seed, Container-Root/seed/README.md) is the curated, scanned default knowledge the Hindsight memory
# is also seeded with: one JSONL file per bank listed in /seed/banks.json (general AWS, container and agent-ops
# knowledge; starter rules). Two ways in, both through `python3 -m loglearner.pack ingest`, which is idempotent: the
# same bytes are a no-op, a record already in the bank (same text) is skipped, a record whose id is already there with
# new text replaces it with a history entry - the loader deletes nothing. The one removal is AGENT_KNOWLEDGE=false's,
# below.
#   - the packs the image ships (LOGLEARNER_PACKS_DIR, default /opt/loglearner-packs: <name>.jsonl +
#     <name>.manifest.json; the image ships the public example pack gpu-cluster-basics) are in the loader's own
#     schema: each is ingested as it is, the loader verifying the manifest's sha256 (fail-closed: a mismatch loads
#     nothing), and the /seed banks a manifest names (hindsight_banks, optional; gpu-cluster-basics names none) are
#     not converted from /seed as well;
#   - every other /seed bank is converted to the loader's simple schema (id, title, text, category, tags,
#     confidence, source) and ingested.
# Then, after those defaults and whatever AGENT_KNOWLEDGE says:
#   - the group's shared pack from S3 (docs/manual/memory.md "A shared knowledge base for a group"), only while LOGLEARNER_S3_BUCKET
#     is set: the runtime's own /opt/loglearner/scripts/loglearner-pull.sh fetches <prefix>/<pack>/latest.json, that
#     version's manifest.json and instincts.jsonl, checks the sha256 and loads it with the same loader (fail-closed: a
#     mismatch leaves the bank as it is; the same version again is a no-op). It never writes to S3, and a failed pull is
#     one line - the start goes on;
#   - the packs imported on the Knowledge transfer page (/agent/knowledge-transfer.py, docs/manual/memory.md "Moving knowledge
#     between instances"), kept in KNOWLEDGE_IMPORTED_DIR: each one's LogLearner file the same way, against its
#     manifest's sha256 (fail-closed), so an import survives the restart. Their Hindsight documents are
#     knowledge-transfer.py load's (startup.sh, once the memory API is up).
# The PreToolUse hook then delivers the matching rules into the agent's Edit, Write and Bash calls.
#
# Run by startup.sh at every start BEFORE the UIs and the agent tmux session, so the bank is complete before the
# first session's first tool call and before the dashboard's own starter-rule ingest (which then finds every
# record in place). Not gated by UI_START: the hook and the command-line tools are not UIs. Never fails the
# start: every problem is one line on stdout and exit 0.
#
# Settings (environment):
#   LOGLEARNER_SEED_DIR     - the seed directory (default /seed); its banks.json names the files to load
#   LOGLEARNER_SEED_PACKS   - override: space-separated pack files to load instead; "none" loads no seed bank (the
#                             shipped packs below load either way: LOGLEARNER_PACKS_DIR and AGENT_KNOWLEDGE
#                             govern those)
#   LOGLEARNER_PACKS_DIR    - the shipped packs (default /opt/loglearner-packs; an empty directory loads none)
#   AGENT_KNOWLEDGE         - false loads no shipped pack (the default knowledge switch, .env) and takes the
#                             records an earlier start loaded from one back out of the bank - every other line of the
#                             bank kept byte for byte, the pack's entry dropped from the bank's install ledger, so a
#                             later start with it true loads the pack again. The banks a pack covers are still not
#                             converted from /seed
#   KNOWLEDGE_IMPORTED_DIR  - the imported packs (default ${KNOWLEDGE_DIR:-/wd/knowledge}/imported; absent loads none)
#   LOGLEARNER_S3_BUCKET    - the group's shared pack is pulled from this bucket at every start; empty (the default,
#                             .env) pulls nothing. With it: LOGLEARNER_S3_PREFIX (default loglearner/packs),
#                             LOGLEARNER_PACK (default aws-default), LOGLEARNER_PACK_VERSION (default latest: the
#                             version latest.json names); the container's own AWS access reads the bucket
#   and the layout in /agent/loglearner-env.sh (LOGLEARNER_DIR, INSTINCTS_JSON, ...)

# shellcheck source=loglearner-env.sh
. "$(dirname "$0")/loglearner-env.sh"
LOGLEARNER_SEED_DIR=${LOGLEARNER_SEED_DIR:-/seed}
LOGLEARNER_PACKS_DIR=${LOGLEARNER_PACKS_DIR:-/opt/loglearner-packs}
KNOWLEDGE_IMPORTED_DIR=${KNOWLEDGE_IMPORTED_DIR:-${KNOWLEDGE_DIR:-/wd/knowledge}/imported}

if [ ! -f "${LOGLEARNER_DIR}/loglearner/pack.py" ]; then
	echo "loglearner-packs: no pack loader at ${LOGLEARNER_DIR}/loglearner/pack.py - nothing loaded"
	exit 0
fi
if [ -z "${LOGLEARNER_SEED_PACKS}" ]; then
	LOGLEARNER_SEED_PACKS=$(python3 - "${LOGLEARNER_SEED_DIR}" "${LOGLEARNER_PACKS_DIR}" << 'PY' 2>/dev/null
import glob, json, os, sys
d, packs = sys.argv[1:3]
# the /seed banks a shipped pack carries (its manifest's hindsight_banks) come from the pack, not from here
covered = set()
for m in glob.glob(os.path.join(packs, "*.manifest.json")):
    try:
        covered |= set(json.load(open(m)).get("hindsight_banks") or [])
    except (OSError, ValueError):
        pass
for bank in json.load(open(os.path.join(d, "banks.json"))):
    if bank not in covered:
        print(os.path.join(d, bank + ".jsonl"))
PY
)
fi
if [ -z "${LOGLEARNER_SEED_PACKS}" ] || [ "${LOGLEARNER_SEED_PACKS}" == "none" ]; then
	echo "loglearner-packs: no seed packs (LOGLEARNER_SEED_PACKS=${LOGLEARNER_SEED_PACKS:-unset}, ${LOGLEARNER_SEED_DIR}/banks.json unreadable or empty) - no seed bank loaded"
	LOGLEARNER_SEED_PACKS=""
fi
mkdir -p "$(dirname "${INSTINCTS_JSON}")" "${LOGLEARNER_UCB_DIR}" 2> /dev/null \
	|| { echo "loglearner-packs: cannot create $(dirname "${INSTINCTS_JSON}") - nothing loaded"; exit 0; }

report()
{
	# report <name> - the loader's JSON summary on stdin as one line
	python3 -c 'import json, sys
t = sys.stdin.read()
try:
    d = json.loads(t)
    print("loglearner-packs: %s -> %s: %s" % (sys.argv[1], sys.argv[2], "no-op (already loaded)" if d.get("noop") else
          "added %d, updated %d, skipped %d (bank total %d)" % (d["added"], d["updated"], d["skipped"], d["total"])))
except Exception:
    print("loglearner-packs: %s not loaded: %s" % (sys.argv[1], " ".join(t.split())[:300]))' "$1" "${INSTINCTS_JSON}"
}

load_imported()
{
	# the LogLearner file of every pack kept in KNOWLEDGE_IMPORTED_DIR (a pack of Hindsight documents only has none), with
	# its manifest - the loader checks the sha256 and loads nothing on a mismatch; the same bytes again are a no-op.
	# Plain files only, and a manifest whose name, version and file name agree
	for MANIFEST in "${KNOWLEDGE_IMPORTED_DIR}"/*.manifest.json; do
		[ -f "${MANIFEST}" ] && [ ! -L "${MANIFEST}" ] || continue
		PACK=${MANIFEST%.manifest.json}.jsonl
		[ -f "${PACK}" ] && [ ! -L "${PACK}" ] || continue
		NAME_VERSION=$(python3 -c 'import json, re, sys
m = json.load(open(sys.argv[1]))
n, v = str(m.get("name")), str(m.get("version"))
if re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", n) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}", v) and sys.argv[1].endswith("/" + n + ".manifest.json"):
    print(n, v)' "${MANIFEST}" 2> /dev/null)
		if [ -z "${NAME_VERSION}" ]; then
			echo "loglearner-packs: ${MANIFEST}: no name and version that match its file name - the imported pack is skipped"
			continue
		fi
		( cd "${LOGLEARNER_DIR}" && python3 -m loglearner.pack ingest --pack "${PACK}" --bank "${INSTINCTS_JSON}" \
			--name "${NAME_VERSION% *}" --version "${NAME_VERSION#* }" --manifest "${MANIFEST}" ) 2>&1 | report "imported pack ${NAME_VERSION% *}"
	done
}

load_shared()
{
	# the group's shared pack from S3, only while LOGLEARNER_S3_BUCKET is set: the runtime's loglearner-pull.sh (it checks
	# the sha256 against the version's manifest and loads with the same loader; a mismatch leaves the bank as it is). Two
	# minutes at most, so an unreachable bucket costs the start one line, not the start
	[ -n "${LOGLEARNER_S3_BUCKET}" ] || return 0
	local PULL="${LOGLEARNER_DIR}/scripts/loglearner-pull.sh" OUT RC
	if [ ! -f "${PULL}" ]; then
		echo "loglearner-packs: LOGLEARNER_S3_BUCKET is set but ${PULL} is missing - no shared pack"
		return 0
	fi
	OUT=$(LOGLEARNER_BANK="${INSTINCTS_JSON}" LOGLEARNER_REPO="${LOGLEARNER_DIR}" timeout 120 bash "${PULL}" 2>&1)
	RC=$?
	# a load ends in the loader's JSON summary (indented, several lines); a pull that loads nothing says why in words
	if [ "${RC}" == "0" ] && printf '%s' "${OUT}" | python3 -c 'import json, sys; json.loads(sys.stdin.read())' 2> /dev/null; then
		printf '%s' "${OUT}" | report "shared pack ${LOGLEARNER_PACK:-aws-default} from s3://${LOGLEARNER_S3_BUCKET}"
	else
		echo "loglearner-packs: shared pack ${LOGLEARNER_PACK:-aws-default} from s3://${LOGLEARNER_S3_BUCKET} (rc ${RC}): $(printf '%s' "${OUT}" | tr '\n' ' ' | cut -c1-300)"
	fi
}

for SEED in ${LOGLEARNER_SEED_PACKS}; do
	if [ ! -f "${SEED}" ]; then
		echo "loglearner-packs: ${SEED} not found - skipped"
		continue
	fi
	PACK_TMP=$(mktemp /tmp/loglearner-pack-XXXXXX.jsonl)
	# The seed's Hindsight document schema -> the pack loader's simple schema; the same mapping the dashboard's
	# starter-rule ingest uses (/agent/loglearner-serve.sh), so a record converted by either has the same text
	# and is the same record to the loader
	if python3 - "${SEED}" "${PACK_TMP}" << 'PY'
import json, re, sys
src, dst = sys.argv[1], sys.argv[2]
n = 0
with open(src, encoding="utf-8") as f, open(dst, "w", encoding="utf-8") as out:
    for line in f:
        if not line.strip():
            continue
        it = json.loads(line)
        text = str(it.get("content", "")).strip()
        if not it.get("document_id") or not text:
            continue
        m = re.search(r"confidence:\s*(high|medium|med|low)", text, re.I)
        tags = [str(t) for t in (it.get("tags") or []) if str(t) != "rule"]
        rec = {"id": it["document_id"], "title": str(it.get("context", "")).strip(), "text": text,
               "category": tags[0] if tags else "general", "tags": tags, "source": "do-agent-aws seed",
               "confidence": (m.group(1).lower() if m else "med")}
        out.write(json.dumps(rec) + "\n")
        n += 1
print(f"loglearner-packs: {n} record(s) prepared from {src}")
PY
	then
		STEM=$(basename "${SEED}" .jsonl)
		( cd "${LOGLEARNER_DIR}" && python3 -m loglearner.pack ingest --pack "${PACK_TMP}" --bank "${INSTINCTS_JSON}" \
			--name "seed-${STEM}" --version "$(sha256sum "${SEED}" | cut -c1-12)" ) 2>&1 | report "${STEM}"
	else
		echo "loglearner-packs: could not convert ${SEED} - skipped"
	fi
	rm -f "${PACK_TMP:?}"
done

# the shipped packs, as shipped: the loader checks each against its manifest's sha256 before it writes. They are
# default knowledge, so AGENT_KNOWLEDGE=false loads none - and takes back out of the bank what an earlier start
# loaded from them (the records carry the pack's name, the name its manifest gives), so neither the hook nor
# recall.sh serves one
if [ "${AGENT_KNOWLEDGE:-true}" == "false" ]; then
	python3 - "${INSTINCTS_JSON}" "${LOGLEARNER_PACKS_DIR}" "${LOGLEARNER_DIR}" << 'PY' 2>&1 | sed 's/^/loglearner-packs: /'
import glob, json, os, sys, tempfile
bank, packs, runtime = sys.argv[1:4]
sys.path.insert(0, runtime)
try:
    from loglearner.pack import INSTALLED_FILE
except Exception:
    INSTALLED_FILE = ".installed-packs.json"
names = set()
for m in glob.glob(os.path.join(packs, "*.manifest.json")):
    try:
        names.add(str(json.load(open(m))["name"]))
    except (OSError, ValueError, KeyError, TypeError):
        pass


def from_pack(line):
    try:
        r = json.loads(line)
    except ValueError:
        return False   # a line this step cannot read stays as it is
    return isinstance(r, dict) and isinstance(r.get("pack"), dict) and r["pack"].get("name") in names


def replace(path, text):
    fd, tmp = tempfile.mkstemp(prefix=".packs-off.", dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)
    os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)


try:
    with open(bank, encoding="utf-8", errors="surrogateescape") as f:
        lines = f.read().splitlines(keepends=True)
except FileNotFoundError:
    lines = []
keep = [l for l in lines if not from_pack(l)]
if len(keep) != len(lines):
    replace(bank, "".join(keep))
ledger = os.path.join(os.path.dirname(bank), INSTALLED_FILE)
try:
    entries = json.load(open(ledger))
except (OSError, ValueError):
    entries = None
if isinstance(entries, list) and any(isinstance(e, dict) and e.get("name") in names for e in entries):
    replace(ledger, json.dumps([e for e in entries if not (isinstance(e, dict) and e.get("name") in names)], indent=1) + "\n")
print("shipped packs not loaded (AGENT_KNOWLEDGE=false); %d record(s) an earlier start loaded from them taken "
      "out of %s, %d line(s) kept" % (len(lines) - len(keep), bank, sum(1 for l in keep if l.strip())))
PY
	load_shared
	load_imported
	exit 0
fi
for MANIFEST in "${LOGLEARNER_PACKS_DIR}"/*.manifest.json; do
	[ -f "${MANIFEST}" ] || continue
	PACK=${MANIFEST%.manifest.json}.jsonl
	NAME_VERSION=$(python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); print(m["name"], m["version"])' "${MANIFEST}" 2> /dev/null)
	if [ ! -f "${PACK}" ] || [ -z "${NAME_VERSION}" ]; then
		echo "loglearner-packs: ${MANIFEST}: no pack beside it or no name/version - skipped"
		continue
	fi
	( cd "${LOGLEARNER_DIR}" && python3 -m loglearner.pack ingest --pack "${PACK}" --bank "${INSTINCTS_JSON}" \
		--name "${NAME_VERSION% *}" --version "${NAME_VERSION#* }" --manifest "${MANIFEST}" ) 2>&1 | report "${NAME_VERSION% *}"
done
load_shared
load_imported
exit 0
