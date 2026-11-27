#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the software bill of materials (docs/manual/supply-chain.md "Software bill of materials": /sbom.sh and /agent/sbom.py, the
# registry /setup/third-party.txt, the Dockerfile's last step writing /SBOM.txt). Fully OFFLINE; its files under
# /tmp/sbom-smoke; nothing under /wd is touched. Each check FAILS if the property it proves is removed:
#   1. /SBOM.txt exists and is not empty; its first line names the image (the first word of /version.txt) and the build stamp
#      (AGENT_BUILD); the four sections are there, in order, each once
#   2. every body line is `<name> <version> - <license>`: a name and a version without spaces, the ` - ` separator, a license
#      that is not blank; an UNKNOWN license carries its reason in parentheses
#   3. coverage, each source enumerated here on its own (dpkg-query, find and the metadata files - not through sbom.py): every
#      installed dpkg package, every node_modules/<name>/package.json that names a package (the caches aside), every
#      *.dist-info and *.egg-info (the caches aside) and every component line of the registry is in its section exactly once,
#      and no registry component reads version `unknown` (a probe that gave nothing); CONTROL: a dist-info planted under a
#      temporary prefix is reported missing by this same check against the shipped file, and found in a file regenerated with
#      that prefix walked (--also)
#   4. every /setup/install-*.sh and harden.sh is accounted for: its text installs through apt, npm, pip or uv, or a registry
#      line names it as the installer (the installer field's first word), or a none: line says it brings nothing - and a none: line never names an installer whose
#      text does install; every installer a registry line names exists (/setup/<install-*.sh>, or the /opt tree); CONTROL: a
#      registry copy with the aws-cli line removed leaves install-aws.sh unaccounted
#   5. determinism: `/sbom.sh <file>` regenerates a body (everything after the header's first empty line) byte-identical to
#      the shipped file's
#   6. the header's counts are the body's (per section, the total and UNKNOWN), and every UNKNOWN line names a component on the
#      allow-list below - a new component without a license turns this red until its license is found (the registry's
#      npm:/python:/dpkg: lines name a license where the metadata has none) or the name is allowed on purpose
set -u
D=/tmp/sbom-smoke
rm -rf "${D:?}"
mkdir -p "${D}"
SBOM=${SBOM_FILE:-/SBOM.txt}
REG=${SBOM_REGISTRY:-/setup/third-party.txt}
SETUP=${SBOM_SETUP_DIR:-/setup}
# The components allowed to read UNKNOWN in the shipped file, by name (one per line of this list, with the reason):
#   cuda-toolkit   the hindsight-api tool environment's NVIDIA wheel; its metadata and its PyPI record declare no license
# Any other UNKNOWN line - a new component without a license, or one of these losing its line to another - turns check 6 red
# until its license is found (a registry dpkg:/npm:/python: line) or the name is added here on purpose.
UNKNOWN_ALLOWED="cuda-toolkit"

fail() { echo "Test-sbom FAILED: $*"; exit 1; }
# the body: everything after the header's first empty line; a section's lines: from its `# <title>` line to the next one
body() { awk 'b {print; next} /^$/ {b=1}' "$1"; }
section() { awk -v t="# $1" 'index($0, t) == 1 {on=1; next} /^# / {on=0} on && NF {print}' "$2"; }
# the component lines of a registry: not a comment, not blank, not a dpkg:/npm:/python:/none: line
reg_components() { grep -vE '^[[:space:]]*(#|$)' "$1" | grep -vE '^(dpkg|npm|python|none):'; }
# the directories the generator never walks under /, as find prunes
PRUNE=(-path /proc -o -path /sys -o -path /dev -o -path /run -o -path /var/run -o -path /tmp -o -path /var/tmp -o -path /wd
       -o -path /home/agent/.npm -o -path /home/agent/.cache -o -path /home/agent/.bun/install/cache -o -path /home/hindsight/.cache -o -path /home/agent/.local/share/uv/cache)

