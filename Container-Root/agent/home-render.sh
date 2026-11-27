#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Harness home page + reverse-proxy config renderer.
#
# Called by /agent/ui-start.sh (UI_HOME=true) before nginx starts; safe to re-run any time
# ("ui-start.sh" restart or a flag change picks the new config up). Renders, from the same
# UI enable flags the other scripts honor, into ${UI_DIR}/home:
#   nginx.conf         - one listener on UI_PORT_HOME proxying every ENABLED UI; a location
#                        block only exists for an enabled UI, so a disabled UI is not
#                        reachable through the proxy at all
#   proxy-common.conf  - shared proxy headers incl. websocket upgrade (streamlit, ttyd,
#                        headlamp and vibe-kanban all hold websockets open)
#   badge.conf         - sub_filter injecting the floating "home" badge into proxied
#                        text/html pages, so every UI links back to the home page
#   badge-host.conf    - the badge for the *.localhost host-routed UIs: same look, but the
#                        target is localhost:<the port the browser is on> (a bare "/" would
#                        resolve to the app's own root on those hostnames, not the home page)
#   badge-rule.conf    - badge.conf's rule alone (no sub_filter_once), for a location that
#                        runs its own sub_filter chain (the tmux-agent /api/ rewrite)
#   badge-host-nolink.conf - badge-host.conf without the stylesheet link, for a host-routed page this
#                        harness builds that links the sheet in its own <head>
#   badge-host-rule.conf - badge-host.conf's rule alone (no sub_filter_once), for a host-routed location that
#                        runs its own sub_filter chain (the memory API's locations on the dashboard's host)
#   badge-host-clear-<px>.conf - badge-host.conf with the route's badge clearance (--hs-badge-offset on the
#                        page's root), for a UI that keeps a control of its own in the badge's corner
#   badge-host-shift-<name>.conf - badge-host.conf with the badge moved aside (--hs-badge-shift on the page's root
#                        from a viewport width), for a UI that keeps a column of controls at the badge's own edge
#   (every server block) location = /__harness/harness.css: the ONE stylesheet of every page this
#                        harness builds (/agent/ui/harness.css, docs/UI-STYLE.md), served same-origin on
#                        every host; the badge files inject its <link> ahead of the badge
#   site/index.html    - the home page: one tile per UI (purpose, proxied link, live
#                        up/down dot probed client-side by same-origin fetch; disabled UIs
#                        rendered grey with the .env flag that enables them)
#   site/guide/        - the user guide: docs/user-guide.md (in the image at /docs/user-guide.md) rendered
#                        by /agent/md2html.py at every render; a missing source renders a page that says so
#   site/guide/readme/ - the README, rendered the same way
#   site/guide/manual/ - the manual, docs/manual/*.md (in the image at /docs/manual/): its index and one page per file,
#                        and site/guide/img/ the pictures they show (docs/img, in the image at /docs/img/);
#                        rendered the same way (its sections are the footer's help links, so they work without GitHub)
#   site/tmux-help/    - static tmux cheatsheet for the shared agent session (no upstream
#                        process; the home listener serves it from the site root, so its
#                        tile probes up whenever the home page itself is up). Every key on
#                        it carries a data-tmux marker verified against the running tmux
#                        by test13.sh - keep the markers when editing.
#
# Per-UI routing (the "ladder" - native base path when the app supports one, a *.localhost
# host route when it does not; see docs/manual/ui.md "Home page and reverse proxy"):
#   /headlamp/    -> headlamp, native -base-url (set by ui-start.sh when UI_HOME=true)
#   /memory-api/  -> hindsight-api; prefix stripped by the proxy. When the pinned CLI
#                    supports --root-path (ui-start.sh detects and exports
#                    HINDSIGHT_API_ROOT_PATH=native) the app generates /memory-api/ URLs
#                    itself; otherwise the /docs page's root-absolute openapi.json
#                    reference is rewritten here with sub_filter
#   /knowledge/   -> the Knowledge transfer page (/agent/knowledge-transfer.py on 127.0.0.1, docs/manual/memory.md "Moving knowledge between
#                    instances"; linked from the Memory tile): the knowledge stores exported as one pack file, a pack
#                    imported; prefix stripped (the page's addresses are relative), GET and POST only
#   hindsight.localhost -> hindsight-ui (Next.js standalone: basePath is build-time, no
#                    runtime prefix support - RFC 6761 *.localhost resolves to loopback in
#                    the browser, and ssh -L / kubectl port-forward preserve the Host header)
#   kanban.localhost -> the self-hosted kanban board (docs/manual/boards.md "Kanban board"): the board server sidecar at
#                    KANBAN_BOARD_URL, which run.sh passes when it started the sidecars. Proxied through a
#                    variable with a resolver, so a board that is down is a 502 on this route only, never an
#                    nginx that refuses to start. With KANBAN_BOARD_URL unset (no sidecar on this target, e.g.
#                    test.sh's container or kubernetes) it serves the vibe-kanban agent runner, as before
#   vk-runner.localhost -> the vibe-kanban agent runner (npm; coding agents in git worktrees; embedded
#                    SPA, no runtime base path). Its tiles open /workspaces: the runner's start page sends a
#                    first visit to its onboarding, which ends in a vibe-kanban cloud sign-in
#   claude-mem.localhost -> the claude-mem worker's memory viewer (root-absolute /api/ and
#                    /stream paths, no base-path setting)
#   loglearner.localhost -> the LogLearner dashboard (root-absolute links, binds 127.0.0.1); its tile
#                    contract (/api/tile.json) is also served same-origin at /__tile/metalearner, where
#                    the Learned rules tile reads its numbers and its ok/degraded state
#   chat.localhost -> the Agent chat page (/agent/agent-chat.py, docs/manual/ui.md "Agent chat"): the agent session's pane
#                    and a box that types a message at its prompt. On a host of its own so that the page's
#                    same-origin check has an origin of its own: the backend takes a message only from
#                    http://chat.localhost on the browser's port, and only on that Host
#   loop-deck.localhost -> the Loop Deck (the vendored /opt/loop-deck in harness mode over /wd/loop-deck, binds 127.0.0.1)
#   loop.localhost -> the Agent loop page (/agent/loop-view.py: a renderer of the autonomy loop's state files, on
#                    127.0.0.1), only when UI_LOOP=true; GET only but for its Control section's POST /control/run and
#                    /control/pause (UI_LOOP_CONTROL), and a Content-Security-Policy of its own origin only - the
#                    badge's three inline pieces (its style attribute, phone-width rule and keeper script) are
#                    allowed by their hashes (BADGE_SCRIPT_SRC and BADGE_STYLE_SRC below, from the strings
#                    badge_html injects); its dot probes the renderer's /health at /__probe/loop, which answers 2xx only
#                    while the page's data is fresh. Its pages link the harness stylesheet (/__harness/harness.css,
#                    served by this block too) and style themselves from its tokens (docs/UI-STYLE.md); the badge is
#                    injected without a second link (badge-host-nolink.conf)
#   /comms/       -> comms UI, native streamlit --server.baseUrlPath (comms-ui-start.sh)
#   /tmux/        -> ttyd browser terminal, native -b base path
#   /tmux-agent/  -> tmux-agent dashboard (the build vendored into the image, or one built from
#                    TMUX_AGENT_SRC, started by ui-start.sh), only when UI_TMUX_AGENT=true. A
#                    loopback Host and Origin are rewritten to its own address for its
#                    DNS-rebinding/CSRF guard (the headlamp pattern), and its root-absolute /api/
#                    paths are rewritten into the route (single-file UI with no base-path
#                    setting - the hindsight-api openapi.json pattern)
#   board.localhost -> the Board (docs/manual/boards.md "Board"): /agent/board-server.py, a read-only kanban view of this harness's own
#                    Plane project (columns and cards) with the agent runner's attempts on the cards they belong to; a
#                    page with root-absolute paths, so a host route. Only while the Plane board runs on this target
#                    (UI_PLANE=true and PLANE_URL set); with the Plane board off (UI_PLANE=false, the default) there is
#                    no Board tile at all, and with it on but not on this target the tile greys with the reason
#   files.localhost -> the Files tile (docs/manual/ui.md "Files"): /agent/files-server.py, the shared folder FILES_DIR (/wd/files)
#                    between the person and the agent - download what the agent produced, upload files for it to read,
#                    folders, rename, move, delete; a page with root-absolute paths, so a host route. Uploads up to
#                    FILES_MAX_UPLOAD_MB pass the route unbuffered (client_max_body_size, proxy_request_buffering off);
#                    only when UI_FILES=true (the default), the tile greys with the flag otherwise
#   (no route)    -> Loop Deck: listed as a greyed tile with the reason it is not served here
#                    (it renders another repository's loop registry; nothing standalone to serve)
#   any other Host -> 421: the home listener answers loopback names (and UI_HOME_HOSTNAMES) only;
#                    the *.localhost UIs are matched by their own server_name
#   any other SOURCE -> 403: only loopback, the network's gateway (the docker-proxy forward) and
#                    UI_HOME_ALLOW_FROM may connect; a neighbour container is refused
#   plane.localhost -> the self-hosted Plane board (docs/manual/boards.md "Plane board"): its proxy sidecar at PLANE_URL,
#                    which run.sh passes when it started the sidecars (a web app with no runtime base path).
#                    Proxied through a variable with a resolver, so a board that is down is a 502 on this route
#                    only, never an nginx that refuses to start. With PLANE_LOGIN_BYPASS=true the exact URL
#                    /__harness/sign-in on it goes to /agent/plane-signin.py, the Plane tile's one-click
#                    sign-in. With PLANE_URL unset (no sidecar on this target, e.g. test.sh's container,
#                    compose or kubernetes) there is no route and the tile says so; with UI_PLANE=false (the
#                    shipped default: the board is optional, AGPL-3.0, opt-in) there is no route and no tile at all

export HOME=${HOME:-/home/agent}

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
UI_FILES=${UI_FILES:-true}
AGENT_TMUX_SESSION_NAME=${AGENT_TMUX_SESSION_NAME:-agent}
COMMS_UI_ENABLED=${COMMS_UI_ENABLED:-false}
UI_PORT_HOME=${UI_PORT_HOME:-8000}
# the port the harness is published on (PORT_EXTERNAL_HOME in .env, passed in by run.sh, the compose and kubernetes
# templates): the header's tunnel and port-forward hint names it, so a deployment on another port tells the truth
HOME_PORT_HINT=${PORT_EXTERNAL_HOME:-8000}
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
UI_PORT_KANBAN_SIGNIN=${UI_PORT_KANBAN_SIGNIN:-8092}
UI_PORT_LOOP=${UI_PORT_LOOP:-7790}
# the Knowledge transfer page (/agent/knowledge-transfer.py; loopback only, behind the home listener's /knowledge/), and the
# largest pack it takes in bytes: the server reads the same KNOWLEDGE_PACK_MAX, so the proxy and the page refuse alike
UI_PORT_KNOWLEDGE=${UI_PORT_KNOWLEDGE:-8097}
KNOWLEDGE_PACK_MAX=${KNOWLEDGE_PACK_MAX:-67108864}
# a number of bytes above 0: nginx reads 0 as no limit at all, while the server would refuse every pack
if ! [[ "${KNOWLEDGE_PACK_MAX}" =~ ^[0-9]{1,15}$ ]] || [ "$((10#${KNOWLEDGE_PACK_MAX}))" -le 0 ]; then
	echo "home-render: KNOWLEDGE_PACK_MAX='${KNOWLEDGE_PACK_MAX}' is not a number of bytes above 0 - 67108864 (64 MiB) used"
	KNOWLEDGE_PACK_MAX=67108864
fi
# the Files tile (/agent/files-server.py; loopback only, behind the files.localhost route): its port, the shared folder and
# the largest upload in MiB - the server reads the same FILES_MAX_UPLOAD_MB, so the route and the server refuse alike
UI_PORT_FILES=${UI_PORT_FILES:-8098}
FILES_DIR=${FILES_DIR:-/wd/files}
FILES_MAX_UPLOAD_MB=${FILES_MAX_UPLOAD_MB:-1024}
# a number of MiB above 0: nginx reads 0 as no limit at all, while the server would refuse every upload
if ! [[ "${FILES_MAX_UPLOAD_MB}" =~ ^[0-9]{1,7}$ ]] || [ "$((10#${FILES_MAX_UPLOAD_MB}))" -le 0 ]; then
	echo "home-render: FILES_MAX_UPLOAD_MB='${FILES_MAX_UPLOAD_MB}' is not a number of MiB above 0 - 1024 used"
	FILES_MAX_UPLOAD_MB=1024
fi
COMMS_UI_PORT=${COMMS_UI_PORT:-8502}
# the agent sessions' supervisor (docs/manual/agents.md "Spoke agents"): it writes status.json in its directory after every pass.
# SPOKES_ON lists the enabled spokes of the registry (/agent/spoke.sh); the /__spokes route that serves status.json
# exists while the supervisor is on or a spoke is
SUPERVISOR=${SUPERVISOR:-true}
SUPERVISOR_DIR=${SUPERVISOR_DIR:-/wd/supervisor}
SPOKE_TOOL="$(cd "$(dirname "$0")" && pwd)/spoke.sh"
SPOKES_ON=""
for N in $("${SPOKE_TOOL}" names 2>/dev/null); do
	"${SPOKE_TOOL}" enabled "${N}" && SPOKES_ON="${SPOKES_ON} ${N}"
done
SUPERVISOR_SESSION=$("${SPOKE_TOOL}" sessions 2>/dev/null | awk '$2 == "supervisor" { print $1; exit }')
UI_LISTEN_HOST=${UI_LISTEN_HOST:-0.0.0.0}
UI_DIR=${UI_DIR:-/wd/ui}
# extra host names the home listener answers for (comma or space separated; see the 421 default
# server below) - the loopback names are always in. Plain host names only: a wildcard (*.example),
# a regex (~...), the catch-all "_" or anything with other characters would reopen the listener to
# every Host, so such an entry is refused with one line and left out (fail-closed)
# The gateway the host's published-port traffic arrives from: the DEFAULT ROUTE's, read from the routing
# table - never derived from a subnet (a planted control put a network with a custom gateway, .254, where a
# neighbour held .1: a "base + 1" guess admitted the neighbour to the writable terminal). Docker's published-port
# forward enters through the default route's gateway, also after the default route moves (a `docker network
# connect` on a running container moves it to the new network; /agent/home-route-watch.sh re-renders then).
# IPv4 only (Docker publishes over IPv4 by default; an IPv6 gateway goes into UI_HOME_ALLOW_FROM). UI_HOME_GATEWAY
# (space-separated) overrides the detection; UI_HOME_ROUTE_TABLE names a file with `ip route` output to read
# instead of the live table - the tests plant routing tables with it.
hex_ip() { printf '%d.%d.%d.%d' 0x${1:6:2} 0x${1:4:2} 0x${1:2:2} 0x${1:0:2}; }
default_gateways()
{
	if [ -n "${UI_HOME_ROUTE_TABLE}" ]; then
		awk '$1 == "default" && $2 == "via" {print $3}' "${UI_HOME_ROUTE_TABLE}" 2>/dev/null
	elif command -v ip > /dev/null 2>&1 && ip -4 route show default > /dev/null 2>&1; then
		ip -4 route show default 2>/dev/null | awk '$1 == "default" && $2 == "via" {print $3}'
	elif [ -r /proc/net/route ]; then
		# no iproute2: the kernel table - every default route (destination 0) with a gateway
		for GW_HEX in $(awk '$2 == "00000000" && $3 != "00000000" {print $3}' /proc/net/route); do hex_ip "${GW_HEX}"; echo; done
	fi | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | awk '!seen[$0]++'
}
if [ -z "${UI_HOME_GATEWAY}" ]; then
	UI_HOME_GATEWAY=$(default_gateways | tr '\n' ' ')
	UI_HOME_GATEWAY=${UI_HOME_GATEWAY% }
fi
if [ "$1" == "--print-gateways" ]; then
	# for /agent/home-route-watch.sh (every few seconds): the list this render would admit, nothing rendered
	# and nothing validated - the hostname and allow-list warnings below are printed by a real render only
	echo "${UI_HOME_GATEWAY}"
	exit 0
fi

# set -f: no pathname expansion while the list is split - a bare * would otherwise become the file names here
set -f
UI_HOME_HOSTNAMES_OK=""
for HN in $(echo "${UI_HOME_HOSTNAMES:-}" | tr ',' ' '); do
	if echo "${HN}" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'; then
		UI_HOME_HOSTNAMES_OK="${UI_HOME_HOSTNAMES_OK} ${HN}"
	else
		echo "home-render: UI_HOME_HOSTNAMES entry '${HN}' refused - plain host names only (letters, digits, dots, hyphens); it is left out of the allowlist" >&2
	fi
done
UI_HOME_HOSTNAMES=${UI_HOME_HOSTNAMES_OK# }
set +f
# Who may CONNECT to the home listener (allow/deny in nginx.conf, 403 otherwise): the container itself
# (127.0.0.1 / ::1 - the tests, the hooks, the seed, the dashboards' own panels), the default gateway
# of the container's network - which is where Docker's published-port forward arrives from (the
# docker-proxy on the host, the default; with "userland-proxy": false the host's traffic is
# masqueraded to the same gateway address) and where kubectl port-forward traffic does not even go
# (it enters through loopback) - plus UI_HOME_ALLOW_FROM, addresses or CIDRs for a deliberate
# exception (an ingress controller's range; the host's address when the gateway detection is
# wrong for your network). A NEIGHBOUR container on the same docker or pod network has another
# source address and is refused: before this, every backend and the proxy answered any neighbour,
# the writable terminal and the memory API included. Entries that are not an IPv4/IPv6 address
# or CIDR, or that cover everything (/0), are refused with one line and left out (fail-closed).
set -f
UI_HOME_ALLOW_OK=""
for AF in $(echo "${UI_HOME_ALLOW_FROM:-}" | tr ',' ' '); do
	# an IPv4 address or CIDR (/8-/32) or an IPv6 address or CIDR (/16-/128), parsed by python's ipaddress -
	# range AND shape (999.1.1.1 fails `nginx -t` and would take the whole home page down; a prefix shorter
	# than /8, or /16 for IPv6, is a near-/0 that would admit most of the internet)
	OK=$(python3 - "${AF}" << 'PY'
import ipaddress, sys
try:
    n = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    print("false"); sys.exit(0)
print("true" if n.prefixlen >= (8 if n.version == 4 else 16) else "false")
PY
)
	if [ "${OK}" == "true" ]; then
		UI_HOME_ALLOW_OK="${UI_HOME_ALLOW_OK} ${AF}"
	else
		echo "home-render: UI_HOME_ALLOW_FROM entry '${AF}' refused - an IPv4 address or CIDR (/8-/32, octets 0-255) or an IPv6 address or CIDR (/16-/128), never /0; it is left out" >&2
	fi
done
set +f
[ -n "${UI_HOME_GATEWAY}" ] || echo "home-render: no default-route gateway found - only loopback (and UI_HOME_ALLOW_FROM) may connect to the home listener" >&2
# native | rewrite - whether the installed hindsight-api CLI accepts --root-path
# (detected by ui-start.sh; default rewrite = proxy-side sub_filter, works for both)
HINDSIGHT_API_ROOT_PATH=${HINDSIGHT_API_ROOT_PATH:-rewrite}
# swagger-ui for the API docs page: the pinned copy /setup/install-swagger-ui.sh installs
SWAGGER_UI_DIR=${SWAGGER_UI_DIR:-/opt/swagger-ui-dist}
# the claude-mem viewer's harness view (CLAUDE_MEM_VIEWER_WRAPPER, .env): the image's script and stylesheet that fold the
# harness's machine prompts and hide the promotion, injected into the viewer's page; false serves the stock viewer
CLAUDE_MEM_VIEWER_WRAPPER=${CLAUDE_MEM_VIEWER_WRAPPER:-true}
CLAUDE_MEM_WRAPPER_DIR=${CLAUDE_MEM_WRAPPER_DIR:-/agent/claude-mem-wrapper}
# The API routes' Content-Security-Policy: their own origin only. Swagger UI's page starts it from an inline script
# and its styles and icons use inline styles and data: images, hence 'unsafe-inline' and data: - nothing else.
MEMORY_API_CSP="default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
# The self-hosted kanban board's server (a sidecar container; run.sh sets both) and its login file
KANBAN_BOARD_URL=${KANBAN_BOARD_URL:-}
KANBAN_AUTH_FILE=${KANBAN_AUTH_FILE:-/wd/kanban/kanban.env}
# Only a plain http(s)://host[:port] URL reaches the nginx config; anything else is ignored, loudly
if [ -n "${KANBAN_BOARD_URL}" ] && ! echo "${KANBAN_BOARD_URL}" | grep -qE '^https?://[A-Za-z0-9._-]+(:[0-9]+)?/?$'; then
	echo "home-render: WARNING - KANBAN_BOARD_URL is not a plain http(s)://host[:port] URL; kanban.localhost serves the agent runner"
	KANBAN_BOARD_URL=""
fi
KANBAN_BOARD_URL=${KANBAN_BOARD_URL%/}
# its port, for the board route's redirect rules (host_redirect_rules below)
KANBAN_BOARD_PORT=${KANBAN_BOARD_URL##*:}
case "${KANBAN_BOARD_PORT}" in
	''|*[!0-9]*) KANBAN_BOARD_PORT=80 ;;
esac
# The board's hostname is resolved per request by the container's own DNS server (docker's embedded one on the
# board's network): the first nameserver of /etc/resolv.conf
KANBAN_RESOLVER=$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf 2>/dev/null)
KANBAN_RESOLVER=${KANBAN_RESOLVER:-127.0.0.11}
case "${KANBAN_RESOLVER}" in
	*:*) KANBAN_RESOLVER="[${KANBAN_RESOLVER}]" ;;
esac

HOME_DIR=${UI_DIR}/home
mkdir -p "${HOME_DIR}/site/tmux-help" "${HOME_DIR}/site/guide/readme" "${HOME_DIR}/tmp"

