#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Sandbox e2e - the harness end to end in a Docker Sandbox, local or cloud.
#
#   usage: to/sandbox/test/e2e.sh --cloud|--local [options]
#
#   --kit REF           kit to run: a pushed image (docker.io/<namespace>/do-agent-aws-sandbox:<tag>)
#                       or a kit directory. Default: to/sandbox/app/do-agent-aws-sandbox, rendered
#                       by to/sandbox/render.sh. sbx builds a kit directory in a local builder
#                       sandbox (sbx kit builder --help), which needs KVM, so from a host without
#                       /dev/kvm a cloud run takes a pushed image (or try --allow-source-kit).
#                       An image is checked before anything is created: docker buildx imagetools
#                       reads its digest, and the run then uses only repo@digest; kit-tck
#                       (KIT_TCK=/path or on PATH) reads its published descriptor and its staged
#                       recipe, which must be HEAD's; and it must not resolve anonymously (a public
#                       kit image is refused).
#   --name NAME         sandbox name (default do-agent-aws-e2e-<UTC timestamp>). The model
#                       credential is a bedrock secret scoped to this one sandbox: choose the
#                       name and store it first (local: a command secret that runs the
#                       installed copy of to/sandbox/bedrock-token.sh, outside the checkout
#                       and every sandbox mount; to/sandbox/README.md "Model credential");
#                       teardown removes that secret, before the sandbox. A global bedrock
#                       secret alone is not used.
#   --ttl DURATION      cloud time-to-live; the sandbox is deleted when it lapses (default 4h:
#                       it must cover the summed per-call timeouts, BUDGET; a passing run
#                       removes the sandbox itself, typically within 30 minutes)
#   --out DIR           results directory (default wd/sandbox-e2e/<UTC timestamp>)
#   --skip-agent        do not run the agent layer (recorded NOT_RUN)
#   --require-agent     the run must exercise the model: whatever keeps the agent layer from
#                       running (no sandbox-scoped bedrock secret, no binding, ...) blocks
#                       preflight with AGENT_NOT_RUNNABLE, and locally a failed host model
#                       check (below) with MODEL_NOT_VERIFIED, instead of a PARTIAL run
#   --keep              keep the sandbox at the end (default: remove it with --force); not after
#                       the platform layer finds the model key at risk (below), when the sandbox
#                       and its sandbox-scoped secret are removed all the same
#   --allow-source-kit  cloud run with a kit directory on a host without /dev/kvm
#   --dry-run           run only the checks that create nothing in sbx or the cloud, print the
#                       commands a real run issues, and stop before the first one (sbx create).
#                       Like a real run it renders to/sandbox/app/ (from HEAD) and sources .env,
#                       whose mkdir creates wd/agent-state/ (both are gitignored). Locally, when
#                       the agent layer would run, it also runs the host model check: the helper
#                       makes a key on this host and one smallest Converse request goes to each
#                       of the two pinned models (billed, a few tokens each).
#
# Layers - each one is a verdict in summary.json:
#   preflight   bash 4.4+, tools, sbx >= 0.47.0, sign-in and sbx diagnose, KVM and a deny-all
#               global network policy (local: no global network allow rule), a free sandbox
#               name, a clean tracked tree and nothing credential-shaped in what is uploaded
#               (test/credential-shapes.txt), the kit (descriptor invariants; for an image
#               also its digest, published descriptor and recipe, and that it is not public;
#               local, for a kit directory, that sbx has built it already, so that create
#               does not build it: KIT_NOT_BUILT otherwise, with the commands that do),
#               a TTL that covers the per-call timeouts (cloud), the model secret (a bedrock
#               secret scoped to the sandbox; a global one alone is not used) and its binding
#               for bedrock-runtime.us-east-1.amazonaws.com (they decide whether the agent
#               layer runs); locally, when the agent layer would run, the host model check:
#               the installed helper makes a key on this host (only its prefix is checked)
#               and one smallest Converse request to each model the image pins must answer
#               200 (it checks the profile, the role and the helper, not the sandbox's proxy;
#               it runs the default helper, or E2E_BEDROCK_HELPER, for profile bedrock in
#               us-east-1, so the sandbox's secret must run the same command)
#   create      sbx [--cloud] create with the descriptor's --cpus/--memory (cloud: --ttl,
#               --on-timeout delete, --platform linux/amd64; local: --skills off), with no
#               workspace path (no host mount) and no published port
#   provenance  the sandbox's /test*.sh and its staged kit recipe are HEAD's
#   policy      cloud: the sandbox's own policy is set to deny-all; both: an allowlisted host
#               (ECR Public) answers, four hosts off the list (example.com, registry.npmjs.org
#               from the balanced preset, the Anthropic API and Docker Hub) are refused and sbx
#               policy log lists them as blocked, and the Bedrock runtime endpoint answers from AWS (its
#               x-amzn-RequestId header) through the proxy, to curl and to Node; that answer's
#               HTTP code is recorded, not judged (the credential is exercised by the harness's
#               test3 and the agent layer). Unless this layer and provenance pass, nothing live
#               runs: platform, harness, example and agent are NOT_RUN, the sandbox is
#               removed, the exit is 1
#   platform    root identity, the sandbox's own Docker Engine, and the declared CPU and
#               memory (nproc or cpu.max; MemTotal or memory.max within 3/4 to 17/16 of it);
#               the model key stays on the host: AWS_BEARER_TOKEN_BEDROCK in the sandbox
#               never starts like a Bedrock API key (bedrock-api-key- for a short-term key,
#               ABSK for a long-term one), and with the model credential configured it is
#               the proxy's sentinel proxy-managed (only its length and those two facts are
#               recorded, never the value). Unless that check passes, nothing live
#               runs after it: harness, example and agent are NOT_RUN ("credential isolation
#               unverified"), the sandbox is removed, the exit is 1
#   harness     the image's /test*.sh suite - what ./test.sh runs - under bash, with the
#               repository's tracked files copied to /do-agent-aws and the harness settings
#               from .env; every test must succeed (test3, the model loop test, may skip only
#               without a credential)
#   example     to/sandbox/example/compose-demo in with sbx cp, its deterministic layer, the
#               result copied out before anything else runs
#   agent       the same task for Claude Code as a headless prompt (claude -p, under bash),
#               judged by a fresh copy of verify-agent-report.py copied in after the session,
#               from the report file and the engine's event log; the example files must come
#               back unchanged; NOT_RUN without a configured credential
#   stack       the whole platform started by /startup.sh (as the kit's boot hook does on a
#               plain create; e2e suppressed that autostart so the harness suite ran in a
#               platform-free VM) and watched through /agent/ui-status.sh until the supervisor
#               is UP, the hub and every enabled spoke are LIVE and every enabled UI is UP;
#               conversations and issues are a documented OFF (Slack and GitHub are off the
#               allowlist); hindsight-seed's line is recorded, not judged
#   results     /root/workspace/out copied out; refused (and the links removed) if it holds a symlink
#   ttl         cloud: the TTL read back is running, neither stopped nor paused, with a
#               future expiry
#   teardown    sbx [--cloud] rm --force (by name, and by id when create printed one) whenever
#               create was attempted, then the name is gone from sbx ls (also on any failure
#               or interrupt); a sandbox never listed is watched for E2E_TEARDOWN_WATCH
#               seconds (default 180), removed if it appears, and otherwise UNVERIFIED
#   secret      when the run used a sandbox-scoped bedrock secret: removed at teardown,
#               before the sandbox, and no longer listed (a global secret is never touched)
# Every directory or file copied out of the sandbox is refused, unread, if it holds a symlink.
# Every sbx call has a host-side timeout, reads no terminal input, runs in the background so
# INT/TERM/HUP are handled at once (the call is killed, then teardown runs; teardown itself
# ignores them until it finishes, and says so with its bound), and is logged with a
# UTC timestamp to commands.log. Exit 0 (PASS) only when every layer passed, the agent layer
# included; 3 (PARTIAL) when every layer that ran passed but the agent layer did not run or the
# sandbox was kept; 1 (FAIL) when a layer failed or teardown is UNVERIFIED; 2 (BLOCKED) when
# preflight stopped the run (nothing was created). A clean dry run reports DRY_RUN, exit 0.
#
# Host requirements: bash 4.4+, sbx, jq, python3 with PyYAML, git, coreutils timeout; docker with
# buildx and kit-tck when --kit is an image reference; curl for a local run with a kit directory.
#
# Everything the sandbox receives from this host comes from the commit at HEAD (git archive):
# the rendered kit, the repository copy, the example and the expected hashes; commit first.
#
# Differences from ./test.sh, on purpose: no host mounts (a cloud sandbox has none) - the
# repository's files at HEAD are copied to /do-agent-aws with sbx cp, where ./test.sh mounts
# it; no host credentials passed in (the Bedrock key is proxy-injected); and the proxy variables
# of .env are not passed (they would override the sandbox's egress proxy) - localhost and
# 127.0.0.1 are appended to NO_PROXY instead, as .env's no_proxy=localhost intends.

# shellcheck disable=SC2086,SC2206  # ${CLOUD} is unquoted on purpose (see where it is set)
set -u -o pipefail

if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
	echo "e2e.sh: bash 4.4 or newer is required" >&2
	exit 2
fi

BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SBX_DIR=${BASE_DIR}/to/sandbox
KIT_NAME=do-agent-aws-sandbox
EXAMPLE_REL=to/sandbox/example/compose-demo
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
# Sizes come from the kit descriptor at HEAD (read in preflight).
CPUS=""
MEMORY=""
# Per-call host-side timeouts (seconds). The cloud TTL must cover their sum up to
# teardown (BUDGET), so the sandbox cannot lapse while a call may still run.
# Each can be set in the environment (E2E_T_CREATE=1800 ...) without an edit,
# which DIRTY_TREE would refuse.
T_CREATE=${E2E_T_CREATE:-1200}
T_QUICK=${E2E_T_QUICK:-60}
T_COPY=${E2E_T_COPY:-180}
T_PLATFORM=${E2E_T_PLATFORM:-300}
# 46 /test*.sh: 39 of them took 2400 s in a 4-CPU local sandbox
T_HARNESS=${E2E_T_HARNESS:-5400}
T_EXAMPLE=${E2E_T_EXAMPLE:-1200}
T_AGENT=${E2E_T_AGENT:-1000}
# The stack layer: /startup.sh, then poll /agent/ui-status.sh until the supervisor,
# the hub, the enabled spokes and the enabled UIs are up (or this bound elapses).
T_STACK=${E2E_T_STACK:-600}
BUDGET=$(( T_CREATE + 30 * T_QUICK + T_PLATFORM + 10 * T_COPY + T_HARNESS + T_EXAMPLE + T_AGENT + T_STACK ))
# Local preflight only, not in BUDGET: how long the kit build check waits for sbx's kit
# registry, which copies a new build in from the Docker engine on the first request (see there).
T_KIT_REGISTRY=${E2E_T_KIT_REGISTRY:-600}
# Worst case of teardown, each call at its timeout plus the 30 s before KILL: secret
# rm and ls (60 s each), rm by name and by id (300 s each), the watch for a sandbox
# never listed (ls polls 10 s apart, then one rm) and 18 absence polls (ls, 5 s apart).
TEARDOWN_BOUND=$(( 2 * (60 + 30) + 2 * (300 + 30) + (${E2E_TEARDOWN_WATCH:-180} / 10) * (60 + 30 + 10) + (300 + 30) + 18 * (60 + 30 + 5) ))
MIN_SBX_VERSION=0.47.0
IN_SANDBOX_OUT=/root/workspace/out
IN_SANDBOX_EXAMPLE=/root/workspace/compose-demo
# The recipe the kit frontend stages into the image (verified in the image test2.sh builds).
IN_SANDBOX_RECIPE=/usr/share/sandbox/kit/${KIT_NAME}/kit.dockerfile

MODE=""
KIT=""
KIT_REQUESTED=""
NAME="do-agent-aws-e2e-${STAMP,,}"
TTL=4h
OUT=""
SKIP_AGENT=false
REQUIRE_AGENT=false
KEEP=false
ALLOW_SOURCE_KIT=false
DRY_RUN=false

usage()
{
	awk 'NR >= 5 && /^#/ {sub(/^# ?/, ""); print; next} NR >= 5 {exit}' "$0"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--cloud) MODE=cloud ;;
	--local) MODE=local ;;
	--kit) KIT="${2:?--kit needs a value}"; shift ;;
	--name) NAME="${2:?--name needs a value}"; shift ;;
	--ttl) TTL="${2:?--ttl needs a value}"; shift ;;
	--out) OUT="${2:?--out needs a value}"; shift ;;
	--skip-agent) SKIP_AGENT=true ;;
	--require-agent) REQUIRE_AGENT=true ;;
	--keep) KEEP=true ;;
	--allow-source-kit) ALLOW_SOURCE_KIT=true ;;
	--dry-run) DRY_RUN=true ;;
	-h|--help) usage; exit 0 ;;
	*) echo "e2e.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done
