#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of container: the agent's CLI runs. /usr/local/bin/claude (the link /setup/install-claude.sh makes) ends at
# the claude-code package's bin/claude.exe, a small stub until the package's postinstall puts the platform-native
# binary in its place; with the stub, claude only prints "claude native binary not installed" and no agent session
# starts. Offline and without credentials: claude --version reads no account. Each check FAILS if the property it
# proves is removed:
#   1. claude --version exits 0 and prints a version
#   2. the file claude runs is the native binary (an ELF file), not the stub
#   3. an update keeps it so: the image's npm allows the package's install scripts (allow-scripts), without which npm 12
#      leaves the stub as claude when claude's auto-updater installs a new version in the running container
# A failure names what claude runs (the stub's size, or a missing file) and whether the platform-native package's
# binary is installed.

fail()
{
	echo "Test1 FAILED: $1"
	exit 1
}

EXE=$(readlink -f /usr/local/bin/claude 2> /dev/null)
[ -n "${EXE}" ] || fail "/usr/local/bin/claude is missing or a broken link (/setup/install-claude.sh links it)"
NM=$(/usr/local/bin/npm root -g --logs-max=0 2> /dev/null) || NM=${EXE%/@anthropic-ai/claude-code/bin/claude.exe}
NATIVE=$(find "${NM}/@anthropic-ai" -maxdepth 5 -path '*/claude-code-linux-*/claude' -type f 2> /dev/null | head -1)
WHAT="claude runs ${EXE} ($(stat -c '%s bytes' "${EXE}" 2> /dev/null || echo 'missing')); the platform-native package's binary is ${NATIVE:-not installed}"

# --- 1. claude --version ---
V=$(timeout 60 /usr/local/bin/claude --version 2>&1) || fail "claude --version exited non-zero - ${WHAT}. It said: ${V}"
echo "${V}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' || fail "claude --version printed no version - ${WHAT}. It said: ${V}"
echo "ok 1 - claude --version: ${V}"

# --- 2. the native binary, not the stub ---
[ "$(head -c 4 "${EXE}" 2> /dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] \
	|| fail "claude does not run the native binary (no ELF file) - ${WHAT}"
echo "ok 2 - claude runs the native binary ${EXE}"

# --- 3. an update runs the package's postinstall ---
# (--logs-max=0: npm writes no debug log under ~/.npm/_logs for these two reads)
NPM_V=$(/usr/local/bin/npm --version --logs-max=0 2>&1)
ALLOW=$(/usr/local/bin/npm config get allow-scripts --logs-max=0 2>&1)
echo "${ALLOW}" | grep -qF @anthropic-ai/claude-code \
	|| fail "npm's allow-scripts (${ALLOW}) does not cover @anthropic-ai/claude-code: npm ${NPM_V} would block its postinstall on an update, and claude would be the stub (/setup/harden.sh sets it)"
echo "ok 3 - npm ${NPM_V} allows the install scripts of @anthropic-ai/claude-code, so an update places the native binary"

echo "Test1 succeeded"
