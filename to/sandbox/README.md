# to/sandbox - the harness in a Docker Sandbox

**Status, 2026-10-15: the kit builds from main again and `sbx create` creates the sandbox on a
KVM host; `e2e.sh --local` last passed at main 3defadd on 2026-10-13; not run in the cloud.**
- **2026-10-15:** the kit had stopped building from main. The Dockerfile had started to COPY
  README.md and docs/ files that render.sh did not stage, so the kit image came out empty and sbx
  reported only "conformance: ... no /etc/passwd ... /bin/sh is missing". render.sh now stages every
  COPY/ADD source (test1 check 2), and `sbx create` built the kit from main and created the sandbox.
  The end-to-end test has not been re-run on main since 2026-10-13.
- **Last PASS:** commit 3defadd (main, the merge of #28), sbx 0.47.0, an EC2 m8i.2xlarge with
  KVM (Ubuntu 24.04), 2026-10-13. Every layer passed, the agent layer included, under the
  deny-all preset with the model credential described below (an Amazon Bedrock API key the
  sandbox proxy injects, "Model credential"): the harness suite 13/13, and the agent's report
  verified with 15 checks on the pinned Sonnet model. Its `summary.json` is in that run's
  `--out` directory, `e2e-local-20261013T015034Z/`.
- That run needed one manual step: a long request to sbx's kit registry, so that sbx could
  finish copying the new build in (93 s). The `e2e.sh` here waits for that copy itself ("Local
  sandboxes").
- **Earlier PASSes:** 2026-10-08, at bb95419 and at 2a7c12c (harness 12/12). `docs/STATUS.md`
  has their evidence.
- **Untried:** an interactive `sbx run` session, and the cloud path.

[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) run an agent in a microVM, on a
host with KVM (local sandboxes) or on Docker-managed infrastructure (cloud sandboxes). The
microVM is the security boundary, so the agent gets its own Docker Engine and can build, run
and test containers without any host Docker socket. This target packages the do-agent-aws
harness as a Docker Sandboxes **workload kit**: one OCI image whose layers are the harness and
whose manifest carries a descriptor - the workload's permission request for compute, network
egress and credentials. The sandbox runtime and its policy decide what is granted.

## First local PASS

The shortest path from a fresh KVM host to a passing `e2e.sh --local`, in the order the steps
depend on each other. The sections named in each step explain it.

**Before you start**

| You need | Detail |
|---|---|
| Host | Linux amd64 with `/dev/kvm` (tested: an EC2 m8i.2xlarge with Ubuntu 24.04) and Docker Engine with Buildx, which sbx 0.47.0 builds the kit with. Room to build: each new kit build added 20 to 30 GB to sbx's state directory on the KVM test host (the image itself is about 11 GB) |
| sbx | Exactly 0.47.0: `e2e.sh --local` refuses any other version. On Ubuntu 24.04, the `DockerSandboxes-linux-amd64-ubuntu2404.deb` asset of release `v0.47.0` of [docker/sbx-releases](https://github.com/docker/sbx-releases/releases/tag/v0.47.0) (sha256 `62ff97a07e0ca760eec873b7407e95b9c93022640a3cfe8317c76810eb01f5f0`), and a Docker account to sign in with |
| Tools | bash 4.4+, git, jq, curl, flock, coreutils `timeout`, python3 with PyYAML, and `python3-venv` |
| AWS | An AWS profile (here `bedrock`) whose role may call `bedrock:CallWithBearerToken` and invoke the two pinned models in us-east-1 ("Model credential", step 1) |
| Time | The first kit build takes 10 to 30 minutes; an e2e run about 6 minutes (measured: 5m21s to 6m14s) |

**Once per host**

1. Install sbx 0.47.0 (`sudo apt install ./DockerSandboxes-linux-amd64-ubuntu2404.deb`) and run
   `sbx login`.
2. Set up the model credential: steps 1 to 4 of "Model credential" (the role's permissions, the
   AWS profile, the helper and its venv, the binding). Install the helper before any secret
   names it:

   ```bash
   install -d -m 0700 ~/.local/share/sbx-bedrock
   python3 -m venv ~/.local/share/sbx-bedrock/venv
   ~/.local/share/sbx-bedrock/venv/bin/pip install 'aws-bedrock-token-generator==1.1.0' 'botocore==1.43.109'
   install -m 0700 to/sandbox/bedrock-token.sh ~/.local/share/sbx-bedrock/bedrock-token.sh
   ~/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1 | cut -c1-16   # bedrock-api-key-
   ```

**Once per kit content** (the first time, and after a commit that changes `Dockerfile`,
`template/` or `Container-Root/`)

3. Build the kit under the balanced preset, then switch the host to deny-all ("Local
   sandboxes"). The build needs hosts that deny-all does not list, so do not start with
   deny-all. The reset commands stop every running sandbox.

   ```bash
   sbx policy reset --force    # leave out on a host whose policy was never initialized
   sbx policy init balanced
   to/sandbox/render.sh
   sbx create --name do-agent-aws-prebuild --cpus 4 --memory 8g --skills off ./to/sandbox/app/do-agent-aws-sandbox
   sbx rm --force do-agent-aws-prebuild
   sbx policy reset --force
   sbx policy init deny-all
   ```

**Each run**

4. Give the run a new sandbox name, store that name's secret, then dry-run and run ("The
   end-to-end test"):

   ```bash
   N=do-agent-aws-e2e-$(date -u +%Y%m%dt%H%M%S)
   sbx secret set bedrock --sandbox "$N" \
     --command "$HOME/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1" --refresh 55m
   to/sandbox/test/e2e.sh --local --require-agent --dry-run --name "$N"
   to/sandbox/test/e2e.sh --local --require-agent --name "$N"
   ```

   - Use a new name every time: sbx 0.47.0 does not give a sandbox the key of a name it served
     before ("A new name for each sandbox", below).
   - The first dry run after a build can take a minute or two while sbx copies the build into
     its kit registry.
5. A PASS is exit 0 with every layer `PASS` in `summary.json`, in the run's `--out` directory
   (by default `wd/sandbox-e2e/<UTC timestamp>/`). The run removes its sandbox and the
   sandbox-scoped secret.

It follows the `to/<target>/template` -> `to/<target>/app` pattern of `to/compose` and
`to/kubernetes`: `render.sh` writes the kit into `to/sandbox/app/` (generated, not committed);
`test/` holds this target's tests (the sibling targets have none).

**`TO=sandbox`.** With `export TO=sandbox` in `.env.local` (docs/manual/install.md "Settings") the top-level
scripts drive this target as they drive the others, each in a branch of its own: `./build.sh`
renders the kit from HEAD (`render.sh`; commit first) and builds it the way `sbx` does, through a
throwaway sandbox (`SANDBOX_PREBUILD_NAME`, `do-agent-aws-prebuild`) that is removed at once, so
that `./run.sh` reuses the build (`kit ... unchanged, reusing`); `./run.sh` creates the sandbox
(`sbx create --name do-agent-aws ...`; `./run.sh <command>` creates it and runs the command in it);
`./status.sh` shows its line of `sbx ls`; `./exec.sh` opens a shell in it, or runs the command
given, `-s` for a plain shell as on every target; `./stop.sh` removes it (`sbx rm --force`, as the
docker target's stop removes the container; `sbx stop do-agent-aws` is the keep-state
alternative); `./logs.sh` says where the agent's output is, since a sandbox has no log stream to
follow (the kit starts `claude` itself, not `/startup.sh`). Before a build or a create, `preflight
sandbox` (`preflight.sh`) names what a local sandbox needs on this host, each gap with its fix:
`sbx` on PATH, `/dev/kvm`, the daemon answering (`sbx ls -q`), the descriptor readable. The
sizes still have one source, the descriptor's `resources@1` (`sbxenv.yaml` is checked to match
it; `e2e.sh`, `build.sh` and `run.sh` read it). The settings are `.env`'s `## sandbox` block
(`SBX`, `SANDBOX_NAME`, `SANDBOX_KIT`, `SANDBOX_DESCRIPTOR`, `SANDBOX_CREATE_OPTS`,
`SANDBOX_PREBUILD_NAME`); the sandbox runs the kit image's own environment, not the `.env`
settings, and no UI or board sidecar starts in it ("Known limitations"). The sign-in, the policy,
the model credential, `push-kit.sh` and `test/e2e.sh` stay this target's own steps, below, and
`./test.sh`'s suite is still the Docker image's (`e2e.sh`'s harness layer runs it in a sandbox).
The other targets' scripts never call `sbx`: the sandbox case is a separate branch, and the
docker, compose, swarm and kubernetes branches are unchanged (`test-sandbox.sh` checks both).
A kit image can follow `.env`'s naming, for example
`docker.io/${REGISTRY}${IMAGE}-sandbox:<tag>` (`iankoulski/aws-do-agent-sandbox`), as long as
that repository is private.

| Path | What it is |
|---|---|
| `template/do-agent-aws-sandbox.yaml` | kit descriptor (Docker Sandbox Kit Specification v3) |
| `template/sandbox.dockerfile` | the sandbox layer, appended to the repository `Dockerfile` |
| `template/do-agent-aws-sandbox-context.md` | instructions the sandbox gives the agent (`CLAUDE.md` profile) |
| `render.sh` | renders `app/do-agent-aws-sandbox/` from HEAD: descriptor, `Dockerfile` + sandbox layer, and every source its `COPY`/`ADD` lines name (`Container-Root/`, `README.md`, the `docs/` files the image serves), minus what `.dockerignore` excludes; it stops, naming the source, when HEAD lacks one |
| `build-env.sh` | sourced by test2.sh and `push-kit.sh`: the kit builder, whose build steps cannot reach the instance metadata service |
| `push-kit.sh` | pushes the kit image to a Docker Hub repository it has confirmed private, or refuses |
| `bedrock-token.sh` | host-side helper: prints a short-term Amazon Bedrock API key, the value of the sandbox-scoped `bedrock` secret; installed outside every sandbox mount ("Model credential") |
| `sbxenv.yaml` | the same setup as a declarative `sbx env` file (experimental) |
| `example/compose-demo/` | worked example: the agent builds, runs and tests a Compose stack inside the sandbox |
| `test/test1.sh` ... `test5.sh` | checks that need no sign-in and no KVM |
| `test/e2e.sh` | the end-to-end test in a real sandbox, local or cloud |

## What the kit declares

The descriptor (`template/do-agent-aws-sandbox.yaml`) is the kit's permission request; the
sandbox runtime and its policy decide what is granted:

| Capability | Value |
|---|---|
| `sbx@1` | the host launches the agent (the image `ENTRYPOINT`, `claude`) under bash and runs it as the image's user |
| `resources@1` | 4 CPU, 8 GiB - the cloud `medium` shape; also passed as `--cpus 4 --memory 8g` at create |
| `network-policy@1` | runtime allowlist `bedrock-runtime.us-east-1.amazonaws.com:443` (the model endpoint: Amazon Bedrock's runtime, in the one region the image pins), `public.ecr.aws:443` and `d2glxqk2uabbnd.cloudfront.net:443` (Amazon ECR Public pulls inside the sandbox; Docker Hub is not allowed); nothing for an install phase; no Anthropic host, no Bedrock control plane. These are the only reachable hosts only under a deny-by-default policy (local: `sbx policy init deny-all`; cloud: `e2e.sh` sets the sandbox's own policy to deny-all); under a broader policy the runtime adds them to what it already allows |
| `credential@1` | service `bedrock`, optional, proxy managed: the sandbox sees the sentinel `proxy-managed` in `AWS_BEARER_TOKEN_BEDROCK`; the proxy writes `Bearer <stored key>` into `Authorization` for `bedrock-runtime.us-east-1.amazonaws.com`. The stored value is a short-term Bedrock API key that `bedrock-token.sh` makes on the host ("Model credential") |
| `lifecycle@1` | startup hook, a fallback only: start the image's `dockerd` when no engine answers. The runtime starts `dockerd` for images labeled `com.docker.sandboxes.start-docker=true` (this image is; the specification's builder example documents the label), so the hook is normally a no-op; it cannot help where the sandbox lacks the privilege `dockerd` needs. `e2e.sh`'s platform layer reports whether an engine answered. A second startup hook starts the harness platform: `/startup.sh` in the background (boot does not wait on its keepalive loop), with `/etc/do-agent-aws-sandbox.env` sourced, unless `SBX_PLATFORM_AUTOSTART=false` (`sbx create -e SBX_PLATFORM_AUTOSTART=false` for a platform-free VM, as `e2e.sh`'s harness layer uses) |
| `agent-context@1` | `CLAUDE.md` profile beside the workspace, pointing at `do-agent-aws-sandbox-context.md` |

Not declared, on purpose: no `port@1` (nothing is published - a cloud published port is a
public HTTPS URL), no volume or host mount (cloud sandboxes cannot mount host paths; files go
in and out with `sbx cp`), no `privileged@1` (Docker's docs say sbx does not apply it; the
runtime starts `dockerd` for images with the start-docker label). The ECR Public blob redirect
went to `d2glxqk2uabbnd.cloudfront.net` (observed from an AWS host, 2026-11-10). `e2e.sh` saves
`sbx policy log` after the example runs, which shows the hosts the pulls in the sandbox actually
used; a stack that needs an image from another registry is refused until the owner adds it.

Residual risk of the registry entries: an allowlisted registry also accepts pushes, so a
process in the sandbox that brings its own registry credentials could upload what the
sandbox holds (the repository copy and the results; the Bedrock key is proxy-managed and not
readable inside). No registry credentials are configured for the sandbox. Pre-loading the
example's base image into the kit would let the allowlist drop the registry, at the cost of any
other pull the agent's stacks need; that is an owner decision.

## How the image differs from `./build.sh`'s

`render.sh` uses the repository `Dockerfile` verbatim (same `ubuntu:22.04` base, same
`Container-Root`, same `setup.sh`) and appends `template/sandbox.dockerfile`, which:

- carries the platform's on-switches the image would otherwise lack (`.env` is not in the image,
  so on the docker target `run.sh` passes them): `UI_START=true`, and `SPOKE_CONVERSATIONS=false`
  and `SPOKE_ISSUES=false`, because Slack and GitHub are off the kit's deny-all allowlist (the
  status reads them as OFF, not as failures). The same values are written to
  `/etc/do-agent-aws-sandbox.env`, which the platform hook sources, so the hook's `/startup.sh` and a
  later `sbx exec /agent/ui-status.sh` agree on what is enabled. To run those two spokes, add
  their hosts to the kit's allowlist and change these values, then rebuild the kit;
