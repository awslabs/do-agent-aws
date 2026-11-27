#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the tmux-agent dashboard tile (the UI_TMUX_AGENT block of /agent/ui-start.sh, its
# rows in ui-status.sh and ui-stop.sh, the /tmux-agent/ route + tile of /agent/home-render.sh,
# the vendored build at /opt/tmux-agent, and the .env contract). The dashboard ships IN the image
# (a prebuilt copy of the public source, so it needs no network), so with the flag on - the shipped
# default - it must start;
# every check about serving it runs unconditionally and FAILS when it cannot, never skips.
# The optional override path (TMUX_AGENT_SRC: build from a source of your own with
# /agent/install-tmux-agent.sh) keeps its planted offline controls here and its live checks run
# only when the caller exports a reachable TMUX_AGENT_SRC. Fully OFFLINE otherwise: everything
# binds 127.0.0.1 on test-local ports and state directories.
#
# Properties proven (each check FAILS if the property is removed):
#   1. all scripts involved parse (bash -n)
#   2. .env contract: UI_TMUX_AGENT=true is the default; TMUX_AGENT_SRC, when set by value, is a
#      credential-free https URL (a token URL is refused - PLANTED CONTROL) and reaches the container
#      as a bare -e; TMUX_AGENT_REF and
#      TMUX_AGENT_INSTALL_DIR are declared and passed by value; the default PORT_MAP is still
#      exactly one publish; the compose and kubernetes templates carry the same
#   3. home-render.sh: enabled (the default), the route exists and carries the loopback-only Host
#      and Origin maps, the /api/ rewrite and the badge rule, the tile is live and names the
#      vendored build (or TMUX_AGENT_SRC when set); disabled, no route, no maps, a greyed tile
#      naming the flag AND where the build comes from; the config validates when nginx is here
#   4. the vendored build is present with its LICENSE and NOTICE and runs (--version); its provenance: package.json's
#      repository, homepage and bugs and the NOTICE name the repository TMUX_AGENT_SRC defaults to, VENDORED.md's
#      commit is the build's (dist/build.json) and, with a checkout at hand, .env's TMUX_AGENT_REF - the offline copy
#      and the first-start build are one commit (PLANTED CONTROLS, one property each: every package.json link
#      alone, a NOTICE naming a private repository beside the public one, a VENDORED.md naming another commit,
#      and with a checkout a .env pinning another commit)
#   5. ui-start.sh (TMUX_AGENT_SRC unset) serves the vendored build: no install log, the pidfile pid
#      IS the dashboard, / is 200 on 127.0.0.1, the listener is loopback-only, it watches the
#      DEFAULT tmux server (a planted session is listed), it is writable, a re-run leaves it
#      untouched, ui-status.sh reports it UP
#   6. through the home proxy (nginx present): /tmux-agent/ answers 200 with every root-absolute
#      '/api/ reference rewritten into the route and the badge, /tmux-agent/api/fleet answers 200
#      (Host rewrite), the dashboard's own guard still refuses cross-site, a foreign Origin and a
#      DNS-rebinding Host (421 from the home listener's Host allowlist; and the dashboard's own 403
#      when the same Host reaches its port directly), a same-site POST reaches it (negative controls)
#   7. ui-stop.sh takes it down: the port answers nothing, the pidfile is gone
#   8. UI_TMUX_WRITABLE=false starts it read-only: policy file written and passed, fleet readOnly,
#      a send to the planted session answers 403
#   9. PLANTED CONTROL: with the vendored build hidden, ui-start.sh says so and starts nothing
#      (no pidfile, port silent), ui-status.sh names the missing build, and check 5's own serve
#      probe goes red on it - "cannot start" is a failure here, never a skip
#  10. ui-status.sh with TMUX_AGENT_SRC set and no finished install names the source setting, not a
#      bare DOWN - also when a dist/ is there without the installer's stamp (a failed build)
#  11. PLANTED CONTROLS for the installer: an unreachable source exits non-zero with EXACTLY ONE
#      stderr line naming the fix and creates nothing; an unreachable TOKEN URL is refused the same
#      way with the token masked everywhere (the planted token appears in no output)
#  12. the shipped TMUX_AGENT_INSTALL_DIR default (ui-start.sh, ui-status.sh, install-tmux-agent.sh and
#      .env agree) is on the /wd volume yet outside both repository scans: with a finished install
#      planted there in a test workspace, starter-repo.sh still creates projects/scratch and
#      vk-runner-repos.sh does not register the checkout (PLANTED CONTROL: the earlier default
#      /wd/tmux-agent, directly under the workspace, fails both)
#  -- override path, only when TMUX_AGENT_SRC is exported and reachable from here --
#  13. the installer produces a build that runs, records no remote, writes its stamp, is
#      idempotent; a credential URL leaves only the masked source in the stamp and a rotated
#      token is the same source; ui-start.sh serves that build; a changed TMUX_AGENT_REF is
#      re-installed; a build that fails type-checking is never served and is retried
# Uses test-local state directories (/tmp/tmux-agent-smoke*, or TEST14_DIR when running from a
# checkout outside the container); does not disturb live state under /wd.

D=${TEST14_DIR:-/tmp/tmux-agent-smoke}
rm -rf "${D:?}"
mkdir -p "${D}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"

export UI_DIR=${D}/ui
export UI_LISTEN_HOST=127.0.0.1
export UI_HOME=false
export UI_HEADLAMP=false
export UI_HINDSIGHT=false
export UI_VIBE_KANBAN=false
export UI_TMUX=false
export UI_CLAUDE_MEM=false
export UI_LOGLEARNER=false
export UI_LOOP=false
export UI_FILES=false
export UI_TMUX_WRITABLE=true
export UI_TMUX_AGENT=true
export COMMS_UI_ENABLED=false
export UI_PORT_HOME=18014
export UI_PORT_TMUX_AGENT=17338
# the vendored build: the image's /opt/tmux-agent, or the repo's Container-Root/opt/tmux-agent
# when running from a checkout (the web verb needs only node builtins, no node_modules)
if [ -z "${TMUX_AGENT_VENDORED_DIR}" ]; then
	TMUX_AGENT_VENDORED_DIR=/opt/tmux-agent
	[ -f "${TMUX_AGENT_VENDORED_DIR}/dist/bin/tmux-agent.js" ] || TMUX_AGENT_VENDORED_DIR="${BASE_DIR}/opt/tmux-agent"
fi
export TMUX_AGENT_VENDORED_DIR
# the override path's build under test, test-local; TMUX_AGENT_SRC only as the caller exported it
export TMUX_AGENT_INSTALL_DIR=${D}/tmux-agent
# the dashboard's OWN state directory (ledger, web-token) - test-local, never the operator's
export TMUX_AGENT_HOME=${D}/dashboard-state
PLANTED_SESSION=tmux-agent-smoke-sess
TOKEN=tmux14plantedtoken

mask()
{
	echo "$1" | sed -E 's#(://)[^/@[:space:]]+@#\1***@#g'
}

cleanup()
{
	"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
	tmux kill-session -t ${PLANTED_SESSION} 2>/dev/null
	if [ -f "${D}/scan-runner.pid" ]; then kill "$(cat "${D}/scan-runner.pid")" 2>/dev/null; fi
}
# every exit - pass, fail or an interrupted run - stops what the test started
trap cleanup EXIT
trap 'exit 130' INT TERM

