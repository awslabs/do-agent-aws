#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The claude option string of the loop's fires and the chat responder's replies - AUTONOMY_LOOP_CLAUDE_OPTS and
# SLACK_CHAT_CLAUDE_OPTS (docs/manual/autonomy.md "Autonomy loop") - read in one place: sourced (`. /agent/claude-opts.sh`) by loop.sh,
# loop-once.sh and slack-chat.sh, which keep no copy of it. It defines
#   claude_opts_split <array-name> <string>   the string's words into the array, one argument of the claude call each: a
#                                             blank (space, tab, newline) ends a word OUTSIDE parentheses and stays in the
#                                             word INSIDE them, so Bash(bash /path/script.sh:*) and Bash(kubectl get:*)
#                                             are one word each. A parenthesis never closed takes the rest of the string
#                                             into its word, which is then split on blanks after all, as the shell did:
#                                             a mistake outside the rule lists (--add-dir /x(y) changes nothing, and
#                                             inside one the open fragment (Bash(bash) is a word for the check while the
#                                             options behind it stay options. Quotes are not quotes (as before), and
#                                             nothing is glob-expanded (the caller expands the array quoted). A value
#                                             without a blank inside parentheses splits exactly as the shell does when
#                                             the string is expanded unquoted on the claude line, where a rule
#                                             with a space would reach claude as two words - the first a harmless unknown
#                                             tool name, the second refused ("Ignoring --allowedTools rule ... Wildcard
#                                             tool name ... is not supported in allow rules"), the rule gone, every call
#                                             it allowed denied, and the fire ran on until its timeout.
#   claude_opts_check <array-name>            prints nothing and returns 0 when every rule word can be a rule; else prints
#                                             one line naming EVERY word that cannot, each quoted with its reason (a rule
#                                             split on its space shows as two such words, both named - the second is the
#                                             one claude's own warning quotes), then one hint, and returns 1. The rule
#                                             words are those after --allowedTools / --allowed-tools
#                                             and --disallowedTools / --disallowed-tools up to the next option (a word
#                                             starting with -); a word may hold several rules separated by commas, which
#                                             claude splits the same way. A rule is a tool name, alone or followed by its
#                                             content in parentheses. What is reported:
#                                             - parentheses that do not pair up (a `(` without its `)`, a `)` without its
#                                               `(`, text after the `)`): the shape of a rule with a space that was split,
#                                               or a parenthesis forgotten
#                                             - a rule that starts or ends with a quote: quotes in the value are not quotes
#                                             - an allow rule whose tool name is not one: a tool name is a word of letters,
#                                               digits and underscores (Bash, Read, Edit, WebFetch) or
#                                               mcp__<server>__<tool>, where only the <tool> part may hold a *. Claude
#                                               itself (2.1.304) refuses a * anywhere else in the name (the "Ignoring" line
#                                               above) and takes any other unknown name - a slash, a dot - silently; both
#                                               allow nothing, so this check is stricter than the client and reports both
#                                             - a deny rule whose tool name holds anything but letters, digits, _, - and *
#                                               (a deny rule may hold a glob anywhere: claude accepts it there)
#                                             Not checked: the content inside the parentheses, and the words of --tools
#                                             and --add-dir. A word longer than 120 characters is quoted clipped.
#
# Setting (the environment; declared in .env beside AUTONOMY_LOOP_CLAUDE_OPTS and passed bare, so unset = the default):
#   AUTONOMY_LOOP_OPTS_CHECK - true (the default): the callers run claude_opts_check once, at their start, and a report
#                              means NO claude call - loop.sh and loop-once.sh skip each fire (its END line rc=96
#                              outcome=config <report>, the report in the fire's transcript file, so the Agent loop page
#                              shows it; loop-once.sh prints it on stderr and exits 96) and slack-chat.sh answers each
#                              message that needs the model with one line saying so (CHAT MODEL rc=96 config=<report>);
#                              false: the report is logged as a WARNING and the calls run as before - claude ignores the
#                              rule it refuses, prints its own line at the top of the transcript, and the fire goes on
#                              without it. Why the check exists: that line is the only place claude says so, and a
#                              headless fire denied the calls it needed works around them until AUTONOMY_LOOP_FIRE_TIMEOUT
#                              (1500 s) - a day of fires to learn that one word of the option string was wrong.

