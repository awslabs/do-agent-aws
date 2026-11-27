#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Sandbox test3 - the compose-demo example on this host's plain Docker Engine:
# the baseline that shows the example's own logic works before any sandbox run.
# Host-side; needs Docker with the compose plugin, curl, python3 and network
# access to Amazon ECR Public (public.ecr.aws/ubuntu/ubuntu:22.04). No sbx, no sign-in, no KVM, no model.
# Each check FAILS if the property it proves is removed:
#    1. run-deterministic.sh passes: build, run, /health from this shell without
#       a published port, 5/5 stack tests for the same instance, down, nothing left
#    2. PLANTED CONTROL: the same stack with a published port is refused at the
#       no-published-ports step
#    3. PLANTED CONTROLS: the same stack with a broken /sum fails at the tests
#       step, and a server that expects a request the tests never make fails at
#       the attest step (the engine's log shows its exit status 3)
#    4. verify-agent-report.py passes a report written by a scripted stand-in for
#       the agent that really ran the stack (no model involved)
#    5. PLANTED CONTROLS: the verifier rejects a wrong nonce, an instance_id no
#       container had, a run outside the window, a container left behind, a run
#       whose tests container never made the check requests (web exits 3), and a
#       run with one failing tests container - each for the expected check only
# Outputs under wd/sandbox-example/<UTC timestamp>/.

BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
EX=${BASE_DIR}/to/sandbox/example/compose-demo
OUT=${BASE_DIR}/wd/sandbox-example/$(date -u +%Y%m%dT%H%M%SZ)
D=$(mktemp -d)
mkdir -p "${OUT}"

cleanup()
{
	for p in sbx-test3-agent sbx-test3-ports sbx-test3-broken sbx-test3-unattested sbx-test3-norequests sbx-test3-onefails; do
		docker compose -p "${p}" -f "${EX}/compose.yaml" down --volumes --remove-orphans > /dev/null 2>&1
	done
	rm -rf "${D}"
}

fail()
{
	echo "Sandbox test3 FAILED: $1"
	cleanup
	exit 1
}

# 1. the deterministic layer on plain Docker
SBX_CONTEXT=host-docker-engine "${EX}/run-deterministic.sh" "${OUT}/deterministic.json" sbx-test3-det > "${OUT}/deterministic.stdout" 2>&1 \
	|| fail "run-deterministic.sh failed: $(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["failed_step"], "-", r["reason"])' "${OUT}/deterministic.json" 2>/dev/null)"
python3 - "${OUT}/deterministic.json" << 'EOF' || fail "deterministic result is not a PASS with 5/5 tests and no published port"
import json, sys
r = json.load(open(sys.argv[1]))
ok = (r["status"] == "PASS" and r["published_ports"] == 0 and r["compose_down"] is True
      and r["tests"]["passed"] == r["expected_checks"] == 5 and r["tests"]["failed"] == 0
      and r["health"]["instance_id"] == r["web_container_hostname"])
sys.exit(0 if ok else 1)
EOF
echo "ok 1 - deterministic layer PASS on Docker $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["engine"]["server_version"])' "${OUT}/deterministic.json") (health via $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["health_probe"])' "${OUT}/deterministic.json"))"

# 2. planted control: a published port
cp -a "${EX}" "${D}/ports"
python3 - "${D}/ports/compose.yaml" << 'EOF'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
c["services"]["web"]["ports"] = ["127.0.0.1:18080:8080"]
yaml.safe_dump(c, open(sys.argv[1], "w"), sort_keys=False)
EOF
"${D}/ports/run-deterministic.sh" "${OUT}/control-ports.json" sbx-test3-ports > /dev/null 2>&1 \
	&& fail "planted control: a stack with a published port passed"
grep -q '"failed_step": "no-published-ports"' "${OUT}/control-ports.json" || fail "planted control ports: wrong failed step"
echo "ok 2 - planted control: a published port is refused at the no-published-ports step"

