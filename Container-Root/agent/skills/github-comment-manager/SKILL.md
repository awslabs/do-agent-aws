---
name: github-comment-manager
description: Audit, delete, and consolidate scattered GitHub issue/PR comments into clean single-thread summaries. Use when comments have accumulated across issues/PRs and need cleanup before maintainer review.
allowed-tools: Read, Grep, Glob, Bash
---

# GitHub Comment Manager Skill

Clean up scattered, redundant, or outdated GitHub comments by auditing, deleting stale ones, and consolidating into single clean summaries.

## Usage

```
/github-comment-manager [repo] [issue-or-pr-number]
```

Or audit all comments by a user:
```
/github-comment-manager [repo] --author [username]
```

## Workflow

### Step 1: Audit All Comments
```bash
# List all comments on an issue by a specific author
gh api repos/OWNER/REPO/issues/NUMBER/comments | \
  jq -r '.[] | select(.user.login=="USERNAME") | "\(.id) \(.created_at[:10]) \(.body[:80])"'

# List all PR review comments by author
gh api repos/OWNER/REPO/pulls/NUMBER/comments | \
  jq -r '.[] | select(.user.login=="USERNAME") | "\(.id) \(.created_at[:10]) \(.body[:80])"'
```

### Step 2: Classify Each Comment

| Classification | Action |
|---------------|--------|
| **Current & accurate** | Keep |
| **Superseded by later comment** | Delete |
| **Contains outdated claims** | Delete |
| **Duplicate content** | Delete, keep best version |
| **Partial - good evidence buried** | Extract evidence, delete |
| **Maintainer response reference** | Keep (never delete maintainer comments) |

### Step 3: Extract Best Content

Before deleting, extract valuable content from comments:
```bash
# Save comment body for reference
gh api repos/OWNER/REPO/issues/comments/COMMENT_ID | jq -r '.body' > /tmp/comment_COMMENT_ID.md
```

### Step 4: Delete Stale Comments
```bash
# Delete a specific comment
gh api -X DELETE repos/OWNER/REPO/issues/comments/COMMENT_ID

# For PR review comments (different endpoint)
gh api -X DELETE repos/OWNER/REPO/pulls/comments/COMMENT_ID
```

### Step 5: Post Consolidated Comment
```bash
# Post a clean, consolidated comment
gh issue comment NUMBER --repo OWNER/REPO --body "$(cat <<'EOF'
## Updated Analysis

[Consolidated content from multiple previous comments]

**Environment:** [specs]
**Reproduction:** [steps]
**Evidence:** [file:line references]
EOF
)"
```

## Rules

1. **NEVER delete maintainer comments.** Only delete your own (or the specified author's).
2. **Save before deleting.** Always capture comment body to /tmp before deletion.
3. **Log all deletions.** Track comment IDs deleted and reason.
4. **Consolidate, don't lose.** Any valuable evidence from deleted comments must appear in the consolidated version.
5. **One clean comment per issue.** The goal is a single, comprehensive comment that replaces N scattered ones.

## Audit Report Format

```markdown
# Comment Audit: REPO#NUMBER

| Comment ID | Date | Action | Reason |
|-----------|------|--------|--------|
| 123456 | 2026-01-15 | DELETE | Superseded by later analysis |
| 123457 | 2026-01-16 | KEEP | Contains maintainer response |
| 123458 | 2026-01-18 | DELETE | Duplicate of 123459 |
| 123459 | 2026-01-18 | CONSOLIDATE | Best version, merge with 123460 |

**Before:** 8 comments by @username
**After:** 1 consolidated comment
**Deleted:** 7 comments
```

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
