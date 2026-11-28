#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Sandbox test4 - the sandbox image as a plain container: a stand-in for the
# microVM on a host without KVM. It checks the IMAGE, not the sandbox: there is
# no microVM, no sbx proxy, no network policy and no credential injection here.
#
#   usage: to/sandbox/test/test4.sh --allow-privileged
#
# RISK, read before running: Docker-in-Docker needs a --privileged container,
# and this one runs the ~11 GB sandbox image, whose build ran upstream
# installers at their latest versions (Container-Root/setup/install-claude.sh,
# harden.sh, install-uv.sh and install-kubectx.sh pin no version). A privileged
# container can reach this host's devices and kernel interfaces. So the test
# refuses to run without --allow-privileged, and for its whole run it blocks the
# EC2 instance metadata service (169.254.169.254, the source of the host's
# instance-role credentials) for the container and for everything it starts:
# the container gets its own Docker network (IPv4 only), and a DOCKER-USER rule
# (sudo iptables) drops that network's traffic to 169.254.169.254. The rule,
# the network, the container and its volume are removed on exit. Run it only on
# a host where a privileged test container is acceptable.
#
# Host-side; needs Docker, passwordless sudo for iptables, and network access
# to Docker Hub. Each check FAILS if the property it proves is removed:
#    0. a probe container on the test network reaches the metadata service
#       before the rule (control; reported if this host blocks it anyway) and
#       does not after it
#    1. the image built by test2.sh (IMAGE, default do-agent-aws-sandbox:local)
#       runs as root in /root/workspace
#    2. the kit's startup hook brings up the image's own Docker Engine, and a
#       second dockerd (the hook racing the runtime's) exits on the held pid file
#    3. the image's /test*.sh suite - what ./test.sh runs, with the repository
#       at HEAD copied to /do-agent-aws where ./test.sh mounts it - passes with
#       the sandbox layer applied and egress limited to the kit's allowlist, as
#       under a deny-all sandbox policy: iptables in the container's own network
#       namespace admit only the allowlisted hosts' addresses (resolved first)
#       on 443, Docker's DNS and loopback; probes show example.com and
#       api.anthropic.com refused and the Bedrock runtime endpoint answering
#       (AWS's 404 for /) before the suite runs (test3 skips: no model
#       credential is passed in). The rules are removed before check 4.
#    4. the compose-demo deterministic layer passes against the inner engine
#    5. the metadata service is unreachable from inside the container and from
#       a container its inner engine starts
# Outputs under wd/sandbox-smoke/<UTC timestamp>/.

BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SBX_DIR=${BASE_DIR}/to/sandbox
IMAGE=${IMAGE:-do-agent-aws-sandbox:local}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME=do-agent-aws-sbx-smoke-${STAMP,,}
NET=${NAME}-net
OUT=${BASE_DIR}/wd/sandbox-smoke/${STAMP}
IMDS=169.254.169.254
SUBNET=""
# The compose-demo base image, which the inner engine pulls in check 4.
PROBE_IMAGE=$(sed -n 's/^FROM \([^ ]*\).*/\1/p' "${SBX_DIR}/example/compose-demo/Dockerfile" | head -1)

if [ "${1:-}" != "--allow-privileged" ]; then
	echo "Sandbox test4 REFUSED: it runs the sandbox image as a --privileged container on this host (see the RISK note at the top of ${0}); rerun with --allow-privileged to accept that"
	exit 2
fi
mkdir -p "${OUT}"

# The DOCKER-USER rule carries a tag naming its network, so a rule left by a
# killed run (its network gone) is found and removed at the next start.
TAG=do-agent-aws-sandbox:test4:${NET}
rule()
{
	# $1 = -I | -C | -D
	sudo -n iptables "$1" DOCKER-USER -s "${SUBNET}" -d "${IMDS}/32" -m comment --comment "${TAG}" -j DROP
}

