#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# clusters spoke — ONE read-only cycle. Reads every reachable kube context, writes ${CLUSTERS_SPOKE_WD}/STATUS.md
# (plus status.json, prev.json and HEADLAMP-NOTE.md next to it) and exits. Run it every 15 minutes.
# Between the read and STATUS.md its broker (broker.py beside this file) runs once on the view just written: it answers
# the spoke's gpu-lease and gpu-release requests with leases of the harness's cluster lock and reclaims expired ones
# (docs/cluster-lock.md). A change of a lock's holder since the previous cycle is a line of notices.jsonl for the hub.
#
# Env:  CLUSTERS_SPOKE_WD    working dir (default /wd/clusters)        KUBECONFIG  (default ~/.kube/config)
#       CLUSTERS_SPOKE_CONTEXTS  space-separated contexts (default: all) CLUSTERS_SPOKE_LOCKS  the cluster lock's directory (default $WD/locks)
# Flags: --self-test   prove the refusal wrapper blocks write verbs (no cluster access needed)
#
# Refusal wrapper: kubectl and aws are shadowed by functions that allow read verbs only. Any write verb is
# refused with exit 2 and a line in $WD/refusals.log. The cycle itself never calls a write verb.
set -uo pipefail
WD="${CLUSTERS_SPOKE_WD:-/wd/clusters}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
LOCKS="${CLUSTERS_SPOKE_LOCKS:-${WD}/locks}"
BROKER="$(cd "$(dirname "$0")" && pwd)/broker.py"
REAL_KUBECTL="$(command -v kubectl || true)"; REAL_AWS="$(command -v aws || true)"
mkdir -p "${WD:?}/cache"
ctxstem() { printf '%s.%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')" "$(printf '%s' "$1" | sha1sum | cut -c1-8)"; }
refuse() { printf '%s REFUSED %s\n' "$(date -u +%FT%TZ)" "$*" >> "${WD:?}/refusals.log"; echo "REFUSED (clusters spoke is read-only): $*" >&2; return 2; }
# first positional words after global flags (flags that take a value consume the next word; --flag=value is one word)
positionals() {
  local skip=0 out=()
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
      --*=*) continue ;;
      --context|--kubeconfig|--namespace|-n|--request-timeout|-o|--output|-l|--selector|--field-selector|--region|--profile|--cluster|-s|--server|--token|--user|--as|--as-group|--endpoint-url|--query) skip=1; continue ;;
      -*) continue ;;
      *) out+=("$a"); [ "${#out[@]}" -ge 2 ] && break ;;
    esac
  done
  printf '%s\n' "${out[@]:-}"
}
kubectl() {
  local verb sub; { read -r verb; read -r sub; } < <(positionals "$@")
  case "${verb:-}" in
    get|describe|version|api-resources|api-versions|cluster-info|explain|top) "$REAL_KUBECTL" --request-timeout=20s "$@" ;;
    auth) case "${sub:-}" in can-i|whoami) "$REAL_KUBECTL" --request-timeout=20s "$@" ;; *) refuse "kubectl $*" ;; esac ;;
    config) case "${sub:-}" in get-contexts|current-context|view) "$REAL_KUBECTL" "$@" ;; *) refuse "kubectl $*" ;; esac ;;
    *) refuse "kubectl $*" ;;
  esac
}
aws() {
  local svc op; { read -r svc; read -r op; } < <(positionals "$@")
  case "${svc:-} ${op:-}" in
    "eks list-clusters"|"eks describe-cluster"|"sts get-caller-identity"|"eks list-access-entries") "$REAL_AWS" "$@" ;;
    *) refuse "aws $*" ;;
  esac
}
if [ "${1:-}" = "--self-test" ]; then
  fails=0
  for cmd in "kubectl delete pod x" "kubectl apply -f x.yaml" "kubectl cordon node1" "kubectl patch node n -p {}" "kubectl exec p -- sh" "kubectl config use-context other" "kubectl --context c -n ns delete pod x" "kubectl --kubeconfig=k --context c drain n" "aws eks update-kubeconfig --name c" "aws --region r ec2 terminate-instances" "aws --profile p eks update-kubeconfig --name c" "kubectl auth reconcile -f rbac.yaml" "kubectl --context c auth reconcile -f rbac.yaml"; do
    if $cmd >/dev/null 2>&1; then echo "FAIL not refused: $cmd"; fails=1; else echo "PASS refused: $cmd"; fi
  done
  if kubectl version --client >/dev/null 2>&1; then echo "PASS allowed read: kubectl version --client"; else echo "FAIL read verb blocked"; fails=1; fi
  if kubectl --context nonexistent-ctx -n kube-system get pods >/dev/null 2>&1 || grep -q "REFUSED kubectl --context nonexistent-ctx" "${WD:?}/refusals.log" 2>/dev/null; then echo "FAIL read verb with global flags was refused (or unexpectedly succeeded against a bogus context)"; fails=1; else echo "PASS allowed read with global flags reached kubectl (bogus context fails at kubectl, not at the wrapper)"; fi
  kubectl --context nonexistent-ctx auth can-i list nodes >/dev/null 2>&1; if grep -q "REFUSED kubectl --context nonexistent-ctx auth can-i" "${WD:?}/refusals.log" 2>/dev/null; then echo "FAIL auth can-i was refused"; fails=1; else echo "PASS auth can-i allowed (reached kubectl)"; fi
  a="$(ctxstem 'arn:aws:eks:us-east-1:ACCOUNT:cluster/demo')"; b="$(python3 -c "import re,hashlib,sys; c=sys.argv[1]; print(re.sub(r'[^A-Za-z0-9._-]','_',c)+'.'+hashlib.sha1(c.encode()).hexdigest()[:8])" 'arn:aws:eks:us-east-1:ACCOUNT:cluster/demo')"
  if [ "$a" = "$b" ] && [ "$a" = "arn_aws_eks_us-east-1_ACCOUNT_cluster_demo.$(printf '%s' 'arn:aws:eks:us-east-1:ACCOUNT:cluster/demo' | sha1sum | cut -c1-8)" ]; then echo "PASS ctxstem identical in bash and python: $a"; else echo "FAIL ctxstem mismatch: bash=$a python=$b"; fails=1; fi
  exit $fails
