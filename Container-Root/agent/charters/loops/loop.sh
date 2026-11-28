#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# loops spoke — ONE cycle: refresh the Loop Deck's inputs from this harness's own loops, validate them at the pinned
# contract, refresh the page when a generator is named, record the cycle and any RED/stall transitions.
# The harness supervisor runs this once per cycle at the cadence the spoke registry declares. Exit: 0 complete and validated; 2 inputs refused or
# unwritable (fail closed: the Deck keeps its last good page); 3 registry drift reported by the Deck's generator.
# Writes only: ${SPOKE_DIR} (its own state) and, through the adapter, the four Deck input files under ${DATA_DIR}.
# Source of the Deck: the vendored release tree /opt/loop-deck (default) or the clone under ${SPOKE_DIR}/deck; LOOP_DECK_TREE overrides.
set -uo pipefail
AGENT_DIR="${AGENT_DIR:-/agent}"
SPOKE_DIR="${SPOKE_DIR:-/wd/loops}"
DATA_DIR="${LOOP_DECK_DATA_DIR:-/wd/loop-deck}"
ADAPTER="${LOOP_DECK_ADAPTER_BIN:-${AGENT_DIR}/loop-deck-adapter.py}"
DECK_DIR="${LOOP_DECK_TREE:-}"                 # the release tree: vendored /opt/loop-deck by default, else the clone
for d in "${DECK_DIR}" /opt/loop-deck "${SPOKE_DIR}/deck"; do
	[ -n "${d}" ] && [ -f "${d}/generate-loop-viz.py" ] && { DECK_DIR="${d}"; break; }
done
if [ -n "${DECK_DIR}" ] && [ -f "${DECK_DIR}/generate-loop-viz.py" ]; then
	VALIDATOR="${LOOP_DECK_VALIDATOR_BIN:-${DECK_DIR}/tools/check-contract.py}"   # the pinned contract's own validator
	GENERATOR="${LOOP_DECK_GENERATOR:-${DECK_DIR}/generate-loop-viz.py}"
else
	VALIDATOR="${LOOP_DECK_VALIDATOR_BIN:-${AGENT_DIR}/check-loop-deck-contract.py}"   # the harness's vendored copy
	GENERATOR="${LOOP_DECK_GENERATOR:-}"          # no release tree yet: inputs only, the page is not refreshed
fi
STALL_CYCLES="${LOOPS_SPOKE_STALL_CYCLES:-3}"  # the page not advancing for this many cycles = the Deck is stalled

mkdir -p "${SPOKE_DIR:?}" || { echo "loop.sh: cannot create ${SPOKE_DIR}" >&2; exit 2; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "${SPOKE_DIR}/cycle.log"; }
[ -f "${ADAPTER}" ] || { log "cycle adapter=missing (${ADAPTER})"; echo "$(ts)" > "${SPOKE_DIR}/last-cycle"; exit 2; }
[ -f "${VALIDATOR}" ] || { log "cycle validator=missing (${VALIDATOR})"; echo "$(ts)" > "${SPOKE_DIR}/last-cycle"; exit 2; }

# 1. refresh the inputs (and the page when a generator is named); the adapter's exit code is kept, never hidden
if [ -n "${GENERATOR}" ]; then
	timeout 60 python3 -I "${ADAPTER}" --data-dir "${DATA_DIR}" --generator "${GENERATOR}" >> "${SPOKE_DIR}/adapter.log" 2>&1; ARC=$?
else
	timeout 30 python3 -I "${ADAPTER}" --data-dir "${DATA_DIR}" >> "${SPOKE_DIR}/adapter.log" 2>&1; ARC=$?
fi

# 2. validate at the pinned contract (fail closed: a malformed input is a failed cycle)
timeout 30 python3 -I "${VALIDATOR}" "${DATA_DIR}" > "${SPOKE_DIR}/validate.out" 2>&1; VRC=$?

# 3. RED rows and the Deck's own liveness, from the Deck's status.json (read-only); transitions only into alerts.jsonl
SUMMARY=$(python3 -I - "${DATA_DIR}/out/status.json" "${SPOKE_DIR}/state.json" "${SPOKE_DIR}/alerts.jsonl" "${ARC}" "${VRC}" "${STALL_CYCLES}" <<'PY'
import json, os, sys, datetime
status_p, state_p, alerts_p, arc, vrc, stall_n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
prev = {}
try:
    prev = json.load(open(state_p))
except Exception:
    prev = {}
red, gen_epoch, page = {}, None, False
try:
    st = json.load(open(status_p))
    page = True
    gen_epoch = st.get("generated_epoch") or st.get("generated")
    for l in st.get("loops", []):
        if l.get("status") == "RED":
            red[l["slug"]] = (l.get("detail") or [""])[0][:160]
except Exception:
    page = False
same_page = page and gen_epoch is not None and gen_epoch == prev.get("gen_epoch")
stale_cycles = (prev.get("stale_cycles", 0) + 1) if same_page else 0
stalled = arc != 0 or vrc != 0 or (page and stale_cycles >= stall_n)
reason = "adapter %d" % arc if arc else ("validator %d" % vrc if vrc else ("page not advancing for %d cycles" % stale_cycles if stalled else ""))
events = []
for slug, detail in red.items():
    if slug not in prev.get("red", {}):
        events.append({"ts": now, "kind": "alert", "slug": slug, "state": "RED", "text": "loop %s is RED: %s" % (slug, detail)})
for slug in prev.get("red", {}):
    if slug not in red:
        events.append({"ts": now, "kind": "alert", "slug": slug, "state": "OK", "text": "loop %s recovered" % slug})
if stalled and not prev.get("stalled"):
    events.append({"ts": now, "kind": "alert", "slug": None, "state": "STALLED", "text": "Loop Deck stalled: %s" % reason})
if prev.get("stalled") and not stalled:
    events.append({"ts": now, "kind": "alert", "slug": None, "state": "OK", "text": "Loop Deck recovered"})
with open(alerts_p, "a") as fh:
    for e in events:
        fh.write(json.dumps(e) + "\n")
tmp = state_p + ".tmp"
json.dump({"ts": now, "red": red, "stalled": stalled, "gen_epoch": gen_epoch, "stale_cycles": stale_cycles, "adapter_rc": arc, "validate_rc": vrc}, open(tmp, "w"))
os.replace(tmp, state_p)
print("red=%d stalled=%s page=%s transitions=%d" % (len(red), str(stalled).lower(), "yes" if page else "none", len(events)))
PY
)
SRC=$?

# 4. record the cycle: the tile's timestamp, one log line with every exit code
echo "$(ts)" > "${SPOKE_DIR}/last-cycle"
log "cycle adapter_rc=${ARC} validate_rc=${VRC} summary_rc=${SRC} deck_tree=${DECK_DIR:-none} generator=${GENERATOR:-none} ${SUMMARY:-summary=unavailable}"

# 5. the cycle's own verdict
if [ "${VRC}" -ne 0 ]; then exit 2; fi
if [ "${ARC}" -eq 3 ]; then exit 3; fi
if [ "${ARC}" -ne 0 ]; then exit 2; fi
exit 0