drop_stale_rules()
{
	local r net
	# iptables -S prints the comment quoted: --comment "do-agent-aws-sandbox:test4:<network>"
	sudo -n iptables -S DOCKER-USER | grep -F -- '"do-agent-aws-sandbox:test4:' | while read -r r; do
		net=$(echo "${r}" | sed -n 's/.*"do-agent-aws-sandbox:test4:\([^" ]*\)".*/\1/p')
		docker network inspect "${net}" > /dev/null 2>&1 && continue
		eval "sudo -n iptables ${r/#-A /-D }"
	done
}

cleanup()
{
	docker rm -f "${NAME}" > /dev/null 2>&1
	docker volume rm "${NAME}-docker" > /dev/null 2>&1
	if [ -n "${SUBNET}" ]; then
		while rule -C 2> /dev/null; do rule -D; done
		rule -C 2> /dev/null && echo "test4 cleanup: the DOCKER-USER rule for ${SUBNET} is still present; remove it with: sudo iptables -D DOCKER-USER -s ${SUBNET} -d ${IMDS}/32 -j DROP"
	fi
	docker network rm "${NET}" > /dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 1' INT TERM

fail()
{
	echo "Sandbox test4 FAILED: $1"
	docker logs "${NAME}" > "${OUT}/container.log" 2>&1
	exit 1
}

imds_probe()
{
	# HTTP status of the metadata service from a throwaway, unprivileged
	# container on the test network (000: no answer). IMDSv2 answers 401 here,
	# no token is requested.
	docker run --rm --network "${NET}" --entrypoint curl "${IMAGE}" -s -o /dev/null -w '%{http_code}' -m 3 "http://${IMDS}/latest/meta-data/" 2> /dev/null
}

docker image inspect "${IMAGE}" > /dev/null 2>&1 || fail "image ${IMAGE} not found (run to/sandbox/test/test2.sh first)"
[ -n "${PROBE_IMAGE}" ] || fail "no FROM image in the compose-demo Dockerfile"
sudo -n iptables -S DOCKER-USER > /dev/null 2>&1 || fail "blocking the metadata service needs passwordless sudo iptables and Docker's DOCKER-USER chain"
drop_stale_rules

# 0. the metadata service, blocked for the test network
docker network create --driver bridge "${NET}" > /dev/null || fail "cannot create network ${NET}"
SUBNET=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${NET}" | tr ' ' '\n' | grep -E '^[0-9.]+/[0-9]+$' | head -1)
[ -n "${SUBNET}" ] || fail "no IPv4 subnet on ${NET}"
BEFORE=$(imds_probe)
rule -I || fail "could not add the DOCKER-USER rule for ${SUBNET}"
AFTER=$(imds_probe)
[ "${AFTER}" = "000" ] || fail "the metadata service still answers (${AFTER}) from ${NET} after the DOCKER-USER rule"
if [ "${BEFORE}" = "000" ]; then
	echo "ok 0 - metadata service unreachable from ${NET} (${SUBNET}); control not shown: this host did not answer even before the rule"
else
	echo "ok 0 - metadata service blocked for ${NET} (${SUBNET}): HTTP ${BEFORE} before the DOCKER-USER rule, no answer after it"
fi

# 1. identity and working directory. The entrypoint is the agent (claude); the
# container idles instead, the way sbx keeps a sandbox up and execs into it.
# --init puts an init at PID 1 that reaps orphaned processes, as the sandbox's
# init does (without it test10's stopped watcher lingers as a zombie under
# "sleep"). /var/lib/docker is a volume, as sbx gives each sandbox one.
docker run -d --init --name "${NAME}" --network "${NET}" --privileged --mount "type=volume,src=${NAME}-docker,dst=/var/lib/docker" \
	--entrypoint sleep "${IMAGE}" infinity > /dev/null || fail "cannot start ${IMAGE}"
ID=$(docker exec "${NAME}" sh -c 'echo "$(id -u) $(pwd)"')
[ "${ID}" = "0 /root/workspace" ] || fail "expected uid 0 in /root/workspace, got '${ID}'"
echo "ok 1 - ${IMAGE} runs as root in /root/workspace"

# 2. the kit's startup hook, as the runtime would run it
HOOK=$(python3 - "${SBX_DIR}/template/do-agent-aws-sandbox.yaml" << 'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
lc = [c for c in d["capabilities"] if c["type"] == "com.docker.sandbox/lifecycle@1"][0]
print(lc["config"]["startup"][0]["command"][2])
EOF
)
[ -n "${HOOK}" ] || fail "no startup hook in the descriptor"
docker exec "${NAME}" sh -c "${HOOK}" || fail "the startup hook failed"
docker exec "${NAME}" sh -c 'i=0; until docker info > /dev/null 2>&1; do i=$((i + 1)); [ $i -lt 60 ] || exit 1; sleep 1; done; docker version --format "{{.Server.Version}}"' > "${OUT}/engine.txt" 2>&1 \
	|| fail "the inner Docker Engine did not come up: $(docker exec "${NAME}" tail -5 /var/log/dockerd.log 2>&1)"
# A second dockerd, as when the hook races the runtime's engine, must exit at once.
docker exec "${NAME}" timeout 30 dockerd > "${OUT}/second-dockerd.log" 2>&1 && fail "a second dockerd kept running next to the first"
grep -qiE 'docker\.pid|pid file' "${OUT}/second-dockerd.log" || fail "a second dockerd did not stop on the held pid file: $(tail -2 "${OUT}/second-dockerd.log")"
docker exec "${NAME}" docker info > /dev/null 2>&1 || fail "the first engine stopped answering after the second dockerd"
echo "ok 2 - the startup hook brought up the inner Docker Engine $(cat "${OUT}/engine.txt"); a second dockerd exits on the held pid file"

# 3. the harness suite, with the repository at HEAD at /do-agent-aws and the
# harness settings ./test.sh passes from .env, under bash as e2e.sh runs it (the
# host launches the agent under bash, which reads BASH_ENV)
mkdir -p "${OUT}/do-agent-aws"
git -C "${BASE_DIR}" archive --format=tar HEAD | tar -xf - -C "${OUT}/do-agent-aws" || fail "could not stage the repository at HEAD"
[ -f "${OUT}/do-agent-aws/.env" ] && [ -f "${OUT}/do-agent-aws/.fun" ] || fail "HEAD lacks .env or .fun"
docker cp "${OUT}/do-agent-aws" "${NAME}:/do-agent-aws" > /dev/null || fail "docker cp of the repository failed"
mapfile -t ENV_ARGS < <(cd "${OUT}/do-agent-aws" && bash -c 'source .env > /dev/null 2>&1; echo "${AUTONOMY_ENV_OPTS} ${AGENT_TMUX_ENV_OPTS} ${SLACK_ENV_OPTS} ${UI_ENV_OPTS} ${COMMS_ENV_OPTS}"' \
	| tr ' ' '\n' | awk 'prev == "-e" && index($0, "=") > 1 {print "-e"; print $0} {prev = $0}')
ALLOW=$(python3 - "${SBX_DIR}/template/do-agent-aws-sandbox.yaml" << 'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
np = [c for c in d["capabilities"] if c["type"] == "com.docker.sandbox/network-policy@1"][0]
print(" ".join(a.rsplit(":", 1)[0] for a in np["config"]["runtime"]["allow"]))
EOF
)
[ -n "${ALLOW}" ] || fail "no allowlist in the descriptor"
docker exec "${NAME}" bash -c 'set -e
	iptables -N SBX-ALLOWLIST
	iptables -A SBX-ALLOWLIST -o lo -j ACCEPT
	iptables -A SBX-ALLOWLIST -d 127.0.0.0/8 -j ACCEPT
	iptables -A SBX-ALLOWLIST -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	for h in "$@"; do
		for ip in $(getent ahostsv4 "$h" | awk "{print \$1}" | sort -u); do
			iptables -A SBX-ALLOWLIST -d "$ip" -p tcp --dport 443 -j ACCEPT
		done
	done
	iptables -A SBX-ALLOWLIST -j REJECT
	iptables -I OUTPUT 1 -j SBX-ALLOWLIST' _ ${ALLOW} > "${OUT}/allowlist-rules.log" 2>&1 || fail "could not limit egress to the allowlist: $(tail -2 "${OUT}/allowlist-rules.log")"
OFF_LIST=$(docker exec "${NAME}" curl -s -o /dev/null -w '%{http_code}' -m 10 https://example.com/ 2> /dev/null)
OFF_ANTHROPIC=$(docker exec "${NAME}" curl -s -o /dev/null -w '%{http_code}' -m 10 https://api.anthropic.com/v1/models 2> /dev/null)
# AWS answers a bare GET of the runtime endpoint with 404 UnknownOperationException
ON_LIST=$(docker exec "${NAME}" curl -s -o /dev/null -w '%{http_code}' -m 10 https://bedrock-runtime.us-east-1.amazonaws.com/ 2> /dev/null)
[ "${OFF_LIST}" = "000" ] && [ "${OFF_ANTHROPIC}" = "000" ] && [ "${ON_LIST}" = "404" ] \
	|| fail "the allowlist emulation is not in effect: example.com answered '${OFF_LIST}' and api.anthropic.com '${OFF_ANTHROPIC}' (expected no answer), bedrock-runtime.us-east-1.amazonaws.com '${ON_LIST}' (expected 404)"
docker exec -w /agent "${ENV_ARGS[@]}" "${NAME}" bash -c 'for t in $(ls /test*.sh); do echo "Running test $t"; $t; echo "EXIT $t $?"; done' > "${OUT}/harness-tests.log" 2>&1
docker exec "${NAME}" bash -c 'iptables -D OUTPUT -j SBX-ALLOWLIST && iptables -F SBX-ALLOWLIST && iptables -X SBX-ALLOWLIST' >> "${OUT}/allowlist-rules.log" 2>&1 \
	|| fail "could not remove the allowlist rules"
"${SBX_DIR}/test/harness-verdict.sh" "${OUT}/harness-tests.log" absent > "${OUT}/harness-verdict.txt" 2>&1 \
	|| fail "harness suite under the allowlist: $(grep FAILED "${OUT}/harness-verdict.txt" | tr '\n' ' ')"
echo "ok 3 - harness suite in the sandbox image, egress limited to the allowlist (${ALLOW}): $(tr '\n' ';' < "${OUT}/harness-verdict.txt")"

# 4. the example against the inner engine
docker cp "${OUT}/do-agent-aws/to/sandbox/example/compose-demo" "${NAME}:/root/workspace/" || fail "docker cp of the example failed"
docker exec -e SBX_CONTEXT=container-stand-in "${NAME}" bash /root/workspace/compose-demo/run-deterministic.sh /root/workspace/out/compose-demo-deterministic.json compose-demo-det > "${OUT}/example.stdout" 2>&1
RC=$?
docker cp "${NAME}:/root/workspace/out/." "${OUT}/" > /dev/null 2>&1
[ ${RC} -eq 0 ] || fail "compose-demo deterministic layer failed inside the image: $(tail -3 "${OUT}/example.stdout")"
echo "ok 4 - compose-demo deterministic layer passes against the inner engine ($(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("health via", r["health_probe"])' "${OUT}/compose-demo-deterministic.json"))"

# 5. the metadata service from inside: the container, and a container its
# engine starts (perl core only; the image was pulled in check 4)
INSIDE=$(docker exec "${NAME}" curl -s -o /dev/null -w '%{http_code}' -m 3 "http://${IMDS}/latest/meta-data/" 2> /dev/null)
NESTED=$(docker exec "${NAME}" docker run --rm --entrypoint perl "${PROBE_IMAGE}" -MIO::Socket::INET \
	-e 'my $s = IO::Socket::INET->new(PeerAddr => $ARGV[0], PeerPort => 80, Timeout => 3); print $s ? "open" : "blocked";' "${IMDS}" 2> "${OUT}/nested-probe.err")
[ "${INSIDE}" = "000" ] || fail "the metadata service answers (${INSIDE}) from inside the privileged container"
[ "${NESTED}" = "blocked" ] || fail "the metadata service is reachable (${NESTED:-no output}) from a container the inner engine starts: $(head -c 200 "${OUT}/nested-probe.err")"
echo "ok 5 - metadata service unreachable from inside the container and from a container its engine starts"

echo "Sandbox test4 succeeded"