- installs Docker Engine, the CLI, Buildx and Compose from download.docker.com (versions
  pinned, jammy/stable as of 2026-10-02) and labels the image `com.docker.sandboxes.start-docker=true`;
- creates `/usr/local/share/ca-certificates` (the runtime installs its egress-proxy CA there
  and adds it to the system bundle), `/etc/sandbox-persistent.sh` (named by `BASH_ENV`, and
  sourced by login and interactive shells too) and `/root/workspace` (the `WORKDIR`);
- points Node (`NODE_EXTRA_CA_CERTS`), Python requests (`REQUESTS_CA_BUNDLE`), OpenSSL
  (`SSL_CERT_FILE`) and curl (`CURL_CA_BUNDLE`) at that system bundle, as Docker's agent guide
  does: the proxy terminates TLS to inject credentials, and Node does not read the system store;
- writes `/etc/sandbox-persistent.sh` (`template/sandbox-persistent.sh`, named by `BASH_ENV` and
  sourced by login and interactive shells) so the lower-case and upper-case proxy variables agree.
  The sbx runtime injects its egress proxy as upper-case `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`; the
  harness `.env` also exports empty lower-case `http_proxy=`/`https_proxy=` (right on a host with no
  proxy), and carried into the sandbox those empty values shadow the upper-case ones for a client
  that reads the lower-case names - Python's `urllib`/`botocore`, which the memory API
  (hindsight-api) uses - so it bypasses the proxy and sends the untouched `AWS_BEARER_TOKEN_BEDROCK`
  sentinel to Bedrock, which answers 403 `Invalid API Key format`. Claude Code (Node) reads the
  upper-case names and was unaffected, so the same sandbox had a working agent and a failing memory
  extraction. The snippet mirrors a set name into an empty-or-unset partner of the opposite case; it
  is a no-op where no proxy is set (test-proxy-env.sh, with a planted control);
