#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The harness's Hindsight recall hook - Claude Code's UserPromptSubmit, registered next to Hindsight's own hooks
(setup/install-hindsight.sh at build, /agent/hindsight-hooks-repair.sh at every start, both of which also set the hooks'
config to autoInject "none").

Why it exists: Hindsight's own prompt hook injected, by default, a narrative - the bank's "reflect" answer to the prompt,
a synthesis with no record behind any sentence - under the heading of memory. A narrative composed over a bank that knew one
project told the agent that an unrelated question's subject was part of that project; the stored records said no such
thing, and the agent had to catch the error itself. This hook injects RECORDS instead: the bank's recall results for the
prompt, one line per record with its id and its provenance - the date, the session (a session write-back's document
conversation:<id>) or the document, and for a session record "not verified" ("agent claim, not verified" when it states
the agent's own action; an observation names the session its source facts come from, and one that states an outcome is a derived claim)
- under a header that names the bank and the ids and says what the block is. A record whose content repeats one
already listed (the text before " | ", as a fact and its observation do), one that is only the transcript's REF-ID marker
and, among session records and observations from them, one not in the memory service's output language
(HINDSIGHT_API_LLM_OUTPUT_LANGUAGE, English by default) are left out - a document's records keep their language -
by the session guard's checks (/agent/hindsight-session-guard.py, beside this hook). Nothing in the block is a synthesis; a
statement without a record id is not a memory. The agent verifies a record before relying on it (the Memory tile,
/agent/recall.sh, or the API's memory endpoint).

Input: the hook event on stdin (JSON: prompt, cwd, session_id). Output: nothing when there is nothing to inject (no prompt,
no records, no API, no bank), else one JSON object {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
"additionalContext": <block>}} - the shape Hindsight's hooks use. It never fails the prompt: every error exits 0 silently.
Bank: as Hindsight's hooks resolve it - HINDSIGHT_BANK_ID, else the config's bankId, else the template
(HINDSIGHT_BANK_ID_TEMPLATE, the config's bankIdTemplate, default coding-agent::{gitProject}) with {gitProject} the name of
the main worktree's root of the cwd's repository (a linked worktree resolves to its main worktree), or the cwd's own name
outside a repository; with git itself missing the bank is not guessed and nothing is injected.
Settings: HINDSIGHT_API_URL (else the config's apiUrl, else http://127.0.0.1:8888), HINDSIGHT_HOOKS_CONFIG (default
~/.hindsight/coding-agent.json), HINDSIGHT_RECALL_MAX_RECORDS (8), HINDSIGHT_RECALL_MAX_CHARS (3600),
HINDSIGHT_RECALL_TIMEOUT seconds (8); HINDSIGHT_DISABLE_HOOKS or HINDSIGHT_DISABLED set: nothing."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_TEMPLATE = "coding-agent::{gitProject}"
HEADER = ("Index entries recalled from the Hindsight bank {bank} for this prompt - records, not an answer. Verify a record before "
          "relying on it (the Memory tile, /agent/recall.sh, or GET {api}/v1/default/banks/{bank}/memories/<id>); nothing below is "
          "a synthesis, and a statement without a record id is not a memory.")


def env_int(name, default):
    try:
        return int(os.environ.get(name, ""))
    except ValueError:
        return default


def read_config(path):
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return {}
    return cfg if isinstance(cfg, dict) else {}


def git_project(cwd):
    """Hindsight's {gitProject}: the name of the main worktree's root (a linked worktree resolves to the main one), the
    directory's own name outside a repository, None when git itself cannot be asked (no guessing)."""
    def git(*args):
        r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ""
    try:
        inside = git("rev-parse", "--is-inside-work-tree")
    except FileNotFoundError:
        return None
    except (OSError, subprocess.SubprocessError):
        return os.path.basename(os.path.normpath(cwd))
    if inside != "true":
        return os.path.basename(os.path.normpath(cwd))
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir") or git("rev-parse", "--git-common-dir")
    if common and not os.path.isabs(common):
        common = os.path.normpath(os.path.join(cwd, common))
    root = os.path.dirname(common) if common and os.path.basename(common) == ".git" else git("rev-parse", "--show-toplevel")
    return os.path.basename(os.path.normpath(root or cwd))


def resolve_bank(cfg, cwd):
    bank = os.environ.get("HINDSIGHT_BANK_ID") or cfg.get("bankId")
    if bank:
        return str(bank)
    template = str(os.environ.get("HINDSIGHT_BANK_ID_TEMPLATE") or cfg.get("bankIdTemplate") or DEFAULT_TEMPLATE)
    project = git_project(cwd)
    if project is None:
        return None
    bank = template.replace("{gitProject}", project)
    if "{" in bank:  # a placeholder this hook does not know: the default form rather than a guess
        bank = DEFAULT_TEMPLATE.replace("{gitProject}", project)
    return bank


def recall(api, bank, prompt, options, timeout):
    url = api.rstrip("/") + "/v1/default/banks/" + urllib.parse.quote(bank, safe=":") + "/memories/recall"
    body = dict(options)
    body["query"] = prompt[:2000]
    if isinstance(body.get("include", {}), dict):   # an observation's source facts say which session it comes from
        body["include"] = {"source_facts": {"max_tokens": 2048}, **body.get("include", {})}
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        data = json.loads(resp.read() or b"{}")
    results = data.get("results") if isinstance(data, dict) else data
    facts = data.get("source_facts") if isinstance(data, dict) and isinstance(data.get("source_facts"), dict) else {}
    for r in results if isinstance(results, list) else []:
        if isinstance(r, dict) and isinstance(r.get("source_fact_ids"), list):
            r["source_facts"] = [facts[i] for i in r["source_fact_ids"] if isinstance(facts.get(i), dict)]
    return results if isinstance(results, list) else []


def record_checks():
    """The session guard's record checks (/agent/hindsight-session-guard.py, next to this hook): content key, marker-only,
    language, claim; None when the guard is not there (the records are then rendered without them)."""
    try:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hindsight-session-guard.py")
        spec = importlib.util.spec_from_file_location("hindsight_session_guard", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception:
        return None


def provenance(r, when, checks):
    """Where a record comes from: its date, its session (a session write-back's document conversation:<id>) or document, and
    whether it is the agent's own account, not verified."""
    parts = [when] if when else []
    doc = str(r.get("document_id") or "")
    sessions = []   # an observation has no document: the sessions its source facts come from
    for s in [] if doc else r.get("source_facts") or []:
        d = str(s.get("document_id") or "") if isinstance(s, dict) else ""
        if d.startswith("conversation:") and d.split(":", 1)[1][:8] not in sessions:
            sessions.append(d.split(":", 1)[1][:8])
    if doc.startswith("conversation:"):
        parts.append("session " + doc.split(":", 1)[1][:8])
    elif doc:
        parts.append("document " + doc)
    elif sessions:
        parts.append("from session " + ", ".join(sessions[:2]) + (" and %d more" % (len(sessions) - 2) if len(sessions) > 2 else ""))
    unit = {"text": r.get("text") or r.get("content"), "fact_type": r.get("type") or r.get("fact_type")}
    claim = "agent claim" in str(r.get("context") or "") or (checks and unit["fact_type"] != "observation" and checks.claim_kind(unit))
    if doc.startswith("conversation:"):   # a transcript holds no tool result: nothing from it was checked
        parts.append("agent claim, not verified" if claim else "not verified")
    elif sessions:   # derived from session records; an outcome it states is a derived claim (labelled, not removed)
        derived = checks and checks.claim_kind({"text": unit["text"], "fact_type": "world"})
        parts.append("derived claim, not verified" if derived else "not verified")
    return " (%s)" % "; ".join(parts) if parts else ""


def render(bank, api, results, max_records, max_chars):
    lines, ids, seen, size = [], [], set(), 0
    checks = record_checks()
    want = checks.language_code(os.environ.get("HINDSIGHT_API_LLM_OUTPUT_LANGUAGE") or "English") if checks else None
    for r in results:
        if not isinstance(r, dict):
            continue
        rid = str(r.get("id") or r.get("memory_id") or "").strip()
        text = re.sub(r"\s+", " ", str(r.get("text") or r.get("content") or "")).replace("</hindsight_memory>", "").strip()
        key = checks.content_key(text) if checks else text.lower()
        if not rid or not text or key in seen:
            continue
        from_session = str(r.get("document_id") or "").startswith("conversation:") or any(
            str(s.get("document_id") or "").startswith("conversation:") for s in r.get("source_facts") or [] if isinstance(s, dict))
        if checks and (checks.is_marker(text) or (from_session and checks.wrong_language(text, want))):
            continue   # the language pin is the session write-back's; a document's records keep their own language
        when = str(r.get("mentioned_at") or r.get("created_at") or "")[:10]
        line = "- [%s] %s%s" % (rid, text, provenance(r, when, checks))
        if len(lines) >= max_records or size + len(line) > max_chars:
            break
        seen.add(key)
        ids.append(rid)
        lines.append(line)
        size += len(line) + 1
    if not lines:
        return ""
    attr = bank.replace("&", "&amp;").replace('"', "&quot;")
    header = HEADER.format(bank=bank, api=api.rstrip("/"))
    return "\n".join(['<hindsight_memory bank="%s" records="%s">' % (attr, ",".join(ids)), header] + lines + ["</hindsight_memory>"])


def main():
    if os.environ.get("HINDSIGHT_DISABLE_HOOKS") or os.environ.get("HINDSIGHT_DISABLED"):
        return
    event = json.loads(sys.stdin.read() or "{}")
    if not isinstance(event, dict):
        return
    prompt = str(event.get("prompt") or "").strip()
    if not prompt:
        return
    cwd = str(event.get("cwd") or "") or os.getcwd()
    cfg = read_config(os.environ.get("HINDSIGHT_HOOKS_CONFIG") or os.path.join(os.environ.get("HOME", "/home/agent"), ".hindsight", "coding-agent.json"))
    api = str(os.environ.get("HINDSIGHT_API_URL") or cfg.get("apiUrl") or "http://127.0.0.1:8888")
    api = re.sub(r"^(https?://)localhost(?=[:/]|$)", r"\g<1>127.0.0.1", api)  # the API listens on IPv4; no IPv6 attempt first
    bank = resolve_bank(cfg, cwd)
    if not bank:
        return
    options = cfg.get("recallOptions") if isinstance(cfg.get("recallOptions"), dict) else {}
    results = recall(api, bank, prompt, options, env_int("HINDSIGHT_RECALL_TIMEOUT", 8))
    block = render(bank, api, results, env_int("HINDSIGHT_RECALL_MAX_RECORDS", 8), env_int("HINDSIGHT_RECALL_MAX_CHARS", 3600))
    if block:
        sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": block}}) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:  # a hook that fails the prompt is worse than a prompt without memory
        pass
    sys.exit(0)
