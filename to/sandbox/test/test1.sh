#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Sandbox test1 - static checks of the Docker Sandboxes delivery. Host-side;
# needs bash, perl, python3 with PyYAML; uses sbx when installed (check 9).
# No Docker, no sign-in, no KVM.
# Each check FAILS if the property it proves is removed:
#    1. every script parses (bash -n, perl -c, python3 ast)
#    2. render.sh writes a self-contained kit from HEAD: the dockerfile is HEAD's
#       Dockerfile followed by its template/sandbox.dockerfile byte for byte,
#       Container-Root is HEAD's exactly, descriptor and context are HEAD's,
#       and every source a COPY or ADD line of that dockerfile names (read
#       here independently of render.sh) is in the kit, as HEAD has it;
#       PLANTED CONTROLS, in a throwaway clone: an untracked file, an untracked
#       directory and an uncommitted edit under Container-Root are not rendered,
#       and two renders at once leave exactly HEAD's tree (no nesting); then,
#       committed there: a COPY of a file HEAD lacks stops the render with
#       that file's name and leaves the previous render in place; a JSON-form
#       COPY of a new directory, an ADD with a flag and a wildcard, a quoted
#       source and one across a blank continuation line are staged, without
#       the file .dockerignore excludes, after a RUN with << inside quotes and
#       a heredoc whose body names a missing file; a COPY --from= needs no
#       source; a COPY of only that excluded file, and an unterminated
#       heredoc, stop the render
#    3. the descriptor and sbxenv.yaml meet the delivery's invariants
#       (test/check-descriptor.py: sbx@1, explicit cpu/memory, runtime-only
#       allowlist without wildcards, proxy-managed credential injected only into
#       allowed hosts, each inject naming a header and a %s format, no
#       port/volume/host mount and no privileged@1; sbxenv without workspace,
#       ports or literal secrets, same sizing as the kit)
#    4. PLANTED CONTROLS: check-descriptor.py rejects a copy without sbx@1, with
#       port@1, with an inject domain outside the allowlist, with a wildcard
#       allow, with privileged@1, with the credential shape of sbx's built-in
#       claude-bedrock agent (AWS_PROFILE, not proxy managed, empty headers, the
#       Bedrock control plane), with an inject header of blanks, and an sbxenv
#       with a workspace (proves check 3 is not vacuous)
#    5. the sandbox layer declares USER root, the start-docker label, BASH_ENV,
#       IS_SANDBOX=1, an ENTRYPOINT, and exposes no port; it selects Bedrock
#       (CLAUDE_CODE_USE_BEDROCK=1, AWS_REGION and the two model pins in the
#       environment, copied into settings.json by the same names), no ENV of
#       the repository Dockerfile or the layer names an AWS credential
#       variable, and AWS_REGION is the region of the one Bedrock runtime host
#       that the allowlist admits, the credential injects into and sbxenv.yaml
#       binds; PLANTED CONTROLS: another AWS_REGION, and an AWS credential
#       variable set by ENV, are rejected
#    6. no credential-shaped string anywhere under to/sandbox (short-term
#       Bedrock API keys included)
#    7. compose-demo publishes no port and has no healthcheck, and the expected
#       check count agrees across check.pl, run-deterministic.sh and the verifier
#    8. e2e.sh calls sbx only through its logged, timed-out wrapper, never signs
#       in, stores a secret or publishes a port, runs the agent headless, and
#       does create with --ttl/--on-timeout delete (local: --skills off), sets
#       the cloud sandbox policy to deny-all, stops before anything live unless
#       the policy layer passed, refuses a public kit image and symlinked
#       copy-outs, probes the Bedrock runtime endpoint for an answer from AWS,
#       requires the Anthropic API listed as blocked, fails the platform layer
#       when AWS_BEARER_TOKEN_BEDROCK in the sandbox is a Bedrock API key (either
#       prefix: bedrock-api-key- short-term, ABSK long-term) or,
#       with the model credential configured, not the sentinel, removes a
#       sandbox-scoped bedrock secret, runs nothing live after the platform
#       layer fails on the model key, and removes with --force; PLANTED
#       CONTROLS: twenty-six copies, each with one violation (among them sbx
#       called directly after if, !, timeout, then and while), are rejected
#    9. when sbx is installed, its own parser accepts sbxenv.yaml (sbx env
#       plan, local, which changes nothing and needs no sign-in)
#   10. test/kit-key.py, with which e2e.sh tells whether sbx has built a kit
#       directory, gives the reference sbx 0.47.0 printed when it built a
#       fixture with a subdirectory, an executable file and names whose path
#       order differs from their walk order (computed before that build);
#       PLANTED CONTROLS: a changed byte and a renamed file give another
#       reference, and a symlink, a dotfile, an empty directory and a wrong
#       kit name are refused (exit 2), each with its reason
#   11. README.md opens with a "First local PASS" quickstart whose steps come in
#       the order they depend on each other: the helper is installed before the
#       first `sbx secret set ... --command` names it (in the whole file), and
#       inside the quickstart the pre-build under balanced comes before deny-all,
#       which comes before the first e2e.sh run, which uses --require-agent and a
#       new sandbox name; PLANTED CONTROL: the README without the quickstart (the
#       secret set before the helper's install) is rejected
#   12. README.md's status names its last local PASS: the sbx version that e2e.sh's
#       local kit check is fitted to, a host type and a date; PLANTED CONTROLS: a
#       status without its date, one without its host type and one naming another
#       sbx version are rejected
#   13. a new name for each local sandbox (sbx 0.47.0 gives a sandbox re-created
#       under a name it served before no model key): in README.md's code blocks a
#       local sbx command addresses a sandbox only by a variable ("$N") or a
#       placeholder (the pre-build's throwaway sandbox excepted), and the sbx env
#       commands there and in sbxenv.yaml pass --name; PLANTED CONTROLS: a create
#       under a fixed name and an sbxenv.yaml sbx env run without --name are
#       rejected
#   14. e2e.sh's --dry-run help and README.md's dry-run paragraph say that a dry
#       run, when the agent layer would run, sends billed Converse requests (the
#       host model check), and README.md says that the sandbox's secret must run
#       the helper and profile that check runs; PLANTED CONTROL: the docs without
#       those sentences are rejected
#   15. the kit boots the whole platform by itself: a lifecycle startup hook
#       runs /startup.sh at boot (background, gated by SBX_PLATFORM_AUTOSTART),
#       the sandbox layer carries the platform on-switches in place of .env
#       (UI_START=true, conversations and issues a documented OFF) and derives
#       the env file the hook sources, and e2e.sh suppresses the autostart at
#       create and has a stack layer that checks /agent/ui-status.sh; PLANTED
#       CONTROLS: the descriptor without the hook, the layer without each
#       on-switch, and e2e.sh without the suppression or the stack layer rejected


BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SBX_DIR=${BASE_DIR}/to/sandbox
KIT=do-agent-aws-sandbox
D=$(mktemp -d)

cleanup()
{
	rm -rf "${D}"
}

fail()
{
	echo "Sandbox test1 FAILED: $1"
	cleanup
	exit 1
}

command -v python3 > /dev/null || fail "python3 is required"
python3 -c 'import yaml' 2> /dev/null || fail "PyYAML is required (pip install pyyaml)"

