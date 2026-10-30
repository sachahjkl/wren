type: Changed

**Fewer limits on a page's WebAssembly**: a module can catch what JavaScript throws (`catch_all`, `WebAssembly.JSTag`), a call can have any number of values, externrefs are released once the module has dropped them, `Memory.toFixedLengthBuffer`. Without cross-origin isolation a page has no `SharedArrayBuffer`, as in other browsers: scripts that use it when available no longer wait on a copy that nothing shares (SQLite's OPFS helper). The toolkit moves to 0.56 (timelines and screencast for its development tools; nothing changes in Wren itself).
