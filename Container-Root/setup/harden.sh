#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Hardening image (CVE cleanup) ..."

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# 1) npm itself: node 24 bundles npm 11.x whose vendored deps carry known CVEs
#    (tar <7.5.19 CVE-2026-59873 CRITICAL, CVE-2026-59874/CVE-2026-73566 HIGH;
#    undici CVE-2026-12151; brace-expansion CVE-2026-13149/-14257/-69152;
#    ip-address CVE-2026-69192). npm 12 ships patched versions of all of them. Pinned: a build installs the npm this
#    tree was tested with (move the pin with npm view npm version, and rebuild; the CVE scan shows what it fixes).
export NPM_HARDEN_VERSION=12.2.3
npm install -g "npm@${NPM_HARDEN_VERSION}" && [ "$(npm -v)" == "${NPM_HARDEN_VERSION}" ] \
    || { echo "harden.sh: FAILED - npm is $(npm -v), not ${NPM_HARDEN_VERSION}"; exit 1; }
echo "npm version: $(npm -v)"

# 2) Installed Claude Code plugins vendor their FULL node_modules including
#    devDependencies (test/build toolchains) that never run in this container:
#    vitest CVE-2026-47429 (CRITICAL), shell-quote CVE-2026-9277 (CRITICAL) /
#    CVE-2026-13311, vite CVE-2026-53571, postcss CVE-2026-73646,
#    nanoid CVE-2026-67213/-67214, js-yaml CVE-2026-59869/GHSA-5p4m-2wfm-xmqj,
#    fast-uri CVE-2026-13676/-16221/-18446. Prune dev deps from every installed
#    plugin; runtime dependencies are left untouched.
for pkg in $(find ${HOME}/.claude/plugins -maxdepth 6 -name package.json -not -path "*/node_modules/*" 2>/dev/null); do
    d=$(dirname "$pkg")
    if [ -d "$d/node_modules" ]; then
        echo "Pruning dev dependencies: $d"
        (cd "$d" && npm prune --omit=dev || true)
    fi
done

