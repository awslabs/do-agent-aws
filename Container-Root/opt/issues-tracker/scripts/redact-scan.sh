#!/usr/bin/env bash

set -uo pipefail

STRICT=0
if [ "${1:-}" = "--strict" ]; then STRICT=1; shift; fi
if [ "$#" -lt 1 ]; then
  echo "usage: $(basename "$0") [--strict] <file-or-dir> [more...]" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_FILE="${REDACT_DENYLIST_FILE:-$HERE/redact-denylist.conf}"

GENERIC_BLOCK='\b[0-9]{12}\b|AKIA[0-9A-Z]{16}|ghp_[0-9A-Za-z]{36}|xoxb-[0-9A-Za-z-]+'

GENERIC_REVIEW='\b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b|/home/[[:alnum:]_.-]+/|(^|/)-home-[[:alnum:]_.-]+-|\bip-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}\b|\.compute\.internal\b|\.ec2\.internal\b|\bi-[0-9a-f]{17}\b'

site_var() {
  [ -r "$SITE_FILE" ] || return 0
  sed -n "s/^$1='\(.*\)'[[:space:]]*$/\1/p" "$SITE_FILE" | head -1
}
BLOCK_SITE="$(site_var BLOCK_SITE)"
CUSTOMER_DENYLIST="$(site_var CUSTOMER_DENYLIST)"
REVIEW_SITE="$(site_var REVIEW_SITE)"
INFRA_DENYLIST="$(site_var INFRA_DENYLIST)"
if [ ! -r "$SITE_FILE" ]; then
  echo "REDACT-NOTE: no site denylist loaded at $SITE_FILE (generic classes only; set REDACT_DENYLIST_FILE or copy redact-denylist.example.conf)" >&2
fi

join_alt() {
  local out="" p
  for p in "$@"; do [ -n "$p" ] || continue; out="${out:+$out|}$p"; done
  printf '%s' "$out"
}
BLOCK="$(join_alt "$GENERIC_BLOCK" "$BLOCK_SITE")"
REVIEW="$(join_alt "$GENERIC_REVIEW" "$REVIEW_SITE")"

GREP='grep -rnEI --binary-files=without-match'

block_hits=$($GREP "$BLOCK" "$@" 2>/dev/null)
cust_hits=""
[ -n "$CUSTOMER_DENYLIST" ] && cust_hits=$($GREP -i "$CUSTOMER_DENYLIST" "$@" 2>/dev/null)
block_hits=$(printf '%s\n%s' "$block_hits" "$cust_hits" | sed '/^$/d')
review_hits=$($GREP "$REVIEW" "$@" 2>/dev/null)
infra_hits=""
[ -n "$INFRA_DENYLIST" ] && infra_hits=$($GREP -i "$INFRA_DENYLIST" "$@" 2>/dev/null)
review_hits=$(printf '%s\n%s' "$review_hits" "$infra_hits" | sed '/^$/d')

rc=0
if [ -n "$block_hits" ]; then
  echo "$block_hits"
  echo "REDACT-BLOCK: internal-only tokens above — DO NOT send. Scrub and re-run." >&2
  rc=1
fi
if [ -n "$review_hits" ]; then
  echo "$review_hits"
  if [ "$STRICT" = "1" ]; then
    echo "REDACT-REVIEW (--strict): context-dependent matches above treated as BLOCK." >&2
    rc=1
  else
    echo "REDACT-REVIEW: context-dependent matches above — confirm each is safe for the destination" >&2
    echo "  (author/reviewer handles + log-paste IPs are often legitimate; private DNS hostnames, instance IDs," >&2
    echo "   container/scratch paths and pod/cluster names almost never are; --strict to hard-fail)." >&2
  fi
fi
[ "$rc" = "0" ] && [ -z "$review_hits" ] && echo "REDACT-PASS: clean."
exit "$rc"
