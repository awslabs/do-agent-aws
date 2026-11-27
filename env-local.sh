#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Your settings file, .env.local (docs/manual/install.md "Settings"). ./run.sh and ./build.sh run this before they read .env.
#
# .env is tracked and holds every setting with its default; .env.local beside it is gitignored and holds the ones you
# change, as export NAME=value lines that .env reads after its defaults. So git pull never stops on your edits and
# still brings every new default. This script:
#   - with no .env.local yet: creates it, a few commented lines with the settings people change most and their
#     defaults from .env, and says so in one line;
#   - once, on the run that would create .env.local, when the tracked .env itself was edited in settings only (the
#     layout before .env.local): moves the edited and added NAME=value lines into the new .env.local, keeps the edited
#     file as .env.edited-<UTC time>, and restores the tracked .env (git checkout), so the next git pull goes through.
#     It changes nothing, and prints the lines it would move for you to merge by hand, when .env.local already exists
#     or when the edit changes more than settings (a line that is not NAME=value, a comment or blank: work on the
#     defaults themselves);
#   - otherwise says nothing.
# Exit status 0 always: a start or a build never stops here. Outside a git checkout, or without git, the second step
# is skipped. ENV_LOCAL_SETUP=false skips both (a test that runs ./build.sh in the checkout leaves your settings be).

[ "${ENV_LOCAL_SETUP}" == "false" ] && exit 0
cd "$(dirname "$0")" || exit 0
LOCAL=.env.local
NOW=$(date -u +%Y%m%dT%H%M%SZ)

# the edited NAME=value lines of the tracked .env, as git diff shows them added (comments and blank lines aside)
edited_lines()
{
	git diff --no-color -U0 -- .env 2>/dev/null \
		| sed -n -E 's/^\+([[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=.*)$/\1/p'
}

# the changed lines of the tracked .env that are not settings (NAME=value), comments or blank lines
other_lines()
{
	git diff --no-color -U0 -- .env 2>/dev/null | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' \
		| grep -vE '^[-+][[:space:]]*((export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=.*|#.*)?$'
}

if command -v git > /dev/null && git rev-parse --is-inside-work-tree > /dev/null 2>&1 \
	&& git ls-files --error-unmatch .env > /dev/null 2>&1 && ! git diff --quiet -- .env 2>/dev/null; then
	MOVE=$(edited_lines)
	if [ -e "${LOCAL}" ] || [ -n "$(other_lines)" ]; then
		if [ -e "${LOCAL}" ]; then
			echo "settings: .env is edited and .env.local exists - nothing moved. Merge these lines of .env into .env.local"
		else
			echo "settings: .env is edited beyond settings ($(other_lines | grep -c .) changed line(s) that are not NAME=value) - nothing moved."
			echo "settings: If these are your settings, put them in .env.local"
		fi
		echo "settings: yourself, then restore .env with: git checkout -- .env"
		if [ -n "${MOVE}" ]; then printf '%s\n' "${MOVE}" | sed 's/^/    /'; else echo "    (no NAME=value line)"; fi
		exit 0
	fi
	cp -p .env ".env.edited-${NOW}" || { echo "settings: could not keep a copy of the edited .env - nothing moved"; exit 0; }
	{
		echo "# Your settings (docs/manual/install.md \"Settings\"), moved from your edited .env on ${NOW} by ./env-local.sh (the edited"
		echo "# file is kept as .env.edited-${NOW}). They replace the defaults in .env; this file is gitignored."
		[ -n "${MOVE}" ] && printf '%s\n' "${MOVE}"
	} > "${LOCAL}.tmp" && mv -f "${LOCAL:?}.tmp" "${LOCAL:?}" \
		&& git checkout -- .env \
		&& echo "settings: your edits to .env ($(printf '%s' "${MOVE}" | grep -c .) line(s)) moved to .env.local; .env is the tracked defaults again (the edited file: .env.edited-${NOW})"
	exit 0
fi

if [ ! -e "${LOCAL}" ]; then
	{
		echo "# Your settings (docs/manual/install.md \"Settings\"): export NAME=value lines that replace the defaults in .env, which"
		echo "# keeps every setting with its description. This file is gitignored, so git pull never stops on it. Uncomment"
		echo "# and edit a line below, or copy any other line of .env here and change it."
		for N in GIT_USER_NAME GIT_USER_EMAIL SLACK_BOT_TOKEN SLACK_CHANNELS AUTONOMY_LOOP PORT_EXTERNAL_HOME UI_PLANE AGENT_MODEL; do
			grep -m1 -E "^export ${N}=" .env | sed 's/^/#/'
		done
	} > "${LOCAL}" && echo "settings: created .env.local for your settings (gitignored; the defaults stay in .env)"
fi
exit 0
