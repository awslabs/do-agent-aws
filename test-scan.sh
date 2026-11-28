#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of ./scan.sh, the CVE scan at the end of ./build.sh (docs/manual/supply-chain.md "CVE scan"); test.sh runs it beside test-build.sh.
# In a copy of the scripts, with docker stubbed on PATH (and trivy, for TRIVY=<cli>), scan.sh walks the image once with the pinned
# scanner container, as this user through a planted Docker socket, writes the report, the table, the two bills of materials, the
# gate's findings and the summary under cve/, gates on the planted report and writes the pass record only on a pass. Each check
# FAILS if the property it proves is removed:
#   1. a report with nothing of the gate severity (one MEDIUM): exit 0; exactly ONE `trivy image --scanners vuln --list-all-pkgs
#      --format json` walk of the image .env names, run as this user with the socket's group, the socket, the cache and cve/
#      mounted, the proxy settings passed; three `trivy convert`s from that report (the CRITICAL,HIGH table, cyclonedx, spdx-json)
#      and no second walk; the summary names the planted scanner version, the database date and the counts; the pass record carries
#      the planted image id; `./scan.sh <image>` scans that image and names the files after it
#   2. a CRITICAL with a fixed version: exit 4, no pass record, the gate line names the package, both versions and the CVE, the
#      refusal names .trivyignore; a pass record planted before the run is gone. CONTROL: a copy of scan.sh that does not remove
#      the previous record fails this check
#   3. a CRITICAL without a fixed version: CVE_IGNORE_UNFIXED=true exit 0, the summary reads "CRITICAL=1 (1 without a fix)" and the
#      gate line says no-fix; CVE_IGNORE_UNFIXED=false (in .env.local, as every knob but CVE_SCAN is set) exit 4
#   4. no report (the scanner wrote nothing), an empty one, one that is not a trivy report, a scanner that exited non-zero: exit 3,
#      no pass record, and the FAIL line says so - never a pass
#   5. CVE_MAX_HIGH=0 with one fixable HIGH: exit 5, no record; the same report with CVE_MAX_HIGH empty: exit 0
#   6. the scanner image not present and not pullable: exit 3 with docker's words; the image to scan not present: exit 3; both
#      before any walk
#   7. TRIVY=<cli>: the trivy on PATH runs the same walk and conversions with cve/ paths, and docker runs no container
#   8. the shipped default, CVE_GATE_SEVERITY=CRITICAL: a fixable CRITICAL fails the scan (exit 4); report only (CVE_GATE_SEVERITY=
#      set empty in .env.local): a fixable CRITICAL and a HIGH give exit 0, no pass record, the summary's gate line reads off /
#      REPORT ONLY, the CRITICAL is still listed; CVE_MAX_HIGH=0 with the gate off still exits 5 (a gate of its own),
#      CVE_MAX_HIGH=50 within the cap exits 0 and still writes no record
#   9. before any walk: docker not usable (exit 3), a Docker endpoint that is not a unix socket (DOCKER_HOST=tcp://, exit 3), a
#      CVE_MAX_HIGH that is not a number (exit 3) - none of them walks the image or leaves a record
#  10. a conversion that fails or writes nothing (STUB_CONVERT_RC, STUB_CONVERT_EMPTY): exit 3, no record; a `--version` that fails:
#      exit 3, no record (a verdict without its provenance is none); a previous run's table, SBOMs and summary are removed first
#  11. two gate severities, `CRITICAL, high` (spaces, lower case): a fixable HIGH alone fails (exit 4), the table's severities read
#      CRITICAL,HIGH once, the gate line names both
set -u
D=$(mktemp -d)
trap 'rm -rf "${D:?}"' EXIT
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "Test-scan FAILED: $*"; exit 1; }

