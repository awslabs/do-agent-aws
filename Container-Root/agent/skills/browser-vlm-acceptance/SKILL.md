---
name: browser-vlm-acceptance
description: Acceptance-test a web UI with REAL browser emulation plus a visual-LLM pass — playwright/Chromium drives the pages, console+DOM asserts prove behavior machine-checkably, and Claude READS the screenshots (multimodal Read tool) to judge that it actually looks right. Use whenever a card/gate says "verify the UI renders", "visual confirm", "test the dashboard/panel/plugin in the browser", "did the frontend really work", or before closing any UI-facing issue on visual claims. Also fires when choosing browser tooling (playwright vs lightpanda) or when someone asks "do you really test things / what's your acceptance criteria".
---

# Browser + visual-LLM acceptance testing

Never close a UI card on "the endpoint returns 200". Acceptance = three layers, each with
different failure modes it alone can catch:

1. **Behavior (console/network)** — the app's own logs prove registration/boot. Example that
   settled a real dispute: Headlamp silently DISABLES incompatible plugins; only the console
   shows `registerRoute ok` / `Incompatible plugins disabled` — no screenshot or curl can.
2. **Content (DOM asserts, machine-checkable)** — `inner_text` regex/equality against the
   SERVED data, not constants. Assert ARITHMETIC, not presence: a totals check that
   recomputes sums from the served JSON and equality-checks the rendered line catches drift
   that a presence check would bless.
3. **Looks (the vision pass)** — screenshot PNGs, then READ them (Claude is the visual LLM;
   the Read tool renders images). This is what catches layout truth the DOM can't: e.g. the
   sidebar entry existed in DOM but only rendered on the HOME sidebar, not cluster views.

## Tool choice (install them where you run the check)
- **playwright + Chromium** (`python3 -c 'import playwright'`; browsers in
  `<path>`) — THE tool for visual acceptance: real rendering, screenshots,
  console capture, form fill/click. Use for React/MUI apps (Headlamp, Plane).
- **lightpanda** (`<path>`) — text/markdown DUMPS of pages (11× faster,
  no pixels). Use for READING content, never for visual acceptance.

## The loop (copy-paste skeleton)
```python
from playwright.sync_api import sync_playwright
logs=[]
with sync_playwright() as p:
    b=p.chromium.launch(); pg=b.new_page(viewport={'width':1500,'height':950})
    pg.on('console', lambda m: logs.append(m.text))          # layer 1
    pg.goto(URL, wait_until='networkidle', timeout=45000)
    pg.wait_for_timeout(2500)                                # SPA settle
    body=pg.inner_text('body')                               # layer 2
    pg.screenshot(path='shot.png', full_page=True)           # layer 3 input
    pg.fill('#msg','...'); pg.click('button')                # interactions too
```
Then `Read shot.png` and WRITE DOWN what you see vs the acceptance criteria.

## Rules that make it acceptance (not demo-ware)
- **Criteria BEFORE closure**: each card carries its acceptance line first; the run maps
  every criterion → PASS/FAIL → evidence (console line, regex match, screenshot path).
- **Round-trips over reads**: for an input surface, drive the REAL form (fill+click) and
  verify the effect at the far end (our chat bridge test typed in the browser and the
  message arrived in the target tmux session — the strongest possible evidence).
- **Archive the PNGs** with the card/state dir — screenshots are the durable visual
  evidence a later session can re-read.
- **Codify after the first manual pass**: promote the checks into a repo harness
  (for example a `tests/ui-acceptance.py` behind an opt-in SMOKE_UI=1 gate) so CI
  re-runs the machine layers; the vision pass re-runs whenever a Claude reads the shots.
- Loopback UIs need no auth juggling — run the browser ON the host, target 127.0.0.1.
  For login walls (Plane), fill the real form from the out-of-band creds file.

## Known traps
- A 302/200 or a served JS file proves NOTHING about registration — check the console.
- SPA screenshots taken before `networkidle`+settle show skeletons; wait, then shoot.
- `inner_text` on the wrong route silently matches globals (headers); anchor asserts to
  route-specific strings.
- Don't test input surfaces against production targets blindly — our chat test used a
  throwaway tmux first, then the live target intentionally, announced.

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
