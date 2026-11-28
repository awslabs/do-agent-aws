#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# tmux-agent dashboard - install (or update) the dashboard from source.
#
# Called by /agent/ui-start.sh when UI_TMUX_AGENT=true and there is no finished install of
# TMUX_AGENT_REF from TMUX_AGENT_SRC (the stamp file below); it can also be run by hand inside
# the container at any time. Idempotent: an existing checkout is fetched and moved to the
# requested ref, a missing one is created; dependencies and the build are redone on every run
# (npm ci reinstalls node_modules each time, so a run always costs a full install - which is why
# ui-start.sh runs it only when the stamp does not match its settings). The dashboard is fetched at
# container start from its default source, the public repository dmvevents/tmux-agent-public at the
# commit TMUX_AGENT_REF pins in .env (the image's prebuilt copy at /opt/tmux-agent is that same
# commit, served when TMUX_AGENT_SRC is empty), or from any other clone the operator can reach.
#
# Settings (all overridable via environment; declared in .env and passed through by run.sh,
# the compose template, and the kubernetes deployment):
#   TMUX_AGENT_SRC         - where to fetch from: any URL git accepts (https, ssh, a token URL
#                            https://<token>@github.com/...) or a local path visible inside the
#                            container (for example a clone under the /wd volume). Default
#                            https://github.com/dmvevents/tmux-agent-public.git, the public
#                            source; .env sets it by value and pins TMUX_AGENT_REF. A token URL
#                            is never written to .env: export it in the host shell, the bare -e
#                            passes it through.
#   TMUX_AGENT_REF         - branch, tag or commit to build (default the v0.1.1 commit; .env pins a commit of the
#                            public source - see .env)
#   TMUX_AGENT_INSTALL_DIR - the checkout + build (default /wd/ui/tmux-agent: on the /wd volume,
#                            so it survives container restarts, but not directly under /wd,
#                            where starter-repo.sh and vk-runner-repos.sh take a git repository
#                            for the user's own). NOT TMUX_AGENT_HOME: that name is the
#                            dashboard's own state directory (ledger, web-token, lexicon;
#                            default ~/.tmux-agent) and must stay the dashboard's.
#
# The checkout is a bare "git init" + "git fetch <src> <ref>" rather than a clone, so no remote
# is recorded: a token URL is used for the fetch and never written to .git/config on the /wd
# volume. Any URL this script prints has its credentials masked (user:token@ -> ***@).
#
# The LAST step writes ${TMUX_AGENT_INSTALL_DIR}/.install-stamp (the ref, the source with any
# credential masked, and the commit built); a run that changes the checkout removes it first. So
# a stamp exists only for a build that finished, and ui-start.sh starts the dashboard only when
# the stamp matches its TMUX_AGENT_REF and its masked TMUX_AGENT_SRC - nothing credential-derived
# is written to the /wd volume, and a rotated token is the same source (no rebuild). A failed or
# interrupted install (tsc
# still emits dist/ when type-checking fails) is never served, and a changed ref or source is
# re-installed on the next start. Each git step is bounded (GIT_TIMEOUT below) and never
# prompts (no terminal prompt, ssh in batch mode), so a dead source fails instead of hanging the
# container start.
#
# Exit 0 with dist/bin/tmux-agent.js built and the stamp written. Exit 1 with ONE plain stderr
# line naming the fix when the source is not reachable, the ref does not exist there, a tool is
# missing, or the build does not produce the dashboard.

export HOME=${HOME:-/home/agent}
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

TMUX_AGENT_SRC=${TMUX_AGENT_SRC:-https://github.com/dmvevents/tmux-agent-public.git}
TMUX_AGENT_REF=${TMUX_AGENT_REF:-92113b54b755cffc7666c0f475cb706b38d9ade9}  # tag v0.1.1
TMUX_AGENT_INSTALL_DIR=${TMUX_AGENT_INSTALL_DIR:-/wd/ui/tmux-agent}
STAMP=${TMUX_AGENT_INSTALL_DIR:?}/.install-stamp
# seconds each git step (ls-remote, fetch, checkout) may take
GIT_TIMEOUT=120
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}

# mask <text> - the same URL with any user:token@ credential blanked, for every line we print
mask()
{
	echo "$1" | sed -E 's#(://)[^/@[:space:]]+@#\1***@#g'
}

SRC_SHOWN=$(mask "${TMUX_AGENT_SRC}")

fail()
{
	echo "tmux-agent install: $1" >&2
	exit 1
}

# npm lives under nvm in this image (setup/install-nodejs.sh); a non-interactive shell has to
# load it the way setup/install-vibe-kanban.sh does. node itself is /usr/local/bin/node.
if ! command -v npm > /dev/null 2>&1; then
	export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
	[ -s "${NVM_DIR}/nvm.sh" ] && \. "${NVM_DIR}/nvm.sh" > /dev/null 2>&1
fi
command -v git > /dev/null 2>&1 || fail "git not found: install git (the image gets it from setup/install-comms.sh)"
command -v npm > /dev/null 2>&1 || fail "npm not found: install Node.js >= 20 with npm (the image gets it from setup/install-nodejs.sh)"
command -v node > /dev/null 2>&1 || fail "node not found: install Node.js >= 20 (the image gets it from setup/install-nodejs.sh)"

