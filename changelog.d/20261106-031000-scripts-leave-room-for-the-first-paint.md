type: Fixed

**Long scripts no longer push a page's first paint behind them.** A script that used up its time now gives the loop a turn before the next inline script, and a stylesheet that just arrived gets its frame before an async script starts: npr.org painted either at 1.4 s or at 2.6 s depending on which came first.