mkdir -p "${D}/bin" "${D}/copy" || fail "could not make the copy"
cp "${BASE_DIR}/scan.sh" "${BASE_DIR}/.env" "${BASE_DIR}/.fun" "${BASE_DIR}/preflight.sh" "${D}/copy/" || fail "could not copy scan.sh and the files it reads"
# the planted Docker socket: a unix socket of this user, the endpoint DOCKER_HOST names for the run
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "${D}/sock" || fail "could not plant a socket"
# what trivy does, for both stubs: `image ... -o <out> <image>` writes STUB_REPORT's content to <out> (STUB_REPORT=none writes
# nothing) and exits STUB_SCAN_RC; `convert --format <f> -o <out> <in>` writes a planted artifact; `--version` a planted block.
# <out> paths under /cve are the container's view: STUB_HOSTDIR is where they land
cat > "${D}/bin/trivy-emulate.sh" << 'STUB'
trivy_emulate()
{
	local out="" a prev=""
	for a in "$@"; do [ "${prev}" == "-o" ] && out="${a}"; prev="${a}"; done
	[ -n "${STUB_HOSTDIR:-}" ] && out="${out/#\/cve/${STUB_HOSTDIR}}"
	case "$1" in
		image) [ "${STUB_REPORT:-}" != "none" ] && cat "${STUB_REPORT}" > "${out}"; echo "stub: scanned"; exit "${STUB_SCAN_RC:-0}" ;;
		convert) [ "${STUB_CONVERT_RC:-0}" == "0" ] || { echo "stub: convert failed" >&2; exit "${STUB_CONVERT_RC}"; }
			[ "${STUB_CONVERT_EMPTY:-0}" == "1" ] && { : > "${out}"; exit 0; }
			case " $* " in
				*" --format table "*) printf 'planted table\n' > "${out}" ;;
				*" --format cyclonedx "*) printf '{"bomFormat": "CycloneDX", "components": []}\n' > "${out}" ;;
				*" --format spdx-json "*) printf '{"spdxVersion": "SPDX-2.3", "packages": []}\n' > "${out}" ;;
				*) echo "stub: unknown convert format" >&2; exit 1 ;;
			esac; exit 0 ;;
		--version) [ "${STUB_VERSION_RC:-0}" == "0" ] || exit "${STUB_VERSION_RC}"
			printf 'Version: 0.76.1\nVulnerability DB:\n  Version: 2\n  UpdatedAt: 2026-10-27 01:25:30.944314632 +0000 UTC\n  NextUpdate: 2026-10-28 01:25:30.944314361 +0000 UTC\nJava DB:\n  UpdatedAt: 2026-10-20 00:00:00 +0000 UTC\n'; exit 0 ;;
	esac
	exit 0
}
STUB
cat > "${D}/bin/docker" << 'STUB'
#!/bin/bash
# test-scan.sh's docker: records its words; a sound daemon whose endpoint is the planted socket; `image inspect` answers present
# (STUB_NO_IMAGE=1: the image to scan is missing; STUB_TRIVY_RC: the scanner image's inspect); `image pull` fails with words;
# `container run ... <scanner image> <trivy words>` is trivy (trivy-emulate.sh), the host directory mounted at /cve its output dir
{ printf 'docker|'; printf '%s|' "$@"; echo; } >> "${STUB_CALLS}"
source "$(dirname "$0")/trivy-emulate.sh"
case "$1 $2" in
	"info "*) exit "${STUB_INFO_RC:-0}" ;;
	"context inspect") echo "unix://${STUB_SOCK}"; exit 0 ;;
	"image inspect") case "$3" in
			public.ecr.aws/aquasecurity/trivy*) exit "${STUB_TRIVY_RC:-0}" ;;
			*) [ "${STUB_NO_IMAGE:-0}" == "1" ] && { echo "Error response from daemon: No such image: $3" >&2; exit 1; }; exit 0 ;;
		esac ;;
	"image pull") echo "Error response from daemon: planted: pull access denied for $4" >&2; exit 1 ;;
	"container run")
		shift 2
		while [ $# -gt 0 ]; do
			case "$1" in
				-v) case "$2" in *:/cve) STUB_HOSTDIR=${2%:/cve} ;; esac; shift 2 ;;
				public.ecr.aws/aquasecurity/trivy*) shift; trivy_emulate "$@" ;;
				*) shift ;;
			esac
		done
		exit 0 ;;
