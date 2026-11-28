#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Refresh the vendored tmux-agent dashboard (Container-Root/opt/tmux-agent) from a clone you can
# reach. Builds upstream's dist/ (which upstream does not commit), copies the build plus the files the
# Apache-2.0 license requires, strips type declarations, and prints the commit to record in
# Container-Root/opt/tmux-agent/VENDORED.md and to pin as .env's TMUX_AGENT_REF. Run from the repository root:
#
#   tools/vendor-tmux-agent.sh ~/tmux-agent
#
# Requires node >= 20 and npm. Exits non-zero on any failure; the vendored tree is replaced only
# after the build succeeded.

set -euo pipefail

SRC=${1:?usage: tools/vendor-tmux-agent.sh <path-to-tmux-agent-clone>}
DST=Container-Root/opt/tmux-agent

[ -f "${SRC}/package.json" ] || { echo "no package.json at ${SRC}" >&2; exit 1; }
[ -d "${DST%/*}" ] || { echo "run from the repository root (no ${DST%/*})" >&2; exit 1; }
grep -q '"name": "tmux-agent"' "${SRC}/package.json" || { echo "${SRC} is not a tmux-agent tree" >&2; exit 1; }

COMMIT=$(git -C "${SRC}" rev-parse HEAD)
# untracked files too: the build compiles whatever is under src/, so an untracked source file would land in dist/
DIRTY=$(git -C "${SRC}" status --porcelain --untracked-files=all)
[ -z "${DIRTY}" ] || { echo "refusing: ${SRC} has uncommitted or untracked files (vendor only a committed tree)" >&2; exit 1; }

echo "building ${SRC} at ${COMMIT}"
( cd "${SRC}" && npm ci --no-fund --no-audit --loglevel=error && npm run build --silent )
[ -f "${SRC}/dist/bin/tmux-agent.js" ] || { echo "build produced no dist/bin/tmux-agent.js" >&2; exit 1; }

rm -rf "${DST:?}.new"
mkdir -p "${DST}.new"
cp -r "${SRC}/dist" "${DST}.new/dist"
find "${DST:?}.new/dist" -name '*.d.ts' -delete
for f in package.json package-lock.json LICENSE NOTICE README.md; do
	cp "${SRC}/${f}" "${DST}.new/"
done
[ -f "${DST}/VENDORED.md" ] && cp "${DST}/VENDORED.md" "${DST}.new/"
rm -rf "${DST:?}"
mv "${DST:?}.new" "${DST:?}"

echo "vendored: $(node "${DST}/dist/bin/tmux-agent.js" --version)"
echo "record in ${DST}/VENDORED.md: commit ${COMMIT} ($(git -C "${SRC}" log -1 --format=%cI)), and pin the same commit in .env: export TMUX_AGENT_REF=${COMMIT}"
