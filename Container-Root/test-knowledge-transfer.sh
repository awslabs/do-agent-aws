#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of knowledge transfer (/agent/knowledge-transfer.py, docs/manual/memory.md "Moving knowledge between instances" and "A
# shared knowledge base for a group", docs/knowledge-sharing.md): one pack file out of a harness's knowledge stores and
# the same pack into another harness's, from the command line and through the Knowledge transfer page behind the home
# proxy, and the group's shared pack pulled from S3 at a start. Offline: everything binds 127.0.0.1 on test-local ports,
# S3 is a stand-in aws command over a local directory, and all state lives under /tmp/knowledge-transfer-smoke. The
# Hindsight half needs two test-local memory APIs - the exporting harness's and an empty second instance on other ports
# (hindsight-api, which the image has; from a bare checkout those assertions are skipped with a line saying so, while a
# run in the image that cannot start it FAILS unless KNOWLEDGE_TEST_NO_HINDSIGHT=1 says so on purpose) - the page's half
# nginx (skipped the same way without it).
#
# Properties proven (each check FAILS if the property is removed):
#   1. the scripts parse (bash -n, sh -n for startup.sh, the Python, the page's script)
#   2. everything exported: the pack is one .tar.gz holding <name>.jsonl, <name>.hindsight.jsonl and <name>.manifest.json
#      and nothing else; each file's sha256 is the one its manifest records (the LogLearner file's also the manifest's own
#      sha256, where the runtime's loader reads it) and the record counts equal the stores': every record of the
#      LogLearner bank and every document of every Hindsight bank (the memory API's own counts); a pack's record keeps
#      its id, a rule banked on this harness travels as <id>-<its arm>; the manifest says what the scrub gate ran with
#   3. a selection exports what it selects and nothing else: one bank of two, one tag, a range of days in either store,
#      the LogLearner store alone, records named by id (exactly those ids), a search (a LogLearner title, Hindsight ids);
#      an id the stores do not hold and an empty selection are refused; the finder lists by id or title; with the
#      memory API off, a selection naming no store takes the LogLearner bank alone
#   4. an import into an EMPTY second instance (its own LogLearner state and its own memory API) comes out with the same
#      counts: the bank holds the pack's records, each Hindsight bank as many documents as the pack carries for it (and
#      the bank's name), and the pack is kept in KNOWLEDGE_IMPORTED_DIR byte for byte. The preview before it says what the
#      import then does (the loader's counts, every document new) and writes nothing; a second import changes nothing (the
#      loader's no-op, every document skipped) and the preview says so (no-op, every document a conflict)
#   5. PLANTED CONTROLS: a pack whose LogLearner file changed by one byte, and one whose Hindsight file did, are refused
#      with the sha256 message, and nothing changes - not the bank's bytes, not the memory API's counts, not the kept
#      directory; an archive with a path in it and a manifest naming another pack's file are refused too
#   6. the scrub gate: PLANTED CONTROLS - a secret-shaped key in a LogLearner record and in a Hindsight document blocks the
#      export, which names both records and the class and never the value, and writes no file; the same stores without
#      those records export. A scrub config (LOGLEARNER_SCRUB_CONFIG) applies its replacements to the pack, and one that
#      is not a file refuses the export; a person's home directory is rewritten, the image's own service account's home
#      (the container's layout) is not
#   7. the kept pack survives: knowledge-files.py verify leaves KNOWLEDGE_IMPORTED_DIR alone while it removes the same pack
#      planted in KNOWLEDGE_DIR/defaults (PLANTED CONTROL: the image does not ship it); a start loads it again into a fresh
#      LogLearner state (loglearner-packs.sh, with AGENT_KNOWLEDGE true and false) and into an emptied memory API
#      (knowledge-transfer.py load), and a second load leaves it alone (its stamp); a bank that lost one of the pack's
#      documents and gained as many others gets that document back (the load compares ids, not counts), and a malformed
#      kept pack (PLANTED CONTROL: its banks a list) is named while the next pack still loads
#   8. on_conflict: a pack whose document differs from the bank's keeps the bank's with skip (the default), replaces it
#      with replace, and adds the pack's beside it with new-id
#   9. the shared pack from S3 (loglearner-packs.sh, the runtime's loglearner-pull.sh): with LOGLEARNER_S3_BUCKET empty
#      nothing is fetched; set, a start loads the bucket's pack (its sha256 checked) and a second start is a no-op; a pack
#      whose bytes differ from its manifest leaves the bank as it was (PLANTED CONTROL); .env carries the switch, off
#  10. PLANTED CONTROLS: a malformed pack - a Hindsight entry whose banks is a list, a document whose facts is a number,
#      a transfer_schema that is text - is refused at the import with its reason before anything is written (the bank's
#      bytes, the kept files, the memory API's counts unchanged); a pack whose files unpack past
#      KNOWLEDGE_PACK_MAX_UNPACKED is refused; a pack limit of 0 or below is the default, and the unpacked cap is four
#      times the upload limit unless set
#  11. this image's own default knowledge (records of its packs - a shipped pack, named by its manifest in
#      LOGLEARNER_PACKS_DIR, and seed-* - and its seed banks' documents, planted here) stays out of an export unless
#      --include-defaults or a record named by id puts it in; the manifest counts what was left out; PLANTED CONTROL: with
#      that manifest gone from LOGLEARNER_PACKS_DIR the shipped pack's records travel (the names come from the
#      manifests); a selection of only such records is refused saying so, while a filter that matches nothing is "no
#      record"; a check names a record of the receiver's own packs the pack would replace and a seed document a bank
#      already has; an export and an import named like a shipped pack are refused (CONTROL: the same import with no such
#      manifest is checked through); a seed bank's other documents are asked for by id only while the query stays short
#  12. the page through the home proxy: /knowledge/ answers the page with the home badge exactly once and the proxy's
#      policy (its own origin plus the badge's hashes), /knowledge redirects there, the Memory tile links it; stores.json
#      and records.json read the stores; a check, an import and an export of records named by id through the proxy work
#      with the page's header and origin - PLANTED CONTROLS: an import or a check without the header, from another
#      origin, or marked cross-site is refused 403 and loads nothing; a selection that is not a JSON object is refused
#      400 with its reason; the page's Include box for the image's own default knowledge is off; the export's summary
#      header stays under KNOWLEDGE_HEADER_MAX; a request past KNOWLEDGE_REQUEST_BUDGET is refused with that reason,
#      while an import whose budget runs out after its LogLearner load answers that the pack is kept and loads at the
#      next start (no stamp until that start's load); a slow but steady download stops at the budget; every 5xx answer
#      reads Failed: on the page; a pack limit of 0 at the proxy is the default
#  13. ui-start.sh starts the page's server with the home page, on 127.0.0.1 only; ui-status.sh reads it UP, and
#      DISABLED with UI_HOME=false; ui-stop.sh stops it

D=/tmp/knowledge-transfer-smoke
rm -rf "${D:?}"
mkdir -p "${D}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
KT=${AGENT_DIR}/knowledge-transfer.py
LOGLEARNER_DIR=${LOGLEARNER_DIR:-/opt/loglearner}
[ -f "${LOGLEARNER_DIR}/loglearner/pack.py" ] || LOGLEARNER_DIR=${BASE_DIR%/}/opt/loglearner
export LOGLEARNER_DIR
HINDSIGHT_BIN=/home/hindsight/.local/bin/hindsight-api
API_PORT=18431
API=http://127.0.0.1:${API_PORT}
API_B_PORT=18436           # the second instance's own memory API: the importing harness starts empty
API_B=http://127.0.0.1:${API_B_PORT}
PAGE_PORT=18432
PAGE_PORT_2=18437         # a second page server with a one-second request budget (check 12)
PAGE_PORT_3=18438         # a third, with a budget spent before its import's memory banks (check 12)
HOME_PORT=18433
API_PGID=""
API_B_PGID=""
PIDS=()

fail()
{
	echo "Test-knowledge-transfer FAILED: $1"
	exit 1
}

cleanup()
{
	for P in "${PIDS[@]}"; do kill "${P}" 2>/dev/null; done   # the page's server and nginx (in the foreground) among them
	for G in ${API_PGID} ${API_B_PGID}; do
		kill -TERM -- "-${G}" 2>/dev/null
		for i in $(seq 1 30); do
			kill -0 -- "-${G}" 2>/dev/null || break
			sleep 1
		done
		kill -KILL -- "-${G}" 2>/dev/null
	done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# port_of <side> - the memory API port side <side> uses: B, the importing harness, has its own (empty) instance
port_of() { [ "$1" == "B" ] && echo "${API_B_PORT}" || echo "${API_PORT}"; }
# kt <side> <args...> - knowledge-transfer.py over side <side>'s stores: its LogLearner state ${D}/ll-<side>, its
# knowledge directory ${D}/knowledge-<side> (the kept packs in its imported/), its memory API
kt()
{
	local S=$1
	shift
	env -u LOGLEARNER_BANKS_DIR -u INSTINCTS_JSON -u KNOWLEDGE_IMPORTED_DIR LOGLEARNER_STATE="${D}/ll-${S}" \
		KNOWLEDGE_DIR="${D}/knowledge-${S}" UI_PORT_HINDSIGHT_API="$(port_of "${S}")" UI_HINDSIGHT="${HS}" KNOWLEDGE_OP_WAIT=180 \
		KNOWLEDGE_API_WAIT=60 python3 "${KT}" "$@"
}
bank_of() { echo "${D}/ll-$1/banks/global/instincts.jsonl"; }
# counts <side> - the stores' own counts as one JSON object: {"loglearner": records, "hindsight": {bank: documents}}
counts()
{
	python3 - "$(bank_of "$1")" "http://127.0.0.1:$(port_of "$1")" "${HS}" << 'PY'
import json, sys, urllib.parse, urllib.request
bank, api, hs = sys.argv[1:4]
try:
    n = sum(1 for l in open(bank, encoding="utf-8") if l.strip())
except FileNotFoundError:
    n = 0
out = {"loglearner": n, "hindsight": {}}
if hs == "true":
    for b in json.load(urllib.request.urlopen(api + "/v1/default/banks?limit=200", timeout=30)).get("banks", []):
        st = json.load(urllib.request.urlopen(api + "/v1/default/banks/%s/stats?refresh=true" % urllib.parse.quote(b["bank_id"], safe=""), timeout=30))
        out["hindsight"][b["bank_id"]] = int(st.get("total_documents") or 0)
print(json.dumps(out, sort_keys=True))
PY
}
sha() { sha256sum "$1" | cut -d' ' -f1; }

# --- 1. syntax ---
for S in "$0" "${AGENT_DIR}/home-render.sh" "${AGENT_DIR}/ui-start.sh" "${AGENT_DIR}/ui-stop.sh" "${AGENT_DIR}/ui-status.sh" \
	"${AGENT_DIR}/loglearner-packs.sh"; do
	bash -n "${S}" || fail "bash -n ${S}"
done
sh -n "${BASE_DIR%/}/startup.sh" || fail "sh -n startup.sh"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${KT}" || fail "knowledge-transfer.py does not parse"
for F in index.html app.js style.css; do [ -f "${AGENT_DIR}/knowledge-view/${F}" ] || fail "the page has no ${F}"; done
if command -v node > /dev/null; then
	node --check "${AGENT_DIR}/knowledge-view/app.js" || fail "the page's script does not parse"
fi
echo "ok 1 - syntax"

# --- the memory API: a test-local one, where the image has it ---
HS=false
if [ -x "${HINDSIGHT_BIN}" ]; then
	HS=true
	HHOME=${D}/hindsight-home
	mkdir -p "${HHOME}"
	# the API's own mock model: it refuses to start without a provider, and nothing here needs a real one - the document
	# transfer moves extracted facts and embeds them locally - so neither the transfer nor the API's background work on
	# the imported facts can reach a model service from this test
	setsid env HOME="${HHOME}" HF_HOME=/home/hindsight/.cache/huggingface \
		HINDSIGHT_API_LLM_PROVIDER=mock HINDSIGHT_API_WORKER_ID=test-knowledge-transfer \
		"${HINDSIGHT_BIN}" --host 127.0.0.1 --port "${API_PORT}" > "${D}/api.log" 2>&1 &
	API_PGID=$!
	# the second instance: its own home, so its own embedded database, on its own port - empty until the import
	mkdir -p "${HHOME}-b"
	setsid env HOME="${HHOME}-b" HF_HOME=/home/hindsight/.cache/huggingface \
		HINDSIGHT_API_LLM_PROVIDER=mock HINDSIGHT_API_WORKER_ID=test-knowledge-transfer-b \
		"${HINDSIGHT_BIN}" --host 127.0.0.1 --port "${API_B_PORT}" > "${D}/api-b.log" 2>&1 &
	API_B_PGID=$!
	for U in "${API}" "${API_B}"; do
		for i in $(seq 1 300); do
			curl -sf --max-time 3 "${U}/health" 2>/dev/null | grep -q '"healthy"' && break
			sleep 1
		done
		curl -sf --max-time 3 "${U}/health" 2>/dev/null | grep -q '"healthy"' \
			|| { tail -20 "${D}/api.log" "${D}/api-b.log"; fail "hindsight-api did not answer ${U}/health within 300s"; }
	done
elif [ -e "${HINDSIGHT_BIN}" ] && [ "${KNOWLEDGE_TEST_NO_HINDSIGHT}" != "1" ]; then
	# the image ships the memory API: a run that cannot start it would pass with its Hindsight half skipped, so it fails
	# instead (KNOWLEDGE_TEST_NO_HINDSIGHT=1 runs without it on purpose)
	fail "the image ships the memory API (${HINDSIGHT_BIN}) but it is not executable here; KNOWLEDGE_TEST_NO_HINDSIGHT=1 runs the test without its Hindsight half"
else
	echo "  (the Hindsight assertions are skipped: $([ -e "${HINDSIGHT_BIN}" ] && echo "KNOWLEDGE_TEST_NO_HINDSIGHT=1" || echo "hindsight-api is not installed here - they run in the image"))"
fi

# --- the exporting harness's stores (side A) ---
BANK_A=$(bank_of A)
mkdir -p "$(dirname "${BANK_A}")"
# three records of a pack, through the runtime's own loader (they carry the pack)
python3 - "${D}/planted-pack.jsonl" << 'PY'
import json, sys
recs = [
    {"id": "kx-planted-001", "title": "Planted pack record on GPU nodes", "text": "Planted pack record one: drain a GPU node before its driver changes.", "category": "test", "tags": ["gpu"], "confidence": "high", "source": "test"},
    {"id": "kx-planted-002", "title": "Planted pack record on the network", "text": "Planted pack record two: read the hardware counters before blaming the fabric.", "category": "test", "tags": ["net"], "confidence": "med", "source": "test"},
    {"id": "kx-planted-003", "title": "Planted pack record without a tag", "text": "Planted pack record three: name the image by its source and its digest.", "category": "test", "tags": [], "confidence": "low", "source": "test"},
]
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in recs))
PY
( cd "${LOGLEARNER_DIR}" && python3 -m loglearner.pack ingest --pack "${D}/planted-pack.jsonl" --bank "${BANK_A}" \
	--name planted-defaults --version v1 ) > "${D}/plant-pack.log" 2>&1 || fail "the planted pack did not load: $(tail -3 "${D}/plant-pack.log")"
