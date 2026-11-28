#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of ./run.sh's start command on the docker target (run by test.sh like test-preflight.sh): run.sh, .env,
# .fun, env-local.sh and preflight.sh are copied into ./scratch/test-run (gitignored) with a planted .env.local (its own
# container name, the two boards off, so no sidecar starts) and a docker stub on PATH that answers the preflight as a
# sound host, records the words `docker container run` gets and answers as each check plants. No real docker command
# runs, and nothing of the checkout is read for a setting or written.
# Each check FAILS if the property is removed:
#   1. a start that fails exits non-zero with one ERROR line: docker refusing the start (exit 125) -> run.sh exits 125
#      after docker's own error; a start command that does not parse (a planted NETWORK with a parenthesis) -> run.sh
#      exits 2 after the shell's syntax error, and docker never ran
#   2. an agent container that is not running right after its start -> run.sh exits 1 with one ERROR line naming the
#      container and its state (exited, exit code 1) and its last log lines; a container docker does not know -> "no
#      such container"
#   3. a sound start (the container running) exits 0 with no ERROR line, the docker command run once and its last word
#      the image; an interactive run (./run.sh <command>) exits with its command's status and no ERROR line, and its
#      command reaches docker as its words were given: bash -c 'echo $HOME; touch planted-arg' is three words after the
#      image, and nothing in it is expanded or run on the host
#   4. LOOP_DECK_URL is checked on its whole value before it reaches the start command, with the home page's own pattern
#      (.env's LOOP_DECK_URL_SHAPE is home-render.sh's): a plain http URL reaches docker as given; javascript:alert(1), an
#      ftp URL, a second line and HTML markup are each refused with the WARNING and reach docker as LOOP_DECK_URL= (empty),
#      and the start goes on (exit 0, the image the last word)
#   5. every setting's value reaches docker as one word, as written: every -e NAME= value on an option line of .env is
#      exactly $(shq "${VAR}") or holds only letters, digits and _ . / : , = @ % + - (the lint first finds each planted
#      form outside that: prefix${X}, $(other ...), ${X}, a suffix after the shq call, a prefix before it, \"${X}\",
#      \"lit\", a\\b, a backquoted command, a ; | & > or < in a literal, and the marker's own text <SHQ> written as a
#      value); planted values with a space, a quote, a parenthesis, a semicolon, $(...) and backquotes, and a plain
#      LOOP_DECK_URL with # ? & ( ), reach docker container run each as its one word, nothing they spell runs, and the
#      shipped values read as before (no_proxy's commas, an empty SLACK_CHANNELS empty); test.sh, run on a copy with its
#      other host-side tests stubbed, gives the test container the same words
#   6. COMMS_ENV_NAMES holds names only: two names reach docker as -e NAME -e NAME; an entry that is not a variable name
#      (a parenthesis, a semicolon, a leading digit, and PLANTED: a glob that matches a file in the current directory,
#      PLANTEDNAM? beside a file PLANTEDNAME) stops the start before docker runs (exit 1) with one ERROR line that does
#      not show the entry
#   7. with NETWORK set and the kanban board on, the agent container joins the board's network once it runs: a join
#      docker refuses (PLANTED) is one WARNING, run.sh exits 0 with no ERROR line; an agent container not running after
#      its start is the ERROR with exit 1, and no join is tried; a sound join gets the board's network and the container;
#      the join is a direct docker call (PLANTED: a board network name with shell syntax reaches docker as one word, and
#      nothing it spells runs), and VERBOSE prints it as the shell would read it (the name quoted)
#   8. the board join is run.sh's own: values in the caller's environment (PLANTED: KANBAN_CONNECT="touch
#      planted-connect" and KANBAN_JOIN_NETWORK) run nothing and join nothing on the swarm target, which never sets them
#      (the docker stub answers its deploy)
#   10. the docker spoke's build substrate (SPOKE_DOCKER=true) through the real docker.sh: PLANTED: its two network names
#      and its socket volume's name with shell syntax reach the network create, the volume create, the sidecars' --network
#      and -v, and the agent's --mount each as one word, and nothing they spell runs; the agent joins the internal network
#      once it runs, a direct docker call that VERBOSE prints quoted, and a refused join is one WARNING (exit 0, no ERROR);
#      the join is run.sh's own (PLANTED: DOCKER_CONNECT and DOCKER_JOIN_NETWORK in the caller's environment do nothing on
#      the swarm target); PLANTED: a ./docker.sh up that fails (docker refuses the network create) leaves the agent
#      started without the substrate (no socket volume, no BUILDKIT_HOST, no join) and marked DOCKER_SUBSTRATE=failed,
#      with one WARNING and exit 0
#   11. a host that restricts unprivileged user namespaces (PLANTED: a stub sysctl answering
#      kernel.apparmor_restrict_unprivileged_userns=1): ./docker.sh up names the setting and the host owner's two
#      options, removes a daemon left from an earlier start, and starts no sidecar and creates no network or volume, so
#      nothing is left restarting; run.sh starts the agent without the substrate, marked DOCKER_SUBSTRATE=failed, and
#      exits 0; ./docker.sh status names the setting; CONTROL: at 0 both sidecars start as before
#   9. the kanban board's network names reach docker as one word on the path without NETWORK too, through the real
#      kanban.sh (up with the relay on, then down) and the agent's start command (PLANTED: both network names with shell
#      syntax, and a docker that keeps the networks it creates): the network create, connect and rm calls, the sidecars'
#      --network and the agent's get each name as one word, and nothing either name spells runs
#   13. the Plane board is opt-in (docs/manual/boards.md "Plane board"): .env ships UI_PLANE=false; a default start (no UI_PLANE in
#       .env.local) runs nothing of ./plane.sh, and the agent neither joins the Plane network nor gets PLANE_URL; with
#       UI_PLANE=true in .env.local ./plane.sh up runs and the agent joins the Plane network with PLANE_URL
#   12. -s (--single), the agent container alone (docs/manual/install.md "Restart only the agent container"): with the two boards and
#      the docker spoke on, ./run.sh -s is a detached run (-d) that runs none of ./plane.sh up, ./docker.sh up and
#      ./kanban.sh up (PLANTED: stubs of the three in the copy that record a call; the control without -s calls all three),
#      creates no network or volume and runs exactly one docker container run; the agent joins what runs: with the Plane
#      and board networks, the substrate's network, its socket volume and its daemon container present, the start carries
#      both networks, the socket mount and BUILDKIT_HOST and the substrate join follows; with none present, one WARNING
#      each names what is not there and the full start that brings it (./stop.sh -s && ./run.sh), and the agent starts
#      without them, marked DOCKER_SUBSTRATE=not-running (not failed: nothing was tried); one part of the substrate missing
#      at a time - the daemon, the registry, the socket volume - is the substrate WARNING alone, the marker, no mount and
#      no join, while both boards are still joined; the preflight counts no network for -s on the docker target (PLANTED: a
#      docker with every address pool in use refuses the default start and lets -s through); ./run.sh -s <command> is an
#      interactive run with the command's words intact after the image (bash -c 'echo $HOME; touch planted-arg', nothing
#      run on the host); --single is -s; only a leading -s or --single is an option: ./run.sh -x runs -x in the container
#      and ./run.sh bash -s keeps -s as the command's word, as before; TO=compose: up -d --no-deps <the agent service> with
#      the base file re-rendered and the board's overlays added only when their rendered files exist, no ./kanban.sh init or
#      db-password (the control without -s renders the overlay, runs init and db-password and up -d of every service);
#      TO=swarm, kubernetes and sandbox refuse -s by name, exit 2, before anything runs

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
D=${BASE_DIR}/scratch/test-run
rm -rf "${D:?}"
mkdir -p "${D}/copy" "${D}/bin"

fail()
{
	echo "Test-run FAILED: $1"
	exit 1
}

cp "${BASE_DIR}/run.sh" "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${BASE_DIR}/env-local.sh" "${BASE_DIR}/preflight.sh" "${D}/copy/" \
	|| fail "could not copy run.sh and the files it reads"
cat > "${D}/bin/docker" << 'EOF'
#!/bin/bash
# test-run.sh's docker: a sound host for run.sh's preflight (no network in use); `container run` writes its words to
# ${STUB_ARGV} (NUL-separated) and exits ${STUB_RUN_RC} (default 0); `container inspect` prints ${STUB_STATE}, and
# with STUB_STATE unset knows no container
case "$1 $2" in
	"info "*) [ "$2" == "--format" ] && echo /var/lib/docker; exit 0 ;;
	"container run")
		shift 2
		printf '%s\0' "$@" > "${STUB_ARGV}"
		[ "${STUB_RUN_RC:-0}" == "0" ] || { echo "docker: Error response from daemon: planted failure" >&2; exit "${STUB_RUN_RC}"; }
		echo 0123456789abcdef
		exit 0
		;;
	"container inspect") [ -n "${STUB_STATE}" ] || { echo "Error: No such container" >&2; exit 1; }; echo "${STUB_STATE}"; exit 0 ;;
	# every network is a bridge network; `network connect` writes its words to ${STUB_ARGV}.connect and exits
	# ${STUB_CONNECT_RC} (default 0)
	"network inspect") [ "$3 $4" == "-f {{.Driver}}" ] && echo bridge; exit 0 ;;
	"network connect")
		shift 2
		printf '%s\0' "$@" > "${STUB_ARGV}.connect"
		[ "${STUB_CONNECT_RC:-0}" == "0" ] || { echo "Error response from daemon: planted connect failure" >&2; exit "${STUB_CONNECT_RC}"; }
		exit 0
		;;
	"container logs") echo "planted: the agent's last log line"; exit 0 ;;
esac
exit 0
EOF
chmod +x "${D}/bin/docker"

