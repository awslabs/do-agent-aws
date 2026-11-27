#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# /agent/learn.sh '<json>'  (or the JSON on stdin)  [--force] [--dry-run]
#
# Bank one VERIFIED learning - a positive (do this, it worked) or a negative (a dead end, a trap) - into the
# LogLearner global knowledge bank, the one the PreToolUse hook delivers from, /agent/recall.sh searches and the
# Learned rules tile counts. A thin wrapper over the runtime's sanctioned write path,
# `python3 -m loglearner.cli bank` (/opt/loglearner/AGENT-USAGE.md): its schema gate (rule, evidence,
# confidence high|med|low, source, provenance, status positive|negative; optional title, category, tags,
# corrects, ...), its echo of the nearest existing records, duplicate and near-duplicate refusal, a stable
# kb-NNNN id and an append. --force banks a near-duplicate that is genuinely a different rule (never an exact
# one); --dry-run checks without writing.
#
# One harness gate runs first, because the bank is injected into later sessions and shown on the dashboard:
# a record carrying credential-shaped text (an access key id, a secret key, a Slack or GitHub token, a private
# key, a bearer token, a password assignment) is refused before the runtime sees it.
#
# Exit 0 banked; 2 refused by a gate (schema or credential), the reasons printed; 3 duplicate or near-duplicate
# (bank a correction with "corrects" instead, or --force); 2 also on a usage error.

# shellcheck source=loglearner-env.sh
. "$(dirname "$0")/loglearner-env.sh"

OPTS=(); ENTRY=""
for A in "$@"; do
	case "${A}" in
	--force|--dry-run) OPTS+=("${A}") ;;
	-h|--help) sed -n '5,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) echo "learn: unknown option ${A} (learn.sh '<json>' [--force] [--dry-run])" >&2; exit 2 ;;
	*) [ -z "${ENTRY}" ] || { echo "learn: give ONE JSON entry" >&2; exit 2; }; ENTRY=${A} ;;
	esac
done
if [ -z "${ENTRY}" ] && [ ! -t 0 ]; then
	ENTRY=$(cat)
fi
[ -n "${ENTRY//[[:space:]]/}" ] || { echo "learn: no entry - give the JSON as the argument or on stdin (learn.sh --help)" >&2; exit 2; }

printf '%s' "${ENTRY}" | python3 -c '
import re, sys
text = sys.stdin.read()
SHAPES = [
    ("an AWS access key id", r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    ("an AWS secret access key", r"(?i)aws_secret_access_key\W{1,4}[A-Za-z0-9/+=]{30,}"),
    ("a Slack token", r"\bxox[abposr]-[0-9A-Za-z-]{10,}"),
    ("a GitHub token", r"\b(?:ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{30,}|\bgithub_pat_[0-9A-Za-z_]{40,}"),
    ("a private key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("a bearer token", r"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{24,}"),
    ("a password", r"(?i)\b(?:password|passwd|pwd)\b\W{1,4}[^\s\"]{6,}"),
]
for name, pat in SHAPES:
    if re.search(pat, text):
        print(f"bank refused: the entry contains {name} (the value is not shown) - bank the lesson without it; nothing was written", file=sys.stderr)
        sys.exit(2)
' || exit 2

printf '%s' "${ENTRY}" | ( cd "${LOGLEARNER_DIR}" && exec python3 -m loglearner.cli bank --stdin "${OPTS[@]}" )
