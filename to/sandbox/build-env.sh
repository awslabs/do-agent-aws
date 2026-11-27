# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash disable=SC2034  # the SBX_ variables are read by the scripts that source this
# Sourced by to/sandbox/test/test2.sh and to/sandbox/push-kit.sh: the kit build
# environment. The kit build runs the harness's upstream installers with network
# access, so it runs in a buildx builder (docker-container driver) attached to
# one Docker network only, and while it runs a DOCKER-USER rule (sudo iptables)
# drops that network's traffic to the EC2 instance metadata service
# (169.254.169.254, the source of the host's instance-role credentials).
#
# sbx_build_env_up proves the block with a probe build step, which must run (its
# marker line is required): the service must answer before the rule (401, the
# positive control) and must not answer after it. Each run tags its rule
# do-agent-aws-sandbox:build:<network>:<run id> and sbx_build_env_down removes
# that rule only, then clears the tag, so a second call is a no-op and never
# touches another run's rule. Builds are serialized with a lock (SBX_BUILD_LOCK).
# A tagged rule is removed as stale only when its network no longer exists; a
# stale rule for the build network itself stays (it only blocks) until removed
# by hand: to/sandbox/README.md "Validate without sign-in".
#
# On a host without a metadata service the control cannot answer; set
# SBX_ALLOW_NO_IMDS=1 there to accept a control without an answer (logged).

SBX_BUILD_NET=${SBX_BUILD_NET:-do-agent-aws-sandbox-build}
SBX_BUILDER=${SBX_BUILDER:-do-agent-aws-sandbox-imds-blocked}
# The kit frontend, pinned (docker/sandbox-kit:3 = 3.0.0-m.8 on 2026-10-07). The
# descriptor keeps the literal "# syntax=docker/sandbox-kit:3" line the
# specification dispatches on; BUILDKIT_SYNTAX overrides it for the build.
SBX_KIT_FRONTEND=${SBX_KIT_FRONTEND:-docker/sandbox-kit:3@sha256:e6a397771e865625047cf84256a914c7974b3e749d858259b5bc9c653ddb6f0d}
SBX_PROBE_IMAGE=busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
SBX_IMDS=169.254.169.254
SBX_TAG_PREFIX=do-agent-aws-sandbox:build
SBX_RULE_TAG=""
SBX_BUILD_LOCK=${SBX_BUILD_LOCK:-${SBX_DIR:?build-env.sh needs SBX_DIR}/app/.build.lock}
SBX_BUILD_SUBNET=""
SBX_IMDS_BEFORE=""
SBX_IMDS_AFTER=""
SBX_PROBE_MARKER=""

sbx_imds_rule()
{
	# $1 = -I | -C | -D
	sudo -n iptables "$1" DOCKER-USER -s "${SBX_BUILD_SUBNET}" -d "${SBX_IMDS}/32" -m comment --comment "${SBX_RULE_TAG}" -j DROP
}

sbx_drop_rules_tagged()
{
	# $1 = exact tag; removes every DOCKER-USER rule carrying it (iptables -S
	# prints the comment quoted)
	local r
	sudo -n iptables -S DOCKER-USER | grep -F -- "\"$1\"" | sed 's/^-A /-D /' | while read -r r; do
		eval "sudo -n iptables ${r}"
	done
}

sbx_drop_stale_build_rules()
{
	# removes build-tagged rules whose network no longer exists
	local r net
	sudo -n iptables -S DOCKER-USER | grep -F -- "\"${SBX_TAG_PREFIX}:" | while read -r r; do
		net=$(echo "${r}" | sed -n "s/.*\"${SBX_TAG_PREFIX}:\([^:\"]*\):[^\"]*\".*/\1/p")
		[ -n "${net}" ] || continue
		docker network inspect "${net}" > /dev/null 2>&1 && continue
		eval "sudo -n iptables ${r/#-A /-D }"
	done
}

sbx_imds_probe_build()
{
	# Prints "<status> <marker>": the HTTP status of the metadata service as a
	# build step in the builder sees it (000: no answer; IMDSv2 answers 401, no
	# token is requested) and whether the step's marker line was seen (ran or
	# missing - a probe that never ran must not read as a block). The marker,
	# IMDS-PROBE-RAN-<nonce>, is assembled by printf in the step, so only the
	# step's output can match it, never the build's echo of the command; only
	# output lines of the step ("#<n> <seconds> ...") are read. They are copied
	# to stderr for the log.
	local d out code marker=missing nonce
	nonce=$(date -u +%s%N)
	d=$(mktemp -d)
	printf 'FROM %s\nRUN printf "IMDS-PROBE-%%s-%%s\\n" RAN %s; wget -q -S -T 3 -O /dev/null http://%s/latest/meta-data/ 2>&1 | sed -n "s/^ *HTTP\\/[0-9.]* \\([0-9][0-9]*\\).*/IMDS-PROBE-STATUS \\1/p" | head -1\n' \
		"${SBX_PROBE_IMAGE}" "${nonce}" "${SBX_IMDS}" > "${d}/Dockerfile"
	out=$(docker buildx build --builder "${SBX_BUILDER}" --no-cache --progress plain "${d}" 2>&1)
	rm -rf "${d}"
	echo "${out}" | grep -E "^#[0-9]+ [0-9.]+ IMDS-PROBE-(RAN-${nonce}|STATUS [0-9]+)\$" >&2
	echo "${out}" | grep -qE "^#[0-9]+ [0-9.]+ IMDS-PROBE-RAN-${nonce}\$" && marker=ran
	code=$(echo "${out}" | sed -n 's/^#[0-9]* [0-9.]* IMDS-PROBE-STATUS \([0-9][0-9]*\)$/\1/p' | head -1)
	echo "${code:-000} ${marker}"
}

