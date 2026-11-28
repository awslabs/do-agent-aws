#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of what the agent runner commits. After a workspace run, vibe-kanban 0.1.44 commits the worktree with
# git add -A (add_all in crates/git/src/cli.rs), so whatever the run left there goes into the task's repository. The
# image's Claude Code plugins keep state in the working tree a session runs in: oh-my-claudecode its .omc/, ralph-loop
# its .claude/ralph-loop.local.md, Claude Code its .claude/settings.local.json.
# Each check FAILS if the property it proves is removed:
#   1. git's per-user excludes file, /home/agent/.config/git/ignore (/setup/install-plugins.sh), names that state
#   2. in a fresh repository holding that state and a project file, the runner's staging (git add -A, as root with the
#      container's git configuration) stages the project file alone
#   3. PLANTED CONTROL: the same with the excludes file switched off (core.excludesFile=/dev/null) stages the state
#      too, so check 2 proves the excludes file

fail()
{
	echo "Test21 FAILED: $1"
	exit 1
}

IGNORE=/home/agent/.config/git/ignore
D=/tmp/runner-commit

# --- 1. the excludes file names the plugins' state ---
[ -f "${IGNORE}" ] || fail "${IGNORE} is missing (/setup/install-plugins.sh writes it)"
for P in .omc/ '.claude/*.local.md' .claude/settings.local.json; do
	grep -qxF "${P}" "${IGNORE}" || fail "${IGNORE} does not name ${P}"
done
echo "ok 1 - ${IGNORE} names .omc/, .claude/*.local.md and .claude/settings.local.json"

# --- 2. the runner's staging leaves that state out ---
rm -rf "${D:?}"
mkdir -p "${D}/.omc/state" "${D}/.claude" "${D}/src"
git -C "${D}" init -q -b main || fail "git init"
echo '{"session": "test21"}' > "${D}/.omc/state/session.json"
echo "iteration 1" > "${D}/.claude/ralph-loop.local.md"
echo '{"permissions": {}}' > "${D}/.claude/settings.local.json"
echo "project" > "${D}/src/main.txt"
STAGED=$(cd "${D}" && HOME=/home/agent git add -A && git diff --cached --name-only) || fail "git add -A: ${STAGED}"
[ "${STAGED}" == "src/main.txt" ] || fail "git add -A staged more than the project file: ${STAGED//$'\n'/ }"
echo "ok 2 - git add -A stages src/main.txt alone"

# --- 3. PLANTED CONTROL: the excludes file switched off ---
git -C "${D}" read-tree --empty
STAGED=$(cd "${D}" && HOME=/home/agent git -c core.excludesFile=/dev/null add -A && git diff --cached --name-only)
echo "${STAGED}" | grep -qx ".omc/state/session.json" \
	|| fail "PLANTED CONTROL: without the excludes file .omc/ is still not staged (${STAGED//$'\n'/ }), so check 2 does not prove it"
echo "ok 3 - PLANTED CONTROL: with core.excludesFile=/dev/null git add -A stages the plugins' state too"

echo "Test21 succeeded"
