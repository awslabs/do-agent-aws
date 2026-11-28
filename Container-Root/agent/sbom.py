#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The image's software bill of materials (docs/manual/supply-chain.md "Software bill of materials"): /sbom.sh runs this as the last step
of the image build and writes /SBOM.txt, one line per third-party component the image carries, `<name> <version> - <license>`,
in four sections, one per source:

  apt      every installed dpkg package (dpkg-query), its license from /usr/share/doc/<package>/copyright: the DEP-5
           `License:` short names, else the /usr/share/common-licenses/<name> files it points at, else the license names
           in its text, else the license text itself recognised (marked "(license text)"), else UNKNOWN
  npm      every package under a node_modules directory anywhere in the image (the global tree, the plugins' trees, the
           vendored dashboards' trees), the license its package.json declares, else its LICENSE file's first line, else UNKNOWN
  Python   every *.dist-info and *.egg-info anywhere in the image (every site-packages, the hindsight tool environment, the
           AWS CLI's bundled dist), the license its metadata declares (License-Expression, License, the license classifiers), else UNKNOWN
  tools    /setup/third-party.txt, the hand-maintained registry of what the installers fetch as release archives, installers,
           git clones, container-image exports and vendored trees - a line per component with its license, its upstream and
           the installer that brings it; a version written as $(command) is read from the image when this runs

Package-manager caches (/home/agent/.npm, /home/agent/.cache, /home/hindsight/.cache, bun's install cache) hold copies of what is listed
and are left out; /proc, /sys, /dev, /run, /tmp and /wd (the person's workspace) are never walked. A component whose license
could not be determined is listed as `UNKNOWN (<why>)`, never dropped; the header counts them. The header (lines starting
with `## `) carries the image name, its build stamp and the generation time; the body after the first empty line is the same
for the same image, sorted, with no timestamp in it, so a regenerated file is compared body to body (/test-sbom.sh) and the
committed copy, THIRD-PARTY-LICENSES at the repository root, is written from it by ./build.sh after every build.

Usage: sbom.py [--output FILE] [--registry FILE] [--version-file FILE] [--also DIR]...
  --output        where to write (default: standard output; /sbom.sh passes /SBOM.txt)
  --registry      the registry (default /setup/third-party.txt); a malformed line is an error, so a typo fails the build
  --version-file  the image's version file (default /version.txt; its first word is the image name)
  --also DIR      walk this directory too (a test plants a dist-info or a node_modules tree there; /tmp is otherwise skipped)
Standard library only (the image's python3 is Ubuntu's 3.10; nothing is installed for this). Exit 0 with the file written,
1 on any error (an unreadable registry, a malformed line, a dpkg-query that fails), and the Dockerfile step fails with it.
"""

import datetime
import json
import os
import re
import subprocess
import sys

REGISTRY_DEFAULT = "/setup/third-party.txt"
VERSION_FILE_DEFAULT = "/version.txt"
# never walked: kernel and device trees, the runtime directories, the person's workspace
WALK_EXCLUDE = ("/proc", "/sys", "/dev", "/run", "/var/run", "/tmp", "/var/tmp", "/wd")
# package-manager caches: copies of what the trees below hold, re-created on demand (setup/harden.sh removes most of them)
CACHE_EXCLUDE = ("/home/agent/.npm", "/home/agent/.cache", "/home/agent/.bun/install/cache", "/home/hindsight/.cache", "/home/agent/.local/share/uv/cache")

SECTION_APT = "apt packages (dpkg): every installed package, with the licenses its /usr/share/doc/<package>/copyright names"
SECTION_NPM = "Node.js packages (npm): every package under a node_modules directory in the image, with the license its package.json declares"
SECTION_PY = "Python packages: every *.dist-info and *.egg-info in the image (package-manager caches aside), with the license its metadata declares"
SECTION_TOOLS = "tools installed from release archives, installers, git clones, container-image exports and vendored trees (/setup/third-party.txt)"


class SbomError(Exception):
    pass


def ci(s):
    """Sort key: case-insensitive, then the exact text - so two names that differ in case only always come in the same order
    (a set's order is not), and the body is the same for the same image."""
    return (s.lower(), s)


def warn(msg):
    sys.stderr.write("sbom.py: " + msg + "\n")


def read_text(path, limit=None):
    try:
        with open(path, "rb") as f:
            data = f.read() if limit is None else f.read(limit)
    except OSError:
        return None
    return data.decode("utf-8", "replace")


def excluded(path):
    """True for a directory the walk of / never enters: the fixed exclusions and the caches, by path prefix."""
    for p in WALK_EXCLUDE + CACHE_EXCLUDE:
        if path == p or path.startswith(p + "/"):
            return True
    return False


def walk(roots):
    """os.walk over the roots, never following symlinks, never crossing into another filesystem (a volume or a bind mount
    the container got at run time - the person's checkout, /wd - is not the image), pruning the excluded directories under /
    (a --also root is walked whole); yields (dirpath, dirnames, filenames)."""
    seen = set()
    for root in roots:
        try:
            root_dev = os.stat(root).st_dev
        except OSError:
            continue
        prune = root == "/"
        for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
            if prune and excluded(dirpath):
                dirnames[:] = []
                continue
            try:
                st = os.stat(dirpath)
            except OSError:
                dirnames[:] = []
                continue
            key = (st.st_dev, st.st_ino)
            if st.st_dev != root_dev or key in seen:   # another filesystem, or the same directory reached twice
                dirnames[:] = []
                continue
            seen.add(key)
            dirnames[:] = sorted(d for d in dirnames if not (prune and excluded(os.path.join(dirpath, d))))
            yield dirpath, dirnames, filenames


def add(table, name, version, license_):
    """table[(name, version)] -> sorted set of license strings seen for that component (one line is written per component)."""
    name = (name or "").strip()
    version = (version or "").strip() or "unknown"
    if not name:
        return
    key = (name.replace(" ", "_"), version.replace(" ", "_"))
    table.setdefault(key, set()).add(license_)


# --- 1. apt ---------------------------------------------------------------------------------------------------------------

# the license names dpkg-licenses (github.com/daald/dpkg-licenses, lib/reader-50-superfuzzy.sh) looks for in a copyright file
SUPERFUZZY = re.compile(
    r"\b((?:4-?clause )?\"?BSD\"? licen[sc]es?"
    r"|(?:Boost Software|mozilla (?:public )?|MIT) Licen[sc]es?"
    r"|(?:CCPL|BSD|L?GPL)-[0-9a-z.+-]+(?: Licenses?)?"
    r"|Creative Commons(?: Licenses?)?"
    r"|Public Domain(?: Licenses?)?)\b", re.IGNORECASE)

# license texts recognised by their opening words when a copyright file names no license (the x11 libraries, libdb, libldap ...)
LICENSE_TEXTS = (
    ("MIT", re.compile(r"Permission is hereby granted, free of charge, to any person", re.IGNORECASE)),
    ("ISC", re.compile(r"Permission to use, copy, modify,? and(?:/or)? distribute this software for any purpose", re.IGNORECASE)),
    ("HPND-sell-variant", re.compile(r"Permission to use, copy, modify, distribute,? and sell this software and its\s+documentation", re.IGNORECASE)),
    ("HPND", re.compile(r"Permission to use, copy, modify,? and distribute this software\s+and its documentation for any purpose", re.IGNORECASE)),
    ("BSD", re.compile(r"Redistribution and use in source and binary forms", re.IGNORECASE)),
    ("LGPL", re.compile(r"GNU (?:Lesser|Library) General Public License", re.IGNORECASE)),
    ("GPL", re.compile(r"GNU General Public License", re.IGNORECASE)),
    ("MPL", re.compile(r"Mozilla Public License", re.IGNORECASE)),
    ("Apache", re.compile(r"Apache License", re.IGNORECASE)),
    ("Info-ZIP", re.compile(r"Info-ZIP license", re.IGNORECASE)),
    ("Sleepycat", re.compile(r"Sleepycat|Berkeley DB software", re.IGNORECASE)),
    ("OpenLDAP", re.compile(r"OpenLDAP Public License", re.IGNORECASE)),
    ("public-domain", re.compile(r"public domain", re.IGNORECASE)),
)


def copyright_licenses(text):
    """The license names a copyright file carries, in dpkg-licenses' order of trust, or (None, why)."""
    head = text.split("\n\n", 1)[0]
    if re.search(r"^Format:", head, re.MULTILINE):   # DEP-5 (machine-readable): the License fields' short names
        names = {}
        for m in re.finditer(r"^Licen[cs]e:[ \t]*(.*)$", text, re.MULTILINE):
            for part in re.split(r"\s+and\s+", m.group(1).strip()):
                part = part.strip().replace("icence", "icense")
                if part:
                    names.setdefault(part.lower(), part)   # one spelling per name: BSD-3-Clause and BSD-3-clause are one license
        if names:
            return ", ".join(sorted(names.values(), key=ci)), None
    refs = set(re.findall(r"/usr/share/common-licenses/([0-9A-Za-z_.+-]*[0-9A-Za-z+])", text))
    if refs:
        return ", ".join(sorted(refs, key=ci)), None
    names = {}
    for m in SUPERFUZZY.finditer(text):
        n = re.sub(r"(?i)licen[cs]es?", "License", m.group(1).replace('"', "")).strip(" .")
        if n and not re.search(r"\.(c|h|txt|py|md)$", n, re.IGNORECASE):   # a file name the pattern caught (bsd-poll.c) is no license
            names.setdefault(n.lower(), n)
    if names:
        return ", ".join(sorted(names.values(), key=ci)), None
    lines = {}
    for m in re.finditer(r"^Licen[cs]e:[ \t]*(.+)$", text, re.MULTILINE):   # a License: line in a file that is not DEP-5
        for part in re.split(r"\s+and\s+", m.group(1).strip()):
            part = part.strip().replace("icence", "icense")
            if part:
                lines.setdefault(part.lower(), part)
    if lines:
        return ", ".join(sorted(lines.values(), key=ci)), None
    kinds = [name for name, rx in LICENSE_TEXTS if rx.search(text)]
    if kinds:
        return ", ".join(kinds) + " (license text)", None
    return None, "no license name found in copyright file"


def override(table, source, name, version, overrides, why, keys=None):
    """An UNKNOWN component, unless the registry's <source>:<key> line names its license (then that license, marked); keys are the
    names to look up (default: the component's own; a dpkg package is tried with and without its architecture). Returns 1 for UNKNOWN."""
    lic = None
    for k in keys or [name]:
        if k in overrides.get(source, {}):
            lic = overrides[source][k]
            break
    if lic is not None:
        add(table, name, version, "%s (third-party.txt: %s)" % (lic, why))
        return 0
    add(table, name, version, "UNKNOWN (%s)" % why)
    return 1


def collect_apt(dpkg_overrides):
    """(table, unknown) over every installed dpkg package; dpkg_overrides: package -> license for a deb without a copyright file."""
    try:
        out = subprocess.run(["dpkg-query", "-W", "-f", "${binary:Package}\t${Version}\t${db:Status-Status}\n"],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise SbomError("dpkg-query failed: %s" % e)
    table, unknown = {}, 0
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3 or parts[2] != "installed":
            continue
        pkg, version = parts[0], parts[1]
        base = pkg.split(":", 1)[0]
        text = read_text("/usr/share/doc/%s/copyright" % pkg) or read_text("/usr/share/doc/%s/copyright" % base)
        if text is None:
            unknown += override(table, "dpkg", pkg, version, {"dpkg": dpkg_overrides}, "no copyright file", keys=[pkg, base])
            continue
        lic, why = copyright_licenses(text)
        if lic is None:
            unknown += override(table, "dpkg", pkg, version, {"dpkg": dpkg_overrides}, why, keys=[pkg, base])
        else:
            add(table, pkg, version, lic)
    return table, unknown


# --- 2. npm -------------------------------------------------------------------------------------------------------------------

def package_json_license(pkg_dir, meta):
    """The license a package declares: package.json's license (a string or {type}), its licenses list, else its LICENSE file's
    first line, else None."""
    lic = meta.get("license")
    if isinstance(lic, str) and lic.strip():
        if re.match(r"(?i)^(SEE LICEN[CS]E IN\b|UNLICENSED$)", lic.strip()):
            return None   # npm's pointer at a file, or "UNLICENSED": no license declared (the registry's npm: line names it, else UNKNOWN)
        return lic.strip()
    if isinstance(lic, dict) and isinstance(lic.get("type"), str) and lic["type"].strip():
        return lic["type"].strip()
    lics = meta.get("licenses")
    if isinstance(lics, list):
        types = sorted(set(l["type"].strip() for l in lics if isinstance(l, dict) and isinstance(l.get("type"), str) and l["type"].strip()))
        if types:
            return " OR ".join(types)
    try:
        names = sorted(os.listdir(pkg_dir))
    except OSError:
        names = []
    for n in names:
        if re.match(r"(?i)^(licen[cs]e|copying)(\.|$)", n) and os.path.isfile(os.path.join(pkg_dir, n)):
            head = (read_text(os.path.join(pkg_dir, n), 4096) or "").strip().splitlines()
            for line in head[:3]:
                m = re.search(r"(?i)\b(MIT|ISC|BSD(?:-[0-9]-Clause)?|Apache(?: License)?(?:,? Version)? ?2\.0|Apache-2\.0|MPL(?:-| )2\.0|L?GPL(?:v| ?-?)[23](?:\.[01])?|Unlicense|0BSD|CC0|WTFPL|Python Software Foundation|BlueOak)\b", line)
                if m:
                    return m.group(1).replace("Apache License, Version 2.0", "Apache-2.0").replace("Apache License Version 2.0", "Apache-2.0") + " (LICENSE file)"
    return None


def collect_npm(roots, overrides):
    """(table, unknown) over every node_modules/<name>/package.json and node_modules/@scope/<name>/package.json under the roots."""
    table, unknown = {}, 0
    for dirpath, dirnames, filenames in walk(roots):
        if os.path.basename(dirpath) != "node_modules":
            continue
        pkg_dirs = []
        for d in dirnames:
            if d.startswith("@"):
                scope = os.path.join(dirpath, d)
                try:
                    pkg_dirs += [os.path.join(scope, s) for s in sorted(os.listdir(scope))]
                except OSError:
                    pass
            elif not d.startswith("."):
                pkg_dirs.append(os.path.join(dirpath, d))
        for pkg_dir in pkg_dirs:
            if os.path.islink(pkg_dir):
                continue   # a linked package (pnpm, bun layouts) is listed where it really is
            pj = os.path.join(pkg_dir, "package.json")
            text = read_text(pj)
            if text is None:
                continue
            try:
                meta = json.loads(text)
            except ValueError:
                meta = {}
            if not isinstance(meta, dict) or not isinstance(meta.get("name"), str) or not meta["name"].strip():
                continue   # a directory in node_modules that is not a package (no name)
            version = meta.get("version") if isinstance(meta.get("version"), str) else ""
            lic = package_json_license(pkg_dir, meta)
            if lic is None:
                declared = meta.get("license") if isinstance(meta.get("license"), str) else ""
                why = "package.json points at a file: %s" % declared.strip() if declared.strip() else "package.json declares no license"
                unknown += override(table, "npm", meta["name"], version, overrides, why)
            else:
                add(table, meta["name"], version, lic)
    return table, unknown


# --- 3. Python -------------------------------------------------------------------------------------------------------------------

def metadata_fields(text):
    """The RFC 822 headers of a METADATA / PKG-INFO file (the body after the first empty line is the description)."""
    fields = {}
    for line in text.replace("\r\n", "\n").split("\n\n", 1)[0].splitlines():
        m = re.match(r"^([A-Za-z][A-Za-z0-9-]*):\s*(.*)$", line)
        if m:
            fields.setdefault(m.group(1).lower(), []).append(m.group(2).strip())
    return fields


def metadata_license(fields):
    """License-Expression, else a one-line License (not a copyright notice or a paragraph), else the license classifiers, else None."""
    for v in fields.get("license-expression", []):
        if v:
            return v
    for v in fields.get("license", []):
        if v and v.upper() != "UNKNOWN" and len(v) <= 80 and not re.match(r"(?i)^copyright\b", v) and "\n" not in v:
            return v
    names = []
    for c in fields.get("classifier", []):
        if c.startswith("License ::"):
            parts = [p.strip() for p in c.split("::")]
            last = parts[-1]
            if last and last != "OSI Approved" and last not in names:
                names.append(last)
    if names:
        return ", ".join(names) + " (classifier)"
    return None


def collect_python(roots, overrides):
    """(table, unknown) over every *.dist-info (METADATA) and *.egg-info (PKG-INFO) under the roots."""
    table, unknown = {}, 0
    for dirpath, dirnames, filenames in walk(roots):
        entries = []
        for d in list(dirnames):
            if d.endswith(".dist-info"):
                entries.append((d, os.path.join(dirpath, d, "METADATA")))
            elif d.endswith(".egg-info"):
                entries.append((d, os.path.join(dirpath, d, "PKG-INFO")))
            else:
                continue
            dirnames.remove(d)   # nothing of interest below a metadata directory
        for f in filenames:
            if f.endswith(".egg-info"):   # the single-file form: the file is the PKG-INFO
                entries.append((f, os.path.join(dirpath, f)))
        for d, meta_file in entries:
            text = read_text(meta_file)
            fields = metadata_fields(text) if text is not None else {}
            name = (fields.get("name") or [""])[0]
            version = (fields.get("version") or [""])[0]
            if not name:   # no readable metadata: the directory's own name
                m = re.match(r"^(.+?)-([0-9][^-]*)\.(dist|egg)-info$", d)
                name, version = (m.group(1), m.group(2)) if m else (d.rsplit(".", 1)[0], "")
            lic = metadata_license(fields)
            if lic is None:
                unknown += override(table, "python", name, version, overrides, "no license metadata")
            else:
                add(table, name, version, lic)
    return table, unknown


# --- 4. the registry ---------------------------------------------------------------------------------------------------------------

def parse_registry(path):
    """The registry's three kinds of line (comments and blank lines aside):
         <name> <version> - <license> - <upstream> - <installer>   a component; <version> a literal, or $(command) read from the image
         dpkg:<package> - <license> - <upstream> - <installer>     the license of an installed deb that ships no copyright file
         npm:<package> - <license> - <upstream> - <installer>      the license of an npm package whose package.json declares none
         python:<distribution> - <license> - <upstream> - <installer>   the same for a Python distribution without license metadata
         none:<installer> - <why>                                   an installer that brings no third-party code
       Returns (components, overrides, none_installers): overrides = {"dpkg": {name: license}, "npm": {...}, "python": {...}};
       a malformed line raises SbomError (the build fails on it)."""
    text = read_text(path)
    if text is None:
        raise SbomError("cannot read the registry %s" % path)
    components, overrides, none_installers = [], {"dpkg": {}, "npm": {}, "python": {}}, {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        where = "%s line %d" % (path, lineno)
        m = re.match(r"^(dpkg|npm|python):(.*)$", s)
        if m:
            parts = [p.strip() for p in m.group(2).split(" - ")]
            if len(parts) != 4 or not all(parts) or " " in parts[0]:
                raise SbomError("%s: an override line is `%s:<name> - <license> - <upstream> - <installer>`: %s" % (where, m.group(1), s))
            overrides[m.group(1)][parts[0]] = parts[1]
            components.append({"kind": m.group(1), "name": parts[0], "license": parts[1], "upstream": parts[2], "installer": parts[3], "line": lineno})
            continue
        if s.startswith("none:"):
            parts = [p.strip() for p in s[5:].split(" - ", 1)]
            if len(parts) != 2 or not all(parts) or " " in parts[0]:
                raise SbomError("%s: a none: line is `none:<installer> - <why>`: %s" % (where, s))
            none_installers[parts[0]] = parts[1]
            continue
        parts = [p.strip() for p in s.split(" - ")]
        if len(parts) != 4 or not all(parts):
            raise SbomError("%s: a component line is `<name> <version> - <license> - <upstream> - <installer>` (four fields, ` - ` between them): %s" % (where, s))
        namever = parts[0]
        if "$(" in namever:
            i = namever.index("$(")
            name, vspec = namever[:i].strip(), namever[i:].strip()
            if not name or not vspec.endswith(")"):
                raise SbomError("%s: the version probe is `<name> $(command)`: %s" % (where, namever))
        else:
            toks = namever.split()
            if len(toks) != 2:
                raise SbomError("%s: the first field is `<name> <version>` (two words, or a name and a $(command)): %s" % (where, namever))
            name, vspec = toks
        if " " in name:
            raise SbomError("%s: a component name carries no space: %s" % (where, name))
        components.append({"kind": "tool", "name": name, "version": vspec, "license": parts[1], "upstream": parts[2], "installer": parts[3], "line": lineno})
    return components, overrides, none_installers


def probe_version(name, spec):
    """A registry version: a literal as written, or the output of $(command) run by sh in the image - its whitespace-separated
    words joined with commas. A command that fails, times out or prints nothing is an error (the registry line has rotted: a
    moved path, a removed tool), so the generation and the build fail instead of writing `unknown`."""
    if not spec.startswith("$("):
        return spec
    cmd = spec[2:-1]
    try:
        r = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, text=True, errors="replace", timeout=120)  # nosemgrep: dangerous-subprocess-use-audit -- a build-time version probe from the image's own registry (third-party.txt); no outside input
    except (OSError, subprocess.TimeoutExpired) as e:
        raise SbomError("the version probe of %s failed: %s: %s" % (name, cmd, e))
    words = r.stdout.split()
    if r.returncode != 0 or not words:
        raise SbomError("the version probe of %s gave nothing (exit %s): %s %s" % (name, r.returncode, cmd, r.stderr.strip()[:200]))
    return ",".join(words)


def collect_registry(components):
    """(table, unknown) over the registry's component lines (the dpkg: lines are folded into the apt section)."""
    table, unknown = {}, 0
    for c in components:
        if c["kind"] != "tool":
            continue
        add(table, c["name"], probe_version(c["name"], c["version"]), c["license"])
        if c["license"].upper().startswith("UNKNOWN"):
            unknown += 1
    return table, unknown


# --- output -------------------------------------------------------------------------------------------------------------------

def section_lines(title, table):
    lines = ["# " + title]
    for (name, version) in sorted(table, key=lambda k: (k[0].lower(), k[1].lower(), k[0], k[1])):
        lines.append("%s %s - %s" % (name, version, ", ".join(sorted(table[(name, version)], key=ci))))
    return lines


def render(image, build, sections, unknown_total):
    """sections: list of (short name, title, table, unknown count). The header lines start with `## `, then one empty line, then the body."""
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    total = sum(len(t) for _, _, t, _ in sections)
    counts = "; ".join("%s %d" % (short, len(t)) for short, _, t, _ in sections)
    header = [
        "## Software bill of materials (SBOM) of the container image %s, build %s" % (image, build),
        "## Generated %s by /sbom.sh (/agent/sbom.py); regenerate in a running container with: /sbom.sh [output file]" % now,
        "## One line per third-party component the image carries: <name> <version> - <license>. A license the generator could not",
        "## determine reads UNKNOWN (<why>); no component is left out. Four sources, each its own section below:",
        "## components: %s; total %d; UNKNOWN %d" % (counts, total, unknown_total),
        "## The body after this header (from the first empty line on) is the same for the same image - sorted, no timestamp - so a",
        "## regenerated file compares body to body (/test-sbom.sh). The committed copy is THIRD-PARTY-LICENSES at the repository root,",
        "## written from the image by ./build.sh after every build (docs/manual/supply-chain.md \"Software bill of materials\").",
        "## Not in the image, so not in this list: the optional sidecar stacks ./run.sh starts only when switched on - the Plane board",
        "## (makeplane/plane-{backend,frontend,space,admin,live,proxy}:v1.4.2 under the AGPL-3.0, and its datastore images under their own",
        "## licenses; UI_PLANE, off by default; docs/manual/boards.md \"Plane board\").",
        "",
    ]
    body = []
    for i, (_, title, table, _) in enumerate(sections):
        if i:
            body.append("")
        body += section_lines(title, table)
    return "\n".join(header + body) + "\n"


def main(argv):
    output, registry, version_file, also = None, REGISTRY_DEFAULT, VERSION_FILE_DEFAULT, []
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--output" and args:
            output = args.pop(0)
        elif a == "--registry" and args:
            registry = args.pop(0)
        elif a == "--version-file" and args:
            version_file = args.pop(0)
        elif a == "--also" and args:
            also.append(os.path.abspath(args.pop(0)))
        elif a in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return 0
        else:
            raise SbomError("unknown argument %s (see --help)" % a)
    vt = read_text(version_file) or ""
    image = (vt.split() or ["unknown"])[0]
    build = os.environ.get("AGENT_BUILD", "").strip() or "unknown"
    components, overrides, _ = parse_registry(registry)
    roots = ["/"] + also
    apt, u1 = collect_apt(overrides["dpkg"])
    npm, u2 = collect_npm(roots, overrides)
    py, u3 = collect_python(roots, overrides)
    tools, u4 = collect_registry(components)
    text = render(image, build, [("apt", SECTION_APT, apt, u1), ("npm", SECTION_NPM, npm, u2),
                                 ("python", SECTION_PY, py, u3), ("tools", SECTION_TOOLS, tools, u4)], u1 + u2 + u3 + u4)
    if output is None:
        sys.stdout.write(text)
    else:
        tmp = output + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, output)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SbomError as e:
        sys.stderr.write("sbom.py: ERROR - %s\n" % e)
        sys.exit(1)
