---
name: directory-cross-examination
description: Use when analyzing directories before archiving, deleting, or consolidating. Use when multiple directories might contain the same project at different stages. Use when you need to verify no unique content will be lost before moving files. Use when the user says "analyze these directories" or "should we keep these?"
---

# Directory Cross-Examination

## Overview

Systematic analysis of directories to determine what's unique, what's duplicate, and what's safe to archive — without making mistakes. **Never move or delete anything until the full cross-examination is complete and the user has reviewed findings.**

## When to Use

- Before archiving, moving, or deleting any directory
- When multiple directories appear to be variants of the same project
- When the user asks "do we need these?" or "what should we do with these?"
- When directories share naming patterns (e.g., `slurm-*`, `nccl-*`, `deepep-*`)

## Core Principle

**Read everything. Compare everything. Recommend only. Act only with explicit approval.**

## The Process

### Phase 1: Inventory (collect raw facts, no judgment)

For each directory, collect ALL of:

```bash
# Size, git status, remote, branch, dirty files, .claude presence
du -sh DIR
git -C DIR remote -v | head -2
git -C DIR branch --show-current
git -C DIR log --oneline -5
git -C DIR status --short | wc -l  # dirty count
[ -d DIR/.claude ] && echo "has .claude"
```

Also check:
- Session activity from provenance DB (if available)
- GitHub repo status (pushed? unpushed commits?)
- Nested git repos inside

### Phase 2: Content Analysis (read the actual files)

- Read EVERY README.md and CLAUDE.md
- Read key config files (Dockerfile, *.yaml, *.conf)
- List unique file types and counts
- Check for test results, passing proofs, deployment artifacts

### Phase 3: Cross-Compare (the critical step)

Build a comparison matrix:

| Content Type | Dir A | Dir B | Dir C |
|-------------|-------|-------|-------|
| K8s manifests | 14 YAMLs | 15 YAMLs | 9 YAMLs |
| Tests passing | No | No | Yes (NCCL+FSDP) |
| Helm chart | Yes | No | No |
| ... | ... | ... | ... |

For each piece of unique content, ask:
1. Does this exist ANYWHERE else in the workspace?
2. Is this content superseded by a newer version elsewhere?
3. Would losing this content prevent reproducing past work?

### Phase 4: Classify

Assign each directory ONE role:
- **CANONICAL**: The production-ready, actively used version
- **REFERENCE**: Contains unique content not in canonical (e.g., Helm charts, experimental variants)
- **DUPLICATE**: Same content exists in canonical or reference
- **HISTORICAL**: Older version, all content superseded

### Phase 5: Present Findings (STOP here — do not act)

Present to user:
1. Which directory is canonical and why (with evidence)
2. What unique content exists in each non-canonical directory
3. Specific files that would be lost if archived
4. Recommended action for each directory

**CRITICAL: Do NOT move, archive, or delete anything without explicit user approval.**

## Red Flags — STOP and Ask

- Directory has dirty files → check what they are before recommending archive
- Directory has unpushed commits → push first or flag as data loss risk
- Directory has .claude dir → it was actively used by Claude sessions
- Directory has test results → may contain proof of working state
- User says "just archive it" but you haven't read the content → READ FIRST

## Common Mistakes

| Mistake | Prevention |
|---------|-----------|
| Archiving before reading content | Always read READMEs and key files |
| Missing unique content in subdirs | Check /hack, /experiments, nested repos |
| Assuming same remote = same content | Different branches may have unique work |
| Moving files without checking dirty status | Always check `git status --short` |
| Acting before user approves | Present findings, wait for explicit go-ahead |

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
