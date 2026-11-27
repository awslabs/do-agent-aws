#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Version of kubectl to install: the newest patch of the 1.36 line (v1.36.6, stable-1.36 on 2026-11-09) - v1.36.0's Go 1.26.2
# and libraries carried 28 HIGH findings in the CVE scan (docs/manual/supply-chain.md "CVE scan"). v1.37.2 was measured too: it carries the
# same 3 HIGH (golang.org/x/net, x/text) and would change the client minor against the clusters the harness talks to
KUBECTL_VERSION=v1.36.6

echo ""
echo "Installing kubectl ${KUBECTL_VERSION} ..."


ARCH=$(uname -m)
if [ "$ARCH" == "aarch64" ]; then
  GOARCH=arm64
else
  GOARCH=amd64
fi

OS=$(uname)
OS_LOWER=$(echo $OS | tr '[:upper:]' '[:lower:]')

# Install kubectl
# Reference: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
# curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
URL=https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS_LOWER}/${GOARCH}/kubectl
echo "$URL"
# -f: a mistyped version must fail here, not store the 404 page as kubectl; the binary is checked against the release's own
# sha256 (published beside it), and a mismatch or a failed fetch fails the installer
curl -fsSLo kubectl "$URL" || exit 1
echo "$(curl -fsSL "${URL}.sha256")  kubectl" | sha256sum -c - || exit 1
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin
kubectl version --client

