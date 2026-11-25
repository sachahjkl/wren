type: Fixed

**Cleared localStorage in site data and reset**: Clearing site data or running `wren ctl reset` now removes cleared origins from `about:sites` and remote stats immediately, without waiting for background disk writes to finish.
