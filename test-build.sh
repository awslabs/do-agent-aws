#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of build.sh's steps after the image build (docs/manual/supply-chain.md "Software bill of materials", "CVE scan"): in a copy of
# the scripts, with docker stubbed on PATH and a planted scan.sh, ./build.sh copies the image's /SBOM.txt into THIRD-PARTY-LICENSES
# through a temporary file, then runs the CVE scan. test.sh runs it beside test-run.sh. Each check FAILS if the property it proves
# is removed:
#   1. a sound build: the image build runs, then the board image's (UI_VIBE_KANBAN=true), then exactly one
#      `docker container run --rm --entrypoint cat <image> /SBOM.txt` - after every build; THIRD-PARTY-LICENSES
#      is byte-identical to what the cat answered and mode 0644, no THIRD-PARTY-LICENSES.tmp.* is left, exit 0, one line says it
#      was written; then ./scan.sh, exactly once, the last call of all (test-scan.sh proves scan.sh itself)
#   2. a cat that fails (an image without /SBOM.txt: docker's and cat's own words are in the ERROR line) or answers something
#      that is not a bill of materials (no `## Software bill of materials` first line; the line it got is quoted): exit 1, one
#      ERROR line naming the image, /SBOM.txt and RUN /sbom.sh, the previous THIRD-PARTY-LICENSES byte-identical (the planted
#      previous content survives), no temporary file left; the cat runs with --network none
#   3. a failed image build: exit non-zero, no cat attempted, THIRD-PARTY-LICENSES untouched, no scan
#   4. CVE_SCAN=false in the environment (the way the other host tests build): no scan, exit 0; .env's default is true and the
#      environment overrides it
#   5. a scan that fails the gate (exit 4) or could not be evaluated (exit 3): build.sh exits with that status, after
#      THIRD-PARTY-LICENSES was written (the scan is the last step)
#   6. the Plane board is opt-in (docs/manual/boards.md "Plane board"): .env ships UI_PLANE=false, and a build with that default calls
#      nothing of ./plane.sh (nothing of Plane is pulled); UI_PLANE=true in .env.local pulls its images (./plane.sh pull, once)
set -u
D=$(mktemp -d)
trap 'rm -rf "${D:?}"' EXIT
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "Test-build FAILED: $*"; exit 1; }

mkdir -p "${D}/bin" "${D}/copy/Container-Root" || fail "could not make the copy"
cp "${BASE_DIR}/build.sh" "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${BASE_DIR}/preflight.sh" "${D}/copy/" || fail "could not copy build.sh and the files it reads"
# kanban.sh, plane.sh and docker.sh record their calls in the same file as docker, so the order of every step is one list
for S in kanban.sh plane.sh docker.sh; do
	printf '#!/bin/bash\n{ printf '"'"'%s|'"'"'; [ $# -gt 0 ] && printf '"'"'%%s|'"'"' "$@"; echo; } >> "${STUB_CALLS}"\nexit 0\n' "${S}" > "${D}/copy/${S}"
	chmod +x "${D}/copy/${S}"
done
# the planted scan.sh (docs/manual/supply-chain.md "CVE scan"): records its call in the same list, exits STUB_SCAN_RC
printf '#!/bin/bash\n{ printf '"'"'scan.sh|'"'"'; [ $# -gt 0 ] && printf '"'"'%%s|'"'"' "$@"; echo; } >> "${STUB_CALLS}"\nexit "${STUB_SCAN_RC:-0}"\n' > "${D}/copy/scan.sh"
chmod +x "${D}/copy/scan.sh"
# the stub's answer for `cat /SBOM.txt`: a bill of materials the way /sbom.sh writes one
printf '## Software bill of materials (SBOM) of the container image do-agent-aws, build 20260101\n## components: apt 1; npm 0; python 0; tools 0; total 1; UNKNOWN 0\n\n# apt packages (dpkg)\nplanted 1.0-1 - MIT\n' > "${D}/sbom.txt"
cat > "${D}/bin/docker" << 'STUB'
#!/bin/bash
# test-build.sh's docker: records its words; a sound host for the preflight; `image build` exits STUB_BUILD_RC; `container run
# ... cat /SBOM.txt` answers STUB_SBOM_FILE's content (STUB_SBOM_ANSWER=garbage: a line that is no bill of materials;
# STUB_SBOM_ANSWER=none: nothing and exit 1, as cat does for a file the image has not)
{ printf 'docker|'; printf '%s|' "$@"; echo; } >> "${STUB_CALLS}"
case "$1 $2" in
	"info "*) [ "$2" == "--format" ] && echo /var/lib/docker; exit 0 ;;
	"buildx version") echo "github.com/docker/buildx (stub)"; exit 0 ;;
	"version "*) echo 1.44; exit 0 ;;
	"image build") echo "stub: image built"; exit "${STUB_BUILD_RC:-0}" ;;
	"network "*) exit 0 ;;
	"container run")
		case " $* " in
			*" /SBOM.txt "*)
				case "${STUB_SBOM_ANSWER:-file}" in
					none) echo "cat: /SBOM.txt: No such file or directory" >&2; exit 1 ;;
					garbage) echo "0123456789abcdef"; exit 0 ;;
					*) cat "${STUB_SBOM_FILE}"; exit 0 ;;
				esac ;;
		esac
		echo 0123456789abcdef; exit 0 ;;
