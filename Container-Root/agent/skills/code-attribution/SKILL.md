---
name: code-attribution
description: Forensic code comparison between PRs to detect attribution issues where code approaches from one PR appear in another without credit. Use when investigating whether closed PRs were reimplemented by others.
allowed-tools: Read, Grep, Glob, Bash
---

# Code Attribution Analysis Skill

Perform forensic comparison between PRs to determine if code approaches were adopted without attribution. Produces evidence chains with confidence scores.

## Usage

```
/code-attribution [repo] [source-pr] [suspect-pr]
```

- `$ARGUMENTS[0]` = repository (e.g., `ai-dynamo/nixl`)
- `$ARGUMENTS[1]` = source PR number (the original, typically closed without merge)
- `$ARGUMENTS[2]` = suspect PR number (the potentially copied PR, typically merged)

## Evidence Collection Workflow

### Step 1: Pull Both Diffs
```bash
# Source PR (original work)
gh pr diff SOURCE_PR --repo REPO > /tmp/source_pr.diff

# Suspect PR (potentially adopted)
gh pr diff SUSPECT_PR --repo REPO > /tmp/suspect_pr.diff
```

### Step 2: Extract Key Code Patterns
```bash
# Get only added lines (the actual contributions)
grep "^+" /tmp/source_pr.diff | grep -v "^+++" > /tmp/source_additions.txt
grep "^+" /tmp/suspect_pr.diff | grep -v "^+++" > /tmp/suspect_additions.txt

# Find common patterns (excluding trivial matches like braces, includes)
comm -12 <(sort /tmp/source_additions.txt) <(sort /tmp/suspect_additions.txt) | \
  grep -v "^+$" | grep -v "^+[{}]$" | grep -v "^+#include"
```

### Step 3: Timeline Analysis
```bash
# Source PR creation date
gh pr view SOURCE_PR --repo REPO --json createdAt,closedAt

# Suspect PR creation date
gh pr view SUSPECT_PR --repo REPO --json createdAt,mergedAt

# Was suspect PR created AFTER source PR was visible?
# Key: If source was open/reviewed before suspect was created = opportunity to see the code
```

### Step 4: Review Activity Cross-Reference
```bash
# Did the suspect PR author review or comment on the source PR?
gh api repos/OWNER/REPO/pulls/SOURCE_PR/reviews
gh api repos/OWNER/REPO/pulls/SOURCE_PR/comments
gh api repos/OWNER/REPO/issues/SOURCE_PR/comments
```

### Step 5: Scoring Criteria

| Evidence Type | Weight | Score Range |
|--------------|--------|-------------|
| **Code similarity** (line-by-line match %) | 30% | 0-10 |
| **Non-standard choices** (same unusual constant, same batch size, same variable name) | 25% | 0-10 |
| **Timeline** (source visible before suspect created) | 20% | 0-10 |
| **Review visibility** (suspect author saw source PR) | 15% | 0-10 |
| **Outcome** (suspect merged quickly, source closed) | 10% | 0-10 |

**Confidence Score = Weighted Average**
- 9-10: Near-certain attribution issue
- 7-8: Strong evidence, likely attribution issue
- 5-6: Moderate evidence, possible coincidence
- 3-4: Weak evidence, likely independent work
- 0-2: No evidence of attribution issue

### Step 6: Key Indicators

**Strong indicators of attribution:**
- Identical constant names that are not industry standard
- Same non-obvious numeric values (batch size 16 when 32/64 are standard)
- Same code structure with cosmetic-only differences (variable renames)
- Source PR reviewed by suspect PR author or team member
- Suspect PR created days after source PR review activity

**Weak indicators (could be coincidence):**
- Same algorithmic approach (may be obvious solution)
- Same library API calls (limited options)
- Similar comments/documentation (standard patterns)

## Output Format

```markdown
# Code Attribution Analysis
**Source PR:** #NUMBER - TITLE
**Suspect PR:** #NUMBER - TITLE
**Confidence Score:** X/10

## Timeline
- Source created: DATE
- Source last reviewed: DATE
- Suspect created: DATE
- Suspect merged: DATE

## Code Comparison
[Side-by-side diff of matching patterns]

## Non-Standard Choices
[List of unusual matching decisions]

## Review Cross-Reference
[Did suspect author see source PR?]

## Verdict
[ATTRIBUTION ISSUE / LIKELY INDEPENDENT / INSUFFICIENT EVIDENCE]
```

## Important Notes

- This skill gathers EVIDENCE, not accusations. Present findings objectively.
- Always consider that independent discovery of the same solution is common.
- Focus on non-obvious choices (constant names, batch sizes, structure) over algorithmic similarity.
- Save all evidence with timestamps for reproducibility.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
