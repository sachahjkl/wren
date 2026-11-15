type: Fixed

**Two copies open at once no longer hide each other's crash**: when two copies of Wren ran at the same time, a crash or a forced end of one could go unreported, and its report could be hidden by the clean end of the other. Each copy now keeps its own trace, and the next start shows what it did not see (gui_toolkit 0.262.1).
