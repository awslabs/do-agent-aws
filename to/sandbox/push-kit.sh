#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Push the kit image to a PRIVATE Docker Hub repository, or refuse.
#
#   usage: DOCKERHUB_USER=<user> to/sandbox/push-kit.sh docker.io/<namespace>/<repository>:<tag>
#
# 1. The repository must exist and be private before anything is built: the
#    Docker Hub API (DOCKERHUB_API, default https://hub.docker.com) is asked,
#    anonymously and then with a personal access token for DOCKERHUB_USER, and
#    only "is_private": true goes on. The token is read from the terminal without
#    echo (or from stdin when that is not a terminal); it is never printed and
#    never passed as a command argument.
# 2. render.sh renders the kit from HEAD; it is built with the pinned kit
#    frontend in the metadata-blocked builder of build-env.sh and pushed (the
#    host's docker login must cover the repository).
# 3. Without credentials the pushed image must not resolve; if it does, the
#    script fails loudly. It prints repo@digest for e2e.sh --kit.
# Exit 0 only after all three; nothing is built or pushed unless step 1 passed.
# It refuses to run under xtrace (bash -x would print the token) and talks only to
# https://hub.docker.com, or to http(s)://127.0.0.1:<port> or localhost:<port>
# with nothing before the host or after the port (test stubs): no userinfo, so no
# other host can be named.

# Before anything else: no xtrace, which would print the token.
case "$-" in *x*) echo "push-kit.sh: refusing to run with xtrace on (bash -x would print the access token)" >&2; exit 1 ;; esac
case ":${SHELLOPTS:-}:" in *:xtrace:*) echo "push-kit.sh: refusing to run with xtrace in SHELLOPTS" >&2; exit 1 ;; esac
[ -z "${BASH_XTRACEFD+set}" ] || { echo "push-kit.sh: refusing to run with BASH_XTRACEFD set" >&2; exit 1; }

set -u -o pipefail

