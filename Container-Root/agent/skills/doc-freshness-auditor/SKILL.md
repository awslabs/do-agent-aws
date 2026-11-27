---
name: doc-freshness-auditor
description: Audit documentation URLs and files for staleness by checking commit dates, release tags, and version history. Use when analysis relies on documentation that may be outdated or when building source-of-truth references.
allowed-tools: Read, Grep, Glob, Bash, WebFetch
---

# Documentation Freshness Auditor Skill

Check whether documentation sources are current or stale before using them as evidence in analysis or recommendations.

## Usage

```
/doc-freshness-auditor [path-or-url-list]
```

## Workflow

### Step 1: Collect All Documentation References

Extract every URL and file reference from the target document:
```bash
# Extract URLs from a markdown file
grep -oP 'https?://[^\s)>"]+' DOCUMENT.md | sort -u

# Extract file path references
grep -oP '`[^`]*\.(md|txt|yaml|json|py|cpp|h)`' DOCUMENT.md | sort -u
```

### Step 2: Check Each Source

#### For GitHub URLs
```bash
# Get last commit date for a file
gh api repos/OWNER/REPO/commits?path=PATH&per_page=1 | \
  jq -r '.[0].commit.committer.date'

# Get release tags and dates
gh release list --repo OWNER/REPO --limit 10

# Check if file exists in current main
gh api repos/OWNER/REPO/contents/PATH 2>/dev/null && echo "EXISTS" || echo "NOT FOUND"
```

#### For Web Documentation
```bash
# Check last-modified header
curl -sI URL | grep -i "last-modified"

# Check page content for version numbers
curl -s URL | grep -oP 'version[:\s]*[\d.]+' | head -5
```

#### For Local Files
```bash
# Check modification date
stat -c '%Y %n' FILE | while read ts name; do
  echo "$(date -d @$ts '+%Y-%m-%d') $name"
done

# Check if file references deprecated versions
grep -n "v0\.\|deprecated\|removed\|obsolete" FILE
```

### Step 3: Score Freshness

| Age | Rating | Action |
|-----|--------|--------|
| < 30 days | FRESH | Use as-is |
| 30-90 days | RECENT | Verify key claims still hold |
| 90-180 days | AGING | Cross-reference with newer sources |
| 180+ days | STALE | Find replacement or verify against current code |
| File not found | DEAD | Remove reference entirely |

### Step 4: Check Version Alignment

For each documentation source, verify:
- Does the doc reference the same software version you're using?
- Has the API/config changed between the documented version and current?
- Are there deprecation notices for anything mentioned in the doc?

```bash
# Compare documented version vs current
DOCUMENTED_VERSION=$(grep -oP 'version[:\s]*[\d.]+' DOC | head -1)
CURRENT_VERSION=$(gh release list --repo OWNER/REPO --limit 1 | awk '{print $1}')
echo "Doc: $DOCUMENTED_VERSION, Current: $CURRENT_VERSION"
```

### Step 5: Generate Report

```markdown
# Documentation Freshness Audit

**Audited:** YYYY-MM-DD
**Source document:** [path]

## Summary
- Total sources: N
- FRESH: N
- RECENT: N
- AGING: N
- STALE: N
- DEAD: N

## Details

| Source | Last Updated | Rating | Version Match | Notes |
|--------|-------------|--------|---------------|-------|
| URL/file | YYYY-MM-DD | FRESH | Yes/No | ... |
```

## When to Use

- Before building analysis documents from multiple documentation sources
- When a user says "some of these documents are outdated"
- Before recommending configurations based on documentation
- When cross-referencing between official docs and source code
- After a major version release (check if docs reflect new version)

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
