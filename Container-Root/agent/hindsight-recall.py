#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The Hindsight half of /agent/recall.sh: ask the memory API this container serves for a query, on every bank.

Usage: hindsight-recall.py "<query>" [--k N]

Hindsight recalls semantically (embeddings, graph spreading), so it returns its nearest memories even for a
query that matches nothing. A memory therefore counts as a hit only when its text also contains one of the
query's terms as a whole word - the same terms, and the same word match, the LogLearner runtime's own
`recall` uses (loglearner.recall.query_tokens and word_boundary), so "a hit" means the same thing for both
sources. At most N hits (default 5) are printed, best first: most query terms matched, then the API's order.

With AGENT_KNOWLEDGE=false (the default knowledge switched off, .env) the banks the shipped packs cover - the
`hindsight_banks` of each manifest in LOGLEARNER_PACKS_DIR (default /opt/loglearner-packs) - are not searched: the
same records the switch takes out of the LogLearner bank, which the Hindsight seed put into the memory store on an
earlier start, stay out of recall too. A manifest without `hindsight_banks` (the example pack gpu-cluster-basics has
none) covers no bank, so with no such manifest every bank is searched either way.

Exit 0 when something was found, 1 when nothing was or the API did not answer (one line on stderr says
which), 2 on a usage error. Loopback only: http://127.0.0.1:${UI_PORT_HINDSIGHT_API:-8888}.
"""
import glob
import json
import os
import sys
import textwrap
import urllib.error
import urllib.parse
import urllib.request


# The http(s) URLs this script builds itself go through one opener, with the scheme checked first: file: or any other
# scheme is refused before a request is made (the urllib default would open it)
_HTTP_OPENER = urllib.request.build_opener()


def http_open(req, timeout):
    """urllib.request.urlopen for an http or https URL (or Request) only; ValueError for any other scheme."""
    url = req.full_url if isinstance(req, urllib.request.Request) else req
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise ValueError("refusing a non-http(s) URL: %r" % (url,))
    return _HTTP_OPENER.open(req, timeout=timeout)


def http_json(method, url, body=None, timeout=8):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with http_open(req, timeout) as resp:
        return json.loads(resp.read().decode() or "null")


def pack_banks(packs):
    """The Hindsight banks the shipped packs cover: every manifest's hindsight_banks (none when a manifest has no such
    key)."""
    names = set()
    for m in glob.glob(os.path.join(packs, "*.manifest.json")):
        try:
            names |= {str(b) for b in json.load(open(m)).get("hindsight_banks") or []}
        except (OSError, ValueError, AttributeError):
            pass
    return names


def main(argv):
    k, words = 5, []
    i = 0
    while i < len(argv):
        if argv[i] == "--k" and i + 1 < len(argv) and argv[i + 1].isdigit():
            k = int(argv[i + 1])
            i += 2
            continue
        words.append(argv[i])
        i += 1
    query = " ".join(words).strip()
    sys.path.insert(0, os.environ.get("LOGLEARNER_DIR", "/opt/loglearner"))
    try:
        from loglearner.recall import query_tokens, word_boundary
    except ImportError as e:
        print(f"recall: hindsight skipped - the LogLearner runtime is not importable ({e})", file=sys.stderr)
        return 1
    terms = query_tokens(query)
    if not terms:
        print("recall: give a query with at least one word of 3+ letters", file=sys.stderr)
        return 2
    api = f"http://127.0.0.1:{os.environ.get('UI_PORT_HINDSIGHT_API', '8888')}"
    try:
        listing = http_json("GET", f"{api}/v1/default/banks?limit=100", timeout=4)
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"recall: hindsight not answering at {api} ({type(e).__name__}) - not searched", file=sys.stderr)
        return 1
    banks = [b["bank_id"] for b in (listing or {}).get("banks", []) if isinstance(b, dict) and b.get("bank_id")]
    if os.environ.get("AGENT_KNOWLEDGE", "true") == "false":
        covered = pack_banks(os.environ.get("LOGLEARNER_PACKS_DIR", "/opt/loglearner-packs"))
        off = [b for b in banks if b in covered]
        if off:
            banks = [b for b in banks if b not in off]
            print(f"recall: AGENT_KNOWLEDGE=false - the {len(off)} bank(s) the shipped packs cover not searched", file=sys.stderr)
    pats = [(t, word_boundary(t)) for t in terms]
    hits, seen = [], set()
    for bank in banks:
        try:
            res = http_json("POST", f"{api}/v1/default/banks/{urllib.parse.quote(bank, safe='')}/memories/recall",
                            {"query": query, "budget": "low"})
        except (urllib.error.URLError, OSError, ValueError) as e:
            print(f"recall: hindsight recall on bank {bank} failed ({type(e).__name__})", file=sys.stderr)
            continue
        for rank, m in enumerate((res or {}).get("results") or []):
            text = " ".join(str(m.get("text") or "").split())
            matched = [t for t, p in pats if p.search(text)]
            if text and matched and text not in seen:
                seen.add(text)
                hits.append((-len(matched), rank, bank, matched, m, text))
    hits.sort(key=lambda h: h[:2])
    for _, _, bank, matched, m, text in hits[:k]:
        print(f"[hindsight {bank}] type={m.get('type') or '?'} matched={','.join(matched)}"
              + (f" document={m['document_id']}" if m.get("document_id") else ""))
        print(textwrap.fill(text[:700], width=110, initial_indent="  ", subsequent_indent="  "))
        print()
    if not hits:
        print(f"no hindsight memory contains a term of {query!r} ({len(banks)} bank(s) asked)", file=sys.stderr)
    return 0 if hits else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
