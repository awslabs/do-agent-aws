#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The clusters spoke's GPU broker (docs/cluster-lock.md). One run reclaims the leases of the harness's cluster lock
that are past their expiry, then answers the spoke's open gpu-lease and gpu-release requests on the bus, oldest first,
with a lease of that lock (/agent/cluster-lock.sh): scoped to GPUs on named nodes when the spoke's current view
(status.json, written by its cycle) shows them free on usable nodes, else the whole cluster's lock, the reply saying
why. Any other request stays open for the spoke's session. A lease is a file in this harness: nothing here changes a
cluster, and a request's text is data, never a command.

  request (the text of a bus request to the spoke, JSON):
    {"kind": "gpu-lease", "cluster": "<lock name>", "gpus": <1-4096>, "ttl_min": <1-1440>, "reason": "...", "holder": "<name>"}
    {"kind": "gpu-release", "cluster": "<lock name>", "holder": "<name>"}
    holder defaults to the sender; reason is optional
  reply (JSON): kind, result (granted, queued, released, left, free or refused), cluster, holder, line (the lock's one-
    line result); a lease adds gpus, nodes (null: the whole cluster), expires_at and view (what the view allowed);
    queued adds position, held_by and held_until; a release adds next_holder. A malformed request gets a bus error
    with result invalid and why.

The spoke's cycle (loop.sh) runs it after it writes the view; the spoke's session can run it at once from its pane:
python3 /agent/charters/clusters/broker.py. Settings: CLUSTERS_SPOKE_WD (default /wd/clusters), CLUSTERS_SPOKE_LOCKS
(default its locks/), AGENT_DIR (where cluster-lock.sh and bus.sh are; default two directories up from this file),
CLUSTERS_BROKER_VIEW_MAX_AGE_SEC (a view older than this scopes nothing; default 1800), CLUSTERS_BROKER_CALL_TIMEOUT_SEC
(each call to the lock or the bus; default 120): a value that is not a whole number of seconds is named and the default
used, and a call past its timeout is an error of the run (exit 1), never a crash. On the bus it is BUS_AGENT_ID,
or the session of its tmux pane; with neither it only reclaims. One run at a time: a run holds an flock on
broker.lock in the working directory, so the cycle's run and the session's never answer a request twice.
"""
import fcntl, json, os, re, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

WD = os.environ.get("CLUSTERS_SPOKE_WD") or "/wd/clusters"
LOCKS = os.environ.get("CLUSTERS_SPOKE_LOCKS") or os.path.join(WD, "locks")
AGENT_DIR = os.environ.get("AGENT_DIR") or str(Path(__file__).resolve().parents[2])
LOCK, BUS = os.path.join(AGENT_DIR, "cluster-lock.sh"), os.path.join(AGENT_DIR, "bus.sh")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
ME = os.environ.get("BUS_AGENT_ID") or None
errors = []
# the escaped length a reply's text may have: bus.sh fits the whole envelope, the text JSON-escaped, in 2048 bytes
TEXT_LIMIT = 1200
# the characters of why an error reply carries: a refusal can echo a long --nodes string
WHY_LIMIT = 300


def short(why):
    why = str(why or "")
    return why if len(why) <= WHY_LIMIT else why[:WHY_LIMIT - 3] + "..."


def setting(name, default):
    """a whole number of seconds of at least 1 from the environment; anything else is named and the default used"""
    v = os.environ.get(name)
    if v is None or v == "":
        return default
    if re.fullmatch(r"[0-9]{1,9}", v) and int(v) >= 1:
        return int(v)
    errors.append(f"{name}={v!r} is not a whole number of seconds of at least 1: {default} is used")
    return default


MAX_AGE = setting("CLUSTERS_BROKER_VIEW_MAX_AGE_SEC", 1800)
CALL_TIMEOUT = setting("CLUSTERS_BROKER_CALL_TIMEOUT_SEC", 120)
LOCK_WAIT = setting("CLUSTERS_BROKER_LOCK_WAIT_SEC", 60)


def call(cmd, what, **kw):
    """one subprocess, or None with the reason in errors (a call that hangs or cannot start ends nothing but itself)"""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=CALL_TIMEOUT, **kw)  # nosemgrep: dangerous-subprocess-use-audit -- argv lists the broker builds itself (kubectl and its own scripts); no shell
    except subprocess.TimeoutExpired:
        errors.append(f"{what} timed out after {CALL_TIMEOUT} s")
    except OSError as e:
        errors.append(f"{what} could not run: {e.strerror}")
    return None


def epoch(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def lock(*a):
    """the cluster lock's exit code and its JSON result; (None, None) when the call itself failed (named in errors)"""
    r = call([LOCK, *a, "--json"], f"cluster-lock.sh {a[0]}", env=dict(os.environ, CLUSTER_LOCK_DIR=LOCKS))
    if r is None:
        return None, None
    try:
        out = json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        out = {"result": "invalid", "line": (r.stderr.strip() or "no output")[-300:]}
    return r.returncode, out


