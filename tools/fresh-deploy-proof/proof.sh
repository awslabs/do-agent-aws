#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Fresh-deploy proof of a pushed branch on a SEPARATE Docker host (one that has never seen the image): a clean
# `git clone` of the pushed commit, ./build.sh, ./run.sh, every home tile fetched through 127.0.0.1:8000 the way a
# browser does, neighbour-container exposure controls, the whole ./test.sh, the seed counts, persistence across
# ./stop.sh && ./run.sh - every output kept as an evidence file. Runs from a checkout on the driving host; everything
# on the proof host happens under PROOF_DIR. It touches only the clone it made and the containers/networks it created
# (all named do-agent-aws or ado-proof-*); nothing else on the proof host.
#
# Settings (environment):
#   PROOF_HOST        ssh destination of the proof host (required; passwordless ssh, sudo -n, docker, git, tmux, curl, python3)
#   PROOF_DIR         directory on the proof host (default ~/ado-proof): <PROOF_DIR>/do-agent-aws is the clone, <PROOF_DIR>/evidence the output
#   PROOF_BRANCH      the branch to prove (default: the checkout's current branch); it must be pushed - the clone is made from a
#                     bundle of the local branch and its sha is compared with GitHub's
#   PROOF_REPO        owner/name on GitHub (default: from the origin remote)
#   PROOF_AWS_ENV     environment prefix for ./build.sh, ./run.sh and ./test.sh on the proof host, e.g. "AWS_PROFILE=bedrock
#                     AWS_REGION=us-east-1" (default: AWS_REGION=us-east-1 - an instance role needs nothing else)
#   PROOF_IMAGE       the image ./build.sh produces on the proof host (default do-agent-aws:latest, the .env default)
#
#   proof.sh archive <n>          # move the previous run's evidence aside (proof host and local) as evidence-run<n>
#   proof.sh bundle               # stop the previous run's harness (only this clone's), re-clone the pushed branch, verify the sha
#   proof.sh build                # ./build.sh on the proof host (tmux session ado-proof-build; log kept)
#   proof.sh build-control        # the same tree with an impossible build arg: the build must FAIL (a failed installer fails the build)
#   proof.sh run                  # ./run.sh, wait for the home page, status, every tile followed like a browser (rc file 20-run-rc.txt)
#   proof.sh hostcheck            # Host allowlist and dot probes on the live deployment
#   proof.sh neighbour            # a container on the same bridge tries every backend and the home port
#   proof.sh neighbour2           # a second harness on a user-defined network (its gateway must be admitted, a neighbour refused)
#   proof.sh neighbour3           # a custom-gateway network with a neighbour holding .1 (only the gateway is admitted)
#   proof.sh routemove            # docker network connect/disconnect on the running harness: the route watcher follows
#   proof.sh llpages before|after # the LogLearner pages, projects and the running server's index path (27b); set
#                                 # LL_LEAK_NEEDLE=<a name that must not appear> in the environment for the hit count
#   proof.sh wdbefore | wdafter   # wd/ listing + LogLearner index content around ./test.sh (34-36)
#   proof.sh tests                # ./test.sh on the proof host (tmux session ado-proof-test; rc file 32-test-rc.txt)
#   proof.sh seed                 # seed status and per-bank stats (after the extraction queue drained)
#   proof.sh persist              # ./stop.sh && ./run.sh, bank counts before and after
#   proof.sh persistafter         # UI status, seed view, volumes after the restart (55-57)
#   proof.sh collect              # pull the evidence directory back under tools/fresh-deploy-proof/evidence (gitignored)
#   proof.sh down                 # ./stop.sh on the proof host (the clone and evidence stay)
# run-all.sh runs the whole sequence after `bundle` and `build`, stops at the first failed step and reports from the rc files.

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "${HERE}/../.." && pwd)
HOST=${PROOF_HOST:?PROOF_HOST: the ssh destination of the proof host}
BRANCH=${PROOF_BRANCH:-$(git -C "${REPO}" rev-parse --abbrev-ref HEAD)}
REMOTE_DIR=${PROOF_DIR:-'~/ado-proof'}
PROOF_REPO=${PROOF_REPO:-$(git -C "${REPO}" remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')}
PROOF_AWS_ENV=${PROOF_AWS_ENV:-AWS_REGION=us-east-1}
PROOF_IMAGE=${PROOF_IMAGE:-do-agent-aws:latest}
STEP=${1:?step (see the header)}

remote() { ssh -o BatchMode=yes "${HOST}" "$@"; }
# remote_script <script under remote/> [args] - run a helper script on the remote, in the clone directory, from stdin
remote_script() { local S=$1; shift; ssh -o BatchMode=yes "${HOST}" "cd ${REMOTE_DIR}/do-agent-aws && bash -s -- $*" < "${HERE}/remote/${S}"; }

case "${STEP}" in
archive)
	N=${2:?run number of the evidence being moved aside}
	remote "cd ${REMOTE_DIR:?} && [ -d evidence ] && [ ! -e evidence-run${N:?} ] && mv evidence evidence-run${N:?} && mkdir evidence && echo \"remote evidence -> evidence-run${N}\" || { echo 'remote: nothing to archive or the target exists' >&2; exit 1; }"
	if [ -d "${HERE}/evidence" ]; then [ ! -e "${HERE}/evidence-run${N}" ] || { echo "local: evidence-run${N} exists" >&2; exit 1; }; mv "${HERE:?}/evidence" "${HERE:?}/evidence-run${N:?}" && echo "local evidence -> evidence-run${N}"; else echo "local: no evidence directory to archive (first run from this checkout)"; fi
	;;
llpages)
	remote_script llpages.sh "${2:?before|after}" "${LL_LEAK_NEEDLE:-}"
	;;