[ -n "${MODE}" ] || { echo "e2e.sh: choose --cloud or --local" >&2; usage >&2; exit 2; }
[ -n "${OUT}" ] || OUT=${BASE_DIR}/wd/sandbox-e2e/${STAMP}
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
CMDLOG=${OUT}/commands.log
LAYERS=${OUT}/layers.tsv
: > "${CMDLOG}"
: > "${LAYERS}"
rm -f "${OUT}/summary.json"
# "--cloud" or empty; expanded unquoted on purpose so it disappears in local mode.
CLOUD=""
[ "${MODE}" = "cloud" ] && CLOUD=--cloud
# For messages: "sbx" or "sbx --cloud".
SBXC="sbx${CLOUD:+ ${CLOUD}}"
ATTEMPTED=false
# A teardown from the main flow is retried once by on_exit if it fails; the one
# on_exit runs is not.
TEARDOWN_RETRY=true
SEEN=false
SANDBOX_ID=""
# The first line of "sbx version", read once in preflight; write_summary reuses it
# (it may run during teardown, while signals are ignored, so it calls nothing).
SBX_VERSION_LINE=""
KIT_DIGEST=""
# Local runs with a kit directory: the reference of sbx's build of it, once preflight found it.
KIT_BUILT=""
CREDENTIAL=unknown
SECRET_SCOPE=none
BINDING=unknown
MODEL_CRED=absent
AGENT_PLAN=NOT_RUN
AGENT_REASON=""
# The host model check: not-run (nothing to check), ok or fail, with its reason.
MODEL_CHECK=not-run
MODEL_CHECK_DETAIL=""
# The check's directory while it holds the key; on_exit removes it, so an interrupt does not
# leave the key behind.
MODEL_CHECK_DIR=""

note()
{
	echo "$(date -u +%FT%TZ) $*" | tee -a "${OUT}/e2e.log"
}

# Every sbx call goes through sbx_run, and every other slow tool through run_bg:
# logged, bounded by a host-side timeout (SBX_T seconds for sbx, default T_QUICK;
# KILL 30 s after TERM), and never reading the terminal, so an approval prompt
# fails the call instead of hanging it. The call runs in the background and is
# waited for, so INT/TERM/HUP are handled at once (timeout puts itself in its own
# process group, which a foreground wait would sit behind) and the handler kills
# it. The exit code is the command's (124 on timeout).
BG_PID=""
run_bg()
{
	# $1 = timeout in seconds, then the command. Logged, bounded, no terminal
	# input; run in the background and waited for, so that INT, TERM and HUP are
	# handled at once and the handler can kill it.
	local t=$1 rc
	shift
	echo "$(date -u +%FT%TZ) + [timeout ${t}s] $(echo "$*" | tr '\n' ' ')" >> "${CMDLOG}"
	timeout -k 30 "${t}" "$@" < /dev/null {E2E_STDOUT_FD}>&- {E2E_STDERR_FD}>&- &
	BG_PID=$!
	# A command substitution does not inherit the script's traps.
	[ "${BASH_SUBSHELL}" -gt 0 ] && trap 'kill -TERM "${BG_PID}" 2> /dev/null; exit 130' INT TERM HUP
	wait "${BG_PID}"
	rc=$?
	BG_PID=""
	return ${rc}
}

sbx_run()
{
	run_bg "${SBX_T:-${T_QUICK}}" sbx "$@"
}

sbx_exec()
{
	sbx_run ${CLOUD} exec "$@"
}

layer()
{
	# $1 = layer, $2 = PASS|FAIL|NOT_RUN|BLOCKED, $3 = detail
	printf '%s\t%s\t%s\n' "$1" "$2" "$(echo "$3" | tr '\t\n' '  ')" >> "${LAYERS}"
	note "layer $1: $2 - $3"
}

layer_status()
{
	awk -F'\t' -v l="$1" '$1 == l {s = $2} END {print s}' "${LAYERS}"
}

write_summary()
{
	# $1 = exit code, $2 = overall
	S_MODE="${MODE}" S_KIT="${KIT}" S_KITREQ="${KIT_REQUESTED}" S_DIGEST="${KIT_DIGEST}" S_NAME="${NAME}" S_ID="${SANDBOX_ID}" \
	S_TTL="${TTL}" S_STAMP="${STAMP}" S_DRY="${DRY_RUN}" S_SBX="${SBX_VERSION_LINE}" \
	S_HEAD="$(git -C "${BASE_DIR}" rev-parse HEAD 2>/dev/null)" \
	S_DIRTY="$(git -C "${BASE_DIR}" status --porcelain 2>/dev/null | grep -c .)" \
	S_CRED="${CREDENTIAL}" S_SCOPE="${SECRET_SCOPE}" S_BIND="${BINDING}" S_MODEL="${MODEL_CRED}" S_EXIT="$1" S_OVERALL="$2" \
	S_MCHECK="${MODEL_CHECK}" S_MDETAIL="${MODEL_CHECK_DETAIL}" S_REQAGENT="${REQUIRE_AGENT}" \
	python3 - "${LAYERS}" "${OUT}/summary.json" << 'EOF'
import datetime, json, os, sys
e = os.environ
layers = {}
for line in open(sys.argv[1]):
    name, status, detail = (line.rstrip("\n").split("\t") + ["", ""])[:3]
    layers[name] = {"status": status, "detail": detail}
summary = {
    "test": "to/sandbox/test/e2e.sh",
    "mode": e["S_MODE"],
    "dry_run": e["S_DRY"] == "true",
    "kit": e["S_KIT"],
    "kit_requested": e["S_KITREQ"] or None,
    "kit_digest": e["S_DIGEST"] or None,
    "sandbox": e["S_NAME"],
    "sandbox_id": e["S_ID"] or None,
    "ttl": e["S_TTL"] if e["S_MODE"] == "cloud" else None,
    "started": e["S_STAMP"],
    "finished": datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
    "sbx_version": e["S_SBX"],
    "repo_head": e["S_HEAD"],
    "repo_dirty_paths": int(e["S_DIRTY"] or 0),
    "credential": {"model_service": "bedrock", "model_secret": e["S_CRED"], "secret_scope": e["S_SCOPE"], "binding": e["S_BIND"], "model_usable": e["S_MODEL"]},
    "require_agent": e["S_REQAGENT"] == "true",
    "host_model_check": {"status": e["S_MCHECK"], "detail": e["S_MDETAIL"]},
    "layers": layers,
    "exit_code": int(e["S_EXIT"]),
    "overall": e["S_OVERALL"],
}
with open(sys.argv[2], "w") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
EOF
}

finish()
{
	# $1 = exit code, $2 = overall (default from the exit code)
	local overall=${2:-}
	[ -n "${overall}" ] || case "$1" in 0) overall=PASS ;; 2) overall=BLOCKED ;; 3) overall=PARTIAL ;; *) overall=FAIL ;; esac
	write_summary "$1" "${overall}"
	note "summary ${OUT}/summary.json (${overall}, exit $1)"
	exit "$1"
}

teardown()
{
	[ "${ATTEMPTED}" = "true" ] || return 0
	# Nothing interrupts the cleanup once it starts.
	trap '' INT TERM HUP
	if [ "${KEEP}" = "true" ]; then
		ATTEMPTED=false
		layer teardown NOT_RUN "--keep: sandbox ${NAME} left in place; remove it with: ${SBXC} rm --force ${NAME}"
		[ "${SECRET_SCOPE}" = "sandbox" ] && layer secret NOT_RUN "--keep: the sandbox-scoped secret stays; remove it with: ${SBXC} secret rm bedrock --sandbox ${NAME} -f"
		return 0
	fi
	if [ "${TEARDOWN_RETRY}" = "true" ]; then
		note "teardown of ${NAME} in progress: INT, TERM and HUP are ignored until it finishes (at most ${TEARDOWN_BOUND} s; if it fails, it is retried once on exit: at most $(( 2 * TEARDOWN_BOUND )) s in all)"
	else
		note "teardown of ${NAME} in progress: INT, TERM and HUP are ignored until it finishes (at most ${TEARDOWN_BOUND} s)"
	fi
	# A sandbox-scoped model secret goes first, while the sandbox still exists;
	# a global secret is never touched.
	if [ "${SECRET_SCOPE}" = "sandbox" ]; then
		SBX_T=60 sbx_run ${CLOUD} secret rm bedrock --sandbox "${NAME}" -f > "${OUT}/secret-rm.log" 2>&1
		local src=$?
		if SBX_T=60 sbx_run ${CLOUD} secret ls --sandbox "${NAME}" --service bedrock -q > "${OUT}/secret-after.txt" 2>> "${OUT}/secret-rm.log" \
			&& ! grep -q . "${OUT}/secret-after.txt"; then
			layer secret PASS "sandbox-scoped bedrock secret of ${NAME} removed (rm exit ${src}) and no longer listed"
		else
			layer secret FAIL "the sandbox-scoped bedrock secret of ${NAME} may remain (rm exit ${src}, secret-rm.log); remove it with: ${SBXC} secret rm bedrock --sandbox ${NAME} -f"
		fi
	fi
	SBX_T=300 sbx_run ${CLOUD} rm --force "${NAME}" >> "${OUT}/teardown.log" 2>&1
	local rc=$? gone=false
	[ "${MODE}" = "cloud" ] && [ -n "${SANDBOX_ID}" ] && SBX_T=300 sbx_run --cloud rm --force "${SANDBOX_ID}" >> "${OUT}/teardown.log" 2>&1
	if [ "${SEEN}" != "true" ]; then
		# Never listed: create may have timed out while provisioning goes on.
		# Watch for it (E2E_TEARDOWN_WATCH seconds, default 180) and remove it
		# if it shows up.
		for _ in $(seq 1 $(( ${E2E_TEARDOWN_WATCH:-180} / 10 ))); do
			if SBX_T=60 sbx_run ${CLOUD} ls -q > "${OUT}/ls-watch.txt" 2>> "${OUT}/teardown.log" \
				&& grep -qxF "${NAME}" "${OUT}/ls-watch.txt"; then
				SEEN=true
				SBX_T=300 sbx_run ${CLOUD} rm --force "${NAME}" >> "${OUT}/teardown.log" 2>&1
				break
			fi
			sleep 10
		done
	fi
	for _ in $(seq 1 18); do
		if SBX_T=60 sbx_run ${CLOUD} ls -q > "${OUT}/ls-after-rm.txt" 2>> "${OUT}/teardown.log" \
			&& ! grep -qxF "${NAME}" "${OUT}/ls-after-rm.txt"; then
			gone=true
			break
		fi
		sleep 5
	done
	# ATTEMPTED stays set unless the removal is verified, so on_exit tries once more.
	if [ "${gone}" = "true" ] && [ "${SEEN}" = "true" ]; then
		ATTEMPTED=false
		layer teardown PASS "absent from ${SBXC} ls after ${SBXC} rm --force ${NAME} (rm exit ${rc})"
	elif [ "${gone}" = "true" ]; then
		ATTEMPTED=false
		local ttl_note="otherwise its TTL removes it"
		[ "${MODE}" = "cloud" ] || ttl_note="a local sandbox has no TTL, so nothing else will"
		layer teardown UNVERIFIED "${NAME} was never listed by ${SBXC} ls, during the run or for ${E2E_TEARDOWN_WATCH:-180} s after; rm --force was issued by name${SANDBOX_ID:+ and by id ${SANDBOX_ID}}; confirm with: ${SBXC} ls, and if it is listed, remove it with: ${SBXC} rm --force ${NAME} (${ttl_note})"
	else
		layer teardown FAIL "still listed or ls failing after rm (rm exit ${rc}); check: ${SBXC} ls; remove with: ${SBXC} rm --force ${NAME}"
	fi
}

on_exit()
{
	local rc=$?
	# Nothing interrupts the cleanup: a further INT, TERM or HUP is ignored from here.
	trap '' INT TERM HUP
	# Back to the caller's stdout and stderr, whatever call was redirected when it came.
	exec 1>&"${E2E_STDOUT_FD}" 2>&"${E2E_STDERR_FD}"
	[ -z "${MODEL_CHECK_DIR}" ] || rm -rf "${MODEL_CHECK_DIR}"
	if [ "${ATTEMPTED}" = "true" ]; then
		note "exiting with a sandbox possibly present; tearing down"
		TEARDOWN_RETRY=false
		teardown
		write_summary 1 FAIL
		exit 1
	fi
	# Every path leaves a summary.json.
	[ -f "${OUT}/summary.json" ] || write_summary "$(( rc == 0 ? 1 : rc ))" FAIL
	exit ${rc}
}
on_signal()
{
	trap '' INT TERM HUP
	exec 1>&"${E2E_STDOUT_FD}" 2>&"${E2E_STDERR_FD}"
	note "interrupted"
	[ -n "${BG_PID}" ] && kill -TERM "${BG_PID}" 2> /dev/null
	exit 1
}
# The caller's stdout and stderr, kept for the handlers: a signal usually arrives
# inside a call whose output goes to a log file (sbx_run create > create.log), and
# the handlers would otherwise write there instead of to the terminal. The copies
# are closed for the commands run_bg starts.
exec {E2E_STDOUT_FD}>&1 {E2E_STDERR_FD}>&2
trap on_exit EXIT
trap on_signal INT TERM HUP

