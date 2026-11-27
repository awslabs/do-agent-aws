#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing buildctl (the BuildKit client of the docker spoke's build substrate) ..."

# buildctl (github.com/moby/buildkit, Apache-2.0) is the client of the BuildKit daemon the docker target runs beside the
# agent container (docs/manual/agents.md "Docker agent"): /agent/image-build.sh builds an image through the daemon's socket, mounted
# at /run/buildkit, and pushes it to the stack's registry. The image has no Docker CLI and no Docker socket. The release
# tarball is fetched at build time and checked against its sha256 (the release's published asset digests, re-computed
# here when the pin was set); only bin/buildctl is kept. The pin is the release of the daemon's image in .env
# (DOCKER_BUILDKIT_IMAGE): client and daemon move together. A mismatch, a failed fetch or another architecture fails the
# build.
# The newest release when the pin was last moved; the digests are the release's (GitHub's asset digests), re-computed on the
# downloads
export BUILDKIT_VERSION=v0.35.0
case "$(uname -m)" in
	x86_64) ARCH=amd64; BUILDKIT_SHA256=37b3befbed28fb72a44d72bf42362c268610386c42feafa27cb45ee0b531369c ;;
	aarch64) ARCH=arm64; BUILDKIT_SHA256=e33872fbc13d7858f2fd4e434697e9a1aa03347a6fe13f86a58c9c3b0e711286 ;;
	*) echo "install-buildctl.sh: no pinned BuildKit release for $(uname -m)"; exit 1 ;;
esac

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
curl -fsSL -o "${T}/buildkit.tgz" "https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-${ARCH}.tar.gz" || exit 1
echo "${BUILDKIT_SHA256}  ${T}/buildkit.tgz" | sha256sum -c - || exit 1
tar -xzf "${T}/buildkit.tgz" -C "${T}" bin/buildctl || exit 1
install -m 0755 "${T}/bin/buildctl" /usr/local/bin/buildctl || exit 1
# the client is the pinned release, not merely a buildctl
buildctl --version | grep -qF " ${BUILDKIT_VERSION} " || { echo "install-buildctl.sh: buildctl is not ${BUILDKIT_VERSION}: $(buildctl --version)"; exit 1; }
buildctl --version
