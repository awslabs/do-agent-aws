#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the issues spoke (docs/AGENT-STACK.md section 7; /agent/charters/issues/): its registry entry, its
# read-only front, its waiting state, one cycle against a recording GitHub stub, its answer to the hub over the bus, and
# the GO gate. Fully OFFLINE: a stub gh that serves fixtures and records every call; a test-local registry, supervisor,
# journal and working directories under /tmp/issues-spoke-smoke (or TEST_ISSUES_DIR); nothing under /wd.
#
# Properties proven (each check FAILS if the property is removed):
#   1 [registry-entry]. the shipped registry has the issues spoke on by default, its flag SPOKE_ISSUES, /wd/issues, its
#      pane (pane.sh), charter, cycle and vendored source in the image, a 900 s cadence, parent agent and the Board tile; spoke.sh check
#      passes it; settings.example.json is JSON; its three UIs, as the home page titles them (the Board, the Goals board
#      and the Project board (Plane)), are tiles the home page renders and are named in the charter, and in
#      docs/AGENT-STACK.md section 7 where the docs are at hand
#   2 [front-refuses-writes]. loop.sh --self-test: every write form (comment, merge, close, review, create, a gh api
#      method, field or input flag, graphql) refused before gh runs, and reads reach it; gh-ro.sh also refuses graphql
#      in any letter case or form and any host but github.com
#   3 [waiting-for-github]. under the supervisor, with GH_TOKEN unset, the spoke reads "waiting for GitHub (GH_TOKEN)" and
#      keeps it for three passes; its cycle never runs (the stub records no call), it is never restarted (no restart
#      line beside its start) and its row says how to set it
#   4 [cycle-rows-read-only]. one cycle against the fixtures: status.json and STATUS.md carry the conflicting pull request
#      and the two items that need a reply; every call the stub recorded is a read, and the front refused nothing; the
#      first cycle sends one summary notice, the second none; a read that fails makes the scan PARTIAL (exit 1, the last
#      complete scan kept)
#   4b [named-repos-own-scan]. the scope decides the scan: with repositories named, the spoke's own scan reads them
#      even where a vendored tree is (its scan inventories the login's own items); with none named, the vendored tree's
#      scan runs (a planted tree)
#   5 [hub-asks-conflicting]. under the supervisor with a planted GH_TOKEN, the hub's request "which pull requests are
#      conflicting?" gets the spoke's reply from its cycle, with reply_to, naming the conflicting pull request
#   6 [go-gate]. post.sh: a planted draft with no GO is refused and stays, a GO naming another sha256 is refused, a draft
#      with a token shape is refused with a matching GO, and so are a symlinked draft, one over 60000 bytes, an empty
#      GO, a record with another send line, a draft whose hash cannot be taken and, with a planted tracker tree, a
#      draft its redact-scan.sh refuses, all without a write; the matching GO is refused without a
#      terminal and at a terminal where other characters are typed; typed, its sha256 prefix sends exactly one comment
#      from post.sh's private copy (a draft that a planted hook rewrites during the gates goes out as hashed),
#      read back and recorded POSTED; a second run is refused; post.sh refuses to run as the spoke's cycle; it writes
#      nothing outside its working directory; with the vendored issues tracker, its block-gh-write.sh's audit line is in
#      the gate's directory, and it blocks merge and close even with the operator token; shared-settings.sh adds the
#      deny rules on post.sh and the GO files to every session's settings once, and startup.sh runs it before the agent
#      session
#   6b [session-walls]. on a tmux server whose environment holds GH_TOKEN, GITHUB_TOKEN, GITHUB_PERSONAL_ACCESS_TOKEN and
#      GH_WRITE_OPERATOR_OK, the issues pane's claude has none of them, its gh an empty configuration directory of its
#      own, and it runs without the hub's permission bypass; its
#      .claude/settings.json denies the GitHub plugin's tools, a bare gh, curl, post.sh, /proc, the GO files and its own
#      files, and registers session-hook.sh; the hook refuses the operator token, post.sh, a GO file and the tmux
#      server's environment, lets a read and send-line.sh through, and with the vendored tree its block-gh-write.sh
#      refuses a comment, a gh api POST and the plugin's write tool; send-line.sh prints the send line from the pane,
#      where post.sh is refused
#   7. in the test container (TEST_CONTAINER=true) nothing is left under /wd. PLANTED CONTROL: an entry planted there is
#      named

fail()
{
	echo "Test-issues-spoke FAILED: $1"
	exit 1
}
unset TMUX TMUX_PANE BUS_AGENT_ID GH_TOKEN GITHUB_TOKEN ISSUES_REPOS ISSUES_GH_LOGIN

