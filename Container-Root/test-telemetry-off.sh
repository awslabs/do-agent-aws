#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the telemetry opt-outs (/agent/telemetry-off.sh, kanban coding guide check VKC-6). Each check FAILS if the
# property it proves is removed:
#   1. the file sets DO_NOT_TRACK=1 and GH_NO_UPDATE_NOTIFIER=1 in the environment of a shell that sources it, and nothing
#      else (no other variable changes)
#   2. startup.sh sources it before anything else it starts (static: the line comes before the first script it runs)
#   3. a child of a shell that sourced it sees both values (what every process startup.sh starts inherits)
set -u
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
F="${AGENT_DIR}/telemetry-off.sh"
fail() { echo "Test-telemetry-off FAILED: $*"; exit 1; }
[ -f "${F}" ] || fail "no ${F}"
sh -n "${F}" || fail "telemetry-off.sh does not parse as sh (startup.sh is /bin/sh)"

# --- 1. exactly the two variables ---
BEFORE=$(env -u DO_NOT_TRACK -u GH_NO_UPDATE_NOTIFIER sh -c 'env | sort')
AFTER=$(env -u DO_NOT_TRACK -u GH_NO_UPDATE_NOTIFIER sh -c '. "$1" && env | sort' sh "${F}")
DIFF=$(diff <(echo "${BEFORE}") <(echo "${AFTER}") | grep '^>' | sed 's/^> //' | grep -vE '^(LINENO|SHLVL|OLDPWD|PWD|_)=' | sort)   # the shell's own bookkeeping aside
[ "${DIFF}" == "$(printf 'DO_NOT_TRACK=1\nGH_NO_UPDATE_NOTIFIER=1')" ] || fail "sourcing the file changes other than the two variables: $(echo "${DIFF}" | tr '\n' ' ')"
echo "ok 1 - telemetry-off.sh sets DO_NOT_TRACK=1 and GH_NO_UPDATE_NOTIFIER=1 and nothing else"

# --- 2. startup.sh sources it first ---
ST="${BASE_DIR%/}/startup.sh"
L=$(grep -n '^\. /agent/telemetry-off.sh$' "${ST}" | cut -d: -f1); [ -n "${L}" ] || fail "startup.sh does not source /agent/telemetry-off.sh"
FIRST=$(grep -nE '^\s*/agent/[a-z-]+\.sh|^\s*setsid|^\s*exec ' "${ST}" | head -1 | cut -d: -f1)
[ "${L}" -lt "${FIRST}" ] || fail "startup.sh sources the opt-outs (line ${L}) after it starts something (line ${FIRST})"
echo "ok 2 - startup.sh sources the opt-outs before the first thing it starts"

# --- 3. inherited by a child ---
OUT=$(env -u DO_NOT_TRACK -u GH_NO_UPDATE_NOTIFIER sh -c '. "$1" && sh -c "echo \$DO_NOT_TRACK \$GH_NO_UPDATE_NOTIFIER"' sh "${F}")
[ "${OUT}" == "1 1" ] || fail "a child process does not see both values: '${OUT}'"
echo "ok 3 - a child of the shell that sourced the file sees DO_NOT_TRACK=1 and GH_NO_UPDATE_NOTIFIER=1"

echo "Test-telemetry-off succeeded"
