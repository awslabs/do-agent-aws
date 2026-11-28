#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# harness-verdict.sh LOG CREDENTIAL - judge one run of the image's own test suite.
#
# LOG is the output of the loop the sandbox tests run inside the image:
#   for t in $(ls /test*.sh); do echo "Running test $t"; $t; echo "EXIT $t $?"; done
# (./test.sh runs the same loop without the EXIT lines). CREDENTIAL is "present"
# when a model credential is configured for the run, anything else otherwise.
# Prints one line per test in Container-Root/test*.sh and exits 0 only when
# every one printed "TestN succeeded" and exited 0. test3 (two autonomy-loop
# fires against the model) may instead print "Test3 skipped" when CREDENTIAL is
# not "present"; with a credential it must succeed. A test missing from LOG fails.

LOG="${1:?usage: harness-verdict.sh LOG CREDENTIAL}"
CREDENTIAL="${2:?usage: harness-verdict.sh LOG CREDENTIAL}"
BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"

[ -f "${LOG}" ] || { echo "harness-verdict.sh: no log ${LOG}"; exit 1; }
# The suite the image was built with: Container-Root/test*.sh at HEAD (render.sh
# and e2e.sh take everything from HEAD; untracked files do not count).
TESTS=$(git -C "${BASE_DIR}" ls-tree --name-only HEAD Container-Root/ | sed -n 's#^Container-Root/\(test[^/]*\.sh\)$#\1#p')
[ -n "${TESTS}" ] || { echo "harness-verdict.sh: no Container-Root/test*.sh at HEAD"; exit 1; }

FAILED=0
for t in ${TESTS}; do
	n=${t#test}
	n=${n%.sh}
	EXIT_LINE=$(grep -a "^EXIT /${t} " "${LOG}" | tail -1)
	RC=${EXIT_LINE##* }
	if grep -aq "^Test${n} succeeded" "${LOG}" && [ "${RC}" = "0" ]; then
		echo "test${n} succeeded"
	elif [ "${n}" = "3" ] && [ "${CREDENTIAL}" != "present" ] && grep -aq "^Test3 skipped" "${LOG}" && [ "${RC}" = "0" ]; then
		echo "test3 skipped (no model credential configured)"
	else
		echo "test${n} FAILED (exit ${RC:-missing})"
		FAILED=$((FAILED + 1))
	fi
done
[ ${FAILED} -eq 0 ]
