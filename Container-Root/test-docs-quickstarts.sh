#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the per-persona quickstarts (docs/quickstarts/*.md, from docs/PERSONAS.md): a quickstart that names a
# script, a document or a setting that does not exist sends a reader nowhere, so every one it names must exist in the
# tree. Fully OFFLINE, static. Each check FAILS if the property it proves is removed:
#   1. every path-like code span in every quickstart exists: /agent/<x> -> Container-Root/agent/<x>, /seed/<x> ->
#      Container-Root/seed/<x>, ./<x>.sh and bare <x>.sh -> the repository root (or Container-Root), docs/... -> docs/...,
#      .env -> .env; runtime paths (/wd/..., /home/agent/..., http://...) are not files of the tree and are skipped
#   2. every UPPER_CASE setting named in a quickstart is a setting .env or the README documents
#   3. PERSONAS.md links one quickstart per persona (7), every linked file exists, and every quickstart is linked;
#      the README links PERSONAS.md
#   4. PLANTED CONTROL: a copy of a quickstart naming /agent/no-such-script.sh fails check 1 on that copy
#   5. the seed's privacy scan passes the quickstarts and PERSONAS.md (no name, id or secret)
#   6. the "What runs" section of docs/manual/install.md names every container run.sh, plane.sh and kanban.sh create: the agent
#      container (CONTAINER itself), Plane's sidecars and migrator (plane.sh's start_sidecar calls and MIG), the
#      Goals board's sidecars and relay (the KANBAN_*_NAME settings), the docker spoke's build substrate (the
#      DOCKER_*_NAME settings); PLANTED CONTROL: a copy of the README with one row removed fails and the missing name is
#      the one removed
set -u
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
D=/tmp/docs-quickstarts-smoke
rm -rf "${D:?}"
mkdir -p ${D}
fail() { echo "Test-docs-quickstarts FAILED: $*"; exit 1; }
# this test reads the repository tree: the quickstarts and the scripts, documents and settings they name. The tree is
# the checkout this test lies in (bash Container-Root/test-docs-quickstarts.sh), or, in the image - which ships neither
# docs/quickstarts nor Container-Root/, nothing at run time reads them - the checkout at /do-agent-aws, where ./test.sh
# mounts it and the sandbox tests copy it (test10 and test22 read it there the same way). Without either the run has
# nothing to check and says so; a checkout missing its quickstarts still fails
ROOT=""
for C in "${BASE_DIR}/.." /do-agent-aws; do
	if [ -d "${C}/docs/quickstarts" ] || [ -d "${C}/Container-Root" ]; then ROOT="$(cd "${C}" && pwd)"; break; fi
done
if [ -z "${ROOT}" ]; then
	echo "Test-docs-quickstarts skipped: not a repository checkout (no docs/quickstarts and no Container-Root beside ${BASE_DIR} or at /do-agent-aws) - run it from a checkout: bash Container-Root/test-docs-quickstarts.sh"
	exit 0
fi
QS=${ROOT}/docs/quickstarts
[ -d "${QS}" ] || fail "no ${QS}"

check_paths()
{
	# check_paths <dir> - every path-like code span in <dir>/*.md exists in the tree; prints the misses
	python3 - "${ROOT}" "$1" << 'PY'
import glob, os, re, sys
root, qdir = sys.argv[1], sys.argv[2]
miss = []
for f in sorted(glob.glob(os.path.join(qdir, "*.md"))):
    spans = re.findall(r"`([^`\n]+)`", open(f).read())
    for sp in spans:
        tok = sp.split()[0] if sp.split() else ""
        if not tok or tok.startswith(("http://", "https://", "/wd/", "/home/agent/", "ssh", "aws", "kubectl", "<")):
            continue
        cands = None
        if tok.startswith("/agent/"): cands = [os.path.join(root, "Container-Root", tok[1:])]
        elif tok.startswith("/seed/"): cands = [os.path.join(root, "Container-Root", tok[1:])]
        elif tok.startswith("./"): cands = [os.path.join(root, tok[2:])]
        elif tok.startswith("docs/"): cands = [os.path.join(root, tok)]
        elif tok == ".env": cands = [os.path.join(root, ".env")]
        elif re.fullmatch(r"[a-z0-9-]+\.sh", tok): cands = [os.path.join(root, tok), os.path.join(root, "Container-Root", tok)]
        if cands is None:
            continue
        if not any(os.path.exists(c) for c in cands):
            miss.append(f"{os.path.basename(f)}: `{sp}`")
print("\n".join(miss))
sys.exit(1 if miss else 0)
PY
}

