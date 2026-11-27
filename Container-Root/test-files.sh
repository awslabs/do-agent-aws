#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the Files tile (docs/manual/ui.md "Files": /agent/files-server.py and its page, the home proxy's files.localhost
# route, its dot probe and its tile, the ui-start.sh / ui-status.sh / ui-stop.sh wiring, and the note that tells the
# agent where the shared folder is). Fully OFFLINE: the server and nginx on test-local ports, a test-local shared folder
# and a planted folder OUTSIDE it under /tmp/files-smoke; nothing under /wd is touched.
#
# Properties proven (each check FAILS if the property is removed):
#   1. the scripts parse (bash -n, py_compile); the page's script has no HTML sink (no innerHTML, insertAdjacentHTML,
#      outerHTML or document.write - it renders with textContent), the page has no inline script or style of its own and
#      links the harness stylesheet; the page carries the Rename, Move to... and Delete controls, each behind a confirm
#   2. the round trip: a 3 MiB random upload through PUT lands with the same sha256 (201), is listed with its size,
#      downloads byte-identical as an attachment (Content-Disposition attachment with the name, nosniff, a plain type),
#      HEAD answers; a nested folder through mkdir, an upload with a UTF-8 name into it, listed under its path with its
#      parent; a second upload on the name is 409 and nothing changes, replace=1 replaces it; mkdir on a taken name 409;
#      the listing carries the live cap (max_upload_mb); the harness stylesheet's path answers an empty text/css fallback
#  2b. rename keeps size and sha256 and drops the old name; a file moved into a sub-folder and back is byte-identical and
#      its old place is empty; a folder renames; a folder is never replaced and never replaces one (409); a folder into
#      itself or under itself is 400 and nothing moves; a link moves as a link; a file deletes, an empty folder deletes, a
#      missing name is 404, a non-empty folder is 409 with its entry count and every entry is still on disk, and gone with
#      recursive=1 - a link inside it to the outside is unlinked while what it pointed at stays
#   3. confinement: ../, a percent-encoded traversal (two spellings), an absolute path, a NUL, a backslash traversal and a
#      symlink inside the folder pointing at a planted file outside are all refused with 400 or 404 and the planted
#      bytes appear in no response, no listing and no log line; a link out is listed as such; a link inside is served;
#      CONTROL: a server copy with the fence removed - the path check in resolve() AND the descriptor checks after the
#      open (opendir_inside, stream) - serves the planted file through the symlink and the same scan catches it; the two
#      layers are removed together because either one alone still refuses it
#  3b. the destination fence: to=../, to=%2e%2e, an absolute to, a link out of the folder as to are refused and the
#      planted outside folder is unchanged; a new name with a '/', '..', '.' or a NUL is refused;
#      CONTROL: a server copy without the destination fence (the path check and the descriptor check) moves the file
#      outside and the same check catches it
#   4. the cap: a Content-Length over FILES_MAX_UPLOAD_MB answers 413 and nothing is stored (with and without
#      Expect: 100-continue), no file and no temporary file remain; exactly the cap passes; a chunked body is 411;
#      CONTROL: a server copy without the cap accepts the over-cap upload
#   5. own-origin and the read-only surface: PUT and POST with a foreign Origin, an opaque null Origin, the own host on
#      another port or a cross-site fetch are 403 and nothing lands, the own origin, no Origin and same-origin pass, the
#      listing is guarded too while the page itself is a navigation from the home page (200); DELETE, PATCH, OPTIONS,
#      TRACE and an arbitrary method are 405 with Allow: GET, HEAD, PUT, POST as plain text; a foreign Host is 421 on
#      every path and method; a malformed request line is 400 as plain text, never the stdlib's HTML page; every
#      response says no-store, nosniff, no-referrer, closes its connection and carries the 'self'-only policy;
#      CONTROL: a server copy without the origin guard answers a foreign Origin 2xx
#  5b. a foreign Origin, a null Origin, a cross-site fetch and a foreign Host on /api/delete and /api/move are refused and
#      nothing changes; the DELETE method itself stays 405 and the file stays; CONTROL: the copy without the guard deletes
#   6. through the home proxy (home-render.sh with UI_FILES=true and test-local ports, nginx): files.localhost serves the
#      page with the home badge exactly once, returning to //localhost:<port>/; the badge's three inline parts are the
#      page's only inline parts, under a policy that is exactly the server's own plus their three hashes, and one
#      stylesheet link; an upload exactly at the cap passes the route (201) and the server, not nginx, refuses one byte
#      over the cap (413 naming FILES_MAX_UPLOAD_MB), while one byte over the route's own limit (the cap plus one MiB) is
#      nginx's 413; DELETE through the route is refused by the proxy (403); the dot probe /__probe/files is 204 while
#      the folder is there, 500 once it is gone (the server's 503), 500 with the server stopped (the route 502), 204 when
#      both are back; CONTROL: a home-render.sh copy without the route's badge include fails the badge check for that reason
#   7. the tile: UI_FILES=false greys it "off - set UI_FILES=true in .env" and renders neither the route nor the probe;
#      on, it is live with data-host=files and data-probe=/__probe/files, opens in a new tab (target _blank, rel opener,
#      as every live tile here), names the shared folder and the cap, and sits under "Run and review"
#   8. ui-start.sh (every other UI off) starts the server (pidfile, 127.0.0.1 only) and the shared folder exists after it, the
#      route answers through the home port, ui-status.sh reports it UP, ui-stop.sh stops it (pidfile gone, port closed);
#      with UI_FILES=false ui-start.sh starts nothing and ui-status.sh says DISABLED
#   9. the agent's note: claude-settings-sync.sh puts agent-rules/AGENT_FILES.md beside the agent's CLAUDE.md, refreshes
#      an outdated copy, references it from CLAUDE.md exactly once, and a second run changes nothing; with FILES_DIR set to
#      another folder the copy names that folder, not /wd/files; the note names the folder, both directions and that
#      nothing is run from there

D=/tmp/files-smoke
rm -rf "${D:?}"
mkdir -p "${D}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
RULES_DIR="${BASE_DIR%/}/agent-rules"
SITE=home/site   # where home-render.sh writes the page under a UI_DIR
PORT_FILES=18841
PORT_HOME=18842
PORT_FILES_MUTANT=18843
PORT_HOME_MUTANT=18844
PORT_FILES_UI=18845
PORT_HOME_UI=18846
PORT_KNOWLEDGE_UI=18847
MB=4                       # the test-local cap: FILES_MAX_UPLOAD_MB
CAP=$((MB * 1024 * 1024))
F=${D}/files               # the shared folder under test
OUTSIDE=${D}/outside       # the planted folder the fence must never reach
PIDS=()
B=http://127.0.0.1:${PORT_FILES}
FH="Host: files.localhost:${PORT_FILES}"
O="Origin: http://files.localhost:${PORT_FILES}"

cleanup()
{
	for P in "${PIDS[@]}"; do kill "${P}" 2>/dev/null; done
	[ -f "${D}/ui/home/nginx.pid" ] && kill "$(cat "${D}/ui/home/nginx.pid")" 2>/dev/null
	[ -f "${D}/mutant-ui/home/nginx.pid" ] && kill "$(cat "${D}/mutant-ui/home/nginx.pid")" 2>/dev/null
	UI_DIR=${D}/ui2 "${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
}
trap cleanup EXIT

fail()
{
	echo "Test-files FAILED: $1"
	exit 1
}

code()
{
	# code [curl options] <url> - the status code, 000 when nothing answers
	curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null || echo 000
}

upto()
{
	# upto <code> [curl options] <url> - true once the url answers that code, within UPTO_TRIES quarter-seconds (default 80)
	WANT=$1; shift
	for _ in $(seq 1 "${UPTO_TRIES:-80}"); do [ "$(code "$@")" == "${WANT}" ] && return 0; sleep 0.25; done
	return 1
}

sha()
{
	sha256sum "$1" | cut -d' ' -f1
}

# --- 1. syntax, and the page's rendering discipline ---
for S in home-render.sh ui-start.sh ui-status.sh ui-stop.sh claude-settings-sync.sh; do bash -n "${AGENT_DIR}/${S}" || fail "bash -n ${S}"; done
bash -n "$0" || fail "bash -n $0"
# the bytecode goes under ${D}: py_compile writes a __pycache__ next to the source, and /agent is the image's, read-only to the agent
PYTHONPYCACHEPREFIX="${D}/pycache" python3 -m py_compile "${AGENT_DIR}/files-server.py" || fail "files-server.py does not compile"
for P in index.html files.js files.css; do [ -s "${AGENT_DIR}/files-ui/${P}" ] || fail "the page file files-ui/${P} is missing"; done
grep -nE 'innerHTML|insertAdjacentHTML|outerHTML|document\.write' "${AGENT_DIR}/files-ui/files.js" && fail "files.js has an HTML sink (the page must render with textContent)"
grep -q 'textContent' "${AGENT_DIR}/files-ui/files.js" || fail "files.js does not render with textContent"
grep -qE '<script[^>]*>[^<]' "${AGENT_DIR}/files-ui/index.html" && fail "index.html carries an inline script (the policy is 'self' alone)"
grep -qE ' style="' "${AGENT_DIR}/files-ui/index.html" && fail "index.html carries an inline style attribute"
grep -qE '<style' "${AGENT_DIR}/files-ui/index.html" && fail "index.html carries an inline style element"
grep -q 'href="/__harness/harness.css"' "${AGENT_DIR}/files-ui/index.html" || fail "the page does not link the shared harness stylesheet"
# the controls Alex asked for, each behind a confirm (the page never deletes or replaces without asking)
for C in "'Rename'" "'Move to...'" "'Delete'"; do
	grep -qF "button(${C}" "${AGENT_DIR}/files-ui/files.js" || fail "files.js has no ${C} control per row"
done
grep -qF "window.confirm('Delete ' + what + '?')" "${AGENT_DIR}/files-ui/files.js" || fail "files.js deletes without its confirm"
grep -qF "Delete the folder and everything in it?" "${AGENT_DIR}/files-ui/files.js" || fail "files.js removes a non-empty folder without the second, count-bearing confirm"
[ "$(grep -c "Replace it?" "${AGENT_DIR}/files-ui/files.js")" == "2" ] || fail "files.js does not ask before it replaces (an upload onto a taken name, a move onto one)"
grep -q "replace=1/.test" "${AGENT_DIR}/files-ui/files.js" || fail "files.js offers a replace without reading whether the 409 allows one"
grep -q "window.addEventListener('drop'" "${AGENT_DIR}/files-ui/files.js" || fail "files.js lets a file dropped outside the zone navigate the browser away"
grep -q "recursive: '1'" "${AGENT_DIR}/files-ui/files.js" || fail "files.js never sends recursive=1 (the second, count-bearing confirm)"
grep -q 'upload\.onprogress' "${AGENT_DIR}/files-ui/files.js" || fail "files.js shows no per-file upload progress"
for I in refresh newfolder pick picker mover mover-go cap queue crumbs; do
	grep -q "id=\"${I}\"" "${AGENT_DIR}/files-ui/index.html" || fail "index.html has no element id=${I}"