# local_env [<line>...] - the copy's .env.local: the test's container name, the boards and the docker spoke's build
# substrate off (so no sidecar starts), then the lines given
local_env()
{
	{ echo "export CONTAINER=test-run-agent"; echo "export UI_PLANE=false"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; printf '%s\n' "$@"; } > "${D}/copy/.env.local"
}
# start [NAME=value...] [-- <run.sh arguments>] - ./run.sh in the copy with the stub docker (${STUB_BIN}'s, when set)
# and those variables; its output in ${D}/run.out, the words docker container run got in ${D}/argv; prints run.sh's
# exit status
start()
{
	local VARS=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do VARS+=("$1"); shift; done
	[ "$1" == "--" ] && shift
	rm -f "${D:?}/argv" "${D:?}/argv.connect"
	( cd "${D}/copy" && env PATH="${STUB_BIN:-${D}/bin}:${PATH}" ENV_LOCAL_SETUP=false STUB_ARGV="${D}/argv" "${VARS[@]}" ./run.sh "$@" ) > "${D}/run.out" 2>&1
	echo $?
}
out() { tail -3 "${D}/run.out" | cut -c1-300 | tr '\n' ' '; }

# --- 1. a start that fails says so ---
local_env
RC=$(start STUB_RUN_RC=125 STUB_STATE="running 0")
[ "${RC}" == "125" ] || fail "1: run.sh exited ${RC} when docker refused the start (expected 125): $(out)"
grep -q "planted failure" "${D}/run.out" || fail "1: docker's own error is not in run.sh's output: $(out)"
grep -qxF "run.sh: ERROR - the start command exited 125 (the lines above name the cause); fix it, then ./stop.sh && ./run.sh" "${D}/run.out" \
	|| fail "1: no ERROR line naming the start command's exit 125: $(out)"
local_env 'export NETWORK="--net planted(paren"'
RC=$(start STUB_STATE="running 0")
[ "${RC}" == "2" ] || fail "1: run.sh exited ${RC} with a start command that does not parse (expected 2): $(out)"
grep -q "syntax error near unexpected token" "${D}/run.out" || fail "1: the shell's syntax error is not in run.sh's output: $(out)"
[ -e "${D}/argv" ] && fail "1: docker ran although the start command does not parse"
grep -qxF "run.sh: ERROR - the start command exited 2 (the lines above name the cause); fix it, then ./stop.sh && ./run.sh" "${D}/run.out" \
	|| fail "1: no ERROR line naming the exit 2 of a start command that does not parse: $(out)"
echo "ok 1 - a start that fails exits non-zero with docker's or the shell's error and one ERROR line: docker refusing it (125), a start command that does not parse (2, docker never ran)"

# --- 2. an agent container that is not running right after its start ---
local_env
RC=$(start STUB_STATE="exited 1")
[ "${RC}" == "1" ] || fail "2: run.sh exited ${RC} with the agent container exited right after its start (expected 1): $(out)"
grep -qxF "run.sh: ERROR - the agent container test-run-agent is not running right after its start (exited, exit code 1); its last log lines:" "${D}/run.out" \
	|| fail "2: no ERROR line naming the container and its state: $(out)"
grep -qxF "  planted: the agent's last log line" "${D}/run.out" || fail "2: the container's last log lines are not shown: $(out)"
RC=$(start)
[ "${RC}" == "1" ] && grep -qF "run.sh: ERROR - the agent container test-run-agent is not running right after its start (no such container)" "${D}/run.out" \
	|| fail "2: a container docker does not know after the start is not an ERROR (rc ${RC}): $(out)"
echo "ok 2 - an agent container not running right after its start: exit 1, one ERROR line with its state (exited, exit code 1; no such container) and its last log lines"

# --- 3. a sound start, and an interactive run ---
local_env
RC=$(start STUB_STATE="running 0")
[ "${RC}" == "0" ] || fail "3: run.sh exited ${RC} on a sound start (expected 0): $(out)"
grep -q "ERROR" "${D}/run.out" && fail "3: a sound start printed an ERROR line: $(grep ERROR "${D}/run.out")"
[ -s "${D}/argv" ] || fail "3: docker container run did not run: $(out)"
[ "$(tr '\0' '\n' < "${D}/argv" | tail -1)" == "do-agent-aws:latest" ] || fail "3: the start command's last word is not the image: $(tr '\0' ' ' < "${D}/argv" | tail -c 200)"
RC=$(start STUB_RUN_RC=3 -- bash)
[ "${RC}" == "3" ] || fail "3: an interactive run whose command exits 3 made run.sh exit ${RC}: $(out)"
grep -q "ERROR" "${D}/run.out" && fail "3: an interactive run's own exit status was reported as an ERROR: $(grep ERROR "${D}/run.out")"
[ "$(tr '\0' '\n' < "${D}/argv" | tail -2 | tr '\n' ' ')" == "do-agent-aws:latest bash " ] || fail "3: the interactive run's command is not after the image"
# PLANTED: a command whose words the host shell would expand and run
RC=$(start STUB_STATE="running 0" -- bash -c 'echo $HOME; touch planted-arg')
[ "${RC}" == "0" ] || fail "3: an interactive run of bash -c exited ${RC}: $(out)"
[ "$(tr '\0' '\n' < "${D}/argv" | tail -4 | tr '\n' '|')" == 'do-agent-aws:latest|bash|-c|echo $HOME; touch planted-arg|' ] \
	|| fail "3: the interactive run's command did not reach docker as its three words: $(tr '\0' '\n' < "${D}/argv" | tail -4 | tr '\n' '|')"
[ -e "${D}/copy/planted-arg" ] && fail "3: the interactive run's command ran on the host (planted-arg was created there)"
echo "ok 3 - a sound start exits 0 with no ERROR line, docker run once ending with the image; an interactive run exits with its command's status (3), no ERROR line, and its command reaches docker as its words, nothing of it run on the host"

# --- 4. LOOP_DECK_URL, checked before it reaches the start command ---
SHAPE_ENV=$(sed -n -E "s/^LOOP_DECK_URL_SHAPE='([^']+)'$/\1/p" "${BASE_DIR}/.env")
SHAPE_HOME=$(grep -F 'LOOP_DECK_URL}" | grep -qE' "${BASE_DIR}/Container-Root/agent/home-render.sh" | grep -oE "grep -qE '[^']+'" | sed -E "s/^grep -qE '//; s/'$//")
[ -n "${SHAPE_ENV}" ] || fail "4: .env has no LOOP_DECK_URL_SHAPE"
[ "${SHAPE_ENV}" == "${SHAPE_HOME}" ] || fail "4: .env's LOOP_DECK_URL pattern is not home-render.sh's: '${SHAPE_ENV}' vs '${SHAPE_HOME}'"
DECK_WARNING="WARNING: LOOP_DECK_URL is not a plain http(s)://host[:port][/path] URL; no Fleet Loop Deck tile (the served Loop Deck tile stays) - it is passed empty"
# deck_words - the LOOP_DECK_URL= words docker container run got, one per line (a NUL ends each word)
deck_words() { tr '\0' '\n' < "${D}/argv" | grep '^LOOP_DECK_URL='; }
local_env "export LOOP_DECK_URL='http://localhost:8091/'"
RC=$(start STUB_STATE="running 0")
[ "${RC}" == "0" ] || fail "4: run.sh exited ${RC} with a plain LOOP_DECK_URL: $(out)"
grep -qF "${DECK_WARNING}" "${D}/run.out" && fail "4: a plain LOOP_DECK_URL was refused"
[ "$(deck_words)" == "LOOP_DECK_URL=http://localhost:8091/" ] || fail "4: a plain LOOP_DECK_URL did not reach docker as given: $(deck_words | tr '\n' ' ')"
NL='
'
for BAD in 'javascript:alert(1)' 'ftp://localhost:8091/' "http://localhost:8091/${NL}<b>planted</b>" 'http://localhost:8091/"><script>x</script>'; do
	local_env "export LOOP_DECK_URL='${BAD}'"
	RC=$(start STUB_STATE="running 0")
	[ "${RC}" == "0" ] || fail "4: run.sh exited ${RC} with LOOP_DECK_URL='${BAD}' (the start must go on with it refused): $(out)"
	grep -qxF "${DECK_WARNING}" "${D}/run.out" || fail "4: no WARNING for LOOP_DECK_URL='${BAD}': $(out)"
	[ "$(deck_words)" == "LOOP_DECK_URL=" ] || fail "4: LOOP_DECK_URL='${BAD}' reached docker as: $(deck_words | tr '\n' ' ')"
	[ "$(tr '\0' '\n' < "${D}/argv" | tail -1)" == "do-agent-aws:latest" ] || fail "4: with LOOP_DECK_URL='${BAD}' the start command's last word is not the image"
done
echo "ok 4 - LOOP_DECK_URL: home-render.sh's pattern on the whole value; a plain http URL reaches docker as given, javascript:alert(1), ftp, a second line and markup are refused with the WARNING, passed empty, and the start goes on"