esac
exit 0
STUB
chmod +x "${D}/bin/docker"
# local_env [<line>...] - the copy's .env.local: the docker target, a name of its own, the sidecars off, then the lines given
local_env() { { echo "export TO=docker"; echo "export CONTAINER=test-build-agent"; echo "export UI_PLANE=false"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; printf '%s\n' "$@"; } > "${D}/copy/.env.local"; }
# run [NAME=value...] - ./build.sh in the copy with the stubs on PATH; output in ${D}/out, the calls in ${D}/calls; prints the exit status
run()
{
	rm -f "${D:?}/calls"
	( cd "${D}/copy" && env PATH="${D}/bin:${PATH}" ENV_LOCAL_SETUP=false BUILD_MIN_FREE_GB=1 STUB_CALLS="${D}/calls" STUB_SBOM_FILE="${D}/sbom.txt" "$@" ./build.sh ) > "${D}/out" 2>&1
	echo $?
}
out() { tail -3 "${D}/out" | cut -c1-300 | tr '\n' ' '; }
calls() { cat "${D}/calls" 2> /dev/null; }
CAT='docker|container|run|--rm|--network|none|--entrypoint|cat|do-agent-aws:latest|/SBOM.txt|'
no_tmp() { ls "${D}/copy"/THIRD-PARTY-LICENSES.tmp.* "${D}/copy"/THIRD-PARTY-LICENSES.err.* > /dev/null 2>&1 && fail "$1: a temporary file was left: $(ls "${D}/copy"/THIRD-PARTY-LICENSES.*.*)"; }

# --- 1. a sound build writes the file, after every build ---
local_env
RC=$(run)
[ "${RC}" == "0" ] || fail "1: build.sh exited ${RC} on a sound build (expected 0): $(out)"
[ "$(calls | grep -cxF -- "${CAT}")" == "1" ] || fail "1: expected exactly one cat of /SBOM.txt from the image: $(calls | grep -F container | tr '\n' ' ')"
[ "$(calls | grep -n -F -- "${CAT}" | cut -d: -f1)" == "$(( $(calls | wc -l) - 1 ))" ] || fail "1: the cat is not the call before the scan: $(calls | tr '\n' ' ')"
[ "$(calls | tail -1)" == "scan.sh|" ] || fail "1: ./scan.sh is not the last call: $(calls | tr '\n' ' ')"
[ "$(calls | grep -cx 'scan.sh|')" == "1" ] || fail "1: expected exactly one ./scan.sh call: $(calls | grep -c scan.sh)"
calls | grep -q '^docker|image|build|' || fail "1: no docker image build: $(calls | tr '\n' ' ')"
cmp -s "${D}/copy/THIRD-PARTY-LICENSES" "${D}/sbom.txt" || fail "1: THIRD-PARTY-LICENSES is not what the image's /SBOM.txt holds: $(head -2 "${D}/copy/THIRD-PARTY-LICENSES" | tr '\n' '|')"
[ "$(stat -c %a "${D}/copy/THIRD-PARTY-LICENSES")" == "644" ] || fail "1: THIRD-PARTY-LICENSES is mode $(stat -c %a "${D}/copy/THIRD-PARTY-LICENSES"), not 644 (mktemp's 0600 would make a committed file unreadable to others)"
no_tmp 1
[ "$(grep -c '^build.sh: THIRD-PARTY-LICENSES written from the image' "${D}/out")" == "1" ] || fail "1: not exactly one line saying the file was written: $(out)"
grep -q 'apt 1; npm 0; python 0; tools 0; total 1; UNKNOWN 0' "${D}/out" || fail "1: the line does not carry the file's counts: $(grep '^build.sh: THIRD-PARTY' "${D}/out")"
local_env 'export UI_VIBE_KANBAN=true'
RC=$(run)
[ "${RC}" == "0" ] || fail "1: build.sh exited ${RC} with the board image on (expected 0): $(out)"
calls | grep -q '^kanban.sh|build|$' || fail "1: with UI_VIBE_KANBAN=true the board image was not built: $(calls | tr '\n' ' ')"
[ "$(calls | tail -2 | head -1)" == "${CAT}" ] && [ "$(calls | tail -1)" == "scan.sh|" ] || fail "1: with the board image on, the cat and the scan are not the last two calls: $(calls | tr '\n' ' ')"
echo "ok 1 - a sound build ends with one cat of /SBOM.txt from the image, after the image build and the board image's, then one ./scan.sh; THIRD-PARTY-LICENSES is that file, no temporary file left, one line says so"

