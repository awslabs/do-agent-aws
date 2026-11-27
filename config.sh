#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Open your settings file .env.local in an editor (docs/manual/install.md "Settings"); it is created on the first run.
# The defaults, with the description of every setting, are in .env.
cd "$(dirname "$0")" || exit 1
./env-local.sh
vi -c ":syntax on" .env.local
