---
name: phase-tracker
description: Track multi-phase projects with metrics, phase gates, and before/after impact analysis. Use when managing a multi-step project that needs progress tracking, phase completion reports, and quantified outcomes.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Phase Tracker Skill

Manage multi-phase projects with structured completion reports and impact metrics.

## Usage

```
/phase-tracker [action] [phase-number]
```

Actions: `init`, `start`, `complete`, `status`, `report`

## Phase Structure

### Initialization
```markdown
# Project: [NAME]
**Created:** YYYY-MM-DD
**Phases:** N total

## Phase 1: [NAME]
- **Objective:** [what this phase accomplishes]
- **Gate criteria:** [what must be true to move to next phase]
- **Metrics:** [what to measure before and after]
- **Status:** PENDING | IN_PROGRESS | COMPLETE | BLOCKED

## Phase 2: [NAME]
...
```

### Phase Completion Report
```markdown
# Phase N Complete: [NAME]

**Started:** YYYY-MM-DD HH:MM
**Completed:** YYYY-MM-DD HH:MM

## Metrics
| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Open PRs | N | N | -N% |
| Open Issues | N | N | -N% |
| Urgent Items | N | N | -N% |
| Build Status | FAIL | PASS | Fixed |

## Actions Taken
1. [Specific action with result]
2. [Specific action with result]

## Artifacts Created
- [file path] - [description]
- [file path] - [description]

## Gate Criteria Met
- [x] Criteria 1
- [x] Criteria 2
- [ ] Criteria 3 (deferred to Phase N+1)

## Blockers Encountered
- [Blocker and resolution]

## Next Phase Preview
- Phase N+1: [NAME]
- Key actions: [list]
```

## Tracking Commands

```bash
# Count open items
gh issue list --repo REPO --state open | wc -l
gh pr list --repo REPO --state open | wc -l

# Track review status
gh pr list --repo REPO --json number,reviewDecision -q '.[] | "\(.number): \(.reviewDecision)"'

# Timeline
gh issue list --repo REPO --state all --json number,createdAt,closedAt | \
  jq -r '.[] | "\(.number) opened:\(.createdAt[:10]) closed:\(.closedAt[:10] // "OPEN")"'
```

## Impact Narrative Template

After completing all phases, generate a summary:

```markdown
# Project Impact Summary

## Before
- [Quantified starting state]

## Actions (Phase 1-N)
- Phase 1: [outcome]
- Phase 2: [outcome]
- Phase N: [outcome]

## After
- [Quantified ending state]

## Net Impact
- [Delta with percentages]
```

## File Naming

Phase reports follow ISO 8601:
```
YYYY-MM-DD_HHMM_phaseN-complete.md
```

Store in project's status directory:
```
project/
├── 07-status-reports/
│   ├── YYYY-MM-DD_HHMM_phase1-complete.md
│   ├── YYYY-MM-DD_HHMM_phase2-complete.md
│   └── YYYY-MM-DD_HHMM_final-impact-report.md
```

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
