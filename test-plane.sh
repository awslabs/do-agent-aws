#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side tests of the self-hosted Plane board (docs/manual/boards.md "Plane board"). Like test-exec.sh they run on the HOST,
# not in the in-container /test*.sh suite: the board's services are sidecar containers that test.sh's throwaway
# container has no access to.
#   ./test-plane.sh dry  - the commands a fresh host runs, without docker: plane.sh and run.sh are copied into a
#                          scratch folder whose .env forces DRY_RUN=true, VERBOSE=true and UI_PLANE=true (the board is
#                          off by default, docs/manual/boards.md "Plane board": this test turns it on in its copy; the variables are
#                          exported inside .env, so the copy must be edited - the test-exec.sh method) and docker is a
#                          stub on PATH; test.sh always runs it, so the Plane path stays tested while off by default
#   ./test-plane.sh live - with ./run.sh up: the board through the home port's plane.localhost route
#   ./test-plane.sh lifecycle - a real docker start and stop of one board container under a CONTAINER of the test's
#                          own (no stack uses it, so the copy's ./stop.sh removes nothing else); test.sh runs it
# Each check FAILS if the property is removed:
#   dry 1. ./plane.sh up starts the 12 services and the one-shot migrator, each with docker container run
#   dry 2. no sidecar command publishes a port (-p, --publish, -P, --publish-all) or uses the host's network
#   dry 3. every sidecar carries the harness label do-agent-aws.plane=<CONTAINER> and joins PLANE_INTERNAL_NETWORK;
#          only the proxy also joins PLANE_NETWORK, the network the agent joins
#   dry 4. no value of plane.env (planted ones) is on any command line: the services get them through --env-file
#   dry 5. ./run.sh's agent command joins PLANE_NETWORK with PLANE_URL, and its only published port is the
#          loopback home port
#   dry 6. the two paths that handle secrets outside DRY_RUN keep them off every command line: plane.sh's redact
#          (the filter on the container logs it shows or keeps) masks every value, sed's special characters
#          included, and while it runs no process's /proc/<pid>/cmdline holds one - the control: the same scan sees
#          the values while the former filter (one sed -e per value) runs, so a blind scan cannot pass; and the
#          database and queue passwords reach psql and rabbitmqctl on stdin only (a recording docker stub), the
#          stdin-reading rabbitmqctl calls without -q (with it the 3.13 CLI waits for the password forever).
#          6c: DEBUG=true (set -x) traces plane.sh but never a secret: init (generating three of the passwords) and
#          seed (a docker stub answers the api) print no plane.env value although the trace is on, and redact and
#          apply_datastore_passwords under set -x trace none
#   dry 7. nothing on the board can phone home: the services' network is created --internal (no egress; the agent's
#          network is not), and app.env - rendered by ./plane.sh init in the copy, which starts nothing - points
#          Plane's metrics exporter (OTLP_ENDPOINT, default https://telemetry.plane.so) at loopback
#   dry 8. the host needs no python3: the whole dry run again on a PATH with every tool but python says so, skips
#          only plane/seed.py's parse check (which needs python3) and passes. live needs python3 and says so
#   dry 9. a migrator whose docker container wait outlives PLANE_MIGRATE_TIMEOUT (a stalling daemon; a docker stub
#          whose wait hangs) is judged by its own state: exited 0 passes and says so, still running does not, and a
#          wait that answers passes as before
#   dry 10. a person's settings reach the copy: the dry run of a scratch checkout whose .env.local alone sets
#           CONTAINER passes, with that container's names; that .env.local's DRY_RUN=false (.env's own value, as in a
#           whole copy of .env) does not end the copy's dry run, and its PLANE_DIR outside the checkout gets nothing
#   live 1. the SERVED /api/instances/, fetched through the home port with Host plane.localhost, says
#           is_setup_done true - the value Plane's web app gates the whole app on (a 302 sign-in proves nothing
#           about it)
#   live 2. the agent's API key from plane.env reads the workspace's projects through the same route (X-Api-Key):
#           200 and the project PLANE_PROJECT_IDENTIFIER is there
#   live 3. the Plane tile's one-click sign-in (a link click on the home page: its Referer is the home page on the
#           home port) answers 302 to that project's board with a session cookie, and the cookie reads
#           /api/users/me/ (200): the session is real. Without that Referer, or with another site's, it answers
#           403 with no cookie (no login CSRF)
#   live 4. a non-loopback Host never signs in: through the home port the sign-in URL with a rebinding-style Host
#           gets no session cookie (no route), and the sign-in helper itself, asked directly in the container
#           with such a Host (and a Referer that passes the home-page check), answers 403
#   live 5. no Plane sidecar publishes a host port, and the home port is published on 127.0.0.1 only
#   live 6. no board container but its proxy can reach the agent: PLANE_NETWORK holds the agent and the proxy only,
#           and from the api container none of the agent's ports (every PORT_INTERNAL_*: the terminal, the home
#           proxy, the UIs) opens, by name or by its address - while the same probe opens the board's proxy (the
#           control: a blind probe cannot pass)
#   live 7. nothing phoned home: the worker's metrics exporter was configured only with loopback endpoints and no
#           push to any other endpoint is logged (the api queues one at every start, before the seed turns telemetry
#           off - check right after a fresh start); the api container cannot open a connection to api.github.com,
#           which the agent container can (the control, when this host has egress at all), and the api's GitHub
#           release check fell back
#   lifecycle 1. ./stop.sh takes a board container's anonymous volumes with it and leaves its named ones: the minio
#           image (its VOLUME /data is none of the board's named volumes) started as plane.sh starts it - its label,
#           its name, the named uploads volume at /export - then the copy's ./stop.sh; the volumes docker volume ls
#           lists after the stop and not before the start hold none of the container's anonymous volumes and do hold
#           the named one. PLANTED (the red): the former stop.sh, rm without -v, left exactly the one anonymous volume.
#           The mode FAILS when the image is not on the host: no check ran, and test.sh must not count that as a pass
# Prints "Test-plane-<dry|live|lifecycle> PASSED" or "... FAILED: <reason>" and exits 0 or 1. Never prints a secret: the
# password and the API key go to curl in mode-600 files, and responses are kept in a mode-600 scratch folder.

source .env

NAME=$1
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
D=$(mktemp -d)
chmod 700 "${D}"
trap 'rm -rf "${D:?}"' EXIT

