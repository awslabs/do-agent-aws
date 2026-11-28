#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Harness UIs - show the honest state of each web UI.
#
# For every UI this prints one line: whether its process is alive AND whether it actually
# answers HTTP on its port - a pid without an answering port is reported as such, never as
# up. A pid only counts when its command line matches the UI it claims to be (pidfiles
# survive container recreation on the /wd volume while pids are namespace-local, so a
# stale pidfile can point at an unrelated recycled pid). Exit code is 0 when every enabled
# UI answers, 1 otherwise, so the script doubles as a probe.

UI_HEADLAMP=${UI_HEADLAMP:-true}
UI_HINDSIGHT=${UI_HINDSIGHT:-true}
UI_VIBE_KANBAN=${UI_VIBE_KANBAN:-true}
UI_TMUX=${UI_TMUX:-true}
UI_TMUX_AGENT=${UI_TMUX_AGENT:-true}
UI_CLAUDE_MEM=${UI_CLAUDE_MEM:-true}
UI_LOGLEARNER=${UI_LOGLEARNER:-true}
UI_CHAT=${UI_CHAT:-true}
UI_LOOP=${UI_LOOP:-true}
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
UI_PORT_LOOP=${UI_PORT_LOOP:-7790}
UI_PORT_HOME=${UI_PORT_HOME:-8000}
UI_PORT_KANBAN_SIGNIN=${UI_PORT_KANBAN_SIGNIN:-8092}
UI_PORT_KNOWLEDGE=${UI_PORT_KNOWLEDGE:-8097}
UI_BOARD=${UI_BOARD:-true}
UI_PORT_BOARD=${UI_PORT_BOARD:-8096}
UI_FILES=${UI_FILES:-true}
UI_PORT_FILES=${UI_PORT_FILES:-8098}
UI_LOOP_DECK=${UI_LOOP_DECK:-true}
UI_PORT_LOOP_DECK=${UI_PORT_LOOP_DECK:-8091}
UI_DIR=${UI_DIR:-/wd/ui}
TMUX_AGENT_INSTALL_DIR=${TMUX_AGENT_INSTALL_DIR:-/wd/ui/tmux-agent}
# empty TMUX_AGENT_SRC (the default) = the vendored build the image ships; see ui-start.sh
TMUX_AGENT_VENDORED_DIR=${TMUX_AGENT_VENDORED_DIR:-/opt/tmux-agent}
TMUX_AGENT_SRC=${TMUX_AGENT_SRC:-}
TMUX_AGENT_REF=${TMUX_AGENT_REF:-master}

RC=0

pid_is_ui()
{
	PID=$1
	MATCH=$2
	[ -n "${PID}" ] && [ -d "/proc/${PID}" ] && tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null | grep -q "${MATCH}"
}

status_ui()
{
	NAME=$1
	MATCH=$2
	ENABLED=$3
	PORT=$4
	PATH_SUFFIX=$5
	PID_FILE=${UI_DIR}/${NAME}.pid
	PID=""
	[ -f "${PID_FILE}" ] && PID=$(cat "${PID_FILE}")
	ALIVE=false
	pid_is_ui "${PID}" "${MATCH}" && ALIVE=true
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}${PATH_SUFFIX}" 2>/dev/null)
	if [ "${ALIVE}" == "true" ] && [ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null; then
		echo "${NAME}: UP pid=${PID} http=${HTTP} port=${PORT}"
	elif [ "${ALIVE}" == "true" ]; then
		echo "${NAME}: STARTING-OR-UNHEALTHY pid=${PID} http=${HTTP:-000} port=${PORT} (process alive, port not answering)"
		[ "${ENABLED}" == "true" ] && RC=1
	elif [ "${ENABLED}" == "true" ]; then
		echo "${NAME}: DOWN port=${PORT}"
		RC=1
	else
		echo "${NAME}: DISABLED"
	fi
}

# Behind the home proxy (UI_HOME=true) headlamp serves under its base path and the API
# probe path stays the app's own /docs on the direct port either way
HEADLAMP_PATH=/
[ "${UI_HOME}" == "true" ] && HEADLAMP_PATH=/headlamp/

