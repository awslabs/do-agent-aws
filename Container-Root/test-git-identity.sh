#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the agent's git identity (/agent/git-identity.sh and the git wrapper it installs: with no
# identity in the container the agent refused to commit and the runner committed as a placeholder author). Fully OFFLINE,
# in a throwaway HOME, the wrapper in a throwaway PATH dir. Each check FAILS if the property it proves is removed:
#   1. with GIT_USER_NAME and GIT_USER_EMAIL set the script writes them as user.name/user.email in HOME's .gitconfig, sets
#      user.useConfigOnly (no drift to a guessed identity), installs the wrapper, says so in one line; a commit carries them
#   2. unset: the script says there is none and removes an earlier identity; a commit is refused by the wrapper with one
#      line naming GIT_USER_NAME and GIT_USER_EMAIL (exit 128, before git's own "Author identity unknown"), nothing committed,
#      no placeholder author (the log never shows "Vibe Kanban <noreply@vibekanban.com>" or any other invented name);
#      an identity given in the environment (GIT_AUTHOR_*/GIT_COMMITTER_*) or in the repository's own config passes
#   3. a repository's own pre-commit and commit-msg hooks run as before (the wrapper is not a hook)
#   4. the script is idempotent (a second run leaves .gitconfig and the wrapper byte-identical); a non-commit command
#      and global options before the subcommand (-C <dir>) pass through the wrapper untouched
#   5. in the image: git's per-user excludes file names .omc/ (setup/install-plugins.sh) and no core.excludesFile
#      overrides it; from a bare checkout this check is skipped
set -u
D=/tmp/git-identity-smoke
rm -rf "${D:?}"
mkdir -p ${D}/home ${D}/repo ${D}/bin
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
fail() { echo "Test-git-identity FAILED: $*"; exit 1; }
export HOME=${D}/home GIT_WRAPPER_DIR=${D}/bin PATH=${D}/bin:${PATH}
REAL=$(command -v /usr/bin/git || command -v git)
unset GIT_USER_NAME GIT_USER_EMAIL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
git -C ${D}/repo init -q
bash -n "${AGENT_DIR}/git-identity.sh" || fail "git-identity.sh does not parse"

# --- 1. the identity from the environment ---
OUT=$(GIT_USER_NAME="Test Operator" GIT_USER_EMAIL=operator@example.org "${AGENT_DIR}/git-identity.sh") || fail "git-identity.sh exited $?: ${OUT}"
hash -r   # the shell looked git up before the wrapper existed
[ "${OUT}" == "git identity: Test Operator <operator@example.org> (GIT_USER_NAME, GIT_USER_EMAIL)" ] || fail "the one line is not the identity: ${OUT}"
[ "$(git config --global user.name)" == "Test Operator" ] && [ "$(git config --global user.email)" == "operator@example.org" ] || fail "user.name/user.email not written: $(git config --global --list)"
[ "$(git config --global user.useConfigOnly)" == "true" ] || fail "user.useConfigOnly is not on"
[ -x ${D}/bin/git ] || fail "the wrapper was not installed in GIT_WRAPPER_DIR"
[ "$(command -v git)" == "${D}/bin/git" ] || fail "test setup: the wrapper is not first on PATH ($(command -v git))"
echo one > ${D}/repo/file.txt && git -C ${D}/repo add file.txt && git -C ${D}/repo commit -q -m "first" || fail "a commit with the identity set failed"
[ "$(git -C ${D}/repo log -1 --format='%an <%ae>')" == "Test Operator <operator@example.org>" ] || fail "the commit does not carry the identity: $(git -C ${D}/repo log -1 --format='%an <%ae>')"
echo "ok 1 - GIT_USER_NAME/GIT_USER_EMAIL become user.name/user.email (useConfigOnly on), the wrapper is installed, said in one line; a commit carries them"

