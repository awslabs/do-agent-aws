#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of the settings layout (docs/manual/install.md "Settings", run by test.sh like test-preflight.sh): .env is the
# tracked defaults file, .env.local the gitignored file of a person's own settings, ./env-local.sh the first run's
# step. Everything happens in throwaway git repositories under ./scratch/test-env-local (gitignored) made from this
# checkout's .env, .fun, env-local.sh, .gitignore and the compose and kubernetes templates; nothing of the checkout
# itself is read for a setting or written.
# Each check FAILS if the property is removed:
#   1. CONTROL - the layout's defect: a clone whose tracked .env was edited cannot git pull --ff-only an upstream
#      change of .env ("would be overwritten"), so a ./build.sh after it builds the old checkout
#   2. the same setting in .env.local instead: git pull --ff-only goes through, git status stays clean (.env.local is
#      ignored), the person's settings apply and the new upstream default arrives too
#   3. the values derived from a setting of .env.local follow it: UI_PLANE=true turns the Plane options on (the board is
#      off by default, docs/manual/boards.md "Plane board": without .env.local they are empty);
#      AUTONOMY_LOOP_INTERVAL reaches the container options, the test container's TEST_RUN_OPTS (which keeps its
#      TEST_CONTAINER=true) and the compose and kubernetes files rendered from the templates (envsubst, as run.sh
#      renders them); a plain NAME=value line is exported too, one of a name .env does not set included; export is
#      the builtin again afterwards
#   4. ./env-local.sh on a first run creates .env.local (only comments) and says so; a second run changes nothing;
#      ENV_LOCAL_SETUP=false skips it
#   5. the one-time move: an edited tracked .env (two settings changed, one added) and no .env.local - its three
#      lines land in a new .env.local, the edited file is kept as .env.edited-<time>, .env is restored (git diff
#      clean) and the settings still apply; then git pull --ff-only goes through
#   6. no move when .env.local exists (.env and .env.local unchanged, the lines it would move printed), nor when the
#      edit to .env is more than settings (no .env.local made, .env unchanged)
#   7. a .env.local that is a whole copy of .env (with its own last lines) loads without recursion
#   8. a shell with set -u sources .env, with and without .env.local
#   9. the model settings (.env "Model settings"): with the shipped defaults, run.sh's eval of the container options and
#      test.sh's array read of the test container's carry ANTHROPIC_MODEL, CLAUDE_CODE_EFFORT_LEVEL,
#      ANTHROPIC_DEFAULT_OPUS_MODEL and ANTHROPIC_DEFAULT_FABLE_MODEL with the [1m] suffix byte for byte (shq's quoting of
#      the brackets shows in the raw option string), and the rendered compose and kubernetes files carry the model id; an
#      override in .env.local follows; all four empty in .env.local leave the options without any of the four names

D=scratch/test-env-local
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "${BASE_DIR:?}/${D:?}"
mkdir -p "${BASE_DIR}/${D}"
D=${BASE_DIR}/${D}

fail()
{
	echo "Test-env-local FAILED: $1"
	exit 1
}

command -v git > /dev/null || { echo "Test-env-local skipped: git not installed"; exit 0; }
G()
{
	# G <repo> <git args...> - git with a fixed identity, no hooks, no global settings
	local R=$1
	shift
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "${R}" -c user.name=test -c user.email=test@example.invalid \
		-c core.hooksPath=/dev/null -c advice.detachedHead=false "$@"
}
# setting <repo> <name> - the value .env gives NAME in that repository (and the export builtin check)
setting()
{
	( cd "$1" && bash -c 'source .env > /dev/null 2>&1; printf "%s" "${!1}"' _ "$2" )
}

# --- the upstream and its clones ---
U=${D}/upstream
mkdir -p "${U}/to/compose" "${U}/to/kubernetes"
cp "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${BASE_DIR}/env-local.sh" "${BASE_DIR}/.gitignore" "${U}/"
cp -r "${BASE_DIR}/to/compose/template" "${U}/to/compose/"
cp -r "${BASE_DIR}/to/kubernetes/template" "${U}/to/kubernetes/"
G "${U}" init -q -b main && G "${U}" add -A && G "${U}" commit -q -m defaults || fail "could not make the upstream repository"
for C in control layout first move refuse-local refuse-code model; do
	G "${D}" clone -q "${U}" "${C}" 2> /dev/null || fail "could not clone ${C}"
