# issues tracker - vendored runtime

This directory is the issues tracker's minimal runtime, shipped in the image at `/opt/issues-tracker` byte for byte as
its owner exported it, without session artifacts. The `issues` spoke
links it as its `repo/`; its cycle runs `scripts/gh-ro` and `scripts/gh-dashboard.py` from it, and its `post.sh` adds
`scripts/redact-scan.sh --strict` and the `.claude/hooks/` noise filter and `block-gh-write.sh`. Nothing here is edited
in this repository.

| | |
|---|---|
| Version | 0.1.9-20261127 |
| Source | public `https://github.com/dmvevents/issues-tracker-runtime`, tag `v0.1.9` (`b92415223bcf19015a281a74b7fb927d13675330`) |
| Tarball | release asset `issues-tracker-runtime-0.1.9-20261127.tar.gz`, sha256 `c9b5b8d9be390902b2bd11c05af258ec5161795501156b5612bab4af379a18e2` |
| Source head | `b92415223bcf` |
| Files | 32, each in MANIFEST.sha256 (sha256 of that file: `acc954add6c4baa315e327e32fdbb4b60648e28a22a74766876e7b8f9210ffe6`); this file is the only addition |
| Checks at import | the tarball's sha256, only files and directories under one top directory, every MANIFEST line, the harness's tree scan (Container-Root/seed/scan.py --tree) |

Its `bin/pr-timeline` and `bin/gh-comment-audit` need `jq`, which this image does not carry. Refresh with
`tools/vendor-issues-tracker.sh <tarball> <sha256> <version> <source head>` from the repository root.
