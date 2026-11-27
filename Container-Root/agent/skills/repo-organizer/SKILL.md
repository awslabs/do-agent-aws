---
name: repo-organizer
description: Organize files into categorical folders with ISO 8601 chronological naming convention. Use when a directory has accumulated many files that need structured organization with consistent naming.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Repository Organizer Skill

Recursively organize files into categorical folders with ISO 8601 naming and create navigation documents.

## Usage

```
/repo-organizer [target-directory]
```

- `$ARGUMENTS[0]` = directory to organize (default: current directory)

## Naming Convention

### Files
```
YYYY-MM-DD_HHMM_descriptive-name.md
```
- Date from file creation/modification time
- Time in 24hr format (use `stat` to get actual times)
- Lowercase, hyphens between words
- No spaces, no special characters

### Folders
```
NN-category-name/
```
- Two-digit prefix for sort order (01, 02, ... 99)
- Descriptive category name in lowercase with hyphens
- `99-archive/` always last for duplicates/old versions

## Workflow

### Step 1: Inventory
```bash
# List all files with dates
find TARGET_DIR -maxdepth 1 -type f -printf '%T+ %p\n' | sort

# Count files by extension
find TARGET_DIR -maxdepth 1 -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn
```

### Step 2: Categorize

Read each file's first 10 lines to determine category:
```bash
for f in TARGET_DIR/*; do
  echo "=== $(basename "$f") ==="
  head -10 "$f"
  echo
done
```

Assign to categories. Common categories:
- `01-primary-topic/` - Main subject matter
- `02-analysis/` - Analysis and investigation
- `03-evidence/` - Supporting evidence and data
- `04-strategy/` - Strategy and planning
- `05-communication/` - Templates and outreach
- `06-summary/` - Executive summaries and briefs
- `07-status/` - Progress reports and tracking
- `08-technical/` - Technical deep dives
- `09-scripts/` - Automation and tooling
- `99-archive/` - Old versions, duplicates

### Step 3: Create Folders
```bash
mkdir -p TARGET_DIR/{01-category,02-category,...,99-archive}
```

### Step 4: Rename and Move

For each file:
1. Get creation date: `stat -c '%W' file` (or `%Y` for modification)
2. Convert to ISO 8601: `date -d @TIMESTAMP '+%Y-%m-%d_%H%M'`
3. Create descriptive name from content
4. Move: `mv "old-name.md" "NN-category/YYYY-MM-DD_HHMM_descriptive-name.md"`

```bash
# Example rename
TIMESTAMP=$(stat -c '%Y' "old-file.md")
DATE=$(date -d @$TIMESTAMP '+%Y-%m-%d_%H%M')
mv "old-file.md" "01-primary/${DATE}_descriptive-name.md"
```

### Step 5: Handle Subdirectories

For existing subdirectories:
- If they fit a category, move them into the numbered folder
- If they ARE a category, rename with the NN- prefix
- Preserve internal structure

### Step 6: Create Navigation Documents

**README.md** (top-level):
```markdown
# Project Name

## Directory Structure
- `01-category/` - Description
- `02-category/` - Description
...

## Quick Links
- [Most important doc](01-category/file.md)
- [Latest status](07-status/latest.md)
```

**STRUCTURE.txt** (tree view):
```bash
tree -I '__pycache__|node_modules|.git' TARGET_DIR > TARGET_DIR/STRUCTURE.txt
```

### Step 7: Verify

```bash
# Confirm no files left in root (except navigation docs)
ls TARGET_DIR/*.md TARGET_DIR/*.txt 2>/dev/null

# Confirm all files accessible
find TARGET_DIR -name "*.md" | wc -l

# Confirm no broken references
grep -r "](.*\.md)" TARGET_DIR | grep -v "README\|INDEX\|STRUCTURE"
```

## Rules

1. **Never delete files.** Move to `99-archive/` if duplicate or outdated.
2. **Preserve git history.** Use `git mv` if in a git repo.
3. **Keep navigation docs in root.** README.md, INDEX.md, STRUCTURE.txt stay at top level.
4. **Log all moves.** Create a `_reorganization-log.txt` with before/after paths.
5. **Timestamp from content, not system.** If file has a date in its name or content, use that over filesystem timestamps.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
