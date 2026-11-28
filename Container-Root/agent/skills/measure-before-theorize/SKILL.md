---
name: measure-before-theorize
description: Use when about to optimize a suspected performance bottleneck, when a timeout or polling loop is assumed to be slow, or when planning a code change based on timing assumptions without measurement data
---

# Measure Before Theorize

## Core Principle
Never optimize a suspected bottleneck without first measuring whether it actually fires. A function with a 100ms timeout that never triggers costs 0ms, not 100ms.

## The Anti-Pattern
1. See code with large timeout (100ms sentinel poll)
2. Assume: "256 tokens × 100ms = 25.6s — that's our 30s!"
3. Reduce timeout to 1ms
4. Result: ZERO effect (timeout was never hitting)
5. Wasted: 1 hour implementing + deploying + testing

## The Pattern
1. Add counter/diagnostic: "How many times does this timeout fire?"
2. Run benchmark
3. If count > 0: optimize the timeout
4. If count == 0: the bottleneck is elsewhere

## Quick Diagnostic
```cuda
// BEFORE optimizing: measure if it fires
static __device__ int timeout_count = 0;
if (timed_out) {
    atomicAdd(&timeout_count, 1);
    printf("TIMEOUT #%d at line %d\n", timeout_count, __LINE__);
}
```

## Real-World Impact
- Sentinel timeout reduction (100ms→1ms): ZERO effect on 30s dispatch
- The 30s was from CPU proxy round-trip (200ms × 128 batches), not sentinel polling
- Measurement would have revealed this in 5 minutes instead of 1 hour

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
