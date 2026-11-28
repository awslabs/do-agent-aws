---
name: public-root-reproducibility
description: Use when writing any REPRODUCE.md / repro guide / public blog steps / open-source reproduction package, or any time a build or deploy recipe FROMs or pins an image, fork, or SHA you produced. Symptoms — "docker pull our-image", "FROM ghcr.io/<ourorg>/...", "don't rebuild the base, just pull it", pinning a private-fork SHA, "reader gets to a serve fastest".
---

# Public-Root Reproducibility (chain of custody)

## Overview

**A reproduction is only reproducible if its entire dependency graph bottoms out
in PUBLIC roots.** If any leaf is an artifact you produced — a private/published
image, a fork SHA, an internal registry — the recipe is not reproducible for
someone without your access, no matter how fast it runs for you.

Core insight: **you cloned public, patched it, and cached the result in a private
image/fork. The private artifact is DOWNSTREAM of public — it is a convenience
cache, never the root of the recipe.** The reproducible path re-derives from the
public source + your patch, expressed as a diff/PR, not `docker pull`.

**"Public" means the reproducer's account can fetch it** — an official upstream
repo at a pinned SHA, a public release, an official vendor base (e.g. NGC). A repo
or image YOUR org published is NOT automatically public-usable: if you built it,
it is a downstream cache, not a root.

## The Iron Rule

**Every artifact in a reproduction recipe must trace to a public root, or be a
diff/PR against a named public commit. No leaf may be something you produced.**

Violating the letter (one `FROM ghcr.io/ourorg/...`) violates the spirit — the
reader without access is stuck at step 1.

## When to Use

- Writing REPRODUCE.md, INSTRUCTIONS.md, a blog "how to reproduce", a repro repo.
- Any Dockerfile `FROM` or manifest `image:` in a recipe meant for others.
- Pinning a git SHA, branch, or wheel in a shared build.
- Handing a "patch inventory" to another team.
- ANY time the fast path is "pull the image we already built."

## The Method

1. **Name the public roots.** For each dependency, the official upstream repo +
   pinned SHA/tag, or the official vendor base image. Write the URL+ref down.
2. **Express every change as a diff against a public commit.** A patch you made =
   a `.patch` file applied to `clone @ SHA`, OR a public PR branch fetched via
   `git fetch origin pull/<N>/head`. Prefer BOTH: file the PR *and* ship the
   `.patch` (robust if the PR rebases/closes).
3. **Build FROM public.** Base image `FROM` an official vendor image (NGC etc.),
   then build the substrate from public sources. Never `FROM` your own image.
4. **Every private-only capability is a GAP** with a named closing PR. List them
   explicitly in a DELTAS-vs-private section. Silent dependence is forbidden.
5. **Private artifacts may appear only as OPTIONAL accelerators**, clearly marked:
   "we also publish a prebuilt image at X to skip the ~45-min build; the
   reproducible path does not require it." Never the only path.
6. **Public-first, not merge-gated.** Do not wait for PRs to merge. Start from
   public `@ SHA`, apply your patch/PR branch now — that IS reproducible. Merges
   only shrink the patch delta later.

## Quick Reference

| Instead of (private root) | Do (public root) |
|---|---|
| `FROM ghcr.io/ourorg/base:v0.2.5` | `FROM nvcr.io/nvidia/cuda:...` + build substrate from public sources |
| `docker pull ourorg/base` as step 1 | build from Dockerfile whose FROM is public; offer the pull as an optional accelerator |
| `pip install git+github.com/ourfork/vllm@<sha>` | `git+github.com/vllm-project/vllm@<public-sha>` (+ our patch/PR if not merged) |
| pin `<name>/DeepEP-1@branch` | `deepseek-ai/DeepEP@<sha>` + `git fetch pull/612/head` or `git apply 0001.patch` |
| "hand the patch inventory to the team" | file each patch as a PR to its upstream + keep the `.patch` in-repo |

## Common Mistakes / Rationalizations

| Rationalization | Reality |
|---|---|
| "Don't rebuild the base — just pull it, it's battle-tested" | The reader can't pull your private image. Rebuild FROM public is the recipe; the pull is an optional shortcut. |
| "Reader gets to a serve fastest this way" | Speed-to-green via a private root produces a recipe that reproduces for nobody but you. Correct > fast. |
| "The SHA was given to me, I'll honor it" | If the SHA is a private fork, honoring it bakes in the gap. Trace it to its public base + the diff on top. |
| "It's published (GHCR/public ECR), so it's public" | If YOU built/pushed it, it's a downstream cache, not a root. Published != reproducible-from-source. |
| "The image already carries the env/patches, re-specifying risks drift" | Then put the env/patches in the PUBLIC Dockerfile/patch, which is the source of truth — not locked inside a binary image. |
| "We'll make it public once the PR merges" | Public-first now: clone public @ SHA + apply patch/PR branch. Don't gate reproducibility on a merge. |

## Red Flags — STOP

- A recipe step is `docker pull <your-org>/...` or `FROM <your-org>/...`.
- A pinned dependency SHA lives in a fork you control and you can't name its
  public base + the diff.
- You're optimizing the recipe for YOUR iteration speed, not the reader's ability
  to reproduce from scratch.
- There's no "DELTAS vs private / GAP list" section, but the setup used forks.

**All mean: re-root the recipe on public sources; convert each private artifact
to a diff/PR against a named public commit.**

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
