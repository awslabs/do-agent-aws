#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""issues spoke - one read-only cycle (loop.sh runs it; charter.md beside this file).

Reads the open pull requests and issues in scope through gh, which loop.sh resolves to the read-only front (the vendored
issues tracker's scripts/gh-ro when /opt/issues-tracker carries it, else gh-ro.sh beside this file), and writes, in the
spoke's working directory only: status.json and STATUS.md (conflicting pull requests, failing checks, changes requested,
what needs a reply, the staged drafts), state.json (the sets of the last complete scan), notices.jsonl (one record per
change of those sets, which the supervisor hands to agent), last-cycle and one cycle.log line. With the vendored tree and
no repository named, its gh-dashboard.py does the scan of the login's own items (its own output directory moved to
dashboard/ here); with repositories named, or without the tree, this file does.
It answers agent's bus requests it has the data for (which pull requests conflict, what needs a reply, what is staged,
the summary) and leaves every other request open for the session. It never writes to GitHub: post.sh is the only path.

A read that fails, is refused or answers with nothing makes the scan PARTIAL: status.json keeps the last complete scan,
the partial one is parked in status.partial.json, STATUS.md says so, and the cycle exits 1 - never "nothing new".
"""
import glob, hashlib, importlib.util, json, os, re, subprocess, sys, time
from datetime import datetime, timezone

WD = os.environ["ISSUES_SPOKE_WD"]
TREE = os.environ.get("ISSUES_TRACKER_DIR", "/opt/issues-tracker")
BUS = os.environ.get("ISSUES_SPOKE_BUS", "/agent/bus.sh")
FRONT = os.environ.get("ISSUES_SPOKE_FRONT", "gh-ro.sh")
PACE = float(os.environ.get("ISSUES_SPOKE_PACE_SEC", "1.0"))
BACKOFF = float(os.environ.get("ISSUES_SPOKE_BACKOFF_SEC", "300"))
NOW = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
OUTBOX = os.path.join(WD, "outbox")
SHA_RX = re.compile(r"\b[0-9a-f]{64}\b")
calls = {"n": 0}
errors = []


def settings():
    """settings.json in the working directory (the shipped example is settings.example.json beside this file) and
    ISSUES_REPOS (owner/name words, spaces or commas); with no repository named, the login's own items"""
    s = {}
    p = os.path.join(WD, "settings.json")
    if os.path.exists(p):
        try:
            s = json.load(open(p))
        except ValueError as e:
            errors.append(f"settings.json is not JSON ({e}); the defaults apply")
            s = {}
    repos = [r for r in s.get("repositories") or [] if isinstance(r, str)]
    repos += [r for r in re.split(r"[\s,]+", os.environ.get("ISSUES_REPOS", "")) if r]
    bad = [r for r in repos if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9._-]+", r)]
    for r in bad:
        errors.append(f"'{r}' is not owner/name; skipped")
    repos = [r for r in dict.fromkeys(repos) if r not in bad]
    mine = s.get("authored_by_me")
    mine = (not repos) if mine is None else bool(mine)
    bots = {b.lower() for b in s.get("bots") or [] if isinstance(b, str)}
    return {"repositories": repos, "authored_by_me": mine, "bots": bots,
            "max_items": int(s.get("max_items") or os.environ.get("ISSUES_SPOKE_MAX_ITEMS") or 30)}


def gh(*args, want_json=True):
    """one read through the front (gh on PATH is the front's shim); paced, one backoff on a rate limit; None on failure"""
    for attempt in (1, 2):
        if calls["n"]:
            time.sleep(PACE)
        calls["n"] += 1
        r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120)
        if r.returncode == 0 and r.stdout.strip():
            if not want_json:
                return r.stdout
            try:
                return json.loads(r.stdout)
            except ValueError:
                pass
        limited = re.search(r"HTTP 403|HTTP 429|rate limit", r.stderr or "", re.I)
        if attempt == 1 and limited:
            time.sleep(BACKOFF)
            continue
        why = "refused by the read-only front" if r.returncode in (2, 3) else (
            "answered with nothing" if r.returncode == 0 else f"failed (rc {r.returncode})")
        errors.append(f"gh {' '.join(args[:4])} {why}: {(r.stderr or '').strip().splitlines()[-1:] or ''}")
        return None
    return None