# --- 5. every setting's value reaches docker as one word, as written ---
# opts_lint <file> - the -e NAME=value switches on <file>'s option lines whose value is neither exactly
# $(shq "${VAR}") nor only letters, digits and _ . / : , = @ % + -, one a line. An allowlist: any other character can
# act under run.sh's eval (a $, a backquote, a quote or backslash, ; | & > <). Each exact shq call is first replaced by
# a marker the allowlist does not hold, so a marker with anything before or after it in the same word is flagged, and
# the line's closing quote is dropped with any comment after it, so a character left in a word is the value's own. A
# line that holds the marker's own text already is not substituted: a literal <SHQ> would pass for a shq call, so each
# of its -e words is flagged as it is
opts_lint()
{
	{
		grep -E '^[[:space:]]*export [A-Za-z0-9_]*_OPTS="' "$1" | grep -F '<SHQ>' | grep -oE -- '-e [A-Za-z_][A-Za-z0-9_]*=[^ ]*'
		grep -E '^[[:space:]]*export [A-Za-z0-9_]*_OPTS="' "$1" | grep -vF '<SHQ>' \
			| sed -E 's/\$\(shq "\$\{[A-Za-z_][A-Za-z0-9_]*\}"\)/<SHQ>/g; s/"[[:space:]]*(#.*)?$//' \
			| grep -oE -- '-e [A-Za-z_][A-Za-z0-9_]*=[^ ]*' \
			| grep -vxE -- '-e [A-Za-z_][A-Za-z0-9_]*=(<SHQ>|[A-Za-z0-9_./:,=@%+-]*)'
	} | sort -u
}
# PLANTED: the lint on lines of each unquoted form finds them all, and not the shq form or a literal, also one before a
# trailing comment
cat > "${D}/planted-opts" << 'OPTS'
export A_OPTS="-e A=prefix${X}"
export B_OPTS="-e B=$(other "${X}")"
export C_OPTS="-e C=$(shq "${X}") -e K=/wd/lit"
export D_OPTS="${D_OPTS} -e D=${X}"
export E_OPTS="-e E=$(shq "${X}")x$Y"
export F_OPTS="-e F=x$(shq "${X}")"
export G_OPTS="-e G=\"${X}\""
export H_OPTS="-e H=\"lit\" -e I=a\\b"
export J_OPTS="-e J=`id` -e M=a;b -e N=a|b"
export O_OPTS="-e O=a&b -e P=a>b -e Q=a<b"
export R_OPTS="-e R=lit -e S=" # literals before a trailing comment, "quoted"
export T_OPTS="-e T=<SHQ>"
OPTS
[ "$(opts_lint "${D}/planted-opts" | sed -E 's/=.*//' | tr '\n' ' ')" == "-e A -e B -e D -e E -e F -e G -e H -e I -e J -e M -e N -e O -e P -e Q -e T " ] \
	|| fail "5: the option lint does not find exactly the planted unquoted values A B D E F G H I J M N O P Q T: $(opts_lint "${D}/planted-opts" | tr '\n' '|')"
LEFT=$(opts_lint "${BASE_DIR}/.env")
[ -z "${LEFT}" ] || fail "5: .env passes a value shq does not quote: $(echo "${LEFT}" | tr '\n' ' ')"
cat > "${D}/planted-values" << 'PLANTED'
export AGENT_TMUX_CLAUDE_OPTS='--continue --verbose'
export UI_HOME_HOSTNAMES="it's(a);b"
export SLACK_TEST_CHANNEL='$(touch planted-subst) `touch planted-tick`'
export LOOP_DECK_URL='http://localhost:8091/#/loops?a=1&b=(2)'
PLANTED
# the words docker must get, one a line: the planted values as written, and two shipped values as they always read
cat > "${D}/planted-words" << 'WORDS'
AGENT_TMUX_CLAUDE_OPTS=--continue --verbose
UI_HOME_HOSTNAMES=it's(a);b
SLACK_TEST_CHANNEL=$(touch planted-subst) `touch planted-tick`
LOOP_DECK_URL=http://localhost:8091/#/loops?a=1&b=(2)
no_proxy=localhost,127.0.0.1
SLACK_CHANNELS=
WORDS
# words <argv file> - the words of a recorded docker command line, one a line (a NUL ends each word)
words() { tr '\0' '\n' < "$1"; }
local_env "$(cat "${D}/planted-values")"
RC=$(start STUB_STATE="running 0")
[ "${RC}" == "0" ] || fail "5: run.sh exited ${RC} with the planted values: $(out)"
while IFS= read -r W; do
	[ "$(words "${D}/argv" | grep -cxF -- "${W}")" == "1" ] || fail "5: docker did not get the one word '${W}': $(words "${D}/argv" | grep -F -- "${W%%=*}=" | tr '\n' '|')"
done < "${D}/planted-words"
[ -e "${D}/copy/planted-subst" ] || [ -e "${D}/copy/planted-tick" ] && fail "5: a planted value's \$(...) or backquotes ran"
[ "$(words "${D}/argv" | tail -1)" == "do-agent-aws:latest" ] || fail "5: with the planted values the start command's last word is not the image"
# test.sh, on a copy beside run.sh's: its other host-side tests stubbed, the same planted values, the same docker stub
mkdir -p "${D}/suite/Container-Root/test-lib" || fail "5: could not make the suite copy"
cp "${BASE_DIR}/test.sh" "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${D}/suite/" && cp "${BASE_DIR}/Container-Root/test-lib/wd-check.sh" "${D}/suite/Container-Root/test-lib/" \
	|| fail "5: could not copy test.sh and the files it reads"
# every host-side test test.sh runs, read from test.sh itself, so a test added there is stubbed here too
HOST_TESTS=$(grep -o '\./test-[a-z0-9-]*\.sh' "${BASE_DIR}/test.sh" | sort -u | sed 's#^\./##')
[ -n "${HOST_TESTS}" ] || fail "5: found no host-side test in test.sh to stub"
for T in ${HOST_TESTS}; do printf '#!/bin/bash\nexit 0\n' > "${D}/suite/${T}" && chmod +x "${D}/suite/${T}"; done
cp "${D}/copy/.env.local" "${D}/suite/.env.local"
rm -f "${D:?}/argv"
( cd "${D}/suite" && env PATH="${D}/bin:${PATH}" STUB_ARGV="${D}/argv" ./test.sh ) > "${D}/suite.out" 2>&1 || fail "5: test.sh on the copy exited non-zero: $(tail -3 "${D}/suite.out" | tr '\n' ' ')"
[ -s "${D}/argv" ] || fail "5: test.sh did not run docker container run: $(tail -3 "${D}/suite.out" | tr '\n' ' ')"
words "${D}/argv" | grep -qxF "TEST_CONTAINER=true" || fail "5: the recorded command is not the test container's"
while IFS= read -r W; do
	[ "$(words "${D}/argv" | grep -cxF -- "${W}")" == "1" ] || fail "5: test.sh did not give the test container the one word '${W}': $(words "${D}/argv" | grep -F -- "${W%%=*}=" | tr '\n' '|')"
done < "${D}/planted-words"
[ -e "${D}/suite/planted-subst" ] || [ -e "${D}/suite/planted-tick" ] && fail "5: a planted value's \$(...) or backquotes ran under test.sh"
echo "ok 5 - every setting's value is one word, as written: no -e NAME= value in .env with a \$ but not an exact shq call, the lint finding fifteen planted forms; a space, a quote, a parenthesis, a semicolon, \$(...), backquotes and a plain URL with # ? & ( ) reach docker as given from run.sh and from test.sh, nothing they spell runs, shipped values read as before"

# --- 6. COMMS_ENV_NAMES: names only ---
local_env 'export COMMS_ENV_NAMES="MY_TOKEN MY_CHANNELS"'
RC=$(start STUB_STATE="running 0")
[ "${RC}" == "0" ] || fail "6: run.sh exited ${RC} with two names in COMMS_ENV_NAMES: $(out)"
tr '\0' ' ' < "${D}/argv" | grep -qF ' -e MY_TOKEN -e MY_CHANNELS ' || fail "6: the two names did not reach docker as -e NAME -e NAME"
NAMES_ERROR="ERROR: a COMMS_ENV_NAMES entry is not an environment-variable name (letters, digits and _, not starting with a digit); the entry is not shown, in case it is a value. List only names."
# PLANTED: a file whose name is a variable name, beside the copy's run.sh, that the glob PLANTEDNAM? matches
touch "${D}/copy/PLANTEDNAME"
for BAD in 'MY_TOKEN A(B' 'MY_TOKEN a;b' 'MY_TOKEN 9LIVES' 'MY_TOKEN PLANTEDNAM?'; do
	local_env "export COMMS_ENV_NAMES='${BAD}'"
	RC=$(start STUB_STATE="running 0")
	[ "${RC}" == "1" ] || fail "6: run.sh exited ${RC} with COMMS_ENV_NAMES='${BAD}' (expected 1): $(out)"
	grep -qxF "${NAMES_ERROR}" "${D}/run.out" || fail "6: no ERROR line for COMMS_ENV_NAMES='${BAD}': $(out)"
	grep -qF "${BAD#MY_TOKEN }" "${D}/run.out" && fail "6: the refused entry '${BAD#MY_TOKEN }' is shown in run.sh's output"
	[ -e "${D}/argv" ] && fail "6: docker ran although COMMS_ENV_NAMES='${BAD}' was refused"
done
rm -f "${D:?}/copy/PLANTEDNAME"
echo "ok 6 - COMMS_ENV_NAMES: two names reach docker as -e NAME -e NAME; an entry with a parenthesis, a semicolon, a leading digit or a glob that matches a file stops the start before docker runs (exit 1), its ERROR line not showing it"

# --- 7. the kanban board's network, joined once the agent container runs ---
# the board on, a network of the user's own; kanban.sh is a stub that starts nothing
cat > "${D}/copy/kanban.sh" << 'STUB'
#!/bin/bash
echo "kanban: planted $*"
exit 0
STUB
chmod +x "${D}/copy/kanban.sh"
local_env 'export UI_VIBE_KANBAN=true' 'export NETWORK="--network test-run-net"'
JOIN_WARNING="WARNING: the agent container test-run-agent runs, but it could not join test-run-agent-kanban (the line above names the cause) - it runs without the kanban board; ./stop.sh && ./run.sh tries again"
# PLANTED: docker refuses the join
RC=$(start STUB_STATE="running 0" STUB_CONNECT_RC=1)
[ "${RC}" == "0" ] || fail "7: run.sh exited ${RC} when the running agent container could not join the board's network (expected 0): $(out)"
grep -q "planted connect failure" "${D}/run.out" || fail "7: docker's own error for the join is not in run.sh's output: $(out)"
grep -qxF "${JOIN_WARNING}" "${D}/run.out" || fail "7: no WARNING for the join that failed: $(out)"
grep -q "ERROR" "${D}/run.out" && fail "7: a join that failed after a sound start printed an ERROR line: $(grep ERROR "${D}/run.out")"
# an agent container not running after its start: the ERROR, and no join
RC=$(start STUB_STATE="exited 1" STUB_CONNECT_RC=1)
[ "${RC}" == "1" ] && grep -qF "run.sh: ERROR - the agent container test-run-agent is not running right after its start (exited, exit code 1)" "${D}/run.out" \
	|| fail "7: an agent container not running after its start, with the board's network to join, is not the ERROR with exit 1 (rc ${RC}): $(out)"
