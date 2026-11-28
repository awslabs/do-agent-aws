#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# A starter repository out of the box. A fresh install's workspace (/wd) holds no git repository, so the
# agent runner's Browse opened at /home/agent on "No folders found", Create put a new repository at / and hung, and Recent was
# empty: the card-to-agent path started nowhere. When the workspace has no repository at all - itself, one level under
# it, or under its projects/ - this makes one at ${STARTER_REPO_ROOT}/projects/scratch: a README that says what it is for
# and where real repositories go, and one commit, by the operator's identity (GIT_USER_NAME, GIT_USER_EMAIL) when set,
# else the harness's own. Idempotent: an existing scratch repository is left as it is, and a workspace with any
# repository never gets one. STARTER_REPO=false opts out. Prints one line saying what it did.
# Environment: STARTER_REPO_ROOT (the workspace, default /wd), STARTER_REPO (default true), GIT_USER_NAME, GIT_USER_EMAIL.
set -u
ROOT=${STARTER_REPO_ROOT:-/wd}
REPO=${ROOT}/projects/scratch

if [ "${STARTER_REPO:-true}" != "true" ]; then
	echo "starter repo: off (STARTER_REPO=${STARTER_REPO:-})"
	exit 0
fi
if [ -d "${REPO}/.git" ]; then
	echo "starter repo: ${REPO} exists ($(git -C "${REPO}" rev-list --count HEAD 2>/dev/null || echo '?') commit(s)); nothing to do"
	exit 0
fi
HAVE=""
[ -d "${ROOT}/.git" ] && HAVE="${ROOT}"
for d in "${ROOT}"/*/ "${ROOT}"/projects/*/; do
	d=${d%/}
	[ -d "${d}/.git" ] && HAVE="${d}" && break
done
if [ -n "${HAVE}" ]; then
	echo "starter repo: the workspace ${ROOT} already holds a repository (${HAVE}); none created"
	exit 0
fi
if ! mkdir -p "${REPO}" || ! git -C "${REPO}" init -q 2>/dev/null; then
	echo "starter repo: could not create ${REPO}" >&2
	exit 1
fi
cat > "${REPO}/README.md" << 'EOT'
# scratch

A scratch repository the harness created at its first start, so the agent runner has somewhere to work out of the
box: pick it under Recent, give the agent a task, review the change here. Your own repositories go under
/wd/projects/ (clone them there in the terminal; the runner lists them after a restart, or run
/agent/vk-runner-repos.sh where the image has it). Delete this repository when you no longer need it.
EOT
git -C "${REPO}" add README.md
if git -C "${REPO}" -c user.name="${GIT_USER_NAME:-do-agent-aws harness}" -c user.email="${GIT_USER_EMAIL:-harness@do-agent-aws.local}" \
	commit -q --no-verify -m "Scratch repository for the agent runner (created by the harness at first start)"; then
	echo "starter repo: created ${REPO} (the workspace ${ROOT} held no repository) - one commit by $(git -C "${REPO}" log -1 --format='%an <%ae>')"
else
	echo "starter repo: could not commit the README in ${REPO}" >&2
	exit 1
fi
