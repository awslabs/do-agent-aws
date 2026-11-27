# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash
# Outbound telemetry off by default (kanban coding guide check VKC-6: during a goal run the runner reported to a product
# analytics host and an error-reporting service, and gh looked up its update host - server-side calls the browser's
# Content-Security-Policy cannot see). Sourced by startup.sh before anything else starts, so every process it starts -
# the agent's tmux session, the loop, the chat responder, the UIs - inherits these:
#   DO_NOT_TRACK=1           the cross-tool convention (consoledonottrack.com) that npm, the Claude Code CLI and many
#                            node tools honour: no usage telemetry
#   GH_NO_UPDATE_NOTIFIER=1  gh does not check for a newer release on start (the only call gh makes on its own)
# A tool's own switch, where it has one, is set beside its install; nothing here reaches a browser.
export DO_NOT_TRACK=1
export GH_NO_UPDATE_NOTIFIER=1