esac
exit 0
STUB
cat > "${D}/bin/trivy" << 'STUB'
#!/bin/bash
# test-scan.sh's trivy, for TRIVY=trivy: records its words and does what the container does, with the paths as given
{ printf 'trivy|'; printf '%s|' "$@"; echo; } >> "${STUB_CALLS}"
source "$(dirname "$0")/trivy-emulate.sh"
STUB_HOSTDIR= trivy_emulate "$@"
STUB
chmod +x "${D}/bin/docker" "${D}/bin/trivy"
# plant <file> <image-id> [SEV,PKG,INSTALLED,FIXED,ID ...] - a trivy report with those findings (FIXED empty: no fix) on one target
plant()
{
	python3 - "$@" << 'PY'
import json, sys
f, image_id, rows = sys.argv[1], sys.argv[2], sys.argv[3:]
vulns = []
for r in rows:
    sev, pkg, inst, fixed, vid = r.split(",")
    v = {"VulnerabilityID": vid, "PkgName": pkg, "InstalledVersion": inst, "Severity": sev, "Status": "fixed" if fixed else "affected", "Title": "planted"}
    if fixed: v["FixedVersion"] = fixed
    vulns.append(v)
json.dump({"SchemaVersion": 2, "ArtifactName": "planted", "ArtifactType": "container_image", "Metadata": {"ImageID": image_id, "OS": {"Family": "ubuntu", "Name": "22.04"}},
           "Results": [{"Target": "planted (ubuntu 22.04)", "Class": "os-pkgs", "Type": "ubuntu", "Packages": [], "Vulnerabilities": vulns}]}, open(f, "w"))
PY
}
# local_env [<line>...] - the copy's .env.local: a name of its own, the sidecars off, the gate ON (CRITICAL; the shipped default is
# report only, check 8), then the lines given
local_env() { { echo "export CONTAINER=test-scan-agent"; echo "export UI_PLANE=false"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; echo "export CVE_GATE_SEVERITY=CRITICAL"; printf '%s\n' "$@"; } > "${D}/copy/.env.local"; }
# run [NAME=value...] [-- <arguments>] - ./scan.sh in the copy with the stubs on PATH and the planted socket as the Docker endpoint;
# output in ${D}/out, the calls in ${D}/calls; prints the exit status
run()
{
	local VARS=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do VARS+=("$1"); shift; done
	[ "${1:-}" == "--" ] && shift
	rm -f "${D:?}/calls"
	( cd "${D}/copy" && env PATH="${D}/bin:${PATH}" DOCKER_HOST="unix://${D}/sock" ENV_LOCAL_SETUP=false STUB_CALLS="${D}/calls" STUB_SOCK="${D}/sock" STUB_REPORT="${D}/report.json" "${VARS[@]}" ./scan.sh "$@" ) > "${D}/out" 2>&1
	echo $?
}
out() { tail -3 "${D}/out" | cut -c1-300 | tr '\n' ' '; }
calls() { cat "${D}/calls" 2> /dev/null; }
CVE="${D}/copy/cve"
SCANNER=$(sed -n 's/^export TRIVY_IMAGE=//p' "${BASE_DIR}/.env")
[ -n "${SCANNER}" ] || fail "no TRIVY_IMAGE in .env"
WALK="|image|--scanners|vuln|--timeout|30m|--list-all-pkgs|--format|json|-o|/cve/do-agent-aws_latest.trivy.json|do-agent-aws:latest|"
no_pass() { [ -e "${CVE}/$2.gate-pass.txt" ] && fail "$1: a pass record was written: $(cat "${CVE}/$2.gate-pass.txt" | tr '\n' ' ')"; }

# --- 1. a clean report: one walk, three conversions, the summary, the pass record ---
local_env
plant "${D}/report.json" sha256:planted0001 "MEDIUM,libplanted,1.0-1,1.0-2,CVE-2026-0001"
RC=$(run)
[ "${RC}" == "0" ] || fail "1: scan.sh exited ${RC} on a report with one MEDIUM (expected 0): $(out)"
[ "$(calls | grep -c -F -- "${WALK}")" == "1" ] || fail "1: expected exactly one trivy image walk of do-agent-aws:latest: $(calls | grep -F '|image|' | tr '\n' ' ')"
[ "$(calls | grep -c '|image|--scanners|')" == "1" ] || fail "1: a second walk of the image ran: $(calls | grep -F -- '--scanners' | tr '\n' ' ')"
W=$(calls | grep -F -- "${WALK}")
for WORD in "|--user|$(id -u):$(id -g)|" "|--group-add|$(stat -c %g "${D}/sock")|" "|-v|${D}/sock:/var/run/docker.sock|" "|-v|${CVE}/.trivy-cache:/cache|" "|-v|${CVE}:/cve|" "|-e|TRIVY_CACHE_DIR=/cache|" "|-e|http_proxy|-e|https_proxy|-e|no_proxy|" "|--name|test-scan-agent-trivy-" "|${SCANNER}|image|"; do
	case "${W}" in *"${WORD}"*) ;; *) fail "1: the scanner container does not carry '${WORD}': ${W}" ;; esac
done
for FMT in "table|--severity|CRITICAL,HIGH|-o|/cve/do-agent-aws_latest.trivy.txt" "cyclonedx|-o|/cve/do-agent-aws_latest.cdx.json" "spdx-json|-o|/cve/do-agent-aws_latest.spdx.json"; do
	[ "$(calls | grep -c -F -- "|${SCANNER}|convert|--format|${FMT}|/cve/do-agent-aws_latest.trivy.json|")" == "1" ] || fail "1: no conversion '${FMT}' from the report: $(calls | grep -F convert | tr '\n' ' ')"
done
calls | grep -q -F -- "|${SCANNER}|--version|" || fail "1: the scanner's version and database date were not read: $(calls | tr '\n' ' ')"
for F in trivy.json trivy.txt cdx.json spdx.json gate.txt summary.txt gate-pass.txt scan.log; do
	[ -e "${CVE}/do-agent-aws_latest.${F}" ] || fail "1: cve/do-agent-aws_latest.${F} was not written: $(ls "${CVE}")"
