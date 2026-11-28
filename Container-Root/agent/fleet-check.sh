#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The fleet check: what a tmux session's agent is doing, read from its pane, and the one safe repair (docs/AGENT-STACK.md
# "What the supervisor does on every pass"). The harness's port of the fleet monitor's pane classification and of the
# fleet's compact rule; /agent/supervisor.sh runs it for every live session, and a person can too.
#
#   /agent/fleet-check.sh <session>           one JSON line: the verdict, the line that decided it, the context reading
#   /agent/fleet-check.sh compact <session>   send /compact - only when the pane, read again at that moment, reads
#                                             "context" with an empty prompt line (80% or more, no spinner, no menu);
#                                             exit 0 sent, 1 not sent (the reason on stdout)
#   /agent/fleet-check.sh pane <session>      the agent's pane: "<pane id> <pane pid>", nothing when it is gone
#
# The pane is the agent's: the one the session's start recorded as the session option @agent_pane
# (/agent/tmux-session-start.sh), so a window a person opens in the session is never read or typed into. A session
# started without that option, not by this harness, has its active pane read.
#
# The verdict, from the pane's visible screen (the live tail is its last lines, so an old line further up never counts):
#   menu     a menu or a question waits for an answer ("Enter to select", "Tab/Arrow", "1." after the prompt mark, "Do
#            you want to", "(y/n)", "should I proceed", "held for operator", "awaiting operator", or an option line of
#            a numbered menu that opens "Yes, and" or "No, and tell", such as "  2. Yes, and don’t ask again": the line
#            starts with the option's number, so a sentence that says "yes, and" is not one) - checked first: a pane at
#            a menu runs no turn
#   working  a turn runs: "esc to interrupt", a spinner verb, an elapsed-time counter, "Compacting", ...
#   error    "compaction failed", "API Error" or "Prompt is too long" in the live tail, with no turn running
#   context  a status line reads ctx:NN% (the image's status line) or ctx:[bar]NN% (the fleet's HUD) at 80 or more,
#            at an empty prompt line
#   idle     an empty prompt line (the prompt mark alone; Claude Code 2.1 ends it with a no-break space), nothing else
#   unknown  none of these; the supervisor reads it as working (the check errs toward "working")
# The JSON: session, verdict, why (the line or pattern that decided it), ctx (the number, or null) and idle_prompt.
# It types nothing but the three keys of the compact repair (C-u, /compact, Enter), and never into a menu.

S=$1
MODE=check
if [ "$1" == "compact" ] || [ "$1" == "pane" ]; then
	MODE=$1
	S=$2
fi
echo "${S}" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || { echo "usage: $0 <session> | compact <session> | pane <session>" >&2; exit 64; }

# pane - the agent's pane as "<pane id> <pane pid>": of the session's panes in every window ("=name:" is the exact-match
# target), the one @agent_pane names, or without that option the active pane of the active window; nothing when the
# session or the recorded pane is gone
pane()
{
	local ID PID ACT OPT HIT=""
	while read -r ID PID ACT OPT; do
		if [ -n "${OPT}" ]; then
			[ "${ID}" == "${OPT}" ] && HIT="${ID} ${PID}"
		elif [ "${ACT}" == "11" ]; then
			HIT="${ID} ${PID}"
		fi
	done < <(tmux list-panes -s -t "=${S}:" -F '#{pane_id} #{pane_pid} #{window_active}#{pane_active} #{@agent_pane}' 2>/dev/null)
	echo "${HIT}"
}
if [ "${MODE}" == "pane" ]; then
	pane
	exit 0
fi
read -r P _ <<< "$(pane)"

