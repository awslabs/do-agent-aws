#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# issues spoke - ONE read-only cycle (charter.md beside this file): the open pull requests and issues in scope, their
# conflicts, failing checks, requested changes and owed replies, into STATUS.md and status.json in the working
# directory; the changes as notices for agent; agent's data questions answered over the bus. Exits. The supervisor runs
# it at the cadence its registry entry sets; this script never sleeps, loops or reads an interval.
#
#   loop.sh               one cycle
#   loop.sh --self-test   the read-only front refuses every write form, and none reaches gh (a recording stub);
#                         needs no token and no network
#
# Every gh call of the cycle goes through the read-only front: the vendored issues tracker's scripts/gh-ro when
# ${ISSUES_TRACKER_DIR} (default /opt/issues-tracker) carries it, else gh-ro.sh beside this file. A shim named gh, first
# on the cycle's PATH, runs the front with the PATH it was given, so gh-dashboard.py's own gh calls pass through it too.
# The shim is written into the private directory (ISSUES_SPOKE_PRIVATE_DIR, default ${SUPERVISOR_DIR}/issues/private),
# outside the session's working directory, so the drafting session - which runs in that working directory - cannot
# rewrite it to make the next cycle run its own gh; the cycle also rewrites the shim at the start of every cycle.
# Environment: ISSUES_SPOKE_WD (default ${SPOKE_DIR:-/wd/issues}); ISSUES_SPOKE_PRIVATE_DIR; ISSUES_REPOS and
# settings.json in the working directory (settings.example.json beside this file); ISSUES_GH_LOGIN (default: the login
# gh api user returns); GH_TOKEN, read by gh. Writes the working directory - status.json, status.partial.json,
# state.json, STATUS.md, notices.jsonl, cycle.log, last-cycle, refusals.log, outbox/, dashboard/ - and the shim in the
# private directory.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export ISSUES_SPOKE_WD="${ISSUES_SPOKE_WD:-${SPOKE_DIR:-/wd/issues}}"
export ISSUES_TRACKER_DIR="${ISSUES_TRACKER_DIR:-/opt/issues-tracker}"
export ISSUES_SPOKE_BUS="${ISSUES_SPOKE_BUS:-${AGENT_DIR:-/agent}/bus.sh}"
WD=${ISSUES_SPOKE_WD}
# the private directory, outside the session's working directory: the shim and post.sh's copy live here, where the
# drafting session (which runs in the working directory) cannot write them with its file tools
export ISSUES_SPOKE_PRIVATE_DIR="${ISSUES_SPOKE_PRIVATE_DIR:-${SUPERVISOR_DIR:-/wd/supervisor}/issues/private}"
PRIV=${ISSUES_SPOKE_PRIVATE_DIR}
SHIMDIR="${PRIV}/gh-front"
mkdir -p "${WD:?}/outbox" "${SHIMDIR:?}" || { echo "issues loop: cannot create ${WD} or ${PRIV}" >&2; exit 2; }
chmod 700 "${PRIV}" 2>/dev/null || true

FRONT="${HERE}/gh-ro.sh"
[ -x "${ISSUES_TRACKER_DIR}/scripts/gh-ro" ] && FRONT="${ISSUES_TRACKER_DIR}/scripts/gh-ro"
export ISSUES_SPOKE_FRONT="${FRONT}" ISSUES_SPOKE_REAL_PATH="${PATH}"
# the shim: gh for everything the cycle runs; the front it starts gets the PATH this script was given, so the front's
# own gh is the real one (or a test's stub). Rewritten every cycle, so a session's edit to it never survives to run
cat > "${SHIMDIR}/gh.tmp" << 'SHIM'
#!/bin/bash
export PATH="${ISSUES_SPOKE_REAL_PATH:?}"
exec "${ISSUES_SPOKE_FRONT:?}" "$@"
SHIM
chmod +x "${SHIMDIR}/gh.tmp" && mv -f "${SHIMDIR:?}/gh.tmp" "${SHIMDIR:?}/gh" || exit 2
export PATH="${SHIMDIR}:${PATH}"

if [ "${1:-}" = "--self-test" ]; then
	# a recording gh behind the front: every form below must be refused before it, and the reads must reach it
	ST="${WD}/self-test"
	mkdir -p "${ST:?}/bin"
	: > "${ST:?}/calls.log"
	printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.log"\necho "[]"\n' "${ST}" > "${ST}/bin/gh"
	chmod +x "${ST}/bin/gh"
	export ISSUES_SPOKE_REAL_PATH="${ST}/bin:${ISSUES_SPOKE_REAL_PATH}"
	FAILS=0
	while IFS= read -r C; do
		[ -n "${C}" ] || continue
		# shellcheck disable=SC2086 # the line is the argument list, split on purpose
		if gh ${C} > /dev/null 2>&1; then echo "FAIL not refused: gh ${C}"; FAILS=1; else echo "PASS refused: gh ${C}"; fi
	done << 'FORMS'
pr comment 1 --repo o/r --body x
issue comment 1 --repo o/r --body x
pr merge 1 --repo o/r
pr close 1 --repo o/r
pr review 1 --repo o/r --approve
pr create --repo o/r --title x --body y
issue create --repo o/r --title x --body y
issue close 1 --repo o/r
api -X POST repos/o/r/issues/1/comments
api --method PATCH repos/o/r/issues/1
api -f body=x repos/o/r/issues/1/comments
api -F body=@x.md repos/o/r/issues/1/comments
api --input x.json repos/o/r/issues/1/comments
api graphql -f query=mutation{x}
repo delete o/r
gist create x.md
FORMS
	N=$(wc -l < "${ST}/calls.log")
	[ "${N}" -eq 0 ] && echo "PASS none of them reached gh" || { echo "FAIL ${N} of them reached gh: $(head -3 "${ST}/calls.log" | tr '\n' ';')"; FAILS=1; }
	for C in "pr list --repo o/r --state open --json number" "issue view 1 --repo o/r --json number" "api user --jq .login"; do
		# shellcheck disable=SC2086
		gh ${C} > /dev/null 2>&1 && echo "PASS read allowed: gh ${C}" || { echo "FAIL read refused: gh ${C}"; FAILS=1; }
	done
	[ "$(wc -l < "${ST}/calls.log")" -eq 3 ] || { echo "FAIL the three reads did not each reach gh once"; FAILS=1; }
	echo "front: ${FRONT}"
	exit ${FAILS}
fi
exec python3 -I "${HERE}/cycle.py"
