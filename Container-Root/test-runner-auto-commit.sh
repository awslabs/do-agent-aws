#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the agent runner's automatic commit, as the git wrapper /agent/git-identity.sh installs sees it. vibe-kanban
# 0.1.44, the agent runner, commits what a coding agent left uncommitted when the agent's turn ends, with the agent's last
# reply as the message, and before that it writes its placeholder author (Vibe Kanban <noreply@vibekanban.com>) into the
# repository's configuration when no identity is set: a turn whose agent had refused to commit for want of an identity
# became a commit by the placeholder, with the refusal as its message. The runner process runs git itself, so the
# wrapper's parent is a process named vibe-kanban. Fully OFFLINE: checks 1-5 in a throwaway HOME, the wrapper in a throwaway
# PATH dir, and a copy of bash named vibe-kanban standing in for the runner; check 6 under the image's own HOME, where the
# runner's warmed binary is. Each check FAILS if the property it proves is removed:
#   1. the runner's automatic commit is refused by default (VK_RUNNER_AUTO_COMMIT unset, or false): one ERROR line naming
#      VK_RUNNER_AUTO_COMMIT, exit 1, nothing committed, the change still in the work tree
#   2. VK_RUNNER_AUTO_COMMIT=true: the same commit goes through, as the runner does upstream
#   3. the runner's squash merge (its Merge action: git merge --squash, then a commit with git's SQUASH_MSG present) goes
#      through; a commit that is not the runner's (the agent's own, through a shell) goes through
#   4. the runner's placeholder author in a repository's configuration is refused for every caller (exit 128, one ERROR
#      line naming it and how to remove it), nothing committed; another identity in a repository's configuration passes
#   5. PLANTED CONTROL: the wrapper without the runner rule commits the runner's automatic commit, and without the
#      placeholder rule commits as the placeholder - so checks 1 and 4 prove these rules, not some other refusal
#   6. in the image: the runner /agent/ui-start.sh starts runs as a process named vibe-kanban, the name the rule matches,
#      from the binary the build warmed under the image's HOME - its launcher downloads nothing (under this test's
#      throwaway HOME it found no binary and fetched 52 MB from npm-cdn.vibekanban.com on every run; in a sandbox whose
#      egress allows no such host the runner never started, and this check failed there alone)
#      (started on a test-local port and data home and stopped again at once); from a bare checkout this check is skipped
set -u
D=/tmp/runner-auto-commit-smoke
rm -rf "${D:?}"
mkdir -p ${D}/home ${D}/bin ${D}/fake ${D}/planted
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
RUNNER_PID=""
fail()
{
	echo "Test-runner-auto-commit FAILED: $*"
	[ -n "${RUNNER_PID}" ] && kill -TERM -- "-${RUNNER_PID}" 2> /dev/null
	exit 1
}
# the image's HOME, for check 6 (the runner's launcher keeps the warmed binary under $HOME/.vibe-kanban/bin)
IMAGE_HOME=${HOME:-/home/agent}
export HOME=${D}/home GIT_WRAPPER_DIR=${D}/bin PATH=${D}/bin:${PATH}
unset GIT_USER_NAME GIT_USER_EMAIL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL VK_RUNNER_AUTO_COMMIT
GIT_USER_NAME="Test Operator" GIT_USER_EMAIL=operator@example.org "${AGENT_DIR}/git-identity.sh" > ${D}/identity.out 2>&1 \
	|| fail "git-identity.sh exited $?: $(cat ${D}/identity.out)"
hash -r
[ "$(command -v git)" == "${D}/bin/git" ] || fail "test setup: the wrapper is not first on PATH ($(command -v git))"
# the runner's stand-in: a process named vibe-kanban that runs git as its child (the second command keeps bash from
# exec-ing git in its own place, as the runner never does)
cp "$(command -v bash)" ${D}/fake/vibe-kanban
runner() { ${D}/fake/vibe-kanban -c "$1; exit \$?"; }
R=${D}/repo
if ! { git init -q ${R} && echo one > ${R}/file.txt && git -C ${R} add file.txt && git -C ${R} commit -q -m "first"; }; then
	fail "test setup: a first commit with the identity set failed"
fi
N0=$(git -C ${R} rev-list --count HEAD)

# --- 1. the runner's automatic commit: off by default ---
for V in "" false; do
	echo "two ${V}" > ${R}/file.txt && git -C ${R} add file.txt
	VK_RUNNER_AUTO_COMMIT=${V} runner "git -C ${R} commit -m 'Done. I changed the file as asked.'" > ${D}/auto.out 2> ${D}/auto.err; RC=$?
	[ "${RC}" == "1" ] || fail "1: the runner's automatic commit with VK_RUNNER_AUTO_COMMIT='${V}' exited ${RC}, not 1: $(cat ${D}/auto.err)"
	grep -q "^ERROR: the agent runner's automatic commit is off (VK_RUNNER_AUTO_COMMIT, docs/manual/install.md \"Git identity\")" ${D}/auto.err \
		|| fail "1: the refusal does not name VK_RUNNER_AUTO_COMMIT: $(cat ${D}/auto.err)"
	[ "$(grep -c '^ERROR' ${D}/auto.err)" == "1" ] || fail "1: more than one ERROR line: $(cat ${D}/auto.err)"
	[ "$(git -C ${R} rev-list --count HEAD)" == "${N0}" ] || fail "1: the runner's automatic commit was committed (VK_RUNNER_AUTO_COMMIT='${V}')"
	git -C ${R} diff --cached --quiet && fail "1: the change left the index (VK_RUNNER_AUTO_COMMIT='${V}')"
