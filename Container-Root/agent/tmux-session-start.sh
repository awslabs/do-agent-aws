#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Shared agent tmux session - create it EAGERLY at container start.
#
# startup.sh calls this script right after the UIs (the memory API among them, which the pane's
# claude waits for - see tmux-claude.sh) so that ttyd's attach-or-create
# (`tmux new-session -A -s agent`, /agent/ui-start.sh) attaches to THIS session instead of
# creating its own on the first browser connect. Before this script existed the session was
# born lazily by whichever door arrived first: `docker exec` + `tmux ls` found "no server
# running" until someone opened /tmux/ in a browser, and the two doors did not behave the
# same (docs/manual/ui.md "tmux in the browser"). It can also be re-run manually inside the
# container at any time: it is idempotent - an existing session is left untouched, attached
# clients are never disturbed.
#
# The session's single window runs /agent/tmux-claude.sh, which starts the interactive
# claude CLI and falls back to a shell when claude exits or is missing - so the session
# both doors depend on survives a `/exit`. The folder the pane starts in is trusted for
# claude first (/agent/claude-onboarding.py --dir), so the pane opens at claude's prompt
# wherever it starts, not at the trust question.
#
# Settings (all overridable via environment; declared in .env and passed through by run.sh,
# the compose template, and the kubernetes deployment):
#   AGENT_TMUX_SESSION      - create the session at container start, true|false (default true)
#   AGENT_TMUX_SESSION_NAME - session name (default agent); ttyd and the .bashrc
#                             auto-attach follow the same name
#   AGENT_TMUX_CLAUDE       - read by tmux-claude.sh: run claude in the session's pane
#                             (default true)
#   AGENT_TMUX_CLAUDE_OPTS  - read by tmux-claude.sh: extra options for the claude call
#
# With a name it starts that session of the registry instead (/agent/spokes/registry.json, the only source of what runs;
# docs/manual/agents.md "Spoke agents", docs/AGENT-STACK.md): /agent/tmux-session-start.sh <name>. /agent/supervisor.sh calls it for
# every enabled entry whose session is gone. The hub's name is the start above; a spoke or the supervisor whose entry or
# charter breaks its rules (/agent/spoke.sh check) is refused. A spoke gets, in its working directory (the entry's
# workdir, /wd/<name>):
#   repo/      its repository. A "vendored: <path>" source is a link to the tree the image ships; a URL source is
#              cloned at the entry's ref, ANONYMOUSLY - no git configuration of the container's, no credential helper,
#              no prompt, https only - so a source that needs credentials is refused; a later start refreshes a branch
#              with git pull --ff-only (a refresh that fails keeps the checkout and says so); "none" has no repo/
#   CLAUDE.md  its charter, byte for byte, at every start - so the Claude Code session started here runs with the charter
#              as its CLAUDE.md (with the agent rules every session in the image loads); the folder is trusted first
#              (/agent/claude-onboarding.py --dir), so claude opens at its prompt, not at the trust question
# and ${SUPERVISOR_DIR}/<name>/state.json records the start: when, the generation (1 at the first start, +1 at each), the
# charter's sha256, the source and the commit checked out; ${SUPERVISOR_DIR}/sessions-ledger.jsonl gets the start's line
# (/agent/session-ledger.py: the event is SESSION_LEDGER_EVENT, start by default, and the reason SESSION_LEDGER_REASON,
# which the supervisor and supervisor.sh resume set). The pane runs the entry's launch_cmd in the workdir with the
# entry's env, BUS_AGENT_ID=<name> and, for a spoke, no shell fallback: when claude exits the session ends, and the
# supervisor starts it again. The lineage is set the way the tmux-agent dashboard reads it: @agent_parent (the entry's
# parent, agent), @agent_owner do-agent-aws, @agent_task (the entry's task). An existing session is left untouched.

# No login shell here - startup.sh runs this without a TTY and without a login PATH
export HOME=${HOME:-/home/agent}
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

AGENT_TMUX_SESSION=${AGENT_TMUX_SESSION:-true}
AGENT_TMUX_SESSION_NAME=${AGENT_TMUX_SESSION_NAME:-agent}
AGENT_TMUX_CLAUDE=${AGENT_TMUX_CLAUDE:-true}
AGENT_TMUX_CLAUDE_OPTS=${AGENT_TMUX_CLAUDE_OPTS:-}

