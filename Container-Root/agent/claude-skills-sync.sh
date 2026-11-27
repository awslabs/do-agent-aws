#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The harness's own Claude Code skills and commands, kept current in the agent's Claude configuration (docs/manual/install.md "Setup
# doctor"). The image ships them under /agent/skills/<skill>/ and /agent/commands/<command>.md, and Claude Code reads
# them from CLAUDE_CONFIG_DIR/skills and CLAUDE_CONFIG_DIR/commands. That configuration is persisted agent state
# (wd/agent-state/.claude), which Docker seeds from the image only on the first start, so an image update would never
# reach an existing deployment: /agent/claude-settings-sync.sh runs this at the build and again at every start (before
# the agent's session starts claude), and it copies the image's files there file by file, only where a file differs.
# A file an earlier sync installed and the image no longer ships (renamed or dropped) is removed; the list of what was
# installed is CLAUDE_CONFIG_DIR/.harness-skills-shipped. Nothing else in those directories is touched: a skill, a
# command or a file of the person's own stays as it is.
# settings.json then gets one rule in permissions.allow: reading the harness-setup skill's own directory. The skill
# reads its files (prompts/steps.md, the Slack manifest, the walk-throughs), which lie outside the session's working
# directory /wd, and Claude Code asks before a read there: a question a headless call has nobody to answer and the
# Agent chat page cannot show. The person's own rules and keys stay, and an unreadable settings.json is left alone.
# Idempotent; prints one line per file it wrote, one summary line and one line for the rule; exit 1 when a file could
# not be written.
# AGENT_SKILLS_PACK (docs/manual/autonomy.md "Parity with a native instance"): the skills imported from a native instance's library - a
# SKILL.md ending with the importer's provenance comment - are synced like the harness's own when it is true (the default) and
# left out when it is false: they then count as not shipped, so the copies an earlier sync made are removed by the manifest
# step below, the harness's own skills untouched.
# Environment: CLAUDE_CONFIG_DIR (default ~/.claude), AGENT_SKILLS_PACK (default true).
set -u
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-/home/agent}/.claude}
RC=0
WROTE=0
SAME=0
AGENT_SKILLS_PACK=${AGENT_SKILLS_PACK:-true}
AGENT_SKILLS_PACK=${AGENT_SKILLS_PACK,,}   # false, False and FALSE are one answer
# the person's own: a destination that exists, differs from the image's file and was not installed by an earlier sync (it is
# not in the manifest below) is the person's own skill or command under a name the image now ships; it is kept and reported
MANIFEST="${CLAUDE_DIR}/.harness-skills-shipped"
PREV=$(cat "${MANIFEST}" 2>/dev/null)
KEPT_OWN=0
KEPT_OWN_PATHS=""
# imported <path under skills/> - true when the file belongs to an imported skill (its SKILL.md carries the provenance comment)
imported()
{
	local S=${AGENT_DIR}/skills/${1%%/*}/SKILL.md
	[ -f "${S}" ] && grep -q '^<!-- imported on [0-9-]* by tools/import-skills.py' "${S}"
}
SKIPPED=0

sync_file()
{
	# sync_file <the image's file> <the configuration's copy>
	SRC=$1
	DST=$2
	if cmp -s "${SRC}" "${DST}"; then
		SAME=$((SAME + 1))
		return
	fi
	if [ -e "${DST}" ] && ! grep -qxF -- "${DST#"${CLAUDE_DIR}"/}" <<< "${PREV}"; then
		echo "claude-skills-sync: ${DST} is the person's own (not installed by an earlier sync) - kept, the image's ${SRC} not installed"
		KEPT_OWN=$((KEPT_OWN + 1))
		KEPT_OWN_PATHS="${KEPT_OWN_PATHS}${DST#"${CLAUDE_DIR}"/}
"
		return
	fi
	if mkdir -p "$(dirname "${DST}")" && cp "${SRC}" "${DST:?}.tmp" && mv -f "${DST:?}.tmp" "${DST:?}"; then
		echo "claude-skills-sync: ${DST} written from ${SRC}"
		WROTE=$((WROTE + 1))
	else
		echo "claude-skills-sync: could not write ${DST}"
		RC=1
	fi
}

for KIND in skills commands; do
	[ -d "${AGENT_DIR}/${KIND}" ] || continue
	while IFS= read -r -d '' F; do
		if [ "${KIND}" == skills ] && [ "${AGENT_SKILLS_PACK}" == false ] && imported "${F#./}"; then
			SKIPPED=$((SKIPPED + 1))
			continue
		fi
		sync_file "${AGENT_DIR}/${KIND}/${F#./}" "${CLAUDE_DIR}/${KIND}/${F#./}"
	done < <(cd "${AGENT_DIR}/${KIND}" && find . -type f -print0 | sort -z)
done
# what the image ships now, as paths under the configuration; a path the earlier sync recorded that is not among them
# is removed, with its directory once empty (a dropped skill), but never the skills or commands directory itself
NOW=$(for KIND in skills commands; do
	[ -d "${AGENT_DIR}/${KIND}" ] && (cd "${AGENT_DIR}/${KIND}" && find . -type f | sed "s#^\./#${KIND}/#") | while IFS= read -r P; do
		# with the pack off an imported skill is not shipped: an earlier sync's copy is removed below
		if [ "${AGENT_SKILLS_PACK}" == false ] && [ "${KIND}" == skills ] && imported "${P#skills/}"; then continue; fi
		echo "${P}"
	done
done | sort)
if [ -n "${KEPT_OWN_PATHS}" ]; then
	NOW=$(grep -vxF -f <(printf '%s' "${KEPT_OWN_PATHS}") <<< "${NOW}")
fi
REMOVED=0
if [ -f "${MANIFEST}" ]; then
	while IFS= read -r P; do
		case "${P}" in
		*..*) continue ;;
		skills/?*|commands/?*) ;;
		*) continue ;;
		esac
		grep -qxF -- "${P}" <<< "${NOW}" && continue
		[ -f "${CLAUDE_DIR:?}/${P:?}" ] || continue
		if rm -f "${CLAUDE_DIR:?}/${P:?}"; then
			echo "claude-skills-sync: ${CLAUDE_DIR}/${P} removed: the image no longer ships it"
			REMOVED=$((REMOVED + 1))
			D=$(dirname "${P}")
			while [ "${D}" != skills ] && [ "${D}" != commands ] && [ "${D}" != . ] && rmdir "${CLAUDE_DIR:?}/${D:?}" 2> /dev/null; do
				D=$(dirname "${D}")
			done
		else
			echo "claude-skills-sync: could not remove ${CLAUDE_DIR}/${P}"
			RC=1
		fi
	done < "${MANIFEST}"
fi
if [ "$(cat "${MANIFEST}" 2> /dev/null)" != "${NOW}" ]; then
	{ mkdir -p "${CLAUDE_DIR}" && printf '%s\n' "${NOW}" > "${MANIFEST}.tmp" && mv -f "${MANIFEST}.tmp" "${MANIFEST}"; } \
		|| { echo "claude-skills-sync: could not write ${MANIFEST}"; RC=1; }
fi
echo "claude-skills-sync: ${WROTE} file(s) written, ${SAME} already current, ${REMOVED} removed (no longer shipped), in ${CLAUDE_DIR}/skills and ${CLAUDE_DIR}/commands$([ "${SKIPPED}" -gt 0 ] && echo "; ${SKIPPED} imported skill file(s) left out (AGENT_SKILLS_PACK=false)")$([ "${KEPT_OWN}" -gt 0 ] && echo "; ${KEPT_OWN} file(s) of the person's own kept")"

# the read rule ("//abs/path": a path from the filesystem root in a permission rule)
python3 -I - "${CLAUDE_DIR}/settings.json" "Read(/${CLAUDE_DIR}/skills/harness-setup/**)" << 'PY' || RC=1
import json, os, sys, tempfile
path, rule = sys.argv[1], sys.argv[2]
try:
    s = json.load(open(path)) if os.path.exists(path) else {}
except ValueError as e:
    print(f"claude-skills-sync: {path} is not valid JSON, the skill's read rule left it alone ({e})")
    sys.exit(0)
perms = s.setdefault("permissions", {}) if isinstance(s, dict) else None
allow = perms.setdefault("allow", []) if isinstance(perms, dict) else None
if not isinstance(allow, list):
    print(f"claude-skills-sync: {path} has a permissions block of another shape, the skill's read rule left it alone")
    sys.exit(0)
if rule in allow:
    print(f"claude-skills-sync: {path} already allows {rule}")
    sys.exit(0)
allow.append(rule)
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
print(f"claude-skills-sync: {path} now allows {rule}")
PY
exit ${RC}
