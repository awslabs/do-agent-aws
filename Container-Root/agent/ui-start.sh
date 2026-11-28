#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Harness UIs - start the enabled web UIs.
#
# Opt-in: set UI_START=true in .env (see docs/manual/ui.md "Harness UIs"); startup.sh then calls this
# script at container start. It can also be run manually inside the container at any time.
# Each UI runs detached in its own session; output goes to ${UI_DIR}/<name>.log and the pid to
# ${UI_DIR}/<name>.pid so ui-stop.sh and ui-status.sh can manage it. A UI whose pid is already
# alive is left untouched, so the script is safe to re-run.
#
# UIs (per-UI enable flags honored when this script runs):
#   headlamp      - Kubernetes dashboard; uses ${KUBECONFIG}, /home/agent/.kube/config, or in-cluster
#                   credentials, whichever exists
#   hindsight-api - hindsight memory HTTP API + interactive /docs explorer; defaults to the
#                   bedrock LLM provider so it runs on the same AWS credentials as the rest of
#                   the container (override via HINDSIGHT_API_LLM_PROVIDER/_API_KEY/_MODEL)
#   hindsight-ui  - hindsight control-plane web UI, backed by hindsight-api
#   vibe-kanban   - the vibe-kanban agent runner (coding agents in git worktrees), at vk-runner.localhost;
#                   the kanban board itself is a sidecar container that run.sh starts (docs/manual/boards.md "Kanban
#                   board") and the home proxy serves at kanban.localhost
#   kanban-signin - with that board (KANBAN_BOARD_URL): the one-click sign-in behind the Kanban board tile
#   kanban-seed   - with that board: /agent/kanban-sync.py seed, once per start - the agent's project and its goal
#                   cards on the board before any fire; it exits when done, its exit status then in
#                   ${UI_DIR}/kanban-seed.done (not a UI: no port, no status row)
#   tmux          - ttyd browser terminal attached to the shared tmux session "agent"
#                   (tmux new-session -A -s agent); WRITABLE by default, watch-only with
#                   UI_TMUX_WRITABLE=false
#   home          - the harness home page + nginx reverse proxy: one port serves the home
#                   page and proxies every enabled UI (config rendered per start by
#                   /agent/home-render.sh; see docs/manual/ui.md "Home page and reverse proxy")
#   tmux-agent    - the tmux-agent web dashboard (fleet tree, history, waste of tmux-run
#                   agents), ON by default: served from the build vendored into the image at
#                   /opt/tmux-agent (setup/install-tmux-agent-dashboard.sh - a prebuilt copy
#                   of the public source, so it needs no network), or,
#                   when TMUX_AGENT_SRC is set, built from that source on first start by
#                   /agent/install-tmux-agent.sh and re-built when TMUX_AGENT_REF or
#                   TMUX_AGENT_SRC changes; served loopback-only and proxied at /tmux-agent/;
#                   read-only with UI_TMUX_WRITABLE=false
#   claude-mem    - the claude-mem plugin's worker, which serves the memory viewer (what the
#                   plugin's hooks capture from every Claude Code session); the same process
#                   the plugin's SessionStart hook would start on demand, started here (or
#                   adopted when already up) so the tile is up before the first session and
#                   stays up; host route claude-mem.localhost
#   loglearner    - the LogLearner dashboard over the agent's own session corpus
#                   (/agent/loglearner-serve.sh: vendored /opt/loglearner, index on /wd);
#                   host route loglearner.localhost
#   loop-view     - the Agent loop page (/agent/loop-view.py): the autonomy loop's state, fires,
#                   goals and fleet, rendered read-only from the loop's state files every few
#                   seconds into ${UI_DIR}/loop; host route loop.localhost
#   board         - the Board (/agent/board-server.py, docs/manual/boards.md "Board"): a read-only kanban view of
#                   this harness's own Plane project with the agent runner's attempts on its cards;
#                   only while the Plane sidecars run on this target (UI_PLANE=true, PLANE_URL set);
#                   loopback only, host route board.localhost
#   files         - the Files tile (/agent/files-server.py, docs/manual/ui.md "Files"): the shared folder FILES_DIR
#                   (/wd/files) between the person and the agent - listed, downloaded as attachments, uploaded
#                   into, folders, rename, move, delete; the folder is created here; loopback only, host route
#                   files.localhost
#   plane-signin  - the Plane tile's one-click sign-in (/agent/plane-signin.py, docs/manual/boards.md "Plane
#                   board"); only while the Plane sidecars run on this target (PLANE_URL, set by
#                   run.sh) and PLANE_LOGIN_BYPASS=true; loopback only, reached through the home
#                   proxy's plane.localhost route. The board itself runs in sidecar containers
#   plane-seed    - with that board (PLANE_URL): /agent/plane-sync.py seed, once per start - the goals as work
#                   items before any fire; it exits when done, its exit status then in
#                   ${UI_DIR}/plane-seed.done (not a UI: no port, no status row)
#   agent-chat    - the Agent chat page (/agent/agent-chat.py, docs/manual/ui.md "Agent chat"): the shared
#                   agent session's pane in the browser and a box that types a message at its prompt;
#                   loopback only, host route chat.localhost; its send box follows UI_TMUX_WRITABLE
#
# Settings (all overridable via environment; the flags and ports are declared in .env and
# passed through by run.sh, the compose template, and the kubernetes deployment):
#   UI_HEADLAMP / UI_HINDSIGHT / UI_VIBE_KANBAN / UI_TMUX / UI_HOME / UI_TMUX_AGENT /
#   UI_CLAUDE_MEM / UI_LOGLEARNER / UI_BOARD / UI_FILES / UI_LOOP - per-UI enable flags (default true); UI_TMUX_WRITABLE
#                    (default true) lets the browser terminal and the tmux-agent dashboard's
#                    send box type into the tmux sessions
#   UI_PORT_HEADLAMP / UI_PORT_HINDSIGHT_API / UI_PORT_HINDSIGHT_UI / UI_PORT_VIBE_KANBAN /
#   UI_PORT_TMUX / UI_PORT_TMUX_AGENT / UI_PORT_CLAUDE_MEM / UI_PORT_LOGLEARNER / UI_PORT_BOARD /
#   UI_PORT_FILES / UI_PORT_LOOP / UI_PORT_HOME
#   FILES_DIR / FILES_MAX_UPLOAD_MB - the Files tile's shared folder (default /wd/files) and its largest upload in
#                    MiB (default 1024)
#   TMUX_AGENT_SRC - unset/empty (default): serve the vendored build at TMUX_AGENT_VENDORED_DIR
#                    (default /opt/tmux-agent); set: build from this source with
#                    TMUX_AGENT_REF into TMUX_AGENT_INSTALL_DIR (default /wd/ui/tmux-agent,
#                    survives restarts) - see /agent/install-tmux-agent.sh
#   HINDSIGHT_HOME - HOME of the hindsight-api process, where its embedded PostgreSQL keeps the
#                    memory database (default /home/hindsight, persisted agent state; test.sh
#                    gives its throwaway container another so two servers never share one
#                    cluster); the embedding model cache stays at /home/hindsight either way
#   HINDSIGHT_AGENT_CONF / CLAUDE_SETTINGS - the hooks' config (default ~/.hindsight/coding-agent.json)
#                    kept on the API port started here, and the settings file (default
#                    $CLAUDE_CONFIG_DIR/settings.json) whose hindsight hooks are repaired when missing;
#                    both are persisted agent state, so a TEST-LOCAL run must point them at copies
#                    (test9.sh, test16.sh do) - HINDSIGHT_HOOKS_REPAIR=false skips the repair
#   HINDSIGHT_API_WORKER_ID - stable id of this API worker (default do-agent-aws): a recreated
#                    container keeps the same id, so background tasks it left "processing" are
#                    recovered instead of orphaned (the API warns about this under docker)
#   LOGLEARNER_STATE - the LogLearner state root (default /wd/loglearner, on the /wd volume)
#   LOGLEARNER_DB / LOGLEARNER_INDEX_INTERVAL - the LogLearner sqlite index (default
#                    ${LOGLEARNER_STATE}/index.db - derived, never a fixed path: a container with its
#                    own LOGLEARNER_STATE, the test container, must index into ITS state) and its
#                    refresh period in seconds (default 300)
#   UI_DIR         - log/pid directory (default /wd/ui, so it survives container restarts)
#   UI_LISTEN_HOST - in-container listen address of the HOME PROXY (default 0.0.0.0: the docker port
#                    publish / kubernetes service is the exposure control and the host side stays on
#                    127.0.0.1 via UI_BIND_HOST in .env; set 127.0.0.1 when running the
#                    Container-Root scripts outside a container)
#   UI_BACKEND_LISTEN_HOST - in-container listen address of every UI BEHIND the proxy (headlamp,
#                    hindsight-api, hindsight-ui, vibe-kanban, ttyd; comms-ui-start.sh follows the same
#                    rule). Default 127.0.0.1 while the proxy fronts them (UI_HOME=true and
#                    UI_PUBLISH_DIRECT_PORTS not true): a backend on 0.0.0.0 inside the container is
#                    reachable by every NEIGHBOUR container on the same docker network or pod network -
#                    the writable terminal and the memory API included - with no Host or Origin to check.
#                    With the proxy off or the direct publishes opted in, the backends must be reachable
#                    by docker-proxy and bind UI_LISTEN_HOST again.

