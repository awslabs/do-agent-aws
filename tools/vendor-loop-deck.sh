#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Refresh the vendored Loop Deck release tree (Container-Root/opt/loop-deck) from a clone of the release repository
# you can reach, byte-identical to its committed tree (git archive; no .git, no untracked file), and print the lines
# to record in Container-Root/opt/loop-deck/VENDORED.md: the commit, the git tree, the tree sha256 (the recipe
# VENDORED.md and test-loop-deck.sh share) and RELEASE.json's pins. No build step: the Deck is Python standard library.
# Run from the repository root:
#
#   tools/vendor-loop-deck.sh ~/loop-deck [<expected commit>]
#
# Exits non-zero on any failure; the vendored tree is replaced only after the copy succeeded and matched.

set -euo pipefail

SRC=${1:?usage: tools/vendor-loop-deck.sh <path-to-loop-deck-clone> [<expected commit>]}
WANT=${2:-}
DST=Container-Root/opt/loop-deck

[ -f "${SRC}/deck-server.py" ] && [ -f "${SRC}/RELEASE.json" ] || { echo "${SRC} is not a Loop Deck release tree (no deck-server.py + RELEASE.json)" >&2; exit 1; }
[ -d "${DST%/*}" ] || { echo "run from the repository root (no ${DST%/*})" >&2; exit 1; }
COMMIT=$(git -C "${SRC}" rev-parse HEAD)
TREE=$(git -C "${SRC}" rev-parse "HEAD^{tree}")
DIRTY=$(git -C "${SRC}" status --porcelain --untracked-files=no)
[ -z "${DIRTY}" ] || { echo "refusing: ${SRC} has uncommitted changes (vendor only a committed tree)" >&2; exit 1; }
[ -z "${WANT}" ] || [ "${COMMIT}" == "${WANT}" ] || { echo "refusing: ${SRC} is at ${COMMIT}, not the expected ${WANT}" >&2; exit 1; }

rm -rf "${DST:?}.new"
mkdir -p "${DST}.new"
git -C "${SRC}" archive --format=tar HEAD | tar -x -C "${DST}.new"
[ -f "${DST}/VENDORED.md" ] && cp "${DST}/VENDORED.md" "${DST}.new/"
SHA=$(cd "${DST}.new" && find . -type f ! -name VENDORED.md ! -path '*/__pycache__/*' | sort | xargs -d '\n' sha256sum | sha256sum | cut -d' ' -f1)
N=$(cd "${DST}.new" && find . -type f ! -name VENDORED.md ! -path '*/__pycache__/*' | wc -l)
rm -rf "${DST:?}"
mv "${DST:?}.new" "${DST:?}"

echo "vendored ${N} files from ${SRC} at ${COMMIT}"
echo "record in ${DST}/VENDORED.md:"
echo "  Commit        ${COMMIT} ($(git -C "${SRC}" log -1 --format=%cI))"
echo "  Git tree      ${TREE}"
echo "  ${N}-file sha256 ${SHA}"
python3 - "${DST}/RELEASE.json" << 'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("  RELEASE.json  source_sha %s, source_tree %s, deck_version %s, cut_at %s" % (r.get("source_sha"), r.get("source_tree"), r.get("deck_version"), r.get("cut_at")))
PY