# git prints the URL it was given in its own errors, so its output is captured and masked
# before anything reaches the log
GIT_OUT=$(mktemp /tmp/tmux-agent-install-XXXXXX)
trap 'rm -f "${GIT_OUT:?}"' EXIT

git_masked()
{
	# git_masked <args...> - run git (bounded by GIT_TIMEOUT), keep its output masked; false on failure
	timeout ${GIT_TIMEOUT} git "$@" > "${GIT_OUT}" 2>&1
	RC=$?
	mask "$(cat "${GIT_OUT}")" | grep -v '^$'
	return ${RC}
}

# --- 1. the source must be reachable before anything is created or touched ---
echo "tmux-agent install: source ${SRC_SHOWN} ref ${TMUX_AGENT_REF} -> ${TMUX_AGENT_INSTALL_DIR}"
if ! timeout ${GIT_TIMEOUT} git ls-remote -q -- "${TMUX_AGENT_SRC}" HEAD > "${GIT_OUT}" 2>&1; then
	mask "$(cat "${GIT_OUT}")" | grep -v '^$' | sed 's/^/tmux-agent install: git: /'
	fail "source not reachable: set TMUX_AGENT_SRC to a clone you can reach (path, ssh or token URL), or empty to serve the vendored build (source given: ${SRC_SHOWN})"
fi

# --- 2. checkout: create or update, then move to the ref ---
mkdir -p "${TMUX_AGENT_INSTALL_DIR}" || fail "cannot create ${TMUX_AGENT_INSTALL_DIR}: set TMUX_AGENT_INSTALL_DIR to a writable directory"
# from here on the checkout changes, so the old stamp goes first: it comes back only at the end
rm -f "${STAMP:?}" || fail "cannot remove ${STAMP}: set TMUX_AGENT_INSTALL_DIR to a writable directory"
if [ ! -d "${TMUX_AGENT_INSTALL_DIR}/.git" ]; then
	git_masked -C "${TMUX_AGENT_INSTALL_DIR}" init -q || fail "git init failed in ${TMUX_AGENT_INSTALL_DIR}"
fi
# a branch or tag is fetched by name (and a full commit sha, which the usual servers allow);
# anything else is a ref the source does not have
if ! git_masked -C "${TMUX_AGENT_INSTALL_DIR}" fetch -q --no-tags -- "${TMUX_AGENT_SRC}" "${TMUX_AGENT_REF}"; then
	fail "ref '${TMUX_AGENT_REF}' not fetched from ${SRC_SHOWN} (not there, or no answer within ${GIT_TIMEOUT}s): set TMUX_AGENT_REF to a branch, tag or commit that exists there"
fi
git_masked -C "${TMUX_AGENT_INSTALL_DIR}" checkout -q --detach FETCH_HEAD || fail "checkout of ${TMUX_AGENT_REF} failed in ${TMUX_AGENT_INSTALL_DIR} (see the git output above)"
HEAD_SHA=$(git -C "${TMUX_AGENT_INSTALL_DIR}" rev-parse --short HEAD 2>/dev/null)
echo "tmux-agent install: checked out ${TMUX_AGENT_REF} (${HEAD_SHA})"

# --- 3. dependencies + build (npm ci when a lockfile pins them, npm install otherwise) ---
cd "${TMUX_AGENT_INSTALL_DIR}" || fail "cannot enter ${TMUX_AGENT_INSTALL_DIR}"
[ -f package.json ] || fail "no package.json at ${SRC_SHOWN} ref ${TMUX_AGENT_REF}: TMUX_AGENT_SRC must point at a tmux-agent source tree"
if [ -f package-lock.json ]; then
	NPM_INSTALL="npm ci"
else
	NPM_INSTALL="npm install"
fi
echo "tmux-agent install: ${NPM_INSTALL}"
${NPM_INSTALL} --no-fund --no-audit --loglevel=error || fail "${NPM_INSTALL} failed in ${TMUX_AGENT_INSTALL_DIR} (see the npm output above; the registry must be reachable)"
echo "tmux-agent install: npm run build"
npm run build --silent || fail "npm run build failed in ${TMUX_AGENT_INSTALL_DIR} (see the build output above)"

# --- 4. the product must exist and run ---
DASHBOARD=${TMUX_AGENT_INSTALL_DIR}/dist/bin/tmux-agent.js
[ -f "${DASHBOARD}" ] || fail "build produced no ${DASHBOARD}: the source at ${SRC_SHOWN} ref ${TMUX_AGENT_REF} is not a tmux-agent tree this installer knows"
VERSION=$(node "${DASHBOARD}" --version 2>/dev/null)
echo "tmux-agent install: built ${DASHBOARD} (${VERSION:-version unknown})"

# --- 5. the stamp, LAST: only a finished install has one (ui-start.sh compares ref + masked source) ---
{
	echo "ref=${TMUX_AGENT_REF}"
	echo "source=${SRC_SHOWN}"
	echo "commit=$(git -C "${TMUX_AGENT_INSTALL_DIR}" rev-parse HEAD)"
} > "${STAMP}.tmp" && mv "${STAMP:?}.tmp" "${STAMP:?}" || fail "cannot write ${STAMP}: set TMUX_AGENT_INSTALL_DIR to a writable directory"
echo "tmux-agent install: stamp ${STAMP} written"
