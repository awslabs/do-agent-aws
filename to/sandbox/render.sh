#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Render the Docker Sandboxes kit for this repository into
# to/sandbox/app/do-agent-aws-sandbox/ - the to/<target>/template -> app pattern
# of to/compose and to/kubernetes. A kit's build context is the directory that
# holds its descriptor, so the rendered directory is self-contained:
#   do-agent-aws-sandbox.yaml          kit descriptor (template/)
#   do-agent-aws-sandbox.dockerfile    ./Dockerfile + template/sandbox.dockerfile
#   do-agent-aws-sandbox-context.md    agent instructions (template/)
#   Container-Root/, docs/..., ...     every source that a COPY or ADD of that
#                                      dockerfile names, at its repository path
# The sources are read from the dockerfile's COPY and ADD instructions (except
# --from=, URLs and heredocs, which do not read the build context), so a new
# COPY needs no change here. A source that HEAD does not hold, that leaves the
# context or names a variable, or that the repository's .dockerignore excludes
# entirely, stops the render with its name; files .dockerignore excludes are
# left out, as the repository build leaves them out of its context.
# Everything comes from the committed tree at HEAD (git archive), never from
# the working tree, so nothing untracked, ignored or uncommitted enters the
# kit; commit before rendering. The result is checked file by file against
# git ls-tree before it replaces the previous render. Renders are serialized
# with flock, and the new directory is moved into place with a rename. The
# repository Dockerfile is used verbatim, so the sandbox image builds the same
# harness as ./build.sh. to/sandbox/app/ is generated and not committed.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KIT_NAME=do-agent-aws-sandbox
APP_ROOT=${BASE_DIR}/to/sandbox/app
APP_DIR=${APP_ROOT}/${KIT_NAME}
TEMPLATE=to/sandbox/template

fail()
{
	echo "render.sh: $1" >&2
	exit 1
}