# 3. planted control: a broken service
cp -a "${EX}" "${D}/broken"
sed -i "s/(\$q{a} + \$q{b})/(\$q{a} + \$q{b} + 1)/" "${D}/broken/app/server.pl"
grep -q '+ 1)' "${D}/broken/app/server.pl" || fail "planted control broken: could not plant the defect"
"${D}/broken/run-deterministic.sh" "${OUT}/control-broken.json" sbx-test3-broken > /dev/null 2>&1 \
	&& fail "planted control: a stack with a broken /sum passed"
grep -q '"failed_step": "tests"' "${OUT}/control-broken.json" || fail "planted control broken: wrong failed step"
cp -a "${EX}" "${D}/unattested"
python3 - "${D}/unattested/app/server.pl" << 'EOF' || fail "planted control unattested: could not plant the defect"
import sys
p = sys.argv[1]
s = open(p).read()
old = "my %CHECK_REQUESTS = ("
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, old + "'/never-requested' => 200, "))
EOF
"${D}/unattested/run-deterministic.sh" "${OUT}/control-unattested.json" sbx-test3-unattested > /dev/null 2>&1 \
	&& fail "planted control: a server whose attestation cannot hold passed"
grep -q '"failed_step": "attest"' "${OUT}/control-unattested.json" || fail "planted control unattested: wrong failed step"
grep -q "web_exit=\['3'\]" "${OUT}/control-unattested.log" || fail "planted control unattested: the web container did not exit 3"
echo "ok 3 - planted controls: a broken /sum fails at the tests step; an unattested run fails at the attest step (web exit 3)"

# 4. the verifier, on a scripted stand-in for the agent
P=sbx-test3-agent
DC=(docker compose -p "${P}" -f "${EX}/compose.yaml")
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
T0=$(date +%s)
"${DC[@]}" --profile test build > "${OUT}/standin.log" 2>&1 || fail "stand-in: build failed"
"${DC[@]}" up -d web >> "${OUT}/standin.log" 2>&1 || fail "stand-in: up failed"
CID=$("${DC[@]}" ps -q web)
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${CID}" | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -1)
H=""
for _ in $(seq 1 30); do
	H=$(curl --noproxy '*' -fsS --max-time 3 "http://${IP}:8080/health" 2>/dev/null) && break
	sleep 1
done
[ -n "${H}" ] || fail "stand-in: no /health answer"
T=$("${DC[@]}" --progress quiet run --rm -T tests 2>> "${OUT}/standin.log" | sed -n 's/^RESULT_JSON //p')
"${DC[@]}" down --volumes --remove-orphans >> "${OUT}/standin.log" 2>&1
python3 - "${NONCE}" "${P}" "${H}" "${T}" "${OUT}/agent-report.json" << 'EOF' || fail "stand-in: could not write the report"
import json, sys
nonce, project, h, t, path = sys.argv[1:6]
h, t = json.loads(h), json.loads(t)
json.dump({"nonce": nonce, "project": project,
           "health": {"status": h["status"], "instance_id": h["instance_id"]},
           "tests": {"passed": t["passed"], "failed": t["failed"]},
           "published_ports": 0, "compose_down": True}, open(path, "w"), indent=2)
EOF
verify()
{
	# $1 = report, $2 = nonce, $3 = since, $4 = verdict name, $5 = project (default P)
	python3 -B "${EX}/verify-agent-report.py" --report "$1" --nonce "$2" --project "${5:-${P}}" --since "$3" \
		--example-dir "${EX}" --verdict "${OUT}/verdict-$4.json" > "${OUT}/verdict-$4.txt" 2>&1
}
only_failed()
{
	# $1 = verdict name, $2 = the one check expected to fail
	python3 - "${OUT}/verdict-$1.json" "$2" << 'EOF'
import json, sys
v = json.load(open(sys.argv[1]))
failed = [c["name"] for c in v["checks"] if not c["ok"]]
sys.exit(0 if failed == [sys.argv[2]] else 1)
EOF
}
standin_report()
{
	# $1 = project, $2 = report path: a report claiming full success for the
	# project's running web container
	local cid host
	cid=$(docker compose -p "$1" -f "${EX}/compose.yaml" ps -q web)
	host=$(docker inspect -f '{{.Config.Hostname}}' "${cid}")
	python3 - "${NONCE}" "$1" "${host}" "$2" << 'EOF'
import json, sys
nonce, project, host, path = sys.argv[1:5]
json.dump({"nonce": nonce, "project": project, "health": {"status": "ok", "instance_id": host},
           "tests": {"passed": 5, "failed": 0}, "published_ports": 0, "compose_down": True},
          open(path, "w"), indent=2)
EOF
}
verify "${OUT}/agent-report.json" "${NONCE}" "${T0}" genuine || fail "the verifier rejected a genuine run: $(grep '^not ok' "${OUT}/verdict-genuine.txt")"
echo "ok 4 - the verifier passes a report that matches the engine's own record"

