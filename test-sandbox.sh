#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of the sandbox target's scripts (TO=sandbox; to/sandbox/README.md "TO=sandbox"), run by test.sh like
# test-run.sh: build.sh, run.sh, status.sh, exec.sh, stop.sh, logs.sh, preflight.sh, .env, .fun, env-local.sh and the kit
# descriptor (to/sandbox/template/do-agent-aws-sandbox.yaml, at the same relative path) are copied into
# ./scratch/test-sandbox (gitignored) with a planted .env.local (TO=sandbox, its own sandbox name, the boards off), stubs
# of render.sh, kanban.sh, plane.sh and docker.sh in the copy that record that they ran, and sbx, docker and kubectl stubs on
# PATH
# that record every call's words and answer as each check plants (sbx ls lists the planted sandbox and two others;
# create exits 0, or with the OCI exporter error, or with a planted status). No real sbx, docker or kubectl runs,
# nothing of the checkout is read for a setting or written, and this host needs no KVM: PREFLIGHT_KVM names a planted
# file. The sizes the commands must carry are read here from the copied descriptor, independently of preflight.sh.
# Each check FAILS if the property is removed:
#   1. ./build.sh renders, then builds the kit through the throwaway sandbox: after the preflight's sbx ls -q, render.sh
#      ran, then sbx create --name <prebuild> --cpus <descriptor> --memory <descriptor> --skills off
#      ./to/sandbox/app/do-agent-aws-sandbox (the kit path starting with ./), then sbx rm --force <prebuild>; exit 0, no
#      ERROR line, and docker never ran
#   2. a kit build that stops with the OCI exporter error: ./build.sh exits 1 with one ERROR line naming both causes (no
#      hypervisor; the classic image store) and the README section 'Local sandboxes (hosts with KVM)', and no sbx rm
#      follows the failed create; a create that exits 7 for another reason: exit 7, one ERROR line with the status and
#      the sbx rm command for a sandbox left behind
#   3. ./run.sh creates the sandbox: sbx create --name <name> --cpus <descriptor> --memory <descriptor> --skills off
#      ./to/sandbox/app/do-agent-aws-sandbox, exit 0, no ERROR line, and the two next commands printed (./exec.sh and
#      sbx run --name <name>); ./run.sh <command> adds sbx exec -it <name> <command> with the words intact (bash -c
#      'echo $HOME; touch planted-arg' is three words, nothing of it run on the host) and exits with the command's
#      status (3), no next-commands line; a create that exits 125 makes ./run.sh exit 125 with one ERROR line and no exec
#   4. ./status.sh runs sbx ls and prints the header and the planted sandbox's line, not the lines of a sandbox whose
#      name starts with the same letters or of another sandbox
#   5. ./exec.sh with no argument runs sbx exec -it <name> sh -c '...bash...'; with arguments, sbx exec -it <name>
#      <args>; -s injects -e TMUX_AUTO_ATTACH=false before the name, alone and with a command
#   6. ./stop.sh runs sbx rm --force <name> and nothing else: no kanban.sh, docker.sh or plane.sh teardown, no docker
#   7. ./logs.sh prints one line saying a sandbox has no log stream to follow and naming sbx run --name <name> and
#      ./exec.sh, exits 0 and calls no sbx command; and none of the six scripts called docker or kubectl under
#      TO=sandbox in checks 1 to 7
#   8. the preflight (preflight sandbox): with the cli named by SBX not on PATH, ./build.sh and ./run.sh exit 1 naming
#      the install and run nothing; without the KVM device, exit 1 naming the no-hypervisor cause and the cloud
#      alternative; with the daemon not answering (sbx ls -q fails), exit 1 naming sbx login and sbx daemon start -d;
#      with a descriptor that has no resources@1, exit 1 naming the descriptor and the missing capability, and with a
#      descriptor path that does not exist, exit 1 naming it and that there is no such file; in each case nothing is
#      rendered or created
#   9. CONTROL - the other targets did not change: with TO=docker in the same copy, ./build.sh runs docker image build,
#      ./run.sh's docker container run ends with the image, ./status.sh, ./exec.sh, ./stop.sh and ./logs.sh echo the
#      docker commands as before (./stop.sh the session ledger's record-stop exec before its rm) and ./stop.sh tears the
#      boards' and the build substrate's sidecars down, and sbx and render.sh never ran

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
D=${BASE_DIR}/scratch/test-sandbox
rm -rf "${D:?}"
mkdir -p "${D}/copy/to/sandbox/template" "${D}/bin"

