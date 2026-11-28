#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Sandbox test2 - build the kit and judge it with the specification's own tools.
# Host-side; needs Docker with Buildx, network access to Docker Hub (the kit
# frontend docker/sandbox-kit:3 and the base image) and kit-tck, the Docker
# Sandbox Kit Specification conformance tool (on PATH, or KIT_TCK=/path/kit-tck;
# install: to/sandbox/README.md "Validate without sign-in"). No sbx, no sign-in,
# no KVM. Each check FAILS if the property it proves is removed:
#    1. render.sh renders the kit
#    2. docker buildx builds it through the kit frontend (# syntax=docker/sandbox-kit:3,
#       pinned by digest with BUILDKIT_SYNTAX), which decodes the descriptor
#       strictly and validates it, into an OCI layout, and also loads it into
#       Docker as IMAGE (default do-agent-aws-sandbox:local) for test4.sh. The
#       build runs in the builder of to/sandbox/build-env.sh (attached to its
#       build network only), whose build steps cannot reach the EC2 metadata
#       service: a probe step - its marker line required - gets HTTP 401 before
#       the run's DOCKER-USER rule (the positive control) and no answer after it;
#       the rule is removed on exit. Needs passwordless sudo for iptables.
#    3. kit-tck validate --layout: the artifact conforms (annotations, staged
#       sources and recipe, image config, sbx@1 platform floor and persistent env)
#    4. the image config is the declared contract: user root, workdir
#       /root/workspace, entrypoint claude, the start-docker label, BASH_ENV,
#       IS_SANDBOX=1, Bedrock (CLAUDE_CODE_USE_BEDROCK=1, AWS_REGION=us-east-1
#       and the two model pins) with no AWS credential variable,
#       NODE_EXTRA_CA_CERTS and the offline settings for hindsight-api
#       (TIKTOKEN_CACHE_DIR, LITELLM_LOCAL_MODEL_COST_MAP, HF_HUB_OFFLINE)
#    5. the published descriptor in the manifest carries the delivery's
#       capabilities and passes check-descriptor.py, and the recipe kit-tck
#       reads from the artifact and the one staged in the image are the rendered
#       dockerfile byte for byte (what e2e.sh's provenance checks compare)
#    6. inside the image: dockerd, docker compose and claude are installed,
#       /home/agent/.claude/settings.json selects Bedrock with the environment's
#       region and model pins and names no AWS credential variable, and the
#       tiktoken and Hugging Face caches hold what hindsight-api needs offline:
#       the two models at their pinned revisions (refs/main points there),
#       safetensors only
#    7. two overlapping build runs: when run A tears down twice (as a script does,
#       explicitly and again from its EXIT trap), its first teardown clears its
#       tag and subnet, and run B's rule, added between the two, stays in place
#       until B itself removes it
# Outputs under wd/sandbox-kit/ (OCI layout, logs).

BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SBX_DIR=${BASE_DIR}/to/sandbox
KIT=do-agent-aws-sandbox
IMAGE=${IMAGE:-do-agent-aws-sandbox:local}
KIT_TCK=${KIT_TCK:-$(command -v kit-tck)}
# shellcheck source=../build-env.sh
. "${SBX_DIR}/build-env.sh"
OUT=${BASE_DIR}/wd/sandbox-kit
TAG=local

fail()
{
	echo "Sandbox test2 FAILED: $1"
	exit 1
}
trap 'sbx_build_env_down' EXIT

command -v docker > /dev/null || fail "docker is required"
docker buildx version > /dev/null 2>&1 || fail "docker buildx is required"
[ -n "${KIT_TCK}" ] && [ -x "${KIT_TCK}" ] || fail "kit-tck not found (set KIT_TCK or put it on PATH; see to/sandbox/README.md)"
command -v jq > /dev/null || fail "jq is required"
mkdir -p "${OUT}"

# 1. render
"${SBX_DIR}/render.sh" > "${OUT}/render.log" 2>&1 || fail "render.sh failed: $(tail -1 "${OUT}/render.log")"
APP=${SBX_DIR}/app/${KIT}
echo "ok 1 - rendered ${APP}"