done
echo "ok 1 - syntax; the page renders with textContent, carries no inline script or style, links the harness stylesheet, has Rename / Move to... / Delete behind confirms, upload progress and recursive=1 after the count-bearing confirm"

# --- the server under test ---
mkdir -p "${F}" "${OUTSIDE}"
# planted before the server starts: an in-flight upload file a dead process left two hours ago, and one from a minute ago
touch -d '2 hours ago' "${F}/.files-uploading-abandoned" && touch "${F}/.files-uploading-fresh" || fail "could not plant the temp files"
serve()
{
	# serve <port> <log> <folder> [<server file>] [<cap MiB>] - starts a files server, prints its pid
	env UI_PORT_FILES="$1" UI_BACKEND_LISTEN_HOST=127.0.0.1 FILES_DIR="$3" FILES_MAX_UPLOAD_MB="${5:-${MB}}" \
		FILES_UI_DIR="${AGENT_DIR}/files-ui" python3 "${4:-${AGENT_DIR}/files-server.py}" > "$2" 2>&1 &
	echo $!
}
SRV=$(serve "${PORT_FILES}" "${D}/files.log" "${F}")
PIDS+=("${SRV}")
upto 200 -H "${FH}" "${B}/healthz" || { cat "${D}/files.log"; fail "the files server did not answer /healthz within 20 s"; }
[ ! -e "${F}/.files-uploading-abandoned" ] || fail "the server did not sweep an abandoned in-flight upload file at start"
[ -e "${F}/.files-uploading-fresh" ] || fail "the server swept an in-flight upload file a minute old"
grep -q '1 abandoned upload file(s) removed' "${D}/files.log" || fail "the sweep is not logged: $(head -3 "${D}/files.log")"
rm -f "${F:?}/.files-uploading-fresh"

# --- 2. the round trip: upload, list, download; a nested folder; 409 then replace=1; the cap in the listing ---
head -c 3145728 /dev/urandom > "${D}/big.bin"
SHA_BIG=$(sha "${D}/big.bin")
curl -s -D "${D}/up.h" -o "${D}/up.b" --max-time 30 -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/big.bin" "${B}/api/upload?path=&name=big.bin" || fail "PUT /api/upload"
grep -q '^HTTP/1.[01] 201' "${D}/up.h" || fail "the upload is not 201: $(head -1 "${D}/up.h") $(cat "${D}/up.b")"
[ "$(sha "${F}/big.bin")" == "${SHA_BIG}" ] || fail "the stored file differs from what was uploaded"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d == {"name": "big.bin", "path": "big.bin", "size": 3145728, "replaced": False}, d' "${D}/up.b" \
	|| fail "the upload's answer is not the file's name, path and size: $(cat "${D}/up.b")"
curl -s -D "${D}/list.h" -o "${D}/list.json" --max-time 5 -H "${FH}" "${B}/api/list?path=" || fail "GET /api/list"
python3 - "${D}/list.json" "${MB}" << 'PY' || fail "the listing is not the one file with its size and the cap (see above)"
import json, sys
d = json.load(open(sys.argv[1]))
e = d["entries"]
assert d["schema"] == "do-agent-aws-files/v1" and d["path"] == "" and d["parent"] is None, d
assert len(e) == 1 and e[0]["name"] == "big.bin" and e[0]["type"] == "file" and e[0]["size"] == 3145728 and e[0]["link"] is False, e
assert d["max_upload_mb"] == int(sys.argv[2]) and d["max_upload_bytes"] == int(sys.argv[2]) * 1048576, (d["max_upload_mb"], d["max_upload_bytes"])
assert e[0]["mtime"].endswith("Z"), e[0]
print("one file, %d bytes, cap %d MiB" % (e[0]["size"], d["max_upload_mb"]))
PY
grep -qi '^Content-Type: application/json' "${D}/list.h" || fail "the listing is not JSON"
curl -s -D "${D}/dl.h" -o "${D}/dl.bin" --max-time 30 -H "${FH}" "${B}/api/download?path=big.bin" || fail "GET /api/download"
[ "$(sha "${D}/dl.bin")" == "${SHA_BIG}" ] || fail "the download differs from the upload"
grep -qi "^Content-Disposition: attachment; filename=\"big.bin\"; filename\*=UTF-8''big.bin" "${D}/dl.h" || fail "the download is not an attachment named big.bin: $(grep -i '^Content-Disposition' "${D}/dl.h")"
grep -qi '^Content-Type: application/octet-stream' "${D}/dl.h" || fail "the download's type is not application/octet-stream: $(grep -i '^Content-Type' "${D}/dl.h")"
grep -qi '^X-Content-Type-Options: nosniff' "${D}/dl.h" || fail "the download lacks nosniff"
grep -qi '^Content-Length: 3145728' "${D}/dl.h" || fail "the download does not announce its size"
[ "$(code -I -H "${FH}" "${B}/api/download?path=big.bin")" == "200" ] || fail "HEAD /api/download is not answered"
[ "$(code -H "${FH}" "${B}/api/download?path=")" == "400" ] || fail "a folder as a download is not refused with 400"
[ "$(code -H "${FH}" "${B}/api/download?path=nope.bin")" == "404" ] || fail "a missing file is not 404"
# 409 on the taken name, nothing changed; replace=1 replaces
head -c 1000 /dev/urandom > "${D}/small.bin"
[ "$(code -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/small.bin" "${B}/api/upload?path=&name=big.bin")" == "409" ] || fail "an upload on a taken name is not 409"
[ "$(sha "${F}/big.bin")" == "${SHA_BIG}" ] || fail "the refused upload changed the file"
curl -s -o "${D}/rep.b" --max-time 5 -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/small.bin" "${B}/api/upload?path=&name=big.bin&replace=1" || fail "PUT replace=1"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["replaced"] is True and d["size"] == 1000, d' "${D}/rep.b" || fail "replace=1 did not answer replaced:true with the new size: $(cat "${D}/rep.b")"
[ "$(sha "${F}/big.bin")" == "$(sha "${D}/small.bin")" ] || fail "replace=1 did not replace the file"
# a nested folder, an upload with a UTF-8 name into it, listed under its path
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/mkdir?path=&name=reports")" == "201" ] || fail "mkdir reports"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/mkdir?path=reports&name=2026-10")" == "201" ] || fail "mkdir reports/2026-10"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/mkdir?path=&name=reports")" == "409" ] || fail "mkdir on a taken name is not 409"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/mkdir?path=nowhere&name=x")" == "404" ] || fail "mkdir in a missing folder is not 404"
[ "$(code -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/small.bin" "${B}/api/upload?path=reports/2026-10&name=r%C3%A9sum%C3%A9%20v1.txt")" == "201" ] || fail "the upload into the nested folder"
[ -f "${F}/reports/2026-10/résumé v1.txt" ] || fail "the nested upload is not at reports/2026-10/résumé v1.txt"
curl -s -D "${D}/dl2.h" -o /dev/null --max-time 5 -H "${FH}" "${B}/api/download?path=reports/2026-10/r%C3%A9sum%C3%A9%20v1.txt" || fail "GET the nested file"
grep -qi "filename\*=UTF-8''r%C3%A9sum%C3%A9%20v1.txt" "${D}/dl2.h" || fail "the UTF-8 name is not in the disposition: $(grep -i '^Content-Disposition' "${D}/dl2.h")"
grep -qi '^Content-Type: text/plain' "${D}/dl2.h" || fail "a .txt download is not text/plain: $(grep -i '^Content-Type' "${D}/dl2.h")"
curl -s --max-time 5 -H "${FH}" "${B}/api/list?path=reports/2026-10" > "${D}/list2.json"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["path"] == "reports/2026-10" and d["parent"] == "reports" and [e["name"] for e in d["entries"]] == ["résumé v1.txt"], d' "${D}/list2.json" \
	|| fail "the nested listing is not the folder, its parent and its one file: $(cat "${D}/list2.json")"
curl -s --max-time 5 -H "${FH}" "${B}/api/list?path=" | python3 -c 'import json, sys; e = json.load(sys.stdin)["entries"]; assert [x["name"] for x in e] == ["reports", "big.bin"] and e[0]["type"] == "dir", e' \
	|| fail "the root listing does not put the folder first"
# an uploaded page never becomes a page here: a .html downloads as an attachment of type application/octet-stream
printf '<html><script>alert(1)</script></html>' > "${D}/page.html"
[ "$(code -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/page.html" "${B}/api/upload?path=&name=page.html")" == "201" ] || fail "the upload of page.html"
curl -s -D "${D}/dlh.h" -o "${D}/dlh.b" --max-time 5 -H "${FH}" "${B}/api/download?path=page.html" || fail "GET page.html"
grep -qi '^Content-Type: application/octet-stream' "${D}/dlh.h" && grep -qi '^Content-Disposition: attachment' "${D}/dlh.h" && grep -qi '^X-Content-Type-Options: nosniff' "${D}/dlh.h" \
	|| fail "an uploaded .html is not downloaded as an octet-stream attachment: $(grep -iE '^Content-(Type|Disposition)' "${D}/dlh.h" | tr '\n' ' ')"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/delete?path=&name=page.html")" == "200" ] || fail "the delete of page.html"
# the stylesheet link never fails: an empty text/css fallback on the harness path
curl -s -D "${D}/css.h" -o "${D}/css.b" --max-time 5 -H "${FH}" "${B}/__harness/harness.css" || fail "GET /__harness/harness.css"
grep -q '^HTTP/1.[01] 200' "${D}/css.h" && grep -qi '^Content-Type: text/css' "${D}/css.h" && grep -q 'harness stylesheet' "${D}/css.b" || fail "/__harness/harness.css is not an empty text/css fallback: $(head -1 "${D}/css.h")"
for P in / /files.js /files.css; do [ "$(code -H "${FH}" "${B}${P}")" == "200" ] || fail "GET ${P} is not 200"; done
curl -s --max-time 5 -H "${FH}" "${B}/" | grep -q '<title>Files - do-agent-aws harness</title>' || fail "the page is not the Files page"
echo "ok 2 - a 3 MiB upload lands byte-identical, is listed with its size and the ${MB} MiB cap, downloads byte-identical as an attachment (nosniff, octet-stream); 409 on the taken name then replace=1; a nested folder with a UTF-8 name listed under its path; the stylesheet fallback"

