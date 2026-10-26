type: Added

**The back/forward cache is measured**: `wren ctl stats` has a `bfcache` section. It gives the pages kept, restored and evicted, the back/forward traversals and how many found their page (`hitRate`), and why pages were refused, each blocker counted apart (`Unload_Listener`, `Web_Socket`, `Worker`...). It is checked by `tools\bfcache_e2e.ps1`.
