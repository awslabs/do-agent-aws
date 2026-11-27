# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
ARG BASE_IMAGE_PATH="public.ecr.aws/ubuntu/ubuntu:22.04@sha256:bea3e9ce454d8bbd1fc005efd77dd06e9ac3bcdeceb3efd9d2e0c7d6fc1a11e7"

FROM $BASE_IMAGE_PATH

ARG BUILD="20260824"
ARG MAINTAINER="awslabs/aws-do-framework (https://github.com/orgs/awslabs/teams/aws-do-framework)"
ARG DESCRIPTION="Depend on Docker Image - agentic harness"
ARG http_proxy
ARG https_proxy
ARG no_proxy

LABEL MAINTAINER="$MAINTAINER"

LABEL DESCRIPTION="$DESCRIPTION"

LABEL BUILD="$BUILD"

COPY Container-Root /

# The agent runs as the unprivileged user agent (AGENT_UID:AGENT_GID, 1000:1000 by default - the uid the rootless
# BuildKit daemon's socket and a typical Linux host user have), never as root (docs/manual/install.md "Container user"). The build
# runs as root with HOME=/home/agent, so everything setup.sh installs into a home directory (nvm, uv tools, Claude Code
# plugins and settings, the hindsight hooks) lands in the agent's home with the agent's paths; the last steps hand the
# home to the agent and switch to it.
ARG AGENT_UID=1000
ARG AGENT_GID=1000
RUN groupadd --gid ${AGENT_GID} agent && useradd --uid ${AGENT_UID} --gid ${AGENT_GID} --create-home --home-dir /home/agent --shell /bin/bash agent
ENV HOME=/home/agent

# Keep Claude Code's mutable configuration file (.claude.json) inside ~/.claude so the whole agent
# state persists through the agent-state mounts declared in .env (a bare file cannot be volume-mounted).
# Set before setup.sh so build-time plugin installs write their registrations to the same location.
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude

# The hindsight coding-agents installer version (setup/install-hindsight.sh); a build arg so the build-time
# control `docker build --build-arg HINDSIGHT_CODING_AGENTS_VERSION=9.9.9 .` can prove a failed installer
# fails the build (setup.sh's outcome check)
# Claude Code's version: pinned (.env CLAUDE_CODE_VERSION passes it; "latest" there installs the newest)
ARG CLAUDE_CODE_VERSION=2.1.327
ARG HINDSIGHT_CODING_AGENTS_VERSION=0.8.1

# `/setup.sh && rm`: the step's status is setup.sh's, not rm's - a failed installer fails the build. The homes setup.sh
# filled are handed to the agent IN THE SAME LAYER: a chown -R in a later layer copies every file of them again (the
# image grew from 16 GB to 31 GB that way); the last step below only hands over what the steps between created.
RUN export http_proxy=$http_proxy; export https_proxy=$https_proxy; export no_proxy=$no_proxy; export HINDSIGHT_CODING_AGENTS_VERSION=$HINDSIGHT_CODING_AGENTS_VERSION; export CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION; /setup.sh && rm -f /setup.sh \
    && chown -R agent:agent /home/agent /home/hindsight /var/log/nginx /var/lib/nginx

