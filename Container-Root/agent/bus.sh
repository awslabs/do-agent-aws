#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The record of the messages between the harness's agent sessions: the bus v1 journal and its projections, in the
# cooperative mode of the harness's inter-agent mailbox specification (docs/INTER-AGENT-MESSAGING.md). The sessions talk
# with Claude Code's own session-to-session messages; this helper writes the journal line for each message, so the
# dashboards and the person see it, and it is how a script (a spoke's cycle, the supervisor) messages a session.
#
#   /agent/bus.sh request <to>                    a question or a task for <to> (the text on stdin); prints the id
#   /agent/bus.sh note <to>                       a notice: a state change, an alert, a finding (the text on stdin)
#   /agent/bus.sh reply <id>                      the answer to message <id>, to its sender (the text on stdin)
#   /agent/bus.sh error <id>                      a failure to act on message <id>, to its sender (the text on stdin);
#                                                 a message takes one answer: a second reply or error to it is refused
#   /agent/bus.sh send <to> <kind> [--reply-to <id>]   the same in the specification's form (request, reply, notice, error)
#   /agent/bus.sh poll [--kind <kind>]            the ids of the open messages to you (no reply, receipt or completion
#                                                 yet), oldest first, each verified against the journal
#   /agent/bus.sh peek <id>                       a message to you (or from you) as its envelope, JSON; no receipt
#   /agent/bus.sh receipt <id> read|completed|denied [--reason <text>]   a receipt for a message to you
#   /agent/bus.sh state <id>...                   where each message to you stands, from the journal: "<id> open", or one
#                                                 line per reply and receipt it has, in journal order ("<id> replied
#                                                 <reply id>", "<id> read", "<id> completed", "<id> denied")
#   /agent/bus.sh last [<agent>]                  the last message from or to <agent> (default: you), its envelope
#
# Who you are: inside a tmux pane, the pane's session; outside tmux, BUS_AGENT_ID (the supervisor sets it for a cycle).
# "from" is attribution, not authentication: every session runs as the same user (the cooperative mode). Who you can
# write to: the hub and the spokes talk to each other, the supervisor writes notices to the hub, nothing else (the pairs
# are default-deny); every name is a session of the registry (/agent/spokes/registry.json). The text is normalized (line
# endings; terminal controls, escape sequences, C1 and direction controls removed), credential shapes are redacted, and
# the journal line holds the whole envelope in at most 2048 bytes, so a text has room for about 1500 bytes.
#
# The journal: ${MAILBOX_STATE_ROOT}/journal/000001.jsonl (default /var/lib/agent-mailbox, outside /wd; 0700, files
# 0600): one event line per message (message.accepted, with the envelope and its routing), per reply (message.replied)
# and per receipt (message.read, message.completed, message.denied), seq rising by 1. The projections under
# ${MAILBOX_PROJECTION_ROOT} (default /wd/mailbox): <agent>/inbox.jsonl, one record per message to that agent
# ({"env", "meta", "hash"}, the hash over the canonical bytes), and log.jsonl, the journal's lines. A read (poll, peek)
# shows only what the journal holds with that envelope: anything else is held back and named. The senders' and the
# recipients' tmux sessions get the option @agent_last_message, which the tmux-agent dashboard can show. Nothing here
# sends anything outside the container, types into a pane or runs a message: a text is data, and a message grants no
# permission.

MAILBOX_STATE_ROOT=${MAILBOX_STATE_ROOT:-/var/lib/agent-mailbox}
MAILBOX_PROJECTION_ROOT=${MAILBOX_PROJECTION_ROOT:-/wd/mailbox}
SUPERVISOR_DIR=${SUPERVISOR_DIR:-/wd/supervisor}
AGENT_TMUX_SESSION_NAME=${AGENT_TMUX_SESSION_NAME:-agent}
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"

ME=""
if [ -n "${TMUX_PANE}" ] && command -v tmux > /dev/null; then
	ME=$(tmux display-message -p -t "${TMUX_PANE}" '#{session_name}' 2>/dev/null)
fi
[ -n "${ME}" ] || ME=${BUS_AGENT_ID}

# the sessions of the registry and their roles: "name role" lines
SESSIONS=$("${AGENT_DIR}/spoke.sh" sessions 2>/dev/null)

