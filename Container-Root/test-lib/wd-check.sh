#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# wd-check.sh <dir> - the end-of-suite check test.sh runs inside the test container: nothing may have been written under
# the throwaway /wd (a tmpfs test.sh mounts in place of the user's wd/), because a test that writes there writes the
# user's checkout as soon as the real volume is mounted. Exit 0 with one line when the directory is empty; exit 1 with the
# FAILED line and the first twenty entries otherwise. test.sh proves the check on a planted entry before the suite runs.
W=$(find "${1:?dir}" -mindepth 1 2>/dev/null | wc -l)
if [ "${W}" -eq 0 ]; then
	echo "test.sh: nothing was written under the throwaway ${1} by the suite"
	exit 0
fi
echo "FAILED: the suite wrote ${W} entries under ${1} (the checkout's wd/ once the real volume is mounted):"
find "${1}" -mindepth 1 | head -20
exit 1