done
cmp -s "${CVE}/do-agent-aws_latest.trivy.json" "${D}/report.json" || fail "1: the report under cve/ is not what the scanner wrote"
grep -q '^scanner    : trivy 0.76.1 as '"${SCANNER}"' through the Docker socket | vulnerability database of 2026-10-27T01:25:30Z$' "${CVE}/do-agent-aws_latest.summary.txt" \
	|| fail "1: the summary does not name the scanner version and the database date: $(grep '^scanner' "${CVE}/do-agent-aws_latest.summary.txt")"
grep -q '^findings   : CRITICAL=0 (0 without a fix)  HIGH=0 (0 without a fix)  MEDIUM=1 (0)  LOW=0 (0)  UNKNOWN=0 (0)  TOTAL=1  targets=1$' "${CVE}/do-agent-aws_latest.summary.txt" \
	|| fail "1: the summary's counts are not the report's: $(grep '^findings' "${CVE}/do-agent-aws_latest.summary.txt")"
grep -q '^gate       : CRITICAL with a fix available = 0 -> PASS ' "${CVE}/do-agent-aws_latest.summary.txt" || fail "1: the summary's gate line is not a PASS: $(grep '^gate' "${CVE}/do-agent-aws_latest.summary.txt")"
grep -q '^image      : do-agent-aws:latest (sha256:planted0001)$' "${CVE}/do-agent-aws_latest.summary.txt" || fail "1: the summary does not name the image and its id"
grep -q '^findings   : CRITICAL=0' "${D}/out" || fail "1: the summary was not printed: $(out)"
grep -qx 'image_id=sha256:planted0001' "${CVE}/do-agent-aws_latest.gate-pass.txt" || fail "1: the pass record does not carry the image id: $(cat "${CVE}/do-agent-aws_latest.gate-pass.txt" | tr '\n' ' ')"
grep -qx 'database=2026-10-27T01:25:30Z' "${CVE}/do-agent-aws_latest.gate-pass.txt" || fail "1: the pass record does not carry the database date"
[ "$(grep -c '^scan.sh: GATE PASS - CRITICAL with a fix available=0; record ' "${D}/out")" == "1" ] || fail "1: not exactly one GATE PASS line: $(out)"
[ ! -s "${CVE}/do-agent-aws_latest.gate.txt" ] || fail "1: the gate findings file is not empty for a report with no CRITICAL: $(cat "${CVE}/do-agent-aws_latest.gate.txt")"
RC=$(run -- planted/other:1.2)
[ "${RC}" == "0" ] || fail "1: scan.sh planted/other:1.2 exited ${RC} (expected 0): $(out)"
calls | grep -q -F -- "|-o|/cve/planted_other_1.2.trivy.json|planted/other:1.2|" || fail "1: the argument image was not the one walked: $(calls | grep -F -- '--scanners' | tr '\n' ' ')"
[ -e "${CVE}/planted_other_1.2.gate-pass.txt" ] || fail "1: the argument image's files are not named after it: $(ls "${CVE}")"
echo "ok 1 - a clean report: one walk of the image as this user through the planted socket, three conversions from it, the summary with scanner, database date and counts, the pass record with the image id; ./scan.sh <image> scans that image"

# --- 2. a CRITICAL with a fix fails the gate; a stale pass record is gone ---
local_env
plant "${D}/report.json" sha256:planted0002 "CRITICAL,libplanted,1.0-1,1.0-2,CVE-2026-0002" "MEDIUM,other,2.0,,CVE-2026-0003"
printf 'image_id=stale\n' > "${CVE}/do-agent-aws_latest.gate-pass.txt"
RC=$(run)
[ "${RC}" == "4" ] || fail "2: scan.sh exited ${RC} on a fixable CRITICAL (expected 4): $(out)"
no_pass 2 do-agent-aws_latest
grep -q '^CRITICAL FIXABLE    libplanted 1.0-1 -> 1.0-2  CVE-2026-0002  planted (ubuntu 22.04)$' "${D}/out" || fail "2: the gate line does not name the package, its versions and the CVE: $(grep -F CVE-2026-0002 "${D}/out")"
grep -q '^gate       : CRITICAL with a fix available = 1 -> FAIL (1 CRITICAL finding(s) with a fix available)' "${D}/out" || fail "2: the summary's gate line is not the FAIL: $(grep '^gate' "${D}/out")"
grep -q '^scan.sh: GATE FAIL (1 CRITICAL finding(s) with a fix available): bump or remove the component that carries each .*not a .trivyignore' "${D}/out" || fail "2: no GATE FAIL line naming .trivyignore: $(out)"
# CONTROL: a scan.sh that does not remove the previous record leaves the stale pass behind - this check must catch that copy
sed '/^rm -f "${PASS:?}"/d' "${D}/copy/scan.sh" > "${D}/copy/scan-keeps-record.sh" && chmod +x "${D}/copy/scan-keeps-record.sh"
grep -q 'rm -f "${PASS:?}"' "${D}/copy/scan-keeps-record.sh" && fail "2: PLANTED CONTROL BROKEN: the copy still removes the record"
printf 'image_id=stale\n' > "${CVE}/do-agent-aws_latest.gate-pass.txt"
( cd "${D}/copy" && env PATH="${D}/bin:${PATH}" DOCKER_HOST="unix://${D}/sock" ENV_LOCAL_SETUP=false STUB_CALLS="${D}/calls" STUB_SOCK="${D}/sock" STUB_REPORT="${D}/report.json" ./scan-keeps-record.sh ) > /dev/null 2>&1
[ -e "${CVE}/do-agent-aws_latest.gate-pass.txt" ] || fail "2: PLANTED CONTROL BROKEN: the copy without the removal left no stale record"
rm -f "${CVE:?}/do-agent-aws_latest.gate-pass.txt"
echo "ok 2 - a CRITICAL with a fix: exit 4, no pass record (a stale one removed first - the control copy keeps it), the gate line names package, versions and CVE, the refusal names .trivyignore"

