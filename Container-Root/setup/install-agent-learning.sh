#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing the agent's learning tools (the LogLearner PreToolUse hook, recall.sh, learn.sh) ..."

# The container agent's side of the LogLearner (the runtime itself is vendored by setup/install-loglearner.sh,
# which must run first): the PreToolUse hook entry in the image's Claude Code settings, so a fresh agent state
# carries it, and the command-line tools the agent calls. All of it is in /agent (Container-Root/agent):
#   loglearner-hook.sh       the hook command - fail-open, always exit 0, bounded to 9 s
#   loglearner-settings.py   adds/removes only that hook entry in settings.json (merge-safe)
#   claude-settings-sync.sh  runs that (and the other config steps) here and at every container start
#   loglearner-packs.sh      loads the /seed banks into the runtime's global bank at every start
#   recall.sh                searches the banks (the runtime's `loglearner.cli recall`) and Hindsight
#                            (hindsight-recall.py) before a risky step
#   learn.sh                 banks a verified learning through the runtime's `loglearner.cli bank`
#   claude-onboarding.py     Claude Code's first-run answers, so the agent's tmux pane opens at the prompt
#   claude-statusline.sh     the agent's status line with its context %, which the tmux-agent dashboard reads
#   tmux-agent-lexicon.json  the dashboard's profile for the agent's claude pane (ui-start.sh passes it)
#   knowledge-files.py       the default knowledge where a headless fire reads it: the /wd copy (at start), the skill
#                            and the CLAUDE.md section (here too, so a fresh agent state carries them)
# The bank itself lives on the /wd volume, so it is filled at start, not here.

fail()
{
	echo "ERROR: install-agent-learning.sh: $1" >&2
	exit 1
}

command -v python3 > /dev/null 2>&1 || fail "python3 not found (setup/install-comms.sh installs it; run that first)"
for F in loglearner-hook.sh loglearner-env.sh loglearner-settings.py claude-settings-sync.sh loglearner-packs.sh \
	recall.sh hindsight-recall.py learn.sh claude-onboarding.py claude-statusline.sh tmux-agent-lexicon.json knowledge-files.py; do
	[ -f "/agent/${F}" ] || fail "/agent/${F} is missing from the image (Container-Root/agent)"
done
for F in loglearner-hook.sh claude-settings-sync.sh loglearner-packs.sh recall.sh hindsight-recall.py learn.sh \
	claude-statusline.sh; do
	[ -x "/agent/${F}" ] || fail "/agent/${F} is not executable"
done

/agent/claude-settings-sync.sh
# with LOGLEARNER_HOOK unset (true) the image default must carry the entry - fail the build otherwise
python3 /agent/loglearner-settings.py status || fail "the LogLearner hook is not registered in the image's settings.json"
# ...and the first-run answers, so a fresh agent state (seeded from the image) opens the pane at the prompt
python3 /agent/claude-onboarding.py --check || fail "Claude Code's first-run answers are not in the image's .claude.json"
# ...and, with AGENT_KNOWLEDGE unset (true), the skill and the CLAUDE.md section of the default knowledge
{ [ -s "${CLAUDE_CONFIG_DIR:-/home/agent/.claude}/skills/aws-defaults-knowledge/SKILL.md" ] \
	&& grep -qxF "<!-- do-agent-aws default knowledge: begin -->" "${CLAUDE_CONFIG_DIR:-/home/agent/.claude}/CLAUDE.md"; } \
	|| fail "the default knowledge's skill or CLAUDE.md section is not in the image"
echo "install-agent-learning.sh complete."
