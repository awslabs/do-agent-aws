#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the "Harness home" badge on EVERY UI the home page links to (/agent/home-render.sh: badge_html,
# badge.conf for path routes, badge-host.conf for the *.localhost host routes, badge-rule.conf inside a location's
# own sub_filter chain, the markup of the static pages the home listener serves). Fully OFFLINE: nginx with the
# rendered config on test-local ports, stub upstreams answering a minimal html page on every UI port, the image's
# real ttyd behind /tmux/ (whose page encoding is the trap), test-local state under /tmp/home-badge-smoke.
#
# Properties proven (each check FAILS if the property is removed):
#   1. home-render.sh and this test parse (bash -n)
#   2. coverage, read from the rendered nginx.conf with every UI flag on: every location that proxies a UI (all
#      but the dot probes' /__probe/ and /__probe_up/ status locations, the Learned rules tile's /__tile/ contract,
#      exact-match routes for one non-HTML file such as the Loop Deck's /history.jsonl and /mermaid.min.js, and
#      the bare redirects) includes a badge file - a *.localhost server badge-host.conf (or badge-host-nolink.conf, for a
#      page that links the stylesheet itself, badge-host-clear-<px>.conf, with a clearance, or badge-host-rule.conf, the rule
#      alone for a location that sets sub_filter_once itself), a path route (the loopback-named home server block)
#      badge.conf or badge-rule.conf, never the host one; the static cheatsheet carries the badge markup; the home
#      page names its tab do-agent-aws-home (the badge's target)
#   3. PLANTED CONTROL: a home-render.sh copy whose /tmux/ location lacks the include fails check 2, naming /tmux/
#   3b. PLANTED CONTROL: a copy whose home listener gives its memory API locations the HOST badge fails check 2, naming
#      /memory-api/ (a path route takes badge.conf or badge-rule.conf only, never a host badge)
#   4. every live tile opens its UI in a new tab that KEEPS its opener (rel="opener"): a noopener tab cannot reach
#      the named home tab, so the badge would open another home tab instead of returning
#   5. the injected bytes are really in each proxied page (a 200 alone proves nothing: sub_filter no-ops on a
#      compressed or unmatched body): every path route and every host route answers its page with the badge
#      exactly once, path routes with href="/", host routes with href="//localhost:<port>/" - ttyd's own page too; the
#      agent stack's two rendered guide pages, /guide/agent-stack/ and /guide/messaging/, carry it the same way
#   5b. the claude-mem viewer's page, and only it, carries the pre-dismiss of its welcome modal in <head> (before
#      its bundle runs); the other host pages do not
#   5c. the harness view of the claude-mem viewer (CLAUDE_MEM_VIEWER_WRAPPER, on by default): its page, and no other
#      host page, loads the view's script and stylesheet once, from the server's own /__harness/claude-mem/ (the
#      image's files, served byte for byte); the view's machine-prompt prefixes are the first sentences of loop.sh's
#      and slack-chat.sh's PROMPT=; CONTROL: CLAUDE_MEM_VIEWER_WRAPPER=false renders neither the location nor the
#      injection, while the default config does
#   6. the badge markup itself: target="do-agent-aws-home", the label, a border, the phone rule moving it to
#      the bottom left under 481 px, and the keeper script that moves the badge and that rule to the <html>
#      element and re-attaches them when removed (a single-page app re-rendering its body would drop them), and
#      on a narrow visual viewport pins the badge to its bottom left (a UI laid out wider than the phone);
#      no $ in the markup (nginx would read it as a variable in the sub_filter replacement)

D=/tmp/home-badge-smoke
rm -rf "${D:?}"
mkdir -p "${D}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"

export UI_DIR=${D}/ui
export UI_LISTEN_HOST=127.0.0.1
export UI_HOME=true UI_HEADLAMP=true UI_HINDSIGHT=true UI_VIBE_KANBAN=true UI_TMUX=true UI_TMUX_WRITABLE=true \
	UI_TMUX_AGENT=true UI_CLAUDE_MEM=true UI_LOGLEARNER=true COMMS_UI_ENABLED=true
