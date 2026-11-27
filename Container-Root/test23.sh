#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the setup doctor (/agent/doctor.sh) and the harness-setup skill that walks its gaps (docs/manual/install.md "Setup
# doctor"). Fully OFFLINE: aws, kubectl, gh and the Slack doctor are stubs on PATH, the memory API and Headlamp a stub
# server on a test port; every path the doctor reads or writes is test-local, and nothing is written under /wd.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the doctor parses; --help prints its usage; an unknown argument or check exits 2 with one line, and so do a
#      --cluster outside the EKS name pattern and a --region that is not a region name; the states its header (and,
#      in a checkout, the README) names are the states a check returns
#   2. UNCONFIGURED (no credentials, no git identity, no kubeconfig, no Slack, gh signed out, no memory API, no package,
#      no UI answering, no build substrate): every one of the nine checks is GAP, each with non-empty host lines and a
#      verification command; exit 1; the table lists the nine checks and doctor.json beside it carries the same states
#   3. CONFIGURED (the model settings the shipped .env gives the container, ANTHROPIC_MODEL=us.anthropic.claude-fable-5-1[1m]
#      and CLAUDE_CODE_EFFORT_LEVEL=max, a stub aws answering a one-token Converse, GIT_USER_NAME/EMAIL with the matching git config, a
#      kubeconfig on a mount with kubectl can-i yes and Headlamp listing the cluster, a Slack token and channel that the
#      shipped Slack doctor proves against its stub API, gh signed in with GH_TOKEN and reading the package's repository, the memory API healthy
#      with the seed complete and a known fact recalled, a loaded package, the tmux-agent dashboard up, a stub buildctl
#      answering at BUILDKIT_HOST and the stub server's /v2/ as the stack's registry): every check
#      PASS, exit 0; the Converse call carries the model id WITHOUT its [1m] suffix (the stub, like Bedrock, refuses an id
#      with it), the row names the 1M context window and the facts carry the configured id, its source and the window;
#      with ANTHROPIC_MODEL empty the call carries Claude Code's own default without its suffix (the Bedrock default path)
#   4. PLANTED model ids: no inference-profile prefix fails Bedrock by the us. prefix rule before any call; an id
#      Bedrock does not know fails with Bedrock's own answer and the fix names where the id is configured (settings.json,
#      or AGENT_MODEL in .env.local for an id that came as ANTHROPIC_MODEL - probed without its [1m] suffix); the shipped
#      us. profile in an EU region fails, the fix keeping the suffix; each time the other eight checks stay PASS (the
#      control); a model pinned in settings.json's env block outranks ANTHROPIC_MODEL in the environment (as it does for
#      Claude Code); a tier alias (fable, opus[1m]) resolves through ANTHROPIC_DEFAULT_<TIER>_MODEL, and without the
#      variable is a gap before any call; with no model configured the default follows ANTHROPIC_DEFAULT_OPUS_MODEL, else
#      the built-in default; a throttled call, which brings no answer back, is a gap with the re-check
#   5. the doctor writes nothing outside SETUP_DIR (kubectl's cache and the Slack doctor's temporary files, removed);
#      PLANTED CONTROL: a copy of the doctor that also writes into HOME is caught by the same scan
#   6. Slack through the shipped Slack doctor (its stub API): a token with chat:write is reported as such; a narrow token
#      is a gap naming channels:history and the reinstall, reported as the read-only set; a channel the bot is not in
#      names the invite; a missing Slack doctor is a gap, and so is one still running at the doctor's Slack budget
#      (DOCTOR_SLACK_WAIT, by default 40 s, which the doctor names in what it ran), whose temporary files are removed
#   7. no credential value reaches the output: planted Slack, GitHub and AWS values echoed by the stubs' errors are
#      masked in the text and the JSON ([redacted] is there, the values are not), and no piece of a random value
#      placed across the doctor's 160-character cut of a command's line (it masks output as it captures it)
#   8. --not-needed <id> makes a check SKIP (exit 0 when the rest pass), --needed brings it back; --check re-runs one
#      check and keeps the other entries of doctor.json; a run writes through a temp file of its own, so a file in the
#      way at a fixed temp name does not stop it and eight runs at once all finish
#   9. the gaps behind the onboarding asks: a cluster found by the region scan, or named, gets the update-kubeconfig step,
#      and no cluster gets host lines that merge the agent's kept kubeconfig into the person's ~/.kube before the
#      restart, read through the container ./run.sh names (CONTAINER_NAME from .env; the daemon stub knows it by that
#      name only, as under host networking, also a name of the person's own), and fail out loud with a non-zero status,
#      the person's file as it was and no ~/.kube/config.merged, when there is no .env or the read fails;
#      can-i no gets the read-only access entry for the role behind the assumed role, its ARN as IAM gives it (with the
#      role's path), or a host line asking IAM for it when the container may not; a context renamed with a space, a
#      package folder and an AWS_REGION with one are quoted in the pasted lines (the stub kubectl models the view
#      policy: namespaced reads, no nodes), and a read failing after can-i said yes is a gap with kubectl's error; Headlamp
#      not listing the cluster and
#      a kubeconfig in the container's own filesystem are gaps, a mounted host kubeconfig stays byte-identical
#      (update-kubeconfig is the person's host line then), but a cluster Headlamp lists on its next re-read of
#      ~/.kube/config (9 s after the doctor first asks) is waited for; the grey tmux-agent tile names its flag; a planted
#      spoke registry gives its spokes live, waiting for their settings, without a session (a gap) or off, with the line
#      that turns one off, on and off as spoke.sh decides them; a registry the supervisor cannot read (it does not
#      parse, or its read fails, or it is not version 1 with a sessions list), one that lists no spoke or has an entry
#      that is not an object, and a spoke whose flag is not SPOKE_<NAME> or whose requires is not a list of names are gaps
#      saying why, each with the step that brings a corrected registry, kept beside another gap's lines; no registry says
#      so without a gap; a gh sign-in
#      without GH_TOKEN and a git identity without GIT_USER_NAME/EMAIL are reported as lost at the next restart
#  10. the harness-setup skill: its frontmatter names it, its triggers (/setup, "help me finish setting up") and the
#      doctor grant, and pre-approves kubectl get only as a table read (no wildcard, no -o); /setup hands over to it; every file and /agent script it names exists or is reported pending by
#      the doctor (the Slack manifest, the Slack doctor, the access-entry lines); the privacy scan passes it and the
#      Slack doctor
#  11. claude-skills-sync.sh installs every skill and command file into a Claude configuration, keeps a skill of the
#      person's own, writes nothing on a second run, restores a changed copy, removes a file the image stopped shipping
#      but none of the person's own; claude-settings-sync.sh runs it, startup.sh
#      runs that before the agent's session and the build through install-claude-onboarding.sh, and setup.sh checks the
#      skill is in the image (in the image: its own configuration carries the skill)
#  13. one item at a time: each check configured alone on the unconfigured instance passes, the other eight stay gaps
#  14. LIVE when claude answers on Bedrock (TEST23_DRIVE=false skips it), the tools stubs: the six onboarding questions
#      driven headless through the skill, one conversation; the doctor's table and a question first; the git identity
#      set inside and its .env.local lines; the Slack manifest's scopes; the kubeconfig written and the cluster read;
#      the GitHub token's host lines for the package; a live tile's grey-tile causes; the model the doctor's Bedrock
#      check probes is the one Claude Code called. The live parts (this and 12's /setup) run with every tool stubbed,
#      the test's own HOME and Claude configuration, and without the session's GitHub, Slack and AWS session values:
#      planted canaries for them reach no live run's configuration, transcript or reply, and every stub echoes only a
#      value the test planted for it (check 7)
#  15. (below 12) the shipped Slack doctor against its stub API: all PASS with a full token; with --post-test the
#      not_in_channel, channel_not_found and both round-trip rows; a narrow token names channels:history; a user token
#      is refused by name; a third-host base, and a loopback base with a user part (127.0.0.1:1@another host, which
#      curl sends to the host after the @), are refused before any request, and a loopback base with a path passes; a
#      dead loopback port is one "no answer" row and one request, with three channels named; an unset token's row
#      names .env.local; a token holding a double quote and a backslash-t reaches the stub byte for byte (auth.test
#      ok on 3 curl lines, none carrying it); no token on any curl command line (a curl that logs its argv), and no
#      temporary file left
#  12. the first turn: --brief prints at most 12 lines of at most 80 characters (a long finding clipped: the agent's pane
#      is 80 columns until a browser attaches) and SKILL.md bounds the first turn; LIVE when claude answers on
#      Bedrock (skipped and said so otherwise), in check 14's stub environment: /setup runs the doctor and answers in
#      under 25 lines ending with a question
# Uses /tmp/test23 (TEST23_DIR) and /dev/shm/test23-kube; never touches /wd or the agent's own configuration. One run at
# a time in a container: a second one refuses while the first runs (it holds /tmp/test23.lock), since these directories
# are fixed and check 5 reads the whole filesystem for writes.

set -u
# the lock is flock's, taken atomically: the run starts this script again as the child of a flock that holds
# /tmp/test23.lock, and goes on only as that child (its parent's command line names the lock); its own children do not
# inherit the lock (-o), and no setting skips it
if ! tr '\0' '\n' 2> /dev/null < "/proc/${PPID}/cmdline" | grep -qxF /tmp/test23.lock; then
	flock -n -o -E 75 /tmp/test23.lock bash "$0" "$@"
	RC=$?
	[ "${RC}" = 75 ] && echo "Test23 FAILED: another test23 runs in this container (it holds /tmp/test23.lock); run one at a time"
	exit "${RC}"
fi
T=${TEST23_DIR:-/tmp/test23}
KUBE_MNT=/dev/shm/test23-kube
rm -rf "${T:?}" "${KUBE_MNT:?}"
mkdir -p "${T}/bin" "${T}/out" "${T}/stublog" "${T}/home" "${T}/claude" "${T}/wd/ui" "${T}/wd/knowledge" "${KUBE_MNT}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
DOCTOR="${AGENT_DIR}/doctor.sh"
SEED_DIR="${BASE_DIR%/}/seed"
[ -d "${SEED_DIR}" ] || SEED_DIR=/seed
SERVER_PID=""
SERVER2_PID=""
SERVER3_PID=""
SLACK_STUB_PID=""

fail()
{
	echo "Test23 FAILED: $1"
	exit 1
}

cleanup()
{
	[ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
	[ -n "${SERVER2_PID}" ] && kill "${SERVER2_PID}" 2>/dev/null
	[ -n "${SERVER3_PID}" ] && kill "${SERVER3_PID}" 2>/dev/null
	[ -n "${SLACK_STUB_PID}" ] && kill "${SLACK_STUB_PID}" 2>/dev/null
	rm -rf "${KUBE_MNT:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- the stubs: each logs its call under ${STUB_LOG} and answers from STUB_* variables ---
cat > "${T}/bin/aws" << 'EOF'
#!/bin/bash
echo "$*" >> "${STUB_LOG:?}/aws.log"
# (STUB_AWS_PAD: text before the echoed session value, to place it across a cut in what the doctor keeps of the line)
creds() { [ "${STUB_AWS:-none}" = ok ] || { echo "Unable to locate credentials. You can configure credentials by running \"aws configure\".${STUB_AWS_PAD:-}$([ -n "${STUB_AWS_LEAK:-}" ] && [ "${AWS_SESSION_TOKEN:-}" = "${STUB_AWS_LEAK}" ] && echo " (session ${AWS_SESSION_TOKEN})")" >&2; exit 253; }; }
case "$1 $2" in
"sts get-caller-identity")
	creds
	echo '{"UserId":"AROAEXAMPLE:i-0","Account":"111122223333","Arn":"arn:aws:sts::111122223333:assumed-role/agent-role/i-0123456789abcdef0"}' ;;
"bedrock-runtime converse")
	creds
	MODEL=""; REGION=""
	while [ $# -gt 0 ]; do case "$1" in --model-id) MODEL=$2; shift ;; --region) REGION=$2; shift ;; esac; shift; done
	echo "converse ${MODEL} ${REGION}" >> "${STUB_LOG}/converse.log"
	# STUB_THROTTLE: Bedrock throttles the call, so no answer comes back
	if [ -n "${STUB_THROTTLE:-}" ]; then
		echo "aws: [ERROR]: An error occurred (ThrottlingException) when calling the Converse operation (reached max retries: 2): Too many tokens, please wait before trying again." >&2
		exit 254
	fi
	case "${MODEL}" in
	anthropic.*)
		echo "aws: [ERROR]: An error occurred (ValidationException) when calling the Converse operation: Invocation of model ID ${MODEL} with on-demand throughput isn't supported. Retry your request with the ID or ARN of an inference profile that contains this model." >&2
		exit 254 ;;
	us.anthropic.claude-opus-5-5|us.anthropic.claude-fable-5-1)
		# the ids the tests call on, in a us- region; an id that still carries Claude Code's [1m] suffix is not one of them and
		# gets the invalid-identifier answer below, as Bedrock gives it (the doctor must leave the suffix out of the call)
		if [ "${REGION#us-}" != "${REGION}" ]; then
			echo '{"output":{"message":{"role":"assistant","content":[{"text":"O"}]}},"stopReason":"max_tokens","usage":{"inputTokens":14,"outputTokens":1,"totalTokens":15}}'
			exit 0
		fi ;;
	esac
	echo "aws: [ERROR]: An error occurred (ValidationException) when calling the Converse operation: The provided model identifier is invalid." >&2
	exit 254 ;;
"iam get-role")
	# the role behind the assumed role, with the path an IAM Identity Center role carries; STUB_IAM=denied: the
	# container's identity may not ask IAM
	creds
	NAME=""; while [ $# -gt 0 ]; do [ "$1" = --role-name ] && NAME=$2; shift; done
	if [ "${STUB_IAM:-}" = denied ]; then
		echo "aws: [ERROR]: An error occurred (AccessDenied) when calling the GetRole operation: not authorized to perform: iam:GetRole on resource: role ${NAME}" >&2
		exit 254
	fi
	echo "arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/${NAME}" ;;
"eks list-clusters")
	creds
	REGION=""; while [ $# -gt 0 ]; do [ "$1" = --region ] && REGION=$2; shift; done
	if [ "${REGION}" = us-east-2 ]; then echo '{"clusters":["demo-cluster"]}'; else echo '{"clusters":[]}'; fi ;;
"eks describe-cluster")
	creds
	echo '{"cluster":{"name":"demo-cluster","status":"ACTIVE"}}' ;;
"eks update-kubeconfig")
	creds
	NAME=""; KC="${KUBECONFIG:-${HOME}/.kube/config}"
	while [ $# -gt 0 ]; do case "$1" in --name) NAME=$2; shift ;; --kubeconfig) KC=$2; shift ;; esac; shift; done
	KC=${KC/#\~/${HOME}}
	mkdir -p "$(dirname "${KC}")" && printf 'apiVersion: v1\nkind: Config\n' > "${KC}"
	echo "Added new context arn:aws:eks:us-east-2:111122223333:cluster/${NAME} to ${KC}" ;;
*)
	echo "stub aws: unexpected call: $*" >&2; exit 2 ;;
esac
EOF
cat > "${T}/bin/kubectl" << 'EOF'
#!/bin/bash
echo "$*" >> "${STUB_LOG:?}/kubectl.log"
CACHE="${HOME}/.kube/cache"
[ "$1" = "--cache-dir" ] && { CACHE=$2; shift 2; }
# a real kubectl keeps a discovery cache: the stub writes one where it was told to, so a doctor that does not say
# where writes into the person's ~/.kube (check 5)
mkdir -p "${CACHE}/discovery" && : > "${CACHE}/discovery/stub"
[ "$1" = "--context" ] && shift 2
[ -f "${KUBECONFIG:-${HOME}/.kube/config}" ] || { echo "error: no configuration has been provided" >&2; exit 1; }
CTX="arn:aws:eks:us-east-2:111122223333:cluster/demo-cluster"
case "$1 $2" in
"config get-contexts" | "config current-context") echo "${STUB_KUBE_CONTEXT:-${CTX}}" ;;
# the view policy (AmazonEKSViewPolicy, the view ClusterRole): namespaced reads, no core-group nodes, which are
# cluster-scoped and outside it (STUB_CANI_NODES=yes grants them); STUB_GET_FAIL: the reads fail on the server side
"auth can-i")
	case " $* " in
	*" nodes "*) echo "${STUB_CANI_NODES:-no}"; [ "${STUB_CANI_NODES:-no}" = yes ] ;;
	*) echo "${STUB_CANI:-yes}"; [ "${STUB_CANI:-yes}" = yes ] ;;
	esac ;;
"get nodes")
	[ -n "${STUB_GET_FAIL:-}" ] && { echo "Error from server (InternalError): an error on the server (\"\") has prevented the request from succeeding" >&2; exit 1; }
	[ "${STUB_CANI_NODES:-no}" = yes ] || { echo 'Error from server (Forbidden): nodes is forbidden: User "agent" cannot list resource "nodes" in API group "" at the cluster scope' >&2; exit 1; }
	case " $* " in
	*" -o name "*) printf 'node/node-a\nnode/node-b\n' ;;
	*) printf 'NAME     STATUS   ROLES    AGE   VERSION\nnode-a   Ready    <none>   3d    v1.32.0\nnode-b   Ready    <none>   3d    v1.32.0\n' ;;
	esac ;;
"get namespaces" | "get ns") printf 'NAME          STATUS   AGE\ndefault       Active   30d\nkube-system   Active   30d\nteam-a        Active   9d\n' ;;
"get pods")
	[ -n "${STUB_GET_FAIL:-}" ] && { echo "Error from server (InternalError): an error on the server (\"\") has prevented the request from succeeding" >&2; exit 1; }
	case " $* " in *" --no-headers "*) ;; *) printf '%s\n' 'NAMESPACE     NAME                       READY   STATUS    RESTARTS   AGE' ;; esac
	printf 'kube-system   coredns-1                  1/1     Running   0          30d\nteam-a        trainer-0                  1/1     Running   0          2d\n' ;;
