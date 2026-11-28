#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of ./stop.sh (run by test.sh like test-run.sh): stop.sh, .env, .fun, kanban.sh, docker.sh and plane.sh are
# copied into ./scratch/test-stop (gitignored) with a planted .env.local (its own container name) and stubs of docker,
# docker-compose, kubectl and sbx on PATH that record every word they get and answer as the checks plant: every container,
# network and volume asked about exists, runs and carries this harness's label, so each down script removes what it would
# remove. No real docker command runs, and nothing of the checkout is read for a setting or written.
# Each check FAILS if the property is removed:
#   1. no argument, the docker target (the default, as it was): the session ledger's record-stop exec in the agent
#      container, then docker container rm -f -v <agent>, then the three down scripts in order - ./kanban.sh down,
#      ./docker.sh down, ./plane.sh down - each reached (the real scripts against the stub: the board's four sidecars and
#      its two networks, the substrate's two containers and two networks, the Plane board's containers and two networks
#      removed, every removal after the agent container's); exit 0
#   2. -s: the record-stop exec and the agent container's rm -f -v, and nothing else - no other container rm, no network rm,
#      no ps of the sidecars, none of the three down scripts' lines - one line saying what keeps running, exit 0; --single
#      is -s
#   3. an argument that is neither (PLANTED: -x, and a word): refused by name with the usage line, exit 2, no docker command
#      run and .env not read (PLANTED: a .env.local line that creates a file when .env is read; the default run creates it,
#      the refused run does not); -h and --help print the usage and exit 0, nothing run
#   4. TO=kubernetes, TO=swarm and TO=sandbox with -s: refused by name (the flag applies to the docker and compose targets),
#      exit 2, no kubectl, docker or sbx command run; without the flag each target's one command runs as before
#   5. TO=compose: no argument is docker-compose -f <file> [-f <overlay>...] down as before, the board's overlay files
#      added when they exist; -s stops and removes the agent service alone (rm -s -f -v <service>) with the same -f files,
#      so compose resolves the same project, and no down; its one line names the services, not the docker target's sidecars
# Uses ./scratch/test-stop (gitignored) for the copy, the stubs and the outputs.

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
D=${BASE_DIR}/scratch/test-stop
rm -rf "${D:?}"
mkdir -p "${D}/copy" "${D}/bin"

fail()
{
	echo "Test-stop FAILED: $1"
	exit 1
}

cp "${BASE_DIR}/stop.sh" "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${BASE_DIR}/kanban.sh" "${BASE_DIR}/docker.sh" "${BASE_DIR}/plane.sh" "${D}/copy/" \
	|| fail "could not copy stop.sh and the scripts it runs"
cat > "${D}/bin/docker" << 'STUB'
#!/bin/bash
# test-stop.sh's docker: every call is a line of ${STUB_CALLS}, "docker" and each word followed by "|"; every container,
# network and volume asked about exists, runs and carries this harness's label (${STUB_OWNER}); ps lists the names in
# ${STUB_PS}, one a line, so each down script removes what it would remove
printf '%s|' docker "$@" >> "${STUB_CALLS}"; echo >> "${STUB_CALLS}"
case "$1 $2" in
	"container inspect"|"network inspect"|"volume inspect")
		if [ "$3" == "-f" ]; then
			case "$4" in *Labels*) echo "${STUB_OWNER}" ;; *Running*) echo true ;; *Internal*) echo true ;; *ExitCode*) echo "running 0" ;; esac
		fi
		exit 0
		;;
	"ps "*) [ -n "${STUB_PS}" ] && printf '%s\n' ${STUB_PS}; exit 0 ;;
esac
exit 0
STUB
for T in docker-compose kubectl sbx; do
	# the other tools stop.sh runs, each recording its words the same way and answering 0
	printf '#!/bin/bash\nprintf '"'"'%%s|'"'"' %s "$@" >> "${STUB_CALLS}"; echo >> "${STUB_CALLS}"\nexit 0\n' "${T}" > "${D}/bin/${T}"
