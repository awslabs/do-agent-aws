#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# issues spoke - the PreToolUse hook of its session (pane.sh registers it in the session's .claude/settings.json for
# Bash, the file-writing tools and the GitHub plugin's tools). The session drafts and never posts. Exit 2 refuses the
# call, with the reason on stderr; any failure of this hook refuses it too (the settings run it as `... || exit 2`).
#   1. A file-writing tool (Write, Edit, MultiEdit, NotebookEdit) aimed at a protected path is refused: the cycle's gh
#      shim and post.sh's private copy (ISSUES_SPOKE_PRIVATE_DIR), the gate directory, gate.log, the session's own
#      settings (.claude), the GO files in the outbox, the vendored tracker (ISSUES_TRACKER_DIR) and the agent tree
#      (/agent) are never the session's to write. Paths are resolved with realpath, so a symlink cannot dodge the
#      check. The session still writes its drafts and records in the outbox and its STATUS.
#   2. A call that carries the operator token GH_WRITE_OPERATOR_OK (a person's words, never the session's), runs post.sh
#      (a person runs it at a terminal), names a GO file (the person's) or reads the tmux server's environment
#      (show-environment) is refused; so is a Bash command whose text names the shim, the gate or the private directory
#      (a prompt-approved cp/printf/mv/ln into them would otherwise pass, since every session runs as root).
#   3. Every other call is handed to the vendored issues tracker's block-gh-write.sh, which refuses each GitHub write
#      form and the GitHub plugin's write tools; its home is a throwaway /tmp directory and its audit line survives in
#      the private directory, never the image's tree or the session's reach. Without the vendored tree, the deny rules
#      of the session's settings stay the wall.
# Environment: ISSUES_SPOKE_WD (the spoke's working directory, default the current one), ISSUES_SPOKE_PRIVATE_DIR
# (default ${SUPERVISOR_DIR}/issues/private), ISSUES_TRACKER_DIR (default /opt/issues-tracker).
set -uo pipefail
WD="${ISSUES_SPOKE_WD:-$(pwd)}"
TREE="${ISSUES_TRACKER_DIR:-/opt/issues-tracker}"
PRIV="${ISSUES_SPOKE_PRIVATE_DIR:-${SUPERVISOR_DIR:-/wd/supervisor}/issues/private}"
IN=$(cat)
block() { echo "issues session: BLOCKED - $1" >&2; exit 2; }

# 1. a file-writing tool aimed at a protected path. The check runs in python (-I) so a planted module cannot change it;
#    the tool call is passed in the environment, never on the argument list. Targets and bases are resolved with
#    realpath so a symlink into a protected directory is caught.
REASON=$(ISSUES_HOOK_IN="${IN}" ISSUES_WD="${WD}" ISSUES_PRIV="${PRIV}" ISSUES_TREE="${TREE}" python3 -I - << 'PYEOF'
import json, os, sys
try:
    d = json.loads(os.environ["ISSUES_HOOK_IN"])
except Exception:
    print("the hook input is not a tool call")
    sys.exit(0)
tool = d.get("tool_name") or ""
ti = d.get("tool_input") if isinstance(d.get("tool_input"), dict) else {}
if tool not in {"Write", "Edit", "MultiEdit", "NotebookEdit"}:
    sys.exit(0)
wd = os.path.realpath(os.environ["ISSUES_WD"])
priv = os.path.realpath(os.environ["ISSUES_PRIV"])
tree = os.path.realpath(os.environ["ISSUES_TREE"])
paths = [ti[k] for k in ("file_path", "notebook_path", "path") if isinstance(ti.get(k), str)]
# the configured tracker directory and its fixed default (the deny rule names the fixed /opt/issues-tracker); the fixed
# bases are realpath'd too, so a symlinked /opt/issues-tracker or /agent is resolved the same way as the targets
bad = [priv, wd + "/.gh-front", wd + "/gate", wd + "/gate.log", wd + "/.claude", tree,
       os.path.realpath("/opt/issues-tracker"), os.path.realpath("/agent")]
def under(p, base):
    return p == base or p.startswith(base + "/")
for p in paths:
    ap = os.path.realpath(p if p.startswith("/") else os.path.join(wd, p))
    for b in bad:
        if under(ap, b):
            print("a file-writing tool aimed at a protected path (%s): the shim, the gate, the session's settings, the tracker and the agent tree are not this session's to write" % p)
            sys.exit(0)
    if under(ap, wd + "/outbox") and os.path.basename(ap).endswith(".GO"):
        print("a GO file is the person's: this session neither writes nor reads one")
        sys.exit(0)
sys.exit(0)
PYEOF
) || block "the hook could not read the tool call"
[ -n "${REASON}" ] && block "${REASON}"

