#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Sandbox test5 - e2e.sh's control flow against a scripted sbx stand-in: no
# Docker, no sign-in, no KVM, nothing created anywhere. e2e.sh runs from a
# throwaway clone of HEAD (it tests HEAD only and refuses a dirty tree), with a
# scripted `sbx` first on PATH that records every call. Each check FAILS if the
# property it proves is removed:
#    1. INT during a hanging `sbx create` is handled within 15 seconds: the
#       create call is killed, rm --force is issued, summary.json says FAIL, and
#       stdout (not create.log) reports the interrupt and that teardown is in
#       progress, ignoring signals, with its bound (and no retry: the exit
#       handler's teardown is the last)
#    2. a sandbox that create did not report but that shows up afterwards is
#       found by the teardown watch and removed: teardown PASS, run FAIL
#    3. a sandbox that is never listed is reported UNVERIFIED, not PASS, with the
#       rm --force command to run
#    4. when the policy layer fails (a host off the allowlist answers), nothing
#       live runs: platform, harness, example and agent are NOT_RUN, no harness
#       test, example or claude call is issued, and the sandbox is removed
#    5. the same when the policy holds but the provenance layer fails
#    6. a second INT during teardown is ignored: the rm --force completes, the
#       teardown layer is recorded and summary.json is written
#    7. push-kit.sh refuses, building and pushing nothing, a repository Docker
#       Hub reports public, one it cannot confirm (no token) and one it reports
#       not private (a stub of the Docker Hub API on 127.0.0.1 stands in)
#    8. one INT during a normal teardown (on the gated path), sent while its
#       rm --force still sleeps, is ignored: that rm completes and is the only
#       one, nothing reports an interrupt, the sandbox is no longer listed, the
#       teardown layer is PASS and summary.json is written; its line gives the
#       bound for one pass and for the retry on exit
#    9. push-kit.sh refuses an API endpoint other than Docker Hub or a local
#       stub (another host, userinfo that names one, a path or query after the
#       port), and refuses to run under bash -x, SHELLOPTS=xtrace or
#       BASH_XTRACEFD, each before any request is made: the token waiting on
#       its stdin is left unread and never printed
#   10. a summary written during teardown calls no sbx: with every sbx version
#       call after preflight's hanging, a run interrupted during create still
#       ends (a 60 s watchdog would KILL it), and summary.json carries
#       preflight's reading
#   11. a local run (dry) with a kit directory that sbx has not built stops in
#       preflight within 60 s with KIT_NOT_BUILT and the pre-build commands
#       with their warning, having asked a stub of sbx's kit registry for
#       test/kit-key.py's reference with one HEAD request and called neither
#       create nor kit inspect; http_proxy, ALL_PROXY and ~/.curlrc pointing
#       at a stub that would answer "built" do not redirect that request; with
#       the build in the registry (200 with the digest header), no KIT_
#       blocker; a registry reported unreachable or off 127.0.0.1 is not asked;
#       and when it cannot tell (200 without the digest header, 500, a closed
#       port, no answer within E2E_T_KIT_REGISTRY - set to 20 s here, the
#       run then ends within 45 s - no registry named, sbx other than exactly
#       v0.47.0, a kit directory kit-key.py refuses), KIT_BUILD_UNKNOWN naming
#       the cause: it fails closed; a registry that answers 200 with the
#       digest only after 25 s (sbx 0.47.0 copies a new build in from the
#       Docker engine on the first request; 93 s on the KVM test host) is
#       waited for at the default setting: no KIT_ blocker
#   12. the policy layer fails, and nothing live runs, when the Anthropic API
#       answers and sbx policy log does not list it as blocked, and when the
#       Bedrock runtime endpoint gets an answer without AWS's x-amzn-RequestId
#       header (the proxy's refusal), each naming the host; teardown removes a
#       bedrock secret scoped to the sandbox (secret layer PASS) and removes
#       no secret when none was scoped
#   13. the model credential, in local dry runs: a bedrock secret scoped to the
#       run's sandbox plus a bedrock binding for
#       bedrock-runtime.us-east-1.amazonaws.com plans the agent layer and the
#       secret's removal, with service-neutral credential fields in
#       summary.json; a global bedrock secret alone, no secret, and an
#       anthropic binding only leave the agent layer NOT_RUN with the reason and
#       the exact setup command, and plan no secret removal; when secret ls
#       --sandbox fails, the credential is "unknown (secret ls --sandbox
#       failed)", not read as a global or absent secret, and the agent layer
#       stays NOT_RUN
#   14. to/sandbox/bedrock-token.sh, against stubs of botocore and
#       aws-bedrock-token-generator in a real venv: only the key, one line, on
#       stdout, from the venv SBX_BEDROCK_VENV names or the default one under
#       HOME, for the profile and region given; a usage error, a missing venv,
#       a profile without credentials and a generator that returns no key exit
#       non-zero with nothing on stdout (the bad value not echoed); PYTHONPATH
#       and the working directory cannot substitute the generator (isolated
#       mode), and PLANTED CONTROLS without -I show that they otherwise would
#   15. the model key never enters the sandbox: with provenance and policy
#       passing, the platform layer judges AWS_BEARER_TOKEN_BEDROCK as e2e.sh's
#       own probe script reports it (run here, with the in-sandbox value each
#       scenario plants): with the model credential configured, the sentinel
#       proxy-managed passes, and a PLANTED real-looking Bedrock API key
#       (bedrock-api-key-...) or any other value fails, naming the reason;
#       without a credential, an unset variable passes and a planted key fails,
#       short-term (bedrock-api-key-...) or long-term (ABSK...);
#       after such a failure nothing live runs: harness, example and agent are
#       NOT_RUN, no harness, example or claude call is issued, the sandbox is
#       removed and the exit is 1 (a passing platform layer goes on to the
#       harness, the control), with --keep too, which is then overridden: the
#       sandbox-scoped secret and the sandbox are removed (secret and teardown
#       PASS); only the length is recorded, and the planted key
#       appears nowhere in the run's output, also when the probe's shell starts
#       with xtrace on (it traces, the control)
#   16. --require-agent and the host model check (local dry runs, a stub helper and a
#       stub of the Bedrock runtime on 127.0.0.1): with the check passing (one request
#       per pinned model, with the helper's key) the dry run is clean and says that
#       Bedrock access from inside the sandbox is not verified; AWS refusing the key
#       (its reason given, the account masked), a missing or failing helper, an
#       endpoint other than AWS or 127.0.0.1 and a missing sandbox secret block
#       preflight (no request is made once the helper or endpoint is refused);
#       without the flag the refusal is a warning; the planted key appears nowhere,
#       also when e2e.sh runs traced (SHELLOPTS=xtrace, as bash -x gives it); an
#       interrupt while the check waits on the endpoint leaves no key file behind
#       (the control: the key file is there while it waits)
#   17. a host whose network policy was never initialized is blocked with
#       NEEDS_POLICY_INIT, and its commands build a kit that is not built yet under
#       the balanced preset before they switch to deny-all, naming render.sh and the
#       kit by their absolute paths and the descriptor's sizes
# Needs bash 4.4+, git, jq, python3 with PyYAML and venv, curl, base64.

BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
D=$(mktemp -d)
OUT=${BASE_DIR}/wd/sandbox-test5/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "${OUT}"

cleanup()
{
	# the registry stubs of case 11, if a check failed while they ran
	if [ -f "${D}/stub.pids" ]; then
		while read -r p; do kill "${p}" 2> /dev/null; done < "${D}/stub.pids"
	fi
	rm -rf "${D}"
}
trap cleanup EXIT

fail()
{
	echo "Sandbox test5 FAILED: $1"
	exit 1
}

git clone -q --no-hardlinks "${BASE_DIR}" "${D}/clone" 2> "${D}/clone.err" || fail "git clone failed: $(cat "${D}/clone.err")"
E2E=${D}/clone/to/sandbox/test/e2e.sh
mkdir -p "${D}/bin"
cat > "${D}/bin/sbx" << 'EOF'
#!/bin/bash
# scripted sbx for test5; SCRIPTED_MODE: hang | late | never | open-egress | bad-provenance | slow-rm | gate-slow-rm | hang-version |
# anthropic-open | bedrock-refused (case 12) | local-* (case 11) | cred-* (case 13) | platform-* (case 15). SCRIPTED_SECRET_SANDBOX and
# SCRIPTED_SECRET_GLOBAL are what secret ls lists for --service bedrock in that scope (nothing when unset);
# SCRIPTED_SECRET_LS_FAIL makes secret ls --sandbox fail.
S=${SCRIPTED_STATE:?}
echo "$*" >> "${S}/calls.log"
[ "${1:-}" = "--cloud" ] && shift
case "${1:-}" in
version)
	n=$(( $(cat "${S}/version-calls" 2> /dev/null || echo 0) + 1 ))
	echo "${n}" > "${S}/version-calls"
	# hang-version: every call after the first (preflight's) hangs
	[ "${SCRIPTED_MODE}" = "hang-version" ] && [ "${n}" -gt 1 ] && exec sleep 600
	echo "sbx version: v${SCRIPTED_SBX_VERSION:-0.47.0} (scripted)"
	;;
kit)
	# kit builder status, as sbx 0.47.0 prints it; local-no-registry leaves out the registry
	if [ "${2:-}" = "builder" ] && [ "${3:-}" = "status" ]; then
		echo "Builder:      not created (the first source-form kit build creates it)"
		echo "Builder kit:  docker.io/docker/sbx-kit-builder:1"
		[ "${SCRIPTED_MODE}" = "local-no-registry" ] || echo "Kit registry: ${SCRIPTED_REGISTRY:-} ${SCRIPTED_REGISTRY_STATE:-— reachable}"
	fi
	;;
diagnose) echo "scripted diagnose" ;;
ls)
	if [ -f "${S}/pending" ]; then
		n=$(( $(cat "${S}/ls-count" 2> /dev/null || echo 0) + 1 ))
		echo "${n}" > "${S}/ls-count"
		[ "${SCRIPTED_MODE}" = "late" ] && [ "${n}" -ge 2 ] && mv "${S}/pending" "${S}/listed"
	fi
	[ -f "${S}/listed" ] && cat "${S}/listed"
	;;
create)
	shift
	while [ $# -gt 0 ]; do [ "$1" = "--name" ] && NAME=$2; shift; done
	case "${SCRIPTED_MODE}" in
	hang|slow-rm|hang-version) exec sleep 600 ;;
	late|never) echo "${NAME}" > "${S}/pending"; echo "created" ;;
	open-egress|bad-provenance|gate-slow-rm|anthropic-open|bedrock-refused|platform-*) echo "${NAME}" > "${S}/listed"; echo "created" ;;
	esac
	;;