fail()
{
	echo "Test-sandbox FAILED: $1"
	exit 1
}

cp "${BASE_DIR}/build.sh" "${BASE_DIR}/run.sh" "${BASE_DIR}/status.sh" "${BASE_DIR}/exec.sh" "${BASE_DIR}/stop.sh" "${BASE_DIR}/logs.sh" \
	"${BASE_DIR}/preflight.sh" "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${BASE_DIR}/env-local.sh" "${D}/copy/" \
	|| fail "could not copy the six scripts and the files they read"
cp "${BASE_DIR}/to/sandbox/template/do-agent-aws-sandbox.yaml" "${D}/copy/to/sandbox/template/" || fail "could not copy the kit descriptor"
: > "${D}/kvm"
# the sizes the commands must carry: the descriptor's resources@1, read here on its own (e2e.sh reads it the same way)
read -r CPUS MEMORY < <(python3 - "${D}/copy/to/sandbox/template/do-agent-aws-sandbox.yaml" << 'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
r = [c for c in d["capabilities"] if c["type"] == "com.docker.sandbox/resources@1"][0]["config"]
print(r["cpu"], r["memory"])
PY
)
echo "${CPUS}" | grep -qE '^[0-9]+$' && echo "${MEMORY}" | grep -qE '^[0-9]+[kmgt]?$' || fail "the descriptor's resources@1 did not read as cpu and memory: '${CPUS}' '${MEMORY}'"

# every stub appends one line to ${STUB_CALLS} (sbx, render.sh, kanban.sh, plane.sh, docker.sh) or ${STUB_OTHER} (docker,
# kubectl):
# the program's name and its words, each followed by |
cat > "${D}/bin/sbx" << 'EOF2'
#!/bin/bash
# test-sandbox.sh's sbx: records its words; `ls` lists the planted sandbox ${STUB_LS_NAME} between two others (or fails
# with STUB_DAEMON_DOWN set); `create` exits 0 and says it reused the kit, or prints the OCI exporter error and exits 1
# with STUB_OCI_ERROR set, or exits ${STUB_CREATE_RC}; `exec` runs nothing and exits ${STUB_EXEC_RC:-0}; `rm` exits 0
{ printf 'sbx|'; printf '%s|' "$@"; echo; } >> "${STUB_CALLS}"
case "$1" in
	ls)
		[ -n "${STUB_DAEMON_DOWN}" ] && { echo "Error: not signed in" >&2; exit 1; }
		if [ "$2" == "-q" ]; then
			printf '%s-prebuild\n%s\nother-sandbox\n' "${STUB_LS_NAME}" "${STUB_LS_NAME}"
		else
			echo "SANDBOX                      AGENT                  STATUS    PORTS   WORKSPACE"
			echo "${STUB_LS_NAME}-prebuild   do-agent-aws-sandbox   stopped   -       -"
			echo "${STUB_LS_NAME}   do-agent-aws-sandbox   running   -       -"
			echo "other-sandbox   claude   running   -       /home/planted"
		fi
		exit 0
		;;
	create)
		if [ -n "${STUB_OCI_ERROR}" ]; then
			echo "→ build kit do-agent-aws-sandbox"
			echo "ERROR: failed to build: OCI exporter is not supported for the docker driver." >&2
			echo "Switch to a different driver, or turn on the containerd image store, and try again." >&2
			exit 1
		fi
		[ "${STUB_CREATE_RC:-0}" == "0" ] || { echo "Error: planted create failure" >&2; exit "${STUB_CREATE_RC}"; }
		echo "→ kit do-agent-aws-sandbox unchanged, reusing sbx-kit-src:do-agent-aws-sandbox-planted"
		exit 0
		;;
	exec) exit "${STUB_EXEC_RC:-0}" ;;