D=${TEST_ISSUES_DIR:-/tmp/issues-spoke-smoke}
# the directory is removed and made again, so it must be one named issues-spoke*, never a path that is merely set
case "$(basename "${D}")" in issues-spoke*) ;; *) fail "TEST_ISSUES_DIR must name a directory issues-spoke*, not '${D}'" ;; esac
rm -rf "${D:?}"
mkdir -p "${D}/bin"
find /wd -mindepth 1 2>/dev/null | sort > "${D}/wd-before.txt"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
CH="${AGENT_DIR}/charters/issues"
SPOKE="${AGENT_DIR}/spoke.sh"
SHIPPED_REGISTRY="${AGENT_DIR}/spokes/registry.json"
SESSIONS="tis-issues tis-sup"
cleanup()
{
	[ -f "${D}/sup/supervisor.pid" ] && kill "$(cat "${D}/sup/supervisor.pid")" 2>/dev/null
	for S in ${SESSIONS}; do tmux kill-session -t "=${S}" 2>/dev/null; done
	env -u TMUX -u TMUX_PANE TMUX_TMPDIR="${D}/tmux-walls" tmux kill-session -t "=tis-walls" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# the GitHub stub: every call one JSON line of STUB_GH_LOG; the stub repository o/r has a conflicting pull request of the
# login's with a failing check and another person's word after the login's (pull request 7), a clean one whose last word
# is the login's (pull request 8) and an issue nobody but its author answered (issue 9); a comment is recorded and served
# back to the read-back
cat > "${D}/bin/gh" << 'STUB'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
log = os.environ["STUB_GH_LOG"]
with open(log, "a") as f:
    f.write(json.dumps(a) + "\n")
me = "ada-dev"
def out(x):
    print(x if isinstance(x, str) else json.dumps(x))
    sys.exit(0)
def flag(name):
    return a[a.index(name) + 1] if name in a else None
def pr(n, author, merge, mergeable, checks, comments, review=None):
    return {"number": n, "title": f"pull request {n}", "url": f"https://github.com/o/r/pull/{n}", "state": "OPEN",
            "author": {"login": author}, "isDraft": False, "updatedAt": "2026-10-14T10:00:00Z", "mergeable": mergeable,
            "mergeStateStatus": merge, "reviewDecision": review, "statusCheckRollup": checks,
            "comments": [{"author": {"login": w}, "createdAt": t} for w, t in comments], "latestReviews": []}
FIX = {("pr", "7"): pr(7, me, "DIRTY", "CONFLICTING", [{"name": "build", "status": "COMPLETED", "conclusion": "FAILURE"}],
                       [(me, "2026-10-13T09:00:00Z"), ("rev-b", "2026-10-14T09:30:00Z")], "CHANGES_REQUESTED"),
       ("pr", "8"): pr(8, "someone-else", "CLEAN", "MERGEABLE", [{"name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"}],
                       [("someone-else", "2026-10-14T08:00:00Z"), (me, "2026-10-14T08:30:00Z")]),
       ("issue", "9"): {"number": 9, "title": "issue 9", "url": "https://github.com/o/r/issues/9", "state": "OPEN",
                        "author": {"login": "reporter-c"}, "updatedAt": "2026-10-14T07:00:00Z",
                        "comments": [{"author": {"login": "reporter-c"}, "createdAt": "2026-10-14T07:00:00Z"}]}}
if os.environ.get("STUB_GH_FAIL_VIEW") and a[:2] == ["issue", "view"]:
    print("HTTP 502: planted failure", file=sys.stderr)
    sys.exit(1)
if a[:2] == ["api", "user"]:
    out(me)
if a[:2] in (["pr", "list"], ["issue", "list"]):
    out([{"number": 7}, {"number": 8}] if a[0] == "pr" else [{"number": 9}])
if a[:1] == ["search"]:
    out([])
if a[:2] in (["pr", "view"], ["issue", "view"]) and (a[0], a[2]) in FIX:
    out(FIX[(a[0], a[2])])
if a[:1] == ["api"] and a[1].startswith("repos/o/r/pulls/") and "/comments" in a[1]:
    out("[]")
if a[:1] == ["api"] and a[1].startswith("repos/o/r/issues/comments/"):
    rec = json.load(open(log + ".posted"))
    out({"id": 1001, "user": {"login": me}, "body": rec["body"], "html_url": rec["url"]})
if a[:1] == ["api"] and a[1].startswith("repos/o/r/issues/"):
    n = a[1].rsplit("/", 1)[1]
    out({"number": int(n), "pull_request": {"url": "x"}} if n in ("7", "8") else {"number": int(n)})
if a[:2] in (["pr", "comment"], ["issue", "comment"]):
    body = open(flag("--body-file")).read()
    url = f"https://github.com/{flag('--repo')}/{'pull' if a[0] == 'pr' else 'issues'}/{a[2]}#issuecomment-1001"
    json.dump({"body": body, "url": url}, open(log + ".posted", "w"))
    out(url)
print(f"stub gh: no fixture for {a}", file=sys.stderr)
sys.exit(1)
STUB
chmod +x "${D}/bin/gh"
# writes <log> - the recorded calls that are not reads, one a line (an independent reading of gh's grammar: list, view,
# search, auth status, and api with a path and no method, field or input flag)
writes()
{
	python3 - "$1" << 'PY'
import json, sys
for line in open(sys.argv[1]):
    a = json.loads(line)
    read = (a[:1] in (["pr"], ["issue"]) and a[1:2] in (["list"], ["view"])) or a[:1] == ["search"] or a[:2] == ["auth", "status"] \
        or (a[:1] == ["api"] and a[1:2] != ["graphql"] and not any(x in ("-X", "--method", "-f", "-F", "--field", "--raw-field", "--input")
                                                                     or x.startswith(("-X", "--method=", "-f", "-F", "--field=", "--raw-field=", "--input="))
                                                                     for x in a[2:]))
    if not read:
        print(" ".join(a))
PY
}

# --- 1. the registry entry ---
python3 - "${SHIPPED_REGISTRY}" "${AGENT_DIR}" << 'PY' || fail "registry-entry: the shipped issues entry is not the decided one"
import json, os, sys
reg, agent = sys.argv[1:3]
e = next(x for x in json.load(open(reg))["sessions"] if x["session_name"] == "issues")
want = {"role": "spoke", "flag": "SPOKE_ISSUES", "enabled": True, "workdir": "/wd/issues", "parent": "agent",
        "launch_cmd": "/agent/charters/issues/pane.sh", "charter": "/agent/charters/issues/charter.md",
        "cycle": "/agent/charters/issues/loop.sh", "cadence_sec": 900, "source": "vendored: /opt/issues-tracker",
        "title": "Issues spoke", "tile": "Board", "agent_process": "claude"}
bad = {k: (e.get(k), v) for k, v in want.items() if e.get(k) != v}
assert not bad, bad
# what it writes outside its working directory: the private directory of the shim, the gate log and the gate's copies
assert "/wd/supervisor/issues/private/" in e["writes"], ("the writes list does not name the private directory", e["writes"])
for x in ("loop.sh", "post.sh", "pane.sh", "session-hook.sh", "send-line.sh"):
    assert os.access(os.path.join(agent, "charters/issues", x), os.X_OK), x
json.load(open(os.path.join(agent, "charters/issues/session-settings.json")))
PY
TREE=/opt/issues-tracker
[ -d "${TREE}" ] || TREE="${BASE_DIR%/}/opt/issues-tracker"
[ -f "${TREE}/VENDORED.md" ] || fail "registry-entry: the vendored source has no VENDORED.md (${TREE})"
OUT=$(SPOKES_REGISTRY=${SHIPPED_REGISTRY} AGENT_TMUX_SESSION_NAME=agent "${SPOKE}" check issues 2>&1) || fail "registry-entry: spoke.sh check refuses the issues entry: ${OUT}"
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "${CH}/settings.example.json" || fail "registry-entry: settings.example.json is not JSON"
# its UIs, as the home page titles them: each a tile home-render.sh renders, the three named in the charter, and in the
# agent stack's section 7 where the docs are at hand (the image's /docs, or a checkout's docs/)
UIS="the home page's Board, the Goals board and the Project board (Plane)"
for T in "Board" "Goals board" "Project board (Plane)"; do
	grep -qF "\"${T}\"" "${AGENT_DIR}/home-render.sh" || fail "registry-entry: the home page renders no tile titled '${T}'"
done
grep -qF "Its UIs are ${UIS}." "${CH}/charter.md" || fail "registry-entry: the charter does not name its UIs: 'Its UIs are ${UIS}.'"
DOCS=""
for DC in "${BASE_DIR%/}/../docs" /docs; do [ -f "${DC}/AGENT-STACK.md" ] && DOCS=$(cd "${DC}" && pwd) && break; done
UIDOC="(no docs/AGENT-STACK.md here)"
if [ -n "${DOCS}" ]; then
	grep -qF "**Its UIs.** The Board, the Goals board and the Project board (Plane) are this spoke's UIs." "${DOCS}/AGENT-STACK.md" \
		|| fail "registry-entry: docs/AGENT-STACK.md section 7 does not name the spoke's UIs (${DOCS}/AGENT-STACK.md)"
	UIDOC="and in docs/AGENT-STACK.md section 7"
fi
echo "ok 1 [registry-entry] - the issues spoke is on by default (SPOKE_ISSUES), /wd/issues, charter, cycle and post.sh executable, cadence 900 s, source vendored: /opt/issues-tracker (${TREE}/VENDORED.md), parent agent, the Board tile, its writes naming the private directory; spoke.sh check passes it; its UIs, the Board, the Goals board and the Project board (Plane), are home page tiles named in the charter ${UIDOC}"

# --- 2. the read-only front ---
# the private directory holds the gh shim, which the cycle executes, so it must be on an exec filesystem: here under
# ${D} (the test's own tree), as in the container it is under the supervisor's directory on the exec /wd bind mount
OUT=$(ISSUES_SPOKE_WD=${D}/front ISSUES_SPOKE_PRIVATE_DIR=${D}/front-private bash "${CH}/loop.sh" --self-test 2>&1)
RC=$?
{ [ ${RC} -eq 0 ] && ! echo "${OUT}" | grep -q '^FAIL'; } || fail "front-refuses-writes: loop.sh --self-test (rc ${RC}): $(echo "${OUT}" | grep -E '^FAIL' | head -3)"
NREF=$(echo "${OUT}" | grep -c '^PASS refused')
[ "${NREF}" -ge 16 ] || fail "front-refuses-writes: the self-test refused only ${NREF} write forms"
# the front beside the charter, gh-ro.sh, also refuses graphql in any letter case or form and any host but github.com,
# none of them reaching gh, and lets a read on github.com through
mkdir -p "${D}/front2-bin" && printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/front2-calls.log"\necho "{}"\n' "${D}" > "${D}/front2-bin/gh" && chmod +x "${D}/front2-bin/gh"
for F in "api graphql/" "api GraphQL" "api /graphql?query=x" "api --hostname evil.example repos/o/r" "api --hostname=evil.example repos/o/r"; do
	# shellcheck disable=SC2086 # the form is the argument list, split on purpose
	OUT2=$(ISSUES_SPOKE_WD=${D}/front2 PATH="${D}/front2-bin:${PATH}" bash "${CH}/gh-ro.sh" ${F} 2>&1) && fail "front-refuses-writes: gh-ro.sh let 'gh ${F}' through: ${OUT2}"
done
[ -e "${D}/front2-calls.log" ] && fail "front-refuses-writes: a refused form reached gh: $(head -3 "${D}/front2-calls.log")"
OUT2=$(ISSUES_SPOKE_WD=${D}/front2 PATH="${D}/front2-bin:${PATH}" bash "${CH}/gh-ro.sh" api --hostname github.com repos/o/r/issues/1 2>&1) \
	|| fail "front-refuses-writes: gh-ro.sh refused a read with --hostname github.com: ${OUT2}"
echo "ok 2 [front-refuses-writes] - loop.sh --self-test: ${NREF} write forms refused before gh, none reached it, reads passed ($(echo "${OUT}" | sed -n 's/^front: //p')); gh-ro.sh also refused graphql/, GraphQL, /graphql?query and another host, and let a read on github.com through"

# --- 3. waiting for GitHub: no GH_TOKEN, no cycle ---
command -v tmux > /dev/null || fail "tmux is not installed"
# the shipped entry under a test-local name, beside the hub and the supervisor, with a short cadence
python3 - "${SHIPPED_REGISTRY}" "${D}/registry.json" "${D}" << 'PY' || fail "could not write the test registry"
import json, sys
src, dst, d = sys.argv[1:4]
doc = json.load(open(src))
keep = []
for e in doc["sessions"]:
    if e["role"] == "hub":
        keep.append(dict(e, session_name="tis-hub"))
    elif e["role"] == "supervisor":
        keep.append(dict(e, session_name="tis-sup", cooldown_sec=2))
    elif e["session_name"] == "issues":
        keep.append(dict(e, session_name="tis-issues", flag="SPOKE_TIS_ISSUES", workdir=f"{d}/wd/tis-issues", parent="tis-hub",
                         cadence_sec=2, cooldown_sec=2))
json.dump(dict(doc, sessions=keep), open(dst, "w"), indent=1)
PY
mkdir -p "${D}/claude-stub" "${D}/claude-config"
printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "${D}/claude-stub/claude"
chmod +x "${D}/claude-stub/claude"
SUP="${AGENT_DIR}/supervisor.sh"
BUS="${AGENT_DIR}/bus.sh"
SUP_ENV=(SPOKES_REGISTRY="${D}/registry.json" SUPERVISOR_DIR="${D}/sup" MAILBOX_STATE_ROOT="${D}/mailbox-state" MAILBOX_PROJECTION_ROOT="${D}/mailbox"
	AGENT_TMUX_SESSION_NAME=tis-hub AGENT_TMUX_SESSION=false SUPERVISOR=true SUPERVISOR_INTERVAL=1 SUPERVISOR_START_GRACE=10
	UI_START=false UI_HINDSIGHT=false UI_CLAUDE_MEM=false CLAUDE_BIN="${D}/claude-stub/claude" CLAUDE_CONFIG_DIR="${D}/claude-config"
	TMUX_AGENT_HOME="${D}/tmux-agent-home" SPOKE_TIS_ISSUES=true PATH="${D}/bin:${PATH}" STUB_GH_LOG="${D}/sup-gh.jsonl"
	ISSUES_REPOS=o/r ISSUES_SPOKE_PACE_SEC=0 ISSUES_TRACKER_DIR="${D}/no-tree")
tmux new-session -d -s tis-sup "sleep 900" || fail "could not start the supervisor's session"
: > "${D}/sup-gh.jsonl"
state() { python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["sessions"]["tis-issues"]; print(s["state"], s["why"], sep=": ")' "${D}/sup/status.json" 2>/dev/null; }
pass_no() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pass"])' "${D}/sup/status.json" 2>/dev/null; }
OUT=$(env -u GH_TOKEN "${SUP_ENV[@]}" "${SUP}" start 2>&1) || fail "waiting-for-github: supervisor.sh start: ${OUT}"
WANT='waiting: waiting for GitHub (GH_TOKEN)'
for I in $(seq 1 25); do [ "$(state)" == "${WANT}" ] && break; sleep 1; done
[ "$(state)" == "${WANT}" ] || fail "waiting-for-github: with GH_TOKEN unset the spoke reads '$(state)', not '${WANT}'"
P0=$(pass_no)
for I in $(seq 1 30); do [ "$(pass_no)" -ge $((P0 + 3)) ] 2>/dev/null && break; sleep 1; done
[ "$(pass_no)" -ge $((P0 + 3)) ] 2>/dev/null || fail "waiting-for-github: the supervisor did not finish three passes"
[ "$(state)" == "${WANT}" ] || fail "waiting-for-github: the spoke left the waiting state with GH_TOKEN unset: '$(state)'"
[ -s "${D}/sup-gh.jsonl" ] && fail "waiting-for-github: its cycle called gh while it waited: $(head -2 "${D}/sup-gh.jsonl")"
[ -e "${D}/wd/tis-issues/status.json" ] && fail "waiting-for-github: a cycle wrote status.json while it waited"
RL=${D}/sup/tis-issues/restarts.log
grep -q ' start: ' "${RL}" 2>/dev/null || fail "waiting-for-github: the supervisor logged no start of the spoke (no control): $(cat "${RL}" 2>&1)"
[ "$(grep -c ' restart ' "${RL}")" == "0" ] || fail "waiting-for-github: the waiting spoke was restarted: $(grep ' restart ' "${RL}" | head -2)"
ROW=$(env -u GH_TOKEN "${SUP_ENV[@]}" "${SUP}" status 2>&1 | grep '^spoke tis-issues:')
[ "${ROW}" == "spoke tis-issues: WAITING session=tis-issues - waiting for GitHub (GH_TOKEN); set GH_TOKEN in .env.local, then ./stop.sh && ./run.sh" ] \
	|| fail "waiting-for-github: the status row does not say what it waits for and how to set it: ${ROW}"
env "${SUP_ENV[@]}" "${SUP}" stop > /dev/null 2>&1
echo "ok 3 [waiting-for-github] - with GH_TOKEN unset the spoke read '${WANT}' for three more passes, its cycle never called gh, it was never restarted, and its row says to set GH_TOKEN in .env.local"

# --- 4. one cycle against the fixtures: the rows, reads only, the notices, a partial scan ---
CY=${D}/cycle
CYP=${D}/cycle-private
mkdir -p "${CY}"
# the spoke's own scan, whatever the image vendors: the stub serves its reads (the vendored scan has its owner's tests).
# the private directory, where the shim lives, is outside the cycle's working directory CY
CY_ENV=(ISSUES_SPOKE_WD="${CY}" ISSUES_SPOKE_PRIVATE_DIR="${CYP}" PATH="${D}/bin:${PATH}" STUB_GH_LOG="${D}/cycle-gh.jsonl" ISSUES_REPOS=o/r ISSUES_SPOKE_PACE_SEC=0 GH_TOKEN=planted
	ISSUES_TRACKER_DIR="${D}/no-tree")
: > "${D}/cycle-gh.jsonl"
OUT=$(env "${CY_ENV[@]}" bash "${CH}/loop.sh" 2>&1) || fail "cycle-rows-read-only: one cycle failed: ${OUT}"
python3 - "${CY}/status.json" << 'PY' || fail "cycle-rows-read-only: status.json does not carry the planted rows: $(head -c 600 "${CY}/status.json" 2>&1)"
import json, sys
d = json.load(open(sys.argv[1]))
s = d["sets"]
assert d["complete"] is True and d["login"] == "ada-dev", d.get("login")
assert s["conflicting"] == ["o/r#7"] and s["checks_failing"] == ["o/r#7"] and s["changes_requested"] == ["o/r#7"], s
assert s["needs_reply"] == ["o/r#7", "o/r#9"], s
r7 = next(r for r in d["items"] if r["number"] == 7)
assert r7["last_them"]["who"] == "rev-b" and r7["is_ours"] is True, r7
PY
grep -qF '## Conflicting pull requests (1)' "${CY}/STATUS.md" && grep -qF '| [o/r#7](https://github.com/o/r/pull/7) |' "${CY}/STATUS.md" \
	&& grep -qF 'last word by reporter-c at 2026-10-14T07:00:00Z' "${CY}/STATUS.md" || fail "cycle-rows-read-only: STATUS.md lacks the conflict or the reply rows: $(head -30 "${CY}/STATUS.md")"
N=$(grep -c . "${D}/cycle-gh.jsonl")
[ "${N}" -ge 6 ] || fail "cycle-rows-read-only: the stub recorded only ${N} calls"
W=$(writes "${D}/cycle-gh.jsonl")
[ -z "${W}" ] || fail "cycle-rows-read-only: the cycle made a call that is not a read: ${W}"
[ -e "${CY}/refusals.log" ] && fail "cycle-rows-read-only: the cycle tried a call the front refused: $(head -3 "${CY}/refusals.log")"
[ "$(grep -c . "${CY}/notices.jsonl")" == "1" ] && grep -q 'issues: first scan - 1 conflicting pull requests' "${CY}/notices.jsonl" \
	|| fail "cycle-rows-read-only: the first cycle did not send one summary notice: $(cat "${CY}/notices.jsonl" 2>&1)"
OUT=$(env "${CY_ENV[@]}" bash "${CH}/loop.sh" 2>&1) || fail "cycle-rows-read-only: the second cycle failed: ${OUT}"
[ "$(grep -c . "${CY}/notices.jsonl")" == "1" ] || fail "cycle-rows-read-only: a second cycle with nothing changed sent a notice: $(tail -2 "${CY}/notices.jsonl")"
# the cycle's gh shim is in the private directory, outside the session's working directory, and is rewritten each cycle,
# so an edit the drafting session could make to it never survives to run
[ -x "${CYP}/gh-front/gh" ] || fail "cycle-rows-read-only: the cycle's gh shim is not in the private directory: $(ls -a "${CYP}" 2>&1 | tr '\n' ' ')"
[ -e "${CY}/.gh-front" ] && fail "cycle-rows-read-only: the shim is in the session's working directory, where the session could rewrite it"
printf '#!/bin/bash\ntouch "%s/planted-shim-ran"\n' "${D}" > "${CYP}/gh-front/gh"
OUT=$(env "${CY_ENV[@]}" bash "${CH}/loop.sh" 2>&1) || fail "cycle-rows-read-only: a cycle after a planted shim failed: ${OUT}"
[ -e "${D}/planted-shim-ran" ] && fail "cycle-rows-read-only: a planted shim ran in the next cycle (loop.sh did not rewrite it first)"
grep -qF 'exec "${ISSUES_SPOKE_FRONT' "${CYP}/gh-front/gh" || fail "cycle-rows-read-only: loop.sh did not overwrite the planted shim with the real front: $(head -3 "${CYP}/gh-front/gh")"
# a read that fails: the scan is PARTIAL, the cycle exits 1, status.json keeps the last complete scan
cp "${CY}/status.json" "${D}/status-before.json"
OUT=$(env "${CY_ENV[@]}" STUB_GH_FAIL_VIEW=1 bash "${CH}/loop.sh" 2>&1) && fail "cycle-rows-read-only: a cycle with a failing read exited 0: ${OUT}"
cmp -s "${CY}/status.json" "${D}/status-before.json" || fail "cycle-rows-read-only: a partial scan overwrote status.json"
[ -f "${CY}/status.partial.json" ] && grep -q "This cycle's scan failed" "${CY}/STATUS.md" || fail "cycle-rows-read-only: a partial scan is not parked and named: $(head -5 "${CY}/STATUS.md")"
echo "ok 4 [cycle-rows-read-only] - one cycle: o/r#7 conflicting, failing and changes requested, o/r#7 and o/r#9 need a reply (last word by rev-b, by reporter-c); ${N} calls, every one a read, none refused; one summary notice, none on a second cycle; a failing read made the scan PARTIAL (exit 1, status.json kept, status.partial.json parked)"

# --- 4b. the scope decides the scan: repositories named are read by the spoke's own scan even where the vendored tree is
#         (its scan inventories the login's own items, not a repository's); with none named, the vendored tree's scan
#         runs. A planted tree: the front beside the charter as its scripts/gh-ro, and a gh-dashboard.py that records
#         its run and finds nothing ---
PT=${D}/planted-tree
mkdir -p "${PT}/scripts"
cp "${CH}/gh-ro.sh" "${PT}/scripts/gh-ro" && chmod +x "${PT}/scripts/gh-ro" || fail "could not plant a vendored tree"
cat > "${PT}/scripts/gh-dashboard.py" << 'PY'
import json, pathlib
OUT_DIR = pathlib.Path("/nonexistent")
def main():
    OUT_DIR.mkdir(exist_ok=True)
    (OUT_DIR / "planted-scan-ran").write_text("yes\n")
    json.dump({"generated": "planted", "items": []}, open(OUT_DIR / "state.json", "w"))
PY
CN=${D}/cycle-named
OUT=$(env "${CY_ENV[@]}" ISSUES_SPOKE_WD="${CN}" ISSUES_TRACKER_DIR="${PT}" bash "${CH}/loop.sh" 2>&1) || fail "named-repos-own-scan: a cycle with o/r named and a vendored tree failed: ${OUT}"
python3 - "${CN}/status.json" << 'PY' || fail "named-repos-own-scan: with o/r named and a vendored tree the cycle did not read o/r with its own scan: $(tail -1 "${CN}/cycle.log" 2>&1)"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["source"] == "the spoke's own scan" and d["sets"]["conflicting"] == ["o/r#7"], (d["source"], d["sets"])
PY
[ -e "${CN}/dashboard/planted-scan-ran" ] && fail "named-repos-own-scan: with o/r named the vendored tree's scan ran"
CV=${D}/cycle-vendored
OUT=$(env "${CY_ENV[@]}" ISSUES_SPOKE_WD="${CV}" ISSUES_TRACKER_DIR="${PT}" ISSUES_REPOS= bash "${CH}/loop.sh" 2>&1) || fail "named-repos-own-scan: a cycle with no repository named and a vendored tree failed: ${OUT}"
[ -e "${CV}/dashboard/planted-scan-ran" ] && grep -q ' source=vendored ' "${CV}/cycle.log" \
	|| fail "named-repos-own-scan: with no repository named the vendored tree's scan did not run: $(tail -1 "${CV}/cycle.log" 2>&1)"
echo "ok 4b [named-repos-own-scan] - with o/r named, the spoke's own scan read it (o/r#7 conflicting) beside a vendored tree, whose scan did not run; with no repository named, the vendored tree's scan ran"

# --- 5. the hub asks which pull requests conflict; the spoke's cycle answers from its scan ---
OUT=$(env "${SUP_ENV[@]}" GH_TOKEN=planted "${SUP}" start 2>&1) || fail "hub-asks-conflicting: supervisor.sh start with GH_TOKEN: ${OUT}"
for I in $(seq 1 30); do state | grep -q '^live: ' && break; sleep 1; done
state | grep -q '^live: ' || fail "hub-asks-conflicting: with GH_TOKEN set the spoke did not go live: '$(state)' $(tail -3 "${D}/sup/tis-issues/cycle.out" 2>&1)"
J=${D}/mailbox-state/journal/000001.jsonl
Q=$(echo "which pull requests are conflicting?" | env "${SUP_ENV[@]}" BUS_AGENT_ID=tis-hub "${BUS}" request tis-issues) || fail "hub-asks-conflicting: bus.sh request: ${Q}"
A=""
for I in $(seq 1 20); do
	A=$(python3 - "${J}" "${Q}" << 'PY'
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    r = (e.get("details") or {}).get("env") or {}
    if e.get("event") == "message.accepted" and r.get("reply_to") == sys.argv[2] and r.get("from") == "tis-issues" and r.get("to") == "tis-hub":
        print(r["text"])
PY
)
	[ -n "${A}" ] && break
	sleep 1
done
env "${SUP_ENV[@]}" "${SUP}" stop > /dev/null 2>&1
[ -n "${A}" ] || fail "hub-asks-conflicting: the spoke's cycle did not answer the hub within 20 s: $(tail -5 "${D}/sup/tis-issues/cycle.out" 2>&1)"
echo "${A}" | grep -q '^conflicting pull requests as of the scan of .*: 1: o/r#7 pull request 7' || fail "hub-asks-conflicting: the answer does not name o/r#7: ${A}"
W=$(writes "${D}/sup-gh.jsonl")
[ -z "${W}" ] || fail "hub-asks-conflicting: a cycle under the supervisor made a call that is not a read: ${W}"
echo "ok 5 [hub-asks-conflicting] - with GH_TOKEN set the spoke went live; the hub's request got the cycle's reply (reply_to set): '${A:0:120}'"

# --- 6. the GO gate ---
G=${D}/gate-wd
GP=${D}/gate-private
mkdir -p "${G}/outbox"
PO="${CH}/post.sh"
# the private directory, where post.sh keeps its one copy and the staged hooks, is outside the session's working
# directory G
GATE_ENV=(ISSUES_SPOKE_WD="${G}" ISSUES_SPOKE_PRIVATE_DIR="${GP}" PATH="${D}/bin:${PATH}" STUB_GH_LOG="${D}/gate-gh.jsonl" ISSUES_GH_LOGIN=ada-dev)
: > "${D}/gate-gh.jsonl"
touch "${D}/gate-start"
N7=o.r-7
printf 'Thanks for the review: the conflict is resolved on the branch and the failing build passes again.\n' > "${G}/outbox/${N7}.md"
CMD=$(env "${GATE_ENV[@]}" bash "${PO}" --command "${N7}" 2>&1) || fail "go-gate: post.sh --command: ${CMD}"
[ "${CMD}" == "gh pr comment 7 --repo o/r --body-file ${G}/outbox/${N7}.md" ] || fail "go-gate: the send command is '${CMD}'"
printf '# o/r#7\nevidence: the planted fixture\nsend: %s\n' "${CMD}" > "${G}/outbox/${N7}.FILING-READY.md"
SHA=$(sha256sum "${G}/outbox/${N7}.md" | cut -d' ' -f1)
gate() { env "${GATE_ENV[@]}" bash "${PO}" "$@" 2>&1; }
# ttyrun <typed line> <name> - post.sh on a pseudo-terminal, as a person runs it, typing the line when it asks for the
# sha256 prefix; prints what the terminal showed and exits with post.sh's code (TTY_EXTRA: more NAME=value settings)
TTY_EXTRA=()
ttyrun()
{
	env "${GATE_ENV[@]}" "${TTY_EXTRA[@]}" python3 -I - "$1" bash "${PO}" "$2" << 'PY'
import os, pty, select, sys
typed = sys.argv[1].encode() + b"\n"
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
out, sent = b"", False
while True:
    r, _, _ = select.select([fd], [], [], 20)
    if not r:
        break
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
    if not sent and b"type the first 12 characters" in out:
        os.write(fd, typed)
        sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r\n", "\n"))
sys.exit(os.waitstatus_to_exitcode(status))
PY
}
nwrites() { writes "${D}/gate-gh.jsonl" | grep -c .; }
OUT=$(gate "${N7}") && fail "go-gate: a draft with no GO was posted: ${OUT}"
echo "${OUT}" | grep -q "REFUSED ${N7}: no GO" || fail "go-gate: the refusal without a GO does not say so: ${OUT}"
[ -f "${G}/outbox/${N7}.md" ] || fail "go-gate: the refused draft is gone"
echo "GO $(printf '%064d' 0) planted" > "${G}/outbox/${N7}.GO"
OUT=$(gate "${N7}") && fail "go-gate: a GO naming another sha256 posted the draft: ${OUT}"
echo "${OUT}" | grep -q "the GO does not name the draft's sha256" || fail "go-gate: the wrong-sha refusal does not say so: ${OUT}"
OUT=$(env "${GATE_ENV[@]}" BUS_AGENT_ID=issues bash "${PO}" "${N7}" 2>&1) && fail "go-gate: post.sh ran as the spoke's cycle: ${OUT}"
echo "${OUT}" | grep -q "run from the issues spoke's cycle" || fail "go-gate: the cycle refusal does not say so: ${OUT}"
[ "$(nwrites)" == "0" ] || fail "go-gate: a refused post reached gh: $(writes "${D}/gate-gh.jsonl")"
# a draft with a token shape, its GO matching: the scrub refuses it
NT=o.r-9
printf 'the token is ghp_%s\n' "$(printf 'A%.0s' $(seq 1 36))" > "${G}/outbox/${NT}.md"
printf 'send: %s\n' "$(env "${GATE_ENV[@]}" bash "${PO}" --command "${NT}")" > "${G}/outbox/${NT}.FILING-READY.md"
echo "GO $(sha256sum "${G}/outbox/${NT}.md" | cut -d' ' -f1) planted" > "${G}/outbox/${NT}.GO"
OUT=$(gate "${NT}") && fail "go-gate: a draft with a token shape was posted: ${OUT}"
echo "${OUT}" | grep -q "the privacy scan found" || fail "go-gate: the token-shape refusal does not name the scan: ${OUT}"
[ "$(nwrites)" == "0" ] || fail "go-gate: the scrubbed refusal reached gh: $(writes "${D}/gate-gh.jsonl")"
# every other refusal of the gate, each planted alone beside a GO naming the draft's sha256, none reaching gh: a draft
# that is a symbolic link, one over 60000 bytes, an empty GO, a record whose send line is not the command, a draft whose
# hash cannot be taken, and, with a tracker tree whose redact-scan.sh does not pass, a draft at a terminal with its
# prefix typed
PL=${G}/planted
mkdir -p "${PL}/nosha" "${PL}/redact-tree/scripts"
refused() { echo "${OUT}" | grep -qF "REFUSED $1: $2" || fail "go-gate: $3 was not refused for its reason ('$2'): ${OUT}"; }
NS=o.r-13
printf 'the target of a link\n' > "${PL}/link-target.md"
ln -s "${PL}/link-target.md" "${G}/outbox/${NS}.md"
printf 'send: gh issue comment 13 --repo o/r --body-file %s\n' "${G}/outbox/${NS}.md" > "${G}/outbox/${NS}.FILING-READY.md"
echo "GO $(sha256sum < "${PL}/link-target.md" | cut -d' ' -f1) planted" > "${G}/outbox/${NS}.GO"
OUT=$(gate "${NS}") && fail "go-gate: a draft that is a symbolic link was posted: ${OUT}"
refused "${NS}" "no draft as a regular file" "a symlinked draft"
NB=o.r-14
head -c 60001 /dev/zero | tr '\0' 'a' > "${G}/outbox/${NB}.md"
printf 'send: gh issue comment 14 --repo o/r --body-file %s\n' "${G}/outbox/${NB}.md" > "${G}/outbox/${NB}.FILING-READY.md"
echo "GO $(sha256sum < "${G}/outbox/${NB}.md" | cut -d' ' -f1) planted" > "${G}/outbox/${NB}.GO"
OUT=$(gate "${NB}") && fail "go-gate: a draft over 60000 bytes was posted: ${OUT}"
refused "${NB}" "the draft is over 60000 bytes" "a draft over 60000 bytes"
stage() { printf 'A short reply, %s.\n' "$1" > "${G}/outbox/$1.md"; printf 'send: %s\n' "$(env "${GATE_ENV[@]}" "${TTY_EXTRA[@]}" bash "${PO}" --command "$1")" > "${G}/outbox/$1.FILING-READY.md"; echo "GO $(sha256sum < "${G}/outbox/$1.md" | cut -d' ' -f1) planted" > "${G}/outbox/$1.GO"; }
NE=o.r-15
stage "${NE}" && : > "${G}/outbox/${NE}.GO"
OUT=$(gate "${NE}") && fail "go-gate: a draft with an empty GO was posted: ${OUT}"
refused "${NE}" "the GO does not name the draft's sha256" "an empty GO"
NL=o.r-16
stage "${NL}" && printf 'send: gh issue comment 99 --repo o/r --body-file %s\n' "${G}/outbox/${NL}.md" > "${G}/outbox/${NL}.FILING-READY.md"
OUT=$(gate "${NL}") && fail "go-gate: a draft whose record names another send command was posted: ${OUT}"
refused "${NL}" "the record has no line 'send: gh issue comment 16" "a record with another send line"
NH=o.r-17
stage "${NH}" && printf '#!/bin/bash\nexit 1\n' > "${PL}/nosha/sha256sum" && chmod +x "${PL}/nosha/sha256sum"
OUT=$(env "${GATE_ENV[@]}" PATH="${PL}/nosha:${D}/bin:${PATH}" bash "${PO}" "${NH}" 2>&1) && fail "go-gate: a draft whose hash could not be taken was posted: ${OUT}"
refused "${NH}" "cannot hash the draft" "a draft whose hash could not be taken"
NR=o.r-18
cp "${CH}/gh-ro.sh" "${PL}/redact-tree/scripts/gh-ro" && chmod +x "${PL}/redact-tree/scripts/gh-ro"
printf '#!/bin/bash\necho "REDACT-FAIL: a planted finding"\nexit 1\n' > "${PL}/redact-tree/scripts/redact-scan.sh"
TTY_EXTRA=(ISSUES_TRACKER_DIR="${PL}/redact-tree")
stage "${NR}"
OUT=$(ttyrun "$(sha256sum < "${G}/outbox/${NR}.md" | cut -c1-12)" "${NR}") && fail "go-gate: a draft the tracker's redact scan refuses was posted: ${OUT}"
TTY_EXTRA=()
refused "${NR}" "the issues tracker's redact-scan.sh --strict did not pass" "a draft the tracker's redact scan refuses"
[ "$(nwrites)" == "0" ] || fail "go-gate: a planted refusal reached gh: $(writes "${D}/gate-gh.jsonl")"
# the matching GO without a terminal is refused, and so is a terminal where other characters are typed: nothing sent
echo "GO ${SHA} reply to the review" > "${G}/outbox/${N7}.GO"
OUT=$(gate "${N7}") && fail "go-gate: a draft with its matching GO was posted without a terminal: ${OUT}"
echo "${OUT}" | grep -q "REFUSED ${N7}: not at a terminal" || fail "go-gate: the refusal without a terminal does not say so: ${OUT}"
OUT=$(ttyrun "$(printf '%012d' 0)" "${N7}") && fail "go-gate: a draft was posted after other characters were typed: ${OUT}"
echo "${OUT}" | grep -q "the typed characters are not the draft's sha256 prefix" || fail "go-gate: the wrong-prefix refusal does not say so: ${OUT}"
[ "$(nwrites)" == "0" ] || fail "go-gate: a refused post reached gh: $(writes "${D}/gate-gh.jsonl")"
# the matching GO at a terminal with the prefix typed: exactly one comment, read back, POSTED; a second run is refused
OUT=$(ttyrun "${SHA:0:12}" "${N7}") || fail "go-gate: the draft with its matching GO and the typed prefix was not posted: ${OUT}"
echo "${OUT}" | grep -q "posted https://github.com/o/r/pull/7#issuecomment-1001 (verified)" || fail "go-gate: the post was not read back as verified: ${OUT}"
[ "$(nwrites)" == "1" ] && writes "${D}/gate-gh.jsonl" | grep -qxE "pr comment 7 --repo o/r --body-file ${GP}/gate/emit\.[A-Za-z0-9]{8}" \
	|| fail "go-gate: the post is not exactly one comment from the verified send body: $(writes "${D}/gate-gh.jsonl")"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["read_back_matches"] and d["author_is_login"] and d["sha256"] == sys.argv[2], d' "${G}/outbox/${N7}.POSTED" "${SHA}" \
	|| fail "go-gate: the POSTED record does not hold the verified read-back: $(cat "${G}/outbox/${N7}.POSTED" 2>&1)"
OUT=$(gate "${N7}") && fail "go-gate: a posted draft was posted again: ${OUT}"
[ "$(nwrites)" == "1" ] || fail "go-gate: a second run reached gh"
# the draft rewritten after its hash: a planted tracker tree whose hook rewrites the outbox draft while the gates run.
# What goes out is post.sh's private copy, the bytes the GO names; the copy is gone afterwards
PT6=${D}/swap-tree
mkdir -p "${PT6}/scripts" "${PT6}/.claude/hooks"
cp "${CH}/gh-ro.sh" "${PT6}/scripts/gh-ro" && chmod +x "${PT6}/scripts/gh-ro"
printf '#!/bin/bash\ncat > /dev/null\nprintf "a different reply, written after the GO\\n" > "${ISSUES_SPOKE_WD:?}/outbox/o.r-12.md"\n' > "${PT6}/.claude/hooks/block-gh-write.sh"
N12=o.r-12
printf 'The reply the person read and gave their GO for.\n' > "${G}/outbox/${N12}.md"
SHA12=$(sha256sum "${G}/outbox/${N12}.md" | cut -d' ' -f1)
printf 'send: %s\n' "$(env "${GATE_ENV[@]}" ISSUES_TRACKER_DIR="${PT6}" bash "${PO}" --command "${N12}")" > "${G}/outbox/${N12}.FILING-READY.md"
echo "GO ${SHA12} the reply as read" > "${G}/outbox/${N12}.GO"
# another run's error files, by the fixed names a gate without its own temporary files would use: this run, which goes
# through staging and the send, neither overwrites nor removes them
printf 'another run\n' > "${GP}/gate/emit.err" && printf 'another run\n' > "${GP}/gate/send.err"
TTY_EXTRA=(ISSUES_TRACKER_DIR="${PT6}")
OUT=$(ttyrun "${SHA12:0:12}" "${N12}")
TTY_EXTRA=()
grep -q 'a different reply' "${G}/outbox/${N12}.md" || fail "go-gate: the planted hook did not rewrite the draft (no control): ${OUT}"
python3 -c 'import hashlib, json, sys; b = json.load(open(sys.argv[1]))["body"]; assert hashlib.sha256(b.encode()).hexdigest() == sys.argv[2], b' "${D}/gate-gh.jsonl.posted" "${SHA12}" \
	|| fail "go-gate: the body sent is not the draft the GO named, it changed after the hash: $(head -c 200 "${D}/gate-gh.jsonl.posted")"
echo "${OUT}" | grep -q "posted https://github.com/o/r/issues/12#issuecomment-1001 (verified)" || fail "go-gate: the post of the draft as hashed was not read back as verified: ${OUT}"
[ "$(nwrites)" == "2" ] || fail "go-gate: the post of the draft as hashed is not one comment: $(writes "${D}/gate-gh.jsonl")"
for F in emit.err send.err; do
	[ "$(cat "${GP}/gate/${F}" 2>/dev/null)" == "another run" ] || fail "go-gate: post.sh overwrote or removed another run's ${F} in the private gate directory"
done
rm -f "${GP:?}/gate/emit.err" "${GP:?}/gate/send.err"
[ -z "$(ls "${GP}/gate/" | grep -E '^(send|emit)\.[A-Za-z0-9]{8}$|^(emit|send)-err\.[A-Za-z0-9]{8}$')" ] || fail "go-gate: post.sh left its private copy, its send body or an error file: $(ls "${GP}/gate/" | tr '\n' ' ')"
# the copy itself rewritten after its hash: a planted tracker tree whose block-gh-write.sh rewrites post.sh's own
# private copy (not the outbox draft) while the gates run. The re-hash just before the send catches it: nothing goes out
PT7=${D}/copy-swap-tree
mkdir -p "${PT7}/scripts" "${PT7}/.claude/hooks"
cp "${CH}/gh-ro.sh" "${PT7}/scripts/gh-ro" && chmod +x "${PT7}/scripts/gh-ro"
cat > "${PT7}/.claude/hooks/block-gh-write.sh" << 'HOOK'
#!/bin/bash
IN=$(cat)
P=$(printf '%s' "${IN}" | python3 -I -c 'import json,re,sys; c=json.load(sys.stdin).get("tool_input",{}).get("command",""); m=re.search(r"--body-file (\S+)", c); print(m.group(1) if m else "")')
[ -n "${P}" ] && printf 'bytes swapped into the copy after its hash, by a planted hook\n' > "${P}"
exit 0
HOOK
N13=o.r-19
printf 'The reply the person read and gave their GO for, nineteen.\n' > "${G}/outbox/${N13}.md"
SHA13=$(sha256sum "${G}/outbox/${N13}.md" | cut -d' ' -f1)
printf 'send: %s\n' "$(env "${GATE_ENV[@]}" ISSUES_TRACKER_DIR="${PT7}" bash "${PO}" --command "${N13}")" > "${G}/outbox/${N13}.FILING-READY.md"
echo "GO ${SHA13} the reply as read" > "${G}/outbox/${N13}.GO"
TTY_EXTRA=(ISSUES_TRACKER_DIR="${PT7}")
OUT=$(ttyrun "${SHA13:0:12}" "${N13}") && fail "go-gate: a copy rewritten after its hash was still posted: ${OUT}"
TTY_EXTRA=()
echo "${OUT}" | grep -q "the send body changed after it was staged" || fail "go-gate: the copy-rewrite refusal does not say so: ${OUT}"
[ "$(nwrites)" == "2" ] || fail "go-gate: the copy-rewrite reached gh: $(writes "${D}/gate-gh.jsonl")"
[ "$(grep -c ' REFUSED ' "${GP}/gate.log")" -ge 5 ] || fail "go-gate: the refusals are not in the private gate.log: $(cat "${GP}/gate.log" 2>&1)"
# post.sh writes only its working directory and its private directory: since its first run here nothing else changed
# under the test's directory but the stub's own record and the planted trees; with the vendored tree, the audit line of
# its block-gh-write.sh is in the private gate directory, not the image's tree and not the session's reach
OUTSIDE=$(find "${D}" -newer "${D}/gate-start" ! -type d ! -path "${G}/*" ! -path "${GP}/*" ! -path "${D}/gate-gh.jsonl*" ! -path "${PT6}/*" ! -path "${PT7}/*" | head -5)
[ -z "${OUTSIDE}" ] || fail "go-gate: post.sh wrote outside its working directory and private directory: $(echo "${OUTSIDE}" | tr '\n' ' ')"
if [ -f "${TREE}/.claude/hooks/block-gh-write.sh" ]; then
	[ -s "${GP}/gate/gh-write-audit.log" ] || fail "go-gate: the vendored block-gh-write.sh left no audit line in the private gate directory: $(ls "${GP}/gate" 2>&1 | tr '\n' ' ')"
fi
# an early refusal, in a private directory of its own: it makes no gate directory, leaves only its one refusal line in
# the private gate.log and makes the directory mode 700; a name carrying a newline and a forged log line (send-line.sh
# passes the session's argument through to post.sh) still makes one line, its unsafe characters replaced
EP=${D}/early-private
FN=$(printf 'o.r-20\n1999-01-01T00:00:00Z POSTED o.r-20 forged')
OUT=$(env "${GATE_ENV[@]}" ISSUES_SPOKE_PRIVATE_DIR="${EP}" bash "${PO}" --check "${FN}" 2>&1) && fail "go-gate: a name carrying a newline passed the gate: ${OUT}"
echo "${OUT}" | grep -qF "the name is not <owner>.<repository>-<number>" || fail "go-gate: the name carrying a newline was not refused for its name: ${OUT}"
[ "$(ls -A "${EP}" 2>&1)" == "gate.log" ] || fail "go-gate: an early refusal left more than its gate.log in the private directory: $(ls -A "${EP}" 2>&1 | tr '\n' ' ')"
{ [ "$(grep -c '' "${EP}/gate.log")" == "1" ] && ! grep -q '^1999-01-01T00:00:00Z' "${EP}/gate.log"; } \
	|| fail "go-gate: a name carrying a newline forged a line in the private gate.log: $(cat -A "${EP}/gate.log" | tr '\n' ' ')"
[ "$(stat -c %a "${EP}")" == "700" ] || fail "go-gate: an early refusal left the private directory mode $(stat -c %a "${EP}"), not 700"
# an absent name logs as ?; a planted POSTED marker is refused as posted already with none of its control bytes (C0, C1,
# DEL) or other non-ASCII bytes in the log or on stderr (the reason carries up to 200 of its bytes); a dangling POSTED
# link is refused as posted already too
OUT=$(env "${GATE_ENV[@]}" ISSUES_SPOKE_PRIVATE_DIR="${EP}" bash "${PO}" --check 2>&1) && fail "go-gate: post.sh with no name passed the gate: ${OUT}"
tail -1 "${EP}/gate.log" | grep -qF " REFUSED ?: the name is not <owner>.<repository>-<number>" || fail "go-gate: an absent name is not logged as ?: $(tail -1 "${EP}/gate.log")"
NC=o.r-21
stage "${NC}" && printf 'planted \033[2J\033]0;title\007 \233[31m caf\303\251 tab\there marker\n' > "${G}/outbox/${NC}.POSTED"
OUT=$(gate "${NC}") && fail "go-gate: a draft beside a planted POSTED marker was posted: ${OUT}"
refused "${NC}" "posted already (planted " "a draft beside a planted POSTED marker"
echo "${OUT}" | grep -qF "tab here marker" || fail "go-gate: the tab of the planted POSTED marker did not become a space in the refusal: $(printf '%s' "${OUT}" | cat -A)"
CB='import sys; d = sys.stdin.buffer.read(); sys.exit(1 if any(b < 32 and b != 10 or b >= 127 for b in d) else 0)'
printf '%s' "${OUT}" | python3 -I -c "${CB}" || fail "go-gate: a control or non-ASCII byte of the planted POSTED marker reached stderr: $(printf '%s' "${OUT}" | cat -A)"
python3 -I -c "${CB}" < "${GP}/gate.log" || fail "go-gate: a control or non-ASCII byte of the planted POSTED marker reached the private gate.log: $(grep -F "REFUSED ${NC}" "${GP}/gate.log" | cat -A)"
ND=o.r-22
stage "${ND}" && ln -s "${PL}/no-such-marker" "${G}/outbox/${ND}.POSTED"
OUT=$(gate "${ND}") && fail "go-gate: a draft beside a dangling POSTED link was posted: ${OUT}"
refused "${ND}" "posted already (the POSTED marker is not a regular file)" "a draft beside a dangling POSTED link"
# a send that gh fails, at a terminal with the prefix typed: gh's whole error output, made printable ASCII (its tab a
# space; ESC, a C1 byte and UTF-8 removed), is in the one FAILED line and on stderr; nothing is posted and the run's
# error files are gone
NF=o.r-23
PF=${D}/fail-gh
mkdir -p "${PF}"
cat > "${PF}/gh" << 'GH'
#!/bin/bash
case " $* " in
	*" comment "*) printf 'first line of the failure\n\033[31mred\033[0m \233[1m caf\303\251 tab\there\n' >&2; exit 1 ;;
esac
exec "${FAILGH_NEXT:?}" "$@"
GH
chmod +x "${PF}/gh"
stage "${NF}"
TTY_EXTRA=(PATH="${PF}:${D}/bin:${PATH}" FAILGH_NEXT="${D}/bin/gh")
OUT=$(ttyrun "$(sha256sum < "${G}/outbox/${NF}.md" | cut -c1-12)" "${NF}") && fail "go-gate: a send whose gh failed reported success: ${OUT}"
TTY_EXTRA=()
python3 -I -c "${CB}" < "${GP}/gate.log" || fail "go-gate: a control or non-ASCII byte of gh's error output reached the private gate.log: $(grep -A1 -F "FAILED ${NF}" "${GP}/gate.log" | cat -A)"
printf '%s' "${OUT}" | sed -n '/the send failed/,$p' | python3 -I -c "${CB}" || fail "go-gate: a control or non-ASCII byte of gh's error output reached stderr: $(printf '%s' "${OUT}" | sed -n '/the send failed/,$p' | cat -A)"
FL=$(grep -F " FAILED ${NF}: " "${GP}/gate.log")
{ echo "${FL}" | grep -qF "${NF}: first line of the failure" && echo "${FL}" | grep -qF "tab here"; } \
	|| fail "go-gate: the FAILED line does not carry gh's whole error output with its tab as a space: $(printf '%s' "${FL}" | cat -A)"
echo "${OUT}" | grep -qF "the send failed: first line of the failure" || fail "go-gate: stderr does not report the failed send with gh's whole error output: ${OUT}"
[ -e "${G}/outbox/${NF}.POSTED" ] && fail "go-gate: a failed send wrote a POSTED marker"
[ -z "$(ls "${GP}/gate/" | grep -E '^(emit|send)-err\.[A-Za-z0-9]{8}$')" ] || fail "go-gate: a failed send left its error files: $(ls "${GP}/gate/" | tr '\n' ' ')"
HOOKNOTE="(no vendored issues tracker here: its block-gh-write.sh is checked where /opt/issues-tracker carries it)"
HK=${TREE}/.claude/hooks/block-gh-write.sh
if [ -f "${HK}" ]; then
	mkdir -p "${D}/hook/home" && cp "${HK}" "${D}/hook/block-gh-write.sh"
	for V in "gh pr merge 7 --repo o/r" "gh pr close 7 --repo o/r"; do
		printf '{"tool_name": "Bash", "tool_input": {"command": "GH_WRITE_OPERATOR_OK=\\"planted\\" %s"}}' "${V}" | HOME="${D}/hook/home" bash "${D}/hook/block-gh-write.sh" > /dev/null 2>&1
		[ $? -eq 2 ] || fail "go-gate: the vendored block-gh-write.sh did not block '${V}' with the operator token"
	done
	HOOKNOTE="the vendored block-gh-write.sh blocks merge and close even with the operator token"
fi
# every session's shared settings deny post.sh and the GO files: shared-settings.sh adds its rules once beside the user's
# own, and startup.sh runs it before the agent session starts
SC=${D}/shared-cfg
mkdir -p "${SC}" && printf '%s\n' '{"permissions": {"deny": ["Read(//secret/**)"]}, "model": "x"}' > "${SC}/settings.json"
for I in 1 2; do
	CLAUDE_CONFIG_DIR="${SC}" ISSUES_SPOKE_WD=/wd/issues bash "${CH}/shared-settings.sh" > "${D}/shared-${I}.out" 2>&1 \
		|| fail "go-gate: shared-settings.sh: $(cat "${D}/shared-${I}.out")"
done
python3 - "${SC}/settings.json" "${CH}" << 'PY' || fail "go-gate: the shared settings do not deny post.sh and the GO files once beside the user's rules: $(cat "${SC}/settings.json")"
import json, sys
s, ch = json.load(open(sys.argv[1])), sys.argv[2]
assert s["model"] == "x" and s["permissions"]["deny"] == ["Read(//secret/**)", f"Bash({ch}/post.sh:*)", f"Bash(bash {ch}/post.sh:*)",
                                                         "Edit(//wd/issues/outbox/*.GO)"], s
PY
grep -q "already in place" "${D}/shared-2.out" || fail "go-gate: a second shared-settings.sh run did not find its rules in place: $(cat "${D}/shared-2.out")"
SU=${BASE_DIR%/}/startup.sh
LS=$(grep -n '^/agent/charters/issues/shared-settings.sh$' "${SU}" | cut -d: -f1)
LA=$(grep -n '^[[:space:]]*/agent/tmux-session-start.sh$' "${SU}" | head -1 | cut -d: -f1)
{ [ -n "${LS}" ] && [ -n "${LA}" ] && [ "${LS}" -lt "${LA}" ]; } || fail "go-gate: startup.sh does not run shared-settings.sh before the agent session (lines ${LS:-none} and ${LA:-none})"
echo "ok 6 [go-gate] - no GO, a GO naming another sha256, the spoke's own cycle, a token-shaped draft, a symlinked draft, one over 60000 bytes, an empty GO, another send line, a draft that cannot be hashed and one the tracker's redact scan refuses all refused with no write; the matching GO without a terminal and with other characters typed refused; at a terminal with the typed prefix it sent exactly one comment, from the frozen send body (a draft rewritten during the gates went out as hashed, the body removed), read back verified and recorded POSTED; a second run refused; nothing written outside the working and private directories; an early refusal made no gate directory, left one line in the private gate.log (a name carrying a newline forged none) and set the directory 700; an absent name logged as ?; a planted POSTED marker and a dangling POSTED link refused as posted already, none of the marker's control or non-ASCII bytes in the log or on stderr and its tab a space; its error files removed with the body and another run's left untouched; a send gh fails logged as one printable-ASCII failure line carrying gh's whole error output, nothing posted; ${HOOKNOTE}; every session's shared settings deny post.sh and the GO files (added once, before the agent session)"

# --- 6b. the session's walls: on a tmux server whose environment holds every GitHub token and the operator token, the
#         issues pane's claude starts without them and without the hub's permission bypass; its settings deny the write
#         paths and register its hook; the hook refuses the session's own write forms, hands the rest to the vendored
#         tracker's block-gh-write.sh and lets a read through; send-line.sh prints the send line from the pane, where
#         post.sh itself is refused ---
WT=${D}/tmux-walls
mkdir -p "${WT}" "${D}/envdump"
cat > "${D}/envdump/claude" << 'STUBC'
#!/bin/bash
env | sort > "${CLAUDE_ENV_DUMP:?}.env"
printf '%s\n' "$@" > "${CLAUDE_ENV_DUMP:?}.argv"
while :; do sleep 1; done
STUBC
chmod +x "${D}/envdump/claude"
python3 - "${SHIPPED_REGISTRY}" "${D}/registry-walls.json" "${D}" << 'PY' || fail "could not write the walls registry"
import json, sys
src, dst, d = sys.argv[1:4]
doc = json.load(open(src))
keep = []
for e in doc["sessions"]:
    if e["role"] == "hub":
        keep.append(dict(e, session_name="tis-hub"))
    elif e["role"] == "supervisor":
        keep.append(dict(e, session_name="tis-sup"))
    elif e["session_name"] == "issues":
        keep.append(dict(e, session_name="tis-walls", flag="SPOKE_TIS_WALLS", workdir=f"{d}/wd/tis-walls", parent="tis-hub"))
json.dump(dict(doc, sessions=keep), open(dst, "w"), indent=1)
PY
WW=${D}/wd/tis-walls
OUT=$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="${WT}" SPOKES_REGISTRY="${D}/registry-walls.json" SUPERVISOR_DIR="${D}/sup-walls" \
	AGENT_TMUX_SESSION_NAME=tis-hub CLAUDE_BIN="${D}/envdump/claude" CLAUDE_CONFIG_DIR="${D}/claude-config" CLAUDE_ENV_DUMP="${D}/envdump/pane" \
	UI_START=false UI_HINDSIGHT=false GH_TOKEN=planted-gh GITHUB_TOKEN=planted-github GITHUB_PERSONAL_ACCESS_TOKEN=planted-pat \
	GH_WRITE_OPERATOR_OK=planted-op AGENT_TMUX_CLAUDE_OPTS="--model planted --dangerously-skip-permissions --permission-mode bypassPermissions --verbose" \
	"${AGENT_DIR}/tmux-session-start.sh" tis-walls 2>&1) || fail "session-walls: tmux-session-start.sh tis-walls: ${OUT}"
