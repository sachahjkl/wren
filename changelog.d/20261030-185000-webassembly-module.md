type: Added

**The WebAssembly JavaScript API, next step** (`javascript.webassembly.enabled`, still off): `WebAssembly.compile`, `WebAssembly.Module` (`imports`, `exports`, `customSections`), `CompileError`, `LinkError` and `RuntimeError`. The Content Security Policy applies (`'wasm-unsafe-eval'` or `'unsafe-eval'`). A module cannot run yet: `Memory`, `Table`, `Global` and `Instance` come next (`docs/js/webassembly-api.md`).
