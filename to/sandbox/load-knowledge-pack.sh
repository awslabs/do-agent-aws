#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# load-knowledge-pack.sh - deliver an external knowledge pack into a RUNNING do-agent-aws sandbox.
# The pack itself stays OUT of this repository; this script is the repeatable mechanism an operator
# runs with a pack of their own, so the sandbox agent gets that pack's knowledge and memory.
# Idempotent: re-running updates in place and never duplicates.
#
# Usage: to/sandbox/load-knowledge-pack.sh [--plan] <sandbox-name> <pack-dir>
#   <pack-dir> is the extracted pack: pack/<name>.jsonl + pack/manifest.json (the LogLearner pack),
#   seeds/banks.json + seeds/<bank>.jsonl (the Hindsight seed), tools/claude-md-block.md, and the
#   document tree (workstreams/..., db/..., etc.). --plan prints the steps and calls nothing.
#
# What it does:
#   0. verify pack/manifest.json's sha256 against pack/<name>.jsonl (fail-closed, before any copy)
#   1. the read-only document copy -> /wd/knowledge/<name> (replaced whole); the agent greps it,
#      the shipped CLAUDE.md "Default knowledge" block already points every diagnosis at /wd/knowledge
#   2. LogLearner ingest of pack/<name>.jsonl into the global bank (the PreToolUse hook + recall.sh)
#   3. Hindsight seed of seeds/ into the banks seeds/banks.json names (its own stamp/state, so the home page's
#      memory row keeps reporting the harness's own seed) - extraction needs the sandbox's Bedrock
#      proxy, which the sandbox layer's /etc/sandbox-persistent.sh now keeps coherent
#   4. the pack's CLAUDE.md block appended to /root/workspace/CLAUDE.md, the sandbox WORKDIR's: a
#      headless `claude -p` fire runs outside /wd, so unlike the docker target (where the pointer goes
#      into /wd/CLAUDE.md) the pointer must sit where every session reads it. Idempotent: guarded by
#      the block's `<!-- <name>: begin -->` marker, <name> being the manifest's.
# A step that fails stops the script with its number (exit 1); nothing after it runs.
set -uo pipefail

PLAN=false
[ "${1:-}" = "--plan" ] && { PLAN=true; shift; }
SBX_NAME="${1:-}"; PACK_DIR="${2:-}"
die() { echo "load-knowledge-pack: $1" >&2; exit 1; }
[ -n "${SBX_NAME}" ] && [ -n "${PACK_DIR}" ] || die "usage: load-knowledge-pack.sh [--plan] <sandbox-name> <pack-dir>"
[ -d "${PACK_DIR}" ] || die "pack dir not found: ${PACK_DIR}"
MAN="${PACK_DIR}/pack/manifest.json"
[ -f "${MAN}" ] || die "no pack/manifest.json under ${PACK_DIR}"
[ -f "${PACK_DIR}/seeds/banks.json" ] || die "no seeds/banks.json under ${PACK_DIR}"
[ -f "${PACK_DIR}/tools/claude-md-block.md" ] || die "no tools/claude-md-block.md under ${PACK_DIR}"

read -r NAME WANT < <(python3 - "${MAN}" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(m["name"], m.get("sha256", ""))
PY
) || die "cannot read pack/manifest.json"
PACK_JSONL="${PACK_DIR}/pack/${NAME}.jsonl"
[ -f "${PACK_JSONL}" ] || die "manifest names '${NAME}' but ${PACK_JSONL} is missing"

# 0. fail-closed manifest check (the loader also verifies this inside the sandbox; this refuses
#    before anything is copied in)
GOT=$(sha256sum "${PACK_JSONL}" | cut -d' ' -f1)
if [ -n "${WANT}" ] && [ "${GOT}" != "${WANT}" ]; then
	die "manifest sha256 mismatch for ${PACK_JSONL}: pack=${GOT} manifest=${WANT} - refusing (pack tampered or stale)"
fi
echo "load-knowledge-pack: pack '${NAME}', manifest sha256 ${GOT:0:12} verified"

run() {  # echo in --plan mode, execute otherwise
	if [ "${PLAN}" = true ]; then printf '  %s\n' "$*"; else "$@"; fi
}
STEP=0
step() {  # step <n> <what>: the label a failure names
	STEP=$1
	echo "load-knowledge-pack: $1/4 $2"
}
fail_step() { die "step ${STEP}/4 failed - the sandbox holds the steps before it; fix and re-run (each step is idempotent)"; }

step 1 "read-only document copy -> ${SBX_NAME}:/wd/knowledge/${NAME}"
run sbx exec "${SBX_NAME}" bash -lc "rm -rf /wd/knowledge/${NAME}.new /wd/knowledge/${NAME}" || fail_step
run sbx cp "${PACK_DIR}" "${SBX_NAME}:/wd/knowledge/${NAME}" || fail_step

step 2 "LogLearner ingest of pack/${NAME}.jsonl"
run sbx cp "${PACK_DIR}/pack" "${SBX_NAME}:/tmp/${NAME}-pack" || fail_step
run sbx exec "${SBX_NAME}" bash -lc ". /agent/loglearner-env.sh; cd /opt/loglearner && python3 -m loglearner.cli ingest --pack /tmp/${NAME}-pack/${NAME}.jsonl --bank \"\$INSTINCTS_JSON\" --name ${NAME} --version \"\$(python3 -c 'import json;print(json.load(open(\"/tmp/${NAME}-pack/manifest.json\"))[\"version\"])')\" --manifest /tmp/${NAME}-pack/manifest.json" || fail_step

step 3 "Hindsight seed of seeds/ into the ${NAME}-* banks"
run sbx cp "${PACK_DIR}/seeds" "${SBX_NAME}:/tmp/${NAME}-seeds" || fail_step
run sbx exec "${SBX_NAME}" bash -lc "HINDSIGHT_SEED_DIR=/tmp/${NAME}-seeds HINDSIGHT_SEED_STAMP=/wd/hindsight-seed-${NAME}.stamp HINDSIGHT_SEED_STATE=/wd/ui/hindsight-seed-${NAME}.state /agent/hindsight-seed.sh" || fail_step

step 4 "CLAUDE.md pointer in the sandbox WORKDIR (idempotent)"
run sbx exec "${SBX_NAME}" bash -lc "W=/root/workspace; mkdir -p \"\$W\"; grep -qF '<!-- ${NAME}: begin -->' \"\$W/CLAUDE.md\" 2>/dev/null || cat /wd/knowledge/${NAME}/tools/claude-md-block.md >> \"\$W/CLAUDE.md\"" || fail_step

if [ "${PLAN}" = true ]; then echo "load-knowledge-pack: done (plan only: nothing was run)"; else echo "load-knowledge-pack: done"; fi