# --- 2b. rename, move, delete ---
head -c 2048 /dev/urandom > "${D}/a.bin"
SHA_A=$(sha "${D}/a.bin")
[ "$(code -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/a.bin" "${B}/api/upload?path=&name=a.bin")" == "201" ] || fail "2b: the upload of a.bin"
curl -s -D "${D}/mv.h" -o "${D}/mv.b" --max-time 5 -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=a.bin&newname=b.bin" || fail "POST /api/move"
grep -q '^HTTP/1.[01] 200' "${D}/mv.h" || fail "the rename is not 200: $(head -1 "${D}/mv.h") $(cat "${D}/mv.b")"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d == {"from": "a.bin", "to": "b.bin", "type": "file", "replaced": False}, d' "${D}/mv.b" || fail "the rename's answer: $(cat "${D}/mv.b")"
[ ! -e "${F}/a.bin" ] && [ "$(sha "${F}/b.bin")" == "${SHA_A}" ] || fail "the rename did not keep the bytes under the new name alone"
curl -s --max-time 5 -H "${FH}" "${B}/api/list?path=" | python3 -c 'import json, sys; n = [e["name"] for e in json.load(sys.stdin)["entries"]]; assert "b.bin" in n and "a.bin" not in n, n' || fail "the listing after the rename"
curl -s -o "${D}/b.dl" --max-time 5 -H "${FH}" "${B}/api/download?path=b.bin"; [ "$(sha "${D}/b.dl")" == "${SHA_A}" ] || fail "the renamed file downloads differently"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=b.bin&to=reports")" == "200" ] || fail "the move into reports"
[ ! -e "${F}/b.bin" ] && [ "$(sha "${F}/reports/b.bin")" == "${SHA_A}" ] || fail "the move into reports did not land byte-identical"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=reports&name=b.bin&to=&newname=c.bin")" == "200" ] || fail "the move back with a new name"
[ ! -e "${F}/reports/b.bin" ] && [ "$(sha "${F}/c.bin")" == "${SHA_A}" ] || fail "the move back did not land byte-identical"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=c.bin&to=")" == "400" ] || fail "a move onto its own place is not 400"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=c.bin")" == "400" ] || fail "a move with neither to nor newname is not 400"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=nope&newname=x")" == "404" ] || fail "a move of a missing name is not 404"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=c.bin&newname=big.bin")" == "409" ] || fail "a rename onto a taken name is not 409"
[ -f "${F}/c.bin" ] && [ "$(sha "${F}/big.bin")" == "$(sha "${D}/small.bin")" ] || fail "the refused rename changed something"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=c.bin&newname=big.bin&replace=1")" == "200" ] || fail "a rename over a file with replace=1"
[ ! -e "${F}/c.bin" ] && [ "$(sha "${F}/big.bin")" == "${SHA_A}" ] || fail "replace=1 did not move the file over the other"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/mkdir?path=&name=old")" == "201" ] || fail "mkdir old"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=old&newname=new")" == "200" ] && [ -d "${F}/new" ] && [ ! -e "${F}/old" ] || fail "a folder does not rename"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=new&newname=reports&replace=1")" == "409" ] && [ -d "${F}/new" ] && [ -d "${F}/reports/2026-10" ] || fail "a folder replaced a folder"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=big.bin&newname=new&replace=1")" == "409" ] && [ -f "${F}/big.bin" ] && [ -d "${F}/new" ] || fail "a file replaced a folder"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=reports&to=reports")" == "400" ] || fail "a folder into itself is not 400"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=reports&to=reports/2026-10")" == "400" ] || fail "a folder into its own descendant is not 400"
[ -d "${F}/reports/2026-10" ] && [ ! -e "${F}/reports/2026-10/reports" ] || fail "the refused folder move changed something"
echo "PLANTED-OUTSIDE-BYTES-7731" > "${OUTSIDE}/secret.txt"
ln -s "${OUTSIDE}/secret.txt" "${F}/new/lnk"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=new&name=lnk&to=")" == "200" ] && [ -L "${F}/lnk" ] && [ -f "${OUTSIDE}/secret.txt" ] || fail "a link does not move as a link"
# delete: the link as a link, a file, an empty folder, a missing name, a non-empty folder without and with recursive=1
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/delete?path=&name=lnk")" == "200" ] && [ ! -L "${F}/lnk" ] && [ -f "${OUTSIDE}/secret.txt" ] || fail "a link is not unlinked as a link (what it points at must stay)"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/delete?path=&name=big.bin")" == "200" ] && [ ! -e "${F}/big.bin" ] || fail "a file does not delete"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/delete?path=&name=new")" == "200" ] && [ ! -e "${F}/new" ] || fail "an empty folder does not delete"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/delete?path=&name=nope")" == "404" ] || fail "a missing name is not 404"
curl -s -D "${D}/del.h" -o "${D}/del.b" --max-time 5 -H "${FH}" -H "${O}" -X POST "${B}/api/delete?path=&name=reports" || fail "POST /api/delete reports"
grep -q '^HTTP/1.[01] 409' "${D}/del.h" || fail "a non-empty folder without recursive=1 is not 409: $(head -1 "${D}/del.h")"
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["entries"] == 2 and d["type"] == "dir" and "2 entries" in d["error"], d' "${D}/del.b" || fail "the 409 does not carry the entry count: $(cat "${D}/del.b")"
[ -f "${F}/reports/2026-10/résumé v1.txt" ] || fail "the 409 removed something"
mkdir -p "${F}/reports/withlink" && ln -s "${OUTSIDE}" "${F}/reports/withlink/out"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/delete?path=&name=reports&recursive=1")" == "200" ] && [ ! -e "${F}/reports" ] || fail "recursive=1 did not remove the folder"
[ -f "${OUTSIDE}/secret.txt" ] || fail "the recursive delete followed a link out of the folder"
echo "ok 2b - rename keeps the bytes and drops the old name; a file moves into a folder and back byte-identical; a folder renames, never replaces or is replaced, never moves into itself; a link moves and deletes as a link; a file and an empty folder delete; a non-empty folder is 409 with its count and intact, gone with recursive=1, the outside untouched"

# --- 3. confinement: nothing outside the folder is told, listed or served ---
PLANTED=PLANTED-OUTSIDE-BYTES-7731
echo "${PLANTED}" > "${OUTSIDE}/secret.txt"
ln -s "${OUTSIDE}/secret.txt" "${F}/leak"
ln -s "${OUTSIDE}" "${F}/leakdir"
mkdir -p "${F}/inner" && echo inner-file > "${F}/inner/i.txt" && ln -s "${F}/inner" "${F}/inner-link"
: > "${D}/scan.txt"
traversal_scan()
{
	# traversal_scan <base url> <host header> <log> - every traversal form is 400 or 404 and the planted bytes are in no
	# response, no listing and no log line; prints the forms tried; fails on the first leak
	for P in "../outside/secret.txt" "%2e%2e/outside/secret.txt" "%2e%2e%2foutside%2fsecret.txt" "${OUTSIDE}/secret.txt" \
		"leak" "leakdir/secret.txt" "a%00b" "..%5coutside%5csecret.txt" "inner/../../outside/secret.txt"; do
		curl -s -D "${D}/t.h" -o "${D}/t.b" --max-time 5 -H "$2" "$1/api/download?path=${P}"
		grep -q "${PLANTED}" "${D}/t.b" && { echo "the planted bytes were served for '${P}'"; return 1; }
		C=$(head -1 "${D}/t.h" | awk '{print $2}')
		case "${C}" in 400|404) ;; *) echo "the download of '${P}' answered ${C:-nothing}: $(head -c 200 "${D}/t.b")"; return 1 ;; esac
		curl -s -o "${D}/tl.b" --max-time 5 -H "$2" "$1/api/list?path=${P}"
		grep -q "${PLANTED}\|secret.txt" "${D}/tl.b" && { echo "the listing of '${P}' names the outside"; return 1; }
		echo "${P}" >> "${D}/scan.txt"
	done
	grep -q "${PLANTED}" "$3" && { echo "the log carries the planted bytes"; return 1; }
	return 0
}
TS=$(traversal_scan "${B}" "${FH}" "${D}/files.log") || fail "confinement: ${TS}"
NF=$(wc -l < "${D}/scan.txt")
curl -s --max-time 5 -H "${FH}" "${B}/api/list?path=" > "${D}/list3.json"
python3 -c 'import json, sys; e = {x["name"]: x for x in json.load(open(sys.argv[1]))["entries"]}; assert e["leak"]["type"] == "outside" and e["leak"]["link"] and e["leak"]["size"] is None and e["leakdir"]["type"] == "outside", e; assert e["inner-link"]["type"] == "dir" and e["inner-link"]["link"], e' "${D}/list3.json" \
	|| fail "the links out are not listed as 'outside' (and the link inside as a folder): $(cat "${D}/list3.json")"
grep -q "${PLANTED}" "${D}/list3.json" && fail "the root listing carries the planted bytes"
printf 'tabbed' > "${F}/a	b.txt"
curl -s --max-time 5 -H "${FH}" "${B}/api/list?path=" | python3 -c 'import json, sys; e = {x["name"]: x for x in json.load(sys.stdin)["entries"]}; t = [x for n, x in e.items() if "\t" in n]; assert len(t) == 1 and t[0]["served"] is False and t[0]["type"] == "file", t; assert all(x["served"] is True for n, x in e.items() if "\t" not in n and x["type"] != "outside"), e' \
	|| fail "a name with a tab is not listed as served:false (and the others as served:true)"
