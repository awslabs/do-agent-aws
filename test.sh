#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

source .env

export MODE=-it

echo "Testing ${IMAGE} ..."

# Host-side check of the Plane board's sidecars (docs/manual/boards.md "Plane board"): with docker stubbed, the commands ./plane.sh
# and ./run.sh would run publish no host port for the board and carry no secret on a command line. Always: the board is
# opt-in (UI_PLANE=false by default) and the test's copy of .env turns it on, so the Plane path stays tested while off
./test-plane.sh dry || exit 1
# and, only where this host opted in, a real start and stop of one board container under names of its own: ./stop.sh
# leaves none of its anonymous volumes behind
if [ "${UI_START}" == "true" ] && [ "${UI_PLANE}" == "true" ]; then
	./test-plane.sh lifecycle || exit 1
fi
# Host-side test of the exec.sh command line flags - exec.sh is a host script, so its
# flag contract is asserted here rather than in the in-container /test*.sh suite below
./test-exec.sh || exit 1
# build.sh's preflight and .env's conditional mounts are host-side behaviour too: planted docker stubs on PATH
./test-preflight.sh || exit 1
# the agent container's mounts, with real docker and the image just built: what the host runs (the checkout, ~/.aws,
# ~/.kube) is read-only inside, /wd and the token caches writable (docs/manual/install.md "Container user")
./test-mounts.sh || exit 1
# the kubernetes target's manifests: the Ingress and the HorizontalPodAutoscaler are opt-in (KUBERNETES_INGRESS, KUBERNETES_HPA)
./test-kubernetes.sh || exit 1
# SECURITY.md's table of who is responsible for each class of finding, and its configuration disclaimer: files only, no container
./test-security-md.sh || exit 1
# the conditions of the release's IP review (README.md "License and third-party software"): the Apache-2.0 header on every
# first-party source file, LICENSE, NOTICE, the bundled third-party code, the Claude Code terms and the notice of the
# restricted licenses (Plane, pgsty/silo): files and git only, no container
./test-license-headers.sh || exit 1
# the README and the manual (README.md "Documentation", docs/manual): every relative link and anchor resolves, every reference
# to a manual section names one the page carries, every page is indexed and the README stays a landing page: files and git only
./test-docs-links.sh || exit 1
# the settings layout (docs/manual/install.md "Settings"): .env the tracked defaults, .env.local a person's own settings, in throwaway repos
./test-env-local.sh || exit 1
# run.sh's start command, with a docker stub on PATH: a start that fails, or leaves no running agent container, exits
# non-zero and says why
./test-run.sh || exit 1
# stop.sh, with docker and the other targets' clis stubbed on PATH: the default removes the agent container and then the
# boards' and the substrate's sidecars through the three down scripts; -s/--single removes the agent container alone
# (docs/manual/install.md "Restart only the agent container"); any other argument is refused
./test-stop.sh || exit 1
# build.sh's step after the image build, with a docker stub on PATH: the image's /SBOM.txt copied out as THIRD-PARTY-LICENSES
# through a temporary file, a failed extraction leaving the committed file alone (docs/manual/supply-chain.md "Software bill of materials")
./test-build.sh || exit 1
# the CVE scan at the end of build.sh (docs/manual/supply-chain.md "CVE scan"), with docker and trivy stubbed on PATH: one walk of the image by the
# pinned scanner through the Docker socket, the report, table and bills of materials under cve/, the gate on a CRITICAL with a fix
# and its exit statuses, the pass record only on a pass
./test-scan.sh || exit 1
# the sandbox target's scripts (TO=sandbox, to/sandbox/README.md), with sbx, docker and kubectl stubbed on PATH: build.sh
# renders then builds the kit, run.sh creates the sandbox with the descriptor's sizes, status.sh, exec.sh, stop.sh and
# logs.sh drive it, the preflight names each gap, and the docker target's commands are unchanged
./test-sandbox.sh || exit 1
# Host-side check of the kanban board's server image (docs/manual/boards.md "Kanban board"): its static bundle must be the
# restored board, not vibe-kanban's sunset page; the image is ./build.sh's, so no container needs to be running
if [ "${UI_VIBE_KANBAN}" == "true" ]; then
	./test-kanban.sh bundle || exit 1
fi
# Host-side test of the docker spoke's build substrate (docs/manual/agents.md "Docker agent"): a daemon and a registry of its own
# beside a throwaway agent container from the image ./build.sh built, which builds an image through them; it needs that
# image and the two sidecar images ./build.sh pulls, and no network
if [ "${SPOKE_DOCKER}" == "true" ]; then
	./test-docker-spoke.sh || exit 1
fi

# TEST_RUN_OPTS and TEST_VOL_MAP (.env): the test container gets the harness environment but NOT the agent-state
# mounts - it works on the image's baked copy of the agent state and throws it away. The tests fire claude
# headless, write memories through the installed hooks and index sessions; with the persisted state mounted, all
# of that landed in the user's own agent state (a `-tmp-loop-smoke` project in the LogLearner dashboard, a planted
# bank in the memory store) and the test's hindsight-api contended with the running one for the same database. It
# gets its own HINDSIGHT_HOME and LOGLEARNER_STATE, the checkout read-only, and a THROWAWAY /wd (a tmpfs) in place
# of the user's wd/: with wd/ mounted, the suite's sessions still reached the running harness's LogLearner index
# through the shipped index path. The suite FAILS when anything was written under /wd - a test that writes there
# would write the user's checkout as soon as the real volume is mounted.
# The check is Container-Root/test-lib/wd-check.sh (/test-lib/wd-check.sh in the image); it is proven here first on a
# planted entry and on an empty directory, so a check that stopped counting would stop the suite, not pass it.
WDC=$(mktemp -d); mkdir -p "${WDC}/planted/sub" "${WDC}/empty"; : > "${WDC}/planted/sub/file"
sh Container-Root/test-lib/wd-check.sh "${WDC}/planted" > /dev/null 2>&1 && { echo "FAILED: test-lib/wd-check.sh passed a directory with a planted entry"; exit 1; }
sh Container-Root/test-lib/wd-check.sh "${WDC}/empty" > /dev/null 2>&1 || { echo "FAILED: test-lib/wd-check.sh refused an empty directory"; exit 1; }
rm -rf "${WDC:?}"
# TEST_RUN_OPTS holds shell words, each setting's value quoted where it needs it (.env's shq): read the way run.sh's eval
# reads RUN_OPTS, so the test container gets a value with a quote, a parenthesis, a semicolon or a space as written
eval "TEST_RUN_ARGS=(${TEST_RUN_OPTS})"
docker container run "${TEST_RUN_ARGS[@]}" ${CONTAINER_NAME}-test ${MODE} --rm ${NETWORK} ${TEST_VOL_MAP} ${REGISTRY}${IMAGE}${TAG} sh -c "rc=0; n=0; for t in \$(ls /test*.sh); do n=\$((n + 1)); echo Running test \$t; \$t || { echo \"FAILED: \$t\"; rc=1; }; done; [ \$n -gt 0 ] || { echo \"FAILED: no /test*.sh ran\"; rc=1; }; /test-lib/wd-check.sh /wd || rc=1; exit \$rc"