# 1. syntax
for f in "${SBX_DIR}/render.sh" "${SBX_DIR}/build-env.sh" "${SBX_DIR}/push-kit.sh" "${SBX_DIR}/bedrock-token.sh" "${SBX_DIR}"/test/*.sh "${SBX_DIR}/example/compose-demo/run-deterministic.sh"; do
	bash -n "${f}" || fail "${f} does not parse"
done
for f in "${SBX_DIR}"/example/compose-demo/app/*.pl; do
	perl -c "${f}" > /dev/null 2>&1 || fail "${f} does not compile"
done
for f in "${SBX_DIR}/test/check-descriptor.py" "${SBX_DIR}/test/kit-key.py" "${SBX_DIR}/example/compose-demo/verify-agent-report.py"; do
	python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "${f}" || fail "${f} does not parse"
done
echo "ok 1 - scripts parse (bash, perl, python)"

# 2. render, from HEAD
"${SBX_DIR}/render.sh" > "${D}/render.out" 2>&1 || fail "render.sh failed: $(cat "${D}/render.out")"
APP=${SBX_DIR}/app/${KIT}
mkdir -p "${D}/head"
git -C "${BASE_DIR}" archive --format=tar HEAD -- Dockerfile Container-Root to/sandbox/template | tar -xf - -C "${D}/head" \
	|| fail "git archive HEAD failed"
cat "${D}/head/Dockerfile" "${D}/head/to/sandbox/template/sandbox.dockerfile" | cmp -s - "${APP}/${KIT}.dockerfile" \
	|| fail "the rendered dockerfile is not HEAD's Dockerfile + template/sandbox.dockerfile"
diff -r "${D}/head/Container-Root" "${APP}/Container-Root" > /dev/null || fail "the rendered Container-Root differs from HEAD's"
cmp -s "${D}/head/to/sandbox/template/${KIT}.yaml" "${APP}/${KIT}.yaml" || fail "the rendered descriptor is not HEAD's"
cmp -s "${D}/head/to/sandbox/template/${KIT}-context.md" "${APP}/${KIT}-context.md" || fail "the rendered context is not HEAD's"
# every source a COPY or ADD line of the rendered dockerfile names is in the kit,
# as HEAD has it. Read here line by line, independently of render.sh's parser
# (one-line instructions, flags dropped, --from= skipped): the kit build
# context is the kit directory, so a source left out fails the build
SRCS=()
while IFS= read -r line; do
	case "${line}" in *--from=*) continue ;; esac
	read -r -a w <<< "$(printf '%s\n' "${line}" | sed -E 's/^[[:space:]]*[A-Za-z]+[[:space:]]+//; s/--[^[:space:]]+//g; s/[]["]//g; s/,/ /g')"
	[ "${#w[@]}" -ge 2 ] || fail "the rendered dockerfile has a COPY/ADD line without a source and a destination: ${line}"
	for s in "${w[@]:0:${#w[@]}-1}"; do
		SRCS+=("${s#./}")
	done
done < <(grep -iE '^[[:space:]]*(COPY|ADD)[[:space:]]' "${APP}/${KIT}.dockerfile")
[ "${#SRCS[@]}" -gt 0 ] || fail "no COPY/ADD source found in the rendered dockerfile (the repository Dockerfile has several)"
mkdir -p "${D}/head-src"
for s in "${SRCS[@]}"; do
	case "${s}" in
	*[*?[]*)
		compgen -G "${APP}/${s}" > /dev/null || fail "the COPY/ADD source ${s} matches nothing in the rendered kit"
		continue ;;
	esac
	[ -e "${APP}/${s}" ] || fail "the COPY/ADD source ${s} is not in the rendered kit, so the kit build cannot copy it"
	git -C "${BASE_DIR}" archive --format=tar HEAD -- "${s}" | tar -xf - -C "${D}/head-src" || fail "git archive HEAD -- ${s} failed"
	diff -r "${D}/head-src/${s}" "${APP}/${s}" > /dev/null || fail "the rendered ${s} differs from HEAD's"
done
# planted controls in a throwaway clone of this repository (its render.sh is HEAD's)
git clone -q --no-hardlinks "${BASE_DIR}" "${D}/clone" 2> "${D}/clone.err" || fail "git clone for the render controls failed: $(cat "${D}/clone.err")"
echo "planted" > "${D}/clone/Container-Root/planted-untracked.txt"
mkdir -p "${D}/clone/Container-Root/planted-dir"
echo "planted" > "${D}/clone/Container-Root/planted-dir/file.txt"
echo "# planted uncommitted edit" >> "${D}/clone/Container-Root/test1.sh"
"${D}/clone/to/sandbox/render.sh" > "${D}/render1.out" 2>&1 &
R1=$!
"${D}/clone/to/sandbox/render.sh" > "${D}/render2.out" 2>&1 &
R2=$!
wait ${R1} || fail "planted control render: concurrent render 1 failed: $(tail -2 "${D}/render1.out")"
wait ${R2} || fail "planted control render: concurrent render 2 failed: $(tail -2 "${D}/render2.out")"
CAPP=${D}/clone/to/sandbox/app/${KIT}
[ ! -e "${CAPP}/Container-Root/planted-untracked.txt" ] && [ ! -e "${CAPP}/Container-Root/planted-dir" ] \
	|| fail "planted control render: an untracked file was rendered"
git -C "${D}/clone" show HEAD:Container-Root/test1.sh | cmp -s - "${CAPP}/Container-Root/test1.sh" \
	|| fail "planted control render: an uncommitted edit was rendered"
[ ! -e "${CAPP}/Container-Root/Container-Root" ] || fail "planted control render: concurrent renders nested Container-Root"
[ "$(find "${CAPP}/Container-Root" -type f | wc -l)" = "$(git -C "${D}/clone" ls-tree -r --name-only HEAD -- Container-Root | wc -l)" ] \
	|| fail "planted control render: the rendered Container-Root does not hold exactly HEAD's files"
grep -q "NOT rendered" "${D}/render1.out" "${D}/render2.out" || fail "planted control render: render.sh did not warn about uncommitted changes"
# committed planted controls: render.sh reads HEAD, so each one is a commit in
# the clone (of what is staged there; the plants above stay uncommitted)
plant_commit()
{
	# $1 = commit message
	git -C "${D}/clone" -c user.name=test1 -c user.email=test1@example.invalid commit -q -m "$1" > /dev/null 2>&1
}
cp "${D}/clone/Dockerfile" "${D}/Dockerfile.orig"
echo "COPY docs/does-not-exist.md /planted/" >> "${D}/clone/Dockerfile"
git -C "${D}/clone" add Dockerfile && plant_commit "planted: a COPY source HEAD lacks" || fail "planted control missing source: could not commit"
"${D}/clone/to/sandbox/render.sh" > "${D}/render-missing.out" 2>&1 && fail "planted control missing source: render.sh accepted a COPY of a file HEAD does not hold"
grep -qF "COPY/ADD source docs/does-not-exist.md is not in HEAD" "${D}/render-missing.out" \
	|| fail "planted control missing source: wrong reason: $(cat "${D}/render-missing.out")"
[ -f "${CAPP}/Container-Root/test1.sh" ] || fail "planted control missing source: the failed render removed the previous one"
mkdir -p "${D}/clone/planted-src"
echo kept > "${D}/clone/planted-src/kept.txt"
echo ignored > "${D}/clone/planted-src/ignored.txt"
echo "planted-src/ignored.txt" >> "${D}/clone/.dockerignore"
# first: << inside quotes is text, not a heredoc that hides what follows (no
# NOPE line ends it); a real heredoc's body is not read as instructions; then
# a quoted shell-form source, and a blank line inside a continuation
{
	cat "${D}/Dockerfile.orig"
	cat << 'EOF'
RUN echo "a<<NOPE" 'b <<NOPE'
RUN <<BODY
COPY docs/does-not-exist.md /a-line-of-a-heredoc-body/
BODY
COPY ["planted-src", "/planted/"]
ADD --chown=0:0 planted-*/kept.txt /planted2/
COPY --from=busybox:1.36 /bin/true /planted3/true
COPY "README.md" /planted4/
COPY --chown=0:0 \

	planted-src/kept.txt /planted5/
EOF
} > "${D}/clone/Dockerfile"
git -C "${D}/clone" add Dockerfile .dockerignore planted-src && plant_commit "planted: new COPY/ADD sources" || fail "planted control new sources: could not commit"
"${D}/clone/to/sandbox/render.sh" > "${D}/render-sources.out" 2>&1 || fail "planted control new sources: render.sh failed: $(cat "${D}/render-sources.out")"
cmp -s "${D}/clone/planted-src/kept.txt" "${CAPP}/planted-src/kept.txt" || fail "planted control new sources: planted-src/kept.txt was not staged"
[ ! -e "${CAPP}/planted-src/ignored.txt" ] || fail "planted control new sources: a file .dockerignore excludes was staged"
[ ! -e "${CAPP}/bin" ] || fail "planted control new sources: the source of a COPY --from= was looked for in the context"
{ cat "${D}/Dockerfile.orig"; echo 'COPY planted-src/ignored.txt /planted/'; } > "${D}/clone/Dockerfile"
git -C "${D}/clone" add Dockerfile && plant_commit "planted: an excluded COPY source" || fail "planted control excluded source: could not commit"
"${D}/clone/to/sandbox/render.sh" > "${D}/render-excluded.out" 2>&1 && fail "planted control excluded source: render.sh accepted a source .dockerignore excludes"
grep -qF "COPY/ADD source planted-src/ignored.txt is excluded by .dockerignore" "${D}/render-excluded.out" \
	|| fail "planted control excluded source: wrong reason: $(cat "${D}/render-excluded.out")"
{ cat "${D}/Dockerfile.orig"; printf 'RUN <<NOPE\necho a heredoc body that never ends\n'; } > "${D}/clone/Dockerfile"
git -C "${D}/clone" add Dockerfile && plant_commit "planted: an unterminated heredoc" || fail "planted control unterminated heredoc: could not commit"
"${D}/clone/to/sandbox/render.sh" > "${D}/render-heredoc.out" 2>&1 && fail "planted control unterminated heredoc: render.sh accepted it"
grep -qF "the heredoc NOPE is not terminated" "${D}/render-heredoc.out" \
	|| fail "planted control unterminated heredoc: wrong reason: $(cat "${D}/render-heredoc.out")"