fail()
{
	echo "Test-plane-${NAME} FAILED: $1"
	exit 1
}

dry()
{
	bash -n "${BASE_DIR}/plane.sh" || fail "bash -n plane.sh"
	# the host needs no python3 (README: Docker, git and AWS credentials); where there is one, seed.py must parse
	if command -v python3 > /dev/null 2>&1; then
		python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "${BASE_DIR}/plane/seed.py" 2> "${D}/seed-parse.err" \
			|| fail "plane/seed.py does not parse: $(tail -1 "${D}/seed-parse.err")"
	else
		echo "   no python3 on this host: plane/seed.py's parse check is skipped (./run.sh runs it in the board's api container and checks its result)"
	fi
	mkdir -p "${D}/copy/plane" "${D}/copy/wd/plane" "${D}/stub-bin"
	# the checkout's files ./plane.sh and ./run.sh read or run: .env (it reads .fun, and .env.local below), and run.sh's
	# env-local.sh (run when present), preflight.sh (sourced before a docker or compose start), kanban.sh (the board) and
	# docker.sh (the docker spoke's build substrate)
	cp "${BASE_DIR}/plane.sh" "${BASE_DIR}/run.sh" "${BASE_DIR}/env-local.sh" "${BASE_DIR}/preflight.sh" "${BASE_DIR}/kanban.sh" \
		"${BASE_DIR}/docker.sh" "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${D}/copy/"
	cp "${BASE_DIR}/plane/seed.py" "${D}/copy/plane/"
	sed -i -e 's/^export DRY_RUN=.*/export DRY_RUN=true/' -e 's/^export VERBOSE=.*/export VERBOSE=true/' \
		-e 's/^export TO=.*/export TO=docker/' -e 's/^export UI_PLANE=.*/export UI_PLANE=true/' \
		-e 's/^export UI_START=.*/export UI_START=true/' "${D}/copy/.env"
	# a person's settings, .env.local beside .env (docs/manual/install.md "Settings"): this test read them with .env, so the copy
	# gets them too and renders the names the checks expect (CONTAINER=x: x-plane-*). Left out: the names the copy's
	# .env sets for this test (DRY_RUN, VERBOSE, TO, DEBUG, UI_PLANE, UI_START), which .env.local would replace; PLANE_DIR, so
	# the board files the copy's init writes stay in the copy; and NETWORK, since a host or none network starts the agent
	# without the board (run.sh), which dry 5 would then fail on a host setting, not on the code
	if [ -f "${BASE_DIR}/.env.local" ]; then
		sed -E '/^[[:space:]]*(export[[:space:]]+)?(DRY_RUN|VERBOSE|TO|DEBUG|PLANE_DIR|UI_PLANE|UI_START|NETWORK)=/d' "${BASE_DIR}/.env.local" > "${D}/copy/.env.local"
	fi
	# the board's derived settings as the copy sees them, with UI_PLANE=true there: the checkout's .env sourced above leaves
	# PLANE_URL and PLANE_RUN_OPTS empty under the shipped default UI_PLANE=false (the checks below expect the copy's values)
	eval "$(cd "${D}/copy" && bash -c 'source .env > /dev/null 2>&1; printf "PLANE_URL=%q\nPLANE_NETWORK=%q\nPLANE_INTERNAL_NETWORK=%q\n" "${PLANE_URL}" "${PLANE_NETWORK}" "${PLANE_INTERNAL_NETWORK}"')"
	[ -n "${PLANE_URL}" ] || fail "the copy's .env leaves PLANE_URL empty although the copy sets UI_PLANE=true"
	# planted secrets: none of them may reach a command line
	PLANTED="planted-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	cat > "${D}/copy/wd/plane/plane.env" << EOF
PLANE_ADMIN_EMAIL=agent@do-agent-aws.local
PLANE_ADMIN_PASSWORD=${PLANTED}-password
PLANE_API_KEY=plane_api_${PLANTED}-key
PLANE_SECRET_KEY=${PLANTED}-secret
PLANE_LIVE_SERVER_SECRET_KEY=${PLANTED}-live
PLANE_DB_PASSWORD=${PLANTED}-db
PLANE_MQ_PASSWORD=${PLANTED}-mq
PLANE_MINIO_SECRET_KEY=${PLANTED}-s3
EOF
	# a docker that knows nothing (every inspect fails) and records every call; only docker info answers, as where docker
	# is usable: ./run.sh's preflight (preflight.sh) stops before the agent's docker run when it does not
	cat > "${D}/stub-bin/docker" << EOF
#!/bin/bash
echo "\$*" >> "${D}/docker-calls.log"
[ "\$1" == "info" ] && exit 0
exit 1
EOF
	chmod +x "${D}/stub-bin/docker"
	( cd "${D}/copy" && PATH="${D}/stub-bin:${PATH}" ./plane.sh up ) > "${D}/plane-up.out" 2>&1
	RUNS=$(grep -E '^docker container run ' "${D}/plane-up.out")
	N=$(echo "${RUNS}" | grep -c .)
	for S in db redis mq minio migrator api worker beat-worker web space admin live proxy; do
		echo "${RUNS}" | grep -qE -- "--name ${PLANE_NAME}-${S} " || fail "no docker container run for ${PLANE_NAME}-${S}: $(head -5 "${D}/plane-up.out")"
	done
	[ "${N}" -eq 13 ] || fail "${N} docker container run commands, not 13"
	echo "ok 1 - ./plane.sh up starts the 12 services and the migrator (13 docker container run commands)"
	if echo "${RUNS}" | grep -qE -- '(^| )(-p|--publish|-P|--publish-all)( |=|$)|--net(work)?[ =]host( |$)'; then
		fail "a sidecar publishes a port or uses the host network: $(echo "${RUNS}" | grep -E -- '(^| )(-p|--publish|-P|--publish-all)( |=|$)|--net(work)?[ =]host' | head -1 | cut -c1-200)"
	fi
	echo "ok 2 - no sidecar publishes a port or uses the host network"
	[ "$(echo "${RUNS}" | grep -cF -- "--label do-agent-aws.plane=${CONTAINER} ")" -eq 13 ] || fail "a sidecar lacks the label do-agent-aws.plane=${CONTAINER}"
	[ "$(echo "${RUNS}" | grep -cF -- "--network ${PLANE_INTERNAL_NETWORK} ")" -eq 13 ] || fail "a sidecar is not on ${PLANE_INTERNAL_NETWORK}"
	EDGE=$(echo "${RUNS}" | grep -E -- "--network (name=)?${PLANE_NETWORK}[ ,]")
	{ [ "$(echo "${EDGE}" | grep -c .)" -eq 1 ] && echo "${EDGE}" | grep -qF -- "--name ${PLANE_NAME}-proxy "; } \
		|| fail "not only the proxy joins the agent's network ${PLANE_NETWORK}: $(echo "${EDGE}" | grep -oE -- '--name [^ ]+' | tr '\n' ' ')"
	echo "ok 3 - every sidecar carries do-agent-aws.plane=${CONTAINER} and joins ${PLANE_INTERNAL_NETWORK}; only the proxy also joins ${PLANE_NETWORK}"
	grep -qF -- "${PLANTED}" "${D}/plane-up.out" "${D}/docker-calls.log" && fail "a plane.env value reached a command line or the output"
	echo "${RUNS}" | grep -qF -- "--env-file ${D}/copy/wd/plane/app.env" || fail "the api's settings do not come from an --env-file"
	echo "ok 4 - no plane.env value on any command line (the services read --env-file files)"
	( cd "${D}/copy" && PATH="${D}/stub-bin:${PATH}" ./run.sh ) > "${D}/run.out" 2>&1
	AGENT=$(grep -E '^docker container run .*'"${REGISTRY}${IMAGE}${TAG}"'( |$)' "${D}/run.out" | tail -1)
	[ -n "${AGENT}" ] || fail "./run.sh printed no agent docker run command"
	echo "${AGENT}" | grep -qF -- "--network ${PLANE_NETWORK} " || fail "the agent does not join ${PLANE_NETWORK}"
	echo "${AGENT}" | grep -qF -- "-e PLANE_URL=${PLANE_URL} " || fail "the agent does not get PLANE_URL"
	PUBLISHED=$(echo "${AGENT}" | grep -oE -- '(^| )-p [^ ]+' | sed 's/^ //')
	[ "${PUBLISHED}" == "-p ${UI_BIND_HOST}:${PORT_EXTERNAL_HOME}:${PORT_INTERNAL_HOME}" ] \
		|| fail "the agent publishes [${PUBLISHED//$'\n'/ }], not only the loopback home port"
	echo "ok 5 - ./run.sh: the agent joins ${PLANE_NETWORK} with PLANE_URL; its one published port is ${UI_BIND_HOST}:${PORT_EXTERNAL_HOME}"
	# 6. in a subshell: it defines plane.sh's functions and a docker stub function
	( secrets_paths ) || exit 1
	# 6c. DEBUG=true: init generates the three datastore passwords again, seed runs against a stub api
	sed -i -e '/^PLANE_DB_PASSWORD=/d' -e '/^PLANE_MQ_PASSWORD=/d' -e '/^PLANE_MINIO_SECRET_KEY=/d' "${D}/copy/wd/plane/plane.env"
	sed -i -e 's/^export DRY_RUN=.*/export DRY_RUN=false/' -e 's/^export DEBUG=.*/export DEBUG=true/' "${D}/copy/.env"
	mkdir -p "${D}/stub6c-bin"
	cat > "${D}/stub6c-bin/docker" << 'EOF'
#!/bin/bash
# the api as plane_seed sees it: it exists, its Django shell runs the seed, the proxy serves is_setup_done true
case "$*" in
*"manage.py shell -c"*) cat > /dev/null; printf 'seed: stub\nPROJECT_ID=00000000-0000-0000-0000-000000000000\n' ;;
*"python -c"*) echo true ;;
esac
exit 0
EOF
	chmod +x "${D}/stub6c-bin/docker"
	( cd "${D}/copy" && PATH="${D}/stub6c-bin:${PATH}" ./plane.sh init && PATH="${D}/stub6c-bin:${PATH}" ./plane.sh seed ) \
		> "${D}/debug.out" 2>&1 || fail "init and seed with DEBUG=true: $(tail -2 "${D}/debug.out")"
	sed -i -e 's/^export DRY_RUN=.*/export DRY_RUN=true/' -e 's/^export DEBUG=.*/export DEBUG=false/' "${D}/copy/.env"
	( umask 077; for K in PLANE_ADMIN_PASSWORD PLANE_API_KEY PLANE_SECRET_KEY PLANE_LIVE_SERVER_SECRET_KEY PLANE_DB_PASSWORD PLANE_MQ_PASSWORD PLANE_MINIO_SECRET_KEY; do
		sed -n "s/^${K}=//p" "${D}/copy/wd/plane/plane.env"; done > "${D}/debug-values.txt" )
	[ "$(grep -c . "${D}/debug-values.txt")" -eq 7 ] || fail "init with DEBUG=true did not leave seven values in plane.env"
	TRACED=$(grep -c '^+' "${D}/debug.out")
	[ "${TRACED}" -gt 0 ] || fail "the control failed: DEBUG=true traced nothing, so the check below could not see a secret"
	HITS=$(grep -cFf "${D}/debug-values.txt" "${D}/debug.out")
	[ "${HITS}" -eq 0 ] || fail "with DEBUG=true, ${HITS} line(s) of init and seed's output held a plane.env value"
	echo "ok 6c - DEBUG=true: init and seed traced ${TRACED} lines and no plane.env value; redact and apply_datastore_passwords under set -x none"
	# 7. no egress for the services, and a loopback metrics exporter
	NETS=$(grep -E '^docker network create ' "${D}/plane-up.out")
	echo "${NETS}" | grep -qE -- "--internal ${PLANE_INTERNAL_NETWORK}( |$)" \
		|| fail "the services' network ${PLANE_INTERNAL_NETWORK} is not created --internal: [${NETS//$'\n'/; }]"
	echo "${NETS}" | grep -E -- " ${PLANE_NETWORK}( |$)" | grep -q -- '--internal' \
		&& fail "the agent's network ${PLANE_NETWORK} is created --internal (the agent needs its egress)"
	sed -i 's/^export DRY_RUN=.*/export DRY_RUN=false/' "${D}/copy/.env"
	( cd "${D}/copy" && PATH="${D}/stub-bin:${PATH}" ./plane.sh init ) > "${D}/init.out" 2>&1 || fail "./plane.sh init in the copy: $(tail -2 "${D}/init.out")"
	sed -i 's/^export DRY_RUN=.*/export DRY_RUN=true/' "${D}/copy/.env"
	grep -qE '^OTLP_ENDPOINT=https?://(127\.[0-9]+\.[0-9]+\.[0-9]+|localhost|\[::1\])(:[0-9]+)?/?$' "${D}/copy/wd/plane/app.env" \
		|| fail "app.env does not point Plane's metrics exporter at loopback: [$(grep '^OTLP_ENDPOINT' "${D}/copy/wd/plane/app.env")]"
	echo "ok 7 - nothing can phone home: ${PLANE_INTERNAL_NETWORK} is --internal (${PLANE_NETWORK} is not), app.env's $(grep '^OTLP_ENDPOINT=' "${D}/copy/wd/plane/app.env")"
	# 8. the whole dry run again on a PATH with every tool of this one but python (the inner run skips this check)
	[ -n "${TEST_PLANE_INNER}" ] && return 0
	mkdir -p "${D}/nopython-bin"
	IFS=: read -r -a DIRS <<< "${PATH}"
	for DIR in "${DIRS[@]}"; do
		[ -d "${DIR}" ] && ln -s "${DIR}"/* "${D}/nopython-bin/" 2> /dev/null  # an earlier PATH entry wins, as in PATH
	done
	rm -f "${D:?}"/nopython-bin/python*
	[ -z "$(PATH="${D}/nopython-bin" command -v python3)" ] || fail "the control failed: the inner PATH still has python3"
	( cd "${BASE_DIR}" && PATH="${D}/nopython-bin" TEST_PLANE_INNER=1 ./test-plane.sh dry ) > "${D}/nopython.out" 2>&1
	{ grep -q 'no python3 on this host' "${D}/nopython.out" && [ "$(tail -1 "${D}/nopython.out")" == "Test-plane-dry PASSED" ]; } \
		|| fail "without python3 on the host the dry run did not pass with a clear message: $(tail -2 "${D}/nopython.out" | tr '\n' ' ')"
	echo "ok 8 - without python3 on the host: the dry run says so, skips only seed.py's parse check, and passes ($(grep -c '^ok ' "${D}/nopython.out") checks)"
	# 9. in a subshell (plane.sh's wait_migrator and a docker stub on PATH)
	( migrator_wait ) || exit 1
	# 10. a scratch checkout of the files this dry run reads, with a planted .env.local, runs it (as 8 does)
	mkdir -p "${D}/local/plane"
	cp "${BASE_DIR}/test-plane.sh" "${BASE_DIR}/plane.sh" "${BASE_DIR}/run.sh" "${BASE_DIR}/env-local.sh" "${BASE_DIR}/preflight.sh" \
		"${BASE_DIR}/kanban.sh" "${BASE_DIR}/docker.sh" "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${D}/local/"
	cp "${BASE_DIR}/plane/seed.py" "${D}/local/plane/"
	printf 'export CONTAINER=planted-local\nexport DRY_RUN=false\nexport PLANE_DIR=%s\n' "${D}/outside/plane" > "${D}/local/.env.local"
	( cd "${D}/local" && TEST_PLANE_INNER=1 ./test-plane.sh dry ) > "${D}/local.out" 2>&1
	{ grep -q '^ok 3 .*=planted-local ' "${D}/local.out" && [ "$(tail -1 "${D}/local.out")" == "Test-plane-dry PASSED" ]; } \
		|| fail "with CONTAINER set in .env.local only, the dry run did not pass with its names: $(grep -m1 'FAILED' "${D}/local.out" | cut -c1-200)"
	[ -e "${D}/outside" ] && fail "the dry run wrote to the PLANE_DIR of .env.local, outside its copy: $(find "${D}/outside" | head -3 | tr '\n' ' ')"
	echo "ok 10 - .env.local reaches the copy: CONTAINER=planted-local there alone passes the dry run with planted-local-plane-* ($(grep -c '^ok ' "${D}/local.out") checks); its DRY_RUN=false and outside PLANE_DIR do not"
}

# cmdline_hits <values file> - the number of processes whose command line holds one of the values (grep reads them
# from the file, so its own command line holds none)
cmdline_hits()
{
	grep -alFf "$1" /proc/[0-9]*/cmdline 2>/dev/null | wc -l
}