"get deployments") printf 'NAMESPACE     NAME      READY   UP-TO-DATE   AVAILABLE   AGE\nkube-system   coredns   2/2     2            2           30d\n' ;;
*) echo "stub kubectl: unexpected call: $*" >&2; exit 2 ;;
esac
EOF
cat > "${T}/bin/gh" << 'EOF'
#!/bin/bash
echo "$1 $2 $3" >> "${STUB_LOG:?}/gh.log"
case "$1 $2" in
"auth status")
	if [ -n "${GH_TOKEN:-}" ] && [ "${GH_TOKEN}" = "${STUB_GH_GOOD:-}" ]; then
		printf 'github.com\n  ✓ Logged in to github.com account octo-test (GH_TOKEN)\n  - Active account: true\n'
		exit 0
	elif [ -n "${GH_TOKEN:-}" ]; then
		# a gh that echoes the refused token, when it is the one the test planted (check 7): the doctor must mask it
		T_SHOWN="the token"; [ -n "${STUB_GH_ECHO:-}" ] && [ "${GH_TOKEN}" = "${STUB_GH_ECHO}" ] && T_SHOWN="the token ${GH_TOKEN}"
		echo "github.com: X Failed to log in to github.com using token (GH_TOKEN): ${T_SHOWN} is invalid" >&2
		exit 1
	fi
	if [ -n "${STUB_GH_CONFIG:-}" ]; then
		printf 'github.com\n  ✓ Logged in to github.com account octo-test (%s/.config/gh/hosts.yml)\n' "${HOME}"
		exit 0
	fi
	echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
	exit 1 ;;
"repo view")
	[ "$3" = "octo-org/allowed" ] && { echo '{"nameWithOwner":"octo-org/allowed"}'; exit 0; }
	echo "GraphQL: Could not resolve to a Repository with the name '$3'." >&2
	exit 1 ;;
esac
exit 2
EOF
cat > "${T}/bin/slack-doctor" << 'EOF'
#!/bin/bash
# a Slack doctor in the shipped one's row format that echoes the token in a row, when it is the one the test planted
# (check 7): the doctor must mask it
SHOWN=""; [ -n "${STUB_SLACK_ECHO:-}" ] && [ "${SLACK_BOT_TOKEN:-}" = "${STUB_SLACK_ECHO}" ] && SHOWN=" (token ${SLACK_BOT_TOKEN})"
echo "STATE CHECK                  DETAIL"
echo "PASS  token                  auth.test ok"
echo "GAP   scopes                 missing scope: chat:write${SHOWN}"
echo "slack-doctor: 1 GAP(s)"
exit 1
EOF
cat > "${T}/bin/tmux" << 'EOF'
#!/bin/bash
# tmux as it is; with STUB_TMUX_LIVE set, has-session answers from it instead (the live session names, space-separated)
if [ -n "${STUB_TMUX_LIVE+x}" ] && [ "${1:-}" = has-session ]; then
	TARGET=""
	while [ $# -gt 0 ]; do [ "$1" = -t ] && TARGET=$2; shift; done
	case " ${STUB_TMUX_LIVE} " in *" ${TARGET#=} "*) exit 0 ;; *) exit 1 ;; esac
fi
exec /usr/bin/tmux "$@"
EOF
cat > "${T}/bin/docker" << 'EOF'
#!/bin/bash
# docker exec -i <container> sh -c <command>, as the container would run it: its /home/agent/.kube/config is
# STUB_AGENT_KUBECONFIG (root's, mode 600, readable only through the container) and its PATH the image's own; the
# daemon knows the container by its name (STUB_CONTAINER) and refuses any other, as it refuses a hostname
echo "$*" >> "${STUB_LOG:?}/docker.log"
if [ "${3:-}" != "${STUB_CONTAINER:?}" ]; then
	echo "Error response from daemon: No such container: ${3:-}" >&2
	exit 1
fi
if [ "${1:-}" = exec ] && [ "${2:-}" = -i ] && [ "${4:-}" = sh ] && [ "${5:-}" = -c ]; then
	exec env PATH=/usr/local/bin:/usr/bin:/bin sh -c "${6//\/home\/agent\/.kube\/config/${STUB_AGENT_KUBECONFIG:?}}"
fi
echo "stub docker: unexpected call: $*" >&2
exit 2
EOF
cat > "${T}/bin/curl" << 'EOF'
#!/bin/bash
# curl as it is, with its argv logged: no token may ever be on a command line (checks 5 and 15)
printf '%s\n' "$*" >> "${CURL_ARGV_LOG:-${STUB_LOG:?}/curl.log}"
exec /usr/bin/curl "$@"
EOF
printf '#!/bin/bash\necho "tmux-agent: UP pid=1 http=200 port=7337"\n' > "${T}/bin/ui-status-up"
printf '#!/bin/bash\necho "tmux-agent: DOWN port=7337"\necho "tmux-agent: not installed at /wd/tmux-agent (no finished install of 0123abc from TMUX_AGENT_SRC - see /wd/ui/tmux-agent-install.log); source: TMUX_AGENT_SRC (set)"\n' > "${T}/bin/ui-status-noinstall"
cat > "${T}/bin/server.py" << 'EOF'
import http.server, json, os, re, sys, time
# Headlamp lists a kubeconfig context under a sanitized name: every "/" of the context becomes "--"
HEADLAMP = json.loads(sys.argv[2]) if len(sys.argv) > 2 else ["arn:aws:eks:us-east-2:111122223333:cluster--demo-cluster"]
# a third argument: the seconds after the first /headlamp/config request before the list appears - Headlamp's watcher
# re-reads ~/.kube/config every 10 s, so a context written moments ago is listed on its next re-read
LATE = float(sys.argv[3]) if len(sys.argv) > 3 else 0
FIRST = []
DOCS = {"harness-knowledge": 120, "loglearner-rules": 30, "demo-pkg-notes": 12}
# every bank the default seed lists holds documents, as after a seed run (hindsight-seed.sh posts each bank in
# banks.json), so a bank added to the seed needs no edit here; a bank of another seed (seed-missing) still has none
if os.environ.get("STUB_SEED_BANKS"):
    for b in json.load(open(os.environ["STUB_SEED_BANKS"])):
        DOCS.setdefault(b if isinstance(b, str) else str(b.get("bank_id")), 10)
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def answer(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/health":
            return self.answer(200, {"status": "healthy"})
        # the stack's registry (the docker check reads /v2/ at BUILD_REGISTRY)
        if self.path == "/v2/":
            return self.answer(200, {})
        if self.path == "/headlamp/config":
            if not FIRST:
                FIRST.append(time.monotonic())
            ready = time.monotonic() - FIRST[0] >= LATE
            return self.answer(200, {"clusters": [{"name": n} for n in HEADLAMP] if ready else []})
        m = re.fullmatch(r"/v1/default/banks/([^/]+)/stats", self.path)
        if m and m.group(1) in DOCS:
            return self.answer(200, {"total_documents": DOCS[m.group(1)]})
        self.answer(404, {"detail": "not found"})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/v1/default/banks/harness-knowledge/memories/recall" and body.get("query"):
            return self.answer(200, {"results": [{"id": "m-1", "text": "Cross-region inference profiles prefix the model id with a geography such as us."}]})
        self.answer(404, {})
SRV = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
print(f"PORT={SRV.server_address[1]}", flush=True)
SRV.serve_forever()
EOF
# the BuildKit client against the build substrate: with STUB_BUILDKIT=ok the daemon answers its debug info and worker list
cat > "${T}/bin/buildctl" << 'EOF'
#!/bin/bash
echo "$*" >> "${STUB_LOG:?}/buildctl.log"
[ "${STUB_BUILDKIT:-none}" = ok ] || { echo "error: failed to dial the daemon: connection refused" >&2; exit 1; }
case " $* " in
	*" debug info "*) echo "BuildKit:   github.com/moby/buildkit v0.34.0 stub"; echo "Dockerfile: 1.28.0" ;;
	*) echo "[]" ;;
esac
EOF
chmod 755 "${T}/bin/buildctl" "${T}/bin/aws" "${T}/bin/kubectl" "${T}/bin/gh" "${T}/bin/slack-doctor" "${T}/bin/curl" "${T}/bin/tmux" "${T}/bin/docker" "${T}/bin/ui-status-up" "${T}/bin/ui-status-noinstall"
# the stub memory API with Headlamp's config (and two more Headlamp stubs) bind port 0, as the Slack stub does, and print
# the port they got: a listener another run left on a fixed port can neither take their place nor make them fail
STUB_SEED_BANKS="${SEED_DIR}/banks.json" python3 -I "${T}/bin/server.py" 0 > "${T}/server.log" 2>&1 &
SERVER_PID=$!
python3 -I "${T}/bin/server.py" 0 '["another-cluster"]' > "${T}/server2.log" 2>&1 &
SERVER2_PID=$!
python3 -I "${T}/bin/server.py" 0 '["arn:aws:eks:us-east-2:111122223333:cluster--demo-cluster"]' 9 > "${T}/server3.log" 2>&1 &
SERVER3_PID=$!
# the Slack Web API stub that ships with the Slack doctor: tokens xoxb-full (every manifest scope) and xoxb-narrow (no
# channels:history, no chat:write); channels C_OK, C_NOTIN (the bot is not in it) and C_NOPE (no such channel)
# and one more token, holding a double quote and a backslash-t, which curl's config syntax would read as the end of
# the string and a TAB: the stub accepts it as these exact bytes alone (check 15)
AWKWARD='xoxb-q"uo\te'
STUB_EXTRA_TOKEN="${AWKWARD}" python3 -I "${BASE_DIR%/}/test-lib/slack-doctor-stub.py" > "${T}/slack-stub.log" 2>&1 &
SLACK_STUB_PID=$!
stub_port()
{
	# stub_port <pid> <log>: the port the stub process bound and printed (PORT=<n>), once it answers /health there; a
	# stub that dies first (its port taken) fails the run, and a listener it does not own never stands in for it; the log
	# is read once it exists, since the stub's shell opens it in the background
	local PID=$1 LOG=$2 P=""
	for _ in $(seq 1 50); do
		[ -f "${LOG}" ] && P=$(sed -n 's/^PORT=//p' "${LOG}")
		[ -n "${P}" ] && curl -s -o /dev/null "http://127.0.0.1:${P}/health" && { echo "${P}"; return 0; }
		kill -0 "${PID}" 2>/dev/null || break
		sleep 0.2
	done
	return 1
}
PORT=$(stub_port "${SERVER_PID}" "${T}/server.log") || fail "the stub memory API did not start: $(tail -2 "${T}/server.log" | tr '\n' ' ')"
PORT2=$(stub_port "${SERVER2_PID}" "${T}/server2.log") || fail "the second Headlamp stub did not start: $(tail -2 "${T}/server2.log" | tr '\n' ' ')"
PORT3=$(stub_port "${SERVER3_PID}" "${T}/server3.log") || fail "the late Headlamp stub did not start: $(tail -2 "${T}/server3.log" | tr '\n' ' ')"
SLACK_BASE=""
for _ in $(seq 1 50); do
	[ -f "${T}/slack-stub.log" ] && SLACK_BASE=$(sed -n 's/^SLACK_API_BASE=//p' "${T}/slack-stub.log")
	[ -n "${SLACK_BASE}" ] && break
	sleep 0.2
done
[ -n "${SLACK_BASE}" ] || fail "the stub Slack API did not start: $(cat "${T}/slack-stub.log")"

# planted credential values, built at run time so no token shape is in this file
PLANT_SLACK="xox""b-test23-$(date +%s)-planted"
PLANT_GH="gh""p_$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PLANT_AWS="planted-session-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# run_doctor <case> [args...]: the doctor with ONLY these variables (env -i), plus the case's CASE_ENV entries;
# its stdout, stderr and exit code land in ${T}/out/<case>.{out,err,rc}
CASE_ENV=()
run_doctor()
{
	local NAME=$1
	shift
	env -i PATH="${T}/bin:/usr/local/bin:/usr/bin:/bin" HOME="${T}/home" LANG=C.UTF-8 GIT_CONFIG_NOSYSTEM=1 \
		SETUP_DIR="${T}/wd/setup" UI_DIR="${T}/wd/ui" KNOWLEDGE_DIR="${T}/wd/knowledge" CLAUDE_CONFIG_DIR="${T}/claude" \
		HINDSIGHT_SEED_STATE="${T}/wd/ui/hindsight-seed.state" HINDSIGHT_SEED_DIR="${SEED_DIR}" STUB_LOG="${T}/stublog" \
		DOCTOR_EKS_REGIONS="us-east-1 us-east-2 eu-west-1" UI_PORT_TMUX_AGENT=9 UI_PORT_HEADLAMP=9 \
		HINDSIGHT_API="http://127.0.0.1:9" SLACK_API_BASE="${SLACK_BASE}" \
		"${CASE_ENV[@]}" "${DOCTOR}" "$@" > "${T}/out/${NAME}.out" 2> "${T}/out/${NAME}.err"
	echo $? > "${T}/out/${NAME}.rc"
}

# states <case>: "id=STATE ..." from the case's doctor.json copy
states()
{
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(c["id"] + "=" + c["state"] for c in d["checks"]))' "${T}/out/$1.json"
}

save_json()
{
	cp "${T}/wd/setup/doctor.json" "${T}/out/$1.json" 2>/dev/null || fail "$1: no ${T}/wd/setup/doctor.json was written"
}

gap_has()
{
	# gap_has <case> <check id> <inside|host|found> <text>: the check is a GAP and that field carries the text
	python3 - "${T}/out/$1.json" "$2" "$3" "$4" << 'PY'
import json, sys
path, cid, field, text = sys.argv[1:5]
c = {x["id"]: x for x in json.load(open(path))["checks"]}[cid]
val = c[field] if field == "found" else " | ".join(c[field])
if c["state"] != "GAP" or text not in val:
    sys.exit(f"{cid}: state {c['state']}, its {field} has no '{text}': {val[:300]}")
PY
}

mark()
{
	# mark <marker>: the write marker, with the listing of /tmp's top level beside it
	sleep 1
	ls -A /tmp > "$1.tmp-list"
	touch "$1"
	sleep 1
}

# --- fixtures, all made BEFORE the write marker (check 5); a case switches them on through its variables ---
mkdir -p "${T}/home-git" "${T}/claude-badmodel" "${T}/wd/knowledge-pkg/demo-pkg/seeds"
git config --file "${T}/home-git/.gitconfig" user.name "Test Person"
git config --file "${T}/home-git/.gitconfig" user.email "test.person@example.com"
echo '{"model": "us.anthropic.claude-nonexistent-9"}' > "${T}/claude-badmodel/settings.json"
# a settings.json whose env block pins the model: it outranks ANTHROPIC_MODEL in the environment for every claude process
mkdir -p "${T}/claude-settings-env" && echo '{"env": {"ANTHROPIC_MODEL": "us.anthropic.claude-opus-5-5"}}' > "${T}/claude-settings-env/settings.json"
echo "apiVersion: v1" > "${KUBE_MNT}/config"
printf 'state=complete\ndocuments=150/150\n' > "${T}/wd/ui/hindsight-seed.state"
PKG="${T}/wd/knowledge-pkg/demo-pkg"
echo '{"demo-pkg-notes": {"name": "Demo notes"}}' > "${PKG}/seeds/banks.json"
echo "# Demo package" > "${PKG}/INDEX.md"
git -C "${PKG}" init -q && git -C "${PKG}" remote add origin https://github.com/octo-org/allowed.git
printf '## Shared workstreams\nRead %s first.\n' "${PKG}" > "${T}/wd/CLAUDE.md"
mkdir -p "${T}/seed-missing" && echo '{"missing-bank": {"name": "a bank the memory API does not hold"}}' > "${T}/seed-missing/banks.json"
mkdir -p "${T}/wd/knowledge-odd/odd pkg/seeds" && echo '{"odd-empty-bank": {"name": "a bank the memory API does not hold"}}' > "${T}/wd/knowledge-odd/odd pkg/seeds/banks.json"
# a spoke registry of the agent stack's shape (/agent/spokes/registry.json): the hub and two spokes; every other case
# names one that does not exist, so an image that carries a registry gives the same rows
printf '%s\n' '{"version": 1, "sessions": [' \
	'  {"session_name": "agent", "role": "hub", "flag": "AGENT_TMUX_SESSION", "enabled": true},' \
	'  {"session_name": "alpha", "role": "spoke", "flag": "SPOKE_ALPHA", "enabled": true},' \
	'  {"session_name": "beta", "role": "spoke", "flag": "SPOKE_BETA", "enabled": true}]}' > "${T}/registry-two.json"
