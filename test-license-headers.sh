#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of the conditions of the release's IP review (README.md "License and third-party software"), run by test.sh;
# it reads files and git only, never docker. Each check FAILS if the property is removed:
#   1. every first-party source file git tracks starts with the license header: Amazon's copyright line and the SPDX
#      identifier Apache-2.0, in the comment syntax of its type, as its first two lines or right after the lines that must
#      stay first (a #! line, a Python coding line, a # syntax= or # escape= directive, an HTML <!DOCTYPE>, a CSS @charset).
#      First-party source: a tracked file outside Container-Root/opt/ (third-party code, each project with its own license)
#      and outside a fixtures/ folder (test inputs kept byte for byte), of a type that carries comments (.sh .py .pl .js .css
#      .html .yaml .yml .dockerfile, Dockerfile, .env, .fun) or that starts with #!
#   2. a script that prints its help from its own source ($0) - sed -n over a line range, awk from a line number (NR), tail
#      from a line, or head - starts below the header, so the header never shows in its help
#   3. LICENSE is the Apache-2.0 text, and NOTICE holds the project's name and Amazon's copyright line, nothing else
#   4. each project vendored under Container-Root/opt/ (a folder with a VENDORED.md) keeps its LICENSE there, has its entry in
#      THIRD-PARTY (its folder, its LICENSE, its NOTICE where it has
#      one), and its registry line in Container-Root/setup/third-party.txt (the source of THIRD-PARTY-LICENSES) says it is
#      bundled there; THIRD-PARTY-LICENSES lists postgresql_binaries (PostgreSQL License) and swagger-ui-dist (Apache-2.0),
#      the two the build brings in that the IP review named, and the registry keeps the postgresql_binaries line
#   5. README.md opens with the project's full name, "Do Agent on AWS" (repository do-agent-aws), says it is not an AWS service
#      or product and clones the public repository; links LICENSE, NOTICE and THIRD-PARTY; says Claude Code is not part of the repository, the build installs it from npm,
#      and its use is subject to Anthropic's commercial terms; and carries the notice of dependencies with restricted
#      licenses, listing Plane and pgsty/silo as AGPL-3.0. The build does install Claude Code from npm, git tracks no copy
#      of it and no AGPL-3.0 license text (no Plane or silo source), and .env keeps Plane off by default
#   6. PLANTED CONTROLS: a file without the header, a header below a code line, another SPDX identifier, a new script
#      without the header, a #! file without an extension and without the header, the wrong comment syntax, help ranges
#      that reach into the header, another license text, another copyright line in NOTICE and an extra line in it, a vendored
#      project without its README row, its THIRD-PARTY entry or NOTICE, its registry note or its LICENSE, the PostgreSQL
#      binaries gone from the registry or from THIRD-PARTY-LICENSES, the THIRD-PARTY link, the Anthropic terms, pgsty/silo, Plane or the
#      restricted-license notice taken out of README.md, Plane on in .env, a tracked AGPL-3.0 text, a tracked Claude Code
#      copy and a build that no longer installs it each fail the check that names it

D=./scratch/test-license-headers
fail() { echo "Test-license-headers FAILED: $*"; exit 1; }
[ -f README.md ] && [ -f .env ] || fail "run it from the repository root"
git rev-parse --is-inside-work-tree > /dev/null 2>&1 || fail "not a git checkout: the check reads the list of tracked files from git"
rm -rf "${D:?}" && mkdir -p "${D}" || fail "cannot create ${D}"
trap 'rm -rf "${D:?}"' EXIT
git ls-files -z > "${D}/tracked" || fail "git ls-files failed"

cat > "${D}/check.py" << 'PY'
import os, re, sys

root, listing = sys.argv[1], sys.argv[2]
over, drop, args = {}, set(), sys.argv[3:]
while args:
    if args[0] == "--set" and len(args) >= 3:
        over[args[1]], args = args[2], args[3:]
    elif args[0] == "--drop" and len(args) >= 2:
        drop.add(args[1]); args = args[2:]
    else:
        sys.exit("usage: check.py ROOT LISTING [--set PATH FILE] [--drop PATH]...")
