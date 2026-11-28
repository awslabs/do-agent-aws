#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the credentials loader (/agent/secrets-load.sh with /agent/secrets-render.py and /agent/secrets-env.sh,
# docs/manual/aws.md "Credentials from AWS Secrets Manager"). Offline: the aws CLI is a stub on PATH that records its arguments and
# answers with a planted secret, so no AWS call is made. Each check FAILS on the behaviour it guards:
#   1. AGENT_SECRETS_ID unset: nothing fetched, a credential from the container environment is named in a WARNING line
#   2. the secret's allowed names are exported with their exact values (quotes, dollars, backticks, newlines survive)
#   3. names that steer processes (PATH, LD_PRELOAD) are never taken, even when listed; unlisted keys are only counted
#   4. a value from the secret replaces the environment's, and the line says so (by name)
#   5. no value appears in anything the start prints, nor on the aws command line
#   6. the docker exec file is 0600 and sourcing /agent/secrets-env.sh in a fresh shell restores the same values
#   7. a failing read (AccessDenied) is one ERROR line, the start goes on, nothing is exported and no file is left
#   8. a secret that is not a JSON object loads nothing
# Runs in the container (./test.sh) or on a host with python3: AGENT_DIR defaults to this checkout's agent/ when /agent is absent.

HERE=$(cd "$(dirname "$0")" && pwd)
AGENT_DIR=${AGENT_DIR:-/agent}
[ -f "${AGENT_DIR}/secrets-load.sh" ] || AGENT_DIR=${HERE}/agent
export AGENT_DIR
fail() { echo "Test-secrets-load FAILED: $*"; exit 1; }
D=$(mktemp -d)
trap 'rm -f "${D}"/stub/aws "${D}"/*.txt "${D}"/*.json "${D}"/agent-secrets.env; rmdir "${D}/stub" "${D}" 2>/dev/null' EXIT
mkdir -p "${D}/stub"
# the stub aws: records argv, answers with the planted secret file, or fails like the CLI on AccessDenied
cat > "${D}/stub/aws" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LOG}"
if [ -n "${STUB_FAIL}" ]; then
	echo "An error occurred (AccessDeniedException) when calling the GetSecretValue operation: not authorized" >&2
	exit 254
fi
cat "${STUB_SECRET}"
EOF
chmod +x "${D}/stub/aws"
V_SLACK='xb-from-secret-0123'
V_IMAP="p'a\"s\$s \`w\`
second line"
python3 - "${D}/secret.json" "${V_SLACK}" "${V_IMAP}" << 'PY'
import json, sys
json.dump({"SLACK_BOT_TOKEN": sys.argv[2], "IMAP_PASSWORD": sys.argv[3], "PATH": "/planted/bin",
           "LD_PRELOAD": "/planted.so", "UNLISTED_EXTRA": "zzz-unlisted-zzz"}, open(sys.argv[1], "w"))
PY
# one start: sources the loader in a fresh POSIX sh and prints the resulting values as JSON (the test's own channel)
start() {
	env -i PATH="${D}/stub:/usr/bin:/bin:/usr/local/bin" HOME="${D}" AGENT_DIR="${AGENT_DIR}" STUB_LOG="${D}/argv.txt" \
		STUB_SECRET="${STUB_SECRET:-${D}/secret.json}" ${STUB_FAIL:+STUB_FAIL=1} AGENT_SECRETS_ENV_FILE="${D}/agent-secrets.env" "$@" \
		sh -c '. "${AGENT_DIR}/secrets-load.sh"; python3 -c "import json, os; print(json.dumps({k: os.environ.get(k) for k in (\"SLACK_BOT_TOKEN\", \"IMAP_PASSWORD\", \"PATH\", \"LD_PRELOAD\", \"UNLISTED_EXTRA\")}))" > "'"${D}"'/values.json"' \
		> "${D}/out.txt" 2>&1
}
val() { python3 -c "import json, sys; v = json.load(open(sys.argv[1])).get(sys.argv[2]); print('' if v is None else v, end='')" "${D}/values.json" "$1"; }

# 1. unset: nothing fetched; the environment's credential is warned about by name
: > "${D}/argv.txt"
start SLACK_BOT_TOKEN=env-value-1 || fail "the loader failed the start with AGENT_SECRETS_ID unset"
[ -s "${D}/argv.txt" ] && fail "aws was called with AGENT_SECRETS_ID unset"
grep -q 'WARNING: secrets: SLACK_BOT_TOKEN comes from the container environment' "${D}/out.txt" || fail "no WARNING named SLACK_BOT_TOKEN from the environment: $(cat "${D}/out.txt")"
[ "$(val SLACK_BOT_TOKEN)" == "env-value-1" ] || fail "the environment's value did not survive with AGENT_SECRETS_ID unset"
[ -e "${D}/agent-secrets.env" ] && fail "an exec file was written with AGENT_SECRETS_ID unset"
# a plain setting the secret may also hold, and the public source URL, are no credentials to warn about; a token URL is
start IMAP_HOST=imap.example.com TMUX_AGENT_SRC=https://github.com/example/public.git || fail "the loader failed the start"
grep -q "WARNING" "${D}/out.txt" && fail "a plain setting or a public URL was warned about: $(cat "${D}/out.txt")"
start TMUX_AGENT_SRC=https://x-access:tok3n@github.example.com/private.git || fail "the loader failed the start"
grep -q "WARNING: secrets: TMUX_AGENT_SRC comes from the container environment" "${D}/out.txt" || fail "a token URL was not warned about"
grep -qF "tok3n" "${D}/out.txt" && fail "the token URL was printed"
echo "ok 1 - unset: no fetch, a credential from the environment named in a WARNING; a plain setting or a public URL is not"

