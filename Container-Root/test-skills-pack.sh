#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the skills the image ships (docs/manual/autonomy.md "Parity with a native instance"; /agent/skills, the imported ones listed
# in docs/parity/SKILLS-PACK.md by tools/import-skills.py; /agent/claude-skills-sync.sh copies them into the agent's Claude
# configuration at the build and at every start). Fully OFFLINE; its files under /tmp/skills-pack-test, kept on a failure and
# named; nothing under /wd touched. Each check FAILS if the property it proves is removed:
#   1. every /agent/skills/<name>/SKILL.md has a frontmatter with a name and a description, and the name is the directory's
#   2. an imported skill - one ending with the provenance comment "imported on <date> by tools/import-skills.py" - carries
#      nothing leak-shaped: no Slack id, cloud account id, IPv4 address, private hostname, e-mail address, credential shape,
#      home-directory path, messaging chat id or gist URL (the shapes the importer refuses; loopback and a three-part version are not
#      addresses); PLANTED CONTROL: a copy of one imported skill with a Slack id, an account id, a home path and an IPv4 address
#      planted fails the same scan on exactly those four
#   3. the imported count is the one docs/parity/SKILLS-PACK.md states ("Kept N of M skills."), when that file is reachable
#      (a checkout, or the checkout mounted at /do-agent-aws)
#   4. /agent/claude-skills-sync.sh run against an empty configuration directory copies every SKILL.md of /agent/skills there
#      (the shipping path of every skill, imported or the harness's own), its summary names no left-out or kept-own file, and a
#      second run writes nothing
#   5. AGENT_SKILLS_PACK=false (docs/manual/autonomy.md "Parity with a native instance"): the same sync into that configuration removes every
#      imported skill's copy and keeps the harness's own, says how many it left out, and copies no imported file into an empty
#      configuration; AGENT_SKILLS_PACK=true afterwards brings them back
#   6. a skill of the person's own under a name the image ships (planted in the configuration, not installed by an earlier sync)
#      is kept byte for byte and reported, by a sync with the pack on and by one with it off
set -u
D=/tmp/skills-pack-test
rm -rf "${D:?}"
mkdir -p "${D}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
SKILLS=${AGENT_DIR}/skills
FAILED=""
fail() { FAILED=1; echo "Test-skills-pack FAILED: $* (the files are kept under ${D})"; exit 1; }
trap '[ -n "${FAILED}" ] || rm -rf "${D:?}"' EXIT
[ -d "${SKILLS}" ] || fail "no ${SKILLS}"

# --- 1. frontmatter ---
N=0
for F in "${SKILLS}"/*/SKILL.md; do
	N=$((N + 1))
	DIR=$(basename "$(dirname "${F}")")
	head -1 "${F}" | grep -qx -- '---' || fail "1: ${F} does not start with a frontmatter"
	NAME=$(awk 'NR>1 && /^---$/ {exit} /^name:/ {sub(/^name:[ \t]*/, ""); gsub(/["'"'"']/, ""); print; exit}' "${F}")
	[ -n "${NAME}" ] || fail "1: ${F} has no frontmatter name"
	[ "${NAME}" == "${DIR}" ] || fail "1: ${F} names itself '${NAME}' in a directory named '${DIR}'"
	awk 'NR>1 && /^---$/ {exit} /^description:[ \t]*[^ \t]/ {found=1} END {exit !found}' "${F}" || fail "1: ${F} has no frontmatter description"
done
[ "${N}" -ge 2 ] || fail "1: fewer than 2 skills under ${SKILLS} (the harness ships harness-setup and comms-connect at least)"
echo "ok 1 - ${N} skills under ${SKILLS}, each with a frontmatter name equal to its directory and a description"