with open(listing, encoding="utf-8") as f:
    paths = [p for p in f.read().split("\0") if p]
paths = [p for p in paths if p not in drop] + [p for p in over if p not in paths]
tracked = set(paths)

def raw(p):
    try:
        with open(over.get(p, os.path.join(root, p)), "rb") as f:
            return f.read()
    except OSError:
        return None

def text(p):
    b = raw(p)
    return None if b is None else b.decode("utf-8", "replace")

bad = []
HDR = ("Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.", "SPDX-License-Identifier: Apache-2.0")
STYLE = {"#": ("# ", ""), "//": ("// ", ""), "/*": ("/* ", " */"), "<!--": ("<!-- ", " -->")}
BY_EXT = {".sh": ["#"], ".py": ["#"], ".pl": ["#"], ".yaml": ["#"], ".yml": ["#"], ".dockerfile": ["#"],
          ".js": ["//", "/*"], ".css": ["/*"], ".html": ["<!--"]}
BY_NAME = {"Dockerfile": ["#"], ".env": ["#"], ".fun": ["#"]}

def styles(p):
    if p.startswith(("Container-Root/opt/", "wd/", "fixtures/")) or "/fixtures/" in p:
        return None
    base = os.path.basename(p)
    if base in BY_NAME:
        return BY_NAME[base]
    ext = os.path.splitext(base)[1]
    if ext in BY_EXT:
        return BY_EXT[ext]
    b = raw(p)
    return ["#"] if b is not None and b.startswith(b"#!") else None

CODING = re.compile(r"^[ \t\f]*#.*?coding[:=][ \t]*[-\w.]+")
def first(lines, p, style):
    # the lines that must stay first: what the header goes below
    k = 1 if lines and lines[0].startswith("#!") else 0
    if p.endswith(".py") and k < 2 and k < len(lines) and CODING.match(lines[k]):
        k += 1
    if style == "#":
        while k < len(lines) and re.match(r"#\s*(syntax|escape|check)=", lines[k]):
            k += 1
    if style == "<!--" and lines and lines[0].lower().startswith("<!doctype"):
        k = 1
    if style == "/*" and p.endswith(".css") and lines and lines[0].startswith("@charset"):
        k = 1
    return k

# 1. the header, and 2. the help a script prints from its own source
SELF = re.compile(r"""sed\s+-n\s+['"]?(\d+),(\d+)p['"]?\s+"?\$\{?0\}?"?"""
                  r"""|awk\s+'([^']*)'\s+"?\$\{?0\}?"?"""
                  r"""|tail\s+-n\s*\+(\d+)\s+"?\$\{?0\}?"?"""
                  r"""|(head)\s+(?:-n\s*)?-?\d*\s*"?\$\{?0\}?"?""")
n_src, n_self = 0, 0
for p in sorted(tracked):
    st = styles(p)
    if st is None:
        continue
    t = text(p)
    if t is None:
        continue
    n_src += 1
    lines = t.split("\n")
    k = first(lines, p, st[0])
    want = {s: [STYLE[s][0] + h + STYLE[s][1] for h in HDR] for s in st}
    if lines[k:k + 2] not in want.values():
        at = [i + 1 for i, l in enumerate(lines[:60]) if HDR[0] in l]
        spdx = [l for l in lines[:60] if "SPDX-License-Identifier:" in l and HDR[1] not in l]
        if spdx:
            bad.append(f"1: {p}: {spdx[0].strip()} - the header names Apache-2.0")
        elif at:
            bad.append(f"1: {p}: the header is at line {at[0]}, not line {k + 1} (or not in the {' or '.join(st)} comment syntax)")
        else:
            bad.append(f"1: {p}: no license header (lines {k + 1}-{k + 2}: {' / '.join(want[st[0]])})")
        continue
    for m in SELF.finditer(t):
        n_self += 1
        if m.group(3) is not None:
            # an awk program prints from the lowest line its NR conditions let through (none: from line 1)
            start = min([int(n) + (op == ">") for op, n in re.findall(r"\bNR\s*(>=|>)\s*(\d+)", m.group(3))] or [1])
        else:
            start = 1 if m.group(5) else int(m.group(1) or m.group(4))
        if start <= k + 2:
            bad.append(f"2: {p}: '{m.group(0)}' prints from line {start}, the header is lines {k + 1}-{k + 2}")
        elif m.group(2) and int(m.group(2)) < start:
            bad.append(f"2: {p}: '{m.group(0)}' is an empty range")
