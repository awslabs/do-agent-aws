# Install your own (colleague installing the harness)

For the colleague who wants this running on their own machine today.

1. Prerequisites: Docker with buildx, about 20 GB of disk, and AWS credentials with Bedrock model access
   (`docs/bedrock/README.md`). `./build.sh` checks docker, buildx and disk before it starts (`test-preflight.sh`).
2. Credentials two ways: on EC2 with an instance role set nothing; on a laptop set `AWS_PROFILE` in `.env.local` (your
   settings; `.env` keeps the defaults) to a profile with Bedrock access. Never put a key in either file.
3. Build and run: `./build.sh` (the image, from public sources), `./run.sh` (the container with the `/wd` volume and
   every UI on), `./status.sh`. Open the home page through the tunnel: `ssh -L 8000:localhost:8000 <host>` then
   http://localhost:8000 - or http://localhost:8000 directly on your own machine.
4. The doctor: `./exec.sh` gives you a shell inside, where `/agent/doctor.sh` checks Bedrock, git, a cluster, Slack,
   GitHub, memory and the dashboards and prints, for each gap, the lines to run on the host and how to verify them;
   `/agent/ui-status.sh` says which UI answers, `/agent/agent-status.sh`
   what the agent did last, `/agent/slack-status.sh` whether Slack is wired. `./test.sh` runs the whole suite in a
   throwaway container when something looks off.
5. Common traps: a `.env` flag off (`UI_*=false`) greys its tile and says so on the home page; a Bedrock model without
   access shows on the Memory tile's note after the seed (`/agent/hindsight-seed.sh --status`); the first board load after
   a start takes up to half a minute.

What you should see: `./status.sh` reporting the container up, the home page with every tile green, and a goal you add
with `/agent/goals-add.sh` worked by the loop.