# The self-hosted Plane board (sidecar containers; run.sh passes PLANE_URL when it started them) and the Plane
# tile's one-click sign-in (/agent/plane-signin.py on the loopback port UI_PORT_PLANE_SIGNIN). The board is optional and
# OFF by default (Plane community edition is AGPL-3.0 - docs/manual/boards.md "Plane board"): with UI_PLANE false no Plane tile, no
# Board tile, no plane.localhost route and no probe are rendered, and the page names no flag for them
UI_PLANE=${UI_PLANE:-false}
PLANE_URL=${PLANE_URL:-}
PLANE_LOGIN_BYPASS=${PLANE_LOGIN_BYPASS:-true}
UI_PORT_PLANE_SIGNIN=${UI_PORT_PLANE_SIGNIN:-8090}
PLANE_AUTH_FILE=${PLANE_AUTH_FILE:-/wd/plane/plane.env}
PLANE_SIGNIN_PATH=/__harness/sign-in
# The Board (docs/manual/boards.md "Board"): /agent/board-server.py on the loopback port UI_PORT_BOARD, served at board.localhost. It
# reads the Plane board's project, so it runs only with the board on this target (UI_PLANE=true and PLANE_URL set): with
# the Plane board off there is no Board tile; UI_BOARD=false, or a target without the board, greys the tile with that reason
UI_BOARD=${UI_BOARD:-true}
UI_PORT_BOARD=${UI_PORT_BOARD:-8096}
BOARD_ON=false
[ "${UI_BOARD}" == "true" ] && [ "${UI_PLANE}" == "true" ] && [ -n "${PLANE_URL}" ] && BOARD_ON=true
# Only a plain http(s)://host[:port] URL reaches the nginx config; anything else is ignored, loudly
if [ -n "${PLANE_URL}" ] && ! echo "${PLANE_URL}" | grep -qE '^https?://[A-Za-z0-9._-]+(:[0-9]+)?/?$'; then
	echo "home-render: WARNING - PLANE_URL is not a plain http(s)://host[:port] URL; no Plane route"
	PLANE_URL=""
fi
PLANE_URL=${PLANE_URL%/}
# its port, for the board route's redirect rules (host_redirect_rules below)
PLANE_PORT=${PLANE_URL##*:}
case "${PLANE_PORT}" in
	''|*[!0-9]*) PLANE_PORT=80 ;;
esac
# The board's hostname is resolved per request by the container's own DNS server (docker's embedded one on the
# board's network): the first nameserver of /etc/resolv.conf
PLANE_RESOLVER=$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf 2>/dev/null)
PLANE_RESOLVER=${PLANE_RESOLVER:-127.0.0.11}
case "${PLANE_RESOLVER}" in
	*:*) PLANE_RESOLVER="[${PLANE_RESOLVER}]" ;;
esac
# The home badge on the Plane route: the shared one (badge-host.conf, the same markup as on every host route, with
# the home page's port) - kept in the page. Plane's web app hydrates the whole server-rendered document and drops the
# nodes it did not render, and on a repeat visit it re-renders the whole document on the client (Plane's own React
# hydration errors 418 and 423, with or without this proxy), so the badge badge-host.conf puts before </body> is in the
# served HTML but does not stay in the page. The route appends a small script after the end of Plane's document (nginx
# add_after_body, below). It removes itself as it runs, keeps a copy of that served badge (with its style element and
# its script when the badge has them) and puts the copy back on the document's root element whenever the page has no
# badge (the app replaced the document), running the badge's own script again. It has no badge of its own: on a page
# served without the shared badge it does nothing
cat > "${HOME_DIR}/badge-plane.html" << 'EOF'
<script>(function(){var me=document.currentScript;if(me&&me.parentNode)me.parentNode.removeChild(me);var Q="#do-agent-aws-home,a[title='do-agent-aws harness home']",a=document.querySelector(Q);if(!a)return;var b=a.cloneNode(true),t=document.getElementById("do-agent-aws-home-style"),c=t?t.cloneNode(true):null,k="";[].forEach.call(document.scripts,function(x){if(!k&&x.textContent.indexOf('getElementById("do-agent-aws-home")')>=0)k=x.textContent;});function put(){var r=document.documentElement;if(!r||document.querySelector(Q))return;r.appendChild(b.cloneNode(true));if(c&&!document.getElementById("do-agent-aws-home-style"))r.appendChild(c.cloneNode(true));if(k){var n=document.createElement("script");n.textContent=k;r.appendChild(n);}}new MutationObserver(put).observe(document,{childList:true,subtree:true});})();</script>
EOF

VERSION_LINE=$(cat /version.txt 2>/dev/null || echo "do-agent-aws")

# The harness stylesheet: ONE file for every page this harness builds (docs/UI-STYLE.md), served by nginx itself at the
# SAME root-relative path on EVERY server block below (harness_css_location), so a page on any *.localhost route loads
# it same-origin and no page carries a cross-host stylesheet link. HARNESS_CSS names the file (the tests point it at the
# checkout); the <link> is root-relative on purpose.
HARNESS_CSS=${HARNESS_CSS:-/agent/ui/harness.css}
HARNESS_CSS_PATH=/__harness/harness.css
HARNESS_LINK="<link rel=\"stylesheet\" href=\"${HARNESS_CSS_PATH}\">"
harness_css_location()
{
	# the stylesheet route of one server block: the file as is, never cached (a redeploy changes it; the pages read
	# it on every load), GET only like every static file nginx serves
	cat << EOF
		location = ${HARNESS_CSS_PATH} {
			alias ${HARNESS_CSS};
			add_header Cache-Control "no-store";
		}
EOF
}

memory_api_locations()
{
	# memory_api_locations <badge conf> [get-only] - the memory API's locations of one server block: the home listener's
	# (badge-rule.conf, the badge of the home host) and the LogLearner dashboard's host route (badge-host-rule.conf, a host
	# route's badge without a sub_filter_once of its own; get-only, since the dashboard's pages only read the API and a
	# page on that origin must not gain same-origin writes). The dashboard's pages link to the API at /memory-api on their
	# own host (loglearner-serve.sh exports LOGLEARNER_HINDSIGHT_LINK_BASE; a link at the container-internal address
	# opens, on a shared host, somebody else's memory API). Prints nothing while the memory API is off.
	# Two proxied locations: /memory-api/ is the API itself, JSON in and out - nginx's substitution filter applies only
	# to text/html there (its default types), so a JSON body that happens to carry the badge's </body> anchor (a bank
	# name, a memory's text) is passed byte for byte; the HTML pages the API serves (/redoc) still get the badge, and
	# no more: /redoc is not supported offline - its bundle and its icon come from CDNs this proxy does not carry, and
	# the policy header keeps the browser from fetching them, so the page stays blank there by design. The
	# docs page alone (= /memory-api/docs, FastAPI's Swagger UI) gets the rewrites it needs: swagger-ui from the copy in
	# the image instead of the jsdelivr CDN and its icon instead of fastapi.tiangolo.com (/memory-api/__swagger/ below),
	# so the page renders offline and requests nothing off the loopback port, and sub_filter_once off for them, which is
	# why its badge include is the rule alone. hindsight-api - prefix stripped by the trailing slash on proxy_pass
	[ "${UI_HINDSIGHT}" == "true" ] || return 0
	local BADGE_CONF=${1:?memory_api_locations needs the badge include of its server block}
	local GET_ONLY=""
	[ "${2:-}" == "get-only" ] && GET_ONLY="			limit_except GET { deny all; }"
cat << EOF
		location /memory-api/ {
${GET_ONLY}
			proxy_pass http://127.0.0.1:${UI_PORT_HINDSIGHT_API}/;
			include ${HOME_DIR}/proxy-common.conf;
			add_header Content-Security-Policy "${MEMORY_API_CSP}" always;
			include ${HOME_DIR}/${BADGE_CONF};
		}
		location = /memory-api/docs {
${GET_ONLY}
			proxy_pass http://127.0.0.1:${UI_PORT_HINDSIGHT_API}/docs;
			include ${HOME_DIR}/proxy-common.conf;
			sub_filter 'https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/' '/memory-api/__swagger/';
			sub_filter 'https://fastapi.tiangolo.com/img/favicon.png' '/memory-api/__swagger/favicon-32x32.png';
			add_header Content-Security-Policy "${MEMORY_API_CSP}" always;
			include ${HOME_DIR}/${BADGE_CONF};
			sub_filter_once off;
EOF
if [ "${HINDSIGHT_API_ROOT_PATH}" != "native" ]; then
cat << EOF
			# CLI has no --root-path: rewrite the /docs page's root-absolute
			# openapi.json reference so swagger loads through the proxy
			sub_filter "'/openapi.json'" "'/memory-api/openapi.json'";
EOF
fi
cat << EOF
		}
		# swagger-ui for the docs page: the pinned copy in the image, read-only
		location /memory-api/__swagger/ {
			limit_except GET { deny all; }
			alias ${SWAGGER_UI_DIR}/;
			add_header Content-Security-Policy "${MEMORY_API_CSP}" always;
		}
		# the bare prefix and every trailing-slash spelling of a memory API path, as a user types them by hand:
		# the API has no page at its root (404) and answers /docs/, /redoc/ or /health/ with a redirect whose
		# Location carries the request's Host but not the /memory-api prefix, so it lands on this listener's
		# 404 (found by a fresh-deploy walk). Each goes to the same path without the slash, on THIS listener,
		# through try_files (precontent phase) into a named location, so the source allowlist (access phase)
		# answers first - a plain return would run in the rewrite phase, before it, as the dot probes above also
		# avoid. 307 for the slashed paths: the method, body and query are kept (a POST to /memory-api/mcp/ from
		# an MCP client is replayed as the same POST, not turned into a GET)
		location = /memory-api {
			try_files /__memory_api_nonexistent @memory_api_docs;
		}
		location = /memory-api/ {
			try_files /__memory_api_nonexistent @memory_api_docs;
		}
		location ~ ^/memory-api/(.+)/\$ {
			set \$memory_api_noslash /memory-api/\$1;
			try_files /__memory_api_nonexistent @memory_api_noslash;
		}
		location @memory_api_docs {
			return 302 /memory-api/docs;
		}
		location @memory_api_noslash {
			return 307 \$memory_api_noslash\$is_args\$args;
		}
EOF
}

# The relay (UI_KANBAN_RELAY=true on the host, docs/manual/boards.md "Kanban board"; KANBAN_RELAY_URL comes from run.sh): with no
# relay base built in, the board app reaches its hosts through the relay at its own origin (/v1/relay/...), so the
# board route sends exactly that path to the relay sidecar; the relay's CORS (any Origin, with credentials) is hidden,
# as the board server's is. Prints nothing without the relay: the rendered configuration is then as without it.
relay_location()
{
	[ -n "${KANBAN_RELAY_URL:-}" ] || return 0
	cat << EOF

		# the relay: the board's hosts, through it, on this origin
		location ^~ /v1/relay/ {
			set \$kanban_relay ${KANBAN_RELAY_URL};
			proxy_pass \$kanban_relay;
			include ${HOME_DIR}/proxy-common.conf;
			proxy_read_timeout 3600s;
			proxy_hide_header Access-Control-Allow-Origin;
			proxy_hide_header Access-Control-Allow-Credentials;
		}
EOF
}

# ---------------------------------------------------------------- nginx config
# Redirects of a host-routed UI go back to the browser ABSOLUTE, on the host the browser used: a relative
# Location is resolved by the client against whatever URL it connected with, and a client that reached the
# tile through 127.0.0.1 with a Host header (curl -L with -H Host, a tunnelled or scripted browser with a host
# rule) lands on the home listener's 404 for /dashboard - the memory UI's root does exactly that redirect
# (found by the owner's hands-on walk). An absolute Location naming the upstream's OWN loopback address and
# port (an upstream that built it from its bind) is re-hosted the same way. Nothing else is touched: an
# external site, another tile, a protocol-relative //host (and /\host, which browsers read the same way), a
# loopback service on another port (an OAuth callback on localhost:3000) pass through as sent. No
# `proxy_redirect default`: it turns the upstream's own address into a RELATIVE Location, which nginx's
# header filter then completes with ITS listen port - wrong whenever the container is published on another
# port (a sidecar on 127.0.0.1:8001); $http_host carries the browser's port. Path-routed UIs keep nginx's
# relative redirects (absolute_redirect off), which stay on the home host by construction. test16 check 4b
# measures every case through a planted upstream. (\x5c is a backslash: the config parser would eat a
# doubled one.)
host_redirect_rules()
{
	# host_redirect_rules <upstream port> - the proxy_redirect lines of a host-routed location
	cat << EOF
			proxy_redirect ~^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\]):$1(/.*)?\$ http://\$http_host\$2;
			proxy_redirect ~^(/(?![/\\x5c]).*)\$ http://\$http_host\$1;
EOF
}

cat > "${HOME_DIR}/proxy-common.conf" << EOF
proxy_http_version 1.1;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection \$connection_upgrade;
# Host is a per-location variable (default \$http_host; the headlamp location overrides it to
# headlamp's own address for its DNS-rebinding guard - see that location). One directive => one
# Host header (Go's net/http 400s on duplicate Host, so we must NOT emit two).
proxy_set_header Host \$proxy_upstream_host;
proxy_set_header X-Forwarded-For \$remote_addr;
proxy_set_header X-Forwarded-Host \$http_host;
proxy_set_header X-Forwarded-Proto \$scheme;
# upstreams must answer uncompressed for sub_filter (the home badge) to see the html
proxy_set_header Accept-Encoding "";
proxy_buffering off;
EOF

# The "Harness home" badge every UI gets, so going back to the home page is one click from anywhere
# in the harness. ONE definition (badge_html) for every place it appears: the sub_filter files below
# inject it before </body> of every proxied text/html page (an upstream must answer uncompressed for
# that - proxy-common.conf's Accept-Encoding ""), and the static pages the home listener serves itself
# (the tmux cheatsheet) carry it in their markup. Its parts:
#   - target="do-agent-aws-home": the home page names its own tab that (window.name, below), so a
#     click returns to the home tab that is already open instead of opening another one, where the
#     browser lets a tab reach it; otherwise it simply opens the home page
#   - id + a media rule: under 481 px it moves to the bottom LEFT - a UI that lays out wider than a
#     phone's viewport pushes a right-pinned badge off-screen (measured: Hindsight, tmux-agent)
#   - class hs-badge: its look (the harness ink, a border so it stays visible on a dark UI) comes from the harness
#     stylesheet, whose <link> is injected right before it (HARNESS_LINK; the same path on every host, so it is loaded
#     same-origin); the style attribute is a fallback for a UI whose own policy refuses that sheet - position only, and
#     the browser's system colours (no hex anywhere but in the stylesheet: test-ui-style.sh's grep gate). The markup is
#     the design system's, in its order - class="hs-badge" data-harness-home (the attribute marks it for the tests), href,
#     title - with this badge's id and target after them and the style last: test-ui-style.sh reads the link and that
#     opening as one string, and the Board's test finds href and style in that order. It reads "&#8962; home", the same
#     on every UI (the Plane board's badge too)
#   - a keeper script: a single-page app that re-renders its <body> (measured: Plane's client render removed the
#     injected badge within half a second) would take the badge with it, so the script moves the badge and its
#     phone rule up to the <html> element, outside any app root, and puts them back if they are ever removed
#     (a MutationObserver on the element's children). Where a UI's own Content-Security-Policy refuses inline
#     scripts the badge simply stays where it was injected. On a narrow screen (a visual viewport of at most 480 CSS
#     px) it also pins the badge to the bottom left of what the user actually sees: a UI without a responsive
#     viewport lays out wider than the phone (measured at 390 px: ttyd 980, the LogLearner dashboard 988,
#     tmux-agent 462), the 481 px media rule never fires there and a fixed badge sits off the visible area. It
#     follows window.visualViewport (its offset and size, on resize and scroll), so pinch-zoom and scrolling keep it
#     in view. No $ or single quote in it: it sits inside the nginx sub_filter's single-quoted replacement, where $
#     starts a variable. And no < either: test-home-badge.sh reads the script's body as everything up to the next <.
# Keep href="..." directly before title="do-agent-aws harness home": test9.sh matches the pair.
BADGE_KEEPER='(function(){var r=document.documentElement,b=document.getElementById("do-agent-aws-home"),s=document.getElementById("do-agent-aws-home-style"),v=window.visualViewport;if(!r||!b)return;var p=function(){if(!v)return;var t=b.style;if(480>=v.width){t.setProperty("right","auto","important");t.setProperty("bottom","auto","important");t.setProperty("left",Math.round(v.offsetLeft+10)+"px","important");t.setProperty("top",Math.round(v.offsetTop+v.height-b.offsetHeight-10)+"px","important");}else{t.removeProperty("left");t.removeProperty("top");t.setProperty("right","14px");t.setProperty("bottom","14px");}};var k=function(){if(b.parentNode!==r)r.appendChild(b);if(s&&s.parentNode!==r)r.appendChild(s);p();};k();if(v){v.addEventListener("resize",p);v.addEventListener("scroll",p);}window.addEventListener("load",p);if(window.MutationObserver)new MutationObserver(k).observe(r,{childList:true});})();'
BADGE_STYLE="position:fixed;bottom:14px;right:14px;z-index:2147483647;background:CanvasText;color:Canvas;border:1px solid Canvas;padding:6px 12px;border-radius:16px;font:13px/1.2 sans-serif;text-decoration:none;opacity:.92"
BADGE_PHONE_RULE="@media (max-width:480px){#do-agent-aws-home{right:auto!important;left:10px!important;bottom:10px!important}}"
badge_html()
{
	# badge_html <href> - the badge markup, the phone-width rule and the keeper script included
	echo "<a class=\"hs-badge\" data-harness-home href=\"$1\" title=\"do-agent-aws harness home\" id=\"do-agent-aws-home\" target=\"do-agent-aws-home\" style=\"${BADGE_STYLE}\">&#8962; home</a><style id=\"do-agent-aws-home-style\">${BADGE_PHONE_RULE}</style><script>${BADGE_KEEPER}</script>"
}
# The badge's three inline pieces as Content-Security-Policy sources, for a route whose policy is its own origin only (the
# Agent loop page, the Board): its keeper script for script-src, and for style-src its style attribute ('unsafe-hashes'
# admits that one hashed attribute value, no other) and its phone-width rule, each by its sha256. Built once, from the
# strings badge_html injects, so the routes cannot drift apart. An empty hash (python3 failing) would leave a policy that
# nginx accepts and the browser uses to refuse the badge, so it stops the render instead
csp_hash()
{
	printf '%s' "$1" | python3 -c 'import base64, hashlib, sys; print("sha256-" + base64.b64encode(hashlib.sha256(sys.stdin.buffer.read()).digest()).decode())'
}
BADGE_KEEPER_SHA=$(csp_hash "${BADGE_KEEPER}")
BADGE_STYLE_SHA=$(csp_hash "${BADGE_STYLE}")
BADGE_RULE_SHA=$(csp_hash "${BADGE_PHONE_RULE}")
for SHA in "${BADGE_KEEPER_SHA}" "${BADGE_STYLE_SHA}" "${BADGE_RULE_SHA}"; do
	case "${SHA}" in
	sha256-?*) ;;
	*) echo "home-render: ERROR - a hash of the home badge's inline pieces is empty or malformed ('${SHA}'); is python3 there?" >&2; exit 1 ;;
	esac
done
BADGE_SCRIPT_SRC="'${BADGE_KEEPER_SHA}'"
BADGE_STYLE_SRC="'unsafe-hashes' '${BADGE_STYLE_SHA}' '${BADGE_RULE_SHA}'"
# The Agent loop page's Content-Security-Policy (the loop.localhost route below): its own origin only, plus the badge's
# three pieces, so the badge keeps its place on a phone and survives a re-render here too; the badge's look itself comes
# from the harness stylesheet, which is 'self'
if [ "${UI_LOOP}" == "true" ]; then
	LOOP_CSP="default-src 'self'; script-src 'self' ${BADGE_SCRIPT_SRC}; style-src 'self' ${BADGE_STYLE_SRC}; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
fi
# The LogLearner dashboard's (the loglearner.localhost route below). The dashboard is a vendored release that puts the search
# page's transcript snippets into the page without escaping them (reported upstream), so its route sends a policy under which only
# the dashboard's own scripts run: each inline script and event handler by its sha256 and its one CDN script by URL, read from
# the release's source (/agent/loglearner-csp.py), plus the badge's keeper. A script or a handler that arrives inside a snippet
# does not run, and the page can load and send nothing to another origin. A source the reader cannot read leaves the policy
# without the dashboard's own scripts: its theme switch, filters and graph stop working, never the defense
if [ "${UI_LOGLEARNER}" == "true" ]; then
	LOGLEARNER_SCRIPTS=$(python3 -I "${AGENT_DIR:-/agent}/loglearner-csp.py" "${LOGLEARNER_DIR:-/opt/loglearner}/dashboard/app.py") \
		|| { echo "home-render: WARNING - the LogLearner dashboard's own scripts could not be read for its Content-Security-Policy; they will not run" >&2; LOGLEARNER_SCRIPTS=""; }
	LOGLEARNER_CSP="default-src 'self'; script-src 'self' ${BADGE_SCRIPT_SRC} ${LOGLEARNER_SCRIPTS}; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'self'"
	echo "add_header Content-Security-Policy \"${LOGLEARNER_CSP}\" always;" > "${HOME_DIR}/csp-loglearner.conf"
fi
# The Knowledge transfer page's (the /knowledge/ route below): the same policy - its own files only, plus the badge's three pieces
KNOWLEDGE_CSP="default-src 'self'; script-src 'self' ${BADGE_SCRIPT_SRC}; style-src 'self' ${BADGE_STYLE_SRC}; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

# path-routed UIs: on the home listener's own hostname href="/" IS the home page
cat > "${HOME_DIR}/badge.conf" << EOF
sub_filter '</body>' '${HARNESS_LINK}$(badge_html /)</body>';
sub_filter_once on;
EOF

# The host-routed UIs (hindsight.localhost, kanban.localhost) need a host-aware target: on
# those hostnames a bare href="/" resolves to the APP's own root, not the home page. The
# $home_host map (rendered below) strips the first hostname label and keeps the :port the
# browser is on (hindsight.localhost:9090 -> localhost:9090), so the badge returns home
# through any ssh -L / kubectl port-forward port; protocol-relative (//) keeps the scheme.
# (the $home_host in the href stays literal: nginx fills it in per request.)
# shellcheck disable=SC2016
cat > "${HOME_DIR}/badge-host.conf" << EOF
sub_filter '</body>' '${HARNESS_LINK}$(badge_html '//$home_host/')</body>';
sub_filter_once on;
EOF

# The same for a host-routed page this harness builds itself and that links the stylesheet in its own <head>: the badge
# without a second link
cat > "${HOME_DIR}/badge-host-nolink.conf" << EOF
sub_filter '</body>' '$(badge_html '//$home_host/')</body>';
sub_filter_once on;
EOF

# badge-host.conf's rule alone (no sub_filter_once), for a host-routed location that runs its own sub_filter chain and
# sets sub_filter_once itself (the memory API's docs-page rewrites on the LogLearner dashboard's host); nginx refuses a
# second sub_filter_once in one location
# shellcheck disable=SC2016
cat > "${HOME_DIR}/badge-host-rule.conf" << EOF
sub_filter '</body>' '${HARNESS_LINK}$(badge_html '//$home_host/')</body>';
EOF

# A route that keeps a Content-Security-Policy of its own origin alone (the Board) still has to let the three inline
# pieces of the badge injected into it apply, each allowed by its sha256 (BADGE_SCRIPT_SRC and BADGE_STYLE_SRC above):
# its style attribute ('unsafe-hashes' admits that one hashed attribute value, no other), its phone-width rule and its
# keeper script; everything else on that page is a file of its own origin
if [ "${BOARD_ON}" == "true" ]; then
	BOARD_CSP="default-src 'self'; script-src 'self' ${BADGE_SCRIPT_SRC}; style-src 'self' ${BADGE_STYLE_SRC}; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