export HOME=${HOME:-/home/agent}
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

UI_HEADLAMP=${UI_HEADLAMP:-true}
UI_HINDSIGHT=${UI_HINDSIGHT:-true}
UI_VIBE_KANBAN=${UI_VIBE_KANBAN:-true}
UI_TMUX=${UI_TMUX:-true}
UI_TMUX_WRITABLE=${UI_TMUX_WRITABLE:-true}
UI_TMUX_AGENT=${UI_TMUX_AGENT:-true}
UI_CLAUDE_MEM=${UI_CLAUDE_MEM:-true}
UI_LOGLEARNER=${UI_LOGLEARNER:-true}
UI_CHAT=${UI_CHAT:-true}
UI_LOOP_DECK=${UI_LOOP_DECK:-true}
UI_LOOP=${UI_LOOP:-true}
UI_LOOP_CONTROL=${UI_LOOP_CONTROL:-true}
UI_HOME=${UI_HOME:-true}
UI_PORT_HEADLAMP=${UI_PORT_HEADLAMP:-4466}
UI_PORT_HINDSIGHT_API=${UI_PORT_HINDSIGHT_API:-8888}
UI_PORT_HINDSIGHT_UI=${UI_PORT_HINDSIGHT_UI:-9999}
UI_PORT_VIBE_KANBAN=${UI_PORT_VIBE_KANBAN:-8081}
UI_PORT_TMUX=${UI_PORT_TMUX:-7681}
UI_PORT_TMUX_AGENT=${UI_PORT_TMUX_AGENT:-7337}
UI_PORT_CLAUDE_MEM=${UI_PORT_CLAUDE_MEM:-37700}
UI_PORT_LOGLEARNER=${UI_PORT_LOGLEARNER:-7777}
UI_PORT_CHAT=${UI_PORT_CHAT:-8094}
UI_PORT_LOOP_DECK=${UI_PORT_LOOP_DECK:-8091}
UI_PORT_LOOP=${UI_PORT_LOOP:-7790}
UI_PORT_HOME=${UI_PORT_HOME:-8000}
# the kanban board's one-click sign-in (/agent/kanban-signin.py; loopback only, behind the home proxy)
UI_PORT_KANBAN_SIGNIN=${UI_PORT_KANBAN_SIGNIN:-8092}
# the Board (/agent/board-server.py; loopback only, behind the home proxy's board.localhost route)
UI_BOARD=${UI_BOARD:-true}
UI_PORT_BOARD=${UI_PORT_BOARD:-8096}
# the Files tile (/agent/files-server.py; loopback only, behind the home proxy's files.localhost route): its port, the
# shared folder it serves and the largest upload it takes, in MiB
UI_FILES=${UI_FILES:-true}
UI_PORT_FILES=${UI_PORT_FILES:-8098}
FILES_DIR=${FILES_DIR:-/wd/files}
FILES_MAX_UPLOAD_MB=${FILES_MAX_UPLOAD_MB:-1024}
# the Knowledge transfer page (/agent/knowledge-transfer.py; loopback only, behind the home proxy's /knowledge/ route)
UI_PORT_KNOWLEDGE=${UI_PORT_KNOWLEDGE:-8097}
UI_LISTEN_HOST=${UI_LISTEN_HOST:-0.0.0.0}
UI_PUBLISH_DIRECT_PORTS=${UI_PUBLISH_DIRECT_PORTS:-false}
if [ -z "${UI_BACKEND_LISTEN_HOST}" ]; then
	if [ "${UI_HOME}" == "true" ] && [ "${UI_PUBLISH_DIRECT_PORTS}" != "true" ]; then
		UI_BACKEND_LISTEN_HOST=127.0.0.1
	else
		UI_BACKEND_LISTEN_HOST=${UI_LISTEN_HOST}
	fi
fi
UI_DIR=${UI_DIR:-/wd/ui}
TMUX_AGENT_INSTALL_DIR=${TMUX_AGENT_INSTALL_DIR:-/wd/ui/tmux-agent}
TMUX_AGENT_VENDORED_DIR=${TMUX_AGENT_VENDORED_DIR:-/opt/tmux-agent}
# empty (the default) = the vendored build; set = the installer path (install-tmux-agent.sh
# has its own default for the source, which is NOT applied here - a source is a deliberate choice)
TMUX_AGENT_SRC=${TMUX_AGENT_SRC:-}
TMUX_AGENT_REF=${TMUX_AGENT_REF:-master}
HINDSIGHT_HOME=${HINDSIGHT_HOME:-/home/hindsight}
HINDSIGHT_API_WORKER_ID=${HINDSIGHT_API_WORKER_ID:-do-agent-aws}
# derived from LOGLEARNER_STATE: a fixed /wd/loglearner/index.db default here sent the test suite's sessions
# into the user's dashboard index through the shared /wd volume (the test container sets its own
# LOGLEARNER_STATE; loglearner-serve.sh's own default never applied)
LOGLEARNER_STATE=${LOGLEARNER_STATE:-/wd/loglearner}
LOGLEARNER_DB=${LOGLEARNER_DB:-${LOGLEARNER_STATE}/index.db}
LOGLEARNER_INDEX_INTERVAL=${LOGLEARNER_INDEX_INTERVAL:-300}

