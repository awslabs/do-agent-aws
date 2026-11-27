#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the tmux cheatsheet tile (/tmux-help/, rendered by /agent/home-render.sh) and of
# tmux render parity for the Claude CLI (the Dockerfile's ENV LANG).
# Fully OFFLINE: everything binds 127.0.0.1 on test-local ports, sockets and state directories.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the changed script parses (bash -n)
#   2. home-render.sh renders site/tmux-help/index.html AND the home page carries a tile
#      linking /tmux-help/; with UI_TMUX=false the tile greys out naming its enabling flag
#   3. the cheatsheet answers 200 THROUGH the home proxy port, offline (no external assets)
#   4. accuracy gate: every key and setting the page documents (its data-tmux /
#      data-tmux-opt markers) exists in THIS image's tmux exactly as written - checked
#      against a live list-keys / show-options - and the page names the real session name.
#      The gate is proven able to fail: a deliberately wrong marker must be rejected.
#   5. render parity: a tmux client attached with the SHIPPED environment draws a pane's
#      unicode as unicode (the Claude CLI's box graphics survive the trip to the browser),
#      while a client with the locale stripped draws the ACS/underscore fallback - the
#      negative twin proving the probe can fail and that parity comes from the environment
#      (the Dockerfile ENV LANG), not from tmux itself
# Uses test-local state directories (/tmp/tmux-help-smoke*); does not disturb live state under /wd.

D=/tmp/tmux-help-smoke
rm -rf "${D:?}"
mkdir -p ${D}

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"

export UI_DIR=${D}/ui
export UI_LISTEN_HOST=127.0.0.1
export UI_HOME=true
export UI_TMUX=true
export UI_HEADLAMP=false
export UI_HINDSIGHT=false
export UI_VIBE_KANBAN=false
export UI_TMUX_AGENT=false
export COMMS_UI_ENABLED=false
export UI_FILES=false
export UI_PORT_HOME=18013
export UI_PORT_TMUX=17683
# Test-local session name, exported BEFORE the page renders: it makes the name gate falsifiable
# (a page hardcoding the default 'agent' fails the grep below) and points the ttyd that
# ui-start.sh spawns at a test-local session instead of the live shared one.
export AGENT_TMUX_SESSION_NAME=tmux-help-smoke-sess
SESSION_NAME=${AGENT_TMUX_SESSION_NAME}
ACC_SOCK=tmux-help-smoke-acc
PAR_SOCK=tmux-help-smoke-par

cleanup()
{
	"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
	tmux -L ${ACC_SOCK} kill-server 2>/dev/null
	tmux -L ${PAR_SOCK}-shipped kill-server 2>/dev/null
	tmux -L ${PAR_SOCK}-stripped kill-server 2>/dev/null
}

fail()
{
	echo "Test13 FAILED: $1"
	cleanup
	exit 1
}

# --- 1. syntax ---
bash -n "${AGENT_DIR}/home-render.sh" || fail "bash -n ${AGENT_DIR}/home-render.sh"
echo "ok 1 - syntax"

# --- preflight: proxy + tmux + a pty recorder for the parity probe ---
if ! command -v nginx > /dev/null || ! command -v tmux > /dev/null || ! command -v script > /dev/null; then
	echo "Test13 skipped: nginx/tmux/script not installed (run setup/install-nginx.sh and setup/install-tmux.sh)"
	exit 0
fi

# --- 2. the page and its tile render; the tile greys out when the terminal is off ---
( export UI_TMUX=false; "${AGENT_DIR}/home-render.sh" > /dev/null ) || fail "home-render.sh (UI_TMUX=false variant)"
INDEX=${UI_DIR}/home/site/index.html
PAGE=${UI_DIR}/home/site/tmux-help/index.html
grep -q 'data-url="/tmux-help/"' "${INDEX}" && fail "UI_TMUX=false still renders a live cheatsheet tile"
grep -E 'tmux cheatsheet.*off - set UI_TMUX=true' "${INDEX}" > /dev/null || fail "disabled cheatsheet tile not greyed with its flag"
"${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh (defaults)"
[ -s "${PAGE}" ] || fail "site/tmux-help/index.html was not rendered"
grep -q 'data-url="/tmux-help/"' "${INDEX}" || fail "home page carries no tile linking /tmux-help/"
echo "ok 2 - page renders; tile links it when enabled and greys out with its flag when not"

