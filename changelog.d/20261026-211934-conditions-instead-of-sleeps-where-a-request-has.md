type: Fixed

**Conditions instead of sleeps where a request has to be registered first** (`stats.pendingOps`, `Wait-WrenPending` in `tools/wrenctl.ps1`): the 100 to 400 ms sleeps of `remote_e2e` and `remote_page_e2e` that waited for a `Wren.wait` to be registered before acting on it.
