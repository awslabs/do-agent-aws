#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Sandbox test-proxy-env - the sandbox layer's proxy-environment coherence
# (to/sandbox/template/sandbox-persistent.sh), host-side, no Docker/sbx/KVM.
#
# Why it exists: the sbx runtime injects its egress proxy as upper-case
# HTTP_PROXY/HTTPS_PROXY/NO_PROXY. The harness .env also exports empty lower-case
# http_proxy=/https_proxy= (correct on a host with no proxy); carried into the sandbox those
# empty values shadow the upper-case ones for clients that read the lower-case names - Python
# urllib/botocore, which the memory API (hindsight-api) uses - so that client bypasses the
# egress proxy and never receives the proxy-injected Bedrock key (AWS answers 403 "Invalid API
# Key format"). sandbox-persistent.sh (BASH_ENV / profile.d) makes the two cases agree.
#
# Each check FAILS if the fix is removed:
#   1. the committed snippet, sourced under the shadowing env the sandbox sees, makes Python's
#      proxy resolution carry an https proxy equal to HTTPS_PROXY (and http likewise)
#   2. PLANTED CONTROL: an empty stand-in (the pre-fix /etc/sandbox-persistent.sh) under the same
#      env leaves Python with NO https proxy - the bug, proving check 1 is not vacuous
#   3. no proxy set on either side stays unset (a no-op on a host with no proxy, e.g. the docker target)
#   4. the sandbox layer COPYs the snippet to /etc/sandbox-persistent.sh and names it in BASH_ENV
# Needs bash and python3.
set -u
BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SNIP="${BASE_DIR}/to/sandbox/template/sandbox-persistent.sh"
DOCKERFILE="${BASE_DIR}/to/sandbox/template/sandbox.dockerfile"
fail() { echo "Sandbox test-proxy-env FAILED: $1"; exit 1; }
[ -f "${SNIP}" ] || fail "missing ${SNIP}"
[ -f "${DOCKERFILE}" ] || fail "missing ${DOCKERFILE}"

# the shadowing env the sandbox process sees (upper-case set by the runtime, empty lower-case from .env)
SHADOW=(env HTTPS_PROXY=http://gateway.docker.internal:3128 https_proxy=
        HTTP_PROXY=http://gateway.docker.internal:3128 http_proxy=
        NO_PROXY=localhost,127.0.0.1,::1,gateway.docker.internal no_proxy=localhost,127.0.0.1)
getproxies='import urllib.request as u; p=u.getproxies(); import sys; sys.stdout.write(",".join(sorted(k for k in p)))'

# 1. with the fix sourced, https (and http) proxy are present and equal HTTPS_PROXY
out=$("${SHADOW[@]}" bash -c ". '${SNIP}'; python3 -c '${getproxies}'; echo \"|\$https_proxy|\$http_proxy\"")
keys=${out%%|*}; rest=${out#*|}; lp=${rest%%|*}; hp=${rest##*|}
case ",${keys}," in *,https,*) : ;; *) fail "check 1: after sourcing the snippet, Python has no https proxy (keys=${keys})" ;; esac
[ "${lp}" = "http://gateway.docker.internal:3128" ] || fail "check 1: https_proxy not aligned to HTTPS_PROXY (got '${lp}')"
[ "${hp}" = "http://gateway.docker.internal:3128" ] || fail "check 1: http_proxy not aligned to HTTP_PROXY (got '${hp}')"
echo "ok 1 - the snippet aligns the empty lower-case proxy vars to the upper-case ones; Python resolves the https proxy"

# 2. PLANTED CONTROL: the pre-fix empty file leaves the bug in place (no https proxy)
EMPTY=$(mktemp); : > "${EMPTY}"
keys2=$("${SHADOW[@]}" bash -c ". '${EMPTY}'; python3 -c '${getproxies}'")
rm -f "${EMPTY}"
case ",${keys2}," in *,https,*) fail "check 2 (control): an empty persistent file should NOT yield an https proxy, but Python had one (keys=${keys2}) - check 1 would be vacuous" ;; esac
echo "ok 2 - planted control: without the fix (empty file) Python drops the https proxy (the bug), so check 1 is non-vacuous"

# 3. no-op when no proxy is set at all (the docker target)
nop=$(env -i PATH="$PATH" bash -c ". '${SNIP}'; echo \"\${https_proxy-unset}/\${HTTPS_PROXY-unset}\"")
[ "${nop}" = "unset/unset" ] || fail "check 3: with no proxy set, the snippet must change nothing (got '${nop}')"
echo "ok 3 - no proxy set on either side stays unset (no-op on a host without a proxy)"

# 4. the sandbox layer wires the snippet in: COPY to /etc/sandbox-persistent.sh and BASH_ENV names it
grep -Eq '^COPY[[:space:]]+to/sandbox/template/sandbox-persistent\.sh[[:space:]]+/etc/sandbox-persistent\.sh[[:space:]]*$' "${DOCKERFILE}" \
  || fail "check 4: sandbox.dockerfile does not COPY the snippet to /etc/sandbox-persistent.sh"
grep -Eq 'BASH_ENV=/etc/sandbox-persistent\.sh' "${DOCKERFILE}" \
  || fail "check 4: sandbox.dockerfile does not set BASH_ENV=/etc/sandbox-persistent.sh"
echo "ok 4 - the sandbox layer COPYs the snippet to /etc/sandbox-persistent.sh and points BASH_ENV at it"

echo "Sandbox test-proxy-env succeeded"
