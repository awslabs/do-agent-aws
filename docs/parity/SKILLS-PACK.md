# Imported skills - the selection and its rule

Source: one directory per skill with a SKILL.md. Rule: kept when the frontmatter has a name and a description, the file is at most 20000 bytes, the name and description name no domain term and the body fewer than 8 distinct ones (the terms: EFA, libfabric, fi_, NCCL, NVSHMEM, DeepEP, NIXL, CUDA, GPU, RDMA, SRD, HyperPod, Trainium, Neuron, trn2, trn1, Dynamo, vLLM, SGLang, TensorRT, TRT-LLM, Megatron, NeMo, MoE, kernel, InfiniBand, p5en, p5.48xlarge, H100, H200, B200, DCGM, NVLink, nvidia-smi, torch, PyTorch, GDRCopy, gdrdrv, IBGDA, GDAKI, UCX, aws-ofi-nccl, nccl-tests, Slurm, MPI, UCCL, pplx, ibv_, NVIDIA, aiperf, genai-perf, KV cache, dispatch/combine, all-reduce, AllReduce, FSDP, Ray, FSx, Triton, DeepSeek, Qwen, Llama, Mixtral, P4d, p4d, P5, SDG, nccl, cuda), the name and description do not change under the scrub, at most 2 references to the source host remain (paths under a home directory or ~/, scratch/ paths, the names list's words, the skill's own files that are not copied), no skill named in the body is itself unshipped, no plugin the image installs ships the name, and nothing leak-shaped survives the scrub (Slack ids, account ids, IPv4 addresses, private hostnames, e-mail addresses, credential shapes, home-directory paths, messaging chat ids, gist URLs, the names list). Run on 2026-10-31.

Kept 35 of 395 skills. Dropped, by reason (the dropped skills' names are the source site's and are not listed):

- 294 domain-specific
- 29 host-bound
- 15 about the source site
- 14 depends on a skill not shipped
- 5 over --max-bytes (20000)
- 3 a plugin the image installs ships a skill of this name

| kept skill | note | bytes |
|---|---|---|
| ablate-combined-changes | SKILL.md alone | 3792 |
| agent-supervisor-methodology | SKILL.md alone | 3218 |
| benchmark-comparison | SKILL.md alone | 2642 |
| browser-vlm-acceptance | SKILL.md alone | 4521 |
| claim-verification | SKILL.md alone | 3262 |
| claude-code-best-practices | SKILL.md alone | 6025 |
| code-attribution | SKILL.md alone | 4311 |
| condition-based-waiting | SKILL.md alone | 4370 |
| conference-intelligence | SKILL.md alone | 4268 |
| deep-research-methodology | SKILL.md alone | 7891 |
| defense-in-depth | SKILL.md alone | 4521 |
| detect-deployment-thrashing | SKILL.md alone | 2826 |
| directory-cross-examination | SKILL.md alone | 3947 |
| doc-freshness-auditor | SKILL.md alone | 3355 |
| eval-harness | SKILL.md alone | 6494 |
| github-comment-manager | SKILL.md alone | 3249 |
| github-deep-research | SKILL.md alone | 5653 |
| github-issue-response | SKILL.md alone | 7151 |
| issue-closure-strategist | SKILL.md alone | 4425 |
| issue-quality-assessment | SKILL.md alone | 3783 |
| k8s-config-persistence-trap | SKILL.md alone | 1448 |
| k8s-configmap-runtime-patch | SKILL.md alone | 2591 |
| maintainer-profiling | SKILL.md alone | 3588 |
| measure-before-theorize | SKILL.md alone | 1393 |
| multi-phase-optimization-campaign | SKILL.md alone | 3817 |
| phase-tracker | SKILL.md alone | 2732 |
| pptx-slide-creation | SKILL.md alone | 7006 |
| pr-issue-scanner | SKILL.md alone | 3363 |
| public-root-reproducibility | SKILL.md alone | 5501 |
| repo-organizer | SKILL.md alone | 3848 |
| root-cause-tracing | SKILL.md alone | 6317 |
| technique-versioning-workflow | SKILL.md alone | 3728 |
| wrong-layer-debugging | SKILL.md alone | 1814 |
| wrong-theory-cascade-prevention | SKILL.md alone | 2210 |
| youtube-transcriber | SKILL.md alone | 2593 |
