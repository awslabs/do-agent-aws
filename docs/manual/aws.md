# AWS credentials and Amazon Bedrock

How the harness gets AWS credentials and reaches Amazon Bedrock. Part of the [Do Agent on AWS manual](README.md).

Contents:

- [AWS credentials](#aws-credentials)
- [Credentials from AWS Secrets Manager](#credentials-from-aws-secrets-manager)
- [Bedrock connectivity](#bedrock-connectivity)

## AWS credentials

The container uses Amazon Bedrock for Claude Code (`CLAUDE_CODE_USE_BEDROCK=1`), so `claude -p "<prompt>"` runs
headless when AWS credentials are available. `run.sh` passes `AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_PROFILE`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, and `AWS_BEARER_TOKEN_BEDROCK` from the host
environment when set, and mounts `~/.aws` into the container when present - at `/home/agent/.aws` for Claude Code and
the agent scripts; the unprivileged user the hindsight memory API runs as gets its own copy of that directory at
container start (`/agent/hindsight-aws-config.sh`) - with `AWS_PROFILE` set, boto3 looks the profile up under that
user's home, and the API's extraction calls would otherwise fail with "config profile could not be found" while
`claude` worked; the copy is taken at each container start, so a rotated static key or an SSO re-login reaches the
memory API after a restart. On EC2, the instance role is picked up automatically through IMDS with no additional
configuration - when the container is one network hop from the instance (the default bridge; the IMDSv2 hop limit
of 2 that [docs/bedrock/README.md](../bedrock/README.md) describes). A harness running inside nested Docker
(docker-in-docker, a sandbox's own engine) is one hop further and cannot reach IMDS at that limit: raise the
instance's hop limit by one more (`--http-put-response-hop-limit 3`) or pass `AWS_*` variables into `./run.sh`'s
environment. The compose template passes the same variables through, and the kubernetes deployment reads them
from an optional secret named `<app>-aws-credentials`. The model settings of `.env` ride along the same way:
`AGENT_MODEL`, `AGENT_EFFORT`, `AGENT_MODEL_OPUS` and `AGENT_MODEL_FABLE` reach the container as `ANTHROPIC_MODEL`,
`CLAUDE_CODE_EFFORT_LEVEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL` and `ANTHROPIC_DEFAULT_FABLE_MODEL`, each only when set (see
"Bedrock connectivity").

## Credentials from AWS Secrets Manager

The third-party credentials the harness uses - the Slack bot token, a GitHub token, the comms engine's tokens and
passwords, the Telegram bot token, a Bedrock API key - belong in **one AWS Secrets Manager secret**, which the container
reads at every start. They then never pass through a `docker run -e` (visible to anyone who can run `docker inspect` on
the host), never sit in `.env.local` or a shell history, are encrypted with a KMS key of their own, and every read is in
CloudTrail. The AWS credentials themselves (the instance role, `~/.aws`, the `AWS_*` variables of "AWS credentials") stay
where they are: they are what reads the secret.

**1. Create the secret, its key and the read policy** with `aws/agent-secrets.yaml` (CloudFormation). The secret is
created **empty**; `ReaderRoleName` attaches the read-only policy to the role the container runs as (an EC2 instance
role, for one) - leave it empty and attach the `ReadPolicyArn` output to your role or user yourself:

```bash
aws cloudformation deploy --template-file aws/agent-secrets.yaml --stack-name do-agent-aws-secrets \
  --capabilities CAPABILITY_IAM --parameter-overrides ReaderRoleName=<your-instance-role>
```

The key has rotation on and can be used only through Secrets Manager; the policy allows `GetSecretValue` and
`DescribeSecret` on that one secret over TLS and `kms:Decrypt` through Secrets Manager, nothing else.

**2. Put the value**: one JSON object whose keys are the environment variable names the harness reads. Typed in without
an echo, it reaches the CLI on stdin, never on a command line or in a file:

```bash
python3 -c 'import getpass, json; print(json.dumps({n: getpass.getpass(n + ": ") for n in ("SLACK_BOT_TOKEN", "GH_TOKEN")}))' \
  | aws secretsmanager put-secret-value --secret-id do-agent-aws/credentials --secret-string file:///dev/stdin
```

**3. Point the container at it** in `.env.local`: `export AGENT_SECRETS_ID=do-agent-aws/credentials` (a name or an ARN;
`AGENT_SECRETS_REGION` when it is not in `AWS_REGION`), then `./stop.sh && ./run.sh`.

What happens at start (`/agent/secrets-load.sh`, sourced by `/startup.sh` before anything else runs): the secret is read
with the container's AWS credentials, and only the names in `AGENT_SECRETS_NAMES` are taken from it - by default
`SLACK_BOT_TOKEN SLACK_APP_TOKEN GH_TOKEN GITHUB_TOKEN AWS_BEARER_TOKEN_BEDROCK HINDSIGHT_API_LLM_API_KEY TMUX_AGENT_SRC
TELEGRAM_BOT_TOKEN IMAP_HOST IMAP_USERNAME IMAP_PASSWORD`, plus every name in `COMMS_ENV_NAMES`. Names that steer
processes (`PATH`, `LD_*`, `BASH_ENV`, `PYTHON*`, ...) and the bootstrap AWS credentials are refused even when listed;
other keys in the secret are only counted. The values are exported to the processes the start launches - the tmux
session, the UIs, the loop, the watchers - and, for shells and scripts started with `docker exec`, kept in an owner-only
`0600` file on the container's memory-backed `/dev/shm` (`/agent/secrets-env.sh` reads it; `doctor.sh`, `slack-gates.sh`
and `loop-start.sh` source it). They are never printed, and never written to the image, `/wd` or the agent state; the
start log names what was loaded. A secret that cannot be read (no permission, no such secret) is one `ERROR` line and
the start goes on without it. A rotated value is read at the next `./stop.sh && ./run.sh`.

**Without a secret** the same names still work as environment variables (exported in the host shell before `./run.sh`,
for a quick local trial), and each credential among them - a secret-named variable (`*TOKEN*`, `*PASSWORD*`, `*SECRET*`,
`*API_KEY*`, ...) or a source URL that carries a token - gets a `WARNING: secrets: <NAME> comes from the container
environment` line at start: the documented place for a credential is the secret. On compose, `AGENT_SECRETS_ID`, `AGENT_SECRETS_REGION` and
`AGENT_SECRETS_NAMES` are in the template's `environment:` list; on kubernetes they are in the deployment's `env:`, and the
pod's role (EKS Pod Identity or IRSA) needs the read policy. The Docker Sandboxes target reaches only the model API and
Docker Hub, so it does not read a secret (its Bedrock key comes from the host's proxy, "Docker Sandboxes").

Every text the agent posts to Slack is masked before it is sent (`/agent/redact.py`, the board mirror's rules: the
values of secret-named settings, the mounted AWS credentials and common token shapes), and a text that cannot be masked
is not posted.

## Bedrock connectivity

Claude Code inside the container talks to Amazon Bedrock (`CLAUDE_CODE_USE_BEDROCK=1` is baked into the
image), so connecting the agent to Bedrock is an AWS-side task: enable Anthropic model access in your
region (Claude Fable 5.1, the shipped model, and Claude Opus 5.5 - "The model" below) and give the container an
identity allowed to invoke the models. The recommended path on EC2 is an
**instance role / instance profile** - credentials arrive through IMDS and the container works with no
keys at all. What the role needs is the policy in
[docs/bedrock/bedrock-agent-policy.json](../bedrock/bedrock-agent-policy.json): required are
`bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` over the foundation-model *and*
inference-profile ARNs (Claude Code uses cross-region inference profiles such as `us.anthropic.claude-...`
by default, and a foundation-model-only policy breaks them); `bedrock:ListInferenceProfiles` and
`bedrock:GetInferenceProfile` are recommended for model discovery. Alternatives - a named profile / SSO
via the mounted `~/.aws`, an Amazon Bedrock API key in `AWS_BEARER_TOKEN_BEDROCK`, or explicit key
variables - ride the passthrough described in "AWS credentials" above. On kubernetes, prefer IRSA or EKS
Pod Identity (the same role-not-keys path); the optional `<app>-aws-credentials` secret remains for
key-based setups. Verify with `./test.sh` - the unit tests start with a headless `claude -p` preflight
against Bedrock and say clearly when credentials are missing. Setup (model access, the required-vs-optional
permission breakdown, the inference-profile scoping trap, the IMDSv2 hop-limit gotcha for bridge-network
containers) is documented in [docs/bedrock/README.md](../bedrock/README.md).

**The model.** The model the container calls (on the docker, compose and kubernetes targets; `TO=sandbox` keeps its kit's
pinned model, [to/sandbox](../../to/sandbox/README.md)) is `AGENT_MODEL` in `.env`, shipped as Claude Fable 5.1 through the `us.`
cross-region inference profile with the `[1m]` suffix, `us.anthropic.claude-fable-5-1[1m]` - the suffix is Claude Code's
request for the 1M-token context window ([Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock),
"1M token context window": for a pinned model id, append `[1m]`). `AGENT_EFFORT`, shipped `max`, is the effort level of
every session, passed as `CLAUDE_CODE_EFFORT_LEVEL` (the deepest reasoning level; the variable outranks `/effort` and a
saved level, and is the one way `max` applies beyond a single session). `AGENT_MODEL_OPUS` and `AGENT_MODEL_FABLE` give
the `opus` and `fable` aliases their ids (`ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_FABLE_MODEL`): what a
sub-agent, a `/model` pick or an alias in `AGENT_MODEL` names, and the id Claude Code's default follows when `AGENT_MODEL` is
empty (the `opus` one; measured). The prerequisite is model access to Claude Fable 5.1 (and Claude Opus 5.5 for the alias) in `AWS_REGION`,
requested once per account and region in the Bedrock console ([docs/bedrock/README.md](../bedrock/README.md), step 1).
An account without it sets `AGENT_MODEL` in `.env.local` to an id it can call - `us.anthropic.claude-opus-5-5[1m]`
keeps the 1M window - or empty, which passes nothing and leaves Claude Code its own Bedrock default
(`us.anthropic.claude-opus-5-5[1m]` for the Claude Code in this image; the doctor names it). The settings are the
environment Claude Code reads, deliberately not an `ENV` of the image nor the `env` block of the agent's
`settings.json`: a model pinned in `settings.json` overrides every run, and the sandbox kit's build
([to/sandbox](../../to/sandbox/README.md)) refuses an image whose environment or settings set `ANTHROPIC_MODEL`. The doctor's
`bedrock` row shows the model in effect, where it comes from and the context window, and probes Bedrock with the id
without the suffix, which is not part of the Bedrock model id.

When the memory stays empty: the default seed is accepted by the memory API at once (the stamp records that)
and the memories are extracted afterwards, with Bedrock. If nothing has been extracted three minutes after
the seed, the seed names the cause it finds in the memory API's log (`/wd/ui/hindsight-api.log`: no
credentials, an unknown profile, no model access, an expired token) in `/wd/ui/hindsight-seed.log` and in the
container's own log (`docker logs <container>`), the home page's Hindsight tile shows it in red under the live
document and pending counts,
and `/agent/ui-status.sh` reports `hindsight-seed: FAILED` and exits 1. Fix the credentials or the model
access and `./stop.sh && ./run.sh`: the queued extraction resumes on its own.
