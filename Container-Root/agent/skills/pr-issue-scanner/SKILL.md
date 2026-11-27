---
name: pr-issue-scanner
description: Live scan of GitHub PRs and issues using gh CLI to produce impact reports. Use when auditing contributions, checking PR status changes, or generating one-line impact summaries for a repository.
allowed-tools: Read, Grep, Glob, Bash
---

# PR & Issue Scanner Skill

Perform a live deep scan of all PRs and issues for a given GitHub repository and user. Produces a structured impact report showing what was merged, adopted, completed, or influenced upstream changes.

## Usage

```
/pr-issue-scanner [repo] [username]
```

- `$ARGUMENTS[0]` = repository (e.g., `ai-dynamo/nixl`)
- `$ARGUMENTS[1]` = GitHub username (optional, defaults to `@me`)

## Workflow

### Step 1: Gather All PRs
```bash
# List all PRs by author with full metadata
gh pr list --repo REPO --author USER --state all --limit 100 \
  --json number,title,state,closedAt,mergedAt,statusCheckRollup,reviews,url

# For each PR, get detailed status
gh pr view NUMBER --repo REPO \
  --json number,title,state,mergedAt,closedAt,reviews,reviewDecision,mergeable
```

### Step 2: Gather All Issues
```bash
# List all issues by author
gh issue list --repo REPO --author USER --state all --limit 100 \
  --json number,title,state,closedAt,stateReason,url
```

### Step 3: Classify Impact

For each item, determine impact category:

| Category | Criteria |
|----------|----------|
| **MERGED** | PR has `mergedAt` timestamp |
| **ADOPTED** | PR closed but code approach appears in another merged PR (check by searching for similar code patterns in other merged PRs) |
| **COMPLETED** | Issue with `stateReason: COMPLETED` |
| **INFLUENCED** | Issue closed as COMPLETED and referenced in a merged PR or commit |
| **UNDER REVIEW** | PR still OPEN with APPROVED or REVIEW_REQUIRED status |
| **NO IMPACT** | Closed without merge, no adoption evidence |

### Step 4: Check for Attribution (Adopted Code)

For closed-but-not-merged PRs, search for code adoption:
```bash
# Get the PR diff
gh pr diff NUMBER --repo REPO > /tmp/pr_NUMBER.diff

# Search recent merged PRs for similar patterns
gh pr list --repo REPO --state merged --limit 50 \
  --json number,title,mergedAt | jq -r '.[].number' | while read pr; do
    gh pr diff $pr --repo REPO 2>/dev/null | grep -c "UNIQUE_PATTERN"
done
```

### Step 5: Generate One-Line Impact Summary

Format each item as:
```
N. **#NUMBER** - TITLE [STATUS DATE] - ONE_SENTENCE_IMPACT
```

Group by category: Merged/Adopted > Critical Bugs Fixed > Features Added > Documentation > Under Review

### Step 6: Generate Statistics

```
Total Contributions: N items with measurable impact
Upstream Code Adoptions: N PRs
Critical Bugs Fixed: N issues
Features Added: N issues
Documentation: N issues
Under Review: N PRs
```

## Output Format

Save report to: `YYYY-MM-DD_IMPACT-SUMMARY.md` in current directory.

## Key Commands Reference

```bash
# Quick status of all PRs
gh pr list --repo REPO --author @me --state all --json number,title,state,mergedAt

# Check if PR was merged
gh pr view NUMBER --repo REPO --json mergedAt

# Check review status
gh pr view NUMBER --repo REPO --json reviewDecision,reviews

# Check mergeable status
gh pr view NUMBER --repo REPO --json mergeable

# Get PR diff for attribution analysis
gh pr diff NUMBER --repo REPO

# Check issue close reason
gh issue view NUMBER --repo REPO --json stateReason
```

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