# --- 2b. the Ctrl+C warning is a callout at the TOP, in "This harness", before the first key table (it sat
#         at the bottom of the page, under Scrollback and copy) ---
HELP_PAGE=${UI_DIR}/home/site/tmux-help/index.html
CALLOUT=$(grep -n 'id="ctrl-c"' "${HELP_PAGE}" | head -1 | cut -d: -f1)
FIRST_TABLE=$(grep -n '<h2>Detach, re-attach, sessions</h2>' "${HELP_PAGE}" | head -1 | cut -d: -f1)
[ -n "${CALLOUT}" ] || fail "the cheatsheet has no Ctrl+C callout (id=ctrl-c)"
[ -n "${FIRST_TABLE}" ] || fail "the cheatsheet has no 'Detach, re-attach, sessions' heading to compare against"
[ "${CALLOUT}" -lt "${FIRST_TABLE}" ] || fail "the Ctrl+C callout (line ${CALLOUT}) is not above the first key table (line ${FIRST_TABLE})"
grep -q 'class="callout warn" id="ctrl-c"><strong>Ctrl+C interrupts the agent.</strong>' "${HELP_PAGE}" || fail "the Ctrl+C callout is not a warning callout that leads with the consequence"
grep -q 'as the callout at the top says' "${HELP_PAGE}" || fail "the Scrollback and copy section no longer points at the callout"
echo "ok 2b - the Ctrl+C warning is a warning callout in 'This harness' above the first key table, and the copy section points back at it"

# --- 3. the page answers through the single proxy port, offline ---
"${AGENT_DIR}/ui-start.sh" > /dev/null || fail "ui-start.sh"
HTTP=000
for i in $(seq 1 30); do
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${UI_PORT_HOME}/tmux-help/" 2>/dev/null)
	[ "${HTTP}" == "200" ] && break
	sleep 1
done
[ "${HTTP}" == "200" ] || fail "/tmux-help/ not answering 200 through the proxy (last=${HTTP})"
curl -s "http://127.0.0.1:${UI_PORT_HOME}/tmux-help/" | grep -q "tmux cheatsheet" \
	|| fail "/tmux-help/ does not carry the cheatsheet title"
grep -qE 'src="http|href="http.*\.(css|js)' "${PAGE}" && fail "cheatsheet references external assets (must render offline)"
echo "ok 3 - /tmux-help/ -> 200 through the proxy, offline"

# --- 4. accuracy gate: everything the page documents is true of this image's tmux ---
tmux -L ${ACC_SOCK} new-session -d -s accgate || fail "could not start the accuracy-gate tmux server"
sleep 1

marker_ok()
{
	# marker_ok <key-table> <key> <command-substring> - true when this image's tmux binds
	# <key> to a command containing <command-substring> in <key-table>. Keys the page shows
	# bare may be printed backslash-escaped by list-keys, and the escape set is version-
	# dependent ('%' joined it in tmux 3.3a), so both spellings are accepted.
	TABLE=$1
	KEY=$2
	CMD=$3
	case "${KEY}" in
		'"'|'$'|';'|'%') LKKEY="\\${KEY}" ;;
		*)               LKKEY=${KEY} ;;
	esac
	LINE=$(tmux -L ${ACC_SOCK} list-keys -T "${TABLE}" 2>/dev/null \
		| LKKEY="${LKKEY}" RAWKEY="${KEY}" awk '($2=="-T" && ($4==ENVIRON["LKKEY"] || $4==ENVIRON["RAWKEY"])) || ($3=="-T" && ($5==ENVIRON["LKKEY"] || $5==ENVIRON["RAWKEY"]))')
	[ -n "${LINE}" ] && echo "${LINE}" | grep -qF "${CMD}"
}