wdbefore)
	remote_script wdlist.sh before
	;;
wdafter)
	remote_script wdlist.sh after
	;;
persistafter)
	remote_script persist-after.sh
	;;
bundle)
	SHA=$(git -C "${REPO}" rev-parse "${BRANCH}")
	PUSHED=$(gh api "repos/${PROOF_REPO}/branches/${BRANCH}" --jq .commit.sha)
	[ "${SHA}" == "${PUSHED}" ] || { echo "local ${BRANCH} ${SHA} != pushed ${PUSHED}: push first" >&2; exit 1; }
	BUNDLE=${HERE}/do-agent-aws-${SHA:0:7}.bundle
	git -C "${REPO}" bundle create "${BUNDLE}" "${BRANCH}"
	# The previous run's harness container must be gone BEFORE its clone directory is wiped: a re-clone
	# deletes /wd under the previous run's still-running container (its home page goes 404) and ./run.sh then fails
	# on the container name. ./stop.sh of the previous clone when it is there; otherwise a container of that name is
	# removed ONLY when its mounts show it is this proof clone's (anything else on the host is left alone).
	remote "cd ${REMOTE_DIR} 2>/dev/null || exit 0; if [ -x do-agent-aws/stop.sh ]; then (cd do-agent-aws && ./stop.sh > /dev/null 2>&1); echo 'previous clone: ./stop.sh run'; fi; \
		if docker container inspect do-agent-aws > /dev/null 2>&1; then M=\$(docker container inspect -f '{{range .Mounts}}{{.Source}} {{end}}' do-agent-aws); case \"\$M\" in *\"\$(pwd)/do-agent-aws/\"*) docker rm -f -v do-agent-aws > /dev/null && echo 'previous harness container removed (this proof clone owned it)';; *) echo \"a container named do-agent-aws is NOT this proof clone's (mounts: \$M) - refusing to remove it\" >&2; exit 1;; esac; fi; \
		docker ps --format '{{.Names}}' | grep -qx do-agent-aws && { echo 'a harness container is still running' >&2; exit 1; }; exit 0"
	# sudo: the previous run's wd/agent-state carries files the container wrote as root and as uid 1000
	remote "mkdir -p ${REMOTE_DIR:?}/evidence && sudo -n rm -rf ${REMOTE_DIR:?}/do-agent-aws"
	scp -q "${BUNDLE}" "${HOST}:${REMOTE_DIR}/"
	remote "cd ${REMOTE_DIR} && git clone -q -b ${BRANCH} $(basename "${BUNDLE}") do-agent-aws && cd do-agent-aws \
		&& echo clone HEAD \$(git rev-parse HEAD) && git status --short --branch | head -3 \
		&& { echo \"clone_sha=\$(git rev-parse HEAD)\"; echo \"pushed_sha=${PUSHED}\"; echo \"bundle=$(basename "${BUNDLE}")\"; date -u +%FT%TZ; } > ../evidence/00-clone.txt"
	remote "cd ${REMOTE_DIR}/do-agent-aws && [ \"\$(git rev-parse HEAD)\" == \"${PUSHED}\" ] && echo 'clone sha == pushed sha OK'"
	;;
