#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the LogLearner dashboard's Content-Security-Policy (/agent/loglearner-csp.py and the loglearner.localhost route
# of /agent/home-render.sh). The vendored dashboard (opt/loglearner, 0.1.11) puts the search page's transcript snippets into the
# page without escaping them; the route's policy lets only the dashboard's own scripts run. Each check FAILS on what it guards:
#   1. syntax
#   2. the reader names each inline script and event handler of the release by its sha256 and its CDN script by URL, never
#      'unsafe-inline'; planted control: a copy with a changed inline script gets another hash
#   3. home-render.sh writes the policy (the badge's keeper among its scripts) and includes it in the loglearner.localhost route;
#      with UI_LOGLEARNER=false neither the file nor the include is rendered
#   4. live: a transcript line carrying an event handler and a script reaches the search page raw (the release's flaw, which is
#      why the policy is there); every inline script and handler the dashboard's own pages serve is in the policy, the planted
#      ones are not
# Test-local: /tmp/loglearner-csp-smoke (TEST_LOGLEARNER_CSP_DIR) and port 17788; never /wd.

AGENT_DIR=${AGENT_DIR:-/agent}
LOGLEARNER_DIR=${LOGLEARNER_DIR:-/opt/loglearner}
APP="${LOGLEARNER_DIR}/dashboard/app.py"
D=${TEST_LOGLEARNER_CSP_DIR:-/tmp/loglearner-csp-smoke}
PORT=17788
SERVE_PID=""
cleanup() { [ -n "${SERVE_PID}" ] && kill -- -"${SERVE_PID}" 2> /dev/null; }
fail() { echo "Test-loglearner-csp FAILED: $*"; cleanup; exit 1; }
trap cleanup EXIT
[ -f "${APP}" ] || { echo "Test-loglearner-csp skipped: no LogLearner dashboard at ${APP}"; exit 0; }
mkdir -p "${D}" || fail "cannot create ${D}"

# 1. syntax
bash -n "${AGENT_DIR}/home-render.sh" || fail "1: home-render.sh"
python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${AGENT_DIR}/loglearner-csp.py" || fail "1: loglearner-csp.py"
echo "ok 1 - syntax"

# 2. the reader on the release, and a planted change
SRCS=$(python3 -I "${AGENT_DIR}/loglearner-csp.py" "${APP}") || fail "2: the reader failed on ${APP}"
python3 -I - "${APP}" "${SRCS}" << 'PY' || fail "2: the reader's sources do not match the release"
import ast, base64, hashlib, re, sys
src, got = open(sys.argv[1]).read(), sys.argv[2].split()
h = lambda s: "'sha256-" + base64.b64encode(hashlib.sha256(s.encode()).digest()).decode() + "'"
consts = {n.targets[0].id: ast.literal_eval(n.value) for n in ast.parse(src).body
          if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("JS", "GRAPH_JS")}
want = [h(consts["JS"]), h(consts["GRAPH_JS"]), h("window.HIND=1"), h("window.HIND=0"), "'unsafe-hashes'"]
want += [h(x) for x in set(re.findall(r' on[a-z]+="([^"]*)"', src))]
want += ["https://unpkg.com/cytoscape@3.30.2/dist/cytoscape.min.js"]
missing = [w for w in want if w not in got]
assert not missing, "missing %s" % missing
assert "'unsafe-inline'" not in got, "the reader allows any inline script"
PY
sed 's/^JS = """/JS = """\/\/ planted change\n/' "${APP}" > "${D}/app-changed.py"
CHANGED=$(python3 -I "${AGENT_DIR}/loglearner-csp.py" "${D}/app-changed.py") || fail "2: the reader failed on the planted copy"
[ "$(echo "${CHANGED}" | cut -d' ' -f1)" != "$(echo "${SRCS}" | cut -d' ' -f1)" ] \
	|| fail "2: PLANTED CONTROL: a changed inline script kept its hash"
echo "ok 2 - the reader names $(echo "${SRCS}" | wc -w | tr -d ' ') sources (4 inline scripts, 2 handlers with 'unsafe-hashes', 1 CDN script), no 'unsafe-inline'; a changed script gets another hash"

# 3. the route renders it
render()
{
	# render <dir> <UI_LOGLEARNER>
	( export UI_DIR="$1" UI_LOGLEARNER="$2" UI_HOME=true UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_HEADLAMP=false UI_CLAUDE_MEM=false \
		UI_TMUX=false UI_TMUX_AGENT=false UI_CHAT=false UI_LOOP=false UI_LOOP_DECK=false UI_FILES=false UI_BOARD=false UI_PLANE=false \
		UI_PORT_LOGLEARNER=${PORT}; "${AGENT_DIR}/home-render.sh" > "$1.log" 2>&1 )
}
render "${D}/ui-on" true || fail "3: home-render.sh with UI_LOGLEARNER=true: $(tail -3 "${D}/ui-on.log")"
POLICY=$(sed -n 's/^add_header Content-Security-Policy "\(.*\)" always;$/\1/p' "${D}/ui-on/home/csp-loglearner.conf" 2> /dev/null)
[ -n "${POLICY}" ] || fail "3: no policy in ${D}/ui-on/home/csp-loglearner.conf"
for S in ${SRCS} "default-src 'self'" "connect-src 'self'" "img-src 'self' data:" "object-src 'none'" "base-uri 'none'" "form-action 'self'"; do
	case "${POLICY}" in *"${S}"*) ;; *) fail "3: the rendered policy lacks ${S}: ${POLICY}" ;; esac
