#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# image-build.sh - build a container image inside the harness and push it to the stack's registry (docs/manual/agents.md "Docker
# agent"). The agent container has no Docker CLI and no Docker socket: buildctl talks to the stack's rootless BuildKit
# daemon at BUILDKIT_HOST (its socket, mounted at /run/buildkit), and the daemon pushes to BUILD_REGISTRY (registry:5000
# on the stack's networks). Both are set by ./run.sh on the docker target while the docker spoke is on (SPOKE_DOCKER).
#
#   image-build.sh <context dir> <Dockerfile> <name:tag> [--build-arg NAME=VALUE]... [--target STAGE]
#       builds the Dockerfile with that context, pushes it as BUILD_REGISTRY/<name:tag> and prints the pushed reference
#       with its digest as the last line ("image: registry:5000/<name:tag>@sha256:..."); the build log goes to stderr
#   image-build.sh list
#       the repositories of the stack's registry with their tags, one reference a line
#
# The name is a repository path and a tag (team/tool:1.0), lowercase, with no registry in front; the stack's own
# (registry:5000/team/tool:1.0) is the same name. A name on any other registry - a first part with a dot or a port, or
# localhost - is refused with exit 2 before anything is built or pushed: a push outside the stack is a person's step,
# never this helper's. Every build is a line of ${DOCKER_SPOKE_WD}/builds.jsonl (default /wd/docker): the time, the
# reference, the digest, the Dockerfile, the seconds and the exit code.
#
# Exit codes: 0 built and pushed; 1 the build or the push failed; 2 refused (usage, a name outside the stack, no build
# substrate on this target).

BUILD_REGISTRY=${BUILD_REGISTRY:-}
BUILDKIT_HOST=${BUILDKIT_HOST:-}
# the push target and the gate are the stack registry's fixed name, never a value the caller passes: a caller that
# set BUILD_REGISTRY to another host could otherwise redirect this helper's own push, or its list, there.
# BUILD_REGISTRY stays only the "a substrate is configured" presence check below.
STACK_REGISTRY=registry:5000
DOCKER_SPOKE_WD=${DOCKER_SPOKE_WD:-/wd/docker}
export BUILDKIT_HOST

usage()
{
	echo "usage: image-build.sh <context dir> <Dockerfile> <name:tag> [--build-arg NAME=VALUE]... [--target STAGE] | image-build.sh list (docs/manual/agents.md \"Docker agent\")" >&2
	exit 2
}

refuse()
{
	echo "image-build: REFUSED - $*" >&2
	exit 2
}

if [ -z "${BUILDKIT_HOST}" ] || [ -z "${BUILD_REGISTRY}" ]; then
	refuse "no build substrate on this target (BUILDKIT_HOST and BUILD_REGISTRY are set by ./run.sh on the docker target with SPOKE_DOCKER=true; docs/manual/agents.md \"Docker agent\")"
fi

if [ "$1" == "list" ]; then
	exec python3 -I - "${STACK_REGISTRY}" << 'PY'
import json, sys, urllib.parse, urllib.request
reg = sys.argv[1]
get = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # the stack's registry is never behind a proxy
def read(path):
    with get.open(f"http://{reg}{path}", timeout=10) as r:
        return json.load(r)
try:
    repos = read("/v2/_catalog?n=1000").get("repositories") or []
    for repo in repos:
        for tag in sorted(read(f"/v2/{urllib.parse.quote(repo)}/tags/list").get("tags") or []):
            print(f"{reg}/{repo}:{tag}")
except OSError as e:
    sys.exit(f"image-build: the registry {reg} does not answer ({e})")
except ValueError as e:
    sys.exit(f"image-build: the registry {reg} answers with something that is not its JSON API ({e})")
PY
fi

