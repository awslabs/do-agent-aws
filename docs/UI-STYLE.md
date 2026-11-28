# UI style: one stylesheet for every page the harness builds itself

Every page this harness renders on its own - the home page, the tmux cheatsheet and the pages of its own tiles - draws
its look from one stylesheet, `Container-Root/agent/ui/harness.css`
(`/agent/ui/harness.css` in the image). The home proxy serves it at the same path on every host it answers,
`/__harness/harness.css`, so a page on any `*.localhost` route loads it from its own origin: a Content-Security-Policy of
`style-src 'self'` admits it and no page ever fetches it across hosts. Third-party UIs (the memory UI, Headlamp,
vibe-kanban, the dashboards) get the stylesheet too, through the same `sub_filter` that injects the "Harness home" badge -
and since every rule in it is anchored on an `.hs-*` class (the bare `:root` blocks declare `--hs-` tokens and nothing
else; the colour scheme is set for `html.hs-root` and `body.hs-page`, never for a bare root), the badge is the only
thing it changes there - a UI whose own Content-Security-Policy lacks `style-src 'self'` refuses the injected link and
logs a CSP violation (or sends a report, if it configures one), and shows the badge in its fallback style. The whole
sheet sits in the cascade layer `hs`, so a page's own unlayered rules win over it wherever the `<link>` sits.

`Container-Root/test-ui-style.sh` proves each rule below with a planted control (see its header); its browser half,
`Container-Root/test-lib/ui-style-browser.py`, needs Python Playwright and a Chromium, which the image does not carry -
run it from a host that has them, against a deployment.

## Tokens

CSS custom properties, declared on `:root`. This is the whole vocabulary; code against these names and nothing else.

| Token | Role | Light | Dark |
|---|---|---|---|
| `--hs-bg` | the page | `#f4f5f7` | `#11161d` |
| `--hs-surface` | a tile, card, table, code block | `#ffffff` | `#1b2129` |
| `--hs-fg` | text | `#1a1a1a` | `#e6e9ee` |
| `--hs-muted` | secondary text, notes, table headings | `#5c6670` | `#aeb7c2` |
| `--hs-border` | hairlines | `#d5d9df` | `#303a46` |
| `--hs-accent` | links, focus rings, the live tile's hover | `#0b5cad` | `#8fc1ff` |
| `--hs-ok` | up, fresh, passed - a shape or a rule, never text | `#0ca30c` | same (fixed) |
| `--hs-stale` | answered, but old - a shape or a rule | `#fab219` | same (fixed) |
| `--hs-bad` | down, failed - a shape or a rule | `#d03b3b` | same (fixed) |
| `--hs-warn` | needs attention, not failed - a shape or a rule | `#ec835a` | same (fixed) |
| `--hs-radius` | corner radius | `8px` | |
| `--hs-font` | text | `system-ui, -apple-system, "Segoe UI", sans-serif` | |
| `--hs-mono` | code, terminal text | `ui-monospace, SFMono-Regular, Menlo, Consolas, monospace` | |
| `--hs-space-1` .. `--hs-space-4` | spacing scale | `4px` `8px` `14px` `28px` | |

