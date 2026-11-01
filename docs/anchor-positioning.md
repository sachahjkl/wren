# CSS anchor positioning

A box placed against another box, its anchor, anywhere in the document: what tooltips, menus and popovers need, without
script. `CSS.supports('anchor-name: --a')` is true, so pages do not load a polyfill for it.

```css
.button  { anchor-name: --menu; }
.menu    { position: absolute; position-anchor: --menu; position-area: bottom span-right;
           position-try-fallbacks: flip-block; width: anchor-size(width); }
```

The demo is `examples/site/anchor.html`, in the demos page.

## What there is

| | |
|---|---|
| `anchor-name`, `anchor-scope` | several names, `all`; a name is looked up in the tree of the element |
| `position-anchor` | `normal`, `none`, `auto`, `match-parent`, a name |
| `anchor()` | in the inset properties: `left` `right` `top` `bottom` `inside` `outside` `start` `end` `self-start` `self-end` `center`, a percentage, a fallback, inside `calc()`, `min()`... |
| `anchor-size()` | in insets, margins and sizes, with or without a name and a size, a fallback |
| `position-area` | every keyword; `normal` alignment follows the area; a box too large for it stays in its containing block |
| `justify-self`, `align-self` | `anchor-center`; on an anchored box, `start`, `end`, `center`, `stretch` in what its insets leave |
| `position-try-fallbacks` | `@position-try` rules, `flip-block`, `flip-inline`, `flip-start`, `flip-x`, `flip-y`, a `<position-area>` |
| `position-try-order` | `most-width`, `most-height`, `most-block-size`, `most-inline-size` |
| `position-visibility` | `always`, `anchor-valid`, `anchor-visible` (the initial value), `no-overflow` |
| implicit anchors | the invoker of a popover, the `anchor` attribute, the originating element of `::before` and `::after` |
| CSSOM | `CSS.supports`, `element.style`, `getComputedStyle` (the used insets of a box that uses anchors) |

An `anchor()` on a box that is not absolutely positioned, or that finds no anchor, is its fallback, or makes the property
behave as `auto`.

Which anchor: the last acceptable one in tree order. Under the box's containing block, an in-flow box is always acceptable,
an absolutely positioned one if it comes first. Outside of the containing block, what comes first. Not the containing block
itself, nothing inside the box, nothing out of an `anchor-scope`.

## How it works

With writing modes (`docs/multicol-writing-modes.md`), an anchored box is laid out once everything else is physical: `start`, `end`, the flow-relative keywords of `position-area`, `flip-block`, `flip-inline`, `flip-start`, `most-block-size`, `justify-self` and `align-self` take the axis and the direction they mean for the writing mode of the containing block, and the box's own for `self-*`; the box itself, if vertical, is an orthogonal frame root.

Style (`src/style/anchor.odin`): a length with `anchor()` or `anchor-size()` keeps its tree (`Length_Kind.Anchor`), and only
on an absolutely positioned box; on another one it becomes its fallback when computed. The rules of `@position-try` are
applied when the element's style is computed, for each option in `position-try-fallbacks`: they may use `var()` and `em`.

Layout (`src/layout/anchor.odin`): a box that uses anchors waits. `layout_abs_list` leaves it out and, at the end of the block
layout of the pass, full or incremental, `anchored_pass` goes over all those boxes in tree order, since what they depend on
may have moved whichever boxes were laid out again. For each one and each option it makes a copy of the box's style with
the rule and the tactics applied and the functions replaced by lengths, and lays the box out with it, for the time of the
call: the box keeps pointing at the record of its element, which is what incremental passes expect. The cost on a page that
uses no anchor is one test of the style of each absolutely positioned box when it is laid out.

An option that does not overflow stays until it no longer fits, and until the box's style changes
(`Layout.anchor_last`, kept across full passes).

Scrolling is not part of layout. A box follows the scroll containers around its default anchor through a space of its own
(`Space_Kind.Anchored`), whose offset is what they add against those around the box: scrolling makes no layout, unless what was
chosen depends on it (fallbacks, `position-visibility`, when anchor and box can scroll apart): then a change of offset makes
the layout stale (`Layout.anchor_stale`), and the next frame or reading lays out again.

## What is missing

- In a **multi-column** flow an anchor is read where it shows, as the union of its fragments, not fragment by fragment.
- `anchor-scope` and names across shadow trees, by the rules of tree-scoped names: a name only matches in the tree of its
  element (`::part()` and `::slotted()` rules that set it are told apart from no other).
- The size of a scrollable containing block is its padding box, not its scrollable overflow.
- Anchors are read where they lie at the initial scroll position, then offset: `position-area` rectangles that are clamped by
  the containing block do not change when the anchor scrolls (the "recalculation points" of the tentative tests).
- `@position-try` declarations win over the element's `!important` ones and its animations, which should win.
- Transitions: `anchor()` values interpolate when an animation asks, but the used position does not start a transition when
  the anchor moves. The interfaces `CSSPositionTryRule` and `CSSPositionTryDescriptors`, typed OM, the `ident()` function,
  `@container anchored()`.
- `safe` and `unsafe` in self-alignment are ignored (as everywhere in this engine).

Tests: `src/css/anchor_test.odin`, `src/style/anchor_test.odin`, `src/layout/anchor_test.odin` (with incremental layout checked
against full passes), the `css/css-anchor-position` folder of web-platform-tests. That folder runs with a layout (the rest of
the runner has none: `src/tools/wpt/layout_host.odin`); its reference tests are not run: the runner runs reference tests
only in the folders of its `REFTEST_FOLDERS` ([Web platform conformance](conformance.md#reference-tests)), which this one
is not yet.
