#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The harness's Hindsight session guard - Claude Code's Stop hook, registered next to Hindsight's own stop hook
(setup/install-hindsight.sh at build, /agent/hindsight-hooks-repair.sh at every start).

Why it exists: Hindsight's stop hook retains each session's transcript, and the memory service's model extracts the facts. The
transcript keeps the user's and the agent's words and the name of each tool call, never a tool's result, so every outcome in a
session record is the agent's own account - yet the extractor stored "which the agent loaded" for a package the user had only
asked to load, wrote records in German from an English session, and kept one fact twice; the session banks' knowledge pages,
refreshed every hour, failed again every five minutes once a refresh failed, and the Memory tile showed only a count.

One pass, for every session bank (the hooks' config bankId, else every bank whose id starts with the fixed part of its
bankIdTemplate, coding-agent:: by default):
  - every failed operation is logged once with its reason; a failed retain with a transient reason (throttling, a timeout, a
    5xx, a dropped connection) is re-queued, at most 3 times, 2, 8 and 32 minutes apart; a knowledge page whose refresh failed
    twice since its last good refresh has its schedule paused (its trigger's refresh_cron cleared, the cron kept), logged
    with the reason, and the cron put back once a refresh of the page succeeds;
  - every record a session retain stored (document conversation:<session>) is checked once: one that is only the transcript's
    REF-ID marker, one not in the memory service's output language (HINDSIGHT_API_LLM_OUTPUT_LANGUAGE, English by default; a
    count of each language's function words outside quotes, code and addresses, more than twice the output language's;
    or a non-Latin script) and one whose content equals a valid record of the bank are invalidated with the
    reason (reversible: the record moves to the bank's archive); one that states the agent's own action is rewritten as
    "The agent said: <text>" with the context "agent claim, not verified; session <id>; <time>"; one that opens with the
    user's request and goes on with the agent's account of an outcome keeps its text and gets the same context.
  - its own calls are retried on a 5xx, a 429 or a timeout (3 attempts) inside the pass's budget (HINDSIGHT_GUARD_BUDGET,
    20 s), and every failure of an API that answers is counted and logged (when nothing listens, the pass ends at once
    and writes nothing); a stage that fails does not skip the other, and the pass's state
    is saved whatever ends it.
