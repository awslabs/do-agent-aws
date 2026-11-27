#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the doctor's packages check (/agent/doctor.sh --check packages; docs/manual/install.md "Setup doctor" and "Moving
# knowledge between instances"; iankouls-aws/aws-do-agent#175): the shared knowledge packages are the repositories cloned
# under KNOWLEDGE_DIR and the packs imported on the Knowledge transfer page, kept in KNOWLEDGE_IMPORTED_DIR and loaded at
# every start. A kept pack reads as loaded when the two load ledgers agree with its manifest: the LogLearner loader's
# .installed-packs.json beside the bank (loglearner.pack ingest) and the .loaded.json stamp knowledge-transfer.py writes
# after its Hindsight load. Offline and self-contained: every path the doctor reads or writes (KNOWLEDGE_DIR,
# KNOWLEDGE_IMPORTED_DIR, SETUP_DIR, the LogLearner state) is under one temporary directory, the memory API is a
# test-local stub on 127.0.0.1 answering bank stats, and nothing under /wd is touched. A failed run keeps its trees and
# names them.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the doctor parses (bash -n, its Python compiles)
#   2. no package at all (KNOWLEDGE_DIR holds defaults/ and an empty imported/) -> GAP "no shared knowledge package
#      loaded"; the remedy names the Knowledge transfer page as the other way to load shared knowledge
#   3. a kept pack with both ledger entries -> PASS; the row reads "imported <name> <version> (<records> records, loaded)";
#      the JSON facts carry it (name, version, records, loaded true) beside packages and repos; the LogLearner ledger is
#      the one the runtime's own loader writes (python3 -m loglearner.pack ingest), so the shape the doctor reads is the
#      shape the loader writes
#   4. the same pack with the ledgers missing -> GAP naming the pack and both stores, the remedy carries
#      loglearner-packs.sh and knowledge-transfer.py load and never the CLAUDE.md line; PLANTED CONTROLS: one ledger
#      alone (LogLearner only, Hindsight only) is still a GAP naming the store that is missing; a LogLearner entry with
#      another sha256 (the pack's bytes changed since that load) or with the right sha256 under another version, and a
#      stamp with another sha256, do not count (the ledgers are compared on sha256 and version, not on presence)
#   5. a kept pack beside a cloned repository (seeds/banks.json, named in CLAUDE.md, its bank with documents) -> two rows
#      and PASS; with the repository's bank empty the GAP names the repository and not the pack, both rows still listed
#   6. the string "imported: the agent is not told where it is" (the misreading #175 reports) appears in none of the
#      outputs; a Hindsight-only pack is loaded by its stamp alone, a LogLearner-only pack by its ledger entry alone; an
#      unreadable manifest (PLANTED CONTROL: an empty file, #175's own reproduction) is a GAP naming the file while the
#      pack beside it still reads loaded, and so is a manifest that is a JSON object listing no LogLearner or Hindsight
#      file (PLANTED CONTROL: {}), which never reads loaded; KNOWLEDGE_IMPORTED_DIR outside KNOWLEDGE_DIR is honoured;
#      with the memory API off (UI_HINDSIGHT=false) the Hindsight store's GAP names that reason

D=$(mktemp -d)
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
DOCTOR=${AGENT_DIR}/doctor.sh
LOGLEARNER_DIR=${LOGLEARNER_DIR:-/opt/loglearner}
[ -f "${LOGLEARNER_DIR}/loglearner/pack.py" ] || LOGLEARNER_DIR=${BASE_DIR%/}/opt/loglearner
BAD="imported: the agent is not told where it is"
CLAUDE_REMEDY="add the package's CLAUDE.md block"
PIDS=()
FAILED=""

fail()
{
	FAILED=1
	echo "Test-doctor-packages FAILED: $1 (the trees are kept under ${D})"
	exit 1
}

