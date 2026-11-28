#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the harness design system (docs/UI-STYLE.md): the one stylesheet /agent/ui/harness.css, served same-origin
# at /__harness/harness.css by every server block of the home proxy (/agent/home-render.sh), and the pages this harness
# builds itself drawing their look from its tokens. Fully OFFLINE: nginx with the rendered config on test-local ports,
# stub upstreams on every UI port, test-local state under /tmp/ui-style-smoke. The browser half (/test-lib/ui-style-browser.py)
# runs when Python Playwright and a Chromium are installed and says so when they are not (the image carries neither).
#
# Properties proven (each check FAILS if the property is removed):
#   1. the stylesheet: under 12 KB (its license header, the two comment lines every source file opens with, not counted);
#      the whole sheet is one `@layer hs { ... }` block (nothing before or after it); every
#      token of the vocabulary (--hs-bg --hs-surface --hs-fg --hs-muted --hs-border --hs-accent --hs-ok --hs-stale --hs-bad
#      --hs-warn --hs-radius --hs-font --hs-mono --hs-space-1..4) is declared in the base block; the six themed tokens (bg,
#      surface, fg, muted, border, accent) again in BOTH dark scopes (the OS setting and the data-theme override), identical;
#      the four status tokens are FIXED - declared once, redefined in no scope (the data-viz rule: status never follows the
#      theme); every component class of the vocabulary exists (comments do not count); nothing is fetched (no @import, no
#      url(), no @font-face); the only at-rules are @layer, @media and @supports (an @page would restyle a third-party
#      print); braces balance; every selector is anchored on an .hs- class in a compound of its own (an .hs- inside
#      :not()/:is()/:where()/:has() anchors nothing - every proxied page contains the badge) with no sibling combinator
#      after the anchor, or is a bare :root compound that declares only --hs- tokens; no `color:` declaration takes a status
#      token - color, -webkit-text-fill-color, -webkit-text-stroke-color, text-emphasis-color or caret-color - nor aliases
#      one through any custom property, --hs- named ones and :root included (a status step colours shapes and rules, never
#      text - as text the steps fail AA on the light surface); the
#      badge reads the route's --hs-badge-offset (its clearance above a control in its corner) and --hs-badge-shift (its
#      move aside from a column of controls at its edge); .hs-header and .hs-wrap
#      read --hs-max (the page's measure, 1700px unless the page sets its own).
#      PLANTED CONTROLS (each must fail for its own reason): the base block without --hs-stale; the dark scope without
#      --hs-muted; the dark scope redefining --hs-ok; an @import; an @page; a rule after the layer's closing brace; the
#      layer wrapper removed; `:root body`; `body:not(.hs-page)`; `:root { color-scheme: dark }`; `.hs-badge ~ *`;
#      `:root:has(.hs-badge) { color-scheme: dark }`; `body:has(> .hs-badge) { background: red }`;
#      `:root:has(.hs-badge) body { font-family: serif }`; `.hs-dot.ok { color: var(--hs-ok) }`; the same with
#      -webkit-text-fill-color; the same with -webkit-text-stroke-color; the same aliased through a custom property, through
#      an --hs- named one and through a :root token; the badge without its --hs-badge-offset translation; .hs-wrap without
#      --hs-max
#   2. AA contrast, computed here on the pairs the pages render: in the light theme and in BOTH dark scopes the three ink
#      tokens (fg, muted, accent) read 4.5:1 or better on --hs-bg and on --hs-surface; every state pill's word on its
#      background - the sheet's .hs-dot states AND the home page's .dot states, each state's word colour and background
#      resolved through the pill's base rule (the off pill's muted word on the default tint included), the tints computed as
#      the sheet mixes them (color-mix of the step into --hs-surface at the rule's own percentage); the off tile's text on
#      its surface; the header's and the badge's white on the harness ink. The status tokens are shapes and rules, never
#      text, so they are not inks here. PLANTED CONTROLS: a copy whose --hs-muted is a pale grey fails, naming the pair; a
#      copy whose ok pill is tinted 85% fails, naming the pill; a copy whose default pill tint is 20% fails, naming the off
#      pill's word; a home page whose .dot tint is 20% fails the same way
#   3. no hardcoded colour (#rgb/#rgba/#rrggbb/#rrggbbaa; rgb()/hsl()/hwb()/lab()/lch()/oklab()/oklch()/color(); a CSS
#      colour name as a declaration value) and no status token as text (`color`, `-webkit-text-fill-color`,
#      `-webkit-text-stroke-color`, `text-emphasis-color`, `caret-color` with `var(--hs-ok|stale|bad|warn)`) nor aliased
#      through ANY custom property (`--x: var(--hs-ok)`, `--hs-x: var(--hs-ok)`, which would hide it from this gate) in the
#      pages this harness builds outside harness.css:
#      home-render.sh (the home page, the
#      cheatsheet, the badge), everything under /agent/ui/ but the stylesheet, and the other self-built pages when they are
#      in the checkout (loop-view/*, agent-chat.py, board-ui/*, board-server.py, knowledge-*). Comment text is not read -
#      a shell or config `# ...` line, a ` # ...` tail after code, a /* */ or <!-- --> block, a Python comment - and a #
#      glued to a word (hindsight#5559) is a reference, not a colour; the same digits in a style declaration (`color: #418`)
#      are a colour. PLANTED CONTROLS: a home-render.sh copy with one hex fails; one with an rgba() fails; one with a status
#      token as a text colour fails; one with it as -webkit-text-fill-color fails; one aliasing it through a custom property
#      fails; one through an --hs- named one fails; a digits-only colour in a declaration fails; a shell comment, a heredoc
#      config comment and a Python comment naming issue numbers each pass
#   4. the route: with every UI on (board and Plane sidecars included), every server block of the rendered nginx.conf but
#      the 421 default carries `location = /__harness/harness.css` with the stylesheet's alias and Cache-Control no-store.
#      PLANTED CONTROL: a home-render.sh copy whose hindsight.localhost block lacks it fails, naming that host
#   5. the pages: the home page and the cheatsheet link the stylesheet in <head> (root-relative), class their root
#      .hs-root, their body .hs-page and their header .hs-header; badge.conf, badge-host.conf and badge-rule.conf inject
#      the same root-relative link right before the badge (a host-absolute link would be a cross-host fetch on a
#      *.localhost route); badge-host-nolink.conf, for a host-routed page that links the sheet itself, injects the badge
#      and no link. PLANTED CONTROLS: a copy of the home page without the link fails; a nolink file with the link fails
#   6. through nginx: the stylesheet answers on the home host and on every *.localhost host (five here, at least three)
#      with the file's exact bytes, text/css and Cache-Control: no-store; a POST to it is refused; every page the proxy
#      injects the badge into - the path routes with a badge include, the terminal and the memory API docs among them,
#      and every host route - carries the link exactly once and the badge exactly once; the cheatsheet carries its own
#      link once; the home page carries its own link exactly
#      once; no served page carries a stylesheet link to another host. PLANTED CONTROL: the mutant config
#      of check 4, on other ports, answers the upstream's page instead of the stylesheet on hindsight.localhost
#   7. in a browser (/test-lib/ui-style-browser.py, when Playwright + Chromium are installed): the home page renders with
#      the tokens at 1920x1080 and 390x844, every state pill a word, no overflow at 390 px; both themes render and the
#      data-theme override wins both ways; the badge is in the viewport and styled by the same-origin stylesheet on two
#      tile hosts at both sizes; PLANTED CONTROL: the home page without its link renders without the tokens

D=/tmp/ui-style-smoke
rm -rf "${D:?}"
mkdir -p "${D}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="${BASE_DIR%/}/agent"
CSS="${AGENT_DIR}/ui/harness.css"
LINK='<link rel="stylesheet" href="/__harness/harness.css">'

