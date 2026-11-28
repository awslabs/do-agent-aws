#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# insights spoke — one mining cycle (see charter.md beside this file).
#
#   loop.sh [--since-hours N] [--max-candidates N] [--min-severity N] [--dry-run] [--no-reindex] [--self-test]
#
# Reads new primary transcripts under ${CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}, detects gaps (user corrections,
# tool-error clusters, security-relevant patterns) with the runtime's own detectors, writes one rule CANDIDATE per gap
# into the candidates bank through the same gates /agent/learn.sh applies (credential shapes, schema, duplicates),
# retains each into the Hindsight bank when the loopback API answers, refreshes the dashboard index, prints one JSON
# summary line and the hub message lines. Exit 0 on a quiet cycle; 1 only on a broken runtime.
# Environment: the harness's loglearner-serve.sh values; defaults match them.
set -u
export HOME=${HOME:-/home/agent}
LOGLEARNER_DIR=${LOGLEARNER_DIR:-/opt/loglearner}
LOGLEARNER_STATE=${LOGLEARNER_STATE:-/wd/loglearner}
export LOGLEARNER_DB=${LOGLEARNER_DB:-${LOGLEARNER_STATE}/index.db}
export LOGLEARNER_BANKS_DIR=${LOGLEARNER_BANKS_DIR:-${LOGLEARNER_STATE}/banks}
export INSTINCTS_JSON=${INSTINCTS_JSON:-${LOGLEARNER_BANKS_DIR}/global/instincts.jsonl}
export FLEET_LEARNINGS_DIR=${FLEET_LEARNINGS_DIR:-${LOGLEARNER_BANKS_DIR}}
export LOGLEARNER_UCB_DIR=${LOGLEARNER_UCB_DIR:-${LOGLEARNER_STATE}/output}
export LOGLEARNER_HINDSIGHT_BANK=${LOGLEARNER_HINDSIGHT_BANK:-loglearner-rules}
export LOGLEARNER_CANDIDATES=${LOGLEARNER_CANDIDATES:-${LOGLEARNER_BANKS_DIR}/candidates/mined.jsonl}
export HINDSIGHT_API=${HINDSIGHT_API:-http://127.0.0.1:${UI_PORT_HINDSIGHT_API:-8888}}

[ -f "${LOGLEARNER_DIR}/loglearner/cli.py" ] || { echo "insights spoke: no runtime at ${LOGLEARNER_DIR}" >&2; exit 1; }

if [ "${1:-}" = "--self-test" ]; then
	# Plant one transcript with a user correction in a scratch HOME and run one cycle against a scratch state: the
	# cycle must bank exactly one candidate that the tile counts and recall finds. Nothing of the real state is touched.
	T=$(mktemp -d "${TMPDIR:-/tmp}/insights-spoke-selftest-XXXXXX") || exit 1
	export HOME="${T}/home" LOGLEARNER_STATE="${T}/state" CLAUDE_PROJECTS_ROOT="${T}/home/.claude/projects"
	export LOGLEARNER_DB="${LOGLEARNER_STATE}/index.db" LOGLEARNER_BANKS_DIR="${LOGLEARNER_STATE}/banks"
	export INSTINCTS_JSON="${LOGLEARNER_BANKS_DIR}/global/instincts.jsonl" FLEET_LEARNINGS_DIR="${LOGLEARNER_BANKS_DIR}"
	export LOGLEARNER_UCB_DIR="${LOGLEARNER_STATE}/output" LOGLEARNER_CANDIDATES="${LOGLEARNER_BANKS_DIR}/candidates/mined.jsonl"
	export LOGLEARNER_HINDSIGHT_DISABLE=1 HINDSIGHT_API="http://127.0.0.1:1"
	P="${CLAUDE_PROJECTS_ROOT}/-work-project"; mkdir -p "${P}" "${LOGLEARNER_BANKS_DIR}/global"
	cat > "${P}/0f0f0f0f-self-test-0000-000000000001.jsonl" <<'JSONL'
{"type":"user","timestamp":"2026-10-14T00:00:01Z","message":{"role":"user","content":"The queue worker is stuck, kill it."}}
{"type":"assistant","timestamp":"2026-10-14T00:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Killing the worker."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"pkill -f queue-worker"}}]}}
{"type":"user","timestamp":"2026-10-14T00:00:03Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Terminated"}]}}
{"type":"user","timestamp":"2026-10-14T00:00:04Z","message":{"role":"user","content":"No, don't use pkill -f for this: it matches your own shell's command line. Find the PID first and kill by PID."}}
{"type":"assistant","timestamp":"2026-10-14T00:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Understood, resolving the PID first."},{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"pgrep -f queue-worker"}}]}}
{"type":"user","timestamp":"2026-10-14T00:00:06Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"4242"}]}}
JSONL
	OUT=$("$0" --since-hours 24 --max-candidates 5) || { echo "self-test: cycle failed"; echo "${OUT}"; rm -rf "${T:?}"; exit 1; }
	echo "${OUT}"
	# second cycle over the same transcript: the duplicate gate must refuse the same candidate and bank nothing new
	OUT2=$("$0" --since-hours 24 --max-candidates 5) || { echo "self-test: second cycle failed"; rm -rf "${T:?}"; exit 1; }
	echo "${OUT2}" | python3 -c "import json,sys; s=json.loads([l for l in sys.stdin.read().splitlines() if l.startswith('{')][-1]); assert s['banked']==[] and s['duplicates']==1, s; print('second cycle: nothing new banked, 1 duplicate refused')" || { rm -rf "${T:?}"; exit 1; }
	( cd "${LOGLEARNER_DIR}" && python3 - "${OUT}" <<'PY'
import json, subprocess, sys, os
summary = json.loads([l for l in sys.argv[1].splitlines() if l.startswith("{")][-1])
assert len(summary["banked"]) == 1, summary
cid = summary["banked"][0]
sys.path.insert(0, ".")
from dashboard.app import api_tile
t = api_tile(db_path=os.environ["LOGLEARNER_DB"], banks_dir=os.environ["LOGLEARNER_BANKS_DIR"], ucb_dir=os.environ["LOGLEARNER_UCB_DIR"])
assert t["meta_learner"]["instincts_total"] == 1, t["meta_learner"]
assert t["meta_learner"]["lifecycle"].get("candidate", 0) + t["meta_learner"]["lifecycle"].get("screened", 0) == 1
r = subprocess.run([sys.executable, "-m", "loglearner.cli", "recall", "pkill PID shell command line", "--json"], capture_output=True, text=True)
assert r.returncode == 0 and json.loads(r.stdout)[0]["id"] == cid, r.stdout[:300] + r.stderr[:300]
print(f"self-test PASS: one candidate {cid} banked from the planted correction, counted by the tile, found by recall")
PY
	) ; RC=$?
	rm -rf "${T:?}"
	exit "${RC}"
fi

cd "${LOGLEARNER_DIR}" || exit 1
exec python3 - "$@" <<'PY'
import argparse, datetime, json, os, re, subprocess, sys, time, urllib.request
from pathlib import Path
sys.path.insert(0, ".")
from loglearner.session_scanner import classify_session
from loglearner.gap_detector import detect_gaps

ap = argparse.ArgumentParser()
ap.add_argument("--since-hours", type=float, default=None)
ap.add_argument("--max-candidates", type=int, default=20)
ap.add_argument("--min-severity", type=int, default=5)
ap.add_argument("--dry-run", action="store_true")
ap.add_argument("--no-reindex", action="store_true")
a = ap.parse_args()

E = os.environ
state = Path(E["LOGLEARNER_UCB_DIR"]) / "state" / "spoke-insights"
marker = state / "last-cycle"
now = time.time()
since = now - a.since_hours * 3600 if a.since_hours else (float(marker.read_text().strip()) if marker.is_file() else now - 24 * 3600)
root = Path(E.get("CLAUDE_PROJECTS_ROOT") or Path(E["HOME"]) / ".claude" / "projects")
cands = Path(E["LOGLEARNER_CANDIDATES"])
# the same credential shapes /agent/learn.sh refuses before the runtime sees an entry
SHAPES = [("an AWS access key id", r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), ("an AWS secret access key", r"(?i)aws_secret_access_key\W{1,4}[A-Za-z0-9/+=]{30,}"),
          ("a Slack token", r"\bxox[abposr]-[0-9A-Za-z-]{10,}"), ("a GitHub token", r"\b(?:ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{30,}|\bgithub_pat_[0-9A-Za-z_]{40,}"),
          ("a private key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), ("a bearer token", r"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{24,}"),
          ("a password", r"(?i)\b(?:password|passwd|pwd)\b\W{1,4}[^\s\"]{6,}")]
GAP_TYPES = {"user_correction", "tool_error_cluster", "security_circumvention"}
help_text = subprocess.run([sys.executable, "-m", "loglearner.cli", "bank", "--help"], capture_output=True, text=True).stdout
lifecycle_opt = ["--lifecycle", "candidate"] if "--lifecycle" in help_text else []   # 0.1.10+; 0.1.9 records screened

transcripts, gaps_total, candidates, banked, dups, refused, reasons = 0, 0, [], [], 0, 0, []
files = sorted((p for p in root.glob("*/*.jsonl") if p.is_file() and p.stat().st_mtime > since), key=lambda p: p.stat().st_mtime) if root.is_dir() else []
for path in files:
    if classify_session(path) != "primary":
        continue
    transcripts += 1
    sid = path.stem
    seen = set()
    for g in detect_gaps(str(path), sid):
        if g.gap_type not in GAP_TYPES or g.severity < a.min_severity:
            continue
        key = (g.gap_type, (g.correction_text or g.summary)[:120])
        if key in seen:
            continue
        seen.add(key)
        gaps_total += 1
        if g.gap_type == "user_correction":
            text = " ".join(g.correction_text.split())[:400]
            rule = f"Correction observed: {text}"
        elif g.gap_type == "tool_error_cluster":
            rule = f"Repeated tool errors observed: {g.summary[:300]}"
        else:
            rule = f"Security-relevant pattern observed: {g.summary[:300]}"
        tools = sorted({str(t.get("name", "")).lower() for t in (g.tool_calls or []) if t.get("name")})
        cat = g.category if g.category and g.category != "unknown" else "agent-operations"
        rec = {"rule": rule, "status": "negative", "confidence": "low",
               "evidence": f"session:{sid[:8]} lines:{g.start_line}-{g.end_line}; {g.gap_type}; severity {g.severity}",
               "source": "insights-spoke:mined", "category": cat, "tags": [g.gap_type.replace('_', '-'), "candidate", "mined", *tools],
               "provenance": "heuristic mining of this agent's own transcripts, no model, unreviewed; promote with learn.sh after review",
               "as_of": datetime.date.today().isoformat()}
        candidates.append(rec)
        if len(candidates) >= a.max_candidates:
            break
    if len(candidates) >= a.max_candidates:
        break

for rec in candidates:
    text = json.dumps(rec)
    hit = next((n for n, pat in SHAPES if re.search(pat, text)), None)
    if hit:
        refused += 1; reasons.append(f"credential shape: {hit}"); continue
    if a.dry_run:
        continue
    cands.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([sys.executable, "-m", "loglearner.cli", "bank", "--stdin", "--bank", str(cands), *lifecycle_opt],
                       input=text, capture_output=True, text=True)
    if r.returncode == 0:
        banked.append(json.loads(r.stdout)["banked"])
    elif r.returncode == 3:
        dups += 1
    else:
        refused += 1; reasons.append(r.stderr.strip()[:200])

hs = "skipped (disabled)" if E.get("LOGLEARNER_HINDSIGHT_DISABLE") else "skipped (dry-run)" if a.dry_run else "skipped (nothing banked)"
if banked and not a.dry_run and not E.get("LOGLEARNER_HINDSIGHT_DISABLE"):
    api, bank = E["HINDSIGHT_API"].rstrip("/"), E["LOGLEARNER_HINDSIGHT_BANK"]
    try:
        urllib.request.urlopen(api + "/v1/default/banks?limit=1", timeout=3).read()
        rows = {json.loads(l)["id"]: json.loads(l) for l in cands.read_text().splitlines() if l.strip()}
        items = [{"document_id": f"loglearner-candidate-{i}", "content": rows[i]["rule"],
                  "context": f"Insights spoke candidate {i}, unreviewed; {rows[i]['evidence']}"} for i in banked if i in rows]
        req = urllib.request.Request(f"{api}/v1/default/banks/{urllib.request.quote(bank, safe='')}/memories",
                                     data=json.dumps({"items": items, "async": True}).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=15).read()
        hs = f"retained {len(items)} into {bank}"
    except Exception as e:   # best effort, never fatal
        hs = f"skipped ({type(e).__name__})"

reindex = "skipped"
if not a.no_reindex and not a.dry_run:
    r = subprocess.run([sys.executable, "dashboard/indexer.py", "--db", E["LOGLEARNER_DB"]], capture_output=True, text=True)
    reindex = "ok" if r.returncode == 0 else f"failed: {r.stderr.strip()[-200:]}"

if not a.dry_run:
    state.mkdir(parents=True, exist_ok=True)
    marker.write_text(str(now))
summary = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "transcripts": transcripts, "gaps": gaps_total,
           "candidates": len(candidates), "banked": banked, "duplicates": dups, "refused": refused, "refusal_reasons": reasons[:5],
           "hindsight": hs, "reindex": reindex, "candidates_file": str(cands), "dry_run": a.dry_run}
if not a.dry_run:
    (state / "last-summary.json").write_text(json.dumps(summary, indent=1) + "\n")
print(json.dumps(summary))
rows = {}
if banked and cands.is_file():
    rows = {json.loads(l)["id"]: json.loads(l) for l in cands.read_text().splitlines() if l.strip()}
for i in banked:
    r = rows.get(i, {})
    print(f"HUB: insights: new candidate {i} from today's sessions — {str(r.get('rule', ''))[:120]} — review: /knowledge?cls={r.get('category', '')}, promote with learn.sh")
PY