# registries the supervisor cannot use, as spoke.sh reads them: the top level a list, no sessions list, another version,
# no sessions, JSON that does not parse; one with the hub alone (no spokes); a spoke whose requires is one name or a
# number, not a list of names (spoke.sh check refuses both), and a live one waiting for a setting this run does not set
printf '%s\n' '[{"session_name": "alpha", "role": "spoke", "flag": "SPOKE_ALPHA", "enabled": true}]' > "${T}/registry-list.json"
printf '%s\n' '{"version": 1, "spokes": [{"session_name": "alpha", "role": "spoke", "enabled": true}]}' > "${T}/registry-nosessions.json"
printf '%s\n' '{"version": 2, "sessions": [{"session_name": "alpha", "role": "spoke", "enabled": true}]}' > "${T}/registry-v2.json"
printf '%s\n' '{"version": 1, "sessions": []}' > "${T}/registry-empty.json"
printf '%s\n' '{"version": 1, "sessions": [' > "${T}/registry-broken.json"
printf '%s\n' '{"version": 1, "sessions": [{"session_name": "agent", "role": "hub", "enabled": true}]}' > "${T}/registry-hub.json"
printf '%s\n' '{"version": 1, "sessions": [1, "x"]}' > "${T}/registry-objects.json"
# one spoke, on by its registry entry, and one whose "enabled" is the word yes: spoke.sh turns a spoke on only with its
# flag set to exactly true, or with no flag set and "enabled": true
printf '%s\n' '{"version": 1, "sessions": [{"session_name": "alpha", "role": "spoke", "flag": "SPOKE_ALPHA", "enabled": true}]}' > "${T}/registry-alpha.json"
printf '%s\n' '{"version": 1, "sessions": [{"session_name": "alpha", "role": "spoke", "flag": "SPOKE_ALPHA", "enabled": "yes"}]}' > "${T}/registry-enabled-yes.json"
# the on direction (off in the registry, its flag set to true), and spokes whose flag spoke.sh check refuses: none, a number
printf '%s\n' '{"version": 1, "sessions": [{"session_name": "alpha", "role": "spoke", "flag": "SPOKE_ALPHA", "enabled": false}]}' > "${T}/registry-enabled-false.json"
printf '%s\n' '{"version": 1, "sessions": [{"session_name": "alpha", "role": "spoke", "enabled": true}]}' > "${T}/registry-noflag.json"
printf '%s\n' '{"version": 1, "sessions": [{"session_name": "alpha", "role": "spoke", "flag": 5, "enabled": true}]}' > "${T}/registry-numflag.json"
for RQ in word:'"SLACK_BOT_TOKEN"' number:5 waiting:'["TEST23_NOT_SET"], "requires_what": "Slack"'; do
	printf '{"version": 1, "sessions": [{"session_name": "alpha", "role": "spoke", "flag": "SPOKE_ALPHA", "enabled": true, "requires": %s}]}\n' \
		"${RQ#*:}" > "${T}/registry-requires-${RQ%%:*}.json"
done
UNCONFIGURED=(AWS_REGION=us-east-1 STUB_AWS=none KUBECONFIG="${T}/no-kubeconfig" SPOKES_REGISTRY="${T}/no-registry.json")
CONFIGURED=(AWS_REGION=us-east-1 STUB_AWS=ok HOME="${T}/home-git" GIT_USER_NAME="Test Person" SPOKES_REGISTRY="${T}/no-registry.json"
	GIT_USER_EMAIL=test.person@example.com KUBECONFIG="${KUBE_MNT}/config" STUB_CANI=yes UI_PORT_HEADLAMP="${PORT}"
	SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK GH_TOKEN="${PLANT_GH}"
	STUB_GH_GOOD="${PLANT_GH}" HINDSIGHT_API="http://127.0.0.1:${PORT}" KNOWLEDGE_DIR="${T}/wd/knowledge-pkg"
	UI_STATUS_BIN="${T}/bin/ui-status-up" BUILDKIT_HOST="unix://${T}/buildkit.sock" STUB_BUILDKIT=ok BUILD_REGISTRY="127.0.0.1:${PORT}"
	DOCKER_MIN_FREE_GB=0
	# the model settings the shipped .env gives the container (AGENT_MODEL, AGENT_EFFORT, AGENT_MODEL_OPUS, AGENT_MODEL_FABLE):
	# the id with the [1m] suffix, the effort level, the two alias ids
	ANTHROPIC_MODEL='us.anthropic.claude-fable-5-1[1m]' CLAUDE_CODE_EFFORT_LEVEL=max
	ANTHROPIC_DEFAULT_OPUS_MODEL='us.anthropic.claude-opus-5-5[1m]' ANTHROPIC_DEFAULT_FABLE_MODEL='us.anthropic.claude-fable-5-1[1m]')
mark "${T}/out/write-marker"

# --- 1. syntax, usage, argument errors ---
[ -f "${DOCTOR}" ] || fail "missing ${DOCTOR}"
bash -n "${DOCTOR}" || fail "bash -n ${DOCTOR}"
CASE_ENV=()
run_doctor help --help
[ "$(cat "${T}/out/help.rc")" = 0 ] && grep -q '^Usage: /agent/doctor.sh' "${T}/out/help.out" \
	|| fail "--help: rc=$(cat "${T}/out/help.rc"), $(head -2 "${T}/out/help.out" "${T}/out/help.err")"
run_doctor badarg --frobnicate
[ "$(cat "${T}/out/badarg.rc")" = 2 ] && [ "$(wc -l < "${T}/out/badarg.err")" -eq 1 ] \
	|| fail "an unknown argument: rc=$(cat "${T}/out/badarg.rc"), stderr: $(cat "${T}/out/badarg.err")"
run_doctor badcheck --check nosuch
[ "$(cat "${T}/out/badcheck.rc")" = 2 ] && grep -q 'unknown check nosuch' "${T}/out/badcheck.err" \
	|| fail "an unknown check: rc=$(cat "${T}/out/badcheck.rc"), stderr: $(cat "${T}/out/badcheck.err")"
# a cluster or region that is not an EKS name or a region name is refused before it reaches a line the person pastes
run_doctor badcluster --cluster 'demo;touch x' --region us-east-2
[ "$(cat "${T}/out/badcluster.rc")" = 2 ] && grep -q -- '--cluster takes an EKS cluster name' "${T}/out/badcluster.err" \
	|| fail "a cluster name outside the EKS pattern: rc=$(cat "${T}/out/badcluster.rc"), stderr: $(cat "${T}/out/badcluster.err")"
run_doctor badregion --cluster demo-cluster --region 'us-east-2 x'
[ "$(cat "${T}/out/badregion.rc")" = 2 ] && grep -q -- '--region takes an AWS region' "${T}/out/badregion.err" \
	|| fail "a region outside the region pattern: rc=$(cat "${T}/out/badregion.rc"), stderr: $(cat "${T}/out/badregion.err")"
[ -e "${T}/wd/setup" ] && fail "a usage error wrote ${T}/wd/setup"
# the states the doctor's header names, and the manual's in a checkout (docs/manual/install.md "Setup doctor"), are the
# ones a check returns
WHY=$(python3 - "${DOCTOR}" "${BASE_DIR%/}/../docs/manual/install.md" 2>&1 << 'PY'
import os, re, sys
doctor = open(sys.argv[1]).read()
returned = set(re.findall(r'result\("([A-Z]+)"', doctor))
texts = [("the doctor's header", doctor)] + ([("docs/manual/install.md", open(sys.argv[2]).read())] if os.path.isfile(sys.argv[2]) else [])
for where, text in texts:
    m = re.search(r"Each check is (.*?)\(the person said it", text, re.S)
    if not m:
        sys.exit(f"{where} has no 'Each check is ...' sentence")
    named = set(re.findall(r"\b[A-Z]{3,}\b", m.group(1)))
    if named != returned:
        sys.exit(f"{where} names the states {sorted(named)}, a check returns {sorted(returned)}")
PY
) || fail "${WHY}"
echo "ok 1 - the doctor parses, --help prints its usage, an unknown argument or check, a cluster outside the EKS name pattern and a region that is not one exit 2 with one line and write nothing; the states it documents are the ones it returns"

# --- 2. unconfigured: every check is a gap with host lines and a verification ---
CASE_ENV=("${UNCONFIGURED[@]}")
run_doctor unconfigured
save_json unconfigured
[ "$(cat "${T}/out/unconfigured.rc")" = 1 ] || fail "unconfigured: exit $(cat "${T}/out/unconfigured.rc"), expected 1: $(cat "${T}/out/unconfigured.err")"
python3 - "${T}/out/unconfigured.json" "${T}/out/unconfigured.out" << 'PY' || fail "unconfigured: see above"
import json, sys
d = json.load(open(sys.argv[1]))
text = open(sys.argv[2]).read()
want = ["bedrock", "git-identity", "eks", "slack", "github", "memory", "packages", "spokes", "docker"]
ids = [c["id"] for c in d["checks"]]
if ids != want:
    sys.exit(f"the checks are {ids}, expected {want}")
bad = []
for c in d["checks"]:
    lines = [x for x in c["host"] if x.strip() and not x.lstrip().startswith("#")]
    if c["state"] != "GAP" or not lines or not c["verify"]:
        bad.append(f'{c["id"]}: state={c["state"]} host commands={len(lines)} verify={len(c["verify"])} ({c["found"]})')
    if f'  {c["id"]}' not in text or f'{c["id"]}: GAP' not in text:
        bad.append(f'{c["id"]}: not in the printed table and its steps')
if bad:
    sys.exit("\n".join(bad))
if d["summary"].get("GAP") != 9:
    sys.exit(f"summary {d['summary']}")
PY
grep -q 'no AWS credentials reach the container' "${T}/out/unconfigured.out" || fail "unconfigured: the bedrock gap does not name the missing credentials"
[ -s "${T}/wd/setup/doctor.txt" ] || fail "unconfigured: no doctor.txt beside the JSON"
echo "ok 2 - unconfigured: all 9 checks GAP, each with host commands and a verification, exit 1, table and JSON agree"

# --- 3. configured: every check passes ---
CASE_ENV=("${CONFIGURED[@]}")
run_doctor configured
save_json configured
S=$(states configured)
[ "${S}" = "bedrock=PASS git-identity=PASS eks=PASS slack=PASS github=PASS memory=PASS packages=PASS spokes=PASS docker=PASS" ] \
	|| fail "configured: ${S}: $(grep -E '^  [a-z-]+ +GAP' "${T}/out/configured.out" | tr '\n' ';')"
[ "$(cat "${T}/out/configured.rc")" = 0 ] || fail "configured: exit $(cat "${T}/out/configured.rc"), expected 0"
grep -q 'converse us.anthropic.claude-fable-5-1 us-east-1' "${T}/stublog/converse.log" || fail "configured: the Bedrock check made no Converse call with the configured model, its [1m] suffix left out: $(cat "${T}/stublog/converse.log" | tr '\n' ';')"
grep -q '\[1m\]' "${T}/stublog/converse.log" && fail "configured: a Converse call carried the [1m] suffix, which is not part of the Bedrock model id: $(cat "${T}/stublog/converse.log" | tr '\n' ';')"
grep -q '^  bedrock .*PASS .*us.anthropic.claude-fable-5-1\[1m\] answers in us-east-1 with the 1M context window' "${T}/out/configured.out" \
	|| fail "configured: the Bedrock row does not name the configured model and the 1M context window: $(grep -m1 '^  bedrock ' "${T}/out/configured.out")"
python3 -I - "${T}/out/configured.json" << 'PY' || fail "configured: the Bedrock facts do not carry the configured id, its source and the context window"
import json, sys
f = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["bedrock"]["facts"]
want = {"model": "us.anthropic.claude-fable-5-1[1m]", "model_source": "ANTHROPIC_MODEL", "bedrock_model_id": "us.anthropic.claude-fable-5-1", "context_window": "1M"}
bad = {k: f.get(k) for k, v in want.items() if f.get(k) != v}
if bad:
    sys.exit(f"facts {bad}, expected {want}")
PY
# the Bedrock default path: with ANTHROPIC_MODEL empty, the doctor probes Claude Code's own default without its suffix - the opus
# alias' id when ANTHROPIC_DEFAULT_OPUS_MODEL is set (the shipped one is the same id as DEFAULT_MODEL), and the facts name the
# default as the source and where it came from
: > "${T}/stublog/converse.log"
CASE_ENV=("${CONFIGURED[@]}" ANTHROPIC_MODEL=)
run_doctor model-default --check bedrock
save_json model-default
grep -q 'converse us.anthropic.claude-opus-5-5 us-east-1' "${T}/stublog/converse.log" || fail "model-default: the Bedrock check made no Converse call with the default model, its suffix left out: $(cat "${T}/stublog/converse.log" | tr '\n' ';')"
python3 -I - "${T}/out/model-default.json" << 'PY' || fail "model-default: the Bedrock default path does not pass with the default named as the source"
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["bedrock"]
if c["state"] != "PASS" or c["facts"].get("model") != "us.anthropic.claude-opus-5-5[1m]" or c["facts"].get("model_source") != "default" \
        or c["facts"].get("default_from") != "ANTHROPIC_DEFAULT_OPUS_MODEL":
    sys.exit(f"state {c['state']}, facts {c['facts']}")
PY
# without the opus pin, the built-in default (DEFAULT_MODEL), and the facts say so
: > "${T}/stublog/converse.log"
CASE_ENV=("${CONFIGURED[@]}" ANTHROPIC_MODEL= ANTHROPIC_DEFAULT_OPUS_MODEL=)
run_doctor model-default-builtin --check bedrock
save_json model-default-builtin
grep -q 'converse us.anthropic.claude-opus-5-5 us-east-1' "${T}/stublog/converse.log" || fail "model-default-builtin: no Converse call with the built-in default without its suffix: $(cat "${T}/stublog/converse.log" | tr '\n' ';')"
python3 -I - "${T}/out/model-default-builtin.json" << 'PY' || fail "model-default-builtin: the built-in default path does not pass with default_from built-in"
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["bedrock"]
if c["state"] != "PASS" or c["facts"].get("model") != "us.anthropic.claude-opus-5-5[1m]" or c["facts"].get("default_from") != "built-in":
    sys.exit(f"state {c['state']}, facts {c['facts']}")
PY
grep -q 'listed in Headlamp' "${T}/out/configured.out" || fail "configured: the EKS row does not say Headlamp lists the cluster"
# the configured cluster grants the view policy only: it passes on its pods, and nodes, outside that policy, are a note
python3 -I - "${T}/out/configured.json" << 'PY' || fail "configured: the EKS row does not pass on the view policy's pods with nodes as an optional note"
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["eks"]
assert c["state"] == "PASS" and "pod" in c["found"], c["found"]
assert any("outside the view policy" in d for d in c["done"]), c["done"]
PY
echo "ok 3 - configured (stubs for Bedrock, Slack, GitHub and the build substrate): all 9 checks PASS, exit 0; the Converse call carries the configured model without its [1m] suffix, the row names the 1M context window, the facts carry the id, its source and the window; with ANTHROPIC_MODEL empty, the call carries Claude Code's default without its suffix"

# --- 4. planted model ids fail Bedrock; the other checks stay PASS ---
expect_bedrock_gap()
{
	# expect_bedrock_gap <case> <text the finding must carry>
	save_json "$1"
	S=$(states "$1")
	[ "${S}" = "bedrock=GAP git-identity=PASS eks=PASS slack=PASS github=PASS memory=PASS packages=PASS spokes=PASS docker=PASS" ] \
		|| fail "$1: ${S}: $(grep -m1 '^  bedrock ' "${T}/out/$1.out")"
	grep -q "^  bedrock .*GAP .*$2" "${T}/out/$1.out" || fail "$1: the Bedrock finding does not say '$2': $(grep -m1 '^  bedrock ' "${T}/out/$1.out")"
}
: > "${T}/stublog/converse.log"
CASE_ENV=("${CONFIGURED[@]}" ANTHROPIC_MODEL=anthropic.claude-opus-5-5)
run_doctor model-noprefix
expect_bedrock_gap model-noprefix "has no inference-profile prefix"
grep -q 'anthropic.claude-opus-5-5' "${T}/stublog/converse.log" && fail "model-noprefix: the prefix rule should refuse the id before any Converse call"
grep -q 'us.anthropic.claude-opus-5-5' "${T}/out/model-noprefix.out" || fail "model-noprefix: the fix does not name the us. id"
CASE_ENV=("${CONFIGURED[@]}" ANTHROPIC_MODEL= CLAUDE_CONFIG_DIR="${T}/claude-badmodel")
run_doctor model-unknown
expect_bedrock_gap model-unknown "provided model identifier is invalid"
grep -q "settings.json" "${T}/out/model-unknown.out" || fail "model-unknown: the fix does not point at settings.json, where the id is configured"
# an id Bedrock does not know, with the [1m] suffix, as ANTHROPIC_MODEL: probed without the suffix, Bedrock's answer, and the
# fix names AGENT_MODEL in .env.local, where the id is configured now, and the empty-value fallback
: > "${T}/stublog/converse.log"
CASE_ENV=("${CONFIGURED[@]}" ANTHROPIC_MODEL='us.anthropic.nope[1m]')
run_doctor model-unknown-env
expect_bedrock_gap model-unknown-env "provided model identifier is invalid"
grep -q 'converse us.anthropic.nope us-east-1' "${T}/stublog/converse.log" && ! grep -q 'nope\[1m\]' "${T}/stublog/converse.log" \
	|| fail "model-unknown-env: the Converse call did not carry the id without its [1m] suffix: $(cat "${T}/stublog/converse.log" | tr '\n' ';')"
gap_has model-unknown-env bedrock host "export AGENT_MODEL=" && gap_has model-unknown-env bedrock host ".env.local" && gap_has model-unknown-env bedrock host "empty, nothing is passed" \
	|| fail "model-unknown-env: the fix does not name AGENT_MODEL in .env.local and the empty-value fallback: $(grep -A12 '^bedrock: GAP' "${T}/out/model-unknown-env.out" | tr '\n' ';')"
grep -q 'AGENT_MODEL' "${T}/out/model-unknown.out" && fail "model-unknown: an id configured in settings.json gets the AGENT_MODEL fix"
CASE_ENV=("${CONFIGURED[@]}" AWS_REGION=eu-west-1)
run_doctor model-region
expect_bedrock_gap model-region "which eu-west-1 does not serve"
gap_has model-region bedrock host "export AGENT_MODEL='eu.anthropic.claude-fable-5-1[1m]'" || fail "model-region: the host fix does not set AGENT_MODEL to the eu. id with the [1m] suffix kept"
# the agent's settings.json env outranks the environment for every claude process (measured on Claude Code 2.1.304, 2026-10-31:
# env.ANTHROPIC_MODEL there was the model called, with another ANTHROPIC_MODEL in the environment): with both set, the doctor
# probes the settings' id and names settings as the source
: > "${T}/stublog/converse.log"
CASE_ENV=("${CONFIGURED[@]}" CLAUDE_CONFIG_DIR="${T}/claude-settings-env")
run_doctor model-settings-env --check bedrock
save_json model-settings-env
grep -q 'converse us.anthropic.claude-opus-5-5 us-east-1' "${T}/stublog/converse.log" && ! grep -q 'fable' "${T}/stublog/converse.log" \
	|| fail "model-settings-env: the doctor did not probe the settings.json id over the environment's: $(cat "${T}/stublog/converse.log" | tr '\n' ';')"