echo "ok 2 - render.sh writes a self-contained kit from HEAD with every COPY/ADD source of its dockerfile (${SRCS[*]}); untracked and uncommitted files are not rendered and concurrent renders leave exactly HEAD's tree; planted: a source HEAD lacks stops the render by name, new JSON-form, quoted and flagged wildcard sources are staged without the file .dockerignore excludes, after a quoted << and a heredoc body naming a missing file, and across a blank continuation line; COPY --from= needs no source; a source .dockerignore excludes and an unterminated heredoc stop the render"

# 3. invariants
OUT=$(python3 "${SBX_DIR}/test/check-descriptor.py" "${SBX_DIR}/template/${KIT}.yaml" "${SBX_DIR}/sbxenv.yaml" 2>&1) \
	|| fail "descriptor/sbxenv invariants: ${OUT}"
echo "ok 3 - the descriptor and sbxenv.yaml meet the delivery invariants"

# 4. planted controls
mutate()
{
	# $1 = output file, $2 = python expression applied to the descriptor dict d
	python3 - "${SBX_DIR}/template/${KIT}.yaml" "$1" "$2" << 'EOF'
import sys, yaml
src, dst, expr = sys.argv[1:4]
d = yaml.safe_load(open(src))
exec(expr)
with open(dst, "w") as f:
    f.write("# syntax=docker/sandbox-kit:3\n")
    yaml.safe_dump(d, f, sort_keys=False)
EOF
}
mutate "${D}/no-sbx.yaml" 'd["capabilities"] = [c for c in d["capabilities"] if c["type"] != "com.docker.sandbox/sbx@1"]'
mutate "${D}/port.yaml" 'd["capabilities"].append({"type": "com.docker.sandbox/port@1", "config": {"name": "home", "container": 8000}})'
mutate "${D}/inject.yaml" '[c for c in d["capabilities"] if c["type"] == "com.docker.sandbox/credential@1"][0]["config"]["apiKey"]["inject"][0]["domain"] = "api.example.com"'
mutate "${D}/wildcard.yaml" '[c for c in d["capabilities"] if c["type"] == "com.docker.sandbox/network-policy@1"][0]["config"]["runtime"]["allow"].append("**")'
mutate "${D}/privileged.yaml" 'd["capabilities"].append({"type": "com.docker.sandbox/privileged@1", "optional": True, "description": "planted"})'
# the credential as the spec of sbx 0.47.0's built-in claude-bedrock agent
# declares it: the daemon resolves the stored AWS profile name into STS
# credentials for that agent; for this kit it armed no STS refresher
# (to/sandbox/README.md "Model credential")
mutate "${D}/builtin-shape.yaml" '[c for c in d["capabilities"] if c["type"] == "com.docker.sandbox/credential@1"][0]["config"]["apiKey"] = {"name": "AWS_PROFILE", "inject": [{"domain": "bedrock-runtime.us-east-1.amazonaws.com", "header": "", "format": "%s"}, {"domain": "bedrock.us-east-1.amazonaws.com", "header": "", "format": "%s"}]}'
# a header of blanks injects nothing either
mutate "${D}/blank-header.yaml" '[c for c in d["capabilities"] if c["type"] == "com.docker.sandbox/credential@1"][0]["config"]["apiKey"]["inject"][0]["header"] = "   "'
for m in no-sbx port inject wildcard privileged builtin-shape blank-header; do
	python3 "${SBX_DIR}/test/check-descriptor.py" "${D}/${m}.yaml" > "${D}/${m}.out" 2>&1 \
		&& fail "planted control '${m}': check-descriptor.py accepted it"
done
grep -q "sbx@1" "${D}/no-sbx.out" || fail "planted control no-sbx: wrong reason: $(cat "${D}/no-sbx.out")"
grep -q "publishes a port" "${D}/port.out" || fail "planted control port: wrong reason: $(cat "${D}/port.out")"
grep -q "api.example.com" "${D}/inject.out" || fail "planted control inject: wrong reason: $(cat "${D}/inject.out")"
grep -q "wildcard" "${D}/wildcard.out" || fail "planted control wildcard: wrong reason: $(cat "${D}/wildcard.out")"
grep -q "privileged@1 requests privilege" "${D}/privileged.out" || fail "planted control privileged: wrong reason: $(cat "${D}/privileged.out")"
for r in "credential bedrock: apiKey must be proxyManaged" "inject domain bedrock.us-east-1.amazonaws.com is not in the allow list" \
	"inject for bedrock-runtime.us-east-1.amazonaws.com names no header"; do
	grep -qF -- "${r}" "${D}/builtin-shape.out" || fail "planted control builtin-shape: '${r}' not reported: $(cat "${D}/builtin-shape.out")"
done
grep -qF "inject for bedrock-runtime.us-east-1.amazonaws.com names no header" "${D}/blank-header.out" || fail "planted control blank-header: wrong reason: $(cat "${D}/blank-header.out")"
python3 - "${SBX_DIR}/sbxenv.yaml" "${D}/sbxenv-ws.yaml" << 'EOF'
import sys, yaml
e = yaml.safe_load(open(sys.argv[1]))
e["workspace"] = "."
yaml.safe_dump(e, open(sys.argv[2], "w"), sort_keys=False)
EOF
python3 "${SBX_DIR}/test/check-descriptor.py" "${SBX_DIR}/template/${KIT}.yaml" "${D}/sbxenv-ws.yaml" > "${D}/ws.out" 2>&1 \
	&& fail "planted control sbxenv workspace: accepted"
grep -q "workspace" "${D}/ws.out" || fail "planted control sbxenv workspace: wrong reason: $(cat "${D}/ws.out")"
echo "ok 4 - planted controls: no sbx@1, port@1, out-of-allowlist inject, wildcard allow, privileged@1, the built-in claude-bedrock credential shape (not proxy managed, empty headers, the control plane off the list), a header of blanks and an sbxenv workspace are all rejected"

# 5. sandbox layer
L=${SBX_DIR}/template/sandbox.dockerfile
grep -q '^USER root$' "${L}" || fail "sandbox.dockerfile does not declare USER root"
grep -q '^LABEL com.docker.sandboxes.start-docker="true"$' "${L}" || fail "sandbox.dockerfile lacks the start-docker label"
grep -q 'BASH_ENV=/etc/sandbox-persistent.sh' "${L}" || fail "sandbox.dockerfile does not set BASH_ENV"
grep -q 'IS_SANDBOX=1' "${L}" || fail "sandbox.dockerfile does not set IS_SANDBOX=1"
grep -q 'TIKTOKEN_CACHE_DIR=/opt/tiktoken-cache' "${L}" && grep -q 'LITELLM_LOCAL_MODEL_COST_MAP=True' "${L}" && grep -q '^ENV HF_HUB_OFFLINE=1' "${L}" \
	|| fail "sandbox.dockerfile does not prepare hindsight-api to start inside the allowlist"
