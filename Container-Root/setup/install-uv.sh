#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Usage: install-uv.sh [<bin dir>]   install uv and uvx into <bin dir> (default ~/.local/bin)
#
# uv (github.com/astral-sh/uv, Apache-2.0 or MIT): the pinned release archive, checked against its sha256 before it
# is unpacked - no installer script is piped into a shell. A mismatch or a failed fetch fails the build. To move the
# pin: the release's <archive>.sha256 files (https://github.com/astral-sh/uv/releases/download/<version>/).

echo ""
echo "Installing UV ..."

export UV_VERSION=0.13.9
case "$(uname -m)" in
	x86_64) UV_TRIPLE=x86_64-unknown-linux-gnu; UV_SHA256=a7fbaff2b9a271d85c1bdb540941090fd1ce011797b4abeb48e4dcd39c2471d5 ;;
	aarch64) UV_TRIPLE=aarch64-unknown-linux-gnu; UV_SHA256=0797542018e541a9288855df555c8077eed06f7a47d206362030480e8ecc9f3d ;;
	*) echo "install-uv.sh: no pinned uv release for $(uname -m)"; exit 1 ;;
esac
BIN_DIR=${1:-${HOME}/.local/bin}

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
curl -fsSL -o "${T}/uv.tgz" "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_TRIPLE}.tar.gz" || exit 1
echo "${UV_SHA256}  ${T}/uv.tgz" | sha256sum -c - || exit 1
tar -xzf "${T}/uv.tgz" -C "${T}" || exit 1
mkdir -p "${BIN_DIR}" || exit 1
install -m 0755 "${T}/uv-${UV_TRIPLE}/uv" "${T}/uv-${UV_TRIPLE}/uvx" "${BIN_DIR}/" || exit 1

if [ -z "$1" ]; then
	echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi
"${BIN_DIR}/uv" --version | grep -qF "uv ${UV_VERSION} " || { echo "install-uv.sh: ${BIN_DIR}/uv is not ${UV_VERSION}: $("${BIN_DIR}/uv" --version)"; exit 1; }
"${BIN_DIR}/uv" --version
