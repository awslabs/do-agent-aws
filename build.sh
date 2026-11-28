#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# your settings file .env.local: created on the first run, an edited tracked .env moved into it once
# (docs/manual/install.md "Settings"); a copy of this script without it skips the step
[ -x ./env-local.sh ] && ./env-local.sh

source .env

# TO=sandbox (to/sandbox/README.md "TO=sandbox"): no Docker image, no board image. The kit is rendered from HEAD (commit
# before building: render.sh takes nothing from the working tree) and built the way sbx builds a kit, through a throwaway
# sandbox that is removed at once, so that ./run.sh reuses the build ("kit ... unchanged, reusing"). The sizes are the
# descriptor's (preflight.sh); the preflight before it names what a local sandbox needs on this host
case "${TO}" in
	"sandbox")
		source ./preflight.sh
		preflight sandbox || exit 1
		read -r SANDBOX_CPUS SANDBOX_MEMORY < <(preflight_sandbox_sizes) || exit 1
		CMD="to/sandbox/render.sh && ${SBX} create --name ${SANDBOX_PREBUILD_NAME} --cpus ${SANDBOX_CPUS} --memory ${SANDBOX_MEMORY} ${SANDBOX_CREATE_OPTS} ${SANDBOX_KIT} && ${SBX} rm --force ${SANDBOX_PREBUILD_NAME}"
		if [ "${VERBOSE}" == "true" ]; then
			echo "${CMD}"
		fi
		if [ "${DRY_RUN}" == "false" ]; then
			# the build's output passes through and is kept for one check: the kit build that stops at once with the OCI
			# exporter error has two causes, and the README names the fix of each
			BUILD_OUT=$(mktemp)
			eval "${CMD}" 2>&1 | tee "${BUILD_OUT}"
			RC=${PIPESTATUS[0]}
			if grep -q "OCI exporter is not supported for the docker driver" "${BUILD_OUT}"; then
				echo "build.sh: ERROR - the kit build stopped with 'OCI exporter is not supported for the docker driver': either this host has no hypervisor (no /dev/kvm; sbx then builds on the host engine's docker driver, which cannot export the OCI image a kit is - use a host with KVM, or a cloud sandbox from a pushed kit, to/sandbox/push-kit.sh), or the hypervisor is there but the engine uses the classic image store (turn the containerd image store on, or build with a buildx builder that is not the docker driver); to/sandbox/README.md 'Local sandboxes (hosts with KVM)'" >&2
				rm -f "${BUILD_OUT:?}"
				exit 1
			fi
			rm -f "${BUILD_OUT:?}"
			if [ "${RC}" != "0" ]; then
				echo "build.sh: ERROR - the kit build exited ${RC} (the lines above name the cause); a sandbox ${SANDBOX_PREBUILD_NAME} it left behind goes with: ${SBX} rm --force ${SANDBOX_PREBUILD_NAME}" >&2
				exit ${RC}
			fi
		fi
		exit 0
		;;
esac

# Preflight (preflight.sh, shared with run.sh): what a build needs on THIS host, each gap named with its numbers and its
# fix - a fresh Ubuntu with the distribution's docker.io package has no BuildKit builder and the build options use it (the
# build stopped with "unknown flag: --progress", rc 125); the image and its build cache take about 30 GB (a fresh build took
# disk use from 2 to 29 GB, on an 8 GB default root volume); a user outside the docker group cannot build at all; a host
# whose Docker address pools are used up builds but cannot start the instance (the preflight warns here, refuses in run.sh)
source ./preflight.sh
preflight build || exit 1

echo "do-agent-aws shell $VERSION" > Container-Root/version.txt

# The self-hosted Plane board's public images (docs/manual/boards.md "Plane board"), pulled now so that ./run.sh pulls nothing - only
# with the board on (UI_PLANE=true in .env.local): it is optional and off by default (AGPL-3.0), and off nothing of it is pulled
if [ "${UI_START}" == "true" ] && [ "${UI_PLANE}" == "true" ]; then
	./plane.sh pull || exit $?