esac
exit 0
EOF2
cat > "${D}/bin/docker" << 'EOF2'
#!/bin/bash
# test-sandbox.sh's docker: records its words (the sandbox target must never call it) and answers the docker target's
# calls as a sound host for the control check: a build, the cat of its /SBOM.txt at the end of build.sh (docs/manual/supply-chain.md
# "Software bill of materials"), a start whose container runs, no network in use
{ printf 'docker|'; printf '%s|' "$@"; echo; } >> "${STUB_OTHER}"
case "$1 $2" in
	"info "*) [ "$2" == "--format" ] && echo /var/lib/docker; exit 0 ;;
	"buildx version") echo "github.com/docker/buildx (stub)"; exit 0 ;;
	"image build") echo "stub: image built"; exit 0 ;;
	"network inspect") [ "$3 $4" == "-f {{.Driver}}" ] && echo bridge; exit 0 ;;
	"container run") case " $* " in *" /SBOM.txt "*) printf '## Software bill of materials (SBOM) of the container image stub, build 0\n\n# stub\n' ;; *) echo 0123456789abcdef ;; esac; exit 0 ;;
	"container inspect") echo "running 0"; exit 0 ;;
esac
exit 0
EOF2
printf '#!/bin/bash\n{ printf '"'"'kubectl|'"'"'; printf '"'"'%%s|'"'"' "$@"; echo; } >> "${STUB_OTHER}"\nexit 0\n' > "${D}/bin/kubectl"
for S in render.sh kanban.sh plane.sh docker.sh; do
	printf '#!/bin/bash\n{ printf '"'"'%s|'"'"'; [ $# -gt 0 ] && printf '"'"'%%s|'"'"' "$@"; echo; } >> "${STUB_CALLS}"\nexit 0\n' "${S}" > "${D}/copy/${S}"
done
mv "${D}/copy/render.sh" "${D}/copy/to/sandbox/render.sh"
chmod +x "${D}/bin/sbx" "${D}/bin/docker" "${D}/bin/kubectl" "${D}/copy/to/sandbox/render.sh" "${D}/copy/kanban.sh" "${D}/copy/plane.sh" "${D}/copy/docker.sh"

