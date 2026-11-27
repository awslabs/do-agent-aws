#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# compose-demo deterministic layer: build, start, probe, test and tear down the
# stack with no model involved, then write one result JSON.
#
#   usage: run-deterministic.sh RESULT_JSON [PROJECT]
#
# Runs unchanged on a plain Docker Engine host (the baseline) and inside a
# Docker Sandbox, against the sandbox's own engine. Needs docker with the
# compose plugin, curl and python3. Exit 0 only when every step passed; any
# failure tears the stack down, writes status FAIL naming the failed step, and
# exits 1. A log of every command's output is written next to the result.
#   1. the stack publishes no port (docker compose config)
#   2. docker compose --profile test build, then docker compose up --build -d
#      web, and the web container is running
#   3. GET /health from inside, without a published port: from this shell to
#      the web container's IP, or, where that address is not routable from the
#      shell, from a one-off container on the project network
#   4. the health instance_id is the web container's hostname (its short id)
#   5. docker compose run --rm -T tests: every check passes, the count is
#      EXPECTED_CHECKS and the tests saw the same instance_id
#   6. docker compose down, and no container of the project is left
#   7. the engine's event log shows the web container exiting 0 on down, which
#      it does only after serving every request the stack tests make, and
#      every tests container of the project exiting 0

set -u -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RESULT="${1:?usage: run-deterministic.sh RESULT_JSON [PROJECT]}"
PROJECT="${2:-compose-demo-det}"
# Keep in sync with the @checks list in app/check.pl.
EXPECTED_CHECKS=5
DC=(docker compose -p "${PROJECT}" -f "${HERE}/compose.yaml")

mkdir -p "$(dirname "${RESULT}")"
LOG="${RESULT%.json}.log"
: > "${LOG}"
STARTED=$(date -u +%FT%TZ)
START_EPOCH=$(date +%s)
STEP=init
ENGINE_VERSION=""
COMPOSE_VERSION=""
PUBLISHED=""
HEALTH_JSON=""
HEALTH_PROBE=""
WEB_HOSTNAME=""
TESTS_JSON=""
DOWN=false

log()
{
	echo "$(date -u +%FT%TZ) $*" | tee -a "${LOG}"
}

write_result()
{
	R_STATUS="$1" R_REASON="$2" R_STEP="${STEP}" R_PROJECT="${PROJECT}" R_STARTED="${STARTED}" \
	R_ENGINE="${ENGINE_VERSION}" R_COMPOSE="${COMPOSE_VERSION}" R_PUBLISHED="${PUBLISHED}" \
	R_HEALTH="${HEALTH_JSON}" R_PROBE="${HEALTH_PROBE}" R_WEB_HOSTNAME="${WEB_HOSTNAME}" \
	R_TESTS="${TESTS_JSON}" R_DOWN="${DOWN}" R_EXPECTED="${EXPECTED_CHECKS}" \
	R_CONTEXT="${SBX_CONTEXT:-unspecified}" python3 - "${RESULT}" << 'EOF'
import datetime, json, os, platform, sys

def parse(text):
    if not text:
        return None
    try:
        return json.loads(text)
    except ValueError:
        return {"unparsed": text}

e = os.environ
result = {
    "layer": "compose-demo-deterministic",
    "status": e["R_STATUS"],
    "reason": e["R_REASON"],
    "failed_step": None if e["R_STATUS"] == "PASS" else e["R_STEP"],
    "project": e["R_PROJECT"],
    "context": e["R_CONTEXT"],
    "started": e["R_STARTED"],
    "finished": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "engine": {"server_version": e["R_ENGINE"], "compose_version": e["R_COMPOSE"], "kernel": platform.release()},
    "published_ports": int(e["R_PUBLISHED"]) if e["R_PUBLISHED"].isdigit() else None,
    "health": parse(e["R_HEALTH"]),
    "health_probe": e["R_PROBE"] or None,
    "web_container_hostname": e["R_WEB_HOSTNAME"] or None,
    "tests": parse(e["R_TESTS"]),
    "expected_checks": int(e["R_EXPECTED"]),
    "compose_down": e["R_DOWN"] == "true",
}
with open(sys.argv[1], "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")
EOF
}