# the gate itself must be able to fail: a correct spec passes, a wrong one is rejected
marker_ok prefix d detach-client || fail "accuracy-gate self-check: known-good binding rejected"
marker_ok prefix d new-window && fail "accuracy-gate self-check: wrong-command control was accepted (gate cannot fail)"

grep -o "data-tmux='[^']*'" "${PAGE}" | sed "s/^data-tmux='//;s/'\$//" > ${D}/markers
[ "$(wc -l < ${D}/markers)" -ge 20 ] || fail "page carries $(wc -l < ${D}/markers) key markers (expected 20+; were the data-tmux markers dropped?)"
while IFS='|' read -r TABLE KEY CMD; do
	marker_ok "${TABLE}" "${KEY}" "${CMD}" \
		|| echo "${TABLE} table: page documents '${KEY}' -> '${CMD}' but this tmux does not bind it" >> ${D}/acc-fail
done < ${D}/markers
[ -f ${D}/acc-fail ] && fail "documented keys this image's tmux does not have: $(cat ${D}/acc-fail | tr '\n' '; ')"

grep -o "data-tmux-opt='[^']*'" "${PAGE}" | sed "s/^data-tmux-opt='//;s/'\$//" > ${D}/opt-markers
[ -s ${D}/opt-markers ] || fail "page carries no data-tmux-opt markers"
while IFS='|' read -r OPT VAL; do
	GOT=$(tmux -L ${ACC_SOCK} show-options -g "${OPT}" 2>/dev/null | awk '{print $2}')
	[ -n "${GOT}" ] || GOT=$(tmux -L ${ACC_SOCK} show-options -gw "${OPT}" 2>/dev/null | awk '{print $2}')
	[ "${GOT}" == "${VAL}" ] || echo "page documents ${OPT}=${VAL} but this tmux has '${GOT}'" >> ${D}/opt-fail
done < ${D}/opt-markers
[ -f ${D}/opt-fail ] && fail "documented settings this image's tmux does not have: $(cat ${D}/opt-fail | tr '\n' '; ')"

grep -qF "tmux attach -t ${SESSION_NAME}" "${PAGE}" || fail "page does not name the real agent session (${SESSION_NAME})"
tmux -L ${ACC_SOCK} kill-server 2>/dev/null
echo "ok 4 - accuracy gate: every documented key/setting verified against this image's tmux (and the gate rejects a planted wrong one)"

# --- 5. render parity: unicode survives the tmux client with the shipped environment ---
# The Claude CLI draws with unicode (rounded corners, blocks, check marks). tmux stores the
# pane grid as UTF-8 regardless, but at DRAW time a client whose locale is not UTF-8 gets
# line-art downgraded to ACS escapes and everything else replaced with underscores - which
# is exactly what the browser terminal and an in-container "tmux attach" showed before the
# Dockerfile shipped ENV LANG. The probe plants unicode in a pane and captures what a
# client actually draws, once with the shipped environment and once with the locale
# stripped; the two must differ in exactly the documented way.
UNI=$(printf '\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x90\xe2\x95\xad\xe2\x95\xae\xe2\x9c\x94')   # box + rounded corners + check

