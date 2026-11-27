#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the North Star register against its own rule (docs/NORTH-STAR.md "The rule": a row counts only when a
# tracked check exists that FAILS if the property is removed). The register is docs/north-star.json, shipped at
# /agent/north-star.json and rendered into the home page's North Star section by /agent/home-render.sh; the document is
# docs/NORTH-STAR.md, shipped at /docs/NORTH-STAR.md. Fully OFFLINE: files only, and one render of the home page into
# test-local state under /tmp/north-star-smoke; nothing under /wd is touched.
#
# What it reads: the register the image ships (NORTH_STAR_JSON_SHIPPED, default /agent/north-star.json) and, from the
# repository's checkout (CHECKOUT, default /do-agent-aws, which test.sh mounts read-only), docs/north-star.json,
# docs/NORTH-STAR.md and .env, each of which the image's copy must equal where the image carries one. The paths a check
# names are looked up in the checkout (the repository at this commit) and, for Container-Root/..., in the image too, where
# Container-Root/<x> ships as /<x>. Without a checkout the image's /docs/NORTH-STAR.md is read, only the paths the image
# ships are looked up, and the ok line says how many were not.
#
# Properties proven (each check FAILS if the property is removed; each was seen to fail on a planted copy, one copy per
# check):
#   1. the register is JSON with the schema's keys: schema do-agent-aws-north-star/v1, an updated date, the statement, the
#      rule, both legends, rows, agents and components, each an object with its own keys, ids and names unique, every
#      component's agent one of the agents; the image's copy equals the checkout's
#   2. every row and every agent has a verdict the scoring defines (YES, YES*, NO) and a today the legend defines (PASS,
#      FAIL, PARTIAL, SKIP); today is empty (null) only for a verdict of NO
#   3. the rule: YES and YES* name a check, YES reads PASS today and YES* carries its caveat; NO names no check, has no
#      today, and its caveat says how it becomes YES: it names the test that would score it and the change that test
#      lands with, or it says that no check of it is written yet
#   4. every YES and YES* row and agent names at least one test or tool in its check (a script or program, or a path under
#      tools/: a check is a file that runs, not prose and not a document), and
#      every path a check, a caveat or a component's "where" names exists (a check that only lands later is named without
#      a path, as test22 is): a repository path (Container-Root/..., docs/...,
#      tools/..., ./<x>) in the checkout, a Container-Root/ path also in the image, an image path (/agent/..., /opt/...,
#      /docs/..., /seed/..., /setup/...) in the image; a register that names no path at all fails too
#   5. docs/NORTH-STAR.md carries the rows, the agents and the components table by table, line for line as the register
#      does (a row's id, goal, check, verdict, today and caveat; an agent's name, North Star, UI, talks-to, check, verdict,
#      today and caveat; a component's name, agent, where, as-of and state), and both legends (the verdicts and the today
#      values) word for word, so a FAIL means in the document what it means in the file; the image's copy equals the
#      checkout's
#   6. no URL in the register or the document but under the two public repositories (communication-engine,
#      tmux-agent-public), and the seed's privacy scan (/seed/scan.py --tree) passes both: no private repository is
#      linked and no internal name ships
#   7. the home page as home-render.sh renders it carries the section with every row's and every agent's verdict and today,
#      as data and as the words a reader sees (a dash and an empty attribute where there is none), every row's and agent's
#      check or "no tracked check", and every component's where, each link to exactly the URL it names; and the document's page it renders (/guide/north-star/)
#      shows every verdict as the register writes it, a YES* cell per item scored YES* and the legend's, none with a stray
#      backslash. CONTROL: the same page with each YES* cell as a renderer without backslash escapes wrote it fails
#   8. NS-2's default start path: with .env's AUTONOMY_LOOP and no Slack token or channels, the loop's autostart gate
#      (/agent/slack-gates.sh loop) reads off and the home page's Start here strip says the goal waits and names
#      AUTONOMY_LOOP=true; while that holds the register's NS-2 reads FAIL today. The day the default path starts the
#      loop this check fails, and NS-2 is scored again
#   9. the register agrees with what a plain start runs, read from /agent/spokes/registry.json and .env's flags (test22
#      check 7b proves that set is what a plain start runs): every session it runs has an agent row; no running agent's
#      caveat, the agents note or a row's caveat says it does not run ("no ... spoke runs", "only the hub runs"); an
#      agent with no session in the registry is scored NO and names the change it lands with, and an agent with a
#      session there no longer reads as pending: neither its caveat ("its session ... lands with", "before its session
#      ships", "until its own change ships it") nor the agents note ("the <name> agent is scored before its session
#      ships", "the <name> agent's North Star comes from its pending charter") says its session comes later; and a
#      running agent scored NO says in its caveat that it runs on a plain start, so a stale row in other words fails too.
#      Without a registry the check fails: nothing to check is not a pass