if n_src < 100:
    bad.append(f"1: only {n_src} first-party source files found - is the list of tracked files complete?")

# 3. LICENSE and NOTICE
lic = text("LICENSE") or ""
for want in ("Apache License", "Version 2.0, January 2004", "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION",
             "1. Definitions.", "9. Accepting Warranty or Additional Liability.", "END OF TERMS AND CONDITIONS"):
    if want not in lic:
        bad.append(f"3: LICENSE is not the Apache-2.0 text: no '{want}'")
if not lic.lstrip().startswith("Apache License"):
    bad.append("3: LICENSE does not start with 'Apache License'")
third = text("THIRD-PARTY")
if not third or not third.startswith("Do Agent on AWS - third-party software in this repository\n"):
    bad.append("3: no THIRD-PARTY file attributing the third-party code copied into the repository")
if text("NOTICE") != "Do Agent on AWS\n" + HDR[0] + "\n":
    bad.append(f"3: NOTICE is not the project's name and Amazon's copyright line: {(text('NOTICE') or '(missing)')[:120]!r}")

# 4. the vendored projects
readme = text("README.md") or ""
registry = text("Container-Root/setup/third-party.txt") or ""
vend = sorted(p.split("/")[2] for p in tracked if re.fullmatch(r"Container-Root/opt/[^/]+/VENDORED\.md", p))
if not vend:
    bad.append("4: no vendored project (Container-Root/opt/<name>/VENDORED.md) found")
for v in vend:
    if f"Container-Root/opt/{v}/LICENSE" not in tracked:
        bad.append(f"4: Container-Root/opt/{v} has no LICENSE")
    if not re.search(r"bundled in this repository at Container-Root/opt/" + re.escape(v) + r"(?![\w.-])", registry):
        bad.append(f"4: Container-Root/setup/third-party.txt does not say {v} is bundled at Container-Root/opt/{v}")
    if not re.search(r"^   In this repository: Container-Root/opt/" + re.escape(v) + r"$", third or "", re.M) \
            or f"Container-Root/opt/{v}/LICENSE" not in (third or ""):
        bad.append(f"4: THIRD-PARTY has no entry naming Container-Root/opt/{v} and its LICENSE")
    if f"Container-Root/opt/{v}/NOTICE" in tracked and f"Container-Root/opt/{v}/NOTICE" not in (third or ""):
        bad.append(f"4: THIRD-PARTY does not name Container-Root/opt/{v}/NOTICE")
listing = text("THIRD-PARTY-LICENSES") or ""
for name, spdx in (("postgresql_binaries", "PostgreSQL"), ("swagger-ui-dist", "Apache-2.0")):
    if not re.search(r"^" + re.escape(name) + r" \S+ - " + re.escape(spdx) + r"\b", listing, re.M):
        bad.append(f"4: THIRD-PARTY-LICENSES does not list {name} under {spdx}")
if not re.search(r"^postgresql_binaries \$\(.*\) - PostgreSQL - https://github\.com/theseus-rs/postgresql_binaries - ", registry, re.M):
    bad.append("4: Container-Root/setup/third-party.txt has no postgresql_binaries line (the PostgreSQL server pg0-embedded unpacks)")

