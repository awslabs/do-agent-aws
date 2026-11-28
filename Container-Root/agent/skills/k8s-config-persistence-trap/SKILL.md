---
name: k8s-config-persistence-trap
description: Use when a previously-working fix stops working after pod restart or eviction, when sed changes to files on pods are lost, when DiskPressure causes pod eviction and fixes disappear, or when debugging a regression that is actually a lost configuration.
---

# K8s Config Persistence Trap

## The Trap

Pod-level file changes via `sed`, `echo >`, or manual edits are LOST when:
- Pod is evicted (DiskPressure, OOM, preemption)
- Pod is deleted and recreated
- Node restarts
- StatefulSet is redeployed

## The Cascade

```
Session 1: sed -i 's/128/4096/' test.py → works
Session 2: Pod evicted → recreated → config=128 again → fails
Session 2: "Must be a new bug!" → 6 hours investigating phantom issues
```

## Prevention

1. **Modify source and commit** — not sed on pod
2. **Use environment variables** — survive pod restarts via ConfigMap/spec
3. **Bake into Docker image** — immutable config
4. **First check on fresh pods:** verify ALL config matches last-known-good

## Diagnostic

Before investigating ANY new failure after pod restart:
```bash
# Check if the critical config is applied
grep recv_tokens /workspace/test.py     # Should show the fixed value
grep NIXL_DEEPEP_NUM /proc/1/environ    # Should show env vars
diff <(kubectl exec pod -- cat file) local_file  # Should match
```

If config doesn't match → restore it first, test, THEN investigate if still broken.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
