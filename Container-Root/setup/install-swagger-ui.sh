#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing swagger-ui (the Hindsight API docs page's assets) ..."

# The hindsight-api docs page (/memory-api/docs, FastAPI's Swagger UI) loads swagger-ui from the jsdelivr CDN and
# its icon from fastapi.tiangolo.com. The home proxy serves this pinned copy instead (/memory-api/__swagger/, see
# /agent/home-render.sh) and rewrites the page's URLs to it, so the page renders offline and makes no request off
# the loopback port. swagger-ui-dist is swagger-ui's published build (github.com/swagger-api/swagger-ui, Apache-2.0,
# Copyright SmartBear Software Inc.): the npm tarball is fetched at build time and checked against its sha256, and
# only what the page uses is kept - the bundle, the stylesheet and an icon - with the LICENSE, the NOTICE, the
# bundle's third-party license file and package.json (the version). A mismatch or a failed fetch fails the build.
export SWAGGER_UI_VERSION=5.35.0
export SWAGGER_UI_SHA256=1b8e891893404ea4c3558b6a87e2a3e494e7eedba41168c2ece5800a391a6ea6
SWAGGER_UI_DIR=${SWAGGER_UI_DIR:-/opt/swagger-ui-dist}

T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
curl -fsSL -o "${T}/swagger-ui-dist.tgz" "https://registry.npmjs.org/swagger-ui-dist/-/swagger-ui-dist-${SWAGGER_UI_VERSION}.tgz" || exit 1
echo "${SWAGGER_UI_SHA256}  ${T}/swagger-ui-dist.tgz" | sha256sum -c - || exit 1
tar -xzf "${T}/swagger-ui-dist.tgz" -C "${T}" || exit 1
mkdir -p "${SWAGGER_UI_DIR}"
for F in swagger-ui-bundle.js swagger-ui-bundle.js.LICENSE.txt swagger-ui.css favicon-32x32.png LICENSE NOTICE package.json; do
	install -m 0644 "${T}/package/${F}" "${SWAGGER_UI_DIR}/${F}" || exit 1
done
( cd "${SWAGGER_UI_DIR}" && sha256sum swagger-ui-bundle.js swagger-ui.css favicon-32x32.png > SHA256SUMS ) || exit 1
echo "swagger-ui-dist ${SWAGGER_UI_VERSION} in ${SWAGGER_UI_DIR}: $(cd "${SWAGGER_UI_DIR}" && echo *)"