exec)
	# the policy layer's probes. bad-provenance: egress held. anthropic-open: held, but the
	# Anthropic API answers (401 without a key) and is not logged as blocked. bedrock-refused:
	# held, but the Bedrock runtime endpoint gets the proxy's refusal, no answer from AWS.
	# platform-*: egress held, and provenance and platform answer (below).
	case "$*" in
	*'sha256sum test*.sh'*)
		# provenance, platform-* only: the hashes of HEAD's files, from the clone e2e.sh runs in
		case "${SCRIPTED_MODE}" in platform-*)
			( cd "${SCRIPTED_REPO:?}/Container-Root" && sha256sum test*.sh )
			cat "${SCRIPTED_REPO}/Dockerfile" "${SCRIPTED_REPO}/to/sandbox/template/sandbox.dockerfile" | sha256sum | sed "s#-\$#${7}#" ;;
		esac ;;
	*'uid=$(id -u)'*)
		# platform, platform-* only: the facts of a 4 CPU, 8 GiB root sandbox, then every
		# other line of e2e.sh's own probe script (argument 5), run here with the
		# in-sandbox AWS_BEARER_TOKEN_BEDROCK read from SCRIPTED_BEARER_FILE (unset
		# without one) and stubs of docker and claude first on PATH. Only the fixed
		# facts above are dropped from the probe's output, so a value the probe prints
		# under any name reaches the run's output, where case 15 looks for it.
		case "${SCRIPTED_MODE}" in platform-*)
			printf 'uid=0 user=root home=/root pwd=/root/workspace\nnproc=4\ncpu_max=\nmemtotal_kb=8217060\nmemory_max=\ndocker_server=29.8.2\ncompose=5.6.0\nclaude=2.1.293 (Claude Code)\nproxy_vars=\nno_proxy_list=\n'
			# SCRIPTED_PROBE_XTRACE: the probe's shell starts with xtrace on
			if [ -n "${SCRIPTED_BEARER_FILE:-}" ]; then
				AWS_BEARER_TOKEN_BEDROCK=$(cat "${SCRIPTED_BEARER_FILE}") PATH="${SCRIPTED_STUBS:?}:${PATH}" bash ${SCRIPTED_PROBE_XTRACE:+-x} -c "$5" | grep -vE '^(uid|nproc|cpu_max|memtotal_kb|memory_max|docker_server|compose|claude|proxy_vars|no_proxy_list)='
			else
				env -u AWS_BEARER_TOKEN_BEDROCK PATH="${SCRIPTED_STUBS:?}:${PATH}" bash -c "$5" | grep -vE '^(uid|nproc|cpu_max|memtotal_kb|memory_max|docker_server|compose|claude|proxy_vars|no_proxy_list)='
			fi ;;
		esac ;;
	*registry-1.docker.io*) printf 401 ;;
	*bedrock-runtime.us-east-1.amazonaws.com*) [ "${SCRIPTED_MODE}" = "bedrock-refused" ] && printf '403 no-aws-header' || printf '404 aws' ;;
	*api.anthropic.com*)
		case "${SCRIPTED_MODE}" in bad-provenance|bedrock-refused|platform-*) printf 000 ;; anthropic-open) printf 401 ;; *) printf 200 ;; esac ;;
	*example.com*|*registry.npmjs.org*)
		case "${SCRIPTED_MODE}" in bad-provenance|anthropic-open|bedrock-refused|platform-*) printf 000 ;; *) printf 200 ;; esac ;;
	esac
	;;
policy)
	# SCRIPTED_POLICY_UNINIT: a host whose global network policy was never initialized
	if [ "${2:-}" = "ls" ] && [ -n "${SCRIPTED_POLICY_UNINIT:-}" ]; then
		echo "The global network policy has not been initialized. Run 'sbx policy init <allow-all|balanced|deny-all>'."
	fi
	if [ "${2:-}" = "log" ]; then
		case "${SCRIPTED_MODE}" in
		bad-provenance|bedrock-refused|platform-*)
			printf 'Blocked requests:\nSANDBOX  TYPE     HOST\nx        network  example.com\nx        network  registry.npmjs.org\nx        network  api.anthropic.com\n' ;;
		anthropic-open)
			printf 'Blocked requests:\nSANDBOX  TYPE     HOST\nx        network  example.com\nx        network  registry.npmjs.org\n' ;;
		*) printf 'Blocked requests:\n(none)\n' ;;
		esac
	fi
	;;
rm)
	case "${SCRIPTED_MODE}" in slow-rm|gate-slow-rm) sleep 6 ;; esac
	rm -f "${S}/listed"
	echo "done" >> "${S}/rm-done"
	;;
secret)
	case "${2:-}" in
	ls)
		case "$*" in
		*" --sandbox "*" --service bedrock "*)
			[ -z "${SCRIPTED_SECRET_LS_FAIL:-}" ] || { echo "scripted: secret ls --sandbox failed" >&2; exit 1; }
			[ -z "${SCRIPTED_SECRET_SANDBOX:-}" ] || [ -e "${S}/secret-removed" ] || echo "${SCRIPTED_SECRET_SANDBOX}" ;;
		*" -g --service bedrock "*) [ -z "${SCRIPTED_SECRET_GLOBAL:-}" ] || echo "${SCRIPTED_SECRET_GLOBAL}" ;;
		esac
		;;
	# only the removal of the sandbox-scoped bedrock secret takes it away
	rm) case "$*" in "secret rm bedrock --sandbox "*" -f") touch "${S}/secret-removed" ;; esac ;;
	esac
	;;
cp|ttl) : ;;
esac
exit 0
EOF
chmod +x "${D}/bin/sbx"

E2E_ARGS=()
run_e2e()
{
	# $1 = scenario; runs e2e.sh in the background in its own session and process
	# group, with INT and QUIT restored to their defaults as at a terminal (a
	# background job starts with them ignored, and bash cannot trap a signal it
	# inherited as ignored); E2E_ARGS adds arguments
	mkdir -p "${D}/$1"
	SCRIPTED_STATE=${D}/$1 SCRIPTED_MODE=$1 E2E_TEARDOWN_WATCH=${WATCH:-0} PATH="${D}/bin:${PATH}" \
		python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.setsid()
os.execv(sys.argv[1], sys.argv[1:])' "${E2E}" --cloud --allow-source-kit --skip-agent --name "test5-$1" --out "${OUT}/$1" "${E2E_ARGS[@]}" > "${OUT}/$1.log" 2>&1 &
	PID=$!
}

# 1. INT while create hangs
run_e2e hang
for _ in $(seq 1 60); do grep -q " create " "${D}/hang/calls.log" 2> /dev/null && break; sleep 1; done
grep -q " create " "${D}/hang/calls.log" || fail "e2e.sh never reached create: $(tail -3 "${OUT}/hang.log")"
sleep 2
T0=$(date +%s)
kill -INT -- "-${PID}"
wait "${PID}"
RC=$?
T=$(( $(date +%s) - T0 ))
[ "${T}" -le 15 ] || fail "INT during create took ${T} s to be handled"
[ "${RC}" -ne 0 ] || fail "an interrupted run exited 0"
grep -q "rm --force test5-hang" "${D}/hang/calls.log" || fail "no rm --force after the interrupted create"
[ "$(jq -r .overall "${OUT}/hang/summary.json")" = "FAIL" ] || fail "an interrupted run's summary is not FAIL"
# what the operator sees: the handlers write to the run's stdout, not into the
# log of the call the INT arrived in (create.log)
grep -q " interrupted$" "${OUT}/hang.log" || fail "hang: the interrupt is not reported on stdout"
grep -qE "teardown of test5-hang in progress: INT, TERM and HUP are ignored until it finishes \(at most [0-9]+ s\)" "${OUT}/hang.log" \
	|| fail "hang: stdout does not say that teardown is in progress and ignores signals, with its bound"
grep -q "interrupted" "${OUT}/hang/create.log" && fail "hang: the handlers wrote into create.log"
grep -q "retried once on exit" "${OUT}/hang.log" && fail "hang: the exit handler's teardown says it will be retried; nothing retries it"
echo "ok 1 - INT during a hanging create handled in ${T} s: create killed, rm --force issued, summary FAIL; stdout says teardown is in progress, ignoring signals, with its bound"

# 2. a sandbox that shows up after create
WATCH=10 run_e2e late
wait "${PID}"
[ "$(jq -r .layers.create.status "${OUT}/late/summary.json")" = "FAIL" ] || fail "late: create was not FAIL"
[ "$(jq -r .layers.teardown.status "${OUT}/late/summary.json")" = "PASS" ] || fail "late: teardown did not find and remove the sandbox: $(jq -c .layers.teardown "${OUT}/late/summary.json")"
[ ! -f "${D}/late/listed" ] || fail "late: the sandbox is still listed"
echo "ok 2 - a sandbox that shows up after create is found by the teardown watch and removed"

# 3. a sandbox never listed
run_e2e never
wait "${PID}"
RC=$?
[ "$(jq -r .layers.teardown.status "${OUT}/never/summary.json")" = "UNVERIFIED" ] || fail "never: teardown was not UNVERIFIED: $(jq -c .layers.teardown "${OUT}/never/summary.json")"
[ "${RC}" -eq 1 ] || fail "never: exit ${RC}, expected 1"
jq -r .layers.teardown.detail "${OUT}/never/summary.json" | grep -qE 'remove it with: sbx --cloud rm --force test5-never \(otherwise its TTL removes it\)[[:space:]]*$' \
	|| fail "never: the UNVERIFIED detail does not give the rm --force command: $(jq -r .layers.teardown.detail "${OUT}/never/summary.json")"
echo "ok 3 - a sandbox never listed is reported UNVERIFIED (exit 1), not PASS, with the rm --force command to run"

# 4. policy FAIL stops everything live
run_e2e open-egress
wait "${PID}"
RC=$?
S=${OUT}/open-egress/summary.json
[ "$(jq -r .layers.policy.status "${S}")" = "FAIL" ] || fail "open-egress: the policy layer did not fail: $(jq -c .layers.policy "${S}")"
for l in platform harness example agent; do
	[ "$(jq -r ".layers.${l}.status" "${S}")" = "NOT_RUN" ] || fail "open-egress: ${l} is $(jq -r ".layers.${l}.status" "${S}"), expected NOT_RUN"
done
grep -qE 'claude -p|/test\*\.sh|run-deterministic' "${D}/open-egress/calls.log" && fail "open-egress: a live call was issued after the policy layer failed"
[ "$(jq -r .layers.teardown.status "${S}")" = "PASS" ] && [ "${RC}" -eq 1 ] || fail "open-egress: teardown $(jq -r .layers.teardown.status "${S}"), exit ${RC}"
echo "ok 4 - a failed policy layer stops everything live: platform, harness, example and agent NOT_RUN, sandbox removed, exit 1"

# 5. policy holds, provenance fails: still nothing live
run_e2e bad-provenance
wait "${PID}"
RC=$?
S=${OUT}/bad-provenance/summary.json
[ "$(jq -r .layers.policy.status "${S}")" = "PASS" ] || fail "bad-provenance: the scripted policy did not pass: $(jq -c .layers.policy "${S}")"
[ "$(jq -r .layers.provenance.status "${S}")" = "FAIL" ] || fail "bad-provenance: provenance did not fail"
for l in platform harness example agent; do
	[ "$(jq -r ".layers.${l}.status" "${S}")" = "NOT_RUN" ] || fail "bad-provenance: ${l} is $(jq -r ".layers.${l}.status" "${S}"), expected NOT_RUN"
done
grep -qE 'claude -p|/test\*\.sh|run-deterministic' "${D}/bad-provenance/calls.log" && fail "bad-provenance: a live call was issued after the provenance layer failed"
[ "${RC}" -eq 1 ] || fail "bad-provenance: exit ${RC}, expected 1"
echo "ok 5 - a failed provenance layer stops everything live even when the policy holds"