status_ui headlamp      headlamp-server         "${UI_HEADLAMP}"    "${UI_PORT_HEADLAMP}"      "${HEADLAMP_PATH}"
status_ui hindsight-api hindsight-api           "${UI_HINDSIGHT}"   "${UI_PORT_HINDSIGHT_API}" /docs
status_ui hindsight-ui  next-server             "${UI_HINDSIGHT}"   "${UI_PORT_HINDSIGHT_UI}"  /
# the default seed's extraction state (written by /agent/hindsight-seed.sh after the items are accepted): a memory
# API that is UP but cannot call Bedrock extracts nothing - that reads here as FAILED with its cause, and exits 1
SEED_STATE_FILE=${HINDSIGHT_SEED_STATE:-${UI_DIR}/hindsight-seed.state}
if [ "${UI_HINDSIGHT}" == "true" ] && [ -f "${SEED_STATE_FILE}" ]; then
	SEED_STATE=$(sed -n 's/^state=//p' "${SEED_STATE_FILE}")
	SEED_DOCS=$(sed -n 's/^documents=//p' "${SEED_STATE_FILE}")
	SEED_REASON=$(sed -n 's/^reason=//p' "${SEED_STATE_FILE}")
	SEED_WATCH=$(sed -n 's/^watch=//p' "${SEED_STATE_FILE}")
	case "${SEED_STATE}" in
		complete)   echo "hindsight-seed: COMPLETE documents=${SEED_DOCS}" ;;
		accepted)   if [ "${SEED_WATCH}" == "off" ]; then echo "hindsight-seed: ACCEPTED documents=${SEED_DOCS} (the extraction watch is off: HINDSIGHT_SEED_EXTRACTION_WAIT=0; /stats shows the extraction)"; else echo "hindsight-seed: ACCEPTED documents=${SEED_DOCS} (watching for the first extracted memory)"; fi ;;
		extracting) echo "hindsight-seed: EXTRACTING documents=${SEED_DOCS}" ;;
		failed)     echo "hindsight-seed: FAILED documents=${SEED_DOCS} - ${SEED_REASON} (fix it and restart; docs/manual/aws.md 'AWS credentials', 'Bedrock connectivity')"; RC=1 ;;
		*)          echo "hindsight-seed: ${SEED_STATE^^} documents=${SEED_DOCS}${SEED_REASON:+ - ${SEED_REASON}}" ;;
	esac
fi
status_ui vibe-kanban   vibe-kanban             "${UI_VIBE_KANBAN}" "${UI_PORT_VIBE_KANBAN}"   /
status_ui tmux          ttyd                    "${UI_TMUX}"        "${UI_PORT_TMUX}"          /tmux/
# the Agent chat page: /healthz answers while its backend runs (the page says what the agent session's pane is doing)
status_ui agent-chat    agent-chat.py           "${UI_CHAT}"        "${UI_PORT_CHAT}"          /healthz
status_ui home          nginx                   "${UI_HOME}"        "${UI_PORT_HOME}"          /
# the home listener's route watcher (no port of its own): alive = the allow list follows the default route
WATCH_PID=$(cat "${UI_DIR}/home-watch.pid" 2>/dev/null)
if pid_is_ui "${WATCH_PID}" home-route-watch.sh; then
	echo "home-watch: UP pid=${WATCH_PID} gateways=$(tr '\n' ' ' < "${UI_DIR}/home-watch.gateways" 2>/dev/null | sed 's/ $//') (re-renders the allow list when the default route moves)"
elif [ "${UI_HOME}" == "true" ] && [ -z "${UI_HOME_GATEWAY}" ]; then
	echo "home-watch: DOWN (the allow list will not follow a default-route change until /agent/ui-start.sh runs again)"
	RC=1
else
	echo "home-watch: DISABLED"