done
chmod +x "${D}/bin/docker" "${D}/bin/docker-compose" "${D}/bin/kubectl" "${D}/bin/sbx"

# local_env [<line>...] - the copy's .env.local: the test's container name, then the lines given
local_env()
{
	{ echo "export CONTAINER=test-stop-agent"; printf '%s\n' "$@"; } > "${D}/copy/.env.local"
}
# stop [NAME=value...] [-- <stop.sh arguments>] - ./stop.sh in the copy with the stubs on PATH and those variables; its output
# in ${D}/stop.out, every stub call in ${D}/calls (one line each: the tool and each word followed by "|"); prints stop.sh's
# exit status
stop()
{
	local VARS=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do VARS+=("$1"); shift; done
	[ "$1" == "--" ] && shift
	rm -f "${D:?}/calls"
	( cd "${D}/copy" && env PATH="${D}/bin:${PATH}" STUB_CALLS="${D}/calls" STUB_OWNER=test-stop-agent "${VARS[@]}" ./stop.sh "$@" ) > "${D}/stop.out" 2>&1
	echo $?
}
calls() { [ -f "${D}/calls" ] && cat "${D}/calls"; }
out() { tail -3 "${D}/stop.out" | cut -c1-300 | tr '\n' ' '; }
# line_of <call> - the line number of that exact call in the recorded calls (empty when it was not made)
line_of() { calls | grep -nxF -- "$1" | head -1 | cut -d: -f1; }
LEDGER="docker|container|exec|test-stop-agent|/agent/supervisor.sh|record-stop|"
AGENT_RM="docker|container|rm|-f|-v|test-stop-agent|"

# --- 1. no argument, the docker target: the agent container, then the three down scripts ---
local_env 'touch planted-env-read'
rm -f "${D:?}/copy/planted-env-read"
RC=$(stop STUB_PS="test-stop-agent-plane-proxy test-stop-agent-plane-api")
[ "${RC}" == "0" ] || fail "1: stop.sh exited ${RC} (expected 0): $(out)"
[ -e "${D}/copy/planted-env-read" ] || fail "1: the planted .env.local line did not run, so .env was not read (the control for check 3)"
[ "$(calls | sed -n '1,2p' | tr '\n' ' ')" == "${LEDGER} ${AGENT_RM} " ] \
	|| fail "1: the first two docker calls are not the ledger's record-stop exec then the agent container's rm -f -v: $(calls | head -2 | tr '\n' ' ')"
