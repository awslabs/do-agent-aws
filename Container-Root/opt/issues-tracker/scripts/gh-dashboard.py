#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import scan_coverage as sc
ME = os.environ.get('ISSUES_GH_LOGIN', '')
ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / 'dashboard'
GENERIC_BOTS = {'github-actions', 'dependabot', 'coderabbitai', 'mergify', 'vercel', 'copilot-pull-request-reviewer', 'github-advanced-security', 'linux-foundation-easycla'}

def _site_bots():
    p = Path(os.environ.get('SHIPPED_TREE_DENYLIST_FILE') or ROOT / 'scripts/test_shipped_tree.local.conf')
    try:
        m = re.search('^BOT_LOGINS=(?:\'(.*)\'|"(.*)")\\s*$', p.read_text(), re.M)
    except OSError:
        return None
    if not m:
        return None
    return {b.strip() for b in (m.group(1) if m.group(1) is not None else m.group(2)).split('|') if b.strip()}
SITE_BOTS = _site_bots()
BOTS = SITE_BOTS if SITE_BOTS is not None else GENERIC_BOTS | {b + '[bot]' for b in GENERIC_BOTS}

def is_bot(login):
    return bool(login) and (login in BOTS or (SITE_BOTS is None and login.endswith('[bot]')))
QUERY = 'query($o:String!,$n:String!,$num:Int!){\n  repository(owner:$o,name:$n){\n    issueOrPullRequest(number:$num){\n      __typename\n      ... on PullRequest {\n        state title updatedAt mergedAt closedAt mergeStateStatus reviewDecision\n        author{login} isDraft\n        commits(last:1){nodes{commit{statusCheckRollup{\n          state\n          contexts(last:30){nodes{\n            __typename\n            ... on CheckRun{name conclusion detailsUrl}\n            ... on StatusContext{context state targetUrl}\n          }}\n        }}}}\n        comments(last:50){nodes{author{login} createdAt body}}\n        reviews(last:20){nodes{author{login} submittedAt state}}\n        reviewThreads(last:50){nodes{\n          isResolved isOutdated path line\n          comments(last:3){nodes{author{login} createdAt body}}\n        }}\n      }\n      ... on Issue {\n        state title updatedAt closedAt author{login}\n        comments(last:50){nodes{author{login} createdAt body}}\n      }\n    }\n  }\n}'

def resolve_login():
    global ME
    if ME:
        return ME
    r = subprocess.run(['gh', 'api', 'user', '--jq', '.login'], capture_output=True, text=True)
    login = (r.stdout or '').strip()
    if r.returncode != 0 or not login:
        sys.exit('gh-dashboard: cannot resolve the operator login (set ISSUES_GH_LOGIN or run `gh auth login`): ' + (r.stderr or '').strip()[:200])
    ME = login
    return ME

def build_inventory(states=('open', 'closed')):
    items = set()
    attempted = succeeded = 0
    for state in states:
        for typ in ('pr', 'issue'):
            for qkind in (f'author:{ME}', f'commenter:{ME}'):
                for page in range(1, 11):
                    attempted += 1
                    r = subprocess.run(['gh', 'api', f'search/issues?q={qkind}+is:{typ}+is:{state}&per_page=100&page={page}'], capture_output=True, text=True, timeout=30)
                    if r.returncode != 0:
                        break
                    try:
                        batch = json.loads(r.stdout).get('items', [])
                    except json.JSONDecodeError:
                        break
                    succeeded += 1
                    for it in batch:
                        repo = '/'.join(it['repository_url'].split('/')[-2:])
                        items.add((repo, it['number']))
                    if len(batch) < 100:
                        break
    attempted += 1
    r = subprocess.run(['gh', 'api', f'users/{ME}/events/public?per_page=100', '--paginate'], capture_output=True, text=True, timeout=60)
    if r.returncode == 0 and r.stdout.strip():
        succeeded += 1
        for chunk in r.stdout.replace('][', ']\n[').splitlines():
            try:
                for ev in json.loads(chunk):
                    if ev.get('type') in ('IssueCommentEvent', 'IssuesEvent', 'PullRequestEvent'):
                        p = ev.get('payload', {})
                        num = (p.get('issue') or p.get('pull_request') or {}).get('number')
                        if num:
                            items.add((ev['repo']['name'], num))
            except json.JSONDecodeError:
                continue
    return (sorted(items), attempted, succeeded)

def needs_repoll(i):
    if not i or i.get('__typename') != 'PullRequest':
        return False
    return i.get('mergeStateStatus') == 'UNKNOWN'
_RATE_LIMITED = re.compile('rate limit|\\b403\\b|\\b429\\b', re.I)

