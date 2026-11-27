# Security

## Reporting a vulnerability

If you discover a potential security issue in this project, notify AWS/Amazon Security through the
[vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/). Please do **not** open a public
issue.

## Security model

* **One operator, one host.** Every harness UI, the writable terminal into the agent container included, is served
  through one home port that `./run.sh` publishes on `127.0.0.1` only (`UI_BIND_HOST`). The UIs have no login of their
  own: reach them from another machine through an SSH tunnel (`ssh -L 8000:127.0.0.1:8000 <host>`) or
  `kubectl port-forward`, never through a wider publish.
* **The home proxy is fail-closed.** It admits loopback, the container network's gateway and the addresses or CIDRs
  listed in `UI_HOME_ALLOW_FROM` (never `/0`), and it answers only localhost names and `UI_HOME_HOSTNAMES` (421
  otherwise), so a neighbour container or a DNS-rebinding page is refused. Every route refuses with 403 a request whose
  `Origin` names another site than the host it was sent to, and the browser terminal (ttyd) checks the `Origin` of its
  websocket itself, so a web page open in the same browser cannot drive the terminal or post to a UI.
* **No internet exposure.** Do not publish the home port on a public interface. The Kubernetes Ingress and autoscaler are
  not applied unless you opt in (`KUBERNETES_INGRESS`, `KUBERNETES_HPA`); never route the Ingress to the internet. Remote
  access beyond a tunnel needs an authenticating proxy in front of the home port.
