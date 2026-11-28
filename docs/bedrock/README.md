# Connecting the agent to Amazon Bedrock

This document walks through connecting do-agent-aws to Amazon Bedrock: enabling model access,
granting the required IAM permissions, choosing how the container gets credentials, and verifying
the path end to end. The container is already wired for Bedrock - `CLAUDE_CODE_USE_BEDROCK=1` is
baked into the image - so everything below happens on the AWS side.

Two principles up front:

* **Prefer a role over keys.** On EC2 an instance role / instance profile delivers credentials
  through IMDS and the container just works - nothing to configure, rotate, or leak. Keys and
  bearer tokens are the fallback for hosts that are not on AWS.
* **The policy ships as documentation, not automation.** Nothing in this project creates or
  attaches IAM resources; you attach the policy below to whatever identity the container runs
  as - instance role, IRSA/Pod Identity role, or IAM user.

## 1. Enable model access

Model access is granted **per AWS account, per region**. In the
[Amazon Bedrock console](https://console.aws.amazon.com/bedrock/) open the **Model catalog**,
select the Anthropic Claude models the container calls, and submit the use case form - access is
granted immediately after submission. The container calls Claude Fable 5.1, the shipped `AGENT_MODEL`
of `.env` (docs/manual/aws.md "Bedrock connectivity"), and Claude Opus 5.5, which the `opus` alias resolves to
and which Claude Code falls back on when `AGENT_MODEL` is empty. Do this in the region the container
will use: Claude Code resolves its region from `AWS_REGION`, then `AWS_DEFAULT_REGION`, then the
active AWS profile, then falls back to `us-east-1`, and a region where access was never enabled fails
at invoke time.

The shipped model id, `us.anthropic.claude-fable-5-1[1m]`, carries Claude Code's `[1m]` suffix - its
request for the 1M-token context window ([Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock),
"1M token context window"). The Bedrock model id has no suffix: the setup doctor's probe and a direct
`aws bedrock-runtime converse` take `us.anthropic.claude-fable-5-1`.

## 2. Grant the required IAM permissions

Attach [bedrock-agent-policy.json](bedrock-agent-policy.json) to the identity the container runs
as. It is the policy documented for Claude Code on Amazon Bedrock
([IAM configuration](https://code.claude.com/docs/en/amazon-bedrock#iam-configuration)):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowModelAndInferenceProfileAccess",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": [
        "arn:aws:bedrock:*:*:inference-profile/*",
        "arn:aws:bedrock:*:*:application-inference-profile/*",
        "arn:aws:bedrock:*:*:foundation-model/*"
      ]
    },
    {
      "Sid": "AllowMarketplaceSubscription",
      "Effect": "Allow",
      "Action": [
        "aws-marketplace:ViewSubscriptions",
        "aws-marketplace:Subscribe"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:CalledViaLast": "bedrock.amazonaws.com"
        }
      }
    }
  ]
}
```

What each part is for - required vs optional:

* `bedrock:InvokeModel` + `bedrock:InvokeModelWithResponseStream` - **required**. Every model
  call the agent makes is one of these two; streaming is Claude Code's normal request path.
* `bedrock:ListInferenceProfiles` - optional but recommended. Lets Claude Code discover which
  cross-region inference profiles the account actually has and resolve model IDs against them;
  without it the region prefix (`us.`, `eu.`, ...) is applied blind and a missing profile
  surfaces as a 400 at request time.
* `bedrock:GetInferenceProfile` - optional. Only matters when models are pinned to application
  inference profile ARNs; it resolves the ARN to its backing model. Without it requests still
  succeed, at the cost of one extra retry round-trip per new model.
* The `AllowMarketplaceSubscription` statement - optional. Needed only if this same identity
  will enable model access itself (step 1) rather than a human doing it once from the console;
  drop it if access is already enabled.

**The inference-profile scoping trap.** The policy above uses wildcards, which is why it works
for the cross-region profile IDs Claude Code uses by default (`us.anthropic.claude-...`). If you
tighten `Resource` to specific ARNs, you must list **both** the inference-profile ARN **and** the
underlying foundation-model ARN in *every region the profile routes to* - per the
[Bedrock prerequisites for inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-prereq.html):
"When you specify an inference profile in the `Resource` field ..., you must also specify the
foundation model in each Region associated with it." A foundation-model-only policy breaks
`us.anthropic.*` model IDs with an access-denied error even though the model itself is allowed.

## 3. Give the container credentials

### Recommended: EC2 instance role / instance profile

Attach the policy to the instance role and run the container - credentials arrive through IMDS
and no variable, file, or key is needed. This is the path the project's own test runs use.

One gotcha: the container runs on the default docker bridge network (`NETWORK=` in `.env`), which
adds a network hop between the container and IMDS. If the instance keeps the default IMDSv2 hop
limit of 1, credential lookups inside the container time out. Raise it to 2 once per instance:

```bash
aws ec2 modify-instance-metadata-options --instance-id <instance-id> --http-put-response-hop-limit 2
```

One hop more for nested Docker: a harness running inside docker-in-docker or a sandbox's own engine is two
hops from IMDS, so a limit of 2 is not enough there - raise it to 3 (`--http-put-response-hop-limit 3`) or pass
`AWS_*` variables into `./run.sh`'s environment instead. Without either, `claude` and the memory API see no
credentials at all (observed on a docker-in-docker host).

### Alternatives

All of these ride the passthrough described in the docs/manual/aws.md "AWS credentials" section - `run.sh`
passes the variables from the host environment only when set, and never echoes secret values:

* **Named profile / SSO** - `~/.aws` is mounted into the container (`VOL_MAP` in `.env`); set
  `AWS_PROFILE` on the host.
* **Amazon Bedrock API key** - export `AWS_BEARER_TOKEN_BEDROCK` on the host; simpler than full
  AWS credentials where a key-style secret is acceptable.
* **Explicit keys** - export `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`
  on the host.

## 4. Kubernetes

Prefer [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
or [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) - the
same role-not-keys path as the instance profile: attach the policy to the pod's role and the SDK
credential chain picks it up with nothing stored in the cluster. For key-based setups the
deployment template reads an optional secret named `<app>-aws-credentials` (see the comment in
`to/kubernetes/template/020-deployment.yaml`).

## 5. Verify

```bash
./test.sh
```

The in-container unit tests begin the loop test (`test3.sh`) with a headless Bedrock preflight -
`claude -p "Reply with exactly: OK"` - and say clearly when the Bedrock path is not working
("headless claude preflight failed (no Bedrock credentials?)") rather than failing silently.
For a direct probe, open a shell with `./exec.sh` and run `claude -p "hello"`, or check what the
identity can see with `aws bedrock list-inference-profiles --region <region>`. `/agent/doctor.sh
--check bedrock` shows the model in effect, where it comes from and the context window, and makes
the one-token call with the id Bedrock knows (docs/manual/install.md "Setup doctor").

## Sources

* [Claude Code on Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock) - IAM
  configuration, region resolution, model pinning
* [Amazon Bedrock: prerequisites for inference profiles](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-prereq.html) -
  the both-ARNs scoping requirement
* [Identity and access management for Amazon Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/security-iam.html)
