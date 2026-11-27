# Do Agent on AWS

> A self-managed agentic harness on AWS. Give it goals and it works on them autonomously on Amazon Bedrock, keeps what it
> learns in memory, and reports through a goals board and chat.

Do Agent on AWS (repository `do-agent-aws`) is a container you build and run with your own AWS credentials. You give it goals, and a loop of headless Claude Code sessions backed by Amazon Bedrock works on them autonomously and writes the code. It records what worked and what did not, and uses that knowledge in later runs. A kanban goals board and chat over Slack, Telegram or email show what it is doing and let you steer it. The harness runs in [Docker](https://www.docker.com/), [Amazon EKS](https://aws.amazon.com/eks/), or [Docker Sandboxes](https://www.docker.com/products/docker-sandboxes/), and is built with the [Do framework](https://bit.ly/do-framework).

**Disclaimer:** Do Agent on AWS is an open-source project, not an AWS service or product. It is provided "as is", use at your own risk. Work with your security and legal teams to meet your organizational security, regulatory, and compliance requirements before deployment. Security model, safe deployment, vulnerability reporting, and configuration are your responsibility: [SECURITY.md](SECURITY.md).

## Contents

- [Goals](#harness-goals)
- [Features](#features)
- [How it works](#how-it-works)
- [Quickstart](#quickstart)
- [Documentation](#documentation)
- [Security](#security)
- [Contributing](#contributing)
- [License and third-party software](#license-and-third-party-software)

## Harness goals
The harness is built around four goals:
1. Self-improvement
2. Autonomy
3. Code writing
4. Knowledge gathering

[docs/STATUS.md](docs/STATUS.md) tracks where each of these goals stands.

## Features

- **Goal-driven autonomy.** Give it goals in a goals file, on the Goals board or in Slack. A loop runs one headless Claude
  Code cycle per fire on Amazon Bedrock (observe, act, persist, stop), with a single-instance lock, a per-fire timeout and
  a stop flag.
- **Memory that persists.** A Hindsight memory store, seeded with AWS, container, Claude Code and harness knowledge, plus the
  agent's own session memory. Both survive restarts.
- **Learned rules in every tool call.** The agent records what worked and what did not, and a hook puts the matching rules
  in front of its Edit, Write and Bash calls (LogLearner).
- **Coding through pull requests.** A kanban Goals board and per-task agent workspaces take a card to a reviewed pull request.
- **One home page for every UI.** The Guide, a browser terminal on the agent's session, Memory, Session insights, Agent
  workspaces, Conversations, the Agent loop page and Files, all behind one loopback port, `127.0.0.1:8000`.
- **Channels with gates.** It watches and answers Slack, and reaches Slack, Telegram and email through the comms engine;
  posting stays off until you open its gate.
- **Spoke agents.** A supervisor runs focused spoke agents beside the hub agent, each with its own charter. The Docker
  agent builds images through a rootless BuildKit daemon and a private registry.
- **Where it runs.** Docker on one host by default, Docker Compose, Kubernetes, or a Docker Sandbox.
- **Supply-chain visibility.** Every build lists the software it installs, with licenses
  ([THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES)), and scans the image for CVEs.

## How it works

![How Do Agent on AWS works: your browser reaches the agent container's home page on 127.0.0.1:8000, Slack, Telegram and email reach its channels, its autonomy loop calls Amazon Bedrock, and the Goals board, the build substrate and the optional Plane board run beside it as sidecar containers](docs/img/how-it-works.svg)

- **The agent container** runs what you work with: the home page and its reverse proxy in front of every UI, memory and
  learning, the channels, the autonomy loop, the Docker agent, and the supervisor with its spoke agents.
- **The autonomy loop** runs headless Claude Code, one cycle per fire, on your goals, and calls Amazon Bedrock with your
  AWS credentials.
- **The sidecars** run beside it on the same host and on private networks: the Goals board (vibe-kanban server,
  PostgreSQL, Electric), the build substrate (rootless BuildKit and a private registry) and, if you turn it on, the
  Plane project board.
- **One port is published:** the home port, `127.0.0.1:8000`.

Every container, image, network and volume the scripts create: [What runs](docs/manual/install.md#what-runs).

## Quickstart

Prerequisites (`./build.sh` and `./run.sh` check them and name what is missing):

- Docker Engine with the BuildKit builder (`docker buildx`), and your user in the `docker` group.
- About 30 GB of free disk where Docker keeps its images.
- git, and AWS credentials that can call Amazon Bedrock in the region you choose.

```bash
git clone https://github.com/awslabs/do-agent-aws.git
cd do-agent-aws
export AWS_REGION=us-east-1    # a region where your account has Bedrock model access
./build.sh      # builds the image: Claude Code + plugins, the memory server, every UI; tens of minutes the first time
./run.sh        # starts the container; the ONLY published port is 127.0.0.1:8000
```

Credentials, one of two ways: on EC2 with an instance role that allows `bedrock:InvokeModel*`, set nothing; with a named
profile from `~/.aws/config`, `export AWS_PROFILE=<name>` before `./run.sh`
([AWS credentials and Amazon Bedrock](docs/manual/aws.md)).

Open `http://localhost:8000` (from another machine, run `ssh -L 8000:localhost:8000 user@host` first). The home page lists
every UI with a live status dot; the first start takes a few minutes.

Your own settings (Slack, the git identity, ports, which UIs run) go in `.env.local`, which `git pull` never touches.
`./test.sh` runs the test suite, `./exec.sh` opens the agent's tmux session, and `./stop.sh` removes the containers and
keeps all state under `wd/`.

The prerequisites in full, the first start and every script: [Installing and running](docs/manual/install.md).

## Documentation

| Topic | Page |
|---|---|
| Installing, running and configuring; the setup doctor; persistent state | [Installing and running](docs/manual/install.md) |
| AWS credentials, Secrets Manager and Amazon Bedrock | [AWS credentials and Amazon Bedrock](docs/manual/aws.md) |
| Memory, learned rules and moving knowledge between harnesses | [Memory and learning](docs/manual/memory.md) |
| How the agent works on goals by itself | [The autonomy loop](docs/manual/autonomy.md) |
| Slack and the comms engine's channels | [Slack and other channels](docs/manual/channels.md) |
| The home page and every UI behind it | [The harness UIs](docs/manual/ui.md) |
| The supervisor, the spoke agents and the Docker agent | [Spoke agents and the Docker agent](docs/manual/agents.md) |
| The Goals board, the Plane project board and the Board page | [The boards](docs/manual/boards.md) |
| The software bill of materials and the CVE scan | [Software bill of materials and CVE scan](docs/manual/supply-chain.md) |
| Who uses it, with a quickstart for each | [docs/PERSONAS.md](docs/PERSONAS.md) |
| What a person must be able to do, as checks that can fail | [docs/NORTH-STAR.md](docs/NORTH-STAR.md) |
| The hub agent, the supervisor and the spokes | [docs/AGENT-STACK.md](docs/AGENT-STACK.md) |
| How the agents talk, and the journal of their messages | [docs/INTER-AGENT-MESSAGING.md](docs/INTER-AGENT-MESSAGING.md) |
| From a card to a reviewed pull request | [docs/guides/kanban-coding.md](docs/guides/kanban-coding.md) |
| Running it in a Docker Sandbox | [to/sandbox/README.md](to/sandbox/README.md) |

The manual's index is [docs/manual/README.md](docs/manual/README.md). A running harness serves the manual on its home page,
under `/guide/manual/`.

## Security

[SECURITY.md](SECURITY.md) has the security model, safe deployment, how to report a vulnerability, and who is responsible
for each kind of finding. Report a security issue through the
[AWS vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/), not in a public issue.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). This project has adopted the [Amazon Open Source Code of Conduct](CODE_OF_CONDUCT.md).

## License and third-party software

This project is licensed under the Apache-2.0 License ([LICENSE](LICENSE), [NOTICE](NOTICE)).

Third-party code kept in this repository (LogLearner and its example knowledge pack gpu-cluster-basics, Loop Deck, tmux-agent
and the issues tracker), each project with its own license and copyright notices, is attributed in [THIRD-PARTY](THIRD-PARTY).
[THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES) lists every third-party component the container image installs, each with its
license; `./build.sh` writes it from the image after every build.

Claude Code is not part of this repository: the image build installs it from npm, and its use is subject to Anthropic's
commercial terms (https://www.anthropic.com/legal/commercial-terms). The image also installs software under proprietary
licenses that other packages bring, such as the NVIDIA CUDA libraries that PyTorch, a dependency of the memory API, installs;
[THIRD-PARTY-LICENSES](THIRD-PARTY-LICENSES) lists each with its license.

Although this repository is released under the Apache-2.0 license, it depends on third-party packages that are installed or
retrieved at install time, build time, or run time. These packages are licensed under their own terms, which you must accept to
use them. Some of these licenses may be restricted by your company's open source policy, so please review them before
proceeding.

The list below reflects the licenses identified in each package's documentation as of Amazon's most recent review. It is
provided for convenience only and may not be complete or current; please check each package's download site for the latest
licensing information.

* Plane (https://github.com/makeplane/plane): AGPL-3.0. Optional and off by default (`UI_PLANE=false`); its upstream images
  are pulled at run time when you turn the board on.
* pgsty/silo (https://github.com/pgsty/silo), a fork of MinIO published as the `pgsty/minio` image: AGPL-3.0. Plane's object
  store, pulled only with Plane.