[ -e "${D}/argv.connect" ] && fail "7: run.sh tried the join although the agent container was not running"
# a sound join
RC=$(start STUB_STATE="running 0")
[ "${RC}" == "0" ] || fail "7: run.sh exited ${RC} on a sound start and join: $(out)"
[ "$(tr '\0' ' ' < "${D}/argv.connect" 2>/dev/null)" == "test-run-agent-kanban test-run-agent " ] || fail "7: the join did not get the board's network and the agent container: $(tr '\0' ' ' < "${D}/argv.connect" 2>&1)"
grep -qF "WARNING: the agent container" "${D}/run.out" && fail "7: a sound join printed the WARNING"
tr '\0' ' ' < "${D}/argv" | grep -qF ' --network test-run-net ' || fail "7: the agent container did not start on NETWORK"
# PLANTED: a board network name with shell syntax (KANBAN_NETWORK in .env.local): the join is a direct docker call
local_env 'export UI_VIBE_KANBAN=true' 'export NETWORK="--network test-run-net"' "export KANBAN_NETWORK='test-run-net2;touch planted-join'"
rm -f "${D:?}/copy/planted-join"
RC=$(start STUB_STATE="running 0")
[ "${RC}" == "0" ] || fail "7: run.sh exited ${RC} with a board network name holding shell syntax: $(out)"
[ -e "${D}/copy/planted-join" ] && fail "7: the join ran a command from the board network's name (planted-join was created)"
[ "$(tr '\0' '|' < "${D}/argv.connect" 2>/dev/null)" == "test-run-net2;touch planted-join|test-run-agent|" ] \
	|| fail "7: the join did not get the board network's name as one word: $(tr '\0' '|' < "${D}/argv.connect" 2>&1)"
# VERBOSE prints the join as the shell would read it
grep -qxF 'docker network connect test-run-net2\;touch\ planted-join test-run-agent' "${D}/run.out" \
	|| fail "7: VERBOSE does not print the join with the network's name quoted: $(grep '^docker network connect' "${D}/run.out")"
echo "ok 7 - the board's network is joined once the agent container runs: a refused join is one WARNING (exit 0, no ERROR); a container not running is the ERROR (exit 1) with no join; a sound join gets the network and the container, a network name with shell syntax as one word, nothing of it run"

# --- 8. the board join is run.sh's own ---
# PLANTED: the join's variables, the former and the present, in the caller's environment, on the swarm target, which
# never sets them (the copy has no compose template, so the line saying so is expected; the deploy goes to the docker
# stub)
local_env 'export TO=swarm'
rm -f "${D:?}/copy/planted-connect"
RC=$(start KANBAN_CONNECT="touch planted-connect" KANBAN_JOIN_NETWORK=planted-net)
[ "${RC}" == "0" ] || fail "8: run.sh exited ${RC} on the swarm target with the docker stub: $(out)"
[ -e "${D}/copy/planted-connect" ] && fail "8: run.sh ran a KANBAN_CONNECT from the caller's environment on the swarm target (planted-connect was created)"
[ -e "${D}/argv.connect" ] && fail "8: run.sh joined a network from the caller's environment on the swarm target: $(tr '\0' ' ' < "${D}/argv.connect")"
echo "ok 8 - the board join is run.sh's own: values in the caller's environment run nothing and join nothing on the swarm target"

# --- 9. the kanban board's network names, on the path without NETWORK ---
# PLANTED: both network names with shell syntax; the real kanban.sh in the copy (check 7's stub replaced), up with the
# relay on and then down, under a docker that keeps the networks it creates
cp "${BASE_DIR}/kanban.sh" "${D}/copy/kanban.sh" || fail "9: could not copy kanban.sh"
mkdir -p "${D}/bin9" "${D}/nets9"
cat > "${D}/bin9/docker" << 'STUB9'
#!/bin/bash
# test-run.sh check 9's docker: a sound host for the preflight; a network exists from its create to its rm (a file per
# name under ${STUB_NETS}, named by the name's hash); each network create, connect and rm, and each container run, is a
# line of ${STUB_NETS}/calls, every word followed by "|"; a container does not exist (exists() reads it so) and, once
# run, is running and healthy on no network; a label reads ${STUB_OWNER}; the last container run's words go to
# ${STUB_ARGV} (NUL-separated)
mark() { printf '%s' "$1" | sha256sum | cut -c1-16; }
call() { printf '%s|' "$@" >> "${STUB_NETS}/calls"; echo >> "${STUB_NETS}/calls"; }
case "$1 $2" in
	"info "*) [ "$2" == "--format" ] && echo /var/lib/docker; exit 0 ;;
	"network inspect")
		if [ "$3" == "-f" ]; then
			case "$4" in *Labels*) echo "${STUB_OWNER}" ;; esac
			exit 0
		fi
		[ -e "${STUB_NETS}/$(mark "$3")" ]
		exit $?
		;;
	"network create") call "$@"; touch "${STUB_NETS}/$(mark "${!#}")"; exit 0 ;;
	"network connect") call "$@"; exit 0 ;;
	"network rm") call "$@"; M=$(mark "$3"); rm -f "${STUB_NETS:?}/${M:?}"; exit 0 ;;
	"container inspect")
		[ "$3" == "-f" ] || exit 1
		case "$4" in
			*Health*) echo "running healthy" ;;
			*ExitCode*) echo "running 0" ;;
			*Labels*) echo "${STUB_OWNER}" ;;
		esac
		exit 0
		;;
	"container run")
		call "$@"
		shift 2
		printf '%s\0' "$@" > "${STUB_ARGV}"
		echo 0123456789abcdef
		exit 0
		;;
esac
exit 0
STUB9
chmod +x "${D}/bin9/docker"
# each name ends its command where an eval reads it, runs a touch and comments out the rest of the line
NET9='kbnet;touch planted-kb #'
INT9='kbint;touch planted-ki #'
local_env 'export UI_VIBE_KANBAN=true' 'export UI_KANBAN_RELAY=true' "export KANBAN_NETWORK='${NET9}'" "export KANBAN_INTERNAL_NETWORK='${INT9}'"
rm -f "${D:?}/copy/planted-kb" "${D:?}/copy/planted-ki" "${D:?}/nets9/calls"
RC=$(STUB_BIN="${D}/bin9" start STUB_NETS="${D}/nets9" STUB_OWNER=test-run-agent)
[ "${RC}" == "0" ] || fail "9: run.sh exited ${RC} with the board on and its network names holding shell syntax: $(out)"
grep -q "kanban: board up" "${D}/run.out" || fail "9: kanban.sh up did not finish: $(grep '^kanban' "${D}/run.out" | tail -3 | tr '\n' ' ')"
( cd "${D}/copy" && env PATH="${D}/bin9:${PATH}" STUB_NETS="${D}/nets9" STUB_OWNER=test-run-agent STUB_ARGV="${D}/argv9-down" ./kanban.sh down ) > "${D}/down9.out" 2>&1 \
	|| fail "9: kanban.sh down exited non-zero: $(tail -3 "${D}/down9.out" | tr '\n' ' ')"
[ -e "${D}/copy/planted-kb" ] || [ -e "${D}/copy/planted-ki" ] && fail "9: a board network's name ran as a command ($(cd "${D}/copy" && echo planted-k*))"
# each call that names a network got it as one word
for W in "network|create|--label|do-agent-aws.kanban=test-run-agent|${NET9}|" "network|create|--internal|--label|do-agent-aws.kanban=test-run-agent|${INT9}|" \
	"network|connect|--alias|kanban-server|${NET9}|test-run-agent-kanban-server|" "network|connect|--alias|kanban-relay|${NET9}|test-run-agent-kanban-relay|" \
	"network|rm|${NET9}|" "network|rm|${INT9}|"; do
	grep -qxF -- "${W}" "${D}/nets9/calls" || fail "9: no docker call ${W} (the network's name as one word): $(cut -c1-120 "${D}/nets9/calls" | tr '\n' ' ')"
done
[ "$(grep -c "^container|run|.*|--network|${INT9}|--network-alias|" "${D}/nets9/calls")" == "4" ] \
	|| fail "9: the four sidecars did not each get the internal network's name as one word: $(grep '^container|run|' "${D}/nets9/calls" | cut -c1-120 | tr '\n' ' ')"
tr '\0' '|' < "${D}/argv" | grep -qF "|--network|${NET9}|" || fail "9: the agent's start command did not get the board network's name as one word: $(tr '\0' ' ' < "${D}/argv" | grep -o -- '--network [^ ]*' | tr '\n' ' ')"
echo "ok 9 - the board's network names with shell syntax, without NETWORK: kanban.sh's network create, connect and rm, the four sidecars and the agent's start command each get a name as one word, and nothing either name spells runs"