# scan_while <filter> <input> <output> - runs "<input lines, 3 s late> | <filter> > <output>" and sums cmdline_hits
# of the values over four reads while the filter waits for its input
scan_while()
{
	{ sleep 3; cat "$2"; } | "$1" > "$3" &
	HITS=0
	for _ in 1 2 3 4; do
		sleep 0.5
		HITS=$((HITS + $(cmdline_hits "${D}/values.txt")))
	done
	wait $!
}

migrator_wait()
{
	eval "$(sed -n -e '/^wait_migrator()$/,/^}$/p' "${BASE_DIR}/plane.sh")"
	type wait_migrator > /dev/null 2>&1 || fail "plane.sh lacks wait_migrator"
	mkdir -p "${D}/stub9-bin"
	cat > "${D}/stub9-bin/docker" << 'EOF'
#!/bin/bash
# STUB_WAIT: hang (a stalling daemon) or the code docker container wait prints; STUB_STATE: what inspect says
case "$*" in
*"container wait"*) [ "${STUB_WAIT}" == "hang" ] && exec sleep 30; echo "${STUB_WAIT}" ;;
*"container inspect"*) echo "${STUB_STATE}" ;;
esac
exit 0
EOF
	chmod +x "${D}/stub9-bin/docker"
	try() { ( PATH="${D}/stub9-bin:${PATH}" PLANE_MIGRATE_TIMEOUT=2 STUB_WAIT=$1 STUB_STATE=$2 wait_migrator stand-in-migrator; echo "MIG_RC=${MIG_RC}" ) 2>&1; }
	OUT=$(try hang "exited 0")
	{ echo "${OUT}" | grep -qx 'MIG_RC=0' && echo "${OUT}" | grep -q "gave no answer within 2s (PLANE_MIGRATE_TIMEOUT); the migrator's own state: exited 0"; } \
		|| fail "a migrator that exited 0 failed when docker container wait timed out: ${OUT//$'\n'/ }"
	OUT=$(try hang "running 0")
	echo "${OUT}" | grep -qx 'MIG_RC=' || fail "a migrator still running when the wait timed out was taken as done: ${OUT//$'\n'/ }"
	OUT=$(try 0 "")
	{ echo "${OUT}" | grep -qx 'MIG_RC=0' && ! echo "${OUT}" | grep -q 'gave no answer'; } || fail "a wait that answers 0 is not taken as is: ${OUT//$'\n'/ }"
	echo "ok 9 - a migrator wait that outlives PLANE_MIGRATE_TIMEOUT: exited 0 passes (and says so), running does not; an answered wait passes"
}