version_ge()
{
	[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# The repository at HEAD, as ./test.sh mounts it at /do-agent-aws (test7, test9
# and test10 read its .env there): git archive, so nothing uncommitted,
# untracked or ignored (a credentials file, say) is ever uploaded.
stage_repo()
{
	# $1 = staging directory
	rm -rf "$1"
	mkdir -p "$1"
	git -C "${BASE_DIR}" archive --format=tar HEAD | tar -xf - -C "$1"
}

# sbx cp keeps symlinks: nothing copied out of the sandbox is read on this host
# if it holds one. Prints the symlinks found under the given paths.
has_symlinks()
{
	local p
	for p in "$@"; do
		if [ -e "${p}" ] || [ -L "${p}" ]; then
			find "${p}" -type l -print
		fi
	done | grep .
}

# An image reference without its tag or digest (a registry port is kept).
ref_repo()
{
	local r=${1%%@*}
	case "${r##*/}" in *:*) r=${r%:*} ;; esac
	echo "${r}"
}

sha_of()
{
	sha256sum < "$1" | awk '{print $1}'
}

# --- preflight: nothing here creates anything in sbx or the cloud ------------
note "e2e ${MODE} - results ${OUT}"
BLOCKERS=()
for tool in jq python3 git timeout sbx; do
	command -v "${tool}" > /dev/null || BLOCKERS+=("NEEDS_TOOL ${tool}")
done
python3 -c 'import yaml' 2> /dev/null || BLOCKERS+=("NEEDS_TOOL PyYAML (python3 -m pip install pyyaml)")
SBX_VERSION_OUT=$(SBX_T=60 sbx_run version 2> /dev/null)
SBX_VERSION_LINE=$(echo "${SBX_VERSION_OUT}" | head -1)
SBX_VER=$(echo "${SBX_VERSION_OUT}" | sed -n 's/^sbx version: v\([0-9.]*\).*/\1/p' | head -1)
if [ -z "${SBX_VER}" ] || ! version_ge "${SBX_VER}" "${MIN_SBX_VERSION}"; then
	BLOCKERS+=("NEEDS_SBX >= ${MIN_SBX_VERSION} (found '${SBX_VER:-none}')")
fi

HAVE_KVM=false
[ -e /dev/kvm ] && HAVE_KVM=true
POLICY_UNINIT=false
SBX_T=120 sbx_run ${CLOUD} diagnose > "${OUT}/diagnose.txt" 2>&1
DIAG_RC=$?
SIGNED_IN=true
if grep -q "not signed in" "${OUT}/diagnose.txt"; then
	SIGNED_IN=false
	if [ "${MODE}" = "cloud" ]; then
		BLOCKERS+=("NEEDS_SIGNIN: run 'sbx login' with the Docker account that has the Agentic Platform subscription")
	else
		BLOCKERS+=("NEEDS_SIGNIN: run 'sbx login' (local sandboxes also require a Docker sign-in)")
	fi
elif [ ${DIAG_RC} -ne 0 ] && { [ "${MODE}" = "cloud" ] || [ "${HAVE_KVM}" = "true" ]; }; then
	BLOCKERS+=("DIAGNOSE_FAILED (${SBXC} diagnose exit ${DIAG_RC}): $(grep '✗' "${OUT}/diagnose.txt" | tr '\n' ' ')")
fi

if [ "${MODE}" = "local" ]; then
	[ "${HAVE_KVM}" = "true" ] || BLOCKERS+=("NEEDS_KVM: local sandboxes run a microVM; this host has no /dev/kvm (use --cloud)")
	# Answers without sign-in while the local daemon runs. Deny-all: no network
	# allow rule applies to every sandbox (the summary rows the sbx docs show,
	# "APPLIES TO" all); kit rules apply per sandbox.
	SBX_T=60 sbx_run policy ls > "${OUT}/policy-global.txt" 2>&1
	PLS_RC=$?
	if grep -q "has not been initialized" "${OUT}/policy-global.txt"; then
		# Its commands name the kit and its sizes, so the blocker is added once they are known
		# (after the kit checks below).
		POLICY_UNINIT=true
	elif [ ${PLS_RC} -ne 0 ]; then
		BLOCKERS+=("POLICY_LS_FAILED: sbx policy ls exit ${PLS_RC}: $(tail -1 "${OUT}/policy-global.txt")")
	elif grep -E '[[:space:]]all[[:space:]]' "${OUT}/policy-global.txt" | grep -qE 'network: *[1-9][0-9]* allow'; then
		BLOCKERS+=("NEEDS_DENY_ALL: a network allow rule applies to every sandbox (policy-global.txt); local runs need the deny-all preset and no global allow rule: sbx policy reset, then sbx policy init deny-all")
	fi
fi

# Everything the sandbox receives, and every expected hash, comes from HEAD.
REV=$(git -C "${BASE_DIR}" rev-parse --verify HEAD 2> /dev/null) || BLOCKERS+=("NEEDS_COMMIT: ${BASE_DIR} has no commit to test")
DIRTY_PATHS=$(git -C "${BASE_DIR}" status --porcelain 2> /dev/null | grep -c .)
stage_repo "${OUT}/do-agent-aws" 2> "${OUT}/stage.err" || BLOCKERS+=("STAGE_FAILED: git archive HEAD: $(tail -1 "${OUT}/stage.err")")
EXAMPLE_DIR=${OUT}/do-agent-aws/${EXAMPLE_REL}
[ -f "${OUT}/do-agent-aws/.env" ] && [ -f "${OUT}/do-agent-aws/.fun" ] && [ -d "${EXAMPLE_DIR}" ] \
	|| BLOCKERS+=("STAGE_INCOMPLETE: HEAD lacks .env, .fun or ${EXAMPLE_REL}")
# What the image must carry if it was built from HEAD.
( cd "${OUT}/do-agent-aws/Container-Root" && sha256sum test*.sh ) > "${OUT}/expected-tests.sha256" 2>> "${OUT}/stage.err"
EXPECTED_RECIPE=$(cat "${OUT}/do-agent-aws/Dockerfile" "${OUT}/do-agent-aws/to/sandbox/template/sandbox.dockerfile" 2>> "${OUT}/stage.err" | sha256sum | awk '{print $1}')
# The run tests HEAD exactly: no uncommitted change to a tracked file.
git -C "${BASE_DIR}" diff --quiet HEAD -- 2> /dev/null \
	|| BLOCKERS+=("DIRTY_TREE: tracked files differ from HEAD (git status); commit them - the run tests HEAD only")
# Nothing credential-shaped is uploaded (the patterns test1.sh uses).
grep -rlE -f "${SBX_DIR}/test/credential-shapes.txt" "${OUT}/do-agent-aws" > "${OUT}/credential-scan.txt" 2> "${OUT}/credential-scan.err"
case $? in
0) BLOCKERS+=("CREDENTIAL_SHAPED: files that would be uploaded hold credential-shaped strings: $(sed "s#^${OUT}/do-agent-aws/##" "${OUT}/credential-scan.txt" | tr '\n' ' ')") ;;
1) ;;
*) BLOCKERS+=("CREDENTIAL_SCAN_FAILED: the scan of the upload did not complete: $(head -c 200 "${OUT}/credential-scan.err" | tr '\n' ' ')") ;;
esac
# Sizes: the descriptor's resources@1 at HEAD.
read -r CPUS MEMORY < <(python3 - "${OUT}/do-agent-aws/to/sandbox/template/${KIT_NAME}.yaml" 2>> "${OUT}/stage.err" << 'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
r = [c for c in d["capabilities"] if c["type"] == "com.docker.sandbox/resources@1"][0]["config"]
print(r["cpu"], r["memory"])
EOF
)
MEM_DECL=$(python3 -c 'import re, sys; m = re.fullmatch(r"(\d+)\s*([kmgt]?)i?b?", sys.argv[1].strip().lower()); print(int(m.group(1)) * 1024 ** "_kmgt".index(m.group(2) or "_"))' "${MEMORY:-x}" 2> /dev/null)
[ -n "${CPUS}" ] && [ -n "${MEM_DECL}" ] || BLOCKERS+=("SIZES: could not read cpu and memory from the descriptor at HEAD")
if [ "${MODE}" = "cloud" ]; then
	TTL_S=$(python3 -c 'import re, sys; s = sys.argv[1].lower(); m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?", s); print(int(m.group(1) or 0) * 3600 + int(m.group(2) or 0) * 60 + int(m.group(3) or 0) if s and m else -1)' "${TTL}")
	if [ "${TTL_S}" -lt "${BUDGET}" ] || [ "${TTL_S}" -gt 86400 ]; then
		BLOCKERS+=("TTL: --ttl ${TTL} (${TTL_S} s) must cover the run's per-call timeouts up to teardown (${BUDGET} s) and stay within 24h; pass --ttl $(( (BUDGET + 3599) / 3600 ))h")
	fi
fi

if [ -z "${KIT}" ]; then
	"${SBX_DIR}/render.sh" > "${OUT}/render.txt" 2>&1 || BLOCKERS+=("RENDER_FAILED: $(tail -1 "${OUT}/render.txt")")
	KIT=${SBX_DIR}/app/${KIT_NAME}