export UI_PORT_HOME=18471 UI_PORT_HEADLAMP=18472 UI_PORT_HINDSIGHT_API=18473 UI_PORT_HINDSIGHT_UI=18474 \
	UI_PORT_VIBE_KANBAN=18475 UI_PORT_TMUX=18476 UI_PORT_TMUX_AGENT=18477 UI_PORT_CLAUDE_MEM=18478 \
	UI_PORT_LOGLEARNER=18479 COMMS_UI_PORT=18480
CONF=${UI_DIR}/home/nginx.conf
PIDS=()

cleanup()
{
	[ -f "${UI_DIR}/home/nginx.pid" ] && kill "$(cat "${UI_DIR}/home/nginx.pid")" 2>/dev/null
	for P in "${PIDS[@]}"; do kill "${P}" 2>/dev/null; done
}
trap cleanup EXIT

fail()
{
	echo "Test-home-badge FAILED: $1"
	exit 1
}

# --- 1. syntax ---
bash -n "${AGENT_DIR}/home-render.sh" || fail "bash -n home-render.sh"
bash -n "$0" || fail "bash -n $0"
echo "ok 1 - syntax"

# coverage <nginx.conf> - prints one line per proxied location WITHOUT the right badge include; exit 1 when any
coverage()
{
	python3 - "$1" << 'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
bad, seen, stack, server_names = [], 0, [], []
cur_server = None
blocks = []                      # (server_name, location, body)
i = 0
tokens = re.split(r"(\{|\}|;)", text)
buf = ""
for t in tokens:
    if t == "{":
        head = buf.strip().split("\n")[-1].strip()
        stack.append([head, ""])
        buf = ""
    elif t == "}":
        head, body = stack.pop()
        body += buf
        if head.startswith("location"):
            srv = next((b for b in reversed(stack) if b[0] == "server"), None)
            name = re.search(r"server_name\s+([^;\s]+)", srv[1]).group(1) if srv and re.search(r"server_name\s+([^;\s]+)", srv[1]) else "_"
            blocks.append((name, head, body))
        if stack:
            stack[-1][1] += head + " {...} "
        buf = ""
    else:
        if t == ";":
            buf += ";"
            if stack:
                stack[-1][1] += buf
            buf = ""
        else:
            buf += t
for name, head, body in blocks:
    if "proxy_pass" not in body or re.search(r"/__(probe(_up)?|tile)/", head):
        continue
    if re.match(r"location\s*=\s*/\S+\.(?!html?$)[A-Za-z0-9]+$", head):
        continue                 # an exact-match route for one file (a JSONL feed, a script): no HTML page to carry the badge
    seen += 1
    files = set(re.findall(r"include\s+\S*/(badge(?:-host|-host-nolink|-host-rule|-host-clear-[^/;\s]+|-rule)?\.conf)", body))
    host_route = name.endswith(".localhost")
    if host_route and (len(files) != 1 or not re.fullmatch(r"badge-host(-nolink|-rule|-clear-[^/;\s]+)?\.conf", next(iter(files)))):
        bad.append(f"{name} {head}: {sorted(files) or 'no badge include'} (a host route needs badge-host.conf, or its variant for a page that links the stylesheet itself, needs a clearance, or runs its own sub_filter chain)")
    if not host_route and (not files or not files <= {"badge.conf", "badge-rule.conf"}):
        bad.append(f"{name} {head}: {sorted(files) or 'no badge include'} (a path route needs badge.conf or badge-rule.conf, never a host badge)")
print(f"proxied locations: {seen}")
for b in bad:
    print("UNCOVERED " + b)
sys.exit(1 if bad or not seen else 0)
PYEOF
}

# --- 2. coverage with every UI on ---
"${AGENT_DIR}/home-render.sh" > /dev/null || fail "home-render.sh"
coverage "${CONF}" > ${D}/coverage.log || fail "a proxied UI location lacks the badge: $(grep UNCOVERED ${D}/coverage.log | tr '\n' ' ')"
grep -q 'id="do-agent-aws-home"' "${UI_DIR}/home/site/tmux-help/index.html" || fail "the static cheatsheet carries no badge"
grep -qF "window.name = 'do-agent-aws-home'" "${UI_DIR}/home/site/index.html" || fail "the home page does not name its tab do-agent-aws-home"
echo "ok 2 - every proxied UI location carries the badge ($(head -1 ${D}/coverage.log)); the cheatsheet carries it; the home page names its tab"