grep -q '^ENTRYPOINT \[' "${L}" || fail "sandbox.dockerfile has no ENTRYPOINT"
grep -qi '^EXPOSE' "${L}" "${BASE_DIR}/Dockerfile" && fail "the sandbox image must not EXPOSE a port"
# the model provider: Bedrock, its region one pin shared by the image, the
# allowlist, the credential and the binding; no AWS credential in the image
cat > "${D}/bedrock-pin.py" << 'EOF'
import re, sys, yaml
dockerfile, layer, desc, env = sys.argv[1:5]
NAMES = ["CLAUDE_CODE_USE_BEDROCK", "AWS_REGION", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"]
CRED = re.compile(r"AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|BEARER_TOKEN_BEDROCK|PROFILE)")
errors, envs = [], {}
# the ENV instructions of the image, the repository Dockerfile first (a later value wins)
for path in (dockerfile, layer):
    for line in re.sub(r"\\\n", " ", open(path).read()).splitlines():
        m = re.match(r"\s*ENV\s+(\S.*)$", line, re.I)
        if not m:
            continue
        words = m.group(1).split()
        pairs = [w.split("=", 1) for w in words] if "=" in words[0] else [[words[0], " ".join(words[1:])]]
        for k, v in pairs:
            envs[k] = v
            if CRED.fullmatch(k):
                errors.append("%s sets %s by ENV; no AWS credential belongs in the image" % (path.rsplit("/", 1)[-1], k))
if envs.get("CLAUDE_CODE_USE_BEDROCK") != "1":
    errors.append("the image environment does not select Bedrock (CLAUDE_CODE_USE_BEDROCK=1)")
for k in NAMES[1:]:
    if not envs.get(k):
        errors.append("the image environment does not set %s" % k)
if open(layer).read().count('["%s"]' % '","'.join(NAMES)) < 2:
    errors.append("the layer does not copy %s into settings.json and check them there" % ", ".join(NAMES))
want = "bedrock-runtime.%s.amazonaws.com" % envs.get("AWS_REGION")
caps = (yaml.safe_load(open(desc)) or {}).get("capabilities") or []
hosts = [a.rsplit(":", 1)[0] for c in caps if c.get("type") == "com.docker.sandbox/network-policy@1"
         for a in (((c.get("config") or {}).get("runtime") or {}).get("allow") or [])]
runtime = [h for h in hosts if re.fullmatch(r"bedrock-runtime\.[a-z0-9-]+\.amazonaws\.com", h)]
if runtime != [want]:
    errors.append("the allowlist's Bedrock runtime hosts are %s, expected exactly [%s] (the image's AWS_REGION)" % (runtime, want))
if any(h == "claude.ai" or h == "anthropic.com" or h.endswith(".anthropic.com") for h in hosts):
    errors.append("the allowlist admits an Anthropic host: %s" % hosts)
inject = [i.get("domain") for c in caps if c.get("type") == "com.docker.sandbox/credential@1"
          for i in ((((c.get("config") or {}).get("apiKey") or {}).get("inject")) or [])]
if inject != [want]:
    errors.append("the credential injects into %s, expected [%s]" % (inject, want))
b = ((((yaml.safe_load(open(env)) or {}).get("bindings") or {}).get("bedrock") or {}).get("apiKey") or {}).get("domains") or []
if b != [want]:
    errors.append("sbxenv.yaml binds bedrock to %s, expected [%s]" % (b, want))
print("\n".join(errors))
sys.exit(1 if errors else 0)
EOF
pin()
{
	# $1 = sandbox layer to check
	python3 "${D}/bedrock-pin.py" "${BASE_DIR}/Dockerfile" "$1" "${SBX_DIR}/template/${KIT}.yaml" "${SBX_DIR}/sbxenv.yaml"
}
OUT=$(pin "${L}" 2>&1) || fail "the sandbox layer's model provider: ${OUT}"
sed 's/^    AWS_REGION=us-east-1 \\$/    AWS_REGION=us-west-2 \\/' "${L}" > "${D}/layer-region.dockerfile"
cmp -s "${L}" "${D}/layer-region.dockerfile" && fail "planted control region: could not plant another AWS_REGION"
OUT=$(pin "${D}/layer-region.dockerfile" 2>&1) && fail "planted control region: AWS_REGION=us-west-2 was accepted"
echo "${OUT}" | grep -qF "expected exactly [bedrock-runtime.us-west-2.amazonaws.com]" || fail "planted control region: wrong reason: ${OUT}"
{ cat "${L}"; echo "ENV AWS_BEARER_TOKEN_BEDROCK=planted"; } > "${D}/layer-cred.dockerfile"
OUT=$(pin "${D}/layer-cred.dockerfile" 2>&1) && fail "planted control credential: an AWS_BEARER_TOKEN_BEDROCK ENV was accepted"
echo "${OUT}" | grep -qF "sets AWS_BEARER_TOKEN_BEDROCK by ENV" || fail "planted control credential: wrong reason: ${OUT}"
echo "ok 5 - the sandbox layer declares the identity, engine label, launch environment and entrypoint, and exposes nothing; it selects Bedrock in the environment and settings.json, with no AWS credential, in the region of the one runtime host the allowlist, credential and binding name (planted: another region, a credential ENV)"

# 6. no credential-shaped strings, by the patterns e2e.sh also applies to
# everything it uploads (test/credential-shapes.txt; written so the file does
# not match itself); a failing scan (grep exit 2) fails too; PLANTED CONTROLS:
# one example of every shape, built here at runtime (never a literal), is caught
SHAPES_FILE=${SBX_DIR}/test/credential-shapes.txt
[ -s "${SHAPES_FILE}" ] || fail "missing ${SHAPES_FILE}"
grep -rEn --exclude-dir=app -f "${SHAPES_FILE}" "${SBX_DIR}" > "${D}/secrets.out" 2> "${D}/secrets.err"
case $? in
0) fail "credential-shaped content under to/sandbox: $(cat "${D}/secrets.out")" ;;
1) ;;
*) fail "the credential scan failed: $(cat "${D}/secrets.err")" ;;
esac
python3 - "${D}/plants" << 'EOF' || fail "could not build the planted credentials"
import os, random, string, sys
r = random.Random(7)
def s(chars, n):
    return "".join(r.choice(chars) for _ in range(n))
A = string.ascii_letters + string.digits
U = string.ascii_uppercase + string.digits
D = string.digits
B64 = A + "+/"
plants = {
    "anthropic": "sk-" + "ant-api03-" + s(A, 40),
    "openai-project": "sk-" + "proj-" + s(A, 48),
    "aws-access-key": "AK" + "IA" + s(U, 16),
    "aws-temporary-key": "AS" + "IA" + s(U, 16),
    "aws-secret": "aws_secret" + "_access_key = " + s(B64, 40),
    "aws-secret-upper": "AWS_SECRET" + "_ACCESS_KEY=" + s(B64, 40),
    "aws-secret-json": '"Secret' + 'AccessKey": "' + s(B64, 40) + '"',
    "aws-session-token": "AWS_SESSION" + "_TOKEN=" + s(B64, 160),
    "aws-session-json": '"Session' + 'Token": "' + s(B64, 160) + '"',
    "bedrock-api-key": "AB" + "SK" + s(B64, 60),
    # the short-term key to/sandbox/bedrock-token.sh prints (aws-bedrock-token-generator)
    "bedrock-short-term-key": "bedrock" + "-api-key-" + s(B64, 120) + "==",
    "docker-pat": "dckr" + "_pat_" + s(A, 27),
    "huggingface": "hf" + "_" + s(A, 34),
    "slack-bot": "xo" + "xb-" + s(D, 12) + "-" + s(D, 13) + "-" + s(A, 24),
    "slack-app": "xa" + "pp-1-" + s(U, 11) + "-" + s(D, 13) + "-" + s("0123456789abcdef", 64),
    "github-classic": "gh" + "p_" + s(A, 36),
    "github-fine-grained": "github" + "_pat_" + s(A + "_", 82),
    "private-key": "-----BEGIN RSA " + "PRIVATE KEY-----",
}
os.makedirs(sys.argv[1])
for name, value in plants.items():
    with open(os.path.join(sys.argv[1], name), "w") as f:
        f.write("value " + value + "\n")
EOF
N_PLANTS=0
for f in "${D}"/plants/*; do
	N_PLANTS=$((N_PLANTS + 1))
	grep -qE -f "${SHAPES_FILE}" "${f}" || fail "planted control: the ${f##*/} shape is not caught by ${SHAPES_FILE}"
done
[ "${N_PLANTS}" -ge 18 ] || fail "planted control: only ${N_PLANTS} credential shapes were planted"
echo "ok 6 - no credential-shaped string under to/sandbox; one planted example of each of ${N_PLANTS} shapes is caught"

# 7. compose-demo
EX=${SBX_DIR}/example/compose-demo
python3 - "${EX}/compose.yaml" << 'EOF' || fail "compose-demo publishes a port or declares a healthcheck"
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
bad = [n for n, s in c["services"].items() if s.get("ports") or s.get("healthcheck")]
sys.exit(1 if bad else 0)
EOF
N_PL=$(grep -cE "^	\['" "${EX}/app/check.pl")
N_SH=$(sed -n 's/^EXPECTED_CHECKS=//p' "${EX}/run-deterministic.sh")
N_PY=$(sed -n 's/^EXPECTED_CHECKS = //p' "${EX}/verify-agent-report.py")
[ "${N_PL}" -gt 0 ] && [ "${N_PL}" = "${N_SH}" ] && [ "${N_PL}" = "${N_PY}" ] \
	|| fail "expected check counts disagree: check.pl ${N_PL}, run-deterministic.sh ${N_SH}, verify-agent-report.py ${N_PY}"
# server.pl exits 0 on stop only after serving the requests check.pl makes: every
# request in its %CHECK_REQUESTS must be one check.pl actually sends
N_REQ=0
while read -r req; do
	N_REQ=$((N_REQ + 1))
	grep -qF "get('${req}')" "${EX}/app/check.pl" || fail "server.pl attests '${req}', which check.pl does not request"
done < <(sed -n "s/^my %CHECK_REQUESTS = (\(.*\));/\1/p" "${EX}/app/server.pl" | grep -oE "'[^']+'" | tr -d "'" | grep '^/')
[ "${N_REQ}" -gt 0 ] || fail "no %CHECK_REQUESTS found in server.pl"
echo "ok 7 - compose-demo publishes no port, has no healthcheck, and the expected check count (${N_PL}) agrees"