# home-render.sh, install-tmux-agent.sh and loglearner-serve.sh (child processes) render the
# home page + proxy config, fetch the dashboard and serve the LogLearner dashboard from these
# same settings, so they must reach their environment
export UI_HEADLAMP UI_HINDSIGHT UI_VIBE_KANBAN UI_TMUX UI_TMUX_WRITABLE UI_TMUX_AGENT UI_CLAUDE_MEM \
	UI_LOGLEARNER UI_LOOP_DECK UI_PORT_LOOP_DECK UI_CHAT UI_HOME UI_PORT_HEADLAMP UI_PORT_HINDSIGHT_API UI_PORT_HINDSIGHT_UI UI_PORT_VIBE_KANBAN \
	UI_PORT_TMUX UI_PORT_TMUX_AGENT UI_PORT_CLAUDE_MEM UI_PORT_LOGLEARNER UI_PORT_CHAT UI_PORT_HOME UI_LISTEN_HOST UI_BACKEND_LISTEN_HOST UI_PUBLISH_DIRECT_PORTS \
	UI_DIR TMUX_AGENT_INSTALL_DIR LOGLEARNER_STATE LOGLEARNER_DB LOGLEARNER_INDEX_INTERVAL UI_PORT_KANBAN_SIGNIN \
	UI_BOARD UI_PORT_BOARD UI_LOOP UI_LOOP_CONTROL UI_PORT_LOOP UI_PORT_KNOWLEDGE UI_FILES UI_PORT_FILES FILES_DIR FILES_MAX_UPLOAD_MB

# Absolute node for the detached dashboard (no login-shell PATH), the slack-*.sh pattern
NODE_BIN=${NODE_BIN:-/usr/local/bin/node}
[ -x "${NODE_BIN}" ] || NODE_BIN=$(command -v node)

# The scripts live in /agent in-container and Container-Root/agent in a repo checkout
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "${UI_DIR}" 2>/dev/null || UI_DIR=/tmp/ui
mkdir -p "${UI_DIR}"

# A pid is trusted only when its command line matches the UI it claims to be: pidfiles
# live on the /wd volume and survive container recreation, while pids are namespace-local,
# so after a restart a stale pidfile can point at an unrelated recycled pid.
pid_is_ui()
{
	PID=$1
	MATCH=$2
	[ -n "${PID}" ] && [ -d "/proc/${PID}" ] && tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null | grep -q "${MATCH}"
}

start_ui()
{
	NAME=$1
	MATCH=$2
	WORKDIR=$3
	shift 3
	PID_FILE=${UI_DIR:?}/${NAME:?}.pid
	if [ -f "${PID_FILE}" ]; then
		if pid_is_ui "$(cat ${PID_FILE})" "${MATCH}"; then
			echo "${NAME}: already running (pid $(cat ${PID_FILE}))"
			return 0
		fi
		rm -f "${PID_FILE:?}"
	fi
	# The & must apply to the setsid command alone (not a && list) so $! is the daemon
	# itself; setsid detaches it into its own session/process group for ui-stop.sh
	(
		cd "${WORKDIR}" || exit 1
		setsid nohup "$@" >> "${UI_DIR}/${NAME}.log" 2>&1 &
		echo $! > "${PID_FILE}"
	)
	echo "${NAME}: started (pid $(cat ${PID_FILE}), log ${UI_DIR}/${NAME}.log)"
}

if [ "${UI_HEADLAMP}" == "true" ]; then
	KUBECONFIG_ARGS=""
	if [ -n "${KUBECONFIG}" ] && [ -f "${KUBECONFIG}" ]; then
		KUBECONFIG_ARGS="-kubeconfig ${KUBECONFIG}"
	elif [ -f "${HOME}/.kube/config" ]; then
		KUBECONFIG_ARGS="-kubeconfig ${HOME}/.kube/config"
	elif [ -n "${KUBERNETES_SERVICE_HOST}" ]; then
		KUBECONFIG_ARGS="-in-cluster"
	fi
	# behind the home proxy headlamp serves under its native base path /headlamp
	HEADLAMP_BASE_ARGS=""
	if [ "${UI_HOME}" == "true" ]; then
		HEADLAMP_BASE_ARGS="-base-url /headlamp"
	fi
	start_ui headlamp headlamp-server / /opt/headlamp/headlamp-server \
		-listen-addr "${UI_BACKEND_LISTEN_HOST}" -port "${UI_PORT_HEADLAMP}" \
		-html-static-dir /opt/headlamp/frontend -plugins-dir /opt/headlamp/plugins \
		${HEADLAMP_BASE_ARGS} ${KUBECONFIG_ARGS}
fi

if [ "${UI_HINDSIGHT}" == "true" ]; then
	# Behind the home proxy the API is /memory-api/. Prefer the CLI's native
	# --root-path (correct swagger/openapi URLs generated by the app itself) and fall
	# back to a proxy-side rewrite when the pinned CLI predates the option; the
	# detected mode is exported so home-render.sh renders the matching config.
	HINDSIGHT_ROOT_PATH_ARGS=""
	export HINDSIGHT_API_ROOT_PATH=rewrite
	# The API's own base path (HINDSIGHT_API_BASE_PATH, the FastAPI root_path of hindsight-api): /memory-api behind
	# the home proxy. Without it the openapi.json named no server, so the docs page's "Try it out" sent every request
	# to the proxy's root (/v1/default/banks), which answers 404; with it the document's server is /memory-api, and
	# the page itself names /memory-api/openapi.json. The proxy still strips the prefix: the API's routes answer
	# without it too, so the hooks and the memory UI, which call the API directly, are unchanged.
	HINDSIGHT_BASE_PATH=""
	[ "${UI_HOME}" == "true" ] && HINDSIGHT_BASE_PATH=/memory-api
	if [ "${UI_HOME}" == "true" ] && env HOME=/home/hindsight \
		/home/hindsight/.local/bin/hindsight-api --help 2>&1 | grep -q -- '--root-path'; then
		HINDSIGHT_ROOT_PATH_ARGS="--root-path /memory-api"
		export HINDSIGHT_API_ROOT_PATH=native
	fi
	# hindsight-api runs as the agent user, like every process here (its embedded PostgreSQL refuses
	# root); HOME is set explicitly so the pg0 cluster lands under HINDSIGHT_HOME/.pg0 -
	# /home/hindsight/.pg0 by default, persisted with the agent state (.env AGENT_STATE_VOL_MAP),
	# so memories survive container replacement. An alternative HINDSIGHT_HOME (test.sh gives its
	# throwaway container one) is created here; the embedding model cache
	# stays pinned to the image's copy under /home/hindsight (HF_HOME), so another HOME never means
	# another download. The worker id is stable across container recreation on purpose (see above).
	# The AWS config and credentials files are pinned to /home/hindsight/.aws, a copy of the agent's
	# /home/agent/.aws (the host's ~/.aws, mounted by run.sh) that /agent/hindsight-aws-config.sh makes
	# on every start: with AWS_PROFILE set boto3 looks the profile up under the process's HOME, which
	# here is the data directory - without the copy every extraction failed
	# with "config profile could not be found" while claude worked. Missing files are simply
	# ignored by boto3 (IMDS, env keys). The output language is pinned (HINDSIGHT_API_LLM_OUTPUT_LANGUAGE,
	# English unless set): the extraction prompt's own rule is "the language of the input", and the
	# default model wrote German records from an English session; the session guard
	# (/agent/hindsight-session-guard.py) sets aside a session record in any other language.
	if [ "${HINDSIGHT_HOME}" != "/home/hindsight" ]; then
		mkdir -p "${HINDSIGHT_HOME}" \
			|| echo "hindsight-api: WARNING - cannot create HINDSIGHT_HOME=${HINDSIGHT_HOME}"
	fi
	"${AGENT_DIR}/hindsight-aws-config.sh"
	start_ui hindsight-api hindsight-api / env \
		HOME="${HINDSIGHT_HOME}" \
		HF_HOME=/home/hindsight/.cache/huggingface \
		HINDSIGHT_API_WORKER_ID="${HINDSIGHT_API_WORKER_ID}" \
		HINDSIGHT_API_LLM_PROVIDER="${HINDSIGHT_API_LLM_PROVIDER:-bedrock}" \
		HINDSIGHT_API_LLM_OUTPUT_LANGUAGE="${HINDSIGHT_API_LLM_OUTPUT_LANGUAGE:-English}" \
		HINDSIGHT_API_BASE_PATH="${HINDSIGHT_BASE_PATH}" \
		AWS_CONFIG_FILE="${AWS_CONFIG_FILE:-/home/hindsight/.aws/config}" \
		AWS_SHARED_CREDENTIALS_FILE="${AWS_SHARED_CREDENTIALS_FILE:-/home/hindsight/.aws/credentials}" \
		/home/hindsight/.local/bin/hindsight-api --host "${UI_BACKEND_LISTEN_HOST}" --port "${UI_PORT_HINDSIGHT_API}" \
		${HINDSIGHT_ROOT_PATH_ARGS}
	# The agent's hindsight hooks (setup/install-hindsight.sh: self-hosted mode) read the API's
	# address from /home/agent/.hindsight/coding-agent.json - persisted agent state, written at build
	# time with the default port. Keep it pointed at THIS API: an older persisted copy may still
	# say "daemon" (the pre-fix mode, a second store the UI never showed), and a changed
	# UI_PORT_HINDSIGHT_API would otherwise leave the hooks talking to a dead port. Rewritten only
	# when it differs, so an untouched file stays byte-for-byte.
	HINDSIGHT_AGENT_CONF=${HINDSIGHT_AGENT_CONF:-${HOME}/.hindsight/coding-agent.json}
	if command -v python3 > /dev/null 2>&1 && [ -d "$(dirname "${HINDSIGHT_AGENT_CONF}")" ]; then
		HINDSIGHT_API_URL="http://localhost:${UI_PORT_HINDSIGHT_API}" HINDSIGHT_AGENT_CONF="${HINDSIGHT_AGENT_CONF}" python3 - << 'EOF'
