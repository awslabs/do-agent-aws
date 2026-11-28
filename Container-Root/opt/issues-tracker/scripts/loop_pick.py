#!/usr/bin/env python3
import json, os, sys
from collections import Counter
from datetime import date, timedelta
BUCKET_RANK = {'A-approved-stuck': 0, 'B-changes-requested': 1, 'C-red-ci': 2, 'D-conflict': 3}

def _d(s):
    try:
        return date(*map(int, str(s)[:10].split('-')))
    except Exception:
        return None

def pick(state, loglines, today=None, skip_ttl_days=None, fail_ttl_days=None, staged_ttl_days=None):
    today = _d(today) if today else date.today()
    skip_ttl = int(skip_ttl_days if skip_ttl_days is not None else os.environ.get('SKIP_TTL_DAYS', '7'))
    staged_ttl = int(staged_ttl_days if staged_ttl_days is not None else os.environ.get('STAGED_TTL_DAYS', '7'))
    fail_ttl = int(fail_ttl_days if fail_ttl_days is not None else os.environ.get('FAIL_TTL_DAYS', '3'))
    skip, fails, benched_at = (set(), Counter(), {})
    watch_at = {}
    for line in loglines:
        try:
            e = json.loads(line)
        except Exception:
            continue
        key = f"{e.get('repo')}#{e.get('number')}"
        when = _d(e.get('ts') or e.get('timestamp'))
        outcome = e.get('outcome')
        if outcome == 'needs-human' and when is not None and (today - when <= timedelta(days=skip_ttl)):
            skip.add(key)
            benched_at[key] = when
        if outcome == 'staged' and when is not None and (today - when <= timedelta(days=staged_ttl)):
            skip.add(key)
            benched_at[key] = when
        if outcome == 'failed':
            fails[key] += 1
            if fails[key] >= 2 and when is not None and (today - when <= timedelta(days=fail_ttl)):
                skip.add(key)
                benched_at[key] = when
        if outcome in ('fixed', 'closed', 'replied', 'merged'):
            skip.discard(key)
            fails[key] = 0
            if outcome in ('fixed', 'replied') and when is not None and (today - when <= timedelta(days=staged_ttl)):
                watch_at[key] = when
            else:
                watch_at.pop(key, None)
    for r in state['items']:
        key = f"{r['repo']}#{r['number']}"
        if key in skip:
            moved = _d(r.get('updated'))
            if moved is not None and benched_at.get(key) is not None and (moved > benched_at[key]):
                skip.discard(key)
        if key in watch_at and key not in skip:
            they_spoke = _d((r.get('last_them') or {}).get('t'))
            if not (r.get('we_owe') or (they_spoke is not None and they_spoke > watch_at[key])):
                skip.add(key)

    def live(r):
        return r.get('state') == 'OPEN' and f"{r['repo']}#{r['number']}" not in skip
    owe = [r for r in state['items'] if live(r) and r.get('we_owe')]
    attn = [r for r in state['items'] if live(r) and r.get('needs_attention') and (not r.get('we_owe'))]
    owe.sort(key=lambda r: r.get('updated') or '', reverse=True)
    attn.sort(key=lambda r: (BUCKET_RANK.get(r.get('bucket'), 9), -int((r.get('updated') or '0000-00-00').replace('-', ''))))
    return owe + attn

def format_line(r):
    tag = 'owe' if r.get('we_owe') else r.get('bucket') or 'attn'
    why = '' if r.get('we_owe') else '; '.join(r.get('attn_reasons') or [])
    return f"{r['repo']}#{r['number']}\t[{tag}] {(r.get('title') or '')[:60]}\t{why}"

def main(argv):
    state_p = argv[1] if len(argv) > 1 else os.environ.get('LOOP_STATE', 'dashboard/state.json')
    log_p = argv[2] if len(argv) > 2 else os.environ.get('LOOP_LOG', 'dashboard/loop-log.jsonl')
    state = json.load(open(state_p))
    loglines = open(log_p).read().splitlines() if os.path.exists(log_p) else []
    for r in pick(state, loglines):
        print(format_line(r))
    return 0
if __name__ == '__main__':
    sys.exit(main(sys.argv))