# 6. a second INT during teardown
run_e2e slow-rm
for _ in $(seq 1 60); do grep -q " create " "${D}/slow-rm/calls.log" 2> /dev/null && break; sleep 1; done
sleep 2
kill -INT -- "-${PID}"
for _ in $(seq 1 20); do grep -q "rm --force" "${D}/slow-rm/calls.log" 2> /dev/null && break; sleep 0.5; done
grep -q "rm --force" "${D}/slow-rm/calls.log" || fail "slow-rm: teardown never started"
sleep 1
kill -INT -- "-${PID}" 2> /dev/null
wait "${PID}"
[ -s "${D}/slow-rm/rm-done" ] || fail "slow-rm: the second INT killed the teardown's rm --force"
[ -f "${OUT}/slow-rm/summary.json" ] || fail "slow-rm: no summary.json"
[ -n "$(jq -r '.layers.teardown.status // empty' "${OUT}/slow-rm/summary.json")" ] || fail "slow-rm: no teardown layer recorded"
echo "ok 6 - a second INT during teardown is ignored: rm --force completed, teardown $(jq -r .layers.teardown.status "${OUT}/slow-rm/summary.json"), summary.json written"

# 7. push-kit.sh refusals, against a stub of the Docker Hub API
cat > "${D}/hub-stub.py" << 'EOF'
import http.server, json, sys
MODE = sys.argv[1]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        authed = self.headers.get("Authorization", "").startswith("Bearer stub-token")
        if MODE == "public":
            return self.reply(200, {"is_private": False})
        if not authed:
            return self.reply(404, {"message": "not found"})
        return self.reply(200, {"is_private": MODE != "not-private"})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if MODE == "no-token":
            return self.reply(401, {"message": "unauthorized"})
        return self.reply(200, {"access_token": "stub-token"})

s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
EOF
mkdir -p "${D}/pushbin"
cat > "${D}/pushbin/docker" << 'EOF'
#!/bin/bash
echo "$*" >> "${DOCKER_CALLS:?}"
exit 1
EOF
chmod +x "${D}/pushbin/docker"
for mode in public no-token not-private; do
	python3 "${D}/hub-stub.py" "${mode}" > "${D}/stub-${mode}.port" &
	STUB=$!
	for _ in $(seq 1 50); do [ -s "${D}/stub-${mode}.port" ] && break; sleep 0.1; done
	: > "${D}/docker-${mode}.calls"
	echo "not-a-real-token" | DOCKER_CALLS="${D}/docker-${mode}.calls" PATH="${D}/pushbin:${PATH}" \
		DOCKERHUB_USER=test5 DOCKERHUB_API="http://127.0.0.1:$(cat "${D}/stub-${mode}.port")" \
		"${D}/clone/to/sandbox/push-kit.sh" docker.io/test5ns/do-agent-aws-sandbox:test5 > "${OUT}/push-${mode}.log" 2>&1
	RC=$?
	kill "${STUB}" 2> /dev/null
	wait "${STUB}" 2> /dev/null
	[ "${RC}" -ne 0 ] || fail "push-kit.sh ${mode}: exit 0, expected a refusal"
	grep -qiE 'refusing|cannot confirm|PUBLIC' "${OUT}/push-${mode}.log" || fail "push-kit.sh ${mode}: no refusal message: $(tail -2 "${OUT}/push-${mode}.log")"
	[ ! -s "${D}/docker-${mode}.calls" ] || fail "push-kit.sh ${mode}: docker was called: $(cat "${D}/docker-${mode}.calls")"
done
echo "ok 7 - push-kit.sh refuses a public repository, one it cannot confirm and one not reported private, calling docker not at all"

# 8. one INT during a normal teardown
run_e2e gate-slow-rm
for _ in $(seq 1 120); do grep -q "rm --force" "${D}/gate-slow-rm/calls.log" 2> /dev/null && break; sleep 0.5; done
grep -q "rm --force" "${D}/gate-slow-rm/calls.log" || fail "gate-slow-rm: teardown never started: $(tail -3 "${OUT}/gate-slow-rm.log")"
sleep 1
# the control: the INT must arrive while rm still sleeps
[ ! -e "${D}/gate-slow-rm/rm-done" ] || fail "gate-slow-rm: rm finished before the INT was sent, so this case proves nothing"
kill -INT -- "-${PID}"
wait "${PID}"
S=${OUT}/gate-slow-rm/summary.json
[ -s "${D}/gate-slow-rm/rm-done" ] || fail "gate-slow-rm: one INT cut the teardown's rm --force short"
[ ! -f "${D}/gate-slow-rm/listed" ] || fail "gate-slow-rm: the sandbox is still listed"
[ -f "${S}" ] || fail "gate-slow-rm: no summary.json"
[ "$(jq -r '.layers.teardown.status // empty' "${S}")" = "PASS" ] || fail "gate-slow-rm: teardown is '$(jq -r '.layers.teardown.status // empty' "${S}")', expected PASS"
grep -q "ignored until it finishes" "${OUT}/gate-slow-rm.log" || fail "gate-slow-rm: teardown did not say that it ignores signals"
B=$(sed -n 's/.*teardown of test5-gate-slow-rm in progress: INT, TERM and HUP are ignored until it finishes (at most \([0-9]*\) s; if it fails, it is retried once on exit: at most \([0-9]*\) s in all)$/\1 \2/p' "${OUT}/gate-slow-rm.log")
[ -n "${B}" ] && [ "${B#* }" -eq $(( 2 * ${B% *} )) ] || fail "gate-slow-rm: the teardown line does not give the bound for one pass and for the retry on exit ('${B}')"
# the INT was ignored, not handled: no interrupt, and the first rm was the only one
grep -q " interrupted$" "${OUT}/gate-slow-rm/e2e.log" && fail "gate-slow-rm: the INT interrupted the teardown (a retry from the exit handler then removed the sandbox)"
[ "$(grep -c "rm --force" "${D}/gate-slow-rm/calls.log")" -eq 1 ] || fail "gate-slow-rm: $(grep -c "rm --force" "${D}/gate-slow-rm/calls.log") rm --force calls, expected 1 (the INT cut the first one short)"
echo "ok 8 - one INT while the teardown's rm --force sleeps is ignored: that rm completed (the only one), sandbox gone, teardown PASS, summary.json written"

# 9. push-kit.sh refusals before any request or token read
mkdir -p "${D}/nonet"
cat > "${D}/nonet/curl" << 'EOF'
#!/bin/bash
echo "$*" >> "${CURL_CALLS:?}"
exit 7
EOF
chmod +x "${D}/nonet/curl"
# Runs a command with a token waiting on its stdin, then reports whether the
# token is still there (unread) once the command has exited.
cat > "${D}/stdin-unread.py" << 'EOF'
import os, subprocess, sys
token = b"not-a-real-token\n"
r, w = os.pipe()
os.write(w, token)
os.close(w)
with open(sys.argv[1], "w") as log:
    rc = subprocess.run(sys.argv[2:], stdin=r, stdout=log, stderr=subprocess.STDOUT).returncode
left = os.read(r, len(token) + 1)
print("rc=%d token_unread=%s" % (rc, "yes" if left == token else "no"))
EOF
refused_early()
{
	# $1 = case, $2 = expected refusal, then the command
	local c=$1 msg=$2 res
	shift 2
	: > "${D}/curl-${c}.calls"
	: > "${D}/docker-${c}.calls"
	res=$(CURL_CALLS="${D}/curl-${c}.calls" DOCKER_CALLS="${D}/docker-${c}.calls" PATH="${D}/nonet:${D}/pushbin:${PATH}" DOCKERHUB_USER=test5 \
		python3 "${D}/stdin-unread.py" "${OUT}/push-${c}.log" "$@")
	case "${res}" in
	"rc=0 "*) fail "push-kit.sh ${c}: it ran instead of refusing (${res})" ;;
	*" token_unread=yes") ;;
	*) fail "push-kit.sh ${c}: the token on its stdin was read (${res})" ;;
	esac
	grep -q "${msg}" "${OUT}/push-${c}.log" || fail "push-kit.sh ${c}: no refusal message: $(tail -1 "${OUT}/push-${c}.log")"
	[ ! -s "${D}/curl-${c}.calls" ] || fail "push-kit.sh ${c}: a request was made: $(cat "${D}/curl-${c}.calls")"
	[ ! -s "${D}/docker-${c}.calls" ] || fail "push-kit.sh ${c}: docker was called: $(cat "${D}/docker-${c}.calls")"
	! grep -q "not-a-real-token" "${OUT}/push-${c}.log" || fail "push-kit.sh ${c}: the token was printed"
}
P=${D}/clone/to/sandbox/push-kit.sh
R=docker.io/test5ns/do-agent-aws-sandbox:test5
refused_early badapi "DOCKERHUB_API must be" env DOCKERHUB_API=http://hub.example.invalid "${P}" "${R}"
# userinfo would name another host (the host is what follows the @); so would a
# suffix after Docker Hub; a path or query after the port is refused too
refused_early userinfo "DOCKERHUB_API must be" env DOCKERHUB_API=http://127.0.0.1:x@attacker.example "${P}" "${R}"
refused_early userinfo-localhost "DOCKERHUB_API must be" env DOCKERHUB_API=https://localhost:1@attacker.example "${P}" "${R}"
refused_early userinfo-hub "DOCKERHUB_API must be" env DOCKERHUB_API=https://hub.docker.com@attacker.example "${P}" "${R}"
refused_early path "DOCKERHUB_API must be" env DOCKERHUB_API=http://127.0.0.1:9/x "${P}" "${R}"
refused_early query "DOCKERHUB_API must be" env DOCKERHUB_API=http://127.0.0.1:9?x=@attacker.example "${P}" "${R}"
refused_early xtrace "refusing to run with xtrace" env DOCKERHUB_API=http://127.0.0.1:9 bash -x "${P}" "${R}"
refused_early shellopts "refusing to run with xtrace" env DOCKERHUB_API=http://127.0.0.1:9 SHELLOPTS=xtrace "${P}" "${R}"
refused_early xtracefd "refusing to run with BASH_XTRACEFD set" env DOCKERHUB_API=http://127.0.0.1:9 BASH_XTRACEFD=2 "${P}" "${R}"
echo "ok 9 - push-kit.sh refuses another API endpoint (another host; userinfo naming a host after 127.0.0.1, localhost or hub.docker.com; a path or query after the port), bash -x, SHELLOPTS=xtrace and BASH_XTRACEFD before any request: the token on its stdin is left unread and never printed"