# 2. build through the kit frontend, in the metadata-blocked builder
sbx_build_env_up > "${OUT}/build-env.log" 2>&1 || fail "$(cat "${OUT}/build-env.log")"
rm -rf "${OUT}/oci"
docker buildx build --builder "${SBX_BUILDER}" --progress plain -f "${APP}/${KIT}.yaml" \
	--build-arg "BUILDKIT_SYNTAX=${SBX_KIT_FRONTEND}" \
	--output "type=oci,dest=${OUT}/oci,tar=false,name=${KIT}:${TAG}" \
	--output "type=docker,name=${IMAGE}" "${APP}" > "${OUT}/build.log" 2>&1
RC=$?
[ ${RC} -eq 0 ] || fail "kit build failed (exit ${RC}); see ${OUT}/build.log"
grep -q "stage sources /usr/share/sandbox/kit/${KIT}" "${OUT}/build.log" || fail "the build did not go through the kit frontend (no staged sources in ${OUT}/build.log)"
grep -qF "${SBX_KIT_FRONTEND#*@}" "${OUT}/build.log" || fail "the build log does not show the pinned frontend ${SBX_KIT_FRONTEND}"
sbx_build_env_down >> "${OUT}/build-env.log" 2>&1 || fail "$(tail -1 "${OUT}/build-env.log")"
# the probe steps' own output lines, as build-env.sh copied them to the log
[ "$(grep -cE '^#[0-9]+ [0-9.]+ IMDS-PROBE-RAN-[0-9]+$' "${OUT}/build-env.log")" -eq 2 ] || fail "${OUT}/build-env.log does not hold the probe's marker line for both probes"
grep -qE '^#[0-9]+ [0-9.]+ IMDS-PROBE-STATUS 401$' "${OUT}/build-env.log" || fail "${OUT}/build-env.log does not hold the control probe's HTTP 401"
echo "ok 2 - kit built through ${SBX_KIT_FRONTEND} into ${OUT}/oci and loaded as ${IMAGE}; builder ${SBX_BUILDER} on ${SBX_BUILD_NET} only: a build step got metadata-service HTTP ${SBX_IMDS_BEFORE} before the DOCKER-USER rule and ${SBX_IMDS_AFTER} (no answer) after it, its marker line in build-env.log both times; rule removed"

# 3. conformance
"${KIT_TCK}" validate --verbose --color never --layout "${OUT}/oci" "${TAG}" > "${OUT}/kit-tck.txt" 2>&1
RC=$?
[ ${RC} -eq 0 ] && grep -q "conforms" "${OUT}/kit-tck.txt" || fail "kit-tck validate failed (exit ${RC}): $(grep -E '✗|FAIL|fail' "${OUT}/kit-tck.txt" | head -5)"
echo "ok 3 - kit-tck: $(grep -E 'checks ·' "${OUT}/kit-tck.txt" | xargs)"

# 4. image config
docker image inspect "${IMAGE}" > "${OUT}/image-inspect.json" || fail "cannot inspect ${IMAGE}"
jq -e '.[0].Config
	| .User == "root"
	and .WorkingDir == "/root/workspace"
	and .Entrypoint == ["claude"]
	and .Labels["com.docker.sandboxes.start-docker"] == "true"
	and (.Env | index("BASH_ENV=/etc/sandbox-persistent.sh"))
	and (.Env | index("IS_SANDBOX=1"))
	and (.Env | index("CLAUDE_CODE_USE_BEDROCK=1"))
	and (.Env | index("AWS_REGION=us-east-1"))
	and (.Env | index("ANTHROPIC_DEFAULT_SONNET_MODEL=us.anthropic.claude-sonnet-4-5-20250929-v1:0"))
	and (.Env | index("ANTHROPIC_DEFAULT_HAIKU_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0"))
	and (.Env | map(select(test("^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|BEARER_TOKEN_BEDROCK|PROFILE)="))) | length == 0)
	and (.Env | index("NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt"))
	and (.Env | index("TIKTOKEN_CACHE_DIR=/opt/tiktoken-cache"))
	and (.Env | index("LITELLM_LOCAL_MODEL_COST_MAP=True"))
	and (.Env | index("HF_HUB_OFFLINE=1"))' "${OUT}/image-inspect.json" > /dev/null \
	|| fail "image config is not the declared contract: $(jq -c '.[0].Config | {User, WorkingDir, Entrypoint, Labels}' "${OUT}/image-inspect.json")"
