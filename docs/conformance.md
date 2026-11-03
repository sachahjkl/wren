# Web platform conformance

Wren runs a **sample** of the [web-platform-tests](https://github.com/web-platform-tests/wpt) (WPT) and records,
for each subtest, the result it expects (`wpt/expectations`). This page shows how many subtests pass and how the
number has grown, folder by folder.

> **Read the numbers honestly.** Wren measures a handful of WPT folders, not the whole suite. The totals below are
> **not comparable** with the per-browser scores on [wpt.fyi](https://wpt.fyi/): those run the entire test suite,
> this runs a few thousand subtests in the folders Wren has code for. A high percentage here means "the part Wren
> claims to do, it does", not "Wren is as complete as another browser".

## Passing subtests over time

The curve is rebuilt from the git history of `wpt/expectations`: one point per commit that touches it, a subtest
counting as passing when its recorded result is exactly `PASS`.

<!-- docsite:chart -->

The **purple** line is every folder measured at that moment — adding a new folder adds its subtests, so the line
steps up when Wren starts measuring more of the web. The **blue** line counts only the folders that were measured
at the start, so it shows progress at a fixed scope.

## Pass rate by folder

Each folder is one area of the platform. The percentage is passing subtests over the subtests Wren runs in that
folder; it says nothing about the subtests Wren does not run yet.

<!-- docsite:wpt-table -->

The `/workers/` folder has its own page, [WPT /workers/](wpt-workers.md), with what still fails and why.

## How this is measured

`build\wpt.exe -update` runs the tests and writes the expectations; `build\wpt.exe -only <folder>` runs one
folder. The chart and the table on this page are generated from `wpt/expectations` (and `build\wpt\report.md`
when a run has produced it) by `src/tools/docsite`, the same tool that builds this site. Nothing here is typed by
hand, so it cannot drift from the recorded results.

Most folders run without layout: what their tests read of geometry is 0, and their expectations say so. The folders that
test geometry (`LAYOUT_FOLDERS` in `src/tools/wpt/layout_host.odin`: `css/css-anchor-position`, `css/css-multicol`,
`css/css-writing-modes`, `css/cssom`, `html/semantics/interactive-elements/the-dialog-element`) get a layout of an 800 x 600 with fixed text metrics, so that `getComputedStyle`, `offsetTop` or `getBoundingClientRect` answer there as a page's.
 runner drives no input: `wpt/testdriver-vendor.js` (served in place of WPT's own) makes `test_driver`'s actions
(`click`, `send_keys`, `bless`...) fail at once instead of waiting for a person until the test's time is up. The tests need them fail, and are counted as failing.

## Reference tests

The numbers above are testharness subtests. Reference tests compare two pages pixel by pixel, and they are counted apart:
never in the chart or the table above, in a table of their own in `build\wpt\report.md`, with expectations of their own
(`wpt/expectations/<folder>.reftest`, one result per test: `PASS`, `FAIL`, `TIMEOUT`, `ERROR`, `CRASH`). They run only in
the folders of `REFTEST_FOLDERS` (`src/tools/wpt/layout_host.odin`): `css/css-multicol` and `css/css-writing-modes`.

```
build\wpt.exe -reftests all of them
build\wpt.exe -reftests -only css/css-multicol one folder's
build\wpt.exe -reftests -only css/css-multicol -update ...and rewrite that folder's expectations
build\wpt.exe -no-reftests testharness tests only
build\wpt.exe -reftests -dump <directory> the pictures of what fails
```

**How a test is told.** As WPT's manifest does at the pinned commit: a page with `<link rel=match>` or `rel=mismatch`, not
one with `testharness.js` (that is a testharness test), not one WPT's names make a reference (a `reference` folder, `-ref`,
`ref-`, `-notref`), a print test (`-print`, a `print` folder, `<meta name=reftest-pages>`: there is no paged layout here)
or a visual one.

**What is compared.** Both pages load as any test does, and are laid out on the same headless layout as the folders with
geometry: a viewport of 800 x 600 (`<meta name=viewport-size>` is honoured), fixed text metrics. The screenshot comes after
the load event and web fonts; with `class=reftest-wait` on the root, `TestRendered` is fired there and the class is waited
for, within the test's time limit (`TIMEOUT`). Then a software rasteriser (`src/tools/wpt/reftest`) draws the layout's display
list, with no GPU and no font engine: every pixel is sampled at its centre, through clips (rounded ones too) and
transforms (3D planes too), edges of boxes snapped to whole pixels first. It draws the canvas, background colours,
gradients (linear, radial, conic; interpolated in sRGB whatever the space asked for), images (the page's decoders),
box shadows (a gaussian: exact for a square box, by distance to the edge for a rounded one), borders of every style,
outlines, inline boxes, list markers, opacity groups and separable blend modes.

**Text** is the rasteriser's own, and that is the limit of what a pass says. Ahem is exact: its metrics and every glyph
shape come from `fonts/Ahem.ttf`. Any other font is one cell per character, half an em wide, filled with a pattern derived
from the code point (and from bold and italic): the same text at the same place gives the same pixels, different
characters differ, a turned run differs from an upright one. So a test comparing text in other fonts says that the same
characters landed in the same places, not that they would look alike in a real font. An item of vertical text
(`Item_Flag.Vertical`) is turned a quarter turn clockwise, its upright characters are not.

**What is not drawn**, so that tests depending on it fail honestly or (for a mismatch) pass without saying much: filters,
backdrop filters, clip paths and masks (the group composites plainly), antialiasing, non-separable blend modes,
`background-clip: text` (the content box instead). What cannot be had headless stands in as a solid colour derived from the
URL, so that both sides of a test agree only when they show the same thing: video, the document in a frame, a broken
image; form controls are their box plus such a colour derived from their type and value.

**Comparing** follows WPT: `<meta name=fuzzy>` (`maxDifference=a-b;totalPixels=c-d` or `a-b;c-d`, optionally for one
reference with a leading `url:`; a single number is that exact value) as `wptrunner` reads it, exact without one. Of a
page's links, at least one match must hold when there are any and every mismatch must (`docs/writing-tests/reftests.md` at
the pinned commit); a reference's own links must hold in turn. With `-ReftestDump` (or the environment's
`WPT_REFTEST_DUMP`), the first comparison that failed goes to `<test>.test.png`, `.ref.png` and `.diff.png` in that directory,
which the tool refuses inside a repository, with the display list of each page (`.test.items.txt`, `.ref.items.txt`: the
quickest way to tell a layout's fault from the rasteriser's); `-ReftestDumpAll` adds what passes.

`build\wpt.exe -reftest-folder css/css-flexbox -root <another checkout> -reftests` looks at a folder that is not measured:
a check of the rasteriser on code that is known to work. It records nothing unless `-Update` is given.
