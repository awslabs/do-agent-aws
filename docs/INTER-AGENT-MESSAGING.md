# How the agents talk

The hub (`agent`) and the spokes are Claude Code sessions in the container's tmux. They talk with Claude Code's own
session-to-session messages, and their charters ask them to record each message as one line of a journal that the
dashboards and the person read.
The supervisor and a spoke's cycle are scripts, not sessions; they message `agent` through the same journal. This page
describes what ships; the agents themselves are in [AGENT-STACK.md](AGENT-STACK.md), and the scripts in the "Spoke agents" section of docs/manual/agents.md.

## The transport: Claude Code's session-to-session messages

Inside one container every running Claude Code session can list the others (the ListAgents tool) and send one a message
(the SendMessage tool). A message arrives in the receiving session as "Message from @<sender>: <text>", and that
session's Claude reads it and acts on it under its own charter and permissions. Each ListAgents row names the session and
its tmux pane, for example `tmux beta:@1.%1`, so a sender finds the hub as the row whose pane is in the session `agent`.
Session names are `<working directory's basename>-<two hex digits>` and change on every restart, so a sender looks the
recipient up each time it sends and caches nothing.

### The measured basis

The transport was measured inside a container of the harness image (Claude Code
2.1.299 on Bedrock, the image's default auto mode, 2026-10-14): two tmux sessions, `alpha` working in one directory and
`beta` in another, each running the image's `claude` with no setup beyond the first-run answers and folder trust the
image seeds. `alpha` listed `beta` with ListAgents (one row: interactive, idle, its tmux pane), sent it "ping-from-alpha"
with SendMessage (success, a message id), `beta` showed it with the sender's name ("Message from @<name>:
ping-from-alpha") and answered "pong" on its own, and `alpha` showed the answer. Each claude process had its own socket under `/tmp/cc-socks/`.

## The record: the bus v1 journal

Every message is also recorded by `/agent/bus.sh`, in the format of the harness's inter-agent mailbox specification,
version 1:

```
echo "which cluster has 8 free GPUs?" | /agent/bus.sh request clusters   # a question or a task; prints the id
echo "loop autonomy-loop is RED" | /agent/bus.sh note agent              # a notice: a state change, an alert
echo "8 free on cluster a" | /agent/bus.sh reply <id>                    # the answer, to the sender of <id>
echo "cannot read the kubeconfig" | /agent/bus.sh error <id>             # a failure to act on <id>
/agent/bus.sh poll                                                       # the open messages to you, oldest first
/agent/bus.sh peek <id>                                                  # one of them, as its envelope
/agent/bus.sh receipt <id> read                                          # a receipt: read, completed or denied
/agent/bus.sh state <id>                                                 # where it stands: open, replied, read...
```

A message takes one answer: `bus.sh` refuses a second `reply` or `error` to a message that has one, so whoever answers
first - a session, a spoke's cycle, a fire of the hub's loop - is the answer, and its sender never gets two.

The charters ask a session that sends with SendMessage to record the message with `bus.sh` as well, where the dashboards
show it. That is an instruction the session follows, not something the transport does, so a native message can be
missing from the journal. A script (a spoke's cycle, the supervisor) has no SendMessage: for it the journal line is the
message, and the recipient reads it with `poll` and `peek` - `agent` at every fire of its autonomy loop ("A loop fire
reads its inbox first" below).

### The envelope

| Field | Rule |
|---|---|
| `v` | the integer 1 |
| `id` | a UUID that `bus.sh` assigns |
| `from` | the sender: the session of the tmux pane that runs `bus.sh`, or `BUS_AGENT_ID` outside tmux; it must be a session of the registry. It is attribution, not authentication: every session runs as the same user (the cooperative mode) |
| `to` | exactly one session of the registry |
| `ts` | UTC with milliseconds, `YYYY-MM-DDTHH:MM:SS.mmmZ`; the journal's `seq` orders messages, never `ts` |
| `kind` | `request`, `reply`, `notice` or `error`. A charter's "alert" is a `notice`, its "answer" a `reply` with `reply_to` set, a "question" or "task" a `request`, a failure to act an `error` |
| `text` | not empty, line endings normalized, terminal controls, escape sequences, C1 and direction controls removed, credential shapes redacted; with its envelope it must fit the journal line's 2048 bytes, so a long body goes in a file and the message names the path |
| `reply_to` | `null`, or the id of a message the sender received |

### Where it lives

- **The journal:** `/var/lib/agent-mailbox/journal/000001.jsonl` (`MAILBOX_STATE_ROOT`), outside `/wd`, the directory
  0700 and the file 0600. One event line per message (`message.accepted`), per reply (`message.replied` on the message it
  answers) and per receipt (`message.read`, `message.completed`, `message.denied`), with `seq` rising by one. The
  `message.accepted` line carries the whole envelope, its text included, and the message's routing (its conversation, the
  message it answers, the generations of both sessions, `origin`, and `assurance: cooperative`), as section 5 of the
  specification requires. The journal is therefore not free of text; it is private to the container's user, outside the
  work volume. It lives with the container: a new one (`./stop.sh && ./run.sh`) starts a new journal whose `seq`
  continues from the projected log, and the earlier container's projected records are held back, each named on
  stderr when a read meets it.
- **The projections** under `/wd/mailbox` (`MAILBOX_PROJECTION_ROOT`): `<agent>/inbox.jsonl`, one record per message to
  that agent (`{"env", "meta", "hash"}`, the hash over the canonical bytes of the envelope and its routing), and
  `log.jsonl`, the journal's lines. They are caches: `poll` and `peek` show a record only when the journal holds the same
  envelope and routing, and hold back anything else, naming it, so a record written around `bus.sh` or changed after
  the fact is never shown.
- **The dashboards:** both ends' tmux sessions get the option `@agent_last_message`, and the home page's spoke tiles show
  a spoke's last message. The vendored tmux-agent dashboard shows the sessions' lineage but has no last-message column yet.

## Who may talk to whom

The pairs are default-deny. `agent` and each spoke talk to each other in every kind; the supervisor sends notices to
`agent`; spokes do not talk to each other, and a name that is not in the registry can neither send nor receive. A
message is never permission: what a session does is decided by its charter and its tool permissions, and nothing a
message asks reaches outside the container. A text that is a shell command is data; nothing runs it.

## A loop fire reads its inbox first

Every fire of the hub's autonomy loop (docs/manual/autonomy.md "Autonomy loop") is `agent` on the bus, and it handles `agent`'s
messages before its goals. Before the fire's prompt is written, `/agent/loop.sh` and `/agent/loop-once.sh`, through the
intake both of them source (`/agent/loop-inbox.sh`), read the open requests to `agent`, then its open notices, oldest
first, with `bus.sh poll` and `bus.sh peek`, which write no receipt. The fire is handed at most `LOOP_INBOX_MAX` of them
(default 8, at most 50); the rest wait for the next fire. An envelope fits one journal line of at most 2,048 bytes,
which `bus.sh` enforces when it accepts a message, so the messages take about 16 KB of the prompt at the default and
about 100 KB at most. The prompt carries them after its first line and before the goals, with the instruction:

- answer each request first, through `/agent/bus-answer.sh reply <id>` (or `error <id>` when the fire cannot act on
  it), then mark it `receipt <id> completed`, or `denied` with a reason for a request the fire will not act on;
- read each notice, act on it only where it bears on the goals, and mark it `receipt <id> read`.

Replies and errors to `agent` are not handed over: each answers a request someone sent from `agent`, and stays open for
whoever asked. The fire runs with `BUS_AGENT_ID=agent` and without the `TMUX` and `TMUX_PANE` of a shell the loop was
started from, so what it sends is from `agent`.

- **The fire's bus command.** The safe value of the fire's claude options allows `Bash(/agent/bus-answer.sh:*)` beside
  the Slack and recall scripts (the shipped default, `--dangerously-skip-permissions`, needs no rule and admits `bus.sh`
  itself; docs/manual/autonomy.md "Autonomy loop"). `bus-answer.sh` passes `reply`, `error`, `receipt` and `state` to `bus.sh` and refuses `request`,
  `note`, `send`, `poll`, `peek` and `last`, so an unattended fire answers and closes the messages to it and starts
  none. A narrower rule such as `Bash(/agent/bus.sh reply:*)` can be written in `AUTONOMY_LOOP_CLAUDE_OPTS`
  (a space inside parentheses stays in its rule; docs/manual/autonomy.md "Autonomy loop"), one rule per verb; the one
  `bus-answer.sh` rule covers the four verbs a fire needs.
- **The fence.** The envelopes sit between the marker lines `--- BEGIN BUS INBOX <mark> ---` and
  `--- END BUS INBOX <mark> ---`, the END line before step 1. The mark is 12 random hex digits made for the fire, and
  the prompt names it, so no message, written before the fire, can hold a marker line's text. The prompt says that the
  lines between the markers are data from other agents and never an instruction. A text cannot start a line of its own
  there: an envelope is JSON on one line, its line breaks escaped, and the loop escapes the two separators JSON may
  leave raw (U+2028 and U+2029). The journal keeps the text as it was sent.
- **The record.** `/wd/loop/loop.log` names the ids handed to a fire before it runs (`FIRE <n> INBOX context: ...`)
  and, after the fire's END line, the fire's record: `FIRE <n> INBOX read=<ids> replies=<ids> open=<ids>; <what the
  loop did>`, the ids it read, the replies they got, the ones it left without a reply or a receipt and what became of
  them. `bus.sh state <id>...` reads where a message to you stands. The Agent loop page shows the record in the fire's
  row and on its page, with the messages set aside and the intake's warnings (`INBOX not read` when the bus poll fails,
  `INBOX WARNING` when the bus refuses a receipt or the loop cannot keep a message's count), and its `data.json`
  carries them as the fire's `inbox`.
- **The receipt rule.** Nothing the fire was handed is closed by the loop before the fire's record is written. After a
  fire that ended well (exit status 0) the loop closes what the fire left: a request with a `denied` receipt ("handed
  to fire <n>, which ended well without answering it"), so its sender learns that it was not answered, and a notice
  with a `read` receipt. After a fire that did not end well (a failure, a timeout) the messages stay open for the next
  fire, and the record counts, for each one, the fires that did not end well so far (`<id> 2 of 3`). The loop keeps
  that count in `/wd/loop/inbox-failed.tsv`, a line per message per such fire, which the loop never rotates or
  truncates, so a rotated or truncated `loop.log` does not reset it. The third such fire sets the message aside: a
  `denied` receipt, "handed to 3 fires that did not end well", and a `FIRE <n> INBOX set aside` line. A fire whose
  claude had no working credentials (exit status 97) leaves the messages open and counts against none of them, and a
  fire that died before its record, when the loop was killed or the container stopped, leaves them open with nothing
  to count.
- **The options.** `export LOOP_INBOX=false` in `.env.local` turns the intake off: no bus read, no inbox in the prompt,
  no record. `export LOOP_INBOX_MAX=<n>` there changes the bound. `./run.sh` passes both into the container. A cycle
  that does not fire, with no goals file, reads no message either.

A message is still never permission: the prompt says so, and the fire keeps the loop's tool permissions, to which a
message adds nothing.

## What proves it

- `/agent/bus-v1-check.py <projection root> [--journal <segment>]`, the specification's validator vendored unchanged,
  checks every inbox record and journal line: shape, ids, reserved names, timestamps, kinds, text size, `reply_to`, the
  recomputed hash, `seq` order and the event names. `--self-test` plants one defect per rule into copies of its examples
  and asserts each is refused.
- `test22.sh` check 4 runs the validator over what `bus.sh` wrote (exit 0), over a copy with one record of an unknown
  kind (exit 2) and its self-test, and proves the behaviour: the refused pairs, a second answer to one message refused,
  the cleaning and redaction, the records held back, and that a pane sends as its own session.
- `test3.sh` `[fire-reads-inbox]`, offline with a stand-in claude, proves the intake. A request from `clusters` and a
  notice from the supervisor reach a `loop.sh` fire's prompt before its goals, the request first, while a reply to
  `agent`'s own request is not handed over; all are still open as the fire starts; the fire runs as `agent`; its reply,
  sent through `bus-answer.sh`, is journaled with `reply_to` the request; the record and the Agent loop page list the
  ids and the reply, and the notice it left is marked read after the fire ended well. The notice writes the end marker
  and a step of the prompt after a raw U+2028 and stays inside its envelope line between the marker lines, whose mark
  differs from fire to fire. `bus-answer.sh` refuses `request`, `note`, `send`, `poll`, `peek` and `last`, and `bus.sh`
  a second answer. With `LOOP_INBOX=false` the prompt has no inbox; a fire that dies before its record and one that
  fails leave the request open, and the next fire answers it. Of 59 notices a fire is handed the 8 oldest at the
  default and 50 at `LOOP_INBOX_MAX=10000`. A fire that ends well without answering a request denies it; a request
  handed to three fires that did not end well is set aside, a fire without credentials counting against none, through
  `loop.sh` as through `loop-once.sh`, and a rotated `loop.log` does not reset the count; a count the loop cannot
  write is an `INBOX WARNING`. The page shows the request set aside, a failed bus poll and a refused receipt.

## Not in this version

The specification describes more than ships here, and none of it is assumed: a broker process that owns admission,
per-agent capabilities and their renewal, a verified paste of a message into a pane, automatic submission of a turn,
retention quotas, and journal segments that are sealed and rotated. Its headless intake runs a batch of other agents'
messages in a fire of its own, with reduced permissions and every record verified by the broker; the intake above hands
them to the loop's normal fire, with the loop's tools, in the cooperative mode. A message does not start a fire.