# 10. a summary written during teardown calls nothing: every sbx version call
#     after preflight's hangs; the run, interrupted during create, still ends
run_e2e hang-version
for _ in $(seq 1 60); do grep -q " create " "${D}/hang-version/calls.log" 2> /dev/null && break; sleep 1; done
grep -q " create " "${D}/hang-version/calls.log" || fail "hang-version: e2e.sh never reached create: $(tail -3 "${OUT}/hang-version.log")"
sleep 2
kill -INT -- "-${PID}"
# a watchdog: KILL the run's process group if it is still there after 60 s
(
	trap 'kill "${s}" 2> /dev/null; exit 0' TERM
	sleep 60 &
	s=$!
	wait "${s}"
	kill -KILL -- "-${PID}" 2> /dev/null && touch "${D}/hang-version/watchdog-fired"
) &
WD=$!
wait "${PID}"
kill "${WD}" 2> /dev/null
wait "${WD}" 2> /dev/null
[ ! -e "${D}/hang-version/watchdog-fired" ] || fail "hang-version: e2e.sh was still running 60 s after the INT (killed): a second sbx version call hung while it wrote its summary"
[ "$(cat "${D}/hang-version/version-calls")" -eq 1 ] || fail "hang-version: sbx version was called $(cat "${D}/hang-version/version-calls") times, expected once (preflight)"
S=${OUT}/hang-version/summary.json
[ -f "${S}" ] || fail "hang-version: no summary.json"
[ "$(jq -r .sbx_version "${S}")" = "sbx version: v0.47.0 (scripted)" ] || fail "hang-version: summary.json's sbx_version is '$(jq -r .sbx_version "${S}")', not preflight's reading"
echo "ok 10 - sbx version is read once, in preflight: with every later call hanging, a run interrupted during create still tears down and writes summary.json, with preflight's reading"

# 11. local runs with a kit directory: has sbx built it? Stubs of sbx's kit
#     registry answer every request with one mode (200 with the image digest,
#     200 without it, 404, 500, or no answer at all) and log what they got.
cat > "${D}/registry-stub.py" << 'EOF'
import http.server, sys, time
LOG, MODE = sys.argv[1], sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def answer(self):
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (self.command, self.path))
        if MODE == "stall":
            time.sleep(120)
            return
        if MODE.startswith("slow-"):
            time.sleep(25)
        code = int(MODE.split("-")[-1] if MODE.startswith("slow-") else MODE.split("-")[0])
        self.send_response(code)
        if code == 200 and MODE != "200-nodigest":
            self.send_header("Docker-Content-Digest", "sha256:" + "0123456789abcdef" * 4)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_HEAD = answer
    do_GET = answer

