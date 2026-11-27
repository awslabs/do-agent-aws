#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The parity inventory, from a checkout: the same file as /agent/parity-inventory.sh in the image (docs/manual/autonomy.md "Parity with a native
# instance", docs/parity/PARITY-GAP.md). Run it on a native host from the directory a session works in: `tools/parity-inventory.sh`
# (or --json).
exec "$(cd "$(dirname "$0")/.." && pwd)/Container-Root/agent/parity-inventory.sh" "$@"