# The scripts live in /agent in-container and Container-Root/agent in a repo checkout
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -gt 0 ] && [ "$1" != "${AGENT_TMUX_SESSION_NAME}" ]; then
	SUPERVISOR_DIR=${SUPERVISOR_DIR:-/wd/supervisor}
	export SUPERVISOR_DIR
	NAME=$1
	SPOKE="${AGENT_DIR}/spoke.sh"
	if ! FINDINGS=$("${SPOKE}" check "${NAME}" 2>&1); then
		echo "spoke ${NAME}: refused - its registry entry or charter breaks its rules:"
		echo "${FINDINGS}"
		exit 1
	fi
	entry() { "${SPOKE}" entry "${NAME}" "$1"; }
	ROLE=$(entry role)
	WORKDIR=$(entry workdir)
	LAUNCH=$(entry launch_cmd)
	PARENT=$(entry parent)
	TITLE=$(entry task)
	CHARTER=$(entry charter)
	SOURCE=$(entry source)
	REF=$(entry ref)
	if ! command -v tmux > /dev/null; then
		echo "spoke ${NAME}: ERROR - tmux is not installed (setup/install-tmux.sh)"
		exit 1
	fi
	if tmux has-session -t "=${NAME}" 2>/dev/null; then
		echo "spoke ${NAME}: session '${NAME}' already exists (left untouched)"
		exit 0
	fi
	mkdir -p "${WORKDIR}" || { echo "spoke ${NAME}: ERROR - cannot create ${WORKDIR}"; exit 1; }
	REPO=${WORKDIR%/}/repo
	COMMIT=""
	case "${SOURCE}" in
		""|none)
			;;
		vendored:*)
			TREE=${SOURCE#vendored: }
			[ -d "${TREE}" ] || { echo "spoke ${NAME}: refused - the vendored tree ${TREE} is not in this image"; exit 1; }
			if [ -e "${REPO}" ] && [ ! -L "${REPO}" ]; then
				echo "spoke ${NAME}: refused - ${REPO} is not a link to the vendored tree (an earlier source's checkout?); move it away to start over"
				exit 1
			fi
			ln -sfn "${TREE}" "${REPO}" || { echo "spoke ${NAME}: ERROR - cannot link ${REPO} to ${TREE}"; exit 1; }
			;;
		*)
			# anonymous: none of the container's git configuration (credential helpers, url rewrites, extra headers),
			# no askpass, no terminal prompt, https only (redirects and submodules included)
			anon_git()
			{
				env -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_SSH_COMMAND GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null \
					GIT_CONFIG_NOSYSTEM=1 git -c protocol.allow=never -c protocol.https.allow=always \
					-c credential.helper= -c core.askPass= "$@"
			}
			if [ -d "${REPO}/.git" ]; then
				ORIGIN=$(git -C "${REPO}" remote get-url origin 2>/dev/null)
				if [ "${ORIGIN}" != "${SOURCE}" ]; then
					echo "spoke ${NAME}: refused - ${REPO} is a clone of ${ORIGIN:-an unknown source}, the registry names ${SOURCE}; move it away to start over"
					exit 1
				fi
				if git -C "${REPO}" symbolic-ref -q HEAD > /dev/null; then
					anon_git -C "${REPO}" pull --quiet --ff-only 2> "${WORKDIR}/refresh.err" \
						|| echo "spoke ${NAME}: WARNING - the refresh (git pull --ff-only) failed, starting on the checkout as it is: $(tail -1 "${WORKDIR}/refresh.err")"
				elif [ "$(git -C "${REPO}" rev-parse -q --verify "${REF}^{commit}" 2>/dev/null)" != "$(git -C "${REPO}" rev-parse HEAD)" ]; then
					{ anon_git -C "${REPO}" fetch --quiet origin "${REF}" && git -C "${REPO}" checkout --quiet --detach FETCH_HEAD; } 2> "${WORKDIR}/refresh.err" \
						|| echo "spoke ${NAME}: WARNING - could not move the checkout to ${REF}, starting on it as it is: $(tail -1 "${WORKDIR}/refresh.err")"
				fi
			else
				if [ -L "${REPO}" ]; then
					rm -f "${WORKDIR:?}/repo"
				elif [ -e "${REPO}" ]; then
					echo "spoke ${NAME}: refused - ${REPO} exists and is not a git checkout; move it away to start over"
					exit 1
				fi
				CLONED=true
				if echo "${REF}" | grep -qE '^[0-9a-f]{7,40}$'; then
					{ anon_git clone --quiet -- "${SOURCE}" "${REPO}" && git -C "${REPO}" checkout --quiet --detach "${REF}"; } 2> "${WORKDIR}/clone.err" || CLONED=false
				else
					anon_git clone --quiet --branch "${REF}" -- "${SOURCE}" "${REPO}" 2> "${WORKDIR}/clone.err" || CLONED=false
				fi
				if [ "${CLONED}" != "true" ]; then
					echo "spoke ${NAME}: refused - the anonymous clone of ${SOURCE} at ${REF} failed (a spoke's source must be public; no credentials are offered): $(tail -1 "${WORKDIR}/clone.err")"
					exit 1
				fi
			fi
			COMMIT=$(git -C "${REPO}" rev-parse HEAD 2>/dev/null)
			;;
	esac
	# the pane's settings (a pane inherits the tmux server's environment, not this caller's): the entry's env, who the
	# session is on the bus, and for a spoke claude without the shell fallback; CLAUDE_BIN only when set, so
	# tmux-claude.sh keeps its own default. They go with -e to a running server (below otherwise)
	PANE_ENV=(-e "BUS_AGENT_ID=${NAME}" -e "SUPERVISOR_DIR=${SUPERVISOR_DIR}")
	# the memory API wait of tmux-claude.sh follows this caller's settings, not the tmux server's (set ones only)
	for V in UI_START UI_HINDSIGHT UI_PORT_HINDSIGHT_API HINDSIGHT_WAIT_SECS SPOKES_REGISTRY MAILBOX_STATE_ROOT MAILBOX_PROJECTION_ROOT AGENT_TMUX_SESSION_NAME; do
		[ -n "${!V+x}" ] && PANE_ENV+=(-e "${V}=${!V}")
	done
	while IFS= read -r KV; do
		[ -n "${KV}" ] && PANE_ENV+=(-e "${KV}")
	done < <("${SPOKE}" entry "${NAME}" env | python3 -I -c 'import json, sys; [print(f"{k}={v}") for k, v in json.load(sys.stdin).items()]')
	if [ "${ROLE}" == "spoke" ]; then
		cp "${CHARTER}" "${WORKDIR%/}/CLAUDE.md" || { echo "spoke ${NAME}: ERROR - cannot write ${WORKDIR%/}/CLAUDE.md"; exit 1; }
		python3 "${AGENT_DIR}/claude-onboarding.py" --dir "${WORKDIR}" > "${WORKDIR%/}/onboarding.out" 2>&1 \
			|| echo "spoke ${NAME}: WARNING - could not mark ${WORKDIR} trusted for claude: $(tail -1 "${WORKDIR%/}/onboarding.out")"
		PANE_ENV+=(-e AGENT_TMUX_CLAUDE=true -e "AGENT_TMUX_CLAUDE_OPTS=${AGENT_TMUX_CLAUDE_OPTS}" -e AGENT_TMUX_SHELL_FALLBACK=false)
		[ -n "${CLAUDE_BIN}" ] && PANE_ENV+=(-e "CLAUDE_BIN=${CLAUDE_BIN}")
	fi
	GENERATION=$("${SPOKE}" state "${NAME}" 2>/dev/null | python3 -I -c 'import json, sys; print(int(json.load(sys.stdin).get("generation") or 0) + 1)' 2>/dev/null)
	[ -n "${GENERATION}" ] || GENERATION=1
	mkdir -p "${SUPERVISOR_DIR%/}/${NAME}" || { echo "spoke ${NAME}: ERROR - cannot create ${SUPERVISOR_DIR%/}/${NAME}"; exit 1; }
	# The session and its lineage - the session options the tmux-agent dashboard reads ("=name:" is the exact-match pane
	# target) - in ONE tmux call, and no query of the session afterwards but has-session: tmux 3.2a (this image's)
	# crashes its whole server, every session with it, when a display-message targets a session whose only pane is
	# exiting at that moment - a spoke whose claude exits at once - right after a set-option on it (5 of 5 in a loop;
	# this chained form survived 90 starts). @agent_pane records the new pane's id: fleet-check.sh and the supervisor read
	# and type into that pane only, never a window a person opens in the session
	WINDOW=claude
	[ "${ROLE}" == "spoke" ] || WINDOW=${ROLE}
	# A server this call starts keeps the call's command line for its whole life, where ps and pgrep -f see it (the
	# agent session's rule below): the settings go in the call's environment instead, which that server takes as its
	# global environment, and the same call takes them out of it again - unset, or back to this caller's own value - so
	# no later pane inherits them
	CALL_ENV=() RESTORE=()
	if ! tmux list-sessions > /dev/null 2>&1; then
		for KV in "${PANE_ENV[@]}"; do
			[ "${KV}" == "-e" ] && continue
			CALL_ENV+=("${KV}")
			K=${KV%%=*}
			if ! printenv "${K}" > /dev/null; then
				RESTORE+=(\; set-environment -g -u "${K}")
			elif [ "$(printenv "${K}")" != "${KV#*=}" ]; then
				RESTORE+=(\; set-environment -g "${K}" "$(printenv "${K}")")
			fi
		done
		PANE_ENV=()
	fi
	# the ledger's two settings are this start's alone: a server this call creates would keep them for every later pane
	NEW=$(env -u SESSION_LEDGER_EVENT -u SESSION_LEDGER_REASON "${CALL_ENV[@]}" tmux new-session -d -P -F '#{session_created} #{pane_pid}' -s "${NAME}" -n "${WINDOW}" -c "${WORKDIR}" "${PANE_ENV[@]}" "${LAUNCH}" \; \
		set-option -t "=${NAME}:" @agent_parent "${PARENT}" \; \
		set-option -t "=${NAME}:" @agent_owner do-agent-aws \; \
		set-option -t "=${NAME}:" @agent_task "${TITLE}" \; \
		set-option -F -t "=${NAME}:" @agent_pane '#{pane_id}' "${RESTORE[@]}" 2> "${SUPERVISOR_DIR%/}/${NAME}/tmux.err") \
		|| { echo "spoke ${NAME}: ERROR - could not create the tmux session '${NAME}' with its lineage: $(tail -1 "${SUPERVISOR_DIR%/}/${NAME}/tmux.err")"; exit 1; }
	read -r CREATED PANE_PID <<< "${NEW}"
	tmux has-session -t "=${NAME}" 2>/dev/null \
		|| { echo "spoke ${NAME}: ERROR - the session '${NAME}' ended right after its start (its pane: ${LAUNCH})"; exit 1; }
	CSHA=""
	[ -n "${CHARTER}" ] && CSHA=$(sha256sum < "${CHARTER}" | cut -d' ' -f1)
	"${SPOKE}" state "${NAME}" state=starting "started_at=$(date -u +%FT%TZ)" "session_created=${CREATED}" "generation=${GENERATION}" \
		"title=${TITLE}" "charter=${CHARTER}" "charter_sha256=${CSHA}" "source=${SOURCE}" "ref=${REF}" "commit=${COMMIT}" "workdir=${WORKDIR}" \
		|| echo "spoke ${NAME}: WARNING - could not record the start in ${SUPERVISOR_DIR%/}/${NAME}/state.json"
	# the session ledger's line (docs/AGENT-STACK.md "The session ledger"): the pane's pid and the session's creation time
	# from the call that created it, its directory and command as given to it - no query of the new pane, which may be
	# exiting at once
	OUT=$(python3 -I "${AGENT_DIR}/session-ledger.py" record "${SESSION_LEDGER_EVENT:-start}" "${NAME}" --pane-pid "${PANE_PID}" \
		--created "${CREATED}" --cwd "${WORKDIR}" --command "${LAUNCH}" --reason "${SESSION_LEDGER_REASON:-tmux-session-start.sh}" 2>&1) \
		|| echo "spoke ${NAME}: WARNING - could not record the start in the session ledger: ${OUT}"
	echo "spoke ${NAME}: created tmux session '${NAME}' (workdir ${WORKDIR}${CHARTER:+, charter ${CHARTER}}${SOURCE:+, source ${SOURCE}}${COMMIT:+ at ${COMMIT}}, generation ${GENERATION})"
	exit 0
