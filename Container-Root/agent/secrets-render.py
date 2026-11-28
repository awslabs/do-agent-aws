#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Render the harness credentials held in one AWS Secrets Manager secret (docs/manual/aws.md "Credentials from AWS Secrets Manager").

stdin   the secret's SecretString: one JSON object of environment variable names to string values
argv    [--env-file PATH] NAME... - the names that may be taken from it (the allowlist, AGENT_SECRETS_NAMES);
        --names NAME... prints the names that pass the checks below and reads nothing
stdout  one `export NAME='value'` line per allowed name the secret holds, POSIX-shell quoted, for the caller to eval
stderr  names only: what was loaded, what the secret holds that the allowlist does not name, what was refused
exit    0 rendered (possibly nothing); 3 the input is not a JSON object

A value is written nowhere but stdout and, with --env-file, a file created with mode 0600 (replaced atomically) that
`docker exec` shells source (/agent/secrets-env.sh). Names that steer processes or are the bootstrap AWS credentials
themselves are refused even when listed: the secret cannot set PATH, LD_PRELOAD, BASH_ENV or AWS_ACCESS_KEY_ID.
"""
import json
import os
import re
import shlex
import sys

NAME = re.compile(r"^[A-Z_][A-Z0-9_]{0,127}$")
NEVER = re.compile(
    r"^(PATH|HOME|SHELL|USER|LOGNAME|ENV|BASH_ENV|BASH_FUNC_\w*|IFS|PS[0-9]|TERM|TZ|LANG|LC_\w*|TMPDIR|"
    r"LD_\w*|DYLD_\w*|PYTHON\w*|NODE_OPTIONS|NODE_PATH|NPM_CONFIG_\w*|PERL5?LIB|PERL5OPT|RUBYLIB|RUBYOPT|"
    r"GIT_\w*|SSH_\w*|CLAUDE_CONFIG_DIR|CLAUDE_CODE_USE_BEDROCK|"
    r"AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AWS_PROFILE|AWS_CONFIG_FILE|AWS_SHARED_CREDENTIALS_FILE|"
    r"AWS_REGION|AWS_DEFAULT_REGION|AWS_ENDPOINT_URL\w*|AWS_CA_BUNDLE|AGENT_SECRETS_\w*)$")


def say(msg):
    print("secrets: " + msg, file=sys.stderr)


def write_env_file(path, lines):
    """The export lines into path, 0600 from creation, replaced atomically; nothing left behind on failure."""
    d = os.path.dirname(path) or "."
    tmp = os.path.join(d, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write("".join(line + "\n" for line in lines))
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv):
    env_file, names_only = None, False
    if argv and argv[0] == "--names":
        names_only, argv = True, argv[1:]
    elif len(argv) >= 2 and argv[0] == "--env-file":
        env_file, argv = argv[1], argv[2:]
    allowed = []
    for n in argv:
        if not n or n in allowed:
            continue
        if not NAME.match(n) or NEVER.match(n):
            say("%s is never taken from the secret (not a credential's environment variable name)" % n)
            continue
        allowed.append(n)
    if names_only:
        print(" ".join(allowed))
        return 0
    try:
        data = json.loads(sys.stdin.read())
    except ValueError:
        data = None
    if not isinstance(data, dict):
        say("the secret is not a JSON object of NAME: value pairs; nothing loaded")
        return 3
    lines, loaded = [], []
    for n in allowed:
        if n not in data:
            continue
        v = data[n]
        if not isinstance(v, str) or "\x00" in v:
            say("%s in the secret is not a string; left out" % n)
            continue
        lines.append("export %s=%s" % (n, shlex.quote(v)))
        loaded.append(n)
    others = [k for k in data if k not in allowed]
    if others:
        named = sorted(k for k in others if isinstance(k, str) and NAME.match(k))
        say("%d key(s) in the secret not in AGENT_SECRETS_NAMES, ignored%s" % (len(others), (": " + " ".join(named)) if named else ""))
    if env_file:
        write_env_file(env_file, lines)
    say("loaded from AWS Secrets Manager: %s" % (" ".join(loaded) if loaded else "nothing (no allowed name in the secret)"))
    sys.stdout.write("".join(line + "\n" for line in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