PY=$(cat << 'PYEOF'
import fcntl, hashlib, json, os, re, subprocess, sys, uuid
from datetime import datetime, timezone

state_root, proj_root, sup_dir = os.environ["MAILBOX_STATE_ROOT"], os.environ["MAILBOX_PROJECTION_ROOT"], os.environ["SUPERVISOR_DIR"]
me, hub = os.environ["BUS_ME"], os.environ["BUS_HUB"]
roles = dict(l.split(" ", 1) for l in os.environ["BUS_SESSIONS"].splitlines() if " " in l)
roles[hub] = "hub"
args = sys.argv[1:]
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
RESERVED = {"operator", "human", "system", "root", "broker", "launcher"}
KINDS = ("request", "reply", "notice", "error")
# the events that close a message: poll lists a message to you until one of them is in the journal
CLOSING = ("message.replied", "message.read", "message.completed", "message.denied")
CONTROLS = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-_]|[\x00-\x08\x0b-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]")
SECRETS = [("a Slack token", r"xox[abpors]-[A-Za-z0-9-]{10,}"), ("a GitHub token", r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"),
           ("an AWS access key id", r"(?<![A-Z0-9])(AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"), ("a private key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
           ("a bearer token", r"(?i)bearer\s+[A-Za-z0-9._~+/=-]{20,}")]
journal = os.path.join(state_root, "journal", "000001.jsonl")
log = os.path.join(proj_root, "log.jsonl")


def die(text, rc=64):
    print(f"bus.sh: {text}", file=sys.stderr)
    sys.exit(rc)


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def rec_hash(env, meta):
    return hashlib.sha256(canon({"env": env, "meta": meta}).encode("utf-8")).hexdigest()


def lines(path):
    """the complete JSON lines of a file (a torn last line is not a line yet)"""
    try:
        data = open(path, "rb").read()
    except FileNotFoundError:
        return []
    out = []
    for raw in data[: data.rfind(b"\n") + 1].splitlines():
        try:
            out.append(json.loads(raw))
        except ValueError:
            out.append(None)
    return out


def events():
    """the journal's events; when the journal is gone (a new container), nothing is verifiable"""
    return [e for e in lines(journal) if isinstance(e, dict)]


def accepted():
    return {e["id"]: e for e in events() if e.get("event") == "message.accepted" and isinstance(e.get("details"), dict)}


def generation(agent):
    try:
        return int(json.load(open(os.path.join(sup_dir, agent, "state.json"))).get("generation") or 1)
    except (OSError, ValueError, TypeError):
        return 1


def allowed(frm, to, kind):
    a, b = roles.get(frm), roles.get(to)
    if a is None or b is None:
        return False
    if {a, b} == {"hub", "spoke"}:
        return True
    return a == "supervisor" and b == "hub" and kind == "notice"


def tag_sessions(env):
    text = " ".join(env["text"].split())[:80]
    line = f'{env["ts"]} {env["from"]} -> {env["to"]} {env["kind"]}: {text}'
    for s in (env["from"], env["to"]):
        try:
            if subprocess.run(["tmux", "has-session", "-t", f"={s}"], capture_output=True).returncode == 0:
                subprocess.run(["tmux", "set-option", "-t", f"={s}:", "@agent_last_message", line], capture_output=True)
        except OSError:
            return


def append(path, text, private=False):
    os.makedirs(os.path.dirname(path), mode=0o700 if private else 0o755, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600 if private else 0o644)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(text)


def lock():
    # the state root and its journal directory 0700, its files 0600 (makedirs gives the mode to the leaf only)
    for d in (state_root, os.path.join(state_root, "journal")):
        os.makedirs(d, mode=0o700, exist_ok=True)
    f = os.fdopen(os.open(os.path.join(state_root, ".lock"), os.O_WRONLY | os.O_CREAT, 0o600), "w")
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def last_seq():
    for path in (journal, log):
        ev = [e for e in lines(path) if isinstance(e, dict) and isinstance(e.get("seq"), int)]
        if ev:
            return max(e["seq"] for e in ev) if path == log else ev[-1]["seq"]
    return 0


def event(seq, name, mid, details):
    return {"v": 1, "seq": seq, "ts": now(), "event": name, "id": mid, "actor": me, "generation": generation(me),
            "attempt": None, "details": details}


def verified(rec, acc):
    """why an inbox record is held back, or None"""
    if not isinstance(rec, dict) or set(rec) != {"env", "meta", "hash"} or not isinstance(rec.get("env"), dict):
        return "not an inbox record"
    if rec["hash"] != rec_hash(rec["env"], rec.get("meta")):
        return "its hash does not match its envelope"
    a = acc.get(rec["env"].get("id"))
    if a is None:
        return "not in the journal"
    if a["details"].get("env") != rec["env"] or a["details"].get("meta") != rec["meta"]:
        return "differs from its journal record"
    return None


def inbox(acc):
    """the verified records of my inbox, oldest first; the held-back ones named on stderr"""
    out, older = [], 0
    # the journal lives outside /wd and starts empty in a new container while the inbox survives: the records from
    # before its first event are held back as before, but counted in one line, not named on every pass
    evs = events()
    start = evs[0].get("ts") if evs else None
    for rec in lines(os.path.join(proj_root, me, "inbox.jsonl")):
        why = verified(rec, acc)
        if why:
            mid = rec.get("env", {}).get("id", "?") if isinstance(rec, dict) and isinstance(rec.get("env"), dict) else "?"
            if why == "not in the journal" and (start is None or str(rec["env"].get("ts", "")) < start):
                older += 1
                continue
            print(f"bus.sh: held back message {mid}: {why}", file=sys.stderr)
        elif rec["env"]["to"] == me:
            out.append(rec)
    if older:
        print(f"bus.sh: held back {older} message(s) from before this journal (its first event {start or 'none yet'}): not verifiable", file=sys.stderr)
    return out


def post(to, kind, reply_to):
    if kind not in KINDS:
        die(f"kind '{kind}' is not one of {', '.join(KINDS)}")
    if not isinstance(to, str) or not NAME.match(to) or to.lower() in RESERVED:
        die(f"'{to}' is not an agent name")
    if to not in roles:
        die(f"unknown recipient '{to}': the sessions of the registry are {' '.join(sorted(roles))}")
    if to == me:
        die("a message to yourself")
    if not allowed(me, to, kind):
        die(f"refused: {me} ({roles.get(me)}) may not send a {kind} to {to} ({roles.get(to)}) - the hub and the spokes talk to each other, the supervisor sends notices to the hub, nothing else")
    acc = accepted()
    orig = None
    if kind == "reply" and reply_to is None:
        die("a reply needs the id of the message it answers")
    if reply_to is not None:
        if not UUID.match(reply_to):
            die(f"'{reply_to}' is not a message id")
        orig = acc.get(reply_to)
        if orig is None:
            die(f"no message {reply_to} in the journal", 1)
        if orig["details"]["env"]["to"] != me:
            die(f"message {reply_to} was sent to {orig['details']['env']['to']}, not to you ({me})", 1)
    text = CONTROLS.sub("", sys.stdin.read().replace("\r\n", "\n").replace("\r", "\n")).strip("\n")
    redacted = []
    for label, rx in SECRETS:
        text, n = re.subn(rx, f"[redacted: {label}]", text)
        if n:
            redacted.append(f"{n} x {label}")
    if not text.strip():
        die("the text (stdin) is empty")
    if len(text.encode("utf-8")) > 16384:
        die(f"the text is {len(text.encode('utf-8'))} bytes; at most 16384")
    env = {"v": 1, "id": str(uuid.uuid4()), "from": me, "to": to, "ts": now(), "kind": kind, "text": text, "reply_to": reply_to}
    meta = {"seq": 0, "conversation_id": orig["details"]["meta"]["conversation_id"] if orig else str(uuid.uuid4()),
            "causation_id": reply_to, "from_generation": generation(me), "to_generation": generation(to),
            "origin": "system" if roles.get(me) == "supervisor" else "agent", "assurance": "cooperative"}
    if len(json.dumps({"env": env, "meta": meta}, ensure_ascii=False).encode("utf-8")) > 2048 - 40:
        die(f"the text is {len(text.encode('utf-8'))} bytes: the journal line carries the whole envelope in at most 2048 bytes; "
            "write a longer body to a file in your working directory and send its path")
    with lock():
        # one answer per message: whoever answers first (a fire of the loop, the person in agent's pane) is the answer
        if kind in ("reply", "error") and reply_to:
            done = [e for e in events() if e.get("id") == reply_to and e.get("event") == "message.replied"]
            if done:
                die(f"message {reply_to} was answered already, by {(done[0].get('details') or {}).get('reply')}: a message takes one answer", 1)
        seq = last_seq() + 1
        meta["seq"] = seq
        evs = [event(seq, "message.accepted", env["id"], {"env": env, "meta": meta})]
        if kind in ("reply", "error") and reply_to:
            evs.append(event(seq + 1, "message.replied", reply_to, {"reply": env["id"]}))
        # the journal first, then the projections: a message the journal does not hold is never shown
        append(journal, "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in evs), private=True)
        append(os.path.join(proj_root, to, "inbox.jsonl"), json.dumps({"env": env, "meta": meta, "hash": rec_hash(env, meta)}, ensure_ascii=False) + "\n")
        append(log, "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in evs))
    if redacted:
        print(f"bus.sh: redacted {', '.join(redacted)} in the text", file=sys.stderr)
    tag_sessions(env)
    print(env["id"])


if not me or not NAME.match(me):
    die("who is sending? inside a tmux pane its session is; outside tmux set BUS_AGENT_ID to your agent's name")
if me not in roles:
    die(f"'{me}' is not a session of the registry ({' '.join(sorted(roles))})")
cmd = args[0] if args else ""
if cmd in ("request", "note"):
    if len(args) != 2:
        die(f"usage: bus.sh {cmd} <to> (the text on stdin)")
    post(args[1], "request" if cmd == "request" else "notice", None)
elif cmd in ("reply", "error"):
    if len(args) != 2:
        die(f"usage: bus.sh {cmd} <id> (the text on stdin)")
    orig = accepted().get(args[1])
    if orig is None:
        die(f"no message {args[1]} in the journal", 1)
    post(orig["details"]["env"]["from"], cmd, args[1])
elif cmd == "send":
    if len(args) not in (3, 5) or (len(args) == 5 and args[3] != "--reply-to"):
        die("usage: bus.sh send <to> <kind> [--reply-to <id>] (the text on stdin)")
    post(args[1], args[2], args[4] if len(args) == 5 else None)
elif cmd == "poll":
    kind = None
    if args[1:2] == ["--kind"] and len(args) == 3:
        kind = args[2]
    elif len(args) != 1:
        die("usage: bus.sh poll [--kind <kind>]")
    closed = {e["id"] for e in events() if e.get("event") in CLOSING}
    for rec in inbox(accepted()):
        if rec["env"]["id"] not in closed and (kind is None or rec["env"]["kind"] == kind):
            print(rec["env"]["id"])
elif cmd == "peek":
    if len(args) != 2:
        die("usage: bus.sh peek <id>")
    acc = accepted()
    rec = next((r for r in inbox(acc) if r["env"]["id"] == args[1]), None)
    if rec is None:
        a = acc.get(args[1])
        if a is None or a["details"]["env"]["from"] != me:
            die(f"no message {args[1]} to or from you ({me}) that the journal holds", 1)
        rec = {"env": a["details"]["env"]}
    print(json.dumps(rec["env"], ensure_ascii=False, sort_keys=True))
elif cmd == "receipt":
    if len(args) not in (3, 5) or args[2] not in ("read", "completed", "denied") or (len(args) == 5 and args[3] != "--reason"):
        die("usage: bus.sh receipt <id> read|completed|denied [--reason <text>]")
    acc = accepted()
    a = acc.get(args[1])
    if a is None:
        die(f"no message {args[1]} in the journal", 1)
    if a["details"]["env"]["to"] != me:
        die(f"message {args[1]} was sent to {a['details']['env']['to']}, not to you ({me})", 1)
    details = {"reason": " ".join(CONTROLS.sub("", args[4]).split())[:500]} if len(args) == 5 else {}
    with lock():
        e = event(last_seq() + 1, f"message.{args[2]}", args[1], details)
        append(journal, json.dumps(e, ensure_ascii=False) + "\n", private=True)
        append(log, json.dumps(e, ensure_ascii=False) + "\n")
    print(f"{args[1]} {args[2]}")
elif cmd == "state":
    if len(args) < 2:
        die("usage: bus.sh state <id>...")
    acc, evs = accepted(), events()
    for mid in args[1:]:
        a = acc.get(mid)
        if a is None or a["details"]["env"]["to"] != me:
            die(f"no message {mid} to you ({me}) in the journal", 1)
        out = [e for e in evs if e.get("id") == mid and e.get("event") in CLOSING]
        for e in out:
            rid = (e.get("details") or {}).get("reply") if e["event"] == "message.replied" else None
            print(f"{mid} {e['event'][len('message.'):]}" + (f" {rid}" if rid else ""))
        if not out:
            print(f"{mid} open")
elif cmd == "last":
    who = args[1] if len(args) > 1 else me
    last = None
    for e in lines(log):
        if isinstance(e, dict) and e.get("event") == "message.accepted":
            env = (e.get("details") or {}).get("env") or {}
            if who in (env.get("from"), env.get("to")):
                last = env
    if last is None:
        sys.exit(1)
    print(json.dumps(last, ensure_ascii=False, sort_keys=True))
else:
    die("usage: bus.sh request <to> | note <to> | reply <id> | error <id> | send <to> <kind> [--reply-to <id>] | poll [--kind <kind>] | peek <id> | receipt <id> read|completed|denied [--reason <text>] | state <id>... | last [<agent>]")
PYEOF
)

umask 022
MAILBOX_STATE_ROOT="${MAILBOX_STATE_ROOT}" MAILBOX_PROJECTION_ROOT="${MAILBOX_PROJECTION_ROOT}" SUPERVISOR_DIR="${SUPERVISOR_DIR}" \
	BUS_ME="${ME}" BUS_HUB="${AGENT_TMUX_SESSION_NAME}" BUS_SESSIONS="${SESSIONS}" python3 -I -c "${PY}" "$@"
