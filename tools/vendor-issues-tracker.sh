#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Vendor the issues tracker's minimal runtime (Container-Root/opt/issues-tracker, the issues spoke's source) from an
# export tarball its owner cut: the tarball must have the sha256 given, its members only files and directories under one
# top directory, every file listed in its MANIFEST.sha256 with a matching hash, and the harness's tree scan
# (Container-Root/seed/scan.py --tree) must find nothing in it. The tree is copied byte for byte; VENDORED.md beside it
# records the pins, so a new export is one new run of this script. Run from the repository root:
#
#   tools/vendor-issues-tracker.sh <issues-tracker-runtime-*.tar.gz> <sha256> <version> <source head>
#
# Exits non-zero on any failure; the vendored tree is replaced only after every check passed. Nothing in the export is
# edited here: a finding goes back to its owner, and a fixed export is vendored again.

set -euo pipefail

USAGE="usage: tools/vendor-issues-tracker.sh <issues-tracker-runtime-*.tar.gz> <sha256> <version> <source head>"
TARBALL=${1:?${USAGE}}
WANT=${2:?${USAGE}}
VERSION=${3:?${USAGE}}
HEAD=${4:?${USAGE}}
DST=Container-Root/opt/issues-tracker

[ -f "${TARBALL}" ] || { echo "no tarball at ${TARBALL}" >&2; exit 1; }
[ -d "${DST%/*}" ] && [ -f Container-Root/seed/scan.py ] || { echo "run from the repository root (no ${DST%/*})" >&2; exit 1; }
echo "${VERSION}" | grep -qE '^[0-9A-Za-z][0-9A-Za-z.+-]*$' || { echo "the version '${VERSION}' is not a version string" >&2; exit 1; }
echo "${HEAD}" | grep -qE '^[0-9a-f]{7,40}$' || { echo "the source head '${HEAD}' is not a commit" >&2; exit 1; }
GOT=$(sha256sum "${TARBALL}" | cut -d' ' -f1)
[ "${GOT}" == "${WANT}" ] || { echo "the tarball's sha256 is ${GOT}, not ${WANT}" >&2; exit 1; }
# only files and directories, nothing absolute or climbing, all under one top directory
tar -tvzf "${TARBALL}" | grep -vE '^[d-]' && { echo "the tarball has a member that is neither a file nor a directory" >&2; exit 1; }
tar -tzf "${TARBALL}" | grep -E '^/|(^|/)\.\.(/|$)' && { echo "the tarball has an absolute or climbing member" >&2; exit 1; }
[ "$(tar -tzf "${TARBALL}" | cut -d/ -f1 | sort -u | wc -l)" == "1" ] || { echo "the tarball has not exactly one top directory" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
tar -xzf "${TARBALL}" -C "${TMP}" --no-same-owner --no-same-permissions
TOP=$(find "${TMP}" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -f "${TOP}/MANIFEST.sha256" ] || { echo "the export has no MANIFEST.sha256" >&2; exit 1; }
# every manifest line matches, and the tree is exactly the manifest's files
awk -v d="${TOP}/" '{ print $1 "  " d substr($0, 67) }' "${TOP}/MANIFEST.sha256" | sha256sum -c --quiet - \
	|| { echo "a file does not match MANIFEST.sha256" >&2; exit 1; }
diff <(find "${TOP}" -type f ! -path "${TOP}/MANIFEST.sha256" | sed "s|^${TOP}/||" | sort) <(awk '{ print substr($0, 67) }' "${TOP}/MANIFEST.sha256" | sort) \
	|| { echo "the tree's files are not exactly MANIFEST.sha256's" >&2; exit 1; }
# the harness's own tree scan, the one the build runs over the vendored trees: a hit refuses the export
python3 -I Container-Root/seed/scan.py --tree "${TOP}" > "${TMP}/scan.out" 2>&1 \
	|| { sed "s|${TOP}/||" "${TMP}/scan.out" | tail -25; echo "the export carries a finding of the harness's tree scan (above, masked) - not vendored; it goes back to the exporter" >&2; exit 1; }
N=$(grep -c . "${TOP}/MANIFEST.sha256")
TREESHA=$(sha256sum "${TOP}/MANIFEST.sha256" | cut -d' ' -f1)

rm -rf "${DST:?}.new"
mkdir -p "${DST}.new"
cp -a "${TOP}/." "${DST}.new/"
cat > "${DST}.new/VENDORED.md" << VEOF
# issues tracker - vendored runtime

This directory is the issues tracker's minimal runtime, shipped in the image at \`/opt/issues-tracker\` byte for byte as
its owner exported it: the tooling of the person's own issues workspace without session artifacts. The \`issues\` spoke
links it as its \`repo/\`; its cycle runs \`scripts/gh-ro\` and \`scripts/gh-dashboard.py\` from it, and its \`post.sh\` adds
\`scripts/redact-scan.sh --strict\` and the \`.claude/hooks/\` noise filter and \`block-gh-write.sh\`. Nothing here is edited
in this repository.

| | |
|---|---|
| Version | ${VERSION} |
| Tarball | $(basename "${TARBALL}"), sha256 \`${WANT}\` |
| Source head | \`${HEAD}\` |
| Files | ${N}, each in MANIFEST.sha256 (sha256 of that file: \`${TREESHA}\`); this file is the only addition |
| Checks at import | the tarball's sha256, only files and directories under one top directory, every MANIFEST line, the harness's tree scan (Container-Root/seed/scan.py --tree) |

Its \`bin/pr-timeline\` and \`bin/gh-comment-audit\` need \`jq\`, which this image does not carry. Refresh with
\`tools/vendor-issues-tracker.sh <tarball> <sha256> <version> <source head>\` from the repository root.
VEOF
rm -rf "${DST:?}"
mv "${DST:?}.new" "${DST:?}"
echo "vendored ${N} files of issues tracker ${VERSION} (source head ${HEAD}) into ${DST}; VENDORED.md records the pins"
