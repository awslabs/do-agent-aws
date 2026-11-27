# LogLearner knowledge packs shipped in the image

`/agent/loglearner-packs.sh` loads every `<name>.jsonl` here that has a matching `<name>.manifest.json`. The pack
loader checks each file against its manifest's sha256 before it writes. Every pack here counts as default knowledge,
so `AGENT_KNOWLEDGE=false` loads none of them.

| Pack | Origin |
|---|---|
| `gpu-cluster-basics` | Vendored, unchanged, from the public example pack in `dmvevents/loglearning` (MIT) |

## gpu-cluster-basics (vendored)

| | |
|---|---|
| Upstream | https://github.com/dmvevents/loglearning, `examples/packs/gpu-cluster-basics/` |
| Tag | `pack-gpu-cluster-basics-v0.1.0`, commit `69d53ce7502d1d21f6c4f0d10020b464a3cdb72e` |
| Release asset | `gpu-cluster-basics-0.1.0.tar.gz`, sha256 `e673ab0f15d4089e5b655cf6220e56ef35397decb61a918611bda266e0e31fb3` |
| Pack file | `gpu-cluster-basics.jsonl`, sha256 `8edbe1d0e9967208a9b49cab13b962dd1124cf91dd12a23ecb04be13f6d00b39` (as its manifest records), 21 records |
| What it is | Generic GPU, NCCL, EFA, Kubernetes and PyTorch troubleshooting records, each written from the public documentation page named in its `source` field |
| License | MIT. `LICENSE` here is the repository's own `LICENSE` at the tag's commit, sha256 `5638d05e74420e3feabb95142990d35d6b4c19c72140c1897cb9350747e05578`: the release asset carries no license file |

The pack's `.jsonl` and `.manifest.json` are copied from the release asset, and `LICENSE` from the repository at the
tag's commit, each unchanged. The release asset also carries its README, SOURCES.md and MANIFEST.sha256, which are not
copied. To refresh, download the asset, check its sha256, copy the two pack files, and copy `LICENSE` from the same
commit.