s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
EOF
start_stub()
{
	# $1 = log file, $2 = mode; the port goes to $1.port
	: > "$1"
	python3 "${D}/registry-stub.py" "$1" "$2" > "$1.port" &
	echo $! >> "${D}/stub.pids"
	for _ in $(seq 1 50); do [ -s "$1.port" ] && break; sleep 0.1; done
}
stop_stubs()
{
	if [ -f "${D}/stub.pids" ]; then
		while read -r p; do kill "${p}" 2> /dev/null; done < "${D}/stub.pids"
		rm -f "${D}/stub.pids"
	fi
}
run_local()
{
	# $1 = scenario, then arguments for e2e.sh. The scripted kit builder status
	# names ${REGISTRY} as "${REG_STATE}" (default "— reachable"); E2E_ENV adds
	# environment; WITH_AGENT=1 leaves out --skip-agent. A dry run, which
	# creates nothing.
	local sc=$1 t0 agent=(--skip-agent)
	shift
	[ "${WITH_AGENT:-}" = "1" ] && agent=()
	mkdir -p "${D}/${sc}"
	t0=$(date +%s)
	env "${E2E_ENV[@]}" SCRIPTED_STATE="${D}/${sc}" SCRIPTED_MODE="${sc}" SCRIPTED_REGISTRY="${REGISTRY}" \
		SCRIPTED_REGISTRY_STATE="${REG_STATE:-— reachable}" SCRIPTED_SBX_VERSION="${SBXV:-0.47.0}" PATH="${D}/bin:${PATH}" \
		"${E2E}" --local --dry-run "${agent[@]}" --name "test5-${sc}" --out "${OUT}/${sc}" "$@" < /dev/null > "${OUT}/${sc}.log" 2>&1
	RC=$?
	T=$(( $(date +%s) - t0 ))
	S=${OUT}/${sc}/summary.json
	[ -f "${S}" ] || fail "${sc}: no summary.json: $(tail -3 "${OUT}/${sc}.log")"
	PF=$(jq -r .layers.preflight.detail "${S}")
	# the codes of a BLOCKED preflight (each blocker starts with one: NEEDS_KVM: ..., KIT_NOT_BUILT: ...)
	CODES=$(jq -r 'select(.layers.preflight.status == "BLOCKED") | .layers.preflight.detail' "${S}" \
		| grep -oE '(^|; )[A-Z][A-Z_]{2,}(:| )' | sed -E 's/^; //; s/[: ]$//' | sort -u | tr '\n' ' ')
	grep -qE '(^| )create |kit inspect' "${D}/${sc}/calls.log" && fail "${sc}: sbx create or sbx kit inspect was called: $(grep -E '(^| )create |kit inspect' "${D}/${sc}/calls.log")"
}
# this host's own blockers (no /dev/kvm here, say), then the one each case expects
HOSTCODES=""
[ -e /dev/kvm ] || HOSTCODES="NEEDS_KVM "
expect_codes()
{
	# $1 = scenario, $2 = the expected codes besides this host's ("" for none)
	local want
	want=$(echo "${HOSTCODES} $2" | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ')
	[ "${CODES}" = "${want}" ] || fail "$1: preflight blockers '${CODES}', expected '${want}': ${PF}"
	if [ -n "${want}" ]; then
		[ "$(jq -r .layers.preflight.status "${S}")" = "BLOCKED" ] && [ "${RC}" -eq 2 ] || fail "$1: preflight $(jq -r .layers.preflight.status "${S}"), exit ${RC}; expected BLOCKED, 2"
	else
		[ "$(jq -r .overall "${S}")" = "DRY_RUN" ] && [ "${RC}" -eq 0 ] || fail "$1: overall $(jq -r .overall "${S}"), exit ${RC}; expected DRY_RUN, 0"
	fi
}
unknown_because()
{
	# $1 = scenario, $2 = text the KIT_BUILD_UNKNOWN blocker must hold
	expect_codes "$1" KIT_BUILD_UNKNOWN
	echo "${PF}" | grep -q "KIT_BUILD_UNKNOWN: could not tell whether sbx has built " || fail "$1: not failed closed with KIT_BUILD_UNKNOWN: ${PF}"
	echo "${PF}" | grep -qF -- "$2" || fail "$1: the KIT_BUILD_UNKNOWN blocker does not say '$2': ${PF}"
}
E2E_ENV=()
REG_STATE=""
SBXV=0.47.0
REF=""

# not built: 404
start_stub "${D}/r-404.log" 404
REGISTRY=127.0.0.1:$(cat "${D}/r-404.log.port")
run_local local-not-built
expect_codes local-not-built KIT_NOT_BUILT
echo "${PF}" | grep -q "KIT_NOT_BUILT: sbx has not built " || fail "local-not-built: no KIT_NOT_BUILT blocker: ${PF}"
for c in 'stops every running sandbox' 'balanced preset until the last one' 'sbx policy reset --force; sbx policy init balanced' "/to/sandbox/render.sh" \
	'sbx create --name do-agent-aws-prebuild --cpus 4 --memory 8g --skills off ' 'sbx rm --force do-agent-aws-prebuild' 'sbx policy init deny-all' 'outlasts create'; do
	echo "${PF}" | grep -qF -- "${c}" || fail "local-not-built: the KIT_NOT_BUILT message lacks '${c}': ${PF}"
done
[ "${T}" -le 60 ] || fail "local-not-built: the preflight took ${T} s"
REF=$(python3 "${D}/clone/to/sandbox/test/kit-key.py" "${D}/clone/to/sandbox/app/do-agent-aws-sandbox" do-agent-aws-sandbox) || fail "local-not-built: kit-key.py failed on the rendered kit"
[ "$(cat "${D}/r-404.log")" = "HEAD /v2/sbx-kit-src/manifests/${REF#*:}" ] \
	|| fail "local-not-built: the registry was not asked once for ${REF} with HEAD: $(tr '\n' ' ' < "${D}/r-404.log")"
T_NB=${T}

# a proxy variable or ~/.curlrc must not redirect the request: they point at a
# stub that would answer "built"; the named registry answers 404
start_stub "${D}/p-200.log" 200
P200=127.0.0.1:$(cat "${D}/p-200.log.port")
: > "${D}/r-404.log"
E2E_ENV=(-u no_proxy -u NO_PROXY "http_proxy=http://${P200}" "ALL_PROXY=http://${P200}")
run_local local-proxy
expect_codes local-proxy KIT_NOT_BUILT
[ ! -s "${D}/p-200.log" ] || fail "local-proxy: the request went through the proxy: $(cat "${D}/p-200.log")"
[ "$(wc -l < "${D}/r-404.log")" -eq 1 ] || fail "local-proxy: the named registry was not asked"
mkdir -p "${D}/home-curlrc"
printf 'connect-to = "::%s"\n' "${P200}" > "${D}/home-curlrc/.curlrc"
: > "${D}/r-404.log"
E2E_ENV=("HOME=${D}/home-curlrc")
run_local local-curlrc
expect_codes local-curlrc KIT_NOT_BUILT
[ ! -s "${D}/p-200.log" ] || fail "local-curlrc: ~/.curlrc redirected the request: $(cat "${D}/p-200.log")"
[ "$(wc -l < "${D}/r-404.log")" -eq 1 ] || fail "local-curlrc: the named registry was not asked"
E2E_ENV=()

# built: 200 with the digest
start_stub "${D}/r-200.log" 200
REGISTRY=127.0.0.1:$(cat "${D}/r-200.log.port")
run_local local-built
echo "${PF}" | grep -q 'KIT_' && fail "local-built: a KIT_ blocker with the build in the registry: ${PF}"
expect_codes local-built ""
grep -qF "kit build: sbx's kit registry holds ${REF}, so create reuses it" "${OUT}/local-built.log" || fail "local-built: the run does not report the build: $(tail -3 "${OUT}/local-built.log")"
if [ -e /dev/kvm ]; then
	echo "${PF}" | grep -qF "(built: ${REF})" || fail "local-built: the preflight detail does not name the build: ${PF}"
fi

# the registry is reported, but not as reachable, or not on 127.0.0.1: not asked
REG_STATE="— unreachable"
: > "${D}/r-200.log"
run_local local-unreachable
unknown_because local-unreachable "does not report the kit registry reachable"
[ ! -s "${D}/r-200.log" ] || fail "local-unreachable: a registry reported unreachable was asked"
REG_STATE=""
REGISTRY=localhost:$(cat "${D}/r-200.log.port")
run_local local-not-loopback
unknown_because local-not-loopback "not 127.0.0.1:<port>"
[ ! -s "${D}/r-200.log" ] || fail "local-not-loopback: a registry off 127.0.0.1 was asked"

# 200 without the digest header, 500, a closed port, no answer at all
start_stub "${D}/r-nodigest.log" 200-nodigest
REGISTRY=127.0.0.1:$(cat "${D}/r-nodigest.log.port")
run_local local-no-digest
unknown_because local-no-digest "without a Docker-Content-Digest: sha256: header"
start_stub "${D}/r-500.log" 500
REGISTRY=127.0.0.1:$(cat "${D}/r-500.log.port")
run_local local-registry-error
unknown_because local-registry-error "answered '500'"
[ "$(wc -l < "${D}/r-500.log")" -eq 1 ] || fail "local-registry-error: the registry was not asked once"
REGISTRY=127.0.0.1:$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
run_local local-closed-port
unknown_because local-closed-port "answered '000'"
# a registry that answers only after 25 s, as sbx 0.47.0's does while it copies a new build in
start_stub "${D}/r-slow.log" slow-200
REGISTRY=127.0.0.1:$(cat "${D}/r-slow.log.port")
run_local local-slow-populate
echo "${PF}" | grep -q 'KIT_' && fail "local-slow-populate: a KIT_ blocker for a registry that answers after 25 s: ${PF}"
expect_codes local-slow-populate ""
grep -qF "kit build: sbx's kit registry holds ${REF}, so create reuses it" "${OUT}/local-slow-populate.log" || fail "local-slow-populate: the run does not report the build: $(tail -3 "${OUT}/local-slow-populate.log")"
[ "$(wc -l < "${D}/r-slow.log")" -eq 1 ] || fail "local-slow-populate: the registry was not asked exactly once: $(tr '\n' ' ' < "${D}/r-slow.log")"
T_SLOW=${T}
start_stub "${D}/r-stall.log" stall
REGISTRY=127.0.0.1:$(cat "${D}/r-stall.log.port")
E2E_ENV=("E2E_T_KIT_REGISTRY=20")
run_local local-stall
E2E_ENV=()
unknown_because local-stall "did not answer for ${REF} within 20 s"
echo "${PF}" | grep -qF "E2E_T_KIT_REGISTRY=<seconds>" || fail "local-stall: the blocker does not name E2E_T_KIT_REGISTRY: ${PF}"
[ "${T}" -le 45 ] || fail "local-stall: a registry that never answers held the preflight ${T} s"
T_STALL=${T}

# no registry named; sbx not exactly v0.47.0; a kit directory kit-key.py refuses
REGISTRY=127.0.0.1:$(cat "${D}/r-200.log.port")
run_local local-no-registry
unknown_because local-no-registry "names no kit registry"
for v in 0.48.0 0.47.0-rc.1; do
	SBXV=${v}
	run_local "local-sbx-${v}"
	unknown_because "local-sbx-${v}" "this sbx is 'v${v}'"
	echo "${PF}" | grep -qF "Run with sbx 0.47.0" || fail "local-sbx-${v}: the blocker does not name the version to run with: ${PF}"
	echo "${PF}" | grep -q "if the build may be missing" && fail "local-sbx-${v}: a version mismatch is reported as a build question: ${PF}"
done
SBXV=0.47.0
rm -rf "${D}/kit-copy"
mkdir -p "${D}/kit-copy"
cp -a "${D}/clone/to/sandbox/app/do-agent-aws-sandbox" "${D}/kit-copy/other-name"
: > "${D}/r-200.log"
run_local local-kit-renamed --kit "${D}/kit-copy/other-name"
unknown_because local-kit-renamed "is not named do-agent-aws-sandbox"
echo "${PF}" | grep -qF "Pass a kit directory named do-agent-aws-sandbox" || fail "local-kit-renamed: the blocker does not say what kit-key.py needs: ${PF}"
echo "${PF}" | grep -q "if the build may be missing" && fail "local-kit-renamed: a refused kit directory is reported as a build question: ${PF}"
[ ! -s "${D}/r-200.log" ] || fail "local-kit-renamed: the registry was asked"
stop_stubs
echo "ok 11 - a local run with a kit directory sbx has not built stops in preflight in ${T_NB} s with KIT_NOT_BUILT and the pre-build commands with their warning (one HEAD for kit-key.py's reference, straight to the named registry despite http_proxy, ALL_PROXY and ~/.curlrc; no create, no kit inspect); with the build in the registry, no KIT_ blocker; a registry reported unreachable or off 127.0.0.1 is not asked; 200 without the digest, 500, a closed port, no answer within E2E_T_KIT_REGISTRY=20 (${T_STALL} s), no registry, sbx 0.48.0 or 0.47.0-rc.1, and a kit directory kit-key.py refuses fail closed (KIT_BUILD_UNKNOWN, naming the cause); a registry that answers after 25 s is waited for (${T_SLOW} s, no KIT_ blocker)"

# 12. the policy layer's model endpoint and refused hosts; bedrock-refused also
#     has a bedrock secret scoped to its sandbox, which teardown must remove
for sc in anthropic-open bedrock-refused; do
	SECRET=""
	[ "${sc}" = "bedrock-refused" ] && SECRET=bedrock
	SCRIPTED_SECRET_SANDBOX=${SECRET} run_e2e "${sc}"
	wait "${PID}"
	RC=$?
	S=${OUT}/${sc}/summary.json
	[ "$(jq -r .layers.policy.status "${S}")" = "FAIL" ] || fail "${sc}: the policy layer did not fail: $(jq -c .layers.policy "${S}")"
	for l in platform harness example agent; do
		[ "$(jq -r ".layers.${l}.status" "${S}")" = "NOT_RUN" ] || fail "${sc}: ${l} is $(jq -r ".layers.${l}.status" "${S}"), expected NOT_RUN"
	done
	grep -qE 'claude -p|/test\*\.sh|run-deterministic' "${D}/${sc}/calls.log" && fail "${sc}: a live call was issued after the policy layer failed"
	[ "$(jq -r .layers.teardown.status "${S}")" = "PASS" ] && [ "${RC}" -eq 1 ] || fail "${sc}: teardown $(jq -r .layers.teardown.status "${S}"), exit ${RC}"
done
P12=$(jq -r .layers.policy.detail "${OUT}/anthropic-open/summary.json")
echo "${P12}" | grep -qF "sbx policy log does not list example.com, registry.npmjs.org and api.anthropic.com as blocked" \
	|| fail "anthropic-open: the policy detail does not name the Anthropic API missing from the policy log: ${P12}"
P12=$(jq -r .layers.policy.detail "${OUT}/bedrock-refused/summary.json")
for c in "the Bedrock runtime endpoint did not answer from AWS through the proxy ('403 no-aws-header'" \
	"Node did not reach the Bedrock runtime endpoint through the proxy (403 no-aws-header)"; do
	echo "${P12}" | grep -qF -- "${c}" || fail "bedrock-refused: the policy detail lacks '${c}': ${P12}"
done
# the sandbox-scoped secret: removed by teardown, and only that one; none without one
[ "$(jq -r .layers.secret.status "${OUT}/bedrock-refused/summary.json")" = "PASS" ] \
	|| fail "bedrock-refused: the secret layer is $(jq -c .layers.secret "${OUT}/bedrock-refused/summary.json"), expected PASS"
[ "$(grep -c "^--cloud secret rm " "${D}/bedrock-refused/calls.log")" -eq 1 ] && grep -qxF -- "--cloud secret rm bedrock --sandbox test5-bedrock-refused -f" "${D}/bedrock-refused/calls.log" \
	|| fail "bedrock-refused: teardown did not remove exactly the sandbox-scoped bedrock secret: $(grep " secret " "${D}/bedrock-refused/calls.log" | tr '\n' ';')"
grep -q " secret rm " "${D}/anthropic-open/calls.log" && fail "anthropic-open: a secret was removed although none was scoped to the sandbox"
[ "$(jq -r '.layers.secret // "none"' "${OUT}/anthropic-open/summary.json")" = "none" ] || fail "anthropic-open: a secret layer was recorded"
echo "ok 12 - the policy layer fails, nothing live runs and the run exits 1 when the Anthropic API answers and is not logged as blocked, and when the Bedrock runtime endpoint is answered without AWS's x-amzn-RequestId header (curl and Node), each naming the host; teardown removes the sandbox-scoped bedrock secret (secret layer PASS) and no other"

# 13. the model credential, in local dry runs (the build is in a stub registry)
start_stub "${D}/r-cred.log" 200
REGISTRY=127.0.0.1:$(cat "${D}/r-cred.log.port")
REG_STATE=""
SBXV=0.47.0
CH=${D}/home-cred
mkdir -p "${CH}/bedrock/.config/sbx" "${CH}/anthropic/.config/sbx"
printf 'bindings:\n  bedrock:\n    apiKey:\n      domains: [bedrock-runtime.us-east-1.amazonaws.com]\n' > "${CH}/bedrock/.config/sbx/credentials.yaml"
printf 'bindings:\n  anthropic:\n    apiKey:\n      domains: [api.anthropic.com]\n' > "${CH}/anthropic/.config/sbx/credentials.yaml"
cred_case()
{
	# $1 = scenario, $2 = HOME, $3 = the expected summary.json credential object
	# (jq), $4 = the plan's agent line, then VAR=value settings of the scripted sbx
	local sc=$1 home=$2 want=$3 line=$4
	shift 4
	E2E_ENV=("HOME=${home}" "$@")
	WITH_AGENT=1 run_local "${sc}"
	E2E_ENV=()
	expect_codes "${sc}" ""
	jq -e --argjson w "${want}" '.credential == $w' "${S}" > /dev/null \
		|| fail "${sc}: summary.json credential $(jq -c .credential "${S}"), expected ${want}"
	grep -qF -- "${line}" "${OUT}/${sc}/plan.txt" || fail "${sc}: the plan lacks '${line}': $(cat "${OUT}/${sc}/plan.txt")"
}
SETUP="--command '${CH}/bedrock/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1' --refresh 55m"
cred_case cred-sandbox "${CH}/bedrock" \
	'{"model_service":"bedrock","model_secret":"present","secret_scope":"sandbox","binding":"present","model_usable":"present"}' \
	"exec timeout 900 claude -p" SCRIPTED_SECRET_SANDBOX=bedrock
grep -qF "sbx secret rm bedrock --sandbox test5-cred-sandbox -f ; sbx secret ls --sandbox test5-cred-sandbox --service bedrock -q" "${OUT}/cred-sandbox/plan.txt" \
	|| fail "cred-sandbox: the plan does not remove the sandbox-scoped bedrock secret: $(cat "${OUT}/cred-sandbox/plan.txt")"
grep -qF "credential: bedrock secret present (scope sandbox), binding present; agent layer RUN" "${OUT}/cred-sandbox/e2e.log" \
	|| fail "cred-sandbox: e2e.log does not report the credential: $(grep credential "${OUT}/cred-sandbox/e2e.log")"
cred_case cred-global-only "${CH}/bedrock" \
	'{"model_service":"bedrock","model_secret":"global only, not used","secret_scope":"global","binding":"present","model_usable":"absent"}' \
	"# agent layer NOT_RUN: only a global bedrock secret is stored, and this kit does not use one: the proxy sends the stored value as 'Bearer <value>' to bedrock-runtime.us-east-1.amazonaws.com" \
	SCRIPTED_SECRET_GLOBAL=bedrock
grep -qF "store a key for this sandbox: sbx secret set bedrock --sandbox test5-cred-global-only ${SETUP}" "${OUT}/cred-global-only/plan.txt" \
	|| fail "cred-global-only: the plan does not give the setup command: $(cat "${OUT}/cred-global-only/plan.txt")"
cred_case cred-none "${CH}/bedrock" \
	'{"model_service":"bedrock","model_secret":"absent","secret_scope":"none","binding":"present","model_usable":"absent"}' \
	"# agent layer NOT_RUN: no bedrock secret for sandbox test5-cred-none in the sbx secret store (absent); store one: sbx secret set bedrock --sandbox test5-cred-none ${SETUP}"
cred_case cred-anthropic-binding "${CH}/anthropic" \
	'{"model_service":"bedrock","model_secret":"present","secret_scope":"sandbox","binding":"absent","model_usable":"absent"}' \
	"# agent layer NOT_RUN: no approved binding for bedrock -> bedrock-runtime.us-east-1.amazonaws.com in ${CH}/anthropic/.config/sbx/credentials.yaml" \
	SCRIPTED_SECRET_SANDBOX=bedrock
# the sandbox's own lookup fails while a global secret exists: reported as unknown,
# not read as "global only, not used" (the global lookup is not consulted)
cred_case cred-ls-fails "${CH}/bedrock" \
	'{"model_service":"bedrock","model_secret":"unknown (secret ls --sandbox failed)","secret_scope":"none","binding":"present","model_usable":"absent"}' \
	"# agent layer NOT_RUN: whether a bedrock secret is stored for sandbox test5-cred-ls-fails is unknown (secret ls --sandbox failed) (secret-sandbox.err, secret-global.err), so the agent layer does not run; if none is stored: sbx secret set bedrock --sandbox test5-cred-ls-fails ${SETUP}" \
	SCRIPTED_SECRET_LS_FAIL=1 SCRIPTED_SECRET_GLOBAL=bedrock
grep -qF "only a global bedrock secret is stored" "${OUT}/cred-ls-fails/plan.txt" && fail "cred-ls-fails: a failed lookup was reported as a global secret: $(cat "${OUT}/cred-ls-fails/plan.txt")"
grep -q -- "secret ls -g" "${D}/cred-ls-fails/calls.log" && fail "cred-ls-fails: the global secret was looked up after the sandbox lookup failed"
for sc in cred-global-only cred-none cred-ls-fails; do
	grep -q "secret rm" "${OUT}/${sc}/plan.txt" && fail "${sc}: the plan removes a secret the run did not scope to its sandbox"
done
stop_stubs
echo "ok 13 - local dry runs: a sandbox-scoped bedrock secret and a bedrock binding plan the agent layer and the secret's removal (summary.json: model_service, model_secret, secret_scope, binding, model_usable); a global bedrock secret alone, no secret, and an anthropic binding only leave the agent NOT_RUN with the reason and the exact sbx secret set ... --command '<helper> bedrock us-east-1' --refresh 55m line, and remove nothing they did not scope; a failing secret ls --sandbox is reported as unknown, not as a global or absent secret"

# 14. bedrock-token.sh against stubs of botocore and aws-bedrock-token-generator,
#     installed in a real venv at the helper's default path under a test HOME
H=${D}/clone/to/sandbox/bedrock-token.sh
TH=${D}/home-tok
V=${TH}/.local/share/sbx-bedrock/venv
python3 -m venv --without-pip "${V}" > "${D}/venv.log" 2>&1 || fail "bedrock-token: python3 -m venv --without-pip failed: $(tail -2 "${D}/venv.log")"
SP=$("${V}/bin/python" -c 'import site; print(site.getsitepackages()[0])')
mkdir -p "${SP}/botocore" "${SP}/aws_bedrock_token_generator" "${D}/poison/aws_bedrock_token_generator"
: > "${SP}/botocore/__init__.py"
cat > "${SP}/botocore/session.py" << 'EOF'
# stub: the named profile's credentials; profile "missing" has none
class Session:
    def __init__(self, profile=None):
        self.profile = profile

    def get_credentials(self):
        return None if self.profile == "missing" else ("stub-credentials", self.profile)
EOF
cat > "${SP}/aws_bedrock_token_generator/__init__.py" << 'EOF'
# stub: a "key" that encodes the profile and region it was made for; profile
# "badtoken" makes the generator return something that is not a key
import base64

class BedrockTokenGenerator:
    def get_token(self, credentials, region):
        if credentials[1] == "badtoken":
            return "STUB-VALUE-THAT-IS-NOT-A-KEY"
        return "bedrock" + "-api-key-" + base64.b64encode(("%s %s" % (credentials[1], region)).encode()).decode()
EOF
printf 'raise SystemExit("POISONED generator loaded from %%s" %% __file__)\n' > "${D}/poison/aws_bedrock_token_generator/__init__.py"
tok()
{
	# $1 = case, $2 = working directory, then the command; stdout and stderr to
	# files, exit code in TOK_RC
	local c=$1 wd=$2
	shift 2
	( cd "${wd}" && "$@" ) > "${D}/tok-${c}.out" 2> "${D}/tok-${c}.err" < /dev/null
	TOK_RC=$?
}
# the stub's key for profile test5-profile, region us-east-1
printf 'bedrock-api-key-%s\n' "$(printf '%s' 'test5-profile us-east-1' | base64 -w0)" > "${D}/tok-want"
key_only()
{
	# $1 = case: exit 0, stdout exactly the stub's key line, stderr empty
	[ "${TOK_RC}" -eq 0 ] && cmp -s "${D}/tok-want" "${D}/tok-$1.out" && [ ! -s "${D}/tok-$1.err" ] \
		|| fail "bedrock-token $1: exit ${TOK_RC}, stdout '$(head -c 200 "${D}/tok-$1.out")', stderr '$(head -c 300 "${D}/tok-$1.err")'"
}
refused()
{
	# $1 = case, $2 = expected exit (or "nonzero"), $3 = text stderr must hold: nothing on stdout
	if [ "$2" = "nonzero" ]; then [ "${TOK_RC}" -ne 0 ]; else [ "${TOK_RC}" -eq "$2" ]; fi \
		|| fail "bedrock-token $1: exit ${TOK_RC}, expected $2"
	[ ! -s "${D}/tok-$1.out" ] || fail "bedrock-token $1: printed on stdout: $(head -c 200 "${D}/tok-$1.out")"
	grep -qF -- "$3" "${D}/tok-$1.err" || fail "bedrock-token $1: stderr lacks '$3': $(head -c 300 "${D}/tok-$1.err")"
}
tok override "${D}" env -u HOME SBX_BEDROCK_VENV="${V}" "${H}" test5-profile us-east-1
key_only override
tok default "${D}" env -u SBX_BEDROCK_VENV HOME="${TH}" "${H}" test5-profile us-east-1
key_only default
tok usage "${D}" env HOME="${TH}" "${H}" test5-profile
refused usage 2 "usage: bedrock-token.sh PROFILE REGION"
tok no-venv "${D}" env SBX_BEDROCK_VENV="${D}/no-such-venv" "${H}" test5-profile us-east-1
refused no-venv 1 "no Python at ${D}/no-such-venv/bin/python"
tok no-credentials "${D}" env HOME="${TH}" "${H}" missing us-east-1
refused no-credentials nonzero "no AWS credentials for profile missing"
tok bad-key "${D}" env HOME="${TH}" "${H}" badtoken us-east-1
refused bad-key nonzero "the generator returned no Bedrock API key"
grep -q "STUB-VALUE-THAT-IS-NOT-A-KEY" "${D}/tok-bad-key.err" && fail "bedrock-token bad-key: the generator's value was echoed on stderr"
# isolated mode: neither PYTHONPATH nor the working directory (sbx runs the
# command from a temporary directory) can put another generator first
tok iso-cwd "${D}/poison" env HOME="${TH}" "${H}" test5-profile us-east-1
key_only iso-cwd
tok iso-path "${D}" env HOME="${TH}" PYTHONPATH="${D}/poison" "${H}" test5-profile us-east-1
key_only iso-path
sed 's/^exec "\${PY}" -I -c /exec "${PY}" -c /' "${H}" > "${D}/bedrock-token-no-I.sh"
cmp -s "${H}" "${D}/bedrock-token-no-I.sh" && fail "bedrock-token: could not plant the control without -I"
tok ctl-cwd "${D}/poison" env HOME="${TH}" bash "${D}/bedrock-token-no-I.sh" test5-profile us-east-1
refused ctl-cwd nonzero "POISONED generator loaded from"
tok ctl-path "${D}" env HOME="${TH}" PYTHONPATH="${D}/poison" bash "${D}/bedrock-token-no-I.sh" test5-profile us-east-1
refused ctl-path nonzero "POISONED generator loaded from"
echo "ok 14 - bedrock-token.sh prints only the key, one line, from SBX_BEDROCK_VENV or the default venv under HOME, for the profile and region given; a usage error, a missing venv, a profile without credentials and a generator returning no key exit non-zero with nothing on stdout; PYTHONPATH and the working directory cannot substitute the generator (planted controls without -I: both do)"

# 15. AWS_BEARER_TOKEN_BEDROCK in the sandbox, as the platform layer judges it.
#     The scripted sbx passes provenance and policy, and runs e2e.sh's own platform
#     probe script for its bearer_* lines with the value a scenario plants.
mkdir -p "${D}/stubs"
printf '#!/bin/bash\ncase "${1:-}" in version) echo 29.8.2 ;; compose) echo 5.6.0 ;; esac\nexit 0\n' > "${D}/stubs/docker"
printf '#!/bin/bash\necho "2.1.293 (Claude Code)"\n' > "${D}/stubs/claude"
chmod +x "${D}/stubs/docker" "${D}/stubs/claude"
H15=${D}/home-platform
mkdir -p "${H15}/.config/sbx"
printf 'bindings:\n  bedrock:\n    apiKey:\n      domains: [bedrock-runtime.us-east-1.amazonaws.com]\n' > "${H15}/.config/sbx/credentials.yaml"
# a real-looking short-term key, built at runtime, never a literal (test1 check 6)
python3 -c 'import random, string; r = random.Random(15); print("bedrock" + "-api-key-" + "".join(r.choice(string.ascii_letters + string.digits + "+/") for _ in range(1200)) + "==")' > "${D}/bearer-key"
KEY_LEN=$(( $(wc -c < "${D}/bearer-key") - 1 ))
# and a real-looking long-term key (ABSK + base64 of "BedrockAPIKey-...", AWS's pattern), built the same way
python3 -c 'import base64, random, string; r = random.Random(151); print("AB" + "SK" + base64.b64encode(("Bedrock" + "APIKey-" + "".join(r.choice(string.ascii_letters + string.digits) for _ in range(150))).encode()).decode())' > "${D}/bearer-longkey"
LONGKEY_LEN=$(( $(wc -c < "${D}/bearer-longkey") - 1 ))
printf 'proxy-managed\n' > "${D}/bearer-sentinel"
printf 'not-the-sentinel\n' > "${D}/bearer-other"
platform_case()
{
	# $1 = scenario, $2 = file with the in-sandbox value ("" leaves it unset), $3 = cred
	# for a configured model credential (a sandbox-scoped secret and the binding)
	local sc=$1 secret=""
	[ "$3" = "cred" ] && secret=bedrock
	HOME=${H15} SCRIPTED_REPO=${D}/clone SCRIPTED_STUBS=${D}/stubs SCRIPTED_BEARER_FILE=$2 SCRIPTED_SECRET_SANDBOX=${secret} run_e2e "${sc}"
	wait "${PID}"
	RC=$?
	S=${OUT}/${sc}/summary.json
	[ -f "${S}" ] || fail "${sc}: no summary.json: $(tail -3 "${OUT}/${sc}.log")"
	[ "$(jq -r .layers.provenance.status "${S}")" = "PASS" ] && [ "$(jq -r .layers.policy.status "${S}")" = "PASS" ] \
		|| fail "${sc}: the scripted provenance and policy layers did not pass, so this case proves nothing: $(jq -c '[.layers.provenance, .layers.policy]' "${S}")"
	want=absent
	[ "$3" = "cred" ] && want=present
	[ "$(jq -r .credential.model_usable "${S}")" = "${want}" ] || fail "${sc}: model_usable is $(jq -r .credential.model_usable "${S}"), expected ${want}"
	PLAT=$(jq -r .layers.platform.status "${S}")
	PDET=$(jq -r .layers.platform.detail "${S}")
}
gated()
{
	# $1 = scenario whose platform layer failed on the model key: nothing live ran after it
	local l
	for l in harness example agent; do
		[ "$(jq -r ".layers.${l}.status" "${S}")" = "NOT_RUN" ] && jq -r ".layers.${l}.detail" "${S}" | grep -qF "credential isolation unverified" \
			|| fail "$1: ${l} is $(jq -c ".layers.${l}" "${S}") after the platform layer failed on the model key, expected NOT_RUN (credential isolation unverified)"
	done
	grep -qE 'claude -p|/test\*\.sh|run-deterministic|compose-demo' "${D}/$1/calls.log" && fail "$1: a live call was issued after the platform layer failed on the model key: $(grep -E 'claude -p|/test\*\.sh|run-deterministic|compose-demo' "${D}/$1/calls.log" | head -2)"
	[ "$(jq -r .layers.teardown.status "${S}")" = "PASS" ] && [ "${RC}" -eq 1 ] || fail "$1: teardown $(jq -r .layers.teardown.status "${S}"), exit ${RC}; expected PASS and 1"
}
platform_case platform-sentinel "${D}/bearer-sentinel" cred
[ "${PLAT}" = "PASS" ] || fail "platform-sentinel: the platform layer is ${PLAT} with the sentinel and a configured credential: ${PDET}"
# the control for gated(): with the sentinel the run goes on to the harness
grep -q '/test\*\.sh' "${D}/platform-sentinel/calls.log" || fail "platform-sentinel: the harness was not run after a passing platform layer, so the gate checks below prove nothing"
echo "${PDET}" | grep -qF "bearer_len=13 bearer_sentinel=yes bearer_key_prefix=no" || fail "platform-sentinel: the detail does not record the sentinel's facts: ${PDET}"
platform_case platform-key "${D}/bearer-key" cred
[ "${PLAT}" = "FAIL" ] || fail "platform-key: a Bedrock API key in the sandbox gave platform ${PLAT}: ${PDET}"
echo "${PDET}" | grep -qF "AWS_BEARER_TOKEN_BEDROCK in the sandbox starts like a Bedrock API key (bedrock-api-key-, a short-term key, or ABSK, a long-term one; length ${KEY_LEN})" || fail "platform-key: the detail does not name the key: ${PDET}"
gated platform-key
# the same with --keep: such a sandbox is removed all the same, its scoped secret first
E2E_ARGS=(--keep)
platform_case platform-key-keep "${D}/bearer-key" cred
E2E_ARGS=()
[ "${PLAT}" = "FAIL" ] || fail "platform-key-keep: a Bedrock API key in the sandbox gave platform ${PLAT}: ${PDET}"
gated platform-key-keep
[ "$(jq -r .layers.secret.status "${S}")" = "PASS" ] || fail "platform-key-keep: the secret layer is $(jq -c .layers.secret "${S}") under --keep after the platform layer failed on the model key, expected PASS"
grep -qxF -- "--cloud secret rm bedrock --sandbox test5-platform-key-keep -f" "${D}/platform-key-keep/calls.log" && grep -qxF -- "--cloud rm --force test5-platform-key-keep" "${D}/platform-key-keep/calls.log" \
	|| fail "platform-key-keep: the sandbox-scoped secret and the sandbox were not both removed: $(grep -E ' rm ' "${D}/platform-key-keep/calls.log" | tr '\n' ' ')"
grep -qF -- "--keep is overridden" "${OUT}/platform-key-keep.log" || fail "platform-key-keep: the run does not say that --keep was overridden"
platform_case platform-other "${D}/bearer-other" cred
[ "${PLAT}" = "FAIL" ] || fail "platform-other: a value other than the sentinel, with a configured credential, gave platform ${PLAT}: ${PDET}"
echo "${PDET}" | grep -qF "is not the proxy's sentinel proxy-managed (length 16)" || fail "platform-other: the detail does not say that the value is not the sentinel: ${PDET}"
gated platform-other
platform_case platform-nocred-key "${D}/bearer-key" none
[ "${PLAT}" = "FAIL" ] || fail "platform-nocred-key: a Bedrock API key in the sandbox, without a configured credential, gave platform ${PLAT}: ${PDET}"
echo "${PDET}" | grep -qF "starts like a Bedrock API key" || fail "platform-nocred-key: the detail does not name the key: ${PDET}"
gated platform-nocred-key
# a long-term key (ABSK...) is a key too, without a credential configured (with one, any value
# but the sentinel fails anyway)
platform_case platform-nocred-longkey "${D}/bearer-longkey" none
[ "${PLAT}" = "FAIL" ] || fail "platform-nocred-longkey: a long-term Bedrock API key in the sandbox, without a configured credential, gave platform ${PLAT}: ${PDET}"
echo "${PDET}" | grep -qF "starts like a Bedrock API key (bedrock-api-key-, a short-term key, or ABSK, a long-term one; length ${LONGKEY_LEN})" || fail "platform-nocred-longkey: the detail does not name the key: ${PDET}"
gated platform-nocred-longkey
grep -rqF -f "${D}/bearer-longkey" "${OUT}/platform-nocred-longkey" "${OUT}/platform-nocred-longkey.log" "${D}/platform-nocred-longkey/calls.log" && fail "platform-nocred-longkey: the planted long-term key was written to the run's output"
platform_case platform-nocred "" none
[ "${PLAT}" = "PASS" ] || fail "platform-nocred: without a credential and with the variable unset, the platform layer is ${PLAT}: ${PDET}"
echo "${PDET}" | grep -qF "bearer_len=0 bearer_sentinel=no bearer_key_prefix=no" || fail "platform-nocred: the detail does not record the unset variable: ${PDET}"
# a probe shell that starts with xtrace on (the control: it does trace) prints no part of the value
SCRIPTED_PROBE_XTRACE=1 platform_case platform-key-xtrace "${D}/bearer-key" cred
[ "${PLAT}" = "FAIL" ] || fail "platform-key-xtrace: a Bedrock API key in the sandbox gave platform ${PLAT}: ${PDET}"
gated platform-key-xtrace
grep -q '^+ ' "${OUT}/platform-key-xtrace/platform.txt" || fail "platform-key-xtrace: the probe ran without xtrace, so this case proves nothing"
# the planted key is recorded nowhere: not in the results, the run's output or sbx's argv
for sc in platform-key platform-key-keep platform-nocred-key platform-key-xtrace; do
	grep -rqF -f "${D}/bearer-key" "${OUT}/${sc}" "${OUT}/${sc}.log" "${D}/${sc}/calls.log"
	case $? in
	1) ;;
	0) fail "${sc}: the planted key was written to the run's output: $(grep -rlF -f "${D}/bearer-key" "${OUT}/${sc}" "${OUT}/${sc}.log" "${D}/${sc}/calls.log" | tr '\n' ' ')" ;;
	*) fail "${sc}: the search for the planted key failed" ;;
	esac