D=/tmp/north-star-smoke
rm -rf "${D:?}"
mkdir -p "${D}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
REGISTER=${NORTH_STAR_JSON_SHIPPED:-/agent/north-star.json}
CHECKOUT=${CHECKOUT:-/do-agent-aws}
SCAN=/seed/scan.py; [ -f "${SCAN}" ] || SCAN="${BASE_DIR%/}/seed/scan.py"
PORT_HOME=18861
# what /wd holds before this test: it must hold the same after (test.sh's own gate runs only after the whole suite; this
# one also holds when the test runs by hand)
find /wd -mindepth 1 2>/dev/null | sort > "${D}/wd-before.txt"

fail()
{
	echo "Test-north-star FAILED: $1"
	exit 1
}

bash -n "$0" || fail "bash -n $0"
[ -s "${REGISTER}" ] || fail "the image ships no register at ${REGISTER}"
if [ -f "${CHECKOUT}/docs/north-star.json" ]; then
	ROOT=${CHECKOUT}
	DOC=${CHECKOUT}/docs/NORTH-STAR.md
	ENV_FILE=${CHECKOUT}/.env
else
	ROOT=""
	DOC=/docs/NORTH-STAR.md
	ENV_FILE=""
fi

# --- 1. the schema ---
P1=$(python3 - "${REGISTER}" 2>&1 << 'PY'
import json, re, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:
    sys.exit("%s is not JSON: %s" % (sys.argv[1], exc))
def need(cond, what):
    if not cond:
        sys.exit(what)
need(isinstance(d, dict), "the register is not an object")
top = ["schema", "updated", "title", "statement", "rule", "scoring", "today_values", "rows", "agents_note", "agents",
       "components_note", "components"]
missing = [k for k in top if k not in d]
need(not missing, "the register lacks %s" % ", ".join(missing))
need(d["schema"] == "do-agent-aws-north-star/v1", "the schema is %r" % d["schema"])
need(isinstance(d["updated"], str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", d["updated"]), "updated is not a date: %r" % d["updated"])
for k in ("title", "statement", "rule", "agents_note", "components_note"):
    need(isinstance(d[k], str) and d[k].strip(), "%s is empty" % k)
need(isinstance(d["scoring"], dict) and isinstance(d["today_values"], dict), "a legend is not an object")
keys = {"rows": ("id", ["id", "goal", "check", "status", "today", "caveat"]),
        "agents": ("agent", ["agent", "role", "north_star", "ui", "talks_to", "check", "status", "today", "caveat"]),
        "components": ("name", ["name", "agent", "where", "as_of", "state"])}
for lst, (name, want) in keys.items():
    need(isinstance(d[lst], list) and d[lst] and all(isinstance(x, dict) for x in d[lst]), "%s is not a list of objects" % lst)
    for x in d[lst]:
        lack = [k for k in want if k not in x]
        need(not lack, "%s %r lacks %s" % (lst, x.get(name), ", ".join(lack)))
    ids = [x[name] for x in d[lst]]
    need(len(ids) == len(set(ids)), "%s has a %s twice: %r" % (lst, name, ids))
agents = {x["agent"] for x in d["agents"]}
for c in d["components"]:
    need(c["agent"] in agents, "component %r stands on %r, which is not an agent of the register" % (c["name"], c["agent"]))
    need(isinstance(c["as_of"], str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", c["as_of"]), "component %r: as_of is not a date" % c["name"])
    for k in ("where", "state"):
        need(isinstance(c[k], str) and c[k].strip(), "component %r: %s is empty" % (c["name"], k))
print("%d rows, %d agents, %d components" % (len(d["rows"]), len(d["agents"]), len(d["components"])))
PY
) || fail "the register does not carry the schema's keys: ${P1}"
if [ -n "${ROOT}" ]; then
	cmp -s "${ROOT}/docs/north-star.json" "${REGISTER}" || fail "the image's ${REGISTER} differs from the checkout's docs/north-star.json - rebuild the image"
fi
echo "ok 1 - the register parses with the schema's keys (${P1})$([ -n "${ROOT}" ] && echo "; the image's copy equals the checkout's")"

# --- 2. verdicts and today values from the legends ---
P2=$(python3 - "${REGISTER}" 2>&1 << 'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if set(d["scoring"]) != {"YES", "YES*", "NO"} or set(d["today_values"]) != {"PASS", "FAIL", "PARTIAL", "SKIP"}:
    sys.exit("the legends define %r and %r" % (sorted(d["scoring"]), sorted(d["today_values"])))
for kind, name, items in (("row", "id", d["rows"]), ("agent", "agent", d["agents"])):
    for x in items:
        if x["status"] not in d["scoring"]:
            sys.exit("%s %s: the verdict %r is not one the scoring defines" % (kind, x[name], x["status"]))
        if x["today"] is None:
            if x["status"] != "NO":
                sys.exit("%s %s: today is empty under the verdict %s (only NO may have no today)" % (kind, x[name], x["status"]))
        elif x["today"] not in d["today_values"]:
            sys.exit("%s %s: today %r is not one the legend defines" % (kind, x[name], x["today"]))
print("%d rows and %d agents" % (len(d["rows"]), len(d["agents"])))
PY
) || fail "a verdict or a today value is outside the legend: ${P2}"
echo "ok 2 - ${P2}: each has a verdict from the scoring and a today from the legend, empty only under NO"

# --- 3. the rule ---
P3=$(python3 - "${REGISTER}" 2>&1 << 'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
n = {"YES": 0, "YES*": 0, "NO": 0}
for kind, name, items in (("row", "id", d["rows"]), ("agent", "agent", d["agents"])):
    for x in items:
        st, check, caveat = x["status"], x["check"], x["caveat"]
        n[st] += 1
        has_check = isinstance(check, str) and check.strip() != ""
        if st in ("YES", "YES*") and not has_check:
            sys.exit("%s %s: the verdict %s names no check" % (kind, x[name], st))
        if st == "YES" and x["today"] != "PASS":
            sys.exit("%s %s: YES while today reads %s (YES is a check that passes)" % (kind, x[name], x["today"]))
        if st == "YES*" and not (isinstance(caveat, str) and caveat.strip()):
            sys.exit("%s %s: YES* without its caveat" % (kind, x[name]))
        if st == "NO":
            if check is not None or x["today"] is not None:
                sys.exit("%s %s: NO with a check or a today (NO is no tracked check, so no result)" % (kind, x[name]))
            text = caveat if isinstance(caveat, str) else ""
            lands = re.search(r"\btest[\w.-]*", text) and re.search(r"\blands? with\b", text)
            unwritten = re.search(r"\bno (?:tracked )?check\b[^;:.]*\bwritten yet\b", text)
            if not (lands or unwritten):
                sys.exit("%s %s: NO whose caveat does not say how it becomes YES - name the test that would score it and the "
                         "change it lands with, or say that no check of it is written yet (caveat: %r)" % (kind, x[name], text))
print("YES %(YES)d, YES* %(YES*)d, NO %(NO)d" % n)
PY
) || fail "the register breaks its own rule: ${P3}"
echo "ok 3 - the rule holds on every row and agent (${P3}): YES and YES* name their check, YES reads PASS, YES* has its caveat, NO says how it becomes YES"

# --- 4. every path a check names exists ---
P4=$(python3 - "${REGISTER}" "${ROOT}" 2>&1 << 'PY'
import json, os, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
root = sys.argv[2]
REPO = re.compile(r"(?<![\w./:-])((?:Container-Root|docs|tools)/[\w./-]*[\w-]|\./[\w.-]*[\w-])")
IMAGE = re.compile(r"(?<![\w./:-])(/(?:agent|opt|docs|seed|setup)/[\w./-]*[\w-])")
texts = [("row " + r["id"], r["check"], r["status"]) for r in d["rows"]] + [("agent " + a["agent"], a["check"], a["status"]) for a in d["agents"]]
texts += [("component " + c["name"], c["where"], None) for c in d["components"]]
texts += [("row " + r["id"] + "'s caveat", r["caveat"], None) for r in d["rows"]] + [("agent " + a["agent"] + "'s caveat", a["caveat"], None) for a in d["agents"]]
miss, checked, unchecked, paths, scored = [], 0, 0, set(), 0
for who, text, status in texts:
    # a test or tool: a script or program (.sh, .py) or a path under tools/; a document names no check that can run
    runs = [t for t in REPO.findall(text or "") + IMAGE.findall(text or "") if t.endswith((".sh", ".py")) or t.startswith("tools/")]
    if status in ("YES", "YES*"):
        scored += 1
        if not runs:
            miss.append("%s is scored %s on a check that names no test or tool (a script, a program or a path under tools/; a document does not run): %r" % (who, status, text))
    for t in REPO.findall(text or ""):
        paths.add(t)
        if root:
            checked += 1
            if not os.path.exists(os.path.join(root, t)):
                miss.append("%s names %s, which the repository does not have" % (who, t))
        elif not t.startswith("Container-Root/"):
            unchecked += 1
        if t.startswith("Container-Root/"):
            checked += 1
            if not os.path.exists("/" + t[len("Container-Root/"):]):
                miss.append("%s names %s, which the image does not carry at /%s" % (who, t, t[len("Container-Root/"):]))
    for t in IMAGE.findall(text or ""):
        paths.add(t)
        checked += 1
        if not os.path.exists(t):
            miss.append("%s names %s, which the image does not carry" % (who, t))
if miss:
    sys.exit("; ".join(miss))
if checked == 0:
    sys.exit("the register names no path a check could be looked up by (nothing to check is not a pass)")
print("%d paths in %d lookups, every one of %d scored items naming a test or tool%s" % (len(paths), checked, scored, "" if root else "; %d repository paths not looked up (no checkout)" % unchecked))
PY
) || fail "${P4}"
echo "ok 4 - every YES and YES* item names a test or tool, and every path the checks, the caveats and the components name exists (${P4})"

# --- 5. the document says what the register says ---
[ -s "${DOC}" ] || fail "no document at ${DOC}"
P5=$(python3 - "${REGISTER}" "${DOC}" 2>&1 << 'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
lines = open(sys.argv[2], encoding="utf-8").read().split("\n")
star = lambda s: s.replace("*", "\\*")
cell = lambda check: "`%s`" % check if check else "no tracked check"
want = {
    "| ID |": ["| %s | %s | %s | **%s** | %s | %s |" % (r["id"], r["goal"], cell(r["check"]), star(r["status"]), r["today"] or "-", r["caveat"])
               for r in d["rows"]],
    "| Agent |": ["| `%s` | %s | %s | %s | %s | **%s** | %s | %s |" % (a["agent"], a["north_star"], a["ui"], a["talks_to"], cell(a["check"]),
                                                                  star(a["status"]), a["today"] or "-", a["caveat"]) for a in d["agents"]],
    "| Component |": ["| %s | `%s` | %s | %s | %s |" % (c["name"], c["agent"], c["where"], c["as_of"], c["state"]) for c in d["components"]],
    "| Verdict |": ["| **%s** | %s |" % (star(k), v) for k, v in d["scoring"].items()],
    "| Today |": ["| %s | %s |" % (k, v) for k, v in d["today_values"].items()],
}
for head, rows in want.items():
    at = [i for i, l in enumerate(lines) if l.startswith(head + " ")]
    if len(at) != 1:
        sys.exit("the document has %d tables headed %r (want 1)" % (len(at), head))
    body = []
    for l in lines[at[0] + 2:]:
        if not l.startswith("|"):
            break
        body.append(l)
    for i in range(max(len(body), len(rows))):
        have = body[i] if i < len(body) else "(nothing)"
        need = rows[i] if i < len(rows) else "(nothing)"
        if have != need:
            sys.exit("the %s table's line %d differs from the register:\n  document: %s\n  register: %s" % (head.strip("| "), i + 1, have, need))
print("%d rows, %d agents, %d components and both legends" % (len(d["rows"]), len(d["agents"]), len(d["components"])))
PY
) || fail "docs/NORTH-STAR.md (${DOC}) does not say what the register says: ${P5}"
if [ -n "${ROOT}" ]; then
	cmp -s "${DOC}" /docs/NORTH-STAR.md || fail "the image's /docs/NORTH-STAR.md differs from the checkout's docs/NORTH-STAR.md - rebuild the image"
fi
echo "ok 5 - docs/NORTH-STAR.md carries the register's ${P5} line for line$([ -n "${ROOT}" ] && echo ", and the image's copy equals the checkout's")"

# --- 6. no private repository linked, no internal name ---
P6=$(python3 - "${REGISTER}" "${DOC}" 2>&1 << 'PY'
import re, sys
PUBLIC = ("https://github.com/dmvevents/communication-engine/", "https://github.com/dmvevents/tmux-agent-public/")
bad, n = [], 0
for path in sys.argv[1:]:
    for u in re.findall(r"""https?://[^\s<>"'`)\]]+""", open(path, encoding="utf-8").read()):
        n += 1
        if not u.startswith(PUBLIC):
            bad.append("%s links %s" % (path, u))
if bad:
    sys.exit("only the two public repositories may be linked: " + "; ".join(bad))
print("%d links, all under the two public repositories" % n)
PY
) || fail "${P6}"
python3 -I "${SCAN}" --tree "${REGISTER}" "${DOC}" > "${D}/scan.out" 2>&1 || fail "the privacy scan refuses the register or the document: $(tail -3 "${D}/scan.out" | tr '\n' ' ')"
echo "ok 6 - ${P6}; the privacy scan passes the register and the document ($(tail -1 "${D}/scan.out"))"

# --- 7. the served section carries every verdict ---
LOOP_DEFAULT=""   # unset reads as auto in slack-gates.sh, the .env default
[ -n "${ENV_FILE}" ] && LOOP_DEFAULT=$(grep -E '^export AUTONOMY_LOOP=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d "\"'")
# the page as a fresh clone renders it: .env's AUTONOMY_LOOP, no Slack, every other UI off
env -u SLACK_BOT_TOKEN -u SLACK_CHANNELS AUTONOMY_LOOP="${LOOP_DEFAULT}" UI_DIR="${D}/ui" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME="${PORT_HOME}" \
	UI_HOME=true UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false \
	UI_LOGLEARNER=false UI_CHAT=false UI_LOOP_DECK=false UI_LOOP=false COMMS_UI_ENABLED=false UI_PLANE=false UI_BOARD=false UI_FILES=false \
	PLANE_URL= KANBAN_BOARD_URL= NORTH_STAR_JSON="${REGISTER}" bash "${AGENT_DIR}/home-render.sh" > "${D}/render.log" 2>&1 \
	|| { cat "${D}/render.log"; fail "home-render.sh"; }
PAGE=${D}/ui/home/site/index.html
[ -s "${PAGE}" ] || fail "home-render.sh wrote no page at ${PAGE}"
P7=$(python3 - "${PAGE}" "${REGISTER}" 2>&1 << 'PY'
import html, json, re, sys
page = open(sys.argv[1], encoding="utf-8").read()
d = json.load(open(sys.argv[2], encoding="utf-8"))
sec = re.search(r'<section class="north-star[^>]*>.*?</section>', page, re.S)
if not sec:
    sys.exit("the page has no North Star section")
sec = sec.group(0)
text = lambda s: html.unescape(re.sub(r"<[^>]+>", "", s)).strip()
def cells(body):
    return {html.unescape(k): text(v) for k, v in re.findall(r'<td data-label="([^"]*)">(.*?)</td>', body, re.S)}
for r in d["rows"]:
    m = re.search(r'<tr data-ns-id="%s" data-ns-status="([^"]*)" data-ns-today="([^"]*)">(.*?)</tr>' % re.escape(html.escape(r["id"])), sec, re.S)
    if not m:
        sys.exit("row %s is not on the page" % r["id"])
    c = cells(m.group(3))
    want = {"Verdict": r["status"], "Today": r["today"] or "-", "Check": r["check"] or "no tracked check"}
    have = {k: c.get(k) for k in want}
    if (html.unescape(m.group(1)), html.unescape(m.group(2))) != (r["status"], r["today"] or "") or have != want:
        sys.exit("row %s: the page shows %r, the register says %r" % (r["id"], have, want))
for a in d["agents"]:
    m = re.search(r'<tr data-ns-agent="%s" data-ns-agent-status="([^"]*)" data-ns-agent-today="([^"]*)">(.*?)</tr>' % re.escape(html.escape(a["agent"])), sec, re.S)
    if not m:
        sys.exit("agent %s is not on the page with its verdict and today" % a["agent"])
    c = cells(m.group(3))
    want = {"Verdict": a["status"], "Today": a["today"] or "-", "Check": a["check"] or "no tracked check"}
    have = {k: c.get(k) for k in want}
    if (html.unescape(m.group(1)), html.unescape(m.group(2))) != (a["status"], a["today"] or "") or have != want:
        sys.exit("agent %s: the page shows %r, the register says %r" % (a["agent"], have, want))
URL = re.compile(r"""https?://[^\s<>"']*[^\s<>"'.,;:)]""")
for comp in d["components"]:
    m = re.search(r'<tr data-ns-component="%s">(.*?)</tr>' % re.escape(html.escape(comp["name"])), sec, re.S)
    if not m or cells(m.group(1)).get("Where its North Star lives") != comp["where"]:
        sys.exit("component %s: the page does not show where its North Star lives as the register does" % comp["name"])
    # each link in the cell goes exactly where its URL in the register points: no entity or punctuation in an href
    where = re.search(r'<td data-label="Where its North Star lives">(.*?)</td>', m.group(1), re.S).group(1)
    hrefs = [html.unescape(h) for h in re.findall(r'<a href="([^"]*)"', where)]
    if hrefs != URL.findall(comp["where"]):
        sys.exit("component %s: the page links %r, its where names %r" % (comp["name"], hrefs, URL.findall(comp["where"])))
print("%d rows, %d agents with their verdict, today and check, %d components" % (len(d["rows"]), len(d["agents"]), len(d["components"])))
PY
) || fail "the served North Star section: ${P7}"
# the document's page: md2html.py renders **YES\*** as YES* (a backslash escape), never as a stray backslash and a star
GUIDE_NS=${D}/ui/home/site/guide/north-star/index.html
[ -s "${GUIDE_NS}" ] || fail "home-render.sh wrote no /guide/north-star/ page at ${GUIDE_NS}"
verdict_cells()
{
	# verdict_cells <page> <register> - the page's verdict cells: one YES* per item scored YES* plus the legend's, none
	# showing a backslash
	python3 - "$1" "$2" 2>&1 << 'PY'
import json, re, sys
page = open(sys.argv[1], encoding="utf-8").read()
d = json.load(open(sys.argv[2], encoding="utf-8"))
stray = re.findall(r"<td><strong>[A-Z]*\\</strong>[^<]*</td>", page)
if stray:
    sys.exit("%d verdict cells show a stray backslash, e.g. %s" % (len(stray), stray[0]))
want = sum(1 for x in d["rows"] + d["agents"] if x["status"] == "YES*") + 1
have = page.count("<td><strong>YES*</strong></td>")
if have != want:
    sys.exit("the page shows %d YES* verdict cells, the register %d (its items scored YES* and the legend's)" % (have, want))
print("%d YES* verdict cells, none with a backslash" % have)
PY
}
P7G=$(verdict_cells "${GUIDE_NS}" "${REGISTER}") || fail "the served /guide/north-star/ page: ${P7G}"
# CONTROL: the page as a renderer without backslash escapes wrote it (<strong>YES\</strong>*) must fail, for that reason
python3 -c 'import sys; p = open(sys.argv[1], encoding="utf-8").read(); open(sys.argv[2], "w", encoding="utf-8").write(p.replace("<td><strong>YES*</strong></td>", "<td><strong>YES\\</strong>*</td>"))' "${GUIDE_NS}" "${D}/guide-ns-planted.html"
MG=$(verdict_cells "${D}/guide-ns-planted.html" "${REGISTER}") && fail "CONTROL: a page whose YES* cells keep a stray backslash passed: ${MG}"
echo "${MG}" | grep -q 'stray backslash' || fail "the backslash control failed for the wrong reason: ${MG}"
echo "ok 7 - the home page's North Star section shows ${P7}, as the register has them; /guide/north-star/ shows ${P7G}; control: ${MG}"

# --- 8. NS-2 on the default start path ---
GATE=$(env -u SLACK_BOT_TOKEN -u SLACK_CHANNELS AUTONOMY_LOOP="${LOOP_DEFAULT}" "${AGENT_DIR}/slack-gates.sh" loop 2>/dev/null)
[ "${GATE}" == "on" ] && fail "the default start path now starts the autonomy loop (AUTONOMY_LOOP=${LOOP_DEFAULT:-unset}, no Slack: the gate reads on): NS-2's FAIL on the default path is no longer true - score NS-2 again in docs/north-star.json and docs/NORTH-STAR.md, and this check with it"
[ "${GATE}" == "off" ] || fail "/agent/slack-gates.sh loop printed '${GATE}' (want on or off)"
STRIP=$(sed -n '/<section class="start"/,/<\/section>/p' "${PAGE}" | tr '\n' ' ')
echo "${STRIP}" | grep -qF 'until then the goal waits' && echo "${STRIP}" | grep -qF '<code>AUTONOMY_LOOP=true</code>' \
	|| fail "with the loop off on the default path the Start here strip does not say the goal waits and name AUTONOMY_LOOP=true: $(echo "${STRIP}" | grep -oE 'Give the agent a goal.{0,260}')"
echo "${STRIP}" | grep -qF 'picks it up at its next fire and writes' && fail "with the loop off on the default path the Start here strip promises the next fire"
NS2=$(python3 -c 'import json, sys; print(next(r["today"] for r in json.load(open(sys.argv[1]))["rows"] if r["id"] == "NS-2"))' "${REGISTER}")
[ "${NS2}" == "FAIL" ] || fail "the default start path runs no loop (AUTONOMY_LOOP=${LOOP_DEFAULT:-unset}, no Slack: the gate reads off), yet the register's NS-2 reads today ${NS2}"
echo "ok 8 - NS-2's default start path: AUTONOMY_LOOP=${LOOP_DEFAULT:-unset} with no Slack keeps the loop off, the Start here strip says the goal waits and names AUTONOMY_LOOP=true, and the register's NS-2 reads FAIL"

# --- 9. the register agrees with what a plain start runs ---
REGISTRY=${AGENT_DIR}/spokes/registry.json
[ -s "${REGISTRY}" ] || fail "no registry at ${REGISTRY}: the register's agents cannot be checked against what a plain start runs"
P9=$(python3 - "${REGISTER}" "${REGISTRY}" "${ENV_FILE}" 2>&1 << 'PY'
import json, re, sys
reg = json.load(open(sys.argv[1], encoding="utf-8"))
sessions = json.load(open(sys.argv[2], encoding="utf-8"))["sessions"]
env = {}
if sys.argv[3]:
    for line in open(sys.argv[3], encoding="utf-8"):
        m = re.match(r"^export ([A-Z_][A-Z0-9_]*)=(.*)$", line.strip())
        if m:
            env[m.group(1)] = m.group(2).strip().strip("\"'")
running = []
for e in sessions:
    value = env.get(e.get("flag") or "")
    on = value.lower() == "true" if value in ("true", "false", "True", "False") else bool(e.get("enabled"))
    if on:
        running.append(e["session_name"])
known = {e["session_name"] for e in sessions}
agents = {a["agent"]: a for a in reg["agents"]}
STALE = re.compile(r"\bno (?:\w+ )?(?:spokes?|supervisors?|stack|sessions?) runs?\b|\bonly the hub runs\b|\bnot on main\b", re.I)
miss = []
for n in running:
    if n not in agents:
        miss.append("a plain start runs %s, which the register does not score" % n)
    else:
        m = STALE.search(agents[n]["caveat"] or "")
        if m:
            miss.append("agent %s runs on a plain start, yet its caveat says %r" % (n, m.group(0)))
        if agents[n]["status"] == "NO" and not re.search(r"\bruns on a plain start\b", agents[n]["caveat"] or "", re.I):
            miss.append("agent %s runs on a plain start and is scored NO, yet its caveat does not say it runs" % n)
pending = [a for a in reg["agents"] if a["agent"] not in known]
for a in pending:
    if a["status"] != "NO" or not re.search(r"\blands? with\b", a["caveat"] or ""):
        miss.append("agent %s has no session in the registry, so it is scored NO and names the change it lands with" % a["agent"])
# an agent the registry lists has shipped its session: a caveat or an agents note that still says the session comes
# with a later change is out of date until the agent is scored again
SHIPS_LATER = re.compile(r"\bits session(?:, [\w ]+?)*(?: and [\w ]+?)? lands? with\b|\bbefore its session ships\b"
                         r"|\buntil its (?:own )?change ships it\b", re.I)
for a in reg["agents"]:
    if a["agent"] in known:
        m = SHIPS_LATER.search(a["caveat"] or "")
        if m:
            miss.append("agent %s has a session in the registry, yet its caveat says %r" % (a["agent"], m.group(0)))
for m in re.finditer(r"\bthe ([\w-]+) agent(?: is scored before its session ships|'s North Star comes from its pending charter)\b",
                     reg["agents_note"] or "", re.I):
    if m.group(1) in known:
        miss.append("the agents note says %r, yet %s has a session in the registry" % (m.group(0), m.group(1)))
if len(running) > 1:
    for where, text in [("the agents note", reg["agents_note"])] + [("row %s's caveat" % r["id"], r["caveat"]) for r in reg["rows"]]:
        m = STALE.search(text or "")
        if m:
            miss.append("%s says %r while a plain start runs %d sessions" % (where, m.group(0), len(running)))
if miss:
    sys.exit("; ".join(miss))
print("%d sessions on a plain start (%s), each scored and none said not to run; %d agent%s scored before %s session ships (%s), "
      "none the registry lists reads as pending, and each running agent scored NO says it runs"
      % (len(running), " ".join(running), len(pending), "" if len(pending) == 1 else "s", "its" if len(pending) == 1 else "their",
         " ".join(a["agent"] for a in pending) or "none"))
PY
) || fail "the register does not say what a plain start runs: ${P9}"
echo "ok 9 - the register agrees with the registry and .env's flags: ${P9}"

find /wd -mindepth 1 2>/dev/null | sort > "${D}/wd-after.txt"
cmp -s "${D}/wd-before.txt" "${D}/wd-after.txt" || fail "this test wrote under /wd: $(comm -13 "${D}/wd-before.txt" "${D}/wd-after.txt" | head -3 | tr '\n' ' ')"
echo "Test-north-star succeeded"