# --- 1. every named path exists ---
MISS=$(check_paths "${QS}") || fail "a quickstart names a file that is not in the tree: $(echo "${MISS}" | tr '\n' ';')"
N=$(ls ${QS}/*.md | wc -l)
echo "ok 1 - every script, document and setting file the ${N} quickstarts name exists in the tree"

# --- 2. settings named exist ---
for T in $(grep -ohE '`[A-Z][A-Z0-9_]{3,}`' ${QS}/*.md | tr -d '`' | sort -u); do
	grep -qE "(^|[^A-Z0-9_])${T}([^A-Z0-9_]|$)" "${ROOT}/.env" "${ROOT}/README.md" "${ROOT}"/docs/manual/*.md || fail "a quickstart names the setting ${T}, which .env, the README and the manual do not document"
done
echo "ok 2 - every UPPER_CASE setting a quickstart names is documented in .env, the README or the manual"

# --- 3. one quickstart per persona, all linked, README link ---
P="${ROOT}/docs/PERSONAS.md"
[ "$(grep -c '^## P[0-9]\.' "${P}")" == "7" ] || fail "PERSONAS.md does not list seven personas"
[ "$(grep -c '^- \*\*Quickstart:\*\* \[quickstarts/' "${P}")" == "7" ] || fail "PERSONAS.md does not link one quickstart per persona: $(grep -c 'Quickstart' "${P}")"
for L in $(grep -oE '\(quickstarts/[a-z-]+\.md\)' "${P}" | tr -d '()'); do
	[ -f "${ROOT}/docs/${L}" ] || fail "PERSONAS.md links ${L}, which does not exist"
done
for F in ${QS}/*.md; do
	grep -qF "(quickstarts/$(basename "${F}"))" "${P}" || fail "$(basename "${F}") is not linked from PERSONAS.md"
done
grep -qF '[docs/PERSONAS.md](docs/PERSONAS.md)' "${ROOT}/README.md" || fail "the README does not link docs/PERSONAS.md"
echo "ok 3 - PERSONAS.md links one existing quickstart per persona, every quickstart is linked, the README links PERSONAS.md"

# --- 4. planted control ---
mkdir -p ${D}/planted && cp ${QS}/install-your-own.md ${D}/planted/ && printf '\nRun `/agent/no-such-script.sh` first.\n' >> ${D}/planted/install-your-own.md
MISS=$(check_paths "${D}/planted") && fail "PLANTED CONTROL BROKEN: a quickstart naming /agent/no-such-script.sh passed"
echo "${MISS}" | grep -qF 'no-such-script.sh' || fail "PLANTED CONTROL BROKEN: the miss is not the planted script: ${MISS}"
echo "ok 4 - PLANTED CONTROL: a quickstart naming a script that does not exist fails the check and is named"

# --- 5. the privacy scan ---
SCAN=${ROOT}/Container-Root/seed/scan.py
if python3 -I "${SCAN}" --tree "${QS}" "${P}" > ${D}/scan.out 2>&1; then
	echo "ok 5 - the privacy scan passes the quickstarts and PERSONAS.md ($(tail -1 ${D}/scan.out))"
else
	grep -q 'unrecognized arguments: --tree' ${D}/scan.out && echo "ok 5 - (skipped: this scan.py has no tree mode)" || fail "the privacy scan refuses the quickstarts or PERSONAS.md: $(cat ${D}/scan.out | tail -3)"
fi

# --- 6. the "What runs" section names every container the scripts create ---
check_what_runs()
{
	# check_what_runs <page> - every container name suffix the scripts create appears in the "What runs" section of
	# docs/manual/install.md (between its heading and the next section heading); prints the misses, exits 1 on any
	python3 - "${ROOT}" "$1" << 'PY'
import re, sys
root, readme = sys.argv[1], sys.argv[2]
text = open(readme).read()
m = re.search(r"^## What runs\n(.*?)(?=^## )", text, re.S | re.M)
if not m:
    print("no \"## What runs\" section"); sys.exit(1)
section = m.group(1)
plane = open(f"{root}/plane.sh").read()
names = ["-plane-" + s for s in re.findall(r"^\s*start_sidecar (\S+) ", plane, re.M)]
names += ["-plane-" + s for s in re.findall(r"^\s*MIG=\$\{PLANE_NAME\}-(\S+)", plane, re.M)]
env = open(f"{root}/.env").read()
names += ["-" + s for s in re.findall(r"^export KANBAN_[A-Z_]+_NAME=\$\{CONTAINER\}-(kanban-[a-z-]+)", env, re.M)]
names += ["-" + s for s in re.findall(r"^export DOCKER_[A-Z_]+_NAME=\$\{CONTAINER\}-([a-z-]+)", env, re.M)]
if len(names) < 16:
    print(f"only {len(names)} container names parsed from plane.sh and .env: {names}"); sys.exit(1)
miss = [n for n in names if f"`{n}`" not in section]
if "`do-agent-aws` (the name itself)" not in section:
    miss.append("the agent container (CONTAINER itself)")
if miss:
    print("\n".join(miss)); sys.exit(1)
print(f"{len(names)} sidecar names + the agent container")
PY
}
OUT=$(check_what_runs "${ROOT}/docs/manual/install.md") || fail "the \"What runs\" section of docs/manual/install.md misses a container the scripts create: ${OUT}"
mkdir -p ${D}/what-runs && grep -v -- '^| `-plane-beat-worker` ' "${ROOT}/docs/manual/install.md" > ${D}/what-runs/install.md
MISS=$(check_what_runs "${D}/what-runs/install.md") && fail "PLANTED CONTROL BROKEN: a page without the -plane-beat-worker row passed"
[ "${MISS}" == "-plane-beat-worker" ] || fail "PLANTED CONTROL BROKEN: the miss is not the removed row alone: ${MISS}"
echo "ok 6 - the \"What runs\" section of docs/manual/install.md names every container the scripts create (${OUT}); PLANTED CONTROL: a copy without one row fails naming it"

echo "Test-docs-quickstarts succeeded"
