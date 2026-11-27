#!/bin/bash

set -uo pipefail

LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/pretooluse-block-comment-noise.log"
mkdir -p "$LOG_DIR"

payload=$(cat)
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if command -v jq >/dev/null 2>&1; then
    cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
    cmd=$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("tool_input",{}).get("command",""))
except Exception:
    pass' 2>/dev/null)
fi

if ! printf '%s' "$cmd" | grep -qE 'gh[[:space:]]+(pr|issue)[[:space:]]+comment\b'; then
    exit 0
fi

body=""
body_file=""

body=$(printf '%s' "$cmd" | python3 -c '
import re,sys
c = sys.stdin.read()
m = re.search(r"""(?:--body|(?<![\w-])-b)[ =]+(?P<q>["'"'"'])(?P<v>.*?)(?<!\\)(?P=q)""", c, re.DOTALL)
if m:
    print(m.group("v"))
' 2>/dev/null)

if [ -z "$body" ]; then
    body_file=$(printf '%s' "$cmd" | python3 -c '
import re,sys
c = sys.stdin.read()
m = re.search(r"(?:--body-file|(?<![\w-])-F)[ =]+(\S+)", c)
if m:
    print(m.group(1).strip("\"'"'"'"))
' 2>/dev/null)
    if [ -n "$body_file" ] && [ -f "$body_file" ]; then
        body=$(cat "$body_file" 2>/dev/null || true)
    fi
fi

if [ -z "$body" ]; then
    echo "$ts allow:no-body cmd=$cmd" >> "$LOG_FILE"
    exit 0
fi

log_decision() {
    local decision="$1"; shift
    local reason="$*"
    {
        echo "--- $ts $decision ---"
        echo "reason: $reason"
        echo "cmd: $cmd"
        echo "body:"
        printf '%s\n' "$body"
        echo
    } >> "$LOG_FILE"
}

SITE_FILE="${SHIPPED_TREE_DENYLIST_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/scripts/test_shipped_tree.local.conf}"
site_value() { [ -f "$SITE_FILE" ] && sed -n "s/^$1=\"\\(.*\\)\"[[:space:]]*\$/\\1/p" "$SITE_FILE" | head -1; }
noise_re=$(site_value NOISE_REGEX || true)
[ -n "$noise_re" ] || noise_re='(close|closing)[^.]{0,80}[0-9]+ ?days|[0-9]+ ?days[^.]{0,80}(close|closing)'
if printf '%s' "$body" | grep -qiE "$noise_re"; then
    log_decision BLOCK "noise pattern"
    echo "BLOCKED by .claude/hooks/pretooluse-block-comment-noise.sh: the comment matches the noise pattern (NOISE_REGEX in the site file, else the built-in N-days form). Refusing to post. Rewrite the comment with concrete technical content; closing a PR is a human's decision." >&2
    exit 2
fi

warn_re=$(site_value WARN_REGEX || true)
if [ -n "$warn_re" ] && printf '%s' "$body" | grep -qiE "$warn_re"; then
    matched=$(printf '%s' "$body" | grep -iE "$warn_re" | head -3)
    log_decision WARN "warn pattern"
    {
        echo "WARN .claude/hooks/pretooluse-block-comment-noise.sh: the comment matches the site warn pattern (WARN_REGEX)."
        echo "matched lines:"
        printf '%s\n' "$matched" | sed 's/^/  /'
        echo "is this what you intended?"
    } >&2
    exit 0
fi

log_decision allow "no pattern match"
exit 0