def _fetch(owner, name, num):
    argv = ['gh', 'api', 'graphql', '-f', f'query={QUERY}', '-F', f'o={owner}', '-F', f'n={name}', '-F', f'num={num}']
    r = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    if r.returncode != 0 and _RATE_LIMITED.search(r.stderr or ''):
        time.sleep(float(os.environ.get('DASH_BACKOFF_SEC', '300')))
        r = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        return None
    return json.loads(r.stdout)['data']['repository']['issueOrPullRequest']

def paced_pull_all(items):
    pace = float(os.environ.get('DASH_PACE_SEC', '1.0'))
    burst_n = int(os.environ.get('DASH_BURST_N', '30'))
    burst_pause = float(os.environ.get('DASH_BURST_PAUSE_SEC', '60'))
    for n, it in enumerate(items):
        if n:
            time.sleep(pace)
            if burst_n and n % burst_n == 0:
                time.sleep(burst_pause)
        yield (n, pull(it))

def pull(item):
    repo, num = item
    owner, name = repo.split('/')
    try:
        i = _fetch(owner, name, num)
        if not i:
            print(f'  pull failed: {repo}#{num}', file=sys.stderr)
            return None
        if needs_repoll(i):
            time.sleep(2)
            i2 = _fetch(owner, name, num)
            if i2:
                i = i2
        i['repo'], i['number'] = (repo, num)
        return i
    except Exception:
        return None

