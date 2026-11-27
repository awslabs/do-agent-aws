#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side unit test of the exec.sh command line flag contract (-s|--shell, -h|--help).
# exec.sh is a HOST script (it builds and evals a docker/kubectl command), so unlike the
# in-container /test*.sh suite this test runs on the host: it copies exec.sh + .env + .fun
# into a scratch folder, flips DRY_RUN=true in the copy's .env (the variables are exported
# inside .env, so a caller's environment cannot override them - the copy must be edited),
# and asserts on the command exec.sh echoes (VERBOSE=true) without ever exec'ing into a
# container. The swarm and kubernetes paths run `docker ps` / `kubectl get pod` while
# BUILDING the command even under DRY_RUN, so those binaries are stubbed on PATH with
# deterministic output. Each check FAILS if the property it proves is removed:
#    1. exec.sh and this test parse (bash -n)
#    2. TO=docker: default invocation is unchanged - no TMUX_AUTO_ATTACH injection
#       (the built-in control proving checks 3/5/6/7/8 assert a real difference)
#    3. TO=docker: -s injects -e TMUX_AUTO_ATTACH=false ahead of the container name
#    4. TO=docker: `exec.sh <cmd>` passthrough is intact - the flag parser must not
#       eat or mangle the command
#    5. TO=docker: -s composes with a passthrough command
#    6. TO=compose: `exec.sh 2` still reaches container index 2, and -s composes with it
#    7. TO=swarm: -s injects the switch ahead of the resolved container id
#    8. TO=kubernetes: -s injects an exported TMUX_AUTO_ATTACH=false prefix INSIDE the
#       pod's sh -c (kubectl exec has no environment switch), and `exec.sh 2` still
#       reaches pod index 2
#    9. MECHANISM: an exported variable in a sh -c really is inherited by the bash that
#       shell starts - the kubernetes prefix reaches the .bashrc attach guard
#   10. -h and --help print usage, exit 0, and build NO exec command
#   11. an unknown option is refused loudly (exit 1), never swallowed into the command
#   12. the suite's knobs reach the test container: .env's TEST_RUN_OPTS passes TEST6_UNITTEST_TIMEOUT through
#       (`TEST6_UNITTEST_TIMEOUT=<s> ./test.sh` is what test6's timeout message tells the user to run)
#   13. TO=sandbox (to/sandbox/README.md "TO=sandbox"): the docker form against the sandbox - no argument
#       builds `sbx exec -it <SANDBOX_NAME> sh -c '...'` with no injection, a command passes through intact,
#       and -s injects -e TMUX_AUTO_ATTACH=false ahead of the sandbox name, alone and with a command (sbx
#       exec takes -e NAME=value as docker exec does)
#   14. TO=docker and TO=sandbox: a command's words reach the container / the sandbox as they were given -
#       `exec.sh sh -c 'echo hello world'` keeps 'echo hello world' one word (the command is re-quoted with
#       printf ' %q' before the eval, run.sh's pattern since 78c875d), alone and with -s; plus the MECHANISM:
#       printf ' %q' + eval rebuilds exactly the words that went in

D=$(mktemp -d /tmp/exec-flags-smoke-XXXXXX)   # per run: two ./test.sh runs on one host must not share it

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

cleanup()
{
	rm -rf "${D:?}"
}

fail()
{
	echo "Test-exec FAILED: $1"
	cleanup
	exit 1
}

# Scratch copy of the host scripts, with DRY_RUN forced on and VERBOSE forced on
cp ${BASE_DIR}/exec.sh ${BASE_DIR}/.env ${BASE_DIR}/.fun ${D}/
sed -i -e 's/^export DRY_RUN=.*/export DRY_RUN=true/' -e 's/^export VERBOSE=.*/export VERBOSE=true/' ${D}/.env
# The container name the commands must carry comes from THIS checkout's .env (CONTAINER, and the compose project
# name), not from a literal: a deployment that prefixes its container (CONTAINER=myteam-do-agent-aws) runs
# ./test.sh verbatim and this test must still read the right name in every command
C=$(cd ${D} && bash -c 'source ./.env > /dev/null 2>&1; echo "${CONTAINER}"')
COMPOSE_PROJECT=$(cd ${D} && bash -c 'source ./.env > /dev/null 2>&1; echo "${COMPOSE_PROJECT_NAME}"')
[ -n "${C}" ] || { echo "Test-exec FAILED: .env sets no CONTAINER"; rm -rf "${D:?}"; exit 1; }
export CONTAINER_UNDER_TEST=${C}   # read by the kubectl/docker stubs on PATH when exec.sh runs them

