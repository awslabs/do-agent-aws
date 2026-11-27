#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# LogLearner dashboard - serve the vendored read-only dashboard over the agent's own Claude Code
# session corpus, keeping its index fresh.
#
# Started by /agent/ui-start.sh (UI_LOGLEARNER=true) through start_ui, so this script is the
# session leader ui-stop.sh signals (it execs the dashboard by its ABSOLUTE path at the end, so the
# pid stays the same and its command line still names loglearner for ui-status.sh/ui-stop.sh): the indexer refresh loop runs in the background of this same
# process group and the dashboard in the foreground, and a TERM to the group takes both down.
# The dashboard (/opt/loglearner/dashboard/app.py, stdlib-only) binds 127.0.0.1 only and is
# GET-only; it reads the sqlite index that /opt/loglearner/dashboard/indexer.py builds from
# ${HOME}/.claude/projects/**/*.jsonl - inside the container that is /home/agent/.claude/projects, the
# agent's own sessions (persisted agent state), never opened for write. Its Hindsight panel
# proxies 127.0.0.1:8888, the hindsight-api this container serves.
#
# The vendored tree is LogLearner's gated minimal runtime (/opt/loglearner/VENDORED.md): its state -
# the sqlite index, the knowledge banks its instinct library and tile read, the bandit ledgers - is
# kept under LOGLEARNER_STATE on the /wd volume, and on every start the harness's starter rules
# (/seed/loglearner-rules.jsonl, the same items the hindsight seed loads into the loglearner-rules
# bank) are loaded into the runtime's global instinct bank through its own pack loader (idempotent
# by id: a re-run changes nothing). Its Hindsight panel reads the loglearner-rules bank of the
# hindsight-api this container serves. /api/tile.json is the runtime's status contract.
#
# Settings (environment):
#   UI_PORT_LOGLEARNER          - dashboard port (default 7777)
#   LOGLEARNER_DIR              - the vendored tree (default /opt/loglearner)
#   LOGLEARNER_STATE            - state root (default /wd/loglearner, on the /wd volume)
#   LOGLEARNER_DB               - the sqlite index (default ${LOGLEARNER_STATE}/index.db)
#   LOGLEARNER_INDEX_INTERVAL   - seconds between index refreshes (default 300; 0 = index once)
#   LOGLEARNER_SEED_PACK        - starter rules to load into the instinct bank (default
#                                 /seed/loglearner-rules.jsonl; empty or missing = load nothing)
#   LOGLEARNER_HINDSIGHT_BANK   - the hindsight bank the dashboard's Hindsight panel shows
#                                 (default loglearner-rules)
#   HINDSIGHT_API             - the memory API as this server reaches it (default
#                               http://127.0.0.1:${UI_PORT_HINDSIGHT_API:-8888})
#   LOGLEARNER_HINDSIGHT_LINK_BASE - the memory API as the browser reaches it, the base of every link the
#                               pages carry (default /memory-api, the home proxy's route on the page's own host)
#   HOME                        - whose ~/.claude/projects is indexed (default /home/agent)

