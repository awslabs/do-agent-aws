from __future__ import annotations
import json
from pathlib import Path
COMPLETE = 'complete'
PARTIAL = 'partial'
BLOCKED = 'blocked_no_visibility'
PARTIAL_PRESERVED = 'partial_preserved'

def coverage_proof(channels_attempted: int, channels_succeeded: int, items_seen: int) -> dict:
    if min(channels_attempted, channels_succeeded, items_seen) < 0:
        raise ValueError('counts must be non-negative')
    if channels_succeeded > channels_attempted:
        raise ValueError(f'channels_succeeded ({channels_succeeded}) > channels_attempted ({channels_attempted})')
    coverage = channels_succeeded / channels_attempted if channels_attempted else 0.0
    return {'items_seen': items_seen, 'channels_attempted': channels_attempted, 'channels_succeeded': channels_succeeded, 'coverage': coverage}

def scan_outcome(proof: dict) -> str:
    if proof['coverage'] <= 0.0 or proof['items_seen'] == 0:
        return BLOCKED
    if proof['coverage'] < 1.0:
        return PARTIAL
    return COMPLETE

def blocked_ops_record(proof: dict, ts: str) -> dict:
    return {'ts': ts, 'channel': 'ops', 'scope': 'scan', 'outcome': BLOCKED, 'coverage': proof['coverage'], 'detail': f"scan had zero visibility: {proof['channels_succeeded']}/{proof['channels_attempted']} channels succeeded, {proof['items_seen']} items seen. Preserved last-known-good state.json; did NOT emit per-item needs-human."}

def partial_ops_record(proof: dict, ts: str, parked_path) -> dict:
    return {'ts': ts, 'channel': 'ops', 'scope': 'scan', 'outcome': PARTIAL_PRESERVED, 'coverage': proof['coverage'], 'detail': f"scan was partial: {proof['channels_succeeded']}/{proof['channels_attempted']} channels succeeded, {proof['items_seen']} items seen. Preserved last-known-good state.json; parked the partial result at {Path(parked_path).name}; re-run paced or pass --allow-partial to accept it."}

def persist_scan_state(outcome: str, proof: dict, *, state_payload: dict, state_path, log_path, ts: str, partial_ok: bool=False) -> bool:
    state_path = Path(state_path)
    log_path = Path(log_path)
    if outcome == BLOCKED:
        rec = blocked_ops_record(proof, ts)
        with log_path.open('a') as fh:
            fh.write(json.dumps(rec) + '\n')
        return False
    if outcome == PARTIAL and (not partial_ok):
        parked = state_path.with_name(state_path.stem + '.partial.json')
        payload = dict(state_payload)
        payload['coverage'] = proof
        payload['scan_outcome'] = outcome
        parked.write_text(json.dumps(payload, indent=2, default=str))
        rec = partial_ops_record(proof, ts, parked)
        with log_path.open('a') as fh:
            fh.write(json.dumps(rec) + '\n')
        return False
    payload = dict(state_payload)
    payload['coverage'] = proof
    payload['scan_outcome'] = outcome
    state_path.write_text(json.dumps(payload, indent=2, default=str))
    return True