# The build-context sources of a dockerfile's COPY and ADD instructions: one
# line per source, SRC<TAB>path (cleaned; empty = the whole context), or
# ERR<TAB>reason. Reads backslash continuations, JSON and shell forms and
# flags, and skips comments and heredoc bodies.
IFS= read -r -d '' SOURCES_AWK << 'EOF' || true
function clean(s) {
	while (s ~ /^\.\//) s = substr(s, 3)
	sub(/^\/+/, "", s)
	gsub(/\/+/, "/", s)
	while (s ~ /\/\.\//) sub(/\/\.\//, "/", s)
	while (s ~ /^\.\//) s = substr(s, 3)
	sub(/\/\.$/, "", s)
	sub(/\/$/, "", s)
	if (s == ".") s = ""
	return s
}
# the shell words of s, quotes kept as written: BuildKit finds heredocs this way
function words(s, w,   n, i, c, q, cur, inw) {
	n = 0
	q = ""
	cur = ""
	inw = 0
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (q == "" && (c == " " || c == "\t")) {
			if (inw) { w[++n] = cur; cur = ""; inw = 0 }
			continue
		}
		inw = 1
		cur = cur c
		if (c == "\\" && q != "'" && i < length(s)) { i++; cur = cur substr(s, i, 1); continue }
		if (q == "" && (c == "\"" || c == "'")) q = c
		else if (q != "" && c == q) q = ""
	}
	if (inw) w[++n] = cur
	return n
}
# a word without its quotes and backslash escapes, as BuildKit reads a source
function unq(s,   r, i, c, q) {
	r = ""
	q = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (q != "'" && c == "\\" && i < length(s)) { i++; r = r substr(s, i, 1); continue }
		if (q == "" && (c == "\"" || c == "'")) { q = c; continue }
		if (q != "" && c == q) { q = ""; continue }
		r = r c
	}
	return r
}
# a heredoc word, <<NAME, <<-NAME, <<"NAME" or 2<<NAME (BuildKit's
# ^(\d*)<<(-?)([^<]*)$ on a shell word): sets hname and htab
function isheredoc(s) {
	if (s !~ /^[0-9]*<<-?[^<]+$/) return 0
	sub(/^[0-9]*<</, "", s)
	htab = (substr(s, 1, 1) == "-")
	sub(/^-/, "", s)
	hname = unq(s)
	return hname != ""
}
function emit(s, kw) {
	if (s ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\// || s ~ /^git@/) return
	if (index(s, "$")) { print "ERR\tline " start ": the " kw " source " s " names a variable, which render.sh does not expand"; return }
	s = clean(s)
	if (s ~ /(^|\/)\.\.(\/|$)/) { print "ERR\tline " start ": the " kw " source " s " is outside the build context"; return }
	print "SRC\t" s
}
function flush(   rest, kw, flag, n, i, t, s, w) {
	rest = inst
	inst = ""
	sub(/^[ \t]+/, "", rest)
	if (!match(rest, /^[A-Za-z]+/)) return
	kw = toupper(substr(rest, 1, RLENGTH))
	if (kw != "COPY" && kw != "ADD") return
	rest = substr(rest, RLENGTH + 1)
	sub(/^[ \t]+/, "", rest)
	sub(/[ \t]+$/, "", rest)
	while (match(rest, /^--[^ \t]*/)) {
		flag = substr(rest, 1, RLENGTH)
		rest = substr(rest, RLENGTH + 1)
		sub(/^[ \t]+/, "", rest)
		if (flag ~ /^--from=/) return
	}
	n = 0
	json = (substr(rest, 1, 1) == "[")
	if (json) {
		s = rest
		while (match(s, /"([^"\\]|\\.)*"/)) {
			t = substr(s, RSTART + 1, RLENGTH - 2)
			gsub(/\\"/, "\"", t)
			gsub(/\\\\/, "\\", t)
			w[++n] = t
			s = substr(s, RSTART + RLENGTH)
		}
	} else {
		n = words(rest, w)
	}
	if (n < 2) { print "ERR\tline " start ": " kw " without a source and a destination"; return }
	# shell form: a heredoc word is an inline source, and quotes are not part of a path
	for (i = 1; i < n; i++) {
		if (json) emit(w[i], kw)
		else if (!isheredoc(w[i])) emit(unq(w[i]), kw)
	}
}
BEGIN { hdn = 0; hdi = 1 }
{
	line = $0
	sub(/\r$/, "", line)
	# heredoc bodies, in order, each ended by a line that is its name
	if (hdi <= hdn) {
		t = line
		if (hdt[hdi]) sub(/^\t+/, "", t)
		if (t == hdw[hdi]) hdi++
		next
	}
	if (!seen && line ~ /^[ \t]*#[ \t]*escape[ \t]*=/) { print "ERR\tline " NR ": the escape parser directive is not read by render.sh"; next }
	# comments and blank lines, also inside a continuation (BuildKit skips both there)
	if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) next
	if (inst == "") start = NR
	seen = 1
	if (line ~ /\\[ \t]*$/) {
		sub(/\\[ \t]*$/, "", line)
		inst = inst line " "
		next
	}
	inst = inst line
	# heredocs, as BuildKit finds them: only in shell-form RUN, COPY and ADD
	# (ONBUILD included), a shell word that starts with << names a body that
	# follows; << inside quotes or in the JSON form is text
	hdn = 0
	hdi = 1
	s = inst
	sub(/^[ \t]+/, "", s)
	if (toupper(s) ~ /^ONBUILD[ \t]/) sub(/^[A-Za-z]+[ \t]+/, "", s)
	if (index(s, "<<") && match(s, /^[A-Za-z]+/) && toupper(substr(s, 1, RLENGTH)) ~ /^(RUN|COPY|ADD)$/) {
		s = substr(s, RLENGTH + 1)
		sub(/^[ \t]+/, "", s)
		while (match(s, /^--[^ \t]*[ \t]*/)) s = substr(s, RLENGTH + 1)
		if (substr(s, 1, 1) != "[") {
			m = words(s, ws)
			for (i = 1; i <= m; i++) if (isheredoc(ws[i])) { hdw[++hdn] = hname; hdt[hdn] = htab }
		}
	}
	flush()
}
END {
	# an unterminated heredoc would hide every instruction after it; BuildKit refuses it too
	if (hdi <= hdn) print "ERR\tline " start ": the heredoc " hdw[hdi] " is not terminated"
	else if (inst != "") flush()
}
EOF

# Which tracked files those sources stage. Inputs: the ignore file, the
# sources (one per line), git ls-tree -r of HEAD. Prints FILE<TAB>mode sha path
# per file to stage, MISS<TAB>source for a source that matches no tracked file
# and IGN<TAB>source for one whose every file the ignore file excludes.
# Sources match as COPY does (* ? [..] within one path component; a directory
# brings its tree); ignore patterns as Docker reads .dockerignore (anchored at
# the context root, ** across directories, ! re-includes, the last match wins,
# a match on a parent directory excludes its files).
IFS= read -r -d '' MATCH_AWK << 'EOF' || true
function q(c) { return index("\\^$.[]|()*+?{}", c) ? "\\" c : c }
function clean(s) {
	while (s ~ /^\.\//) s = substr(s, 3)
	sub(/^\/+/, "", s)
	gsub(/\/+/, "/", s)
	while (s ~ /\/\.\//) sub(/\/\.\//, "/", s)
	sub(/\/\.$/, "", s)
	sub(/\/$/, "", s)
	if (s == ".") s = ""
	return s
}
function glob(s,   re, i, n, c, j) {
	re = ""
	n = length(s)
	for (i = 1; i <= n; i++) {
		c = substr(s, i, 1)
		if (c == "*") re = re "[^/]*"
		else if (c == "?") re = re "[^/]"
		else if (c == "[" && (j = index(substr(s, i + 1), "]")) > 0) { re = re "[" substr(s, i + 1, j); i += j }
		else if (c == "\\" && i < n) { i++; re = re q(substr(s, i, 1)) }
		else re = re q(c)
	}
	return re
}
function ign(p,   re, i, n, c) {
	re = "^"
	n = length(p)
	for (i = 1; i <= n; i++) {
		c = substr(p, i, 1)
		if (c == "*") {
			if (substr(p, i + 1, 1) == "*") {
				i++
				if (substr(p, i + 1, 1) == "/") i++
				re = re (i >= n ? ".*" : "(.*/)?")
			} else re = re "[^/]*"
		} else if (c == "?") re = re "[^/]"
		else if (c == "[" || c == "]") re = re c
		else if (c == "\\" && i < n) { i++; re = re q(substr(p, i, 1)) }
		else re = re q(c)
	}
	return re "$"
}
function ignored(f,   m, k, hit, np, parts, j, pre) {
	m = 0
	np = split(f, parts, "/")
	for (k = 1; k <= ni; k++) {
		if (iex[k] != m) continue
		hit = (f ~ ire[k])
		for (j = 1; !hit && j < np; j++) {
			pre = (j == 1 ? parts[1] : pre "/" parts[j])
			hit = (pre ~ ire[k])
		}
		if (hit) m = !iex[k]
	}
	return m
}
FILENAME == ARGV[1] {
	p = $0
	sub(/^[ \t]+/, "", p)
	sub(/[ \t\r]+$/, "", p)
	if (p == "" || p ~ /^#/) next
	ex = 0
	if (substr(p, 1, 1) == "!") { ex = 1; p = substr(p, 2); sub(/^[ \t]+/, "", p) }
	p = clean(p)
	if (p == "") next
	ni++
	ire[ni] = ign(p)
	iex[ni] = ex
	next
}
FILENAME == ARGV[2] { ns++; src[ns] = $0; sre[ns] = ($0 == "" ? "" : "^" glob($0) "(/.*)?$"); next }
{
	split($0, a, "\t")
	split(a[1], m, " ")
	if (m[2] != "blob") next
	f = a[2]
	for (i = 1; i <= ns; i++) {
		if (sre[i] != "" && f !~ sre[i]) continue
		cand[i]++
		if (!(f in seen)) {
			seen[f] = 1
			if (ignored(f)) skip[f] = 1
			else print "FILE\t" m[1] " " m[3] " " f
		}
		if (!(f in skip)) kept[i]++
	}
}
END {
	for (i = 1; i <= ns; i++) {
		if (!cand[i]) print "MISS\t" (src[i] == "" ? "." : src[i])
		else if (!kept[i]) print "IGN\t" (src[i] == "" ? "." : src[i])
	}
}
EOF

command -v git > /dev/null || fail "git is required"
command -v flock > /dev/null || fail "flock is required"
REV=$(git -C "${BASE_DIR}" rev-parse --verify HEAD 2> /dev/null) || fail "${BASE_DIR} is not a git checkout with a commit"
PATHS=(Dockerfile "${TEMPLATE}/${KIT_NAME}.yaml" "${TEMPLATE}/${KIT_NAME}-context.md" "${TEMPLATE}/sandbox.dockerfile")
for p in "${PATHS[@]}"; do
	git -C "${BASE_DIR}" cat-file -e "${REV}:${p}" 2> /dev/null || fail "${p} is not in HEAD (${REV})"
done
# the repository build's ignore file: Dockerfile.dockerignore if HEAD has one, else .dockerignore
IGNORE=""
for p in Dockerfile.dockerignore .dockerignore; do
	if git -C "${BASE_DIR}" cat-file -e "${REV}:${p}" 2> /dev/null; then
		IGNORE=${p}
		PATHS+=("${p}")
		break
	fi
done

mkdir -p "${APP_ROOT}"
exec 9> "${APP_ROOT}/.render.lock"
flock -w 600 9 || fail "another render holds ${APP_ROOT}/.render.lock"
WORK=$(mktemp -d "${APP_ROOT}/.render.XXXXXX")
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/src" "${WORK}/kit"

# The sources HEAD's kit dockerfile copies, and the tracked files they stage
{ git -C "${BASE_DIR}" show "${REV}:Dockerfile"; git -C "${BASE_DIR}" show "${REV}:${TEMPLATE}/sandbox.dockerfile"; } > "${WORK}/kit.dockerfile"
awk "${SOURCES_AWK}" "${WORK}/kit.dockerfile" > "${WORK}/sources.out"
ERR=$(awk -F'\t' '$1 == "ERR" { print $2; exit }' "${WORK}/sources.out")
[ -z "${ERR}" ] || fail "${KIT_NAME}.dockerfile (Dockerfile + sandbox.dockerfile), ${ERR}"
awk -F'\t' '$1 == "SRC" { print $2 }' "${WORK}/sources.out" | LC_ALL=C sort -u > "${WORK}/sources.txt"
if [ -n "${IGNORE}" ]; then
	git -C "${BASE_DIR}" show "${REV}:${IGNORE}" > "${WORK}/ignore.txt"
else
	: > "${WORK}/ignore.txt"
fi
git -C "${BASE_DIR}" -c core.quotePath=false ls-tree -r --full-tree "${REV}" > "${WORK}/tree.txt"
awk "${MATCH_AWK}" "${WORK}/ignore.txt" "${WORK}/sources.txt" "${WORK}/tree.txt" > "${WORK}/match.out"
MISS=$(awk -F'\t' '$1 == "MISS" { printf "%s%s", s, $2; s = ", " }' "${WORK}/match.out")
[ -z "${MISS}" ] || fail "the Dockerfile's COPY/ADD source ${MISS} is not in HEAD (${REV:0:12}); commit it, or change the COPY/ADD line"
EXCLUDED=$(awk -F'\t' '$1 == "IGN" { printf "%s%s", s, $2; s = ", " }' "${WORK}/match.out")
[ -z "${EXCLUDED}" ] || fail "the Dockerfile's COPY/ADD source ${EXCLUDED} is excluded by ${IGNORE}, so no build can copy it"
awk -F'\t' '$1 == "FILE" { print $2 }' "${WORK}/match.out" | LC_ALL=C sort > "${WORK}/expected.txt"
cut -d' ' -f3- "${WORK}/expected.txt" > "${WORK}/staged.txt"
if grep -Fxq -e "${KIT_NAME}.yaml" -e "${KIT_NAME}.dockerfile" -e "${KIT_NAME}-context.md" "${WORK}/staged.txt"; then
	fail "a COPY/ADD source would replace one of the kit's own files (${KIT_NAME}.yaml, .dockerfile, -context.md)"
fi
# what git archive extracts: the top-level path of each source (all of HEAD for . or a wildcard there)
SPECS=()
while IFS= read -r s; do
	top=${s%%/*}
	case "${top}" in "" | *[*?[\\]*) top=. ;; esac
	SPECS+=("${top}")
done < "${WORK}/sources.txt"

if ! git -C "${BASE_DIR}" diff --quiet HEAD -- "${PATHS[@]}" ${SPECS[@]+"${SPECS[@]}"} \
	|| [ -n "$(git -C "${BASE_DIR}" ls-files --others -- "${PATHS[@]}" ${SPECS[@]+"${SPECS[@]}"})" ]; then
	echo "render.sh: uncommitted or untracked changes under ${PATHS[*]} ${SPECS[*]+${SPECS[*]}} are NOT rendered (HEAD ${REV:0:12} only)" >&2
fi

git -C "${BASE_DIR}" --literal-pathspecs archive --format=tar "${REV}" -- "${PATHS[@]}" ${SPECS[@]+"${SPECS[@]}"} | tar -xf - -C "${WORK}/src"
cp "${WORK}/src/${TEMPLATE}/${KIT_NAME}.yaml" "${WORK}/src/${TEMPLATE}/${KIT_NAME}-context.md" "${WORK}/kit/"
cat "${WORK}/src/Dockerfile" "${WORK}/src/${TEMPLATE}/sandbox.dockerfile" > "${WORK}/kit/${KIT_NAME}.dockerfile"
if [ -s "${WORK}/staged.txt" ]; then
	sed 's#^#./#' "${WORK}/staged.txt" > "${WORK}/staged.list"
	( cd "${WORK}/src" && tar -cf - -T "${WORK}/staged.list" ) | tar -xf - -C "${WORK}/kit"
fi

# Verify: the kit holds exactly the files the sources stage, with HEAD's
# content and modes, besides its own three; the descriptor and context are
# HEAD's; the dockerfile is HEAD's Dockerfile followed by HEAD's sandbox layer.
( cd "${WORK}/kit" && find . \( -type f -o -type l \) ! -path "./${KIT_NAME}.yaml" ! -path "./${KIT_NAME}.dockerfile" ! -path "./${KIT_NAME}-context.md" \
	| sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do
	[ -L "${f}" ] && { echo "symlink ${f}"; continue; }
	mode=100644
	[ -x "${f}" ] && mode=100755
	echo "${mode} $(git hash-object --no-filters -- "${f}") ${f}"
done ) | LC_ALL=C sort > "${WORK}/actual.txt"
diff "${WORK}/expected.txt" "${WORK}/actual.txt" > "${WORK}/tree.diff" || fail "the rendered sources are not HEAD's: $(head -5 "${WORK}/tree.diff" | tr '\n' ' ')"
for f in "${KIT_NAME}.yaml" "${KIT_NAME}-context.md"; do
	[ "$(git hash-object --no-filters -- "${WORK}/kit/${f}")" = "$(git -C "${BASE_DIR}" rev-parse "${REV}:${TEMPLATE}/${f}")" ] || fail "${f} is not HEAD's"
done
{ git -C "${BASE_DIR}" show "${REV}:Dockerfile"; git -C "${BASE_DIR}" show "${REV}:${TEMPLATE}/sandbox.dockerfile"; } \
	| cmp -s - "${WORK}/kit/${KIT_NAME}.dockerfile" || fail "${KIT_NAME}.dockerfile is not HEAD's Dockerfile + sandbox.dockerfile"
echo "${REV}" > "${WORK}/kit.rev"

# Replace the previous render: two renames on one filesystem, under the lock.
[ -e "${APP_DIR}" ] && mv "${APP_DIR}" "${WORK}/previous"
mv "${WORK}/kit" "${APP_DIR}"
mv "${WORK}/kit.rev" "${APP_ROOT}/${KIT_NAME}.rev"

echo "Rendered ${APP_DIR} from ${REV} ($(wc -l < "${WORK}/expected.txt" | tr -d ' ') files of the COPY/ADD sources $(sed 's#^$#.#' "${WORK}/sources.txt" | paste -sd ' ' -), verified against git ls-tree)"
( cd "${APP_DIR}" && sha256sum "${KIT_NAME}.yaml" "${KIT_NAME}.dockerfile" "${KIT_NAME}-context.md" )