# --- 10. the docker spoke's build substrate: its names, and the agent's join ---
# PLANTED: the substrate's two network names and its socket volume's name with shell syntax; the real docker.sh in the
# copy, up under a docker that keeps the networks and volumes it creates; the agent container joins the internal network
# once it runs, a direct docker call
cp "${BASE_DIR}/docker.sh" "${D}/copy/docker.sh" || fail "10: could not copy docker.sh"
mkdir -p "${D}/bin10" "${D}/state10"
cat > "${D}/bin10/docker" << 'STUB10'
#!/bin/bash
# test-run.sh check 10's docker: a sound host for the preflight; a network or a volume exists from its create (a file per
# name under ${STUB_STATE10}, named by the name's hash); each network create and connect, volume create and container run
# is a line of ${STUB_STATE10}/calls, every word followed by "|"; a container does not exist until it is run, then reads
# running and healthy; a label reads ${STUB_OWNER}; network connect exits ${STUB_CONNECT_RC} (default 0), network create
# ${STUB_NETCREATE_RC} (default 0); the last container run's words go to ${STUB_ARGV} (NUL-separated); a container named
# in ${STUB_EXISTING} exists (a plain inspect and an exec answer for it), and each container rm is a line of the calls
mark() { printf '%s' "$1" | sha256sum | cut -c1-16; }
call() { printf '%s|' "$@" >> "${STUB_STATE10}/calls"; echo >> "${STUB_STATE10}/calls"; }
case "$1 $2" in
	"info "*) [ "$2" == "--format" ] && echo /var/lib/docker; exit 0 ;;
	"image inspect") [ "$3" == "-f" ] && echo sha256:stub; exit 0 ;;
	"network inspect"|"volume inspect")
		if [ "$3" == "-f" ]; then
			case "$4" in *Labels*) echo "${STUB_OWNER}" ;; *Internal*) echo true ;; *Driver*) echo bridge ;; esac
			exit 0
		fi
		[ -e "${STUB_STATE10}/n-$(mark "$3")" ]
		exit $?
		;;
	"network create"|"volume create")
		call "$@"
		[ "$1" == "network" ] && [ "${STUB_NETCREATE_RC:-0}" != "0" ] && { echo "Error response from daemon: planted create failure" >&2; exit "${STUB_NETCREATE_RC}"; }
		touch "${STUB_STATE10}/n-$(mark "${!#}")"
		exit 0
		;;
	"network connect")
		call "$@"
		[ "${STUB_CONNECT_RC:-0}" == "0" ] || { echo "Error response from daemon: planted connect failure" >&2; exit "${STUB_CONNECT_RC}"; }
		exit 0
		;;
	"container inspect")
		if [ "$3" != "-f" ]; then
			case " ${STUB_EXISTING:-} " in *" $3 "*) exit 0 ;; esac
			exit 1
		fi
		case "$4" in
			*Health*) echo "running healthy" ;;
			*ExitCode*) echo "running 0" ;;
			*Labels*) echo "${STUB_OWNER}" ;;
		esac
		exit 0
		;;
	"container rm") call "$@"; exit 0 ;;
	"container exec")
		case " ${STUB_EXISTING:-} " in *" $3 "*) exit 0 ;; esac
		exit 1
		;;
	"container run")
		call "$@"
		shift 2
		printf '%s\0' "$@" > "${STUB_ARGV}"
		echo 0123456789abcdef
		exit 0
		;;
esac
exit 0
STUB10
chmod +x "${D}/bin10/docker"
cat > "${D}/bin10/sysctl" << 'SYSCTL10'
#!/bin/bash
# test-run.sh checks 10 and 11's sysctl: kernel.apparmor_restrict_unprivileged_userns reads ${STUB_USERNS} (default 0,
# so the checks never read the real host's kernel); any other key is unknown
[ "$1" == "-n" ] && [ "$2" == "kernel.apparmor_restrict_unprivileged_userns" ] && { echo "${STUB_USERNS:-0}"; exit 0; }
echo "sysctl: cannot stat /proc/sys/${2//.//}: No such file or directory" >&2
exit 255
SYSCTL10
chmod +x "${D}/bin10/sysctl"
# each name ends its command where an eval reads it, runs a touch and comments out the rest of the line
DN10='dknet;touch planted-dn #'
DB10='dkbuild;touch planted-db #'
DV10='dksock;touch planted-dv #'
local_env 'export SPOKE_DOCKER=true' "export DOCKER_NETWORK='${DN10}'" "export DOCKER_BUILD_NETWORK='${DB10}'" "export DOCKER_SOCKET_VOLUME='${DV10}'"
rm -f "${D:?}/copy/planted-dn" "${D:?}/copy/planted-db" "${D:?}/copy/planted-dv" "${D:?}/state10/calls"
RC=$(STUB_BIN="${D}/bin10" start STUB_STATE10="${D}/state10" STUB_OWNER=test-run-agent)
[ "${RC}" == "0" ] || fail "10: run.sh exited ${RC} with the substrate on and its names holding shell syntax: $(out)"
grep -q "^docker: build substrate up" "${D}/run.out" || fail "10: ./docker.sh up did not finish: $(grep '^docker' "${D}/run.out" | tail -3 | tr '\n' ' ')"
for F in planted-dn planted-db planted-dv; do
	[ -e "${D}/copy/${F}" ] && fail "10: a substrate name ran as a command (${F} was created)"
done
# each call that names a network or the socket volume got it as one word
for W in "network|create|--label|do-agent-aws.docker=test-run-agent|${DB10}|" \
	"network|create|--label|do-agent-aws.docker=test-run-agent|--internal|${DN10}|" \
	"volume|create|--label|do-agent-aws.docker=test-run-agent|--driver|local|--opt|type=tmpfs|--opt|device=tmpfs|--opt|o=uid=1000,gid=1000,mode=0700,size=1m|${DV10}|" \
	"network|connect|${DN10}|test-run-agent|"; do
	grep -qxF -- "${W}" "${D}/state10/calls" || fail "10: no docker call ${W} (the name as one word): $(cut -c1-140 "${D}/state10/calls" | tr '\n' ' ')"
done
grep -qF -- "|--network|name=${DB10},alias=registry|--network|name=${DN10},alias=registry|" "${D}/state10/calls" \
	|| fail "10: the registry did not get both network names as one word each: $(grep '^container|run|' "${D}/state10/calls" | cut -c1-160 | tr '\n' ' ')"
grep -qF -- "|--network|${DB10}|--security-opt|" "${D}/state10/calls" && grep -qF -- "|-v|${DV10}:/run/user/1000/buildkit|" "${D}/state10/calls" \
	|| fail "10: the daemon did not get its network and the socket volume as one word each"
tr '\0' '|' < "${D}/argv" | grep -qF -- "|--mount|type=volume,src=${DV10},dst=/run/buildkit|" \
	|| fail "10: the agent's start command did not get the socket volume in one --mount word: $(tr '\0' ' ' < "${D}/argv" | cut -c1-200)"
# VERBOSE prints the join as the shell would read it (the name quoted)
grep -qxF 'docker network connect dknet\;touch\ planted-dn\ # test-run-agent' "${D}/run.out" \
	|| fail "10: VERBOSE does not print the substrate join with the network's name quoted: $(grep '^docker network connect' "${D}/run.out")"
# PLANTED: docker refuses the join - one WARNING, exit 0, no ERROR
RC=$(STUB_BIN="${D}/bin10" start STUB_STATE10="${D}/state10" STUB_OWNER=test-run-agent STUB_CONNECT_RC=1)
[ "${RC}" == "0" ] || fail "10: run.sh exited ${RC} when the running agent could not join the substrate's network (expected 0): $(out)"
grep -qF "WARNING: the agent container test-run-agent runs, but it could not join ${DN10} (the line above names the cause)" "${D}/run.out" \
	|| fail "10: no WARNING for the substrate join that failed: $(out)"
grep -q "ERROR" "${D}/run.out" && fail "10: a refused substrate join printed an ERROR line: $(grep ERROR "${D}/run.out")"
# PLANTED: ./docker.sh up fails (docker refuses the network create, a state with no network yet): one WARNING, the agent
# started without the substrate and marked for its rows, no join, exit 0
mkdir -p "${D}/state10f"
rm -f "${D:?}/state10f/calls"
RC=$(STUB_BIN="${D}/bin10" start STUB_STATE10="${D}/state10f" STUB_OWNER=test-run-agent STUB_NETCREATE_RC=1)
[ "${RC}" == "0" ] || fail "10: run.sh exited ${RC} when ./docker.sh up failed (expected 0: the agent starts without the substrate): $(out)"
grep -qF "WARNING: the build substrate did not come up" "${D}/run.out" || fail "10: no WARNING when ./docker.sh up failed: $(out)"
[ -s "${D}/argv" ] || fail "10: the agent container was not started when ./docker.sh up failed: $(out)"
tr '\0' '|' < "${D}/argv" | grep -qF -- "|-e|DOCKER_SUBSTRATE=failed|" \
	|| fail "10: the agent's start command does not carry DOCKER_SUBSTRATE=failed when ./docker.sh up failed: $(tr '\0' ' ' < "${D}/argv" | cut -c1-200)"
tr '\0' '|' < "${D}/argv" | grep -qE -- "dst=/run/buildkit|BUILDKIT_HOST=" \
	&& fail "10: the agent's start command mounts the daemon's socket or passes BUILDKIT_HOST although ./docker.sh up failed"
grep -q "^network|connect|" "${D}/state10f/calls" && fail "10: run.sh joined the substrate's network although ./docker.sh up failed"
# PLANTED: the join's variables, the former and the present, in the caller's environment, on the swarm target, which
# never sets them
local_env 'export TO=swarm'
rm -f "${D:?}/copy/planted-dconnect"
RC=$(start DOCKER_CONNECT="touch planted-dconnect" DOCKER_JOIN_NETWORK=planted-dnet)
[ "${RC}" == "0" ] || fail "10: run.sh exited ${RC} on the swarm target with the docker stub: $(out)"
[ -e "${D}/copy/planted-dconnect" ] && fail "10: run.sh ran a DOCKER_CONNECT from the caller's environment (planted-dconnect was created)"
[ -e "${D}/argv.connect" ] && fail "10: run.sh joined a network from the caller's environment on the swarm target: $(tr '\0' ' ' < "${D}/argv.connect")"
echo "ok 10 - the docker spoke's build substrate with its network and socket-volume names holding shell syntax: the network create, the volume create, the sidecars' --network and -v and the agent's --mount each get the name as one word and nothing it spells runs; the agent joins the internal network once it runs, a direct docker call, VERBOSE prints it quoted, a refused join is one WARNING (exit 0, no ERROR); the join is run.sh's own (caller values do nothing on swarm); a ./docker.sh up that fails leaves the agent started without the substrate, marked DOCKER_SUBSTRATE=failed"