[ "$(code -H "${FH}" "${B}/api/download?path=a%09b.txt")" == "400" ] || fail "a name with a tab is served"
rm -f "${F:?}/a	b.txt"
curl -s --max-time 5 -H "${FH}" "${B}/api/list?path=inner-link" | python3 -c 'import json, sys; d = json.load(sys.stdin); assert [x["name"] for x in d["entries"]] == ["i.txt"], d' || fail "a link inside the folder is not served"
curl -s --max-time 5 -H "${FH}" "${B}/api/download?path=inner-link/i.txt" | grep -q '^inner-file$' || fail "a file through a link inside the folder does not download"
grep -q 'secret\|big.bin\|r.sum' "${D}/files.log" && fail "the server's log carries a file name: $(grep -m1 'secret\|big.bin\|r.sum' "${D}/files.log")"
# CONTROL: a server copy with the fence removed follows the symlink out and serves the planted file. The fence has two
# layers - resolve() checks the path, then the open descriptor is checked (opendir_inside for a folder, stream for a file);
# either alone refuses the link out, so the control removes both
mkdir -p "${D}/mutant"
FD_CHECK='    if not inside(root, os.path.realpath(f"/proc/self/fd/{fd}")):\n        os.close(fd)\n        raise Refused(404,'
python3 - "${AGENT_DIR}/files-server.py" "${D}/mutant/files-server-nofence.py" "${FD_CHECK}" << 'PY' || fail "CONTROL: the no-fence copy could not be planted"
import sys
s = open(sys.argv[1]).read()
fd_check = sys.argv[3].encode().decode("unicode_escape")
a1 = "    if real != root and not real.startswith(root + os.sep):\n        raise Refused(404,"
a2 = '            if not stat.S_ISREG(st.st_mode) or not inside(root, os.path.realpath(f"/proc/self/fd/{f.fileno()}")):'
assert s.count(a1) == 1 and s.count(a2) == 1 and s.count(fd_check) == 1, "the fence is not where the control expects it"
s = s.replace(a1, "    if False:\n        raise Refused(404,").replace(a2, "            if not stat.S_ISREG(st.st_mode):").replace(fd_check, "    if False:\n        os.close(fd)\n        raise Refused(404,")
open(sys.argv[2], "w").write(s)
PY
MUT=$(serve "${PORT_FILES_MUTANT}" "${D}/mutant-nofence.log" "${F}" "${D}/mutant/files-server-nofence.py")
PIDS+=("${MUT}")
MH="Host: files.localhost:${PORT_FILES_MUTANT}"
upto 200 -H "${MH}" "http://127.0.0.1:${PORT_FILES_MUTANT}/healthz" || fail "the no-fence control server did not come up"
MS=$(traversal_scan "http://127.0.0.1:${PORT_FILES_MUTANT}" "${MH}" "${D}/mutant-nofence.log") && fail "CONTROL: the copy without the fence passed the confinement scan - the check above proves nothing"
case "${MS}" in *"planted bytes were served for 'leak'"*) ;; *) fail "CONTROL: the no-fence copy failed for another reason: ${MS}" ;; esac
kill "${MUT}" 2>/dev/null
echo "ok 3 - ${NF} traversal forms (dotted, percent-encoded, absolute, NUL, backslash, a link out, through a link) 400/404; the planted bytes in no response, listing or log line; links out listed as such; a link inside served; a tab-named file listed as served:false and not served; control: with both layers of the fence removed the link out serves the planted file"

# --- 3b. the destination fence of a move ---
head -c 512 /dev/urandom > "${D}/m.bin"
[ "$(code -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/m.bin" "${B}/api/upload?path=&name=m.bin")" == "201" ] || fail "3b: the upload of m.bin"
BEFORE=$(ls -A "${OUTSIDE}" | sort | tr '\n' ' ')
dest_fence()
{
	# dest_fence <base url> <host header> - every fenced destination is refused and the planted folder is unchanged
	for T in "../outside" "%2e%2e/outside" "%2e%2e%2foutside" "${OUTSIDE}" "leakdir" "../" "%2e%2e%2f"; do
		C=$(code -H "$2" -H "Origin: http://${2#Host: }" -X POST "$1/api/move?path=&name=m.bin&to=${T}")
		case "${C}" in 400|404) ;; *) echo "the destination '${T}' answered ${C}"; return 1 ;; esac
	done
	[ "$(ls -A "${OUTSIDE}" | sort | tr '\n' ' ')" == "${BEFORE}" ] || { echo "the planted folder changed: $(ls -A "${OUTSIDE}" | tr '\n' ' ')"; return 1; }
	[ -f "${F}/m.bin" ] || { echo "the file left the shared folder"; return 1; }
	return 0
}
DF=$(dest_fence "${B}" "${FH}") || fail "the destination fence: ${DF}"
LONG=$(printf 'a%.0s' $(seq 1 256))
for N in "a%2Fb" ".." "." "x%00y" "%2e%2e%2fz" "a%5Cb" "invoice%E2%80%AEtxt.exe" "${LONG}" ".files-uploading-x" "a%C2%85b"; do
	[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/move?path=&name=m.bin&newname=${N}")" == "400" ] || fail "the new name '${N}' is not refused"
done
[ -f "${F}/m.bin" ] || fail "a refused new name moved the file"
# CONTROL: a server copy whose destination skips the fence (the path check and the descriptor check) moves the file into
# the planted folder
python3 - "${AGENT_DIR}/files-server.py" "${D}/mutant/files-server-nodest.py" "${FD_CHECK}" << 'PY' || fail "CONTROL: the no-destination-fence copy could not be planted"
import sys
s = open(sys.argv[1]).read()
fd_check = sys.argv[3].encode().decode("unicode_escape")
anchor = '            _, dest, drel = resolve(q.get("to", q.get("path", "")))\n'
assert s.count(anchor) == 1 and s.count(fd_check) == 1, "the destination's resolve is not where the control expects it"
s = s.replace(anchor, '            dest = os.path.realpath(os.path.join(root_dir(), q.get("to", q.get("path", "")))); drel = q.get("to", "")\n')
s = s.replace(fd_check, "    if False:\n        os.close(fd)\n        raise Refused(404,")
open(sys.argv[2], "w").write(s)
PY
MUT=$(serve "${PORT_FILES_MUTANT}" "${D}/mutant-nodest.log" "${F}" "${D}/mutant/files-server-nodest.py")
PIDS+=("${MUT}")
upto 200 -H "${MH}" "http://127.0.0.1:${PORT_FILES_MUTANT}/healthz" || fail "the no-destination-fence control server did not come up"
MD=$(dest_fence "http://127.0.0.1:${PORT_FILES_MUTANT}" "${MH}") && fail "CONTROL: the copy without the destination fence passed the fence check - the check above proves nothing"
case "${MD}" in *"the destination '../outside' answered 200"*|*"planted folder changed"*|*"left the shared folder"*) ;; *) fail "CONTROL: the no-destination-fence copy failed for another reason: ${MD}" ;; esac
kill "${MUT}" 2>/dev/null
rm -f "${OUTSIDE:?}/m.bin"
[ -f "${F}/m.bin" ] || head -c 512 /dev/urandom > "${F}/m.bin"
echo "ok 3b - 7 fenced destinations (dotted, percent-encoded, absolute, a link out) refused with the planted folder unchanged; 10 bad new names refused (separators, dots, NUL, a bidi control, 256 bytes, a temp-shaped name, a C1 control); control: without the destination fence the file lands outside (${MD%%:*})"

