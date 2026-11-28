#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""kanban-sync.py - mirror the autonomy loop's goals and fires on the self-hosted kanban board.

/agent/loop.sh and /agent/loop-once.sh call it around every fire while the board is up (KANBAN_BOARD_URL set by
run.sh; docs/manual/boards.md "Kanban board"). Each call is best effort: the loop bounds it with a timeout and only logs a
failure, so a board outage never fails, blocks or changes a fire. It can also be run by hand:

  kanban-sync.py sync          the board's changes into the goals file first (below), then the project and one card
                               per goal; a checked goal moves to Done, every other card keeps its column (a new card
                               starts in To do, a Cancelled one comes back to it)
  kanban-sync.py watch         sync every KANBAN_WATCH_INTERVAL seconds (default 30) while the loop is not firing:
                               what a user does on the board between fires reaches the goals file without waiting
                               for one (/agent/ui-start.sh starts it with the board, beside the seed)
  kanban-sync.py seed          the board's first view, run in the background by /agent/ui-start.sh at container
                               start, before any fire: the same as sync once the board answers, tried again every 2s
                               for up to KANBAN_SEED_WAIT seconds while it does not (its sidecars can still be
                               starting); a refused login or a bad setting ends it at once
  kanban-sync.py fire-start --fire N --started EPOCH [--goal-key KEY]
                               the same, and the goal this fire works on moves to In progress, the other open
                               goals to To do - except the goals of the other fires still running, which stay In
                               progress. KEY names the goal by its key (supervisor mode: loop.sh passes each
                               worker's first goal); without it the goal is the first open one in file order
  kanban-sync.py fire-end --fire N --started EPOCH --rc RC --duration SECONDS [--out FILE]
                               the fire's goal moves to Done when the fire checked it off, else to In review; the
                               fire's result (rc, duration, the end of its transcript FILE) becomes a comment on its
                               card, and a one-line "Last fire" note in its description (kept until its next fire),
                               both with the secrets a transcript can carry masked (redact)

Goals are read from the file the loop fires on (AUTONOMY_LOOP_GOALS, default /wd/goals/GOALS.md), and while it does
not exist from the shipped default goals the loop fires on then (AUTONOMY_LOOP_DEFAULT_GOALS, default
/agent/goals-default.md: one standing goal, the Slack inbox), so a new instance's board shows that goal from the
start. Once the goals file exists, the cards of the default goals that are not in it move to the board's hidden
Cancelled column. Two forms are goals:
  - a checkbox item "- [ ] <goal>" (the form /agent/goals-add.sh writes), done when checked "- [x] <goal>";
  - a "## Goal ..." heading (the form of docs/loop/GOALS.md.example; "## Standing goal ..." in the default goals),
    done when its heading carries "[x]".
The fire prompt tells the agent to mark a goal done in exactly these two ways.
The mirror is TWO-WAY (sync, seed, watch and fire-start pull the board first; fire-end does not, the fire just edited
the file): a card dragged to Done checks its goal off and dragged out of Done unchecks it; a card created on the
board becomes a new goal in the file's own form (its card keeps its id through an alias in the state file); a title
edit renames the goal; a description edit rewrites the goal's outcome lines with its "DONE when:" line kept. A field
edited in both places since the last sync: the goals file wins and the card gets a comment saying so. Every
write-back is one atomic rewrite (temp file + rename) under ${AUTONOMY_LOOP_DIR}/goals.lock, and the watcher never
writes while the loop is FIRING. A card created while the loop is stopped (its STOP flag set) gets a comment saying
how to start the loop; nothing starts it on its own.
The project is shown under the goal set's name: KANBAN_PROJECT_NAME, else the goals file's first "# " heading, else
"do-agent-aws goals"; a name someone chose on the board is kept (the state file records the last name this script
set). The project's id still derives from KANBAN_PROJECT, so a rename never makes a second project.
Which goal a fire worked on: fire-start records the first open goal in file order - or the goal its --goal-key names
(the supervisor mode of loop.sh, several workers at once, each on its own goal group) - with the goals that were done
already, BEFORE it calls the board (a fire completes "the single smallest unfinished increment" and goals are
worked top down). The state file keeps one record per running fire (fires: {"<fire>": {goal, card, done_before,
started, requested}}, written at fire-start, removed at fire-end, read by fire number) beside the single
fire/started/goal/card/done_before of the latest start that older readers know; the goals of the other fires still
running stay In progress through a fire-start or fire-end.
fire-end credits the goal that flipped to done during the fire when there is one (the first in
file order), else the recorded goal - a fire started with --goal-key is credited with its own goal only, never with
another worker's flip. A recorded goal whose line was renamed during the fire by a completion note
prefixed to it ("(done 2026-10-30, evidence ...) Fix X") is the same goal and keeps its card (goal_key, same_goal below);
a recorded goal whose text is really gone from the file after the fire keeps its card too: that card moves to In
review with a note, and the goals file's new text gets a new card - except a fire on the default goals that created
the goals file: its card gets the fire's result and is Cancelled.
The order within a column: a card's sort_order (what the board sorts a column by, ascending, in its Manual sort - the
default view) is minus the time the goal first reached the board (KANBAN_CARD_ORDER=newest-first, the default), so the
newest goal is on top of its column, in every column, Done included - a card created on the board, which the board itself
puts on top of its column, stays there once mirrored. That time is kept per goal in the state file (mirrored[key].since),
so a card's value never changes once set: a second sync PATCHes nothing, a goal added later only adds its own card, and
a card the mirror no longer writes (retired to In review, another card of a checked goal) keeps its place. Goals first
seen in the same sync are told apart by their file position (the file's later goal is the newer): for a file whose goals
were all added at the end this is reverse file order, and a Slack goal that goals-add.sh keeps under its heading, above a
section a card created on the board appended, still ranks by when it came. A card that was on the board before the state
knew its goal - the first sync after an update, a renamed goal's adopted card - takes its creation time on the board.
KANBAN_CARD_ORDER=file is the file's position (the oldest on top, the order before this setting). A changed setting
reaches the container at its next start (run.sh passes it) and the cards already on the board at the first sync after
that (a changed sort_order is PATCHed like any other field); a card dragged within its column (the board then renumbers
that column) keeps its place until the next sync.
What the agent does next: the card of the goal the loop's next fire starts on (the first open goal; during a fire,
the fire's own) carries one first line in its description, and no other card does: "**Agent:** working on this goal
now (fire N, since HH:MM UTC)" while the loop fires on it, "**Agent:** next - the loop's next fire, at about HH:MM
UTC, starts on this goal" while it sleeps, "**Agent:** next - the loop is idle: ..." while it waits for a goals file
or a Slack message, "**Agent:** not picked up - the loop is stopped" while its STOP flag is set and "... - the loop is
not running" when no loop process is behind its state file (${AUTONOMY_LOOP_DIR}/loop.state, which loop.sh writes:
its state word, its pid and the time). The board shows a card's first description lines on the card itself. The line
is the mirror's own: it never reaches the goals file.
Card ids are uuidv5 of the project and the goal's key: its text without its checkbox and without the parenthesised
note a fire prefixes when it checks the goal off (goal_key), so a re-run, and a completion note, update the same card
and never duplicate it; a card created or renamed on the board keeps its own id through the state file's aliases. A
goal without a card adopts the card of its earlier text when one is left on the board (same_goal: the text cut at 250
characters, the board's title length, or renamed before this rule) - the oldest one, through an alias - and the other
cards of a checked goal move to Done with it, so every card of a done goal is Done. Every call also names the board's personal organization after the project when it still has the board's
default name ("<user id>'s Org": a local account has no display name); a name someone chose is kept.

Settings (environment):
  KANBAN_BOARD_URL   the board server (run.sh: http://kanban-server:8081); only loopback or a single-label docker
                     network name is accepted - the login never leaves the host, and no HTTP proxy is used
  KANBAN_AUTH_FILE   the board login (default /wd/kanban/kanban.env: SELF_HOST_LOCAL_AUTH_EMAIL and
                     SELF_HOST_LOCAL_AUTH_PASSWORD, generated by kanban.sh on the host)
  KANBAN_PROJECT     the board project of this agent (default do-agent-aws; run.sh passes the container name) - its
                     id derives from this; its DISPLAY name from KANBAN_PROJECT_NAME (see above)
  KANBAN_WATCH_INTERVAL  seconds between the watcher's syncs (default 30)
  KANBAN_SEED_WAIT   how long seed waits for the board, in seconds (default 300)
  KANBAN_CARD_ORDER  the order of the cards within a column: newest-first (default: the goal that reached the board last
                     on top of its column, every column, Done included) or file (the file's order, the oldest on top);
                     .env's value reaches the container at its start with the other board settings; any other value is
                     a bad setting (exit 4)
  AUTONOMY_LOOP_GOALS, AUTONOMY_LOOP_DEFAULT_GOALS, AUTONOMY_LOOP_DIR (default /wd/loop: the state file
                     kanban-sync.state)

Prints one summary line on stdout. Never prints the password or the session token. Exit status: 0 mirrored (or
nothing to mirror: neither goals file exists - seed then still creates the project), 2 board unreachable (for seed:
still, after KANBAN_SEED_WAIT), a board or API error, or any unexpected failure, 3 login refused, 4 bad settings,
5 the goals file is locked (held for longer than GOALS_LOCK_WAIT seconds): nothing written, the board left as it is.
With --done FILE it removes FILE when it starts and writes that exit status to FILE when it ends: ui-start.sh's seed
runs in the background, and once it ends its pid tells nothing (an init that does not reap keeps it as a zombie, which
kill -0 still finds).

The REST calls are those of the board server at the pinned commit (github.com/BloopAI/vibe-kanban 4deb7eca8,
crates/remote/src/routes and crates/api-types): POST /v1/auth/local/login returns a Bearer token; projects, issues
and comments accept a client-generated id, a second POST of the same id answers 409, and PATCH /v1/<table>/<id>
updates (PATCH /v1/organizations/<id> {"name"} renames an organization its admin). POST /v1/issues/bulk is
update-only, so it is not used.
"""
import argparse
import datetime
import fcntl
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

# A fixed namespace keeps the ids stable across runs, containers and hosts: it is the one every board this harness
# has written uses, so existing boards keep their ids
NS = uuid.UUID("403ef658-05ce-59aa-97e8-8aea9ecc4f02")

TODO, IN_PROGRESS, IN_REVIEW, DONE = "To do", "In progress", "In review", "Done"
CANCELLED = "Cancelled"  # a hidden column of every board project (the board server's default statuses)
CARD_ORDERS = ("newest-first", "file")  # KANBAN_CARD_ORDER: the order of the cards within a column (mirror)
FOOTER = ("\n\n---\nSynced with {goals} by /agent/kanban-sync.py, the do-agent-aws autonomy loop's board mirror, both ways: "
          "moving this card to Done checks the goal off (and back), a new card becomes a goal, title and description edits "
          "reach the file at the next sync; edited in both places, the file wins. "
          "The goals file is the source of truth: edit the goal there, and this card follows on the next fire.")
DEFAULT_FOOTER = ("\n\n---\nMirrored from {source}, the shipped default goals, by /agent/kanban-sync.py, the do-agent-aws "
                  "autonomy loop's board mirror: the loop fires on them while there is no goals file {goals}. To set "
                  "your own goals, create that file (docs/manual/autonomy.md \"Autonomy loop\"); this card then leaves the board.")
RESULT_TAIL = 1500
# A fire's transcript can print anything the agent saw; its first line and its end go on the board, masked (redact)
SECRET_NAME = re.compile(r"TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE_KEY|API_?KEY|ACCESS_KEY|CREDENTIAL", re.I)
SECRET_SHAPES = re.compile(
    r"xox[abeoprs]-[A-Za-z0-9-]{8,}"  # Slack tokens
    r"|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"  # AWS access key ids
    r"|(?:IQoJb3JpZ2lu|FwoGZXIvYXdzE|AQoDYXdzE)[A-Za-z0-9/+=]{40,}"  # AWS session tokens, even after an escaped \n
    r"|\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}"  # GitHub tokens
    r"|\bsk-[A-Za-z0-9_-]{20,}"  # OpenAI-style and Anthropic API keys
    r"|\bABSK[A-Za-z0-9+/=]{20,}"  # Bedrock API keys
    r"|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"  # JWTs (a board session, for one)
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S)
SECRET_ASSIGNMENT = re.compile(  # NAME=value or name: value - an upper-case secret-named setting, or the plain words
    r"\b((?:[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY)[A-Z0-9_]*|(?i:password|passwd|secret|token|api[_-]?key))"
    r"\s*[=:]\s*)(\S+)")
# AWS credentials as their files and the CLI print them (aws_secret_access_key = ..., "SecretAccessKey": "..." and
# any JSON string under a secret-named key, the CREDENTIALS row of its text output: key id, expiration, secret key,
# session token), as Python's botocore shows them (secret_key='...'), and a bearer token in an Authorization header
AWS_ASSIGNMENT = re.compile(r"(\baws_(?:secret_access_key|session_token)\s*[=:]\s*)\S+", re.I)
AWS_TEXT_ROW = re.compile(r"(\bCREDENTIALS(?:\t|\\t))[^\n]*")
SECRET_KEY = re.compile(r"""(\bsecret_?(?:access_?)?key\s*[=:]\s*['"]?)[^'"\s,)]+""", re.I)
JSON_SECRET = re.compile(r'("[A-Za-z0-9_]*(?:secret|token|password|passwd|api_?key|private_?key|access_?key)'
                         r'[A-Za-z0-9_]*"\s*:\s*)"[^"]*"', re.I)
# a count of tokens in a string ("max_tokens": "4096", "token_count": "1234") is no secret and stays
TOKEN_COUNT = re.compile(r'"[A-Za-z0-9_]*(?:tokens|token_count)"\s*:\s*"\d+"', re.I)
BEARER = re.compile(r"(\bBearer\s+)\S{20,}", re.I)
REDACTED = "[redacted]"
# The name the board server gives a local account's personal organization ("<user id>'s Org": a local account
# has no display name) - the one name sync replaces, so a name a person chose stays
DEFAULT_ORG_NAME = re.compile(r"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}'s Org")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Follow no redirect: urllib would send the request's headers, the board session included, to wherever the
    Location points, another host too. The board server's API never redirects, so a 3xx is an error (see _req)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


# The board is on loopback or the agent's own docker network: a proxy from the environment (http_proxy, which
# .env passes into the container) must never carry the login, and no redirect may carry the session elsewhere
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


class SyncError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


# ------------------------------------------------------------------ http
def _req(method, url, headers=None, body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with _OPENER.open(req, timeout=timeout) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        if 300 <= e.code < 400:  # not followed (_NoRedirect)
            return e.code, {"redirect": (e.headers.get("Location") or "")[:200]}
        raw = e.read().decode() if e.fp else ""
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = raw[:200]
        return e.code, payload
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, {"error": str(e)}


def _assert_private(url):
    """The board login may only travel to this host or to a sidecar on the agent's docker network."""
    p = urllib.parse.urlparse(url)
    host = p.hostname or ""
    if p.scheme not in ("http", "https"):
        raise SyncError(4, f"KANBAN_BOARD_URL must be http(s)://host[:port], got scheme {p.scheme!r}")
    if host in ("127.0.0.1", "localhost", "::1") or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", host):
        return
    raise SyncError(4, f"refusing KANBAN_BOARD_URL host {host!r}: only loopback or a single-label docker network "
                       "name (the board sidecar) is allowed")


class Board:
    def __init__(self, base):
        _assert_private(base)
        self.base = base.rstrip("/")
        self.tok = None

    def _call(self, method, path, body=None, ok=(200,)):
        headers = {"Content-Type": "application/json"}
        if self.tok:
            headers["Authorization"] = f"Bearer {self.tok}"
        code, payload = _req(method, f"{self.base}{path}", headers, body)
        if code == 0:
            raise SyncError(2, f"board unreachable at {self.base} ({payload.get('error')})")
        if 300 <= code < 400:
            raise SyncError(2, f"{method} {path.split('?')[0]} -> {code}: the board answered a redirect to "
                               f"{payload.get('redirect')!r}, not followed (it would carry the board session)")
        if code not in ok:
            raise SyncError(2, f"{method} {path.split('?')[0]} -> {code}: {str(payload)[:200]}")
        return code, payload

    def login(self, email, password):
        code, payload = _req("POST", f"{self.base}/v1/auth/local/login", {"Content-Type": "application/json"},
                             {"email": email, "password": password})
        if code == 0:
            raise SyncError(2, f"board unreachable at {self.base} ({payload.get('error')})")
        if code >= 500:
            raise SyncError(2, f"the board failed the login (HTTP {code}) - is its database up?")
        if 300 <= code < 400:
            raise SyncError(2, f"the board answered the login with a redirect (HTTP {code}) to "
                               f"{payload.get('redirect')!r}, not followed")
        if code != 200 or not isinstance(payload, dict) or "access_token" not in payload:
            raise SyncError(3, f"board login refused (HTTP {code}) - check the login in KANBAN_AUTH_FILE")
        self.tok = payload["access_token"]

    def organization(self):
        _, payload = self._call("GET", "/v1/organizations")
        orgs = (payload or {}).get("organizations") or []
        if not orgs:
            raise SyncError(2, "the board login has no organization")
        # the org the board's UI opens by default: the first shared one, else the personal one
        return next((o for o in orgs if not o.get("is_personal")), orgs[0])

    def name_organization(self, org, name):
        """Give the board's default personal organization a human name (best effort: the board works without it).
        Returns True when it was renamed."""
        if not DEFAULT_ORG_NAME.fullmatch(org.get("name") or ""):
            return False
        try:
            self._call("PATCH", f"/v1/organizations/{org['id']}", {"name": name})
        except SyncError:
            return False
        return True

    def ensure_project(self, pid, org_id, name):
        code, _ = self._call("POST", "/v1/projects",
                             {"id": pid, "organization_id": org_id, "name": name, "color": _color_for(name)},
                             ok=(200, 409))
        return "created" if code == 200 else "exists"

    def project(self, pid):
        code, payload = self._call("GET", f"/v1/projects/{pid}", ok=(200, 404))
        return payload if code == 200 and isinstance(payload, dict) else None

    def rename_project(self, pid, name):
        self._call("PATCH", f"/v1/projects/{pid}", {"name": name})

    def statuses(self, project_id):
        _, payload = self._call("GET", f"/v1/project_statuses?project_id={project_id}")
        return {s["name"]: s["id"] for s in (payload or {}).get("project_statuses", [])}

    def issues(self, project_id):
        _, payload = self._call("GET", f"/v1/issues?project_id={project_id}")
        return {i["id"]: i for i in (payload or {}).get("issues", [])}

    def create_issue(self, body):
        code, _ = self._call("POST", "/v1/issues", body, ok=(200, 409))
        return code == 200

    def update_issue(self, iid, changes):
        self._call("PATCH", f"/v1/issues/{iid}", changes)

    def comment(self, cid, issue_id, message):
        code, _ = self._call("POST", "/v1/issue_comments",
                             {"id": cid, "issue_id": issue_id, "message": message, "parent_id": None},
                             ok=(200, 409))
        return code == 200


def _color_for(name):
    h = 0
    for ch in name:
        h = (h * 31 + ord(ch)) % 360
    return f"{h} 70% 55%"


def project_id(name):
    return str(uuid.uuid5(NS, f"project:{name}"))


def card_id(pid, key):
    return str(uuid.uuid5(NS, f"{pid}:goal:{key}"))


# ------------------------------------------------------------------ goal identity
# A fire that checks a goal off may prefix its line with a parenthesised note - "(done 2026-10-30, evidence ...) Fix X" -
# and the goal is the same: its key, and so its card, is the text without that note. same_goal() also pairs the forms
# older mirrors left behind: a text cut at 250 characters (the board's title length), a note appended, whitespace.
# plane-sync.py carries the same three functions, so both boards agree on what one goal is.
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
    """The title the mirror writes for a goal: its first 250 characters (the board's title length)."""
    return (text or "")[:250]


# ------------------------------------------------------------------ goals
CHECKBOX = re.compile(r"^\s*[-*]\s+\[([ xX])\]\s+(\S.*?)\s*$")
HEADING = re.compile(r"^##\s+(\S.*?)\s*$")
DONE_MARK = re.compile(r"\[[xX]\]")


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
            # "Goal 1 - ..." or "Standing goal - ...", not the section "Goals from Slack"
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
        return None, f"--goal-key '{_short(goal_key, 60)}' is not in the goals file: no card is moved for this fire"
    return goal, ""


# the per-fire records of the state file (supervisor mode, several fires at once): state["fires"] = {"<fire>": {"goal":
# key or None, "card": id or None, "done_before": [keys], "started": epoch, "requested": the --goal-key or None}},
# written at fire-start and removed at fire-end; a record a killed loop left behind leaves after FIRES_TTL seconds, and
# only the newest FIRES_MAX records are kept
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
    cards In progress while this fire starts or ends."""
    return {r.get("goal") for n, r in (state.get("fires") or {}).items()
            if isinstance(r, dict) and r.get("goal") and str(n) != str(except_fire)}


AGENT_CUE = "**Agent:**"  # the first line of one card's description: what the agent does next (agent_cue)


def loop_state(loop_dir):
    """The loop's own state line, ${AUTONOMY_LOOP_DIR}/loop.state ("WORD key=value ... pid=P utc=T", loop.sh), as
    (word, fields); fields["alive"] is True only while that pid is a running loop.sh. (None, {}) without the file."""
    try:
        with open(os.path.join(loop_dir, "loop.state")) as f:
            parts = f.read().split()
    except OSError:
        return None, {}
    if not parts:
        return None, {}
    fields = dict(p.split("=", 1) for p in parts[1:] if "=" in p)
    try:
        with open(f"/proc/{int(fields.get('pid', ''))}/cmdline", "rb") as f:
            fields["alive"] = b"loop.sh" in f.read()
    except (OSError, ValueError):
        fields["alive"] = False
    return parts[0], fields


def _hhmm(utc, plus=0):
    """HH:MM of loop.sh's utc= time plus some seconds, or None."""
    try:
        t = datetime.datetime.strptime(utc, "%Y-%m-%dT%H:%M:%SZ") + datetime.timedelta(seconds=int(plus))
    except (TypeError, ValueError):
        return None
    return t.strftime("%H:%M")


def agent_cue(cfg, goals, state, phase=None):
    """(goal key, first line) for the one card the agent acts on next, or (None, None) when no goal is open: what the
    loop says of itself (loop_state), its STOP flag and the goal order decide. phase "fire-start": the fire's own goal,
    working; "fire-end": the next open goal, the next fire's (the state file still says FIRING then)."""
    open_goals = [g for g in goals if not g["done"]]
    if not open_goals:
        return None, None
    nxt = open_goals[0]["key"]
    if os.path.exists(os.path.join(cfg["loop_dir"], "STOP")):
        return nxt, f"{AGENT_CUE} not picked up - the loop is stopped (its STOP flag is set; /agent/loop-start.sh starts it)"
    word, f = loop_state(cfg["loop_dir"])
    open_keys = {g["key"] for g in open_goals}
    # the other fires still running (supervisor mode, state["fires"] - this fire's record is already gone at fire-end),
    # the lowest fire number first
    running = sorted((int(n), r) for n, r in (state.get("fires") or {}).items()
                     if str(n).isdigit() and isinstance(r, dict) and r.get("goal") in open_keys)
    if phase == "fire-end":
        if running:
            return running[0][1]["goal"], f"{AGENT_CUE} working on this goal now (fire {running[0][0]})"
        return nxt, f"{AGENT_CUE} next - the loop's next fire starts on this goal"
    if phase == "fire-start" or (word == "FIRING" and f.get("alive")):
        key = state.get("goal") if state.get("goal") in open_keys else nxt
        since = _hhmm(f.get("utc")) if word == "FIRING" else None
        # the fire's own number at fire-start (the loop's state line is the previous cycle's until every worker of a
        # supervisor cycle has started); the loop's state line (one fire, or the cycle's fires) while it says FIRING
        fire = state.get("fire") if phase == "fire-start" or word != "FIRING" else f.get("fire")
        return key, (f"{AGENT_CUE} working on this goal now (fire {fire}" + (f", since {since} UTC" if since else "") + ")")
    if not f.get("alive"):
        return nxt, f"{AGENT_CUE} not picked up - the loop is not running (/agent/loop-start.sh starts it)"
    if word == "SLEEPING":
        at = _hhmm(f.get("utc"), (f.get("interval") or "").rstrip("s") or 0)
        return nxt, f"{AGENT_CUE} next - the loop's next fire" + (f", at about {at} UTC," if at else "") + " starts on this goal"
    if word == "IDLE":
        return nxt, f"{AGENT_CUE} next - the loop is idle: it fires when a Slack message arrives or the goals file appears"
    return nxt, f"{AGENT_CUE} not picked up - the loop is stopped (/agent/loop-start.sh starts it)"


# ------------------------------------------------------------------ state
def _state_path(loop_dir):
    return os.path.join(loop_dir, "kanban-sync.state")


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
        print(f"kanban-sync: cannot write the state file: {e}", file=sys.stderr)


# ------------------------------------------------------------------ two-way: the board writes back into the goals file
# What the board may change, and what the file gets (the file stays the source the loop fires on):
#   - a card dragged to Done checks its goal off; dragged out of Done it is unchecked;
#   - a card created on the board becomes a new goal in the file's own form (a "## Goal N - title" section with the
#     card's description as its outcome, or a "- [ ] title" item when the file is a checklist);
#   - a card's title edit renames the goal (the goal's key is its text, so the card keeps its id through an alias);
#   - a card's description edit rewrites the goal's outcome lines, the "DONE when:" line kept.
# A field edited in BOTH places since the last sync: the file wins and the card gets a comment saying so. Every
# write-back is one atomic rewrite (temp file + rename) under ${AUTONOMY_LOOP_DIR}/goals.lock, and the watcher
# never writes while the loop is FIRING (a fire reads and edits the file itself).
GOALS_LOCK_WAIT = 20          # seconds a write-back waits for the goals lock
CONFLICT_NOTE = "Edited on the board and in the goals file since the last sync; the goals file wins. The board shows the file's {field} again."
REMOVED_NOTE = ("Removed from the goals file (or renamed there: the file's new text has its own card). This card is not mirrored any "
                "more and keeps its history: In review. Move it to Done or Cancelled, or delete it, as you see fit.")
ADOPTED_NOTE = ("This card is its goal's card again: the goal's line in {goals} was renamed (a completion note prefixed to it, or "
                "the text cut at 250 characters by an older mirror), and cards now follow the goal text without its note. "
                "It mirrors the goal from here on.")
DUPLICATE_NOTE = ("Another card of a goal that is checked off in {goals}: an older mirror created it when the goal's line was "
                  "renamed or cut, so it was left behind. Done, with the goal's card.")
STOPPED_NOTE = ("Added to the goals file as a new goal. The autonomy loop is stopped (its STOP flag is set), so nothing works on it "
                "until the loop runs again: /agent/loop-start.sh in the container (docs/manual/autonomy.md \"Autonomy loop\").")


def issue_id_for(pid, key, state):
    """The card of a goal: an alias (a card created or renamed on the board keeps its id) or the key's uuid."""
    return (state.get("aliases") or {}).get(key) or card_id(pid, key)


def strip_mirror(description):
    """The user's text of a card description: without our footer, the 'Last fire' note and the agent line."""
    text = description or ""
    m = re.search(r"\n\n---\n(Synced with|Mirrored from) ", text)
    if m:
        text = text[:m.start()]
    text = re.sub(r"\n\n\*\*Last fire:\*\* .*$", "", text, flags=re.S)
    text = re.sub(r"\A" + re.escape(AGENT_CUE) + r" [^\n]*(?:\n\n|\Z)", "", text)
    # the projection's summary and marker (card_body) are not the user's text: the full text after the marker is
    cut = text.find("\n" + FULL_MARKER + "\n")
    if cut >= 0:
        text = text[cut + len(FULL_MARKER) + 2:]
    elif text.startswith(FULL_MARKER + "\n"):
        text = text[len(FULL_MARKER) + 1:]
    return text.strip()


def goals_file_form(lines):
    """'heading' when the file writes goals as '## Goal' sections (docs/loop/GOALS.md.example), 'checkbox' when it is a
    checklist (what goals-add.sh writes), 'heading' for an empty or undecided file."""
    if any(HEADING.match(l) and re.match(r"(standing\s+)?goal\b", DONE_MARK.sub("", HEADING.match(l).group(1)), re.I) for l in lines):
        return "heading"
    if any(CHECKBOX.match(l) for l in lines):
        return "checkbox"
    return "heading"


def locate_goals(lines):
    """[{key, kind, line, end}] in file order: kind 'checkbox' (one line) or 'heading' (the heading line and its body up to
    the next heading, blank-trimmed); keys as parse_goals makes them."""
    out, seen, fence, current = [], {}, False, None
    for n, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        m = CHECKBOX.match(line)
        if m:
            current = None
            text = goal_key(m.group(2))
            k = seen[text] = seen.get(text, 0) + 1
            out.append({"key": text if k == 1 else f"{text}#{k}", "kind": "checkbox", "line": n, "end": n + 1})
            continue
        m = HEADING.match(line)
        if m:
            current = None
            text = goal_key(" ".join(DONE_MARK.sub("", m.group(1)).split()))
            if re.match(r"(standing\s+)?goal\b", text, re.I):
                k = seen[text] = seen.get(text, 0) + 1
                current = {"key": text if k == 1 else f"{text}#{k}", "kind": "heading", "line": n, "end": n + 1}
                out.append(current)
            continue
        if current is not None and line.strip():
            current["end"] = n + 1
    return out


def goal_block(form, title, outcome, done, number):
    """The lines of a new goal in the file's form."""
    if form == "checkbox":
        return [f"- [{'x' if done else ' '}] {title}"]
    body = [l for l in (outcome or "").splitlines() if l.strip()]
    if not any(l.lower().startswith("done when") for l in body):
        body.append("DONE when: (state a file or a command result that only exists once the work is done)")
    return ["", f"## Goal {number} - {title}" + (" [x]" if done else ""), ""] + body


def write_goals_file(cfg, lines):
    """One atomic rewrite under the goals lock."""
    path = cfg["goals"]
    lock_path = os.path.join(cfg["loop_dir"], "goals.lock")
    os.makedirs(cfg["loop_dir"], exist_ok=True)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(lock_path, "w") as lock:
        deadline = time.monotonic() + GOALS_LOCK_WAIT
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise SyncError(5, f"the goals file is locked ({lock_path}) - not written, the board left as it is")
                time.sleep(0.2)  # nosemgrep: arbitrary-sleep -- retry interval of a bounded lock wait
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(lines).rstrip("\n") + "\n")
        os.replace(tmp, path)
        fcntl.flock(lock, fcntl.LOCK_UN)


def pull(cfg, board, pid, goals, state, status_ids, existing):
    """Apply the board's changes to the goals file; returns (changed: bool, summary: [str], comments: [(issue_id, text)]).
    `goals` is the parsed file (None when there is no goals file: only new cards can create one)."""
    names = {v: k for k, v in status_ids.items()}
    mirrored = state.get("mirrored") or {}
    aliases = dict(state.get("aliases") or {})
    try:
        with open(cfg["goals"], encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
    except FileNotFoundError:
        lines = None
    file_goals = goals or []
    by_key = {g["key"]: g for g in file_goals}
    ids = {issue_id_for(pid, k, state): k for k in by_key}
    default_ids = {card_id(pid, g["key"]) for g in (parse_goals(cfg["default_goals"]) or [])}
    changes, comments = [], []
    located = locate_goals(lines) if lines is not None else []
    loc = {l["key"]: l for l in located}
    form = goals_file_form(lines or [])
    if lines is None:
        lines = ["# Goals for the autonomy loop", ""]
        form = "heading"
    by_id = {m.get("id"): (k, m) for k, m in mirrored.items()}
    # 1. cards of known goals: status, title, description
    for iid, card in existing.items():
        key = ids.get(iid)
        if key is None:
            # a card this script mirrored whose goal text is no longer in the file (renamed or removed there; the
            # file's new text gets its own card, the old one stays as the fire hooks leave it): a title edited on
            # the board meanwhile is a conflict - the file's last text comes back, with a comment
            if iid in by_id:
                old_key, base = by_id[iid]
                board_title = _norm(card.get("title"))
                # the mirror writes the first 250 characters of the text as the title (card_title): only another title
                # is an edit
                if base.get("title") and board_title and board_title != _norm(card_title(base["title"])):
                    board.update_issue(iid, {"title": card_title(base["title"])})
                    comments.append((iid, CONFLICT_NOTE.format(field="title")))
            continue
        g, base, where = by_key[key], mirrored.get(key) or {}, loc.get(key)
        if where is None:
            continue
        status = names.get(card.get("status_id"))
        board_done = status == DONE
        if base and board_done != base.get("done") and g["done"] == base.get("done"):
            # the board moved the card: check or uncheck the goal
            l = lines[where["line"]]
            if where["kind"] == "checkbox":
                lines[where["line"]] = re.sub(r"\[[ xX]\]", "[x]" if board_done else "[ ]", l, count=1)
            else:
                lines[where["line"]] = (l.rstrip() + " [x]") if (board_done and not DONE_MARK.search(l)) else (DONE_MARK.sub("", l).rstrip() if not board_done else l)
            changes.append(f"{_short(g['text'])}: {'done' if board_done else 'reopened'} on the board")
        elif base and board_done != base.get("done") and g["done"] != base.get("done") and g["done"] != board_done:
            comments.append((iid, CONFLICT_NOTE.format(field="state")))
        board_title = _norm(card.get("title"))
        # the title the mirror wrote is the first 250 characters of the goal's text (card_title): a longer goal's card
        # shows a cut title, which is no rename - only another title is one
        shown = _norm(card_title(base.get("title"))) if base else ""
        if base and board_title and board_title != shown and g["text"] == base.get("title"):
            l = lines[where["line"]]
            if where["kind"] == "checkbox":
                lines[where["line"]] = l.replace(g["text"], board_title, 1)
            else:
                lines[where["line"]] = l.replace(g["text"], board_title, 1)
            aliases.pop(key, None)
            aliases[goal_key(board_title)] = iid
            changes.append(f"{_short(g['text'])}: renamed on the board to {_short(board_title)}")
        elif base and board_title and board_title != shown and g["text"] != base.get("title"):
            comments.append((iid, CONFLICT_NOTE.format(field="title")))
        board_body = strip_mirror(card.get("description"))
        if where["kind"] == "heading" and base and board_body != (base.get("body") or "") and g["body"] == (base.get("body") or ""):
            # the outcome lines change; a "DONE when:" line the card dropped is kept
            keep = [l for l in lines[where["line"] + 1:where["end"]] if l.strip().lower().startswith("done when")]
            new_body = [l for l in board_body.splitlines() if l.strip()]
            if keep and not any(l.strip().lower().startswith("done when") for l in new_body):
                new_body += keep
            lines[where["line"] + 1:where["end"]] = [""] + new_body
            changes.append(f"{_short(g['text'])}: description edited on the board")
            located = locate_goals(lines); loc = {l["key"]: l for l in located}
        elif where["kind"] == "heading" and base and board_body != (base.get("body") or "") and g["body"] != (base.get("body") or ""):
            comments.append((iid, CONFLICT_NOTE.format(field="description")))
    # 2. cards created on the board: new goals, appended in the file's form. A card this script mirrored before (its
    #    goal removed from the file, or the file removed) is not one: it stays as the mirror leaves it
    # the next "Goal N" is past every number the file's goal headings use: a goal removed from the middle leaves a gap,
    # and counting the headings would give the new goal a number one of them already has
    headings = [l["key"] for l in located if l["kind"] == "heading"]
    numbers = [int(m.group(1)) for m in (re.match(r"goal\s+(\d+)\b", k, re.I) for k in headings) if m]
    number = max(numbers + [len(headings)]) + 1
    known = set(ids) | default_ids | set(aliases.values()) | {m.get("id") for m in mirrored.values()} | set(state.get("known_cards") or [])
    for iid, card in existing.items():
        if iid in known:
            continue
        status = names.get(card.get("status_id"))
        if status == CANCELLED:
            continue
        title = _norm(card.get("title"))
        if not title or goal_key(title) in by_key:
            continue
        lines += goal_block(form, title, strip_mirror(card.get("description")), status == DONE, number)
        aliases[goal_key(f"Goal {number} - {title}" if form == "heading" else title)] = iid
        number += 1
        changes.append(f"new goal from the board: {_short(title)}")
        if os.path.exists(os.path.join(cfg["loop_dir"], "STOP")):
            comments.append((iid, STOPPED_NOTE))
    if changes:
        write_goals_file(cfg, lines)
    state["aliases"] = aliases
    return bool(changes), changes, comments


# ------------------------------------------------------------------ mirror
def load_login(path):
    vals = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    vals[k.strip()] = v.strip()
    except OSError:
        raise SyncError(4, f"the board login file {path} is missing (kanban.sh creates it on the host at ./run.sh)")
    email, password = vals.get("SELF_HOST_LOCAL_AUTH_EMAIL"), vals.get("SELF_HOST_LOCAL_AUTH_PASSWORD")
    if not (email and password):
        raise SyncError(4, f"{path} lacks SELF_HOST_LOCAL_AUTH_EMAIL or SELF_HOST_LOCAL_AUTH_PASSWORD")
    return email, password


def goal_note(notes, key):
    """The last-fire note of a goal: under its key, else under an earlier text of the same goal (same_goal)."""
    notes = notes or {}
    if key in notes:
        return notes[key]
    return next((v for k, v in notes.items() if same_goal(k, key)), None)


def _created(card):
    return card.get("created_at") or ""


def _created_epoch(card):
    """A card's creation time on the board as epoch seconds (the server's created_at, ISO 8601), None without one."""
    raw = (card or {}).get("created_at")
    if not raw:
        return None
    try:
        return datetime.datetime.fromisoformat(str(raw).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def resolve_cards(pid, goals, existing, state):
    """The card of every goal, {key: issue id}; the goals that adopted a card, {key: issue id}; and the other cards of
    the checked goals, {key: [issue id, ...]}, oldest first. A goal's card is its alias or its key's uuid (card_id) when
    that card exists, or when none does (a new card gets the uuid); else the goal adopts the oldest unclaimed card this
    mirror made whose text names the same goal (same_goal, over the card's title and the texts the state mirrored or
    aliased it under) - the card of the goal's earlier text, renamed by a completion note or cut at 250 characters by an
    older mirror - and the state's aliases remember it. Every other unclaimed card that names a checked goal is listed
    for the caller to move to Done. An adopted card is no longer retired."""
    aliases = dict(state.get("aliases") or {})
    mirrored = state.get("mirrored") or {}
    retired = set(state.get("retired_cards") or [])
    known = set(state.get("known_cards") or []) | set(aliases.values()) | retired | {m.get("id") for m in mirrored.values()}
    texts = {iid: {_norm(card.get("title"))} - {""} for iid, card in existing.items() if iid in known}
    for key, m in mirrored.items():
        if m.get("id") in texts:
            texts[m["id"]].update(t for t in (key, m.get("title")) if t)
    for key, iid in aliases.items():
        if iid in texts:
            texts[iid].add(key)
    ids, claimed = {}, set()
    for g in goals:  # 1. the card the key names, when it exists
        iid = issue_id_for(pid, g["key"], state)
        if iid in existing:
            ids[g["key"]] = iid
            claimed.add(iid)

    def names_goal(g, iid):
        return iid not in claimed and any(same_goal(g["text"], t) for t in texts[iid])

    adopted = {}
    for g in goals:  # 2. adoption, else the key's uuid (a new card)
        if g["key"] in ids:
            continue
        found = [iid for iid in texts if names_goal(g, iid)]
        if found:
            iid = min(found, key=lambda i: (_created(existing[i]), i))
            adopted[g["key"]] = aliases[g["key"]] = iid
        else:
            iid = issue_id_for(pid, g["key"], state)
        ids[g["key"]] = iid
        claimed.add(iid)
    extras = {}
    for g in goals:  # 3. the other cards of a checked goal
        if g["done"]:
            more = sorted((iid for iid in texts if names_goal(g, iid)), key=lambda i: (_created(existing[i]), i))
            if more:
                extras[g["key"]] = more
                claimed.update(more)
    state["aliases"] = aliases
    state["retired_cards"] = sorted(retired - set(ids.values()))
    return ids, adopted, extras


def mirror(cfg, goals, focus_key=None, focus_status=None, keep_open=False, notes=None, state=None, cue=None, hold=None):
    """Bring every goal's card to its column; a goal's note (its last fire) goes into its description, and `cue`
    (agent_cue: a goal key and a line) leads that one goal's description. With `state`,
    cards created or renamed on the board are found through its aliases and the baseline of what was written is
    recorded in it (what a later pull compares the board against). `hold`: the keys of the goals other fires still
    work on (running_goals) - their cards stay In progress.
    Returns (board, project_id, {key: issue_id}, counts, status_ids)."""
    state = state if state is not None else {}
    before = dict(state.get("mirrored") or {})   # the previous baseline: the goals mirrored last time, by key
    board = Board(cfg["url"])
    board.login(*load_login(cfg["auth"]))
    org = board.organization()
    org_named = board.name_organization(org, cfg["project"])
    pid = project_id(cfg["project"])
    project = board.ensure_project(pid, org["id"], cfg["project_name"])
    # the goal set's name on the board; a name someone chose there (not the one this script set last) is kept
    current = board.project(pid)
    if current and current.get("name") not in (None, cfg["project_name"]) and current.get("name") in (state.get("project_name"), cfg["project"]):
        board.rename_project(pid, cfg["project_name"])
        project = "renamed"
    state["project_name"] = cfg["project_name"]
    status_ids = board.statuses(pid)
    missing = [s for s in (TODO, IN_PROGRESS, IN_REVIEW, DONE) if s not in status_ids]
    if missing:
        raise SyncError(2, f"project {cfg['project']} has no status column(s) {missing}")
    names = {v: k for k, v in status_ids.items()}
    existing = board.issues(pid)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    ids, counts = {}, {"created": 0, "moved": 0, "cards": len(goals), "project": project, "org_named": org_named,
                       "from_default": cfg["source"] if cfg["default"] else None, "retired": [], "removed": []}
    footer = (DEFAULT_FOOTER if cfg["default"] else FOOTER).format(goals=cfg["goals"], source=cfg["source"])
    ids, adopted, extras = resolve_cards(pid, goals, existing, state)
    counts.update(adopted=sorted(adopted.values()), duplicates=[])
    # the order within a column: the board sorts a column by sort_order, ascending (its Manual sort, the default view),
    # so the smallest is on top. newest-first (the default): minus the goal's `since` - the time it first reached the
    # board, kept per goal in the state file, so a value never changes once set (a second sync PATCHes nothing; a goal
    # added later only adds its own card; a card the mirror no longer writes keeps its place) and the newest goal is on
    # top of its column, Done included, wherever it sits in the file (goals-add.sh keeps a Slack goal under its heading,
    # which is not the file's end once a card created on the board appended a section after it). Goals first seen in
    # the same sync are told apart by their file position, a tenth of a millisecond per goal: the file's later goal is
    # the newer. A goal whose card was on the board before the state knew it (the board of an earlier version at the
    # first sync after an update; a renamed goal's adopted card) takes the card's creation time there. file: the file's
    # position, 1.0 for its first goal (the order before this setting)
    newest_first = cfg.get("card_order", CARD_ORDERS[0]) != "file"
    now_epoch = time.time()
    by_card = {m.get("id"): m.get("since") for m in before.values() if isinstance(m.get("since"), (int, float))}
    sinces = {}
    for idx, g in enumerate(goals):
        iid = ids[g["key"]]
        cur = existing.get(iid)
        since = (before.get(g["key"]) or {}).get("since")
        if not isinstance(since, (int, float)):
            since = by_card.get(iid) or _created_epoch(cur) or (now_epoch + idx * 1e-4)
        sinces[g["key"]] = since
        if g["done"]:
            target = DONE
        elif focus_key is not None and g["key"] == focus_key:
            target = focus_status
        elif hold and g["key"] in hold:
            target = IN_PROGRESS  # another fire still works on it (supervisor mode)
        elif keep_open and cur is not None and names.get(cur.get("status_id")) not in (None, DONE, CANCELLED):
            target = names[cur["status_id"]]
        else:
            target = TODO
        note = goal_note(notes, g["key"])
        lead = f"{cue[1]}\n\n" if cue and cue[0] == g["key"] else ""
        description = lead + card_body(g, cfg) + (f"\n\n{note}" if note else "") + footer
        fields = {"status_id": status_ids[target], "title": g["title"], "description": description,
                  "sort_order": -since if newest_first else float(idx + 1)}
        if target == DONE and not (cur or {}).get("completed_at"):
            fields["completed_at"] = now
        elif target != DONE and (cur or {}).get("completed_at"):
            fields["completed_at"] = None
        if cur is None:
            body = dict(fields, id=iid, project_id=pid, priority=None, extension_metadata={})
            if board.create_issue(body):
                counts["created"] += 1
                continue
            if keep_open:
                continue  # created meanwhile (a 409) by a fire (the startup seed can overlap the first one): its column
            cur = {}  # created meanwhile (a 409): update it below
        changes = {k: v for k, v in fields.items() if cur.get(k) != v}
        if changes:
            if "status_id" in changes and cur.get("status_id") is not None:
                counts["moved"] += 1
            board.update_issue(iid, changes)
    # the other cards of a checked goal (its earlier text's: renamed by a completion note or cut at 250 characters by an
    # older mirror, found by resolve_cards): Done with the goal's card, one note each; an adopted card gets one note too
    for key, more in extras.items():
        for iid in more:
            cur = existing[iid]
            if names.get(cur.get("status_id")) in (DONE, CANCELLED):
                continue
            board.update_issue(iid, {"status_id": status_ids[DONE], "completed_at": cur.get("completed_at") or now})
            board.comment(str(uuid.uuid5(NS, f"{pid}:duplicate-done:{iid}")), iid, DUPLICATE_NOTE.format(goals=cfg["goals"]))
            counts["moved"] += 1
            counts["duplicates"].append(iid)
    for key, iid in adopted.items():
        board.comment(str(uuid.uuid5(NS, f"{pid}:adopted:{iid}")), iid, ADOPTED_NOTE.format(goals=cfg["goals"]))
    extra_ids = {iid for more in extras.values() for iid in more}
    state["mirrored"] = {g["key"]: {"id": ids[g["key"]], "title": g["text"], "body": g["body"], "done": g["done"],
                                    "since": sinces[g["key"]]} for g in goals}
    state["known_cards"] = sorted(set(state.get("known_cards") or []) | set(ids.values()) | extra_ids)
    # a goal that left the file (removed, or renamed there - the file's new text has its own card): its card is not
    # mirrored any more and keeps its history, In review, with one note saying so; a card already Done,
    # Cancelled or In review (the fire-end hook moved it) stays as it is; the state remembers, so the note is posted once.
    # The other cards of a checked goal (handled above) are retired too: never In review
    retired_cards = set(state.get("retired_cards") or []) | extra_ids
    for key, m in before.items():
        iid = m.get("id")
        if key in ids or not iid or iid in ids.values() or iid in retired_cards:
            continue
        cur = existing.get(iid)
        if cur is None:
            continue
        if names.get(cur.get("status_id")) not in (DONE, CANCELLED, IN_REVIEW):
            board.update_issue(iid, {"status_id": status_ids[IN_REVIEW]})
            board.comment(str(uuid.uuid5(NS, f"{pid}:removed:{iid}")), iid, REMOVED_NOTE)
            counts["moved"] += 1
            counts["removed"].append(iid)
        retired_cards.add(iid)
    state["retired_cards"] = sorted(retired_cards)
    if not cfg["default"] and CANCELLED in status_ids:
        # the goals file exists, so the loop no longer fires on the default goals: their cards leave the board
        for g in parse_goals(cfg["default_goals"]) or []:
            iid = card_id(pid, g["key"])
            if iid not in ids.values() and iid in existing and existing[iid].get("status_id") != status_ids[CANCELLED]:
                board.update_issue(iid, {"status_id": status_ids[CANCELLED]})
                counts["retired"].append(iid)
    return board, pid, ids, counts, status_ids


FULL_MARKER = "## Full instructions"


def card_body(g, cfg):
    """What a card's description shows of the goal: a checkbox goal's body is its title, so nothing; a body of
    more than one line (the standing goal's instructions, a goal's outcome and DONE condition) leads with its first
    line, then one line that is exactly FULL_MARKER, then the full text (the board's card panel shows the summary
    and a "Show full instructions" toggle that splits at the first marker; any edit saves the whole description, which
    strip_mirror() reads back by the same marker, so a re-projection is byte-identical)."""
    body = (g["body"] or "").strip()
    if body == g["text"].strip():
        return ""
    lines = [l for l in body.splitlines() if l.strip()]
    if len(lines) <= 1:
        return body
    return f"{lines[0].strip()}\n\n{FULL_MARKER}\n\n{body}"


def _short(text, n=80):
    return text if len(text) <= n else text[:n - 3] + "..."


def _summary(head, goal, status, counts):
    card = f"'{_short(goal['title'])}' -> {status}; " if goal else ""
    default = f"; from the default goals {counts['from_default']} (no goals file yet)" if counts.get("from_default") else ""
    retired = f"; {len(counts['retired'])} card(s) of the default goals -> Cancelled" if counts.get("retired") else ""
    removed = f"; {len(counts['removed'])} card(s) of goals removed from the file -> In review" if counts.get("removed") else ""
    adopted = f"; {len(counts['adopted'])} card(s) of renamed goals adopted back" if counts.get("adopted") else ""
    duplicates = f"; {len(counts['duplicates'])} other card(s) of done goals -> Done" if counts.get("duplicates") else ""
    named = "; organization named after the project" if counts.get("org_named") else ""
    return (f"{head}: {card}{counts['cards']} card(s), {counts['created']} created, {counts['moved']} moved "
            f"(project {counts['project']}){default}{retired}{removed}{adopted}{duplicates}{named}")


def redact(text, auth_file):
    """text with the secrets a fire's transcript can carry masked, before any of it goes on the board (which shows a
    comment as HTML to whoever opens the card): the values of the secret-named settings (SECRET_NAME) of this
    process's environment (the loop's: SLACK_BOT_TOKEN, AWS_SECRET_ACCESS_KEY and the like), of the board login file
    and of the AWS credentials and config files the container mounts (AWS_SHARED_CREDENTIALS_FILE, AWS_CONFIG_FILE,
    default ~/.aws/credentials and ~/.aws/config); then common token shapes, NAME=value assignments of secret-named
    settings, the AWS credentials forms and bearer tokens."""
    values = {v for k, v in os.environ.items() if SECRET_NAME.search(k)}
    for path in (auth_file,
                 os.environ.get("AWS_SHARED_CREDENTIALS_FILE") or os.path.expanduser("~/.aws/credentials"),
                 os.environ.get("AWS_CONFIG_FILE") or os.path.expanduser("~/.aws/config")):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:  # KEY=value (the login file) or key = value (the INI files of AWS)
                    key, sep, value = line.strip().partition("=")
                    if sep and SECRET_NAME.search(key):
                        values.add(value.strip())
        except OSError:
            pass
    for value in sorted((v for v in values if len(v) >= 8), key=len, reverse=True):
        text = text.replace(value, REDACTED)
    text = SECRET_SHAPES.sub(REDACTED, text)
    text = AWS_ASSIGNMENT.sub(lambda m: m.group(1) + REDACTED, text)
    text = AWS_TEXT_ROW.sub(lambda m: m.group(1) + REDACTED, text)
    text = SECRET_KEY.sub(lambda m: m.group(1) + REDACTED, text)
    text = JSON_SECRET.sub(lambda m: m.group(0) if TOKEN_COUNT.fullmatch(m.group(0))
                           else m.group(1) + f'"{REDACTED}"', text)
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
    return text.replace("```", "'''") or "(empty transcript)"


def fire_end(cfg, args, goals, state, notes):
    """Credit the fire to the goal it finished, else to the recorded goal; returns the summary line."""
    head = f"fire {args.fire} end"
    # this fire's own record (fires, by fire number: supervisor mode, or any fire-start of this version), else the single
    # record of the latest start (an older fire-start), else nothing recorded
    fires = prune_fires(state.get("fires"))
    rec = fires.pop(str(args.fire), None)
    state["fires"] = fires
    if rec is not None and rec.get("started") == args.started:
        recorded = rec
    else:
        recorded = state if (state.get("fire"), state.get("started")) == (args.fire, args.started) else {}
    explicit = bool(recorded.get("requested"))  # started with --goal-key: credited with its own goal only
    done_before = set(recorded.get("done_before") or [])
    flipped = [g for g in goals if g["done"] and g["key"] not in done_before] if recorded else []
    key = recorded.get("goal")
    by_key = {g["key"]: g for g in goals}
    if key and key not in by_key:
        # the goal's line was renamed during the fire (its completion note prefixed, or the text cut): the same goal
        same = next((g for g in goals if same_goal(key, g["text"])), None)
        if same is not None:
            key = same["key"]
    orphan = recorded.get("card") if key and key not in by_key else None
    if key in by_key and by_key[key] in flipped:
        goal = by_key[key]
    elif flipped and not explicit:
        goal = flipped[0]
    elif key and key in by_key:
        goal = by_key[key]
    elif recorded:
        goal = None
    else:
        goal = first_open(goals)  # no fire-start record: the goal it would have recorded
    status = (DONE if goal["done"] else IN_REVIEW) if goal else None
    duration = args.duration if args.duration is not None else "?"
    first = _first_line(args.out, cfg["auth"]) if args.out else ""
    if goal:
        outcome = ("the goal is checked off: Done" if goal["done"] else
                   "the goal is still open: In review" if args.rc == 0 else
                   "the fire failed or timed out; the goal is still open: In review")
        notes[goal["key"]] = (f"**Last fire:** fire {args.fire} ended rc={args.rc} after {duration}s - "
                              f"{outcome}." + (f" {first}" if first else ""))
    write_state(cfg["loop_dir"], dict(state, last_fire=notes))
    board, pid, ids, counts, status_ids = mirror(cfg, goals, goal["key"] if goal else None, status, notes=notes, state=state,
                                                 cue=agent_cue(cfg, goals, state, "fire-end"), hold=running_goals(state, args.fire))
    write_state(cfg["loop_dir"], dict(state, last_fire=notes))
    transcript = _result_text(args.out, cfg["auth"]) if args.out else "(no transcript)"
    if goal:
        message = (f"**Fire {args.fire}** of the autonomy loop ended rc={args.rc} after {duration}s - {outcome}."
                   f"\n\nResult (the end of {args.out or 'the transcript'}):\n\n```text\n{transcript}\n```")
        board.comment(str(uuid.uuid5(NS, f"{pid}:fire:{args.fire}:{args.started}:end")), ids[goal["key"]], message)
    summary = _summary(head, goal, status, counts) + (f", rc={args.rc} commented" if goal else "")
    if orphan in counts["retired"]:
        # the fire worked on a default goal, and the goals file exists now (a fire creates it when a Slack message
        # states a goal): the loop fires on that file from now on, and the default goal's card, Cancelled by the
        # mirror above, keeps this fire's result
        board.comment(str(uuid.uuid5(NS, f"{pid}:fire:{args.fire}:{args.started}:end")), orphan,
                      f"**Fire {args.fire}** of the autonomy loop ended rc={args.rc} after {duration}s, and the goals "
                      f"file {cfg['goals']} exists now: the loop fires on that file from now on, so this card of the "
                      f"default goals is Cancelled.\n\nResult (the end of {args.out or 'the transcript'}):\n\n"
                      f"```text\n{transcript}\n```")
        summary += f"; fire {args.fire}'s result is on the card of the default goal '{_short(key)}'"
    elif orphan:
        # the goal this fire started on is no longer in the file: its card keeps the history, In review
        board.update_issue(orphan, {"status_id": status_ids[IN_REVIEW]})
        board.comment(str(uuid.uuid5(NS, f"{pid}:fire:{args.fire}:{args.started}:orphan")), orphan,
                      f"**Fire {args.fire}** started on this goal, and its text is no longer in {cfg['goals']} "
                      f"(renamed or removed during the fire; rc={args.rc} after {duration}s). This card is not "
                      f"mirrored any more: In review.\n\nResult (the end of {args.out or 'the transcript'}):\n\n"
                      f"```text\n{transcript}\n```")
        summary += f"; the card of the renamed or removed goal '{_short(key)}' -> In review"
    return summary


def seed(cfg, goals, notes, state=None):
    """sync, tried again every 2s while the board does not answer, for up to KANBAN_SEED_WAIT seconds: at container
    start the board's sidecars can still be starting, or the agent not yet on the board server's network. Returns
    the counts."""
    try:
        wait = int(os.environ.get("KANBAN_SEED_WAIT", "300"))
    except ValueError:
        raise SyncError(4, "KANBAN_SEED_WAIT must be a whole number of seconds")
    deadline = time.monotonic() + wait
    said = False
    while True:
        try:
            return mirror(cfg, goals, keep_open=True, notes=notes, state=state, cue=agent_cue(cfg, goals, state or {}))[3]
        except SyncError as e:
            if e.code != 2:
                raise  # a refused login or a bad setting: waiting does not help
            if time.monotonic() >= deadline:
                raise SyncError(2, f"{e} - still, after waiting {wait}s (KANBAN_SEED_WAIT)")
            if not said:
                print(f"kanban-sync: seed: {e} - trying again every 2s for up to {wait}s", file=sys.stderr)
                said = True
        time.sleep(2)  # nosemgrep: arbitrary-sleep -- retry interval of a bounded wait for the board


def main():
    ap = argparse.ArgumentParser(description="Mirror the autonomy loop's goals and fires on the kanban board.")
    ap.add_argument("action", choices=["sync", "seed", "fire-start", "fire-end", "watch"])
    ap.add_argument("--fire", type=int)
    ap.add_argument("--started", type=int, help="the fire's start time, epoch seconds")
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
                print(f"kanban-sync: cannot remove {path}: {e}", file=sys.stderr)
    rc = act(args)
    if args.done:
        sys.stdout.flush()  # its last line is in its log before the file says it ended
        sys.stderr.flush()
        try:
            with open(f"{args.done}.tmp", "w") as f:
                f.write(f"{rc}\n")
            os.replace(f"{args.done}.tmp", args.done)  # whole or not at all for whoever polls for it
        except OSError as e:
            print(f"kanban-sync: cannot write {args.done}: {e}", file=sys.stderr)
    return rc


def _carry(state):
    """What every state write keeps: the two-way sync's baseline, the aliases, the project name this script set, the
    records of the fires still running."""
    return {k: state.get(k) for k in ("mirrored", "aliases", "project_name", "known_cards", "retired_cards", "fires")
            if state.get(k) is not None}


def load_goals(cfg):
    """The goals the loop fires on: the goals file, else the shipped default goals (sets cfg source/default)."""
    goals = parse_goals(cfg["goals"])
    cfg["source"], cfg["default"] = cfg["goals"], False
    if goals is None:
        default_goals = parse_goals(cfg["default_goals"])
        if default_goals is not None:
            goals, cfg["source"], cfg["default"] = default_goals, cfg["default_goals"], True
    return goals


def project_display_name(cfg):
    """KANBAN_PROJECT_NAME, else the goals file's first '# ' heading, else '<repository> goals'."""
    name = os.environ.get("KANBAN_PROJECT_NAME", "").strip()
    if name:
        return name[:120]
    try:
        with open(cfg["goals"], encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"^#\s+(\S.*?)\s*$", line)
                if m:
                    return m.group(1)[:120]
                if line.strip():
                    break
    except OSError:
        pass
    return "do-agent-aws goals"


def pull_from_board(cfg, goals, state):
    """Log in, read the project's cards, write the board's changes into the goals file (pull above), post the
    comments it asks for. Returns (changed, [summary lines]). SyncError 2 when the board does not answer."""
    board = Board(cfg["url"])
    board.login(*load_login(cfg["auth"]))
    pid = project_id(cfg["project"])
    if board.project(pid) is None:
        return False, []
    status_ids = board.statuses(pid)
    if DONE not in status_ids:
        return False, []
    existing = board.issues(pid)
    changed, changes, comments = pull(cfg, board, pid, goals, state, status_ids, existing)
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    for iid, text in comments:
        board.comment(str(uuid.uuid5(NS, f"{pid}:pull:{iid}:{day}:{text[:40]}")), iid, text)
    write_state(cfg["loop_dir"], state)
    return changed, changes


def loop_is_firing(loop_dir):
    try:
        with open(os.path.join(loop_dir, "loop.state")) as f:
            return f.read().split(" ", 1)[0] == "FIRING"
    except OSError:
        return False


def watch(cfg):
    """Sync every KANBAN_WATCH_INTERVAL seconds while the loop is not firing; a failing sync is logged and tried again."""
    try:
        interval = max(5, int(os.environ.get("KANBAN_WATCH_INTERVAL", "30")))
    except ValueError:
        raise SyncError(4, "KANBAN_WATCH_INTERVAL must be a whole number of seconds")
    print(f"watch: the board and {cfg['goals']} every {interval}s while the loop is not firing", flush=True)
    while True:
        if not loop_is_firing(cfg["loop_dir"]):
            try:
                state = read_state(cfg["loop_dir"])
                notes = state.get("last_fire") or {}
                goals = load_goals(cfg)
                changed, changes = pull_from_board(cfg, goals, state)
                if changed:
                    print("watch: from the board: " + "; ".join(changes), flush=True)
                    goals = load_goals(cfg)
                mirror(cfg, goals or [], keep_open=True, notes=notes, state=state, cue=agent_cue(cfg, goals or [], state))
                write_state(cfg["loop_dir"], state)
            except SyncError as e:
                print(f"watch: {e}", file=sys.stderr, flush=True)
            except Exception as e:  # a board-side failure: logged, the watcher goes on
                print(f"watch: unexpected {type(e).__name__}: {str(e)[:300]}", file=sys.stderr, flush=True)
        time.sleep(interval)


def act(args):
    cfg = {
        "url": os.environ.get("KANBAN_BOARD_URL", ""),
        "auth": os.environ.get("KANBAN_AUTH_FILE", "/wd/kanban/kanban.env"),
        "project": os.environ.get("KANBAN_PROJECT", "do-agent-aws") or "do-agent-aws",
        "goals": os.environ.get("AUTONOMY_LOOP_GOALS", "/wd/goals/GOALS.md"),
        "default_goals": os.environ.get("AUTONOMY_LOOP_DEFAULT_GOALS", "/agent/goals-default.md"),
        "loop_dir": os.environ.get("AUTONOMY_LOOP_DIR", "/wd/loop"),
        "card_order": os.environ.get("KANBAN_CARD_ORDER", CARD_ORDERS[0]) or CARD_ORDERS[0],
    }
    cfg["project_name"] = project_display_name(cfg)
    try:
        if not cfg["url"]:
            raise SyncError(4, "KANBAN_BOARD_URL is not set (no board on this target)")
        if cfg["card_order"] not in CARD_ORDERS:
            raise SyncError(4, f"KANBAN_CARD_ORDER must be {CARD_ORDERS[0]} (the goals file's last goal on top of its "
                               f"column) or {CARD_ORDERS[1]} (the file's order), got {cfg['card_order']!r}")
        if args.action not in ("sync", "seed", "watch") and (args.fire is None or args.started is None):
            raise SyncError(4, f"{args.action} needs --fire and --started")
        if args.action == "watch":
            return watch(cfg)
        goals = load_goals(cfg)
        head = args.action if args.action in ("sync", "seed") else f"fire {args.fire} {args.action[5:]}"
        # the last fire of each goal, kept across calls and shown in its card's description (the board's
        # issue panel can leave its comment list loading on plain HTTP; the description always renders)
        state = read_state(cfg["loop_dir"])
        notes = state.get("last_fire") or {}
        if args.action in ("sync", "seed", "fire-start"):
            # the board's changes reach the goals file BEFORE the file is mirrored or fired on (best effort: a board
            # that does not answer here fails or is retried below exactly as before)
            try:
                changed, changes = pull_from_board(cfg, goals, state)
            except SyncError as e:
                if e.code != 2:
                    raise
                changed, changes = False, []
            if changed:
                print(f"{head}: from the board: " + "; ".join(changes))
                goals = load_goals(cfg)
        if args.action == "seed":
            # the project and its columns even without any goals file: the board's first view is the agent's project
            counts = seed(cfg, goals or [], notes, state)
            write_state(cfg["loop_dir"], state)
            print(_summary(head, None, None, counts))
            return 0
        if goals is None:
            if args.action == "fire-start":
                write_state(cfg["loop_dir"], dict(_carry(state), fire=args.fire, started=args.started, goal=None,
                                                  card=None, done_before=[], last_fire=notes))
            print(f"{head}: no goals file {cfg['goals']} (nor the default goals {cfg['default_goals']}) - nothing to mirror")
            return 0
        if args.action == "sync":
            _, _, _, counts, _ = mirror(cfg, goals, keep_open=True, notes=notes, state=state, cue=agent_cue(cfg, goals, state))
            write_state(cfg["loop_dir"], state)
            print(_summary(head, None, None, counts))
            return 0
        if args.action == "fire-start":
            goal_key_arg = getattr(args, "goal_key", None) or None  # a caller built before the option has no attribute
            goal, note = pick_goal(goals, goal_key_arg)
            # recorded BEFORE the board is called: a board that fails here still leaves fire-end the right goal; the
            # records of the other fires still running (supervisor mode) carry over
            rec = {"goal": goal["key"] if goal else None, "started": args.started, "requested": goal_key_arg,
                   "card": issue_id_for(project_id(cfg["project"]), goal["key"], state) if goal else None,
                   "done_before": [g["key"] for g in goals if g["done"]]}
            fires = dict(state.get("fires") or {})
            fires[str(args.fire)] = rec
            fires = prune_fires(fires)  # this fire's record is the newest: always kept
            state = dict(_carry(state), fire=args.fire, started=args.started, goal=rec["goal"], card=rec["card"],
                         done_before=rec["done_before"], last_fire=notes, fires=fires)
            write_state(cfg["loop_dir"], state)
            _, _, ids, counts, _ = mirror(cfg, goals, goal["key"] if goal else None, IN_PROGRESS, notes=notes, state=state,
                                          cue=agent_cue(cfg, goals, state, "fire-start"), hold=running_goals(state, args.fire))
            if goal:
                state["card"] = rec["card"] = ids.get(goal["key"], state.get("card"))  # the card the mirror resolved (adopted, maybe)
            write_state(cfg["loop_dir"], state)
            print(_summary(head, goal, IN_PROGRESS, counts) + (f"; {note}" if note else ""))
            return 0
        print(fire_end(cfg, args, goals, state, notes))
        return 0
    except SyncError as e:
        print(f"kanban-sync: {e}", file=sys.stderr)
        return e.code
    except Exception as e:  # anything else is a board-side failure for the loop: logged, never fatal to a fire
        print(f"kanban-sync: unexpected {type(e).__name__}: {str(e)[:300]}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