build)
	remote "cd ${REMOTE_DIR}/do-agent-aws && tmux kill-session -t ado-proof-build 2>/dev/null; \
		tmux new-session -d -s ado-proof-build \"export ${PROOF_AWS_ENV}; date -u +%FT%TZ > ../evidence/10-build-start.txt; ./build.sh > ../evidence/11-build.log 2>&1; echo rc=\\\$? > ../evidence/12-build-rc.txt; date -u +%FT%TZ >> ../evidence/12-build-rc.txt\""
	echo "build started in tmux ado-proof-build on ${HOST}; poll with: ssh ${HOST} 'tail -3 ${REMOTE_DIR}/evidence/11-build.log; cat ${REMOTE_DIR}/evidence/12-build-rc.txt'"
	;;
build-control)
	# a failed installer must fail the build: the same tree with an impossible hindsight coding-agents version
	# (a build arg); expected rc != 0 with setup.sh's "FAILED - required components missing" line in the log
	remote "cd ${REMOTE_DIR}/do-agent-aws && tmux kill-session -t ado-proof-bctl 2>/dev/null; \
		tmux new-session -d -s ado-proof-bctl \"date -u +%FT%TZ > ../evidence/13-build-control.txt; docker image build --progress plain --build-arg HINDSIGHT_CODING_AGENTS_VERSION=9.9.9 -t do-agent-aws:build-control . > ../evidence/14-build-control.log 2>&1; RC=\\\$?; { echo rc=\\\$RC; grep -E 'setup.sh: (FAILED|all required)|install-hindsight.sh|No matching version|ERR!' ../evidence/14-build-control.log | tail -5; date -u +%FT%TZ; } >> ../evidence/13-build-control.txt; docker image rm do-agent-aws:build-control > /dev/null 2>&1\""
	echo "build control started in tmux ado-proof-bctl on ${HOST}; poll with: ssh ${HOST} 'cat ${REMOTE_DIR}/evidence/13-build-control.txt'"
	;;