classify()
{
	# the agent pane's screen, classified
	if [ -z "${P}" ] || ! SCREEN=$(tmux capture-pane -p -t "${P}" 2>/dev/null); then
		WHY="no such session"
		tmux has-session -t "=${S}" 2>/dev/null && WHY="its agent pane is gone"
		echo "{\"session\": \"${S}\", \"verdict\": \"gone\", \"why\": \"${WHY}\", \"ctx\": null, \"idle_prompt\": false}"
		return
	fi
	# shellcheck disable=SC1112 # the Python program's ’ is data: a spinner verb's typographic apostrophe in the turn pattern
	printf '%s' "${SCREEN}" | python3 -I -c '
import json, re, sys
s, screen = sys.argv[1], sys.stdin.read()
raw = screen.splitlines()
lines = [l.rstrip() for l in raw]
tail = lambda n: [l for l in lines if l.strip()][-n:]
# a menu option counts only on a line that starts with its number, after the cursor mark or a dialog border
# ("❯ 2. Yes, and don’t ask again", "│   3. No, and tell Claude what to do differently"), and only when no empty
# prompt line sits below it: a menu takes the place of the prompt box. A sentence that says "returned yes, and the
# API" is an answer, and so is a numbered item of an answer ("  1. Yes, and the API") above the empty prompt line
MENU = re.compile(r"(?i:Enter to select|Tab/Arrow|❯ ?1\.|Do you want to|\(y/n\)|should I proceed|held for operator|awaiting operator)")
OPTION = re.compile(r"^[\s│]*(?:❯\s*)?[0-9]+\.\s+(?:Yes, and|No, and tell)")
# a turn runs only while its live line shows: a spinner glyph and a verb ending in "…", or "esc to interrupt"; the line
# a finished turn leaves ("✻ Cooked for 8s · done 3:45 AM") is not one
WORK = re.compile(r"esc to interrupt|^\s*[·✢✳✶✻✽*]\s+[A-Z][\w\x27’-]*…|running (stop hooks|scheduled)")
ERR = re.compile(r"(?i:compaction failed)|API Error|Prompt is too long")
CTX = re.compile(r"ctx[^0-9%\n]{0,40}?([0-9]{1,3})%")
ctx = [int(m.group(1)) for l in lines for m in CTX.finditer(l)]
ctx = ctx[-1] if ctx else None
# Claude Code 2.1 draws its empty prompt line as the mark and a no-break space (U+00A0), not a space
PROMPT = re.compile("❯[ \u00a0]*")
idle = any(PROMPT.fullmatch(l) for l in raw)
def first(rx, ls):
    for l in reversed(ls):
        m = rx.search(l)
        if m:
            return " ".join(l.split())[:160]
    return None
verdict, why = "unknown", "no pattern matched"
def menu(ls):
    # bottom-up, as first() reads: a question line, or an option line with no empty prompt line below it
    for i in range(len(ls) - 1, -1, -1):
        if MENU.search(ls[i]) or (OPTION.search(ls[i]) and not any(PROMPT.fullmatch(b) for b in ls[i + 1:])):
            return " ".join(ls[i].split())[:160]
    return None
m = menu(tail(15))
if m:
    verdict, why = "menu", m
elif first(WORK, tail(8)):
    verdict, why = "working", first(WORK, tail(8))
elif first(ERR, tail(8)):
    verdict, why = "error", first(ERR, tail(8))
elif ctx is not None and ctx >= 80 and idle:
    verdict, why = "context", f"ctx {ctx}%"
elif idle:
    verdict, why = "idle", "an empty prompt line"
print(json.dumps({"session": s, "verdict": verdict, "why": why, "ctx": ctx, "idle_prompt": idle}))
' "${S}"
}

if [ "${MODE}" == "check" ]; then
	classify
	exit 0
fi

# the repair: read the pane again now, and only then - the fleet's rule: >= 80%, an empty prompt line, no spinner, no menu
V=$(classify)
WHAT=$(printf '%s' "${V}" | python3 -I -c 'import json, sys; v = json.load(sys.stdin); print(v["verdict"], "true" if v["idle_prompt"] else "false", v["ctx"] if v["ctx"] is not None else "-")')
read -r VERDICT IDLE CTX <<< "${WHAT}"
if [ "${VERDICT}" != "context" ] || [ "${IDLE}" != "true" ]; then
	echo "not sent: the pane reads ${VERDICT} (ctx ${CTX}%, empty prompt line ${IDLE}) - /compact goes only into an idle pane at 80% or more"
	exit 1
fi
# type it, then read the input line back: Enter goes in only when it reads exactly "❯ /compact" - a dialog that opened in
# between would take Enter as its default answer
tmux send-keys -t "${P}" C-u && tmux send-keys -t "${P}" -l '/compact' || { echo "not sent: tmux send-keys failed"; exit 1; }
LINE=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
	LINE=$(tmux capture-pane -p -t "${P}" 2>/dev/null | python3 -I -c 'import sys; ls = [l.rstrip() for l in sys.stdin if l.lstrip().startswith("❯")]; print(ls[-1].strip() if ls else "")')
	python3 -I -c 'import re, sys; sys.exit(0 if re.fullmatch("❯[ \u00a0]/compact", sys.argv[1]) else 1)' "${LINE}" && break
	LINE="! ${LINE}"
	sleep 0.2
done
if [ "${LINE:0:2}" == "! " ]; then
	tmux send-keys -t "${P}" C-u
	echo "not sent: after typing /compact the input line reads '${LINE:2}', not '❯ /compact' - cleared it, no Enter"
	exit 1
fi
tmux send-keys -t "${P}" Enter || { echo "not sent: tmux send-keys Enter failed"; exit 1; }
echo "sent: /compact (ctx ${CTX}%)"
exit 0
