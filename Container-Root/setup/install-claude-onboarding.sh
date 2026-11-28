#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Seeding Claude Code's first-run answers ..."

# A fresh agent state is seeded from the image's Claude Code configuration, and on a fresh state the agent's tmux pane
# (the browser terminal /tmux/, the chat page, `docker exec` shells) stopped at Claude Code's first-run screens - the
# theme picker, the security notes, the trust dialog - where three Enters exit claude to the bare shell. The image's
# .claude.json gets the answers here (/agent/claude-settings-sync.sh, /agent/claude-onboarding.py), and the build fails
# without them. python3 comes from setup/install-comms.sh, which runs before this step.
command -v python3 > /dev/null 2>&1 || { echo "install-claude-onboarding.sh: python3 not found (setup/install-comms.sh installs it; run that first)"; exit 1; }
/agent/claude-settings-sync.sh
python3 /agent/claude-onboarding.py --check \
	|| { echo "install-claude-onboarding.sh: Claude Code's first-run answers are not in the image's .claude.json"; exit 1; }
echo "install-claude-onboarding.sh: the image's .claude.json carries Claude Code's first-run answers"
