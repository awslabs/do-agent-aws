# Operating the fleet (owner / operator)

For the owner who runs many agent lanes alone and wants to approve, gate and report once.

1. The harness home page (http://localhost:8000 through the tunnel) is the one place to look: the Goals board, the
   agent's terminal and chat, memory and learning, Headlamp. `./status.sh` on the host and `/agent/ui-status.sh` in
   the container say what is up.
2. The autonomy loop is the agent's unattended mode: `/agent/loop-status.sh` for its state and last fire,
   `/agent/loop-stop.sh` to halt it (the STOP flag), `/agent/loop-start.sh` to resume; `/agent/loop-once.sh` fires once
   by hand. Every fire is bounded by `AUTONOMY_LOOP_FIRE_TIMEOUT` in `.env`.
3. Outward posts are gated: Slack posting is `SLACK_POST_ENABLED` in `.env`; the communication engine's drafts wait for
   a human in the **Conversations** tile (the Comms UI, `docs/comms/README.md`). Nothing is sent in your name without the gate open.
4. Credentials: the container uses an instance role or your `AWS_PROFILE` (`docs/bedrock/README.md`); scope the
   cluster access the agent inherits (docs/manual/ui.md "Harness UIs", the Headlamp paragraph) before pointing it at a cluster
   that matters.
5. Recovery: `./logs.sh` for the container's log, `./exec.sh` for a shell inside, `./stop.sh` and `./run.sh` to restart
   with the persisted state on the `/wd` volume; `./test.sh` runs the harness's own tests in a throwaway container.

What you should see: one dashboard, every lane's loop reporting on its board, and no message or change leaving the
host without a gate you opened.
