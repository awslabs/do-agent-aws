#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# issues spoke - the GO gate: the only path by which a staged draft reaches GitHub, as one comment, after a person's GO
# (charter.md beside this file, "The GO gate"). A person runs it; it refuses to run from the spoke's own session or
# cycle. Every refusal is one line on stderr and in the private gate.log, exit 2; a failed send exits 1.
#
#   post.sh --command <name>   print the exact send command, for the draft's record
#   post.sh --check <name>     every gate, nothing sent
#   post.sh <name>             every gate, at a terminal the typed sha256 prefix, then the one comment, its read-back,
#                              and the POSTED record
#
# <name> is <owner>.<repository>-<number>; in ${ISSUES_SPOKE_WD}/outbox/ (default /wd/issues/outbox/):
#   <name>.md               the draft, the comment's exact text (the session writes it)
#   <name>.FILING-READY.md  its record: evidence, the duplicate search, the scan result, verify steps, a watch trigger,
#                           and a line "send: <the exact command>" that post.sh --command printed
#   <name>.GO               the person's GO: their words and the draft's sha256 (sha256sum <name>.md); a draft changed
#                           after the GO no longer matches it
#   <name>.POSTED           written here after the send: the comment's URL, its author and whether its read-back
#                           matches the draft byte for byte
# The gates, in order: not from the spoke's session or cycle; the draft, its record and the GO are regular files; the
# GO names the draft's sha256; not posted before; the record's send line is the command this script runs; the
# harness's privacy scan (seed/scan.py --tree) passes the draft; a post needs a person at a terminal (stdin and stdout),
# who types the first 12 characters of the draft's sha256; with the vendored issues tracker, its redact-scan.sh --strict
# says REDACT-PASS, its noise hook and its block-gh-write.sh admit the command (the second wall: merge, close and review
# stay blocked with the token). The draft is copied once into the private directory (ISSUES_SPOKE_PRIVATE_DIR, outside
# the session's working directory) and hashed; right after the hash the verified bytes are frozen into a send body
# (EMIT) in the same directory, and the privacy scan, the redact scan, the tracker hooks and gh all read EMIT, so what
# is scanned is what is sent. EMIT is re-verified against the hash immediately before the send, so a hook that rewrote
# it during the gates sends nothing. Reads go through the read-only front; the send is the one gh write.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WD="${ISSUES_SPOKE_WD:-/wd/issues}"
TREE="${ISSUES_TRACKER_DIR:-/opt/issues-tracker}"
SESSION="${ISSUES_SPOKE_SESSION:-issues}"
# the private directory, outside the session's working directory: the one copy, the staged hooks and their logs live
# here, where the drafting session (which runs in the working directory) cannot write them with its file tools
PRIV="${ISSUES_SPOKE_PRIVATE_DIR:-${SUPERVISOR_DIR:-/wd/supervisor}/issues/private}"
GATE="${PRIV}/gate"
# the refusal/post log lives in the private directory, outside the session's working directory. A relative path from
# the session's cwd (../) can still resolve here, but the session's hook refuses any Bash command that names gate.log
# or the private directory and its file tools are denied the directory, so the session cannot forge or erase a line
GATELOG="${PRIV}/gate.log"
OUT="${WD}/outbox"
SCAN="${ISSUES_SPOKE_SCAN:-/seed/scan.py}"
[ -f "${SCAN}" ] || SCAN="${HERE}/../../../seed/scan.py"
FRONT="${HERE}/gh-ro.sh"
[ -x "${TREE}/scripts/gh-ro" ] && FRONT="${TREE}/scripts/gh-ro"
MODE=post
case "${1:-}" in --command|--check) MODE=${1#--}; shift ;; esac
NAME="${1:-}"
ts() { date -u +%FT%TZ; }
# printable ASCII for the gate log and the terminal: tabs and line breaks become spaces, every other control byte (C0,
# DEL, C1) and any other non-ASCII byte is removed, and trailing spaces are dropped
asc() { LC_ALL=C tr '\t\n\r' '   ' | LC_ALL=C tr -d '\000-\037\177-\377' | sed 's/ *$//'; }
# the gate directory is made lazily, only once a draft is about to be copied, so a post.sh that refuses early (the
# spoke's own session or cycle, a bad name) makes no gate directory and leaves only its own refusal line in the private
# gate.log. The logged reason goes through asc() and the name keeps only a safe set of characters (an absent name logs
# as ?), so neither a session-chosen name (send-line.sh passes its argument through) nor the text of a session-written
# POSTED marker can forge a second log line or put an escape sequence into the log or on a terminal.
refuse() {
	local sn="$(printf '%s' "${NAME:-?}" | LC_ALL=C tr -c 'A-Za-z0-9._?-' '_' )" sr="$(printf '%s' "$1" | asc)"
	echo "post.sh: REFUSED ${sn}: ${sr}" >&2
	mkdir -p "${PRIV:?}" 2>/dev/null && chmod 700 "${PRIV:?}" 2>/dev/null
	printf '%s REFUSED %s: %s\n' "$(ts)" "${sn}" "${sr}" >> "${GATELOG}"
	exit 2
}

# 0. a person's act: never the spoke's own session (its pane) or its cycle (the supervisor's BUS_AGENT_ID); --command
#    only prints the send line, which the session asks for through send-line.sh
if [ "${MODE}" != command ]; then
	[ "${BUS_AGENT_ID:-}" == "${SESSION}" ] && refuse "run from the ${SESSION} spoke's cycle; a person runs post.sh"
	if [ -n "${TMUX_PANE:-}" ] && command -v tmux > /dev/null; then
		[ "$(tmux display-message -p -t "${TMUX_PANE}" '#{session_name}' 2>/dev/null)" == "${SESSION}" ] \
			&& refuse "run from the ${SESSION} spoke's own session; a person runs post.sh"
	fi
fi
[[ "${NAME}" =~ ^([A-Za-z0-9-]+)\.([A-Za-z0-9._-]+)-([0-9]+)$ ]] || refuse "the name is not <owner>.<repository>-<number>"
OWNER=${BASH_REMATCH[1]} REPO=${BASH_REMATCH[2]} NUM=${BASH_REMATCH[3]}
DRAFT="${OUT}/${NAME}.md" RECORD="${OUT}/${NAME}.FILING-READY.md" GO="${OUT}/${NAME}.GO" POSTED="${OUT}/${NAME}.POSTED"
regular() { [ -f "$1" ] && [ ! -L "$1" ] && [ -s "$1" ]; }
regular "${DRAFT}" || refuse "no draft as a regular file: ${DRAFT}"
[ "$(wc -c < "${DRAFT}")" -le 60000 ] || refuse "the draft is over 60000 bytes"
# the kind of item decides the command: a read through the front
KIND=$(env ISSUES_SPOKE_WD="${WD}" "${FRONT}" api "repos/${OWNER}/${REPO}/issues/${NUM}" 2>/dev/null \
	| python3 -I -c 'import json, sys; d = json.load(sys.stdin); print("pr" if d.get("pull_request") else "issue")' 2>/dev/null)
[ -n "${KIND}" ] || refuse "${OWNER}/${REPO}#${NUM} could not be read through the read-only front"
CMD="gh ${KIND} comment ${NUM} --repo ${OWNER}/${REPO} --body-file ${DRAFT}"
if [ "${MODE}" == command ]; then echo "${CMD}"; exit 0; fi
# one private copy of the draft, made once and hashed, in the private directory outside the session's working
# directory, so the session can neither make the outbox draft diverge from what goes out nor rewrite the copy. Right
# after the hash the verified bytes are frozen into a separate send body (EMIT, below); the send body is what the
# privacy scan, the redact scan, the tracker hooks and gh read, and it is re-verified against the GO's hash
# immediately before the send. Both are removed when post.sh ends
mkdir -p "${GATE:?}" 2>/dev/null && chmod 700 "${PRIV:?}" 2>/dev/null
COPY=$(mktemp "${GATE:?}/send.XXXXXXXX") || refuse "cannot make the private copy of the draft in ${GATE}"
# the send body and the two error captures are this run's own mktemp files, so a concurrent run neither overwrites nor
# removes them, and the trap removes every one this run made
EMIT="" EMITERR="" SENDERR=""
trap 'rm -f "${COPY:?}"; [ -n "${EMIT:-}" ] && rm -f "${EMIT:?}"; [ -n "${EMITERR:-}" ] && rm -f "${EMITERR:?}"; [ -n "${SENDERR:-}" ] && rm -f "${SENDERR:?}"' EXIT
{ chmod 600 "${COPY}" && cp "${DRAFT}" "${COPY}" && regular "${COPY}"; } || refuse "cannot copy the draft"
[ "$(wc -c < "${COPY}")" -le 60000 ] || refuse "the draft is over 60000 bytes"
regular "${RECORD}" || refuse "no record as a regular file: ${RECORD}"
{ [ -f "${GO}" ] && [ ! -L "${GO}" ]; } || refuse "no GO: a person writes ${GO} naming the draft's sha256"
SHA=$(sha256sum "${COPY}" | cut -d' ' -f1)
[[ "${SHA}" =~ ^[0-9a-f]{64}$ ]] || refuse "cannot hash the draft (sha256sum gave '${SHA}')"
grep -qw "${SHA}" "${GO}" || refuse "the GO does not name the draft's sha256 ${SHA:0:12} (the draft changed after the GO, or the GO is for another draft)"
{ [ -e "${POSTED}" ] || [ -L "${POSTED}" ]; } && refuse "posted already ($(regular "${POSTED}" && head -c 200 "${POSTED}" || echo 'the POSTED marker is not a regular file')); a new reply is a new draft"
grep -qxF "send: ${CMD}" "${RECORD}" || refuse "the record has no line 'send: ${CMD}' (post.sh --command ${NAME} prints it)"
# freeze the verified send body once, right after the hash check: read the copy once, check that read against the GO's
# hash, and write exactly those bytes to EMIT. From here the privacy scan, the redact scan, the tracker hooks and gh
# all work on EMIT, so what is scanned is what is sent.
EMIT=$(mktemp "${GATE:?}/emit.XXXXXXXX") || refuse "cannot stage the send body in ${GATE}"
EMITERR=$(mktemp "${GATE:?}/emit-err.XXXXXXXX") || refuse "cannot make the staging error file in ${GATE}"
COPY="${COPY}" EMIT="${EMIT}" GOSHA="${SHA}" python3 -I - 2> "${EMITERR}" << 'PY'
import hashlib, os, sys
try:
    b = open(os.environ["COPY"], "rb").read()
    # EMIT is the mktemp file (mode 0600); write the verified bytes into it directly, no second file
    if hashlib.sha256(b).hexdigest() != os.environ["GOSHA"]:
        sys.exit(3)
    with open(os.environ["EMIT"], "wb") as f:
        f.write(b)
except OSError as e:
    sys.stderr.write(str(e))
    sys.exit(4)
PY
case $? in
	0) ;;
	3) refuse "the private copy does not match the GO's sha256; nothing staged to send" ;;
	*) refuse "could not stage the send body: $(tail -1 "${EMITERR}" 2>/dev/null | tr -d '\n')" ;;