export HOME=${HOME:-/home/agent}
UI_PORT_LOGLEARNER=${UI_PORT_LOGLEARNER:-7777}
LOGLEARNER_DIR=${LOGLEARNER_DIR:-/opt/loglearner}
LOGLEARNER_STATE=${LOGLEARNER_STATE:-/wd/loglearner}
LOGLEARNER_DB=${LOGLEARNER_DB:-${LOGLEARNER_STATE}/index.db}
LOGLEARNER_INDEX_INTERVAL=${LOGLEARNER_INDEX_INTERVAL:-300}
LOGLEARNER_SEED_PACK=${LOGLEARNER_SEED_PACK-/seed/loglearner-rules.jsonl}
# the runtime's own settings (START.md in the vendored tree), all under the state root
export LOGLEARNER_DB
export LOGLEARNER_BANKS_DIR=${LOGLEARNER_BANKS_DIR:-${LOGLEARNER_STATE}/banks}
export INSTINCTS_JSON=${INSTINCTS_JSON:-${LOGLEARNER_BANKS_DIR}/global/instincts.jsonl}
# the dashboard's Learnings tab indexes LOGLEARNER_LEARNINGS_DIR: the global bank, so the starter rules show
export LOGLEARNER_LEARNINGS_DIR=${LOGLEARNER_LEARNINGS_DIR:-${LOGLEARNER_BANKS_DIR}/global}
export FLEET_LEARNINGS_DIR=${FLEET_LEARNINGS_DIR:-${LOGLEARNER_BANKS_DIR}}
export LOGLEARNER_UCB_DIR=${LOGLEARNER_UCB_DIR:-${LOGLEARNER_STATE}/output}
export LOGLEARNER_HINDSIGHT_BANK=${LOGLEARNER_HINDSIGHT_BANK:-loglearner-rules}
# The memory API, two addresses: HINDSIGHT_API is where the dashboard's server reaches it (this container's loopback,
# on the port ui-start.sh runs it on), LOGLEARNER_HINDSIGHT_LINK_BASE is where the person's BROWSER reaches it, used for
# every link the pages carry - /memory-api on the page's own host, which the home proxy serves on the home listener and on
# the dashboard's host route alike (home-render.sh, memory_api_locations). A link at the server's address would open, on
# a shared host, somebody else's memory API, or nothing: the API publishes no port
export HINDSIGHT_API=${HINDSIGHT_API:-http://127.0.0.1:${UI_PORT_HINDSIGHT_API:-8888}}
# the /memory-api route exists only while the memory API is on; with it off (UI_HINDSIGHT=false) and HINDSIGHT_API
# pointed elsewhere, the links keep the server address, which the dashboard's own 404 would otherwise replace
if [ "${UI_HINDSIGHT:-true}" == "true" ]; then
	export LOGLEARNER_HINDSIGHT_LINK_BASE=${LOGLEARNER_HINDSIGHT_LINK_BASE:-/memory-api}
fi

[ -f "${LOGLEARNER_DIR}/dashboard/app.py" ] || { echo "loglearner-serve: no dashboard at ${LOGLEARNER_DIR}/dashboard/app.py" >&2; exit 1; }
mkdir -p "$(dirname "${LOGLEARNER_DB}")" "${LOGLEARNER_BANKS_DIR}/global" "${LOGLEARNER_UCB_DIR}" \
	|| { echo "loglearner-serve: cannot create the state directories under ${LOGLEARNER_STATE}" >&2; exit 1; }
cd "${LOGLEARNER_DIR}" || exit 1

# Starter rules into the instinct bank: the seed's loglearner-rules items, converted to the pack
# loader's simple schema (id, title, text, category, tags, confidence) and ingested by the runtime's
# own `loglearner.pack ingest` (idempotent by id). A failing ingest is logged and does not stop the
# dashboard - an empty instinct library is a valid, if poorer, state.
if [ -n "${LOGLEARNER_SEED_PACK}" ] && [ -f "${LOGLEARNER_SEED_PACK}" ]; then
	PACK_TMP=$(mktemp /tmp/loglearner-pack-XXXXXX.jsonl)
	if python3 - "${LOGLEARNER_SEED_PACK}" "${PACK_TMP}" << 'PY'
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
print(f"loglearner-serve: {n} starter rule(s) prepared from {src}")
PY
	then
		PACK_VERSION=$(sha256sum "${LOGLEARNER_SEED_PACK}" | cut -c1-12)
		python3 -m loglearner.pack ingest --pack "${PACK_TMP}" --bank "${INSTINCTS_JSON}" \
			--name do-agent-aws-seed --version "${PACK_VERSION}" \
			|| echo "loglearner-serve: starter rule ingest failed (rc=$?); the instinct library stays as it was"
	else
		echo "loglearner-serve: could not prepare the starter rules from ${LOGLEARNER_SEED_PACK}; skipping the ingest"
	fi
	rm -f "${PACK_TMP:?}"
else
	echo "loglearner-serve: no starter rules at ${LOGLEARNER_SEED_PACK:-<unset>} - instinct bank left as is"
fi

# First index before the dashboard answers, so the first page is not "no index yet". A failing
# indexer is logged and does not stop the dashboard: an empty corpus is a valid state.
echo "loglearner-serve: indexing ${HOME}/.claude/projects -> ${LOGLEARNER_DB}"
python3 dashboard/indexer.py --db "${LOGLEARNER_DB}" || echo "loglearner-serve: indexer failed (rc=$?); serving the existing index"

if [ "${LOGLEARNER_INDEX_INTERVAL}" -gt 0 ] 2>/dev/null; then
	(
		while sleep "${LOGLEARNER_INDEX_INTERVAL}"; do
			python3 dashboard/indexer.py --db "${LOGLEARNER_DB}" > /dev/null 2>&1 \
				|| echo "loglearner-serve: periodic indexer run failed (rc=$?)"
		done
	) &
fi

echo "loglearner-serve: dashboard on 127.0.0.1:${UI_PORT_LOGLEARNER} (index ${LOGLEARNER_DB}, refresh every ${LOGLEARNER_INDEX_INTERVAL}s)"
exec python3 "${LOGLEARNER_DIR}/dashboard/app.py" --port "${UI_PORT_LOGLEARNER}"