# 8. e2e.sh guard rails, on code lines (comments and echo/note/layer messages
# may name commands for the operator; they are not calls)
guard_rails()
{
	# $1 = e2e script; prints the first violation and returns 1, or returns 0
	local code=${D}/guard.code
	grep -vE '^\s*#' "$1" | grep -vE '^\s*(echo|note|layer|printf|BLOCKERS\+=|AGENT_REASON=)' > "${code}"
	# every sbx call goes through sbx_run, whose one line hands it to run_bg
	# (logged, timed out, no terminal input, in the background): the word sbx as
	# a command anywhere else in a code line once quoted strings are blanked (if
	# sbx, ! sbx, timeout 60 sbx, then sbx, while sbx, $(sbx ...), run_bg 60 sbx
	# ...), command substitutions inside double quotes ("$(sbx ...)") included
	python3 - "${code}" > "${code}.bare" << 'EOF'
import re, sys
for line in open(sys.argv[1]):
    # $(...) inside a double-quoted string runs too: keep it, after the line
    subs = re.findall(r'"(?:[^"\\]|\\.)*"', re.sub(r"'[^']*'", "''", line))
    subs = [c for q in subs for c in re.findall(r"\$\(([^()]*)\)", q)]
    line = re.sub(r"'[^']*'", "''", line)
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line).rstrip("\n")
    sys.stdout.write(line + "".join(" ; " + c for c in subs) + "\n")
EOF
	if grep -nE '(^|[^A-Za-z0-9_./${-])sbx[[:space:]]' "${code}.bare" | grep -vE '^[0-9]+:[[:space:]]*run_bg "" sbx ""[[:space:]]*$' > "${D}/guard.out"; then
		echo "calls sbx outside sbx_run: $(cat "${D}/guard.out")"
		return 1
	fi
	{
		grep -nE '(sbx_run|sbx_exec).*(\slogin(\s|$)|\slogout|secret (set|set-custom|import)|\sports(\s|$)|--publish)' "${code}"
		grep -nE '(CREATE=|CREATE\+=).*[[:space:](](-p|--publish)([[:space:]=)]|$)' "${code}"
		grep -nE 'sbx_run.*[[:space:]]create([[:space:]]|$).*[[:space:]](-p|--publish)([[:space:]=]|$)' "${code}"
	} > "${D}/guard.out"
	if [ -s "${D}/guard.out" ]; then
		echo "signs in, stores a secret or publishes a port: $(cat "${D}/guard.out")"
		return 1
	fi
	if ! grep -nE 'sbx_exec .*claude' "${code}" | grep -qE 'claude -p '; then
		echo "does not run the agent headless (claude -p)"
		return 1
	fi
	for need in '--ttl' '--on-timeout delete' 'policy init deny-all' 'rm --force' \
		'run_bg "${SBX_T:-${T_QUICK}}" sbx "$@"' 'timeout -k 30 "${t}" "$@" < /dev/null {E2E_STDOUT_FD}>&- {E2E_STDERR_FD}>&- &' \
		'--skills off' 'egress unverified' 'docker manifest inspect' 'has_symlinks' 'secret rm bedrock --sandbox' \
		'MODEL=$(probe_aws https://bedrock-runtime.us-east-1.amazonaws.com/)' 'blocked_in_log "${OUT}/policy-log.txt" api.anthropic.com' \
		'case "$v" in bedrock-api-key-*|ABSK*) k=yes ;; esac' 'elif [ "${MODEL_CRED}" = "present" ] && [ "$(val bearer_sentinel)" != "yes" ]; then' \
		'[ "${MEM_OK}" = "true" ] && [ -z "${BEARER_WHY}" ]; then' 'if [ -n "${BEARER_WHY}" ]; then' \
		'GATE="credential isolation unverified: ${BEARER_WHY}"'; do
		if ! grep -qF -- "${need}" "${code}"; then
			echo "does not use '${need}'"
			return 1
		fi
	done
	return 0
}
MSG=$(guard_rails "${SBX_DIR}/test/e2e.sh") || fail "e2e.sh ${MSG}"
plant()
{
	# $1 = name, $2 = python expression of s, the script text
	python3 - "${SBX_DIR}/test/e2e.sh" "${D}/e2e-$1.sh" "$2" << 'EOF'
import sys
src, dst, expr = sys.argv[1:4]
s = open(src).read()
t = eval(expr)
if t == s:
    sys.exit("mutation changed nothing")
open(dst, "w").write(t)
EOF
}
plant login 's + "\nsbx_run login\n"' || fail "could not plant the login control"
plant direct 's + "\nsbx ls -q\n"' || fail "could not plant the direct-call control"
plant publish 's + "\nCREATE+=(-p 8080)\n"' || fail "could not plant the publish control"
plant secret 's + "\nsbx_run secret set bedrock\n"' || fail "could not plant the secret control"
plant no-delete 's.replace("--on-timeout delete", "--on-timeout stop")' || fail "could not plant the on-timeout control"
plant no-headless 's.replace("claude -p ", "claude ")' || fail "could not plant the headless control"
plant no-gate 's.replace("egress unverified", "egress noted")' || fail "could not plant the policy-gate control"
plant public-kit 's.replace("docker manifest inspect", "docker version")' || fail "could not plant the public-kit control"
plant if-sbx 's + "\nif sbx ls -q; then :; fi\n"' || fail "could not plant the if-sbx control"
plant not-sbx 's + "\n! sbx ls -q\n"' || fail "could not plant the not-sbx control"
plant timeout-sbx 's + "\ntimeout 60 sbx ls -q\n"' || fail "could not plant the timeout-sbx control"
plant then-sbx 's + "\nif true; then sbx ls -q; fi\n"' || fail "could not plant the then-sbx control"
plant while-sbx 's + "\nwhile sbx ls -q; do break; done\n"' || fail "could not plant the while-sbx control"
plant bg-sbx 's + "\nrun_bg 60 sbx ls -q\n"' || fail "could not plant the bg-sbx control"
plant no-stdin 's.replace("\"$@\" < /dev/null {E2E_STDOUT_FD}", "\"$@\" {E2E_STDOUT_FD}")' || fail "could not plant the no-stdin control"
plant no-timeout 's.replace("timeout -k 30 \"${t}\" \"$@\"", "\"$@\"")' || fail "could not plant the no-timeout control"
plant fd-leak 's.replace(" {E2E_STDOUT_FD}>&- {E2E_STDERR_FD}>&- &", " &")' || fail "could not plant the fd-leak control"
plant quoted-sbx 's.replace("S_SBX=\"${SBX_VERSION_LINE}\"", "S_SBX=\"$(sbx version 2>/dev/null | head -1)\"")' || fail "could not plant the quoted-sbx control"
plant no-bedrock-probe 's.replace("MODEL=$(probe_aws https://bedrock-runtime.us-east-1.amazonaws.com/)", "MODEL=$(probe_aws https://bedrock.us-east-1.amazonaws.com/)")' || fail "could not plant the bedrock-probe control"
plant anthropic-unchecked 's.replace("blocked_in_log \"${OUT}/policy-log.txt\" api.anthropic.com", "true")' || fail "could not plant the anthropic-unchecked control"
plant no-key-probe 's.replace("case \"$v\" in bedrock-api-key-*|ABSK*) k=yes ;; esac; ", "")' || fail "could not plant the key-probe control"
plant no-longterm-probe 's.replace("bedrock-api-key-*|ABSK*) k=yes", "bedrock-api-key-*) k=yes")' || fail "could not plant the long-term key-probe control"
plant no-sentinel-check 's.replace("elif [ \"${MODEL_CRED}\" = \"present\" ] && [ \"$(val bearer_sentinel)\" != \"yes\" ]; then", "elif false; then")' || fail "could not plant the sentinel-check control"
plant bearer-ungated 's.replace("[ \"${MEM_OK}\" = \"true\" ] && [ -z \"${BEARER_WHY}\" ]; then", "[ \"${MEM_OK}\" = \"true\" ]; then")' || fail "could not plant the bearer-gate control"
plant platform-ungated 's.replace("if [ -n \"${BEARER_WHY}\" ]; then", "if false; then")' || fail "could not plant the platform-gate control"
plant no-platform-gate 's.replace("GATE=\"credential isolation unverified: ${BEARER_WHY}\"", "GATE=\"\"")' || fail "could not plant the platform-gate message control"
for m in login direct publish secret no-delete no-headless no-gate public-kit if-sbx not-sbx timeout-sbx then-sbx while-sbx bg-sbx no-stdin no-timeout fd-leak quoted-sbx no-bedrock-probe anthropic-unchecked \
	no-key-probe no-longterm-probe no-sentinel-check bearer-ungated platform-ungated no-platform-gate; do
	guard_rails "${D}/e2e-${m}.sh" > /dev/null && fail "planted control e2e '${m}': the guard rails accepted it"
done
echo "ok 8 - e2e.sh logs and bounds every sbx call, never signs in, stores secrets or publishes ports; it sets a TTL, a deny-all sandbox policy, gates live layers on the policy, probes the Bedrock runtime endpoint, requires the Anthropic API blocked, fails the platform layer on a Bedrock API key in the sandbox (short-term or long-term) or, with a credential, on anything but the sentinel, and then runs nothing live, refuses public kits and symlinks, and force-removes (26 planted violations caught)"