fail()
{
	log "FAIL at ${STEP}: $1"
	"${DC[@]}" down --volumes --remove-orphans >> "${LOG}" 2>&1
	write_result FAIL "$1"
	exit 1
}

STEP=tools
command -v python3 > /dev/null || { echo "run-deterministic.sh: python3 is required" >&2; exit 1; }
ENGINE_VERSION=$(docker version --format '{{.Server.Version}}' 2>> "${LOG}") || fail "no Docker Engine answers (docker version)"
COMPOSE_VERSION=$(docker compose version --short 2>> "${LOG}") || fail "the docker compose plugin is missing"
command -v curl > /dev/null || fail "curl is missing"
log "engine ${ENGINE_VERSION}, compose ${COMPOSE_VERSION}, project ${PROJECT}"

STEP=no-published-ports
CONFIG=$("${DC[@]}" config --format json 2>> "${LOG}") || fail "docker compose config failed"
PUBLISHED=$(echo "${CONFIG}" | python3 -c 'import json,sys; c=json.load(sys.stdin); print(sum(len(s.get("ports") or []) for s in c.get("services", {}).values()))') || fail "could not read the compose config"
[ "${PUBLISHED}" = "0" ] || fail "the stack publishes ${PUBLISHED} port(s); it must publish none"
log "published ports: ${PUBLISHED}"

STEP=build
# Build both service images up front (tests sits behind the "test" profile),
# so no later "run" builds and its stdout carries the container's output only.
"${DC[@]}" --profile test build >> "${LOG}" 2>&1 || fail "docker compose build failed"

STEP=up
"${DC[@]}" up --build -d web >> "${LOG}" 2>&1 || fail "docker compose up --build -d web failed"
CID=$("${DC[@]}" ps -q web 2>> "${LOG}")
[ -n "${CID}" ] || fail "no web container after up"
sleep 2
if [ "$(docker inspect -f '{{.State.Running}}' "${CID}" 2>> "${LOG}")" != "true" ]; then
	docker logs "${CID}" >> "${LOG}" 2>&1
	fail "the web container is not running after up (its log is in ${LOG})"
fi
WEB_HOSTNAME=$(docker inspect -f '{{.Config.Hostname}}' "${CID}" 2>> "${LOG}")
WEB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${CID}" 2>> "${LOG}" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
log "web container ${CID:0:12} hostname ${WEB_HOSTNAME} ip ${WEB_IP:-none}"

STEP=health
if [ -n "${WEB_IP}" ]; then
	for _ in $(seq 1 30); do
		HEALTH_JSON=$(curl --noproxy '*' -fsS --max-time 3 "http://${WEB_IP}:8080/health" 2>> "${LOG}") && break
		HEALTH_JSON=""
		sleep 1
	done
	[ -n "${HEALTH_JSON}" ] && HEALTH_PROBE="this shell -> web container IP ${WEB_IP}:8080"
fi
if [ -z "${HEALTH_JSON}" ]; then
	log "container IP not answering from this shell; probing from a one-off container on the project network"
	HEALTH_JSON=$("${DC[@]}" --progress quiet run --rm -T --no-deps --entrypoint perl tests -e 'use IO::Socket::INET; for (1..30) { my $s = IO::Socket::INET->new(PeerAddr => "web", PeerPort => 8080, Timeout => 3); if ($s) { print $s "GET /health HTTP/1.0\r\nHost: web\r\n\r\n"; local $/; my $r = <$s>; if (defined $r && $r =~ m{^HTTP/\S+ 200} && $r =~ m{\r\n\r\n(.*)\z}s) { print $1; exit 0 } } sleep 1 } exit 1' 2>> "${LOG}") \
		&& HEALTH_PROBE="one-off container on the project network -> web:8080"
