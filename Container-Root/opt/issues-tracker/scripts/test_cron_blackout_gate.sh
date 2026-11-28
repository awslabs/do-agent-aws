#!/usr/bin/env bash
set -uo pipefail
REAL_CRON="$(cd "$(dirname "$0")" && pwd)/cron-agent-loop.sh"
fails=0

drive_case() {
  local scan_rc="$1"
  local proj; proj="$(mktemp -d "${TMPDIR:-/tmp}/cron-gate-XXXXXX")"
  mkdir -p "$proj/scripts" "$proj/dashboard/cron"
  cat > "$proj/scripts/gh-dashboard.py" <<PY
import sys
print("SCAN BLOCKED" if $scan_rc == 3 else "wrote dashboard/DASHBOARD.md + state.json")
sys.exit($scan_rc)
PY
  cat > "$proj/scripts/agent-loop.sh" <<SH
#!/usr/bin/env bash
echo RAN > "$proj/dashboard/loop-ran.marker"
SH
  chmod +x "$proj/scripts/agent-loop.sh"
  local tmp_cron="$proj/cron.sh"
  sed "s#^PROJECT=.*#PROJECT=$proj#" "$REAL_CRON" > "$tmp_cron"
  chmod +x "$tmp_cron"
  LOOP_LOCK="$proj/cron.lock" bash "$tmp_cron" >/dev/null 2>&1
  [ -f "$proj/dashboard/loop-ran.marker" ] && echo RAN || echo SKIPPED
  rm -rf "$proj"
}

got="$(drive_case 3)"
if [ "$got" = "SKIPPED" ]; then
  echo "PASS test_blackout_skips_loop (scan exit 3 -> $got)"
else
  echo "FAIL test_blackout_skips_loop: expected SKIPPED, got $got"; fails=$((fails+1))
fi

got="$(drive_case 0)"
if [ "$got" = "RAN" ]; then
  echo "PASS test_healthy_scan_drives_loop (scan exit 0 -> $got)"
else
  echo "FAIL test_healthy_scan_drives_loop: expected RAN, got $got"; fails=$((fails+1))
fi


if grep -qE '^PROJECT=.*\$\{ISSUES_PROJECT' "$REAL_CRON" && ! grep -qE '^PROJECT=/' "$REAL_CRON"; then
  echo "PASS test_project_path_is_derived_not_hardcoded"
else
  echo "FAIL test_project_path_is_derived_not_hardcoded: PROJECT= must derive from ISSUES_PROJECT or the script dir"; fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS (3/3)"; exit 0
else echo "$fails FAILED"; exit 1; fi
