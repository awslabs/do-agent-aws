---
name: k8s-configmap-runtime-patch
description: Use when injecting Python patches or config files into containers at runtime without rebuilding images, when base64 encoding makes YAMLs unreadable, or when private repos block curl-based downloads
---

# K8s ConfigMap Runtime Patching

## Overview
Mount Python patch scripts as ConfigMaps into containers at runtime. Avoids base64-encoded blobs in YAMLs, doesn't depend on GitHub access (works with private repos), and patches are version-controlled separately.

## When to Use
- Container image has a bug you can't rebuild for
- YAML has unreadable base64-encoded patches
- Private repo blocks `curl` from downloading patches
- Need to iterate patches without rebuilding images
- Multiple manifests need the same patches

## Pattern

### 1. Create patch files in repo
```
patches/
  patch_worker_v5.py    # Standalone Python scripts
  patch_grpo_v9.py      # Each is self-contained, idempotent
```

### 2. Create ConfigMap from files
```bash
kubectl create configmap nemo-rl-patches \
  --from-file=patch_worker_v5.py=patches/patch_worker_v5.py \
  --from-file=patch_grpo_v9.py=patches/patch_grpo_v9.py \
  --dry-run=client -o yaml > deploy/kubernetes/patches-configmap.yaml

kubectl apply -f deploy/kubernetes/patches-configmap.yaml
```

### 3. Mount in pod spec
```yaml
volumes:
  - name: patches
    configMap:
      name: nemo-rl-patches
# ...
containers:
  - volumeMounts:
      - name: patches
        mountPath: /opt/patches
        readOnly: true
```

### 4. Run patches at startup
```yaml
command: ["/bin/bash", "-c"]
args:
  - |
    python3 /opt/patches/patch_worker_v5.py
    python3 /opt/patches/patch_grpo_v9.py
    # ... rest of startup
```

## Patch Script Best Practices

```python
#!/usr/bin/env python3
"""Each patch must be idempotent."""

f = '/path/to/target.py'
c = open(f).read()

if 'PATCH_MARKER_V1' in c:
    print('Already patched')
    exit(0)

# Apply patch...
open(f, 'w').write(modified)
print('PATCH_MARKER_V1: Applied')
```

Key rules:
- **Idempotent**: Check for marker before patching
- **Versioned markers**: `PATCH_V1`, `PATCH_V2` etc.
- **Print confirmation**: Log what was patched
- **Clean .pyc after**: `find /path -name '*.pyc' -delete`

## Comparison of Approaches

| Approach | Readability | Private Repo | Iteration Speed |
|----------|------------|-------------|-----------------|
| Base64 in YAML | Poor | Works | Must re-encode |
| curl from GitHub | Good | Fails | Push + redeploy |
| **ConfigMap mount** | Good | Works | `kubectl apply` |
| Rebuild image | N/A | Works | Slow (minutes) |

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
