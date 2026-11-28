#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""plane-sync.py - mirror the autonomy loop's goals and fires as work items on the self-hosted Plane board.

/agent/loop.sh and /agent/loop-once.sh call it around every fire while the board runs on this target (PLANE_URL, set
by run.sh; docs/manual/boards.md "Plane board"). Each call is best effort: the loop bounds it with a timeout and only logs a
failure, so a board outage never fails, blocks or changes a fire. It can also be run by hand:

  plane-sync.py sync           one work item per goal; a checked goal moves to Done, every other one keeps its state
                               (a new one starts in Todo, a Cancelled one comes back to it)
  plane-sync.py seed [--done FILE]
                               the board's first view, run in the background by /agent/ui-start.sh at container
                               start, before any fire: the same as sync once the board answers, tried again every 2s
                               for up to PLANE_SEED_WAIT seconds while it does not (its sidecars can still be
                               starting); a refused API key or a bad setting ends it at once. --done FILE: FILE is
                               removed when it starts and holds its exit status when it ends (once the seed ended, its
                               pid tells nothing: an init that does not reap keeps it as a zombie)
  plane-sync.py fire-start --fire N [--goal-key KEY]
                               the same, and the goal this fire works on moves to In Progress, the other open goals
                               to Todo - except the goals of the other fires still running, which stay In Progress.
                               KEY names the goal by its key (supervisor mode: loop.sh passes each worker's first
                               goal); without it the goal is the first open one in file order (a serial fire)
  plane-sync.py fire-end --fire N --rc RC --duration SECONDS [--out FILE]
                               that goal moves to Done when the fire checked it off, else to In Review; the fire's
                               result (rc, duration, the end of its transcript FILE) becomes a comment on its work
                               item, and a one-line "Last fire" note in its description (kept until its next fire);
                               both are masked first (redact: the secrets file's, the environment's and the AWS
                               files' secret values, token shapes, AWS credential forms, bearer tokens)

Goals are read from the file the loop fires on (AUTONOMY_LOOP_GOALS, default /wd/goals/GOALS.md), and while it does
not exist from the shipped default goals the loop fires on then (AUTONOMY_LOOP_DEFAULT_GOALS, default
/agent/goals-default.md: one standing goal, the Slack inbox), so a new instance's board shows that goal from the start.
Once the goals file exists, the work items of the default goals that are not in it move to Cancelled; a fire on the
default goals that created the goals file posts its result on the default goal's work item. Two forms are goals:
  - a checkbox item "- [ ] <goal>" (the form /agent/goals-add.sh writes), done when checked "- [x] <goal>";
  - a "## Goal ..." heading (the form of docs/loop/GOALS.md.example; "## Standing goal ..." in the default goals),
    done when its heading carries "[x]".
The goal a fire works on is the first open goal in file order (a fire completes "the single smallest unfinished
increment" and goals are worked top down), or the goal fire-start's --goal-key names (the supervisor mode of loop.sh,
where several workers fire at once, each on its own goal group); fire-start records it so fire-end moves the same work
item: the state file keeps one record per running fire (fires: {"<fire>": {goal, started, requested}}, written at
fire-start, removed at fire-end, read by fire number) beside the single fire/started/goal of the latest start that
older readers know. The goals of the other fires still running stay In Progress through a fire-start or fire-end.
A work item is
keyed by external_source "do-agent-aws" and external_id uuidv5(project id, the goal's key), Plane's own integration
keys, so a re-run (every start's seed among them) updates the same items and never duplicates them. The key is the
goal text without its checkbox and without the parenthesised note a fire prefixes when it checks the goal off
("(done 2026-10-30, evidence ...) Fix X": goal_key), so a completion note keeps the item too. A goal without an item
adopts the item of its earlier text when one is on the board (same_goal: the text cut at 250 characters, the board's
title length, or renamed before this rule) - the oldest, remembered as an alias in the state file - and the other items
of a checked goal move to Done with it, so every item of a done goal is Done. The mirror is one-way: the goals file
wins, and a work item moved by hand moves back on the next fire. A goal deleted from the file keeps its item.

Settings (environment):
  PLANE_URL        the Plane proxy (run.sh: http://plane-proxy:80); only loopback or a single-label docker network
                   name is accepted - the API key never leaves the host
  PLANE_AUTH_FILE  the board's secrets file (default /wd/plane/plane.env; PLANE_API_KEY, sent as X-Api-Key)
  PLANE_WORKSPACE  the workspace slug (default do-agent-aws); PLANE_PROJECT the project identifier (default AGENT),
                   which ./plane.sh seed creates on every ./run.sh
  PLANE_SEED_WAIT  how long seed waits for the board, in seconds (default 300)
  PLANE_429_RETRIES, PLANE_429_MAX_WAIT, PLANE_429_BUDGET
                   a rate-limited call (HTTP 429) is retried up to PLANE_429_RETRIES times (default 4), each after the
                   board's Retry-After or else 1, 2, 4, ... s with jitter, at most PLANE_429_MAX_WAIT s (default 10);
                   one run sleeps at most PLANE_429_BUDGET s in all (default 20, below the loop's 30 s
                   PLANE_SYNC_TIMEOUT), then exits 2 naming the 429
  AUTONOMY_LOOP_GOALS, AUTONOMY_LOOP_DEFAULT_GOALS, AUTONOMY_LOOP_DIR (default /wd/loop: the state file
                   plane-sync.state)

Prints one summary line on stdout. Never prints the API key. Exit status: 0 mirrored (or nothing to mirror: neither
goals file exists), 2 board unreachable (for seed: still, after PLANE_SEED_WAIT) or an API error, 3 the API key is
refused, 4 bad settings.

The goal rules and the command contract are those of the vibe-kanban board mirror (kanban-sync.py), so either board shows the same thing. The REST calls are Plane v1.4.2's /api/v1 (checked
against apps/api/plane/api/views): a POST of a work item or comment whose external id exists answers 409 with its id,
PATCH updates it, a state POST needs a color.
"""
import argparse
import email.utils
import html
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

# A fixed namespace keeps the ids stable across runs, containers and hosts: it is the one every Plane project this harness
# has written uses, so existing projects keep their ids
NS = uuid.UUID("366aee7f-ddd7-553e-bfe4-c74f14bbb106")
SOURCE = "do-agent-aws"

TODO, IN_PROGRESS, IN_REVIEW, DONE = "Todo", "In Progress", "In Review", "Done"
CANCELLED = "Cancelled"  # a default state of every Plane project: where the default goals' work items go
# The default states of a Plane project; In Review (group started, between In Progress and Done) is added once
NEW_STATES = {IN_REVIEW: {"group": "started", "color": "#8B5CF6", "sequence": 40000}}
RESULT_TAIL = 1500


def _env_num(name, default):
    try:
        return max(0.0, float(os.environ.get(name) or default))
    except ValueError:
        return float(default)


# A 429 (the board's rate limit) is retried with backoff (Board._backoff); the whole process stays inside the loop's
# PLANE_SYNC_TIMEOUT (30 s), so the waits of one run share RATE_BUDGET seconds
RATE_RETRIES = int(_env_num("PLANE_429_RETRIES", 4))
RATE_MAX_WAIT = _env_num("PLANE_429_MAX_WAIT", 10)
RATE_BUDGET = _env_num("PLANE_429_BUDGET", 20)
# A fire's transcript can print anything the agent saw; its first line (the "Last fire" note, in the description and
# the state file) and its end (the comment) go on the board masked (redact). The same rules as the vibe-kanban mirror
# (kanban-sync.py)
SECRET_NAME = re.compile(r"TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE_KEY|API_?KEY|ACCESS_KEY|CREDENTIAL", re.I)
SECRET_SHAPES = re.compile(
    r"xox[abeoprs]-[A-Za-z0-9-]{8,}"  # Slack tokens
    r"|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"  # AWS access key ids
    r"|\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}"  # GitHub tokens
    r"|\bsk-[A-Za-z0-9_-]{20,}"  # OpenAI-style and Anthropic API keys
    r"|\bABSK[A-Za-z0-9+/=]{20,}"  # Bedrock API keys
    r"|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"  # JWTs (a board session, for one)
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S)
SECRET_ASSIGNMENT = re.compile(  # NAME=value or name: value - an upper-case secret-named setting, or the plain words
    r"\b((?:[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY)[A-Z0-9_]*|(?i:password|passwd|secret|token|api[_-]?key))"
    r"\s*[=:]\s*)(\S+)")
# AWS credentials as their files and the CLI print them (aws_secret_access_key = ..., "SecretAccessKey": "..." and
# any JSON string under a secret-named key), and a bearer token in an Authorization header
AWS_ASSIGNMENT = re.compile(r"(\baws_(?:secret_access_key|session_token)\s*[=:]\s*)\S+", re.I)
JSON_SECRET = re.compile(r'("[A-Za-z0-9_]*(?:secret|token|password|passwd|api_?key|private_?key|access_?key)'
                         r'[A-Za-z0-9_]*"\s*:\s*)"[^"]*"', re.I)
BEARER = re.compile(r"(\bBearer\s+)\S{20,}", re.I)
REDACTED = "[redacted]"
# Never through a proxy from the environment (http_proxy in .env is for the internet): the board is a sidecar, and
# the API key must not travel to a proxy
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """No redirect is followed: urllib would send X-Api-Key again to wherever Location points, another host
    included, past _assert_private. The board's API answers no 3xx, so one is an error (exit status 2)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


class SyncError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _assert_private(url):
    """The API key may only travel to this host or to a sidecar on the agent's docker network."""
    p = urllib.parse.urlparse(url)
    host = p.hostname or ""
    if p.scheme not in ("http", "https"):
        raise SyncError(4, f"PLANE_URL must be http(s)://host[:port], got scheme {p.scheme!r}")
    if host in ("127.0.0.1", "localhost", "::1") or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", host):
        return
    raise SyncError(4, f"refusing PLANE_URL host {host!r}: only loopback or a single-label docker network name "
                       "(the Plane proxy sidecar) is allowed")


class Board:
    def __init__(self, base, api_key, workspace):
        _assert_private(base)
        self.base = f"{base.rstrip('/')}/api/v1/workspaces/{workspace}"
        self.key = api_key
        self.waited = 0.0  # seconds slept on 429s by this process, against RATE_BUDGET

    def _backoff(self, attempt, retry_after):
        """Seconds to wait before retry number attempt (1, 2, ...) of a 429: the board's Retry-After (delta-seconds
        or an HTTP-date), else 1, 2, 4, ... s with jitter; each wait at most RATE_MAX_WAIT. None when RATE_RETRIES
        retries are spent or the wait would pass RATE_BUDGET (the loop's PLANE_SYNC_TIMEOUT, 30 s, kills the whole
        process, so the budget stays below it)."""
        if attempt > RATE_RETRIES:
            return None
        delay = None
        if retry_after:
            try:
                delay = float(retry_after)
            except ValueError:
                try:
                    delay = email.utils.parsedate_to_datetime(retry_after).timestamp() - time.time()
                except (TypeError, ValueError, IndexError, OverflowError):
                    delay = None
        if delay is None or delay != delay:  # absent, unparseable or nan: exponential backoff
            delay = (2 ** (attempt - 1)) * random.uniform(0.5, 1.0)
        delay = min(RATE_MAX_WAIT, max(0.0, delay))
        if self.waited + delay > RATE_BUDGET:
            return None
        return delay

    def call(self, method, path, body=None, ok=(200, 201, 204)):
        """(status, payload); a 429 is retried up to RATE_RETRIES times (_backoff)."""
        for attempt in range(1, RATE_RETRIES + 2):
            req = urllib.request.Request(self.base + path, method=method,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers={"X-Api-Key": self.key, "Content-Type": "application/json"})
            try:
                with OPENER.open(req, timeout=10) as r:
                    raw = r.read().decode()
                    code, payload = r.status, (json.loads(raw) if raw else None)
            except urllib.error.HTTPError as e:
                raw = e.read().decode() if e.fp else ""
                try:
                    payload = json.loads(raw) if raw else None
                except ValueError:
                    payload = raw[:200]
                code = e.code
                if code == 429:
                    delay = self._backoff(attempt, (e.headers.get("Retry-After") or "").strip())
                    if delay is not None:
                        time.sleep(delay)
                        self.waited += delay
                        continue
                    raise SyncError(2, f"{method} {path.split('?')[0]} -> 429 rate limited, still after "
                                       f"{attempt - 1} retr{'y' if attempt == 2 else 'ies'} and {self.waited:.1f}s "
                                       f"of backoff: {str(payload)[:200]}")
            except (urllib.error.URLError, OSError, ValueError) as e:
                raise SyncError(2, f"board unreachable at {self.base.split('/api/')[0]} ({e})")
            break
        if code in (401, 403):
            raise SyncError(3, f"the board refused the API key (HTTP {code}) - check PLANE_API_KEY in PLANE_AUTH_FILE")
        if 300 <= code < 400:
            raise SyncError(2, f"{method} {path.split('?')[0]} -> {code}: a redirect is never followed (the API key "
                               "stays with the board)")
        if code not in ok:
            raise SyncError(2, f"{method} {path.split('?')[0]} -> {code}: {str(payload)[:200]}")
        return code, payload

    def all(self, path):
        """Every row of a paginated list."""
        rows, cursor = [], None
        for _ in range(100):
            sep = "&" if "?" in path else "?"
            _, page = self.call("GET", f"{path}{sep}per_page=100" + (f"&cursor={cursor}" if cursor else ""))
            if isinstance(page, list):
                return page
            rows += page.get("results") or []
            if not page.get("next_page_results"):
                break
            cursor = page.get("next_cursor")
        return rows


# ------------------------------------------------------------------ goals (the rules of kanban-sync.py)
CHECKBOX = re.compile(r"^\s*[-*]\s+\[([ xX])\]\s+(\S.*?)\s*$")
HEADING = re.compile(r"^##\s+(\S.*?)\s*$")
DONE_MARK = re.compile(r"\[[xX]\]")

# ------------------------------------------------------------------ goal identity (the same rules as kanban-sync.py)
# A fire that checks a goal off may prefix its line with a parenthesised note - "(done 2026-10-30, evidence ...) Fix X" -
# and the goal is the same: its key, and so its work item, is the text without that note. same_goal() also pairs the
# forms older mirrors left behind: a text cut at 250 characters (the board's title length), a note appended, whitespace.
NOTE_MIN = 24  # characters: the shortest text the prefix rule of same_goal() trusts


def strip_note(text):
    """text without the leading parenthesised note(s) a fire prefixes at completion; an unbalanced note (a line cut
    inside it) or a text that is nothing but a note stays as it is."""
    t = (text or "").strip()
    while t.startswith("("):
        depth, end = 0, -1
        for i, ch in enumerate(t):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        rest = t[end + 1:].strip() if end >= 0 else ""
        if not rest:
            break
        t = rest
    return t


def _norm(text):
    return " ".join((text or "").split())


def same_goal(a, b):
    """Whether two goal texts name the same goal: equal once leading notes are stripped and whitespace normalised, or
    one of them (at least NOTE_MIN characters) is the start of the other (a text cut at 250 characters, a note appended)."""
    forms_a = {_norm(a), _norm(strip_note(a))} - {""}
    forms_b = {_norm(b), _norm(strip_note(b))} - {""}
    for x in forms_a:
        for y in forms_b:
            if x == y:
                return True
            short, long_ = (x, y) if len(x) <= len(y) else (y, x)
            if len(short) >= NOTE_MIN and long_.startswith(short):
                return True
    return False


def goal_key(text):
    """The key of a goal text: the text without its leading note (strip_note)."""
    return strip_note(text)


def card_title(text):
    """The name the mirror writes for a goal's work item: its first 250 characters (the board's title length)."""
    return (text or "")[:250]


def parse_goals(path):
    """[{key, title, done, body}] in file order; code fences are skipped."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return None
    goals, seen, fence, heading_goal = [], {}, False, None
    for line in lines:
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        m = CHECKBOX.match(line)
        if m:
            goals.append({"text": m.group(2), "done": m.group(1) in "xX", "body": m.group(2)})
            continue
        m = HEADING.match(line)
        if m:
            heading_goal = None
            text = " ".join(DONE_MARK.sub("", m.group(1)).split())
            # "Goal 1 - ..." and the default goals' "Standing goal - ...", not the section "Goals from Slack"
            if re.match(r"(standing\s+)?goal\b", text, re.I):
                heading_goal = {"text": text, "done": bool(DONE_MARK.search(m.group(1))), "body": text, "lines": []}
                goals.append(heading_goal)
            continue
        if heading_goal is not None and line.strip():
            heading_goal["lines"].append(line.strip())
    for g in goals:
        if g.get("lines"):
            g["body"] = "\n".join(g.pop("lines"))[:2000]
        g.pop("lines", None)
        # the key is the goal text without the note a fire prefixes at completion (goal_key); a repeated text gets its
        # occurrence number
        base = goal_key(g["text"])
        n = seen[base] = seen.get(base, 0) + 1
        g["key"] = base if n == 1 else f"{base}#{n}"
        g["title"] = card_title(g["text"])
    return goals


def first_open(goals):
    return next((g for g in goals if not g["done"]), None)


def pick_goal(goals, goal_key=None):
    """(goal, note): the goal a fire works on - the one with this key (fire-start --goal-key: the supervisor mode of
    loop.sh names each worker's first goal; a line renamed meanwhile, a note prefixed, is found by same_goal), else the
    first open goal in file order (a serial fire, the rule so far). A key that is not in the file gives (None, note):
    nothing is moved for that fire, and never another fire's goal."""
    if not goal_key:
        return first_open(goals), ""
    goal = next((g for g in goals if g["key"] == goal_key), None)
    if goal is None:
        goal = next((g for g in goals if same_goal(goal_key, g["text"])), None)
    if goal is None:
        return None, f"--goal-key '{_short(goal_key, 60)}' is not in the goals file: no work item is moved for this fire"
    return goal, ""


# the per-fire records of the state file (supervisor mode, several fires at once): state["fires"] = {"<fire>": {"goal":
# key or None, "started": epoch, "requested": the --goal-key or None}}, written at fire-start and removed at fire-end;
# a record a killed loop left behind leaves after FIRES_TTL seconds, and only the newest FIRES_MAX records are kept
FIRES_TTL = 48 * 3600
FIRES_MAX = 20


def prune_fires(fires, now=None):
    """The records of state["fires"] still worth keeping (a dict copy)."""
    now = time.time() if now is None else now
    kept = {str(n): r for n, r in (fires or {}).items()
            if isinstance(r, dict) and isinstance(r.get("started"), (int, float)) and now - r["started"] < FIRES_TTL}
    if len(kept) > FIRES_MAX:
        for n in sorted(kept, key=lambda x: int(x) if x.isdigit() else -1)[:len(kept) - FIRES_MAX]:
            kept.pop(n)
    return kept


def running_goals(state, except_fire=None):
    """The goal keys of the other fires still running (state["fires"] without this fire's record): mirror() keeps their
    work items In Progress while this fire starts or ends."""
    return {r.get("goal") for n, r in (state.get("fires") or {}).items()
            if isinstance(r, dict) and r.get("goal") and str(n) != str(except_fire)}


# ------------------------------------------------------------------ state
def _state_path(loop_dir):
    return os.path.join(loop_dir, "plane-sync.state")


def read_state(loop_dir):
    try:
        with open(_state_path(loop_dir)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def write_state(loop_dir, state):
    try:
        os.makedirs(loop_dir, exist_ok=True)
        tmp = _state_path(loop_dir) + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, _state_path(loop_dir))
    except OSError as e:
        print(f"plane-sync: cannot write the state file: {e}", file=sys.stderr)


# ------------------------------------------------------------------ mirror
def load_key(path):
    vals = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    vals[k.strip()] = v.strip()
    except OSError:
        raise SyncError(4, f"the board's secrets file {path} is missing (./plane.sh creates it on the host at ./run.sh)")
    if not vals.get("PLANE_API_KEY"):
        raise SyncError(4, f"{path} lacks PLANE_API_KEY")
    return vals["PLANE_API_KEY"]


def _html(text):
    return "".join(f"<p>{html.escape(line)}</p>" for line in text.splitlines() if line.strip()) or "<p></p>"


def _same_html(current, ours):
    """Plane stores a description wrapped in one <div>; compare without it and without whitespace."""
    cur = re.sub(r"^<div>(.*)</div>$", r"\1", (current or "").strip(), flags=re.S)
    return re.sub(r"\s+", "", cur) == re.sub(r"\s+", "", ours)


def _first_paragraph(description_html):
    """The text of a work item description's first paragraph: the goal's line, as the mirror wrote it (_html)."""
    m = re.search(r"<p[^>]*>(.*?)</p>", description_html or "", re.S)
    return html.unescape(re.sub(r"<[^>]+>", "", m.group(1))) if m else ""


def _created(item):
    return item.get("created_at") or ""


def goal_note(notes, key):
    """The last-fire note of a goal: under its key, else under an earlier text of the same goal (same_goal)."""
    notes = notes or {}
    if key in notes:
        return notes[key]
    return next((v for k, v in notes.items() if same_goal(k, key)), None)


def resolve_items(pid, goals, existing, state):
    """The work item of every goal, {key: item id}; the goals that adopted one, {key: item id}; and the other items of
    the checked goals, {key: [item id, ...]}, oldest first. A goal's item is its alias or the one its key names
    (external_id) when it exists, or none (the caller creates one); else the goal adopts the oldest unclaimed item of
    this mirror whose name or first paragraph names the same goal (same_goal) - the item of the goal's earlier text,
    renamed by a completion note or cut at 250 characters by an older mirror - and the state's aliases remember it.
    Every other unclaimed item that names a checked goal is listed for the caller to move to Done."""
    aliases = dict(state.get("aliases") or {})
    by_id = {i["id"]: i for i in existing.values()}
    texts = {i["id"]: {_norm(i.get("name")), _norm(_first_paragraph(i.get("description_html")))} - {""}
             for i in existing.values()}
    ids, claimed = {}, set()
    for g in goals:  # 1. the item the key names, when it exists
        item = by_id.get(aliases.get(g["key"])) or existing.get(str(uuid.uuid5(NS, f"{pid}:goal:{g['key']}")))
        if item is not None:
            ids[g["key"]] = item["id"]
            claimed.add(item["id"])

    def names_goal(g, iid):
        return iid not in claimed and any(same_goal(g["text"], t) for t in texts[iid])

    adopted = {}
    for g in goals:  # 2. adoption (else the caller creates the key's item)
        if g["key"] in ids:
            continue
        found = [iid for iid in texts if names_goal(g, iid)]
        if found:
            iid = min(found, key=lambda i: (_created(by_id[i]), i))
            ids[g["key"]] = adopted[g["key"]] = aliases[g["key"]] = iid
            claimed.add(iid)
    extras = {}
    for g in goals:  # 3. the other items of a checked goal
        if g["done"]:
            more = sorted((iid for iid in texts if names_goal(g, iid)), key=lambda i: (_created(by_id[i]), i))
            if more:
                extras[g["key"]] = more
                claimed.update(more)
    state["aliases"] = aliases
    return ids, adopted, extras


def mirror(cfg, goals, focus_key=None, focus_state=None, keep_open=False, notes=None, state=None, hold=None):
    """Bring every goal's work item to its state; a goal's note (its last fire) goes into its description. With `state`
    (the state file's content), the items adopted for renamed goals are found and remembered through its aliases
    (resolve_items). `hold`: the keys of the goals other fires still work on (running_goals) - their items stay In
    Progress. Returns (board, project id, {key: issue id}, counts); with the goals file in effect,
    counts["default_items"] has the work items of the default goals that are not in it ({key: issue id}), now in Cancelled."""
    state = state if state is not None else {}
    board = Board(cfg["url"], load_key(cfg["auth"]), cfg["workspace"])
    project = next((p for p in board.all("/projects/") if p.get("identifier") == cfg["project"]), None)
    if project is None:
        raise SyncError(2, f"no project {cfg['project']} in workspace {cfg['workspace']} (./run.sh seeds it)")
    pid = project["id"]
    states = {s["name"]: s["id"] for s in board.all(f"/projects/{pid}/states/")}
    for name, spec in NEW_STATES.items():
        if name not in states:
            _, s = board.call("POST", f"/projects/{pid}/states/", dict(spec, name=name))
            states[name] = s["id"]
    missing = [s for s in (TODO, IN_PROGRESS, IN_REVIEW, DONE) if s not in states]
    if missing:
        raise SyncError(2, f"project {cfg['project']} has no state(s) {missing}")
    names = {v: k for k, v in states.items()}
    existing = {i.get("external_id"): i for i in board.all(f"/projects/{pid}/issues/")
                if i.get("external_source") == SOURCE}
    by_id = {i["id"]: i for i in existing.values()}
    ids, adopted, extras = resolve_items(pid, goals, existing, state)
    counts = {"created": 0, "moved": 0, "items": len(goals), "retired": 0, "default_items": {},
              "from_default": cfg["source"] if cfg["default"] else None, "adopted": len(adopted), "duplicates": 0}
    if cfg["default"]:
        footer = (f"<p><em>Mirrored from {html.escape(cfg['source'])}, the shipped default goals the loop fires on "
                  f"while there is no goals file {html.escape(cfg['goals'])}, by /agent/plane-sync.py, the do-agent-aws "
                  "autonomy loop's board mirror. Once that goals file exists, this work item moves to Cancelled."
                  "</em></p>")
    else:
        footer = (f"<p><em>Mirrored from {html.escape(cfg['goals'])} by /agent/plane-sync.py, the do-agent-aws "
                  "autonomy loop's board mirror. The goals file is the source of truth: edit the goal there, and this "
                  "work item follows on the next fire.</em></p>")
    for g in goals:
        eid = str(uuid.uuid5(NS, f"{pid}:goal:{g['key']}"))
        cur = by_id.get(ids.get(g["key"]))  # the goal's item (resolve_items), else None: created below
        if g["done"]:
            target = DONE
        elif focus_key is not None and g["key"] == focus_key:
            target = focus_state
        elif hold and g["key"] in hold:
            target = IN_PROGRESS  # another fire still works on it (supervisor mode)
        elif keep_open and cur is not None and names.get(cur.get("state")) not in (None, DONE, CANCELLED):
            target = names[cur["state"]]
        else:
            target = TODO
        note = goal_note(notes, g["key"])
        description = (_html(g["body"]) + (f"<p><strong>Last fire:</strong> {html.escape(note)}</p>" if note else "")
                       + footer)
        if cur is None:
            code, payload = board.call("POST", f"/projects/{pid}/issues/", {
                "name": g["title"], "description_html": description, "state": states[target], "priority": "none",
                "external_id": eid, "external_source": SOURCE}, ok=(200, 201, 409))
            ids[g["key"]] = payload["id"]
            if code != 409:
                counts["created"] += 1
                continue
            if keep_open:
                continue  # created meanwhile by a fire (a start's seed can overlap the first fire): it keeps its state
            # created meanwhile: update it below
            cur = {"id": payload["id"]}
        ids[g["key"]] = cur["id"]
        changes = {}
        if cur.get("state") != states[target]:
            changes["state"] = states[target]
        if cur.get("name") != g["title"]:
            changes["name"] = g["title"]
        if not _same_html(cur.get("description_html"), description):
            changes["description_html"] = description
        if changes:
            if "state" in changes and cur.get("state") is not None:
                counts["moved"] += 1
            board.call("PATCH", f"/projects/{pid}/issues/{cur['id']}/", changes)
    # the other items of a checked goal (its earlier text's: renamed by a completion note or cut at 250 characters by an
    # older mirror, found by resolve_items): Done with the goal's item
    for key, more in extras.items():
        for iid in more:
            if names.get(by_id[iid].get("state")) in (DONE, CANCELLED):
                continue
            board.call("PATCH", f"/projects/{pid}/issues/{iid}/", {"state": states[DONE]})
            counts["moved"] += 1
            counts["duplicates"] += 1
    if not cfg["default"]:
        # the goals file exists, so the loop no longer fires on the default goals: their work items leave the open
        # states (a default goal that is in the goals file too keeps its item, mirrored above)
        mirrored = set(ids.values()) | {iid for more in extras.values() for iid in more}
        for g in parse_goals(cfg["default_goals"]) or []:
            eid = str(uuid.uuid5(NS, f"{pid}:goal:{g['key']}"))
            cur = existing.get(eid)
            if cur is None or cur["id"] in mirrored:
                continue
            counts["default_items"][g["key"]] = cur["id"]
            if CANCELLED in states and cur.get("state") != states[CANCELLED]:
                board.call("PATCH", f"/projects/{pid}/issues/{cur['id']}/", {"state": states[CANCELLED]})
                counts["retired"] += 1
    return board, pid, ids, counts


def _short(text, n=80):
    return text if len(text) <= n else text[:n - 3] + "..."


def _summary(head, goal, state, counts):
    item = f"'{_short(goal['title'])}' -> {state}; " if goal else ""
    default = f"; from the default goals {counts['from_default']} (no goals file yet)" if counts.get("from_default") else ""
    retired = f"; {counts['retired']} work item(s) of the default goals -> Cancelled" if counts.get("retired") else ""
    adopted = f"; {counts['adopted']} work item(s) of renamed goals adopted back" if counts.get("adopted") else ""
    duplicates = f"; {counts['duplicates']} other work item(s) of done goals -> Done" if counts.get("duplicates") else ""
    return (f"{head}: {item}{counts['items']} work item(s), {counts['created']} created, {counts['moved']} moved"
            f"{default}{retired}{adopted}{duplicates}")


def seed(cfg, goals, notes, state=None):
    """sync, tried again every 2s while the board does not answer (or answers an error), for up to PLANE_SEED_WAIT
    seconds: at container start the board's sidecars can still be starting. Returns the counts."""
    try:
        wait = int(os.environ.get("PLANE_SEED_WAIT", "300"))
    except ValueError:
        raise SyncError(4, "PLANE_SEED_WAIT must be a whole number of seconds")
    deadline = time.monotonic() + wait
    said = False
    while True:
        try:
            return mirror(cfg, goals, keep_open=True, notes=notes, state=state)[3]
        except SyncError as e:
            if e.code != 2:
                raise  # a refused API key or a bad setting: waiting does not help
            if time.monotonic() >= deadline:
                raise SyncError(2, f"{e} - still, after waiting {wait}s (PLANE_SEED_WAIT)")
            if not said:
                print(f"plane-sync: seed: {e} - trying again every 2s for up to {wait}s", file=sys.stderr)
                said = True
        time.sleep(2)  # nosemgrep: arbitrary-sleep -- retry interval of a bounded wait for the board


def redact(text, auth_file):
    """text with the secrets a fire's transcript can carry masked, before any of it goes on the board (which shows a
    comment and a description as HTML to whoever opens the work item) or into the state file: the values of the
    secret-named settings (SECRET_NAME) of this process's environment (the loop's: SLACK_BOT_TOKEN,
    AWS_SECRET_ACCESS_KEY and the like), of the board's secrets file (PLANE_AUTH_FILE) and of the AWS credentials and
    config files the container mounts (AWS_SHARED_CREDENTIALS_FILE, AWS_CONFIG_FILE, default ~/.aws/credentials and
    ~/.aws/config); then common token shapes, NAME=value assignments of secret-named settings, the AWS credentials
    forms and bearer tokens."""
    values = {v for k, v in os.environ.items() if SECRET_NAME.search(k)}
    for path in (auth_file,
                 os.environ.get("AWS_SHARED_CREDENTIALS_FILE") or os.path.expanduser("~/.aws/credentials"),
                 os.environ.get("AWS_CONFIG_FILE") or os.path.expanduser("~/.aws/config")):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:  # KEY=value (the secrets file) or key = value (the INI files of AWS)
                    key, sep, value = line.strip().partition("=")
                    if sep and SECRET_NAME.search(key):
                        values.add(value.strip())
        except OSError:
            pass
    for value in sorted((v for v in values if len(v) >= 8), key=len, reverse=True):
        text = text.replace(value, REDACTED)
    text = SECRET_SHAPES.sub(REDACTED, text)
    text = AWS_ASSIGNMENT.sub(lambda m: m.group(1) + REDACTED, text)
    text = JSON_SECRET.sub(lambda m: m.group(1) + f'"{REDACTED}"', text)
    text = BEARER.sub(lambda m: m.group(1) + REDACTED, text)
    return SECRET_ASSIGNMENT.sub(lambda m: m.group(1) + REDACTED, text)


def _first_line(path, auth_file):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line).strip()
                if line:
                    return _short(redact(line, auth_file), 240)
    except OSError:
        pass
    return ""


def _result_text(path, auth_file):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return "(no transcript)"
    # masked before the cut, so a secret that spans it cannot leave its second half
    text = redact(re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text).strip(), auth_file)
    if len(text) > RESULT_TAIL:
        text = "..." + text[-RESULT_TAIL:]
    return text or "(empty transcript)"


def main():
    ap = argparse.ArgumentParser(description="Mirror the autonomy loop's goals and fires on the Plane board.")
    ap.add_argument("action", choices=["sync", "seed", "fire-start", "fire-end"])
    ap.add_argument("--fire", type=int)
    ap.add_argument("--rc", type=int)
    ap.add_argument("--duration", type=int)
    ap.add_argument("--out", help="the fire's transcript file")
    ap.add_argument("--goal-key", help="fire-start: the goal this fire works on, by its key (its text without a leading "
                                       "note; supervisor mode names each worker's first goal) - default the first open goal")
    ap.add_argument("--done", help="a file to write the exit status to when it ends (ui-start.sh's seed)")
    args = ap.parse_args()
    if args.done:
        for path in (args.done, f"{args.done}.tmp"):  # an earlier run's: until this run ends, the file is absent
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            except OSError as e:
                print(f"plane-sync: cannot remove {path}: {e}", file=sys.stderr)
    rc = 1
    try:
        rc = act(args)
    finally:
        if args.done:
            sys.stdout.flush()  # its last line is in its log before the file says it ended
            sys.stderr.flush()
            try:
                with open(f"{args.done}.tmp", "w") as f:
                    f.write(f"{rc}\n")
                os.replace(f"{args.done}.tmp", args.done)  # whole or not at all for whoever polls for it
            except OSError as e:
                print(f"plane-sync: cannot write {args.done}: {e}", file=sys.stderr)
    return rc


def act(args):
    cfg = {
        "url": os.environ.get("PLANE_URL", ""),
        "auth": os.environ.get("PLANE_AUTH_FILE", "/wd/plane/plane.env"),
        "workspace": os.environ.get("PLANE_WORKSPACE", "do-agent-aws") or "do-agent-aws",
        "project": os.environ.get("PLANE_PROJECT", "AGENT") or "AGENT",
        "goals": os.environ.get("AUTONOMY_LOOP_GOALS", "/wd/goals/GOALS.md"),
        "default_goals": os.environ.get("AUTONOMY_LOOP_DEFAULT_GOALS", "/agent/goals-default.md"),
        "loop_dir": os.environ.get("AUTONOMY_LOOP_DIR", "/wd/loop"),
    }
    try:
        if not cfg["url"]:
            raise SyncError(4, "PLANE_URL is not set (no Plane board on this target)")
        if args.action not in ("sync", "seed") and args.fire is None:
            raise SyncError(4, f"{args.action} needs --fire")
        goals = parse_goals(cfg["goals"])
        cfg["source"], cfg["default"] = cfg["goals"], False
        if goals is None:
            # no goals file yet: the shipped default goals, the ones the loop fires on then
            goals = parse_goals(cfg["default_goals"])
            cfg["source"], cfg["default"] = cfg["default_goals"], True
        head = args.action if args.action in ("sync", "seed") else f"fire {args.fire} {args.action[5:]}"
        if goals is None:
            print(f"{head}: no goals file {cfg['goals']} (nor the default goals {cfg['default_goals']}) - nothing to mirror")
            return 0
        # the last fire of each goal, kept across calls and shown in its work item's description
        state = read_state(cfg["loop_dir"])
        # an earlier fire's note (written by an older plane-sync.py, maybe unmasked) is masked again before it reaches
        # a description or the state file
        notes = {k: redact(v, cfg["auth"]) for k, v in (state.get("last_fire") or {}).items() if isinstance(v, str)}
        if args.action in ("sync", "seed"):
            aliases_before = dict(state.get("aliases") or {})
            counts = (seed(cfg, goals, notes, state) if args.action == "seed" else
                      mirror(cfg, goals, keep_open=True, notes=notes, state=state)[3])
            changed = {}
            if notes != (state.get("last_fire") or {}):
                changed["last_fire"] = notes  # an older, unmasked note masked there too
            if (state.get("aliases") or {}) != aliases_before:
                changed["aliases"] = state["aliases"]  # the items this run adopted for renamed goals
            if changed:
                # a fire's record written meanwhile (a start's seed can overlap the first fire) is kept: re-read, then these
                write_state(cfg["loop_dir"], dict(read_state(cfg["loop_dir"]), **changed))
            print(_summary(head, None, None, counts))
            return 0
        if args.action == "fire-start":
            goal_key_arg = getattr(args, "goal_key", None) or None  # a caller built before the option has no attribute
            goal, note = pick_goal(goals, goal_key_arg)
            # recorded before the board is called: fire-end then files the fire under this goal even when this call
            # fails (the board down as the fire starts) and the fire checks the goal off; the aliases (the items adopted
            # for renamed goals) carry over, and so do the records of the other fires still running (supervisor mode)
            started = int(time.time())
            fires = dict(state.get("fires") or {})
            fires[str(args.fire)] = {"goal": goal["key"] if goal else None, "started": started,
                                     "requested": goal_key_arg}
            fires = prune_fires(fires, started)  # this fire's record is the newest: always kept
            state = {"fire": args.fire, "started": started, "goal": goal["key"] if goal else None,
                     "last_fire": notes, "aliases": state.get("aliases") or {}, "fires": fires}
            write_state(cfg["loop_dir"], state)
            _, _, _, counts = mirror(cfg, goals, goal["key"] if goal else None, IN_PROGRESS, notes=notes, state=state,
                                     hold=running_goals(state, args.fire))
            write_state(cfg["loop_dir"], state)  # an item adopted at this start is in the aliases now
            print(_summary(head, goal, IN_PROGRESS, counts) + (f"; {note}" if note else ""))
            return 0
        # fire-end: the goal recorded at fire-start of this fire - its own record (fires, by fire number) or the single
        # record of the latest start - else the first open one, re-read after its edits. A record made for a --goal-key
        # that was not in the file names no goal on purpose: another fire's goal is never credited with this fire
        fires = prune_fires(state.get("fires"))
        rec = fires.pop(str(args.fire), None)
        state["fires"] = fires
        if rec is not None:
            key, explicit, started = rec.get("goal"), bool(rec.get("requested")), rec.get("started")
        else:
            key = state.get("goal") if state.get("fire") == args.fire else None
            explicit, started = False, state.get("started")
        goal = next((g for g in goals if g["key"] == key), None) if key else (None if explicit else first_open(goals))
        if key and goal is None:
            # the goal's line was renamed during the fire (its completion note prefixed, or the text cut): the same goal
            goal = next((g for g in goals if same_goal(key, g["text"])), None)
        target = (DONE if goal["done"] else IN_REVIEW) if goal else None
        duration = args.duration if args.duration is not None else "?"
        if goal:
            outcome = ("the goal is checked off: Done" if goal["done"] else
                       "the goal is still open: In Review" if args.rc == 0 else
                       "the fire failed or timed out; the goal is still open: In Review")
            first = _first_line(args.out, cfg["auth"]) if args.out else ""
            notes[goal["key"]] = (f"fire {args.fire} ended rc={args.rc} after {duration}s - {outcome}."
                                  + (f" {first}" if first else ""))
        board, pid, ids, counts = mirror(cfg, goals, goal["key"] if goal else None, target, notes=notes, state=state,
                                         hold=running_goals(state, args.fire))
        write_state(cfg["loop_dir"], dict(state, last_fire=notes))
        # a fire on the default goals that created the goals file: its result goes on the default goal's work item
        item = ids[goal["key"]] if goal else counts["default_items"].get(key)
        if not goal and item:
            outcome = "the fire created the goals file, so this default goal's work item is Cancelled"
        if item:
            transcript = _result_text(args.out, cfg["auth"]) if args.out else "(no transcript)"
            message = (f"<p><strong>Fire {args.fire}</strong> of the autonomy loop ended rc={args.rc} after "
                       f"{duration}s - {html.escape(outcome)}.</p>"
                       f"<p>Result (the end of {html.escape(args.out or 'the transcript')}):</p>"
                       f"<pre><code>{html.escape(transcript)}</code></pre>")
            cid = str(uuid.uuid5(NS, f"{pid}:fire:{args.fire}:{started}:end"))
            code, _ = board.call("POST", f"/projects/{pid}/issues/{item}/comments/",
                                 {"comment_html": message, "external_id": cid, "external_source": SOURCE},
                                 ok=(200, 201, 409))
            commented = ", rc=%d %s" % (args.rc, "comment already posted" if code == 409 else "commented")
        print(_summary(head, goal, target, counts) + (commented if item else ""))
        return 0
    except SyncError as e:
        print(f"plane-sync: {e}", file=sys.stderr)
        return e.code


if __name__ == "__main__":
    sys.exit(main())
