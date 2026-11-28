#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# vk-runner-repos.sh - the agent runner's Recent repositories: register the harness workspace (VK_REPOS_ROOT, /wd,
# when it is a git repository), every git repository one level under it and every one under its projects/ folder,
# where /agent/starter-repo.sh makes the starter repository (projects/scratch) and README.md says your own go, with the
# runner (vibe-kanban 0.1.44's POST /api/repos), so its "Which repositories would you like to work on?" page starts
# with them instead of an empty Recent list (docs/manual/boards.md "The agent runner"). Idempotent: a path the runner already lists
# is left alone. Best effort: it waits for the runner's /api/health up to VK_REPOS_WAIT seconds (ui-start.sh runs it
# in the background right after the runner starts), registers, prints one summary line and exits. Re-run by hand
# after cloning a repository under the workspace:  docker exec <container> /agent/vk-runner-repos.sh
#
# Settings (environment): VK_RUNNER_URL (default http://127.0.0.1:${UI_PORT_VIBE_KANBAN:-8081}, loopback: the runner
# listens on 127.0.0.1 only), VK_REPOS_ROOT (default /wd), VK_REPOS_WAIT (seconds, default 120).
# Exit status: 0 registered or nothing to register; 2 the runner did not answer in time or refused a listing.

URL=${VK_RUNNER_URL:-http://127.0.0.1:${UI_PORT_VIBE_KANBAN:-8081}}
ROOT=${VK_REPOS_ROOT:-/wd}
WAIT=${VK_REPOS_WAIT:-120}

DEADLINE=$(( $(date +%s) + WAIT ))
until curl -sf -o /dev/null --max-time 3 "${URL}/api/health"; do
	if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
		echo "vk-runner repos: the runner at ${URL} did not answer within ${WAIT}s - nothing registered (re-run /agent/vk-runner-repos.sh once it is up)"
		exit 2
	fi
	sleep 2
done

# the candidates: the workspace itself when it is a repository, then every repository one level under it and under its
# projects/ folder (the places starter-repo.sh looks before it makes the starter there)
CANDIDATES=()
[ -d "${ROOT}/.git" ] && CANDIDATES+=("${ROOT}")
for d in "${ROOT}"/*/ "${ROOT}"/projects/*/; do
	d=${d%/}
	[ -d "${d}/.git" ] && CANDIDATES+=("${d}")
done

# what the runner lists already (paths), so a second run changes nothing
LISTED=$(curl -s --max-time 10 "${URL}/api/repos" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not d.get("success", False):
    sys.exit(3)
for r in d.get("data") or []:
    print(r.get("path", ""))
') || { echo "vk-runner repos: the runner at ${URL} did not list its repositories - nothing registered"; exit 2; }

NEW=0; OLD=0; REFUSED=0; NAMES=""
for p in "${CANDIDATES[@]}"; do
	if printf '%s\n' "${LISTED}" | grep -qxF -- "${p}"; then
		OLD=$(( OLD + 1 )); continue
	fi
	BODY=$(python3 -c 'import json, os, sys; print(json.dumps({"path": sys.argv[1], "display_name": os.path.basename(sys.argv[1]) or sys.argv[1]}))' "${p}")
	if curl -s --max-time 20 -H 'Content-Type: application/json' -X POST --data "${BODY}" "${URL}/api/repos" | python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if d.get("success") else 1)' 2>/dev/null; then
		NEW=$(( NEW + 1 )); NAMES="${NAMES} ${p}"
	else
		REFUSED=$(( REFUSED + 1 )); echo "vk-runner repos: the runner refused ${p}"
	fi
done

ROOT_NOTE="the workspace ${ROOT} is a git repository"
[ -d "${ROOT}/.git" ] || ROOT_NOTE="the workspace ${ROOT} is not a git repository itself"
echo "vk-runner repos: ${NEW} registered${NAMES:+ (${NAMES# })}, ${OLD} listed already, ${REFUSED} refused; ${ROOT_NOTE}; repositories one level under it and under its projects/ are the candidates"
exit 0