import json, os
path, url = os.environ["HINDSIGHT_AGENT_CONF"], os.environ["HINDSIGHT_API_URL"]
try:
    conf = json.load(open(path))
except (OSError, ValueError):
    conf = {}
if conf.get("serverMode") != "self-hosted" or conf.get("apiUrl") != url:
    was = f'{conf.get("serverMode")} {conf.get("apiUrl") or ""}'.strip()
    conf.update({"serverMode": "self-hosted", "apiUrl": url})
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(conf, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print(f"hindsight-api: agent hooks pointed at {url} ({path}; was: {was or 'absent'})")
EOF
	fi
	# The hooks themselves live in $CLAUDE_CONFIG_DIR/settings.json - persisted agent state too, and a
	# folder first seeded by an image that had lost them (the pre-fix plugins step overwrote the file)
	# keeps them lost through every later image. Put back when missing, never otherwise touched.
	# The repair also keeps the hooks' config at autoInject "none" (the memory block is the recall hook's records,
	# not a synthesis), so the config path goes along.
	HINDSIGHT_AGENT_CONF="${HINDSIGHT_AGENT_CONF}" CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json}" "${AGENT_DIR}/hindsight-hooks-repair.sh"
	# Loopback bind of the Next.js standalone server: HOSTNAME=localhost with node's IPv4-first resolution
	# (-> 127.0.0.1 only), NOT HOSTNAME=127.0.0.1. The control plane's next-intl middleware rewrites every
	# page to an absolute URL on `localhost:<port>`; Next serves that rewrite only when it matches the
	# server's own hostname - with 127.0.0.1 it answered `307 /dashboard` to itself in a loop and the memory
	# UI tile never loaded (found in a sign-in walk of the tiles). Plain `localhost` binds ::1 only here
	# (node resolves it to IPv6 first), hence --dns-result-order=ipv4first.
	if [ "${UI_BACKEND_LISTEN_HOST}" == "127.0.0.1" ]; then
		HINDSIGHT_UI_HOSTNAME=localhost
		HINDSIGHT_UI_NODE_OPTIONS="--dns-result-order=ipv4first${NODE_OPTIONS:+ ${NODE_OPTIONS}}"
	else
		HINDSIGHT_UI_HOSTNAME=${UI_BACKEND_LISTEN_HOST}
		HINDSIGHT_UI_NODE_OPTIONS=${NODE_OPTIONS}
	fi
	start_ui hindsight-ui next-server /opt/hindsight/control-plane env \
		HOSTNAME="${HINDSIGHT_UI_HOSTNAME}" NODE_OPTIONS="${HINDSIGHT_UI_NODE_OPTIONS}" PORT="${UI_PORT_HINDSIGHT_UI}" \
		HINDSIGHT_CP_DATAPLANE_API_URL="http://127.0.0.1:${UI_PORT_HINDSIGHT_API}" \
		/usr/local/bin/node /opt/hindsight/control-plane/server.js
fi