* **The agent acts on what it reads.** Claude Code runs inside the agent container, as its unprivileged `agent` user
  (docs/manual/install.md "Container user"), and reads content from
  Slack, email, issues and web pages. Treat that content as untrusted input: give the container credentials scoped to
  what it must do (for Amazon Bedrock, model invocation), in an account that holds no production data, and keep a person
  reviewing what it does. Its unattended calls (the autonomy loop's fires, the Slack chat responder) run with a short
  allowlist of the harness's own scripts by default; the permission bypass `--dangerously-skip-permissions` is an
  explicit opt-in in `.env.local` (docs/manual/autonomy.md "Autonomy loop"). Only the people `SLACK_ALLOWED_USERS` names can drive the
  agent through Slack (empty, the default, admits no one), and other bots' messages are never read.
* **Credentials live in AWS Secrets Manager.** The container reads its third-party credentials (Slack, GitHub, the
  comms engine, Telegram, a Bedrock API key) from one KMS-encrypted secret at start (`AGENT_SECRETS_ID`;
  `aws/agent-secrets.yaml` creates the secret, its key and a read-only policy - docs/manual/aws.md "Credentials from AWS
  Secrets Manager"). Values are never printed or written to the image, `/wd` or the agent state. Credentials passed
  as environment variables still work for a local trial, with a warning naming each; never put one in `.env` or a
  committed file.
* **What the agent posts is masked.** Every Slack message is passed through the same redaction as the board mirror
  (values of secret-named settings, mounted AWS credentials, common token shapes) before it is sent.
* **What the host runs is read-only inside.** The checkout (`/do-agent-aws`), `~/.aws` and `~/.kube` are mounted
  read-only, so a command in the container cannot change what a host script, a `credential_process` or a kubeconfig
  `exec` plugin runs next; no process in the container gains privileges through a setuid binary (`no-new-privileges`
  on every target). To change the harness, the agent works in a clone under `/wd/projects` and you review the branch.
* **What the build installs is pinned.** The base image is an Ubuntu LTS image from Amazon ECR Public, by digest; uv, Bun,
  nvm's installer, BuildKit's client, swagger-ui and the ttyd fallback are pinned releases checked against their
  sha256; npm and Claude Code are pinned versions; vendored releases are kept byte for byte (`VENDORED.md`); the Goals
  board's image builds on its upstream Dockerfile's base images from ECR Public by digest, and its two sidecar images are
  pinned by digest (`KANBAN_BUILD_BASES`, `KANBAN_POSTGRES_IMAGE`, `KANBAN_ELECTRIC_IMAGE`); a CVE scan gates every build
  on fixable CRITICAL findings.

## Threat model

Trust boundaries:

| # | Boundary | Controls |
|---|---|---|
| B1 | Operator's browser -> home proxy (127.0.0.1) | Loopback-only publish; source and Host allowlists (403, 421); a Content-Security-Policy on every page |
| B2 | Host -> agent container | Credentials from Secrets Manager (or the environment, with a warning); the `agent` user |
| B3 | Agent (the model) -> tools | Unprivileged user; read-only gh and kubectl allowlists in the spokes; the cluster lock broker; Slack gates; redaction before posting; the main session is bounded by the credentials and RBAC you give it |
| B4 | Container -> AWS | Amazon Bedrock with your or the instance's credentials; nothing written to the image |
| B5 | Container -> SaaS (Slack, IMAP, GitHub, Telegram, registries) | Off unless configured; token URLs never written to `.env` |
| B6 | Container <-> sidecars | Segmented networks, no route out for the databases and the stack's registry; rootless BuildKit, no `docker.sock` |
| B7 | Cluster ingress (kubernetes target) | ClusterIP service; the Ingress only on opt-in; the proxy refuses ingress traffic until `UI_HOME_ALLOW_FROM` and `UI_HOME_HOSTNAMES` open it |
| B8 | Other web pages in your browser -> home proxy | The same-origin gate on every route (403 for a foreign `Origin`); ttyd's own origin check on the terminal's websocket |
| B9 | Channel members and bots -> the agent's inbox | `SLACK_ALLOWED_USERS` (empty admits no one); other bots' messages never read; the safe permission values for unattended calls |
| B10 | Agent container -> files the host runs | The checkout, `~/.aws` and `~/.kube` read-only; `no-new-privileges` |

Threats:

| ID | Threat | Mitigation | Residual risk |
|---|---|---|---|
| T1 | Someone else reaches the UIs (terminal, memory API) | B1; tests prove that neighbour containers and foreign Hosts are refused | The UIs have no login: anyone with host access or the tunnel has control (single-operator tool) |
| T2 | The Kubernetes Ingress opened to a wide network | Off by default (`KUBERNETES_INGRESS`); the proxy refuses ingress traffic | Put an authenticating proxy in front before opening it |
| T3 | Prompt injection (Slack, email, issues, web pages) makes the agent run harmful commands or leak data | Unprivileged user; safe permission values for unattended calls; read-only spoke wrappers; gated watchers; redaction | Inherent to agents: scope credentials to Bedrock invocation and read-only access, use an account without production data, keep a person reviewing |
| T4 | Secrets leak into logs, posts, the repository or its history | Secrets Manager; tested redaction; secret scanners clean; history fixtures verified synthetic | Low |
| T5 | Vulnerable or compromised dependencies | Pinned images and tools (T14); lockfiles; SBOM; CVE gate | A prebuilt release binary can carry a CVE that is fixed upstream until the tool's next release; moving the pin takes it ("Open findings") |
| T6 | Container breakout or host impact | Unprivileged user; no `docker.sock`; rootless BuildKit; loopback publish; seccomp RuntimeDefault on Kubernetes; B10 | The Docker Sandboxes target runs root inside its microVM by design |
| T7 | Resource exhaustion by crafted input | Upload caps, request budgets, patched parsers | Local impact only |
| T8 | Data at rest on the host (`wd/`, volumes) | Bind mounts under your checkout | Encrypt the disk; delete `wd/` and the volumes when done |
| T9 | No audit trail of agent actions | Session ledger, fire transcripts, message journal | Local files; ship them to central logging beyond one operator |
| T10 | Markup in a transcript runs as script in the LogLearner dashboard | The route's Content-Security-Policy admits only the dashboard's own scripts (by sha256) | Low; fixed upstream when the vendored release is |
| T11 | A web page you visit drives the terminal or posts to a UI (cross-site WebSocket hijacking, CSRF) | B8 (`test-origin-gate.sh`, `test9.sh` check 7d) | Low |
| T12 | A channel member or another bot makes the agent run commands | B9 (`test-slack-senders.sh`) | With the opt-in bypass, each named person has the container's authority |
| T13 | A command in the container plants code the host runs (`.env.local`, `credential_process`, kube `exec`) | B10 (`test-mounts.sh`) | Low; the writable token caches hold data, which the host never runs |
| T14 | A tampered download at build time (an installer piped into a shell, a moving base image) | Base images by digest (the agent's and the Goals board's, and the board's sidecars); pinned, checksum-verified releases; pinned npm and Claude Code | apt packages (signed by Ubuntu) and npm lockfile installs are trusted at their pinned versions; the AWS CLI (AWS's installer over HTTPS), the memory API's Python dependencies and the official Claude plugin marketplace resolve at build time (each build's versions are in `THIRD-PARTY-LICENSES`, scanned by the CVE gate); the opt-in Plane board's images are pinned by release tag |
| T15 | A prompt-injected agent reads the secrets in its environment and sends them out | Secrets Manager with names-only logging; masked posts; tokens with the least scope | Every process of the container can read the secrets it was given, and the docker target has no egress filter: use scoped tokens, and the sandbox target (deny-by-default egress) or VPC egress filtering for untrusted inputs |
| T16 | More exposure on Kubernetes than intended (Ingress, extra replicas, privilege) | Ingress and autoscaler opt-in; the pod runs as uid 1000 with no privilege escalation, no capabilities, RuntimeDefault seccomp | Low |
| T17 | Third-party code in the image misbehaves (vendored releases, plugins installed at build, MCP servers) | Pinned versions and provenance (`VENDORED.md`); Agent Tool Checker scan of the shipped MCP servers; the CVE gate | Plugins from individual maintainers are trusted at their pinned versions, not audited line by line |

## Open findings and who is responsible for each

Scanners report findings against this repository, its image and the software the image installs. That list changes with
every scan, so this file names no version, CVE identifier, line number or date: run the scans below for what is open today. What
stays true is who is responsible for each class of finding.

**See today's findings**

* **The image:** `./scan.sh` (docs/manual/supply-chain.md "CVE scan") scans the image just built and writes its report under `./cve/`. Every
  build also writes `THIRD-PARTY-LICENSES`, the list of what the image installs with each component's version and license.
* **The source:** run your own static analysis and secret scanning over the checkout; `./test.sh` proves this project's own
  controls.
* **Where to report one:** a finding in a vendored project or in an installed tool is that project's to fix, so report it
  there. This repository does not patch what it ships unchanged.

**Responsibility by class of finding**

`upstream:<name>` is the project, distributor or publisher that owns the code or the release; `this-repo` is this
repository's maintainers; `operator` is you.

```csv
class,where it is,flaw fixed by,fix taken by,how to see it
vendored third-party code,Container-Root/opt/<project>/ (each has a VENDORED.md),upstream:<project>,"this-repo, by importing the project's next release; the tree is never patched here",static analysis of the source
pinned tool binaries and installers,the install scripts under Container-Root/setup/,upstream:<tool>,"this-repo, by moving the pin (checked against the release's checksum) once a release carries the fix; you can move it in your clone between releases",./scan.sh and THIRD-PARTY-LICENSES
operating-system and language packages,"resolved at build (apt, npm, pip)",upstream:<distribution or package maintainer>,a rebuild takes the current packages,./scan.sh and THIRD-PARTY-LICENSES
base and sidecar container images,the Dockerfile and .env,upstream:<image publisher>,"this-repo, by refreshing the digest pins",a scanner of your choice over each image
"this repository's own code, scripts, tests and docs",everything outside the classes above,this-repo,"this-repo, with a test",./test.sh and your own scans
scanner hits that are not in the tree,"an earlier commit's history (a public example value, for instance)",this-repo,nothing in the tree to fix; only scanners that read old commits show it,secret scanners that read git history
third-party services you connect,"AWS, Slack, GitHub, Telegram, mail",upstream:<service provider>,"operator, for the tokens and the scopes you grant",the provider's console and audit log
your configuration and where you run it,".env.local, mounts, credentials, host, network",operator,operator,the section below
```

## Your configuration is your responsibility

The defaults of this project are chosen for one operator on one host, and its tests (`./test.sh`) prove them. **Every
configuration you set, change or add is yours to secure.** That includes, without being limited to:

* **Who can reach the UIs:** `UI_BIND_HOST`, `UI_HOME_ALLOW_FROM`, `UI_HOME_HOSTNAMES`, any tunnel, port-forward or proxy
  you put in front of the home port, and the Kubernetes Ingress you opt into.
* **Who can drive the agent:** `SLACK_ALLOWED_USERS` (`anyone` admits every person in the watched channels), the
  permission bypass you opt into in `.env.local`, and everyone with access to the terminal.
* **What the agent can do:** the AWS credentials, IAM roles and Bedrock access you give the container; the Slack, GitHub,
  Telegram and mail tokens and the scopes you grant them; who can read the secret in AWS Secrets Manager; the cluster
  credentials and RBAC you mount.
* **What the container can touch:** every mount or volume you add (the harness mounts the checkout, `~/.aws` and `~/.kube`
  read-only) and the files under `wd/`.
* **What you enable:** the optional components (the Plane board, the board relay, the spokes), the plugins, skills and MCP
  servers you install, and every third-party service they connect to.
* **Where it runs:** the host, the network, the AWS account, patching, disk encryption, egress control, logging and
  monitoring, and keeping production data and production credentials out of the agent's reach.

The maintainers do not secure, monitor or support your deployment, and nothing here guarantees that a configuration of
yours is secure. Review what you configure against your own organization's security, legal and compliance requirements
before you rely on it.

## Disclaimer

This is sample code, for non-production usage. You should work with your security and legal teams to meet your
organizational security, regulatory and compliance requirements before deployment.
