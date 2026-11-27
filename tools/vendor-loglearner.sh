#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Refresh the vendored LogLearner minimal runtime (Container-Root/opt/loglearner) from a release tarball of
# dmvevents/loglearning (the gated minimal runtime LogLearner's export gate produces, its releases under dist/),
# keeping what the image runs and adding the MIT license text VENDORED.md records (taken from a clone of that
# repository). It copies the release as it is: carry this repository's hardening of the files VENDORED.md names over by
# hand afterwards. Run from the repository root:
#
#   tools/vendor-loglearner.sh <loglearner-minimal-*.tar.gz> <path-to-loglearning-clone>
#
# Exits non-zero on any failure; the vendored tree is replaced only after the copy compiled.

set -euo pipefail

TARBALL=${1:?usage: tools/vendor-loglearner.sh <loglearner-minimal-*.tar.gz> <path-to-loglearning-clone>}
SRC=${2:?usage: tools/vendor-loglearner.sh <loglearner-minimal-*.tar.gz> <path-to-loglearning-clone>}
DST=Container-Root/opt/loglearner

[ -f "${TARBALL}" ] || { echo "no tarball at ${TARBALL}" >&2; exit 1; }
[ -f "${SRC}/LICENSE" ] || { echo "${SRC} is not a loglearning clone (no LICENSE)" >&2; exit 1; }
[ -d "${DST%/*}" ] || { echo "run from the repository root (no ${DST%/*})" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
tar xzf "${TARBALL}" -C "${TMP}"
TOP=$(find "${TMP}" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -f "${TOP}/dashboard/app.py" ] && [ -f "${TOP}/loglearner/pack.py" ] || { echo "the tarball is not a loglearner minimal runtime" >&2; exit 1; }

rm -rf "${DST:?}.new"
mkdir -p "${DST}.new"
rsync -a --exclude 'registry/board_routing.json' --exclude '__pycache__' --exclude '*.pyc' "${TOP}/" "${DST}.new/"
cp "${SRC}/LICENSE" "${DST}.new/"
[ -f "${DST}/VENDORED.md" ] && cp "${DST}/VENDORED.md" "${DST}.new/"

python3 -m compileall -q "${DST}.new" > /dev/null
find "${DST:?}.new" -name '__pycache__' -type d -prune -exec rm -rf {} +
# the same privacy scan the build runs (install-loglearner.sh): a release carrying a denylisted name or a home directory is refused here
python3 Container-Root/seed/scan.py --tree "${DST}.new" > "${TMP}/scan.out" 2>&1 \
	|| { tail -25 "${TMP}/scan.out"; echo "the release carries a denylisted name or a home directory (above, masked) - not vendored; ask upstream for a scrubbed release" >&2; rm -rf "${DST:?}.new"; exit 1; }
echo "privacy scan of the release: $(tail -1 "${TMP}/scan.out")"
rm -rf "${DST:?}"
mv "${DST:?}.new" "${DST:?}"

echo "vendored loglearner minimal runtime from ${TARBALL}"
echo "record in ${DST}/VENDORED.md: sha256 $(sha256sum "${TARBALL}" | cut -d' ' -f1)"
