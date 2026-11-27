# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# Docker Sandboxes (sbx) layer for the do-agent-aws harness.
#
# to/sandbox/render.sh appends this file to the repository Dockerfile, so the
# sandbox image is the harness image built from this repository (same base,
# same Container-Root, same setup.sh) followed by the steps below. Nothing
# above this point is changed. See to/sandbox/README.md.
# ---------------------------------------------------------------------------

# nosemgrep: last-user-is-root -- the sandbox runs Docker Engine inside the Docker Sandboxes microVM, the isolation boundary (to/sandbox/README.md "Identity"); the harness image itself runs as the agent user
USER root

# Docker Engine inside the sandbox microVM. The agent builds, runs and tests
# Compose stacks against this engine; the microVM is the security boundary and
# no host Docker socket is involved. The runtime starts dockerd for images
# labeled com.docker.sandboxes.start-docker=true (label below); the kit's
# startup hook is the fallback. Versions are pinned to download.docker.com
# jammy/stable as of 2026-10-02 (InRelease date).
ARG SBX_DOCKER_CE_VERSION=5:29.8.2-1~ubuntu.22.04~jammy
ARG SBX_CONTAINERD_VERSION=2.3.6-1~ubuntu.22.04~jammy
ARG SBX_BUILDX_VERSION=0.37.1-1~ubuntu.22.04~jammy
ARG SBX_COMPOSE_VERSION=5.6.0-1~ubuntu.22.04~jammy
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable" > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        docker-ce=${SBX_DOCKER_CE_VERSION} \
        docker-ce-cli=${SBX_DOCKER_CE_VERSION} \
        containerd.io=${SBX_CONTAINERD_VERSION} \
        docker-buildx-plugin=${SBX_BUILDX_VERSION} \
        docker-compose-plugin=${SBX_COMPOSE_VERSION} \
        iptables procps ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    docker --version; \
    docker compose version
LABEL com.docker.sandboxes.start-docker="true"

# Platform contract (kit capability com.docker.sandbox/sbx@1):
# - /usr/local/share/ca-certificates must exist: the runtime writes its egress
#   proxy CA there and merges it into the system trust bundle at start (the
#   proxy terminates TLS to inject credentials, so every client must trust it;
#   the ENV block below points Node/Bun, Python requests and curl at that bundle);
# - BASH_ENV names a shipped file, so the environment the sandbox adds reaches
#   the agent, which the host launches under non-interactive bash; login and
#   interactive shells read the same file;
# - /root/workspace is the agent's working directory (WORKDIR below).
RUN set -eux; \
    mkdir -p /usr/local/share/ca-certificates /root/workspace; \
    printf '%s\n' '. /etc/sandbox-persistent.sh' > /etc/profile.d/sandbox-persistent.sh; \
    printf '\n%s\n' '. /etc/sandbox-persistent.sh' >> /home/agent/.bashrc
# /etc/sandbox-persistent.sh (BASH_ENV, and sourced by login/interactive shells and
# /etc/profile.d above) makes the lower-case and upper-case proxy variables agree. The sbx
# runtime injects its egress proxy as upper-case HTTP_PROXY/HTTPS_PROXY/NO_PROXY; the harness
# .env also exports empty lower-case http_proxy=/https_proxy= (correct on a host with no proxy),
# and those empty values otherwise shadow the upper-case ones for clients that read the
# lower-case names - notably Python urllib/botocore, used by the memory API (hindsight-api),
# which then bypasses the proxy and never gets the proxy-injected Bedrock key (AWS answers 403
# "Invalid API Key format"). See to/sandbox/README.md "Model credential".
COPY to/sandbox/template/sandbox-persistent.sh /etc/sandbox-persistent.sh