# 5. the README's notices, and what the repository holds
# the project's full name, spelled out as Trademark Legal approved it, and where the repository is
if not readme.startswith("# Do Agent on AWS\n"):
    bad.append("5: README.md does not open with the project's full name as its title: '# Do Agent on AWS'")
top = readme[:4000]
for want, what in (("Do Agent on AWS (repository `do-agent-aws`)", "the full name with the repository name"),
                   ("is an open-source project, not an AWS service or product", "that it is not an AWS service or product"),
                   ('provided "as is", use at your own risk', "the use-at-your-own-risk disclaimer")):
    if want not in top:
        bad.append(f"5: README.md's opening lacks {what}: '{want}'")
if "git clone https://github.com/awslabs/do-agent-aws.git\ncd do-agent-aws\n" not in readme:
    bad.append("5: README.md's quick start does not clone https://github.com/awslabs/do-agent-aws.git")
m = re.search(r"^## License and third-party software\n(.*?)(?=^#{1,2} |\Z)", readme, re.S | re.M)
sec = m.group(1) if m else ""
if not m:
    bad.append("5: README.md has no section 'License and third-party software'")
flat = re.sub(r"\s+", " ", sec)
for want, what in (("[LICENSE](LICENSE)", "a link to LICENSE"), ("[NOTICE](NOTICE)", "a link to NOTICE"),
                   ("[THIRD-PARTY](THIRD-PARTY)", "a link to THIRD-PARTY"),
                   ("Claude Code is not part of this repository", "that Claude Code is not part of the repository"),
                   ("installs it from npm", "that the build installs Claude Code from npm"),
                   ("subject to Anthropic's commercial terms (https://www.anthropic.com/legal/commercial-terms)",
                    "that Claude Code's use is subject to Anthropic's commercial terms"),
                   ("Although this repository is released under the Apache-2.0 license, it depends on third-party packages",
                    "the notice of dependencies with restricted licenses"),
                   ("may be restricted by your company's open source policy", "the notice of dependencies with restricted licenses")):
    if want not in flat:
        bad.append(f"5: README.md's section lacks {what}: '{want}'")
items = [re.sub(r"\s+", " ", i) for i in re.findall(r"^\* (.*?)(?=^\* |^$|\Z)", sec, re.S | re.M)]
for name, url in (("Plane", "https://github.com/makeplane/plane"), ("pgsty/silo", "https://github.com/pgsty/silo")):
    if not any(i.startswith(f"{name} ({url})") and "AGPL-3.0" in i for i in items):
        bad.append(f"5: the restricted-license notice does not list {name} ({url}) as AGPL-3.0")
if not any(i.startswith("Plane (") and "off by default" in i for i in items):
    bad.append("5: the notice does not say Plane is off by default")
plane = re.findall(r"^export UI_PLANE=(.*)$", text(".env") or "", re.M)
if plane != ["false"]:
    bad.append(f"5: .env does not keep Plane off by default (export UI_PLANE=false): {plane}")
if not re.search(r"^/setup/install-claude\.sh\b", text("Container-Root/setup.sh") or "", re.M) \
        or not re.search(r'^\s*npm install -g "@anthropic-ai/claude-code@', text("Container-Root/setup/install-claude.sh") or "", re.M):
    bad.append("5: the image build (Container-Root/setup.sh) does not install Claude Code from npm (/setup/install-claude.sh)")
AGPL = ("GNU AFFERO GENERAL " + "PUBLIC LICENSE", "Version 3, 19 " + "November 2007")
for p in sorted(tracked):
    if "/node_modules/" in "/" + p or "@anthropic-ai/" in p or re.search(r"(^|/)claude-code/", p):
        bad.append(f"5: git tracks {p}: Claude Code and npm packages are installed at build time, never committed")
    t = text(p)
    if t and all(a in t for a in AGPL):
        bad.append(f"5: git tracks an AGPL-3.0 license text: {p} (Plane and silo are pulled as images at run time)")
    if t and re.search(r"SPDX-License-Identifier:\s*" + "AGPL", t):
        bad.append(f"5: git tracks a file under the AGPL: {p}")