# one rule banked on this harness, through the runtime's gated writer (learn.sh's path)
( cd "${LOGLEARNER_DIR}" && LOGLEARNER_BANKS_DIR="${D}/ll-A/banks" python3 -m loglearner.cli bank --bank "${BANK_A}" \
	--json '{"rule": "Planted learned rule: rebuild the image after a dependency pin moves.", "evidence": "the test", "confidence": "high", "source": "test", "provenance": "test", "status": "positive", "tags": ["gpu", "ops"]}' ) \
	> "${D}/plant-bank.log" 2>&1 || fail "the planted rule was not banked: $(tail -3 "${D}/plant-bank.log")"
# and one banked here on an earlier day: the bank's own shape, its day planted
python3 - "${BANK_A}" << 'PY'
import hashlib, json, sys
rule = "Planted learned rule from an earlier day: never trust a check that cannot fail."
row = {"id": "kb-0002", "rule": rule, "title": "Planted earlier rule", "evidence": "the test", "confidence": "med", "source": "test",
       "provenance": "test", "status": "negative", "tags": ["net"],
       "meta": {"arm": "ll-%s_apply" % hashlib.sha1(rule.encode()).hexdigest()[:10], "reward": 0, "regret": 1, "cross_ref": []},
       "banked_at": "2026-09-01T10:00:00Z", "lifecycle_state": "screened"}
open(sys.argv[1], "a").write(json.dumps(row) + "\n")
PY
[ "$(grep -c . "${BANK_A}")" == "5" ] || fail "the planted bank holds $(grep -c . "${BANK_A}") records, 5 planted"
if [ "${HS}" == "true" ]; then
	# two banks of documents with their facts, through the memory API's own document transfer (no model call)
	python3 - "${API}" << 'PY' > "${D}/plant-hs.log" 2>&1 || fail "the planted Hindsight banks did not load: $(tail -3 "${D}/plant-hs.log")"
import io, json, sys, time, urllib.request, zipfile
api = sys.argv[1]
def req(method, path, data=None, ctype="application/json"):
    r = urllib.request.Request(api + path, data=data, method=method, headers={"Content-Type": ctype} if data is not None else {})
    return urllib.request.urlopen(r, timeout=120).read()
banks = {"kx-alpha": ("Planted alpha", [("kx-a1", ["gpu"], "2026-10-01T09:00:00Z"), ("kx-a2", ["net"], "2026-10-05T09:00:00Z"),
                                         ("kx-a3", [], "2026-10-10T09:00:00Z")]),
         "kx-beta": ("Planted beta", [("kx-b1", ["gpu"], "2026-10-03T09:00:00Z"), ("kx-b2", [], "2026-10-12T09:00:00Z")])}
for bank, (name, docs) in banks.items():
    req("PUT", "/v1/default/banks/" + bank, json.dumps({"name": name, "mission": "planted for the knowledge export test"}).encode())
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("manifest.json", json.dumps({"schema_version": 1, "source_bank_id": bank, "document_count": len(docs)}))
        for i, (did, tags, at) in enumerate(docs):
            text = "Planted document %s: the %s bank holds it for the knowledge export test." % (did, bank)
            zf.writestr("documents/%06d.json" % i, json.dumps({
                "id": did, "original_text": text, "tags": tags, "created_at": at, "chunks": [{"chunk_index": 0, "chunk_text": text}],
                "facts": [{"text": "%s is a planted fact of the %s bank" % (did, bank), "fact_type": "world", "event_date": at,
                           "tags": tags, "chunk_index": 0, "entities": ["planted"]}]}))
    b = "plantedboundary"
    body = (("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"t.zip\"\r\nContent-Type: application/zip\r\n\r\n" % b).encode()
            + buf.getvalue() + ("\r\n--%s--\r\n" % b).encode())
    op = json.loads(req("POST", "/v1/default/banks/%s/document-transfer?on_conflict=skip" % bank, body, "multipart/form-data; boundary=" + b))["operation_id"]
    for _ in range(360):
        st = json.loads(req("GET", "/v1/default/banks/%s/operations/%s" % (bank, op)))
        if st.get("status") in ("completed", "failed", "cancelled"):
            break
        time.sleep(0.5)
    assert st.get("status") == "completed", st
    n = json.loads(req("GET", "/v1/default/banks/%s/stats?refresh=true" % bank)).get("total_documents")
    assert n == len(docs), (bank, n)
    print(bank, n)
PY
fi
COUNTS_A=$(counts A)
echo "  planted: ${COUNTS_A}"

# --- 2. everything exported ---
kt A export "${D}/all.tar.gz" --name harness-a > "${D}/export-all.json" || fail "the export failed: $(cat "${D}/export-all.json")"
python3 - "${D}/all.tar.gz" "${BANK_A}" "${COUNTS_A}" "${HS}" << 'PY' > "${D}/check2.log" 2>&1 || fail "the pack is not the stores': $(tail -3 "${D}/check2.log")"
import hashlib, json, sys, tarfile
path, bank, counts, hs = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4] == "true"
with tarfile.open(path) as tf:
    files = {m.name: tf.extractfile(m).read() for m in tf if m.isreg()}
want = {"harness-a.jsonl", "harness-a.manifest.json"} | ({"harness-a.hindsight.jsonl"} if hs else set())
assert set(files) == want, "the archive holds %s" % sorted(files)
m = json.loads(files["harness-a.manifest.json"])
for f in m["files"]:
    assert hashlib.sha256(files[f["path"]]).hexdigest() == f["sha256"], "%s: its sha256 is not the manifest's" % f["path"]
    assert sum(1 for l in files[f["path"]].splitlines() if l.strip()) == f["records"], "%s: not its manifest's count" % f["path"]
assert m["sha256"] == hashlib.sha256(files["harness-a.jsonl"]).hexdigest(), "the manifest's own sha256 is not the LogLearner file's"
rows = [json.loads(l) for l in files["harness-a.jsonl"].splitlines() if l.strip()]
assert len(rows) == counts["loglearner"] == 5, "%d LogLearner records, the bank holds %d" % (len(rows), counts["loglearner"])
held = [json.loads(l) for l in open(bank) if l.strip()]
for h, r in zip(held, rows):
    if isinstance(h.get("pack"), dict):
        assert r["id"] == h["id"], "the pack's record %s left as %s" % (h["id"], r["id"])
    else:
        arm = hashlib.sha1(h["rule"].strip().encode()).hexdigest()[:10]
        assert r["id"] == "%s-%s" % (h["id"], arm), "the rule banked here as %s travels as %s" % (h["id"], r["id"])
total = len(rows)
if hs:
    docs = [json.loads(l) for l in files["harness-a.hindsight.jsonl"].splitlines() if l.strip()]
    per = {}
    for d in docs:
        per[d["bank"]] = per.get(d["bank"], 0) + 1
    assert per == {b: n for b, n in counts["hindsight"].items() if n}, "documents per bank %s, the API holds %s" % (per, counts["hindsight"])
    entry = next(f for f in m["files"] if f["store"] == "hindsight")
    assert {b: v["records"] for b, v in entry["banks"].items()} == per and entry["banks"]["kx-alpha"]["name"] == "Planted alpha", entry["banks"]
    assert all(d.get("facts") for d in docs), "a document lost its facts"
    total += len(docs)
assert m["records"] == total, "the manifest counts %s records, the files %d" % (m["records"], total)
sc = m.get("scrub") or {}
assert sc.get("gate") == "detectors" and sc.get("classes", 0) > 0 and sc.get("replacements") == {}, "the manifest's scrub gate: %s" % sc
assert (m.get("source") or {}).get("harness") == "do-agent-aws", "the manifest's source: %s" % m.get("source")
print("%d records, every file's sha256 its manifest's, the scrub gate's %d detector classes" % (total, sc["classes"]))
PY
echo "ok 2 - everything exported: $(cat "${D}/check2.log"); the bank's 5 records (a pack's keep their ids, a rule banked here carries its arm)$([ "${HS}" == "true" ] && echo ", every document of both banks with its facts")"

# --- 3. a selection exports what it selects ---
# pick <case> <want ids, comma-separated> <export options...> - the pack of the selection holds exactly those records
pick()
{
	local CASE=$1 WANT=$2
	shift 2
	kt A export "${D}/sel-${CASE}.tar.gz" --name "sel-${CASE}" "$@" > "${D}/sel-${CASE}.json" || { echo "export: $(cat "${D}/sel-${CASE}.json")"; return 1; }
	python3 - "${D}/sel-${CASE}.tar.gz" "${WANT}" << 'PY'
import hashlib, json, sys, tarfile
with tarfile.open(sys.argv[1]) as tf:
    files = {m.name: tf.extractfile(m).read() for m in tf if m.isreg()}
m = json.loads(next(v for k, v in files.items() if k.endswith(".manifest.json")))
got = []
for f in m["files"]:
    assert hashlib.sha256(files[f["path"]]).hexdigest() == f["sha256"], f["path"]
    for l in files[f["path"]].splitlines():
        if l.strip():
            r = json.loads(l)
            got.append(r["id"])
want = sorted(x for x in sys.argv[2].split(",") if x)
# a rule banked here travels as <id>-<arm>: compared by the id it had
got = sorted(g if not g.startswith("kb-") else g[:7] for g in got)
assert got == want, "the pack holds %s, the selection is %s" % (got, want)
print(len(got))
PY
}
HS_ALPHA="" HS_GPU="" HS_DAYS=""
[ "${HS}" == "true" ] && HS_ALPHA="kx-a1,kx-a2,kx-a3" && HS_GPU=",kx-a1,kx-b1" && HS_DAYS="kx-a2,kx-a3"
if [ "${HS}" == "true" ]; then
	pick bank "${HS_ALPHA}" --store hindsight --bank kx-alpha > "${D}/sel.log" 2>&1 || fail "one bank of two: $(tail -2 "${D}/sel.log")"
	pick days "${HS_DAYS}" --store hindsight --since 2026-10-04 --until 2026-10-11 > "${D}/sel.log" 2>&1 || fail "a range of days in Hindsight: $(tail -2 "${D}/sel.log")"
fi
pick tag "kb-0001,kx-planted-001${HS_GPU}" --tag gpu > "${D}/sel.log" 2>&1 || fail "one tag: $(tail -2 "${D}/sel.log")"
pick earlier "kb-0002" --store loglearner --until 2026-09-30 > "${D}/sel.log" 2>&1 || fail "a range of days in LogLearner: $(tail -2 "${D}/sel.log")"
pick ll "kb-0001,kb-0002,kx-planted-001,kx-planted-002,kx-planted-003" --store loglearner > "${D}/sel.log" 2>&1 \
	|| fail "the LogLearner store alone: $(tail -2 "${D}/sel.log")"
tar tzf "${D}/sel-ll.tar.gz" | grep -q hindsight && fail "the LogLearner store alone exported a Hindsight file"
kt A export "${D}/sel-none.tar.gz" --name sel-none --tag no-such-tag > "${D}/sel-none.json"
RC=$?
[ "${RC}" == "2" ] && grep -q "nothing to export" "${D}/sel-none.json" || fail "a selection that holds nothing was not refused (rc ${RC}): $(cat "${D}/sel-none.json")"
# records named by id: exactly those, in either store - the rule banked here by the id it travels with
KB1=$(python3 -c 'import json, sys, tarfile; t = tarfile.open(sys.argv[1]); print(next(json.loads(l)["id"] for l in t.extractfile("harness-a.jsonl").read().splitlines() if l.strip() and json.loads(l)["id"].startswith("kb-0001-")))' "${D}/all.tar.gz") \
	|| fail "the exported rule banked here has no travelling id"
HS_ID="" HS_ID_ARGS=()
[ "${HS}" == "true" ] && HS_ID=",kx-b2" && HS_ID_ARGS=(--id kx-b2)
pick ids "kb-0001,kx-planted-002${HS_ID}" --id kx-planted-002 --id "${KB1}" "${HS_ID_ARGS[@]}" > "${D}/sel.log" 2>&1 || fail "records named by id: $(tail -2 "${D}/sel.log")"
kt A export "${D}/sel-noid.tar.gz" --name sel-noid --id kx-planted-002 --id no-such-id > "${D}/sel-noid.json"
RC=$?
[ "${RC}" == "2" ] && grep -q "not in the selection: record no-such-id" "${D}/sel-noid.json" && [ ! -e "${D}/sel-noid.tar.gz" ] \
	|| fail "an id the stores do not hold was not refused (rc ${RC}): $(cat "${D}/sel-noid.json")"
