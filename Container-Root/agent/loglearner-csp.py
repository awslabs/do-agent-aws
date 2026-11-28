#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The script-src sources the LogLearner dashboard's own pages need, read from the vendored release's source.

loglearner-csp.py <path to dashboard/app.py>
  prints one line: the sha256 source of each inline script the pages carry ('sha256-...'), 'unsafe-hashes' with the
  sha256 of each inline event handler, and each external script URL - for /agent/home-render.sh, which sends them in
  the loglearner.localhost route's Content-Security-Policy. Under that policy only the dashboard's own scripts run: a
  script or a handler that arrives inside a transcript snippet on the search page (which the vendored release puts into
  the page without escaping) does not. Exit 1 with one line on stderr when the source cannot be read or holds none of
  the shapes below (a release that changed them needs this reader updated, not a looser policy).

The shapes, as the 0.1.11 release writes them: module-level string constants JS and GRAPH_JS served as
<script>{JS}</script> and <script>{GRAPH_JS}</script>; the inline script window.HIND={1 if hind else 0} (both values);
on<event>="..." attributes; <script src="https://..."> tags.
"""
import ast
import base64
import hashlib
import re
import sys


def sha(text):
    return "'sha256-" + base64.b64encode(hashlib.sha256(text.encode("utf-8")).digest()).decode() + "'"


def main(argv):
    if len(argv) != 2:
        print("usage: loglearner-csp.py <dashboard/app.py>", file=sys.stderr)
        return 2
    try:
        src = open(argv[1], encoding="utf-8").read()
        tree = ast.parse(src)
    except (OSError, SyntaxError, ValueError) as e:
        print(f"loglearner-csp: cannot read {argv[1]}: {e}", file=sys.stderr)
        return 1
    consts = {}
    for node in tree.body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id in ("JS", "GRAPH_JS")):
            value = ast.literal_eval(node.value)
            if isinstance(value, str):
                consts[node.targets[0].id] = value
    scripts = [consts[k] for k in ("JS", "GRAPH_JS") if k in consts and "<script>{" + k + "}</script>" in src]
    if "<script>window.HIND={1 if hind else 0}</script>" in src:
        scripts += ["window.HIND=1", "window.HIND=0"]
    handlers = sorted(set(re.findall(r' on[a-z]+="([^"]*)"', src)))
    urls = sorted(set(re.findall(r'<script src="(https://[^"\s]+)"></script>', src)))
    if not scripts:
        print(f"loglearner-csp: no inline script of the known shapes in {argv[1]}", file=sys.stderr)
        return 1
    sources = [sha(s) for s in scripts]
    if handlers:
        sources += ["'unsafe-hashes'"] + [sha(h) for h in handlers]
    print(" ".join(sources + urls))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
