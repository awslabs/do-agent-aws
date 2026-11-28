#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The harness's cluster lock (docs/cluster-lock.md): one JSON lock file per cluster, <cluster>.json in CLUSTER_LOCK_DIR
# (default /wd/clusters/locks, the clusters spoke's lock directory), holding the lease - its holder, session, reason,
# claimed_at, expires_at and the GPUs and nodes it covers - a first-come queue, and the holders a stale reclaim
# displaced. Every change is made under an flock on the sibling <cluster>.lock file and lands by an atomic rename. The
# lock is advisory and per harness: it coordinates this harness's jobs, it reserves nothing from other people's
# workloads, and no host-wide lock file is read or written.
#
#   cluster-lock.sh claim <cluster> --holder <name> --ttl <minutes> [--reason <text>] [--session <name>]
#                   [--gpus <n>] [--nodes <node>=<n>[,<node>=<n>...]]
#                                    a free cluster is granted; a held one queues the claim (exit 2, its position);
#                                    an expired lease is reclaimed first (its holder recorded as displaced); the
#                                    holder's own claim renews its lease on the claim's terms, expired or not, and
#                                    the lease keeps its session. With --session (the session asking) a renewal is
#                                    refused (exit 2) unless that session is the holder or the lease's session
#   cluster-lock.sh queue join <cluster> ...    the same as claim
#   cluster-lock.sh queue list <cluster>        the queue, first in line first
#   cluster-lock.sh extend <cluster> --holder <name> --ttl <minutes>     the holder's lease expires <minutes> from now,
#                                    or keeps a later expiry it has (an extend never shortens a lease)
#   cluster-lock.sh release <cluster> --holder <name> [--session <name>]
#                                    the holder's release hands the lock to the queue head (its ttl runs from then) or
#                                    frees it; a queued holder's release leaves the queue. With --session (the
#                                    session asking, as the broker passes the request's sender) it is refused (exit 2)
#                                    unless that session is the holder or the session that claimed the lease
#   cluster-lock.sh reclaim-stale <cluster> [--by <name>]
#                                    a lease past its expires_at is reclaimed: the holder is recorded as displaced (who,
#                                    its expiry, when, by whom) and the queue head gets the lock; a live lease is refused
#   cluster-lock.sh status [<cluster>]          one line per lock file
#   cluster-lock.sh run-check <cluster> --holder <name> --ttl <minutes> [...]
#                                    what run reads before it claims, read-only: the claim's cluster, holder and ttl,
#                                    and whether that holder holds the cluster's lease live
#   cluster-lock.sh run <cluster> --holder <name> --ttl <minutes> [--reason <text>] -- <command> [<argument>...]
#                                    claim, run the command while the lease is held (renewed every half ttl), release
#                                    at the end, failed or not; exits with the command's code. Held by someone else,
#                                    the command does not run (exit 2) and the queue entry its claim joined is left
#                                    (an entry the holder had before stays; a queued claim's --json says joined). The
#                                    exit undoes what the claim took, a signal while it is written included. The command gets
#                                    CLUSTER_LOCK_RUN=<cluster>/<holder>: a run inside it for the same cluster and
#                                    holder, while that holder holds the lease live, claims nothing and leaves the
#                                    renewal and the release to this one (a marker with no live lease behind it makes
#                                    an ordinary run). A run killed with SIGKILL
#                                    runs no exit trap: its renewer stops at its next turn and the lease expires (a
#                                    command still running then runs on without it). Two runs at once under one
#                                    holder share one lease: the first to end releases it for both. A
#                                    renewal refused while the command runs is said on stderr; the command runs on
#
# --json prints one JSON object instead of the line. Names (cluster, holder, session) are a letter or digit, then
# letters, digits, '.', '_' or '-', at most 64 characters; a ttl is 1 to 1440 minutes, in digits only (so are --gpus
# and node counts). --session defaults to the tmux
# session of the pane, else BUS_AGENT_ID.
# Exit: 0 done; 2 held by another (a claim queued, or an extend, release or reclaim refused); 3 invalid (a malformed
# argument, an extend of a free cluster, or a lock file that is not this harness's: an older format, not JSON, or a "v": 1 file without the
# fields this tool writes, which is reported and never changed); 1 the lock directory cannot be written.
# Settings: CLUSTER_LOCK_DIR; CLUSTER_LOCK_RENEW_SEC (run's renewal interval, default half the ttl);
# CLUSTER_LOCK_HOLD_SEC (seconds a change holds the file lock between its read and its write, default 0: the race
# test sets it so two claims overlap).

