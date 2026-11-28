#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing ttyd (tmux browser terminal) ..."

# ttyd (github.com/tsl0922/ttyd, MIT) serves a terminal in the browser over a websocket.
# The harness attaches it to the container's shared tmux session so the operator can watch
# and drive the agent live at /tmux/ through the home proxy (writable by default; set
# UI_TMUX_WRITABLE=false for watch-only - see docs/manual/ui.md "Home page and reverse proxy").
# The distro package is preferred (ubuntu 22.04 ships ttyd 1.6.3, patched via apt); the
# pinned upstream release binary is the fallback for a base image whose apt has no ttyd.
# The writable/read-only flag spelling differs between the two major lines (1.6.x is
# writable unless -R, >=1.7 is read-only unless -W), so /agent/ui-start.sh detects the
# installed version and passes the right flag.
export TTYD_FALLBACK_VERSION=1.7.7

if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ttyd; then
	ARCH=$(uname -m)
	echo "apt has no ttyd package; installing upstream release ${TTYD_FALLBACK_VERSION} (${ARCH})"
	case "${ARCH}" in
		x86_64) TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55 ;;
		aarch64) TTYD_SHA256=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165 ;;
		*) echo "install-ttyd.sh: no pinned ttyd ${TTYD_FALLBACK_VERSION} checksum for ${ARCH}"; exit 1 ;;
	esac
	T=$(mktemp -d)
	curl -fsSL -o "${T}/ttyd" "https://github.com/tsl0922/ttyd/releases/download/${TTYD_FALLBACK_VERSION}/ttyd.${ARCH}" || exit 1
	echo "${TTYD_SHA256}  ${T}/ttyd" | sha256sum -c - || exit 1   # the release's SHA256SUMS
	install -m 0755 "${T}/ttyd" /usr/local/bin/ttyd || exit 1
	rm -rf "${T:?}"
fi

ttyd --version