fi
# The docker spoke's build substrate (docs/manual/agents.md "Docker agent"): its two pinned public images, pulled the same way
if [ "${SPOKE_DOCKER}" == "true" ]; then
	./docker.sh pull || exit $?
fi

# Build Docker image
CMD="docker image build ${BUILD_OPTS} -t ${REGISTRY}${IMAGE}${TAG} ."
eval "$CMD" || exit $?

# The self-hosted kanban board's server image (docs/manual/boards.md "Kanban board"): built from the public upstream
# source at the pinned commit plus the vendored patch in kanban/, by the same docker image build
if [ "${UI_VIBE_KANBAN}" == "true" ]; then
	./kanban.sh build
fi

# The end of the build: the software bill of materials the image's last step wrote (/sbom.sh -> /SBOM.txt, docs/manual/supply-chain.md
# "Software bill of materials"), copied out of the image as THIRD-PARTY-LICENSES at the repository root, the committed
# human-readable list of the third-party software in the image with its licenses. Through a temporary file, so a failed
# extraction never truncates the committed file; an image without the file, or a cat that returns something else, exits 1
# with one line. The sandbox target returned above: it builds no Docker image (its kit image carries /SBOM.txt itself).
SBOM_TMP=$(mktemp ./THIRD-PARTY-LICENSES.tmp.XXXXXX) || exit 1
SBOM_ERR=$(mktemp ./THIRD-PARTY-LICENSES.err.XXXXXX) || { rm -f "${SBOM_TMP:?}"; exit 1; }
trap 'rm -f "${SBOM_TMP:?}" "${SBOM_ERR:?}"' EXIT   # an interrupted run leaves no temporary file behind
chmod 0644 "${SBOM_TMP}"   # a committed file readable by everyone, not mktemp's 0600
# --network none: cat needs no network, and a host whose Docker address pools are used up (the preflight only warns for a
# build) must not fail here; docker's and cat's own words are kept and printed when something fails
if ! docker container run --rm --network none --entrypoint cat ${REGISTRY}${IMAGE}${TAG} /SBOM.txt > "${SBOM_TMP}" 2> "${SBOM_ERR}"; then
	echo "build.sh: ERROR - reading /SBOM.txt from the image ${REGISTRY}${IMAGE}${TAG} failed: $(tail -1 "${SBOM_ERR}") (its last step is RUN /sbom.sh); THIRD-PARTY-LICENSES is left as it was" >&2
	exit 1
fi
if ! head -1 "${SBOM_TMP}" | grep -q '^## Software bill of materials'; then
	echo "build.sh: ERROR - the image ${REGISTRY}${IMAGE}${TAG} answered something that is not a software bill of materials for /SBOM.txt ('$(head -1 "${SBOM_TMP}" | cut -c1-80)'; its last step is RUN /sbom.sh); THIRD-PARTY-LICENSES is left as it was" >&2
	exit 1
fi
mv -f "${SBOM_TMP:?}" THIRD-PARTY-LICENSES
echo "build.sh: THIRD-PARTY-LICENSES written from the image's /SBOM.txt ($(grep -m1 '^## components:' THIRD-PARTY-LICENSES | sed 's/^## //'))"

# The CVE scan, last (docs/manual/supply-chain.md "CVE scan"): ./scan.sh walks the image just built with trivy, writes its report, table and bills of
# materials under CVE_DIR and fails this build on a CRITICAL that has a fix available - its exit status is this script's (4 the gate,
# 5 the HIGH ceiling, 3 a scan that could not be evaluated: never a silent pass). CVE_SCAN=false skips it (the host tests that
# build against a docker stub set it in the environment). The sandbox target returned above: no Docker image to scan.
if [ "${CVE_SCAN}" == "true" ]; then
	./scan.sh || exit $?
fi
