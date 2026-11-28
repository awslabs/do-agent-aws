---
name: issue-closure-strategist
description: Analyze open GitHub issues/PRs and execute strategic closures with appropriate justification comments. Use when cleaning up stale issues, withdrawing superseded PRs, or closing issues that have been resolved upstream.
allowed-tools: Read, Grep, Glob, Bash
---

# Issue Closure Strategist Skill

Strategically close GitHub issues and PRs with appropriate justification, maintaining professional reputation and relationships with maintainers.

## Usage

```
/issue-closure-strategist [repo]
```

Or for a specific item:
```
/issue-closure-strategist [repo] [issue-or-pr-number]
```

## Workflow

### Step 1: Audit Open Items
```bash
# List all open issues by author
gh issue list --repo OWNER/REPO --author @me --state open \
  --json number,title,createdAt,comments,labels

# List all open PRs by author
gh pr list --repo OWNER/REPO --author @me --state open \
  --json number,title,createdAt,reviewDecision,mergeable,comments
```

### Step 2: Check Upstream Activity

For each open item, check if the issue was resolved:
```bash
# Check recent commits that might fix the issue
gh api repos/OWNER/REPO/commits?since=ISSUE_CREATED_DATE | \
  jq -r '.[].commit.message' | grep -i "KEYWORD"

# Check if similar PR was merged by someone else
gh pr list --repo OWNER/REPO --state merged --limit 50 \
  --json number,title,mergedAt | jq -r '.[] | "\(.number): \(.title)"' | grep -i "KEYWORD"

# Check maintainer comments on the issue
gh issue view NUMBER --repo OWNER/REPO --comments
```

### Step 3: Classify Disposition

| Classification | Criteria | Closure Comment Tone |
|---------------|----------|---------------------|
| **Withdraw** | Your analysis was wrong or incomplete | Acknowledge error, thank maintainers |
| **Superseded** | Another PR/issue covers the same ground | Reference the superseding item |
| **Fixed upstream** | Maintainers resolved it independently | Thank them, reference the fix commit |
| **Stale** | No activity for 30+ days, no longer relevant | Explain changed circumstances |
| **Per feedback** | Maintainer explicitly asked you to close | Acknowledge their guidance |
| **Keep open** | Still valid, still relevant, actively discussed | Do NOT close |

### Step 4: Draft Closure Comments

#### Withdraw (wrong/incomplete)
```
Closing this issue. After further analysis, [explanation of what changed].
Thank you @maintainer for the feedback on [specific point]. This helped
clarify [what you learned].
```

#### Superseded
```
Closing in favor of #NUMBER which addresses this more comprehensively.
The approach in #NUMBER [brief explanation of why it's better].
```

#### Fixed upstream
```
This has been resolved in [commit/PR reference]. Verified that the fix
addresses the original issue. Thank you for the quick resolution.
```

#### Per maintainer feedback
```
Closing per @maintainer's feedback. Understood that [key takeaway from
their feedback]. Will [what you'll do differently next time].
```

### Step 5: Execute Closures
```bash
# Close issue with comment
gh issue close NUMBER --repo OWNER/REPO \
  --comment "CLOSURE_MESSAGE"

# Close PR with comment
gh pr close NUMBER --repo OWNER/REPO \
  --comment "CLOSURE_MESSAGE"
```

### Step 6: Generate Report

```markdown
# Closure Report: REPO

**Date:** YYYY-MM-DD

## Actions Taken

| # | Type | Title | Disposition | Reason |
|---|------|-------|-------------|--------|
| <n> | Issue | <title> | Per feedback | Maintainer resolved in PR #<m> |
| <n> | PR | <title> | Superseded | Approach adopted in PR #<m> |

## Metrics
- **Before:** N open issues, M open PRs
- **After:** N open issues, M open PRs
- **Closed:** X issues, Y PRs

## Reputation Impact
- Professional closures maintain contributor standing
- Acknowledged maintainer contributions
- No bridges burned
```

## Key Principles

1. **Never close without reading maintainer comments.** Their feedback determines the tone.
2. **Acknowledge when you're wrong.** "After further review..." is stronger than defending a bad position.
3. **Reference specific items.** Link to the PR/commit that supersedes your work.
4. **Keep it brief.** Closure comments should be 2-4 sentences, not essays.
5. **Don't close items with active discussion.** If there's recent maintainer engagement, the item is alive.
6. **Batch strategically.** Don't close 10 items in 5 minutes - space them out to avoid looking like spam.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