fail()
{
	echo "Test14 FAILED: $1"
	exit 1
}

# --- 1. syntax ---
for S in "${AGENT_DIR}/install-tmux-agent.sh" "${AGENT_DIR}/ui-start.sh" "${AGENT_DIR}/ui-status.sh" \
         "${AGENT_DIR}/ui-stop.sh" "${AGENT_DIR}/home-render.sh" "${BASE_DIR}/setup/install-tmux-agent-dashboard.sh"; do
	bash -n "${S}" || fail "bash -n ${S}"
done
echo "ok 1 - syntax"

# --- 2. .env contract (and the templates), when a checkout is at hand ---
ENV_FILE=""
for C in "${BASE_DIR}/../.env" "/do-agent-aws/.env" "${BASE_DIR}/.env"; do
	[ -f "${C}" ] && ENV_FILE="$(cd "$(dirname "${C}")" && pwd)/.env" && break
done
if [ -n "${ENV_FILE}" ]; then
	ENV_DIR="$(dirname "${ENV_FILE}")"
	grep -qE '^export UI_TMUX_AGENT=true$' "${ENV_FILE}" || fail "UI_TMUX_AGENT=true is not the .env default (the vendored dashboard must be on out of the box)"
	grep -qE '^export TMUX_AGENT_REF=' "${ENV_FILE}" || fail "TMUX_AGENT_REF is not declared in .env"
	grep -qE '^export TMUX_AGENT_INSTALL_DIR=' "${ENV_FILE}" || fail "TMUX_AGENT_INSTALL_DIR is not declared in .env"
	# a value is allowed only as a credential-free https URL (the public source); anything with a credential in it must never land here
	if grep -qE '^export TMUX_AGENT_SRC=' "${ENV_FILE}"; then
		grep -qE '^export TMUX_AGENT_SRC=(https://[^@[:space:]]+|\$\{TMUX_AGENT_SRC:-\})$' "${ENV_FILE}" \
			|| fail ".env sets TMUX_AGENT_SRC to something other than a credential-free https URL (a token must never land in this file)"
	fi
	# planted control: the same rule must refuse a token URL
	printf 'export TMUX_AGENT_SRC=https://token@example.invalid/repo.git\n' > "${D}/env-planted-token"
	grep -qE '^export TMUX_AGENT_SRC=https://[^@[:space:]]+$' "${D}/env-planted-token" && fail ".env contract accepted a token URL for TMUX_AGENT_SRC (planted control)"
	grep -qF -- '-e TMUX_AGENT_SRC -e TMUX_AGENT_REF=$(shq "${TMUX_AGENT_REF}") -e TMUX_AGENT_INSTALL_DIR=$(shq "${TMUX_AGENT_INSTALL_DIR}")' "${ENV_FILE}" \
		|| fail "UI_ENV_OPTS does not pass TMUX_AGENT_SRC (bare) + TMUX_AGENT_REF + TMUX_AGENT_INSTALL_DIR"
	grep -qF -- '-e UI_TMUX_AGENT=$(shq "${UI_TMUX_AGENT}")' "${ENV_FILE}" || fail "UI_ENV_OPTS does not pass UI_TMUX_AGENT"
	# the dashboard rides the home port: with the flag on by default the run command still has ONE publish
	PM_DEFAULT=$( cd "${ENV_DIR}" && source "${ENV_FILE}" > /dev/null 2>&1; echo "${PORT_MAP}" )
	[ "$(echo "${PM_DEFAULT}" | grep -o '\-p ' | wc -l)" == "1" ] \
		|| fail "default PORT_MAP is not exactly one publish with the dashboard on: '${PM_DEFAULT}'"
	COMPOSE="${ENV_DIR}/to/compose/template/docker-compose.yaml"
	K8S="${ENV_DIR}/to/kubernetes/template/020-deployment.yaml"
	if [ -f "${COMPOSE}" ]; then
		grep -qE '^\s+- TMUX_AGENT_SRC$' "${COMPOSE}" || fail "compose template does not carry TMUX_AGENT_SRC as a bare (host-resolved) entry"
		grep -qF -- '- TMUX_AGENT_INSTALL_DIR=${TMUX_AGENT_INSTALL_DIR}' "${COMPOSE}" || fail "compose template does not pass TMUX_AGENT_INSTALL_DIR"
		grep -qF -- '- UI_TMUX_AGENT=${UI_TMUX_AGENT}' "${COMPOSE}" || fail "compose template does not pass UI_TMUX_AGENT"
	fi
	if [ -f "${K8S}" ]; then
		grep -qF 'name: ${APP_NAME}-tmux-agent' "${K8S}" || fail "kubernetes template has no optional ${APP_NAME}-tmux-agent secret for TMUX_AGENT_SRC"
		grep -qF -- '- name: TMUX_AGENT_INSTALL_DIR' "${K8S}" || fail "kubernetes template does not pass TMUX_AGENT_INSTALL_DIR"
		grep -qF -- 'containerPort: ${PORT_INTERNAL_TMUX_AGENT}' "${K8S}" || fail "kubernetes template does not declare the dashboard's containerPort"
	fi
	echo "ok 2 - .env contract: flag on by default, one publish, source never by value, bare -e + templates carry it"
else
	echo "ok 2 - (skipped: no .env found in this context)"
fi

# --- 3. the tile text and the route ---
CONF=${UI_DIR}/home/nginx.conf
PAGE=${UI_DIR}/home/site/index.html
( export UI_TMUX_AGENT=false; "${AGENT_DIR}/home-render.sh" > /dev/null ) || fail "home-render.sh (UI_TMUX_AGENT=false)"
grep -qF "location /tmux-agent/" "${CONF}" && fail "disabled tmux-agent still has a proxy route"
grep -qF "tmux_agent_" "${CONF}" && fail "disabled tmux-agent still renders its Host/Origin maps"
grep -qF 'off - set UI_TMUX_AGENT=true in .env; source: the build vendored in the image (/opt/tmux-agent), or TMUX_AGENT_SRC to build another' "${PAGE}" \
	|| fail "greyed tmux-agent tile does not carry the exact flag + source text"
# the vendored-build wording is asserted with the source unset explicitly: .env now sets TMUX_AGENT_SRC by
# default, so the caller's environment usually carries it (checks 5-9 unset it the same way)
( unset TMUX_AGENT_SRC; "${AGENT_DIR}/home-render.sh" > /dev/null ) || fail "home-render.sh (UI_TMUX_AGENT=true)"
grep -qF "location /tmux-agent/" "${CONF}" || fail "enabled tmux-agent route missing"
grep -qF "set \$proxy_upstream_host \$tmux_agent_host;" "${CONF}" || fail "route lacks the Host override the dashboard's DNS-rebinding guard needs"
grep -qF "map \$http_host \$tmux_agent_host" "${CONF}" || fail "the Host map is missing"
grep -A3 -F "map \$http_host \$tmux_agent_host" "${CONF}" | grep -qF 'default $http_host;' \
	|| fail "the Host map does not forward a non-loopback Host as sent (the dashboard must see a DNS-rebinding Host)"
grep -A3 -F "map \$http_host \$tmux_agent_host" "${CONF}" | grep -qF "\"127.0.0.1:${UI_PORT_TMUX_AGENT}\";" \
	|| fail "the Host map does not rewrite a loopback Host to the dashboard's own address"
