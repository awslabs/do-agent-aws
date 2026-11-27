#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing Headlamp ..."

# Headlamp (github.com/kubernetes-sigs/headlamp) is the Kubernetes web UI the agent
# harness uses as its cluster dashboard. Upstream publishes the server only inside the
# official container image (the GitHub release assets are desktop builds), so extract
# headlamp-server and its frontend from the image with crane.
# v0.46.0 (2026-10-15) is built with Go 1.26.8; v0.45.0's Go 1.26.7 and libraries (grpc, x/crypto, x/net, x/text, compress)
# carried 10 HIGH findings in the CVE scan (docs/manual/supply-chain.md "CVE scan"), 6 remain
export HEADLAMP_VERSION=v0.46.0

mkdir -p /opt/headlamp
crane export ghcr.io/headlamp-k8s/headlamp:${HEADLAMP_VERSION} - \
	| tar -x -C /opt/headlamp --strip-components=1 \
		headlamp/headlamp-server headlamp/frontend headlamp/plugins headlamp/static-plugins

ls -la /opt/headlamp/headlamp-server