fi
# the Files route keeps the same shape: files-server.py's own policy ('self' alone) plus the badge's three hashes
if [ "${UI_FILES}" == "true" ]; then
	FILES_CSP="default-src 'self'; script-src 'self' ${BADGE_SCRIPT_SRC}; style-src 'self' ${BADGE_STYLE_SRC}; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
fi

# The host-routed badge WITH A CLEARANCE, for a route whose UI keeps a control of its own in the badge's corner
# (docs/UI-STYLE.md, the badge's clearance): the route's --hs-badge-offset is set on the page's root in the same
# replacement, right before the stylesheet link and the badge, and the stylesheet lifts the badge by it. One file per
# clearance, badge-host-clear-<px>.conf; a route that needs none keeps badge-host.conf. The claude-mem viewer's console
# toggle sits at the phone's bottom left where the badge lands (measured at 390x844: a 48 px button at y 776-824 under a
# badge at y 804-834, 960 CSS px² covered); 60 px lifts the badge clear of it (test-lib/ui-style-browser.py --badge-clear).
badge_host_clearance_conf()
{
	# badge_host_clearance_conf <px> - writes badge-host-clear-<px>.conf and prints its path
	# shellcheck disable=SC2016
	cat > "${HOME_DIR}/badge-host-clear-$1.conf" << EOF
sub_filter '</body>' '<style>:root{--hs-badge-offset:$1px}</style>${HARNESS_LINK}$(badge_html '//$home_host/')</body>';
sub_filter_once on;
EOF
	echo "${HOME_DIR}/badge-host-clear-$1.conf"
}
BADGE_CLAUDE_MEM_CLEARANCE=${BADGE_CLAUDE_MEM_CLEARANCE:-60}
badge_host_clearance_conf "${BADGE_CLAUDE_MEM_CLEARANCE}" > /dev/null

# The host-routed badge MOVED ASIDE, for a route whose UI keeps a full-height column of controls at the badge's own edge,
# where no lift clears it: the route's --hs-badge-shift moves the badge left, from a viewport width on (a media query in the
# same replacement); narrower viewports keep the resting corner. The Goals board's card panel is such a column (measured at
# 1440x900 and 1920x1080 with a card open: the panel's left edge at 1036 and 1451 px, its comment composer and a failed
# comment's error box reaching the panel's bottom under the badge). A 35vw shift lands the badge at 847 and 1159 px, over
# the board columns' empty bottoms, with no control under it. On a phone the panel is the whole width and the badge stays
# in its corner (clear of the composer's buttons, measured at 390x844).
badge_host_shift_conf()
{
	# badge_host_shift_conf <name> <length> <from px> - writes badge-host-shift-<name>.conf and prints its path
	# shellcheck disable=SC2016
	cat > "${HOME_DIR}/badge-host-shift-$1.conf" << EOF
sub_filter '</body>' '<style>@media (min-width:$3px){:root{--hs-badge-shift:$2}}</style>${HARNESS_LINK}$(badge_html '//$home_host/')</body>';
sub_filter_once on;
EOF
	echo "${HOME_DIR}/badge-host-shift-$1.conf"
}
BADGE_KANBAN_SHIFT=${BADGE_KANBAN_SHIFT:-35vw}
BADGE_KANBAN_SHIFT_FROM=${BADGE_KANBAN_SHIFT_FROM:-900}
badge_host_shift_conf board "${BADGE_KANBAN_SHIFT}" "${BADGE_KANBAN_SHIFT_FROM}" > /dev/null

# The browser egress lock of the vibe-kanban pages (the board and the agent runner): vibe-kanban 0.1.44 calls third
# parties from the browser - the runner's prebuilt bundle sends Sentry and PostHog telemetry, and both apps load
# Google Fonts and fetch the GitHub star and Discord online counts. This policy lets those pages load and connect
# only to their own origin and its websocket (frames also to loopback, for the runner's previews of local dev
# servers), so the browser refuses each of those requests before it leaves; the pages fall back to local fonts and
# show no counts. Their API, live sync and websockets are all same-origin. No other site may frame them.
# The agent runner's pages (vibe-kanban 0.1.44, prebuilt): two harness touches, shared by both routes that serve it
# (vk-runner.localhost, and kanban.localhost without a board).
#   runner-harness.conf   - server-level: /settings is not a route of the runner's frontend (its Settings is a dialog
#                           from the nav, packages/local-web routeTree has no /settings), so a typed or bookmarked
#                           /settings lands on the workspaces, where the Settings button is, instead of the SPA's
#                           "Not Found"
#   runner-hide-cloud.conf - location-level: the retired vibe-kanban cloud's prompts are hidden in the page by a script
#                           injected before </head> (the same mechanism as the home badge; the vibe-kanban CSP allows
#                           inline scripts): the app bar's "Kanban Boards / Sign in to organise your coding agents with
#                           kanban boards." block with its Sign in button, the Projects button whose tooltip is "Sign in
#                           to view projects", and the drawer's "Organization" header. The strings are the runner's own
#                           (packages/web-core/src/i18n/locales/en/common.json appBar.kanban; SharedAppLayout.tsx), so
#                           a runner upgrade that rewords them shows the prompts again rather than hiding anything else.
#                           The Settings dialog's own Remote sections are left alone (opened on purpose, inside a dialog).
#                           nginx unescapes a backslash in a quoted argument, so the selector's quotes are written \'
#                           (served as '): written \" they were served as " and the script stopped at a syntax error
cat > "${HOME_DIR}/runner-harness.conf" << 'EOF'
location = /settings { return 302 /workspaces; }
EOF
cat > "${HOME_DIR}/runner-hide-cloud.conf" << 'EOF'
sub_filter '</head>' '<script data-harness="hide-cloud">(function(){var B={"Kanban Boards":1,"Sign in to organise your coding agents with kanban boards.":1};function hide(){document.querySelectorAll("[aria-label=\'Sign in to view projects\'],[title=\'Sign in to view projects\']").forEach(function(e){e.style.display="none"});document.querySelectorAll("p,span,h1,h2,h3,button").forEach(function(e){if(e.children.length>1)return;var t=(e.textContent||"").trim();if(B[t]){var c=e.parentElement;if(c)c.style.display="none"}else if(t==="Organization"&&e.tagName==="SPAN"){e.style.display="none"}})}new MutationObserver(hide).observe(document.documentElement,{childList:true,subtree:true,characterData:true});hide()})();</script></head>';
EOF

# connect-src's same-host websocket sources: the UIs behind this plain-HTTP loopback listener open websockets to their own host
CSP_SAME_HOST_WS='ws://$http_host wss://$http_host'  # nosemgrep: detect-insecure-websocket -- same-host websocket sources in the Content-Security-Policy of the plain-HTTP loopback listener; wss beside them
cat > "${HOME_DIR}/csp-vibe-kanban.conf" << EOF
add_header Content-Security-Policy "default-src 'self'; connect-src 'self' ${CSP_SAME_HOST_WS}; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; worker-src 'self' blob:; frame-src 'self' http://localhost:* http://127.0.0.1:* http://*.localhost:*; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'" always;
EOF

# The Goals board's own policy and the live-sync origin. The board app keeps a dozen Electric shape
# long-polls open and a browser allows six HTTP/1.1 connections per host, so every other request to the board origin
# queued behind them (reads, writes, the comments fallback, the token refresh: 17-30 s measured, the access token
# expired meanwhile). The fork moves the live shape long-polls (the first and the catch-up shape reads stay on the
# board origin) to the origin this meta tag names, kanban-sync.<home host>, a second host route to the same board
# server (below); the board's CSP lets the page connect to it (http only: the
# shapes are fetch long-polls, the board's websockets stay on its own origin). The meta goes before </head> on every
# text/html response of the board route, so a deep link's index.html carries it too; the fork reads it once, accepts
# an origin alone (//host[:port] or http(s)://host[:port]) and falls back to its own origin without it or when the
# route fails - a page without the route renders as before.
# nosemgrep: detect-insecure-websocket -- same-host websocket sources in the Content-Security-Policy of the plain-HTTP loopback listener; wss beside them
sed "s#connect-src 'self' ws://\$http_host wss://\$http_host;#connect-src 'self' ws://\$http_host wss://\$http_host http://kanban-sync.\$home_host;#" \
	"${HOME_DIR}/csp-vibe-kanban.conf" > "${HOME_DIR}/csp-kanban-board.conf"
grep -q 'http://kanban-sync\.\$home_host' "${HOME_DIR}/csp-kanban-board.conf" \
	|| { echo "home-render: ERROR - the board's CSP did not take the live-sync origin (csp-vibe-kanban.conf's connect-src changed shape)" >&2; exit 1; }
# shellcheck disable=SC2016
cat > "${HOME_DIR}/board-sync-meta.conf" << 'EOF'
sub_filter '</head>' '<meta name="harness-sync-origin" content="//kanban-sync.$home_host"></head>';
EOF

# The same badge for a location that runs its own sub_filter chain with sub_filter_once off
# (the tmux-agent /api/ rewrite below): the rule alone, since a second sub_filter_once in one
# location is a duplicate directive nginx refuses
grep '^sub_filter ' "${HOME_DIR}/badge.conf" > "${HOME_DIR}/badge-rule.conf"

# The browser egress lock of the claude-mem viewer: its bundle (claude-mem 13.x) fetches the repository's GitHub star
# count from api.github.com on every page load, from the user's browser, and the plugin has no setting for it. This
# policy lets the viewer load and connect only to its own origin - its API and its /stream events are same-origin -
# so the browser refuses that request before it leaves and the viewer shows no count. 'unsafe-inline': the viewer's
# own styles, the pre-dismiss script below and the home badge are inline; its fonts and images are its own.
cat > "${HOME_DIR}/csp-claude-mem.conf" << 'EOF'
add_header Content-Security-Policy "default-src 'self'; connect-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'" always;
EOF

{
cat << EOF
# Generated by /agent/home-render.sh - do not edit; re-rendered on every ui-start.sh run.
pid ${HOME_DIR}/nginx.pid;
error_log ${HOME_DIR}/nginx-error.log warn;
worker_processes 2;
events {
	worker_connections 512;
}
http {
	include /etc/nginx/mime.types;
	default_type application/octet-stream;
	access_log ${HOME_DIR}/nginx-access.log;
	client_body_temp_path ${HOME_DIR}/tmp/client-body;
	proxy_temp_path ${HOME_DIR}/tmp/proxy;
	fastcgi_temp_path ${HOME_DIR}/tmp/fastcgi;
	uwsgi_temp_path ${HOME_DIR}/tmp/uwsgi;
	scgi_temp_path ${HOME_DIR}/tmp/scgi;
	map \$http_upgrade \$connection_upgrade {
		default upgrade;
		'' close;
	}
	# badge-host.conf's home target: strip the FIRST hostname label and keep everything
	# after it INCLUDING the :port the browser sent (hindsight.localhost:9090 ->
	# localhost:9090). Only the *.localhost host-routed server blocks use this; the
	# path-routed locations keep badge.conf's plain href="/" and never go through the map
	# (localhost:8000 has no label to strip - the default branch, \$host, carries no port).
	map \$http_host \$home_host {
		default \$host;
		"~^[^.]+\.(?<rest>.+)\$" \$rest;
	}
	# The live-sync route's CORS (kanban-sync.localhost, below): the board's own origin alone may read it, so the
	# request's Origin must be exactly http://kanban.<home host> - the same home host and the port the browser is on.
	# The one regex compares the two halves (the Origin, then this request's home host) with a backreference; any
	# other Origin, or none, leaves every CORS header out (the browser then refuses the response to that page).
	map "\$http_origin|\$home_host" \$sync_origin {
		default "";
		"~^(http://kanban\.([^|]+))\|\2\$" \$1;
	}
	map \$sync_origin \$sync_expose {
		default "";
		"~." "electric-cursor, electric-handle, electric-offset, electric-schema, electric-up-to-date";
	}
	map \$sync_origin \$sync_methods { default ""; "~." "GET, HEAD, OPTIONS"; }
	map \$sync_origin \$sync_headers { default ""; "~." "Authorization, Content-Type"; }
	map \$sync_origin \$sync_max_age { default ""; "~." "600"; }
	# The same-origin gate (Cross-Site WebSocket Hijacking and cross-site requests): a browser sends Origin on every
	# WebSocket handshake and on every cross-origin request, so a request whose Origin names another site than the Host
	# it was sent to is refused with 403 on every server block below, before any upstream sees it - a page the operator
	# visits cannot open ws://localhost:8000/tmux/ws and type into the agent's shell, or post to a UI. No Origin (curl, a
	# CLI, a same-origin navigation) passes. The scheme is not compared, so a TLS front end before this listener keeps
	# working; host names compare case-insensitively. The one cross-origin flow of the harness, the board's live sync
	# (kanban.<home host> reading kanban-sync.<home host>), is admitted by \$sync_origin on that server block alone.
	# test-origin-gate.sh proves both, and that the terminal never upgrades for a foreign Origin.
	map "\$http_origin|\$http_host" \$foreign_origin {
		default 1;
		"~^\|" 0;
		"~*^https?://([^/|]+)\|\1\$" 0;
	}
	map "\$foreign_origin|\$sync_origin" \$sync_foreign_origin {
		default 1;
		"~^0\|" 0;
		"~^1\|." 0;
	}
	# The gate's refusal may not be framed. No server block declares a header of its own, so each inherits these two,
	# and the 403 its gate answers (before any location) carries them; for a request with no foreign Origin their values
	# are empty, which adds no header, and a location with headers of its own does not inherit them
	map \$foreign_origin \$foreign_origin_frame_options {
		default "";
		1 DENY;
	}
	map \$foreign_origin \$foreign_origin_frame_ancestors {
		default "";
		1 "frame-ancestors 'none'";
	}
	add_header X-Frame-Options \$foreign_origin_frame_options always;
	add_header Content-Security-Policy \$foreign_origin_frame_ancestors always;
EOF
if [ "${UI_TMUX_AGENT}" == "true" ]; then
cat << EOF
	# The tmux-agent dashboard's DNS-rebinding guard refuses a Host, and its CSRF guard an
	# Origin, that is not its own loopback host:port. A browser on the tunnel sends the HOME
	# port's host and origin, so a LOOPBACK Host or Origin is rewritten to the dashboard's own
	# address; any other value is forwarded as sent and the dashboard still refuses it (a
	# DNS-rebinding page arrives with its own hostname, so it reads nothing). Sec-Fetch-Site
	# passes through untouched, so a cross-site request is refused by the dashboard exactly as
	# without the proxy. An absent Origin stays absent (an empty value drops the header).
	map \$http_host \$tmux_agent_host {
		default \$http_host;
		"~^(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?\$" "127.0.0.1:${UI_PORT_TMUX_AGENT}";
	}
	map \$http_origin \$tmux_agent_origin {
		default \$http_origin;
		"~^https?://(localhost|127\\.0\\.0\\.1|\\[::1\\])(:[0-9]+)?\$" "http://127.0.0.1:${UI_PORT_TMUX_AGENT}";
	}
EOF
fi
cat << EOF
	# the UIs hold websockets open (terminal, dashboards) - do not idle them out quickly
	proxy_read_timeout 1d;
	proxy_send_timeout 1d;
	# emit RELATIVE Location headers on our trailing-slash redirects (return 302 /x/). With the
	# default (absolute_redirect on) nginx bakes its own listen port (8000) into the redirect,
	# which is wrong the moment the user forwards to a different local port (kubectl port-forward
	# 9090:8000, or ssh -L on any port) - they would be bounced to a dead :8000. A relative
	# Location resolves against whatever host:port the user is actually on.
	absolute_redirect off;

	# who may connect (every server on this listener; 403 otherwise) - see home-render.sh
	allow 127.0.0.1;
	allow ::1;
EOF
for GW in ${UI_HOME_GATEWAY}; do echo "	allow ${GW};"; done
for AF in ${UI_HOME_ALLOW_OK}; do echo "	allow ${AF};"; done
# the badge's keeper script for the two policies on this listener that admit it by its sha256 (the Guide's /guide/
# location and the Loop Deck page's <meta>, below): an empty hash (python3 failing) would leave policies that refuse it,
# so the render stops instead
KEEPER_SCRIPT_HASH=$(csp_hash "${BADGE_KEEPER}")
case "${KEEPER_SCRIPT_HASH}" in
sha256-?*) ;;
*) echo "home-render: ERROR - the home badge's keeper script hash is empty or malformed ('${KEEPER_SCRIPT_HASH}'); is python3 there?" >&2; exit 1 ;;
esac
cat << EOF
	deny all;

	# Any Host that is not one of ours answers 421 (Misdirected Request). The home listener and
	# every path route below serve the loopback names only - localhost, 127.0.0.1, [::1], plus
	# UI_HOME_HOSTNAMES - and the *.localhost UIs have their own server blocks. Before this, the
	# default server answered ANY Host, so a DNS-rebinding page the operator visited while the
	# tunnel was up could reach the writable terminal, the memory API and headlamp (whose Host
	# is overridden below) with a hostname of its own. test16.sh check 7 proves the refusal and
	# that the loopback names still answer.
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME} default_server;
		server_name _;
		if (\$foreign_origin) { return 403; }
		return 421;
	}

	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name localhost 127.0.0.1 [::1] ${UI_HOME_HOSTNAMES};
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)

		location / {
			root ${HOME_DIR}/site;
			index index.html;
		}
		# the rendered documents (the Guide; /guide/...): the floating home badge every UI carries, no caching (they are
		# re-rendered at every start) and a policy that allows the page's own inline style and the badge's, no script but
		# the badge's keeper (by its hash), nothing external
		location /guide/ {
			root ${HOME_DIR}/site;
			index index.html;
			add_header Cache-Control "no-store" always;
			add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; script-src '${KEEPER_SCRIPT_HASH}'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'" always;
			include ${HOME_DIR}/badge.conf;
		}
		# the Knowledge transfer page (/agent/knowledge-transfer.py on 127.0.0.1, docs/manual/memory.md "Moving knowledge between instances"): the
		# knowledge stores exported as one pack file and a pack imported, prefix stripped. GET and POST only - its three
		# actions are POSTs the page's server takes only with the page's own X-Knowledge-Transfer header and origin - a pack
		# of up to KNOWLEDGE_PACK_MAX bytes (the server's own limit), 900 s for an action (the server bounds each by its
		# KNOWLEDGE_REQUEST_BUDGET, 840 s, so a long one is refused with its reason, not a 504), and the page's own origin
		# only: the server's policy replaced by the same one plus the hashes of the badge's three inline pieces (KNOWLEDGE_CSP)
		location /knowledge/ {
			limit_except GET POST { deny all; }
			proxy_pass http://127.0.0.1:${UI_PORT_KNOWLEDGE}/;
			include ${HOME_DIR}/proxy-common.conf;
			include ${HOME_DIR}/badge.conf;
			proxy_hide_header Content-Security-Policy;
			add_header Content-Security-Policy "${KNOWLEDGE_CSP}" always;
			client_max_body_size ${KNOWLEDGE_PACK_MAX};
			proxy_read_timeout 900s;
		}
		location = /knowledge {
			return 302 /knowledge/;
		}
EOF

if [ -n "${SPOKES_ON}" ] || { [ "${SUPERVISOR}" == "true" ] && [ -n "${SUPERVISOR_SESSION}" ]; }; then
cat << EOF

		# the agent sessions' state for their tiles (docs/manual/agents.md "Spoke agents"): the file /agent/supervisor.sh writes after
		# each pass (404 until its first), while the supervisor or a spoke is on
		location = /__spokes {
			limit_except GET { deny all; }
			default_type application/json;
			add_header Cache-Control no-store;
			alias ${SUPERVISOR_DIR%/}/status.json;
		}
EOF
fi

# the spokes' own pages (a registry entry's page, docs/manual/agents.md "Spoke agents"): an enabled spoke with one gets that path on
# this listener, serving the STATUS.html its cycle writes in its working directory (404 until its first cycle wrote it),
# the way the Guide's pages are served: the home badge, never cached, the page's own inline style and nothing external
for N in ${SPOKES_ON}; do
	SPOKE_PAGE=$("${SPOKE_TOOL}" entry "${N}" page 2>/dev/null)
	[ -n "${SPOKE_PAGE}" ] || continue
	SPOKE_WORKDIR=$("${SPOKE_TOOL}" entry "${N}" workdir)
cat << EOF

		location = ${SPOKE_PAGE} {
			limit_except GET { deny all; }
			# the file by try_files, not alias: a path that ends in / would send alias to the index module
			root ${SPOKE_WORKDIR%/};
			try_files /STATUS.html =404;
			default_type text/html;
			add_header Cache-Control "no-store" always;
			add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; script-src '${KEEPER_SCRIPT_HASH}'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'" always;
			include ${HOME_DIR}/badge.conf;
		}
EOF
done

if [ "${UI_HEADLAMP}" == "true" ]; then
cat << EOF

		# headlamp - native base path (-base-url /headlamp, set by ui-start.sh)
		location /headlamp/ {
			proxy_pass http://127.0.0.1:${UI_PORT_HEADLAMP};
			# headlamp has DNS-rebinding protection: bound to a specific loopback
			# interface (not 0.0.0.0), or with no kubeconfig loaded, it trusts ONLY its
			# own host:port and 403s a forwarded external Host ("Rejected request with
			# unexpected Host header"). Send it its own address (via the Host variable
			# proxy-common.conf reads) so /headlamp/ answers through the proxy on ANY
			# external port and in any bind/kubeconfig state.
			set \$proxy_upstream_host 127.0.0.1:${UI_PORT_HEADLAMP};
			include ${HOME_DIR}/proxy-common.conf;
			include ${HOME_DIR}/badge.conf;
			# Compensating controls for the Go net/http advisories in the headlamp-server release binary (docs/manual/supply-chain.md "CVE
			# scan"): it is reached only over this HTTP/1.1 plaintext loopback hop (no HTTP/2, no TLS of its own); no Range
			# header reaches it (the parsed-Range CPU exhaustion, GO-2026-6609), and only the methods its UI and API use do -
			# CONNECT and the rest answer 403 here, TRACE nginx's own 405 (the CONNECT desynchronization advisories)
			proxy_set_header Range "";
			limit_except GET HEAD POST PUT PATCH DELETE OPTIONS { deny all; }
		}
		location = /headlamp {
			return 302 /headlamp/;
		}
EOF
fi

if [ "${UI_HINDSIGHT}" == "true" ]; then
cat << EOF

		# hindsight-api - prefix stripped by the trailing slash on proxy_pass
		# the default seed's extraction state (key=value lines /agent/hindsight-seed.sh writes; 404 until it ran):
		# the memory tile's note reads it with the live bank stats, so a memory API that is up but cannot call
		# Bedrock (no credentials, no model access) does not read green over empty banks
		location = /__seed-state {
			limit_except GET { deny all; }
			default_type text/plain;
			add_header Cache-Control no-store;
			alias ${UI_DIR}/hindsight-seed.state;
		}
		# the session guard's counts (key=value lines /agent/hindsight-session-guard.py writes; 404 until its first pass):
		# the memory tile's note adds what the guard set aside, marked and paused
		location = /__memory-guard {
			limit_except GET { deny all; }
			default_type text/plain;
			add_header Cache-Control no-store;
			alias ${UI_DIR}/hindsight-memory-guard.state;
		}
