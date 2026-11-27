#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the default knowledge seed (/seed, /agent/hindsight-seed.sh, the detached launch in
# /startup.sh): a fresh container's hindsight memory holds the curated banks, posted once with stable
# document ids, opt-out with HINDSIGHT_SEED=false, and the shipped seed is clean of secrets and PII.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the script parses; the seed is well-formed: banks.json names banks, every bank has a jsonl,
#   1b. .env contract (when a checkout is at hand): HINDSIGHT_SEED=true is the default, run.sh/compose/
#      kubernetes pass it, startup.sh gates the seed on it
#      every line is {document_id, content, context, tags}, and document ids are unique per bank
#      (the API refuses duplicate ids in one async batch - a duplicate would be dropped, not seeded)
#   2. the shipped scan (/seed/scan.py) passes on the shipped seed (0 findings, exit 0), and PLANTED
#      CONTROLS: a copy with an AWS access key fails it (exit 1) - the scan can go red; a copy with a
#      kernel-internals item in a planted layer bank (layer-planted.jsonl: the seed ships no layer bank, the
#      scanner's layer rule is for any layer-*.jsonl added to it) fails it as scope; a copy with a practical
#      EFA/NCCL/NVSHMEM/NIXL item (the topics a general bank excludes whole) passes in a planted layer bank and
#      fails as scope in a general bank (harness-knowledge); a bank of 301 items fails the per-bank cap and one
#      of 300 passes;
#      the vendored LogLearner tree passes the scan's tree mode (every text file, identifiers included - the
#      build gate in install-loglearner.sh), and a planted tree carrying the internal identifier fails it; a
#      planted tree carrying a home directory (the build host's user: /home/<user>, /Users/<user>, /var/home,
#      C:\Users, in plain, doubled-slash, file://, relative or JSON-escaped form, or the encoded -home-<user>-,
#      -Users-<user>- and C--Users-<user>- directory names a vendored release once shipped in its provenance
#      table, dashboard and tests) fails it naming the file and line, one tree per shape, while the image's own
#      service and root homes (through the path and the encoded forms) and the look-alike tokens (flags, slugs,
#      URL paths, ${VAR}/home) each pass; the build gate (install-loglearner.sh) refuses such a tree naming the
#      cause, writing no command
#   3. --dry-run validates and reports without the API and without a stamp; a missing seed directory
#      and an API that never answers each exit 1 with one stderr line naming the problem
#   3b. PLANTED CONTROLS (offline, a stand-in API): items accepted but nothing extracted within the
#      watch -> a WARNING (the seed log, and the container's own log) naming the cause read from the API's log (a planted
#      ProfileNotFound), state=failed with the excerpt, acceptance still stamped, and a restart with
#      everything still pending says it again; everything extracted -> no WARNING, state=complete;
#      HINDSIGHT_SEED_EXTRACTION_WAIT=0 -> state=accepted, no wait
#   3c/3d. (stand-in API) an item's metadata reaches the API's retain request, every value as a string: a boolean as
#      "true"/"false", a number as its decimal text, a null dropped; the seed file keeps its JSON types
#   -- live, where hindsight-api is installed (the image; skipped from a bare checkout) --
#   4. against a test-local API: the seed exits 0, writes the stamp (sha256 + per-bank counts), every
#      bank from banks.json exists with its name, and the API accepted every item (one retain
#      operation per batch)
#   4b. a bank whose items carry a boolean metadata value is accepted (the API refused it with HTTP 422 before
#      the conversion, and the seed stopped there), and both banks' counts reach the stamp and the status row
#   5. a second run says already seeded and posts nothing (operations unchanged; with the extraction
#      still pending it says so and still posts nothing); HINDSIGHT_SEED=false
#      posts nothing and writes no stamp (control); --force re-posts and the stamp is rewritten
#   6b. planted control: a document deleted from a bank (fewer documents than stamped, nothing pending)
#      makes a plain run re-seed instead of trusting the stamp; the bank comes back to its count
#   6. counts (needs the LLM the API extracts with - skipped honestly when the API's own health/llm
#      reports no working provider): after the queue drains (no operation pending or processing),
#      total_documents per bank equals the number of unique ids in its seed file - also after the
#      --force re-run (stable ids update in place, no duplicates) - and total_nodes > 0
# Uses test-local directories, port and stamp (/tmp/hindsight-seed-smoke, or TEST17_DIR); never
# touches /wd or the persisted pg0 cluster. TEST17_SEED_DIR points the test at another seed directory
# (default: /seed in the image, ./seed from a checkout).

D=${TEST17_DIR:-/tmp/hindsight-seed-smoke}
rm -rf "${D:?}"
mkdir -p "${D}"
# the extraction state file and the API log the seed reads are test-local too (never /wd/ui); the watch window
# is shortened for the live checks (the first memory of a working extraction arrives within a minute)
export HINDSIGHT_SEED_STATE=${D}/state HINDSIGHT_API_LOG=${D}/api.log HINDSIGHT_SEED_EXTRACTION_WAIT=120

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
SEED_DIR=${TEST17_SEED_DIR:-${BASE_DIR%/}/seed}
[ -d "${SEED_DIR}" ] || SEED_DIR=/seed
SEED="${AGENT_DIR}/hindsight-seed.sh"
API_PORT=18017
API=http://127.0.0.1:${API_PORT}
HINDSIGHT_BIN=/home/hindsight/.local/bin/hindsight-api
API_PGID=""

fail()
{
	echo "Test17 FAILED: $1"
	exit 1
}

cleanup()
{
	if [ -n "${API_PGID}" ]; then
		kill -TERM -- "-${API_PGID}" 2>/dev/null
		for i in $(seq 1 30); do
			kill -0 -- "-${API_PGID}" 2>/dev/null || break
			sleep 1
		done
		kill -KILL -- "-${API_PGID}" 2>/dev/null
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

json()
{
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1]) if sys.argv[1] != "-" else sys.stdin); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null
}

# --- 1. syntax + a well-formed seed ---
[ -f "${SEED}" ] || fail "missing ${SEED}"
bash -n "${SEED}" || fail "bash -n ${SEED}"
[ -f "${SEED_DIR}/banks.json" ] || fail "no seed: ${SEED_DIR}/banks.json missing"
BANKS=$(json "${SEED_DIR}/banks.json" "' '.join(sorted(d))")
[ -n "${BANKS}" ] || fail "${SEED_DIR}/banks.json names no banks"
for B in harness-knowledge loglearner-rules; do
	echo " ${BANKS} " | grep -q " ${B} " || fail "banks.json does not name the bank ${B}"
done
declare -A EXPECTED
for B in ${BANKS}; do
	F=${SEED_DIR}/${B}.jsonl
	[ -f "${F}" ] || fail "bank ${B} has no ${F}"
	N=$(python3 - "${F}" << 'PY' || exit 1
import json, sys
ids = set()
n = 0
for ln, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if not line.strip():
        continue
    try:
        it = json.loads(line)
    except ValueError as e:
        print(f"{sys.argv[1]}:{ln}: invalid JSON: {e}", file=sys.stderr); sys.exit(1)
    for k in ("document_id", "content", "context", "tags"):
        if not it.get(k):
            print(f"{sys.argv[1]}:{ln}: missing {k}", file=sys.stderr); sys.exit(1)
    if it["document_id"] in ids:
        print(f"{sys.argv[1]}:{ln}: duplicate document_id {it['document_id']}", file=sys.stderr); sys.exit(1)
    ids.add(it["document_id"])
    n += 1
print(n)
PY
) || fail "seed file ${F} is malformed (see above)"
	[ "${N:-0}" -ge 1 ] 2>/dev/null || fail "seed file ${F} is empty"
	EXPECTED[${B}]=${N}
done
TOTAL=0
for B in ${BANKS}; do TOTAL=$((TOTAL + EXPECTED[${B}])); done
echo "ok 1 - syntax; seed ${SEED_DIR}: banks ${BANKS}; ${TOTAL} items, ids unique per bank, every line {document_id, content, context, tags}"

# --- 1b. the .env contract, when a checkout is at hand: the switch ships ON and reaches the container ---
ENV_FILE=""
for C in "${BASE_DIR}/../.env" "/do-agent-aws/.env" "${BASE_DIR}/.env"; do
	[ -f "${C}" ] && ENV_FILE="$(cd "$(dirname "${C}")" && pwd)/.env" && break
done
if [ -n "${ENV_FILE}" ]; then
	ENV_DIR="$(dirname "${ENV_FILE}")"
	grep -qE '^export HINDSIGHT_SEED=true$' "${ENV_FILE}" || fail "HINDSIGHT_SEED=true is not the .env default"
	grep -qF -- '-e HINDSIGHT_SEED=$(shq "${HINDSIGHT_SEED}")' "${ENV_FILE}" || fail "UI_ENV_OPTS does not pass HINDSIGHT_SEED into the container"
	[ -f "${ENV_DIR}/to/compose/template/docker-compose.yaml" ] && { grep -qF -- '- HINDSIGHT_SEED=${HINDSIGHT_SEED}' "${ENV_DIR}/to/compose/template/docker-compose.yaml" || fail "compose template does not pass HINDSIGHT_SEED"; }
	[ -f "${ENV_DIR}/to/kubernetes/template/020-deployment.yaml" ] && { grep -qF -- '- name: HINDSIGHT_SEED' "${ENV_DIR}/to/kubernetes/template/020-deployment.yaml" || fail "kubernetes template does not pass HINDSIGHT_SEED"; }
	grep -qE 'HINDSIGHT_SEED:-true}" != "false"' "${BASE_DIR}/startup.sh" 2>/dev/null || grep -qE 'HINDSIGHT_SEED:-true}" != "false"' /startup.sh 2>/dev/null \
		|| fail "startup.sh has no HINDSIGHT_SEED=false gate around the seed"
	echo "ok 1b - .env contract: HINDSIGHT_SEED=true by default, passed by run.sh, compose and kubernetes; startup.sh gates on it"
else
	echo "ok 1b - (skipped: no .env found in this context)"
fi