# --- 1. the file, its header, its sections ---
[ -s "${SBOM}" ] || fail "1: ${SBOM} is missing or empty (the Dockerfile's last step is RUN /sbom.sh)"
IMAGE=$(awk '{print $1; exit}' /version.txt 2>/dev/null)
[ -n "${IMAGE}" ] || fail "1: /version.txt names no image"
head -1 "${SBOM}" | grep -qF "## Software bill of materials (SBOM) of the container image ${IMAGE}, build ${AGENT_BUILD:-}" \
	|| fail "1: the first line does not name the image ${IMAGE} and the build ${AGENT_BUILD:-}: $(head -1 "${SBOM}")"
[ -n "${AGENT_BUILD:-}" ] || fail "1: AGENT_BUILD is not set (the Dockerfile's ENV)"
grep -q '^$' "${SBOM}" || fail "1: no empty line ends the header"
LINES=$(grep -n '^# ' "${SBOM}" | cut -d: -f1 | tr '\n' ' ')
[ "$(grep -c '^# ' "${SBOM}")" == "4" ] || fail "1: expected four section lines, got: $(grep '^# ' "${SBOM}" | cut -c1-40 | tr '\n' '|')"
PREV=0
for T in "# apt packages (dpkg)" "# Node.js packages (npm)" "# Python packages" "# tools installed from release archives"; do
	N=$(grep -n -F -- "${T}" "${SBOM}" | cut -d: -f1)
	[ "$(echo "${N}" | grep -c .)" == "1" ] || fail "1: the section '${T}' is not there exactly once"
	[ "${N}" -gt "${PREV}" ] || fail "1: the section '${T}' is out of order (line ${N} after ${PREV})"
	PREV=${N}
done
echo "ok 1 - ${SBOM} is there, its header names ${IMAGE} build ${AGENT_BUILD}, the four sections in order (lines ${LINES})"

# --- 2. the line shape ---
body "${SBOM}" | grep -vE '^$|^# ' > "${D}/lines"
[ -s "${D}/lines" ] || fail "2: the body has no component line"
BAD=$(grep -vE '^[^ ]+ [^ ]+ - [^ ].*$' "${D}/lines" | head -3)
[ -z "${BAD}" ] || fail "2: lines that are not <name> <version> - <license>: $(echo "${BAD}" | tr '\n' '|')"
BAD=$(grep -E ' - UNKNOWN' "${D}/lines" | grep -vE ' - UNKNOWN \(.+\)$' | head -3)
[ -z "${BAD}" ] || fail "2: UNKNOWN lines without a reason in parentheses: $(echo "${BAD}" | tr '\n' '|')"
echo "ok 2 - $(wc -l < "${D}/lines") body lines, each <name> <version> - <license>, every UNKNOWN with its reason"