run)
	remote "cd ${REMOTE_DIR}/do-agent-aws && export ${PROOF_AWS_ENV} && E=../evidence && \
		./run.sh > \$E/20-run.log 2>&1; RC=\$?; { echo rc=\$RC; date -u +%FT%TZ; } > \$E/20-run-rc.txt; \
		{ [ \$RC -eq 0 ] && docker ps --format '{{.Names}} {{.Status}}' | grep -q '^do-agent-aws Up'; } || { echo 'run.sh FAILED:'; tail -3 \$E/20-run.log; exit 1; }; \
		for i in \$(seq 1 90); do curl -sf -o /dev/null http://127.0.0.1:8000/ && break; sleep 2; done; \
		sleep 60; docker exec do-agent-aws /agent/ui-status.sh > \$E/21-ui-status.txt 2>&1; cat \$E/21-ui-status.txt; \
		curl -s http://127.0.0.1:8000/ > \$E/22-home.html; \
		{ for u in \$(grep -o 'data-url=\"[^\"]*\"' \$E/22-home.html | cut -d'\"' -f2); do printf '%s %s\n' \"\$(curl -s -L --max-redirs 10 -o /dev/null -w '%{http_code} (final, %{num_redirects} redirects)' --max-time 20 http://127.0.0.1:8000\$u)\" \"\$u\"; done; \
		  for h in \$(grep -o 'data-host=\"[^\"]*\"' \$E/22-home.html | cut -d'\"' -f2); do printf '%s %s.localhost/\n' \"\$(curl -s -L --max-redirs 10 -o /dev/null -w '%{http_code} (final, %{num_redirects} redirects)' --max-time 20 -H \"Host: \$h.localhost:8000\" http://127.0.0.1:8000/)\" \"\$h\"; done; \
		  for hp in \$(grep -oE 'data-host=\"[^\"]*\" data-probe=\"[^\"]*\" data-path=\"[^\"]+\"' \$E/22-home.html | sed -E 's/data-host=\"([^\"]*)\".*data-path=\"([^\"]*)\"/\\1|\\2/'); do h=\${hp%%|*}; pth=\${hp#*|}; printf '%s %s.localhost%s (deep link, %s bytes)\n' \"\$(curl -s -L --max-redirs 10 -o \$E/deep-\$h.html -w '%{http_code} (final, %{num_redirects} redirects)' --max-time 20 -H \"Host: \$h.localhost:8000\" \"http://127.0.0.1:8000\$pth\")\" \"\$h\" \"\$pth\" \"\$(wc -c < \$E/deep-\$h.html)\"; done; \
		  printf 'memory UI bank view carries the bank id: %s occurrence(s) of harness-knowledge\n' \"\$(grep -c harness-knowledge \$E/deep-hindsight.html 2>/dev/null)\"; \
		  for h in \$(grep -o 'data-host=\"[^\"]*\"' \$E/22-home.html | cut -d'\"' -f2); do printf 'browser-like %s.localhost:8000/ -> first hop %s, Location %s; followed on its own host: final %s at %s\\n' \"\$h\" \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve \$h.localhost:8000:127.0.0.1 http://\$h.localhost:8000/)\" \"\$(curl -s -D - -o /dev/null --max-time 10 --resolve \$h.localhost:8000:127.0.0.1 http://\$h.localhost:8000/ | grep -i '^location:' | cut -d' ' -f2- | tr -d '\\r')\" \"\$(curl -s -L --max-redirs 8 -o /dev/null -w '%{http_code}' --max-time 20 --resolve \$h.localhost:8000:127.0.0.1 http://\$h.localhost:8000/)\" \"\$(curl -s -L --max-redirs 8 -o /dev/null -w '%{url_effective}' --max-time 20 --resolve \$h.localhost:8000:127.0.0.1 http://\$h.localhost:8000/)\"; done; \
		  printf 'curl -L with the Host header through 127.0.0.1 (the case of a browser behind the tunnel): hindsight root -> %s\\n' \"\$(curl -s -L --max-redirs 5 -o /dev/null -w '%{http_code} at %{url_effective}' --max-time 20 -H 'Host: hindsight.localhost:8000' --resolve hindsight.localhost:8000:127.0.0.1 http://127.0.0.1:8000/)\"; } | tee \$E/23-tiles.txt; \
		grep -o '<li class=\"tile off[^\"]*\">.*</li>' \$E/22-home.html | sed 's/<[^>]*>/ /g' | tr -s ' ' > \$E/24-grey-tiles.txt; cat \$E/24-grey-tiles.txt"
	;;
hostcheck)
	# the live Host allowlist and the status probes: a foreign Host on the main routes and a probe (421), the
	# loopback name (200), every probe GET with a planted cookie (204, empty body) and POST (403)
	remote "cd ${REMOTE_DIR}/do-agent-aws && { for p in / /tmux/ /headlamp/ /memory-api/docs /__probe/kanban; do printf 'evil Host %-20s -> %s\n' \$p \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: evil.example' http://127.0.0.1:8000\$p)\"; done; \
		printf 'localhost Host /tmux/   -> %s\n' \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: localhost:8000' http://127.0.0.1:8000/tmux/)\"; \
		for n in hindsight kanban claude-mem loglearner; do printf 'probe %-12s GET -> %s  POST -> %s\n' \$n \"\$(curl -s -o /dev/null -w '%{http_code} %{size_download}' --max-time 5 -H 'Cookie: planted=1' http://127.0.0.1:8000/__probe/\$n)\" \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST http://127.0.0.1:8000/__probe/\$n)\"; done; } | tee ../evidence/25-host-allowlist-and-probes.txt"
	;;
tests)
	remote "cd ${REMOTE_DIR}/do-agent-aws && export ${PROOF_AWS_ENV} && tmux kill-session -t ado-proof-test 2>/dev/null; \
		tmux new-session -d -s ado-proof-test \"export ${PROOF_AWS_ENV}; date -u +%FT%TZ > ../evidence/30-test-start.txt; ./test.sh > ../evidence/31-test.log 2>&1; echo rc=\\\$? > ../evidence/32-test-rc.txt; date -u +%FT%TZ >> ../evidence/32-test-rc.txt\""
	echo "tests started in tmux ado-proof-test; poll with: ssh ${HOST} 'grep -E \"^Running test|succeeded|FAILED|skipped\" ${REMOTE_DIR}/evidence/31-test.log; cat ${REMOTE_DIR}/evidence/32-test-rc.txt'"
	;;