AUTONOMY_LOOP_OPTS_CHECK=${AUTONOMY_LOOP_OPTS_CHECK:-true}

# claude_opts_split <array-name> <string> - see the header. The array name must not be __co_words.
claude_opts_split()
{
	local -n __co_words=$1
	local __co_s=$2 __co_i __co_c __co_depth=0 __co_word="" __co_in=0
	__co_words=()
	for (( __co_i = 0; __co_i < ${#__co_s}; __co_i++ )); do
		__co_c=${__co_s:__co_i:1}
		case ${__co_c} in
		"(")
			__co_depth=$(( __co_depth + 1 )); __co_word+=${__co_c}; __co_in=1 ;;
		")")
			[ "${__co_depth}" -gt 0 ] && __co_depth=$(( __co_depth - 1 ))
			__co_word+=${__co_c}; __co_in=1 ;;
		" " | $'\t' | $'\n')
			if [ "${__co_depth}" -gt 0 ]; then
				__co_word+=${__co_c}; __co_in=1
			elif [ "${__co_in}" -eq 1 ]; then
				__co_words+=("${__co_word}"); __co_word=""; __co_in=0
			fi ;;
		*)
			__co_word+=${__co_c}; __co_in=1 ;;
		esac
	done
	if [ "${__co_in}" -eq 1 ]; then
		if [ "${__co_depth}" -gt 0 ]; then
			# a parenthesis never closed took the rest of the string into this word: split it on blanks after all, as the
			# shell did - a mistake outside the rule lists (--add-dir /x(y) then changes nothing, and inside a list the open
			# fragment (Bash(bash) is one word for the check while the options behind it stay options
			local __co_tail=()
			IFS=$' \t\n' read -r -d '' -a __co_tail < <(printf '%s' "${__co_word}")
			__co_words+=("${__co_tail[@]}")
		else
			__co_words+=("${__co_word}")
		fi
	fi
	return 0
}

# claude_opts_rules <word> - the rules of one list word, NUL-separated (a rule may hold a newline inside its parentheses):
# the word split on the commas outside parentheses, as claude splits it
claude_opts_rules()
{
	local __cr_s=$1 __cr_i __cr_c __cr_depth=0 __cr_rule=""
	for (( __cr_i = 0; __cr_i < ${#__cr_s}; __cr_i++ )); do
		__cr_c=${__cr_s:__cr_i:1}
		case ${__cr_c} in
		"(") __cr_depth=$(( __cr_depth + 1 )); __cr_rule+=${__cr_c} ;;
		")") [ "${__cr_depth}" -gt 0 ] && __cr_depth=$(( __cr_depth - 1 )); __cr_rule+=${__cr_c} ;;
		",")
			if [ "${__cr_depth}" -gt 0 ]; then
				__cr_rule+=${__cr_c}
			else
				printf '%s\0' "${__cr_rule}"; __cr_rule=""
			fi ;;
		*) __cr_rule+=${__cr_c} ;;
		esac
	done
	printf '%s\0' "${__cr_rule}"
}