fi
TS="$(date -u +%FT%TZ)"; EPOCH="$(date -u +%s)"
# without kubectl there is no read, but the broker still answers (from the last view, if any) and reclaims
if [ -z "$REAL_KUBECTL" ]; then echo "kubectl not installed" >&2; [ -f "$BROKER" ] && CLUSTERS_SPOKE_WD="$WD" CLUSTERS_SPOKE_LOCKS="$LOCKS" python3 -I "$BROKER" >&2; exit 1; fi
if [ -n "${CLUSTERS_SPOKE_CONTEXTS:-}" ]; then CONTEXTS="$CLUSTERS_SPOKE_CONTEXTS"; else CONTEXTS="$(kubectl config get-contexts -o name 2>/dev/null | tr '\n' ' ')"; fi
: > "${WD:?}/cache/errors.txt"
# context -> safe cache file stem: every char outside [A-Za-z0-9._-] becomes "_", plus 8 hex of sha1(context) so two contexts never collide
# (EKS contexts made by `aws eks update-kubeconfig` are cluster ARNs containing ":" and "/"). The Python half uses the same rule.
for ctx in $CONTEXTS; do
  stem="$(ctxstem "$ctx")"
  if ! kubectl --context "$ctx" get nodes -o json > "${WD:?}/cache/nodes.${stem:?}.json" 2>>"${WD:?}/cache/errors.txt"; then echo "UNREACHABLE ${ctx}" >> "${WD:?}/cache/errors.txt"; rm -f "${WD:?}/cache/nodes.${stem:?}.json"; continue; fi
  kubectl --context "$ctx" get pods -A -o json > "${WD:?}/cache/pods.${stem:?}.json" 2>>"${WD:?}/cache/errors.txt" || echo "PODS-UNREADABLE ${ctx}" >> "${WD:?}/cache/errors.txt"