seed)
	remote "cd ${REMOTE_DIR}/do-agent-aws && E=../evidence && docker exec do-agent-aws /agent/hindsight-seed.sh --status > \$E/40-seed-status.txt 2>&1; cat \$E/40-seed-status.txt; \
		for b in harness-knowledge loglearner-rules; do printf '%s ' \$b; curl -s http://127.0.0.1:8000/memory-api/v1/default/banks/\$b/stats | python3 -c 'import sys,json; d=json.load(sys.stdin); print(\"documents\", d[\"total_documents\"], \"nodes\", d[\"total_nodes\"], \"pending\", d[\"pending_operations\"], \"failed\", d[\"failed_operations\"])'; done | tee \$E/41-seed-stats.txt"
	;;
persist)
	remote "cd ${REMOTE_DIR}/do-agent-aws && export ${PROOF_AWS_ENV} && E=../evidence && \
		docker volume ls -qf dangling=true | wc -l > \$E/56-volumes-before.txt; \
		curl -s http://127.0.0.1:8000/memory-api/v1/default/banks > \$E/50-banks-before.json; \
		./stop.sh > \$E/51-stop.log 2>&1; ./run.sh > \$E/52-run-again.log 2>&1; \
		for i in \$(seq 1 90); do curl -sf -o /dev/null http://127.0.0.1:8000/memory-api/health && break; sleep 2; done; sleep 5; \
		curl -s http://127.0.0.1:8000/memory-api/v1/default/banks > \$E/53-banks-after.json; \
		python3 - \$E/50-banks-before.json \$E/53-banks-after.json << 'EOF' | tee \$E/54-persist.txt
import json,sys
b={x['bank_id']:x['fact_count'] for x in json.load(open(sys.argv[1]))['banks']}
a={x['bank_id']:x['fact_count'] for x in json.load(open(sys.argv[2]))['banks']}
print('before', b); print('after ', a); print('PERSIST OK' if b and a==b else 'PERSIST MISMATCH')
EOF
		cat \$E/50-banks-before.json | head -c 300"
	;;
neighbour)
	# a throwaway container on the same default bridge (the harness image itself, it has curl) tries every
	# backend port and the home port of the harness container by its bridge address; then the host publish
	remote "cd ${REMOTE_DIR}/do-agent-aws && IP=\$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' do-agent-aws) && { echo \"harness bridge address \$IP\"; \
		for p in 7681 4466 8081 8502 8888 9999 7337 37700 7777 8000; do C=\$(docker run --rm --entrypoint sh ${PROOF_IMAGE} -c \"curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://\$IP:\$p/\" 2>/dev/null); [ \"\$C\" == \"000\" ] && C=refused; printf 'neighbour -> :%-5s %s\n' \$p \"\$C\"; done; \
		C=\$(docker run --rm --entrypoint sh ${PROOF_IMAGE} -c \"curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: localhost:8000' http://\$IP:8000/\" 2>/dev/null); printf 'neighbour -> :8000 with a loopback Host header %s (the source rule; the bare address above is the Host allowlist)\n' \"\$C\"; \
		printf 'host publish 127.0.0.1:8000/ -> %s\n' \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8000/)\"; } | tee ../evidence/26-neighbour.txt"
	;;