# local_env [<line>...] - the copy's .env.local: the sandbox target, the test's own sandbox name, the boards and the docker
# spoke off (as test-run.sh's), then the lines given; docker_env the same for the docker target (the control)
local_env()
{
	{ echo "export TO=sandbox"; echo "export SANDBOX_NAME=test-sandbox-agent"; echo "export CONTAINER=test-sandbox-agent"; echo "export UI_PLANE=false"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; printf '%s\n' "$@"; } > "${D}/copy/.env.local"
}
docker_env()
{
	{ echo "export TO=docker"; echo "export CONTAINER=test-sandbox-agent"; echo "export UI_PLANE=false"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; printf '%s\n' "$@"; } > "${D}/copy/.env.local"
}
# run <script> [NAME=value...] [-- <arguments>] - ./<script> in the copy with the stubs on PATH, the planted KVM device
# and those variables; its output in ${D}/out, the sbx/render.sh/kanban.sh/plane.sh calls in ${D}/calls and the
# docker/kubectl calls in ${D}/other (one call a line); prints the script's exit status
run()
{
	local S=$1 VARS=()
	shift
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do VARS+=("$1"); shift; done
	[ "$1" == "--" ] && shift
	rm -f "${D:?}/calls" "${D:?}/other"
	# CVE_SCAN=false: the docker target's CVE scan at the end of build.sh is test-scan.sh's (docs/manual/supply-chain.md "CVE scan")
	( cd "${D}/copy" && env PATH="${D}/bin:${PATH}" ENV_LOCAL_SETUP=false CVE_SCAN=false PREFLIGHT_KVM="${D}/kvm" STUB_CALLS="${D}/calls" STUB_OTHER="${D}/other" STUB_LS_NAME=test-sandbox-agent "${VARS[@]}" "./${S}" "$@" ) > "${D}/out" 2>&1
	echo $?
}
out() { tail -3 "${D}/out" | cut -c1-300 | tr '\n' ' '; }
calls() { cat "${D}/calls" 2> /dev/null; }
no_other() { [ -e "${D}/other" ] && fail "$1: docker or kubectl ran under TO=sandbox: $(tr '\n' ' ' < "${D}/other" | cut -c1-200)"; }
CREATE_PRE="sbx|create|--name|test-sandbox-agent-prebuild|--cpus|${CPUS}|--memory|${MEMORY}|--skills|off|./to/sandbox/app/do-agent-aws-sandbox|"
CREATE="sbx|create|--name|test-sandbox-agent|--cpus|${CPUS}|--memory|${MEMORY}|--skills|off|./to/sandbox/app/do-agent-aws-sandbox|"
NEXT="run.sh: sandbox test-sandbox-agent created. A shell in it: ./exec.sh - the agent (Claude Code with the harness configuration): sbx run --name test-sandbox-agent - remove it: ./stop.sh"

# --- 1. build.sh renders, then builds the kit through the throwaway sandbox ---
local_env
RC=$(run build.sh)
[ "${RC}" == "0" ] || fail "1: build.sh exited ${RC} on a sound kit build (expected 0): $(out)"
grep -q "ERROR" "${D}/out" && fail "1: a sound kit build printed an ERROR line: $(grep ERROR "${D}/out")"
[ "$(calls | tr '\n' ' ')" == "sbx|ls|-q| render.sh| ${CREATE_PRE} sbx|rm|--force|test-sandbox-agent-prebuild| " ] \
	|| fail "1: the kit build is not the preflight's ls, render.sh, the create of the throwaway sandbox with the descriptor's sizes and its rm: $(calls | tr '\n' ' ')"
no_other 1
echo "ok 1 - build.sh: after the preflight, render.sh runs, then sbx create of the throwaway sandbox with --cpus ${CPUS} --memory ${MEMORY} --skills off and the ./ kit path, then its rm --force; exit 0, docker never ran"

# --- 2. a kit build that fails says so ---
RC=$(run build.sh STUB_OCI_ERROR=1)
[ "${RC}" == "1" ] || fail "2: build.sh exited ${RC} on the OCI exporter error (expected 1): $(out)"
[ "$(grep -c '^build.sh: ERROR' "${D}/out")" == "1" ] || fail "2: not exactly one ERROR line on the OCI exporter error: $(grep ERROR "${D}/out" | tr '\n' ' ')"
grep -q "^build.sh: ERROR - the kit build stopped with 'OCI exporter is not supported for the docker driver'" "${D}/out" || fail "2: the ERROR line does not name the error: $(out)"
grep -qF "no hypervisor" "${D}/out" && grep -qF "classic image store" "${D}/out" && grep -qF "to/sandbox/push-kit.sh" "${D}/out" \
	|| fail "2: the ERROR line does not name both causes and the cloud alternative: $(grep ERROR "${D}/out")"
