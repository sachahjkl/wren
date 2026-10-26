type: Fixed

**The browser frees the registry of navigables at exit** (`main.odin`: `page.frames_shutdown()`): a top-level page asks for its navigable on first use, which allocates the registry, and the browser's own exit order never freed it: the check build reported `1 leaked block(s), 320 byte(s)` at `navigable_new`, which failed the `browser check build` step of the CI.