CLUSTER_LOCK_DIR=${CLUSTER_LOCK_DIR:-${CLUSTERS_SPOKE_LOCKS:-${CLUSTERS_SPOKE_WD:-/wd/clusters}/locks}}
SESSION_AUTO=""
if [ -n "${TMUX_PANE}" ] && command -v tmux > /dev/null; then
	SESSION_AUTO=$(tmux display-message -p -t "${TMUX_PANE}" '#{session_name}' 2>/dev/null)
fi
[ -n "${SESSION_AUTO}" ] || SESSION_AUTO=${BUS_AGENT_ID}

PY=$(cat << 'PYEOF'
import fcntl, json, os, re, sys, time
from datetime import datetime, timezone

DIR = os.environ["CLUSTER_LOCK_DIR"]
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
NODE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,252}\Z")
CONTROLS = re.compile(r"[\x00-\x1f\x7f-\x9f]")
FORMAT = "%Y-%m-%dT%H:%M:%SZ"
MAX_TTL, MAX_GPUS, KEEP = 1440, 4096, 20
FIELDS = ("holder", "session", "reason", "claimed_at", "expires_at", "gpus", "nodes")
VALUED = ("--holder", "--ttl", "--reason", "--session", "--gpus", "--nodes", "--by")
args = sys.argv[1:]
as_json = "--json" in args
try:
    HOLD = float(os.environ.get("CLUSTER_LOCK_HOLD_SEC") or 0)
except ValueError:
    HOLD = 0.0
AUTO = os.environ.get("CLUSTER_LOCK_SESSION_AUTO") or None
AUTO = AUTO if AUTO and NAME.match(AUTO) else None


class Foreign(Exception):
    """a lock file that is not this harness's: reported, never changed"""


def emit(result, line, rc, d=None, **extra):
    if as_json:
        print(json.dumps(dict(result=result, line=line, lock=d, **extra), sort_keys=True))
    else:
        print(line)
    sys.exit(rc)


def invalid(why):
    print(f"cluster-lock.sh: {why}", file=sys.stderr)
    if as_json:
        print(json.dumps({"result": "invalid", "line": why, "lock": None}))
    sys.exit(3)