def pick(free, n):
    """n GPUs from {node: free}: whole nodes, largest first, then the smallest node that fits the rest; None if too few"""
    if sum(free.values()) < n:
        return None
    left, out, need = dict(free), {}, n
    while need > 0:
        fit = [k for k, v in left.items() if v >= need]
        if fit:
            out[min(fit, key=lambda k: (left[k], k))] = need
            break
        k = min(left, key=lambda k: (-left[k], k))
        out[k] = left.pop(k)
        need -= out[k]
    return out


def view_for(view, cluster, gpus):
    """the nodes the view allows for gpus GPUs (None: the whole cluster) and the words for what it allowed"""
    if view is None:
        return None, "no cluster view: the spoke has not read the clusters yet"
    at = view.get("generated_utc") or "?"
    t = epoch(at)
    if t is None or time.time() - t > MAX_AGE:
        return None, f"no cluster view of {cluster}: the last read, {at}, is older than {MAX_AGE // 60} minutes"
    ctxs = view["contexts"]
    # the lock's name is the context's, or for an EKS context (a cluster ARN) the cluster's name after "cluster/"
    match = [c for c in ctxs if c == cluster] or [c for c in ctxs if c.startswith("arn:") and c.endswith(":cluster/" + cluster)]
    if not match:
        return None, f"no cluster view of {cluster}: not one of the contexts the spoke reads ({len(ctxs)} in STATUS.md)"
    if len(match) > 1:
        return None, f"no cluster view of {cluster}: {len(match)} contexts carry that name"
    c = ctxs[match[0]]
    if not c.get("reachable"):
        return None, f"no cluster view of {cluster}: unreachable at {at}"
    free = {}
    for r in c.get("nodes") or []:
        # a lease names its nodes as Kubernetes does (the row's k8s_name); a view an older loop wrote has only the
        # short name its table shows; a row with neither is left out, and named
        name = (r.get("k8s_name") if isinstance(r.get("k8s_name"), str) else r.get("node")) if isinstance(r, dict) else None
        if not isinstance(name, str) or not name:
            errors.append(f"the view of {cluster} has a node row with no node name: it is left out")
            continue
        n = r.get("gpu_free") if isinstance(r.get("gpu_free"), int) else 0
        if r.get("usable") and n > 0:
            free[name] = n
    nodes = pick(free, gpus)
    if nodes is None:
        return None, f"the view of {at} shows {sum(free.values())} free GPUs on usable nodes of {cluster}, fewer than {gpus}: the lease is the whole cluster's lock"
    return nodes, f"the view of {at}"


def check(q):
    """why a gpu-lease or gpu-release request is malformed, or None"""
    if not isinstance(q.get("cluster"), str) or not NAME.match(q["cluster"]):
        return "cluster must be a lock name: a letter or digit, then letters, digits, '.', '_' or '-', at most 64 characters"
    if q.get("holder") is not None and (not isinstance(q["holder"], str) or not NAME.match(q["holder"])):
        return "holder must be a name of the same form as a cluster's"
    if q["kind"] == "gpu-release":
        return None
    whole = lambda v, lo, hi: isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi
    if not whole(q.get("gpus"), 1, 4096):
        return "gpus must be a whole number from 1 to 4096"
    if not whole(q.get("ttl_min"), 1, 1440):
        return "ttl_min must be a whole number of minutes from 1 to 1440"
    if q.get("reason") is not None and not isinstance(q["reason"], str):
        return "reason must be text"
    return None


def handle(env, view):
    """the answer to one request: (bus verb, body), or None when it is not the broker's to answer"""
    try:
        q = json.loads(env.get("text") or "")
    except ValueError:
        return None
    if not isinstance(q, dict) or q.get("kind") not in ("gpu-lease", "gpu-release"):
        return None
    kind = q["kind"]
    why = check(q)
    if why:
        return "error", {"kind": kind, "result": "invalid", "why": why}
    sender = env.get("from")
    if not isinstance(sender, str) or not NAME.match(sender):
        return "error", {"kind": kind, "result": "invalid", "why": "the request's envelope names no sender: there is no session to answer for"}
    holder = q.get("holder") or sender
    if kind == "gpu-release":
        # on behalf of the sender: only the holder or the session that claimed the lease may release it
        rc, out = lock("release", q["cluster"], "--holder", holder, "--session", sender)
        if rc is None:
            return None
        if rc not in (0, 2):
            return "error", {"kind": kind, "result": "invalid", "why": short(out.get("line"))}
        return "reply", {"kind": kind, "result": out["result"], "cluster": q["cluster"], "holder": holder,
                         "next_holder": out.get("next_holder"), "line": out["line"]}
    nodes, words = view_for(view, q["cluster"], q["gpus"])
    a = ["claim", q["cluster"], "--holder", holder, "--session", sender, "--ttl", str(q["ttl_min"]), "--gpus", str(q["gpus"])]
    if q.get("reason"):
        a += ["--reason", q["reason"]]
    if nodes:
        a += ["--nodes", ",".join(f"{k}={v}" for k, v in nodes.items())]
    rc, out = lock(*a)
    if rc is None:
        return None
    if rc not in (0, 2):
        return "error", {"kind": kind, "result": "invalid", "why": short(out.get("line"))}
    d = out.get("lock") or {}
    body = {"kind": kind, "result": out["result"], "cluster": q["cluster"], "holder": holder, "view": words, "line": out["line"]}
    if rc == 0:
        body.update(gpus=d.get("gpus"), nodes=d.get("nodes"), expires_at=d.get("expires_at"))
    else:
        body.update(gpus=q["gpus"], nodes=None, position=out.get("position"), held_by=out.get("held_by"), held_until=out.get("held_until"))
    return "reply", body