wt() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="${WT}" tmux "$@"; }
for I in $(seq 1 20); do [ -s "${D}/envdump/pane.argv" ] && break; sleep 1; done
[ -s "${D}/envdump/pane.env" ] || fail "session-walls: the issues pane's claude did not start: ${OUT}"
[ "$(wt show-environment -g GH_TOKEN 2>/dev/null)" == "GH_TOKEN=planted-gh" ] || fail "session-walls: the planted token did not reach the tmux server (no control)"
TOK=$(grep -E '^(GH_TOKEN|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN|GH_WRITE_OPERATOR_OK)=' "${D}/envdump/pane.env" | cut -d= -f1 | tr '\n' ' ')
[ -z "${TOK}" ] || fail "session-walls: the issues pane's claude has ${TOK}in its environment"
grep -qxF "GH_CONFIG_DIR=${WW}/.gh-config" "${D}/envdump/pane.env" && [ -d "${WW}/.gh-config" ] && [ ! -e "${WW}/.gh-config/hosts.yml" ] \
	|| fail "session-walls: the issues pane's gh does not get an empty configuration of its own: $(grep '^GH_CONFIG_DIR=' "${D}/envdump/pane.env")"
PPID_W=$(wt display-message -p -t "=tis-walls:" '#{pane_pid}' 2>/dev/null)
[ -n "${PPID_W}" ] && ! tr '\0' '\n' < "/proc/${PPID_W}/environ" | grep -qE '^(GH_TOKEN|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN|GH_WRITE_OPERATOR_OK)=' \
	|| fail "session-walls: the pane's own process (pid ${PPID_W:-?}) holds a token"