$(memory_api_locations badge-rule.conf)
EOF
fi

if [ "${COMMS_UI_ENABLED}" == "true" ]; then
cat << EOF

		# comms UI - native streamlit base path (--server.baseUrlPath comms)
		location /comms/ {
			proxy_pass http://127.0.0.1:${COMMS_UI_PORT};
			include ${HOME_DIR}/proxy-common.conf;
			include ${HOME_DIR}/badge.conf;
		}
		location = /comms {
			return 302 /comms/;
		}
EOF
fi

if [ "${UI_TMUX}" == "true" ]; then
cat << EOF

		# tmux browser terminal - native ttyd base path (-b /tmux); ttyd answers its page uncompressed to a
		# request without gzip in Accept-Encoding (proxy-common.conf), so the badge can be injected
		location /tmux/ {
			proxy_pass http://127.0.0.1:${UI_PORT_TMUX};
			include ${HOME_DIR}/proxy-common.conf;
			include ${HOME_DIR}/badge.conf;
		}
		location = /tmux {
			return 302 /tmux/;
		}
EOF
fi

if [ "${UI_TMUX_AGENT}" == "true" ]; then
cat << EOF

		# tmux-agent dashboard - built from TMUX_AGENT_SRC and started by ui-start.sh
		# (/agent/install-tmux-agent.sh; docs/manual/ui.md "tmux-agent dashboard"); prefix stripped
		# by the trailing slash on proxy_pass. The dashboard 403s any Host that is not its
		# own loopback host:port (DNS-rebinding guard) and any Origin that is not its own
		# (CSRF guard), so a loopback Host and Origin are sent as its own address - Host via
		# the variable proxy-common.conf reads (the headlamp pattern), both via the maps
		# above, which leave a foreign value for the dashboard to refuse. Its
		# single-file UI fetches root-absolute '/api/...' paths and has no base-path setting,
		# so those (and its favicon) are rewritten into this route; the home badge rides the
		# same sub_filter chain (badge-rule.conf: one sub_filter_once per location).
		location /tmux-agent/ {
			proxy_pass http://127.0.0.1:${UI_PORT_TMUX_AGENT}/;
			set \$proxy_upstream_host \$tmux_agent_host;
			proxy_set_header Origin \$tmux_agent_origin;
			include ${HOME_DIR}/proxy-common.conf;
			sub_filter "'/api/" "'/tmux-agent/api/";
			sub_filter 'href="/favicon.ico"' 'href="/tmux-agent/favicon.ico"';
			include ${HOME_DIR}/badge-rule.conf;
			sub_filter_once off;
		}
		location = /tmux-agent {
			return 302 /tmux-agent/;
		}
EOF
fi

# Honest status dots for the host-routed tiles: the page cannot fetch hindsight.localhost & co.
# same-origin, and a no-cors fetch resolves for ANY answer - a 502 from a dead upstream looked as
# green as a 200 (a control run kept the memory-UI dot green with its server killed). Each
# host-routed UI therefore gets a same-origin probe path on the home listener; the page reads the
# REAL status from it (data-probe on the tile, test16.sh), the link still opens the host route.
# The probe is a STATUS-ONLY, GET-only auth_request subrequest to the upstream's health path:
# the client gets 204 when the upstream answers 2xx and 500 when it does not (auth_request maps
# every non-2xx/401/403 answer to 500; the 204 is produced by try_files, which runs AFTER the
# access phase - a `return` would run before auth_request and skip it), never the upstream's body, and the subrequest carries no
# Cookie, Authorization or request body (nothing of the browser's reaches the upstream, nothing of
# the upstream's reaches the page). The upstream's own address is sent as Host (its guard accepts it).
probe_location()
{
	# probe_location <tile host label> <upstream port> <upstream health path>
	cat << EOF

		location = /__probe/$1 {
			limit_except GET { deny all; }
			auth_request /__probe_up/$1;
			# the 204 comes from try_files (precontent phase), not return: return runs in the rewrite
			# phase, BEFORE limit_except and auth_request, and would skip both
			try_files /__probe_nonexistent =204;
		}
		location = /__probe_up/$1 {
			internal;
			proxy_pass http://127.0.0.1:$2$3;
			proxy_pass_request_body off;
			proxy_set_header Content-Length "";
			proxy_set_header Cookie "";
			proxy_set_header Authorization "";
			proxy_set_header Host 127.0.0.1:$2;
		}
EOF
}
# /api/banks, not /api/health: the control plane answers 200 on its health path with the memory API stopped
# (it reports its own process), and 502 on /api/banks, which it has to fetch from the API - the dot must
# follow the API (test16 check 4 stops the API and expects the probe to go red)
[ "${UI_HINDSIGHT}" == "true" ] && probe_location hindsight "${UI_PORT_HINDSIGHT_UI}" /api/banks
# The Goals board and agent runner tiles: /__probe/kanban asks the sign-in helper for a board read that goes to its
# database (the board server's own /v1/health answers without it); without a board, kanban.localhost serves the
# runner, and so does its probe. /__probe/vk-runner is the runner's /api/health.
if [ "${UI_VIBE_KANBAN}" == "true" ]; then
	if [ -n "${KANBAN_BOARD_URL}" ]; then
		probe_location kanban "${UI_PORT_KANBAN_SIGNIN}" /healthz/board
	else
		probe_location kanban "${UI_PORT_VIBE_KANBAN}" /api/health
	fi
	probe_location vk-runner "${UI_PORT_VIBE_KANBAN}" /api/health
fi
[ "${UI_CLAUDE_MEM}" == "true" ] && probe_location claude-mem "${UI_PORT_CLAUDE_MEM}" /health
[ "${UI_LOGLEARNER}" == "true" ] && probe_location loglearner "${UI_PORT_LOGLEARNER}" /api/tile.json
# The Learned rules tile's numbers: the one upstream BODY the home page reads, and only this one - the LogLearner
# dashboard's tile contract (/api/tile.json, loglearner-tile/v1: rule and delivery counts, the bank files, and
# "degraded" naming a missing source), the document the dashboard publishes for exactly this tile and serves on
# loglearner.localhost as well. Bounded like the dot probes: this exact upstream path, GET only (POST -> 403), no
# Cookie, Authorization or request body forwarded, no Set-Cookie returned, and only under the loopback names this
# server block answers (a DNS-rebinding page gets the 421). test-agent-learning.sh check 12 proves each bound.
if [ "${UI_LOGLEARNER}" == "true" ]; then
cat << EOF

		location = /__tile/metalearner {
			limit_except GET { deny all; }
			proxy_pass http://127.0.0.1:${UI_PORT_LOGLEARNER}/api/tile.json;
			proxy_pass_request_body off;
			proxy_set_header Content-Length "";
			proxy_set_header Cookie "";
			proxy_set_header Authorization "";
			proxy_set_header Host 127.0.0.1:${UI_PORT_LOGLEARNER};
			proxy_hide_header Set-Cookie;
		}
EOF
fi
# The Board's dot: its /healthz answers 200 only while its last pass is fresh and Plane answered, so the dot reads down
# for a stopped server AND for a board that lost Plane
[ "${BOARD_ON}" == "true" ] && probe_location board "${UI_PORT_BOARD}" /healthz
# The Files tile's dot: /healthz answers 200 while the shared folder exists and the server may write it
[ "${UI_FILES}" == "true" ] && probe_location files "${UI_PORT_FILES}" /healthz
# The Agent chat tile's dot follows its backend (/healthz answers while agent-chat.py runs): the page itself says
# whether the agent session's pane is there and takes a message, so a pane that is missing or runs a shell is a
# page that explains, not a red dot
[ "${UI_CHAT}" == "true" ] && probe_location chat "${UI_PORT_CHAT}" /healthz
[ "${UI_LOOP_DECK}" == "true" ] && probe_location loop-deck "${UI_PORT_LOOP_DECK}" /status.json
# the Agent loop page's renderer answers /health with 2xx only while the page's data is fresh: a stopped renderer (no
# answer) and one that stopped writing (503) both read down
[ "${UI_LOOP}" == "true" ] && probe_location loop "${UI_PORT_LOOP}" /health
# The Plane tile's dot: the board's /api/instances/ (the instance row Plane's web app reads from its database) through
# the board's proxy. probe_location reaches loopback only and the board is a sidecar resolved per request, so this
# probe carries its own resolver and variable; GET-only and status-only like the others. It sends the browser's
# address and scheme with proxy-common.conf's values (X-Forwarded-For, X-Forwarded-Proto) but not that whole file, whose
# Host and upgrade lines are for pages. Plane allows 30 anonymous calls a minute per caller (Plane v1.4.2, no setting)
# and tells callers apart by the X-Forwarded-For its proxy passes on: without one, a request counts against the agent
# container's own address. Every open home tab's sweep (one probe per 15 s) then spent the budget of the Plane tile's
# one-click sign-in, which answered 429. With the header the dots count against the browser, like the board's own pages
if [ "${UI_PLANE}" == "true" ] && [ -n "${PLANE_URL}" ]; then
cat << EOF

		location = /__probe/plane {
			limit_except GET { deny all; }
			auth_request /__probe_up/plane;
			try_files /__probe_nonexistent =204;
		}
		location = /__probe_up/plane {
			internal;
			resolver ${PLANE_RESOLVER} valid=10s ipv6=off;
			set \$plane_probe ${PLANE_URL}/api/instances/;
			proxy_pass \$plane_probe;
			proxy_pass_request_body off;
			proxy_set_header Content-Length "";
			proxy_set_header Cookie "";
			proxy_set_header Authorization "";
			# Plane keys its limit on the X-Forwarded-For its proxy passes on, and the proxy keeps an incoming one only
			# from a sender it trusts: makeplane/plane-proxy:v1.4.2's Caddyfile has client_ip_headers X-Forwarded-For
			# X-Real-IP and trusted_proxies {\$TRUSTED_PROXIES:0.0.0.0/0}, every sender, and plane.sh sets no
			# TRUSTED_PROXIES. A TRUSTED_PROXIES that leaves out the agent container puts the probe back on the
			# container's address, the one-click sign-in's budget
			proxy_set_header X-Forwarded-For \$remote_addr;
			proxy_set_header X-Forwarded-Proto \$scheme;
		}
EOF
fi

cat << EOF
	}
EOF

if [ "${UI_PLANE}" == "true" ] && [ -n "${PLANE_URL}" ]; then
cat << EOF

	# the self-hosted Plane board - sidecar containers (docs/manual/boards.md "Plane board"); its web app has no runtime base
	# path, so a host route. proxy_pass through a variable: nginx resolves the sidecar's name per request, so a
	# board that is down or not started yet is a 502 on this route only, never an nginx that cannot start
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name plane.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
		resolver ${PLANE_RESOLVER} valid=10s ipv6=off;
		set \$plane_board ${PLANE_URL};
		# Plane's own upload limit (FILE_SIZE_LIMIT, 5 MB) with headroom
		client_max_body_size 6m;
$(harness_css_location)
		location / {
			proxy_pass \$plane_board;
			include ${HOME_DIR}/proxy-common.conf;
			# its redirects stay on plane.localhost at the browser's port, as on every host route: the board proxy's own
			# URL; an absolute plane.localhost URL Plane built from its WEB_URL, whose port need not be the browser's (an
			# ssh -L on another local port); then the shared rules (its loopback address on its port, a relative Location)
			proxy_redirect ${PLANE_URL}/ http://\$http_host/;
			proxy_redirect ~^https?://plane\\.localhost(:[0-9]+)?(/.*)?\$ http://\$http_host\$2;
$(host_redirect_rules "${PLANE_PORT}")
			# the home badge: the shared one before </body>, and after the end of each HTML page the script that
			# keeps it there through the app's own render (see badge-plane.html above in home-render.sh)
			include ${HOME_DIR}/badge-host.conf;
			add_after_body /__harness/home-badge.html;
		}
		location = /__harness/home-badge.html {
			internal;
			alias ${HOME_DIR}/badge-plane.html;
		}
EOF
if [ "${PLANE_LOGIN_BYPASS}" == "true" ]; then
cat << EOF
		# the Plane tile's one-click sign-in (/agent/plane-signin.py, loopback only): this exact URL on this host
		# route only, and the helper itself refuses any Host but plane.localhost
		location = ${PLANE_SIGNIN_PATH} {
			proxy_pass http://127.0.0.1:${UI_PORT_PLANE_SIGNIN};
			include ${HOME_DIR}/proxy-common.conf;
			# its 302 to the board is relative: made absolute on plane.localhost at the browser's port
$(host_redirect_rules "${UI_PORT_PLANE_SIGNIN}")
		}
EOF
fi
cat << EOF
	}
EOF
fi

if [ "${BOARD_ON}" == "true" ]; then
cat << EOF

	# the Board (docs/manual/boards.md "Board"): /agent/board-server.py on its loopback port, a page with root-absolute paths, so a host
	# route. GET only here too (the server itself answers 405 to anything else, and its data endpoint refuses another
	# origin). The page links the stylesheet itself, so the badge goes in without a second link; the server's own
	# Content-Security-Policy ('self' alone) is replaced by the same one plus the hashes of the badge's three inline pieces
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name board.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
		location / {
			limit_except GET { deny all; }
			proxy_pass http://127.0.0.1:${UI_PORT_BOARD};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_BOARD}")
			include ${HOME_DIR}/badge-host-nolink.conf;
			proxy_hide_header Content-Security-Policy;
			add_header Content-Security-Policy "${BOARD_CSP}" always;
		}
	}
EOF
fi

if [ "${UI_FILES}" == "true" ]; then
cat << EOF

	# the Files tile (docs/manual/ui.md "Files"): /agent/files-server.py on its loopback port, a page with root-absolute paths, so a
	# host route. GET, HEAD, PUT (an upload) and POST (a folder, a rename, a move, a delete) pass; every other method is
	# refused here (the server answers 405 to them too, and refuses another origin itself). An upload is the request body
	# as it is, so the route takes bodies up to FILES_MAX_UPLOAD_MB - the server's own cap, with one MiB of headroom so
	# the server, not nginx, answers 413 at the cap itself - and streams them through without buffering to disk. The page
	# links the stylesheet itself, so the badge goes in without a second link; the server's own Content-Security-Policy
	# ('self' alone) is replaced by the same one plus the hashes of the badge's three inline pieces
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name files.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
		client_max_body_size $((10#${FILES_MAX_UPLOAD_MB} + 1))m;
		proxy_request_buffering off;
$(harness_css_location)
		location / {
			limit_except GET HEAD PUT POST { deny all; }
			proxy_pass http://127.0.0.1:${UI_PORT_FILES};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_FILES}")
			include ${HOME_DIR}/badge-host-nolink.conf;
			proxy_hide_header Content-Security-Policy;
			add_header Content-Security-Policy "${FILES_CSP}" always;
		}
	}
EOF
fi

if [ "${UI_HINDSIGHT}" == "true" ]; then
cat << EOF

	# hindsight-ui has no runtime base path (Next.js standalone) - host route instead
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name hindsight.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
		location / {
			proxy_pass http://127.0.0.1:${UI_PORT_HINDSIGHT_UI};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_HINDSIGHT_UI}")
			include ${HOME_DIR}/badge-host.conf;
		}
	}
EOF
fi

if [ "${UI_VIBE_KANBAN}" == "true" ] && [ -n "${KANBAN_BOARD_URL}" ]; then
cat << EOF

	# the self-hosted kanban board - a sidecar container (docs/manual/boards.md "Kanban board"); an SPA with no runtime base
	# path, so a host route. proxy_pass through a variable: nginx resolves the sidecar's name per request, so a
	# board that is down or not started yet is a 502 on this route only, never an nginx that cannot start
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name kanban.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)$(relay_location)
		resolver ${KANBAN_RESOLVER} valid=10s ipv6=off;
		set \$kanban_board ${KANBAN_BOARD_URL};
		# the board's bundle has no /workspaces route: that path is the agent runner's (vk-runner.localhost), and on the
		# board it crashes ("useWorkspaceContext must be used within a WorkspaceProvider"). /workspaces and
		# everything under it go to the runner's host on the port the browser is on, the path and the query kept
		location = /workspaces {
			return 302 http://vk-runner.\$home_host\$request_uri;
		}
		location ^~ /workspaces/ {
			return 302 http://vk-runner.\$home_host\$request_uri;
		}
		location / {
			proxy_pass \$kanban_board;
			include ${HOME_DIR}/proxy-common.conf;
			# its redirects stay on kanban.localhost, as on every host route: the board's own URL, then the shared rules
			# (its loopback address on its port, and a relative Location)
			proxy_redirect ${KANBAN_BOARD_URL}/ http://\$http_host/;
$(host_redirect_rules "${KANBAN_BOARD_PORT}")
			# the badge moved left of the card panel on a wide viewport (badge_host_shift_conf above)
			include ${HOME_DIR}/badge-host-shift-board.conf;
			# the live-sync origin: the meta tag on every HTML response, and the board's CSP that lets the page reach it
			include ${HOME_DIR}/board-sync-meta.conf;
			include ${HOME_DIR}/csp-kanban-board.conf;
			# the board app is same-origin and needs no CORS; the board server allows any Origin, with credentials
			proxy_hide_header Access-Control-Allow-Origin;
			proxy_hide_header Access-Control-Allow-Credentials;
		}
		# the one-click sign-in behind the home page's Kanban board tile (/agent/kanban-signin.py, loopback only): it
		# signs in server-side and hands this origin the session; it refuses any Host but kanban.localhost itself
		location = /__harness/sign-in {
			proxy_pass http://127.0.0.1:${UI_PORT_KANBAN_SIGNIN};
			include ${HOME_DIR}/proxy-common.conf;
		}
	}

	# kanban-sync.localhost - the board's live-sync shapes on a second origin (the maps above and
	# board-sync-meta.conf explain why). The same board server, the shape endpoints ALONE: everything else on this host
	# but the harness stylesheet (on every server block, harness_css_location) is 404 - no board API, no app, no badge.
	# CORS for the board's own origin only (the maps) and never with
	# credentials (the shape fetch sends a Bearer token, no cookie); the Electric response headers the client reads are
	# exposed; the preflight is answered here and never reaches the board. The board server's own CORS (any Origin, with
	# credentials) and its exposure list are hidden as on the board route; Vary gains Origin beside the server's own.
	# Long polls: no buffering (proxy-common.conf) and a read timeout above the client's 20 s poll.
	# test18 checks 2 and 3; removing this block leaves the board route valid (the fork then stays on its own origin).
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name kanban-sync.localhost;
		if (\$sync_foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
		resolver ${KANBAN_RESOLVER} valid=10s ipv6=off;
		set \$kanban_board ${KANBAN_BOARD_URL};
		location ^~ /v1/shape/ {
			if (\$request_method = OPTIONS) {
				add_header Access-Control-Allow-Origin \$sync_origin always;
				add_header Access-Control-Allow-Methods \$sync_methods always;
				add_header Access-Control-Allow-Headers \$sync_headers always;
				add_header Access-Control-Max-Age \$sync_max_age always;
				add_header Vary Origin always;
				return 204;
			}
			proxy_pass \$kanban_board;
			include ${HOME_DIR}/proxy-common.conf;
			proxy_read_timeout 75s;
			proxy_hide_header Access-Control-Allow-Origin;
			proxy_hide_header Access-Control-Allow-Credentials;
			proxy_hide_header Access-Control-Expose-Headers;
			proxy_hide_header Access-Control-Allow-Methods;
			proxy_hide_header Access-Control-Allow-Headers;
			proxy_hide_header Access-Control-Max-Age;
			add_header Access-Control-Allow-Origin \$sync_origin always;
			add_header Access-Control-Expose-Headers \$sync_expose always;
			add_header Vary Origin always;
		}
		location / {
			return 404;
		}
	}
EOF
elif [ "${UI_VIBE_KANBAN}" == "true" ]; then
cat << EOF

	# no kanban board sidecar on this target (KANBAN_BOARD_URL unset): kanban.localhost serves the vibe-kanban
	# agent runner, as before the board (embedded SPA, no runtime base path - host route instead)
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name kanban.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
		include ${HOME_DIR}/runner-harness.conf;
		location / {
			proxy_pass http://127.0.0.1:${UI_PORT_VIBE_KANBAN};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_VIBE_KANBAN}")
			include ${HOME_DIR}/badge-host.conf;
			include ${HOME_DIR}/runner-hide-cloud.conf;
			include ${HOME_DIR}/csp-vibe-kanban.conf;
		}
	}
EOF
fi

if [ "${UI_VIBE_KANBAN}" == "true" ]; then
cat << EOF

	# the vibe-kanban agent runner (coding agents in git worktrees) on its own hostname - embedded SPA, no
	# runtime base path
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name vk-runner.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
		include ${HOME_DIR}/runner-harness.conf;
		location / {
			proxy_pass http://127.0.0.1:${UI_PORT_VIBE_KANBAN};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_VIBE_KANBAN}")
			include ${HOME_DIR}/badge-host.conf;
			include ${HOME_DIR}/runner-hide-cloud.conf;
			include ${HOME_DIR}/csp-vibe-kanban.conf;
		}
	}
EOF
fi

if [ "${UI_CLAUDE_MEM}" == "true" ]; then
CM_VIEW_FILTER=""
CM_VIEW_LOC=""
if [ "${CLAUDE_MEM_VIEWER_WRAPPER}" == "true" ]; then
	CM_VIEW_FILTER="			# the harness view (CLAUDE_MEM_VIEWER_WRAPPER): its script and stylesheet, from this server's /__harness/ location
			sub_filter '</head>' '<link rel=\"stylesheet\" href=\"/__harness/claude-mem/harness-view.css\"><script src=\"/__harness/claude-mem/harness-view.js\" defer></script></head>';"
	CM_VIEW_LOC="		# the harness view's script and stylesheet: the image's own files, read-only
		location ^~ /__harness/claude-mem/ {
			limit_except GET { deny all; }
			alias ${CLAUDE_MEM_WRAPPER_DIR}/;
		}"
fi
cat << EOF

	# claude-mem viewer: the worker's single-page UI fetches root-absolute /api/ paths and
	# streams /stream (server-sent events; proxy-common.conf already disables buffering and
	# keeps the connection open) - host route instead of a prefix
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name claude-mem.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
		location / {
			proxy_pass http://127.0.0.1:${UI_PORT_CLAUDE_MEM};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_CLAUDE_MEM}")
			include ${HOME_DIR}/badge-host-clear-${BADGE_CLAUDE_MEM_CLEARANCE}.conf;
			include ${HOME_DIR}/csp-claude-mem.conf;
			# the viewer opens behind a "Welcome to claude-mem" modal on every fresh browser profile until its
			# local dismissed flag is set (localStorage, claude-mem 13.x key): set before its bundle runs
			sub_filter '<head>' '<head><script>try{localStorage.setItem("claude-mem-welcome-dismissed-v3","true")}catch(e){}</script>';
${CM_VIEW_FILTER}
		}
