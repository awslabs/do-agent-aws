---
name: wrong-layer-debugging
description: Use when debugging a multi-layer system where one code path works but another fails using shared infrastructure, when 3+ theories about shared code have been disproved, or when the working and broken paths differ only in execution order or data flow direction
---

# Wrong Layer Debugging

## Core Principle
When path A works but path B fails using identical shared infrastructure, the bug is in what's DIFFERENT between A and B — not the shared code.

## When to Use
- Function A works, function B fails, both use same RDMA/networking/IPC path
- You've verified 3+ theories about shared infrastructure (all correct)
- Hours spent debugging shared code that dispatch/combine/send/recv all use

## The Pattern

```
STOP. Ask: "What is DIFFERENT between the working and broken case?"

NOT: "What's wrong with the shared infrastructure?"
```

## Diagnostic Checklist
1. List everything SHARED (same proxy, same NIC, same MR, same QP)
2. List everything DIFFERENT (execution order, buffer regions, kernel roles, flow direction)
3. Add diagnostic printf to the FIRST difference, not the shared path
4. The bug is almost always in the difference list

## Don't Simplify by Disabling Distribution
When debugging a multi-path system, resist disabling parallelism (sharding, multi-NIC, multi-channel) to "simplify." Disabling changes the execution topology and may REMOVE the bug-producing condition. Re-enabling sharding improved combine from 248ms to 2.3ms — the parallelism wasn't the bug.

## Real-World Example
- 8 hours debugging RDMA proxy, NIC workers, ibv_wr_rdma_write, MR coverage — all CORRECT
- Actual bug: NVLink intra-node tail counter not updated (only affects combine, not dispatch)
- The SHARED RDMA path was never broken. The DIFFERENT NVLink path was.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
