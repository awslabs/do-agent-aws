---
name: benchmark-comparison
description: Compare benchmark results before/after optimizations, generate reports, and track progress toward latency gap closure
allowed-tools: Read, Grep, Glob, Bash
---

# Benchmark Comparison Skill

## Purpose
Compare benchmark results before/after optimizations,
generate reports, and track progress toward performance goals.

## When to Use
- After running optimization benchmarks
- Comparing multiple optimization approaches
- Tracking progress toward latency gap closure
- Generating optimization reports

## Input Format

Expects benchmark results in JSON:
```json
{
  "optimization": "OPT_001_message_batching",
  "timestamp": "2025-01-28T12:00:00Z",
  "config": {
    "num_tokens": 128,
    "hidden_dim": 7168,
    "num_experts": 256,
    "dtype": "bfloat16"
  },
  "results": {
    "latency_us": 450.0,
    "throughput_tokens_per_sec": 284444,
    "bandwidth_gbps": 145.6,
    "cpu_util_percent": 15.2
  },
  "baseline_comparison": {
    "baseline_latency_us": 650.0,
    "improvement_percent": 30.8
  }
}
```

## Analysis Framework

### Gap Analysis
```
Target: Close 30% latency gap with InfiniBand
InfiniBand baseline: ~450us (DeepEP IBGDA)
Current EFA: ~650us (NVSHMEM libfabric)
Gap: 200us (30.8%)

After OPT_001: ~520us
Remaining gap: 70us (15.5%)
Progress: 65% of gap closed
```

### Improvement Tracking
| Optimization | Predicted | Actual | Delta |
|-------------|-----------|--------|-------|
| OPT_001 | -40% | -30% | -10% |
| OPT_002 | -20% | -18% | -2% |
| Cumulative | -52% | -43% | -9% |

### Statistical Analysis
- Mean latency across runs
- Standard deviation
- P95/P99 latency
- Confidence intervals

## Output Format
```markdown
## Benchmark Comparison Report

### Summary
- **Optimization**: [name]
- **Date**: [timestamp]
- **Status**: [PASS/FAIL] (target: [X]% improvement)

### Results
| Metric | Baseline | Optimized | Change |
|--------|----------|-----------|--------|
| Latency | X us | Y us | -Z% |
| Throughput | X tok/s | Y tok/s | +Z% |
| Bandwidth | X Gbps | Y Gbps | +Z% |

### Gap Closure Progress
```
InfiniBand ████████████████████ 450us
Target     ████████████████████████ 585us (30% gap)
Before     ████████████████████████████████ 650us
After      ██████████████████████████ 520us
           ├─────── Closed: 130us (65%) ───────┤
```

### Recommendation
[Continue with next optimization / Investigate regression / ...]
```

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
