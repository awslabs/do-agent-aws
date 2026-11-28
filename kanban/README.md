# Self-hosted kanban board: build inputs

This folder holds what `./kanban.sh build` needs to build the board server image
(`${REGISTRY}${IMAGE}-kanban${TAG}` in `.env`) from public sources only. See docs/manual/boards.md "Kanban board" for how the
board runs, where its login is and how the agent's work reaches it.

| input | value |
|---|---|
| upstream | `https://github.com/BloopAI/vibe-kanban` (Apache-2.0), the `crates/remote` server and `packages/remote-web` frontend |
| pinned commit | `4deb7eca8f381f7cbc1f9d15515a9ab8f8009053` (tag `v0.1.44-20260424091429`, the v0.1.44 release; `KANBAN_VK_SHA` in `.env`) |
| patches | `patches/0001-restore-project-kanban-board.patch`, sha256 `338f2dc23d8d5da25279a5da92416a8eef9066a3330582ba777cd35f0b2a63e9` (upstream's own code); `patches/0002-self-hosted-board-no-cloud-shutdown-banner.patch`, sha256 `cffb870b4f8827a73cb3d3b9df4d99bcfe5e7cddf50a5c22c495640b38d274b5` (ours); `patches/0003-goals-board-goal-noun-keys-and-new-goal-note.patch`, sha256 `18c3b228b04060938135842664931f367c64e118f0d8feae189ad86b5cce423a` (ours); `patches/0004-goals-board-bounded-host-lookup-runner-settings.patch`, sha256 `159b6affb02f4f546c7b3896024d883101be181d2e188555dc7b589f89e89985` (ours); `patches/0005-goals-board-no-web-fonts-or-community-counts.patch`, sha256 `4484cc7d8d91d3d797b2f88b5dad320dd9f9260c96f456725320c3c669c29801` (ours); `patches/0006-goals-board-harness-mode-hides-community-and-pairing.patch`, sha256 `6801efcd5e11d131b965b61e8364fe5d186de624d7017befdeb6e7db5a5eda03` (ours); `patches/0007-goals-board-full-instructions-disclosure.patch`, sha256 `f5fcedff6f2bc44d01713ab7efff202b70dce9de8bb3b65c9bcc7b6e27951566` (ours); `patches/0008-goals-board-sync-origin-and-pending-writes.patch`, sha256 `3e5c6511135363238f444508e0675d6cad435db6b7ca02673c9a5876828df5f7` (ours) |
| relay patches (`UI_KANBAN_RELAY=true` only) | `patches-relay/0101-goals-board-relay-pair-host.patch`, sha256 `bba97286c0f4014979d02773f0d2af0f9ede0c7e74190a88d6643aec22b4b843` (ours), after the patches above |
| build | `docker image build -f crates/remote/Dockerfile` on the patched checkout (the upstream Dockerfile, unchanged; its base images from ECR Public and its `# syntax=` frontend, each by digest: `KANBAN_BUILD_BASES`, `KANBAN_BUILD_SYNTAX`); with `UI_KANBAN_RELAY=true` also `docker image build -f crates/relay-tunnel/Dockerfile` on the same checkout, the relay server image `${REGISTRY}${IMAGE}-kanban-relay${TAG}` |
| source checkout | `kanban/src/` (gitignored, never part of the agent image's build context) |

## Why a patch

vibe-kanban 0.1.44 retired its cloud and, with it, the project board: upstream PR #3387 (commit `97123d526`) turned
`packages/web-core/src/pages/kanban/ProjectKanban.tsx` into a stub that always renders `ProjectSunsetPage`
("Project functionality has been retired"). Everything the board needs still ships in 0.1.44; only its wiring was
removed. The patch puts back the component from the commit before the sunset (`c768ce21`): `OrgProvider`,
`ProjectProvider`, `KanbanContainer` (the board) and `ProjectRightSidebarContainer` (the issue panel). It changes that
one file and nothing else.

The second patch is this harness's own, not upstream code: in `packages/remote-web/src/app/layout/RemoteAppShell.tsx`
the board shows vibe-kanban's "Vibe Kanban Cloud is shutting down. Export your data within 30 days." banner only on
its export page (`/export`), no longer on every project page: the notice is about the hosted cloud, not about this
self-hosted board. It changes that one condition and nothing else.

The third patch is ours too: the board is the agent's Goals board, so its cards are goals.
- The board's English strings say goal for issue: New Goal, Create Goal, Search goals..., Sub-goals, the help text
  and the title placeholder.
- The New Goal panel says what a new goal does: "A new goal goes to the goals file; the autonomy loop's Claude Code
  works on it at its next fire (start the loop if it has stopped)." The draft-workspace toggle's description says
  that its workspace runs on a vibe-kanban host linked to this board, and that none is linked by default.
- A new organization's card keys are `GOAL-n`. The server derives an organization's prefix once, when it creates
  the organization (`derive_issue_prefix`, normally the first three letters of its name), and each card keeps the
  key it got. So a board whose organization already exists keeps its prefix (`CCF-1`, for one); a fresh board's
  first card is `GOAL-1`.

The fourth patch is ours: the board's settings dialog has a "Machine Settings" section for a vibe-kanban host linked
to the board, and with none linked it could say "Loading settings..." for as long as its host lookup hung. The lookup
now counts as done after 8 s. With no host, the dialog says this harness's coding agents and MCP servers are set in
its agent runner, and links the runner (the same port on `vk-runner.localhost`).

The fifth patch is ours: the board makes no optional third-party call. It loads no web font from Google Fonts
(IBM Plex when it is installed locally, else the system font stack), and it asks GitHub for no star count and
Discord for no online count. The app bar's links to both are links, not calls.

The sixth patch is ours: the board runs in an explicit harness mode (`packages/web-core/src/shared/lib/harnessMode.ts`;
a build with `VITE_DO_AGENT_AWS_HARNESS=off` turns it off). It hides vibe-kanban's community and remote-service entry
points: the app bar's "Star on GitHub" and "Join our Discord" links, its Remote section's "Pair a remote device", and
the "Give Feedback" action. The settings dialog's Machine Settings, and the fourth patch's way to the runner, stay.

The seventh patch is ours: a goal card can keep its full instructions out of the way. The goals file's projection
writes a card's description as a concise summary, then a line that is exactly `## Full instructions`, then the full
instructions. The card panel splits at the first such line: it shows the summary (through the app's markdown
preview) with a "Show full instructions" toggle. Showing them, or clicking the summary to edit, opens the whole
description in the editor, so an edit always saves the full text. A description without that line is the editor, as
before.

The eighth patch is ours: the board's live sync stops starving its own requests. Every live Electric shape holds a
long-poll open, and on HTTP/1.1 a browser opens at most six connections to one host, so with six live shapes the
page's other requests waited for one to end: a comment's POST took 20 s to reach the server, and a 120 s access token
could expire meanwhile. The patch reads `<meta name="harness-sync-origin" content="//host[:port]">`, which the home
proxy puts on the board's pages (`kanban-sync.localhost` on the home port), and sends the shapes' live requests there,
so the long-polls fill that host's connections and never the board's own
(`packages/web-core/src/shared/lib/electric/syncOrigin.ts`). A shape's first and catch-up requests answer at once and
stay on the board's origin, so a card's comments still load at once. Without the meta nothing changes. A network
error on the second origin is retried there twice, after 0.5 s and 1 s; a third failure is the shape's own: the app
switches that shape to its fallback, short reads on the board's origin every 30 s, for the rest of the page's life
(a reload tries live sync again), so a network error never moves a long-poll onto the board's own connections.
An answer without the Electric headers leaves the second origin for good, and the long-polls go back to the board's
origin. A comment's text stays in the box, with "Saving...", until the server has it; when it is not saved an error says so
and the text is still there to send again. While any write is in flight, leaving the page asks first. The server's
access token lasts 15 minutes instead of 120 s.

The relay's patch (`patches-relay/0101`, applied only with `UI_KANBAN_RELAY=true`, docs/manual/boards.md "Kanban board") is ours:
with the relay on, the harness runs vibe-kanban's relay server and the agent runner registers with it as the board's
host, so the app bar's "Pair a remote device", which the sixth patch hides, is shown again (for a signed-in user, as
upstream shows it). The community links stay hidden. It changes that one condition in
`packages/remote-web/src/app/layout/RemoteAppShell.tsx` and nothing else.

`./kanban.sh build` applies `patches/*.patch` in name order (with the relay on, `patches-relay/*.patch` after them),
each after a `git apply --check`, and fails the build if
one does not apply, if `ProjectSunsetPage` is still referenced afterwards, if the project pages still show the
banner, or if the board's strings and the key prefix are not the Goals board's; `./test-kanban.sh bundle` then
checks the built image's static bundle (sunset copy absent, restored-board code present, the English strings naming
the cards goals).

