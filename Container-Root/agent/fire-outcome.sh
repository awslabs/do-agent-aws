#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# fire-outcome.sh <fire output file> <claude exit status> - the OUTCOME of one autonomy-loop fire, one line:
#   ok                               claude exited 0 and reported no API error
#   no-credentials <complaint>       claude's own API error line: it could not load AWS credentials
#   invalid-credentials <complaint>  ... the security token is expired or invalid (a wrong or stale key)
#   no-access <complaint>            ... denied or not authorized (model access, the IAM policy)
#   api-error <complaint>            any other API error line claude reported
#   timeout exit status <n>          the fire hit AUTONOMY_LOOP_FIRE_TIMEOUT (124; 137 when killed after the grace
#                                    period) and claude reported nothing: credentials that never answer look like
#                                    this - an IMDS endpoint that does not respond, static keys that fail silently
#   error exit status <n>            claude exited non-zero and reported no API error
#   ... ignored-rule "<rule>"        appended to ok, timeout or error when the transcript holds claude's own line
#                                    `Ignoring --allowedTools rule "<rule>": ...` - an allow rule of the fire's options the
#                                    client refused (a wildcard or a slash in the tool name: what a rule with a space
#                                    becomes when it is split), so the fire ran WITHOUT it, every call it would have
#                                    allowed denied; the exit status is unchanged (a completed fire did its work). The
#                                    backstop for what /agent/claude-opts.sh's check, run before the fire, does not see
# Why: `claude -p` CAN exit 0 when it cannot load AWS credentials - it prints an "API Error: Could not load AWS
# credentials" line instead of working - so a fire that did nothing would be recorded as a success from its exit
# status alone. Only claude's own report is classified: the first line beginning "API Error" (a working fire prints
# the answer alone; an older CLI printed the bare "Could not load AWS credentials" line, read the same way). The
# answer itself is never classified, so a fire whose answer discusses an AccessDenied stays ok. loop.sh and
# loop-once.sh log this word with the fire's END line, record it in the loop state, and give such a fire the exit
# status 97 when claude's own was 0. The complaint is clipped to 120 characters with 12-digit numbers masked (a
# resource name in a denial carries the account id). Exit status is always 0.
OUT=$1
RC=$2
[ -f "${OUT}" ] || { echo "error no fire output at ${OUT}"; exit 0; }
LINE=$(grep -m1 -E '^(API Error|Could not load AWS credentials)' "${OUT}")
if [ -n "${LINE}" ]; then
	COMPLAINT=$(printf '%s' "${LINE}" | sed -E 's/^API Error:? *//; s/[0-9]{12}/<account>/g' | cut -c1-120)
	case "${LINE,,}" in
		*"could not load aws credentials"*|*"could not load credentials"*) echo "no-credentials ${COMPLAINT}" ;;
		*"token included in the request is "*|*expiredtoken*|*invalidclienttokenid*|*unrecognizedclient*|*"invalid security token"*) echo "invalid-credentials ${COMPLAINT}" ;;
		*"access denied"*|*accessdenied*|*"not authorized"*|*"have access to the model"*) echo "no-access ${COMPLAINT}" ;;
		*) echo "api-error ${COMPLAINT}" ;;
	esac
	exit 0
fi
# claude's own refusal of an allow rule, printed at the top of the transcript before the fire ran on without the rule:
# named after the outcome's word, so a completed fire stays ok (its exit status unchanged) and a timed-out one timeout
IGNORED=$(sed -n 's/^Ignoring --allowedTools rule "\(.*\)": .*/\1/p' "${OUT}" | head -1 | tr -d '\n\r' | tr '\t' ' ' | cut -c1-120)
case "${RC}" in
	0) OUTCOME="ok" ;;
	124|137) OUTCOME="timeout exit status ${RC}" ;;
	*) OUTCOME="error exit status ${RC}" ;;
esac
[ -z "${IGNORED}" ] || OUTCOME="${OUTCOME} ignored-rule \"${IGNORED}\""
echo "${OUTCOME}"