# --- 3. planted control: one route without its include ---
mkdir -p ${D}/mutant
python3 - "${AGENT_DIR}/home-render.sh" ${D}/mutant/home-render.sh << 'PYEOF'
import sys
s = open(sys.argv[1]).read()
anchor = "proxy_pass http://127.0.0.1:${UI_PORT_TMUX};\n\t\t\tinclude ${HOME_DIR}/proxy-common.conf;\n\t\t\tinclude ${HOME_DIR}/badge.conf;"
assert anchor in s, "the /tmux/ include is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, anchor.rsplit("\n", 1)[0]))
PYEOF
[ -s ${D}/mutant/home-render.sh ] || fail "could not plant the control"
UI_DIR=${D}/mutant-ui bash ${D}/mutant/home-render.sh > /dev/null || fail "the mutant home-render.sh did not render"
coverage ${D}/mutant-ui/home/nginx.conf > ${D}/coverage-mutant.log && fail "PLANTED CONTROL: a /tmux/ location without the badge include passed the coverage check"
grep -q "UNCOVERED localhost location /tmux/" ${D}/coverage-mutant.log || fail "the control failed for the wrong reason: $(cat ${D}/coverage-mutant.log)"
echo "ok 3 - planted control: without its include /tmux/ fails the coverage check ($(grep UNCOVERED ${D}/coverage-mutant.log))"
# --- 3b. planted control: a host badge on the home listener's memory API location ---
# the memory API's locations take their badge include as an argument (memory_api_locations); the home listener must get
# the path badge - a host badge there would point every docs page at a host that is not the home page. PLANTED: a copy
# whose home listener passes the host variant fails the coverage check, naming /memory-api/
mkdir -p ${D}/mutant-host
python3 - "${AGENT_DIR}/home-render.sh" ${D}/mutant-host/home-render.sh << 'PYEOF'
import sys
s = open(sys.argv[1]).read()
anchor = "$(memory_api_locations badge-rule.conf)"
assert s.count(anchor) == 1, "the home listener's memory API call is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, "$(memory_api_locations badge-host-rule.conf)"))
PYEOF
[ -s ${D}/mutant-host/home-render.sh ] || fail "could not plant the host-badge control"
UI_DIR=${D}/mutant-host-ui bash ${D}/mutant-host/home-render.sh > /dev/null || fail "the host-badge mutant home-render.sh did not render"
coverage ${D}/mutant-host-ui/home/nginx.conf > ${D}/coverage-mutant-host.log && fail "PLANTED CONTROL: the home listener's memory API location with a host badge passed the coverage check"
grep -q "UNCOVERED localhost location /memory-api/" ${D}/coverage-mutant-host.log || fail "the host-badge control failed for the wrong reason: $(cat ${D}/coverage-mutant-host.log)"
echo "ok 3b - planted control: a host badge on the home listener's /memory-api/ fails the coverage check ($(grep -c UNCOVERED ${D}/coverage-mutant-host.log) locations named)"

# --- 4. tiles keep the opener ---
PAGE=${UI_DIR}/home/site/index.html
LIVE=$(grep -c '<li class="tile" ' "${PAGE}")
[ "${LIVE}" -ge 10 ] || fail "only ${LIVE} live tiles rendered"
[ "$(grep '<li class="tile" ' "${PAGE}" | grep -c 'target="_blank" rel="opener"')" == "${LIVE}" ] || fail "a live tile does not open with target=_blank rel=opener"
grep '<li class="tile" ' "${PAGE}" | grep -q 'noopener' && fail "a live tile still opens noopener (the badge could not return to the home tab)"
echo "ok 4 - all ${LIVE} live tiles open a new tab that keeps its opener"

# --- 5. the injected bytes through the proxy ---
if ! command -v nginx > /dev/null || ! command -v ttyd > /dev/null; then
	echo "Test-home-badge skipped checks 5-6: nginx/ttyd not installed (setup/install-nginx.sh, setup/install-ttyd.sh)"
	exit 0
fi
cat > ${D}/stub.py << 'PYEOF'
import sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        b = b"<!doctype html><html><head><title>stub</title></head><body><p>stub ui</p></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
servers = [ThreadingHTTPServer(("127.0.0.1", int(p)), H) for p in sys.argv[1:]]
for s in servers[1:]:
    threading.Thread(target=s.serve_forever, daemon=True).start()