- keeps Claude Code on Amazon Bedrock, the harness's default, and pins it: `CLAUDE_CODE_USE_BEDROCK=1`,
  `AWS_REGION=us-east-1`, `ANTHROPIC_DEFAULT_SONNET_MODEL=us.anthropic.claude-sonnet-4-5-20250929-v1:0`
  and `ANTHROPIC_DEFAULT_HAIKU_MODEL=us.anthropic.claude-haiku-4-5-20251001-v1:0` (the small/fast
  model; the Claude Code Bedrock docs call the older `ANTHROPIC_SMALL_FAST_MODEL` deprecated), in
  the environment **and** in the `env` block of `/home/agent/.claude/settings.json`, which overrides
  the process environment (verified 2026-10-07: with only the environment switched, Claude Code
  followed the settings file). The Sonnet pin without an Opus pin keeps Sonnet 4.5 the default
  model. The build fails unless the settings file carries the environment's values; it also
  fails if the settings file names an AWS credential variable, if it or the environment sets a
  model variable that would replace the pinned Sonnet as the default (`ANTHROPIC_MODEL`,
  `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_MODEL`), or if either sets an
  `AWS_DEFAULT_REGION` other than `AWS_REGION`. The image holds no AWS credential;
- sets `IS_SANDBOX=1` (Claude Code requires it before it accepts `bypassPermissions` as root)
  and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (telemetry, error reporting and update
  checks off, so the agent needs no Anthropic host);
- declares `USER root`, `WORKDIR /root/workspace`, `ENTRYPOINT ["claude"]`.

**Identity.** The Docker Sandboxes platform floor documents a non-root `agent` user (uid 1000,
`/home/agent`), and the harness image is built around exactly that user: it runs as `agent`, with
its Claude Code configuration, plugins and memory under `/home/agent`. This layer switches back to
`USER root`: the agent builds and runs Compose stacks against a Docker Engine inside the sandbox
microVM, which is the isolation boundary, and the harness tests here assume root. The v3 `sbx@1` contract
runs the agent as whatever user the image declares, Docker's own `alpine` example kit does
the same, and `kit-tck` passes the `sbx@1` platform-floor check for this image (test2.sh).
Whether a cloud sandbox accepts a root workload is exercised by `e2e.sh` (`platform` layer).

## Validate without sign-in

These run on any Linux host with Docker; none needs `sbx login` or KVM. `render.sh`, test2.sh,
test4.sh and `e2e.sh` take everything from the commit at HEAD (`git archive`), never from the
working tree, so commit before running them.

```bash
to/sandbox/test/test1.sh   # static: render, descriptor/sbxenv invariants, e2e.sh guard rails and kit-key.py, each with planted controls
to/sandbox/test/test2.sh   # build through the pinned kit frontend, kit-tck conformance, image contract, staged recipe
to/sandbox/test/test3.sh   # compose-demo on plain Docker, with planted controls for the example and its verifier
to/sandbox/test/test4.sh --allow-privileged   # the image as a privileged container, metadata service blocked (see below)
to/sandbox/test/test5.sh   # e2e.sh's control flow against a scripted sbx: interrupt, late or missing sandbox, policy gate, local kit build check, model credential, the in-sandbox key check; bedrock-token.sh against stubs
to/sandbox/test/test-proxy-env.sh          # the sandbox layer's proxy-env coherence, with a planted control
to/sandbox/test/test-load-knowledge-pack.sh  # load-knowledge-pack.sh's fail-closed manifest gate and plan
```

test1.sh runs `sbx env plan` on `sbxenv.yaml` (its check 9) only while the local sbx daemon
runs (`sbx daemon start -d`); otherwise it reports that check as skipped.

**The rendered build context.** The kit's build context is the rendered directory, so every
source a `COPY` or `ADD` line of the `Dockerfile` names must be in it; a missing one fails the
kit build with `"/<path>": not found` and the frontend's `conformance:` lines about an image that
was never built. test1.sh check 2 requires each source in the render as HEAD has it. A build
through the pinned kit frontend whose steps have no network checks the same thing with BuildKit
itself, with no KVM and no sign-in: it resolves the `COPY` sources in its first seconds, and a
missing one stops it there; with all of them present it goes on to `setup.sh`, the first step
that downloads, and fails there. It keeps nothing (OCI output to `/dev/null`):

```bash
to/sandbox/render.sh
docker buildx create --name kit-context-check --driver docker-container   # once
FE=docker/sandbox-kit:3@sha256:e6a397771e865625047cf84256a914c7974b3e749d858259b5bc9c653ddb6f0d
docker buildx build --builder kit-context-check --network=none --build-arg BUILDKIT_SYNTAX=$FE \
  -f to/sandbox/app/do-agent-aws-sandbox/do-agent-aws-sandbox.yaml --output type=oci,dest=/dev/null \
  to/sandbox/app/do-agent-aws-sandbox 2>&1 | grep -E '^ERROR:|failed to calculate checksum'
```

The check passes only when it prints exactly one line, the build's own error for `setup.sh`:
`ERROR: failed to build: failed to solve: process "/bin/sh -c ... /setup.sh && rm -f /setup.sh"
did not complete successfully`. Every `COPY` source was found if the build got that far. A
missing source prints its `"/<path>": not found` line, then `failed to solve: conformance:`.
Any other `ERROR:` line, for instance a missing builder, a missing kit directory or a frontend
image that cannot be pulled, means the check did not run.

The kit build also prints two BuildKit warnings, JSONArgsRecommended and
MultipleInstructionsDisallowed, both for the repository `Dockerfile`'s `CMD /startup.sh`: the
sandbox layer's `ENTRYPOINT ["claude"]` and `CMD []` replace that command in the kit, as
intended, and the warnings change nothing in the image.

test2.sh needs `kit-tck`, the specification's conformance tool:

```bash
gh release download v3.0.0-m.8 -R docker/sandbox-kit-spec -p 'kit-tck_3.0.0-m.8_linux_amd64.tar.gz' -p checksums.txt
grep linux_amd64 checksums.txt | sha256sum -c - && tar -xzf kit-tck_3.0.0-m.8_linux_amd64.tar.gz kit-tck
KIT_TCK=$PWD/kit-tck to/sandbox/test/test2.sh
```

The checksum file comes from the same release as the tool, so this checks the download's
integrity, not who built it. test2.sh pins the kit frontend by digest
(`BUILDKIT_SYNTAX=docker/sandbox-kit:3@sha256:e6a3977...`); the descriptor keeps the literal
`# syntax=docker/sandbox-kit:3` line the specification dispatches on.

**The build cannot reach the instance metadata service.** The kit build runs the harness's
upstream installers with network access, so test2.sh and `push-kit.sh` build in the builder
of `build-env.sh`: a `docker-container` buildx builder (`do-agent-aws-sandbox-imds-blocked`)
attached to one Docker network only (`do-agent-aws-sandbox-build`). While a build runs, a
`DOCKER-USER` rule (`sudo iptables`) drops that network's traffic to 169.254.169.254. The rule
is tagged per run, `do-agent-aws-sandbox:build:<network>:<run id>`, and each run removes only
its own, once. Before each build a probe build step must run (its marker line is required):
the service must answer it without the rule (401, the positive control) and must not answer
with it. Builds are serialized. A tagged rule left by a killed run is removed at the next
start only when its network no longer exists; one for the build network stays (it only blocks)
until removed by hand. On a host without a metadata service, `SBX_ALLOW_NO_IMDS=1` accepts a
control with no answer. The image's two Hugging Face models are pinned by revision
(`SBX_BGE_REVISION`, `SBX_RERANKER_REVISION` in `template/sandbox.dockerfile`, safetensors
only; test2.sh checks both). To remove every metadata-drop rule these scripts tag (test4.sh
tags its own `do-agent-aws-sandbox:test4:<network>`), run this only while no build (test2.sh,
`push-kit.sh`) and no test4.sh is running, since it also removes a running build's rule:

```bash
sudo iptables -S DOCKER-USER | grep -F '"do-agent-aws-sandbox:' | sed 's/^-A /-D /' | while read -r r; do eval "sudo iptables $r"; done
```

test4.sh is a stand-in for hosts without KVM: it judges the image, not the sandbox (no
microVM, no sbx proxy, network policy or credential injection). Docker-in-Docker needs a
`--privileged` container, and the image ran upstream installers at their latest versions
(`Container-Root/setup/install-claude.sh`, `harden.sh`, `install-uv.sh`, `install-kubectx.sh`
pin none), so the test runs only with `--allow-privileged`. For its whole run it blocks the EC2
instance metadata service (the source of the host's instance-role credentials, which a plain
container on this host can reach): the container gets its own Docker network and a
`DOCKER-USER` rule (`sudo iptables`) drops that network's traffic to 169.254.169.254; the test
proves the block from the container and from a container its engine starts, and removes the
rule, network, container and volume on exit. It runs the harness suite with egress limited to
the kit's allowlist (iptables in the container's own network namespace admit only the
allowlisted hosts' addresses on 443, Docker's DNS and loopback), because that is what the
suite meets in a sandbox under deny-all: with no network at all, harness test9 fails (the
memory API exits when it cannot download tiktoken's encoding and its two Hugging Face models;
the image now fetches them at build time, about 220 MB, and runs the hub offline) and
test12 failed (seen with the Anthropic API configured: Claude Code exited when it could not
reach its model endpoint, which the allowlist admits; now `bedrock-runtime.us-east-1.amazonaws.com`,
which the emulation probes for AWS's 404 to a bare GET, while `example.com` and
`api.anthropic.com` must get no answer). Run it only on a host where a privileged test
container is acceptable.

## Local sandboxes (hosts with KVM)

**What the host needs before `sbx create` builds the kit.** Run `sbx diagnose` first: its
Virtualization line says whether this host can run local sandboxes at all. A kit build that
stops at once with this error has one of two causes:

```
ERROR: failed to build: OCI exporter is not supported for the docker driver.
Switch to a different driver, or turn on the containerd image store, and try again.
Learn more at https://docs.docker.com/go/build-exporters/
```

- **No hypervisor** (no `/dev/kvm`, as on the EC2 instances where this error was seen): sbx
  creates no builder sandbox there and builds on the host engine's docker driver, which cannot
  export the OCI image a kit is. The error's own advice, the containerd image store, may let that
  build run (not tried here), but the host still cannot run a local sandbox. From such a host,
  run a cloud sandbox from a pushed kit ("Cloud sandboxes" below, `push-kit.sh`).
- **Hypervisor present, classic image store**: the build ran on the docker driver of an engine
  without the containerd image store. `docker info -f '{{ .DriverStatus }}'` prints
  `[[driver-type io.containerd.snapshotter.v1]]` when the containerd image store is on, and
  `docker buildx ls` shows the driver of each builder (`*` marks the one in use). Either turn the
  containerd image store on (Docker Desktop: Settings, General, "Use containerd for pulling and
  storing images"; Docker Engine: `{"features": {"containerd-snapshotter": true}}` in
  `/etc/docker/daemon.json`, then restart the daemon; the images and containers of the other store
  are not shown until you switch back), or build with a buildx builder that is not the docker
  driver (`docker buildx create --name <name> --driver docker-container --use`; test2.sh,
  `push-kit.sh` and the context check under "Validate without sign-in" use one). Whether
  `sbx create` follows the selected buildx builder is not verified.

Once per host: install `sbx` 0.47.0 (exactly that version for `e2e.sh --local`: its check of
the kit build, below, relies on how sbx 0.47.0 names and stores a build, so any other version,
later ones included, stops it in preflight with `KIT_BUILD_UNKNOWN`), sign in, and build the
kit before the host goes to deny-all. `sbx create` builds a kit directory that sbx has not
built yet before it creates the sandbox, and the first build of this kit takes longer than
`e2e.sh`'s create timeout (20 minutes; with sbx 0.47.0 on an m8i.2xlarge, under deny-all,
setup.sh alone took 19), so a throwaway sandbox does that build, waiting as long as it takes.
The build downloads from hosts that deny-all does not list, so it runs under the balanced
preset. On that host, with sbx 0.47.0, deny-all did not block the build (sbx built it with
the host's Docker engine, and it reached download.docker.com in under 50 ms); whether it
slowed it was not measured (under deny-all, apt waited about a minute at a time on the Ubuntu
mirrors, which answered in under a second in the balanced build). The reset commands stop
every running sandbox, and between the first and the last of them the host is under the
balanced preset. From the repository root:

```bash
sbx login
sbx policy reset --force    # only if this host's policy was initialized before
sbx policy init balanced
to/sandbox/render.sh
sbx create --name do-agent-aws-prebuild --cpus 4 --memory 8g --skills off ./to/sandbox/app/do-agent-aws-sandbox
sbx rm --force do-agent-aws-prebuild
sbx policy reset --force
sbx policy init deny-all                          # the kit's allowlist is the whole egress only under deny-all
```

The first `sbx create` prints `→ build kit ...`; a later one from the same content prints
`→ kit ... unchanged, reusing sbx-kit-src:do-agent-aws-sandbox-<key>`. Build again (the lines
from the first `sbx policy reset --force` to `sbx policy init deny-all`) after a commit that
changes what `render.sh` copies: the `Dockerfile`, `.dockerignore`, `template/` or a source the
`Dockerfile` copies (`Container-Root/`, `README.md`, the `docs/` files it names). If the build is
missing, `e2e.sh --local` stops in preflight within seconds, before anything is created, with
`KIT_NOT_BUILT` and these commands (and with `KIT_BUILD_UNKNOWN`, naming the cause, if it cannot
tell). The first check after a build can take longer: sbx 0.47.0 copies a build from the Docker
engine into its kit registry on the first request for it, and `e2e.sh` waits for that copy up
to `E2E_T_KIT_REGISTRY` seconds (default 600). On the KVM test host on 2026-10-13, after a
commit that changed `Container-Root` (so setup.sh ran again), the copy took 93 s; with the
earlier 20 s limit every request cancelled it and preflight stopped with `KIT_BUILD_UNKNOWN`.
sbx 0.47.0 keys a build on the paths and contents of the kit directory's files, not
their modes: a commit that changes only a file's mode (say, `chmod +x` on a `Container-Root`
script) reuses the old image, and neither this check nor the provenance layer, which hashes
contents, notices. Change such a mode together with the content of a file the kit copies.