fi
if [ -d "${KIT}" ]; then
	KIT="$(cd "${KIT}" && pwd)"
	python3 "${SBX_DIR}/test/check-descriptor.py" "${KIT}/${KIT_NAME}.yaml" > "${OUT}/descriptor-check.txt" 2>&1 \
		|| BLOCKERS+=("DESCRIPTOR_INVARIANTS: $(tr '\n' ' ' < "${OUT}/descriptor-check.txt")")
	[ "$(sha_of "${KIT}/${KIT_NAME}.dockerfile" 2>/dev/null)" = "${EXPECTED_RECIPE}" ] \
		|| BLOCKERS+=("KIT_STALE: ${KIT}/${KIT_NAME}.dockerfile is not HEAD's Dockerfile + template/sandbox.dockerfile; run to/sandbox/render.sh")
	if [ "${MODE}" = "cloud" ] && [ "${HAVE_KVM}" = "false" ] && [ "${ALLOW_SOURCE_KIT}" = "false" ]; then
		BLOCKERS+=("NEEDS_PUSHED_KIT: sbx builds a kit directory in a local builder sandbox (sbx kit builder --help), which needs KVM; push the kit image and pass --kit docker.io/<namespace>/${KIT_NAME}:<tag> (to/sandbox/README.md 'Cloud sandboxes'), or pass --allow-source-kit to try")
	fi
	# Local runs only, and only for a kit directory (a cloud run and a kit image
	# are not checked here). sbx create builds a kit directory that sbx has not
	# built yet before it creates the sandbox, and the first build of this kit
	# outlasts create's timeout: with sbx 0.47.0 on an m8i.2xlarge, under
	# deny-all, setup.sh alone took 19 minutes. So a local run needs that build
	# to exist already (to/sandbox/README.md, "Local sandboxes"), and finds out
	# without starting one. sbx answers no such question: sbx kit inspect builds
	# a kit it has not built, and sbx kit validate loads no kit directory at all
	# (both tried with sbx 0.47.0). The check relies on two sbx-internal details,
	# read off sbx 0.47.0 and used with exactly that version (the whole token
	# "v0.47.0" of sbx version): the reference sbx gives the build
	# (test/kit-key.py), and sbx's kit registry on 127.0.0.1, whose address sbx
	# kit builder status prints and which answers a manifest request for that
	# reference with 200 and the image's Docker-Content-Digest when it holds the
	# build, and with 404 when not. sbx 0.47.0 reused every build its registry
	# held, and built those it did not. A finished build showed up in the
	# registry's tag list a few seconds late; a delay of that kind can only make
	# the check report a build missing, never one that is not there. The
	# registry fills itself from the Docker engine on the first request for a
	# build it does not hold yet ("kit registry facade: populate from engine" in
	# sbx's daemon.log), and a request that gives up cancels that copy; after a
	# build whose harness layers changed (Container-Root, so setup.sh ran again)
	# the copy took 93 s on an m8i.2xlarge, where a 20 s request never let it
	# finish. So the request waits up to T_KIT_REGISTRY seconds
	# (E2E_T_KIT_REGISTRY, default 600). The request ignores proxy variables and
	# curl configuration (-q, --noproxy). Any other answer is inconclusive and
	# blocks the run.
	if [ "${MODE}" = "local" ]; then
		KIT_REF=""
		KIT_REGISTRY=""
		KIT_HTTP=""
		KIT_WHY=""
		# What to do when the check cannot tell, unless a cause below says better.
		KIT_ADVICE="A local create from a kit directory sbx has not built builds it first, which outlasts create's timeout; if the build may be missing, build it (to/sandbox/README.md 'Local sandboxes')"
		SBX_VER_TOKEN=$(echo "${SBX_VERSION_LINE}" | awk '$1 == "sbx" && $2 == "version:" {print $3}')
		if [ "${SBX_VER_TOKEN}" != "v0.47.0" ]; then
			KIT_WHY="this check knows how sbx v0.47.0 names and stores a kit build, and this sbx is '${SBX_VER_TOKEN:-none}'"
			KIT_ADVICE="Run with sbx 0.47.0, or first check test/kit-key.py and the registry request against this version"
		elif ! command -v curl > /dev/null; then
			KIT_WHY="NEEDS_TOOL curl, to ask sbx's kit registry"
			KIT_ADVICE="Install curl"
		elif ! KIT_REF=$(python3 "${SBX_DIR}/test/kit-key.py" "${KIT}" "${KIT_NAME}" 2> "${OUT}/kit-key.err"); then
			KIT_WHY="$(tr '\n' ' ' < "${OUT}/kit-key.err")"
			KIT_ADVICE="Pass a kit directory named ${KIT_NAME} that holds only regular files and non-empty directories, as to/sandbox/render.sh writes it"
		elif ! SBX_T=60 sbx_run kit builder status > "${OUT}/kit-builder-status.txt" 2>&1; then
			KIT_WHY="sbx kit builder status failed: $(tail -1 "${OUT}/kit-builder-status.txt")"
		else
			# sbx 0.47.0 prints "Kit registry: 127.0.0.1:5411 — reachable". Only a
			# registry it reports reachable, on 127.0.0.1, is asked.
			KIT_REG_LINE=$(awk '$1 == "Kit" && $2 == "registry:" {print; exit}' "${OUT}/kit-builder-status.txt")
			read -r _ _ KIT_REGISTRY KIT_REG_DASH KIT_REG_STATE KIT_REG_MORE <<< "${KIT_REG_LINE}"
			if [ -z "${KIT_REG_LINE}" ]; then
				KIT_WHY="sbx kit builder status names no kit registry (kit-builder-status.txt)"
			elif [ "${KIT_REG_DASH}" != "—" ] || [ "${KIT_REG_STATE}" != "reachable" ] || [ -n "${KIT_REG_MORE}" ]; then
				KIT_WHY="sbx kit builder status does not report the kit registry reachable: '${KIT_REG_LINE}'"
			elif ! [[ "${KIT_REGISTRY}" =~ ^127\.0\.0\.1:[0-9]{1,5}$ ]]; then
				KIT_WHY="sbx kit builder status names the kit registry '${KIT_REGISTRY}', not 127.0.0.1:<port>; the check asks only a registry on loopback"
			else
				# -q first: no ~/.curlrc; --noproxy '*': no proxy variable redirects it.
				KIT_HTTP=$(run_bg $(( T_KIT_REGISTRY + 10 )) curl -q --noproxy '*' -sS -o /dev/null -D "${OUT}/kit-registry-headers.txt" -w '%{http_code}' -I --max-time "${T_KIT_REGISTRY}" \
					-H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
					"http://${KIT_REGISTRY}/v2/${KIT_REF%%:*}/manifests/${KIT_REF#*:}" 2> "${OUT}/kit-registry.err")
				case "${KIT_HTTP}" in
				200)
					if grep -qiE '^docker-content-digest:[[:space:]]*sha256:[0-9a-f]{64}' "${OUT}/kit-registry-headers.txt" 2> /dev/null; then
						KIT_BUILT=${KIT_REF}
						note "kit build: sbx's kit registry holds ${KIT_REF}, so create reuses it"
					else
						KIT_WHY="the kit registry at ${KIT_REGISTRY} answered 200 for ${KIT_REF} without a Docker-Content-Digest: sha256: header (kit-registry-headers.txt)"
					fi
					;;
				404)
					BLOCKERS+=("KIT_NOT_BUILT: sbx has not built ${KIT} (its kit registry at ${KIT_REGISTRY} holds no ${KIT_REF}), so sbx create would build it first, and the first build of this kit outlasts create's ${T_CREATE} s timeout (sbx 0.47.0, m8i.2xlarge, under deny-all: setup.sh alone took 19 minutes). Build it once, then rerun (to/sandbox/README.md 'Local sandboxes'). The first command stops every running sandbox, and the host stays under the balanced preset until the last one: sbx policy reset --force; sbx policy init balanced; ${SBX_DIR}/render.sh; sbx create --name do-agent-aws-prebuild --cpus ${CPUS} --memory ${MEMORY} --skills off ${KIT}; sbx rm --force do-agent-aws-prebuild; sbx policy reset --force; sbx policy init deny-all")
					;;
				*)
					KIT_WHY="the kit registry at ${KIT_REGISTRY} answered '${KIT_HTTP}' for ${KIT_REF} (kit-registry.err)"
					if grep -q 'timed out' "${OUT}/kit-registry.err" 2> /dev/null; then
						KIT_WHY="the kit registry at ${KIT_REGISTRY} did not answer for ${KIT_REF} within ${T_KIT_REGISTRY} s (kit-registry.err)"
						KIT_ADVICE="sbx 0.47.0 copies a new build from the Docker engine into its kit registry on the first request for it, and a request that gives up cancels the copy; give it longer with E2E_T_KIT_REGISTRY=<seconds>"
					fi
					;;
				esac
			fi
		fi
		[ -z "${KIT_WHY}" ] || BLOCKERS+=("KIT_BUILD_UNKNOWN: could not tell whether sbx has built ${KIT}: ${KIT_WHY}. ${KIT_ADVICE}")
		printf 'reference %s\nregistry %s\nmanifest HTTP %s\nbuilt %s\ninconclusive %s\n' "${KIT_REF:-none}" "${KIT_REGISTRY:-none}" "${KIT_HTTP:-none}" "${KIT_BUILT:-no}" "${KIT_WHY:-no}" > "${OUT}/kit-build.txt"
	fi
elif [ -e "${KIT}" ]; then
	BLOCKERS+=("KIT_INVALID: ${KIT} is not a directory or an image reference")
else
	# An image reference. Its digest is read first; from here on only repo@digest
	# is used, so every check below and the create see the same artifact.
	KIT_REQUESTED=${KIT}
	if run_bg 300 docker buildx imagetools inspect "${KIT}" > "${OUT}/kit-imagetools.txt" 2>&1; then
		KIT_DIGEST=$(sed -n 's/^Digest:[[:space:]]*//p' "${OUT}/kit-imagetools.txt" | head -1)
	fi
	if [ -z "${KIT_DIGEST}" ]; then
		BLOCKERS+=("KIT_DIGEST: could not read the digest of ${KIT} (docker buildx imagetools inspect; docker login for a private repository)")
	else
		KIT="$(ref_repo "${KIT_REQUESTED}")@${KIT_DIGEST}"
		# A public kit image is refused: it must not resolve without credentials.
		ANON=$(mktemp -d)
		if run_bg 120 env DOCKER_CONFIG="${ANON}" docker manifest inspect "${KIT}" > /dev/null 2> "${OUT}/kit-anonymous.err"; then
			BLOCKERS+=("KIT_PUBLIC: ${KIT} resolves without credentials; keep the kit image in a private repository (to/sandbox/README.md 'Cloud sandboxes')")
		elif ! grep -qiE 'denied|unauthorized|authentication required|not found|manifest unknown' "${OUT}/kit-anonymous.err"; then
			BLOCKERS+=("KIT_VISIBILITY_UNKNOWN: could not tell whether ${KIT} is private: $(head -c 200 "${OUT}/kit-anonymous.err" | tr '\n' ' ')")
		fi
		rm -rf "${ANON}"
		KIT_TCK=${KIT_TCK:-$(command -v kit-tck)}
		if [ -z "${KIT_TCK}" ] || [ ! -x "${KIT_TCK}" ]; then
			BLOCKERS+=("NEEDS_TOOL kit-tck (KIT_TCK=/path/kit-tck) to read the kit image's published descriptor")
		elif ! run_bg 300 "${KIT_TCK}" inspect --descriptor "${KIT}" > "${OUT}/kit-published-descriptor.yaml" 2> "${OUT}/kit-inspect.err"; then
			BLOCKERS+=("KIT_UNREADABLE: kit-tck inspect --descriptor ${KIT} failed: $(tail -2 "${OUT}/kit-inspect.err" | tr '\n' ' ')")
		else
			{ echo "# syntax=docker/sandbox-kit:3"; cat "${OUT}/kit-published-descriptor.yaml"; } > "${OUT}/kit-published-descriptor.checked.yaml"
			python3 "${SBX_DIR}/test/check-descriptor.py" "${OUT}/kit-published-descriptor.checked.yaml" > "${OUT}/descriptor-check.txt" 2>&1 \
				|| BLOCKERS+=("DESCRIPTOR_INVARIANTS (published): $(tr '\n' ' ' < "${OUT}/descriptor-check.txt")")
			if ! run_bg 300 "${KIT_TCK}" inspect --dockerfile "${KIT}" > "${OUT}/kit-published-recipe.dockerfile" 2>> "${OUT}/kit-inspect.err"; then
				BLOCKERS+=("KIT_UNREADABLE: kit-tck inspect --dockerfile ${KIT} failed: $(tail -2 "${OUT}/kit-inspect.err" | tr '\n' ' ')")
			elif [ "$(sha_of "${OUT}/kit-published-recipe.dockerfile")" != "${EXPECTED_RECIPE}" ]; then
				BLOCKERS+=("KIT_STALE: the recipe staged in ${KIT} is not HEAD's Dockerfile + template/sandbox.dockerfile; render, build and push it again (to/sandbox/README.md 'Cloud sandboxes')")
			fi
		fi
	fi
fi

if [ "${SIGNED_IN}" = "true" ]; then
	if SBX_T=60 sbx_run ${CLOUD} ls -q > "${OUT}/ls-before.txt" 2>&1; then
		grep -qxF "${NAME}" "${OUT}/ls-before.txt" && BLOCKERS+=("NAME_IN_USE: a sandbox named ${NAME} already exists; pass --name")
	else
		BLOCKERS+=("LS_FAILED: ${SBXC} ls -q failed: $(tail -1 "${OUT}/ls-before.txt")")
	fi
fi

# A host whose network policy was never initialized (local, above). The commands work from any
# directory, and build a kit that sbx has not built yet under the balanced preset first.
if [ "${POLICY_UNINIT}" = "true" ]; then
	BLOCKERS+=("NEEDS_POLICY_INIT: this host has no network policy yet. If sbx has not built this kit yet, build it first under the balanced preset and only then switch to deny-all (the build needs hosts deny-all does not list; to/sandbox/README.md 'First local PASS', step 3): sbx policy init balanced; ${SBX_DIR}/render.sh; sbx create --name do-agent-aws-prebuild --cpus ${CPUS} --memory ${MEMORY} --skills off ${KIT}; sbx rm --force do-agent-aws-prebuild; sbx policy reset --force; sbx policy init deny-all. If it has: sbx policy init deny-all (the kit's allowlist is the whole egress only under a deny-by-default policy)")
fi

# The model credential: a bedrock secret scoped to this sandbox name. The proxy
# writes its value as "Authorization: Bearer <value>" into requests to
# bedrock-runtime.us-east-1.amazonaws.com, so the value must be a Bedrock API
# key: locally a command secret that runs to/sandbox/bedrock-token.sh on the
# host (installed outside every sandbox mount) and is refreshed every 55
# minutes; in the cloud, whose secret store takes no command source (sbx docs),
# a key stored as the value, which is not refreshed. The run removes it at
# teardown (to/sandbox/README.md "Model credential"). A global bedrock secret
# alone is not used: for sbx's built-in claude-bedrock agent that value is an
# AWS profile name, which this kit's proxy would send as the bearer value, and
# a global key would reach every sandbox. It is never touched.
BEDROCK_HELPER=${E2E_BEDROCK_HELPER:-${HOME}/.local/share/sbx-bedrock/bedrock-token.sh}
if [ "${MODE}" = "cloud" ]; then
	BEDROCK_SETUP="${BEDROCK_HELPER} bedrock us-east-1 | sbx --cloud secret set bedrock --sandbox ${NAME} (a key valid until it expires: the cloud store takes no --command source)"
else
	BEDROCK_SETUP="sbx secret set bedrock --sandbox ${NAME} --command '${BEDROCK_HELPER} bedrock us-east-1' --refresh 55m"
fi
CREDENTIAL="unknown (not signed in)"
if [ "${SIGNED_IN}" = "true" ]; then
	# A failing lookup of the sandbox's own secret is reported as such, not read
	# as "no sandbox secret" (which would fall through to the global lookup).
	if ! SBX_T=60 sbx_run ${CLOUD} secret ls --sandbox "${NAME}" --service bedrock -q > "${OUT}/secret-sandbox.txt" 2> "${OUT}/secret-sandbox.err"; then
		CREDENTIAL="unknown (secret ls --sandbox failed)"
	elif grep -q . "${OUT}/secret-sandbox.txt"; then
		CREDENTIAL=present
		SECRET_SCOPE=sandbox
	elif SBX_T=60 sbx_run ${CLOUD} secret ls -g --service bedrock -q > "${OUT}/secret-global.txt" 2> "${OUT}/secret-global.err"; then
		if grep -q . "${OUT}/secret-global.txt"; then
			CREDENTIAL="global only, not used"
			SECRET_SCOPE=global
		else
			CREDENTIAL=absent
		fi
	else
		CREDENTIAL="unknown (secret ls -g failed)"
	fi