def stamp(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime(FORMAT)


def epoch(s):
    try:
        return datetime.strptime(s, FORMAT).replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def name(v, what):
    if not isinstance(v, str) or not NAME.match(v):
        invalid(f"{what} {v!r} is not a name: a letter or digit, then letters, digits, '.', '_' or '-', at most 64 characters")
    return v


def number(v, what, low, high):
    # digits only: int() alone also takes "1_0", "+5" and " 5", which no other reader of these values does
    if not isinstance(v, str) or not re.fullmatch(r"[0-9]{1,9}", v):
        invalid(f"{what} {v!r} is not a whole number (digits only)")
    n = int(v, 10)
    if not low <= n <= high:
        invalid(f"{what} {n} is not between {low} and {high}")
    return n


def parse(rest, allowed, npos):
    """the options of a verb (each of `allowed` takes a value; --json none) and its positionals (at most npos)"""
    opts, pos, i = {}, [], 0
    while i < len(rest):
        a = rest[i]
        if a == "--json":
            i += 1
        elif a.startswith("--"):
            if a not in allowed:
                invalid(f"unknown option {a}")
            if i + 1 >= len(rest):
                invalid(f"{a} needs a value")
            opts[a[2:]] = rest[i + 1]
            i += 2
        else:
            pos.append(a)
            i += 1
    if len(pos) > npos:
        invalid(f"one cluster at most, not {' '.join(pos)}")
    return opts, pos


def entry(opts):
    """a claim's terms: holder, session, reason, ttl_min, gpus, nodes"""
    if "holder" not in opts:
        invalid("--holder <name> is required: the job or session that holds the lease")
    if "ttl" not in opts:
        invalid("--ttl <minutes> is required: when the lease expires unless it is extended")
    gpus = number(opts["gpus"], "--gpus", 1, MAX_GPUS) if "gpus" in opts else None
    nodes = None
    if "nodes" in opts:
        nodes = {}
        for part in opts["nodes"].split(","):
            k, sep, v = part.partition("=")
            if not sep or not NODE.match(k) or k in nodes:
                invalid(f"--nodes {opts['nodes']!r} is not <node>=<n>,... with each node once")
            nodes[k] = number(v, f"the GPUs on {k}", 1, MAX_GPUS)
        total = sum(nodes.values())
        if gpus is None:
            gpus = total
        elif gpus != total:
            invalid(f"--nodes {opts['nodes']} adds up to {total} GPUs, not --gpus {gpus}")
    reason = " ".join(CONTROLS.sub(" ", opts.get("reason") or "").split())[:200] or None
    session = name(opts["session"], "--session") if "session" in opts else AUTO
    return {"holder": name(opts["holder"], "--holder"), "session": session, "reason": reason,
            "ttl_min": number(opts["ttl"], "--ttl", 1, MAX_TTL), "gpus": gpus, "nodes": nodes}


def path(c):
    return os.path.join(DIR, c + ".json")


def blank(c):
    return {"v": 1, "cluster": c, **{k: None for k in FIELDS}, "queue": [], "displaced": [], "updated_at": None}


def load(c):
    """the cluster's document (a blank one when it has no file); Foreign when the file is not this harness's"""
    p = path(c)
    try:
        raw = open(p, encoding="utf-8").read()
    except FileNotFoundError:
        return blank(c)
    except OSError as e:
        raise Foreign(f"{p} cannot be read ({e.strerror})")
    try:
        d = json.loads(raw)
    except ValueError:
        raise Foreign(f"{p} is not readable JSON: it is reported, never changed")
    if not isinstance(d, dict) or d.get("v") != 1 or d.get("cluster") != c:
        raise Foreign(f"{p} is not a lock file of this harness (no \"v\": 1 for {c}): it is reported, never changed")
    why = malformed(d)
    if why:
        raise Foreign(f"{p} is not a lock file of this harness ({why}): it is reported, never changed")
    d.setdefault("displaced", [])
    return d


def malformed(d):
    """why a v1 document is not one this tool writes, or None"""
    missing = [k for k in FIELDS + ("queue",) if k not in d]
    if missing:
        return "no " + ", ".join(missing)
    if d["holder"] is not None and (not isinstance(d["holder"], str) or not NAME.match(d["holder"])):
        return "a holder that is not a name"
    if d["holder"] is not None and (epoch(d["claimed_at"]) is None or epoch(d["expires_at"]) is None):
        return "a lease without its claimed_at and expires_at"
    if not isinstance(d["queue"], list) or not isinstance(d.get("displaced", []), list):
        return "a queue or a displaced list that is not a list"
    for x in d["queue"]:
        if not isinstance(x, dict) or not isinstance(x.get("holder"), str) or not NAME.match(x["holder"]):
            return "a queue entry without a holder"
        if not isinstance(x.get("ttl_min"), int) or isinstance(x["ttl_min"], bool) or not 1 <= x["ttl_min"] <= MAX_TTL:
            return f"a queue entry without its ttl ({x['holder']})"
        if epoch(x.get("queued_at")) is None:
            return f"a queue entry without its queued_at ({x['holder']})"
    if d["nodes"] is not None and not (isinstance(d["nodes"], dict) and all(isinstance(v, int) for v in d["nodes"].values())):
        return "nodes that are not node: count"
    return None


def save(d, now):
    d["updated_at"] = stamp(now)
    p = path(d["cluster"])
    tmp = f"{p}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, indent=1)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, p)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        print(f"cluster-lock.sh: cannot write {p}: {e.strerror}", file=sys.stderr)
        sys.exit(1)


def change(c, fn):
    """fn(d, now) on the cluster's document under its file lock; fn returns (result, line, rc, extra, dirty)"""
    try:
        os.makedirs(DIR, mode=0o755, exist_ok=True)
        fd = os.open(os.path.join(DIR, c + ".lock"), os.O_WRONLY | os.O_CREAT, 0o644)
    except OSError as e:
        print(f"cluster-lock.sh: cannot use the lock directory {DIR}: {e.strerror}", file=sys.stderr)
        sys.exit(1)
    with os.fdopen(fd, "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            d = load(c)
        except Foreign as e:
            invalid(str(e))
        if HOLD > 0:
            time.sleep(HOLD)
        now = time.time()
        result, line, rc, extra, dirty = fn(d, now)
        if dirty:
            save(d, now)
    emit(result, line, rc, d, **extra)


def expired(d, now):
    t = epoch(d.get("expires_at"))
    return d.get("holder") is not None and (t is None or t <= now)


def grant(d, e, now):
    d.update(holder=e["holder"], session=e.get("session"), reason=e.get("reason"), claimed_at=stamp(now),
             expires_at=stamp(now + 60 * e["ttl_min"]), gpus=e.get("gpus"), nodes=e.get("nodes"))


def promote(d, now):
    """the queue head gets the lock, its ttl running from now; with no queue the lock is free"""
    if d["queue"]:
        grant(d, d["queue"].pop(0), now)
    else:
        d.update({k: None for k in FIELDS})


def reclaim(d, now, by):
    rec = {k: d.get(k) for k in FIELDS}
    rec.update(reclaimed_at=stamp(now), by=by)
    d["displaced"] = (d.get("displaced") or [])[-(KEEP - 1):] + [rec]
    promote(d, now)


def scope(d):
    g, n = d.get("gpus"), d.get("nodes")
    if n:
        return f"{g} GPUs on " + ", ".join(f"{k}={v}" for k, v in n.items())
    return f"{g} GPUs on the whole cluster" if g else "the whole cluster"


def after(d):
    return f"now held by {d['holder']} until {d['expires_at']}" if d["holder"] else "free"


def claim(c, e, asker=None):
    """asker: the session the claim is made on behalf of (--session, as the broker passes the request's sender); a
    renewal of the holder's lease is refused unless it is the holder or the lease's session, as a release is"""
    h = e["holder"]
    read = {"cluster": c, "holder": h, "ttl_min": e["ttl_min"]}

    def fn(d, now):
        before, note, dirty = d["holder"], "", False
        if before is not None and before != h and expired(d, now):
            note = f"; reclaimed from {before}, expired {d['expires_at']}"
            reclaim(d, now, h)
            dirty = True
        if d["holder"] is None:
            grant(d, e, now)
            return "granted", f"granted {c} to {h} until {d['expires_at']} ({scope(d)}){note}", 0, read, True
        if d["holder"] == h:
            # the holder's own lease, live or expired, or the queue head the reclaim just promoted: renewed on this
            # claim's terms, so a job that comes back under the same name (after a crash or a restart) holds a live
            # lease again and displaces nobody. The lease keeps its session, and a claim on behalf of a session that is
            # neither the holder nor the lease's session renews nothing (it could cut the lease short and move it)
            if asker is not None and asker not in (h, d.get("session")):
                return ("refused", f"held by {h} for session {d.get('session') or '-'}: {asker} may not renew it", 2,
                        dict(read, held_by=h, held_until=d["expires_at"]), dirty)
            session = d.get("session") or e.get("session")
            grant(d, e, now)
            d["session"] = session
            if before != h:
                return "granted", f"granted {c} to {h} until {d['expires_at']} ({scope(d)}){note}", 0, read, True
            return "granted", f"renewed {c} for {h} until {d['expires_at']} ({scope(d)})", 0, dict(read, renewed=True), True
        queued = [x["holder"] for x in d["queue"]]
        joined = h not in queued
        if joined:
            # a queued claim keeps the GPUs it wants, not nodes: which nodes are free is a question for its grant
            d["queue"].append(dict(e, nodes=None, queued_at=stamp(now)))
            queued.append(h)
            dirty = True
        pos = queued.index(h) + 1
        # joined: this claim added the entry (an entry from before it, such as the hub's queued lease, is not its own)
        return ("queued", f"queued {h} for {c} at position {pos}: held by {d['holder']} until {d['expires_at']}{note}", 2,
                dict(read, position=pos, held_by=d["holder"], held_until=d["expires_at"], joined=joined), dirty)
    change(c, fn)


def run_check(c, e):
    """what run reads before it claims: the claim's cluster, holder and ttl, and whether that holder holds the
    cluster's lease live now; read-only (a lock file that is not the harness's is invalid, as for a claim)"""
    try:
        d = load(c)
    except Foreign as x:
        invalid(str(x))
    live = d["holder"] == e["holder"] and not expired(d, time.time())
    emit("checked", f"{c}: {e['holder']} {'holds the lease, live' if live else 'holds no live lease'}", 0, d,
         cluster=c, holder=e["holder"], ttl_min=e["ttl_min"], live=live)


def extend(c, h, ttl):
    def fn(d, now):
        if d["holder"] is None:
            invalid(f"{c} is free: claim it first")
        if d["holder"] != h:
            return "refused", f"held by {d['holder']}, not {h}: not extended", 2, {}, False
        # an extend never shortens a lease: one that already runs past the new expiry keeps its own
        if epoch(d["expires_at"]) > now + 60 * ttl:
            return "kept", f"{c} for {h} already runs until {d['expires_at']}, later than {ttl} min from now: kept", 0, {}, False
        d["expires_at"] = stamp(now + 60 * ttl)
        return "extended", f"extended {c} for {h} until {d['expires_at']}", 0, {}, True
    change(c, fn)


def release(c, h, asker=None):
    """asker: the session the release is made on behalf of (the broker's request sender); it must be the holder or the
    session that claimed the lease or the queue entry"""
    def denied(owner_session):
        return asker is not None and asker not in (h, owner_session)

    def fn(d, now):
        if d["holder"] is None:
            return "free", f"{c} is free: nothing to release", 0, {}, False
        if d["holder"] == h:
            if denied(d.get("session")):
                return ("refused", f"held by {h} for session {d.get('session') or '-'}: {asker} may not release it", 2, {}, False)
            promote(d, now)
            return "released", f"released {c} by {h}; {after(d)}", 0, {"next_holder": d["holder"]}, True
        entry = next((x for x in d["queue"] if x["holder"] == h), None)
        if entry is not None:
            if denied(entry.get("session")):
                return ("refused", f"{h} is queued for session {entry.get('session') or '-'}: {asker} may not take it out", 2, {}, False)
            d["queue"] = [x for x in d["queue"] if x["holder"] != h]
            return "left", f"{h} left the queue of {c}", 0, {}, True
        return "refused", f"held by {d['holder']}, not {h}: not released", 2, {}, False
    change(c, fn)


def reclaim_stale(c, by):
    def fn(d, now):
        if d["holder"] is None:
            return "free", f"{c} is free: nothing to reclaim", 0, {}, False
        if not expired(d, now):
            return "refused", f"held by {d['holder']} until {d['expires_at']}, live: not reclaimed", 2, {}, False
        old, oexp = d["holder"], d["expires_at"]
        reclaim(d, now, by)
        return ("reclaimed", f"reclaimed {c} from {old} (expired {oexp}) by {by or '-'}; {after(d)}", 0,
                {"displaced": old, "next_holder": d["holder"]}, True)
    change(c, fn)


def status_line(c, d, now):
    if d["holder"] is None:
        return f"{c}: free"
    why = f", for {d['reason']}" if d.get("reason") else ""
    queue = ", ".join(x["holder"] for x in d["queue"]) or "empty"
    return (f"{c}: held by {d['holder']} (session {d.get('session') or '-'}) until {d['expires_at']}, "
            f"{'EXPIRED' if expired(d, now) else 'live'}, {scope(d)}{why}; queue: {queue}")


def foreign(f):
    """the line and the record of a lock file that is not this harness's"""
    try:
        d = json.load(open(os.path.join(DIR, f), encoding="utf-8"))
    except (OSError, ValueError):
        return f"{f}: not readable JSON", {"file": f, "state": "unreadable"}
    if not isinstance(d, dict):
        return f"{f}: not a lock file of this harness", {"file": f, "state": "foreign"}
    bits = [f"holder {d.get('holder') or 'none'}"]
    if d.get("claimed_at"):
        bits.append(f"claimed {d['claimed_at']}")
    if d.get("timeout_minutes") is not None:
        bits.append(f"timeout {d['timeout_minutes']} min")
    rec = {"file": f, "state": "foreign", "holder": d.get("holder"), "claimed_at": d.get("claimed_at"), "timeout_minutes": d.get("timeout_minutes")}
    return f"{f}: not a lock file of this harness ({', '.join(bits)})", rec


def status(only):
    now, lines, items = time.time(), [], []
    if only is not None and not os.path.exists(path(only)):
        lines, items = [f"{only}: free (no lock file)"], [dict(blank(only), file=only + ".json", state="free")]
    else:
        try:
            files = [only + ".json"] if only is not None else sorted(f for f in os.listdir(DIR) if f.endswith(".json"))
        except FileNotFoundError:
            files = []
        for f in files:
            c = f[:-len(".json")]
            try:
                if not NAME.match(c):
                    raise Foreign(f)
                d = load(c)
            except Foreign:
                line, rec = foreign(f)
                lines.append(line)
                items.append(dict(rec, cluster=c))
                continue
            lines.append(status_line(c, d, now))
            items.append(dict(d, file=f, state="free" if d["holder"] is None else "expired" if expired(d, now) else "live"))
    if as_json:
        print(json.dumps({"dir": DIR, "locks": items}, sort_keys=True))
    else:
        print("\n".join(lines or [f"no locks under {DIR}"]))
    sys.exit(0)


def queue_list(c):
    try:
        d = load(c)
    except Foreign as e:
        invalid(str(e))
    if as_json:
        print(json.dumps({"cluster": c, "queue": d["queue"]}, sort_keys=True))
        sys.exit(0)
    if not d["queue"]:
        print(f"queue of {c}: empty")
    for i, x in enumerate(d["queue"], 1):
        why = f", for {x['reason']}" if x.get("reason") else ""
        print(f"{i}. {x['holder']} (session {x.get('session') or '-'}), {scope(x)}, {x['ttl_min']} min, queued {x['queued_at']}{why}")
    sys.exit(0)


USAGE = ("usage: cluster-lock.sh claim <cluster> --holder <name> --ttl <minutes> [--reason <text>] [--session <name>] "
         "[--gpus <n>] [--nodes <node>=<n>,...] | queue join|list <cluster> ... | extend <cluster> --holder <name> --ttl <minutes> "
         "| release <cluster> --holder <name> | reclaim-stale <cluster> [--by <name>] | status [<cluster>] "
         "| run <cluster> --holder <name> --ttl <minutes> [--reason <text>] -- <command> [<argument>...]; --json for one JSON object")
verb, rest = (args[0], args[1:]) if args else ("", [])
if verb == "queue":
    sub = rest[0] if rest else ""
    if sub not in ("join", "list"):
        invalid("queue join <cluster> ... or queue list <cluster>; " + USAGE)
    verb, rest = ("claim" if sub == "join" else "queue-list"), rest[1:]
ALLOWED = {"claim": ("--holder", "--ttl", "--reason", "--session", "--gpus", "--nodes"), "extend": ("--holder", "--ttl"),
           "run-check": ("--holder", "--ttl", "--reason", "--session", "--gpus", "--nodes"),
           "release": ("--holder", "--session"), "reclaim-stale": ("--by",), "status": (), "queue-list": ()}
if verb not in ALLOWED:
    invalid((f"unknown verb {verb!r}; " if verb else "") + USAGE)
opts, pos = parse(rest, ALLOWED[verb], 1)
if verb == "status":
    status(name(pos[0], "the cluster") if pos else None)
if not pos:
    invalid(f"{verb} needs a cluster; " + USAGE)
cluster = name(pos[0], "the cluster")
if verb == "claim":
    claim(cluster, entry(opts), name(opts["session"], "--session") if "session" in opts else None)
elif verb == "queue-list":
    queue_list(cluster)
elif verb == "run-check":
    run_check(cluster, entry(opts))
elif verb == "extend":
    if "holder" not in opts or "ttl" not in opts:
        invalid("extend needs --holder <name> and --ttl <minutes>")
    extend(cluster, name(opts["holder"], "--holder"), number(opts["ttl"], "--ttl", 1, MAX_TTL))
elif verb == "release":
    if "holder" not in opts:
        invalid("release needs --holder <name>")
    release(cluster, name(opts["holder"], "--holder"), name(opts["session"], "--session") if "session" in opts else None)
else:
    reclaim_stale(cluster, name(opts["by"], "--by") if "by" in opts else AUTO)
PYEOF
)

umask 022
core()
{
	CLUSTER_LOCK_DIR="${CLUSTER_LOCK_DIR}" CLUSTER_LOCK_SESSION_AUTO="${SESSION_AUTO}" python3 -I -c "${PY}" "$@"
}

[ "${1:-}" == "run" ] || { core "$@"; exit $?; }

# run: claim, the command while the lease is held, the release at the end
shift
ARGS=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do ARGS+=("$1"); shift; done
if [ "${1:-}" != "--" ] || [ $# -lt 2 ]; then
	echo "cluster-lock.sh: run needs its command after --: run <cluster> --holder <name> --ttl <minutes> [--reason <text>] -- <command> [<argument>...]" >&2
	exit 3
fi
shift
# the cluster, the holder and the ttl as a claim reads them (options may come before the cluster; the ttl is digits),
# and whether that holder holds the cluster's lease live now; nothing is changed yet
P=$(core run-check "${ARGS[@]}" --json)
RC=$?
[ ${RC} -eq 0 ] || exit ${RC}
IFS=$'\t' read -r RUN_CLUSTER RUN_HOLDER RUN_TTL RUN_LIVE < <(printf '%s' "${P}" | python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = {}
print("\t".join(str(d.get(k) or "") for k in ("cluster", "holder", "ttl_min", "live")))')
case "${RUN_TTL}" in ''|*[!0-9]*) echo "cluster-lock.sh: run: the claim's reading names no ttl: ${P}" >&2; exit 1 ;; esac
[ -n "${RUN_CLUSTER}" ] && [ -n "${RUN_HOLDER}" ] || { echo "cluster-lock.sh: run: the claim's reading names no cluster or holder: ${P}" >&2; exit 1; }
if [ "${CLUSTER_LOCK_RUN:-}" == "${RUN_CLUSTER}/${RUN_HOLDER}" ] && [ "${RUN_LIVE}" == "True" ]; then
	# inside a run of this lease: the command carries its marker and the holder holds the lease live. That run renews
	# and releases; this one claims nothing, so its own ttl can neither shorten nor lengthen the lease. A marker with
	# no live lease behind it (inherited from a run that is gone) makes an ordinary run
	echo "cluster-lock.sh: inside the run that holds ${RUN_CLUSTER} for ${RUN_HOLDER}: that run renews and releases the lease" >&2
	"$@"
	exit $?
fi
# what this run takes is undone at its exit, from its claim's answer: a lease it was granted or renewed is released
# once the renewer has stopped, and a queue entry its claim joined is left; a refusal, or the holder's queue entry from
# before this run, is not this run's. The traps are set before the claim, so a signal while it is written undoes it too
J=""
RENEWER=""
cluster_lock_undo()
{
	if [ -n "${RENEWER}" ]; then
		kill "${RENEWER}" 2>/dev/null
		wait "${RENEWER}" 2>/dev/null
	fi
	local TOOK
	TOOK=$(printf '%s' "${J}" | python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = None
took = isinstance(d, dict) and (d.get("result") == "granted" or (d.get("result") == "queued" and d.get("joined") is True))
print(d["result"] if took else "")')
	case "${TOOK}" in
		granted) echo "cluster-lock.sh: $(core release "${RUN_CLUSTER}" --holder "${RUN_HOLDER}" 2>&1)" >&2 ;;
		queued) core release "${RUN_CLUSTER}" --holder "${RUN_HOLDER}" > /dev/null 2>&1 ;;
	esac
}
trap cluster_lock_undo EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
J=$(core claim "${ARGS[@]}" --json)
RC=$?
[ ${RC} -eq 0 ] || [ ${RC} -eq 2 ] || exit ${RC}
LINE=$(printf '%s' "${J}" | python3 -I -c 'import json, sys
try:
    print(json.load(sys.stdin).get("line") or "")
except (ValueError, AttributeError):
    print("")')
if [ ${RC} -eq 2 ]; then
	# not ours to wait for: the command does not run, and the exit leaves the queue entry this claim joined
	echo "cluster-lock.sh: not run: ${LINE}" >&2
	exit 2
fi
echo "cluster-lock.sh: ${LINE}" >&2
# every half ttl; CLUSTER_LOCK_RENEW_SEC only when it is a whole number of seconds of at least 1
RENEW=$((10#${RUN_TTL} * 30))
case "${CLUSTER_LOCK_RENEW_SEC:-}" in ''|*[!0-9]*) ;; *) [ "$((10#${CLUSTER_LOCK_RENEW_SEC}))" -ge 1 ] && RENEW=$((10#${CLUSTER_LOCK_RENEW_SEC})) ;; esac
RUN_PID=$$
(
	# the renewer's sleep dies with it (jobs -p lists it as soon as it is started, so a TERM cannot leave it behind) and
	# has its stdin, stdout and stderr on /dev/null; the renewer itself keeps the caller's stderr for its warning and ends
	# with run. A run killed with SIGKILL runs no exit trap, so the renewer stops by itself at its next turn once that
	# run is gone, and the lease is left to expire
	trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
	while :; do
		sleep "${RENEW}" < /dev/null > /dev/null 2>&1 &
		wait $!
		kill -0 "${RUN_PID}" 2>/dev/null || exit 0
		# a renewal refused (the lease was released or reclaimed under the command) is said, then renewing stops
		OUT=$(core extend "${RUN_CLUSTER}" --holder "${RUN_HOLDER}" --ttl "${RUN_TTL}" 2>&1) || {
			echo "cluster-lock.sh: run: the lease of ${RUN_CLUSTER} for ${RUN_HOLDER} could not be renewed (${OUT}); the command runs on without it" >&2
			exit 0
		}
	done
) > /dev/null &
RENEWER=$!
# the marker tells a run inside this command that the lease is this run's to renew and release
CLUSTER_LOCK_RUN="${RUN_CLUSTER}/${RUN_HOLDER}" "$@"
exit $?