# Model provider: Amazon Bedrock, the harness's own default, selected in both
# places the harness uses: the process environment (the ENV line below) and
# the "env" block of /home/agent/.claude/settings.json, which overrides the process
# environment for every claude process. The sandbox holds no AWS credentials:
# the kit's proxy-managed credential (service bedrock) sets
# AWS_BEARER_TOKEN_BEDROCK to a sentinel, with which Claude Code authenticates
# instead of the AWS credential chain, and the host-side proxy puts the real
# short-term Bedrock API key in the Authorization header of requests to
# bedrock-runtime.us-east-1.amazonaws.com. The region and the models are
# pinned: the kit's allowlist admits only that region's runtime endpoint, and
# the IAM policy of the host's instance role names these inference profiles
# (to/sandbox/README.md "Model credential"). ANTHROPIC_DEFAULT_HAIKU_MODEL is
# the small/fast (background) model variable current Claude Code reads
# (code.claude.com/docs/en/amazon-bedrock, "Pin model versions", read
# 2026-10-08, calls ANTHROPIC_SMALL_FAST_MODEL deprecated; Claude Code 2.1.287
# migrates that name to ANTHROPIC_DEFAULT_HAIKU_MODEL). With
# ANTHROPIC_DEFAULT_SONNET_MODEL set and ANTHROPIC_DEFAULT_OPUS_MODEL not, the
# pinned Sonnet stays the default model (same page). The build fails unless
# the settings file carries exactly the values of the ENV line; it also fails
# if the settings file names any AWS credential variable, if it or the
# environment sets a model variable that would replace the pinned Sonnet as
# the default (ANTHROPIC_MODEL, ANTHROPIC_DEFAULT_OPUS_MODEL,
# ANTHROPIC_DEFAULT_MODEL), or if either sets an AWS_DEFAULT_REGION other than
# AWS_REGION.
ENV CLAUDE_CODE_USE_BEDROCK=1 \
    AWS_REGION=us-east-1 \
    ANTHROPIC_DEFAULT_SONNET_MODEL=us.anthropic.claude-sonnet-4-5-20250929-v1:0 \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0
RUN set -eux; \
    node -e 'const fs=require("fs");const f="/home/agent/.claude/settings.json";const s=JSON.parse(fs.readFileSync(f,"utf8"));const e={};for(const k of ["CLAUDE_CODE_USE_BEDROCK","AWS_REGION","ANTHROPIC_DEFAULT_SONNET_MODEL","ANTHROPIC_DEFAULT_HAIKU_MODEL"])e[k]=process.env[k];s.env=Object.assign({},s.env,e);fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n");'; \
    node -e 'const s=JSON.parse(require("fs").readFileSync("/home/agent/.claude/settings.json","utf8"));const e=s.env||{};if(e.CLAUDE_CODE_USE_BEDROCK!=="1"){console.error("settings.json does not select Bedrock");process.exit(1)}for(const k of ["CLAUDE_CODE_USE_BEDROCK","AWS_REGION","ANTHROPIC_DEFAULT_SONNET_MODEL","ANTHROPIC_DEFAULT_HAIKU_MODEL"]){if(!process.env[k]||e[k]!==process.env[k]){console.error("settings.json and the environment differ on "+k);process.exit(1)}}if(Object.keys(e).some(k=>/^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|BEARER_TOKEN_BEDROCK|PROFILE)$/.test(k))){console.error("settings.json carries an AWS credential setting");process.exit(1)}for(const k of ["ANTHROPIC_MODEL","ANTHROPIC_DEFAULT_OPUS_MODEL","ANTHROPIC_DEFAULT_MODEL"]){if(k in e||process.env[k]!==undefined){console.error("settings.json or the environment sets "+k+", which would replace the pinned Sonnet as the default model");process.exit(1)}}for(const r of [e.AWS_DEFAULT_REGION,process.env.AWS_DEFAULT_REGION]){if(r!==undefined&&r!==process.env.AWS_REGION){console.error("AWS_DEFAULT_REGION ("+r+") disagrees with AWS_REGION ("+process.env.AWS_REGION+")");process.exit(1)}}'

# The harness memory API (hindsight-api) must start inside the allowlist, which
# admits only the model API and Docker Hub. At startup it downloads, and exits
# when it cannot: tiktoken's cl100k_base encoding (openaipublic.blob.core.
# windows.net) and its default embedding and reranking models (huggingface.co:
# BAAI/bge-small-en-v1.5, hindsight-ai/hs-rerank-1 since hindsight 1.x); litellm also
# tries its model cost map (raw.githubusercontent.com). All of it is fetched
# here at build time. The models come as the hindsight user, into its Hugging
# Face cache, at pinned revisions and safetensors only; refs/main is pointed at
# each pinned revision, because hindsight-api asks for "main". Both models are
# then loaded once with the hub offline, as they will be in the sandbox.
ARG SBX_BGE_REVISION=5c38ec7c405ec4b44b94cc5a9bb96e735b38267a
ARG SBX_RERANKER_REVISION=927f5be31280298a51cf29af8a29cb111ed812c5
ENV TIKTOKEN_CACHE_DIR=/opt/tiktoken-cache \
    LITELLM_LOCAL_MODEL_COST_MAP=True
