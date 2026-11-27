# The harness UIs

The home page, its reverse proxy and every UI behind it. Part of the [Do Agent on AWS manual](README.md).

Contents:

- [Harness UIs](#harness-uis)
- [Home page and reverse proxy](#home-page-and-reverse-proxy)
  - [Telemetry](#telemetry)
  - [tmux in the browser](#tmux-in-the-browser)
  - [Agent chat](#agent-chat)
  - [Starter repository](#starter-repository)
  - [tmux-agent dashboard](#tmux-agent-dashboard)
  - [Agent loop page](#agent-loop-page)
- [Files](#files)

## Harness UIs

The container packages the web UIs used to observe and drive the agent harness, and they are all
enabled by default (`UI_START=true` in `.env`, per-UI flags `UI_HEADLAMP`, `UI_HINDSIGHT`,
`UI_VIBE_KANBAN`, `UI_TMUX`, `UI_HOME`). When `UI_START` is `false` the harness UI stack is
completely off - no UI process runs, no proxy, no UI port is published - and the container behaves
exactly as it did before the UIs existed. By default the UIs are served **through one single
published port** - the home page + reverse proxy described in
"Home page and reverse proxy" below - so there is exactly one `-p 127.0.0.1:8000:8000` in the
docker run command and one port on the kubernetes service.

| UI | Purpose | Route through the home port | In-container port | Source |
|----|---------|------------------------------|-------------------|--------|
| Home page + proxy | lists every UI, proxies all of them | `/` | 8000 | nginx (apt `nginx-core`) |
| Headlamp | Kubernetes dashboard - the cluster the agent operates on | `/headlamp/` | 4466 | official image `ghcr.io/headlamp-k8s/headlamp` (server + frontend extracted with crane) |
| (Memory API docs, linked from the Memory tile) | agent memory HTTP API with interactive `/docs` explorer | `/memory-api/docs` | 8888 | `hindsight-api` (PyPI) |
| Memory (Hindsight UI) | the agent's long-term memory - banks, memories, operations | `http://hindsight.localhost:8000/` | 9999 | official image `ghcr.io/vectorize-io/hindsight-control-plane` (extracted with crane) |
| Goals board | the agent's goals as cards, moved by its autonomy loop (vibe-kanban; see "Kanban board") | `http://kanban.localhost:8000/` | - (its own container) | vibe-kanban 0.1.44 server built from source with the board restored, plus Electric and Postgres, as three sidecar containers |
| Agent workspaces (vibe-kanban) | coding agents on a repository, each in its own git worktree (the vibe-kanban runner's workspaces) | `http://vk-runner.localhost:8000/workspaces` | 8081 | `vibe-kanban` (npm) |
| tmux terminal | live browser terminal attached to the agent tmux session | `/tmux/` | 7681 | `ttyd` (apt; pinned upstream release as fallback) |
| tmux cheatsheet | static tmux reference for the shared agent session | `/tmux-help/` | - (static page, served by the home listener) | rendered by `home-render.sh`; every key on it verified against the image's tmux by `test13.sh` |
| Guide | the user guide - the 5-minute tour, goals and the board, agent workspaces, memory, learning, troubleshooting | `/guide/` | - (static page, served by the home listener) | `docs/user-guide.md`, rendered at every start by `home-render.sh` with `/agent/md2html.py` (no third-party module); this README is served the same way at `/guide/readme/`, where the home page's footer links point (the repository is private, so a GitHub link is a 404 for most users); `test16.sh` checks both pages |
| Agent chat | talk to the agent without Slack: the agent session's screen and a box that types a message at its prompt (see "Agent chat") | `http://chat.localhost:8000/` | 8094 | `/agent/agent-chat.py` (python3 standard library, in the image already) |
| Comms UI | communication channels dashboard (see "Comms UI") | `/comms/` | 8502 | communication-engine (pinned sha) |
| tmux-agent dashboard | fleet tree, history and waste of tmux-run agents (see "tmux-agent dashboard") | `/tmux-agent/` | 7337 | vendored prebuilt dashboard in the image (`Container-Root/opt/tmux-agent`, Apache-2.0 with LICENSE and NOTICE; `VENDORED.md` names the upstream commit); set `TMUX_AGENT_SRC` to build another source instead |
| Session memory (claude-mem viewer) | the claude-mem session memory: observations, summaries, the context the agent gets back after compaction | `http://claude-mem.localhost:8000/` | 37700 | the claude-mem plugin's own worker (Bun), already installed for the agent's hooks |
| Session insights (LogLearner dashboard) | read-only browser over the agent's own Claude Code sessions: projects, transcripts with gap evidence, the Learnings tab (seeded with the starter rules), Hindsight panel; `/api/tile.json` status | `http://loglearner.localhost:8000/` | 7777 | the gated minimal runtime of `dmvevents/loglearning` (`Container-Root/opt/loglearner`, MIT; `VENDORED.md` names the artifact and its scrub report); indexes `/home/agent/.claude/projects` into `/wd/loglearner/index.db` incrementally and never prunes a session whose file is gone - remove that file once to rebuild the index at the next start (a checkout whose earlier test runs were indexed into it keeps listing those test projects until then) |
| Learned rules | the LogLearner knowledge bank the agent learns from: rules, bank files, deliveries into its sessions (see "Agent learning tools"); red with the reason when degraded | `http://loglearner.localhost:8000/learnings` (tile numbers from `/__tile/metalearner`) | 7777 | the LogLearner dashboard's `/api/tile.json` |
| Project board (Plane) | **opt-in, off by default** (`UI_PLANE=true` in `.env.local` turns it on; Plane is AGPL-3.0 - see "Plane board"): project-management board, the agent's goals as work items, moved by its autonomy loop, and the work it tracks there without firing on it; the tile signs you in; off, there is no tile | `http://plane.localhost:8000/` | - (its own containers) | Plane community `makeplane/*:v1.4.2` and its datastores, as twelve sidecar containers (docker target), pulled only with `UI_PLANE=true` |
| Board | read-only kanban view of the agent's goals: the Plane project's columns and cards, each with the agent runner's attempts on it (see "Board"); only with the Plane board on - off, there is no tile | `http://board.localhost:8000/` | 8096 | `/agent/board-server.py` (stdlib python; reads Plane and the runner, writes nothing) |
| Files | the shared folder between you and the agent: download what the agent produced for you, upload files for it to read, folders, rename, move and delete - every change that removes or replaces something asks first (see "Files") | `http://files.localhost:8000/` | 8098 | `/agent/files-server.py` (stdlib python; serves `/wd/files` and nothing outside it; nothing is executed) |
| Agent loop | the autonomy loop at a glance: state and health, fires with their transcripts, goals, what needs attention, the fleet it runs in (see "Agent loop page") | `http://loop.localhost:8000/` | 7790 | `/agent/loop-view.py` (python3, stdlib only), read-only over the loop's state files but for Run next fire and Pause loop (the loop's own start and stop scripts) |
| Loop Deck | the fleet's loop observability console (fire timelines, breakers, history, runbook) over this harness's own loops - the Deck release shipped in the image (`/opt/loop-deck`, see its `VENDORED.md`) in harness mode, rendered from `/wd/loop-deck`, which `/agent/loop-deck-adapter.py` writes at UI start and after every fire; actions off (every `POST /act` answers 403); `LOOP_DECK_URL` in `.env.local` links a fleet Deck instead: a plain `http(s)://host[:port][/path]` URL as your browser reaches it (any other value is refused with a WARNING when `.env` is read and passed empty, so the served tile stays) | `loop-deck.localhost` | `UI_LOOP_DECK=true` | `/opt/loop-deck` (vendored) |

Inside the container the UIs are managed with `/agent/ui-start.sh`, `/agent/ui-stop.sh`, and
`/agent/ui-status.sh` (logs and pidfiles under `/wd/ui/`, so they survive restarts; `ui-status.sh` reports a
UI as up only when it actually answers HTTP on its port). Headlamp picks up `KUBECONFIG`,
`/home/agent/.kube/config`, or in-cluster credentials, whichever is present. **Cluster access is the container's,
not Headlamp's:** `run.sh` mounts `~/.aws` and `~/.kube` when they exist, and on EC2 the instance role arrives
through IMDS, so Headlamp and the agent act on a cluster with whatever that role allows - an instance role with
`AdministratorAccess` lets the agent create, change and delete anything in the account and the cluster. For a
cluster the agent should only watch, give the container a scoped role instead: an IAM policy that allows
`eks:DescribeCluster` and `eks:ListClusters` (what `aws eks update-kubeconfig` and Headlamp's cluster list need) and
nothing else, and in the cluster an EKS access entry (or an `aws-auth` mapping) that binds that role to the
read-only `view` ClusterRole - then `kubectl get` works and every write is refused, in Headlamp and in the agent's
terminal alike. Add a cluster from the terminal with `aws eks update-kubeconfig --name <cluster> --region <region>`
(`/agent/doctor.sh --check eks` prints the lines, the access entry included; install.md "Setup doctor"). With the
host's `~/.kube` mounted, run it on the host: the kubeconfig is yours, and it makes the new context the current one.
Headlamp
picks the new context up without a restart: it re-reads `~/.kube/config` every ten seconds, also when the file did
not exist when it started. The hindsight server defaults to the
`bedrock` LLM provider so it runs on the same AWS credentials as the rest of the container; export
`HINDSIGHT_API_LLM_PROVIDER` / `HINDSIGHT_API_LLM_API_KEY` / `HINDSIGHT_API_LLM_MODEL` on the host to use
another provider, and `HINDSIGHT_API_LLM_OUTPUT_LANGUAGE` for memories in a language other than English (`run.sh` passes
them through only when set - no secrets in `.env`).

The per-UI direct ports can still be published on loopback for debugging (the pre-home behavior):
set `UI_PUBLISH_DIRECT_PORTS=true`, or set `UI_HOME=false` to run without the proxy exactly as
before this feature. Every tile above but the Project board (Plane) and the Board is on by default (`UI_CLAUDE_MEM`,
`UI_LOGLEARNER`, `UI_TMUX_AGENT`, `UI_CHAT` and `UI_LOOP` join the per-UI flags); the Plane board is opt-in (`UI_PLANE=true`;
Plane is AGPL-3.0 - see "Plane board") and the Board comes with it. `test16.sh` proves that every enabled tile on the rendered
home page answers through the proxy. Included: the Loop Deck release itself (`/opt/loop-deck`, harness mode over `/wd/loop-deck`; `LOOP_DECK_URL`
links a fleet Deck instead). Plane, a multi-service stack (postgres, valkey, rabbitmq, an object store, workers, frontends) that does not
fit in the agent container, runs beside it as sidecar containers when switched on - see "Plane board".

vibe-kanban 0.1.44 runs Claude Code as `npx -y @anthropic-ai/claude-code@<its pin>` (2.1.119), a copy fetched at the
first agent start, with `--dangerously-skip-permissions`. That copy runs only because the image's npm allows the
package's install scripts (`setup/harden.sh`). When vibe-kanban has no agent settings yet (no `profiles.json` beside its
configuration in `/home/agent/.local/share/vibe-kanban`), `ui-start.sh` gives it this image's
(`Container-Root/agent/vibe-kanban-profiles.json`): Claude Code's base command is `claude`, the image's own Claude
Code with its Bedrock settings, and "Dangerously Skip Permissions" is off. Both are in vibe-kanban's Settings, Agents,
Claude Code, where you can change them; agent settings that exist are never changed. vibe-kanban finds `npx` on its
PATH because the image links `npm` and `npx` beside `node` in `/usr/local/bin`; `test20.sh` proves both.

The browser terminal is writable by default. ttyd's flag for that differs by version (1.6.x is writable
unless `-R`, 1.7 and later read-only unless `-W`), so `ui-start.sh` asks the installed binary (`ttyd
--help`) which flag it has rather than parsing a version string; `test9.sh` check 7 plants a keystroke
through the proxied websocket and proves it reaches the tmux pane.

## Home page and reverse proxy

`http://localhost:8000` is the front door of the whole harness: a dependency-free home page (it
renders offline, no CDN assets) with one tile per UI - purpose, a link that opens in a new tab, and a
live up/down dot probed from the browser - plus an nginx reverse proxy that carries every enabled UI
through that same single port. The dots read a real status: path tiles are probed at their path and
host-routed tiles at a same-origin `/__probe/<name>` location on the home listener (a cross-origin
fetch of `hindsight.localhost` can only be made no-cors, and that resolves for a 502 as happily as for a
200 - a dead memory UI used to stay green); `test16.sh` kills an upstream and proves its dot probe reads
down. Each dot is probed when the page loads and every 15 s; a failed probe is tried again after
10 s, with one retry pending per tile at a time, and the dot reads "starting" until its sixth failure
in a row, then "down". A dot's probe, and the Learned rules tile's read of its numbers, give up after
8 s and count as a failure, so a dot whose UI hangs holds one of the browser's few connections to the
home port for 8 s at most. `test-home-probe.sh` runs the page's own probe script, as served, under
simulated time and proves the probes stay bounded while a UI is down, rate-limited or never answers.
Disabled UIs are listed greyed with the `.env` flag that enables them, and every
UI the page links to carries a small floating "⌂ home" badge so navigating between the
capabilities is one click: injected into every proxied page (the API docs and the ttyd terminal
included) and part of the static pages. On the hostname-served UIs (`hindsight.localhost`, `kanban.localhost`, `vk-runner.localhost`)
the badge returns to `localhost:<the port you are on>`, so it lands on the home page through any
tunnel or port-forward port; under 481 px it sits at the bottom left, where a UI wider than a phone cannot push
it off-screen; and it targets the home page's own tab (the page names it `do-agent-aws-home`, and tiles open
their UI with `rel=opener` so the badge can reach it), so it returns to the home tab already open instead of
opening another. `test-home-badge.sh` proves the injected bytes are in every route's page. Only one port needs mapping or exposing:

* docker: `./run.sh` publishes `127.0.0.1:8000:8000` and nothing else; from your machine open an
  SSH tunnel `ssh -L 8000:localhost:8000 user@host` and browse `http://localhost:8000`
* compose: the template publishes the same single loopback port
* kubernetes: the service exposes only port 8000; `kubectl -n <namespace> port-forward
  svc/do-agent-aws 8000:8000` then browse `http://localhost:8000`

The default port is 8000 (`PORT_INTERNAL_HOME` / `PORT_EXTERNAL_HOME` in `.env`); nothing else
in the image uses it. Should it collide with another app on your host, change the external side
only - the home page and its links follow whatever port the browser is on, and the header's tunnel hint names
that port (`PORT_EXTERNAL_HOME` is passed into the container for it).

Every page the harness builds itself - the home page, the tmux cheatsheet - and the floating badge draw their look
from one stylesheet, `/__harness/harness.css`, which the proxy serves on every host it answers: the tokens, the
components, light and dark, the rules (a state is a word with a shape, never a colour alone; no hardcoded colour
outside the sheet) and the five lines that adopt it in a new page are in [docs/UI-STYLE.md](../UI-STYLE.md);
`test-ui-style.sh` proves each rule.

The page opens with a **Start here** strip - one sentence on how to give the agent a goal and one primary action: the
Goals board, signed in, when a board is configured, or the Guide's goals section without one - and groups the tiles by
the user's task: **Get started** (the Guide), **Run and review** (the boards, the workspaces, the conversations),
**Memory and learning**, **Administration** (the cluster, the terminal, the dashboards). A tile is placed by its name, so a
new tile no group names lands under **Other** rather than nowhere; `test16.sh` check 2 asserts the strip, the groups and
their order, with a planted tile and a planted strip-less page as its controls.

The trust boundary is unchanged: everything binds the host on `127.0.0.1` only (`UI_BIND_HOST`) and
the SSH tunnel / port-forward is the access path - the proxy adds no authentication and must never
be published on a public interface. The home listener answers loopback host names only (`localhost`,
`127.0.0.1`, `[::1]`, plus `UI_HOME_HOSTNAMES` in `.env` for a name you reach it under on purpose) and
refuses any other `Host` with 421, so a DNS-rebinding page cannot reach the writable terminal or the
memory API through the proxy; the status-dot probes are GET-only, status-only subrequests that carry no
cookies to the upstream and no upstream body to the page (`test16.sh` check 7 proves both). Inside the
container, every UI behind the proxy binds `127.0.0.1` (ui-start.sh `UI_BACKEND_LISTEN_HOST`; before, they
listened on all interfaces and any NEIGHBOUR container on the same docker network could drive the writable
terminal or write memories), and the home listener itself admits only loopback, the container's default-route gateway
read from the routing table (IPv4; where Docker's published-port forward arrives from - the default bridge's, or a
sidecar stack's user-defined network's; never an address guessed from a subnet) and `UI_HOME_ALLOW_FROM` in `.env`,
answering 403 to any other source. A network connected to the running container moves the default route;
`/agent/home-route-watch.sh` re-renders the config and reloads nginx within seconds, so the host's published
port keeps answering (`test16.sh` check 8 connects from the container's own non-loopback address and is
refused, then allowed once that address is listed). With `UI_HOME=false` or `UI_PUBLISH_DIRECT_PORTS=true`
the backends bind the container's interfaces again, for the direct publishes. On kubernetes the pod network
is the neighbourhood: `kubectl port-forward` enters through loopback and works unchanged, an Ingress
controller needs its source range in `UI_HOME_ALLOW_FROM`, and a `NetworkPolicy` that denies ingress to the
pod except from the controller is the matching cluster-side rule. The Ingress and the HorizontalPodAutoscaler are not
applied unless you opt in (`KUBERNETES_INGRESS=true`, `KUBERNETES_HPA=true` in `.env.local`; `test-kubernetes.sh`): the
Ingress routes plain HTTP to the home proxy with no authentication in front, so turn it on only behind an
authenticating front end.

Routing per UI: apps with native base-path support are served under a path prefix (headlamp
`-base-url /headlamp`, streamlit `--server.baseUrlPath comms`, ttyd `-b /tmux`, hindsight-api under
`/memory-api/`, tmux-agent under `/tmux-agent/` with its `/api/` paths rewritten). Hindsight UI,
the kanban board, the vibe-kanban agent runner, the claude-mem viewer and the LogLearner dashboard have no runtime
base-path support (root-absolute links, build-time prefixes at best), so the proxy serves them on their own
hostnames `hindsight.localhost`, `kanban.localhost`, `vk-runner.localhost`, `claude-mem.localhost` and
`loglearner.localhost` - RFC 6761
reserves `*.localhost` to resolve to loopback, browsers do this without any setup, and both the SSH
tunnel and `kubectl port-forward` preserve the Host header the proxy routes on. The Agent chat page is on
`chat.localhost` for another reason: its write accepts a message only from its own origin, and a hostname of
its own gives it one (see "Agent chat"). The home page links point at the right place either way.

The API docs page (`/memory-api/docs`, FastAPI's Swagger UI) would load swagger-ui from the jsdelivr CDN and its
icon from fastapi.tiangolo.com; the proxy rewrites both to a pinned copy in the image (swagger-ui-dist,
Apache-2.0, fetched and checksum-verified at build by `setup/install-swagger-ui.sh`, served read-only at
`/memory-api/__swagger/`), and the `/memory-api/` routes carry a Content-Security-Policy that allows their own
origin only, so the page renders offline and requests nothing beyond the loopback port. `test-docs-assets.sh`
proves it on FastAPI's real page, with the rewrite removed as its failing control.

The LogLearner dashboard route (`loglearner.localhost`) carries a Content-Security-Policy under which only the
dashboard's own scripts run: each inline script and event handler of the vendored release by its sha256 (read from the
release's source by `/agent/loglearner-csp.py`), its one CDN script by URL, and the home badge. The release's search page
puts transcript snippets into the page without escaping them (reported upstream); under the policy a script or a handler
inside a transcript does not run, and the page can load from and send to its own origin only. `test-loglearner-csp.sh`
plants both in a transcript and checks the served pages against the policy.

The proxy is managed like every other UI: `setup/install-nginx.sh` installs nginx at build time,
`/agent/home-render.sh` renders `/wd/ui/home/nginx.conf` and the home page from the UI enable
flags on every `ui-start.sh` run (a disabled UI has no route at all), and `ui-status.sh` /
`ui-stop.sh` cover the `home` entry. `test9.sh` proves the contract: exactly one published port by
default, every enabled route answers through it, a stopped UI reports down (no false green), and
`UI_START=false` publishes nothing.

### Telemetry

Nothing in the container reports home by default. The browser's Content-Security-Policy on every proxied UI stops
the pages' third-party calls (analytics, error reporting, fonts, star counts), and for the server side
`/agent/telemetry-off.sh`, sourced by `startup.sh` before anything starts, exports `DO_NOT_TRACK=1` (the cross-tool
convention npm, the Claude Code CLI and many node tools honour) and `GH_NO_UPDATE_NOTIFIER=1` (gh's update check), so
every process the container starts inherits them. A tool with a switch of its own is set beside its install.
`/test-telemetry-off.sh` proves the two variables and their place in the start.

### tmux in the browser

There is **one shared tmux session, `agent`, and both doors land in it**. The session is created
at container start (`/agent/tmux-session-start.sh`, called from `startup.sh` - so `tmux ls` finds
it immediately, browser or not, UIs or not) with the interactive claude CLI already running in its
pane and ready to accept prompts (`/agent/tmux-claude.sh`):

* browser: the `tmux` tile (`/tmux/`) is a live terminal - ttyd attaches to that session. The page URL can name
  another session of the container instead: `/tmux/?arg=<session>` attaches to that one (its exact name), and
  `/tmux/?arg=pick` (the tile's "choose a session" link) shows the numbered list of the container's tmux sessions
  to choose from. A name that does not exist, or anything that is not a plain session name, shows the same list
  and says why. Only the container's own tmux server is listed or attached - no argument can choose a socket, a
  server or a path - and `UI_TMUX_WRITABLE` still decides whether the terminal takes keys
* shell: `docker exec -it do-agent-aws bash` (or `./exec.sh`) prints the banner and lands in that
  same session; detaching (`Ctrl-b d`) returns to a plain in-container shell instead of ending the
  exec, and `docker exec -e TMUX_AUTO_ATTACH=false -it do-agent-aws bash` is the escape hatch when
  you want a plain shell from the start (kubernetes: `kubectl exec -it <pod> -- env
  TMUX_AUTO_ATTACH=false bash`); `./exec.sh -s` (or `--shell`) is that same escape hatch as a
  flag, on every orchestrator target, and `./exec.sh -h` displays usage. Scripted execs
  (`docker exec do-agent-aws <command>`) are never touched - only interactive shells with a
  terminal attach.

On a fresh agent state the pane opens at claude's prompt: Claude Code's first-run answers (onboarding done, a
theme, the pane's folder `/wd` trusted) are seeded into its `.claude.json` at build and at every start
(`/agent/claude-onboarding.py`, only where missing), where it otherwise stopped at the theme picker, the security
notes and the trust dialog, and three Enters exited claude to the bare shell. claude runs as the pane's
foreground process (its own process group), so tmux and the tmux-agent dashboard see it as claude.
`test-agent-terminal.sh` proves both with A/B controls. When claude exits (e.g. `/exit`) the pane falls back to
a shell and the session survives - type `claude` to start it again. The flags live in `.env`: `AGENT_TMUX_SESSION` (create the session at
startup; `false` switches the whole feature off), `AGENT_TMUX_SESSION_NAME`, `AGENT_TMUX_CLAUDE`
(run claude in the pane), `AGENT_TMUX_CLAUDE_OPTS`, and `TMUX_AUTO_ATTACH`. `test12.sh` proves the
contract: the session exists eagerly before any client connects, the pane runs claude (and a
planted `AGENT_TMUX_CLAUDE=false` control does not), an interactive pty shell attaches while
`TMUX_AUTO_ATTACH=false` and scripted execs do not, and re-running the session starter is
idempotent.

The browser terminal is **writable by default**: keystrokes typed in the browser reach the
`agent` session, so you can drive the agent live from the page (`test9.sh` proves a planted
keystroke lands in the pane, and that a read-only twin refuses the same probe). The trust
boundary is unchanged - the port is published on loopback only and the SSH tunnel / port-forward
is the access path. For a watch-only terminal, set `UI_TMUX_WRITABLE=false` in `.env.local` and
restart - the tile says which mode it is in.

The `tmux cheatsheet` tile (`/tmux-help/`) is a static reference for operators who are new to
tmux: the prefix key, detach/re-attach, windows, panes, and scrollback/copy - plus the
harness-specific facts (the shared `agent` session, what read-only mode means, how to scroll in
the browser terminal). It is rendered by `home-render.sh` next to the home page and served by the
same listener, so it needs no process and no route of its own. Everything on it is true of this
image: each documented key carries a `data-tmux` marker and `test13.sh` verifies every marker
against a live `tmux list-keys` / `show-options`, so a page edit that documents a key this tmux
does not have fails the test suite (`./test.sh`).

The terminal renders the same inside tmux as in a plain container shell: the Dockerfile sets
`LANG=C.UTF-8` because tmux, at draw time, downgrades a pane's non-ASCII cells for any attached
client whose locale is not UTF-8 - line-art becomes DEC ACS escapes and everything else (the
Claude CLI's rounded corners, check marks, block logo) becomes underscores. With no locale in the
image both doors into the session (the browser terminal's ttyd client and a `tmux attach` from
`exec.sh`) degraded exactly that way while the tmux-less shell looked fine. `test13.sh` proves the
parity with a byte-level probe - and that a locale-stripped client still degrades, so the check
fails if the `ENV LANG` is ever dropped.

### Agent chat

The `Agent chat` tile (`http://chat.localhost:8000/`, in-container port 8094) is the way to talk to the agent
without Slack: a page that shows the shared `agent` session's screen - the same pane the browser terminal shows,
refreshed every two seconds - with a send box under it. A message typed there is typed at the agent's prompt as
literal keystrokes and submitted with Enter, and the page says so: "Sent to the session at <time> (<n> characters
typed at the prompt and submitted)". That line is the transport and nothing more. Whether the agent read the
message, what it did with it and what it answered is on the screen above, where it would be for a person at the
terminal. The page is served by `/agent/agent-chat.py` (python3's standard library; `ui-start.sh`, `ui-stop.sh` and
`ui-status.sh` manage it as `agent-chat`) and routed by the home proxy on its own hostname.

The write is deliberately narrow, narrower than the terminal's keyboard:

* it accepts a POST from the page's own origin only (`http://chat.localhost` on the port the browser is on, read
  from the request's Origin or, failing that, its Referer; another origin, `null`, another port or neither header
  is 403), answers no CORS header, forbids framing, and every route but its health path refuses a Host that is not
  `chat.localhost`, so a page on another site, or one that rebinds its own name to loopback, can neither read the
  screen nor type;
* the message is capped at 4000 characters, every control character in it (newlines, tabs, escape sequences)
  becomes a space, and it never meets a shell: tmux is called with an argument list, the message one argument
  (`send-keys -l --`, so tmux reads no key name and no option out of it), then Enter as a keystroke of its own.
  The one tmux rule that applies to that argument - a trailing `;` would be read as a command separator - is
  handled: a message ending in `;` is handed over with that character escaped and arrives exactly;
* sends are serialized (one lock around the whole check, text, check, Enter sequence; the page sends one message at
  a time), so two messages at once arrive as two lines, each with its own Enter;
* it types only while the pane's foreground command is the agent CLI (`claude`; `AGENT_CHAT_COMMANDS` names
  others). A pane that runs a shell, or whose session is missing, is refused with the reason, and the page says
  so instead of showing a send box that works. This compares the foreground process's name: it is a guard against
  typing into the wrong program, not authentication. The session's wrapper (`/agent/tmux-claude.sh`) runs the agent
  CLI under job control, in its own process group, so the harness's own agent pane reports `claude` and qualifies;
* it types only at the agent's **prompt**. When the agent shows a menu instead - an approval ("Do you want to
  proceed?" with numbered choices), a question with options, a selection list - a message is refused, naming the
  menu, because a menu reads keys: the letters are ignored and the Enter would pick the highlighted choice, an
  approval nobody gave. The page shows the menu's text (the command to approve, the question) and, for numbered
  choices, one button per option; a button presses that option's number in the session, exactly as the key would
  in the terminal, and nothing else (Enter follows only if the menu is still up with that option highlighted, which
  Claude Code's menus never are: the digit answers). A checkbox list has no number to press and is answered in the
  terminal. The button names the menu it was shown (its question and options); a menu that changed meanwhile is
  refused. The prompt and a menu are read from the pane's text as Claude Code draws them (the prompt a `❯` line
  between two rules, a menu's highlighted item `❯ 1. ...` or `❯ [✔] ...`); when the pane runs `claude` and shows
  neither - it is starting, or a dialog without a cursor is up - a message is refused too, saying so. The pane is
  read again between the text and the Enter: a menu that opened meanwhile leaves the text waiting at the prompt,
  unsubmitted, and the page says so;
* `UI_TMUX_WRITABLE` other than exactly `true` (a watch-only harness; the rule the terminal, the dashboard and the
  tile apply to the same flag) turns the send box off too: the page still shows the screen.

The agent CLI reads the message as typed input, so its own syntax applies: for Claude Code a message that starts with
`!` is its bash mode and one that starts with `/` a command, exactly as at the terminal - the page is as capable as the
terminal, behind the same boundary, and no more.

Every answer is `Cache-Control: no-store` and `X-Content-Type-Options: nosniff` with a Content-Security-Policy that
forbids framing - the answers the standard library writes itself (a method without a handler, too many header lines)
included - and never a CORS header. The one exception is the library's answer to a request line that names no HTTP
version: an HTTP/0.9 answer, which by protocol has no status line and no headers, only the library's error page as its
body. A body that does not arrive in 10 s is dropped, and a tmux that does not answer in 10 s is an error answer. The
page draws its look from the harness's shared stylesheet, which its route serves (`/__harness/harness.css`); the route
refuses to render on a tree without the harness design system, loudly, instead of serving an unstyled page.

Known limit: in the first seconds after the agent CLI starts, while its session-start hooks run, a message typed from
the page can stay in the CLI's input box unsubmitted - the text arrives, the Enter is swallowed by the starting CLI
(measured once: the keystrokes reached the pane, the CLI took the Enter as nothing). The page's acknowledgement is still
true, the screen shows the text waiting at the prompt, and the next Enter at the terminal, or the next message, submits
it. Wait for the prompt to settle before the first message of a fresh session (until the prompt is drawn, the page
refuses to type at all). `UI_CHAT=false` in `.env` removes the backend, the route and the tile's
link (the tile greys out naming the flag). `test-agent-chat.sh` proves each of these against a stub agent in a
test-local tmux server, each with a planted control: the pane's text served escaped (a copy without the escaping
serves `<script>` as markup), a literal send with `$(...)`, `;`, key names and control characters (a copy that
hands tmux a shell command line runs the `;` part), a foreign origin refused (a copy without the check types the
message), a shell pane refused (a copy without the check types into the shell), an approval menu on the pane refused
by name and answered with exactly one key (a copy without the gate types the message into the menu, and its Enter
answers "Yes"; a copy without the menu's key answers a menu the page never showed; a copy that always follows the key
with Enter answers the next menu too), the agent CLI's own screens read right (its approval dialog, a question with
options, a checkbox list, the prompt, a dialog without a cursor), the tile's dot following the
backend (stopped: the probe reads down), the start/status/stop rows, watch-only (every spelling but `true`), two
messages at once (a copy without the lock interleaves them), a message ending in `;` (a copy without the escape loses
it), the headers on every answer including the standard library's own (a copy that allows any origin fails), a body
that never arrives (dropped at the timeout) and a tmux that never answers (an error answer, not a hung request).

### Starter repository

A fresh install's workspace (`/wd`) holds no git repository, so the agent runner had nowhere to start: its Browse
opened on "No folders found", Create hung, Recent was empty. At every start `/agent/starter-repo.sh` looks at the
workspace - itself, one level under it, under `/wd/projects/` - and, when there is no repository at all, makes one at
`/wd/projects/scratch`: a README that says what it is for and where real repositories go, and one commit by the
operator's identity (`GIT_USER_NAME`, `GIT_USER_EMAIL`) when set, else the harness's own. It is idempotent, never
touches an existing repository, and `STARTER_REPO=false` in the environment opts out. Your own repositories go under
`/wd/projects/` (clone them there in the terminal). `/test-starter-repo.sh` proves it.

### tmux-agent dashboard

The `tmux-agent dashboard` tile (`/tmux-agent/`, in-container port 7337) is the tmux-agent dashboard
(`dmvevents/tmux-agent-public`, the public source of the tmux-agent dashboard, CLI and MCP server): the fleet tree, history and waste analytics of agents run in tmux sessions, with
the harness's own `agent` session in it. It is **on by default** (`UI_TMUX_AGENT=true` in `.env`) and needs
nothing from the network: the image carries a prebuilt copy of the dashboard at `/opt/tmux-agent`
(`Container-Root/opt/tmux-agent`: the compiled `dist/`, `package.json` and lockfile, and the `LICENSE` and
`NOTICE` the Apache-2.0 license requires; `VENDORED.md` names the upstream commit and `tools/vendor-tmux-agent.sh`
refreshes the copy from a clone). The dashboard's original repository is private and its source carries its
owner's private project notes, so a fresh user could not build it at container start - the previous design -
and only the scrubbed open-source tree is what ships here. `setup/install-tmux-agent-dashboard.sh`
installs the two runtime dependencies at image build (`npm ci --omit=dev`, from the public npm registry)
and fails the build if the dashboard does not run.

`ui-start.sh` serves the vendored build on `127.0.0.1:7337` inside the container - loopback only; the
home proxy is the exposure - with `--no-token` (the harness fronts every UI, the writable terminal
included, unauthenticated behind the loopback-published home port and the SSH tunnel, and the dashboard
rides that same boundary) and `--strict-port` (so a busy port fails loud instead of the dashboard scanning
forward while the proxy route points at nothing). With `UI_TMUX_WRITABLE=false` (a watch-only terminal) the
dashboard is started read-only as well (tmux-agent's own policy file, `surfaces.web.readOnly`), so its send
box answers 403. The dashboard has a CSRF/DNS-rebinding guard that refuses any `Host` or `Origin` that is
not its own loopback address, and a single-file UI that fetches root-absolute `/api/...` paths, so the proxy
route sends it its own address when the browser's `Host`/`Origin` is a loopback one (the headlamp pattern)
and rewrites those paths into `/tmux-agent/` (the hindsight-api pattern); any other `Host` or `Origin` (a
DNS-rebinding page, a cross-site request) still reaches the dashboard as sent and is refused. The dashboard
watches its own isolated tmux socket by default, while the harness's shared `agent` session lives on the
default tmux server, so the harness starts it in the dashboard's "adoption mode"
(`TMUX_AGENT_DEFAULT_SERVER=1`) and the `agent` session shows up in its fleet tree - classified, with a
context %: `tmux-session-start.sh` sets the session's lineage (`@agent_parent operator`, `@agent_owner`,
`@agent_task`, `@agent_role`, so it is not "orphaned") and pipes the pane into the dashboard's capture log
(`/wd/tmux-agent-home/logs/agent.log`, the dashboard's home on the `/wd` volume; 0600, at most 64 MiB a start),
the agent's status line (`/agent/claude-statusline.sh`) shows `ctx:N%`, and the harness lexicon
(`/agent/tmux-agent-lexicon.json`, passed as `TMUX_AGENT_LEXICON`) adds a profile that recognises the agent's
claude pane also when it is idle. `test-agent-terminal.sh` reads all of it back through the dashboard's own API. To watch a
`tmux-agent`-spawned fleet on another socket instead, set the dashboard's own `TMUX_AGENT_SOCKET` inside the
container (it is not passed through by `run.sh`) and restart the dashboard there
(`/agent/ui-stop.sh; /agent/ui-start.sh`).

**The default source.** `TMUX_AGENT_SRC` is empty by default: the dashboard is the copy vendored in the image
(`/opt/tmux-agent`, built from its lockfile, `VENDORED.md`), and nothing is fetched or built at start. Set it in
`.env.local` - for the upstream repository `https://github.com/dmvevents/tmux-agent-public.git`, at the commit
`TMUX_AGENT_REF` pins - to build that source at the container's first start instead (that start needs `github.com`
and `registry.npmjs.org`). A token URL is never
written to `.env` (test14 refuses it): export it in the host shell before `./run.sh` and the bare
`-e TMUX_AGENT_SRC` passes it through like `SLACK_BOT_TOKEN`; compose resolves it the same way, kubernetes reads it
from the optional `do-agent-aws-tmux-agent` secret. With a source set the vendored copy is ignored: on the first start with it set,
`/agent/ui-start.sh` runs `/agent/install-tmux-agent.sh` - `git fetch` of `TMUX_AGENT_REF` (default `master`)
from that source (any form git accepts: https, ssh, a token URL, or a path visible inside the container such
as a clone under `/wd`), `npm ci` (or `npm install` without a lockfile), `npm run build` - into
`TMUX_AGENT_INSTALL_DIR` (default `/wd/ui/tmux-agent`, on the `/wd` volume, so later starts skip the build; under
`/wd/ui` with the other UIs' state, because the starter repository step and the agent runner's repository list take a
git repository directly under `/wd` for one of yours).
Its last step writes a stamp (the ref, the source with any credential masked, and the commit built), and a
start serves that build only when the stamp matches the current ref and source - a failed or interrupted
build is never served and is retried on the next start, a changed ref or source is re-built, a rotated
token is the same source. The installer never prints a token (credentials in any URL it echoes are
masked) and records no remote, so a token URL never lands in `.git/config` on the `/wd` volume. The install
log is `/wd/ui/tmux-agent-install.log`; `ui-status.sh` names the source setting while there is no finished
build. Inside a Docker Sandbox (`to/sandbox`) the deny-by-default network allowlist has neither
`registry.npmjs.org` nor a git host, so this override path needs both allowed; the vendored default needs
nothing.

`test14.sh` proves the contract and **fails - never skips - when the dashboard cannot start**: the flag is on
by default and a source in `.env` is a credential-free https URL or empty; the greyed tile names the flag; the route exists only
when enabled and carries the Host/Origin and `/api/` rewrites; the vendored build is present and runs;
`ui-start.sh` serves it loopback-only with 200 on `/`, watching the default tmux server, writable, idempotent
on re-run, `UP` in `ui-status.sh`; it answers through the proxy with the guard's negative controls intact;
`ui-stop.sh` takes it down; `UI_TMUX_WRITABLE=false` makes its send box answer 403; a planted copy of the
tree without the build is reported as not started; and a finished build at the install directory's default is
not taken for one of your repositories, with the earlier `/wd/tmux-agent` failing that check as its planted control.
The override path (install from `TMUX_AGENT_SRC`,
re-install on a ref change, a build that fails type-checking never served, a token URL masked everywhere) is
exercised when a reachable `TMUX_AGENT_SRC` is given.

**The autonomy loop in the dashboard's tree.** The loop runs detached, outside tmux (see "Autonomy loop"), and the
dashboard's census lists tmux sessions only, so on its own the tree would show the agent session and nothing of the
loop. `/agent/loop-start.sh` therefore gives the running loop a tmux session of its own on the default server,
`agent-loop` (`@agent_parent operator`), whose pane shows the loop's log, and the loop's pane opens one more session per
fire while the fire runs, `agent-loop-fire-<n>` (`@agent_parent agent-loop`), closed at the fire's END line
(`/agent/loop-lineage.sh`). The tree and `tmux-agent lineage` read operator -> `agent-loop` -> `agent-loop-fire-<n>`,
and the dashboard's history keeps every fire under the loop: each session gets a `session.spawned` and a
`session.killed` line in the dashboard's ledger, stamped with the times `loop.log` records. These sessions are a view,
never the work: `loop.sh` is unchanged, so a fire's exit code, its timeout, the claude options, the single-instance
lock and `loop-stop.sh --now`'s process-group kill are what they were; nothing in a view holds the loop's lock, and
every view ends with what it shows (a fire's at its END line, the loop's when the loop exits by any route). The
dashboard reads a session's state and CPU from its pane, so for these sessions it shows the view's - idle, process
bash - not the fire's; the Agent loop page below has the fire's own. No tmux server is ever started for it, a fire run
by `/agent/loop-once.sh` gets no session, and `AUTONOMY_LOOP_TMUX_LINEAGE=false` (environment of `loop-start.sh`)
leaves the sessions out.

### Agent loop page

The `Agent loop` tile (`http://loop.localhost:8000/`) is the autonomy loop at a glance. `/agent/loop-view.py`
(python3, standard library only, started by `ui-start.sh`) reads the loop's own files every 5 seconds and writes
`/wd/ui/loop/data.json` and the page that draws it - each to a temp file, then renamed - and serves them on
`127.0.0.1:7790`; the home proxy carries the page on its own hostname, like the other standard-library dashboards. Its
look is the harness stylesheet's (`/__harness/harness.css`, linked first): the page's own `style.css` holds only its
layout, every colour a token. On by default (`UI_LOOP=true` in `.env`; `false` removes the route and greys the tile).
Each loop's page is also at `/loop/<loop-id>/` - today `autonomy-loop`, the same page: `/loop/<loop-id>`
redirects there, and an id this page does not show answers 404 with a page that says so and links the loops it does.
A loop row of Loop Deck opens the Deck's own view of that loop (`#/loop/<slug>` on the Deck), not this page: the Deck
ships unchanged from its release (`/opt/loop-deck/VENDORED.md`), and that view has no link here.
The page links back to Loop Deck's Loops view: the fleet Deck `LOOP_DECK_URL` names
(the URL the home page's Fleet Loop Deck tile links, under the same check), or else the Deck this harness serves, on
its sibling host route (`//loop-deck.<home host>/#/loops`, found from the page's own host the way the home badge
finds the home page), while the home proxy reaches it - the renderer asks `/__probe/loop-deck`, the probe the home
page's Loop Deck dot reads, at most every 30 seconds (`LOOP_VIEW_DECK_PROBE_SECS`). With neither there is no link,
never a dead one, and the served Deck's link shows only on a `*.localhost` host. The harness's other loops each have
a status page at their slug, read from the files each one leaves: `slack-chat` (the messages it answered, as fires -
answering, ok with the model's rc and duration, failed - and whether it holds its lock), `slack-watch` (its last
run's summary line), `comms-watch` (its process and the tail of its log), `kanban-sync` and `plane-sync` (their state
files) and `hindsight-seed` (its extraction state). The page has five parts:

* **Overview** - first a line that says what the loop does now or how its work ended: the fire running and for how
  long, waiting for the next fire, idle with nothing to fire against, all goals done, or the fault, with the last
  fire's result. Then its health, always as a word next to the colour: GREEN when the last fire (or, idle with nothing
  to fire against, the last cycle) is within twice the interval and at most 10 minutes old or a fire is running inside
  its timeout, STALE within six times (at least 30 minutes), RED beyond that, for a fire past its timeout, for a lock
  that no loop process holds, for a state line that no process backs, and for a loop that stopped after a failed or
  timed-out fire. A loop that is not running is not otherwise a fault: COMPLETE when every goal is done (it stopped
  on the `STOP` flag its last fire set), STOPPED when it was stopped or never started. The last fire's age and the
  goals open and done (the checkbox lines of the goals file, counted as `agent-status.sh` counts them) come next; the
  loop's details follow in smaller tiles: its state line and the `STOP` flag, the fires and their success rate in the
  last 24 hours, and the interval and timeout of the running loop (its own start line). Open goals are listed,
  completed ones fold behind their count; then the last progress notes and **needs attention**: a failed fire, a fire
  that hit its timeout, a stale lock, the `STOP` flag of a loop with work left, the loop not running while goals are
  open. On a phone the first screen holds that first line, the health, the last fire and the goals.
* **Control** - two actions. **Run next fire** is the loop's own start, `/agent/loop-start.sh`: it removes a `STOP`
  flag left by a halt and starts the loop, which fires at once when goals are open; a running loop is left alone and
  fires on its own schedule, and one with a Pause pending still halts (the answer says so). **Pause loop** is
  `/agent/loop-stop.sh`: it sets the `STOP` flag, the loop halts before its next fire and a fire in flight finishes;
  the next Run next fire removes the flag. Each answer is the loop read back after the script ran, never the script's
  word: done, unchanged (already running, or the flag already set), refused, or failed with what was read - a lock
  held by a process that is not the loop (`loop-start.sh` then says "already running" and exits 0), a `STOP` that is
  not a file `loop.sh` sees (a directory: the `touch` succeeds) - and what the script printed. The renderer takes the
  two actions only as a POST to `/control/run` or `/control/pause` with the page's own origin and its `X-Loop-Control`
  header, which a form or a page on another site cannot send, one at a time. `UI_LOOP_CONTROL=false` in `.env` turns
  them off: no proxy route, the renderer refuses them and the page says so. The tile and its dot probe stay
  status-only either way.
* **Fires** - the last 50 with their start, duration, exit code, the goals they fired on and the first line of the
  transcript; each links to a page showing its transcript (`/wd/loop/fires/fire-<n>.out`), served as `text/plain`
  with `nosniff` and a sandbox policy, and drawn as text, never as HTML. A fire's page polls while the fire runs and
  says so; once the fire has ended it is a snapshot that says when it was read and that it does not refresh. A 24-hour
  strip in half hours shows the fires (fired and every fire ok, a fire failed or timed out, the loop ran with nothing to
  fire, no sign of the loop); on a narrow screen a line says the table scrolls sideways.
* **Fleet** - a top-down tree: the operator; under it the agent's terminal sessions (tmux, with their
  `@agent_parent` lineage, attached or not, what runs in them) and the autonomy loop, the hub, with its latest fires -
  the one in flight marked live - and, under each fire, the sub-agents it spawned, read from the fire's own Claude
  Code session (its Task and Agent tool uses: done once their result is in). Then the services beside the agent with
  their probe state: the rows of `ui-status.sh`, the comms UI and the Slack chat responder, each with its process and
  HTTP answer folded behind "details".
* **Commands** - the operations to copy (`docker exec <this container> /agent/loop-start.sh`, `loop-stop.sh`,
  `loop-stop.sh --now`, `loop-status.sh`, `goals-add.sh`, `loop-once.sh`, and the last transcript), shown to copy;
  the page runs only the two actions above.

Apart from those two actions the page is read-only over the loop: the renderer never writes `/wd/loop` itself (the
actions run the loop's own scripts, which do), its only POST endpoints are the two actions, and it never takes
`loop.lock` - `loop.sh` and `loop-start.sh` test that lock with `flock -n`, so a reader holding it even for
an instant could turn a start away; it reads who holds the lock from `/proc/<pid>/fdinfo` (which names the flock on the
holding file description; inside a container `/proc/locks` stops showing it once `flock` has exited). Every text from
the data reaches the page through `textContent`; the page carries nothing inline and allows its own origin only, and
on the proxy route the policy adds the hashes of exactly the home badge's three inline pieces (its style attribute
and phone-width rule in `style-src`, its keeper script in `script-src`), computed by `home-render.sh` from the
strings it injects. Its dot probes `/__probe/loop`, the renderer's `/health`,
which answers 2xx only while the last write is at most `LOOP_VIEW_STALE_SECS` (default 30) seconds old, so a stopped
renderer and one that stopped writing both read down, in `ui-status.sh` too. `test-loop-view.sh` proves each part with
the control that fails it: a stopped loop never reads GREEN and the running loop does; needs attention lists exactly the
failures and is empty without them; a goal too long for the page ends in an ellipsis; the tree is operator -> loop ->
fire -> sub-agent after one fire and a renderer without the lineage fails; the probe is 204 only while fresh; a
transcript holding `<script>` stays text; the badge and the policy's hash are in the proxied page and a route without
the badge include fails; and the loop's tmux sessions reach the tmux-agent dashboard's own CLI and API while the fires
keep their exit code, timeout and `--now`, and a last fire that sets the STOP flag closes in its history with its rc.
Through the proxy, Run next fire starts a stopped loop and Pause loop halts it, each answering with the state read
back, and Run next fire before the paused loop has halted answers failed with its STOP flag still set; a planted lock
that no loop holds and a `STOP` directory answer failed although both scripts exit 0; a request without the page's
header, from another origin or as a GET is refused, and so is every action with `UI_LOOP_CONTROL=false` - a renderer
that trusts the scripts' exit codes, and one without the header check, each fail. Under `/loop/autonomy-loop/` the proxy
serves the same page, its data and its transcripts (still sandboxed plain text), and its controls; `/loop/nope/` is a
404 that says so, and an id carrying markup comes back escaped; the Loop Deck link is absent with no Deck named or
reachable, the served Deck's while a stub answers its probe, and the Loops view of the Deck `LOOP_DECK_URL` names - a
renderer without the route, one without the escape, one without Loop Deck's address, one that links the served Deck
without asking, one that ignores `LOOP_DECK_URL`, and a proxy without the prefixed transcripts location each fail.
The other loops' pages and data come from fixture files of each - slack-chat's three answered messages, its lock
holder, the comms watch's pid, which reads not running once that process exits - and a renderer without the chat's
REPLY lines, and one that trusts a pid file, each fail.

The overview refreshes every 5 seconds and redraws only the parts whose data changed; the keyboard focus (a copy
button, a transcript link) and any details left open stay where they were across a refresh. When the data cannot be
read, the caption says so and the page keeps what it read last. `tests/ux/test_loop_view.py` checks this in a browser
on the host (it needs Python Playwright and its Chromium; `python3 tests/ux/test_loop_view.py`): the real renderer
writes the page for fixtures under `tests/ux/fixtures/loop/` (every goal done with the STOP flag and rc 0, a failed
last fire, no fire yet, a live fire; old data and a failed read on top), headless Chromium reads it at 1920x1080 and
390x844, and each check runs again against a copy with its property removed, which must fail it: COMPLETE for the
finished loop and RED for the failed one, a word for every state, the focus kept through a refresh, captions that poll
when they say so and snapshots that say they do not, the phone's first screen, the folded goals, the stale and
failed-read captions; the two actions, whose answer the page shows as read back (a failure the scripts called
fine, not the intent), each sent as a same-origin POST with its header and offered neither when the controls are
off; and - with the harness stylesheet served, which these two need - the header's text starting where the nav's
does at 1920x1080 and a 16 px gutter on a phone; and under `/loop/autonomy-loop/` the page reading that loop's data and
linking its fires there; and the Loop Deck link: the served Deck's on `loop.localhost` while it answers its probe,
none off a `*.localhost` host, none with no Deck reachable or named, and the Loops view of the Deck `LOOP_DECK_URL`
names on any host; and slack-chat's status page showing its process and its answered messages as fires,
every word as text.

## Files

The home page's **Files** tile (`http://files.localhost:8000/`, on by default with `UI_FILES=true`) is a shared folder
between you and the agent, served by the harness itself: `/wd/files` inside the container (`FILES_DIR`), on the `/wd`
volume - on the docker target `wd/files` beside the checkout, persisted with the rest of the agent's state; on
kubernetes `/wd` is the deployment's `emptyDir`, gone with the pod unless you mount a volume there.

* **Two directions.** The agent saves what it made for you there - a report, a chart, an export, a log excerpt, a patch,
  an archive - and names the path in its answer; you download it from the tile. A file you upload lands in the folder you
  are viewing, for the agent to read: say so, and it looks under `/wd/files`. The agent's side of the convention is
  `agent-rules/AGENT_FILES.md`, which `/agent/claude-settings-sync.sh` keeps beside its `CLAUDE.md` at every start the way
  it keeps the learning rules: deliverables go there (sub-folders welcome), uploads arrive there, nothing is run from there,
  and a deliverable is a copy - the person can rename, move and delete in that folder.
* **What the page does.** Browse folders (breadcrumbs), download a file, upload files (the picker or drag-and-drop, several
  one after another, each with its progress and outcome), make a folder, rename, move (drag a row onto a folder row, the
  parent row or a breadcrumb, or **Move to...** with a folder picker for a keyboard) and delete. Every change that removes
  or replaces something asks first; a folder that is not empty asks a second time, naming how many entries it holds. The
  page shows the live upload cap.
* **The knobs,** all in `.env` and passed through by `run.sh`, the compose template and the kubernetes deployment:
  `UI_FILES` (the tile, default `true`), `PORT_INTERNAL_FILES` (the server's loopback port, 8098), `FILES_DIR` (the folder,
  `/wd/files`) and `FILES_MAX_UPLOAD_MB` (the largest upload in MiB, 1024 = 1 GiB; the home proxy's body limit for the
  route follows it, one MiB above, so the server - not nginx - answers 413 at the cap itself).
* **The posture.** `/agent/files-server.py` (python standard library, `127.0.0.1:8098`, reached through the home proxy's
  `files.localhost` route) resolves every path with `realpath` against the folder and answers nothing outside it: a dotted
  or percent-encoded traversal, an absolute path or a symlink that points out of the folder is refused (the listing marks
  such a link and never follows it). Every download is an attachment (`Content-Disposition: attachment`, `nosniff`, a plain
  type), so an uploaded `.html` never renders as a page on this origin. An upload is the raw request body (no multipart
  parsing), refused with 413 before a byte is read when its `Content-Length` is over the cap, streamed to a temporary file
  in the target folder and moved onto its name (a taken name is 409 unless `replace=1`). Every write - an upload, a folder,
  a rename, a move, a delete - is a `PUT` or a `POST` answered to the page's own origin only (a foreign `Origin`, an opaque
  `null` or a cross-site fetch gets 403); the `DELETE` method stays 405, a foreign `Host` 421; every response says
  `Cache-Control: no-store`, `nosniff` and `no-referrer`, and the policy is the page's own origin alone (the route adds
  exactly the hashes of the home badge's three inline pieces). The page builds its DOM with `textContent` only. Nothing is
  ever executed - the one thing the server never does with a file. Log lines carry the method, the path without its query
  and the status: no file name, no content.
* **Not published, and no login of its own.** Loopback only, like every other UI: reach it through the home page, or an SSH
  tunnel to the home port (`run.sh` publishes `127.0.0.1:8000` and nothing else). The home port carries no authentication,
  so whatever can reach it reaches every UI - this one included, and this one takes uploads that land in a folder the agent
  reads. Inside the container nginx listens on every interface: another container on the same docker network, or a pod
  that reaches the kubernetes Service, can use it; keep that network to the harness's own containers (a NetworkPolicy on
  kubernetes), and treat what arrives in the folder as data from outside - the agent's note says the same.
* **An honest dot.** The tile's dot reads `/__probe/files`, the server's `/healthz`: 200 while the folder exists and the
  server may write it, 503 otherwise. `UI_FILES=false` greys the tile with its flag, and neither the route nor the probe is
  rendered.

`test-files.sh` proves each of these offline against the server and nginx on test-local ports: the round trip byte for
byte, rename, move and delete with their rules, nine traversal forms and seven fenced destinations with a planted file
outside the folder that appears in no response (and is served once a control removes the fence), the cap with and without
`Expect: 100-continue` (and accepted once a control removes it), every origin and method refusal (and a foreign origin
accepted once a control removes the guard), the route with the badge once under exactly the server's policy plus the
badge's hashes, the cap at the route, the dot following the folder and the server, the tile on and off, `ui-start.sh` /
`ui-status.sh` / `ui-stop.sh`, and the note's sync.