# 9. optional: sbx's own parser accepts sbxenv.yaml. "sbx env plan" changes
# nothing; a local plan needs no sign-in but does need the local daemon (sbx
# 0.47.0 answers "not signed in" without it). Skipped where sbx is absent or its
# daemon is not running (start it with: sbx daemon start -d).
if ! command -v sbx > /dev/null; then
	echo "ok 9 - (skipped: sbx is not installed)"
elif ! sbx daemon status 2> /dev/null | grep -q 'Status: running'; then
	echo "ok 9 - (skipped: the sbx daemon is not running; sbx daemon start -d enables this check)"
else
	( cd "${BASE_DIR}" && sbx env plan --skip-host-commands to/sandbox < /dev/null ) > "${D}/env-plan.out" 2>&1 \
		|| fail "sbx env plan rejected to/sandbox/sbxenv.yaml: $(tail -5 "${D}/env-plan.out")"
	grep -q "agent: ${KIT}" "${D}/env-plan.out" && grep -q "domains: bedrock-runtime.us-east-1.amazonaws.com" "${D}/env-plan.out" \
		|| fail "sbx env plan does not show the kit agent and the bedrock binding: $(cat "${D}/env-plan.out")"
	echo "ok 9 - sbx $(sbx version 2>/dev/null | awk '{print $3}') env plan accepts sbxenv.yaml (kit ${KIT}, cpus/memory, bedrock binding)"
fi

# 10. kit-key.py on the pf-tree fixture, byte for byte as sbx 0.47.0 built it on
# the KVM test host on 2026-10-08 ("→ build kit .../pf-tree (sbx-kit-src:pf-tree-f2f9a4bd957e)")
mkfixture()
{
	# $1 = directory to create, named pf-tree
	mkdir -p "$1/a"
	cat > "$1/pf-tree.yaml" << 'EOF'
# syntax=docker/sandbox-kit:3
schemaVersion: "3"
kind: workload
displayName: pf-tree
description: Fixture of to/sandbox/test/test1.sh for kit-key.py
capabilities:
  - type: com.docker.sandbox/sbx@1
  - type: com.docker.sandbox/network-policy@1
    config:
      runtime:
        allow:
          - api.anthropic.com:443
EOF
	cat > "$1/pf-tree.dockerfile" << 'EOF'
FROM ubuntu:22.04
RUN touch /etc/sandbox-persistent.sh && mkdir -p /root/workspace /usr/local/share/ca-certificates
ENV BASH_ENV=/etc/sandbox-persistent.sh
USER root
WORKDIR /root/workspace
ENTRYPOINT ["bash"]
CMD ["-l"]
EOF
	printf '#!/bin/sh\necho x\n' > "$1/a/x.sh"
	chmod 755 "$1/a/x.sh"
	printf 'a-b\n' > "$1/a-b.txt"
}
mkdotfixture()
{
	# $1 = directory to create, named pf-dot: names starting with a dot, as the vendored /opt/issues-tracker has
	mkdir -p "$1/a" "$1/.claude/agents"
	cat > "$1/pf-dot.yaml" << 'EOF'
# syntax=docker/sandbox-kit:3
schemaVersion: "3"
kind: workload
displayName: pf-dot
description: kit-key.py dotfile probe
capabilities:
  - type: com.docker.sandbox/sbx@1
  - type: com.docker.sandbox/network-policy@1
    config:
      runtime:
        allow:
          - api.anthropic.com:443
EOF
	sed -n '/^FROM/,$p' "$2" > "$1/pf-dot.dockerfile"
	printf 'x\n' > "$1/a/x.txt"
	printf 'agent\n' > "$1/.claude/agents/w.md"
	printf 'ign\n' > "$1/.gitignore"
}
KK=${SBX_DIR}/test/kit-key.py
SBX_REF=sbx-kit-src:pf-tree-f2f9a4bd957e
mkfixture "${D}/kk/pf-tree"
GOT=$(python3 "${KK}" "${D}/kk/pf-tree" pf-tree 2>&1)
[ "${GOT}" = "${SBX_REF}" ] || fail "kit-key.py gives '${GOT}' for the pf-tree fixture; sbx 0.47.0 built it as ${SBX_REF}"
# pf-dot, as sbx 0.47.0 built it on the KVM test host on 2026-10-15 ("→ build kit ./pf-dot (sbx-kit-src:pf-dot-21b31230a3f2)")
mkdotfixture "${D}/kk/pf-dot" "${D}/kk/pf-tree/pf-tree.dockerfile"
GOT=$(python3 "${KK}" "${D}/kk/pf-dot" pf-dot 2>&1)
[ "${GOT}" = "sbx-kit-src:pf-dot-21b31230a3f2" ] || fail "kit-key.py gives '${GOT}' for the pf-dot fixture; sbx 0.47.0 built it as sbx-kit-src:pf-dot-21b31230a3f2"
for c in byte rename symlink dotfile emptydir name; do
	mkfixture "${D}/kk-${c}/pf-tree"
done
printf 'a-c\n' > "${D}/kk-byte/pf-tree/a-b.txt"
mv "${D}/kk-rename/pf-tree/a-b.txt" "${D}/kk-rename/pf-tree/a_b.txt"
ln -s a-b.txt "${D}/kk-symlink/pf-tree/link"
: > "${D}/kk-dotfile/pf-tree/.dockerignore"
mkdir "${D}/kk-emptydir/pf-tree/empty"
for c in byte rename dotfile; do
	GOT=$(python3 "${KK}" "${D}/kk-${c}/pf-tree" pf-tree 2>&1) || fail "planted control kit-key ${c}: kit-key.py failed: ${GOT}"
	case "${GOT}" in
	"${SBX_REF}") fail "planted control kit-key ${c}: the reference did not change" ;;
	sbx-kit-src:pf-tree-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
	*) fail "planted control kit-key ${c}: not a reference: ${GOT}" ;;
	esac
done
for cm in "symlink:link is not a regular file or directory" "emptydir:empty directory empty" "name:is not named other"; do
	c=${cm%%:*}
	n=pf-tree
	[ "${c}" = "name" ] && n=other
	python3 "${KK}" "${D}/kk-${c}/pf-tree" "${n}" > "${D}/kk-${c}.out" 2>&1
	[ $? -eq 2 ] || fail "planted control kit-key ${c}: not refused (exit 2): $(cat "${D}/kk-${c}.out")"
	grep -qF -- "${cm#*:}" "${D}/kk-${c}.out" || fail "planted control kit-key ${c}: refused, but not because '${cm#*:}': $(cat "${D}/kk-${c}.out")"
done
echo "ok 10 - kit-key.py gives ${SBX_REF} for the fixture sbx 0.47.0 built as that; and sbx-kit-src:pf-dot-21b31230a3f2 for the one with dot names; a changed byte, a renamed file and an added dotfile change it; a symlink, an empty directory and a wrong kit name are refused, each with its reason"