draw_as()
{
	# draw_as <label> [<env assignments...>] - fresh isolated tmux server, plant the
	# unicode probe in its pane, attach a client under exactly this environment, record
	# what the client draws to the pty, tear the server down. One server per draw: a
	# detached-then-reattached server is not guaranteed alive across cycles here, and an
	# accidental dead-server draw must not masquerade as a rendering verdict.
	LABEL=$1
	shift
	SOCK=${PAR_SOCK}-${LABEL}
	env -i PATH=/usr/bin:/bin HOME="${HOME:-/home/agent}" tmux -L ${SOCK} new-session -d -s par \
		|| fail "could not start the parity tmux server (${LABEL})"
	tmux -L ${SOCK} send-keys -t par "echo UNIPROBE:${UNI}" Enter
	# poll, don't sleep: the pane's shell may still be starting when the keys arrive
	for i in $(seq 1 30); do
		tmux -L ${SOCK} capture-pane -p -t par 2>/dev/null | grep -qF "UNIPROBE:${UNI}" && break
		sleep 0.5
	done
	tmux -L ${SOCK} capture-pane -p -t par | grep -qF "UNIPROBE:${UNI}" \
		|| fail "parity precondition (${LABEL}): unicode did not reach the pane grid"
	( env -i PATH=/usr/bin:/bin HOME="${HOME:-/home/agent}" TERM=xterm "$@" \
		script -qec "tmux -L ${SOCK} attach -t par" ${D}/draw-${LABEL}.raw > /dev/null 2>&1 ) &
	DRAW_PID=$!
	# same for the draw: wait until the client has actually drawn the probe row (the ASCII
	# "UNIPROBE:" prefix lands in the capture either way), then let it settle one beat
	for i in $(seq 1 30); do
		grep -aq "UNIPROBE:" ${D}/draw-${LABEL}.raw 2>/dev/null && break
		sleep 0.5
	done
	sleep 0.5
	tmux -L ${SOCK} detach-client -s par 2>/dev/null
	wait ${DRAW_PID} 2>/dev/null
	tmux -L ${SOCK} kill-server 2>/dev/null
	grep -aq "UNIPROBE:" ${D}/draw-${LABEL}.raw || fail "parity probe (${LABEL}) captured no draw at all"
}

# The shipped locale under test. In the image, the Dockerfile's ENV LANG IS this process's
# environment (and the Dockerfile itself is not shipped). From a checkout the Dockerfile is
# present and is the artifact - the value is read from it there, because the ambient shell's
# LANG proves nothing about what the Dockerfile ships.
SHIPPED_LANG=${LANG}
DOCKERFILE="${BASE_DIR%/}/../Dockerfile"
if [ -f "${DOCKERFILE}" ]; then
	SHIPPED_LANG=$(sed -n 's/^ENV LANG=//p' "${DOCKERFILE}" | tail -1)
fi
LOCNORM=$(echo "${SHIPPED_LANG}" | tr 'A-Z' 'a-z' | tr -d '.-')
case "${LOCNORM}" in *utf8*) : ;; *) fail "shipped LANG='${SHIPPED_LANG}' is not a UTF-8 locale (Dockerfile ENV LANG removed?)" ;; esac
locale -a 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '.-' | grep -qx "${LOCNORM}" \
	|| fail "shipped LANG='${SHIPPED_LANG}' does not exist on this system (locale -a)"

draw_as shipped LANG="${SHIPPED_LANG}"
grep -qF "UNIPROBE:${UNI}" ${D}/draw-shipped.raw \
	|| fail "PARITY BROKEN: a client with the shipped environment did not draw the pane's unicode as unicode"
echo "ok 5a - shipped environment: the tmux client draws unicode as unicode (LANG=${SHIPPED_LANG})"

draw_as stripped
grep -qF "UNIPROBE:${UNI}" ${D}/draw-stripped.raw \
	&& fail "negative twin drew real unicode without a locale - the parity probe can no longer fail"
grep -aq "UNIPROBE:.*_" ${D}/draw-stripped.raw \
	|| fail "negative twin did not draw the ACS/underscore fallback (probe did not exercise the mechanism)"
echo "ok 5b - locale-stripped twin degrades to underscores (negative control: the parity comes from the environment)"

cleanup
echo "Test13 succeeded"