done
echo "ok 1 - the runner's automatic commit is refused by default (VK_RUNNER_AUTO_COMMIT unset or false): one ERROR line naming it, exit 1, nothing committed, the change still staged"

# --- 2. on request: the upstream behaviour ---
VK_RUNNER_AUTO_COMMIT=true runner "git -C ${R} commit -q -m 'Done. I changed the file as asked.'" > ${D}/on.out 2>&1 \
	|| fail "2: with VK_RUNNER_AUTO_COMMIT=true the runner's commit failed: $(cat ${D}/on.out)"
[ "$(git -C ${R} rev-list --count HEAD)" == "$((N0 + 1))" ] || fail "2: with VK_RUNNER_AUTO_COMMIT=true nothing was committed"
[ "$(git -C ${R} log -1 --format=%s)" == "Done. I changed the file as asked." ] || fail "2: the commit is not the runner's: $(git -C ${R} log -1 --format=%s)"
echo "ok 2 - VK_RUNNER_AUTO_COMMIT=true: the runner's automatic commit goes through"

# --- 3. the runner's squash merge, and a commit that is not the runner's ---
B=$(git -C ${R} rev-parse --abbrev-ref HEAD)
if ! { git -C ${R} checkout -q -b task && echo three > ${R}/file.txt && git -C ${R} commit -q -a -m "task work" && git -C ${R} checkout -q "${B}"; }; then
	fail "3: test setup: the task branch"
fi
git -C ${R} merge --squash --no-commit task > /dev/null 2>&1 || fail "3: test setup: git merge --squash"
N1=$(git -C ${R} rev-list --count HEAD)
runner "git -C ${R} commit -q -m 'task (vibe-kanban 1a2b3c4d)'" > ${D}/merge.out 2>&1 || fail "3: the runner's squash-merge commit was refused: $(cat ${D}/merge.out)"
[ "$(git -C ${R} rev-list --count HEAD)" == "$((N1 + 1))" ] || fail "3: the runner's squash merge was not committed"
echo four > ${R}/file.txt && git -C ${R} add file.txt
bash -c "git -C ${R} commit -q -m 'the agent commits its own work'; exit \$?" || fail "3: a commit through a shell (the agent's own) was refused"
[ "$(git -C ${R} log -1 --format=%s)" == "the agent commits its own work" ] || fail "3: the agent's own commit did not land"
echo "ok 3 - the runner's squash merge (SQUASH_MSG present) and a commit that is not the runner's go through"

# --- 4. the runner's placeholder author is refused for every caller ---
"${AGENT_DIR}/git-identity.sh" > /dev/null 2>&1
git -C ${R} config user.name "Vibe Kanban" && git -C ${R} config user.email noreply@vibekanban.com
N2=$(git -C ${R} rev-list --count HEAD)
for WHO in shell runner; do
	echo "five ${WHO}" > ${R}/file.txt && git -C ${R} add file.txt
	if [ "${WHO}" == "runner" ]; then
		VK_RUNNER_AUTO_COMMIT=true runner "git -C ${R} commit -m 'the agent reply'" > /dev/null 2> ${D}/ph.err; RC=$?
	else
		bash -c "git -C ${R} commit -m 'the agent reply'; exit \$?" > /dev/null 2> ${D}/ph.err; RC=$?
	fi
	[ "${RC}" == "128" ] || fail "4: a commit (${WHO}) with the runner's placeholder author exited ${RC}, not 128: $(cat ${D}/ph.err)"
	grep -q "^ERROR: the identity here is the agent runner's placeholder (Vibe Kanban <noreply@vibekanban.com>" ${D}/ph.err \
		|| fail "4: the refusal does not name the placeholder: $(cat ${D}/ph.err)"
	grep -q "git config --unset user.name" ${D}/ph.err || fail "4: the refusal does not say how to remove it: $(cat ${D}/ph.err)"
	[ "$(git -C ${R} rev-list --count HEAD)" == "${N2}" ] || fail "4: a commit (${WHO}) as the runner's placeholder was committed"
done
git -C ${R} log --format='%an <%ae>' | grep -qF 'noreply@vibekanban.com' && fail "4: the placeholder author is in the log"
git -C ${R} config user.name Local && git -C ${R} config user.email local@example.org
git -C ${R} commit -q -m "a repository's own identity" || fail "4: another identity in the repository's configuration was refused"
[ "$(git -C ${R} log -1 --format='%an <%ae>')" == "Local <local@example.org>" ] || fail "4: the repository's own identity did not land"
echo "ok 4 - the runner's placeholder author in a repository's configuration is refused for the agent and the runner alike (exit 128, one ERROR line naming it and its removal), nothing committed; another repository-local identity passes"

