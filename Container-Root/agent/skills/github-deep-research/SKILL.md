---
name: github-deep-research
description: Use when searching GitHub beyond the default branch — forks, contrib/* branches, deleted code, historical refs, or AWS-internal team contributions. Use when `gh search code` comes back empty because it only indexes default branches.
---

# GitHub Deep Research

Search GitHub across forks, branches, deleted code, and historical refs. Beats `gh search code` (default-branch only) for finding internal-team work and contrib branches.

## When to use

- Need to find non-default-branch code (contrib/*, fork branches)
- Looking for AWS-internal team contributions (jburtoft fork pattern)
- Searching across all forks of a public AWS repo for the canonical implementation
- Cross-repo aggregation (search same query across `aws-neuron/*`, `huggingface/*`)
- Need code archaeology (git log -S, deleted-branch refs, PR head refs)

## Tools available

| Tool | Use |
|---|---|
| `gh` CLI (system) | Quick lookups, repo CRUD, PR/issue create |
| `github-mcp-server` | MCP-mode CRUD (Claude Code tool calls) |
| `github-crawler` (Go binary) | Currently only `pr_graph` mode in dev build — limited |
| Direct GitHub REST API | Full power, scriptable, no rate-limit if PAT-authed |

Auth token at `<path>` or `gh auth token`. Fallback: `<REVOKED — never hardcode a token here; use `gh auth token`>`.

## Operations

### Search code across all forks of a repo

```bash
# Find every fork of aws-neuron/neuronx-distributed-inference
gh api repos/aws-neuron/neuronx-distributed-inference/forks --paginate \
  --jq '.[] | "\(.full_name) \(.default_branch)"'

# Then for each fork, list all branches
for fork in $(gh api repos/aws-neuron/neuronx-distributed-inference/forks --paginate --jq '.[] | .full_name'); do
  echo "=== $fork ==="
  gh api "repos/$fork/branches" --paginate --jq '.[] | .name' | grep -iE 'glm|kimi|wan|qwen' | head
done
```

### Search code in a specific fork's contrib branches

```bash
gh api "repos/jimburtoft/neuronx-distributed-inference/git/refs/heads" --paginate \
  --jq '.[] | .ref' | grep contrib/
```

### Pull a specific file from a non-default branch

```bash
gh api "repos/jimburtoft/neuronx-distributed-inference/contents/contrib/models/GLM-5/glm5_neuron.py?ref=contrib/GLM-5" \
  --jq '.content' | base64 -d
```

### Clone a fork and snapshot multiple branches

```bash
gh repo clone jimburtoft/neuronx-distributed-inference jburtoft-nxdi
cd jburtoft-nxdi
for branch in contrib/GLM-5 contrib/qwen3.5-27b contrib/wan21-rollingforcing; do
  git checkout "$branch"
  cp -r contrib/models/* /save/branches/$(echo $branch | tr / _)/
done
```

### Search for an issue/error code across all aws-neuron repos

```bash
for repo in aws-neuron/aws-neuron-sdk aws-neuron/aws-neuron-samples aws-neuron/neuronx-distributed-inference aws-neuron/transformers-neuronx; do
  echo "=== $repo ==="
  gh issue list --repo "$repo" --search "NCC_IBIR297" --state all --json number,title,state,createdAt --limit 5
done
```

### List PRs touching a specific file across forks

```bash
gh search prs "GLM-5" --json title,url,repository,state | jq -r '.[] | "\(.repository.nameWithOwner)#\(.title) [\(.state)] \(.url)"'
```

### Code archaeology — find deleted code

```bash
# Local clone with all refs
git clone --mirror https://github.com/aws-neuron/neuronx-distributed-inference.git mirror.git
cd mirror.git
git log --all -S "NCC_IBIR297" --pretty=format:'%h %s'  # pickaxe across all branches+PR refs
```

### Get a specific PR's full conversation graph

```bash
# pr_graph via github-crawler MCP if Claude Code is wrapping it
# Direct API:
PR=70 REPO=aws-neuron/neuronx-distributed-inference
gh pr view "$PR" --repo "$REPO" --comments --json title,body,comments,reviews,commits,files
```

## High-value AWS Neuron repos

| Repo | Contains |
|---|---|
| `aws-neuron/aws-neuron-sdk` | Release notes, docs, ground-truth |
| `aws-neuron/neuronx-distributed-inference` | NxDI source — production class |
| `aws-neuron/aws-neuron-samples` | Reference implementations |
| `aws-neuron/transformers-neuronx` | Older API (pre-NxDI) |
| `jimburtoft/neuronx-distributed-inference` | jburtoft's contrib fork — **GLM-5, Qwen3.5, WAN 2.1, Kimi-K2.6** all in branches `contrib/<name>` |
| `jimburtoft/NeuronStuff` | Steering docs, NKI examples, Wan2.2 |
| `huggingface/optimum-neuron` | HF-side Neuron support |
| `aws/aws-ofi-nccl` | EFA NCCL plugin |
| `aws-samples/aws-do-eks-trn` | Reference EKS+Trn deployments |

## High-value individual contributors

| Person | GitHub | Slack | Notes |
|---|---|---|---|
| jburtoft | `jimburtoft` | `<SLACK_ID>` | NxDI contrib branches for GLM-5, Qwen3.5, WAN 2.1, Kimi-K2.6, etc. |
| Public AWS team | `aws-neuron/*` | various | Official Neuron releases |

## Common tasks

### Find the latest jburtoft branch for a model

```bash
gh api repos/jimburtoft/neuronx-distributed-inference/branches --paginate --jq '.[] | .name' | grep -i $MODEL
```

### Save provenance

When citing a github-crawler / gh API finding, ALWAYS save:
- The full URL with branch + commit hash
- The branch HEAD `git log -1` info
- The repo + commit at the time of citation (URLs change)

## Anti-patterns

- ❌ Don't fork aws-neuron repos to make changes — submit a PR to upstream or use a contrib/* branch
- ❌ Don't rely on `gh search code` alone — it indexes default branches only
- ❌ Don't shallow-clone (`--depth=1`) when doing archaeology — you lose history

## Cross-references

- Slack skill: `aws-slack-search` (find which person to ask via Slack first, then look at their fork)
- Cached jburtoft fork: `<path>`

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
