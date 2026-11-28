# Fresh-deploy proof

A driver that proves a pushed branch the way a new user meets it, on a **separate Docker host that has never
seen the image**: clean `git clone` of the pushed commit, `./build.sh`, `./run.sh`, every home tile fetched
through `127.0.0.1:8000` and followed like a browser, the neighbour-container exposure controls, the whole
`./test.sh`, the seed counts after extraction, persistence across `./stop.sh && ./run.sh`. Every output is an
evidence file (`<PROOF_DIR>/evidence/NN-*.txt` on the proof host, pulled back by `collect`).

It touches only what it made: the clone under `PROOF_DIR`, the harness container `do-agent-aws` of that clone,
and containers/networks named `ado-proof-*`. Anything else on the proof host is left alone - a container named
`do-agent-aws` whose mounts are not this clone's is refused, never removed.

## Requirements

- Driving host: this checkout, `git`, `gh` (logged in; the pushed sha is compared with GitHub's), `ssh`, `scp`.
- Proof host (`PROOF_HOST`): passwordless `ssh`, `sudo -n`, Docker, `git`, `tmux`, `curl`, `python3`; AWS
  credentials that reach Bedrock in the environment `PROOF_AWS_ENV` names (an instance role needs only the region).

## Settings

| variable | default | meaning |
|---|---|---|
| `PROOF_HOST` | required | ssh destination of the proof host |
| `PROOF_DIR` | `~/ado-proof` | directory on the proof host (`do-agent-aws/` clone, `evidence/`) |
| `PROOF_BRANCH` | the checkout's branch | the pushed branch to prove |
| `PROOF_REPO` | from `origin` | `owner/name` on GitHub |
| `PROOF_AWS_ENV` | `AWS_REGION=us-east-1` | environment prefix for `./build.sh`, `./run.sh`, `./test.sh` on the proof host |
| `PROOF_IMAGE` | `do-agent-aws:latest` | the image `./build.sh` produces (the `.env` default) |

## A full run

```
export PROOF_HOST=<host> PROOF_AWS_ENV="AWS_PROFILE=<profile> AWS_REGION=us-east-1"
tools/fresh-deploy-proof/proof.sh archive <previous run number>   # keep the previous evidence (never deleted)
tools/fresh-deploy-proof/proof.sh bundle                          # stops the previous run's harness, re-clones, checks the sha
tools/fresh-deploy-proof/proof.sh build                           # ./build.sh in tmux on the proof host
tools/fresh-deploy-proof/proof.sh build-control                   # optional: the build must FAIL with an impossible build arg
tools/fresh-deploy-proof/run-all.sh                               # waits for the build, runs every step, stops at the first failure
```

`run-all.sh` ends with the two rc files that decide the run:
```
20-run-rc.txt:  rc=0 <timestamp>
32-test-rc.txt: rc=0 <timestamp>
PROOF OK (run rc 0, test rc 0)
```
Anything else is a failed proof - the step's own output names what went wrong. The steps are individually
runnable (`proof.sh <step>`; the header of `proof.sh` lists them) for a re-check of one property.

## Evidence files

| file | content |
|---|---|
| `00-clone.txt` | clone sha, pushed sha, bundle name |
| `10`-`12` | build start, log, rc; `13`/`14` the build-arg control |
| `20`-`24` | run rc and log, `ui-status`, home page, every tile followed (browser-like chains), greyed tiles |
| `25` | Host allowlist and dot probes |
| `26`-`29` | neighbour on the bridge, on a user-defined network, on a custom-gateway network; the route move |
| `27b` | LogLearner pages, projects, the running server's index path, persisted projects - before and after `./test.sh` |
| `30`-`33` | test start, log, rc, verdict lines |
| `34`-`36` | the user's `wd/` listing before and after `./test.sh`, the LogLearner index's content, the comparison |
| `40`-`41` | seed status and per-bank stats |
| `50`-`57` | persistence: banks before and after `./stop.sh && ./run.sh`, UI status, seed view, volumes |

## Why the guard in `bundle`

A re-clone over the previous run's clone while its container is still up takes the container's `/wd` away (home
page 404), the new `./run.sh` fails on the container name, and the driver goes on measuring the orphan. `bundle` now runs the previous clone's `./stop.sh`, removes a leftover container only
when `docker container inspect` shows its mounts under this clone, and refuses otherwise; `run` fails its step
when `./run.sh` fails; `run-all.sh` stops at the first failed step.