# claude_opts_balanced <rule> - 0 when the rule's parentheses pair up: the depth never drops below 0 and is 0 at the end,
# and a rule that opens a parenthesis ends with its `)` (the tool name, then the content in parentheses, nothing after)
claude_opts_balanced()
{
	local __cb_s=$1 __cb_i __cb_c __cb_depth=0 __cb_open=0
	for (( __cb_i = 0; __cb_i < ${#__cb_s}; __cb_i++ )); do
		__cb_c=${__cb_s:__cb_i:1}
		case ${__cb_c} in
		"(") __cb_depth=$(( __cb_depth + 1 )); __cb_open=1 ;;
		")") __cb_depth=$(( __cb_depth - 1 )); [ "${__cb_depth}" -ge 0 ] || return 1 ;;
		esac
	done
	[ "${__cb_depth}" -eq 0 ] || return 1
	[ "${__cb_open}" -eq 0 ] || [ "${__cb_s: -1}" = ")" ] || return 1
	return 0
}

# claude_opts_quote <word> - the word in double quotes for a report, one line, clipped to 120 characters
claude_opts_quote()
{
	local __cq
	__cq=$(printf '%s' "$1" | tr '\n\r\t' '   ')
	if [ "${#__cq}" -gt 120 ]; then
		printf '"%s..."' "${__cq:0:120}"
	else
		printf '"%s"' "${__cq}"
	fi
}

# claude_opts_check <array-name> - see the header. The array name must not be __cc_words.
claude_opts_check()
{
	local -n __cc_words=$1
	local __cc_w __cc_rule __cc_tool __cc_list="" __cc_once=0 __cc_out=""
	local __cc_allow_re='^([A-Za-z][A-Za-z0-9_]*|mcp__[A-Za-z0-9_-]+(__[A-Za-z0-9_*-]+)?)$'
	local __cc_deny_re='^[A-Za-z0-9_*-]+$'
	for __cc_w in "${__cc_words[@]}"; do
		case ${__cc_w} in
		--allowedTools | --allowed-tools) __cc_list=allow; continue ;;
		--disallowedTools | --disallowed-tools) __cc_list=deny; continue ;;
		--allowedTools=* | --allowed-tools=*) __cc_list=allow; __cc_once=1; __cc_w=${__cc_w#*=} ;;   # the = form takes this one word
		--disallowedTools=* | --disallowed-tools=*) __cc_list=deny; __cc_once=1; __cc_w=${__cc_w#*=} ;;
		-*) __cc_list=""; continue ;;
		esac
		[ -n "${__cc_list}" ] || continue
		while IFS= read -r -d '' __cc_rule; do
			[ -n "${__cc_rule}" ] || continue
			case ${__cc_rule} in
			\'* | \"* | *\' | *\")
				__cc_out="${__cc_out:+${__cc_out}; }the word $(claude_opts_quote "${__cc_rule}") cannot be a rule: quotes in the value are not quotes - remove them"
				continue ;;
			esac
			if ! claude_opts_balanced "${__cc_rule}"; then
				__cc_out="${__cc_out:+${__cc_out}; }the word $(claude_opts_quote "${__cc_rule}") cannot be a rule: its parentheses do not pair up"
				continue
			fi
			__cc_tool=${__cc_rule%%(*}
			if [ "${__cc_list}" = "allow" ]; then
				[[ ${__cc_tool} =~ ${__cc_allow_re} ]] && continue
				__cc_out="${__cc_out:+${__cc_out}; }the word $(claude_opts_quote "${__cc_rule}") cannot be an allow rule: $(claude_opts_quote "${__cc_tool}") is not a tool name"
				continue
			fi
			[[ ${__cc_tool} =~ ${__cc_deny_re} ]] && continue
			__cc_out="${__cc_out:+${__cc_out}; }the word $(claude_opts_quote "${__cc_rule}") cannot be a deny rule: $(claude_opts_quote "${__cc_tool}") is not a tool name (letters, digits, _, - and *)"
		done < <(claude_opts_rules "${__cc_w}")
		[ "${__cc_once}" -eq 0 ] || { __cc_list=""; __cc_once=0; }
	done
	[ -n "${__cc_out}" ] || return 0
	# every offending word, then the hint once: a rule split on its space shows as two words, both named
	printf '%s\n' "${__cc_out} - a rule is a tool name alone or followed by its content in parentheses, and a rule with a space keeps the space inside its parentheses, as Bash(bash /path/script.sh:*); a tool name is a word such as Bash, Read, Edit or mcp__SERVER__TOOL, where only the TOOL part may hold a * (claude refuses a * anywhere else in an allow rule's tool name and takes any other unknown name silently: either way the rule allows nothing, and every call it was meant to allow is denied)"
	return 1
}
