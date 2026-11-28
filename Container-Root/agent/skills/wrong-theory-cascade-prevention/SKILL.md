---
name: wrong-theory-cascade-prevention
description: Use when multiple debugging theories have been tried and failed in sequence, when investigation has exceeded 4 hours without resolution, when each new theory is more complex than the last, or when the symptom is intermittent and explanations keep changing.
---

# Wrong Theory Cascade Prevention

## The Pattern

Each disproven theory leads to a more complex theory. After 4+ theories, the actual cause is usually simpler than any of them.

## Warning Signs

- Theory #4+ is about hardware architecture (cache coherence, NIC firmware, memory domains)
- Each theory requires more specialized knowledge than the last
- You're consulting multiple LLMs for hardware-level explanations
- The original simple fix (that worked once) was "disproven" by a different environment

## The Checklist (Before Theory N+1)

1. **Can I reproduce the LAST KNOWN GOOD state?**
   - If not: the ENVIRONMENT changed, not the bug
   - Check: pod restart, config loss, driver version, lib path

2. **Was Theory #1 actually disproven, or did the test environment change?**
   - Re-apply Theory #1's fix on a clean environment
   - If it works: the "disproof" was a false negative

3. **What's the SIMPLEST explanation for the symptom?**
   - Flow control parameter too small?
   - Buffer not large enough?
   - Config file lost on restart?

4. **Am I investigating the transport or the application?**
   - If SIGNAL works on the same transport: transport is fine
   - The bug is in how the APPLICATION uses the transport

## The 8-Theory Cascade (Real Example)

| # | Theory | Complexity | Actual Answer |
|---|--------|-----------|---------------|
| 1 | L2 cache | Medium | Fixed (needed but not blocker) |
| 2 | NVLink IPC | Medium | Fixed (needed but not blocker) |
| 3 | AsymBuffer | High | Correct by design |
| 4 | Proxy budget | Medium | Not the issue |
| 5 | Handle collision | High | Not root cause |
| 6 | Buffer clean race | High | Disproven (sequential) |
| 7 | FI_HMEM/MR domain | Very High | WRONG (proxy DMA works) |
| 8 | **recv_tokens=128** | **Trivial** | **THE ANSWER** |

The trivial parameter (found in hour 4, lost on pod restart) was the answer all along.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
