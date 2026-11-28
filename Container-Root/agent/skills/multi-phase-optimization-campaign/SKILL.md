---
name: multi-phase-optimization-campaign
description: "Use when planning or running a phased performance optimization campaign that requires cumulative metrics tracking, gap analysis against a reference baseline, cross-layer synergy mapping, and decision gates that can short-circuit later phases. Distinct from phase-tracker (generic project phases) because this handles optimization-specific concerns: gap closure percentages, synergy matrices, config-before-code ordering, and rollback flags per technique."
---

# Multi-Phase Optimization Campaign

Phased optimization rollouts: config-only first, decision gates to prevent wasted effort.

## Campaign Initialization

Create `campaign/STATUS.md`:

```markdown
## Target
| Metric    | Value            |
|-----------|------------------|
| Reference | {ref} {unit}     |
| Starting  | {start} {unit}   |
| Gap       | {gap} ({pct}%)   |
| Target    | <{tgt} {unit}    |
| Success   | >=75% gap closure |

## Progress
| Phase | Optimization | Status | Measured | Improvement | Cumulative |
|-------|-------------|--------|----------|-------------|------------|
| 0     | Baseline    | ...    | ...      | -           | 0%         |
| 0.5   | Config-only | ...    | ...      | ...         | ...        |
```

**Rule**: Phase 0.5 (config/env, zero code) is mandatory: configuration alone can close more than the whole gap to the reference.

## Phase Structure

Each phase requires: **prerequisites** (prior phase measured), **technique**, **rollback flag**, **decision gate**.

### Decision Gates

```
IF cumulative >= target:  STOP, document victory.
IF phase delta < 2%:      SKIP (diminishing returns).
IF correctness regresses: ROLLBACK, investigate.
```

## Cumulative Metrics

Track gap closure from the original start, not the previous phase:

```
Gap closure % = (starting - current) / (starting - reference) * 100
```

Example (650us start, 450us ref, 200us gap):

| Phase | Result | Delta | Gap Closed |
|-------|--------|-------|------------|
| 0.5   | 400us  | -38%  | 125%       |
| 1     | 250us  | -37%  | 200%       |
| 4     | 210us  | -5%   | 220%       |

Over 100% means you beat the reference system.

## Cross-Layer Synergy Tracking

Document in `OPTIMIZATION_ROADMAP.md`. Co-deploy synergistic techniques:

```
L1 coalescing + L3 doorbell batching:
  Separate: 1000->16 ops + 1000->32 doorbells
  Combined: 16 ops -> 1 doorbell = 1000x total
```

## Rollback Strategy

Every technique gets a kill switch:

| Type    | Mechanism             | Example                        |
|---------|-----------------------|--------------------------------|
| Config  | Env var removal       | `unset FI_EFA_USE_DEVICE_RDMA` |
| Wrapper | Drop LD_PRELOAD entry | Remove `adaptive_proxy.so`     |
| Patch   | Compile-time guard    | `#ifndef USE_PUT_SIGNAL`       |

Maintain `rollback_all_optimizations.sh` for single-command revert.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Skip Phase 0.5 | Always measure config-only first |
| Delta from previous phase, not baseline | Track cumulative gap closure from start |
| Synergistic techniques in separate phases | Co-deploy pairs that multiply |
| No rollback flag | Every technique needs a kill switch |
| Estimated metrics treated as measured | Mark estimates, re-order after real data |

## File Layout

```
campaign/STATUS.md                       # Cumulative table
analysis/call_chain/OPTIMIZATION_ROADMAP.md  # Synergies, priority
analysis/call_chain/L{N}_{name}/techniques/  # Versioned techniques
optimizations/deploy_all_optimizations.sh
optimizations/rollback_all_optimizations.sh
env/PHASE0_*.env                         # Config-only variables
```

Update `STATUS.md` after every measurement. Never overwrite rows; append with timestamps.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