fi

if [ "${AGENT_TMUX_SESSION}" != "true" ]; then
	echo "tmux session: disabled (AGENT_TMUX_SESSION=${AGENT_TMUX_SESSION})"
	exit 0
fi

if ! command -v tmux > /dev/null; then
	echo "tmux session: ERROR - tmux is not installed (setup/install-tmux.sh)"
	exit 1
fi

# "=" pins an exact-name match: a bare -t prefix-matches, so a session named
# "agent-something" would wrongly satisfy a check for "agent"
if tmux has-session -t "=${AGENT_TMUX_SESSION_NAME}" 2>/dev/null; then
	echo "tmux session: '${AGENT_TMUX_SESSION_NAME}' already exists (left untouched)"
	exit 0
fi

# Start in /wd (the persistent work volume, same default as the autonomy loop) when it
# exists - a repo checkout outside a container has no /wd
SESSION_WORKDIR=/wd
[ -d "${SESSION_WORKDIR}" ] || SESSION_WORKDIR=${HOME}

# The pane's folder is trusted for claude before the pane starts (/agent/claude-onboarding.py --dir, merge-safe: a
# missing answer is added, nothing else changes). The image's config trusts /wd alone (claude-settings-sync.sh at the
# build and at every start), so a pane that started in the fallback folder opened at Claude Code's trust question
# instead of its prompt - where the tmux-agent dashboard reads a menu, not the agent (a plain docker run of the image)
python3 "${AGENT_DIR}/claude-onboarding.py" --dir "${SESSION_WORKDIR}" > /dev/null 2>&1 \
	|| echo "tmux session: WARNING - could not mark ${SESSION_WORKDIR} trusted for claude (the pane may open at the trust question)"