# --- 2. an answer that is no bill of materials leaves the committed file alone ---
for ANSWER in garbage none; do
	local_env
	printf 'PREVIOUS CONTENT\n' > "${D}/copy/THIRD-PARTY-LICENSES"
	RC=$(run STUB_SBOM_ANSWER="${ANSWER}")
	[ "${RC}" == "1" ] || fail "2: build.sh exited ${RC} when cat answered ${ANSWER} (expected 1): $(out)"
	[ "$(grep -c '^build.sh: ERROR - .*do-agent-aws:latest.*/SBOM.txt.*its last step is RUN /sbom.sh); THIRD-PARTY-LICENSES is left as it was$' "${D}/out")" == "1" ] \
		|| fail "2: not exactly one ERROR line naming the image, /SBOM.txt and RUN /sbom.sh when cat answered ${ANSWER}: $(out)"
	case "${ANSWER}" in
		none) grep -q "reading /SBOM.txt from the image do-agent-aws:latest failed: cat: /SBOM.txt: No such file or directory" "${D}/out" || fail "2: the ERROR line does not carry docker's and cat's own words: $(out)" ;;
		garbage) grep -q "answered something that is not a software bill of materials for /SBOM.txt ('0123456789abcdef'" "${D}/out" || fail "2: the ERROR line does not quote the first line it got: $(out)" ;;
	esac
	[ "$(cat "${D}/copy/THIRD-PARTY-LICENSES")" == "PREVIOUS CONTENT" ] || fail "2: the previous THIRD-PARTY-LICENSES was changed when cat answered ${ANSWER}: $(head -2 "${D}/copy/THIRD-PARTY-LICENSES" | tr '\n' '|')"
	no_tmp 2
	grep -q '^build.sh: THIRD-PARTY-LICENSES written' "${D}/out" && fail "2: build.sh said the file was written although cat answered ${ANSWER}"
done
echo "ok 2 - a cat that answers no bill of materials (another text, or nothing as for an image without /SBOM.txt): exit 1, one ERROR line, the previous file byte-identical, no temporary file"

# --- 3. a failed image build never reaches the extraction ---
local_env
printf 'PREVIOUS CONTENT\n' > "${D}/copy/THIRD-PARTY-LICENSES"
RC=$(run STUB_BUILD_RC=7)
[ "${RC}" == "7" ] || fail "3: build.sh exited ${RC} when the image build exited 7 (expected 7): $(out)"
calls | grep -q '^docker|container|run|' && fail "3: a failed image build was followed by a container run: $(calls | tr '\n' ' ')"
[ "$(cat "${D}/copy/THIRD-PARTY-LICENSES")" == "PREVIOUS CONTENT" ] || fail "3: THIRD-PARTY-LICENSES changed after a failed build"
no_tmp 3
calls | grep -q '^scan.sh|' && fail "3: a failed image build was followed by the scan: $(calls | tr '\n' ' ')"
echo "ok 3 - a failed image build exits with its status, attempts no extraction and no scan, leaves THIRD-PARTY-LICENSES as it was"

