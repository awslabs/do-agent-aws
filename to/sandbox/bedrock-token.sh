#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# bedrock-token.sh PROFILE REGION - print a short-term Amazon Bedrock API key on
# stdout, and nothing else, for the sandbox kit's proxy-managed credential
# (service bedrock; to/sandbox/README.md "Model credential").
#
# It runs on the host, as the command of a sandbox-scoped dynamic secret. sbx
# runs the command through the host shell, from a fresh temporary directory,
# when the secret is stored and again after each refresh period:
#   sbx secret set bedrock --sandbox NAME \
#     --command '/home/USER/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1' --refresh 55m
# The proxy writes the key into the Authorization header of the sandbox's
# requests to bedrock-runtime.REGION.amazonaws.com; the sandbox never sees it.
# Install this file outside every directory a sandbox mounts, as sbx requires
# of a --command helper and of everything it loads: for example as
# ~/.local/share/sbx-bedrock/bedrock-token.sh, mode 0700, never in a checkout
# that a sandbox may mount.
#
# The key is made by aws-bedrock-token-generator, run by the Python of a venv:
# SBX_BEDROCK_VENV, default ~/.local/share/sbx-bedrock/venv (the README creates
# it, with the generator pinned), in isolated mode (-I: no PYTHON* variables,
# no user site-packages, not the working directory). It is a SigV4-presigned
# bedrock:CallWithBearerToken request, signed with the credentials botocore
# resolves for AWS profile PROFILE (on an EC2 host, the instance role's), and
# valid for 12 hours or until those credentials expire, whichever comes first.
# AWS attributes the calls made with it to that identity.
#
# Only the key goes to stdout. A failure prints a reason on stderr, never the
# key, and exits non-zero, so sbx stores or refreshes nothing.

set -u
if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
	echo "usage: bedrock-token.sh PROFILE REGION" >&2
	exit 2
fi
VENV=${SBX_BEDROCK_VENV:-${HOME:?bedrock-token.sh: HOME is not set}/.local/share/sbx-bedrock/venv}
PY=${VENV}/bin/python
if [ ! -x "${PY}" ]; then
	echo "bedrock-token.sh: no Python at ${PY}; create the venv (to/sandbox/README.md \"Model credential\") or set SBX_BEDROCK_VENV" >&2
	exit 1
fi
exec "${PY}" -I -c '
import sys
profile, region = sys.argv[1], sys.argv[2]
try:
    import botocore.session
    from aws_bedrock_token_generator import BedrockTokenGenerator
    credentials = botocore.session.Session(profile=profile).get_credentials()
    if credentials is None:
        raise RuntimeError("no AWS credentials for profile %s" % profile)
    token = BedrockTokenGenerator().get_token(credentials, region)
except Exception as e:
    sys.exit("bedrock-token.sh: %s: %s" % (type(e).__name__, e))
if not isinstance(token, str) or not token.startswith("bedrock-api-key-"):
    sys.exit("bedrock-token.sh: the generator returned no Bedrock API key")
sys.stdout.write(token + "\n")
' "$1" "$2"
