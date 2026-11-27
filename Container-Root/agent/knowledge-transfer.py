#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Knowledge transfer (docs/manual/memory.md "Moving knowledge between instances", docs/knowledge-sharing.md): one pack file out of
this harness's knowledge stores, and the same pack into another harness's - on the Knowledge transfer page (the home
proxy's /knowledge/, linked from the Memory tile) or from the command line.

The stores are the two the agent's knowledge lives in:
  loglearner  the LogLearner bank the PreToolUse hook delivers from and /agent/recall.sh searches (INSTINCTS_JSON, one
              record per line): the default knowledge every start loads and every rule /agent/learn.sh banked
  hindsight   the memory API's banks (127.0.0.1:UI_PORT_HINDSIGHT_API): each bank's documents with the facts extracted
              from them, moved by the API's own document transfer - the same facts, embedded again where they land and
              never extracted again, so neither an export nor an import calls a model
An export takes the stores and banks ticked, narrowed by a tag, a range of days and a search (a LogLearner record whose
id or title holds the text - a record without a title: the start of its rule -, a Hindsight document whose id does: the
memory API's own filter), or exactly the records a list names by id; a selection naming no store takes both, or the
LogLearner bank alone where the memory API is off. Unless the selection names records or switches
defaults on (the page's Include box, --include-defaults), this image's own default knowledge stays out - the records of
its packs (the packs it ships in LOGLEARNER_PACKS_DIR, by their manifests' names, and the seed-* packs) and its seed
banks' documents: every harness of the image already has them, and an older image's copy would replace a newer one
where the pack is imported; a check names such records in a pack. A pack has the shape /agent/loglearner-packs.sh
loads: <name>.jsonl (the LogLearner records as the bank holds them), <name>.hindsight.jsonl (one Hindsight document per
line, with its bank) when it holds any, and <name>.manifest.json (name, version, as_of, records, per file its store,
record count and sha256, where the pack comes from - the image's build stamp, the memory API's version - and what the
scrub gate ran with; the LogLearner file's sha256 is also the manifest's own sha256, the one the runtime's loader and
loglearner-pull.sh read). The download is one .tar.gz of those files. A rule this harness banked itself (a record
without a pack) travels as <id>-<the 10 hex digits of its rule's arm>:
learn.sh numbers rules per bank (kb-0001, ...) and a pack record replaces the bank's record of the same id, so a plain
kb-0001 would replace another harness's own kb-0001.

An import checks every file against the manifest before anything is written and loads nothing anywhere when one differs
(fail-closed). It then loads the LogLearner file with the runtime's loader the way loglearner-packs.sh does (python3 -m
loglearner.pack ingest --manifest: the same bytes again are a no-op, a record already in the bank is skipped), keeps the
pack in KNOWLEDGE_IMPORTED_DIR (default /wd/knowledge/imported; a pack of the same name is replaced) and posts each bank's
documents to the memory API's document-transfer import with the on_conflict chosen: skip (the default: a document the
bank already has is left as it is), replace, or new-id (imported beside it under a new id). A preview runs the same
checks and says what an import would do, writing nothing: the runtime's loader on a copy of the bank, and per Hindsight
bank the documents it already has. Every start loads the kept packs again after the defaults: loglearner-packs.sh their
LogLearner files, and `knowledge-transfer.py load` (startup.sh, in the background) their Hindsight files with
on_conflict=skip, so an import survives a restart, a new memory database and an emptied bank. knowledge-files.py verify
never touches that directory (it owns KNOWLEDGE_DIR/defaults only).

Every export passes the LogLearner runtime's export gate (loglearner.export_gate.scrub_bundle, the gate of the
dashboard's /export) before a byte of it is written: all of the scrub config LOGLEARNER_SCRUB_CONFIG names, or the
runtime's state/scrub-patterns.json (replacements, numbered classes, detectors); without one, the detectors of the
runtime's shipped config - secret shapes only, never its example replacement values. The runtime's built-in
home-directory classes apply either way, except to the image's own service accounts' homes (IMAGE_HOMES: the
container's layout, not a person's home, as seed/scan.py treats them). A detector hit refuses the whole export and names each record and class, never
the value (fail-closed); so do a pattern left after the scrub, a line the scrub broke, a LOGLEARNER_SCRUB_CONFIG that is
not a file, and a manifest whose bank names or missions a class matches.

Usage:
  knowledge-transfer.py serve [--port PORT]   the Knowledge transfer page on 127.0.0.1 (UI_PORT_KNOWLEDGE, default 8097)
  knowledge-transfer.py records [--search TEXT] [--store S]... [--bank BANK]... [--limit N]   the page's record finder
  knowledge-transfer.py export OUT.tar.gz [--name NAME] [--store loglearner|hindsight]... [--bank BANK]... [--tag TAG]
                        [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--search TEXT] [--id ID]... [--include-defaults]
  knowledge-transfer.py preview PACK.tar.gz   check, and say what an import would do; writes nothing
  knowledge-transfer.py import PACK.tar.gz [--on-conflict skip|replace|new-id]   check, load into both stores, keep
  knowledge-transfer.py load                  the start step: the Hindsight files of the kept packs
Each prints one JSON object. Exit 0 on success, 1 when a store could not be read or written, 2 for a refused pack, a
refused export or a wrong argument. The page's actions are bounded by KNOWLEDGE_REQUEST_BUDGET (840 s, inside the home
proxy's 900 s): one that runs past it is refused with that reason; a shell's command has no such bound.
"""
import argparse
import glob
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# The http(s) URLs this script builds itself go through one opener, with the scheme checked first: file: or any other
# scheme is refused before a request is made (the urllib default would open it)
_HTTP_OPENER = urllib.request.build_opener()


def http_open(req, timeout):
    """urllib.request.urlopen for an http or https URL (or Request) only; ValueError for any other scheme."""
    url = req.full_url if isinstance(req, urllib.request.Request) else req
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise ValueError("refusing a non-http(s) URL: %r" % (url,))
    return _HTTP_OPENER.open(req, timeout=timeout)

E = os.environ
LOGLEARNER_DIR = E.get("LOGLEARNER_DIR", "/opt/loglearner")
BANKS_DIR = E.get("LOGLEARNER_BANKS_DIR", os.path.join(E.get("LOGLEARNER_STATE", "/wd/loglearner"), "banks"))
INSTINCTS_JSON = E.get("INSTINCTS_JSON", os.path.join(BANKS_DIR, "global", "instincts.jsonl"))
API = "http://127.0.0.1:%s" % E.get("UI_PORT_HINDSIGHT_API", "8888")
HINDSIGHT = E.get("UI_HINDSIGHT", "true") != "false"
IMPORTED = E.get("KNOWLEDGE_IMPORTED_DIR", os.path.join(E.get("KNOWLEDGE_DIR", "/wd/knowledge"), "imported"))
# pack name -> the sha256 of its Hindsight file (a start's load leaves a pack alone while that matches and every one of
# its documents is in its bank, by id) and each bank's count at the load, for the record
STAMP = os.path.join(IMPORTED, ".loaded.json")
PAGE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "knowledge-view")
PORT = int(E.get("UI_PORT_KNOWLEDGE", "8097"))


def env_int(name, default):
    """A whole-number setting above 0, or its default when the value is not one: 0 would refuse every pack while the home
    proxy reads 0 as no limit (home-render.sh treats KNOWLEDGE_PACK_MAX alike)."""
    try:
        value = int(E.get(name) or default)
    except ValueError:
        return default
    return value if value > 0 else default


# bytes of an uploaded pack (the .tar.gz): the home proxy's client_max_body_size for /knowledge/ is the same setting
MAX_PACK = env_int("KNOWLEDGE_PACK_MAX", 64 << 20)
MAX_FILE = env_int("KNOWLEDGE_PACK_MAX_FILE", 512 << 20)           # bytes of one file in it, unpacked
# bytes of all its files together, unpacked: four times the upload limit unless set, so one upload cannot unpack into
# the per-file cap in memory
MAX_UNPACKED = env_int("KNOWLEDGE_PACK_MAX_UNPACKED", 4 * MAX_PACK)
OP_WAIT = float(E.get("KNOWLEDGE_OP_WAIT", "600"))    # seconds one export or import operation of the memory API may take
API_WAIT = float(E.get("KNOWLEDGE_API_WAIT", "300"))  # load: seconds to wait for the memory API to answer
# seconds one page request (an export, a check, an import) may take: inside the home proxy's proxy_read_timeout of 900 s
# for /knowledge/ (home-render.sh), so a long run is refused with its reason instead of ending in the proxy's 504
BUDGET = float(E.get("KNOWLEDGE_REQUEST_BUDGET", "840"))
# bytes of the export's X-Knowledge-Pack summary header: the home proxy reads a response's headers into a 4 KB buffer
HEADER_MAX = env_int("KNOWLEDGE_HEADER_MAX", 3000)
# this image's own default knowledge, which every harness of the image already has (left out of an export by default):
# the shipped packs loglearner-packs.sh loads (their manifests' names) and the seed banks hindsight-seed.sh posts
PACKS_DIR = E.get("LOGLEARNER_PACKS_DIR", "/opt/loglearner-packs")
SEED_DIR = E.get("HINDSIGHT_SEED_DIR") or E.get("LOGLEARNER_SEED_DIR") or "/seed"
STORES = ("loglearner", "hindsight")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")   # no dot: <name>.hindsight.jsonl must not be another pack's file
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$")
DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
CONFLICT = ("skip", "replace", "new-id")   # the memory API's on_conflict choices for an import; skip is the default
# the image's own service accounts' homes (seed/scan.py TREE_IMAGE_USERS): the container's layout, not a person's home -
# a default record names the memory API's data directory under the hindsight user's - so the scrub gate leaves them be
IMAGE_HOMES = ("/home/hindsight",)
MAX_RECORDS = 5000        # records an export may name by id
MAX_SEARCH = 200          # characters of a search
FIND_LIMIT = 25           # the finder's records per store and bank by default; 200 at most
ID_QUERY_MAX = 6000       # bytes of an export's document_id query: past it the bank is exported whole and filtered here
INSTALLED = ".installed-packs.json"   # the runtime loader's install ledger beside the bank (loglearner.pack.INSTALLED_FILE)


class Refused(Exception):
    """A pack or a request that is not loaded; str() is the reason the page and the command line show."""


class BudgetSpent(Refused):
    """The running page request's time budget (KNOWLEDGE_REQUEST_BUDGET) is spent: a refusal, which an import that has
    already loaded and kept its pack answers as kept for the next start instead."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def shown(text):
    """A name from a pack as it may appear in a message: [A-Za-z0-9._-] kept, the rest '?', 80 at most."""
    return re.sub(r"[^A-Za-z0-9._-]", "?", str(text))[:80]


def image_packs():
    """The names of the packs this image ships: the name each manifest in LOGLEARNER_PACKS_DIR gives (the packs
    loglearner-packs.sh loads)."""
    packs = set()
    for path in glob.glob(os.path.join(PACKS_DIR, "*.manifest.json")):
        try:
            with open(path, encoding="utf-8") as f:
                name = json.load(f).get("name")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(name, str) and name:
            packs.add(name)
    return packs


def check_name(name):
    own = image_packs()
    if not NAME_RE.match(name) or name.startswith("seed-") or name in own:
        raise Refused("the pack name '%s' is not allowed: lower-case letters, digits, '_' and '-', 64 at most, and not "
                      "seed-* or the name of a pack this image ships (%s): those are the image's own packs"
                      % (shown(name), ", ".join(sorted(own)) or "none here"))


# ---------------------------------------------------------------- the stores, read
def bank_rows():
    """The LogLearner bank's records (JSON objects, in file order) and the number of lines that are not one."""
    rows, bad = [], 0
    try:
        with open(INSTINCTS_JSON, encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    r = None
                if isinstance(r, dict):
                    rows.append(r)
                else:
                    bad += 1
    except FileNotFoundError:
        pass
    return rows, bad


REQUEST = threading.local()   # .end: the running page request's deadline (Handler.do_POST); unset from a shell


def time_left(cap):
    """cap, or what is left of the running page request's budget when that is less; BudgetSpent, a refusal, once it is
    spent (a shell's command has no such bound)."""
    end = getattr(REQUEST, "end", None)
    if end is None:
        return cap
    left = end - time.time()
    if left < 1:
        raise BudgetSpent("the request ran past its %d s budget (KNOWLEDGE_REQUEST_BUDGET, inside the home proxy's 900 s): pick "
                          "fewer banks or records, or run it in a shell in the container (knowledge-transfer.py), which has no "
                          "such bound" % BUDGET)
    return min(cap, left)


def api(method, path, data=None, ctype="application/json", timeout=60):
    """The memory API's answer to one request, as bytes. An HTTP error is a RuntimeError carrying the API's own detail;
    an API that does not answer raises urllib's URLError (or OSError)."""
    req = urllib.request.Request(API + path, data=data, method=method, headers={"Content-Type": ctype} if data is not None else {})
    try:
        with http_open(req, time_left(timeout)) as r:
            if getattr(REQUEST, "end", None) is None:
                return r.read()
            # a page request: read what has arrived (read1, at most one socket read) and check its budget each time, since
            # each socket read has its own timeout and a slow but steady download would otherwise outlast the budget
            parts = []
            while True:
                part = r.read1(1 << 16)
                if not part:
                    return b"".join(parts)
                parts.append(part)
                time_left(1)
    except urllib.error.HTTPError as e:
        detail = e.read()[:300].decode("utf-8", errors="replace")
        raise RuntimeError("the memory API answered HTTP %d to %s %s: %s" % (e.code, method, path.split("?")[0], detail)) from None


def api_json(method, path, body=None, timeout=60):
    raw = api(method, path, None if body is None else json.dumps(body).encode(), timeout=timeout)
    return json.loads(raw or b"{}")


def bank_path(bank, rest=""):
    return "/v1/default/banks/%s%s" % (urllib.parse.quote(bank, safe=""), rest)


def hindsight_banks(counts=True, timeout=60):
    """Every bank the memory API lists: [{id, name, mission, documents}], documents from its stats read fresh."""
    out, offset = [], 0
    while True:
        page = api_json("GET", "/v1/default/banks?limit=200&offset=%d" % offset, timeout=timeout)
        got = [b for b in page.get("banks") or [] if isinstance(b, dict) and b.get("bank_id")]
        for b in got:
            n = None
            if counts:
                st = api_json("GET", bank_path(b["bank_id"], "/stats?refresh=true"), timeout=timeout)
                n = int(st.get("total_documents") or 0)
            out.append({"id": b["bank_id"], "name": b.get("name") or "", "mission": b.get("mission") or "", "documents": n})
        offset += len(got)
        if len(got) < 200:
            return out


def wait_op(bank, op):
    """The memory API's operation once it completed; RuntimeError when it failed or did not finish within OP_WAIT, Refused
    when the page request's budget ended first."""
    deadline = time.time() + time_left(OP_WAIT)
    while True:
        st = api_json("GET", bank_path(bank, "/operations/%s" % urllib.parse.quote(str(op), safe="")))
        if st.get("status") == "completed":
            return st
        if st.get("status") in ("failed", "cancelled", "not_found"):
            raise RuntimeError("the memory API's %s operation on bank %s ended %s: %s" % (
                st.get("operation_type") or "transfer", bank, st.get("status"), str(st.get("error_message") or "")[:300]))
        if time.time() > deadline:
            time_left(1)   # the page request's budget: Refused when that is what ended the wait
            raise RuntimeError("the memory API's operation on bank %s did not finish within %ds (still %s)" % (
                bank, OP_WAIT, st.get("status")))
        time.sleep(0.5)  # nosemgrep: arbitrary-sleep -- poll interval of a bounded wait for the memory API


# ---------------------------------------------------------------- export
def selection(d):
    """A checked selection from the page's JSON or the command line's options; raises Refused."""
    if not isinstance(d, dict):
        raise Refused("the selection must be a JSON object")
    # no store named: both, or the LogLearner bank alone on a harness with the memory API off (UI_HINDSIGHT=false)
    stores = d.get("stores") or (list(STORES) if HINDSIGHT else ["loglearner"])
    if not isinstance(stores, list) or not stores or any(s not in STORES for s in stores):
        raise Refused("stores must name loglearner, hindsight or both")
    banks = d.get("banks")
    if banks is not None and (not isinstance(banks, list) or not all(isinstance(b, str) and b for b in banks)):
        raise Refused("banks must be a list of bank ids")
    out = {"stores": [s for s in STORES if s in stores], "banks": banks,
           "tag": str(d.get("tag") or "").strip().lower() or None, "name": str(d.get("name") or "knowledge").strip()}
    # this image's own default knowledge in the pack too (image_defaults): off unless asked for
    if not isinstance(d.get("defaults", False), bool):
        raise Refused("defaults must be true or false")
    out["defaults"] = d.get("defaults", False)
    for k in ("since", "until"):
        v = str(d.get(k) or "").strip() or None
        if v and not DAY_RE.match(v):
            raise Refused("%s must be a date, YYYY-MM-DD" % k)
        out[k] = v
    search = str(d.get("search") or "").strip()
    if len(search) > MAX_SEARCH:
        raise Refused("the search is %d characters; at most %d are taken" % (len(search), MAX_SEARCH))
    out["search"] = search.lower() or None
    # records named by id: the page's [{store, bank, id}] or the command line's bare ids (any store, any bank)
    recs = d.get("records")
    if recs is not None and (not isinstance(recs, list) or len(recs) > MAX_RECORDS):
        raise Refused("records must be a list of at most %d records" % MAX_RECORDS)
    clean = []
    for r in recs or []:
        r = {"id": r} if isinstance(r, str) else r
        if not isinstance(r, dict) or not isinstance(r.get("id"), str) or not r["id"].strip() or len(r["id"]) > 300:
            raise Refused("a record of the selection needs its id: a string of 300 characters at most")
        store, bank = r.get("store"), r.get("bank")
        if store is not None and store not in STORES:
            raise Refused("a record's store must be loglearner or hindsight")
        if bank is not None and (not isinstance(bank, str) or not bank or store == "loglearner"):
            raise Refused("a record's bank must be a Hindsight bank id")
        clean.append({"store": store, "bank": bank, "id": r["id"].strip()})
    out["records"] = clean or None
    if clean and None not in {r["store"] for r in clean}:
        out["stores"] = [s for s in out["stores"] if s in {r["store"] for r in clean}]
        if not out["stores"]:
            raise Refused("the records named are in no store of the selection")
    check_name(out["name"])
    return out


def record_name(r):
    """A record of a selection's list, as a message names it."""
    if r["store"] == "loglearner":
        return "LogLearner record %s" % shown(r["id"])
    if r["store"] == "hindsight":
        return "Hindsight %sdocument %s" % ("bank %s " % shown(r["bank"]) if r["bank"] else "", shown(r["id"]))
    return "record %s" % shown(r["id"])


def wanted(sel, store, bank, ids, found):
    """Whether a record (ids: its id as the store holds it and as it travels) is among the records the selection names -
    True when it names none - and each named record it is marked found."""
    if not sel["records"]:
        return True
    hit = False
    for i, r in enumerate(sel["records"]):
        if r["store"] in (None, store) and (store != "hindsight" or r["bank"] in (None, bank)) and r["id"] in ids:
            found[i] = hit = True
    return hit


def travelling(r):
    """A LogLearner record as it travels: a rule banked here (no pack) gets the runtime's arm of its rule in its id
    (loglearner.arms.arm_id_for_rule: ll-<sha1[:10]>_apply)."""
    if not isinstance(r.get("pack"), dict) and r.get("id") and isinstance(r.get("rule"), str):
        return dict(r, id="%s-%s" % (r["id"], hashlib.sha1(r["rule"].strip().encode(), usedforsecurity=False).hexdigest()[:10]))
    return r


def title_of(r):
    """A LogLearner record's title, or the first 120 characters of its rule's first line when it has none."""
    t = str(r.get("title") or "").strip()
    if not t and isinstance(r.get("rule"), str) and r["rule"].strip():
        t = r["rule"].strip().splitlines()[0][:120]
    return t


def image_defaults():
    """This image's own default knowledge, which every harness of the image already has: (the pack names its LogLearner
    records carry - the packs of LOGLEARNER_PACKS_DIR (image_packs); loglearner-packs.sh loads the seed banks as
    seed-<file> -, {seed bank: the document ids hindsight-seed.sh posts there, from SEED_DIR/<bank>.jsonl})."""
    packs = image_packs()
    seed = {}
    try:
        with open(os.path.join(SEED_DIR, "banks.json"), encoding="utf-8") as f:
            banks = json.load(f)
    except (OSError, ValueError):
        banks = {}
    for bank in banks if isinstance(banks, (dict, list)) else []:
        ids = set()
        try:
            with open(os.path.join(SEED_DIR, "%s.jsonl" % bank), encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        it = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(it, dict) and it.get("document_id"):
                        ids.add(str(it["document_id"]))
        except OSError:
            pass
        seed[str(bank)] = ids
    return packs, seed


def from_image(r, packs):
    """Whether a LogLearner record came from one of this image's own packs (image_defaults: the shipped packs, seed-*)."""
    pack = r.get("pack") if isinstance(r.get("pack"), dict) else {}
    name = str(pack.get("name") or "")
    return bool(name) and (name in packs or name.startswith("seed-"))


def matches(sel, texts):
    """Whether a search, when there is one, is in one of texts (case-insensitive)."""
    return not sel["search"] or any(sel["search"] in str(t).lower() for t in texts)


def picked(sel, tags, when):
    """Whether a record with these tags and this time (ISO; its day counts) is in the selection."""
    if sel["tag"] and sel["tag"] not in {str(t).strip().lower() for t in (tags if isinstance(tags, list) else [])}:
        return False
    if sel["since"] or sel["until"]:
        day = str(when or "")[:10]
        if not DAY_RE.match(day) or (sel["since"] and day < sel["since"]) or (sel["until"] and day > sel["until"]):
            return False
    return True


def loglearner_records(sel, found):
    """The bank's records in the selection, as the bank holds them, and how many of this image's own default records it
    left out; a rule banked here gets its arm in its id. A selection that names no record by id and does not switch
    defaults on leaves out the records of the image's own packs (the shipped packs, seed-*): every harness of the image has
    them, and an older image's copy would replace a newer one where the pack is imported."""
    rows, bad = bank_rows()
    packs = None if sel["defaults"] or sel["records"] else image_defaults()[0]
    out, left = [], 0
    for r in rows:
        pack = r.get("pack") if isinstance(r.get("pack"), dict) else None
        if not picked(sel, r.get("tags"), r.get("banked_at") or (pack or {}).get("ingested_at")):
            continue
        held = str(r.get("id") or "")
        r = travelling(r)
        ids = {held, str(r.get("id") or "")} - {""}
        if matches(sel, list(ids) + [title_of(r)]) and wanted(sel, "loglearner", None, ids, found):
            if packs is not None and from_image(r, packs):
                left += 1
                continue
            out.append(r)
    return out, bad, left


def ids_matching(bank, text):
    """The ids of a bank's documents whose id holds text (the memory API's own documents filter), 100 at most."""
    page = api_json("GET", bank_path(bank, "/documents?" + urllib.parse.urlencode({"q": text, "limit": 100})))
    return {str(i.get("id")) for i in page.get("items") or [] if isinstance(i, dict) and i.get("id") is not None}


def hindsight_documents(bank, sel, ids, found, drop=frozenset()):
    """One bank's documents in the selection, each with its bank, through the memory API's export (an operation that
    writes the bank's transfer archive into the API's file storage) and the archive's download; ids, when given, are
    the documents the export asks for (the API's document_id selection) instead of the whole bank; drop, the ids left
    out (this image's own seed documents)."""
    path = "/document-transfer/export"
    if ids:
        path += "?" + urllib.parse.urlencode([("document_id", i) for i in ids])
    sub = api_json("POST", bank_path(bank, path), {})
    meta = wait_op(bank, sub["operation_id"]).get("result_metadata") or {}
    raw = api("GET", "/v1/default/files/download/%s" % urllib.parse.quote(str(meta.get("storage_key") or ""), safe="/"),
              timeout=300)
    docs, schema = [], 1
    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        schema = json.loads(zf.read("manifest.json")).get("schema_version", 1)
        for n in sorted(x for x in zf.namelist() if x.startswith("documents/") and x.endswith(".json")):
            d = json.loads(zf.read(n))
            did = str(d.get("id") or "") if isinstance(d, dict) else ""
            if (isinstance(d, dict) and did not in drop and picked(sel, d.get("tags"), d.get("created_at")) and matches(sel, [did])
                    and wanted(sel, "hindsight", bank, {did}, found)):
                rec = {"bank": bank}
                rec.update(d)
                docs.append(rec)
    return docs, schema


def runtime():
    """The vendored LogLearner runtime's export gate and scrub engine (loglearner.export_gate, loglearner.scrub_core)."""
    if LOGLEARNER_DIR not in sys.path:
        sys.path.insert(0, LOGLEARNER_DIR)
    from loglearner import export_gate, scrub_core
    return export_gate, scrub_core


def scrub_config():
    """(the config the export gate runs with, "config" or "detectors", where it came from); Refused when none loads."""
    try:
        export_gate, scrub_core = runtime()
    except ImportError as e:
        raise Refused("the scrub gate cannot run: the LogLearner runtime's export gate is not under %s (%s); nothing was "
                      "exported" % (LOGLEARNER_DIR, str(e)[:120])) from None
    named = E.get("LOGLEARNER_SCRUB_CONFIG")
    try:
        if named:
            if not os.path.isfile(named):
                raise Refused("the scrub gate cannot run: LOGLEARNER_SCRUB_CONFIG names %s, which is not a file; nothing "
                              "was exported" % named)
            return scrub_core.load_config(named), "config", named
        found = export_gate.find_config(LOGLEARNER_DIR)
        if found:
            return scrub_core.load_config(found), "config", str(found)
        # no scrub config: the detectors the runtime ships (secret shapes), never its example replacement values
        example = os.path.join(LOGLEARNER_DIR, "config", "scrub-patterns.example.json")
        with open(example, encoding="utf-8") as f:
            detectors = json.load(f).get("detectors") or []
        if not detectors:
            raise ValueError("%s lists no detector" % example)
        with tempfile.TemporaryDirectory(prefix="knowledge-scrub-") as tmp:
            path = os.path.join(tmp, "detectors.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"detectors": detectors}, f)
            return scrub_core.load_config(path), "detectors", example
    except (OSError, ValueError, KeyError, TypeError, AttributeError, re.error) as e:
        raise Refused("the scrub gate cannot run: its config does not load (%s: %s); nothing was exported"
                      % (type(e).__name__, str(e)[:160])) from None


def gate(members):
    """members: [(file name, [record lines], [what each line is])] -> ([each file's bytes, scrubbed], the gate's
    summary, its config). Refused (nothing exported) on a detector hit - each record and class named, never the value -,
    a pattern left after the scrub, a line the scrub broke and a file the scrub would rename or leave out."""
    cfg, kind, where = scrub_config()
    export_gate, scrub_core = runtime()
    hits = []
    for _, lines, labels in members:
        for line, label in zip(lines, labels):
            hits += ["%s (%s)" % (label, cls) for cls, _, _ in scrub_core.detect(cfg, line, label)]
    if hits:
        raise Refused("the scrub gate blocked the export: %d possible secret(s), values not shown: %s%s. Nothing was "
                      "exported; edit or remove those records, or leave them out of the selection" % (
                          len(hits), "; ".join(hits[:12]), "; and %d more" % (len(hits) - 12) if len(hits) > 12 else ""))
    files = {name: "".join(l + "\n" for l in lines) for name, lines, _ in members}
    # the image's own service-account homes pass the scrub as tokens, first of every replacement, so the runtime's
    # built-in home-directory class cannot rewrite them; they come back unchanged after it
    keep = []
    for i, home in enumerate(IMAGE_HOMES):
        entry = {"class": "image-home", "regex": re.escape(home) + r"(?![A-Za-z0-9_.-])", "placeholder": "@@image-home-%d@@" % i}
        entry["_re"] = re.compile(entry["regex"])
        keep.append((home, entry["placeholder"], entry))
    shielded = dict(cfg, replacements=[e for _, _, e in keep] + list(cfg["replacements"]))
    try:
        out, done = export_gate.scrub_bundle(files, shielded)
    except export_gate.ExportBlocked as e:
        raise Refused("the scrub gate blocked the export: %s. Nothing was exported" % e) from None
    if set(out) != set(files):
        raise Refused("the scrub gate blocked the export: it would rename or leave out %s (a class of the scrub config "
                      "matches the pack's name, or its file_denylist names the file); choose another pack name"
                      % ", ".join(sorted(set(files) - set(out))))
    replaced = {}
    for entry in done:
        for cls, n in (entry.get("replacements") or {}).items():
            replaced[cls] = replaced.get(cls, 0) + n
    restored = 0
    for name in out:
        for home, token, _ in keep:
            restored += out[name].count(token)
            out[name] = out[name].replace(token, home)
    if restored != replaced.pop("image-home", 0):
        raise Refused("the scrub gate blocked the export: a class of the scrub config rewrote the image's own paths (%s); "
                      "nothing was exported" % ", ".join(IMAGE_HOMES))
    data = []
    for name, lines, _ in members:
        if sum(1 for l in out[name].splitlines() if l.strip()) != len(lines):
            raise Refused("the scrub gate blocked the export: the scrub changed the number of records in %s" % name)
        data.append(out[name].encode("utf-8"))
    return data, {"gate": kind, "classes": len(cfg["detectors"]), "replacements": replaced, "from": where}, cfg


def gate_manifest(cfg, text):
    """The manifest's own text (bank names and missions, a tag) through the gate's detectors and residual scan; Refused
    on a hit - the manifest is not rewritten."""
    _, scrub_core = runtime()
    hits = [cls for cls, _, _ in scrub_core.detect(cfg, text, "manifest")] + [cls for cls, _ in scrub_core.verify_clean(cfg, text)]
    if hits:
        raise Refused("the scrub gate blocked the export: the pack's manifest (its bank names and missions, its tag) matches "
                      "%s; nothing was exported" % ", ".join(sorted(set(hits))))


def source():
    """Where a pack comes from, as far as this container can tell: the image's build stamp (the Dockerfile's BUILD, the
    image's BUILD label) and the memory API's version."""
    out = {"harness": "do-agent-aws", "image_build": E.get("AGENT_BUILD") or None}
    if HINDSIGHT:
        try:
            out["memory_api"] = api_json("GET", "/version", timeout=10).get("api_version")
        except (urllib.error.URLError, OSError, ValueError, RuntimeError):
            out["memory_api"] = None
    return out


def hindsight_selection(sel, found):
    """(the selection's Hindsight documents, each with its bank; per bank their count, name and mission; the transfer
    schema; how many of this image's own seed documents it left out). A bank without documents is not exported: its
    export would only leave an empty archive in the API's storage. Records named by id are asked for by id (a bank they
    do not name: found through the API's own filter). Without the defaults switch and without records named, a seed
    bank's own documents (image_defaults) stay out: a seed bank holding nothing else is not exported at all."""
    listed = hindsight_banks()
    known = {b["id"]: b for b in listed}
    recs = [r for r in sel["records"] or [] if r["store"] in (None, "hindsight")]
    unknown = sorted({b for b in (sel["banks"] or []) + [r["bank"] for r in recs if r["bank"]] if b not in known})
    if unknown:
        raise Refused("no such bank here: %s" % ", ".join(shown(b) for b in unknown))
    ticked = [b["id"] for b in listed if (sel["banks"] is None or b["id"] in sel["banks"]) and b["documents"]]
    only = None   # bank -> the ids asked for there; None: every document of the ticked banks
    if sel["records"]:
        only = {}
        loose = [r for r in recs if not r["bank"]]
        if len(loose) > 100:
            raise Refused("%d ids name no bank: name the bank (--bank) for more than 100" % len(loose))
        for r in recs:
            if r["bank"]:
                only.setdefault(r["bank"], set()).add(r["id"])
        for r in loose:
            for b in ticked:
                if r["id"] in ids_matching(b, r["id"]):
                    only.setdefault(b, set()).add(r["id"])
    seed = None if sel["defaults"] or only is not None else image_defaults()[1]
    docs, banks, schema, left = [], {}, 1, 0
    for b in sorted(only) if only is not None else ticked:
        if not known[b]["documents"]:
            continue
        ids = sorted(only[b]) if only is not None else None
        drop = frozenset()
        if seed is not None and seed.get(b):
            have = bank_document_ids(b)
            drop = frozenset(have & seed[b])
            if not (sel["tag"] or sel["since"] or sel["until"] or sel["search"]):
                # counted only when no filter narrows the selection: which seed documents a filter would have kept is
                # not known without exporting them
                left += len(drop)
            ids = sorted(have - drop)
            if not ids:
                continue
        asked = ids if ids and len(ids) <= 200 and len(urllib.parse.urlencode([("document_id", i) for i in ids])) <= ID_QUERY_MAX else None
        got, schema = hindsight_documents(b, sel, asked, found, drop)
        if got:
            docs += got
            banks[b] = {"records": len(got), "name": known[b]["name"], "mission": known[b]["mission"]}
    return docs, banks, schema, left


def export_pack(sel):
    """(the pack's .tar.gz bytes, its manifest, the scrub gate's summary) for a selection; Refused when it holds no
    record, names a record it does not hold, or the scrub gate blocks it."""
    found = [False] * len(sel["records"] or [])
    members, entries = [], []   # (file name, its lines, what each line is); its manifest entry
    left = {}                   # store -> this image's own default records the selection left out
    if "loglearner" in sel["stores"]:
        rows, _, left["loglearner"] = loglearner_records(sel, found)
        if rows:
            members.append((sel["name"] + ".jsonl", [json.dumps(r, ensure_ascii=False) for r in rows],
                            ["LogLearner record %s" % shown(r.get("id")) for r in rows]))
            entries.append({"path": sel["name"] + ".jsonl", "store": "loglearner", "records": len(rows)})
    if "hindsight" in sel["stores"]:
        if not HINDSIGHT:
            raise Refused("the memory API is off on this harness (UI_HINDSIGHT=false): untick the Hindsight banks")
        docs, banks, schema, left["hindsight"] = hindsight_selection(sel, found)
        if docs:
            members.append((sel["name"] + ".hindsight.jsonl", [json.dumps(d, ensure_ascii=False) for d in docs],
                            ["Hindsight bank %s document %s" % (shown(d["bank"]), shown(d.get("id"))) for d in docs]))
            entries.append({"path": sel["name"] + ".hindsight.jsonl", "store": "hindsight", "records": len(docs),
                            "transfer_schema": schema, "banks": banks})
    missing = [r for r, ok in zip(sel["records"] or [], found) if not ok]
    if missing:
        raise Refused("not in the selection: %s%s (an id is matched exactly; a tag, a range of days or a search can leave a "
                      "record out)" % ("; ".join(record_name(r) for r in missing[:10]),
                                       "; and %d more" % (len(missing) - 10) if len(missing) > 10 else ""))
    left = {k: v for k, v in left.items() if v}
    if not members:
        if left:
            raise Refused("nothing to export: the selection holds only this image's own default knowledge (%s), which every "
                          "harness of the image already has; tick Include this image's default knowledge (export "
                          "--include-defaults) to export it anyway" % ", ".join("%s %d" % (k, v) for k, v in sorted(left.items())))
        raise Refused("nothing to export: the selection holds no record")
    data, scrub, cfg = gate(members)
    files = []
    for entry, blob in zip(entries, data):
        f = {k: entry[k] for k in ("path", "store", "records")}
        f["sha256"] = sha256(blob)
        f.update({k: v for k, v in entry.items() if k not in f})
        files.append(f)
    members = [(f["path"], blob) for f, blob in zip(files, data)]
    now = time.gmtime()
    manifest = {"name": sel["name"], "version": time.strftime("%Y%m%dT%H%M%SZ", now), "as_of": time.strftime("%Y-%m-%d", now)}
    if files[0]["store"] == "loglearner":
        manifest["sha256"] = files[0]["sha256"]
    manifest.update({
        "records": sum(f["records"] for f in files), "files": files,
        "selection": dict({k: sel[k] for k in ("stores", "banks", "tag", "since", "until", "defaults")},
                          search=bool(sel["search"]), records=len(sel["records"] or [])),
        "source": source(),
        "scrub": {k: scrub[k] for k in ("gate", "classes", "replacements")},
        "left_out_defaults": left,
        "about": "Knowledge exported from an do-agent-aws harness (its Knowledge transfer page). %s.jsonl holds LogLearner "
                 "records in the bank's own schema; %s.hindsight.jsonl, when present, Hindsight documents with their "
                 "extracted facts, one per line with its bank. Import it on the Knowledge transfer page of another harness: "
                 "every file is checked against its sha256 here first." % (sel["name"], sel["name"])})
    text = json.dumps(manifest, indent=1) + "\n"
    gate_manifest(cfg, text)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, blob in members + [(sel["name"] + ".manifest.json", text.encode())]:
            ti = tarfile.TarInfo(name)
            ti.size, ti.mtime, ti.mode = len(blob), int(time.time()), 0o644
            tf.addfile(ti, io.BytesIO(blob))
    return buf.getvalue(), manifest, scrub


# ---------------------------------------------------------------- import
def lines_of(name, data):
    """The JSON objects of a pack file, one per non-empty line; Refused at the first line that is not one."""
    out = []
    for n, line in enumerate(data.decode("utf-8", errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except ValueError:
            r = None
        if not isinstance(r, dict):
            raise Refused("%s line %d is not a JSON object" % (shown(name), n))
        out.append(r)
    return out


def read_pack(blob):
    """(manifest, {file name: bytes}, {store: the manifest's entry}) of a pack's .tar.gz, every file checked against the
    manifest - its sha256 and its record count; raises Refused."""
    if len(blob) > MAX_PACK:
        raise Refused("the pack is %d bytes; at most %d are taken (KNOWLEDGE_PACK_MAX)" % (len(blob), MAX_PACK))
    files, total = {}, 0
    try:
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
            for member in tf:
                if not member.isreg() or "/" in member.name or "\\" in member.name or member.name.startswith("."):
                    raise Refused("not a pack: %s is not a plain file at the top of the archive" % shown(member.name))
                if member.size > MAX_FILE or len(files) >= 3 or member.name in files:
                    raise Refused("not a pack: more files, a larger file or a file twice (%s)" % shown(member.name))
                total += member.size
                if total > MAX_UNPACKED:
                    raise Refused("not a pack: its files unpack to more than %d bytes together (KNOWLEDGE_PACK_MAX_UNPACKED)"
                                  % MAX_UNPACKED)
                files[member.name] = tf.extractfile(member).read()
    except (tarfile.TarError, OSError, EOFError, zlib.error) as e:
        raise Refused("not a pack: the file is not a .tar.gz this page wrote (%s)" % str(e)[:120])
    manifests = [n for n in files if n.endswith(".manifest.json")]
    if len(manifests) != 1:
        raise Refused("not a pack: it holds %d manifests, one is expected" % len(manifests))
    try:
        m = json.loads(files[manifests[0]])
    except ValueError:
        raise Refused("not a pack: %s is not JSON" % shown(manifests[0])) from None
    if not isinstance(m, dict):
        raise Refused("not a pack: the manifest is not a JSON object")
    name = str(m.get("name") or "")
    check_name(name)
    if manifests[0] != name + ".manifest.json":
        raise Refused("not a pack: the manifest %s names the pack '%s'" % (shown(manifests[0]), shown(name)))
    if not VERSION_RE.match(str(m.get("version") or "")):
        raise Refused("not a pack: the manifest carries no version")
    want = {"loglearner": name + ".jsonl", "hindsight": name + ".hindsight.jsonl"}
    seen = {}
    for f in m.get("files") if isinstance(m.get("files"), list) else []:
        store = f.get("store") if isinstance(f, dict) else None
        if store not in want or f.get("path") != want[store] or store in seen:
            raise Refused("not a pack: the manifest's file list names %s" % shown(json.dumps(f)[:60]))
        seen[store] = f
    if not seen or set(files) != {manifests[0]} | {f["path"] for f in seen.values()}:
        raise Refused("not a pack: the archive holds %s, the manifest lists %s" % (
            ", ".join(shown(n) for n in sorted(files)), ", ".join(shown(f["path"]) for f in seen.values()) or "no file"))
    for store, f in seen.items():
        data = files[f["path"]]
        if sha256(data) != str(f.get("sha256") or "").lower():
            raise Refused("%s: its sha256 does not match the manifest's - the pack is refused and nothing was loaded"
                          % shown(f["path"]))
        recs = lines_of(f["path"], data)
        if len(recs) != f.get("records"):
            raise Refused("%s holds %d records, its manifest says %s" % (shown(f["path"]), len(recs), shown(f.get("records"))))
        if store == "hindsight":
            check_hindsight_entry(f, recs)
    if "sha256" in m and ("loglearner" not in seen or str(m["sha256"]).lower() != seen["loglearner"]["sha256"]):
        raise Refused("not a pack: the manifest's sha256 is not its LogLearner file's")
    return m, files, seen


def check_hindsight_entry(f, recs):
    """The types an import and a start's load rely on, before anything is written: the entry's transfer_schema a whole
    number, its banks a map of bank id to {records, name, mission} that agrees with the documents, and every document
    its bank and its id as text, its facts, chunks and tags lists. Refused naming the first that is not."""
    path = shown(f["path"])
    schema = f.get("transfer_schema", 1)
    if isinstance(schema, bool) or not isinstance(schema, int) or schema < 1:
        raise Refused("not a pack: the manifest's transfer_schema for %s is not a whole number" % path)
    banks = f.get("banks", {})
    if not isinstance(banks, dict) or not all(isinstance(k, str) and k and isinstance(v, dict) for k, v in banks.items()):
        raise Refused("not a pack: the manifest's banks for %s is not a map of bank ids to their name and mission" % path)
    for k, v in banks.items():
        if any(v.get(x) is not None and not isinstance(v[x], str) for x in ("name", "mission")):
            raise Refused("not a pack: the manifest gives bank %s a name or mission that is not text" % shown(k))
    per = {}
    for r in recs:
        if not (isinstance(r.get("bank"), str) and r["bank"] and isinstance(r.get("id"), str) and r["id"]):
            raise Refused("%s: every document needs its bank and its id" % path)
        for x in ("facts", "chunks", "tags"):
            if r.get(x) is not None and not isinstance(r[x], list):
                raise Refused("%s: document %s: its %s is not a list" % (path, shown(r["id"]), x))
        per[r["bank"]] = per.get(r["bank"], 0) + 1
    if banks and {k: v.get("records") for k, v in banks.items()} != per:
        raise Refused("not a pack: the manifest's banks for %s do not count its documents" % path)


def linked(path):
    """Where path really is, when it resolves through a link below its top-level directory; None otherwise (the
    knowledge-files.py rule: a /wd that is itself a link is the host's layout)."""
    path = os.path.abspath(path)
    parts = path.strip("/").split("/")
    real = os.path.realpath(path)
    return real if real != os.path.join(os.path.realpath("/" + parts[0]), *parts[1:]) else None


def write_bytes(path, data):
    """data at path through a fresh temporary name in its directory and a rename: a link at path is replaced, never
    written through."""
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def load_loglearner(path, manifest_path, name, version, bank=None):
    """The runtime's loader on a pack's LogLearner file (loglearner-packs.sh's call) into the bank (default
    INSTINCTS_JSON): its JSON summary; Refused when it refuses the pack. Bounded by its own 300 s, not by the page
    request's budget: the budget bounds the memory API's work, which comes after it."""
    bank = bank or INSTINCTS_JSON
    os.makedirs(os.path.dirname(bank), exist_ok=True)
    r = subprocess.run([sys.executable, "-m", "loglearner.pack", "ingest", "--pack", path, "--bank", bank,  # nosemgrep: dangerous-subprocess-use-audit, dangerous-subprocess-use-tainted-env-args -- argv list run without a shell; the environment values are operator settings, each passed as one argv word
                        "--name", name, "--version", version, "--manifest", manifest_path],
                       cwd=LOGLEARNER_DIR, capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
    if r.returncode == 0:
        return json.loads(r.stdout)
    try:
        why = json.loads(r.stderr.strip().splitlines()[-1]).get("refused")
    except (ValueError, IndexError, AttributeError):
        why = None
    raise Refused("the LogLearner loader refused %s: %s" % (shown(os.path.basename(path)), why or (r.stderr or r.stdout).strip()[-300:]))


def import_bank(bank, docs, schema, meta, existing, on_conflict="skip"):
    """One bank's documents into the memory API: its transfer archive rebuilt from the pack's lines and posted to the
    document-transfer import with on_conflict (skip, replace or new-id); {imported, skipped, facts, and any other
    document count the operation reports} once it completed. A bank this API does not have yet gets the pack's name and
    mission for it first."""
    if bank not in existing and meta.get("name"):
        api_json("PUT", bank_path(bank), dict({"name": meta["name"]}, **({"mission": meta["mission"]} if meta.get("mission") else {})))
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("manifest.json", json.dumps({
            "schema_version": schema, "source_bank_id": bank, "exported_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "document_count": len(docs), "fact_count": sum(len(d.get("facts") or []) for d in docs)}))
        for i, d in enumerate(docs):
            zf.writestr("documents/%06d.json" % i, json.dumps({k: v for k, v in d.items() if k != "bank"}))
    boundary = "knowledge-pack-" + os.urandom(20).hex()
    body = (("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"transfer.zip\"\r\nContent-Type: "
             "application/zip\r\n\r\n" % boundary).encode() + buf.getvalue() + ("\r\n--%s--\r\n" % boundary).encode())
    sub = json.loads(api("POST", bank_path(bank, "/document-transfer?on_conflict=%s" % urllib.parse.quote(on_conflict)), body,
                         "multipart/form-data; boundary=" + boundary, timeout=300))
    md = wait_op(bank, sub["operation_id"]).get("result_metadata") or {}
    out = {"imported": int(md.get("documents_imported") or 0), "skipped": int(md.get("documents_skipped") or 0),
           "facts": int(md.get("facts_imported") or 0)}
    for k, v in md.items():   # replaced, renamed, ...: whatever else the operation counts for this choice
        if k.startswith("documents_") and k not in ("documents_imported", "documents_skipped") and isinstance(v, int):
            out[k[len("documents_"):]] = v
    return out


def load_hindsight(m, data, entry, on_conflict="skip"):
    """A pack's Hindsight documents into the memory API, bank by bank; {bank: counts or {"error": why}}, and the stamp
    updated for the pack when every bank went in."""
    by_bank = {}
    for d in lines_of(entry["path"], data):
        by_bank.setdefault(d["bank"], []).append(d)
    existing = {b["id"] for b in hindsight_banks(counts=False)}
    out, ok = {}, True
    for bank, docs in by_bank.items():
        try:
            out[bank] = import_bank(bank, docs, entry.get("transfer_schema", 1), (entry.get("banks") or {}).get(bank) or {},
                                    existing, on_conflict)
        except (urllib.error.URLError, OSError, ValueError, KeyError, RuntimeError, zipfile.BadZipFile) as e:
            out[bank] = {"error": "%s: %s" % (type(e).__name__, str(e)[:300])}
            ok = False
    if ok:
        stamp = read_stamp()
        stamp[m["name"]] = {"sha256": entry["sha256"], "banks": {b: len(d) for b, d in by_bank.items()}}
        write_bytes(STAMP, (json.dumps(stamp, indent=1, sort_keys=True) + "\n").encode())
    return out


def read_stamp():
    try:
        with open(STAMP, encoding="utf-8") as f:
            s = json.load(f)
        return s if isinstance(s, dict) else {}
    except (OSError, ValueError):
        return {}


def import_pack(blob, on_conflict="skip"):
    """Check a pack, load its LogLearner file, keep it in IMPORTED, load its Hindsight documents with on_conflict: the
    result per store."""
    if on_conflict not in CONFLICT:
        raise Refused("on_conflict must be skip, replace or new-id, not '%s'" % shown(on_conflict))
    m, files, seen = read_pack(blob)
    name, version = m["name"], str(m["version"])
    real = linked(IMPORTED)
    if real:
        raise Refused("KNOWLEDGE_IMPORTED_DIR %s resolves to %s through a link: nothing is kept there; set it to a real "
                      "directory" % (IMPORTED, real))
    res = {"pack": name, "version": version, "records": m.get("records"), "checked": sorted(f["path"] for f in seen.values()),
           "on_conflict": on_conflict}
    if "loglearner" in seen:
        with tempfile.TemporaryDirectory(prefix="knowledge-pack-") as tmp:
            for n in (seen["loglearner"]["path"], name + ".manifest.json"):
                with open(os.path.join(tmp, n), "wb") as f:
                    f.write(files[n])
            res["loglearner"] = load_loglearner(os.path.join(tmp, seen["loglearner"]["path"]),
                                                os.path.join(tmp, name + ".manifest.json"), name, version)
    os.makedirs(IMPORTED, exist_ok=True)
    for n in sorted(files, key=lambda n: n.endswith(".manifest.json")):   # the manifest last
        write_bytes(os.path.join(IMPORTED, n), files[n])
    for store, n in (("loglearner", name + ".jsonl"), ("hindsight", name + ".hindsight.jsonl")):
        if store not in seen and os.path.lexists(os.path.join(IMPORTED, n)):
            os.remove(os.path.join(IMPORTED, n))   # an earlier version of this pack had it, this one does not
    res["kept"] = os.path.join(IMPORTED, name + ".manifest.json")
    if "hindsight" in seen:
        if not HINDSIGHT:
            res["hindsight"] = {"error": "the memory API is off on this harness (UI_HINDSIGHT=false); the documents are kept "
                                "and load at a start with it on"}
        else:
            try:
                res["hindsight"] = load_hindsight(m, files[seen["hindsight"]["path"]], seen["hindsight"], on_conflict)
            except BudgetSpent:
                # the LogLearner records are loaded and the pack is kept: not a refusal - the next start loads the rest
                res["hindsight"] = {"error": "the request's time budget ran out before every memory bank was loaded "
                                    "(KNOWLEDGE_REQUEST_BUDGET); the pack is kept and its documents load at the next start"}
            except (urllib.error.URLError, OSError, ValueError) as e:
                res["hindsight"] = {"error": "the memory API did not answer (%s); the pack is kept and its documents load at "
                                    "the next start" % str(e)[:200]}
    return res


def ids_lines(path):
    """{id: line} of a bank file's records (absent file: empty)."""
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("id") is not None:
                    out[str(r["id"])] = line
    except FileNotFoundError:
        pass
    return out


def preview_loglearner(files, entry, name, version):
    """What an import would do to the LogLearner bank: the runtime's own loader on a copy of the bank and its install
    ledger in a temporary directory - its counts, and the ids of the bank's records it would replace. The bank itself is
    not written."""
    ledger = os.path.join(os.path.dirname(INSTINCTS_JSON), INSTALLED)
    with tempfile.TemporaryDirectory(prefix="knowledge-preview-") as tmp:
        bank = os.path.join(tmp, "bank", os.path.basename(INSTINCTS_JSON))
        os.makedirs(os.path.dirname(bank))
        for src, dst in ((INSTINCTS_JSON, bank), (ledger, os.path.join(os.path.dirname(bank), INSTALLED))):
            if os.path.isfile(src):
                shutil.copyfile(src, dst)
        before = ids_lines(bank)
        for n in (entry["path"], name + ".manifest.json"):
            with open(os.path.join(tmp, n), "wb") as f:
                f.write(files[n])
        res = load_loglearner(os.path.join(tmp, entry["path"]), os.path.join(tmp, name + ".manifest.json"), name, version, bank)
        after = ids_lines(bank)
    out = {k: res.get(k) for k in ("noop", "added", "updated", "skipped", "total")}
    replaced = sorted(i for i in before if i in after and after[i] != before[i])
    out["replaces"] = replaced[:50]
    # a record of this image's own packs (the shipped packs, seed-*) the pack carries another version of: an import replaces
    # it with the pack's, the copy of whichever image the pack came from
    packs, mine = image_defaults()[0], []
    for i in replaced:
        try:
            r = json.loads(before[i])
        except ValueError:
            continue
        if isinstance(r, dict) and from_image(r, packs):
            mine.append(i)
    out["replaces_image"] = {"count": len(mine), "ids": mine[:20]}
    return out


def bank_document_ids(bank):
    """Every document id the memory API holds in a bank (its documents list, page by page)."""
    ids, offset = set(), 0
    while True:
        page = api_json("GET", bank_path(bank, "/documents?limit=500&offset=%d" % offset))
        items = [i for i in page.get("items") or [] if isinstance(i, dict)]
        ids.update(str(i["id"]) for i in items if i.get("id") is not None)
        offset += len(items)
        if not items or offset >= int(page.get("total") or 0):
            return ids


def preview_hindsight(data, entry):
    """Per bank of a pack: its documents, how many the bank does not have and which it already has (the conflicts the
    import's on_conflict decides), and whether the bank exists here."""
    by_bank = {}
    for d in lines_of(entry["path"], data):
        by_bank.setdefault(d["bank"], []).append(str(d["id"]))
    existing = {b["id"] for b in hindsight_banks(counts=False)}
    seed = image_defaults()[1]
    out = {}
    for bank, ids in by_bank.items():
        have = bank_document_ids(bank) if bank in existing else set()
        same = [i for i in ids if i in have]
        mine = [i for i in same if i in seed.get(bank, ())]   # this image's own seed documents: replace overwrites them
        out[bank] = {"documents": len(ids), "bank": "exists" if bank in existing else "new", "new": len(ids) - len(same),
                     "conflicts": len(same), "conflict_ids": same[:20], "conflicts_image": len(mine), "conflict_image_ids": mine[:20]}
    return out


def preview_pack(blob):
    """A pack checked the way an import checks it, and what the import would do; nothing is written anywhere."""
    m, files, seen = read_pack(blob)
    name, version = m["name"], str(m["version"])
    res = {"pack": name, "version": version, "records": m.get("records"), "checked": sorted(f["path"] for f in seen.values()),
           "source": m.get("source") if isinstance(m.get("source"), dict) else None,
           "scrub": m.get("scrub") if isinstance(m.get("scrub"), dict) else None,
           "replaces_kept": os.path.isfile(os.path.join(IMPORTED, name + ".manifest.json"))}
    if "loglearner" in seen:
        res["loglearner"] = preview_loglearner(files, seen["loglearner"], name, version)
    if "hindsight" in seen:
        if not HINDSIGHT:
            res["hindsight"] = {"error": "the memory API is off on this harness (UI_HINDSIGHT=false); the documents would be "
                                "kept and load at a start with it on"}
        else:
            try:
                res["hindsight"] = preview_hindsight(files[seen["hindsight"]["path"]], seen["hindsight"])
            except (urllib.error.URLError, OSError, ValueError, RuntimeError) as e:
                res["hindsight"] = {"error": "the memory API did not answer (%s)" % str(e)[:200]}
    return res


def find_records(sel, limit=FIND_LIMIT):
    """The page's finder: the records of the ticked stores and banks the search matches, the first `limit` of each store
    and bank with how many match. LogLearner records by id or title, as they would travel; Hindsight documents by id
    (the memory API's own filter, most recent first)."""
    out = {"search": sel["search"], "limit": limit}
    if "loglearner" in sel["stores"]:
        rows, _ = bank_rows()
        listed, total = [], 0
        for r in rows:
            held = str(r.get("id") or "")
            t = travelling(r)
            if not matches(sel, [held, t.get("id"), title_of(t)]):
                continue
            total += 1
            if len(listed) < limit:
                pack = t.get("pack") if isinstance(t.get("pack"), dict) else {}
                listed.append({"store": "loglearner", "id": t.get("id"), "held_as": held, "title": title_of(t),
                               "day": str(t.get("banked_at") or pack.get("ingested_at") or "")[:10]})
        out["loglearner"] = {"total": total, "shown": listed}
    if "hindsight" in sel["stores"]:
        if not HINDSIGHT:
            out["hindsight"] = {"error": "the memory API is off on this harness (UI_HINDSIGHT=false)"}
            return out
        banks = {}
        for b in hindsight_banks(counts=False):
            if sel["banks"] is not None and b["id"] not in sel["banks"]:
                continue
            q = [("limit", str(limit))] + ([("q", sel["search"])] if sel["search"] else [])
            page = api_json("GET", bank_path(b["id"], "/documents?" + urllib.parse.urlencode(q)))
            items = [i for i in page.get("items") or [] if isinstance(i, dict) and i.get("id") is not None][:limit]
            banks[b["id"]] = {"total": int(page.get("total") or len(items)), "shown": [
                {"store": "hindsight", "bank": b["id"], "id": str(i["id"]), "day": str(i.get("created_at") or "")[:10],
                 "tags": i.get("tags") if isinstance(i.get("tags"), list) else []} for i in items]}
        out["hindsight"] = {"banks": banks}
    return out


def kept():
    """The kept packs: [(name, manifest path)] of IMPORTED's manifests (plain files only)."""
    try:
        names = sorted(os.listdir(IMPORTED))
    except OSError:
        return []
    out = []
    for n in names:
        p = os.path.join(IMPORTED, n)
        if n.endswith(".manifest.json") and not n.startswith(".") and os.path.isfile(p) and not os.path.islink(p):
            out.append((n[:-len(".manifest.json")], p))
    return out


def read_kept(name, manifest_path):
    """A kept pack's manifest, files and entries, checked like an upload (a file the manifest lists that is missing, a
    link or not its bytes refuses the pack)."""
    buf = io.BytesIO()
    with open(manifest_path, "rb") as f:
        m = json.loads(f.read())
    listed = [f.get("path") for f in (m.get("files") if isinstance(m, dict) and isinstance(m.get("files"), list) else [])
              if isinstance(f, dict)]
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for n in listed + [name + ".manifest.json"]:
            p = os.path.join(IMPORTED, os.path.basename(str(n)))
            if os.path.isfile(p) and not os.path.islink(p):
                tf.add(p, arcname=os.path.basename(p), recursive=False)
    return read_pack(buf.getvalue())


def load():
    """The start step: the Hindsight files of the kept packs into the memory API, each pack checked again first; a pack
    the stamp records whose banks still hold every one of its documents (by id) is left alone, and a pack that cannot be
    read or loaded is named in the result while the others still load."""
    out, todo = {}, []
    for name, p in kept():
        try:
            m, files, seen = read_kept(name, p)
        except Exception as e:   # noqa: BLE001 - one unreadable kept pack never stops the others
            out[name] = "refused: %s" % (e if isinstance(e, Refused) else "%s: %s" % (type(e).__name__, str(e)[:300]))
            continue
        if "hindsight" in seen:
            todo.append((name, m, files, seen))
    if not todo:
        return {"load": out or "no kept pack with Hindsight documents in %s" % IMPORTED}
    if not HINDSIGHT:
        return {"load": dict(out, hindsight="the memory API is off (UI_HINDSIGHT=false): nothing loaded")}
    deadline = time.time() + API_WAIT
    while True:
        try:
            if api_json("GET", "/health", timeout=5).get("status") == "healthy":
                break
        except (urllib.error.URLError, OSError, ValueError, RuntimeError):
            pass
        if time.time() > deadline:
            return {"load": dict(out, hindsight="the memory API did not answer within %ds: nothing loaded" % API_WAIT)}
        time.sleep(2)  # nosemgrep: arbitrary-sleep -- retry interval of a bounded wait for the memory API
    stamp = read_stamp()
    for name, m, files, seen in todo:
        entry = seen["hindsight"]
        try:
            if (stamp.get(name) or {}).get("sha256") == entry["sha256"]:
                need = {}
                for d in lines_of(entry["path"], files[entry["path"]]):
                    need.setdefault(d["bank"], set()).add(str(d["id"]))
                there = {b["id"] for b in hindsight_banks(counts=False)}
                if all(b in there and ids <= bank_document_ids(b) for b, ids in need.items()):
                    out[name] = "already in the memory API"
                    continue
            out[name] = load_hindsight(m, files[entry["path"]], entry)
        except Exception as e:   # noqa: BLE001 - one pack's failure never stops the next pack's load at a start
            out[name] = {"error": "%s: %s" % (type(e).__name__, str(e)[:300])}
    return {"load": out}


def stores():
    """What the page shows: the LogLearner bank's count, every Hindsight bank's documents, the kept packs."""
    rows, bad = bank_rows()
    packs, seed = image_defaults()
    out = {"loglearner": {"bank": INSTINCTS_JSON, "records": len(rows), "unreadable_lines": bad,
                          "from_image": sum(1 for r in rows if from_image(r, packs))},
           "hindsight": {"on": HINDSIGHT}, "imported_dir": IMPORTED, "kept": [], "seed_banks": sorted(seed)}
    if HINDSIGHT:
        try:
            out["hindsight"].update(state="up", banks=hindsight_banks(timeout=15))
        except (urllib.error.URLError, OSError, ValueError, RuntimeError) as e:
            out["hindsight"].update(state="down", error=str(e)[:200])
    for name, p in kept():
        try:
            with open(p, encoding="utf-8") as f:
                m = json.load(f)
            out["kept"].append({"name": name, "version": m.get("version"), "records": m.get("records"),
                                "files": [{k: f.get(k) for k in ("path", "store", "records")} for f in m.get("files") or []]})
        except (OSError, ValueError, AttributeError):
            out["kept"].append({"name": name, "error": "the manifest is not readable"})
    return out


# ---------------------------------------------------------------- the page
# The page's own origin only; the home proxy replaces this header on /knowledge/ with the same policy plus the hashes of
# the home badge's three inline pieces (home-render.sh, KNOWLEDGE_CSP)
CSP = "default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
FILES = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
         "/app.js": ("app.js", "text/javascript; charset=utf-8"), "/style.css": ("style.css", "text/css; charset=utf-8")}
ACTION = threading.Lock()


HOME_HOSTNAMES = set(E.get("UI_HOME_HOSTNAMES", "").lower().split())   # the home listener's extra names (.env)


def host_ok(host):
    name = (host or "").strip().lower()
    name = name[1:name.index("]")] if name.startswith("[") and "]" in name else name.split(":")[0]
    return name in ("127.0.0.1", "localhost", "::1") or name.endswith(".localhost") or name in HOME_HOSTNAMES


def summary_header(summary):
    """The export's summary as the X-Knowledge-Pack header, at most HEADER_MAX bytes: past that the per-bank counts give
    way to their number (the manifest in the pack keeps them), then the scrub's per-class counts to their total."""
    head = json.dumps(summary, separators=(",", ":"))
    if len(head) > HEADER_MAX:
        summary = dict(summary, banks={"count": len(summary.get("banks") or {})})
        head = json.dumps(summary, separators=(",", ":"))
    if len(head) > HEADER_MAX:
        rep = (summary.get("scrub") or {}).get("replacements") or {}
        summary = dict(summary, scrub=dict(summary.get("scrub") or {}, replacements={"total": sum(rep.values())}))
        head = json.dumps(summary, separators=(",", ":"))
    return head


class Handler(BaseHTTPRequestHandler):
    server_version = "knowledge-transfer"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype, extra=None):
        self.send_response(code)
        headers = {"Content-Type": ctype, "Content-Length": str(len(body)), "Cache-Control": "no-store",
                   "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Content-Security-Policy": CSP}
        headers.update(extra or {})
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def answer(self, code, obj):
        self.send(code, json.dumps(obj).encode("utf-8"), "application/json")

    def refuse(self):
        self.send(405, b"GET and HEAD only; POST only to export, preview and import\n", "text/plain; charset=utf-8",
                  {"Allow": "GET, HEAD"})

    do_PUT = do_PATCH = do_DELETE = do_OPTIONS = refuse

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if not host_ok(self.headers.get("Host")):
            return self.send(421, b"misdirected: loopback names only\n", "text/plain; charset=utf-8")
        if path == "/health":
            return self.answer(200, {"ok": True})
        if path == "/stores.json":
            return self.answer(200, stores())
        if path == "/records.json":
            qs = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            try:
                limit = int((qs.get("limit") or [FIND_LIMIT])[0])
                if not 1 <= limit <= 200:
                    raise ValueError
            except ValueError:
                return self.answer(400, {"refused": "limit must be a number from 1 to 200"})
            try:
                sel = selection({"stores": qs.get("store"), "banks": qs.get("bank"), "search": (qs.get("q") or [""])[0]})
                return self.answer(200, find_records(sel, limit))
            except Refused as e:
                return self.answer(400, {"refused": str(e)})
            except (urllib.error.URLError, OSError, ValueError, KeyError, RuntimeError) as e:
                return self.answer(502, {"error": "%s: %s" % (type(e).__name__, str(e)[:300])})
            except Exception as e:   # noqa: BLE001 - every request gets an answer
                return self.answer(500, {"error": "unexpected %s: %s" % (type(e).__name__, str(e)[:300])})
        if path not in FILES:
            return self.send(404, b"not found\n", "text/plain; charset=utf-8")
        name, ctype = FILES[path]
        try:
            with open(os.path.join(PAGE_DIR, name), "rb") as f:
                body = f.read()
        except OSError:
            return self.send(503, b"the page's files are missing\n", "text/plain; charset=utf-8")
        self.send(200, body, ctype)

    def do_POST(self):
        action = self.path.split("?", 1)[0].lstrip("/")
        if action not in ("export", "preview", "import"):
            return self.refuse()
        host = self.headers.get("Host") or ""
        if not host_ok(host):
            return self.answer(421, {"refused": "loopback names only"})
        # this page's own requests only: a form or a page on another site can send neither its header nor its origin
        if self.headers.get("X-Knowledge-Transfer") != "1":
            return self.answer(403, {"refused": "not sent by the Knowledge transfer page (no X-Knowledge-Transfer header)"})
        origin = self.headers.get("Origin") or ""
        if origin != "http://" + host or (self.headers.get("Sec-Fetch-Site") or "same-origin") != "same-origin":
            return self.answer(403, {"refused": "the request comes from another origin (%s)" % (shown(origin) or "none given")})
        try:
            length = int(self.headers.get("Content-Length") or "")
        except ValueError:
            return self.answer(411, {"refused": "a Content-Length is required"})
        cap = 1 << 20 if action == "export" else MAX_PACK   # a selection (up to MAX_RECORDS ids), or a pack
        if length < 0 or length > cap:
            return self.answer(413, {"refused": "the request is %d bytes; at most %d are taken" % (length, cap)})
        body = self.rfile.read(length)
        if not ACTION.acquire(blocking=False):
            return self.answer(409, {"refused": "another export or import is still running"})
        REQUEST.end = time.time() + BUDGET
        try:
            if action == "export":
                try:
                    sel = selection(json.loads(body or b"{}"))
                except ValueError:
                    raise Refused("the selection is not JSON") from None
                blob, m, scrub = export_pack(sel)
                summary = {"name": m["name"], "version": m["version"], "records": m["records"],
                           "files": [{k: f[k] for k in ("path", "store", "records", "sha256")} for f in m["files"]],
                           "banks": {b: v["records"] for f in m["files"] for b, v in (f.get("banks") or {}).items()},
                           "scrub": {k: scrub[k] for k in ("gate", "classes", "replacements")},
                           "left_out_defaults": m.get("left_out_defaults") or {}}
                return self.send(200, blob, "application/gzip", {
                    "Content-Disposition": "attachment; filename=\"%s-%s.tar.gz\"" % (m["name"], m["version"]),
                    "X-Knowledge-Pack": summary_header(summary)})
            if action == "preview":
                return self.answer(200, preview_pack(body))
            qs = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            return self.answer(200, import_pack(body, (qs.get("on_conflict") or ["skip"])[0]))
        except Refused as e:
            return self.answer(400, {"refused": str(e)})
        except (urllib.error.URLError, OSError, ValueError, KeyError, RuntimeError, zipfile.BadZipFile, subprocess.SubprocessError) as e:
            return self.answer(502, {"error": "%s: %s" % (type(e).__name__, str(e)[:300])})
        except Exception as e:   # noqa: BLE001 - every request gets an answer, never a dropped connection
            return self.answer(500, {"error": "unexpected %s: %s" % (type(e).__name__, str(e)[:300])})
        finally:
            REQUEST.end = None
            ACTION.release()


def main(argv):
    ap = argparse.ArgumentParser(prog="knowledge-transfer.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, default=PORT)
    x = sub.add_parser("export")
    x.add_argument("out")
    x.add_argument("--name", default="knowledge")
    x.add_argument("--store", action="append", choices=STORES)
    x.add_argument("--bank", action="append")
    x.add_argument("--tag")
    x.add_argument("--since")
    x.add_argument("--until")
    x.add_argument("--search")
    x.add_argument("--id", action="append", dest="ids")
    x.add_argument("--include-defaults", action="store_true", dest="defaults",
                   help="this image's own default knowledge too (the shipped packs' and the seed-* records, the seed banks' documents)")
    r = sub.add_parser("records")
    r.add_argument("--search")
    r.add_argument("--store", action="append", choices=STORES)
    r.add_argument("--bank", action="append")
    r.add_argument("--limit", type=int, default=FIND_LIMIT)
    p = sub.add_parser("preview")
    p.add_argument("pack")
    i = sub.add_parser("import")
    i.add_argument("pack")
    i.add_argument("--on-conflict", default="skip", choices=CONFLICT)
    sub.add_parser("load")
    a = ap.parse_args(argv)
    if a.cmd == "serve":
        server = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
        server.daemon_threads = True
        print("knowledge-transfer: serving the Knowledge transfer page on 127.0.0.1:%d (bank %s, memory API %s, kept packs %s)"
              % (a.port, INSTINCTS_JSON, API if HINDSIGHT else "off", IMPORTED), flush=True)
        server.serve_forever()
    try:
        if a.cmd == "export":
            blob, m, scrub = export_pack(selection({"stores": a.store, "banks": a.bank, "tag": a.tag, "since": a.since,
                                                    "until": a.until, "name": a.name, "search": a.search, "records": a.ids,
                                                    "defaults": a.defaults}))
            with open(a.out, "wb") as f:
                f.write(blob)
            out = {"wrote": a.out, "bytes": len(blob), "manifest": m, "scrub_config": scrub["from"]}
        elif a.cmd == "records":
            if not 1 <= a.limit <= 200:
                raise Refused("--limit must be a number from 1 to 200")
            out = find_records(selection({"stores": a.store, "banks": a.bank, "search": a.search}), a.limit)
        elif a.cmd == "preview":
            with open(a.pack, "rb") as f:
                out = preview_pack(f.read())
        elif a.cmd == "import":
            with open(a.pack, "rb") as f:
                out = import_pack(f.read(), a.on_conflict)
        else:
            out = load()
    except Refused as e:
        print(json.dumps({"refused": str(e)}))
        return 2
    except (urllib.error.URLError, OSError, ValueError, KeyError, RuntimeError, zipfile.BadZipFile, subprocess.SubprocessError) as e:
        print(json.dumps({"error": "%s: %s" % (type(e).__name__, str(e)[:300])}))
        return 1
    except Exception as e:   # noqa: BLE001 - one JSON answer, never a traceback
        print(json.dumps({"error": "unexpected %s: %s" % (type(e).__name__, str(e)[:300])}))
        return 1
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
