#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side test of SECURITY.md's responsibility table and its configuration disclaimer (run by test.sh); it reads files only,
# never docker. SECURITY.md is guidance that must not go stale, so it names no version, CVE identifier or date: the list of
# open findings is whatever the scans report today, and the file says who is responsible for each class of finding. Each
# check FAILS if the property is removed:
#   1. the table is a CSV block with its exact columns and rows of one width, one row for each class of finding the file
#      promises (vendored code, pinned tools, packages, images, first-party code, history-only hits, services, your
#      configuration), and every owner is this-repo, operator or upstream:<who>
#   2. every folder, script and file the section names exists in the repository (the vendored folder, the install scripts,
#      ./scan.sh, ./test.sh, THIRD-PARTY-LICENSES, .env, the Dockerfile), and each vendored project has its VENDORED.md
#   3. the file names no version, CVE identifier or date (IP addresses and the T and B ids do not count)
#   4. the section "Your configuration is your responsibility" says every configuration you set, change or add is yours to
#      secure, and names the settings and the places that move the responsibility to you; README.md points at it
#   5. PLANTED CONTROLS: a copy with a version, a CVE id, a date, a product version, an unknown owner, a missing class, a
#      script the section no longer names, a row of the wrong width and no disclaimer each fail the same checker (checks 1
#      to 4 can tell)

SEC=SECURITY.md
D=./scratch/test-security-md
fail() { echo "Test-security-md FAILED: $*"; exit 1; }
rm -rf "${D:?}" && mkdir -p "${D}" || fail "cannot create ${D}"
trap 'rm -rf "${D:?}"' EXIT
[ -f "${SEC}" ] && [ -f README.md ] || fail "run it from the repository root"

cat > "${D}/check.py" << 'PY'
import csv, io, os, re, sys

sec, readme = sys.argv[1], sys.argv[2]
text = open(sec, encoding="utf-8").read()
bad = []

# 1. the table
blocks = re.findall(r"```csv\n(.*?)```", text, re.S)
if len(blocks) != 1:
    sys.exit(f"1: {len(blocks)} csv blocks in {sec}, not 1")
rows = list(csv.reader(io.StringIO(blocks[0])))
COLS = ["class", "where it is", "flaw fixed by", "fix taken by", "how to see it"]
if rows[0] != COLS:
    bad.append(f"1: the columns are {rows[0]}, not {COLS}")
body = [r for r in rows[1:] if r]
for r in body:
    if len(r) != len(COLS):
        bad.append(f"1: a row has {len(r)} fields, not {len(COLS)}: {r[0] if r else '(empty)'}")
CLASSES = ["vendored third-party code", "pinned tool binaries and installers", "operating-system and language packages",
           "base and sidecar container images", "this repository's own code, scripts, tests and docs",
           "scanner hits that are not in the tree", "third-party services you connect",
           "your configuration and where you run it"]
have = [r[0] for r in body if len(r) == len(COLS)]
for c in CLASSES:
    if c not in have:
        bad.append(f"1: no row for the class '{c}'")
if len(have) != len(set(have)):
    bad.append("1: a class appears twice")
WHO = re.compile(r"this-repo|operator|upstream:<[^<>]+>")
for r in body:
    if len(r) != len(COLS):
        continue
    if not WHO.fullmatch(r[2]):
        bad.append(f"1: '{r[0]}': '{r[2]}' is not this-repo, operator or upstream:<who>")
    if not r[3].startswith(("this-repo", "operator", "a rebuild", "nothing in the tree")):
        bad.append(f"1: '{r[0]}': who takes the fix is not stated: '{r[3][:40]}'")

# 2. what the section names exists
section = text[text.index("## Open findings and who is responsible for each"):text.index("## Your configuration is your responsibility")]
for path in ("Container-Root/opt", "Container-Root/setup", "scan.sh", "test.sh", "THIRD-PARTY-LICENSES", ".env", "Dockerfile"):
    if not os.path.exists(path):
        bad.append(f"2: {path} does not exist")
    elif path not in section:
        bad.append(f"2: the section no longer names {path}")
for d in ("issues-tracker", "loglearner", "loop-deck", "tmux-agent"):
    if not os.path.isfile(f"Container-Root/opt/{d}/VENDORED.md"):
        bad.append(f"2: the vendored project {d} has no VENDORED.md")