# --- 3. a CRITICAL without a fix: listed, not gating unless CVE_IGNORE_UNFIXED=false ---
local_env
plant "${D}/report.json" sha256:planted0003 "CRITICAL,linux-libc-planted,5.15.0-1,,CVE-2026-0004"
RC=$(run)
[ "${RC}" == "0" ] || fail "3: scan.sh exited ${RC} on an unfixed CRITICAL with CVE_IGNORE_UNFIXED=true (expected 0): $(out)"
grep -q '^findings   : CRITICAL=1 (1 without a fix)' "${D}/out" || fail "3: the summary does not say '(1 without a fix)': $(grep '^findings' "${D}/out")"
grep -q '^CRITICAL no-fix     linux-libc-planted 5.15.0-1 no fix  CVE-2026-0004  planted (ubuntu 22.04)$' "${D}/out" || fail "3: the unfixed CRITICAL is not listed and labelled: $(grep -F CVE-2026-0004 "${D}/out")"
grep -qx 'critical_without_fix=1' "${CVE}/do-agent-aws_latest.gate-pass.txt" || fail "3: the pass record does not carry the without-a-fix count"
local_env 'export CVE_IGNORE_UNFIXED=false'
RC=$(run)
[ "${RC}" == "4" ] || fail "3: scan.sh exited ${RC} on an unfixed CRITICAL with CVE_IGNORE_UNFIXED=false (expected 4): $(out)"
no_pass 3 do-agent-aws_latest
grep -q '^gate       : CRITICAL = 1 -> FAIL (1 CRITICAL finding(s))' "${D}/out" || fail "3: the summary's gate line is not the FAIL without the fix clause: $(grep '^gate' "${D}/out")"
echo "ok 3 - a CRITICAL without a fix: exit 0 and '(1 without a fix)' in the summary, listed as no-fix; CVE_IGNORE_UNFIXED=false: exit 4"

# --- 4. no report, an empty one, a non-report, a scanner that failed: exit 3, never a pass ---
local_env
for CASE in none empty garbage rc; do
	case "${CASE}" in
		none) RC=$(run STUB_REPORT=none) ;;
		empty) : > "${D}/empty.json"; RC=$(run STUB_REPORT="${D}/empty.json") ;;
		garbage) printf 'not a report\n' > "${D}/garbage.json"; RC=$(run STUB_REPORT="${D}/garbage.json") ;;
		rc) plant "${D}/report.json" sha256:planted0004; RC=$(run STUB_SCAN_RC=1) ;;
	esac
	[ "${RC}" == "3" ] || fail "4: scan.sh exited ${RC} when the scanner wrote ${CASE} (expected 3): $(out)"
	no_pass 4 do-agent-aws_latest
	grep -q '^scan.sh: FAIL - ' "${D}/out" || fail "4: no FAIL line when the scanner wrote ${CASE}: $(out)"
	grep -q 'GATE PASS' "${D}/out" && fail "4: a GATE PASS with a report that is ${CASE}"
done
grep -q 'refusing to claim a clean image' "${D}/out" || fail "4: the FAIL line does not say it refuses to claim a clean image: $(out)"
echo "ok 4 - no report, an empty one, one that is not a trivy report, a scanner exiting non-zero: exit 3 with a FAIL line, no pass record"