# --- 3. coverage, each source enumerated here ---
# expected_* <out> [extra root...] - the components the image carries, as `<name> <version>` lines, sorted, unique
expected_apt() { dpkg-query -W -f '${binary:Package} ${Version} ${db:Status-Status}\n' | awk '$3 == "installed" {print $1 " " $2}' | sort -u > "$1"; }
expected_npm()
{
	local OUT=$1; shift
	{ find / -xdev \( "${PRUNE[@]}" \) -prune -o -type f -name package.json -print 2>/dev/null
	  for R in "$@"; do find "${R}" -type f -name package.json 2>/dev/null; done; } \
		| grep -E '/node_modules/(@[^/]+/)?[^/@.][^/]*/package.json$' | sort -u > "${OUT}.files"
	python3 - "${OUT}.files" << 'PY' | sort -u > "${OUT}"
import json, sys
for f in open(sys.argv[1]).read().splitlines():
    try:
        m = json.load(open(f))
    except Exception:
        continue
    if isinstance(m, dict) and isinstance(m.get("name"), str) and m["name"].strip():
        v = m.get("version") if isinstance(m.get("version"), str) and m["version"].strip() else "unknown"
        print(m["name"].strip().replace(" ", "_"), v.strip().replace(" ", "_"))
PY
}
expected_python()
{
	local OUT=$1; shift
	{ find / -xdev \( "${PRUNE[@]}" \) -prune -o \( -type d -name '*.dist-info' -o -name '*.egg-info' \) -print 2>/dev/null
	  for R in "$@"; do find "${R}" \( -type d -name '*.dist-info' -o -name '*.egg-info' \) 2>/dev/null; done; } | sort -u > "${OUT}.dirs"
	python3 - "${OUT}.dirs" << 'PY' | sort -u > "${OUT}"
import os, re, sys
for d in open(sys.argv[1]).read().splitlines():
    f = d if os.path.isfile(d) else os.path.join(d, "METADATA" if d.endswith(".dist-info") else "PKG-INFO")   # a single-file egg-info is its own PKG-INFO
    fields = {}
    try:
        for line in open(f, "rb").read().decode("utf-8", "replace").replace("\r\n", "\n").split("\n\n", 1)[0].splitlines():
            m = re.match(r"^([A-Za-z][A-Za-z0-9-]*):\s*(.*)$", line)
            if m:
                fields.setdefault(m.group(1).lower(), m.group(2).strip())
    except OSError:
        pass
    name, version = fields.get("name", ""), fields.get("version", "")
    if not name:
        b = os.path.basename(d)
        m = re.match(r"^(.+?)-([0-9][^-]*)\.(dist|egg)-info$", b)
        name, version = (m.group(1), m.group(2)) if m else (b.rsplit(".", 1)[0], "")
    print(name.replace(" ", "_"), (version or "unknown").replace(" ", "_"))
PY
}
# got <section title prefix> <file> <out> - the `<name> <version>` of a section's lines, sorted (duplicates kept: check 3 wants none)
got() { section "$1" "$2" | awk '{print $1 " " $2}' | sort > "$3"; }
# coverage <source> <expected> <got> - empty output when every expected component is there exactly once and nothing else is
coverage()
{
	local MISSING EXTRA DUP
	MISSING=$(comm -23 "$2" <(sort -u "$3")); EXTRA=$(comm -13 "$2" <(sort -u "$3")); DUP=$(uniq -d "$3")
	[ -z "${MISSING}" ] || echo "$1: not listed: $(echo "${MISSING}" | head -5 | tr '\n' '|') ($(echo "${MISSING}" | grep -c .) in all)"
	[ -z "${EXTRA}" ] || echo "$1: listed but not found: $(echo "${EXTRA}" | head -5 | tr '\n' '|') ($(echo "${EXTRA}" | grep -c .) in all)"
	[ -z "${DUP}" ] || echo "$1: listed twice: $(echo "${DUP}" | head -5 | tr '\n' '|')"
}
expected_apt "${D}/exp-apt"; got "apt packages" "${SBOM}" "${D}/got-apt"
expected_npm "${D}/exp-npm"; got "Node.js packages" "${SBOM}" "${D}/got-npm"
expected_python "${D}/exp-py"; got "Python packages" "${SBOM}" "${D}/got-py"
reg_components "${REG}" | awk '{print $1}' | sort > "${D}/exp-tools"
[ "$(sort -u "${D}/exp-tools" | wc -l)" == "$(wc -l < "${D}/exp-tools")" ] || fail "3: a component name is on two lines of ${REG}: $(uniq -d "${D}/exp-tools" | tr '\n' ' ')"
section "tools installed" "${SBOM}" | awk '{print $1}' | sort > "${D}/got-tools"
R=$(coverage apt "${D}/exp-apt" "${D}/got-apt"; coverage npm "${D}/exp-npm" "${D}/got-npm"; coverage python "${D}/exp-py" "${D}/got-py"; coverage tools "${D}/exp-tools" "${D}/got-tools")
[ -z "${R}" ] || fail "3: $(echo "${R}" | tr '\n' ' ')"
[ -s "${D}/exp-apt" ] && [ -s "${D}/exp-npm" ] && [ -s "${D}/exp-py" ] && [ -s "${D}/exp-tools" ] || fail "3: a source enumerated nothing (apt $(wc -l < "${D}/exp-apt"), npm $(wc -l < "${D}/exp-npm"), python $(wc -l < "${D}/exp-py"), tools $(wc -l < "${D}/exp-tools"))"
U=$(section "tools installed" "${SBOM}" | awk '$2 == "unknown" {print $1}')
[ -z "${U}" ] || fail "3: registry components whose version probe gave nothing: $(echo "${U}" | tr '\n' ' ')"
# CONTROL: a planted distribution under a prefix the generator does not walk by itself
mkdir -p "${D}/planted/site-packages/sbom_planted_control-9.9.9.dist-info"
printf 'Metadata-Version: 2.1\nName: sbom-planted-control\nVersion: 9.9.9\nLicense-Expression: MIT\n' > "${D}/planted/site-packages/sbom_planted_control-9.9.9.dist-info/METADATA"
expected_python "${D}/exp-py-planted" "${D}/planted"
grep -qx 'sbom-planted-control 9.9.9' "${D}/exp-py-planted" || fail "3: CONTROL BROKEN: the planted distribution was not enumerated"
R=$(coverage python "${D}/exp-py-planted" "${D}/got-py")
echo "${R}" | grep -q 'not listed: sbom-planted-control 9.9.9' || fail "3: CONTROL BROKEN: the planted distribution missing from the shipped file was not reported: ${R}"
python3 /agent/sbom.py --output "${D}/regen-planted.txt" --also "${D}/planted" > "${D}/regen-planted.log" 2>&1 || fail "3: sbom.py --also failed: $(tail -3 "${D}/regen-planted.log")"
got "Python packages" "${D}/regen-planted.txt" "${D}/got-py-planted"
R=$(coverage python "${D}/exp-py-planted" "${D}/got-py-planted")
[ -z "${R}" ] || fail "3: with the planted prefix walked, the regenerated file does not cover it: ${R}"
grep -qE '^sbom-planted-control 9\.9\.9 - MIT$' "${D}/regen-planted.txt" || fail "3: the planted distribution's line is not '<name> <version> - MIT'"
echo "ok 3 - every component found is listed once: apt $(wc -l < "${D}/exp-apt"), npm $(wc -l < "${D}/exp-npm"), python $(wc -l < "${D}/exp-py"), tools $(wc -l < "${D}/exp-tools"); no registry version unknown; CONTROL: a planted dist-info is reported missing, and listed once its prefix is walked"

