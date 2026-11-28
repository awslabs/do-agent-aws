# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=sh
# The credentials /agent/secrets-load.sh loaded from AWS Secrets Manager at the container's start, for a shell or script
# started with `docker exec` (it inherits the container's configured environment, not the start's): sourced by root's
# .bashrc and by the entry scripts README.md shows run that way (doctor.sh, slack-gates.sh, loop-start.sh). A no-op when
# the start loaded nothing, or for a user who cannot read the root-only file.
if [ -r "${AGENT_SECRETS_ENV_FILE:-/dev/shm/agent-secrets.env}" ]; then
	# shellcheck source=/dev/null # the file is written at run time by /agent/secrets-render.py
	. "${AGENT_SECRETS_ENV_FILE:-/dev/shm/agent-secrets.env}"
fi
