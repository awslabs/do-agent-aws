#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the starter repository (/agent/starter-repo.sh: a fresh install has no repository, so the
# agent runner's Browse opened on "No folders found" and Create hung). Fully OFFLINE, in a throwaway workspace. Each
# check FAILS if the property it proves is removed:
#   1. a workspace with no repository gets ${ROOT}/projects/scratch: a README, one clean commit by the operator's identity
#      (GIT_USER_NAME/GIT_USER_EMAIL), and the script says so in one line
#   2. a second start changes nothing (CONTROL for idempotence: the same commit, the same files) and says the repository
#      exists; a third start after the user committed on top keeps that commit (never touched)
#   3. a workspace that holds a repository - itself, one level under it, or under projects/ - gets no scratch repository
#   4. STARTER_REPO=false creates nothing; without an operator identity the one commit is the harness's own
#   5. startup.sh calls the script before the UIs start and before the knowledge seed (static, with two planted controls)
set -u
D=/tmp/starter-repo-smoke
rm -rf "${D:?}"
mkdir -p ${D}/fresh ${D}/home
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
S="${AGENT_DIR}/starter-repo.sh"
fail() { echo "Test-starter-repo FAILED: $*"; exit 1; }
export HOME=${D}/home   # no global identity leaks in
unset GIT_USER_NAME GIT_USER_EMAIL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL STARTER_REPO
bash -n "${S}" || fail "starter-repo.sh does not parse"

# --- 1. a fresh workspace ---
OUT=$(GIT_USER_NAME="Test Operator" GIT_USER_EMAIL=operator@example.org STARTER_REPO_ROOT=${D}/fresh "${S}") || fail "first start exited $?: ${OUT}"
R=${D}/fresh/projects/scratch
[ -d ${R}/.git ] || fail "no scratch repository after the first start: ${OUT}"
[ -s ${R}/README.md ] && grep -q '/wd/projects/' ${R}/README.md || fail "the README does not say where real repositories go"
[ "$(git -C ${R} rev-list --count HEAD)" == "1" ] || fail "the scratch repository does not have exactly one commit"
[ "$(git -C ${R} log -1 --format='%an <%ae>')" == "Test Operator <operator@example.org>" ] || fail "the commit does not carry the operator's identity: $(git -C ${R} log -1 --format='%an <%ae>')"
[ -z "$(git -C ${R} status --porcelain)" ] || fail "the scratch repository is not clean"
echo "${OUT}" | grep -q "^starter repo: created ${R} (the workspace ${D}/fresh held no repository) - one commit by Test Operator <operator@example.org>" || fail "the line does not say what was created: ${OUT}"
echo "ok 1 - a fresh workspace gets projects/scratch: a README, one clean commit by the operator's identity, said in one line"

# --- 2. idempotent: second and third starts ---
SHA=$(git -C ${R} rev-parse HEAD); LIST=$(cd ${R} && find . -type f -not -path './.git/*' -exec md5sum {} + | sort)
OUT=$(GIT_USER_NAME="Test Operator" GIT_USER_EMAIL=operator@example.org STARTER_REPO_ROOT=${D}/fresh "${S}") || fail "second start exited $?: ${OUT}"
echo "${OUT}" | grep -q "^starter repo: ${R} exists (1 commit(s)); nothing to do" || fail "the second start does not say the repository exists: ${OUT}"
[ "$(git -C ${R} rev-parse HEAD)" == "${SHA}" ] || fail "CONTROL: the second start changed the commit"
[ "$(cd ${R} && find . -type f -not -path './.git/*' -exec md5sum {} + | sort)" == "${LIST}" ] || fail "CONTROL: the second start changed the files"
echo "user work" > ${R}/work.txt && git -C ${R} add work.txt && git -C ${R} -c user.name=U -c user.email=u@example.org commit -q -m "user's commit"
USER_SHA=$(git -C ${R} rev-parse HEAD)
OUT=$(STARTER_REPO_ROOT=${D}/fresh "${S}") || fail "third start exited $?"
[ "$(git -C ${R} rev-parse HEAD)" == "${USER_SHA}" ] && [ -f ${R}/work.txt ] || fail "a start after the user's commit touched the repository"
echo "ok 2 - a second start changes nothing (same commit, same files) and says the repository exists; the user's later commit is left alone"

# --- 3. a workspace that already holds a repository ---
for CASE in top under projects; do
	W=${D}/has-${CASE}; mkdir -p ${W}
	case ${CASE} in top) git -C ${W} init -q ;; under) mkdir -p ${W}/mine && git -C ${W}/mine init -q ;; projects) mkdir -p ${W}/projects/theirs && git -C ${W}/projects/theirs init -q ;; esac
	OUT=$(STARTER_REPO_ROOT=${W} "${S}") || fail "start with a repository (${CASE}) exited $?: ${OUT}"
	[ -e ${W}/projects/scratch ] && fail "a scratch repository was created although the workspace holds one (${CASE})"
	echo "${OUT}" | grep -q "already holds a repository" || fail "the line does not say the workspace holds a repository (${CASE}): ${OUT}"
done
echo "ok 3 - a workspace with a repository at its root, one level under it, or under projects/ gets no scratch repository"

