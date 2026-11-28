#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# issues spoke - the exact send command of a staged draft, for the "send: <command>" line of its record: what
# `post.sh --command <name>` prints, under a name the session may run (its settings and every session's shared ones
# refuse post.sh itself, which is a person's to run at a terminal). It reads GitHub once, through the read-only front,
# and sends nothing.
#   send-line.sh <owner>.<repository>-<number>
exec "$(cd "$(dirname "$0")" && pwd)/post.sh" --command "$@"
