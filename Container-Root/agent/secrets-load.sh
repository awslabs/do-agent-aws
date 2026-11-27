# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=sh
# Credentials from AWS Secrets Manager (docs/manual/aws.md "Credentials from AWS Secrets Manager"). SOURCED by /startup.sh before
# anything else starts, so what it exports reaches every process the start launches - the tmux server and its panes, the
# UIs, the loop, the watchers - and the GitHub token derivation right after it. It never exits and never fails the start.
#
#   AGENT_SECRETS_ID      a secret name or ARN: ONE secret whose SecretString is a JSON object of environment variable names
#                         to values ({"SLACK_BOT_TOKEN": "...", "IMAP_PASSWORD": "..."}). Empty: nothing is fetched.
#   AGENT_SECRETS_REGION  its region (default AWS_REGION, then AWS_DEFAULT_REGION)
#   AGENT_SECRETS_NAMES   the names taken from it (default below, plus COMMS_ENV_NAMES); /agent/secrets-render.py refuses
#                         names that steer processes (PATH, LD_*, BASH_ENV ...) and the bootstrap AWS credentials
#
# The values are never printed and never written to the image, /wd or the persisted agent state: they live in this process
# tree's environment and, for `docker exec` shells and scripts (/agent/secrets-env.sh), in a root-only 0600 file on the
# container's memory-backed /dev/shm. A credential that reaches the container as an environment variable instead (a
# `docker run -e`) still works, with one WARNING line naming the variable - the documented place is the secret.
AGENT_SECRETS_ENV_FILE=${AGENT_SECRETS_ENV_FILE:-/dev/shm/agent-secrets.env}
AGENT_SECRETS_DEFAULT_NAMES="SLACK_BOT_TOKEN SLACK_APP_TOKEN GH_TOKEN GITHUB_TOKEN AWS_BEARER_TOKEN_BEDROCK HINDSIGHT_API_LLM_API_KEY TMUX_AGENT_SRC TELEGRAM_BOT_TOKEN IMAP_HOST IMAP_USERNAME IMAP_PASSWORD"

agent_secrets_load()
{
	# the allowlist, checked by the renderer (one rule set: names that steer processes are refused there, with a line each)
	# shellcheck disable=SC2086 # names are words, split on purpose
	_as_names=$(python3 -I "${AGENT_DIR:-/agent}/secrets-render.py" --names ${AGENT_SECRETS_NAMES:-${AGENT_SECRETS_DEFAULT_NAMES}} ${COMMS_ENV_NAMES:-})
	# which CREDENTIALS the container environment already carries (names only), for the warnings below: a secret-named
	# variable (the board mirror's rule: TOKEN, SECRET, PASSWORD, PASSWD, PRIVATE_KEY, API_KEY, ACCESS_KEY, CREDENTIAL) or a
	# source URL with a user part (a token URL); a plain setting the secret may also hold (IMAP_HOST, a channel list, the
	# public TMUX_AGENT_SRC) is no credential to warn about
	_as_from_env=""
	for _as_n in ${_as_names}; do
		eval "_as_v=\${${_as_n}:-}"
		[ -n "${_as_v}" ] || continue
		case "${_as_n}" in
		*TOKEN* | *SECRET* | *PASSWORD* | *PASSWD* | *PRIVATE_KEY* | *API_KEY* | *APIKEY* | *ACCESS_KEY* | *CREDENTIAL*) ;;
		*) case "${_as_v}" in *://*@*) ;; *) continue ;; esac ;;
		esac
		_as_from_env="${_as_from_env} ${_as_n}"
	done
	_as_v=""
	rm -f "${AGENT_SECRETS_ENV_FILE}" 2> /dev/null
	if [ -z "${AGENT_SECRETS_ID:-}" ]; then
		for _as_n in ${_as_from_env}; do
			echo "WARNING: secrets: ${_as_n} comes from the container environment; keep it in AWS Secrets Manager and set AGENT_SECRETS_ID (docs/manual/aws.md \"Credentials from AWS Secrets Manager\")" >&2
		done
		return 0
	fi
	_as_region=${AGENT_SECRETS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}
	_as_err=$(mktemp) || { echo "ERROR: secrets: no temporary file for the AWS CLI's errors; nothing loaded" >&2; return 0; }
	# the SecretString stays in this shell's memory; printf is a builtin, so the value is on no command line
	_as_json=$(aws secretsmanager get-secret-value --secret-id "${AGENT_SECRETS_ID}" ${_as_region:+--region "${_as_region}"} \
		--query SecretString --output text --cli-connect-timeout 5 --cli-read-timeout 20 2> "${_as_err}")
	_as_rc=$?
	if [ "${_as_rc}" -ne 0 ]; then
		echo "ERROR: secrets: AGENT_SECRETS_ID is set, but the secret could not be read (aws exit ${_as_rc}): $(grep -v '^$' "${_as_err}" | head -1)" >&2
		echo "ERROR: secrets: the start goes on without it; what needs those credentials reports them missing" >&2
		rm -f "${_as_err}"
		_as_json=""
		return 0
	fi
	rm -f "${_as_err}"
	# shellcheck disable=SC2086 # the names are validated words, split on purpose
	_as_exports=$(printf '%s' "${_as_json}" | (umask 077 && python3 -I "${AGENT_DIR:-/agent}/secrets-render.py" --env-file "${AGENT_SECRETS_ENV_FILE}" ${_as_names}))
	_as_json=""
	eval "${_as_exports}"
	for _as_n in ${_as_from_env}; do
		case "${_as_exports}" in
		*"export ${_as_n}="*) echo "secrets: ${_as_n} from AWS Secrets Manager replaces the container environment's value" >&2 ;;
		*) echo "WARNING: secrets: ${_as_n} comes from the container environment, not the secret; add it to ${AGENT_SECRETS_ID}" >&2 ;;
		esac
	done
	_as_exports=""
	return 0
}

agent_secrets_load
unset _as_names _as_from_env _as_n _as_v _as_region _as_err _as_json _as_rc _as_exports
