# compose-demo: the harness builds, runs and tests a Compose stack inside a Docker Sandbox

**Status, 2026-10-08: both layers pass in a local Docker Sandbox; not run in a cloud
sandbox.** In both local end-to-end runs of 2026-10-08
(`to/sandbox/test/e2e.sh --local`, `docs/STATUS.md`), layer 1 passed 5/5 inside the sandbox and
the agent's layer-2 report passed the verifier, with Claude Code on Amazon Bedrock. Layer 1
also runs on plain Docker and in the sandbox image as a container (`to/sandbox/test/test3.sh`,
`test4.sh`).

A Docker Sandbox runs the agent in a microVM, and the microVM is the security
boundary, so the agent can have a Docker Engine of its own: it builds images,
starts containers and runs Compose stacks inside the VM, and no host Docker
socket is exposed. This example shows that with the do-agent-aws harness, in
two layers.

The stack is self-contained in this folder and depends on no other repository:

| File | Role |
|---|---|
| `compose.yaml` | two services, `web` and `tests`; no `ports:`, no healthcheck |
| `Dockerfile` | `public.ecr.aws/ubuntu/ubuntu:22.04` pinned by digest (the harness's own base) plus `app/` |
| `app/server.pl` | HTTP service, Perl core modules only: `/health`, `/sum`, 404 otherwise |
| `app/check.pl` | the stack's tests, run as the `tests` container's main process |
| `run-deterministic.sh` | layer 1, no model |
| `agent-task.md` | layer 2, the headless prompt template |
| `verify-agent-report.py` | layer 2, the verifier |

The image build downloads nothing beyond the base image, so the only network
the stack needs is Amazon ECR Public. `/health` returns the container hostname as
`instance_id`; Docker sets it to the short container id, which lets a reader
of `/health` be matched to the container that served it.

The web service attests the test run through its own exit status: on stop it
exits 0 only if it has answered each request `check.pl` makes
(`%CHECK_REQUESTS` in `server.pl`) with the expected status, and 3 otherwise.
Docker's event log records that exit status, so a run in which the tests never
reached the service cannot pass, whatever a report says.

## Layer 1 - deterministic, no model

`run-deterministic.sh RESULT_JSON [PROJECT]` runs, against whatever Docker
Engine `docker` talks to:

1. `docker compose config`: the stack publishes no port (fails otherwise);
2. `docker compose --profile test build`, then `docker compose up --build -d web`,
   and the web container is running;
3. `GET /health` from inside, with no published port - from the shell to the
   web container's IP, or, where that address is not routable from the shell,
   from a one-off container on the project network (the result records which);
4. the `instance_id` it returns is the web container's hostname;
5. `docker compose run --rm -T tests`: all 5 checks pass, for that instance;
6. `docker compose down --volumes --remove-orphans`, and no container of the
   project is left;
7. the engine's event log shows the web container exiting 0 on that stop (it
   served every check request) and every `tests` container of the project
   exiting 0.

It writes `RESULT_JSON` (status, failed step, engine and compose versions,
health answer and probe path, test counts), a log and the event records beside
it, and exits 0 only when every step passed. On a plain Docker Engine host:

```bash
to/sandbox/example/compose-demo/run-deterministic.sh wd/compose-demo/deterministic.json
```

In a sandbox, `to/sandbox/test/e2e.sh` copies this folder in with `sbx cp`,
runs the same script through `sbx exec`, and copies the result out before the
agent layer starts.

**A PASS would show:** the sandbox's own engine builds an image, runs a Compose stack and
runs its tests, and its event log confirms the tests reached the service; the
service is reachable from inside without any published port; the sandbox
network policy admits the ECR Public pull the build needs; the files went in
and the results came out with `sbx cp`.
**It would not show:** anything about the model or the agent; isolation
properties of the microVM (those are Docker's claims, see
docs.docker.com/ai/sandboxes/security/); behavior of stacks that need
healthchecks or `docker exec` (avoided on purpose, see Limitations).

## Layer 2 - the agent

The harness's agent, Claude Code, gets the same task as a headless prompt:
`agent-task.md` with a fresh nonce, the project name `compose-demo-agent` and
the report path filled in, run as
`claude -p "<prompt>" --permission-mode bypassPermissions` inside the sandbox.
Success is never judged from the model's reply. The agent must write a report
file, and `verify-agent-report.py` checks it against the Docker Engine's own
record:

- the report carries this run's nonce, health `ok`, 5 passed / 0 failed,
  0 published ports and `compose_down: true`, with the right types;
- the engine's event log since the session started shows a `web` container of
  the project whose id starts with the reported `instance_id`, which exited 0
  when stopped (so it served every check request), and `tests` containers of
  the project, every one of which exited 0;
- no container of the project is left, and the shipped stack publishes no port.

`e2e.sh` copies a fresh copy of the verifier in only after the agent session,
to a path the prompt never named, runs it, requires its exit status 0 and a
PASS verdict, and copies the example folder back out to check on the host that
every shipped file is unchanged.

This layer needs the operator's model credential: a `bedrock` secret scoped to
the sandbox in the sbx secret store, a command that makes a short-term Amazon
Bedrock API key on the host, plus an approved binding for
`bedrock-runtime.us-east-1.amazonaws.com` (`to/sandbox/README.md`, "Model
credential"). When no usable credential is configured, `e2e.sh` records the
layer as `NOT_RUN` with the reason and does not count it as a failure.

**A PASS would show:** the harness's agent, driven headless inside the sandbox, completed
a build-run-test-teardown task end to end through the sandbox's engine and
network policy, and its report agrees with the engine's own record.
**It would not show:** that the agent is reliable (one run is one sample), output
quality beyond the checked fields, or anything about other prompts. The
verifier runs inside the sandbox the agent controlled as root, so it catches a
wrong, partial or invented report, not an agent that deliberately forges the
engine's state. It does not show that the agent itself read `/health` (the
instance id is also visible through `docker ps`), nor which ports the agent's
own commands published (only the shipped compose file is checked).

## Requirements the example declares

The example runs inside the harness sandbox, so its requirements are part of
the harness kit descriptor (`to/sandbox/template/do-agent-aws-sandbox.yaml`),
the sandbox's permission request:

- compute: `resources@1` 4 CPU / 8 GiB (the cloud `medium` shape), which `e2e.sh`
  also passes as `--cpus`/`--memory` at create;
- network allowlist (`network-policy@1`; the whole egress under a
  deny-by-default policy): `bedrock-runtime.us-east-1.amazonaws.com` for the
  model (Amazon Bedrock), and `public.ecr.aws` and
  `d2glxqk2uabbnd.cloudfront.net` (the blob redirect observed from AWS) for
  the ECR Public pull of the base image;
- secrets by name only (`credential@1`): service `bedrock`, a short-term
  Bedrock API key injected by the sandbox proxy as `Authorization: Bearer` for
  `bedrock-runtime.us-east-1.amazonaws.com`; the value stays on the host.

## Limitations

- In cloud sandboxes `docker exec`, `docker compose exec` and Docker
  healthchecks can reach the sandbox VM filesystem instead of the container's
  (docs.docker.com/ai/sandboxes/cloud/usage/ "Known limitations"). The stack
  therefore has no healthcheck, the tests wait for readiness themselves, and
  every check runs as a container's main process.
- The base image is pinned by digest; anonymous ECR Public pulls are subject
  to its rate limits for unauthenticated clients.