# --- 5. the HIGH ceiling ---
local_env
plant "${D}/report.json" sha256:planted0005 "HIGH,libhigh,1.0,1.1,CVE-2026-0005"
local_env 'export CVE_MAX_HIGH=0'
RC=$(run)
[ "${RC}" == "5" ] || fail "5: scan.sh exited ${RC} with CVE_MAX_HIGH=0 and one fixable HIGH (expected 5): $(out)"
no_pass 5 do-agent-aws_latest
grep -q '^gate       : CRITICAL with a fix available = 0 -> FAIL (HIGH 1 exceeds CVE_MAX_HIGH=0)' "${D}/out" || fail "5: the summary's gate line is not the HIGH ceiling FAIL: $(grep '^gate' "${D}/out")"
local_env
RC=$(run)
[ "${RC}" == "0" ] || fail "5: scan.sh exited ${RC} with CVE_MAX_HIGH empty and one HIGH (expected 0): $(out)"
grep -qx 'max_high=<not gated>' "${CVE}/do-agent-aws_latest.gate-pass.txt" || fail "5: the pass record does not say HIGH is not gated"
echo "ok 5 - CVE_MAX_HIGH=0 with one fixable HIGH: exit 5 and no record; the ceiling empty: exit 0, HIGH reported"

# --- 6. the scanner image not pullable, the image not present: exit 3 before any walk ---
local_env
plant "${D}/report.json" sha256:planted0006
RC=$(run STUB_TRIVY_RC=1)
[ "${RC}" == "3" ] || fail "6: scan.sh exited ${RC} when the scanner image is absent and the pull fails (expected 3): $(out)"
grep -q "^scan.sh: cannot pull the scanner image ${SCANNER} (TRIVY_IMAGE): Error response from daemon: planted: pull access denied" "${D}/out" || fail "6: the pull failure does not carry docker's words: $(out)"
calls | grep -q -F -- '|image|--scanners|' && fail "6: a walk ran although the scanner image could not be pulled"
RC=$(run STUB_NO_IMAGE=1)
[ "${RC}" == "3" ] || fail "6: scan.sh exited ${RC} when the image to scan is not present (expected 3): $(out)"
grep -q '^scan.sh: the image do-agent-aws:latest is not present on this host' "${D}/out" || fail "6: the missing image is not named: $(out)"
calls | grep -q -F -- '|image|--scanners|' && fail "6: a walk ran although the image is not present"
no_pass 6 do-agent-aws_latest
echo "ok 6 - a scanner image that cannot be pulled, an image that is not present: exit 3 with the reason, before any walk"

# --- 7. TRIVY=<cli>: the host trivy, no container ---
local_env 'export TRIVY=trivy'
plant "${D}/report.json" sha256:planted0007 "LOW,liblow,1.0,,CVE-2026-0007"
RC=$(run)
[ "${RC}" == "0" ] || fail "7: scan.sh exited ${RC} with TRIVY=trivy (expected 0): $(out)"
calls | grep -q -F -- "trivy|image|--scanners|vuln|--timeout|30m|--list-all-pkgs|--format|json|-o|./cve/do-agent-aws_latest.trivy.json|do-agent-aws:latest|" || fail "7: the host trivy did not walk the image with cve/ paths: $(calls | grep -F -- '--scanners' | tr '\n' ' ')"
[ "$(calls | grep -c '^trivy|convert|')" == "3" ] || fail "7: expected three conversions by the host trivy: $(calls | grep convert | tr '\n' ' ')"
calls | grep -q '^docker|container|run|' && fail "7: a container ran although TRIVY=trivy: $(calls | grep container | tr '\n' ' ')"
grep -q '^scanner    : trivy 0.76.1 as trivy of this host | vulnerability database of 2026-10-27T01:25:30Z$' "${CVE}/do-agent-aws_latest.summary.txt" || fail "7: the summary does not name the host trivy: $(grep '^scanner' "${CVE}/do-agent-aws_latest.summary.txt")"
grep -q '^findings   : CRITICAL=0 (0 without a fix)  HIGH=0 (0 without a fix)  MEDIUM=0 (0)  LOW=1 (1)' "${CVE}/do-agent-aws_latest.summary.txt" || fail "7: the summary's counts are not the report's: $(grep '^findings' "${CVE}/do-agent-aws_latest.summary.txt")"
echo "ok 7 - TRIVY=trivy: the host trivy walks and converts with cve/ paths, no container runs, the summary says so"

