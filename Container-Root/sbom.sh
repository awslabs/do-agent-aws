#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Software bill of materials of this image (docs/manual/supply-chain.md "Software bill of materials"): one line per third-party component,
# `<name> <version> - <license>`, from the four sources /agent/sbom.py reads - the installed dpkg packages, every npm package
# under a node_modules directory, every Python distribution's metadata, and /setup/third-party.txt, the registry of the tools
# the installers fetch as archives, installers, clones, image exports and vendored trees. The Dockerfile runs this as its
# LAST step, so /SBOM.txt lists everything setup.sh installed (the sandbox kit's dockerfile runs it again after its own
# layer); ./build.sh then copies it out of the image as THIRD-PARTY-LICENSES at the repository root. Re-runnable in a
# running container: `/sbom.sh` rewrites /SBOM.txt, `/sbom.sh <file>` writes elsewhere (/test-sbom.sh compares the two).
# Nothing is written under /wd. A failure here fails the build: the image never ships without its bill of materials.

OUT=${1:-/SBOM.txt}

echo ""
echo "Generating ${OUT} (the image's software bill of materials)"

python3 /agent/sbom.py --output "${OUT}" || { echo "sbom.sh: FAILED - /agent/sbom.py did not write ${OUT}" >&2; exit 1; }
[ -s "${OUT}" ] || { echo "sbom.sh: FAILED - ${OUT} is empty" >&2; exit 1; }

# the header's counts line, as the build log's one-line summary
grep -m1 '^## components:' "${OUT}" | sed 's/^## /sbom.sh: /'
echo "sbom.sh: $(awk 'b && NF && !/^# / {n++} /^$/ {b=1} END {print n+0}' "${OUT}") component lines in ${OUT}"