grep -qF "proxy_set_header Origin \$tmux_agent_origin;" "${CONF}" || fail "route lacks the Origin rewrite the dashboard's CSRF guard needs"
grep -qF "map \$http_origin \$tmux_agent_origin" "${CONF}" || fail "the Origin map is missing"
grep -qF "sub_filter \"'/api/\" \"'/tmux-agent/api/\";" "${CONF}" || fail "route lacks the /api/ -> /tmux-agent/api/ rewrite"
grep -qF "badge-rule.conf" "${CONF}" || fail "route lacks the home badge rule"
[ -s "${UI_DIR}/home/badge-rule.conf" ] || fail "badge-rule.conf was not rendered"
grep -qF 'data-url="/tmux-agent/"' "${PAGE}" || fail "enabled tmux-agent tile is not live"
grep -qF 'vendored build in the image; set TMUX_AGENT_SRC to build another source' "${PAGE}" \
	|| fail "the live tmux-agent tile does not say it serves the vendored build"
( export TMUX_AGENT_SRC=/some/source; "${AGENT_DIR}/home-render.sh" > /dev/null ) || fail "home-render.sh (TMUX_AGENT_SRC set)"
grep -qF 'built from TMUX_AGENT_SRC by install-tmux-agent.sh at first start' "${PAGE}" \
	|| fail "with TMUX_AGENT_SRC set the tile does not say the build comes from the source"
"${AGENT_DIR}/home-render.sh" > /dev/null
if command -v nginx > /dev/null; then
	nginx -t -c "${CONF}" > /dev/null 2>&1 || { nginx -t -c "${CONF}"; fail "rendered nginx.conf does not validate"; }
	echo "ok 3 - tile text exact (vendored / source), route carries loopback Host/Origin maps + api rewrite only when enabled, config validates"
else
	echo "ok 3 - tile text exact (vendored / source), route carries loopback Host/Origin maps + api rewrite only when enabled (nginx -t skipped: no nginx here)"
fi

# --- 4. the vendored build is there, licensed, and runs ---
VENDORED_JS=${TMUX_AGENT_VENDORED_DIR}/dist/bin/tmux-agent.js
[ -f "${VENDORED_JS}" ] || fail "no vendored dashboard at ${VENDORED_JS} (Container-Root/opt/tmux-agent must ship dist/; the image puts it at /opt/tmux-agent)"
[ -f "${TMUX_AGENT_VENDORED_DIR}/LICENSE" ] && [ -f "${TMUX_AGENT_VENDORED_DIR}/NOTICE" ] \
	|| fail "the vendored tree lacks LICENSE and/or NOTICE (Apache-2.0 redistribution requires both)"
grep -qF "Apache License" "${TMUX_AGENT_VENDORED_DIR}/LICENSE" || fail "the vendored LICENSE is not the Apache License"
command -v node > /dev/null || fail "node not installed here - the dashboard cannot run (setup/install-nodejs.sh)"
VERSION=$(node "${VENDORED_JS}" --version 2>/dev/null)
[ -n "${VERSION}" ] || fail "the vendored dashboard does not run (node ${VENDORED_JS} --version printed nothing)"
# where the copy comes from: the links a person follows (package.json's repository, homepage and bugs; the NOTICE) name
# the repository TMUX_AGENT_SRC defaults to, and VENDORED.md's commit is the build's and the first-start build's
REPO_URL=$(sed -n 's/^TMUX_AGENT_SRC=\${TMUX_AGENT_SRC:-\(.*\)}$/\1/p' "${AGENT_DIR}/install-tmux-agent.sh")
REPO_URL=${REPO_URL%.git}
[ -n "${REPO_URL}" ] || fail "install-tmux-agent.sh states no default TMUX_AGENT_SRC (the repository the vendored copy's links must name)"
REVENDOR="re-vendor with tools/vendor-tmux-agent.sh, record the commit it prints in VENDORED.md and pin it as .env's TMUX_AGENT_REF"
# prints the first broken provenance property of the vendored tree $1 and returns 1; returns 0 when there is none.
# ENV_FILE (check 2's, or a caller's override) is the .env whose TMUX_AGENT_REF must be that commit
vendored_provenance()
{
	local commit built pin
	python3 - "$1" "${REPO_URL}" << 'EOF' || return 1
import json, re, sys
d, want = sys.argv[1], sys.argv[2]
try:
    p = json.load(open(d + "/package.json"))
    notice = open(d + "/NOTICE").read()
except (OSError, ValueError) as e:
    print(f"package.json or NOTICE cannot be read: {e}")
    sys.exit(1)
def norm(u):
    u = u[4:] if u.startswith("git+") else u
    return u[:-4] if u.endswith(".git") else u
repo, bugs = p.get("repository"), p.get("bugs")
links = {"repository": repo.get("url", "") if isinstance(repo, dict) else (repo or ""), "homepage": p.get("homepage") or "",
         "bugs": bugs.get("url", "") if isinstance(bugs, dict) else (bugs or "")}
bad = [f"{k} {v!r}" for k, v in links.items() if not (norm(v) == want or norm(v).startswith((want + "/", want + "#")))]
# the NOTICE names the public repository and no other repository of its owner (a private URL beside it is caught)
owner = want.rsplit("/", 1)[0]
others = sorted({norm(u.rstrip(".,;")) for u in re.findall(re.escape(owner) + r"/[^\s)\"'>]+", notice)} - {want})
if want not in notice or others:
    bad.append(f"NOTICE (names {want}: {want in notice}; other URLs of {owner}: {others})")
if bad:
    print(f"the links do not name {want}: " + ", ".join(bad))
    sys.exit(1)
EOF
	commit=$(grep -oE '^\| Commit \| `[0-9a-f]{40}`' "$1/VENDORED.md" 2>/dev/null | grep -oE '[0-9a-f]{40}')
	[ -n "${commit}" ] || { echo "VENDORED.md records no 40-hex commit in its | Commit | row"; return 1; }
	built=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["commit"])' "$1/dist/build.json" 2>/dev/null)
	case "${commit}" in "${built:-none}"*) ;; *) echo "VENDORED.md records ${commit} but dist/build.json was built from ${built:-nothing readable}"; return 1 ;; esac
	if [ -n "${ENV_FILE}" ]; then
		pin=$(sed -n 's/^export TMUX_AGENT_REF=//p' "${ENV_FILE}" | tail -1)
		[ "${pin}" == "${commit}" ] || { echo "VENDORED.md records ${commit} but .env pins TMUX_AGENT_REF=${pin} for the first-start build"; return 1; }
	fi
	return 0
}
WHY=$(vendored_provenance "${TMUX_AGENT_VENDORED_DIR}") || fail "the vendored copy's provenance: ${WHY} (${REVENDOR})"
# PLANTED CONTROLS, each on a copy of the metadata that breaks ONE property: each package.json link alone, the NOTICE
# alone (a private URL beside the public one), the commit VENDORED.md records, and - with a .env at hand - the .env pin
P=${D:?}/planted-vendored
plant()
{
	{ rm -rf "${P:?}" && mkdir -p "${P}/dist" && cp "${TMUX_AGENT_VENDORED_DIR}/VENDORED.md" "${TMUX_AGENT_VENDORED_DIR}/NOTICE" \
		"${TMUX_AGENT_VENDORED_DIR}/package.json" "${P}/" && cp "${TMUX_AGENT_VENDORED_DIR}/dist/build.json" "${P}/dist/"; } \
		|| fail "could not plant a copy of the vendored metadata at ${P}"
}
for KEY in repository homepage bugs; do
	plant
	python3 - "${P}/package.json" "${KEY}" << 'EOF'