if [ "${UI_VIBE_KANBAN}" == "true" ]; then
	# The runner's analytics are off unless the user turns them on: its server sends usage events to vibe-kanban's
	# PostHog while analytics_enabled is true, the default of a new configuration. On a first start (no config yet)
	# the runner gets its own 0.1.44 first-start settings (vibe-kanban-config.json) with analytics_enabled false and
	# its Workspaces guide seen (showcases.seen_features "workspaces-guide": else the guide opens over /workspaces on
	# the first visit, the page the home tile opens); its terms, disclaimer and onboarding stay unanswered, for the
	# user. A config that exists is the user's and is never changed - with its analytics on, a one-line notice says
	# so (here and in the runner's log)
	VK_CONFIG=${VIBE_KANBAN_DATA_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}}/vibe-kanban/config.json
	# this start's notice alone also goes to VK_NOTICE (test-kanban.sh live reads it): one of an earlier start, still
	# in the appended log, must not count for this one
	VK_NOTICE=${UI_DIR}/vibe-kanban-analytics.notice
	rm -f "${VK_NOTICE:?}"
	if [ ! -e "${VK_CONFIG}" ]; then
		mkdir -p "$(dirname "${VK_CONFIG}")" && cp "${AGENT_DIR}/vibe-kanban-config.json" "${VK_CONFIG}" \
			&& echo "vibe-kanban: first start - its analytics are off in ${VK_CONFIG} (the runner's Settings, General, Privacy turns them on)"
	elif grep -qE '"analytics_enabled"[[:space:]]*:[[:space:]]*true' "${VK_CONFIG}"; then
		echo "vibe-kanban: NOTICE - analytics are on in ${VK_CONFIG}: the runner sends usage events to vibe-kanban's PostHog; turn them off in its Settings, General, Privacy" \
			| tee -a "${UI_DIR}/vibe-kanban.log" "${VK_NOTICE}"
	fi
	# The runner's agent settings, when it has none (no profiles.json): vibe-kanban 0.1.44 runs Claude Code as
	# npx -y @anthropic-ai/claude-code@<its pin> with --dangerously-skip-permissions. vibe-kanban-profiles.json makes
	# it this image's own claude (its Bedrock settings, nothing fetched at a start) without that flag. A person changes
	# both in the runner's Settings, Agents, Claude Code; a profiles.json that exists is theirs and is never changed
	VK_PROFILES=$(dirname "${VK_CONFIG}")/profiles.json
	if [ ! -e "${VK_PROFILES}" ]; then
		mkdir -p "$(dirname "${VK_PROFILES}")" && cp "${AGENT_DIR}/vibe-kanban-profiles.json" "${VK_PROFILES}" \
			&& echo "vibe-kanban: no agent settings yet - its Claude Code is the image's claude, without --dangerously-skip-permissions (${VK_PROFILES}; the runner's Settings, Agents changes them)"
	fi
	# VIBE_KANBAN_DATA_HOME (unset by default): the runner keeps its state there instead of in the persisted
	# /home/agent/.local/share/vibe-kanban (it is the runner's XDG data home). test.sh gives its throwaway container one,
	# so the tests' runner never opens the database of a harness: a starting runner marks every agent run its
	# database calls running as failed
	# The runner's Recent repositories: once it answers, /agent/vk-runner-repos.sh registers the workspace (/wd when it
	# is a git repository) and every git repository one level under it or under its projects/ (the starter repository's
	# folder), so the "Which repositories would you like to work on?" page does not start empty. Detached and best effort (it ends on its own within VK_REPOS_WAIT, so no
	# pid file); its one summary line goes to ${UI_DIR}/vk-runner-repos.log. Re-run by hand after cloning:
	# docker exec <container> /agent/vk-runner-repos.sh
	( setsid nohup "${AGENT_DIR}/vk-runner-repos.sh" >> "${UI_DIR}/vk-runner-repos.log" 2>&1 & )
	echo "vk-runner-repos: registering the workspace's repositories with the runner in the background (log ${UI_DIR}/vk-runner-repos.log)"
	# The relay (UI_KANBAN_RELAY=true on the host, docs/manual/boards.md "Kanban board"; KANBAN_RELAY_URL set by run.sh, with the
	# board): the runner gets the board as its shared API and the relay. Before it starts (not while it runs),
	# /agent/vk-runner-signin.py signs in to the board with the board login and stores the sign-in where the runner
	# keeps it, so the runner starts signed in and registers with the relay as the board's host; the runner's own
	# sign-in would turn its analytics on. Bounded (VK_SIGNIN_WAIT, default 60 s, for a board still starting); its one
	# line also goes to ${UI_DIR}/vk-runner-signin.log, and without a sign-in the runner starts signed out. Without the
	# relay the runner starts exactly as before.
	if [ -n "${KANBAN_BOARD_URL:-}" ] && [ -n "${KANBAN_RELAY_URL:-}" ]; then
		if ! { [ -f "${UI_DIR}/vibe-kanban.pid" ] && pid_is_ui "$(cat "${UI_DIR}/vibe-kanban.pid")" vibe-kanban; }; then
			VK_CREDENTIALS="$(dirname "${VK_CONFIG}")/credentials.json" "${AGENT_DIR}/vk-runner-signin.py" 2>&1 \
				| tee -a "${UI_DIR}/vk-runner-signin.log"
		fi
		start_ui vibe-kanban vibe-kanban / env \
			HOST="${UI_BACKEND_LISTEN_HOST}" PORT="${UI_PORT_VIBE_KANBAN}" \
			${VIBE_KANBAN_DATA_HOME:+"XDG_DATA_HOME=${VIBE_KANBAN_DATA_HOME}"} \
			VK_SHARED_API_BASE="${KANBAN_BOARD_URL}" VK_SHARED_RELAY_API_BASE="${KANBAN_RELAY_URL}" \
			/usr/local/bin/vibe-kanban
	else
		start_ui vibe-kanban vibe-kanban / env \
			HOST="${UI_BACKEND_LISTEN_HOST}" PORT="${UI_PORT_VIBE_KANBAN}" \
			${VIBE_KANBAN_DATA_HOME:+"XDG_DATA_HOME=${VIBE_KANBAN_DATA_HOME}"} \
			/usr/local/bin/vibe-kanban
	fi
fi

if [ "${UI_CLAUDE_MEM}" == "true" ]; then
	# The claude-mem viewer is served by the plugin's worker (worker-service.cjs under Bun) - the
	# process the plugin's own SessionStart hook spawns on demand with `start` (detached, as
	# `bun worker-service.cjs --daemon`, which is the long-running server itself). Started here so
	# the tile is up before the first Claude session, and kept up (CLAUDE_MEM_IDLE_EXIT_SEC=0: the
	# worker otherwise exits when idle, and the tile would read down between sessions). Loopback
	# only - nginx is the exposure (host route claude-mem.localhost: the viewer fetches
	# root-absolute /api/ and /stream paths). Memory data stays in /home/agent/.claude-mem (persisted
	# agent state). Newest installed plugin version wins, the way the hook itself resolves it.
	CLAUDE_MEM_PLUGIN_DIR=${CLAUDE_MEM_PLUGIN_DIR:-$(ls -d "${HOME}"/.claude/plugins/cache/thedotmack/claude-mem/[0-9]*/ 2>/dev/null | sort -V | tail -1)}
	CLAUDE_MEM_WORKER=${CLAUDE_MEM_PLUGIN_DIR%/}/scripts/worker-service.cjs
	BUN_BIN=${BUN_BIN:-/usr/local/bin/bun}
	[ -x "${BUN_BIN}" ] || BUN_BIN=$(command -v bun)
	if [ ! -f "${CLAUDE_MEM_WORKER}" ]; then
		echo "claude-mem: not started - no claude-mem plugin under ${HOME}/.claude/plugins/cache/thedotmack/claude-mem (setup/install-plugins.sh installs it)"
	elif [ -z "${BUN_BIN}" ]; then
		echo "claude-mem: not started - bun not found (setup/install-bun.sh installs it at /usr/local/bin/bun); set BUN_BIN"
	else
		# A worker the plugin's hook already started (a Claude session ran before this script)
		# is adopted rather than raced for the port: its /health names its pid, and that pid is
		# trusted only when its command line is the worker's. start_ui then leaves it alone.
		if ! pid_is_ui "$(cat "${UI_DIR}/claude-mem.pid" 2>/dev/null)" worker-service.cjs; then
			CM_PID=$(curl -s --max-time 2 "http://127.0.0.1:${UI_PORT_CLAUDE_MEM}/health" 2>/dev/null | sed -nE 's/.*"pid":([0-9]+).*/\1/p')
			if pid_is_ui "${CM_PID}" worker-service.cjs; then
				echo "${CM_PID}" > "${UI_DIR}/claude-mem.pid"
				echo "claude-mem: adopted the worker already serving 127.0.0.1:${UI_PORT_CLAUDE_MEM} (pid ${CM_PID}, started by the plugin's hook)"
			fi
		fi
		start_ui claude-mem worker-service.cjs / env \
			CLAUDE_MEM_WORKER_HOST=127.0.0.1 CLAUDE_MEM_WORKER_PORT="${UI_PORT_CLAUDE_MEM}" \
			CLAUDE_MEM_IDLE_EXIT_SEC=0 \
			"${BUN_BIN}" "${CLAUDE_MEM_WORKER}" --daemon
	fi
fi