# --- 11. a host that restricts unprivileged user namespaces: no sidecar starts, the agent does ---
# PLANTED: check 10's stub sysctl answers kernel.apparmor_restrict_unprivileged_userns=1, in a state with no network or
# volume yet and the daemon's container left from an earlier start (ours): ./docker.sh up names the setting and both
# host-owner options, removes that daemon, and creates and runs nothing; run.sh warns, starts the agent without the
# substrate (no socket volume, no BUILDKIT_HOST, no join), marked DOCKER_SUBSTRATE=failed, and exits 0; ./docker.sh
# status names the setting too. CONTROL: the same start with the setting at 0 starts both sidecars, as before
local_env 'export SPOKE_DOCKER=true'
mkdir -p "${D}/state11"
rm -f "${D:?}/state11/calls" "${D:?}/state11/"n-*
RC=$(STUB_BIN="${D}/bin10" start STUB_STATE10="${D}/state11" STUB_OWNER=test-run-agent STUB_USERNS=1 STUB_EXISTING=test-run-agent-buildkit)
[ "${RC}" == "0" ] || fail "11: run.sh exited ${RC} on a host that restricts unprivileged user namespaces (expected 0: the agent starts without the substrate): $(out)"
for S in buildkit registry; do
	grep -qF -- "|--name|test-run-agent-${S}|" "${D}/state11/calls" && fail "11: the ${S} sidecar was started on a host that restricts unprivileged user namespaces: $(grep -F -- "|--name|test-run-agent-${S}|" "${D}/state11/calls" | cut -c1-160)"
done
grep -qE '^(network|volume)\|create\|' "${D}/state11/calls" && fail "11: a network or a volume of the substrate was created on a host that restricts unprivileged user namespaces"
grep -qF "docker: not starting the build substrate - the host restricts unprivileged user namespaces (kernel.apparmor_restrict_unprivileged_userns=1)" "${D}/run.out" \
	&& grep -qF "persist kernel.apparmor_restrict_unprivileged_userns=0 in a file under /etc/sysctl.d" "${D}/run.out" && grep -qF "or set SPOKE_DOCKER=false in .env.local" "${D}/run.out" \
	|| fail "11: the start does not name the restriction and both options: $(grep '^docker' "${D}/run.out" | tr '\n' ' ' | cut -c1-300)"
grep -qF "WARNING: the build substrate did not come up" "${D}/run.out" || fail "11: run.sh did not warn that the substrate did not come up: $(out)"
grep -qxF 'container|rm|-f|-v|test-run-agent-buildkit|' "${D}/state11/calls" \
	|| fail "11: the daemon's container left from an earlier start was not removed, so it would go on restarting: $(tr '\n' ' ' < "${D}/state11/calls" | cut -c1-200)"
[ -s "${D}/argv" ] || fail "11: the agent container was not started on a host that restricts unprivileged user namespaces: $(out)"
tr '\0' '|' < "${D}/argv" | grep -qF -- "|-e|DOCKER_SUBSTRATE=failed|" \
	|| fail "11: the agent's start command does not carry DOCKER_SUBSTRATE=failed: $(tr '\0' ' ' < "${D}/argv" | cut -c1-200)"
tr '\0' '|' < "${D}/argv" | grep -qE -- "dst=/run/buildkit|BUILDKIT_HOST=" \
	&& fail "11: the agent's start command mounts the daemon's socket or passes BUILDKIT_HOST on a host that restricts unprivileged user namespaces"
grep -q "^network|connect|" "${D}/state11/calls" && fail "11: run.sh joined the substrate's network on a host that restricts unprivileged user namespaces"
( cd "${D}/copy" && env PATH="${D}/bin10:${PATH}" STUB_STATE10="${D}/state11" STUB_OWNER=test-run-agent STUB_USERNS=1 ./docker.sh status ) > "${D}/status11.out" 2>&1
grep -qF "daemon test-run-agent-buildkit: not running - the host restricts unprivileged user namespaces (kernel.apparmor_restrict_unprivileged_userns=1)" "${D}/status11.out" \
	&& grep -qF "or set SPOKE_DOCKER=false in .env.local" "${D}/status11.out" \
	|| fail "11: ./docker.sh status does not name the restriction and the options for the daemon: $(tr '\n' ' ' < "${D}/status11.out" | cut -c1-300)"
# CONTROL: the setting at 0 - both sidecars start, as before
rm -f "${D:?}/state11/calls" "${D:?}/state11/"n-*
RC=$(STUB_BIN="${D}/bin10" start STUB_STATE10="${D}/state11" STUB_OWNER=test-run-agent STUB_USERNS=0)
[ "${RC}" == "0" ] || fail "11: CONTROL: run.sh exited ${RC} with kernel.apparmor_restrict_unprivileged_userns=0: $(out)"
grep -q "^docker: build substrate up" "${D}/run.out" || fail "11: CONTROL: with the setting at 0 the substrate did not come up: $(grep '^docker' "${D}/run.out" | tail -3 | tr '\n' ' ')"
for S in buildkit registry; do
	grep -qF -- "|--name|test-run-agent-${S}|" "${D}/state11/calls" || fail "11: CONTROL: with the setting at 0 the ${S} sidecar was not started"
done
grep -q "not starting the build substrate" "${D}/run.out" && fail "11: CONTROL: with the setting at 0 the start still says it does not start the substrate"
echo "ok 11 - a host that restricts unprivileged user namespaces (a stub sysctl at 1): ./docker.sh up names kernel.apparmor_restrict_unprivileged_userns=1 and both options, removes a daemon left from an earlier start and starts no sidecar, creates no network or volume; run.sh warns and starts the agent without the substrate, marked DOCKER_SUBSTRATE=failed, no join, exit 0; ./docker.sh status names the setting; at 0 both sidecars start as before"

# --- 12. -s / --single: the agent container alone, joining what runs ---
# PLANTED: stubs of plane.sh, kanban.sh and docker.sh in the copy (check 9 and 10's real ones replaced) that record each
# call to ${STUB_SIDE} and start nothing; a docker (bin12) under which a network, a volume or a container exists only when
# the check planted it (a file per name under ${STUB_STATE12}), every call recorded, the daemon's container running when
# planted; the compose templates in the copy, so the compose target renders its files
for S in plane kanban docker; do
	printf '#!/bin/bash\necho "%s|$*" >> "${STUB_SIDE}"\nexit 0\n' "${S}.sh" > "${D}/copy/${S}.sh" && chmod +x "${D}/copy/${S}.sh" || fail "12: could not plant the ${S}.sh stub"
done
mkdir -p "${D}/bin12" "${D}/state12" "${D}/copy/to/compose/template"
cp "${BASE_DIR}/to/compose/template/docker-compose.yaml" "${BASE_DIR}/to/compose/template/docker-compose.kanban.yaml" "${D}/copy/to/compose/template/" \
	|| fail "12: could not copy the compose templates"
cat > "${D}/bin12/docker" << 'STUB12'
#!/bin/bash
# test-run.sh check 12's docker: every call is a line of ${STUB_STATE12}/calls, each word followed by "|"; a network or a
# volume exists when a file named by its name's hash is under ${STUB_STATE12}; a container exists, and runs, when it is
# named in ${STUB_EXISTING}, and once run reads running; a label reads ${STUB_OWNER}; network ls lists ${STUB_NETS_USED}
# (default 0) bridge networks, for the preflight; the last container run's words go to ${STUB_ARGV} (NUL-separated)
mark() { printf '%s' "$1" | sha256sum | cut -c1-16; }
printf '%s|' "$@" >> "${STUB_STATE12}/calls"; echo >> "${STUB_STATE12}/calls"
case "$1 $2" in
	"info "*) [ "$2" == "--format" ] && echo /var/lib/docker; exit 0 ;;
	"network ls") seq 1 "${STUB_NETS_USED:-0}" 2> /dev/null | sed 's/^/stub-net-/'; exit 0 ;;
	"network inspect"|"volume inspect")
		if [ "$3" == "-f" ]; then
			case "$4" in *Labels*) echo "${STUB_OWNER}" ;; *Internal*) echo true ;; *Driver*) echo bridge ;; esac
			exit 0
		fi
		[ -e "${STUB_STATE12}/n-$(mark "$3")" ]
		exit $?
		;;
	"container inspect")
		if [ "$3" != "-f" ]; then
			case " ${STUB_EXISTING:-} " in *" $3 "*) exit 0 ;; esac
			exit 1
		fi
		case "$4" in
			*Running*) case " ${STUB_EXISTING:-} " in *" $5 "*) echo true ;; *) echo false ;; esac ;;
			*Health*) echo "running healthy" ;;
			*ExitCode*) echo "running 0" ;;
			*Labels*) echo "${STUB_OWNER}" ;;
		esac
		exit 0
		;;
	"network connect") exit 0 ;;
	"container run")
		shift 2
		printf '%s\0' "$@" > "${STUB_ARGV}"
		echo 0123456789abcdef
		exit 0
		;;