BASE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SBX_DIR=${BASE_DIR}/to/sandbox
KIT=do-agent-aws-sandbox
API=${DOCKERHUB_API:-https://hub.docker.com}
REF=${1:-}
# Exact match only: a glob such as http://127.0.0.1:* also passes
# http://127.0.0.1:x@attacker.example, whose host is attacker.example.
STUB_API_RE='^https?://(127\.0\.0\.1|localhost):[0-9]{1,5}$'
if ! { [ "${API}" = https://hub.docker.com ] || [[ ${API} =~ ${STUB_API_RE} ]]; }; then
	echo "push-kit.sh: DOCKERHUB_API must be https://hub.docker.com (or http(s)://127.0.0.1:<port> or localhost:<port>, a test stub), not ${API}" >&2
	exit 1
fi

fail()
{
	echo "push-kit.sh: $1" >&2
	exit 1
}

for tool in curl jq docker git; do
	command -v "${tool}" > /dev/null || fail "${tool} is required"
done
case "${REF}" in
docker.io/*/*:*) ;;
*) fail "usage: DOCKERHUB_USER=<user> $0 docker.io/<namespace>/<repository>:<tag>" ;;
esac
case "${REF}" in *@*) fail "push by tag, not by digest: ${REF}" ;; esac
REPO_PATH=${REF#docker.io/}
NAMESPACE=${REPO_PATH%%/*}
REPOSITORY=${REPO_PATH#*/}
REPOSITORY=${REPOSITORY%%:*}
case "${REPOSITORY}" in */*|"") fail "expected docker.io/<namespace>/<repository>:<tag>, got ${REF}" ;; esac
URL="${API}/v2/namespaces/${NAMESPACE}/repositories/${REPOSITORY}"

# 1. private, before anything is built
ANON=$(curl -sS -o /dev/stdout -w '\n%{http_code}' --max-time 30 "${URL}" 2> /dev/null)
if [ "$(echo "${ANON}" | tail -1)" = "200" ] && echo "${ANON}" | sed '$d' | jq -e '.is_private == false' > /dev/null 2>&1; then
	fail "${NAMESPACE}/${REPOSITORY} is PUBLIC on Docker Hub; refusing to push (make it private first)"
fi
[ -n "${DOCKERHUB_USER:-}" ] || fail "set DOCKERHUB_USER to confirm with the Docker Hub API that ${NAMESPACE}/${REPOSITORY} is private"
if [ -t 0 ]; then
	read -rsp "Docker Hub personal access token for ${DOCKERHUB_USER}: " HUB_PAT
	echo
else
	read -r HUB_PAT
fi
[ -n "${HUB_PAT:-}" ] || fail "no access token given; cannot confirm that ${NAMESPACE}/${REPOSITORY} is private"
HUB_TOKEN=$(HUB_USER="${DOCKERHUB_USER}" HUB_PAT="${HUB_PAT}" jq -n '{identifier: env.HUB_USER, secret: env.HUB_PAT}' \
	| curl -fsS --max-time 30 -H 'Content-Type: application/json' -d @- "${API}/v2/auth/token" 2> /dev/null \
	| jq -r '.access_token // .token // empty' 2> /dev/null)
unset HUB_PAT
[ -n "${HUB_TOKEN}" ] || fail "could not authenticate to Docker Hub as ${DOCKERHUB_USER}; cannot confirm that ${NAMESPACE}/${REPOSITORY} is private"
# The token goes to curl on stdin (-K -), never in its arguments.
PRIVATE=$(printf 'header = "Authorization: Bearer %s"\nurl = "%s"\n' "${HUB_TOKEN}" "${URL}" \
	| curl -fsS --max-time 30 -K - 2> /dev/null | jq -r '.is_private' 2> /dev/null)
unset HUB_TOKEN
[ "${PRIVATE}" = "true" ] || fail "Docker Hub does not report ${NAMESPACE}/${REPOSITORY} as private (is_private=${PRIVATE:-unknown}; create it as private first); refusing to push"
echo "push-kit.sh: ${NAMESPACE}/${REPOSITORY} is private"

# 2. render from HEAD, build in the metadata-blocked builder, push
# shellcheck source=build-env.sh
. "${SBX_DIR}/build-env.sh"
trap 'sbx_build_env_down > /dev/null' EXIT
"${SBX_DIR}/render.sh" || fail "render.sh failed"
sbx_build_env_up || fail "the metadata-blocked builder is not available"
echo "push-kit.sh: builder ${SBX_BUILDER}: metadata service HTTP ${SBX_IMDS_BEFORE} before the rule, ${SBX_IMDS_AFTER} after"
docker buildx build --builder "${SBX_BUILDER}" --progress plain \
	-f "${SBX_DIR}/app/${KIT}/${KIT}.yaml" --build-arg "BUILDKIT_SYNTAX=${SBX_KIT_FRONTEND}" \
	-t "${REF}" --push "${SBX_DIR}/app/${KIT}" || fail "build or push failed"
sbx_build_env_down || fail "could not remove the DOCKER-USER rule"

# 3. not resolvable without credentials
NOCREDS=$(mktemp -d)
if DOCKER_CONFIG=${NOCREDS} docker manifest inspect "${REF}" > /dev/null 2> "${NOCREDS}/err"; then
	rm -rf "${NOCREDS}"
	fail "PUBLIC: ${REF} resolves without credentials. Make the repository private or delete the tag now"
fi
grep -qiE 'denied|unauthorized|authentication required|not found|manifest unknown' "${NOCREDS}/err" \
	|| { cat "${NOCREDS}/err" >&2; rm -rf "${NOCREDS}"; fail "could not confirm that ${REF} is unreadable without credentials"; }
rm -rf "${NOCREDS}"
DIGEST=$(docker buildx imagetools inspect "${REF}" 2> /dev/null | sed -n 's/^Digest:[[:space:]]*//p' | head -1)
[ -n "${DIGEST}" ] || fail "pushed, but could not read the digest of ${REF}"
echo "push-kit.sh: pushed ${REF%:*}@${DIGEST}; it does not resolve without credentials"
echo "next: KIT_TCK=/path/to/kit-tck to/sandbox/test/e2e.sh --cloud --name <name> --kit ${REF%:*}@${DIGEST}"
