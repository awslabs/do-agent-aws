#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The browser terminal's command: which tmux session of THIS container the browser attaches to. ui-start.sh starts
# the terminal's ttyd (/tmux/) with --url-arg and this script, so the browser can name a session in the page URL
# (/tmux/?arg=<session>); ttyd hands each arg= to this script as one argument word - nothing is evaluated.
#   (no argument)   attach-or-create the agent's session (AGENT_TMUX_SESSION_NAME, default agent) - as before
#   <session>       attach to the session of exactly that name, when it exists
#   pick            the session menu: the numbered list of the sessions that exist; a choice attaches to it
#   anything else   the same menu, after saying honestly why nothing was attached: no session of that name, or not a
#                   session name at all (one word of letters, digits, dot, underscore and hyphen, 64 at most, not
#                   starting with a hyphen or dot - so an argument can never select a socket, a server or a path)
# The list and every attach use the container's own tmux server: this user's default socket. The arguments are only
# ever compared with that server's session names; TMUX is unset so a nested call cannot redirect it.
# Inside any session, tmux's own prefix + s chooses another one.

unset TMUX
DEFAULT=${AGENT_TMUX_SESSION_NAME:-agent}
NAME_RX='^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$'

menu()
{
	# menu [<why nothing was attached>]
	[ -n "${1:-}" ] && printf '%s\n\n' "$1"
	mapfile -t SESSIONS < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
	if [ "${#SESSIONS[@]}" -eq 0 ]; then
		printf 'No tmux session exists in this container yet. Press Enter to start the agent session (%s).\n' "${DEFAULT}"
		read -r _ || exit 0
		exec tmux new-session -A -s "${DEFAULT}"
	fi
	echo "tmux sessions in this container:"
	for i in "${!SESSIONS[@]}"; do
		printf '  %d) %s\n' "$((i + 1))" "${SESSIONS[$i]}"
	done
	while true; do
		printf 'Attach to session number (1-%d): ' "${#SESSIONS[@]}"
		read -r CHOICE || exit 0
		if [[ "${CHOICE}" =~ ^[0-9]+$ ]] && [ "${CHOICE}" -ge 1 ] && [ "${CHOICE}" -le "${#SESSIONS[@]}" ]; then
			exec tmux attach-session -t "=${SESSIONS[$((CHOICE - 1))]}"
		fi
		echo "Not a number from the list."
	done
}

if [ "$#" -eq 0 ]; then
	exec tmux new-session -A -s "${DEFAULT}"
fi
if [ "$#" -gt 1 ]; then
	menu "Not attached: the terminal takes one session name, it was given $#."
fi
if [ "$1" == "pick" ]; then
	menu ""
fi
# the argument as it may be shown in the terminal: printable name characters only, the rest '?', 64 at most
SHOWN=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._ =/-' '?' | cut -c1-64)
if ! [[ "$1" =~ ${NAME_RX} ]]; then
	menu "Not attached: '${SHOWN}' is not a tmux session name (one word of letters, digits, dot, underscore and hyphen; no socket, server or path can be chosen here)."
fi
if tmux has-session -t "=$1" 2>/dev/null; then
	exec tmux attach-session -t "=$1"
fi
menu "Not attached: there is no tmux session named '${SHOWN}' in this container."