# The claude settings are handed to the pane with -e: a pane inherits the tmux SERVER's
# environment, not this caller's, so on a re-run against an already-running server the
# caller's values would otherwise never reach /agent/tmux-claude.sh
# CLAUDE_BIN only when it is set (a test's stub claude; the supervisor's start of a gone hub session passes its own), and
# the memory API wait's settings as this caller has them (set ones only) - with -e only to a tmux server that is already
# running. A server this call starts takes this environment as its own, so the pane has them anyway, and an -e on the
# call that starts the server stays in that server's command line for its whole life, where ps and pgrep see it.
HUB_ENV=()
if tmux list-sessions > /dev/null 2>&1; then
	[ -n "${CLAUDE_BIN}" ] && HUB_ENV=(-e "CLAUDE_BIN=${CLAUDE_BIN}")
	for V in UI_START UI_HINDSIGHT UI_PORT_HINDSIGHT_API HINDSIGHT_WAIT_SECS; do
		[ -n "${!V+x}" ] && HUB_ENV+=(-e "${V}=${!V}")
	done
fi
# The session's parent and task, for its lineage below: AGENT_TMUX_PARENT and AGENT_TMUX_TASK when set, else the
# registry's entry for this session (/agent/spokes/registry.json), else the operator and the interactive agent's task
HUB_PARENT=${AGENT_TMUX_PARENT:-$("${AGENT_DIR}/spoke.sh" entry "${AGENT_TMUX_SESSION_NAME}" parent 2>/dev/null)}
HUB_TASK=${AGENT_TMUX_TASK:-$("${AGENT_DIR}/spoke.sh" entry "${AGENT_TMUX_SESSION_NAME}" task 2>/dev/null)}
[ -n "${HUB_PARENT}" ] || HUB_PARENT=operator
[ -n "${HUB_TASK}" ] || HUB_TASK="the interactive agent: browser terminal /tmux/ and exec shells"
# the ledger's two settings are a resume's alone (the spokes' call above drops them the same way)
HUB_PANE=$(env -u SESSION_LEDGER_EVENT -u SESSION_LEDGER_REASON tmux new-session -d -P -F '#{pane_id}' -s "${AGENT_TMUX_SESSION_NAME}" -n claude -c "${SESSION_WORKDIR}" \
	-e AGENT_TMUX_CLAUDE="${AGENT_TMUX_CLAUDE}" \
	-e AGENT_TMUX_CLAUDE_OPTS="${AGENT_TMUX_CLAUDE_OPTS}" \
	"${HUB_ENV[@]}" \
	"${AGENT_DIR}/tmux-claude.sh") \
	|| { echo "tmux session: ERROR - could not create '${AGENT_TMUX_SESSION_NAME}'"; exit 1; }
