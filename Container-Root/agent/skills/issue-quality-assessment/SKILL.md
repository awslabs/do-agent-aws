---
name: issue-quality-assessment
description: Multi-persona issue quality assessment using 5 independent perspectives (Code Auditor, Devil's Advocate, Maintainer, Reproducer, Synthesizer). Use when evaluating GitHub issues or PRs for quality, accuracy, and maintainer acceptance probability before submission.
allowed-tools: Read, Grep, Glob, Bash, Task
---

# Issue Quality Assessment Skill

Evaluate GitHub issues and PRs from 5 independent perspectives to score quality and predict maintainer response before submission.

## Usage

```
/issue-quality-assessment [repo] [issue-or-pr-number]
```

Or for pre-submission review of a draft issue:
```
/issue-quality-assessment [path-to-draft.md]
```

## The 5 Personas

### 1. Code Auditor
**Focus:** Is the code analysis correct? Are the claims verifiable?

Checks:
- Does the issue reference exact file paths and line numbers?
- Is the code snippet actually from the current version (verify against upstream)?
- Are the error messages real (not fabricated or paraphrased)?
- Is the root cause analysis sound?

Score: 0-10 on technical accuracy.

### 2. Devil's Advocate
**Focus:** What's wrong with this issue? What assumptions are untested?

Checks:
- Could this be user error, not a bug?
- Are there alternative explanations for the behavior?
- Is the reproduction environment typical or edge-case?
- What information is missing that a skeptic would ask for?

Score: 0-10 on robustness of claims.

### 3. Maintainer Perspective
**Focus:** Would you merge this / act on this issue?

Checks:
- Does it follow the project's issue template?
- Is the scope appropriate (not too broad, not too narrow)?
- Does the proposed fix align with project architecture?
- Is this a priority for the project right now?
- Red flags: environment variable workarounds, mixed concerns in one PR

Score: 0-10 on merge/accept probability.

### 4. Reproducer
**Focus:** Can someone reproduce this in under 30 minutes?

Checks:
- Are hardware requirements specified (instance type, GPU count)?
- Are software versions exact (not "latest" or "recent")?
- Are all configuration steps listed (env vars, build flags)?
- Is there a minimal reproduction case?
- Are expected vs actual outputs shown?

Score: 0-10 on reproducibility.

### 5. Synthesizer
**Focus:** Aggregate findings, identify consensus and conflicts.

Produces:
- Consensus findings (3+ personas agree)
- Conflicting findings (personas disagree)
- Overall quality score (weighted average)
- Specific improvement recommendations

## Scoring Scale

| Score | Quality Level | Action |
|-------|--------------|--------|
| 0-3 | Reject | Missing critical info, rewrite needed |
| 4-6 | Needs Work | Has basics but incomplete, revise |
| 7-8 | Good | Reproducible, clear steps, submit |
| 9-10 | Excellent | Maintainer can reproduce in <15 min |

## Verification Process

For each claim in the issue:
1. Locate exact file in upstream repo
2. Find exact line number(s)
3. Extract actual code vs claimed code
4. Verify against specific commit hash
5. Score confidence: CONFIRMED / WEAK / NOT FOUND / CONTRADICTED

## Output Format

```markdown
# Issue Quality Assessment: [TITLE]

## Persona Scores
| Persona | Score | Key Finding |
|---------|-------|------------|
| Code Auditor | X/10 | ... |
| Devil's Advocate | X/10 | ... |
| Maintainer | X/10 | ... |
| Reproducer | X/10 | ... |

## Overall Score: X/10

## Consensus Findings
- [Finding agreed by 3+ personas]

## Improvement Recommendations
1. [Specific action to improve score]
```

## Execution

Run each persona as a parallel subagent (Task tool) for speed:
1. Launch 4 persona agents in parallel (Code Auditor, Devil's Advocate, Maintainer, Reproducer)
2. Collect results
3. Run Synthesizer inline to aggregate
4. Present final assessment

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
