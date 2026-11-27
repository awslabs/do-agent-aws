#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of the agent container's mounts (run by test.sh, Guardian review H-3): what the host runs is
# READ-ONLY inside the container - the checkout (every host script sources its .env and .env.local), ~/.aws (a
# credential_process command) and ~/.kube (an exec plugin) - while /wd and the two token caches the AWS CLI and the SDKs
# refresh in place (~/.aws/sso/cache, ~/.aws/cli/cache) stay writable. Real docker, the image ./build.sh built, a
# planted HOME and a throwaway copy of the settings in ./scratch/test-mounts (gitignored), so no file of the person's
# checkout, ~/.aws or ~/.kube is mounted or written. Each check FAILS if the property is removed:
#   1. .env's VOL_MAP, mounted as run.sh mounts it, as the container's own user: a write to the checkout, to
#      ~/.aws/config and to ~/.kube/config is refused (read-only file system), and the planted files are readable
#   2. the same container writes /wd and both token caches, and the files land in the planted host directories
#   3. PLANTED CONTROL: the map with the read-only flags stripped lets the same writes through (check 1 can tell)
#   4. run.sh's options carry --security-opt no-new-privileges, and a container started with them has NoNewPrivs set
#      (CONTROL: without the option it is not)
# Skipped (exit 0, one line) when docker or the image is not there.

source .env > /dev/null 2>&1
IMG=${REGISTRY}${IMAGE}${TAG}
D=./scratch/test-mounts
fail() { echo "Test-mounts FAILED: $*"; exit 1; }
command -v docker > /dev/null && docker image inspect "${IMG}" > /dev/null 2>&1 \
	|| { echo "Test-mounts skipped: no docker or no image ${IMG}"; exit 0; }
rm -rf "${D:?}" && mkdir -p "${D}/checkout/wd" "${D}/home/.aws/sso/cache" "${D}/home/.aws/cli/cache" "${D}/home/.kube" || fail "cannot create ${D}"
cp .env .fun "${D}/checkout/" || fail "cannot copy .env and .fun"
echo "[default]" > "${D}/home/.aws/config"
echo "apiVersion: v1" > "${D}/home/.kube/config"
chmod -R a+rwX "${D}"   # the container's user (AGENT_UID) writes the writable mounts whatever this host's uid is
D=$(cd "${D}" && pwd)

# vol_map [sed expression] - .env's VOL_MAP for the planted checkout and HOME, optionally edited
vol_map() { (cd "${D}/checkout" && HOME="${D}/home" ENV_LOCAL_SETUP=false bash -c 'source ./.env > /dev/null 2>&1; echo "${VOL_MAP}"') | sed -E "${1:-}"; }
# probe <volume map> - one container as its own user; prints "<path> ok|refused" per write
probe()
{
	# shellcheck disable=SC2086 # the map is words, as run.sh passes it
	docker container run --rm $1 --entrypoint sh "${IMG}" -c '
		for f in /do-agent-aws/planted-write /home/agent/.aws/config /home/agent/.kube/config /wd/planted-write \
			/home/agent/.aws/sso/cache/planted-write /home/agent/.aws/cli/cache/planted-write; do
			if (echo planted >> "$f") 2> /dev/null; then echo "$f ok"; else echo "$f refused"; fi
		done
		cat /home/agent/.aws/config /home/agent/.kube/config > /dev/null && echo "read ok"' 2>&1
}
MAP=$(vol_map)
case " ${MAP} " in *" ${D}/checkout:/do-agent-aws:ro "*) ;; *) fail "1: VOL_MAP does not mount the planted checkout read-only: ${MAP}" ;; esac
OUT=$(probe "${MAP}")
for f in /do-agent-aws/planted-write /home/agent/.aws/config /home/agent/.kube/config; do
	echo "${OUT}" | grep -qx "${f} refused" || fail "1: the container could write ${f}: ${OUT}"
done
echo "${OUT}" | grep -qx "read ok" || fail "1: the container cannot read the planted ~/.aws/config and ~/.kube/config: ${OUT}"
grep -q planted "${D}/home/.aws/config" "${D}/home/.kube/config" && fail "1: a planted host file changed"
echo "ok 1 - the checkout, ~/.aws/config and ~/.kube/config are read-only in the container (readable)"

for f in /wd/planted-write /home/agent/.aws/sso/cache/planted-write /home/agent/.aws/cli/cache/planted-write; do
	echo "${OUT}" | grep -qx "${f} ok" || fail "2: the container could not write ${f}: ${OUT}"
done
for h in checkout/wd/planted-write home/.aws/sso/cache/planted-write home/.aws/cli/cache/planted-write; do
	[ -f "${D}/${h}" ] || fail "2: the write did not land in the planted ${h}"
done
echo "ok 2 - /wd and the two token caches are writable, and the writes land on the host"

OUT=$(probe "$(vol_map 's/:ro( |$)/\1/g')")
echo "${OUT}" | grep -qx "/home/agent/.aws/config ok" || fail "3: PLANTED CONTROL: without the read-only flags ~/.aws/config was still refused: ${OUT}"
echo "${OUT}" | grep -qx "/do-agent-aws/planted-write ok" || fail "3: PLANTED CONTROL: without the read-only flags the checkout was still refused: ${OUT}"
echo "ok 3 - PLANTED CONTROL: the same map without its read-only flags lets the writes through"

RUN=$(cd "${D}/checkout" && HOME="${D}/home" ENV_LOCAL_SETUP=false bash -c 'source ./.env > /dev/null 2>&1; echo "${RUN_OPTS}"')
case " ${RUN} " in *" --security-opt no-new-privileges "*) ;; *) fail "4: RUN_OPTS does not carry --security-opt no-new-privileges" ;; esac
NNP=$(docker container run --rm --security-opt no-new-privileges --entrypoint sh "${IMG}" -c 'grep ^NoNewPrivs: /proc/self/status' | awk '{print $2}')
[ "${NNP}" == "1" ] || fail "4: a container with --security-opt no-new-privileges has NoNewPrivs ${NNP:-unknown}"
NNP=$(docker container run --rm --entrypoint sh "${IMG}" -c 'grep ^NoNewPrivs: /proc/self/status' | awk '{print $2}')
[ "${NNP}" == "0" ] || fail "4: CONTROL: a container without the option has NoNewPrivs ${NNP:-unknown} - the check cannot tell"
echo "ok 4 - run.sh starts the agent container with no-new-privileges (NoNewPrivs 1; without the option 0)"

rm -rf "${D:?}"
echo "Test-mounts succeeded"
