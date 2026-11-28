#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of the README and the manual under docs/manual (run by test.sh); it reads files and git only, never
# docker. The README is the landing page and the manual holds the reference, one page per topic, so what ties them
# together must not rot. Each check FAILS if the property is removed:
#   1. every relative link in README.md and docs/manual/*.md names a file or folder that exists, and every #anchor in
#      such a link names a heading of its target page (GitHub's anchors: lower case, punctuation dropped, spaces to -)
#   2. every reference to a manual section anywhere in the repository - docs/manual/<page>.md "Section", or
#      <page>.md "Section" inside the manual - names a page that exists and a heading or lead text that page carries
#   3. every manual page is linked from the manual's index (docs/manual/README.md) and from the README, and no heading
#      repeats within a page (each anchor leads to one place)
#   4. the README stays a landing page: at most 200 lines, the detail in the manual
#   5. PLANTED CONTROLS: a link to a missing file, a link to a missing anchor, a reference to a section a page does not
#      carry, a page missing from the index, a repeated heading and a README over its budget each fail the checker

D=./scratch/test-docs-links
fail() { echo "Test-docs-links FAILED: $*"; exit 1; }
[ -f README.md ] && [ -d docs/manual ] || fail "run it from the repository root"
git rev-parse --is-inside-work-tree > /dev/null 2>&1 || fail "not a git checkout: the check reads the list of tracked files from git"
rm -rf "${D:?}" && mkdir -p "${D}" || fail "cannot create ${D}"
trap 'rm -rf "${D:?}"' EXIT
git ls-files -z > "${D}/tracked" || fail "git ls-files failed"

cat > "${D}/check.py" << 'PY'
import os, re, sys

root, listing = sys.argv[1], sys.argv[2]
over, args = {}, sys.argv[3:]
while args:
    if args[0] == "--set" and len(args) >= 3:
        over[args[1]], args = args[2], args[3:]
    else:
        sys.exit("usage: check.py ROOT LISTING [--set PATH FILE]...")
with open(listing, encoding="utf-8") as f:
    tracked = [p for p in f.read().split("\0") if p]
manual = sorted({p for p in tracked if re.fullmatch(r"docs/manual/[^/]+\.md", p)} | {p for p in over if p.startswith("docs/manual/")})

def text(p):
    try:
        with open(over.get(p, os.path.join(root, p)), encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None

def slug(h):
    h = re.sub(r"`", "", h.strip().lower())
    return re.sub(r"[^\w\- ]", "", h).replace(" ", "-")

def headings(t):
    out, fence = [], False
    for line in t.split("\n"):
        if line.startswith("```"):
            fence = not fence
            continue
        m = None if fence else re.match(r"^#{1,6} (.+)$", line)
        if m:
            out.append(m.group(1).strip())
    return out

def links(t):
    fence = False
    for n, line in enumerate(t.split("\n"), 1):
        if line.startswith("```"):
            fence = not fence
            continue
        if not fence:
            for m in re.finditer(r"\]\(([^)\s]+)\)", line):
                yield n, m.group(1)

bad = []
pages = ["README.md"] + manual
n_links = 0
# 1. links
for p in pages:
    t = text(p)
    if t is None:
        bad.append(f"1: {p} is not readable"); continue
    for n, target in links(t):
        if re.match(r"^(https?:|mailto:)", target):
            continue
        n_links += 1
        path, _, anchor = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(p), path)) if path else p
        if path and not (dest in over or os.path.exists(os.path.join(root, dest))):
            bad.append(f"1: {p}:{n}: the link {target} names {dest}, which does not exist"); continue
        if anchor and dest.endswith(".md"):
            dt = text(dest) or ""
            if anchor not in {slug(h) for h in headings(dt)}:
                bad.append(f"1: {p}:{n}: the link {target} names the anchor #{anchor}, which {dest} has no heading for")