echo "ok 4 - image config: user root, workdir /root/workspace, entrypoint claude, start-docker label, sandbox environment (incl. the proxy CA for Node)"

# 5. published descriptor
"${KIT_TCK}" inspect --descriptor --color never --layout "${OUT}/oci" "${TAG}" > "${OUT}/published-descriptor.yaml" 2>&1 || fail "kit-tck inspect --descriptor failed"
{ echo "# syntax=docker/sandbox-kit:3"; cat "${OUT}/published-descriptor.yaml"; } > "${OUT}/published-descriptor.checked.yaml"
python3 "${SBX_DIR}/test/check-descriptor.py" "${OUT}/published-descriptor.checked.yaml" > "${OUT}/published-check.txt" 2>&1 \
	|| fail "the published descriptor breaks the delivery invariants: $(cat "${OUT}/published-check.txt")"
# e2e.sh's provenance checks: the recipe kit-tck reads from the artifact (its
# preflight, for a pushed image) and the one staged in the image (its
# provenance layer) are byte for byte the rendered dockerfile.
"${KIT_TCK}" inspect --dockerfile --layout "${OUT}/oci" "${TAG}" > "${OUT}/published-recipe.dockerfile" 2>&1 || fail "kit-tck inspect --dockerfile failed"
cmp -s "${OUT}/published-recipe.dockerfile" "${APP}/${KIT}.dockerfile" || fail "kit-tck's recipe is not the rendered ${KIT}.dockerfile"
STAGED=$(docker run --rm --entrypoint sha256sum "${IMAGE}" "/usr/share/sandbox/kit/${KIT}/kit.dockerfile" | awk '{print $1}')
[ "${STAGED}" = "$(sha256sum < "${APP}/${KIT}.dockerfile" | awk '{print $1}')" ] || fail "the recipe staged in the image is not the rendered ${KIT}.dockerfile"
echo "ok 5 - the published descriptor carries the delivery's capabilities and passes check-descriptor.py; the published and staged recipe are the rendered dockerfile"

