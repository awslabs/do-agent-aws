---
name: agent-supervisor-methodology
description: Use when monitoring another Claude Code agent's progress, when an agent is stuck in a debugging loop, when you need to steer an agent toward the right fix, or when coordinating multiple agents on the same problem. Covers session log analysis, advisory writing, multi-agent research dispatch, and the paste-to-terminal steering pattern.
---

# Agent Supervisor Methodology

## Overview
Systematic approach for a supervisor agent to monitor, analyze, and steer another Claude Code agent working on a complex debugging task. The supervisor reads session logs, deploys specialized research agents, and writes advisory files that the target agent reads when directed.

## The Supervision Loop

```
1. READ session JSONL tail → understand agent's current state
2. ANALYZE: is it making progress, stuck, or regressing?
3. RESEARCH: deploy specialized agents for deep analysis
4. WRITE advisory file to project directory
5. GIVE user the paste message for the agent's terminal
6. MONITOR: wait for agent to read advisory and act
7. REPEAT
```

## Session Log Analysis
```bash
# Get agent's latest activity (last 20 entries)
tail -20 <session.jsonl> | python3 -c "
import sys, json
for line in sys.stdin:
    obj = json.loads(line.strip())
    ts = obj.get('timestamp', '')[:19]
    t = obj.get('type', '')
    if t == 'assistant':
        for block in obj.get('message', {}).get('content', []):
            if block.get('type') == 'text':
                print(f'[{ts}] TEXT: {block[\"text\"][:500]}')
            elif block.get('type') == 'tool_use':
                print(f'[{ts}] TOOL: {block.get(\"name\",\"\")}')
"
```

## Advisory File Pattern
Write advisories to the agent's project directory with numbered names:
```
SUPERVISOR_ADVISORY_1.md  → First guidance
SUPERVISOR_ADVISORY_2.md  → Updated guidance
SUPERVISOR_ADVISORY_7_FINAL_FIX.md → Critical fix
NEXT_PHASE_DIRECTIVE_V4_VALIDATED.md → Multi-turn validated
```

## Multi-Agent Research Pattern
Launch 3-4 specialized agents in parallel, each investigating a different angle:
- `cuda-analyzer`: GPU kernel code analysis
- `efa-specialist`: Network/RDMA patterns
- `perf-optimizer`: Throughput analysis
- `troubleshooter`: Failure mode analysis

Wait for all to complete, then synthesize findings into one advisory.

## Steering via Paste Messages
Give the user a concise message to paste into the target agent's terminal:
```
Read SUPERVISOR_ADVISORY_N.md. [1-2 sentence summary of what to do and why].
```
Keep paste messages under 300 words. The advisory file has the details.

## Anti-Patterns to Watch For
1. **Hypothesis thrashing**: Agent applies fix, test disproves, applies next fix → 10 iterations with no progress. Intervention: "Stop runtime testing. Do source code analysis."
2. **Infrastructure addiction**: >50% time on disk/ports/zombies. Intervention: "Delete pods, recreate, increment port."
3. **Runtime diagnostic loop**: Agent adds printf, builds, deploys, waits, reads, repeats. Intervention: "Read the code locally instead."
4. **Wrong layer**: Agent debugging proxy when bug is in kernel (or vice versa). Intervention: "The bug is at [file:line], not where you're looking."

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