# 3. no version, CVE id or date
plain = re.sub(r"\b(?:127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?", "", text)
for pat, what in ((r"CVE-\d{4}-\d+", "a CVE identifier"), (r"\bv?\d+\.\d+(?:\.\d+)+\b", "a version"),
                  (r"\b\d{4}-\d{2}-\d{2}\b", "a date"),
                  (r"\b(?:Ubuntu|Python|Node(?:\.js)?|npm|Go|Kubernetes|kubectl)\s+v?\d+(?:\.\d+)*\b", "a product version")):
    for m in re.finditer(pat, plain):
        bad.append(f"3: {what} in {sec}: '{m.group(0)}'")

# 4. the disclaimer
m = re.search(r"^## Your configuration is your responsibility\n(.*?)(?=^## )", text, re.S | re.M)
if not m:
    bad.append("4: no section 'Your configuration is your responsibility'")
else:
    flat = re.sub(r"\s+", " ", m.group(1)).replace("**", "")
    for want in ("Every configuration you set, change or add is yours to secure", "UI_BIND_HOST", "SLACK_ALLOWED_USERS",
                 "the AWS credentials", "every mount or volume you add", "Where it runs",
                 "do not secure, monitor or support your deployment"):
        if want not in flat:
            bad.append(f"4: the disclaimer lacks '{want}'")
opening = re.sub(r"\s+", " ", re.split(r"^## ", open(readme, encoding="utf-8").read(), maxsplit=1, flags=re.M)[0])
if "SECURITY.md" not in opening or "configuration" not in opening or "your responsibility" not in opening:
    bad.append("4: README.md's opening does not point at SECURITY.md and say that the configuration is your responsibility")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY

check() { python3 -I "${D}/check.py" "$1" README.md; }

OUT=$(check "${SEC}") || fail "${OUT}"
N=$(python3 -I - "${SEC}" << 'PY'
import csv, io, re, sys
print(len(list(csv.reader(io.StringIO(re.findall(r"```csv\n(.*?)```", open(sys.argv[1], encoding="utf-8").read(), re.S)[0])))) - 1)
PY
)
echo "ok 1 - SECURITY.md's table has its exact columns and one row of one width for each of the ${N} classes of finding, each owned by this-repo, operator or upstream:<who>"
echo "ok 2 - every folder, script and file the section names exists, and each vendored project has its VENDORED.md"
echo "ok 3 - SECURITY.md names no version, CVE identifier or date, so it does not go stale"
echo "ok 4 - the configuration disclaimer names what moves the responsibility to you, and README.md points at it"

# 5. planted controls: the same checker must fail each
plant()
{
	# plant <name> <python expression on the text s> - a copy of SECURITY.md, changed
	python3 -I - "${SEC}" "${D}/$1.md" "$2" << 'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
t = eval(sys.argv[3], {"s": s})
assert t != s, "the planted change did nothing"
open(sys.argv[2], "w", encoding="utf-8").write(t)
PY
	[ $? -eq 0 ] || fail "5: could not plant $1"
	check "${D}/$1.md" > /dev/null 2>&1 && fail "5: PLANTED CONTROL: $1 passed the checker"
	return 0
}
plant version 's.replace("the install scripts under Container-Root/setup/", "the install scripts (kubectl 1.2.3) under Container-Root/setup/", 1)'
plant cve 's.replace("a scanner of your choice over each image", "CVE-2026-12345 in each image", 1)'
plant date 's.replace("Scanners report findings against", "As of 2026-11-18, scanners report findings against", 1)'
plant product 's.replace("an Ubuntu LTS image", "an Ubuntu 22.04 image", 1)'
plant owner 's.replace(",operator,operator,", ",nobody,operator,", 1)'
plant class 's.replace("third-party services you connect", "services", 1)'
plant script 's.replace("./scan.sh and THIRD-PARTY-LICENSES", "THIRD-PARTY-LICENSES").replace("`./scan.sh`", "the scan")'
plant width 's.replace("operator,operator,the section below", "operator,the section below", 1)'
plant nodisclaimer 's.replace("Every\nconfiguration you set, change or add is yours to secure.", "Be careful.", 1)'
echo "ok 5 - PLANTED CONTROLS: a version, a CVE id, a date, a product version, an unknown owner, a missing class, a script the section no longer names, a row of the wrong width and a removed disclaimer each fail the checker"
echo "Test-security-md succeeded"