python3 -I - "${T}/out/model-settings-env.json" << 'PY' || fail "model-settings-env: the facts do not name settings as the source of the settings.json id"
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["bedrock"]
if c["state"] != "PASS" or c["facts"].get("model") != "us.anthropic.claude-opus-5-5" or c["facts"].get("model_source") != "settings":
    sys.exit(f"state {c['state']}, facts {c['facts']}")
PY
# a tier alias as the model (fable, opus[1m], ...) resolves through ANTHROPIC_DEFAULT_<TIER>_MODEL, which the shipped .env passes
# for opus and fable; without the variable the doctor cannot know the id, and says so before any call
: > "${T}/stublog/converse.log"
CASE_ENV=("${CONFIGURED[@]}" ANTHROPIC_MODEL=fable)
run_doctor model-alias --check bedrock
save_json model-alias
grep -q 'converse us.anthropic.claude-fable-5-1 us-east-1' "${T}/stublog/converse.log" || fail "model-alias: the alias fable was not resolved through ANTHROPIC_DEFAULT_FABLE_MODEL: $(cat "${T}/stublog/converse.log" | tr '\n' ';')"
python3 -I - "${T}/out/model-alias.json" << 'PY' || fail "model-alias: the facts do not carry the resolved id, the alias and the 1M window"
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["bedrock"]
f = c["facts"]
if c["state"] != "PASS" or f.get("model") != "us.anthropic.claude-fable-5-1[1m]" or f.get("model_alias") != "fable" or f.get("context_window") != "1M":
    sys.exit(f"state {c['state']}, facts {f}")
PY
: > "${T}/stublog/converse.log"
CASE_ENV=("${CONFIGURED[@]}" ANTHROPIC_MODEL='opus[1m]' ANTHROPIC_DEFAULT_OPUS_MODEL=)
run_doctor model-alias-unresolved --check bedrock
save_json model-alias-unresolved
gap_has model-alias-unresolved bedrock found "ANTHROPIC_DEFAULT_OPUS_MODEL" && gap_has model-alias-unresolved bedrock host "export AGENT_MODEL=" \
	|| fail "model-alias-unresolved: an alias without its resolver is not a gap naming the variable and AGENT_MODEL"
[ -s "${T}/stublog/converse.log" ] && fail "model-alias-unresolved: a Converse call was made with an alias: $(cat "${T}/stublog/converse.log" | tr '\n' ';')"
# with no model configured, Claude Code's default follows ANTHROPIC_DEFAULT_OPUS_MODEL (measured 2026-10-31 on 2.1.304: the pinned
# us.anthropic.claude-opus-5-5 was the model called), so the doctor probes the pin as it is and names it as the default's source
: > "${T}/stublog/converse.log"
CASE_ENV=("${CONFIGURED[@]}" ANTHROPIC_MODEL= ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-5-5)
run_doctor model-default-pinned --check bedrock
save_json model-default-pinned
python3 -I - "${T}/out/model-default-pinned.json" << 'PY' || fail "model-default-pinned: the default does not follow the opus pin"
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["bedrock"]
f = c["facts"]
if c["state"] != "PASS" or f.get("model") != "us.anthropic.claude-opus-5-5" or f.get("model_source") != "default" or f.get("default_from") != "ANTHROPIC_DEFAULT_OPUS_MODEL" or f.get("context_window") != "default":
    sys.exit(f"state {c['state']}, facts {f}")
PY
# a throttled call brings no answer back, so nothing is proven: a gap that says so and gives the re-check
CASE_ENV=("${CONFIGURED[@]}" STUB_THROTTLE=1)
run_doctor bedrock-throttled --check bedrock
save_json bedrock-throttled
gap_has bedrock-throttled bedrock found "throttled" && gap_has bedrock-throttled bedrock inside "/agent/doctor.sh --check bedrock" \
	|| fail "a throttled Converse call, which brings no answer back, is not a gap with the re-check"
echo "ok 4 - planted model ids fail Bedrock (no prefix: before any call; unknown: Bedrock's answer, fix in settings.json, or AGENT_MODEL in .env.local for an id that came as ANTHROPIC_MODEL, probed without its [1m] suffix; the shipped us. id in eu-west-1, the fix keeping the suffix), the other 8 checks stay PASS; settings.json's env outranks the environment; an alias resolves through ANTHROPIC_DEFAULT_<TIER>_MODEL or is a gap before any call; the default follows the opus pin; a throttled call is a gap with the re-check"

# --- 5. the doctor writes nothing outside SETUP_DIR ---
written_outside()
{
	# written_outside <marker>: every file, and every directory that is not an ancestor of an allowed place, changed
	# since the marker - in the places a process here can write, outside SETUP_DIR and this test's own records. /tmp
	# itself is read at its top level only (a name that is new since the marker's listing, a top-level file changed since
	# it), so other tests' leftover directories there are not this test's business; this test's own directory is walked
	python3 - "$1" "${T}" "${BASE_DIR}" << 'PY'
import os, sys
marker, T, base = sys.argv[1:4]
since = os.stat(marker).st_mtime
allowed = [os.path.join(T, p) for p in ("wd/setup", "out", "stublog", "server.log", "server2.log", "slack-stub.log", "planted")]
roots = ["/home/agent", "/etc", "/usr/local/bin", "/agent", "/var/tmp", "/dev/shm", "/wd", T]
if base not in ("", "/") and not base.startswith(T):
    roots.append(base)
inside = lambda p: any(p == a or p.startswith(a + "/") for a in allowed)
ancestor = lambda p: any(a.startswith(p.rstrip("/") + "/") for a in allowed)
hits, seen = set(), set()
for root in roots:
    for dp, dns, fns in os.walk(root):
        if dp in seen or inside(dp):
            dns[:] = []
            continue
        seen.add(dp)
        for n in fns:
            p = os.path.join(dp, n)
            try:
                if os.lstat(p).st_mtime > since:
                    hits.add(p)
            except OSError:
                pass
        try:
            if os.lstat(dp).st_mtime > since and not ancestor(dp):
                hits.add(dp + "/")
        except OSError:
            pass
before = set(open(marker + ".tmp-list").read().split("\n"))
for n in os.listdir("/tmp"):
    p = os.path.join("/tmp", n)
    if p == T or inside(p):
        continue
    try:
        if n not in before or (os.path.isfile(p) and os.lstat(p).st_mtime > since):
            hits.add(p)
    except OSError:
        pass
print("\n".join(sorted(hits)))
PY
}

OUTSIDE=$(written_outside "${T}/out/write-marker")
[ -z "${OUTSIDE}" ] || fail "the doctor runs of checks 1-4 wrote outside SETUP_DIR: $(echo "${OUTSIDE}" | head -10 | tr '\n' ' ')"
[ -f "${T}/wd/setup/kube-cache/discovery/stub" ] || fail "kubectl's cache did not land under SETUP_DIR (the stub writes where --cache-dir points)"
# the Slack doctor's requests are the curl calls that write a /body file; ui-status.sh's probes go through the same curl
grep -q -- "-o ${T}/wd/setup/tmp/[^ ]*/body " "${T}/stublog/curl.log" || fail "no Slack doctor request kept its temporary files under SETUP_DIR: $(grep -m1 -- '/body ' "${T}/stublog/curl.log")"
grep -- '/body ' "${T}/stublog/curl.log" | grep -v -- "-o ${T}/wd/setup/tmp/" | grep -q . && fail "a Slack doctor request kept its temporary files outside SETUP_DIR: $(grep -- '/body ' "${T}/stublog/curl.log" | grep -v -- "-o ${T}/wd/setup/tmp/" | head -1)"
[ -z "$(ls -A "${T}/wd/setup/tmp")" ] || fail "the Slack doctor left its temporary files in ${T}/wd/setup/tmp"
mkdir -p "${T}/planted"
cp "${DOCTOR}" "${T}/planted/doctor.sh"
python3 - "${T}/planted/doctor.sh" << 'PY' || fail "could not plant the write into the doctor copy"
import sys
p = sys.argv[1]
c = open(p).read()
assert c.count("def main():\n") == 1
open(p, "w").write(c.replace("def main():\n", "def main():\n    open(os.path.join(HOME, '.doctor-planted'), 'w').close()\n"))
PY
mark "${T}/out/write-marker2"
DOCTOR_REAL=${DOCTOR}
DOCTOR="${T}/planted/doctor.sh"
CASE_ENV=("${CONFIGURED[@]}")
run_doctor planted-write --check git-identity
DOCTOR=${DOCTOR_REAL}
OUTSIDE=$(written_outside "${T}/out/write-marker2")
echo "${OUTSIDE}" | grep -qxF "${T}/home-git/.doctor-planted" || fail "PLANTED CONTROL BROKEN: the scan missed a doctor writing into HOME: [${OUTSIDE}]"
rm -f "${T:?}/home-git/.doctor-planted"
echo "ok 5 - the doctor wrote nothing outside SETUP_DIR (kubectl's cache and the Slack doctor's temporary files under it, removed); PLANTED CONTROL: a copy writing into HOME is caught"

# --- 6. Slack through the shipped Slack doctor and its stub API: the gap names the row, the scope set is reported ---
python3 -c 'import json,sys; c={x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["slack"]; sys.exit(0 if "read and write (chat:write granted)" in c["found"] else 1)' "${T}/out/configured.json" \
	|| fail "configured: the Slack row does not say the token carries chat:write"
CASE_ENV=("${CONFIGURED[@]}" SLACK_BOT_TOKEN=xoxb-narrow)
run_doctor slack-narrow --check slack
save_json slack-narrow
gap_has slack-narrow slack found "slack-doctor.sh scopes: missing scope: channels:history" && gap_has slack-narrow slack host "Reinstall to Workspace" \
	|| fail "a narrow token: the gap does not name the missing scope and the reinstall"
python3 -c 'import json,sys; c={x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["slack"]; sys.exit(0 if c["facts"].get("scope_set") == "read-only (no chat:write)" else 1)' "${T}/out/slack-narrow.json" \
	|| fail "a token without chat:write is not reported as the read-only scope set"
CASE_ENV=("${CONFIGURED[@]}" SLACK_CHANNELS=C_OK,C_NOTIN)
run_doctor slack-notin --check slack
save_json slack-notin
gap_has slack-notin slack found "slack-doctor.sh channel C_NOTIN: not_in_channel" && gap_has slack-notin slack host "/invite @<your app>" \
	|| fail "a channel the bot is not in: the gap does not name it and the invite"
CASE_ENV=("${CONFIGURED[@]}" SLACK_DOCTOR_BIN="${T}/bin/no-such-slack-doctor")
run_doctor slack-missing --check slack
save_json slack-missing
gap_has slack-missing slack found "the Slack doctor is missing from this image" || fail "a missing Slack doctor is not a gap"
# a Slack doctor still running at the doctor's Slack budget (one that sleeps past DOCTOR_SLACK_WAIT) is a gap naming the
# budget, and the temporary files it made before it was stopped are gone; the default budget, 40 s, is in what the
# doctor says it ran
printf '#!/bin/bash\nd=$(mktemp -d) && : > "${d}/body"\nsleep 8\necho "STATE CHECK                  DETAIL"\necho "PASS  token                  auth.test ok"\n' > "${T}/bin/slack-doctor-slow"
chmod 755 "${T}/bin/slack-doctor-slow"
CASE_ENV=("${CONFIGURED[@]}" SLACK_DOCTOR_BIN="${T}/bin/slack-doctor-slow" DOCTOR_SLACK_WAIT=2)
run_doctor slack-slow --check slack
save_json slack-slow
gap_has slack-slow slack found "slack-doctor.sh did not finish within 2 s" \
	|| fail "a Slack doctor still running at the doctor's Slack budget is not a gap naming the budget: $(grep -E '^  slack ' "${T}/out/slack-slow.out")"
[ -z "$(ls -A "${T}/wd/setup/tmp")" ] || fail "a Slack doctor stopped at the doctor's Slack budget left its temporary files in ${T}/wd/setup/tmp: $(ls -A "${T}/wd/setup/tmp")"
python3 -c 'import json,sys; c={x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["slack"]; sys.exit(0 if any("at most 40 s" in d for d in c["done"]) else 1)' "${T}/out/configured.json" \
	|| fail "configured: what the doctor ran does not name its default Slack budget of 40 s"
echo "ok 6 - Slack through the shipped doctor: chat:write reported when granted, a narrow token names channels:history and the reinstall (read-only set), a channel the bot is not in names the invite, a missing Slack doctor is a gap, so is one past the doctor's Slack budget (40 s by default)"

# --- 7. no credential value reaches the output ---
# a stub echoes only a value the test planted for it, never a token the environment happens to hold (the live parts
# run with the container's environment, check 12)
UNPLANTED="unplanted$$"
env STUB_LOG="${T}/stublog" STUB_AWS=none STUB_AWS_LEAK="${PLANT_AWS}" AWS_SESSION_TOKEN="${UNPLANTED}" "${T}/bin/aws" sts get-caller-identity 2>&1 \
	| grep -qF "${UNPLANTED}" && fail "the aws stub echoes a session value the test did not plant"
env STUB_LOG="${T}/stublog" GH_TOKEN="${UNPLANTED}" STUB_GH_GOOD=another "${T}/bin/gh" auth status 2>&1 | grep -qF "${UNPLANTED}" \
	&& fail "the gh stub echoes a token the test did not plant"
env SLACK_BOT_TOKEN="${UNPLANTED}" "${T}/bin/slack-doctor" | grep -qF "${UNPLANTED}" \
	&& fail "the Slack doctor stub echoes a token the test did not plant"
env STUB_LOG="${T}/stublog" STUB_AWS=none STUB_AWS_LEAK="${PLANT_AWS}" AWS_SESSION_TOKEN="${PLANT_AWS}" "${T}/bin/aws" sts get-caller-identity 2>&1 \
	| grep -qF "${PLANT_AWS}" || fail "control: the aws stub does not echo the planted session value"
env STUB_LOG="${T}/stublog" GH_TOKEN="${PLANT_GH}" STUB_GH_GOOD=another STUB_GH_ECHO="${PLANT_GH}" "${T}/bin/gh" auth status 2>&1 | grep -qF "${PLANT_GH}" \
	|| fail "control: the gh stub does not echo the planted token"
env SLACK_BOT_TOKEN="${PLANT_SLACK}" STUB_SLACK_ECHO="${PLANT_SLACK}" "${T}/bin/slack-doctor" | grep -qF "${PLANT_SLACK}" \
	|| fail "control: the Slack doctor stub does not echo the planted token"
CASE_ENV=("${UNCONFIGURED[@]}" STUB_AWS_LEAK="${PLANT_AWS}" AWS_SESSION_TOKEN="${PLANT_AWS}" GH_TOKEN="${PLANT_GH}" STUB_GH_GOOD=another
	STUB_GH_ECHO="${PLANT_GH}" SLACK_BOT_TOKEN="${PLANT_SLACK}" STUB_SLACK_ECHO="${PLANT_SLACK}" SLACK_CHANNELS=CTEST0001
	SLACK_DOCTOR_BIN="${T}/bin/slack-doctor")
run_doctor leak --check bedrock,slack,github
for F in "${T}/out/leak.out" "${T}/out/leak.err" "${T}/wd/setup/doctor.json" "${T}/wd/setup/doctor.txt"; do
	for V in "${PLANT_AWS}" "${PLANT_GH}" "${PLANT_SLACK}"; do
		grep -qF "${V}" "${F}" && fail "a planted credential value is in ${F} (length ${#V})"
	done
done
[ "$(grep -o '\[redacted\]' "${T}/out/leak.out" | wc -l)" -ge 3 ] || fail "the three echoed values are not marked [redacted]: $(grep -E '^  (bedrock|slack|github) ' "${T}/out/leak.out" | tr '\n' ';')"
# a value the doctor's 160-character cut of a command's first line would split: no piece of it reaches the output,
# since the doctor masks a command's output as it captures it, before anything is cut (a random value, so a piece is
# its own: an AWS secret key has no shape a pattern could catch)
LONG=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
AT=$(env STUB_LOG="${T}/stublog" STUB_AWS=none STUB_AWS_LEAK="${LONG}" AWS_SESSION_TOKEN="${LONG}" "${T}/bin/aws" sts get-caller-identity 2>&1 \
	| awk -v v="${LONG}" '{ i = index($0, v); if (i) print i - 1 }')
[ -n "${AT}" ] && [ "${AT}" -lt 148 ] || fail "control: the aws stub does not echo the long planted value early enough in its line (at ${AT:-none})"
PAD=$(printf '%*s' $((160 - 12 - AT)) '' | tr ' ' '.')
CASE_ENV=("${UNCONFIGURED[@]}" STUB_AWS_LEAK="${LONG}" AWS_SESSION_TOKEN="${LONG}" STUB_AWS_PAD="${PAD}")
run_doctor leak-cut --check bedrock
WHY=$(python3 - "${LONG}" "${T}/out/leak-cut.out" "${T}/out/leak-cut.err" "${T}/wd/setup/doctor.json" "${T}/wd/setup/doctor.txt" 2>&1 << 'PY'
import sys
v, files = sys.argv[1], sys.argv[2:]
pieces = {v[i:i + 8] for i in range(len(v) - 7)}
for f in files:
    text = open(f).read()
    if any(p in text for p in pieces):
        sys.exit(f"a piece of a planted credential value cut at 160 characters is in {f}")
PY
) || fail "${WHY}"
echo "ok 7 - planted AWS, GitHub and Slack values echoed by the stubs are [redacted] in the text and the JSON; the controls prove each stub echoes its value; no piece of a value cut at 160 characters reaches the output"