print("\n".join(bad) if bad else f"{n_src} {n_self} {len(vend)}")
sys.exit(1 if bad else 0)
PY

check() { python3 -I "${D}/check.py" . "${D}/tracked" "$@"; }

OUT=$(check) || fail "${OUT}"
read -r N_SRC N_SELF N_VEND <<< "${OUT}"
echo "ok 1 - all ${N_SRC} first-party source files start with the Apache-2.0 license header, below the lines that must stay first"
echo "ok 2 - the ${N_SELF} help texts that scripts print from their own source start below the header"
echo "ok 3 - LICENSE is the Apache-2.0 text, NOTICE the project's name and Amazon's copyright line, THIRD-PARTY is there"
echo "ok 4 - the ${N_VEND} vendored projects keep their LICENSE, each with its THIRD-PARTY entry and its bundled note in the registry; THIRD-PARTY-LICENSES lists postgresql_binaries and swagger-ui-dist"
echo "ok 5 - README.md opens with the full name Do Agent on AWS (repository do-agent-aws), says it is not an AWS service or product, clones the public repository, links LICENSE, NOTICE and THIRD-PARTY and carries the Claude Code terms and the restricted-license notice (Plane, pgsty/silo); Plane is off in .env; git tracks no Claude Code copy and no AGPL-3.0 text"

