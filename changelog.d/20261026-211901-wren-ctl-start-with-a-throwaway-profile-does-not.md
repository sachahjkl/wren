type: Fixed

**`wren ctl start` with a throwaway profile does not download the content blocker's lists** (`--pref blocker.update.enabled=true` turns that on): a few seconds of CPU after the start were taken for the CPU of an idle Wren by the end-to-end tests on a machine with a network.