esac
exit 0
STUB12
# the compose target's cli, recording its words the same way (DOCKER_COMPOSE's default name)
printf '#!/bin/bash\nprintf '"'"'%%s|'"'"' docker-compose "$@" >> "${STUB_STATE12}/calls"; echo >> "${STUB_STATE12}/calls"\nexit 0\n' > "${D}/bin12/docker-compose"
chmod +x "${D}/bin12/docker" "${D}/bin12/docker-compose"
mark12() { printf '%s' "$1" | sha256sum | cut -c1-16; }
# plant12 <name>... - these networks and volumes exist under bin12; none otherwise
plant12() { rm -f "${D:?}/state12/"n-* "${D:?}/state12/calls" "${D:?}/side"; for N in "$@"; do : > "${D}/state12/n-$(mark12 "${N}")"; done; }
# start12 [NAME=value...] [-- <run.sh arguments>] - start under bin12 with the planted state and the side-script log
start12() { STUB_BIN="${D}/bin12" start STUB_STATE12="${D}/state12" STUB_OWNER=test-run-agent STUB_SIDE="${D}/side" "$@"; }
calls12() { [ -f "${D}/state12/calls" ] && cat "${D}/state12/calls"; }
side12() { [ -f "${D}/side" ] && cat "${D}/side"; }
argv12() { tr '\0' '|' < "${D}/argv"; }
SINGLE_LINE="run.sh: -s - starting the agent container alone: no board and no build substrate is started, the agent joins the ones that run (./stop.sh -s && ./run.sh starts them)"
SINGLE_LINE_COMPOSE="run.sh: -s - starting the agent service alone: no other service is started (./run.sh without -s starts every service)"
SUBSTRATE_WARNING="WARNING: the build substrate is not running - the agent starts without it (./docker.sh status shows the sidecars; ./stop.sh -s && ./run.sh starts them)"
local_env 'export UI_PLANE=true' 'export UI_VIBE_KANBAN=true' 'export SPOKE_DOCKER=true'
# (a) everything runs: both boards' networks, the substrate's network, socket volume and daemon
ALL_UP=(test-run-agent-plane test-run-agent-kanban test-run-agent-docker test-run-agent-buildkit-socket)
for FLAG in -s --single; do
	plant12 "${ALL_UP[@]}"
	RC=$(start12 STUB_EXISTING="test-run-agent-buildkit test-run-agent-registry" -- "${FLAG}")
	[ "${RC}" == "0" ] || fail "12: run.sh ${FLAG} exited ${RC} with every sidecar running (expected 0): $(out)"
	[ -e "${D}/side" ] && fail "12: run.sh ${FLAG} ran a sidecar script: $(side12 | tr '\n' ' ')"
	[ "$(calls12 | grep -c '^container|run|')" == "1" ] || fail "12: run.sh ${FLAG} ran docker container run $(calls12 | grep -c '^container|run|') times, not once"
	calls12 | grep -qE '^(network|volume)\|create\|' && fail "12: run.sh ${FLAG} created a network or a volume: $(calls12 | grep -E '^(network|volume)\|create\|' | tr '\n' ' ')"
	argv12 | grep -qF -- "|-d|" || fail "12: run.sh ${FLAG} is not a detached run (-d): $(argv12 | cut -c1-200)"
	[ "$(tr '\0' '\n' < "${D}/argv" | tail -1)" == "do-agent-aws:latest" ] || fail "12: with ${FLAG} the start command's last word is not the image"
	argv12 | grep -qF -- "|--network|test-run-agent-plane|" || fail "12: run.sh ${FLAG} does not join the Plane network that runs: $(argv12 | cut -c1-300)"
	argv12 | grep -qF -- "|--network|test-run-agent-kanban|" || fail "12: run.sh ${FLAG} does not join the board network that runs: $(argv12 | cut -c1-300)"
	argv12 | grep -qF -- "|--mount|type=volume,src=test-run-agent-buildkit-socket,dst=/run/buildkit|" && argv12 | grep -qF -- "|BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock|" \
		|| fail "12: run.sh ${FLAG} does not mount the running substrate's socket: $(argv12 | cut -c1-300)"
	argv12 | grep -qF -- "DOCKER_SUBSTRATE=" && fail "12: run.sh ${FLAG} marked the substrate although it runs: $(argv12 | grep -oF -- 'DOCKER_SUBSTRATE=[a-z-]*')"
	calls12 | grep -qxF "network|connect|test-run-agent-docker|test-run-agent|" || fail "12: run.sh ${FLAG} did not join the running substrate's network: $(calls12 | grep '^network' | tr '\n' ' ')"
	grep -qxF "${SINGLE_LINE}" "${D}/run.out" || fail "12: run.sh ${FLAG} does not say what the run covers: $(out)"
	grep -qE "WARNING|ERROR" "${D}/run.out" && fail "12: run.sh ${FLAG} with every sidecar running printed a WARNING or ERROR: $(grep -E 'WARNING|ERROR' "${D}/run.out" | head -2 | tr '\n' ' ')"
done
# (b) nothing runs: one WARNING each, the agent starts without, the substrate marked not-running
plant12
RC=$(start12 -- -s)
[ "${RC}" == "0" ] || fail "12: run.sh -s exited ${RC} with no sidecar running (expected 0): $(out)"
[ -e "${D}/side" ] && fail "12: run.sh -s with no sidecar running ran a sidecar script: $(side12 | tr '\n' ' ')"
for W in "WARNING: no test-run-agent-plane network - the agent starts without the Plane board (./stop.sh -s && ./run.sh starts it)" \
	"${SUBSTRATE_WARNING}" \
	"WARNING: no test-run-agent-kanban network - the agent starts without the board (./stop.sh -s && ./run.sh starts it)"; do
	grep -qxF "${W}" "${D}/run.out" || fail "12: no '${W}': $(grep WARNING "${D}/run.out" | tr '\n' ' ' | cut -c1-400)"
done
[ "$(grep -c WARNING "${D}/run.out")" == "3" ] || fail "12: $(grep -c WARNING "${D}/run.out") WARNING lines, not 3: $(grep WARNING "${D}/run.out" | tr '\n' ' ' | cut -c1-400)"
grep -q "ERROR" "${D}/run.out" && fail "12: run.sh -s with no sidecar running printed an ERROR: $(grep ERROR "${D}/run.out")"
[ "$(calls12 | grep -c '^container|run|')" == "1" ] || fail "12: with no sidecar running docker container run ran $(calls12 | grep -c '^container|run|') times, not once"
argv12 | grep -qF -- "|-e|DOCKER_SUBSTRATE=not-running|" || fail "12: the agent is not marked DOCKER_SUBSTRATE=not-running when the substrate does not run: $(argv12 | cut -c1-300)"
argv12 | grep -qE -- "test-run-agent-plane|test-run-agent-kanban|dst=/run/buildkit|BUILDKIT_HOST=" && fail "12: the agent joins a network or mounts a socket that is not there: $(argv12 | cut -c1-300)"
calls12 | grep -q '^network|connect|' && fail "12: run.sh -s joined a network although none runs: $(calls12 | grep '^network|connect|')"
# one part of the substrate missing at a time, both boards' networks there: the daemon not running, the registry not
# running, the socket volume gone - the substrate WARNING alone, the marker, no mount and no join; the boards still joined
for MISSING in daemon registry volume; do
	case "${MISSING}" in
		daemon) plant12 "${ALL_UP[@]}"; EXISTING="test-run-agent-registry" ;;
		registry) plant12 "${ALL_UP[@]}"; EXISTING="test-run-agent-buildkit" ;;
		volume) plant12 test-run-agent-plane test-run-agent-kanban test-run-agent-docker; EXISTING="test-run-agent-buildkit test-run-agent-registry" ;;
	esac
	RC=$(start12 STUB_EXISTING="${EXISTING}" -- -s)
	[ "${RC}" == "0" ] || fail "12: run.sh -s exited ${RC} with the substrate's ${MISSING} missing (expected 0): $(out)"
	[ "$(grep -c WARNING "${D}/run.out")" == "1" ] && grep -qxF "${SUBSTRATE_WARNING}" "${D}/run.out" \
		|| fail "12: with the substrate's ${MISSING} missing, not exactly the one substrate WARNING: $(grep WARNING "${D}/run.out" | tr '\n' ' ' | cut -c1-300)"
	argv12 | grep -qF -- "|-e|DOCKER_SUBSTRATE=not-running|" || fail "12: with the substrate's ${MISSING} missing the agent is not marked not-running: $(argv12 | cut -c1-300)"
	argv12 | grep -qE -- "dst=/run/buildkit|BUILDKIT_HOST=" && fail "12: with the substrate's ${MISSING} missing the agent mounts the socket or gets BUILDKIT_HOST: $(argv12 | cut -c1-300)"
	calls12 | grep -q '^network|connect|' && fail "12: with the substrate's ${MISSING} missing run.sh joined the substrate's network: $(calls12 | grep '^network|connect|')"
	argv12 | grep -qF -- "|--network|test-run-agent-plane|" && argv12 | grep -qF -- "|--network|test-run-agent-kanban|" \
		|| fail "12: with the substrate's ${MISSING} missing the boards' networks were not joined: $(argv12 | cut -c1-300)"
done
# the preflight counts no network for -s: every address pool in use refuses the default start and lets -s through
plant12 "${ALL_UP[@]}"
RC=$(start12 STUB_NETS_USED=31 STUB_EXISTING="test-run-agent-buildkit test-run-agent-registry")
[ "${RC}" == "1" ] && grep -q "too few free Docker address pools" "${D}/run.out" || fail "12: CONTROL: the default start with every address pool in use was not refused (rc ${RC}): $(out)"
plant12 "${ALL_UP[@]}"
RC=$(start12 STUB_NETS_USED=31 STUB_EXISTING="test-run-agent-buildkit test-run-agent-registry" -- -s)
[ "${RC}" == "0" ] || fail "12: run.sh -s exited ${RC} with every address pool in use (expected 0: it creates no network): $(out)"
grep -qF "a harness instance needs 0 (none with -s: the agent container alone joins the networks that run)" "${D}/run.out" || fail "12: the preflight does not say -s needs no address pool: $(grep 'address pools' "${D}/run.out")"
# (c) an interactive run with -s: the command's words intact after the image, nothing run on the host
plant12 "${ALL_UP[@]}"
rm -f "${D:?}/copy/planted-arg"
RC=$(start12 STUB_EXISTING="test-run-agent-buildkit test-run-agent-registry" -- -s bash -c 'echo $HOME; touch planted-arg')
[ "${RC}" == "0" ] || fail "12: run.sh -s bash -c exited ${RC}: $(out)"
[ "$(tr '\0' '\n' < "${D}/argv" | tail -4 | tr '\n' '|')" == 'do-agent-aws:latest|bash|-c|echo $HOME; touch planted-arg|' ] \
	|| fail "12: the interactive run's command after -s did not reach docker as its three words: $(tr '\0' '\n' < "${D}/argv" | tail -4 | tr '\n' '|')"