fi
[ -n "${HEALTH_JSON}" ] || fail "no answer from the web service's /health within 30 s"
log "health via ${HEALTH_PROBE}: ${HEALTH_JSON}"
HEALTH_ID=$(echo "${HEALTH_JSON}" | python3 -c 'import json,sys; h=json.load(sys.stdin); assert h.get("status") == "ok"; print(h["instance_id"])' 2>> "${LOG}") \
	|| fail "the health answer is not status ok with an instance_id: ${HEALTH_JSON}"
[ "${HEALTH_ID}" = "${WEB_HOSTNAME}" ] || fail "health instance_id '${HEALTH_ID}' is not the web container hostname '${WEB_HOSTNAME}'"

STEP=tests
TESTS_OUT=$("${DC[@]}" --progress quiet run --rm -T tests 2>> "${LOG}")
TESTS_RC=$?
echo "${TESTS_OUT}" >> "${LOG}"
TESTS_JSON=$(echo "${TESTS_OUT}" | sed -n 's/^RESULT_JSON //p' | tail -1)
[ ${TESTS_RC} -eq 0 ] || fail "the stack tests exited ${TESTS_RC}"
[ -n "${TESTS_JSON}" ] || fail "the stack tests printed no RESULT_JSON line"
echo "${TESTS_JSON}" | EXPECTED="${EXPECTED_CHECKS}" HEALTH_ID="${HEALTH_ID}" python3 -c '
import json, os, sys
t = json.load(sys.stdin)
expected = int(os.environ["EXPECTED"])
ok = t.get("total") == expected and t.get("passed") == expected and t.get("failed") == 0 and t.get("instance_id") == os.environ["HEALTH_ID"]
sys.exit(0 if ok else 1)' || fail "the stack tests result is not ${EXPECTED_CHECKS}/${EXPECTED_CHECKS} for instance ${HEALTH_ID}: ${TESTS_JSON}"
log "tests ${TESTS_JSON}"

STEP=down
"${DC[@]}" down --volumes --remove-orphans >> "${LOG}" 2>&1 || fail "docker compose down failed"
LEFT=$(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}" 2>> "${LOG}")
[ -z "${LEFT}" ] || fail "containers of project ${PROJECT} are left after down: ${LEFT}"
DOWN=true

STEP=attest
EVENTS="${LOG%.log}.events.jsonl"
docker events --since "${START_EPOCH}" --until "$(( $(date +%s) + 1 ))" --filter type=container \
	--filter "label=com.docker.compose.project=${PROJECT}" --filter event=die --format '{{json .}}' > "${EVENTS}" 2>> "${LOG}" \
	|| fail "could not read the engine's event log"
ATTEST=$(CID="${CID}" python3 -c '
import json, os, sys
web, tests = [], []
for line in open(sys.argv[1]):
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    a = (ev.get("Actor") or {}).get("Attributes") or {}
    cid = ev.get("id") or (ev.get("Actor") or {}).get("ID", "")
    if a.get("com.docker.compose.service") == "web" and cid.startswith(os.environ["CID"][:12]):
        web.append(a.get("exitCode"))
    elif a.get("com.docker.compose.service") == "tests":
        tests.append(a.get("exitCode"))
ok = web == ["0"] and bool(tests) and all(x == "0" for x in tests)
print(("ok" if ok else "bad") + " web_exit=%s tests_exits=%s" % (web, tests))
' "${EVENTS}")
log "attest: ${ATTEST}"
[ "${ATTEST%% *}" = "ok" ] || fail "the engine's event log does not attest the run (${ATTEST}); web exits 0 on down only after serving every check request"

STEP=finish
write_result PASS "built, started, probed from inside without a published port, tested and torn down"
log "PASS - result ${RESULT}"
exit 0