import json, sys
f, key = sys.argv[1], sys.argv[2]
p = json.load(open(f))
other = "https://github.com/example/private-dashboard" + ("/issues" if key == "bugs" else "")
if isinstance(p.get(key), dict):
    p[key]["url"] = other
else:
    p[key] = other
json.dump(p, open(f, "w"), indent=2)
EOF
	vendored_provenance "${P}" > /dev/null && fail "PLANTED CONTROL BROKEN: a package.json whose ${KEY} alone names another repository passed the provenance check"
done
plant
printf '%s\n' "(${REPO_URL%/*}/private-dashboard)" >> "${P}/NOTICE"
vendored_provenance "${P}" > /dev/null && fail "PLANTED CONTROL BROKEN: a NOTICE naming a private repository beside the public one passed the provenance check"
plant
sed -E 's#^(\| Commit \| `)[0-9a-f]{7}#\10000000#' "${TMUX_AGENT_VENDORED_DIR}/VENDORED.md" > "${P}/VENDORED.md"
vendored_provenance "${P}" > /dev/null && fail "PLANTED CONTROL BROKEN: a VENDORED.md naming another commit passed the provenance check"
PIN_CONTROL=""
if [ -n "${ENV_FILE}" ]; then
	plant
	sed -E 's#^(export TMUX_AGENT_REF=)[0-9a-f]{7}#\10000000#' "${ENV_FILE}" > "${P}/env-other-pin"
	( ENV_FILE=${P}/env-other-pin; vendored_provenance "${P}" > /dev/null ) && fail "PLANTED CONTROL BROKEN: a .env pinning another commit passed the provenance check"
	PIN_CONTROL=", another .env pin"
fi
echo "ok 4 - vendored build ${VERSION} at ${TMUX_AGENT_VENDORED_DIR}, LICENSE + NOTICE present; package.json and NOTICE name ${REPO_URL}, VENDORED.md's commit is the build's${ENV_FILE:+ and the .env pin TMUX_AGENT_REF}; planted controls: each link, the NOTICE, another commit${PIN_CONTROL}"

# wait_up [port] - the dashboard answers 200 on its port within 60 s
wait_up()
{
	for i in $(seq 1 60); do
		[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${1:-${UI_PORT_TMUX_AGENT}}/" 2>/dev/null)" == "200" ] && return 0
		sleep 1
	done
	return 1
}
# listeners <port> - every address bound on the port (ss when present, else /proc/net/tcp*)
listeners()
{
	if command -v ss > /dev/null; then
		ss -ltnH "sport = :$1" 2>/dev/null | awk '{print $4}'
	else
		awk -v p=":$(printf '%04X' "$1")" '$4=="0A" && index($2,p) {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
	fi
}

# --- 5. ui-start.sh serves the vendored build, loopback-only, on the default tmux server ---
if command -v tmux > /dev/null; then
	tmux new-session -d -s ${PLANTED_SESSION} || fail "could not plant a tmux session on the default server"
