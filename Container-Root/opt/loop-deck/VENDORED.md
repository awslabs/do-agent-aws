# Loop Deck - vendored release tree

This directory is the Loop Deck 1.7.1 release tree (`dmvevents/loop-deck`, public, tag `v1.7.1`),
shipped inside the image at `/opt/loop-deck` byte-identical to the release commit, so the Loop Deck tile works out of
the box, offline, for a user who cannot reach the release repository. Nothing in it is edited here: changes are made at
the source and the release is cut again (its README "Pinned source").

| | |
|---|---|
| Upstream | `https://github.com/dmvevents/loop-deck` (public; the release tree cut from the Loop Deck source), tag `v1.7.1` |
| Commit | `b3eeeecbad8c277b62f4ddfd410e9ed3e59b3e3e` (2026-11-26T10:13:27Z, "Loop Deck 1.7.1 release tree") |
| Git tree | `0da0c2c3b549449b62ab543733a989a22c96bf35` |
| Files | 21 tracked files, copied with `git archive` (no `.git`, nothing else) |
| 21-file sha256 | `eeb2fb2ffd5da886ffa8b767f72e0a402f8a4229128acf7352112ffd5595ce4c` = `cd /opt/loop-deck && find . -type f ! -name VENDORED.md ! -path '*/__pycache__/*' \| sort \| xargs -d '\n' sha256sum \| sha256sum` (this file is the only addition and is excluded from the hash, as is any Python bytecode cache a run may leave) |
| RELEASE.json | `source_sha` `4c878e19dc21c25280cbd80ac776393b01aa3794`, `source_tree` `785afbda72872aceb6be94d95c4352da93df69c5`, `deck_version` `1.7.1`, `cut_at` `2026-11-26T10:13:07Z`, features harness_mode, act_token, relative_urls |
| License | `LICENSE` is shipped alongside as the release carries it |
| Runtime | Python 3.9+ standard library only; no build step |

How the harness runs it (ui-start.sh, home-render.sh):
- harness mode only: `LOOP_DECK_MODE=harness`, `LOOP_DECK_DATA_DIR=/wd/loop-deck` - the directory `/agent/loop-deck-adapter.py`
  writes from the harness's own loops; the generator (`generate-loop-viz.py`) renders `out/` under it after every adapter
  run and probes nothing else;
- `deck-server.py --port $UI_PORT_LOOP_DECK --root /wd/loop-deck/out` bound to 127.0.0.1, behind the home proxy as
  `loop-deck.localhost` with the harness badge like every UI;
- `LOOP_DECK_ACT_TOKEN` is never set: every `POST /act` answers 403 `DENIED-ACT-DISABLED` and is audited; the page hides
  its action buttons (`GET /__act` says enabled false);
- the route rewrites one string as it serves `app/index.html`: its `<meta>` policy's `script-src 'self';` gains the
  sha256 of the home badge's keeper script (the loop-deck.localhost route's `sub_filter` in `home-render.sh`), so the
  badge the route injects keeps working there. The file on disk stays byte-identical, and `test16.sh` check 3 fails
  when a release's page no longer carries that exact text;
- `tools/check-contract.py` is the Deck's own contract validator (22 planted defects in its self-test); the adapter's
  test runs it over the adapter's output.

Refresh: `tools/vendor-loop-deck.sh <path-to-a-clone-at-the-release-commit>` from the repository root re-copies the tree,
recomputes the hash and prints the lines to update here; test-loop-deck.sh fails when the tree and this file disagree.
When a release changes the page's `<meta>` policy, update the route's `sub_filter` with it (check 3 of test16.sh names
the page it fails on).