neighbour2)
	# the sidecar case, measured in testing: a harness attached to a user-defined network gets its published
	# port's traffic from THAT network's gateway. A second harness container from the same image, primary network
	# ado-proof-net2, ephemeral state, published on 127.0.0.1:8001: the host publish must answer 200 (gateway
	# admitted) and a neighbour on net2 must still be refused (421 bare address / 403 loopback Host)
	remote "cd ${REMOTE_DIR}/do-agent-aws && source .env > /dev/null 2>&1; docker rm -f ado-proof-n2 > /dev/null 2>&1; docker network rm ado-proof-net2 > /dev/null 2>&1; docker network create ado-proof-net2 > /dev/null && \
		docker run -d --name ado-proof-n2 --network ado-proof-net2 -p 127.0.0.1:8001:8000 -e AWS_REGION=us-east-1 \${UI_ENV_OPTS} -e HINDSIGHT_SEED=false ${PROOF_IMAGE} > /dev/null && \
		for i in \$(seq 1 120); do curl -sf -o /dev/null http://127.0.0.1:8001/ && break; sleep 2; done; \
		{ echo \"second harness on user network ado-proof-net2: \$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} gw {{.Gateway}}{{end}}' ado-proof-n2)\"; \
		  echo \"allow lines rendered: \$(docker exec ado-proof-n2 sh -c 'grep -E \"^\\s*allow \" /wd/ui/home/nginx.conf | tr -s \" \\t\\n\" \" \"')\"; \
		  printf 'host publish 127.0.0.1:8001/ -> %s (traffic from the user network gateway)\\n' \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8001/)\"; \
		  printf 'host publish 127.0.0.1:8001/tmux/ -> %s\\n' \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8001/tmux/)\"; \
		  IP2=\$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ado-proof-n2); \
		  printf 'neighbour on net2 -> :8000 bare address %s\\n' \"\$(docker run --rm --network ado-proof-net2 --entrypoint sh ${PROOF_IMAGE} -c \"curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://\$IP2:8000/\" 2>/dev/null)\"; \
		  printf 'neighbour on net2 -> :8000 loopback Host %s\\n' \"\$(docker run --rm --network ado-proof-net2 --entrypoint sh ${PROOF_IMAGE} -c \"curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: localhost:8000' http://\$IP2:8000/\" 2>/dev/null)\"; \
		  C=\$(docker run --rm --network ado-proof-net2 --entrypoint sh ${PROOF_IMAGE} -c \"curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://\$IP2:7681/\" 2>/dev/null); [ \"\$C\" == \"000\" ] && C=refused; printf 'neighbour on net2 -> :7681 (terminal) %s\\n' \"\$C\"; } | tee ../evidence/27-neighbour-user-network.txt; \
		docker rm -f ado-proof-n2 > /dev/null 2>&1; docker network rm ado-proof-net2 > /dev/null 2>&1; echo cleaned"
	;;
neighbour3)
	# the custom-gateway control, a planted network: 172.31.251.0/24 with gateway .254; a neighbour
	# started FIRST holds .1; a second harness on that network (primary) gets .2. The host publish must answer
	# 200 and the neighbour at .1 must be refused on /, /tmux/ and the terminal websocket (403, never 101)
	remote "cd ${REMOTE_DIR}/do-agent-aws && source .env > /dev/null 2>&1; docker rm -f ado-proof-n3 ado-proof-nb3 > /dev/null 2>&1; docker network rm ado-proof-net3 > /dev/null 2>&1; \
		docker network create --subnet 172.31.251.0/24 --gateway 172.31.251.254 ado-proof-net3 > /dev/null && \
		docker run -d --name ado-proof-nb3 --network ado-proof-net3 --entrypoint sh ${PROOF_IMAGE} -c 'sleep 3600' > /dev/null && \
		docker run -d --name ado-proof-n3 --network ado-proof-net3 -p 127.0.0.1:8002:8000 -e AWS_REGION=us-east-1 \${UI_ENV_OPTS} -e HINDSIGHT_SEED=false ${PROOF_IMAGE} > /dev/null && \
		for i in \$(seq 1 120); do curl -sf -o /dev/null http://127.0.0.1:8002/ && break; sleep 2; done; \
		{ echo \"custom-gateway network: neighbour \$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ado-proof-nb3), harness \$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} gw {{.Gateway}}{{end}}' ado-proof-n3)\"; \
		  echo \"harness default route: \$(docker exec ado-proof-n3 ip -4 route show default)\"; \
		  echo \"allow lines rendered: \$(docker exec ado-proof-n3 sh -c 'grep -E \"^\\s*allow \" /wd/ui/home/nginx.conf | tr -s \" \\t\\n\" \" \"')\"; \
		  printf 'host publish 127.0.0.1:8002/ -> %s\\n' \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8002/)\"; \
		  IP3=\$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ado-proof-n3); \
		  WSKEY=\$(head -c 16 /dev/urandom | base64); \
		  printf 'neighbour at .1 -> :8000 / (Host localhost) %s\\n' \"\$(docker exec ado-proof-nb3 curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: localhost:8000' http://\$IP3:8000/)\"; \
		  printf 'neighbour at .1 -> :8000 /tmux/ (Host localhost) %s\\n' \"\$(docker exec ado-proof-nb3 curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: localhost:8000' http://\$IP3:8000/tmux/)\"; \
		  printf 'neighbour at .1 -> :8000 /tmux/ws websocket upgrade %s (403 expected, never 101)\\n' \"\$(docker exec ado-proof-nb3 curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: localhost:8000' -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H \"Sec-WebSocket-Key: \$WSKEY\" http://\$IP3:8000/tmux/ws)\"; \
		  printf 'neighbour at .1 -> :8000 /memory-api/v1/default/banks (Host localhost) %s\\n' \"\$(docker exec ado-proof-nb3 curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: localhost:8000' http://\$IP3:8000/memory-api/v1/default/banks)\"; } | tee ../evidence/28-neighbour-custom-gateway.txt; \
		docker rm -f ado-proof-n3 ado-proof-nb3 > /dev/null 2>&1; docker network rm ado-proof-net3 > /dev/null 2>&1; echo cleaned"
	;;