fi
( unset TMUX_AGENT_SRC; "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-1.log 2>&1 ) || { cat ${D}/ui-start-1.log; fail "ui-start.sh"; }
grep -q "installing" ${D}/ui-start-1.log && fail "ui-start.sh ran the installer although no TMUX_AGENT_SRC is set: $(cat ${D}/ui-start-1.log)"
[ -e ${UI_DIR}/tmux-agent-install.log ] && fail "the vendored path wrote an install log"
[ -e "${TMUX_AGENT_INSTALL_DIR}" ] && fail "the vendored path created ${TMUX_AGENT_INSTALL_DIR}"
PID=$(cat ${UI_DIR}/tmux-agent.pid 2>/dev/null)
[ -n "${PID}" ] || fail "ui-start.sh wrote no tmux-agent.pid: $(cat ${D}/ui-start-1.log)"
tr '\0' ' ' < /proc/${PID}/cmdline 2>/dev/null | grep -q "${VENDORED_JS} web" || fail "pid ${PID} in tmux-agent.pid is not the vendored dashboard: $(tr '\0' ' ' < /proc/${PID}/cmdline 2>/dev/null)"
wait_up || { tail -5 ${UI_DIR}/tmux-agent.log; fail "dashboard not answering 200 on 127.0.0.1:${UI_PORT_TMUX_AGENT}/"; }
curl -s --max-time 5 "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/" > ${D}/root.html
grep -q "<title>tmux-agent</title>" ${D}/root.html || fail "/ does not carry the dashboard page"
ADDRS=$(listeners ${UI_PORT_TMUX_AGENT})
[ -n "${ADDRS}" ] || fail "no listener found on port ${UI_PORT_TMUX_AGENT}"
echo "${ADDRS}" | grep -qvE '^(127\.0\.0\.1:|0100007F:)' && fail "dashboard listens beyond loopback: ${ADDRS}"
FLEET=$(curl -s --max-time 5 "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/api/fleet")
echo "${FLEET}" | grep -q '"reachable":true' || fail "dashboard does not reach the default tmux server: $(echo "${FLEET}" | head -c 300)"
if command -v tmux > /dev/null; then
	echo "${FLEET}" | grep -qF "${PLANTED_SESSION}" || fail "the planted default-server session is not in the fleet: $(echo "${FLEET}" | head -c 300)"
fi
# writable by default: the fleet says so and a send is not refused by policy (to a session that
# does not exist, so nothing is typed anywhere)
echo "${FLEET}" | grep -q '"readOnly":false' || fail "the dashboard is not writable by default: $(echo "${FLEET}" | head -c 300)"
HTTP=$(curl -s -o ${D}/send-rw.out -w '%{http_code}' --max-time 5 -X POST -H 'content-type: application/json' \
	--data '{"name":"nosuch","text":"x"}' "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/api/send")
[ "${HTTP}" != "403" ] && ! grep -q "read-only" ${D}/send-rw.out \
	|| fail "a send was refused by policy with UI_TMUX_WRITABLE at its default (http=${HTTP}: $(head -c 200 ${D}/send-rw.out))"
( unset TMUX_AGENT_SRC; "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-2.log 2>&1 ) || fail "ui-start.sh re-run"
grep -q "tmux-agent: already running (pid ${PID})" ${D}/ui-start-2.log || fail "re-run did not leave the live dashboard untouched: $(cat ${D}/ui-start-2.log)"
( unset TMUX_AGENT_SRC; "${AGENT_DIR}/ui-status.sh" > ${D}/status.log 2>&1 )
grep -q "tmux-agent: UP pid=${PID} http=200 port=${UI_PORT_TMUX_AGENT}" ${D}/status.log || fail "ui-status.sh does not report the dashboard UP: $(cat ${D}/status.log)"
grep -q "vendored build missing" ${D}/status.log && fail "ui-status.sh claims the vendored build is missing while serving it"
echo "ok 5 - vendored build served: no installer, pid is the dashboard, 200 on /, loopback-only, default tmux server watched, writable, re-run idempotent, status UP"

# --- 6. through the home proxy ---
if command -v nginx > /dev/null; then
	( unset TMUX_AGENT_SRC; export UI_HOME=true; "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-home.log 2>&1 ) || { cat ${D}/ui-start-home.log; fail "ui-start.sh (UI_HOME=true)"; }
	probe()
	{
		# probe <url> [curl args...] - retries until 2xx/3xx or timeout, echoes last code
		URL=$1
		shift
		HTTP=000
		for i in $(seq 1 30); do
			HTTP=$(curl -s -o ${D}/probe.out -w '%{http_code}' --max-time 3 "$@" "${URL}" 2>/dev/null)
			[ "${HTTP}" -ge 200 ] 2>/dev/null && [ "${HTTP}" -lt 400 ] 2>/dev/null && break
			sleep 1
		done
		echo "${HTTP}"
	}
	H=http://127.0.0.1:${UI_PORT_HOME}
	HTTP=$(probe "${H}/tmux-agent/")
	[ "${HTTP}" == "200" ] || { tail -5 ${UI_DIR}/home.log 2>/dev/null; fail "/tmux-agent/ not answering 200 through the proxy (last=${HTTP})"; }
	[ "$(grep -o "'/tmux-agent/api/" ${D}/probe.out | wc -l)" -ge 1 ] || fail "proxied page carries no rewritten /tmux-agent/api/ reference"
	[ "$(grep -o "'/api/" ${D}/probe.out | wc -l)" == "0" ] || fail "proxied page still carries root-absolute '/api/ references (the rewrite is gone)"
	grep -qF 'do-agent-aws harness home' ${D}/probe.out || fail "proxied page carries no home badge"
	HTTP=$(probe "${H}/tmux-agent/api/fleet")
	[ "${HTTP}" == "200" ] || fail "/tmux-agent/api/fleet not 200 through the proxy (Host rewrite broken? last=${HTTP})"
	# negative controls: the dashboard's own guard still refuses through the proxy
	HTTP=$(curl -s -o ${D}/neg1.out -w '%{http_code}' --max-time 5 -H 'Sec-Fetch-Site: cross-site' "${H}/tmux-agent/api/fleet")
	[ "${HTTP}" == "403" ] || fail "a cross-site request passed through the proxy (http=${HTTP}: $(head -c 200 ${D}/neg1.out))"
	# a foreign-Origin POST: refused by the proxy's same-origin gate before the dashboard sees it, and by the dashboard's
	# own guard when it reaches the dashboard's port directly (the guard behind the gate)
	HTTP=$(curl -s -o ${D}/neg2.out -w '%{http_code}' --max-time 5 -X POST -H 'content-type: application/json' \
		-H 'Origin: http://evil.example' --data '{"name":"nosuch","text":"x"}' "${H}/tmux-agent/api/send")
	[ "${HTTP}" == "403" ] || fail "a foreign-Origin POST was not refused through the proxy (http=${HTTP}: $(head -c 200 ${D}/neg2.out))"
	HTTP=$(curl -s -o ${D}/neg3.out -w '%{http_code}' --max-time 5 -X POST -H 'content-type: application/json' \
		-H 'Origin: http://evil.example' --data '{"name":"nosuch","text":"x"}' "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/api/send")
	[ "${HTTP}" == "403" ] && grep -q "cross-origin request refused" ${D}/neg3.out \
		|| fail "the dashboard's own guard did not refuse a foreign-Origin POST on its port (http=${HTTP}: $(head -c 200 ${D}/neg3.out))"
	HTTP=$(curl -s -o ${D}/neg3.out -w '%{http_code}' --max-time 5 -H "Host: rebind.example:${UI_PORT_HOME}" "${H}/tmux-agent/api/fleet")
	[ "${HTTP}" == "421" ] \
		|| fail "a non-loopback Host was not refused by the home listener's Host allowlist (expected 421, http=${HTTP}: $(head -c 200 ${D}/neg3.out))"
	# ...and the dashboard's OWN guard still refuses that Host when it does arrive (sent straight to its
	# port, the way a process inside the container could): defence in depth, both layers proven
	HTTP=$(curl -s -o ${D}/neg3b.out -w '%{http_code}' --max-time 5 -H "Host: rebind.example:${UI_PORT_TMUX_AGENT}" "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/api/fleet")
	[ "${HTTP}" == "403" ] && grep -q "not loopback" ${D}/neg3b.out \
		|| fail "the dashboard's own guard let a non-loopback Host read it on its port (http=${HTTP}: $(head -c 200 ${D}/neg3b.out))"
	# the browser's same-origin POST from the home page: its Host and its Origin are both the page's (localhost:<home port>)
	HTTP=$(curl -s -o ${D}/pos.out -w '%{http_code}' --max-time 5 -X POST -H 'content-type: application/json' \
		-H "Host: localhost:${UI_PORT_HOME}" -H "Origin: http://localhost:${UI_PORT_HOME}" -H 'Sec-Fetch-Site: same-origin' \
		--data '{"name":"nosuch","text":"x"}' "${H}/tmux-agent/api/send")
	grep -q "refused" ${D}/pos.out && fail "a same-site POST was refused through the proxy (Origin rewrite broken): $(head -c 200 ${D}/pos.out)"
	[ "${HTTP}" != "000" ] && [ "${HTTP}" != "403" ] && [ "$(head -c 1 ${D}/pos.out)" == "{" ] \
		|| fail "a same-site POST did not reach the dashboard through the proxy (http=${HTTP}: $(head -c 200 ${D}/pos.out))"
	echo "ok 6 - through the proxy: 200 with /api/ rewritten + badge, API 200 (Host rewrite), guard refuses cross-site, foreign Origin and non-loopback Host, same-site POST reaches the dashboard (http=${HTTP})"
else
	echo "ok 6 - (skipped: nginx not installed here - check 6 runs wherever nginx is present)"
fi

# --- 7. ui-stop.sh takes it down ---
"${AGENT_DIR}/ui-stop.sh" > ${D}/ui-stop.log 2>&1
grep -q "tmux-agent: stopped (pid ${PID})" ${D}/ui-stop.log || fail "ui-stop.sh did not stop the dashboard: $(cat ${D}/ui-stop.log)"
sleep 1
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/" 2>/dev/null)
[ "${HTTP}" == "000" ] || fail "dashboard port still answers after ui-stop.sh (http=${HTTP})"
[ -f ${UI_DIR}/tmux-agent.pid ] && fail "ui-stop.sh left tmux-agent.pid behind"
echo "ok 7 - ui-stop.sh: dashboard down, port silent, pidfile gone"

# --- 8. watch-only harness: UI_TMUX_WRITABLE=false starts the dashboard read-only ---
( unset TMUX_AGENT_SRC; export UI_TMUX_WRITABLE=false; "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-ro.log 2>&1 ) || { cat ${D}/ui-start-ro.log; fail "ui-start.sh (UI_TMUX_WRITABLE=false)"; }
wait_up || { tail -5 ${UI_DIR}/tmux-agent.log; fail "read-only dashboard not answering 200"; }
HTTP=$(curl -s -o ${D}/send-ro.out -w '%{http_code}' --max-time 5 -X POST -H 'content-type: application/json' \
	--data "{\"name\":\"${PLANTED_SESSION}\",\"text\":\"x\"}" "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/api/send")
[ "${HTTP}" == "403" ] && grep -q "read-only" ${D}/send-ro.out \
	|| fail "UI_TMUX_WRITABLE=false: a send into the planted session was not refused (http=${HTTP}: $(head -c 200 ${D}/send-ro.out))"
curl -s --max-time 5 "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/api/fleet" | grep -q '"readOnly":true' || fail "the dashboard does not report readOnly with UI_TMUX_WRITABLE=false"
grep -qxF '{"surfaces":{"web":{"readOnly":true}}}' ${UI_DIR}/tmux-agent-policy.json 2>/dev/null || fail "no read-only policy file at ${UI_DIR}/tmux-agent-policy.json"
PID=$(cat ${UI_DIR}/tmux-agent.pid 2>/dev/null)
tr '\0' '\n' < /proc/${PID}/environ 2>/dev/null | grep -qxF "TMUX_AGENT_POLICY=${UI_DIR}/tmux-agent-policy.json" \
	|| fail "the read-only policy file was not passed to the dashboard (TMUX_AGENT_POLICY)"
"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
echo "ok 8 - UI_TMUX_WRITABLE=false: policy written and passed, fleet readOnly, send refused 403"

# --- 9. planted control: a missing vendored build is a loud non-start, and check 5's probe goes red ---
mkdir -p ${D}/no-vendored
( unset TMUX_AGENT_SRC; export TMUX_AGENT_VENDORED_DIR=${D}/no-vendored; "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-missing.log 2>&1 )
grep -qF "tmux-agent: not started - vendored build missing at ${D}/no-vendored/dist/bin/tmux-agent.js" ${D}/ui-start-missing.log \
	|| fail "planted control: ui-start.sh does not name the missing vendored build: $(cat ${D}/ui-start-missing.log)"
[ -f ${UI_DIR}/tmux-agent.pid ] && fail "planted control: a missing build still left a tmux-agent.pid"
grep -q "installing" ${D}/ui-start-missing.log && fail "planted control: a missing vendored build triggered the installer (no source is set)"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/" 2>/dev/null)
[ "${HTTP}" == "000" ] || fail "planted control: something answers on the dashboard port with the build missing (http=${HTTP})"
( unset TMUX_AGENT_SRC; export TMUX_AGENT_VENDORED_DIR=${D}/no-vendored; "${AGENT_DIR}/ui-status.sh" > ${D}/status-missing.log 2>&1 )
grep -qF "tmux-agent: vendored build missing at ${D}/no-vendored/dist/bin/tmux-agent.js" ${D}/status-missing.log \
	|| fail "planted control: ui-status.sh does not name the missing vendored build: $(cat ${D}/status-missing.log)"
grep -q "^tmux-agent: DOWN" ${D}/status-missing.log || fail "planted control: ui-status.sh does not report the dashboard DOWN with the build missing"
# the serve probe of check 5 must read this as a failure (never a skip): the same wait_up goes red
wait_up_short() { for i in 1 2 3; do [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${UI_PORT_TMUX_AGENT}/" 2>/dev/null)" == "200" ] && return 0; sleep 1; done; return 1; }
wait_up_short && fail "planted control is vacuous: the serve probe passed with the build missing"
echo "ok 9 - planted control: missing vendored build -> loud non-start, no pidfile, port silent, status names it, the serve probe goes red"

# --- 10. status names the source setting on the override path while there is no build ---
STATUS=$(TMUX_AGENT_SRC=/some/source TMUX_AGENT_INSTALL_DIR=${D}/nobuild "${AGENT_DIR}/ui-status.sh" 2>&1)
echo "${STATUS}" | grep -qF "tmux-agent: not installed at ${D}/nobuild" || fail "ui-status.sh without a build does not say so: ${STATUS}"
echo "${STATUS}" | grep -qF "source: TMUX_AGENT_SRC (set: the installer builds from it - any reachable clone works; unset it to serve the vendored build)" \
	|| fail "ui-status.sh without a build does not name the source setting: ${STATUS}"
# a dist/ without the installer's stamp is what a failed build leaves (tsc emits on type errors)
mkdir -p ${D}/nostamp/dist/bin && echo "// planted" > ${D}/nostamp/dist/bin/tmux-agent.js
STATUS=$(TMUX_AGENT_SRC=/some/source TMUX_AGENT_INSTALL_DIR=${D}/nostamp "${AGENT_DIR}/ui-status.sh" 2>&1)
echo "${STATUS}" | grep -qF "tmux-agent: not installed at ${D}/nostamp" \
	|| fail "ui-status.sh takes a dist/ without the install stamp for an install: ${STATUS}"
echo "ok 10 - override path: ui-status.sh names the source setting while there is no finished install (dist/ without a stamp included)"

# --- 11. planted controls: the installer refuses an unreachable source with one line, no token ---
TMUX_AGENT_SRC=/nonexistent TMUX_AGENT_INSTALL_DIR=${D}/ctrl "${AGENT_DIR}/install-tmux-agent.sh" > ${D}/ctrl.out 2> ${D}/ctrl.err
RC=$?
[ ${RC} -ne 0 ] || fail "planted control: installer exited 0 with TMUX_AGENT_SRC=/nonexistent"
[ "$(wc -l < ${D}/ctrl.err)" == "1" ] || fail "planted control: expected exactly ONE stderr line, got $(wc -l < ${D}/ctrl.err): $(cat ${D}/ctrl.err)"
grep -qF 'source not reachable: set TMUX_AGENT_SRC to a clone you can reach' ${D}/ctrl.err \
	|| fail "planted control: the stderr line does not name the fix: $(cat ${D}/ctrl.err)"
[ -d ${D}/ctrl ] && fail "planted control: an unreachable source still created ${D}/ctrl"
TMUX_AGENT_SRC="https://x-access-token:${TOKEN}@127.0.0.1:9/nobody/tmux-agent.git" TMUX_AGENT_INSTALL_DIR=${D}/ctrl2 \
	"${AGENT_DIR}/install-tmux-agent.sh" > ${D}/ctrl2.out 2> ${D}/ctrl2.err
[ $? -ne 0 ] || fail "planted control: installer exited 0 on an unreachable token URL"
grep -q "${TOKEN}" ${D}/ctrl2.out ${D}/ctrl2.err && fail "TOKEN LEAK: the planted token appears in the installer's output"
grep -qF '***@' ${D}/ctrl2.out ${D}/ctrl2.err || fail "the token URL was not echoed in masked form (the mask is gone?)"
echo "ok 11 - installer: unreachable source -> non-zero, exactly one stderr line naming the fix, nothing created, token masked"

# --- 12. the install dir is on the /wd volume but outside the workspace's repository scans ---
# A checkout directly under /wd is a repository to starter-repo.sh (which then makes no starter repository) and to
# vk-runner-repos.sh (which registers it with the agent runner as the user's): the shipped default must be neither.
# A finished install (a checkout with its build and stamp, as the installer leaves it) is planted at that default
# inside a test workspace, then both scans run there, against a stub runner
DEFAULTS=$(for f in ui-start.sh ui-status.sh install-tmux-agent.sh; do
	sed -n 's/^TMUX_AGENT_INSTALL_DIR=\${TMUX_AGENT_INSTALL_DIR:-\(.*\)}$/\1/p' "${AGENT_DIR}/${f}" | grep . || echo "(none in ${f})"
done; [ -n "${ENV_FILE}" ] && sed -n 's/^export TMUX_AGENT_INSTALL_DIR=//p' "${ENV_FILE}")
DEFAULT_DIR=$(echo "${DEFAULTS}" | head -1)
[ "$(echo "${DEFAULTS}" | sort -u | wc -l)" -eq 1 ] || fail "the TMUX_AGENT_INSTALL_DIR defaults are missing or disagree (ui-start.sh, ui-status.sh, install-tmux-agent.sh, .env): $(echo ${DEFAULTS})"
case "${DEFAULT_DIR}" in /wd/?*) ;; *) fail "the TMUX_AGENT_INSTALL_DIR default ${DEFAULT_DIR} is not on the /wd volume (the build would not survive a restart)" ;; esac
SCAN_PORT=18215
cat > ${D}/scan-runner.py << 'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
REPOS = []
class H(BaseHTTPRequestHandler):
    def _json(self, obj):
        b = json.dumps(obj).encode(); self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._json({"success": True, "data": REPOS} if self.path == '/api/repos' else {"success": True})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        REPOS.append({"id": str(len(REPOS) + 1), "path": body["path"]}); self._json({"success": True, "data": REPOS[-1]})
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
EOF
( setsid nohup python3 ${D}/scan-runner.py ${SCAN_PORT} > ${D}/scan-runner.log 2>&1 & echo $! > ${D}/scan-runner.pid )
for _ in $(seq 1 40); do curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${SCAN_PORT}/api/health" && break; sleep 0.25; done
# plants a finished install at $2 in the workspace $1 and runs both scans there; true when the starter repository was
# made and the runner does not hold the checkout (STARTER_OUT, RUNNER_LIST say what each did)
scan_workspace()
{
	{ mkdir -p "$2/dist/bin" && git -C "$2" init -q && echo '// planted build' > "$2/dist/bin/tmux-agent.js" \
		&& printf 'ref=planted\nsource=planted\n' > "$2/.install-stamp" \
		&& git -C "$2" -c user.name=test14 -c user.email=test14@localhost commit -q --allow-empty -m planted; } \
		|| fail "could not plant an install at $2"
	STARTER_OUT=$(STARTER_REPO_ROOT="$1" STARTER_REPO=true "${AGENT_DIR}/starter-repo.sh" 2>&1)
	RUNNER_OUT=$(VK_RUNNER_URL=http://127.0.0.1:${SCAN_PORT} VK_REPOS_ROOT="$1" VK_REPOS_WAIT=10 "${AGENT_DIR}/vk-runner-repos.sh" 2>&1) \
		|| fail "vk-runner-repos.sh failed against the stub runner: ${RUNNER_OUT}"
	RUNNER_LIST=$(curl -s --max-time 5 "http://127.0.0.1:${SCAN_PORT}/api/repos" | python3 -c 'import json, sys; [print(r["path"]) for r in json.load(sys.stdin)["data"]]')
	[ -d "$1/projects/scratch/.git" ] && ! printf '%s\n' "${RUNNER_LIST}" | grep -qxF -- "$2"
}
WS=${D}/ws-default
scan_workspace "${WS}" "${WS}/${DEFAULT_DIR#/wd/}" \
	|| fail "a finished install at the default ${DEFAULT_DIR} is taken for the user's repository: starter-repo.sh said '${STARTER_OUT}'; the runner holds [$(echo ${RUNNER_LIST})]"
echo "${STARTER_OUT}" | grep -qF "created ${WS}/projects/scratch" || fail "starter-repo.sh does not say it created the starter repository: ${STARTER_OUT}"
# PLANTED CONTROL: the earlier default /wd/tmux-agent, directly under the workspace - both scans take it for the user's
WS_OLD=${D}/ws-old-default
scan_workspace "${WS_OLD}" "${WS_OLD}/tmux-agent" && fail "PLANTED CONTROL BROKEN: a checkout directly under the workspace passed the scan check"
echo "${STARTER_OUT}" | grep -qF "already holds a repository (${WS_OLD}/tmux-agent)" || fail "PLANTED CONTROL: starter-repo.sh does not name the checkout under the workspace: ${STARTER_OUT}"
printf '%s\n' "${RUNNER_LIST}" | grep -qxF -- "${WS_OLD}/tmux-agent" || fail "PLANTED CONTROL: vk-runner-repos.sh did not register the checkout under the workspace: [$(echo ${RUNNER_LIST})]"
echo "ok 12 - install dir default ${DEFAULT_DIR}: the same in ui-start.sh, ui-status.sh, install-tmux-agent.sh${ENV_FILE:+ and .env}, on the /wd volume, outside both repository scans (starter repository created, checkout not registered); planted control: the earlier /wd/tmux-agent fails both"

# --- 13. the override path, live: only with a reachable TMUX_AGENT_SRC exported by the caller ---
if [ -z "${TMUX_AGENT_SRC}" ]; then
	# reported as SKIPPED, not ok: an optional path that did not run must be visible to a "nothing skipped" check
	echo "skipped 13 - override path not exercised: TMUX_AGENT_SRC not set (optional - the shipped default is the vendored build proven in checks 4-9; export a reachable source to run the installer checks)"
	echo "Test14 succeeded"
	exit 0
fi
if ! command -v git > /dev/null || ! command -v npm > /dev/null; then
	export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
	[ -s "${NVM_DIR}/nvm.sh" ] && \. "${NVM_DIR}/nvm.sh" > /dev/null 2>&1
fi
command -v git > /dev/null && command -v npm > /dev/null || fail "TMUX_AGENT_SRC is set but git/npm are not installed here - the override path cannot be exercised"
SRC_SHOWN=$(mask "${TMUX_AGENT_SRC}")
GIT_TERMINAL_PROMPT=0 git ls-remote -q "${TMUX_AGENT_SRC}" HEAD > /dev/null 2>&1 \
	|| fail "TMUX_AGENT_SRC=${SRC_SHOWN} is set but not reachable from here (unset it to test the vendored default)"
"${AGENT_DIR}/install-tmux-agent.sh" > ${D}/install-1.log 2>&1 || { tail -5 ${D}/install-1.log; fail "install-tmux-agent.sh failed from ${SRC_SHOWN}"; }
DASHBOARD=${TMUX_AGENT_INSTALL_DIR}/dist/bin/tmux-agent.js
[ -f "${DASHBOARD}" ] || fail "install left no ${DASHBOARD}"
[ -n "$(node "${DASHBOARD}" --version 2>/dev/null)" ] || fail "the built dashboard does not run (--version printed nothing)"
[ -z "$(git -C "${TMUX_AGENT_INSTALL_DIR}" remote)" ] || fail "the checkout records a remote (a token URL would land in .git/config)"
STAMP=${TMUX_AGENT_INSTALL_DIR}/.install-stamp
grep -qxF "ref=${TMUX_AGENT_REF:-master}" "${STAMP}" 2>/dev/null || fail "the install stamp does not name the ref built: $(cat "${STAMP}" 2>&1)"
grep -qxF "commit=$(git -C "${TMUX_AGENT_INSTALL_DIR}" rev-parse HEAD)" "${STAMP}" || fail "the install stamp does not name the commit built: $(cat "${STAMP}")"
"${AGENT_DIR}/install-tmux-agent.sh" > ${D}/install-2.log 2>&1 || { tail -5 ${D}/install-2.log; fail "second install run failed (not idempotent)"; }
CRED_URL="https://x-access-token:${TOKEN}@127.0.0.1:9/nobody/tmux-agent.git"
ROTATED_URL="https://x-access-token:${TOKEN}rotated@127.0.0.1:9/nobody/tmux-agent.git"
CRED_DIR=${D}/tmux-agent-cred
git_redirect()
{
	# git_redirect <cmd...> - run with both credential URLs rewritten by git to the reachable source
	GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0="url.${TMUX_AGENT_SRC}.insteadOf" GIT_CONFIG_VALUE_0="${CRED_URL}" \
		GIT_CONFIG_KEY_1="url.${TMUX_AGENT_SRC}.insteadOf" GIT_CONFIG_VALUE_1="${ROTATED_URL}" "$@"
}
git_redirect env TMUX_AGENT_SRC="${CRED_URL}" TMUX_AGENT_INSTALL_DIR=${CRED_DIR} "${AGENT_DIR}/install-tmux-agent.sh" \
	> ${D}/install-cred.log 2>&1 || { tail -5 ${D}/install-cred.log; fail "install from a credential URL (resolved to ${SRC_SHOWN}) failed"; }
grep -q "${TOKEN}" ${D}/install-cred.log ${CRED_DIR}/.install-stamp && fail "TOKEN LEAK: the credential reached the install output or the stamp"
# the ref may be the pinned commit itself (the .env default); that one line is the commit, not a leaked value
STAMP_COMMIT=$(grep '^commit=' ${CRED_DIR}/.install-stamp | cut -d= -f2)
grep -v '^commit=' ${CRED_DIR}/.install-stamp | grep -vxF "ref=${STAMP_COMMIT}" | grep -qE '[0-9a-f]{32,}' && fail "the stamp carries a hash-like value besides the commit: $(cat ${CRED_DIR}/.install-stamp)"
grep -qxF "source=$(mask "${CRED_URL}")" ${CRED_DIR}/.install-stamp || fail "the stamp does not name the masked source: $(cat ${CRED_DIR}/.install-stamp)"
TMUX_AGENT_SRC="${ROTATED_URL}" TMUX_AGENT_INSTALL_DIR=${CRED_DIR} "${AGENT_DIR}/ui-status.sh" 2>&1 | grep -qF "not installed at ${CRED_DIR}" \
	&& fail "ui-status.sh reads a rotated token as another source (not installed)"
TMUX_AGENT_SRC=/elsewhere TMUX_AGENT_INSTALL_DIR=${CRED_DIR} "${AGENT_DIR}/ui-status.sh" 2>&1 | grep -qF "not installed at ${CRED_DIR}" \
	|| fail "ui-status.sh counts a stamp for another source as an install"
# served from that build, not re-installed
"${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-src.log 2>&1 || { cat ${D}/ui-start-src.log; fail "ui-start.sh (TMUX_AGENT_SRC set)"; }
grep -q "installing" ${D}/ui-start-src.log && fail "ui-start.sh re-installed although the stamp matches: $(cat ${D}/ui-start-src.log)"
PID=$(cat ${UI_DIR}/tmux-agent.pid 2>/dev/null)
tr '\0' ' ' < /proc/${PID}/cmdline 2>/dev/null | grep -q "${DASHBOARD} web" || fail "pid ${PID} is not the dashboard built from the source"
tr '\0' '\n' < /proc/${PID}/environ 2>/dev/null | grep -q '^TMUX_AGENT_SRC=' && fail "the dashboard inherited TMUX_AGENT_SRC (it may carry a token; only the installer needs it)"
wait_up || { tail -5 ${UI_DIR}/tmux-agent.log; fail "the dashboard built from the source is not served"; }
"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
INSTALL_LOG=${UI_DIR}/tmux-agent-install.log
installs() { grep -c '^=== .* install-tmux-agent.sh ===$' "${INSTALL_LOG}" 2>/dev/null || true; }
# a changed TMUX_AGENT_REF naming the same commit is re-installed on the next start: the full sha when the
# stamp's ref is a name; the source's default branch when the stamp's ref is already that sha (the .env default)
SHA=$(git -C "${TMUX_AGENT_INSTALL_DIR}" rev-parse HEAD)
if grep -qxF "ref=${SHA}" "${STAMP}"; then
	NEW_REF=$(GIT_TERMINAL_PROMPT=0 git ls-remote --symref -q "${TMUX_AGENT_SRC}" HEAD 2>/dev/null \
		| sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p' | head -1)
	[ -n "${NEW_REF}" ] || fail "cannot learn the default branch of ${SRC_SHOWN} (git ls-remote --symref HEAD) for the changed-ref check"
else
	NEW_REF=${SHA}
fi
N0=$(installs)
( export TMUX_AGENT_REF=${NEW_REF}; "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-ref.log 2>&1 ) || { cat ${D}/ui-start-ref.log; fail "ui-start.sh (TMUX_AGENT_REF=${NEW_REF})"; }
N1=$(installs)
[ "${N1:-0}" -eq $(( ${N0:-0} + 1 )) ] || fail "a changed TMUX_AGENT_REF (${NEW_REF}) was not re-installed (installs ${N0:-0} -> ${N1:-0}): $(cat ${D}/ui-start-ref.log)"
grep -qxF "ref=${NEW_REF}" "${STAMP}" || fail "the stamp does not name the new ref after the re-install: $(cat "${STAMP}" 2>&1)"
wait_up || { tail -5 ${INSTALL_LOG}; fail "the re-installed dashboard is not served"; }
"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
# planted control: a build that fails type-checking (tsc still emits dist/) is never served
BROKEN=${D}/src-broken
BROKEN_DIR=${D}/tmux-agent-broken
{ git init -q "${BROKEN}" && git -C "${BROKEN}" fetch -q --no-tags -- "${TMUX_AGENT_INSTALL_DIR}" HEAD \
	&& git -C "${BROKEN}" checkout -q -b planted-type-error FETCH_HEAD \
	&& echo 'const plantedTypeError: number = "not a number";' >> "${BROKEN}/src/bin/tmux-agent.ts" \
	&& git -C "${BROKEN}" -c user.name=test14 -c user.email=test14@localhost commit -qam "planted type error"; } \
	|| fail "could not plant the broken source at ${BROKEN}"
( export TMUX_AGENT_SRC=${BROKEN} TMUX_AGENT_REF=planted-type-error TMUX_AGENT_INSTALL_DIR=${BROKEN_DIR}
  "${AGENT_DIR}/ui-start.sh" > ${D}/ui-start-broken.log 2>&1 )
grep -q "npm run build failed" "${INSTALL_LOG}" || fail "planted control: the type error did not fail the build: $(tail -3 "${INSTALL_LOG}")"
[ -f "${BROKEN_DIR}/dist/bin/tmux-agent.js" ] || fail "planted control is vacuous: the failing build emitted no dist/bin/tmux-agent.js"
[ -f ${UI_DIR}/tmux-agent.pid ] && fail "a failed install left a running dashboard (pid $(cat ${UI_DIR}/tmux-agent.pid))"
[ -f "${BROKEN_DIR}/.install-stamp" ] && fail "a failed install left a stamp"
grep -q "tmux-agent: not started - install failed" ${D}/ui-start-broken.log || fail "ui-start.sh does not say the failed install was not started: $(cat ${D}/ui-start-broken.log)"
echo "ok 13 - override path from ${SRC_SHOWN}: built, no remote, stamp, idempotent, credential masked, rotation same source, served, ref change re-installed, type error never served"

echo "Test14 succeeded"
