#!/bin/bash

set -uo pipefail

LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/session-start-dashboard.log"
mkdir -p "$LOG_DIR"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "--- $ts session-start-dashboard ---" >> "$LOG_FILE"

SITE_CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/scripts/session-start.local.sh"
if [ -x "$SITE_CHECK" ]; then
    "$SITE_CHECK" 2>&1 >>"$LOG_FILE" | head -5 >&2 || true
fi

AUDIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/gh-comment-audit"
[ -x "$AUDIT" ] || AUDIT="$(command -v gh-comment-audit 2>/dev/null || true)"
if [ -x "$AUDIT" ]; then
    audit_out=$("$AUDIT" --days 1 2>>"$LOG_FILE" || true)
    echo "$audit_out" >> "$LOG_FILE"

    nonzero=$(printf '%s\n' "$audit_out" \
        | awk '/^[[:space:]]+[A-Za-z][^:]*[[:space:]][1-9][0-9]*[[:space:]]*$/' \
        || true)

    if [ -n "$nonzero" ]; then
        echo "WARN gh-comment-audit found noise in last 24h:" >&2
        printf '%s\n' "$nonzero" | head -5 | while read -r line; do
            echo "  $line" >&2
        done
        printf '%s\n' "$audit_out" | grep -oE 'https://github\.com/[^ )]+' | sort -u | head -3 | while read -r url; do
            echo "  $url" >&2
        done
    fi
fi

exit 0