echo "tmux session: created '${AGENT_TMUX_SESSION_NAME}' (window: claude, workdir: ${SESSION_WORKDIR})"

# Lineage for the tmux-agent dashboard - the session user options its census reads. Without a parent the
# dashboard lists the session as ORPHANED ("nobody claims it"); the parent is the operator, the human who drives
# it through the browser terminal and exec shells (a process parent, not another tmux session), the owner is the
# harness, the task says what the session is for. AGENT_TMUX_PARENT / _OWNER / _TASK / _ROLE override them; the
# parent and the task default to the registry's (above). @agent_pane is the agent's pane, the one the supervisor reads:
# a window a person opens in the session is not it. Separate set-option calls are safe here, unlike a spoke's
# start: the session's pane falls back to a shell when claude exits (tmux-claude.sh), so it does not exit at once,
# the case in which this image's tmux 3.2a server crashes on the next query (the spokes' start above).
# "=name:" - an exact session name as the pane/option target (tmux 3.2 refuses a bare "=name" there)
S="=${AGENT_TMUX_SESSION_NAME}:"
tmux set-option -t "${S}" @agent_parent "${HUB_PARENT}"
tmux set-option -t "${S}" @agent_owner "${AGENT_TMUX_OWNER:-do-agent-aws}"
tmux set-option -t "${S}" @agent_task "${HUB_TASK}"
tmux set-option -t "${S}" @agent_role "${AGENT_TMUX_ROLE:-agent}"
tmux set-option -t "${S}" @agent_pane "${HUB_PANE}"

