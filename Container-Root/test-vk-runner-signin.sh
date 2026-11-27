#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of /agent/vk-runner-signin.py, the agent runner's sign-in to the self-hosted board with the relay on
# (UI_KANBAN_RELAY=true, docs/manual/boards.md "Kanban board"), stored before the runner starts. Fully OFFLINE: a stub board on a
# test-local port answers the board's local login and records what it is sent. Each check FAILS if the property it
# proves is removed:
#   1. a board that takes the login: the helper stores the board's refresh token in VK_CREDENTIALS as the runner stores
#      its sign-in (that one field, mode 600, no temporary file left), one line, exit 0; its only request is the
#      board's POST /v1/auth/local/login (never the runner's own sign-in, which turns the runner's analytics on), with
#      the login file's pair in the body; neither the password nor the token is in its output; an earlier start's
#      sign-in is replaced
#   2. a board that refuses the login: exit 3, a line that says so without the password, nothing stored
#   3. a board that answers the login with a redirect: exit 2, the redirect not followed, nothing stored; a board that
#      fails the login (HTTP 500) until VK_SIGNIN_WAIT ends: exit 2
#   4. a KANBAN_BOARD_URL off loopback that is not a single-label docker name, or none, a VK_CREDENTIALS that is not a
#      credentials.json, a login file that is missing or has no password: exit 4, nothing sent, nothing stored
#   5. a board that never answers: exit 2 within VK_SIGNIN_WAIT, nothing stored
#   6. PLANTED CONTROL: a copy of the helper that prints the token fails check 1's output scan
set -u
D=/tmp/vk-runner-signin-smoke
rm -rf "${D:?}"
mkdir -p "${D}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="${BASE_DIR%/}/agent/vk-runner-signin.py"
PORT=18291
STUB_PID=""
fail()
{
	echo "Test-vk-runner-signin FAILED: $*"
	[ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2> /dev/null
	exit 1
}
[ -x "${HELPER}" ] || fail "no executable ${HELPER}"
# ast.parse, not py_compile: the latter writes a __pycache__ next to the source, and the checkout is mounted read-only
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${HELPER}" || fail "python3 cannot parse ${HELPER}"
PASSWORD="planted-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
TOKEN="refresh-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf 'SELF_HOST_LOCAL_AUTH_EMAIL=agent@do-agent-aws.local\nSELF_HOST_LOCAL_AUTH_PASSWORD=%s\n' "${PASSWORD}" > ${D}/kanban.env
chmod 600 ${D}/kanban.env
cat > ${D}/stub-board.py << 'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT, STATE, LOG, TOKEN = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]  # STATE: ok, refuse, redirect, fail
class H(BaseHTTPRequestHandler):
    def _json(self, code, obj, extra=()):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        open(LOG, "ab").write(b"GET " + self.path.encode() + b"\n")
        return self._json(404, {})
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(LOG, "ab").write(b"POST " + self.path.encode() + b" " + body + b"\n")
        if self.path != "/v1/auth/local/login":
            return self._json(404, {})
        if STATE == "refuse":
            return self._json(401, {"error": "invalid credentials"})
        if STATE == "fail":
            return self._json(500, {"error": "database unavailable"})
        if STATE == "redirect":
            return self._json(302, {}, [("Location", f"http://127.0.0.1:{PORT}/elsewhere")])
        return self._json(200, {"access_token": "access-not-stored", "refresh_token": TOKEN})
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF
# stub <ok|refuse|redirect|fail> - (re)start the stub board in that state, with an empty request log
stub()
{
	[ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2> /dev/null && sleep 0.3
	: > ${D}/requests.log
	python3 ${D}/stub-board.py ${PORT} "$1" ${D}/requests.log "${TOKEN}" > ${D}/stub.log 2>&1 &
	STUB_PID=$!
	for _ in $(seq 1 40); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${PORT}/" && { : > ${D}/requests.log; return 0; }; sleep 0.1; done
	fail "the stub board did not start: $(cat ${D}/stub.log)"
}
CREDS=${D}/data/vibe-kanban/credentials.json
signin()
{
	# signin [<env NAME=value>...] - the helper against the stub, its output in ${D}/out.txt, its exit code echoed
	env KANBAN_BOARD_URL="http://127.0.0.1:${PORT}" KANBAN_AUTH_FILE=${D}/kanban.env VK_CREDENTIALS=${CREDS} VK_SIGNIN_WAIT=10 \
		"$@" python3 -B "${HELPER}" > ${D}/out.txt 2>&1
	echo $?
}
nothing_stored()
{
	# nothing_stored <check> - no credentials file and no temporary file
	[ -e "${CREDS}" ] && fail "$1: a sign-in was stored: $(ls -la "${CREDS}")"
	[ -z "$(find ${D}/data -name '.credentials-*' 2> /dev/null)" ] || fail "$1: a temporary file was left: $(find ${D}/data -name '.credentials-*')"
}

# --- 1. a board that takes the login: the runner's sign-in stored ---
stub ok
mkdir -p "$(dirname "${CREDS}")"
echo '{"refresh_token": "an-earlier-start"}' > "${CREDS}"
RC=$(signin)
[ "${RC}" == "0" ] || fail "1: exit ${RC}, not 0: $(cat ${D}/out.txt)"
grep -qx "vk-runner-signin: the runner's sign-in to the board at http://127.0.0.1:${PORT} as agent@do-agent-aws.local is stored in ${CREDS} (it loads it when it starts)" ${D}/out.txt \
	|| fail "1: the line does not say the sign-in is stored: $(cat ${D}/out.txt)"
[ "$(grep -c . ${D}/out.txt)" == "1" ] || fail "1: more than one line: $(cat ${D}/out.txt)"
python3 - "${CREDS}" "${TOKEN}" << 'PYEOF' || fail "1: ${CREDS} is not the runner's sign-in as the runner stores it"
import json, os, stat, sys
d = json.load(open(sys.argv[1]))
assert d == {"refresh_token": sys.argv[2]}, sorted(d)
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600, oct(os.stat(sys.argv[1]).st_mode)
PYEOF
[ -z "$(find ${D}/data -name '.credentials-*')" ] || fail "1: a temporary file was left: $(find ${D}/data -name '.credentials-*')"
[ "$(grep -c . ${D}/requests.log)" == "1" ] || fail "1: not exactly one request reached the board: $(cut -c1-60 ${D}/requests.log)"
grep -q "^POST /v1/auth/local/login " ${D}/requests.log || fail "1: the request was not the board's POST /v1/auth/local/login: $(cut -c1-40 ${D}/requests.log)"
grep -qF "\"email\": \"agent@do-agent-aws.local\", \"password\": \"${PASSWORD}\"" ${D}/requests.log || fail "1: the login file's pair is not in the login's body"
grep -qF "${PASSWORD}" ${D}/out.txt && fail "1: the password is in the helper's output"
grep -qF "${TOKEN}" ${D}/out.txt && fail "1: the refresh token is in the helper's output"
echo "ok 1 - the board's refresh token is stored as the runner stores its sign-in (one field, mode 600, no temporary file), replacing an earlier one; one line, exit 0; one request, the board's login, the pair only in its body"

# --- 2. a board that refuses the login: exit 3, nothing stored ---
rm -f "${CREDS:?}"
stub refuse
RC=$(signin)
[ "${RC}" == "3" ] || fail "2: a refused login: exit ${RC}, not 3: $(cat ${D}/out.txt)"
grep -q "the board refused the runner's sign-in as agent@do-agent-aws.local (HTTP 401) - the runner starts signed out" ${D}/out.txt \
	|| fail "2: the line does not say the board refused it: $(cat ${D}/out.txt)"
grep -qF "${PASSWORD}" ${D}/out.txt && fail "2: the password is in the helper's output"
nothing_stored 2
echo "ok 2 - a login the board refuses: exit 3, says so without the password, nothing stored"

# --- 3. a redirect is not followed; a failing board: exit 2 ---
stub redirect
RC=$(signin)
[ "${RC}" == "2" ] || fail "3: a redirected login: exit ${RC}, not 2: $(cat ${D}/out.txt)"
grep -q "answered the login with a redirect (HTTP 302), not followed" ${D}/out.txt || fail "3: the line does not name the redirect: $(cat ${D}/out.txt)"
grep -q "/elsewhere" ${D}/requests.log && fail "3: the redirect was followed"
nothing_stored 3
stub fail
T0=$(date +%s)
RC=$(signin VK_SIGNIN_WAIT=3)
[ "${RC}" == "2" ] || fail "3: a board that fails the login: exit ${RC}, not 2: $(cat ${D}/out.txt)"
grep -q "did not answer the login within 3s (last HTTP 500)" ${D}/out.txt || fail "3: the line does not say the board failed: $(cat ${D}/out.txt)"
[ $(( $(date +%s) - T0 )) -le 10 ] || fail "3: the helper waited longer than VK_SIGNIN_WAIT"
nothing_stored 3
echo "ok 3 - a login answered with a redirect: exit 2, not followed; a board that fails the login until VK_SIGNIN_WAIT ends: exit 2; nothing stored"

# --- 4. settings that are wrong: exit 4, nothing sent, nothing stored ---
stub ok
for SETTING in "KANBAN_BOARD_URL=http://board.example.com:${PORT}" "KANBAN_BOARD_URL=" "KANBAN_BOARD_URL=file:///etc/passwd" \
	"VK_CREDENTIALS=${D}/data/vibe-kanban/config.json" "KANBAN_AUTH_FILE=${D}/no-such.env"; do
	RC=$(signin "${SETTING}")
	[ "${RC}" == "4" ] || fail "4: ${SETTING}: exit ${RC}, not 4: $(cat ${D}/out.txt)"
done
grep -q "^SELF_HOST_LOCAL_AUTH_EMAIL=" ${D}/kanban.env > ${D}/nopass.env
RC=$(signin KANBAN_AUTH_FILE=${D}/nopass.env)
[ "${RC}" == "4" ] || fail "4: a login file without a password: exit ${RC}, not 4: $(cat ${D}/out.txt)"
[ -s ${D}/requests.log ] && fail "4: a request went out with a wrong setting: $(cut -c1-40 ${D}/requests.log)"
nothing_stored 4
echo "ok 4 - a board URL that is not loopback or a single-label docker name (or none), a VK_CREDENTIALS that is not a credentials.json, a missing login file or one without a password: exit 4, nothing sent or stored"

# --- 5. a board that never answers: exit 2 within VK_SIGNIN_WAIT ---
kill "${STUB_PID}" 2> /dev/null; STUB_PID=""; sleep 0.3
T0=$(date +%s)
RC=$(signin VK_SIGNIN_WAIT=3)
[ "${RC}" == "2" ] || fail "5: no board: exit ${RC}, not 2: $(cat ${D}/out.txt)"
[ $(( $(date +%s) - T0 )) -le 10 ] || fail "5: the helper waited longer than VK_SIGNIN_WAIT"
grep -q "did not answer the login within 3s - the runner starts signed out" ${D}/out.txt || fail "5: the line does not say the board did not answer: $(cat ${D}/out.txt)"
nothing_stored 5
echo "ok 5 - a board that never answers: exit 2 within VK_SIGNIN_WAIT, nothing stored"

# --- 6. PLANTED CONTROL: a helper that prints the token fails check 1's scan ---
python3 - "${HELPER}" ${D}/leaky.py << 'PYEOF' || fail "6: PLANTED CONTROL BROKEN: the stored line is not in the helper as expected"
import sys
c = open(sys.argv[1]).read()
old = 'is stored in {CREDENTIALS} (it loads it when it starts)")'
assert c.count(old) == 1
open(sys.argv[2], "w").write(c.replace(old, 'is stored in {CREDENTIALS} (it loads it when it starts) {token}")'))
PYEOF
stub ok
env KANBAN_BOARD_URL="http://127.0.0.1:${PORT}" KANBAN_AUTH_FILE=${D}/kanban.env VK_CREDENTIALS=${CREDS} VK_SIGNIN_WAIT=10 \
	python3 -B ${D}/leaky.py > ${D}/out.txt 2>&1
grep -qF "${TOKEN}" ${D}/out.txt || fail "6: PLANTED CONTROL BROKEN: the leaking copy's output does not show the token, so check 1's scan proves nothing"
kill "${STUB_PID}" 2> /dev/null; STUB_PID=""
echo "ok 6 - PLANTED CONTROL: a copy that prints the token is caught by the same output scan"

echo "Test-vk-runner-signin succeeded"
