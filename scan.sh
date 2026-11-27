#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The CVE scan of the harness image (docs/manual/supply-chain.md "CVE scan"): the end of ./build.sh, and on its own against the current image.
#   ./scan.sh            scans ${REGISTRY}${IMAGE}${TAG} as .env (and your .env.local) names it
#   ./scan.sh <image>    scans that image
# trivy (github.com/aquasecurity/trivy) walks the image once (`trivy image --scanners vuln`, every package listed) and writes
# under CVE_DIR (./cve, gitignored: the counts move with trivy's vulnerability database from one day to the next):
#   <image>.trivy.json      the full report - every severity, every package
#   <image>.trivy.txt       the table of the CVE_GATE_SEVERITY and HIGH findings (trivy convert, from the json: no second walk)
#   <image>.cdx.json        the image's bill of materials as CycloneDX; <image>.spdx.json the same as SPDX (converted the same way)
#   <image>.gate.txt        one line per finding of the gate severity (CRITICAL when the gate is off): its fix status, the package,
#                           the CVE, the target
#   <image>.summary.txt     the one-screen summary printed at the end: scanner and database date, image id, the counts with their
#                           without-a-fix split, the gate verdict, the knobs, the wall time
#   <image>.gate-pass.txt   the verdict as a FILE: written ONLY when the gate passed, removed at the start of every run, so a previous
#                           run's pass never speaks for this one (the image id in it is the one that passed)
#   .trivy-cache/           trivy's vulnerability database; trivy refreshes it when it is a day old (remove it for a fresh one)
# <image> is the image reference with / and : replaced by _ (do-agent-aws_latest). The scanner runs as the pinned public image
# TRIVY_IMAGE through the Docker socket, so a build host needs nothing beyond docker (the way the docker spoke's images run); TRIVY=<cli>
# in .env.local runs a trivy of this host instead (the knobs are settings of .env, set in .env.local; CVE_SCAN alone is also read from
# the environment). A run removes the previous run's files for the image first, so what is left after a failure is this run's.
#
# The gate: a finding of CVE_GATE_SEVERITY (CRITICAL) that HAS a fixed version fails the scan; one without a fix (nothing to install
# today) is counted, listed and labelled, and does not (CVE_IGNORE_UNFIXED=true; false gates on every finding of that severity).
# CVE_MAX_HIGH, when set, caps the HIGH findings counted the same way (exit 5 when exceeded, with the gate on or off). CVE_GATE_SEVERITY
# EMPTY (the shipped default, .env says why) is report only: the same report, table and summary, the CRITICAL findings listed, exit 0
# and no pass record - the record means a gate on a severity passed, so none is written while there is none. A failure is fixed by
# bumping or removing the component that carries the CVE (Container-Root/setup/install-*.sh, harden.sh), never with a .trivyignore:
# an ignore file makes the count untrue. No report, an empty or unreadable one, a scanner that cannot run: a FAILURE with its
# reason, never a pass.
#
# Exit status: 0 the gate passed | 3 the scan could not be evaluated (docker or trivy unusable, the image not present, the scanner image
#              not pullable, no report or an unreadable one, a conversion that failed) | 4 the gate failed on CVE_GATE_SEVERITY
#              | 5 CVE_MAX_HIGH exceeded

[ -x ./env-local.sh ] && ./env-local.sh
source .env
# preflight_docker_socket: the unix socket of the current Docker endpoint (preflight.sh; build.sh's preflight warns about it)
source ./preflight.sh