if [ "${UI_LOGLEARNER}" == "true" ]; then
	# The LogLearner dashboard over the agent's own sessions, through /agent/loglearner-serve.sh
	# (first index, periodic refresh, then the stdlib dashboard on 127.0.0.1 - the app has no
	# other bind, nginx is the exposure on the host route loglearner.localhost). The serve script
	# is the session leader start_ui records, so ui-stop.sh's group signal takes the indexer
	# loop down with the dashboard.
	LOGLEARNER_DIR=${LOGLEARNER_DIR:-/opt/loglearner}
	if [ ! -f "${LOGLEARNER_DIR}/dashboard/app.py" ]; then
		echo "loglearner: not started - no vendored dashboard at ${LOGLEARNER_DIR}/dashboard/app.py (the image ships it; setup/install-loglearner.sh)"
	else
		start_ui loglearner "loglearner/dashboard/app.py\|loglearner-serve.sh" / env LOGLEARNER_DIR="${LOGLEARNER_DIR}" \
			"${AGENT_DIR}/loglearner-serve.sh"
	fi
fi

if [ "${UI_LOOP}" == "true" ]; then
	# The Agent loop page: /agent/loop-view.py renders the autonomy loop's state files (loop.state, loop.log,
	# notes.md, fires/, the goals file) into ${UI_DIR}/loop every few seconds and serves them on 127.0.0.1. It never
	# writes the loop's directory or takes its lock itself; its two Control actions (UI_LOOP_CONTROL) run the loop's own
	# loop-start.sh and loop-stop.sh. nginx is the exposure (host route loop.localhost); the tile's dot is its /health,
	# 2xx only while the page's data is fresh. Before the home proxy, so the dot is up when the page first loads.
	start_ui loop-view loop-view.py / python3 "${AGENT_DIR}/loop-view.py" --port "${UI_PORT_LOOP}"
fi

if [ "${UI_HOME}" == "true" ]; then
	# The Knowledge transfer page (docs/manual/memory.md "Moving knowledge between instances"): /agent/knowledge-transfer.py exports the knowledge
	# stores as one pack file and imports a pack, on 127.0.0.1; the home proxy routes it at /knowledge/, so it runs with
	# the home page. It writes nothing until a pack is imported, and then only the LogLearner bank (through the runtime's
	# loader), the memory API and KNOWLEDGE_IMPORTED_DIR
	if [ -f "${AGENT_DIR}/knowledge-transfer.py" ]; then
		start_ui knowledge knowledge-transfer.py / python3 "${AGENT_DIR}/knowledge-transfer.py" serve --port "${UI_PORT_KNOWLEDGE}"
	else
		echo "knowledge: not started - no ${AGENT_DIR}/knowledge-transfer.py"
	fi
fi

if [ "${UI_VIBE_KANBAN}" == "true" ] && [ -n "${KANBAN_BOARD_URL}" ]; then
	# The self-hosted board's one-click sign-in: the home page's Kanban board tile lands on the board already signed
	# in. Bound to 127.0.0.1 only; the home proxy routes it on kanban.localhost (see /agent/kanban-signin.py)
	start_ui kanban-signin kanban-signin.py / env UI_PORT_KANBAN_SIGNIN="${UI_PORT_KANBAN_SIGNIN}" \
		python3 "${AGENT_DIR}/kanban-signin.py"
	# The board's first view, before any fire: this instance's project with its columns and a card per goal (the
	# shipped default goals while there is no goals file). In the background and best effort: it waits for the board
	# (KANBAN_SEED_WAIT, default 300 s), then exits; a board that never answers only leaves a line in its log.
	# Its exit status goes to kanban-seed.done, this start's only: once the seed ends its pid tells nothing (an init
	# that does not reap keeps it as a zombie)
	rm -f "${UI_DIR:?}/kanban-seed.done"
	start_ui kanban-seed "kanban-sync.py seed" / python3 "${AGENT_DIR}/kanban-sync.py" seed \
		--done "${UI_DIR}/kanban-seed.done"
	# The board watcher: what a user does on the board between fires (a card to Done, a new card, an edit) reaches
	# the goals file every KANBAN_WATCH_INTERVAL seconds (default 30) while the loop is not firing - kanban-sync.py
	# watch, two-way like the fire hooks (docs/manual/boards.md "Kanban board")
	start_ui kanban-watch "kanban-sync.py watch" / python3 "${AGENT_DIR}/kanban-sync.py" watch
fi

if [ "${UI_TMUX}" == "true" ]; then
	# Browser terminal attached to the shared tmux session: attach-or-create ("-A") so
	# the operator always lands in the same session the agent can be driven in - normally
	# the session /agent/tmux-session-start.sh created at container start with claude
	# running in it (-A still self-heals by creating one if it was killed).
	# WRITABLE by default (UI_TMUX_WRITABLE=false for watch-only). The flag spelling differs by
	# ttyd line: 1.6.x (ubuntu's apt package) is writable unless -R/--readonly, 1.7+ (the pinned
	# upstream fallback) is read-only unless -W/--writable, and each line only knows its own flag.
	# Detected from the installed binary's own option list rather than from a parsed version
	# string: a distro build's version line is not a reliable statement of which flag it takes,
	# and passing the wrong one either fails the start or silently flips the mode.
	TTYD_OPTIONS=$(ttyd --help 2>&1)
	TTYD_MODE_ARGS=""
	if [ "${UI_TMUX_WRITABLE}" == "true" ]; then
		# a ttyd with --writable is read-only until told otherwise; one without is already writable
		echo "${TTYD_OPTIONS}" | grep -q -- '--writable' && TTYD_MODE_ARGS="-W"
	else
		# a ttyd with --readonly is writable until told otherwise; one without is already read-only
		echo "${TTYD_OPTIONS}" | grep -q -- '--readonly' && TTYD_MODE_ARGS="-R"
	fi
	# ttyd binds an interface, not an address: map the loopback listen host onto lo
	TTYD_IFACE_ARGS=""
	if [ "${UI_BACKEND_LISTEN_HOST}" == "127.0.0.1" ]; then
		TTYD_IFACE_ARGS="-i lo"
	fi
	# The page URL may name a session (/tmux/?arg=<session>, ?arg=pick for the menu): --url-arg hands each arg= to
	# /agent/tmux-attach.sh as one argument word, which attaches only to a session of this container's own tmux server;
	# with none, the agent session as before.
	# -O (--check-origin): ttyd accepts a websocket only when its Origin names the host it was sent to, so a page the
	# operator visits in the same browser cannot open ws://localhost:<port>/tmux/ws and type into the agent's shell
	# (cross-site WebSocket hijacking). The proxy refuses such a request before ttyd sees it (home-render.sh's
	# same-origin gate); ttyd's own check also covers a client that reaches its port directly. Both ttyd lines know the
	# option; a ttyd that does not is not started at all - the writable terminal is never served without the check.
	if echo "${TTYD_OPTIONS}" | grep -q -- '--check-origin'; then
		start_ui tmux ttyd / ttyd -p "${UI_PORT_TMUX}" -b /tmux --url-arg -O \
			${TTYD_IFACE_ARGS} ${TTYD_MODE_ARGS} \
			env AGENT_TMUX_SESSION_NAME="${AGENT_TMUX_SESSION_NAME:-agent}" "${AGENT_DIR}/tmux-attach.sh"
	else
		echo "tmux: ERROR - not started: this ttyd ($(command -v ttyd)) has no --check-origin option, and the browser terminal is never served without its origin check" >&2
	fi
fi