secrets_paths()
{
	eval "$(sed -n -e '/^kv()$/,/^}$/p' -e '/^SECRET_KEYS=/p' -e '/^redact()$/,/^}$/p' -e '/^apply_datastore_passwords()$/,/^}$/p' \
		-e '/^quiet()$/,/^}$/p' -e '/^unquiet()$/,/^}$/p' "${BASE_DIR}/plane.sh")"
	{ type redact && type apply_datastore_passwords && [ -n "${SECRET_KEYS}" ]; } > /dev/null 2>&1 \
		|| fail "plane.sh lacks redact, apply_datastore_passwords or SECRET_KEYS"
	# every secret planted, the admin password with all of sed's special characters
	AUTH_FILE=${D}/secrets.env
	( umask 077
	  for K in ${SECRET_KEYS}; do
		if [ "${K}" == "PLANE_ADMIN_PASSWORD" ]; then V="${PLANTED}-pw/&.*[x]^\$\\end"; else V="${PLANTED}-${K}"; fi
		echo "${K}=${V}" >> "${AUTH_FILE}"
		echo "${V}" >> "${D}/values.txt"
		echo "a log line with ${V} in it" >> "${D}/log.txt"
	  done )
	scan_while redact "${D}/log.txt" "${D}/redacted.txt"
	[ "${HITS}" -eq 0 ] || fail "while plane.sh's redact ran, ${HITS} process command line(s) held a secret"
	{ [ "$(grep -cFx 'a log line with *** in it' "${D}/redacted.txt")" -eq "$(wc -l < "${D}/log.txt")" ] && ! grep -qFf "${D}/values.txt" "${D}/redacted.txt"; } \
		|| fail "redact did not mask every secret: $(grep -cF '***' "${D}/redacted.txt") of $(wc -l < "${D}/log.txt") lines masked"
	# the control: the former redact, one sed -e per value, on the same values without sed's special characters
	# (those would stop its sed at once)
	# shellcheck disable=SC2317 # called by name, through scan_while
	redact_argv()
	{
		SED_ARGS=()
		for K in ${SECRET_KEYS}; do
			V=$(kv "${K}")
			[ -n "${V}" ] && SED_ARGS+=(-e "s/${V}/***/g")
		done
		sed "${SED_ARGS[@]}"
	}
	sed -i "s/^PLANE_ADMIN_PASSWORD=.*/PLANE_ADMIN_PASSWORD=${PLANTED}-pw/" "${AUTH_FILE}"
	echo "${PLANTED}-pw" >> "${D}/values.txt"
	scan_while redact_argv "${D}/log.txt" "${D}/control.txt"
	[ "${HITS}" -gt 0 ] || fail "the control failed: the scan saw no secret while the former redact (sed -e per value) ran"
	echo "ok 6a - redact masks every secret (sed's special characters included); while it runs no command line holds one (the former sed -e redact: ${HITS} hits)"
	# the database and queue passwords: a docker stub on PATH records each command line and each stdin; the queue does
	# not know the password yet (authenticate_user fails), so the queue user is re-created
	mkdir -p "${D}/stub6-bin"
	cat > "${D}/stub6-bin/docker" << EOF
#!/bin/bash
echo "\$*" >> "${D}/apply-argv.log"
if [ "\$3" == "-i" ]; then cat >> "${D}/apply-stdin.log"; fi
case "\$*" in
*authenticate_user*) exit 1 ;;
*list_users*) printf 'user\ttags\nplane\t[administrator]\n' ;;
esac
exit 0
EOF
	chmod +x "${D}/stub6-bin/docker"
	( PATH="${D}/stub6-bin:${PATH}" DRY_RUN=false apply_datastore_passwords ) > "${D}/apply.out" 2>&1 \
		|| fail "apply_datastore_passwords failed: $(tail -1 "${D}/apply.out")"
	grep -qFf "${D}/values.txt" "${D}/apply-argv.log" && fail "a datastore password reached a docker command line"
	{ grep -qF "PASSWORD '$(kv PLANE_DB_PASSWORD)'" "${D}/apply-stdin.log" && grep -qxF "$(kv PLANE_MQ_PASSWORD)" "${D}/apply-stdin.log" \
		&& grep -qF -- "-i ${PLANE_NAME}-db psql" "${D}/apply-argv.log" && grep -qF -- "-i ${PLANE_NAME}-mq rabbitmqctl add_user plane" "${D}/apply-argv.log"; } \
		|| fail "the database and queue passwords did not reach psql and rabbitmqctl add_user on stdin"
	# measured on rabbitmq:3.13.6: with -q, a rabbitmqctl that reads its password from stdin waits forever
	grep -qE -- "-i ${PLANE_NAME}-mq rabbitmqctl (.* )?-q( |$)" "${D}/apply-argv.log" \
		&& fail "rabbitmqctl reads a password from stdin with -q (the RabbitMQ 3.13 CLI then waits forever)"
	echo "ok 6b - the database and queue passwords reach psql and rabbitmqctl on stdin only (rabbitmqctl without -q)"
	# 6c, the functions: traced with DEBUG=true and set -x, neither prints a value (their input comes from files, so
	# this test's own traced commands hold none)
	( DEBUG=true; set -x; redact < "${D}/log.txt" > /dev/null ) 2> "${D}/redact.trace"
	( DEBUG=true; set -x; PATH="${D}/stub6-bin:${PATH}" DRY_RUN=false apply_datastore_passwords > /dev/null ) 2> "${D}/apply.trace"
	{ grep -q '^+' "${D}/redact.trace" && grep -q '^+' "${D}/apply.trace"; } || fail "the control failed: set -x traced nothing"
	if grep -qFf "${D}/values.txt" "${D}/redact.trace" "${D}/apply.trace"; then
		fail "under set -x a secret was traced: $(grep -lFf "${D}/values.txt" "${D}/redact.trace" "${D}/apply.trace" | xargs -n1 basename | tr '\n' ' ')"
	fi
}

