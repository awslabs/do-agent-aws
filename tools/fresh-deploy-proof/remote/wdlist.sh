#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# wd/ of the clone before and after ./test.sh: a listing (type, size, path - no mtime: the harness's own LogLearner
# re-index rewrites index pages every 5 minutes) and the LogLearner index's logical content (sessions by project),
# then the comparison. Run from the clone directory. Evidence 34 (before), 35 (after), 36 (the comparison).
set -u
TAG=$1; E=../evidence
case "${TAG}" in
before) N=34 ;;
after)  N=35 ;;
*) echo "wdlist.sh before|after" >&2; exit 1 ;;
esac
sudo -n find wd -printf '%y %s %p\n' | sort > ${E}/${N}-wd-${TAG}.txt
sudo -n python3 - wd/loglearner/index.db << 'PY' > ${E}/${N}-wd-${TAG}-index.txt 2>&1
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print("sessions by project:", sorted(c.execute("select project, count(*) from sessions group by project").fetchall()))
print("body rows by project:", sorted(c.execute("select project, count(*) from body group by project").fetchall()))
PY
if [ "${TAG}" == "before" ]; then
	touch ${E}/34-wd-marker
	echo "wd/ before ./test.sh: $(wc -l < ${E}/34-wd-before.txt) entries; LogLearner index: $(tr '\n' ' ' < ${E}/34-wd-before-index.txt)"
else
	{
	echo "wd/ listing (type, size, path) before ./test.sh: $(wc -l < ${E}/34-wd-before.txt) entries; after: $(wc -l < ${E}/35-wd-after.txt) entries"
	echo "entries added, removed or resized across ./test.sh (diff of the two listings; nothing below = none):"
	diff ${E}/34-wd-before.txt ${E}/35-wd-after.txt | grep '^[<>]' | sed 's/^/  /'
	echo "files modified during the test window (mtime newer than a marker written just before ./test.sh):"
	sudo -n find wd -type f -newer ${E}/34-wd-marker -printf '  %s %p\n' | sort -k2
	echo "LogLearner index before: $(tr '\n' ' ' < ${E}/34-wd-before-index.txt)"
	echo "LogLearner index after:  $(tr '\n' ' ' < ${E}/35-wd-after-index.txt)"
	if [ "$(cat ${E}/34-wd-before-index.txt)" == "$(cat ${E}/35-wd-after-index.txt)" ]; then echo "LogLearner index content: IDENTICAL sessions and projects before and after the suite"; else echo "LogLearner index content: CHANGED across the suite"; fi
	if grep -q 'tmp-loop-smoke' ${E}/35-wd-after-index.txt; then echo "LEAK: the test project -tmp-loop-smoke is in the user's index"; else echo "no test project (-tmp-loop-smoke) in the user's index"; fi
	} | tee ${E}/36-wd-diff.txt
fi
