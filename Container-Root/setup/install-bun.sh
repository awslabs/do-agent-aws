#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing Bun ..."

# Bun is the runtime the claude-mem plugin runs its hooks and worker under: every hook in the plugin
# calls `node plugin/scripts/bun-runner.js <script>`, which looks for `bun` on PATH, then in
# ~/.bun/bin, then in /usr/local/bin, and fails the hook with "Error: Bun not found. Please install
# Bun: https://bun.sh" when none is there. Install it explicitly and pinned, to a path the hooks
# resolve without any shell profile, instead of relying on the claude-mem installer's auto-install
# (which never ran while that installer was aborting non-interactively - see install-claudemem.sh).
# The pinned release archive, checked against its sha256 (the release's SHASUMS256.txt) before it is unpacked - no
# installer script is piped into a shell; a mismatch or a failed fetch fails the build.
export BUN_VERSION=1.4.4
case "$(uname -m)" in
	x86_64) BUN_ASSET=bun-linux-x64; BUN_SHA256=bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c ;;
	aarch64) BUN_ASSET=bun-linux-aarch64; BUN_SHA256=baa6bb36f51d6e58561e02bbea825038a9df454f673d6d776e8bbf86f8c7850e ;;
	*) echo "install-bun.sh: no pinned Bun release for $(uname -m)"; exit 1 ;;
esac
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
curl -fsSL -o "${T}/bun.zip" "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${BUN_ASSET}.zip" || exit 1
echo "${BUN_SHA256}  ${T}/bun.zip" | sha256sum -c - || exit 1
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "${T}/bun.zip" "${T}" || exit 1
install -m 0755 "${T}/${BUN_ASSET}/bun" /usr/local/bin/bun || exit 1

INSTALLED=$(/usr/local/bin/bun --version 2>/dev/null)
if [ "${INSTALLED}" != "${BUN_VERSION}" ]; then
	echo "Bun install FAILED: expected ${BUN_VERSION}, found '${INSTALLED}'"
	exit 1
fi
echo "Bun ${INSTALLED} installed at /usr/local/bin/bun"