done
echo "ok 15 - the platform layer passes the sentinel with a configured credential and an unset variable without one, and fails a planted Bedrock API key (short-term with or without a credential, long-term without one) and any other value with a credential, naming the reason; after such a failure nothing live runs (harness, example and agent NOT_RUN, no harness, example or claude call, sandbox removed, exit 1; under --keep too, the sandbox-scoped secret and the sandbox removed), while a passing platform layer goes on to the harness; only the length is recorded, and the planted key appears nowhere in the run's output, also when the probe's shell traces"

# 16. --require-agent and the host model check, in local dry runs: a stub helper prints a
#     planted key-shaped value (built here, never valid) and a stub of the Bedrock runtime
#     on 127.0.0.1 answers each request with one mode and logs its path and a hash of the
#     bearer value it got (never the value)
cat > "${D}/bedrock-stub.py" << 'EOF'
import hashlib, http.server, json, sys, time
LOG, MODE = sys.argv[1], sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        a = self.headers.get("Authorization") or ""
        tok = a[len("Bearer "):] if a.startswith("Bearer ") else ""
        with open(LOG, "a") as f:
            f.write("%s %s auth=%s\n" % (self.command, self.path, hashlib.sha256(tok.encode()).hexdigest()[:16] if tok else "none"))
        if MODE == "hang":
            time.sleep(120)
            return
        if MODE == "200":
            code, body = 200, {"output": {"message": {"role": "assistant", "content": [{"text": "OK"}]}}, "stopReason": "end_turn"}
        else:
            code, body = 403, {"message": "User: arn:aws:sts::123456789012:assumed-role/test5-role/i-0test5 is not authorized to perform: bedrock:CallWithBearerToken on resource: *"}
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
EOF
start_bedrock_stub()
{
	# $1 = log file, $2 = mode (200, 403, or hang: no answer); the port goes to $1.port
	: > "$1"
	python3 "${D}/bedrock-stub.py" "$1" "$2" > "$1.port" &
	echo $! >> "${D}/stub.pids"
	for _ in $(seq 1 50); do [ -s "$1.port" ] && break; sleep 0.1; done
}
start_stub "${D}/r-model.log" 200
REGISTRY=127.0.0.1:$(cat "${D}/r-model.log.port")
REG_STATE=""
SBXV=0.47.0
start_bedrock_stub "${D}/b-200.log" 200
start_bedrock_stub "${D}/b-403.log" 403
B200=http://127.0.0.1:$(cat "${D}/b-200.log.port")
B403=http://127.0.0.1:$(cat "${D}/b-403.log.port")
python3 -c 'import random, string; r = random.Random(16); print("bedrock" + "-api-key-" + "".join(r.choice(string.ascii_letters + string.digits + "+/") for _ in range(400)) + "==")' > "${D}/model-key"
KH=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1]).read().strip().encode()).hexdigest()[:16])' "${D}/model-key")
printf '#!/bin/bash\ncat %s\n' "${D}/model-key" > "${D}/stub-helper-ok"
printf '#!/bin/bash\necho "no AWS credentials for profile $1" >&2\nexit 1\n' > "${D}/stub-helper-fails"
chmod +x "${D}/stub-helper-ok" "${D}/stub-helper-fails"
SONNET=$(sed -n 's/^.*ANTHROPIC_DEFAULT_SONNET_MODEL=\([^ ]*\).*$/\1/p' "${D}/clone/to/sandbox/template/sandbox.dockerfile" | head -1)
HAIKU=$(sed -n 's/^.*ANTHROPIC_DEFAULT_HAIKU_MODEL=\([^ ]*\).*$/\1/p' "${D}/clone/to/sandbox/template/sandbox.dockerfile" | head -1)
[ -n "${SONNET}" ] && [ -n "${HAIKU}" ] || fail "model: could not read the two model pins from template/sandbox.dockerfile"
model_case()
{
	# $1 = scenario, $2 = helper, $3 = endpoint, $4 = the expected blocker codes, then
	# e2e.sh arguments; a sandbox-scoped bedrock secret and the binding are configured
	local sc=$1 helper=$2 url=$3 codes=$4
	shift 4
	E2E_ENV=("HOME=${CH}/bedrock" "E2E_BEDROCK_HELPER=${helper}" "E2E_BEDROCK_URL=${url}" "SCRIPTED_SECRET_SANDBOX=${SECRET-bedrock}")
	# XT=1: e2e.sh runs traced, as under bash -x
	[ -n "${XT:-}" ] && E2E_ENV+=("SHELLOPTS=xtrace")
	WITH_AGENT=1 run_local "${sc}" "$@"
	E2E_ENV=()
	expect_codes "${sc}" "${codes}"
	# the planted key is recorded nowhere: not in the results, the run's output or sbx's argv
	grep -rqF -f "${D}/model-key" "${OUT}/${sc}" "${OUT}/${sc}.log" "${D}/${sc}/calls.log"
	case $? in
	1) ;;
	0) fail "${sc}: the planted key was written to the run's output: $(grep -rlF -f "${D}/model-key" "${OUT}/${sc}" "${OUT}/${sc}.log" "${D}/${sc}/calls.log" | tr '\n' ' ')" ;;
	*) fail "${sc}: the search for the planted key failed" ;;
	esac
}
# the model is reachable and permitted: --require-agent passes, the stub got one request per
# pinned model with the helper's key, and the dry run says what it did not verify
model_case model-ok "${D}/stub-helper-ok" "${B200}" "" --require-agent
[ "$(grep -c . "${D}/b-200.log")" = 2 ] || fail "model-ok: the stub got $(grep -c . "${D}/b-200.log") requests, expected 2: $(tr '\n' ' ' < "${D}/b-200.log")"
for m in "${SONNET}" "${HAIKU}"; do
	grep -qxF "POST /model/${m//:/%3A}/converse auth=${KH}" "${D}/b-200.log" || fail "model-ok: no request for ${m} with the helper's key: $(tr '\n' ' ' < "${D}/b-200.log")"