[ "$(tr '\n' ' ' < "${D}/envdump/pane.argv")" == "--model planted --verbose " ] \
	|| fail "session-walls: the issues claude kept the hub's permission bypass: $(tr '\n' ' ' < "${D}/envdump/pane.argv")"
python3 - "${WW}/.claude/settings.json" "${WW}" "${CH}" << 'PY' || fail "session-walls: the session's settings do not carry its deny rules and hook: $(head -c 400 "${WW}/.claude/settings.json" 2>&1)"
import json, re, sys
p, wd, ch = sys.argv[1:4]
s = json.load(open(p))
deny = s["permissions"]["deny"]
want = ["mcp__plugin_github_github", "mcp__plugin_github_github__*", "Bash(gh:*)", "Bash(curl:*)", f"Bash({ch}/post.sh:*)",
        "Read(//proc/**)", "Read(~/.config/gh/**)", "Bash(tmux show-environment:*)", f"Edit(/{wd}/outbox/*.GO)",
        f"Read(/{wd}/outbox/*.GO)",
        f"Edit(/{wd}/.claude/**)", f"Edit(/{ch}/**)",
        # the write paths the session may not edit or write (round-2 HIGH): the shim, the gate, the tracker, the agent tree
        f"Edit(/{wd}/.gh-front/**)", f"Write(/{wd}/.gh-front/**)", f"Edit(/{wd}/gate/**)", f"Write(/{wd}/gate/**)",
        f"Edit(/{wd}/gate.log)", f"Write(/{wd}/gate.log)",
        "Edit(//opt/issues-tracker/**)", "Write(//opt/issues-tracker/**)", "Edit(//agent/**)", "Write(//agent/**)"]
