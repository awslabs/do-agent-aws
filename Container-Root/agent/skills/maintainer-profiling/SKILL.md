---
name: maintainer-profiling
description: Build communication profiles for open source maintainers by analyzing their PR review patterns, response times, approval triggers, and rejection patterns. Use when preparing to submit PRs or engage with unfamiliar maintainers.
allowed-tools: Read, Grep, Glob, Bash
---

# Maintainer Profiling Skill

Analyze maintainer behavior from GitHub activity to build communication profiles. Helps craft PRs and issues that match what specific maintainers expect.

## Usage

```
/maintainer-profiling [repo] [maintainer-username]
```

## Data Collection

### Step 1: Review Activity
```bash
# Get recent reviews by maintainer
gh api repos/OWNER/REPO/pulls?state=all\&per_page=50 | \
  jq -r '.[] | "\(.number) \(.title) \(.user.login)"'

# Get their review comments
gh api repos/OWNER/REPO/pulls/NUMBER/reviews | \
  jq -r '.[] | select(.user.login=="MAINTAINER") | "\(.state): \(.body)"'
```

### Step 2: Comment Pattern Analysis
```bash
# Get all review comments by maintainer across recent PRs
for pr in $(gh pr list --repo OWNER/REPO --state all --limit 50 --json number -q '.[].number'); do
  gh api repos/OWNER/REPO/pulls/$pr/comments 2>/dev/null | \
    jq -r ".[] | select(.user.login==\"MAINTAINER\") | .body" 2>/dev/null
done
```

### Step 3: Response Time Analysis
```bash
# Time between PR creation and first review
gh pr list --repo OWNER/REPO --state all --limit 30 \
  --json number,createdAt,reviews | \
  jq -r '.[] | select(.reviews | length > 0) |
    "\(.number) created:\(.createdAt) first_review:\(.reviews[0].submittedAt)"'
```

## Profile Template

```markdown
# Maintainer Profile: @USERNAME

## Communication Style
- [ ] Direct / Analytical / Diplomatic / Terse
- [ ] Technical depth: High / Medium / Low
- [ ] Response time: Hours / Days / Weeks

## Approval Triggers (DO)
- What makes them approve quickly?
- What format do they prefer?
- What level of testing do they expect?

## Rejection Triggers (DON'T)
- What causes CHANGES_REQUESTED?
- What pet peeves do they have?
- What patterns do they reject?

## Key Observations
- Preferred PR size (lines changed)
- Preferred commit style (squash vs granular)
- Stance on environment variables vs code changes
- Stance on backwards compatibility

## Communication Templates

### For Bug Fixes
[Template that matches their expectations]

### For Features
[Template that matches their expectations]

### For Issues
[Template that matches their expectations]
```

## Analysis Dimensions

### 1. Technical Philosophy
- **Architect:** Cares about design patterns, system integrity, long-term impact
- **Pragmatist:** Cares about "does it work?", minimal changes, practical fixes
- **Perfectionist:** Wants comprehensive tests, documentation, edge case handling

### 2. Review Depth
- **Surface:** Checks formatting, naming, obvious issues
- **Structural:** Checks architecture, patterns, abstractions
- **Deep:** Checks correctness, edge cases, performance implications

### 3. Response Patterns
- **Quick reviewer:** Responds within hours, may miss details
- **Thorough reviewer:** Takes days, catches everything
- **Batch reviewer:** Reviews multiple PRs at once on a schedule

### 4. Feedback Style
- **Directive:** "Change X to Y"
- **Socratic:** "Have you considered...?"
- **Blocking:** "This needs X before I can approve"

## Output

Save profile to: `maintainer-profiles/USERNAME.md`

Include:
- Communication DO/DON'T list
- Issue template optimized for this maintainer
- PR template optimized for this maintainer
- Expected review timeline
- Approval probability checklist

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