# 2.-6. a secret read
: > "${D}/argv.txt"
start AGENT_SECRETS_ID=do-agent-aws/credentials AGENT_SECRETS_REGION=us-east-1 SLACK_BOT_TOKEN=env-value-2 \
	AGENT_SECRETS_NAMES="SLACK_BOT_TOKEN IMAP_PASSWORD PATH LD_PRELOAD 9BAD A-B" || fail "the loader failed the start on a good secret"
[ "$(val SLACK_BOT_TOKEN)" == "${V_SLACK}" ] || fail "SLACK_BOT_TOKEN is not the secret's value"
[ "$(val IMAP_PASSWORD)" == "${V_IMAP}" ] || fail "IMAP_PASSWORD lost its quotes, dollar, backticks or newline"
echo "ok 2 - allowed names exported with their exact values"
[ "$(val PATH)" == "/planted/bin" ] && fail "the secret set PATH"
[ -n "$(val LD_PRELOAD)" ] && fail "the secret set LD_PRELOAD"
[ -n "$(val UNLISTED_EXTRA)" ] && fail "an unlisted key was exported"
grep -q 'PATH is never taken from the secret' "${D}/out.txt" && grep -q 'LD_PRELOAD is never taken from the secret' "${D}/out.txt" \
	|| fail "PATH / LD_PRELOAD were not refused by name: $(cat "${D}/out.txt")"
grep -q "'9BAD'\|9BAD is never taken" "${D}/out.txt" || fail "the malformed name 9BAD was not refused"
grep -q 'key(s) in the secret not in AGENT_SECRETS_NAMES, ignored' "${D}/out.txt" || fail "the unlisted keys were not counted"
echo "ok 3 - PATH and LD_PRELOAD refused, malformed names refused, unlisted keys only counted"
grep -q 'SLACK_BOT_TOKEN from AWS Secrets Manager replaces the container environment' "${D}/out.txt" || fail "no line named the replaced SLACK_BOT_TOKEN"
echo "ok 4 - the secret's value replaces the environment's, said by name"
for V in "${V_SLACK}" "second line" "zzz-unlisted-zzz" "/planted.so"; do
	grep -qF -- "${V}" "${D}/out.txt" && fail "a value was printed by the start: ${V}"
	grep -qF -- "${V}" "${D}/argv.txt" && fail "a value reached the aws command line"
done
grep -q -- '--secret-id do-agent-aws/credentials --region us-east-1 --query SecretString --output text' "${D}/argv.txt" \
	|| fail "unexpected aws arguments: $(cat "${D}/argv.txt")"
echo "ok 5 - no value printed, none on the aws command line"
[ "$(stat -c '%a' "${D}/agent-secrets.env" 2>/dev/null || stat -f '%Lp' "${D}/agent-secrets.env")" == "600" ] || fail "the exec file is not 0600"
OUT=$(env -i PATH=/usr/bin:/bin AGENT_DIR="${AGENT_DIR}" AGENT_SECRETS_ENV_FILE="${D}/agent-secrets.env" \
	sh -c '. "${AGENT_DIR}/secrets-env.sh"; printf "%s" "${IMAP_PASSWORD}"')
[ "${OUT}" == "${V_IMAP}" ] || fail "secrets-env.sh did not restore IMAP_PASSWORD exactly"
echo "ok 6 - the exec file is 0600 and restores the same values"

# 7. a failing read
: > "${D}/argv.txt"
STUB_FAIL=1 start AGENT_SECRETS_ID=do-agent-aws/credentials || fail "a failing read failed the start"
grep -q 'ERROR: secrets: AGENT_SECRETS_ID is set, but the secret could not be read (aws exit 254): An error occurred (AccessDeniedException)' "${D}/out.txt" \
	|| fail "no ERROR line with the CLI's reason: $(cat "${D}/out.txt")"
[ -n "$(val SLACK_BOT_TOKEN)" ] && fail "a value was exported after a failed read"
[ -e "${D}/agent-secrets.env" ] && fail "an exec file was left after a failed read"
echo "ok 7 - a failed read is one ERROR line; the start goes on with nothing loaded"

# 8. not a JSON object
printf '%s' '["not", "an", "object"]' > "${D}/bad.json"
STUB_SECRET="${D}/bad.json" start AGENT_SECRETS_ID=do-agent-aws/credentials || fail "a malformed secret failed the start"
grep -q 'the secret is not a JSON object' "${D}/out.txt" || fail "a malformed secret was not reported"
[ -n "$(val SLACK_BOT_TOKEN)" ] && fail "a malformed secret exported a value"
echo "ok 8 - a secret that is not a JSON object loads nothing"

echo "Test-secrets-load PASSED"
