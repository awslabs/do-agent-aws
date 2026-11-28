---
name: github-deep-research
description: Use when searching GitHub beyond the default branch — forks, contrib/* branches, deleted code, historical refs, or work kept in contributors' forks. Use when `gh search code` comes back empty because it only indexes default branches.
---

# GitHub Deep Research

Search GitHub across forks, branches, deleted code, and historical refs. Beats `gh search code` (default-branch only) for finding work in forks and contrib branches.

## When to use

- Need to find non-default-branch code (contrib/*, fork branches)
- Looking for work a contributor keeps in a fork's contrib/* branches
- Searching across all forks of a public AWS repo for the canonical implementation
- Cross-repo aggregation (search same query across `aws-neuron/*`, `huggingface/*`)
- Need code archaeology (git log -S, deleted-branch refs, PR head refs)

## Tools available

| Tool | Use |
|---|---|
| `gh` CLI (system) | Quick lookups, repo CRUD, PR/issue create |
| `github-mcp-server` | MCP-mode CRUD (Claude Code tool calls) |
| Direct GitHub REST API | Full power, scriptable, no rate-limit if PAT-authed |

Auth: `gh auth token`; never hardcode a token in a script or a note.

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
gh api "repos/<fork-owner>/neuronx-distributed-inference/git/refs/heads" --paginate \
  --jq '.[] | .ref' | grep contrib/
```

### Pull a specific file from a non-default branch

```bash
gh api "repos/<fork-owner>/<repo>/contents/<path>?ref=<branch>" \
  --jq '.content' | base64 -d
```

### Clone a fork and snapshot multiple branches

```bash
gh repo clone <fork-owner>/neuronx-distributed-inference fork-nxdi
cd fork-nxdi
for branch in contrib/<model-a> contrib/<model-b>; do
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
| `huggingface/optimum-neuron` | HF-side Neuron support |
| `aws/aws-ofi-nccl` | EFA NCCL plugin |
| `aws-samples/aws-do-eks-trn` | Reference EKS+Trn deployments |

## Common tasks

### Find the latest contrib branch for a model in a fork

```bash
gh api repos/<fork-owner>/neuronx-distributed-inference/branches --paginate --jq '.[] | .name' | grep -i $MODEL
```

### Save provenance

When citing a gh API finding, ALWAYS save:
- The full URL with branch + commit hash
- The branch HEAD `git log -1` info
- The repo + commit at the time of citation (URLs change)

## Anti-patterns

- ❌ Don't fork aws-neuron repos to make changes — submit a PR to upstream or use a contrib/* branch
- ❌ Don't rely on `gh search code` alone — it indexes default branches only
- ❌ Don't shallow-clone (`--depth=1`) when doing archaeology — you lose history

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
