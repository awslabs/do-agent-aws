#!/bin/bash -p
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The agent's board tool (docs/manual/boards.md "Plane board", the board tool): list the goals and the tracked work, track work,
# give the autonomy loop a goal, move and comment - only on the paths the goals' mirrors do not fight. Run with no
# arguments for its usage; the commands, the paths and the exit statuses are described in /agent/board.py.
#
# Claude Code's allow rule Bash(/agent/board.sh:*) (/agent/board-settings.sh puts it in the agent's settings) lets
# an agent session run this without a prompt, so what it runs is pinned to the image's: bash -p reads no BASH_ENV
# and imports no functions from the caller, the PATH is the system's, and python3 -I takes no PYTHON* setting, no
# user site and nothing from the caller's directory. The deny rules beside that allow rule keep these files, the
# goal mirror and the board's secrets out of reach of the session's own writes.

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec python3 -I -B "$(dirname "$(readlink -f "$0")")/board.py" "$@"