grep -qF "to/sandbox/README.md 'Local sandboxes (hosts with KVM)'" "${D}/out" || fail "2: the ERROR line does not name the README section: $(grep ERROR "${D}/out")"
calls | grep -q '^sbx|rm|' && fail "2: sbx rm ran after a create that failed: $(calls | tr '\n' ' ')"
RC=$(run build.sh STUB_CREATE_RC=7)
[ "${RC}" == "7" ] || fail "2: build.sh exited ${RC} when the create exited 7 (expected 7): $(out)"
grep -qxF "build.sh: ERROR - the kit build exited 7 (the lines above name the cause); a sandbox test-sandbox-agent-prebuild it left behind goes with: sbx rm --force test-sandbox-agent-prebuild" "${D}/out" \
	|| fail "2: no ERROR line with the create's status and the rm command: $(out)"
[ "$(grep -c '^build.sh: ERROR' "${D}/out")" == "1" ] || fail "2: not exactly one ERROR line when the create exited 7"
no_other 2
echo "ok 2 - build.sh on the OCI exporter error: exit 1, one ERROR line with both causes, the cloud alternative and the README section, no rm after the failed create; a create exiting 7: exit 7, one ERROR line with the status and the rm command"

# --- 3. run.sh creates the sandbox, and an interactive run ---
RC=$(run run.sh)
[ "${RC}" == "0" ] || fail "3: run.sh exited ${RC} on a sound create (expected 0): $(out)"
grep -q "ERROR" "${D}/out" && fail "3: a sound create printed an ERROR line: $(grep ERROR "${D}/out")"
[ "$(calls | tr '\n' ' ')" == "sbx|ls|-q| ${CREATE} " ] || fail "3: the start is not the preflight's ls and one sbx create with the descriptor's sizes and the ./ kit path: $(calls | tr '\n' ' ')"
grep -qxF "${NEXT}" "${D}/out" || fail "3: the two next commands (./exec.sh, sbx run --name) are not printed: $(out)"
# PLANTED: a command whose words the host shell would expand and run; the stub's exec exits 3
RC=$(run run.sh STUB_EXEC_RC=3 -- bash -c 'echo $HOME; touch planted-arg')
[ "${RC}" == "3" ] || fail "3: an interactive run whose command exits 3 made run.sh exit ${RC}: $(out)"
grep -q "ERROR" "${D}/out" && fail "3: an interactive run's own exit status was reported as an ERROR: $(grep ERROR "${D}/out")"
grep -qF "${NEXT}" "${D}/out" && fail "3: an interactive run printed the detached run's next commands"
[ "$(calls | tr '\n' '~')" == "sbx|ls|-q|~${CREATE}~sbx|exec|-it|test-sandbox-agent|bash|-c|echo \$HOME; touch planted-arg|~" ] \
	|| fail "3: the interactive run is not the create followed by sbx exec -it <name> with the command's three words: $(calls | tr '\n' ' ')"
[ -e "${D}/copy/planted-arg" ] && fail "3: the interactive run's command ran on the host (planted-arg was created there)"
RC=$(run run.sh STUB_CREATE_RC=125)
[ "${RC}" == "125" ] || fail "3: run.sh exited ${RC} when the create exited 125 (expected 125): $(out)"
grep -q "planted create failure" "${D}/out" || fail "3: sbx's own error is not in run.sh's output: $(out)"
grep -qxF "run.sh: ERROR - the start command exited 125 (the lines above name the cause); fix it, then ./stop.sh && ./run.sh" "${D}/out" \
	|| fail "3: no ERROR line naming the create's exit 125: $(out)"
[ "$(grep -c 'ERROR' "${D}/out")" == "1" ] || fail "3: not exactly one ERROR line when the create exited 125: $(grep ERROR "${D}/out" | tr '\n' ' ')"
calls | grep -q '^sbx|exec|' && fail "3: sbx exec ran after a create that failed"
no_other 3
echo "ok 3 - run.sh: one sbx create with --cpus ${CPUS} --memory ${MEMORY} --skills off and the ./ kit path, exit 0, the two next commands printed; an interactive run adds sbx exec -it <name> with the command's words intact, nothing of it run on the host, and exits with its status (3); a create exiting 125: exit 125, one ERROR line, no exec"

