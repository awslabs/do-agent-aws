#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# issues spoke - the read-only front for gh: the only way its cycle, and its session for its own reads, call GitHub.
# It forwards an allowlist of read forms to gh, argument for argument (never through a shell), and refuses every other
# form before gh runs: exit 2, one line on stderr and one in ${ISSUES_SPOKE_WD}/refusals.log. A gh api call is not
# read-only by its name: -X/--method choose the verb, and -f/-F/--field/--raw-field/--input turn gh's default GET into a
# POST; so api is allowed with an endpoint path, GET and output flags alone, and never graphql (a mutation is a POST).
#
#   gh-ro.sh pr list|view|checks|diff|status ...      gh-ro.sh issue list|view|status ...
#   gh-ro.sh search prs|issues|code|commits|repos ... gh-ro.sh repo view ...       gh-ro.sh auth status
#   gh-ro.sh api <endpoint> [--paginate] [--slurp] [-q|--jq <expr>] [-X|--method GET] [-H|--header Accept:<type>]
#                           [--cache <duration>] [-i|--include] [--silent] [--hostname github.com]
#
# Environment: ISSUES_SPOKE_WD, where refusals.log goes (default ${SPOKE_DIR:-/wd/issues}). It forwards to the gh on
# PATH and holds no credential of its own: gh reads GH_TOKEN as it always does.
set -uo pipefail
WD="${ISSUES_SPOKE_WD:-${SPOKE_DIR:-/wd/issues}}"

refuse()
{
	local line
	# the refused line, with anything shaped like a GitHub token masked
	line=$(printf '%s ' "$@" | sed -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/\1[masked]/g' | cut -c1-400)
	echo "REFUSED (the issues spoke reads GitHub only): gh ${line}- ${REASON}" >&2
	mkdir -p "${WD:?}" 2>/dev/null && printf '%s REFUSED gh %s- %s\n' "$(date -u +%FT%TZ)" "${line}" "${REASON}" >> "${WD:?}/refusals.log"
	exit 2
}

[ $# -ge 1 ] || { REASON="no subcommand"; refuse; }
# argv reaches gh token for token, so a shell operator here can only be an attempt to chain a second command
for A in "$@"; do
	case "${A}" in
		'&&'|'||'|';'|'|'|'>'|'>>'|'<'|'`'*|'$('*) REASON="a shell operator in the arguments (${A})"; refuse "$@" ;;
	esac
done
# --web opens a browser, and --show-token would print the token into a log
for A in "$@"; do
	case "${A}" in
		-w|--web|-t|--show-token) [ "$1" != "api" ] && { REASON="${A} is not allowed"; refuse "$@"; } ;;
	esac
done

case "$1" in
	pr)     case "${2:-}" in list|view|checks|diff|status) ;; *) REASON="pr ${2:-} is not a read"; refuse "$@" ;; esac ;;
	issue)  case "${2:-}" in list|view|status) ;; *) REASON="issue ${2:-} is not a read"; refuse "$@" ;; esac ;;
	search) case "${2:-}" in prs|issues|code|commits|repos) ;; *) REASON="search ${2:-} is not a read"; refuse "$@" ;; esac ;;
	repo)   case "${2:-}" in view) ;; *) REASON="repo ${2:-} is not a read"; refuse "$@" ;; esac ;;
	auth)   [ "${2:-}" == "status" ] || { REASON="auth ${2:-} is not a read"; refuse "$@"; } ;;
	api)
		# whole-string matches: a value with a line break in it matches neither
		ACCEPT_RX='^[Aa][Cc][Cc][Ee][Pp][Tt]:[^:[:cntrl:]]*$'
		PATH_RX='^/?[A-Za-z0-9{][A-Za-z0-9._~/{}?=&,:%+-]*$'
		ENDPOINT=""
		I=2
		while [ "${I}" -le $# ]; do
			A=${!I}
			NEXT=$((I + 1))
			V=""
			[ "${NEXT}" -le $# ] && V=${!NEXT}
			case "${A}" in
				--paginate|--slurp|-i|--include|--silent) ;;
				-q|--jq|--cache)
					[ "${NEXT}" -le $# ] || { REASON="${A} without its value"; refuse "$@"; }
					I=${NEXT} ;;
				--jq=*|--cache=*) ;;
				# the one host whose reads this spoke makes: github.com
				--hostname)
					[ "${V}" == "github.com" ] || { REASON="the host ${V:-(none)} is not github.com"; refuse "$@"; }
					I=${NEXT} ;;
				--hostname=*)
					[ "${A#--hostname=}" == "github.com" ] || { REASON="the host ${A#--hostname=} is not github.com"; refuse "$@"; } ;;
				-X|--method)
					[ "${V^^}" == "GET" ] || { REASON="the method ${V:-(none)} is not GET"; refuse "$@"; }
					I=${NEXT} ;;
				--method=*|-X*)
					M=${A#--method=}; [ "${M}" == "${A}" ] && M=${A#-X}
					[ "${M^^}" == "GET" ] || { REASON="the method ${M:-(none)} is not GET"; refuse "$@"; } ;;
				-H|--header)
					[[ "${V}" =~ ${ACCEPT_RX} ]] || { REASON="a header other than Accept"; refuse "$@"; }
					I=${NEXT} ;;
				-*)
					REASON="${A} is not one of the read flags (a field, an input or another verb turns gh api into a write)"; refuse "$@" ;;
				*)
					[ -z "${ENDPOINT}" ] || { REASON="a second endpoint (${A})"; refuse "$@"; }
					ENDPOINT=${A} ;;
			esac
			I=$((I + 1))
		done
		[ -n "${ENDPOINT}" ] || { REASON="api without an endpoint"; refuse "$@"; }
		# graphql in any letter case and with anything after it (graphql/, graphql?x): a query or a mutation, both POST
		E=${ENDPOINT#/}
		[[ "${E,,}" =~ ^graphql([/?#]|$) ]] && { REASON="graphql (a query or a mutation, both sent as POST)"; refuse "$@"; }
		[[ "${ENDPOINT}" =~ ${PATH_RX} ]] && [[ "${ENDPOINT}" != *://* ]] || { REASON="the endpoint is not a path of the API"; refuse "$@"; }
		;;
	*) REASON="$1 is not one of the read subcommands"; refuse "$@" ;;
esac
exec gh "$@"