Events go to ${UI_DIR}/hindsight-memory-guard.jsonl (one JSON object per line) and the counts the Memory tile shows to
${UI_DIR}/hindsight-memory-guard.state (key=value lines), both only when UI_DIR exists; what it has seen and when a retry is
due to HINDSIGHT_GUARD_STATE. As a hook it reads the event on stdin, runs at most one pass per 20 s, prints nothing and exits 0
on every error (a Stop hook's output can block the stop). --once runs a pass now and prints one summary line.
Settings: HINDSIGHT_API_URL (else the config's apiUrl, else http://127.0.0.1:8888), HINDSIGHT_HOOKS_CONFIG (default
~/.hindsight/coding-agent.json), HINDSIGHT_BANK_ID, HINDSIGHT_API_LLM_OUTPUT_LANGUAGE, HINDSIGHT_GUARD_STATE (default
~/.hindsight/session-guard.json), UI_DIR (default /wd/ui); HINDSIGHT_SESSION_GUARD=false, HINDSIGHT_DISABLE_HOOKS or
HINDSIGHT_DISABLED set: nothing."""
import fcntl
import hashlib
import json
import os
import re
import signal
import socket
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

DEFAULT_TEMPLATE = "coding-agent::{gitProject}"
CLAIM_PREFIX = "The agent said: "
CLAIM_CONTEXT = "agent claim, not verified"
MIN_INTERVAL = 20
PASS_BUDGET = 20
LANGUAGE_CODES = {"english": "en", "en": "en", "german": "de", "deutsch": "de", "de": "de", "french": "fr", "francais": "fr",
                  "français": "fr", "fr": "fr", "spanish": "es", "espanol": "es", "español": "es", "es": "es", "italian": "it",
                  "italiano": "it", "it": "it", "portuguese": "pt", "portugues": "pt", "português": "pt", "pt": "pt",
                  "dutch": "nl", "nederlands": "nl", "nl": "nl"}
FUNCTION_WORDS = {
    "en": "the and of to is are was were with for on that this it as by be from at an or not has have had which in its their "
          "after before into when then than there been will would should can could does did but also only you our we they",
    "de": "der das und ist nicht mit den dem ein eine einer einen eines zu für auf wurde wurden werden wird sich "
          "auch nur oder aber sind bei nach wie noch kann muss über zum zur vom durch dass diese dieser",
    "fr": "le la les une pour dans que qui pas sur avec sont mais aux cette ces être été elle nous",
    "es": "el los las que una por para como más pero sus este esta está fue muy entre",
    "it": "gli della delle dei degli che una sono nel nella alla questo questa anche più",
    "pt": "uma não para que das foi são mais pelo pela como mas seu sua",
    "nl": "het een dat niet voor zijn ook bij naar worden wordt deze wat",
}
FUNCTION_WORDS = {code: set(words.split()) for code, words in FUNCTION_WORDS.items()}
AGENT_ACTION = re.compile(
    r"\b(?:the agent|agent|the assistant|assistant|claude code|claude|i)\s+(?:has\s+|have\s+|had\s+|was\s+|successfully\s+|then\s+)?"
    r"(?:loaded|created|installed|connected|configured|fixed|deployed|ran|executed|set up|set|completed|verified|pushed|merged|"
    r"updated|added|removed|deleted|built|started|stopped|restarted|cloned|wrote|edited|changed|tested|confirmed|enabled|"
    r"disabled|uploaded|downloaded|applied|resolved|found|checked|ingested|imported|exported|published|sent|posted|opened|"
    r"closed|registered|corrected)\b", re.I)
PASSIVE_OUTCOME = re.compile(
    r"\b(?:was|were|has been|have been)\s+(?:successfully\s+)?"
    r"(?:loaded|created|installed|connected|configured|fixed|deployed|executed|set up|completed|verified|pushed|merged|updated|"
    r"added|removed|deleted|built|started|stopped|restarted|cloned|written|edited|changed|tested|confirmed|enabled|disabled|"
    r"uploaded|downloaded|applied|resolved|ingested|imported|exported|published|sent|posted|opened|closed|registered|"
    r"corrected)\b", re.I)
AGENT_WORDED = re.compile(r"(?:the\s+)?(?:agent|assistant|claude code|claude)\s+(?:said|says|reported|reports|claimed|claims|stated|states)\b", re.I)
USER_WORDED = re.compile(r"(?:the\s+)?user\b", re.I)
QUOTED = re.compile(r"\"[^\"]*\"|“[^”]*”|„[^“”]*[“”]|«[^»]*»|(?<!\w)'[^']+'(?!\w)|‘[^’]*’|‚[^‘’]*[‘’]|‹[^›]*›|»[^«]*«|›[^‹]*‹|「[^」]*」|『[^』]*』")
NOT_WORDS = re.compile(r"`[^`]*`|\b[a-z][a-z0-9+.-]*://\S+|(?:[\w-]+\.)+[a-z]{2,}(?::\d+)?(?:/\S*)?|\S*/\S*", re.I)
# an action of the agent's that the user asks about or reports is the user's words, not the agent's account
ASKED_IF = re.compile(r"\b(?:whether|if|what|how|why|when|where|(?:reported|reports|said|says|noted|notes|mentioned|mentions|stated|states|confirmed|confirms|claimed|claims|wrote|writes|explained|explains)(?:\s+that)?)\s*$", re.I)
USER_REPORTS = re.compile(r"(?:the\s+)?user\s+(?:reported|reports|said|says|noted|notes|mentioned|mentions|stated|states|confirmed|confirms|claimed|claims|wrote|writes|explained|explains)\b", re.I)
REQUEST_END = re.compile(r"[,;:]\s+|\s+(?:and then|then|after which|and)\s+", re.I)
MARKER_ONLY = re.compile(r"REF-ID:\s*\S+(?:\s+was mentioned on [^|]*?)?\.?(?:\s*\|.*)?", re.I)
TRANSIENT = re.compile(r"throttl|too many requests|rate exceeded|timed? ?out|temporar|unavailable|connection|reset by peer|"
                       r"overloaded|internal server error|\b50[0234]\b", re.I)
RETRY_DELAYS = (120, 480, 1920)


def language_code(name):
    """The code of a language name (English, Deutsch, fr, ...); None for one the function-word count does not know."""
    return LANGUAGE_CODES.get(str(name or "").strip().lower())


def counted_text(text):
    """The part of a text its language is told by: without code spans, URLs, host and file names or paths, and without
    quotes unless the text is nothing but quotes (a record in one language may quote or address another)."""
    plain = NOT_WORDS.sub(" ", str(text or ""))
    outside = QUOTED.sub(" ", plain)
    return outside if re.search(r"[^\W\d_]", outside) else plain


def script_of(text):
    """The main other script (cyrillic, cjk, hiragana, greek, arabic, ...) of a text whose letters are less than half Latin,
    at 8 letters or more; None otherwise. The function-word lists know Latin-script languages only."""
    letters = [c for c in str(text or "") if c.isalpha()]
    if len(letters) < 8:
        return None
    scripts = {}
    for c in letters:
        name = unicodedata.name(c, "")
        scripts[name.split(" ")[0] if name else "?"] = scripts.get(name.split(" ")[0] if name else "?", 0) + 1
    if scripts.get("LATIN", 0) * 2 >= len(letters):   # mostly Latin letters: its function words tell its language
        return None
    return max((s for s in scripts if s != "LATIN"), key=lambda s: scripts[s]).lower()


def language_hits(text):
    words = re.findall(r"[^\W\d_]+", counted_text(text).lower())
    return {code: sum(1 for w in words if w in fw) for code, fw in FUNCTION_WORDS.items()}


def language_of(text):
    """The language a text is in: a non-Latin script, or the language whose function words it holds most of, at least 3
    of them; None when none does."""
    script = script_of(counted_text(text))
    if script:
        return script
    hits = language_hits(text)
    best = max(hits, key=lambda code: hits[code])
    return best if hits[best] >= 3 and list(hits.values()).count(hits[best]) == 1 else None


def wrong_language(text, want):
    """The language a text is in when it is not want (a code): a non-Latin script, or at least 3 function words of another
    language and more than twice as many as of want; else None."""
    if not want:
        return None
    script = script_of(counted_text(text))
    if script:
        return script
    hits = language_hits(text)
    best = max(hits, key=lambda code: hits[code])
    if best == want or hits[best] < 3 or hits[best] <= 2 * hits.get(want, 0) or list(hits.values()).count(hits[best]) > 1:
        return None
    return best


def content_key(text):
    """What two records saying the same thing share: the text before " | " (the extractor appends When/Involving/why
    parts), without the claim prefix, the articles (the, a, an) and the final full stop, in lower case with its blanks
    collapsed: "The user asked the agent to load X." and "User asked agent to load X | When: ..." are one content."""
    t = re.sub(r"\s+", " ", str(text or "")).strip()
    if t.startswith(CLAIM_PREFIX):
        t = t[len(CLAIM_PREFIX):]
    t = t.split(" | ")[0].strip().rstrip(".").strip().lower()
    t = re.sub(r"\s+", " ", re.sub(r"\b(?:the|a|an)\b", " ", t)).strip()
    return hashlib.sha256(t.encode("utf-8")).hexdigest()


def is_marker(text):
    """A record that is only the transcript's first line, "REF-ID: <document>", and nothing it says."""
    return bool(MARKER_ONLY.fullmatch(re.sub(r"\s+", " ", str(text or "")).strip()))


def claim_kind(unit):
    """"worded" for a record that already says it is the agent's account ("The agent said ..."), "claim" for one that states
    the agent's own action as a fact (fact type experience, "the agent/assistant/Claude/I <did> ...", "... was <done>"),
    "outcome" for a record that opens with the user's words and also states an action of the agent's ("The user asked to
    load X which the agent loaded") or, after the request clause, a passive outcome ("..., which was loaded"), but not an
    action the user asks about ("whether/what/how/why/when/where the agent ...") or reports ("The user reported that the
    agent ...", "The user reported: the build was fixed"), None for the user's words alone and anything else."""
    text = re.sub(r"\s+", " ", str(unit.get("text") or "")).strip()
    if text.startswith(CLAIM_PREFIX) or AGENT_WORDED.match(text):
        return "worded"
    if USER_WORDED.match(text):   # the request is the user's; an action of the agent's in it is the agent's account
        if next((m for m in AGENT_ACTION.finditer(text) if not ASKED_IF.search(text[:m.start()])), None):
            return "outcome"
        after = REQUEST_END.split(text, 1)[1:]   # an outcome after the request clause, unless the user reports it
        return "outcome" if after and not USER_REPORTS.match(text) and PASSIVE_OUTCOME.search(after[0]) else None
    if unit.get("fact_type") == "experience" or AGENT_ACTION.search(text) or PASSIVE_OUTCOME.search(text):
        return "claim"
    return None


def short_reason(error):
    """The part of an error message that says what went wrong: its last ": " part up to the first ", ", "; " or ". "."""
    msg = re.sub(r"\s+", " ", str(error or "")).strip()
    if not msg:
        return "no reason given"
    tail = re.split(r"[,;] |\. ", msg.split(": ")[-1])[0].strip().rstrip(".")
    return (tail or msg)[:120]


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value):
    try:
        t = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