# --- 4. status.sh ---
RC=$(run status.sh)
[ "${RC}" == "0" ] || fail "4: status.sh exited ${RC} (expected 0): $(out)"
[ "$(calls | tr '\n' ' ')" == "sbx|ls| " ] || fail "4: status.sh did not run exactly sbx ls: $(calls | tr '\n' ' ')"
grep -q "^SANDBOX " "${D}/out" || fail "4: the header line of sbx ls is not printed: $(out)"
grep -q "^test-sandbox-agent " "${D}/out" || fail "4: the planted sandbox's line is not printed: $(out)"
grep -q "^test-sandbox-agent-prebuild " "${D}/out" && fail "4: the line of a sandbox whose name starts with the same letters is printed: $(out)"
grep -q "^other-sandbox " "${D}/out" && fail "4: another sandbox's line is printed: $(out)"
no_other 4
echo "ok 4 - status.sh runs sbx ls and prints the header and the planted sandbox's line only"

# --- 5. exec.sh ---
SHELL_CMD="sh|-c|if [ -e /bin/bash ]; then /bin/bash; else sh; fi|"
RC=$(run exec.sh)
[ "${RC}" == "0" ] && [ "$(calls)" == "sbx|exec|-it|test-sandbox-agent|${SHELL_CMD}" ] || fail "5: exec.sh with no argument is not sbx exec -it <name> sh -c '...bash...' (rc ${RC}): $(calls)"
RC=$(run exec.sh -- whoami)
[ "${RC}" == "0" ] && [ "$(calls)" == "sbx|exec|-it|test-sandbox-agent|whoami|" ] || fail "5: exec.sh whoami is not sbx exec -it <name> whoami (rc ${RC}): $(calls)"
RC=$(run exec.sh -- -s)
[ "${RC}" == "0" ] && [ "$(calls)" == "sbx|exec|-it|-e|TMUX_AUTO_ATTACH=false|test-sandbox-agent|${SHELL_CMD}" ] || fail "5: exec.sh -s does not inject -e TMUX_AUTO_ATTACH=false before the name (rc ${RC}): $(calls)"
RC=$(run exec.sh -- -s whoami)
[ "${RC}" == "0" ] && [ "$(calls)" == "sbx|exec|-it|-e|TMUX_AUTO_ATTACH=false|test-sandbox-agent|whoami|" ] || fail "5: exec.sh -s whoami does not compose (rc ${RC}): $(calls)"
no_other 5
echo "ok 5 - exec.sh: a shell in the sandbox by default, the command given otherwise, -s injected before the sandbox name alone and with a command"

# --- 6. stop.sh ---
RC=$(run stop.sh)
[ "${RC}" == "0" ] || fail "6: stop.sh exited ${RC} (expected 0): $(out)"
[ "$(calls | tr '\n' ' ')" == "sbx|rm|--force|test-sandbox-agent| " ] || fail "6: stop.sh did not run exactly sbx rm --force <name> (a kanban.sh, docker.sh or plane.sh teardown?): $(calls | tr '\n' ' ')"
no_other 6
echo "ok 6 - stop.sh runs sbx rm --force <name> and nothing else"

# --- 7. logs.sh, and no docker or kubectl in checks 1 to 7 ---
RC=$(run logs.sh)
[ "${RC}" == "0" ] || fail "7: logs.sh exited ${RC} (expected 0): $(out)"
[ -e "${D}/calls" ] && fail "7: logs.sh called sbx: $(calls | tr '\n' ' ')"
[ "$(grep -c '^logs.sh: TO=sandbox' "${D}/out")" == "1" ] || fail "7: logs.sh did not print exactly one explanation line: $(out)"
grep -q "^logs.sh: TO=sandbox - a sandbox has no log stream to follow" "${D}/out" || fail "7: the line does not say a sandbox has no log stream: $(out)"
grep -qF "sbx run --name test-sandbox-agent" "${D}/out" && grep -qF "./exec.sh" "${D}/out" || fail "7: the line does not name sbx run --name <name> and ./exec.sh: $(out)"
no_other 7
echo "ok 7 - logs.sh says once that a sandbox has no log stream, names sbx run --name <name> and ./exec.sh, exits 0, calls no sbx; no script called docker or kubectl under TO=sandbox"