# 2b) The runtime dependencies that carry a CVE with a fix inside the range the plugin's own package.json allows move to it, by
#     name (npm update <names>: nothing else changes; the fix lands within a declared range, so the plugin's code sees what it
#     asked for). NAMED, not a blanket `npm update`: a blanket one re-runs the install scripts of every package it touches - in
#     claude-mem's tree that is tree-sitter-sql's, which needs a tree-sitter cli npm 12 no longer downloads (npm 12 runs no
#     install script its allow-scripts setting does not name), so the whole update aborted - and would move native modules
#     (better-sqlite3) without the install script that fetches their binding. Fail loud: a move that did not happen leaves the
#     CVE in the image, and the CVE scan's table (docs/manual/supply-chain.md "CVE scan") would show it.
#     oh-my-claudecode: @modelcontextprotocol/sdk ^1.26 -> 1.32, and through its express the proxy-addr 2.0.8 (CVE-2026-90711
#     CRITICAL) and body-parser 2.4.0 (HIGH) it depends on; zod stays at 3 (its fix is zod 4, outside ^3 - docs/manual/supply-chain.md "CVE scan").
#     claude-mem: zod ^4.4.3 -> 4.6.x (HIGH).
#     Both plugins are installed unconditionally (install-plugins.sh, install-claudemem.sh): a tree that is not where the cache
#     layout puts it is a failure here, not a plugin that is off - a silent skip would leave the CVEs in the image.
OMC_DIR=$(ls -d ${HOME}/.claude/plugins/cache/omc/oh-my-claudecode/*/ 2>/dev/null | head -1)
[ -n "${OMC_DIR}" ] && [ -d "${OMC_DIR}/node_modules" ] \
    || { echo "harden.sh: FAILED - no oh-my-claudecode tree with node_modules under ${HOME}/.claude/plugins/cache/omc/oh-my-claudecode/ (found: ${OMC_DIR:-nothing})"; exit 1; }
echo "Moving @modelcontextprotocol/sdk, express, proxy-addr and body-parser within their ranges: ${OMC_DIR}"
(cd "${OMC_DIR}" && npm update --omit=dev --no-fund --no-audit --loglevel=error @modelcontextprotocol/sdk express proxy-addr body-parser) \
    || { echo "harden.sh: FAILED - the oh-my-claudecode dependencies could not be moved in ${OMC_DIR}"; exit 1; }
CM_PIN=$(sed -n 's/^export CLAUDE_MEM_VERSION=//p' /setup/install-claudemem.sh)
CM_DIR=${HOME}/.claude/plugins/cache/thedotmack/claude-mem/${CM_PIN}
[ -n "${CM_PIN}" ] && [ -d "${CM_DIR}/node_modules" ] \
    || { echo "harden.sh: FAILED - no claude-mem tree with node_modules at ${CM_DIR} (the pin read from install-claudemem.sh: '${CM_PIN}')"; exit 1; }
echo "Moving zod within its range: ${CM_DIR}"
(cd "${CM_DIR}" && npm update --omit=dev --no-fund --no-audit --loglevel=error zod) \
    || { echo "harden.sh: FAILED - zod could not be moved in ${CM_DIR}"; exit 1; }

# 2c) claude-mem pins shell-quote EXACTLY (1.9.0 at the 13.39.0 pin: CVE-2026-102422 CRITICAL), so no range lets npm update move
#     it, and none of the plugin's scripts, hooks or bundles loads the module (grep over the plugin at that pin). The copy is
#     replaced by 1.11.0, the fixed release, the pin kept exact. A claude-mem that already carries 1.11.0 or newer leaves this a
#     no-op; CM_DIR is the plugin's directory at the pin of install-claudemem.sh, as install-plugins.sh reads it (step 2b).
if [ -f "${CM_DIR}/node_modules/shell-quote/package.json" ]; then
    SQ=$(node -p "require('${CM_DIR}/node_modules/shell-quote/package.json').version")
    if [ "$(printf '%s\n%s\n' "${SQ}" 1.11.0 | sort -V | head -1)" != "1.11.0" ]; then
        echo "Replacing shell-quote ${SQ} with 1.11.0 in ${CM_DIR}"
        (cd "${CM_DIR}" && npm install --save-exact --omit=dev --no-fund --no-audit --loglevel=error shell-quote@1.11.0) \
            || { echo "harden.sh: FAILED - shell-quote ${SQ} in ${CM_DIR} could not be replaced by 1.11.0"; exit 1; }
    fi
    # every copy in the tree, nested ones included (a sub-package's own exact pin would survive the install above)
    for f in $(find "${CM_DIR}/node_modules" -path '*/shell-quote/package.json'); do
        V=$(node -p "require('${f}').version")
        [ "$(printf '%s\n%s\n' "${V}" 1.11.0 | sort -V | head -1)" == "1.11.0" ] \
            || { echo "harden.sh: FAILED - a shell-quote ${V} copy remains at ${f}"; exit 1; }
    done
fi

# 3) claude's updates run under this npm: claude's auto-updater updates claude inside the running container with
#    npm install --global @anthropic-ai/claude-code@<version>, and npm 12 runs only the install scripts its
#    allow-scripts setting covers. Without the package's postinstall an update leaves the 500-byte stub as claude
#    ("claude native binary not installed"). So the package's postinstall is allowed in the global npmrc, set here
#    after the upgrade above, so the npm 11 installs before it run as before. An addition goes into this same
#    global list (npm config set --location=global with every entry): an allow-scripts at the user level replaces
#    it, because npm does not merge the levels. Then the version setup/install-claude.sh installed is installed
#    again under this npm and checked again, so the build proves an update on the npm that will run it.
npm config set allow-scripts=@anthropic-ai/claude-code --location=global \
    || { echo "harden.sh: FAILED - npm $(npm -v) refused allow-scripts=@anthropic-ai/claude-code"; exit 1; }
CLAUDE_VERSION=$(timeout 60 claude --version 2> /dev/null | cut -d' ' -f1)
npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" && /setup/install-claude.sh --check \
    || { echo "harden.sh: FAILED - claude ${CLAUDE_VERSION:-(no version)} installed again under npm $(npm -v) does not run, so an update in a running container would leave the stub"; exit 1; }

# 4) Package-manager caches are re-created on demand and only add bulk + stale
#    vulnerable copies (bun cache carried shell-quote 1.8.4; the npx cache ~77MB,
#    bun cache ~466MB). Safe to drop from the baked image.
rm -rf "${HOME:?}/.npm/_npx" "${HOME:?}/.npm/_cacache" "${HOME:?}/.bun/install/cache"
npm cache clean --force > /dev/null 2>&1 || true

# Known-open (no fix released yet, tracked): /usr/bin/gh 2.98.0 is the LATEST gh
# release and is still built with golang.org/x/mod v0.38.0
# (CVE-2026-56864/CVE-2026-56865 HIGH, fixed in x/mod 0.40.0). Clears when the
# next gh release is rebuilt; install-gh.sh always installs the latest release.

echo "Hardening done."
