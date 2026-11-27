#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the agent governance rules (agent-rules/AGENT_RULES.md, installed by
# setup/install-governance.sh into $CLAUDE_CONFIG_DIR).
#
# Falsifiable by design — this test FAILS if the property is removed:
#   1. the rules file is present in the Claude config dir,
#   2. CLAUDE.md references it (so every headless fire loads it),
#   3. it still carries each hard-rule heading (a gutted file fails), and rule 1 still asks for a result that is
#      checkable from the reply (the lines that carry each requirement, each affected item by name, a long list in a
#      file), matched with whitespace collapsed so a rewrap keeps the check,
#   4. it leaks NO environment-specific identifier — the file must stay generic/shippable
#      (a name, host, account id, or token shape sneaking in FAILS the test, not just review).
# No credentials or network needed; runs in the throwaway test container.

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-/home/agent/.claude}"
RULES="${CLAUDE_DIR}/AGENT_RULES.md"
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"

# 1. present
if [ ! -f "${RULES}" ]; then
	echo "Test5 FAILED: ${RULES} missing (setup/install-governance.sh did not run?)"
	exit 1
fi

# 2. referenced from CLAUDE.md
if ! grep -qF "@AGENT_RULES.md" "${CLAUDE_MD}" 2>/dev/null; then
	echo "Test5 FAILED: ${CLAUDE_MD} does not reference @AGENT_RULES.md (rules would not load per-fire)"
	exit 1
fi

# 3. still carries the hard-rule headings (guards against a gutted/replaced file)
for h in \
	"Verify before you claim" \
	"private by default" \
	"loopback-only" \
	"other people's running work" \
	"Irreversible" \
	"Commit identity" \
	"Record what you learn" ; do
	if ! grep -qF "${h}" "${RULES}"; then
		echo "Test5 FAILED: rules file is missing the hard rule: '${h}'"
		exit 1
	fi
done

# 3b. "Verify before you claim" covers the reply too: a result is checkable from the reply itself - the lines of a
# written file that carry each requirement, each affected item by name, and a long list in a file with its path, its
# count and its first entries (an agent's reply once described a NodeClass it wrote but never showed its interface
# field, and counted the manifests that would not schedule per kind, never naming them). The phrases are
# matched on the rules text with its whitespace collapsed, so rewrapping a bullet does not break the check.
FLAT=$(tr -s '[:space:]' ' ' < "${RULES}")
for p in \
	"quote the lines that carry each requirement" \
	"name each one" \
	"for a long list, write it to a file, give its path and count, and quote the first few" ; do
	case "${FLAT}" in
		*"${p}"*) ;;
		*)
			echo "Test5 FAILED: rules file no longer says a result must be checkable from the reply: '${p}'"
			exit 1
			;;
	esac
done

# 4. leaks no environment-specific identifier — must stay generic/shippable.
# A denylist of shapes/strings that must NEVER appear in a shippable rules file. If any of these
# match, the file has been contaminated with site-specific detail and must be re-scrubbed.
#   - AWS account id (12 consecutive digits)
#   - private ECR / registry host, k8s Slack channel-id shape, absolute home paths
#   - AWS long-lived key prefixes
LEAK=0
check_absent() {
	# $1 = grep -E pattern, $2 = human description
	if grep -Eiq "$1" "${RULES}"; then
		echo "Test5 FAILED: rules file leaks environment-specific content ($2) — re-scrub before shipping"
		LEAK=1
	fi
}
check_absent '[0-9]{12}'                       "12-digit account id"
check_absent 'dkr\.ecr\.|public\.ecr\.aws'     "private/public ECR registry host"
check_absent '\bAKIA[0-9A-Z]{8,}'              "AWS access-key id"
check_absent '(xoxb|xoxp)-[0-9]'               "Slack bot/user token"
check_absent '/home/[a-z]'                     "absolute home path"
check_absent '\bD0[0-9A-Z]{8,}\b'              "Slack channel/DM id"
if [ "${LEAK}" -ne 0 ]; then
	exit 1
fi

echo "Test5 succeeded"