done
grep -qF "# host model check: ok" "${OUT}/model-ok/plan.txt" || fail "model-ok: the plan does not report the host model check: $(tail -3 "${OUT}/model-ok/plan.txt")"
grep -qF "Bedrock access from inside the sandbox is NOT verified" "${OUT}/model-ok/plan.txt" || fail "model-ok: the plan does not say that Bedrock access from inside the sandbox is not verified"
grep -qF "Bedrock access from inside the sandbox was NOT verified (no sandbox was created); host model check: ok" "${OUT}/model-ok/e2e.log" || fail "model-ok: e2e.log lacks the DRY_RUN statement"
if [ -z "${HOSTCODES}" ]; then
	grep -qF "DRY_RUN: the checks that create nothing passed." "${OUT}/model-ok/e2e.log" || fail "model-ok: e2e.log does not say the checks passed"
fi
[ "$(jq -r '.host_model_check.status + " " + (.require_agent | tostring)' "${S}")" = "ok true" ] || fail "model-ok: summary.json host_model_check/require_agent: $(jq -c '[.host_model_check, .require_agent]' "${S}")"
# the same run traced (SHELLOPTS=xtrace, as bash -x gives it; the control: the trace is
# there): the key is in no traced word either
XT=1 model_case model-ok-xtrace "${D}/stub-helper-ok" "${B200}" "" --require-agent
grep -q '^+ ' "${OUT}/model-ok-xtrace.log" || fail "model-ok-xtrace: e2e.sh ran without xtrace, so this case proves nothing"
[ "$(jq -r .host_model_check.status "${S}")" = "ok" ] || fail "model-ok-xtrace: the host model check did not pass, so the key was not handled: $(jq -c .host_model_check "${S}")"
# AWS refuses the key: blocked, naming the action, with the account and the ARN masked
model_case model-denied "${D}/stub-helper-ok" "${B403}" MODEL_NOT_VERIFIED --require-agent
echo "${PF}" | grep -qF "is not authorized to perform: bedrock:CallWithBearerToken" || fail "model-denied: the blocker does not give AWS's reason: ${PF}"
# (the run's staged repository copy, do-agent-aws/, holds this script and so the stub's message: not output)
grep -rqF --exclude-dir=do-agent-aws "123456789012" "${OUT}/model-denied" "${OUT}/model-denied.log" && fail "model-denied: the account number in AWS's message was not masked"
# the same refusal without --require-agent: no blocker (the run would go on), a warning
B403_BEFORE=$(grep -c . "${D}/b-403.log")
model_case model-denied-unrequired "${D}/stub-helper-ok" "${B403}" ""
grep -qF "WARNING: with the host model check failing" "${OUT}/model-denied-unrequired/e2e.log" || fail "model-denied-unrequired: no warning in e2e.log"
[ "$(( $(grep -c . "${D}/b-403.log") - B403_BEFORE ))" = 2 ] || fail "model-denied-unrequired: the check did not run without --require-agent"
# no helper, a helper that fails, an endpoint that is neither AWS nor 127.0.0.1: blocked, and
# no request is made with the key
N200=$(grep -c . "${D}/b-200.log")
model_case model-no-helper "${D}/no-such-helper" "${B200}" MODEL_NOT_VERIFIED --require-agent
echo "${PF}" | grep -qF "is missing or not executable" || fail "model-no-helper: the blocker does not name the missing helper: ${PF}"
model_case model-helper-fails "${D}/stub-helper-fails" "${B200}" MODEL_NOT_VERIFIED --require-agent
echo "${PF}" | grep -qF "exited 1 without a Bedrock API key" || fail "model-helper-fails: the blocker does not say the helper failed: ${PF}"
model_case model-endpoint "${D}/stub-helper-ok" "http://example.invalid:80" MODEL_NOT_VERIFIED --require-agent
echo "${PF}" | grep -qF "is neither the Bedrock runtime endpoint nor a stub on 127.0.0.1" || fail "model-endpoint: the blocker does not refuse the endpoint: ${PF}"
[ "$(grep -c . "${D}/b-200.log")" = "${N200}" ] || fail "model-*: a request was made after the helper or the endpoint was refused"
# no sandbox-scoped secret: --require-agent blocks with the reason the agent cannot run
SECRET="" model_case model-no-secret "${D}/stub-helper-ok" "${B200}" AGENT_NOT_RUNNABLE --require-agent
echo "${PF}" | grep -qF "AGENT_NOT_RUNNABLE: --require-agent, and the agent layer cannot run: no bedrock secret for sandbox test5-model-no-secret" || fail "model-no-secret: the blocker does not give the reason: ${PF}"
# an interrupt while the check holds the key (the stub never answers): its directory goes
# too. TMPDIR is the scenario's own, so whatever is left there is seen.
start_bedrock_stub "${D}/b-hang.log" hang
mkdir -p "${D}/model-int" "${D}/model-int-tmp"
env HOME="${CH}/bedrock" E2E_BEDROCK_HELPER="${D}/stub-helper-ok" E2E_BEDROCK_URL="http://127.0.0.1:$(cat "${D}/b-hang.log.port")" \
	SCRIPTED_SECRET_SANDBOX=bedrock TMPDIR="${D}/model-int-tmp" SCRIPTED_STATE="${D}/model-int" SCRIPTED_MODE=model-int \
	SCRIPTED_REGISTRY="${REGISTRY}" SCRIPTED_REGISTRY_STATE="— reachable" SCRIPTED_SBX_VERSION=0.47.0 PATH="${D}/bin:${PATH}" \
	python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.setsid()
