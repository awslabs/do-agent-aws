# tmux-agent dashboard - vendored build

This directory is a prebuilt copy of the tmux-agent dashboard (`dmvevents/tmux-agent-public`, the public source
repository of the tmux-agent web dashboard, CLI and MCP server), shipped inside the image at `/opt/tmux-agent` so the
`tmux-agent dashboard` tile works out of the box, offline, for a user who cannot reach the source repository.

| | |
|---|---|
| Upstream | `dmvevents/tmux-agent-public` (https://github.com/dmvevents/tmux-agent-public), tag `v0.1.1` |
| Commit | `92113b54b755cffc7666c0f475cb706b38d9ade9` (2026-11-27T15:16:12Z, the merge of the upstream release PR #6) |
| Package version | 0.1.1 (`dist/build.json` carries the commit and build time; the MCP server still reports 0.1.0, hard-coded upstream in `src/mcp/server.ts`) |
| License | Apache-2.0 - `LICENSE` and `NOTICE` are shipped alongside, as the license requires |
| Built with | `tools/vendor-tmux-agent.sh` (`npm ci && npm run build`: tsc + `scripts/build-stamp.mjs`) on Node 24 |

What 0.1.1 changes from 0.1.0 (`4e60513`): the zod 4 / MCP SDK 1.32 dependency update, which clears the npm advisories against 0.1.0 (upstream reports `npm audit --omit=dev` at 0 vulnerable on 0.1.1, 7 including 2 high on 0.1.0), and the package version bump to 0.1.1. The copy comes
from the public repository, so `package.json`'s repository, homepage and bugs links and the `NOTICE` name
`dmvevents/tmux-agent-public`, `NOTICE` carries the copyright line and `README.md` is the public repository's; a spawn
whose launch command did not land is an error (exit 1, the session kept, `commandDelivered: false` on its ledger row);
a `policy.json` or `lexicon.json` that is a symbolic link to a missing file is refused instead of read as absent; a
health warning is not filed again within 10 minutes of its recovery (`rewarnHoldDownMinutes`; a critical still is);
the context badge also reads the bar form `ctx:[####]71%`; the latest census sets a session's parent; and `status`,
`lineage` and the MCP `fleet-status` say when census enrichment has aged into the ledger archive.

Why this tree: the dashboard's original repository is private and not scrubbed for publication; its owner's
decision is that the dashboard is published as `dmvevents/tmux-agent-public`, a scrubbed snapshot, and this copy is
built from the commit `.env` pins as `TMUX_AGENT_REF` for the first-start build, so the offline copy and the
first-start build are the same commit. Its build carries no project-internal identifiers (checked at vendoring time
with `Container-Root/seed/scan.py --tree` and a privacy gate over id, path, host and name patterns).

What is here: `dist/` (the compiled JavaScript; `.d.ts` type declarations stripped), `package.json`,
`package-lock.json` (so the two runtime dependencies - `zod` and `@modelcontextprotocol/sdk`, both only
needed by the MCP server binary, not by the `web` verb - are installed reproducibly at image build by
`setup/install-tmux-agent-dashboard.sh` with `npm ci --omit=dev`), `README.md`, `LICENSE`, `NOTICE`. `README.md` is
upstream's, verbatim: its relative links to `CONTRIBUTING.md`, `SECURITY.md`, `VERSIONING.md` and five files under
`docs/` name files this copy does not carry, and they resolve in `dmvevents/tmux-agent-public` at `92113b5`.

Security patch level: `package-lock.json` carries one update beyond upstream's lockfile at `92113b5`, applied with
`npm audit fix --package-lock-only` (no declared version range changed): the build-only `typescript-eslint` tooling
8.68.0 to 8.74.0, which drops a `minimatch` that GHSA-g3hv-75wg-m249 affects. `npm audit` reports 0 vulnerabilities
with and without the dev dependencies; the image installs only the runtime ones (`npm ci --omit=dev`). A refresh with
`tools/vendor-tmux-agent.sh` takes upstream's lockfile, so run that command again afterwards until upstream carries it.

Nothing in this tree but this file and that lockfile update is edited by hand. To refresh it from a clone you can reach, run
`tools/vendor-tmux-agent.sh <path-to-clone>` from the repository root (it builds, copies, and refuses an
uncommitted tree) and commit the result together with the new commit in this file and in `.env`'s `TMUX_AGENT_REF`:
test14 check 4 fails unless this file, the build and that pin name the same commit.

To build the dashboard from a different source at container start instead of using this copy, set
`TMUX_AGENT_SRC` (see `.env`); `/agent/install-tmux-agent.sh` then fetches and builds it into
`TMUX_AGENT_INSTALL_DIR`.