SCAN_IMAGE=${1:-${REGISTRY}${IMAGE}${TAG}}
[ -n "${SCAN_IMAGE}" ] || { echo "scan.sh: no image to scan (IMAGE is empty in .env and none was given)" >&2; exit 3; }
CVE_DIR=${CVE_DIR:-./cve}
mkdir -p "${CVE_DIR}" || { echo "scan.sh: cannot make ${CVE_DIR} (CVE_DIR)" >&2; exit 3; }
SAFE=$(echo "${SCAN_IMAGE}" | tr '/:' '__')
REPORT=${CVE_DIR}/${SAFE}.trivy.json
TABLE=${CVE_DIR}/${SAFE}.trivy.txt
CDX=${CVE_DIR}/${SAFE}.cdx.json
SPDX=${CVE_DIR}/${SAFE}.spdx.json
GATE=${CVE_DIR}/${SAFE}.gate.txt
SUMMARY=${CVE_DIR}/${SAFE}.summary.txt
PASS=${CVE_DIR}/${SAFE}.gate-pass.txt
LOG=${CVE_DIR}/${SAFE}.scan.log
rm -f "${PASS:?}" "${TABLE:?}" "${CDX:?}" "${SPDX:?}" "${GATE:?}" "${SUMMARY:?}"   # a previous run's pass, and its files, never speak for this one
case "${CVE_MAX_HIGH}" in
	""|*[!0-9]*) [ -z "${CVE_MAX_HIGH}" ] || { echo "scan.sh: CVE_MAX_HIGH='${CVE_MAX_HIGH}' is not a number (a HIGH ceiling, or empty for none)" >&2; exit 3; } ;;
esac
T0=$(date +%s)

# The scanner: TRIVY=docker runs TRIVY_IMAGE as a container, as the invoking user (so cve/ stays this user's files) with the socket's
# group added (so trivy reads the image through the daemon), its database cache on CVE_DIR/.trivy-cache and CVE_DIR mounted at /cve
# for its outputs; .env's proxy settings reach it for the database download. Any other value is the trivy command of this host.
if [ "${TRIVY:-docker}" == "docker" ]; then
	if ! docker info > /dev/null 2>&1; then
		echo "scan.sh: docker is not usable by $(id -un) - the scanner runs as a container through the Docker socket (TRIVY=docker); README 'Prerequisites'" >&2
		exit 3
	fi
	SOCK=$(preflight_docker_socket)
	if [ -z "${SOCK}" ]; then
		echo "scan.sh: the Docker endpoint is not a unix socket (DOCKER_HOST=${DOCKER_HOST:-$(docker context inspect --format '{{(index .Endpoints "docker").Host}}' 2> /dev/null)}): trivy in a container cannot reach the image through it - in .env.local, TRIVY=<trivy command> for a host install, or CVE_SCAN=false (docs/manual/supply-chain.md \"CVE scan\")" >&2
		exit 3
	fi
	if [ ! -S "${SOCK}" ] || [ ! -w "${SOCK}" ]; then
		echo "scan.sh: the Docker socket ${SOCK} is not there or not writable by $(id -un): trivy in a container reads the image through it - in .env.local, TRIVY=<trivy command> for a host install, or CVE_SCAN=false (docs/manual/supply-chain.md \"CVE scan\")" >&2
		exit 3
	fi
	CVE_DIR_ABS=$(cd "${CVE_DIR}" && pwd)
	mkdir -p "${CVE_DIR_ABS}/.trivy-cache"
	if ! docker image inspect "${TRIVY_IMAGE}" > /dev/null 2>&1; then
		PULL_ERR=$(docker image pull -q "${TRIVY_IMAGE}" 2>&1 > /dev/null) || { echo "scan.sh: cannot pull the scanner image ${TRIVY_IMAGE} (TRIVY_IMAGE): ${PULL_ERR##*$'\n'}" >&2; exit 3; }
	fi
	O=/cve
	trivy_run()
	{
		docker container run --rm --name "${CONTAINER:-scan}-trivy-$$" --user "$(id -u):$(id -g)" --group-add "$(stat -c %g "${SOCK}")" \
			-e TRIVY_CACHE_DIR=/cache -e HOME=/tmp -e http_proxy -e https_proxy -e no_proxy \
			-v "${SOCK}:/var/run/docker.sock" -v "${CVE_DIR_ABS}/.trivy-cache:/cache" -v "${CVE_DIR_ABS}:/cve" "${TRIVY_IMAGE}" "$@"
	}
	SCANNER_HOW="${TRIVY_IMAGE} through the Docker socket"
