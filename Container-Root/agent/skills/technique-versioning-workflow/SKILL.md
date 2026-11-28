---
name: technique-versioning-workflow
description: Use when iterating on performance optimization techniques within a layer and you need to version, compare, and evolve approaches based on measurement results. Covers naming, file templates, version transitions, and index updates.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Technique Versioning Workflow

Systematic versioning for optimization techniques within a layered analysis framework. Each technique evolves through measured iterations (v1, v2, v3...) where each version addresses gaps the previous version's results revealed.

## Naming Convention

```
T{N}_{descriptive_name}_v{version}.md
```

`N`: technique number (sequential within layer). `descriptive_name`: snake-case. `version`: integer from 1.

Examples: `T1_coalescing_v1.md`, `T1_coalescing_v2.md`, `T2_doorbell_batching_v1.md`

## When to Create a New Version

Create v(N+1) when:

1. **Measurement shows issues** -- profiling revealed gaps (e.g., missing receiver unpacking)
2. **Integration conflicts** -- technique breaks assumptions in another layer
3. **Performance target not met** -- improvement exists but falls short of phase goal
4. **New API discovered** -- enables a fundamentally better approach (e.g., put-signal eliminated all fences in v3)

Never overwrite the previous version. The old file is the evidence trail.

## Technique File Template (6 Required Sections)

```markdown
# T{N} {Name} v{V}

**Status**: DRAFT | CODE READY | VALIDATED
**Date**: YYYY-MM-DD
**Layer**: L{X}
**Supersedes**: v{V-1} (if applicable)

## 1. Problem Statement
What bottleneck this addresses. Reference baseline measurements.

## 2. Implementation
Before/after code. Include compile guards:
  #ifdef USE_TECHNIQUE_NAME
      optimized_path();
  #else
      baseline_path();
  #endif

## 3. Performance Analysis
| Metric  | Baseline | This Version | Previous Version |
|---------|----------|--------------|------------------|
| Latency |          |              |                  |
| Calls   |          |              |                  |

## 4. Trade-offs
Pros, cons, memory cost, compatibility constraints.

## 5. Validation Plan
Correctness check, benchmark config, success criteria.

## 6. Next Iteration
What v(N+1) would address. Leave blank if final.
```

## Version Transition Protocol

1. Read previous version's Performance Analysis and Next Iteration sections
2. Create `T{N}_{name}_v{V+1}.md` in the same `techniques/` directory
3. Add `Supersedes: v{V}` in the header
4. In section 1, reference specific prior measurements that motivated the change
5. In section 3, include a column comparing against the previous version
6. Update MASTER_INDEX.md

## Cross-Layer References

When a technique interacts with other layers, add after Trade-offs:

```markdown
### Cross-Layer Dependencies
- **Enables**: L5 T1_fi_more_batching (fewer ops to batch)
- **Requires**: L3 T2_doorbell_coalescing (for full benefit)
- **Conflicts**: None
```

## MASTER_INDEX.md Update Protocol

After creating or updating any technique file:

1. Update the directory tree to include the new file
2. Update the completion table (count and percentage)
3. Mark the latest version with "NEW" or "CURRENT"
4. Update "Next Actions" if priorities changed

## Common Mistakes

- **Overwriting v1**: Destroys the evidence trail. Always create a new file.
- **Skipping baseline**: Every v1 must reference baseline/ANALYSIS.md numbers.
- **Not linking related techniques**: If L1 coalescing affects L3 doorbell count, both files must cross-reference.
- **Mixing layer concerns**: One technique file per layer. Span layers with linked files.
- **Forgetting compile guards**: Every technique must be toggleable for rollback.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
