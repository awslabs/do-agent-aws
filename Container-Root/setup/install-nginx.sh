#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing nginx (harness home page + reverse proxy) ..."

# nginx fronts every harness UI behind ONE port: the home page at / lists the enabled UIs
# and each UI is proxied on a path (or a *.localhost host route), so a docker run publishes
# - and a kubernetes service exposes - a single port for the whole harness (see docs/manual/ui.md
# "Home page and reverse proxy"). Ubuntu's nginx-core build carries http_sub_module (used
# to inject the "home" badge into proxied pages) and websocket-capable proxying, which
# streamlit, ttyd, headlamp and vibe-kanban all need.
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx-core

# The distro service/config is not used: /agent/ui-start.sh runs nginx in the foreground
# ("daemon off;") under the same setsid+pidfile pattern as the other UIs, with a config
# rendered per start by /agent/home-render.sh from the UI enable flags.
rm -f /etc/nginx/sites-enabled/default

nginx -v
# Fail loud at build time if this nginx cannot do what the harness config asks of it
nginx -V 2>&1 | grep -q http_sub_module || { echo "ERROR: nginx build lacks http_sub_module"; exit 1; }
