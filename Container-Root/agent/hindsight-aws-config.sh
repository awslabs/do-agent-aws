#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# AWS configuration for the memory API - give hindsight-api the same AWS config the agent has.
#
# hindsight-api runs as the agent user, like every process of the container, with its own HOME: the memory data
# directory (HINDSIGHT_HOME, /home/hindsight by default), where its embedded PostgreSQL keeps the cluster. It calls
# Amazon Bedrock for every memory extraction. run.sh mounts the host's ~/.aws at /home/agent/.aws and passes
# AWS_PROFILE/AWS_REGION through; with AWS_PROFILE set, boto3 looks the profile up under the PROCESS'S home, so the
# API found no `[profile ...]` and every extraction failed with "The config profile (...) could not be found" while
# claude worked. So this script, run by /agent/ui-start.sh (and by the tests before they
# start their own API), COPIES /home/agent/.aws into /home/hindsight/.aws, mode 0700/0600, and the API is started with
# AWS_CONFIG_FILE/AWS_SHARED_CREDENTIALS_FILE pointing there. The copy is refreshed on every start (rotated static
# credentials, a new profile), never persisted, and lives inside the container only. Without /home/agent/.aws nothing
# is copied: the instance role (IMDS) or AWS_* variables in the environment serve the API alike.
#
# Settings (environment):
#   HINDSIGHT_AWS_SRC   - the directory to copy from (default /home/agent/.aws)
#   HINDSIGHT_AWS_DST   - the memory API's copy (default /home/hindsight/.aws)
# Exit 0 whether or not there was anything to copy (one line says which); exit 1 when the copy fails.

HINDSIGHT_AWS_SRC=${HINDSIGHT_AWS_SRC:-/home/agent/.aws}
HINDSIGHT_AWS_DST=${HINDSIGHT_AWS_DST:-/home/hindsight/.aws}

if [ ! -d "${HINDSIGHT_AWS_SRC}" ]; then
	echo "hindsight aws config: no ${HINDSIGHT_AWS_SRC} - nothing to copy (the instance role or AWS_* variables serve the API)"
	exit 0
fi
TMP="${HINDSIGHT_AWS_DST:?}.tmp.$$"
rm -rf "${TMP:?}"
if ! cp -a "${HINDSIGHT_AWS_SRC}" "${TMP}" 2>/dev/null; then
	rm -rf "${TMP:?}"
	echo "hindsight aws config: cannot copy ${HINDSIGHT_AWS_SRC} to ${HINDSIGHT_AWS_DST}" >&2
	exit 1
fi
chmod -R go-rwx "${TMP}" || { rm -rf "${TMP:?}"; echo "hindsight aws config: cannot set the mode of ${TMP}" >&2; exit 1; }
rm -rf "${HINDSIGHT_AWS_DST:?}" && mv "${TMP:?}" "${HINDSIGHT_AWS_DST:?}" || { rm -rf "${TMP:?}"; echo "hindsight aws config: cannot install ${HINDSIGHT_AWS_DST}" >&2; exit 1; }
FILES=$(find "${HINDSIGHT_AWS_DST}" -type f | wc -l)
echo "hindsight aws config: ${HINDSIGHT_AWS_SRC} copied to ${HINDSIGHT_AWS_DST} for the memory API (${FILES} file(s), mode 0700/0600)"
