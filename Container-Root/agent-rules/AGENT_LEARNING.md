# Learning tools

Two stores of knowledge ship with this container and grow as you work: the **LogLearner knowledge bank**
(`/wd/loglearner/banks` - a curated default seed of AWS, container and agent-operations knowledge, starter
rules, and everything you bank) and the **Hindsight memory** (`http://127.0.0.1:8888` - the same seed plus
what your sessions record). Both survive container replacement.

## What arrives on its own

Before every Edit, Write and Bash call a PreToolUse hook matches the file you edit or the command you run
(docker, kubectl, `aws <service>`, git, pip, ...) against the LogLearner bank and adds the matching records to
your context, headed `Banked learnings matched to this edit|command - N of M shown`. Each record carries its
id, confidence, Status (positive = a practice that worked, negative = a dead end or trap), Provenance and
Evidence. Weigh each by its own lines: a negative is a warning, not a recipe, and the task's own instructions
win on conflict. The hook never blocks or changes a tool call, and it is quiet when nothing matches.

## Recall before a step that is expensive to get wrong

Run `/agent/recall.sh "<what you are about to do>"` and read the answer before you act:

- before a `docker build` or `docker push`: `/agent/recall.sh "docker build base image cache"`
- before a cluster change (`kubectl apply`, `helm upgrade`, `eksctl create`):
  `/agent/recall.sh "kubectl apply kubeconfig context"`
- before an IAM edit (`aws iam ...`): `/agent/recall.sh "iam policy least privilege"`, and
  `--status negative` for the known traps

It searches the bank and Hindsight; exit 0 means something matched, 1 means nothing is banked on it yet. A headless
loop fire runs it too: the shipped fire skips the permission checks, and the safe value of its options allows exactly
this script, `/agent/slack-post.sh` and `/agent/bus-answer.sh`.

## Bank what you verified - positives AND negatives

When you have verified a lesson yourself - a fix that worked, or an approach that failed and why - bank it,
one rule per record, with the evidence that proves it:

    /agent/learn.sh '{"rule": "<the lesson, one self-contained statement>",
      "evidence": "<the command and its output, a test name, an exit code>",
      "confidence": "high|med|low", "source": "<where it came from>",
      "provenance": "verified by <this session>: <how>", "status": "positive|negative",
      "tags": ["docker"]}'

Bank negatives as readily as positives: they stop the next session from repeating a failed attempt. Bank only
what you verified, never a guess. Never bank secrets, account ids, hostnames or people's names - write the rule
as if the bank were public (an entry carrying a credential-shaped string is refused). Exit 0 prints the new
`kb-NNNN` id; 2 means refused (the reasons are printed); 3 means it is already banked - bank a correction with
`"corrects": ["<id>"]` instead. `/agent/learn.sh --help` prints the full schema.

learn.sh is the only way in: the bank (`/wd/loglearner`), like the shipped default knowledge, is closed to your
Edit and Write tools and to shell writes such as `>>`, `touch`, `cp` and `tee` - every record goes through
learn.sh's gates.