# 6. contents
docker run --rm --entrypoint bash "${IMAGE}" -c '
	command -v dockerd && docker --version && docker compose version && claude --version || exit 1
	node -e "const e=JSON.parse(require(\"fs\").readFileSync(\"/home/agent/.claude/settings.json\",\"utf8\")).env||{}; const ok=e.CLAUDE_CODE_USE_BEDROCK===\"1\" && [\"AWS_REGION\",\"ANTHROPIC_DEFAULT_SONNET_MODEL\",\"ANTHROPIC_DEFAULT_HAIKU_MODEL\"].every(k => process.env[k] && e[k]===process.env[k]) && !Object.keys(e).some(k => /^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|BEARER_TOKEN_BEDROCK|PROFILE)$/.test(k)); if (!ok) console.log(\"settings.json env: \" + JSON.stringify(Object.keys(e))); process.exit(ok ? 0 : 1)" || exit 1
	test -n "$(ls -A "${TIKTOKEN_CACHE_DIR}")" || exit 1
	H=/home/hindsight/.cache/huggingface/hub
	for mv in models--BAAI--bge-small-en-v1.5=5c38ec7c405ec4b44b94cc5a9bb96e735b38267a \
		models--hindsight-ai--hs-rerank-1=927f5be31280298a51cf29af8a29cb111ed812c5; do
		m=${mv%%=*}; v=${mv#*=}
		[ "$(cat "${H}/${m}/refs/main")" = "${v}" ] || { echo "${m}: refs/main is not the pinned ${v}"; exit 1; }
		[ "$(ls "${H}/${m}/snapshots")" = "${v}" ] || { echo "${m}: snapshots other than ${v}"; exit 1; }
		test -s "${H}/${m}/snapshots/${v}/model.safetensors" || exit 1
		if find "${H}/${m}/" -name "*.bin" | grep -q .; then echo "${m}: pickle weights cached"; exit 1; fi
	done
' > "${OUT}/contents.txt" 2>&1 || fail "image contents check failed: $(cat "${OUT}/contents.txt")"
echo "ok 6 - dockerd, docker compose and claude are in the image; settings.json selects Bedrock with the image's region and model pins, no AWS credential; the tiktoken and model caches are filled"

# 7. two overlapping build runs
OV=${OUT}/overlap
rm -rf "${OV}"
mkdir -p "${OV}"
export SBX_DIR OV
bash -c '. "${SBX_DIR}/build-env.sh"
	sbx_build_env_up > "${OV}/a-up.log" 2>&1 || exit 1
	echo "${SBX_RULE_TAG}" > "${OV}/a.tag"
	sudo -n iptables -S DOCKER-USER | grep -qF "\"${SBX_RULE_TAG}\"" && echo present > "${OV}/a.check" || echo missing > "${OV}/a.check"
	sbx_build_env_down || exit 1
	echo "tag=${SBX_RULE_TAG} subnet=${SBX_BUILD_SUBNET}" > "${OV}/a.cleared"
	touch "${OV}/a.down1"
	for _ in $(seq 1 600); do [ -e "${OV}/b.up" ] && break; sleep 1; done
	sbx_build_env_down || exit 1
	touch "${OV}/a.down2"' > "${OV}/a.log" 2>&1 &
RUN_A=$!
bash -c 'for _ in $(seq 1 600); do [ -e "${OV}/a.down1" ] && break; sleep 1; done
	. "${SBX_DIR}/build-env.sh"
	sbx_build_env_up > "${OV}/b-up.log" 2>&1 || exit 1
	echo "${SBX_RULE_TAG}" > "${OV}/b.tag"
	touch "${OV}/b.up"
	for _ in $(seq 1 600); do [ -e "${OV}/a.down2" ] && break; sleep 1; done
	sudo -n iptables -S DOCKER-USER | grep -qF "\"${SBX_RULE_TAG}\"" && echo present > "${OV}/b.check" || echo missing > "${OV}/b.check"
	sbx_build_env_down || exit 1
	sudo -n iptables -S DOCKER-USER | grep -qF "\"$(cat "${OV}/b.tag")\"" && echo left > "${OV}/b.after" || echo removed > "${OV}/b.after"' > "${OV}/b.log" 2>&1 &
RUN_B=$!
wait "${RUN_A}" || fail "overlap: run A failed: $(cat "${OV}/a.log" "${OV}/a-up.log" 2> /dev/null | tail -3)"
wait "${RUN_B}" || fail "overlap: run B failed: $(cat "${OV}/b.log" "${OV}/b-up.log" 2> /dev/null | tail -3)"
[ "$(cat "${OV}/a.check")" = "present" ] || fail "overlap: run A's rule was not in DOCKER-USER after its setup"
[ "$(cat "${OV}/a.cleared")" = "tag= subnet=" ] || fail "overlap: run A's teardown left $(cat "${OV}/a.cleared") set, so a second call is not a no-op"
[ "$(cat "${OV}/a.tag")" != "$(cat "${OV}/b.tag")" ] || fail "overlap: both runs used the same rule tag"
[ "$(cat "${OV}/b.check")" = "present" ] || fail "overlap: run A's second teardown removed run B's rule"
[ "$(cat "${OV}/b.after")" = "removed" ] || fail "overlap: run B's own teardown left its rule"
echo "ok 7 - overlapping runs: run A's second teardown left run B's rule ($(cat "${OV}/b.tag")) in place; B removed it itself"

echo "Sandbox test2 succeeded"