done
WD="$WD" LOCKS="$LOCKS" TS="$TS" EPOCH="$EPOCH" CONTEXTS="$CONTEXTS" BROKER="$BROKER" python3 - <<'PY'
import json, os, glob, collections, datetime, re, hashlib, subprocess, time
WD=os.environ["WD"]; LOCKS=os.environ["LOCKS"]; TS=os.environ["TS"]; EPOCH=int(os.environ["EPOCH"]); CONTEXTS=os.environ["CONTEXTS"].split(); BROKER=os.environ["BROKER"]
def ctxstem(ctx):  # must equal the bash ctxstem(): sanitized name + "." + 8 hex of sha1
    return re.sub(r"[^A-Za-z0-9._-]", "_", ctx) + "." + hashlib.sha1(ctx.encode()).hexdigest()[:8]
errors=open(f"{WD}/cache/errors.txt").read().strip().splitlines()
# the previous cycle's lock files (holder, state), for the holder changes; none on a first cycle
prev_locks=None
try:
    _s=json.load(open(f"{WD}/status.json"))
    if isinstance(_s.get("locks"),list): prev_locks={x.get("file"):x for x in _s["locks"] if isinstance(x,dict)}
except Exception: pass
def q(v):
    s=str(v or "0")
    try: return int(float(s.rstrip("m"))/1000) if s.endswith("m") else int(float(s))
    except Exception: return 0