if [ "${UI_CHAT}" == "true" ]; then
	# The Agent chat page (docs/manual/ui.md "Agent chat"): the shared agent session's pane in the browser, and a box that types
	# a message at the agent's prompt - /agent/agent-chat.py, bound to 127.0.0.1 only; the home proxy routes
	# chat.localhost to it and the home page's "Agent chat" tile opens it. Started before the proxy, so the route has its
	# upstream from the first page load. It follows the terminal's mode: with UI_TMUX_WRITABLE=false the page still shows
	# the pane and its send box is off (the backend refuses a send)
	start_ui agent-chat agent-chat.py / env UI_PORT_CHAT="${UI_PORT_CHAT}" \
		AGENT_TMUX_SESSION_NAME="${AGENT_TMUX_SESSION_NAME:-agent}" UI_TMUX_WRITABLE="${UI_TMUX_WRITABLE}" \
		python3 "${AGENT_DIR}/agent-chat.py"
fi

# The Plane tile's one-click sign-in (docs/manual/boards.md "Plane board"): started before the proxy that forwards it its one
# URL, so the tile works from the first page load. The board is optional and off by default (UI_PLANE=false, AGPL-3.0):
# off, none of the three Plane processes below (the sign-in, the seed, the Board) starts
if [ "${UI_PLANE:-false}" == "true" ] && [ -n "${PLANE_URL}" ] && [ "${PLANE_LOGIN_BYPASS:-true}" == "true" ]; then
	start_ui plane-signin plane-signin.py / python3 "${AGENT_DIR}/plane-signin.py"
fi
# The board's first view, before any fire (docs/manual/boards.md "Plane board"): the goals as work items in the project that
# ./plane.sh seed created - the shipped default goals while there is no goals file - so a new instance's board shows
# the goal its loop fires on. In the background and best effort: it waits for the board (PLANE_SEED_WAIT, default
# 300 s), then exits; a board that never answers only leaves a line in its log. Its exit status goes to
# plane-seed.done, this start's only: once the seed ended, its pid tells nothing (an init that does not reap keeps it
# as a zombie)
if [ "${UI_PLANE:-false}" == "true" ] && [ -n "${PLANE_URL}" ]; then
	rm -f "${UI_DIR:?}/plane-seed.done"
	start_ui plane-seed "plane-sync.py seed" / python3 "${AGENT_DIR}/plane-sync.py" seed \
		--done "${UI_DIR}/plane-seed.done"
fi

# The Board (docs/manual/boards.md "Board"): a read-only kanban view of this harness's own Plane project, read with the agent's API
# key from the board's secrets file (PLANE_AUTH_FILE, on the /wd volume - never on this command line), with the agent
# runner's attempts on the cards; only with the Plane board on this target. Before the proxy, so the tile works from the
# first page load; its first pass runs in the background, so nothing here waits for Plane
if [ "${UI_BOARD}" == "true" ] && [ "${UI_PLANE:-false}" == "true" ] && [ -n "${PLANE_URL}" ]; then
	start_ui board board-server.py / env UI_PORT_BOARD="${UI_PORT_BOARD}" UI_BACKEND_LISTEN_HOST="${UI_BACKEND_LISTEN_HOST}" \
		python3 "${AGENT_DIR}/board-server.py"
fi

# The Files tile (docs/manual/ui.md "Files"): the shared folder FILES_DIR between the person and the agent, created here so the
# agent can write into it from the first start; the server lists, uploads into, downloads from, renames, moves and deletes
# inside it and nowhere else. Before the proxy, so the tile works from the first page load
if [ "${UI_FILES}" == "true" ]; then
	mkdir -p "${FILES_DIR}" 2>/dev/null || echo "files: WARNING - ${FILES_DIR} could not be created; the Files tile's dot reads down until it exists"
	start_ui files files-server.py / env UI_PORT_FILES="${UI_PORT_FILES}" UI_BACKEND_LISTEN_HOST="${UI_BACKEND_LISTEN_HOST}" \
		FILES_DIR="${FILES_DIR}" FILES_MAX_UPLOAD_MB="${FILES_MAX_UPLOAD_MB}" python3 "${AGENT_DIR}/files-server.py"
fi

if [ "${UI_HOME}" == "true" ]; then
	# Fail loud when the home port is already held by a foreign process - nginx would die
	# on bind and the harness front door would be silently absent. A re-run with our own
	# proxy already up is fine (start_ui leaves a live pid untouched).
	if ! pid_is_ui "$(cat "${UI_DIR}/home.pid" 2>/dev/null)" nginx \
		&& (exec 3<>"/dev/tcp/127.0.0.1/${UI_PORT_HOME}") 2>/dev/null; then
		echo "home: ERROR - something already listens on port ${UI_PORT_HOME} inside the container:"
		ss -ltnp 2>/dev/null | grep -F ":${UI_PORT_HOME} " || echo "home: (ss not available to name the process)"
		echo "home: set PORT_INTERNAL_HOME in .env (UI_PORT_HOME here) to a free port and re-run"
		exit 1
	fi
	# Render the home page + proxy config from the flags above, then front everything
	# with nginx on the single home port (see docs/manual/ui.md "Home page and reverse proxy")
	"${AGENT_DIR}/home-render.sh"
	start_ui home nginx / nginx -c "${UI_DIR}/home/nginx.conf" -g "daemon off;"
	# the allow list follows the default route: a network connected to the RUNNING container moves the
	# default route (and the source of the host's published-port traffic) to the new network's gateway
	start_ui home-watch home-route-watch.sh / "${AGENT_DIR}/home-route-watch.sh"
fi

# The agent sessions (docs/manual/agents.md "Spoke agents") are not UIs, but each has a home tile: one row for the supervisor and
# one per session, as its last pass saw them. The supervisor itself starts with the container (startup.sh), not here, so
# it runs with every UI off. Before the dashboard block, and never in the exit status: that stays the UIs'.
if [ -x "${AGENT_DIR}/supervisor.sh" ]; then
	"${AGENT_DIR}/supervisor.sh" status
else
	echo "supervisor: not installed (no ${AGENT_DIR}/supervisor.sh)"
fi