export UI_DIR=${D}/ui
export UI_LISTEN_HOST=127.0.0.1
export HARNESS_CSS=${CSS}
# the kanban board as the docker target runs it (a sidecar the proxy resolves per request): its route renders, with the
# badge moved aside; only the stylesheet, which nginx serves itself, is asked of that host here
export KANBAN_BOARD_URL=${KANBAN_BOARD_URL:-http://kanban-server:8081}
export UI_HOME=true UI_HEADLAMP=true UI_HINDSIGHT=true UI_VIBE_KANBAN=true UI_TMUX=true UI_TMUX_WRITABLE=true \
	UI_TMUX_AGENT=true UI_CLAUDE_MEM=true UI_LOGLEARNER=true COMMS_UI_ENABLED=true
export UI_PORT_HOME=18531 UI_PORT_HEADLAMP=18532 UI_PORT_HINDSIGHT_API=18533 UI_PORT_HINDSIGHT_UI=18534 \
	UI_PORT_VIBE_KANBAN=18535 UI_PORT_TMUX=18536 UI_PORT_TMUX_AGENT=18537 UI_PORT_CLAUDE_MEM=18538 \
	UI_PORT_LOGLEARNER=18539 COMMS_UI_PORT=18540
MUTANT_PORT=18543
CONF=${UI_DIR}/home/nginx.conf
PIDS=()

cleanup()
{
	for P in "${UI_DIR}/home/nginx.pid" "${D}/mutant-ui/home/nginx.pid"; do
		[ -f "${P}" ] && kill "$(cat "${P}")" 2>/dev/null
	done
	for P in "${PIDS[@]}"; do kill "${P}" 2>/dev/null; done
}
trap cleanup EXIT

fail()
{
	echo "Test-ui-style FAILED: $1"
	exit 1
}

# --- 1. the stylesheet itself ---
bash -n "${AGENT_DIR}/home-render.sh" || fail "bash -n home-render.sh"
bash -n "$0" || fail "bash -n $0"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "${BASE_DIR}/test-lib/ui-style-browser.py" || fail "ui-style-browser.py does not parse"
[ -s "${CSS}" ] || fail "no stylesheet at ${CSS}"
# the budget is the sheet's own: the two lines of the license header every source file carries are not counted
SIZE=$(grep -vxF -e "/* Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. */" -e "/* SPDX-License-Identifier: Apache-2.0 */" "${CSS}" | wc -c)
[ "${SIZE}" -lt 12288 ] || fail "harness.css is ${SIZE} bytes without its license header (the budget is 12 KB)"
# sheet_ok <css file> - the vocabulary, both dark scopes, the components, nothing fetched, balanced braces; prints the
# first missing thing and exits 1
sheet_ok()
{
	python3 - "$1" << 'PYEOF'
import re, sys
css = open(sys.argv[1], encoding="utf-8").read()
tokens = ["--hs-bg", "--hs-surface", "--hs-fg", "--hs-muted", "--hs-border", "--hs-accent", "--hs-ok", "--hs-stale",
          "--hs-bad", "--hs-warn", "--hs-radius", "--hs-font", "--hs-mono", "--hs-space-1", "--hs-space-2", "--hs-space-3", "--hs-space-4"]
colours = tokens[:10]
components = [".hs-page", ".hs-header", ".hs-tile", ".hs-dot", ".hs-dot.ok", ".hs-dot.stale", ".hs-dot.bad", ".hs-dot.off",
              ".hs-stat", ".hs-table", ".hs-card", ".hs-badge", ".hs-empty", ".hs-error", ".hs-code"]
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
themed = ["--hs-bg", "--hs-surface", "--hs-fg", "--hs-muted", "--hs-border", "--hs-accent"]
status = ["--hs-ok", "--hs-stale", "--hs-bad", "--hs-warn"]
# one layer: the sheet opens with `@layer hs {` and that brace closes the file
body_text = css.strip()
if not body_text.startswith("@layer hs {") or not body_text.endswith("}"):
    print("the sheet is not one @layer hs { ... } block"); sys.exit(1)
depth, opened = 0, False
for i, ch in enumerate(body_text):
    depth += (ch == "{") - (ch == "}")
    opened = opened or depth > 0
    if opened and depth == 0 and i < len(body_text) - 1:
        print("a rule outside the @layer hs block (after its closing brace)"); sys.exit(1)
if depth != 0:
    print("braces do not balance"); sys.exit(1)
def block(head):
    m = re.search(head + r"\s*\{(.*?)\}", css, re.S)
    return m.group(1) if m else None
light = block(r":root")
if light is None:
    print("no :root block"); sys.exit(1)
for t in tokens:
    if not re.search(re.escape(t) + r"\s*:", light):
        print(f"light block lacks {t}"); sys.exit(1)
media = re.search(r"@media \(prefers-color-scheme: dark\)\s*\{\s*:root:where\(:not\(\[data-theme=\"light\"\]\)\)\s*\{(.*?)\}", css, re.S)
attr = block(r':root\[data-theme="dark"\]')
decl = lambda body: dict(re.findall(r"(--hs-[a-z0-9-]+)\s*:\s*([^;]+);", body))
for name, body in (("prefers-color-scheme dark scope", media.group(1) if media else None), ('data-theme="dark" scope', attr)):
    if body is None:
        print(f"no {name}"); sys.exit(1)
    for t in themed:
        if not re.search(re.escape(t) + r"\s*:", body):
            print(f"{name} lacks {t}"); sys.exit(1)
    for t in status:
        if re.search(re.escape(t) + r"\s*:", body):
            print(f"{name} redefines the status token {t} (status is fixed, never themed)"); sys.exit(1)
if decl(media.group(1)) != decl(attr):
    print("the two dark scopes differ"); sys.exit(1)
for t in status:
    if len(re.findall(re.escape(t) + r"\s*:", css)) != 1:
        print(f"the status token {t} is declared more than once (status is fixed, never themed)"); sys.exit(1)
for c in components:
    if not re.search(re.escape(c) + r"[\s,{:.>\[]", css):
        print(f"no {c} rule"); sys.exit(1)
badge = re.search(r"\.hs-badge\s*\{([^}]*)\}", css)
if not badge or not re.search(r"translate\s*:[^;]*var\(--hs-badge-offset, 0px\)[^;]*!important", badge.group(1)):
    print("the badge does not read --hs-badge-offset (a route's clearance above a control in its corner)"); sys.exit(1)
if not re.search(r"translate\s*:\s*calc\(-1 \* var\(--hs-badge-shift, 0px\)\)", badge.group(1)):
    print("the badge does not read --hs-badge-shift (a route's move aside from a column of controls at its edge)"); sys.exit(1)
for sel in (r"\.hs-header", r"\.hs-wrap"):
    rule = re.search(sel + r"\s*\{([^}]*)\}", css)
    if not rule or "var(--hs-max, 1700px)" not in rule.group(1):
        print(f"{sel.replace(chr(92), '')} does not read --hs-max (the page's measure; a page centred on another width sets it on :root)"); sys.exit(1)
nocomment = css
for bad in ("@import", "url(", "@font-face", "http://", "https://"):
    if bad in nocomment:
        print(f"the sheet fetches or refers out: {bad}"); sys.exit(1)
for at in re.findall(r"@([a-zA-Z-]+)", nocomment):
    if at not in ("layer", "media", "supports"):
        print(f"an at-rule other than @layer/@media/@supports: @{at} (it would reach a third-party page)"); sys.exit(1)
# the scope gate: a rule's selectors, with the arguments of :not()/:is()/:where()/:has() removed (an .hs- inside any of
# them anchors nothing - every proxied page contains the badge, so :has(.hs-badge) matches a third-party root), must
# each carry an .hs- class, and after the last compound that carries one only descendant or child combinators may follow
# (a sibling combinator after the anchor would reach a third-party page's own elements next to the badge); a selector
# without one must be a single :root compound (no combinator) whose block declares --hs- tokens only
for m in re.finditer(r"([^{}]+)\{([^{}]*)\}", nocomment):
    head, body = m.group(1).strip(), m.group(2)
    if not head or head.startswith("@"):
        continue
    for sel in head.split(","):
        sel = sel.strip()
        bare = re.sub(r":(not|is|where|has)\([^()]*(\([^()]*\)[^()]*)*\)", "", sel)
        parts = re.sub(r"\s*([>+~])\s*", r" \1 ", bare).split()
        anchors = [i for i, part in enumerate(parts) if ".hs-" in part]
        if anchors:
            if any(part in ("+", "~") for part in parts[anchors[-1] + 1:]):
                print(f"a sibling combinator after the .hs- anchor: {sel!r} (it would reach a third-party page's own elements)"); sys.exit(1)
            continue
        if bare.startswith(":root") and len(parts) == 1:
            if re.search(r"(^|;)\s*(?!--hs-)[a-zA-Z-]+\s*:", body):
                print(f"the :root block {sel!r} declares something other than --hs- tokens (it would leak into a third-party page)"); sys.exit(1)
            continue
        print(f"a selector outside the .hs- namespace: {sel!r} (a third-party page receiving this sheet would change)"); sys.exit(1)
    m2 = re.search(r"(?<![-\w])(color|-webkit-text-fill-color|-webkit-text-stroke-color|text-emphasis-color|caret-color)\s*:\s*[^;}]*var\(--hs-(ok|stale|bad|warn)\)", body)
    if m2:
        print(f"a status token as a text colour in {head!r}: {m2.group(0).strip()} (a status step colours shapes and rules, never text)"); sys.exit(1)
    m3 = re.search(r"(--[\w-]+)\s*:\s*[^;}]*var\(--hs-(ok|stale|bad|warn)\)", body)
    if m3:
        print(f"a status token aliased through a custom property in {head!r}: {m3.group(0).strip()} (set the step where the shape or rule uses it, so the text gate can see it)"); sys.exit(1)
print("ok")
PYEOF
}
sheet_ok "${CSS}" > ${D}/sheet.log || fail "harness.css: $(cat ${D}/sheet.log)"
mkdir -p ${D}/mutant-css
python3 - "${CSS}" "${D}/mutant-css" << 'PYEOF' || fail "could not plant the controls of check 1"
import re, sys
css, out = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
def w(name, text):
    assert text != css, name
    open(f"{out}/{name}", "w", encoding="utf-8").write(text)
def inside(rule):
    assert "@layer hs {" in css
    return css.replace("@layer hs {", "@layer hs {\n" + rule, 1)
w("no-stale-light.css", re.sub(r"\n\t--hs-stale: #[0-9a-f]+;[^\n]*", "", css, count=1))        # the base block's line only
i = css.index(':root[data-theme="dark"] {')
w("no-muted-dark.css", css[:i] + re.sub(r"--hs-muted: #[0-9a-f]+; ", "", css[i:], count=1))  # the attribute scope's only
w("themed-status.css", css[:i] + css[i:].replace("--hs-accent: #8fc1ff;", "--hs-accent: #8fc1ff; --hs-ok: #7fd47f;", 1))
w("import.css", inside('@import url("https://example.invalid/x.css");'))
w("page.css", inside("@page { margin: 3in; }"))
w("after-layer.css", css.rstrip() + "\nbody { margin: 0; }\n")
w("no-layer.css", css.replace("@layer hs {", "", 1).rstrip()[:-1])
w("leak-descendant.css", inside(":root body { color: red; }"))
w("leak-not.css", inside("body:not(.hs-page) { margin: 0; }"))
w("leak-root-scheme.css", css.replace("@layer hs {\n\n:root {", "@layer hs {\n\n:root {\n\tcolor-scheme: dark;", 1))
w("leak-sibling.css", inside(".hs-badge ~ * { display: none; }"))
w("leak-has-root.css", inside(":root:has(.hs-badge) { color-scheme: dark; }"))
w("leak-has-body.css", inside("body:has(> .hs-badge) { background: red; }"))
w("leak-has-descendant.css", inside(":root:has(.hs-badge) body { font-family: serif; }"))
w("no-badge-shift.css", css.replace("translate: calc(-1 * var(--hs-badge-shift, 0px)) calc(", "translate: 0 calc(", 1))
w("status-text.css", inside(".hs-dot.ok { color: var(--hs-ok); }"))
w("no-badge-offset.css", re.sub(r"translate: calc\(-1 \* var\(--hs-badge-shift, 0px\)\) calc\(-1 \* var\(--hs-badge-offset, 0px\)\) !important; ", "", css, count=1))
w("status-fill.css", inside(".hs-dot.ok { -webkit-text-fill-color: var(--hs-ok); }"))
w("status-alias.css", inside(".hs-dot.ok { --word: var(--hs-ok); color: var(--word); }"))
w("status-alias-hs.css", inside(".hs-tile .hs-why { --hs-why: var(--hs-bad); color: var(--hs-why); }"))
w("status-root-alias.css", css.replace("@layer hs {\n\n:root {", "@layer hs {\n\n:root {\n\t--hs-ink-ok: var(--hs-ok);", 1))
w("status-stroke.css", inside(".hs-dot.ok { -webkit-text-stroke-color: var(--hs-ok); }"))
w("no-hs-max.css", css.replace("max-width: var(--hs-max, 1700px);", "max-width: 1700px;", 1))
PYEOF
control()
{
	# control <mutant file> <what must be in the verdict>
	sheet_ok "${D}/mutant-css/$1" > "${D}/sheet-$1.log" && fail "PLANTED CONTROL: the sheet $1 passed"
	grep -qF "$2" "${D}/sheet-$1.log" || fail "the control $1 failed for the wrong reason: $(cat "${D}/sheet-$1.log")"
}
control no-stale-light.css "light block lacks --hs-stale"
control no-muted-dark.css 'data-theme="dark" scope lacks --hs-muted'
control themed-status.css 'redefines the status token --hs-ok'
control import.css "fetches or refers out: @import"
control page.css "an at-rule other than @layer/@media/@supports: @page"
control after-layer.css "a rule outside the @layer hs block"
control no-layer.css "not one @layer hs { ... } block"
control leak-descendant.css "outside the .hs- namespace: ':root body'"
control leak-not.css "outside the .hs- namespace: 'body:not(.hs-page)'"
control leak-root-scheme.css "declares something other than --hs- tokens"
control leak-sibling.css "a sibling combinator after the .hs- anchor: '.hs-badge ~ *'"
control leak-has-root.css "declares something other than --hs- tokens"
control leak-has-body.css "outside the .hs- namespace: 'body:has(> .hs-badge)'"
control leak-has-descendant.css "outside the .hs- namespace: ':root:has(.hs-badge) body'"
control status-text.css "a status token as a text colour in '.hs-dot.ok'"
control no-badge-offset.css "does not read --hs-badge-offset"
control no-badge-shift.css "does not read --hs-badge-shift"
control status-fill.css "a status token as a text colour in '.hs-dot.ok': -webkit-text-fill-color"
control status-alias.css "a status token aliased through a custom property in '.hs-dot.ok'"
control status-alias-hs.css "a status token aliased through a custom property in '.hs-tile .hs-why'"
control status-root-alias.css "a status token aliased through a custom property in ':root'"
control status-stroke.css "a status token as a text colour in '.hs-dot.ok': -webkit-text-stroke-color"
control no-hs-max.css ".hs-wrap does not read --hs-max"
echo "ok 1 - harness.css (${SIZE} bytes): one @layer hs block; the token vocabulary in the base block, the six themed tokens in both (identical) dark scopes, the four status tokens fixed; every component class; nothing fetched; only @layer/@media/@supports; every selector anchored on .hs- (nothing inside :not/:is/:where/:has counts, no sibling combinator after it) or a tokens-only :root; no status token as text (color, -webkit-text-fill-color, -webkit-text-stroke-color, text-emphasis-color, caret-color) or aliased through ANY custom property; the badge reads --hs-badge-offset, the header and wrap --hs-max; twenty-two planted controls fail as planted"

# --- 2. AA contrast of the token pairs, computed ---
# contrast_ok <css file> <home-render.sh> - every ink on bg and surface in both themes >= 4.5, every pill word (the sheet's
# .hs-dot states and the home page's .dot states) on its tint, the off tile, white on the header ink
contrast_ok()
{
	python3 - "$1" "$2" << 'PYEOF'
import re, sys
css = open(sys.argv[1], encoding="utf-8").read()
page = open(sys.argv[2], encoding="utf-8", errors="replace").read()
page_css = re.search(r"<title>do-agent-aws harness</title>.*?<style>(.*?)</style>", page, re.S)
page_css = re.sub(r"/\*.*?\*/", "", page_css.group(1), flags=re.S) if page_css else ""
def srgb(h):
    h = h.lstrip("#"); h = "".join(c * 2 for c in h) if len(h) == 3 else h
    return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
def lin(c): return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def lum(h):
    r, g, b = (lin(c) for c in srgb(h)); return 0.2126 * r + 0.7152 * g + 0.0722 * b
def ratio(a, b):
    x, y = lum(a), lum(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
def toks(body): return dict(re.findall(r"(--hs-[a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{3,6})\b", body))
css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
light = toks(re.search(r":root\s*\{(.*?)\}", css, re.S).group(1))
dark = dict(light); dark.update(toks(re.search(r':root\[data-theme="dark"\]\s*\{(.*?)\}', css, re.S).group(1)))
dark_os = dict(light); dark_os.update(toks(re.search(r':root:where\(:not\(\[data-theme="light"\]\)\)\s*\{(.*?)\}', css, re.S).group(1)))
def mix(a, b, pct):
    # color-mix(in srgb, a pct%, b): the sRGB components mixed in the given proportion
    ra, rb = srgb(a), srgb(b)
    return "#" + "".join("%02x" % round(255 * (x * pct / 100 + y * (1 - pct / 100))) for x, y in zip(ra, rb))
def pill_states(text, pill):
    """{state: (word token, background token, percentage)} for a pill class and its state variants, each state resolved
    through the base rule: a rule `<...>PILL { color: var(--hs-X); background: color-mix(in srgb, var(--hs-Y) P%, var(--hs-surface)) }`
    sets the defaults, `PILL.state {...}` (or `<ancestor>.state PILL {...}`) overrides what it declares."""
    base, states = {}, {}
    for m in re.finditer(r"([^{}]+)\{([^{}]*)\}", text):
        heads, body = m.group(1), m.group(2)
        word = re.search(r"(?<![-\w])color\s*:\s*var\((--hs-[a-z]+)\)", body)
        bg = re.search(r"background\s*:\s*color-mix\(in srgb, var\((--hs-[a-z]+)\) (\d+)%, var\(--hs-surface\)\)", body)
        if not word and not bg:
            continue
        for sel in heads.split(","):
            sel = sel.strip()
            if not re.search(re.escape(pill) + r"(\.[a-z]+)?$", sel) or "::" in sel or ":empty" in sel:
                continue
            state = re.search(re.escape(pill) + r"\.([a-z]+)$", sel)
            state = state.group(1) if state else (re.search(r"\.(off|ok|stale|bad|up|down)\s+" + re.escape(pill) + r"$", sel).group(1) if re.search(r"\.(off|ok|stale|bad|up|down)\s+" + re.escape(pill) + r"$", sel) else None)
            target = states.setdefault(state, {}) if state else base
            if word: target["word"] = word.group(1)
            if bg: target["bg"] = (bg.group(1), int(bg.group(2)))
    if "word" not in base or "bg" not in base:
        return {}
    out = {None: (base["word"], base["bg"][0], base["bg"][1])}
    for state, d in states.items():
        out[state] = (d.get("word", base["word"]), *(d.get("bg", base["bg"])))
    return out
pills = {".hs-dot": pill_states(css, ".hs-dot"), ".dot": pill_states(page_css, ".dot")}
if len(pills[".hs-dot"]) < 5:
    print(f"FAIL: only {len(pills['.hs-dot'])} .hs-dot states resolved in the sheet (want the default, ok, stale, bad and off pills)"); sys.exit(1)
if len(pills[".dot"]) < 4:
    print(f"FAIL: only {len(pills['.dot'])} .dot states resolved in the home page (want the default, up, down and off pills)"); sys.exit(1)
off_tile = re.search(r"\.hs-tile\.off\s*\{[^}]*background:\s*color-mix\(in srgb, var\(--hs-surface\) (\d+)%, var\(--hs-bg\)\)", css)
if not off_tile:
    print("FAIL: no off-tile surface mix found"); sys.exit(1)
worst = ("", 99.0)
n = 0
def need(theme, what, ink, bg, floor=4.5):
    global worst, n
    r = ratio(ink, bg); n += 1
    if r < worst[1]: worst = (f"{theme} {what}", r)
    if r < floor:
        print(f"FAIL {theme}: {what} - {ink} on {bg} is {r:.2f}:1 (AA needs {floor}:1)"); sys.exit(1)
for theme, t in (("light", light), ("dark", dark), ("dark (OS scope)", dark_os)):
    for ink in ("--hs-fg", "--hs-muted", "--hs-accent"):
        for surface in ("--hs-bg", "--hs-surface"):
            need(theme, f"{ink} on {surface}", t[ink], t[surface])
    for pill, states in pills.items():
        for state, (word_tok, bg_tok, pct) in states.items():
            label = f"{pill}.{state}" if state else f"{pill} (default)"
            need(theme, f"the {label} pill's {word_tok} word on its {pct}% {bg_tok} tint", t[word_tok], mix(t[bg_tok], t["--hs-surface"], pct))
    need(theme, "the off tile's muted text on its surface", t["--hs-muted"], mix(t["--hs-surface"], t["--hs-bg"], int(off_tile.group(1))))
header = re.search(r"\.hs-header\s*\{[^}]*background:\s*(#[0-9a-fA-F]{6})[^}]*color:\s*(#[0-9a-fA-F]{6})", css)
badge = re.search(r"\.hs-badge\s*\{[^}]*background:\s*(#[0-9a-fA-F]{6})[^}]*color:\s*(#[0-9a-fA-F]{6})", css)
for name, m in (("header", header), ("badge", badge)):
    if not m: print(f"FAIL: no background/colour pair in the .hs-{name} rule"); sys.exit(1)
    r = ratio(m.group(2), m.group(1))
    if r < 4.5: print(f"FAIL: the {name}'s text {m.group(2)} on {m.group(1)} is {r:.2f}:1"); sys.exit(1)
print(f"{n} rendered pairs (3 inks x 2 surfaces, {len(pills['.hs-dot'])} sheet pill states and {len(pills['.dot'])} home-page pill states on their tints, the off tile; light, dark, dark OS scope) and the header and badge text pass AA; the weakest is {worst[0]} at {worst[1]:.2f}:1")
PYEOF
}
contrast_ok "${CSS}" "${AGENT_DIR}/home-render.sh" > "${D}/contrast.log" || fail "contrast: $(cat "${D}/contrast.log")"
python3 - "${CSS}" ${D}/mutant-css/pale-muted.css << 'PYEOF'
import re, sys
css = open(sys.argv[1], encoding="utf-8").read()
new = re.sub(r"(--hs-muted:\s*)#[0-9a-fA-F]{6}", r"\g<1>#9aa0a6", css, count=1)
assert new != css, "could not plant the pale --hs-muted"
open(sys.argv[2], "w", encoding="utf-8").write(new)
PYEOF
contrast_ok "${D}/mutant-css/pale-muted.css" "${AGENT_DIR}/home-render.sh" > "${D}/contrast-c.log" && fail "PLANTED CONTROL: a pale --hs-muted passed the contrast check"
grep -q 'FAIL light: --hs-muted on --hs-bg - #9aa0a6 on' "${D}/contrast-c.log" || fail "the contrast control failed for the wrong reason: $(cat "${D}/contrast-c.log")"
sed 's/var(--hs-ok) 12%, var(--hs-surface)/var(--hs-ok) 85%, var(--hs-surface)/' "${CSS}" > "${D}/mutant-css/deep-tint.css"
grep -q 'var(--hs-ok) 85%' "${D}/mutant-css/deep-tint.css" || fail "could not plant the deep tint"
contrast_ok "${D}/mutant-css/deep-tint.css" "${AGENT_DIR}/home-render.sh" > "${D}/contrast-c2.log" && fail "PLANTED CONTROL: an 85% pill tint passed the contrast check"
grep -q "the .hs-dot.ok pill's --hs-fg word on its 85% --hs-ok tint" "${D}/contrast-c2.log" || fail "the tint control failed for the wrong reason: $(cat "${D}/contrast-c2.log")"
# the off pill's muted word on the DEFAULT tint is the weakest rendered pair: a 20% default tint takes it under 4.5:1
sed 's/var(--hs-muted) 12%, var(--hs-surface)/var(--hs-muted) 20%, var(--hs-surface)/' "${CSS}" > "${D}/mutant-css/off-tint.css"
grep -q 'var(--hs-muted) 20%' "${D}/mutant-css/off-tint.css" || fail "could not plant the 20% default tint"
contrast_ok "${D}/mutant-css/off-tint.css" "${AGENT_DIR}/home-render.sh" > "${D}/contrast-c3.log" && fail "PLANTED CONTROL: a 20% default pill tint passed the contrast check"
grep -q "the .hs-dot.off pill's --hs-muted word on its 20% --hs-muted tint" "${D}/contrast-c3.log" || fail "the off-tint control failed for the wrong reason: $(cat "${D}/contrast-c3.log")"
mkdir -p "${D}/mutant"
sed 's/^\.dot { \(.*\)var(--hs-muted) 12%, var(--hs-surface)/.dot { \1var(--hs-muted) 20%, var(--hs-surface)/' "${AGENT_DIR}/home-render.sh" > "${D}/mutant/home-render-dot-tint.sh"
grep -q '^\.dot { .*var(--hs-muted) 20%' "${D}/mutant/home-render-dot-tint.sh" || fail "could not plant the home page's 20% pill tint"
contrast_ok "${CSS}" "${D}/mutant/home-render-dot-tint.sh" > "${D}/contrast-c4.log" && fail "PLANTED CONTROL: a 20% .dot tint on the home page passed the contrast check"
grep -q "the .dot.off pill's --hs-muted word on its 20% --hs-muted tint" "${D}/contrast-c4.log" || fail "the home-page tint control failed for the wrong reason: $(cat "${D}/contrast-c4.log")"
echo "ok 2 - $(cat "${D}/contrast.log"); controls: a pale --hs-muted fails ($(cut -c1-70 "${D}/contrast-c.log")), an 85% ok tint fails, a 20% default tint fails on the sheet's off pill and on the home page's off pill"

# --- 3. no hardcoded palette hex outside harness.css ---
# hex_free <file>... - prints every hardcoded colour (#rgb, #rgba, #rrggbb, #rrggbbaa as CSS or JS would read it; the
# rgb()/hsl()/hwb()/lab()/lch()/oklab()/oklch()/color() functions; a CSS colour name as a declaration value, such as
# `color: gray;` - a &#NNNN; entity is not a colour) with its line; exit 1 when any
hex_free()
{
	python3 - "$@" << 'PYEOF'
import io, re, sys, tokenize
names = ("white|black|gray|grey|silver|red|green|blue|yellow|orange|purple|navy|teal|maroon|olive|lime|aqua|cyan|magenta|fuchsia|"
         "brown|pink|gold|beige|ivory|khaki|coral|salmon|tomato|crimson|indigo|violet|turquoise|tan|wheat|linen|snow|azure|lavender")
# a # glued to a word (hindsight#5559) is a reference, not a colour; comment text is blanked before the scan (below)
pat = re.compile(r"(?<![&\w])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![0-9a-zA-Z_-])"
                 r"|(?<![a-zA-Z-])(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\("
                 r"|(?<=[:\s])(?:" + names + r")(?=\s*(?:;|!important|\}|$))"
                 r"|(?<![-\w])(?:color|-webkit-text-fill-color|-webkit-text-stroke-color|text-emphasis-color|caret-color)\s*:\s*[^;}]*var\(--hs-(?:ok|stale|bad|warn)\)"
                 r"|--[\w-]+\s*:\s*[^;}]*var\(--hs-(?:ok|stale|bad|warn)\)")
def blank(m):
    return re.sub(r"[^\n]", " ", m.group(0))
HEREDOC = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?")
def uncommented(path, text):
    """The file's text with its comments blanked (line numbers kept): a comment documents a page, it is not the page.
    A Python file's comments come from its tokenizer (a # inside a string stays). Elsewhere a /* ... */ or <!-- ... -->
    block goes; in a shell file a `# ...` line and a ` # ...` tail after code go, and inside a heredoc - whose lines are
    content: a page, a config - only a `# ` line (hash and a space; a CSS id selector has no space) goes."""
    if path.endswith(".py"):
        lines = text.split("\n")
        try:
            for tok in tokenize.generate_tokens(io.StringIO(text).readline):
                if tok.type == tokenize.COMMENT:
                    r, c = tok.start
                    lines[r - 1] = lines[r - 1][:c] + " " * (tok.end[1] - c) + lines[r - 1][tok.end[1]:]
        except (tokenize.TokenError, SyntaxError):
            pass
        return "\n".join(lines)
    text = re.sub(r"/\*.*?\*/|<!--.*?-->", blank, text, flags=re.S)
    lines = text.split("\n")
    if path.endswith(".js"):
        return "\n".join(re.sub(r"(^|\s)//\s.*$", r"\1", l) for l in lines)
    if not (path.endswith(".sh") or lines[0].startswith("#!")):
        return "\n".join(lines)
    term = None
    for i, line in enumerate(lines):
        if term is not None:
            if line.strip() == term:
                term = None
            elif re.match(r"\s*#\s", line):
                lines[i] = ""
            continue
        if re.match(r"\s*#", line):
            lines[i] = ""
            continue
        m = HEREDOC.search(line)
        if m:
            term = m.group(1)
        lines[i] = re.sub(r"\s#\s.*$", "", line)
    return "\n".join(lines)
bad = 0
for path in sys.argv[1:]:
    text = uncommented(path, open(path, encoding="utf-8", errors="replace").read())
    for n, line in enumerate(text.split("\n"), 1):
        for m in pat.finditer(line):
            bad += 1
            kind = "STATUS-AS-TEXT" if "var(--hs-" in m.group(0) else "COLOUR"
            print(f"{kind} {path}:{n}: {m.group(0)} in {line.strip()[:100]}")
sys.exit(1 if bad else 0)
PYEOF
}
PAGES=("${AGENT_DIR}/home-render.sh")
for F in "${AGENT_DIR}"/ui/* "${AGENT_DIR}"/loop-view/* "${AGENT_DIR}"/agent-chat.py "${AGENT_DIR}"/board-ui/* "${AGENT_DIR}"/board-server.py "${AGENT_DIR}"/files-ui/* "${AGENT_DIR}"/files-server.py \
	"${AGENT_DIR}"/knowledge-view/*; do
	[ -f "${F}" ] && [ "${F}" != "${CSS}" ] && PAGES+=("${F}")
done
hex_free "${PAGES[@]}" > ${D}/hex.log || fail "a page outside harness.css carries a hardcoded colour or a status token as text: $(head -3 ${D}/hex.log | tr '\n' ' ')"
mkdir -p ${D}/mutant
sed 's/^li\.tile p\.note { color: var(--hs-muted);/li.tile p.note { color: #5c6670;/' "${AGENT_DIR}/home-render.sh" > ${D}/mutant/home-render-hex.sh
grep -q '#5c6670' ${D}/mutant/home-render-hex.sh || fail "could not plant the hex control"
hex_free ${D}/mutant/home-render-hex.sh > ${D}/hex-c.log && fail "PLANTED CONTROL: a home-render.sh with one palette hex passed the grep gate"
grep -q 'COLOUR .*home-render-hex.sh:.*#5c6670' ${D}/hex-c.log || fail "the hex control failed for the wrong reason: $(cat ${D}/hex-c.log)"
sed 's/^li\.tile p\.note { color: var(--hs-muted);/li.tile p.note { color: rgba(0, 0, 0, .6);/' "${AGENT_DIR}/home-render.sh" > ${D}/mutant/home-render-rgba.sh
hex_free ${D}/mutant/home-render-rgba.sh > ${D}/hex-c2.log && fail "PLANTED CONTROL: a home-render.sh with one rgba() colour passed the grep gate"
grep -q 'COLOUR .*home-render-rgba.sh:.*rgba(' ${D}/hex-c2.log || fail "the rgba control failed for the wrong reason: $(cat ${D}/hex-c2.log)"
sed 's/^\.dot\.up { background:/.dot.up { color: var(--hs-ok); background:/' "${AGENT_DIR}/home-render.sh" > ${D}/mutant/home-render-status-text.sh
grep -q '^\.dot\.up { color: var(--hs-ok);' ${D}/mutant/home-render-status-text.sh || fail "could not plant the status-as-text control"
hex_free ${D}/mutant/home-render-status-text.sh > ${D}/hex-c3.log && fail "PLANTED CONTROL: a home-render.sh with a status token as a text colour passed the page scan"
grep -q 'STATUS-AS-TEXT .*home-render-status-text.sh:.*color: var(--hs-ok)' ${D}/hex-c3.log || fail "the status-as-text control failed for the wrong reason: $(cat ${D}/hex-c3.log)"
sed 's/^\.dot\.up { background:/.dot.up { -webkit-text-fill-color: var(--hs-ok); background:/' "${AGENT_DIR}/home-render.sh" > ${D}/mutant/home-render-status-fill.sh
hex_free ${D}/mutant/home-render-status-fill.sh > ${D}/hex-c4.log && fail "PLANTED CONTROL: a home-render.sh with a status token as -webkit-text-fill-color passed the page scan"
grep -q 'STATUS-AS-TEXT .*home-render-status-fill.sh:.*-webkit-text-fill-color: var(--hs-ok)' ${D}/hex-c4.log || fail "the text-fill control failed for the wrong reason: $(cat ${D}/hex-c4.log)"
sed 's/^\.dot\.up { background:/.dot.up { --word: var(--hs-ok); background:/' "${AGENT_DIR}/home-render.sh" > ${D}/mutant/home-render-status-alias.sh
hex_free ${D}/mutant/home-render-status-alias.sh > ${D}/hex-c5.log && fail "PLANTED CONTROL: a home-render.sh aliasing a status token through a custom property passed the page scan"
grep -q 'STATUS-AS-TEXT .*home-render-status-alias.sh:.*--word: var(--hs-ok)' ${D}/hex-c5.log || fail "the alias control failed for the wrong reason: $(cat ${D}/hex-c5.log)"
sed 's/^\.dot\.up { background:/.dot.up { --hs-up: var(--hs-ok); background:/' "${AGENT_DIR}/home-render.sh" > ${D}/mutant/home-render-status-alias-hs.sh
hex_free ${D}/mutant/home-render-status-alias-hs.sh > ${D}/hex-c6.log && fail "PLANTED CONTROL: a home-render.sh aliasing a status token through an --hs- named property passed the page scan"
grep -q 'STATUS-AS-TEXT .*home-render-status-alias-hs.sh:.*--hs-up: var(--hs-ok)' ${D}/hex-c6.log || fail "the --hs- alias control failed for the wrong reason: $(cat ${D}/hex-c6.log)"
# comment text is documentation, not a page: a shell comment naming issue numbers, a config comment inside a heredoc naming a
# reference glued to a word, and a Python comment pass; the same digits as a colour in a style context still fail
{ head -1 "${AGENT_DIR}/home-render.sh"; echo "# the viewer logs React hydration errors #418/#423 here, see hindsight#5559"; tail -n +2 "${AGENT_DIR}/home-render.sh"; } > ${D}/mutant/home-render-comment.sh
hex_free ${D}/mutant/home-render-comment.sh > ${D}/hex-c7.log || fail "PLANTED CONTROL: a comment line naming issue numbers (#418/#423, hindsight#5559) was read as a colour: $(head -2 ${D}/hex-c7.log | tr '\n' ' ')"
python3 - "${AGENT_DIR}/home-render.sh" ${D}/mutant/home-render-heredoc-comment.sh << 'PY'
import sys
s = open(sys.argv[1]).read()
anchor = "proxy_set_header Accept-Encoding \"\";\n"
assert s.count(anchor) == 1, "the proxy-common.conf line is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, anchor + "# a config comment inside the heredoc: see hindsight#5559 and the errors #418/#423\n"))
PY
hex_free ${D}/mutant/home-render-heredoc-comment.sh > ${D}/hex-c8.log || fail "PLANTED CONTROL: a comment line inside a heredoc naming references was read as a colour: $(head -2 ${D}/hex-c8.log | tr '\n' ' ')"
printf '%s\n' 'CSS = "body { color: var(--hs-fg); }"  # the page keeps #418 and #423 in words, see hindsight#5559' 'print(CSS)' > ${D}/mutant/page-comment.py
hex_free ${D}/mutant/page-comment.py > ${D}/hex-c9.log || fail "PLANTED CONTROL: a Python comment naming references was read as a colour: $(head -2 ${D}/hex-c9.log | tr '\n' ' ')"
sed 's/^li\.tile p\.note { color: var(--hs-muted);/li.tile p.note { color: #418;/' "${AGENT_DIR}/home-render.sh" > ${D}/mutant/home-render-digits.sh
grep -q 'color: #418;' ${D}/mutant/home-render-digits.sh || fail "could not plant the digits-only colour"
hex_free ${D}/mutant/home-render-digits.sh > ${D}/hex-c10.log && fail "PLANTED CONTROL: a digits-only colour (#418) in a style declaration passed the gate"
grep -q 'COLOUR .*home-render-digits.sh:.*#418 in li.tile p.note { color: #418;' ${D}/hex-c10.log || fail "the digits-only control failed for the wrong reason: $(cat ${D}/hex-c10.log)"
echo "ok 3 - no hardcoded colour, no status token as text (color, -webkit-text-fill-color, -webkit-text-stroke-color, text-emphasis-color, caret-color) and none aliased through any custom property in ${#PAGES[@]} page file(s) outside harness.css, comment text not read; controls: a planted hex, an rgba(), a status text colour, a status text-fill, a status alias, an --hs- named alias and a digits-only colour in a declaration each fail; a shell comment, a heredoc config comment and a Python comment naming issue numbers (#418/#423, hindsight#5559) each pass"

# --- 4. the stylesheet route on every server block ---
# route_ok <nginx.conf> <css path> - every server block but the 421 default has the location; prints the ones without
route_ok()
{
	python3 - "$1" "$2" << 'PYEOF'
import re, sys
text, css = open(sys.argv[1]).read(), sys.argv[2]
stack, servers, buf = [], [], ""
for t in re.split(r"(\{|\}|;)", text):
    if t == "{":
        stack.append([buf.strip().split("\n")[-1].strip(), ""]); buf = ""
    elif t == "}":
        head, body = stack.pop(); body += buf
        if head == "server":
            servers.append(body)
        if stack:
            stack[-1][1] += head + " {" + body + "} "
        buf = ""
    elif t == ";":
        buf += ";"
        if stack:
            stack[-1][1] += buf
        buf = ""
    else:
        buf += t
bad, n = [], 0
for body in servers:
    name = re.search(r"server_name\s+([^;]+);", body)
    name = name.group(1).split()[0] if name else "?"
    if name == "_":
        continue
    n += 1
    loc = re.search(r"location = /__harness/harness\.css \{([^}]*)\}", body)
    if not loc:
        bad.append(f"{name}: no location = /__harness/harness.css"); continue
    if f"alias {css};" not in loc.group(1):
        bad.append(f"{name}: the location does not alias {css}")
    if 'add_header Cache-Control "no-store";' not in loc.group(1):
        bad.append(f"{name}: the stylesheet is not Cache-Control no-store")
print(f"server blocks with the stylesheet: {n}")
for b in bad:
    print("MISSING " + b)
sys.exit(1 if bad or n < 4 else 0)
PYEOF
}
"${AGENT_DIR}/home-render.sh" > "${D}/render.log" 2>&1 || fail "home-render.sh: $(cat "${D}/render.log")"
route_ok "${CONF}" "${CSS}" > "${D}/route.log" || fail "a server block lacks the stylesheet route: $(grep MISSING "${D}/route.log" | tr '\n' ' ')"
python3 - "${AGENT_DIR}/home-render.sh" ${D}/mutant/home-render.sh << 'PYEOF'
import sys
s = open(sys.argv[1]).read()
anchor = "\t\tserver_name hindsight.localhost;\n\t\tif (\\$foreign_origin) { return 403; }\n\t\tset \\$proxy_upstream_host \\$http_host;\n$(harness_css_location)\n"
assert anchor in s, "the hindsight block is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, anchor.replace("$(harness_css_location)\n", "")))
PYEOF
[ -s ${D}/mutant/home-render.sh ] || fail "could not plant the route control"
UI_DIR=${D}/mutant-ui bash ${D}/mutant/home-render.sh > /dev/null 2>&1 || fail "the mutant home-render.sh did not render"
route_ok ${D}/mutant-ui/home/nginx.conf "${CSS}" > ${D}/route-c.log && fail "PLANTED CONTROL: a hindsight.localhost block without the stylesheet route passed"
grep -q 'MISSING hindsight.localhost: no location' ${D}/route-c.log || fail "the route control failed for the wrong reason: $(cat ${D}/route-c.log)"
echo "ok 4 - $(head -1 ${D}/route.log), each aliasing the sheet with no-store; control: hindsight.localhost without it fails"

# --- 5. the pages and the badge files link the stylesheet, root-relative ---
# page_ok <html> - the link once in <head>, body.hs-page, header.hs-header; no link to another host
page_ok()
{
	HEAD=$(sed -n '1,/<\/head>/p' "$1")
	[ "$(echo "${HEAD}" | grep -cF "${LINK}")" == "1" ] || { echo "$1: the stylesheet link is not in <head> exactly once"; return 1; }
	grep -q '<html lang="en" class="hs-root">' "$1" || { echo "$1: the root is not .hs-root"; return 1; }
	grep -q '<body class="hs-page">' "$1" || { echo "$1: the body is not .hs-page"; return 1; }
	grep -q '<header class="hs-header">' "$1" || { echo "$1: the header is not .hs-header"; return 1; }
	grep -E 'rel="stylesheet" href="(https?:)?//' "$1" && { echo "$1: a stylesheet link to another host"; return 1; }
	return 0
}
for P in "${UI_DIR}/home/site/index.html" "${UI_DIR}/home/site/tmux-help/index.html"; do
	page_ok "${P}" > ${D}/page.log || fail "$(cat ${D}/page.log)"
done
for F in badge.conf badge-host.conf badge-rule.conf; do
	grep -qF "'${LINK}<a class=\"hs-badge\" data-harness-home " "${UI_DIR}/home/${F}" || fail "${F} does not inject the root-relative stylesheet link right before the hs-badge"
done
# nolink_ok <badge file> - the badge markup once and no stylesheet link (for a host-routed page that links the sheet itself)
nolink_ok()
{
	[ "$(grep -o 'class="hs-badge"' "$1" | wc -l)" == "1" ] || { echo "$1: the badge is not in it exactly once"; return 1; }
	grep -q '<link' "$1" && { echo "$1: carries a stylesheet link (the page links the sheet itself)"; return 1; }
	grep -qF "href=\"//\$home_host/\"" "$1" || { echo "$1: the badge does not return to the home host"; return 1; }
	return 0
}
nolink_ok "${UI_DIR}/home/badge-host-nolink.conf" > "${D}/nolink.log" || fail "$(cat "${D}/nolink.log")"
# clear_ok <badge file> <px> - the route's clearance on the root (a <style> setting --hs-badge-offset) right before the link
# and the badge, in the one replacement, and the badge once
clear_ok()
{
	grep -qF "'<style>:root{--hs-badge-offset:$2px}</style>${LINK}<a class=\"hs-badge\" data-harness-home " "$1" || { echo "$1: does not set --hs-badge-offset:$2px on the root right before the link and the badge"; return 1; }
	[ "$(grep -o 'class="hs-badge"' "$1" | wc -l)" == "1" ] || { echo "$1: the badge is not in it exactly once"; return 1; }
	return 0
}
clear_ok "${UI_DIR}/home/badge-host-clear-60.conf" 60 > "${D}/clear.log" || fail "$(cat "${D}/clear.log")"
sed -n '/server_name claude-mem.localhost;/,/^\t}/p' "${UI_DIR}/home/nginx.conf" | grep -q 'include .*/badge-host-clear-60\.conf;' || fail "the claude-mem route does not take the 60 px clearance file (its console toggle sits where the badge lands)"
[ "$(grep -c 'badge-host-clear-' "${UI_DIR}/home/nginx.conf")" == "1" ] || fail "a clearance file is included $(grep -c 'badge-host-clear-' "${UI_DIR}/home/nginx.conf") times (want 1: the claude-mem route alone)"
sed 's#<style>[^<]*</style>##' "${UI_DIR}/home/badge-host-clear-60.conf" > "${D}/mutant/badge-host-clear-60-nostyle.conf"
clear_ok "${D}/mutant/badge-host-clear-60-nostyle.conf" 60 > "${D}/clear-c.log" && fail "PLANTED CONTROL: a clearance file without its <style> passed"
grep -q 'does not set --hs-badge-offset' "${D}/clear-c.log" || fail "the clearance control failed for the wrong reason: $(cat "${D}/clear-c.log")"
# shift_ok <badge file> <length> <from px> - the route's move aside on the root (a <style> with a min-width media query
# setting --hs-badge-shift) right before the link and the badge, in the one replacement, and the badge once
shift_ok()
{
	grep -qF "'<style>@media (min-width:$3px){:root{--hs-badge-shift:$2}}</style>${LINK}<a class=\"hs-badge\" data-harness-home " "$1" || { echo "$1: does not set --hs-badge-shift:$2 from $3px on the root right before the link and the badge"; return 1; }
	[ "$(grep -o 'class="hs-badge"' "$1" | wc -l)" == "1" ] || { echo "$1: the badge is not in it exactly once"; return 1; }
	return 0
}
shift_ok "${UI_DIR}/home/badge-host-shift-board.conf" 35vw 900 > "${D}/shift.log" || fail "$(cat "${D}/shift.log")"
sed -n '/server_name kanban.localhost;/,/^\t}/p' "${UI_DIR}/home/nginx.conf" | grep -q 'include .*/badge-host-shift-board\.conf;' || fail "the kanban route does not take the board's shift file (its card panel is a full-height column of controls at the badge's edge)"
[ "$(grep -c 'badge-host-shift-' "${UI_DIR}/home/nginx.conf")" == "1" ] || fail "a shift file is included $(grep -c 'badge-host-shift-' "${UI_DIR}/home/nginx.conf") times (want 1: the kanban route alone)"
# PLANTED: a home-render.sh whose board route keeps the plain badge include renders a route the check above refuses
python3 - "${AGENT_DIR}/home-render.sh" ${D}/mutant/home-render-noshift.sh << 'PYEOF'
import sys
s = open(sys.argv[1]).read()
anchor = "\t\t\tinclude ${HOME_DIR}/badge-host-shift-board.conf;\n"
assert s.count(anchor) == 1, "the board route's shift include is not where the control expects it"
open(sys.argv[2], "w").write(s.replace(anchor, "\t\t\tinclude ${HOME_DIR}/badge-host.conf;\n"))
PYEOF
UI_DIR=${D}/mutant-ui-noshift bash ${D}/mutant/home-render-noshift.sh > /dev/null 2>&1 || fail "the shift-less home-render.sh did not render"
sed -n '/server_name kanban.localhost;/,/^\t}/p' ${D}/mutant-ui-noshift/home/nginx.conf | grep -q 'include .*/badge-host-shift-board\.conf;' && fail "PLANTED CONTROL: a board route with the plain badge include passed the shift check"
sed 's#<style>[^<]*</style>##' "${UI_DIR}/home/badge-host-shift-board.conf" > "${D}/mutant/badge-host-shift-board-nostyle.conf"
shift_ok "${D}/mutant/badge-host-shift-board-nostyle.conf" 35vw 900 > "${D}/shift-c.log" && fail "PLANTED CONTROL: a shift file without its <style> passed"
grep -q 'does not set --hs-badge-shift' "${D}/shift-c.log" || fail "the shift control failed for the wrong reason: $(cat "${D}/shift-c.log")"
nolink_ok "${UI_DIR}/home/badge-host.conf" > "${D}/nolink-c.log" && fail "PLANTED CONTROL: badge-host.conf (which carries the link) passed as a nolink file"
grep -q 'carries a stylesheet link' "${D}/nolink-c.log" || fail "the nolink control failed for the wrong reason: $(cat "${D}/nolink-c.log")"
grep -v -F "${LINK}" "${UI_DIR}/home/site/index.html" > ${D}/mutant/index-nolink.html
page_ok ${D}/mutant/index-nolink.html > ${D}/page-c.log && fail "PLANTED CONTROL: a home page without the stylesheet link passed"
grep -q 'not in <head> exactly once' ${D}/page-c.log || fail "the page control failed for the wrong reason: $(cat ${D}/page-c.log)"
echo "ok 5 - the home page and the cheatsheet link the sheet once in <head> as .hs-root/.hs-page/.hs-header; the three badge files inject the root-relative link; badge-host-nolink.conf injects the badge alone; badge-host-clear-60.conf sets the claude-mem route's --hs-badge-offset, badge-host-shift-board.conf the kanban route's --hs-badge-shift from 900 px before the link and the badge, and that route alone takes it; controls: a page without the link fails, a nolink file with the link fails"

# --- 6. through nginx ---
if ! command -v nginx > /dev/null; then
	echo "Test-ui-style skipped checks 6-7: nginx not installed (setup/install-nginx.sh)"
	exit 0
fi
cat > ${D}/stub.py << 'PYEOF'
import sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        b = b"<!doctype html><html><head><title>stub</title></head><body><p>stub ui</p></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
servers = [ThreadingHTTPServer(("127.0.0.1", int(p)), H) for p in sys.argv[1:]]
for s in servers[1:]:
    threading.Thread(target=s.serve_forever, daemon=True).start()
servers[0].serve_forever()
PYEOF
python3 ${D}/stub.py ${UI_PORT_HEADLAMP} ${UI_PORT_HINDSIGHT_API} ${UI_PORT_HINDSIGHT_UI} ${UI_PORT_VIBE_KANBAN} ${UI_PORT_TMUX} \
	${UI_PORT_TMUX_AGENT} ${UI_PORT_CLAUDE_MEM} ${UI_PORT_LOGLEARNER} ${COMMS_UI_PORT} > ${D}/stub.log 2>&1 &
PIDS+=($!)
nginx -c "${CONF}" -g "daemon off;" > ${D}/nginx.log 2>&1 &
PIDS+=($!)
H=http://127.0.0.1:${UI_PORT_HOME}
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "${H}/" && break; sleep 0.2; done
curl -s -o /dev/null --max-time 2 "${H}/" || fail "the test nginx did not come up: $(tail -3 ${D}/nginx.log)"
WANT=$(sha256sum "${CSS}" | cut -d' ' -f1)
N=0
for HOST in localhost hindsight.localhost kanban.localhost claude-mem.localhost loglearner.localhost; do
	curl -s --max-time 5 -D ${D}/h.txt -o ${D}/b.css -H "Host: ${HOST}:${UI_PORT_HOME}" "${H}/__harness/harness.css" || fail "${HOST}: no answer for the stylesheet"
	grep -q '^HTTP/1.1 200' ${D}/h.txt || fail "${HOST}: the stylesheet answered $(head -1 ${D}/h.txt)"
	grep -qi '^Content-Type: text/css' ${D}/h.txt || fail "${HOST}: the stylesheet is not text/css: $(grep -i content-type ${D}/h.txt)"
	grep -qi '^Cache-Control: no-store' ${D}/h.txt || fail "${HOST}: the stylesheet is cacheable: $(grep -i cache-control ${D}/h.txt)"
	[ "$(sha256sum ${D}/b.css | cut -d' ' -f1)" == "${WANT}" ] || fail "${HOST}: the served stylesheet differs from ${CSS}"
	N=$((N + 1))
done
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -d x=1 -H "Host: hindsight.localhost:${UI_PORT_HOME}" "${H}/__harness/harness.css")
[ "${CODE}" == "405" ] || fail "a POST to the stylesheet answered ${CODE}, not 405"
# body <url> [<host header>] - the proxied body as the browser would get it (no gzip asked)
body() { if [ -n "$2" ]; then curl -s --max-time 5 -H "Host: $2" "$1"; else curl -s --max-time 5 "$1"; fi; }
M=0
check_page()
{
	# check_page <label> <body> - the link once, the badge once, no link to another host
	[ "$(echo "$2" | grep -oF "${LINK}" | wc -l)" == "1" ] || fail "$1: the page carries the stylesheet link $(echo "$2" | grep -oF "${LINK}" | wc -l) times (want exactly 1)"
	[ "$(echo "$2" | grep -o 'class="hs-badge"' | wc -l)" == "1" ] || fail "$1: the page carries the badge $(echo "$2" | grep -o 'class="hs-badge"' | wc -l) times (want exactly 1)"
	echo "$2" | grep -qE 'rel="stylesheet" href="(https?:)?//' && fail "$1: the page carries a stylesheet link to another host"
	M=$((M + 1))
}
# the pages the proxy injects the badge into: the path routes with a badge include (the terminal and the memory API docs
# too: every UI carries the badge) and every host route
for P in /headlamp/ /comms/ /tmux-agent/ /tmux/ /memory-api/docs; do
	B=""
	for _ in $(seq 1 25); do B=$(body "${H}${P}"); [ -n "${B}" ] && break; sleep 0.2; done
	check_page "${P}" "${B}"
done
# the page it does not inject into: the cheatsheet (a static page of the home listener, which links the sheet in its own
# head) carries the link exactly once, and no stylesheet on another host
check_plain()
{
	# check_plain <label> <body> <links wanted>
	[ "$(echo "$2" | grep -oF "${LINK}" | wc -l)" == "$3" ] || fail "$1: the page carries the stylesheet link $(echo "$2" | grep -oF "${LINK}" | wc -l) times (want $3)"
	echo "$2" | grep -qE 'rel="stylesheet" href="(https?:)?//' && fail "$1: the page carries a stylesheet link to another host"
}
check_plain /tmux-help/ "$(body "${H}/tmux-help/")" 1
for HOST in hindsight kanban claude-mem loglearner; do
	check_page "${HOST}.localhost" "$(body "${H}/" "${HOST}.localhost:${UI_PORT_HOME}")"
done
# the clearance reaches the page: the claude-mem host's page sets --hs-badge-offset:60px on its root exactly once; a host
# without a control in the badge's corner (hindsight) sets none
[ "$(body "${H}/" "claude-mem.localhost:${UI_PORT_HOME}" | grep -o -- '--hs-badge-offset:60px' | wc -l)" == "1" ] || fail "the claude-mem page does not carry its 60 px badge clearance exactly once"
body "${H}/" "hindsight.localhost:${UI_PORT_HOME}" | grep -q -- '--hs-badge-offset' && fail "the hindsight page carries a badge clearance it does not need"
HOME_BODY=$(body "${H}/")
[ "$(echo "${HOME_BODY}" | grep -oF "${LINK}" | wc -l)" == "1" ] || fail "the home page carries the stylesheet link $(echo "${HOME_BODY}" | grep -oF "${LINK}" | wc -l) times (want exactly 1)"
# the planted control: the mutant config of check 4 on other ports
sed -e "s/listen 127.0.0.1:${UI_PORT_HOME}/listen 127.0.0.1:${MUTANT_PORT}/" ${D}/mutant-ui/home/nginx.conf > ${D}/mutant-ui/home/nginx-ports.conf
nginx -c ${D}/mutant-ui/home/nginx-ports.conf -g "daemon off;" > ${D}/nginx-mutant.log 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${MUTANT_PORT}/" && break; sleep 0.2; done
curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${MUTANT_PORT}/" || fail "the control's nginx did not come up: $(tail -3 ${D}/nginx-mutant.log)"
# without its route the request falls through to the host's `location /` and the UPSTREAM answers it (here the stub's
# html; a real app's 404) - whatever it is, it is not the stylesheet, which is what the check above measures
curl -s --max-time 5 -D ${D}/hm.txt -o ${D}/bm.css -H "Host: hindsight.localhost:${MUTANT_PORT}" "http://127.0.0.1:${MUTANT_PORT}/__harness/harness.css"
if [ "$(sha256sum ${D}/bm.css | cut -d' ' -f1)" == "${WANT}" ] || grep -qi '^Content-Type: text/css' ${D}/hm.txt; then
	fail "PLANTED CONTROL: the mutant config without the hindsight route still served the stylesheet on hindsight.localhost ($(head -1 ${D}/hm.txt))"
fi
curl -s --max-time 5 -o ${D}/bm2.css -H "Host: loglearner.localhost:${MUTANT_PORT}" "http://127.0.0.1:${MUTANT_PORT}/__harness/harness.css"
[ "$(sha256sum ${D}/bm2.css | cut -d' ' -f1)" == "${WANT}" ] || fail "the mutant config's other hosts should still serve the stylesheet (loglearner.localhost did not)"
echo "ok 6 - the stylesheet answers with the file's bytes, text/css and no-store on ${N} hosts, POST is 405; ${M} badge-injected pages (the terminal and the API docs among them) carry the link and the badge exactly once, the cheatsheet its own link once, no page links another host; the home page links it once; control: without its route hindsight.localhost answers the upstream's page, not the stylesheet ($(grep -i '^Content-Type' ${D}/hm.txt | tr -d '\r')); the claude-mem page carries its 60 px clearance once, hindsight's none"

# --- 7. in a browser ---
if ! python3 -c "import playwright" 2>/dev/null; then
	echo "Test-ui-style skipped check 7: Python Playwright is not installed here (pip install playwright; python3 -m playwright install chromium); run /test-lib/ui-style-browser.py on a host that has it, against this deployment"
	echo "Test-ui-style succeeded (checks 1-6)"
	exit 0
fi
python3 "${BASE_DIR}/test-lib/ui-style-browser.py" --base "${H}" --css "${CSS}" --hosts hindsight,loglearner --out ${D}/shots > ${D}/browser.log 2>&1 \
	|| fail "the browser checks: $(grep -E 'FAILED|Error' ${D}/browser.log | head -3 | tr '\n' ' ')"
echo "ok 7 - $(grep -c '^ok B' ${D}/browser.log) browser checks: $(grep '^ok B' ${D}/browser.log | cut -c1-110 | tr '\n' ';')"

echo "Test-ui-style succeeded"