status={"generated_utc":TS,"contexts":{}}
md=[f"# clusters spoke STATUS — {TS}", "", "Read-only snapshot. Allocation = GPUs *requested* by Running/Pending pods, not utilization. A cordoned or NotReady node is not a placement target.", ""]
for ctx in CONTEXTS:
    npath=f"{WD}/cache/nodes.{ctxstem(ctx)}.json"
    if not os.path.exists(npath):
        status["contexts"][ctx]={"reachable":False}; md+= [f"## {ctx}", "", "UNREACHABLE this cycle (see errors)", ""]; continue
    nodes=json.load(open(npath))["items"]
    try: pods=json.load(open(f"{WD}/cache/pods.{ctxstem(ctx)}.json"))["items"]
    except Exception: pods=[]
    req=collections.Counter(); req_efa=collections.Counter(); ns_gpu=collections.Counter(); pending=[]
    for p in pods:
        g=sum(q(c.get("resources",{}).get("requests",{}).get("nvidia.com/gpu")) for c in p["spec"].get("containers",[]))
        e=sum(q(c.get("resources",{}).get("requests",{}).get("vpc.amazonaws.com/efa")) for c in p["spec"].get("containers",[]))
        if not g: continue
        ph=p["status"].get("phase"); node=(p["spec"].get("nodeName") or "").split(".")[0]
        if ph in ("Running","Pending") and node: req[node]+=g; req_efa[node]+=e; ns_gpu[p["metadata"]["namespace"]]+=g
        if ph=="Pending" and not node: pending.append(f'{p["metadata"]["namespace"]}/{p["metadata"]["name"]} ({g} GPU)')
    rows=[]; tot_alloc=tot_req=0
    for n in nodes:
        L=n["metadata"]["labels"]; st=n["status"]; al=st.get("allocatable",{}); cap=st.get("capacity",{})
        gpu_al=q(al.get("nvidia.com/gpu")); gpu_cap=q(cap.get("nvidia.com/gpu"))
        if gpu_cap==0 and L.get("nvidia.com/gpu.present")!="true": continue
        name=n["metadata"]["name"].split(".")[0]
        ready=next((c["status"] for c in st["conditions"] if c["type"]=="Ready"),"Unknown")
        cordon=bool(n["spec"].get("unschedulable")); taints=[t["key"].split("/")[-1] for t in n["spec"].get("taints",[]) if t.get("effect")=="NoSchedule"]
        prov=L.get("eks.amazonaws.com/nodegroup") or (("pool:"+L["karpenter.sh/nodepool"]) if L.get("karpenter.sh/nodepool") else L.get("sagemaker.amazonaws.com/instance-group-name") or "-")
        usable = ready=="True" and not cordon and not taints
        free = max(gpu_al-req[name],0) if usable else 0
        tot_alloc+= gpu_al if usable else 0; tot_req+=req[name]
        # node: the short name the table shows; k8s_name: the node's own name, which a lease's nodes carry
        rows.append(dict(node=name,k8s_name=n["metadata"]["name"],itype=L.get("node.kubernetes.io/instance-type","?"),ready=ready,cordon=cordon,taints=taints,gpu_alloc=gpu_al,gpu_req=req[name],gpu_free=free,efa_alloc=q(al.get("vpc.amazonaws.com/efa")),efa_req=req_efa[name],prov=prov,usable=usable))
    status["contexts"][ctx]={"reachable":True,"nodes":rows,"gpu_usable_allocatable":tot_alloc,"gpu_requested":tot_req,"gpu_free":sum(r["gpu_free"] for r in rows),"top_namespaces":ns_gpu.most_common(5),"pending_gpu_pods":pending}
    md+=[f"## {ctx}", "", f"GPU: {status['contexts'][ctx]['gpu_free']} free of {tot_alloc} usable-allocatable ({tot_req} requested on all nodes). Pending GPU pods (unscheduled): {len(pending)}", "",
         "| node | type | Ready | cordon | NoSchedule taints | GPU alloc | GPU req | GPU free | EFA alloc | EFA req | provenance |", "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows: md.append(f"| {r['node']} | {r['itype']} | {r['ready']} | {'yes' if r['cordon'] else ''} | {','.join(r['taints'])} | {r['gpu_alloc']} | {r['gpu_req']} | {r['gpu_free']} | {r['efa_alloc']} | {r['efa_req']} | {r['prov']} |")
    md.append("")
    if ns_gpu: md+=["Top GPU consumers by namespace (requested): " + ", ".join(f"{ns}={g}" for ns,g in ns_gpu.most_common(5)), ""]
    if pending: md+=["Unscheduled GPU pods: " + "; ".join(pending[:8]), ""]
# the view, written before the broker: it answers this cycle's gpu-lease requests from this cycle's read; it carries
# the previous cycle's locks, so a cycle that dies after this write leaves the next one its holder comparison
mid=dict(status,locks=list(prev_locks.values())) if prev_locks is not None else status
json.dump(mid,open(f"{WD}/status.json.tmp","w"),indent=1); os.replace(f"{WD}/status.json.tmp",f"{WD}/status.json")
broker="broker: not installed"
if os.path.isfile(BROKER):
    try:
        r=subprocess.run(["python3","-I",BROKER],capture_output=True,text=True,timeout=300,env=dict(os.environ,CLUSTERS_SPOKE_WD=WD,CLUSTERS_SPOKE_LOCKS=LOCKS))
        broker=(r.stdout.strip().splitlines() or ["broker: no output"])[-1]
        errors+=[l for l in r.stderr.strip().splitlines() if l.strip()]
    except Exception as e: errors.append(f"broker: {e}")
# the cluster lock, read after the broker: this harness's lock files (/agent/cluster-lock.sh), and any other file
# found there - an older format (holder, claimed_at, timeout_minutes) or not JSON - reported, never changed
def utc(s):
    try: return datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except Exception: return None
def scope(x):
    if x.get("nodes"): return f"{x['gpus']} GPUs on " + ", ".join(f"{k}={v}" for k,v in x["nodes"].items())
    return f"{x['gpus']} GPUs on the whole cluster" if x.get("gpus") else "the whole cluster"
NOW=time.time(); locks=[]
for f in sorted(glob.glob(f"{LOCKS}/*.json")):
    fn=os.path.basename(f); c=fn[:-len(".json")]
    try: d=json.load(open(f))
    except Exception: d=None
    # a v1 file is this harness's only when it is well formed (a holder field, queue entries with holder, ttl_min and
    # queued_at); a malformed one is reported with the other files, so one bad file cannot stop the cycle
    ok=isinstance(d,dict) and d.get("v")==1 and d.get("cluster")==c and "holder" in d and isinstance(d.get("queue"),list) \
       and all(isinstance(e,dict) and isinstance(e.get("holder"),str) and isinstance(e.get("ttl_min"),int) and isinstance(e.get("queued_at"),str) for e in d["queue"])
    if ok:
        et=utc(d.get("expires_at"))
        st="free" if not d.get("holder") else ("expired" if et is None or et<=NOW else "live")
        locks.append(dict(file=fn,cluster=c,holder=d.get("holder"),session=d.get("session"),reason=d.get("reason"),claimed_at=d.get("claimed_at"),expires_at=d.get("expires_at"),
                          gpus=d.get("gpus"),nodes=d.get("nodes"),queue=d["queue"],displaced_last=(d.get("displaced") or [None])[-1],state=st,stale=st=="expired"))
        continue
    holder=claimed=tmo=None; st="unreadable"
    if isinstance(d,dict):
        holder=d.get("holder"); claimed=d.get("claimed_at"); tmo=d.get("timeout_minutes"); st="held" if holder else "free"
        t=utc(claimed)
        try:
            if holder and t is not None and tmo and EPOCH>t+int(tmo)*60: st="STALE"
        except Exception: pass
    locks.append(dict(file=fn,cluster=c,holder=holder,claimed_at=claimed,timeout_minutes=tmo,state=st,stale=st=="STALE",other=True))
status["locks"]=locks
ours=[x for x in locks if not x.get("other")]; others=[x for x in locks if x.get("other")]
md+=["## Cluster lock: leases and queue", "",
     f"This harness's cluster lock (/agent/cluster-lock.sh; docs/cluster-lock.md), read after this cycle's {broker}. A lease coordinates this harness's jobs and reserves nothing from other people's workloads; a held lock is not a running job. A lease past its expiry is reclaimed by the next cycle, its holder recorded as displaced.", ""]
if ours:
    md+=["| cluster | holder | session | scope | claimed_at | expires_at | state | queue |","|---|---|---|---|---|---|---|---|"]
    md+=[f"| {x['cluster']} | {x.get('holder') or '-'} | {x.get('session') or '-'} | {scope(x) if x.get('holder') else '-'} | {x.get('claimed_at') or '-'} | {x.get('expires_at') or '-'} | {x['state']} | {', '.join(str(e.get('holder')) for e in x['queue']) or 'empty'} |" for x in ours]+[""]
    for x in ours:
        if x["queue"]: md+=[f"Queue of {x['cluster']}: " + "; ".join(f"{i}. {e.get('holder')} (session {e.get('session') or '-'}), {scope(e)}, {e.get('ttl_min')} min, queued {e.get('queued_at')}" for i,e in enumerate(x["queue"],1)), ""]
else: md+=[f"no lease files under {LOCKS}",""]
if others: md+=["Other lock files there, not this harness's (reported, never changed): " + "; ".join(f"{x['file']}: {x['holder'] or 'no holder'}" + (f" since {x['claimed_at']}" if x.get("claimed_at") else "") + (f", timeout {x['timeout_minutes']} min" if x.get("timeout_minutes") is not None else "") + f", {x['state']}" for x in others), ""]
# a lock that changed holder, or went stale, since the previous cycle: a change line and a notice for the hub
lock_changes=[]
if prev_locks is not None:
    for x in locks:
        p=prev_locks.get(x["file"]) or {}
        was=p.get("holder") or "free"; now_h=x.get("holder") or "free"
        dl=x.get("displaced_last") or {}
        until=(f" until {x['expires_at']}" if x.get("holder") and x.get("expires_at") else "")
        if was!=now_h and isinstance(dl,dict) and dl.get("holder")==was and dl!=(p.get("displaced_last") or {}):
            # the holder's lease expired and was reclaimed: say so, the displaced holder is the one to hear it
            lock_changes.append((f"LOCK-RECLAIMED {x['cluster']} {was} -> {now_h}", f"lock {x['cluster']}: the lease of {was} expired at {dl.get('expires_at')} and was reclaimed by {dl.get('by') or '-'}; " + (f"now held by {now_h}{until}" if x.get("holder") else "free")))
        elif was!=now_h: lock_changes.append((f"LOCK-HOLDER {x['cluster']} {was} -> {now_h}", f"lock {x['cluster']}: {was} -> {now_h}{until}"))
        elif x["stale"] and not p.get("stale"): lock_changes.append((f"LOCK-STALE {x['cluster']} {now_h}", f"lock {x['cluster']}: the lease of {now_h} is past its expiry"))
    seen={x["file"] for x in locks}
    for fn,p in prev_locks.items():
        if fn not in seen and p.get("holder"): lock_changes.append((f"LOCK-HOLDER {fn[:-len('.json')]} {p['holder']} -> free", f"lock {fn[:-len('.json')]}: {p['holder']} -> free (its file is gone)"))
if lock_changes:
    with open(f"{WD}/notices.jsonl","a") as nf:
        for _,t in lock_changes: nf.write(json.dumps({"ts":TS,"kind":"notice","text":t})+"\n")
# detector line vs previous cycle
prev={}
try: prev=json.load(open(f"{WD}/prev.json"))
except Exception: pass
cur={}
for ctx,c in status["contexts"].items():
    if c.get("reachable"):
        for r in c["nodes"]: cur[f"{ctx}/{r['node']}"]=dict(alloc=r["gpu_alloc"],req=r["gpu_req"],cordon=r["cordon"],ready=r["ready"])
changes=[]
for k,v in cur.items():
    p=prev.get(k)
    if p is None: changes.append(f"NODE-ADDED {k} alloc={v['alloc']} req={v['req']}"); continue
    if p["req"]==0 and v["req"]>0: changes.append(f"NODE-TAKEN {k} req 0->{v['req']}")
    elif p["req"]>0 and v["req"]==0: changes.append(f"NODE-FREED {k} req {p['req']}->0")
    elif p["req"]!=v["req"]: changes.append(f"GPU-REQ-CHANGED {k} {p['req']}->{v['req']}")
    if not p["cordon"] and v["cordon"]: changes.append(f"NODE-CORDONED {k}")
    if p["cordon"] and not v["cordon"]: changes.append(f"NODE-UNCORDONED {k}")
    if p["ready"]=="True" and v["ready"]!="True": changes.append(f"NODE-NOTREADY {k}")
for k in prev:
    if k not in cur and k.split("/")[0] in [c for c,v in status["contexts"].items() if v.get("reachable")]: changes.append(f"NODE-REMOVED {k}")
changes+=[c for c,_ in lock_changes]
status["changes_since_previous_cycle"]=changes; status["errors"]=errors
md+=["## Changes since the previous cycle", ""]+([f"- {c}" for c in changes] or ["- none"])+[""]
if errors: md+=["## Errors this cycle",""]+[f"- {e}" for e in errors]+[""]
md+=["---","Written by loop.sh (read-only; kubectl verbs used: config get-contexts, get). Writes: STATUS.md, status.json, prev.json, HEADLAMP-NOTE.md and notices.jsonl in this directory; its broker changes the lock files in locks/ only through /agent/cluster-lock.sh.",""]
tmp=f"{WD}/STATUS.md.tmp"; open(tmp,"w").write("\n".join(md)); os.replace(tmp,f"{WD}/STATUS.md")
json.dump(status,open(f"{WD}/status.json.tmp","w"),indent=1); os.replace(f"{WD}/status.json.tmp",f"{WD}/status.json")
json.dump(cur,open(f"{WD}/prev.json.tmp","w")); os.replace(f"{WD}/prev.json.tmp",f"{WD}/prev.json")
reach=[c for c,v in status["contexts"].items() if v.get("reachable")]
summary=f"clusters spoke {TS}: " + "; ".join(f"{c}: {status['contexts'][c]['gpu_free']}/{status['contexts'][c]['gpu_usable_allocatable']} GPU free" for c in reach) + (f"; unreachable: {', '.join(c for c in status['contexts'] if not status['contexts'][c].get('reachable'))}" if len(reach)<len(status['contexts']) else "") + (f"; leases: {sum(1 for x in ours if x['holder'])} held, {sum(len(x['queue']) for x in ours)} queued" if ours else "") + f"; changes: {len(changes)}"
open(f"{WD}/HEADLAMP-NOTE.md.tmp","w").write(summary+"\n"); os.replace(f"{WD}/HEADLAMP-NOTE.md.tmp",f"{WD}/HEADLAMP-NOTE.md")
print(summary)
PY
rc=$?
rm -f "${WD:?}/STATUS.md.tmp" "${WD:?}/status.json.tmp" "${WD:?}/prev.json.tmp" "${WD:?}/HEADLAMP-NOTE.md.tmp"
exit $rc