# Stub kubectl and docker with deterministic output for the command-substitution paths
mkdir -p ${D}/stub-bin
cat << 'EOF' > ${D}/stub-bin/kubectl
#!/bin/bash
case "$*" in
*"get pod"*)
	echo "NAME READY STATUS RESTARTS AGE"
	echo "${CONTAINER_UNDER_TEST}-pod-1 1/1 Running 0 1m"
	echo "${CONTAINER_UNDER_TEST}-pod-2 1/1 Running 0 1m"
	;;
esac
EOF
cat << 'EOF' > ${D}/stub-bin/docker
#!/bin/bash
case "$1" in
ps)
	echo "abc123def456   iankoulski/${CONTAINER_UNDER_TEST}:latest   \"bash\"   1m   Up 1m   mystack_${CONTAINER_UNDER_TEST}.1.xyz"
	;;
esac
EOF
chmod +x ${D}/stub-bin/kubectl ${D}/stub-bin/docker

set_to()
{
	sed -i "s/^export TO=.*/export TO=$1/" ${D}/.env
}

run_exec()
{
	( cd ${D} && PATH="${D}/stub-bin:${PATH}" ./exec.sh "$@" )
}

# 1. parse checks
bash -n ${BASE_DIR}/exec.sh || fail "exec.sh does not parse"
bash -n ${BASE_DIR}/test-exec.sh || fail "test-exec.sh does not parse"
echo "ok 1 - exec.sh and test-exec.sh parse"

# 2. TO=docker default: unchanged, no injection
set_to docker
OUT=$(run_exec)
echo "${OUT}" | grep -q "docker container exec -it ${C} sh -c" \
	|| fail "docker default command changed: ${OUT}"
echo "${OUT}" | grep -q "TMUX_AUTO_ATTACH" \
	&& fail "docker default must not inject TMUX_AUTO_ATTACH: ${OUT}"
echo "ok 2 - docker default builds the unchanged attach command (control for 3/5/6/7/8)"

# 3. TO=docker -s
OUT=$(run_exec -s)
echo "${OUT}" | grep -q "docker container exec -it -e TMUX_AUTO_ATTACH=false ${C} sh -c" \
	|| fail "-s did not inject -e TMUX_AUTO_ATTACH=false on TO=docker: ${OUT}"
OUT=$(run_exec --shell)
echo "${OUT}" | grep -q "docker container exec -it -e TMUX_AUTO_ATTACH=false ${C} sh -c" \
	|| fail "--shell did not inject -e TMUX_AUTO_ATTACH=false on TO=docker: ${OUT}"
echo "ok 3 - -s|--shell injects -e TMUX_AUTO_ATTACH=false ahead of the container name"

# 4. TO=docker passthrough command intact
OUT=$(run_exec whoami)
[ "${OUT}" == "docker container exec -it ${C} whoami" ] \
	|| fail "command passthrough mangled: ${OUT}"
echo "ok 4 - command passthrough is intact"

# 5. TO=docker -s + passthrough command
OUT=$(run_exec -s whoami)
[ "${OUT}" == "docker container exec -it -e TMUX_AUTO_ATTACH=false ${C} whoami" ] \
	|| fail "-s does not compose with a passthrough command: ${OUT}"
echo "ok 5 - -s composes with a passthrough command"

# 6. TO=compose index arg intact, with and without -s
set_to compose
OUT=$(run_exec 2)
echo "${OUT}" | grep -q "docker exec -it ${COMPOSE_PROJECT}_${C}_2 sh -c" \
	|| fail "compose index 2 not reached: ${OUT}"
OUT=$(run_exec -s 2)
echo "${OUT}" | grep -q "docker exec -it -e TMUX_AUTO_ATTACH=false ${COMPOSE_PROJECT}_${C}_2 sh -c" \
	|| fail "-s does not compose with the compose index arg: ${OUT}"