# --- 2. the shipped scan is clean and can go red ---
[ -f "${SEED_DIR}/scan.py" ] || fail "the seed ships no scan.py (${SEED_DIR}/scan.py)"
python3 "${SEED_DIR}/scan.py" "${SEED_DIR}" > "${D}/scan.out" 2>&1 || { cat "${D}/scan.out"; fail "scan.py found something in the shipped seed"; }
grep -qE '^scan: [0-9]+ files, [0-9]+ items, 0 findings' "${D}/scan.out" || fail "scan.py did not print its summary line: $(cat "${D}/scan.out")"
mkdir -p "${D}/planted"
cp "${SEED_DIR}"/*.json "${SEED_DIR}"/*.jsonl "${D}/planted/"
printf '{"document_id":"planted-key","content":"use %s as the key","context":"planted","tags":["x"]}\n' "AKIA""IOSFODNN7EXAMPLE" >> "${D}/planted/harness-knowledge.jsonl"
python3 "${SEED_DIR}/scan.py" "${D}/planted" > "${D}/scan-planted.out" 2>&1
[ $? -eq 1 ] || fail "PLANTED CONTROL BROKEN: scan.py passed a seed carrying an AWS access key: $(cat "${D}/scan-planted.out")"
grep -q "harness-knowledge.jsonl" "${D}/scan-planted.out" || fail "scan.py did not name the file carrying the planted key: $(cat "${D}/scan-planted.out")"
# compound forms of a denylisted term must be caught too - inside a hyphenated file name, a dotted name
# and a camelCase word, and the hyphenated lane name itself - while the product name the harness ships
# openly (LogLearner, whose camelCase splits into that lane name) must pass: exactly four findings
mkdir -p "${D}/seed-compound" && cp "${SEED_DIR}"/*.json "${SEED_DIR}"/*.jsonl "${D}/seed-compound/" 2>/dev/null
{
	printf '{"document_id": "zz-compound-1", "content": "Read fleet-mgr-learnings before the change.", "context": "planted compound name", "tags": ["planted"]}\n'
	printf '{"document_id": "zz-compound-2", "content": "The file kube-spoke-learnings.jsonl holds them.", "context": "planted dotted name", "tags": ["planted"]}\n'
	printf '{"document_id": "zz-compound-3", "content": "The FleetMgr lane keeps the board.", "context": "planted camelCase name", "tags": ["planted"]}\n'
	printf '{"document_id": "zz-compound-4", "content": "Ask the log-learner lane for the rule.", "context": "planted lane name", "tags": ["planted"]}\n'
	printf '{"document_id": "zz-compound-5", "content": "Open the LogLearner dashboard tile.", "context": "the product name, shipped openly - not a finding", "tags": ["planted"]}\n'
} >> "${D}/seed-compound/harness-knowledge.jsonl"
python3 "${SEED_DIR}/scan.py" "${D}/seed-compound" > "${D}/scan-compound.out" 2>&1
[ $? -eq 1 ] || fail "planted compound denylisted names (fleet-mgr-learnings, kube-spoke-learnings.jsonl, FleetMgr, log-learner) passed the scan: $(tail -2 "${D}/scan-compound.out")"
N_COMPOUND=$(grep -c "denylist-name" "${D}/scan-compound.out")
[ "${N_COMPOUND}" -eq 4 ] || fail "expected exactly 4 denylist-name findings for the planted compound forms (the LogLearner product name must not be one), got ${N_COMPOUND}: $(grep denylist-name "${D}/scan-compound.out")"
grep -q "zz-compound-5\|LogLearner" "${D}/scan-compound.out" && fail "the product name LogLearner was reported as a finding: $(grep -i loglearner "${D}/scan-compound.out")"
# planted: kernel internals in a layer bank (the depth the seed stays out of) fail as scope. The seed ships no layer
# bank, so the copy gets one of its own, layer-planted.jsonl: the scanner's layer rule is for any layer-*.jsonl
plant() { rm -rf "${D:?}/${1:?}"; mkdir -p "${D}/$1"; cp "${SEED_DIR}"/*.json "${SEED_DIR}"/*.jsonl "${D}/$1/"; printf '%s\n' "$3" >> "${D}/$1/$2"; }
plant planted-depth layer-planted.jsonl '{"document_id":"planted-depth","content":"After posting each WQE ring the doorbell, then call nvshmemx_quiet() inside the dispatch kernel before the next put.","context":"planted","tags":["x"]}'
python3 "${SEED_DIR}/scan.py" "${D}/planted-depth" > "${D}/scan-depth.out" 2>&1
[ $? -eq 1 ] || fail "PLANTED CONTROL BROKEN: scan.py passed a kernel-internals item in a layer bank: $(tail -1 "${D}/scan-depth.out")"
grep -qE "layer-planted.jsonl:[0-9]+: scope:" "${D}/scan-depth.out" || fail "scan.py did not refuse the kernel-internals item as scope: $(cat "${D}/scan-depth.out")"
# the practical level of the networking stack - the topics the general banks exclude whole - passes in a layer bank
plant planted-practical layer-planted.jsonl '{"document_id":"planted-practical","content":"Before an NCCL job on EFA run fi_info -p efa, then check that NCCL_DEBUG=INFO logs NET/OFI from aws-ofi-nccl; NVSHMEM and NIXL use the same libfabric provider, and DeepEP needs both.","context":"planted","tags":["x"]}'
python3 "${SEED_DIR}/scan.py" "${D}/planted-practical" > "${D}/scan-practical.out" 2>&1 || fail "scan.py refused a practical EFA/NCCL/NVSHMEM/NIXL item: $(cat "${D}/scan-practical.out")"
# ... in a layer bank only: the same item in a GENERAL bank fails as scope - the general banks exclude those topics whole
plant planted-general harness-knowledge.jsonl '{"document_id":"planted-general","content":"Before an NCCL job on EFA run fi_info -p efa, then check that NCCL_DEBUG=INFO logs NET/OFI from aws-ofi-nccl; NVSHMEM and NIXL use the same libfabric provider, and DeepEP needs both.","context":"planted","tags":["x"]}'
python3 "${SEED_DIR}/scan.py" "${D}/planted-general" > "${D}/scan-general.out" 2>&1
[ $? -eq 1 ] || fail "PLANTED CONTROL BROKEN: scan.py passed an EFA/NCCL item in a GENERAL bank (the depth rule is for the layer banks only): $(tail -1 "${D}/scan-general.out")"
grep -qE "harness-knowledge.jsonl:[0-9]+: scope:" "${D}/scan-general.out" || fail "scan.py did not refuse the general-bank EFA/NCCL item as scope: $(cat "${D}/scan-general.out")"
# the cap is per bank: 301 items in one bank fail, 300 pass
mkdir -p "${D}/planted-cap"
for N in 300 301; do
	python3 -c 'import json, sys
for i in range(int(sys.argv[1])):
    print(json.dumps({"document_id": f"cap-item-{i:03d}", "content": f"Planted item {i}.", "context": "planted", "tags": ["x"]}))' "${N}" > "${D}/planted-cap/cap-bank.jsonl"
	python3 "${SEED_DIR}/scan.py" "${D}/planted-cap" > "${D}/scan-cap-${N}.out" 2>&1
	echo "$?" > "${D}/scan-cap-${N}.rc"
done
[ "$(cat "${D}/scan-cap-300.rc")" == "0" ] || fail "scan.py refused a bank of 300 items: $(cat "${D}/scan-cap-300.out")"
{ [ "$(cat "${D}/scan-cap-301.rc")" == "1" ] && grep -q "exceeds the per-bank cap of 300" "${D}/scan-cap-301.out"; } \
	|| fail "PLANTED CONTROL BROKEN: scan.py passed a bank of 301 items: $(cat "${D}/scan-cap-301.out")"
# an address on a domain that cannot exist on the public internet is a placeholder, not a finding: the harness's own
# board account agent@do-agent-aws.local (docs/manual/boards.md "Signing in"), the documentation domains, the reserved TLDs;
# PLANTED: a real-looking address still fails as email
for M in ok bad; do mkdir -p "${D}/planted-mail-${M}"; cp "${SEED_DIR}"/*.json "${SEED_DIR}"/*.jsonl "${D}/planted-mail-${M}/"; done
printf '{"document_id":"planted-mail-ok","content":"The board account is agent@do-agent-aws.local; examples use someone@example.org, sub@dev.example.com and ops@service.test.","context":"planted","tags":["x"]}\n' >> "${D}/planted-mail-ok/harness-knowledge.jsonl"
python3 "${SEED_DIR}/scan.py" "${D}/planted-mail-ok" > "${D}/scan-mail-ok.out" 2>&1 || fail "scan.py refused placeholder addresses (.local, example.org, .test): $(cat "${D}/scan-mail-ok.out")"
printf '{"document_id":"planted-mail-bad","content":"Write to someone@gmail.com for access.","context":"planted","tags":["x"]}\n' >> "${D}/planted-mail-bad/harness-knowledge.jsonl"
python3 "${SEED_DIR}/scan.py" "${D}/planted-mail-bad" > "${D}/scan-mail-bad.out" 2>&1
[ $? -eq 1 ] || fail "PLANTED CONTROL BROKEN: scan.py passed a real-looking address: $(cat "${D}/scan-mail-bad.out")"
grep -qE "harness-knowledge.jsonl:[0-9]+: email:" "${D}/scan-mail-bad.out" || fail "scan.py did not flag the planted address as email: $(cat "${D}/scan-mail-bad.out")"
# the scp-like SSH remote form of a repository address - git@host:owner/repo, or the bare git@host: prefix a URL rewrite
# strips - is a repository address, not a person's; PLANTED: the same token without the colon is still an address
for M in ok bad; do mkdir -p "${D}/planted-ssh-${M}"; cp "${SEED_DIR}"/*.json "${SEED_DIR}"/*.jsonl "${D}/planted-ssh-${M}/"; done
printf '{"document_id":"planted-ssh-ok","content":"Clone git@github.com:someorg/somerepo.git; the rewrite strips the git@github.com: prefix.","context":"planted","tags":["x"]}\n' >> "${D}/planted-ssh-ok/harness-knowledge.jsonl"
python3 "${SEED_DIR}/scan.py" "${D}/planted-ssh-ok" > "${D}/scan-ssh-ok.out" 2>&1 || fail "scan.py refused the SSH remote form of a repository address: $(cat "${D}/scan-ssh-ok.out")"
printf '{"document_id":"planted-ssh-bad","content":"The account git@github.com without a colon.","context":"planted","tags":["x"]}\n' >> "${D}/planted-ssh-bad/harness-knowledge.jsonl"
python3 "${SEED_DIR}/scan.py" "${D}/planted-ssh-bad" > "${D}/scan-ssh-bad.out" 2>&1
[ $? -eq 1 ] || fail "PLANTED CONTROL BROKEN: scan.py passed git@host without the colon that makes it a remote: $(cat "${D}/scan-ssh-bad.out")"
# --tree mode: the exact fixture values one named file carries on purpose (the fresh-deploy proof's planted control network,
# tools/fresh-deploy-proof/proof.sh) pass in that file and nowhere else; a third address in that file is still a finding. The
# two values are assembled here so this test spells no address
FX_NET=$(printf '%s.%s.%s.%s' 172 31 251 0); FX_GW=$(printf '%s.%s.%s.%s' 172 31 251 254); FX_OTHER=$(printf '%s.%s.%s.%s' 203 0 113 9)
mkdir -p "${D}/fixture-ok/tools/fresh-deploy-proof" "${D}/fixture-other/tools/other" "${D}/fixture-third/tools/fresh-deploy-proof"
printf 'docker network create --subnet %s/24 --gateway %s ado-proof-net3\n' "${FX_NET}" "${FX_GW}" > "${D}/fixture-ok/tools/fresh-deploy-proof/proof.sh"
cp "${D}/fixture-ok/tools/fresh-deploy-proof/proof.sh" "${D}/fixture-other/tools/other/proof.sh"
cp "${D}/fixture-ok/tools/fresh-deploy-proof/proof.sh" "${D}/fixture-third/tools/fresh-deploy-proof/proof.sh"; printf '# and %s\n' "${FX_OTHER}" >> "${D}/fixture-third/tools/fresh-deploy-proof/proof.sh"
python3 "${SEED_DIR}/scan.py" --tree "${D}/fixture-ok" > "${D}/scan-fixture-ok.out" 2>&1 || fail "scan.py refused the fixture file's own two values: $(cat "${D}/scan-fixture-ok.out")"
python3 "${SEED_DIR}/scan.py" --tree "${D}/fixture-other" > "${D}/scan-fixture-other.out" 2>&1
[ $? -eq 1 ] && grep -qE "proof.sh:1: ipv4:" "${D}/scan-fixture-other.out" || fail "PLANTED CONTROL BROKEN: the fixture values passed in another file: $(cat "${D}/scan-fixture-other.out")"
python3 "${SEED_DIR}/scan.py" --tree "${D}/fixture-third" > "${D}/scan-fixture-third.out" 2>&1
[ $? -eq 1 ] && [ "$(grep -c ": ipv4:" "${D}/scan-fixture-third.out")" == "1" ] || fail "PLANTED CONTROL BROKEN: a third address in the fixture file was not the one finding: $(cat "${D}/scan-fixture-third.out")"
# the vendored LogLearner tree (the image's /opt/loglearner, or the checkout's Container-Root/opt/loglearner): the
# same scan over EVERY text file - sources, tests, configs, identifiers included - must be clean. The E2E run found a
# fleet-internal identifier shipped in it (P0); install-loglearner.sh runs this scan at build time, so a dirty tree
# cannot build. PLANTED: a tree carrying that identifier (assembled at run time - this test must not spell it) fails
# with one finding per file; a clean tree passes
T=$(printf 'c%sco' u)
mkdir -p "${D}/tree-planted/pkg"
printf 'def to_%s(x):\n    return x\n' "${T}" > "${D}/tree-planted/pkg/mod.py"
printf '{"%s_stores": 1}\n' "${T}" > "${D}/tree-planted/pkg/axes.json"
printf 'clean = True\n' > "${D}/tree-planted/pkg/clean.py"
python3 "${SEED_DIR}/scan.py" --tree "${D}/tree-planted" > "${D}/scan-tree-planted.out" 2>&1
[ $? -eq 1 ] || fail "PLANTED CONTROL BROKEN: scan.py --tree passed a tree carrying the internal identifier: $(cat "${D}/scan-tree-planted.out")"
[ "$(grep -c denylist-name "${D}/scan-tree-planted.out")" -eq 2 ] || fail "expected 2 denylist-name findings in the planted tree (mod.py, axes.json): $(cat "${D}/scan-tree-planted.out")"
grep -q "pkg/mod.py:1:" "${D}/scan-tree-planted.out" && grep -q "pkg/axes.json:1:" "${D}/scan-tree-planted.out" || fail "the planted tree's findings do not name both files: $(cat "${D}/scan-tree-planted.out")"
mkdir -p "${D}/tree-clean"; printf 'clean = True\n' > "${D}/tree-clean/ok.py"
python3 "${SEED_DIR}/scan.py" --tree "${D}/tree-clean" > "${D}/scan-tree-clean.out" 2>&1 || fail "scan.py --tree failed a clean tree: $(cat "${D}/scan-tree-clean.out")"
# a home directory in a shipped tree is the build host's user and layout (the vendored 0.1.9 carried the encoded form in
# its provenance table and its dashboard, and /home paths in its tests). PLANTED, one tree per shape so a missing shape
# or a broken exclusion is named: the clean tree plus one file carrying the shape fails with exactly one home-path
# finding naming that file and line, and only it; a two-line file pins one finding per line; the look-alike tokens and
# the image's own service home each pass in a tree of their own. Exit 0 on a planted tree is the control broken; any
# exit but 1 is the scanner crashing, named apart
home_hit() {  # home_hit <name> <line>
	mkdir -p "${D}/tree-home-${1}"; cp "${D}/tree-clean/ok.py" "${D}/tree-home-${1}/"
	printf '%s\n' "${2}" > "${D}/tree-home-${1}/hit.txt"
	python3 "${SEED_DIR}/scan.py" --tree "${D}/tree-home-${1}" > "${D}/scan-tree-home-${1}.out" 2>&1; local rc=$?
	[ "${rc}" -eq 0 ] && fail "PLANTED CONTROL BROKEN: scan.py --tree passed a tree carrying a home directory (${1}): $(cat "${D}/scan-tree-home-${1}.out")"
	[ "${rc}" -eq 1 ] || fail "scan.py --tree crashed (exit ${rc}) on the planted tree (${1}): $(cat "${D}/scan-tree-home-${1}.out")"
	[ "$(grep -c ": home-path:" "${D}/scan-tree-home-${1}.out")" -eq 1 ] && grep -qF "/hit.txt:1: home-path:" "${D}/scan-tree-home-${1}.out" \
		|| fail "expected exactly one home-path finding naming hit.txt:1 (${1}): $(cat "${D}/scan-tree-home-${1}.out")"
	grep -qF "/ok.py:" "${D}/scan-tree-home-${1}.out" && fail "the clean file was reported in the planted tree (${1}): $(cat "${D}/scan-tree-home-${1}.out")"
	HOME_HITS=$((HOME_HITS + 1))
}
home_ok() {  # home_ok <name> <line>
	mkdir -p "${D}/tree-homeok-${1}"; printf '%s\n' "${2}" > "${D}/tree-homeok-${1}/notes.md"
	python3 "${SEED_DIR}/scan.py" --tree "${D}/tree-homeok-${1}" > "${D}/scan-tree-homeok-${1}.out" 2>&1; local rc=$?
	[ "${rc}" -eq 1 ] && fail "scan.py --tree flagged a look-alike token or the image's own service home as a home directory (${1}): $(cat "${D}/scan-tree-homeok-${1}.out")"
	[ "${rc}" -eq 0 ] || fail "scan.py --tree crashed (exit ${rc}) on a look-alike tree (${1}): $(cat "${D}/scan-tree-homeok-${1}.out")"
	HOME_OKS=$((HOME_OKS + 1))
}
HOME_HITS=0; HOME_OKS=0
home_hit encoded '{"source": "~/.claude/projects/-home-someone-somerepo/memory/notes.md"}'
home_hit quoted-encoded 'p = r["project"].replace("-home-someone-", "")'
home_hit backtick-encoded 'the directory `-Users-someone-repo` holds the session'
home_hit path 'P = "/home/someone/.claude/settings.json"'
home_hit users 'Q = "/Users/someone/work/repo"'
home_hit dotted-user 'see /home/first.last/work'
home_hit var-home 'under /var/home/someone/x'
home_hit double-slash 'open //home/someone/x'
home_hit file-url 'file:///home/someone/x'
home_hit relative 'cp ../home/someone/x .'
home_hit chained-relative 'cp ../../home/someone/x .'
home_hit dot-relative './../home/someone/x'
home_hit tilde-relative '~/../home/someone/x'
home_hit json-escaped '{"p": "\/home\/someone\/x"}'
home_hit windows 'C:\Users\someone\x'
home_hit windows-doubled 'C:\\Users\\someone\\x'
home_hit windows-encoded 'projects/C--Users-someone-repo/memory'
mkdir -p "${D}/tree-home-two"
printf 'P = "/home/someone/.claude/settings.json"\nQ = "/Users/someone/work/repo"\n' > "${D}/tree-home-two/paths.py"
python3 "${SEED_DIR}/scan.py" --tree "${D}/tree-home-two" > "${D}/scan-tree-home-two.out" 2>&1; rc=$?
[ "${rc}" -eq 0 ] && fail "PLANTED CONTROL BROKEN: scan.py --tree passed the two-path tree: $(cat "${D}/scan-tree-home-two.out")"
[ "${rc}" -eq 1 ] || fail "scan.py --tree crashed (exit ${rc}) on the two-path tree: $(cat "${D}/scan-tree-home-two.out")"
[ "$(grep -c ": home-path:" "${D}/scan-tree-home-two.out")" -eq 2 ] && grep -qF "paths.py:1: home-path:" "${D}/scan-tree-home-two.out" \
	&& grep -qF "paths.py:2: home-path:" "${D}/scan-tree-home-two.out" \
	|| fail "expected one home-path finding on each of paths.py:1 and paths.py:2: $(cat "${D}/scan-tree-home-two.out")"
home_ok slug 'fix-home-page-tiles'
home_ok double-dash-flag '--home-dir'
home_ok single-dash-flag 'run -home-dir x'
home_ok users-flag '-Users-only'
home_ok url 'https://example.com/home/page'
home_ok bare '/home/'
home_ok variable 'cp "${VAR}/home/x" .'
home_ok service-home '/home/hindsight/.pg0 is the data directory'
home_ok service-home-sentence 'the data directory is under /home/hindsight.'
home_ok service-home-encoded 'projects/-home-hindsight-repo'
home_ok service-home-encoded-sentence 'the sessions sit under projects/-home-hindsight.'
home_ok service-home-windows-encoded 'see C--Users-hindsight.'
home_ok tilde-home 'the copy under ~/home/x'
home_ok root-home 'Claude Code configuration under /home/agent/.claude; the CLI accepts --root-path'
# the build gate names the cause: install-loglearner.sh over a copy of the vendored tree plus one home path exits 1,
# says "a denylisted name or a home directory" and shows the finding. The script's three overrides point its scan at
# this test's scan.py and its scan output and its command at ${D}, so the control runs from a checkout too and a planted
# tree can never repoint the image's command (/usr/local/bin/loglearner is not touched) or write outside ${D}; a command
# written under ${D} would mean the gate let the tree through. The vendor script's refusal, when a checkout is at hand,
# carries the same words (it needs a release tarball and a source clone to run)
INSTALL_LL=/setup/install-loglearner.sh; [ -f "${INSTALL_LL}" ] || INSTALL_LL="${BASE_DIR%/}/setup/install-loglearner.sh"
LL_TREE=${TEST17_LOGLEARNER_DIR:-${BASE_DIR%/}/opt/loglearner}
[ -d "${LL_TREE}" ] || LL_TREE=/opt/loglearner
[ -d "${LL_TREE}" ] || fail "no vendored LogLearner tree to scan (${LL_TREE})"
if [ -f "${INSTALL_LL}" ]; then
	rm -rf "${D:?}/ll-home" "${D:?}/ll-bin"; cp -r "${LL_TREE}" "${D}/ll-home"; printf 'see /home/someone/x\n' > "${D}/ll-home/docs/planted.md"
	LOGLEARNER_DIR=${D}/ll-home LOGLEARNER_SCAN=${SEED_DIR}/scan.py LOGLEARNER_SCAN_OUT=${D}/ll-scan.out LOGLEARNER_BIN=${D}/ll-bin/loglearner \
		bash "${INSTALL_LL}" > "${D}/install-home.out" 2>&1; rc=$?
	[ "${rc}" -eq 1 ] || fail "install-loglearner.sh over a tree with a home path exited ${rc}, not 1: $(tail -3 "${D}/install-home.out")"
	grep -q "a denylisted name or a home directory" "${D}/install-home.out" || fail "install-loglearner.sh's refusal does not name a home directory: $(tail -3 "${D}/install-home.out")"
	grep -q "planted.md:1: home-path:" "${D}/install-home.out" || fail "install-loglearner.sh's refusal does not show the finding: $(tail -5 "${D}/install-home.out")"
	[ -e "${D}/ll-bin/loglearner" ] && fail "install-loglearner.sh wrote its command although the gate refused the tree"
	[ -f "${D}/ll-scan.out" ] || fail "install-loglearner.sh did not write its scan output where LOGLEARNER_SCAN_OUT pointed"
	INSTALL_NOTE="install-loglearner.sh refuses a tree with one home path, naming the cause and the finding, writing no command"
else
	INSTALL_NOTE="install-loglearner.sh not run here (no script at /setup or beside this test's setup/)"
fi
VENDOR_SH="${BASE_DIR%/}/../tools/vendor-loglearner.sh"
if [ -f "${VENDOR_SH}" ]; then
	grep -q "a denylisted name or a home directory" "${VENDOR_SH}" || fail "tools/vendor-loglearner.sh's refusal does not name a home directory"
	INSTALL_NOTE="${INSTALL_NOTE}; the vendor script's refusal says the same"
fi
# the repository's own front page and its manual, when a checkout is at hand: README.md and docs/manual in tree mode (a
# private repository's name once stood in the Loop Deck row the manual now holds). The rest of docs/ is not scanned here:
# the Slack guides carry placeholder channel ids and tokens (C0123ABCDEF, xoxb-your-token) the scanner cannot tell from real
# ones, and the status page attributes decisions to the owner and the committer by first name
for RD in "${BASE_DIR%/}/../README.md" "/do-agent-aws/README.md"; do [ -f "${RD}" ] && { README_PATH=${RD}; break; }; done
if [ -n "${README_PATH:-}" ]; then
	python3 "${SEED_DIR}/scan.py" --tree "${README_PATH}" "$(dirname "${README_PATH}")/docs/manual" > "${D}/scan-readme.out" 2>&1 \
		|| { head -5 "${D}/scan-readme.out"; fail "scan.py --tree: the README or the manual carries a denylisted name or secret: $(tail -1 "${D}/scan-readme.out")"; }
	grep -qE '^scan: ([2-9]|[1-9][0-9]+) files, 0 items, 0 findings \(tree mode' "${D}/scan-readme.out" || fail "scan.py --tree did not scan the README and the manual: $(tail -1 "${D}/scan-readme.out")"
fi
python3 "${SEED_DIR}/scan.py" --tree "${LL_TREE}" > "${D}/scan-tree.out" 2>&1 \
	|| { tail -5 "${D}/scan-tree.out"; fail "scan.py --tree: the vendored LogLearner tree ${LL_TREE} carries a denylisted name or a home directory ($(tail -1 "${D}/scan-tree.out")) - re-vendor a scrubbed release"; }
grep -qE '^scan: [0-9]+ files, 0 items, 0 findings \(tree mode' "${D}/scan-tree.out" || fail "scan.py --tree did not print its tree-mode summary: $(tail -1 "${D}/scan-tree.out")"
echo "ok 2 - compound forms of a denylisted name caught (4 planted), the shipped product name passes; scan.py: shipped seed clean ($(head -1 "${D}/scan.out")); planted AWS key and kernel internals in a planted layer bank fail it, a practical networking item passes in a planted layer bank and fails as scope in a general bank, 301 items in one bank fail the per-bank cap; the vendored LogLearner tree is clean in tree mode ($(tail -1 "${D}/scan-tree.out" | cut -d'(' -f1)), a planted tree fails with one finding per file; placeholder addresses (.local, example.org and a subdomain of it, .test) pass, a real-looking address fails; the SSH remote form passes and git@host without its colon does not; the fixture file's two exact values pass there alone; home-directory controls: ${HOME_HITS} planted shapes each one finding naming its file and line, a two-line file pinned per line, ${HOME_OKS} look-alikes and the service and root homes pass; ${INSTALL_NOTE}"

# --- 3. offline behaviour: dry run, missing seed, dead API ---
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-dry HINDSIGHT_SEED_API=http://127.0.0.1:9 "${SEED}" --dry-run > "${D}/dry.out" 2> "${D}/dry.err" \
	|| fail "--dry-run exited non-zero: $(cat "${D}/dry.err")"
grep -q "dry run - nothing posted, no stamp written" "${D}/dry.out" || fail "--dry-run did not report itself: $(cat "${D}/dry.out")"
[ -e "${D}/stamp-dry" ] && fail "--dry-run wrote a stamp"
for B in ${BANKS}; do
	grep -q "bank ${B}: ${EXPECTED[${B}]} items" "${D}/dry.out" || fail "--dry-run did not report ${EXPECTED[${B}]} items for ${B}: $(cat "${D}/dry.out")"
done
HINDSIGHT_SEED_DIR=${D}/no-such-seed HINDSIGHT_SEED_STAMP=${D}/stamp-missing "${SEED}" > "${D}/missing.out" 2> "${D}/missing.err"
[ $? -eq 1 ] || fail "a missing seed directory did not exit 1"
[ "$(wc -l < "${D}/missing.err")" == "1" ] && grep -q "no seed at ${D}/no-such-seed" "${D}/missing.err" \
	|| fail "a missing seed directory did not produce exactly one stderr line naming it: $(cat "${D}/missing.err")"
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-dead HINDSIGHT_SEED_API=http://127.0.0.1:9 HINDSIGHT_SEED_WAIT=3 "${SEED}" > "${D}/dead.out" 2> "${D}/dead.err"
[ $? -eq 1 ] || fail "an API that never answers did not exit 1"
[ "$(wc -l < "${D}/dead.err")" == "1" ] && grep -q "did not answer /health within 3s" "${D}/dead.err" \
	|| fail "a dead API did not produce exactly one stderr line: $(cat "${D}/dead.err")"
[ -e "${D}/stamp-dead" ] && fail "a failed seed wrote a stamp"
echo "ok 3 - --dry-run reports without the API or a stamp; missing seed dir and dead API exit 1 with one line each"

# --- 3b. planted controls: the extraction watch - items accepted but nothing extracted must be reported, with the cause ---
# a stand-in memory API accepts the banks and the items and reports the documents/pending this test says; the
# memory API's log is a planted file with the credentials error of a fresh deploy whose profile does not exist
cat > "${D}/stub-api.py" << 'PYSTUB'
import http.server, json, os, sys
DOCS = int(sys.argv[2]); PENDING = int(sys.argv[3]); LOG = sys.argv[4] if len(sys.argv) > 4 else ""; BANKS = set()
LOGLINE = os.environ.get("STUB_LOG_LINE", "botocore.exceptions.ProfileNotFound: The config profile (planted-profile) could not be found\nhttps://github.com/example/issues/new?&title=%5BBug%5D%3A+ProfileNotFound+in+client.py&version=1\n")
FAILED = int(os.environ.get("STUB_FAILED", "0"))          # failed_operations the stand-in reports
STEP = int(os.environ.get("STUB_DOCS_STEP", "0"))          # > 0: each bank's documents grow by STEP per stats call, up to DOCS
CALLS = {}
class H(http.server.BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == '/health': return self._json(200, {"status": "healthy"})
        if self.path.startswith('/v1/default/banks') and self.path.endswith('/stats'):
            if LOG and DOCS == 0:   # a stuck extraction: the real API logs its error on every retry - while the seed watches
                with open(LOG, 'a') as f: f.write(LOGLINE)
            docs = DOCS
            if STEP:
                CALLS[self.path] = CALLS.get(self.path, 0) + 1
                docs = min(DOCS, STEP * CALLS[self.path])
            return self._json(200, {"total_documents": docs, "total_nodes": docs, "pending_operations": PENDING, "failed_operations": FAILED})
        if self.path.startswith('/v1/default/banks'): return self._json(200, {"banks": [{"bank_id": b} for b in sorted(BANKS)]})
        return self._json(404, {})
    def do_PUT(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0))); BANKS.add(self.path.rsplit('/', 1)[-1]); return self._json(200, {})
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if os.environ.get('STUB_RECORD'):   # what the seed posted, item by item, for the checks below
            try:
                for it in json.loads(body or b'{}').get('items', []):
                    with open(os.environ['STUB_RECORD'], 'a') as f: f.write(json.dumps(it) + '\n')
            except ValueError:
                pass
        return self._json(202, {"operations": []})
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PYSTUB
STUB_PORT=18019
stub_start() { ( setsid nohup python3 "${D}/stub-api.py" "${STUB_PORT}" "$1" "$2" "${D}/api-planted.log" > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.25; done; }
stub_stop() { kill -TERM -- "-$(cat "${D}/stub.pid")" 2>/dev/null || kill -TERM "$(cat "${D}/stub.pid")" 2>/dev/null; sleep 0.5; }
# the planted API log starts with an OLD error from before this start (a run before the credentials were fixed);
# the stand-in appends the live error (the plain line and, after it, the LLM client's "file a bug" URL that repeats
# the error name URL-encoded - as the real log has it) on every stats request, i.e. while the seed watches. The
# excerpt must come from a plain line logged since the start, never from the old one
printf 'INFO starting\nbotocore.exceptions.NoCredentialsError: Unable to locate credentials (an OLD line, before this start)\n' > "${D}/api-planted.log"
stub_start 0 7
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub HINDSIGHT_SEED_EXTRACTION_WAIT=6 HINDSIGHT_API_LOG=${D}/api-planted.log "${SEED}" > "${D}/stub-fail.out" 2> "${D}/stub-fail.err"
RC=$?
[ ${RC} -eq 0 ] || { stub_stop; cat "${D}/stub-fail.err"; fail "3b: the seed against the stand-in API (nothing extracted) exited ${RC} - acceptance succeeded, so the exit must stay 0"; }
grep -q "WARNING - ${TOTAL} items were accepted but NO memory was extracted within 6s" "${D}/stub-fail.out" || fail "3b: no WARNING about the extraction in the seed's output: $(tail -3 "${D}/stub-fail.out")"
grep -q "the AWS profile named by AWS_PROFILE does not exist" "${D}/stub-fail.out" || fail "3b: the WARNING does not name the cause from the planted API log: $(grep WARNING "${D}/stub-fail.out")"
[ "$(grep -c "WARNING" "${D}/stub-fail.out")" == "1" ] || fail "3b: the WARNING must appear exactly once in the seed's own output: $(grep -c WARNING "${D}/stub-fail.out") time(s)"
grep -q "^hindsight seed: WARNING" "${D}/stub-fail.out" || fail "3b: the WARNING line does not carry the seed's prefix"
grep -qx "state=failed" "${D}/state-stub" || fail "3b: the state file does not say state=failed: $(cat "${D}/state-stub")"
grep -q "^reason=.*AWS_PROFILE" "${D}/state-stub" || fail "3b: the state file carries no reason: $(cat "${D}/state-stub")"
grep -q "^excerpt=.*could not be found" "${D}/state-stub" || fail "3b: the state file's excerpt is not the plain error line: $(grep ^excerpt= "${D}/state-stub")"
grep -q "^excerpt=.*title=" "${D}/state-stub" && fail "3b: the excerpt came from the URL-encoded bug-report line, not the error: $(grep ^excerpt= "${D}/state-stub")"
grep -q "OLD line" "${D}/state-stub" && fail "3b: the cause was read from a log line written BEFORE this start: $(grep ^excerpt= "${D}/state-stub")"
# the state file follows the stamp: a seed with its own stamp (another seed directory - a knowledge package's instructions do
# this - and HINDSIGHT_SEED_STATE unset) writes <stamp name>.state under UI_DIR and leaves the harness's own
# hindsight-seed.state alone, so the home page's memory row keeps reporting the harness's seed, not the package's
mkdir -p "${D}/ui-own"
( unset HINDSIGHT_SEED_STATE; UI_DIR=${D}/ui-own HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/package-seed.stamp HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} \
	HINDSIGHT_SEED_WAIT=10 HINDSIGHT_SEED_EXTRACTION_WAIT=6 HINDSIGHT_API_LOG=${D}/api-planted.log "${SEED}" > "${D}/stub-own.out" 2>&1 ) || fail "3b: the seed with its own stamp failed: $(tail -3 "${D}/stub-own.out")"
[ -f "${D}/ui-own/package-seed.state" ] || fail "3b: a seed with its own stamp wrote no ${D}/ui-own/package-seed.state - the state file must follow the stamp: $(ls "${D}/ui-own" | tr '\n' ' ')"
[ -e "${D}/ui-own/hindsight-seed.state" ] && fail "3b: a seed with its own stamp wrote the harness's own state file ${D}/ui-own/hindsight-seed.state (the home page would report this seed instead of the harness's)"
grep -qx "state=failed" "${D}/ui-own/package-seed.state" || fail "3b: the stamp-named state file does not carry the run's state: $(cat "${D}/ui-own/package-seed.state")"
# planted control for the since-this-start rule: only the OLD error in the log, the stand-in logging nothing new ->
# no cause may be read from it: stalled, not failed
stub_stop
printf 'botocore.exceptions.NoCredentialsError: Unable to locate credentials (an OLD line, before this start)\n' > "${D}/api-old-only.log"
( setsid nohup python3 "${D}/stub-api.py" ${STUB_PORT} 0 7 > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.25; done
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub-old HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub-old HINDSIGHT_SEED_EXTRACTION_WAIT=6 HINDSIGHT_API_LOG=${D}/api-old-only.log "${SEED}" > "${D}/stub-old.out" 2>&1
stub_stop
grep -qx "state=stalled" "${D}/state-stub-old" || fail "3b: with only an OLD error in the log the state must be stalled, not read from it: $(cat "${D}/state-stub-old")"
grep -q "no error since this start" "${D}/stub-old.out" || fail "3b: the stalled WARNING does not say the API logged no error since this start: $(grep WARNING "${D}/stub-old.out")"
# planted controls for two more causes the verifier's run found: Bedrock refusing a Legacy model, and an error the
# seed's list does not know - both must read FAILED (the second with the line itself), never "slow"
for CASE in legacy noaccess throughput expired denied unknown; do
	case ${CASE} in
		legacy)     LINE='litellm.NotFoundError: BedrockException - {"message":"Access denied. This Model is marked by provider as Legacy and you have not been granted access."}'; WANT="marked Legacy by its provider" ;;
		noaccess)   LINE='litellm.BadRequestError: BedrockException - {"message":"You don'"'"'t have access to the model with the specified model ID."}'; WANT="model access is not enabled" ;;
		throughput) LINE='litellm.BadRequestError: BedrockException - {"message":"Invocation of model ID xyz with on-demand throughput isn'"'"'t supported. Retry your request with the ID or ARN of an inference profile that contains this model."}'; WANT="needs an inference profile id" ;;
		expired)    LINE='litellm.AuthenticationError: BedrockException - {"message":"The security token included in the request is expired"}'; WANT="expired or invalid" ;;
		denied)     LINE='litellm.PermissionDeniedError: BedrockException - {"message":"User: arn:aws:sts::000000000000:assumed-role/x/y is not authorized to perform: bedrock:InvokeModel on resource: arn:aws:bedrock:us-east-1:000000000000:inference-profile/us.amazon.nova-2-lite-v1:0"}'; WANT="no access to the Bedrock model" ;;
		unknown)    LINE='2026-10-13 12:00:00 - ERROR - litellm.InternalServerError: BedrockException - {"message":"planted, not in the seed list"}'; WANT="errors the seed does not recognise" ;;
	esac
	: > "${D}/api-${CASE}.log"
	( export STUB_LOG_LINE="${LINE}"$'\n'; setsid nohup python3 "${D}/stub-api.py" ${STUB_PORT} 0 7 "${D}/api-${CASE}.log" > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.25; done
	HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub-${CASE} HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
		HINDSIGHT_SEED_STATE=${D}/state-stub-${CASE} HINDSIGHT_SEED_EXTRACTION_WAIT=6 HINDSIGHT_API_LOG=${D}/api-${CASE}.log "${SEED}" > "${D}/stub-${CASE}.out" 2>&1
	stub_stop
	grep -qx "state=failed" "${D}/state-stub-${CASE}" || fail "3b (${CASE}): the state is not failed: $(cat "${D}/state-stub-${CASE}")"
	grep -q "^reason=.*${WANT}" "${D}/state-stub-${CASE}" || fail "3b (${CASE}): the reason does not say '${WANT}': $(grep ^reason= "${D}/state-stub-${CASE}")"
	grep -q "WARNING.*${WANT}" "${D}/stub-${CASE}.out" || fail "3b (${CASE}): the WARNING does not carry the cause: $(grep WARNING "${D}/stub-${CASE}.out")"
done
grep -q "^excerpt=.*planted, not in the seed list" "${D}/state-stub-unknown" || fail "3b (unknown): the excerpt is not the unknown error line: $(grep ^excerpt= "${D}/state-stub-unknown")"
grep -q "no error logged\|logged no error" "${D}/stub-unknown.out" && fail "3b (unknown): the seed said no error was logged while ERROR lines were in the window: $(grep WARNING "${D}/stub-unknown.out")"
# a drained queue with every operation failed and no documents: FAILED, not "slow" (the log carries no known cause)
: > "${D}/api-drained.log"
( export STUB_FAILED=7; setsid nohup python3 "${D}/stub-api.py" "${STUB_PORT}" 0 0 > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.25; done
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub-drained HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub-drained HINDSIGHT_SEED_EXTRACTION_WAIT=30 HINDSIGHT_API_LOG=${D}/api-drained.log "${SEED}" > "${D}/stub-drained.out" 2>&1
stub_stop
grep -qx "state=failed" "${D}/state-stub-drained" || fail "3b (drained): documents 0, pending 0, failed 7 must read failed: $(cat "${D}/state-stub-drained")"
grep -q "^reason=every extraction operation failed" "${D}/state-stub-drained" || fail "3b (drained): the reason does not say every operation failed: $(grep ^reason= "${D}/state-stub-drained")"
grep -qx "excerpt=" "${D}/state-stub-drained" || fail "3b (drained): with no error line in the window the excerpt must be empty, not a literal None: $(grep ^excerpt= "${D}/state-stub-drained")"
grep -q "Log line:" "${D}/stub-drained.out" && fail "3b (drained): the WARNING carries a 'Log line' although no line was found: $(grep WARNING "${D}/stub-drained.out")"
# a drained queue WITH a throttling cause in the window: still failed (nothing is pending, so nothing more is extracted until a
# restart re-posts), the throttling text kept in the reason - never "slow, not broken"
: > "${D}/api-throttled.log"
( export STUB_FAILED=21 STUB_LOG_LINE='litellm.RateLimitError: BedrockException - {"message":"Too many requests, please wait before trying again."}'$'\n'; setsid nohup python3 "${D}/stub-api.py" "${STUB_PORT}" 0 0 "${D}/api-throttled.log" > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.25; done
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub-throttled HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub-throttled HINDSIGHT_SEED_EXTRACTION_WAIT=30 HINDSIGHT_API_LOG=${D}/api-throttled.log "${SEED}" > "${D}/stub-throttled.out" 2>&1
stub_stop
grep -qx "state=failed" "${D}/state-stub-throttled" || fail "3b (throttled+drained): 0 pending with 21 failed must read failed even with a throttling cause: $(cat "${D}/state-stub-throttled")"
grep -qE "^reason=Bedrock is throttling the calls; every extraction operation failed \([0-9]+ of [0-9]+\) and nothing is pending" "${D}/state-stub-throttled" || fail "3b (throttled+drained): the reason must keep the throttling text and say every operation failed: $(grep ^reason= "${D}/state-stub-throttled")"
grep -q "WARNING.*throttling" "${D}/stub-throttled.out" || fail "3b (throttled+drained): no WARNING carrying the cause: $(tail -3 "${D}/stub-throttled.out")"
# the control for that rule: throttled with operations still PENDING reads stalled (slow, not broken), exit 0
: > "${D}/api-throttling.log"
( export STUB_FAILED=3 STUB_LOG_LINE='litellm.RateLimitError: BedrockException - {"message":"Too many requests, please wait before trying again."}'$'\n'; setsid nohup python3 "${D}/stub-api.py" "${STUB_PORT}" 0 7 "${D}/api-throttling.log" > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.25; done
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub-throttling HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub-throttling HINDSIGHT_SEED_EXTRACTION_WAIT=6 HINDSIGHT_API_LOG=${D}/api-throttling.log "${SEED}" > "${D}/stub-throttling.out" 2>&1
RC=$?
stub_stop
[ ${RC} -eq 0 ] || fail "3b (throttling, pending): a throttled run with operations pending exited ${RC} (slow is not a failure)"
grep -qx "state=stalled" "${D}/state-stub-throttling" || fail "3b (throttling, pending): throttled with 7 pending must read stalled: $(cat "${D}/state-stub-throttling")"
grep -q "^reason=Bedrock is throttling the calls - extraction is slow, not broken" "${D}/state-stub-throttling" || fail "3b (throttling, pending): the reason does not name the throttling: $(grep ^reason= "${D}/state-stub-throttling")"
# the completion watch: documents that arrive over several polls end in state=complete, the state rewritten meanwhile.
# The stand-in reports the same document count for every bank, growing by GROW_STEP per stats call up to a cap; the cap
# is the LARGEST bank of the seed (so the banks together reach the seed total whatever the seed holds - a cap sized for
# one seed left a bigger one in state=extracting), and the completion line's count is computed from the same numbers:
# the first poll at which the banks together hold at least the seed total
N_BANKS=$(echo ${BANKS} | wc -w)
MAX_BANK=$(for B in ${BANKS}; do wc -l < "${SEED_DIR}/${B}.jsonl"; done | sort -n | tail -1)
GROW_STEP=25
GROW_K=$(( (TOTAL + N_BANKS * GROW_STEP - 1) / (N_BANKS * GROW_STEP) ))
GROW_AT=$(( GROW_K * GROW_STEP < MAX_BANK ? GROW_K * GROW_STEP : MAX_BANK ))
GROW_EXPECT=$(( N_BANKS * GROW_AT ))
[ "${GROW_EXPECT}" -ge "${TOTAL}" ] || fail "3b (grow): test arithmetic: ${N_BANKS} banks x ${GROW_AT} documents < ${TOTAL} items"
( export STUB_DOCS_STEP=${GROW_STEP}; setsid nohup python3 "${D}/stub-api.py" "${STUB_PORT}" ${MAX_BANK} 3 > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.25; done
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub-grow HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub-grow HINDSIGHT_SEED_EXTRACTION_WAIT=20 HINDSIGHT_SEED_COMPLETE_WAIT=60 HINDSIGHT_SEED_POLL=1 HINDSIGHT_API_LOG=${D}/api-planted.log "${SEED}" > "${D}/stub-grow.out" 2>&1
stub_stop
grep -qx "state=complete" "${D}/state-stub-grow" || fail "3b (grow): documents arriving over several polls did not end in state=complete: $(cat "${D}/state-stub-grow")"
grep -q "extraction complete: ${GROW_EXPECT}/${TOTAL} documents after" "${D}/stub-grow.out" || fail "3b (grow): no completion line with the counts ${GROW_EXPECT}/${TOTAL}: $(grep -i extraction "${D}/stub-grow.out" | tail -2)"
# CONTROL: a stand-in capped BELOW the seed total (the banks together never reach it) ends in state=extracting, not complete
LOW_CAP=$(( (TOTAL - 1) / N_BANKS ))
( export STUB_DOCS_STEP=${GROW_STEP}; setsid nohup python3 "${D}/stub-api.py" "${STUB_PORT}" ${LOW_CAP} 3 > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.2; done
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub-low HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub-low HINDSIGHT_SEED_EXTRACTION_WAIT=3 HINDSIGHT_SEED_COMPLETE_WAIT=4 HINDSIGHT_SEED_POLL=1 HINDSIGHT_API_LOG=${D}/api-planted.log "${SEED}" > "${D}/stub-low.out" 2>&1
stub_stop
grep -qx "state=extracting" "${D}/state-stub-low" || fail "3b (grow, PLANTED CONTROL BROKEN): a stand-in capped at ${LOW_CAP} per bank (${N_BANKS} banks < ${TOTAL} items) did not end in state=extracting: $(cat "${D}/state-stub-low")"
grep -q "extraction complete" "${D}/stub-low.out" && fail "3b (grow, PLANTED CONTROL BROKEN): the capped stand-in produced a completion line: $(grep -i extraction "${D}/stub-low.out")"
# back to the stuck stand-in for the restart case
stub_start 0 7
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub HINDSIGHT_SEED_EXTRACTION_WAIT=6 HINDSIGHT_API_LOG=${D}/api-planted.log "${SEED}" --force > "${D}/stub-fail-again.out" 2>&1 || fail "3b: re-posting against the stuck stand-in failed"
[ -f "${D}/stamp-stub" ] || fail "3b: acceptance was not stamped (the stamp records acceptance; the state records extraction)"
# a second start with the extraction still stuck (already seeded, everything pending) must say so again - against
# the SAME stand-in (it remembers the banks the first run created; a fresh one would read as a recreated database)
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub2 HINDSIGHT_SEED_EXTRACTION_WAIT=6 HINDSIGHT_API_LOG=${D}/api-planted.log "${SEED}" > "${D}/stub-fail2.out" 2> "${D}/stub-fail2.err"
RC=$?
stub_stop
[ ${RC} -eq 0 ] || fail "3b: the second start against the stuck stand-in exited ${RC}"
grep -q "already seeded" "${D}/stub-fail2.out" || fail "3b: the second start did not recognise the stamp: $(head -3 "${D}/stub-fail2.out")"
grep -qx "state=failed" "${D}/state-stub2" || fail "3b: the second start with everything still pending did not record state=failed: $(cat "${D}/state-stub2")"
# the positive control: the stand-in reports every document extracted -> state complete, no WARNING
stub_start ${TOTAL} 0
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub-ok HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub-ok HINDSIGHT_SEED_EXTRACTION_WAIT=6 HINDSIGHT_API_LOG=${D}/api-planted.log "${SEED}" > "${D}/stub-ok.out" 2> "${D}/stub-ok.err"
RC=$?
stub_stop
[ ${RC} -eq 0 ] || { cat "${D}/stub-ok.err"; fail "3b: the seed against the stand-in API (everything extracted) exited ${RC}"; }
grep -q "WARNING" "${D}/stub-ok.out" && fail "3b: a WARNING although every document was extracted: $(grep WARNING "${D}/stub-ok.out")"
grep -qx "state=complete" "${D}/state-stub-ok" || fail "3b: the state file does not say state=complete: $(cat "${D}/state-stub-ok")"
# the watch can be turned off: state accepted, no wait
stub_start 0 7
HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${D}/stamp-stub-off HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 \
	HINDSIGHT_SEED_STATE=${D}/state-stub-off HINDSIGHT_SEED_EXTRACTION_WAIT=0 HINDSIGHT_API_LOG=${D}/api-planted.log "${SEED}" > "${D}/stub-off.out" 2>&1
stub_stop
grep -qx "state=accepted" "${D}/state-stub-off" || fail "3b: with the watch off the state is not 'accepted': $(cat "${D}/state-stub-off")"
echo "ok 3b - planted controls: items accepted but nothing extracted -> one WARNING naming the cause from the API log (ProfileNotFound; the client-forwarded texts: Legacy model, no model access, on-demand throughput, expired token, not authorized; an unknown ERROR line with its text), state=failed with the excerpt, acceptance stamped, and a restart says it again; only an old error -> stalled; a drained queue with every operation failed -> failed (empty excerpt, no Log line), with a throttling cause too (its text kept), while throttled with operations pending -> stalled; documents arriving over several polls -> complete; everything extracted at once -> no WARNING, state=complete; watch off -> state=accepted; a seed with its own stamp writes <stamp name>.state and leaves hindsight-seed.state alone"

# --- 3c. an item's `metadata` reaches the API as given (the knowledge lanes' class/layer/admission/correction fields;
#         the seed rebuilt each item without it before): the stand-in records what is posted. The read-back through the
#         API's document record needs the extraction to run (Bedrock credentials), so it is a live-run check, not this suite's ---
mkdir -p "${D}/meta-seed"
printf '{"meta-bank": {"name": "Meta bank", "mission": "a planted bank for the metadata control"}}\n' > "${D}/meta-seed/banks.json"
printf '{"document_id":"meta-001","content":"A planted fact that carries record metadata.","context":"planted","tags":["planted"],"metadata":{"class":"rule","layer":"aws-policy","admission":"reviewed","correction":"none"}}\n' > "${D}/meta-seed/meta-bank.jsonl"
: > "${D}/posted-items.jsonl"
( export STUB_RECORD="${D}/posted-items.jsonl"; setsid nohup python3 "${D}/stub-api.py" "${STUB_PORT}" 0 0 > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.25; done
HINDSIGHT_SEED_DIR=${D}/meta-seed HINDSIGHT_SEED_STAMP=${D}/stamp-meta HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 HINDSIGHT_SEED_EXTRACTION_WAIT=0 \
	HINDSIGHT_SEED_STATE=${D}/state-meta "${SEED}" > "${D}/seed-meta.out" 2>&1 || fail "3c: the seed with a metadata item failed: $(cat "${D}/seed-meta.out")"
stub_stop
python3 - "${D}/posted-items.jsonl" << 'PYCHK' || fail "3c: the posted item does not carry its metadata as given: $(cat "${D}/posted-items.jsonl")"
import json, sys
items = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
it = next((i for i in items if i.get("document_id") == "meta-001"), None)
assert it is not None, "meta-001 was not posted"
assert it.get("metadata") == {"class": "rule", "layer": "aws-policy", "admission": "reviewed", "correction": "none"}, it.get("metadata")
assert it.get("content") == "A planted fact that carries record metadata." and it.get("tags") == ["planted"] and it.get("context") == "planted"
PYCHK
echo "ok 3c - a seeded item's metadata reaches the API's retain request as given (class, layer, admission, correction), beside its content, context and tags"

# --- 3d. ... as strings: the memory API takes string metadata values only and refuses a whole batch with HTTP 422 for
#         any other (an item's metadata may carry one: model_likely_knows is a JSON boolean). The stand-in records what is posted: a
#         boolean arrives as "true"/"false", a number as its decimal text, a list as its JSON text, a null not at all,
#         a string unchanged - while the seed file keeps its JSON types ---
printf '{"document_id":"meta-002","content":"A planted fact with typed metadata.","context":"planted","tags":["planted"],"metadata":{"model_likely_knows":true,"stale":false,"count":3,"ratio":0.5,"tiny":1e-05,"tags":["a","b"],"gone":null,"layer":"build"}}\n' >> "${D}/meta-seed/meta-bank.jsonl"
: > "${D}/posted-items.jsonl"
( export STUB_RECORD="${D}/posted-items.jsonl"; setsid nohup python3 "${D}/stub-api.py" "${STUB_PORT}" 0 0 > "${D}/stub.log" 2>&1 & echo $! > "${D}/stub.pid" ); for i in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${STUB_PORT}/health" && break; sleep 0.25; done
HINDSIGHT_SEED_DIR=${D}/meta-seed HINDSIGHT_SEED_STAMP=${D}/stamp-meta2 HINDSIGHT_SEED_API=http://127.0.0.1:${STUB_PORT} HINDSIGHT_SEED_WAIT=10 HINDSIGHT_SEED_EXTRACTION_WAIT=0 \
	HINDSIGHT_SEED_STATE=${D}/state-meta2 "${SEED}" > "${D}/seed-meta2.out" 2>&1 || fail "3d: the seed with typed metadata failed: $(cat "${D}/seed-meta2.out")"
stub_stop
python3 - "${D}/posted-items.jsonl" "${D}/meta-seed/meta-bank.jsonl" << 'PYCHK' || fail "3d: the posted metadata are not all strings as converted: $(cat "${D}/posted-items.jsonl")"
import json, sys
items = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
it = next((i for i in items if i.get("document_id") == "meta-002"), None)
assert it is not None, "meta-002 was not posted"
want = {"model_likely_knows": "true", "stale": "false", "count": "3", "ratio": "0.5", "tiny": "0.00001", "tags": '["a", "b"]', "layer": "build"}
assert it.get("metadata") == want, it.get("metadata")
src = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
assert next(s for s in src if s["document_id"] == "meta-002")["metadata"]["model_likely_knows"] is True, "the seed file lost its JSON boolean"
PYCHK
echo "ok 3d - typed metadata reach the API as strings: true/false, 3, 0.5, 0.00001 and a list's JSON text, the null dropped, the string unchanged; the seed file keeps its JSON types"

# --- live preflight ---
if [ ! -x "${HINDSIGHT_BIN}" ]; then
	echo "ok 4-6 - (skipped: hindsight-api is not installed here - the live checks run in the image)"
	echo "Test17 succeeded"
	exit 0
fi

# --- 4. a test-local API, the seed lands ---
HHOME=${D}/hindsight-home
mkdir -p "${HHOME}"
	# the agent's AWS config for the API (what ui-start.sh does before the real API)
	"${AGENT_DIR}/hindsight-aws-config.sh" > /dev/null 2>&1 || true
setsid env HOME="${HHOME}" HF_HOME=/home/hindsight/.cache/huggingface \
	HINDSIGHT_API_LLM_PROVIDER="${HINDSIGHT_API_LLM_PROVIDER:-bedrock}" HINDSIGHT_API_WORKER_ID=test17 \
	AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-/home/hindsight/.aws/config}" AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/home/hindsight/.aws/credentials}" \
	HINDSIGHT_API_ENABLE_BANK_LLM_HEALTH=true \
	"${HINDSIGHT_BIN}" --host 127.0.0.1 --port "${API_PORT}" > "${D}/api.log" 2>&1 &
API_PGID=$!
for i in $(seq 1 300); do
	curl -sf --max-time 3 "${API}/health" 2>/dev/null | grep -q '"healthy"' && break
	sleep 1
done
curl -sf --max-time 3 "${API}/health" 2>/dev/null | grep -q '"healthy"' || { tail -20 "${D}/api.log"; fail "hindsight-api did not answer ${API}/health within 300s"; }
bank_url() { echo "${API}/v1/default/banks/$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1")"; }
# the number of bank $1's operations in status $2, from the operations list (empty when the API does not answer):
# /stats answers from a cache (60 s by default) unless asked to refresh, and its pending_operations leaves out the
# operations the worker has already claimed, which are 'processing'
ops_with() { curl -s --max-time 10 "$(bank_url "$1")/operations?status=$2&limit=1" | json - "d['total']"; }
# wait (bounded, 600 polls 2 s apart) until no operation of the banks named is pending or processing: a retain that is
# still processing writes its documents (an upsert), so a document deleted meanwhile comes back. Returns 1 at the first
# failed operation or at the bound; DRAIN_ACTIVE and DRAIN_FAILED hold what the last poll read.
drain()
{
	for i in $(seq 1 600); do
		DRAIN_ACTIVE=0
		DRAIN_FAILED=0
		for B in "$@"; do
			P=$(ops_with "${B}" pending)
			W=$(ops_with "${B}" processing)
			F=$(ops_with "${B}" failed)
			DRAIN_ACTIVE=$((DRAIN_ACTIVE + ${P:-1} + ${W:-1}))
			DRAIN_FAILED=$((DRAIN_FAILED + ${F:-0}))
		done
		[ "${DRAIN_FAILED}" -eq 0 ] || return 1
		[ "${DRAIN_ACTIVE}" -eq 0 ] && return 0
		sleep 2
	done
	return 1
}
ops_total()
{
	# retain operations only (the API schedules consolidation and maintenance operations of its
	# own, which must not count as "something was posted"); paged, the API caps limit at 100
	T=0
	for B in ${BANKS}; do
		N=$(python3 - "$(bank_url "${B}")" << 'PY' 2>/dev/null || echo 0
import json, sys, urllib.request
base = sys.argv[1]
n = offset = 0
while True:
    with urllib.request.urlopen(f"{base}/operations?limit=100&offset={offset}", timeout=10) as r:
        d = json.load(r)
    ops = d.get("operations", [])
    n += sum(1 for o in ops if o.get("task_type") in ("retain", "batch_retain"))
    if len(ops) < 100:
        break
    offset += 100
print(n)
PY
)
		T=$((T + ${N:-0}))
	done
	echo ${T}
}
STAMP=${D}/stamp
export HINDSIGHT_SEED_DIR=${SEED_DIR} HINDSIGHT_SEED_STAMP=${STAMP} HINDSIGHT_SEED_API=${API} HINDSIGHT_SEED_WAIT=60 HINDSIGHT_SEED_BATCH=20
"${SEED}" > "${D}/seed-1.out" 2> "${D}/seed-1.err" || { cat "${D}/seed-1.err"; fail "hindsight-seed.sh failed against ${API}"; }
[ -f "${STAMP}" ] || fail "no stamp at ${STAMP} after a successful seed"
grep -qE '^sha256=[0-9a-f]{64}$' "${STAMP}" || fail "the stamp carries no sha256: $(cat "${STAMP}")"
grep -qE "^items=${TOTAL}$" "${STAMP}" || fail "the stamp does not count ${TOTAL} items: $(cat "${STAMP}")"
LISTED=$(curl -s --max-time 10 "${API}/v1/default/banks?limit=100" | json - "json.dumps({b['bank_id']: b.get('name') for b in d['banks']})")
EXPECTED_OPS=0
for B in ${BANKS}; do
	echo "${LISTED}" | grep -qF "\"${B}\"" || fail "bank ${B} is not listed by the API: ${LISTED}"
	NAME=$(json "${SEED_DIR}/banks.json" "d['${B}']['name']")
	echo "${LISTED}" | grep -qF "\"${B}\": \"${NAME}\"" || fail "bank ${B} does not carry its seed name '${NAME}': ${LISTED}"
	grep -qE "^bank:${B}=${EXPECTED[${B}]}$" "${STAMP}" || fail "the stamp does not count ${EXPECTED[${B}]} items for ${B}: $(cat "${STAMP}")"
	EXPECTED_OPS=$((EXPECTED_OPS + (EXPECTED[${B}] + 19) / 20))
done
OPS1=0
for i in $(seq 1 30); do
	OPS1=$(ops_total)
	[ "${OPS1}" -ge "${EXPECTED_OPS}" ] && break
	sleep 1
done
[ "${OPS1}" -ge "${EXPECTED_OPS}" ] || fail "the API recorded ${OPS1} operations, expected at least ${EXPECTED_OPS} (one per batch of 20)"
echo "ok 4 - seeded ${TOTAL} items into ${BANKS// /, }: stamp written, banks listed with their names, ${OPS1} operations recorded (>= ${EXPECTED_OPS} batches)"

# --- 4b. against the same API: a bank whose items carry a boolean metadata value is accepted, and every bank's count
#         reaches the stamp and the status row. Before the conversion (3d) the API answered that batch HTTP 422, the seed
#         stopped there without a stamp or a state, and every bank after it was never seeded ---
mkdir -p "${D}/typed-seed"
printf '{"a-strings": {"name": "Strings bank", "mission": "a planted bank with string metadata"}, "b-booleans": {"name": "Booleans bank", "mission": "a planted bank with a boolean metadata value"}}\n' > "${D}/typed-seed/banks.json"
for N in 1 2; do printf '{"document_id":"str-%s","content":"A planted fact number %s with string metadata.","context":"planted","tags":["planted"],"metadata":{"layer":"build"}}\n' "${N}" "${N}"; done > "${D}/typed-seed/a-strings.jsonl"
for N in 1 2 3; do printf '{"document_id":"bool-%s","content":"A planted fact number %s with a boolean in its metadata.","context":"planted","tags":["planted"],"metadata":{"layer":"aws-policy","model_likely_knows":%s}}\n' "${N}" "${N}" "$([ "${N}" = 2 ] && echo false || echo true)"; done > "${D}/typed-seed/b-booleans.jsonl"
HINDSIGHT_SEED_DIR=${D}/typed-seed HINDSIGHT_SEED_STAMP=${D}/stamp-typed HINDSIGHT_SEED_EXTRACTION_WAIT=0 HINDSIGHT_SEED_STATE=${D}/state-typed \
	"${SEED}" > "${D}/seed-typed.out" 2>&1 || fail "4b: the seed of a bank with a boolean metadata value failed: $(grep -m1 -E 'refused|HTTP|failed' "${D}/seed-typed.out")"
for KV in a-strings=2 b-booleans=3 items=5; do
	K=${KV%%=*}; [ "${K}" != items ] && K=bank:${K}
	grep -qx "${K}=${KV#*=}" "${D}/stamp-typed" || fail "4b: the stamp does not count ${KV}: $(cat "${D}/stamp-typed")"
done
ROW=$(UI_HINDSIGHT=true UI_DIR=${D}/ui-typed HINDSIGHT_SEED_STATE=${D}/state-typed "${AGENT_DIR}/ui-status.sh" 2> /dev/null | grep '^hindsight-seed:')
[ "${ROW}" == "hindsight-seed: ACCEPTED documents=0/5 (the extraction watch is off: HINDSIGHT_SEED_EXTRACTION_WAIT=0; /stats shows the extraction)" ] \
	|| fail "4b: the status row does not carry the 5 accepted items of both banks: '${ROW}'"
echo "ok 4b - a bank whose items carry a boolean metadata value is accepted by the API (bank:a-strings=2, bank:b-booleans=3, items=5 in the stamp) and the status row reads ${ROW#hindsight-seed: }"

# --- 5. idempotency gates ---
sleep 5
OPS_BEFORE=$(ops_total)
"${SEED}" > "${D}/seed-2.out" 2>&1 || fail "the second run exited non-zero: $(cat "${D}/seed-2.out")"
grep -q "already seeded" "${D}/seed-2.out" || fail "the second run did not say already seeded: $(cat "${D}/seed-2.out")"
sleep 3
[ "$(ops_total)" == "${OPS_BEFORE}" ] || fail "the second run posted again (operations ${OPS_BEFORE} -> $(ops_total))"
HINDSIGHT_SEED=false HINDSIGHT_SEED_STAMP=${D}/stamp-off "${SEED}" > "${D}/seed-off.out" 2>&1 || fail "HINDSIGHT_SEED=false exited non-zero"
grep -q "disabled (HINDSIGHT_SEED=false) - nothing posted" "${D}/seed-off.out" || fail "HINDSIGHT_SEED=false did not report itself: $(cat "${D}/seed-off.out")"
[ -e "${D}/stamp-off" ] && fail "HINDSIGHT_SEED=false wrote a stamp"
sleep 3
[ "$(ops_total)" == "${OPS_BEFORE}" ] || fail "HINDSIGHT_SEED=false still posted (operations ${OPS_BEFORE} -> $(ops_total))"
STAMP_T1=$(stat -c %Y "${STAMP}")
sleep 1
"${SEED}" --force > "${D}/seed-3.out" 2>&1 || fail "--force exited non-zero: $(cat "${D}/seed-3.out")"
grep -q "done - ${TOTAL} items" "${D}/seed-3.out" || fail "--force did not re-post: $(cat "${D}/seed-3.out")"
[ "$(stat -c %Y "${STAMP}")" -gt "${STAMP_T1}" ] || fail "--force did not rewrite the stamp"
OPS3=0
for i in $(seq 1 30); do
	OPS3=$(ops_total)
	[ "${OPS3}" -ge $((OPS_BEFORE + EXPECTED_OPS)) ] && break
	sleep 1
done
[ "${OPS3}" -ge $((OPS_BEFORE + EXPECTED_OPS)) ] || fail "--force did not post every batch again (operations ${OPS_BEFORE} -> ${OPS3})"
echo "ok 5 - second run: already seeded, nothing posted; HINDSIGHT_SEED=false: nothing posted, no stamp; --force: re-posted (operations ${OPS_BEFORE} -> ${OPS3}), stamp rewritten"

# --- 6. counts after extraction (LLM) ---
FIRST_BANK=${BANKS%% *}
LLM=$(curl -s --max-time 60 -X POST -H 'content-type: application/json' --data '{}' "$(bank_url "${FIRST_BANK}")/health/llm" \
	| json - "next((o.get('status','?') for o in d.get('operations',[]) if o.get('operation')=='retain'), 'unknown')")
LLM=${LLM:-unknown}
if [ "${LLM}" == "connected" ]; then
	# drain: every operation of the two seed runs over (none pending or processing, none failed), bounded
	# shellcheck disable=SC2086 # the bank names, one word each
	drain ${BANKS}
	[ "${DRAIN_FAILED}" -eq 0 ] || { for B in ${BANKS}; do curl -s "$(bank_url "${B}")/operations" | json - "[(o['task_type'],o['status'],(o.get('error_message') or '')[:160]) for o in d['operations'] if o['status']=='failed']"; done; fail "${DRAIN_FAILED} seed operation(s) failed"; }
	[ "${DRAIN_ACTIVE}" -eq 0 ] || fail "the seed queue did not drain within 20 minutes (${DRAIN_ACTIVE} operation(s) pending or processing)"
	for B in ${BANKS}; do
		S=$(curl -s --max-time 10 "$(bank_url "${B}")/stats?refresh=true")
		DOCS=$(echo "${S}" | json - "d.get('total_documents',0)")
		NODES=$(echo "${S}" | json - "d.get('total_nodes',0)")
		[ "${DOCS}" == "${EXPECTED[${B}]}" ] || fail "bank ${B}: total_documents ${DOCS} != ${EXPECTED[${B}]} unique seed ids (after the seed and a --force re-run: stable ids must update in place, never duplicate)"
		[ "${NODES:-0}" -ge 1 ] 2>/dev/null || fail "bank ${B}: total_nodes is ${NODES} after extraction"
		echo "    bank ${B}: total_documents=${DOCS} total_nodes=${NODES}"
	done
	# the extraction state after the drain: a plain run (already seeded, nothing pending) records complete
	"${SEED}" > "${D}/seed-final.out" 2>&1 || { cat "${D}/seed-final.out"; fail "6: the final plain run failed"; }
	grep -qx "state=complete" "${HINDSIGHT_SEED_STATE}" || fail "6: after the drain the state file does not say complete: $(cat "${HINDSIGHT_SEED_STATE}")"
	echo "ok 6 - counts after extraction: total_documents equals the unique seed ids per bank (no duplicates after --force), total_nodes > 0 everywhere; the state file says complete"

	# --- 6b. planted control: the stamp alone is not trusted - a bank that lost a document is re-seeded ---
	# (the stamp records acceptance; here a document is deleted from the smallest bank, the API reports one
	# fewer with nothing pending, and a plain run must re-seed instead of saying "already seeded")
	LAST_BANK=${BANKS##* }
	LOST=$(curl -s --max-time 10 "$(bank_url "${LAST_BANK}")/documents?limit=1" | json - "(d.get('items') or d)[0]['id']")
	[ -n "${LOST}" ] || fail "6b: could not pick a document of ${LAST_BANK} to delete"
	# the delete lands on an idle bank: a retain of the document still processing would write it back
	drain "${LAST_BANK}" || fail "6b: ${LAST_BANK} did not go idle before the delete (${DRAIN_ACTIVE} operation(s) pending or processing, ${DRAIN_FAILED} failed)"
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X DELETE "$(bank_url "${LAST_BANK}")/documents/${LOST}")
	[ "${HTTP}" == "200" ] || fail "6b: DELETE document ${LOST} of ${LAST_BANK} -> ${HTTP}"
	# the API processes the delete asynchronously (it queues follow-up operations): wait until the bank reports
	# one document fewer AND nothing pending - a plain seed run must then re-seed (with operations still pending
	# it rightly says "extraction still running" and posts nothing)
	for i in $(seq 1 60); do
		S=$(curl -s --max-time 10 "$(bank_url "${LAST_BANK}")/stats?refresh=true")
		DOCS=$(echo "${S}" | json - "d.get('total_documents',0)")
		P6=$(echo "${S}" | json - "d.get('pending_operations',0)")
		[ "${DOCS}" == "$((EXPECTED[${LAST_BANK}] - 1))" ] && [ "${P6}" == "0" ] && break
		sleep 2
	done
	[ "${DOCS}" == "$((EXPECTED[${LAST_BANK}] - 1))" ] && [ "${P6}" == "0" ] \
		|| fail "6b: ${LAST_BANK} reports ${DOCS} documents and ${P6} pending operation(s) 120s after deleting ${LOST} (expected $((EXPECTED[${LAST_BANK}] - 1)) and 0)"
	OPS6=$(ops_total)
	"${SEED}" > "${D}/seed-6b.out" 2>&1 || fail "6b: the run after the loss exited non-zero: $(cat "${D}/seed-6b.out")"
	grep -q "fewer documents than were accepted" "${D}/seed-6b.out" || fail "6b: the run after the loss did not notice the bank is short (planted control: the stamp was trusted blindly): $(cat "${D}/seed-6b.out")"
	grep -q "re-seeding" "${D}/seed-6b.out" || fail "6b: the run after the loss did not re-seed: $(cat "${D}/seed-6b.out")"
	[ "$(ops_total)" -gt "${OPS6}" ] || fail "6b: the run after the loss posted nothing (operations ${OPS6} -> $(ops_total))"
	RESTORED=false
	for i in $(seq 1 150); do
		DOCS=$(curl -s --max-time 10 "$(bank_url "${LAST_BANK}")/stats?refresh=true" | json - "d.get('total_documents',0)")
		[ "${DOCS}" == "${EXPECTED[${LAST_BANK}]}" ] && { RESTORED=true; break; }
		sleep 2
	done
	[ "${RESTORED}" == "true" ] || fail "6b: ${LAST_BANK} did not come back to ${EXPECTED[${LAST_BANK}]} documents within 5 minutes of the re-seed (now ${DOCS})"
	echo "ok 6b - planted control: with ${LOST} deleted from ${LAST_BANK} ($((EXPECTED[${LAST_BANK}] - 1))/${EXPECTED[${LAST_BANK}]}, nothing pending) a plain run re-seeds instead of trusting the stamp; the bank is back to ${EXPECTED[${LAST_BANK}]} documents"
else
	ERR=$(curl -s --max-time 10 "$(bank_url "${FIRST_BANK}")/operations" | json - "next(((o.get('error_message') or '')[:160] for o in d['operations'] if o.get('error_message')), '')")
	echo "ok 6 - (skipped: no working LLM for the API's extraction here - health/llm says '${LLM}'${ERR:+; last error: ${ERR}}; the items were accepted in check 4, extraction needs Bedrock credentials)"
fi

echo "Test17 succeeded"