# --- 2. no identity: refused with the reason, nothing committed, no placeholder ---
OUT=$("${AGENT_DIR}/git-identity.sh") || fail "git-identity.sh without an identity exited $?: ${OUT}"
echo "${OUT}" | grep -q "^git identity: none - set GIT_USER_NAME and GIT_USER_EMAIL in \.env\.local;" || fail "the no-identity line does not name the variables: ${OUT}"
git config --global user.name > /dev/null 2>&1 && fail "an earlier identity survived the unset run: $(git config --global user.name)"
[ "$(git config --global user.useConfigOnly 2>/dev/null)" == "true" ] || fail "user.useConfigOnly is off without an identity (git would guess one from the host name)"
echo two > ${D}/repo/file.txt && git -C ${D}/repo add file.txt
git -C ${D}/repo commit -q -m "second" > ${D}/commit.out 2> ${D}/commit.err; RC=$?
[ "${RC}" == "128" ] || fail "a commit without an identity did not stop with 128 (rc=${RC}): $(cat ${D}/commit.err | head -2)"
grep -q 'Author identity unknown' ${D}/commit.err && fail "git's own refusal came out instead of the harness line: $(cat ${D}/commit.err | head -3)"
grep -q "^ERROR: no git identity in this container - set GIT_USER_NAME and GIT_USER_EMAIL in \.env\.local (they become" ${D}/commit.err || fail "the refusal does not name the two variables: $(cat ${D}/commit.err)"
[ "$(grep -c '^ERROR' ${D}/commit.err)" == "1" ] || fail "more than one ERROR line: $(cat ${D}/commit.err)"
[ "$(git -C ${D}/repo rev-list --count HEAD)" == "1" ] || fail "something was committed without an identity"
git -C ${D}/repo log --format='%an <%ae>' | grep -qiE 'vibe kanban|noreply@vibekanban|root|unknown' && fail "a placeholder author appears in the log: $(git -C ${D}/repo log --format='%an <%ae>')"
# an identity given another way passes the wrapper: the environment, or the repository's own configuration
GIT_AUTHOR_NAME=Env GIT_AUTHOR_EMAIL=env@example.org GIT_COMMITTER_NAME=Env GIT_COMMITTER_EMAIL=env@example.org git -C ${D}/repo commit -q -m "from env" || fail "an identity from the environment was refused"
[ "$(git -C ${D}/repo log -1 --format='%an <%ae>')" == "Env <env@example.org>" ] || fail "the environment identity did not land"
git -C ${D}/repo config user.name Local && git -C ${D}/repo config user.email local@example.org && echo three > ${D}/repo/file.txt && git -C ${D}/repo add file.txt && git -C ${D}/repo commit -q -m "from local config" || fail "a repository-local identity was refused"
[ "$(git -C ${D}/repo log -1 --format='%an <%ae>')" == "Local <local@example.org>" ] || fail "the repository's own identity did not land"
git -C ${D}/repo config --unset user.name; git -C ${D}/repo config --unset user.email
echo "ok 2 - without GIT_USER_NAME/GIT_USER_EMAIL the script says so and a commit is refused by the wrapper with one ERROR line naming them (exit 128, before git's own words); nothing committed, no placeholder author; an identity from the environment or the repository's own config passes"

# --- 3. the repository's own hooks keep running ---
GIT_USER_NAME="Test Operator" GIT_USER_EMAIL=operator@example.org "${AGENT_DIR}/git-identity.sh" > /dev/null
printf '#!/bin/bash\necho local-pre-commit-ran > %s/marker-pre\n' "${D}" > ${D}/repo/.git/hooks/pre-commit
printf '#!/bin/bash\necho local-commit-msg-ran > %s/marker-msg\n' "${D}" > ${D}/repo/.git/hooks/commit-msg
chmod +x ${D}/repo/.git/hooks/pre-commit ${D}/repo/.git/hooks/commit-msg
echo hooks > ${D}/repo/file.txt && git -C ${D}/repo add file.txt
git -C ${D}/repo commit -q -m "with hooks" || fail "a commit with the identity set and local hooks failed"
[ -f ${D}/marker-pre ] && [ -f ${D}/marker-msg ] || fail "the repository's own pre-commit/commit-msg hooks did not run behind the global ones (pre=$(ls ${D}/marker-pre 2>&1), msg=$(ls ${D}/marker-msg 2>&1))"
[ "$(git -C ${D}/repo rev-list --count HEAD)" == "4" ] || fail "the hooks commit did not land ($(git -C ${D}/repo rev-list --count HEAD) commits)"
printf '#!/bin/bash\nexit 1\n' > ${D}/repo/.git/hooks/pre-commit
echo four > ${D}/repo/file.txt && git -C ${D}/repo add file.txt
git -C ${D}/repo commit -q -m "fourth" 2>/dev/null && fail "a repository's own refusing pre-commit hook was bypassed"
echo "ok 3 - the repository's own pre-commit and commit-msg hooks run as before, and a refusing local hook still refuses"

# --- 4. idempotent; every hook name present ---
GIT_USER_NAME="Test Operator" GIT_USER_EMAIL=operator@example.org "${AGENT_DIR}/git-identity.sh" > /dev/null
A=$(md5sum < ${HOME}/.gitconfig)$(md5sum < ${D}/bin/git); GIT_USER_NAME="Test Operator" GIT_USER_EMAIL=operator@example.org "${AGENT_DIR}/git-identity.sh" > /dev/null; B=$(md5sum < ${HOME}/.gitconfig)$(md5sum < ${D}/bin/git)
[ "${A}" == "${B}" ] || fail "a second run changed .gitconfig or the wrapper"
bash -n ${D}/bin/git || fail "the wrapper does not parse"
[ "$(git -C ${D}/repo rev-list --count HEAD)" == "$(${REAL} -C ${D}/repo rev-list --count HEAD)" ] || fail "a non-commit command through the wrapper differs from the system git"
[ "$(cd ${D} && git -C repo status --porcelain | wc -l)" == "$(cd ${D} && ${REAL} -C repo status --porcelain | wc -l)" ] || fail "-C <dir> before the subcommand did not pass through"
git --version | grep -q '^git version' || fail "git --version through the wrapper"
echo "ok 4 - the identity script is idempotent (config and wrapper byte-identical); non-commit commands and -C <dir> pass through the wrapper untouched"

# --- 5. the image's excludes file ---
if [ -f /home/agent/.config/git/ignore ]; then
	grep -qx '.omc/' /home/agent/.config/git/ignore || fail "the image's per-user git excludes file does not name .omc/"
	[ -z "$(HOME=/home/agent git config --global core.excludesFile 2>/dev/null)" ] || fail "core.excludesFile is set in the image and would override the per-user excludes file"
	echo "ok 5 - the image's per-user git excludes file names .omc/ and nothing overrides it"
else
	echo "ok 5 - (skipped: not in the image - no /home/agent/.config/git/ignore)"
fi

echo "Test-git-identity succeeded"