# 5. planted controls for the verifier
verify "${OUT}/agent-report.json" 0000000000000000 "${T0}" wrong-nonce && fail "verifier accepted a wrong nonce"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); r["health"]["instance_id"]="0123456789ab"; json.dump(r, open(sys.argv[2], "w"))' \
	"${OUT}/agent-report.json" "${OUT}/agent-report-fabricated.json"
verify "${OUT}/agent-report-fabricated.json" "${NONCE}" "${T0}" fabricated && fail "verifier accepted an instance_id no container had"
verify "${OUT}/agent-report.json" "${NONCE}" "$(date +%s)" outside-window && fail "verifier accepted a run outside the window"
"${DC[@]}" up -d web >> "${OUT}/standin.log" 2>&1
verify "${OUT}/agent-report.json" "${NONCE}" "${T0}" left-running && fail "verifier accepted a container left behind"
"${DC[@]}" down --volumes --remove-orphans >> "${OUT}/standin.log" 2>&1
# a tests container that never makes the check requests: web exits 3 on down
P2=sbx-test3-norequests
DC2=(docker compose -p "${P2}" -f "${EX}/compose.yaml")
sleep 1
T2=$(date +%s)
"${DC2[@]}" up -d web >> "${OUT}/standin.log" 2>&1 || fail "control norequests: up failed"
standin_report "${P2}" "${OUT}/agent-report-norequests.json" || fail "control norequests: could not write the report"
"${DC2[@]}" --progress quiet run --rm -T --no-deps --entrypoint true tests >> "${OUT}/standin.log" 2>&1 \
	|| fail "control norequests: the no-op tests container failed"
"${DC2[@]}" down --volumes --remove-orphans >> "${OUT}/standin.log" 2>&1
verify "${OUT}/agent-report-norequests.json" "${NONCE}" "${T2}" norequests "${P2}" \
	&& fail "verifier accepted a run whose tests never made the check requests"
only_failed norequests "events: that web container exited 0 when stopped (it served every check request)" \
	|| fail "control norequests: rejected for the wrong reason: $(grep '^not ok' "${OUT}/verdict-norequests.txt")"
# one failing tests container next to a passing one
P3=sbx-test3-onefails
DC3=(docker compose -p "${P3}" -f "${EX}/compose.yaml")
sleep 1
T3=$(date +%s)
"${DC3[@]}" up -d web >> "${OUT}/standin.log" 2>&1 || fail "control onefails: up failed"
standin_report "${P3}" "${OUT}/agent-report-onefails.json" || fail "control onefails: could not write the report"
"${DC3[@]}" --progress quiet run --rm -T --no-deps --entrypoint false tests >> "${OUT}/standin.log" 2>&1 \
	&& fail "control onefails: the failing tests container exited 0"
"${DC3[@]}" --progress quiet run --rm -T tests >> "${OUT}/standin.log" 2>&1 || fail "control onefails: the real tests failed"
"${DC3[@]}" down --volumes --remove-orphans >> "${OUT}/standin.log" 2>&1
verify "${OUT}/agent-report-onefails.json" "${NONCE}" "${T3}" onefails "${P3}" \
	&& fail "verifier accepted a run with a failing tests container"
only_failed onefails "events: tests containers ran and every one exited 0" \
	|| fail "control onefails: rejected for the wrong reason: $(grep '^not ok' "${OUT}/verdict-onefails.txt")"
echo "ok 5 - planted controls: wrong nonce, fabricated instance_id, run outside the window, a leftover container, tests that never made the check requests and one failing tests container are all rejected"

cleanup
echo "Sandbox test3 succeeded"