def classify(i):
    is_pr = i['__typename'] == 'PullRequest'
    author = (i.get('author') or {}).get('login')
    last_we = last_them = None
    for c in i.get('comments', {}).get('nodes') or []:
        who = (c.get('author') or {}).get('login')
        if not who or is_bot(who):
            continue
        if who == ME:
            if not last_we or c['createdAt'] > last_we:
                last_we = c['createdAt']
        elif not last_them or c['createdAt'] > last_them['t']:
            last_them = {'t': c['createdAt'], 'who': who, 'body': c['body'][:200]}
    unresolved = []
    if is_pr:
        for th in i.get('reviewThreads', {}).get('nodes') or []:
            if th['isResolved'] or th['isOutdated']:
                continue
            cs = th.get('comments', {}).get('nodes') or []
            if cs:
                unresolved.append({'path': th['path'], 'line': th['line'], 'last_who': (cs[-1].get('author') or {}).get('login'), 'last_at': cs[-1]['createdAt']})
    we_owe = False
    if last_them and (not last_we or last_them['t'] > last_we):
        we_owe = True
    if unresolved:
        latest = max(unresolved, key=lambda t: t['last_at'])
        if latest['last_who'] and latest['last_who'] != ME and (not is_bot(latest['last_who'])):
            we_owe = True
    ci_state = ci_failures = None
    if is_pr:
        try:
            roll = ((i.get('commits', {}).get('nodes') or [{}])[0].get('commit') or {}).get('statusCheckRollup') or {}
            ci_state = roll.get('state')
            fails = []
            for c in roll.get('contexts', {}).get('nodes') or []:
                concl = c.get('conclusion') or c.get('state')
                if concl in ('FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'STARTUP_FAILURE'):
                    fails.append({'name': c.get('name') or c.get('context'), 'conclusion': concl, 'url': c.get('detailsUrl') or c.get('targetUrl')})
            ci_failures = fails or None
        except (IndexError, AttributeError, TypeError):
            pass
    merge = i.get('mergeStateStatus')
    review = i.get('reviewDecision')
    needs_attention, attn_reasons, bucket = (False, [], None)
    if is_pr and i.get('state') == 'OPEN' and (author == ME) and (not i.get('isDraft')):
        if review == 'APPROVED' and merge in ('DIRTY', 'CONFLICTING', 'BEHIND'):
            needs_attention = True
            attn_reasons.append('APPROVED but unmergeable — rebase to land (cheapest merge)')
            bucket = 'A-approved-stuck'
        if merge in ('DIRTY', 'CONFLICTING'):
            needs_attention = True
            attn_reasons.append('merge-conflict (needs rebase)')
            bucket = bucket or 'D-conflict'
        if ci_state in ('FAILURE', 'ERROR') or ci_failures:
            needs_attention = True
            n = len(ci_failures or [])
            attn_reasons.append(f'CI red ({n} failing)' if n else 'CI red')
            bucket = bucket or 'C-red-ci'
        if review == 'CHANGES_REQUESTED':
            needs_attention = True
            attn_reasons.append('changes requested')
            bucket = bucket or 'B-changes-requested'
        if merge == 'BEHIND':
            attn_reasons.append('behind base (update-branch)')
    last_activity = i.get('updatedAt', '')
    days_idle = None
    if last_activity:
        try:
            t = datetime.fromisoformat(last_activity.replace('Z', '+00:00'))
            days_idle = (datetime.now(timezone.utc) - t).days
        except ValueError:
            pass
    return {'repo': i['repo'], 'number': i['number'], 'title': i.get('title', ''), 'type': 'PR' if is_pr else 'ISS', 'state': i.get('state'), 'merged': bool(i.get('mergedAt')), 'is_draft': bool(i.get('isDraft')), 'is_ours': author == ME, 'author': author, 'merge_state': i.get('mergeStateStatus'), 'review_decision': i.get('reviewDecision'), 'we_owe': we_owe, 'ci_state': ci_state, 'ci_failures': ci_failures, 'needs_attention': needs_attention, 'attn_reasons': attn_reasons, 'bucket': bucket, 'days_idle': days_idle, 'updated': last_activity[:10], 'unresolved_threads': len(unresolved), 'last_them': last_them, 'no_engagement': last_them is None}

def classify_owner(r):
    if r.get('we_owe'):
        return 'ours-act'
    if r.get('is_ours') and r.get('needs_attention'):
        return 'ours-act'
    if r.get('no_engagement'):
        return 'watch'
    if r.get('is_ours'):
        return 'maintainers'
    return 'upstream'

def render(rows, generated):
    open_rows = [r for r in rows if r['state'] == 'OPEN']
    closed = [r for r in rows if r['state'] in ('CLOSED', 'MERGED')]
    needs_attn = sorted([r for r in open_rows if r.get('needs_attention')], key=lambda r: r['updated'], reverse=True)
    needs_attn.sort(key=lambda r: r.get('bucket') or 'Z')
    we_owe = sorted([r for r in open_rows if r['we_owe']], key=lambda r: r['updated'], reverse=True)
    their_court = sorted([r for r in open_rows if not r['we_owe'] and (not r['no_engagement'])], key=lambda r: r['updated'], reverse=True)
    zero = sorted([r for r in open_rows if r['no_engagement']], key=lambda r: (not r['is_ours'], r['repo']))
    merged = [r for r in closed if r['merged']]
    just_closed = [r for r in closed if not r['merged']]

    def line(r, quote=False):
        flags = []
        if r['is_draft']:
            flags.append('draft')
        if r['review_decision']:
            flags.append(r['review_decision'][:9])
        if r['unresolved_threads']:
            flags.append(f"thr:{r['unresolved_threads']}")
        flag_s = f" [{','.join(flags)}]" if flags else ''
        idle = f"{r['days_idle']}d" if r['days_idle'] is not None else '?'
        url = f"https://github.com/{r['repo']}/{('pull' if r['type'] == 'PR' else 'issues')}/{r['number']}"
        s = f"| {r['updated']} | {idle} | {r['type']}{flag_s} | [{r['repo']}#{r['number']}]({url}) | {r['title'][:60]} |"
        if quote and r['last_them']:
            s += f"\n|  |  |  | ↳ *{r['last_them']['who']}*: | {r['last_them']['body'][:100].replace('|', '/')} |"
        return s

    def attn_line(r):
        idle = f"{r['days_idle']}d" if r['days_idle'] is not None else '?'
        url = f"https://github.com/{r['repo']}/pull/{r['number']}"
        why = '; '.join(r.get('attn_reasons') or [])
        return f"| {r['updated']} | {idle} | {r.get('bucket') or '?'} | [{r['repo']}#{r['number']}]({url}) | {r['title'][:45]} | {why} |"
    OWNER_ORDER = ['ours-act', 'maintainers', 'upstream', 'watch']
    OWNER_LABEL = {'ours-act': '🔧 Ours — act now (fix/answer)', 'maintainers': '🟡 Maintainers — review/CI-enable', 'upstream': '🔵 Upstream — their court / stacked dep', 'watch': '⏸ Watch — zero engagement'}
    by_owner = {k: [] for k in OWNER_ORDER}
    for r in open_rows:
        by_owner[classify_owner(r)].append(r)

    def _counts(rs):
        pr = sum((1 for r in rs if r['type'] == 'PR'))
        return f'{len(rs)} ({pr} PR / {len(rs) - pr} ISS)'
    md = [f'# PR/Issue Dashboard', f'', f'Generated: {generated} · Items scanned: {len(rows)} · Open: {len(open_rows)} · Merged: {len(merged)} · Closed: {len(just_closed)}', f'', f'Regenerate: `python3 scripts/gh-dashboard.py`', f'', '---', '', f'## 🧭 Per-owner rollup — who acts next ({len(open_rows)} open)', '', 'Every open item mapped to exactly one owner (MECE).', '', '| Owner | Count | Meaning |', '|---|---|---|']
    for k in OWNER_ORDER:
        md.append(f'| {OWNER_LABEL[k]} `{k}` | {_counts(by_owner[k])} | |')
    md += ['', '---', '', f'## 🔥 Needs attention — red PRs of ours ({len(needs_attn)})', '', 'Merge conflicts / red CI / changes-requested — surfaced from PR state, independent of who commented last.', '', '| Updated | Idle | Bucket | Item | Title | Why |', '|---|---|---|---|---|---|']
    md += [attn_line(r) for r in needs_attn] or ['| — | | | | *(none)* | |']
    md += ['', f'## 🔴 We owe a response ({len(we_owe)})', '', '| Updated | Idle | Type | Item | Title |', '|---|---|---|---|---|']
    md += [line(r, quote=True) for r in we_owe] or ['| — | | | *(none)* | |']
    md += ['', f'## 🟡 Ball in their court ({len(their_court)})', '', '| Updated | Idle | Type | Item | Title |', '|---|---|---|---|---|']
    md += [line(r) for r in their_court]
    md += ['', f'## ⏸ Zero engagement ({len(zero)})', '', '| Updated | Idle | Type | Item | Title |', '|---|---|---|---|---|']
    md += [line(r) for r in zero]
    md += ['', f'## ✅ Merged ({len(merged)})', '', '| Updated | Idle | Type | Item | Title |', '|---|---|---|---|---|']
    md += [line(r) for r in sorted(merged, key=lambda r: r['updated'], reverse=True)[:40]]
    md += ['', f'## ⬛ Closed unmerged ({len(just_closed)})', '', '| Updated | Idle | Type | Item | Title |', '|---|---|---|---|---|']
    md += [line(r) for r in sorted(just_closed, key=lambda r: r['updated'], reverse=True)[:40]]
    md += ['', '---', 'Data caveats: Search index lags ~24h; events API is the recency backstop.']
    return '\n'.join(md)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--items', help='reuse an inventory file (repo num per line)')
    ap.add_argument('--open-only', action='store_true')
    ap.add_argument('--allow-partial', dest='partial_ok', action='store_true', help='operator override: write a PARTIAL scan over state.json (default: preserve last-known-good, park state.partial.json)')
    args = ap.parse_args()
    resolve_login()
    if args.items:
        items = [tuple(l.split()) for l in Path(args.items).read_text().splitlines() if l.strip()]
        items = [(r, int(n)) for r, n in items]
        inv_attempted = inv_succeeded = 0
    else:
        print('building inventory (paginated searches + events API)...', file=sys.stderr)
        items, inv_attempted, inv_succeeded = build_inventory(states=('open',) if args.open_only else ('open', 'closed'))
    print(f'pulling {len(items)} items...', file=sys.stderr)
    rows = []
    pulls_ok = 0
    for n, i in paced_pull_all(items):
        if i:
            pulls_ok += 1
            row = classify(i)
            if not args.open_only or row['state'] == 'OPEN':
                rows.append(row)
        if (n + 1) % 50 == 0:
            print(f'  {n + 1}/{len(items)}', file=sys.stderr)
    generated = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    OUT_DIR.mkdir(exist_ok=True)
    proof = sc.coverage_proof(channels_attempted=inv_attempted + len(items), channels_succeeded=inv_succeeded + pulls_ok, items_seen=pulls_ok)
    outcome = sc.scan_outcome(proof)
    wrote = sc.persist_scan_state(outcome, proof, state_payload={'generated': generated, 'items': rows}, state_path=OUT_DIR / 'state.json', log_path=OUT_DIR / 'loop-log.jsonl', ts=ts, partial_ok=args.partial_ok)
    if not wrote:
        if outcome == sc.PARTIAL:
            print(f"\nSCAN PARTIAL — coverage {round(proof['coverage'] * 100)}%: {inv_succeeded + pulls_ok}/{inv_attempted + len(items)} channels ok, {pulls_ok} items seen. Preserved last-known-good dashboard/state.json; parked the partial at dashboard/state.partial.json. Re-run (paced) or pass --allow-partial to accept it. Logged one ops-channel partial_preserved record.", file=sys.stderr)
        else:
            print(f'\nSCAN BLOCKED — zero visibility: {inv_succeeded + pulls_ok}/{inv_attempted + len(items)} channels ok, {pulls_ok} items seen. Preserved last-known-good dashboard/state.json; did NOT overwrite with a false-clean board. Logged one ops-channel blocked_no_visibility record.', file=sys.stderr)
        sys.exit(3)
    (OUT_DIR / 'DASHBOARD.md').write_text(render(rows, generated))
    open_n = sum((1 for r in rows if r['state'] == 'OPEN'))
    owe_n = sum((1 for r in rows if r['state'] == 'OPEN' and r['we_owe']))
    attn_n = sum((1 for r in rows if r['state'] == 'OPEN' and r.get('needs_attention')))
    print(f"\nwrote dashboard/DASHBOARD.md + state.json — {len(rows)} items, {open_n} open, {owe_n} we-owe, {attn_n} needs-attention (red) · coverage {round(proof['coverage'] * 100)}% ({outcome})")
if __name__ == '__main__':
    main()