esac
OUTP=$(python3 -I "${SCAN}" --tree "${EMIT}" 2>&1) || refuse "the privacy scan found: $(echo "${OUTP}" | head -3 | sed "s|${EMIT}|${NAME}.md|g" | tr '\n' ';')"
# a person at a terminal: the send waits for the first 12 characters of the draft's sha256, typed at the keyboard. A
# session's tool call runs without a terminal, and a GO file alone is no proof that a person was there
if [ "${MODE}" == post ]; then
	{ [ -t 0 ] && [ -t 1 ]; } || refuse "not at a terminal: a person runs post.sh in a terminal and types the draft's sha256 prefix"
	printf 'post.sh: to send %s as one comment to %s/%s#%s, type the first 12 characters of its sha256: ' "${NAME}" "${OWNER}" "${REPO}" "${NUM}"
	IFS= read -r TYPED || TYPED=""
	[ "${TYPED}" == "${SHA:0:12}" ] || refuse "the typed characters are not the draft's sha256 prefix; nothing sent"
fi
# the operator's words: the GO without its hash, one line
REASON=$(sed "s/${SHA}//g" "${GO}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' | cut -c1-200)
[ -n "${REASON}" ] || REASON="GO ${SHA:0:12}"
REASON=${REASON//\"/\'}
SEND="GH_WRITE_OPERATOR_OK=\"${REASON}\" gh ${KIND} comment ${NUM} --repo ${OWNER}/${REPO} --body-file ${EMIT}"
if [ -f "${TREE}/scripts/redact-scan.sh" ]; then
	R=$(bash "${TREE}/scripts/redact-scan.sh" --strict "${EMIT}" 2>&1)
	echo "${R}" | grep -q "REDACT-PASS" || refuse "the issues tracker's redact-scan.sh --strict did not pass: $(echo "${R}" | tail -2 | tr '\n' ';')"
fi
# the issues tracker's hooks, as Claude Code would run them on the send, from copies in the private directory (their
# logs land there, not in the image's tree and not where the session could reach them; block-gh-write.sh's audit line
# goes to the private gate/gh-write-audit.log, which it would otherwise put two directories above the copy)
for H in pretooluse-block-comment-noise.sh block-gh-write.sh; do  # 0.1.9 renamed the noise hook (was pretooluse-block-autopilot-noise.sh)
	[ -f "${TREE}/.claude/hooks/${H}" ] || continue
	mkdir -p "${GATE:?}/home" && cp "${TREE}/.claude/hooks/${H}" "${GATE:?}/${H}" || refuse "cannot stage the hook ${H}"
	P=$(SEND="${SEND}" python3 -I -c 'import json, os; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": os.environ["SEND"]}}))')
	echo "${P}" | HOME="${GATE}/home" GH_WRITE_AUDIT_LOG="${GATE}/gh-write-audit.log" bash "${GATE}/${H}" > "${GATE}/${H}.out" 2>&1 \
		|| refuse "the issues tracker's ${H} blocked the send: $(tail -2 "${GATE}/${H}.out" | tr '\n' ';')"
done
if [ "${MODE}" == check ]; then echo "post.sh: ${NAME} passes every gate; it would run: ${SEND}"; exit 0; fi
# the send's error capture is made before the re-verify, so nothing runs between the re-verify and the send
SENDERR=$(mktemp "${GATE:?}/send-err.XXXXXXXX") || refuse "cannot make the send error file in ${GATE}"
# re-verify the staged send body immediately before the send: a tracker hook that rewrote EMIT during the gates sends
# nothing. The residual window between this check and gh opening EMIT needs write access to the private directory,
# which the session does not have; the stated residual is a person-approved Bash command.
EMIT="${EMIT}" GOSHA="${SHA}" python3 -I -c 'import hashlib, os, sys; sys.exit(0 if hashlib.sha256(open(os.environ["EMIT"], "rb").read()).hexdigest() == os.environ["GOSHA"] else 3)' \
	|| refuse "the send body changed after it was staged; nothing sent"
# the one write, from the verified bytes; a failure logs gh's whole error output, made printable ASCII by asc()
URL=$(GH_WRITE_OPERATOR_OK="${REASON}" gh "${KIND}" comment "${NUM}" --repo "${OWNER}/${REPO}" --body-file "${EMIT}" 2> "${SENDERR}") \
	|| { SE=$(asc < "${SENDERR}"); printf '%s FAILED %s: %s\n' "$(ts)" "${NAME}" "${SE}" >> "${GATELOG}"; echo "post.sh: the send failed: ${SE}" >&2; exit 1; }
URL=$(echo "${URL}" | tail -1)
# the read-back, through the front: the author, and the body byte for byte
CID=${URL##*issuecomment-}
BACK=$(env ISSUES_SPOKE_WD="${WD}" "${FRONT}" api "repos/${OWNER}/${REPO}/issues/comments/${CID}" 2>/dev/null)
LOGIN=${ISSUES_GH_LOGIN:-$(env ISSUES_SPOKE_WD="${WD}" "${FRONT}" api user --jq .login 2>/dev/null)}
VERDICT=$(BACK="${BACK}" python3 -I - "${DRAFT}" "${LOGIN}" "${URL}" "${SHA}" "${POSTED}" "$(ts)" << 'PY'
import hashlib, json, os, sys
draft, login, url, sha, posted, ts = sys.argv[1:7]
try:
    b = json.loads(os.environ["BACK"])
except ValueError:
    b = {}
body = (b.get("body") or "").encode()
same = hashlib.sha256(body).hexdigest() == sha
who = (b.get("user") or {}).get("login")
rec = {"ts": ts, "url": url, "sha256": sha, "author": who, "author_is_login": who == login, "read_back_matches": same}
with open(posted, "w") as f:
    json.dump(rec, f, sort_keys=True)
    f.write("\n")
print("verified" if same and who == login else "UNVERIFIED")
PY
)
printf '%s POSTED %s %s sha256 %s %s\n' "$(ts)" "${NAME}" "${URL}" "${SHA:0:12}" "${VERDICT}" >> "${GATELOG}"
python3 -I -c 'import json, sys; print(json.dumps({"ts": sys.argv[1], "kind": "notice", "text": sys.argv[2]}))' "$(ts)" \
	"${OWNER}/${REPO}#${NUM}: a person posted the staged reply ${NAME} (${URL}, read-back ${VERDICT})" >> "${WD}/notices.jsonl"
echo "post.sh: posted ${URL} (${VERDICT})"
[ "${VERDICT}" == verified ] || exit 1