def send(verb, mid, body):
    text = json.dumps(body, sort_keys=True)
    if len(json.dumps(text)) > TEXT_LIMIT and body.get("nodes"):
        # too long for the journal line: the node list, and the line that names every node, stay in the lock file
        n, path = len(body["nodes"]), os.path.join(LOCKS, body["cluster"] + ".json")
        body = dict({k: v for k, v in body.items() if k != "nodes"}, nodes_file=path,
                    line=f"{body['result']} {body['cluster']} to {body['holder']} until {body.get('expires_at')} ({body.get('gpus')} GPUs on {n} nodes, listed in {path})")
        text = json.dumps(body, sort_keys=True)
    r = call([BUS, verb, mid], f"bus {verb} to {mid}", input=text)
    if r is not None and r.returncode != 0:
        errors.append(f"bus {verb} to {mid} failed: {r.stderr.strip()[-200:]}")
    return r is not None and r.returncode == 0


def expire():
    """reclaim every lease past its expiry; the number reclaimed"""
    rc, out = lock("status")
    if rc is None:
        return 0
    if rc != 0:
        errors.append(f"cluster-lock.sh status failed: {out.get('line')}")
        return 0
    n = 0
    for x in out.get("locks") or []:
        if x.get("state") == "expired":
            rc, o = lock("reclaim-stale", x["cluster"], *(["--by", ME] if ME else []))
            if rc is None:
                continue
            if rc == 0 and o.get("result") == "reclaimed":
                n += 1
            elif rc != 2:
                errors.append(f"reclaim of {x['cluster']} failed: {o.get('line')}")
    return n


def main():
    if not os.access(LOCK, os.X_OK):
        print(f"broker: no cluster lock at {LOCK}", file=sys.stderr)
        return 1
    # one run at a time (the cycle's and the session's): a second run polls only after the first has answered. It
    # waits at most LOCK_WAIT seconds, then answers nothing and names the run that holds the lock (its pid and start,
    # which the holder writes into the lock file), rather than waiting out the loop's own timeout
    os.makedirs(WD, exist_ok=True)
    path = os.path.join(WD, "broker.lock")
    run_lock = open(path, "a+")  # nosemgrep: open-never-closed -- the flock lock file is held open for the process lifetime on purpose
    deadline = time.time() + LOCK_WAIT
    while True:
        try:
            fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.time() >= deadline:
                run_lock.seek(0)
                who = " ".join(run_lock.read().split())[:200] or "a run that wrote nothing into it"
                print(f"broker: {path} is held by another broker run ({who}) after {LOCK_WAIT} s: this run answers nothing", file=sys.stderr)
                return 1
            time.sleep(0.5)  # nosemgrep: arbitrary-sleep -- retry interval of a bounded lock wait
    run_lock.seek(0)
    run_lock.truncate()
    run_lock.write(f"pid {os.getpid()} since {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
    run_lock.flush()
    try:
        view = json.load(open(os.path.join(WD, "status.json"), encoding="utf-8"))
        view = view if isinstance(view, dict) and isinstance(view.get("contexts"), dict) else None
    except (OSError, ValueError):
        view = None
    reclaimed = expire()
    counts = {}
    if not (ME or os.environ.get("TMUX_PANE")):
        bus = "bus skipped (no BUS_AGENT_ID and no tmux pane: not run as the spoke)"
    elif not os.access(BUS, os.X_OK):
        errors.append(f"no bus helper at {BUS}")
        bus = "no bus"
    else:
        r = call([BUS, "poll", "--kind", "request"], "bus poll")
        if r is not None and r.returncode != 0:
            errors.append(f"bus poll failed: {r.stderr.strip()[-200:]}")
        for mid in (r.stdout.split() if r is not None else []):
            p = call([BUS, "peek", mid], f"bus peek {mid}")
            if p is None:
                continue
            try:
                env = json.loads(p.stdout)
            except ValueError:
                continue
            a = handle(env, view)
            if a and send(a[0], mid, a[1]):
                k = a[1]["result"] if a[0] == "reply" else "error"
                counts[k] = counts.get(k, 0) + 1
        bus = f"{sum(counts.values())} answered" + (" (" + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())) + ")" if counts else "")
    print(f"broker: {bus}, {reclaimed} reclaimed; view {view.get('generated_utc') if view else 'none'}")
    for e in errors:
        print(f"broker: {e}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