done
case "${POLICY}" in *"script-src 'self' 'sha256-"*) ;; *) fail "3: the badge's keeper is not the first script source: ${POLICY}" ;; esac
SCRIPT_SRC=$(echo "${POLICY}" | tr ';' '\n' | grep -E '^ *script-src ')
case "${SCRIPT_SRC}" in *"'unsafe-inline'"*) fail "3: script-src allows any inline script: ${SCRIPT_SRC}" ;; esac
sed -n '/server_name loglearner.localhost;/,/^\t}/p' "${D}/ui-on/home/nginx.conf" | grep -qF "include ${D}/ui-on/home/csp-loglearner.conf;" \
	|| fail "3: the loglearner.localhost route does not send the policy"
render "${D}/ui-off" false || fail "3: home-render.sh with UI_LOGLEARNER=false: $(tail -3 "${D}/ui-off.log")"
[ -e "${D}/ui-off/home/csp-loglearner.conf" ] && fail "3: UI_LOGLEARNER=false wrote the LogLearner policy"
grep -q "csp-loglearner" "${D}/ui-off/home/nginx.conf" && fail "3: UI_LOGLEARNER=false includes the LogLearner policy"
echo "ok 3 - home-render.sh sends the policy on the loglearner.localhost route (the badge's keeper first); UI_LOGLEARNER=false renders neither"

# 4. live: the dashboard's own pages against the policy, and a planted transcript line
mkdir -p "${D}/home/.claude/projects/-wd" "${D}/state"
python3 -I - "${D}/home/.claude/projects/-wd/planted-0001.jsonl" << 'PY'
import json, sys
text = 'zqxplanted <img src=x onerror="alert(7)"> <script>alert(8)</script> zqxplanted'
lines = [{"type": "user", "sessionId": "planted-0001", "cwd": "/wd", "timestamp": "2026-11-10T00:00:00Z",
          "message": {"role": "user", "content": text}},
         {"type": "assistant", "sessionId": "planted-0001", "cwd": "/wd", "timestamp": "2026-11-10T00:00:01Z",
          "message": {"role": "assistant", "content": [{"type": "text", "text": "noted " + text}]}}]
open(sys.argv[1], "w").write("\n".join(json.dumps(l) for l in lines) + "\n")
PY
env HOME="${D}/home" LOGLEARNER_STATE="${D}/state" UI_PORT_LOGLEARNER=${PORT} LOGLEARNER_INDEX_INTERVAL=0 LOGLEARNER_SEED_PACK= \
	UI_HINDSIGHT=false setsid bash "${AGENT_DIR}/loglearner-serve.sh" > "${D}/serve.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 1 120); do
	curl -s --max-time 2 "http://127.0.0.1:${PORT}/search?q=zqxplanted" 2> /dev/null | grep -q "zqxplanted" && break
	sleep 1
done
curl -s --max-time 5 "http://127.0.0.1:${PORT}/search?q=zqxplanted" > "${D}/search.html"
grep -q "zqxplanted" "${D}/search.html" || fail "4: the planted line was not found by the search page in 120 s: $(tail -5 "${D}/serve.log")"
for P in / /instincts /learnings /knowledge /graph; do
	curl -s --max-time 5 "http://127.0.0.1:${PORT}${P}" > "${D}/page-$(echo "${P}" | tr -d /).html"
done
python3 -I - "${POLICY}" "${D}"/search.html "${D}"/page-*.html << 'PY' || fail "4: the policy does not match what the pages serve"
import base64, hashlib, re, sys
policy, pages = sys.argv[1], sys.argv[2:]
script_src = next(d for d in policy.split(";") if d.strip().startswith("script-src")).split()
h = lambda s: "'sha256-" + base64.b64encode(hashlib.sha256(s.encode()).digest()).decode() + "'"
raw = open(pages[0]).read()
assert '<img src=x onerror="alert(7)">' in raw and "<script>alert(8)</script>" in raw, \
    "the planted markup is escaped on the search page: the release changed, re-check the reader and this test"
own, planted = set(), set()
for p in pages:
    html = open(p).read()
    for body in re.findall(r"<script>(.*?)</script>", html, re.S):
        (planted if "alert(8)" in body else own).add(("script", body))
    for value in re.findall(r' on[a-z]+="([^"]*)"', html):
        (planted if "alert(7)" in value else own).add(("handler", value))
own = {x for x in own if not x[1].startswith("(function(){var r=document.documentElement")}   # the badge's keeper, not served here
assert planted == {("script", "alert(8)"), ("handler", "alert(7)")}, "planted: %s" % planted
for kind, body in own:
    assert h(body) in script_src, "%s of the dashboard not in the policy: %r" % (kind, body[:60])
for kind, body in planted:
    assert h(body) not in script_src, "planted %s allowed" % kind
assert "'unsafe-inline'" not in script_src
print("    %d inline scripts and handlers of the dashboard's own pages allowed, the planted script and handler not" % len(own))
PY
echo "ok 4 - live: the planted handler and script reach the search page raw, and the policy allows every inline script and handler the dashboard serves but not them"

cleanup; SERVE_PID=""
rm -rf "${D:?}"
echo "Test-loglearner-csp succeeded"
