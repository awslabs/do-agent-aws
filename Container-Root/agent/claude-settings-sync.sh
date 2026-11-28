#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Keep the container agent's Claude Code configuration in step with the harness settings.
#
# Run at image build (setup/install-agent-learning.sh, so the image default carries it) and by startup.sh at
# EVERY start, before the UIs and the agent tmux session: Claude Code reads its settings once per session,
# and the configuration lives in the persisted agent state (/home/agent/.claude), so a state created by an older
# image - or a setting flipped in .env - would otherwise never reach the next session. Each step edits only
# the keys it owns, merge-safe, and is idempotent; a failing step prints one line and the next one runs.
# Never fails the start (exit 0).
#
# Steps:
#   hook   the LogLearner PreToolUse entry (Edit|Write|Bash -> /agent/loglearner-hook.sh), registered when
#          LOGLEARNER_HOOK is true (the default) and removed when it is false - /agent/loglearner-settings.py
#   usage  the agent's CLAUDE.md "Learning tools" section: agent-rules/AGENT_LEARNING.md (how to recall before a
#          docker build, a cluster change or an IAM edit, how to bank verified positives and negatives, what the
#          hook injects) is kept current next to CLAUDE.md and referenced from it once (@AGENT_LEARNING.md), the
#          pattern of the governance rules (setup/install-governance.sh); every other line of CLAUDE.md is left
#          as it is
#   knowledge  the default knowledge where a headless loop fire can read it (/agent/knowledge-files.py): the
#          shipped packs (/opt/loglearner-packs) and the seed's general banks copied to /wd/knowledge/defaults, a
#          skill indexing every record, and a marked CLAUDE.md section pointing at them - a fire may Read and Grep but
#          not call MCP tools, so the Hindsight banks alone never reached one (measured); AGENT_KNOWLEDGE=false removes
#          copy, skill and section
#   stores the stores the agent learns from - the LogLearner state (the bank the hook injects from, its index and
#          ledgers) and the default knowledge copy - are written by the harness's own tools only (learn.sh, the pack
#          loader, the dashboard, the knowledge step): Edit deny rules on their absolute paths in settings.json
#          (`Edit(//wd/loglearner/**)`, `Edit(//wd/knowledge/**)` by default). Claude Code checks them for its file
#          tools, for the file commands it recognises in Bash (touch, cp, mv, tee, sed) and for redirect targets
#          (> and >>) in every session - the interactive agent, loop fires and the Slack chat responder - so a steered
#          session cannot append a "rule" the hook then injects into every later one. Measured: a loop fire with the
#          shipped options wrote the bank with Write, Edit, >> and touch until the rules were there. Added when
#          missing, the user's other permission rules kept
#   integrity  a SessionStart hook (`python3 /agent/knowledge-files.py verify`) so every Claude session - each loop fire,
#          each chat reply, the agent's pane - starts from the image's bytes of the knowledge copy, which its CLAUDE.md
#          tells it to follow and which lies on the volume fires work in: a changed or missing file is restored, a pack
#          the image does not ship removed, each case logged (KNOWLEDGE_DIR/integrity.log) and named in the session's
#          context; silent when the copy is the image's. Added once, the other SessionStart hooks kept
#   onboarding  Claude Code's first-run answers (/agent/claude-onboarding.py: onboarding done, a theme, the
#          pane's folder /wd trusted) added to its .claude.json when missing, so the agent's tmux pane - the
#          browser terminal /tmux/ - opens at the prompt instead of the theme picker, the security notes and the
#          trust dialog, where three Enters exit claude to the bare shell; a value already set is never changed
#   statusline  the agent's status line (/agent/claude-statusline.sh: "do-agent-aws · <model> · ctx:<N>%") set
#          in settings.json when none is configured: the context % the tmux-agent dashboard reads off the pane,
#          and the marker its harness lexicon classifies an idle agent by; a status line of the user's own is kept
#   github the GitHub plugin (github@claude-plugins-official) enabled only while a GitHub token is set - GH_TOKEN,
#          GITHUB_TOKEN or GITHUB_PERSONAL_ACCESS_TOKEN (startup.sh hands GH_TOKEN/GITHUB_TOKEN to the plugin as
#          GITHUB_PERSONAL_ACCESS_TOKEN, the variable its MCP server's Authorization header reads). With none set
#          its MCP server failed to connect in every session; and the context7 plugin enabled only when asked for
#          (CONTEXT7_PLUGIN=true): its remote MCP server needs an OAuth sign-in (/mcp), so with it on every new
#          terminal opened on "1 MCP server needs authentication". Only those enabledPlugins keys are ever changed,
#          and only when the plugin is installed
#   skills  the harness's own skills and commands (/agent/claude-skills-sync.sh: the harness-setup skill and its /setup
#          command, from /agent/skills and /agent/commands) copied into the configuration where a file differs; a skill
#          or a command of the person's own is never touched; settings.json allows reading the skill's own files
#   overlay the operator's overlay (/agent/claude-overlay.sh): with AGENT_OVERLAY true (the default) and no /wd/CLAUDE.md, a short
#          stub there that says the overlay is not filled yet and names the shipped example (/agent/CLAUDE.md.example); a file
#          that exists is never touched; false writes nothing (docs/manual/autonomy.md "Parity with a native instance")
#   memory  Claude Code's own auto-memory (/agent/claude-memory-settings.py): autoMemoryEnabled in settings.json follows
#          AGENT_MEMORY (true, the default: the agent writes and loads its MEMORY.md and fact files per working directory,
#          persisted with the state; false turns it off), so an older state or a changed default follows the knob; the
#          other keys are kept (docs/manual/memory.md "Agent memory")

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-/home/agent}/.claude}
AGENT_RULES_DIR=${AGENT_RULES_DIR:-$(cd "${AGENT_DIR}/../agent-rules" 2>/dev/null && pwd)}

