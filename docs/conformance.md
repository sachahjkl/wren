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

`tools\wpt.ps1 -Update` runs the tests and writes the expectations; `tools\wpt.ps1 -Only <folder>` runs one
folder. The chart and the table on this page are generated from `wpt/expectations` (and `build\wpt\report.md`
when a run has produced it) by `src/tools/docsite`, the same tool that builds this site. Nothing here is typed by
hand, so it cannot drift from the recorded results.