# --- 5. PLANTED CONTROL: the wrapper without the rules ---
python3 - ${D}/bin/git ${D}/planted/git << 'PYEOF' || fail "5: PLANTED CONTROL BROKEN: the rules are not in the wrapper as expected"
import sys
c = open(sys.argv[1]).read()
a = c.index("\t# the agent runner's automatic commit")
b = c.index("\tesac\n", a) + len("\tesac\n")
assert "VK_RUNNER_AUTO_COMMIT" in c[a:b] and "noreply@vibekanban.com" in c[a:b]
open(sys.argv[2], "w").write(c[:a] + c[b:])
PYEOF
chmod +x ${D}/planted/git
echo six > ${R}/file.txt && git -C ${R} add file.txt
N3=$(git -C ${R} rev-list --count HEAD)
PATH=${D}/planted:${PATH} runner "git -C ${R} commit -q -m 'Done. I changed the file as asked.'" > /dev/null 2>&1 \
	|| fail "5: PLANTED CONTROL BROKEN: the wrapper without the runner rule still refused the runner's automatic commit"
[ "$(git -C ${R} rev-list --count HEAD)" == "$((N3 + 1))" ] || fail "5: PLANTED CONTROL BROKEN: without the rule nothing was committed"
git -C ${R} config user.name "Vibe Kanban" && git -C ${R} config user.email noreply@vibekanban.com
echo seven > ${R}/file.txt && git -C ${R} add file.txt
PATH=${D}/planted:${PATH} bash -c "git -C ${R} commit -q -m 'as the placeholder'; exit \$?" > /dev/null 2>&1 \
	|| fail "5: PLANTED CONTROL BROKEN: the wrapper without the placeholder rule still refused the placeholder"
[ "$(git -C ${R} log -1 --format='%ae')" == "noreply@vibekanban.com" ] || fail "5: PLANTED CONTROL BROKEN: without the rule the placeholder did not commit"
echo "ok 5 - PLANTED CONTROL: without the runner rule the runner's automatic commit is committed, and without the placeholder rule the placeholder commits"

# --- 6. in the image: the runner's process name ---
# under the image's HOME: /usr/local/bin/vibe-kanban is the npm package's launcher, which runs the platform binary from
# $HOME/.vibe-kanban/bin (warmed there at the build, setup/install-vibe-kanban.sh) and downloads it where it finds none
if [ -x /agent/ui-start.sh ] && [ -x /usr/local/bin/vibe-kanban ]; then
	mkdir -p ${D}/ui
	HOME=${IMAGE_HOME} UI_DIR=${D}/ui UI_LISTEN_HOST=127.0.0.1 UI_HOME=false UI_HEADLAMP=false UI_HINDSIGHT=false UI_TMUX=false \
		UI_TMUX_AGENT=false UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_LOOP=false UI_FILES=false UI_PLANE=false UI_VIBE_KANBAN=true UI_PORT_VIBE_KANBAN=18199 \
		XDG_DATA_HOME=${D}/data /agent/ui-start.sh > ${D}/ui-start.log 2>&1 || fail "6: ui-start.sh: $(cat ${D}/ui-start.log)"
	RUNNER_PID=$(cat ${D}/ui/vibe-kanban.pid 2> /dev/null)
	[ -n "${RUNNER_PID}" ] || fail "6: ui-start.sh started no runner: $(cat ${D}/ui-start.log)"
	NAMED=""
	for _ in $(seq 1 60); do
		for P in $(pgrep -g "${RUNNER_PID}" 2> /dev/null); do
			[ "$(cat "/proc/${P}/comm" 2> /dev/null)" == "vibe-kanban" ] && NAMED=${P}
		done
		[ -n "${NAMED}" ] && break
		sleep 1
	done
	kill -TERM -- "-${RUNNER_PID}" 2> /dev/null
	RUNNER_PID=""
	[ -n "${NAMED}" ] || fail "6: no process of the runner ui-start.sh started is named vibe-kanban (the wrapper's rule would never match): $(pgrep -a -g "$(cat "${D}/ui/vibe-kanban.pid")" 2>&1 | head -5); its log: $(grep -v '^$' ${D}/ui/vibe-kanban.log 2> /dev/null | tail -3 | tr '\n' ' ')"
	grep -q '^Downloading ' ${D}/ui/vibe-kanban.log && fail "6: the runner's launcher downloaded its binary instead of running the one the build warmed under ${IMAGE_HOME}/.vibe-kanban/bin: $(grep -m1 '^Downloading ' ${D}/ui/vibe-kanban.log)"
	echo "ok 6 - the runner ui-start.sh starts runs as a process named vibe-kanban (pid ${NAMED}), the name the rule matches, from the binary warmed under ${IMAGE_HOME}/.vibe-kanban/bin (no download)"
else
	echo "ok 6 - (skipped: not in the image - no /agent/ui-start.sh or /usr/local/bin/vibe-kanban)"
fi

echo "Test-runner-auto-commit succeeded"