python3 "${AGENT_DIR}/loglearner-settings.py" sync || echo "claude-settings-sync: the LogLearner hook entry was not synced"

# usage: the harness owns AGENT_LEARNING.md (refreshed when the image's copy differs); CLAUDE.md is the user's
USAGE_SRC=${AGENT_RULES_DIR}/AGENT_LEARNING.md
if [ -f "${USAGE_SRC}" ] && mkdir -p "${CLAUDE_DIR}" 2>/dev/null; then
	if ! cmp -s "${USAGE_SRC}" "${CLAUDE_DIR}/AGENT_LEARNING.md"; then
		cp "${USAGE_SRC}" "${CLAUDE_DIR}/AGENT_LEARNING.md.tmp" && mv -f "${CLAUDE_DIR:?}/AGENT_LEARNING.md.tmp" "${CLAUDE_DIR:?}/AGENT_LEARNING.md" \
			&& echo "claude-settings-sync: ${CLAUDE_DIR}/AGENT_LEARNING.md updated from ${USAGE_SRC}"
	fi
	if ! grep -qxF "@AGENT_LEARNING.md" "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null; then
		printf '\n## Learning tools (recall before a risky step, bank what you verified)\n@AGENT_LEARNING.md\n' >> "${CLAUDE_DIR}/CLAUDE.md" \
			&& echo "claude-settings-sync: ${CLAUDE_DIR}/CLAUDE.md now references AGENT_LEARNING.md"
	fi
else
	echo "claude-settings-sync: no ${USAGE_SRC} (or ${CLAUDE_DIR} not writable) - the Learning tools section was not synced"
fi

# files: the shared folder of the Files tile (docs/manual/ui.md "Files") - where the agent puts what it made for the person and
# finds what the person uploaded; the harness owns AGENT_FILES.md (refreshed when the image's copy differs), CLAUDE.md
# is the user's and gains one pointer
FILES_SRC=${AGENT_RULES_DIR}/AGENT_FILES.md
# the note names the folder as THIS container has it: the shipped text says /wd/files, FILES_DIR (.env, passed through by
# run.sh and the deploy templates) may say otherwise - the tile serves FILES_DIR, so the agent must be told the same path
FILES_DIR_NOTE=${FILES_DIR:-/wd/files}
if [ -f "${FILES_SRC}" ] && mkdir -p "${CLAUDE_DIR}" 2>/dev/null; then
	if python3 - "${FILES_SRC}" "${CLAUDE_DIR}/AGENT_FILES.md.tmp" "${FILES_DIR_NOTE}" << 'PYEOF'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[3] != "/wd/files":
    s = s.replace("/wd/files", sys.argv[3])