# a search: a LogLearner record by its title (any case), Hindsight documents by their id
pick search-title "kx-planted-002" --store loglearner --search NETWORK > "${D}/sel.log" 2>&1 || fail "a search by title: $(tail -2 "${D}/sel.log")"
if [ "${HS}" == "true" ]; then
	pick search-id "kx-a1,kx-a2,kx-a3" --store hindsight --search kx-a > "${D}/sel.log" 2>&1 || fail "a search by Hindsight id: $(tail -2 "${D}/sel.log")"
fi
# the finder: the rule banked here listed by the id it travels with, found by the id the bank holds
kt A records --search kb-0001 > "${D}/find.json" || fail "the finder failed: $(cat "${D}/find.json")"
python3 - "${D}/find.json" "${KB1}" "${HS}" << 'PY' || fail "the finder does not list the records: $(head -c 400 "${D}/find.json")"
import json, sys
f, kb1, hs = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3] == "true"
ll = f["loglearner"]
assert ll["total"] == 1 and ll["shown"][0]["id"] == kb1 and ll["shown"][0]["held_as"] == "kb-0001", ll
if hs:
    assert f["hindsight"]["banks"] and all(v["total"] == 0 for v in f["hindsight"]["banks"].values()), f["hindsight"]
PY
# with the memory API off, a selection that names no store takes the LogLearner bank alone, not a refusal
env -u LOGLEARNER_BANKS_DIR -u INSTINCTS_JSON -u KNOWLEDGE_IMPORTED_DIR LOGLEARNER_STATE="${D}/ll-A" KNOWLEDGE_DIR="${D}/knowledge-A" \
	UI_HINDSIGHT=false python3 "${KT}" export "${D}/sel-hsoff.tar.gz" --name sel-hsoff > "${D}/sel-hsoff.json" \
	|| fail "with the memory API off an export naming no store was refused: $(cat "${D}/sel-hsoff.json")"
python3 -c 'import sys, tarfile; t = tarfile.open(sys.argv[1]); n = sorted(m.name for m in t if m.isreg()); assert n == ["sel-hsoff.jsonl", "sel-hsoff.manifest.json"] and sum(1 for l in t.extractfile("sel-hsoff.jsonl").read().splitlines() if l.strip()) == 5, n' \
	"${D}/sel-hsoff.tar.gz" || fail "with the memory API off an export naming no store does not hold the LogLearner bank alone"
echo "ok 3 - a selection exports what it selects: $([ "${HS}" == "true" ] && echo "one bank of two (3), a range of days in Hindsight (2), ")one tag (the bank's 2$([ "${HS}" == "true" ] && echo " and the banks' 2")), an earlier range of days in LogLearner (1), the LogLearner store alone (5, no Hindsight file), records by id ($([ "${HS}" == "true" ] && echo 3 || echo 2), the rule banked here by ${KB1}), a search by title (1)$([ "${HS}" == "true" ] && echo " and by Hindsight id (3)"); an unknown id and an empty selection are refused; the finder lists ${KB1} for kb-0001; with the memory API off an export naming no store takes the LogLearner bank alone (5)"

# --- 4. an import into an empty second instance comes out with the same counts ---
# empty: side B has no LogLearner state yet and its own memory API, on its own port and database, holds no bank
# drop_banks - the second instance's banks deleted (its memory database recreated, for the restart in check 7)
drop_banks()
{
	for B in kx-alpha kx-beta; do curl -s -o /dev/null --max-time 60 -X DELETE "${API_B}/v1/default/banks/${B}"; done
	[ "$(counts B | python3 -c 'import json, sys; print(sorted(json.load(sys.stdin)["hindsight"]))')" == "[]" ]
}
[ "$(counts B)" == '{"hindsight": {}, "loglearner": 0}' ] || fail "the second instance is not empty: $(counts B)"
WANT_HS=$(python3 -c 'import json, sys; print(json.dumps({b: n for b, n in json.loads(sys.argv[1])["hindsight"].items() if n}, sort_keys=True))' "${COUNTS_A}")
# the preview first: what the import will do, and nothing written
kt B preview "${D}/all.tar.gz" > "${D}/preview-1.json" || fail "the preview failed: $(cat "${D}/preview-1.json")"
python3 - "${D}/preview-1.json" "${WANT_HS}" "${HS}" << 'PY' > "${D}/check4p.log" 2>&1 || fail "the preview does not say what the import does: $(tail -3 "${D}/check4p.log")"
import json, sys
res, want, hs = json.load(open(sys.argv[1])), json.loads(sys.argv[2]), sys.argv[3] == "true"
ll = res["loglearner"]
assert (ll["noop"], ll["added"], ll["updated"], ll["skipped"], ll["total"], ll["replaces"]) == (False, 5, 0, 0, 5, []), ll
assert res["replaces_kept"] is False and res["scrub"]["gate"] == "detectors", res
if hs:
    got = {b: (v["documents"], v["new"], v["conflicts"], v["bank"]) for b, v in res["hindsight"].items()}
    assert got == {b: (n, n, 0, "new") for b, n in want.items()}, got
PY
[ ! -e "${D}/ll-B" ] && [ ! -e "${D}/knowledge-B" ] && [ "$(counts B)" == '{"hindsight": {}, "loglearner": 0}' ] \
	|| fail "the preview wrote to the second instance: $(ls "${D}" | tr '\n' ' ') $(counts B)"
kt B import "${D}/all.tar.gz" > "${D}/import-1.json" || fail "the import failed: $(cat "${D}/import-1.json")"
python3 - "${D}/import-1.json" "$(counts B)" "${WANT_HS}" "${HS}" << 'PY' > "${D}/check4.log" 2>&1 || fail "the import did not come out with the counts: $(tail -3 "${D}/check4.log")"
import json, sys
res, counts, want, hs = json.load(open(sys.argv[1])), json.loads(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4] == "true"
ll = res["loglearner"]
assert (ll["added"], ll["updated"], ll["skipped"], ll["total"]) == (5, 0, 0, 5), ll
assert counts["loglearner"] == 5, counts
if hs:
    assert {b: v["imported"] for b, v in res["hindsight"].items()} == want, res["hindsight"]
    assert counts["hindsight"] == want, "the banks hold %s, the pack %s" % (counts["hindsight"], want)
print("5 records%s" % (", documents %s" % want if hs else ""))
PY
if [ "${HS}" == "true" ]; then
	curl -s --max-time 30 "${API_B}/v1/default/banks?limit=200" | grep -q '"name":"Planted alpha"' || fail "the imported bank kx-alpha did not get its name"
fi
# the bank holds the pack's records, by id
python3 - "$(bank_of B)" "${D}/all.tar.gz" << 'PY' || fail "side B's bank does not hold the pack's records"
import json, sys, tarfile
with tarfile.open(sys.argv[2]) as tf:
    ids = sorted(json.loads(l)["id"] for l in tf.extractfile("harness-a.jsonl").read().splitlines() if l.strip())
held = sorted(json.loads(l)["id"] for l in open(sys.argv[1]) if l.strip())
assert held == ids, (held, ids)
PY
# kept byte for byte
mkdir "${D}/unpacked"
tar xzf "${D}/all.tar.gz" -C "${D}/unpacked" || fail "the pack does not unpack"
for P in "${D}/unpacked"/*; do
	[ -e "${P}" ] || continue
	F=${P##*/}
	cmp -s "${D}/unpacked/${F}" "${D}/knowledge-B/imported/${F}" || fail "${F} is not kept byte for byte in ${D}/knowledge-B/imported"
done
[ "$(ls "${D}/knowledge-B/imported" | grep -c '\.jsonl$\|\.manifest\.json$')" == "$(ls "${D}/unpacked" | wc -l)" ] || fail "the kept directory holds $(ls "${D}/knowledge-B/imported" | tr '\n' ' ')"
# a second import changes nothing
SUM_B=$(sha "$(bank_of B)")
COUNTS_B=$(counts B)
kt B import "${D}/all.tar.gz" > "${D}/import-2.json" || fail "the second import failed: $(cat "${D}/import-2.json")"
python3 - "${D}/import-2.json" "${WANT_HS}" "${HS}" << 'PY' > "${D}/check4b.log" 2>&1 || fail "the second import was not a no-op: $(tail -3 "${D}/check4b.log")"
import json, sys
res, want, hs = json.load(open(sys.argv[1])), json.loads(sys.argv[2]), sys.argv[3] == "true"
assert res["loglearner"].get("noop") is True, res["loglearner"]
if hs:
    assert {b: (v["imported"], v["skipped"]) for b, v in res["hindsight"].items()} == {b: (0, n) for b, n in want.items()}, res["hindsight"]
PY
[ "$(sha "$(bank_of B)")" == "${SUM_B}" ] && [ "$(counts B)" == "${COUNTS_B}" ] || fail "the second import changed the stores: $(counts B)"
# and the preview now says so: the loader's no-op, every document already in its bank, the kept pack replaced
kt B preview "${D}/all.tar.gz" > "${D}/preview-2.json" || fail "the second preview failed: $(cat "${D}/preview-2.json")"
python3 - "${D}/preview-2.json" "${WANT_HS}" "${HS}" << 'PY' > "${D}/check4q.log" 2>&1 || fail "the preview after the import is wrong: $(tail -3 "${D}/check4q.log")"
import json, sys
res, want, hs = json.load(open(sys.argv[1])), json.loads(sys.argv[2]), sys.argv[3] == "true"
assert res["loglearner"]["noop"] is True and res["replaces_kept"] is True, res
if hs:
    got = {b: (v["new"], v["conflicts"], v["bank"]) for b, v in res["hindsight"].items()}
    assert got == {b: (0, n, "exists") for b, n in want.items()}, got
PY
[ "$(sha "$(bank_of B)")" == "${SUM_B}" ] && [ "$(counts B)" == "${COUNTS_B}" ] || fail "the second preview changed the stores: $(counts B)"
echo "ok 4 - an import into an empty second instance (its own memory API on port ${API_B_PORT}): $(cat "${D}/check4.log"), the same as exported, the pack kept byte for byte; the preview before it said 5 to add$([ "${HS}" == "true" ] && echo " and every document new") and wrote nothing; a second import changed nothing (the loader's no-op$([ "${HS}" == "true" ] && echo ", every document skipped")) and the preview then says no-op$([ "${HS}" == "true" ] && echo ", every document a conflict")"