miss = [w for w in want if w not in deny]
assert not miss, miss
# the private directory, wherever the pane resolved it, is denied for both file tools (its rule ends in /private/**)
assert any(r.startswith("Edit(") and r.endswith("/private/**)") for r in deny), ("no Edit rule for the private directory", deny)
assert any(r.startswith("Write(") and r.endswith("/private/**)") for r in deny), ("no Write rule for the private directory", deny)
assert any(r.startswith("Read(") and r.endswith("/private/**)") for r in deny), ("no Read rule for the private directory", deny)
# the hook now covers the file-writing tools as well as Bash and the plugin
for t in ("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"):
    assert any(re.fullmatch(m["matcher"], t) for m in s["hooks"]["PreToolUse"]), ("the hook matcher misses", t)
hk = [h for m in s["hooks"]["PreToolUse"] for h in m["hooks"]
      if re.fullmatch(m["matcher"], "Bash") and re.fullmatch(m["matcher"], "mcp__plugin_github_github__add_issue_comment")
      and re.fullmatch(m["matcher"], "Write") and re.fullmatch(m["matcher"], "Edit")]
assert any(h["type"] == "command" and f"{ch}/session-hook.sh" in h["command"] and h["command"].endswith("|| exit 2")
           and f"ISSUES_SPOKE_WD={wd} " in h["command"] and "ISSUES_SPOKE_PRIVATE_DIR=" in h["command"] for h in hk), hk