os.execv(sys.argv[1], sys.argv[1:])' "${E2E}" --local --dry-run --require-agent --name test5-model-int --out "${OUT}/model-int" > "${OUT}/model-int.log" 2>&1 &
PID=$!
for _ in $(seq 1 150); do grep -q . "${D}/b-hang.log" 2> /dev/null && break; sleep 0.2; done
grep -q . "${D}/b-hang.log" || fail "model-int: the host model check never reached the stub: $(tail -3 "${OUT}/model-int.log")"
# the control: while the check waits, its directory holds the key
find "${D}/model-int-tmp" -name key | grep -q . || fail "model-int: no key file while the check runs, so this case proves nothing"
kill -INT -- "-${PID}"
wait "${PID}"
RC=$?
[ "${RC}" -ne 0 ] || fail "model-int: an interrupted run exited 0"
LEFT=$(find "${D}/model-int-tmp" \( -name key -o -name header \) | tr '\n' ' ')
[ -z "${LEFT}" ] || fail "model-int: the interrupt left the key's directory behind: ${LEFT}"
grep -rqF -f "${D}/model-key" "${OUT}/model-int" "${OUT}/model-int.log" && fail "model-int: the planted key was written to the run's output"
stop_stubs
echo "ok 16 - --require-agent: a configured model credential whose host model check passes (one request per pinned model, with the helper's key, to a stub of the Bedrock runtime) dry-runs clean and says that Bedrock access from inside the sandbox is not verified; AWS refusing the key (its reason given, the account masked), a missing or failing helper, an endpoint other than AWS or 127.0.0.1 and a missing sandbox secret block preflight, with no request made once the helper or endpoint is refused; without the flag the refusal is only a warning; the planted key appears nowhere in the run's output, also when e2e.sh runs traced (SHELLOPTS=xtrace); an interrupt during the check leaves no key file"

# 17. a host with no network policy yet: the blocker sends a kit that is not built yet through
#     the balanced pre-build before deny-all, not straight to deny-all
start_stub "${D}/r-uninit.log" 200
REGISTRY=127.0.0.1:$(cat "${D}/r-uninit.log.port")
REG_STATE=""
SBXV=0.47.0
E2E_ENV=("SCRIPTED_POLICY_UNINIT=1")
run_local local-policy-uninit
E2E_ENV=()
expect_codes local-policy-uninit NEEDS_POLICY_INIT
python3 - "${PF}" << 'EOF' || fail "local-policy-uninit: the NEEDS_POLICY_INIT blocker does not build an unbuilt kit under balanced before deny-all: ${PF}"
import sys
m = sys.argv[1]
i = m.find("NEEDS_POLICY_INIT:")
seg = m[i:] if i >= 0 else ""
b, c, d = seg.find("sbx policy init balanced"), seg.find("sbx create --name do-agent-aws-prebuild"), seg.find("sbx policy init deny-all")
sys.exit(0 if -1 < b < c < d else 1)
EOF
# its commands work from any directory: render.sh and the kit by their absolute paths, the
# descriptor's sizes
SB=${D}/clone/to/sandbox
for c in "${SB}/render.sh;" "--cpus 4 --memory 8g --skills off ${SB}/app/do-agent-aws-sandbox;"; do
	echo "${PF}" | grep -qF -- "${c}" || fail "local-policy-uninit: the NEEDS_POLICY_INIT commands do not say '${c}' (they must work from any directory): ${PF}"
done
stop_stubs
echo "ok 17 - a host whose network policy was never initialized is blocked with NEEDS_POLICY_INIT, whose commands build the kit under balanced before switching to deny-all, from any directory (absolute paths, the descriptor's sizes)"

echo "Sandbox test5 succeeded"
