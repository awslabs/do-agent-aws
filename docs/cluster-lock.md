# The cluster lock and GPU leases

Several jobs of one harness can want the same GPU cluster at once: the hub's own work, a worker's goal, a test
series. The cluster lock keeps them from running over each other. It is one small JSON file per cluster, a lease
with a holder and an expiry, and a queue behind it. The `clusters` spoke brokers it: it answers lease requests from
its view of the cluster and reclaims leases that expire.

**The rule.** Every job that touches a cluster takes a lease first and releases it when it ends, failed or not. The
agent's operating rules (`agent-rules/AGENT_RULES.md`, loaded by every session and every headless fire) and the
`clusters` spoke's charter say the same. The simplest form is one call:

```
/agent/cluster-lock.sh run demo --holder gpucheck --ttl 30 --reason "read the GPU nodes" -- ./gpucheck nodes
```

`run` claims the lock, runs the command only once the lease is granted and renews it every half ttl while the
command runs. It releases the lease when the command ends and exits with the command's own code. When someone else
holds the lock, the command does not run (exit 2) and the queue entry its claim joined is left (one the holder
had before, such as the hub's queued lease, stays). Its traps are set before the claim, so a signal while the claim
is written still undoes what the claim took. A run killed before its
release (a SIGKILL, a container restart) leaves its lease behind under its holder's name. The next run under that
name renews the lease and owns it: it renews it while its command runs and releases it at the end. The command
gets `CLUSTER_LOCK_RUN=<cluster>/<holder>`, and a run inside it for the same cluster and holder leaves the renewal
and the release to the outer run: while that holder holds the lease live, the inner run claims nothing, so its own
ttl can neither shorten nor lengthen the outer lease. A marker with no live lease of its holder behind it, inherited
from a run that is gone, makes an ordinary run that claims and releases. A run killed with SIGKILL runs no exit trap: its renewer notices at its next turn
and stops, and the lease expires after its ttl. If only `run` itself was killed, its command runs on without the
renewal, so the lease can expire under it. Two runs at once under one holder name share one lease, and the first to
end releases it for both: give each job that may run beside another its own holder name. A renewal the lock refuses while the command runs (the lease was
released or reclaimed meanwhile) is said on stderr, and the command runs on without the lease.

## The state file

`/wd/clusters/locks/<cluster>.json` (`CLUSTER_LOCK_DIR`; it is the `clusters` spoke's lock directory, under `/wd`, so
it survives a restart). Every change is made under an flock on the sibling `<cluster>.lock` file and lands by an
atomic rename, so a reader never sees half a file and two claims at once end with one holder.

```
{
 "v": 1,
 "cluster": "demo",
 "holder": "agent",
 "session": "agent",
 "reason": "nccl busbw test",
 "claimed_at": "2026-10-15T12:00:00Z",
 "expires_at": "2026-10-15T12:30:00Z",
 "gpus": 12,
 "nodes": {"n1": 8, "n3": 4},
 "queue": [{"holder": "worker-1", "session": "agent", "reason": "second", "ttl_min": 30, "gpus": 4, "nodes": null,
            "queued_at": "2026-10-15T12:05:00Z"}],
 "displaced": [],
 "updated_at": "2026-10-15T12:05:00Z"
}
```

A free lock has `holder: null` and an empty queue. `gpus` and `nodes` are the lease's scope: `nodes: null` is the
whole cluster. A queued claim keeps the GPUs it wants but not nodes, since which nodes are free is a question for its
grant. `displaced` keeps the last 20 holders a stale reclaim displaced. A file in that directory without `"v": 1`
(an older format with `holder`, `claimed_at` and `timeout_minutes`, or one that is not JSON) is not this harness's,
and neither is a `"v": 1` file without the fields above (no `holder`, or a queue entry without its holder, ttl or
`queued_at`): it is reported, never changed, and every verb on it exits 3. The lock is per harness, and no host-wide
lock file is read or written.

## The verbs

| Command | What it does | Exit |
|---|---|---|
| `claim <cluster> --holder <name> --ttl <minutes> [--reason <text>] [--gpus <n>] [--nodes <node>=<n>,...]` | a free cluster is granted until now plus the ttl; on a held one the claim joins the queue, at the end, once; the holder's own claim renews its lease on the claim's terms, expired or not, and the lease keeps its session; with `--session` a renewal is refused unless that session is the holder or the lease's session | 0 granted or renewed, 2 queued or refused |
| `queue join <cluster> ...` / `queue list <cluster>` | the same as claim / the queue, first in line first | 0 |
| `extend <cluster> --holder <name> --ttl <minutes>` | the holder's lease expires `<minutes>` from now; a lease that already runs later keeps its expiry, since an extend never shortens a lease | 0 extended or kept, 2 another holder, 3 free |
| `release <cluster> --holder <name> [--session <name>]` | the holder's release hands the lock to the queue head, whose ttl runs from the hand-over, or frees it; a queued holder's release leaves the queue; with `--session` (the session asking) it is refused unless that session is the holder or the session that claimed the lease | 0, 2 another holder or session |
| `reclaim-stale <cluster> [--by <name>]` | a lease past its `expires_at` is reclaimed (below); a live one is refused | 0, 2 live |
| `status [<cluster>]` | one line per lock file: free, or the holder, its session, the expiry, live or EXPIRED, the scope, the reason and the queue | 0 |
| `run <cluster> --holder <name> --ttl <minutes> [--reason <text>] -- <command>` | claim, the command, release (above) | the command's, 2 held |

Every verb prints one line, except `status`, which prints one per lock file, and `queue list`, one per queue entry;
with `--json` every verb prints one JSON object instead. Exit 3 is invalid input: a cluster, holder or
session that is not a name (a letter or digit, then letters, digits, `.`, `_` or `-`, at most 64 characters, so a
path, a slash or an EKS ARN is refused), a ttl outside 1 to 1440 minutes or not in digits (`1_0`, `+5`), node counts
that do not add up to
`--gpus`, an unknown option or verb, or a lock file that is not this harness's. Exit 1 means the lock directory
cannot be written. `--session` defaults to the tmux session of the pane, else `BUS_AGENT_ID`.

## Stale reclaim

A lease is the holder's promise that it is still working: a job longer than its ttl extends it, and `run` does that
for its command. A lease past its `expires_at` is reclaimable. `reclaim-stale`, a claim by someone else, and the
`clusters` spoke's next cycle (every 15 minutes) all reclaim it the same way. The holder is recorded in `displaced`
with its expiry, the time and who reclaimed it, and the queue head gets the lock, or nobody does. Past its ttl is
not proof that a job died: the record is there so the displaced holder can be told, and the spoke tells `agent`.

## Asking the clusters spoke for a lease

`agent` asks over the bus (docs/INTER-AGENT-MESSAGING.md). The text of the request is JSON:

```
echo '{"kind": "gpu-lease", "cluster": "demo", "gpus": 12, "ttl_min": 30, "reason": "nccl busbw test"}' | /agent/bus.sh request clusters
echo '{"kind": "gpu-release", "cluster": "demo"}' | /agent/bus.sh request clusters
```

`holder` names the job the lease is for, a worker's for instance; it defaults to the sender, and two jobs under one
name share one lease, so give each job its own. The spoke's cycle answers each
request with its broker (`/agent/charters/clusters/broker.py`); the spoke's session runs the broker at once when
`agent` tells it a request is waiting. One broker run holds an flock on `/wd/clusters/broker.lock`, so the cycle's run
and the session's never answer a request twice; a run that cannot take it within `CLUSTERS_BROKER_LOCK_WAIT_SEC`
(default 60) answers nothing, names the run that holds it (its pid and start, which the holder writes into the file)
and exits 1. The reply is JSON too:

```
{"kind": "gpu-lease", "result": "granted", "cluster": "demo", "holder": "agent", "gpus": 12, "nodes": {"n1": 8, "n3": 4},
 "expires_at": "2026-10-15T12:30:00Z", "view": "the view of 2026-10-15T12:00:00Z", "line": "granted demo to agent ..."}
```

- **Scoped to nodes** when the spoke's view (its `status.json`, at most 30 minutes old) shows the GPUs free on usable
  nodes: whole nodes first, largest first, then the smallest node that fits the rest. A cordoned or NotReady node,
  or one with a NoSchedule taint (the common `nvidia.com/gpu` taint too), is never used, so a cluster whose GPU
  nodes all carry such a taint gets the whole cluster's lock. The nodes are named as Kubernetes names them (the
  name `kubectl get nodes` lists and a pod's `spec.nodeName` takes, `ip-10-0-1-2.ec2.internal` on EKS);
  STATUS.md's table shows the part before the first dot.
- **The whole cluster's lock** (`nodes: null`) when there is no view, the cluster is not one of the spoke's contexts
  (a lock is named for its context, or for an EKS context, the cluster name after `cluster/`), the context was
  unreachable, too few GPUs are free, or the view is older than 30 minutes; `view` says which.
- **Queued** when the cluster is held: `result` is `queued`, with `position`, `held_by` and `held_until`. When the
  lock reaches the queued holder, the spoke's next cycle tells `agent` with a notice.
- A reply too long for the bus (a lease over many nodes) leaves the node list in the lock file: the reply carries
  `nodes_file` in place of `nodes`, and a short `line`.
- A release replies `released` with `next_holder`, `left` for a queued holder, `free`, or `refused` when someone else
  holds the lock. A malformed request, or one whose envelope names no sender, gets a bus `error` with `result: invalid` and `why`,
  at most 300 characters of it, so the error fits the bus even when the lock tool's refusal echoes a long node list. The broker releases and renews on behalf of the request's sender: a lease (or a queue entry) is released, and
  a gpu-lease naming its holder renews it, only when the sender is its holder or the session that claimed it. So the
  hub can release and renew what it asked for, on a worker's behalf too, but not a lease a job took directly from
  another session; that renewal is `refused`, with `held_by` and `held_until`, and the lease is unchanged.

A lease is not a reservation and not a running job. It binds this harness's jobs to each other; it reserves nothing
from other people's workloads, and it never entitles a job to preempt one.

Settings of the broker: `CLUSTERS_BROKER_VIEW_MAX_AGE_SEC` (default 1800), `CLUSTERS_BROKER_CALL_TIMEOUT_SEC`, the
longest a call to the lock or the bus may take (default 120), and `CLUSTERS_BROKER_LOCK_WAIT_SEC` (default 60). A
value that is not a whole number of seconds is named and the default used; a call past its timeout is an error of the
run (exit 1), and the request stays open for the next run. A row of the view with no node name is left out of a lease
and named as an error of the run.

## What the spoke shows

`/wd/clusters/STATUS.md` has a "Cluster lock: leases and queue" table (cluster, holder, session, scope, claimed_at,
expires_at, state, queue) and one line per queue, and `status.json` the same as `locks`. A lock file that is not
this harness's is listed below the table and never stops the cycle. A lock that changed holder, went stale or was
reclaimed from an expired lease since the previous cycle is a `LOCK-HOLDER`, `LOCK-STALE` or `LOCK-RECLAIMED` line in
the cycle's changes and one line of `/wd/clusters/notices.jsonl`, which the supervisor sends to `agent` as a notice; a
reclaim's notice names the holder whose lease expired, when, and who holds the lock now. The Headlamp note counts the
leases held and queued.

## Headless fires

A headless fire of the autonomy loop with the shipped `AUTONOMY_LOOP_CLAUDE_OPTS` (`--dangerously-skip-permissions`,
docs/manual/autonomy.md "Autonomy loop") runs `/agent/cluster-lock.sh` and its cluster commands without a rule. Under the safe value
it runs Bash only through its allow rules, and a goal that touches a cluster needs `Bash(/agent/cluster-lock.sh:*)`
beside the rules for its cluster commands.

## What proves it

`Container-Root/test-cluster-lock.sh` (in the suite `./test.sh` runs; no cluster needed): claims, the queue, extend,
release and hand-over, stale reclaim, a planted race of two claims, invalid input, status, `run`, the broker's replies
from a planted view and from one cycle of the spoke's loop with a stub kubectl, the notice, and the rule in the
charter, the operating rules and this page.