## Known limits

- **The agent runner's own calls.** The runner is vibe-kanban 0.1.44's prebuilt npm binary, whose frontend is compiled
  in: its PostHog key, the Google Fonts stylesheet and the GitHub-star and Discord counts. Its analytics are off in the
  harness's first-start settings, and the home proxy's Content-Security-Policy refuses those calls in the browser, so
  none leaves; removing them from the runner would mean building it from source, which this harness does not.
- **Link pull request** does nothing on this board: the dialog calls the runner's local API (`/api/repos/pr-info`,
  `/api/remote/pull-requests/link`), which the self-hosted board server does not serve. A GET there answers the
  board app's page (the SPA fallback) and the POST 405. Put a pull request's link in the goal's description or a
  comment instead.

## No telemetry

The build passes none of the Dockerfile's telemetry arguments, so they keep their empty defaults: the server's
`SENTRY_DSN_REMOTE` (`crates/utils/src/sentry.rs` initializes Sentry only for a non-empty DSN) and `POSTHOG_API_KEY` /
`POSTHOG_API_ENDPOINT` (the server logs "PostHog analytics not configured" at start). The frontend build gets no
PostHog key either, and `packages/remote-web` has no Sentry. `./test-kanban.sh bundle` fails if a Sentry DSN ingest
host or a PostHog project key is compiled into the static bundle - the npm runner's prebuilt 0.1.44 binary has both.
The calls the shared frontend code makes regardless (Google Fonts, the GitHub star and Discord online counts) are
refused in the browser by the home proxy's Content-Security-Policy (docs/manual/boards.md "Kanban board").