def jsonl_lines(text):
    out = []
    for line in (text or "").splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def is_bot(login, bots):
    l = (login or "").lower()
    return not l or l.endswith("[bot]") or l.startswith("app/") or l in bots


RED = ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE")   # ACTION_REQUIRED is a gate, not red


def classify(kind, repo, d, me, bots, inline=None):
    """one row from a gh view; the issues tracker's own rules: a reply is owed when the last human word is not ours,
    and a pull request's health comes from its state, whoever spoke last"""
    author = (d.get("author") or {}).get("login") or ""
    words = [((c.get("author") or {}).get("login"), c.get("createdAt") or "") for c in d.get("comments") or []]
    words += [((r.get("author") or {}).get("login"), r.get("submittedAt") or "") for r in d.get("latestReviews") or []
              if r.get("state") != "PENDING"]
    words += [(c.get("u"), c.get("t") or "") for c in inline or []]
    words = sorted((t, w) for w, t in words if t and not is_bot(w, bots))
    last_we = max((t for t, w in words if w == me), default="")
    them = [(t, w) for t, w in words if w != me]
    last_them = {"t": them[-1][0], "who": them[-1][1]} if them else None
    we_owe = bool(last_them and last_them["t"] > last_we) or (not words and author != me and author != "")
    row = {"repo": repo, "number": d.get("number"), "type": "PR" if kind == "pr" else "ISS", "title": d.get("title") or "",
           "url": d.get("url") or "", "state": d.get("state") or "OPEN", "author": author, "is_ours": author == me,
           "is_draft": bool(d.get("isDraft")), "updated": (d.get("updatedAt") or "")[:10], "we_owe": we_owe,
           "last_them": last_them, "merge_state": None, "mergeable": None, "review_decision": None, "ci_failures": None,
           "conflicting": False, "needs_attention": False, "attn_reasons": [], "bucket": None}
    if kind != "pr":
        return row
    fails = []
    for c in d.get("statusCheckRollup") or []:
        concl = c.get("conclusion") or c.get("state")
        if concl in RED:
            fails.append({"name": c.get("name") or c.get("context"), "conclusion": concl})
    merge, review = d.get("mergeStateStatus"), d.get("reviewDecision")
    row.update(merge_state=merge, mergeable=d.get("mergeable"), review_decision=review, ci_failures=fails or None,
               conflicting=merge == "DIRTY" or d.get("mergeable") == "CONFLICTING")
    if row["is_ours"] and not row["is_draft"]:
        if review == "APPROVED" and (row["conflicting"] or merge == "BEHIND"):
            row["attn_reasons"].append("approved but unmergeable: rebase to land")
            row["bucket"] = "A-approved-stale"
        if row["conflicting"]:
            row["attn_reasons"].append("merge conflict (needs a rebase)")
            row["bucket"] = row["bucket"] or "D-conflict"
        if fails:
            row["attn_reasons"].append(f"checks failing ({len(fails)})")
            row["bucket"] = row["bucket"] or "C-red-ci"
        if review == "CHANGES_REQUESTED":
            row["attn_reasons"].append("changes requested")
            row["bucket"] = row["bucket"] or "B-changes-requested"
        row["needs_attention"] = bool(row["attn_reasons"])
    return row


PR_FIELDS = "number,title,url,state,author,isDraft,updatedAt,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,comments,latestReviews"
ISSUE_FIELDS = "number,title,url,state,author,updatedAt,comments"