live()
{
	command -v python3 > /dev/null 2>&1 \
		|| fail "the live checks read the board's JSON with python3, which this host lacks - install python3, or run ./test-plane.sh dry"
	AUTH=${PLANE_DIR}/plane.env
	[ -f "${AUTH}" ] || fail "no ${AUTH} - run ./run.sh first"
	URL=http://127.0.0.1:${PORT_EXTERNAL_HOME}
	ROUTE="Host: plane.localhost:${PORT_EXTERNAL_HOME}"
	# 1. the SERVED setup state
	HTTP=$(curl -s --noproxy '*' -o "${D}/instances.json" -w '%{http_code}' --max-time 10 -H "${ROUTE}" "${URL}/api/instances/")
	SETUP=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(str((d.get("instance") or d).get("is_setup_done")).lower())' "${D}/instances.json" 2>/dev/null)
	{ [ "${HTTP}" == "200" ] && [ "${SETUP}" == "true" ]; } || fail "the served /api/instances/ through ${URL} (Host plane.localhost) answered ${HTTP} with is_setup_done=${SETUP:-?}"
	echo "ok 1 - the served /api/instances/ through the home port: 200, is_setup_done=true (no setup wizard)"
	# 2. the agent's API key
	( umask 077; printf 'X-Api-Key: %s\n' "$(sed -n 's/^PLANE_API_KEY=//p' "${AUTH}" | tail -1)" > "${D}/key.hdr" )
	HTTP=$(curl -s --noproxy '*' -o "${D}/projects.json" -w '%{http_code}' --max-time 10 -H "${ROUTE}" -H @"${D}/key.hdr" \
		"${URL}/api/v1/workspaces/${PLANE_WORKSPACE}/projects/")
	PROJECT_ID=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(next((p["id"] for p in d.get("results", []) if p.get("identifier") == sys.argv[2]), ""))' \
		"${D}/projects.json" "${PLANE_PROJECT_IDENTIFIER}" 2>/dev/null)
	{ [ "${HTTP}" == "200" ] && [ -n "${PROJECT_ID}" ]; } || fail "the project list with the agent's API key answered ${HTTP}; project ${PLANE_PROJECT_IDENTIFIER} $(if [ -n "${PROJECT_ID}" ]; then echo found; else echo missing; fi)"
	echo "ok 2 - the agent's API key (X-Api-Key) reads workspace ${PLANE_WORKSPACE}: 200, project ${PLANE_PROJECT_IDENTIFIER} present"
	# 3. the one-click sign-in (only when it is on): the tile's link click carries the home page as its Referer
	HOMEREF=http://localhost:${PORT_EXTERNAL_HOME}/
	if [ "${PLANE_LOGIN_BYPASS}" == "true" ]; then
		for HDR in "X-None: 1" "Referer: https://evil.example/" "Origin: https://evil.example" "Referer: http://localhost:9/"; do
			HTTP=$(curl -s --noproxy '*' -o /dev/null -D "${D}/csrf.hdr" -w '%{http_code}' --max-time 30 -H "${ROUTE}" -H "${HDR}" "${URL}/__harness/sign-in")
			{ [ "${HTTP}" == "403" ] && ! grep -qi '^set-cookie' "${D}/csrf.hdr"; } || fail "a sign-in with '${HDR}' (not from the home page) answered ${HTTP}$(grep -qi '^set-cookie' "${D}/csrf.hdr" && echo ' with a cookie')"
		done
		echo "   not from the home page (no Referer or Origin, another site's, another port's): 403, no cookie"
		HTTP=$(curl -s --noproxy '*' -o /dev/null -D "${D}/signin.hdr" -w '%{http_code}' --max-time 30 -e "${HOMEREF}" -H "${ROUTE}" "${URL}/__harness/sign-in")
		LOCATION=$(sed -n 's/^[Ll]ocation: *//p' "${D}/signin.hdr" | tr -d '\r')
		( umask 077; sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\).*/\1/p' "${D}/signin.hdr" | tr -d '\r' | paste -sd ';' - | sed 's/^/Cookie: /' > "${D}/cookie.hdr" )
		[ "${HTTP}" == "302" ] || fail "the sign-in answered ${HTTP}, not 302"
		# the helper answers a relative Location; the home proxy makes it absolute on plane.localhost at the port the
		# browser is on (a host route's redirects stay on its host)
		[ "${LOCATION}" == "http://plane.localhost:${PORT_EXTERNAL_HOME}/${PLANE_WORKSPACE}/projects/${PROJECT_ID}/issues/" ] \
			|| fail "the sign-in redirects to '${LOCATION}', not the project's board on plane.localhost:${PORT_EXTERNAL_HOME}"
		grep -q 'session-id=' "${D}/cookie.hdr" || fail "the sign-in set no session-id cookie"
		grep -qi 'domain=' "${D}/signin.hdr" && fail "a sign-in cookie carries a Domain attribute (it must be host-only)"
		HTTP=$(curl -s --noproxy '*' -o "${D}/me.json" -w '%{http_code}' --max-time 10 -H "${ROUTE}" -H @"${D}/cookie.hdr" "${URL}/api/users/me/")
		{ [ "${HTTP}" == "200" ] && grep -qF "\"email\":\"$(sed -n 's/^PLANE_ADMIN_EMAIL=//p' "${AUTH}" | tail -1)\"" "${D}/me.json"; } \
			|| fail "/api/users/me/ with the sign-in's cookie answered ${HTTP}"
		echo "ok 3 - the one-click sign-in from the home page: 302 to http://plane.localhost:${PORT_EXTERNAL_HOME}/${PLANE_WORKSPACE}/projects/<id>/issues/ with a host-only session cookie that reads /api/users/me/ (200); not from the home page: 403"
	else
		HTTP=$(curl -s --noproxy '*' -o /dev/null -D "${D}/signin.hdr" -w '%{http_code}' --max-time 30 -e "${HOMEREF}" -H "${ROUTE}" "${URL}/__harness/sign-in")
		grep -qi '^set-cookie: *session-id=' "${D}/signin.hdr" && fail "PLANE_LOGIN_BYPASS=false, yet the sign-in URL set a session cookie"
		echo "ok 3 - PLANE_LOGIN_BYPASS=false: the sign-in URL is Plane's own route (http ${HTTP}), no session cookie"
	fi
	# 4. a non-loopback Host never signs in
	for H in evil.example.com "plane.localhost.evil.example.com:${PORT_EXTERNAL_HOME}" "rebind.127.0.0.1.nip.io:${PORT_EXTERNAL_HOME}"; do
		HTTP=$(curl -s --noproxy '*' -o /dev/null -D "${D}/foreign.hdr" -w '%{http_code}' --max-time 10 -e "${HOMEREF}" -H "Host: ${H}" "${URL}/__harness/sign-in")
		grep -qi '^set-cookie: *session-id=' "${D}/foreign.hdr" && fail "Host ${H} got a session cookie through the home port"
		[ "${HTTP}" == "302" ] && fail "Host ${H} was redirected like a sign-in (http 302)"
		echo "   through the home port, Host ${H}: http ${HTTP}, no session cookie"
	done
	if [ "${PLANE_LOGIN_BYPASS}" == "true" ]; then
		# a Referer on the same port as the Host passes the home-page check, so only the Host check can refuse
		P=${PORT_INTERNAL_PLANE_SIGNIN}
		HTTP=$(docker container exec "${CONTAINER}" curl -s --noproxy '*' -o /dev/null -D - -w '%{http_code}' --max-time 10 \
			-e "http://localhost:${P}/" -H "Host: evil.example.com:${P}" "http://127.0.0.1:${P}/__harness/sign-in" 2>/dev/null | tr -d '\r')
		echo "${HTTP}" | grep -qi '^set-cookie:' && fail "the sign-in helper set a cookie for Host evil.example.com"
		[ "$(echo "${HTTP}" | tail -1)" == "403" ] || fail "the sign-in helper answered $(echo "${HTTP}" | tail -1) to Host evil.example.com, not 403"
		echo "ok 4 - a non-loopback Host never signs in: no route and no cookie through the home port; the helper itself answers 403"
	else
		echo "ok 4 - a non-loopback Host never signs in through the home port (the helper is off)"
	fi
	# 5. no host port for the board; the home port on loopback only
	PUBLISHED=$(docker ps --filter "label=do-agent-aws.plane=${CONTAINER}" --format '{{.Names}} {{.Ports}}' | grep -E -- '->' )
	[ -z "${PUBLISHED}" ] || fail "a Plane sidecar publishes a host port: ${PUBLISHED}"
	[ "$(docker ps --filter "label=do-agent-aws.plane=${CONTAINER}" -q | wc -l)" -ge 12 ] || fail "fewer than 12 Plane sidecars run"
	HOME_PUB=$(docker port "${CONTAINER}" 2>/dev/null | tr '\n' ' ')
	[ "${HOME_PUB}" == "${PORT_INTERNAL_HOME}/tcp -> ${UI_BIND_HOST}:${PORT_EXTERNAL_HOME} " ] || fail "the agent publishes [${HOME_PUB}], not only ${UI_BIND_HOST}:${PORT_EXTERNAL_HOME}"
	echo "ok 5 - the $(docker ps --filter "label=do-agent-aws.plane=${CONTAINER}" -q | wc -l) Plane sidecars publish no host port; the agent publishes only ${UI_BIND_HOST}:${PORT_EXTERNAL_HOME}"
	# 6. only the board's proxy shares a network with the agent
	MEMBERS=$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "${PLANE_NETWORK}" 2>/dev/null | tr ' ' '\n' | grep . | sort | tr '\n' ' ')
	[ "${MEMBERS}" == "$(printf '%s\n' "${CONTAINER}" "${PLANE_NAME}-proxy" | sort | tr '\n' ' ')" ] \
		|| fail "${PLANE_NETWORK} holds [${MEMBERS}], not only the agent and the board's proxy"
	AGENT_IP=$(docker container inspect -f "{{(index .NetworkSettings.Networks \"${PLANE_NETWORK}\").IPAddress}}" "${CONTAINER}" 2>/dev/null)
	PORTS=$(for V in $(compgen -v PORT_INTERNAL_); do echo "${!V}"; done | sort -un | tr '\n' ' ')
	docker container exec -i "${PLANE_NAME}-api" python - "proxy:80" "${CONTAINER}:${PORTS}" "${AGENT_IP}:${PORTS}" > "${D}/reach.txt" 2>&1 << 'EOF'