done
# the upstream's next change of .env: a new default the clones must receive
printf '\nexport ENV_LOCAL_TEST_NEW_DEFAULT=arrived\n' >> "${U}/.env"
G "${U}" commit -q -am "a new default" || fail "could not commit the upstream change"

# --- 1. CONTROL: an edited tracked .env stops git pull ---
sed -i 's/^export SLACK_CHANNELS=""$/export SLACK_CHANNELS="C-PLANTED"/' "${D}/control/.env"
grep -qx 'export SLACK_CHANNELS="C-PLANTED"' "${D}/control/.env" || fail "1: could not plant the edit (no export SLACK_CHANNELS=\"\" line in .env)"
OUT=$(G "${D}/control" pull -q --ff-only 2>&1)
[ $? -ne 0 ] && echo "${OUT}" | grep -q "would be overwritten" || fail "1: CONTROL BROKEN: a clone with an edited tracked .env pulled the upstream change: ${OUT}"
echo "ok 1 - CONTROL: an edited tracked .env stops git pull --ff-only (\"would be overwritten\")"

# --- 2. the same setting in .env.local: the pull goes through ---
L=${D}/layout
printf 'export SLACK_CHANNELS="C-PLANTED"\nexport UI_PLANE=true\nexport AUTONOMY_LOOP_INTERVAL=4321\nGIT_USER_NAME="Planted Name"\nENV_LOCAL_TEST_PLAIN="plain value"\n' > "${L}/.env.local"
OUT=$(G "${L}" pull -q --ff-only 2>&1) || fail "2: git pull with the setting in .env.local: ${OUT}"
[ -z "$(G "${L}" status --porcelain 2>&1)" ] || fail "2: git status is not clean with .env.local: $(G "${L}" status --porcelain)"
G "${L}" check-ignore -q .env.local || fail "2: .env.local is not ignored"
[ "$(setting "${L}" SLACK_CHANNELS)" == "C-PLANTED" ] || fail "2: the setting of .env.local does not apply: SLACK_CHANNELS=$(setting "${L}" SLACK_CHANNELS)"
[ "$(setting "${L}" ENV_LOCAL_TEST_NEW_DEFAULT)" == "arrived" ] || fail "2: the upstream's new default did not arrive"
echo "ok 2 - the setting in .env.local: git pull --ff-only goes through, status clean (.env.local ignored), the setting applies, the new upstream default arrived"