def own_scan(cfg):
    """the spoke's own read-only scan: the repositories' open items and, by default, the login's own; one view each"""
    who = os.environ.get("ISSUES_GH_LOGIN") or gh("api", "user", "--jq", ".login", want_json=False)
    me = (who or "").strip()
    if not me:
        return None, "", ["the login could not be read (gh api user)"]
    n = str(cfg["max_items"])
    items = {}
    for repo in cfg["repositories"]:
        for kind in ("pr", "issue"):
            got = gh(kind, "list", "--repo", repo, "--state", "open", "--limit", n, "--json", "number")
            for x in got if isinstance(got, list) else []:
                items[(repo, int(x["number"]))] = kind
    if cfg["authored_by_me"]:
        for kind, what in (("pr", "prs"), ("issue", "issues")):
            for role in ("--author", "--commenter"):
                got = gh("search", what, role, "@me", "--state", "open", "--limit", n, "--json", "repository,number")
                for x in got if isinstance(got, list) else []:
                    items[((x.get("repository") or {}).get("nameWithOwner"), int(x["number"]))] = kind
    rows = []
    for (repo, num), kind in sorted(items.items(), key=lambda kv: (str(kv[0][0]), kv[0][1])):
        if not repo:
            continue
        d = gh(kind, "view", str(num), "--repo", repo, "--json", PR_FIELDS if kind == "pr" else ISSUE_FIELDS)
        if not isinstance(d, dict):
            continue
        inline = None
        if kind == "pr":
            # the third channel: inline review comments, the last one counts
            # (one array per page, "[]" for none: a read that answers with nothing stays an error)
            out = gh("api", f"repos/{repo}/pulls/{num}/comments?per_page=100", "--paginate",
                     "--jq", "[.[] | {u: .user.login, t: .created_at}]", want_json=False)
            inline = [c for page in jsonl_lines(out) if isinstance(page, list) for c in page]
        rows.append(classify(kind, repo, d, me, cfg["bots"], inline))
    return rows, me, []


def vendored_scan(cfg):
    """the vendored issues tracker's own scan, unedited: its gh-dashboard.py --open-only, with its output directory
    moved from the tree to dashboard/ here; its rows as it writes them (status: its exit code, 3 = blocked or partial)"""
    script = os.path.join(TREE, "scripts", "gh-dashboard.py")
    out_dir = os.path.join(WD, "dashboard")
    os.makedirs(out_dir, exist_ok=True)
    code = ("import importlib.util, pathlib, sys\n"
            f"spec = importlib.util.spec_from_file_location('gh_dashboard', {script!r})\n"
            "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
            f"m.OUT_DIR = pathlib.Path({out_dir!r})\n"
            "sys.argv = ['gh-dashboard.py', '--open-only']\n"
            "m.main()\n")
    env = dict(os.environ, DASH_PACE_SEC=os.environ.get("ISSUES_SPOKE_PACE_SEC", "1.0"))
    if os.environ.get("ISSUES_SPOKE_BACKOFF_SEC"):
        env["DASH_BACKOFF_SEC"] = os.environ["ISSUES_SPOKE_BACKOFF_SEC"]
    # -B: no bytecode cache written into the vendored tree (the spoke writes only its working directory)
    try:
        r = subprocess.run([sys.executable, "-I", "-B", "-c", code], capture_output=True, text=True, timeout=840, env=env, cwd=WD)  # nosemgrep: dangerous-subprocess-use-audit, dangerous-subprocess-use-tainted-env-args -- sys.executable runs a fixed program (paths embedded with repr()); env is operator settings; no shell
    except subprocess.TimeoutExpired:
        return None, "", ["the vendored scan ran out of time (840 s)"]
    tail = " ".join((r.stderr or r.stdout or "").strip().splitlines()[-2:])
    if r.returncode != 0:
        return None, "", [f"the vendored scan exited {r.returncode}: {tail}"]
    try:
        doc = json.load(open(os.path.join(out_dir, "state.json")))
    except (OSError, ValueError) as e:
        return None, "", [f"the vendored scan wrote no readable state.json ({e})"]
    rows = []
    for x in doc.get("items") or []:
        if x.get("state") != "OPEN":
            continue
        kind = "pull" if x.get("type") == "PR" else "issues"
        x = dict(x, url=f"https://github.com/{x.get('repo')}/{kind}/{x.get('number')}",
                 conflicting=x.get("merge_state") in ("DIRTY", "CONFLICTING"))
        rows.append(x)
    return rows, os.environ.get("ISSUES_GH_LOGIN", ""), []