# 2. the string gates on the tool_input, whatever the tool. These read the whole tool input, so a draft whose text
#    quotes one of them is refused too; that over-block is deliberate - a draft never needs the operator token, a GO
#    filename, post.sh or the server's environment in its body.
CALL=$(printf '%s' "${IN}" | python3 -I -c 'import json, sys; print(json.dumps(json.load(sys.stdin).get("tool_input") or {}))' 2>/dev/null) \
	|| block "the hook's input is not a tool call"
case "${CALL}" in
	*GH_WRITE_OPERATOR_OK*) block "the operator token is a person's words, never this session's: stage the draft and tell agent its sha256" ;;
	*post.sh*) block "post.sh is run by a person at a terminal, never by this session" ;;
	*.GO*) block "a GO file is the person's: this session neither writes nor reads one" ;;
	*show-environment*|*showenv*) block "the tmux server's environment is not this session's to read" ;;
esac
# a Bash command whose text names the shim, the gate, gate.log or the private directory by a common spelling: the shim
# directory (gh-front), the private directory (issues/private or the resolved PRIV), gate.log, the working gate, or the
# SUPERVISOR_DIR variable a path could expand through. Only Bash's command field is matched (a draft that quotes these
# is not refused), and /./ and // are collapsed until neither is left, so doubled slashes or a repeated /./ inside a
# spelling still match. A prompt-approved cp/printf/mv/ln would otherwise reach them, since every session runs as root.
# A spelling that carries none of these substrings - a glob, or a cd into the directory then a bare relative name - is
# NOT caught here and reaches the session's permission prompt, where a person's decision is the wall. (The agent tree
# and the tracker are not named here: the session runs gh-ro.sh and send-line.sh from the agent tree, which must stay
# allowed.)
CMDF=$(printf '%s' "${IN}" | python3 -I -c 'import json, sys
ti = json.load(sys.stdin).get("tool_input")
c = ti.get("command", "") if isinstance(ti, dict) else ""
print(c if isinstance(c, str) else "")' 2>/dev/null)
while :; do
	NX=${CMDF//\/.\//\/}
	NX=${NX//\/\//\/}
	[ "${NX}" == "${CMDF}" ] && break
	CMDF=${NX}
done
case "${CMDF}" in
	*gh-front*|*issues/private*|*gate.log*|*SUPERVISOR_DIR*|*"${PRIV}"*|*"${WD}/gate"*)
		block "a Bash command naming the shim, the gate, gate.log or the private directory is not this session's to run: those are written only by the cycle and post.sh" ;;
esac

# 3. the vendored tracker's write-blocking hook, with a throwaway /tmp home it removes and an audit line that survives
#    in the private directory, out of the session's reach
H="${TREE}/.claude/hooks/block-gh-write.sh"
[ -f "${H}" ] || exit 0
HH=$(mktemp -d -p /tmp 2>/dev/null)
[ -n "${HH}" ] || block "the hook could not make a working directory"
trap 'rm -rf "${HH:?}"' EXIT
mkdir -p "${PRIV}/gate" 2>/dev/null
printf '%s' "${IN}" | env -u GH_WRITE_OPERATOR_OK HOME="${HH}" GH_WRITE_AUDIT_LOG="${PRIV}/gate/gh-write-audit.log" bash "${H}" \
	|| exit 2