`sbx policy ls` must show no network allow rule that applies to all sandboxes
(`e2e.sh --local` refuses to run otherwise). Set up the model credential once per host (the
role's IAM policy, the AWS profile, the helper and the binding: "Model credential" below), and
give each sandbox a new name and its own `bedrock` secret, a command that sbx runs on this
host to make a short-term Bedrock API key (it names the helper, so install that first: "Model
credential", step 3):

```bash
N=do-agent-aws-$(date -u +%Y%m%dt%H%M%S)
sbx secret set bedrock --sandbox "$N" \
  --command "$HOME/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1" --refresh 55m
```

Then, from the repository root:

```bash
to/sandbox/render.sh
sbx create --name "$N" --cpus 4 --memory 8g --skills off ./to/sandbox/app/do-agent-aws-sandbox
sbx run --name "$N"       # attach: Claude Code with the harness configuration
sbx exec "$N" docker compose version
sbx rm --force "$N"
```

A relative kit path must start with `./` (otherwise `sbx` reads it as a registry or agent
name); `--skills off` keeps the host's skills store out of the sandbox. This `sbx create`
reuses the build made above. The declarative equivalent is
`sbx env run --name "$N" to/sandbox` (see `sbxenv.yaml`); `sbx env plan` and `sbx env rm` take
the same `--name`.

**A new name for each sandbox.** With sbx 0.47.0, reusing the name of an earlier sandbox can
leave the new sandbox without the stored key. On the KVM test host on 2026-10-13, every request
to the Bedrock endpoint then got HTTP 403 (`Invalid API Key format`), whatever the sandbox sent:
after the earlier sandbox was removed with its secret kept, and after its secret was removed
first (as `e2e.sh` does) and set again. sbx did not run the secret's command for the new sandbox
at all, so its proxy sent something other than a key. Names never used before always got the
key. So give each new sandbox its own name and set its secret first, as in the commands above
and below; a second `e2e.sh` run under the same name fails its harness test3 and agent layers.
- `sbx env run to/sandbox` without `--name` always uses the name in `sbxenv.yaml`,
  `do-agent-aws`. So a second `sbx env run` after `sbx env rm` re-creates a name sbx has served
  before. Pass a new `--name` to `sbx env plan`, `run` and `rm` alike: sbx 0.47.0's
  `sbx env run --help` says every `sbx env` command for one environment needs the same name.
- If a name must be reused, two things restored the key on the KVM test host. One was removing
  the sandbox first, then its secret, then setting the secret again before the next create. The
  other was `sbx daemon restart`, then setting the secret again. With the secret kept, neither a
  re-create nor a daemon restart did.

End-to-end test (its secret, scoped to the sandbox name it is given, is removed after the run):

```bash
N=do-agent-aws-e2e-$(date -u +%Y%m%dt%H%M%S)
sbx secret set bedrock --sandbox "$N" \
  --command "$HOME/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1" --refresh 55m
to/sandbox/test/e2e.sh --local --require-agent --dry-run --name "$N"   # seconds; creates nothing
to/sandbox/test/e2e.sh --local --require-agent --name "$N"
```

Run the dry run first: it is the fail-fast check. It takes seconds and creates nothing in sbx
(on the KVM test host on 2026-10-08, a dry run that stopped with `KIT_NOT_BUILT` took 1.0 s,
and the passing one before the full run 12 s). When the agent layer would run, it does call
AWS: the host model check below makes a key on this host and sends one smallest Converse
request to each of the two pinned models, which are billed (a few input tokens and at most 5
output tokens each). It exits 2 when preflight finds a blocker (`KIT_NOT_BUILT`
while the build is missing, `KIT_BUILD_UNKNOWN` when it cannot tell, and the others), 0
otherwise, and its plan names a missing or unusable model secret or binding (agent layer
`NOT_RUN`, with the exact command that sets it up). Without `--require-agent` a missing
credential is not a blocker: a real run without one runs every layer but the agent and exits 3
at best. With `--require-agent` it is: `AGENT_NOT_RUNNABLE` names what keeps the agent layer
from running, and locally `MODEL_NOT_VERIFIED` stops a run whose **host model check** failed.
That check runs whenever the agent layer would run (locally): the installed helper makes a key
on this host (only its prefix is checked; the key is never printed, never an argument, never a
word of a traced command under `bash -x`, and never in the results), and one smallest Converse
request to each of the two pinned models must answer 200. It proves the profile, the role's
permissions and the helper from this host (`model-check.txt` records each model's HTTP code and
AWS's message, with account numbers and ARNs masked); without `--require-agent` a failure is a
warning. It runs the installed helper at its default path (`E2E_BEDROCK_HELPER` overrides it)
for the profile `bedrock` in us-east-1, while the sandbox's proxy runs whatever command the
sandbox's secret stores: store the secret with that same helper and profile, as above, or the
check proves a path the sandbox does not use. It does not prove the path
through the sandbox's proxy: a dry run creates no sandbox, and it says so (`DRY_RUN: ...
Bedrock access from inside the sandbox was NOT verified`). Only a real run's harness test3 and
agent layer verify that.

## Model credential (Amazon Bedrock)

Claude Code in the sandbox calls Amazon Bedrock with a short-term Bedrock API key that never
enters the sandbox. The kit declares the credential by service name (`bedrock`), proxy managed:
inside the sandbox `AWS_BEARER_TOKEN_BEDROCK` holds the sentinel `proxy-managed`, with which
Claude Code authenticates instead of looking for AWS credentials, and the host-side proxy sets
the `Authorization` header of every request to `bedrock-runtime.us-east-1.amazonaws.com` to
`Bearer <key>`. What the sandbox sends there is irrelevant: on the KVM test host on 2026-10-08
a request with a made-up bearer value was answered like one with the sentinel (HTTP 200). The
key is the value of a sandbox-scoped dynamic secret: sbx runs `bedrock-token.sh` on the host
when the secret is stored and again after each `--refresh` period (55 minutes, sbx's default),
and the helper prints a key that aws-bedrock-token-generator makes from the credentials of an
AWS profile - the instance role's, on an EC2 host. AWS attributes the calls to that role. On
the KVM test host, under deny-all, a Converse call and `claude -p` answered through this path
once the role had `bedrock:CallWithBearerToken`, and the full `e2e.sh --local` run passed with
it. On every run, `e2e.sh`'s platform layer checks that `AWS_BEARER_TOKEN_BEDROCK` in the
sandbox never starts like a Bedrock API key (`bedrock-api-key-` for a short-term key, `ABSK` for
a long-term one: the patterns AWS's security blog gives for the two kinds) and, with the
credential configured, is the sentinel; it records only the variable's length and those two
facts, never the value.

**Why not the built-in `claude-bedrock` agent's mechanism.** sbx 0.47.0's built-in agent
declares the `bedrock` service with `apiKey.name: AWS_PROFILE` and inject rules without a
header: the daemon resolves the stored profile name on the host, writes STS credentials to
`/home/agent/.aws/sbx-bedrock-credentials.json` inside the sandbox, and Claude Code reads them
through `awsCredentialExport`. On the KVM test host a custom kit with that same credential
shape and a `bedrock` binding got `SBX_CRED_BEDROCK_MODE=apikey` but never that file. In the
daemon's log (sbx 0.47.0, 2026-10-08), the built-in agent's sandbox got "bedrock: scheduling
STS refresher" and "bedrock: STS refresher armed"; for this kit's sandbox the daemon armed no
STS refresher and logged "sync: could not load agent artifact; using persisted gated-services
list only", with the error "artifact: spec.yaml (or spec.yml) is required: open
agents/do-agent-aws-sandbox/spec.yml: file does not exist". That is what was observed for this
kit with that version, not a documented rule. This kit does not use that mechanism, and
`test/check-descriptor.py` rejects the shape (not proxy managed, empty headers).

Once per host. The tested setup: the EC2 instance role itself carries the permissions, and
the AWS profile names no other role.

1. **IAM.** The role the AWS profile resolves to (in the tested setup, the instance role)
   needs `bedrock:CallWithBearerToken` (without it, AWS refuses every call made with the key:
   "not authorized to perform: bedrock:CallWithBearerToken", seen on the KVM test host before
   the action was added), and `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`
   on the two inference profiles the image pins and on their foundation models in every region
   the `us.` profiles route to (the scoping rule in `docs/bedrock/README.md`). A minimal
   policy, `<account-id>` being the role's account:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "InvokeThePinnedModels",
         "Effect": "Allow",
         "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
         "Resource": [
           "arn:aws:bedrock:us-east-1:<account-id>:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0",
           "arn:aws:bedrock:us-east-1:<account-id>:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0",
           "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0",
           "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"
         ]
       },
       {
         "Sid": "ShortTermBedrockApiKeys",
         "Effect": "Allow",
         "Action": "bedrock:CallWithBearerToken",
         "Resource": "*",
         "Condition": {"StringEquals": {"bedrock:bearerTokenType": "SHORT_TERM"}}
       }
     ]
   }
   ```

   `bedrock:ListInferenceProfiles` and `bedrock:GetInferenceProfile`, which the harness's own
   policy adds for model discovery, are calls to the Bedrock control plane, which the allowlist
   does not admit; Claude Code then uses the pinned IDs as they are. This policy matches AWS's
   documented condition key and value for short-term keys (`bedrock:bearerTokenType`,
   `SHORT_TERM`) and the model calls Claude Code makes, but it was not applied as written in
   the tested setup: there the instance role kept the model permissions it already had, and
   `bedrock:CallWithBearerToken` was added to it.
2. **AWS profile.** In the host's `~/.aws/config`, as tested:

   ```ini
   [profile bedrock]
   region = us-east-1
   credential_source = Ec2InstanceMetadata
   ```

   Without `role_arn`, botocore ignores `credential_source` and uses the instance role's own
   credentials from the metadata service: on the KVM test host the calls were attributed to
   the instance role's own session (`assumed-role/<instance role>/<instance id>`). To have the
   calls made as another role, add `role_arn = arn:aws:iam::<account-id>:role/<role with the
   policy above>`; botocore then takes the instance role's credentials and assumes that role. Not
   tried here. It needs `sts:AssumeRole` on that role for the instance role, and a trust
   policy on that role that trusts the instance role. A key then lasts no longer than the
   assumed session, at most 1 hour when one role assumes another, against sbx's 55-minute
   refresh; with a `duration_seconds` under 3300, sbx injects an expired key until the next
   refresh. A `role_session_name` makes these calls easy to find in CloudTrail. Either way the
   policy belongs on the role the calls are attributed to.
3. **The helper and its venv**, outside the checkout and any directory a sandbox mounts: sbx
   runs a `--command` helper as it is and requires that the helper and everything it loads
   stay outside writable sandbox mounts (`sbx secret set --help`). What it loads includes the
   venv and the AWS configuration, `~/.aws/config` and `~/.aws/credentials`: a profile's
   `credential_process` runs on this host at every refresh, so neither file may sit in a
   directory a sandbox can write. On Ubuntu, `python3 -m venv` needs the `python3-venv`
   package. Pin botocore next to the generator (the versions below are the ones the helper
   ran with), or install from a requirements file with hashes:

   ```bash
   install -d -m 0700 ~/.local/share/sbx-bedrock
   python3 -m venv ~/.local/share/sbx-bedrock/venv
   ~/.local/share/sbx-bedrock/venv/bin/pip install 'aws-bedrock-token-generator==1.1.0' 'botocore==1.43.109'
   install -m 0700 to/sandbox/bedrock-token.sh ~/.local/share/sbx-bedrock/bedrock-token.sh
   ~/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1 | cut -c1-16   # bedrock-api-key-
   ```

   The last line prints the key's prefix only. `bedrock-token.sh PROFILE REGION` prints the key
   and nothing else on stdout; when it fails it writes a reason, never the key, to stderr and
   exits non-zero, so sbx stores or refreshes nothing. It runs the venv's Python in isolated
   mode, so neither `PYTHON*` variables nor sbx's temporary working directory can put other
   code first; `SBX_BEDROCK_VENV` overrides the venv path. The installed copy does not follow
   later changes of `to/sandbox/bedrock-token.sh`: install it again.
4. **The binding**, in `~/.config/sbx/credentials.yaml` (the pre-build above creates its
   sandbox before any secret exists, so it asks nothing; an interactive `sbx create` of the
   kit after the secret is set asks once instead):

   ```yaml
   bindings:
     bedrock:
       apiKey:
         domains: [bedrock-runtime.us-east-1.amazonaws.com]
   ```

Then, per sandbox, before `e2e.sh` (which removes it after the run) or the sandbox's create:

```bash
sbx secret set bedrock --sandbox <name> \
  --command "$HOME/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1" --refresh 55m
```

The shell expands `$HOME`, so sbx stores the helper's absolute path (it runs the command from a
fresh temporary directory) and checks once that the command resolves. Sandbox-scoped secrets
take precedence over global ones (sbx docs).

**A global `bedrock` secret is not used.** For sbx's built-in `claude-bedrock` agent the global
`bedrock` secret holds an AWS profile name, and this kit's proxy would send that value as
`Bearer <profile name>`; a global key command would reach every sandbox on the host and break
the built-in agent. With only a global one, `e2e.sh` leaves the agent layer `NOT_RUN` and says
so, with the command above.

Residual risks:

- A key is valid until it expires: aws-bedrock-token-generator 1.1.0 asks for 12 hours, and a
  key stops working sooner when the credentials that signed it expire. A refresh makes a new
  key without revoking the previous one, which sbx no longer injects but which stays valid. To
  stop every key at once, deny the role both `bedrock:CallWithBearerToken` and
  `bedrock-mantle:CallWithBearerToken` (AWS: denying only the first does not stop keys at the
  Mantle endpoint; this kit's allowlist admits only the runtime endpoint), or invalidate the
  sessions that signed them (a deny on `aws:TokenIssueTime`), which affects every caller of
  those sessions.
- The sbx daemon holds the resolved key for the refresh period; the secret store holds only the
  command (on a host without a keychain, in a 0700 directory under
  `~/.config/com.docker.sandboxes`).
- Every request from the sandbox to `bedrock-runtime.us-east-1.amazonaws.com` carries the
  role's key, whichever process sends it. The allowlist admits only that endpoint (one region,
  the runtime API), so the sandbox can do there what the role's policy allows: keep the policy
  to the pinned models.
- Spend: Bedrock has no per-key spend limit, and every process in the sandbox can call the
  pinned models as the role: the agent under `bypassPermissions`, the containers it builds,
  any client that sends a request to the endpoint. Use a dedicated role, ideally in a
  dedicated AWS account (the Claude Code Bedrock docs recommend a dedicated account, to
  simplify cost tracking and access control); make an AWS Budgets alert and the account's
  Bedrock token quotas the spend bound; and give the sandbox's calls an identity of their own
  (a dedicated role, or `role_session_name` with `role_arn`) so CloudTrail tells them apart
  from other users of the instance role.
- `e2e.sh`'s teardown removes the sandbox-scoped secret first, while the sandbox still exists;
  sbx then falls back to a global `bedrock` secret if there is one (sbx docs), so for the
  seconds until the sandbox is gone the proxy would send that value (on the KVM test host a
  profile name, which AWS refuses).
- The cloud store takes no command source ("Cloud sandboxes" below).

## Cloud sandboxes

Needs a Docker Agentic Platform subscription (pay as you go) on the Docker account you sign in
with. Once:

```bash
sbx login
sbx --cloud diagnose                                    # sign-in, cloud API and entitlement must pass
```

The model credential is not refreshed in the cloud: the cloud secret commands take no `--ref`
or `--command` source (sbx docs, "Authenticate cloud agents"), so a cloud run needs a
short-term key stored as the value of a secret scoped to the sandbox, before the sandbox is
created (the cloud docs say to set a sandbox-scoped secret first), made by the helper of
"Model credential":

```bash
~/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1 | sbx --cloud secret set bedrock --sandbox <name>
```

plus the `bedrock` binding above. Not tried: whether the cloud proxy injects a kit-declared
`bedrock` service (the cloud docs list the built-in services only), and the value on stdin with
`--cloud` (`sbx secret set --help` shows stdin for local secrets). For services that are not
built in, the cloud docs give `sbx --cloud secret set-custom --host
bedrock-runtime.us-east-1.amazonaws.com --header Authorization --format 'Bearer %s'`, the
documented alternative for a first cloud attempt; it is not tried either, and `e2e.sh` looks
only for a `bedrock` service secret, so with a custom one it would not run the agent layer. The
cloud docs also describe an env file whose host command is resolved once (`snapshot: true`).
The key stops working when it expires (at most 12 hours, sooner with the credentials that
signed it), and storing it in the cloud secret store hands its custody to Docker.
`e2e.sh --name <name>` uses it and removes
it after the run; an account-wide `bedrock` secret alone is not used. The binding is a record in
this host's `~/.config/sbx/credentials.yaml`, for cloud runs too (`sbx env --help` states that
a third-party kit's credential domains must be approved by a binding).
`e2e.sh` runs the agent layer only when both the secret and the binding are present.

Between `sbx --cloud create` and `e2e.sh`'s `sbx --cloud policy init deny-all --sandbox`, the
new sandbox runs under the account's default policy. `sbx --cloud policy init deny-all`
without `--sandbox` sets that default for the whole account - every cloud sandbox of it - and,
like the per-sandbox form, keeps the existing allow and deny rules (`sbx policy init --help`).
Inspect them with `sbx --cloud policy ls`; `sbx --cloud policy reset` clears them before an
init. Both are the account owner's decision; account-level allow rules also stay in force in
the sandbox `e2e.sh` creates (its policy layer probes three hosts off the list).

From a host without KVM, a cloud run takes a pushed kit image: `sbx kit builder --help` says
`sbx` builds a kit directory in a local builder sandbox, which needs KVM (an inference from
the CLI help, not yet tried against the cloud; `e2e.sh --allow-source-kit` tries the
directory anyway). Publish the image to a registry the cloud can pull from - a **private**
Docker Hub repository of the signed-in account. Create the repository as private on Docker Hub,
`docker login`, commit, then:

```bash
DOCKERHUB_USER=<user> to/sandbox/push-kit.sh docker.io/<namespace>/do-agent-aws-sandbox:<tag>
```

`push-kit.sh` refuses to build or push unless the Docker Hub API reports the repository
private. It refuses to run under xtrace (`bash -x`, `SHELLOPTS=xtrace` or `BASH_XTRACEFD`,
which would print the token) and talks only to `https://hub.docker.com` (or a
127.0.0.1/localhost stub, for its tests). It asks anonymously first (a public repository is
refused at once), then with a personal access token read without echo, which it never prints
or passes as an argument. It renders the kit from HEAD, builds it with the pinned frontend in
the metadata-blocked builder, and pushes. It then requires that the image does **not**
resolve without credentials (it fails loudly if it does) and prints the `repo@digest` for
`e2e.sh --kit`. Its refusal paths are tested in test5.sh against a stub of the Docker Hub API
and a stub curl; the push itself has not been run (the image is about 11 GB). Optionally sign
the pushed kit:
`sbx kit sign --key cosign.key docker.io/<namespace>/do-agent-aws-sandbox:<tag>` signs with a
key and uploads nothing; keyless signing (the default) records the signing event in the public
Rekor transparency log unless `--tlog-upload=false`. Then run the end-to-end test against it:

```bash
~/.local/share/sbx-bedrock/bedrock-token.sh bedrock us-east-1 | sbx --cloud secret set bedrock --sandbox do-agent-aws-e2e-cloud
KIT_TCK=$PWD/kit-tck to/sandbox/test/e2e.sh --cloud --name do-agent-aws-e2e-cloud \
  --kit docker.io/<namespace>/do-agent-aws-sandbox:<tag>
```

Before creating anything, `e2e.sh` reads the image's digest with
`docker buildx imagetools inspect` and from then on uses only `repo@digest`, so the checks and
the create see the same artifact: `kit-tck` reads its published descriptor and staged recipe
(the recipe must be HEAD's `Dockerfile` + `template/sandbox.dockerfile`, or preflight stops
with `KIT_STALE`), and an anonymous `docker manifest inspect` must fail (`KIT_PUBLIC`
otherwise). `docker buildx imagetools` reads a private repository with the host's
`docker login`; that `kit-tck` does too is not verified here. If either cannot read the image,
preflight stops (`KIT_UNREADABLE` or `KIT_DIGEST`) and nothing is created. From a host with
KVM, `--kit` can be left out and the rendered directory is used.

## The end-to-end test

`test/e2e.sh --cloud|--local` runs these layers, each a verdict in `summary.json`:

| Layer | What it checks |
|---|---|
| preflight | tools, sbx >= 0.47.0, sign-in and `sbx diagnose`, KVM and a deny-all policy with no global allow rule (local), a free sandbox name, the kit's invariants (for an image: its digest, then its published descriptor and staged recipe against HEAD, and that it does not resolve anonymously; local, for a kit directory: that sbx has built it already, so that create does not build it, see 'Local sandboxes'), the model secret (a `bedrock` secret scoped to the sandbox; a global one alone is not used, see 'Model credential'; a failed lookup is reported as unknown) and its binding for `bedrock-runtime.us-east-1.amazonaws.com`; locally, when the agent layer would run, the host model check (helper, profile, role, both pinned models); with `--require-agent`, `AGENT_NOT_RUNNABLE` or `MODEL_NOT_VERIFIED` instead of a run without the agent |
| create | `sbx [--cloud] create` with the descriptor's `--cpus`/`--memory` (cloud: `--ttl 4h --on-timeout delete --platform linux/amd64`, the kit is amd64-only; local: `--skills off`), from `repo@digest` for an image, no workspace path, no published port |
| provenance | the sandbox's `/test*.sh` and staged kit recipe hash to HEAD's (only these are compared). Unless this layer passes too, nothing live runs |
| policy | cloud: the sandbox's policy is set to deny-all; an allowlisted host answers (401); `example.com`, `registry.npmjs.org` (in the balanced preset, not in the kit) and `api.anthropic.com` (no longer in the kit) are refused and listed as blocked by `sbx policy log`; the Bedrock runtime endpoint answers a bare GET from AWS (with AWS's `x-amzn-RequestId` header; AWS's 404, with or without a key), to curl and to Node through the proxy's TLS, its HTTP code recorded, not judged (the key itself is exercised by harness test3 and the agent layer). Unless this layer passes, nothing live runs: platform, harness, example and agent are `NOT_RUN` ("egress unverified"), the sandbox is removed and the exit is 1 |
| platform | uid 0, the sandbox's own Docker Engine, 4 CPUs (`nproc` or `cpu.max`) and 6 to 8.5 GiB (`MemTotal` or `memory.max`); `AWS_BEARER_TOKEN_BEDROCK` never starts like a Bedrock API key (`bedrock-api-key-`, short-term, or `ABSK`, long-term) and, with the model credential configured, is the sentinel `proxy-managed` (only its length and these two facts are recorded, never the value); records the proxy variable names and `NO_PROXY`. Unless that key check passes, nothing live runs after it: harness, example and agent are `NOT_RUN` ("credential isolation unverified"), the sandbox is removed and the exit is 1 |
| harness | the image's `/test*.sh` suite under bash with the repository at HEAD at `/do-agent-aws` and the `.env` settings; every test succeeds (test3 may skip only without a credential) |
| example | `example/compose-demo` in with `sbx cp`, its deterministic layer, the result copied out before the agent runs |
| agent | `claude -p` (under bash) on the same task; a fresh verifier copied in after the session judges the report against the engine's event log; the example files come back unchanged; `NOT_RUN` without a configured credential |
| stack | the platform, started after the agent layer: the sandbox is stopped and booted again (clearing what the harness layer left running), `/startup.sh` is started as the boot hook starts it, and `/agent/ui-status.sh` is polled until the supervisor is UP, the hub and the enabled spokes LIVE, conversations and issues OFF, and no row DOWN, STARTING, STUCK, NOT-SET-UP, FAILED or UNKNOWN (hindsight-seed is recorded, not judged) |
| results | `/root/workspace/out` copied out; refused, and the links removed from the host copy, if it holds a symlink |
| ttl | cloud: the TTL read back is neither stopped nor paused |
| teardown | `sbx [--cloud] rm --force` (by name, and by the id create printed) whenever create was attempted, then the name is gone from `sbx ls` (also on failure or interrupt); a sandbox never listed is watched for 3 minutes and removed if it shows up, otherwise teardown is `UNVERIFIED` |
| secret | when the run used a sandbox-scoped key: removed before the sandbox and no longer listed (a global key is never touched) |

`sbx cp` keeps symlinks, so nothing copied out of the sandbox is read on this host if it holds
one: the example, agent and results layers fail instead.

Preflight also refuses a dirty tracked tree (the run tests HEAD only; the per-call timeouts
can be raised without an edit: `E2E_T_CREATE`, `E2E_T_HARNESS`, ...), anything
credential-shaped in what it would upload (`test/credential-shapes.txt`; a scan that fails also
blocks), and a cloud TTL
shorter than the run's summed per-call timeouts (the default, 4h, covers them; a passing run
removes the sandbox itself, typically within 30 minutes; a local run took 5m21s to 6m14s in
four passing runs on the KVM test host). Every `sbx` call has a host-side
timeout, reads no terminal input (an approval prompt fails the call instead of hanging it),
runs in the background so Ctrl-C, TERM or HUP kill it at once and teardown follows, and is
logged with a UTC timestamp (`commands.log`). Teardown itself ignores those signals until it
finishes (it says so, with its upper bound), is retried once on exit unless the sandbox was
seen gone, and every path writes `summary.json`. Exit 0 (`PASS`) only when every layer passed,
the agent layer included; 3 (`PARTIAL`) when every layer that ran passed but the agent layer
did not run or the sandbox was kept; 1 (`FAIL`) when a layer failed or teardown is
`UNVERIFIED`; 2 (`BLOCKED`) when preflight stopped the run, in which case nothing was created.
`--dry-run` runs the checks that create nothing (locally, with the agent layer planned, they
include the host model check's two billed Converse requests), prints the plan and reports
`DRY_RUN` (it
does render `app/` and run `.env`, which creates `wd/agent-state/`); `--keep` leaves the
sandbox for inspection (teardown `NOT_RUN`), except when the platform layer finds the model key
at risk: that sandbox and its sandbox-scoped secret are removed all the same, and the run says so.

What a passing run shows, for that one sandbox: the harness image runs there as a workload
kit, as root, with the declared CPU and memory; its own test suite passes there; its Docker
Engine builds and tests a Compose stack inside the microVM without a published port; the three
probed off-list hosts are refused and logged as blocked, and AWS answers at the Bedrock runtime
endpoint; files move in and out with `sbx cp`; the cloud TTL is running with a future expiry;
forced removal leaves nothing listed. With the credential, also: Claude Code reaches Bedrock
with the proxy-injected key (harness test3 and the agent) while the sandbox holds only the
sentinel, and the agent's report of its task matches the engine's own record. What it does not
show: that the TTL deletes the sandbox when
it lapses (the platform's job; the test removes it first), that every other host is refused
(three are probed; account-level allow rules in cloud stay in force), the microVM's isolation
properties (Docker's claims), protection against an agent that deliberately forges the
engine's state (see `example/compose-demo/README.md`), behavior under other policies or sizes,
or reliability (one run is one sample).

Its policy log, read after the example layer, also lists what deny-all refused up to then,
none of which failed a layer. In the first local run of 2026-10-08 (the second refused the
same hosts): `api.anthropic.com` (2, one of them the policy layer's probe),
`downloads.claude.ai` (2), the Bedrock control plane `bedrock.us-east-1.amazonaws.com` (5),
Sentry and PostHog ingest hosts (3), `github.com` (13, and its DNS lookups),
`api.githubcopilot.com` (6), `mcp.context7.com` (2), `releases.astral.sh` (3),
`registry.npmjs.org` (4, one of them the probe) and `example.com` (the probe). So the agent
needs no Anthropic host, but `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` does not stop every
attempt. The allowed entry for `bedrock-runtime.us-east-1.amazonaws.com` stayed at a count of
1, the policy layer's probe, although harness test3 had called it twice before the log was
read: allowed counts are not evidence of model traffic.

## Loading a knowledge pack into a sandbox

A sandbox created from this kit carries the image's own default knowledge (the LogLearner pack it
ships, the example pack `gpu-cluster-basics`, and the `/seed` Hindsight banks). To give the sandbox agent the *same* extra
knowledge and memory a teammate's fleet harness has - a private knowledge pack such as
`example-workstreams` - deliver it into a **running** sandbox with:

```bash
to/sandbox/load-knowledge-pack.sh <sandbox-name> <pack-dir>     # --plan prints the steps, runs nothing
```

The pack stays **out of this repository** (it is private); the script is the repeatable mechanism,
the sbx counterpart of the pack's own docker-only `tools/refresh-local.sh`. Given the extracted pack
(its `pack/<name>.jsonl` + `pack/manifest.json`, `seeds/`, `tools/claude-md-block.md` and the
document tree) it verifies the manifest sha256 fail-closed, then: copies the document tree to
`/wd/knowledge/<name>` (the agent greps it; the shipped CLAUDE.md "Default knowledge" block already
sends every diagnosis to `/wd/knowledge`), ingests the LogLearner pack into the global bank
(`/agent/recall.sh` and the PreToolUse hook), seeds the `<name>` Hindsight banks (its own stamp and
state file, so the home page keeps reporting the harness's own seed), and appends the pack's
CLAUDE.md block to the sandbox WORKDIR's `/root/workspace/CLAUDE.md` - the analog of the docker
target's `/wd/CLAUDE.md` (whose `refresh-local.sh` edits it): a sandbox session, or a headless
`claude -p` fire started under `/root/workspace`, reads it as project context the
way the fleet reads `/wd/CLAUDE.md`. Re-running updates in place and
never duplicates. The Hindsight seed's memory extraction needs the sandbox's Bedrock proxy, which
the proxy-env coherence above keeps working; on a kit built before that fix landed, restart
hindsight-api under a login shell (so it sources `/etc/sandbox-persistent.sh`) before seeding.

## Known limitations

- Cloud sandboxes: `docker exec`, `docker compose exec` and Docker healthchecks can reach the
  sandbox VM's filesystem instead of the container's; the example avoids all three.
- `sbx env` and kits are experimental in sbx 0.47.0. `sbx kit validate` needs sign-in (it
  reads administrator settings), so the offline kit checks use the kit frontend and `kit-tck`
  instead. A local `sbx env plan` needs no sign-in while the local daemon runs
  (`sbx daemon start -d`; without it sbx 0.47.0 answers "not signed in"), and test1.sh then
  runs it on `sbxenv.yaml`; `sbx --cloud env plan` needs sign-in.
- The harness's web UIs are not started in a sandbox (nothing is published), and Slack,
  comms watchers and the autonomy loop stay off unless enabled for a run; their hosts are not
  in the allowlist.
- Several harness tests call stub servers on `127.0.0.1`. `e2e.sh` appends `localhost` and
  `127.0.0.1` to `NO_PROXY` for the harness suite and the agent, as `.env`'s
  `no_proxy=localhost` does for `./test.sh`, but each
  test is a new bash that re-reads `BASH_ENV`; if the sandbox's own persistent environment
  sets `NO_PROXY` without them, those requests go to the proxy and the tests fail. The harness
  log's first line shows the `NO_PROXY` a child bash sees, so a failure of this kind is
  visible in the evidence; not observed in the local runs of 2026-10-08 (a child bash saw
  `localhost` and `127.0.0.1` in both variables).
- The policy layer reads the `sbx policy log` text format the sbx docs show (a
  "Blocked requests" table, or a line naming the host as blocked or denied). If the format
  differs, the layer fails closed and `policy-log.txt` holds what was printed.
- Claude Code itself is a native binary; whether it trusts the proxy's TLS is exercised only
  when a credential is configured (harness test3 and the agent layer, which passed in the local
  runs). The Node probe covers the Node-based tools of the harness.
- An interactive `sbx run` session is unverified. Harness test12 checks only that a `claude`
  process runs in the shared tmux pane, not what it shows. sbx's built-in claude-bedrock agent
  sets an `apiKeyHelper` because, per its spec, Claude Code otherwise prompts for `/login`;
  this kit sets none, and whether its TUI starts without that prompt is untested.