# --- 8. not needed, needed, and one check re-run ---
pkg_state() { python3 -c 'import json,sys; print({c["id"]: c["state"] for c in json.load(open(sys.argv[1]))["checks"]}["packages"])' "${T}/wd/setup/doctor.json"; }
CASE_ENV=("${CONFIGURED[@]}" KNOWLEDGE_DIR="${T}/wd/knowledge")
run_doctor skip-before
[ "$(pkg_state)" = GAP ] && [ "$(cat "${T}/out/skip-before.rc")" = 1 ] || fail "no package: packages $(pkg_state), exit $(cat "${T}/out/skip-before.rc")"
run_doctor skip --not-needed packages
[ "$(pkg_state)" = SKIP ] && [ "$(cat "${T}/out/skip.rc")" = 0 ] || fail "--not-needed packages: packages $(pkg_state), exit $(cat "${T}/out/skip.rc")"
grep -qx packages "${T}/wd/setup/not-needed" || fail "--not-needed did not record the choice in SETUP_DIR/not-needed"
run_doctor skip-undo --needed packages
[ "$(pkg_state)" = GAP ] && [ "$(cat "${T}/out/skip-undo.rc")" = 1 ] || fail "--needed packages: packages $(pkg_state), exit $(cat "${T}/out/skip-undo.rc")"
grep -qx packages "${T}/wd/setup/not-needed" && fail "--needed did not remove the choice"
# a run writes its files through a temp file of its own: one in the way at a fixed name (planted: directories where
# another run's doctor.json.tmp and doctor.txt.tmp would be) does not stop it, and eight runs at once all finish
mkdir -p "${T}/wd/setup/doctor.json.tmp" "${T}/wd/setup/doctor.txt.tmp"
CASE_ENV=("${CONFIGURED[@]}")
run_doctor tmp-taken --check git-identity
[ "$(cat "${T}/out/tmp-taken.rc")" = 0 ] \
	|| fail "a temp file of another run in the way stops a run: exit $(cat "${T}/out/tmp-taken.rc"): $(tail -1 "${T}/out/tmp-taken.err")"
rmdir "${T:?}/wd/setup/doctor.json.tmp" "${T:?}/wd/setup/doctor.txt.tmp"
TOGETHER=()
for N in 1 2 3 4 5 6 7 8; do
	run_doctor "together-${N}" --check git-identity &
	TOGETHER+=("$!")
done
wait "${TOGETHER[@]}"
for N in 1 2 3 4 5 6 7 8; do
	[ "$(cat "${T}/out/together-${N}.rc")" = 0 ] || fail "run ${N} of eight at once: exit $(cat "${T}/out/together-${N}.rc"): $(tail -1 "${T}/out/together-${N}.err")"
done
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${T}/wd/setup/doctor.json" || fail "eight runs at once left a doctor.json that does not parse"
CASE_ENV=("${CONFIGURED[@]}")
run_doctor merge-full
CASE_ENV=("${CONFIGURED[@]}" GIT_USER_NAME= GIT_USER_EMAIL=)
run_doctor merge-one --check git-identity
save_json merge-one
S=$(states merge-one)
[ "${S}" = "bedrock=PASS git-identity=GAP eks=PASS slack=PASS github=PASS memory=PASS packages=PASS spokes=PASS docker=PASS" ] || fail "--check git-identity: doctor.json is ${S}"
[ "$(grep -c '^  [a-z-]* \+\(PASS\|GAP\|SKIP\)' "${T}/out/merge-one.out")" = 1 ] || fail "--check git-identity printed more than its row: $(head -4 "${T}/out/merge-one.out" | tr '\n' ';')"
grep -q 'set for this container only' "${T}/out/merge-one.out" || fail "a git identity without GIT_USER_NAME/EMAIL is not reported as lost at the next start"
echo "ok 8 - --not-needed makes a check SKIP (exit 0), --needed brings it back; --check re-runs one check and keeps the other entries of doctor.json; a file at a fixed temp name does not stop a run, eight runs at once all finish"

# --- 9. the gaps behind the onboarding asks: what the agent does inside, what the person runs on the host ---
CASE_ENV=("${CONFIGURED[@]}" KUBECONFIG="${T}/no-kubeconfig")
run_doctor eks-scan --check eks
save_json eks-scan
gap_has eks-scan eks inside "aws eks update-kubeconfig --name demo-cluster --region us-east-2 --kubeconfig ~/.kube/config" || fail "a cluster found by the region scan: no update-kubeconfig step"
run_doctor eks-named --check eks --cluster demo-cluster --region us-east-2
save_json eks-named
gap_has eks-named eks inside "aws eks update-kubeconfig --name demo-cluster --region us-east-2 --kubeconfig ~/.kube/config" || fail "a named cluster: no update-kubeconfig step"
# a container whose ~/.kube is on a read-only mount (planted: HOME on the first read-only directory mount, /sys in a
# Docker container): the agent cannot write a kubeconfig there, so update-kubeconfig is a host line, where that file
# comes from, and no inside line writes. A VM (a Docker Sandbox) can have no read-only directory mount at all - its /sys
# is read-write for root - and then there is no read-only ~/.kube to plant, which the test says instead of passing it.
RO_DIR=$(awk '$6 ~ /(^|,)ro(,|$)/ {print $5}' /proc/self/mountinfo | while read -r d; do [ -d "${d}" ] && { echo "${d}"; break; }; done)
if [ -n "${RO_DIR}" ]; then
	CASE_ENV=("${CONFIGURED[@]}" KUBECONFIG="${T}/no-kubeconfig" HOME="${RO_DIR}")
	run_doctor eks-rokube --check eks
	save_json eks-rokube
	gap_has eks-rokube eks found "read-only" && gap_has eks-rokube eks host "aws eks update-kubeconfig --name demo-cluster --region us-east-2" \
		|| fail "a read-only ~/.kube (HOME=${RO_DIR}): update-kubeconfig is not a host line naming the read-only mount"
	gap_has eks-rokube eks inside "update-kubeconfig" 2> /dev/null && fail "a read-only ~/.kube: an inside line still writes the kubeconfig there"
	ROKUBE_NOTE="a read-only ~/.kube (HOME=${RO_DIR})"
else
	echo "note: no read-only directory mount here (a VM such as a Docker Sandbox): the read-only ~/.kube case is not exercised"
	ROKUBE_NOTE="no read-only directory mount here, so no read-only ~/.kube case"
fi
# no cluster to connect: the host lines make ~/.kube to share one, and first merge the kubeconfig the agent keeps into
# it, since the next ./run.sh mounts the host's ~/.kube over that file. Played here as the host: the person's own file
# with one context, the agent's (root's, mode 600, readable only through the container: the docker stub runs the
# line's command as the container would) with another; the lines up to the restart must leave the person's file with
# both, theirs current, mode 600. The lines run in the checkout, whose .env names the container as ./run.sh does, and
# the stub knows the container by that name only: under NETWORK=--network host the container's hostname is the host's
CASE_ENV=("${CONFIGURED[@]}" KUBECONFIG="${T}/no-kubeconfig" DOCTOR_EKS_REGIONS=us-east-1)
run_doctor eks-nocluster --check eks
save_json eks-nocluster
HP="${T}/host-play"
mkdir -p "${HP}/home/.kube"
kubeconfig_of() # kubeconfig_of <name>: a kubeconfig with one context, <name>-ctx, current
{
	printf '%s\n' 'apiVersion: v1' 'kind: Config' "clusters: [{name: $1-cl, cluster: {server: \"https://$1.example\"}}]" \
		"users: [{name: $1-u, user: {token: $1-token}}]" "contexts: [{name: $1-ctx, context: {cluster: $1-cl, user: $1-u}}]" \
		"current-context: $1-ctx"
}
kubeconfig_of host > "${HP}/home/.kube/config"
kubeconfig_of agent > "${HP}/agent-kubeconfig"
# the two lines of the checkout's .env that name the container ./run.sh starts (it runs it under CONTAINER_NAME)
printf '%s\n' 'export CONTAINER=agent-under-test' 'export CONTAINER_NAME="--name ${CONTAINER}"' > "${HP}/.env"
chmod 600 "${HP}/agent-kubeconfig"
WHY=$(python3 - "${T}/out/eks-nocluster.json" "${HP}/lines.sh" 2>&1 << 'PY'
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["eks"]
if c["state"] != "GAP" or not c["found"].startswith("no cluster"):
    sys.exit(f"no cluster in the scanned region is not the no-cluster gap: {c['state']} {c['found']}")
host = c["host"]
start = next((i for i, x in enumerate(host) if x.startswith("mkdir -p ~/.kube")), None)
stop = next((i for i, x in enumerate(host) if x.startswith("./stop.sh && ./run.sh")), None)
if start is None or stop is None or stop < start:
    sys.exit("no cluster: the host lines do not make ~/.kube before the restart: " + " | ".join(host))
open(sys.argv[2], "w").write("\n".join(x for x in host[start:stop] if not x.lstrip().startswith("#")) + "\n")
PY
) || fail "${WHY}"
(cd "${HP}" && env -i PATH="${T}/bin:/usr/local/bin:/usr/bin:/bin" HOME="${HP}/home" STUB_LOG="${T}/stublog" \
	STUB_AGENT_KUBECONFIG="${HP}/agent-kubeconfig" STUB_CONTAINER=agent-under-test bash "${HP}/lines.sh") > "${T}/out/host-play.out" 2>&1
HOST_RC=$?
REAL_KUBECTL=$(PATH=/usr/local/bin:/usr/bin:/bin command -v kubectl)
CTXS=$(KUBECONFIG="${HP}/home/.kube/config" "${REAL_KUBECTL}" config get-contexts -o name 2>/dev/null | sort | tr '\n' ' ')
CUR=$(KUBECONFIG="${HP}/home/.kube/config" "${REAL_KUBECTL}" config current-context 2>/dev/null)
[ "${HOST_RC}" = 0 ] && [ "${CTXS}" = "agent-ctx host-ctx " ] && [ "${CUR}" = host-ctx ] && [ "$(stat -c %a "${HP}/home/.kube/config")" = 600 ] \
	|| fail "no cluster: the host lines, run (status ${HOST_RC}), leave the person's kubeconfig with the contexts [${CTXS}], current ${CUR:-none}, mode $(stat -c %a "${HP}/home/.kube/config"), not both with theirs current and mode 600: $(tail -2 "${T}/out/host-play.out" | tr '\n' ' ')"
grep -q "^exec -i agent-under-test sh -c " "${T}/stublog/docker.log" \
	|| fail "no cluster: the merge does not read the kept kubeconfig through the container ./run.sh named (CONTAINER in .env): $(tail -1 "${T}/stublog/docker.log" 2>/dev/null)"
# the same lines in three more stand-in checkouts, each with the person's own kubeconfig: a CONTAINER_NAME of the
# person's names the container (./run.sh runs it under that name); a container that is not running, and a directory
# with no .env, each fail loudly with a non-zero status and leave the person's file as it was, with no
# ~/.kube/config.merged behind, so the next try starts clean
other_play() # other_play <name> <.env text, empty for none> <the container the daemon knows>: status in PLAY_RC
{
	local D="${T}/host-play-$1"
	mkdir -p "${D}/home/.kube"
	kubeconfig_of host > "${D}/home/.kube/config"
	chmod 600 "${D}/home/.kube/config"
	[ -z "$2" ] || printf '%s\n' "$2" > "${D}/.env"
	PLAY_SUM=$(sha256sum < "${D}/home/.kube/config")
	(cd "${D}" && env -i PATH="${T}/bin:/usr/local/bin:/usr/bin:/bin" HOME="${D}/home" STUB_LOG="${T}/stublog" \
		STUB_AGENT_KUBECONFIG="${HP}/agent-kubeconfig" STUB_CONTAINER="$3" bash "${HP}/lines.sh") > "${D}.out" 2>&1
	PLAY_RC=$?
}
play_kept() # play_kept <name>: the person's file is byte-identical and no config.merged is left
{
	[ "$(sha256sum < "${T}/host-play-$1/home/.kube/config")" = "${PLAY_SUM}" ] || fail "no cluster, $1: a merge that failed changed the person's kubeconfig"
	[ -e "${T}/host-play-$1/home/.kube/config.merged" ] && fail "no cluster, $1: a merge that failed leaves ~/.kube/config.merged behind"
	return 0
}
other_play own-name $'export CONTAINER=agent-under-test\nexport CONTAINER_NAME="--name my-agent"' my-agent
CTXS=$(KUBECONFIG="${T}/host-play-own-name/home/.kube/config" "${REAL_KUBECTL}" config get-contexts -o name 2>/dev/null | sort | tr '\n' ' ')
[ "${PLAY_RC}" = 0 ] && [ "${CTXS}" = "agent-ctx host-ctx " ] \
	|| fail "no cluster, CONTAINER_NAME=\"--name my-agent\": the lines do not merge through the container ./run.sh named my-agent (status ${PLAY_RC}, contexts [${CTXS}]): $(tail -2 "${T}/host-play-own-name.out" | tr '\n' ' ')"
other_play not-running $'export CONTAINER=agent-not-running\nexport CONTAINER_NAME="--name ${CONTAINER}"' agent-under-test
grep -q 'No such container: agent-not-running' "${T}/host-play-not-running.out" && grep -q 'not merged: ~/.kube/config is as it was' "${T}/host-play-not-running.out" \
	&& [ "${PLAY_RC}" != 0 ] \
	|| fail "no cluster, the container not running: the lines do not stop at docker exec, say the file was not merged and end non-zero (status ${PLAY_RC}): $(tail -2 "${T}/host-play-not-running.out" | tr '\n' ' ')"
play_kept not-running
other_play no-env "" agent-under-test
grep -q 'no container name from ./.env' "${T}/host-play-no-env.out" && [ "${PLAY_RC}" != 0 ] \
	|| fail "no cluster, run where there is no .env: the lines do not say they found no container name and end non-zero (status ${PLAY_RC}): $(tail -2 "${T}/host-play-no-env.out" | tr '\n' ' ')"
play_kept no-env
grep -q 'eks describe-cluster --name demo-cluster --region us-east-2' "${T}/stublog/aws.log" || fail "--cluster/--region did not describe that cluster"
# can-i answered yes, so the API answered: a read that then fails is a gap carrying kubectl's error, never a PASS
CASE_ENV=("${CONFIGURED[@]}" STUB_CANI_NODES=yes STUB_GET_FAIL=1)
run_doctor eks-getfail --check eks
save_json eks-getfail
gap_has eks-getfail eks found "Error from server (InternalError)" || fail "a read that fails after can-i answered yes is not a gap carrying kubectl's error"
# the host's ~/.kube mounted as the container's (./run.sh on a host that has one: KUBE_HOST_MOUNT=true): that kubeconfig
# is the person's own file, so the step that connects a cluster leaves it byte-identical, and update-kubeconfig, which
# also makes the new context the current one, is the person's host line
HK="${T}/hosthome"
mkdir -p "${HK}/.kube" && printf 'apiVersion: v1\nkind: Config\ncurrent-context: host-ctx\n' > "${HK}/.kube/config"
HK_SUM=$(sha256sum < "${HK}/.kube/config")
CASE_ENV=("${CONFIGURED[@]}" HOME="${HK}" KUBECONFIG="${HK}/.kube/config" KUBE_HOST_MOUNT=true STUB_KUBE_CONTEXT=host-ctx)
run_doctor eks-hostkube --check eks --cluster demo-cluster --region us-east-2
save_json eks-hostkube
python3 -I - "${T}/out/eks-hostkube.json" > "${T}/out/eks-hostkube.inside" << 'PY' || fail "eks-hostkube: no eks entry in doctor.json"
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["eks"]
print("\n".join(x for x in c.get("inside") or [] if x.strip() and not x.lstrip().startswith("#")))
PY
while IFS= read -r LINE; do
	env -i PATH="${T}/bin:/usr/bin:/bin" HOME="${HK}" KUBECONFIG="${HK}/.kube/config" STUB_LOG="${T}/stublog" STUB_AWS=ok \
		STUB_KUBE_CONTEXT=host-ctx bash -c "${LINE}" > /dev/null 2>&1
done < "${T}/out/eks-hostkube.inside"
[ "$(sha256sum < "${HK}/.kube/config")" = "${HK_SUM}" ] \
	|| fail "the eks step's inside lines changed the host's mounted kubeconfig: $(tr '\n' ';' < "${T}/out/eks-hostkube.inside")"
gap_has eks-hostkube eks host "aws eks update-kubeconfig --name demo-cluster --region us-east-2" \
	&& gap_has eks-hostkube eks host "makes it the current one" \
	|| fail "a mounted host ~/.kube: update-kubeconfig is not the person's host line, with the context it makes current"
CASE_ENV=("${CONFIGURED[@]}" STUB_CANI=no)
run_doctor eks-cani --check eks
save_json eks-cani
gap_has eks-cani eks host "aws eks create-access-entry --cluster-name demo-cluster --region us-east-2" \
	&& gap_has eks-cani eks host "--principal-arn arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/agent-role --type STANDARD" \
	|| fail "can-i no: the host lines are not the access entry for the role behind the assumed-role identity, its ARN with its path as IAM gives it"
gap_has eks-cani eks host "cluster-access-policy/AmazonEKSViewPolicy" || fail "can-i no: the access entry does not carry the read-only view policy"
gap_has eks-cani eks host "#   eksctl create iamidentitymapping --cluster demo-cluster --region us-east-2" \
	|| fail "can-i no: the aws-auth ConfigMap alternative is not offered, filled in"
# the container's identity may not ask IAM: the ARN is asked for on the host, with the person's own credentials
CASE_ENV=("${CONFIGURED[@]}" STUB_CANI=no STUB_IAM=denied)
run_doctor eks-cani-noiam --check eks
save_json eks-cani-noiam
gap_has eks-cani-noiam eks host 'PRINCIPAL_ARN="$(aws iam get-role --role-name agent-role --query Role.Arn --output text)"' \
	&& gap_has eks-cani-noiam eks host '--principal-arn "$PRINCIPAL_ARN" --type STANDARD' \
	|| fail "can-i no, IAM not readable from the container: the host lines do not ask IAM for the role's ARN on the host"