# The user guide: rendered into the home page's Guide tile at every start by /agent/home-render.sh (/agent/md2html.py).
# Copied AFTER setup.sh so a documentation edit never rebuilds the setup layer (setup.sh does not read /docs).
COPY docs/user-guide.md /docs/user-guide.md
# The README, served locally at /guide/readme/ as the footer's help links (the repository is private, so a GitHub link is a 404 for most)
COPY README.md /docs/README.md
# the manual, served at /guide/manual/ one page per topic; the footer's help links land on its sections
COPY docs/manual /docs/manual
# the README's How it works picture, served at /guide/img/ for the rendered README
COPY docs/img/how-it-works.svg /docs/img/how-it-works.svg
# the North Star register and the GA release page, served at /guide/north-star/ and /guide/ga-release/ like the README
COPY docs/NORTH-STAR.md /docs/NORTH-STAR.md
COPY docs/GA-RELEASE.md /docs/GA-RELEASE.md
# the agent stack and how its agents talk, served at /guide/agent-stack/ and /guide/messaging/
COPY docs/AGENT-STACK.md /docs/AGENT-STACK.md
COPY docs/INTER-AGENT-MESSAGING.md /docs/INTER-AGENT-MESSAGING.md
# how harnesses share knowledge, served at /guide/knowledge-sharing/ (the Knowledge transfer page links it)
COPY docs/knowledge-sharing.md /docs/knowledge-sharing.md
# the cluster lock and its GPU leases, which the clusters charter and the agent's operating rules point at
COPY docs/cluster-lock.md /docs/cluster-lock.md
# the operator's overlay example (docs/manual/autonomy.md "Parity with a native instance"): the stub /agent/claude-overlay.sh writes at /wd/CLAUDE.md
# when none exists points at this copy
COPY docs/parity/CLAUDE.md.example /agent/CLAUDE.md.example
# the North Star register as data (docs/north-star.json): the home page renders its North Star section from this file,
# and test-board.sh fails when the page, docs/NORTH-STAR.md and the file disagree - one source, shipped where the renderer runs
COPY docs/north-star.json /agent/north-star.json

ENV CLAUDE_CODE_USE_BEDROCK=1
ENV CLAUDE_MEM_WELCOME_HINT_ENABLED=false

# tmux draws a pane's non-ASCII cells as line-art escapes and underscores for any attached client
# whose locale is not UTF-8 - with no locale set, both the browser terminal (ttyd's tmux client) and
# a "tmux attach" from the container shell degrade the Claude CLI's box graphics to ____ while the
# plain (tmux-less) shell renders them. C.UTF-8 ships in the ubuntu base; no locales package needed.
ENV LANG=C.UTF-8

# the image's build stamp (BUILD, its BUILD label) where a process inside can read it: a knowledge pack's manifest names
# the image build it was exported from (/agent/knowledge-transfer.py)
ENV AGENT_BUILD=$BUILD

# The software bill of materials, LAST: /sbom.sh (/agent/sbom.py) lists every third-party component the layers above put in
# the image - the dpkg packages, every npm package, every Python distribution, and the tools /setup/third-party.txt names -
# one `<name> <version> - <license>` line each, into /SBOM.txt (docs/manual/supply-chain.md "Software bill of materials"). A step after this
# one would not be listed; the sandbox kit's dockerfile runs it again after its own layer. A failure fails the build.
# ./build.sh copies the file out of the image as THIRD-PARTY-LICENSES at the repository root.
# git refuses a repository another user owns, and root runs this step over the agent's home, which setup.sh's layer
# handed to the agent: the image's own checkouts there are named safe for this one step (environment only, nothing
# written to a git config)
RUN GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' /sbom.sh

# The agent's home and the memory API's home (its embedded PostgreSQL data, model cache and tool install) belong to the
# agent, which runs every process of the container; the image's own files stay root's, read-only to the agent. setup.sh's
# layer handed them over; this step hands over only what the steps after it created (find ... ! -user agent), so no file
# is copied into a layer twice. Claude
# Code updates come with the image, not from a running container (its install is the image's).
# The image's git checkouts that the agent reads (the SBOM's version probes) are root's: git refuses another user's repository
# unless it is named safe, and these are read-only to the agent
RUN find /home/agent /home/hindsight /var/log/nginx /var/lib/nginx \( ! -user agent -o ! -group agent \) -exec chown -h agent:agent {} + \
    && git config --system --add safe.directory /opt/kubectx \
    && git config --system --add safe.directory /opt/claude-marketplaces/oh-my-claudecode \
    && git config --system --add safe.directory /opt/comms
ENV DISABLE_AUTOUPDATER=1
USER agent

WORKDIR /agent

CMD /startup.sh