# --- 3. the derived values follow .env.local ---
DERIVED=$(cd "${L}" && bash -c 'source .env > /dev/null 2>&1
	echo "ui=$(echo "${UI_ENV_OPTS}" | grep -o "UI_PLANE=[a-z]*")"
	echo "plane=[${PLANE_RUN_OPTS%% *}][${PLANE_URL}]"
	echo "agent=$(echo "${AGENT_ENV_OPTS}" | grep -o "AUTONOMY_LOOP_INTERVAL=[0-9]*")"
	echo "test=$(echo "${TEST_RUN_OPTS}" | grep -o "AUTONOMY_LOOP_INTERVAL=[0-9]*") $(echo "${TEST_RUN_OPTS}" | grep -o "TEST_CONTAINER=true")"
	echo "compose=$(envsubst < to/compose/template/docker-compose.yaml | grep -o "AUTONOMY_LOOP_INTERVAL=[0-9]*" | head -1)"
	echo "k8s=$(cat to/kubernetes/template/*.yaml | envsubst | grep -A1 "name: AUTONOMY_LOOP_INTERVAL$" | grep -o "[0-9][0-9]*" | head -1)"
	echo "child=$(bash -c "echo \${GIT_USER_NAME} / \${ENV_LOCAL_TEST_PLAIN}")"
	echo "export=$(type -t export)"')
for W in "ui=UI_PLANE=true" "plane=[--network][http://plane-proxy:80]" "agent=AUTONOMY_LOOP_INTERVAL=4321" "test=AUTONOMY_LOOP_INTERVAL=4321 TEST_CONTAINER=true" \
	"compose=AUTONOMY_LOOP_INTERVAL=4321" "k8s=4321" "child=Planted Name / plain value" "export=builtin"; do
	echo "${DERIVED}" | grep -qxF "${W}" || fail "3: a value derived from .env.local's settings does not follow them (want ${W}): $(echo "${DERIVED}" | tr '\n' ' ')"
done
# the same values without .env.local are the defaults (the control: the checks above can tell the two apart)
NOLOCAL=$(cd "${D}/first" && bash -c 'source .env > /dev/null 2>&1; echo "$(echo "${UI_ENV_OPTS}" | grep -o "UI_PLANE=[a-z]*") $(echo "${TEST_RUN_OPTS}" | grep -o "AUTONOMY_LOOP_INTERVAL=[0-9]*") plane=[${PLANE_RUN_OPTS}][${PLANE_URL}]"')
[ "${NOLOCAL}" == "UI_PLANE=false AUTONOMY_LOOP_INTERVAL=300 plane=[][]" ] || fail "3: without .env.local the defaults are not UI_PLANE=false (the Plane options empty: the board is opt-in) and AUTONOMY_LOOP_INTERVAL=300: ${NOLOCAL}"
echo "ok 3 - derived values follow .env.local: the Plane options on with UI_PLANE=true (the network and PLANE_URL; off by default, so empty without .env.local); AUTONOMY_LOOP_INTERVAL in the container options, TEST_RUN_OPTS (TEST_CONTAINER=true kept) and the rendered compose and kubernetes files; a plain line exported; export the builtin again (without .env.local: the defaults)"

# --- 4. the first run creates .env.local ---
F=${D}/first
OUT=$(ENV_LOCAL_SETUP=false "${F}/env-local.sh" 2>&1)
[ ! -e "${F}/.env.local" ] && [ -z "${OUT}" ] || fail "4: ENV_LOCAL_SETUP=false did something: ${OUT}"
OUT=$("${F}/env-local.sh" 2>&1)
[ -f "${F}/.env.local" ] && echo "${OUT}" | grep -q "^settings: created .env.local" || fail "4: a first run did not create .env.local and say so: ${OUT}"
grep -vqE '^[[:space:]]*(#|$)' "${F}/.env.local" && fail "4: the new .env.local holds a setting, not only comments: $(cat "${F}/.env.local")"
grep -qx '#export SLACK_CHANNELS=""' "${F}/.env.local" || fail "4: the new .env.local does not show a setting with its default"
SUM=$(sha256sum "${F}/.env.local")
OUT=$("${F}/env-local.sh" 2>&1)
[ -z "${OUT}" ] && [ "$(sha256sum "${F}/.env.local")" == "${SUM}" ] || fail "4: a second run said or changed something: ${OUT}"
[ "$(setting "${F}" UI_PLANE)" == "false" ] || fail "4: the commented .env.local changed a setting"
echo "ok 4 - a first run creates .env.local (comments only, a setting with its default) and says so; a second run is silent and changes nothing; ENV_LOCAL_SETUP=false skips it"

# --- 5. the one-time move of an edited tracked .env ---
M=${D}/move
sed -i -e 's/^export SLACK_CHANNELS=""$/export SLACK_CHANNELS="C-MOVED"/' -e 's/^export UI_PLANE=false$/export UI_PLANE=true/' "${M}/.env"
printf 'export ENV_LOCAL_TEST_ADDED=yes\n' >> "${M}/.env"
OUT=$("${M}/env-local.sh" 2>&1)
echo "${OUT}" | grep -q "^settings: your edits to .env (3 line(s)) moved to .env.local" || fail "5: the edited .env was not moved: ${OUT}"
for LINE in 'export SLACK_CHANNELS="C-MOVED"' 'export UI_PLANE=true' 'export ENV_LOCAL_TEST_ADDED=yes'; do
	grep -qxF "${LINE}" "${M}/.env.local" || fail "5: .env.local lacks the moved line ${LINE}: $(cat "${M}/.env.local")"
done
G "${M}" diff --quiet -- .env || fail "5: .env was not restored"
ls "${M}"/.env.edited-* > /dev/null 2>&1 && grep -qx 'export SLACK_CHANNELS="C-MOVED"' "${M}"/.env.edited-* || fail "5: no kept copy of the edited .env"
[ "$(setting "${M}" SLACK_CHANNELS) $(setting "${M}" UI_PLANE) $(setting "${M}" ENV_LOCAL_TEST_ADDED)" == "C-MOVED true yes" ] \
	|| fail "5: the moved settings do not apply"
OUT=$(G "${M}" pull -q --ff-only 2>&1) || fail "5: git pull after the move: ${OUT}"
[ -z "$(G "${M}" status --porcelain)" ] || fail "5: git status is not clean after the move: $(G "${M}" status --porcelain)"
OUT=$("${M}/env-local.sh" 2>&1)
[ -z "${OUT}" ] || fail "5: a second run said something: ${OUT}"
echo "ok 5 - the one-time move: 3 edited lines of .env into a new .env.local, the edited file kept, .env restored, the settings apply, then git pull goes through; a second run is silent"

# --- 6. no move when .env.local exists, nor for an edit beyond settings ---
R=${D}/refuse-local
printf 'export GIT_USER_NAME="Mine"\n' > "${R}/.env.local"
sed -i 's/^export SLACK_CHANNELS=""$/export SLACK_CHANNELS="C-STAYS"/' "${R}/.env"
LSUM=$(sha256sum < "${R}/.env.local"); ESUM=$(sha256sum < "${R}/.env")
OUT=$("${R}/env-local.sh" 2>&1)
echo "${OUT}" | grep -q "nothing moved" && echo "${OUT}" | grep -qF '    export SLACK_CHANNELS="C-STAYS"' \
	&& [ "$(sha256sum < "${R}/.env.local")" == "${LSUM}" ] && [ "$(sha256sum < "${R}/.env")" == "${ESUM}" ] \
	&& ! ls "${R}"/.env.edited-* > /dev/null 2>&1 || fail "6: with .env.local present something moved, or the lines were not printed: ${OUT}"
R=${D}/refuse-code
printf 'if true; then\n  export SLACK_CHANNELS="C-CODE"\nfi\n' >> "${R}/.env"
ESUM=$(sha256sum < "${R}/.env")
OUT=$("${R}/env-local.sh" 2>&1)
echo "${OUT}" | grep -q "beyond settings" && [ ! -e "${R}/.env.local" ] && [ "$(sha256sum < "${R}/.env")" == "${ESUM}" ] \
	|| fail "6: an edit beyond settings was moved, or .env.local was made: ${OUT}"
echo "ok 6 - no move with .env.local present (both files unchanged, the lines it would move printed), nor for an edit beyond settings (no .env.local, .env unchanged)"

# --- 7. a whole copy of .env as .env.local ---
cp "${D}/first/.env" "${D}/first/.env.local"
sed -i 's/^export AUTONOMY_LOOP_INTERVAL=300$/export AUTONOMY_LOOP_INTERVAL=77/' "${D}/first/.env.local"
OUT=$(timeout 20 bash -c "cd '${D}/first' && source .env > /dev/null 2>&1 && echo \"\${AUTONOMY_LOOP_INTERVAL}\"")
[ "${OUT}" == "77" ] || fail "7: a whole copy of .env as .env.local did not load (recursion or its value lost): ${OUT}"
echo "ok 7 - a whole copy of .env as .env.local loads without recursion and applies"

# --- 8. a shell with set -u (nounset) sources .env, with and without .env.local ---
for C in "${D}/control" "${D}/layout"; do
	OUT=$(cd "${C}" && bash -c 'set -u; source .env > /dev/null 2>&1; echo "reached ${UI_PLANE}"' 2>&1)
	echo "${OUT}" | grep -q "^reached " || fail "8: .env does not source under set -u in $(basename "${C}"): ${OUT}"
done
echo "ok 8 - .env sources under set -u, with and without .env.local"

# --- 9. the model settings reach the container as written: the [1m] suffix byte for byte, nothing for an empty one ---
MC=${D}/model
# model_words <repo>: the ANTHROPIC_* and CLAUDE_CODE_EFFORT_LEVEL words of the container options as run.sh's eval reads
# them (run:) and of the test container's as test.sh's array read reads them (test:), the raw option string (raw:), and
# the model id in the compose and kubernetes files rendered from the templates (envsubst, as run.sh renders them)
model_words()
{
	( cd "$1" && bash -c 'source .env > /dev/null 2>&1
		eval "set -- ${AGENT_ENV_OPTS}"
		while [ $# -gt 1 ]; do [ "$1" = -e ] && case "$2" in ANTHROPIC_*|CLAUDE_CODE_EFFORT_LEVEL=*) echo "run:$2" ;; esac; shift; done
		eval "TEST_RUN_ARGS=(${TEST_RUN_OPTS})"
		for A in "${TEST_RUN_ARGS[@]}"; do case "${A}" in ANTHROPIC_*|CLAUDE_CODE_EFFORT_LEVEL=*) echo "test:${A}" ;; esac; done
		echo "raw:$(echo "${AGENT_MODEL_ENV_OPTS}" | grep -o "ANTHROPIC_MODEL=[^ ]*")"
		echo "aws:$(echo "${AGENT_ENV_OPTS}" | grep -c -- "-e AWS_REGION")"
		echo "compose:$(envsubst < to/compose/template/docker-compose.yaml | grep -o "ANTHROPIC_MODEL=[^ ]*" | head -1)"
		echo "k8s:$(cat to/kubernetes/template/*.yaml | envsubst | grep -A1 "name: ANTHROPIC_MODEL$" | sed -n "s/^ *value: //p")"' )
}
WORDS=$(model_words "${MC}")
for W in 'run:ANTHROPIC_MODEL=us.anthropic.claude-fable-5-1[1m]' 'run:CLAUDE_CODE_EFFORT_LEVEL=max' \
	'run:ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-5-5[1m]' 'run:ANTHROPIC_DEFAULT_FABLE_MODEL=us.anthropic.claude-fable-5-1[1m]' \
	'test:ANTHROPIC_MODEL=us.anthropic.claude-fable-5-1[1m]' 'test:CLAUDE_CODE_EFFORT_LEVEL=max' \
	'raw:ANTHROPIC_MODEL=us.anthropic.claude-fable-5-1\[1m\]' 'compose:ANTHROPIC_MODEL=us.anthropic.claude-fable-5-1[1m]' 'k8s:"us.anthropic.claude-fable-5-1[1m]"' 'aws:1'; do
	echo "${WORDS}" | grep -qxF "${W}" || fail "9: the shipped model settings do not reach the container as written (want ${W}): $(echo "${WORDS}" | tr '\n' ' ')"
done
[ "$(echo "${WORDS}" | grep -c '^run:')" = 4 ] || fail "9: not the four model words in the container options: $(echo "${WORDS}" | grep '^run:' | tr '\n' ' ')"
# an override in .env.local follows, its suffix as written
printf 'export AGENT_MODEL="us.anthropic.claude-opus-5-5[1m]"\nexport AGENT_EFFORT=auto\n' > "${MC}/.env.local"
WORDS=$(model_words "${MC}")
echo "${WORDS}" | grep -qxF 'run:ANTHROPIC_MODEL=us.anthropic.claude-opus-5-5[1m]' && echo "${WORDS}" | grep -qxF 'test:CLAUDE_CODE_EFFORT_LEVEL=auto' && echo "${WORDS}" | grep -qxF 'aws:1' \
	|| fail "9: the model settings of .env.local do not reach the container options: $(echo "${WORDS}" | tr '\n' ' ')"
# all four empty: none of the four names is passed, so Claude Code keeps its own defaults
printf 'export AGENT_MODEL=""\nexport AGENT_EFFORT=""\nexport AGENT_MODEL_OPUS=""\nexport AGENT_MODEL_FABLE=""\n' > "${MC}/.env.local"
WORDS=$(model_words "${MC}")
# (aws:1 proves .env still sourced to the end with the four empty: an absence alone would also follow from a broken .env)
echo "${WORDS}" | grep -qxF 'aws:1' || fail "9: with the four model settings empty .env no longer gives the container options: $(echo "${WORDS}" | tr '\n' ' ')"
[ "$(echo "${WORDS}" | grep -c -E '^(run|test):')" = 0 ] || fail "9: an empty model setting still reaches the container: $(echo "${WORDS}" | grep -E '^(run|test):' | tr '\n' ' ')"
echo "ok 9 - the model settings reach the container options and the test container's as written, the [1m] suffix byte for byte (quoted in the raw string), and the rendered compose and kubernetes files; an .env.local override follows; all four empty, none of the four names is passed"

echo "Test-env-local succeeded"
