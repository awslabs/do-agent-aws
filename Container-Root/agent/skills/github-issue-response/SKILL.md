---
name: github-issue-response
description: "Use when responding to GitHub issues with technical recommendations, creating verified test configurations, or building evidence-based responses with before/after documentation for infrastructure or networking issues"
---

# GitHub Issue Response Workflow

Structured workflow for crafting evidence-based GitHub issue responses with verified configurations and reproducible test environments. Derived from 41 GitHub workflow instances covering EFA/NCCL configuration, cluster networking, and infrastructure debugging.

## When to Use

- Responding to GitHub issues that report bugs, misconfigurations, or performance problems
- Creating technical recommendation documents for customer-specific environments
- Building before/after evidence for infrastructure or networking changes
- Generating verified YAML configs, Helm values, or environment variable sets
- Cross-referencing related issues, PRs, and upstream documentation
- Producing comprehensive technical recommendations (40+ pages when warranted)

## Workflow Phases

### Phase 1 - Investigation

1. Read the full issue thread including all comments (`gh issue view <number> --comments`)
2. Identify every factual claim and configuration detail the reporter provides
3. Search the codebase for evidence supporting or contradicting each claim
4. Check related issues and PRs (`gh issue list --search "<keywords>"`, `gh pr list --search "<keywords>"`)
5. Record each finding with file path + line number or commit hash

```
Evidence: <claim> -> <file>:<line> OR <log snippet> OR <test output>
Status: CONFIRMED | CONTRADICTED | UNVERIFIED
```

### Phase 2 - Reproduction

1. Create a minimal test environment that mirrors the reporter's setup
2. Extract cluster specs: instance types, node counts, networking (EFA, VPC CNI, etc.)
3. Reproduce the exact failure using their configuration
4. Capture baseline metrics and error output before any changes
5. Document the reproduction steps so they are fully repeatable

```bash
# Example: capture baseline state
kubectl get pods -n <namespace> -o yaml > baseline-pods.yaml
kubectl logs <pod> > baseline-logs.txt
```

### Phase 3 - Root Cause Analysis

1. Trace from symptoms to actual cause -- do not stop at the first error message
2. Walk the code path: entrypoint -> configuration loading -> runtime behavior
3. Check for version-specific behavior, dependency conflicts, or environment drift
4. Distinguish between root cause and contributing factors
5. Document the causal chain with evidence at each step

```
Symptom: <what the user sees>
Contributing factor: <what makes it worse>
Root cause: <the actual defect or misconfiguration> -> <file>:<line>
```

### Phase 4 - Recommendation

1. Generate the fix: YAML configs, commands, environment variables, or code changes
2. Verify every configuration artifact actually works in a test environment before recommending
3. Adapt to customer-specific details: instance types, cluster size, network topology
4. Provide both the minimal fix and the hardened/production-ready version
5. Include rollback steps

```yaml
# VERIFIED: tested against <environment description>
# Change: <what this modifies and why>
apiVersion: v1
kind: ConfigMap
metadata:
  name: example
data:
  KEY: "value"  # Ref: <file>:<line> or <documentation URL>
```

### Phase 5 - Documentation

1. Write a before/after comparison showing the exact change and its impact
2. Include metrics or log diffs where available
3. Add customer-specific context (their cluster specs, instance types, networking)
4. Link all related issues, PRs, and documentation
5. Structure for both quick-scan readers and deep-dive reviewers

## Evidence Standards

Every claim in the response MUST have at least one of:

| Evidence Type | Format | Example |
|---|---|---|
| Source code | `file:line` | `pkg/config/loader.go:142` |
| Log output | Verbatim snippet | `level=error msg="timeout after 30s"` |
| Test result | Command + output | `kubectl get pods` showing CrashLoopBackOff |
| Documentation | URL | Link to upstream docs or RFCs |
| Commit | Hash + message | `a1b2c3d fix: increase default timeout` |

If evidence cannot be obtained, mark the claim as **UNVERIFIED** and state what would be needed to verify it.

## Response Template

```markdown
## Problem Statement
<1-2 sentences summarizing the issue from the reporter's perspective>

## Investigation Findings
- **Claim**: <reporter's claim> -> **Evidence**: <file:line or log>
- ...

## Root Cause
<Causal chain from root cause to observed symptom, with evidence at each link>

## Recommended Fix

### Minimal Fix
<Smallest change that resolves the issue>

### Production-Ready Configuration
<Hardened version with best practices>

### Rollback Steps
<How to revert if the fix causes problems>

## Verification Steps
1. Apply the fix: `<command>`
2. Confirm resolution: `<command + expected output>`
3. Validate no regression: `<command + expected output>`

## Related
- Issue #<number>: <title>
- PR #<number>: <title>
- Docs: <URL>
```

## Common Patterns

### EFA / NCCL Configuration (Lila Sciences, NIXL)

- Missing or incorrect `FI_PROVIDER`, `FI_EFA_USE_DEVICE_RDMA`, `NCCL_ALGO` env vars
- EFA device plugin not matching requested `vpc.amazonaws.com/efa` resource counts
- NCCL topology file mismatch with actual instance placement
- Hugepages not allocated or insufficient for RDMA buffers
- Security group rules missing for EFA traffic (all-to-all within placement group)

### Kubernetes Networking

- CNI plugin version incompatible with kernel or EKS version
- Pod CIDR exhaustion causing scheduling failures
- MTU mismatch between node and pod networks
- DNS resolution delays from `ndots:5` default in resolv.conf

### Helm / Config Drift

- Values file overridden by chart defaults on upgrade
- CRD not updated because `helm upgrade` skips CRD changes
- Secret or ConfigMap not triggering pod restart after update

## Anti-Patterns

1. **Recommending without reproducing** -- never suggest a fix you have not tested
2. **Treating symptoms as root cause** -- always trace the full causal chain
3. **Generic advice** -- adapt every recommendation to the reporter's actual environment
4. **Missing rollback plan** -- every change must be reversible
5. **Unlinked claims** -- every statement needs evidence; mark gaps as UNVERIFIED
6. **Copy-paste configs** -- verify YAML parses, values are valid, and references exist
7. **Ignoring version context** -- check whether the fix applies to the reporter's versions
8. **Skipping cross-references** -- always search for duplicate or related issues first

## Tools Integration

```bash
# Issue management
gh issue view <number> --comments
gh issue comment <number> --body "<response>"
gh issue list --search "<keywords>" --limit 20

# Config verification
kubectl apply --dry-run=client -f <config>.yaml
kubectl diff -f <config>.yaml
helm template <chart> -f <values>.yaml | kubectl apply --dry-run=client -f -

# Evidence capture
kubectl get events --sort-by='.lastTimestamp' -n <namespace>
kubectl describe pod <pod> -n <namespace>
kubectl logs <pod> -n <namespace> --previous
```

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