The six surface and ink tokens are themed. The four **status tokens are fixed**: one step each in every theme (the
data-viz reference's status scale: good, warning, serious, critical), and they colour **shapes and rules only** - the
pill's disc, square or half disc, a tile's or callout's rule bar, a strip's cells - never text. A state's word is set in
`--hs-fg` (or `--hs-muted` for "off"). So every text pair the pages render reads at 4.5:1 or better (WCAG AA for normal
text): the three inks `fg`, `muted`, `accent` on `--hs-bg` and `--hs-surface`, the pill words on their tinted
backgrounds (the status step mixed 12% into the surface), the off tile's text, the header's and badge's white on the
harness ink - the test computes each rendered pair in the light theme and in both dark scopes (48 pairs plus the two
header/badge pairs; the two dark scopes are identical by construction and both are checked). The weakest is the light
off pill's `--hs-muted` word on its 12% tint at 4.98:1; the weakest plain pair is light `--hs-muted` on `--hs-bg` at 5.36:1. The status steps themselves are not held to a text ratio: on the light surface the
amber and orange steps sit below 3:1 by design, and a step's 12% tint reads low against the surface - the ring in the text
token carries the shape and the word carries the meaning (the test refuses a `color:` declaration that takes a status
token, in the sheet and in the pages). A callout (`.hs-error`) or a rule bar says its state in words too: its first
`<strong>` names it ("Down:", "Stale since ..."), because the ok and bad steps are near-identical under deuteranopia.

The header and the badge keep the harness's own ink (`#232f3e`, white text) in both themes; those two values live in
the stylesheet only.

## Components

| Class | What it is |
|---|---|
| `.hs-root` | on `<html>`: the viewport's colour scheme (scrollbars, canvas) follows the theme on the harness's own pages |
| `.hs-page` | on `<body>`: page background, text colour, the colour scheme of the page's controls, the fonts, box-sizing, link and focus colours, `code`/`kbd`/`pre`, form controls |
| `.hs-header` | the harness header bar: `h1`, a `p` subtitle, links; centred on the page's measure `--hs-max` (1700 px unless the page sets its own); tighter on a phone |
| `.hs-wrap` | a centred column of the page's measure `--hs-max` (1700 px by default) with the page gutter |
| `.hs-tiles` / `.hs-tile` | the tile grid (one column on a phone, up to six on a wide screen) and a tile: a `> a` title stretched over the whole tile (one click target), `p` purpose, `.hs-note`; states `.off` (greyed, dashed) and `.bad` (red left rule); `.hs-why` for the reason |
| `.hs-dot` | the state pill: a word (in the text token) AND a shape (ringed in the text token, filled with the fixed status step), never a colour alone. Default = ring + "checking…"; `.ok` disc + "up"; `.stale` half disc + "stale"; `.bad` square + "down"; `.off` dotted ring + "off". Empty, it labels itself from its state; with text inside, that text is the label (`<span class="hs-dot ok">fresh</span>`) |
| `.hs-stat` | a KPI tile: `.k` label, `.v` value, `.d` detail |
| `.hs-table` | a table whose cells carry `data-label="<heading>"`; below 700 px every row becomes a card of label/value lines and the heading row is hidden (still read by screen readers) |
| `.hs-card` | a surface panel; `> .hs-title`, `p`, `.hs-note` |
| `.hs-badge` | the Harness home badge, both placements (a path route's `href="/"`, a host route's `//<home host>/`). Rendered by `home-render.sh`'s `badge_html` - do not build another. Its clearance is the route's: `--hs-badge-offset` (below) |
| `.hs-empty` | an empty state: dashed, muted, centred |
| `.hs-error` | a callout whose left rule carries the status step (`--hs-bad`; `.warn` and `.ok` recolour the rule); its words stay in the text token |
| `.hs-code` | a block of code or output (`<pre class="hs-code">`): mono, surface, wraps long lines. Inline code is a plain `<code>` inside `.hs-page` |
| `.hs-muted`, `.hs-small`, `.hs-sr` | muted text, 13 px text, visually hidden text |

## Adopting it in a new page - five lines

1. In `<head>`: `<link rel="stylesheet" href="/__harness/harness.css">` (root-relative; never a host).
2. `<html lang="en" class="hs-root">`, `<body class="hs-page">` and `<header class="hs-header">`.
3. Build from the components above; where the page needs a rule of its own, write it against the tokens
   (`color: var(--hs-muted)`), never a hex; a status token colours a shape or a rule, a word stays in `--hs-fg`.
4. If the page is served on a host route of its own, its server block in `home-render.sh` includes
   `$(harness_css_location)` right after `set $proxy_upstream_host $http_host;` (the test fails a block without it),
   its location includes `badge-host-nolink.conf` instead of `badge-host.conf` (the page links the sheet itself, so the
   badge is injected without a second link), and its Content-Security-Policy keeps `style-src 'self'` (or
   `default-src 'self'`).
5. Add the page's files to `test-ui-style.sh`'s page list (the hex gate) and look at it at 1920x1080 and 390x844 in
   both themes before calling it done.

## The page's measure

`.hs-header` and `.hs-wrap` centre their content on `--hs-max`, 1700 px by default. A page laid out on another width sets
it once on its root and both follow - no header override needed:

```css
:root { --hs-max: 1500px; }
```

(`--hs-max`, `--hs-badge-offset` and `--hs-badge-shift` are layout knobs a page or route may set; they are not colour tokens and have no
dark-scope value.)

## Rules

- **Status is a word with a shape, and a status colour is never text.** `.hs-dot` and the home page's `.dot` carry a
  word and a shape; the four status tokens are fixed across themes and colour shapes and rules only. The test refuses a
  status token in `color`, `-webkit-text-fill-color`, `-webkit-text-stroke-color`, `text-emphasis-color` or
  `caret-color`, in the sheet and in the pages, and refuses a status token aliased through any custom property, `--hs-`
  named ones and `:root` tokens included (set the step where the shape or rule uses it, so the gate can see it). Status colours are reserved for states (never a priority or a category); a colour
  that means nothing is `--hs-muted`.
- **Both themes.** The stylesheet switches on `prefers-color-scheme`; `<html data-theme="light|dark">` overrides the OS
  both ways. A page that sets its own colours sets them from the tokens, so it switches too. Look at both.
- **390 px must work.** One column, the gutter at 16 px, the badge inside the viewport, no horizontal overflow; tables
  stack into cards. Test it at 390x844 and at 1920x1080.
- **No hardcoded colour** outside `harness.css` - no hex, no `rgb()`/`hsl()`/`lab()`/`oklch()`/`color()`, no colour name
  as a value, in a page's `<style>`, a script that builds markup, a Python string that renders a page. The test's gate
  fails on one; add a token (and this table, and the contrast check) rather than a colour. Comment text is not read, so
  an issue number in a comment (`#418`, `hindsight#5559`) is fine; the same digits in a declaration are a colour.
- **Nothing fetched.** No web font, no icon set, no `@import`, no `url()`. The pages render offline and through an SSH
  tunnel; the stylesheet is served from the page's own origin, never from another host.
- **Scope.** Every selector in the stylesheet is anchored on an `.hs-*` class (or `:root`); a third-party page that
  receives it must not change. The test fails a bare element selector.
- **A page served through the proxy that links the sheet in its `<head>` takes `badge-host-nolink.conf`** in its
  server block: the badge without a second link, so the sheet is fetched once (the page's own link in `<head>` is what
  prevents a flash of unstyled content). Third-party routes keep `badge-host.conf`, whose injected link styles the
  badge. Should both ever meet, the sheet in `@layer hs` cannot outrank the page's own rules.
- **`color-mix()` has no fallback.** A browser without it drops the tinted pill and hover backgrounds to transparent; the
  text keeps its AA contrast on the surface. `@layer`, `:where()` and `color-mix()` need a 2023-or-later browser.

## The badge's clearance

The badge floats in the bottom right corner. A UI that keeps a control of its own in that corner - a console toggle, a card panel's bottom buttons -
would be covered. The contract: **the badge's box meets no interactive element's box**, on the initial render and after
the application has replaced its DOM, at 1920x1080 and at 390x844. A route that needs clearance sets
`--hs-badge-offset` on its root - a length, the lift above the corner's resting place, `0px` by default:

```html
<style>:root { --hs-badge-offset: 56px; }</style>
```

A page this harness builds puts that in its own `<style>`; for a third-party route the proxy injects it with the badge
(`home-render.sh`, next to the route's badge include). The sheet applies it as a translation of `.hs-badge`, which
the markup's fallback style does not touch, so the lift holds wherever the badge rests.
`Container-Root/test-lib/ui-style-browser.py --badge-clear <host[,host]> --base <home> --css <sheet>` is the check for
every adopter: exactly one badge, inside the viewport, over no control (in the document and in open shadow roots; an
iframe's own document is not seen), before and after a simulated DOM replacement; its planted controls are a button in
the corner the badge takes on the desktop and on the phone. Measure, then set the smallest offset that clears the control.

A lift cannot clear a UI whose controls form a full-height column at the badge's own edge - a card panel on the right whose
comment composer, error box and row menus reach the panel's bottom in some state. Such a route moves the badge aside
instead: `--hs-badge-shift` on its root, a length the badge is translated to the left, set from a viewport width on so
that a phone, where the panel is the whole width, keeps the resting corner:

```html
<style>@media (min-width: 900px) { :root { --hs-badge-shift: 35vw; } }</style>
```

`home-render.sh`'s `badge_host_shift_conf <name> <length> <from px>` writes that include; the kanban board's route takes
`badge-host-shift-board.conf` (measured with a card open: the panel's left edge at 1036 px of 1440 and 1451 of 1920; a
35vw shift lands the badge over the board columns' empty bottoms). The `--badge-clear` check takes `--sizes`, `--referer-home`
(for a route whose sign-in admits the home page's tile click only), `--path` (the path to load, a sign-in path) and
`--open-first <selectors>` (before measuring, an element matching one of them - | separated, in order of preference, the first few matches of each - is clicked until a page of its own opens: a board's card, which opens its panel; a size where no click opens one loads the card an earlier size opened, the phone layout's case, so a wide size goes first), and plants its control at the
badge's own box wherever it rests.

Two limits of the lift: it lives in the sheet, so a route whose own Content-Security-Policy refuses the sheet gets the
badge in its fallback style and no clearance; and the offset must be a length with a unit (`60px`) - a unitless value
makes the `calc()` invalid and the lift silently zero. The check catches both, since it measures the badge where it is.

In the home proxy the clearance travels with the badge: `home-render.sh` writes `badge-host-clear-<px>.conf`
(`badge_host_clearance_conf <px>`), the host-routed badge file whose one replacement sets `--hs-badge-offset:<px>px` on
the root right before the stylesheet link and the badge, and a route that needs it includes that file instead of
`badge-host.conf`. One route does today: the claude-mem viewer (`BADGE_CLAUDE_MEM_CLEARANCE`, 60 px), whose console
toggle sits at the phone's bottom left where the badge lands (measured at 390x844: a 48 px button at y 776-824 under a
badge at y 804-834); `test-ui-style.sh` proves the file, the route and the rendered page, and a route without a control
in the corner carries no clearance.

## The LogLearner dashboard

The dashboard under `/opt/loglearner` is vendored and edited nowhere in this repository (`VENDORED.md`); its owner's
constraint is a single stdlib file whose CSS is an inline constant that can copy a token block but never fetch one.
Its maintainer pastes the token block (the `:root` and dark-scope declarations above, byte for byte) into that constant
and maps the dashboard's variables to it; the vendored copy here changes when a release carries it:

| dashboard variable | token | dashboard variable | token |
|---|---|---|---|
| `--page` | `var(--hs-bg)` | `--surface` | `var(--hs-surface)` |
| `--ink` | `var(--hs-fg)` | `--ink2`, `--muted` | `var(--hs-muted)` |
| `--grid`, `--axis`, `--border` | `var(--hs-border)` | `--good` `#0ca30c` | `var(--hs-ok)` `#0ca30c` |
| `--warn` `#fab219` | `var(--hs-stale)` `#fab219` | `--serious` `#ec835a` | `var(--hs-warn)` `#ec835a` |
| `--crit` `#d03b3b` | `var(--hs-bad)` `#d03b3b` | links | `var(--hs-accent)` |

The four status steps are the dashboard's own fixed values (it keeps them in both of its themes today), so the mapping
changes nothing in its status palette; the names cross on purpose (`--warn` → `--hs-stale`, `--serious` → `--hs-warn`):
the harness names the states, the dashboard names the severities, and the values are the same. Its chart series colours (`--s1 --s2 --s3 --seq`) stay its own validated data-viz
palette: they colour marks, not text.
