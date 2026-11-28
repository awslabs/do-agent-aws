# Example spoke - the vendored tree

The repository of the `example` spoke (`charter.md` beside this file), shipped in the image at `/agent/charters/example`.
A spoke's checkout is `repo` in its working directory (`/wd/example/repo`); for a vendored source like this one it is a
link to the tree in the image, so a new image brings the new tree with it.

`cycle.sh` is the spoke's loop: one cycle writes the time of the cycle to `status.txt` in the spoke's directory and
answers each request in its inbox with that time, through `/agent/bus.sh`. It spends no model tokens, which is why this
spoke can prove the scaffold on a fresh harness: `SPOKE_EXAMPLE=true` in `.env.local`, then `./stop.sh && ./run.sh`.