servers[0].serve_forever()
PYEOF
python3 ${D}/stub.py ${UI_PORT_HEADLAMP} ${UI_PORT_HINDSIGHT_API} ${UI_PORT_HINDSIGHT_UI} ${UI_PORT_VIBE_KANBAN} \
	${UI_PORT_TMUX_AGENT} ${UI_PORT_CLAUDE_MEM} ${UI_PORT_LOGLEARNER} ${COMMS_UI_PORT} > ${D}/stub.log 2>&1 &
PIDS+=($!)
ttyd -p "${UI_PORT_TMUX}" -b /tmux -i lo bash > ${D}/ttyd.log 2>&1 &
PIDS+=($!)
nginx -c "${CONF}" -g "daemon off;" > ${D}/nginx.log 2>&1 &
PIDS+=($!)
H=http://127.0.0.1:${UI_PORT_HOME}
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "${H}/" && break; sleep 0.2; done
# body <url> [<host header>] - the proxied body as the browser would get it (no gzip asked)
body() { if [ -n "$2" ]; then curl -s --max-time 5 -H "Host: $2" "$1"; else curl -s --max-time 5 "$1"; fi; }
N=0
for P in /headlamp/ /memory-api/docs /comms/ /tmux/ /tmux-agent/ /tmux-help/ /guide/agent-stack/ /guide/messaging/; do
	B=""
	for _ in $(seq 1 25); do B=$(body "${H}${P}"); [ -n "${B}" ] && break; sleep 0.2; done
	C=$(echo "${B}" | grep -o 'id="do-agent-aws-home"' | wc -l)
	[ "${C}" == "1" ] || fail "${P}: the proxied page carries the badge ${C} times (want exactly 1)"
	echo "${B}" | grep -qF 'href="/" title="do-agent-aws harness home"' || fail "${P}: the badge does not return to href=\"/\""
	N=$((N + 1))
done
for HOST in hindsight kanban claude-mem loglearner; do
	B=$(body "${H}/" "${HOST}.localhost:${UI_PORT_HOME}")
	C=$(echo "${B}" | grep -o 'id="do-agent-aws-home"' | wc -l)
	[ "${C}" == "1" ] || fail "${HOST}.localhost: the proxied page carries the badge ${C} times (want exactly 1)"
	echo "${B}" | grep -qF "href=\"//localhost:${UI_PORT_HOME}/\" title=\"do-agent-aws harness home\"" || fail "${HOST}.localhost: the badge does not return to //localhost:${UI_PORT_HOME}/"
	N=$((N + 1))
done
for HOST in hindsight kanban claude-mem loglearner; do
	B=$(body "${H}/" "${HOST}.localhost:${UI_PORT_HOME}")
	PRE=$(echo "${B}" | grep -c '<head><script>try{localStorage.setItem("claude-mem-welcome-dismissed-v3","true")}catch(e){}</script>')
	if [ "${HOST}" == "claude-mem" ]; then
		[ "${PRE}" == "1" ] || fail "the claude-mem viewer's page does not pre-dismiss its welcome modal in <head>"
	else
		[ "${PRE}" == "0" ] || fail "${HOST}.localhost carries claude-mem's welcome pre-dismiss"
	fi
done
echo "ok 5b - the claude-mem viewer's page pre-dismisses its welcome modal in <head>; the other host pages do not"
# the harness view (CLAUDE_MEM_VIEWER_WRAPPER, on by default): the viewer's page, and only it, loads its script and
# stylesheet from the server's own /__harness/claude-mem/ location, which serves the image's files
VIEW_TAGS='<link rel="stylesheet" href="/__harness/claude-mem/harness-view.css"><script src="/__harness/claude-mem/harness-view.js" defer></script></head>'
for HOST in hindsight kanban claude-mem loglearner; do
	B=$(body "${H}/" "${HOST}.localhost:${UI_PORT_HOME}")
	V=$(echo "${B}" | grep -cF "${VIEW_TAGS}")
	if [ "${HOST}" == "claude-mem" ]; then
		[ "${V}" == "1" ] || fail "the claude-mem viewer's page does not load the harness view once (${V})"
	else
		[ "${V}" == "0" ] || fail "${HOST}.localhost loads the claude-mem harness view"
	fi
