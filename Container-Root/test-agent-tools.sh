#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the agent's own Python tools in the image: what a build or diagnosis task reaches for first. Two agent
# build tasks (an Auto Mode NodePool and NodeClass, a template audit) spent their first tool calls here: `import yaml`
# failed (no PyYAML) and `python3 -m venv` made an environment without pip (no ensurepip), so each agent retried and
# then fell back to uv or `pip install --target`. Offline and without credentials;
# nothing is written under /wd. Each check FAILS if the property it proves is removed:
#   1. python3 imports yaml (PyYAML, the apt package python3-yaml) and reads a two-document manifest
#   2. python3 -m venv makes an environment whose own pip runs (python3-venv brings ensurepip)

fail()
{
	echo "Test-agent-tools FAILED: $1"
	exit 1
}

# --- 1. PyYAML ---
OUT=$(python3 -c 'import yaml; d = list(yaml.safe_load_all("kind: NodePool\n---\nkind: NodeClass\n")); print(len(d), d[1]["kind"])' 2>&1) \
	|| fail "python3 cannot read YAML (PyYAML, the apt package python3-yaml): ${OUT}"
[ "${OUT}" = "2 NodeClass" ] || fail "python3's yaml read a two-document manifest as '${OUT}'"
echo "ok 1 - python3 reads YAML: a two-document manifest reads as '${OUT}'"

# --- 2. venv with pip ---
V=/tmp/agent-tools-venv
rm -rf "${V:?}"
OUT=$(python3 -m venv "${V}" 2>&1) || fail "python3 -m venv failed (python3-venv brings ensurepip): ${OUT}"
P=$("${V}/bin/python" -m pip --version 2>&1) || fail "the new environment has no pip: ${P}"
rm -rf "${V:?}"
echo "ok 2 - python3 -m venv makes an environment whose pip runs (${P%% from *})"

echo "Test-agent-tools succeeded"
