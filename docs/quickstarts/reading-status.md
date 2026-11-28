# Reading status (manager / leader)

For the person who asks "what moved this week, and what is the impact?" without running anything.

1. Open the **Goals board** tile on the harness home page: Done is what landed, In progress is being worked, To do is
   the queue; each card's description ends with the agent's own account of its last fire (result, duration, what
   changed).
2. "Done" on the board means the goal's check passed - a file or a command result the goal named - not that a change
   was merged. A code change is merged only when its pull request is; the card's description says where the change is.
3. The completion status of the harness itself against its goals is `docs/STATUS.md`; who it serves and what each needs
   is `docs/PERSONAS.md`.
4. For a periodic digest, ask the operator to add the goal: `/agent/goals-add.sh "Write the weekly digest to
   /wd/reports/week.md - DONE when it lists every goal closed this week"`; the loop writes it where the goal says.

What you should see: the board's columns as the week's status, and a short written account per goal.