fi
CRED_FILE=${HOME}/.config/sbx/credentials.yaml
BINDING=absent
if [ -f "${CRED_FILE}" ]; then
	if python3 - "${CRED_FILE}" << 'EOF' > /dev/null 2>&1
import sys, yaml
b = (yaml.safe_load(open(sys.argv[1])) or {}).get("bindings") or {}
sys.exit(0 if "bedrock-runtime.us-east-1.amazonaws.com" in (((b.get("bedrock") or {}).get("apiKey") or {}).get("domains") or []) else 1)
EOF
	then
		BINDING=present
	fi
fi
# The model is usable in the sandbox only with both the stored key and the binding.
[ "${CREDENTIAL}" = "present" ] && [ "${BINDING}" = "present" ] && MODEL_CRED=present
if [ "${SKIP_AGENT}" = "true" ]; then
	AGENT_REASON="--skip-agent"
elif [ "${SECRET_SCOPE}" = "global" ]; then
	AGENT_REASON="only a global bedrock secret is stored, and this kit does not use one: the proxy sends the stored value as 'Bearer <value>' to bedrock-runtime.us-east-1.amazonaws.com, so it must be a Bedrock API key, while a global bedrock secret holds what sbx's built-in claude-bedrock agent reads (an AWS profile name) and would reach every sandbox; store a key for this sandbox: ${BEDROCK_SETUP} (to/sandbox/README.md 'Model credential')"
elif [[ "${CREDENTIAL}" == "unknown (secret ls"* ]]; then
	AGENT_REASON="whether a bedrock secret is stored for sandbox ${NAME} is ${CREDENTIAL} (secret-sandbox.err, secret-global.err), so the agent layer does not run; if none is stored: ${BEDROCK_SETUP} (to/sandbox/README.md 'Model credential')"
elif [ "${CREDENTIAL}" != "present" ]; then
	AGENT_REASON="no bedrock secret for sandbox ${NAME} in the ${SBXC} secret store (${CREDENTIAL}); store one: ${BEDROCK_SETUP} (to/sandbox/README.md 'Model credential')"
elif [ "${BINDING}" != "present" ]; then
	AGENT_REASON="no approved binding for bedrock -> bedrock-runtime.us-east-1.amazonaws.com in ${CRED_FILE} (to/sandbox/README.md 'Model credential')"
else
	AGENT_PLAN=RUN
fi
note "credential: bedrock secret ${CREDENTIAL} (scope ${SECRET_SCOPE}), binding ${BINDING}; agent layer ${AGENT_PLAN}${AGENT_REASON:+ (${AGENT_REASON})}"

