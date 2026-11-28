---
name: conference-intelligence
description: End-to-end conference intelligence gathering and analysis. Deploys parallel agent teams to scrape Twitter/X, LinkedIn, Reddit, HN, press, and GitHub for conference signals. Profiles personas, analyzes customer buying intent, maps competitive dynamics, and synthesizes executive-ready reports. Uses Bedrock for deep analysis. Use when user asks about any tech conference (GTC, re:Invent, Google I/O, Build, WWDC, etc.) or wants market signal analysis from an event.
---

# Conference Intelligence System

## When to Use
- User mentions a tech conference (GTC, re:Invent, Google I/O, Build, WWDC, KubeCon, etc.)
- User wants to understand "what the market is saying" about an event
- User needs executive-ready analysis of conference announcements
- User asks for competitive intelligence from a conference
- User wants persona analysis of conference attendees/speakers

## Agent Team (Deploy All in Parallel)

### 1. Executive Analyst
**Focus:** the user's business perspective — revenue, customers, competition
**Searches:** Customer wins, competitive gaps, revenue signals, pain points, opportunity map

### 2. LinkedIn Persona Analyst
**Focus:** WHO is posting — 50+ personas with buying intent signals
**Searches:** C-suite, VPs, analysts, VCs, CTOs, researchers, developers
**Output:** Persona profiles with influence tier, key quotes, buying signals

### 3. Twitter/X Persona Analyst
**Focus:** Influence tiers (1M+, 100K+, 10K+), viral content, developer sentiment
**Searches:** Viral tweets, threads, Twitter Spaces, memes, gaming reactions

### 4. Reddit & Community Analyst
**Focus:** Unfiltered developer/user voices
**Searches:** r/LocalLLaMA, r/MachineLearning, r/nvidia, r/aws, Hacker News, YouTube, podcasts, newsletters

### 5. Customer Signal Miner
**Focus:** 50+ companies — who's buying, what, how much, which cloud
**Searches:** Announcements, spending signals, job postings, alternative evaluations

### 6. Bedrock Deep Analyst
**Focus:** Market signal extraction via Bedrock Sonnet 4.6
**Input:** All collected signals from agents 1-5
**Output:** Business-framed analysis: buying triggers, competitive dynamics, revenue implications, 90-day outlook

## Execution Pattern

```
User: "Analyze <conference> from an executive perspective"
  │
  ├─ Agent 1: exec-analyst (background)
  ├─ Agent 2: linkedin-persona-analyst (background)
  ├─ Agent 3: twitter-persona-analyst (background)
  ├─ Agent 4: reddit-community-analyst (background)
  ├─ Agent 5: customer-signal-miner (background)
  │
  └─ [Wait for all agents]
       │
       └─ Bedrock Sonnet 4.6: Synthesize → Executive Report → PDF
```

## Output Structure

```
{conference}/executive-analysis/
  executive-perspective.md
  linkedin-persona-profiles.md
  twitter-persona-profiles.md
  community-and-media-deep-dive.md
  customer-enterprise-signals.md
  bedrock-market-analysis.md
  FINAL-EXECUTIVE-REPORT.md
  FINAL-EXECUTIVE-REPORT.pdf
```

## Key Principles

1. **Market signals, not keynote recaps** — What does it MEAN, not what was SAID
2. **Conference as a whole, not just keynote** — Sessions, booths, hallway conversations, partner events
3. **Persona profiling** — WHO is saying it matters as much as WHAT they're saying
4. **Customer buying intent** — Every signal should map to a revenue implication
5. **Competitive framing** — Every finding should be positioned relative to the user's company and its competitors
6. **10x collection depth** — 50+ personas, 50+ companies, 30+ Reddit threads, all major press

## Bedrock Integration

```python
# Market signal analysis
client = boto3.client("bedrock-runtime", region_name="us-west-2")
response = client.invoke_model(
    modelId="us.anthropic.claude-sonnet-4-6",
    body=json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 8192,
        "messages": [{"role": "user", "content": prompt}]
    })
)
```

## Transcript Analysis

For keynote/session videos:
1. Download audio locally → upload to S3
2. Amazon Transcribe ($0.024/min) → full transcript
3. Feed transcript to Bedrock Sonnet 4.6 for market signal extraction
4. NOT a transcript summary — extract buying triggers, competitive signals, customer mentions

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