AGENT_LINE=$(line_of "${AGENT_RM}")
# each down script's removals, after the agent container's, in the scripts' order
LAST=${AGENT_LINE}
for GROUP in "kanban:docker|container|rm|-f|-v|test-stop-agent-kanban-relay| docker|container|rm|-f|-v|test-stop-agent-kanban-server| docker|container|rm|-f|-v|test-stop-agent-kanban-electric| docker|container|rm|-f|-v|test-stop-agent-kanban-db| docker|network|rm|test-stop-agent-kanban| docker|network|rm|test-stop-agent-kanban-internal|" \
	"docker:docker|container|rm|-f|-v|test-stop-agent-buildkit| docker|container|rm|-f|-v|test-stop-agent-registry| docker|network|rm|test-stop-agent-docker| docker|network|rm|test-stop-agent-docker-build|" \
	"plane:docker|container|rm|-f|-v|test-stop-agent-plane-proxy| docker|container|rm|-f|-v|test-stop-agent-plane-api| docker|network|rm|test-stop-agent-plane| docker|network|rm|test-stop-agent-plane-internal|"; do
	WHO=${GROUP%%:*}
	for CALL in ${GROUP#*:}; do
		N=$(line_of "${CALL}")
		[ -n "${N}" ] || fail "1: ./${WHO}.sh down did not remove ${CALL} (not in the docker calls): $(calls | grep -E 'rm' | tr '\n' ' ' | cut -c1-400)"
		[ "${N}" -gt "${LAST}" ] || fail "1: ${CALL} (line ${N}) came before the removals it must follow (line ${LAST})"
	done
	LAST=${N}
done
for L in "kanban: removed test-stop-agent-kanban-server" "docker: removed test-stop-agent-buildkit" "plane: removed test-stop-agent-plane-api"; do
	grep -qxF "${L}" "${D}/stop.out" || fail "1: no '${L}' line in stop.sh's output: $(out)"
done
echo "ok 1 - no argument, the docker target: the ledger's record-stop exec, the agent container's rm -f -v, then ./kanban.sh down, ./docker.sh down and ./plane.sh down each remove their containers and networks, in that order, exit 0"

# --- 2. -s: the agent container alone ---
SINGLE_LINE="stop.sh: -s - removing the agent container alone; the kanban board, the docker spoke's build substrate and the Plane board, whichever run, keep running (./stop.sh without -s removes them)"
SINGLE_LINE_COMPOSE="stop.sh: -s - removing the agent service alone; the board's services keep running (./stop.sh without -s removes every service)"
for FLAG in -s --single; do
	RC=$(stop STUB_PS="test-stop-agent-plane-proxy test-stop-agent-plane-api" -- "${FLAG}")
	[ "${RC}" == "0" ] || fail "2: stop.sh ${FLAG} exited ${RC} (expected 0): $(out)"
	[ "$(calls | tr '\n' ' ')" == "${LEDGER} ${AGENT_RM} " ] \
		|| fail "2: stop.sh ${FLAG} ran more or other than the record-stop exec and the agent container's rm -f -v: $(calls | tr '\n' ' ' | cut -c1-400)"
	grep -qE '^(kanban|docker|plane): ' "${D}/stop.out" && fail "2: a down script printed with ${FLAG}: $(grep -E '^(kanban|docker|plane): ' "${D}/stop.out" | head -2 | tr '\n' ' ')"
	grep -qxF "${SINGLE_LINE}" "${D}/stop.out" || fail "2: stop.sh ${FLAG} does not say what keeps running: $(out)"
done
echo "ok 2 - -s and --single: the record-stop exec and docker container rm -f -v <agent> and nothing else (no other rm, no network rm, no down script), one line saying what keeps running, exit 0"

# --- 3. an argument that is neither: refused, nothing run, .env not read ---
local_env 'touch planted-env-read'
for BAD in -x stop; do
	rm -f "${D:?}/copy/planted-env-read"
	RC=$(stop -- "${BAD}")
	[ "${RC}" == "2" ] || fail "3: stop.sh exited ${RC} on the argument '${BAD}' (expected 2): $(out)"
	grep -qF "stop.sh: unknown argument '${BAD}'" "${D}/stop.out" || fail "3: the refused argument '${BAD}' is not named: $(out)"
	grep -qF "Usage: ./stop.sh [-s|--single]" "${D}/stop.out" || fail "3: no usage line for the argument '${BAD}': $(out)"
	[ -e "${D}/calls" ] && fail "3: a command ran although the argument '${BAD}' was refused: $(calls | tr '\n' ' ')"
	[ -e "${D}/copy/planted-env-read" ] && fail "3: .env was read although the argument '${BAD}' was refused (the planted .env.local line ran)"
done
for H in -h --help; do
	RC=$(stop -- "${H}")
	[ "${RC}" == "0" ] || fail "3: stop.sh ${H} exited ${RC} (expected 0): $(out)"
	grep -qF "Usage: ./stop.sh [-s|--single]" "${D}/stop.out" || fail "3: ${H} prints no usage line: $(out)"
	[ -e "${D}/calls" ] && fail "3: a command ran on ${H}: $(calls | tr '\n' ' ')"
done
echo "ok 3 - an argument that is neither -s nor --single is refused by name with the usage line, exit 2, nothing run and .env not read; -h and --help print the usage, exit 0"

# --- 4. the other targets: -s refused by name; without it each target's command as before ---
for T in "kubernetes:kubectl|delete|-f|./to/kubernetes/app|" "swarm:docker|stack|rm|mystack|" "sandbox:sbx|rm|--force|do-agent-aws|"; do
	TO=${T%%:*}
	# the target from .env.local, as a person sets it (.env's export TO= wins over the environment)
	local_env "export TO=${TO}"
	RC=$(stop -- -s)
	[ "${RC}" == "2" ] || fail "4: stop.sh -s exited ${RC} with TO=${TO} (expected 2): $(out)"
	grep -qF "stop.sh: -s/--single applies to the docker and compose targets, not TO=${TO}" "${D}/stop.out" || fail "4: TO=${TO} with -s is not refused by name: $(out)"
	[ -e "${D}/calls" ] && fail "4: a command ran on TO=${TO} with -s: $(calls | tr '\n' ' ')"
	RC=$(stop)
	[ "${RC}" == "0" ] || fail "4: stop.sh exited ${RC} with TO=${TO} and no argument (expected 0): $(out)"
	[ "$(calls | tr '\n' ' ')" == "${T#*:} " ] || fail "4: TO=${TO} without the flag did not run exactly ${T#*:}: $(calls | tr '\n' ' ')"
done
echo "ok 4 - TO=kubernetes, swarm and sandbox: -s is refused by name (exit 2, nothing run); without it each target runs its one command as before"

# --- 5. the compose target: down as before; -s removes the agent service alone ---
local_env 'export TO=compose'
RC=$(stop)
[ "${RC}" == "0" ] || fail "5: stop.sh exited ${RC} on the compose target (expected 0): $(out)"
[ "$(calls | tr '\n' ' ')" == "docker-compose|-f|./to/compose/app/docker-compose.yaml|down| " ] || fail "5: the compose target's default is not docker-compose -f <file> down: $(calls | tr '\n' ' ')"
# the board's overlays, rendered by an earlier ./run.sh (PLANTED: both files)
mkdir -p "${D}/copy/to/compose/app" && : > "${D}/copy/to/compose/app/docker-compose.kanban.yaml" && : > "${D}/copy/to/compose/app/docker-compose.kanban-relay.yaml" \
	|| fail "5: could not plant the overlay files"
OVERLAYS="-f|./to/compose/app/docker-compose.yaml|-f|./to/compose/app/docker-compose.kanban.yaml|-f|./to/compose/app/docker-compose.kanban-relay.yaml|"
RC=$(stop)
[ "${RC}" == "0" ] || fail "5: stop.sh exited ${RC} on the compose target with the overlays (expected 0): $(out)"
[ "$(calls | tr '\n' ' ')" == "docker-compose|${OVERLAYS}down| " ] || fail "5: the compose down does not carry the two overlay files: $(calls | tr '\n' ' ')"
for FLAG in -s --single; do
	RC=$(stop -- "${FLAG}")
	[ "${RC}" == "0" ] || fail "5: stop.sh ${FLAG} exited ${RC} on the compose target (expected 0): $(out)"
	[ "$(calls | tr '\n' ' ')" == "docker-compose|${OVERLAYS}rm|-s|-f|-v|test-stop-agent| " ] \
		|| fail "5: stop.sh ${FLAG} on the compose target is not docker-compose <the same -f files> rm -s -f -v <the agent service>: $(calls | tr '\n' ' ')"
	grep -qxF "${SINGLE_LINE_COMPOSE}" "${D}/stop.out" || fail "5: stop.sh ${FLAG} on the compose target does not say what keeps running: $(out)"
done
echo "ok 5 - the compose target: docker-compose -f <file> [-f <overlay>...] down as before; -s and --single run rm -s -f -v <the agent service> with the same -f files and no down"

echo "Test-stop succeeded"