RUN set -eux; \
    HPY=/home/hindsight/.local/share/uv/tools/hindsight-api/bin/python; \
    mkdir -p "${TIKTOKEN_CACHE_DIR}"; \
    "${HPY}" -c 'import tiktoken; assert tiktoken.get_encoding("cl100k_base").encode("ok")'; \
    chmod -R a+rX "${TIKTOKEN_CACHE_DIR}"; \
    test -n "$(ls -A "${TIKTOKEN_CACHE_DIR}")"; \
    runuser -u hindsight -- env HOME=/home/hindsight "${HPY}" -c 'import sys; from huggingface_hub import snapshot_download; [snapshot_download(r, revision=v, allow_patterns=["*.json", "*.txt", "model.safetensors", "1_Pooling/*"]) for r, v in (("BAAI/bge-small-en-v1.5", sys.argv[1]), ("hindsight-ai/hs-rerank-1", sys.argv[2]))]' \
        "${SBX_BGE_REVISION}" "${SBX_RERANKER_REVISION}"; \
    H=/home/hindsight/.cache/huggingface/hub; \
    for mv in "models--BAAI--bge-small-en-v1.5=${SBX_BGE_REVISION}" "models--hindsight-ai--hs-rerank-1=${SBX_RERANKER_REVISION}"; do \
        m=${mv%%=*}; v=${mv#*=}; \
        runuser -u hindsight -- sh -c "mkdir -p '${H}/${m}/refs' && printf %s '${v}' > '${H}/${m}/refs/main'"; \
        test -s "${H}/${m}/snapshots/${v}/model.safetensors"; \
        ! find "${H}/${m}/snapshots/${v}/" -name '*.bin' | grep -q .; \
    done; \
    runuser -u hindsight -- env HOME=/home/hindsight HF_HUB_OFFLINE=1 "${HPY}" -c 'from sentence_transformers import SentenceTransformer, CrossEncoder; SentenceTransformer("BAAI/bge-small-en-v1.5"); CrossEncoder("hindsight-ai/hs-rerank-1")'
ENV HF_HUB_OFFLINE=1

# The do-agent-aws platform's on-switches for the sandbox target. The repository
# .env (which run.sh hands the container on the docker target) is not in the
# image, so the image's own defaults decide what /startup.sh brings up. UI_START
# is the master switch for the harness UIs - startup.sh starts none without it.
# Two spokes are OFF here on purpose: conversations and issues reach services the
# kit's deny-all allowlist does not admit (Slack and GitHub), so they could not do
# their work in the sandbox even with a token - a documented OFF that
# /agent/ui-status.sh prints. The spokes left on (insights, clusters, sessions,
# loops) run from the image's vendored sources with no egress beyond the
# allowlist. The same values are written to an env file the boot hook sources
# (template/do-agent-aws-sandbox.yaml), so the hook's /startup.sh and a later
# `sbx exec /agent/ui-status.sh` agree on what is enabled.
ENV UI_START=true \
    SPOKE_CONVERSATIONS=false \
    SPOKE_ISSUES=false
RUN set -eux; \
    { echo "export UI_START=${UI_START}"; \
      echo "export SPOKE_CONVERSATIONS=${SPOKE_CONVERSATIONS}"; \
      echo "export SPOKE_ISSUES=${SPOKE_ISSUES}"; } > /etc/do-agent-aws-sandbox.env

# IS_SANDBOX=1 tells Claude Code it runs inside a deliberate sandbox, which it
# requires before it accepts bypassPermissions as root.
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 turns off telemetry, error
# reporting and update checks, so the agent needs no Anthropic host in the
# allowlist: its only model endpoint is the Bedrock runtime.
ENV BASH_ENV=/etc/sandbox-persistent.sh \
    IS_SANDBOX=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# nosemgrep: last-user-is-root -- the sandbox runs Docker Engine inside the Docker Sandboxes microVM, the isolation boundary (to/sandbox/README.md "Identity"); the harness image itself runs as the agent user
USER root
WORKDIR /root/workspace
# The software bill of materials once more, after this layer: the repository
# Dockerfile's last step wrote /SBOM.txt before the Docker Engine packages above
# existed, so the kit image's copy is regenerated here and /test-sbom.sh finds
# every installed package in it (docs/manual/supply-chain.md "Software bill of materials").
RUN /sbom.sh
# The agent sbx launches for an interactive session: Claude Code with the
# harness configuration. Scripted work uses sbx exec (to/sandbox/test/e2e.sh).
ENTRYPOINT ["claude"]
CMD []
