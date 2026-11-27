#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The browser half of /test-ui-style.sh: what a browser makes of the harness stylesheet (docs/UI-STYLE.md).

Needs Python Playwright with a Chromium (pip install playwright && python3 -m playwright install chromium); the shell
test runs it when they are there and says so when they are not. Runs against the test's own nginx or a live deployment:

  ui-style-browser.py --base http://127.0.0.1:8000 --css Container-Root/agent/ui/harness.css \\
      --hosts hindsight,loglearner [--out <screenshot dir>]

Checks (each FAILS if its property is removed; exit 1 on the first failure):
  B1  the home page and the tmux cheatsheet at 1920x1080 and at 390x844 render with the tokens: the body's background is
      the light --hs-bg, the home page shows at least one state pill and every pill shows a word (its ::after content),
      never a colour alone; at 390 px nothing lays out wider than the screen (no horizontal overflow)
  B2  both themes, all six OS x data-theme combinations, on the home page and the cheatsheet: the body's background and
      the ROOT element's computed color-scheme follow the theme - dark under prefers-color-scheme: dark with no
      attribute, light under data-theme="light" even then, dark under data-theme="dark" even under light emulation
  B3  on each host in --hosts (two tile hosts at least), at both sizes: the Harness home badge is in the page, inside
      the viewport, visible, and styled by the stylesheet (its computed background is the stylesheet's, not the
      fallback's), and every request for the stylesheet went to the page's own host - never across hosts
  B4  PLANTED CONTROL: the home page served without its stylesheet link renders WITHOUT the tokens (B1's background
      check fails on it), so B1 does measure the stylesheet and not the page's own markup
  B5  a third-party page is unchanged by the sheet: on the first two hosts, under dark AND light emulation, a snapshot of
      EVERY standard computed property (custom properties aside: the inert, inherited --hs- tokens) of EVERY element but
      the badge, the injected link and elements with a running animation (which differ between two loads by themselves;
      their count is part of the snapshot) is the same with the stylesheet and with its request blocked; PLANTED CONTROL: a sheet with an important root color-scheme and body font INSIDE its cascade
      layer (important, as the badge's own rules are - a normal layered rule loses to the page's own) changes the
      snapshot, and the check fails
  --badge-clear <hosts>  (a mode of its own, for every adopter; one host is enough): on each host, at 1920x1080 and
      390x844, on the initial render AND after a simulated application DOM replacement (the body's children re-created,
      which the badge's keeper script survives), exactly one badge is in the page, inside the viewport, and its box meets
      no interactive element's box (a, button, input, select, textarea, summary, [role=button], [tabindex], in the
      document and in every open shadow root; an iframe's document is not seen); the offending element is named with the
      overlap in CSS px². PLANTED CONTROLS: a stub page with a button in the badge's corner fails - the desktop's bottom
      right and the phone's bottom left. A route clears a collision by setting --hs-badge-offset on its root
      (docs/UI-STYLE.md).
The token values are read from --css, so the expectations follow the file. Screenshots of every page and size go to
--out (evidence, read them). Nothing here writes anywhere else.
"""
import argparse
import os
import re
import sys
from urllib.parse import urlparse

SIZES = ((1920, 1080), (390, 844))
BADGE_BG = "rgb(35, 47, 62)"  # .hs-badge's background in harness.css; the fallback style's is the system colour


def fail(msg):
    print(f"ui-style-browser FAILED: {msg}")
    sys.exit(1)


def rgb(hexcolor):
    h = hexcolor.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return "rgb(%d, %d, %d)" % tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def tokens(css):
    """{'light': {name: hex}, 'dark': {name: hex}} from harness.css: the :root block and the data-theme="dark" block."""
    out = {}
    for theme, head in (("light", r":root\s*\{"), ("dark", r':root\[data-theme="dark"\]\s*\{')):
        m = re.search(head + r"(.*?)\}", css, re.S)
        if not m:
            fail(f"harness.css has no {theme} token block")
        out[theme] = dict(re.findall(r"(--hs-[a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{3,6})\b", m.group(1)))
    return out


def body_bg(page):
    return page.evaluate("getComputedStyle(document.body).backgroundColor")


def dots_without_words(page):
    return page.evaluate("""() => [...document.querySelectorAll('.dot, .hs-dot')].filter(d => {
        const t = (d.textContent || '').trim(); const a = getComputedStyle(d, '::after').content;
        return !t && (!a || a === 'none' || a === 'normal' || a === '""'); }).length""")


BADGE_CLEAR_JS = """() => {
  const badges = document.querySelectorAll('#do-agent-aws-home, a[data-harness-home]');
  if (badges.length !== 1) return {badges: badges.length};
  const b = badges[0], bb = b.getBoundingClientRect(), hits = [];
  const SEL = 'a, button, input, select, textarea, summary, [role=button], [tabindex]:not([tabindex="-1"])';
  const all = [];                                   // the document and every OPEN shadow root under it (an iframe's document is not seen)
  const walk = (root) => { for (const el of root.querySelectorAll('*')) { if (el.matches(SEL)) all.push(el); if (el.shadowRoot) walk(el.shadowRoot); } };
  walk(document);
  for (const el of all) {
    if (el === b) continue;
    const r = el.getBoundingClientRect(); if (!r.width || !r.height) continue;
    const cs = getComputedStyle(el); if (cs.visibility === 'hidden' || cs.display === 'none' || cs.pointerEvents === 'none') continue;
    const ix = Math.max(0, Math.min(bb.right, r.right) - Math.max(bb.left, r.left)), iy = Math.max(0, Math.min(bb.bottom, r.bottom) - Math.max(bb.top, r.top));
    if (ix * iy > 0) hits.push({tag: el.tagName, id: el.id, cls: String(el.className).slice(0, 60), text: (el.textContent || '').trim().slice(0, 40), area: Math.round(ix * iy)});
  }
  return {badges: 1, box: [Math.round(bb.left), Math.round(bb.top), Math.round(bb.width), Math.round(bb.height)], hits};
}"""
REPLACE_DOM_JS = """() => { const kids = [...document.body.children]; for (const k of kids) { const c = k.cloneNode(true); document.body.replaceChild(c, k); } }"""


def badge_clear(a, browser, base, port, hosts, shot):
    """--badge-clear: the badge meets no interactive element's box on every host, at every size, before and after a DOM
    replacement; with --open-first the first matching link is opened first (a card panel); with --referer-home the host is
    loaded as the home page's tile click loads it (a sign-in that admits that referer only), at --path (a sign-in path). The
    planted control is a button
    at the badge's own box, wherever the route rests it."""
    sizes = [tuple(int(x) for x in sz.split("x")) for sz in a.sizes.split(",") if sz]
    home = f"{base.scheme}://localhost:{port}/"
    opened_url = {}   # host -> the address of the card a click opened at an earlier size
    def load(page, url, host):
        page.goto(url, wait_until="load", referer=home if a.referer_home else None)
        page.wait_for_timeout(2500)
        if a.open_first:
            # a sign-in path hands the browser on to the UI from the page it answers with: wait for the address to leave it
            if a.path != "/" and page.url.endswith(a.path):
                page.wait_for_url(lambda u: not u.endswith(a.path), timeout=15000)
                page.wait_for_timeout(2500)
            # the candidates (| separated, in order of preference), the first few matches of each: a card on a board is a
            # block, not a link, and the click must open a page of its own; a control that opens no page (a menu) is passed over
            cands = [x for x in a.open_first.split("|") if x]
            page.wait_for_selector(", ".join(cands), timeout=10000)
            before = page.url
            for sel in cands:
                for el in page.query_selector_all(sel)[:4]:
                    try:
                        el.click(timeout=5000)
                    except Exception:
                        continue
                    page.wait_for_timeout(3500)
                    if page.url != before:
                        opened_url[host] = page.url
                        return page.url
                    page.keyboard.press("Escape")
            # a phone layout keeps its cards behind other controls: the card a wider size opened is loaded by its address
            # (the sizes run in the order given, so a wide size first)
            if opened_url.get(host):
                page.goto(opened_url[host], wait_until="load", referer=home if a.referer_home else None)
                page.wait_for_timeout(3500)
                if page.url != before:
                    return page.url
            fail(f"badge-clear --open-first: no click on {a.open_first!r} opened a page on {before}, and no earlier size opened one")
        return page.url
    def measure(page, w, h, what):
        r = page.evaluate(BADGE_CLEAR_JS)
        if r.get("badges") != 1:
            fail(f"badge-clear {what}: {r.get('badges')} badge(s) in the page (want exactly one)")
        x, y, bw, bh = r["box"]
        if x < 0 or y < 0 or x + bw > w or y + bh > h or not bw or not bh:
            fail(f"badge-clear {what}: the badge's box {r['box']} is outside the {w}x{h} viewport")
        if r["hits"]:
            fail(f"badge-clear {what}: the badge (box {r['box']}) covers {len(r['hits'])} control(s): " + "; ".join(f"<{h_['tag'].lower()} id={h_['id']!r} class={h_['cls']!r}> {h_['text']!r} by {h_['area']} px²" for h_ in r["hits"][:3]))
        return r["box"]
    opened = " with the first link opened" if a.open_first else ""
    for host in hosts:
        for w, h in sizes:
            ctx = browser.new_context(viewport={"width": w, "height": h}, color_scheme="light")
            page = ctx.new_page()
            load(page, f"{base.scheme}://{host}.localhost:{port}{a.path}", host)
            box1 = measure(page, w, h, f"{host}.localhost at {w}x{h}{opened}, initial render")
            page.evaluate(REPLACE_DOM_JS)
            page.wait_for_timeout(1500)
            box2 = measure(page, w, h, f"{host}.localhost at {w}x{h}{opened}, after the DOM replacement")
            shot(page, f"badge-clear-{host}-{w}x{h}")
            ctx.close()
            print(f"ok badge-clear - {host}.localhost at {w}x{h}{opened}: one badge at {box1} (after the replacement {box2}), no control under it")
    # the planted control: the first host's page (opened the same way) with a button planted at the badge's own box - wherever
    # the route rests or moves the badge - which must be reported as covered
    for (w, h) in sizes:
        ctx = browser.new_context(viewport={"width": w, "height": h}, color_scheme="light")
        page = ctx.new_page()
        target = load(page, f"{base.scheme}://{hosts[0]}.localhost:{port}{a.path}", hosts[0])
        box = page.evaluate(BADGE_CLEAR_JS).get("box") or [0, 0, 0, 0]
        real = page.request.get(target, headers={"Referer": home} if a.referer_home else {}).text()
        where = f"left:{box[0]}px;top:{box[1]}px"
        planted = real.replace("</body>", f'<button id="planted-control" style="position:fixed;{where};width:120px;height:40px">planted</button></body>', 1)
        if planted == real:
            fail("badge-clear PLANTED CONTROL: could not plant a button in the first host's page")
        page.route(target, lambda route, request, body=planted: route.fulfill(status=200, content_type="text/html; charset=utf-8", body=body))
        page.goto(target, wait_until="load", referer=home if a.referer_home else None)
        page.wait_for_timeout(2500)
        r = page.evaluate(BADGE_CLEAR_JS)
        if not r.get("hits"):
            fail(f"badge-clear PLANTED CONTROL: a button planted at the badge's box at {w}x{h} ({where}) was not reported as covered")
        print(f"ok badge-clear - planted control at {w}x{h}: a button at the badge's box ({where}) is reported ({r['hits'][0]['area']} px² under the badge)")
        ctx.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="the home listener, e.g. http://127.0.0.1:8000")
    ap.add_argument("--css", required=True, help="the harness.css the deployment serves (its tokens are the expectations)")
    ap.add_argument("--hosts", default="hindsight,loglearner", help="tile hosts to check the badge on (*.localhost labels)")
    ap.add_argument("--out", default="", help="screenshot directory")
    ap.add_argument("--badge-clear", default="", help="run ONLY the badge-clearance check on these *.localhost labels (comma-separated)")
    ap.add_argument("--sizes", default="1920x1080,390x844", help="--badge-clear: the viewports, WxH comma-separated")
    ap.add_argument("--referer-home", action="store_true", help="--badge-clear: load each host as the home page's tile click does (a sign-in that admits that referer only)")
    ap.add_argument("--open-first", default="", help="--badge-clear: before measuring, click an element matching one of these selectors (| separated, in order of preference; the first few matches of each) until a page of its own opens - a board's card, which opens its panel; a size where no click opens one loads the card an earlier size opened (phone layouts), so give a wide size first")
    ap.add_argument("--path", default="/", help="--badge-clear: the path to load on each host (a board's sign-in path, for one that signs the home page's click in)")
    a = ap.parse_args()
    from playwright.sync_api import sync_playwright

    tok = tokens(open(a.css, encoding="utf-8").read())
    light_bg, dark_bg = rgb(tok["light"]["--hs-bg"]), rgb(tok["dark"]["--hs-bg"])
    base = urlparse(a.base)
    port = base.port or 80
    hosts = [h for h in a.hosts.split(",") if h]
    if not a.badge_clear and len(hosts) < 2:
        fail("B3 needs at least two tile hosts (--hosts)")
    if a.out:
        os.makedirs(a.out, exist_ok=True)

    def shot(page, name):
        if a.out:
            page.screenshot(path=os.path.join(a.out, name + ".png"), full_page=False)

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)

        if a.badge_clear:
            badge_clear(a, browser, base, port, [h for h in a.badge_clear.split(",") if h], shot)
            browser.close()
            print("ui-style-browser succeeded (badge-clear)")
            return

        # --- B1: the home page and the cheatsheet with the tokens, both sizes
        for path, name in (("/", "home"), ("/tmux-help/", "cheatsheet")):
            for w, h in SIZES:
                ctx = browser.new_context(viewport={"width": w, "height": h}, color_scheme="light")
                page = ctx.new_page()
                page.goto(a.base + path, wait_until="load")
                page.wait_for_timeout(300)
                bg = body_bg(page)
                if bg != light_bg:
                    fail(f"B1 {name} at {w}x{h}: body background {bg}, the light --hs-bg is {light_bg} (the stylesheet did not apply)")
                if name == "home":
                    pills = page.evaluate("document.querySelectorAll('.dot, .hs-dot').length")
                    if not pills:
                        fail(f"B1 home page at {w}x{h}: no state pill in the page (the check would pass vacuously)")
                    n = dots_without_words(page)
                    if n:
                        fail(f"B1 home page at {w}x{h}: {n} of {pills} state pill(s) show no word")
                if page.evaluate("document.documentElement.scrollWidth") > w:
                    fail(f"B1 {name} at {w}x{h}: lays out wider than the screen ({page.evaluate('document.documentElement.scrollWidth')} px)")
                shot(page, f"{name}-light-{w}x{h}")
                ctx.close()
        print(f"ok B1 - the home page and the cheatsheet render with the tokens at {' and '.join(f'{w}x{h}' for w, h in SIZES)}: body background {light_bg}, every state pill a word, no overflow at 390 px")

        # --- B2: all six OS x data-theme combinations, body background AND the root's colour scheme, both pages
        combos = []
        for scheme in ("light", "dark"):
            for attr in (None, "light", "dark"):
                want_dark = (attr == "dark") or (attr is None and scheme == "dark")
                combos.append((scheme, attr, want_dark))
        for path, name in (("/", "home"), ("/tmux-help/", "cheatsheet")):
            for scheme, attr, want_dark in combos:
                ctx = browser.new_context(viewport={"width": 1280, "height": 800}, color_scheme=scheme)
                page = ctx.new_page()
                if attr:
                    page.add_init_script(f'document.addEventListener("DOMContentLoaded", () => document.documentElement.setAttribute("data-theme", "{attr}"));')
                page.goto(a.base + path, wait_until="load")
                page.wait_for_timeout(300)
                what = f"{name}, OS {scheme}, data-theme {attr or 'unset'}"
                bg, root_scheme = body_bg(page), page.evaluate("getComputedStyle(document.documentElement).colorScheme")
                want_bg = dark_bg if want_dark else light_bg
                if bg != want_bg:
                    fail(f"B2 {what}: body background {bg}, want {want_bg}")
                if root_scheme != ("dark" if want_dark else "light"):
                    fail(f"B2 {what}: the root's colour scheme is {root_scheme!r}, want {'dark' if want_dark else 'light'} (the viewport's scrollbars would not follow)")
                if name == "home":
                    shot(page, f"home-os-{scheme}-theme-{attr or 'unset'}")
                ctx.close()
        print(f"ok B2 - all six OS x data-theme combinations on both pages: body background and the root's colour scheme follow the theme (dark {dark_bg}, light {light_bg})")

        # --- B3: the badge on the tile hosts, styled from the same-origin stylesheet
        for host in hosts:
            for w, h in SIZES:
                ctx = browser.new_context(viewport={"width": w, "height": h}, color_scheme="light")
                page = ctx.new_page()
                css_requests = []
                page.on("request", lambda r: css_requests.append(r.url) if r.url.endswith("/__harness/harness.css") else None)
                url = f"{base.scheme}://{host}.localhost:{port}/"
                page.goto(url, wait_until="load")
                page.wait_for_timeout(500)
                badge = page.query_selector("#do-agent-aws-home, a[data-harness-home]")
                if not badge:
                    fail(f"B3 {host}.localhost at {w}x{h}: no Harness home badge in the page")
                box = badge.bounding_box()
                if not box or not badge.is_visible():
                    fail(f"B3 {host}.localhost at {w}x{h}: the badge is not visible")
                if box["x"] < 0 or box["y"] < 0 or box["x"] + box["width"] > w or box["y"] + box["height"] > h:
                    fail(f"B3 {host}.localhost at {w}x{h}: the badge is outside the viewport ({box})")
                bgc = badge.evaluate("e => getComputedStyle(e).backgroundColor")
                if bgc != BADGE_BG:
                    fail(f"B3 {host}.localhost at {w}x{h}: the badge is not styled by the stylesheet (background {bgc}, want {BADGE_BG})")
                if not css_requests:
                    fail(f"B3 {host}.localhost at {w}x{h}: the page never requested the stylesheet")
                for r in css_requests:
                    if urlparse(r).netloc != f"{host}.localhost:{port}":
                        fail(f"B3 {host}.localhost: the stylesheet was fetched across hosts, from {urlparse(r).netloc}")
                shot(page, f"badge-{host}-{w}x{h}")
                ctx.close()
        print(f"ok B3 - the badge is in the viewport and styled by the same-origin stylesheet on {', '.join(h + '.localhost' for h in hosts)} at both sizes")

        # --- B4: planted control - the home page without its link
        ctx = browser.new_context(viewport={"width": 1280, "height": 800}, color_scheme="light")
        page = ctx.new_page()
        html = page.request.get(a.base + "/").text()
        planted = re.sub(r'<link rel="stylesheet" href="/__harness/harness.css">\s*', "", html)
        if planted == html:
            fail("B4: could not plant the control (the home page carries no stylesheet link to remove)")
        page.route(a.base + "/", lambda route: route.fulfill(status=200, content_type="text/html; charset=utf-8", body=planted))
        page.goto(a.base + "/", wait_until="load")
        page.wait_for_timeout(300)
        bg = body_bg(page)
        if bg == light_bg:
            fail(f"B4 PLANTED CONTROL: the home page without its stylesheet link still has the token background {bg} - B1 would not notice a missing link")
        shot(page, "control-home-without-link")
        ctx.close()
        print(f"ok B4 - planted control: without its stylesheet link the home page renders without the tokens (body background {bg})")

        # --- B5: a third-party page keeps its look with the sheet - every element's computed style, two hosts
        SNAPSHOT_JS = """() => {
            const out = []; let animated = 0;
            for (const el of document.querySelectorAll('*')) {
                if (el.id === 'do-agent-aws-home' || el.id === 'do-agent-aws-home-style' || el.hasAttribute('data-harness-home')) continue;
                if (el.tagName === 'LINK' && (el.getAttribute('href') || '').endsWith('/__harness/harness.css')) continue;
                if (el.tagName === 'SCRIPT') continue;
                if (el.getAnimations && el.getAnimations().length) { animated++; continue; }   // a running animation changes between the two loads by itself
                const cs = getComputedStyle(el), vals = [];
                // every computed property but the custom ones: the sheet's --hs- tokens on :root are inherited by every
                // element and are inert there (nothing reads them); a standard property that changes is the leak
                for (let i = 0; i < cs.length; i++) if (!cs[i].startsWith('--')) vals.push(cs[i] + '=' + cs.getPropertyValue(cs[i]));
                out.push(el.tagName + '#' + (el.id || '') + '.' + el.className + '|' + vals.join('|'));
            }
            out.push('animated elements left out: ' + animated);
            return out; }"""
        def snapshot(host, scheme, mode):
            """The computed-style snapshot of the host's page with the sheet as served ('sheet'), with its request blocked
            ('none'), or with a leak planted INSIDE the sheet's cascade layer ('planted')."""
            ctx = browser.new_context(viewport={"width": 1280, "height": 800}, color_scheme=scheme)
            page = ctx.new_page()
            if mode == "none":
                page.route("**/__harness/harness.css", lambda route: route.abort())
            elif mode == "planted":
                sheet = open(a.css, encoding="utf-8").read()
                if "@layer hs {" not in sheet:
                    fail("B5: cannot plant inside the layer - the sheet has no `@layer hs {`")
                # the planted leak sits INSIDE the layer and is important, as the badge's own rules are: a page's unlayered
                # rules beat a normal layered leak (that is what the layer is for), an important one reaches every page
                planted_css = sheet.replace("@layer hs {", "@layer hs {\n:root { color-scheme: dark !important; }\nbody { font-family: serif !important; letter-spacing: 1px !important; }", 1)
                page.route("**/__harness/harness.css", lambda route: route.fulfill(status=200, content_type="text/css", body=planted_css))
            page.goto(f"{base.scheme}://{host}.localhost:{port}/", wait_until="load")
            page.wait_for_timeout(500)
            got = page.evaluate(SNAPSHOT_JS)
            ctx.close()
            return got
        for host in hosts[:2]:
            for scheme in ("dark", "light"):
                with_sheet, without = snapshot(host, scheme, "sheet"), snapshot(host, scheme, "none")
                if len(with_sheet) < 3:
                    fail(f"B5 {host}.localhost: the snapshot has {len(with_sheet)} elements (the check would pass vacuously)")
                if with_sheet != without:
                    diff = [(x, y) for x, y in zip(with_sheet, without) if x != y][:3]
                    fail(f"B5 {host}.localhost under {scheme}: the sheet changes {sum(1 for x, y in zip(with_sheet, without) if x != y)} element(s), e.g. {diff}")
                planted = snapshot(host, scheme, "planted")
                if planted == without:
                    fail(f"B5 PLANTED CONTROL: a sheet with an important root colour scheme and body font inside its layer left {host}.localhost unchanged under {scheme} emulation - the check would not notice a leak")
        print(f"ok B5 - {', '.join(h + '.localhost' for h in hosts[:2])} keep every computed property of every element ({len(with_sheet)} elements on the last) with the sheet under dark and light emulation; planted control: an important leak inside the layer changes the snapshot")
        browser.close()
    print("ui-style-browser succeeded")


if __name__ == "__main__":
    main()
