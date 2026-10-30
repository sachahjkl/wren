type: Added

**The first step of the WebAssembly JavaScript API** (`javascript.webassembly.enabled`, off): the realm gets a `WebAssembly` object with `validate(bytes)`, checked by Wasmtime with the browser's own features. Nothing else of the API yet, so it stays off: a page that finds the object expects all of it (Blazor, Emscripten, wasm-bindgen). The plan and the steps are in `docs/js/webassembly-api.md`.