PY
call() { python3 -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' Bash "$1"; }
callf() { python3 -c 'import json, sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}}))' "$1" "$2"; }
hook() { printf '%s' "$1" | env ISSUES_SPOKE_WD="${WW}" ISSUES_SPOKE_PRIVATE_DIR="${WW}/private" bash "${CH}/session-hook.sh" > "${D}/hook.out" 2>&1; echo $?; }
[ "$(hook "$(call 'GH_WRITE_OPERATOR_OK="planted" gh pr comment 7 --repo o/r --body-file d.md')")" == "2" ] || fail "session-walls: the session's hook let a command with the operator token through"
[ "$(hook "$(call "${CH}/post.sh o.r-7")")" == "2" ] || fail "session-walls: the session's hook let post.sh run"
[ "$(hook "$(call 'echo GO > outbox/o.r-7.GO')")" == "2" ] || fail "session-walls: the session's hook let a GO file be written"
[ "$(hook "$(call 'tmux show-environment -g GH_TOKEN')")" == "2" ] || fail "session-walls: the session's hook let the tmux server's environment be read"
[ "$(hook "$(call "${CH}/gh-ro.sh pr view 7 --repo o/r --json number")")" == "0" ] || fail "session-walls: the session's hook refused a read through the front: $(cat "${D}/hook.out")"
[ "$(hook "$(call "${CH}/send-line.sh o.r-7")")" == "0" ] || fail "session-walls: the session's hook refused send-line.sh: $(cat "${D}/hook.out")"
# the file-writing tools, which the widened matcher now sends to the hook: a Write or Edit aimed at the shim, the gate,
# the private directory, the session settings or a GO file is refused; a draft in the outbox is allowed
[ "$(hook "$(callf Write "${WW}/private/gh-front/gh")")" == "2" ] || fail "session-walls: the session's hook let a Write to the gh shim through"
[ "$(hook "$(callf Write "${WW}/private/gate/send.x")")" == "2" ] || fail "session-walls: the session's hook let a Write to the private gate through"
# /opt/issues-tracker, /agent (not a post.sh path, so the string gates do not catch it) and .claude isolate the hook's
# file-path section; a MultiEdit and a NotebookEdit (notebook_path) prove the matcher covers those tools too
[ "$(hook "$(callf Write "/opt/issues-tracker/scripts/gh-ro")")" == "2" ] || fail "session-walls: the session's hook let a Write to the vendored tracker through"
[ "$(hook "$(callf Write "/agent/charters/issues/charter.md")")" == "2" ] || fail "session-walls: the session's hook let a Write to the agent tree through"
[ "$(hook "$(callf Edit "${WW}/.claude/settings.json")")" == "2" ] || fail "session-walls: the session's hook let an Edit of its own settings through"
[ "$(hook "$(callf MultiEdit "/opt/issues-tracker/x")")" == "2" ] || fail "session-walls: the session's hook let a MultiEdit of the tracker through"
[ "$(hook "$(python3 -c 'import json; print(json.dumps({"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/agent/x.ipynb"}}))')")" == "2" ] || fail "session-walls: the session's hook let a NotebookEdit of the agent tree through"
[ "$(hook "$(callf Write "${WW}/gate.log")")" == "2" ] || fail "session-walls: the session's hook let a Write of gate.log through"
[ "$(hook "$(callf Write "${WW}/outbox/a.GO")")" == "2" ] || fail "session-walls: the session's hook let a Write of a GO file through"
[ "$(hook "$(callf Write "${WW}/outbox/a.md")")" == "0" ] || fail "session-walls: the session's hook refused a draft in the outbox: $(cat "${D}/hook.out")"
# the Bash case names the shim, the gate, gate.log and the private directory by spelling, not just the literal path: an
# absolute, a relative, a doubled-separator, a repeated /./ and a $SUPERVISOR_DIR form are each refused (so dropping a
# pattern or the separator-collapse from the hook fails here), while a read elsewhere and the front are allowed
[ "$(hook "$(call "cp evil ${WW}/private/gh-front/gh")")" == "2" ] || fail "session-walls: the session's hook let a Bash cp into the shim through"
[ "$(hook "$(call "printf x >> ${WW}/gate.log")")" == "2" ] || fail "session-walls: the session's hook let a Bash write of gate.log through"
# the fragment globs, the separator-collapse and the variable name, each caught by only its part of the Bash case (none
# names the test's literal private directory, so a hook that matched literal absolute paths only would let them through)
[ "$(hook "$(call 'cd /wd/issues; cp evil ../supervisor/issues/private/x')")" == "2" ] || fail "session-walls: the session's hook let a relative issues/private path through"
[ "$(hook "$(call 'cp evil /wd/supervisor/issues//private/x')")" == "2" ] || fail "session-walls: the session's hook let a doubled-separator issues/private path through"
[ "$(hook "$(call 'cp evil /wd/supervisor/issues/././private/x')")" == "2" ] || fail "session-walls: the session's hook let a repeated /./ issues/private path through"
[ "$(hook "$(call 'cp evil $SUPERVISOR_DIR/x')")" == "2" ] || fail "session-walls: the session's hook let a \$SUPERVISOR_DIR path through"
[ "$(hook "$(call "ls ${WW}/outbox")")" == "0" ] || fail "session-walls: the session's hook refused a harmless Bash ls: $(cat "${D}/hook.out")"
WALLNOTE="(no vendored issues tracker here: its block-gh-write.sh behind the hook is checked where /opt/issues-tracker carries it)"
if [ -f "${TREE}/.claude/hooks/block-gh-write.sh" ]; then
	[ "$(hook "$(call 'gh pr comment 7 --repo o/r --body x')")" == "2" ] || fail "session-walls: a comment without a GO passed the session's hook"
	[ "$(hook "$(call 'gh api -X POST repos/o/r/issues/7/comments -f body=x')")" == "2" ] || fail "session-walls: a gh api write passed the session's hook"
	[ "$(hook '{"tool_name": "mcp__plugin_github_github__add_issue_comment", "tool_input": {"owner": "o", "repo": "r", "issue_number": 7, "body": "x"}}')" == "2" ] \
		|| fail "session-walls: the GitHub plugin's write tool passed the session's hook"
	WALLNOTE="behind it the vendored block-gh-write.sh refused a bare comment, a gh api POST and the plugin's write tool"
fi
# send-line.sh from the session's own pane prints the send line; post.sh from the same pane is refused
PANE_W=$(wt show-options -v -t "=tis-walls:" @agent_pane 2>/dev/null)
SL=${D}/sendline-wd
mkdir -p "${SL}/outbox" && printf 'a staged reply\n' > "${SL}/outbox/o.r-7.md"
SL_ENV=(TMUX_TMPDIR="${WT}" TMUX_PANE="${PANE_W}" ISSUES_SPOKE_SESSION=tis-walls ISSUES_SPOKE_WD="${SL}" ISSUES_SPOKE_PRIVATE_DIR="${SL}/private" PATH="${D}/bin:${PATH}"
	STUB_GH_LOG="${D}/sendline-gh.jsonl" ISSUES_TRACKER_DIR="${D}/no-tree")
OUT=$(env -u TMUX "${SL_ENV[@]}" bash "${CH}/send-line.sh" o.r-7 2>&1)
[ "${OUT}" == "gh pr comment 7 --repo o/r --body-file ${SL}/outbox/o.r-7.md" ] || fail "session-walls: send-line.sh from the session's pane printed '${OUT}'"
OUT=$(env -u TMUX "${SL_ENV[@]}" bash "${CH}/post.sh" o.r-7 2>&1) && fail "session-walls: post.sh ran from the session's own pane: ${OUT}"
echo "${OUT}" | grep -q "run from the tis-walls spoke's own session" || fail "session-walls: post.sh from the session's pane was not refused as its own session: ${OUT}"
wt kill-session -t "=tis-walls" 2>/dev/null
echo "ok 6b [session-walls] - on a server holding every token, the issues pane's claude had none of GH_TOKEN, GITHUB_TOKEN, GITHUB_PERSONAL_ACCESS_TOKEN or GH_WRITE_OPERATOR_OK, its gh an empty configuration of its own, and it started without the hub's permission bypass; its settings deny the plugin's tools, a bare gh, curl, post.sh, /proc, the GO files and its own files and register its hook; the hook refused the operator token, post.sh, a GO file and the server's environment, let a read and send-line.sh through, ${WALLNOTE}; send-line.sh printed the send line from the pane, where post.sh was refused"

# --- 7. nothing under /wd ---
if [ "${TEST_CONTAINER}" == "true" ]; then
	wd_new() { find /wd -mindepth 1 2>/dev/null | sort | comm -13 "${D}/wd-before.txt" -; }
	NEW=$(wd_new)
	[ -z "${NEW}" ] || fail "this test wrote $(echo "${NEW}" | wc -l) entries under /wd: $(echo "${NEW}" | head -5 | tr '\n' ' ')"
	touch /wd/.test-issues-planted || fail "PLANTED CONTROL: could not plant an entry under /wd"
	NEW=$(wd_new)
	rm -f /wd/.test-issues-planted
	[ "${NEW}" == "/wd/.test-issues-planted" ] || fail "PLANTED CONTROL: the entry planted under /wd is not the one new entry named: '${NEW}'"
	echo "ok 7 - nothing under /wd that was not there when the test started (control: an entry planted there is named)"
fi
echo "Test-issues-spoke succeeded"