def outbox():
    """the staged drafts: <owner>.<name>-<number>.md, with the record, the person's GO and the post record beside it"""
    out = []
    for p in sorted(glob.glob(os.path.join(OUTBOX, "*.md"))):
        base = os.path.basename(p)[:-3]
        if base.endswith(".FILING-READY"):
            continue
        m = re.fullmatch(r"([A-Za-z0-9-]+)\.([A-Za-z0-9._-]+)-([0-9]+)", base)
        sha = hashlib.sha256(open(p, "rb").read()).hexdigest()
        go = os.path.join(OUTBOX, base + ".GO")
        named = SHA_RX.findall(open(go, errors="replace").read()) if os.path.isfile(go) else []
        posted = os.path.isfile(os.path.join(OUTBOX, base + ".POSTED"))
        out.append({"name": base, "target": f"{m.group(1)}/{m.group(2)}#{m.group(3)}" if m else None, "sha256": sha,
                    "record": os.path.isfile(os.path.join(OUTBOX, base + ".FILING-READY.md")),
                    "go": "none" if not os.path.isfile(go) else ("matches" if sha in named else "names another sha256"),
                    "posted": posted})
    return out


def key(r):
    return f"{r['repo']}#{r['number']}"


def sets(rows):
    return {"conflicting": sorted(key(r) for r in rows if r.get("conflicting")),
            "checks_failing": sorted(key(r) for r in rows if r.get("ci_failures")),
            "changes_requested": sorted(key(r) for r in rows if r.get("review_decision") == "CHANGES_REQUESTED"),
            "needs_reply": sorted(key(r) for r in rows if r.get("we_owe"))}


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


TITLES = {"conflicting": "Conflicting pull requests", "checks_failing": "Failing checks",
          "changes_requested": "Changes requested", "needs_reply": "Needs a reply"}
TEXT = {"conflicting": "is conflicting (needs a rebase)", "checks_failing": "has failing checks",
        "changes_requested": "has changes requested", "needs_reply": "needs a reply"}
LEFT = {"conflicting": "is no longer conflicting", "checks_failing": "has no failing check now",
        "changes_requested": "has no changes requested now", "needs_reply": "no longer needs a reply"}


def status_md(doc, partial_why):
    rows = {key(r): r for r in doc["items"]}
    s = doc["sets"]
    md = [f"# issues spoke STATUS - {NOW}", ""]
    if partial_why:
        md += [f"**This cycle's scan failed ({partial_why}). The rows below are the last complete scan, of "
               f"{doc['generated_utc']}; the partial one is in status.partial.json.**", ""]
    md += [f"Read-only triage. Source: {doc['source']}. Scope: " + (", ".join(doc["scope"]["repositories"]) or "no repository")
           + ("; the login's own open items" if doc["scope"]["authored_by_me"] else "") + f". Login: {doc['login'] or 'unknown'}.",
           "", f"{len(rows)} open items. " + ". ".join(f"{TITLES[k]}: {len(v)}" for k, v in s.items())
           + f". Staged drafts: {len(doc['staged'])}.", ""]
    for k, title in TITLES.items():
        md += [f"## {title} ({len(s[k])})", ""]
        if not s[k]:
            md += ["- none", ""]
            continue
        md += ["| item | title | ours | why | updated |", "|---|---|---|---|---|"]
        for kk in s[k]:
            r = rows[kk]
            why = {"conflicting": r.get("merge_state") or r.get("mergeable") or "",
                   "checks_failing": ", ".join(f"{c['name']} {c['conclusion']}" for c in r.get("ci_failures") or [])[:120],
                   "changes_requested": r.get("review_decision") or "",
                   "needs_reply": (f"last word by {r['last_them']['who']} at {r['last_them']['t']}" if r.get("last_them")
                                   else "nobody but its author has written on it")}[k]
            md.append(f"| [{kk}]({r.get('url')}) | {(r.get('title') or '').replace('|', '/')[:70]} | "
                      f"{'yes' if r.get('is_ours') else ''} | {why} | {r.get('updated') or ''} |")
        md.append("")
    md += [f"## Staged drafts ({len(doc['staged'])})", ""]
    md += [f"- {d['name']}: {d['target'] or 'not a target name'}, sha256 {d['sha256'][:12]}, record "
           f"{'yes' if d['record'] else 'missing'}, GO {d['go']}{', POSTED' if d['posted'] else ''}" for d in doc["staged"]] or ["- none"]
    md += [""]
    if doc["errors"]:
        md += ["## Errors this cycle", ""] + [f"- {e}" for e in doc["errors"]] + [""]
    md += ["---", "Written by loop.sh: GitHub reads only, through the read-only front. Nothing posts from here: a draft "
           "leaves only through post.sh, after a person's GO naming its sha256.", ""]
    return "\n".join(md)