gap_has eks-cani-noiam eks host "role/agent-role" 2> /dev/null && fail "can-i no, IAM not readable from the container: the host lines still carry an ARN rebuilt without the role's path"
# a value that reaches a line the person pastes is quoted for the shell: a kubeconfig context renamed with a space, a
# package folder with one, an AWS_REGION with one
CASE_ENV=("${CONFIGURED[@]}" STUB_CANI=no STUB_KUBE_CONTEXT="arn:aws:eks:us-east-2:111122223333:cluster/demo cluster")
run_doctor eks-quoted --check eks
save_json eks-quoted
gap_has eks-quoted eks host "aws eks create-access-entry --cluster-name 'demo cluster' --region us-east-2" \
	|| fail "a cluster name with a space is not quoted in the access entry's lines"
CASE_ENV=("${CONFIGURED[@]}" KNOWLEDGE_DIR="${T}/wd/knowledge-odd")
run_doctor pkg-quoted --check packages
save_json pkg-quoted
gap_has pkg-quoted packages inside "HINDSIGHT_SEED_DIR='${T}/wd/knowledge-odd/odd pkg/seeds' HINDSIGHT_SEED_STAMP='/wd/hindsight-seed-odd pkg.stamp' /agent/hindsight-seed.sh" \
	|| fail "a package folder with a space is not quoted in its seed line"
CASE_ENV=(AWS_REGION="us-east-1 x" STUB_AWS=none KUBECONFIG="${T}/no-kubeconfig")
run_doctor bedrock-quoted --check bedrock
save_json bedrock-quoted
gap_has bedrock-quoted bedrock host "export AWS_REGION='us-east-1 x'" || fail "an AWS_REGION with a space is not quoted in the credentials lines"
CASE_ENV=("${CONFIGURED[@]}" UI_PORT_HEADLAMP="${PORT2}" DOCTOR_HEADLAMP_WAIT=2)
run_doctor eks-headlamp --check eks
save_json eks-headlamp
gap_has eks-headlamp eks found "Headlamp does not list the cluster" || fail "Headlamp answering without the cluster is not a gap"
# Headlamp re-reads ~/.kube/config every 10 s: a cluster it lists on that re-read (9 s after the doctor first asks) is
# waited for, with the default wait, not reported as a gap
CASE_ENV=("${CONFIGURED[@]}" UI_PORT_HEADLAMP="${PORT3}")
run_doctor eks-headlamp-late --check eks
grep -q '^eks: PASS' "${T}/out/eks-headlamp-late.out" && grep -q 'listed in Headlamp' "${T}/out/eks-headlamp-late.out" \
	|| fail "a cluster Headlamp lists on its next re-read of ~/.kube/config is reported as a gap: $(grep -m1 '^eks:' "${T}/out/eks-headlamp-late.out")"
mkdir -p "${T}/kube-ephemeral" && cp "${KUBE_MNT}/config" "${T}/kube-ephemeral/config"
CASE_ENV=("${CONFIGURED[@]}" KUBECONFIG="${T}/kube-ephemeral/config")
run_doctor eks-persist --check eks
save_json eks-persist
gap_has eks-persist eks found "lost at the next restart" || fail "a kubeconfig in the container's own filesystem is not reported as lost at the restart"
gap_has eks-persist eks host "./stop.sh && ./run.sh   # the container's ~/.kube is kept under wd/agent-state" || fail "the persistence gap has no restart into the agent-state ~/.kube"
CASE_ENV=("${CONFIGURED[@]}" KUBECONFIG="${T}/kube-ephemeral/config" UI_PORT_HEADLAMP="${PORT2}" DOCTOR_HEADLAMP_WAIT=2)
run_doctor eks-both --check eks
save_json eks-both
gap_has eks-both eks found "Headlamp does not list the cluster and the kubeconfig is lost at the next restart" \
	&& gap_has eks-both eks inside "headlamp.pid" && gap_has eks-both eks host "kept under wd/agent-state" \
	|| fail "a readable cluster with both gaps does not report both, each with its own step"
CASE_ENV=("${CONFIGURED[@]}" UI_TMUX_AGENT=false)
run_doctor tile-off --check spokes
save_json tile-off
gap_has tile-off spokes found "its tile is grey" || fail "UI_TMUX_AGENT=false is not reported as the grey tile"
gap_has tile-off spokes host "export UI_TMUX_AGENT=true" || fail "the grey tile has no host line turning it on"
CASE_ENV=("${CONFIGURED[@]}" UI_STATUS_BIN="${T}/bin/ui-status-noinstall")
run_doctor tile-noinstall --check spokes
save_json tile-noinstall
gap_has tile-noinstall spokes found "not built from its source yet" && gap_has tile-noinstall spokes inside "tmux-agent-install.log" \
	&& gap_has tile-noinstall spokes host "export TMUX_AGENT_SRC=   # empty: the vendored copy" \
	|| fail "a dashboard whose build from TMUX_AGENT_SRC has not finished is not a gap with the install log and the vendored copy"
CASE_ENV=("${CONFIGURED[@]}")
run_doctor tile-pass --check spokes
grep -q '^spokes: PASS' "${T}/out/tile-pass.out" && grep -q 'no install source' "${T}/out/tile-pass.out" && grep -q 'reload it' "${T}/out/tile-pass.out" \
	|| fail "--check spokes on a live dashboard does not explain a grey tile seen elsewhere: $(tail -4 "${T}/out/tile-pass.out" | tr '\n' ';')"
# the spokes a registry names: each one live, without a session or off, and the line that turns one off; a spoke that is
# on with no session is a gap; without a registry the row says so and adds no gap
# the home page's sentence, byte for byte: /setup says it the same way
OFFLINE="To turn one off, set SPOKE_<NAME>=false in .env.local, then ./stop.sh && ./run.sh."
grep -qF -- "${OFFLINE}" "${SKILL:-${AGENT_DIR}/skills/harness-setup}/prompts/steps.md" \
	|| fail "the skill's spokes step does not carry the home page's turn-off sentence: ${OFFLINE}"
CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/registry-two.json" STUB_TMUX_LIVE=alpha)
run_doctor spokes-two --check spokes
save_json spokes-two
gap_has spokes-two spokes found "spokes: alpha live, beta no session" && gap_has spokes-two spokes found "the spoke beta is on" \
	&& gap_has spokes-two spokes host "${OFFLINE}" \
	|| fail "a registry with one live spoke and one without a session: the row does not give both states and the line that turns one off"
CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/registry-two.json" STUB_TMUX_LIVE=alpha SPOKE_BETA=false)
run_doctor spokes-off --check spokes
grep -q '^spokes: PASS - .*spokes: alpha live, beta off' "${T}/out/spokes-off.out" && grep -qF -- "${OFFLINE}" "${T}/out/spokes-off.out" \
	|| fail "a spoke turned off (SPOKE_BETA=false) is not reported off in a passing row with the line that turns one off: $(grep -m1 '^spokes:' "${T}/out/spokes-off.out")"
CASE_ENV=("${CONFIGURED[@]}")
run_doctor spokes-none --check spokes
grep -q '^spokes: PASS - .*no spoke registry in this image' "${T}/out/spokes-none.out" \
	|| fail "without a spoke registry the row does not say so, or is not a pass: $(grep -m1 '^spokes:' "${T}/out/spokes-none.out")"
