---
name: detect-deployment-thrashing
description: Use when an optimization campaign on Kubernetes involves infrastructure changes (pod restarts, StatefulSet recreations, image rebuilds) and the ratio of deployment operations to actual benchmark runs exceeds 2:1. Use when more than 10 minutes pass between benchmark results, or when kubectl operations dominate session activity.
---

# Detect Deployment Thrashing

## Overview

**Measure your deployment:test ratio.** If you spend more time restarting pods than running benchmarks, you are thrashing. Target: 5+ experiments per hour. Below 3/hour, stop and fix your experiment loop.

## When to Use

- More than 10 minutes between benchmark results
- Doing `kubectl delete/apply` instead of `kubectl set env`
- Rebuilding Docker images for env var changes
- Session is 80%+ kubectl commands with <20% benchmark data
- Running the same experiment multiple times due to pod crashes

## The Efficiency Ladder

| Method | Time to Change | When to Use |
|--------|---------------|-------------|
| `kubectl set env statefulset/<name> VAR=VAL` | ~60s (rolling restart) | **Env var experiments (ALWAYS use this)** |
| `kubectl patch configmap` | ~30s (if pod watches) | Config file changes |
| `kubectl exec -- sed -i` | ~5s (hot patch) | One-line code tweaks for testing |
| `kubectl delete sts && apply` | ~5 min | Schema changes to StatefulSet |
| Docker rebuild + ECR push + redeploy | ~15-30 min | Source code changes, new libraries |

## Self-Check: Am I Thrashing?

```
Count in last hour:
  Benchmark results captured: ___
  kubectl apply/delete/create: ___
  Pod restarts observed: ___

RATIO = kubectl_ops / benchmark_results

Ratio < 2:1  → Healthy
Ratio 2-5:1  → Warning — simplify your loop
Ratio > 5:1  → STOP. Fix deployment method before continuing.
```

## Common Traps

| Trap | Waste | Fix |
|------|-------|-----|
| Recreate StatefulSet for env var change | 5 min instead of 60s | Use `kubectl set env` |
| Rebuild image for env var test | 15 min instead of 60s | Env vars go in StatefulSet spec, not Dockerfile |
| Delete pod to "clean state" | Triggers CrashLoopBackOff timing issues | Let rolling update handle it |
| Wait for ProcessGroup cleanup (600s) | Wasted 10 min | Capture results in the 600s window, then let it crash |
| Re-read documentation between every experiment | 65% of session on reading | Read once, make a checklist, execute |

## Quick Protocol

```
1. Change ONE env var: kubectl -n <ns> set env sts/<name> VAR=VAL
2. Wait for rollout: kubectl rollout status sts/<name> --timeout=180s
3. Wait for benchmarks: watch for test_*.py to finish (~5-7 min)
4. Capture: grep results from /tmp/bench_ll.log
5. Record: append to CSV immediately
6. Revert: kubectl set env sts/<name> VAR=ORIGINAL
7. Repeat. Target: 5+ experiments/hour.
```

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
