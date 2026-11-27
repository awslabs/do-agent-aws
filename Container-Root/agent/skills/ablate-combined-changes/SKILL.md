---
name: ablate-combined-changes
description: Use when a multi-variable change produces a large improvement and you need to isolate which variables contributed, which are harmful, and whether gains stack. Use when celebrating a big win from simultaneous changes, when building on a combined config without understanding individual contributions, or when two good optimizations give worse-than-expected combined result.
---

# Ablate Combined Changes

## Overview

**Never build on a multi-variable win without ablation.** When multiple changes produce a big improvement, some variables may be harmful (dragging the result down), some may be required (crash without them), and beneficial ones may NOT stack when combined due to overlapping bottlenecks.

## When to Use

- After any experiment that changed 2+ variables simultaneously
- Before building further optimizations on a combined config
- When two individually good changes give a worse-than-expected combined result
- When a "required" variable might actually be hurting performance

## Core Pattern

```
1. RECORD combined result as reference
2. FOR EACH variable changed:
   a. Revert ONLY that variable to its pre-change value
   b. Benchmark (using stable measurement protocol)
   c. Record: did removing it help, hurt, or crash?
   d. Restore variable, move to next
3. CLASSIFY each variable:
   - REQUIRED:    Crashes without it (do not remove)
   - BENEFICIAL:  Removing it hurts performance (keep)
   - HARMFUL:     Removing it IMPROVES performance (remove from config!)
   - NEUTRAL:     No measurable effect (remove for simplicity)
4. TEST STACKING: Combine the top 2 beneficial changes. Compare against each alone.
   If combined < sum of individual gains → overlapping bottlenecks
```

## The Non-Additive Trap

Two optimizations that independently improve the same metric can **interfere** when combined:

```
Optimization A alone: -8.9% dispatch  (targets NIC coordination overhead)
Optimization B alone: -17.7% dispatch (targets memory registration overhead)
Expected combined:    -26.6%
Actual combined:      -8.4%  ← WORSE than B alone!
```

**Root cause:** Both optimizations targeted overlapping bottlenecks in the memory registration path. Removing NIC coordination (A) also removed the workload that B was optimizing.

**Detection:** If `combined_improvement < max(individual_improvements)`, the changes are anti-synergistic. Use the better individual change, not the combination.

## Quick Reference

| Variable Classification | What Happened When Removed | Action |
|------------------------|---------------------------|--------|
| **REQUIRED** | System crashed | Keep, mark as non-negotiable |
| **BENEFICIAL** | Performance degraded | Keep in optimal config |
| **HARMFUL** | Performance IMPROVED | Remove immediately |
| **NEUTRAL** | No change (within noise) | Remove for simplicity |

## Common Mistakes

| Mistake | Consequence | Fix |
|---------|-------------|-----|
| Celebrating multi-var win without ablation | Building on suboptimal config | Always ablate before proceeding |
| Assuming "safety" variables are free | Hidden 17% penalty from VMM disable | Test every variable |
| Stacking two good changes without testing | Non-additive interference undetected | Always test the combination explicitly |
| Changing variables during ablation | Confounded results | Reset to baseline between EACH test |

## Real-World Impact

A 7-variable combined change produced 22% improvement. Ablation revealed one "safety" variable (`DISABLE_CUDA_VMM=1`) was actively harmful (-17.7%). Removing it alone beat the combined config. Two beneficial changes (VMM + single-rail) did NOT stack — the combination was worse than VMM alone. The optimal config had fewer variables than the original "winning" config.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