sbx_build_env_up()
{
	local cname nets probe
	sudo -n iptables -S DOCKER-USER > /dev/null 2>&1 \
		|| { echo "build-env: blocking the metadata service needs passwordless sudo iptables and Docker's DOCKER-USER chain"; return 1; }
	mkdir -p "$(dirname "${SBX_BUILD_LOCK}")"
	exec 8> "${SBX_BUILD_LOCK}"
	flock -w 3600 8 || { echo "build-env: another kit build holds ${SBX_BUILD_LOCK}"; return 1; }
	sbx_drop_stale_build_rules
	docker network inspect "${SBX_BUILD_NET}" > /dev/null 2>&1 \
		|| docker network create --driver bridge "${SBX_BUILD_NET}" > /dev/null \
		|| { echo "build-env: cannot create network ${SBX_BUILD_NET}"; return 1; }
	SBX_BUILD_SUBNET=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${SBX_BUILD_NET}" | tr ' ' '\n' | grep -E '^[0-9.]+/[0-9]+$' | head -1)
	[ -n "${SBX_BUILD_SUBNET}" ] || { echo "build-env: no IPv4 subnet on ${SBX_BUILD_NET}"; return 1; }
	if ! docker buildx inspect "${SBX_BUILDER}" > /dev/null 2>&1; then
		docker buildx create --name "${SBX_BUILDER}" --driver docker-container --driver-opt "network=${SBX_BUILD_NET}" > /dev/null \
			|| { echo "build-env: cannot create builder ${SBX_BUILDER}"; return 1; }
	fi
	docker buildx inspect --bootstrap "${SBX_BUILDER}" > /dev/null 2>&1 || { echo "build-env: builder ${SBX_BUILDER} does not start"; return 1; }
	cname=buildx_buildkit_${SBX_BUILDER}0
	nets=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "${cname}" 2> /dev/null | xargs)
	[ "${nets}" = "${SBX_BUILD_NET}" ] \
		|| { echo "build-env: builder ${SBX_BUILDER} must be attached to ${SBX_BUILD_NET} only (it is on: ${nets:-none}); remove it (docker buildx rm ${SBX_BUILDER}) and run again"; return 1; }
	probe=$(sbx_imds_probe_build)
	SBX_IMDS_BEFORE=${probe% *}
	echo "build-env: control probe, before the rule: HTTP ${SBX_IMDS_BEFORE}, step ${probe#* }"
	[ "${probe#* }" = "ran" ] || { echo "build-env: the control probe step did not run"; return 1; }
	if [ "${SBX_IMDS_BEFORE}" != "401" ]; then
		[ "${SBX_ALLOW_NO_IMDS:-}" = "1" ] && [ "${SBX_IMDS_BEFORE}" = "000" ] \
			|| { echo "build-env: the metadata service did not answer the control probe (${SBX_IMDS_BEFORE}, expected 401), so a block cannot be shown; on a host without one set SBX_ALLOW_NO_IMDS=1"; return 1; }
		echo "build-env: no metadata service answered the control probe (SBX_ALLOW_NO_IMDS=1)"
	fi
	SBX_RULE_TAG=${SBX_TAG_PREFIX}:${SBX_BUILD_NET}:$(date -u +%Y%m%dT%H%M%SZ)-$$
	sbx_imds_rule -I || { echo "build-env: cannot add the DOCKER-USER rule for ${SBX_BUILD_SUBNET}"; return 1; }
	probe=$(sbx_imds_probe_build)
	SBX_IMDS_AFTER=${probe% *}
	SBX_PROBE_MARKER=${probe#* }
	echo "build-env: probe under the rule ${SBX_RULE_TAG}: HTTP ${SBX_IMDS_AFTER}, step ${SBX_PROBE_MARKER}"
	[ "${SBX_PROBE_MARKER}" = "ran" ] || { echo "build-env: the probe step under the rule did not run"; return 1; }
	[ "${SBX_IMDS_AFTER}" = "000" ] || { echo "build-env: the metadata service still answers (${SBX_IMDS_AFTER}) from a build step"; return 1; }
	return 0
}

sbx_build_env_down()
{
	# Removes this run's rule only; a second call is a no-op.
	[ -n "${SBX_RULE_TAG}" ] || return 0
	sbx_drop_rules_tagged "${SBX_RULE_TAG}"
	if sudo -n iptables -S DOCKER-USER | grep -qF -- "\"${SBX_RULE_TAG}\""; then
		echo "build-env: the DOCKER-USER rule tagged ${SBX_RULE_TAG} is still present"
		return 1
	fi
	SBX_RULE_TAG=""
	SBX_BUILD_SUBNET=""
	exec 8>&-
	return 0
}
