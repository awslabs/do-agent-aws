#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Print the image reference sbx 0.47.0 gives a kit directory it builds.

usage: kit-key.py KIT_DIR KIT_NAME

sbx builds a kit directory (a source-form kit) into its kit registry as
sbx-kit-src:<name>-<key>. sbx 0.47.0 reused every build its registry held, and
built those it did not. <key> is the first 12 hex digits of a sha256 over every
regular file of the directory, in directory-walk order (each directory's
entries sorted by name, depth first): the file's relative path, a NUL byte,
its content and a NUL byte. Names starting with a dot are files like any
other: sbx 0.47.0 built the pf-dot fixture (a .claude/ directory and a
.gitignore) as the reference this gives on 2026-10-15. File modes and directory entries do not enter it,
so a change of modes alone gives the same reference.

This is sbx-internal, not documented, and read off sbx 0.47.0 on 2026-10-08:
it reproduces the references sbx printed for four kits it built. Two of them
were computed before sbx built them (pf-validate, and pf-tree, with a
subdirectory, an executable file and names whose walk order differs from their
path order); the other two (pf-inspect and do-agent-aws-sandbox) are the ones
it was fitted to. test1.sh checks it against pf-tree. to/sandbox/test/e2e.sh
uses it with sbx 0.47.0 only.
What it was not checked against is refused (exit 2): a directory not named
KIT_NAME, a symlink or other special file, an empty directory.
"""
import hashlib
import os
import stat
import sys


def refuse(msg):
    print("kit-key.py: " + msg, file=sys.stderr)
    sys.exit(2)


def walk(top, rel, digest):
    path = os.path.join(top, rel) if rel else top
    names = sorted(os.listdir(path))
    if rel and not names:
        refuse("empty directory %s (not checked against sbx)" % os.fsdecode(rel))
    for name in names:
        r = rel + b"/" + name if rel else name
        mode = os.lstat(os.path.join(top, r)).st_mode
        if stat.S_ISDIR(mode):
            walk(top, r, digest)
        elif stat.S_ISREG(mode):
            digest.update(r + b"\0")
            with open(os.path.join(top, r), "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    digest.update(chunk)
            digest.update(b"\0")
        else:
            refuse("%s is not a regular file or directory (not checked against sbx)" % os.fsdecode(r))


def main():
    if len(sys.argv) != 3:
        refuse("usage: kit-key.py KIT_DIR KIT_NAME")
    top, name = sys.argv[1], sys.argv[2]
    if not os.path.isdir(top):
        refuse("%s is not a directory" % top)
    if os.path.basename(os.path.abspath(top)) != name:
        refuse("%s is not named %s (sbx names the kit after it; only that case was checked)" % (top, name))
    digest = hashlib.sha256()
    walk(os.fsencode(top), b"", digest)
    print("sbx-kit-src:%s-%s" % (name, digest.hexdigest()[:12]))


if __name__ == "__main__":
    main()
