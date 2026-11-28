#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# LogLearner - the PreToolUse hook command Claude Code runs before every Edit, Write and Bash tool call in
# the container (registered in its settings.json by /agent/loglearner-settings.py; LOGLEARNER_HOOK in .env).
#
# It hands the tool call (JSON on stdin) to the runtime's own hook,
# /opt/loglearner/scripts/hooks/pretooluse-instinct-context.py, which matches it against the global knowledge
# bank (the seed packs /agent/loglearner-packs.sh ingests, and everything /agent/learn.sh banks) - an edited
# file by its path tokens (a Dockerfile or *.sh to aws/docker/git rules, a *.tf, *.yaml or eksctl file to
# aws/eks/ec2/kubernetes rules), a Bash command by its program names (docker, kubectl, aws <service>, git,
# pip, ...), and snake_case identifiers in the text written or the command to any rule naming them - and
# answers with at most one JSON object whose additionalContext carries the matching rules into the model's
# context, recording each delivery (session, rule) in the exposure ledger the Learned rules tile counts. Rules
# already delivered to the session within 30 minutes are withheld; a call nothing matches gets nothing.
#
# Tool calls never fail because of this hook: it always exits 0 (Claude Code blocks a tool call only on
# exit 2), writes nothing to stdout but the runtime hook's own JSON, and gives up after 9 s, inside the
# timeout of 10 s its settings entry declares. LOGLEARNER_HOOK=false in the environment turns it into a
# no-op even where an entry is still registered (the next container start removes the entry).

[ "${LOGLEARNER_HOOK:-true}" = "true" ] || exit 0
# shellcheck source=loglearner-env.sh
. "$(dirname "$0")/loglearner-env.sh" 2> /dev/null || exit 0
HOOK=${LOGLEARNER_DIR}/scripts/hooks/pretooluse-instinct-context.py
[ -f "${HOOK}" ] || exit 0
timeout 9 python3 "${HOOK}"
exit 0