echo "ok 6 - compose index arg survives the flag parser, with and without -s"

# 7. TO=swarm -s
set_to swarm
OUT=$(run_exec)
echo "${OUT}" | grep -q "docker exec -it abc123def456 sh -c" \
	|| fail "swarm default command changed: ${OUT}"
OUT=$(run_exec -s)
echo "${OUT}" | grep -q "docker exec -it -e TMUX_AUTO_ATTACH=false abc123def456 sh -c" \
	|| fail "-s did not inject -e TMUX_AUTO_ATTACH=false on TO=swarm: ${OUT}"
echo "ok 7 - swarm gets the injection ahead of the resolved container id"

# 8. TO=kubernetes: exported prefix inside the pod's sh -c, index arg intact
set_to kubernetes
OUT=$(run_exec)
echo "${OUT}" | grep -q "TMUX_AUTO_ATTACH" \
	&& fail "kubernetes default must not inject TMUX_AUTO_ATTACH: ${OUT}"
OUT=$(run_exec -s)
echo "${OUT}" | grep -q -- "-- sh -c 'export TMUX_AUTO_ATTACH=false; if \[ -e /bin/bash \]" \
	|| fail "-s did not inject the exported prefix on TO=kubernetes: ${OUT}"
OUT=$(run_exec -s 2)
echo "${OUT}" | grep -q "${C}-pod-2" \
	|| fail "kubernetes pod index 2 not reached with -s: ${OUT}"
echo "ok 8 - kubernetes gets an exported prefix inside sh -c and keeps the pod index arg"

# 9. mechanism: the exported prefix reaches a child bash of the sh -c - the inner
# command is single-quoted so the CHILD bash expands the variable from its inherited
# environment (double quotes there would let the parent sh expand it, proving nothing)
OUT=$(sh -c "export TMUX_AUTO_ATTACH=false; bash -c 'echo got=\${TMUX_AUTO_ATTACH}'")
[ "${OUT}" == "got=false" ] \
	|| fail "exported sh -c variable did not reach the child bash: ${OUT}"
echo "ok 9 - an exported variable in sh -c is inherited by the bash it starts"

# 10. -h|--help: usage, exit 0, no command built
set_to docker
OUT=$(run_exec -h)
RC=$?
[ "${RC}" == "0" ] || fail "-h exited ${RC}, expected 0"
echo "${OUT}" | grep -q "Usage:" || fail "-h printed no usage: ${OUT}"
echo "${OUT}" | grep -q "exec -it" && fail "-h must not build an exec command: ${OUT}"
OUT=$(run_exec --help)
RC=$?
[ "${RC}" == "0" ] || fail "--help exited ${RC}, expected 0"
echo "${OUT}" | grep -q "Usage:" || fail "--help printed no usage: ${OUT}"
echo "${OUT}" | grep -q "exec -it" && fail "--help must not build an exec command: ${OUT}"
echo "ok 10 - -h|--help print usage, exit 0, and build no exec command"

# 11. unknown option refused loudly
OUT=$(run_exec -x)
RC=$?
[ "${RC}" == "1" ] || fail "unknown option -x exited ${RC}, expected 1"
echo "${OUT}" | grep -q "unknown option -x" || fail "unknown option not reported: ${OUT}"
echo "${OUT}" | grep -q "exec -it" && fail "unknown option must not be swallowed into the command: ${OUT}"
echo "ok 11 - an unknown option is refused loudly, never swallowed into the command"

# --- 12. the suite's knobs reach the test container ---
OPTS=$(cd ${D} && bash -c 'source ./.env > /dev/null 2>&1; echo "${TEST_RUN_OPTS}"')
echo " ${OPTS} " | grep -qF -- " -e TEST6_UNITTEST_TIMEOUT " \
	|| fail "TEST_RUN_OPTS does not pass TEST6_UNITTEST_TIMEOUT into the test container, so the 'TEST6_UNITTEST_TIMEOUT=<s> ./test.sh' test6 advises would never reach it: ${OPTS}"
echo "ok 12 - TEST_RUN_OPTS passes TEST6_UNITTEST_TIMEOUT into the test container (TEST6_UNITTEST_TIMEOUT=<s> ./test.sh reaches test6)"