${CM_VIEW_LOC}
	}
EOF
fi

if [ "${UI_LOGLEARNER}" == "true" ]; then
cat << EOF

	# LogLearner dashboard: root-absolute links (/project/..., /instincts, /hindsight) and no
	# base-path setting - host route instead of a prefix; its Hindsight page links to the memory API at
	# /memory-api on this host, so this block serves the memory API's locations too (memory_api_locations)
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name loglearner.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
$(memory_api_locations badge-host-rule.conf get-only)
		location / {
			proxy_pass http://127.0.0.1:${UI_PORT_LOGLEARNER};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_LOGLEARNER}")
			include ${HOME_DIR}/badge-host.conf;
			include ${HOME_DIR}/csp-loglearner.conf;
		}
	}
EOF
fi

if [ "${UI_CHAT}" == "true" ]; then
	# the chat page draws its look from the harness's shared stylesheet, which this block serves through
	# harness_css_location (defined by the harness design system above). Without that function the page would render
	# unstyled and its stylesheet request 404, with nothing failing: a tree that stacks the chat above a base without the
	# design system fails here, loudly, instead
	declare -F harness_css_location > /dev/null || { echo "home-render: the Agent chat route requires the harness design system (harness_css_location is not defined in this tree)" >&2; exit 1; }
cat << EOF

	# the Agent chat page (/agent/agent-chat.py, docs/manual/ui.md "Agent chat"): the agent session's pane in the browser and a
	# box that types a message at its prompt. A host of its own, so the page's same-origin check has an origin of its
	# own: the backend takes a message only from http://chat.localhost on the browser's port, and only on that Host
	# (proxy-common.conf passes the browser's Host and Origin through untouched). A message is a few kilobytes at most
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name chat.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
		client_max_body_size 64k;
		location / {
			proxy_pass http://127.0.0.1:${UI_PORT_CHAT};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_CHAT}")
			include ${HOME_DIR}/badge-host-nolink.conf;
		}
	}
EOF
fi

if [ "${UI_LOOP_DECK}" == "true" ]; then
cat << EOF

	# Loop Deck (the vendored /opt/loop-deck, harness mode over /wd/loop-deck): the page fetches every URL relative to
	# its own path and binds 127.0.0.1; a host route like the other UIs, with the badge. POST /act is refused by the
	# server itself (LOOP_DECK_ACT_TOKEN is never set here), so nothing to gate at the proxy
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name loop-deck.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
		# history.jsonl, on the Deck's static allowlist, appears with the first run record: harness mode writes no history
		# for zero runs, so on a fresh harness the page's request for it read 404. Proxied while out/ has it, an empty
		# history (200, no lines) on the Deck's 404
		location = /history.jsonl {
			proxy_pass http://127.0.0.1:${UI_PORT_LOOP_DECK};
			include ${HOME_DIR}/proxy-common.conf;
			proxy_intercept_errors on;
			error_page 404 = @loop_deck_no_history;
		}
		location @loop_deck_no_history {
			default_type text/plain;
			return 200 "";
		}
		# mermaid.min.js, also on the allowlist, is the Deck's optional diagram renderer: its release ships none (README:
		# "placed beside index.html in the served directory") and the page shows the diagrams' source when it is absent.
		# Proxied when mermaid 11's file has been placed in out/, an empty script (200, window.mermaid stays unset) on the
		# Deck's 404, so the page loads without a failed request
		location = /mermaid.min.js {
			proxy_pass http://127.0.0.1:${UI_PORT_LOOP_DECK};
			include ${HOME_DIR}/proxy-common.conf;
			proxy_intercept_errors on;
			error_page 404 = @loop_deck_no_mermaid;
		}
		location @loop_deck_no_mermaid {
			default_type application/javascript;
			return 200 "/* no mermaid.min.js in this harness: the Loop Deck shows its diagrams as source */";
		}
		location / {
			proxy_pass http://127.0.0.1:${UI_PORT_LOOP_DECK};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_LOOP_DECK}")
			include ${HOME_DIR}/badge-host.conf;
			# the Deck's page declares its own policy in a <meta> tag, whose script-src 'self' refuses the badge's keeper
			# script; the vendored page stays byte-identical on disk, so the proxy adds the keeper's hash to that tag as it
			# serves the page, as it adds the badge itself
			sub_filter "script-src 'self';" "script-src 'self' '${KEEPER_SCRIPT_HASH}';";
		}
	}
EOF
fi

# The Agent loop page's Control section (/agent/loop-view.py control()): POST only, passed on with the page's Origin and
# X-Loop-Control header, which the renderer checks. Its answers are JSON, so the badge include (the one every proxied
# host location carries) changes nothing there. The autonomy loop's page is also /loop/autonomy-loop/, whose relative
# control/ addresses land here too. With UI_LOOP_CONTROL=false the location is not written, and a POST meets the
# GET-only location / (403)
LOOP_CONTROL_LOCATION=""
if [ "${UI_LOOP_CONTROL}" == "true" ]; then
	LOOP_CONTROL_LOCATION="		location ~ ^(/loop/autonomy-loop)?/control/(run|pause)\$ {
			limit_except POST { deny all; }
			proxy_pass http://127.0.0.1:${UI_PORT_LOOP};
			include ${HOME_DIR}/proxy-common.conf;
			include ${HOME_DIR}/badge-host.conf;
		}"
fi
if [ "${UI_LOOP}" == "true" ]; then
cat << EOF

	# the Agent loop page (/agent/loop-view.py on 127.0.0.1): a host route like the other stdlib dashboards. GET only
	# (anything else is 403 here and 405 at the renderer) but for the two Control routes at the end, and its own origin
	# only - the renderer's policy is replaced by the same one plus the hashes of the badge's three inline pieces
	# (LOOP_CSP above). The fire transcripts keep the renderer's own policy (text/plain, nosniff, a sandbox that runs nothing);
	# the badge include there changes nothing, sub_filter only rewrites text/html. Each loop's page is also
	# /loop/<loop-id>/, and its transcripts under that address keep the same policy
	server {
		listen ${UI_LISTEN_HOST}:${UI_PORT_HOME};
		server_name loop.localhost;
		if (\$foreign_origin) { return 403; }
		set \$proxy_upstream_host \$http_host;
$(harness_css_location)
		location / {
			limit_except GET { deny all; }
			proxy_pass http://127.0.0.1:${UI_PORT_LOOP};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_LOOP}")
			include ${HOME_DIR}/badge-host-nolink.conf;
			proxy_hide_header Content-Security-Policy;
			add_header Content-Security-Policy "${LOOP_CSP}" always;
		}
		location /transcripts/ {
			limit_except GET { deny all; }
			proxy_pass http://127.0.0.1:${UI_PORT_LOOP};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_LOOP}")
			include ${HOME_DIR}/badge-host.conf;
		}
		location ~ ^/loop/[^/]+/transcripts/ {
			limit_except GET { deny all; }
			proxy_pass http://127.0.0.1:${UI_PORT_LOOP};
			include ${HOME_DIR}/proxy-common.conf;
$(host_redirect_rules "${UI_PORT_LOOP}")
			include ${HOME_DIR}/badge-host.conf;
		}
${LOOP_CONTROL_LOCATION}
	}
EOF
fi

cat << EOF
}
EOF
} > "${HOME_DIR}/nginx.conf"

# ---------------------------------------------------------------- home page
# Tiles are rendered from the same flags as the location blocks above. An enabled tile
# carries data-url (same-origin path) or data-host (*.localhost route; the link and probe
# are completed client-side from window.location so any tunnel port works). A disabled
# tile is grey and names the .env flag that turns the UI on.

