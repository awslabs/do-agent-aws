# Partner view (external partner engineer)

For an engineer outside the team who co-debugs one project and should see that project's problem-and-fix ledger and
nothing else.

1. Access is a shared SSH tunnel to the harness home page (http://localhost:8000); there is no public endpoint, and the
   operator decides which lanes you see. Ask for the Goals board of your project and the **Conversations** tile.
2. The Goals board is the ledger: one card per problem or fix, moved by the agent's loop, with the fire's result on
   the card. File a problem as a goal through the operator (`/agent/goals-add.sh`), or in the shared Slack channel when
   it is on (`docs/slack/README.md`), stating the outcome and how to check it.
3. What leaves the host is redacted and gated: the privacy scan (`/seed/scan.py`) refuses names, ids and secrets in
   anything the image ships, and outward posts wait for a human in Conversations (the Comms UI, `docs/comms/README.md`).
4. Track your problem on its card; ask in its Slack thread; the agent answers in the thread, never elsewhere.

What you should see: your project's cards and threads, redacted summaries, and no other project's data.