fi
status_ui tmux-agent    tmux-agent.js           "${UI_TMUX_AGENT}"  "${UI_PORT_TMUX_AGENT}"    /
status_ui claude-mem    worker-service.cjs      "${UI_CLAUDE_MEM}"  "${UI_PORT_CLAUDE_MEM}"    /
status_ui loglearner    "loglearner/dashboard/app.py\|loglearner-serve.sh" "${UI_LOGLEARNER}"  "${UI_PORT_LOGLEARNER}"    /
# the Agent loop page's renderer: /health answers 2xx only while the page's data is fresh, so a renderer that stopped
# writing is not UP
status_ui loop-view     loop-view.py            "${UI_LOOP}"        "${UI_PORT_LOOP}"          /health
# the Loop Deck (the vendored /opt/loop-deck in harness mode, ui-start.sh): its server's /status.json, the file the home
# page's Loop Deck dot probes
status_ui loop-deck     deck-server.py          "${UI_LOOP_DECK}"   "${UI_PORT_LOOP_DECK}"     /status.json
# the Knowledge transfer page's server runs with the home page (its route is the home listener's /knowledge/)
status_ui knowledge     knowledge-transfer.py   "${UI_HOME}"        "${UI_PORT_KNOWLEDGE}"     /health
# the kanban board's one-click sign-in runs only with the board (KANBAN_BOARD_URL); /healthz signs nobody in
KANBAN_SIGNIN_ON=false
[ "${UI_VIBE_KANBAN}" == "true" ] && [ -n "${KANBAN_BOARD_URL}" ] && KANBAN_SIGNIN_ON=true
status_ui kanban-signin kanban-signin.py        "${KANBAN_SIGNIN_ON}" "${UI_PORT_KANBAN_SIGNIN}" /healthz

