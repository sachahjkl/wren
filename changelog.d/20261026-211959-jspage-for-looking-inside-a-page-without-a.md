type: Added

**`jspage` for looking inside a page without a window** (`src/tools/jspage`): `-init code` (a script before the page's own), `-eval code` (after `-wait`; prints the navigations the page asked for), `-viewport WxH`, `-allocs` (with `-stats`: the live allocations of the window thread by source line), and in `-stats` the memory of the realm and of the style system and what the first paint would still wait for. `WREN_SAMPLE_STACKS=1` is another spelling of `WREN_SAMPLE_STACK=1` of the profile build.
