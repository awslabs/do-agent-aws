#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCAN="$HERE/scripts/redact-scan.sh"
[ -d "$HERE/scratch" ] && HAD_SCRATCH=1 || HAD_SCRATCH=0
FIX="$HERE/scratch/redact-scan-generic-test.$$"
mkdir -p "$FIX"
trap 'rm -rf "${FIX:?}"; [ "$HAD_SCRATCH" = 1 ] || rmdir "$HERE/scratch" 2>/dev/null' EXIT
pass=0; fail=0
export REDACT_DENYLIST_FILE="$FIX/does-not-exist.conf"

expect() {
  local name=$1 mode=$2 want_rc=$3 want_marker=$4 text=$5
  local f="$FIX/$name.txt" out rc
  printf '%s\n' "$text" > "$f"
  if [ "$mode" = strict ]; then out=$("$SCAN" --strict "$f" 2>&1); rc=$?
  else out=$("$SCAN" "$f" 2>&1); rc=$?; fi
  if [ "$rc" = "$want_rc" ] && printf '%s\n' "$out" | grep -q -- "$want_marker"; then
    pass=$((pass+1)); echo "ok   $name"
  else
    fail=$((fail+1)); echo "FAIL $name (mode=$mode rc=$rc want_rc=$want_rc want_marker=$want_marker)"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

echo "--- generic BLOCK classes (no site file) ---"
expect generic_account_id      plain 1 REDACT-BLOCK 'account 1234567''89012'
expect generic_aws_access_key  plain 1 REDACT-BLOCK 'key AKIA''ABCDEFGHIJKLMNOP'
expect generic_github_pat      plain 1 REDACT-BLOCK 'token ghp_''abcdefghijklmnopqrstuvwxyz0123456789'
expect generic_slack_token     plain 1 REDACT-BLOCK 'xoxb''-1234-5678-abcdefgh'

echo "--- generic REVIEW classes (fail under --strict, no site file) ---"
expect generic_home_any_user   strict 1 REDACT-REVIEW 'see /ho''me/alice/notes.md'
expect generic_encoded_home    strict 1 REDACT-REVIEW 'projects/-ho''me-alice-work/memory/MEMORY.md'
expect generic_private_ip      strict 1 REDACT-REVIEW 'peer 10.1''.2.3 timed out'
expect generic_ec2_private_dns strict 1 REDACT-REVIEW 'host ip-10-1''-2-3.us-west-2.compute''.internal'
expect generic_ec2_internal    strict 1 REDACT-REVIEW 'resolved to ip-172-31''-0-9.ec2''.internal'
expect generic_instance_id     strict 1 REDACT-REVIEW 'node i-0123''456789abcdef0 cordoned'
expect generic_review_warns_plain plain 0 REDACT-REVIEW 'see /ho''me/alice/notes.md'

echo "--- missing site file: noted, never silent; generic classes still bind ---"
expect no_site_file_noted         plain 0 'no site denylist' 'plain public text'
expect no_site_file_generic_binds plain 1 REDACT-BLOCK      'account 1234567''89012'

echo "--- site denylist file adds BLOCK and REVIEW lists ---"
cat > "$FIX/site.conf" <<'CONF'
BLOCK_SITE='my-private-ecr-ns|example-org-internal'
CUSTOMER_DENYLIST='\bzorblax\b|\bquuxcorp\b'
REVIEW_SITE='reviewer-handle-x|/opt/example-path-'
INFRA_DENYLIST='mypod-[01]\b|\bmycluster\b'
CONF
REDACT_DENYLIST_FILE="$FIX/site.conf" expect site_block_token      plain  1 REDACT-BLOCK  'image my-private-ecr-ns.dkr.ecr.example'
REDACT_DENYLIST_FILE="$FIX/site.conf" expect site_customer_ci      plain  1 REDACT-BLOCK  'Deployed for Zorblax'
REDACT_DENYLIST_FILE="$FIX/site.conf" expect site_review_handle    strict 1 REDACT-REVIEW 'thanks reviewer-handle-x'
REDACT_DENYLIST_FILE="$FIX/site.conf" expect site_infra_token      strict 1 REDACT-REVIEW 'exec into MYPOD-0 on mycluster'
REDACT_DENYLIST_FILE="$FIX/site.conf" expect site_file_loaded_pass strict 0 REDACT-PASS   'plain public text'

echo "--- negatives: public tokens stay REDACT-PASS even under --strict ---"
expect neg_public_paths      strict 0 REDACT-PASS '/opt/vendor/tool/bin/tool_info and tcp://127.0.0.1:5555'
expect neg_19_digit_code     strict 0 REDACT-PASS 'error 1234567890123456789 returned'
expect neg_short_i_dash      strict 0 REDACT-PASS 'i-am-here, ip-config, i-0c3d'
expect neg_home_word         strict 0 REDACT-PASS 'the home directory concept, and /home alone'

echo "redact-scan generic tests: pass=$pass fail=$fail"
[ "$fail" = 0 ]
