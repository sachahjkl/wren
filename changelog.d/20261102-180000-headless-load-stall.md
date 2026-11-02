type: Fixed

**A headless Wren loads a page at once**: a frame made at once for a client waiting on it (`wren ctl`, CDP, the tests) no longer books a frame slot, so the parsed document no longer waits 0.6 to 1 s behind the slots a burst of such frames had booked (a 611 KB page from the navigation to its load: 1055 -> 34 ms). The layout-shift entries of a page cost a quarter of what they did per changed frame (flat arrays by node instead of a table of every box per frame). The pipelines and their numbers: `docs/performance.md`.