# The self-hosted Plane board runs in sidecar containers (docs/manual/boards.md "Plane board"), so it has no pid here: it counts
# as up when its proxy at PLANE_URL serves /api/instances/ with is_setup_done true - the SERVED value Plane's web
# app gates the whole app on (false means Plane's own setup wizard shows; the seed was not applied). The Plane
# tile's one-click sign-in (plane-signin.py) is a process of this container and is checked like the UIs above.
# The request is anonymous, so Plane counts it against the agent container's own address (it allows 30 anonymous calls
# a minute per caller), the address the sign-in's CSRF request is counted against too. It keeps that address on
# purpose: the Agent loop page runs this script once per LOOP_VIEW_SERVICES_INTERVAL (30 s by default, never under
# 5 s), 2 calls a minute that leave the sign-in about 28. The home page's Plane dot, once per 15 s in every open home
# tab, sends the browser's address instead (home-render.sh). The board is optional and off by default (AGPL-3.0 -
# docs/manual/boards.md "Plane board"): off, its row and the Board's say so with the flag, keeping the DISABLED word the Agent loop
# page's services panel parses (loop-view.py)
UI_PLANE=${UI_PLANE:-false}
PLANE_URL=${PLANE_URL:-}
PLANE_LOGIN_BYPASS=${PLANE_LOGIN_BYPASS:-true}
UI_PORT_PLANE_SIGNIN=${UI_PORT_PLANE_SIGNIN:-8090}
if [ "${UI_PLANE}" == "true" ] && [ -n "${PLANE_URL}" ]; then
	PLANE_BODY=$(curl -s --noproxy '*' --max-time 5 -w '\n%{http_code}' "${PLANE_URL%/}/api/instances/" 2>/dev/null)
	PLANE_HTTP=${PLANE_BODY##*$'\n'}
	PLANE_SETUP=$(echo "${PLANE_BODY%$'\n'*}" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(str((d.get("instance") or d).get("is_setup_done")).lower())' 2>/dev/null)
	if [ "${PLANE_HTTP}" == "200" ] && [ "${PLANE_SETUP}" == "true" ]; then
		echo "plane: UP http=${PLANE_HTTP} setup_done=true url=${PLANE_URL} (sidecar containers)"
	elif [ "${PLANE_HTTP}" == "200" ]; then
		echo "plane: NOT-SET-UP http=${PLANE_HTTP} setup_done=${PLANE_SETUP:-?} url=${PLANE_URL} (Plane's setup wizard shows; ./plane.sh seed on the host applies the seed)"
		RC=1
	else
		echo "plane: DOWN http=${PLANE_HTTP:-000} url=${PLANE_URL} (sidecar containers; ./plane.sh status on the host shows them)"
		RC=1
	fi
	status_ui plane-signin plane-signin.py      "${PLANE_LOGIN_BYPASS}" "${UI_PORT_PLANE_SIGNIN}" /healthz
elif [ "${UI_PLANE}" == "true" ]; then
	echo "plane: NOT CONFIGURED (no Plane sidecars on this target; ./run.sh with TO=docker runs them)"
else
	echo "plane: DISABLED (UI_PLANE=${UI_PLANE} - the Plane board is optional and off by default, AGPL-3.0; UI_PLANE=true in .env.local, then ./build.sh and ./stop.sh && ./run.sh, turns it on: docs/manual/boards.md \"Plane board\")"
fi
# The Board (docs/manual/boards.md "Board") reads the Plane board, so it runs only with it; its /healthz answers 200 only while its
# last pass is fresh and Plane answered, so a board that lost Plane is reported here as not answering
if [ "${UI_BOARD}" == "true" ] && [ "${UI_PLANE}" == "true" ] && [ -n "${PLANE_URL}" ]; then
	status_ui board         board-server.py         true                   "${UI_PORT_BOARD}"         /healthz
elif [ "${UI_BOARD}" == "true" ] && [ "${UI_PLANE}" == "true" ]; then
	echo "board: NOT CONFIGURED (the Board needs the Plane sidecars on this target: ./run.sh with TO=docker runs them)"
elif [ "${UI_BOARD}" == "true" ]; then
	echo "board: DISABLED (needs the Plane board, which is off: UI_PLANE=${UI_PLANE} - docs/manual/boards.md \"Plane board\")"
else
	echo "board: DISABLED"
fi
# the Files tile's server (docs/manual/ui.md "Files"): /healthz answers 200 while the shared folder exists and is writable
status_ui files         files-server.py         "${UI_FILES}"       "${UI_PORT_FILES}"         /healthz

# The tmux-agent dashboard comes from one of two places (the way ui-start.sh serves it):
# - TMUX_AGENT_SRC unset (the default): the build vendored into the image at /opt/tmux-agent.
#   Nothing to install; a DOWN row with the file missing is a broken image, not a setting.
# - TMUX_AGENT_SRC set: built from that source on first start (ui-start.sh runs
#   /agent/install-tmux-agent.sh when there is no finished install of the ref and source asked
#   for). Only a finished install leaves the installer's stamp - a dist/ left by a failed build
#   does not count - and it is checked the way ui-start.sh checks it (the ref, and the source in
#   its masked form), so a DOWN row with no matching stamp behind it is an install that has not
#   happened, has failed, or is for another ref or source: name the source setting it needs
if [ "${UI_TMUX_AGENT}" == "true" ]; then
	if [ -z "${TMUX_AGENT_SRC}" ]; then
		[ -f "${TMUX_AGENT_VENDORED_DIR}/dist/bin/tmux-agent.js" ] \
			|| echo "tmux-agent: vendored build missing at ${TMUX_AGENT_VENDORED_DIR}/dist/bin/tmux-agent.js (the image ships it there: rebuild the image with Container-Root/opt/tmux-agent present, or set TMUX_AGENT_SRC to build from a source)"
	else
		TMUX_AGENT_STAMP=${TMUX_AGENT_INSTALL_DIR}/.install-stamp
		TMUX_AGENT_SRC_SHOWN=$(echo "${TMUX_AGENT_SRC}" | sed -E 's#(://)[^/@[:space:]]+@#\1***@#g')
		if ! { [ -f "${TMUX_AGENT_INSTALL_DIR}/dist/bin/tmux-agent.js" ] \
			&& grep -qxF "ref=${TMUX_AGENT_REF}" "${TMUX_AGENT_STAMP}" 2>/dev/null \
			&& grep -qxF "source=${TMUX_AGENT_SRC_SHOWN}" "${TMUX_AGENT_STAMP}" 2>/dev/null; }; then
			echo "tmux-agent: not installed at ${TMUX_AGENT_INSTALL_DIR} (no finished install of ${TMUX_AGENT_REF} from TMUX_AGENT_SRC - see ${UI_DIR}/tmux-agent-install.log); source: TMUX_AGENT_SRC (set: the installer builds from it - any reachable clone works; unset it to serve the vendored build)"
		fi
	fi
fi

# The self-hosted kanban board runs in a sidecar container (docs/manual/boards.md "Kanban board"), so it has no pid here: it
# counts as up when the board server answers its own /v1/health at the URL the home proxy routes kanban.localhost
# to. Without KANBAN_BOARD_URL (no sidecar on this target) kanban.localhost serves the agent runner above.
KANBAN_BOARD_URL=${KANBAN_BOARD_URL:-}
if [ "${UI_VIBE_KANBAN}" == "true" ] && [ -n "${KANBAN_BOARD_URL}" ]; then
	# --noproxy: the sidecar is on the agent's own network, never behind a proxy from the environment
	HTTP=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 "${KANBAN_BOARD_URL%/}/v1/health" 2>/dev/null)
	if [ "${HTTP}" == "200" ]; then
		echo "kanban-board: UP http=${HTTP} url=${KANBAN_BOARD_URL} (sidecar container)"
	else
		echo "kanban-board: DOWN http=${HTTP:-000} url=${KANBAN_BOARD_URL} (sidecar container; ./kanban.sh status on the host shows it)"
		RC=1
	fi
elif [ "${UI_VIBE_KANBAN}" == "true" ]; then
	echo "kanban-board: NOT CONFIGURED (no board sidecar on this target; kanban.localhost serves the agent runner)"
else
	echo "kanban-board: DISABLED"
fi

# The docker spoke's build substrate runs in two sidecar containers (docs/manual/agents.md "Docker agent"), so it has no pid here:
# the daemon counts as up when buildctl's worker list answers at BUILDKIT_HOST (its socket, mounted at /run/buildkit),
# the registry when it answers /v2/ at BUILD_REGISTRY. Without them (no substrate on this target) both rows say so.
if [ "${SPOKE_DOCKER:-true}" != "true" ]; then
	echo "docker-buildkit: DISABLED"
	echo "docker-registry: DISABLED"
elif [ -z "${BUILDKIT_HOST}" ] || [ -z "${BUILD_REGISTRY}" ]; then
	if [ "${DOCKER_SUBSTRATE:-}" == "failed" ]; then
		# ./run.sh tried to start the substrate on this target and it did not come up (DOCKER_SUBSTRATE=failed)
		echo "docker-buildkit: DOWN - the build substrate did not come up at ./run.sh (./docker.sh status on the host shows the sidecars)"
		echo "docker-registry: DOWN - the build substrate did not come up at ./run.sh (./docker.sh status on the host shows the sidecars)"
		RC=1
	elif [ "${DOCKER_SUBSTRATE:-}" == "not-running" ]; then
		# ./run.sh -s started the agent container alone, and no running substrate was there to join (DOCKER_SUBSTRATE=not-running)
		echo "docker-buildkit: DOWN - the build substrate was not running at ./run.sh -s, which starts no sidecar (./docker.sh status on the host shows the sidecars; ./stop.sh -s && ./run.sh starts them)"
		echo "docker-registry: DOWN - the build substrate was not running at ./run.sh -s, which starts no sidecar (./docker.sh status on the host shows the sidecars; ./stop.sh -s && ./run.sh starts them)"
		RC=1
	else
		echo "docker-buildkit: NOT CONFIGURED (no build substrate on this target; ./run.sh with TO=docker starts it)"
		echo "docker-registry: NOT CONFIGURED (no build substrate on this target; ./run.sh with TO=docker starts it)"
	fi
else
	if WHY=$(timeout 15 buildctl --addr "${BUILDKIT_HOST}" --timeout 5 debug workers 2>&1 > /dev/null); then
		echo "docker-buildkit: UP addr=${BUILDKIT_HOST} (sidecar container)"
	else
		echo "docker-buildkit: DOWN addr=${BUILDKIT_HOST} - $(echo "${WHY}" | tail -1 | cut -c1-160) (sidecar container; ./docker.sh status on the host shows it)"
		RC=1
	fi
	# --noproxy: the registry is on the stack's own network, never behind a proxy from the environment
	HTTP=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 "http://${BUILD_REGISTRY}/v2/" 2>/dev/null)
	if [ "${HTTP}" == "200" ]; then
		echo "docker-registry: UP http=${HTTP} url=http://${BUILD_REGISTRY}/v2/ (sidecar container)"
	else
		echo "docker-registry: DOWN http=${HTTP:-000} url=http://${BUILD_REGISTRY}/v2/ (sidecar container; ./docker.sh status on the host shows it)"
		RC=1
	fi
fi

# The agent sessions (docs/manual/agents.md "Spoke agents"): a row for the supervisor - UP with the age of its last pass, STALE,
# DOWN, OFF - and one per session as its last pass saw it - OFF with the flag that turns a spoke on, STARTING, LIVE with
# its last cycle, STUCK or DOWN with the reason. An enabled session that is not live counts like a UI that is down; with
# SUPERVISOR=false the spokes' rows read OFF with that reason and count no more than the supervisor's own OFF row
SUPERVISOR_SH="$(cd "$(dirname "$0")" && pwd)/supervisor.sh"
if [ -x "${SUPERVISOR_SH}" ]; then
	"${SUPERVISOR_SH}" status || RC=1
else
	echo "supervisor: not installed (no ${SUPERVISOR_SH})"
fi

exit ${RC}
