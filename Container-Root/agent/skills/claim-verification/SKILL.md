---
name: claim-verification
description: Verify technical claims against upstream source code with exact file paths, line numbers, and commit hashes. Use when auditing issues, PRs, or documentation for accuracy before submission.
allowed-tools: Read, Grep, Glob, Bash
---

# Claim Verification Skill

Systematically verify every technical claim in a document against actual source code. Produces a verification report with CONFIRMED/WEAK/NOT FOUND/CONTRADICTED ratings.

## Usage

```
/claim-verification [document-path] [repo-path-or-url]
```

## Workflow

### Step 1: Extract Claims

Read the document and extract every verifiable claim:
- File paths referenced
- Line numbers cited
- Code snippets quoted
- Error messages described
- Configuration values stated
- Version numbers mentioned

### Step 2: Verify Each Claim

For each claim:

```bash
# 1. Check file exists
ls REPO_PATH/claimed/file/path.cpp

# 2. Check line content matches
sed -n 'LINE_NUMp' REPO_PATH/claimed/file/path.cpp

# 3. Check code snippet exists
grep -n "claimed code snippet" REPO_PATH/claimed/file/path.cpp

# 4. Verify against specific commit
cd REPO_PATH && git show COMMIT_HASH:claimed/file/path.cpp | sed -n 'LINE_NUMp'
```

### Step 3: Score Each Claim

| Rating | Criteria |
|--------|----------|
| **CONFIRMED** | Code/content matches exactly at stated location |
| **WEAK** | Content exists but at different location, or partially matches |
| **NOT FOUND** | Cannot locate the claimed content anywhere |
| **CONTRADICTED** | Found content that directly contradicts the claim |
| **OUTDATED** | Was true at a previous commit but not current |

### Step 4: Generate Report

```markdown
# Verification Report

**Document:** [path]
**Verified Against:** [repo] @ [commit hash]
**Date:** YYYY-MM-DD

## Summary
- Total claims: N
- CONFIRMED: N (X%)
- WEAK: N (X%)
- NOT FOUND: N (X%)
- CONTRADICTED: N (X%)

## Claim Details

### Claim 1: [description]
- **Source:** Document line N
- **States:** "code snippet or assertion"
- **Actual:** "what the code actually shows"
- **Location:** file.cpp:123
- **Rating:** CONFIRMED / WEAK / NOT FOUND / CONTRADICTED
- **Evidence:** [exact command and output]

### Claim 2: ...
```

## Verification Commands

```bash
# File existence
test -f PATH && echo "EXISTS" || echo "NOT FOUND"

# Line content
sed -n 'Np' PATH

# Code search
grep -rn "PATTERN" REPO --include="*.cpp" --include="*.h"

# Commit-specific verification
git show HASH:PATH | head -N

# Function existence
grep -n "function_name" PATH

# Constant/define verification
grep -rn "#define CONSTANT" REPO --include="*.h" --include="*.hpp"
```

## Key Principles

1. **Exact matches only for CONFIRMED.** Paraphrased code that captures the intent but doesn't match verbatim gets WEAK.
2. **Check the right commit.** Code changes between versions. Always note which commit you verified against.
3. **Save all evidence.** Every verification should include the command run and its output.
4. **Check for moves.** If a claim says file.cpp:100 but the code is at file.cpp:115, it may have shifted due to other changes. Rate as WEAK with note.
5. **Verify error messages against actual error handling code.** Don't assume error messages are correct just because they look plausible.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
