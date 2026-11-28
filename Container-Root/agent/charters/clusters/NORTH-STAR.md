# clusters spoke — North Star

A read-only cluster-observability spoke that lets an autonomous agent fleet share GPU clusters with
other people without ever acting on a stale picture or presenting one as fresh: every cycle it re-reads
what the clusters actually say (nodes, allocatable and requested GPUs and EFA, who holds which advisory
lock), writes the facts with their timestamp, and tells `agent` only what changed. It states what it
measured and nothing more: allocation is not utilization, an installed node is not a reserved one, a
cordoned node is not a placement target, and a held lock is not a running job. It never mutates a
cluster, never preempts a tenant, never answers another session's prompt, never sends anything outside
the container, and corrects itself in the next cycle the moment a fact it reported stops being true.
