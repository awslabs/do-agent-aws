#!/usr/bin/env bash
set -uo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
PROJECT="${ISSUES_PROJECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOCK="${LOOP_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/gh-agent-loop-$(id -u).lock}"
LOG_DIR="$PROJECT/dashboard/cron"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date -u +%F).log"

{
  echo "=== cron wake $(date -u +%FT%TZ) ==="
  command -v flock >/dev/null 2>&1 || { echo "flock not installed — aborting"; exit 1; }
  flock -n 9 || { echo "previous run still holds the lock — skipping"; exit 0; }

  cd "$PROJECT" || { echo "[cron] cd $PROJECT failed — aborting"; exit 1; }

  python3 scripts/gh-dashboard.py --open-only 2>&1 | tail -5
  SCAN_RC=${PIPESTATUS[0]}

  if [ "$SCAN_RC" = "3" ]; then
    echo "[cron] scan BLOCKED (coverage 0) — preserved last-known-good state.json;"
    echo "[cron] skipping agent-loop this wake (gh api blackout). See loop-log.jsonl ops record."
    echo "=== cron done $(date -u +%FT%TZ) (scan-blocked) ==="
    exit 0
  fi

  ./scripts/agent-loop.sh --max 2

  echo "=== cron done $(date -u +%FT%TZ) ==="
} >> "$LOG" 2>&1 9>"$LOCK"