# --- 5. PLANTED CONTROLS: a pack that is not its manifest's is refused, and nothing changes ---
# planted <case> <out> - a copy of the pack with one planted defect: a byte of the LogLearner file (ll) or of the Hindsight
# file (hs) changed under the same manifest, a member with a directory in its name (path), a manifest naming another
# pack's file (other)
planted()
{
	python3 - "${D}/all.tar.gz" "$2" "$1" << 'PY'
import io, json, sys, tarfile
src, dst, case = sys.argv[1:4]
with tarfile.open(src) as tf:
    files = {m.name: tf.extractfile(m).read() for m in tf if m.isreg()}
if case in ("ll", "hs"):
    n = "harness-a.jsonl" if case == "ll" else "harness-a.hindsight.jsonl"
    b = bytearray(files[n])
    i = b.index(b"Planted")
    b[i] = ord("p")                       # one byte, the same length: only the sha256 can tell
    files[n] = bytes(b)
elif case == "path":
    files["sub/harness-a.jsonl"] = files.pop("harness-a.jsonl")
else:
    m = json.loads(files["harness-a.manifest.json"])
    m["files"][0]["path"] = "other.jsonl"
    files["harness-a.manifest.json"] = (json.dumps(m, indent=1) + "\n").encode()
with tarfile.open(dst, "w:gz") as tf:
    for n, data in files.items():
        ti = tarfile.TarInfo(n)
        ti.size = len(data)
        tf.addfile(ti, io.BytesIO(data))
PY
}
kept_sums() { (cd "${D}/knowledge-B/imported" && sha256sum ./* 2>/dev/null); }
KEPT_B=$(kept_sums)
CASES="ll path other"
[ "${HS}" == "true" ] && CASES="ll hs path other"
for CASE in ${CASES}; do
	planted "${CASE}" "${D}/bad-${CASE}.tar.gz" || fail "could not plant the ${CASE} control"
	kt B import "${D}/bad-${CASE}.tar.gz" > "${D}/bad-${CASE}.json"
	RC=$?
	[ "${RC}" == "2" ] || fail "PLANTED CONTROL ${CASE}: the pack was not refused (rc ${RC}): $(cat "${D}/bad-${CASE}.json")"
	[ "$(sha "$(bank_of B)")" == "${SUM_B}" ] && [ "$(counts B)" == "${COUNTS_B}" ] && [ "$(kept_sums)" == "${KEPT_B}" ] \
		|| fail "PLANTED CONTROL ${CASE}: the refused pack changed the stores or the kept directory: $(counts B)"
done
grep -q '"refused": "harness-a.jsonl: its sha256 does not match the manifest' "${D}/bad-ll.json" || fail "the changed LogLearner file was refused for another reason: $(cat "${D}/bad-ll.json")"
if [ "${HS}" == "true" ]; then
	grep -q '"refused": "harness-a.hindsight.jsonl: its sha256 does not match the manifest' "${D}/bad-hs.json" || fail "the changed Hindsight file was refused for another reason: $(cat "${D}/bad-hs.json")"
fi
grep -q 'is not a plain file at the top of the archive' "${D}/bad-path.json" || fail "the archive with a path was refused for another reason: $(cat "${D}/bad-path.json")"
grep -q "the manifest's file list names" "${D}/bad-other.json" || fail "the manifest naming another pack's file was refused for another reason: $(cat "${D}/bad-other.json")"
echo "ok 5 - planted controls: a byte changed in the LogLearner file$([ "${HS}" == "true" ] && echo " or in the Hindsight file") is refused with the sha256 message ($(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["refused"][:60])' "${D}/bad-ll.json")...), an archive with a path and a manifest naming another file are refused; the bank's bytes, the API's counts and the kept files unchanged"

# --- 6. the scrub gate ---
# PLANTED CONTROLS: a secret-shaped key (built here, so this file carries none) in one more LogLearner record - side G is
# side A's bank and that record - and in a document of a third bank of the exporting memory API
mkdir -p "$(dirname "$(bank_of G)")"
cp "${BANK_A}" "$(bank_of G)"
KEY=$(python3 -c 'print("AK" + "IA" + "7" * 16)')
python3 - "$(bank_of G)" "${KEY}" << 'PY' || fail "could not plant the secret record"
import json, sys
row = {"id": "kx-secret-001", "rule": "Planted secret rule: use the key %s for the bucket." % sys.argv[2], "title": "Planted secret",
       "meta": {"arm": "ll-5ec7e75ec7_apply"}, "pack": {"name": "planted-secret", "version": "v1"}}
open(sys.argv[1], "a").write(json.dumps(row) + "\n")
PY
if [ "${HS}" == "true" ]; then
	python3 - "${API}" "${KEY}" << 'PY' > "${D}/plant-gamma.log" 2>&1 || fail "the planted secret document did not load: $(tail -3 "${D}/plant-gamma.log")"
import io, json, sys, time, urllib.request, zipfile
api, key = sys.argv[1:3]
def req(method, path, data=None, ctype="application/json"):
    r = urllib.request.Request(api + path, data=data, method=method, headers={"Content-Type": ctype} if data is not None else {})
    return urllib.request.urlopen(r, timeout=120).read()
req("PUT", "/v1/default/banks/kx-gamma", json.dumps({"name": "Planted gamma"}).encode())
text = "Planted document kx-g1: the deploy key is %s." % key
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as zf:
    zf.writestr("manifest.json", json.dumps({"schema_version": 1, "source_bank_id": "kx-gamma", "document_count": 1}))
    zf.writestr("documents/000000.json", json.dumps({"id": "kx-g1", "original_text": text, "tags": [], "created_at": "2026-10-02T09:00:00Z",
        "chunks": [{"chunk_index": 0, "chunk_text": text}], "facts": [{"text": "kx-g1 is a planted fact of the gamma bank",
        "fact_type": "world", "event_date": "2026-10-02T09:00:00Z", "tags": [], "chunk_index": 0, "entities": ["planted"]}]}))
b = "plantedboundary"
body = (("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"t.zip\"\r\nContent-Type: application/zip\r\n\r\n" % b).encode()
        + buf.getvalue() + ("\r\n--%s--\r\n" % b).encode())
op = json.loads(req("POST", "/v1/default/banks/kx-gamma/document-transfer?on_conflict=skip", body, "multipart/form-data; boundary=" + b))["operation_id"]
for _ in range(360):
    st = json.loads(req("GET", "/v1/default/banks/kx-gamma/operations/%s" % op))
    if st.get("status") in ("completed", "failed", "cancelled"):
        break
    time.sleep(0.5)
assert st.get("status") == "completed", st
PY
fi
kt G export "${D}/gated.tar.gz" --name gated > "${D}/gated.json"
RC=$?
python3 - "${D}/gated.json" "${KEY}" "${HS}" << 'PY' || fail "PLANTED CONTROL: the scrub gate did not block the export (rc ${RC}): $(cat "${D}/gated.json")"
import json, sys
out, key, hs = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3] == "true"
why = json.loads(out)["refused"]
assert why.startswith("the scrub gate blocked the export"), why
assert "LogLearner record kx-secret-001 (detect-aws-access-key)" in why, why
if hs:
    assert "Hindsight bank kx-gamma document kx-g1 (detect-aws-access-key)" in why, why
assert key not in out, "the refusal shows the value"
PY
[ "${RC}" == "2" ] && [ ! -e "${D}/gated.tar.gz" ] || fail "PLANTED CONTROL: a blocked export wrote a file or exited ${RC}"
# the same stores without those two records export: side A's bank, the two banks without the planted document
GATE_ARGS=()
[ "${HS}" == "true" ] && GATE_ARGS=(--bank kx-alpha --bank kx-beta)
kt A export "${D}/ungated.tar.gz" --name ungated "${GATE_ARGS[@]}" > "${D}/ungated.json" || fail "the stores without the planted records did not export: $(cat "${D}/ungated.json")"
# a scrub config: its replacements go into the pack; one that is not a file refuses the export
printf '%s\n' '{"replacements": [{"class": "test-term", "regex": "hardware counters", "placeholder": "<TERM>"}], "detectors": []}' > "${D}/scrub.json"
LOGLEARNER_SCRUB_CONFIG="${D}/scrub.json" kt A export "${D}/scrubbed.tar.gz" --name scrubbed --store loglearner > "${D}/scrubbed.json" \
	|| fail "the export with a scrub config failed: $(cat "${D}/scrubbed.json")"
python3 - "${D}/scrubbed.tar.gz" << 'PY' || fail "the scrub config's replacement is not in the pack"
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as tf:
    files = {m.name: tf.extractfile(m).read().decode() for m in tf if m.isreg()}
m = json.loads(files["scrubbed.manifest.json"])
assert m["scrub"] == {"gate": "config", "classes": 0, "replacements": {"test-term": 1}}, m["scrub"]
assert "hardware counters" not in files["scrubbed.jsonl"] and files["scrubbed.jsonl"].count("<TERM>") == 1, "not replaced"
PY
LOGLEARNER_SCRUB_CONFIG="${D}/no-such-scrub.json" kt A export "${D}/noconf.tar.gz" --name noconf --store loglearner > "${D}/noconf.json"
RC=$?
[ "${RC}" == "2" ] && grep -q "LOGLEARNER_SCRUB_CONFIG names .*, which is not a file" "${D}/noconf.json" && [ ! -e "${D}/noconf.tar.gz" ] \
	|| fail "a LOGLEARNER_SCRUB_CONFIG that is not a file did not refuse the export (rc ${RC}): $(cat "${D}/noconf.json")"
# a person's home directory (built here) is rewritten by the runtime's built-in class; the image's own service
# account's home, the container's layout, is not
mkdir -p "$(dirname "$(bank_of H)")"
cp "${BANK_A}" "$(bank_of H)"
python3 - "$(bank_of H)" << 'PY' || fail "could not plant the home-directory records"
import json, sys
person = "/ho" + "me/kxuser"
rows = [{"id": "kx-svc-001", "rule": "Planted service path: the memory API keeps its database in /home/hindsight/.pg0.",
         "meta": {"arm": "ll-5e2c000001_apply"}, "pack": {"name": "planted-homes", "version": "v1"}},
        {"id": "kx-person-001", "rule": "Planted person path: notes live in %s/notes." % person,
         "meta": {"arm": "ll-5e2c000002_apply"}, "pack": {"name": "planted-homes", "version": "v1"}}]
open(sys.argv[1], "a").write("".join(json.dumps(r) + "\n" for r in rows))
PY
kt H export "${D}/homes.tar.gz" --name homes --store loglearner --id kx-svc-001 --id kx-person-001 > "${D}/homes.json" \
	|| fail "the export of the home-directory records failed: $(cat "${D}/homes.json")"
python3 - "${D}/homes.tar.gz" << 'PY' || fail "the scrub gate's home directories are wrong"
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as tf:
    files = {m.name: tf.extractfile(m).read().decode() for m in tf if m.isreg()}
rules = {json.loads(l)["id"]: json.loads(l)["rule"] for l in files["homes.jsonl"].splitlines() if l.strip()}
assert "/home/hindsight/.pg0" in rules["kx-svc-001"], "the image's own path was rewritten: %s" % rules["kx-svc-001"]
assert "~/notes" in rules["kx-person-001"] and "kxuser" not in rules["kx-person-001"], rules["kx-person-001"]
scrub = json.loads(files["homes.manifest.json"])["scrub"]
assert scrub["replacements"] == {"builtin-home-path": 1}, scrub
PY
[ "${HS}" == "true" ] && curl -s -o /dev/null --max-time 60 -X DELETE "${API}/v1/default/banks/kx-gamma"
echo "ok 6 - the scrub gate: planted controls - a secret-shaped key in a LogLearner record$([ "${HS}" == "true" ] && echo " and in a Hindsight document") blocked the export, named $([ "${HS}" == "true" ] && echo "both" || echo "the record") and the class, never the value, and wrote no file; without them the stores export; a scrub config's replacement is in the pack, and a config that is not a file refuses the export; a person's home directory is rewritten to ~, the image's own /home/hindsight is not"

# --- 7. the kept pack survives ---
# knowledge-files.py verify (the SessionStart hook) over side B's knowledge directory, the image's pack list a planted
# one-pack list: it owns KNOWLEDGE_DIR/defaults - the same pack planted there, which this image does not ship, goes -
# and leaves KNOWLEDGE_IMPORTED_DIR alone
mkdir -p "${D}/shipped" "${D}/knowledge-B/defaults"
printf '%s\n' '{"document_id": "shipped-001", "content": "a shipped record", "context": "shipped"}' > "${D}/shipped/shipped.jsonl"
cp "${D}/knowledge-B/imported/harness-a.jsonl" "${D}/knowledge-B/imported/harness-a.manifest.json" "${D}/knowledge-B/defaults/"
VERIFY_ENV=(KNOWLEDGE_DIR="${D}/knowledge-B" KNOWLEDGE_PACKS="${D}/shipped/shipped.jsonl" AGENT_KNOWLEDGE=true CLAUDE_CONFIG_DIR="${D}/claude")
env "${VERIFY_ENV[@]}" python3 "${AGENT_DIR}/knowledge-files.py" verify > "${D}/verify.log" 2>&1
grep -q "removed harness-a.jsonl: the image does not ship it" "${D}/verify.log" && [ ! -e "${D}/knowledge-B/defaults/harness-a.jsonl" ] \
	|| fail "PLANTED CONTROL: the pack planted in defaults was not removed: $(cat "${D}/verify.log")"
[ "$(kept_sums)" == "${KEPT_B}" ] || fail "knowledge-files.py verify changed the kept directory: $(cat "${D}/verify.log")"
# a start: loglearner-packs.sh into a fresh LogLearner state (no seed bank, no team pack: the kept pack alone), with the
# default knowledge on and off
for AK in true false; do
	env -u LOGLEARNER_BANKS_DIR -u INSTINCTS_JSON LOGLEARNER_STATE="${D}/ll-R${AK}" LOGLEARNER_SEED_PACKS=none LOGLEARNER_PACKS_DIR="${D}/no-packs" \
		KNOWLEDGE_IMPORTED_DIR="${D}/knowledge-B/imported" AGENT_KNOWLEDGE="${AK}" "${AGENT_DIR}/loglearner-packs.sh" > "${D}/restart-${AK}.log" 2>&1
	grep -q "imported pack harness-a -> .*: added 5, updated 0, skipped 0 (bank total 5)" "${D}/restart-${AK}.log" \
		|| fail "a start (AGENT_KNOWLEDGE=${AK}) did not load the kept pack: $(cat "${D}/restart-${AK}.log")"
	cmp -s <(python3 -c 'import json, sys; print(sorted(json.loads(l)["id"] for l in open(sys.argv[1]) if l.strip()))' "${D}/ll-R${AK}/banks/global/instincts.jsonl") \
		<(python3 -c 'import json, sys; print(sorted(json.loads(l)["id"] for l in open(sys.argv[1]) if l.strip()))' "$(bank_of B)") \
		|| fail "the restarted bank (AGENT_KNOWLEDGE=${AK}) does not hold the imported records"
done
env -u LOGLEARNER_BANKS_DIR -u INSTINCTS_JSON LOGLEARNER_STATE="${D}/ll-Rtrue" LOGLEARNER_SEED_PACKS=none LOGLEARNER_PACKS_DIR="${D}/no-packs" \
	KNOWLEDGE_IMPORTED_DIR="${D}/knowledge-B/imported" "${AGENT_DIR}/loglearner-packs.sh" > "${D}/restart-again.log" 2>&1
grep -q "imported pack harness-a -> .*: no-op (already loaded)" "${D}/restart-again.log" || fail "a second start reloaded the kept pack: $(cat "${D}/restart-again.log")"
HS_LINE=""
if [ "${HS}" == "true" ]; then
	# the memory database recreated: the banks gone, the kept pack's documents come back at the start
	drop_banks || fail "the banks could not be deleted for the restart: $(counts B)"
	kt B load > "${D}/load-1.json" || fail "knowledge-transfer.py load failed: $(cat "${D}/load-1.json")"
	python3 - "$(counts B)" "${WANT_HS}" "${D}/load-1.json" << 'PY' || fail "the start's load did not bring the documents back: $(cat "${D}/load-1.json")"
import json, sys
counts, want, res = json.loads(sys.argv[1]), json.loads(sys.argv[2]), json.load(open(sys.argv[3]))
assert counts["hindsight"] == want, counts
assert {b: v["imported"] for b, v in res["load"]["harness-a"].items()} == want, res
PY
	kt B load > "${D}/load-2.json" || fail "the second load failed: $(cat "${D}/load-2.json")"
	grep -q '"harness-a": "already in the memory API"' "${D}/load-2.json" || fail "a second start's load did not leave the pack alone: $(cat "${D}/load-2.json")"
	# a bank that lost one of the pack's documents and gained as many others: the load compares ids, not counts
	python3 - "${API_B}" << 'PY' > "${D}/refill.log" 2>&1 || fail "the bank could not be refilled for the next load: $(tail -3 "${D}/refill.log")"
import io, json, sys, time, urllib.request, zipfile
api = sys.argv[1]
def req(method, path, data=None, ctype="application/json"):
    r = urllib.request.Request(api + path, data=data, method=method, headers={"Content-Type": ctype} if data is not None else {})
    return urllib.request.urlopen(r, timeout=120).read()
def ids():
    return {i["id"] for i in json.loads(req("GET", "/v1/default/banks/kx-alpha/documents?limit=100"))["items"]}
req("DELETE", "/v1/default/banks/kx-alpha/documents/kx-a1")
buf = io.BytesIO()
others = [("kx-other-1", "2026-10-14T09:00:00Z"), ("kx-other-2", "2026-10-14T10:00:00Z")]
with zipfile.ZipFile(buf, "w") as zf:
    zf.writestr("manifest.json", json.dumps({"schema_version": 1, "source_bank_id": "kx-alpha", "document_count": len(others)}))
    for i, (did, at) in enumerate(others):
        text = "Another document %s: the kx-alpha bank holds it beside the pack's." % did
        zf.writestr("documents/%06d.json" % i, json.dumps({"id": did, "original_text": text, "tags": [], "created_at": at,
            "chunks": [{"chunk_index": 0, "chunk_text": text}], "facts": [{"text": "%s is another fact" % did, "fact_type": "world",
            "event_date": at, "tags": [], "chunk_index": 0, "entities": ["other"]}]}))
b = "refillboundary"
body = (("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"t.zip\"\r\nContent-Type: application/zip\r\n\r\n" % b).encode()
        + buf.getvalue() + ("\r\n--%s--\r\n" % b).encode())
op = json.loads(req("POST", "/v1/default/banks/kx-alpha/document-transfer?on_conflict=skip", body, "multipart/form-data; boundary=" + b))["operation_id"]
for _ in range(360):
    st = json.loads(req("GET", "/v1/default/banks/kx-alpha/operations/%s" % op))
    if st.get("status") in ("completed", "failed", "cancelled"):
        break
    time.sleep(0.5)
assert st.get("status") == "completed", st
have = ids()
assert "kx-a1" not in have and {"kx-other-1", "kx-other-2"} <= have and len(have) >= 3, have
print(sorted(have))
PY
	kt B load > "${D}/load-3.json" || fail "the load after the refill failed: $(cat "${D}/load-3.json")"
	curl -s --max-time 60 "${API_B}/v1/default/banks/kx-alpha/documents?limit=100" > "${D}/refill-after.json"
	python3 -c 'import json, sys; ids = {i["id"] for i in json.load(open(sys.argv[1]))["items"]}; assert "kx-a1" in ids, sorted(ids)' "${D}/refill-after.json" \
		|| fail "a start's load left out the pack's document of a bank refilled with as many others: $(cat "${D}/load-3.json")"
	for O in kx-other-1 kx-other-2; do curl -s -o /dev/null --max-time 60 -X DELETE "${API_B}/v1/default/banks/kx-alpha/documents/${O}"; done
	# PLANTED CONTROL: a malformed kept pack (its banks a list), named before harness-a: the load names it and goes on
	python3 - "${D}/knowledge-B/imported" << 'PY' || fail "the malformed kept pack could not be planted"
import hashlib, json, os, sys
d = sys.argv[1]
line = json.dumps({"bank": "kx-alpha", "id": "kx-bad-1", "original_text": "a document of a malformed kept pack", "facts": []}) + "\n"
open(os.path.join(d, "aaa-bad.hindsight.jsonl"), "w").write(line)
m = {"name": "aaa-bad", "version": "v1", "records": 1, "files": [{"path": "aaa-bad.hindsight.jsonl", "store": "hindsight", "records": 1,
     "sha256": hashlib.sha256(line.encode()).hexdigest(), "transfer_schema": 1, "banks": ["kx-alpha"]}]}
open(os.path.join(d, "aaa-bad.manifest.json"), "w").write(json.dumps(m))
PY
	kt B load > "${D}/load-4.json" || fail "PLANTED CONTROL: a malformed kept pack stopped the start's load: $(cat "${D}/load-4.json")"
	python3 -c 'import json, sys; r = json.load(open(sys.argv[1]))["load"]; assert ("refused:" in str(r["aaa-bad"]) or "error" in str(r["aaa-bad"])) and r["harness-a"] == "already in the memory API", r' "${D}/load-4.json" \
		|| fail "PLANTED CONTROL: the start's load did not name the malformed kept pack and load the next: $(cat "${D}/load-4.json")"
	rm -f "${D:?}/knowledge-B/imported/aaa-bad.hindsight.jsonl" "${D:?}/knowledge-B/imported/aaa-bad.manifest.json"
	HS_LINE=", an emptied memory API gets the documents back from knowledge-transfer.py load (${WANT_HS}) and a second load leaves them (its stamp); a bank that lost kx-a1 and gained two others got it back (ids, not counts); a malformed kept pack was named and the next pack still loaded (planted control)"
fi
echo "ok 7 - the kept pack survives: knowledge-files.py verify removed it from defaults (planted control) and left imported/ byte for byte; a start loads it into a fresh LogLearner state with AGENT_KNOWLEDGE true and false (5 records), a second start is the loader's no-op${HS_LINE}"

# --- 8. on_conflict: a document the second instance already has ---
if [ "${HS}" == "true" ]; then
	# version 2 of the pack: kx-a1's text changed, every file's sha256 and the manifest's version made to match
	python3 - "${D}/all.tar.gz" "${D}/v2.tar.gz" << 'PY' || fail "could not build version 2 of the pack"
import hashlib, io, json, sys, tarfile
src, dst = sys.argv[1:3]
with tarfile.open(src) as tf:
    files = {m.name: tf.extractfile(m).read() for m in tf if m.isreg()}
lines = []
for l in files["harness-a.hindsight.jsonl"].decode().splitlines():
    d = json.loads(l)
    if d["id"] == "kx-a1":
        d["original_text"] = "Changed document kx-a1: version 2 of the pack carries this text."
        d["chunks"] = [{"chunk_index": 0, "chunk_text": d["original_text"]}]
    lines.append(json.dumps(d))
files["harness-a.hindsight.jsonl"] = ("\n".join(lines) + "\n").encode()
m = json.loads(files["harness-a.manifest.json"])
m["version"] += "-v2"
for f in m["files"]:
    f["sha256"] = hashlib.sha256(files[f["path"]]).hexdigest()
files["harness-a.manifest.json"] = (json.dumps(m, indent=1) + "\n").encode()
with tarfile.open(dst, "w:gz") as tf:
    for n, data in files.items():
        ti = tarfile.TarInfo(n)
        ti.size = len(data)
        tf.addfile(ti, io.BytesIO(data))
PY
	doc_text() { curl -s --max-time 30 "${API_B}/v1/default/banks/kx-alpha/documents/kx-a1" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("original_text", ""))'; }
	alpha_docs() { counts B | python3 -c 'import json, sys; print(json.load(sys.stdin)["hindsight"].get("kx-alpha"))'; }
	kt B preview "${D}/v2.tar.gz" > "${D}/oc-preview.json" || fail "the preview of version 2 failed: $(cat "${D}/oc-preview.json")"
	python3 -c 'import json, sys; h = json.load(open(sys.argv[1]))["hindsight"]["kx-alpha"]; assert h["conflicts"] == 3 and "kx-a1" in h["conflict_ids"], h' "${D}/oc-preview.json" \
		|| fail "the preview does not name the conflicts: $(cat "${D}/oc-preview.json")"
	kt B import "${D}/v2.tar.gz" > "${D}/oc-skip.json" || fail "the import with skip failed: $(cat "${D}/oc-skip.json")"
	doc_text | grep -q '^Planted document kx-a1' || fail "with skip (the default) the bank's document was replaced: $(doc_text)"
	kt B import "${D}/v2.tar.gz" --on-conflict replace > "${D}/oc-replace.json" || fail "the import with replace failed: $(cat "${D}/oc-replace.json")"
	doc_text | grep -q '^Changed document kx-a1' || fail "with replace the bank kept its document: $(doc_text)"
	[ "$(alpha_docs)" == "3" ] || fail "with replace kx-alpha holds $(alpha_docs) documents, 3 expected"
	kt B import "${D}/v2.tar.gz" --on-conflict new-id > "${D}/oc-newid.json" || fail "the import with new-id failed: $(cat "${D}/oc-newid.json")"
	[ "$(alpha_docs)" == "6" ] || fail "with new-id kx-alpha holds $(alpha_docs) documents, the 3 it had and the pack's 3 beside them expected"
	kt B import "${D}/v2.tar.gz" --on-conflict sideways > "${D}/oc-bad.json"
	[ "$?" == "2" ] || fail "an on_conflict the memory API does not know was taken: $(cat "${D}/oc-bad.json")"
	echo "ok 8 - on_conflict: the preview names the 3 conflicts; skip (the default) kept the bank's kx-a1, replace put the pack's text in its place (still 3 documents), new-id added the pack's 3 beside them (6); an unknown choice is refused"
else
	echo "ok 8 - on_conflict: skipped, no memory API here"
fi

# --- 9. the shared pack from S3 ---
# a stand-in for the aws command: "s3 cp [--only-show-errors] s3://<bucket>/<key> <dest>" copies ${D}/s3/<bucket>/<key>,
# each call logged; the bucket holds the exported pack's LogLearner file in the layout loglearner-pull.sh reads
mkdir -p "${D}/bin" "${D}/s3/amzn-s3-demo-bucket/loglearner/packs/group-kx/v1"
cat > "${D}/bin/aws" << 'SH'
#!/bin/bash
echo "$*" >> "${S3_CALLS:?}"
[ "$1" == "s3" ] && [ "$2" == "cp" ] || exit 2
shift 2
[ "$1" == "--only-show-errors" ] && shift
cp "${S3_ROOT:?}/${1#s3://}" "$2"
SH
chmod +x "${D}/bin/aws"
printf '%s\n' '{"version": "v1"}' > "${D}/s3/amzn-s3-demo-bucket/loglearner/packs/group-kx/latest.json"
cp "${D}/unpacked/harness-a.jsonl" "${D}/s3/amzn-s3-demo-bucket/loglearner/packs/group-kx/v1/instincts.jsonl"
cp "${D}/unpacked/harness-a.manifest.json" "${D}/s3/amzn-s3-demo-bucket/loglearner/packs/group-kx/v1/manifest.json"
# start <state> [<env>...] - loglearner-packs.sh into a fresh LogLearner state with no other knowledge, the stand-in first
start()
{
	local ST=$1
	shift
	env -u LOGLEARNER_BANKS_DIR -u INSTINCTS_JSON -u LOGLEARNER_S3_BUCKET LOGLEARNER_STATE="${D}/ll-${ST}" LOGLEARNER_SEED_PACKS=none \
		LOGLEARNER_PACKS_DIR="${D}/no-packs" KNOWLEDGE_IMPORTED_DIR="${D}/no-imported" PATH="${D}/bin:${PATH}" S3_ROOT="${D}/s3" \
		S3_CALLS="${D}/s3-calls.log" "$@" "${AGENT_DIR}/loglearner-packs.sh"
}
start S0 > "${D}/s3-off.log" 2>&1
! grep -q "shared pack" "${D}/s3-off.log" && [ ! -e "${D}/s3-calls.log" ] && [ ! -s "$(bank_of S0)" ] \
	|| fail "with LOGLEARNER_S3_BUCKET empty a start fetched from S3: $(cat "${D}/s3-off.log" "${D}/s3-calls.log" 2>&1)"
start S1 LOGLEARNER_S3_BUCKET=amzn-s3-demo-bucket LOGLEARNER_PACK=group-kx > "${D}/s3-on.log" 2>&1
grep -q "shared pack group-kx from s3://amzn-s3-demo-bucket -> .*: added 5, updated 0, skipped 0 (bank total 5)" "${D}/s3-on.log" \
	&& [ "$(grep -c 'loglearner/packs/group-kx/' "${D}/s3-calls.log")" == "3" ] \
	|| fail "a start with LOGLEARNER_S3_BUCKET set did not load the bucket's pack: $(cat "${D}/s3-on.log" "${D}/s3-calls.log")"
SUM_S1=$(sha "$(bank_of S1)")
start S1 LOGLEARNER_S3_BUCKET=amzn-s3-demo-bucket LOGLEARNER_PACK=group-kx > "${D}/s3-again.log" 2>&1
grep -q "already installed .* no-op" "${D}/s3-again.log" && [ "$(sha "$(bank_of S1)")" == "${SUM_S1}" ] \
	|| fail "a second start reloaded the shared pack: $(cat "${D}/s3-again.log")"
# PLANTED CONTROL: the bucket's file no longer the one its manifest names
python3 -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); i = b.index(b"Planted"); b[i] = ord("p"); open(p, "wb").write(bytes(b))' \
	"${D}/s3/amzn-s3-demo-bucket/loglearner/packs/group-kx/v1/instincts.jsonl"
start S2 LOGLEARNER_S3_BUCKET=amzn-s3-demo-bucket LOGLEARNER_PACK=group-kx > "${D}/s3-bad.log" 2>&1
grep -q "sha256 mismatch" "${D}/s3-bad.log" && [ ! -s "$(bank_of S2)" ] \
	|| fail "PLANTED CONTROL: a shared pack that is not its manifest's was loaded: $(cat "${D}/s3-bad.log")"
ENV_LINE=""
if [ -f "${BASE_DIR%/}/../.env" ]; then
	# the setting's own value, however .env quotes it
	grep -q '^export LOGLEARNER_S3_BUCKET=""$' "${BASE_DIR%/}/../.env" && grep -q -E -- '-e LOGLEARNER_S3_BUCKET=[^-]{0,16}\$\{LOGLEARNER_S3_BUCKET\}' "${BASE_DIR%/}/../.env" \
		|| fail ".env does not carry the LOGLEARNER_S3_BUCKET switch, off, into the container"
	ENV_LINE="; .env carries LOGLEARNER_S3_BUCKET, empty, into the container"
fi
echo "ok 9 - the shared pack from S3: with LOGLEARNER_S3_BUCKET empty nothing is fetched; set, a start loaded the bucket's pack (5 records, 3 fetches) and a second start was a no-op; planted control: a pack whose bytes differ from its manifest left the bank empty${ENV_LINE}"

# --- 10. PLANTED CONTROLS: a malformed pack is refused at the import with its reason, and nothing changes ---
# bad <case> <out> - the full pack renamed harness-bad, with one malformation and every sha256 made to match it
bad()
{
	python3 - "${D}/all.tar.gz" "$1" "$2" << 'PY'
import hashlib, io, json, sys, tarfile
src, case, out = sys.argv[1:4]
with tarfile.open(src) as tf:
    files = {m.name: tf.extractfile(m).read() for m in tf if m.isreg()}
m = json.loads(files["harness-a.manifest.json"])
ll = files["harness-a.jsonl"]
docs = [json.loads(l) for l in files["harness-a.hindsight.jsonl"].decode().splitlines() if l.strip()]
entry = next(f for f in m["files"] if f["store"] == "hindsight")
if case == "banks-list":
    entry["banks"] = sorted(entry["banks"])
elif case == "facts-number":
    docs[0]["facts"] = 5
elif case == "schema-text":
    entry["transfer_schema"] = "one"
hs = "".join(json.dumps(d) + "\n" for d in docs).encode()
m["name"] = "harness-bad"
for f in m["files"]:
    f["path"] = f["path"].replace("harness-a", "harness-bad")
    f["sha256"] = hashlib.sha256(ll if f["store"] == "loglearner" else hs).hexdigest()
m["sha256"] = hashlib.sha256(ll).hexdigest()
with tarfile.open(out, "w:gz") as tf:
    for name, blob in (("harness-bad.jsonl", ll), ("harness-bad.hindsight.jsonl", hs), ("harness-bad.manifest.json", json.dumps(m).encode())):
        ti = tarfile.TarInfo(name)
        ti.size = len(blob)
        tf.addfile(ti, io.BytesIO(blob))
PY
}
( export KNOWLEDGE_PACK_MAX_UNPACKED=1000; kt B preview "${D}/all.tar.gz" ) > "${D}/bad-size.json"
R=$?
[ "${R}" == "2" ] && grep -q 'unpack to more than 1000 bytes' "${D}/bad-size.json" \
	|| fail "PLANTED CONTROL: a pack past KNOWLEDGE_PACK_MAX_UNPACKED was taken (rc ${R}): $(cat "${D}/bad-size.json")"
# the limits: 0 or below is the default, and the unpacked cap is four times the upload limit unless set
python3 - "${KT}" << 'PY' > "${D}/limits.log" 2>&1 || fail "the pack limits do not hold: $(tail -3 "${D}/limits.log")"
import importlib.util, os, sys
def load(env):
    for k in ("KNOWLEDGE_PACK_MAX", "KNOWLEDGE_PACK_MAX_UNPACKED"):
        os.environ.pop(k, None)
    os.environ.update(env)
    spec = importlib.util.spec_from_file_location("kt", sys.argv[1])
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
for bad in ("0", "-5", "x"):
    assert load({"KNOWLEDGE_PACK_MAX": bad}).MAX_PACK == 64 << 20, bad
m = load({"KNOWLEDGE_PACK_MAX": "1000000"})
assert m.MAX_PACK == 1000000 and m.MAX_UNPACKED == 4000000, (m.MAX_PACK, m.MAX_UNPACKED)
assert load({}).MAX_UNPACKED == 4 * (64 << 20)
print("limits ok")
PY
TEN_LINE="a pack whose files unpack past KNOWLEDGE_PACK_MAX_UNPACKED is refused; a pack limit of 0, -5 or text is the default 64 MiB, and the unpacked cap is four times the upload limit unless set"
if [ "${HS}" == "true" ]; then
	BANK_B_SUM=$(sha "$(bank_of B)")
	KEPT_NOW=$(kept_sums)
	COUNTS_NOW=$(counts B)
	for CASE in "banks-list:is not a map of bank ids" "facts-number:its facts is not a list" "schema-text:is not a whole number"; do
		BC=${CASE%%:*}
		WHY=${CASE#*:}
		bad "${BC}" "${D}/bad-${BC}.tar.gz" || fail "the ${BC} pack could not be made"
		kt B import "${D}/bad-${BC}.tar.gz" > "${D}/bad-${BC}.json"
		R=$?
		[ "${R}" == "2" ] && grep -q "${WHY}" "${D}/bad-${BC}.json" \
			|| fail "PLANTED CONTROL ${BC}: the import was not refused with its reason (rc ${R}): $(cat "${D}/bad-${BC}.json")"
	done
	[ "$(sha "$(bank_of B)")" == "${BANK_B_SUM}" ] && [ "$(kept_sums)" == "${KEPT_NOW}" ] && [ "$(counts B)" == "${COUNTS_NOW}" ] \
		|| fail "PLANTED CONTROL: a refused malformed pack changed side B's stores"
	TEN_LINE="a Hindsight entry whose banks is a list, a document whose facts is a number and a transfer_schema that is text are each refused at the import with their reason, and the bank's bytes, the kept files and the memory API's counts did not change; ${TEN_LINE}"
fi
echo "ok 10 - malformed packs: ${TEN_LINE}"

# --- 11. this image's own default knowledge stays out of a pack unless asked for, and a check names it ---
# side A gets records of the image's own packs (two of kx-shipped, the pack a planted manifest in LOGLEARNER_PACKS_DIR
# names, as /opt/loglearner-packs names the packs the image ships, and a seed-* one) and kx-alpha becomes a seed bank
# whose own seed document is kx-a3 (HINDSIGHT_SEED_DIR, as hindsight-seed.sh reads it); side B a kx-shipped record of the
# same id with other content, as a newer or older image would ship it
mkdir -p "${D}/image-seed" "${D}/image-packs"
printf '%s\n' '{"kx-alpha": {"name": "Planted alpha", "mission": "planted for the knowledge export test"}}' > "${D}/image-seed/banks.json"
printf '%s\n' '{"document_id": "kx-a3", "content": "Planted document kx-a3: the image seeds it."}' > "${D}/image-seed/kx-alpha.jsonl"
printf '%s\n' '{"name": "kx-shipped", "version": "v1", "about": "planted: the manifest of a pack this image ships"}' > "${D}/image-packs/kx-shipped.manifest.json"
python3 - "${D}/image-pack.jsonl" "${D}/image-seed-pack.jsonl" "${D}/image-pack-b.jsonl" << 'PY'
import json, sys
def rec(i, text):
    return {"id": i, "title": "Planted image record %s" % i, "text": text, "category": "test", "tags": ["image"], "confidence": "high", "source": "test"}
open(sys.argv[1], "w").write("".join(json.dumps(rec(i, "Planted image record %s: the image ships it." % i)) + "\n" for i in ("kx-image-001", "kx-image-002")))
open(sys.argv[2], "w").write(json.dumps(rec("kx-image-003", "Planted seed record kx-image-003: a seed bank of the image.")) + "\n")
open(sys.argv[3], "w").write(json.dumps(rec("kx-image-001", "Planted image record kx-image-001: another image's version of it.")) + "\n")
PY
( cd "${LOGLEARNER_DIR}" && python3 -m loglearner.pack ingest --pack "${D}/image-pack.jsonl" --bank "${BANK_A}" --name kx-shipped --version v1 \
	&& python3 -m loglearner.pack ingest --pack "${D}/image-seed-pack.jsonl" --bank "${BANK_A}" --name seed-kx --version v1 \
	&& python3 -m loglearner.pack ingest --pack "${D}/image-pack-b.jsonl" --bank "$(bank_of B)" --name kx-shipped --version v0 ) \
	> "${D}/plant-image.log" 2>&1 || fail "the image's planted records did not load: $(tail -3 "${D}/plant-image.log")"
# img <side> <args...> - knowledge-transfer.py with the planted seed and packs directories as this image's own
img() { ( export HINDSIGHT_SEED_DIR="${D}/image-seed" LOGLEARNER_PACKS_DIR="${D}/image-packs"; kt "$@" ); }
img A export "${D}/def-off.tar.gz" --name def-off > "${D}/def-off.json" || fail "the export with the defaults left out failed: $(cat "${D}/def-off.json")"
img A export "${D}/def-on.tar.gz" --name def-on --include-defaults > "${D}/def-on.json" || fail "the export with --include-defaults failed: $(cat "${D}/def-on.json")"
img A export "${D}/def-id.tar.gz" --name def-id --store loglearner --id kx-image-001 > "${D}/def-id.json" || fail "the export of an image record by id failed: $(cat "${D}/def-id.json")"
python3 - "${D}" "${HS}" << 'PY' || fail "this image's own default knowledge is not left out by default, or not put in when asked for: $(head -c 600 "${D}/def-off.json")"
import json, sys, tarfile
d, hs = sys.argv[1], sys.argv[2] == "true"
def pack(name):
    with tarfile.open("%s/%s.tar.gz" % (d, name)) as tf:
        files = {m.name: tf.extractfile(m).read() for m in tf if m.isreg()}
    m = json.loads(files["%s.manifest.json" % name])
    ll = [json.loads(l)["id"] for l in files.get(name + ".jsonl", b"").splitlines() if l.strip()]
    docs = [json.loads(l)["id"] for l in files.get(name + ".hindsight.jsonl", b"").splitlines() if l.strip()]
    return m, ll, docs
image = {"kx-image-001", "kx-image-002", "kx-image-003"}
m, ll, docs = pack("def-off")
assert not image & set(ll) and len(ll) == 5, ll
assert m["left_out_defaults"].get("loglearner") == 3 and m["selection"]["defaults"] is False, m["left_out_defaults"]
if hs:
    assert "kx-a3" not in docs and sorted(docs) == ["kx-a1", "kx-a2", "kx-b1", "kx-b2"], docs
    assert m["left_out_defaults"].get("hindsight") == 1, m["left_out_defaults"]
m, ll, docs = pack("def-on")
assert image <= set(ll) and len(ll) == 8 and not m["left_out_defaults"], (ll, m["left_out_defaults"])
if hs:
    assert "kx-a3" in docs and len(docs) == 5, docs
m, ll, docs = pack("def-id")
assert ll == ["kx-image-001"], ll
PY
# PLANTED CONTROL: the names come from the manifests - with no manifest in LOGLEARNER_PACKS_DIR naming kx-shipped, its two
# records are not the image's and travel, while the seed-* record still stays out
mkdir -p "${D}/image-packs-none"
( export HINDSIGHT_SEED_DIR="${D}/image-seed" LOGLEARNER_PACKS_DIR="${D}/image-packs-none"; kt A export "${D}/def-nopack.tar.gz" --name def-nopack ) \
	> "${D}/def-nopack.json" || fail "the export with no shipped pack's manifest failed: $(cat "${D}/def-nopack.json")"
python3 - "${D}/def-nopack.tar.gz" << 'PY' || fail "PLANTED CONTROL BROKEN: with its manifest gone the shipped pack's records were still left out: $(head -c 600 "${D}/def-nopack.json")"
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as tf:
    files = {m.name: tf.extractfile(m).read() for m in tf if m.isreg()}
m = json.loads(files["def-nopack.manifest.json"])
ll = {json.loads(l)["id"] for l in files["def-nopack.jsonl"].splitlines() if l.strip()}
assert {"kx-image-001", "kx-image-002"} <= ll and "kx-image-003" not in ll and len(ll) == 7, sorted(ll)
assert m["left_out_defaults"].get("loglearner") == 1, m["left_out_defaults"]
PY
img A export "${D}/def-only.tar.gz" --name def-only --store loglearner --search "planted image record" > "${D}/def-only.json"
R=$?
[ "${R}" == "2" ] && grep -q "holds only this image's own default knowledge (loglearner 3)" "${D}/def-only.json" && [ ! -e "${D}/def-only.tar.gz" ] \
	|| fail "a selection of only the image's own default records was not refused saying so (rc ${R}): $(cat "${D}/def-only.json")"
# a filter that matches nothing is "no record", not "only this image's own default knowledge": seed documents count
# only when no filter narrows the selection
img A export "${D}/def-tag.tar.gz" --name def-tag --tag no-such-tag > "${D}/def-tag.json"
R=$?
[ "${R}" == "2" ] && grep -q "the selection holds no record" "${D}/def-tag.json" \
	|| fail "a filter that matches nothing was refused as only the image's own knowledge (rc ${R}): $(cat "${D}/def-tag.json")"
# a seed bank's other documents are asked for by id only while the query stays short; past ID_QUERY_MAX the bank is
# exported whole and filtered (stubbed memory API calls: the decision alone)
python3 - "${KT}" << 'PY' > "${D}/idquery.log" 2>&1 || fail "the id query is not bounded by its length: $(tail -3 "${D}/idquery.log")"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("kt", sys.argv[1])
kt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kt)
calls = []
kt.hindsight_banks = lambda counts=True, timeout=60: [{"id": "seedbank", "name": "S", "mission": "", "documents": 151}]
kt.image_defaults = lambda: ({"kx-shipped"}, {"seedbank": {"seed-1"}})
kt.hindsight_documents = lambda bank, sel, ids, found, drop=frozenset(): (calls.append(ids), ([], 1))[1]
sel = kt.selection({"stores": ["hindsight"]})
for ids, want_whole in ((["kx-a-long-document-id-%04d-%s" % (i, "x" * 40) for i in range(150)], True),
                        (["s-%03d" % i for i in range(150)], False)):
    kt.bank_document_ids = lambda bank, ids=ids: set(ids) | {"seed-1"}
    calls.clear()
    kt.hindsight_selection(sel, [])
    assert calls == ([None] if want_whole else [sorted(ids)]), (want_whole, str(calls)[:120])
print("id query ok")
PY
img B preview "${D}/def-on.tar.gz" > "${D}/def-check.json" || fail "the check of a pack with the defaults in failed: $(cat "${D}/def-check.json")"
python3 - "${D}/def-check.json" "${HS}" << 'PY' || fail "the check does not name this image's own records the pack would replace: $(head -c 800 "${D}/def-check.json")"
import json, sys
r, hs = json.load(open(sys.argv[1])), sys.argv[2] == "true"
assert r["loglearner"]["replaces_image"] == {"count": 1, "ids": ["kx-image-001"]}, r["loglearner"]
if hs:
    h = r["hindsight"]["kx-alpha"]
    assert h["conflicts_image"] == 1 and h["conflict_image_ids"] == ["kx-a3"], h
PY
# an export named like a pack this image ships is refused, and so is an import of a pack whose manifest names one (it
# would take the place of the receiver's own pack of that name); CONTROL: the same pack is checked through where no
# shipped pack has its name
img A export "${D}/def-name.tar.gz" --name kx-shipped > "${D}/def-name.json"
R=$?
[ "${R}" == "2" ] && grep -q "the pack name 'kx-shipped' is not allowed" "${D}/def-name.json" && [ ! -e "${D}/def-name.tar.gz" ] \
	|| fail "an export named like a pack this image ships was not refused (rc ${R}): $(cat "${D}/def-name.json")"
python3 - "${D}/def-on.tar.gz" "${D}/kx-shipped.tar.gz" << 'PY' || fail "could not plant the pack named like a shipped one"
import io, json, sys, tarfile
src, dst = sys.argv[1:3]
with tarfile.open(src) as tf:
    files = {m.name: tf.extractfile(m).read() for m in tf if m.isreg()}
m = json.loads(files.pop("def-on.manifest.json"))
m["name"] = "kx-shipped"
for f in m["files"]:
    f["path"] = f["path"].replace("def-on", "kx-shipped", 1)
out = {n.replace("def-on", "kx-shipped", 1): data for n, data in files.items()}
out["kx-shipped.manifest.json"] = (json.dumps(m, indent=1) + "\n").encode()
with tarfile.open(dst, "w:gz") as tf:
    for n, data in out.items():
        ti = tarfile.TarInfo(n)
        ti.size = len(data)
        tf.addfile(ti, io.BytesIO(data))
PY
img B preview "${D}/kx-shipped.tar.gz" > "${D}/def-named.json"
R=$?
[ "${R}" == "2" ] && grep -q "the pack name 'kx-shipped' is not allowed" "${D}/def-named.json" \
	|| fail "an import of a pack named like one this image ships was not refused (rc ${R}): $(cat "${D}/def-named.json")"
( export HINDSIGHT_SEED_DIR="${D}/image-seed" LOGLEARNER_PACKS_DIR="${D}/image-packs-none"; kt B preview "${D}/kx-shipped.tar.gz" ) \
	> "${D}/def-named-ok.json" || fail "CONTROL: the same pack, where no shipped pack has its name, was not checked through: $(cat "${D}/def-named-ok.json")"
ELEVEN_LINE=", and in Hindsight its seed bank's own document kx-a3 the same way (4 documents out of 5, then 5)"
[ "${HS}" == "true" ] || ELEVEN_LINE=""
ELEVEN_LINE="${ELEVEN_LINE}; a filter that matches nothing is no record; a seed bank's other documents are asked for by id only while the query stays under ID_QUERY_MAX"
echo "ok 11 - this image's own default knowledge: an export leaves out the 3 records of its packs (kx-shipped, named by its manifest in LOGLEARNER_PACKS_DIR, and seed-*) and counts them in the manifest, --include-defaults puts them in (8 records), a record named by id travels either way${ELEVEN_LINE}; PLANTED CONTROL: without that manifest the 2 kx-shipped records travel (7 records, 1 left out); a selection of only such records is refused saying so; the check names kx-image-001, the receiver's own record the pack would replace$([ "${HS}" == "true" ] && echo ", and kx-a3, a seed document kx-alpha already has"); an export and an import named kx-shipped are refused (CONTROL: the import is checked through where no shipped pack has the name)"

# --- 12. the page through the home proxy ---
if ! command -v nginx > /dev/null; then
	echo "Test-knowledge-transfer skipped checks 12-13: nginx is not installed (setup/install-nginx.sh)"
	echo "Test-knowledge-transfer succeeded"
	exit 0
fi
H=http://127.0.0.1:${HOME_PORT}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@"; }
# the page's server over side C's stores (empty), the way ui-start.sh starts it
env -u LOGLEARNER_BANKS_DIR -u INSTINCTS_JSON -u KNOWLEDGE_IMPORTED_DIR LOGLEARNER_STATE="${D}/ll-C" KNOWLEDGE_DIR="${D}/knowledge-C" \
	UI_PORT_HINDSIGHT_API="${API_PORT}" UI_HINDSIGHT="${HS}" KNOWLEDGE_OP_WAIT=180 \
	python3 "${KT}" serve --port "${PAGE_PORT}" > "${D}/serve.log" 2>&1 &
PIDS+=($!)
# the sharing guide the page links: the checkout's copy, or the image's (the Dockerfile copies docs/ to /docs)
KS_MD=${BASE_DIR%/}/../docs/knowledge-sharing.md
env UI_DIR="${D}/ui" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME="${HOME_PORT}" UI_PORT_KNOWLEDGE="${PAGE_PORT}" UI_HINDSIGHT=true \
	UI_PORT_HINDSIGHT_API="${API_PORT}" UI_PLANE=false KNOWLEDGE_SHARING_MD="${KS_MD}" "${AGENT_DIR}/home-render.sh" > "${D}/render.log" 2>&1 \
	|| fail "home-render.sh: $(tail -3 "${D}/render.log")"
nginx -t -c "${D}/ui/home/nginx.conf" > "${D}/nginx-t.log" 2>&1 || fail "the rendered config does not pass nginx -t: $(cat "${D}/nginx-t.log")"
nginx -c "${D}/ui/home/nginx.conf" -g "daemon off;" > "${D}/nginx.log" 2>&1 &
PIDS+=($!)
for i in $(seq 1 40); do [ "$(code "${H}/knowledge/health")" == "200" ] && break; sleep 0.25; done
curl -s -D "${D}/page.h" --max-time 30 "${H}/knowledge/" > "${D}/page.html"
grep -q '^HTTP/1.1 200' "${D}/page.h" && grep -qi '^content-type: text/html' "${D}/page.h" && grep -q 'data-page="knowledge"' "${D}/page.html" \
	|| fail "/knowledge/ does not answer the page through the proxy: $(head -1 "${D}/page.h") $(head -c 200 "${D}/page.html")"
[ "$(grep -o 'data-harness-home' "${D}/page.html" | wc -l)" == "1" ] || fail "the page carries the home badge $(grep -o 'data-harness-home' "${D}/page.html" | wc -l) times, once expected"
CSP=$(grep -i '^content-security-policy:' "${D}/page.h")
[ "$(echo "${CSP}" | wc -l)" == "1" ] && echo "${CSP}" | grep -q "default-src 'self'; script-src 'self' 'sha256-" && echo "${CSP}" | grep -q "'unsafe-hashes' 'sha256-" \
	|| fail "the page's policy is not the proxy's one with the badge's hashes: ${CSP}"
[ "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 "${H}/knowledge")" == "302 ${H}/knowledge/" ] || fail "/knowledge does not redirect to /knowledge/"
grep -q '<a href="/knowledge/" target="_blank" rel="opener">Knowledge transfer</a>' "${D}/ui/home/site/index.html" || fail "the Memory tile does not link the Knowledge transfer page"
# the guide it links, rendered from docs/knowledge-sharing.md at /guide/knowledge-sharing/
grep -q 'href="/guide/knowledge-sharing/"' "${D}/page.html" || fail "the page does not link the sharing guide"
curl -s --max-time 10 "${H}/guide/knowledge-sharing/" > "${D}/guide.html"
grep -q '<h1[^>]*>Sharing knowledge between harnesses</h1>' "${D}/guide.html" && grep -q 'A shared knowledge base for a group of harnesses' "${D}/guide.html" \
	|| fail "/guide/knowledge-sharing/ does not serve docs/knowledge-sharing.md: $(head -c 300 "${D}/guide.html")"
for F in app.js style.css; do [ "$(code "${H}/knowledge/${F}")" == "200" ] || fail "the page's ${F} does not answer through the proxy"; done
[ "$(code -X PUT "${H}/knowledge/import")" == "403" ] || fail "a PUT through the proxy was not refused"
curl -s --max-time 60 "${H}/knowledge/stores.json" > "${D}/stores.json"
python3 - "${D}/stores.json" "${HS}" << 'PY' || fail "stores.json does not read the stores: $(head -c 300 "${D}/stores.json")"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["loglearner"]["records"] == 0 and s["kept"] == [], s
if sys.argv[2] == "true":
    assert s["hindsight"]["state"] == "up" and {b["id"] for b in s["hindsight"]["banks"]} >= {"kx-alpha", "kx-beta"}, s["hindsight"]
PY
# post <case> <file> <path> [<curl header options>...] - a POST of <file> to the page through the proxy
post()
{
	local CASE=$1 FILE=$2 P=$3
	shift 3
	curl -s -D "${D}/post-${CASE}.h" -o "${D}/post-${CASE}.out" -w '%{http_code}' --max-time 300 -X POST --data-binary "@${FILE}" "$@" "${H}/knowledge/${P}"
}
PAGE_HDRS=(-H "X-Knowledge-Transfer: 1" -H "Origin: ${H}" -H "Sec-Fetch-Site: same-origin")
# PLANTED CONTROLS: what a form or a page on another site could send
[ "$(post nohdr "${D}/all.tar.gz" import -H "Origin: ${H}" -H 'Content-Type: application/gzip')" == "403" ] || fail "PLANTED CONTROL: an import without the page's header was not refused"
[ "$(post foreign "${D}/all.tar.gz" import -H "X-Knowledge-Transfer: 1" -H "Origin: http://evil.example" -H 'Content-Type: application/gzip')" == "403" ] \
	|| fail "PLANTED CONTROL: an import from another origin was not refused"
[ "$(post cross "${D}/all.tar.gz" import -H "X-Knowledge-Transfer: 1" -H "Origin: ${H}" -H "Sec-Fetch-Site: cross-site" -H 'Content-Type: application/gzip')" == "403" ] \
	|| fail "PLANTED CONTROL: an import marked cross-site was not refused"
[ "$(post nohdr-check "${D}/all.tar.gz" preview -H "Origin: ${H}" -H 'Content-Type: application/gzip')" == "403" ] || fail "PLANTED CONTROL: a check without the page's header was not refused"
# another origin: the proxy's same-origin gate refuses it first (above); the page's own guard behind it, on its port
curl -s -o "${D}/post-foreign-direct.out" --max-time 60 -X POST --data-binary "@${D}/all.tar.gz" -H "X-Knowledge-Transfer: 1" \
	-H "Origin: http://evil.example" -H 'Content-Type: application/gzip' "http://127.0.0.1:${PAGE_PORT}/import" > /dev/null
grep -q 'another origin' "${D}/post-foreign-direct.out" && grep -q 'X-Knowledge-Transfer' "${D}/post-nohdr.out" || fail "the refusals do not say why: $(cat "${D}/post-nohdr.out" "${D}/post-foreign-direct.out")"
[ ! -e "$(bank_of C)" ] && [ ! -e "${D}/knowledge-C/imported" ] || fail "PLANTED CONTROL: a refused import wrote side C's stores"
# the page's own requests: a check, the import with the choice the page sends, the finder and an export of records by id
[ "$(post check "${D}/all.tar.gz" preview "${PAGE_HDRS[@]}" -H 'Content-Type: application/gzip')" == "200" ] || fail "the check through the proxy failed: $(cat "${D}/post-check.out")"
python3 - "${D}/post-check.out" "${HS}" << 'PY' || fail "the check through the proxy does not say what the import does: $(cat "${D}/post-check.out")"
import json, sys
r, hs = json.load(open(sys.argv[1])), sys.argv[2] == "true"
assert r["loglearner"]["added"] == 5 and r["loglearner"]["noop"] is False, r["loglearner"]
if hs:   # side C's page reads the exporting memory API, which holds every document already
    assert all(v["conflicts"] == v["documents"] and v["new"] == 0 for v in r["hindsight"].values()), r["hindsight"]
PY
[ ! -e "$(bank_of C)" ] && [ ! -e "${D}/knowledge-C/imported" ] || fail "the check through the proxy wrote side C's stores"
[ "$(post import "${D}/all.tar.gz" 'import?on_conflict=skip' "${PAGE_HDRS[@]}" -H 'Content-Type: application/gzip')" == "200" ] || fail "the import through the proxy failed: $(cat "${D}/post-import.out")"
python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); assert r["loglearner"]["added"] == 5 and r["on_conflict"] == "skip" and r["kept"].endswith("/harness-a.manifest.json"), r' "${D}/post-import.out" \
	|| fail "the import through the proxy did not load the pack: $(cat "${D}/post-import.out")"
curl -s --max-time 60 "${H}/knowledge/records.json?q=network&store=loglearner" > "${D}/records-ll.json"
python3 -c 'import json, sys; r = json.load(open(sys.argv[1]))["loglearner"]; assert r["total"] == 1 and r["shown"][0]["id"] == "kx-planted-002", r' "${D}/records-ll.json" \
	|| fail "the finder through the proxy does not find a record by its title: $(cat "${D}/records-ll.json")"
SEL_RECORDS='[{"store": "loglearner", "id": "kx-planted-002"}]'
WANT_PAGE="kx-planted-002"
if [ "${HS}" == "true" ]; then
	curl -s --max-time 60 "${H}/knowledge/records.json?q=kx-a&store=hindsight&bank=kx-alpha" > "${D}/records-hs.json"
	python3 -c 'import json, sys; r = json.load(open(sys.argv[1]))["hindsight"]["banks"]; assert list(r) == ["kx-alpha"] and r["kx-alpha"]["total"] == 3 and sorted(x["id"] for x in r["kx-alpha"]["shown"]) == ["kx-a1", "kx-a2", "kx-a3"], r' "${D}/records-hs.json" \
		|| fail "the finder through the proxy does not find documents by id: $(cat "${D}/records-hs.json")"
	SEL_RECORDS='[{"store": "loglearner", "id": "kx-planted-002"}, {"store": "hindsight", "bank": "kx-alpha", "id": "kx-a2"}]'
	WANT_PAGE="kx-a2,kx-planted-002"
fi
printf '{"name": "via-ids", "records": %s}' "${SEL_RECORDS}" > "${D}/sel-ids.json"
[ "$(post export-ids "${D}/sel-ids.json" export "${PAGE_HDRS[@]}" -H 'Content-Type: application/json')" == "200" ] || fail "the export of records by id through the proxy failed: $(cat "${D}/post-export-ids.out")"
python3 - "${D}/post-export-ids.out" "${WANT_PAGE}" << 'PY' || fail "the export of records by id through the proxy does not hold exactly them"
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as tf:
    ids = sorted(json.loads(l)["id"] for m in tf if m.isreg() and m.name.endswith(".jsonl") for l in tf.extractfile(m).read().splitlines() if l.strip())
assert ids == sorted(sys.argv[2].split(",")), ids
PY
printf '%s' '{"name": "via-page", "stores": ["loglearner"]}' > "${D}/sel-page.json"
[ "$(post export "${D}/sel-page.json" export "${PAGE_HDRS[@]}" -H 'Content-Type: application/json')" == "200" ] || fail "the export through the proxy failed: $(cat "${D}/post-export.out")"
grep -qi '^content-disposition: attachment; filename="via-page-[0-9TZ]*\.tar\.gz"' "${D}/post-export.h" || fail "the export is not offered as a download: $(grep -i '^content-' "${D}/post-export.h")"
python3 - "${D}/post-export.out" "${D}/post-export.h" << 'PY' || fail "the exported download is not the pack its header says"
import hashlib, json, sys, tarfile
with tarfile.open(sys.argv[1]) as tf:
    files = {m.name: tf.extractfile(m).read() for m in tf if m.isreg()}
head = next(l.split(":", 1)[1].strip() for l in open(sys.argv[2]) if l.lower().startswith("x-knowledge-pack:"))
s = json.loads(head)
assert s["records"] == 5 and set(files) == {"via-page.jsonl", "via-page.manifest.json"}, (s, sorted(files))
assert hashlib.sha256(files["via-page.jsonl"]).hexdigest() == s["files"][0]["sha256"], "the header's sha256 is not the file's"
PY
# a selection that is not a JSON object is refused with its reason, not a dropped connection behind a 502
printf '%s' '[]' > "${D}/sel-list.json"
[ "$(post sel-list "${D}/sel-list.json" export "${PAGE_HDRS[@]}" -H 'Content-Type: application/json')" == "400" ] && grep -q 'must be a JSON object' "${D}/post-sel-list.out" \
	|| fail "a selection that is not a JSON object was not refused with its reason: $(cat "${D}/post-sel-list.out")"
grep -q '<input type="checkbox" id="defaults">' "${D}/page.html" || fail "the page has no Include box for the image's own default knowledge, off by default"
# the summary header stays under KNOWLEDGE_HEADER_MAX: a pack of many banks keeps their number, not each one's count
python3 - "${KT}" << 'PY' || fail "the export's summary header is not capped"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("kt", sys.argv[1])
kt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kt)
s = {"name": "n", "version": "v", "records": 400, "files": [], "banks": {"bank-%04d" % i: 1 for i in range(400)},
     "scrub": {"gate": "detectors", "classes": 18, "replacements": {}}, "left_out_defaults": {}}
h = kt.summary_header(s)
assert len(h) <= kt.HEADER_MAX and '"banks":{"count":400}' in h, (len(h), h[:200])
PY
BUDGET_LINE=""
if [ "${HS}" == "true" ]; then
	# a page request past its budget is refused with that reason (KNOWLEDGE_REQUEST_BUDGET), not left to the proxy's 504
	env -u LOGLEARNER_BANKS_DIR -u INSTINCTS_JSON -u KNOWLEDGE_IMPORTED_DIR LOGLEARNER_STATE="${D}/ll-A" KNOWLEDGE_DIR="${D}/knowledge-A" \
		UI_PORT_HINDSIGHT_API="${API_PORT}" UI_HINDSIGHT=true KNOWLEDGE_REQUEST_BUDGET=1 \
		python3 "${KT}" serve --port "${PAGE_PORT_2}" > "${D}/serve-2.log" 2>&1 &
	PIDS+=($!)
	for i in $(seq 1 40); do [ "$(code "http://127.0.0.1:${PAGE_PORT_2}/health")" == "200" ] && break; sleep 0.25; done
	printf '%s' '{"name": "slow", "stores": ["hindsight"]}' > "${D}/sel-slow.json"
	R=$(curl -s -o "${D}/post-slow.out" -w '%{http_code}' --max-time 120 -X POST --data-binary "@${D}/sel-slow.json" -H "X-Knowledge-Transfer: 1" \
		-H "Origin: http://127.0.0.1:${PAGE_PORT_2}" -H 'Content-Type: application/json' "http://127.0.0.1:${PAGE_PORT_2}/export")
	[ "${R}" == "400" ] && grep -q 'ran past its 1 s budget' "${D}/post-slow.out" \
		|| fail "a request past its budget was not refused with its reason (HTTP ${R}, $(wc -c < "${D}/post-slow.out") bytes: $(head -c 200 "${D}/post-slow.out" | tr -c '[:print:]' '?'))"
	BUDGET_LINE="; a request past its budget (KNOWLEDGE_REQUEST_BUDGET=1) is refused 400 with that reason"
	# an import whose budget runs out after its LogLearner load and its keep (KNOWLEDGE_REQUEST_BUDGET=0.5: the first
	# memory API call finds it spent) answers that the pack is kept and loads at the next start, and writes no stamp;
	# the next start's load then loads it
	env -u LOGLEARNER_BANKS_DIR -u INSTINCTS_JSON -u KNOWLEDGE_IMPORTED_DIR LOGLEARNER_STATE="${D}/ll-Q" KNOWLEDGE_DIR="${D}/knowledge-Q" \
		UI_PORT_HINDSIGHT_API="${API_PORT}" UI_HINDSIGHT=true KNOWLEDGE_REQUEST_BUDGET=0.5 \
		python3 "${KT}" serve --port "${PAGE_PORT_3}" > "${D}/serve-3.log" 2>&1 &
	PIDS+=($!)
	for i in $(seq 1 40); do [ "$(code "http://127.0.0.1:${PAGE_PORT_3}/health")" == "200" ] && break; sleep 0.25; done
	R=$(curl -s -o "${D}/post-budget-import.out" -w '%{http_code}' --max-time 120 -X POST --data-binary "@${D}/all.tar.gz" -H "X-Knowledge-Transfer: 1" \
		-H "Origin: http://127.0.0.1:${PAGE_PORT_3}" -H 'Content-Type: application/gzip' "http://127.0.0.1:${PAGE_PORT_3}/import?on_conflict=skip")
	[ "${R}" == "200" ] || fail "an import whose budget ran out after its keep was refused (HTTP ${R}): $(head -c 300 "${D}/post-budget-import.out" | tr -c '[:print:]' '?')"
	python3 - "${D}/post-budget-import.out" "${D}/knowledge-Q/imported/.loaded.json" << 'PY' || fail "the import past its budget does not say the pack is kept for the next start: $(head -c 400 "${D}/post-budget-import.out")"
import json, os, sys
r = json.load(open(sys.argv[1]))
assert r["loglearner"]["added"] == 5 and r["kept"].endswith("/harness-a.manifest.json"), r
assert "the pack is kept and its documents load at the next start" in r["hindsight"]["error"], r["hindsight"]
assert not os.path.exists(sys.argv[2]) or "harness-a" not in json.load(open(sys.argv[2])), "a stamp was written"
PY
	kt Q load > "${D}/load-q.json" || fail "the start's load after a budget-spent import failed: $(cat "${D}/load-q.json")"
	python3 -c 'import json, sys; r = json.load(open(sys.argv[1]))["load"]; assert isinstance(r["harness-a"], dict) and "error" not in r["harness-a"], r' "${D}/load-q.json" \
		|| fail "the next start's load did not load the pack the budget-spent import kept: $(cat "${D}/load-q.json")"
	BUDGET_LINE="${BUDGET_LINE}; an import whose budget runs out after its keep answers 200 that the pack is kept and loads at the next start, with no stamp, and the next start's load loads it"
fi
# a slow but steady download stops at the budget: each socket read has its own timeout, so the budget is checked between
# the reads (a stub memory API sending 40 bytes over 10 s, a 1.5 s budget)
python3 - "${KT}" << 'PY' > "${D}/slowread.log" 2>&1 || fail "a slow download outlasts the request's budget: $(tail -3 "${D}/slowread.log")"
import importlib.util, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Slow(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "40")
        self.end_headers()
        try:
            for _ in range(40):
                self.wfile.write(b"x")
                self.wfile.flush()
                time.sleep(0.25)
        except OSError:
            pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
srv.daemon_threads = True
threading.Thread(target=srv.serve_forever, daemon=True).start()
os.environ["UI_PORT_HINDSIGHT_API"] = str(srv.server_address[1])
spec = importlib.util.spec_from_file_location("kt", sys.argv[1])
kt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kt)
kt.REQUEST.end = time.time() + 1.5
t0 = time.time()
try:
    kt.api("GET", "/slow", timeout=5)
    raise SystemExit("the slow download was read whole in %.1f s" % (time.time() - t0))
except kt.BudgetSpent:
    took = time.time() - t0
assert took < 4, took
print("stopped after %.2f s" % took)
PY
# every 5xx answer reads Failed: on the page (a 500 is an unexpected error, a 502 a store that failed): the page's script,
# served through the proxy
curl -s --max-time 30 "${H}/knowledge/app.js" | grep -q "r.status >= 500 ? 'Failed:' : 'Refused:'" \
	|| fail "the page does not read every 5xx answer as Failed:"
# a pack limit of 0 at the proxy is the default, not nginx's no limit
env UI_DIR="${D}/ui-zero" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME="${HOME_PORT}" UI_PORT_KNOWLEDGE="${PAGE_PORT}" UI_HINDSIGHT=true \
	UI_PORT_HINDSIGHT_API="${API_PORT}" UI_PLANE=false KNOWLEDGE_SHARING_MD="${KS_MD}" KNOWLEDGE_PACK_MAX=0 "${AGENT_DIR}/home-render.sh" > "${D}/render-zero.log" 2>&1 \
	|| fail "home-render.sh with KNOWLEDGE_PACK_MAX=0: $(tail -3 "${D}/render-zero.log")"
grep -q "KNOWLEDGE_PACK_MAX='0' is not a number of bytes above 0" "${D}/render-zero.log" && grep -q 'client_max_body_size 67108864;' "${D}/ui-zero/home/nginx.conf" \
	&& ! grep -q 'client_max_body_size 0;' "${D}/ui-zero/home/nginx.conf" \
	|| fail "a pack limit of 0 reached the proxy: $(grep -o 'client_max_body_size [^;]*;' "${D}/ui-zero/home/nginx.conf" | sort -u | tr '\n' ' ')"
BUDGET_LINE="${BUDGET_LINE}; a slow but steady download stops at the budget; every 5xx answer reads Failed: on the page; a pack limit of 0 at the proxy is the default"
echo "ok 12 - a selection that is not a JSON object is refused 400; the Include box is off; the summary header is capped${BUDGET_LINE}; the page through the home proxy: 200 with the badge once and the proxy's policy (its own origin and the badge's hashes), /knowledge -> /knowledge/, the Memory tile links it, the sharing guide it links is served at /guide/knowledge-sharing/, stores.json and records.json read the stores; planted controls: no header (an import, a check), another origin, a cross-site mark -> 403 and nothing written; with the page's header and origin a check says what the import does and writes nothing, the import with on_conflict=skip loads the pack (5 added), records by id export exactly them (${WANT_PAGE}), and an export downloads the bank (via-page, 5 records, its sha256 in the header)"

# --- 13. ui-start.sh starts the page's server with the home page; ui-status.sh and ui-stop.sh know it ---
(
	export UI_DIR="${D}/ui-start" UI_LISTEN_HOST=127.0.0.1 UI_HOME=true UI_PORT_HOME=18435 UI_PORT_KNOWLEDGE=18434 \
		UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false \
		UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false LOOP_DECK_DATA_DIR="${D}/loop-deck" UI_CHAT=false UI_BOARD=false UI_FILES=false \
		UI_PLANE=false COMMS_UI_ENABLED=false LOGLEARNER_STATE="${D}/ll-S" KNOWLEDGE_DIR="${D}/knowledge-S"
	"${AGENT_DIR}/ui-start.sh" > "${D}/ui-start.log" 2>&1 || { cat "${D}/ui-start.log"; exit 1; }
	grep -q '^knowledge: started' "${D}/ui-start.log" || { cat "${D}/ui-start.log"; exit 2; }
	for i in $(seq 1 40); do "${AGENT_DIR}/ui-status.sh" > "${D}/ui-status.log" 2>&1 && break; sleep 0.25; done
	grep -q "^knowledge: UP pid=[0-9]* http=200 port=18434" "${D}/ui-status.log" || { cat "${D}/ui-status.log"; exit 3; }
	ADDRS=$(ss -ltnH "sport = :18434" | awk '{print $4}')
	[ "${ADDRS}" == "127.0.0.1:18434" ] || { echo "the page's server listens on: ${ADDRS}"; exit 4; }
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:18435/knowledge/")" == "200" ] || exit 5
	"${AGENT_DIR}/ui-stop.sh" > "${D}/ui-stop.log" 2>&1
	grep -q "^knowledge: stopped" "${D}/ui-stop.log" || { cat "${D}/ui-stop.log"; exit 6; }
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:18434/health")" == "000" ] || exit 7
	UI_HOME=false "${AGENT_DIR}/ui-status.sh" > "${D}/ui-status-off.log" 2>&1
	grep -q "^knowledge: DISABLED" "${D}/ui-status-off.log" || { cat "${D}/ui-status-off.log"; exit 8; }
	exit 0
)
RC=$?
[ "${RC}" == "0" ] || fail "ui-start/ui-status/ui-stop: check 13 stopped at its step ${RC} of 8 (see ${D}/ui-*.log)"
echo "ok 13 - ui-start.sh starts the page's server with the home page on 127.0.0.1 only, ui-status.sh: $(grep '^knowledge:' "${D}/ui-status.log"), the proxy serves it, ui-stop.sh stops it; UI_HOME=false: DISABLED"

echo "Test-knowledge-transfer succeeded"