# 2. references to manual sections, everywhere
names = {os.path.basename(m)[:-3]: m for m in manual}
REF = re.compile(r'(?<![\w/.-])(docs/manual/)?([a-z][a-z-]*)\.md((?:,)?\s+\(?\\?")((?:[^"\\\n]|\\.|\n[ \t]*(?:#+|//|\*|--)?[ \t]*){1,160}?)\\?"')
n_refs = 0
for p in sorted(set(tracked) | set(over)):
    if p.startswith("Container-Root/opt/") or p.endswith((".patch", ".png", ".jsonl", ".json")) or p == "THIRD-PARTY-LICENSES":
        continue
    t = text(p)
    if not t or ".md" not in t:
        continue
    for m in REF.finditer(t):
        page = m.group(2)
        if not m.group(1) and not p.startswith("docs/manual/"):
            continue
        if page not in names:
            if m.group(1):
                bad.append(f"2: {p}: names docs/manual/{page}.md, which does not exist")
            continue
        name = re.sub(r"\s+", " ", re.sub(r"\\?\n[ \t]*(?:#+|//|\*|--)?[ \t]*", " ", m.group(4))).strip()
        n_refs += 1
        pt = text(names[page]) or ""
        if name not in headings(pt) and name not in re.sub(r"\s+", " ", pt):
            bad.append(f"2: {p}: names docs/manual/{page}.md \"{name}\", which that page does not carry")
# 3. the index, the README and unique headings
index = text("docs/manual/README.md") or ""
readme = text("README.md") or ""
for m in manual:
    base = os.path.basename(m)
    if base == "README.md":
        continue
    if f"]({base})" not in index:
        bad.append(f"3: the manual's index does not link {base}")
    if f"](docs/manual/{base})" not in readme:
        bad.append(f"3: the README does not link docs/manual/{base}")
    hs = [slug(h) for h in headings(text(m) or "")]
    dup = sorted({h for h in hs if hs.count(h) > 1})
    if dup:
        bad.append(f"3: {m} repeats the heading(s) {dup}: their anchors lead to the first one only")
if len(manual) < 2:
    bad.append(f"3: only {len(manual)} manual page(s) found - is the list of tracked files complete?")
# 4. the README's budget
lines = readme.count("\n")
if lines > 200:
    bad.append(f"4: README.md has {lines} lines, over its budget of 200: move the detail into docs/manual")
print("\n".join(bad) if bad else f"{n_links} {n_refs} {len([m for m in manual if not m.endswith('/README.md')])} {lines}")
sys.exit(1 if bad else 0)
PY

check() { python3 -I "${D}/check.py" . "${D}/tracked" "$@"; }

OUT=$(check) || fail "${OUT}"
read -r N_LINKS N_REFS N_PAGES N_LINES <<< "${OUT}"
echo "ok 1 - the ${N_LINKS} relative links in README.md and the manual name files that exist and anchors their pages carry"
echo "ok 2 - the ${N_REFS} references to a manual section across the repository name a page and a section it carries"
echo "ok 3 - the manual's index and the README link all ${N_PAGES} manual pages, and no page repeats a heading"
echo "ok 4 - the README is a landing page: ${N_LINES} lines, the budget is 200"

# 5. planted controls: each fails the check that names it
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
	[ $? -eq 0 ] || fail "5: could not plant $1"
	P=$(check --set "$3" "${D}/$1.planted") && fail "5: PLANTED CONTROL: $1 passed the checker"
	echo "${P}" | grep -q "^$2: " || fail "5: PLANTED CONTROL: $1 did not fail check $2: ${P}"
	return 0
}
plant file 1 README.md replace "[docs/PERSONAS.md](docs/PERSONAS.md)" "[docs/PERSONAS.md](docs/NO-SUCH-PAGE.md)"
plant anchor 1 README.md replace "(docs/manual/install.md#what-runs)" "(docs/manual/install.md#what-ran)"
plant section 2 Container-Root/planted.sh new "# docs/manual/install"".md \"A section that is not there\""$'\n'
plant index 3 docs/manual/README.md replace "](ui.md)" "](ui-gone.md)"
plant repeat 3 docs/manual/boards.md new $'# The boards\n\n## Board\n\ntext\n\n## Board\n\ntext\n'
plant budget 4 README.md replace $'## Contents\n' "## Contents"$'\n'"$(printf 'filler\n%.0s' $(seq 1 60))"$'\n'
echo "ok 5 - PLANTED CONTROLS: a link to a missing file, a link to a missing anchor, a reference to a section a page does not carry, a page missing from the index, a repeated heading and a README over its budget each fail their check"
echo "Test-docs-links succeeded"