argv12 | grep -qF -- "|-it|" && ! argv12 | grep -qF -- "|-d|" || fail "12: run.sh -s <command> is not an interactive run (-it): $(argv12 | cut -c1-200)"
[ -e "${D}/copy/planted-arg" ] && fail "12: the interactive run's command ran on the host (planted-arg was created there)"
[ -e "${D}/side" ] && fail "12: run.sh -s <command> ran a sidecar script: $(side12 | tr '\n' ' ')"
# (d) only a leading -s or --single is an option: -x is a command, and bash -s keeps its -s
plant12 "${ALL_UP[@]}"
RC=$(start12 STUB_EXISTING="test-run-agent-buildkit test-run-agent-registry" -- -x)
[ "$(tr '\0' '\n' < "${D}/argv" | tail -2 | tr '\n' '|')" == 'do-agent-aws:latest|-x|' ] || fail "12: ./run.sh -x no longer runs -x in the container: $(tr '\0' '\n' < "${D}/argv" | tail -2 | tr '\n' '|')"
grep -qF "${SINGLE_LINE}" "${D}/run.out" && fail "12: ./run.sh -x was read as -s"
plant12 "${ALL_UP[@]}"
RC=$(start12 STUB_EXISTING="test-run-agent-buildkit test-run-agent-registry" -- bash -s)
[ "$(tr '\0' '\n' < "${D}/argv" | tail -3 | tr '\n' '|')" == 'do-agent-aws:latest|bash|-s|' ] || fail "12: ./run.sh bash -s lost the command's -s: $(tr '\0' '\n' < "${D}/argv" | tail -3 | tr '\n' '|')"
grep -qF "${SINGLE_LINE}" "${D}/run.out" && fail "12: ./run.sh bash -s was read as the -s option"
side12 | grep -qx 'kanban.sh|up' || fail "12: ./run.sh bash -s (an interactive run, not -s) did not run ./kanban.sh up as before: $(side12 | tr '\n' ' ')"
# CONTROL: the default run calls the three sidecar scripts, in order
plant12 "${ALL_UP[@]}"
RC=$(start12 STUB_EXISTING="test-run-agent-buildkit test-run-agent-registry")
[ "${RC}" == "0" ] || fail "12: CONTROL: run.sh exited ${RC} with the sidecar stubs (expected 0): $(out)"
[ "$(side12 | tr '\n' ' ')" == "plane.sh|up docker.sh|up kanban.sh|up " ] || fail "12: CONTROL: the default run did not call ./plane.sh up, ./docker.sh up and ./kanban.sh up: $(side12 | tr '\n' ' ')"
grep -qF "${SINGLE_LINE}" "${D}/run.out" && fail "12: CONTROL: the default run says it starts the agent container alone"
# (e) the compose target: up -d --no-deps of the agent service with the base file re-rendered, the overlay only when its
# rendered file exists; the control without -s renders the overlay, runs init and db-password, up -d of every service
local_env 'export TO=compose' 'export UI_VIBE_KANBAN=true'
rm -rf "${D:?}/copy/to/compose/app"
plant12
RC=$(start12 -- -s)
[ "${RC}" == "0" ] || fail "12: run.sh -s exited ${RC} on the compose target (expected 0): $(out)"
[ "$(calls12 | grep '^docker-compose|')" == "docker-compose|-f|./to/compose/app/docker-compose.yaml|up|-d|--no-deps|test-run-agent|" ] \
	|| fail "12: run.sh -s on the compose target is not docker-compose -f <file> up -d --no-deps <the agent service>: $(calls12 | grep '^docker-compose|' | tr '\n' ' ')"
grep -q "^  test-run-agent:" "${D}/copy/to/compose/app/docker-compose.yaml" || fail "12: run.sh -s did not render the compose file with the agent service"
[ -e "${D}/copy/to/compose/app/docker-compose.kanban.yaml" ] && fail "12: run.sh -s rendered the board's overlay"
[ -e "${D}/side" ] && fail "12: run.sh -s on the compose target ran a sidecar script: $(side12 | tr '\n' ' ')"
grep -qxF "${SINGLE_LINE_COMPOSE}" "${D}/run.out" || fail "12: run.sh -s on the compose target does not say what the run covers: $(out)"
grep -qF "${SINGLE_LINE}" "${D}/run.out" && fail "12: run.sh -s on the compose target names the docker target's sidecars"
# both overlays rendered by an earlier full start (PLANTED: the board's and the relay's, empty files)
: > "${D}/copy/to/compose/app/docker-compose.kanban.yaml"
: > "${D}/copy/to/compose/app/docker-compose.kanban-relay.yaml"
plant12
RC=$(start12 -- -s)
[ "${RC}" == "0" ] || fail "12: run.sh -s exited ${RC} on the compose target with the overlays rendered (expected 0): $(out)"
[ "$(calls12 | grep '^docker-compose|')" == "docker-compose|-f|./to/compose/app/docker-compose.yaml|-f|./to/compose/app/docker-compose.kanban.yaml|-f|./to/compose/app/docker-compose.kanban-relay.yaml|up|-d|--no-deps|test-run-agent|" ] \
	|| fail "12: run.sh -s with the overlays rendered does not pass both: $(calls12 | grep '^docker-compose|' | tr '\n' ' ')"
[ -s "${D}/copy/to/compose/app/docker-compose.kanban.yaml" ] || [ -s "${D}/copy/to/compose/app/docker-compose.kanban-relay.yaml" ] && fail "12: run.sh -s re-rendered an overlay"
rm -f "${D:?}/copy/to/compose/app/docker-compose.kanban-relay.yaml"
plant12
RC=$(start12)
[ "${RC}" == "0" ] || fail "12: CONTROL: run.sh exited ${RC} on the compose target (expected 0): $(out)"
[ "$(side12 | tr '\n' ' ')" == "kanban.sh|init kanban.sh|db-password " ] || fail "12: CONTROL: the default compose start did not run ./kanban.sh init then db-password: $(side12 | tr '\n' ' ')"
calls12 | grep -qxF "docker-compose|-f|./to/compose/app/docker-compose.yaml|-f|./to/compose/app/docker-compose.kanban.yaml|up|-d|" \
	|| fail "12: CONTROL: the default compose start is not up -d of every service with the overlay: $(calls12 | grep '^docker-compose|' | tr '\n' ' ')"
[ -s "${D}/copy/to/compose/app/docker-compose.kanban.yaml" ] || fail "12: CONTROL: the default compose start did not render the board's overlay"
# (f) swarm, kubernetes and the sandbox refuse -s by name, before anything runs
for T in swarm kubernetes sandbox; do
	local_env "export TO=${T}"
	plant12
	RC=$(start12 -- -s)
	[ "${RC}" == "2" ] || fail "12: run.sh -s exited ${RC} with TO=${T} (expected 2): $(out)"
	grep -qF "run.sh: -s/--single applies to the docker and compose targets, not TO=${T}" "${D}/run.out" || fail "12: TO=${T} with -s is not refused by name: $(out)"
	[ -e "${D}/state12/calls" ] && fail "12: a docker command ran on TO=${T} with -s: $(calls12 | tr '\n' ' ')"
	[ -e "${D}/side" ] && fail "12: a sidecar script ran on TO=${T} with -s: $(side12 | tr '\n' ' ')"
done
echo "ok 12 - -s and --single start the agent container alone: no sidecar script runs, no network or volume is created, one detached docker run that joins the Plane and board networks and mounts and joins the substrate when they run, one WARNING each and DOCKER_SUBSTRATE=not-running when they do not, the substrate alone when one of its parts is missing; the preflight counts no network for -s; -s <command> is an interactive run with its words intact; -x and bash -s stay commands; compose: up -d --no-deps of the agent service with the overlays only when rendered; swarm, kubernetes and sandbox refuse -s (exit 2)"

# --- 13. the Plane board is opt-in (docs/manual/boards.md "Plane board"): the shipped default starts nothing of it, UI_PLANE=true does ---
grep -q '^export UI_PLANE=false$' "${BASE_DIR}/.env" || fail "13: .env does not ship UI_PLANE=false (the Plane board is opt-in): $(grep -n '^export UI_PLANE=' "${BASE_DIR}/.env")"
{ echo "export CONTAINER=test-run-agent"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; } > "${D}/copy/.env.local"   # no UI_PLANE line: the shipped default
plant12 "${ALL_UP[@]}"
RC=$(start12 STUB_EXISTING="test-run-agent-buildkit test-run-agent-registry")
[ "${RC}" == "0" ] || fail "13: run.sh exited ${RC} with the shipped Plane default (expected 0): $(out)"
side12 | grep -q '^plane.sh|' && fail "13: with the shipped default (UI_PLANE=false) run.sh ran ./plane.sh: $(side12 | tr '\n' ' ')"
argv12 | grep -qE -- '\|--network\|test-run-agent-plane\||PLANE_URL=' && fail "13: with the shipped default the agent joins the Plane network or gets PLANE_URL: $(argv12 | cut -c1-300)"
[ "$(calls12 | grep -c '^container|run|')" == "1" ] || fail "13: the default start did not run docker container run exactly once: $(calls12 | grep -c '^container|run|')"
local_env 'export UI_PLANE=true'
plant12 "${ALL_UP[@]}"
RC=$(start12 STUB_EXISTING="test-run-agent-buildkit test-run-agent-registry")
[ "${RC}" == "0" ] || fail "13: run.sh exited ${RC} with UI_PLANE=true (expected 0): $(out)"
side12 | grep -qx 'plane.sh|up' || fail "13: with UI_PLANE=true in .env.local run.sh did not run ./plane.sh up: $(side12 | tr '\n' ' ')"
argv12 | grep -qF -- '|--network|test-run-agent-plane|' && argv12 | grep -qF -- '|-e|PLANE_URL=http://plane-proxy:80|' \
	|| fail "13: with UI_PLANE=true the agent does not join the Plane network with PLANE_URL: $(argv12 | cut -c1-300)"
echo "ok 13 - the Plane board is opt-in: .env ships UI_PLANE=false; a default start runs nothing of ./plane.sh and the agent neither joins the Plane network nor gets PLANE_URL; UI_PLANE=true in .env.local runs ./plane.sh up and joins the agent to the Plane network with PLANE_URL"

echo "Test-run succeeded"