import socket, sys
for arg in sys.argv[1:]:
    host, ports = arg.split(":", 1)
    for port in ports.split():
        try:
            socket.create_connection((host, int(port)), timeout=2).close()
            print(f"open {host}:{port}")
        except OSError as e:
            print(f"closed {host}:{port} ({type(e).__name__})")
EOF
	grep -qx 'open proxy:80' "${D}/reach.txt" || fail "the control failed: the probe in the api container did not open the board's proxy: $(head -3 "${D}/reach.txt")"
	OPEN=$(grep '^open ' "${D}/reach.txt" | grep -v '^open proxy:80$' | tr '\n' ' ')
	[ -z "${OPEN}" ] || fail "from the board's api container the agent is reachable: ${OPEN}"
	[ "$(grep -c '^closed ' "${D}/reach.txt")" -eq $((2 * $(echo "${PORTS}" | wc -w))) ] || fail "the reach probe did not try every agent port: $(tail -3 "${D}/reach.txt")"
	echo "ok 6 - only the board's proxy shares ${PLANE_NETWORK} with the agent; from the api container none of the agent's ${PORTS}opens (by name or ${AGENT_IP:-?}), the board's proxy does"
	# 7. nothing phoned home
	docker container logs "${PLANE_NAME}-worker" > "${D}/worker.log" 2>&1
	python3 - "${D}/worker.log" > "${D}/exporters.txt" << 'EOF'
