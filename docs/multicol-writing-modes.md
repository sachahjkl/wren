# Multi-column layout and writing modes

Columns (CSS Multicol 1, CSS Fragmentation 3) and vertical text (CSS Writing Modes 4). Demos: `examples/site/multicol.html` and
`examples/site/vertical.html`, in the demos page.

```css
article { columns: 3 16em; column-gap: 2em; column-rule: 1px solid #ccc; }
article h2 { column-span: all; }
article figure { break-inside: avoid; }

.ja { writing-mode: vertical-rl; }
.ja .year { text-combine-upright: all; }
```

## What there is

| | |
|---|---|
| `columns`, `column-count`, `column-width`, `column-gap` | the used count and width as specified; `normal` gap is 1em |
| `column-rule-*`, `column-rule` | painted between columns that have content; each style of border |
| `column-span: all` | a spanner in the block flow of the container: it ends a set of columns; the sets are balanced on their own |
| `column-fill` | `balance`, `auto` in a definite height; `balance-all` as `balance` |
| `break-before`, `break-after`, `break-inside` | forced breaks (`column`, `page`, `always`, `left`...), `avoid`, `avoid-column`; the legacy `page-break-*` and `-webkit-column-break-*` |
| `orphans`, `widows` | |
| Overflow columns | past the count in a limited height: they go on in the inline direction, and are scrollable overflow |
| `writing-mode` | `horizontal-tb`, `vertical-rl`, `vertical-lr`, `sideways-rl`, `sideways-lr`, the SVG names |
| `text-orientation` | `mixed` (upright by a table after UTR #50), `upright`, `sideways` |
| `text-combine-upright` | `all`: squeezed into an em |
| Flow-relative properties | margins, padding, insets, borders, radii, sizes: mapped per element for its writing mode and its direction |
| Orthogonal flows | a vertical box in a horizontal one and the other way round; fit-content in the available size; percentages |
| Flex, grid, tables, floats, positioned boxes | inside vertical text, in their logical axes |
| Queries | `getBoundingClientRect` the union of the fragments, `getClientRects` one per fragment (and per line for an inline box), hit testing, selection and find per column and along vertical lines |

## How columns work

`src/layout/multicol.odin`. A container's content is laid out in one strip as wide as a column, by the block layout as it is, then
cut:

1. `gather_units` lists what must not be cut (lines, replaced boxes, scroll containers, flex lines and grid rows, table rows,
   `break-inside: avoid`) with their forced breaks, avoided breaks (`orphans`, `widows` are chains of avoided breaks), and how much of the
   space above them is margins, which a break takes away.
2. `place_units` sends the units into columns of a given height. It touches no box: balancing tries heights from the strip's height
   shared out, growing by what the break that hurts lacked. No second layout of the content.
3. `apply_shifts` moves the boxes for the height found. The strip is now the "flow": each column is a band of it, and a box with
   nothing that must stay whole in it may lie across bands (a tall empty box, a background).

A container inside the flow of another stays whole in the outer column where it starts when it fits; when it would cross it, the outer one (given a height or balanced) lays its content out again with that container in rows of columns (`Mc_Rows`): all of what the outer column leaves, then the next outer column; what must stay whole and is too tall for what is left waits for the next one. Its columns are spaces under the outer column they show in. Column rules reach the content edge of a container with a height of its own, or the end of the outer column, however low its columns are balanced.

The containing block of a spanner is its container, whatever lies between them: for what is positioned in it (`child_frame`), for anchors, for `offsetParent`.

A column is a fragment: a band of the flow and the translation to where it shows (`Mc_Frag`). Finishing makes a space per column
(`Space_Kind.Column`) under a space of the flow (`Space_Kind.Flow`), which the boxes inside point to; `push_item` makes of every display
item in the flow space one copy per column it lies in, clipped to the band. Hit testing, culling, the compositor and painting then know nothing of
columns. A box with a space of its own (a transform, a scroll port, a nested container) hangs from the column where it starts, and is not cut.

An incremental pass that reaches the container lays out all that is in it again (the strip is moved, so caches inside are dropped by `mark_flow`);
a pass that does not reach it keeps its result. No splicing of the display list, no layout threads on a page with columns.

## How writing modes work

`src/layout/frames.odin`. The layout code knows one geometry: x is inline, y is block. A vertical box is laid out in that geometry too, in the logical
coordinates of its *frame*, and made physical when the block layout of the pass is over: everything after (finishing, the display list,
queries, the painter) sees physical boxes.

- The frame of a box is the writing mode of its containing block. Its own margins, borders, padding, size and position are in that frame; its content
  is in the frame of its own mode. A box whose own mode differs is a frame root: an independent formatting context, and `frame_layout_contents` turns it
  from one to the other for the time of its content.
- Style: during the block layout a box points to a copy of its record with `width` under `height` and each side under its logical name (`transposed`). What
  is flow-relative already stays: `flex-direction`, `grid-template-columns`, `align-*`, `justify-*`, `text-align`. So flex, grid and tables have no code for writing modes.
- `frames_to_physical` saves what it changes; `frames_to_logical` puts it back at the next pass, exactly: the layout caches of the boxes (which are
  logical) hold across passes, and a vertical page has incremental layout as any other. It is checked against full passes as any other (`layout.incremental.verify`).
- The viewport takes the mode and the direction of the body, else the root element (the principal writing mode). A `vertical-rl` document starts at the right and scrolls to the left (`doc_min_x`); one whose lines run upwards (`vertical-*` with `direction: rtl`, `sideways-lr`) starts at the bottom and scrolls up, with negative offsets (`doc_min_y`). In a scroll container too, the end margins of what is in it count where its axes end.
- Text: a font in vertical text has a central baseline (`Font_Vmode.Central`: half of the face's height on each side), the `vert` feature on, and a length along
  the line made of upright clusters (an em for what has an em box, else the face's height) and sideways runs. The painter draws upright clusters one by one and
  sideways runs through a rotation (`draw_vertical_text`); the text interface needs no vertical direction.
- Flow-relative properties: a declaration remembers that it was written so (`Pre_Decl.logical`); an element that is not horizontal left to right considers its declarations again, mapped (`src/style/writing_modes.odin`).

The cost on a page with neither: one flag per declaration in the cascade, one byte of `Computed` when boxes are built, one byte of `Box` (no larger: `wm` and `fx` are in its padding)
in `layout_contents`, `flow_children` and `compute_overflow`, one flag in `push_item`.

## What is missing

Columns:

- Nested containers: of the `multicol-nested` reference tests, part pass; `multicol-breaking` fails only with `box-decoration-break: clone`. What is left is break priorities across containers (`orphans` or `widows` given up inside before a `break-before: avoid` outside: 015, 020), monolithic content wider than its column with a height of the outer container too small for it (011), nested margins of a first child.
- `column-height` and `column-wrap` (CSS Multicol 2, about 30 reference tests) are not there.
- `flex`, `grid` and table cells are cut between their lines and rows, not inside items; a float is not cut, and lines beside a float that moves to the next column move with it.
- A float that is taller than a column, and monolithic content taller than one, are cut at the band rather than overflowing as some engines do.
- `box-decoration-break` is not there: a box cut across columns is sliced.
- Absolutely positioned boxes keep the place their containing block's top gives them and are cut like other content; their static position is mapped.
- `position: sticky` inside a column sticks in its first fragment's coordinates.
- Pages: `break-*` values that name pages act as column breaks, there is no paged media.

Writing modes:

- The toolkit's text backend (`ext/gui_toolkit`, a separate repository) has no vertical shaping. It lacks: vertical metrics (`vhea`, `vmtx`, `VORG`: the advance and origin of each glyph), a `TTB` direction for HarfRust; so upright glyphs advance by an em or the face's height and are centered by their horizontal width. Fonts with proportional vertical metrics (`palt`, `vpal`) are not honoured. The rest is reached through rotated runs.
- `text-orientation: mixed` follows a table of ranges, not the whole of UTR #50's classes (Tr and Tu: upright, with what `vert` gives).
- `text-combine-upright: digits <n>` is kept as a value and combines nothing (as Blink); `all` applies to a text of an element as one unit, and scales horizontally only.
- `clip` (the CSS 2 property) clips an absolutely positioned box by its physical rect(), from the top-left corner of its border box in every writing mode (`layout/effects.odin` `clip_rect`), through the group of a clip-path: such a box is a stacking context, which in Blink it is not.
- `ruby` has no layout in this engine. `text-emphasis`, `text-underline-position` are not there (underlines are on the left of a vertical line).
- `caret` in vertical editable text: `<input>` and `<textarea>` stay horizontal controls. `<meter>` and `<progress>` follow their own writing mode and direction; the rasteriser of the reference tests draws no control, so `forms/meter-*` and `forms/progress-*` cannot tell.
- Baselines across frames: an orthogonal box has none (it is aligned by its margin edge); `dominant-baseline` is not there.

Tests: `src/layout/multicol_test.odin` (every test checks incremental passes against full ones through `layout.incremental.verify`), `src/style` for the values, the folders `css/css-multicol` and
`css/css-writing-modes` of web-platform-tests, testharness and reference tests.
