#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Offline test of /agent/slack-upload.sh - the file-upload path of the Slack integration - against the stub
# Slack API in /test-lib/slack-upload-stub.py (127.0.0.1 only, ephemeral port; no real Slack call). The checks
# are in /test-lib/slack-upload-test.py, one "ok N" line each; each FAILS if the property it proves is removed:
# syntax; the post gate off, a channel outside SLACK_CHANNELS, a missing or empty file, a bad thread_ts and an
# empty token each refuse with exit 1 and no API call; a 200 KB PNG into a thread and into the channel lands
# byte-for-byte (length and sha256 at the stub), is read back by files[].id, is logged to posted.jsonl, records
# its ts in SLACK_POST_RECORD, registers the thread / watches the channel share; missing_scope names files:write
# and the reinstall step; a refused upload or an ok:false completion is exit 1 with nothing shared; a landed file
# whose message is not found is exit 4 with "unknown" recorded; a lost completion response is exit 5; an HTTP 429
# on either token call is honored once; an upload_url on a foreign origin is refused before a byte is sent; the
# token appears in no output.
#
# AGENT_DIR (default /agent) names the scripts under test; TEST_LIB (default: test-lib beside this script, else
# /test-lib) the stub and the checks - so the test also runs from the source tree:
#   AGENT_DIR=/do-agent-aws/Container-Root/agent /do-agent-aws/Container-Root/test24.sh

AGENT_DIR=${AGENT_DIR:-/agent}
HERE=$(cd "$(dirname "$0")" && pwd)
TEST_LIB=${TEST_LIB:-${HERE}/test-lib}
[ -d "${TEST_LIB}" ] || TEST_LIB=/test-lib

fail()
{
	echo "Test24 FAILED: $1"
	exit 1
}

[ -f "${TEST_LIB}/slack-upload-test.py" ] || fail "${TEST_LIB}/slack-upload-test.py is missing"
[ -f "${TEST_LIB}/slack-upload-stub.py" ] || fail "${TEST_LIB}/slack-upload-stub.py is missing"
[ -f "${AGENT_DIR}/slack-upload.sh" ] || fail "${AGENT_DIR}/slack-upload.sh is missing"
[ -f "${AGENT_DIR}/slack-gates.sh" ] || fail "${AGENT_DIR}/slack-gates.sh is missing (slack-upload.sh sources it from beside itself)"

python3 -I "${TEST_LIB}/slack-upload-test.py" "${AGENT_DIR}" "${TEST_LIB}" || exit 1