# --- 8. the preflight names each gap, nothing rendered or created ---
local_env 'export SBX=sbx-planted-missing'
for S in build.sh run.sh; do
	RC=$(run ${S})
	[ "${RC}" == "1" ] || fail "8: ${S} exited ${RC} with the sbx cli not on PATH (expected 1): $(out)"
	grep -q "^${S}: sbx-planted-missing is not on PATH - install sbx 0.47.0" "${D}/out" || fail "8: ${S} does not name the missing cli and its install: $(out)"
	[ -e "${D}/calls" ] && fail "8: ${S} ran something with the sbx cli missing: $(calls | tr '\n' ' ')"
done
local_env
RC=$(run run.sh PREFLIGHT_KVM="${D}/no-such-kvm")
[ "${RC}" == "1" ] || fail "8: run.sh exited ${RC} without the KVM device (expected 1): $(out)"
grep -q "^run.sh: no ${D}/no-such-kvm - this host has no hypervisor" "${D}/out" && grep -qF "cloud sandbox from a pushed kit" "${D}/out" \
	|| fail "8: run.sh does not name the no-hypervisor cause and the cloud alternative: $(out)"
calls | grep -q '^sbx|create|' && fail "8: run.sh created a sandbox without the KVM device"
RC=$(run build.sh PREFLIGHT_KVM="${D}/no-such-kvm")
[ "${RC}" == "1" ] && grep -q "^build.sh: no ${D}/no-such-kvm - this host has no hypervisor" "${D}/out" || fail "8: build.sh without the KVM device exited ${RC}: $(out)"
calls | grep -qE '^(render.sh|sbx\|create)' && fail "8: build.sh rendered or created without the KVM device: $(calls | tr '\n' ' ')"
RC=$(run build.sh STUB_DAEMON_DOWN=1)
[ "${RC}" == "1" ] || fail "8: build.sh exited ${RC} with the daemon not answering (expected 1): $(out)"
grep -q "^build.sh: the local sandbox daemon does not answer (sbx ls -q fails)" "${D}/out" && grep -qF "'sbx login'" "${D}/out" && grep -qF "'sbx daemon start -d'" "${D}/out" \
	|| fail "8: build.sh does not name the daemon and its two fixes: $(out)"
[ "$(calls | tr '\n' ' ')" == "sbx|ls|-q| " ] || fail "8: build.sh ran more than the daemon check with the daemon down: $(calls | tr '\n' ' ')"
printf 'schemaVersion: "3"\nkind: workload\ncapabilities:\n  - type: com.docker.sandbox/sbx@1\n' > "${D}/copy/to/sandbox/template/planted-no-resources.yaml"
local_env 'export SANDBOX_DESCRIPTOR=./to/sandbox/template/planted-no-resources.yaml'
RC=$(run run.sh)
[ "${RC}" == "1" ] || fail "8: run.sh exited ${RC} with a descriptor without resources@1 (expected 1): $(out)"
grep -q "^run.sh: could not read cpu and memory from the kit descriptor's resources@1 (./to/sandbox/template/planted-no-resources.yaml)" "${D}/out" \
	|| fail "8: run.sh does not name the descriptor it could not read: $(out)"
grep -qF "(./to/sandbox/template/planted-no-resources.yaml): no com.docker.sandbox/resources@1 capability" "${D}/out" \
	|| fail "8: the line does not say the descriptor has no resources@1 capability: $(out)"