class ApiDown(Exception):
    """The memory API does not answer at all: nothing to check in this pass."""


class ApiFailed(Exception):
    """A call failed after its retries, or with an answer it cannot be retried for."""


class Guard:
    def __init__(self, api, state_path, ui_dir, want):
        self.api, self.state_path, self.ui_dir, self.want = api.rstrip("/"), state_path, ui_dir, want
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            self.budget = float(os.environ.get("HINDSIGHT_GUARD_BUDGET") or PASS_BUDGET)
        except ValueError:
            self.budget = float(PASS_BUDGET)
        self.deadline = time.time() + self.budget
        self.reached, self.out_of_budget, self.banks_seen = False, False, []
        try:
            with open(state_path, encoding="utf-8") as f:
                self.state = json.load(f)
        except (OSError, ValueError):
            self.state = {}
        if not isinstance(self.state, dict):
            self.state = {}
        self.counts = self.state.setdefault("counts", {})
        self.banks = self.state.setdefault("banks", {})

    # --- the record of what happened ---
    def count(self, name, n=1):
        self.counts[name] = self.counts.get(name, 0) + n

    def event(self, kind, bank, **fields):
        if not os.path.isdir(self.ui_dir):
            return
        path = os.path.join(self.ui_dir, "hindsight-memory-guard.jsonl")
        try:
            if os.path.getsize(path) > 2 * 1024 * 1024:   # one older generation is kept
                os.replace(path, path + ".1")
        except OSError:
            pass
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": now_iso(), "kind": kind, "bank": bank, **fields}) + "\n")

    def save(self, banks_seen):
        """The guard's state always; the counts the Memory tile shows only when the pass reached the memory API."""
        tmp = self.state_path + ".tmp"
        os.makedirs(os.path.dirname(self.state_path) or ".", exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.state, f)
        os.replace(tmp, self.state_path)
        if not os.path.isdir(self.ui_dir) or not self.reached:
            return
        keys = ("failed_logged", "retried", "paused_pages", "rejected_language", "rejected_duplicate", "rejected_marker",
                "claims_marked", "api_errors", "errors")
        lines = ["updated_at=" + now_iso(), "language=" + (self.want or "none"), "banks=" + ",".join(banks_seen)]
        shown = dict(self.counts)   # the pages paused now: a page whose schedule came back no longer counts
        shown["paused_pages"] = sum(len(m.get("paused") or {}) for m in self.banks.values() if isinstance(m, dict))
        lines += ["%s=%d" % (k, shown.get(k, 0)) for k in keys]
        path = os.path.join(self.ui_dir, "hindsight-memory-guard.state")
        with open(path + ".tmp", "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(path + ".tmp", path)

    # --- the memory API ---
    def call(self, method, path, body=None, bank=""):
        """One API call inside the pass's budget: each attempt's timeout is the time left (at most 8 s); a 5xx, a 429 or a
        timeout is retried (3 attempts, 0.5 s and 1 s apart) while time is left; every failed attempt is counted and logged.
        Returns the decoded answer, None on a 404; raises ApiDown when nothing listens, ApiFailed otherwise (a spent budget
        included, logged once a pass)."""
        data = json.dumps(body).encode("utf-8") if body is not None else None
        name = "%s %s" % (method, path.split("?")[0])
        for attempt in (1, 2, 3):
            left = self.deadline - time.time()
            if left < 0.5:
                if not self.out_of_budget:   # the next pass carries on where this one stopped
                    self.out_of_budget = True
                    self.event("budget", bank, call=name, reason="the pass's %g s budget is spent" % self.budget)
                raise ApiFailed("%s: the pass's budget is spent" % name)
            req = urllib.request.Request(self.api + path, data=data, method=method, headers={"Content-Type": "application/json"})
            try:
                with self.opener.open(req, timeout=min(8.0, left)) as resp:
                    raw = resp.read()
                self.reached = True
                return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                self.reached = True
                if e.code == 404:
                    return None
                status, reason = e.code, "HTTP %d" % e.code
                if e.code < 500 and e.code != 429:   # not worth a retry, but counted and logged like every failure
                    self.count("api_errors")
                    self.event("api", bank, call=name, status=status, reason=reason, attempt=attempt, outcome="gave up")
                    raise ApiFailed("%s -> HTTP %d" % (name, e.code))
            except urllib.error.URLError as e:
                if isinstance(e.reason, ConnectionRefusedError):
                    raise ApiDown(str(e.reason))
                status, reason = None, "timeout" if isinstance(e.reason, (socket.timeout, TimeoutError)) else str(e.reason)
            except (socket.timeout, TimeoutError):
                status, reason = None, "timeout"
            except ConnectionRefusedError as e:
                raise ApiDown(str(e))
            except (ConnectionError, ValueError) as e:
                status, reason = None, str(e)
            last = attempt == 3 or self.deadline - time.time() < 0.5 + 0.5 * attempt
            self.count("api_errors")
            self.event("api", bank, call=name, status=status, reason=reason, attempt=attempt, outcome="gave up" if last else "retrying")
            if last:
                raise ApiFailed("%s: %s" % (name, reason))
            time.sleep(0.5 * attempt)

    def bank_path(self, bank, rest):
        return "/v1/default/banks/" + urllib.parse.quote(bank, safe="") + rest

    # --- failed operations ---
    def failures(self, bank, mem):
        listed = self.call("GET", self.bank_path(bank, "/operations?status=failed&limit=100"), bank=bank) or {}
        ops = sorted(listed.get("operations") or [], key=lambda o: str(o.get("created_at") or ""))
        seen = mem.setdefault("failed_seen", [])
        retries = mem.setdefault("retries", {})
        refresh_fails = mem.setdefault("refresh_fails", {})
        detail_failures = mem.setdefault("detail_failures", {})
        detail_reads = 0
        for op in ops:
            oid, kind, error = str(op.get("id") or ""), str(op.get("task_type") or ""), op.get("error_message")
            if not oid:
                continue
            if oid not in seen:
                page = None
                if kind == "refresh_mental_model" and detail_reads < 20:   # the page a refresh was for is only in its record
                    detail_reads += 1
                    try:
                        full = self.call("GET", self.bank_path(bank, "/operations/" + urllib.parse.quote(oid)), bank=bank) or {}
                    except ApiFailed:
                        if self.out_of_budget:
                            raise
                        tries = detail_failures[oid] = detail_failures.get(oid, 0) + 1
                        if tries < 3:   # left for the next pass, without holding up the operations after it
                            continue
                        full = {}   # its third failed read: logged without its page, so it stops coming back
                    meta = full.get("result_metadata") or {}
                    match = re.search(r"mental_model_id=([\w-]+)", str(error or ""))
                    mm = meta.get("mental_model_id") or (match.group(1) if match else None)
                    page = meta.get("name")
                    if mm and not any(len(f) > 2 and f[2] == oid for f in refresh_fails.get(mm, [])):   # once per operation
                        refresh_fails.setdefault(mm, []).append([str(op.get("created_at") or ""), short_reason(error), oid])
                self.event("failed", bank, op=oid, type=kind, reason=short_reason(error), error=str(error or "")[:400],
                           at=op.get("created_at"), **({"page": page} if page else {}))
                seen.append(oid)   # only once logged: a detail read that fails leaves it for the next pass
                detail_failures.pop(oid, None)
                self.count("failed_logged")
            if kind in ("retain", "batch_retain") and TRANSIENT.search(str(error or "")):
                r = retries.setdefault(oid, {"n": 0, "next": 0})
                if r["n"] < len(RETRY_DELAYS) and time.time() >= r["next"]:
                    self.call("POST", self.bank_path(bank, "/operations/%s/retry" % urllib.parse.quote(oid)), bank=bank)
                    r["n"] += 1
                    r["next"] = time.time() + RETRY_DELAYS[r["n"] - 1]
                    self.count("retried")
                    self.event("retry", bank, op=oid, attempt=r["n"], reason=short_reason(error))
        del seen[:-2000]
        failed_now = {str(op.get("id") or "") for op in ops}
        for oid in [o for o in retries if o not in failed_now]:   # no longer failed: re-queued and done, or deleted
            del retries[oid]
        for oid in [o for o in detail_failures if o not in failed_now]:
            del detail_failures[oid]
        paused = mem.setdefault("paused", {})
        for mm in sorted(set(refresh_fails) | set(paused)):
            self.page_check(bank, mm, refresh_fails, paused)

    def page_check(self, bank, mm, refresh_fails, paused):
        """A page whose refresh failed twice since its last good refresh (and since the guard last paused it) is re-queued by
        the memory service every five minutes and fails again: its schedule is paused, the cron kept in the guard's state.
        A paused page whose refresh then succeeds (a refresh by hand) gets its cron back; one whose schedule is back already
        (Hindsight's page sync, or a person) is left alone. Failures older than the page's last good refresh are dropped, and
        the page with them when none is left."""
        path = self.bank_path(bank, "/mental-models/" + urllib.parse.quote(mm))
        page = self.call("GET", path, bank=bank)
        if not page:   # the page is gone
            refresh_fails.pop(mm, None)
            paused.pop(mm, None)
            return
        trigger = page.get("trigger") or {}
        last_ok = parse_time(page.get("last_refreshed_at"))
        p = paused.get(mm)
        if isinstance(p, str):   # a pause recorded before the cron was kept
            p = paused[mm] = {"at": p, "cron": None}
        if p and trigger.get("refresh_cron"):
            del paused[mm]
            p = None
        elif p and p.get("cron") and last_ok and parse_time(p.get("at")) and last_ok > parse_time(p["at"]):
            self.call("PATCH", path, {"trigger": {"refresh_cron": p["cron"],
                                                  "refresh_after_consolidation": bool(p.get("after_consolidation"))}}, bank=bank)
            del paused[mm]
            self.count("resumed_pages")
            self.event("resumed", bank, page=page.get("name") or mm, mental_model_id=mm, schedule=p["cron"])
            p = None   # its old failures are older than the good refresh: pruned below
        since = [t for t in (last_ok, parse_time(p.get("at")) if p else None) if t]
        fails = [f for f in refresh_fails.get(mm, []) if parse_time(f[0]) and all(parse_time(f[0]) > t for t in since)]
        if fails:
            refresh_fails[mm] = fails[-20:]
        else:
            refresh_fails.pop(mm, None)
        if p or len(fails) < 2 or not trigger.get("refresh_cron"):
            return
        self.call("PATCH", path, {"trigger": {"refresh_cron": None, "refresh_after_consolidation": False}}, bank=bank)
        paused[mm] = {"at": now_iso(), "cron": trigger.get("refresh_cron"),
                      "after_consolidation": bool(trigger.get("refresh_after_consolidation"))}
        self.count("paused_pages")
        self.event("paused", bank, page=page.get("name") or mm, mental_model_id=mm, reason=fails[-1][1], failures=len(fails),
                   schedule=trigger.get("refresh_cron"))

    # --- the records a session retain stored ---
    def records(self, bank, mem):
        done = mem.setdefault("ops_checked", [])
        docs, offset = [], 0
        # The completed retains, newest first, every page up to 1000 retains a pass. The scan does not stop at the first one
        # already checked: a retain completes out of creation order (a re-queued one, a backlog), so a new completion can
        # sit behind retains checked before.
        while offset < 1000:
            listed = self.call("GET", self.bank_path(bank, "/operations?status=completed&type=retain&limit=100&offset=%d" % offset),
                               bank=bank) or {}
            page = listed.get("operations") or []
            for op in page:
                doc, oid = str(op.get("document_id") or ""), str(op.get("id") or "")
                if op.get("task_type") in ("retain", "batch_retain") and doc.startswith("conversation:") and oid not in done:
                    docs.append((oid, doc))
            if len(page) < 100:
                break
            offset += 100
        if not docs:
            return
        keys = mem.get("keys")
        if keys is None:   # the bank's records as they are, the oldest one per content, before any new one is checked
            oldest = {}
            for unit in self.units(bank, ""):
                if unit.get("fact_type") in ("world", "experience") and unit.get("id"):
                    key, rank = content_key(unit.get("text")), (str(unit.get("mentioned_at") or ""), str(unit["id"]))
                    if key not in oldest or rank < oldest[key]:
                        oldest[key] = rank
            keys = mem["keys"] = {key: rank[1] for key, rank in oldest.items()}
        checked = mem.setdefault("units_checked", [])
        for oid, doc in docs:
            if time.time() > self.deadline:
                break
            for unit in self.units(bank, doc):
                uid = str(unit.get("id") or "")
                if uid and uid not in checked:
                    self.check(bank, unit, keys)
                    checked.append(uid)
            done.append(oid)
        del done[:-2000]
        del checked[:-5000]
        for key in list(keys)[:-5000]:   # the newest 5000 contents; a repeat of an older one goes unseen
            del keys[key]

    def units(self, bank, doc):
        out, offset = [], 0
        while offset < 2000:
            q = "?limit=200&offset=%d" % offset + ("&document_id=" + urllib.parse.quote(doc, safe="") if doc else "")
            page = (self.call("GET", self.bank_path(bank, "/memories/list" + q), bank=bank) or {}).get("items") or []
            out += page
            if len(page) < 200:
                break
            offset += 200
        return out

    def check(self, bank, unit, keys):
        uid, text = unit["id"], str(unit.get("text") or "")
        doc = str(unit.get("document_id") or "")
        sid = doc.split(":", 1)[1] if doc.startswith("conversation:") else str((unit.get("metadata") or {}).get("session_id") or "unknown")
        lang = wrong_language(text, self.want)
        reason = None
        if is_marker(text):
            reason, counter = "no content: the transcript's REF-ID marker", "rejected_marker"
        elif lang:
            reason, counter = "language: %s, not %s" % (lang, self.want), "rejected_language"
        else:
            key = content_key(text)
            older = keys.get(key)
            found = self.call("GET", self.bank_path(bank, "/memories/" + urllib.parse.quote(older)), bank=bank) if older and older != uid else None
            if found and found.get("state") != "invalidated":   # the read falls back to the archive
                reason, counter = "duplicate of %s" % older, "rejected_duplicate"
            else:
                keys[key] = uid
        if reason:
            self.call("PATCH", self.bank_path(bank, "/memories/" + urllib.parse.quote(uid)), {"state": "invalidated", "reason": reason}, bank=bank)
            self.count(counter)
            self.event("rejected", bank, record=uid, session=sid, reason=reason, text=text[:200])
            return
        kind = claim_kind(unit)
        if kind and CLAIM_CONTEXT not in str(unit.get("context") or ""):
            patch = {"context": "%s; session %s; %s" % (CLAIM_CONTEXT, sid, str(unit.get("mentioned_at") or "")[:19])}
            if kind == "claim":
                patch["text"] = CLAIM_PREFIX + text
            self.call("PATCH", self.bank_path(bank, "/memories/" + urllib.parse.quote(uid)), patch, bank=bank)
            self.count("claims_marked")
            self.event("claim", bank, record=uid, session=sid, text=text[:200])

    def run(self, cfg):
        listed = self.call("GET", "/v1/default/banks?limit=200") or {}
        names = [str(b.get("bank_id")) for b in listed.get("banks") or [] if isinstance(b, dict) and b.get("bank_id")]
        banks = session_banks(cfg, names)
        for bank in banks:
            if time.time() > self.deadline:
                break
            self.banks_seen.append(bank)
            mem = self.banks.setdefault(bank, {})
            for stage in (self.failures, self.records):   # a stage that fails does not skip the other
                try:
                    stage(bank, mem)
                except ApiFailed:   # counted and logged by call(); the next pass carries on where this one stopped
                    pass
        return banks


def read_config(path):
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return {}
    return cfg if isinstance(cfg, dict) else {}


def session_banks(cfg, names):
    """The banks session write-backs go to: HINDSIGHT_BANK_ID or the config's bankId, else every bank whose id starts with
    the fixed part of the bankIdTemplate (coding-agent:: by default) - never every bank when the template has none."""
    bank = os.environ.get("HINDSIGHT_BANK_ID") or cfg.get("bankId")
    if bank:
        return [b for b in names if b == str(bank)]
    prefix = str(os.environ.get("HINDSIGHT_BANK_ID_TEMPLATE") or cfg.get("bankIdTemplate") or DEFAULT_TEMPLATE).split("{")[0]
    return [b for b in names if prefix and b.startswith(prefix)]


def main(once):
    if os.environ.get("HINDSIGHT_DISABLE_HOOKS") or os.environ.get("HINDSIGHT_DISABLED") or os.environ.get("HINDSIGHT_SESSION_GUARD", "true") == "false":
        return ""
    if not once:
        sys.stdin.read()   # the hook event: the pass is the same for every session
    home = os.environ.get("HOME", "/home/agent")
    cfg = read_config(os.environ.get("HINDSIGHT_HOOKS_CONFIG") or os.path.join(home, ".hindsight", "coding-agent.json"))
    api = str(os.environ.get("HINDSIGHT_API_URL") or cfg.get("apiUrl") or "http://127.0.0.1:8888")
    api = re.sub(r"^(https?://)localhost(?=[:/]|$)", r"\g<1>127.0.0.1", api)   # the API listens on IPv4
    state_path = os.environ.get("HINDSIGHT_GUARD_STATE") or os.path.join(home, ".hindsight", "session-guard.json")
    os.makedirs(os.path.dirname(state_path) or ".", exist_ok=True)
    with open(state_path + ".lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return "hindsight session guard: another pass is running"
        guard = Guard(api, state_path, os.environ.get("UI_DIR") or "/wd/ui",
                      language_code(os.environ.get("HINDSIGHT_API_LLM_OUTPUT_LANGUAGE") or "English"))
        if not once and time.time() - float(guard.state.get("last_pass") or 0) < MIN_INTERVAL:
            return ""
        guard.state["last_pass"] = time.time()   # first: the throttle holds whatever ends this pass
        try:
            guard.run(cfg)
        except (ApiDown, ApiFailed) as e:
            return "hindsight session guard: the memory API did not answer (%s)" % e
        except Exception as e:   # not expected: counted and logged, and what the pass did is still saved
            guard.count("errors")
            guard.event("error", "", reason="%s: %s" % (type(e).__name__, str(e)[:300]))
            raise
        finally:   # also on SIGTERM (the hook's timeout), which ends the pass through SystemExit
            guard.save(guard.banks_seen)
    c = guard.counts
    return ("hindsight session guard: %d session bank(s); %d failed operation(s) logged, %d retried, %d page(s) paused; %d record(s) "
            "set aside (%d language, %d duplicate, %d marker), %d agent claim(s) marked" % (
                len(guard.banks_seen), c.get("failed_logged", 0), c.get("retried", 0), c.get("paused_pages", 0),
                c.get("rejected_language", 0) + c.get("rejected_duplicate", 0) + c.get("rejected_marker", 0),
                c.get("rejected_language", 0), c.get("rejected_duplicate", 0), c.get("rejected_marker", 0), c.get("claims_marked", 0)))


if __name__ == "__main__":
    once = "--once" in sys.argv[1:]
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))   # the hook's timeout: the pass ends through its finally
    try:
        line = main(once)
        if once and line:
            print(line)
    except Exception as e:   # a hook that fails the stop is worse than a stop without the check
        if once:
            print("hindsight session guard: %s" % e, file=sys.stderr)
    sys.exit(0)
