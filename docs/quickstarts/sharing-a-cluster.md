# Sharing a cluster (GPU cluster co-tenant)

For the person who asks "can I use the cluster now without breaking someone's run?" The harness shows the cluster; the
reservation itself is your fleet's own tooling (a lock, a queue), so this guide covers what the harness gives you.

1. Open the home page through the SSH tunnel (`ssh -L 8000:localhost:8000 <host>`, then http://localhost:8000) and the
   **Headlamp** tile. Headlamp reads the kubeconfig the container has (`/home/agent/.kube/config`, or the instance role);
   with no cluster yet, add one from the **tmux terminal** tile: `aws eks update-kubeconfig --name <cluster>`.
2. In Headlamp, Workloads -> Pods: filter by namespace to see who runs what; the node pages show GPU requests per node.
   Requested GPUs are not GPUs in use: a pod that requests 8 GPUs holds them whether or not its process is busy.
3. Before you start anything, check `./status.sh` on the host (the harness's own state) and your fleet's lock or
   queue; when a run is yours to stop, do it from the terminal with `kubectl`, never from Headlamp's delete buttons on
   someone else's namespace.
4. Leave the cluster as you found it: your pods deleted, your lock released, and a line in the shared channel if the
   harness's Slack is on (`/agent/slack-status.sh` shows whether it is).

What you should see: Headlamp's cluster overview and pod lists for the cluster you added; nothing changes on the
cluster until you act in the terminal.