tile()
{
	# tile <enabled> <title> <purpose> <path|@host[/path]> <flag-hint> [<extra-note>] [<off-note>] [<contract>] [<extra-html>]
	# (@host/path: a host-routed UI opened at a deep link, e.g. @hindsight/banks/<bank>?view=data; the
	# dot still probes the host's /__probe/<host> location)
	# (<contract>: a host tile that also reads a status contract, Learned rules' /__tile/metalearner - JSON
	# with status ok|degraded and the tile's numbers; the page's readContract() below fills the numbers and decides
	# the dot from it instead of the status-only probe, because a degraded contract answers HTTP 200 like an ok one)
	# <enabled>: true  - a live tile (link + probed dot)
	#            false - greyed, "off - set <flag> in .env" (+ the off-note appended)
	#            unavailable - greyed with the off-note as the WHOLE reason: a UI this harness
	#                      knows of but cannot serve (no flag turns it on), so the page says why
	ENABLED=$1
	TITLE=$2
	PURPOSE=$3
	TARGET=$4
	FLAG_HINT=$5
	NOTE=$6
	OFF_NOTE=$7
	CONTRACT=$8
	EXTRA=$9   # raw html appended inside a live tile (the memory tile's state note)
	# every live link opens in a new tab, so the home page with its dots stays where the user left it.
	# rel=opener, not the browsers' default noopener: a noopener tab is in a separate browsing context
	# group, where a link targeting the home tab's name ("do-agent-aws-home", the Harness home badge)
	# cannot find it and opens one more home tab each time; with the opener kept, the badge returns to the
	# tab that is already open. The UIs are the harness's own, behind the same loopback port.
	if [ "${ENABLED}" == "true" ]; then
		if [ "${TARGET:0:1}" == "@" ]; then
			# data-probe: the same-origin status probe for the dot (probe_location above); the link
			# itself is completed client-side to the *.localhost route on the port the browser is on,
			# at data-path (the deep link) when the target carries one
			TILE_HOST=${TARGET:1}
			TILE_PATH=/
			case "${TILE_HOST}" in
				*/*) TILE_PATH=/${TILE_HOST#*/}; TILE_HOST=${TILE_HOST%%/*} ;;
			esac
			echo "<li class=\"tile\" data-host=\"${TILE_HOST}\" data-probe=\"/__probe/${TILE_HOST}\" data-path=\"${TILE_PATH}\"${CONTRACT:+ data-contract=\"${CONTRACT}\"}><span class=\"dot\"></span><a href=\"/\" target=\"_blank\" rel=\"opener\">${TITLE}</a><p>${PURPOSE}</p><p class=\"note\">${NOTE}</p>${EXTRA}</li>"
		else
			echo "<li class=\"tile\" data-url=\"${TARGET}\"><span class=\"dot\"></span><a href=\"${TARGET}\" target=\"_blank\" rel=\"opener\">${TITLE}</a><p>${PURPOSE}</p><p class=\"note\">${NOTE}</p>${EXTRA}</li>"
		fi
	elif [ "${ENABLED}" == "external" ]; then
		# an external link (the Fleet Loop Deck): the user's browser follows it; this harness neither serves nor probes
		# it, so no data-url/data-probe (the page probes only its own routes) and a static "external" pill; noopener
		# noreferrer, unlike the harness's own UIs above: another site gets no opener and no referrer
		echo "<li class=\"tile external\"><span class=\"dot external\"></span><a href=\"${TARGET}\" target=\"_blank\" rel=\"noopener noreferrer\">${TITLE}</a><p>${PURPOSE}</p><p class=\"note\">${NOTE}</p></li>"
	elif [ "${ENABLED}" == "unavailable" ]; then
		echo "<li class=\"tile off unavailable\"><span class=\"dot\"></span><span class=\"title\">${TITLE}</span><p>${PURPOSE}</p><p class=\"note\">${OFF_NOTE}</p></li>"
	else
		[ -n "${OFF_NOTE}" ] && OFF_NOTE="; ${OFF_NOTE}"
		echo "<li class=\"tile off\"><span class=\"dot\"></span><span class=\"title\">${TITLE}</span><p>${PURPOSE}</p><p class=\"note\">off - set ${FLAG_HINT} in .env${OFF_NOTE}</p></li>"
	fi
}

TMUX_MODE="read-only - set UI_TMUX_WRITABLE=true in .env to type"
if [ "${UI_TMUX_WRITABLE}" == "true" ]; then
	TMUX_MODE="writable - keystrokes drive the agent session; set UI_TMUX_WRITABLE=false in .env for watch-only"
fi
# the terminal opens on the agent session; the menu of this container's other tmux sessions is one link away
TMUX_MODE+="; <a href=\"/tmux/?arg=pick\" target=\"_blank\" rel=\"opener\">choose a session</a>"

TILES=""
TILES+="$(tile true "Guide" "how to use the harness - the 5-minute tour, goals and the board, agent workspaces, memory, learning, troubleshooting" "/guide/" "" "static page served by the home listener itself; the source is docs/user-guide.md in the repository")"$'\n'
# Headlamp shows the clusters of the mounted ~/.kube/config and has no way to add one in the browser - the note says how
TILES+="$(tile "${UI_HEADLAMP}" "Headlamp" "Kubernetes dashboard - the cluster the agent operates on" "/headlamp/" "UI_HEADLAMP=true" "no cluster yet? run <code>aws eks update-kubeconfig --name &lt;cluster&gt;</code> in the terminal or on the host (~/.kube is mounted)")"$'\n'
# the memory UI opens straight on the seeded knowledge bank's memories (the control plane has no
# default-bank setting; its /banks/<id> page is the only way in) - HINDSIGHT_DEFAULT_BANK picks another
HINDSIGHT_DEFAULT_BANK=${HINDSIGHT_DEFAULT_BANK:-harness-knowledge}
TILES+="$(tile "${UI_HINDSIGHT}" "Memory" "the agent's long-term memory (Hindsight) - banks, memories, operations; opens on the ${HINDSIGHT_DEFAULT_BANK} bank" "@hindsight/banks/${HINDSIGHT_DEFAULT_BANK}?view=data" "UI_HINDSIGHT=true" "served on its own hostname (no base-path support upstream); the memory HTTP API and its interactive docs: <a href=\"/memory-api/docs\" target=\"_blank\" rel=\"opener\">/memory-api/docs</a>; export this harness's knowledge, or import another's: <a href=\"/knowledge/\" target=\"_blank\" rel=\"opener\">Knowledge transfer</a>" "" "" "<p class=\"memory\" id=\"memory-state\">memory: checking the seeded banks</p>")"$'\n'
# The board tile names WHERE the login is, never the login itself
if [ -n "${KANBAN_BOARD_URL}" ]; then
	KANBAN_TARGET="@kanban/__harness/sign-in"
	KANBAN_NOTE="a self-hosted vibe-kanban board; this link signs you in (the login is in ${KANBAN_AUTH_FILE}, the project's wd/kanban/kanban.env on the host, created by the first ./run.sh); the first load after a container start takes up to half a minute"
else
	KANBAN_TARGET="@kanban/workspaces"
	KANBAN_NOTE="no board server on this target - this link opens the vibe-kanban agent runner's workspaces; ./run.sh (TO=docker or compose) starts the board"
fi
TILES+="$(tile "${UI_VIBE_KANBAN}" "Goals board" "what the agent is working on: one card per goal, moved To do, In progress, In review, Done by its autonomy loop fires" "${KANBAN_TARGET}" "UI_VIBE_KANBAN=true" "${KANBAN_NOTE}")"$'\n'
# The runner tiles open /workspaces, not the runner's start page: a first visit there goes through its onboarding,
# which ends in a vibe-kanban cloud sign-in; the workspaces need no account
TILES+="$(tile "${UI_VIBE_KANBAN}" "Agent workspaces" "start coding agents on a repository, each in its own git worktree, and review their changes (vibe-kanban)" "@vk-runner/workspaces" "UI_VIBE_KANBAN=true" "vibe-kanban's agent runner, opened at its workspaces with the repositories under /wd in Recent (clone into /wd, then Browse or re-run /agent/vk-runner-repos.sh), no sign-in; its board pages need the retired vibe-kanban cloud, whose prompts are hidden - use the Goals board")"$'\n'
TILES+="$(tile "${COMMS_UI_ENABLED}" "Conversations" "the communication channels (Comms UI) - which conversations need a human" "/comms/" "COMMS_UI_ENABLED=true" "")"$'\n'
TILES+="$(tile "${UI_TMUX}" "tmux terminal" "live browser terminal attached to the agent tmux session" "/tmux/" "UI_TMUX=true" "${TMUX_MODE}")"$'\n'
# The Agent chat page (docs/manual/ui.md "Agent chat"): the same session as the terminal, as a page with a send box. It follows
# the terminal's mode: watch-only (UI_TMUX_WRITABLE=false) shows the pane and keeps the box off
CHAT_NOTE="the same tmux session the terminal shows; a message is typed at the agent's prompt and submitted - the page says when it was typed, the screen shows what the agent does with it"
if [ "${UI_TMUX_WRITABLE}" != "true" ]; then
	CHAT_NOTE="watch-only (UI_TMUX_WRITABLE=false in .env): the page shows the agent session's screen, its send box is off"
fi
TILES+="$(tile "${UI_CHAT}" "Agent chat" "talk to the agent without Slack - the agent session's screen, and a box that types your message at its prompt" "@chat" "UI_CHAT=true" "${CHAT_NOTE}")"$'\n'
TILES+="$(tile "${UI_TMUX}" "tmux cheatsheet" "static tmux reference for the shared agent session - detach, windows, panes, scrollback" "/tmux-help/" "UI_TMUX=true" "static page served by the home listener itself")"$'\n'
TMUX_AGENT_NOTE="vendored build in the image; set TMUX_AGENT_SRC to build another source"
if [ -n "${TMUX_AGENT_SRC}" ]; then
	TMUX_AGENT_NOTE="built from TMUX_AGENT_SRC by install-tmux-agent.sh at first start"
fi
TILES+="$(tile "${UI_TMUX_AGENT}" "tmux-agent dashboard" "session dashboard for tmux-run agents - fleet tree, history, waste" "/tmux-agent/" "UI_TMUX_AGENT=true" "${TMUX_AGENT_NOTE}" "source: the build vendored in the image (/opt/tmux-agent), or TMUX_AGENT_SRC to build another")"$'\n'
TILES+="$(tile "${UI_CLAUDE_MEM}" "Session memory" "what the claude-mem plugin captures from the agent's sessions - observations, summaries, prompts" "@claude-mem" "UI_CLAUDE_MEM=true" "served on its own hostname (the viewer uses root-absolute paths)")"$'\n'
TILES+="$(tile "${UI_LOGLEARNER}" "Session insights" "LogLearner - gaps, instincts and learned rules mined from the agent's own Claude Code sessions, with a Hindsight panel" "@loglearner" "UI_LOGLEARNER=true" "served on its own hostname (the dashboard uses root-absolute links)")"$'\n'
# Learned rules (docs/naming.md N3; LogLearner calls it the Meta Learner): the LogLearner knowledge bank the agent learns from - the rules the PreToolUse hook delivers
# before an Edit, Write or Bash call (/agent/loglearner-hook.sh) and what /agent/learn.sh banks. Its link opens
# the banked rules (/learnings); its dot is the LogLearner dashboard's own status-only probe (/__probe/loglearner:
# the same upstream, and the dashboard has no data-free health path to give it one of its own), and its numbers
# and its ok/degraded state come from the dashboard's tile contract (/__tile/metalearner, above).
META_NUMS="<span data-k=\"instincts\">-</span> rules &middot; <span data-k=\"banks\">-</span> bank file(s) &middot; <span data-k=\"exposures\">-</span> deliveries (<span data-k=\"exposures_24h\">-</span> in 24 h)<span class=\"why\"></span>"
TILES+="$(tile "${UI_LOGLEARNER}" "Learned rules" "the knowledge bank the agent learns from - rules delivered into its sessions before each Edit, Write and Bash call, and what it banks" "@loglearner/learnings" "UI_LOGLEARNER=true" "${META_NUMS}" "" "/__tile/metalearner")"$'\n'
# The Plane tile (a new tab, as every tile): with the one-click sign-in its link is the sign-in URL. The note names
# where the login is, never the login itself. The board is opt-in (docs/manual/boards.md "Plane board"): with UI_PLANE false there is
# NO tile - not a greyed one with a flag hint - because nothing of Plane is pulled, started or shown unless a person
# accepts its license (AGPL-3.0) and turns it on (UI_PLANE=true in .env.local, then ./build.sh and ./run.sh)
PLANE_PURPOSE="project-management board - the agent's goals as work items, moved by its autonomy loop fires, and the work it tracks there without firing on it"
if [ "${UI_PLANE}" != "true" ]; then
	:   # off (the shipped default): no Plane tile - the board is opt-in, and off nothing of it is shown
elif [ -z "${PLANE_URL}" ]; then
	TILES+="$(tile unavailable "Project board (Plane)" "${PLANE_PURPOSE}" "" "" "" "not on this target - ./run.sh with TO=docker runs Plane as sidecar containers")"$'\n'
elif [ "${PLANE_LOGIN_BYPASS}" == "true" ]; then
	TILES+="$(tile "${UI_PLANE}" "Project board (Plane)" "${PLANE_PURPOSE}" "@plane${PLANE_SIGNIN_PATH}" "UI_PLANE=true" "self-hosted Plane; opens in a new tab already signed in (loopback-only convenience; PLANE_LOGIN_BYPASS=false in .env for Plane's own login page - the login is in ${PLANE_AUTH_FILE})")"$'\n'
else
	TILES+="$(tile "${UI_PLANE}" "Project board (Plane)" "${PLANE_PURPOSE}" "@plane" "UI_PLANE=true" "self-hosted Plane; opens in a new tab at Plane's login page - sign in with PLANE_ADMIN_EMAIL and PLANE_ADMIN_PASSWORD from ${PLANE_AUTH_FILE} (the project's wd/plane/plane.env on the host)")"$'\n'
fi
# The Board tile (docs/manual/boards.md "Board"): read-only, this harness's own Plane project as columns and cards with the agent
# runner's attempts on them. It needs the Plane board: with the board off (UI_PLANE false) there is no Board tile either;
# with it on, UI_BOARD=false greys the tile with its flag and a target without the sidecars greys it with that reason
BOARD_PURPOSE="read-only kanban view of the agent's goals: the Plane project's columns and cards, each with the agent runner's attempts on it"
if [ "${UI_PLANE}" != "true" ]; then
	:   # the Plane board off (the shipped default): no Board tile either - it reads that board
elif [ "${UI_BOARD}" != "true" ]; then
	TILES+="$(tile false "Board" "${BOARD_PURPOSE}" "" "UI_BOARD=true" "")"$'\n'
elif [ -z "${PLANE_URL}" ]; then
	TILES+="$(tile unavailable "Board" "${BOARD_PURPOSE}" "" "" "" "not on this target - ./run.sh with TO=docker runs Plane as sidecar containers, which the Board reads")"$'\n'
else
	TILES+="$(tile true "Board" "${BOARD_PURPOSE}" "@board" "UI_BOARD=true" "served on its own hostname; refreshes every 30 s; an attempt shows on a card when its name or branch carries the card's key (AGENT-3)")"$'\n'
fi
# The Files tile (docs/manual/ui.md "Files"): the shared folder between the person and the agent, served by the harness itself
# (/agent/files-server.py); off, it greys with its flag
FILES_PURPOSE="download what the agent produced for you, upload files for it to read - the shared folder ${FILES_DIR}, with folders, rename, move and delete"
TILES+="$(tile "${UI_FILES}" "Files" "${FILES_PURPOSE}" "@files" "UI_FILES=true" "served on its own hostname; uploads up to ${FILES_MAX_UPLOAD_MB} MiB each (FILES_MAX_UPLOAD_MB in .env); every download is saved, never shown; nothing is executed")"$'\n'
# The Agent loop page, rendered by /agent/loop-view.py from the loop's state files; its dot reads the
# renderer's /health, up only while the page's data is fresh
TILES+="$(tile "${UI_LOOP}" "Agent loop" "the autonomy loop at a glance - state and health, fires with their transcripts, goals, what needs attention, and the fleet it runs in" "@loop" "UI_LOOP=true" "served on its own hostname - Run next fire and Pause loop on the page, which lists the other loop commands to copy")"$'\n'
# The Loop Deck tile: Loop Deck is the loop observability console of a fleet this harness is part of - fire timelines,
# breakers, history and runbook. The image ships the Deck itself (/opt/loop-deck, VENDORED.md) and runs it in harness
# mode over the inputs this harness writes for its own loops under /wd/loop-deck (/agent/loop-deck-adapter.py, at UI
# start and after every fire), on loop-deck.localhost like the other UIs, with its actions off. An operator who runs a
# fleet Deck elsewhere names it with LOOP_DECK_URL - the URL as the BROWSER reaches it, since the link is followed by
# the user's browser and never proxied (an SSH tunnel to the deck's loopback port works: http://localhost:8091/) - and
# the tile becomes an external link to that Deck instead. Only a plain http(s)://host[:port][/path] value is linked; any
# other (another scheme, nginx or HTML syntax) is refused with a warning and the served tile stays.
LOOP_DECK_URL=${LOOP_DECK_URL:-}
LOOP_DECK_PURPOSE="the fleet's loop observability console (Loop Deck) - fire timelines, breakers, history and runbook of the loops this harness runs among"
if [ -n "${LOOP_DECK_URL}" ] && printf '%s' "${LOOP_DECK_URL}" | grep -qE '^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~!$&()*+,;=:@/%#?-]*)?$'; then
	TILES+="$(tile external "Fleet Loop Deck" "${LOOP_DECK_PURPOSE}" "${LOOP_DECK_URL//&/&amp;}" "" "opens the fleet's Loop Deck at LOOP_DECK_URL in a new tab - external: not served or probed by this harness")"$'\n'
else
	[ -z "${LOOP_DECK_URL}" ] || echo "home-render: WARNING - LOOP_DECK_URL is not a plain http(s)://host[:port][/path] URL; no Fleet Loop Deck tile (the served Loop Deck tile stays)"
	TILES+="$(tile "${UI_LOOP_DECK}" "Loop Deck" "${LOOP_DECK_PURPOSE}" "@loop-deck" "UI_LOOP_DECK=true" "the Deck shipped in the image (/opt/loop-deck, harness mode) over this harness's own loops, rendered from /wd/loop-deck after every fire; actions are off (every POST /act answers 403); LOOP_DECK_URL links a fleet Deck instead")"$'\n'
fi

# One tile per spoke agent of the registry (docs/manual/agents.md "Spoke agents", /agent/spokes/registry.json): every spoke whose
# charter is in the image, and every enabled flag without one. A spoke is not a UI behind this proxy, so its tile carries
# class "spoke" and no probe: off, it names its flag like every tile; on, the page's script reads its state - starting,
# live (a cycle completed since its start), waiting (for settings its cycle needs) or stuck - from the supervisor's
# /__spokes, with its last cycle and its
# last message. Registry text is escaped like any text the page did not write.
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
spoke_tile()
{
	N=$1
	CHARTER=$("${SPOKE_TOOL}" entry "${N}" charter)
	FLAG=$("${SPOKE_TOOL}" flag "${N}")
	ID=$(echo "${N}" | esc)
	if [ -f "${CHARTER}" ]; then
		T=$("${SPOKE_TOOL}" entry "${N}" title | esc)
		PURPOSE=$("${SPOKE_TOOL}" entry "${N}" task | esc)
		WRITES=$("${SPOKE_TOOL}" entry "${N}" writes --list | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
		NOTE="writes only ${WRITES}; $("${SPOKE_TOOL}" entry "${N}" cost)"
		NOTE=$(echo "${NOTE}" | esc)
	else
		T="Spoke ${ID}"
		PURPOSE="its charter is not in this image yet ($(echo "${CHARTER}" | esc))"
		NOTE=""
	fi
	if ! "${SPOKE_TOOL}" enabled "${N}"; then
		echo "<li class=\"tile spoke off\" data-spoke=\"${ID}\"><span class=\"dot\"></span><span class=\"title\">${T}</span><p>${PURPOSE}</p><p class=\"note\">off - set ${FLAG}=true in .env.local; ${NOTE}</p></li>"
		return
	fi
	# its session is on the tmux-agent dashboard, with its lineage; a spoke with a page of its own (the registry's page,
	# served above from what its cycle writes) links that page instead
	LINK="<span class=\"title\">${T}</span>"
	[ "${UI_TMUX_AGENT}" == "true" ] && LINK="<a href=\"/tmux-agent/\" target=\"_blank\" rel=\"opener\">${T}</a>"
	PAGE=$("${SPOKE_TOOL}" entry "${N}" page 2>/dev/null | esc)
	[ -n "${PAGE}" ] && LINK="<a href=\"${PAGE}\" target=\"_blank\" rel=\"opener\">${T}</a>"
	echo "<li class=\"tile spoke\" data-spoke=\"${ID}\"><span class=\"dot\"></span>${LINK}<p>${PURPOSE}</p><p class=\"note\">${NOTE}</p><p class=\"note spoke-state\">checking the spoke</p></li>"
}
SPOKE_TILES=""
# the supervisor's tile first: off it names its flag; on, the page's script reads the age of its last pass
if [ -n "${SUPERVISOR_SESSION}" ]; then
	SUP_T=$("${SPOKE_TOOL}" entry "${SUPERVISOR_SESSION}" title | esc)
	SUP_P=$("${SPOKE_TOOL}" entry "${SUPERVISOR_SESSION}" task | esc)
	SUP_W=$("${SPOKE_TOOL}" entry "${SUPERVISOR_SESSION}" writes --list | awk 'NR > 1 { printf ", " } { printf "%s", $0 }' | esc)
	SUP_NOTE="writes only ${SUP_W}; no model calls"
	if [ "${SUPERVISOR}" == "true" ]; then
		LINK="<span class=\"title\">${SUP_T}</span>"
		[ "${UI_TMUX_AGENT}" == "true" ] && LINK="<a href=\"/tmux-agent/\" target=\"_blank\" rel=\"opener\">${SUP_T}</a>"
		SPOKE_TILES+="<li class=\"tile spoke\" data-supervisor=\"$(echo "${SUPERVISOR_SESSION}" | esc)\"><span class=\"dot\"></span>${LINK}<p>${SUP_P}</p><p class=\"note\">${SUP_NOTE}</p><p class=\"note spoke-state\">checking the supervisor</p></li>"$'\n'
	else
		SPOKE_TILES+="<li class=\"tile spoke off\" data-supervisor=\"$(echo "${SUPERVISOR_SESSION}" | esc)\"><span class=\"dot\"></span><span class=\"title\">${SUP_T}</span><p>${SUP_P}</p><p class=\"note\">off - set SUPERVISOR=true in .env.local; ${SUP_NOTE}</p></li>"$'\n'
	fi
fi
for N in $("${SPOKE_TOOL}" names 2>/dev/null); do
	if [ -f "$("${SPOKE_TOOL}" entry "${N}" charter)" ] || "${SPOKE_TOOL}" enabled "${N}"; then
		SPOKE_TILES+="$(spoke_tile "${N}")"$'\n'
	fi
done
AGENTS_HTML=""
# the spokes that run, and how to turn one off: the registry's enabled ones as rendered, and the page's script puts the
# supervisor's last pass in their place (each with its state)
if [ -n "${SPOKES_ON}" ]; then
	AGENTS_ON="On:$(echo "${SPOKES_ON}" | sed -e 's/ /, /g' -e 's/^,//' | esc). To turn one off, set SPOKE_&lt;NAME&gt;=false in .env.local, then ./stop.sh &amp;&amp; ./run.sh."
else
	AGENTS_ON="Every spoke is off. To run one, set SPOKE_&lt;NAME&gt;=true in .env.local, then ./stop.sh &amp;&amp; ./run.sh."
fi
if [ -n "${SPOKE_TILES}" ]; then
	AGENTS_HTML="<h2 class=\"group\">Agents</h2>
<p class=\"group-note\" id=\"agents-on\">${AGENTS_ON}</p>
<ul class=\"tiles\">
${SPOKE_TILES}</ul>"
fi

# The North Star section (docs/NORTH-STAR.md, served at /guide/north-star/): the harness's goal as rows a named check can
# fail, rendered from the register the image ships at /agent/north-star.json (docs/north-star.json in the repository;
# NORTH_STAR_JSON names another file - the tests plant one). Each row, and each agent of the stack, carries its id, verdict
# and today's result as data attributes, which test-board.sh and test-north-star.sh compare with the file and with the
# document: the page can never say more than the register does. An agent with no tracked check reads "no tracked check" in
# its check column, never a blank. The components' own North Stars follow, a public repository's linked. A missing or
# malformed register renders as one line saying so, never as an empty section. Its look is the stylesheet's (.hs-card,
# .hs-table, code, .hs-dot); the page's style block sets only its spacing and the no-wrap of its short columns
NORTH_STAR_JSON=${NORTH_STAR_JSON:-/agent/north-star.json}
north_star_html()
{
	NORTH_STAR_JSON="${NORTH_STAR_JSON}" python3 - << 'NSPY'
import html, json, os, re
path = os.environ["NORTH_STAR_JSON"]
e = html.escape
URL = re.compile(r"""https?://[^\s<>"']*[^\s<>"'.,;:)]""")
def linked(text):
    # a component's where, with each http(s) URL in it a link that opens in a new tab with no opener and no referrer; the
    # URLs are found in the raw text and every part is escaped on its own, so no entity (a quote's &#x27;) enters an href
    out, at = [], 0
    for m in URL.finditer(text):
        out.append(e(text[at:m.start()]) + '<a href="%s" target="_blank" rel="noopener noreferrer">%s</a>' % (e(m.group(0)), e(m.group(0))))
        at = m.end()
    return "".join(out) + e(text[at:])
try:
    d = json.load(open(path, encoding="utf-8"))
    assert isinstance(d, dict), "the register is not an object"
    rows = d["rows"]
    assert isinstance(rows, list) and rows and all(isinstance(r, dict) for r in rows), "rows must be objects"
except Exception as exc:  # a missing file, invalid JSON, a root or a row that is not an object: one line, never no section
    print('<section class="north-star hs-card" id="north-star"><h2>North Star</h2><p class="hs-error">the register '
          + e(path) + ' is missing or unreadable (' + e(type(exc).__name__) + ') - the image ships docs/north-star.json there</p></section>')
    raise SystemExit(0)
klass = {"YES": "ok", "YES*": "stale", "NO": "bad"}
out = ['<section class="north-star hs-card" id="north-star" aria-labelledby="north-star-h" data-ns-rows="%d" data-ns-agents="%d" data-ns-updated="%s">'
       % (len(rows), len(d.get("agents") or []), e(str(d.get("updated", ""))))]
out.append('<h2 id="north-star-h">%s</h2>' % e(str(d.get("title") or "North Star")))
out.append('<p class="ns-statement">%s</p>' % e(str(d.get("statement", ""))))
out.append('<p class="ns-rule">%s</p>' % e(str(d.get("rule", ""))))
out.append('<table class="hs-table ns-table"><thead><tr><th>ID</th><th>The harness must</th><th>Check that fails if the property is removed</th><th>Verdict</th><th>Today</th><th>Caveat</th></tr></thead><tbody>')
for r in rows:
    st, today, check = str(r.get("status", "")), r.get("today"), r.get("check")
    today = "" if today is None else str(today)   # a row scored NO has no check and no result, as an agent scored NO
    out.append('<tr data-ns-id="%s" data-ns-status="%s" data-ns-today="%s">' % (e(str(r.get("id", ""))), e(st), e(today)))
    out.append('<td data-label="ID">%s</td>' % e(str(r.get("id", ""))))
    out.append('<td data-label="The harness must">%s</td>' % e(str(r.get("goal", ""))))
    out.append('<td data-label="Check">%s</td>' % ('<code>%s</code>' % e(str(check)) if check else 'no tracked check'))
    out.append('<td data-label="Verdict"><span class="ns-verdict hs-dot %s">%s</span></td>' % (klass.get(st, "bad"), e(st)))
    out.append('<td data-label="Today">%s</td>' % e(today or "-"))
    out.append('<td data-label="Caveat">%s</td>' % e(str(r.get("caveat", ""))))
    out.append('</tr>')
out.append('</tbody></table>')
agents = d.get("agents") or []
if isinstance(agents, list) and agents and all(isinstance(x, dict) for x in agents):
    out.append('<h3 class="ns-agents-h">The agents</h3>')
    out.append('<p class="ns-agents-note">%s</p>' % e(str(d.get("agents_note", ""))))
    out.append('<table class="hs-table ns-agents"><thead><tr><th>Agent</th><th>North Star</th><th>UI it keeps</th><th>Talks to</th>'
               '<th>Check that fails if the property is removed</th><th>Verdict</th><th>Today</th><th>Caveat</th></tr></thead><tbody>')
    for x in agents:
        st, today, check = str(x.get("status", "")), x.get("today"), x.get("check")
        today = "" if today is None else str(today)   # an agent scored NO has no result: an empty attribute, a dash in its cell
        out.append('<tr data-ns-agent="%s" data-ns-agent-status="%s" data-ns-agent-today="%s">' % (e(str(x.get("agent", ""))), e(st), e(today)))
        out.append('<td data-label="Agent"><code>%s</code></td>' % e(str(x.get("agent", ""))))
        out.append('<td data-label="North Star">%s</td>' % e(str(x.get("north_star", ""))))
        out.append('<td data-label="UI it keeps">%s</td>' % e(str(x.get("ui", ""))))
        out.append('<td data-label="Talks to">%s</td>' % e(str(x.get("talks_to", ""))))
        out.append('<td data-label="Check">%s</td>' % ('<code>%s</code>' % e(str(check)) if check else 'no tracked check'))
        out.append('<td data-label="Verdict"><span class="ns-verdict hs-dot %s">%s</span></td>' % (klass.get(st, "bad"), e(st)))
        out.append('<td data-label="Today">%s</td>' % e(today or "-"))
        out.append('<td data-label="Caveat">%s</td>' % e(str(x.get("caveat", ""))))
        out.append('</tr>')
    out.append('</tbody></table>')
comps = d.get("components") or []
if isinstance(comps, list) and comps and all(isinstance(c, dict) for c in comps):
    out.append('<h3 class="ns-components-h">The components\' own North Stars</h3>')
    out.append('<p class="ns-components-note">%s</p>' % e(str(d.get("components_note", ""))))
    out.append('<table class="hs-table ns-components" data-ns-components="%d"><thead><tr><th>Component</th><th>Agent</th>'
               '<th>Where its North Star lives</th><th>As of</th><th>State</th></tr></thead><tbody>' % len(comps))
    for c in comps:
        out.append('<tr data-ns-component="%s">' % e(str(c.get("name", ""))))
        out.append('<td data-label="Component">%s</td>' % e(str(c.get("name", ""))))
        out.append('<td data-label="Agent"><code>%s</code></td>' % e(str(c.get("agent", ""))))
        out.append('<td data-label="Where its North Star lives">%s</td>' % linked(str(c.get("where", ""))))
        out.append('<td data-label="As of">%s</td>' % e(str(c.get("as_of", ""))))
        out.append('<td data-label="State">%s</td>' % e(str(c.get("state", ""))))
        out.append('</tr>')
    out.append('</tbody></table>')
sc = d.get("scoring") or {}
out.append('<p class="ns-legend">' + ' &middot; '.join('<strong>%s</strong> %s' % (e(k), e(str(v))) for k, v in sc.items()) + '</p>')
out.append('<p class="ns-links">Updated %s &middot; <a href="/guide/north-star/">the full register, docs/NORTH-STAR.md</a> &middot; <a href="/guide/ga-release/">its companion, the release checklist docs/GA-RELEASE.md</a></p>'
           % e(str(d.get("updated", ""))))
out.append('</section>')
print("\n".join(out))
NSPY
}
NORTH_STAR_HTML=$(north_star_html)
[ -n "${NORTH_STAR_HTML}" ] || echo "home-render: WARNING - the North Star section rendered empty (${NORTH_STAR_JSON})" >&2

# The home page by the user's task: every tile above is placed under its group by its NAME, in the decided order -
#   Get started          the Guide, the first tile on the page
#   Run and review       what the agent works on and where its work lands
#   Memory and learning  what it remembers and what it learned
#   Administration       the cluster, the terminal, the dashboards
# - and a tile whose name no group lists lands under "Other", so a new tile is never lost; a name listed here before its
# tile exists (Agent loop, Agent chat, Board, Learned rules) takes its place the day the tile arrives. The headings are
# written once, in the page below.
tile_title()
{
	# tile_title <tile line> - the title of one rendered tile: live (the link's text), external (the link's text of the Fleet
	# Loop Deck tile, class "tile external") or greyed (the .title span)
	sed -E 's#^<li class="tile" [^>]*><span class="dot"></span><a [^>]*>([^<]*)</a>.*#\1#; t; s#^<li class="tile external"><span class="dot external"></span><a [^>]*>([^<]*)</a>.*#\1#; t; s#^<li class="tile off[^"]*"><span class="dot"></span><span class="title">([^<]*)</span>.*#\1#' <<< "$1"
}
group_tiles()
{
	# group_tiles <title>... - the tiles of TILES whose titles are listed, in the listed order, one per line
	local T L
	for T in "$@"; do
		while IFS= read -r L; do
			[ -n "${L}" ] && [ "$(tile_title "${L}")" == "${T}" ] && echo "${L}"
		done <<< "${TILES}"
	done
}
GROUP_START=("Guide")
GROUP_RUN=("Agent loop" "Agent chat" "Files" "Goals board" "Agent workspaces" "Project board (Plane)" "Board" "Conversations" "Fleet Loop Deck" "Loop Deck")
GROUP_MEMORY=("Memory" "Session memory" "Learned rules" "Session insights")
GROUP_ADMIN=("Headlamp" "tmux terminal" "tmux cheatsheet" "tmux-agent dashboard")
TILES_START=$(group_tiles "${GROUP_START[@]}")
TILES_RUN=$(group_tiles "${GROUP_RUN[@]}")
TILES_MEMORY=$(group_tiles "${GROUP_MEMORY[@]}")
TILES_ADMIN=$(group_tiles "${GROUP_ADMIN[@]}")
TILES_OTHER=""
while IFS= read -r L; do
	[ -n "${L}" ] || continue
	T=$(tile_title "${L}"); KNOWN=false
	for K in "${GROUP_START[@]}" "${GROUP_RUN[@]}" "${GROUP_MEMORY[@]}" "${GROUP_ADMIN[@]}"; do [ "${K}" == "${T}" ] && KNOWN=true; done
	[ "${KNOWN}" == "true" ] || TILES_OTHER+="${L}"$'\n'
done <<< "${TILES}"
OTHER_HTML=""
if [ -n "${TILES_OTHER}" ]; then
	OTHER_HTML="<h2 class=\"group\">Other</h2>
<ul class=\"tiles\">
${TILES_OTHER}</ul>"
fi

# The "Start here" strip: one sentence and the one primary action - give the agent a goal. With the board, the action
# opens the Goals board (signed in, like its tile); without one, the Guide's goals section.
if [ "${UI_VIBE_KANBAN}" == "true" ] && [ -n "${KANBAN_BOARD_URL}" ]; then
	START_ACTION='<a class="primary" data-host="kanban" data-path="/__harness/sign-in" href="/" target="_blank" rel="noopener">Open the Goals board</a>'
	START_HOW='open the <strong>Goals board</strong> and add a card, or add a goal to <code>/wd/goals/GOALS.md</code>'
else
	START_ACTION='<a class="primary" href="/guide/#goals-and-the-goals-board-vibe-kanban">How to add a goal</a>'
	START_HOW='add a goal to <code>/wd/goals/GOALS.md</code> (the Guide shows the format)'
fi

# The strip's promise follows the loop's autostart gate - the shared decision in slack-gates.sh (AUTONOMY_LOOP=true on,
# false off, auto or unset on only while Slack is configured): a loop that will not run is not promised a fire, the page
# says what turns it on instead
LOOP_GATE=$("$(dirname "$0")/slack-gates.sh" loop 2>/dev/null)
if [ "${LOOP_GATE}" == "on" ]; then
	START_LOOP="The autonomy loop picks it up at its next fire and writes the result on the goal's card."
else
	START_LOOP="Enable the autonomy loop (<code>AUTONOMY_LOOP=true</code> in .env, or <code>/agent/loop-start.sh</code> in the terminal) and it picks the goal up at its next fire; until then the goal waits."
fi
cat > "${HOME_DIR}/site/index.html" << EOF
<!DOCTYPE html>
<html lang="en" class="hs-root">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>do-agent-aws harness</title>
<link rel="stylesheet" href="${HARNESS_CSS_PATH}">
<style>
/* Layout only - the look (colours, type, spacing, both themes) is the harness stylesheet's (${HARNESS_CSS_PATH},
   docs/UI-STYLE.md): every value below is one of its tokens, so this page and every other page the harness builds share
   one palette. Each tile's state is a word with a shape - checking, up, down, off - never a colour alone. */
ul.tiles, footer { max-width: 1700px; margin: 0 auto; }
ul.tiles { list-style: none; display: grid; grid-template-columns: repeat(auto-fill, minmax(min(280px, 100%), 1fr)); gap: var(--hs-space-3); padding: 24px var(--hs-space-4); }
li.tile { background: var(--hs-surface); border: 1px solid var(--hs-border); border-radius: var(--hs-radius); padding: 14px var(--hs-space-3) 10px; position: relative; }
li.tile a, li.tile .title { font-size: 16px; font-weight: 600; color: var(--hs-accent); text-decoration: none; }
li.tile a[target="_blank"]::after { content: " \2197" / " (opens in a new tab)"; font-weight: 400; }
li.tile:not(.off):hover { border-color: var(--hs-accent); box-shadow: 0 2px 8px color-mix(in srgb, var(--hs-accent) 18%, transparent); }
li.tile p { margin: 6px 0 0; font-size: 13px; color: var(--hs-fg); clear: right; }
li.tile p.note { color: var(--hs-muted); font-size: 12px; min-height: 1em; }
li.tile.off { background: color-mix(in srgb, var(--hs-surface) 55%, var(--hs-bg)); border-style: dashed; }
li.tile.off .title, li.tile.off p, li.tile.off p.note { color: var(--hs-muted); }
/* a link inside a tile's note takes its own click, above whatever a title link may stretch over the tile */
li.tile p.note a { position: relative; z-index: 1; }
/* the state pill: a word (in the text token) and a shape (ringed in it, filled with the fixed status step) - ring =
   checking, disc = up, square = down, dotted ring = off; the stylesheet's .hs-dot on this page's own class names */
.dot { float: right; margin: 0 -4px 4px 10px; display: inline-flex; align-items: center; gap: 6px; height: 22px; padding: 0 8px; border-radius: 11px; font: 600 12px/1 var(--hs-font); white-space: nowrap; color: var(--hs-fg); background: color-mix(in srgb, var(--hs-muted) 12%, var(--hs-surface)); }
.dot::before { content: ""; width: 10px; height: 10px; border-radius: 50%; border: 2px solid var(--hs-fg); }
.dot::after { content: "checking\2026"; }
.dot.up { background: color-mix(in srgb, var(--hs-ok) 12%, var(--hs-surface)); }
.dot.up::before { background: var(--hs-ok); }
.dot.up::after { content: "up"; }
.dot.down { background: color-mix(in srgb, var(--hs-bad) 12%, var(--hs-surface)); }
.dot.down::before { border-radius: 2px; background: var(--hs-bad); }
.dot.down::after { content: "down"; }
/* a UI that does not answer yet, right after a container start: amber and "starting", not "down" (the probe below
   sets it until the sixth failure in a row); the same pill, in the warn tokens */
.dot.starting { background: color-mix(in srgb, var(--hs-warn) 12%, var(--hs-surface)); }
.dot.starting::before { background: var(--hs-warn); }
.dot.starting::after { content: "starting"; }
.dot.external::before { border-style: dashed; }
.dot.external::after { content: "external"; }
.dot.warn::before { background: linear-gradient(90deg, var(--hs-warn) 50%, transparent 50%); }
/* a spoke's states (its tile reads the supervisor's report): live is the up disc, stuck the down square */
.dot.live { background: color-mix(in srgb, var(--hs-ok) 12%, var(--hs-surface)); }
.dot.live::before { background: var(--hs-ok); }
.dot.live::after { content: "live"; }
.dot.stuck { background: color-mix(in srgb, var(--hs-bad) 12%, var(--hs-surface)); }
.dot.stuck::before { border-radius: 2px; background: var(--hs-bad); }
.dot.stuck::after { content: "stuck"; }
/* a spoke waiting for the settings its cycle needs (the registry's requires): idle, not starting - the hollow disc */
.dot.waiting::before { border-color: var(--hs-muted); }
.dot.waiting::after { content: "waiting"; }
.dot.down { background: color-mix(in srgb, var(--hs-bad) 12%, var(--hs-surface)); }
.dot.down::before { border-radius: 2px; background: var(--hs-bad); }
.dot.down::after { content: "down"; }
li.tile.off .dot { color: var(--hs-muted); }
li.tile.off .dot::before { border-style: dotted; border-color: var(--hs-muted); }
li.tile.off .dot::after { content: "off"; }
/* the memory tile's note: its state is in its words and in a rule, never in the text's colour */
li.tile p.memory { font-size: 12px; }
li.tile p.memory.bad { font-weight: 600; border-left: 3px solid var(--hs-bad); padding-left: 8px; }
li.tile p.memory.warn { border-left: 3px solid var(--hs-warn); padding-left: 8px; }
/* the Learned rules tile reads its status contract: a red rule, and the reason in words, while the contract reads degraded */
li.tile.red { border-color: var(--hs-bad); box-shadow: inset 4px 0 0 var(--hs-bad); }
li.tile .why { font-weight: 600; }
/* the "Start here" strip and the group headings, on the grid's own measure: the strip's rule and action take the accent,
   the action's word the surface on it (AA in both themes); a heading is muted text */
h2.group { margin: 20px max(var(--hs-space-4), calc((100% - 1700px) / 2 + var(--hs-space-4))) 0; font-size: 13px; font-weight: 700; letter-spacing: .05em; text-transform: uppercase; color: var(--hs-muted); }
h2.group + ul.tiles { padding-top: 10px; }
/* the line under the Agents heading: the spokes that run and how to turn one off */
p.group-note { margin: 4px max(var(--hs-space-4), calc((100% - 1700px) / 2 + var(--hs-space-4))) 0; font-size: 13px; color: var(--hs-muted); }
p.group-note + ul.tiles { padding-top: 10px; }
section.start { margin: 18px max(var(--hs-space-4), calc((100% - 1700px) / 2 + var(--hs-space-4))) 0; background: var(--hs-surface); border: 1px solid var(--hs-border); border-left: 4px solid var(--hs-accent); border-radius: var(--hs-radius); padding: 14px 18px; }
section.start h2 { margin: 0 0 6px; font-size: 16px; }
section.start p { margin: 6px 0 0; font-size: 14px; }
section.start a.primary { display: inline-block; margin-top: 8px; background: var(--hs-accent); color: var(--hs-surface); border-radius: 6px; padding: 7px 14px; text-decoration: none; font-weight: 600; }
section.start a.primary:hover, section.start a.primary:focus-visible { text-decoration: underline; }
footer { padding: 8px var(--hs-space-4) 24px; font-size: 12px; color: var(--hs-muted); }
/* the North Star section (rendered from /agent/north-star.json, see docs/NORTH-STAR.md): a card under the tiles with one
   row per goal; the verdict is a word in a pill, never a colour alone. Its look - the card, the table and its stacking below
   700 px, inline code, the verdict dots - is the harness stylesheet's; only its spacing and the no-wrap of its three short
   columns are set here */
section.north-star { margin: 4px var(--hs-space-4) 18px; padding: var(--hs-space-3) 16px; }
section.north-star h2 { margin: 0 0 6px; font-size: 17px; }
section.north-star h3 { margin: 14px 0 4px; font-size: 15px; }
section.north-star table.ns-agents { font-size: 13px; margin: 6px 0 8px; }
section.north-star table.ns-agents th:nth-child(1), section.north-star table.ns-agents td:nth-child(1) { white-space: nowrap; }
/* an agent's verdict and today, and a component's as-of date, are short words too: never broken across lines */
section.north-star table.ns-agents th:nth-child(6), section.north-star table.ns-agents td:nth-child(6), section.north-star table.ns-agents th:nth-child(7),
section.north-star table.ns-agents td:nth-child(7), section.north-star table.ns-components th:nth-child(4), section.north-star table.ns-components td:nth-child(4) { white-space: nowrap; overflow-wrap: normal; }
section.north-star table.ns-components { font-size: 13px; margin: 6px 0 8px; }
section.north-star p { margin: 4px 0 8px; font-size: 13px; color: var(--hs-muted); }
section.north-star p.ns-statement { color: var(--hs-fg); font-size: 14px; }
section.north-star table.ns-table { font-size: 13px; margin: 6px 0 8px; }
section.north-star .ns-verdict { white-space: nowrap; }
/* the id, verdict and today columns are short words: never broken across lines (measured at 1920 px: "N S - 1") */
section.north-star table.ns-table th:nth-child(1), section.north-star table.ns-table td:nth-child(1), section.north-star table.ns-table th:nth-child(4),
section.north-star table.ns-table td:nth-child(4), section.north-star table.ns-table th:nth-child(5), section.north-star table.ns-table td:nth-child(5) { white-space: nowrap; overflow-wrap: normal; }
section.north-star p.ns-legend, section.north-star p.ns-links { font-size: 12px; }
@media (max-width: 700px) {
	section.north-star table.ns-table td { white-space: normal; }
}
@media (max-width: 600px) {
	section.north-star { margin: 4px 16px 16px; padding: 12px; }
	ul.tiles { gap: 10px; padding: 14px 16px; }
	section.start, h2.group { margin-left: 16px; margin-right: 16px; }
	footer { padding: 8px 16px 20px; }
}
</style>
</head>
<body class="hs-page">
<header class="hs-header">
<h1>do-agent-aws harness</h1>
<p>every UI below is served through this single port; reach it with
ssh -L ${HOME_PORT_HINT}:localhost:${HOME_PORT_HINT} (docker) or kubectl port-forward svc/do-agent-aws ${HOME_PORT_HINT}:${HOME_PORT_HINT} (kubernetes)</p>
</header>
<main>
<section class="start" aria-labelledby="start-h">
<h2 id="start-h">Start here</h2>
<p>Give the agent a goal: ${START_HOW}. ${START_LOOP}
Watch it work in the tmux terminal, see what it learned under Memory and learning; the <a href="/guide/">Guide</a> has the 5-minute tour.</p>
<p class="action">${START_ACTION}</p>
</section>
<h2 class="group">Get started</h2>
<ul class="tiles">
${TILES_START}
</ul>
<h2 class="group">Run and review</h2>
<ul class="tiles">
${TILES_RUN}
</ul>
<h2 class="group">Memory and learning</h2>
<ul class="tiles">
${TILES_MEMORY}
</ul>
<h2 class="group">Administration</h2>
<ul class="tiles">
${TILES_ADMIN}
</ul>
${AGENTS_HTML}
${OTHER_HTML}
${NORTH_STAR_HTML}
</main>
<footer>${VERSION_LINE} &middot; <a href="/guide/">Guide</a> &middot; <a href="/guide/manual/ui/#home-page-and-reverse-proxy">Manual: Home page and reverse proxy</a> &middot; <a href="/guide/manual/ui/#harness-uis">Harness UIs</a> &middot; <a href="https://github.com/awslabs/do-agent-aws" target="_blank" rel="noopener">GitHub (access required)</a></footer>
<script>
// Live up/down dots, probed from the browser, always SAME-ORIGIN so the real status is read: a
// path tile at its path, a *.localhost host tile at its /__probe/<name> location on this listener
// (a cross-origin no-cors fetch would resolve for a 502 as happily as for a 200). Redirects are not
// followed (an upstream that answers with one is up; a followed redirect could land on this page
// and read 404). No external assets anywhere on this page: it renders offline and through an ssh tunnel.
// This tab is the one every UI's "Harness home" badge returns to (its target="do-agent-aws-home").
window.name = 'do-agent-aws-home';
// A UI that does not answer yet is "starting", not "down": right after a container start the slower UIs (the Goals
// board's sidecars, Hindsight) take up to a minute, so a failed probe is retried every 10 s and the dot reads
// "starting" until the sixth failure in a row, then "down" (and keeps being retried). A tile has at most one retry
// pending, and while it waits the 15 s sweep leaves the tile to it: before, every sweep started one more retry chain
// while a UI stayed down, so one tab's probes grew by 24 a minute every minute (test-home-probe.sh). The failure
// count is the tile's own, kept on its element; sweep's forEach once handed each tile its list index as the count.
// A probe that has not answered after 8 s is aborted and counts as a failure. The home proxy's read timeout is a day
// (for the UIs' websockets) and a browser opens only a few connections per host: before, every sweep added one more
// hung probe of a tile whose UI never answered, each holding a connection, until the tab's same-origin requests queued
// behind them, the other dots included. Only a pending retry holds a sweep back, not a probe in flight, so a tile can
// have two probes out for a moment; the abort ends either.
function probe(el) {
  if (el.dataset.contract) return readContract(el);
  if (el.probeRetryPending) return;
  var dot = el.querySelector('.dot');
  var url = el.dataset.probe || el.dataset.url;
  var warn = dot.classList.contains('warn');
  var failed = function () {
    // a sweep can start a second probe while one is still out (only a pending retry holds it back); when both fail,
    // the first schedules the retry and the second finds it pending here, so the tile keeps a single retry chain
    if (el.probeRetryPending) return;
    var failures = el.probeFailures = (el.probeFailures || 0) + 1;
    dot.className = 'dot ' + (failures < 6 ? 'starting' : 'down') + (warn ? ' warn' : '');
    el.probeRetryPending = true;
    setTimeout(function () { el.probeRetryPending = false; probe(el); }, 10000);
  };
  var ctl = typeof AbortController === 'function' ? new AbortController() : null;
  var limit = ctl ? setTimeout(function () { ctl.abort(); }, 8000) : null;
  fetch(url, { cache: 'no-store', redirect: 'manual', signal: ctl ? ctl.signal : undefined }).then(function (r) {
    clearTimeout(limit);
    var ok = r.type === 'opaqueredirect' || (r.status >= 200 && r.status < 400);
    if (ok) { el.probeFailures = 0; dot.className = 'dot up' + (warn ? ' warn' : ''); } else { failed(); }
  }).catch(function () { clearTimeout(limit); failed(); });
}
// A tile that reads a status contract at its data-contract location (Learned rules: the LogLearner tile
// contract, loglearner-tile/v1): its numbers come from the contract, and it is up only while the contract reads
// status "ok" - a degraded contract answers HTTP 200 like an ok one, so the status-only probe would read it green.
// Otherwise it turns red and says why ("degraded: <the missing source>", or "not answering" while the dashboard is
// down). Like a dot's probe, a read that has not finished after 8 s is aborted and reads "not answering": the tile's
// location has the proxy's day-long read timeout too, so a dashboard that hangs would hold one more request per sweep.
// The timer is cleared once the contract is read, not at its headers, because the body can hang as well.
function readContract(el) {
  var ctl = typeof AbortController === 'function' ? new AbortController() : null;
  var limit = ctl ? setTimeout(function () { ctl.abort(); }, 8000) : null;
  fetch(el.dataset.contract, { cache: 'no-store', redirect: 'manual', signal: ctl ? ctl.signal : undefined }).then(function (r) {
    if (r.status !== 200) { clearTimeout(limit); return contract(el, null, 'not answering (HTTP ' + r.status + ')'); }
    return r.json().then(function (d) { clearTimeout(limit); contract(el, d, null); });
  }).catch(function () { clearTimeout(limit); contract(el, null, 'not answering'); });
}
function contract(el, d, err) {
  if (!err && !(d && d.schema === 'loglearner-tile/v1')) err = 'not a loglearner-tile/v1 contract';
  var ml = (d && d.meta_learner) || {}, b = ml.bandit || {};
  var v = { instincts: ml.instincts_total, banks: ml.banks ? ml.banks.length : null, exposures: b.exposures,
    exposures_24h: b.exposures_24h };
  el.querySelectorAll('[data-k]').forEach(function (n) {
    var x = v[n.dataset.k];
    n.textContent = (x === undefined || x === null) ? '-' : Number(x).toLocaleString('en-US');
  });
  var ok = !err && d.status === 'ok';
  el.querySelector('.dot').className = 'dot ' + (ok ? 'up' : 'down');
  el.classList.toggle('red', !ok);
  var why = el.querySelector('.why');
  if (why) why.textContent = ok ? '' : ' - ' + (err || 'degraded: ' + ((d.errors || []).join('; ') || 'status ' + d.status));
}
// The memory tile's note: the seed's extraction state (a file the seed writes; 404 until it ran) plus the live
// document/pending/failed counts of the banks through the same-origin /memory-api/ route. A memory API that is UP
// but cannot call Bedrock (no credentials, an unknown profile, no model access) answers every probe and holds
// empty banks with operations pending for good - the dot alone would stay green over an empty memory. A pass reads the
// seed's state, the bank list, then every bank's counts at once. Each read gives up after 8 s and counts as no answer;
// its timer is cleared once the body is read (a body can hang too), and its request is then aborted, which ends the
// unread body of an error answer and does nothing to a finished one. A minute's pass is skipped while the last one is
// still reading, so a memory API that hangs holds one pass's reads per tab, one per bank, for 8 s at most; before, it
// held one more pass a minute (the proxy's read timeout is a day). The 8 s include any time a read waits for one of the
// browser's connections to the home port. Banks that did not answer are counted in the note, and a note about an API
// or banks that did not answer is styled as a warning; an empty bank list reads "no banks yet", neutral (the seed can
// be off). The pass starts inside its promise chain, so even a read that throws at once clears the flag, and an error
// still reaches the console after it. Without AbortController (browsers before 2019) a read that hangs keeps the flag
// for the life of the tab: the note keeps its text rather than opening one more read a minute, and a reload starts
// over (test-home-memory-note.sh). With the counts the pass reads the session guard's counts (/__memory-guard, the
// key=value file /agent/hindsight-session-guard.py writes; 404 until its first pass) and, for each bank with failed
// operations, the failed operations themselves: the note names their reasons and is styled as a warning; with none it is
// unchanged.
function memoryState() {
  // A failed operation's reason as the guard logs it: its kind (a knowledge page's refresh, a retain) and the last part of
  // the memory API's message up to the first clause break
  function failReason(op) {
    var msg = String((op && op.error_message) || 'no reason given').replace(/\s+/g, ' ').trim();
    var tail = msg.split(': ').pop().split(/[,;] |\. /)[0].replace(/\.$/, '').trim() || msg;
    var kind = op && op.task_type === 'refresh_mental_model' ? 'page refresh' : ((op && op.task_type) || 'operation');
    return kind + ': ' + tail.slice(0, 120);
  }
  // the distinct reasons of the failed operations read, the most frequent first, at most three named
  function failedReasons(lists) {
    var n = {}, order = [];
    lists.forEach(function (l) {
      ((l && l.operations) || []).forEach(function (op) { var r = failReason(op); if (!n[r]) { n[r] = 0; order.push(r); } n[r]++; });
    });
    order.sort(function (a, b) { return n[b] - n[a]; });
    if (!order.length) return '';
    return ' (' + order.slice(0, 3).join('; ') + (order.length > 3 ? '; ' + (order.length - 3) + ' more reasons' : '') + ')';
  }
  // what the session guard did to the session banks: records set aside, agent claims marked, page refreshes paused
  function guardNote(txt) {
    var g = {};
    (txt || '').split('\n').forEach(function (l) { var i = l.indexOf('='); if (i > 0) g[l.slice(0, i)] = Number(l.slice(i + 1)) || 0; });
    var lang = g.rejected_language || 0, dup = g.rejected_duplicate || 0, marker = g.rejected_marker || 0, aside = lang + dup + marker;
    var parts = [];
    if (aside) parts.push(aside + (aside === 1 ? ' record' : ' records') + ' set aside (' + [lang ? lang + ' in another language' : '',
      dup ? dup + (dup === 1 ? ' duplicate' : ' duplicates') : '', marker ? marker + ' marker only' : ''].filter(Boolean).join(', ') + ')');
    if (g.claims_marked) parts.push(g.claims_marked + (g.claims_marked === 1 ? ' agent claim' : ' agent claims') + ' marked');
    if (g.paused_pages) parts.push(g.paused_pages + (g.paused_pages === 1 ? ' page refresh' : ' page refreshes') + ' paused');
    return parts.length ? '; session guard: ' + parts.join(', ') : '';
  }
  var el = document.getElementById('memory-state');
  if (!el || el.memoryReading) return;
  var dot = el.parentNode.querySelector('.dot');
  var read = function (url, asJson) {
    var ctl = typeof AbortController === 'function' ? new AbortController() : null;
    var limit = ctl ? setTimeout(function () { ctl.abort(); }, 8000) : null;
    return fetch(url, { cache: 'no-store', signal: ctl ? ctl.signal : undefined }).then(function (r) { return r.ok ? (asJson ? r.json() : r.text()) : null; })
      .catch(function () { return null; }).then(function (v) { clearTimeout(limit); if (ctl) ctl.abort(); return v; });
  };
  var done = function () { el.memoryReading = false; };
  el.memoryReading = true;
  Promise.resolve().then(function () { return read('/__seed-state', false); }).then(function (txt) {
    var st = {};
    (txt || '').split('\n').forEach(function (l) { var i = l.indexOf('='); if (i > 0) st[l.slice(0, i)] = l.slice(i + 1); });
    return read('/memory-api/v1/default/banks?limit=200', true).then(function (banks) {
      var listed = !!(banks && banks.banks);
      var ids = listed ? banks.banks.map(function (b) { return b.bank_id; }) : [];
      return Promise.all(ids.map(function (id) { return read('/memory-api/v1/default/banks/' + encodeURIComponent(id) + '/stats', true); })
        .concat([read('/__memory-guard', false)])).then(function (stats) {
        var guard = stats.pop(), docs = 0, pending = 0, failed = 0, seen = 0;
        stats.forEach(function (s) { if (s) { seen++; docs += s.total_documents || 0; pending += s.pending_operations || 0; failed += s.failed_operations || 0; } });
        var failing = ids.filter(function (id, k) { return stats[k] && stats[k].failed_operations; });
        return Promise.all(failing.map(function (id) { return read('/memory-api/v1/default/banks/' + encodeURIComponent(id) + '/operations?status=failed&limit=100', true); })).then(function (lists) {
          var missing = ids.length - seen, ofBanks = ' of ' + ids.length + (ids.length === 1 ? ' bank' : ' banks');
          var line = seen ? 'memory: ' + docs + ' documents in ' + seen + ' bank' + (seen === 1 ? '' : 's') + (pending ? ', ' + pending + ' pending' : '') + (failed ? ', ' + failed + ' failed' + failedReasons(lists) : '') : (listed && !ids.length ? 'memory: no banks yet' : 'memory: the API did not answer');
          if (missing > 0) line += seen ? ', ' + missing + ofBanks + ' did not answer' : ' (' + missing + ofBanks + ')';
          el.className = 'memory';
          if (dot) dot.classList.remove('warn');
          if (!listed || missing > 0 || failed) {
            el.className = 'memory warn';
            if (dot) dot.classList.add('warn');
          }
          if (st.state === 'failed') {
            el.className = 'memory bad';
            line += ' - EXTRACTION FAILING: ' + (st.reason || 'see the seed log') + '. Fix it and restart (./stop.sh && ./run.sh); the manual: AWS credentials and Amazon Bedrock (/guide/manual/aws/)';
            if (dot) dot.classList.add('warn');
          } else if (st.state === 'stalled') {
            el.className = 'memory warn';
            line += ' - nothing extracted yet (' + (st.reason || 'no error in the API log') + ')';
          } else if (st.state === 'accepted' || st.state === 'extracting' || pending) {
            line += ' - extraction running';
          }
          line += guardNote(guard);
          el.textContent = line;
        });
      });
    });
  }).then(done, function (e) { done(); throw e; });
}
function sweep() {
  document.querySelectorAll('li.tile[data-url],li.tile[data-host]').forEach(function (el) { probe(el); });
}
// The agent tiles that are on: the state the supervisor writes after each pass (/__spokes, 404 until its first) - a word
// with a shape like every dot: starting, live (alive, and a cycle completed since its start), waiting (for settings its
// cycle needs, with how to set them), stuck (a menu, an error,
// the context, the restart cap - or a supervisor that stopped reporting) or down; the note says why, the last cycle, the
// restarts and the last message. The supervisor's own tile reads the age of its last pass. Text nodes only: a message's
// text is another agent's.
function spokes() {
  var tiles = document.querySelectorAll('li.tile.spoke:not(.off)');
  if (!tiles.length) return;
  fetch('/__spokes', { cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; }).catch(function () { return null; }).then(function (doc) {
    tiles.forEach(function (el) {
      var stale = doc && Date.now() - Date.parse(doc.updated_at) > (2 * doc.interval + 60) * 1000;
      var state = 'starting', text;
      if (el.dataset.supervisor) {
        if (!doc) { text = 'starting - no pass yet'; }
        else if (stale) { state = 'stuck'; text = 'stuck - its last pass was at ' + doc.updated_at; }
        else {
          var on = Object.keys(doc.sessions || {}).filter(function (n) { return doc.sessions[n].enabled; });
          var bad = on.filter(function (n) { return doc.sessions[n].state !== 'live'; });
          state = 'live';
          text = 'live - last pass ' + doc.updated_at + ': ' + (on.length - bad.length) + ' of ' + on.length + ' live' + (bad.length ? ' (' + bad.map(function (n) { var b = doc.sessions[n]; return n + (b.state === 'waiting' ? ' waiting for ' + b.waiting_for : ' ' + b.state); }).join(', ') + ')' : '');
        }
        el.querySelector('.dot').className = 'dot ' + state;
        el.querySelector('.spoke-state').textContent = text;
        return;
      }
      var s = doc && doc.sessions ? doc.sessions[el.dataset.spoke] : null;
      if (!doc) {
        text = 'starting - the supervisor has not reported yet';
      } else if (stale) {
        state = 'stuck';
        text = 'stuck - the supervisor stopped reporting at ' + doc.updated_at;
      } else if (!s) {
        text = 'starting - not in the supervisor\'s report yet';
      } else {
        state = (s.state === 'live' || s.state === 'stuck' || s.state === 'down' || s.state === 'waiting') ? s.state : 'starting';
        text = state + (s.why ? ' - ' + s.why : '');
        if (state === 'waiting' && s.how) text += '; ' + s.how;
        if (state === 'live' && s.last_cycle) text += '; last cycle ' + s.last_cycle;
        if (s.restarts) text += '; restarts ' + s.restarts + '/' + doc.cap;
        var m = s.last_message;
        if (m) text += '; last message ' + m.from + ' -> ' + m.to + ' ' + m.kind + ' "' + (m.text || '').slice(0, 80) + '" at ' + m.ts;
      }
      el.querySelector('.dot').className = 'dot ' + state;
      el.querySelector('.spoke-state').textContent = text;
    });
    // the line under the heading: the spokes the last pass saw, each with its state
    var row = document.getElementById('agents-on');
    if (row && doc && doc.sessions) {
      var run = Object.keys(doc.sessions).filter(function (n) { return doc.sessions[n].enabled && doc.sessions[n].role === 'spoke'; });
      row.textContent = (run.length ? 'Running: ' + run.map(function (n) { var r = doc.sessions[n]; return n + ' (' + (r.state === 'waiting' ? 'waiting for ' + r.waiting_for : r.state) + ')'; }).join(', ') + '. To turn one off, set SPOKE_<NAME>=false in .env.local, then ./stop.sh && ./run.sh.' : 'No spoke runs. To run one, set SPOKE_<NAME>=true in .env.local, then ./stop.sh && ./run.sh.');
    }
  });
}
// *.localhost links are completed from the page's own location so any tunnel port works
document.querySelectorAll('li.tile[data-host], .start a[data-host]').forEach(function (el) {
  var a = el.tagName === 'A' ? el : el.querySelector('a');
  a.href = location.protocol + '//' + el.dataset.host + '.localhost:' + (location.port || 80) + (el.dataset.path || '/');
});
// a host-route tile with a data-path (the Plane tile's one-click sign-in) links to that path on its host
document.querySelectorAll('li.tile[data-host][data-path]').forEach(function (el) {
  el.querySelector('a').href = location.protocol + '//' + el.dataset.host + '.localhost:' + (location.port || 80) + el.dataset.path;
});
sweep();
memoryState();
spokes();
setInterval(sweep, 15000);
setInterval(spokes, 15000);
setInterval(memoryState, 60000);   // one /stats per bank a minute per tab is plenty for a note
</script>
</body>
</html>
EOF

# ---------------------------------------------------------------- tmux cheatsheet
# Static reference for the shared agent tmux session, one tile away from the home page.
# Everything on it is true of THIS image: each key row carries a data-tmux='<table>|<key>|<command>'
# marker (a row documenting several bindings carries the extras on nested empty spans) and each setting a
# data-tmux-opt='<option>|<value>' marker, and test13.sh verifies every marker against the
# running tmux (list-keys / show-options). Add a marker with any key you add to the page.

TMUX_HELP_MODE_HTML="<p class=\"callout\"><strong>This deployment: the browser terminal is writable.</strong>
Keys typed at <a href=\"/tmux/\">/tmux/</a> drive the shared session below.
Set UI_TMUX_WRITABLE=false in .env for a watch-only viewer.</p>"
if [ "${UI_TMUX_WRITABLE}" != "true" ]; then
	TMUX_HELP_MODE_HTML="<p class=\"callout warn\"><strong>This deployment: the browser terminal is read-only.</strong>
Keys pressed at <a href=\"/tmux/\">/tmux/</a> do nothing by design - the viewer is not broken.
Set UI_TMUX_WRITABLE=true in .env to type, or attach from the container shell:
<code>tmux attach -t ${AGENT_TMUX_SESSION_NAME}</code></p>"
fi

cat > "${HOME_DIR}/site/tmux-help/index.html" << EOF
<!DOCTYPE html>
<html lang="en" class="hs-root">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>tmux cheatsheet - do-agent-aws harness</title>
<link rel="stylesheet" href="${HARNESS_CSS_PATH}">
<style>
/* the page's look is the harness stylesheet's (tokens, header, code and kbd); only this page's own layout is here */
main { max-width: 880px; padding: 8px var(--hs-space-4) 24px; }
h2 { font-size: 16px; margin: 26px 0 6px; }
table { border-collapse: collapse; width: 100%; background: var(--hs-surface); border: 1px solid var(--hs-border); }
td { padding: 7px 12px; border-top: 1px solid var(--hs-border); font-size: 14px; vertical-align: top; }
tr:first-child td { border-top: none; }
td.k { white-space: nowrap; width: 13em; }
.callout { background: var(--hs-surface); border: 1px solid var(--hs-border); border-left: 4px solid var(--hs-ok); border-radius: var(--hs-radius); padding: 10px 14px; font-size: 14px; }
.callout.warn { border-left-color: var(--hs-bad); }
p.note { color: var(--hs-muted); font-size: 13px; }
footer { padding: 16px 0 0; font-size: 12px; color: var(--hs-muted); }
@media (max-width: 600px) {
	main { padding: 8px 16px 20px; }
	td.k { white-space: normal; width: auto; }
}
</style>
</head>
<body class="hs-page">
<header class="hs-header">
<h1>tmux cheatsheet</h1>
<p>the shared terminal session the agent runs in - how to move around without breaking anything</p>
</header>
<main>

<h2>The one thing to know</h2>
<p>tmux keeps a terminal session alive on the server, independent of who is watching it.
Every shortcut below means: press <kbd>Ctrl</kbd>+<kbd>b</kbd>, <em>release both keys</em>, then press the
key shown<span data-tmux-opt='prefix|C-b'></span>. Example: detach is <kbd>Ctrl+b</kbd> then <kbd>d</kbd> - written <kbd>C-b</kbd> <kbd>d</kbd> from here on.</p>

<h2>This harness</h2>
${TMUX_HELP_MODE_HTML}
<p class="callout warn" id="ctrl-c"><strong>Ctrl+C interrupts the agent.</strong> In the browser terminal Ctrl+C is not "copy": the
terminal passes it straight through as an interrupt to whatever is running in the shared pane - the Claude CLI included.
Copy with the mouse (select, release) or with tmux copy mode (<kbd>C-b</kbd> <kbd>[</kbd>), both under "Scrollback and copy" below.</p>
<p>The agent lives in one tmux session named <code>${AGENT_TMUX_SESSION_NAME}</code>. The browser terminal
(<a href="/tmux/">/tmux/</a>) and a <code>tmux attach</code> from the container shell are two doors into that
<em>same</em> session: one shared screen and one shared keyboard, so keys typed in either place land in both,
and both always show the same thing. Detaching or closing the browser tab leaves the session - and anything
running in it, including the Claude CLI - untouched.</p>

<h2>Detach, re-attach, sessions</h2>
<table>
<tr data-tmux='prefix|d|detach-client'><td class="k"><kbd>C-b</kbd> <kbd>d</kbd></td><td>detach - leave the session (and anything running in it) untouched; a container shell returns to its prompt, the browser terminal reconnects into the session by itself</td></tr>
<tr><td class="k"><code>tmux attach -t ${AGENT_TMUX_SESSION_NAME}</code></td><td>re-attach from any container shell</td></tr>
<tr><td class="k"><code>tmux ls</code></td><td>list sessions (shell command, no prefix)</td></tr>
<tr data-tmux='prefix|s|choose-tree'><td class="k"><kbd>C-b</kbd> <kbd>s</kbd></td><td>interactive session picker (arrows + Enter, <kbd>q</kbd> to leave)</td></tr>
<tr><td class="k"><a href="/tmux/?arg=pick"><code>/tmux/?arg=pick</code></a></td><td>the browser terminal's session menu: the numbered list of this container's tmux sessions; type a number to attach to it</td></tr>
<tr><td class="k"><code>/tmux/?arg=&lt;session&gt;</code></td><td>open the browser terminal on that session (its exact name: one word of letters, digits, dot, underscore and hyphen). A name that does not exist, or anything else, shows the menu and says why. Only this container's own tmux server is listed or attached, never the host's, and no argument can pick a socket or a path</td></tr>
<tr data-tmux='prefix|\$|rename-session'><td class="k"><kbd>C-b</kbd> <kbd>\$</kbd></td><td>rename the current session</td></tr>
<tr><td class="k"><code>tmux kill-session -t ${AGENT_TMUX_SESSION_NAME}</code></td><td>end the session and everything running in it (shell command; there is no undo)</td></tr>
</table>

<h2>Windows (tabs)</h2>
<table>
<tr data-tmux='prefix|c|new-window'><td class="k"><kbd>C-b</kbd> <kbd>c</kbd></td><td>new window</td></tr>
<tr data-tmux='prefix|n|next-window'><td class="k"><kbd>C-b</kbd> <kbd>n</kbd> / <kbd>p</kbd><span data-tmux='prefix|p|previous-window'></span></td><td>next / previous window</td></tr>
<tr data-tmux='prefix|0|select-window'><td class="k"><kbd>C-b</kbd> <kbd>0</kbd>..<kbd>9</kbd></td><td>jump to window by number (the list is in the green status bar)</td></tr>
<tr data-tmux='prefix|w|choose-tree'><td class="k"><kbd>C-b</kbd> <kbd>w</kbd></td><td>interactive window picker</td></tr>
<tr data-tmux='prefix|,|rename-window'><td class="k"><kbd>C-b</kbd> <kbd>,</kbd></td><td>rename the current window</td></tr>
<tr data-tmux='prefix|&|kill-window'><td class="k"><kbd>C-b</kbd> <kbd>&amp;</kbd></td><td>kill the current window (asks y/n first). The agent session starts with a single window running the agent - killing the last window ends the session, and a fresh attach gets a plain shell without it (restart the container to bring it back)</td></tr>
</table>

<h2>Panes (splits)</h2>
<table>
<tr data-tmux='prefix|%|split-window -h'><td class="k"><kbd>C-b</kbd> <kbd>%</kbd></td><td>split side by side</td></tr>
<tr data-tmux='prefix|"|split-window'><td class="k"><kbd>C-b</kbd> <kbd>"</kbd></td><td>split top / bottom</td></tr>
<tr data-tmux='prefix|Up|select-pane -U'><td class="k"><kbd>C-b</kbd> <kbd>&#8592;&#8593;&#8595;&#8594;</kbd><span data-tmux='prefix|Down|select-pane -D'></span><span data-tmux='prefix|Left|select-pane -L'></span><span data-tmux='prefix|Right|select-pane -R'></span></td><td>move between panes</td></tr>
<tr data-tmux='prefix|C-Up|resize-pane -U'><td class="k"><kbd>C-b</kbd> <kbd>Ctrl</kbd>+<kbd>&#8592;&#8593;&#8595;&#8594;</kbd><span data-tmux='prefix|C-Down|resize-pane -D'></span><span data-tmux='prefix|C-Left|resize-pane -L'></span><span data-tmux='prefix|C-Right|resize-pane -R'></span></td><td>resize the current pane</td></tr>
<tr data-tmux='prefix|z|resize-pane -Z'><td class="k"><kbd>C-b</kbd> <kbd>z</kbd></td><td>zoom the pane full-screen; same key restores the layout</td></tr>
<tr data-tmux='prefix|o|select-pane -t'><td class="k"><kbd>C-b</kbd> <kbd>o</kbd></td><td>cycle to the next pane</td></tr>
<tr data-tmux='prefix|x|kill-pane'><td class="k"><kbd>C-b</kbd> <kbd>x</kbd></td><td>kill the current pane (asks y/n first). Same caution as killing a window: the agent runs in the session's only pane, so this ends the whole session</td></tr>
</table>

<h2>Scrollback and copy</h2>
<p>The mouse wheel does <em>not</em> scroll tmux history<span data-tmux-opt='mouse|off'></span> - in the browser
terminal too, scrolling happens through copy mode. History keeps the last 2000
lines<span data-tmux-opt='history-limit|2000'></span>.</p>
<table>
<tr data-tmux='prefix|[|copy-mode'><td class="k"><kbd>C-b</kbd> <kbd>[</kbd></td><td>enter copy mode - then move with arrows / PageUp / PageDown</td></tr>
<tr data-tmux='prefix|PPage|copy-mode -u'><td class="k"><kbd>C-b</kbd> <kbd>PageUp</kbd></td><td>enter copy mode one page up - the quickest way to scroll back</td></tr>
<tr data-tmux='copy-mode|PPage|page-up'><td class="k"><kbd>PageUp</kbd> / <kbd>Space</kbd><span data-tmux='copy-mode|Space|page-down'></span></td><td>in copy mode: page up / page down</td></tr>
<tr data-tmux='copy-mode|C-Space|begin-selection'><td class="k"><kbd>Ctrl</kbd>+<kbd>Space</kbd></td><td>in copy mode: start selecting<span data-tmux-opt='mode-keys|emacs'></span></td></tr>
<tr data-tmux='copy-mode|M-w|copy-pipe-and-cancel'><td class="k"><kbd>Alt</kbd>+<kbd>w</kbd></td><td>in copy mode: copy the selection to the tmux buffer and leave copy mode</td></tr>
<tr data-tmux='prefix|]|paste-buffer'><td class="k"><kbd>C-b</kbd> <kbd>]</kbd></td><td>paste the tmux buffer</td></tr>
<tr data-tmux='copy-mode|q|cancel'><td class="k"><kbd>q</kbd> or <kbd>Esc</kbd><span data-tmux='copy-mode|Escape|cancel'></span></td><td>leave copy mode (back to the live view)</td></tr>
</table>
<p class="note">In the browser terminal, selecting text with the mouse copies it to the clipboard the moment
you release the button (tmux mouse mode is off, so the browser owns the mouse). Do <em>not</em> press Ctrl+C
to copy: as the callout at the top says, the terminal passes it straight through as an interrupt to whatever is
running in the shared pane.
Paste with Ctrl+Shift+V (Cmd+V on macOS). The tmux buffer above is separate from your system clipboard.</p>

<h2>When stuck</h2>
<table>
<tr data-tmux='prefix|?|list-keys'><td class="k"><kbd>C-b</kbd> <kbd>?</kbd></td><td>tmux's own full key list (<kbd>q</kbd> to leave)</td></tr>
<tr><td class="k"><kbd>q</kbd> then <kbd>C-b</kbd> <kbd>d</kbd></td><td>the safe exit from anywhere: leave whatever mode you are in, then detach - nothing running is disturbed</td></tr>
</table>

<footer>${VERSION_LINE} &middot; every key above verified against this image's tmux by test13.sh &middot;
<a href="/">harness home</a> &middot; <a href="/tmux/">open the terminal</a></footer>
</main>
$(badge_html /)
</body>
</html>
EOF

# ---------------------------------------------------------------- user guide, README and manual
# docs/user-guide.md, README.md and docs/manual/ (the Dockerfile copies them to /docs/) rendered by /agent/md2html.py: no
# third-party module, the page carries the home chrome and a "Harness home" link, headings carry GitHub-style anchors so
# the footer's help links land on the manual's sections (/guide/manual/ui/#harness-uis). A missing or unreadable source
# renders a page that says so - the home render never fails on a document.
USER_GUIDE_MD=${USER_GUIDE_MD:-/docs/user-guide.md}
README_MD=${README_MD:-/docs/README.md}
# the North Star register (docs/NORTH-STAR.md) and the GA release page (docs/GA-RELEASE.md): the home page's North Star
# section linked them on GitHub, a 404 for every reader of a private repository; served here like the README
NORTH_STAR_MD=${NORTH_STAR_MD:-/docs/NORTH-STAR.md}
GA_RELEASE_MD=${GA_RELEASE_MD:-/docs/GA-RELEASE.md}
# the agent stack (docs/AGENT-STACK.md) and how its agents talk (docs/INTER-AGENT-MESSAGING.md), which the Guide links
AGENT_STACK_MD=${AGENT_STACK_MD:-/docs/AGENT-STACK.md}
MESSAGING_MD=${MESSAGING_MD:-/docs/INTER-AGENT-MESSAGING.md}
# how harnesses share knowledge (docs/knowledge-sharing.md), which the Knowledge transfer page links
KNOWLEDGE_SHARING_MD=${KNOWLEDGE_SHARING_MD:-/docs/knowledge-sharing.md}
render_doc()
{
	# render_doc <source.md> <output.html> <title> <subtitle>
	local SRC=$1 OUT=$2 TITLE=$3 SUBTITLE=$4
	if [ -r "${SRC}" ] && python3 -I "$(dirname "$0")/md2html.py" "${SRC}" --title "${TITLE}" --subtitle "${SUBTITLE}" > "${OUT}.new" 2> "${HOME_DIR}/tmp/md2html.err"; then
		mv "${OUT:?}.new" "${OUT:?}"
	else
		echo "home-render: WARNING - ${TITLE} is not rendered (${SRC}: $(head -1 "${HOME_DIR}/tmp/md2html.err" 2>/dev/null || echo 'not readable')); its page says so" >&2
		rm -f "${OUT:?}.new"
		local ESCAPED_SRC
		ESCAPED_SRC=$(printf '%s' "${SRC}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
		printf '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>%s - do-agent-aws harness</title></head><body style="font: 15px system-ui, sans-serif; margin: 28px"><h1>%s</h1><p>This document is not in this image (no readable %s). Its source is in the repository.</p><p><a href="/">Harness home</a></p></body></html>\n' "${TITLE}" "${TITLE}" "${ESCAPED_SRC}" > "${OUT}"
	fi
}
render_doc "${USER_GUIDE_MD}" "${HOME_DIR:?}/site/guide/index.html" "Guide" "how to use the harness - every UI behind one home page"
render_doc "${README_MD}" "${HOME_DIR:?}/site/guide/readme/index.html" "README" "the repository's README, served here because the repository is private"
# the manual: its index at /guide/manual/ and one page per file at /guide/manual/<file>/, the page title from the file's first
# heading; a manual folder that is missing renders the index's placeholder and no page
MANUAL_DIR=${MANUAL_DIR:-/docs/manual}
mkdir -p "${HOME_DIR}/site/guide/manual"
render_doc "${MANUAL_DIR}/README.md" "${HOME_DIR:?}/site/guide/manual/index.html" "Manual" "the reference, one page per topic"
for MANUAL_PAGE in "${MANUAL_DIR}"/*.md; do
	[ -r "${MANUAL_PAGE}" ] || continue
	MANUAL_NAME=$(basename "${MANUAL_PAGE}" .md)
	[ "${MANUAL_NAME}" == "README" ] && continue
	mkdir -p "${HOME_DIR}/site/guide/manual/${MANUAL_NAME}"
	render_doc "${MANUAL_PAGE}" "${HOME_DIR:?}/site/guide/manual/${MANUAL_NAME}/index.html" "$(sed -n '1s/^# //p' "${MANUAL_PAGE}")" "part of the manual"
done
# the pictures the README and the manual show (docs/img, in the image at /docs/img/), at /guide/img/ where md2html.py
# points a docs/img picture; a folder that is missing leaves the pages with their alt text
IMG_DIR=${IMG_DIR:-/docs/img}
mkdir -p "${HOME_DIR}/site/guide/img"
for IMG in "${IMG_DIR}"/*.svg "${IMG_DIR}"/*.png; do
	if [ -f "${IMG}" ]; then cp "${IMG}" "${HOME_DIR}/site/guide/img/"; fi
done
mkdir -p "${HOME_DIR}/site/guide/north-star" "${HOME_DIR}/site/guide/ga-release" "${HOME_DIR}/site/guide/agent-stack" "${HOME_DIR}/site/guide/messaging" \
	"${HOME_DIR}/site/guide/knowledge-sharing"
render_doc "${NORTH_STAR_MD}" "${HOME_DIR:?}/site/guide/north-star/index.html" "North Star" "what the harness must do, as rows a named check can fail"
render_doc "${GA_RELEASE_MD}" "${HOME_DIR:?}/site/guide/ga-release/index.html" "GA release" "what blocks the release, and what is done"
render_doc "${AGENT_STACK_MD}" "${HOME_DIR:?}/site/guide/agent-stack/index.html" "The agent stack" "the hub, the supervisor and the spokes: what each one is, keeps, writes and talks about"
render_doc "${MESSAGING_MD}" "${HOME_DIR:?}/site/guide/messaging/index.html" "How the agents talk" "session-to-session messages, the journal, and what proves them"
render_doc "${KNOWLEDGE_SHARING_MD}" "${HOME_DIR:?}/site/guide/knowledge-sharing/index.html" "Sharing knowledge between harnesses" "export and import on the Knowledge transfer page, and one pack a group of harnesses loads"

echo "home-render: wrote ${HOME_DIR}/nginx.conf, ${HOME_DIR}/site/index.html, ${HOME_DIR}/site/guide/index.html, ${HOME_DIR}/site/guide/readme/index.html, ${HOME_DIR}/site/guide/manual/, ${HOME_DIR}/site/guide/north-star/index.html, ${HOME_DIR}/site/guide/ga-release/index.html, ${HOME_DIR}/site/guide/agent-stack/index.html, ${HOME_DIR}/site/guide/messaging/index.html, ${HOME_DIR}/site/guide/knowledge-sharing/index.html and ${HOME_DIR}/site/tmux-help/index.html"