else
	command -v "${TRIVY}" > /dev/null 2>&1 || { echo "scan.sh: ${TRIVY} is not on PATH (TRIVY in .env.local names the trivy command; TRIVY=docker, the default, runs the pinned image instead)" >&2; exit 3; }
	O=${CVE_DIR}
	trivy_run() { "${TRIVY}" "$@"; }
	SCANNER_HOW="${TRIVY} of this host"
fi
if command -v docker > /dev/null 2>&1 && ! docker image inspect "${SCAN_IMAGE}" > /dev/null 2>&1; then
	echo "scan.sh: the image ${SCAN_IMAGE} is not present on this host (./build.sh builds it; ./scan.sh <image> scans another)" >&2
	exit 3
fi

# One walk of the image: the full json report, every package in it (the bills of materials below are converted from it)
echo "scan.sh: trivy image --scanners vuln ${SCAN_IMAGE} (${SCANNER_HOW}; timeout ${TRIVY_TIMEOUT:-30m}) ..."
rm -f "${REPORT:?}"
trivy_run image --scanners vuln --timeout "${TRIVY_TIMEOUT:-30m}" --list-all-pkgs --format json -o "${O}/${SAFE}.trivy.json" "${SCAN_IMAGE}" 2>&1 | tee "${LOG}"
RC=${PIPESTATUS[0]}
# FAIL-LOUD: a scan that exited non-zero, or left no report, is a failure with trivy's last words - never a silent pass
if [ "${RC}" != "0" ] || [ ! -s "${REPORT}" ]; then
	echo "scan.sh: FAIL - trivy exited ${RC} and ${REPORT} is $([ -e "${REPORT}" ] && echo empty || echo missing) (its last words: $(tail -1 "${LOG}" 2> /dev/null | cut -c1-200)); refusing to claim a clean image" >&2
	exit 3
fi

# The counts, from the json by python (standard library; it exits non-zero on anything it cannot read, so the gate fails loud): per
# severity the findings and those without a fixed version; the gate count (CVE_GATE_SEVERITY, without-a-fix ones left out when
# CVE_IGNORE_UNFIXED=true; 0 when the gate is off); the HIGH count the same way for CVE_MAX_HIGH; the image id and the number of
# targets. The listed findings (the gate's severities, CRITICAL when the gate is off) go to ${GATE}, one line each, fixed ones first.
LIST_SEV=${CVE_GATE_SEVERITY:-CRITICAL}
COUNTS=$(python3 - "${REPORT}" "${GATE}" "${CVE_GATE_SEVERITY}" "${LIST_SEV}" "${CVE_IGNORE_UNFIXED:-true}" << 'PY'
import json, sys, collections
report, gate_file, gate_sev, list_sev, ignore_unfixed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "true"
try:
    d = json.load(open(report))
    results = d.get("Results") or []   # absent when the image has no target at all
    if not isinstance(results, list) or not isinstance(d.get("Metadata"), dict):
        raise ValueError("no Metadata, or Results is not a list, in the report")
except Exception as e:
    sys.stderr.write("the trivy report cannot be read: %s\n" % e); sys.exit(1)
gate_sevs = {s.strip().upper() for s in gate_sev.split(",") if s.strip()}
list_sevs = {s.strip().upper() for s in list_sev.split(",") if s.strip()}
total = collections.Counter(); unfixed = collections.Counter(); rows = []
for r in results:
    for v in r.get("Vulnerabilities") or []:
        sev = (v.get("Severity") or "UNKNOWN").upper(); fixed = bool(v.get("FixedVersion"))
        total[sev] += 1
        if not fixed: unfixed[sev] += 1
        if sev in list_sevs:
            rows.append((0 if fixed else 1, sev, v.get("PkgName") or "?", v.get("InstalledVersion") or "?",
                         ("-> " + v["FixedVersion"]) if fixed else "no fix", v.get("VulnerabilityID") or "?", r.get("Target") or "?"))
rows.sort()
with open(gate_file, "w") as f:
    for row in rows:
        f.write("%-8s %-10s %s %s %s  %s  %s\n" % (row[1], "FIXABLE" if row[0] == 0 else "no-fix", row[2], row[3], row[4], row[5], row[6]))
def gate(sevs):
    return sum(total[s] - (unfixed[s] if ignore_unfixed else 0) for s in sevs)
print(" ".join(str(x) for x in [d["Metadata"].get("ImageID") or "?", total["CRITICAL"], unfixed["CRITICAL"], total["HIGH"], unfixed["HIGH"],
      total["MEDIUM"], unfixed["MEDIUM"], total["LOW"], unfixed["LOW"], total["UNKNOWN"], unfixed["UNKNOWN"], sum(total.values()),
      gate(gate_sevs), gate({"HIGH"}), len(results)]))
PY
) || { echo "scan.sh: FAIL - ${REPORT} could not be read as a trivy report (the line above says why); refusing to claim a clean image" >&2; exit 3; }
read -r IMAGE_ID CRIT CRIT_U HIGH HIGH_U MED MED_U LOW LOW_U UNK UNK_U TOTAL GATE_COUNT GATE_HIGH TARGETS <<< "${COUNTS}"