import re, sys
log = open(sys.argv[1], errors="replace").read()
loop = re.compile(r"^(127\.\d+\.\d+\.\d+|localhost|\[::1\])(:\d+)?$")
seen = bad = 0
# Plane logs each line twice, as text and as JSON: an endpoint ends at a space, a quote or a brace
for kind, pat in (("exporter", r"Configuring OTLP exporter: protocol=\w+, endpoint=([^\s\"'}]+)"),
                  ("push", r"Successfully pushed metrics to OTEL collector at ([^\s\"'}]+)")):
    for m in re.finditer(pat, log):
        seen += 1
        host = re.sub(r"^\w+://", "", m.group(1)).split("/")[0]
        if not loop.match(host):
            bad += 1
            print(f"BAD {kind} {m.group(1)}")
print(f"SEEN {seen} BAD {bad}")
EOF
	grep -q '^BAD ' "${D}/exporters.txt" && fail "the board phoned home: $(grep '^BAD ' "${D}/exporters.txt" | head -3 | tr '\n' ' ')"
	grep -q '^SEEN ' "${D}/exporters.txt" || fail "the worker log check did not run: $(head -2 "${D}/exporters.txt")"
	PROBE='import socket
try:
    socket.create_connection(("api.github.com", 443), timeout=5).close()
    print("open")
