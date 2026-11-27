---
name: pptx-slide-creation
description: Use when creating, modifying, or inserting slides into PowerPoint PPTX files using python-pptx. Use when matching existing slide deck styling, extracting font colors and positions from existing slides, reordering slides, or visually verifying slide output. Use when PPTX text overlaps, slides are in wrong order, or duplicate zip entries corrupt the file.
---

# PowerPoint Slide Creation with python-pptx

## Overview

Create and modify PPTX presentations programmatically using `python-pptx`. The critical workflow: extract styling from existing slides first, then create new slides matching those exact positions, colors, and font sizes. Never guess styling — always measure from the source deck.

## When to Use

- Adding slides to an existing presentation deck
- Creating new PPTX from scratch with consistent styling
- Matching an existing deck's color scheme, fonts, and layout
- Inserting slides at a specific position (reordering)
- Visually verifying slide output without opening PowerPoint

## Core Pattern: Extract → Create → Reorder → Fix → Verify

### Step 1: Extract Styling from Existing Deck

```python
from pptx import Presentation
from pptx.util import Pt, Emu

prs = Presentation('existing.pptx')

# List all available layouts
for i, layout in enumerate(prs.slide_layouts):
    print(f'[{i}] {layout.name}')

# Extract exact positions and font styling from reference slide
for slide in prs.slides:
    for shape in slide.shapes:
        if not hasattr(shape, 'text_frame') or not shape.text.strip():
            continue
        print(f"Shape: left={shape.left} top={shape.top} w={shape.width} h={shape.height}")
        for para in shape.text_frame.paragraphs:
            for run in para.runs:
                f = run.font
                try:
                    color = str(f.color.rgb) if f.color and f.color.type is not None else 'theme'
                except AttributeError:
                    color = 'theme'
                print(f"  '{run.text[:50]}' size={f.size} bold={f.bold} color={color}")
```

**Critical**: Font sizes in python-pptx are in EMU (English Metric Units), not points.
- `Pt(14)` = 177800 EMU
- Raw values from extraction: `304800` = 24pt, `152400` = 12pt, `114300` = 9pt

### Step 2: Create Slides Matching Style

```python
from pptx.dml.color import RGBColor

# Use extracted constants — never hardcode without measuring first
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
PINK = RGBColor(0xE4, 0x33, 0xFF)    # from source deck

layouts = {l.name: l for l in prs.slide_layouts}
title_layout = layouts.get('Title Only')

# Use layout placeholder for title (inherits theme styling)
slide = prs.slides.add_slide(title_layout)
for shape in slide.placeholders:
    shape.text = "My Title"
    break

# Add body content as text boxes at extracted positions
def add_box(slide, left, top, w, h, lines, size=14, color=WHITE):
    box = slide.shapes.add_textbox(Emu(left), Emu(top), Emu(w), Emu(h))
    tf = box.text_frame
    tf.word_wrap = True
    for i, line in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        run = p.add_run()
        run.text = line
        run.font.size = Pt(size)
        run.font.color.rgb = color
    return box
```

**Spacing trap**: Body content must start BELOW the title placeholder. Extract `BODY_TOP` from a reference slide — typically `2100000` EMU. Placing content at `1100000` causes overlap with titles.

### Step 3: Reorder Slides (Insert at Position)

New slides append to the end. Reorder via XML manipulation:

```python
sldIdLst = prs.part._element.find(
    './/{http://schemas.openxmlformats.org/presentationml/2006/main}sldIdLst'
)
refs = list(sldIdLst)

# Move slides 24-29 (new) to after slide 14
original = refs[:14]
new_slides = refs[24:]
rest = refs[14:24]

for r in refs:
    sldIdLst.remove(r)
for r in original + new_slides + rest:
    sldIdLst.append(r)
```

### Step 4: Fix Duplicate Zip Entries

Deleting and re-adding slides creates duplicate filenames in the PPTX zip. This corrupts the file for some readers. Fix by deduplicating:

```python
import zipfile, io

buf = io.BytesIO()
prs.save(buf)
buf.seek(0)

seen = {}
with zipfile.ZipFile(buf, 'r') as zin:
    for info in zin.infolist():
        seen[info.filename] = (info, zin.read(info.filename))

with zipfile.ZipFile('output.pptx', 'w', zipfile.ZIP_DEFLATED) as zout:
    for fn, (info, data) in seen.items():
        zout.writestr(info, data)
```

**Always deduplicate** after any slide deletion + re-creation cycle.

### Step 5: Visual Verification

Convert PPTX to images without PowerPoint:

```bash
# Install: sudo apt-get install -y libreoffice-impress poppler-utils

# PPTX → PDF
soffice --headless --convert-to pdf --outdir /tmp/slides deck.pptx

# PDF → PNG per slide
pdftoppm -png -r 150 -f 15 -l 20 /tmp/slides/deck.pdf /tmp/slides/slide
```

Then use the Read tool on the PNG files to visually inspect.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Text overlaps title | Extract `BODY_TOP` from reference slide (~2100000 EMU). Don't place content above it. |
| Two-line title overlaps subtitle | Use single-line titles in placeholder. Add subtitle as separate text box below. |
| Font size looks wrong | EMU not points. Use `Pt(14)` helper, not raw `14`. |
| Colors don't match | Extract RGB from source with `.color.rgb`. Wrap in try/except for theme colors. |
| Slides in wrong order | python-pptx only appends. Reorder via `sldIdLst` XML after all slides created. |
| PPTX won't open after edits | Duplicate zip entries. Run the deduplication fix. |
| LibreOffice can't convert | Duplicate zip entries. Deduplicate first, then convert. |
| Section divider has no title text | Section dividers use a different placeholder. Iterate `slide.shapes` not `slide.placeholders`. |

## Quick Reference: Position Constants

Extract these from YOUR source deck — these are examples from an AWS workshop deck:

```python
# Title placeholder position (from layout)
TITLE_LEFT = 486566    # ~0.5 inches from left
TITLE_TOP  = 650191    # ~0.7 inches from top
TITLE_W    = 10664687  # ~11 inches wide
TITLE_H    = 688619    # ~0.7 inches tall

# Body content start (below title)
BODY_TOP   = 2100000   # ~2.2 inches — first bullet line
BODY_LEFT  = 757647    # ~0.8 inches from left
BODY_W     = 10500000  # ~10.9 inches wide

# Two-column layout
LEFT_COL   = 757647    # left edge
LEFT_W     = 4800000   # ~5 inches
RIGHT_COL  = 6000000   # ~6.25 inches from left
RIGHT_W    = 5200000   # ~5.4 inches

# Slide dimensions (widescreen 16:9)
SLIDE_W    = 12192000  # 13.33 inches
SLIDE_H    = 6858000   # 7.5 inches
```

## Workflow Summary

1. `pip install python-pptx`
2. Extract styling from 2-3 reference slides (title, body, architecture)
3. Create slides using extracted positions and colors
4. Reorder via `sldIdLst` XML
5. Deduplicate zip entries
6. Convert to PNG and visually verify
7. Iterate on spacing until text doesn't overlap

<!-- imported on 2026-10-31 by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->