# The table and the two bills of materials, converted from the report (no second walk of the image); a conversion that fails
# fails the scan: the artifacts are what the scan is for
TABLE_SEV=$(echo "CRITICAL,HIGH,${CVE_GATE_SEVERITY}" | tr ',' '\n' | tr -d ' \t' | tr 'a-z' 'A-Z' | awk 'NF && !seen[$0]++' | paste -sd,)
for CONV in "table --severity ${TABLE_SEV}:${SAFE}.trivy.txt" "cyclonedx:${SAFE}.cdx.json" "spdx-json:${SAFE}.spdx.json"; do
	trivy_run convert --format ${CONV%%:*} -o "${O}/${CONV#*:}" "${O}/${SAFE}.trivy.json" > /dev/null 2>&1 \
		|| { echo "scan.sh: FAIL - trivy convert --format ${CONV%%:*} failed for ${REPORT}" >&2; exit 3; }
	[ -s "${CVE_DIR}/${CONV#*:}" ] || { echo "scan.sh: FAIL - trivy convert --format ${CONV%%:*} wrote nothing to ${CVE_DIR}/${CONV#*:}" >&2; exit 3; }
done

# Scanner and database provenance, read AFTER the scan from the cache trivy matched against (the counts depend on the database
# as much as on the image: a day's database can turn 0 CRITICAL into 3 on the same image)
TRIVY_VER=$(trivy_run --version 2> /dev/null | awk '/^Version:/ && !v {v=$2} /UpdatedAt:/ && !d {d=$2 "T" substr($3,1,8) "Z"} END {print (v ? v : "?"), (d ? d : "?")}')
read -r TRIVY_VERSION TRIVY_DB <<< "${TRIVY_VER}"
if [ "${TRIVY_VERSION:-?}" == "?" ] || [ "${TRIVY_DB:-?}" == "?" ]; then
	echo "scan.sh: FAIL - the scanner's version and database date could not be read (trivy --version: '${TRIVY_VER}'); a report without its provenance is not a verdict" >&2
	exit 3
fi
T1=$(date +%s)

# The verdict: the gate off (CVE_GATE_SEVERITY empty) is report only - unless CVE_MAX_HIGH, a gate of its own, is set and exceeded
FIX_CLAUSE=$([ "${CVE_IGNORE_UNFIXED:-true}" == "true" ] && echo " with a fix available")
if [ "${GATE_COUNT}" -gt 0 ]; then
	VERDICT="FAIL (${GATE_COUNT} ${CVE_GATE_SEVERITY} finding(s)${FIX_CLAUSE})"
elif [ -n "${CVE_MAX_HIGH}" ] && [ "${GATE_HIGH}" -gt "${CVE_MAX_HIGH}" ]; then
	VERDICT="FAIL (HIGH ${GATE_HIGH} exceeds CVE_MAX_HIGH=${CVE_MAX_HIGH})"