# 11. the README's quickstart puts each step after what it depends on
readme_order()
{
	# $1 = README; prints the problems and returns 1, or returns 0
	python3 - "$1" << 'EOF'
import sys
lines = open(sys.argv[1]).read().split("\n")
def first(s, lo=0, hi=None):
    for i in range(lo, len(lines) if hi is None else hi):
        if s in lines[i]:
            return i
    return None
q = first("## First local PASS")
declares = first("## What the kit declares")
errs = []
if q is None or (declares is not None and q > declares):
    errs.append("no '## First local PASS' section before 'What the kit declares'")
else:
    end = next((i for i in range(q + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    bal = first("sbx policy init balanced", q, end)
    deny = first("sbx policy init deny-all", q, end)
    run = first("to/sandbox/test/e2e.sh --local", q, end)
    if None in (bal, deny) or bal > deny:
        errs.append("the quickstart does not build under balanced before it switches to deny-all")
    if None in (deny, run) or deny > run:
        errs.append("the quickstart runs e2e.sh before the switch to deny-all")
    elif "--require-agent" not in lines[run] or "--name \"$N\"" not in lines[run]:
        errs.append("the quickstart's first e2e.sh run lacks --require-agent or the new name")
helper = first("install -m 0700 to/sandbox/bedrock-token.sh")
secret = first("sbx secret set bedrock --sandbox")
if helper is None or secret is None or helper > secret:
    errs.append("the first 'sbx secret set bedrock --sandbox' (line %s) comes before the helper's install (line %s)" % (None if secret is None else secret + 1, None if helper is None else helper + 1))
print("; ".join(errs))
sys.exit(1 if errs else 0)
EOF
}
MSG=$(readme_order "${SBX_DIR}/README.md") || fail "README.md: ${MSG}"
python3 - "${SBX_DIR}/README.md" "${D}/README-no-quickstart.md" << 'EOF'
import re, sys
s = open(sys.argv[1]).read()
t = re.sub(r"\n## First local PASS\n.*?(?=\n## )", "\n", s, count=1, flags=re.S)
if t == s:
    sys.exit("could not plant the control: no quickstart to remove")
open(sys.argv[2], "w").write(t)
EOF
[ $? -eq 0 ] || fail "could not plant the README control"
readme_order "${D}/README-no-quickstart.md" > "${D}/readme-order.out" && fail "planted control: README.md without the quickstart passed the order check"
grep -qF "comes before the helper's install" "${D}/readme-order.out" || fail "planted control: the README without the quickstart was not refused for the secret before the helper: $(cat "${D}/readme-order.out")"
echo "ok 11 - README.md opens with a First local PASS quickstart in dependency order: the helper's install before the first secret set that names it, the balanced pre-build before deny-all, deny-all before the first e2e.sh run (with --require-agent and a new name); the README without it is refused"

# 12. the README's status line names the last local PASS: sbx version, host, date
status_line()
{
	# $1 = README; prints the problem and returns 1, or returns 0
	local line ver want
	# the bullet, with its continuation lines
	line=$(awk '/^- \*\*Last PASS:\*\*/ {f = 1; printf "%s", $0; next} f && /^  / {printf " %s", $0; next} f {exit}' "$1")
	[ -n "${line}" ] || { echo "the status names no last PASS ('- **Last PASS:** <date>, sbx <version>, <host>')"; return 1; }
	want=$(sed -n 's/.*SBX_VER_TOKEN}" != "v\([0-9.]*\)" ].*/\1/p' "${SBX_DIR}/test/e2e.sh" | head -1)
	ver=$(echo "${line}" | sed -n 's/.*sbx \([0-9][0-9.]*[0-9]\).*/\1/p')
	[ -n "${want}" ] && [ "${ver}" = "${want}" ] || { echo "the status names sbx '${ver}', and e2e.sh's local kit check is fitted to '${want}'"; return 1; }
	echo "${line}" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || { echo "the status names no date"; return 1; }
	echo "${line}" | grep -qE 'KVM' || { echo "the status names no host type (KVM host)"; return 1; }
	return 0
}
MSG=$(status_line "${SBX_DIR}/README.md") || fail "README.md: ${MSG}"
CONTROLS12="no-date no-host other-sbx"
for m in ${CONTROLS12}; do
	case "${m}" in
	no-date) expr='re.sub(r"(- \*\*Last PASS:\*\*) [0-9]{4}-[0-9]{2}-[0-9]{2},", r"\1 the last run,", s, count=1)' ;;
	no-host) expr='re.sub(r"(- \*\*Last PASS:\*\*.*?)with KVM", r"\1with a hypervisor", s, count=1, flags=re.S)' ;;
	other-sbx) expr='re.sub(r"(- \*\*Last PASS:\*\*.*?)sbx 0\.47\.0", r"\1sbx 0.48.0", s, count=1, flags=re.S)' ;;
	esac
	python3 - "${SBX_DIR}/README.md" "${D}/README-${m}.md" "${expr}" << 'EOF'
import re, sys
src, dst, expr = sys.argv[1:4]
s = open(src).read()
t = eval(expr)
if t == s:
    sys.exit("mutation changed nothing")
open(dst, "w").write(t)
EOF
	[ $? -eq 0 ] || fail "could not plant the status control ${m}"
	status_line "${D}/README-${m}.md" > /dev/null && fail "planted control status ${m}: the status check accepted it"
done
echo "ok 12 - README.md's status names its last local PASS: $(sed -n 's/^- \*\*Last PASS:\*\* \([0-9-]*\),.*/\1/p' "${SBX_DIR}/README.md" | head -1), the sbx version e2e.sh's local check is fitted to and a KVM host; a status without its date, without its host type or with another sbx version is refused"

# 13. a new name for each local sandbox, in the README's commands and sbxenv.yaml's
new_names()
{
	# $1 = README, $2 = sbxenv.yaml; prints the problems and returns 1, or returns 0
	python3 - "$1" "$2" << 'EOF'
import re, sys
readme, env = sys.argv[1:3]
errs = []
# in the README's code blocks, a local sbx command addresses a sandbox only by a
# variable or a placeholder; the pre-build's throwaway sandbox holds no secret
ok = {'"$N"', '"${N}"', "$N", "<name>", "do-agent-aws-prebuild"}
inb = False
for i, l in enumerate(open(readme).read().split("\n"), 1):
    if l.strip().startswith("```"):
        inb = not inb
        continue
    if not inb or "--cloud" in l:
        continue
    for m in re.finditer(r"\bsbx\s+(?:secret\s+set\s+bedrock\s+--sandbox|create\s+--name|run\s+--name|exec|rm\s+--force|rm)\s+(\S+)", l):
        if m.group(1) not in ok:
            errs.append("README.md:%d addresses the sandbox %s, a fixed name" % (i, m.group(1)))
    if re.search(r"\bsbx\s+env\s+(?:plan|run|rm)\b", l) and "--name" not in l:
        errs.append("README.md:%d runs sbx env without --name" % i)
# sbxenv.yaml's own usage lines name the sandbox with --name too
for i, l in enumerate(open(env).read().split("\n"), 1):
    if re.search(r"\bsbx\s+env\s+(?:plan|run|rm)\b", l) and "--name" not in l:
        errs.append("sbxenv.yaml:%d runs sbx env without --name" % i)
print("; ".join(errs))
sys.exit(1 if errs else 0)
EOF
}
MSG=$(new_names "${SBX_DIR}/README.md" "${SBX_DIR}/sbxenv.yaml") || fail "the sandbox names: ${MSG}"
python3 - "${SBX_DIR}/README.md" "${D}/README-fixed-name.md" "${SBX_DIR}/sbxenv.yaml" "${D}/sbxenv-no-name.yaml" << 'EOF'
import sys
s = open(sys.argv[1]).read()
t = s.replace('sbx create --name "$N" --cpus', "sbx create --name do-agent-aws --cpus", 1)
e = open(sys.argv[3]).read()
f = e.replace('sbx env run --name "$N" to/sandbox', "sbx env run to/sandbox", 1)
if t == s or f == e:
    sys.exit("could not plant the name controls")
open(sys.argv[2], "w").write(t)
open(sys.argv[4], "w").write(f)
EOF
[ $? -eq 0 ] || fail "could not plant the name controls"
new_names "${D}/README-fixed-name.md" "${SBX_DIR}/sbxenv.yaml" > "${D}/names.out" && fail "planted control: a README create under a fixed name passed the name check"
grep -qF "addresses the sandbox do-agent-aws, a fixed name" "${D}/names.out" || fail "planted control: the fixed name was refused for another reason: $(cat "${D}/names.out")"
new_names "${SBX_DIR}/README.md" "${D}/sbxenv-no-name.yaml" > "${D}/names.out" && fail "planted control: an sbxenv.yaml sbx env run without --name passed the name check"
grep -qF "sbxenv.yaml:" "${D}/names.out" || fail "planted control: sbxenv.yaml without --name was refused for another reason: $(cat "${D}/names.out")"
echo "ok 13 - README.md's local sbx commands address a sandbox only by a new name (\"\$N\") or a placeholder, its sbx env commands and sbxenv.yaml's pass --name; a create under a fixed name and an sbx env run without --name are refused"

# 14. what a dry run does and what the host model check covers, said where an operator reads it
doc_claims()
{
	# $1 = README, $2 = e2e.sh; prints the problems and returns 1, or returns 0
	python3 - "$1" "$2" << 'EOF'
import re, sys
readme, e2e = sys.argv[1:3]
errs = []
# e2e.sh --help: the --dry-run option's text, up to the next option or section
usage = []
for l in open(e2e).read().split("\n")[2:]:
    if not l.startswith("#"):
        break
    usage.append(l[1:])
txt = "\n".join(usage)
m = re.search(r"\n\s*--dry-run\s(.*?)(?=\n\s*--[a-z]|\n\s*\n|\nLayers)", txt, re.S)
opt = re.sub(r"\s+", " ", m.group(1)) if m else ""
if "Converse request" not in opt or "billed" not in opt:
    errs.append("e2e.sh's --dry-run help does not say that a dry run sends billed Converse requests")
r = re.sub(r"\s+", " ", open(readme).read())
m = re.search(r"Run the dry run first: (.*?)\. It exits 2", r)
if not m or "Converse request" not in m.group(1) or "billed" not in m.group(1):
    errs.append("README.md's 'Run the dry run first' paragraph does not say that a dry run sends billed Converse requests")
if "store the secret with that same helper and profile" not in r:
    errs.append("README.md does not say that the sandbox's secret must run the helper and profile the host model check runs")
print("; ".join(errs))
sys.exit(1 if errs else 0)
EOF
}
MSG=$(doc_claims "${SBX_DIR}/README.md" "${SBX_DIR}/test/e2e.sh") || fail "${MSG}"
python3 - "${SBX_DIR}/README.md" "${D}/README-old-dry.md" "${SBX_DIR}/test/e2e.sh" "${D}/e2e-old-dry.sh" << 'EOF'
import re, sys
s = open(sys.argv[1]).read()
t = re.sub(r" When the agent layer would run, it does call\s+AWS:.*?output tokens each\)\.", "", s, count=1, flags=re.S)
t = t.replace("store the secret with that same helper and profile", "store the secret", 1)
e = open(sys.argv[3]).read()
f = re.sub(r" Locally, when\n#\s+the agent layer would run, it also runs the host model check:.*?\(billed, a few tokens each\)\.", "", e, count=1, flags=re.S)
if t == s or f == e:
    sys.exit("could not plant the doc controls")
