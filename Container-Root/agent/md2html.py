#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""md2html.py - render a Markdown document to the harness's static page HTML, with no third-party module.

A link's target may be http(s)://, a same-origin path (/...) or an anchor (#...); any other target (javascript:, data:,
vbscript:, a protocol-relative //host, a relative path) is not a link: its text alone is shown, so a document cannot
smuggle a script or send the reader to another site. A picture, ![alt](target), is shown when its target is a picture of
the repository's docs/img folder (an .svg or .png, served by the home listener at /guide/img/) or a same-origin path;
any other picture shows its alt text alone.

    md2html.py <file.md> [--title TITLE] [--subtitle TEXT]   the page on stdout
    md2html.py --self-test                                   planted Markdown, expected HTML; exit 1 on a mismatch

The subset the harness docs use: # and ## headings (the first # heading is the page title unless --title is given),
paragraphs, "-" and "1." lists (one level of "  -" nesting), fenced code blocks, tables with a |---| separator,
**bold**, *emphasis*, `code`, [text](url) links, ![alt](picture) pictures and bare http(s) URLs, and CommonMark's backslash
escapes outside code:
\\* \\_ \\\\ \\` \\# \\[ \\] \\( \\) \\! \\< \\> \\| \\~ \\. \\- render the character itself, so **YES\\*** reads YES*, as on
GitHub, and an escaped pipe does not end a table cell. Everything is HTML-escaped first, so a document cannot inject
markup; links open in the same tab unless they leave the page's origin (then target=_blank). The page carries the home
page's chrome: a dark header with a "Harness home" link back to /.
"""
import html
import re
import sys

INLINE = [
    (re.compile(r'`([^`]+)`'), r'<code>\1</code>'),
    (re.compile(r'\*\*([^*]+)\*\*'), r'<strong>\1</strong>'),
    (re.compile(r'(?<![*\w])\*([^*\n]+)\*(?![*\w])'), r'<em>\1</em>'),
    # a picture of the repository's docs/img (README.md and docs/manual name it relatively; the home listener serves the
    # folder at /guide/img/), or one at a same-origin path; any other picture shows its alt text alone, never a link
    (re.compile(r'!\[([^\]]*)\]\((?:\.\./)*docs/img/([A-Za-z0-9][A-Za-z0-9._-]*\.(?:svg|png))\)'), r'<img src="/guide/img/\2" alt="\1">'),
    (re.compile(r'!\[([^\]]*)\]\((/(?![/\\])[^)\s\\]*)\)'), r'<img src="\2" alt="\1">'),
    (re.compile(r'!\[([^\]]*)\]\([^()\s]*(?:\([^()\s]*\)[^()\s]*)*\)'), r'\1'),
    (re.compile(r'\[([^\]]+)\]\((https?://[^)\s]+)\)'), r'<a href="\2" target="_blank" rel="noopener">\1</a>'),
    # a same-origin target: one slash (not // and not /\, which a browser reads as another host) or an anchor, and no
    # backslash anywhere in it
    (re.compile(r'\[([^\]]+)\]\(((?:/(?![/\\])|#)[^)\s\\]*)\)'), r'<a href="\2">\1</a>'),
    (re.compile(r'(?<![="\w/])(https?://[^\s<)`\x01]*[^\s<)`.,;:\x01])'), r'<a href="\1" target="_blank" rel="noopener">\1</a>'),
    # any other link target (a relative path, another scheme) is not a link: its text alone is shown
    (re.compile(r'\[([^\]]+)\]\([^()\s]*(?:\([^()\s]*\)[^()\s]*)*\)'), r'\1'),
]

# CommonMark's backslash escapes, matched on the HTML-escaped text (where < and > read &lt; and &gt;); a code span is
# matched in the same left-to-right pass and left alone, since a backslash inside one is literal
ESCAPE = re.compile(r'(`[^`]+`)|\\([*_\\`#\[\]()!|~.\-]|&lt;|&gt;)')

def inline(text):
    out = html.escape(text, quote=True)
    # backslash escapes first: each escaped character is held behind a placeholder until the end, so it is never markup
    # (an escaped backtick opens no code span, an escaped * no emphasis, an escaped [ no link)
    escaped = []
    def hold_escape(m):
        if m.group(1):
            return m.group(1)
        escaped.append(m.group(2))
        return '\x01%d\x01' % (len(escaped) - 1)
    out = ESCAPE.sub(hold_escape, out)
    # code spans next, then held out of the other rules behind placeholders, so a bold or a link may span a code
    # span while a ** or a URL inside a code span stays literal
    spans = []
    def hold(m):
        spans.append(m.group(0))
        return '\x00%d\x00' % (len(spans) - 1)
    out = re.sub(r'<code>.*?</code>', hold, INLINE[0][0].sub(INLINE[0][1], out))
    for rx, rep in INLINE[1:]:
        out = rx.sub(rep, out)
    out = re.sub(r'\x00(\d+)\x00', lambda m: spans[int(m.group(1))], out)
    return re.sub(r'\x01(\d+)\x01', lambda m: escaped[int(m.group(1))], out)


def slug(text, seen=None):
    """GitHub's heading anchor: lower case, spaces to hyphens, punctuation dropped (markup first); a repeated
    heading gets -1, -2, ... like GitHub, when a `seen` dict is given."""
    plain = re.sub(r'<[^>]+>', '', text)
    plain = html.unescape(plain).lower()
    plain = re.sub(r'[^\w\s-]', '', plain)
    s = re.sub(r'\s+', '-', plain.strip())
    if seen is None:
        return s
    n = seen.get(s, 0)
    seen[s] = n + 1
    return s if n == 0 else f'{s}-{n}'

def cells_of(row):
    # a table row's cells: a pipe ends a cell unless a backslash escapes it (\|, which inline() renders as a pipe); a
    # backslash escapes only the character after it, so an escaped backslash (\\) before a pipe leaves that pipe a delimiter
    cells, cell, i, row = [], '', 0, row.strip()
    while i < len(row):
        if row[i] == '\\' and i + 1 < len(row):
            cell += row[i:i + 2]
            i += 2
            continue
        if row[i] == '|':
            cells.append(cell)
            cell = ''
        else:
            cell += row[i]
        i += 1
    cells.append(cell)
    # the row's own leading and trailing pipes open and close it: drop the empty cells they leave
    if cells and row.startswith('|'):
        cells = cells[1:]
    if len(cells) > 1 and not cells[-1].strip():
        cells = cells[:-1]
    return [c.strip() for c in cells]

def table(rows):
    cells = [cells_of(r) for r in rows]
    head, body = cells[0], cells[2:]
    out = ['<table>', '<tr>' + ''.join(f'<th>{inline(c)}</th>' for c in head) + '</tr>']
    for r in body:
        out.append('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>')
    out.append('</table>')
    return out

def render_body(md):
    out, i, lines = [], 0, md.split('\n')
    title, seen_slugs = None, {}
    while i < len(lines):
        line = lines[i]
        if line.startswith('```'):
            j = i + 1
            while j < len(lines) and not lines[j].startswith('```'):
                j += 1
            out.append('<pre><code>' + html.escape('\n'.join(lines[i + 1:j])) + '</code></pre>')
            i = j + 1
            continue
        m = re.match(r'^(#{1,4})\s+(.*)$', line)
        if m:
            level = len(m.group(1))
            if level == 1 and title is None:
                title = m.group(2).strip()
            else:
                h = inline(m.group(2).strip())
                out.append(f'<h{level} id="{slug(h, seen_slugs)}">{h}</h{level}>')
            i += 1
            continue
        if line.startswith('|') and i + 1 < len(lines) and re.match(r'^\|[\s:|-]+\|?\s*$', lines[i + 1]):
            j = i
            while j < len(lines) and lines[j].startswith('|'):
                j += 1
            out += table(lines[i:j])
            i = j
            continue
        m = re.match(r'^(\s*)([-*]|\d+\.)\s+(.*)$', line)
        if m:
            kind = 'ol' if m.group(2)[0].isdigit() else 'ul'
            out.append(f'<{kind}>')
            open_sub = False
            item = None  # the pending item's text: its continuation lines are joined before the inline rules run

            def flush():
                nonlocal item
                if item is not None:
                    out.append(f'<li>{inline(item)}</li>')
                    item = None
            while i < len(lines):
                m = re.match(r'^(\s*)([-*]|\d+\.)\s+(.*)$', lines[i])
                if not m:
                    # a continuation line of the item (indented text), or a fenced block inside the list
                    if lines[i].startswith('  ') and lines[i].strip() and not lines[i].strip().startswith('```') and item is not None:
                        item = item + ' ' + lines[i].strip()
                        i += 1
                        continue
                    if lines[i].strip().startswith('```'):
                        flush()
                        j = i + 1
                        while j < len(lines) and not lines[j].strip().startswith('```'):
                            j += 1
                        block = '\n'.join(l[2:] if l.startswith('  ') else l for l in lines[i + 1:j])
                        out.append('<pre><code>' + html.escape(block) + '</code></pre>')
                        i = j + 1
                        continue
                    break
                flush()
                indent, text = len(m.group(1)), m.group(3).strip()
                if indent >= 2:
                    if not open_sub:
                        out.append('<ul>')
                        open_sub = True
                else:
                    if open_sub:
                        out.append('</ul>')
                        open_sub = False
                item = text
                i += 1
            flush()
            if open_sub:
                out.append('</ul>')
            out.append(f'</{kind}>')
            continue
        if not line.strip():
            i += 1
            continue
        j = i
        para = []
        while j < len(lines) and lines[j].strip() and not re.match(r'^(#{1,4}\s|```|\||\s*([-*]|\d+\.)\s)', lines[j]):
            para.append(lines[j].strip())
            j += 1
        out.append('<p>' + inline(' '.join(para)) + '</p>')
        i = j
    return title, '\n'.join(out)

PAGE = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} - do-agent-aws harness</title>
<style>
body {{ font: 15px/1.55 system-ui, sans-serif; margin: 0; background: #f4f5f7; color: #1a1a1a; }}
header {{ background: #232f3e; color: #fff; padding: 18px 28px; display: flex; align-items: baseline; gap: 18px; flex-wrap: wrap; }}
header h1 {{ margin: 0; font-size: 20px; }}
header p {{ margin: 0; opacity: .8; font-size: 13px; }}
header a.home {{ margin-left: auto; color: #fff; background: #0972d3; border-radius: 6px; padding: 5px 12px; font-size: 13px; text-decoration: none; }}
main {{ max-width: 880px; padding: 8px 28px 32px; }}
h2 {{ font-size: 17px; margin: 28px 0 8px; }}
h3 {{ font-size: 15px; margin: 20px 0 6px; }}
table {{ border-collapse: collapse; width: 100%; background: #fff; border: 1px solid #e0e2e6; border-radius: 8px; margin: 8px 0; }}
th, td {{ padding: 7px 12px; border-top: 1px solid #eef0f3; font-size: 14px; vertical-align: top; text-align: left; }}
tr:first-child th {{ border-top: none; background: #eef0f3; }}
code {{ background: #e9ebee; border-radius: 4px; padding: 1px 5px; font: 13px ui-monospace, monospace; }}
pre {{ background: #232f3e; color: #fff; border-radius: 8px; padding: 12px 14px; overflow-x: auto; }}
pre code {{ background: none; color: inherit; padding: 0; }}
li {{ margin: 3px 0; }}
a {{ color: #0972d3; }}
</style>
</head>
<body>
<header>
<h1>{title}</h1>
<p>{subtitle}</p>
<a class="home" href="/">Harness home</a>
</header>
<main>
{body}
</main>
</body>
</html>
'''

def self_test():
    md = ('# Doc title\n\nIntro with **bold**, *em*, `a <code> span` and a [link](/guide/) plus http://x.test/p.\n\n'
          '**one `agent` session** and `f(**kw)`\n\n'
          '[js](javascript:alert(1)) [JS](JaVaScRiPt:alert(1)) [data](data:text/html,x) [vb](vbscript:x) [cut](javascript:) [pr](//evil.example/) [rel](other/page) [ok](/guide/) [anc](#steps)\n\n'
          '[bs](/\\evil.example) [bs2](/\\/evil.example) [bs3](/guide/x\\y)\n\n'
          '![one](docs/img/a.svg) ![two](../../docs/img/b.png) ![abs](/guide/img/c.svg) ![rel](other/x.svg) ![js](javascript:alert(1)) ![pr](//evil.example/x.svg) ![bad](docs/img/../x.svg)\n\n'
          '## Steps\n\ntext\n\n'
          '## Steps\n1. First `one`\n2. Second\n\n- bullet <script>alert(1)</script>\n  - nested\n- last\n- a span `across\n  two` lines, then http://h.test/p`x\n\n'
          '```\nrm -rf "${D:?}"\n```\n\n| Symptom | Check |\n|---|---|\n| grey | `./status.sh` |\n\n'
          '**YES\\*** and \\*plain\\* \\_x\\_ \\\\ \\# \\[not a link\\](/guide/) \\<b\\> \\! \\~ \\. \\- \\(a\\) \\`no code\\` and `a\\*b`; http://x.test/q\\.\n\n'
          '| Verdict | Note |\n|---|---|\n| **YES\\*** | a \\| b |\n| x \\\\| y |\n')
    title, body = render_body(md)
    want = ('<p>Intro with <strong>bold</strong>, <em>em</em>, <code>a &lt;code&gt; span</code> and a <a href="/guide/">link</a> plus '
            '<a href="http://x.test/p" target="_blank" rel="noopener">http://x.test/p</a>.</p>\n'
            '<p><strong>one <code>agent</code> session</strong> and <code>f(**kw)</code></p>\n'
            '<p>js JS data vb cut pr rel <a href="/guide/">ok</a> <a href="#steps">anc</a></p>\n'
            '<p>bs bs2 bs3</p>\n'
            '<p><img src="/guide/img/a.svg" alt="one"> <img src="/guide/img/b.png" alt="two"> <img src="/guide/img/c.svg" alt="abs"> rel js pr bad</p>\n'
            '<h2 id="steps">Steps</h2>\n<p>text</p>\n'
            '<h2 id="steps-1">Steps</h2>\n<ol>\n<li>First <code>one</code></li>\n<li>Second</li>\n</ol>\n'
            '<ul>\n<li>bullet &lt;script&gt;alert(1)&lt;/script&gt;</li>\n<ul>\n<li>nested</li>\n</ul>\n<li>last</li>\n<li>a span <code>across two</code> lines, then <a href="http://h.test/p" target="_blank" rel="noopener">http://h.test/p</a>`x</li>\n</ul>\n'
            '<pre><code>rm -rf &quot;${D:?}&quot;</code></pre>\n'
            '<table>\n<tr><th>Symptom</th><th>Check</th></tr>\n<tr><td>grey</td><td><code>./status.sh</code></td></tr>\n</table>\n'
            '<p><strong>YES*</strong> and *plain* _x_ \\ # [not a link](/guide/) &lt;b&gt; ! ~ . - (a) `no code` and <code>a\\*b</code>; '
            '<a href="http://x.test/q" target="_blank" rel="noopener">http://x.test/q</a>.</p>\n'
            '<table>\n<tr><th>Verdict</th><th>Note</th></tr>\n<tr><td><strong>YES*</strong></td><td>a | b</td></tr>\n<tr><td>x \\</td><td>y</td></tr>\n</table>')
    ok = title == 'Doc title' and body == want
    if not ok:
        print('md2html self-test FAILED\n--- got ---\n' + body + '\n--- want ---\n' + want)
        return 1
    print('md2html self-test ok: headings with anchors (duplicates suffixed), lists with nesting, fenced code, a table, inline marks across code spans, escaped markup, pictures from docs/img or a same-origin path only, links to http(s)/paths/anchors only - javascript:, data:, vbscript:, //host, /\\host, backslashes and relative targets show their text; a code span may cross a list continuation line; a URL stops at a backtick; backslash escapes render the character (YES\\* reads YES*), not inside code, and an escaped pipe stays in its cell while an escaped backslash before a pipe leaves it a delimiter')
    return 0

if __name__ == '__main__':
    args = sys.argv[1:]
    if args == ['--self-test']:
        sys.exit(self_test())
    title_opt = subtitle = None
    files = []
    while args:
        a = args.pop(0)
        if a == '--title':
            title_opt = args.pop(0)
        elif a == '--subtitle':
            subtitle = args.pop(0)
        else:
            files.append(a)
    if len(files) != 1:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    title, body = render_body(open(files[0], encoding='utf-8').read())
    print(PAGE.format(title=html.escape(title_opt or title or files[0]), subtitle=html.escape(subtitle or ''), body=body))