# a registry the supervisor cannot read (spoke.sh's own reader refuses it) is a gap that says why, never a quiet pass,
# and so is one spoke.sh check refuses as a whole: no spoke listed, an entry that is not an object; each gives the
# person the step that brings a corrected registry
for C in "list:the supervisor cannot read the spoke registry REG: it is a JSON array, not an object with a sessions list" \
	"nosessions:the supervisor cannot read the spoke registry REG: it has no sessions list" \
	"v2:the supervisor cannot read the spoke registry REG: its version is 2, not 1" \
	"broken:the supervisor cannot read the spoke registry REG: it does not parse" \
	"empty:the spoke registry REG lists no spoke" "hub:the spoke registry REG lists no spoke" \
	"objects:the spoke registry REG has an entry that is not an object"; do
	N=${C%%:*}
	SAYS=${C#*:}
	SAYS=${SAYS//REG/${T}/registry-${N}.json}
	CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/registry-${N}.json")
	run_doctor "spokes-${N}" --check spokes
	save_json "spokes-${N}"
	gap_has "spokes-${N}" spokes found "${SAYS}" \
		|| fail "the spoke registry case ${N} is not a gap saying \"${SAYS}\": $(grep -m1 '^spokes:' "${T}/out/spokes-${N}.out")"
	gap_has "spokes-${N}" spokes host "git pull && ./build.sh" \
		|| fail "the spoke registry case ${N}: the gap gives no step that brings a corrected registry"
done
gap_has spokes-objects spokes found "lists no spoke" || fail "a registry whose only entries are not objects does not say it lists no spoke"
# a registry the supervisor cannot read lists no spoke count under done, and one whose read fails says so rather than that
# it does not parse (/proc/self/mem is a regular file that fails to read, also for root)
python3 -c 'import json, sys; c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["spokes"]; sys.exit(any("spoke(s)" in x for x in c["done"]))' \
	"${T}/out/spokes-broken.json" || fail "a registry that does not parse is listed under done with a spoke count"
CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY=/proc/self/mem)
run_doctor spokes-unreadable --check spokes
save_json spokes-unreadable
gap_has spokes-unreadable spokes found "the supervisor cannot read the spoke registry /proc/self/mem: reading it fails (Input/output error)" \
	|| fail "a registry that cannot be read is not a gap saying the read fails: $(grep -m1 '^spokes:' "${T}/out/spokes-unreadable.out")"
# a registry problem beside a grey tile: the host lines keep the tile's setting, add the build step, one restart after both
CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/registry-list.json" UI_TMUX_AGENT=false)
run_doctor spokes-tile-registry --check spokes
save_json spokes-tile-registry
WHY=$(python3 - "${T}/out/spokes-tile-registry.json" 2>&1 << 'PY'
import json, sys
c = {x["id"]: x for x in json.load(open(sys.argv[1]))["checks"]}["spokes"]
h = c["host"]
at = lambda pre: next((i for i, x in enumerate(h) if x.startswith(pre)), None)
tile, build, restart = at("export UI_TMUX_AGENT=true"), at("git pull && ./build.sh"), at("./stop.sh && ./run.sh")
if c["state"] != "GAP" or None in (tile, build, restart) or not tile < build < restart \
        or sum(x.startswith("./stop.sh && ./run.sh") for x in h) != 1:
    sys.exit("a registry problem beside a grey tile: the host lines are not the tile's setting, the build step and one restart: "
             + " | ".join(h))
PY
) || fail "${WHY}"
# on and off as spoke.sh decides them: a flag set to anything but exactly true is off, and so is an "enabled" that is not true
for C in "flag-upper:SPOKE_ALPHA=TRUE:registry-alpha" "flag-empty:SPOKE_ALPHA=:registry-alpha" "enabled-yes::registry-enabled-yes"; do
	N=${C%%:*}
	REST=${C#*:}
	SET=${REST%%:*}
	CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/${REST#*:}.json" ${SET:+"${SET}"})
	run_doctor "spokes-${N}" --check spokes
	grep -q '^spokes: PASS - .*spokes: alpha off' "${T}/out/spokes-${N}.out" \
		|| fail "a spoke spoke.sh keeps off (${N}) is not off in a passing row: $(grep -m1 '^spokes:' "${T}/out/spokes-${N}.out")"
done
# and on: "enabled": false, its flag set to exactly true
CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/registry-enabled-false.json" SPOKE_ALPHA=true STUB_TMUX_LIVE=alpha)
run_doctor spokes-flag-on --check spokes
grep -q '^spokes: PASS - .*spokes: alpha live' "${T}/out/spokes-flag-on.out" \
	|| fail "a spoke off in the registry with SPOKE_ALPHA=true is not on: $(grep -m1 '^spokes:' "${T}/out/spokes-flag-on.out")"
# a spoke with no SPOKE_<NAME> flag, or a flag that is not one, is an entry spoke.sh check refuses: a gap naming it. One
# with no flag of its own never reads as decided by a SPOKE_ variable, which the supervisor does not read for it
CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/registry-noflag.json" SPOKE_ALPHA=false)
run_doctor spokes-noflag --check spokes
save_json spokes-noflag
gap_has spokes-noflag spokes found "the spoke alpha: it has no SPOKE_<NAME> flag, which spoke.sh check refuses" \
	|| fail "a spoke with no flag is not a gap naming it: $(grep -m1 '^spokes:' "${T}/out/spokes-noflag.out")"
grep -q 'is on (SPOKE_ALPHA' "${T}/out/spokes-noflag.out" \
	&& fail "a spoke with no flag of its own reads as decided by SPOKE_ALPHA, which the supervisor does not read for it"
CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/registry-numflag.json")
run_doctor spokes-numflag --check spokes
save_json spokes-numflag
gap_has spokes-numflag spokes found "the spoke alpha: its flag 5 is not SPOKE_<NAME>, which spoke.sh check refuses" \
	|| fail "a spoke whose flag is a number is not a gap naming it: $(grep -m1 '^spokes:' "${T}/out/spokes-numflag.out")"
# a spoke entry whose requires is not a list of names is a gap naming it, as spoke.sh check says, not a misread
for RQ in word number; do
	CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/registry-requires-${RQ}.json" STUB_TMUX_LIVE=alpha)
	run_doctor "spokes-requires-${RQ}" --check spokes
	save_json "spokes-requires-${RQ}"
	gap_has "spokes-requires-${RQ}" spokes found "the spoke alpha: its requires is not a list of environment variable names, which spoke.sh check refuses" \
		|| fail "a spoke whose requires is a ${RQ}, not a list of names, is not a gap naming it: $(grep -m1 '^spokes:' "${T}/out/spokes-requires-${RQ}.out")"
done
# a live spoke whose cycle waits for a setting this environment does not set: the row says waiting, the supervisor's
# word, never live
CASE_ENV=("${CONFIGURED[@]}" SPOKES_REGISTRY="${T}/registry-requires-waiting.json" STUB_TMUX_LIVE=alpha)
run_doctor spokes-waiting --check spokes
grep -q '^spokes: PASS - .*spokes: alpha waiting for Slack' "${T}/out/spokes-waiting.out" \
	|| fail "a live spoke whose requires is unset does not read 'alpha waiting for Slack' in a passing row: $(grep -m1 '^spokes:' "${T}/out/spokes-waiting.out")"
grep -q 'alpha live' "${T}/out/spokes-waiting.out" && fail "a spoke waiting for its settings reads live: $(grep -m1 '^spokes:' "${T}/out/spokes-waiting.out")"
CASE_ENV=("${CONFIGURED[@]}" GH_TOKEN= STUB_GH_CONFIG=1)
run_doctor gh-config --check github
save_json gh-config
gap_has gh-config github found "for this container only" || fail "a gh sign-in without GH_TOKEN is not reported as lost at the restart"
gap_has gh-config github host "export GH_TOKEN=" || fail "the gh gap has no GH_TOKEN host line"
gap_has unconfigured git-identity inside "git config --global user.name" || fail "no git identity: no inside step"
gap_has unconfigured git-identity host "export GIT_USER_NAME=" || fail "no git identity: no .env line"
echo "ok 9 - the asks' gaps: a found or named cluster gets update-kubeconfig, no cluster a ~/.kube that keeps the agent's kubeconfig (a host line, the mounted host kubeconfig byte-identical, when the host's ~/.kube is mounted), can-i no the role's read-only access entry (its ARN from IAM with its path, or asked for on the host), a cluster, package or region with a space quoted in the pasted lines, a read failing after can-i yes a gap with kubectl's error, Headlamp (listing a context under its sanitized name, waited for until its next re-read) and persistence gaps (alone and together, each with its step); the grey tile names its flag, a build from TMUX_AGENT_SRC that has not finished names its log and the vendored copy, and a live one explains a grey tile seen elsewhere; a registry's spokes live, waiting, without a session or off (on and off as spoke.sh decides), with the line that turns one off, and a registry or spoke entry spoke.sh refuses (a flag that is not SPOKE_<NAME> among them) a gap saying why, with its build step beside any other gap's lines; the kubeconfig merge reads through the container ./run.sh names, and no .env or a failed read fails out loud and leaves the person's file as it was; gh and git say what lasts only until the restart; ${ROKUBE_NOTE}"

# --- 10. the skill: its frontmatter, the files it names, the pending inputs the doctor reports, the privacy scan ---
SKILL="${AGENT_DIR}/skills/harness-setup"
[ -f "${SKILL}/SKILL.md" ] || fail "no skill at ${SKILL}/SKILL.md"
[ -f "${AGENT_DIR}/commands/setup.md" ] || fail "no /setup command at ${AGENT_DIR}/commands/setup.md"
python3 - "${SKILL}" "${AGENT_DIR}" "${BASE_DIR}" "${T}/out/unconfigured.json" << 'PY' || fail "the skill: see above"
import json, os, re, sys
skill, agent, base, doctor_json = sys.argv[1:5]
text = open(os.path.join(skill, "SKILL.md"), encoding="utf-8").read()
m = re.match(r"---\n(.*?)\n---\n", text, re.S)
if not m:
    sys.exit("SKILL.md has no frontmatter")
front = m.group(1)
if not re.search(r"^name: harness-setup$", front, re.M):
    sys.exit("the frontmatter does not name the skill harness-setup")
desc = re.search(r"^description: (.+)$", front, re.M)
if not desc or "/setup" not in desc.group(1) or "help me finish setting up" not in desc.group(1):
    sys.exit("the description does not carry /setup and 'help me finish setting up'")
if "  - Bash(/agent/doctor.sh *)" not in front:
    sys.exit("allowed-tools does not grant the doctor")
# the skill reads its own files, outside the working directory: its grant, and the rule claude-skills-sync.sh puts in
# settings.json for the turns after it (check 11), keep that read from asking
if "  - Read(~/.claude/skills/harness-setup/**)" not in front:
    sys.exit("SKILL.md does not grant reading its own files: the first turn's read of prompts/steps.md would ask")
cmd = open(os.path.join(agent, "commands", "setup.md"), encoding="utf-8").read()
if not cmd.startswith("---\ndescription: ") or "harness-setup skill" not in cmd or "Bash(/agent/doctor.sh *)" not in cmd:
    sys.exit("commands/setup.md does not describe itself, grant the doctor and hand over to the skill")
miss = [l for l in re.findall(r"\]\(([^)]+)\)", text) if not os.path.isfile(os.path.join(skill, l))]
for f in ("prompts/steps.md", "prompts/p2-working-through-the-agent.md", "prompts/p6-starting-a-project-with-us.md",
          "prompts/p7-install-your-own.md", "slack-app-manifest.yaml", "eks-access-entry.md"):
    if f not in text or not os.path.isfile(os.path.join(skill, f)):
        miss.append(f)
if miss:
    sys.exit(f"SKILL.md names files the skill does not have: {miss}")
steps = open(os.path.join(skill, "prompts", "steps.md"), encoding="utf-8").read()
want = ["bedrock", "git-identity", "eks", "slack", "github", "memory", "packages", "spokes", "docker"]
if re.findall(r"^## (\S+)$", steps, re.M) != want:
    sys.exit(f"prompts/steps.md sections {re.findall(r'^## (.+)$', steps, re.M)} are not the doctor's checks in its order")
doc = json.load(open(doctor_json))
pending = [p for c in doc["checks"] for p in c["pending"]]
bad = []
for f in [os.path.join(skill, "SKILL.md")] + [os.path.join(skill, "prompts", n) for n in sorted(os.listdir(os.path.join(skill, "prompts")))]:
    for span in re.findall(r"`([^`\n]+)`", open(f, encoding="utf-8").read()):
        tok = span.split()[0]
        if tok.startswith("/agent/"):
            path = os.path.join(agent, tok[len("/agent/"):])
            if not os.path.exists(path) and not any(tok in p and "input pending" in p for p in pending):
                bad.append(f"{os.path.basename(f)}: {tok}")
        elif tok.startswith(("docs/", "./")) and os.path.isdir(os.path.join(base, "..", "Container-Root")):
            # a checkout (the image ships /docs but not the scripts and documents of the repository's root)
            if not os.path.exists(os.path.join(base, "..", tok)):
                bad.append(f"{os.path.basename(f)}: {tok}")
if bad:
    sys.exit(f"the skill names scripts or documents that do not exist (and are not reported pending): {bad}")
PY
for P in slack-app-manifest.yaml eks-access-entry.md; do
	if head -1 "${SKILL}/${P}" | grep -qi 'input pending'; then
		LINE=$(head -1 "${SKILL}/${P}" | sed 's/^#* *//')
		grep -qF "${LINE}" "${T}/out/unconfigured.json" "${T}/out/eks-cani.json" || fail "the placeholder ${P} is not reported by the doctor as: ${LINE}"
	fi
done
# the skill pre-approves only table reads of a cluster: no wildcard and no output format after kubectl get (-o yaml or
# json prints a pod's literal env values, and the skill never prints a secret)
grants_table_reads()
{
	# grants_table_reads <SKILL.md>: its kubectl get rules are table reads (no wildcard, no output format in any spelling)
	python3 - "$1" 2>&1 << 'PY'
import re, sys
head = open(sys.argv[1]).read().split("---")[1]
rules = re.findall(r"^\s*-\s*(Bash\(kubectl get [^)]*\))\s*$", head, re.M)
bad = [r for r in rules if "*" in r or re.search(r"\s(-o\S*|--output(=|\s|\)))", r)]
if not rules or bad:
    sys.exit(f"the skill pre-approves kubectl get beyond a table read: {bad or 'no kubectl get rule'}")
PY
}
WHY=$(grants_table_reads "${SKILL}/SKILL.md") || fail "${WHY}"
# PLANTED CONTROL: a rule with the output format joined to its flag (-oyaml) is caught too. The plant must land and the
# refusal must name the planted rule: a plant that misses its line, or a check that cannot read the copy, is no pass
mkdir -p "${T}/skill-planted"
python3 -I - "${SKILL}/SKILL.md" "${T}/skill-planted/SKILL.md" << 'PY' \
	|| fail "PLANTED CONTROL BROKEN: could not plant the -oyaml rule beside Bash(kubectl get pods -A) in a copy of SKILL.md"
import sys
src, dst = sys.argv[1:3]
c = open(src).read()
old = "  - Bash(kubectl get pods -A)\n"
assert c.count(old) == 1, c.count(old)
open(dst, "w").write(c.replace(old, old + "  - Bash(kubectl get pods -A -oyaml)\n"))
PY
WHY=$(grants_table_reads "${T}/skill-planted/SKILL.md") && fail "PLANTED CONTROL BROKEN: a kubectl get rule with -oyaml passes as a table read"
case "${WHY}" in
	*"Bash(kubectl get pods -A -oyaml)"*) ;;
	*) fail "PLANTED CONTROL BROKEN: the check refused the planted copy, but not for its -oyaml rule: ${WHY}" ;;
esac
python3 -I "${SEED_DIR}/scan.py" --tree "${SKILL}" "${AGENT_DIR}/commands/setup.md" "${DOCTOR}" "${AGENT_DIR}/slack-doctor.sh" \
	> "${T}/out/scan.out" 2>&1 || fail "the privacy scan refuses the skill, the command, the doctor or the Slack doctor: $(tail -3 "${T}/out/scan.out" | tr '\n' ';')"
echo "ok 10 - the skill names itself and its triggers, grants the doctor, the reads of its own files and only table reads of a cluster; /setup hands over to it; every file and script it names exists or is reported pending by the doctor; the privacy scan passes ($(tail -1 "${T}/out/scan.out" | cut -c1-40))"

# --- 11. the install: into a Claude configuration at the build and every start, idempotent, the person's own kept ---
I="${T}/claude-install"
mkdir -p "${I}/skills/my-own"
echo "mine" > "${I}/skills/my-own/SKILL.md"
printf '{"theme": "dark", "permissions": {"allow": ["Bash(ls:*)"]}}\n' > "${I}/settings.json"
CLAUDE_CONFIG_DIR="${I}" "${AGENT_DIR}/claude-skills-sync.sh" > "${T}/out/sync1.out" 2>&1 || fail "claude-skills-sync.sh failed: $(tail -2 "${T}/out/sync1.out")"
N=0
while IFS= read -r -d '' F; do
	cmp -s "${AGENT_DIR}/${F#./}" "${I}/${F#./}" || fail "claude-skills-sync.sh did not install ${F#./}"
	N=$((N + 1))
done < <(cd "${AGENT_DIR}" && find ./skills ./commands -type f -print0)
[ "${N}" -ge 8 ] || fail "only ${N} skill and command files to install"
[ "$(cat "${I}/skills/my-own/SKILL.md")" = mine ] || fail "claude-skills-sync.sh changed a skill of the person's own"
CLAUDE_CONFIG_DIR="${I}" "${AGENT_DIR}/claude-skills-sync.sh" > "${T}/out/sync2.out" 2>&1
grep -q ' 0 file(s) written' "${T}/out/sync2.out" || fail "a second claude-skills-sync.sh run wrote files: $(cat "${T}/out/sync2.out")"
# the skill reads its own files, outside the session's working directory /wd: settings.json allows that read, so no
# session asks (a headless call has nobody to answer, the Agent chat page cannot show the question)
python3 -I - "${I}/settings.json" "Read(/${I}/skills/harness-setup/**)" << 'PY' || fail "claude-skills-sync.sh did not allow the skill's own reads in settings.json, or dropped the person's own: $(cat "${I}/settings.json")"
import json, sys
s = json.load(open(sys.argv[1]))
allow = s["permissions"]["allow"]
assert sys.argv[2] in allow and "Bash(ls:*)" in allow and s.get("theme") == "dark", allow
assert allow.count(sys.argv[2]) == 1, allow
PY
cp "${I}/settings.json" "${T}/out/settings.before"
CLAUDE_CONFIG_DIR="${I}" "${AGENT_DIR}/claude-skills-sync.sh" > "${T}/out/sync2b.out" 2>&1
cmp -s "${I}/settings.json" "${T}/out/settings.before" || fail "a second claude-skills-sync.sh run rewrote settings.json"
mkdir -p "${T}/claude-badjson"
printf '{not json\n' > "${T}/claude-badjson/settings.json"
CLAUDE_CONFIG_DIR="${T}/claude-badjson" "${AGENT_DIR}/claude-skills-sync.sh" > "${T}/out/sync-badjson.out" 2>&1 \
	|| fail "claude-skills-sync.sh failed on an unreadable settings.json: $(tail -2 "${T}/out/sync-badjson.out")"
[ "$(cat "${T}/claude-badjson/settings.json")" = "{not json" ] || fail "claude-skills-sync.sh changed an unreadable settings.json"
echo "changed by hand" >> "${I}/skills/harness-setup/prompts/steps.md"
CLAUDE_CONFIG_DIR="${I}" "${AGENT_DIR}/claude-skills-sync.sh" > "${T}/out/sync3.out" 2>&1
cmp -s "${AGENT_DIR}/skills/harness-setup/prompts/steps.md" "${I}/skills/harness-setup/prompts/steps.md" && grep -q ' 1 file(s) written' "${T}/out/sync3.out" \
	|| fail "a changed copy was not restored from the image: $(cat "${T}/out/sync3.out")"
# a file the image stops shipping leaves the configuration at the next sync, and only that file: one the person put
# beside it, and a skill of the person's own, stay
A2="${T}/agent-dropped"
mkdir -p "${A2}"
cp -r "${AGENT_DIR}/skills" "${AGENT_DIR}/commands" "${AGENT_DIR}/claude-skills-sync.sh" "${A2}/"
echo "a prompt the image renames" > "${A2}/skills/harness-setup/prompts/old-name.md"
echo "a command the image drops" > "${A2}/commands/old-command.md"
CLAUDE_CONFIG_DIR="${I}" "${A2}/claude-skills-sync.sh" > "${T}/out/sync4.out" 2>&1
[ -f "${I}/skills/harness-setup/prompts/old-name.md" ] && [ -f "${I}/commands/old-command.md" ] \
	|| fail "claude-skills-sync.sh did not install the two extra files: $(cat "${T}/out/sync4.out")"
echo "mine" > "${I}/skills/harness-setup/prompts/my-note.md"
rm -f "${A2:?}/skills/harness-setup/prompts/old-name.md" "${A2:?}/commands/old-command.md"
CLAUDE_CONFIG_DIR="${I}" "${A2}/claude-skills-sync.sh" > "${T}/out/sync5.out" 2>&1
[ -e "${I}/skills/harness-setup/prompts/old-name.md" ] || [ -e "${I}/commands/old-command.md" ] \
	&& fail "a file the image stopped shipping stays in the configuration: $(cat "${T}/out/sync5.out")"
[ "$(cat "${I}/skills/harness-setup/prompts/my-note.md")" = mine ] && [ "$(cat "${I}/skills/my-own/SKILL.md")" = mine ] \
	|| fail "claude-skills-sync.sh removed a file of the person's own: $(cat "${T}/out/sync5.out")"
grep -q '^"${AGENT_DIR}/claude-skills-sync.sh" ||' "${AGENT_DIR}/claude-settings-sync.sh" \
	|| fail "claude-settings-sync.sh does not run claude-skills-sync.sh"
START=/startup.sh
[ -f "${BASE_DIR%/}/startup.sh" ] && START="${BASE_DIR%/}/startup.sh"
SYNC_AT=$(grep -n '^/agent/claude-settings-sync.sh$' "${START}" | cut -d: -f1)
TMUX_AT=$(grep -n '^	/agent/tmux-session-start.sh$' "${START}" | cut -d: -f1)
[ -n "${SYNC_AT}" ] && [ -n "${TMUX_AT}" ] && [ "${SYNC_AT}" -lt "${TMUX_AT}" ] || fail "${START} does not run claude-settings-sync.sh (the skills step) before the agent's tmux session starts claude (lines ${SYNC_AT:-none}, ${TMUX_AT:-none})"
if [ -f "${BASE_DIR%/}/setup.sh" ]; then
	grep -q '^/agent/claude-settings-sync.sh$' "${BASE_DIR%/}/setup/install-claude-onboarding.sh" \
		&& grep -q '"${CLAUDE_DIR}/skills/harness-setup/SKILL.md" "${CLAUDE_DIR}/commands/setup.md"' "${BASE_DIR%/}/setup.sh" \
		|| fail "the build does not install the skill (install-claude-onboarding.sh runs claude-settings-sync.sh) and check it (setup.sh)"
	BAKED="(a checkout: the build installs and checks it)"
elif [ -f /home/agent/.claude/skills/harness-setup/SKILL.md ] || [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
	cmp -s "${AGENT_DIR}/skills/harness-setup/SKILL.md" "${CLAUDE_CONFIG_DIR:-/home/agent/.claude}/skills/harness-setup/SKILL.md" \
		|| fail "the image's own Claude configuration does not carry the skill: the build did not install it"
	C=${CLAUDE_CONFIG_DIR:-/home/agent/.claude}
	grep -qF "\"Read(/${C}/skills/harness-setup/**)\"" "${C}/settings.json" \
		|| fail "the image's own settings.json does not allow the skill's reads: the build did not add the rule"
	BAKED="(the image's configuration carries it)"
fi
echo "ok 11 - claude-skills-sync.sh installs the ${N} files, keeps the person's own skill, writes nothing on a second run, restores a changed copy, removes a file the image stopped shipping (the person's own kept), allows the skill's reads of its own files in settings.json (the person's own rules kept, an unreadable file left alone); claude-settings-sync.sh runs it, before the agent's session at every start and at the build ${BAKED:-}"

# --- 12. the first turn stays short ---
CASE_ENV=("${UNCONFIGURED[@]}")
run_doctor brief --brief
[ "$(wc -l < "${T}/out/brief.out")" -le 12 ] || fail "--brief printed $(wc -l < "${T}/out/brief.out") lines; the skill's first turn shows it whole"
W=$(awk '{ if (length > m) m = length } END { print m + 0 }' "${T}/out/brief.out")
[ "${W}" -le 80 ] || fail "--brief has a ${W}-character line: the agent's pane is 80 columns until a browser attaches, and a wrapped row doubles the first turn"
CASE_ENV=("${CONFIGURED[@]}" KUBECONFIG="${T}/no-kubeconfig" DOCTOR_EKS_REGIONS="us-east-2 us-east-2 us-east-2")
run_doctor brief-long --brief
W=$(awk '{ if (length > m) m = length } END { print m + 0 }' "${T}/out/brief-long.out")
grep -q '^  eks .* no kubeconfig for demo-cluster (us-east-2)$' "${T}/out/brief-long.out" && grep -q '+2 more' "${T}/wd/setup/doctor.json" \
	&& [ "${W}" -le 80 ] || fail "--brief does not shorten a long finding to the pane, keeping it whole in the JSON (${W} characters): $(grep -m1 '^  eks' "${T}/out/brief-long.out")"
grep -q '^## The first turn: under 20 lines$' "${SKILL}/SKILL.md" || fail "SKILL.md does not bound its first turn"
# the live parts (this check's /setup, check 14's drive) run claude on Bedrock with every tool it calls stubbed, a test
# HOME and the test's own Claude configuration, and without the session's GitHub, Slack and AWS session values: no
# token of the container may reach the model, its transcript or a reply. CANARY values stand in for them here
LH="${T}/live-home"
mkdir -p "${LH}" "${T}/live-work" "${T}/drive-work" "${T}/drive-ui"
CANARY="canary$$$(date +%s)"
export GH_TOKEN="ghp_${CANARY}" GITHUB_TOKEN="ghp_${CANARY}" GITHUB_PERSONAL_ACCESS_TOKEN="ghp_${CANARY}"
export SLACK_BOT_TOKEN="xoxb-${CANARY}" AWS_SESSION_TOKEN="aws${CANARY}" AWS_BEARER_TOKEN_BEDROCK="abt${CANARY}"
live_env()
{
	# live_env <Claude configuration> <setup dir> <command...>: the command in the live parts' environment
	local CFG=$1 SETUP=$2
	shift 2
	env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN -u SLACK_BOT_TOKEN -u SLACK_CHANNELS -u SLACK_TEST_CHANNEL \
		-u AWS_SESSION_TOKEN -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_BEARER_TOKEN_BEDROCK -u AWS_PROFILE \
		PATH="${T}/bin:${PATH}" HOME="${LH}" CLAUDE_CONFIG_DIR="${CFG}" SETUP_DIR="${SETUP}" \
		UI_DIR="${T}/drive-ui" KNOWLEDGE_DIR="${T}/drive-knowledge" GIT_CONFIG_NOSYSTEM=1 STUB_LOG="${T}/stublog" STUB_AWS=ok \
		STUB_CANI=yes UI_STATUS_BIN="${T}/bin/ui-status-up" KUBE_HOST_MOUNT=false HINDSIGHT_API="http://127.0.0.1:${PORT}" \
		HINDSIGHT_SEED_STATE="${T}/wd/ui/hindsight-seed.state" UI_PORT_HEADLAMP="${PORT}" DOCTOR_EKS_REGIONS="us-east-1 us-east-2" \
		SLACK_API_BASE="${SLACK_BASE}" SPOKES_REGISTRY="${T}/no-registry.json" "$@"
}
live_env "${T}/claude-probe" "${T}/probe-setup" env > "${T}/out/live-env.txt" 2>&1
grep -qF -- "${CANARY}" "${T}/out/live-env.txt" && fail "the live parts' environment carries the session's tokens: $(grep -F -- "${CANARY}" "${T}/out/live-env.txt" | cut -d= -f1 | tr '\n' ' ')"
LIVE_NOTE="live check skipped: no answer from claude on Bedrock"
if command -v claude > /dev/null && [ -x /agent/doctor.sh ] \
	&& live_env "${T}/claude-probe" "${T}/probe-setup" timeout 120 claude -p "Reply with exactly: OK" 2>&1 | grep -qw OK; then
	LIVE="${T}/claude-live"
	CLAUDE_CONFIG_DIR="${LIVE}" "${AGENT_DIR}/claude-skills-sync.sh" > /dev/null 2>&1
	(cd "${T}/live-work" && live_env "${LIVE}" "${T}/live-setup" env KUBECONFIG="${T}/no-kubeconfig" DOCTOR_EKS_REGIONS=us-east-1 \
		timeout 400 claude -p "/setup") > "${T}/out/live.out" 2> "${T}/out/live.err"
	[ -f "${T}/live-setup/doctor.json" ] || fail "live: /setup did not run the doctor (no ${T}/live-setup/doctor.json): $(tail -3 "${T}/out/live.out" | tr '\n' ';')"
	LINES=$(grep -c '' "${T}/out/live.out")
	[ "${LINES}" -gt 0 ] && [ "${LINES}" -lt 25 ] || fail "live: the first turn is ${LINES} lines (the bound is under 25): $(head -30 "${T}/out/live.out" | tr '\n' ';')"
	grep -v '^[[:space:]]*$' "${T}/out/live.out" | tail -3 | grep -q '?' || fail "live: the first turn does not end with a question: $(tail -3 "${T}/out/live.out" | tr '\n' ';')"
	[ "$(grep -c '^ *```' "${T}/out/live.out")" -le 4 ] || fail "live: the first turn carries more than two code blocks (a document dump)"
	LIVE_NOTE="live: /setup ran the doctor and answered in ${LINES} lines, ending with a question"
fi
echo "ok 12 - --brief prints $(wc -l < "${T}/out/brief.out") lines of at most 80 characters, a long finding clipped; SKILL.md bounds the first turn; ${LIVE_NOTE}"

# --- 13. one item at a time: configured alone on the unconfigured instance, a check passes and the other eight stay gaps ---
one_item()
{
	# one_item <id> <variables...>: the unconfigured instance plus these variables; <id> PASS and every other check GAP
	local ID=$1
	shift
	CASE_ENV=("${UNCONFIGURED[@]}" "$@")
	run_doctor "alone-${ID}"
	save_json "alone-${ID}"
	python3 - "${T}/out/alone-${ID}.json" "${ID}" << 'PY' || fail "${ID} configured alone: see above"
import json, sys
st = {c["id"]: c["state"] for c in json.load(open(sys.argv[1]))["checks"]}
want = sys.argv[2]
if st.get(want) != "PASS" or any(s != "GAP" for i, s in st.items() if i != want):
    sys.exit(f"{want} configured alone: {st}")
PY
}
one_item bedrock STUB_AWS=ok
one_item git-identity HOME="${T}/home-git" GIT_USER_NAME="Test Person" GIT_USER_EMAIL=test.person@example.com
one_item eks KUBECONFIG="${KUBE_MNT}/config" STUB_CANI=yes UI_PORT_HEADLAMP="${PORT}"
one_item slack SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK
one_item github GH_TOKEN="${PLANT_GH}" STUB_GH_GOOD="${PLANT_GH}"
one_item memory HINDSIGHT_API="http://127.0.0.1:${PORT}"
one_item packages HINDSIGHT_API="http://127.0.0.1:${PORT}" KNOWLEDGE_DIR="${T}/wd/knowledge-pkg" HINDSIGHT_SEED_DIR="${T}/seed-missing"
one_item spokes UI_STATUS_BIN="${T}/bin/ui-status-up"
one_item docker BUILDKIT_HOST="unix://${T}/buildkit.sock" STUB_BUILDKIT=ok BUILD_REGISTRY="127.0.0.1:${PORT}" DOCKER_MIN_FREE_GB=0
echo "ok 13 - one item at a time: each of the nine checks, configured alone on the unconfigured instance, passes while the other eight stay gaps"

# --- 14. the six onboarding questions, driven headless through the skill (LIVE: claude on Bedrock; the tools are stubs) ---
DRIVE_NOTE="live drive skipped: no answer from claude on Bedrock"
[ "${TEST23_DRIVE:-true}" = "false" ] && DRIVE_NOTE="live drive skipped: TEST23_DRIVE=false"
if [ "${TEST23_DRIVE:-true}" != "false" ] && command -v claude > /dev/null && [ -x /agent/doctor.sh ] \
	&& live_env "${T}/claude-probe" "${T}/probe-setup" timeout 120 claude -p "Reply with exactly: OK" 2>&1 | grep -qw OK; then
	DH="${LH}"
	CLAUDE_CONFIG_DIR="${T}/claude-drive" "${AGENT_DIR}/claude-skills-sync.sh" > /dev/null 2>&1
	ASKS=("Hi. I just set this up from a fresh clone of main on my own EC2 instance. What's working, and what do I still need to set up before you can work on my projects?"
		"Use 'Test Person <test.person@example.com>' as my git identity for your commits. Make it stick across container restarts."
		"I'd like to talk to you from Slack too. What do I need to do, step by step?"
		"Connect to my EKS cluster demo-cluster in us-east-2 (read-only for now) and tell me what's on it."
		"A colleague shared a private knowledge package with me: github.com/octo-org/shared-notes. Load it so you know our shared workstreams."
		"Why is the tmux-agent dashboard tile grey, and how do I turn it on?")
	N=0
	for ASK in "${ASKS[@]}"; do
		N=$((N + 1))
		CONT=()
		[ "${N}" -gt 1 ] && CONT=(--continue)
		(cd "${T}/drive-work" && live_env "${T}/claude-drive" "${T}/drive-setup" \
			timeout 400 claude -p "${CONT[@]}" --output-format json "${ASK}") > "${T}/out/drive-${N}.json" 2> "${T}/out/drive-${N}.err"
		python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); open(sys.argv[2],"w").write(str(d.get("result") or ""))' \
			"${T}/out/drive-${N}.json" "${T}/out/drive-${N}.reply" 2>/dev/null || fail "drive ${N}: claude gave no JSON answer: $(tail -3 "${T}/out/drive-${N}.err" | tr '\n' ';')"
	done
	# the Bedrock check probes the model Claude Code calls: AGENT_MODEL from the settings (ANTHROPIC_MODEL in this container's
	# environment, with its [1m] suffix, as Claude Code reports the model it called), or with none Claude Code's own default,
	# which the doctor names (DEFAULT_MODEL) and an upgrade of the unpinned Claude Code can change; then this fails, naming both
	WHY=$(python3 - "${T}/drive-setup/doctor.json" "${T}/out/drive-1.json" 2>&1 << 'PY'
import json, sys
facts = {c["id"]: c for c in json.load(open(sys.argv[1]))["checks"]}.get("bedrock", {}).get("facts", {})
probed, source = facts.get("model"), facts.get("model_source")
usage = json.load(open(sys.argv[2])).get("modelUsage") or {}
used = max(usage, key=lambda m: usage[m].get("outputTokens") or 0) if usage else None
if not probed or not used or probed != used:
    why = "set DEFAULT_MODEL in doctor.sh to it" if source == "default" else "a model fallback, or an alias resolution the doctor does not follow"
    sys.exit(f"the doctor's Bedrock check probes {probed} (source {source}), and Claude Code called {used}: {why}")
PY
	) || fail "drive: ${WHY}"
	R=${T}/out
	reply_has()
	{
		# reply_has <n> <what it shows> <fixed string>...: the reply to ask <n> carries every string
		local N=$1 WHAT=$2
		shift 2
		for S in "$@"; do
			grep -qiF -- "${S}" "${R}/drive-${N}.reply" || fail "drive ${N} (${WHAT}): the reply has no '${S}': $(head -c 600 "${R}/drive-${N}.reply" | tr '\n' ' ')"
		done
	}
	reply_has 1 "the doctor's table and one question" "git-identity" "GAP" "?"
	[ "$(HOME="${DH}" GIT_CONFIG_NOSYSTEM=1 git var GIT_AUTHOR_IDENT 2>/dev/null | sed -E 's/ [0-9]+ [+-][0-9]{4}$//')" = "Test Person <test.person@example.com>" ] \
		|| fail "drive 2: the agent did not set the git identity in the container"
	reply_has 2 "the identity done inside and its host lines" "GIT_USER_NAME" "GIT_USER_EMAIL" ".env.local" "./stop.sh && ./run.sh"
	reply_has 3 "the manifest with its scopes" "channels:history" "groups:history" "im:history" "mpim:history" "channels:read" \
		"users:read" "chat:write"
	[ -f "${DH}/.kube/config" ] || fail "drive 4: the agent did not write the kubeconfig (aws eks update-kubeconfig)"
	reply_has 4 "the cluster read" "team-a"
	reply_has 5 "the token's host lines for the package" "GH_TOKEN" "octo-org/shared-notes"
	reply_has 6 "a live tile and the causes of a grey one" "reload"
	DRIVE_NOTE="live drive: the six questions answered; git identity set and kubeconfig written inside; host lines for git, Slack (the manifest's scopes), GitHub; the cluster read; the grey tile explained"
fi
# no session token reached a live run: the CANARY values are nowhere in their configurations, transcripts or replies
LEAKS=$(grep -rlF -- "${CANARY}" "${T}/claude-probe" "${T}/claude-live" "${T}/claude-drive" "${T}/live-setup" "${T}/drive-setup" \
	"${LH}" "${T}"/out/live.out "${T}"/out/live.err "${T}"/out/drive-* 2>/dev/null)
[ -z "${LEAKS}" ] || fail "a session token reached a live run: $(echo "${LEAKS}" | tr '\n' ' ')"
echo "ok 14 - ${DRIVE_NOTE}"

# --- 15. the shipped Slack doctor itself, against its stub API: its planted controls, and no token on a command line ---
SD="${AGENT_DIR}/slack-doctor.sh"
SD_ENV=()
sd()
{
	# sd <case> [args...]: the Slack doctor with only the case's variables (SD_ENV), its curl calls' argv logged
	local NAME=$1
	shift
	env -i PATH="${T}/bin:/usr/local/bin:/usr/bin:/bin" TMPDIR="${T}/out/sd-tmp" CURL_ARGV_LOG="${T}/out/sd-curl.log" \
		SLACK_API_BASE="${SLACK_BASE}" "${SD_ENV[@]}" "${SD}" "$@" > "${T}/out/sd-${NAME}.out" 2>&1
	echo $? > "${T}/out/sd-${NAME}.rc"
}
sd_has()
{
	# sd_has <case> <rc> <regex>...: the case exited <rc> and its table has a line for each regex
	local NAME=$1 RC=$2
	shift 2
	[ "$(cat "${T}/out/sd-${NAME}.rc")" = "${RC}" ] || fail "slack-doctor ${NAME}: exit $(cat "${T}/out/sd-${NAME}.rc"), expected ${RC}: $(tr '\n' ';' < "${T}/out/sd-${NAME}.out")"
	for RX in "$@"; do
		grep -qE "${RX}" "${T}/out/sd-${NAME}.out" || fail "slack-doctor ${NAME}: no line matches '${RX}': $(tr '\n' ';' < "${T}/out/sd-${NAME}.out")"
	done
}
mkdir -p "${T}/out/sd-tmp"
SD_ENV=(SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK)
sd ok
sd_has ok 0 '^PASS +token ' '^PASS +scopes +every read scope granted' '^PASS +chat:write +granted' '^PASS +channel C_OK ' '^slack-doctor: PASS'
SD_ENV=(SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK,C_NOTIN,C_NOPE SLACK_TEST_CHANNEL=C_OK)
sd post --post-test
sd_has post 1 '^GAP +channel C_NOTIN +not_in_channel' '^GAP +channel C_NOPE +channel_not_found' '^PASS +post-round-trip +posted ts' '^PASS +thread-round-trip +reply ts'
SD_ENV=(SLACK_BOT_TOKEN=xoxb-narrow SLACK_CHANNELS=C_OK)
sd narrow
sd_has narrow 1 '^GAP +scopes +missing scope: channels:history' '^GAP +channel C_OK +missing_scope needed=channels:history' '^PASS +chat:write +not granted'
SD_ENV=(SLACK_BOT_TOKEN=xoxp-someone SLACK_CHANNELS=C_OK)
sd user
sd_has user 1 '^GAP +token +a USER token \(xoxp-\)'
DEAD_PORT=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
# nothing answers: the token row says so and the doctor asks nothing more, since each further request would wait out
# its own timeout for the same reason: one row and one curl call, with three channels named
SD_ENV=(SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK,C_NOTIN,C_NOPE SLACK_API_BASE="http://127.0.0.1:${DEAD_PORT}" CURL_ARGV_LOG="${T}/out/sd-curl-dead.log")
sd dead
sd_has dead 1 "^GAP +token +no answer from http://127\.0\.0\.1:${DEAD_PORT} "
grep -q '000000' "${T}/out/sd-dead.out" && fail "slack-doctor dead port: a doubled HTTP status: $(tr '\n' ';' < "${T}/out/sd-dead.out")"
[ "$(grep -cE '^(PASS|GAP) ' "${T}/out/sd-dead.out")" = 1 ] && [ "$(grep -c '' "${T}/out/sd-curl-dead.log")" = 1 ] \
	|| fail "slack-doctor dead port: $(grep -cE '^(PASS|GAP) ' "${T}/out/sd-dead.out") rows and $(grep -c '' "${T}/out/sd-curl-dead.log") curl calls, expected one no-answer row and one call: $(tr '\n' ';' < "${T}/out/sd-dead.out")"
SD_ENV=(SLACK_CHANNELS=C_OK)
sd notoken
sd_has notoken 1 '^GAP +token +SLACK_BOT_TOKEN is not set .*\.env\.local'
grep -q 'COMMS_ENV_NAMES' "${T}/out/sd-notoken.out" && fail "slack-doctor no token: names COMMS_ENV_NAMES, which the harness's .env does not need for Slack: $(tr '\n' ';' < "${T}/out/sd-notoken.out")"
SD_ENV=(SLACK_BOT_TOKEN="${AWKWARD}" SLACK_CHANNELS=C_OK CURL_ARGV_LOG="${T}/out/sd-curl-awkward.log")
sd awkward
sd_has awkward 0 '^PASS +token +auth.test ok'
[ "$(grep -c '' "${T}/out/sd-curl-awkward.log")" = 3 ] \
	|| fail "slack-doctor awkward token: $(grep -c '' "${T}/out/sd-curl-awkward.log") curl calls, expected 3 (auth.test and C_OK's two reads)"
grep -qF -- "${AWKWARD}" "${T}/out/sd-curl-awkward.log" && fail "slack-doctor put the awkward token on curl's command line"
# a loopback base with a path, the form the harness's other Slack stubs serve, is accepted
SD_ENV=(SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK SLACK_API_BASE="${SLACK_BASE}/api")
sd path
sd_has path 0 '^PASS +token ' '^PASS +channel C_OK ' '^slack-doctor: PASS'
REQUESTS=$(grep -c '' "${T}/out/sd-curl.log")
for TOK in xoxb-full xoxb-narrow xoxp-someone; do
	grep -qF -- "${TOK}" "${T}/out/sd-curl.log" && fail "slack-doctor put the token ${TOK} on curl's command line"
done
[ "${REQUESTS}" -ge 10 ] || fail "slack-doctor made only ${REQUESTS} requests: the argv check saw too little"
[ -z "$(ls -A "${T}/out/sd-tmp")" ] || fail "slack-doctor left temporary files under its TMPDIR: $(ls -A "${T}/out/sd-tmp")"
SD_ENV=(SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK SLACK_API_BASE=http://example.com CURL_ARGV_LOG="${T}/out/sd-curl-third.log")
sd third
sd_has third 2 'refusing http://example.com'
[ -s "${T}/out/sd-curl-third.log" ] && fail "slack-doctor sent a request to a third host before refusing it"
# a loopback base with a user part: curl reads 127.0.0.1 and 1 as a user name and a password, and sends the request,
# the token in its header, to the host after the @
SD_ENV=(SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK SLACK_API_BASE=http://127.0.0.1:1@third.example/api CURL_ARGV_LOG="${T}/out/sd-curl-userinfo.log")
sd userinfo
[ -s "${T}/out/sd-curl-userinfo.log" ] && fail "slack-doctor sent a request through http://127.0.0.1:1@third.example/api, which curl sends to third.example ($(grep -c '' "${T}/out/sd-curl-userinfo.log") curl calls)"
sd_has userinfo 2 'refusing http://127\.0\.0\.1:1@third\.example/api'
# the same with a port on the third host, and with a path or a trailing slash after it: refused before any request
UN=0
for B in "http://127.0.0.1:1@third-host.example:8080" "http://127.0.0.1:1@third-host.example:8080/api" "http://127.0.0.1:1@third-host.example:8080/"; do
	UN=$((UN + 1))
	SD_ENV=(SLACK_BOT_TOKEN=xoxb-full SLACK_CHANNELS=C_OK SLACK_API_BASE="${B}" CURL_ARGV_LOG="${T}/out/sd-curl-userinfo-${UN}.log")
	sd "userinfo-${UN}"
	[ -s "${T}/out/sd-curl-userinfo-${UN}.log" ] && fail "slack-doctor sent $(grep -c '' "${T}/out/sd-curl-userinfo-${UN}.log") request(s) through ${B}, which curl sends to the host after the @"
	sd_has "userinfo-${UN}" 2 "refusing ${B}"
done
echo "ok 15 - the Slack doctor against its stub: all PASS with a full token; not_in_channel, channel_not_found and both round-trips with --post-test; a narrow token names channels:history; a user token is refused; a dead port is one no-answer row and one request; an unset token names .env.local; a token with a quote and a backslash arrives byte for byte; a third host and a loopback base with a user part (also with a port, a path or a trailing slash after it) are refused before any request, a loopback base with a path passes; no token on any of ${REQUESTS} curl command lines, no temporary file left"

echo "Test23 succeeded"
