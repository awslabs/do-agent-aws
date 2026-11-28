#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Sandbox test-load-knowledge-pack - load-knowledge-pack.sh's fail-closed manifest gate and plan,
# host-side, no sbx/Docker/KVM (it drives --plan, which calls no sbx). Each check FAILS if the
# behaviour is removed:
#   1. with a well-formed pack, --plan verifies the manifest sha and prints the four delivery steps
#      (the /wd/knowledge copy, the LogLearner ingest, the Hindsight seed, the CLAUDE.md pointer)
#   2. PLANTED CONTROL: a pack whose jsonl no longer matches its manifest sha is REFUSED before any
#      step is planned (proves the gate is real, not vacuous)
# Needs bash, python3, sha256sum.
set -u
BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
LOADER="${BASE_DIR}/to/sandbox/load-knowledge-pack.sh"
fail() { echo "Sandbox test-load-knowledge-pack FAILED: $1"; exit 1; }
[ -x "${LOADER}" ] || fail "missing or non-executable ${LOADER}"
D=$(mktemp -d); trap 'rm -rf "${D}"' EXIT
P="${D}/pack"
mkdir -p "${P}/pack" "${P}/seeds" "${P}/tools" "${P}/workstreams/demo"
printf '%s\n' '{"id":"demo-1","title":"demo","text":"hello","category":"demo","tags":["demo"]}' > "${P}/pack/testpack.jsonl"
printf '%s\n' '{}' > "${P}/seeds/banks.json"
printf '%s\n' '<!-- example-workstreams: begin -->' 'demo pointer' '<!-- example-workstreams: end -->' > "${P}/tools/claude-md-block.md"
printf '%s\n' 'demo tree file' > "${P}/workstreams/demo/README.md"
SHA=$(sha256sum "${P}/pack/testpack.jsonl" | cut -d' ' -f1)
printf '{"name":"testpack","version":"v1","sha256":"%s"}\n' "${SHA}" > "${P}/pack/manifest.json"

# 1. well-formed pack: --plan verifies and prints the four steps
OUT=$("${LOADER}" --plan demo-sbx "${P}" 2>&1); RC=$?
[ ${RC} -eq 0 ] || fail "check 1: --plan on a well-formed pack exited ${RC}: ${OUT}"
for needle in "sha256" "/wd/knowledge/testpack" "loglearner.cli ingest" "hindsight-seed.sh" "claude-md-block.md"; do
	echo "${OUT}" | grep -qF "${needle}" || fail "check 1: plan is missing '${needle}'"
done
echo "ok 1 - --plan verifies the manifest sha and prints the /wd/knowledge copy, LogLearner ingest, Hindsight seed and CLAUDE.md pointer steps"

# 2. PLANTED CONTROL: tamper the pack jsonl so it no longer matches the manifest sha -> refuse, no steps
printf '%s\n' '{"id":"demo-2","title":"tampered","text":"x"}' >> "${P}/pack/testpack.jsonl"
OUT2=$("${LOADER}" --plan demo-sbx "${P}" 2>&1); RC2=$?
[ ${RC2} -ne 0 ] || fail "check 2 (control): a tampered pack must be refused, but --plan exited 0: ${OUT2}"
echo "${OUT2}" | grep -qi "manifest sha256 mismatch" || fail "check 2 (control): refusal did not name the sha mismatch: ${OUT2}"
echo "${OUT2}" | grep -qF "/wd/knowledge/testpack" && fail "check 2 (control): a step was planned despite the sha mismatch (gate is not fail-closed)"
echo "ok 2 - planted control: a pack whose jsonl no longer matches its manifest sha is refused before any step is planned"

echo "Sandbox test-load-knowledge-pack succeeded"