# 6. planted controls: each fails the check that names it
plant()
{
	# plant <name> <check> <path> new <text>       - a new tracked file
	# plant <name> <check> <path> replace <a> <b>  - a copy of a tracked file, its one <a> replaced with <b>
	python3 -I - "$3" "${D}/$1.planted" "$4" "$5" "$6" << 'PY'
import sys
path, out, mode, a, b = sys.argv[1:6]
if mode == "new":
    t = a
else:
    s = open(path, encoding="utf-8").read()
    assert s.count(a) == 1, f"'{a[:60]}' occurs {s.count(a)} times in {path}, not once"
    t = s.replace(a, b)
open(out, "w", encoding="utf-8").write(t)
PY
	[ $? -eq 0 ] || fail "6: could not plant $1"
	P=$(check --set "$3" "${D}/$1.planted") && fail "6: PLANTED CONTROL: $1 passed the checker"
	echo "${P}" | grep -q "^$2: " || fail "6: PLANTED CONTROL: $1 did not fail check $2: ${P}"
	return 0
}
H1="Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved."
H2="SPDX-License-Identifier: Apache-2.0"
plant noheader 1 build.sh replace "# ${H1}"$'\n'"# ${H2}"$'\n' ""
plant below 1 test.sh replace $'#!/bin/bash\n'"# ${H1}" $'#!/bin/bash\nset -e\n'"# ${H1}"
plant spdx 1 build.sh replace "# ${H2}" "# SPDX-License-Identifier: MIT-0"
plant newscript 1 Container-Root/agent/planted-tool.sh new $'#!/bin/bash\necho planted\n'
plant shebang 1 Container-Root/agent/planted-tool new $'#!/usr/bin/env python3\nprint("planted")\n'
plant syntax 1 Container-Root/agent/board-ui/board.css replace "/* ${H1} */" "# ${H1}"
plant sedhelp 2 Container-Root/agent/learn.sh replace "sed -n '5,22p' \"\$0\"" "sed -n '3,22p' \"\$0\""
plant awkhelp 2 to/sandbox/test/e2e.sh replace "awk 'NR >= 5 && /^#/" "awk 'NR >= 3 && /^#/"
plant license 3 LICENSE replace "Version 2.0, January 2004" "Version 1.1"
plant notice 3 NOTICE replace "${H1}" "Copyright Example Corp."
plant noticeextra 3 NOTICE replace $'Do Agent on AWS\n' $'Do Agent on AWS\nThis product includes software developed by others.\n'
plant registry 4 Container-Root/setup/third-party.txt replace "bundled in this repository at Container-Root/opt/tmux-agent" "installed at build time"
plant thirdentry 4 THIRD-PARTY replace $'   In this repository: Container-Root/opt/loop-deck\n' ""
plant thirdnotice 4 THIRD-PARTY replace "Container-Root/opt/tmux-agent/NOTICE" "its NOTICE"
plant pgregistry 4 Container-Root/setup/third-party.txt replace $'\npostgresql_binaries $(ls' $'\npostgres $(ls'
plant pglisting 4 THIRD-PARTY-LICENSES replace $'\npostgresql_binaries ' $'\npostgres '
plant swaggerlisting 4 THIRD-PARTY-LICENSES replace $'\nswagger-ui-dist ' $'\nswagger-ui '
P=$(check --drop Container-Root/opt/loop-deck/LICENSE) && fail "6: PLANTED CONTROL: a vendored project without its LICENSE passed the checker"
echo "${P}" | grep -q "^4: " || fail "6: PLANTED CONTROL: a vendored project without its LICENSE did not fail check 4: ${P}"
plant readmetitle 5 README.md replace $'# Do Agent on AWS\n' $'# do-agent-aws\n'
plant readmenotaws 5 README.md replace "is an open-source project, not an AWS service or product." "is an open-source project."
plant readmerisk 5 README.md replace 'provided "as is", use at your own risk' "for non-production usage"
plant readmeclone 5 README.md replace "git clone https://github.com/awslabs/do-agent-aws.git" "git clone https://github.com/iankouls-aws/aws-do-agent.git"
plant thirdlink 5 README.md replace "[THIRD-PARTY](THIRD-PARTY)" "THIRD-PARTY"
plant nothird 3 THIRD-PARTY replace "Do Agent on AWS - third-party software in this repository" "Third-party software"
plant anthropic 5 README.md replace $'Anthropic\'s\ncommercial terms' $'Anthropic\'s\nterms'
plant silo 5 README.md replace "* pgsty/silo (https://github.com/pgsty/silo)" "* an object store (https://github.com/pgsty/silo)"
plant plane 5 README.md replace "* Plane (https://github.com/makeplane/plane): AGPL-3.0." "* Plane (https://github.com/makeplane/plane): see its site."
plant ospo 5 README.md replace "Although this repository is released under the Apache-2.0 license" "This repository is released under the Apache-2.0 license"
plant planeon 5 .env replace $'\nexport UI_PLANE=false\n' $'\nexport UI_PLANE=true\n'
plant agpl 5 plane/vendor/LICENSE new "                    GNU AFFERO GENERAL ""PUBLIC LICENSE"$'\n'"                       Version 3, 19 ""November 2007"$'\n'
plant claudecopy 5 node_modules/@anthropic-ai/claude-code/cli.js new "// ${H1}"$'\n'"// ${H2}"$'\n'
plant noinstall 5 Container-Root/setup.sh replace "/setup/install-claude.sh ||" "true ||"
echo "ok 6 - PLANTED CONTROLS: a missing header, a header below code, another SPDX id, a new script and a #! file without the header, the wrong comment syntax, two help ranges into the header, another license, two changed NOTICEs, a vendored project without its THIRD-PARTY entry or NOTICE, its registry note or its LICENSE, the PostgreSQL binaries and swagger-ui-dist gone from the registry or the listing, a THIRD-PARTY without its title, five README notices, the README's title, its not-an-AWS-product line, its use-at-your-own-risk disclaimer and its clone address taken out, Plane on, a tracked AGPL-3.0 text, a tracked Claude Code copy and a build without it each fail their check"
echo "Test-license-headers succeeded"