cleanup()
{
	for P in "${PIDS[@]}"; do kill "${P}" 2>/dev/null; done
	[ -n "${FAILED}" ] || rm -rf "${D:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- the memory API stub: /health healthy, /v1/default/banks/<bank>/stats with total_documents from ${D}/stub-docs/<bank>
# (no file: 0). It binds a free port on 127.0.0.1 and writes the port to ${D}/stub-port
mkdir -p "${D}/stub-docs"
python3 - "${D}/stub-docs" "${D}/stub-port" << 'PY' > "${D}/stub.log" 2>&1 &
import http.server, json, os, sys, urllib.parse
root, port_file = sys.argv[1:3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = urllib.parse.unquote(self.path.split("?")[0])
        if p == "/health":
            body = {"status": "healthy"}
        elif p.startswith("/v1/default/banks/") and p.endswith("/stats"):
            try:
                n = int(open(os.path.join(root, os.path.basename(p[len("/v1/default/banks/"):-len("/stats")]))).read().strip())
            except (OSError, ValueError):
                n = 0
            body = {"total_documents": n}
        else:
            self.send_response(404); self.end_headers(); return
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers()
        self.wfile.write(data)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(port_file + ".tmp", "w") as f: f.write(str(srv.server_address[1]))
os.replace(port_file + ".tmp", port_file)
srv.serve_forever()
PY
PIDS+=($!)
for i in $(seq 1 40); do [ -s "${D}/stub-port" ] && break; sleep 0.25; done
[ -s "${D}/stub-port" ] || fail "the memory API stub did not start: $(cat "${D}/stub.log")"
STUB_PORT=$(cat "${D}/stub-port")
python3 -c 'import sys, urllib.request
print(urllib.request.build_opener(urllib.request.ProxyHandler({})).open("http://127.0.0.1:%s/health" % sys.argv[1], timeout=5).read().decode())' "${STUB_PORT}" | grep -q healthy \
	|| fail "the memory API stub does not answer /health on port ${STUB_PORT}"

# --- helpers ---
# tree <name> - a fresh temp tree: knowledge/defaults (the image's own copy, never a package), setup/, the LogLearner state
tree() { local T=${D}/$1; mkdir -p "${T}/knowledge/defaults" "${T}/setup" "${T}/loglearner/banks/global"; echo "${T}"; }
# doctor <tree> [VAR=value ...] - /agent/doctor.sh --check packages over <tree>: knowledge/ is KNOWLEDGE_DIR (CLAUDE.md beside
# it), setup/ SETUP_DIR, loglearner/ LOGLEARNER_STATE, the stub the memory API; stdout in <tree>/out, the exit code in RC
doctor()
{
	local T=$1
	shift
	RC=0
	env -u LOGLEARNER_BANKS_DIR -u INSTINCTS_JSON -u KNOWLEDGE_IMPORTED_DIR -u HINDSIGHT_SEED_DIR KNOWLEDGE_DIR="${T}/knowledge" \
		SETUP_DIR="${T}/setup" LOGLEARNER_STATE="${T}/loglearner" UI_DIR="${T}/ui" HINDSIGHT_API="http://127.0.0.1:${STUB_PORT}" \
		UI_START=true UI_HINDSIGHT=true "$@" "${DOCTOR}" --check packages > "${T}/out" 2> "${T}/err" || RC=$?
}
# row <tree> - the packages row of the doctor's text (state and found)
row() { grep -E '^  packages +' "$1/out" | head -1 | sed -E 's/^  packages +//'; }
# fact <tree> <python expression over c> - c is the packages entry of <tree>/setup/doctor.json (the doctor's JSON state)
fact()
{
	python3 -c 'import json, sys
c = [c for c in json.load(open(sys.argv[1]))["checks"] if c["id"] == "packages"][0]
print(eval(sys.argv[2]))' "$1/setup/doctor.json" "$2"
}
# pack <imported dir> <name> <version> [both|loglearner|hindsight] - a kept pack: <name>.jsonl (2 LogLearner records),
# <name>.hindsight.jsonl (3 documents of the bank <name>-bank) and <name>.manifest.json in the shape knowledge-transfer.py
# export_pack writes: files with path, store, records, sha256; the manifest's own sha256 is the LogLearner file's
pack()
{
	mkdir -p "$1"
	python3 - "$1" "$2" "$3" "${4:-both}" << 'PY'
import hashlib, json, os, sys
d, name, version, stores = sys.argv[1:5]
files = []
if stores in ("both", "loglearner"):
    rows = [{"id": "%s-%03d" % (name, i), "rule": "Rule %d of the pack %s." % (i, name), "evidence": "planted by test-doctor-packages.sh",
             "confidence": "high", "source": "test", "provenance": "test", "status": "positive"} for i in (1, 2)]
    blob = "".join(json.dumps(r) + "\n" for r in rows).encode()
    open(os.path.join(d, name + ".jsonl"), "wb").write(blob)
    files.append({"path": name + ".jsonl", "store": "loglearner", "records": len(rows), "sha256": hashlib.sha256(blob).hexdigest()})
if stores in ("both", "hindsight"):
    docs = [{"bank": name + "-bank", "id": "%s-doc-%d" % (name, i), "text": "Document %d of the pack %s." % (i, name), "facts": []} for i in (1, 2, 3)]
    blob = "".join(json.dumps(x) + "\n" for x in docs).encode()
    open(os.path.join(d, name + ".hindsight.jsonl"), "wb").write(blob)
    files.append({"path": name + ".hindsight.jsonl", "store": "hindsight", "records": len(docs), "sha256": hashlib.sha256(blob).hexdigest(),
                  "transfer_schema": 1, "banks": {name + "-bank": {"records": len(docs), "name": name + " bank", "mission": ""}}})
m = {"name": name, "version": version, "as_of": "2026-10-27"}
if files[0]["store"] == "loglearner":
    m["sha256"] = files[0]["sha256"]
m.update({"records": sum(f["records"] for f in files), "files": files})
with open(os.path.join(d, name + ".manifest.json"), "w") as f:
    f.write(json.dumps(m, indent=1) + "\n")
PY
}
# sha_of <manifest> <store> - the sha256 the manifest records for its <store> file
sha_of() { python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); print([f["sha256"] for f in m["files"] if f["store"] == sys.argv[2]][0])' "$1" "$2"; }
# installed <tree> <name> <version> <sha256> - one entry of the LogLearner loader's ledger beside the bank, in the shape
# loglearner.pack ingest appends (name, version, sha256, pack, at, added, updated, skipped)
installed()
{
	python3 - "$1/loglearner/banks/global/.installed-packs.json" "$2" "$3" "$4" << 'PY'
import json, os, sys
p, name, version, sha = sys.argv[1:5]
prior = json.load(open(p)) if os.path.isfile(p) else []
prior.append({"name": name, "version": version, "sha256": sha, "pack": "/wd/knowledge/imported/%s.jsonl" % name,
              "at": "2026-10-27T00:00:00Z", "added": 2, "updated": 0, "skipped": 0})
with open(p, "w") as f:
    f.write(json.dumps(prior, indent=1) + "\n")
PY
}
# stamp <imported dir> <name> <sha256> - the pack's entry of the .loaded.json stamp, in the shape knowledge-transfer.py
# load_hindsight writes (the Hindsight file's sha256 and each bank's count)
stamp()
{
	python3 - "$1/.loaded.json" "$2" "$3" << 'PY'
import json, os, sys
p, name, sha = sys.argv[1:4]
s = json.load(open(p)) if os.path.isfile(p) else {}
s[name] = {"sha256": sha, "banks": {name + "-bank": 3}}
with open(p, "w") as f:
    f.write(json.dumps(s, indent=1, sort_keys=True) + "\n")
PY
}
# repo <tree> <name> <documents> - a cloned package repository knowledge/<name>: seeds/banks.json naming one bank,
# <tree>/CLAUDE.md pointing at the directory (today's check), and the stub's document count for that bank
repo()
{
	mkdir -p "$1/knowledge/$2/seeds"
	echo "{\"$2-bank\": {\"name\": \"$2\"}}" > "$1/knowledge/$2/seeds/banks.json"
	echo "# the shared knowledge package $2 is at $1/knowledge/$2" >> "$1/CLAUDE.md"
	echo "$3" > "${D}/stub-docs/$2-bank"
}

# --- 1. syntax ---
bash -n "${DOCTOR}" || fail "doctor.sh does not parse"
sed -n "/^exec python3 -I - \"\$@\" << 'PY'\$/,/^PY\$/p" "${DOCTOR}" | sed '1d;$d' | python3 -c 'import ast, sys; ast.parse(sys.stdin.read())' \
	|| fail "the doctor's Python does not compile"
echo "ok 1 - syntax"

# --- 2. no package at all ---
T=$(tree a)
mkdir -p "${T}/knowledge/imported"
doctor "${T}"
[ "${RC}" == "1" ] || fail "no package: expected exit 1 (a GAP), got ${RC}: $(row "${T}") $(cat "${T}/err")"
R=$(row "${T}")
echo "${R}" | grep -q "^GAP .*no shared knowledge package loaded" || fail "no package: the row reads '${R}'"
grep -q "Knowledge transfer page" "${T}/out" || fail "no package: the remedy does not name the Knowledge transfer page"
grep -q -- "--not-needed packages" "${T}/out" || fail "no package: the remedy lost the --not-needed line"
echo "ok 2 - no package (defaults/ and an empty imported/ only): ${R}; the remedy names the Knowledge transfer page and keeps --not-needed"

# --- 3. a kept pack, loaded: PASS, the row names it, the facts carry it; the LogLearner ledger written by the real loader ---
T=$(tree b)
I=${T}/knowledge/imported
pack "${I}" team-a v3
( cd "${LOGLEARNER_DIR}" && python3 -m loglearner.pack ingest --pack "${I}/team-a.jsonl" --bank "${T}/loglearner/banks/global/instincts.jsonl" \
	--name team-a --version v3 --manifest "${I}/team-a.manifest.json" ) > "${T}/ingest.log" 2>&1 || fail "the runtime's loader refused the planted pack: $(cat "${T}/ingest.log")"
grep -q '"added": 2' "${T}/ingest.log" || fail "the runtime's loader did not add the pack's 2 records: $(cat "${T}/ingest.log")"
[ -s "${T}/loglearner/banks/global/.installed-packs.json" ] || fail "the runtime's loader wrote no .installed-packs.json beside the bank"
stamp "${I}" team-a "$(sha_of "${I}/team-a.manifest.json" hindsight)"
doctor "${T}"
R=$(row "${T}")
[ "${RC}" == "0" ] || fail "a loaded kept pack: expected PASS (exit 0), got exit ${RC}: ${R} $(cat "${T}/err")"
echo "${R}" | grep -q "^PASS .*1 package(s): imported team-a v3 (5 records, loaded)" || fail "a loaded kept pack: the row reads '${R}'"
F=$(fact "${T}" 'json.dumps(c["facts"]["imported"], sort_keys=True)')
[ "${F}" == '[{"loaded": true, "name": "team-a", "records": 5, "version": "v3"}]' ] || fail "a loaded kept pack: facts.imported is ${F}"
[ "$(fact "${T}" 'len(c["facts"]["packages"]), c["facts"]["repos"]')" == "(1, [])" ] || fail "a loaded kept pack: facts.packages/repos read $(fact "${T}" 'c["facts"]')"
grep -qF "kept in ${I}" "${T}/out" || fail "a loaded kept pack: the 'checked' lines do not name ${I}"
echo "ok 3 - a kept pack with both ledgers (the LogLearner one written by loglearner.pack ingest): ${R}; facts.imported ${F}"

# --- 4. the same pack, not loaded: GAP naming it with the load remedy; planted controls per store ---
T=$(tree c)
I=${T}/knowledge/imported
pack "${I}" team-a v3
doctor "${T}"
R=$(row "${T}")
[ "${RC}" == "1" ] || fail "an unloaded kept pack: expected a GAP (exit 1), got ${RC}: ${R}"
echo "${R}" | grep -q "^GAP .*imported team-a v3: not loaded in LogLearner and Hindsight" || fail "an unloaded kept pack: the row reads '${R}'"
grep -q "/agent/loglearner-packs.sh" "${T}/out" && grep -q "python3 /agent/knowledge-transfer.py load" "${T}/out" \
	|| fail "an unloaded kept pack: the remedy lacks the two load commands: $(grep -A4 'inside the container' "${T}/out")"
grep -q "${CLAUDE_REMEDY}" "${T}/out" && fail "an unloaded kept pack: the CLAUDE.md remedy is offered for an imported pack"
[ "$(fact "${T}" 'c["facts"]["imported"][0]["loaded"]')" == "False" ] || fail "an unloaded kept pack: facts say loaded"
# control: the LogLearner ledger alone
T2=$(tree c-ll)
pack "${T2}/knowledge/imported" team-a v3
installed "${T2}" team-a v3 "$(sha_of "${T2}/knowledge/imported/team-a.manifest.json" loglearner)"
doctor "${T2}"
R2=$(row "${T2}")
echo "${R2}" | grep -q "^GAP .*imported team-a v3: not loaded in Hindsight" && ! echo "${R2}" | grep -q "LogLearner" \
	|| fail "LogLearner ledger alone: the row reads '${R2}'"
# control: the Hindsight stamp alone
T3=$(tree c-hs)
pack "${T3}/knowledge/imported" team-a v3
stamp "${T3}/knowledge/imported" team-a "$(sha_of "${T3}/knowledge/imported/team-a.manifest.json" hindsight)"
doctor "${T3}"
R3=$(row "${T3}")
echo "${R3}" | grep -q "^GAP .*imported team-a v3: not loaded in LogLearner" && ! echo "${R3}" | grep -q "Hindsight" \
	|| fail "Hindsight stamp alone: the row reads '${R3}'"
# control: both ledgers, but the LogLearner entry carries another sha256 (the pack's bytes changed since that load)
T4=$(tree c-sha)
pack "${T4}/knowledge/imported" team-a v3
installed "${T4}" team-a v3 "0000000000000000000000000000000000000000000000000000000000000000"
stamp "${T4}/knowledge/imported" team-a "$(sha_of "${T4}/knowledge/imported/team-a.manifest.json" hindsight)"
doctor "${T4}"
R4=$(row "${T4}")
echo "${R4}" | grep -q "^GAP .*imported team-a v3: not loaded in LogLearner$" || fail "a ledger entry with another sha256: the row reads '${R4}'"
# control: the ledger entry with the right sha256 under another version (a re-import under a new version the loader has not run yet)
T5=$(tree c-ver)
pack "${T5}/knowledge/imported" team-a v3
installed "${T5}" team-a v2 "$(sha_of "${T5}/knowledge/imported/team-a.manifest.json" loglearner)"
stamp "${T5}/knowledge/imported" team-a "$(sha_of "${T5}/knowledge/imported/team-a.manifest.json" hindsight)"
doctor "${T5}"
R5=$(row "${T5}")
echo "${R5}" | grep -q "^GAP .*imported team-a v3: not loaded in LogLearner$" || fail "a ledger entry of another version: the row reads '${R5}'"
# control: the stamp with another sha256 (the Hindsight file changed since that load), the LogLearner ledger right
T6=$(tree c-stamp)
pack "${T6}/knowledge/imported" team-a v3
installed "${T6}" team-a v3 "$(sha_of "${T6}/knowledge/imported/team-a.manifest.json" loglearner)"
stamp "${T6}/knowledge/imported" team-a "0000000000000000000000000000000000000000000000000000000000000000"
doctor "${T6}"
R6=$(row "${T6}")
echo "${R6}" | grep -q "^GAP .*imported team-a v3: not loaded in Hindsight$" || fail "a stamp with another sha256: the row reads '${R6}'"
echo "ok 4 - an unloaded kept pack: ${R}; the remedy is the two load commands, never the CLAUDE.md line; controls: LogLearner alone -> '${R2}', Hindsight alone -> '${R3}', another sha256 -> '${R4}', another version -> '${R5}', a stale stamp -> '${R6}'"

# --- 5. a kept pack beside a cloned repository ---
T=$(tree d)
I=${T}/knowledge/imported
repo "${T}" example-workstreams 7
pack "${I}" team-a v3
installed "${T}" team-a v3 "$(sha_of "${I}/team-a.manifest.json" loglearner)"
stamp "${I}" team-a "$(sha_of "${I}/team-a.manifest.json" hindsight)"
doctor "${T}"
R=$(row "${T}")
[ "${RC}" == "0" ] || fail "a repository and a kept pack: expected PASS (exit 0), got ${RC}: ${R} $(cat "${T}/err")"
echo "${R}" | grep -q "^PASS .*2 package(s): example-workstreams (1 bank(s)), imported team-a v3 (5 records, loaded)" || fail "a repository and a kept pack: the row reads '${R}'"
[ "$(fact "${T}" 'len(c["facts"]["packages"]), len(c["facts"]["imported"])')" == "(2, 1)" ] || fail "a repository and a kept pack: facts read $(fact "${T}" 'c["facts"]')"
# the repository's bank empty: the GAP names the repository, not the pack, and both rows are still listed
echo 0 > "${D}/stub-docs/example-workstreams-bank"
doctor "${T}"
R5=$(row "${T}")
[ "${RC}" == "1" ] || fail "a repository with an empty bank: expected a GAP, got ${RC}: ${R5}"
echo "${R5}" | grep -q "^GAP .*example-workstreams: bank(s) without documents: example-workstreams-bank" || fail "a repository with an empty bank: the row reads '${R5}'"
echo "${R5}" | grep -q "team-a" && fail "a repository with an empty bank: the GAP names the loaded pack: '${R5}'"
grep -q "imported team-a v3 (5 records, loaded)" "${T}/out" || fail "a repository with an empty bank: the loaded pack left the 'checked' lines"
echo "ok 5 - a cloned repository beside a kept pack: ${R}; with the repository's bank empty: ${R5} (the pack still listed as loaded)"

# --- 6. the misreading never appears; one-store packs; an unreadable manifest; KNOWLEDGE_IMPORTED_DIR elsewhere; the memory API off ---
T=$(tree e-hs)
pack "${T}/knowledge/imported" docs-only 20261027T000000Z hindsight
stamp "${T}/knowledge/imported" docs-only "$(sha_of "${T}/knowledge/imported/docs-only.manifest.json" hindsight)"
doctor "${T}"
R=$(row "${T}")
[ "${RC}" == "0" ] && echo "${R}" | grep -q "imported docs-only 20261027T000000Z (3 records, loaded)" || fail "a Hindsight-only pack with its stamp: exit ${RC}, the row reads '${R}'"
T=$(tree e-ll)
pack "${T}/knowledge/imported" rules-only v1 loglearner
installed "${T}" rules-only v1 "$(sha_of "${T}/knowledge/imported/rules-only.manifest.json" loglearner)"
doctor "${T}"
R2=$(row "${T}")
[ "${RC}" == "0" ] && echo "${R2}" | grep -q "imported rules-only v1 (2 records, loaded)" || fail "a LogLearner-only pack with its ledger entry: exit ${RC}, the row reads '${R2}'"
# #175's own reproduction: an empty manifest file, beside a loaded pack
T=$(tree e-bad)
I=${T}/knowledge/imported
pack "${I}" team-a v3
installed "${T}" team-a v3 "$(sha_of "${I}/team-a.manifest.json" loglearner)"
stamp "${I}" team-a "$(sha_of "${I}/team-a.manifest.json" hindsight)"
: > "${I}/broken.manifest.json"
doctor "${T}"
R3=$(row "${T}")
[ "${RC}" == "1" ] || fail "an unreadable manifest: expected a GAP, got ${RC}: ${R3}"
echo "${R3}" | grep -q "^GAP .*broken.manifest.json" || fail "an unreadable manifest: the row does not name the file: '${R3}'"
grep -q "imported team-a v3 (5 records, loaded)" "${T}/out" || fail "an unreadable manifest: the pack beside it no longer reads loaded"
grep -q "${CLAUDE_REMEDY}" "${T}/out" && fail "an unreadable manifest: the CLAUDE.md remedy is offered"
# a manifest that is a JSON object but lists no file: no loader would take it, so it never reads loaded
T=$(tree e-nofiles)
I=${T}/knowledge/imported
pack "${I}" team-a v3
installed "${T}" team-a v3 "$(sha_of "${I}/team-a.manifest.json" loglearner)"
stamp "${I}" team-a "$(sha_of "${I}/team-a.manifest.json" hindsight)"
echo '{}' > "${I}/nofiles.manifest.json"
doctor "${T}"
R6=$(row "${T}")
[ "${RC}" == "1" ] && echo "${R6}" | grep -q "^GAP .*imported nofiles: its manifest .*nofiles.manifest.json lists no LogLearner or Hindsight file" \
	|| fail "a manifest without files: exit ${RC}, the row reads '${R6}'"
[ "$(fact "${T}" '[x for x in c["facts"]["imported"] if x["name"] == "nofiles"][0].get("loaded")')" == "None" ] || fail "a manifest without files reads loaded in the facts"
grep -q "imported team-a v3 (5 records, loaded)" "${T}/out" || fail "a manifest without files: the pack beside it no longer reads loaded"
# KNOWLEDGE_IMPORTED_DIR outside KNOWLEDGE_DIR
T=$(tree e-dir)
pack "${T}/elsewhere" team-b v2
installed "${T}" team-b v2 "$(sha_of "${T}/elsewhere/team-b.manifest.json" loglearner)"
stamp "${T}/elsewhere" team-b "$(sha_of "${T}/elsewhere/team-b.manifest.json" hindsight)"
doctor "${T}" KNOWLEDGE_IMPORTED_DIR="${T}/elsewhere"
R4=$(row "${T}")
[ "${RC}" == "0" ] && echo "${R4}" | grep -q "1 package(s): imported team-b v2 (5 records, loaded)" || fail "KNOWLEDGE_IMPORTED_DIR elsewhere: exit ${RC}, the row reads '${R4}'"
grep -qF "kept in ${T}/elsewhere" "${T}/out" || fail "KNOWLEDGE_IMPORTED_DIR elsewhere: the 'checked' lines do not name it"
# the memory API off: the Hindsight store cannot be loaded, and the GAP says why
T=$(tree e-off)
I=${T}/knowledge/imported
pack "${I}" team-a v3
installed "${T}" team-a v3 "$(sha_of "${I}/team-a.manifest.json" loglearner)"
doctor "${T}" UI_HINDSIGHT=false
R5=$(row "${T}")
[ "${RC}" == "1" ] && echo "${R5}" | grep -q "not loaded in Hindsight (the memory API is off" || fail "the memory API off: exit ${RC}, the row reads '${R5}'"
# the misreading, in none of the outputs of this test
HITS=$(grep -l -- "${BAD}" "${D}"/*/out 2>/dev/null | tr '\n' ' ')
[ -z "${HITS}" ] || fail "the row reads '${BAD}' in: ${HITS}"
HITS=$(grep -l -- "${CLAUDE_REMEDY}" "${D}"/*/out 2>/dev/null | tr '\n' ' ')
[ -z "${HITS}" ] || fail "the CLAUDE.md remedy is offered (every repository of this test is named in CLAUDE.md): ${HITS}"
echo "ok 6 - '${BAD}' appears in none of $(ls "${D}"/*/out | wc -l) trees; Hindsight-only: ${R}; LogLearner-only: ${R2}; an empty manifest: ${R3}; a manifest without files: ${R6}; KNOWLEDGE_IMPORTED_DIR elsewhere: ${R4}; the memory API off: ${R5}"

echo "Test-doctor-packages succeeded"