# --- 2. imported skills carry nothing leak-shaped; the scan is live (planted control) ---
# scan <file> - the leak shapes found in <file>, one label per line (empty when clean)
scan()
{
	python3 - "$1" << 'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
held = re.sub(r"(?<![0-9.])(?:(?:v|version )[0-9]+(?:\.[0-9]+){3}|[0-9]+\.[0-9]+\.[0-9]+)(?![0-9.])", " ", text)   # versions are not addresses
held = re.sub(r"\b(?:127\.0\.0\.1|0\.0\.0\.0)\b", " ", held)   # loopback and the unspecified address are not leaks
shapes = [
    ("slack id", r"\b[UCDGW]0[A-Z0-9]{8,10}\b"),
    ("account id", r"\b[0-9]{12}\b"),
    ("ipv4", r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"),
    ("private hostname", r"\bip-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}\b|\.compute\.internal\b|\.ec2\.internal\b|\bi-[0-9a-f]{17}\b"),
    ("e-mail", r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
    ("credential", r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bxox[abposr]-[0-9A-Za-z-]{10,}|\bgh[pousr]_[0-9A-Za-z]{30,}|\bgithub_pat_[0-9A-Za-z_]{22,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\bsk-(?:ant|proj)-[A-Za-z0-9_-]{20,}|\bhf_[A-Za-z0-9]{30,}"),
    ("home path", r"/home/[A-Za-z0-9_.-]+(?:/|\b)|(?:^|/)-home-[A-Za-z0-9_.-]+-"),
    ("chat id", r"(?i)\b(?:telegram|chat[ _-]?id|whatsapp|signal)\b\D{0,24}\b[0-9]{7,12}\b"),
    ("gist", r"gist\.github\.com/\S+|\bgist(?: id)?\s+[0-9a-f]{8,32}\b"),
]
for label, pat in shapes:
    if re.search(pat, held, re.M):
        print(label)
PY
}
IMPORTED=0
for F in "${SKILLS}"/*/SKILL.md; do
	grep -q '^<!-- imported on [0-9-]* by tools/import-skills.py' "${F}" || continue
	IMPORTED=$((IMPORTED + 1))
	HITS=$(scan "${F}")
	[ -z "${HITS}" ] || fail "2: $(basename "$(dirname "${F}")") carries $(echo "${HITS}" | tr '\n' ' ')"
done
# the files the sync leaves out with the pack off: every file of an imported skill's folder (its SKILL.md, and the LICENSE
# of a skill adapted from an MIT-licensed project)
IMPORTED_FILES=0
for F in "${SKILLS}"/*/SKILL.md; do
	grep -q '^<!-- imported on [0-9-]* by tools/import-skills.py' "${F}" || continue
	IMPORTED_FILES=$(( IMPORTED_FILES + $(find "$(dirname "${F}")" -type f | wc -l) ))
done
ONE=$(for F in "${SKILLS}"/*/SKILL.md; do grep -q '^<!-- imported on' "${F}" && { echo "${F}"; break; }; done)
if [ -n "${ONE}" ]; then
	mkdir -p "${D}/planted"
	{ cat "${ONE}"; printf '\nPLANTED: channel C0ABCDEFGHJ account 123456789012 at /home/someone/work on 10.1.2.3 (claude 2.1.304 and 127.0.0.1 are not addresses)\n'; } > "${D}/planted/SKILL.md"
	HITS=$(scan "${D}/planted/SKILL.md" | sort | tr '\n' ' ')
	[ "${HITS}" == "account id home path ipv4 slack id " ] || fail "2: PLANTED CONTROL BROKEN: the planted Slack id, account id, home path and IPv4 address were reported as '${HITS}' (expected exactly those four)"
	echo "ok 2 - ${IMPORTED} imported skill(s), none carries a leak shape; PLANTED CONTROL: a copy with a Slack id, an account id, a home path and an IPv4 address fails on exactly those four (a version and loopback do not count)"
else
	echo "ok 2 - no imported skill under ${SKILLS} (nothing to scan); the scan's planted control was not exercised"
fi

# --- 3. the count the report states ---
REPORT=""
for C in "${BASE_DIR}/../docs/parity/SKILLS-PACK.md" "/do-agent-aws/docs/parity/SKILLS-PACK.md"; do
	[ -f "${C}" ] && REPORT=${C} && break
done
if [ -n "${REPORT}" ]; then
	STATED=$(sed -n 's/^Kept \([0-9]*\) of [0-9]* skills\..*$/\1/p' "${REPORT}" | head -1)
	[ -n "${STATED}" ] || fail "3: ${REPORT} has no 'Kept N of M skills.' line"
	[ "${STATED}" == "${IMPORTED}" ] || fail "3: ${REPORT} states ${STATED} imported skills, ${SKILLS} holds ${IMPORTED}"
	echo "ok 3 - ${REPORT} states ${STATED} imported skills and ${SKILLS} holds ${IMPORTED}"
else
	echo "ok 3 - docs/parity/SKILLS-PACK.md not reachable from here (the count was not compared)"
fi

# --- 4. the shipping path: claude-skills-sync.sh into an empty configuration ---
SYNC=${AGENT_DIR}/claude-skills-sync.sh
[ -f "${SYNC}" ] || fail "4: ${SYNC} is missing"
mkdir -p "${D}/config"
CLAUDE_CONFIG_DIR="${D}/config" "${SYNC}" > "${D}/sync1.out" 2>&1 || fail "4: claude-skills-sync.sh exited nonzero: $(tail -3 "${D}/sync1.out")"
grep -q "left out\|person's own" "${D}/sync1.out" && fail "4: the summary of a sync with the pack on names left-out or kept-own files: $(grep "file(s) written" "${D}/sync1.out")"
COPIED=$(find "${D}/config/skills" -name SKILL.md | wc -l)
[ "${COPIED}" == "${N}" ] || fail "4: the sync copied ${COPIED} SKILL.md files of ${N}: $(tail -2 "${D}/sync1.out")"
for F in "${SKILLS}"/*/SKILL.md; do
	REL=${F#"${SKILLS}"/}
	cmp -s "${F}" "${D}/config/skills/${REL}" || fail "4: ${REL} differs after the sync"
done
CLAUDE_CONFIG_DIR="${D}/config" "${SYNC}" > "${D}/sync2.out" 2>&1 || fail "4: the second sync exited nonzero"
grep -q '^claude-skills-sync: 0 file(s) written, ' "${D}/sync2.out" || fail "4: the second sync wrote files: $(grep 'file(s) written' "${D}/sync2.out")"
echo "ok 4 - claude-skills-sync.sh copied all ${COPIED} SKILL.md files byte for byte into an empty configuration; the second run wrote nothing"

# --- 5. AGENT_SKILLS_PACK=false ---
if [ "${IMPORTED}" -gt 0 ]; then
	OWN=$(( N - IMPORTED ))
	AGENT_SKILLS_PACK=false CLAUDE_CONFIG_DIR="${D}/config" "${SYNC}" > "${D}/sync-off.out" 2>&1 || fail "5: the sync with AGENT_SKILLS_PACK=false exited nonzero: $(tail -3 "${D}/sync-off.out")"
	LEFT=$(find "${D}/config/skills" -name SKILL.md | wc -l)
	[ "${LEFT}" == "${OWN}" ] || fail "5: with the pack off ${LEFT} SKILL.md files remain in the configuration, expected the harness's own ${OWN}: $(tail -2 "${D}/sync-off.out")"
	for F in "${SKILLS}"/*/SKILL.md; do
		REL=${F#"${SKILLS}"/}
		if grep -q '^<!-- imported on' "${F}"; then
			[ ! -e "${D}/config/skills/${REL}" ] || fail "5: the imported ${REL} is still in the configuration with the pack off"
		else
			cmp -s "${F}" "${D}/config/skills/${REL}" || fail "5: the harness's own ${REL} was changed or removed with the pack off"
		fi
	done
	grep -q "${IMPORTED_FILES} imported skill file(s) left out (AGENT_SKILLS_PACK=false)" "${D}/sync-off.out" || fail "5: the summary does not say ${IMPORTED_FILES} imported files were left out: $(grep 'file(s) written' "${D}/sync-off.out")"
	mkdir -p "${D}/config-off"
	AGENT_SKILLS_PACK=false CLAUDE_CONFIG_DIR="${D}/config-off" "${SYNC}" > "${D}/sync-off2.out" 2>&1 || fail "5: the sync into an empty configuration with the pack off exited nonzero"
	[ "$(find "${D}/config-off/skills" -name SKILL.md | wc -l)" == "${OWN}" ] || fail "5: an empty configuration got $(find "${D}/config-off/skills" -name SKILL.md | wc -l) skills with the pack off, expected ${OWN}"
	AGENT_SKILLS_PACK=true CLAUDE_CONFIG_DIR="${D}/config" "${SYNC}" > "${D}/sync-on.out" 2>&1 || fail "5: the sync with AGENT_SKILLS_PACK=true exited nonzero"
	[ "$(find "${D}/config/skills" -name SKILL.md | wc -l)" == "${N}" ] || fail "5: AGENT_SKILLS_PACK=true did not bring the imported skills back"
	echo "ok 5 - AGENT_SKILLS_PACK=false: the sync removed the ${IMPORTED} imported skills' copies, kept the harness's own ${OWN}, said it left out their ${IMPORTED_FILES} files, copied none into an empty configuration; true brought them back"
else
	echo "ok 5 - no imported skill to switch off (AGENT_SKILLS_PACK not exercised)"
fi

# --- 6. a skill of the person's own under a shipped name ---
if [ -n "${ONE}" ]; then
	OWN_NAME=$(basename "$(dirname "${ONE}")")
	mkdir -p "${D}/config-own/skills/${OWN_NAME}"
	printf 'mine\n' > "${D}/config-own/skills/${OWN_NAME}/SKILL.md"
	CLAUDE_CONFIG_DIR="${D}/config-own" "${SYNC}" > "${D}/sync-own.out" 2>&1 || fail "6: the sync with a planted own skill exited nonzero: $(tail -3 "${D}/sync-own.out")"
	[ "$(cat "${D}/config-own/skills/${OWN_NAME}/SKILL.md")" == "mine" ] || fail "6: the person's own ${OWN_NAME}/SKILL.md was overwritten by the image's"
	grep -q "skills/${OWN_NAME}/SKILL.md is the person's own (not installed by an earlier sync) - kept" "${D}/sync-own.out" || fail "6: the sync did not report the kept own skill: $(grep -i own "${D}/sync-own.out")"
	grep -q "1 file(s) of the person's own kept" "${D}/sync-own.out" || fail "6: the summary does not count the kept own file: $(grep 'file(s) written' "${D}/sync-own.out")"
	[ "$(find "${D}/config-own/skills" -name SKILL.md | wc -l)" == "${N}" ] || fail "6: the other skills were not installed beside the kept own one"
	AGENT_SKILLS_PACK=false CLAUDE_CONFIG_DIR="${D}/config-own" "${SYNC}" > "${D}/sync-own-off.out" 2>&1 || fail "6: the sync with the pack off exited nonzero"
	[ "$(cat "${D}/config-own/skills/${OWN_NAME}/SKILL.md")" == "mine" ] || fail "6: AGENT_SKILLS_PACK=false removed the person's own ${OWN_NAME}/SKILL.md"
	echo "ok 6 - a skill of the person's own under a shipped name (${OWN_NAME}) is kept byte for byte and reported by the sync, and survives AGENT_SKILLS_PACK=false"
else
	echo "ok 6 - no imported skill to shadow (the own-skill protection was not exercised)"
fi

echo "Test-skills-pack succeeded"