[ $# -ge 3 ] || usage
CONTEXT=$1
DOCKERFILE=$2
NAME=$3
shift 3
OPTS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--build-arg)
			echo "$2" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' || refuse "--build-arg takes NAME=VALUE, got '$2'"
			OPTS+=(--opt "build-arg:$2")
			shift 2
			;;
		--target)
			echo "$2" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || refuse "--target takes a stage name, got '$2'"
			OPTS+=(--opt "target=$2")
			shift 2
			;;
		*)
			usage
			;;
	esac
done
[ -d "${CONTEXT}" ] || refuse "the context ${CONTEXT} is not a directory"
[ -f "${DOCKERFILE}" ] || refuse "the Dockerfile ${DOCKERFILE} is not a file"

# The registry the name points at. A first part with a dot or a port, or localhost, is a registry host (the Docker
# reference grammar); the stack's own is dropped, any other is refused before buildctl runs
FIRST=${NAME%%/*}
if [ "${FIRST}" != "${NAME}" ] && { [[ "${FIRST}" == *.* ]] || [[ "${FIRST}" == *:* ]] || [ "${FIRST}" == "localhost" ]; }; then
	[ "${FIRST}" == "${STACK_REGISTRY}" ] || refuse "'${NAME}' names the registry ${FIRST}: this helper pushes only to the stack's registry, ${STACK_REGISTRY}; a push anywhere else is a person's step outside the harness"
	NAME=${NAME#*/}
fi
echo "${NAME}" | grep -qE '^[a-z0-9]+([._-]+[a-z0-9]+)*(/[a-z0-9]+([._-]+[a-z0-9]+)*)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' \
	|| refuse "'${NAME}' is not a repository path with a tag (lowercase letters, digits, '.', '_' and '-'; for example team/tool:1.0)"
REF=${STACK_REGISTRY}/${NAME}

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
START=$(date +%s)
echo "image-build: building ${DOCKERFILE} (context ${CONTEXT}) into ${REF} through ${BUILDKIT_HOST}" >&2
# registry.insecure=true: the push goes over plain HTTP, to the stack's own registry only (REF names STACK_REGISTRY - any
# other registry is refused above). That registry is a sidecar without a TLS certificate of its own, attached only to the
# stack's two Docker networks (the agent's internal one and the daemon's) and published on no host port, so the plain
# HTTP between the daemon and the registry never leaves the host's Docker bridges (docs/manual/agents.md "Docker agent")
buildctl build --frontend dockerfile.v0 --local "context=${CONTEXT}" --local "dockerfile=$(dirname "${DOCKERFILE}")" \
	--opt "filename=$(basename "${DOCKERFILE}")" "${OPTS[@]}" \
	--output "type=image,name=${REF},push=true,registry.insecure=true" --metadata-file "${T}/meta.json" --progress plain >&2
RC=$?
DIGEST=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("containerimage.digest") or "")' "${T}/meta.json" 2> /dev/null)
[ ${RC} -eq 0 ] && [ -z "${DIGEST}" ] && { echo "image-build: the build reported no pushed digest" >&2; RC=1; }
# the build's record: a line of builds.jsonl, written best effort (a read-only /wd does not fail a build)
mkdir -p "${DOCKER_SPOKE_WD}" 2> /dev/null
python3 -I - "${DOCKER_SPOKE_WD}/builds.jsonl" "${REF}" "${DIGEST}" "${DOCKERFILE}" "$(( $(date +%s) - START ))" "${RC}" << 'PY' 2> /dev/null \
	|| echo "image-build: could not record the build in ${DOCKER_SPOKE_WD}/builds.jsonl" >&2
import json, sys, time
path, ref, digest, dockerfile, secs, rc = sys.argv[1:7]
rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "ref": ref, "digest": digest or None,
       "dockerfile": dockerfile, "seconds": int(secs), "rc": int(rc)}
with open(path, "a") as f:
    f.write(json.dumps(rec, sort_keys=True) + "\n")
PY
if [ ${RC} -ne 0 ]; then
	echo "image-build: FAILED - the build or the push of ${REF} exited ${RC} (the log above)" >&2
	exit 1
fi
echo "image: ${REF}@${DIGEST}"