# Durable capture of the pane for the tmux-agent dashboard (its log bytes, its log tail and its log-growth
# WORKING signal) at <TMUX_AGENT_HOME>/logs/<session>.log, where the dashboard reads it - on the /wd volume, the
# same default /agent/ui-start.sh gives the dashboard. The log holds raw terminal bytes, so the directory is 0700
# and the file 0600 (the dashboard's own rule). One start captures at most TMUX_AGENT_LOG_MAX_BYTES (64 MiB) and
# a log already over that is moved aside to <log>.1 first, so a long-lived container cannot fill the disk (head
# under stdbuf -o0: a bare head buffers the stream, and the log - the dashboard's activity signal - stayed empty).
TMUX_AGENT_HOME=${TMUX_AGENT_HOME:-$([ -d /wd ] && echo /wd/tmux-agent-home || echo "${HOME}/.tmux-agent")}
LOG_MAX=${TMUX_AGENT_LOG_MAX_BYTES:-67108864}
LOG=${TMUX_AGENT_HOME}/logs/${AGENT_TMUX_SESSION_NAME}.log
if mkdir -p "${TMUX_AGENT_HOME}/logs" 2>/dev/null && chmod 700 "${TMUX_AGENT_HOME}" "${TMUX_AGENT_HOME}/logs"; then
	[ "$(stat -c %s "${LOG}" 2>/dev/null || echo 0)" -gt "${LOG_MAX}" ] && mv -f "${LOG:?}" "${LOG:?}.1"
	touch "${LOG}" && chmod 600 "${LOG}" \
		&& tmux pipe-pane -t "${S}" "exec stdbuf -o0 head -c ${LOG_MAX} >> '${LOG}'" \
		&& echo "tmux session: capturing the pane to ${LOG}"
else
	echo "tmux session: no capture log - cannot create ${TMUX_AGENT_HOME}/logs"
fi