except OSError as e:
    print("closed " + type(e).__name__)'
	API_EGRESS=$(docker container exec "${PLANE_NAME}-api" python -c "${PROBE}" 2>&1 | tail -1)
	AGENT_EGRESS=$(docker container exec "${CONTAINER}" python3 -c "${PROBE}" 2>&1 | tail -1)
	echo "${API_EGRESS}" | grep -q '^closed ' || fail "the board's api container reaches api.github.com:443 (${API_EGRESS}): the services have egress"
	docker container logs "${PLANE_NAME}-api" 2>&1 | grep -q 'Error checking for latest version' \
		|| fail "the api's GitHub release check did not fall back (no 'Error checking for latest version' in its log)"
	if [ "${AGENT_EGRESS}" == "open" ]; then
		CONTROL="the agent container does (the control)"
	else
		CONTROL="the control could not run: the agent container has no egress either (${AGENT_EGRESS})"
	fi
	echo "ok 7 - nothing phoned home: $(sed -n 's/^SEEN \([0-9]*\) BAD 0$/\1/p' "${D}/exporters.txt") exporter/push line(s) in the worker log, all loopback; the api cannot reach api.github.com (${API_EGRESS}), ${CONTROL}; its release check fell back"
}

# lc_cleanup - what lifecycle planted, by the names it recorded: the container, its anonymous volumes (a failed check
# leaves one) and the named uploads volume
lc_cleanup()
{
	[ -n "${LC_CONTAINER:-}" ] && docker container rm -f -v "${LC_CONTAINER:?}" > /dev/null 2>&1
	for V in ${LC_ANON:-}; do docker volume rm "${V:?}" > /dev/null 2>&1; done
	[ -n "${LC_NAMED:-}" ] && docker volume rm "${LC_NAMED:?}" > /dev/null 2>&1
	return 0
}

lifecycle()
{
	command -v docker > /dev/null 2>&1 || fail "lifecycle needs docker"
	IMG=${PLANE_MINIO_IMAGE}
	# test.sh runs this with the board on, where ./build.sh pulls the image: without it no check can run, and that is
	# not a pass
	docker image inspect "${IMG}" > /dev/null 2>&1 \
		|| fail "${IMG} is not on this host, so no lifecycle check ran (./build.sh pulls it with the board on, or docker pull ${IMG})"
	trap 'lc_cleanup; rm -rf "${D:?}"' EXIT
	LC=do-agent-aws-test-plane-lifecycle-$$
	PN=${LC}-plane
	mkdir -p "${D}/lc" || fail "could not make the lifecycle copy"
	cp "${BASE_DIR}/stop.sh" "${BASE_DIR}/plane.sh" "${BASE_DIR}/kanban.sh" "${BASE_DIR}/docker.sh" "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${D}/lc/" \
		|| fail "could not copy stop.sh and the scripts it runs"
	# the copy's own CONTAINER (the test's pid: no stack uses it), the docker target, a real stop
	printf 'export CONTAINER=%s\nexport TO=docker\nexport DRY_RUN=false\n' "${LC}" > "${D}/lc/.env.local"
	BEFORE=$(docker volume ls -q | sort)
	# the board's minio as plane.sh starts it: its label, its name, its named uploads volume at /export
	LC_CONTAINER=${PN}-minio
	LC_NAMED=${PN}-uploads
	docker container run -d --name "${LC_CONTAINER}" --label "do-agent-aws.plane=${LC}" -v "${LC_NAMED}:/export" "${IMG}" server /export \
		> /dev/null 2> "${D}/lc-run.err" || fail "could not start the planted board container: $(tail -1 "${D}/lc-run.err")"
	MOUNTS=$(docker container inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Destination}}{{println}}{{end}}{{end}}' "${LC_CONTAINER}")
	LC_ANON=$(echo "${MOUNTS}" | awk -v n="${LC_NAMED}" 'NF == 2 && $1 != n { print $1 }')
	[ -n "${LC_ANON}" ] || fail "the planted container has no anonymous volume, so a stop that leaves one could not be seen: ${MOUNTS}"
	echo "${MOUNTS}" | grep -qx "${LC_NAMED} /export" || fail "the planted container has no named uploads volume at /export: ${MOUNTS}"
	( cd "${D}/lc" && ./stop.sh ) > "${D}/lc-stop.out" 2>&1
	docker container inspect "${LC_CONTAINER}" > /dev/null 2>&1 && fail "./stop.sh left the board container ${LC_CONTAINER}: $(tail -3 "${D}/lc-stop.out")"
	ADDED=$(comm -13 <(echo "${BEFORE}") <(docker volume ls -q | sort))
	LEFT=$(for V in ${LC_ANON}; do echo "${ADDED}" | grep -qx "${V}" && echo "${V}"; done)
	[ -z "${LEFT}" ] || fail "./stop.sh left $(echo "${LEFT}" | grep -c .) anonymous volume(s) of ${LC_CONTAINER} behind (the image's VOLUME /data): ${LEFT}"
	echo "${ADDED}" | grep -qx "${LC_NAMED}" || fail "./stop.sh removed the named volume ${LC_NAMED} (the board's data volumes stay)"
	echo "   lifecycle: a board container started and stopped with ./stop.sh: its anonymous volume gone, the named volume ${LC_NAMED} kept"
}

case "${NAME}" in
	"dry")
		dry
		;;
	"live")
		live
		;;
	"lifecycle")
		lifecycle
		;;
	*)
		echo "Usage: $0 dry|live|lifecycle"
		exit 1
		;;
esac
echo "Test-plane-${NAME} PASSED"