elif [ -z "${CVE_GATE_SEVERITY}" ]; then
	VERDICT="REPORT ONLY (no gate: CVE_GATE_SEVERITY is empty; CRITICAL fails on a CRITICAL${FIX_CLAUSE}${CVE_MAX_HIGH:+; HIGH ${GATE_HIGH} <= CVE_MAX_HIGH=${CVE_MAX_HIGH}})"
else
	VERDICT="PASS"
fi
{
echo "=============================== CVE SCAN SUMMARY ==============================="
echo "image      : ${SCAN_IMAGE} (${IMAGE_ID})"
echo "scanner    : trivy ${TRIVY_VERSION} as ${SCANNER_HOW} | vulnerability database of ${TRIVY_DB}"
echo "report     : ${REPORT} (every finding) | ${TABLE} (${TABLE_SEV} table) | ${GATE} (the gate's findings)"
echo "sbom       : ${CDX} (CycloneDX) | ${SPDX} (SPDX)"
echo "findings   : CRITICAL=${CRIT} (${CRIT_U} without a fix)  HIGH=${HIGH} (${HIGH_U} without a fix)  MEDIUM=${MED} (${MED_U})  LOW=${LOW} (${LOW_U})  UNKNOWN=${UNK} (${UNK_U})  TOTAL=${TOTAL}  targets=${TARGETS}"
echo "gate       : ${CVE_GATE_SEVERITY:-off}$([ -n "${CVE_GATE_SEVERITY}" ] && echo "${FIX_CLAUSE} = ${GATE_COUNT}") -> ${VERDICT}   (CVE_IGNORE_UNFIXED=${CVE_IGNORE_UNFIXED:-true}; CVE_MAX_HIGH=${CVE_MAX_HIGH:-<not gated>}, HIGH counted the same way: ${GATE_HIGH})"
echo "wall time  : $((T1 - T0)) s"
echo "==============================================================================="
} | tee "${SUMMARY}"
# the gate's findings into the log: a failing build names its CVEs without opening a file
if [ -s "${GATE}" ]; then
	echo "---- ${LIST_SEV} findings (fixed ones first; the full ${TABLE_SEV} table is ${TABLE}) ----"
	cat "${GATE}"
	echo "----"
fi
case "${VERDICT}" in
	"FAIL (HIGH"*)
		echo "scan.sh: GATE ${VERDICT}: bump or remove the components that carry them (Container-Root/setup/install-*.sh, harden.sh), not a .trivyignore - an ignore file makes the count untrue" >&2
		exit 5 ;;
	FAIL*)
		echo "scan.sh: GATE ${VERDICT}: bump or remove the component that carries each (Container-Root/setup/install-*.sh, harden.sh), not a .trivyignore - an ignore file makes the count untrue" >&2
		exit 4 ;;
	"REPORT ONLY"*)
		echo "scan.sh: ${VERDICT}; no pass record (docs/manual/supply-chain.md \"CVE scan\")"
		exit 0 ;;
esac
# the pass record, one key=value a line; the image id is the one this verdict is about
{
	echo "image=${SCAN_IMAGE}"
	echo "image_id=${IMAGE_ID}"
	echo "critical=${CRIT}"; echo "critical_without_fix=${CRIT_U}"
	echo "high=${HIGH}"; echo "high_without_fix=${HIGH_U}"
	echo "total=${TOTAL}"
	echo "gate_severity=${CVE_GATE_SEVERITY:-<none>}"; echo "ignore_unfixed=${CVE_IGNORE_UNFIXED:-true}"; echo "max_high=${CVE_MAX_HIGH:-<not gated>}"
	echo "scanner=trivy ${TRIVY_VERSION} as ${SCANNER_HOW}"; echo "database=${TRIVY_DB}"
	echo "passed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${PASS}"
echo "scan.sh: GATE PASS - ${CVE_GATE_SEVERITY:+${CVE_GATE_SEVERITY}${FIX_CLAUSE}=${GATE_COUNT}}${CVE_MAX_HIGH:+${CVE_GATE_SEVERITY:+, }HIGH ${GATE_HIGH} <= ${CVE_MAX_HIGH}}; record ${PASS}"