routemove)
	# a network connected to the RUNNING harness moves its default route; the watcher must re-render within
	# seconds and the host's published port must keep answering 200; then disconnect and check again
	remote "cd ${REMOTE_DIR}/do-agent-aws && docker network rm ado-proof-net4 > /dev/null 2>&1; docker network create ado-proof-net4 > /dev/null && { \
		echo \"before: \$(docker exec do-agent-aws ip -4 route show default) | gateways in force: \$(docker exec do-agent-aws cat /wd/ui/home-watch.gateways)\"; \
		docker network connect ado-proof-net4 do-agent-aws; sleep 1; echo \"after connect: \$(docker exec do-agent-aws ip -4 route show default)\"; \
		for i in \$(seq 1 30); do [ \"\$(docker exec do-agent-aws cat /wd/ui/home-watch.gateways)\" == \"\$(docker exec do-agent-aws ip -4 route show default | awk '{print \$3}')\" ] && break; sleep 1; done; \
		echo \"watcher after \${i}s: gateways in force: \$(docker exec do-agent-aws cat /wd/ui/home-watch.gateways) | log: \$(docker exec do-agent-aws tail -1 /wd/ui/home-watch.log | cut -c1-160)\"; \
		printf 'host publish 127.0.0.1:8000/ after connect -> %s\\n' \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8000/)\"; \
		IP=\$(docker inspect -f '{{(index .NetworkSettings.Networks \"ado-proof-net4\").IPAddress}}' do-agent-aws); printf 'neighbour on net4 -> :8000 (Host localhost) %s\\n' \"\$(docker run --rm --network ado-proof-net4 --entrypoint sh ${PROOF_IMAGE} -c \"curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: localhost:8000' http://\$IP:8000/\" 2>/dev/null)\"; \
		docker network disconnect ado-proof-net4 do-agent-aws; sleep 1; echo \"after disconnect: \$(docker exec do-agent-aws ip -4 route show default)\"; \
		for i in \$(seq 1 30); do [ \"\$(docker exec do-agent-aws cat /wd/ui/home-watch.gateways)\" == \"\$(docker exec do-agent-aws ip -4 route show default | awk '{print \$3}')\" ] && break; sleep 1; done; \
		echo \"watcher after \${i}s: gateways in force: \$(docker exec do-agent-aws cat /wd/ui/home-watch.gateways)\"; \
		printf 'host publish 127.0.0.1:8000/ after disconnect -> %s\\n' \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8000/)\"; } | tee ../evidence/29-route-move.txt; docker network disconnect ado-proof-net4 do-agent-aws > /dev/null 2>&1; docker network rm ado-proof-net4 > /dev/null 2>&1"
	;;
collect)
	mkdir -p "${HERE}/evidence"
	scp -q -r "${HOST}:${REMOTE_DIR}/evidence/*" "${HERE}/evidence/"
	ls -la "${HERE}/evidence"
	;;
down)
	remote "cd ${REMOTE_DIR}/do-agent-aws && ./stop.sh"
	;;
*)
	echo "unknown step ${STEP}" >&2; exit 1
	;;
esac