grep -q "Traceback" "${D}/out" && fail "8: a Python traceback reached the output: $(out)"
calls | grep -q '^sbx|create|' && fail "8: run.sh created a sandbox without sizes"
local_env 'export SANDBOX_DESCRIPTOR=./to/sandbox/template/planted-missing.yaml'
RC=$(run run.sh)
[ "${RC}" == "1" ] || fail "8: run.sh exited ${RC} with a descriptor path that does not exist (expected 1): $(out)"
grep -q "^run.sh: could not read cpu and memory from the kit descriptor's resources@1 (./to/sandbox/template/planted-missing.yaml): .*No such file or directory" "${D}/out" \
	|| fail "8: run.sh does not name the missing descriptor and that there is no such file: $(out)"
calls | grep -q '^sbx|create|' && fail "8: run.sh created a sandbox without a descriptor"
echo "ok 8 - preflight sandbox: the sbx cli missing, no KVM device, the daemon not answering, a descriptor without resources@1 (the line says so) and a descriptor path with no file (the line says so) each stop build.sh and run.sh with exit 1, the gap and its fix named, nothing rendered or created"

# --- 9. CONTROL: the docker target is unchanged ---
docker_env
RC=$(run build.sh BUILD_MIN_FREE_GB=1)
[ "${RC}" == "0" ] || fail "9: build.sh on the docker target exited ${RC} (expected 0): $(out)"
grep -q '^docker|image|build|' "${D}/other" || fail "9: build.sh on the docker target ran no docker image build: $(tr '\n' ' ' < "${D}/other" | cut -c1-200)"
[ -e "${D}/calls" ] && fail "9: build.sh on the docker target called sbx or render.sh: $(calls | tr '\n' ' ')"
RC=$(run run.sh)
[ "${RC}" == "0" ] || fail "9: run.sh on the docker target exited ${RC} (expected 0): $(out)"
grep -q '^docker|container|run|.*|do-agent-aws:latest|$' "${D}/other" || fail "9: run.sh on the docker target did not run docker container run ending with the image: $(grep '^docker|container|run' "${D}/other" | tail -c 200)"
[ -e "${D}/calls" ] && fail "9: run.sh on the docker target called sbx or render.sh: $(calls | tr '\n' ' ')"
docker_env 'export DRY_RUN=true'
RC=$(run status.sh)
[ "${RC}" == "0" ] && [ "$(cat "${D}/out")" == "docker ps -a | grep test-sandbox-agent" ] || fail "9: status.sh on the docker target changed (rc ${RC}): $(out)"
RC=$(run exec.sh)
[ "${RC}" == "0" ] && [ "$(cat "${D}/out")" == "docker container exec -it test-sandbox-agent sh -c 'if [ -e /bin/bash ]; then /bin/bash; else sh; fi'" ] || fail "9: exec.sh on the docker target changed (rc ${RC}): $(out)"
RC=$(run logs.sh)
[ "${RC}" == "0" ] && [ "$(cat "${D}/out")" == "docker container logs -f test-sandbox-agent" ] || fail "9: logs.sh on the docker target changed (rc ${RC}): $(out)"
RC=$(run stop.sh)
[ "${RC}" == "0" ] && [ "$(cat "${D}/out")" == "$(printf '%s\n%s' 'docker container exec test-sandbox-agent /agent/supervisor.sh record-stop' 'docker container rm -f -v test-sandbox-agent')" ] \
	|| fail "9: stop.sh on the docker target changed (rc ${RC}; expected the session ledger's record-stop exec, then the rm): $(out)"
[ "$(calls | tr '\n' ' ')" == "kanban.sh|down| docker.sh|down| plane.sh|down| " ] || fail "9: stop.sh on the docker target did not tear the boards' and the substrate's sidecars down as before: $(calls | tr '\n' ' ')"
echo "ok 9 - the docker target is unchanged: build.sh builds the image, run.sh's start ends with the image, status.sh, exec.sh, logs.sh and stop.sh echo the docker commands as before (stop.sh the ledger's record-stop exec, then the rm) with the boards' and the substrate's teardown, and sbx and render.sh never ran"

echo "Test-sandbox succeeded"