# --- 4. CVE_SCAN=false in the environment skips the scan; the default is true ---
local_env
RC=$(run CVE_SCAN=false)
[ "${RC}" == "0" ] || fail "4: build.sh exited ${RC} with CVE_SCAN=false (expected 0): $(out)"
calls | grep -q '^scan.sh|' && fail "4: ./scan.sh ran although CVE_SCAN=false: $(calls | tr '\n' ' ')"
calls | grep -q -F -- "${CAT}" || fail "4: with CVE_SCAN=false the extraction did not run: $(calls | tr '\n' ' ')"
grep -q '^export CVE_SCAN=${CVE_SCAN:-true}$' "${BASE_DIR}/.env" || fail "4: .env does not default CVE_SCAN to true with the environment overriding it: $(grep -n 'CVE_SCAN=' "${BASE_DIR}/.env")"
echo "ok 4 - CVE_SCAN=false in the environment: the build and the extraction run, no scan; .env defaults CVE_SCAN to true"

# --- 5. the scan's exit status is build.sh's, after the extraction ---
local_env
for SRC in 4 3; do
	printf 'PREVIOUS CONTENT\n' > "${D}/copy/THIRD-PARTY-LICENSES"
	RC=$(run STUB_SCAN_RC=${SRC})
	[ "${RC}" == "${SRC}" ] || fail "5: build.sh exited ${RC} when scan.sh exited ${SRC} (expected ${SRC}): $(out)"
	cmp -s "${D}/copy/THIRD-PARTY-LICENSES" "${D}/sbom.txt" || fail "5: THIRD-PARTY-LICENSES was not written before the scan that exited ${SRC}"
	[ "$(calls | tail -1)" == "scan.sh|" ] || fail "5: the scan was not the last call: $(calls | tr '\n' ' ')"
done
echo "ok 5 - a scan exiting 4 or 3 is build.sh's exit status, after THIRD-PARTY-LICENSES was written"

# --- 6. the Plane board is opt-in: the shipped default pulls nothing of it, UI_PLANE=true pulls its images ---
grep -q '^export UI_PLANE=false$' "${BASE_DIR}/.env" || fail "6: .env does not ship UI_PLANE=false (the Plane board is opt-in): $(grep -n '^export UI_PLANE=' "${BASE_DIR}/.env")"
{ echo "export TO=docker"; echo "export CONTAINER=test-build-agent"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; } > "${D}/copy/.env.local"   # no UI_PLANE line: the shipped default
RC=$(run CVE_SCAN=false)
[ "${RC}" == "0" ] || fail "6: build.sh exited ${RC} with the shipped Plane default (expected 0): $(out)"
calls | grep -q '^plane.sh|' && fail "6: with the shipped default (UI_PLANE=false) build.sh called ./plane.sh: $(calls | grep '^plane.sh' | tr '\n' ' ')"
calls | grep -qi 'makeplane' && fail "6: with the shipped default a Plane image was pulled: $(calls | grep -i makeplane | tr '\n' ' ')"
calls | grep -q '^docker|image|build|' || fail "6: the agent image was not built with the shipped default: $(calls | tr '\n' ' ')"
local_env 'export UI_PLANE=true'
RC=$(run CVE_SCAN=false)
[ "${RC}" == "0" ] || fail "6: build.sh exited ${RC} with UI_PLANE=true (expected 0): $(out)"
[ "$(calls | grep -cx 'plane.sh|pull|')" == "1" ] || fail "6: with UI_PLANE=true in .env.local build.sh did not call ./plane.sh pull exactly once: $(calls | grep '^plane.sh' | tr '\n' ' ')"
echo "ok 6 - the Plane board is opt-in: .env ships UI_PLANE=false, a build with that default calls nothing of ./plane.sh (nothing of Plane pulled) and builds the image; UI_PLANE=true in .env.local pulls its images (./plane.sh pull, once)"

echo "Test-build succeeded"