def notices(prev, cur, rows):
    """transitions only; the first cycle sends one summary; at most 8 a cycle, then a count"""
    path = os.path.join(WD, "notices.jsonl")
    out = []
    if prev is None:
        out.append("issues: first scan - " + ", ".join(f"{len(v)} {TITLES[k].lower()}" for k, v in cur.items())
                   + f" (STATUS.md in {WD})")
    else:
        for k in TITLES:
            for kk in cur[k]:
                if kk not in prev.get(k, []):
                    t = (rows.get(kk) or {}).get("title", "")[:80]
                    out.append(f"{kk} {TEXT[k]}: {t}")
            for kk in prev.get(k, []):
                if kk not in cur[k]:
                    out.append(f"{kk} {LEFT[k]}")
    if len(out) > 8:
        out = out[:8] + [f"and {len(out) - 8} more changes (STATUS.md in {WD})"]
    with open(path, "a") as f:
        for t in out:
            f.write(json.dumps({"ts": NOW, "kind": "notice", "text": t}) + "\n")
    return len(out)


def answer(doc):
    """agent's open requests this cycle has the data for; any other request stays open for the session"""
    if not os.environ.get("BUS_AGENT_ID"):
        return "bus: skipped (no BUS_AGENT_ID: not run by the supervisor)"
    if not os.access(BUS, os.X_OK):
        errors.append(f"no bus helper at {BUS}")
        return "bus: no helper"
    r = subprocess.run([BUS, "poll", "--kind", "request"], capture_output=True, text=True)  # nosemgrep: dangerous-subprocess-use-audit, dangerous-subprocess-use-tainted-env-args -- argv list run without a shell; the environment values are operator settings, each passed as one argv word
    if r.returncode != 0:
        errors.append(f"bus poll failed: {r.stderr.strip()[-200:]}")
        return "bus: poll failed"
    rows = {key(x): x for x in doc["items"]}
    answered = 0
    for mid in r.stdout.split():
        p = subprocess.run([BUS, "peek", mid], capture_output=True, text=True)  # nosemgrep: dangerous-subprocess-use-audit, dangerous-subprocess-use-tainted-env-args -- argv list run without a shell; the environment values are operator settings, each passed as one argv word
        try:
            q = json.loads(p.stdout)["text"].lower()
        except (ValueError, KeyError, TypeError):
            continue
        if "conflict" in q:
            what, ks = "conflicting pull requests", doc["sets"]["conflicting"]
        elif re.search(r"\b(repl|respon|owe|owed|answer)", q):
            what, ks = "items that need a reply", doc["sets"]["needs_reply"]
        elif re.search(r"\b(stag|draft|outbox)", q):
            what, ks = "staged drafts", [f"{d['name']} (GO {d['go']}{', posted' if d['posted'] else ''})" for d in doc["staged"]]
        elif re.search(r"\b(status|summary|overview|changed|failing|checks)\b", q):
            what, ks = "the summary", [f"{len(v)} {TITLES[k].lower()}" for k, v in doc["sets"].items()]
        else:
            continue
        lines = []
        for kk in ks:
            r0 = rows.get(kk)
            lines.append(f"{kk} {(r0.get('title') or '')[:60]}" if r0 else kk)
        head = f"{what} as of the scan of {doc['generated_utc']} ({doc['source']}): {len(ks)}"
        text, shown = head, 0
        for l in lines:
            if len((text + "; " + l).encode()) > 1200:
                break
            text += ("; " if shown else ": ") + l
            shown += 1
        if shown < len(lines):
            text += f"; and {len(lines) - shown} more in {WD}/STATUS.md"
        s = subprocess.run([BUS, "reply", mid], input=text, capture_output=True, text=True)  # nosemgrep: dangerous-subprocess-use-audit, dangerous-subprocess-use-tainted-env-args -- argv list run without a shell; the environment values are operator settings, each passed as one argv word
        if s.returncode != 0:
            errors.append(f"bus reply to {mid} failed: {s.stderr.strip()[-200:]}")
        else:
            answered += 1
    return f"bus: {answered} answered"