done
for F in harness-view.js harness-view.css; do
	curl -s --max-time 5 -H "Host: claude-mem.localhost:${UI_PORT_HOME}" "${H}/__harness/claude-mem/${F}" > ${D}/served-${F}
	cmp -s ${D}/served-${F} "${AGENT_DIR}/claude-mem-wrapper/${F}" || fail "/__harness/claude-mem/${F} on the claude-mem host is not the image's ${F}"
done
# the prompts it folds are the harness's own, word for word: the first sentence of every prompt of the loop (its
# supervisor mode's workers' too) and of the chat responder's
for S in loop.sh slack-chat.sh; do
	FIRSTS=$(sed -n 's/^[[:space:]]*PROMPT="\([^.]*\.\).*/\1/p' "${AGENT_DIR}/${S}")
	[ -n "${FIRSTS}" ] || fail "no PROMPT= line in ${S} to compare the harness view with"
	while IFS= read -r FIRST; do
		grep -qF "\"${FIRST}\"" "${AGENT_DIR}/claude-mem-wrapper/harness-view.js" || fail "the harness view does not fold ${S}'s prompt (\"${FIRST}\")"
	done <<< "${FIRSTS}"
done
# CONTROL: CLAUDE_MEM_VIEWER_WRAPPER=false renders neither the location nor the injection (the stock viewer)
( export UI_DIR=${D}/ui-stock CLAUDE_MEM_VIEWER_WRAPPER=false; "${AGENT_DIR}/home-render.sh" > /dev/null 2>&1 ) || fail "home-render.sh with CLAUDE_MEM_VIEWER_WRAPPER=false"
grep -q '__harness/claude-mem' ${D}/ui-stock/home/nginx.conf && fail "CLAUDE_MEM_VIEWER_WRAPPER=false still serves or injects the harness view"
grep -q '__harness/claude-mem' "${CONF}" || fail "CONTROL BROKEN: the default config names no harness view to compare the stock one with"
echo "ok 5c - the claude-mem viewer's page, and only it, loads the harness view from its own /__harness/claude-mem/ (the image's files, served as they are); the view folds every prompt of the loop (its workers' too) and the chat responder's word for word; CLAUDE_MEM_VIEWER_WRAPPER=false renders neither (control: the default does)"
TT=$(body "${H}/tmux/")
echo "${TT}" | grep -qi "ttyd\|xterm" || fail "/tmux/ did not serve ttyd's own page through the proxy"
echo "ok 5 - the badge bytes are in all ${N} pages exactly once (path routes href=\"/\", host routes //localhost:${UI_PORT_HOME}/), ttyd's real page and the agent stack's two guide pages included"

# --- 6. the markup ---
BADGE=$(grep -o '<a [^>]*id="do-agent-aws-home"[^>]*>[^<]*</a><style id="do-agent-aws-home-style">[^<]*</style><script>[^<]*</script>' "${UI_DIR}/home/badge.conf")
[ -n "${BADGE}" ] || fail "badge.conf carries no badge markup"
# the design system's badge: the stylesheet link, then the markup opening with class="hs-badge" data-harness-home
# (test-ui-style.sh reads the two as one string)
grep -qF '<link rel="stylesheet" href="/__harness/harness.css"><a class="hs-badge" data-harness-home ' "${UI_DIR}/home/badge.conf" \
	|| fail "badge.conf does not open the badge with class=\"hs-badge\" data-harness-home right after the stylesheet link"
for P in 'target="do-agent-aws-home"' '>&#8962; home</a>' 'border:1px solid' '@media (max-width:480px)' 'left:10px!important' 'right:auto!important' \
         'document.documentElement' 'new MutationObserver(k).observe(r,{childList:true})' 'r.appendChild(b)' 'r.appendChild(s)' \
         'window.visualViewport' '480>=v.width' 'v.addEventListener("scroll",p)'; do
	echo "${BADGE}" | grep -qF "${P}" || fail "the badge markup lacks ${P}"
done
echo "${BADGE}" | grep -qF '$' && fail "the badge markup carries a \$ (nginx would read it as a variable)"
echo "ok 6 - the badge opens with class=\"hs-badge\" data-harness-home right after the stylesheet link, targets the named home tab, reads '&#8962; home', has a border, moves bottom-left under 481 px, and its keeper script re-attaches it to <html>"

echo "Test-home-badge succeeded"
