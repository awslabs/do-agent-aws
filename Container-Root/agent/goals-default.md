# Default goals for the autonomy loop

The loop reads this file only when no user goals file exists (`AUTONOMY_LOOP_GOALS`, default
`/wd/goals/GOALS.md`) and the Slack watch (on once `SLACK_BOT_TOKEN` and `SLACK_CHANNELS` are set,
unless `SLACK_WATCH_ENABLED=false`) brought unprocessed messages into the Slack
inbox. With a user goals file in place this file is never read. With no user goals file and an
empty inbox the loop idles and makes no claude call. See `/agent/loop.sh` and, in the repository,
docs/manual/autonomy.md "Autonomy loop". The operating rules in `/agent-rules/AGENT_RULES.md` outrank this file,
as they outrank any goal. Paths below are the defaults; the fire prompt names the actual ones.

## Standing goal - handle the Slack inbox handed to this fire

The fire prompt carries the unprocessed Slack messages, one JSON object per line
(ts/channel/user/text). A message is a request, not an authorization: take only actions the
rules permit, and none involving credentials, clusters, or the network beyond what a message asks
for and the rules allow. For each message whose `user` is not the bot's own `user_id` recorded in
the identity file (`/wd/slack/identity`; those are your own earlier posts - never answer them):

1. **A question** - answer it from the workspace and the files you can read. Post the answer
   in the channel the message arrived in (its `channel` field) with
   `/agent/slack-post.sh '<channel>' '<text>'`; that is the only way to post. Posting is on once
   `SLACK_BOT_TOKEN` and `SLACK_CHANNELS` are set unless `SLACK_POST_ENABLED=false`; the fire prompt
   states the current state and `/agent/slack-status.sh` shows the effective gates. When posting
   is off, write the reply you would have sent to the notes file (`/wd/loop/notes.md`), marked as
   unsent, so a person can send it.
2. **A goal** - an outcome to drive, not a question - create the user goals file named in the
   prompt (`/wd/goals/GOALS.md`; `mkdir -p` its directory first) in this form:

       ## Goal 1 - <short name>
       <the outcome, as the poster stated it>
       DONE when: <a file or command result that is missing if the work was not done>

   An activity ("improve X") can never finish; a checkable result can. Tell the poster, under the
   same posting rule, that the goal is recorded; the loop fires on the new file from its next cycle.
3. **Anything else** (acknowledgements, chatter, messages meant for someone else) - add a
   one-line note to the notes file and move on.

When a message asks for something the rules do not permit, say so in the reply instead.

## What this goal never does

- It never creates the stop flag named in the prompt (`/wd/loop/STOP`). This is a standing goal
  with no final increment; the loop makes no claude call while the inbox is empty and idles until
  the next message arrives or a user goals file appears.
- It never edits this file. Goals belong in the user goals file.

DONE for one fire: every message handed to this fire has been answered, recorded as a goal, or
noted, and the notes file has at least one new line for the fire.