def main():
    cfg = settings()
    os.makedirs(OUTBOX, exist_ok=True)
    # the vendored scan inventories the login's own open items, not a repository's: repositories named in settings.json
    # or ISSUES_REPOS are read by this file's scan, so the scope STATUS.md names is the scope that was read
    tree = os.path.isfile(os.path.join(TREE, "scripts", "gh-dashboard.py")) and os.path.isfile(os.path.join(TREE, "scripts", "gh-ro"))
    vendored = tree and not cfg["repositories"]
    source = f"the vendored issues tracker ({TREE})" if vendored else "the spoke's own scan"
    rows, me, fail = vendored_scan(cfg) if vendored else own_scan(cfg)
    fail = fail or ([e for e in errors if e.startswith("gh ")] and ["a read failed, was refused or answered with nothing"]) or []
    status_p, state_p = os.path.join(WD, "status.json"), os.path.join(WD, "state.json")
    staged = outbox()
    try:
        prev = json.load(open(state_p))
    except (OSError, ValueError):
        prev = None
    if rows is not None and not fail:
        doc = {"generated_utc": NOW, "source": source, "login": me, "scope": {k: cfg[k] for k in ("repositories", "authored_by_me")},
               "items": rows, "sets": sets(rows), "staged": staged, "errors": list(errors), "complete": True}
        write(status_p, json.dumps(doc, indent=1, sort_keys=True) + "\n")
        sent = notices(prev.get("sets") if isinstance(prev, dict) else None, doc["sets"], {key(r): r for r in rows})
        write(state_p, json.dumps({"ts": NOW, "sets": doc["sets"]}, sort_keys=True) + "\n")
        why = ""
    else:
        why = "; ".join(fail or ["no rows"])
        write(os.path.join(WD, "status.partial.json"), json.dumps({"ts": NOW, "source": source, "items": rows or [],
                                                                   "errors": list(errors) + fail}, indent=1) + "\n")
        try:
            doc = json.load(open(status_p))
        except (OSError, ValueError):
            doc = {"generated_utc": "never", "source": source, "login": me, "scope": {k: cfg[k] for k in ("repositories", "authored_by_me")},
                   "items": [], "sets": sets([]), "complete": False}
        doc["staged"], doc["errors"] = staged, list(errors) + fail
        sent = 0
    write(os.path.join(WD, "STATUS.md"), status_md(doc, why))
    bus = answer(doc)
    line = (f"{NOW} source={'vendored' if vendored else 'own'} complete={'no' if why else 'yes'} items={len(doc['items'])} "
            + " ".join(f"{k}={len(v)}" for k, v in doc["sets"].items()) + f" staged={len(staged)} gh_calls={calls['n']} notices={sent} {bus}")
    with open(os.path.join(WD, "cycle.log"), "a") as f:
        f.write(line + (f" FAILED: {why}" if why else "") + "\n")
    print(line)
    for e in errors + (fail if why else []):
        print("error:", e)
    if why:
        sys.exit(1)
    write(os.path.join(WD, "last-cycle"), NOW + "\n")


if __name__ == "__main__":
    main()
