#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing nodejs ..."

export NVM_VERSION=v0.41.0
# ONE node tree, the pinned release: nvm's installer below installs NODE_VERSION itself when it is exported (and makes it the
# default), and the `nvm install 24` that followed it had put the newest 24.x beside it as a SECOND tree that nothing used and whose
# bundled npm carried CVE findings of its own (undici, brace-expansion: 4 HIGH in the CVE scan, docs/manual/supply-chain.md "CVE scan"). The pin is
# the newest 24 LTS release when it was last moved; harden.sh moves the one tree's npm to its pin afterwards
export NODE_VERSION=v24.22.3
export NPM_VERSION=11.19.1

# Download and install nvm:
# nvm's installer at the pinned tag, checked against its sha256 before it runs (never piped into a shell); nvm then
# checks each Node.js download against nodejs.org's SHASUMS256.txt itself
NVM_INSTALL_SHA256=045932fe05f0d4247c946f2ec0ec4026dbfd8ce88a5f67ea28d8ea833227f48b
NVM_T=$(mktemp -d)
curl -fsSL -o "${NVM_T}/install.sh" "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" || exit 1
echo "${NVM_INSTALL_SHA256}  ${NVM_T}/install.sh" | sha256sum -c - || exit 1
bash "${NVM_T}/install.sh" || exit 1
rm -rf "${NVM_T:?}"

# in lieu of restarting the shell
\. "$HOME/.nvm/nvm.sh"

echo 'export NVM_DIR="$HOME/.nvm"' >> ${HOME}/.bashrc
echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> ${HOME}/.bashrc  # This loads nvm
echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' >> ${HOME}/.bashrc  # This loads nvm bash_completion

# Download and install Node.js: the pinned release (nvm's installer above already did, which this makes explicit), the default
nvm install ${NODE_VERSION}
nvm alias default ${NODE_VERSION}

# Verify: one tree, and it is the pinned release
node -v # Should print "${NODE_VERSION}".
[ "$(node -v)" == "${NODE_VERSION}" ] || { echo "install-nodejs.sh: node is $(node -v), not ${NODE_VERSION}"; exit 1; }
[ "$(ls "${NVM_DIR:-$HOME/.nvm}/versions/node" | wc -l)" == "1" ] || { echo "install-nodejs.sh: more than one node tree under nvm: $(ls "${NVM_DIR:-$HOME/.nvm}/versions/node" | tr '\n' ' ')"; exit 1; }

# Verify npm version (the bundled one; harden.sh upgrades it):
npm -v # Should print "${NPM_VERSION}".