# --- 4. every installer accounted for; every registry installer exists ---
# installs <file> - true when the installer's text installs through a package manager (apt, npm, npx, pip, uv)
installs() { grep -qE 'apt(-get)? +install|npm +(install|ci)\b|npx +|pip3? +install|uv +tool +install' "$1"; }
# unaccounted <registry> - the installers under ${SETUP} that no rule accounts for, one a line; a none: line on an installer
# whose text installs is reported too
unaccounted()
{
	local F B
	for F in "${SETUP}"/install-*.sh "${SETUP}"/harden.sh; do
		[ -f "${F}" ] || continue
		B=$(basename "${F}")
		if grep -qE "^none:${B//./\\.}( |$)" "$1"; then
			installs "${F}" && echo "${B} (a none: line, but its text installs through a package manager)"
			continue
		fi
		installs "${F}" && continue
		grep -vE '^[[:space:]]*(#|$)' "$1" | grep -vE '^none:' | awk -F' - ' '{print $NF}' | awk '{print $1}' | grep -qxF -- "${B}" && continue
		echo "${B}"
	done
}
R=$(unaccounted "${REG}")
[ -z "${R}" ] || fail "4: installers that neither install through a package manager nor are named by ${REG}: $(echo "${R}" | tr '\n' ' ')"
# every installer a registry line names exists: /setup/<install-*.sh>|harden.sh, or the /opt tree; a path of the repository
# (the sandbox template) is not in the image and is noted, not checked
MISSING=""; NOTED=""
while IFS= read -r INST; do
	FIRST=${INST%% *}
	case "${FIRST}" in
		install-*.sh|harden.sh) [ -f "${SETUP}/${FIRST}" ] || MISSING="${MISSING} ${FIRST}" ;;
		/opt/*) [ -d "${FIRST}" ] || MISSING="${MISSING} ${FIRST}" ;;
		*) echo "${NOTED}" | grep -qF -- " ${FIRST}" || NOTED="${NOTED} ${FIRST}" ;;
	esac
done < <(grep -vE '^[[:space:]]*(#|$)' "${REG}" | grep -vE '^none:' | awk -F' - ' '{print $NF}')
[ -z "${MISSING}" ] || fail "4: installers named by ${REG} that do not exist:${MISSING}"
# CONTROL: the registry without its aws-cli line leaves install-aws.sh (curl of a zip: no package manager) unaccounted
grep -v '^aws-cli ' "${REG}" > "${D}/reg-no-aws.txt"
[ "$(grep -c '^aws-cli ' "${REG}")" == "1" ] || fail "4: CONTROL BROKEN: ${REG} has no single aws-cli line"
unaccounted "${D}/reg-no-aws.txt" | grep -qx 'install-aws.sh' || fail "4: CONTROL BROKEN: without the aws-cli line install-aws.sh is not reported: $(unaccounted "${D}/reg-no-aws.txt" | tr '\n' ' ')"
echo "ok 4 - every installer under ${SETUP} installs through a package manager, is named by the registry or is a none: line; every named installer exists (not in the image, noted:${NOTED:- none}); CONTROL: a registry without aws-cli leaves install-aws.sh unaccounted"

# --- 5. determinism ---
/sbom.sh "${D}/regen.txt" > "${D}/regen.log" 2>&1 || fail "5: /sbom.sh ${D}/regen.txt failed: $(tail -3 "${D}/regen.log" | tr '\n' ' ')"
body "${SBOM}" > "${D}/body-shipped"; body "${D}/regen.txt" > "${D}/body-regen"
cmp -s "${D}/body-shipped" "${D}/body-regen" || fail "5: the regenerated body differs from the shipped one: $(diff "${D}/body-shipped" "${D}/body-regen" | head -5 | tr '\n' '|')"
[ "$(head -1 "${D}/regen.txt")" == "$(head -1 "${SBOM}")" ] || fail "5: the regenerated first line differs: $(head -1 "${D}/regen.txt")"
grep -q '^sbom.sh: components: ' "${D}/regen.log" || fail "5: sbom.sh did not print the counts line: $(cat "${D}/regen.log" | tr '\n' ' ')"
echo "ok 5 - /sbom.sh regenerates the same body ($(wc -l < "${D}/body-shipped") lines) and the same first line"

# --- 6. the header's counts are the body's; UNKNOWN within the allowance ---
COUNTS=$(grep -m1 '^## components: ' "${SBOM}")
[ -n "${COUNTS}" ] || fail "6: no '## components:' line in the header"
for S in "apt:apt packages" "npm:Node.js packages" "python:Python packages" "tools:tools installed"; do
	N=$(echo "${COUNTS}" | grep -oE "\b${S%%:*} [0-9]+" | awk '{print $2}')
	G=$(section "${S#*:}" "${SBOM}" | wc -l)
	[ "${N}" == "${G}" ] || fail "6: the header says ${S%%:*} ${N}, the section has ${G} lines"
done
TOTAL=$(echo "${COUNTS}" | grep -oE 'total [0-9]+' | awk '{print $2}')
[ "${TOTAL}" == "$(wc -l < "${D}/lines")" ] || fail "6: the header says total ${TOTAL}, the body has $(wc -l < "${D}/lines") lines"
HU=$(echo "${COUNTS}" | grep -oE 'UNKNOWN [0-9]+' | awk '{print $2}')
BU=$(grep -c ' - UNKNOWN (' "${D}/lines")
[ "${HU}" == "${BU}" ] || fail "6: the header says UNKNOWN ${HU}, the body has ${BU} UNKNOWN lines"
NOT_ALLOWED=$(grep ' - UNKNOWN (' "${D}/lines" | awk '{print $1}' | grep -vxF -f <(printf '%s\n' ${UNKNOWN_ALLOWED}))
[ -z "${NOT_ALLOWED}" ] || fail "6: UNKNOWN lines whose component is not on the allow-list (${UNKNOWN_ALLOWED}): $(grep ' - UNKNOWN (' "${D}/lines" | grep -F -f <(printf '%s\n' ${NOT_ALLOWED}) | tr '\n' '|')"
echo "ok 6 - the header's counts are the body's (${COUNTS#\#\# }); ${BU} UNKNOWN line(s), each on the allow-list (${UNKNOWN_ALLOWED})"

rm -rf "${D:?}"
echo "Test-sbom succeeded"
