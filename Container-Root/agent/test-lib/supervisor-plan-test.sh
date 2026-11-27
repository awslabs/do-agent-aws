#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# supervisor-plan-test.sh - the offline test of the supervisor mode's planner (G99, DESIGN.md section 12).
#
# Runs supervisor-plan.py --selftest (the fixture: three independent goals, a two-goal serial chain, one high-priority
# goal last in the file, a done line and a fenced `- [ ]` to ignore; locks, parking, explicit markers, --set-priority's
# one-line edit and its mirror-key invariant, the json plan), then the planner on the real goals file when one exists,
# read-only. Needs no model, no Slack, no network. Exit 0 = every check passed.
#
#   test-lib/supervisor-plan-test.sh [OUT_FILE]      # OUT_FILE gets the captured output (default: stdout only)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
planner="$here/../supervisor-plan.py"
out="${1:-}"
goals="${AUTONOMY_LOOP_GOALS:-/wd/goals/GOALS.md}"
notes="${AUTONOMY_LOOP_DIR:-/wd/loop}/notes.md"

run() {
  echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) supervisor-plan-test: $planner"
  echo "== python3 -I $planner --selftest"
  python3 -I "$planner" --selftest
  local rc=$?
  echo "== selftest rc=$rc"
  if [ -f "$goals" ]; then
    echo "== read-only plan of the live goals file: $goals (notes: $notes)"
    python3 -I "$planner" --goals "$goals" --notes "$notes" --max-workers "${SUPERVISOR_MAX_WORKERS:-3}" --explain
    echo "== live plan rc=$?"
  fi
  echo "== EXIT=$rc"
  return $rc
}

if [ -n "$out" ]; then
  run 2>&1 | tee "$out"
  exit "${PIPESTATUS[0]}"
fi
run