# --- 8. the shipped default: the CRITICAL gate; report only when set empty ---
grep -q '^export CVE_GATE_SEVERITY=CRITICAL$' "${BASE_DIR}/.env" || fail "8: .env does not ship CVE_GATE_SEVERITY=CRITICAL: $(grep -n '^export CVE_GATE_SEVERITY=' "${BASE_DIR}/.env")"
{ echo "export CONTAINER=test-scan-agent"; echo "export UI_PLANE=false"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; } > "${D}/copy/.env.local"
plant "${D}/report.json" sha256:planted0008 "CRITICAL,libplanted,1.0-1,1.0-2,CVE-2026-0008" "HIGH,libhigh,1.0,1.1,CVE-2026-0009"
RC=$(run)
[ "${RC}" == "4" ] || fail "8: scan.sh exited ${RC} with the shipped gate and a fixable CRITICAL (expected 4): $(out)"
no_pass 8 do-agent-aws_latest
{ echo "export CONTAINER=test-scan-agent"; echo "export UI_PLANE=false"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; echo "export CVE_GATE_SEVERITY="; } > "${D}/copy/.env.local"
RC=$(run)
[ "${RC}" == "0" ] || fail "8: scan.sh exited ${RC} with the gate off and a fixable CRITICAL (expected 0, report only): $(out)"
no_pass 8 do-agent-aws_latest
grep -q '^gate       : off -> REPORT ONLY (no gate: CVE_GATE_SEVERITY is empty; CRITICAL fails on a CRITICAL with a fix available)' "${D}/out" || fail "8: the summary's gate line does not read off / REPORT ONLY: $(grep '^gate' "${D}/out")"
grep -q '^CRITICAL FIXABLE    libplanted 1.0-1 -> 1.0-2  CVE-2026-0008  planted (ubuntu 22.04)$' "${D}/out" || fail "8: the CRITICAL is not listed with the gate off: $(grep -F CVE-2026-0008 "${D}/out")"
grep -q '^findings   : CRITICAL=1 (0 without a fix)  HIGH=1 (0 without a fix)' "${D}/out" || fail "8: the counts are not printed with the gate off: $(grep '^findings' "${D}/out")"
grep -q '^scan.sh: REPORT ONLY (no gate: CVE_GATE_SEVERITY is empty' "${D}/out" || fail "8: no REPORT ONLY line: $(out)"
grep -q 'GATE PASS\|GATE FAIL' "${D}/out" && fail "8: a gate verdict was printed although the gate is off: $(grep 'GATE' "${D}/out")"
{ echo "export CONTAINER=test-scan-agent"; echo "export UI_PLANE=false"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; echo "export CVE_GATE_SEVERITY="; echo "export CVE_MAX_HIGH=0"; } > "${D}/copy/.env.local"
RC=$(run)
[ "${RC}" == "5" ] || fail "8: scan.sh exited ${RC} with the gate off and CVE_MAX_HIGH=0 over one HIGH (expected 5): $(out)"
no_pass 8 do-agent-aws_latest
{ echo "export CONTAINER=test-scan-agent"; echo "export UI_PLANE=false"; echo "export UI_VIBE_KANBAN=false"; echo "export SPOKE_DOCKER=false"; echo "export CVE_GATE_SEVERITY="; echo "export CVE_MAX_HIGH=50"; } > "${D}/copy/.env.local"
RC=$(run)
[ "${RC}" == "0" ] || fail "8: scan.sh exited ${RC} with the gate off and CVE_MAX_HIGH=50 over one HIGH (expected 0): $(out)"
no_pass 8 do-agent-aws_latest
grep -q '^gate       : off -> REPORT ONLY (no gate: CVE_GATE_SEVERITY is empty; CRITICAL fails on a CRITICAL with a fix available; HIGH 1 <= CVE_MAX_HIGH=50)' "${D}/out" || fail "8: the gate line does not say the ceiling held with the gate off: $(grep '^gate' "${D}/out")"
echo "ok 8 - the shipped default (CVE_GATE_SEVERITY=CRITICAL) fails on a fixable CRITICAL (exit 4); set empty it is report only: exit 0, no pass record, the gate line reads off / REPORT ONLY, the CRITICAL listed; CVE_MAX_HIGH gates on its own and within the cap still leaves no record"