# --- 13. TO=sandbox: the docker form against the sandbox ---
# the sandbox's name and the sbx cli come from THIS checkout's .env (SANDBOX_NAME, SBX), as the container name does above
set_to sandbox
SBX_NAME=$(cd ${D} && bash -c 'source ./.env > /dev/null 2>&1; echo "${SANDBOX_NAME}"')
SBX_CLI=$(cd ${D} && bash -c 'source ./.env > /dev/null 2>&1; echo "${SBX}"')
[ -n "${SBX_NAME}" ] && [ -n "${SBX_CLI}" ] || fail ".env sets no SANDBOX_NAME or no SBX"
OUT=$(run_exec)
[ "${OUT}" == "${SBX_CLI} exec -it ${SBX_NAME} sh -c 'if [ -e /bin/bash ]; then /bin/bash; else sh; fi'" ] \
	|| fail "sandbox default command is not the shell in the sandbox: ${OUT}"
OUT=$(run_exec whoami)
[ "${OUT}" == "${SBX_CLI} exec -it ${SBX_NAME} whoami" ] \
	|| fail "sandbox command passthrough mangled: ${OUT}"
OUT=$(run_exec -s)
[ "${OUT}" == "${SBX_CLI} exec -it -e TMUX_AUTO_ATTACH=false ${SBX_NAME} sh -c 'if [ -e /bin/bash ]; then /bin/bash; else sh; fi'" ] \
	|| fail "-s did not inject -e TMUX_AUTO_ATTACH=false ahead of the sandbox name: ${OUT}"
OUT=$(run_exec -s whoami)
[ "${OUT}" == "${SBX_CLI} exec -it -e TMUX_AUTO_ATTACH=false ${SBX_NAME} whoami" ] \
	|| fail "-s does not compose with a passthrough command on TO=sandbox: ${OUT}"
echo "ok 13 - TO=sandbox: a shell in the sandbox by default, a command passed through intact, -s injected ahead of the sandbox name, alone and with a command"

# --- 14. a multi-word argument survives the eval, on TO=docker and TO=sandbox ---
# exec.sh builds ONE string and evals it (DRY_RUN prints that string): a bare `CMD="$@"` flattens
# `sh -c 'echo hello world'` into five words, so the words must be re-quoted (printf ' %q', the pattern
# run.sh's docker and sandbox arms use). The expected tail is what printf %q renders for these words.
EXPECTED_ARGS=$(printf ' %q' sh -c 'echo hello world')
set_to docker
OUT=$(run_exec sh -c 'echo hello world')
[ "${OUT}" == "docker container exec -it ${C}${EXPECTED_ARGS}" ] \
	|| fail "TO=docker: a multi-word argument lost its word boundaries: ${OUT}"
OUT=$(run_exec -s sh -c 'echo hello world')
[ "${OUT}" == "docker container exec -it -e TMUX_AUTO_ATTACH=false ${C}${EXPECTED_ARGS}" ] \
	|| fail "TO=docker -s: a multi-word argument lost its word boundaries: ${OUT}"
set_to sandbox
OUT=$(run_exec sh -c 'echo hello world')
[ "${OUT}" == "${SBX_CLI} exec -it ${SBX_NAME}${EXPECTED_ARGS}" ] \
	|| fail "TO=sandbox: a multi-word argument lost its word boundaries: ${OUT}"
OUT=$(run_exec -s sh -c 'echo hello world')
[ "${OUT}" == "${SBX_CLI} exec -it -e TMUX_AUTO_ATTACH=false ${SBX_NAME}${EXPECTED_ARGS}" ] \
	|| fail "TO=sandbox -s: a multi-word argument lost its word boundaries: ${OUT}"
# mechanism: eval of the re-quoted string gives back the same three words (a subshell, so the test's own
# positional parameters are untouched)
WORDS=$(eval "set --${EXPECTED_ARGS}"; echo "$#|$3")
[ "${WORDS}" == "3|echo hello world" ] \
	|| fail "printf ' %q' + eval did not rebuild the words that went in: ${WORDS}"
echo "ok 14 - a multi-word argument reaches the container and the sandbox as one word (printf %q, run.sh's pattern), alone and with -s"

cleanup
echo "Test-exec PASSED"