open(sys.argv[2], "w", encoding="utf-8").write(s)
PYEOF
	then
		if ! cmp -s "${CLAUDE_DIR}/AGENT_FILES.md.tmp" "${CLAUDE_DIR}/AGENT_FILES.md"; then
			mv -f "${CLAUDE_DIR:?}/AGENT_FILES.md.tmp" "${CLAUDE_DIR:?}/AGENT_FILES.md" \
				&& echo "claude-settings-sync: ${CLAUDE_DIR}/AGENT_FILES.md updated from ${FILES_SRC} (the shared folder ${FILES_DIR_NOTE})"
		else
			rm -f "${CLAUDE_DIR:?}/AGENT_FILES.md.tmp"
		fi
	else
		rm -f "${CLAUDE_DIR:?}/AGENT_FILES.md.tmp"
		echo "claude-settings-sync: the Files note could not be rendered from ${FILES_SRC} - the section was not synced"
	fi
	if ! grep -qxF "@AGENT_FILES.md" "${CLAUDE_DIR}/CLAUDE.md" 2>/dev/null; then
		printf '\n## Files for the person (the shared folder)\n@AGENT_FILES.md\n' >> "${CLAUDE_DIR}/CLAUDE.md" \
			&& echo "claude-settings-sync: ${CLAUDE_DIR}/CLAUDE.md now references AGENT_FILES.md"
	fi
else
	echo "claude-settings-sync: no ${FILES_SRC} (or ${CLAUDE_DIR} not writable) - the Files section was not synced"
fi

# knowledge: the copy a headless fire can grep, its skill and the CLAUDE.md pointer
python3 "${AGENT_DIR}/knowledge-files.py" sync || echo "claude-settings-sync: the default knowledge was not synced"

# stores: Edit deny rules on the LogLearner state and the knowledge copy, where the agent-side tools keep them
# (loglearner-env.sh's layout, KNOWLEDGE_DIR)
STORE_DIRS=$(. "${AGENT_DIR}/loglearner-env.sh" 2>/dev/null; echo "${LOGLEARNER_STATE:-/wd/loglearner} ${LOGLEARNER_BANKS_DIR:-}")
# shellcheck disable=SC2086 # STORE_DIRS is a list of directories, one per word
python3 - "${CLAUDE_DIR}/settings.json" ${STORE_DIRS} "${KNOWLEDGE_DIR:-/wd/knowledge}" << 'PYEOF' || echo "claude-settings-sync: the store deny rules were not synced"
import json, os, sys, tempfile
path = sys.argv[1]
dirs = []
for d in (os.path.normpath(a) for a in sys.argv[2:] if a.startswith("/")):
    if not any(d == o or d.startswith(o + "/") for o in dirs):  # a directory inside another one is covered
        dirs = [o for o in dirs if not o.startswith(d + "/")] + [d]
rules = ["Edit(/%s/**)" % d for d in dirs]  # "//abs/path/**": an absolute path from the filesystem root
try:
    s = json.load(open(path)) if os.path.exists(path) else {}
except ValueError as e:
    print(f"claude-settings-sync: {path} is not valid JSON, the store deny rules left it alone ({e})")
    sys.exit(0)
perms = s.setdefault("permissions", {}) if isinstance(s, dict) else None
deny = perms.setdefault("deny", []) if isinstance(perms, dict) else None
if not isinstance(deny, list):
    print(f"claude-settings-sync: {path} has a permissions block of another shape, the store deny rules left it alone")
    sys.exit(0)
missing = [r for r in rules if r not in deny]
if not missing:
    print("claude-settings-sync: store deny rules already in place: " + " ".join(rules))
    sys.exit(0)
deny.extend(missing)
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
print("claude-settings-sync: store deny rules added: " + " ".join(missing))
PYEOF

# integrity: every session starts from the image's bytes of the knowledge copy (knowledge-files.py verify)
python3 - "${CLAUDE_DIR}/settings.json" "python3 ${AGENT_DIR}/knowledge-files.py verify" << 'PYEOF' || echo "claude-settings-sync: the knowledge integrity hook was not synced"
import json, os, sys, tempfile
path, cmd = sys.argv[1], sys.argv[2]
try:
    s = json.load(open(path)) if os.path.exists(path) else {}
except ValueError as e:
    print(f"claude-settings-sync: {path} is not valid JSON, the knowledge integrity hook left it alone ({e})")
    sys.exit(0)
hooks = s.setdefault("hooks", {}) if isinstance(s, dict) else None
groups = hooks.setdefault("SessionStart", []) if isinstance(hooks, dict) else None
if not isinstance(groups, list):
    print(f"claude-settings-sync: {path} has hooks of another shape, the knowledge integrity hook left it alone")
    sys.exit(0)
if any(isinstance(g, dict) and any(isinstance(h, dict) and h.get("command") == cmd for h in g.get("hooks") or [])
       for g in groups):
    print("claude-settings-sync: knowledge integrity hook already registered (SessionStart: " + cmd + ")")
    sys.exit(0)
groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
print("claude-settings-sync: knowledge integrity hook registered (SessionStart: " + cmd + ")")
PYEOF

# onboarding: the interactive pane starts in /wd (/agent/tmux-session-start.sh), so that folder is the trusted one
python3 "${AGENT_DIR}/claude-onboarding.py" --config "${CLAUDE_DIR}/.claude.json" --dir /wd \
	|| echo "claude-settings-sync: Claude Code's first-run answers were not synced"

# statusline: set only when none is configured
python3 - "${CLAUDE_DIR}/settings.json" "${AGENT_DIR}/claude-statusline.sh" << 'PYEOF' || echo "claude-settings-sync: the status line was not synced"
import json, os, sys, tempfile
path, cmd = sys.argv[1], sys.argv[2]
try:
    s = json.load(open(path)) if os.path.exists(path) else {}
except ValueError as e:
    print(f"claude-settings-sync: {path} is not valid JSON, the status line step left it alone ({e})")
    sys.exit(0)
if not isinstance(s, dict):
    sys.exit(0)
if s.get("statusLine"):
    mine = isinstance(s["statusLine"], dict) and s["statusLine"].get("command") == cmd
    print(f"claude-settings-sync: status line {'already ' + cmd if mine else 'of the user kept'}")
    sys.exit(0)
s["statusLine"] = {"type": "command", "command": cmd}
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
print(f"claude-settings-sync: status line set to {cmd}")
PYEOF

# github and context7: each plugin whose MCP server needs a credential follows it - github a token, context7 an
# explicit CONTEXT7_PLUGIN=true (its remote MCP asks for an OAuth sign-in, run /mcp; the sign-in persists in the
# agent state)
GITHUB_TOKEN_SET=false
[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}" ] && GITHUB_TOKEN_SET=true
CONTEXT7_WANTED=false
[ "${CONTEXT7_PLUGIN:-false}" == "true" ] && CONTEXT7_WANTED=true
python3 - "${CLAUDE_DIR}/settings.json" "${GITHUB_TOKEN_SET}" "${CONTEXT7_WANTED}" << 'PYEOF' || echo "claude-settings-sync: the plugin gates were not synced"
import json, os, sys, tempfile
path = sys.argv[1]
gates = [("github@claude-plugins-official", "GitHub plugin", sys.argv[2] == "true",
          "a GitHub token is set", "no GH_TOKEN, GITHUB_TOKEN or GITHUB_PERSONAL_ACCESS_TOKEN set"),
         ("context7@claude-plugins-official", "context7 plugin", sys.argv[3] == "true",
          "CONTEXT7_PLUGIN=true (sign in with /mcp)", "CONTEXT7_PLUGIN is not true - its MCP server needs an OAuth sign-in")]
try:
    s = json.load(open(path))
except FileNotFoundError:
    sys.exit(0)
except ValueError as e:
    print(f"claude-settings-sync: {path} is not valid JSON, the plugin gates left it alone ({e})")
    sys.exit(0)
ep = s.get("enabledPlugins") if isinstance(s, dict) else None
if not isinstance(ep, dict):
    sys.exit(0)
changed = False
for key, label, want, why_on, why_off in gates:
    if key not in ep:
        continue  # not installed: nothing to gate
    if ep[key] is want:
        print(f"claude-settings-sync: {label} already {'enabled' if want else 'disabled'} ({why_on if want else why_off})")
        continue
    ep[key] = want
    changed = True
    print(f"claude-settings-sync: {label} {'enabled - ' + why_on if want else 'disabled - ' + why_off}")
if changed:
    mode = os.stat(path).st_mode & 0o777
    fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w") as f:
        json.dump(s, f, indent=2)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)
PYEOF

# skills: the image's skills and commands, where Claude Code reads them
"${AGENT_DIR}/claude-skills-sync.sh" || echo "claude-settings-sync: the harness's skills and commands were not all synced"

# memory: Claude Code's own auto-memory follows AGENT_MEMORY (docs/manual/memory.md "Agent memory")
python3 "${AGENT_DIR}/claude-memory-settings.py" "${CLAUDE_DIR}/settings.json" || echo "claude-settings-sync: the auto-memory setting was not synced"

# overlay: the stub at the fires' working directory when the operator has not written the overlay yet (AGENT_OVERLAY)
"${AGENT_DIR}/claude-overlay.sh" || echo "claude-settings-sync: the overlay stub was not synced"
exit 0