# The host model check, for local runs whose agent layer would run: the installed helper
# makes a key on this host (only its prefix is checked), and one smallest Converse request
# to each model the image pins (template/sandbox.dockerfile at HEAD) must answer 200. It
# checks the AWS profile, the role's permissions (bedrock:CallWithBearerToken and the two
# models) and the helper from this host. It does not check the path through the sandbox's
# proxy, which only the harness's test3 and the agent layer exercise, so a dry run still
# says that Bedrock access from inside the sandbox is not verified. The key stays in a
# directory only this user can read, removed at once, and by on_exit after an interrupt:
# it is never a command argument (commands.log shows the header file's path), never
# printed and never in the results. Nor is it ever a word of a command, so a trace
# (bash -x, or SHELLOPTS=xtrace in the environment) shows the file's path and never the key.
# E2E_BEDROCK_URL may point the check at a stub on 127.0.0.1 (test5), and nowhere else.
BEDROCK_URL=${E2E_BEDROCK_URL:-https://bedrock-runtime.us-east-1.amazonaws.com}
model_check()
{
	local dir rc code msg m id
	MODEL_CHECK=fail
	if [ "${BEDROCK_URL}" != "https://bedrock-runtime.us-east-1.amazonaws.com" ] && ! [[ "${BEDROCK_URL}" =~ ^http://127\.0\.0\.1:[0-9]{1,5}$ ]]; then
		MODEL_CHECK_DETAIL="E2E_BEDROCK_URL '${BEDROCK_URL}' is neither the Bedrock runtime endpoint nor a stub on 127.0.0.1, so the key is not sent there"
		return
	fi
	if [ ! -x "${BEDROCK_HELPER}" ]; then
		MODEL_CHECK_DETAIL="the helper ${BEDROCK_HELPER} is missing or not executable (to/sandbox/README.md 'Model credential', step 3)"
		return
	fi
	dir=$(mktemp -d) || { MODEL_CHECK_DETAIL="mktemp -d failed"; return; }
	MODEL_CHECK_DIR=${dir}
	run_bg 120 "${BEDROCK_HELPER}" bedrock us-east-1 > "${dir}/key" 2> "${OUT}/model-check-helper.err"
	rc=$?
	if [ ${rc} -ne 0 ] || ! grep -q '^bedrock-api-key-' "${dir}/key"; then
		MODEL_CHECK_DETAIL="the helper (${BEDROCK_HELPER} bedrock us-east-1) exited ${rc} without a Bedrock API key (model-check-helper.err)"
		rm -rf "${dir}"
		MODEL_CHECK_DIR=""
		return
	fi
	# file to file: the key is never expanded into a command word
	{ printf 'Authorization: Bearer '; head -1 "${dir}/key"; } > "${dir}/header"
	MODEL_CHECK=ok
	MODEL_CHECK_DETAIL=""
	: > "${OUT}/model-check.txt"
	for m in SONNET HAIKU; do
		id=$(python3 -c 'import re, sys; m = re.search(r"ANTHROPIC_DEFAULT_%s_MODEL=([^\s\\]+)" % sys.argv[2], open(sys.argv[1]).read()); print(m.group(1) if m else "")' \
			"${OUT}/do-agent-aws/to/sandbox/template/sandbox.dockerfile" "${m}" 2>> "${OUT}/model-check-helper.err")
		if [ -z "${id}" ]; then
			MODEL_CHECK=fail
			MODEL_CHECK_DETAIL="${MODEL_CHECK_DETAIL}no ${m} model pin in template/sandbox.dockerfile; "
			continue
		fi
		code=$(run_bg 90 curl -q -sS -o "${dir}/body" -w '%{http_code}' --max-time 60 -X POST -H 'Content-Type: application/json' -H "@${dir}/header" \
			--data '{"messages":[{"role":"user","content":[{"text":"Reply with the word OK."}]}],"inferenceConfig":{"maxTokens":5}}' \
			"${BEDROCK_URL}/model/${id//:/%3A}/converse" 2>> "${OUT}/model-check-helper.err")
		# AWS's own message, with account numbers and ARNs masked
		msg=$(python3 -c 'import json, re, sys
try:
    m = str(json.load(open(sys.argv[1])).get("message") or "")
except Exception:
    m = ""
print(re.sub(r"\b\d{12}\b", "<account>", re.sub(r"arn:aws[^\s]*", "<arn>", m))[:240])' "${dir}/body" 2> /dev/null)
		echo "${id}: HTTP ${code:-000}${msg:+ - ${msg}}" >> "${OUT}/model-check.txt"
		if [ "${code}" != "200" ]; then
			MODEL_CHECK=fail
			MODEL_CHECK_DETAIL="${MODEL_CHECK_DETAIL}${id} answered HTTP ${code:-000}${msg:+ (${msg})}; "
		fi
	done
	rm -rf "${dir}"
	MODEL_CHECK_DIR=""
	MODEL_CHECK_DETAIL=${MODEL_CHECK_DETAIL%; }
}
[ "${MODE}" = "local" ] && [ "${AGENT_PLAN}" = "RUN" ] && model_check
if [ "${MODEL_CHECK}" = "ok" ]; then
	note "host model check: the helper made a Bedrock API key and both pinned models answered 200 from this host (model-check.txt)"
elif [ "${MODEL_CHECK}" = "fail" ]; then
	note "host model check FAILED: ${MODEL_CHECK_DETAIL}"
fi
# --require-agent: the run must exercise the model, so whatever keeps the agent layer from
# running, or a failed host model check (local), blocks the run here.
if [ "${REQUIRE_AGENT}" = "true" ]; then
	[ "${AGENT_PLAN}" = "RUN" ] || BLOCKERS+=("AGENT_NOT_RUNNABLE: --require-agent, and the agent layer cannot run: ${AGENT_REASON}")
	if [ "${MODE}" = "local" ] && [ "${AGENT_PLAN}" = "RUN" ] && [ "${MODEL_CHECK}" != "ok" ]; then
		BLOCKERS+=("MODEL_NOT_VERIFIED: --require-agent, and the host model check failed: ${MODEL_CHECK_DETAIL}")
	fi
elif [ "${MODEL_CHECK}" = "fail" ]; then
	note "WARNING: with the host model check failing, the harness's test3 and the agent layer will fail too; --require-agent stops the run here instead"
fi

# The harness settings ./test.sh passes from .env: NAME=value pairs only; bare -e NAME
# (host credentials), the proxy variables and the mounts are left out (header).
mapfile -t ENV_ARGS < <(cd "${BASE_DIR}" && bash -c 'source .env > /dev/null 2>&1; echo "${AUTONOMY_ENV_OPTS} ${AGENT_TMUX_ENV_OPTS} ${SLACK_ENV_OPTS} ${UI_ENV_OPTS} ${COMMS_ENV_OPTS}"' \
	| tr ' ' '\n' | awk 'prev == "-e" && index($0, "=") > 1 {print "-e"; print $0} {prev = $0}')
[ ${#ENV_ARGS[@]} -gt 0 ] || BLOCKERS+=("ENV_ARGS: could not read the harness settings from .env")

if [ ${#BLOCKERS[@]} -gt 0 ]; then
	layer preflight BLOCKED "$(printf '%s; ' "${BLOCKERS[@]}")"
else
	layer preflight PASS "sbx ${SBX_VER}; signed in; HEAD ${REV:0:12} (uncommitted paths, not used: ${DIRTY_PATHS}); kit ${KIT}${KIT_BUILT:+ (built: ${KIT_BUILT})}; secret scope ${SECRET_SCOPE}; agent layer ${AGENT_PLAN}"
fi

# The create call, shared by the plan and the real run: no workspace path (no
# host mount), no published port, and locally no link to the host's skills store.
CREATE=(${CLOUD} create --name "${NAME}" --cpus "${CPUS}" --memory "${MEMORY}")
# e2e suppresses the kit's boot-time platform autostart: the harness layer runs the
# image's /test*.sh in a platform-free VM (./test.sh gives the suite its own throwaway
# /wd and memory home for the same reason), and the stack layer starts the platform
# itself and checks it. A plain `sbx create` leaves the hook on, so a user's sandbox
# brings up the platform by itself.
CREATE+=(-e SBX_PLATFORM_AUTOSTART=false)
[ "${MODE}" = "cloud" ] && CREATE+=(--ttl "${TTL}" --on-timeout delete --platform linux/amd64)
[ "${MODE}" = "local" ] && CREATE+=(--skills off)
CREATE+=("${KIT}")

if [ "${DRY_RUN}" = "true" ]; then
	{
		echo "# Plan - the commands a real run issues, in order (dry run: none was issued)"
		echo "sbx ${CREATE[*]}"
		echo "${SBXC} exec ${NAME} bash -c 'cd / && sha256sum test*.sh && sha256sum ${IN_SANDBOX_RECIPE}'   # provenance"
		[ "${MODE}" = "cloud" ] && echo "sbx --cloud policy init deny-all --sandbox ${NAME}"
		echo "${SBXC} exec ${NAME} bash -c 'curl ... https://public.ecr.aws/v2/'   # allowlisted: expect 401"
		echo "${SBXC} exec ${NAME} bash -c 'curl ... https://example.com/ ; curl ... https://registry.npmjs.org/ ; curl ... https://api.anthropic.com/v1/models ; curl ... https://registry-1.docker.io/v2/'   # off the list: expect refusal"
		echo "${SBXC} exec ${NAME} bash -c 'curl -D ... https://bedrock-runtime.us-east-1.amazonaws.com/ ; node fetch(same)'   # model endpoint through the proxy: an answer from AWS (x-amzn-RequestId), its code recorded"
		echo "${SBXC} policy log ${NAME}   # the four refused hosts listed as blocked"
		echo "# unless the provenance and policy layers pass: platform, harness, example and agent NOT_RUN, teardown, exit 1"
		echo "${SBXC} exec ${NAME} bash -c '<uid, nproc, MemTotal, docker version, compose version, claude --version, AWS_BEARER_TOKEN_BEDROCK: length, sentinel or key-shaped (never the value)>'"
		echo "# unless AWS_BEARER_TOKEN_BEDROCK in the sandbox passes that check: harness, example and agent NOT_RUN, teardown, exit 1"
		echo "${SBXC} cp ${OUT}/do-agent-aws ${NAME}:/do-agent-aws   # HEAD (git archive), where ./test.sh mounts the repository"
		echo "${SBXC} exec -w /agent ${ENV_ARGS[*]} ${NAME} bash -c 'for t in \$(ls /test*.sh); do ...; done'"
		echo "${SBXC} cp ${EXAMPLE_DIR} ${NAME}:/root/workspace/"
		echo "${SBXC} exec -e SBX_CONTEXT=docker-sandbox-${MODE} ${NAME} bash ${IN_SANDBOX_EXAMPLE}/run-deterministic.sh ${IN_SANDBOX_OUT}/compose-demo-deterministic.json compose-demo-det"
		echo "${SBXC} cp ${NAME}:${IN_SANDBOX_OUT}/compose-demo-deterministic.json ${OUT}/deterministic/   # out before the agent runs"
		if [ "${AGENT_PLAN}" = "RUN" ]; then
			echo "${SBXC} exec -w ${IN_SANDBOX_EXAMPLE} ${NAME} bash -c 'exec timeout 900 claude -p \"\$1\" --permission-mode bypassPermissions --output-format json' _ '<agent-task.md with nonce>'"
			echo "${SBXC} cp ${OUT}/verifier-<token> ${NAME}:/opt/e2e-verify-<token>   # fresh verifier, after the session"
			echo "${SBXC} exec ${NAME} python3 /opt/e2e-verify-<token>/verify-agent-report.py ..."
			echo "${SBXC} cp ${NAME}:/opt/e2e-verify-<token> ${OUT}/agent-verify ; ${SBXC} cp ${NAME}:${IN_SANDBOX_EXAMPLE} ${OUT}/example-after-agent"
		else
			echo "# agent layer NOT_RUN: ${AGENT_REASON}"
		fi
		echo "${SBXC} exec ${NAME} bash -c '. /etc/do-agent-aws-sandbox.env; /startup.sh & ... poll /agent/ui-status.sh'   # stack: platform up, supervisor/hub/spokes/UIs"
		echo "${SBXC} cp ${NAME}:${IN_SANDBOX_OUT} ${OUT}/sandbox-out   # every copy-out is refused if it holds a symlink"
		[ "${MODE}" = "cloud" ] && echo "sbx --cloud ttl --json ${NAME}"
		[ "${SECRET_SCOPE}" = "sandbox" ] && echo "${SBXC} secret rm bedrock --sandbox ${NAME} -f ; ${SBXC} secret ls --sandbox ${NAME} --service bedrock -q   # must list nothing"
		echo "${SBXC} rm --force ${NAME}"
		echo "${SBXC} ls -q   # ${NAME} must be absent"
		echo "# host model check: ${MODEL_CHECK}${MODEL_CHECK_DETAIL:+ (${MODEL_CHECK_DETAIL})}"
		echo "# DRY_RUN creates no sandbox, so no request goes through a sandbox's proxy: Bedrock access from inside the sandbox is NOT verified (a real run's harness test3 and agent layer verify it)"
	} | tee "${OUT}/plan.txt"
	if [ ${#BLOCKERS[@]} -gt 0 ]; then
		printf 'BLOCKED: %s\n' "${BLOCKERS[@]}"
		note "DRY_RUN: preflight is BLOCKED (above). Bedrock access from inside the sandbox was NOT verified (no sandbox was created); host model check: ${MODEL_CHECK}"
		finish 2
	fi
	note "DRY_RUN: the checks that create nothing passed. Bedrock access from inside the sandbox was NOT verified (no sandbox was created); host model check: ${MODEL_CHECK}"
	finish 0 DRY_RUN
fi
[ ${#BLOCKERS[@]} -eq 0 ] || { printf 'BLOCKED: %s\n' "${BLOCKERS[@]}"; finish 2; }

# --- create -----------------------------------------------------------------
# From here on teardown runs whenever create was attempted, whatever create or
# ls report, so nothing can be left running by a half-failed create.
ATTEMPTED=true
SBX_T=${T_CREATE} sbx_run "${CREATE[@]}" > "${OUT}/create.log" 2>&1
RC=$?
# Recorded only (teardown goes by name): cloud create prints the sandbox ID, sbx_<id>.
SANDBOX_ID=$(grep -oE 'sbx_[A-Za-z0-9]+' "${OUT}/create.log" | grep -vxE 'sbx_cloud|sbx_known' | head -1)
LISTED=false
SBX_T=60 sbx_run ${CLOUD} ls -q > "${OUT}/ls-after-create.txt" 2>> "${OUT}/create.log" \
	&& grep -qxF "${NAME}" "${OUT}/ls-after-create.txt" && LISTED=true
[ "${LISTED}" = "true" ] && SEEN=true
if [ ${RC} -ne 0 ] || [ "${LISTED}" != "true" ]; then
	layer create FAIL "create exit ${RC}, listed=${LISTED} (create.log)"
	for l in provenance policy platform harness example agent stack; do layer "${l}" NOT_RUN "create failed"; done
	teardown
	finish 1
fi
layer create PASS "sandbox ${NAME}${SANDBOX_ID:+ (${SANDBOX_ID})}, ${CPUS} CPU, ${MEMORY}${CLOUD:+, ttl ${TTL}, on-timeout delete}"

# --- provenance -------------------------------------------------------------
sbx_exec "${NAME}" bash -c 'cd / && sha256sum test*.sh && sha256sum "$1"' _ "${IN_SANDBOX_RECIPE}" > "${OUT}/provenance.txt" 2>&1
RC=$?
# every /test*.sh the glob gives (numbered and named, e.g. test-agent-chat.sh): the set expected-tests.sha256 holds
grep -E ' test[^/ ]*\.sh$' "${OUT}/provenance.txt" | LC_ALL=C sort -k2 > "${OUT}/image-tests.sha256"
GOT_RECIPE=$(awk -v f="${IN_SANDBOX_RECIPE}" '$2 == f {print $1}' "${OUT}/provenance.txt")
if [ ${RC} -eq 0 ] && diff <(LC_ALL=C sort -k2 "${OUT}/expected-tests.sha256") "${OUT}/image-tests.sha256" > "${OUT}/provenance.diff" \
	&& [ "${GOT_RECIPE}" = "${EXPECTED_RECIPE}" ]; then
	layer provenance PASS "the sandbox's $(wc -l < "${OUT}/image-tests.sha256") /test*.sh scripts and its staged kit recipe (sha256 ${EXPECTED_RECIPE:0:12}) hash to HEAD's (only these are compared)"
else
	layer provenance FAIL "the sandbox's /test*.sh scripts or staged kit recipe do not hash to HEAD's (exec exit ${RC}; recipe ${GOT_RECIPE:-missing} vs ${EXPECTED_RECIPE}; script diff in provenance.diff)"
fi

# --- policy -----------------------------------------------------------------
POLICY_OK=true
POLICY_DETAIL=""
if [ "${MODE}" = "cloud" ]; then
	if sbx_run --cloud policy init deny-all --sandbox "${NAME}" > "${OUT}/policy-init.log" 2>&1 \
		&& ! grep -qi '^error' "${OUT}/policy-init.log"; then
		POLICY_DETAIL="sandbox policy init deny-all ok;"
	else
		POLICY_OK=false
		POLICY_DETAIL="policy init deny-all --sandbox failed (policy-init.log);"
	fi
	sbx_run --cloud policy ls "${NAME}" > "${OUT}/policy-ls.txt" 2>&1
fi
probe()
{
	# $1 = URL, then extra curl options; prints the HTTP status (000: no HTTP answer)
	sbx_exec "${NAME}" bash -c 'u=$1; shift; curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "$@" "$u"' _ "$@" 2>> "${OUT}/policy-probe.log"
}
# Listed as blocked by sbx policy log: under its "Blocked requests:" heading (the
# text format the sbx docs show), or on a line that says blocked or denied.
blocked_in_log()
{
	# $1 = policy log, $2 = host
	awk -v h="$2" '
		/^Blocked requests:/ {b = 1; next}
		/^Allowed requests:/ {b = 0; next}
		{
			hit = 0
			for (i = 1; i <= NF; i++) if ($i == h || $i == h ":443") hit = 1
			if (hit && (b || tolower($0) ~ /block|den(y|ied)/)) found = 1
		}
		END {exit found ? 0 : 1}' "$1"
}
# The model endpoint: AWS answers a bare GET of the Bedrock runtime with 404
# (UnknownOperationException) and an x-amzn-RequestId header, with or without a
# key (seen from an AWS host on 2026-10-08); the proxy's own refusal carries no
# such header. An answer with it is AWS's: the endpoint is reachable through the
# proxy. Its code is recorded, not judged; the key itself is exercised by the
# harness's test3 and the agent layer.
probe_aws()
{
	# $1 = URL; prints "<HTTP status> aws" for an answer that carries
	# x-amzn-RequestId, "<HTTP status> no-aws-header" otherwise (000: no answer)
	sbx_exec "${NAME}" bash -c 'h=$(mktemp); c=$(curl -sS -o /dev/null -D "$h" -w "%{http_code}" --max-time 20 "$1"); a=no-aws-header; grep -qi "^x-amzn-requestid:" "$h" && a=aws; rm -f "$h"; echo "$c $a"' _ "$1" 2>> "${OUT}/policy-probe.log"
}
ALLOWED=$(probe https://public.ecr.aws/v2/)
DENY1=$(probe https://example.com/)
DENY2=$(probe https://registry.npmjs.org/)
# The Anthropic API is off the list; without a key it would answer 401 itself,
# so only sbx policy log tells its refusal apart (checked below).
DENY3=$(probe https://api.anthropic.com/v1/models)
# Docker Hub is off the list too (base images come from ECR Public); it answers 401 itself, so here as well only
# sbx policy log tells its refusal apart.
DENY4=$(probe https://registry-1.docker.io/v2/)
MODEL=$(probe_aws https://bedrock-runtime.us-east-1.amazonaws.com/)
# Node ignores the system CA store and, without NODE_USE_ENV_PROXY=1, the proxy
# variables (Node 24); the image points NODE_EXTRA_CA_CERTS at the bundle the
# runtime adds its proxy CA to.
NODE_TLS=$(sbx_exec "${NAME}" bash -c 'NODE_USE_ENV_PROXY=1 node -e "fetch(\"https://bedrock-runtime.us-east-1.amazonaws.com/\").then(r => console.log(r.status + (r.headers.get(\"x-amzn-requestid\") ? \" aws\" : \" no-aws-header\"))).catch(e => { console.log(\"ERR \" + (e.cause ? e.cause.code || e.cause.message : e.message)); process.exit(1) })"' 2>> "${OUT}/policy-probe.log")
LOGGED=false
for _ in 1 2 3 4 5 6; do
	sbx_run ${CLOUD} policy log "${NAME}" > "${OUT}/policy-log.txt" 2>&1
	if blocked_in_log "${OUT}/policy-log.txt" example.com && blocked_in_log "${OUT}/policy-log.txt" registry.npmjs.org \
		&& blocked_in_log "${OUT}/policy-log.txt" api.anthropic.com && blocked_in_log "${OUT}/policy-log.txt" registry-1.docker.io; then
		LOGGED=true
		break
	fi
	sleep 5
done
[ "${ALLOWED}" = "401" ] || { POLICY_OK=false; POLICY_DETAIL="${POLICY_DETAIL} allowlisted public.ecr.aws answered '${ALLOWED}', expected 401;"; }
for pair in "example.com=${DENY1}" "registry.npmjs.org=${DENY2}" "api.anthropic.com=${DENY3}" "registry-1.docker.io=${DENY4}"; do
	case "${pair#*=}" in
	000|4??|5??) ;;
	*) POLICY_OK=false; POLICY_DETAIL="${POLICY_DETAIL} ${pair%%=*} answered '${pair#*=}': egress is not limited to the allowlist;" ;;
	esac
done
[ "${LOGGED}" = "true" ] || { POLICY_OK=false; POLICY_DETAIL="${POLICY_DETAIL} sbx policy log does not list example.com, registry.npmjs.org, api.anthropic.com and registry-1.docker.io as blocked (policy-log.txt);"; }
case "${MODEL}" in
[1-5][0-9][0-9]\ aws) ;;
*) POLICY_OK=false; POLICY_DETAIL="${POLICY_DETAIL} the Bedrock runtime endpoint did not answer from AWS through the proxy ('${MODEL:-no output}': an answer without AWS's x-amzn-RequestId header is not AWS's, 000 is none);" ;;
esac
case "${NODE_TLS}" in
[1-5][0-9][0-9]\ aws) ;;
*CERT*|*SELF_SIGNED*|*UNABLE_TO*|*ERR_TLS*) POLICY_OK=false; POLICY_DETAIL="${POLICY_DETAIL} Node does not trust the proxy's TLS (${NODE_TLS});" ;;
*) POLICY_OK=false; POLICY_DETAIL="${POLICY_DETAIL} Node did not reach the Bedrock runtime endpoint through the proxy (${NODE_TLS:-no output});" ;;
esac
POLICY_DETAIL="${POLICY_DETAIL} public.ecr.aws=${ALLOWED} example.com=${DENY1:-none} registry.npmjs.org=${DENY2:-none} api.anthropic.com=${DENY3:-none} registry-1.docker.io=${DENY4:-none} logged-as-blocked=${LOGGED} bedrock-runtime.us-east-1.amazonaws.com=${MODEL:-none} node=${NODE_TLS:-none}"
if [ "${POLICY_OK}" = "true" ]; then layer policy PASS "${POLICY_DETAIL}"; else layer policy FAIL "${POLICY_DETAIL}"; fi
# Nothing live runs - no model call, no agent with bypassPermissions, no image
# pulls - unless the sandbox runs HEAD's kit and its egress policy was shown to hold.
GATE=""
[ "$(layer_status provenance)" = "PASS" ] || GATE="the provenance layer did not pass"
[ "$(layer_status policy)" = "PASS" ] || GATE="${GATE:+${GATE}; }egress unverified: the policy layer did not pass"
if [ -n "${GATE}" ]; then
	for l in platform harness example agent stack; do
		layer "${l}" NOT_RUN "${GATE}"
	done
	[ "${MODE}" = "cloud" ] && layer ttl NOT_RUN "${GATE}"
	teardown
	finish 1
fi

# --- platform ---------------------------------------------------------------
# The last three lines are about AWS_BEARER_TOKEN_BEDROCK: its length, whether it
# is the proxy's sentinel, and whether it starts like a Bedrock API key. The
# value itself is never printed: the probe turns xtrace off first, so a sandbox
# shell that starts with it on does not trace the value's assignment.
SBX_T=${T_PLATFORM} sbx_exec "${NAME}" bash -c 'set +x; echo "uid=$(id -u) user=$(id -un) home=${HOME} pwd=$(pwd)"; echo "nproc=$(nproc)"; echo "cpu_max=$(cat /sys/fs/cgroup/cpu.max 2>/dev/null)"; echo "memtotal_kb=$(awk "/^MemTotal:/ {print \$2}" /proc/meminfo)"; echo "memory_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"; i=0; until docker info > /dev/null 2>&1; do i=$((i + 1)); [ $i -lt 90 ] || break; sleep 1; done; echo "docker_server=$(docker version --format "{{.Server.Version}}" 2>/dev/null)"; echo "compose=$(docker compose version --short 2>/dev/null)"; echo "claude=$(claude --version 2>/dev/null)"; echo "proxy_vars=$(env | grep -iE "^(https?|no)_proxy=" | cut -d= -f1 | sort | tr "\n" " ")"; echo "no_proxy_list=${NO_PROXY:-${no_proxy:-}}"; v=${AWS_BEARER_TOKEN_BEDROCK-}; s=no; k=no; [ "$v" = proxy-managed ] && s=yes; case "$v" in bedrock-api-key-*|ABSK*) k=yes ;; esac; echo "bearer_len=${#v}"; echo "bearer_sentinel=$s"; echo "bearer_key_prefix=$k"' > "${OUT}/platform.txt" 2>&1
RC=$?
val()
{
	sed -n "s/^$1=//p" "${OUT}/platform.txt" | head -1
}
UID_IN=$(val uid | awk '{print $1}')
DOCKER_IN=$(val docker_server)
NPROC=$(val nproc)
CPU_MAX=$(val cpu_max)
MEM_KB=$(val memtotal_kb)
MEM_MAX=$(val memory_max)
CPU_OK=false
[ "${NPROC}" = "${CPUS}" ] && CPU_OK=true
case "${CPU_MAX}" in
[0-9]*\ [0-9]*) [ $(( ${CPU_MAX% *} / ${CPU_MAX#* } )) -eq "${CPUS}" ] && CPU_OK=true ;;
esac
# A VM reports a little less than its size as MemTotal: 3/4 to 17/16 of the
# declared memory.
MEM_OK=false
in_mem_range()
{
	[ -n "$1" ] && [ "$1" -ge $((MEM_DECL * 3 / 4)) ] && [ "$1" -le $((MEM_DECL * 17 / 16)) ]
}
case "${MEM_KB}" in [0-9]*) in_mem_range $((MEM_KB * 1024)) && MEM_OK=true ;; esac
case "${MEM_MAX}" in [0-9]*) in_mem_range "${MEM_MAX}" && MEM_OK=true ;; esac
# The model key stays on the host: the sandbox never holds a Bedrock API key in
# AWS_BEARER_TOKEN_BEDROCK, and with the model credential configured it holds
# the proxy's sentinel (to/sandbox/README.md "Model credential"). A probe that
# reports neither fact fails too.
BEARER_PREFIX=$(val bearer_key_prefix)
BEARER_WHY=""
if [ "${BEARER_PREFIX}" = "yes" ]; then
	BEARER_WHY="AWS_BEARER_TOKEN_BEDROCK in the sandbox starts like a Bedrock API key (bedrock-api-key-, a short-term key, or ABSK, a long-term one; length $(val bearer_len)): a Bedrock API key reached the sandbox, where only the proxy's sentinel belongs"
elif [ "${BEARER_PREFIX}" != "no" ]; then
	BEARER_WHY="the probe did not report AWS_BEARER_TOKEN_BEDROCK (platform.txt)"
elif [ "${MODEL_CRED}" = "present" ] && [ "$(val bearer_sentinel)" != "yes" ]; then
	BEARER_WHY="the model credential is configured, but AWS_BEARER_TOKEN_BEDROCK in the sandbox is not the proxy's sentinel proxy-managed (length $(val bearer_len))"
fi
if [ ${RC} -eq 0 ] && [ "${UID_IN}" = "0" ] && [ -n "${DOCKER_IN}" ] && [ "${CPU_OK}" = "true" ] && [ "${MEM_OK}" = "true" ] && [ -z "${BEARER_WHY}" ]; then
	layer platform PASS "$(tr '\n' ' ' < "${OUT}/platform.txt")"
else
	layer platform FAIL "exit ${RC}; uid=${UID_IN:-?} docker_server=${DOCKER_IN:-none} cpus ok=${CPU_OK} (nproc ${NPROC:-?}, cpu.max ${CPU_MAX:-?}) memory ok=${MEM_OK} (MemTotal ${MEM_KB:-?} kB, memory.max ${MEM_MAX:-?})${BEARER_WHY:+; ${BEARER_WHY}} (platform.txt)"
fi
# Nothing live runs once a Bedrock API key may be in the sandbox, or the check could not
# tell: the harness's model calls, the example's pulls and the agent would all run beside
# it. The same NOT_RUN, teardown and exit as the provenance and policy gate above.
if [ -n "${BEARER_WHY}" ]; then
	GATE="credential isolation unverified: ${BEARER_WHY}"
	for l in harness example agent stack; do
		layer "${l}" NOT_RUN "${GATE}"
	done
	[ "${MODE}" = "cloud" ] && layer ttl NOT_RUN "${GATE}"
	# Such a sandbox is not kept: it and its sandbox-scoped secret go, whatever --keep says.
	if [ "${KEEP}" = "true" ]; then
		note "--keep is overridden: a Bedrock API key may be in sandbox ${NAME}, so it and its sandbox-scoped secret are removed"
		KEEP=false
	fi
	teardown
	finish 1
fi

# --- harness ----------------------------------------------------------------
# ${OUT}/do-agent-aws is HEAD, staged in preflight.
REPO_OK=false
if [ -f "${OUT}/do-agent-aws/.env" ] && [ -f "${OUT}/do-agent-aws/.fun" ] \
	&& SBX_T=${T_COPY} sbx_run ${CLOUD} cp "${OUT}/do-agent-aws" "${NAME}:/do-agent-aws" > "${OUT}/repo-cp.log" 2>&1; then
	REPO_OK=true
fi
# The suite writes its log outside /root, /home/agent, /wd, /agent and /tmp, which tests watch for stray writes (test23
# scanned /root, so a log under /root/workspace/out failed it), and stops itself before the exec times out. The log is
# read with its own exec, so the tests that finished are scored even when the suite ran out of time.
HARNESS_LOG=/var/log/do-agent-aws-e2e/harness-tests.log
SBX_T=${T_HARNESS} sbx_exec -w /agent "${ENV_ARGS[@]}" "${NAME}" bash -c 'export NO_PROXY="${NO_PROXY:+${NO_PROXY},}localhost,127.0.0.1"; export no_proxy="${no_proxy:+${no_proxy},}localhost,127.0.0.1"; mkdir -p "${1%/*}"; { echo "NO_PROXY|no_proxy seen by a child bash: $(bash -c "echo \"\${NO_PROXY:-}|\${no_proxy:-}\"")"; timeout -k 30 "$2" bash -c '"'"'for t in $(ls /test*.sh); do echo "Running test $t"; $t; echo "EXIT $t $?"; done'"'"'; r=$?; case ${r} in 124 | 137) echo "SUITE STOPPED: the suite outlasted $2 s (exit ${r})" ;; esac; } > "$1" 2>&1' _ "${HARNESS_LOG}" "$(( T_HARNESS - 120 ))" > "${OUT}/harness-exec.log" 2>&1
RC=$?
SBX_T=${T_COPY} sbx_exec "${NAME}" bash -c 'mkdir -p "$2" && cp "$1" "$2/harness-tests.log" && cat "$1"' _ "${HARNESS_LOG}" "${IN_SANDBOX_OUT}" > "${OUT}/harness-tests.stdout" 2>&1 || { [ ${RC} -ne 0 ] || RC=1; }
"${SBX_DIR}/test/harness-verdict.sh" "${OUT}/harness-tests.stdout" "${MODEL_CRED}" > "${OUT}/harness-verdict.txt" 2>&1
VERDICT_RC=$?
if [ "${REPO_OK}" = "true" ] && [ ${RC} -eq 0 ] && [ ${VERDICT_RC} -eq 0 ]; then
	layer harness PASS "$(tr '\n' ';' < "${OUT}/harness-verdict.txt")"
else
	layer harness FAIL "repository copied=${REPO_OK}; exec exit ${RC}; $(tr '\n' ';' < "${OUT}/harness-verdict.txt")"
fi

# --- example: deterministic layer, result out before anything else runs -------
rm -rf "${OUT}/deterministic"
mkdir -p "${OUT}/deterministic"
EX_RC=cp-failed
if SBX_T=${T_COPY} sbx_run ${CLOUD} cp "${EXAMPLE_DIR}" "${NAME}:/root/workspace/" > "${OUT}/example-cp.log" 2>&1; then
	SBX_T=${T_EXAMPLE} sbx_exec -e "SBX_CONTEXT=docker-sandbox-${MODE}" "${NAME}" bash "${IN_SANDBOX_EXAMPLE}/run-deterministic.sh" "${IN_SANDBOX_OUT}/compose-demo-deterministic.json" compose-demo-det > "${OUT}/example.stdout" 2>&1
	EX_RC=$?
	for f in compose-demo-deterministic.json compose-demo-deterministic.log compose-demo-deterministic.events.jsonl; do
		SBX_T=${T_COPY} sbx_run ${CLOUD} cp "${NAME}:${IN_SANDBOX_OUT}/${f}" "${OUT}/deterministic/" >> "${OUT}/example-cp.log" 2>&1
	done
fi
sbx_run ${CLOUD} policy log "${NAME}" > "${OUT}/policy-log-after-example.txt" 2>&1
DET=${OUT}/deterministic/compose-demo-deterministic.json
if [ "${EX_RC}" = "cp-failed" ]; then
	layer example FAIL "sbx cp of the example into the sandbox failed (example-cp.log)"
elif has_symlinks "${OUT}/deterministic" > "${OUT}/deterministic.symlinks"; then
	layer example FAIL "a copied-out result is a symlink, not read: $(tr '\n' ' ' < "${OUT}/deterministic.symlinks")"
elif [ ! -f "${DET}" ]; then
	layer example FAIL "run exit ${EX_RC}; the result was not copied out (example-cp.log)"
elif [ "${EX_RC}" = "0" ] && jq -e '.status == "PASS" and .published_ports == 0 and .compose_down == true and .tests.passed == .expected_checks and .tests.failed == 0 and .health.status == "ok"' "${DET}" > /dev/null; then
	layer example PASS "$(jq -r '"engine \(.engine.server_version), compose \(.engine.compose_version); health via \(.health_probe); tests \(.tests.passed)/\(.expected_checks); down; engine log attests"' "${DET}")"
else
	layer example FAIL "run exit ${EX_RC}; $(jq -r '"status \(.status) at \(.failed_step): \(.reason)"' "${DET}" 2>/dev/null) (policy-log-after-example.txt lists refused hosts)"
fi

# --- agent layer ----------------------------------------------------------------
if [ "${AGENT_PLAN}" != "RUN" ]; then
	layer agent NOT_RUN "${AGENT_REASON}"
elif [ "${EX_RC}" = "cp-failed" ]; then
	layer agent FAIL "the example is not in the sandbox (example-cp.log)"
else
	NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
	VTOKEN=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
	T0=$(sbx_exec "${NAME}" date +%s 2>> "${OUT}/agent.log" | tr -d '\r\n')
	PROMPT=$(sed -e "s|{{NONCE}}|${NONCE}|g" -e "s|{{PROJECT}}|compose-demo-agent|g" \
		-e "s|{{REPORT}}|${IN_SANDBOX_OUT}/agent-report.json|g" -e "s|{{EXAMPLE_DIR}}|${IN_SANDBOX_EXAMPLE}|g" \
		"${EXAMPLE_DIR}/agent-task.md")
	echo "${PROMPT}" > "${OUT}/agent-prompt.txt"
	SBX_T=${T_AGENT} sbx_exec -w "${IN_SANDBOX_EXAMPLE}" "${NAME}" bash -c 'export NO_PROXY="${NO_PROXY:+${NO_PROXY},}localhost,127.0.0.1"; export no_proxy="${no_proxy:+${no_proxy},}localhost,127.0.0.1"; exec timeout 900 claude -p "$1" --permission-mode bypassPermissions --output-format json' _ "${PROMPT}" > "${OUT}/agent-session.json" 2>> "${OUT}/agent.log"
	AGENT_RC=$?
	# A fresh verifier, copied in only now, to a path the prompt never named.
	rm -rf "${OUT}/verifier-${VTOKEN}"
	mkdir -p "${OUT}/verifier-${VTOKEN}"
	cp "${EXAMPLE_DIR}/verify-agent-report.py" "${OUT}/verifier-${VTOKEN}/"
	VDIR=/opt/e2e-verify-${VTOKEN}
	VERIFY_RC=not-run
	if SBX_T=${T_COPY} sbx_run ${CLOUD} cp "${OUT}/verifier-${VTOKEN}" "${NAME}:${VDIR}" > "${OUT}/agent-verify-cp.log" 2>&1; then
		sbx_exec "${NAME}" python3 "${VDIR}/verify-agent-report.py" --report "${IN_SANDBOX_OUT}/agent-report.json" \
			--nonce "${NONCE}" --project compose-demo-agent --since "${T0:-0}" --example-dir "${IN_SANDBOX_EXAMPLE}" \
			--verdict "${VDIR}/verdict.json" > "${OUT}/agent-verify.stdout" 2>&1
		VERIFY_RC=$?
		rm -rf "${OUT}/agent-verify" "${OUT}/example-after-agent"
		SBX_T=${T_COPY} sbx_run ${CLOUD} cp "${NAME}:${VDIR}" "${OUT}/agent-verify" >> "${OUT}/agent-verify-cp.log" 2>&1
		SBX_T=${T_COPY} sbx_run ${CLOUD} cp "${NAME}:${IN_SANDBOX_EXAMPLE}" "${OUT}/example-after-agent" >> "${OUT}/agent-verify-cp.log" 2>&1
	fi
	# Every file of the example as shipped must come back unchanged; nothing
	# copied out is read if it holds a symlink.
	UNCHANGED=true
	SYMLINKED=false
	if has_symlinks "${OUT}/agent-verify" "${OUT}/example-after-agent" > "${OUT}/agent-copyout.symlinks"; then
		SYMLINKED=true
		UNCHANGED=false
	fi
	[ "${SYMLINKED}" = "true" ] || while IFS= read -r -d '' f; do
		rel=${f#"${EXAMPLE_DIR}"/}
		if ! { [ -f "${OUT}/example-after-agent/${rel}" ] && cmp -s "${f}" "${OUT}/example-after-agent/${rel}"; }; then
			UNCHANGED=false
			echo "changed or missing: ${rel}" >> "${OUT}/agent-example-diff.txt"
		fi
	done < <(find "${EXAMPLE_DIR}" -type f -print0)
	V=${OUT}/agent-verify/verdict.json
	if [ "${SYMLINKED}" = "true" ]; then
		layer agent FAIL "copied-out agent results hold symlinks, not read: $(tr '\n' ' ' < "${OUT}/agent-copyout.symlinks")"
	elif [ "${VERIFY_RC}" = "0" ] && [ -f "${V}" ] && jq -e '.status == "PASS"' "${V}" > /dev/null && [ "${UNCHANGED}" = "true" ]; then
		layer agent PASS "fresh verifier PASS ($(jq -r '[.checks[] | select(.ok)] | length' "${V}") checks); example files unchanged; claude exit ${AGENT_RC}"
	else
		layer agent FAIL "verifier exit ${VERIFY_RC}; $( [ -f "${V}" ] && jq -r '"failed: " + ([.checks[] | select(.ok | not) | .name] | join(", "))' "${V}" ); example files unchanged=${UNCHANGED}; claude exit ${AGENT_RC}"
	fi
fi

# --- stack: the whole platform comes up and ui-status reports it healthy ------
# On a plain `sbx create` the kit's boot hook starts /startup.sh by itself; e2e
# suppressed that at create (-e SBX_PLATFORM_AUTOSTART=false) so the harness suite
# ran in a platform-free VM. Start the platform the same way the hook does and
# watch /agent/ui-status.sh until the supervisor is UP, the hub and every enabled
# spoke are LIVE, and every enabled UI is UP. conversations and issues are OFF on
# purpose (Slack and GitHub are off the kit's allowlist). hindsight-seed's line is
# recorded, not judged. The one exec holds the session for its
# whole life, so the sandbox does not auto-stop while the platform converges.
STACK_WAIT=$(( T_STACK - 60 ))
[ "${STACK_WAIT}" -lt 120 ] && STACK_WAIT=120
# Reboot the sandbox first (sbx stop; the next exec boots it fresh): the harness
# layer started several UIs on their ports to test them and left processes behind,
# which would stop /startup.sh binding them. A fresh boot clears every process, so
# the platform starts on a clean VM, as it does on a real `sbx create`. The rw
# filesystem survives the reboot, so stale /wd pidfiles are handled by ui-start.sh
# (it checks the pid is alive and is the UI it claims).
SBX_T=120 sbx_run ${CLOUD} stop "${NAME}" > "${OUT}/stack-reboot.log" 2>&1 || note "stack: sbx stop before the platform start returned non-zero (continuing): $(tail -1 "${OUT}/stack-reboot.log")"
SBX_T=${T_STACK} sbx_exec "${NAME}" bash -c '
set -u
WAIT=${1:-480}
[ -f /etc/do-agent-aws-sandbox.env ] && . /etc/do-agent-aws-sandbox.env
setsid nohup /startup.sh > /var/log/do-agent-aws-platform.log 2>&1 < /dev/null &
end=$(( $(date +%s) + WAIT ))
rc=1
while [ "$(date +%s)" -lt "${end}" ]; do
  sleep 10
  OUT=$(/agent/ui-status.sh 2>&1)
  BAD=$(printf "%s\n" "${OUT}" | grep -v "^hindsight-seed:" | grep -E ": (DOWN|STARTING|STARTING-OR-UNHEALTHY|STUCK|NOT-SET-UP|FAILED|UNKNOWN)" || true)
  ready=yes
  printf "%s\n" "${OUT}" | grep -q "^supervisor: UP" || ready=no
  printf "%s\n" "${OUT}" | grep -q "^hub agent: LIVE" || ready=no
  for sp in insights clusters sessions loops; do printf "%s\n" "${OUT}" | grep -q "^spoke ${sp}: LIVE" || ready=no; done
  [ -n "${BAD}" ] && ready=no
  if [ "${ready}" = yes ]; then rc=0; break; fi
done
echo "===== PLATFORM LOG TAIL ====="
tail -n 40 /var/log/do-agent-aws-platform.log 2>/dev/null
echo "===== FINAL UI STATUS ====="
/agent/ui-status.sh 2>&1
echo "===== UI STATUS RC: $? ====="
echo "===== STACK READY RC: ${rc} ====="
' _ "${STACK_WAIT}" > "${OUT}/stack.txt" 2>&1
STACK_EXEC_RC=$?
awk '/^===== FINAL UI STATUS =====$/{f=1;next} /^===== UI STATUS RC:/{f=0} f' "${OUT}/stack.txt" > "${OUT}/ui-status.txt"
STACK_OK=true
STACK_WHY=""
[ -s "${OUT}/ui-status.txt" ] || { STACK_OK=false; STACK_WHY="ui-status produced no output (exec exit ${STACK_EXEC_RC}, stack.txt); "; }
grep -q '^supervisor: UP' "${OUT}/ui-status.txt" || { STACK_OK=false; STACK_WHY="${STACK_WHY}supervisor not UP; "; }
grep -q '^hub agent: LIVE' "${OUT}/ui-status.txt" || { STACK_OK=false; STACK_WHY="${STACK_WHY}hub agent not LIVE; "; }
for sp in insights clusters sessions loops; do
	grep -q "^spoke ${sp}: LIVE" "${OUT}/ui-status.txt" || { STACK_OK=false; STACK_WHY="${STACK_WHY}spoke ${sp} not LIVE; "; }
done
for sp in conversations issues; do
	grep -q "^spoke ${sp}: OFF" "${OUT}/ui-status.txt" || { STACK_OK=false; STACK_WHY="${STACK_WHY}spoke ${sp} not OFF (expected a documented OFF under deny-all); "; }
done
STACK_BAD=$(grep -v '^hindsight-seed:' "${OUT}/ui-status.txt" | grep -E ': (DOWN|STARTING|STARTING-OR-UNHEALTHY|STUCK|NOT-SET-UP|FAILED|UNKNOWN)' || true)
[ -n "${STACK_BAD}" ] && { STACK_OK=false; STACK_WHY="${STACK_WHY}unhealthy: $(echo "${STACK_BAD}" | tr '\n' ' ')"; }
SEED_LINE=$(grep '^hindsight-seed:' "${OUT}/ui-status.txt" | head -1)
UPN=$(grep -cE ': UP ' "${OUT}/ui-status.txt" 2>/dev/null || echo 0)
if [ "${STACK_OK}" = "true" ]; then
	layer stack PASS "platform up by /startup.sh: supervisor UP, hub LIVE, spokes insights/clusters/sessions/loops LIVE, conversations/issues OFF (deny-all), ${UPN} UIs UP; hindsight-seed: ${SEED_LINE:-absent}"
else
	layer stack FAIL "${STACK_WHY}(see stack.txt, ui-status.txt); hindsight-seed: ${SEED_LINE:-absent}"
fi

# --- results out ------------------------------------------------------------------
rm -rf "${OUT}/sandbox-out"
if ! SBX_T=${T_COPY} sbx_run ${CLOUD} cp "${NAME}:${IN_SANDBOX_OUT}" "${OUT}/sandbox-out" > "${OUT}/cp-out.log" 2>&1; then
	layer results FAIL "copying ${IN_SANDBOX_OUT} out failed (cp-out.log); the layer results above were copied separately"
elif has_symlinks "${OUT}/sandbox-out" > "${OUT}/sandbox-out.symlinks"; then
	# Record where each link pointed (without following it), then remove the links.
	while IFS= read -r l; do printf '%s -> %s\n' "${l}" "$(readlink "${l}")"; done < "${OUT}/sandbox-out.symlinks" > "${OUT}/sandbox-out.symlinks.txt"
	find "${OUT}/sandbox-out" -type l -delete
	layer results FAIL "${IN_SANDBOX_OUT} held symlinks; refused and removed from the host copy (sandbox-out.symlinks.txt)"
else
	layer results PASS "${IN_SANDBOX_OUT} copied out ($(find "${OUT}/sandbox-out" -type f | wc -l) files, no symlinks)"
fi

# --- ttl --------------------------------------------------------------------------
if [ "${MODE}" = "cloud" ]; then
	if sbx_run --cloud ttl --json "${NAME}" > "${OUT}/ttl.json" 2>&1 && python3 - "${OUT}/ttl.json" << 'EOF'
import datetime, json, re, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict) or d.get("stopped") is True or d.get("ttl_paused") is True:
    sys.exit(1)
now = datetime.datetime.now(datetime.timezone.utc)

def future(v):
    if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 1e9:
        return datetime.datetime.fromtimestamp(v / (1000 if v > 1e12 else 1), datetime.timezone.utc) > now
    if isinstance(v, str):
        try:
            t = datetime.datetime.fromisoformat(v.replace("Z", "+00:00"))
        except ValueError:
            return False
        return (t if t.tzinfo else t.replace(tzinfo=datetime.timezone.utc)) > now
    return False

def has_future_expiry(o):
    if isinstance(o, dict):
        return any((re.search(r"expir|deadline", k, re.I) and future(v)) or has_future_expiry(v) for k, v in o.items())
    if isinstance(o, list):
        return any(has_future_expiry(x) for x in o)
    return False

sys.exit(0 if has_future_expiry(d) else 1)
EOF
	then
		layer ttl PASS "$(jq -c . "${OUT}/ttl.json")"
	else
		layer ttl FAIL "sbx --cloud ttl --json ${NAME}: running, not paused and a future expiry field are all required: $(head -c 300 "${OUT}/ttl.json")"
	fi
fi

# --- teardown and verdict ---------------------------------------------------------
teardown
EXIT=0
while IFS=$'\t' read -r l s _; do
	case "${s}" in
	FAIL|BLOCKED|UNVERIFIED) EXIT=1 ;;
	NOT_RUN) [ "${l}" = "agent" ] || [ "${l}" = "teardown" ] || [ "${l}" = "secret" ] || EXIT=1 ;;
	esac
done < "${LAYERS}"
[ "$(layer_status teardown)" = "NOT_RUN" ] && [ "${KEEP}" != "true" ] && EXIT=1
# Every layer that ran passed, but not all of them ran: the agent (no credential)
# or the teardown (--keep).
if [ ${EXIT} -eq 0 ] && { [ "$(layer_status agent)" != "PASS" ] || [ "$(layer_status teardown)" != "PASS" ]; }; then
	finish 3 PARTIAL
fi
finish ${EXIT}
