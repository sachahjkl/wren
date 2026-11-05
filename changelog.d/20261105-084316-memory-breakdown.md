type: Added

**Where the memory is**: `wren ctl stats` and `Wren.stats` say what the heaps and each store hold (`memory`), `Wren.memoryReport` writes the allocations by kind, `Wren.memoryTrim` gives memory back now, `wrentool sweep` writes it after each page.
