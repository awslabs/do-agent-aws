#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The agent's git identity. GIT_USER_NAME and GIT_USER_EMAIL from .env become the container's git
# configuration (user.name, user.email, git config --global) at every start, so a commit the agent makes in a
# repository carries the operator's identity. Without them the agent must not commit as anyone: user.useConfigOnly
# keeps git from guessing an identity from the host name, no placeholder author is ever written, and the commit
# stops with one line naming the two variables. git itself would stop with "Author identity unknown" and its own
# advice (set user.email ...), before any hook runs - so the line comes from a thin wrapper installed ahead of the
# system git on PATH: on `git commit` it resolves the identity the way git does (git var GIT_AUTHOR_IDENT and
# GIT_COMMITTER_IDENT: the environment, the repository's and the global configuration) and refuses with the harness's
# line when there is none; every other invocation, and a commit with an identity, is the system git untouched. Two
# commits of the agent runner (vibe-kanban, whose process runs git itself) are refused too: its automatic commit of what
# a coding agent left uncommitted, with the agent's last reply as the message, unless VK_RUNNER_AUTO_COMMIT=true (its
# squash merge passes), and any commit under its placeholder author, which it writes into a repository's configuration
# when no identity is set (/test-runner-auto-commit.sh).
# Idempotent; prints one line saying what the identity is, or that there is none.
# Environment: GIT_USER_NAME, GIT_USER_EMAIL; HOME (whose .gitconfig is written); GIT_WRAPPER_DIR (where the wrapper
# goes, default /usr/local/bin - ahead of /usr/bin on PATH); GIT_REAL (the system git, default /usr/bin/git).
set -u
WRAP_DIR=${GIT_WRAPPER_DIR:-/usr/local/bin}
REAL=${GIT_REAL:-/usr/bin/git}
NAME=${GIT_USER_NAME:-}
EMAIL=${GIT_USER_EMAIL:-}

"${REAL}" config --global user.useConfigOnly true
if [ -n "${NAME}" ] && [ -n "${EMAIL}" ]; then
	"${REAL}" config --global user.name "${NAME}"
	"${REAL}" config --global user.email "${EMAIL}"
	echo "git identity: ${NAME} <${EMAIL}> (GIT_USER_NAME, GIT_USER_EMAIL)"
else
	"${REAL}" config --global --unset user.name 2>/dev/null
	"${REAL}" config --global --unset user.email 2>/dev/null
	echo "git identity: none - set GIT_USER_NAME and GIT_USER_EMAIL in .env.local; until then a commit in this container is refused with that message, and no placeholder author is written"
fi

# the wrapper, written only when it differs (an atomic replace)
mkdir -p "${WRAP_DIR}"
WRAPPER=$(cat << EOW
#!/bin/bash
# do-agent-aws: git with the harness's identity check (/agent/git-identity.sh; docs/manual/install.md "Git identity"). A commit without
# a configured identity stops here with one line naming the .env variables - instead of git's "Author identity unknown"
# or a guessed root@host author; everything else, and a commit with an identity, is the system git untouched.
REAL=${REAL}
PRE=(); SUB=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) PRE+=("\$1" "\$2"); shift 2; continue ;;
		-*) PRE+=("\$1"); shift; continue ;;
		*) SUB=\$1; break ;;
	esac
done
if [ "\${SUB}" == "commit" ]; then
	if ! "\${REAL}" "\${PRE[@]}" var GIT_AUTHOR_IDENT > /dev/null 2>&1 || ! "\${REAL}" "\${PRE[@]}" var GIT_COMMITTER_IDENT > /dev/null 2>&1; then
		echo "ERROR: no git identity in this container - set GIT_USER_NAME and GIT_USER_EMAIL in .env.local (they become git config user.name and user.email at the container's start); nothing was committed" >&2
		exit 128
	fi
	# the agent runner's automatic commit (the runner process runs git itself): what a coding agent left uncommitted
	# would be committed with the agent's last reply as the message, so it is off unless VK_RUNNER_AUTO_COMMIT=true; the
	# runner's squash merge (its Merge action, git's SQUASH_MSG present) is the user's own and passes
	# (no line continuation in this template: bash before 5.2 drops the newline of a backslash-newline here)
	if [ "\$(cat /proc/\${PPID}/comm 2>/dev/null)" == "vibe-kanban" ] && [ "\${VK_RUNNER_AUTO_COMMIT:-false}" != "true" ]; then
		if [ ! -f "\$("\${REAL}" "\${PRE[@]}" rev-parse --absolute-git-dir 2>/dev/null)/SQUASH_MSG" ]; then
			echo "ERROR: the agent runner's automatic commit is off (VK_RUNNER_AUTO_COMMIT, docs/manual/install.md \"Git identity\"): the changes stay in the workspace for the agent or you to commit; nothing was committed" >&2
			exit 1
		fi
	fi
	# the agent runner's placeholder author: before its own commit the runner writes it into a repository's configuration
	# when no identity is set, and every later commit there would carry it
	case "\$("\${REAL}" "\${PRE[@]}" var GIT_AUTHOR_IDENT 2>/dev/null)" in
		"Vibe Kanban <noreply@vibekanban.com> "*)
			echo "ERROR: the identity here is the agent runner's placeholder (Vibe Kanban <noreply@vibekanban.com>, in this repository's configuration) - remove it (git config --unset user.name and git config --unset user.email in the repository) and set GIT_USER_NAME and GIT_USER_EMAIL in .env.local; nothing was committed" >&2
			exit 128 ;;
	esac
fi
exec "\${REAL}" "\${PRE[@]}" "\$@"
EOW
)
if [ ! -f "${WRAP_DIR}/git" ] || [ "$(cat "${WRAP_DIR}/git")" != "${WRAPPER}" ]; then
	printf '%s\n' "${WRAPPER}" > "${WRAP_DIR}/git.tmp" && chmod 755 "${WRAP_DIR}/git.tmp" && mv "${WRAP_DIR:?}/git.tmp" "${WRAP_DIR:?}/git"
fi
