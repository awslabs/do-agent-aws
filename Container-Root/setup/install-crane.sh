#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing crane ..."

# crane (github.com/google/go-containerregistry) extracts filesystems from public
# container images without needing a docker daemon. install-headlamp.sh and
# install-hindsight-ui.sh use it to pull the official upstream images and keep only
# the pieces this container serves.
# v0.22.1 (2026-09-04) is built with Go 1.26.6; v0.22.0's Go 1.25.0 standard library carried CVE-2025-68121 (CRITICAL) and 25 HIGH
# findings in the CVE scan (docs/manual/supply-chain.md "CVE scan"), 4 HIGH remain at v0.22.1 - the newest release when the pin was moved (2026-10-27)
export CRANE_VERSION=v0.22.1

# the release tarball, checked against the release's published checksums.txt before anything is extracted (-f: a mistyped version
# fails here, not with an archive that is a 404 page); a mismatch or a failed fetch fails the installer
CRANE_URL=https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}
T=$(mktemp -d)
curl -fsSL -o "${T}/crane.tgz" "${CRANE_URL}/go-containerregistry_Linux_x86_64.tar.gz" || { rm -rf "${T:?}"; exit 1; }
curl -fsSL "${CRANE_URL}/checksums.txt" | grep ' go-containerregistry_Linux_x86_64.tar.gz$' | sed "s#  *go-containerregistry_Linux_x86_64.tar.gz#  ${T}/crane.tgz#" | sha256sum -c - || { rm -rf "${T:?}"; exit 1; }
tar -xzf "${T}/crane.tgz" -C /usr/local/bin crane || { rm -rf "${T:?}"; exit 1; }
rm -rf "${T:?}"

crane version