# --- 4. opt-out, and the harness's own identity ---
mkdir -p ${D}/off
OUT=$(STARTER_REPO=false STARTER_REPO_ROOT=${D}/off "${S}") || fail "STARTER_REPO=false exited $?"
[ -e ${D}/off/projects ] && fail "STARTER_REPO=false still created the repository"
echo "${OUT}" | grep -q "^starter repo: off" || fail "the opt-out does not say so: ${OUT}"
mkdir -p ${D}/noid
OUT=$(STARTER_REPO_ROOT=${D}/noid "${S}") || fail "start without an identity exited $?: ${OUT}"
[ "$(git -C ${D}/noid/projects/scratch log -1 --format='%an <%ae>')" == "do-agent-aws harness <harness@do-agent-aws.local>" ] || fail "without an operator identity the commit is not the harness's own: $(git -C ${D}/noid/projects/scratch log -1 --format='%an <%ae>')"
echo "ok 4 - STARTER_REPO=false creates nothing; without an operator identity the commit is the harness's own"

# --- 5. startup.sh calls it, before the UIs start and before the knowledge seed ---
ST="${BASE_DIR%/}/startup.sh"
# line_of <pattern> <file>: the number of the first line matching the anchored pattern; empty when there is none
line_of() { grep -n -E "$1" "$2" | head -1 | cut -d: -f1; }
STARTER='^/agent/starter-repo.sh$'                              # the call, at column 1
UISTART='^[[:space:]]*/agent/ui-start.sh$'                      # the call inside the UI_START block (not the comments naming it)
SEED='^[[:space:]]*setsid nohup /agent/hindsight-seed.sh '      # the detached call (not the comment or the echo naming it)
[ -n "$(line_of "${STARTER}" "${ST}")" ] || fail "startup.sh does not call /agent/starter-repo.sh"
[ -n "$(line_of "${UISTART}" "${ST}")" ] || fail "startup.sh has no /agent/ui-start.sh call line; the order check cannot place the UIs"
[ -n "$(line_of "${SEED}" "${ST}")" ] || fail "startup.sh has no detached hindsight-seed.sh call line; the order check cannot place the seed"
# order_ok <startup.sh>: the starter repository is made before the UIs start (ui-start.sh launches the runner's registration
# scan, which runs as soon as the runner answers and registers only what exists then) and before the knowledge seed
order_ok()
{
	local s u h
	s=$(line_of "${STARTER}" "$1"); u=$(line_of "${UISTART}" "$1"); h=$(line_of "${SEED}" "$1")
	[ -n "${s}" ] && [ -n "${u}" ] && [ -n "${h}" ] && [ "${s}" -lt "${u}" ] && [ "${s}" -lt "${h}" ]
}
order_ok "${ST}" || fail "startup.sh makes the starter repository after the UIs start (the runner's registration scan would find nothing on a first start) or after the knowledge seed"
# PLANTED CONTROL A, the UI clause: the parent's order - the starter call moved to just after the UI block's closing fi, still
# before the seed - must fail the order check, and only the before-the-UIs comparison can fail it
awk -v call='/agent/starter-repo.sh' '$0==call{h=1; next} {print} h && $0=="fi" && !d {print call; d=1}' "${ST}" > ${D}/startup-after-ui.sh
s=$(line_of "${STARTER}" ${D}/startup-after-ui.sh); u=$(line_of "${UISTART}" ${D}/startup-after-ui.sh); h=$(line_of "${SEED}" ${D}/startup-after-ui.sh)
if ! { [ -n "${s}" ] && [ -n "${u}" ] && [ -n "${h}" ] && [ "${u}" -lt "${s}" ] && [ "${s}" -lt "${h}" ]; }; then fail "CONTROL A was not built: starter ${s:-none}, ui-start ${u:-none}, seed ${h:-none}"; fi
order_ok ${D}/startup-after-ui.sh && fail "the order check passed a startup.sh that makes the starter repository right after the UIs start"
# PLANTED CONTROL B, both clauses: the starter call last (after the UIs and after the seed) must fail the order check
grep -v -E "${STARTER}" "${ST}" > ${D}/startup-late.sh && echo '/agent/starter-repo.sh' >> ${D}/startup-late.sh
[ "$(tail -1 ${D}/startup-late.sh)" == "/agent/starter-repo.sh" ] || fail "CONTROL B was not built: the starter call is not the last line"
order_ok ${D}/startup-late.sh && fail "the order check passed a startup.sh that makes the starter repository last"
# PLANTED CONTROL C, the seed clause alone: a three-line script in the order seed call, starter call, UI call; the starter
# precedes the UIs, so only the before-the-seed comparison can fail it
printf '\tsetsid nohup /agent/hindsight-seed.sh >> /dev/null 2>&1 &\n/agent/starter-repo.sh\n\t/agent/ui-start.sh\n' > ${D}/startup-seed-first.sh
s=$(line_of "${STARTER}" ${D}/startup-seed-first.sh); u=$(line_of "${UISTART}" ${D}/startup-seed-first.sh); h=$(line_of "${SEED}" ${D}/startup-seed-first.sh)
if ! { [ "${h}" == "1" ] && [ "${s}" == "2" ] && [ "${u}" == "3" ]; }; then fail "CONTROL C was not built: seed ${h:-none}, starter ${s:-none}, ui-start ${u:-none}"; fi
order_ok ${D}/startup-seed-first.sh && fail "the order check passed a script that makes the starter repository after the knowledge seed"
echo "ok 5 - startup.sh makes the starter repository before the UIs start (the runner's registration scan) and before the knowledge seed; copies making it right after the UIs, last, or after the seed alone each fail the check"

echo "Test-starter-repo succeeded"