## Provenance

Everything here derives from the public upstream repository:

- `patches/0001-restore-project-kanban-board.patch` is byte for byte the upstream diff of the one file between the
  pinned release and the commit before the sunset (`c768ce21e28807c4a7c7665244538a6af08c2e3c`, the parent of
  `97123d5262091deca5e4eba7167164e21329db36`, PR #3387 "Sunset project routes to export-only page"):

  ```
  git diff 4deb7eca8 c768ce21 -- packages/web-core/src/pages/kanban/ProjectKanban.tsx
  ```

  It takes the file's blob `432810090aa91a4ac5895f13af9a192f6f14ffe8` (v0.1.44, the sunset stub) to
  `ecac85e03800e059810eba2131744e62b37d1862` (the board component). To re-derive it: in a clone of the upstream
  repository, `git fetch origin c768ce21e28807c4a7c7665244538a6af08c2e3c`, run the diff above and compare it with the
  vendored file (`cmp`); the sha256 is in the table above.
- `patches/0002-self-hosted-board-no-cloud-shutdown-banner.patch` is written here, against the pinned release (one
  hunk, `git diff` of the edited file in a checkout of `4deb7eca8`).
- `patches/0003-goals-board-goal-noun-keys-and-new-goal-note.patch` is written here, against the pinned release with
  0001 and 0002 applied (`git diff` of the edited files).
- `patches/0004-goals-board-bounded-host-lookup-runner-settings.patch` is written here, against the pinned release with
  0001 to 0003 applied (`git diff` of the edited files).
- `patches/0005-goals-board-no-web-fonts-or-community-counts.patch` is written here, against the pinned release with
  0001 to 0004 applied (`git diff` of the edited files).
- `patches/0006-goals-board-harness-mode-hides-community-and-pairing.patch` is written here, against the pinned
  release with 0001 to 0005 applied (`git diff` of the edited and added files).
- `patches/0007-goals-board-full-instructions-disclosure.patch` is written here, against the pinned release with 0001
  to 0006 applied (`git diff` of the edited and added files).
- `patches-relay/0101-goals-board-relay-pair-host.patch` is written here, against the pinned release with 0001 to
  0008 applied (`git diff` of the edited file).
- the relay server: upstream's `crates/relay-tunnel/Dockerfile`, unchanged, on the same checkout; its settings
  (`wd/kanban/relay.env`: the board database's URL, the listen address and the board server's token secret) and its
  health check follow upstream's `crates/remote/docker-compose.yml` at the pinned commit, its relay profile.
- the build: the upstream `crates/remote/Dockerfile`, unchanged, run by `docker image build` (a plain image build
  needs no ssh-agent: the Dockerfile's `--mount=type=ssh` serves only the private billing crate, which it strips
  when `FEATURES` is empty). Each image its `FROM` lines name comes from ECR Public by digest (`KANBAN_BUILD_BASES`,
  passed as `--build-context <name>=docker-image://<image>@sha256:...`), and its `# syntax=` frontend by digest
  (`KANBAN_BUILD_SYNTAX`, `--build-arg BUILDKIT_SYNTAX`); a base image without a pin fails the build (`kanban.sh`
  `base_args`), and the image's `do-agent-aws.kanban.bases.sha256` label records the pins (`test-kanban.sh bundle` 11).
- the sidecar settings: upstream's `crates/remote/docker-compose.yml` at the pinned commit (the same images at the
  same versions, pinned by digest, the database's from ECR Public; the same environment, start order and health checks), with Electric on `restart: unless-stopped` like the other two and no
  sidecar publishing a host port.
- the REST calls in `Container-Root/agent/kanban-sync.py` and `kanban-signin.py`: the upstream server's routes and
  types at the pinned commit (`crates/remote/src/routes`, `crates/api-types`); the board app keeps its session in
  IndexedDB `rf-auth` (`packages/remote-web/src/shared/lib/auth.ts`).