# --- 9. before any walk: docker unusable, a tcp endpoint, a CVE_MAX_HIGH that is not a number ---
local_env
plant "${D}/report.json" sha256:planted0009 "MEDIUM,libplanted,1.0-1,1.0-2,CVE-2026-0010"
RC=$(run STUB_INFO_RC=1)
[ "${RC}" == "3" ] || fail "9: scan.sh exited ${RC} when docker info fails (expected 3): $(out)"
grep -q '^scan.sh: docker is not usable by ' "${D}/out" || fail "9: no line naming docker as unusable: $(out)"
calls | grep -q -F -- '|image|--scanners|' && fail "9: a walk ran although docker is not usable"
RC=$(run DOCKER_HOST=tcp://planted:2375)
[ "${RC}" == "3" ] || fail "9: scan.sh exited ${RC} with DOCKER_HOST=tcp:// (expected 3): $(out)"
grep -q '^scan.sh: the Docker endpoint is not a unix socket (DOCKER_HOST=tcp://planted:2375): .*in .env.local, TRIVY=<trivy command>' "${D}/out" || fail "9: the tcp endpoint is not named with the .env.local remedy: $(out)"
calls | grep -q -F -- '|image|--scanners|' && fail "9: a walk ran although the endpoint is tcp"
local_env 'export CVE_MAX_HIGH=none'
RC=$(run)
[ "${RC}" == "3" ] || fail "9: scan.sh exited ${RC} with CVE_MAX_HIGH=none (expected 3): $(out)"
grep -q "^scan.sh: CVE_MAX_HIGH='none' is not a number" "${D}/out" || fail "9: the bad ceiling is not named: $(out)"
calls | grep -q -F -- '|image|--scanners|' && fail "9: a walk ran although CVE_MAX_HIGH is not a number"
no_pass 9 do-agent-aws_latest
echo "ok 9 - docker unusable, a tcp Docker endpoint, a CVE_MAX_HIGH that is not a number: exit 3 with the reason, before any walk, no record"

# --- 10. conversions and the provenance must succeed; the previous run's files go first ---
local_env
plant "${D}/report.json" sha256:planted0010 "MEDIUM,libplanted,1.0-1,1.0-2,CVE-2026-0011"
RC=$(run)
[ "${RC}" == "0" ] || fail "10: scan.sh exited ${RC} on the clean run before the failures (expected 0): $(out)"
for CASE in "STUB_CONVERT_RC=1" "STUB_CONVERT_EMPTY=1" "STUB_VERSION_RC=1"; do
	RC=$(run "${CASE}")
	[ "${RC}" == "3" ] || fail "10: scan.sh exited ${RC} with ${CASE} (expected 3): $(out)"
	no_pass 10 do-agent-aws_latest
	grep -q '^scan.sh: FAIL - ' "${D}/out" || fail "10: no FAIL line with ${CASE}: $(out)"
	grep -q 'GATE PASS' "${D}/out" && fail "10: a GATE PASS with ${CASE}"
	case "${CASE}" in
		STUB_CONVERT_RC=1) grep -q '^scan.sh: FAIL - trivy convert --format table --severity CRITICAL,HIGH failed for ' "${D}/out" || fail "10: the failed conversion is not named: $(out)" ;;
		STUB_CONVERT_EMPTY=1) grep -q '^scan.sh: FAIL - trivy convert --format table --severity CRITICAL,HIGH wrote nothing to ' "${D}/out" || fail "10: the empty conversion is not named: $(out)" ;;
		STUB_VERSION_RC=1) grep -q "^scan.sh: FAIL - the scanner's version and database date could not be read" "${D}/out" || fail "10: the unreadable provenance is not named: $(out)" ;;
	esac
done
# the previous run's files go first: planted stale ones, then a run that fails before anything is written (no report)
for F in trivy.txt cdx.json spdx.json gate.txt summary.txt; do printf 'STALE\n' > "${CVE}/do-agent-aws_latest.${F}"; done
RC=$(run STUB_REPORT=none)
[ "${RC}" == "3" ] || fail "10: scan.sh exited ${RC} with no report (expected 3): $(out)"
for F in trivy.txt cdx.json spdx.json gate.txt summary.txt; do [ -e "${CVE}/do-agent-aws_latest.${F}" ] && fail "10: the previous run's ${F} survived a run that failed before writing it"; done
echo "ok 10 - a failed or empty conversion and an unreadable scanner version: exit 3 with the reason, no record; the previous run's files are removed before the walk"

# --- 11. two gate severities, written loosely ---
local_env 'export CVE_GATE_SEVERITY="CRITICAL, high"'
plant "${D}/report.json" sha256:planted0011 "HIGH,libhigh,1.0,1.1,CVE-2026-0012"
RC=$(run)
[ "${RC}" == "4" ] || fail "11: scan.sh exited ${RC} with CVE_GATE_SEVERITY='CRITICAL, high' and one fixable HIGH (expected 4): $(out)"
no_pass 11 do-agent-aws_latest
calls | grep -q -F -- '|convert|--format|table|--severity|CRITICAL,HIGH|-o|' || fail "11: the table's severities are not CRITICAL,HIGH once: $(calls | grep -F -- '--severity' | tr '\n' ' ')"
grep -q '^HIGH     FIXABLE    libhigh 1.0 -> 1.1  CVE-2026-0012  planted (ubuntu 22.04)$' "${D}/out" || fail "11: the HIGH is not listed as a gate finding: $(grep -F CVE-2026-0012 "${D}/out")"
grep -q '^gate       : CRITICAL, high with a fix available = 1 -> FAIL' "${D}/out" || fail "11: the gate line does not name both severities: $(grep '^gate' "${D}/out")"
echo "ok 11 - two gate severities written loosely: a fixable HIGH fails the gate, the table's severities are normalized, the gate line names both"

echo "Test-scan succeeded"