if [ "${UI_TMUX_AGENT}" == "true" ]; then
	# AFTER the home proxy on purpose: with TMUX_AGENT_SRC set the first start builds the
	# dashboard from source (git fetch + npm ci + tsc, minutes on a cold /wd), and the front door
	# must not wait for it - the tile reads down until the build lands and up from the next probe
	# on. The default serves the build vendored into the image, which is there before anything
	# starts; it is checked by file, there is nothing to install and no stamp.
	if [ -z "${TMUX_AGENT_SRC}" ]; then
		TMUX_AGENT_JS=${TMUX_AGENT_VENDORED_DIR}/dist/bin/tmux-agent.js
		tmux_agent_installed()
		{
			[ -f "${TMUX_AGENT_JS}" ]
		}
		TMUX_AGENT_NOT_STARTED="not started - vendored build missing at ${TMUX_AGENT_JS} (the image ships it there: rebuild the image with Container-Root/opt/tmux-agent present, or set TMUX_AGENT_SRC to build from a source)"
	else
		# Installed into TMUX_AGENT_INSTALL_DIR (the /wd volume) so later starts skip the build.
		# The build is trusted only through the stamp the installer writes as its LAST step: it
		# must name the TMUX_AGENT_REF and TMUX_AGENT_SRC asked for now, so a changed ref or source
		# is re-installed, and a failed or interrupted install (no stamp - tsc emits dist/ even when
		# type-checking fails) is retried on the next start and never served. The source is
		# compared in the installer's masked form (user:token@ -> ***@), the only form it writes,
		# so a rotated token is the same source. A failed install leaves the other UIs untouched
		# and names its fix in the log.
		TMUX_AGENT_JS=${TMUX_AGENT_INSTALL_DIR}/dist/bin/tmux-agent.js
		TMUX_AGENT_STAMP=${TMUX_AGENT_INSTALL_DIR}/.install-stamp
		TMUX_AGENT_SRC_SHOWN=$(echo "${TMUX_AGENT_SRC}" | sed -E 's#(://)[^/@[:space:]]+@#\1***@#g')
		tmux_agent_installed()
		{
			[ -f "${TMUX_AGENT_JS}" ] \
				&& grep -qxF "ref=${TMUX_AGENT_REF}" "${TMUX_AGENT_STAMP}" 2>/dev/null \
				&& grep -qxF "source=${TMUX_AGENT_SRC_SHOWN}" "${TMUX_AGENT_STAMP}" 2>/dev/null
		}
		if ! tmux_agent_installed; then
			echo "tmux-agent: no finished install of ${TMUX_AGENT_REF} from TMUX_AGENT_SRC at ${TMUX_AGENT_INSTALL_DIR} - installing (log ${UI_DIR}/tmux-agent-install.log)"
			echo "=== $(date -u +%FT%TZ) install-tmux-agent.sh ===" >> "${UI_DIR}/tmux-agent-install.log"
			TMUX_AGENT_SRC="${TMUX_AGENT_SRC}" TMUX_AGENT_REF="${TMUX_AGENT_REF}" \
				"${AGENT_DIR}/install-tmux-agent.sh" >> "${UI_DIR}/tmux-agent-install.log" 2>&1 \
				|| tail -1 "${UI_DIR}/tmux-agent-install.log" >&2
		fi
		TMUX_AGENT_NOT_STARTED="not started - install failed (see ${UI_DIR}/tmux-agent-install.log; the next ui-start.sh retries it)"
	fi
	if ! tmux_agent_installed; then
		echo "tmux-agent: ${TMUX_AGENT_NOT_STARTED}"
	elif [ -z "${NODE_BIN}" ]; then
		echo "tmux-agent: not started - node not found (looked at /usr/local/bin/node and PATH); set NODE_BIN"
	else
		# Loopback only - nginx is the exposure (the pre-wired /tmux-agent/ route, with the
		# Host/Origin rewrite the dashboard's own DNS-rebinding guard needs; see
		# home-render.sh). --no-token: the dashboard mints and requires a URL token by
		# default, which would make the proxied route answer 401 - the harness fronts every
		# UI, the writable terminal included, unauthenticated behind the loopback-published
		# home port and the SSH tunnel, and the dashboard rides that same boundary.
		# --strict-port: the dashboard otherwise scans forward from a busy port, which
		# would silently leave the proxy route pointing at nothing.
		# The dashboard watches its own isolated tmux socket (-L tmux-agent) by default,
		# while the harness's shared "agent" session lives on the DEFAULT tmux server, so
		# it is pointed there (tmux-agent's "adoption mode", its own TMUX_AGENT_DEFAULT_SERVER
		# switch) unless the operator names a socket with the dashboard's own TMUX_AGENT_SOCKET.
		TMUX_AGENT_SERVER_ENV="TMUX_AGENT_DEFAULT_SERVER=${TMUX_AGENT_DEFAULT_SERVER:-1}"
		[ -n "${TMUX_AGENT_SOCKET}" ] && TMUX_AGENT_SERVER_ENV="TMUX_AGENT_SOCKET=${TMUX_AGENT_SOCKET}"
		# Watch-only harness (UI_TMUX_WRITABLE=false): the dashboard's send box types into the
		# same sessions as the terminal, so it gets tmux-agent's own read-only policy for its
		# web surface (the send box, the dashboard's only write, then answers 403). Writable,
		# no policy is passed and the dashboard's own default applies.
		TMUX_AGENT_POLICY_ENV=""
		if [ "${UI_TMUX_WRITABLE}" != "true" ]; then
			echo '{"surfaces":{"web":{"readOnly":true}}}' > "${UI_DIR}/tmux-agent-policy.json"
			TMUX_AGENT_POLICY_ENV="TMUX_AGENT_POLICY=${UI_DIR}/tmux-agent-policy.json"
		fi
		# The dashboard's state home on the /wd volume, where /agent/tmux-session-start.sh writes the agent
		# pane's capture log (<home>/logs/<session>.log: the dashboard's log bytes and log tail), and the
		# harness's lexicon (/agent/tmux-agent-lexicon.json), whose profile classifies the agent's claude pane
		# also when it is idle and reads its context % from the statusline /agent/claude-statusline.sh draws.
		TMUX_AGENT_HOME=${TMUX_AGENT_HOME:-$([ -d /wd ] && echo /wd/tmux-agent-home || echo "${HOME}/.tmux-agent")}
		TMUX_AGENT_LEXICON=${TMUX_AGENT_LEXICON:-${AGENT_DIR}/tmux-agent-lexicon.json}
		# env -u: TMUX_AGENT_SRC may carry a token and only the installer needs it
		start_ui tmux-agent tmux-agent.js / env -u TMUX_AGENT_SRC ${TMUX_AGENT_POLICY_ENV} \
			"TMUX_AGENT_HOME=${TMUX_AGENT_HOME}" "TMUX_AGENT_LEXICON=${TMUX_AGENT_LEXICON}" \
			"${TMUX_AGENT_SERVER_ENV}" "${NODE_BIN}" "${TMUX_AGENT_JS}" web \
			--port "${UI_PORT_TMUX_AGENT}" --host 127.0.0.1 --no-token --strict-port
	fi
fi

# The Loop Deck's harness-mode inputs for this harness's own loops (/wd/loop-deck, see /agent/loop-deck-adapter.py): written
# once at UI start from what the loops have left behind, and after every fire by loop.sh; best effort, never fatal here
if [ -f "$(dirname "$0")/loop-deck-adapter.py" ]; then
	timeout 30 python3 -I "$(dirname "$0")/loop-deck-adapter.py" >> "${UI_DIR}/loop-deck-adapter.log" 2>&1 || echo "ui-start: loop-deck-adapter.py exited $? (see ${UI_DIR}/loop-deck-adapter.log); the UIs are unaffected"
fi

# The Loop Deck itself: the vendored release (/opt/loop-deck, VENDORED.md) in harness mode over that data directory, bound to
# 127.0.0.1 and routed as loop-deck.localhost by the home proxy, with its actions off - started by /agent/loop-deck-start.sh,
# the script the supervisor runs again when the server's process is gone; the adapter above already ran the generator, so
# out/ exists before the server starts. Its exit status is not this script's: without the vendored Deck its line says so
# and the other UIs are unaffected
LOOP_DECK_DIR=${LOOP_DECK_DIR:-/opt/loop-deck}
LOOP_DECK_DATA_DIR=${LOOP_DECK_DATA_DIR:-/wd/loop-deck}
if [ "${UI_LOOP_DECK}" == "true" ]; then
	UI_DIR="${UI_DIR}" UI_PORT_LOOP_DECK="${UI_PORT_LOOP_DECK}" LOOP_DECK_DIR="${LOOP_DECK_DIR}" LOOP_DECK_DATA_DIR="${LOOP_DECK_DATA_DIR}" \
		"$(dirname "$0")/loop-deck-start.sh" || true
fi