# --- 4. the cap ---
head -c $((CAP + 1)) /dev/urandom > "${D}/over.bin"
curl -s -D "${D}/over.h" -o "${D}/over.b" --max-time 30 -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/over.bin" "${B}/api/upload?path=&name=over.bin"
grep -q '^HTTP/1.[01] 413' "${D}/over.h" || fail "one byte over the cap is not 413 (with Expect: 100-continue): $(head -1 "${D}/over.h")"
grep -q 'FILES_MAX_UPLOAD_MB' "${D}/over.b" || fail "the 413 does not name the knob: $(cat "${D}/over.b")"
curl -s -D "${D}/over2.h" -o /dev/null --max-time 30 -H "${FH}" -H 'Expect:' -H "${O}" -X PUT --data-binary "@${D}/over.bin" "${B}/api/upload?path=&name=over.bin"
grep -q '^HTTP/1.[01] 413' "${D}/over2.h" || fail "one byte over the cap is not 413 (body sent at once): $(head -1 "${D}/over2.h")"
[ -e "${F}/over.bin" ] && fail "the over-cap upload landed"
ls -A "${F}" | grep -q '^\.files-uploading-' && fail "a temporary file remains after the refused upload"
head -c "${CAP}" /dev/urandom > "${D}/atcap.bin"
[ "$(code --max-time 60 -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/atcap.bin" "${B}/api/upload?path=&name=atcap.bin")" == "201" ] || fail "an upload exactly at the cap is refused"
[ "$(sha "${F}/atcap.bin")" == "$(sha "${D}/atcap.bin")" ] || fail "the at-cap upload differs"
[ "$(code -H "${FH}" -H "${O}" -H 'Transfer-Encoding: chunked' -X PUT --data-binary "@${D}/small.bin" "${B}/api/upload?path=&name=chunked.bin")" == "411" ] || fail "a chunked body (no Content-Length) is not 411"
[ -e "${F}/chunked.bin" ] && fail "the chunked upload landed"
# CONTROL: a server copy without the cap accepts the over-cap upload
python3 - "${AGENT_DIR}/files-server.py" "${D}/mutant/files-server-nocap.py" << 'PY' || fail "CONTROL: the no-cap copy could not be planted"
import sys
s = open(sys.argv[1]).read()
anchor = "            if int(length) > MAX_BYTES:\n"
assert s.count(anchor) == 1, "the cap is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, "            if False:\n"))
PY
mkdir -p "${D}/files-nocap"
MUT=$(serve "${PORT_FILES_MUTANT}" "${D}/mutant-nocap.log" "${D}/files-nocap" "${D}/mutant/files-server-nocap.py")
PIDS+=("${MUT}")
upto 200 -H "${MH}" "http://127.0.0.1:${PORT_FILES_MUTANT}/healthz" || fail "the no-cap control server did not come up"
[ "$(code --max-time 60 -H "${MH}" -H "Origin: http://files.localhost:${PORT_FILES_MUTANT}" -X PUT --data-binary "@${D}/over.bin" "http://127.0.0.1:${PORT_FILES_MUTANT}/api/upload?path=&name=over.bin")" == "201" ] \
	|| fail "CONTROL: the copy without the cap refused the over-cap upload - the 413 above proves nothing"
kill "${MUT}" 2>/dev/null
rm -f "${D:?}/over.bin" "${D:?}/atcap.bin"
echo "ok 4 - one byte over ${MB} MiB is 413 naming FILES_MAX_UPLOAD_MB, with and without Expect, nothing lands and no temporary file remains; exactly the cap passes byte-identical; a chunked body is 411; control: a copy without the cap accepts"

# --- 5. own-origin, and the read-only surface ---
headers_ok()
{
	# headers_ok <header file> - every response: no-store, nosniff, no-referrer, the connection closed, the 'self'-only policy
	grep -qi '^Cache-Control: no-store' "$1" && grep -qi '^X-Content-Type-Options: nosniff' "$1" && grep -qi '^Referrer-Policy: no-referrer' "$1" \
		&& grep -qi '^Connection: close' "$1" && grep -qi '^X-Frame-Options: DENY' "$1" && grep -qi '^Cross-Origin-Resource-Policy: same-origin' "$1" \
		&& grep -qi "^Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" "$1"
}
for P in / /files.js /files.css "/api/list?path=" /healthz "/api/download?path=m.bin" /nope "/api/download?path=../x" /__harness/harness.css; do
	curl -s -D "${D}/h.txt" -o /dev/null --max-time 5 -H "${FH}" "${B}${P}" || fail "GET ${P}"
	headers_ok "${D}/h.txt" || fail "${P}: a response lacks no-store, nosniff, no-referrer, X-Frame-Options DENY, Connection close or the 'self'-only policy: $(grep -iE '^(Cache-Control|X-Content|Referrer|Connection|X-Frame|Content-Security)' "${D}/h.txt" | tr '\n' ' ')"
done
grep -qi '^Content-Type: text/html' "${D}/h.txt" && fail "/__harness/harness.css is html"
for W in "PUT ${B}/api/upload?path=&name=w.bin" "POST ${B}/api/mkdir?path=&name=w" "POST ${B}/api/delete?path=&name=m.bin" "POST ${B}/api/move?path=&name=m.bin&newname=w.bin"; do
	M=${W%% *}; U=${W#* }
	[ "$(code -H "${FH}" -H "Origin: https://example.com" -X "${M}" --data-binary "@${D}/small.bin" "${U}")" == "403" ] || fail "${M} ${U#*${B}} with a foreign Origin is not 403"
	[ "$(code -H "${FH}" -H "Origin: null" -X "${M}" --data-binary "@${D}/small.bin" "${U}")" == "403" ] || fail "${M} with an opaque null Origin is not 403"
	[ "$(code -H "${FH}" -H "Origin: http://files.localhost:1" -X "${M}" --data-binary "@${D}/small.bin" "${U}")" == "403" ] || fail "${M} with the own host on another port is not 403"
	[ "$(code -H "${FH}" -H "Origin: http://evil.localhost:${PORT_FILES}" -X "${M}" --data-binary "@${D}/small.bin" "${U}")" == "403" ] || fail "${M} with another *.localhost Origin is not 403"
	[ "$(code -H "${FH}" -H "Sec-Fetch-Site: cross-site" -X "${M}" --data-binary "@${D}/small.bin" "${U}")" == "403" ] || fail "${M} from a cross-site fetch is not 403"
	[ "$(code -H "${FH}" -H "Sec-Fetch-Site: same-site" -X "${M}" --data-binary "@${D}/small.bin" "${U}")" == "403" ] || fail "${M} from a same-site fetch (another host of the site) is not 403"
	[ "$(code -H "Host: evil.example:${PORT_FILES}" -X "${M}" --data-binary "@${D}/small.bin" "${U}")" == "421" ] || fail "${M} with a foreign Host is not 421"
done
[ ! -e "${F}/w.bin" ] && [ ! -e "${F}/w" ] && [ -f "${F}/m.bin" ] || fail "a refused write landed or a refused delete/move changed the folder"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/mkdir?path=&name=own")" == "201" ] || fail "the own origin is refused"
[ "$(code -H "${FH}" -H "Origin: http://localhost:${PORT_FILES}" -X POST "${B}/api/mkdir?path=&name=own2")" == "403" ] || fail "another loopback name as the Origin (http://localhost on the port, where the home page lives) is not refused"
[ "$(code -H "Host: 127.0.0.1:${PORT_FILES}" -H "Origin: http://127.0.0.1:${PORT_FILES}" -X POST "${B}/api/mkdir?path=&name=own2")" == "201" ] || fail "a direct client's own origin (Host and Origin both 127.0.0.1 on the port) is refused"
[ "$(code -H "${FH}" -H "Origin: http://files.localhost:99999" -X POST "${B}/api/mkdir?path=&name=bad1")" == "403" ] || fail "an Origin with a port out of range is not a plain refusal"
[ "$(code -H "${FH}" -H "Origin: http://[::1" -X POST "${B}/api/mkdir?path=&name=bad2")" == "403" ] || fail "an Origin with an unclosed IPv6 literal is not a plain refusal"
[ ! -e "${F}/bad1" ] && [ ! -e "${F}/bad2" ] || fail "a refused Origin made a folder"
[ "$(code -H "${FH}" -H "Sec-Fetch-Site: same-origin" -X POST "${B}/api/mkdir?path=&name=own3")" == "201" ] || fail "a same-origin fetch is refused"
[ "$(code -H "${FH}" -X POST "${B}/api/mkdir?path=&name=own4")" == "201" ] || fail "a request without an Origin (a direct client such as curl) is refused"
[ "$(code -H "${FH}" -H "Origin: https://example.com" "${B}/api/list?path=")" == "403" ] || fail "the listing answers a foreign Origin"
[ "$(code -H "${FH}" -H "Sec-Fetch-Site: cross-site" "${B}/api/list?path=")" == "403" ] || fail "the listing answers a cross-site fetch"
[ "$(code -H "${FH}" -H "${O}" "${B}/api/list?path=")" == "200" ] || fail "the listing refuses its own origin"
[ "$(code -H "${FH}" -H "Sec-Fetch-Site: cross-site" -H "Sec-Fetch-Mode: navigate" "${B}/")" == "200" ] || fail "the tile's own navigation to the page is refused"
[ "$(code -H "${FH}" -H "Sec-Fetch-Site: cross-site" -H "Sec-Fetch-Mode: no-cors" -H "Sec-Fetch-Dest: image" "${B}/api/download?path=m.bin")" == "403" ] || fail "a download fetched from another site (an <img> on a foreign page) is not refused"
[ "$(code -H "${FH}" -H "Sec-Fetch-Site: same-origin" "${B}/api/download?path=m.bin")" == "200" ] || fail "a download from this page is refused"
[ "$(code -H "${FH}" -H "Sec-Fetch-Site: none" "${B}/api/download?path=m.bin")" == "200" ] || fail "a download typed into the address bar is refused"
printf 'PUT /api/upload?path=&name=u.bin HTTP/1.1\r\nHost: files.localhost:%s\r\nOrigin: http://files.localhost:%s\r\nContent-Length: \xc2\xb2\r\n\r\n' "${PORT_FILES}" "${PORT_FILES}" | timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT_FILES}; cat >&3; cat <&3" > "${D}/cl.h" 2>/dev/null
grep -q '^HTTP/1.[01] 411' "${D}/cl.h" || fail "a Content-Length that is a digit but not a number (superscript two) is not refused with 411: $(head -1 "${D}/cl.h")"
for M in DELETE PATCH OPTIONS TRACE PROPFIND; do
	curl -s -D "${D}/m.h" -o "${D}/m.b" --max-time 5 -X "${M}" -H "${FH}" "${B}/api/list"
	grep -q '^HTTP/1.[01] 405' "${D}/m.h" || fail "${M} /api/list is not 405: $(head -1 "${D}/m.h")"
	grep -qi '^Allow: GET, HEAD, PUT, POST' "${D}/m.h" || fail "${M}: no Allow: GET, HEAD, PUT, POST"
	grep -qi '^Content-Type: text/plain' "${D}/m.h" || fail "${M}: the refusal is not plain text (the stdlib's HTML page?)"
	headers_ok "${D}/m.h" || fail "${M}: the refusal lacks the headers every response carries"
	[ "$(code -X "${M}" -H "${FH}" "${B}/")" == "405" ] || fail "${M} / is not 405"
	[ "$(code -X "${M}" -H "Host: evil.example:${PORT_FILES}" "${B}/")" == "421" ] || fail "${M} with a foreign Host is not 421"
done
for P in / /api/list "/api/download?path=m.bin" /healthz /files.js; do
	[ "$(code -H "Host: evil.example:${PORT_FILES}" "${B}${P}")" == "421" ] || fail "a foreign Host is not 421 on ${P}"
	[ "$(code -H "Host: evil.localhost:${PORT_FILES}" "${B}${P}")" == "421" ] || fail "another *.localhost Host is not 421 on ${P}"
done
[ "$(code "${B}/")" == "200" ] || fail "the loopback Host (no header) is refused"
printf 'GET /api/list junk HTTP/1.1\r\nHost: files.localhost:%s\r\n\r\n' "${PORT_FILES}" | timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT_FILES}; cat >&3; cat <&3" > "${D}/bad.h" 2>/dev/null
grep -q '^HTTP/1.[01] 400' "${D}/bad.h" && grep -qi '^Content-Type: text/plain' "${D}/bad.h" && grep -qi '^Cache-Control: no-store' "${D}/bad.h" && ! grep -qi '<html' "${D}/bad.h" \
	|| fail "a malformed request line is not refused as plain text 400 with the headers: $(head -1 "${D}/bad.h")"
printf 'GET /api/list HTTP/9.9\r\nHost: files.localhost:%s\r\n\r\n' "${PORT_FILES}" | timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT_FILES}; cat >&3; cat <&3" > "${D}/bad2.h" 2>/dev/null
grep -qi '<html' "${D}/bad2.h" && fail "an unreadable HTTP version is answered with the stdlib's HTML page"
# CONTROL: a server copy without the origin guard answers a foreign Origin
python3 - "${AGENT_DIR}/files-server.py" "${D}/mutant/files-server-noguard.py" << 'PY' || fail "CONTROL: the no-guard copy could not be planted"
import sys
s = open(sys.argv[1]).read()
anchor = "        if not origin_ok(self.headers, host):\n            return 403,"
assert s.count(anchor) == 1, "the origin guard is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, "        if False:\n            return 403,"))
PY
mkdir -p "${D}/files-noguard"
MUT=$(serve "${PORT_FILES_MUTANT}" "${D}/mutant-noguard.log" "${D}/files-noguard" "${D}/mutant/files-server-noguard.py")
PIDS+=("${MUT}")
upto 200 -H "${MH}" "http://127.0.0.1:${PORT_FILES_MUTANT}/healthz" || fail "the no-guard control server did not come up"
[ "$(code -H "${MH}" -H "Origin: https://example.com" -X PUT --data-binary "@${D}/small.bin" "http://127.0.0.1:${PORT_FILES_MUTANT}/api/upload?path=&name=g.bin")" == "201" ] \
	|| fail "CONTROL: the copy without the origin guard refused a foreign Origin - the 403s above prove nothing"
echo "ok 5 - every response kind carries no-store, nosniff, no-referrer, DENY, same-origin CORP, close and the 'self'-only policy; PUT/POST (upload, mkdir, delete, move) with a foreign, null, other-port, other-host, other-loopback-name or cross-site origin 403 and nothing lands, the own origin, same-origin and no Origin pass; a malformed Origin and a non-number Content-Length are plain refusals; the listing is guarded, the page navigates, a download is served to this page and a direct client and refused to another site; DELETE/PATCH/OPTIONS/TRACE/PROPFIND 405 with Allow as text; a foreign Host 421 everywhere; a malformed line 400 as text; control: without the guard a foreign Origin uploads"

# --- 5b. the destructive calls behind the same guard; the DELETE method stays 405 ---
head -c 10 /dev/urandom > "${D}/o.bin"
[ "$(code -H "${FH}" -H "${O}" -X PUT --data-binary "@${D}/o.bin" "${B}/api/upload?path=&name=o.bin")" == "201" ] || fail "5b: the upload of o.bin"
[ "$(code -H "${FH}" -H "Origin: https://example.com" -X POST "${B}/api/delete?path=&name=o.bin")" == "403" ] && [ -f "${F}/o.bin" ] || fail "a foreign Origin deleted, or was not 403"
[ "$(code -H "${FH}" -H "Origin: https://example.com" -X POST "${B}/api/delete?path=&name=own&recursive=1")" == "403" ] && [ -d "${F}/own" ] || fail "a foreign Origin removed a folder, or was not 403"
[ "$(code -H "${FH}" -H "Origin: null" -X POST "${B}/api/move?path=&name=o.bin&newname=p.bin")" == "403" ] && [ -f "${F}/o.bin" ] && [ ! -e "${F}/p.bin" ] || fail "a null Origin moved, or was not 403"
[ "$(code -H "${FH}" -H "Sec-Fetch-Site: cross-site" -X POST "${B}/api/move?path=&name=o.bin&to=own")" == "403" ] && [ -f "${F}/o.bin" ] || fail "a cross-site fetch moved, or was not 403"
[ "$(code -H "Host: evil.example:${PORT_FILES}" -X POST "${B}/api/delete?path=&name=o.bin")" == "421" ] && [ -f "${F}/o.bin" ] || fail "a foreign Host deleted, or was not 421"
[ "$(code -H "${FH}" -H "${O}" -X DELETE "${B}/api/delete?path=&name=o.bin")" == "405" ] && [ -f "${F}/o.bin" ] || fail "the DELETE method is not 405, or it deleted"
[ "$(code -H "${FH}" -H "${O}" -X DELETE "${B}/o.bin")" == "405" ] && [ -f "${F}/o.bin" ] || fail "DELETE on a file path is not 405"
[ "$(code -H "${FH}" -H "${O}" -X POST "${B}/api/nope?path=&name=o.bin")" == "404" ] || fail "an unknown POST path is not 404"
# CONTROL: the no-guard copy (still up) deletes on a foreign Origin
cp "${D}/o.bin" "${D}/files-noguard/o.bin"
[ "$(code -H "${MH}" -H "Origin: https://example.com" -X POST "http://127.0.0.1:${PORT_FILES_MUTANT}/api/delete?path=&name=o.bin")" == "200" ] && [ ! -e "${D}/files-noguard/o.bin" ] \
	|| fail "CONTROL: the copy without the origin guard did not delete on a foreign Origin - the refusals above prove nothing"
kill "${MUT}" 2>/dev/null
echo "ok 5b - delete and move with a foreign, null or cross-site origin or a foreign Host are refused and nothing changes; the DELETE method is 405 and the file stays; control: without the guard a foreign Origin deletes"

# --- 6. through the home proxy ---
if ! command -v nginx > /dev/null; then
	fail "nginx is not installed (setup/install-nginx.sh) - the route checks cannot run"
fi
render()
{
	# render <UI_DIR> [VAR=value ...] - home-render.sh with the Files tile on (test-local port, folder and cap) and every
	# other UI off; the Board and Plane off too, so no sidecar is expected
	OUT=$1; shift
	env UI_DIR="${OUT}" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME="${PORT_HOME}" UI_FILES=true UI_PORT_FILES="${PORT_FILES}" FILES_DIR="${F}" \
		FILES_MAX_UPLOAD_MB="${MB}" UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false \
		UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_CHAT=false UI_LOOP=false UI_LOOP_DECK=false COMMS_UI_ENABLED=false UI_HOME=true \
		UI_PLANE=false UI_BOARD=false PLANE_URL= KANBAN_BOARD_URL= SUPERVISOR=false "$@" bash "${AGENT_DIR}/home-render.sh"
}
render "${D}/ui" > "${D}/render.log" 2>&1 || { cat "${D}/render.log"; fail "home-render.sh"; }
CONF=${D}/ui/home/nginx.conf
PAGE=${D}/ui/${SITE}/index.html
nginx -t -c "${CONF}" > "${D}/nginx-t.log" 2>&1 || { cat "${D}/nginx-t.log"; fail "the rendered nginx.conf does not pass nginx -t"; }
grep -q "client_max_body_size $((MB + 1))m;" "${CONF}" || fail "the files route's client_max_body_size is not the cap plus one MiB: $(grep -n client_max_body_size "${CONF}" | tr '\n' ' ')"
sed -n '/server_name files.localhost;/,/^\t}/p' "${CONF}" | grep -q 'proxy_request_buffering off;' || fail "the files route buffers uploads to disk (no proxy_request_buffering off)"
sed -n '/server_name files.localhost;/,/^\t}/p' "${CONF}" | grep -q 'limit_except GET HEAD PUT POST' || fail "the files route does not limit the methods to GET HEAD PUT POST"
nginx -c "${CONF}" -g "daemon off;" > "${D}/nginx.log" 2>&1 &
PIDS+=($!)
H=http://127.0.0.1:${PORT_HOME}
upto 200 "${H}/" || fail "the home page does not answer on the test port"
LH="files.localhost:${PORT_HOME}"
PO="Origin: http://${LH}"
# the files server's own policy (check 5 reads it from the server): the route's must be exactly this plus the badge's hashes
SERVER_CSP="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
badge_check()
{
	# badge_check <header file> <page file> <port> - the page carries the badge once, returning to //localhost:<port>/; its
	# three inline parts (the style attribute, the phone rule, the keeper script) are the page's only inline parts, each
	# allowed by its sha256 in the route's policy; that policy is exactly the server's own plus those three hashes
	python3 - "$1" "$2" "$3" "${SERVER_CSP}" << 'PY'
import base64, hashlib, re, sys
head, page, port, server = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3], sys.argv[4]
csp = [l.split(":", 1)[1].strip() for l in head.splitlines() if l.lower().startswith("content-security-policy:")]
if len(csp) != 1:
    sys.exit("the route sends %d Content-Security-Policy headers (want exactly 1)" % len(csp))
csp = csp[0]
h = lambda s: "'sha256-%s'" % base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()
def directives(policy):
    d = {}
    for part in policy.split(";"):
        bits = part.strip().split()
        if bits and bits[0].lower() not in d:
            d[bits[0].lower()] = bits[1:]
    return d
marker = '<a class="hs-badge" data-harness-home'
m = re.search(r'<a class="hs-badge" data-harness-home href="([^"]*)"[^>]*style="([^"]*)"[^>]*>', page)
if page.count(marker) != 1 or not m:
    sys.exit("the badge is not in the page exactly once (%d)" % page.count(marker))
if m.group(1) != "//localhost:%s/" % port:
    sys.exit("the badge returns to %s" % m.group(1))
k = re.search(r'</a><style id="do-agent-aws-home-style">([^<]*)</style><script>([^<]*)</script>', page)
if not k:
    sys.exit("the badge's phone-width rule and keeper script are not in the page right after it")
inline = len(re.findall(r"<script(?![^>]*\bsrc=)[^>]*>", page)) + page.count("<style") + page.count("style=")
if inline != 3:
    sys.exit("the page carries %d inline parts (want the badge's three: its style attribute, rule and script)" % inline)
d = directives(csp)
style, script = d.get("style-src", []), d.get("script-src", [])
if not ("'unsafe-hashes'" in style and h(m.group(2)) in style):
    sys.exit("the route's policy does not allow the badge's style attribute by hash: %s" % csp)
if h(k.group(1)) not in style:
    sys.exit("the route's policy does not allow the badge's phone-width rule by hash: %s" % csp)
if h(k.group(2)) not in script:
    sys.exit("the route's policy does not allow the badge's keeper script by hash: %s" % csp)
want = directives(server)
want["script-src"] = ["'self'", h(k.group(2))]
want["style-src"] = ["'self'", "'unsafe-hashes'", h(m.group(2)), h(k.group(1))]
if d != want:
    sys.exit("the route's policy is not the server's own plus the badge's three hashes: %s" % csp)
if page.count('href="/__harness/harness.css"') != 1:
    sys.exit("the page links the stylesheet %d times (the page's own link, and the badge adds none)" % page.count('href="/__harness/harness.css"'))
if "<title>Files - do-agent-aws harness</title>" not in page:
    sys.exit("the route did not serve the Files page")
print("badge once, back to //localhost:%s/, its three inline parts (the page's only ones) each allowed by hash, the policy "
      "exactly the server's own plus those hashes, one stylesheet link" % port)
PY
}
badge_ok()
{
	# badge_ok <url> <host> - badge_check on the page the route serves
	curl -s -D "${D}/badge.h" -o "${D}/badge.html" --max-time 5 -H "Host: $2" "$1/"
	badge_check "${D}/badge.h" "${D}/badge.html" "${2#*:}"
}
BO=$(badge_ok "${H}" "${LH}" 2>&1) || fail "${BO}"
[ "$(code -H "Host: ${LH}" -H "${PO}" "${H}/api/list?path=")" == "200" ] || fail "the listing does not answer through the route"
[ "$(code -H "Host: ${LH}" "${H}/files.js")" == "200" ] || fail "the page's script does not answer through the route"
curl -s -D "${D}/rcss.h" -o /dev/null --max-time 5 -H "Host: ${LH}" "${H}/__harness/harness.css"
grep -q '^HTTP/1.[01] 200' "${D}/rcss.h" && grep -qi '^Content-Type: text/css' "${D}/rcss.h" || fail "the harness stylesheet is not served on the route: $(head -1 "${D}/rcss.h")"
# the cap through the route: exactly the cap passes, one byte over is the SERVER's 413 (it names the knob), one byte over the
# route's own limit (the cap plus one MiB) is nginx's 413 - so nothing above the cap reaches the folder either way
head -c "${CAP}" /dev/urandom > "${D}/pcap.bin"
curl -s -D "${D}/pcap.h" -o "${D}/pcap.b" --max-time 120 -H "Host: ${LH}" -H "${PO}" -X PUT --data-binary "@${D}/pcap.bin" "${H}/api/upload?path=&name=pcap.bin"
grep -q '^HTTP/1.[01] 201' "${D}/pcap.h" || fail "an upload exactly at the cap does not pass the route: $(head -1 "${D}/pcap.h") $(head -c 200 "${D}/pcap.b")"
[ "$(sha "${F}/pcap.bin")" == "$(sha "${D}/pcap.bin")" ] || fail "the at-cap upload through the route differs"
head -c $((CAP + 1)) /dev/urandom > "${D}/pover.bin"
curl -s -D "${D}/pover.h" -o "${D}/pover.b" --max-time 120 -H "Host: ${LH}" -H "${PO}" -X PUT --data-binary "@${D}/pover.bin" "${H}/api/upload?path=&name=pover.bin"
grep -q '^HTTP/1.[01] 413' "${D}/pover.h" || fail "one byte over the cap through the route is not 413: $(head -1 "${D}/pover.h")"
grep -q 'FILES_MAX_UPLOAD_MB' "${D}/pover.b" || fail "the 413 one byte over the cap is not the server's (it should name the knob): $(head -c 200 "${D}/pover.b")"
head -c $(((MB + 1) * 1024 * 1024 + 1)) /dev/urandom > "${D}/pnginx.bin"
curl -s -D "${D}/pnginx.h" -o "${D}/pnginx.b" --max-time 120 -H "Host: ${LH}" -H "${PO}" -X PUT --data-binary "@${D}/pnginx.bin" "${H}/api/upload?path=&name=pnginx.bin"
grep -q '^HTTP/1.[01] 413' "${D}/pnginx.h" || fail "one byte over the route's limit is not 413: $(head -1 "${D}/pnginx.h")"
grep -q 'FILES_MAX_UPLOAD_MB' "${D}/pnginx.b" && fail "one byte over the route's limit reached the server (client_max_body_size is not enforced by the route)"
[ ! -e "${F}/pover.bin" ] && [ ! -e "${F}/pnginx.bin" ] || fail "an over-cap upload landed through the route"
ls -A "${F}" | grep -q '^\.files-uploading-' && fail "a temporary file remains after the refused uploads through the route"
rm -f "${D:?}/pcap.bin" "${D:?}/pover.bin" "${D:?}/pnginx.bin"
[ "$(code -X DELETE -H "Host: ${LH}" -H "${PO}" "${H}/api/delete?path=&name=pcap.bin")" == "403" ] && [ -f "${F}/pcap.bin" ] || fail "DELETE through the route is not refused by the proxy (limit_except GET HEAD PUT POST)"
[ "$(code -X POST -H "Host: ${LH}" -H "${PO}" "${H}/api/delete?path=&name=pcap.bin")" == "200" ] && [ ! -e "${F}/pcap.bin" ] || fail "a delete through the route from the page's origin does not work"
[ "$(code -X POST -H "Host: ${LH}" -H "Origin: https://example.com" "${H}/api/mkdir?path=&name=viaproxy")" == "403" ] || fail "a foreign Origin through the route is not refused by the server"
# the dot: 204 while the folder is there, 500 once it is gone (the server's 503), 500 with the server stopped, back to 204
grep -qF 'data-host="files" data-probe="/__probe/files" data-path="/"' "${PAGE}" || fail "the Files tile does not carry its probe"
upto 204 "${H}/__probe/files" || fail "the dot probe /__probe/files is not 204 while the folder is there ($(code "${H}/__probe/files"))"
[ "$(code -X POST "${H}/__probe/files")" == "403" ] || fail "the probe is not GET-only"
mv "${F}" "${F}.away"
UPTO_TRIES=40 upto 500 "${H}/__probe/files" || fail "the dot probe stayed $(code "${H}/__probe/files") with the shared folder gone (the server's 503 must read down)"
[ "$(code -H "${FH}" "${B}/healthz")" == "503" ] || fail "/healthz is not 503 with the shared folder gone"
mv "${F}.away" "${F}"
upto 204 "${H}/__probe/files" || fail "the dot probe did not recover with the folder back"
kill "${SRV}" 2>/dev/null
upto 500 "${H}/__probe/files" || fail "the dot probe is not 500 with the server stopped ($(code "${H}/__probe/files"))"
[ "$(code -H "Host: ${LH}" "${H}/")" == "502" ] || fail "the route does not read 502 with the server stopped"
SRV=$(serve "${PORT_FILES}" "${D}/files2.log" "${F}")
PIDS+=("${SRV}")
upto 204 "${H}/__probe/files" || fail "the dot probe did not come back with the server"
# CONTROL: the route without its badge include
mkdir -p "${D}/mutant-home"
python3 - "${AGENT_DIR}/home-render.sh" "${D}/mutant-home/home-render.sh" << 'PY' || fail "CONTROL: the badge-include mutant could not be planted"
import sys
s = open(sys.argv[1]).read()
anchor = ('\t\t\tproxy_pass http://127.0.0.1:${UI_PORT_FILES};\n\t\t\tinclude ${HOME_DIR}/proxy-common.conf;\n'
          '$(host_redirect_rules "${UI_PORT_FILES}")\n\t\t\tinclude ${HOME_DIR}/badge-host-nolink.conf;\n')
assert s.count(anchor) == 1, "the files route's badge include is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, anchor.replace("\t\t\tinclude ${HOME_DIR}/badge-host-nolink.conf;\n", "")))
PY
env UI_DIR="${D}/mutant-ui" UI_LISTEN_HOST=127.0.0.1 UI_PORT_HOME="${PORT_HOME_MUTANT}" UI_FILES=true UI_PORT_FILES="${PORT_FILES}" FILES_DIR="${F}" \
	FILES_MAX_UPLOAD_MB="${MB}" UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false \
	UI_CLAUDE_MEM=false UI_LOGLEARNER=false UI_CHAT=false UI_LOOP=false UI_LOOP_DECK=false COMMS_UI_ENABLED=false UI_HOME=true \
	UI_PLANE=false UI_BOARD=false PLANE_URL= KANBAN_BOARD_URL= SUPERVISOR=false bash "${D}/mutant-home/home-render.sh" > /dev/null 2>&1 || fail "the mutant home-render.sh did not render"
nginx -c "${D}/mutant-ui/home/nginx.conf" -g "daemon off;" > "${D}/nginx-mutant.log" 2>&1 &
PIDS+=($!)
upto 200 "http://127.0.0.1:${PORT_HOME_MUTANT}/" || fail "the mutant proxy did not come up"
MB_=$(badge_ok "http://127.0.0.1:${PORT_HOME_MUTANT}" "files.localhost:${PORT_HOME_MUTANT}" 2>&1) && fail "CONTROL: without the route's badge include the badge check passed: ${MB_}"
case "${MB_}" in *"the badge is not in the page exactly once"*) ;; *) fail "CONTROL: the badge-include mutant failed for another reason: ${MB_}" ;; esac
kill "$(cat "${D}/mutant-ui/home/nginx.pid" 2>/dev/null)" 2>/dev/null
echo "ok 6 - through the proxy: ${BO}; the listing and the stylesheet answer; exactly the cap passes the route, one byte over is the server's 413, one byte over the route's limit nginx's, nothing landed; DELETE 403 at the proxy, a delete by POST works, a foreign Origin 403; the dot 204, 500 with the folder gone, 500 with the server stopped, 204 back; control: without its include -> ${MB_}"

# --- 7. the tile, on and off ---
tile_note()
{
	grep -oE '>Files</span><p>[^<]*</p><p class="note">[^<]*' "$1/${SITE}/index.html" | sed -E 's/.*<p class="note">//'
}
render "${D}/ui-off" UI_FILES=false > /dev/null 2>&1 || fail "render UI_FILES=false"
[ "$(tile_note "${D}/ui-off")" == "off - set UI_FILES=true in .env" ] || fail "UI_FILES=false: the tile reads '$(tile_note "${D}/ui-off")'"
grep -q 'server_name files.localhost' "${D}/ui-off/home/nginx.conf" && fail "UI_FILES=false: the files route is rendered although the tile is off"
grep -q '/__probe/files' "${D}/ui-off/home/nginx.conf" && fail "UI_FILES=false: the files probe is rendered although the tile is off"
grep -q 'data-host="files"' "${D}/ui-off/${SITE}/index.html" && fail "UI_FILES=false: the tile is live although the tile is off"
nginx -t -c "${D}/ui-off/home/nginx.conf" > /dev/null 2>&1 || fail "the UI_FILES=false nginx.conf does not pass nginx -t"
# on (the render of check 6): a live tile opening a new tab that keeps its opener, naming the folder and the cap, under Run and review
grep -qE '<li class="tile" data-host="files" data-probe="/__probe/files" data-path="/"><span class="dot"></span><a [^>]*target="_blank" rel="opener"[^>]*>Files</a>' "${PAGE}" \
	|| fail "with the tile on the Files tile is not a live tile opening a new tab"
grep -oE '>Files</a><p>[^<]*</p><p class="note">[^<]*' "${PAGE}" | grep -qF "the shared folder ${F}" || fail "the live tile does not name the shared folder: $(grep -oE '>Files</a><p>[^<]*' "${PAGE}")"
grep -oE '>Files</a><p>[^<]*</p><p class="note">[^<]*' "${PAGE}" | grep -qF "uploads up to ${MB} MiB each (FILES_MAX_UPLOAD_MB in .env)" || fail "the live tile's note does not name the cap and its knob: $(grep -oE '>Files</a><p>[^<]*</p><p class="note">[^<]*' "${PAGE}")"
grep -oE '>Files</a><p>[^<]*</p><p class="note">[^<]*' "${PAGE}" | grep -qF "nothing is executed" || fail "the live tile's note does not say nothing is executed"
group_titles() { awk -v g="<h2 class=\"group\">$2</h2>" 'index($0, g) {on=1; next} /<h2 class="group">/ {on=0} on' "$1" \
	| grep -oE '^<li class="tile" [^>]*><span class="dot"></span><a href="[^"]*"[^>]*>[^<]*|^<li class="tile off[^"]*"><span class="dot"></span><span class="title">[^<]*' | sed -E 's/.*>//'; }
group_titles "${PAGE}" 'Run and review' | grep -qxF "Files" || fail "the Files tile is not under Run and review (there: $(group_titles "${PAGE}" 'Run and review' | tr '\n' ','))"
grep -q '<h2 class="group">Other</h2>' "${PAGE}" && fail "the page carries an Other group (a tile no group names)"
echo "ok 7 - the tile: off with its flag, no route and no probe; on, live with its probe, a new tab, naming the folder, the cap and its knob, under Run and review"

# --- 8. ui-start.sh, ui-status.sh, ui-stop.sh ---
(
	export UI_HEADLAMP=false UI_HINDSIGHT=false UI_VIBE_KANBAN=false UI_TMUX=false UI_TMUX_AGENT=false UI_CLAUDE_MEM=false \
		UI_LOGLEARNER=false UI_LOOP=false UI_LOOP_DECK=false LOOP_DECK_DATA_DIR="${D}/loop-deck" UI_CHAT=false UI_BOARD=false UI_PLANE=false \
		PLANE_URL= KANBAN_BOARD_URL= COMMS_UI_ENABLED=false SUPERVISOR=false SPOKE_DOCKER=false UI_HOME=true UI_LISTEN_HOST=127.0.0.1 \
		UI_FILES=true UI_PORT_FILES="${PORT_FILES_UI}" FILES_DIR="${D}/files-ui" FILES_MAX_UPLOAD_MB="${MB}" UI_PORT_HOME="${PORT_HOME_UI}" \
		UI_PORT_KNOWLEDGE="${PORT_KNOWLEDGE_UI}" UI_DIR="${D}/ui2"
	[ -d "${D}/files-ui" ] && exit 10
	"${AGENT_DIR}/ui-start.sh" > "${D}/ui-start.log" 2>&1 || { cat "${D}/ui-start.log"; exit 11; }
	grep -q '^files: started' "${D}/ui-start.log" || { cat "${D}/ui-start.log"; exit 12; }
	[ -d "${D}/files-ui" ] || { echo "ui-start.sh did not create FILES_DIR"; exit 13; }
	for _ in $(seq 1 80); do "${AGENT_DIR}/ui-status.sh" > "${D}/ui-status.log" 2>&1 && break; sleep 0.25; done
	grep -q "^files: UP pid=[0-9]* http=200 port=${PORT_FILES_UI}" "${D}/ui-status.log" || { cat "${D}/ui-status.log"; exit 14; }
	ADDRS=$(ss -ltnH "sport = :${PORT_FILES_UI}" | awk '{print $4}')
	[ "${ADDRS}" == "127.0.0.1:${PORT_FILES_UI}" ] || { echo "the files server listens on: ${ADDRS}"; exit 15; }
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: files.localhost:${PORT_HOME_UI}" "http://127.0.0.1:${PORT_HOME_UI}/")" == "200" ] || exit 16
	echo "from the agent" > "${D}/files-ui/hello.txt"
	curl -s --max-time 5 -H "Host: files.localhost:${PORT_HOME_UI}" -H "Origin: http://files.localhost:${PORT_HOME_UI}" "http://127.0.0.1:${PORT_HOME_UI}/api/list?path=" | grep -q '"hello.txt"' || exit 17
	"${AGENT_DIR}/ui-stop.sh" > "${D}/ui-stop.log" 2>&1
	grep -q '^files: stopped' "${D}/ui-stop.log" || { cat "${D}/ui-stop.log"; exit 18; }
	[ -f "${D}/ui2/files.pid" ] && exit 19
	[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT_FILES_UI}/healthz")" == "000" ] || exit 20
	# off: nothing starts, the status says so
	export UI_FILES=false
	"${AGENT_DIR}/ui-start.sh" > "${D}/ui-start2.log" 2>&1 || { cat "${D}/ui-start2.log"; exit 21; }
	grep -q '^files:' "${D}/ui-start2.log" && exit 22
	"${AGENT_DIR}/ui-status.sh" > "${D}/ui-status2.log" 2>&1
	grep -q '^files: DISABLED' "${D}/ui-status2.log" || { cat "${D}/ui-status2.log"; exit 23; }
	"${AGENT_DIR}/ui-stop.sh" > /dev/null 2>&1
	exit 0
)
RC=$?
[ "${RC}" == "0" ] || fail "ui-start/ui-status/ui-stop (step ${RC}; see ${D}/ui-*.log)"
echo "ok 8 - after ui-start.sh the shared folder exists and the files server runs on 127.0.0.1 only, the route answers through the home port and lists a file the agent wrote, ui-status.sh reports it UP, ui-stop.sh stops it; UI_FILES=false starts nothing and reads DISABLED"

# --- 9. the agent's note ---
NOTE_SRC=${RULES_DIR}/AGENT_FILES.md
[ -s "${NOTE_SRC}" ] || fail "agent-rules/AGENT_FILES.md is missing"
grep -q '/wd/files' "${NOTE_SRC}" || fail "the note does not name the shared folder /wd/files"
grep -qi 'deliverable' "${NOTE_SRC}" && grep -qi 'upload' "${NOTE_SRC}" || fail "the note does not cover both directions (deliverables out, uploads in)"
grep -qi 'never run' "${NOTE_SRC}" || fail "the note does not say nothing is run from there"
for SHAPE in '[0-9]{12}' 'dkr\.ecr\.|public\.ecr\.aws' '\bAKIA[0-9A-Z]{8,}' '(xoxb|xoxp)-[0-9]' '/home/[a-z]'; do
	grep -Eiq "${SHAPE}" "${NOTE_SRC}" && fail "the note leaks an environment-specific identifier (${SHAPE})"
done
mkdir -p "${D}/claude"
printf '# my own notes\nkeep this line\n' > "${D}/claude/CLAUDE.md"
cp "${D}/claude/CLAUDE.md" "${D}/claude/CLAUDE.md.planted"
echo "an outdated copy" > "${D}/claude/AGENT_FILES.md"
echo '{}' > "${D}/claude/settings.json"
FILES_DIR=/wd/files CLAUDE_CONFIG_DIR=${D}/claude KNOWLEDGE_DIR=${D}/knowledge AGENT_RULES_DIR=${RULES_DIR} "${AGENT_DIR}/claude-settings-sync.sh" > "${D}/sync1.log" 2>&1
head -c "$(wc -c < "${D}/claude/CLAUDE.md.planted")" "${D}/claude/CLAUDE.md" | cmp -s - "${D}/claude/CLAUDE.md.planted" || fail "the sync changed the user's CLAUDE.md lines"
[ "$(grep -cxF '@AGENT_FILES.md' "${D}/claude/CLAUDE.md")" == "1" ] || fail "the sync did not reference AGENT_FILES.md exactly once: $(grep -c AGENT_FILES "${D}/claude/CLAUDE.md") time(s); $(grep -i files "${D}/sync1.log")"
grep -q '^## Files for the person' "${D}/claude/CLAUDE.md" || fail "the pointer has no heading naming the shared folder"
cmp -s "${NOTE_SRC}" "${D}/claude/AGENT_FILES.md" || fail "the sync did not refresh the outdated AGENT_FILES.md"
grep -q 'AGENT_FILES.md updated' "${D}/sync1.log" && grep -q 'now references AGENT_FILES.md' "${D}/sync1.log" || fail "the sync did not say what it did for the Files note: $(grep -i files "${D}/sync1.log")"
SHA9=$(cat "${D}/claude/CLAUDE.md" "${D}/claude/AGENT_FILES.md" | sha256sum)
FILES_DIR=/wd/files CLAUDE_CONFIG_DIR=${D}/claude KNOWLEDGE_DIR=${D}/knowledge AGENT_RULES_DIR=${RULES_DIR} "${AGENT_DIR}/claude-settings-sync.sh" > "${D}/sync2.log" 2>&1
[ "$(cat "${D}/claude/CLAUDE.md" "${D}/claude/AGENT_FILES.md" | sha256sum)" == "${SHA9}" ] || fail "a re-sync changed CLAUDE.md or AGENT_FILES.md"
grep -q 'AGENT_FILES' "${D}/sync2.log" && fail "a re-sync reported a Files change: $(grep AGENT_FILES "${D}/sync2.log")"
# another folder: the copy names it everywhere the shipped text says /wd/files (the tile serves FILES_DIR, the agent must hear the same)
mkdir -p "${D}/claude-shared"
FILES_DIR=/wd/shared CLAUDE_CONFIG_DIR=${D}/claude-shared KNOWLEDGE_DIR=${D}/knowledge AGENT_RULES_DIR=${RULES_DIR} "${AGENT_DIR}/claude-settings-sync.sh" > "${D}/sync3.log" 2>&1
grep -q '/wd/shared' "${D}/claude-shared/AGENT_FILES.md" || fail "with FILES_DIR=/wd/shared the note does not name /wd/shared"
grep -q '/wd/files' "${D}/claude-shared/AGENT_FILES.md" && fail "with FILES_DIR=/wd/shared the note still names /wd/files: $(grep -n '/wd/files' "${D}/claude-shared/AGENT_FILES.md" | head -2)"
[ "$(grep -c '/wd/shared' "${D}/claude-shared/AGENT_FILES.md")" == "$(grep -c '/wd/files' "${NOTE_SRC}")" ] || fail "the rendered note does not name the folder on every line the shipped one does"
grep -q 'the shared folder /wd/shared' "${D}/sync3.log" || fail "the sync does not say which folder it rendered: $(grep -i files "${D}/sync3.log")"
echo "ok 9 - the note names /wd/files, both directions and that nothing runs from there, no leak shapes; the sync puts it beside CLAUDE.md, refreshes an outdated copy, references it once; a re-sync changes nothing; FILES_DIR=/wd/shared renders a note naming /wd/shared"

if [ "${TEST_CONTAINER}" == "true" ]; then
	W=$(find /wd -mindepth 1 2>/dev/null | wc -l)
	[ "${W}" -eq 0 ] || fail "this test wrote ${W} entries under /wd"
fi
echo "Test-files succeeded"