open(sys.argv[2], "w").write(t)
open(sys.argv[4], "w").write(f)
EOF
[ $? -eq 0 ] || fail "could not plant the doc controls"
doc_claims "${D}/README-old-dry.md" "${D}/e2e-old-dry.sh" > "${D}/doc.out" && fail "planted control: the docs without the dry run's model calls and the helper note passed"
for c in "e2e.sh's --dry-run help" "'Run the dry run first' paragraph" "same helper and profile|helper and profile the host model check runs"; do
	grep -qE -- "${c}" "${D}/doc.out" || fail "planted control: the old docs were not refused for '${c}': $(cat "${D}/doc.out")"
done
echo "ok 14 - e2e.sh's --dry-run help and README.md's dry-run paragraph say that a dry run sends billed Converse requests when the agent layer would run, and README.md says the sandbox's secret must run the helper and profile the host model check runs; the docs without them are refused"

# 15. the kit boots the whole platform by itself: a lifecycle startup hook runs
#     /startup.sh at boot (background, gated by SBX_PLATFORM_AUTOSTART, that name
#     in its env so `sbx create -e` can suppress it), the sandbox layer carries
#     the platform on-switches the image needs in place of .env (UI_START=true,
#     and a documented OFF for the conversations and issues spokes, whose
#     services are off the kit's allowlist) and derives the env file the hook
#     sources, and e2e.sh suppresses the autostart at create and has a stack
#     layer that starts /startup.sh and reads /agent/ui-status.sh; PLANTED
#     CONTROLS: the descriptor without the hook, the layer without each
#     on-switch, and e2e.sh without the suppression or the stack layer rejected
cat > "${D}/platform-boot.py" << 'EOF'
import sys, yaml
desc, layer, e2e = sys.argv[1:4]
errors = []
d = yaml.safe_load(open(desc)) or {}
caps = d.get("capabilities") or []
hooks = [h for c in caps if c.get("type") == "com.docker.sandbox/lifecycle@1"
         for h in ((c.get("config") or {}).get("startup") or [])]
def script(h):
    cmd = h.get("command") or []
    return cmd[-1] if cmd and isinstance(cmd[-1], str) else ""
plat = [h for h in hooks if "/startup.sh" in script(h)]
if not plat:
    errors.append("the descriptor has no lifecycle startup hook that runs /startup.sh: a plain sbx create would not bring the platform up")
else:
    h = plat[0]
    sc = script(h)
    if "SBX_PLATFORM_AUTOSTART" not in sc:
        errors.append("the platform startup hook does not read SBX_PLATFORM_AUTOSTART, so it cannot be suppressed")
    if h.get("background") is not True:
        errors.append("the platform startup hook is not background: boot would block on /startup.sh")
    if "SBX_PLATFORM_AUTOSTART" not in (h.get("env") or []):
        errors.append("SBX_PLATFORM_AUTOSTART is not in the hook's env list, so sbx create -e could not reach it")
lt = open(layer).read()
for kv in ("UI_START=true", "SPOKE_CONVERSATIONS=false", "SPOKE_ISSUES=false"):
    if kv not in lt:
        errors.append("the sandbox layer does not set %s (an on-switch the image carries in place of .env)" % kv)
if "/etc/do-agent-aws-sandbox.env" not in lt:
    errors.append("the sandbox layer does not derive /etc/do-agent-aws-sandbox.env for the boot hook to source")
et = open(e2e).read()
if "-e SBX_PLATFORM_AUTOSTART=false" not in et:
    errors.append("e2e.sh does not suppress the boot autostart at create, so the harness suite would run against a live platform")
if "layer stack " not in et:
    errors.append("e2e.sh has no stack layer that verifies the platform")
if "/agent/ui-status.sh" not in et:
    errors.append("e2e.sh's stack layer does not consult /agent/ui-status.sh")
if "stack-reboot.log" not in et:
    errors.append("e2e.sh's stack layer does not reboot the sandbox (sbx stop) before starting the platform, so the harness layer's leftover UI processes would block it")
print("\n".join(errors))
sys.exit(1 if errors else 0)
EOF
pboot()
{
	python3 "${D}/platform-boot.py" "$1" "$2" "$3"
}
OUT=$(pboot "${SBX_DIR}/template/${KIT}.yaml" "${SBX_DIR}/template/sandbox.dockerfile" "${SBX_DIR}/test/e2e.sh" 2>&1) \
	|| fail "the kit does not boot the platform by itself: ${OUT}"
python3 - "${SBX_DIR}/template/${KIT}.yaml" "${D}/desc-nohook.yaml" << 'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for c in d.get("capabilities") or []:
    if c.get("type") == "com.docker.sandbox/lifecycle@1":
        su = (c.get("config") or {}).get("startup") or []
        c["config"]["startup"] = [h for h in su if "/startup.sh" not in (((h.get("command") or [""]) or [""])[-1] or "")]
yaml.safe_dump(d, open(sys.argv[2], "w"))
EOF
OUT=$(pboot "${D}/desc-nohook.yaml" "${SBX_DIR}/template/sandbox.dockerfile" "${SBX_DIR}/test/e2e.sh" 2>&1) \
	&& fail "planted control: a descriptor without the platform startup hook was accepted"
echo "${OUT}" | grep -qF "no lifecycle startup hook that runs /startup.sh" || fail "planted control hook: wrong reason: ${OUT}"
for kv in UI_START=true SPOKE_CONVERSATIONS=false SPOKE_ISSUES=false; do
	grep -vF "${kv}" "${SBX_DIR}/template/sandbox.dockerfile" > "${D}/layer-no-${kv%%=*}.dockerfile"
	OUT=$(pboot "${SBX_DIR}/template/${KIT}.yaml" "${D}/layer-no-${kv%%=*}.dockerfile" "${SBX_DIR}/test/e2e.sh" 2>&1) \
		&& fail "planted control: the layer without ${kv} was accepted"
	echo "${OUT}" | grep -qF "does not set ${kv}" || fail "planted control ${kv}: wrong reason: ${OUT}"
done
grep -vF -- "-e SBX_PLATFORM_AUTOSTART=false" "${SBX_DIR}/test/e2e.sh" > "${D}/e2e-nosuppress.sh"
OUT=$(pboot "${SBX_DIR}/template/${KIT}.yaml" "${SBX_DIR}/template/sandbox.dockerfile" "${D}/e2e-nosuppress.sh" 2>&1) \
	&& fail "planted control: e2e.sh without the autostart suppression was accepted"
echo "${OUT}" | grep -qF "does not suppress the boot autostart" || fail "planted control suppress: wrong reason: ${OUT}"
grep -v 'layer stack ' "${SBX_DIR}/test/e2e.sh" > "${D}/e2e-nostack.sh"
OUT=$(pboot "${SBX_DIR}/template/${KIT}.yaml" "${SBX_DIR}/template/sandbox.dockerfile" "${D}/e2e-nostack.sh" 2>&1) \
	&& fail "planted control: e2e.sh without the stack layer was accepted"
echo "${OUT}" | grep -qF "no stack layer" || fail "planted control stack: wrong reason: ${OUT}"
grep -vF 'stack-reboot.log' "${SBX_DIR}/test/e2e.sh" > "${D}/e2e-noreboot.sh"
OUT=$(pboot "${SBX_DIR}/template/${KIT}.yaml" "${SBX_DIR}/template/sandbox.dockerfile" "${D}/e2e-noreboot.sh" 2>&1) \
	&& fail "planted control: e2e.sh without the stack reboot was accepted"
echo "${OUT}" | grep -qF "does not reboot the sandbox" || fail "planted control reboot: wrong reason: ${OUT}"
echo "ok 15 - the kit boots the platform by itself (a background /startup.sh hook gated by SBX_PLATFORM_AUTOSTART), the layer carries the on-switches (UI_START, conversations/issues OFF) and the hook's env file, and e2e.sh suppresses the autostart and checks the platform through ui-status.sh (planted: no hook, each missing on-switch, no suppression, no stack layer)"


cleanup
echo "Sandbox test1 succeeded"
